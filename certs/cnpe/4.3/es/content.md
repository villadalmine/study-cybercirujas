# Tema 4.3 — Deploying Applications Using Progressive Delivery Strategies (Blue/Green, Canary)

> **Certificación:** CNPE (Certified Cloud Native Platform Engineer) · Dominio 4 (Application Delivery) · Peso 8.34
> **Perfil:** SRE / Platform Architect — mecánica interna, trade-offs y operación en producción.

---

## 1. Motivación y el problema arquitectónico de producción

### 1.1 Qué falla con un despliegue "atómico"

El objetivo de un plataform engineer no es *hacer un deploy*, es **acotar el radio de impacto (blast radius) de un cambio malo y hacer que la reversión sea barata, rápida y automática**. Un `kubectl set image` sobre un `Deployment` con `RollingUpdate` ya es progresivo a nivel de *pods*, pero tiene tres límites duros que en producción se convierten en incidentes:

1. **El criterio de avance es la *readiness*, no la *corrección*.** El rollout avanza en cuanto los nuevos pods pasan su `readinessProbe`. Un pod puede estar *ready* y aun así devolver `500` en el 4 % de las requests, tener una regresión de latencia p99, o corromper datos. `RollingUpdate` no mira métricas de negocio ni SLOs; mira TCP/HTTP de un endpoint de health.
2. **No hay una fase de observación controlada.** Una vez que empieza, el rollout corre hasta el final salvo que un humano lo pause. No existe "mandá 1 % del tráfico, esperá 10 minutos, mirá el error-rate y recién ahí seguí".
3. **La reversión es otro rollout completo.** `kubectl rollout undo` vuelve a hacer un `RollingUpdate` en reversa: tarda, vuelve a agitar el `ReplicaSet` viejo, y durante ese tiempo el tráfico sigue pegándole a la versión mala.

Progressive Delivery es la disciplina que separa **dos ejes que `RollingUpdate` fusiona**:

- **Deployment** — *poner el código corriendo* en el cluster.
- **Release** — *dirigir tráfico de usuarios* hacia ese código.

Cuando desacoplás ambos, podés tener la versión nueva corriendo (deployed) recibiendo 0 % del tráfico de producción (not released), y promover el release por métricas, no por el simple hecho de que el proceso arrancó.

### 1.2 El rol del Platform Engineer

El CNPE no evalúa "sé hacer un canary a mano". Evalúa que puedas **construir la *capability* de progressive delivery como un producto de plataforma**: un golden path donde el equipo de aplicación declara *intención* (`estrategia: canary, pasos: [5,25,50], SLO: error-rate < 1%`) y la plataforma se encarga del control de tráfico, el análisis de métricas y el rollback automático. Eso implica integrar:

- Un **controller de rollout** (Argo Rollouts o Flagger).
- Un **data plane de tráfico** (Service mesh — Istio/Linkerd — o Gateway API / Ingress).
- Una **fuente de verdad de métricas** (Prometheus, Datadog, CloudWatch) para el *AnalysisTemplate*.
- **Guardrails**: rollback automático, límites de blast radius, y GitOps como sistema de registro.

---

## 2. Taxonomía de estrategias y trade-offs

### 2.1 Las cuatro estrategias base

| Estrategia | Mecánica | Coste de infra | Ventana de riesgo | Reversión | Casos de datos |
|---|---|---|---|---|---|
| **Recreate** | Mata todo v1, arranca v2 | 1× | Downtime total | Redeploy | Migraciones incompatibles, singleton |
| **RollingUpdate** | Reemplaza pods de a `maxSurge`/`maxUnavailable` | ~1.25× | Todo el tráfico ve v2 progresivamente por pods | `rollout undo` (lento) | Default seguro para stateless |
| **Blue/Green** | Dos entornos completos; se conmuta el `Service` selector de golpe | **2×** | 100 % del tráfico salta de una | Reapuntar el selector (instantáneo) | Necesitás validar el entorno completo antes de exponerlo |
| **Canary** | v2 recibe un % creciente del tráfico junto a v1 | 1× + N réplicas canary | Solo el % enrutado ve v2 | Bajar el peso a 0 % (instantáneo) | Blast radius mínimo, análisis por métricas |

### 2.2 Blue/Green vs Canary — el trade-off central del examen

| Dimensión | **Blue/Green** | **Canary** |
|---|---|---|
| **Granularidad de tráfico** | Binaria: 0 % o 100 % | Continua: 1 %, 5 %, 25 %… |
| **Blast radius de un bug** | Todos los usuarios a la vez tras el switch | Solo la cohorte enrutada |
| **Coste de cómputo** | 2× (dos stacks completos en paralelo) | 1× + réplicas canary (fracción) |
| **Velocidad de switch/rollback** | Instantáneo (cambio de selector) | Gradual, pero bajar a 0 % es instantáneo |
| **Requiere control de tráfico L7** | No (basta cambiar el selector del Service) | Sí, para % fino (mesh/Gateway API); sin mesh solo % por conteo de réplicas |
| **Análisis por métricas** | Difícil: hasta el switch, v2 no ve tráfico real | Natural: cada step observa tráfico real de producción |
| **Sesiones/sticky** | Simple: un usuario ve v1 **o** v2 | Cuidado: sin session affinity un usuario oscila entre versiones |
| **Idóneo para** | Cambios grandes que querés validar como un todo (smoke test full-stack antes de exponer) | Cambios incrementales, alto tráfico, donde el % + métricas dan confianza estadística |

**Regla de arquitecto:** Blue/Green optimiza la **reversibilidad instantánea a costa de duplicar infra**; Canary optimiza el **blast radius y el análisis estadístico a costa de exigir un data plane L7**. En un servicio de alto tráfico con SLOs medibles, Canary con análisis automático es superior. Blue/Green brilla cuando el cambio *no se puede validar por partes* (p. ej. un cambio de esquema coordinado, o cuando necesitás un entorno idéntico para smoke tests E2E antes de dar la cara).

### 2.3 El problema del data plane: ¿cómo se parte el tráfico realmente?

El % de canary no lo hace mágicamente Kubernetes. Hay tres mecanismos, de menor a mayor fidelidad:

| Mecanismo | Granularidad real | Cómo funciona | Límite |
|---|---|---|---|
| **Réplicas (kube-proxy)** | Aproximada, por conteo | El `Service` balancea sobre *endpoints*; si canary tiene 1 de 10 pods, recibe ~10 % | No hay control fino; 5 % exige 19:1 pods; sin métricas por versión |
| **Ingress weighted** (NGINX `canary-weight`, ALB) | Fina en L7, sin mTLS/telemetría | El Ingress controller reparte por peso | Acoplado al Ingress; sin métricas de mesh |
| **Service Mesh / Gateway API** | Fina (1 %), con telemetría y mTLS | `VirtualService`/`HTTPRoute` con `weight`; el mesh emite métricas por subset | Complejidad operativa del mesh |

Este es el punto que separa un canary "de juguete" (peso por réplicas) de uno de producción (peso L7 + métricas por versión para el análisis automático).

---

## 3. Implementaciones completas

Voy a mostrar cuatro capas, de la primitiva nativa a la plataforma completa:
**A)** Kubernetes puro (Blue/Green por selector, Canary por réplicas) · **B)** Canary L7 con Gateway API · **C)** Argo Rollouts con análisis automático · **D)** Flagger + Istio (canary declarativo dirigido por SLO).

### 3.A — Kubernetes nativo (sin controllers extra)

#### 3.A.1 Blue/Green por conmutación de selector

Dos `Deployment` con el mismo `app` pero distinto label `version`. Un único `Service` de producción cuyo `selector` decide quién recibe tráfico. La conmutación es un `kubectl patch` sobre el selector — atómica desde la perspectiva del cliente.

```yaml
# blue-green.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout-blue
  labels: {app: checkout, version: blue}
spec:
  replicas: 4
  selector:
    matchLabels: {app: checkout, version: blue}
  template:
    metadata:
      labels: {app: checkout, version: blue}
    spec:
      containers:
        - name: checkout
          image: registry.example.com/checkout:1.7.3
          ports: [{containerPort: 8080}]
          readinessProbe:
            httpGet: {path: /healthz/ready, port: 8080}
            initialDelaySeconds: 5
            periodSeconds: 5
          resources:
            requests: {cpu: 250m, memory: 256Mi}
            limits: {cpu: "1", memory: 512Mi}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout-green
  labels: {app: checkout, version: green}
spec:
  replicas: 4
  selector:
    matchLabels: {app: checkout, version: green}
  template:
    metadata:
      labels: {app: checkout, version: green}
    spec:
      containers:
        - name: checkout
          image: registry.example.com/checkout:1.8.0   # versión nueva
          ports: [{containerPort: 8080}]
          readinessProbe:
            httpGet: {path: /healthz/ready, port: 8080}
            initialDelaySeconds: 5
            periodSeconds: 5
          resources:
            requests: {cpu: 250m, memory: 256Mi}
            limits: {cpu: "1", memory: 512Mi}
---
# Service de PRODUCCIÓN — arranca apuntando a blue
apiVersion: v1
kind: Service
metadata:
  name: checkout
spec:
  selector: {app: checkout, version: blue}   # <- este campo es el "switch"
  ports:
    - {port: 80, targetPort: 8080}
---
# Service de PREVIEW — siempre apunta a green, para smoke tests fuera de banda
apiVersion: v1
kind: Service
metadata:
  name: checkout-preview
spec:
  selector: {app: checkout, version: green}
  ports:
    - {port: 80, targetPort: 8080}
```

**El switch, la validación previa y el rollback:**

```console
$ kubectl apply -f blue-green.yaml
deployment.apps/checkout-blue created
deployment.apps/checkout-green created
service/checkout created
service/checkout-preview created

# 1) Green ya corre pero NO recibe tráfico de producción. Smoke test por el preview Service:
$ kubectl run smoke --rm -it --image=curlimages/curl --restart=Never -- \
    curl -s -o /dev/null -w '%{http_code}\n' http://checkout-preview/healthz/ready
200

# 2) Confirmá qué endpoints resuelve el Service de producción (deben ser TODOS blue):
$ kubectl get endpointslices -l kubernetes.io/service-name=checkout \
    -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{"\n"}{end}'
checkout-blue-7c9d5f7b8-2xk4p
checkout-blue-7c9d5f7b8-9mnq7
checkout-blue-7c9d5f7b8-h4v2t
checkout-blue-7c9d5f7b8-wq8lr

# 3) SWITCH atómico: reapuntá el selector del Service de producción a green.
$ kubectl patch service checkout -p '{"spec":{"selector":{"app":"checkout","version":"green"}}}'
service/checkout patched

# 4) Verificá que los endpoints ahora son green:
$ kubectl get endpointslices -l kubernetes.io/service-name=checkout \
    -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{"\n"}{end}'
checkout-green-6f8b4c9d5-4rt7x
checkout-green-6f8b4c9d5-8kp2m
checkout-green-6f8b4c9d5-lq9wz
checkout-green-6f8b4c9d5-nv3hs

# 5) ROLLBACK instantáneo si algo se rompe — un patch en reversa:
$ kubectl patch service checkout -p '{"spec":{"selector":{"app":"checkout","version":"blue"}}}'
service/checkout patched
```

> **Trampa de producción (conntrack):** el cambio de selector reasigna endpoints, pero las **conexiones TCP keep-alive ya establecidas** contra pods blue no se cortan solas — kube-proxy solo afecta a *conexiones nuevas*. Clientes con connection pooling (gRPC, HTTP/2, drivers de DB) pueden seguir hablando con blue por minutos. Para un corte real necesitás draining a nivel L7 (mesh) o forzar el reciclado de conexiones. Este matiz es exactamente lo que un mesh resuelve y `kube-proxy` no.

#### 3.A.2 Canary "pobre" por réplicas

Sin mesh, el % de tráfico es aproximado y lo da la proporción de pods detrás de **un mismo Service** (mismo label `app`, ignorando `version`):

```yaml
# Service que selecciona AMBAS versiones — el peso lo da el conteo de réplicas
apiVersion: v1
kind: Service
metadata: {name: checkout}
spec:
  selector: {app: checkout}          # sin 'version' -> incluye stable y canary
  ports: [{port: 80, targetPort: 8080}]
```

```console
# 9 stable + 1 canary  ≈ 10 % del tráfico al canary
$ kubectl scale deployment checkout-stable --replicas=9
$ kubectl scale deployment checkout-canary --replicas=1
```

**Limitación:** para 5 % necesitás 19:1 pods (desperdicio), no hay session affinity, y el `Service` no te da métricas por versión. Sirve para clusters mínimos; **no es progressive delivery de producción**. Se muestra para entender por qué el mesh/Gateway API es necesario.

---

### 3.B — Canary con Gateway API (traffic splitting nativo, sin mesh)

La Gateway API (GA en `v1`, `gateway.networking.k8s.io/v1`) estandariza el weighted routing con `HTTPRoute.spec.rules[].backendRefs[].weight` — portable entre implementaciones (Istio, Contour, Cilium, NGINX Gateway Fabric, Envoy Gateway).

```yaml
# gateway-canary.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: edge
  namespace: shop
spec:
  gatewayClassName: istio          # o 'cilium', 'contour', 'envoy-gateway'…
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces: {from: Same}
---
apiVersion: v1
kind: Service
metadata: {name: checkout-stable, namespace: shop}
spec:
  selector: {app: checkout, version: stable}
  ports: [{port: 80, targetPort: 8080}]
---
apiVersion: v1
kind: Service
metadata: {name: checkout-canary, namespace: shop}
spec:
  selector: {app: checkout, version: canary}
  ports: [{port: 80, targetPort: 8080}]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: checkout
  namespace: shop
spec:
  parentRefs:
    - name: edge
  hostnames: ["shop.example.com"]
  rules:
    - matches:
        - path: {type: PathPrefix, value: /checkout}
      backendRefs:
        - name: checkout-stable
          port: 80
          weight: 95            # 95 % stable
        - name: checkout-canary
          port: 80
          weight: 5             # 5 % canary
```

**Promoción manual por steps (weight-shifting):**

```console
$ kubectl apply -f gateway-canary.yaml
gateway.gateway.networking.k8s.io/edge created
httproute.gateway.networking.k8s.io/checkout created

# Verificá que el Gateway obtuvo dirección y que la ruta está aceptada:
$ kubectl get gateway edge -n shop -o jsonpath='{.status.addresses[0].value}{"\n"}'
34.120.88.14
$ kubectl get httproute checkout -n shop \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}{"\n"}'
True

# Muestreo real del split (100 requests):
$ for i in $(seq 1 100); do curl -s http://34.120.88.14/checkout/version; done | sort | uniq -c
     95 1.7.3
      5 1.8.0

# Subí el canary a 25 %:
$ kubectl patch httproute checkout -n shop --type=json -p='[
  {"op":"replace","path":"/spec/rules/0/backendRefs/0/weight","value":75},
  {"op":"replace","path":"/spec/rules/0/backendRefs/1/weight","value":25}]'
httproute.gateway.networking.k8s.io/checkout patched
```

Gateway API te da el weighted routing portable **sin** análisis automático — eso lo agregan Argo Rollouts o Flagger encima.

---

### 3.C — Argo Rollouts: canary declarativo con análisis y rollback automático

`Rollout` reemplaza al `Deployment` (mismo `spec.template`) y agrega `spec.strategy.canary` con `steps` y `analysis`. Integra con Gateway API / Istio / SMI / Ingress para el peso, y con `AnalysisTemplate` (Prometheus, Datadog, Web, Job…) para el criterio de avance.

#### 3.C.1 AnalysisTemplate — el guardrail por métricas

```yaml
# analysis-success-rate.yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: success-rate
  namespace: shop
spec:
  args:
    - name: service-name
    - name: canary-hash
  metrics:
    - name: success-rate
      interval: 1m
      count: 5                 # 5 mediciones antes de aprobar el step
      successCondition: result[0] >= 0.99
      failureLimit: 2          # 2 fallos -> aborta y hace rollback
      provider:
        prometheus:
          address: http://prometheus.monitoring.svc:9090
          query: |
            sum(rate(
              istio_requests_total{
                destination_service_name="{{args.service-name}}",
                response_code!~"5.*"
              }[2m]
            ))
            /
            sum(rate(
              istio_requests_total{
                destination_service_name="{{args.service-name}}"
              }[2m]
            ))
    - name: latency-p99
      interval: 1m
      count: 5
      successCondition: result[0] <= 500     # p99 <= 500ms
      failureLimit: 2
      provider:
        prometheus:
          address: http://prometheus.monitoring.svc:9090
          query: |
            histogram_quantile(0.99,
              sum(rate(
                istio_request_duration_milliseconds_bucket{
                  destination_service_name="{{args.service-name}}"
                }[2m]
              )) by (le)
            )
```

#### 3.C.2 El Rollout con steps y análisis inline

```yaml
# rollout-checkout.yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: checkout
  namespace: shop
spec:
  replicas: 10
  revisionHistoryLimit: 3
  selector:
    matchLabels: {app: checkout}
  template:
    metadata:
      labels: {app: checkout}
    spec:
      containers:
        - name: checkout
          image: registry.example.com/checkout:1.8.0
          ports: [{containerPort: 8080}]
          readinessProbe:
            httpGet: {path: /healthz/ready, port: 8080}
            periodSeconds: 5
          resources:
            requests: {cpu: 250m, memory: 256Mi}
            limits: {cpu: "1", memory: 512Mi}
  strategy:
    canary:
      canaryService: checkout-canary     # Argo gestiona sus selectores
      stableService: checkout-stable
      trafficRouting:
        plugins:
          argoproj-labs/gatewayAPI:
            httpRoute: checkout
            namespace: shop
      # Análisis de fondo que corre en paralelo a TODOS los steps:
      analysis:
        templates:
          - templateName: success-rate
        startingStep: 1                  # empieza a vigilar desde el 2º step
        args:
          - name: service-name
            value: checkout-canary
      steps:
        - setWeight: 5
        - pause: {duration: 10m}         # observación con 5 % de tráfico
        - setWeight: 25
        - pause: {duration: 10m}
        - setWeight: 50
        - analysis:                      # análisis-gate explícito antes de 50->100
            templates:
              - templateName: success-rate
            args:
              - name: service-name
                value: checkout-canary
        - setWeight: 75
        - pause: {duration: 5m}
        # sin pause final -> promoción a 100 % automática si el análisis pasó
```

**Operación real con `kubectl argo rollouts`:**

```console
$ kubectl argo rollouts get rollout checkout -n shop --watch
Name:            checkout
Namespace:       shop
Status:          ॥ Paused
Message:         CanaryPauseStep
Strategy:        Canary
  Step:          1/8
  SetWeight:     5
  ActualWeight:  5
Images:          checkout:1.7.3 (stable)
                 checkout:1.8.0 (canary)
Replicas:
  Desired:       10
  Current:       11
  Updated:       1
  Ready:         11
  Available:     11

NAME                                  KIND        STATUS     AGE  INFO
⟳ checkout                            Rollout     ॥ Paused   6m
├──# revision:2
│  └──⧉ checkout-6c8f4d9b7           ReplicaSet  ✔ Healthy  6m   canary
│     └──□ checkout-6c8f4d9b7-2xk4p  Pod         ✔ Running  6m   ready:1/1
└──# revision:1
   └──⧉ checkout-7c9d5f7b8           ReplicaSet  ✔ Healthy  2d   stable
      ├──□ checkout-7c9d5f7b8-9mnq7  Pod         ✔ Running  2d   ready:1/1
      └──□ ... (9 pods stable)

# El AnalysisRun corriendo en paralelo:
$ kubectl argo rollouts get rollout checkout -n shop | grep -A3 Analysis
   └──α checkout-6c8f4d9b7-2   AnalysisRun  ◌ Running  4m   ✔ 3

# Promoción manual del step pausado (si el gate es manual):
$ kubectl argo rollouts promote checkout -n shop
rollout 'checkout' promoted

# --- CASO DE FALLO: el success-rate cae por debajo de 0.99 ---
$ kubectl argo rollouts get rollout checkout -n shop
Status:          ✖ Degraded
Message:         RolloutAborted: metric "success-rate" assessed Failed:
                 failed (2) > failureLimit (2)
  Step:          3/8
  SetWeight:     0          # <- Argo bajó el canary a 0 % automáticamente
  ActualWeight:  0

# Inspección del AnalysisRun que abortó:
$ kubectl get analysisrun -n shop
NAME                     STATUS   AGE
checkout-6c8f4d9b7-2     Failed   12m

$ kubectl describe analysisrun checkout-6c8f4d9b7-2 -n shop | sed -n '/Metric Results/,/Events/p'
Metric Results:
  Name:            success-rate
  Phase:           Failed
  Failed:          2
  Successful:      3
  Measurements:
    Value:  0.9997   Phase: Successful
    Value:  0.9981   Phase: Successful
    Value:  0.9723   Phase: Failed      # <- regresión detectada
    Value:  0.9605   Phase: Failed

# El rollback ya ocurrió solo. Para reintentar tras corregir la imagen:
$ kubectl argo rollouts abort checkout -n shop      # deja stable al 100%
$ kubectl argo rollouts set image checkout checkout=registry.example.com/checkout:1.8.1 -n shop
```

**Variante Blue/Green en Argo Rollouts** (para el mismo `Rollout`, cambiando la estrategia):

```yaml
  strategy:
    blueGreen:
      activeService: checkout            # Service que ve producción
      previewService: checkout-preview   # Service para validar green
      autoPromotionEnabled: false        # requiere promoción manual/gate
      prePromotionAnalysis:              # corre contra preview ANTES del switch
        templates: [{templateName: success-rate}]
        args: [{name: service-name, value: checkout-preview}]
      postPromotionAnalysis:             # corre contra active DESPUÉS del switch
        templates: [{templateName: success-rate}]
        args: [{name: service-name, value: checkout}]
      scaleDownDelaySeconds: 300         # mantené el viejo 5 min por si hay rollback
```

---

### 3.D — Flagger + Istio: canary dirigido por SLO, GitOps-nativo

Flagger toma el enfoque opuesto a Argo: en vez de reemplazar tu `Deployment`, lo **envuelve**. Vos seguís aplicando un `Deployment` normal; Flagger observa cambios en el `spec.template`, crea los `Service`/`VirtualService` canary, y ejecuta el análisis, incrementando el peso él mismo.

```yaml
# canary.yaml  (Deployment 'checkout' ya existe, sin cambios)
apiVersion: flagger.app/v1beta1
kind: Canary
metadata:
  name: checkout
  namespace: shop
spec:
  provider: istio
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: checkout
  progressDeadlineSeconds: 600      # aborta si no promueve en 10 min
  service:
    port: 80
    targetPort: 8080
    gateways: [public-gateway.istio-system.svc.cluster.local]
    hosts: [shop.example.com]
    retries: {attempts: 3, perTryTimeout: 2s, retryOn: "5xx"}
  analysis:
    interval: 1m                    # evalúa cada 1 min
    threshold: 5                    # 5 fallos consecutivos -> rollback
    maxWeight: 50                   # tope del canary antes de promover a 100
    stepWeight: 10                  # +10 % por iteración exitosa
    metrics:
      - name: request-success-rate
        thresholdRange: {min: 99}   # % de 2xx/3xx
        interval: 1m
      - name: request-duration
        thresholdRange: {max: 500}  # p99 en ms
        interval: 1m
      - name: error-rate-custom
        templateRef: {name: error-rate, namespace: shop}
        thresholdRange: {max: 1}
    webhooks:
      - name: load-test
        type: rollout               # genera carga sintética durante el canary
        url: http://flagger-loadtester.shop/
        metadata:
          cmd: "hey -z 1m -q 10 -c 2 http://checkout-canary.shop:80/checkout"
      - name: acceptance-test
        type: pre-rollout           # gate: debe pasar antes de enrutar tráfico
        url: http://flagger-loadtester.shop/
        timeout: 30s
        metadata:
          type: bash
          cmd: "curl -sf http://checkout-canary.shop/healthz/ready"
```

**El ciclo completo, observado en logs:**

```console
# Disparás el canary simplemente cambiando la imagen del Deployment envuelto:
$ kubectl set image deployment/checkout checkout=registry.example.com/checkout:1.8.0 -n shop
deployment.apps/checkout image updated

$ kubectl get canary checkout -n shop --watch
NAME       STATUS        WEIGHT   LASTTRANSITIONTIME
checkout   Progressing   0        2026-08-07T14:02:11Z
checkout   Progressing   10       2026-08-07T14:03:11Z
checkout   Progressing   20       2026-08-07T14:04:11Z
checkout   Progressing   30       2026-08-07T14:05:11Z
checkout   Progressing   40       2026-08-07T14:06:11Z
checkout   Progressing   50       2026-08-07T14:07:11Z
checkout   Promoting     0        2026-08-07T14:08:11Z
checkout   Finalising    0        2026-08-07T14:09:11Z
checkout   Succeeded     0        2026-08-07T14:10:11Z

# Traza de decisiones en el controller:
$ kubectl -n istio-system logs deploy/flagger -f | grep checkout
New revision detected! Scaling up checkout.shop
Starting canary analysis for checkout.shop
Pre-rollout check acceptance-test passed
Advance checkout.shop canary weight 10
Advance checkout.shop canary weight 20
Advance checkout.shop canary weight 30
Advance checkout.shop canary weight 40
Advance checkout.shop canary weight 50
Copying checkout.shop template spec to checkout-primary.shop
Routing all traffic to primary
Promotion completed! Scaling down checkout.shop

# --- CASO DE FALLO ---
$ kubectl get canary checkout -n shop
NAME       STATUS   WEIGHT   LASTTRANSITIONTIME
checkout   Failed   0        2026-08-07T14:22:41Z

$ kubectl -n istio-system logs deploy/flagger | grep checkout | tail -4
Advance checkout.shop canary weight 20
Halt checkout.shop advancement success rate 96.42% < 99%
Halt checkout.shop advancement success rate 95.88% < 99%
Rolling back checkout.shop failed checks threshold reached 5
Canary failed! Scaling down checkout.shop
```

---

## 4. Comparativa de herramientas de progressive delivery

| Criterio | **Argo Rollouts** | **Flagger** |
|---|---|---|
| Modelo | Reemplaza `Deployment` por CRD `Rollout` | Envuelve un `Deployment` existente |
| Control de steps | Imperativo y granular (`steps: [setWeight, pause, analysis]`) | Declarativo por `stepWeight`/`maxWeight` |
| Promoción manual | Sí (`promote`, pausas indefinidas) | Menos idiomático (pensado para automático) |
| Data planes | Istio, Linkerd, SMI, Gateway API, NGINX, ALB, Traefik, Apisix… | Istio, Linkerd, App Mesh, Gateway API, NGINX, Contour, Gloo… |
| Análisis | `AnalysisTemplate` (Prometheus, Datadog, NewRelic, CloudWatch, Web, Job, Kayenta) | `MetricTemplate` + built-ins; webhooks de carga/gates |
| UX | Dashboard + plugin `kubectl argo rollouts` | CLI mínima; observás vía `kubectl get canary` |
| Experimentos A/B | `Experiment`/`AnalysisRun` de primera clase | Header/cookie routing para A/B; sin CRD de experimento |
| Encaje mental | "quiero pilotar el rollout paso a paso" | "quiero que el mesh automatice el canary por SLO" |

**Elección de arquitecto:** Argo Rollouts si querés *control explícito*, pausas para aprobación humana y experimentos A/B como ciudadanos de primera clase; Flagger si ya tenés un mesh y querés *automatización total dirigida por SLO* con mínima superficie de config sobre tus `Deployment` existentes. Ambos son proyectos CNCF (Argo es Graduated; Flagger vive bajo Flux, Graduated).

---

## 5. Guía de verificación y diagnóstico de fallas

### 5.1 Checklist de verificación (qué mirar y con qué)

| Pregunta | Comando |
|---|---|
| ¿El Service de producción resuelve los endpoints correctos? | `kubectl get endpointslices -l kubernetes.io/service-name=<svc> -o wide` |
| ¿El split de tráfico real coincide con el peso declarado? | `for i in $(seq 1 200); do curl -s $URL/version; done \| sort \| uniq -c` |
| ¿El `HTTPRoute`/`VirtualService` fue aceptado? | `kubectl get httproute <r> -o jsonpath='{.status.parents[0].conditions}'` |
| ¿El AnalysisRun está midiendo lo esperado? | `kubectl describe analysisrun <ar>` |
| ¿El mesh está inyectando el sidecar en ambos subsets? | `kubectl get pod <p> -o jsonpath='{.spec.containers[*].name}'` (debe incluir `istio-proxy`) |
| ¿Prometheus tiene la serie que el análisis consulta? | `curl -s 'http://prom:9090/api/v1/query?query=istio_requests_total' \| jq '.data.result \| length'` |
| ¿Cuál fue la última transición de estado del canary? | `kubectl get canary <c> -o jsonpath='{.status.phase} {.status.lastTransitionTime}'` |

### 5.2 Fallas típicas → causa raíz → remediación

**1) El canary se queda en 5 % y nunca avanza (Argo `Progressing` eterno)**
```console
$ kubectl argo rollouts get rollout checkout -n shop | grep Message
Message:  waiting for analysis to complete
$ kubectl describe analysisrun checkout-6c8f4d9b7-2 -n shop | grep -A2 "Measurements"
    Value: NaN   Phase: Error   Message: no values found
```
→ **Causa:** la query de Prometheus devuelve vacío (label `destination_service_name` mal, o el mesh aún no emitió métricas porque no hay tráfico). `successCondition` sobre `NaN` nunca se cumple. → **Fix:** validá la query en Prometheus a mano; agregá un `load-test` webhook para generar tráfico; confirmá los labels reales con `istio_requests_total{destination_service_name=~"checkout.*"}`.

**2) El split no respeta el peso (pediste 5 %, ves ~50 %)**
```console
$ kubectl get pods -n shop --show-labels | grep canary
checkout-canary-...  1/1  Running  ...  app=checkout,version=canary
$ kubectl get svc checkout-stable -n shop -o jsonpath='{.spec.selector}'
{"app":"checkout"}      # <- BUG: selector sin 'version', captura también canary
```
→ **Causa:** el `stableService` selecciona ambos subsets, así que el weighted routing de L7 se rompe: kube-proxy ya reparte 50/50 por debajo. → **Fix:** los Service stable/canary deben tener selectores **disjuntos** (`version: stable` vs `version: canary`); el controller de rollouts los gestiona si lo dejás.

**3) Blue/Green: tras el switch, parte del tráfico sigue en blue**
→ **Causa:** conexiones keep-alive/HTTP2 pre-existentes contra pods blue (§3.A). → **Fix:** con mesh, usá `DestinationRule` con outlier detection + connection pool para forzar reciclado; sin mesh, escalá blue a 0 réplicas tras el `scaleDownDelay` para que kube-proxy expulse los endpoints y los clientes reconecten.

**4) Rollback automático no dispara pese al error-rate alto**
```console
$ kubectl describe analysistemplate success-rate -n shop | grep failureLimit
  failureLimit: 5
```
→ **Causa:** `failureLimit` demasiado alto o `interval` demasiado largo → el análisis tolera la regresión más tiempo del aceptable. → **Fix:** ajustá `failureLimit`/`count`/`interval` al presupuesto de error del SLO. Regla: el *tiempo hasta rollback* ≈ `failureLimit × interval`; con SLO estricto, `interval: 30s, failureLimit: 2`.

**5) `progressDeadlineSeconds` expira y aborta un canary sano (Flagger)**
→ **Causa:** `stepWeight` chico + `interval` largo hacen que `maxWeight` no se alcance dentro del deadline (`(maxWeight/stepWeight) × interval > progressDeadlineSeconds`). → **Fix:** subí `progressDeadlineSeconds` o el `stepWeight`, o bajá `maxWeight`.

**6) Sidecar ausente → el mesh no ve el tráfico del canary**
```console
$ kubectl get pod checkout-canary-xxxx -n shop -o jsonpath='{.spec.containers[*].name}'
checkout                     # <- falta 'istio-proxy'
$ kubectl get ns shop --show-labels | grep istio-injection
shop   Active   90d   kubernetes.io/metadata.name=shop      # <- sin istio-injection=enabled
```
→ **Fix:** `kubectl label ns shop istio-injection=enabled` y recreá los pods; sin sidecar no hay `istio_requests_total` y el análisis queda ciego.

### 5.3 Consideración transversal: schema/DB y contratos hacia atrás

Toda estrategia progresiva asume que **v1 y v2 coexisten sirviendo tráfico simultáneamente**. Eso impone dos disciplinas no negociables:
- **Backward/forward-compatible schema changes** (expand/contract): agregá columnas nullable, nunca renombres/borres en el mismo release que el código que las usa. La migración destructiva va en un release posterior, cuando ya no queda v1.
- **Contratos de API aditivos**: v2 no puede exigir un campo que v1 no envía, porque durante el canary un request puede pegarle a v1 en el frontend y a v2 en el backend.

Blue/Green *no* te salva de esto salvo que tengas bases de datos separadas por color (raro y caro); en el instante del switch, v2 hereda el estado que v1 dejó.

---

## 6. Referencias

- CNCF Curriculum — CNPE: https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- Kubernetes — Deployments (RollingUpdate/Recreate): https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- Kubernetes — Canary deployments (patrón nativo): https://kubernetes.io/docs/concepts/cluster-administration/manage-deployment/#canary-deployments
- Kubernetes — Service / EndpointSlices: https://kubernetes.io/docs/concepts/services-networking/service/
- Gateway API — HTTPRoute traffic splitting (weight): https://gateway-api.sigs.k8s.io/guides/traffic-splitting/
- Gateway API — spec `HTTPBackendRef.weight`: https://gateway-api.sigs.k8s.io/api-types/httproute/
- Argo Rollouts — Canary strategy: https://argo-rollouts.readthedocs.io/en/stable/features/canary/
- Argo Rollouts — BlueGreen strategy: https://argo-rollouts.readthedocs.io/en/stable/features/bluegreen/
- Argo Rollouts — Analysis & Progressive Delivery: https://argo-rollouts.readthedocs.io/en/stable/features/analysis/
- Argo Rollouts — Gateway API plugin: https://argoproj.github.io/argo-rollouts/features/traffic-management/plugins/
- Flagger — How it works / Canary CRD: https://docs.flagger.app/usage/how-it-works
- Flagger — Istio canary tutorial: https://docs.flagger.app/tutorials/istio-progressive-delivery
- Flagger — Metrics analysis (MetricTemplate): https://docs.flagger.app/usage/metrics
- Istio — VirtualService / traffic shifting: https://istio.io/latest/docs/tasks/traffic-management/traffic-shifting/
- Istio — DestinationRule (connection pool / outlier detection): https://istio.io/latest/docs/reference/config/networking/destination-rule/
- Linkerd — Progressive delivery con Flagger: https://linkerd.io/2/tasks/canary-release/
- Prometheus — `histogram_quantile` (latencia p99): https://prometheus.io/docs/prometheus/latest/querying/functions/#histogram_quantile
- CNCF Blog — Progressive delivery primer: https://www.cncf.io/blog/2021/07/22/progressive-delivery-with-service-mesh-and-gitops/