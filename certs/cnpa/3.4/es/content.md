# Tema 3.4 — Incident Response and Remediation in Platform Engineering

> **CNPA (Cloud Native Platform Engineering Associate) · versión 2025-04-01 · Peso 2.3**
> Perfil: SRE Senior / Platform Architect. Todo el material asume Kubernetes ≥ 1.29, Prometheus Operator, un mesh (Istio/Linkerd) y GitOps (Argo CD o Flux) ya presentes en el cluster.

---

## 1. Motivación y problema arquitectónico de producción

En una plataforma cloud-native el fallo no es un evento excepcional: es el **régimen permanente de operación**. Con cientos de Deployments, decenas de nodos, autoscaling, rollouts continuos y dependencias de red efímeras, en cualquier instante *algo* está degradado. La pregunta de ingeniería no es "¿cómo evito incidentes?" sino "¿cuánto tarda el sistema en **detectar, contener y remediar** una degradación, y cuánto de ese trabajo puede ejecutarse sin intervención humana?".

El *Platform Engineering* mueve la respuesta a incidentes de un modelo **reactivo y manual** (un humano recibe un page, abre un runbook, ejecuta `kubectl` a mano) hacia un modelo de **golden paths con self-healing y guardrails**: la plataforma provee probes correctas, PodDisruptionBudgets, rollback automático en el rollout, reconciliación GitOps y políticas de error budget *por defecto*, de modo que la mayoría de las clases de fallo se remedien solas y el humano sólo entre en los casos novedosos.

### 1.1 Métricas que gobiernan el diseño

| Métrica | Definición | Qué la reduce arquitectónicamente |
|---|---|---|
| **MTTD** (Mean Time To Detect) | Tiempo desde que empieza la degradación hasta que se dispara una alerta accionable | SLO-based alerting con *burn rate* multi-ventana; observabilidad de los cuatro golden signals |
| **MTTA** (Mean Time To Acknowledge) | Detección → un responsable la toma | Routing de Alertmanager, on-call schedules, deduplicación |
| **MTTR** (Mean Time To Remediate/Recover) | Detección → servicio restaurado | Rollback automático, self-heal GitOps, restore desde backup, circuit breaking |
| **MTBF** (Mean Time Between Failures) | Tiempo medio entre incidentes | Chaos engineering, PDB, testing progresivo, análisis de causa raíz |
| **Change failure rate** | % de deploys que causan incidente | Progressive delivery + analysis gates |

La palanca central es **MTTR**: en sistemas distribuidos no podés eliminar los fallos, pero sí acortar radicalmente el tiempo de recuperación. Cada segundo de MTTR consume **error budget** — la fracción de indisponibilidad que el SLO te permite gastar.

### 1.2 Ciclo de vida del incidente (lo que la plataforma debe soportar en cada fase)

```
  DETECT ──► TRIAGE ──► CONTAIN ──► REMEDIATE ──► RECOVER ──► LEARN
    │           │           │            │            │          │
 SLO burn    severidad   circuit     rollback      verificar  blameless
  rate       + blast     breaker /   / self-heal   SLO / smoke postmortem
 alerting    radius      drain /     / restore     tests      + error-budget
            (¿quién,     rate-limit                           policy
             qué,
             cuánto?)
```

- **Detect** — señales (metrics/logs/traces/events) → alerta con contexto y link a runbook.
- **Triage** — asignar severidad (SEV1–SEV4), acotar el *blast radius*, nombrar un Incident Commander en SEV alto.
- **Contain** — reducir el radio de impacto *antes* de arreglar la causa: expulsar la instancia mala (outlier detection), abrir el circuit breaker, cordonar un nodo, activar rate-limit, congelar deploys.
- **Remediate** — restaurar el estado bueno conocido: `rollout undo`, revert GitOps, restore Velero, escalar, reiniciar por probe.
- **Recover** — confirmar por señales objetivas (no por "parece que anda") que el SLI volvió al target.
- **Learn** — postmortem sin culpa, acciones correctivas con dueño y fecha, ajuste de la error-budget policy.

### 1.3 El problema arquitectónico central: **remediación segura y automática**

La automatización de remediación tiene una tensión estructural: una acción automática mal diseñada **amplifica** el incidente (un liveness probe agresivo que reinicia pods sanos bajo carga alta → tormenta de reinicios; un HPA que escala contra una dependencia caída → thundering herd). Por eso toda remediación automática debe: (1) ser **idempotente**, (2) tener **límites de blast radius** (maxUnavailable, maxEjectionPercent, PDB), (3) ser **observable y reversible**, y (4) **fallar de forma segura** (fail-static antes que fail-loud amplificando).

---

## 2. Comparativas técnicas con tablas de trade-offs

### 2.1 Estrategia de detección: threshold estático vs. SLO burn-rate

| Dimensión | Alerta por threshold estático | Multi-window multi-burn-rate (SLO) |
|---|---|---|
| Basado en | Valor absoluto (`error_rate > 1%`) | Consumo de error budget relativo al SLO |
| Falsos positivos | Altos (picos transitorios pagean) | Bajos (ventana corta *y* larga deben coincidir) |
| Detección rápida de outages grandes | Igual para todo | 14.4× burn ⇒ page en minutos |
| Detección de leaks lentos | Ciega | Ventana 3d/6h captura el goteo |
| Alert fatigue | Alta | Baja; sólo pagea lo que amenaza el SLO |
| Complejidad de setup | Baja | Media (recording rules por ventana) |

**Regla:** paginá por *síntomas que amenazan el SLO*, no por causas. La causa se diagnostica; el síntoma se alerta.

### 2.2 Estrategia de rollback

| Estrategia | Mecanismo | MTTR típico | Reversa automática | Riesgo |
|---|---|---|---|---|
| `kubectl rollout undo` | Vuelve al ReplicaSet anterior | Segundos–minutos | No (imperativo) | **Deriva** vs. Git; el próximo sync GitOps lo revierte |
| GitOps revert (`git revert` + sync) | Reconcilia al commit bueno | Minutos | Con self-heal, sí | Requiere disciplina de repo; PR/merge en el camino crítico |
| Progressive delivery (Argo Rollouts / Flagger) | Analysis gate aborta el canary | Segundos (antes de 100% tráfico) | **Sí, en el propio deploy** | Sólo protege el *nuevo* deploy, no regresiones externas |
| Blue/Green switch | Cambiar Service selector al stable | Segundos | Semi | Doble capacidad; state/DB migrations |
| Restore desde snapshot (Velero) | Restaura objetos + PV | Minutos–horas | No | Pérdida de datos entre snapshot y ahora (RPO) |

**Convivencia GitOps ↔ imperativo:** si corrés Argo CD con `selfHeal: true`, un `kubectl rollout undo` manual será **revertido** por el controller en el próximo reconcile. En una plataforma GitOps la remediación *durable* es el revert en Git; el `rollout undo` sirve sólo como parche de emergencia mientras abrís el PR — o cortando temporalmente el auto-sync.

### 2.3 Self-healing: dónde vive cada mecanismo

| Nivel | Mecanismo | Detecta | Remedia | Límite de blast radius |
|---|---|---|---|---|
| Pod | livenessProbe | Deadlock/hung | Reinicia el container | `restartPolicy`, backoff exponencial |
| Pod | readinessProbe | No listo para tráfico | Saca del endpoint | — (no reinicia) |
| Pod | startupProbe | Arranque lento | Protege liveness durante boot | `failureThreshold × period` |
| ReplicaSet | Controller reconcile | Pod faltante/muerto | Recrea el pod | `replicas` |
| Deployment | Rolling update | Rollout malo | `progressDeadlineSeconds` marca fallo | `maxUnavailable/maxSurge` |
| Node | Node Problem Detector + remediation | Kernel deadlock, disco, NTP | Marca condición → cordon/drain | Rate de remediación |
| Cluster | Descheduler | Pods con demasiados restarts, desbalance | Expulsa para re-scheduling | PDB, `maxNoOfPodsToEvict` |
| Servicio | Outlier detection (mesh) | Instancia 5xx | Eyecta del pool | `maxEjectionPercent` |
| App | Controller/Operator | Drift del CR | Reconcilia al estado deseado | Definido por el operator |

### 2.4 Remediación automática vs. manual (cuándo cada una)

| | Automática | Manual (con runbook) |
|---|---|---|
| Fallo conocido, causa determinística | ✅ ideal (rollback, restart, eject) | ⛔ derrocha MTTR |
| Fallo novedoso / causa desconocida | ⛔ puede amplificar | ✅ humano diagnostica |
| Acción destructiva/irreversible (delete PVC, restore prod) | ⛔ nunca sin break-glass + aprobación | ✅ con doble control |
| Alta frecuencia, bajo riesgo | ✅ | ⛔ no escala |
| Requiere contexto de negocio (¿aceptamos degradar feature X?) | ⛔ | ✅ Incident Commander |

---

## 3. Manifiestos completos (production-grade, sin recortar)

### 3.1 Probes correctas + PodDisruptionBudget + rollout controlado

Base de todo self-healing: probes que distinguen *vivo* de *listo*, y garantías de disponibilidad durante disrupciones voluntarias (drain, upgrade).

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  namespace: shop
  labels:
    app: checkout
spec:
  replicas: 6
  revisionHistoryLimit: 10          # historial para rollout undo
  progressDeadlineSeconds: 600      # si el rollout no progresa en 10m => Degraded
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1             # blast radius del deploy
      maxSurge: 2
  selector:
    matchLabels:
      app: checkout
  template:
    metadata:
      labels:
        app: checkout
    spec:
      terminationGracePeriodSeconds: 45
      containers:
        - name: checkout
          image: registry.acme.io/shop/checkout:1.14.2
          ports:
            - name: http
              containerPort: 8080
          resources:
            requests:
              cpu: "250m"
              memory: "256Mi"
            limits:
              memory: "512Mi"        # sin CPU limit: evita throttling que dispara falsos liveness
          startupProbe:              # protege el arranque: hasta 30 × 2s = 60s para bootear
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 2
            failureThreshold: 30
          livenessProbe:             # SÓLO "¿el proceso está colgado?" — nunca dependencias externas
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
          readinessProbe:            # "¿puedo atender tráfico ahora?" — puede chequear deps
            httpGet:
              path: /ready
              port: http
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 3
          lifecycle:
            preStop:                 # drenado ordenado: deja de recibir antes de morir
              exec:
                command: ["/bin/sh", "-c", "sleep 10"]
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: checkout-pdb
  namespace: shop
spec:
  minAvailable: 4                    # nunca menos de 4 de 6 durante drains/upgrades
  selector:
    matchLabels:
      app: checkout
```

> **Anti-patrón clásico de incidente:** un `livenessProbe` que llama a la base de datos. Cuando la DB se degrada, *todos* los pods fallan el liveness a la vez y Kubernetes los reinicia en masa — convirtiendo una degradación de dependencia en un outage total con tormenta de reinicios. El liveness prueba **sólo el proceso local**; las dependencias van en **readiness**.

### 3.2 Detección: SLO burn-rate multi-ventana (Prometheus Operator)

Implementa las alertas del Google SRE Workbook para un SLO de disponibilidad de **99.9%** (error budget = 0.001). Dispara `page` rápido ante outages grandes y `ticket` ante leaks lentos.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: checkout-slo
  namespace: monitoring
  labels:
    role: alert-rules
    prometheus: k8s
spec:
  groups:
    - name: checkout-slo.sli
      interval: 30s
      rules:
        # SLI = fracción de requests fallidas, por ventana
        - record: job:slo_errors_per_request:ratio_rate5m
          expr: |
            sum(rate(http_requests_total{job="checkout",code=~"5.."}[5m]))
            / sum(rate(http_requests_total{job="checkout"}[5m]))
        - record: job:slo_errors_per_request:ratio_rate30m
          expr: |
            sum(rate(http_requests_total{job="checkout",code=~"5.."}[30m]))
            / sum(rate(http_requests_total{job="checkout"}[30m]))
        - record: job:slo_errors_per_request:ratio_rate1h
          expr: |
            sum(rate(http_requests_total{job="checkout",code=~"5.."}[1h]))
            / sum(rate(http_requests_total{job="checkout"}[1h]))
        - record: job:slo_errors_per_request:ratio_rate6h
          expr: |
            sum(rate(http_requests_total{job="checkout",code=~"5.."}[6h]))
            / sum(rate(http_requests_total{job="checkout"}[6h]))
        - record: job:slo_errors_per_request:ratio_rate3d
          expr: |
            sum(rate(http_requests_total{job="checkout",code=~"5.."}[3d]))
            / sum(rate(http_requests_total{job="checkout"}[3d]))
    - name: checkout-slo.alerts
      rules:
        # PAGE rápido: 2% del budget en 1h  => burn rate 14.4  (threshold = 14.4 * 0.001)
        - alert: CheckoutErrorBudgetBurnFast
          expr: |
            job:slo_errors_per_request:ratio_rate1h  > (14.4 * 0.001)
            and
            job:slo_errors_per_request:ratio_rate5m  > (14.4 * 0.001)
          for: 2m
          labels: { severity: page, service: checkout }
          annotations:
            summary: "checkout quema el error budget 14.4x (page)"
            runbook_url: "https://runbooks.acme.io/checkout/error-budget-burn"
        # PAGE lento: 5% del budget en 6h  => burn rate 6
        - alert: CheckoutErrorBudgetBurnMedium
          expr: |
            job:slo_errors_per_request:ratio_rate6h  > (6 * 0.001)
            and
            job:slo_errors_per_request:ratio_rate30m > (6 * 0.001)
          for: 15m
          labels: { severity: page, service: checkout }
          annotations:
            summary: "checkout quema el error budget 6x (page)"
            runbook_url: "https://runbooks.acme.io/checkout/error-budget-burn"
        # TICKET: 10% del budget en 3d  => burn rate 1  (leak lento)
        - alert: CheckoutErrorBudgetBurnSlow
          expr: |
            job:slo_errors_per_request:ratio_rate3d > (1 * 0.001)
            and
            job:slo_errors_per_request:ratio_rate6h > (1 * 0.001)
          for: 1h
          labels: { severity: ticket, service: checkout }
          annotations:
            summary: "checkout: fuga lenta de error budget (ticket)"
            runbook_url: "https://runbooks.acme.io/checkout/error-budget-burn"
```

### 3.3 Routing y contención humana: Alertmanager

```yaml
apiVersion: monitoring.coreos.com/v1alpha1
kind: AlertmanagerConfig
metadata:
  name: shop-routing
  namespace: monitoring
spec:
  route:
    receiver: 'default-slack'
    groupBy: ['alertname', 'service']
    groupWait: 30s
    groupInterval: 5m
    repeatInterval: 4h
    routes:
      - matchers:
          - name: severity
            value: page
        receiver: 'pagerduty-critical'
        continue: false
      - matchers:
          - name: severity
            value: ticket
        receiver: 'jira-tickets'
  receivers:
    - name: 'default-slack'
      slackConfigs:
        - channel: '#shop-alerts'
          sendResolved: true
    - name: 'pagerduty-critical'
      pagerdutyConfigs:
        - routingKey:
            name: pagerduty-secret
            key: routingKey
          severity: critical
    - name: 'jira-tickets'
      webhookConfigs:
        - url: 'https://automation.acme.io/hooks/jira'
  inhibitRules:                       # una page silencia el ticket del mismo servicio
    - sourceMatch:
        - name: severity
          value: page
      targetMatch:
        - name: severity
          value: ticket
      equal: ['service']
```

### 3.4 Remediación automática en el deploy: Argo Rollouts con analysis gate

El canary avanza sólo si el análisis pasa; si la tasa de error del canary supera el umbral, **aborta y revierte automáticamente** al stable — sin humano en el loop.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: checkout
  namespace: shop
spec:
  replicas: 6
  revisionHistoryLimit: 5
  selector:
    matchLabels: { app: checkout }
  workloadRef:                        # reusa el pod template del Deployment
    apiVersion: apps/v1
    kind: Deployment
    name: checkout
  strategy:
    canary:
      canaryService: checkout-canary
      stableService: checkout-stable
      trafficRouting:
        istio:
          virtualServices:
            - name: checkout-vsvc
              routes: [primary]
      analysis:                       # análisis "de fondo" durante todo el rollout
        templates:
          - templateName: error-rate
        startingStep: 1
        args:
          - name: canary-svc
            value: checkout-canary
      steps:
        - setWeight: 10
        - pause: { duration: 2m }
        - setWeight: 30
        - pause: { duration: 5m }
        - setWeight: 60
        - pause: { duration: 5m }
        - setWeight: 100
---
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: error-rate
  namespace: shop
spec:
  args:
    - name: canary-svc
  metrics:
    - name: error-rate
      interval: 60s
      count: 5
      successCondition: result < 0.01     # < 1% de 5xx
      failureLimit: 2                       # 2 fallos => aborta y revierte
      provider:
        prometheus:
          address: http://prometheus-k8s.monitoring:9090
          query: |
            sum(rate(http_requests_total{service="{{args.canary-svc}}",code=~"5.."}[2m]))
            / sum(rate(http_requests_total{service="{{args.canary-svc}}"}[2m]))
```

### 3.5 Remediación durable y self-heal: Argo CD Application

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: checkout
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: shop
  source:
    repoURL: https://github.com/acme/shop-gitops.git
    targetRevision: main
    path: apps/checkout/overlays/prod
  destination:
    server: https://kubernetes.default.svc
    namespace: shop
  syncPolicy:
    automated:
      prune: true
      selfHeal: true          # revierte drift manual al estado de Git
      allowEmpty: false
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
    syncOptions:
      - CreateNamespace=true
      - PruneLast=true
  revisionHistoryLimit: 20     # habilita `argocd app rollback`
```

### 3.6 Remediación de datos/estado: Velero (backup programado + política de retención)

```yaml
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: shop-hourly
  namespace: velero
spec:
  schedule: "0 * * * *"          # RPO = 1h
  useOwnerReferencesInBackup: false
  template:
    includedNamespaces:
      - shop
    snapshotVolumes: true
    defaultVolumesToFsBackup: true
    ttl: 168h0m0s                # retención 7 días
    storageLocation: default
    hooks:
      resources:
        - name: quiesce-db
          includedNamespaces: [shop]
          labelSelector:
            matchLabels: { app: postgres }
          pre:                    # consistencia: checkpoint antes del snapshot
            - exec:
                container: postgres
                command: ["/bin/sh","-c","pg_ctl -w checkpoint || true"]
```

### 3.7 Self-healing a nivel nodo: Node Problem Detector + Descheduler

**Node Problem Detector** (DaemonSet) traduce problemas de kernel/hardware en *NodeConditions* que otros controllers pueden accionar:

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-problem-detector
  namespace: kube-system
spec:
  selector:
    matchLabels: { app: node-problem-detector }
  template:
    metadata:
      labels: { app: node-problem-detector }
    spec:
      serviceAccountName: node-problem-detector
      tolerations:
        - operator: Exists       # corre en todos los nodos, incluidos tainted
      containers:
        - name: node-problem-detector
          image: registry.k8s.io/node-problem-detector/node-problem-detector:v0.8.20
          args:
            - --config.system-log-monitor=/config/kernel-monitor.json
            - --config.custom-plugin-monitor=/config/disk-custom-plugin.json
          securityContext:
            privileged: true
          volumeMounts:
            - { name: log, mountPath: /var/log, readOnly: true }
            - { name: kmsg, mountPath: /dev/kmsg, readOnly: true }
            - { name: config, mountPath: /config, readOnly: true }
      volumes:
        - { name: log, hostPath: { path: /var/log/ } }
        - { name: kmsg, hostPath: { path: /dev/kmsg } }
        - name: config
          configMap: { name: node-problem-detector-config }
```

**Descheduler** (CronJob) expulsa pods atrapados en restart-loops y rebalancea; respeta PDB automáticamente:

```yaml
apiVersion: descheduler/v1alpha2
kind: DeschedulerPolicy
metadata:
  name: cluster-hygiene
maxNoOfPodsToEvictPerNode: 5      # límite de blast radius
profiles:
  - name: default
    pluginConfig:
      - name: RemovePodsHavingTooManyRestarts
        args:
          podRestartThreshold: 100
          includingInitContainers: true
      - name: LowNodeUtilization
        args:
          thresholds:      { cpu: 20, memory: 20, pods: 20 }
          targetThresholds:{ cpu: 50, memory: 50, pods: 50 }
    plugins:
      deschedule:
        enabled: [RemovePodsHavingTooManyRestarts]
      balance:
        enabled: [LowNodeUtilization]
```

### 3.8 Contención a nivel red: circuit breaking + outlier detection (Istio)

Cuando una instancia empieza a devolver 5xx, el mesh la **eyecta del pool** sin esperar al reinicio — contención inmediata del blast radius.

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: checkout
  namespace: shop
spec:
  host: checkout.shop.svc.cluster.local
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 100
      http:
        http1MaxPendingRequests: 64
        maxRequestsPerConnection: 10
    outlierDetection:
      consecutive5xxErrors: 5      # 5 fallos consecutivos
      interval: 10s
      baseEjectionTime: 30s        # eyectada 30s (crece con reincidencias)
      maxEjectionPercent: 50       # jamás eyectar > 50% del pool (evita cascada)
    retries:
      attempts: 2
      perTryTimeout: 1s
      retryOn: 5xx,connect-failure,refused-stream
```

### 3.9 Preparación proactiva: chaos experiment (Chaos Mesh)

Validar que el self-healing *funciona* antes del incidente real. Se corre en staging o en prod con blast radius acotado.

```yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: PodChaos
metadata:
  name: checkout-pod-kill
  namespace: shop
spec:
  action: pod-kill
  mode: fixed-percent
  value: "20"                      # mata 20% de los pods
  selector:
    namespaces: [shop]
    labelSelectors: { app: checkout }
  duration: "60s"
```

---

## 4. Comandos CLI y salidas de terminal reales

### 4.1 Triage rápido de un pod que falla

```console
$ kubectl -n shop get pods -l app=checkout
NAME                        READY   STATUS             RESTARTS      AGE
checkout-7d9f8c6b4-4kf2p    0/1     CrashLoopBackOff   6 (48s ago)   9m
checkout-7d9f8c6b4-9xqzt    1/1     Running            0             34h
checkout-7d9f8c6b4-t7m5r    0/1     CrashLoopBackOff   6 (12s ago)   9m

$ kubectl -n shop describe pod checkout-7d9f8c6b4-4kf2p | sed -n '/Last State/,/Events/p'
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
      Started:      Mon, 07 Apr 2025 14:22:11 -0300
      Finished:     Mon, 07 Apr 2025 14:22:53 -0300
    Ready:          False
    Restart Count:  6
Events:
  Type     Reason     Age                 From     Message
  ----     ------     ----                ----     -------
  Warning  BackOff    31s (x8 over 4m)    kubelet  Back-off restarting failed container
  Warning  Unhealthy  2m (x3 over 3m)     kubelet  Liveness probe failed: HTTP 500
```

`Exit Code 137 / Reason OOMKilled` ⇒ el container superó su `memory limit`. Causa distinta a `Exit Code 1` (crash de app) o `CreateContainerConfigError` (secret/config faltante).

```console
$ kubectl -n shop logs checkout-7d9f8c6b4-4kf2p --previous --tail=5
2025-04-07T14:22:52Z FATAL loading in-memory catalog: 1.8GB > heap budget
runtime: out of memory: cannot allocate 268435456-byte block
fatal error: out of memory
```

### 4.2 Remediación de emergencia: rollback imperativo

```console
$ kubectl -n shop rollout history deployment/checkout
REVISION  CHANGE-CAUSE
7         kubectl set image ... checkout=checkout:1.14.1
8         kubectl set image ... checkout=checkout:1.14.2   # <-- la que rompió

$ kubectl -n shop rollout undo deployment/checkout --to-revision=7
deployment.apps/checkout rolled back

$ kubectl -n shop rollout status deployment/checkout --timeout=120s
Waiting for deployment "checkout" rollout to finish: 3 out of 6 new replicas have been updated...
deployment "checkout" successfully rolled out
```

### 4.3 Remediación durable: rollback GitOps (el patrón correcto en plataforma)

```console
$ argocd app history checkout
ID  DATE                            REVISION
12  2025-04-07 11:03:22 -0300       main (a1b2c3d)
13  2025-04-07 14:19:40 -0300       main (e4f5g6h)   # deploy que rompió

$ argocd app rollback checkout 12
Rollback application 'checkout' to history id 12
...
$ argocd app get checkout -o wide
Name:               argocd/checkout
Health Status:      Healthy
Sync Status:        Synced to main (a1b2c3d)
```

> Con `selfHeal: true`, si en cambio hubieras hecho `kubectl rollout undo`, Argo CD lo detecta como *OutOfSync* y lo revierte. La reversa durable es **en Git**: `git revert e4f5g6h && git push`, y el controller reconcilia.

### 4.4 Verificar el rollback automático de Argo Rollouts

```console
$ kubectl argo rollouts get rollout checkout -n shop
Name:            checkout
Status:          ✖ Degraded
Message:         RolloutAborted: metric "error-rate" assessed Failed
Strategy:        Canary
  Step:          2/7
  SetWeight:     30
  ActualWeight:  0
Images:          checkout:1.14.1 (stable)
Replicas:
  Desired:       6
  Current:       6
  Ready:         6

NAME                                  KIND         STATUS     AGE  INFO
⟳ checkout                            Rollout      ✖ Degraded 34h
├──# revision:12
│  └──⧉ checkout-6c4b9 (canary)       ReplicaSet   • ScaledDown 3m  canary,delay:passed
└──# revision:11
   └──⧉ checkout-7d9f8 (stable)       ReplicaSet   ✔ Healthy    34h  stable
```

`Status: Degraded` + `RolloutAborted` + `ActualWeight: 0` ⇒ el analysis gate detectó el 5xx, abortó el canary y devolvió el 100% del tráfico al stable **sin intervención**.

### 4.5 Restore de estado con Velero

```console
$ velero backup get
NAME                     STATUS      ERRORS   CREATED                         EXPIRES
shop-hourly-20250407130002  Completed   0     2025-04-07 13:00:02 -0300       6d

$ velero restore create --from-backup shop-hourly-20250407130002 \
    --include-namespaces shop --wait
Restore request "shop-hourly-20250407130002-20250407143512" submitted successfully.
....
Restore completed with status: Completed. Warnings: 2, Errors: 0.

$ velero restore describe shop-hourly-20250407130002-20250407143512 | grep -E 'Phase|Warnings|Errors'
Phase:  Completed
Warnings:  2  (existing resources skipped)
Errors:    0
```

### 4.6 Validar las reglas de alerta *antes* de confiar en ellas

```console
$ promtool check rules /etc/prometheus/rules/checkout-slo.yaml
Checking /etc/prometheus/rules/checkout-slo.yaml
  SUCCESS: 8 rules found

$ amtool alert query --alertmanager.url=http://alertmanager:9093 severity=page
Alertname                       Starts At             Summary
CheckoutErrorBudgetBurnFast     2025-04-07 14:20 -03  checkout quema el error budget 14.4x (page)
```

### 4.7 Contención rápida a nivel nodo

```console
$ kubectl get nodes
NAME             STATUS                     ROLES    AGE    VERSION
ip-10-0-3-14     Ready                      <none>   62d    v1.31.4
ip-10-0-3-77     Ready,SchedulingDisabled   <none>   62d    v1.31.4   # ya cordonado por NPD-remediation

$ kubectl describe node ip-10-0-3-77 | grep -A2 KernelDeadlock
  KernelDeadlock   True   Mon, 07 Apr 2025 14:25:03  KernelHasDeadlock  task hung > 120s

$ kubectl drain ip-10-0-3-77 --ignore-daemonsets --delete-emptydir-data --grace-period=45
node/ip-10-0-3-77 evicting pods respecting PDB checkout-pdb (minAvailable=4)
evicting pod shop/checkout-7d9f8c6b4-9xqzt
node/ip-10-0-3-77 drained
```

El drain **respeta el PDB**: si expulsar el pod bajaría de `minAvailable: 4`, el evict bloquea hasta que haya reemplazo listo — así la contención no genera el segundo incidente.

---

## 5. Guía de verificación y diagnóstico de fallas

### 5.1 Árbol de decisión por `STATUS`/`Reason`

| Síntoma | Causa probable | Comando de confirmación | Remediación |
|---|---|---|---|
| `CrashLoopBackOff` + `Exit 137` / `OOMKilled` | Límite de memoria bajo o leak | `describe pod` → *Last State* | Subir `limits.memory` / arreglar leak; rollback si es regresión |
| `CrashLoopBackOff` + `Exit 1` | Crash de aplicación | `logs --previous` | Rollback a la revisión anterior |
| `CreateContainerConfigError` | Secret/ConfigMap ausente | `describe pod` → Events | Crear el recurso; revisar el sync GitOps |
| `ImagePullBackOff` | Tag inexistente / auth registry | `describe pod` → Events | Corregir tag / imagePullSecret |
| `Running` pero `0/1 READY` | Readiness falla (dependencia caída) | `logs`, `describe` → readiness | Arreglar la **dependencia**, no reiniciar el pod |
| `Pending` | Sin recursos / taint / PVC unbound | `describe pod` → Events; `kubectl get events` | Escalar nodos, revisar affinity/PVC |
| `Terminating` colgado | Finalizer atascado | `kubectl get pod -o yaml \| grep finalizers` | Resolver el controller dueño del finalizer |

### 5.2 Verificación post-remediación (nunca declarar "resuelto" sin señales)

```console
# 1) El SLI volvió bajo el error budget:
$ curl -s 'http://prometheus:9090/api/v1/query?query=job:slo_errors_per_request:ratio_rate5m' \
    | jq '.data.result[0].value[1]'
"0.0003"                                   # 0.03% < 0.1% budget  ✔

# 2) La alerta se resolvió (no sólo se silenció):
$ amtool alert query severity=page
# (vacío) => no hay pages activas

# 3) Smoke test del golden path del negocio:
$ kubectl -n shop exec deploy/loadtest -- \
    hey -z 30s -c 20 https://checkout.acme.io/api/cart | grep -E 'Status|error'
  Status code distribution:
    [200] 5980 responses                   # 0 x [5xx]  ✔

# 4) No hay drift / todo Synced+Healthy:
$ argocd app get checkout | grep -E 'Sync Status|Health Status'
Sync Status:    Synced
Health Status:  Healthy
```

### 5.3 Errores de diagnóstico que alargan el MTTR

- **Confundir síntoma con causa:** ver `CrashLoopBackOff` en pods y reiniciarlos, cuando la causa es la DB caída (readiness). Reiniciar no arregla nada y borra el estado que necesitás para diagnosticar. → Revisá siempre `logs --previous` y las **dependencias** antes de reiniciar.
- **Remediar contra un GitOps con self-heal:** parchear con `kubectl` mientras Argo CD revierte. → Cortá el auto-sync (`argocd app set checkout --sync-policy none`) *o* remediá en Git.
- **Rollback ciego sin snapshot de estado:** volver la app a v1.14.1 después de que 1.14.2 corrió una migración de schema irreversible. → Confirmá compatibilidad de datos; ese es el caso donde el restore de Velero (RPO) entra.
- **Liveness que amplifica:** ver reinicios masivos y subir la agresividad del probe. → Casi siempre es lo opuesto: el liveness prueba dependencias que no debería.
- **Silenciar en vez de resolver:** un `amtool silence add` cierra el ruido pero deja el error budget quemándose. El silence es para *reducir ruido durante* la remediación, no para *terminar* el incidente.

### 5.4 Cierre del ciclo: postmortem sin culpa y error-budget policy

La fase **Learn** es infraestructura, no burocracia. Todo SEV1/SEV2 produce un postmortem *blameless* con: timeline objetivo (de los timestamps de eventos/alertas), impacto cuantificado en error budget, causa raíz (los "cinco por qué" apuntan al **sistema**, no a la persona), y acciones correctivas con dueño y fecha. La **error-budget policy** convierte todo esto en una regla operativa: si el budget del trimestre se agotó, **se congelan las features** y el equipo redirige a fiabilidad hasta recuperarlo — así la respuesta a incidentes retroalimenta las prioridades de la plataforma en lugar de repetirse.

---

## 6. Referencias

- **CNCF — CNPA Curriculum**: https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- **Kubernetes — Configure Liveness, Readiness and Startup Probes**: https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- **Kubernetes — Specifying a Disruption Budget (PDB)**: https://kubernetes.io/docs/tasks/run-application/configure-pdb/
- **Kubernetes — Safely Drain a Node**: https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/
- **Kubernetes — Deployments (rollout, undo, history)**: https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#rolling-back-a-deployment
- **Prometheus — Alerting Rules**: https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
- **Prometheus Alertmanager — Configuration**: https://prometheus.io/docs/alerting/latest/configuration/
- **Prometheus Operator — PrometheusRule / AlertmanagerConfig API**: https://prometheus-operator.dev/docs/api-reference/api/
- **Google SRE Workbook — Alerting on SLOs (multi-window, multi-burn-rate)**: https://sre.google/workbook/alerting-on-slos/
- **Google SRE Book — Managing Incidents / Postmortem Culture**: https://sre.google/sre-book/managing-incidents/ · https://sre.google/sre-book/postmortem-culture/
- **Argo Rollouts — Canary & Analysis**: https://argo-rollouts.readthedocs.io/en/stable/features/canary/ · https://argo-rollouts.readthedocs.io/en/stable/features/analysis/
- **Argo CD — Automated Sync Policy (self-heal, prune)**: https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/
- **Flux — Automated remediation**: https://fluxcd.io/flux/components/helm/helmreleases/#configuring-failure-remediation
- **Velero — Backup, Restore & Schedules**: https://velero.io/docs/main/backup-reference/ · https://velero.io/docs/main/restore-reference/
- **Kubernetes Node Problem Detector**: https://github.com/kubernetes/node-problem-detector
- **Kubernetes SIG — Descheduler**: https://github.com/kubernetes-sigs/descheduler
- **Istio — Circuit Breaking & Outlier Detection**: https://istio.io/latest/docs/tasks/traffic-management/circuit-breaking/ · https://istio.io/latest/docs/reference/config/networking/destination-rule/#OutlierDetection
- **Chaos Mesh — PodChaos**: https://chaos-mesh.org/docs/simulate-pod-chaos-on-kubernetes/
- **CNCF LitmusChaos (alternativa)**: https://docs.litmuschaos.io/