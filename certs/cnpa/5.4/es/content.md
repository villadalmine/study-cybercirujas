# Tema 5.4 — AI/ML Integration in Platform Automation

> Certificación: **CNPA** (Cloud Native Platform Engineering Associate) · Examen 2025-04-01 · Peso: **2.0**
> Perfil: SRE Senior / Platform Architect · Profundidad de producción

---

## 1. Motivación y el problema arquitectónico de producción

Una Internal Developer Platform (IDP) madura llega a un punto en el que el crecimiento del estado del sistema supera la capacidad del equipo de plataforma para operarlo con reglas escritas a mano. Los dos síntomas clásicos son **toil operacional que crece linealmente con la flota** (cada nuevo cluster, tenant o golden path añade alertas, umbrales y runbooks) y **fatiga de alertas** (miles de reglas estáticas cuyo umbral fue correcto el día que se escribió y nunca más). La integración de AI/ML en la automatización de plataforma existe para atacar ese límite, y se manifiesta en **dos ejes que se confunden constantemente y hay que separar**:

| Eje | Nombre en la industria | Qué automatiza | Ejemplos concretos |
|---|---|---|---|
| **AI *para* la plataforma** | AIOps | El *control loop* de operación de la propia plataforma | Predictive autoscaling, anomaly detection, forecasting de capacidad, root-cause analysis, remediación automática, self-service por lenguaje natural |
| **AI *sobre* la plataforma** | CNAI / MLOps golden path | La plataforma como *sustrato* de cargas AI/ML de los tenants | GPU scheduling, model serving (inference), batch training, feature stores, pipelines de MLOps ofrecidos como capability del IDP |

El examen CNPA evalúa la **intersección**: cómo el Platform Engineer expone AI/ML como una *capability* del IDP (eje 2) y cómo usa AI/ML para reducir el toil de operar ese IDP (eje 1). Kubernetes es el sustrato común porque ambos ejes necesitan lo mismo: scheduling declarativo, cuotas, aislamiento multi-tenant, y un control plane reconciliador sobre el que colgar controllers.

**El problema arquitectónico central** es que las dos propiedades que hacen valioso al ML —no-determinismo y adaptación— son exactamente las que rompen los principios de una plataforma: reproducibilidad, auditabilidad y GitOps. Un modelo que decide escalar o remediar es un actor no-determinista con permisos de mutación sobre producción. El diseño correcto no es "dejar que el modelo actúe", sino **insertar el juicio del modelo dentro de un pipeline que conserva las garantías de la plataforma**: dry-run, human-in-the-loop, remediación por Pull Request en vez de `kubectl apply` directo, y guardrails con RBAC de mínimo privilegio.

Fuentes: CNCF *Cloud Native Artificial Intelligence Whitepaper* (https://www.cncf.io/reports/cloud-native-artificial-intelligence-whitepaper/) y el CNPA Curriculum (https://github.com/cncf/curriculum).

---

## 2. Comparativas técnicas y trade-offs

### 2.1 Autoscaling reactivo vs. predictivo

El HPA nativo reacciona *después* de que la métrica cruza el umbral; para cargas con arranque lento (modelos de varios GB que tardan en cargar en GPU) o con picos correlacionados al reloj (batch nocturno, horario laboral), reaccionar tarde significa violar el SLO durante toda la ventana de warm-up.

| Enfoque | Mecanismo | Latencia de reacción | Riesgo | Cuándo usarlo |
|---|---|---|---|---|
| **HPA reactivo** (CPU/mem) | Métricas de resource | Segundos-minutos, *post-hoc* | Under-provision durante warm-up | Servicios stateless de arranque rápido |
| **KEDA reactivo** (event/queue) | Longitud de cola, métrica Prometheus | Igual, pero por evento real | Igual | Workers, colas, event-driven |
| **KEDA + cron** | Escala por horario fijo | Anticipada pero rígida | No se adapta a cambios de patrón | Picos deterministas (9:00 lun-vie) |
| **KEDA + predictkube** | Forecast ML de la serie temporal | *Anticipada* (predice el pico) | Falsos positivos → costo GPU | Cargas con estacionalidad e histórico ≥7d |
| **Custom metrics + external forecaster** | Modelo propio expuesto vía `metrics-api` | Anticipada, controlable | Complejidad operativa | Cuando ya existe un modelo de forecasting corporativo |

La práctica de producción es **combinar** un trigger predictivo (proactivo) con uno reactivo (piso de seguridad): KEDA toma el **máximo** de todos los triggers, así el forecast provisiona por adelantado y el reactivo cubre el error del modelo.

### 2.2 Detección de anomalías: reglas estáticas vs. ML

| Técnica | Herramienta | Coste | Falsos positivos | Explicabilidad |
|---|---|---|---|---|
| Umbral fijo | PrometheusRule | Nulo | Altos (umbral obsoleto) | Total |
| Forecast estadístico | `predict_linear`, `holt_winters` en PromQL | Nulo | Medios | Alta |
| Anomaly detection ML | Detector externo (isolation forest, LSTM) | Alto (infra + tuning) | Bajos si bien entrenado | Baja |
| LLM RCA sobre logs/traces | LLM + contexto de OTel | Coste por token | Variable | Media (razona en NL) |

Regla arquitectónica: **empezá por `predict_linear`** para capacity forecasting (disco, PVC, cuotas). Es gratis, explicable y cubre el 80% de los incidentes de agotamiento de recursos. Sube a ML sólo cuando la métrica es multi-estacional y no lineal.

### 2.3 Model serving (inference) sobre la plataforma

| Runtime | Modelo mental | Autoscaling | Multi-framework | Scale-to-zero |
|---|---|---|---|---|
| `Deployment` + contenedor propio | Manual, tú operás todo | HPA/KEDA manual | N/A | No sin extras |
| **KServe** | CRD `InferenceService` sobre Knative | Nativo (concurrency-based) | sklearn, PyTorch, HF, Triton, custom | **Sí** |
| **Seldon Core v2** | Grafo de inferencia (pipelines) | Nativo | Multi-framework | Sí |
| **BentoML/Yatai** | Empaquetado "bento" | Vía adapter | Multi-framework | Parcial |
| **NVIDIA Triton** | Servidor de inferencia GPU | Externo | ONNX/TensorRT/PyTorch | No nativo |

KServe es el default de facto en CNCF para exponer *model serving as a golden path*: scale-to-zero (crítico para el coste de GPU ociosa), canary por revisión y un `storage-initializer` que resuelve el modelo desde S3/GCS/PVC de forma declarativa.

### 2.4 GPU sharing: cómo repartir un acelerador caro

| Técnica | Aislamiento | Overhead | Granularidad | Falla de un tenant afecta a otro |
|---|---|---|---|---|
| **1 GPU = 1 pod** | Total | Nulo | Grueso (desperdicio) | No |
| **Time-slicing** | Ninguno (context-switch) | Bajo | N réplicas lógicas | **Sí** (sin memoria aislada) |
| **MPS** (Multi-Process Service) | Parcial (memoria compartida) | Bajo | Por proceso | Parcial |
| **MIG** (Multi-Instance GPU) | Hardware (A100/H100) | Nulo | Hasta 7 instancias | **No** (aislamiento HW) |
| **DRA** (Dynamic Resource Allocation) | Depende del driver | Bajo | Declarativa, fina | Depende |

Para inference de baja demanda en dev/test → **time-slicing** (barato, sin aislamiento). Para producción multi-tenant → **MIG** (aislamiento de memoria y fault por hardware). **DRA** (Dynamic Resource Allocation) alcanzó *beta* con structured parameters en Kubernetes 1.32 y es la dirección estratégica que reemplazará a los device plugins con una API declarativa de solicitud de dispositivos.

### 2.5 Batch scheduling para training

| Scheduler | Modelo | Gang scheduling | Cuotas jerárquicas | Encaje con Kubernetes |
|---|---|---|---|---|
| Default kube-scheduler | Pod a pod | No | No (sólo ResourceQuota) | Nativo |
| **Kueue** | Job-level queueing | Sí (vía workloads) | Sí (ClusterQueue/cohorts) | SIG-nativo, ligero |
| **Volcano** | Batch/HPC | Sí (PodGroup) | Sí | Reemplaza scheduler |
| **YuniKorn** | Multi-tenant batch | Sí | Sí (queues jerárquicas) | Reemplaza/coexiste |

Kueue es la opción CNCF recomendada cuando querés **quota-aware queueing sin reemplazar el scheduler**: suspende Jobs hasta que hay cuota, evitando el deadlock de un training distribuido que arranca la mitad de sus pods y espera para siempre a los otros.

---

## 3. Manifiestos completos de producción

### 3.1 Autoscaling predictivo con KEDA (predictkube + piso reactivo)

```yaml
# secret con la API key de PredictKube (Dysnix)
apiVersion: v1
kind: Secret
metadata:
  name: predictkube-secret
  namespace: ml-serving
type: Opaque
stringData:
  apiKey: "pk_live_REDACTED_ROTATE_ME"
---
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: keda-predictkube-auth
  namespace: ml-serving
spec:
  secretTargetRef:
    - parameter: apiKey
      name: predictkube-secret
      key: apiKey
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: llm-gateway-scaler
  namespace: ml-serving
spec:
  scaleTargetRef:
    name: llm-gateway          # Deployment objetivo
  minReplicaCount: 2           # nunca a cero: warm-up de GPU es caro
  maxReplicaCount: 30
  pollingInterval: 30          # segundos
  cooldownPeriod: 300
  advanced:
    horizontalPodAutoscalerConfig:
      behavior:
        scaleDown:
          stabilizationWindowSeconds: 300   # evita flapping tras un pico
          policies:
            - type: Percent
              value: 25
              periodSeconds: 60
  triggers:
    # Trigger 1: PREDICTIVO — provisiona por adelantado
    - type: predictkube
      metadata:
        predictHorizon: "2h"          # cuánto hacia el futuro predice
        historyTimeWindow: "7d"       # histórico de entrenamiento
        prometheusAddress: http://prometheus-server.monitoring.svc:80
        query: sum(rate(http_requests_total{service="llm-gateway"}[2m]))
        threshold: "50"               # req/s por réplica objetivo
      authenticationRef:
        name: keda-predictkube-auth
    # Trigger 2: REACTIVO — piso de seguridad si el modelo se equivoca
    - type: prometheus
      metadata:
        serverAddress: http://prometheus-server.monitoring.svc:80
        query: sum(rate(http_requests_total{service="llm-gateway"}[2m]))
        threshold: "80"
```

> KEDA crea y gestiona un HPA por debajo; el número de réplicas final es el **máximo** entre ambos triggers. El `stabilizationWindowSeconds` es imprescindible en GPU: sin él, el modelo predictivo puede oscilar y destruir pods a mitad de warm-up.

### 3.2 Model serving con KServe (LLM en GPU con scale-to-zero)

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: mistral-7b
  namespace: ml-serving
  annotations:
    serving.kserve.io/enable-metric-aggregation: "true"
spec:
  predictor:
    minReplicas: 0            # scale-to-zero: la GPU no cuesta si nadie infiere
    maxReplicas: 4
    scaleTarget: 10           # concurrencia objetivo por réplica
    scaleMetric: concurrency
    model:
      modelFormat:
        name: huggingface
      args:
        - --model_id=mistralai/Mistral-7B-Instruct-v0.2
        - --max_model_len=4096
      storageUri: "s3://models/mistral-7b/"
      resources:
        requests:
          cpu: "4"
          memory: 24Gi
          nvidia.com/gpu: "1"
        limits:
          nvidia.com/gpu: "1"
    tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
    nodeSelector:
      nvidia.com/gpu.product: NVIDIA-A100-SXM4-80GB
```

Credenciales de storage (patrón `storage-initializer`):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: s3-creds
  namespace: ml-serving
  annotations:
    serving.kserve.io/s3-endpoint: minio.storage.svc:9000
    serving.kserve.io/s3-usehttps: "0"
    serving.kserve.io/s3-region: us-east-1
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: "minio"
  AWS_SECRET_ACCESS_KEY: "REDACTED"
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: sa-model-store
  namespace: ml-serving
secrets:
  - name: s3-creds
```

### 3.3 GPU time-slicing con el NVIDIA GPU Operator

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: time-slicing-config
  namespace: gpu-operator
data:
  a100-4x: |-
    version: v1
    flags:
      migStrategy: none
    sharing:
      timeSlicing:
        renameByDefault: false
        failRequestsGreaterThanOne: true   # 1 GPU lógica = 1 slice, no más
        resources:
          - name: nvidia.com/gpu
            replicas: 4                     # 1 GPU física → 4 lógicas
```

Se activa parcheando la `ClusterPolicy` del operator:

```bash
$ kubectl patch clusterpolicy/cluster-policy \
    -n gpu-operator --type merge \
    -p '{"spec":{"devicePlugin":{"config":{"name":"time-slicing-config","default":"a100-4x"}}}}'
clusterpolicy.nvidia.com/cluster-policy patched
```

### 3.4 Batch training gobernado con Kueue

```yaml
apiVersion: kueue.x-k8s.io/v1beta1
kind: ResourceFlavor
metadata:
  name: gpu-a100
spec:
  nodeLabels:
    nvidia.com/gpu.product: NVIDIA-A100-SXM4-80GB
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: ClusterQueue
metadata:
  name: team-ml
spec:
  namespaceSelector: {}
  cohort: research          # comparte capacidad prestada con otras queues del cohort
  preemption:
    reclaimWithinCohort: Any
    withinClusterQueue: LowerPriority
  resourceGroups:
    - coveredResources: ["cpu", "memory", "nvidia.com/gpu"]
      flavors:
        - name: gpu-a100
          resources:
            - name: cpu
              nominalQuota: "100"
            - name: memory
              nominalQuota: 600Gi
            - name: nvidia.com/gpu
              nominalQuota: "16"
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: LocalQueue
metadata:
  name: default
  namespace: team-ml
spec:
  clusterQueue: team-ml
---
apiVersion: batch/v1
kind: Job
metadata:
  generateName: llama-finetune-
  namespace: team-ml
  labels:
    kueue.x-k8s.io/queue-name: default    # entra a la cola, no al scheduler directo
spec:
  parallelism: 8
  completions: 8
  suspend: true                            # Kueue lo despausará al admitir cuota
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: trainer
          image: registry.example.com/ml/llama-finetune:1.4.0
          resources:
            requests:
              cpu: "8"
              memory: 64Gi
              nvidia.com/gpu: "1"
            limits:
              nvidia.com/gpu: "1"
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
```

> El `suspend: true` es el contrato con Kueue: el Job nace pausado y sólo arranca cuando hay cuota para **los 8 pods a la vez** (gang), evitando el deadlock de un training distribuido a medio arrancar.

### 3.5 Capacity forecasting sin ML: `predict_linear` como línea base

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: capacity-forecast
  namespace: monitoring
  labels:
    release: prometheus
spec:
  groups:
    - name: forecasting.rules
      rules:
        # Predice si el PVC se llena en las próximas 6 horas según tendencia lineal
        - alert: PVCWillFillIn6h
          expr: |
            predict_linear(
              kubelet_volume_stats_available_bytes{namespace="ml-serving"}[6h], 6*3600
            ) < 0
          for: 15m
          labels:
            severity: warning
            team: platform
          annotations:
            summary: "PVC {{ $labels.persistentvolumeclaim }} se llenará en <6h"
            runbook: "https://runbooks.example.com/pvc-forecast"
        # GPU quota del cohort agotándose por tendencia de admisión
        - alert: GPUQuotaExhaustionForecast
          expr: |
            predict_linear(
              kueue_cluster_queue_resource_usage{resource="nvidia.com/gpu"}[3h], 2*3600
            )
            > on(cluster_queue) kueue_cluster_queue_nominal_quota{resource="nvidia.com/gpu"}
          for: 10m
          labels:
            severity: warning
```

### 3.6 Remediación AIOps con human-in-the-loop (Argo Events → Workflow → PR)

Patrón que preserva GitOps: la alerta **no** aplica cambios; genera un Pull Request que un humano aprueba.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Sensor
metadata:
  name: aiops-remediation
  namespace: argo-events
spec:
  dependencies:
    - name: alertmanager-dep
      eventSourceName: alertmanager-webhook
      eventName: firing
  triggers:
    - template:
        name: propose-remediation
        argoWorkflow:
          operation: submit
          source:
            resource:
              apiVersion: argoproj.io/v1alpha1
              kind: Workflow
              metadata:
                generateName: remediate-
              spec:
                entrypoint: analyze-and-pr
                serviceAccountName: aiops-remediator   # RBAC de mínimo privilegio
                templates:
                  - name: analyze-and-pr
                    steps:
                      - - name: rca
                          template: llm-root-cause      # LLM analiza logs/traces OTel
                      - - name: open-pr
                          template: git-open-pr          # NO aplica: abre PR con el fix
                  - name: llm-root-cause
                    container:
                      image: registry.example.com/aiops/rca:2.1.0
                      env:
                        - name: OTEL_ENDPOINT
                          value: http://otel-collector.observability:4317
                        - name: LLM_MODE
                          value: "propose-only"          # guardrail: nunca "apply"
                  - name: git-open-pr
                    container:
                      image: registry.example.com/aiops/gitops-pr:2.1.0
```

> **Guardrail arquitectónico**: el `serviceAccountName` del workflow tiene RBAC de sólo lectura sobre el cluster y escritura únicamente sobre un repo Git. El LLM *propone*; el merge del PR sigue siendo la barrera humana. Así el actor no-determinista nunca muta producción directamente.

---

## 4. Comandos CLI y salidas reales

**Verificar que la GPU es allocatable en el nodo:**

```bash
$ kubectl get nodes -L nvidia.com/gpu.product -o custom-columns=\
NODE:.metadata.name,GPU:.status.allocatable.'nvidia\.com/gpu'
NODE              GPU
gpu-node-01       4        # 4 = time-slicing activo (1 física × 4 réplicas)
gpu-node-02       1
```

```bash
$ kubectl exec -it -n gpu-operator nvidia-driver-daemonset-abc12 -- nvidia-smi
+-----------------------------------------------------------------------------+
| NVIDIA-SMI 550.90.07    Driver Version: 550.90.07    CUDA Version: 12.4     |
|-------------------------------+----------------------+----------------------+
| GPU  Name        Persistence-M| Bus-Id        Disp.A | Volatile Uncorr. ECC |
|   0  NVIDIA A100-SXM4-80GB  On | 00000000:07:00.0 Off |                    0 |
| N/A   34C    P0    64W / 400W |  38112MiB / 81920MiB |     47%      Default |
+-------------------------------+----------------------+----------------------+
```

**Estado del InferenceService de KServe:**

```bash
$ kubectl get inferenceservice -n ml-serving
NAME         URL                                          READY   PREV   LATEST   AGE
mistral-7b   http://mistral-7b.ml-serving.example.com     True           100      6m

$ kubectl get pods -n ml-serving -l serving.kserve.io/inferenceservice=mistral-7b
NAME                                             READY   STATUS    RESTARTS   AGE
mistral-7b-predictor-00001-deployment-7c9-x2k4   2/2     Running   0          6m
```

**Estado del ScaledObject de KEDA:**

```bash
$ kubectl get scaledobject -n ml-serving
NAME                 SCALETARGETKIND     SCALETARGETNAME   MIN   MAX   READY   ACTIVE   AGE
llm-gateway-scaler   apps/v1.Deployment  llm-gateway       2     30    True    True     3h

$ kubectl get hpa -n ml-serving
NAME                          REFERENCE               TARGETS              REPLICAS
keda-hpa-llm-gateway-scaler   Deployment/llm-gateway  62/50 (predictkube)  7
```

**Colas y workloads de Kueue:**

```bash
$ kubectl get workloads -n team-ml
NAME                      QUEUE     ADMITTED   AGE
job-llama-finetune-x8k2   default   True       12m
job-llama-finetune-p4m9   default   False      2m      # suspendido: sin cuota

$ kubectl get clusterqueue team-ml -o jsonpath=\
'{.status.flavorsUsage[0].resources}' | jq
[
  {"name":"nvidia.com/gpu","total":"8"},
  {"name":"cpu","total":"64"}
]
```

---

## 5. Verificación y diagnóstico de fallas

### 5.1 La GPU no aparece como allocatable (`0` en `nvidia.com/gpu`)

Ladder de diagnóstico, de más común a menos:

```bash
# 1) ¿Está sano el operator y el device plugin?
$ kubectl get pods -n gpu-operator
nvidia-device-plugin-daemonset-abc12    1/1   Running
nvidia-driver-daemonset-abc12           1/1   Running   # si CrashLoop → driver/kernel
gpu-feature-discovery-abc12             1/1   Running

# 2) ¿NFD etiquetó el nodo? Sin labels, el plugin no arranca ahí.
$ kubectl get node gpu-node-01 -o jsonpath='{.metadata.labels}' | tr ',' '\n' | grep nvidia
"nvidia.com/gpu.present":"true"

# 3) ¿El pod tolera el taint de GPU? Falta de toleration = Pending eterno.
$ kubectl describe pod <pod> | grep -A2 Events
  Warning  FailedScheduling  0/3 nodes are available: 3 node(s) had untolerated taint {nvidia.com/gpu}.
```

**Causas raíz típicas:** (a) driver DaemonSet en CrashLoop por mismatch kernel/driver → revisar `kubectl logs nvidia-driver-daemonset-...`; (b) falta la `toleration` en el pod; (c) time-slicing configurado pero la `ClusterPolicy` no fue parcheada (el `default` no apunta al ConfigMap); (d) NFD no corre y el nodo no tiene labels.

### 5.2 El `InferenceService` no llega a `READY=True`

```bash
$ kubectl describe inferenceservice mistral-7b -n ml-serving
Status:
  Conditions:
    Type: PredictorReady    Status: False   Reason: RevisionFailed

# El sospechoso #1 es el storage-initializer (init container)
$ kubectl logs <predictor-pod> -c storage-initializer -n ml-serving
Traceback (most recent call last):
  ...
botocore.exceptions.ClientError: An error occurred (403) ... Forbidden
```

**Checklist:** credenciales S3 mal anotadas en el Secret (endpoint, `usehttps`); el `ServiceAccount` no referencia el Secret; `storageUri` con typo o bucket inexistente; imagen del runtime sin pull (`ImagePullBackOff`); `nvidia.com/gpu` solicitado pero sin nodo GPU libre (Pending). Regla: **siempre leé primero los logs del init container `storage-initializer`**, no del contenedor principal.

### 5.3 KEDA no escala

```bash
$ kubectl describe scaledobject llm-gateway-scaler -n ml-serving
  Conditions:
    Type: Ready    Status: False   Reason: ScalerFailed
  Events:
    Warning  KEDAScalerFailed  error requesting predictkube: 401 unauthorized
```

**Causas:** API key de predictkube inválida o rotada (revisá el `TriggerAuthentication`/Secret); `prometheusAddress` inalcanzable desde el namespace de KEDA (NetworkPolicy); la `query` PromQL devuelve vacío (KEDA lo trata como 0 → no escala); histórico `<historyTimeWindow` → predictkube no tiene datos para entrenar. Confirmá que el **HPA fue creado** (`kubectl get hpa`): si no existe, el ScaledObject nunca se activó.

### 5.4 Job de Kueue atascado en `suspend`

```bash
$ kubectl describe workload job-llama-finetune-p4m9 -n team-ml
  Conditions:
    Type: QuotaReserved   Status: False
    Reason: Pending
    Message: "couldn't assign flavors: insufficient quota for nvidia.com/gpu
              in flavor gpu-a100, 16 more needed"
```

**Diagnóstico:** la `nominalQuota` del `ClusterQueue` está agotada por otros workloads admitidos; el `ResourceFlavor` no matchea (`nodeLabels` no coinciden con ningún nodo real); o la `borrowingLimit`/`cohort` no permite prestar de otra queue. Verificá `kubectl get clusterqueue -o wide` para ver `PENDING WORKLOADS` y `ADMITTED WORKLOADS`.

### 5.5 Guardrail: verificar que el LLM de remediación no puede mutar producción

```bash
$ kubectl auth can-i --as=system:serviceaccount:argo-events:aiops-remediator \
    delete pods -A
no
$ kubectl auth can-i --as=system:serviceaccount:argo-events:aiops-remediator \
    get pods -A
yes
```

Que la respuesta a `delete/patch/apply` sea `no` es la prueba de que el actor no-determinista está confinado a *proponer* (abrir PR), no a actuar. Este chequeo debe ser parte del pipeline de conformance del IDP.

---

## 6. Referencias

- CNCF — *Cloud Native Artificial Intelligence Whitepaper*: https://www.cncf.io/reports/cloud-native-artificial-intelligence-whitepaper/
- CNPA Curriculum (CNCF/curriculum): https://github.com/cncf/curriculum
- KServe — documentación oficial: https://kserve.github.io/website/
- KEDA — Scalers y ScaledObject: https://keda.sh/docs/latest/concepts/scaling-deployments/ · Predictkube scaler: https://keda.sh/docs/latest/scalers/predictkube/
- Kueue (Kubernetes SIG): https://kueue.sigs.k8s.io/docs/
- Volcano: https://volcano.sh/en/docs/
- Apache YuniKorn: https://yunikorn.apache.org/docs/
- NVIDIA GPU Operator — GPU sharing (time-slicing / MPS / MIG): https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/gpu-sharing.html
- Kubernetes — Dynamic Resource Allocation (DRA): https://kubernetes.io/docs/concepts/scheduling-eviction/dynamic-resource-allocation/
- Prometheus — funciones de query (`predict_linear`, `holt_winters`): https://prometheus.io/docs/prometheus/latest/querying/functions/
- Argo Events: https://argoproj.github.io/argo-events/ · Argo Workflows: https://argo-workflows.readthedocs.io/
- OpenTelemetry — documentación: https://opentelemetry.io/docs/
- Kubeflow — MLOps sobre Kubernetes: https://www.kubeflow.org/docs/