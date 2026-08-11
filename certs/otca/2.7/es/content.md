# 2.7 — Agents

**OTCA · Domain 2 (The OpenTelemetry Collector) · Peso en el examen ≈ 6.57%**

> Nota de alcance: En la terminología de OpenTelemetry un *agent* no es un binario distinto. Es un **rol de despliegue** del mismo binario del Collector (`otelcol` / `otelcol-contrib` / una compilación personalizada de OCB). Un Collector es un *agent* cuando corre **en el mismo host o en el mismo Pod que la carga de trabajo de la que recolecta**, como el primer salto que sale del proceso instrumentado. El rol complementario es el *gateway* (un servicio independiente, escalado horizontalmente, que concentra el tráfico entrante de muchos agents). Este tema trata sobre el rol de agent: por qué existe, cómo se despliega y cómo se opera en producción.

---

## 1. El problema de producción: por qué existe una capa de agent

Una aplicación instrumentada tiene un exporter del SDK que debe enviar spans, métricas y logs a algún lado. El diseño ingenuo es **SDK → backend directamente**. En producción esto falla en cinco ejes distintos, y cada falla es lo que la capa de agent está diseñada para absorber.

1. **La latencia de egreso se filtra en la ruta de la petición.** Un batch span processor igual tiene que establecer/mantener TLS hacia un backend remoto que puede estar en otra AZ u otra región. Cualquier backpressure (429s, ACKs lentos) se propaga al proceso de la aplicación — la memoria crece en la cola de exportación, aumenta la presión sobre el GC y, en casos patológicos, la app sufre OOM *a causa de su propia telemetría*. Un agent en `localhost` (sidecar) o en la IP del nodo (DaemonSet) convierte un salto remoto de alta varianza en un salto loopback/host-local de submilisegundo. La app descarga y se olvida.

2. **El fan-in de conexiones derrite el backend y el gateway.** 10.000 Pods, cada uno abriendo un stream gRPC persistente hacia un backend, son 10.000 conexiones para autenticar, mantener vivas y balancear. La capa de agent colapsa esto: el agent de cada nodo multiplexa todos los Pods locales en un número pequeño y estable de conexiones upstream.

3. **La telemetría está sub-contextualizada en el origen.** El SDK conoce `service.name` y `service.version`, pero **no** conoce de forma confiable `k8s.pod.name`, `k8s.node.name`, `cloud.availability_zone`, `host.id`, ni el digest de la imagen del contenedor. El agent — porque se ubica en el nodo con acceso a la API de Kubernetes y a los endpoints de metadata de la nube (IMDS) — enriquece cada señal con `k8sattributes` y `resourcedetection`. Hacer esto de forma centralizada en un gateway es posible para los atributos de k8s pero imposible para los datos de alcance de host, que solo existen en el nodo.

4. **Las señales de alcance de host y de nodo no tienen otro recolector.** El CPU/memoria/disco/red del host (`hostmetrics`), las estadísticas del kubelet y de cAdvisor (`kubeletstats`), y los archivos de log de stdout/stderr de los contenedores bajo `/var/log/pods` (`filelog`) son **recursos locales del nodo**. Solo un agent por nodo (DaemonSet) puede leerlos. Esta es la razón más común, y por lejos, por la que una capa de agent es obligatoria y no opcional.

5. **Sin durabilidad local = pérdida de datos ante cualquier tropiezo.** El buffer del SDK es pequeño y volátil. Un agent provee una cola de envío persistente (extensión `file_storage`), reintentos con backoff, y un `memory_limiter` que descarga carga de forma predecible en lugar de crashear.

**La arquitectura de referencia** es, por lo tanto, de dos capas:

```
┌─ node A ─────────────┐     ┌─ node B ─────────────┐
│  app pods            │     │  app pods            │
│    │ OTLP localhost/ │     │    │                 │
│    ▼ hostIP          │     │    ▼                 │
│  [Collector AGENT]   │     │  [Collector AGENT]   │
│   otlp,hostmetrics,  │     │   otlp,hostmetrics,  │
│   kubeletstats,      │     │   kubeletstats,      │
│   filelog            │     │   filelog            │
└────────┬─────────────┘     └────────┬─────────────┘
         │  OTLP (batched, few conns) │
         └───────────────┬────────────┘
                         ▼
              [Collector GATEWAY]  (Deployment, HPA)
               tail_sampling, aggregation, redaction
                         │
                         ▼
                   backend(s): Jaeger/Tempo/Prometheus/OTLP SaaS
```

El trabajo del agent es **descarga local rápida + enriquecimiento de host + recolección de alcance de host**. Las decisiones pesadas, con estado, sobre la población completa (tail-based sampling, control de cardinalidad, agregación entre servicios) pertenecen al gateway, nunca al agent — un agent solo ve el tráfico de su propio nodo, así que no puede tomar decisiones a nivel de toda la población de forma correcta.

---

## 2. Topologías de despliegue y compromisos

### 2.1 Agent vs Gateway (los dos roles del Collector)

| Dimensión | **Agent** | **Gateway** |
|---|---|---|
| Primitiva de Kubernetes | `DaemonSet` (1/nodo) o contenedor sidecar | `Deployment` + `Service` (+ HPA) |
| Ubicación | Mismo host / mismo Pod que la carga de trabajo | Independiente, en cualquier parte del cluster |
| Alcance de visibilidad | Un nodo (o un Pod) | Todos los agents que lo apunten |
| Deberes primarios | Descarga local, `resourcedetection`, `k8sattributes`, recolección de host/kubelet/logs | `tail_sampling`, agregación, redacción de PII, fan-out al backend, balanceo de carga |
| Tail-based sampling | ❌ Incorrecto (vista parcial del trace) | ✅ Correcto (necesita el trace completo) |
| Radio de impacto de una config mala | Los datos de un nodo | Todo el pipeline |
| Escala con | Cantidad de nodos (automático vía DaemonSet) | Volumen de tráfico (HPA sobre CPU/cola) |
| Conexiones upstream | Pocas (agent→gateway) | Pool gestionado (gateway→backend) |

### 2.2 Formatos del agent

| | **Agent DaemonSet** | **Agent sidecar** | **Sin agent (SDK→gateway/backend)** |
|---|---|---|---|
| Instancias | 1 por nodo | 1 por Pod | 0 |
| Sobrecarga de recursos | Amortizada entre todos los Pods del nodo | Multiplicada por la cantidad de Pods (la más alta) | Ninguna |
| Aislamiento de impacto/tenant | Compartido por nodo | Aislamiento perfecto por Pod | N/A |
| Métricas de host / logs de nodo / kubelet | ✅ Solo este formato puede | ❌ | ❌ |
| Alcanzabilidad desde la app | `status.hostIP` + `hostPort`, o Service local del nodo | `localhost` (netns compartida del Pod) | DNS de un Service remoto |
| Acoplamiento de fallas con la app | Ciclo de vida del Pod independiente | Muere/reinicia con el Pod; bloquea el arranque del Pod si no es estilo init con `restartPolicy: Always` | Ninguno |
| Despliegue de config | Por nodo, un solo DaemonSet | Por carga de trabajo; requiere reinicio del Pod / reinyección | Central |
| Ideal para | Línea base para todo el cluster: telemetría de host + k8s + app | Aislamiento multi-tenant estricto, pipelines por equipo, latencia estilo serverless | Chico/dev, o cuando un gateway realmente alcanza |

**Regla general:** el agent DaemonSet es el predeterminado en Kubernetes porque es el *único* formato que puede recolectar las señales de host, kubelet y logs de nodo, y su costo se amortiza. Agregá sidecars solo donde el aislamiento por Pod o los pipelines por tenant justifiquen la sobrecarga multiplicada.

### 2.3 Cómo la app encuentra el agent DaemonSet

Como un Pod de un DaemonSet es por nodo, la app debe alcanzar el agent **de su propio nodo**, no uno cualquiera. Tres técnicas, en orden de preferencia:

| Técnica | Cómo | Compromiso |
|---|---|---|
| **Downward API `status.hostIP` + `hostPort`** | La app lee la IP del nodo, envía a `http://$(NODE_IP):4318`; el agent hace bind de `hostPort: 4318` | Estándar, explícito; requiere un hostPort libre y privilegios `NET` sobre el puerto del nodo |
| **Service `internalTrafficPolicy: Local`** | Un Service ClusterIP sobre el DaemonSet con `internalTrafficPolicy: Local` enruta solo al endpoint local del nodo | Nombre DNS más limpio; necesita k8s ≥1.22 GA |
| **`hostNetwork: true`** | El agent comparte la netns del nodo; la app usa `NODE_IP` | El enrutamiento más simple, pero consume puertos del nodo y debilita el aislamiento |

---

## 3. Manifiestos completos y sintácticamente válidos

Se muestran dos rutas equivalentes: **(A)** los objetos de Kubernetes crudos (lo que el Operator genera por debajo — conocelos para el examen), y **(B)** el CRD del OpenTelemetry Operator (lo que usás en la práctica).

### 3.1 Ruta A — Agent DaemonSet crudo (stack completo: RBAC + ConfigMap + DaemonSet)

**3.1.1 ServiceAccount + RBAC** (requerido por `k8sattributes` y `kubeletstats`):

```yaml
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
  # k8sattributes processor: enrich telemetry with Pod/Namespace/workload metadata
  - apiGroups: [""]
    resources: ["pods", "namespaces", "nodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["replicasets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["extensions"]
    resources: ["replicasets"]
    verbs: ["get", "list", "watch"]
  # kubeletstats receiver: read the node's kubelet /stats/summary via the API proxy path
  - apiGroups: [""]
    resources: ["nodes/stats", "nodes/proxy"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: otel-agent
subjects:
  - kind: ServiceAccount
    name: otel-agent
    namespace: observability
roleRef:
  kind: ClusterRole
  name: otel-agent
  apiGroup: rbac.authorization.k8s.io
```

**3.1.2 ConfigMap — la configuración del Collector del agent** (el corazón del tema):

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-agent-conf
  namespace: observability
data:
  otel-agent-config.yaml: |
    receivers:
      # Local offload point for every SDK on this node.
      otlp:
        protocols:
          grpc:
            endpoint: ${env:MY_POD_IP}:4317
          http:
            endpoint: ${env:MY_POD_IP}:4318
      # Host-scoped metrics — ONLY an agent can produce these.
      hostmetrics:
        collection_interval: 15s
        root_path: /hostfs
        scrapers:
          cpu: {}
          load: {}
          memory: {}
          disk: {}
          filesystem:
            exclude_mount_points:
              mount_points: ["/var/lib/kubelet/*", "/proc", "/sys"]
              match_type: regexp
          network: {}
          paging: {}
      # Kubelet + cAdvisor stats for this node's Pods/containers.
      kubeletstats:
        collection_interval: 20s
        auth_type: serviceAccount
        endpoint: https://${env:K8S_NODE_NAME}:10250
        insecure_skip_verify: true
        metric_groups: [container, pod, node, volume]
      # Container stdout/stderr from the node's log directory.
      filelog:
        include: [/var/log/pods/*/*/*.log]
        exclude: [/var/log/pods/observability_otel-agent-*/*/*.log]
        start_at: end
        include_file_path: true
        operators:
          - type: container
            id: container-parser

    processors:
      # ALWAYS first in every pipeline — bounds RAM and sheds load deterministically.
      memory_limiter:
        check_interval: 1s
        limit_percentage: 80
        spike_limit_percentage: 25
      # Enrich with node/cloud facts available only at the host.
      resourcedetection:
        detectors: [env, system, eks, ec2, gcp, azure]
        timeout: 5s
        override: false
      # Enrich with Kubernetes metadata; correlate by source IP.
      k8sattributes:
        auth_type: serviceAccount
        passthrough: false
        filter:
          node_from_env_var: K8S_NODE_NAME   # only watch THIS node's Pods → less API load
        extract:
          metadata:
            - k8s.namespace.name
            - k8s.pod.name
            - k8s.pod.uid
            - k8s.deployment.name
            - k8s.node.name
            - k8s.container.name
        pod_association:
          - sources:
              - from: resource_attribute
                name: k8s.pod.ip
          - sources:
              - from: connection
      # Batch LAST — after enrichment, before export.
      batch:
        send_batch_size: 8192
        send_batch_max_size: 10000
        timeout: 5s

    exporters:
      # Ship to the gateway, not the backend. Durable queue + retry.
      otlp:
        endpoint: otel-gateway.observability.svc.cluster.local:4317
        tls:
          insecure: true
        sending_queue:
          enabled: true
          num_consumers: 10
          queue_size: 5000
          storage: file_storage   # survive restarts
        retry_on_failure:
          enabled: true
          initial_interval: 5s
          max_interval: 30s
          max_elapsed_time: 300s

    extensions:
      health_check:
        endpoint: ${env:MY_POD_IP}:13133
      pprof:
        endpoint: ${env:MY_POD_IP}:1777
      zpages:
        endpoint: ${env:MY_POD_IP}:55679
      file_storage:
        directory: /var/lib/otelcol/queue
        timeout: 1s

    service:
      extensions: [health_check, pprof, zpages, file_storage]
      telemetry:
        metrics:
          level: detailed
          address: ${env:MY_POD_IP}:8888
        logs:
          level: info
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, k8sattributes, resourcedetection, batch]
          exporters: [otlp]
        metrics:
          receivers: [otlp, hostmetrics, kubeletstats]
          processors: [memory_limiter, k8sattributes, resourcedetection, batch]
          exporters: [otlp]
        logs:
          receivers: [otlp, filelog]
          processors: [memory_limiter, k8sattributes, resourcedetection, batch]
          exporters: [otlp]
```

**3.1.3 El DaemonSet en sí** (cableado de env, montajes de volúmenes del host, `hostPort`):

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: otel-agent
  namespace: observability
  labels: { app: otel-agent }
spec:
  selector:
    matchLabels: { app: otel-agent }
  template:
    metadata:
      labels: { app: otel-agent }
    spec:
      serviceAccountName: otel-agent
      # Tolerate control-plane taints so host metrics cover every node.
      tolerations:
        - operator: Exists
      containers:
        - name: otel-agent
          image: otel/opentelemetry-collector-contrib:0.112.0
          args: ["--config=/conf/otel-agent-config.yaml"]
          securityContext:
            runAsUser: 0            # required to read /var/log/pods and /hostfs
          env:
            - name: K8S_NODE_NAME
              valueFrom: { fieldRef: { fieldPath: spec.nodeName } }
            - name: MY_POD_IP
              valueFrom: { fieldRef: { fieldPath: status.podIP } }
          ports:
            - { name: otlp-grpc, containerPort: 4317, hostPort: 4317, protocol: TCP }
            - { name: otlp-http, containerPort: 4318, hostPort: 4318, protocol: TCP }
            - { name: metrics,   containerPort: 8888, protocol: TCP }
          livenessProbe:
            httpGet: { path: /, port: 13133 }
            initialDelaySeconds: 10
          readinessProbe:
            httpGet: { path: /, port: 13133 }
          resources:
            requests: { cpu: 100m, memory: 200Mi }
            limits:   { cpu: 500m, memory: 500Mi }   # memory_limiter's 80% is derived from this
          volumeMounts:
            - { name: config,   mountPath: /conf }
            - { name: hostfs,   mountPath: /hostfs, readOnly: true, mountPropagation: HostToContainer }
            - { name: varlogpods, mountPath: /var/log/pods, readOnly: true }
            - { name: queue,    mountPath: /var/lib/otelcol/queue }
      volumes:
        - name: config
          configMap: { name: otel-agent-conf }
        - name: hostfs
          hostPath: { path: / }
        - name: varlogpods
          hostPath: { path: /var/log/pods }
        - name: queue
          hostPath: { path: /var/lib/otelcol/queue, type: DirectoryOrCreate }
```

**3.1.4 Lado de la app — cómo una carga de trabajo apunta a su agent local del nodo** (Downward API):

```yaml
# excerpt of an application Deployment's pod spec
env:
  - name: NODE_IP
    valueFrom: { fieldRef: { fieldPath: status.hostIP } }
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://$(NODE_IP):4318"
  - name: OTEL_EXPORTER_OTLP_PROTOCOL
    value: "http/protobuf"
  - name: OTEL_SERVICE_NAME
    value: "checkout"
```

### 3.2 Ruta B — OpenTelemetry Operator (CRDs)

El Operator colapsa todo el §3.1 en un solo objeto. El mismo agent, de forma declarativa:

```yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: agent
  namespace: observability
spec:
  mode: daemonset          # <-- the "agent" role
  image: otel/opentelemetry-collector-contrib:0.112.0
  serviceAccount: otel-agent
  hostNetwork: false
  env:
    - name: K8S_NODE_NAME
      valueFrom: { fieldRef: { fieldPath: spec.nodeName } }
  volumeMounts:
    - { name: hostfs, mountPath: /hostfs, readOnly: true, mountPropagation: HostToContainer }
    - { name: varlogpods, mountPath: /var/log/pods, readOnly: true }
  volumes:
    - { name: hostfs, hostPath: { path: / } }
    - { name: varlogpods, hostPath: { path: /var/log/pods } }
  config:
    receivers:
      otlp:
        protocols:
          grpc: { endpoint: 0.0.0.0:4317 }
          http: { endpoint: 0.0.0.0:4318 }
      hostmetrics:
        root_path: /hostfs
        scrapers: { cpu: {}, memory: {}, filesystem: {}, network: {}, load: {} }
      kubeletstats:
        auth_type: serviceAccount
        endpoint: https://${env:K8S_NODE_NAME}:10250
        insecure_skip_verify: true
    processors:
      memory_limiter: { check_interval: 1s, limit_percentage: 80, spike_limit_percentage: 25 }
      k8sattributes:
        filter: { node_from_env_var: K8S_NODE_NAME }
      batch: {}
    exporters:
      otlp:
        endpoint: otel-gateway-collector.observability.svc:4317
        tls: { insecure: true }
    service:
      pipelines:
        traces:  { receivers: [otlp], processors: [memory_limiter, k8sattributes, batch], exporters: [otlp] }
        metrics: { receivers: [otlp, hostmetrics, kubeletstats], processors: [memory_limiter, k8sattributes, batch], exporters: [otlp] }
```

**Agent sidecar vía el Operator** — un `OpenTelemetryCollector` separado con `mode: sidecar`, inyectado por annotation:

```yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: sidecar
  namespace: team-payments
spec:
  mode: sidecar
  config:
    receivers:
      otlp: { protocols: { grpc: { endpoint: localhost:4317 }, http: { endpoint: localhost:4318 } } }
    processors: { batch: {} }
    exporters:
      otlp: { endpoint: otel-gateway-collector.observability.svc:4317, tls: { insecure: true } }
    service:
      pipelines:
        traces: { receivers: [otlp], processors: [batch], exporters: [otlp] }
---
# Injection is opt-in per Pod:
apiVersion: apps/v1
kind: Deployment
metadata: { name: payments }
spec:
  template:
    metadata:
      annotations:
        sidecar.opentelemetry.io/inject: "team-payments/sidecar"
    spec:
      containers:
        - name: app
          image: payments:1.4.0
          # App exports to localhost:4318 — the injected sidecar shares the netns.
```

---

## 4. CLI y terminal

**Validá la config antes de que llegue al cluster** (la verificación gratuita y offline):

```console
$ docker run --rm -v "$PWD/otel-agent-config.yaml:/c.yaml" \
    otel/opentelemetry-collector-contrib:0.112.0 validate --config=/c.yaml
$ echo $?
0
```

Un pipeline roto se atrapa acá, no en tiempo de ejecución:

```console
$ otelcol-contrib validate --config=/c.yaml
Error: failed to build pipelines: pipeline "traces": references processor "k8sattribute" which is not configured
exit status 1
```

**Desplegá y observá el DaemonSet del agent:**

```console
$ kubectl apply -f rbac.yaml -f configmap.yaml -f daemonset.yaml
serviceaccount/otel-agent created
clusterrole.rbac.authorization.k8s.io/otel-agent created
clusterrolebinding.rbac.authorization.k8s.io/otel-agent created
configmap/otel-agent-conf created
daemonset.apps/otel-agent created

$ kubectl -n observability rollout status ds/otel-agent
Waiting for daemon set "otel-agent" rollout: 2 of 3 updated pods are available...
daemon set "otel-agent" successfully rolled out

$ kubectl -n observability get ds otel-agent
NAME         DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
otel-agent   3         3         3       3            3           <none>          47s

$ kubectl -n observability get pods -o wide -l app=otel-agent
NAME               READY   STATUS    RESTARTS   AGE   IP           NODE
otel-agent-4f9q2   1/1     Running   0          51s   10.244.1.7   node-1
otel-agent-b2xzl   1/1     Running   0          51s   10.244.2.3   node-2
otel-agent-tk8mn   1/1     Running   0          51s   10.244.3.9   node-3
```

**Confirmá que el pipeline se construyó** (el log de arranque es la verdad de base):

```console
$ kubectl -n observability logs otel-agent-4f9q2 | grep -E "Everything is ready|pipeline"
2026-08-10T14:22:07.114Z  info  service@v0.112.0/service.go:261  Everything is ready. Begin running and processing data.
2026-08-10T14:22:07.109Z  info  Starting receivers... {"pipeline": "metrics/hostmetrics"}
```

---

## 5. Verificación y diagnóstico de fallas

El agent expone tres superficies de diagnóstico. Aprendé las tres.

| Superficie | Extensión / puerto | Qué responde |
|---|---|---|
| **Health** | `health_check` :13133 | ¿Está el collector arriba y sus pipelines corriendo? (alimenta las probes) |
| **Pipeline en vivo** | `zpages` :55679 (`/debug/tracez`, `/debug/pipelinez`) | Qué está fluyendo en este momento, por componente |
| **Auto-métricas** | telemetría interna :8888 (Prometheus) | Accepted vs refused vs dropped vs sent, profundidad de cola, RSS |
| **Profiling** | `pprof` :1777 | Perfiles de CPU/heap cuando el agent mismo se comporta mal |

**5.1 Health y liveness:**

```console
$ kubectl -n observability exec otel-agent-4f9q2 -- \
    wget -qO- http://localhost:13133/
{"status":"Server available","upSince":"2026-08-10T14:22:07Z","uptime":"6m41s"}
```

**5.2 Los cuatro números que explican todo incidente de pérdida de datos.** Hacé port-forward de :8888 y leé los contadores:

```console
$ kubectl -n observability port-forward otel-agent-4f9q2 8888:8888 &
$ curl -s localhost:8888/metrics | grep -E 'otelcol_(receiver|processor|exporter)'
otelcol_receiver_accepted_spans{receiver="otlp",transport="grpc"} 154820
otelcol_receiver_refused_spans{receiver="otlp",transport="grpc"} 0
otelcol_processor_dropped_spans{processor="memory_limiter"} 0
otelcol_exporter_sent_spans{exporter="otlp"} 154820
otelcol_exporter_send_failed_spans{exporter="otlp"} 0
otelcol_exporter_queue_size{exporter="otlp"} 3
otelcol_exporter_queue_capacity{exporter="otlp"} 5000
otelcol_process_memory_rss 148176896
```

Leelos como una ecuación de flujo — **accepted − refused − dropped ≈ sent**. Cualquier desbalance localiza la falla:

| Síntoma en las métricas de :8888 | Causa raíz | Solución |
|---|---|---|
| `receiver_refused_spans` subiendo | El `memory_limiter` está rechazando en la puerta (se alcanzó el límite soft) → backpressure al SDK | Subir el límite de memoria del Pod; bajar la ingesta; agregar capacidad de gateway |
| `processor_dropped_spans{processor="memory_limiter"}` > 0 | Se alcanzó el límite hard; se descartan datos para salvar el proceso | Igual que arriba; buscar una explosión de cardinalidad/batch |
| `exporter_send_failed_spans` subiendo | Ruta agent → gateway rota | Ver 5.3 |
| `exporter_queue_size` → `queue_capacity` | El gateway no da abasto; la cola se satura, drops inminentes | Escalar el gateway (HPA); aumentar `queue_size`; habilitar `file_storage` |
| `process_memory_rss` cerca del límite + rechazos | Agent sub-provisionado | Subir `resources.limits.memory` |

**5.3 "Los traces desaparecen entre el agent y el gateway."** La falla canónica del agent. Recorrela:

```console
$ kubectl -n observability logs otel-agent-4f9q2 | grep -i "export"
2026-08-10T14:31:02.550Z  warn  exporterhelper/queue_sender.go:120  Exporting failed. Will retry.
  {"error": "rpc error: code = Unavailable desc = connection error: desc = \"transport: Error while dialing:
   dial tcp 10.96.0.42:4317: connect: connection refused\"", "interval": "8.6s"}

# Is the gateway even resolvable / up?
$ kubectl -n observability get svc otel-gateway
NAME           TYPE        CLUSTER-IP     PORT(S)             AGE
otel-gateway   ClusterIP   10.96.0.42     4317/TCP,4318/TCP   3h

$ kubectl -n observability get endpoints otel-gateway
NAME           ENDPOINTS   AGE
otel-gateway   <none>      3h          # <-- no ready backends: gateway Pods are down/unready
```

Un `ENDPOINTS` vacío es la prueba contundente: el Service existe pero ningún Pod del gateway está Ready, así que cada exportación del agent es rechazada. Arreglá el gateway (o su readiness probe); el `retry_on_failure` + la cola de `file_storage` del agent drenarán el backlog una vez que aparezcan los endpoints — *siempre que* `max_elapsed_time` no haya expirado ya (los datos posteriores a esa ventana se descartan, y lo vas a ver en `exporter_send_failed_spans`).

**5.4 "Faltan las métricas de host / stats de kubelet."** Casi siempre es RBAC o un montaje de host faltante:

```console
$ kubectl -n observability logs otel-agent-4f9q2 | grep -i kubeletstats
2026-08-10T14:22:10.880Z  error  scraperhelper/scrapercontroller.go  Error scraping metrics
  {"error": "Get \"https://node-1:10250/stats/summary\": Unauthorized", "scraper": "kubeletstats"}

# Prove the ServiceAccount can reach the kubelet stats path:
$ kubectl auth can-i get nodes/stats --as=system:serviceaccount:observability:otel-agent
no          # <-- ClusterRole is missing nodes/stats; add it (see §3.1.1)
```

Para `hostmetrics` mostrando valores de alcance de contenedor en lugar de alcance de nodo, verificá que tanto `root_path: /hostfs` **como** el montaje hostPath de `hostfs` estén presentes — uno sin el otro reporta silenciosamente la vista del contenedor.

**5.5 Inspección de componentes en vivo con zpages:**

```console
$ kubectl -n observability port-forward otel-agent-4f9q2 55679:55679 &
$ curl -s localhost:55679/debug/pipelinez | sed 's/<[^>]*>//g' | grep -A2 traces
Pipeline traces
  MutatesData: true
  Receivers: [otlp]  Processors: [memory_limiter k8sattributes resourcedetection batch]  Exporters: [otlp]
```

---

## 6. Referencias

- OpenTelemetry — Collector *Deployment* (roles de agent vs gateway): https://opentelemetry.io/docs/collector/deployment/
- OpenTelemetry — Collector *Deployment › Agent*: https://opentelemetry.io/docs/collector/deployment/agent/
- OpenTelemetry — Collector *Deployment › Gateway*: https://opentelemetry.io/docs/collector/deployment/gateway/
- OpenTelemetry — Configuración del Collector (receivers/processors/exporters/extensions/service): https://opentelemetry.io/docs/collector/configuration/
- OpenTelemetry — procesador `memory_limiter`: https://github.com/open-telemetry/opentelemetry-collector/tree/main/processor/memorylimiterprocessor
- OpenTelemetry — procesador `k8sattributes` (incl. RBAC): https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/k8sattributesprocessor
- OpenTelemetry — procesador `resourcedetection`: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/resourcedetectionprocessor
- OpenTelemetry — receiver `hostmetrics`: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver/hostmetricsreceiver
- OpenTelemetry — receiver `kubeletstats`: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver/kubeletstatsreceiver
- OpenTelemetry — receiver `filelog`: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver/filelogreceiver
- OpenTelemetry — Telemetría interna del Collector / auto-observabilidad: https://opentelemetry.io/docs/collector/internal-telemetry/
- OpenTelemetry — extensiones `health_check`, `pprof`, `zpages`, `file_storage`: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/extension
- OpenTelemetry Operator — CRD `OpenTelemetryCollector` e inyección de sidecar: https://github.com/open-telemetry/opentelemetry-operator
- OpenTelemetry — Patrones de despliegue del Collector en Kubernetes: https://opentelemetry.io/docs/platforms/kubernetes/collector/
- Variables de entorno del exporter OTLP (`OTEL_EXPORTER_OTLP_ENDPOINT`, `_PROTOCOL`): https://opentelemetry.io/docs/specs/otel/protocol/exporter/
- CNCF — OTCA Curriculum: https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf