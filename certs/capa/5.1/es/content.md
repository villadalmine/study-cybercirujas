# Topic 5.1 — Argo Events

> **CAPA domain 5 · Exam weight: 20 %**
> Automatización orientada a eventos para Kubernetes. Este es uno de los dos dominios de mayor peso en el blueprint de CAPA, así que la profundidad aquí es deliberada: se espera que razones sobre el *grafo de dependencias*, el *event bus como sustrato de mensajería distribuida* y los *modos de fallo* — no solo que reconozcas un manifiesto de `Sensor`.

---

## 1. Motivación y el problema arquitectónico de producción

### 1.1 El vacío que llena Argo Events

Argo Workflows responde a "cómo ejecuto un DAG de contenedores hasta su finalización". **No** responde a "*cuándo* debería ejecutarse ese DAG, y *a causa de qué*". En una plataforma ingenua terminás con una proliferación de pegamento: una Lambda que golpea la API del Argo Server ante un evento de S3; un sidecar de cron sondeando un webhook; un controller a medida observando un `ConfigMap`; un bot de Slack invocando `kubectl create` por shell. Cada uno es un deployment aparte, un límite de autenticación aparte, un lugar aparte donde se filtran secretos, y una cosa aparte que falla en silencio a las 03:00.

Argo Events colapsa ese pegamento en **tres CRDs declarativas** y un **message bus durable**, todo corriendo dentro del cluster, todo reconciliado por controllers, todo observable a través de la misma superficie de Prometheus/`kubectl` que el resto de la plataforma.

```
   ┌────────────┐    CloudEvents    ┌───────────┐    subscribe   ┌──────────┐   trigger
   │ EventSource│ ────────────────▶ │ EventBus  │ ─────────────▶ │  Sensor  │ ────────▶  Workflow
   │  (adapter) │   publish (pub)   │ (NATS/JS) │   (sub)        │ (rules)  │            K8s obj
   └────────────┘                   └───────────┘                └──────────┘            HTTP / Lambda
        ▲                            durable, replicated              │  Kafka / Slack …
        │ external stimulus          (StatefulSet)                    │
   webhook · S3 · SQS · Kafka                                   dependency graph +
   calendar · GitHub · resource                                filters + parameters
```

Las tres responsabilidades están limpiamente separadas:

| CRD | Responsabilidad | Artefacto de runtime |
|---|---|---|
| **EventSource** | *Ingesta.* Adapta un estímulo externo (webhook, S3, Kafka, cron, un cambio de recurso de K8s…) a un **CloudEvent** y lo **publica** en el EventBus. | un `Deployment` (el "eventsource pod") |
| **EventBus** | *Transporte.* Un backbone de pub/sub durable y replicado que desacopla productores de consumidores y sobrevive a los reinicios del sensor. | un `StatefulSet` (NATS/JetStream) o un Kafka externo |
| **Sensor** | *Reacción.* **Se suscribe**, evalúa un **grafo de dependencias** con **filtros**, parametriza y dispara uno o más **triggers**. | un `Deployment` (el "sensor pod") |

### 1.2 Por qué un bus en el medio — el punto arquitectónico crucial

La decisión de diseño no obvia es el **EventBus** situado entre source y sensor. Podrías imaginar que el EventSource llama al Sensor directamente por HTTP. Argo Events deliberadamente no lo hace, y entender *por qué* es el corazón de este topic:

- **Desacople temporal / durabilidad.** Si el pod del Sensor está reiniciándose (deploy, OOM, node drain) cuando llega el evento, un push HTTP directo se perdería. Con un bus durable el evento se persiste y se entrega cuando el subscriber se reconecta — esto es lo que hace posible la semántica **`atLeastOnce`**.
- **Fan-out.** Un evento (`github push`) puede repartirse a N Sensors independientes (build, notify, audit) sin que el EventSource sepa que existen.
- **Joins multi-dependencia.** Un Sensor puede requerir `A AND B` donde A y B llegan con minutos de diferencia desde *distintas* sources. Ese join necesita un lugar para retener A mientras espera a B — el bus (más el estado interno del sensor) lo provee.
- **Back-pressure y control de flujo.** Los consumers de JetStream hacen ack de los mensajes; un Sensor lento no descarta eventos, se rezaga. Podés ver ese lag y alarmar sobre él.

El trade-off que estás comprando: un EventBus es **infraestructura con estado** (un StatefulSet de quórum de 3 réplicas con PVCs) que ahora tenés que operar, parchar y sobre el que tenés que razonar acerca de split-brain. Ese es el precio de la entrega exactamente-`atLeastOnce`.

### 1.3 El fallo de producción que esto previene

La caída clásica: se suponía que un upload a S3 iniciara un Workflow de ingesta, no lo hizo, y nadie lo notó durante seis horas porque la "Lambda de pegamento" se tragó un 5xx de la API de Argo y devolvió 200. En el modelo de Argo Events ese mismo camino es: pod de EventSource (con métricas de eventos leídos/enviados), EventBus (con métricas de consumer-lag), pod de Sensor (con `triggers_total` / `action_failed_total`), y cada salto es un objeto de Kubernetes al que podés hacer `describe` y una serie de Prometheus sobre la que podés alertar. El vacío silencioso se vuelve uno visible.

---

## 2. Comparaciones técnicas y trade-offs

### 2.1 Implementaciones de EventBus

El EventBus es enchufable. Elegir mal aquí es el arrepentimiento de producción más común, porque migrar un bus en el lugar es disruptivo.

| Implementación | Clave `spec.` | Entrega | Estado | Cuándo usarla | Cuidado con |
|---|---|---|---|---|---|
| **NATS Streaming (STAN)** | `nats.native` | at-least-once | StatefulSet + PVC | *Solo legacy.* | **Deprecado y EOL upstream.** No elegir para clusters nuevos. |
| **JetStream** | `jetstream` | at-least-once, con ack, replayable | StatefulSet + PVC, quórum RAFT | **Recomendación por defecto** para todas las instalaciones nuevas. | Necesita `replicas` impares (3/5) para el quórum; dimensionar el PVC para la retención. |
| **Kafka (externo)** | `kafka` | at-least-once | *Ya corrés Kafka* | Tenés un Kafka existente y operado y querés un único bus. | Argo no lo gestiona; el ciclo de vida de topics/ACL corre por tu cuenta. |

**Regla práctica:** cluster nuevo → `jetstream`, `replicas: 3`, volúmenes persistentes. Solo recurrí a `kafka` cuando Kafka ya existe como servicio de plataforma de primera clase.

### 2.2 EventSource vs. un adaptador ad-hoc

| Aspecto | EventSource | Controller / Lambda casero |
|---|---|---|
| Reconciliación | Deployment gestionado por controller, se auto-repara | Sos dueño del Deployment/ciclo de vida |
| Observabilidad | Métricas de Prometheus incorporadas, `kubectl describe` | Lo que hayas agregado |
| Auth al bus | Auth de EventBus gestionada (token/none) | Lo cableás vos |
| Formato de evento | CloudEvents 1.0 (portable) | JSON ad-hoc |
| Superficie de fallo | 1 CRD | N piezas móviles |

### 2.3 Tipos de trigger (lado Sensor)

| Trigger `template.*` | Propósito | `operation` / perillas típicas |
|---|---|---|
| `argoWorkflow` | Enviar/operar un Argo Workflow (de primera clase) | `submit`, `resubmit`, `retry`, `resume`, `suspend`, `terminate` |
| `k8s` | Crear/patchar/actualizar cualquier objeto de K8s genéricamente | `create`, `update`, `patch`, `delete` |
| `http` | Llamar a un endpoint HTTP arbitrario | method, url, payload, secure headers |
| `awsLambda` | Invocar una Lambda | region, function, creds |
| `kafka` | Producir a un topic de Kafka | url, topic, partition |
| `nats` / `pulsar` | Publicar a un sistema de mensajería | subject/topic |
| `slack` | Postear en Slack | channel, message |
| `azureEventHubs`, `openWhisk`, `log`, `custom` | Funciones cloud / debug / plugin gRPC | — |

`argoWorkflow` vs `k8s` para lanzar Workflows: preferí **`argoWorkflow`** — entiende operaciones específicas de Workflow (retry, resubmit, terminate) que un `k8s` create genérico no puede expresar, y nombra los Workflows con un sufijo generado para que eventos repetidos no colisionen.

### 2.4 Trade-off de semántica de entrega (relevante para el examen)

| Ajuste | Garantía | Costo |
|---|---|---|
| `sensor.spec.triggers[].atLeastOnce: false` (por defecto) | Trigger *como mucho una vez* por evento; ante un fallo ambiguo **no** se reintenta tras el ack | Un trigger genuinamente-ejecutado-pero-sin-ackear se descarta → posible ejecución **omitida** |
| `atLeastOnce: true` | El mensaje se re-entrega hasta que el trigger ackee éxito | Posible trigger **duplicado** → la acción destino debe ser **idempotente** |

No hay exactly-once. Elegís cuál fallo podés tolerar y diseñás el trigger en consecuencia (p. ej. nombrar el Workflow de forma determinista para que un submit duplicado sea un conflicto inofensivo).

---

## 3. Manifiestos completos e infraestructura (sin recortes)

### 3.1 Instalación

```bash
# Namespace + CRDs + controller + validating webhook
kubectl create namespace argo-events
kubectl apply -n argo-events \
  -f https://raw.githubusercontent.com/argoproj/argo-events/stable/manifests/install.yaml

# Optional but recommended: the validating admission webhook
kubectl apply -n argo-events \
  -f https://raw.githubusercontent.com/argoproj/argo-events/stable/manifests/install-validating-webhook.yaml
```

### 3.2 EventBus — JetStream, 3 réplicas, persistente (baseline de producción)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: EventBus
metadata:
  name: default            # the name 'default' is what EventSource/Sensor use implicitly
  namespace: argo-events
spec:
  jetstream:
    version: latest        # pin to a concrete tag in prod, e.g. 2.10.10
    replicas: 3            # odd number → RAFT quorum; survives one pod loss
    persistence:
      storageClassName: standard
      accessMode: ReadWriteOnce
      volumeSize: 10Gi
    # Stream retention: how long unacked/observed events are kept
    streamConfig: |
      maxAge: 72h
      maxBytes: 1GB
      replicas: 3
    metrics:
      enabled: true
    containerTemplate:
      resources:
        requests:
          cpu: 100m
          memory: 128Mi
        limits:
          cpu: "1"
          memory: 512Mi
```

### 3.3 EventSource — webhook (el "hola mundo" canónico de ingreso)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: EventSource
metadata:
  name: webhook
  namespace: argo-events
spec:
  # The controller creates a Service exposing these ports
  service:
    ports:
      - name: default
        port: 12000
        targetPort: 12000
  webhook:
    # 'orders' is the eventName that Sensors will reference
    orders:
      port: "12000"
      endpoint: /orders
      method: POST
```

### 3.4 EventSource — un bucket S3/Minio (ingesta del mundo real)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: EventSource
metadata:
  name: minio
  namespace: argo-events
spec:
  minio:
    landing-bucket:
      bucket:
        name: incoming
      endpoint: minio.storage.svc:9000
      events:
        - s3:ObjectCreated:Put
      filter:
        prefix: raw/
        suffix: .csv
      insecure: true
      accessKey:
        name: minio-creds
        key: accesskey
      secretKey:
        name: minio-creds
        key: secretkey
```

### 3.5 Sensor — trigger de producción completo: filtros + parámetros + policy + retry + rate-limit

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Sensor
metadata:
  name: order-processor
  namespace: argo-events
spec:
  template:
    serviceAccountName: operate-workflow-sa   # MUST be able to create Workflows (see RBAC)
  # Boolean dependency graph: this trigger fires only when the expression is true
  dependencies:
    - name: order-dep
      eventSourceName: webhook
      eventName: orders
      # Filters run inside the sensor BEFORE the trigger; a filtered-out event acks and is dropped
      filters:
        dataLogicalOperator: "and"
        data:
          - path: body.action
            type: string
            comparator: "="
            value:
              - "created"
          - path: body.amount
            type: number
            comparator: ">="
            value:
              - "100"
        exprs:
          - expr: 'region in ["us-east-1","us-west-2"]'
            fields:
              - name: region
                path: body.region
  triggers:
    - template:
        name: launch-order-workflow
        # conditions lets you compose multiple dependencies: "order-dep && audit-dep"
        conditions: "order-dep"
        argoWorkflow:
          operation: submit
          source:
            resource:
              apiVersion: argoproj.io/v1alpha1
              kind: Workflow
              metadata:
                generateName: process-order-   # generateName → duplicate-safe naming
              spec:
                serviceAccountName: workflow-runner
                entrypoint: main
                arguments:
                  parameters:
                    - name: order-id
                      value: PLACEHOLDER        # overwritten by parameters below
                    - name: amount
                      value: "0"
                templates:
                  - name: main
                    container:
                      image: ghcr.io/acme/order-processor:1.4.2
                      args: ["--order", "{{workflow.parameters.order-id}}",
                             "--amount", "{{workflow.parameters.amount}}"]
          # Inject event data into the Workflow at trigger time
          parameters:
            - src:
                dependencyName: order-dep
                dataKey: body.orderId
              dest: spec.arguments.parameters.0.value
            - src:
                dependencyName: order-dep
                dataKey: body.amount
              dest: spec.arguments.parameters.1.value
      # Retry the TRIGGER (not the Workflow) on transient failures firing it
      retryStrategy:
        steps: 3
        duration: 3s
        factor: 2.0
        jitter: 0.1
      # Cap how fast this trigger may fire
      rateLimit:
        unit: Second
        requestsPerUnit: 20
      # Consider the trigger successful only if the created Workflow reaches this state
      policy:
        k8s:
          labels:
            workflows.argoproj.io/phase: Succeeded
          backoff:
            duration: "3s"
            steps: 10
            factor: 2.0
          errorOnBackoffTimeout: true
```

### 3.6 RBAC — la causa más común de "silenciosamente no hace nada"

El pod de un Sensor usa su ServiceAccount para crear el objeto disparado. Si le falta el verbo, el trigger falla. Cablealo explícitamente:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: operate-workflow-sa
  namespace: argo-events
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: operate-workflow-role
  namespace: argo-events
rules:
  - apiGroups: ["argoproj.io"]
    resources: ["workflows", "workflowtemplates", "cronworkflows", "workflowtaskresults"]
    verbs: ["create", "get", "list", "watch", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: operate-workflow-binding
  namespace: argo-events
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: operate-workflow-role
subjects:
  - kind: ServiceAccount
    name: operate-workflow-sa
    namespace: argo-events
```

---

## 4. Comandos de CLI y salida real de terminal

### 4.1 Confirmar que el plano de control está arriba

```console
$ kubectl -n argo-events get deploy
NAME                             READY   UP-TO-DATE   AVAILABLE   AGE
argo-events-controller-manager   1/1     1            1           4m12s

$ kubectl -n argo-events get eventbus
NAME      TYPE        AGE
default   JetStream   3m2s

$ kubectl -n argo-events get statefulset
NAME                READY   AGE
eventbus-default-js 3/3     3m2s
```

### 4.2 Aplicar source + sensor y observar cómo aparecen los Deployments derivados

```console
$ kubectl apply -f eventsource-webhook.yaml
eventsource.argoproj.io/webhook created

$ kubectl apply -f sensor-order.yaml
sensor.argoproj.io/order-processor created

$ kubectl -n argo-events get pods -l 'controller in (eventsource-controller,sensor-controller)'
NAME                                        READY   STATUS    RESTARTS   AGE
webhook-eventsource-xxxxx-abcde             1/1     Running   0          25s
order-processor-sensor-yyyyy-fghij          1/1     Running   0          20s

$ kubectl -n argo-events get svc webhook-eventsource-svc
NAME                      TYPE        CLUSTER-IP      PORT(S)     AGE
webhook-eventsource-svc   ClusterIP   10.96.140.22    12000/TCP   30s
```

### 4.3 Disparar un evento y observar el trigger

```console
$ kubectl -n argo-events port-forward svc/webhook-eventsource-svc 12000:12000 &
$ curl -sS -X POST http://localhost:12000/orders \
    -H 'Content-Type: application/json' \
    -d '{"action":"created","orderId":"ORD-9001","amount":150,"region":"us-east-1"}'
success

$ kubectl -n argo-events get workflows
NAME                  STATUS      AGE
process-order-4t7xq   Running     3s

$ kubectl -n argo-events logs -l sensor-name=order-processor --tail=5
... level=info msg="succeeded to publish a message" ...
... level=info msg="Successfully processed trigger 'launch-order-workflow'" triggerType=ArgoWorkflow
```

### 4.4 Un evento filtrado: ackeado, descartado, sin trigger

```console
$ curl -sS -X POST http://localhost:12000/orders \
    -d '{"action":"created","orderId":"ORD-9002","amount":5,"region":"us-east-1"}'
success

$ kubectl -n argo-events logs -l sensor-name=order-processor --tail=3
... level=info msg="Applying filters on dependency 'order-dep'"
... level=info msg="event is filtered out" dependency=order-dep reason="data filter: body.amount >= 100 not satisfied"
```

Notá que se devolvió `success` al llamante — el EventSource acusa recibo; la decisión del *filtro* ocurre después, dentro del Sensor. Esta asimetría sorprende a la gente durante el diagnóstico.

---

## 5. Guía de verificación y diagnóstico de fallos

Trabajá la pipeline **de izquierda a derecha**; cada salto tiene su propia evidencia.

### 5.1 ¿Está sano el EventBus?

```console
$ kubectl -n argo-events describe eventbus default | sed -n '/Status/,$p'
Status:
  Config:
    Js:
      Auth:      token
      Url:       nats://eventbus-default-js-svc:4222
  Conditions:
    Type:      Deployed        Status: True
    Type:      ConfigMapReady   Status: True
```

- **¿Los 3 pods del StatefulSet Ready?** Un quórum de JetStream necesita una mayoría. `2/3` todavía sirve; `1/3` pierde el quórum y todo se detiene.
- **¿PVCs Bound?** `kubectl -n argo-events get pvc`. Un PVC sin bind → pods atascados en `Pending` → todo el bus caído.

### 5.2 ¿Está publicando de verdad el EventSource?

```console
$ kubectl -n argo-events logs deploy/webhook-eventsource --tail=20 | grep -i "started\|publish\|error"
... msg="starting webhook event source" eventName=orders port=12000
... msg="dispatching event on the data channel" eventSourceName=webhook eventName=orders
... msg="succeeded to publish an event to eventbus" eventName=orders
```

Si ves que la request llega pero **no hay** línea de "publish" → la source no puede alcanzar el bus (auth/red). Si nunca ves la request → problema de ingress/Service/puerto, no de Argo.

### 5.3 ¿Está el Sensor suscripto y evaluando?

```console
$ kubectl -n argo-events logs deploy/order-processor-sensor --tail=30
... msg="starting sensor" sensorName=order-processor
... msg="Subscribing to messages on the event bus" dependency=order-dep
... msg="received event"
... msg="Successfully processed trigger 'launch-order-workflow'"
```

Tabla de decisión:

| Síntoma en los logs del Sensor | Causa raíz | Solución |
|---|---|---|
| Sin línea `Subscribing…` | El Sensor no puede alcanzar el EventBus | verificar EventBus `Deployed=True`, network policy |
| `received event` y luego **nada** | evento filtrado silenciosamente | inspeccionar `filters`; verificar el `path` del JSON (es `body.x`, no `x`) |
| `Failed to execute a trigger` `... is forbidden` | **RBAC** — a la SA le falta el verbo | otorgar el Role en §3.6 |
| `dependency not found` / nunca dispara | discordancia de `eventSourceName`/`eventName` | deben coincidir exactamente con el metadata del EventSource y el nombre de la *clave* |
| El trigger dispara **dos veces** por evento | `atLeastOnce: true` + destino no idempotente | hacer el destino idempotente (`generateName`/nombre determinista) |

### 5.4 Probar directamente la hipótesis de RBAC

```console
$ kubectl -n argo-events auth can-i create workflows \
    --as=system:serviceaccount:argo-events:operate-workflow-sa
yes
```

Un `no` aquí es tu respuesta — el pod del Sensor recibirá un 403 del API server en el momento en que intente enviar, y el trigger falla con un mensaje `forbidden`.

### 5.5 Métricas sobre las que alertar

- EventSource: `argo_events_event_processing_duration_milliseconds`, `argo_events_events_sent_total` (debería trepar con la carga).
- Sensor: `argo_events_action_triggered_total`, `argo_events_action_failed_total` (alertar sobre la tasa de fallos), `argo_events_action_duration_milliseconds`.
- EventBus (JetStream): **pending/lag** del consumer — un backlog creciente significa que el Sensor no puede seguir el ritmo o está en crash-loop.

### 5.6 El checklist de "todo se ve en verde pero nada corre"

1. `kubectl get eventbus` → `Deployed: True`, StatefulSet en quórum completo.
2. Los logs del EventSource muestran `succeeded to publish`.
3. Los logs del Sensor muestran `Subscribing…` **y** `received event`.
4. Si se recibió pero no hay trigger → son los **filters** (99 % un `path` equivocado) o la expresión de **`conditions`**.
5. Si se intentó el trigger pero falló → es **RBAC** o que el objeto destino es inválido.
6. Discordancia de `atLeastOnce` → duplicados o descartes; alineá la semántica con la idempotencia del destino.

---

## 6. Referencias

- Argo Events — documentación oficial: https://argoproj.github.io/argo-events/
- Argo Events — repositorio de GitHub y manifiestos de instalación: https://github.com/argoproj/argo-events
- Concepts (EventSource / Sensor / EventBus): https://argoproj.github.io/argo-events/concepts/architecture/
- EventBus (NATS / JetStream / Kafka): https://argoproj.github.io/argo-events/eventbus/eventbus/
- Sensor triggers: https://argoproj.github.io/argo-events/sensors/triggers/argo-workflow/
- Sensor filters: https://argoproj.github.io/argo-events/sensors/filters/intro/
- Trigger retries, rate-limit & policy: https://argoproj.github.io/argo-events/sensors/trigger-conditions/
- CloudEvents specification (formato del sobre de evento): https://cloudevents.io/
- CAPA curriculum (blueprint del examen): https://raw.githubusercontent.com/cncf/curriculum/master/capa/README.md
- Argo Project (proyecto graduado de la CNCF): https://argoproj.github.io/