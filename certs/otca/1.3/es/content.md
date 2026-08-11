# 1.3 Instrumentación

> **Dominio:** Fundamentos de la Observabilidad · **Peso en el examen:** 4.5%
> **Alcance:** Qué *es* la instrumentación en el modelo de OpenTelemetry (OTel), las tres estrategias de producción (zero-code, por librería, manual), cómo cada runtime inyecta físicamente el código que emite telemetría, y cómo un equipo de Plataforma lo despliega sobre una flota con el OpenTelemetry Operator.

---

## 1. El problema de producción: la brecha de instrumentación

Un backend de telemetría — Tempo, Jaeger, Prometheus, un proveedor — no vale nada hasta que el workload *emita* señales. **La instrumentación es el acto de hacer que una aplicación produzca traces, métricas y logs.** Todo lo demás en el pipeline (Collector, exporters, almacenamiento) solo *mueve y almacena* lo que la instrumentación creó. Si el proceso no está instrumentado, el pipeline es un conjunto de caños vacíos.

En un monolito podías cablear a mano el logging y unos cuantos timers y considerarlo observable. En un mesh de 300 servicios ese modelo se derrumba por tres razones concretas:

1. **Cobertura vs. esfuerzo.** Una sola request toca un gateway, un servicio de auth, tres servicios de negocio, un cache y dos bases de datos a través de dos lenguajes. Para reconstruir ese camino necesitás que *cada* salto emita un span **y** propague el mismo trace context. Un solo salto sin instrumentar rompe el trace en fragmentos desconectados — obtenés un "broken trace" con un hueco exactamente donde suele esconderse la latencia.
2. **Consistencia.** Si el equipo A nombra el atributo de estado HTTP como `status`, el equipo B como `http_status` y el equipo C como `http.response.status_code`, ninguna query abarca los tres. Los dashboards y SLOs entre servicios requieren un *vocabulario compartido*, que es lo que proveen las **semantic conventions** (§6).
3. **Costo del cambio.** Editar manualmente 300 servicios para agregar tracing — y luego re-editarlos cuando el SDK cambia — es un programa de trabajo que ningún equipo de plataforma puede sostener. Este es el motor económico detrás de la **instrumentación zero-code** y el **OpenTelemetry Operator** (§7).

La idea arquitectónica que evalúa OTCA: **la instrumentación es un espectro, no un binario.** Casi siempre corrés un modelo *híbrido* — zero-code para amplitud (cada llamada a DB, cada handler HTTP, gratis) más una capa delgada de spans y atributos manuales para el contexto de negocio que un agente genérico nunca puede inferir (`order.id`, `tenant.tier`, `payment.provider`).

```
        broad, generic, zero effort                deep, business-specific, high effort
   ├──────────────────────────────┼──────────────────────────────────────────────────┤
   Zero-code (auto)        Instrumentation libraries              Manual (API/SDK)
   agent / operator        framework-aware plugins                your code, your spans
```

---

## 2. Taxonomía de la instrumentación

OpenTelemetry define tres estrategias distintas. **No son mutuamente excluyentes** — el SDK fusiona los spans de las tres en un único trace.

| # | Estrategia | Qué es | Quién la escribe | ¿Cambio de código en la app? |
|---|----------|-----------|---------------|---------------------|
| 1 | **Zero-code** (también llamada automática / auto-instrumentación) | Un agente externo inyecta telemetría en una app *en ejecución* sin tocar el código fuente | Mantenedores de OTel + vos (solo config) | **Ninguno** (solo re-empaquetar/relanzar) |
| 2 | **Instrumentation libraries** | Plugins por framework (`requests`, `net/http`, `Spring`, `gRPC`) que producen spans/métricas para esa librería | Mantenedores de OTel/comunidad | Importar + registrar (unas pocas líneas) |
| 3 | **Manual / basada en código** | Llamás directamente a la **API** de OTel para crear spans, registrar métricas, setear atributos | Vos | Sí — ediciones reales de la lógica de negocio |

Un cuarto término que no debés confundir: **instrumentación nativa** — una librería que emite telemetría de OTel *por sí misma*, sin necesidad de plugin (la API de OTel es una dependencia de la librería). Este es el estado final hacia el que empuja el proyecto; hoy es raro.

### 2.1 Matriz de trade-offs (la tabla de oro)

| Dimensión | Zero-code | Instrumentation library | Manual |
|-----------|-----------|-------------------------|--------|
| **Amplitud de cobertura** | Alta — todas las libs soportadas de una | Media — un framework | Baja — solo donde lo escribís |
| **Contexto de negocio** | Ninguno (no puede conocer `order.id`) | Ninguno | **Completo** |
| **Cambios en el código fuente** | Cero | Mínimos | Extensos |
| **Rollout a la flota** | Trivial (annotation/variable de entorno) | Por servicio | Por servicio, continuo |
| **Overhead en runtime** | El más alto (parchea todo) | Medio | El más bajo (solo lo que agregás) |
| **Acoplamiento de versión** | El agente debe seguir las versiones de las libs | El plugin debe coincidir con la lib | Laxo (la API es estable) |
| **Radio de impacto de una falla** | Todo el proceso (mal agente → crash/lag) | Una librería | Un camino de código |
| **Costo de arranque** | Alto (escaneo de bytecode / monkey-patch) | Bajo | ~Cero |
| **Soporte en Go** | eBPF o solo en tiempo de compilación (§3.5) | Sí | Sí |

**Regla práctica para una plataforma:** dejá la flota por defecto en zero-code (amplitud, cero esfuerzo por equipo), y dales a los equipos una capa delgada de SDK **manual** para enriquecer los auto-spans con atributos de dominio. Reservá el modo puramente-manual para servicios en Go donde la inyección por eBPF no sea aceptable.

---

## 3. Cómo funciona realmente la instrumentación zero-code, por runtime

"Automático" no es magia — cada runtime tiene un mecanismo de inyección concreto, y el mecanismo dicta las restricciones operativas (privilegios, reinicio, sidecar). Esta es el área de mecánica más evaluada de este tema.

| Runtime | Mecanismo | Punto de inyección | Requisito extra |
|---------|-----------|-----------------|-------------------|
| **Java** | Manipulación de bytecode vía un JAR `-javaagent` (ByteBuddy) | En el class-load de la JVM | `JAVA_TOOL_OPTIONS` / `-javaagent:` |
| **Python** | Monkey-patching de módulos en el import | Wrapper `opentelemetry-instrument` | El wrapper lanza el proceso |
| **Node.js** | Hooks de módulos (`require-in-the-middle` / `import-in-the-middle`) | `--require`/`--import` en el arranque | `NODE_OPTIONS` |
| **.NET** | La CLR Profiler API reescribe el IL | En el compilado JIT | `CORECLR_ENABLE_PROFILING=1` + env del profiler |
| **Go** | **uprobes de eBPF** (no es posible parchear el runtime) | Probes del kernel sobre el binario | Privilegiado/`CAP_SYS_ADMIN`, sidecar, path del ejecutable objetivo |

### 3.1 Java — el agente de bytecode

La JVM expone un hook de class-load. El agente Java de OTel (`opentelemetry-javaagent.jar`) se engancha a él y reescribe el bytecode de las librerías *soportadas* en el momento en que sus clases se cargan, envolviendo métodos (por ej. `HttpServlet.service`, JDBC `Statement.execute`) con inicio/fin de span. No se toca ningún archivo `.java`.

```console
$ java -javaagent:/otel/opentelemetry-javaagent.jar \
       -Dotel.service.name=checkout \
       -Dotel.exporter.otlp.endpoint=http://otel-collector:4317 \
       -jar checkout.jar
[otel.javaagent 2026-08-10 12:01:03] - opentelemetry-javaagent - version: 2.11.0
[otel.javaagent 2026-08-10 12:01:04] - Auto-instrumentation for: [jdbc, spring-web, tomcat, kafka-clients]
[otel.javaagent 2026-08-10 12:01:04] - Exporting spans via OTLP gRPC to http://otel-collector:4317
```

### 3.2 Python — el wrapper + monkey-patch

`opentelemetry-instrument` es un lanzador. Corre un bootstrap estilo `sitecustomize` que importa OTel y hace monkey-patch de los módulos de librería (`requests`, `flask`, `psycopg2`) para que sus llamadas emitan spans. `opentelemetry-bootstrap` detecta qué librerías tenés instaladas y baja los paquetes de instrumentación correspondientes.

```console
$ pip install opentelemetry-distro opentelemetry-exporter-otlp
$ opentelemetry-bootstrap -a install          # installs instrumentation libs for detected deps
$ OTEL_SERVICE_NAME=cart \
  OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318 \
  OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf \
  opentelemetry-instrument python app.py
Instrumenting: flask, requests, psycopg2
Exporting traces, metrics, logs to http://otel-collector:4318 (http/protobuf)
```

### 3.3 Node.js — el require hook

El module loader de Node se intercepta vía `--require`. El hook registrado (`@opentelemetry/auto-instrumentations-node/register`) parchea el `require` de CommonJS y el `import` de ESM para que las llamadas a los frameworks queden envueltas.

```console
$ npm install @opentelemetry/api \
              @opentelemetry/auto-instrumentations-node
$ export OTEL_SERVICE_NAME=frontend
$ export OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318
$ node --require @opentelemetry/auto-instrumentations-node/register server.js
@opentelemetry/instrumentation-http Applying patch for http
@opentelemetry/instrumentation-express Applying patch for express@4.19.2
```

### 3.4 .NET — el CLR profiler

La auto-instrumentación de .NET registra un **CLR Profiler** (vía `CORECLR_ENABLE_PROFILING=1`, `CORECLR_PROFILER`, `CORECLR_PROFILER_PATH`). El profiler reescribe el IL en tiempo de JIT para insertar las llamadas de span. Sin recompilar tus assemblies.

### 3.5 Go — la excepción que confirma la regla

Go compila a un binario nativo estático con **sin VM, sin class loader, sin import hook** — así que el monkey-patching en runtime es imposible. Hay dos opciones de producción, ambas con restricciones reales:

- **Auto-instrumentación por eBPF** (`opentelemetry-go-instrumentation`): un *proceso/sidecar privilegiado separado* engancha uprobes de eBPF a las funciones de tu binario objetivo y reconstruye los spans desde el kernel. Requiere el path al ejecutable objetivo (`OTEL_GO_AUTO_TARGET_EXE`), capacidades elevadas (`CAP_SYS_ADMIN` / `privileged: true`), y `hostPID` en algunos setups.
- **Instrumentación en tiempo de compilación:** weaving en el código fuente/build.

Consecuencia para la plataforma: **Go no puede auto-instrumentarse con simples variables de entorno como Java/Python/Node.** El Operator inyecta la instrumentación de Go como un sidecar privilegiado, no como un init container que copia un agente (§7.4). Para la mayoría de las tiendas Go, **la instrumentación manual es el default pragmático**.

---

## 4. Instrumentation libraries vs. instrumentación nativa

Una **instrumentation library** es un shim que produce telemetría *para una librería que no le pertenece* — por ej. `opentelemetry-instrumentation-requests` le enseña al paquete `requests`, que no lo sabe, a emitir spans de cliente HTTP. Los agentes zero-code son, por debajo, orquestadores que cargan un conjunto de estas librerías.

La **instrumentación nativa (natural)** es cuando una librería emite telemetría de OTel por sí misma, dependiendo directamente de la **API** de OTel (nunca del SDK — una librería no debe forzar un SDK a sus consumidores). La distinción que quiere el examen:

| | Instrumentation library | Instrumentación nativa |
|--|-------------------------|------------------------|
| Quién es dueño del código de telemetría | OTel/comunidad, *fuera* de la lib objetivo | Los mantenedores de la librería, *adentro* |
| Dependencia agregada | Un paquete plugin extra | Nada — está integrado |
| Depende de | API de OTel (+ lógica de parcheo) | **Solo** la API de OTel |
| Riesgo de rotura al actualizar la lib | Mayor (el parche puede no coincidir con la nueva versión) | Ninguno (se mueve con la lib) |
| Disponibilidad hoy | Amplia | Escasa, en crecimiento |

**API vs SDK — el concepto que sostiene todo.** La **API** es la superficie que tu código (y las librerías) llaman para crear spans/métricas — por defecto es un *no-op*. El **SDK** es la implementación concreta que samplea, batchea y exporta. Una librería instrumenta contra la API para que, si la *app* nunca instala un SDK, la telemetría de la librería no cueste nada. Instrumentar = llamar a la API; **hacer que haga algo** = instalar y configurar el SDK.

---

## 5. Instrumentación manual (basada en código)

Acá es donde agregás el contexto que un agente genérico no puede conocer. Obtenés un `Tracer`/`Meter` del provider (configurado globalmente) y creás spans/mediciones alrededor de las operaciones de negocio.

### 5.1 Python — enriqueciendo un servicio auto-instrumentado

```python
from opentelemetry import trace, metrics
from opentelemetry.trace import Status, StatusCode

tracer = trace.get_tracer("checkout.service", "1.4.0")
meter  = metrics.get_meter("checkout.service", "1.4.0")

orders_total = meter.create_counter(
    "checkout.orders.completed",
    unit="1",
    description="Number of successfully completed orders",
)

def complete_order(order):
    # Child of the HTTP server span the auto-instrumentation already created.
    with tracer.start_as_current_span("complete_order") as span:
        span.set_attribute("order.id", order.id)
        span.set_attribute("order.items", len(order.items))
        span.set_attribute("tenant.tier", order.tenant.tier)   # business context
        try:
            charge(order)               # DB/HTTP spans appear automatically as children
            orders_total.add(1, {"tenant.tier": order.tenant.tier})
            span.set_status(Status(StatusCode.OK))
        except PaymentError as exc:
            span.record_exception(exc)
            span.set_status(Status(StatusCode.ERROR, str(exc)))
            raise
```

Como el SDK ya está cableado por la capa zero-code, este span encaja como hijo del span HTTP auto-generado, y cualquier llamada a DB/HTTP de `charge()` se captura como nieto — **un único trace coherente a partir de tres fuentes de instrumentación.**

### 5.2 Java — un span manual con el mismo agente corriendo

```java
import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.trace.*;

Tracer tracer = GlobalOpenTelemetry.getTracer("checkout.service", "1.4.0");

Span span = tracer.spanBuilder("complete_order")
        .setAttribute("order.id", order.id())
        .setAttribute("tenant.tier", order.tenant().tier())
        .startSpan();
try (Scope scope = span.makeCurrent()) {
    charge(order);                       // JDBC/HTTP spans auto-attach as children
} catch (PaymentException e) {
    span.recordException(e);
    span.setStatus(StatusCode.ERROR, e.getMessage());
    throw e;
} finally {
    span.end();
}
```

### 5.3 Propagación de contexto — por qué la instrumentación cose, no solo emite

Un span es inútil de forma aislada; el segundo trabajo de la instrumentación es **propagar el contexto** a través de los límites de proceso para que el hijo en el servicio B conozca a su padre en el servicio A. En el cable esto es el header W3C **`traceparent`** (y el opcional `baggage`). La auto-instrumentación lo inyecta/extrae por vos; cuando hacés una llamada saliente *manual* no debés anularlo. Configurá los propagadores explícitamente:

```console
$ export OTEL_PROPAGATORS=tracecontext,baggage
```

Un desajuste — el servicio A emitiendo `b3` mientras B solo extrae `tracecontext` — es la causa clásica de *broken traces* incluso cuando ambos servicios están "instrumentados."

---

## 6. Semantic conventions — el contrato que hace útil a la instrumentación

Una instrumentación que nombra las cosas de forma arbitraria produce telemetría que no podés consultar entre servicios. Las **semantic conventions** son los nombres y valores de atributos estandarizados de OpenTelemetry, para que cada lenguaje y librería coincidan en el vocabulario.

| Concepto | Atributo convencional (estable) |
|---------|-------------------------------|
| Método HTTP | `http.request.method` |
| Código de estado HTTP | `http.response.status_code` |
| Path de la URL | `url.path` |
| Dirección del servidor | `server.address` |
| Sistema de DB | `db.system.name` |
| Statement de DB | `db.query.text` |
| Identidad del servicio | `service.name`, `service.version` (Resource) |

`service.name` es especial: es un atributo de **Resource** (identifica al *productor*, no a un span individual) y es efectivamente obligatorio — sin él el backend etiqueta tus datos como `unknown_service`. Todas las capas zero-code lo setean desde `OTEL_SERVICE_NAME` / `OTEL_RESOURCE_ATTRIBUTES`.

> **Trampa de examen:** el atributo de interoperabilidad correcto para el estado HTTP es `http.response.status_code`, **no** `http.status_code` (el nombre viejo, previo a la estabilización). Seguir las convenciones es parte de instrumentar *correctamente*, no un lujo opcional.

---

## 7. Zero-code a escala de flota: el OpenTelemetry Operator

Para una flota de Kubernetes no horneás agentes en las imágenes ni editás 300 Dockerfiles. El **OpenTelemetry Operator** despacha un mutating admission webhook que, gobernado por una única annotation en el pod, inyecta el agente como un **init container** y setea las variables de entorno — en el momento de creación del pod, sin cambio de imagen.

### 7.1 Instalar el Operator (requiere cert-manager)

```console
$ kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
$ kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml
$ kubectl -n opentelemetry-operator-system get pods
NAME                                        READY   STATUS    RESTARTS   AGE
opentelemetry-operator-7c4f9d8b6d-2xk5p     2/2     Running   0          41s
```

### 7.2 Un Collector al que los agentes exporten (`v1beta1`)

```yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: otelcol
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
          http:
            endpoint: 0.0.0.0:4318
    processors:
      batch:
        send_batch_size: 8192
        timeout: 5s
      memory_limiter:
        check_interval: 1s
        limit_percentage: 80
        spike_limit_percentage: 25
    exporters:
      debug:
        verbosity: detailed
      otlp/tempo:
        endpoint: tempo.observability.svc:4317
        tls:
          insecure: true
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [debug, otlp/tempo]
        metrics:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [debug]
        logs:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [debug]
```

### 7.3 El custom resource `Instrumentation` (`v1alpha1`)

Este CR es la *política*: qué endpoint, qué sampler, qué propagadores, e imágenes de agente por lenguaje. Un solo CR puede servir a todo un namespace.

```yaml
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: fleet-instrumentation
  namespace: payments
spec:
  exporter:
    endpoint: http://otelcol-collector.observability.svc:4317
  propagators:
    - tracecontext
    - baggage
  sampler:
    type: parentbased_traceidratio
    argument: "0.25"                 # keep 25% of root traces, always keep children of sampled roots
  resource:
    addK8sUIDAttributes: true
  env:
    - name: OTEL_EXPORTER_OTLP_PROTOCOL
      value: grpc
  java:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:2.11.0
    resources:
      limits:
        cpu: 200m
        memory: 256Mi
  python:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-python:0.49b0
    env:
      - name: OTEL_EXPORTER_OTLP_PROTOCOL
        value: http/protobuf     # Python defaults to http/protobuf; override the grpc default above
  nodejs:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-nodejs:0.53.0
  dotnet:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-dotnet:1.9.0
  go:
    image: ghcr.io/open-telemetry/opentelemetry-go-instrumentation/autoinstrumentation-go:v0.19.0-alpha
```

### 7.4 Habilitar un workload con una annotation

La annotation va en el **pod template**, no en el metadata del Deployment. Semántica de valores: `"true"` → el único CR de este namespace; `"name"` → CR por nombre; `"ns/name"` → CR en otro namespace; `"false"` → omitir.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  namespace: payments
spec:
  replicas: 3
  selector:
    matchLabels: { app: checkout }
  template:
    metadata:
      labels: { app: checkout }
      annotations:
        instrumentation.opentelemetry.io/inject-java: "fleet-instrumentation"
        # Multi-container pod? pick the app container explicitly:
        instrumentation.opentelemetry.io/container-names: "checkout"
    spec:
      containers:
        - name: checkout
          image: registry.internal/checkout:1.4.0
          ports:
            - containerPort: 8080
```

Para **Go**, la annotation es `inject-go` y el pod además necesita el security context elevado que requiere el sidecar de eBPF:

```yaml
      annotations:
        instrumentation.opentelemetry.io/inject-go: "fleet-instrumentation"
        instrumentation.opentelemetry.io/otel-go-auto-target-exe: "/app/checkout"
```

### 7.5 Qué inyectó realmente el webhook

```console
$ kubectl -n payments get pod checkout-6b9f7c8d5-abcde -o jsonpath='{.spec.initContainers[*].name}'
opentelemetry-auto-instrumentation-java

$ kubectl -n payments get pod checkout-6b9f7c8d5-abcde \
    -o jsonpath='{range .spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}'
JAVA_TOOL_OPTIONS= -javaagent:/otel-auto-instrumentation-java/javaagent.jar
OTEL_SERVICE_NAME=checkout
OTEL_EXPORTER_OTLP_ENDPOINT=http://otelcol-collector.observability.svc:4317
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.25
OTEL_PROPAGATORS=tracecontext,baggage
OTEL_RESOURCE_ATTRIBUTES=k8s.pod.name=checkout-6b9f7c8d5-abcde,k8s.namespace.name=payments,...
```

El init container copió el JAR del agente en un `emptyDir` compartido (`/otel-auto-instrumentation-java`), el operator lo montó dentro del container de la app, y `JAVA_TOOL_OPTIONS` hace que la JVM lo levante — todo con la imagen de la aplicación intacta.

---

## 8. Verificación y diagnóstico de fallas

La instrumentación falla en silencio: la app corre bien, pero no llega ningún span. Diagnosticá de arriba hacia abajo a lo largo del camino **inyectar → emitir → propagar → exportar → recibir.**

### 8.1 ¿Fue el pod siquiera mutado?

```console
$ kubectl -n payments describe pod checkout-6b9f7c8d5-abcde | grep -A2 'Init Containers'
Init Containers:
  opentelemetry-auto-instrumentation-java:
    Image:  ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:2.11.0
```

Sin init container ⇒ el webhook no se disparó. Verificá, en orden:

```console
$ kubectl get mutatingwebhookconfiguration | grep opentelemetry     # webhook registered?
$ kubectl -n payments get instrumentation                           # CR exists in the pod's namespace?
NAME                     ENDPOINT                                              AGE
fleet-instrumentation    http://otelcol-collector.observability.svc:4317       6m

$ kubectl -n opentelemetry-operator-system logs deploy/opentelemetry-operator | grep -i inject
```

Causas más comunes: la annotation en el metadata del Deployment en lugar del **pod template**; `"true"` usado mientras hay cero o varios CRs en el namespace; el pod creado *antes* de que el CR existiera (recreálo — la inyección es solo en tiempo de admisión).

### 8.2 ¿Está emitiendo el agente?

```console
$ kubectl -n payments logs checkout-6b9f7c8d5-abcde -c checkout | head
[otel.javaagent 2026-08-10 12:14:22] - opentelemetry-javaagent - version: 2.11.0
[otel.javaagent 2026-08-10 12:14:23] - Auto-instrumentation for: [jdbc, spring-web, tomcat]
```

Silencio acá ⇒ el agente no está enganchado (verificá que `JAVA_TOOL_OPTIONS` esté seteado y no lo sobrescriba el propio env de la app).

### 8.3 ¿Está llegando algo al Collector?

Apuntá el pipeline al exporter `debug` y observá:

```console
$ kubectl -n observability logs deploy/otelcol-collector | grep -A6 'ResourceSpans'
2026-08-10T12:15:04Z info  ResourceSpans #0
Resource attributes:
     -> service.name: Str(checkout)
     -> k8s.namespace.name: Str(payments)
ScopeSpans #0
Span #0  Name: POST /api/checkout  Kind: SERVER  Status: STATUS_CODE_UNSET
```

Si el Collector está vacío, generá una señal conocida-buena para aislar app vs. pipeline:

```console
$ kubectl -n observability run telemetrygen --rm -it --restart=Never \
    --image=ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest -- \
    traces --otlp-insecure --otlp-endpoint otelcol-collector:4317 --traces 5
2026-08-10T12:16:10Z info generated 5 traces
```

Los test traces llegan pero los de la app no ⇒ el problema está en la app/agente, no en el Collector.

### 8.4 La trampa del protocolo/puerto

`OTEL_EXPORTER_OTLP_PROTOCOL=grpc` debe pegar en **4317**; `http/protobuf` debe pegar en **4318**. Java por defecto usa gRPC, Python por defecto usa `http/protobuf` — un CR de flota que hardcodea un protocolo va a descartar en silencio los datos del otro lenguaje. Síntoma: connection-refused o `UNAVAILABLE` en el log de la app:

```console
$ kubectl -n payments logs checkout-... -c checkout | grep -i 'export\|otlp'
[BatchSpanProcessor] Failed to export spans. Server responded UNAVAILABLE: endpoint 4318 (http) but exporter is grpc
```

### 8.5 Traces rotos/desconectados

Existen spans pero no se enlazan entre servicios ⇒ desajuste de **propagación**. Confirmá que cada servicio comparta un conjunto de propagadores:

```console
$ kubectl -n payments exec checkout-... -c checkout -- printenv OTEL_PROPAGATORS
tracecontext,baggage
```

Si un servicio fue instrumentado manualmente y se olvida de inyectar `traceparent` en las llamadas salientes, su downstream aparece como un nuevo trace raíz — el delatador span "huérfano" sin padre.

### 8.6 Checklist de verificación

| Verificación | Comando / señal | Resultado sano |
|-------|------------------|----------------|
| El webhook se disparó | `describe pod` → Init Containers | Init container del agente presente |
| El CR se resolvió | `kubectl get instrumentation -n <ns>` | Exactamente una coincidencia para `"true"` |
| El agente se enganchó | logs del container de la app | Línea `opentelemetry-javaagent - version:` |
| El env se inyectó | `printenv OTEL_SERVICE_NAME` | Nombre de servicio correcto (no `unknown_service`) |
| Coincidencia protocolo/puerto | proto del exporter vs puerto del receiver | grpc↔4317, http/protobuf↔4318 |
| El Collector recibe | logs del exporter `debug` | `ResourceSpans` con tu `service.name` |
| Pipeline vs app | span de prueba con `telemetrygen` | El de prueba llega ⇒ aislar a la app |
| Traces conectados | IDs de padre de span entre servicios | Sin raíces huérfanas; `OTEL_PROPAGATORS` compartido |

---

## 9. Referencias

- OpenTelemetry — Instrumentation (concepts): https://opentelemetry.io/docs/concepts/instrumentation/
- OpenTelemetry — Zero-code instrumentation: https://opentelemetry.io/docs/zero-code/
- OpenTelemetry — Instrumentation libraries: https://opentelemetry.io/docs/concepts/instrumentation/libraries/
- OpenTelemetry — Manual (code-based) instrumentation: https://opentelemetry.io/docs/concepts/instrumentation/code-based/
- OpenTelemetry — Semantic Conventions: https://opentelemetry.io/docs/specs/semconv/
- OpenTelemetry — Context propagation: https://opentelemetry.io/docs/concepts/context-propagation/
- W3C Trace Context specification: https://www.w3.org/TR/trace-context/
- OpenTelemetry Operator: https://github.com/open-telemetry/opentelemetry-operator
- Operator — auto-instrumentation injection: https://github.com/open-telemetry/opentelemetry-operator/blob/main/docs/api/instrumentations.md
- Java zero-code agent: https://opentelemetry.io/docs/zero-code/java/agent/
- Python zero-code: https://opentelemetry.io/docs/zero-code/python/
- Node.js zero-code: https://opentelemetry.io/docs/zero-code/js/
- .NET zero-code: https://opentelemetry.io/docs/zero-code/dotnet/
- Go eBPF auto-instrumentation: https://github.com/open-telemetry/opentelemetry-go-instrumentation
- OTLP exporter environment variables: https://opentelemetry.io/docs/specs/otel/protocol/exporter/
- `telemetrygen` utility: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/cmd/telemetrygen
- OTCA certification & curriculum: https://training.linuxfoundation.org/certification/opentelemetry-certified-associate-otca/