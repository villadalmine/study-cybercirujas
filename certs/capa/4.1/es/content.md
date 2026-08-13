# Tema 4.1 — Argo Rollouts

> **Certificación:** CAPA (Certified Argo Project Associate)
> **Peso en el examen:** 20 % · **Perfil:** Progressive Delivery en producción
> **API:** `argoproj.io/v1alpha1` · **Controlador:** `argo-rollouts`

---

## 1. Motivación y problema arquitectónico de producción

### 1.1 El techo del `Deployment` nativo

El controlador `Deployment` de Kubernetes solo conoce dos estrategias: `Recreate` (mata todo y recrea, con downtime) y `RollingUpdate` (reemplazo gradual gobernado por `maxSurge`/`maxUnavailable`). Ese modelo tiene tres carencias que en producción se pagan caras:

1. **No hay gate humano ni automático dentro del rollout.** Un `RollingUpdate` avanza hasta el 100 % en cuanto los readiness probes pasan. El readiness probe responde "el proceso arrancó y acepta tráfico", **no** "la versión nueva no incrementó la latencia p99 ni la tasa de 5xx". Un bug que solo se manifiesta bajo carga real (un memory leak, una query N+1, un deadlock a los 4 minutos) escapa al probe y llega al 100 % de los usuarios antes de que nadie lo note.

2. **El rollback es manual y lento.** Ante una regresión, el operador debe ejecutar `kubectl rollout undo` a mano, tras haberla detectado a mano. El **MTTR** (mean time to recovery) queda atado al tiempo de reacción humano y a la latencia del pipeline de CI/CD, no al tiempo real de degradación del servicio.

3. **El control de tráfico es una aproximación por conteo de réplicas.** Con `RollingUpdate`, la única palanca de "porcentaje de tráfico a la versión nueva" es la proporción de pods nuevos sobre el total, y el reparto depende de `kube-proxy`/Service (round-robin sobre endpoints), no de un peso declarado. No podés decir "mandá exactamente el 5 % del tráfico a v2 con 20 pods estables y 1 canary": el Service repartiría ~1/21 ≈ 4,7 %, atado al conteo, no al SLO.

### 1.2 Qué agrega Argo Rollouts

Argo Rollouts es un **controlador Kubernetes + un conjunto de CRDs** que reemplaza al `Deployment` por un recurso `Rollout` (superconjunto casi idéntico del `Deployment.spec`) y aporta **progressive delivery**:

- **Estrategias avanzadas:** `blueGreen` y `canary` con pasos declarativos (`steps`).
- **Traffic management desacoplado del conteo de réplicas:** integración con ingress controllers y service meshes (NGINX, ALB, Istio, Gateway API, Traefik, APISIX, Kong…) para partir el tráfico por **peso declarado**.
- **Análisis y rollback automático:** los CRDs `AnalysisTemplate`/`AnalysisRun` consultan Prometheus, Datadog, CloudWatch, un `Job`, un endpoint HTTP, etc., y **abortan el rollout automáticamente** si una métrica cruza un umbral. El MTTR pasa a ser el tiempo del intervalo de análisis, no el de reacción humana.
- **Experimentación:** el CRD `Experiment` levanta ReplicaSets efímeros para A/B testing con duración acotada.

### 1.3 Mecánica interna (cómo trabaja el controlador)

Igual que el `Deployment`, el `Rollout` **no gestiona pods directamente**: gestiona **ReplicaSets**. En cada cambio del `spec.template`:

1. El controlador calcula el hash del pod template y lo escribe en la etiqueta `rollouts-pod-template-hash` (análoga a `pod-template-hash` del Deployment). Ese hash identifica de forma estable cada ReplicaSet.
2. Crea (o reutiliza, si el hash ya existió) el ReplicaSet de la nueva revisión y **modula el `replicas` de cada ReplicaSet** para materializar cada `step`.
3. Reescribe el `selector` de los Services `canary`/`stable` (o `active`/`preview`) inyectándoles el `rollouts-pod-template-hash` correspondiente, de modo que cada Service apunte exactamente a la revisión deseada — este es el mecanismo que hace posible el blue-green y el canary **sin** traffic router.
4. Si hay `trafficRouting`, además programa el peso en el ingress/mesh (annotations de NGINX, `TargetGroup` del ALB, `VirtualService`/`DestinationRule` de Istio, `HTTPRoute` de Gateway API…), y entonces el peso deja de depender del conteo de réplicas.

Estados (`.status.phase`) que debés reconocer: **Progressing**, **Paused**, **Healthy**, **Degraded**. Un `AnalysisRun` transita **Pending → Running → {Successful | Failed | Error | Inconclusive}**.

---

## 2. Comparativas técnicas (trade-offs)

### 2.1 Deployment vs. Rollout (canary vs. blue-green)

| Dimensión | `Deployment` (RollingUpdate) | `Rollout` canary | `Rollout` blueGreen |
|---|---|---|---|
| Control de progreso | Automático hasta 100 % | `steps`: `setWeight` + `pause` + `analysis` | Un salto: preview → active al promover |
| Gate de análisis | No | Sí (por step o `background`) | Sí (`pre`/`postPromotionAnalysis`) |
| Rollback automático | No | Sí (aborta ante `failureLimit`) | Sí (aborta en pre-promotion) |
| Coste en réplicas extra | `maxSurge` (parcial) | Bajo (solo el % del canary) | **2× réplicas** durante la ventana |
| Reparto de tráfico | Por conteo de pods | Por **peso** (con router) o por conteo | 0 %/100 % (corte limpio) |
| Tiempo de exposición del blast radius | Alto | Muy bajo (empieza en 5–20 %) | Nulo hasta el switch, total al switch |
| Ventana de rollback tras promover | Reprogramar RS | Reprogramar RS | Inmediato si `scaleDownDelaySeconds` no venció |
| Casos de uso | Servicios internos/tolerantes | APIs de alto tráfico, SLO estrictos | Cambios de esquema, cutovers atómicos, tests E2E previos |

**Lectura de arquitecto:** el blue-green minimiza el *tiempo* de riesgo (nadie ve v2 hasta que vos decidís) a cambio de duplicar capacidad y de un blast radius del 100 % en el instante del switch. El canary minimiza el *blast radius* (siempre hay un subconjunto pequeño expuesto) a cambio de que v1 y v2 conviven — problemático si hay migraciones de esquema no retrocompatibles.

### 2.2 Canary con traffic router vs. sin él

| | Sin `trafficRouting` (basic canary) | Con `trafficRouting` (NGINX/Istio/ALB/Gateway API) |
|---|---|---|
| Cómo se logra el peso | Proporción de réplicas canary/total | Peso declarado en el data plane |
| Granularidad | Cuantizada por réplica (5 % ⇒ ~20 pods) | Fina e independiente del conteo |
| `setCanaryScale` | Limitado | Desacopla escala de peso (p. ej. 10 % de tráfico con 1 pod) |
| Dependencias | Ninguna | Un provider soportado desplegado |
| Coste de infra | Mínimo | El del mesh/ingress |

### 2.3 Providers de traffic routing (panorama)

| Provider | Nivel | Header/mirror routing | Notas de producción |
|---|---|---|---|
| NGINX Ingress | L7 ingress | Canary por `nginx.ingress.kubernetes.io/canary-*` | Crea un ingress "canary" gestionado; simple y muy usado |
| AWS ALB | L7 (TargetGroup) | Sí | Pesos a nivel de `TargetGroupBinding`; requiere AWS LB Controller |
| Istio | Service mesh | Header, mirror, subsets | El más rico: `VirtualService` + `DestinationRule` |
| Gateway API | Estándar K8s | Sí (plugin) | Portable entre implementaciones; futuro-proof |
| Traefik / APISIX / Kong | Ingress/API GW | Según plugin | Buenos si ya son tu ingress |
| SMI | Abstracción de mesh | Limitado | **Deprecado**; no elegir para greenfield |

---

## 3. Manifiestos completos

### 3.1 Instalación del controlador y del plugin CLI

```bash
# Namespace y controlador (release estable)
$ kubectl create namespace argo-rollouts
$ kubectl apply -n argo-rollouts \
    -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

# Plugin kubectl (Linux amd64)
$ curl -sSL -o kubectl-argo-rollouts-linux-amd64 \
    https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
$ chmod +x kubectl-argo-rollouts-linux-amd64
$ sudo mv kubectl-argo-rollouts-linux-amd64 /usr/local/bin/kubectl-argo-rollouts
$ kubectl argo rollouts version
kubectl-argo-rollouts: v1.7.2+... 
```

### 3.2 Canary con traffic routing (NGINX) + análisis en background

Manifiesto completo, sin recortar: `Rollout`, ambos `Service`, el `Ingress` estable y el `AnalysisTemplate`.

```yaml
# rollout-canary.yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: rollouts-demo
  namespace: demo
spec:
  replicas: 10
  revisionHistoryLimit: 3
  selector:
    matchLabels:
      app: rollouts-demo
  template:
    metadata:
      labels:
        app: rollouts-demo
    spec:
      containers:
      - name: rollouts-demo
        image: argoproj/rollouts-demo:blue
        ports:
        - containerPort: 8080
        resources:
          requests:
            cpu: "50m"
            memory: "64Mi"
          limits:
            cpu: "200m"
            memory: "128Mi"
        readinessProbe:
          httpGet:
            path: /
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5
  strategy:
    canary:
      canaryService: rollouts-demo-canary
      stableService: rollouts-demo-stable
      trafficRouting:
        nginx:
          stableIngress: rollouts-demo-stable
      # maxSurge/maxUnavailable rigen el reemplazo dentro de cada step
      maxSurge: "25%"
      maxUnavailable: 0
      # Análisis continuo mientras el canary vive (no por-step)
      analysis:
        templates:
        - templateName: success-rate
        startingStep: 2          # empieza a analizar recién tras el segundo step
        args:
        - name: canary-svc
          value: rollouts-demo-canary
      steps:
      - setWeight: 5
      - pause: {duration: 2m}
      - setWeight: 20
      - pause: {duration: 5m}
      - setWeight: 50
      - pause: {duration: 5m}
      - setWeight: 80
      - pause: {duration: 5m}
      # sin un step final: al terminar promueve al 100 %
---
apiVersion: v1
kind: Service
metadata:
  name: rollouts-demo-stable
  namespace: demo
spec:
  selector:
    app: rollouts-demo        # el controlador le inyecta rollouts-pod-template-hash
  ports:
  - port: 80
    targetPort: 8080
    protocol: TCP
---
apiVersion: v1
kind: Service
metadata:
  name: rollouts-demo-canary
  namespace: demo
spec:
  selector:
    app: rollouts-demo
  ports:
  - port: 80
    targetPort: 8080
    protocol: TCP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: rollouts-demo-stable
  namespace: demo
  annotations:
    kubernetes.io/ingress.class: nginx
spec:
  rules:
  - host: rollouts-demo.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: rollouts-demo-stable   # el controlador crea el ingress "canary" en paralelo
            port:
              number: 80
```

```yaml
# analysis-success-rate.yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: success-rate
  namespace: demo
spec:
  args:
  - name: canary-svc
  metrics:
  - name: success-rate
    interval: 1m
    count: 5                    # 5 muestras; sin count, corre indefinidamente
    successCondition: result[0] >= 0.95
    failureLimit: 3             # 3 fallos ⇒ AnalysisRun Failed ⇒ Rollout abortado
    inconclusiveLimit: 2
    provider:
      prometheus:
        address: http://prometheus-server.monitoring.svc.cluster.local:80
        query: |
          sum(rate(
            http_requests_total{service="{{args.canary-svc}}", code!~"5.."}[2m]
          )) /
          sum(rate(
            http_requests_total{service="{{args.canary-svc}}"}[2m]
          ))
```

> **Semántica de `successCondition`/`failureCondition`:** son expresiones que evalúan `result` (array del provider). `failureLimit` cuenta cuántas mediciones **fallidas** se toleran antes de marcar el `AnalysisRun` como `Failed`; `inconclusiveLimit` hace lo propio con las **inconclusivas** (ni éxito ni fallo). Un `AnalysisRun` `Failed` **aborta y hace rollback** del rollout.

### 3.3 Blue-Green con pre/post-promotion analysis

```yaml
# rollout-bluegreen.yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: bluegreen-demo
  namespace: demo
spec:
  replicas: 4
  revisionHistoryLimit: 2
  selector:
    matchLabels:
      app: bluegreen-demo
  template:
    metadata:
      labels:
        app: bluegreen-demo
    spec:
      containers:
      - name: app
        image: argoproj/rollouts-demo:blue
        ports:
        - containerPort: 8080
        readinessProbe:
          httpGet: {path: /, port: 8080}
          periodSeconds: 5
  strategy:
    blueGreen:
      activeService: bluegreen-active     # tráfico de producción
      previewService: bluegreen-preview   # solo para validar v2 en privado
      autoPromotionEnabled: false         # gate humano: no promueve solo
      # autoPromotionSeconds: 300         # alternativa: promueve solo tras 5m
      prePromotionAnalysis:               # corre ANTES de mover el active
        templates:
        - templateName: smoke-tests
        args:
        - name: preview-svc
          value: bluegreen-preview
      postPromotionAnalysis:              # corre DESPUÉS de mover el active
        templates:
        - templateName: success-rate
        args:
        - name: canary-svc
          value: bluegreen-active
      scaleDownDelaySeconds: 30           # ventana para rollback instantáneo del RS viejo
      antiAffinity:
        preferredDuringSchedulingIgnoredDuringExecution:
          weight: 1
---
apiVersion: v1
kind: Service
metadata: {name: bluegreen-active, namespace: demo}
spec:
  selector: {app: bluegreen-demo}
  ports: [{port: 80, targetPort: 8080}]
---
apiVersion: v1
kind: Service
metadata: {name: bluegreen-preview, namespace: demo}
spec:
  selector: {app: bluegreen-demo}
  ports: [{port: 80, targetPort: 8080}]
```

`smoke-tests` como análisis basado en `Job` (útil para validaciones E2E antes de promover):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata: {name: smoke-tests, namespace: demo}
spec:
  args:
  - name: preview-svc
  metrics:
  - name: smoke
    provider:
      job:
        spec:
          backoffLimit: 1
          template:
            spec:
              restartPolicy: Never
              containers:
              - name: test
                image: curlimages/curl:8.8.0
                command: ["sh", "-c"]
                args:
                - |
                  set -e
                  for i in $(seq 1 20); do
                    curl -fsS "http://{{args.preview-svc}}.demo.svc.cluster.local/healthz" >/dev/null
                  done
```

> Con el provider `job`, el éxito del `Job` (exit 0) ⇒ métrica exitosa; su fallo ⇒ `AnalysisRun` `Failed`.

### 3.4 `workloadRef`: adoptar un `Deployment` existente sin migrar el template

Para brownfield, el `Rollout` puede **referenciar** un `Deployment` en vez de embeber el `template`. El controlador escala el Deployment a 0 y toma el mando:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata: {name: rollout-ref, namespace: demo}
spec:
  replicas: 5
  workloadRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-existing-deployment
    scaleDown: onsuccess        # progressively | never | onsuccess
  strategy:
    canary:
      steps:
      - setWeight: 25
      - pause: {duration: 1m}
      - setWeight: 75
      - pause: {duration: 1m}
```

---

## 4. Comandos CLI y salidas reales

### 4.1 Observar un canary en vivo

```bash
$ kubectl argo rollouts get rollout rollouts-demo -n demo --watch
Name:            rollouts-demo
Namespace:       demo
Status:          ॥ Paused
Message:         CanaryPauseStep
Strategy:        Canary
  Step:          1/8
  SetWeight:     5
  ActualWeight:  5
Images:          argoproj/rollouts-demo:blue (stable)
                 argoproj/rollouts-demo:yellow (canary)
Replicas:
  Desired:       10
  Current:       11
  Updated:       1
  Ready:         11
  Available:     11

NAME                                       KIND        STATUS     AGE    INFO
⟳ rollouts-demo                            Rollout     ॥ Paused   14m
├──# revision:2
│  └──⧉ rollouts-demo-687d76d795           ReplicaSet  ✔ Healthy  95s    canary
│     └──□ rollouts-demo-687d76d795-4xt2n  Pod         ✔ Running  95s    ready:1/1
└──# revision:1
   └──⧉ rollouts-demo-6cf78c96c4           ReplicaSet  ✔ Healthy  14m    stable
      ├──□ rollouts-demo-6cf78c96c4-2z6qv  Pod         ✔ Running  14m    ready:1/1
      └──□ rollouts-demo-6cf78c96c4-8h4kn  Pod         ✔ Running  14m    ready:1/1
```

### 4.2 Disparar una nueva revisión y conducirla

```bash
# Cambiar la imagen ⇒ nueva revisión ⇒ arranca el canary
$ kubectl argo rollouts set image rollouts-demo \
    rollouts-demo=argoproj/rollouts-demo:yellow -n demo
rollout "rollouts-demo" image updated

# Ver estado resumido (bloquea hasta un estado terminal o pausa)
$ kubectl argo rollouts status rollouts-demo -n demo
Paused - CanaryPauseStep

# Promover al siguiente step (salta el pause actual)
$ kubectl argo rollouts promote rollouts-demo -n demo
rollout "rollouts-demo" promoted

# Promover hasta el final saltando TODOS los steps y análisis restantes
$ kubectl argo rollouts promote rollouts-demo -n demo --full
rollout "rollouts-demo" fully promoted
```

### 4.3 Abortar, reintentar, deshacer

```bash
# Abortar: vuelve el peso a 0 y reescala el stable (NO borra la revisión canary)
$ kubectl argo rollouts abort rollouts-demo -n demo
rollout "rollouts-demo" aborted

$ kubectl argo rollouts get rollout rollouts-demo -n demo
Status:   ✖ Degraded
Message:  RolloutAborted: Rollout aborted update to revision 2

# Reintentar un rollout abortado (reanuda desde el principio de los steps)
$ kubectl argo rollouts retry rollout rollouts-demo -n demo
rollout "rollouts-demo" retried

# Rollback declarativo a una revisión anterior
$ kubectl argo rollouts undo rollouts-demo --to-revision=1 -n demo
rollout "rollouts-demo" undo
```

### 4.4 Blue-green: promover el switch

```bash
$ kubectl argo rollouts get rollout bluegreen-demo -n demo
Name:            bluegreen-demo
Status:          ॥ Paused
Message:         BlueGreenPause
Strategy:        BlueGreen
Images:          argoproj/rollouts-demo:blue   (stable, active)
                 argoproj/rollouts-demo:green  (preview)

# Validado el preview y pasado el prePromotionAnalysis ⇒ mover el active
$ kubectl argo rollouts promote bluegreen-demo -n demo
rollout "bluegreen-demo" promoted
```

### 4.5 Dashboard local

```bash
$ kubectl argo rollouts dashboard -n demo
INFO[0000] Argo Rollouts Dashboard is now available at http://localhost:3100/rollouts
```

---

## 5. Verificación y diagnóstico de fallas

### 5.1 Checklist de verificación

```bash
# 1) El controlador está sano
$ kubectl -n argo-rollouts get deploy argo-rollouts
NAME            READY   UP-TO-DATE   AVAILABLE   AGE
argo-rollouts   1/1     1            1           3d

# 2) Los CRDs están instalados
$ kubectl get crd | grep argoproj.io
analysisruns.argoproj.io
analysistemplates.argoproj.io
clusteranalysistemplates.argoproj.io
experiments.argoproj.io
rollouts.argoproj.io

# 3) El controlador inyectó el hash en los Services
$ kubectl get svc rollouts-demo-canary -n demo -o jsonpath='{.spec.selector}'
{"app":"rollouts-demo","rollouts-pod-template-hash":"687d76d795"}

# 4) Estado y condiciones del rollout
$ kubectl get rollout rollouts-demo -n demo \
    -o jsonpath='{.status.phase}{"\t"}{.status.message}{"\n"}'
Progressing     more replicas need to be updated
```

### 5.2 Inspeccionar el análisis que decidió el rollback

```bash
$ kubectl get analysisrun -n demo
NAME                              STATUS   AGE
rollouts-demo-687d76d795-2-0      Failed   6m

$ kubectl argo rollouts get rollout rollouts-demo -n demo | sed -n '/Analysis/,$p'
   └──α rollouts-demo-687d76d795-2-0   AnalysisRun  ✖ Failed   6m   ✖ 3,✔ 2

# Detalle de la métrica y los valores medidos
$ kubectl describe analysisrun rollouts-demo-687d76d795-2-0 -n demo
...
Metric Results:
  Name:   success-rate
  Phase:  Failed
  Failed: 3
  Measurements:
    Value:  0.87   Phase: Failed
    Value:  0.83   Phase: Failed
    Value:  0.79   Phase: Failed
```

### 5.3 Tabla de síntomas → causa → acción

| Síntoma | Causa probable | Diagnóstico / acción |
|---|---|---|
| `Status: Degraded`, `RolloutAborted` | `AnalysisRun` `Failed` o `abort` manual | `kubectl describe analysisrun …`; corregir métrica/umbral; `retry` |
| El canary queda en `Paused` para siempre | `pause: {}` sin `duration` | Requiere gate manual: `promote`; o agregar `duration` |
| Peso real (`ActualWeight`) ≠ peso pedido | Sin `trafficRouting`: peso cuantizado por réplicas | Añadir un provider, o subir `replicas` para granularidad |
| `AnalysisRun` en `Error` (no `Failed`) | Provider inaccesible (Prometheus caído, query inválida) | Revisar `address`/`query`; ver logs del controlador |
| Services `active`/`canary` sin `rollouts-pod-template-hash` | Nombres mal referenciados en `strategy` | Verificar `canaryService`/`stableService`/`activeService` |
| `error: no matches for kind "Rollout"` | CRDs ausentes o `argoproj.io/v1alpha1` mal escrito | Reinstalar CRDs; validar `apiVersion` |
| Tras promover blue-green, no puedo hacer rollback instantáneo | `scaleDownDelaySeconds` ya venció | Subir el delay; o `undo --to-revision` |
| CLI-agent backend devuelve recap en lugar de contenido | (fuera de Rollouts) — n/a | n/a |

### 5.4 Logs del controlador (última línea de defensa)

```bash
$ kubectl -n argo-rollouts logs deploy/argo-rollouts --tail=20 | grep -i "rollouts-demo"
time="..." level=info msg="Started syncing Rollout" namespace=demo rollout=rollouts-demo
time="..." level=info msg="Trafficrouting Reconciliation begins" ...
time="..." level=error msg="AnalysisRun 'rollouts-demo-687d76d795-2-0' failed: metric 'success-rate' assessed Failed"
time="..." level=info msg="Rollout aborted update to revision 2"
```

### 5.5 Eventos correlacionados

```bash
$ kubectl describe rollout rollouts-demo -n demo | sed -n '/Events:/,$p'
Events:
  Type     Reason                 Age   From                 Message
  ----     ------                 ----  ----                 -------
  Normal   RolloutUpdated         12m   rollouts-controller  Rollout updated to revision 2
  Normal   RolloutStepCompleted   11m   rollouts-controller  Rollout step 1/8 completed (setWeight: 5)
  Warning  RolloutAborted         6m    rollouts-controller  Rollout aborted update to revision 2
```

---

## 6. Referencias

- Argo Rollouts — documentación oficial: https://argo-rollouts.readthedocs.io/en/stable/
- Repositorio y releases: https://github.com/argoproj/argo-rollouts
- Especificación del recurso `Rollout`: https://argo-rollouts.readthedocs.io/en/stable/features/specification/
- Estrategia Canary: https://argo-rollouts.readthedocs.io/en/stable/features/canary/
- Estrategia Blue-Green: https://argo-rollouts.readthedocs.io/en/stable/features/bluegreen/
- Análisis y progressive delivery: https://argo-rollouts.readthedocs.io/en/stable/features/analysis/
- Traffic management (visión general): https://argo-rollouts.readthedocs.io/en/stable/features/traffic-management/
- NGINX Ingress: https://argo-rollouts.readthedocs.io/en/stable/features/traffic-management/nginx/
- Istio: https://argo-rollouts.readthedocs.io/en/stable/features/traffic-management/istio/
- AWS ALB: https://argo-rollouts.readthedocs.io/en/stable/features/traffic-management/alb/
- Gateway API (plugin): https://argoproj.github.io/argo-rollouts/features/traffic-management/plugins/
- Plugin `kubectl argo rollouts`: https://argo-rollouts.readthedocs.io/en/stable/features/kubectl-plugin/
- `Experiment` CRD: https://argo-rollouts.readthedocs.io/en/stable/features/experiment/
- Currículo oficial CAPA (CNCF): https://github.com/cncf/curriculum/blob/master/capa/README.md