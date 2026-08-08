# Ejercicios guiados — Tema 5.4: AI/ML Integration in Platform Automation

> **Certificación:** CNPA (Certified Cloud Native Platform Engineering Associate) · versión 2025-04-01
> **Dominio 5 · Tema 5.4** · Peso en examen: 2.0
> **Fuente base:** [CNPA Curriculum (CNCF)](https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf)

Estos ejercicios asumen un cluster de práctica con acceso `cluster-admin`, `kubectl` ≥ 1.29 y `helm` ≥ 3.14. Los pasos que requieren GPU física están marcados; donde no dispongas de hardware acelerador podés seguir la mecánica sobre el `nvidia.com/gpu` que expone el device plugin en modo *fake* o razonar la salida esperada. Trabajaremos las cuatro capas donde AI/ML toca a la plataforma: **provisión de aceleradores**, **serving de modelos como capability**, **autoscaling dirigido por señales de inferencia** y **AIOps con remediación automatizada**.

---

## Ejercicio 1 — Exponer aceleradores GPU como recurso de la plataforma

**Objetivo:** entender cómo el platform team convierte una GPU en un recurso *schedulable* (`nvidia.com/gpu`) mediante el **device plugin framework**, cómo se etiquetan los nodos con **Node Feature Discovery (NFD)** y cómo se sobresuscribe una GPU con **time-slicing** para workloads de inferencia livianos.

### Pasos

1. Inspeccioná qué recursos extendidos anuncia un nodo. En un cluster sin operator de GPU, `nvidia.com/gpu` no aparece: el kubelet solo conoce `cpu`, `memory`, `ephemeral-storage` y `pods`.

   ```bash
   kubectl get nodes -o json \
     | jq '.items[].status.capacity | keys'
   ```

   Salida esperada (nodo aún sin device plugin):

   ```json
   [
     "cpu",
     "ephemeral-storage",
     "hugepages-2Mi",
     "memory",
     "pods"
   ]
   ```

2. Instalá el **NVIDIA GPU Operator**, que despliega en cadena: NFD, el driver, el `nvidia-container-toolkit`, el **device plugin** (que hace `Register()` contra el socket del kubelet en `/var/lib/kubelet/device-plugins/`) y el DCGM exporter para métricas.

   ```bash
   helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
   helm repo update
   helm install --wait gpu-operator nvidia/gpu-operator \
     -n gpu-operator --create-namespace \
     --set driver.enabled=true
   ```

3. Verificá que el device plugin quedó corriendo como DaemonSet y que el nodo ahora anuncia GPUs:

   ```bash
   kubectl -n gpu-operator get ds nvidia-device-plugin-daemonset
   kubectl get node <NODE> -o jsonpath='{.status.allocatable.nvidia\.com/gpu}{"\n"}'
   ```

   Salida esperada:

   ```
   NAME                             DESIRED   CURRENT   READY   NODE SELECTOR
   nvidia-device-plugin-daemonset   1         1         1       ...
   1
   ```

4. Confirmá las labels que puso NFD sobre el nodo (el scheduler y los `nodeSelector`/`nodeAffinity` de tus workloads dependen de ellas):

   ```bash
   kubectl get node <NODE> -o json \
     | jq '.metadata.labels | with_entries(select(.key|test("nvidia|feature.node")))'
   ```

   Salida (recortada) esperada:

   ```json
   {
     "feature.node.kubernetes.io/pci-10de.present": "true",
     "nvidia.com/gpu.product": "NVIDIA-A100-SXM4-40GB",
     "nvidia.com/gpu.count": "1",
     "nvidia.com/gpu.memory": "40960"
   }
   ```

5. Lanzá un pod que **solicite una GPU**. Un recurso extendido solo puede ir en `limits` (Kubernetes copia el valor a `requests` automáticamente), siempre en enteros, nunca `overcommitteable`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: gpu-smi
     namespace: default
   spec:
     restartPolicy: OnFailure
     containers:
       - name: cuda
         image: nvidia/cuda:12.4.1-base-ubuntu22.04
         command: ["nvidia-smi"]
         resources:
           limits:
             nvidia.com/gpu: 1     # entero; no admite "500m"
   ```

   ```bash
   kubectl apply -f gpu-smi.yaml
   kubectl logs gpu-smi
   ```

   Salida esperada (recortada):

   ```
   +-----------------------------------------------------------------------------+
   | NVIDIA-SMI 550.54.15    Driver Version: 550.54.15    CUDA Version: 12.4      |
   |   0  NVIDIA A100-SXM4-40GB   On  |  00000000:07:00.0 Off |                  0 |
   +-----------------------------------------------------------------------------+
   ```

6. **Time-slicing** para inferencia: una A100 sirviendo modelos pequeños queda ociosa. Configurá el device plugin para anunciar 4 "réplicas" lógicas de cada GPU física. Aplicá el ConfigMap y referencialo desde el `ClusterPolicy` del operator:

   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: time-slicing-config
     namespace: gpu-operator
   data:
     any: |-
       version: v1
       sharing:
         timeSlicing:
           replicas: 4
   ```

   ```bash
   kubectl apply -f time-slicing-config.yaml
   kubectl patch clusterpolicy/cluster-policy \
     -n gpu-operator --type merge \
     -p '{"spec":{"devicePlugin":{"config":{"name":"time-slicing-config","default":"any"}}}}'
   # tras el rollout del device plugin:
   kubectl get node <NODE> -o jsonpath='{.status.allocatable.nvidia\.com/gpu}{"\n"}'
   ```

   Salida esperada:

   ```
   4
   ```

> **Preguntas de comprensión (1)**
>
> **P1.1** ¿Por qué `nvidia.com/gpu` solo se acepta en `limits` y no puede expresarse como fracción (`0.5`), mientras que la CPU sí admite `500m`?
> **P1.2** El nodo ahora anuncia `4` GPUs allocatable tras el time-slicing, pero físicamente hay **una**. ¿Qué aislamiento *no* te da el time-slicing frente a **MIG (Multi-Instance GPU)**, y qué riesgo introduce para un workload de inferencia con SLO estricto?
> **P1.3** ¿Qué rol cumple NFD en el pipeline y por qué el platform team prefiere `nodeAffinity` sobre `feature.node.kubernetes.io/pci-10de.present` en vez de fijar un `nodeName`?

---

## Ejercicio 2 — Servir un modelo como capability con KServe (`InferenceService`)

**Objetivo:** desplegar un modelo detrás de un `InferenceService`, comprender el **data plane V2 (Open Inference Protocol)**, el **scale-to-zero** vía Knative y un **canary rollout** por porcentaje de tráfico — el patrón "model serving as a self-service platform capability".

### Pasos

1. Verificá que KServe y sus dependencias (Knative Serving, cert-manager, una ingress class) estén instalados y que existan los `ClusterServingRuntime` por defecto:

   ```bash
   kubectl get clusterservingruntimes
   ```

   Salida esperada (recortada):

   ```
   NAME                   DISABLED   MODELTYPE    AGE
   kserve-sklearnserver              sklearn      3d
   kserve-tritonserver               tensorrt     3d
   kserve-huggingfaceserver          huggingface  3d
   ```

2. Creá el namespace y desplegá un `InferenceService`. No especificás imagen ni runtime: KServe lo **resuelve** a partir del `modelFormat`.

   ```yaml
   apiVersion: serving.kserve.io/v1beta1
   kind: InferenceService
   metadata:
     name: sklearn-iris
     namespace: ml-serving
   spec:
     predictor:
       minReplicas: 0            # habilita scale-to-zero
       scaleTarget: 10
       scaleMetric: concurrency
       model:
         modelFormat:
           name: sklearn
         storageUri: "gs://kfserving-examples/models/sklearn/1.0/model"
   ```

   ```bash
   kubectl create namespace ml-serving
   kubectl apply -f sklearn-iris.yaml
   kubectl get inferenceservice sklearn-iris -n ml-serving
   ```

   Salida esperada:

   ```
   NAME           URL                                          READY   AGE
   sklearn-iris   http://sklearn-iris.ml-serving.example.com   True    90s
   ```

3. Realizá una predicción. Guardá el host lógico y armá el request contra el ingress gateway:

   ```bash
   cat <<EOF > iris-input.json
   { "instances": [ [6.8, 2.8, 4.8, 1.4], [6.0, 3.4, 4.5, 1.6] ] }
   EOF

   SERVICE_HOSTNAME=$(kubectl get inferenceservice sklearn-iris -n ml-serving \
     -o jsonpath='{.status.url}' | cut -d "/" -f 3)

   curl -s -H "Host: ${SERVICE_HOSTNAME}" -H "Content-Type: application/json" \
     "http://${INGRESS_HOST}:${INGRESS_PORT}/v1/models/sklearn-iris:predict" \
     -d @iris-input.json
   ```

   Salida esperada:

   ```json
   {"predictions":[1,1]}
   ```

4. Observá el **scale-to-zero**. Sin tráfico, Knative retira el pod del predictor tras el `stable-window` (60 s por defecto). El siguiente request sufre un **cold start**:

   ```bash
   # esperá ~90s sin enviar tráfico
   kubectl get pods -n ml-serving -l serving.kserve.io/inferenceservice=sklearn-iris
   # No resources found  ->  escaló a cero
   ```

   Salida esperada tras el idle:

   ```
   No resources found in ml-serving namespace.
   ```

5. **Canary rollout.** Publicá una nueva versión del modelo y enviá solo el 20 % del tráfico a ella. KServe mantiene el revision anterior recibiendo el 80 %:

   ```yaml
   apiVersion: serving.kserve.io/v1beta1
   kind: InferenceService
   metadata:
     name: sklearn-iris
     namespace: ml-serving
   spec:
     predictor:
       canaryTrafficPercent: 20
       minReplicas: 0
       model:
         modelFormat:
           name: sklearn
         storageUri: "gs://kfserving-examples/models/sklearn/1.0/model-v2"
   ```

   ```bash
   kubectl apply -f sklearn-iris-canary.yaml
   kubectl get inferenceservice sklearn-iris -n ml-serving \
     -o jsonpath='{.status.components.predictor.traffic}{"\n"}'
   ```

   Salida esperada (dos revisions, tráfico repartido):

   ```
   [{"latestRevision":true,"percent":20,"revisionName":"sklearn-iris-predictor-00002"},
    {"latestRevision":false,"percent":80,"revisionName":"sklearn-iris-predictor-00001"}]
   ```

> **Preguntas de comprensión (2)**
>
> **P2.1** El `InferenceService` no declara `image` ni `command`. ¿Qué componente de KServe decide qué contenedor arranca, y en base a qué campo del spec?
> **P2.2** `minReplicas: 0` es atractivo para modelos poco usados pero peligroso para un endpoint con SLO de latencia p99. Explicá el trade-off del **cold start** y una mitigación que preserve costo (pista: pensá en `minReplicas` vs. una réplica *warm* dedicada, y en el tamaño de la imagen del runtime).
> **P2.3** En el canary, ¿por qué KServe puede repartir tráfico 20/80 sin un service mesh explícito de tu parte? ¿Qué capa lo implementa por debajo?

---

## Ejercicio 3 — Autoscaling dirigido por señales de inferencia con KEDA

**Objetivo:** ir más allá del HPA por CPU. Escalar un predictor según una **métrica de negocio de inferencia** (profundidad de cola / request rate expuesta a Prometheus) usando **KEDA**, el patrón de *event-driven autoscaling* que la plataforma ofrece a los equipos de ML.

### Pasos

1. Confirmá que el predictor expone métricas y que Prometheus las scrapea. Los runtimes de KServe publican, entre otras, un contador de requests:

   ```bash
   kubectl -n ml-serving port-forward svc/sklearn-iris-predictor 8080:80 &
   curl -s localhost:8080/metrics | grep -E '^request_(count|latency)'
   ```

   Salida esperada (recortada):

   ```
   request_count{model_name="sklearn-iris",...} 1024
   request_latency_bucket{le="0.05",...} 990
   ```

2. Desplegá un `ScaledObject` de KEDA que consulte a Prometheus. Escalamos por **request rate**: sobre 100 req/s por réplica, KEDA agrega pods; el escalado a cero lo delega Knative/KServe, así que acá fijamos `minReplicaCount: 1` para el data plane V2 desplegado en modo *raw*.

   ```yaml
   apiVersion: keda.sh/v1alpha1
   kind: ScaledObject
   metadata:
     name: sklearn-iris-scaler
     namespace: ml-serving
   spec:
     scaleTargetRef:
       apiVersion: apps/v1
       kind: Deployment
       name: sklearn-iris-predictor
     minReplicaCount: 1
     maxReplicaCount: 10
     cooldownPeriod: 120
     advanced:
       horizontalPodAutoscalerConfig:
         behavior:
           scaleDown:
             stabilizationWindowSeconds: 300   # evita flapping tras picos
     triggers:
       - type: prometheus
         metadata:
           serverAddress: http://prometheus.monitoring.svc:9090
           threshold: "100"
           query: |
             sum(rate(request_count{model_name="sklearn-iris"}[1m]))
   ```

   ```bash
   kubectl apply -f sklearn-iris-scaler.yaml
   kubectl get scaledobject -n ml-serving
   kubectl get hpa -n ml-serving        # KEDA crea el HPA subyacente
   ```

   Salida esperada:

   ```
   NAME                  SCALETARGETKIND      MIN   MAX   READY   ACTIVE
   sklearn-iris-scaler   apps/v1.Deployment   1     10    True    False
   NAME                             REFERENCE                  TARGETS       MINPODS   MAXPODS
   keda-hpa-sklearn-iris-scaler     Deployment/sklearn-iris    12/100 (avg)  1         10
   ```

3. Generá carga y observá el escalado. Con `hey` o un bucle de `curl`, empujá la request rate por encima del threshold:

   ```bash
   hey -z 60s -c 50 -H "Host: ${SERVICE_HOSTNAME}" -m POST \
     -D iris-input.json \
     "http://${INGRESS_HOST}:${INGRESS_PORT}/v1/models/sklearn-iris:predict"

   watch -n5 'kubectl get pods -n ml-serving \
     -l serving.kserve.io/inferenceservice=sklearn-iris'
   ```

   Salida esperada durante el pico:

   ```
   NAME                                       READY   STATUS    RESTARTS
   sklearn-iris-predictor-6c9f...-2k4dq       2/2     Running   0
   sklearn-iris-predictor-6c9f...-8xn7p       2/2     Running   0
   sklearn-iris-predictor-6c9f...-p5wqz       2/2     Running   0
   ```

> **Preguntas de comprensión (3)**
>
> **P3.1** KEDA no reemplaza al HPA: lo *crea y alimenta*. Describí el rol de cada uno (quién decide el número de réplicas, quién traduce la métrica externa).
> **P3.2** Para inferencia sobre GPU con time-slicing (Ej. 1), escalar por `request rate` puede ser engañoso. ¿Qué métrica describe mejor la saturación real de un modelo servido — la que Knative usa por defecto — y por qué? (pista: `concurrency`).
> **P3.3** ¿Qué problema resuelve `stabilizationWindowSeconds: 300` en `scaleDown` para un workload de inferencia con arranque costoso, y qué costo introduce?

---

## Ejercicio 4 — AIOps: detección de anomalías con remediación automatizada

**Objetivo:** cerrar el loop de **AIOps**. Servir un modelo de detección de anomalías que evalúa métricas de la plataforma, y disparar **remediación automatizada** vía Argo Events → Argo Workflows cuando el modelo marca una anomalía — el patrón "AI in the operations control loop", con *human-in-the-loop* como guardrail.

### Pasos

1. Serví el modelo de anomalías como un `InferenceService` interno (mismo patrón del Ej. 2, formato PyTorch/ONNX). Un job periódico le pasa una ventana de métricas de Prometheus y publica el score:

   ```yaml
   apiVersion: serving.kserve.io/v1beta1
   kind: InferenceService
   metadata:
     name: anomaly-detector
     namespace: aiops
   spec:
     predictor:
       minReplicas: 1                   # endpoint de operaciones: siempre warm
       model:
         modelFormat:
           name: onnx
         storageUri: "s3://platform-models/anomaly/isoforest-v3"
   ```

2. Definí el **EventSource** y el **Sensor** de Argo Events. El EventSource recibe el webhook con el veredicto del modelo; el Sensor filtra por `score > 0.9` y lanza un Workflow de remediación:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Sensor
   metadata:
     name: anomaly-remediation
     namespace: aiops
   spec:
     dependencies:
       - name: anomaly-event
         eventSourceName: anomaly-webhook
         eventName: score
         filters:
           data:
             - path: body.score
               type: number
               comparator: ">="
               value: ["0.9"]
     triggers:
       - template:
           name: run-remediation
           k8s:
             operation: create
             source:
               resource:
                 apiVersion: argoproj.io/v1alpha1
                 kind: Workflow
                 metadata:
                   generateName: remediate-
                 spec:
                   entrypoint: cordon-and-notify
                   templates:
                     - name: cordon-and-notify
                       steps:
                         - - name: notify
                             template: slack-approval   # human-in-the-loop
                         - - name: drain-node
                             template: drain
                             when: "{{steps.notify.outputs.result}} == approved"
                     - name: slack-approval
                       # ... suspend + resume vía aprobación humana
                     - name: drain
                       container:
                         image: bitnami/kubectl:1.30
                         command: ["kubectl","drain","{{workflow.parameters.node}}",
                                   "--ignore-daemonsets","--delete-emptydir-data"]
   ```

   ```bash
   kubectl apply -f anomaly-sensor.yaml
   kubectl -n aiops get sensor,eventsource
   ```

   Salida esperada:

   ```
   NAME                                             AGE
   sensor.argoproj.io/anomaly-remediation           30s
   NAME                                             AGE
   eventsource.argoproj.io/anomaly-webhook          30s
   ```

3. Simulá una anomalía enviando un score alto al webhook y verificá que se creó el Workflow, **suspendido** esperando aprobación humana:

   ```bash
   curl -s -X POST http://anomaly-webhook.aiops.svc:12000/score \
     -H "Content-Type: application/json" \
     -d '{"score": 0.97, "node": "gpu-node-3", "signal": "gpu_ecc_errors"}'

   kubectl -n aiops get workflows
   ```

   Salida esperada:

   ```
   NAME              STATUS      AGE
   remediate-abcde   Running     8s     # suspendido en el step de aprobación
   ```

> **Preguntas de comprensión (4)**
>
> **P4.1** El Workflow se detiene en un step de aprobación humana antes de `kubectl drain`. ¿Por qué el *human-in-the-loop* es un guardrail crítico cuando la señal de disparo proviene de un modelo de ML, y no simplemente de un `PrometheusRule` con umbral fijo?
> **P4.2** El `anomaly-detector` usa `minReplicas: 1` mientras que el `sklearn-iris` del Ej. 2 usaba `minReplicas: 0`. Justificá la diferencia en términos del rol de cada endpoint.
> **P4.3** Este loop introduce un **riesgo de feedback**: el modelo podría marcar como anómalo el propio efecto de una remediación previa. Nombrá una salvaguarda de plataforma para evitar remediaciones en cascada.

---

## Ejercicio 5 — Golden path MLOps: desplegar un modelo por GitOps

**Objetivo:** cerrar el círculo tratando al modelo como artefacto versionado. El equipo de ML hace `git push`; Argo CD reconcilia el `InferenceService` — la integración de AI/ML dentro del **Internal Developer Platform** por el mismo mecanismo que cualquier otro workload.

### Pasos

1. La `Application` de Argo CD apunta a un repo que contiene el `InferenceService`. El `storageUri` incluye una **versión inmutable** del modelo (no `latest`):

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: fraud-model
     namespace: argocd
   spec:
     project: ml-platform
     source:
       repoURL: https://git.example.com/ml/fraud-serving
       targetRevision: main
       path: manifests/prod
     destination:
       server: https://kubernetes.default.svc
       namespace: ml-serving
     syncPolicy:
       automated:
         prune: true
         selfHeal: true
   ```

2. Promover un modelo nuevo = commit que cambia el `storageUri` a `s3://models/fraud/v7`. Argo CD detecta el drift y sincroniza:

   ```bash
   kubectl -n argocd get application fraud-model \
     -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
   ```

   Salida esperada tras el commit:

   ```
   Synced Healthy
   ```

> **Preguntas de comprensión (5)**
>
> **P5.1** ¿Por qué el `storageUri` debe apuntar a una versión inmutable del modelo y nunca a un tag mutable como `latest` en un flujo GitOps?
> **P5.2** ¿Qué le da GitOps a un rollback de modelo que un `kubectl apply` manual no garantiza?

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1

**P1.1** `nvidia.com/gpu` es un **extended resource**: el kubelet lo reporta como una cantidad entera de dispositivos discretos que el device plugin registró, y el scheduler los asigna de forma exclusiva (1:1) al contenedor. No son *compressible* ni *overcommitteable* como la CPU, que el kernel puede repartir por time-sharing en cuantos arbitrarios (`500m` = 0,5 núcleos de tiempo). Por eso solo se admiten enteros y solo en `limits`; Kubernetes copia el valor a `requests` para que `limit == request` y la QoS sea determinística. Una GPU no se "fracciona" a nivel de API: cualquier compartición (time-slicing, MIG, MPS) se resuelve *por debajo*, presentando al scheduler más unidades enteras.

**P1.2** El time-slicing **no da aislamiento de memoria ni de fallos**: las 4 réplicas lógicas comparten el mismo contexto físico y la misma VRAM, se turnan en el tiempo (round-robin del scheduler de la GPU) y un proceso puede agotar la memoria o colgar el device afectando a los otros tres. **MIG** sí particiona el hardware (SMs, cache L2 y memoria dedicados por instancia) con aislamiento de rendimiento y de fallo. El riesgo para un SLO estricto es el **noisy neighbor**: la latencia p99 de tu modelo depende de lo que hagan los co-tenants en la misma GPU; para SLO duro usá MIG o una GPU dedicada, y reservá el time-slicing para inferencia batch/best-effort.

**P1.3** NFD descubre las capacidades del hardware/kernel y las publica como **labels** (`feature.node.kubernetes.io/...`, y las `nvidia.com/gpu.*` que agrega el GPU Feature Discovery). Sirven para que los workloads expresen requisitos declarativos. Se prefiere `nodeAffinity` sobre una label porque describe *la propiedad requerida* ("necesito un nodo con GPU de tal familia") y deja que el scheduler elija cualquier nodo que la cumpla — resiliente ante reemplazo de nodos, escalado del cluster y drenajes. Fijar `nodeName` acopla el pod a una máquina concreta, rompe el scheduling, el bin-packing y la HA.

### Ejercicio 2

**P2.1** El **KServe controller** (webhook + reconciler). A partir de `spec.predictor.model.modelFormat.name` busca un `ClusterServingRuntime`/`ServingRuntime` que declare soportar ese formato (`supportedModelFormats`) y del que hereda imagen, args y el protocolo del data plane. El `storageUri` lo descarga el `storage-initializer` (un initContainer) al volumen del modelo. Así el equipo de ML declara *qué* servir, no *cómo*.

**P2.2** Con `minReplicas: 0` no hay pods entre requests: el primero paga el **cold start** = programar el pod + pull de imagen del runtime + `storage-initializer` bajando el modelo + carga en memoria/GPU, que puede ir de segundos a minutos y viola un p99 ajustado. Mitigaciones que preservan costo: mantener `minReplicas: 1` **solo** para los endpoints con SLO (una réplica warm) y dejar scale-to-zero para los de baja demanda; achicar la imagen del runtime y precachear el modelo en un volumen/nodo; usar `containerConcurrency` afinado para no sub-utilizar la réplica warm.

**P2.3** Porque KServe (en modo Serverless) se apoya en **Knative Serving**, que gestiona *revisions* inmutables y su reparto de tráfico a través del ingress/mesh subyacente (Istio/Kourier/Gateway API). El `canaryTrafficPercent` se traduce a un split de tráfico entre las revisions a nivel de esa capa de red; vos declarás el porcentaje y Knative programa el routing sin que tengas que escribir `VirtualService`/`HTTPRoute` a mano.

### Ejercicio 3

**P3.1** El **HPA** es quien efectivamente ajusta el `replicas` del Deployment; solo sabe leer métricas de la Metrics API (resource o external). **KEDA** actúa como *adaptador y activador*: se conecta a la fuente externa (Prometheus, Kafka, colas…), expone esa métrica a través de un `external.metrics.k8s.io` que él sirve, **crea y mantiene el HPA** apuntando a ella, y añade lo que el HPA no sabe hacer: **activación desde/hacia cero**. En régimen (≥1 réplica) el que decide el número es el HPA con la fórmula estándar; KEDA le da de comer la métrica de negocio.

**P3.2** `concurrency` — el número de requests **en vuelo simultáneas** por réplica. Es la métrica por defecto del Knative Pod Autoscaler y describe mejor la saturación porque una inferencia sobre GPU puede tener request rate baja pero cada request ocupa la GPU un tiempo largo: el cuello de botella es cuántas caben a la vez, no cuántas llegan por segundo. Un modelo lento a 10 req/s puede estar tan saturado como uno rápido a 1000 req/s; `concurrency` (o `rps` afinado con la latencia real) captura eso, `request rate` sola no.

**P3.3** Evita el **flapping**: tras un pico, la métrica cae y el HPA querría bajar réplicas de inmediato; si el tráfico rebota, se vuelve a pagar el arranque costoso (pull + carga del modelo en GPU). La ventana de estabilización de 300 s obliga a sostener la caída antes de escalar hacia abajo, amortiguando oscilaciones. El costo es **sobreaprovisionamiento temporal**: mantenés réplicas (y GPU) ociosas hasta 5 minutos después de que bajó la demanda real.

### Ejercicio 4

**P4.1** Un modelo de ML produce salidas **probabilísticas y no interpretables directamente**: puede dar falsos positivos por *drift* de datos, features fuera de distribución o un fenómeno legítimo raro que "parece" anómalo. A diferencia de un umbral fijo y auditable (`gpu_ecc_errors > N`), no podés razonar de antemano cada disparo. Como la acción (`drain`) es destructiva e irreversible en su efecto inmediato, el gate humano evita que un falso positivo del modelo drene un nodo sano; el operador aporta el contexto que el modelo no tiene y convierte el loop en *human-in-the-loop* en vez de *fully autonomous*.

**P4.2** El `anomaly-detector` es un endpoint de **operaciones críticas**: debe evaluar métricas de forma continua/periódica, y un cold start retrasaría la detección justo cuando hay un incidente en curso — por eso `minReplicas: 1` (siempre warm). El `sklearn-iris` del Ej. 2 es un ejemplo de baja demanda donde optimizar costo con scale-to-zero es aceptable porque un cold start ocasional no rompe un SLO de operaciones.

**P4.3** Varias válidas: (a) un **cooldown / silence window** por nodo o por tipo de remediación, que suprime nuevas acciones sobre el mismo target por un período tras remediar; (b) excluir de la ventana de features del modelo las señales generadas por la propia remediación (marcar el nodo con una anotación que el pipeline ignore); (c) un **rate limit / circuit breaker** de acciones automáticas por unidad de tiempo; (d) el propio gate humano del P4.1. Todas rompen el lazo de realimentación positiva que produciría remediaciones en cascada.

### Ejercicio 5

**P5.1** GitOps exige que el **estado deseado sea reproducible desde el commit**. Un tag mutable como `latest` significa que el mismo manifiesto puede resolver a artefactos distintos en el tiempo: dos syncs del mismo commit desplegarían modelos diferentes, se pierde la trazabilidad "qué modelo estuvo en prod" y un rollback de Git no restaura realmente el modelo anterior. Una versión inmutable (`v7`, o un digest por hash) hace que el commit sea la fuente de verdad completa: modelo + configuración quedan atados y auditables.

**P5.2** Un `git revert` restaura **exactamente** el estado desplegado anterior — manifiesto y `storageUri` inmutable — y Argo CD lo reconcilia de forma automática y verificable, con historial de quién cambió qué y cuándo. Un `kubectl apply` manual depende de que alguien conserve el YAML exacto de la versión previa (incluida la versión del modelo); si se perdió o difiere, el "rollback" reconstruye un estado que quizás nunca existió. GitOps te da rollback **atómico, auditable y con self-heal** frente a drift.

</details>

---

**Fuentes oficiales consultadas:**
- CNPA Curriculum — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- Kubernetes · Schedule GPUs — https://kubernetes.io/docs/tasks/manage-gpus/scheduling-gpus/
- Kubernetes · Device Plugins — https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/device-plugins/
- NVIDIA GPU Operator — https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/index.html
- Node Feature Discovery (Kubernetes SIG) — https://kubernetes-sigs.github.io/node-feature-discovery/
- KServe · InferenceService & Autoscaling — https://kserve.github.io/website/latest/
- Knative Serving · Autoscaling — https://knative.dev/docs/serving/autoscaling/
- KEDA · Prometheus Scaler — https://keda.sh/docs/latest/scalers/prometheus/
- Argo Events / Argo Workflows — https://argoproj.github.io/argo-events/ · https://argo-workflows.readthedocs.io/
- Argo CD · GitOps — https://argo-cd.readthedocs.io/