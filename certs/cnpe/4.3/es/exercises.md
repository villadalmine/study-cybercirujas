# Ejercicios Guiados — Tema 4.3: Deploying Applications Using Progressive Delivery Strategies (Blue/Green y Canary)

> **Objetivo del laboratorio.** Vas a construir, de forma incremental, un pipeline de *progressive delivery* sobre Kubernetes usando **Argo Rollouts** como controlador principal, y compararlo con **Flagger** y con los patrones nativos. Al terminar vas a poder razonar sobre los trade-offs de Blue/Green vs Canary, implementar promoción manual y automática basada en métricas, y diagnosticar un `abort` con rollback.
>
> **Prerrequisitos.** Un cluster (kind, minikube o k3s con ≥ 4 GB), `kubectl` ≥ 1.27, `helm` ≥ 3.12 y acceso a internet para descargar imágenes públicas. Todas las imágenes usadas (`argoproj/rollouts-demo`) son públicas.
>
> **Convención.** Los prompts marcados con `$` se ejecutan en tu shell. Las salidas mostradas son *representativas*: los hashes de ReplicaSet y las IPs variarán en tu entorno.

---

## Ejercicio 0 — Preparación del entorno

**Paso 1.** Creá un namespace dedicado y verificá el contexto activo para no operar sobre el cluster equivocado:

```bash
$ kubectl config current-context
kind-progressive
$ kubectl create namespace pd-lab
namespace/pd-lab created
$ kubectl config set-context --current --namespace=pd-lab
Context "kind-progressive" modified.
```

**Paso 2.** Instalá el controlador de Argo Rollouts (vive en su propio namespace, es *cluster-scoped* por sus CRDs):

```bash
$ kubectl create namespace argo-rollouts
namespace/argo-rollouts created
$ kubectl apply -n argo-rollouts \
    -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
customresourcedefinition.apiextensions.k8s.io/rollouts.argoproj.io created
customresourcedefinition.apiextensions.k8s.io/analysistemplates.argoproj.io created
customresourcedefinition.apiextensions.k8s.io/analysisruns.argoproj.io created
customresourcedefinition.apiextensions.k8s.io/experiments.argoproj.io created
...
deployment.apps/argo-rollouts created
```

**Paso 3.** Instalá el plugin de `kubectl` para inspeccionar Rollouts (Krew o binario directo):

```bash
$ curl -sSL -o kubectl-argo-rollouts \
    https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
$ chmod +x kubectl-argo-rollouts && sudo mv kubectl-argo-rollouts /usr/local/bin/
$ kubectl argo rollouts version
kubectl-argo-rollouts: v1.7.2+...
```

**Paso 4.** Confirmá que el controlador está `Ready` antes de continuar:

```bash
$ kubectl -n argo-rollouts rollout status deployment/argo-rollouts
deployment "argo-rollouts" successfully rolled out
```

> **Preguntas de comprensión (0)**
> 1. ¿Por qué `Rollout` es un CRD y no un simple `Deployment` con más campos? ¿Qué gana el controlador al reemplazar al Deployment controller nativo?
> 2. El plugin `kubectl argo rollouts` es un *cliente*. ¿Qué componente hace realmente el trabajo de crear/escalar ReplicaSets y modificar Services? ¿Qué pasa si el pod del controlador cae en medio de una promoción?
> 3. ¿Por qué instalamos el controlador en `argo-rollouts` pero las aplicaciones van en `pd-lab`? ¿Es el controlador namespaced o cluster-scoped?

---

## Ejercicio 1 — Blue/Green con Argo Rollouts

En Blue/Green mantenemos **dos ReplicaSets a plena capacidad simultáneamente**: el *active* (versión estable, recibe tráfico) y el *preview* (versión nueva, recibe validación). La promoción es un *cutover* atómico del selector del Service.

**Paso 1.** Creá los dos Services que el Rollout va a manipular. El controlador reescribe sus `selector` inyectando el hash del ReplicaSet:

```yaml
# bluegreen-services.yaml
apiVersion: v1
kind: Service
metadata:
  name: rollout-bluegreen-active
spec:
  selector:
    app: rollout-bluegreen
  ports:
    - protocol: TCP
      port: 80
      targetPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: rollout-bluegreen-preview
spec:
  selector:
    app: rollout-bluegreen
  ports:
    - protocol: TCP
      port: 80
      targetPort: 8080
```

```bash
$ kubectl apply -f bluegreen-services.yaml
service/rollout-bluegreen-active created
service/rollout-bluegreen-preview created
```

**Paso 2.** Definí el Rollout con estrategia `blueGreen`. Fijate en `autoPromotionEnabled: false`: la promoción será **manual**.

```yaml
# rollout-bluegreen.yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: rollout-bluegreen
spec:
  replicas: 3
  revisionHistoryLimit: 2
  selector:
    matchLabels:
      app: rollout-bluegreen
  template:
    metadata:
      labels:
        app: rollout-bluegreen
    spec:
      containers:
        - name: rollouts-demo
          image: argoproj/rollouts-demo:blue
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
  strategy:
    blueGreen:
      activeService: rollout-bluegreen-active
      previewService: rollout-bluegreen-preview
      autoPromotionEnabled: false
      scaleDownDelaySeconds: 30
```

```bash
$ kubectl apply -f rollout-bluegreen.yaml
rollout.argoproj.io/rollout-bluegreen created
```

**Paso 3.** Observá el estado inicial. En el primer despliegue no hay "versión anterior", así que ambos Services apuntan al mismo ReplicaSet:

```bash
$ kubectl argo rollouts get rollout rollout-bluegreen
Name:            rollout-bluegreen
Namespace:       pd-lab
Status:          ✔ Healthy
Strategy:        BlueGreen
Images:          argoproj/rollouts-demo:blue (stable, active)
Replicas:
  Desired:       3
  Current:       3
  Updated:       3
  Ready:         3
  Available:     3

NAME                                           KIND        STATUS     AGE  INFO
⟳ rollout-bluegreen                            Rollout     ✔ Healthy  40s
└──# revision:1
   └──⧉ rollout-bluegreen-6cf78ff755           ReplicaSet  ✔ Healthy  40s  stable,active
```

**Paso 4.** Dispará una nueva versión cambiando solo la imagen (a `:yellow`). Esto crea el ReplicaSet *preview* pero **no** mueve el tráfico active:

```bash
$ kubectl argo rollouts set image rollout-bluegreen \
    rollouts-demo=argoproj/rollouts-demo:yellow
rollout "rollout-bluegreen" image updated
$ kubectl argo rollouts get rollout rollout-bluegreen
Status:          ॥ Paused
Message:         BlueGreenPause
...
   ├──# revision:2
   │  └──⧉ rollout-bluegreen-7d9fc8b6c9        ReplicaSet  ✔ Healthy  15s  preview
   └──# revision:1
      └──⧉ rollout-bluegreen-6cf78ff755        ReplicaSet  ✔ Healthy  4m   stable,active
```

**Paso 5.** Verificá el corte de tráfico a nivel Service. El active sigue en `blue`, el preview ya sirve `yellow`:

```bash
$ kubectl get endpoints rollout-bluegreen-active rollout-bluegreen-preview
NAME                        ENDPOINTS                                   AGE
rollout-bluegreen-active    10.244.0.11:8080,10.244.0.12:8080,...       4m
rollout-bluegreen-preview   10.244.0.21:8080,10.244.0.22:8080,...       20s
# Los sets de IPs son disjuntos: preview y active apuntan a ReplicaSets distintos.
```

**Paso 6.** Promocioná manualmente. El active hace *cutover* al nuevo ReplicaSet de forma instantánea:

```bash
$ kubectl argo rollouts promote rollout-bluegreen
rollout "rollout-bluegreen" promoted
$ kubectl argo rollouts get rollout rollout-bluegreen
Status:          ✔ Healthy
Images:          argoproj/rollouts-demo:yellow (stable, active)
```

Después de `scaleDownDelaySeconds: 30` el ReplicaSet `blue` (revision 1) se escala a 0, pero permanece registrado para rollback rápido.

> **Preguntas de comprensión (1)**
> 1. Durante el `Paused` (Paso 4), ¿cuánta capacidad de cómputo está consumiendo el Rollout respecto de un Deployment estándar? ¿Cuál es el costo económico implícito de Blue/Green y por qué lo pagás incluso si no promocionás?
> 2. El `previewService` te deja validar la versión nueva **sin** exponerla a usuarios reales. ¿Qué tipo de pruebas tiene sentido correr contra el preview antes de promocionar, y cuáles *no* se pueden validar así?
> 3. Explicá qué hace exactamente `scaleDownDelaySeconds`. Si lo ponés en `0`, ¿qué garantía de rollback perdés? Si detectás un bug 5 minutos después de promocionar y `scaleDownDelaySeconds` era 30, ¿el rollback sigue siendo instantáneo?
> 4. El *cutover* de Blue/Green cambia el selector del Service. ¿Este cambio es atómico para todas las conexiones? ¿Qué pasa con las conexiones TCP ya establecidas contra pods `blue` en el instante del corte?

---

## Ejercicio 2 — Canary básico con Argo Rollouts (sin traffic mesh)

En Canary desplegamos la versión nueva a una **fracción** de las réplicas y aumentamos el peso por etapas. Sin un traffic router, Argo Rollouts aproxima el peso ajustando el **número de réplicas** del canary y el stable (traffic splitting por conteo de pods vía `kube-proxy`).

**Paso 1.** Un único Service (el tráfico se reparte por endpoints, no por routing L7):

```yaml
# rollout-canary.yaml
apiVersion: v1
kind: Service
metadata:
  name: rollout-canary
spec:
  selector:
    app: rollout-canary
  ports:
    - port: 80
      targetPort: 8080
---
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: rollout-canary
spec:
  replicas: 5
  revisionHistoryLimit: 2
  selector:
    matchLabels:
      app: rollout-canary
  template:
    metadata:
      labels:
        app: rollout-canary
    spec:
      containers:
        - name: rollouts-demo
          image: argoproj/rollouts-demo:blue
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
  strategy:
    canary:
      steps:
        - setWeight: 20
        - pause: {}                 # pausa indefinida → promoción manual
        - setWeight: 40
        - pause: { duration: 30s }  # pausa temporizada
        - setWeight: 60
        - pause: { duration: 30s }
        - setWeight: 80
        - pause: { duration: 30s }
```

```bash
$ kubectl apply -f rollout-canary.yaml
service/rollout-canary created
rollout.argoproj.io/rollout-canary created
```

**Paso 2.** Dispará la actualización a `:yellow` y observá el primer step (`setWeight: 20`). Con 5 réplicas, 20% ≈ **1 pod canary + 4 stable**:

```bash
$ kubectl argo rollouts set image rollout-canary rollouts-demo=argoproj/rollouts-demo:yellow
rollout "rollout-canary" image updated
$ kubectl argo rollouts get rollout rollout-canary --watch
Name:            rollout-canary
Status:          ॥ Paused
Message:         CanaryPauseStep
Strategy:        Canary
  Step:          1/8
  SetWeight:     20
  ActualWeight:  20
Replicas:
  Desired:       5
  Updated:       1
  Ready:         5
  Available:     5

NAME                                        KIND        STATUS     AGE  INFO
⟳ rollout-canary                            Rollout     ॥ Paused   2m
├──# revision:2
│  └──⧉ rollout-canary-8657... (canary)     ReplicaSet  ✔ Healthy  30s  canary
└──# revision:1
   └──⧉ rollout-canary-5f9d... (stable)     ReplicaSet  ✔ Healthy  2m   stable
```

**Paso 3.** El Rollout está en pausa indefinida (step 2). Promocioná para avanzar; a partir de ahí las pausas temporizadas de 30s se resuelven solas hasta el 100%:

```bash
$ kubectl argo rollouts promote rollout-canary
rollout "rollout-canary" promoted
# El controlador recorre 40→60→80→100 esperando 30s en cada pausa.
$ kubectl argo rollouts status rollout-canary
Healthy
```

**Paso 4.** Comprobá empíricamente el *skew* del split contando pods por revisión durante el step del 40%:

```bash
$ kubectl get pods -l app=rollout-canary \
    -o custom-columns='POD:.metadata.name,IMG:.spec.containers[0].image'
POD                         IMG
rollout-canary-5f9d-...     argoproj/rollouts-demo:blue     # stable
rollout-canary-5f9d-...     argoproj/rollouts-demo:blue
rollout-canary-5f9d-...     argoproj/rollouts-demo:blue
rollout-canary-8657-...     argoproj/rollouts-demo:yellow   # canary
rollout-canary-8657-...     argoproj/rollouts-demo:yellow
```

> **Preguntas de comprensión (2)**
> 1. Pediste `setWeight: 20` con `replicas: 5`. ¿Qué pasa con la precisión del peso si tuvieras `replicas: 3` y pidieras `setWeight: 10`? ¿Cuál es el mínimo de réplicas canary que puede crear el controlador y cómo se relaciona con `setCanaryScale`?
> 2. Sin un traffic router (SMI, Istio, Gateway API), el reparto lo hace `kube-proxy` balanceando entre endpoints. ¿Por qué este método **no** garantiza que exactamente el 20% de las *requests* vaya al canary? Nombrá dos factores que rompen la proporción (pista: keep-alive, distribución de sesiones).
> 3. Diferencia entre `pause: {}` y `pause: { duration: 30s }`. ¿Cuál requiere intervención humana o un `promote`? ¿Cómo reanudás una pausa indefinida por CLI?
> 4. Compará el consumo de recursos de este Canary (max 6 pods transitorios) contra el Blue/Green del Ejercicio 1 (6 pods sostenidos). ¿Por qué se dice que Canary es más "barato" en capacidad pero más "lento" en tiempo de despliegue?

---

## Ejercicio 3 — Canary con análisis automático basado en métricas

El valor real de progressive delivery aparece cuando la promoción es **automática y condicionada a SLOs**. Vamos a atar cada step a un `AnalysisTemplate` que consulta Prometheus; si la tasa de éxito cae por debajo del umbral, el Rollout hace `abort`.

**Paso 1.** Definí el `AnalysisTemplate`. Recibe el nombre del servicio como argumento y evalúa la *success rate* de las últimas requests:

```yaml
# analysis-success-rate.yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: success-rate
spec:
  args:
    - name: service-name
  metrics:
    - name: success-rate
      interval: 30s
      count: 3               # 3 mediciones antes de veredicto final
      successCondition: result[0] >= 0.95
      failureLimit: 1        # 1 medición fallida aborta
      provider:
        prometheus:
          address: http://prometheus.monitoring.svc.cluster.local:9090
          query: |
            sum(rate(http_requests_total{
              service="{{args.service-name}}", code=~"2.."}[1m]))
            /
            sum(rate(http_requests_total{
              service="{{args.service-name}}"}[1m]))
```

```bash
$ kubectl apply -f analysis-success-rate.yaml
analysistemplate.argoproj.io/success-rate created
```

**Paso 2.** Referenciá el análisis desde la estrategia canary. Con `analysis` en un step, el análisis corre **en background** durante ese tramo; el Rollout no avanza si el `AnalysisRun` falla:

```yaml
# rollout-canary-analysis.yaml (fragmento de strategy)
  strategy:
    canary:
      steps:
        - setWeight: 20
        - pause: { duration: 60s }
        - analysis:
            templates:
              - templateName: success-rate
            args:
              - name: service-name
                value: rollout-canary-analysis
        - setWeight: 50
        - pause: { duration: 60s }
        - setWeight: 100
```

**Paso 3.** También podés correr un análisis **de fondo durante todo** el rollout (no ligado a un step) con `analysis.templates` a nivel de `canary` mediante `analysisRunMetadata`/`background`. Para el ejercicio, aplicalo y dispará la nueva versión:

```bash
$ kubectl apply -f rollout-canary-analysis.yaml
rollout.argoproj.io/rollout-canary-analysis configured
$ kubectl argo rollouts set image rollout-canary-analysis \
    rollouts-demo=argoproj/rollouts-demo:yellow
rollout "rollout-canary-analysis" image updated
```

**Paso 4.** Inspeccioná el `AnalysisRun` creado cuando el Rollout llega al step de análisis:

```bash
$ kubectl argo rollouts get rollout rollout-canary-analysis
...
  Step:          3/6
  ...
NAME                                                  KIND         STATUS        AGE
⟳ rollout-canary-analysis                             Rollout      ॥ Paused      3m
├──# revision:2
│  ├──⧉ rollout-canary-analysis-6b7c... (canary)      ReplicaSet   ✔ Healthy     3m
│  └──α rollout-canary-analysis-6b7c-2-1              AnalysisRun  ⚠ Running     40s   ✔ 1,✖ 0
$ kubectl get analysisrun -o wide
NAME                               STATUS       AGE
rollout-canary-analysis-6b7c-2-1   Running      45s
```

**Paso 5.** Si las 3 mediciones cumplen `successCondition`, el `AnalysisRun` pasa a `Successful` y el Rollout avanza al `setWeight: 50` **sin intervención humana**:

```bash
$ kubectl get analysisrun rollout-canary-analysis-6b7c-2-1 -o jsonpath='{.status.phase}'
Successful
```

> **Preguntas de comprensión (3)**
> 1. `successCondition: result[0] >= 0.95` con `failureLimit: 1` y `count: 3`. Describí la máquina de estados: ¿cuántas mediciones fallidas hacen falta para abortar? ¿Y para declarar `Successful`?
> 2. Diferencia entre un análisis **inline en un step** y un análisis **background** (que arranca en un `setWeight` y corre en paralelo a los steps siguientes). ¿Cuál detecta antes una regresión que solo aparece con más tráfico?
> 3. La query de Prometheus mide *success rate* agregado del **service**, que incluye stable + canary. ¿Por qué eso puede *enmascarar* un canary defectuoso cuando el canary solo tiene 20% del tráfico? ¿Cómo reescribirías la query para aislar los pods canary (pista: label injectado por el controlador)?
> 4. ¿Qué pasa si Prometheus está caído cuando corre el `AnalysisRun`? ¿El Rollout lo interpreta como éxito, fallo, o inconclusivo? ¿Qué campo controla ese comportamiento?

---

## Ejercicio 4 — Traffic management L7 real (Gateway API / SMI)

El split por conteo de pods del Ejercicio 2 es impreciso. Con un **traffic router** (Istio, SMI, Nginx, o **Gateway API**) el peso se aplica a nivel de request, desacoplado de la cantidad de réplicas. Esto habilita `setCanaryScale` (pocas réplicas canary sirviendo mucho tráfico) y viceversa.

**Paso 1.** Con un provider de tráfico, la estrategia declara el `trafficRouting`. Ejemplo con Gateway API (plugin) referenciando un `HTTPRoute`:

```yaml
# fragmento strategy con trafficRouting
  strategy:
    canary:
      canaryService: rollout-canary-preview   # Service que apunta solo al canary
      stableService: rollout-canary-stable     # Service que apunta solo al stable
      trafficRouting:
        plugins:
          argoproj-labs/gatewayAPI:
            httpRoute: rollout-http-route       # HTTPRoute que el controlador reescribe
            namespace: pd-lab
      steps:
        - setWeight: 10
        - pause: { duration: 60s }
        - setWeight: 30
        - setCanaryScale:
            weight: 30            # réplicas canary dimensionadas al 30% del tráfico
        - pause: { duration: 60s }
        - setWeight: 60
        - pause: { duration: 60s }
```

**Paso 2.** El `HTTPRoute` de Gateway API declara ambos backends; el controlador ajusta los `weight` de los `backendRefs` en cada step:

```yaml
# httproute.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: rollout-http-route
spec:
  parentRefs:
    - name: demo-gateway
  rules:
    - backendRefs:
        - name: rollout-canary-stable
          port: 80
          weight: 100
        - name: rollout-canary-preview
          port: 80
          weight: 0
```

**Paso 3.** Durante el step `setWeight: 30`, verificá que el controlador reescribió los pesos del `HTTPRoute` (no la cantidad de pods):

```bash
$ kubectl get httproute rollout-http-route \
    -o jsonpath='{.spec.rules[0].backendRefs[*].weight}'
70 30
# stable=70, preview=30 — el split ahora es de request-level, exacto.
```

**Paso 4.** Con `setCanaryScale`, comprobá el desacople entre peso de tráfico y número de réplicas:

```bash
$ kubectl argo rollouts get rollout rollout-canary-tr | grep -A4 Replicas
Replicas:
  Desired:   10
  Updated:   3      # solo 3 pods canary...
  Ready:     10
# ...pero el HTTPRoute les enruta el 30% del tráfico. Menos capacidad, misma exposición.
```

> **Preguntas de comprensión (4)**
> 1. Con traffic router L7, ¿por qué `setWeight: 10` sí garantiza (aprox.) el 10% de las *requests* al canary, cosa que el Ejercicio 2 no lograba? ¿Dónde ocurre físicamente la decisión de routing?
> 2. `setCanaryScale` con `weight: 30` y solo 3 de 10 réplicas: ¿qué riesgo introducís al enrutar 30% del tráfico a 30% de la capacidad *nominal*? ¿Cuándo conviene `matchTrafficWeight: true`?
> 3. En este esquema necesitás **dos** Services (`stableService` y `canaryService`), a diferencia del Ejercicio 2 que usaba uno. ¿Por qué el traffic router necesita dos backends distinguibles?
> 4. Gateway API, SMI e Istio son intercambiables como `trafficRouting`. Desde la óptica de un platform engineer, ¿qué ventaja de portabilidad da que la *estrategia* (steps, weights) viva en el Rollout y el *mecanismo* (mesh/ingress) sea un plugin?

---

## Ejercicio 5 — Abort automático y rollback

Ahora provocamos una regresión para observar el `abort` y el rollback. La versión `:bad` de la demo devuelve errores 500 en un porcentaje de requests.

**Paso 1.** Con el Rollout del Ejercicio 3 en `Healthy`, desplegá la versión defectuosa:

```bash
$ kubectl argo rollouts set image rollout-canary-analysis \
    rollouts-demo=argoproj/rollouts-demo:bad
rollout "rollout-canary-analysis" image updated
```

**Paso 2.** Observá cómo el `AnalysisRun` supera el `failureLimit` y el Rollout entra en `Degraded`/`abort`:

```bash
$ kubectl argo rollouts get rollout rollout-canary-analysis --watch
Status:          ✖ Degraded
Message:         RolloutAborted: Rollout aborted update to revision 3: metric "success-rate" assessed Failed
...
│  └──α rollout-canary-analysis-....-3-1   AnalysisRun  ✖ Failed  50s  ✔ 0,✖ 2
```

**Paso 3.** Un `abort` **no** promueve; el stable sigue sirviendo. El canary defectuoso se escala a 0 automáticamente:

```bash
$ kubectl argo rollouts status rollout-canary-analysis
Degraded
$ kubectl get endpoints rollout-canary-analysis
# Todos los endpoints vuelven a apuntar al ReplicaSet stable (:yellow), 0 canary :bad.
```

**Paso 4.** Un `abort` deja el Rollout `Degraded` esperando acción. Podés reintentar la MISMA revisión con `retry`, o volver a una versión buena conocida con `undo`:

```bash
$ kubectl argo rollouts undo rollout-canary-analysis --to-revision=2
rollout "rollout-canary-analysis" rolled back
$ kubectl argo rollouts status rollout-canary-analysis
Healthy
```

**Paso 5 (rollback manual, sin análisis).** Aun sin métricas podés abortar a mano en cualquier pausa:

```bash
$ kubectl argo rollouts abort rollout-canary   # descarta el canary, mantiene stable
$ kubectl argo rollouts promote rollout-canary  # o, alternativamente, forzar la promoción
```

> **Preguntas de comprensión (5)**
> 1. Tras el `abort` del Paso 2, el Rollout queda `Degraded` pero el servicio **sigue disponible**. Explicá por qué el `abort` es *fail-safe*: ¿qué versión sirve tráfico mientras un operador decide?
> 2. Diferencia entre `abort`, `retry` y `undo`. Si el fallo fue por un Prometheus intermitente (falso positivo), ¿cuál usás? Si el fallo fue un bug real en la imagen, ¿cuál?
> 3. `--to-revision=2` en el `undo` reutilizó un ReplicaSet ya existente. ¿Por qué el rollback es casi instantáneo aquí y qué papel juega `revisionHistoryLimit`? ¿Qué pasaría si pidieras revertir a una revisión ya podada?
> 4. Un `abort` automático protege de regresiones *detectables por métricas*. Nombrá una clase de regresión (correctitud de datos, seguridad) que **pasaría** el análisis de success-rate y llegaría a producción igual. ¿Qué defensa complementaria agregarías?

---

## Ejercicio 6 — Alternativa: Flagger + service mesh (comparación)

Flagger es el otro operador dominante de progressive delivery. A diferencia de Argo Rollouts (que reemplaza al Deployment con un CRD `Rollout`), **Flagger orquesta tu Deployment existente** vía un CRD `Canary` y gestiona los objetos derivados.

**Paso 1.** Instalá Flagger sobre un mesh (ejemplo con Linkerd/Istio ya presente):

```bash
$ helm repo add flagger https://flagger.app
$ helm upgrade -i flagger flagger/flagger \
    --namespace flagger-system --create-namespace \
    --set meshProvider=istio \
    --set metricsServer=http://prometheus.monitoring:9090
Release "flagger" has been upgraded.
```

**Paso 2.** El recurso `Canary` referencia tu `Deployment` existente y declara el análisis. Flagger crea los `-primary`/`-canary` Deployments y Services derivados:

```yaml
# flagger-canary.yaml
apiVersion: flagger.app/v1beta1
kind: Canary
metadata:
  name: podinfo
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: podinfo
  service:
    port: 9898
  analysis:
    interval: 30s
    threshold: 5              # nº de checks fallidos antes de rollback
    maxWeight: 50
    stepWeight: 10
    metrics:
      - name: request-success-rate
        thresholdRange:
          min: 99
        interval: 1m
      - name: request-duration
        thresholdRange:
          max: 500
        interval: 1m
    webhooks:
      - name: load-test
        url: http://flagger-loadtester.test/
        metadata:
          cmd: "hey -z 1m -q 10 -c 2 http://podinfo-canary.test:9898/"
```

```bash
$ kubectl apply -f flagger-canary.yaml
canary.flagger.app/podinfo created
```

**Paso 3.** Disparás el análisis modificando el Deployment original; Flagger detecta el cambio de spec y arranca el canary:

```bash
$ kubectl set image deployment/podinfo podinfod=stefanprodan/podinfo:6.0.1
$ kubectl -n test describe canary/podinfo | tail -6
Events:
  New revision detected! Scaling up podinfo.canary
  Starting canary analysis for podinfo.test
  Advance podinfo.test canary weight 10
  Advance podinfo.test canary weight 20
  ...
  Copying podinfo.test template spec to podinfo-primary  # promoción
```

> **Preguntas de comprensión (6)**
> 1. Argo Rollouts *reemplaza* el Deployment por un CRD; Flagger *envuelve* un Deployment existente. ¿Qué implica cada modelo para migrar una app ya desplegada con Helm y para el GitOps que la gestiona (p. ej. drift)?
> 2. Flagger incluye un `webhook` de `load-test` que genera tráfico sintético contra el canary. ¿Por qué es necesario en un canary automatizado y qué problema resuelve cuando el tráfico orgánico es bajo o nulo (p. ej. servicios internos)?
> 3. Compará el modelo declarativo de análisis: `steps` explícitos con `analysis` (Argo) vs `stepWeight`/`maxWeight`/`threshold` (Flagger). ¿Cuál te da control fino por-etapa y cuál favorece una progresión uniforme?
> 4. Ambos requieren un mesh/ingress para split L7 preciso. Como platform engineer que ofrece progressive delivery *as a self-service* a decenas de equipos, ¿qué criterios (mesh existente, curva de aprendizaje, GitOps, UI) usarías para estandarizar en uno u otro?

---

## Síntesis — Elegir la estrategia

| Criterio | Blue/Green | Canary (pod-count) | Canary (traffic L7) |
|---|---|---|---|
| Capacidad extra durante deploy | 100 % (2× réplicas) | ~1 pod | configurable (`setCanaryScale`) |
| Precisión del split de tráfico | binaria (0 % / 100 %) | grosera (por endpoints) | fina (por request) |
| Exposición del usuario a la vN | todos, de golpe | fracción creciente | fracción exacta creciente |
| Rollback | cutover inverso instantáneo | descartar canary | reescribir pesos a 0 |
| Validación automática por métricas | limitada (preview) | sí | sí, la más representativa |
| Complejidad de infra | baja (2 Services) | baja | alta (mesh/Gateway API) |

> **Preguntas de comprensión (síntesis)**
> 1. Un banco despliega un servicio de pagos donde *ninguna* transacción errónea es tolerable, pero puede pagar el doble de cómputo por unos minutos. ¿Blue/Green o Canary? Justificá.
> 2. Un servicio de recomendaciones de alto tráfico quiere medir el impacto de un modelo nuevo en la latencia p99 con exposición controlada al 5 %. ¿Qué estrategia y qué mecanismo de traffic routing?
> 3. ¿Por qué progressive delivery es *ortogonal* a GitOps pero se complementan? Si Argo CD sincroniza el estado deseado, ¿quién "posee" los pesos intermedios del canary durante una promoción, y por qué eso puede causar drift si no configurás `ignoreDifferences`?

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 0
1. Un `Deployment` nativo solo sabe hacer `RollingUpdate` o `Recreate`; su lógica de rollout está fija en el `kube-controller-manager`. `Rollout` es un CRD porque necesita un **controlador propio** que sepa manipular ReplicaSets, Services/HTTPRoutes y correr `AnalysisRun`s condicionando la progresión. Al reemplazar al Deployment controller, el controlador de Argo Rollouts gana el control total del ciclo de vida de los ReplicaSets (crear preview, pausar, escalar canary, cutover) que el nativo no expone.
2. El **controlador** (`deployment/argo-rollouts` en el namespace `argo-rollouts`) es quien reconcilia: crea/escala ReplicaSets y reescribe selectores/pesos. El plugin `kubectl argo rollouts` solo lee estado y escribe anotaciones/patches (p. ej. la de `promote`). Si el pod del controlador cae en medio de una promoción, **el estado en el cluster no se corrompe**: el rollout queda "congelado" en su último estado reconciliado (los ReplicaSets siguen como estaban) y, al reiniciar, el controlador reconcilia hacia el estado deseado. Es *level-triggered*, no *edge-triggered*.
3. El controlador es **cluster-scoped** por sus CRDs y por watchear Rollouts en todos los namespaces (en la instalación estándar). Se instala en `argo-rollouts` como componente de plataforma; las apps viven en namespaces de equipo como `pd-lab`. Separa el plano de control del workload.

### Ejercicio 1
1. En `Paused`, el Rollout corre **3 pods stable + 3 pods preview = 6 pods**, el doble de un Deployment de 3 réplicas. El costo de Blue/Green es esa **capacidad duplicada sostenida** mientras coexisten active y preview; lo pagás desde que se crea el preview hasta que expira `scaleDownDelaySeconds`, promociones o no. Para servicios con requests de CPU/memoria grandes o muchas réplicas, es caro.
2. Contra el preview tienen sentido: smoke tests, contract/integration tests, health checks profundos, validación de migraciones de esquema *read-only*, y verificación manual por QA. **No** se puede validar comportamiento bajo carga real de producción, interacción con el patrón de tráfico real de usuarios, ni efectos que solo emergen con volumen/diversidad de requests — para eso hace falta Canary.
3. `scaleDownDelaySeconds` es el tiempo que el ReplicaSet *viejo* (active anterior) permanece escalado tras la promoción, para permitir rollback instantáneo (basta re-apuntar el active). Con `0`, el ReplicaSet viejo se escala a 0 inmediatamente y el rollback ya **no es instantáneo**: hay que recrear pods (arranque de imagen, readiness). Si detectás el bug a los 5 minutos y el delay era 30s, el ReplicaSet viejo **ya se escaló a 0**; el rollback sigue siendo posible (vía `undo`) pero **no instantáneo**, porque hay que reescalar.
4. El cambio de selector del Service es atómico a nivel de objeto API, pero **no** corta conexiones TCP ya establecidas: `kube-proxy`/endpoints solo afectan a *nuevas* conexiones. Las conexiones existentes contra pods `blue` siguen vivas hasta que se cierran (o hasta que esos pods se escalan a 0 tras el delay). Por eso conviene draining/keep-alive corto para un cutover realmente limpio.

### Ejercicio 2
1. Con `replicas: 3` y `setWeight: 10`, el controlador no puede crear "0.3 pods": redondea a un mínimo de **1 pod canary** (~33% real, no 10%). El mínimo que crea es 1 pod canary salvo que uses `setCanaryScale` para desacoplar. Sin traffic router, el peso efectivo está cuantizado por `1/replicas`; para pesos finos necesitás muchas réplicas o un traffic router L7.
2. `kube-proxy` balancea *conexiones/endpoints*, no requests. Rompen la proporción: (a) **HTTP keep-alive** — una conexión persistente manda muchas requests siempre al mismo pod; (b) **distribución no uniforme de sesiones/clientes** — clientes pesados pegados a un endpoint; además el modo `iptables` reparte por probabilidad estadística, no exacta, y clientes con connection pooling sesgan aún más. El resultado es que "20% de pods" ≠ "20% de requests".
3. `pause: {}` es **indefinida**: el Rollout se detiene hasta un `promote` (o `abort`) humano. `pause: { duration: 30s }` es **temporizada**: se resuelve sola al vencer. Una pausa indefinida se reanuda con `kubectl argo rollouts promote <rollout>`.
4. Canary crea como máximo ~1 pod extra por vez (6 transitorio con `setCanaryScale` moderado, o menos), mientras Blue/Green sostiene 6 pods todo el tiempo → Canary es más barato en capacidad. Pero Canary progresa por steps con pausas (minutos) mientras valida, así que el despliegue completo tarda más → más lento en *time-to-100%*. Es el trade-off capacidad↔tiempo/seguridad.

### Ejercicio 3
1. Con `count: 3` y `failureLimit: 1`: apenas **1 medición fallida** dispara el `abort` (no espera las 3). Para `Successful` deben completarse las **3 mediciones** sin exceder el `failureLimit` (es decir, 0 fallos, o hasta `failureLimit` si fuera >0 y aun así completar el count). O sea: falla rápido con 1 error; para éxito necesita cumplir las 3.
2. **Inline en step**: el rollout se detiene en ese step hasta que el análisis concluye; es un *gate*. **Background**: el `AnalysisRun` arranca en un `setWeight` temprano y corre en paralelo mientras los steps siguen avanzando; si falla en cualquier momento, aborta. El background detecta antes una regresión que solo aparece con más tráfico, porque vigila continuamente a través de los incrementos de peso, no solo en un instante.
3. La query agrega stable+canary del mismo `service`. Si el canary tiene solo 20% del tráfico y falla, su contribución al ratio global puede quedar **diluida** por el 80% sano del stable → el promedio sigue ≥0.95 y el canary defectuoso pasa. Hay que **aislar el canary** filtrando por el label que el controlador inyecta en los pods canary (p. ej. `rollouts-pod-template-hash="<hash-canary>"`), de modo que la query mida solo requests servidas por el canary.
4. Si Prometheus está caído, el provider no obtiene resultado y la medición se cuenta como **error/fallida** (inconclusive tratado como fallo), lo que puede abortar el rollout — comportamiento *fail-safe*. Se ajusta con `inconclusiveLimit` (y `consecutiveErrorLimit`): permiten tolerar N errores del provider antes de marcar `Error`/`Inconclusive` en vez de `Failed`.

### Ejercicio 4
1. Con router L7 (Istio/SMI/Gateway API/Nginx), el split se aplica **por request** en el proxy (sidecar o ingress/gateway) según los `weight` de los backends del `HTTPRoute`/`VirtualService`. La decisión de routing ocurre en el data plane del mesh/gateway, independiente de cuántos pods haya, así que `setWeight: 10` sí produce ~10% de requests al canary.
2. Rutear 30% del tráfico a solo 30% de la capacidad nominal está bien **si** ese 30% de réplicas puede sostener ese 30% de carga; el riesgo es **saturar el canary** (latencia/errores) si el dimensionamiento no acompaña, dando un falso negativo de la nueva versión (falla por falta de capacidad, no por bug). `matchTrafficWeight: true` (o dejar que el scale siga al weight) conviene cuando querés que capacidad y tráfico crezcan juntos para evitar sobrecargar el canary.
3. El traffic router necesita **dos backends distinguibles** (`stableService` y `canaryService`, cada uno seleccionando solo su ReplicaSet vía el pod-template-hash) para poder asignarles pesos distintos en el `HTTPRoute`. Con un solo Service que agrupa ambos ReplicaSets, el router no podría separar el tráfico stable del canary.
4. La estrategia (steps, weights, análisis) queda **portable**: es lógica de negocio del despliegue. El mecanismo de tráfico es un plugin intercambiable, así que un equipo puede pasar de Nginx a Istio a Gateway API sin reescribir su política de progressive delivery. Para una plataforma, eso significa una **abstracción estable** para los equipos y libertad de evolucionar el data plane por debajo.

### Ejercicio 5
1. `abort` es fail-safe porque **nunca promueve**: revierte el peso del canary a 0 y deja al **stable (versión anterior, buena)** sirviendo el 100% del tráfico. El servicio permanece disponible con la versión estable mientras un operador decide `retry` o `undo`. Un despliegue fallido no degrada la disponibilidad.
2. `abort` detiene y descarta el canary de la revisión en curso (queda `Degraded`). `retry` reintenta la **misma** revisión abortada. `undo` revierte a una revisión anterior conocida. Falso positivo por Prometheus intermitente → `retry` (la imagen está bien). Bug real en la imagen → `undo` a la última revisión buena (o corregir la imagen y desplegar una nueva revisión).
3. `--to-revision=2` reutilizó un ReplicaSet aún presente (escalado a 0 pero no podado), así que el rollback solo lo reescala → casi instantáneo. `revisionHistoryLimit` fija cuántos ReplicaSets viejos se conservan; si pedís revertir a una revisión ya **podada** (más allá del límite), ese ReplicaSet ya no existe y Argo debe recrearlo desde el historial de spec — más lento, y si no hay spec disponible, falla.
4. Regresiones que **pasan** el success-rate: corrupción silenciosa de datos (respuestas 200 pero con contenido incorrecto), vulnerabilidades de seguridad, fugas de datos, o degradaciones que no se reflejan en HTTP status ni latencia. Defensas complementarias: métricas de negocio/correctitud como custom metrics en el análisis, contract tests, revisión de seguridad (SAST/DAST) en CI antes del deploy, y análisis con Kayenta/juicios comparativos stable-vs-canary sobre señales de dominio.

### Ejercicio 6
1. Argo Rollouts reemplaza el Deployment → migrar una app existente exige **convertir** el `Deployment` en `Rollout` (cambio de `kind`), lo que toca el chart de Helm y el repo GitOps. Flagger **envuelve** el Deployment → menos intrusivo para adoptar, pero introduce objetos derivados (`-primary`, `-canary`) que Flagger gestiona; el GitOps debe **ignorar** esos objetos y el reescalado del Deployment original para no pelear con Flagger (drift). En ambos casos hay que configurar `ignoreDifferences`/exclusiones en Argo CD.
2. El `load-test` webhook genera **tráfico sintético** contra el canary durante el análisis. Es necesario porque el veredicto por métricas requiere un volumen mínimo de requests para ser estadísticamente significativo; si el tráfico orgánico es bajo o el servicio es interno/batch con picos, sin carga generada las métricas serían ruido o inexistentes y el canary nunca reuniría evidencia para promover.
3. Argo con `steps`+`analysis` da **control fino por etapa**: podés intercalar pesos arbitrarios, pausas específicas, análisis distintos en distintos puntos y experimentos. Flagger con `stepWeight`/`maxWeight`/`threshold` favorece una **progresión uniforme y declarativa** (incrementos parejos hasta el tope) con menos flexibilidad pero configuración más compacta.
4. Criterios: **mesh ya existente** (si el equipo ya corre Istio/Linkerd, Flagger encaja natural; Argo integra con varios providers y también funciona sin mesh vía pod-count); **modelo GitOps** (Argo Rollouts se integra fuerte con Argo CD y su UI/dashboard unificado); **curva de aprendizaje y self-service** (Argo tiene UI y plugin CLI ricos para dozens de equipos); **flexibilidad de estrategia** (Blue/Green + Canary + experiments en Argo vs canary/AB/blue-green en Flagger). Estandarizás en el que minimice fricción con tu stack actual y ofrezca la mejor UX de plataforma.

### Síntesis
1. **Blue/Green.** Si ninguna transacción errónea es tolerable, no querés exponer *ningún* usuario real a la vN sin validación previa; validás el preview exhaustivamente y hacés cutover atómico (rollback instantáneo). El costo de duplicar cómputo unos minutos es aceptable para el banco. Un canary expondría un % de pagos reales a la versión no validada, inaceptable aquí.
2. **Canary con traffic routing L7** (Istio/Gateway API), `setWeight: 5` + `analysis` sobre p99 de latencia. El split por request garantiza exactamente ~5% de exposición y el análisis de métricas mide el impacto real en producción con controlada exposición, con abort automático si la p99 se degrada.
3. Progressive delivery decide *cómo* transiciona el tráfico entre versiones; GitOps decide *cuál* es el estado deseado declarado en Git. Son ortogonales pero se complementan: Git declara la imagen/target y el operador de rollout ejecuta la transición. Durante una promoción, **el controlador de Rollouts/Flagger "posee" los pesos intermedios** (los va modificando en vivo), que no están en Git; si Argo CD compara y ve esos pesos transitorios divergentes del manifiesto, marca **drift** e intenta revertirlos, peleando con el rollout. Por eso configurás `ignoreDifferences` sobre los campos que el controlador gestiona (pesos, réplicas del canary, selectores inyectados).

</details>