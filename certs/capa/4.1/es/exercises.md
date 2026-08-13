# Tema 4.1: Argo Rollouts — Ejercicios guiados

> **Dominio 4 del examen CAPA (Certified Argo Project Associate), peso 20%.**
> Argo Rollouts es el controller de *progressive delivery* de la Argo Project. Reemplaza el objeto `Deployment` por un CRD `Rollout` que orquesta estrategias **canary** y **blue-green** con pasos declarativos, análisis automático de métricas y control de tráfico. Estos ejercicios asumen un cluster funcional (kind, minikube, k3d o uno real) y `kubectl` configurado.
>
> Fuentes oficiales:
> - Curriculum CAPA: https://raw.githubusercontent.com/cncf/curriculum/master/capa/README.md
> - Documentación Argo Rollouts: https://argo-rollouts.readthedocs.io/en/stable/
> - Especificación del CRD `Rollout`: https://argo-rollouts.readthedocs.io/en/stable/features/specification/

---

## Prerrequisitos y verificación del entorno

```bash
# Debés tener un cluster accesible
kubectl version --output=yaml | grep -A1 serverVersion
kubectl cluster-info
```

Salida esperada (los valores exactos varían según tu cluster):

```
serverVersion:
  gitVersion: v1.29.2
Kubernetes control plane is running at https://127.0.0.1:6443
```

---

## Ejercicio 1 — Instalar el controller y el plugin CLI

El proyecto se compone de **dos piezas**: el controller (corre en el cluster) y el plugin `kubectl argo rollouts` (corre en tu máquina y traduce el estado del CRD a una vista de árbol legible).

**Pasos:**

1. Creá el namespace dedicado e instalá el controller con el manifiesto oficial:

   ```bash
   kubectl create namespace argo-rollouts
   kubectl apply -n argo-rollouts \
     -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
   ```

2. Esperá a que el controller esté disponible:

   ```bash
   kubectl -n argo-rollouts rollout status deployment/argo-rollouts
   ```

   Salida esperada:

   ```
   deployment "argo-rollouts" successfully rolled out
   ```

3. Verificá que los CRDs quedaron registrados:

   ```bash
   kubectl get crd | grep argoproj.io
   ```

   Salida esperada (fragmento):

   ```
   analysisruns.argoproj.io          2026-08-12T10:00:00Z
   analysistemplates.argoproj.io     2026-08-12T10:00:00Z
   clusteranalysistemplates.argoproj.io  2026-08-12T10:00:00Z
   experiments.argoproj.io           2026-08-12T10:00:00Z
   rollouts.argoproj.io              2026-08-12T10:00:00Z
   ```

4. Instalá el plugin CLI (Linux amd64; ajustá la arquitectura según tu SO):

   ```bash
   curl -sSL -o kubectl-argo-rollouts \
     https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
   chmod +x kubectl-argo-rollouts
   sudo mv kubectl-argo-rollouts /usr/local/bin/
   kubectl argo rollouts version
   ```

   Salida esperada:

   ```
   kubectl-argo-rollouts: v1.7.2+abc1234
     BuildDate: 2026-05-10T12:00:00Z
     GoVersion: go1.22
     Compiler: gc
     Platform: linux/amd64
   ```

**Preguntas de comprensión:**

- **1.a** El plugin `kubectl argo rollouts` no está corriendo cuando ocurre un rollout. ¿Quién ejecuta realmente la lógica de la estrategia (pausas, `setWeight`, análisis)?
- **1.b** ¿Qué diferencia hay entre un `AnalysisTemplate` y un `ClusterAnalysisTemplate`, según los CRDs que aparecen en el paso 3?
- **1.c** Si borrás el plugin CLI de tu máquina, ¿deja de funcionar un `Rollout` que ya está en curso? ¿Por qué?

---

## Ejercicio 2 — Tu primer Rollout con estrategia canary

El objeto `Rollout` es un *drop-in replacement* del `Deployment`: comparte `replicas`, `selector` y `template`, pero agrega `strategy.canary` o `strategy.blueGreen`.

**Pasos:**

1. Guardá este manifiesto como `rollout-canary.yaml`:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Rollout
   metadata:
     name: rollouts-demo
   spec:
     replicas: 5
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
               cpu: 5m
               memory: 32Mi
     strategy:
       canary:
         steps:
         - setWeight: 20
         - pause: {}                 # pausa indefinida hasta promoción manual
         - setWeight: 40
         - pause: {duration: 30s}
         - setWeight: 60
         - pause: {duration: 30s}
         - setWeight: 80
         - pause: {duration: 30s}
   ```

2. Aplicá el manifiesto:

   ```bash
   kubectl apply -f rollout-canary.yaml
   ```

3. Observá el estado en tiempo real (dejá esta terminal abierta):

   ```bash
   kubectl argo rollouts get rollout rollouts-demo --watch
   ```

   En la **primera** aplicación **no hay canary**: como no existe versión previa, el controller escala directo a las 5 réplicas. Salida esperada:

   ```
   Name:            rollouts-demo
   Namespace:       default
   Status:          ✔ Healthy
   Strategy:        Canary
     Step:          8/8
     SetWeight:     100
     ActualWeight:  100
   Images:          argoproj/rollouts-demo:blue (stable)
   Replicas:
     Desired:       5
     Current:       5
     Updated:       5
     Ready:         5
     Available:     5

   NAME                                       KIND        STATUS     AGE  INFO
   ⟳ rollouts-demo                            Rollout     ✔ Healthy  30s
   └──# revision:1
      └──⧉ rollouts-demo-687d76d795           ReplicaSet  ✔ Healthy  30s  stable
         ├──□ rollouts-demo-687d76d795-x1     Pod         ✔ Running  30s  ready:1/1
         └──□ ...                             Pod         ✔ Running  30s  ready:1/1
   ```

4. Confirmá que se creó un `ReplicaSet` (Argo Rollouts usa ReplicaSets, igual que un Deployment):

   ```bash
   kubectl get rs -l app=rollouts-demo
   ```

**Preguntas de comprensión:**

- **2.a** ¿Por qué la **primera** creación de un `Rollout` no ejecuta los pasos del canary?
- **2.b** ¿Qué significa la diferencia entre `SetWeight` y `ActualWeight` en la salida del `get rollout`?
- **2.c** En el paso `- pause: {}`, ¿cuánto dura la pausa? ¿Y en `- pause: {duration: 30s}`?
- **2.d** Sin un *traffic router* (Istio, NGINX, SMI, ALB...), ¿cómo aproxima Argo Rollouts un `setWeight: 20` con 5 réplicas?

---

## Ejercicio 3 — Disparar un update y promover manualmente

Ahora que existe la revisión 1, un cambio de imagen **sí** dispara la estrategia canary.

**Pasos:**

1. Cambiá la imagen (de `:blue` a `:yellow`) usando el plugin:

   ```bash
   kubectl argo rollouts set image rollouts-demo \
     rollouts-demo=argoproj/rollouts-demo:yellow
   ```

2. Mirá el `--watch` de la terminal del ejercicio anterior. El rollout avanza al paso 1 (`setWeight: 20`) y se **detiene** en el paso 2 (`pause: {}`). Salida esperada:

   ```
   Status:          ॥ Paused
   Message:         CanaryPauseStep
     Step:          2/8
     SetWeight:     20
     ActualWeight:  20
   Images:          argoproj/rollouts-demo:blue (stable)
                    argoproj/rollouts-demo:yellow (canary)
   ...
   ├──# revision:2
   │  └──⧉ rollouts-demo-6f9b8c5d4c   ReplicaSet  ✔ Healthy  20s  canary
   │     └──□ ...                     Pod         ✔ Running  20s  ready:1/1
   └──# revision:1
      └──⧉ rollouts-demo-687d76d795   ReplicaSet  ✔ Healthy  4m   stable
   ```

   Notá que la revisión 2 tiene **1 réplica** (20% de 5) marcada como `canary`, y la revisión 1 mantiene 4 réplicas `stable`.

3. Verificá el estado con exit code (útil en CI/CD; bloquea hasta terminar o fallar):

   ```bash
   kubectl argo rollouts status rollouts-demo
   # imprime: Paused - CanaryPauseStep
   ```

4. Promocioná al **siguiente paso**:

   ```bash
   kubectl argo rollouts promote rollouts-demo
   ```

   El rollout avanza a `setWeight: 40`, luego a las pausas con `duration`, que se resuelven solas.

5. (Opcional) Si querés **saltar todos los pasos restantes** y promover a estable de una:

   ```bash
   kubectl argo rollouts promote rollouts-demo --full
   ```

6. Esperá a `Healthy` y confirmá que la revisión 2 es ahora `stable`:

   ```bash
   kubectl argo rollouts status rollouts-demo
   # imprime: Healthy
   ```

**Preguntas de comprensión:**

- **3.a** ¿Qué diferencia hay entre `promote` y `promote --full`?
- **3.b** En el estado `Paused` del paso 2, ¿por qué el `Image` marcado como `stable` sigue siendo `:blue` y no `:yellow`?
- **3.c** Un pipeline de CI corre `kubectl argo rollouts status rollouts-demo` y el comando no retorna. ¿Es un bug? ¿Qué hace ese comando por defecto?
- **3.d** ¿En qué se diferencia `set image` (del plugin) de editar `spec.template.spec.containers[].image` con `kubectl edit`? ¿Cuál dispara el canary?

---

## Ejercicio 4 — Abortar, hacer rollback y reintentar

La red de seguridad de un canary es poder cortar y volver atrás **sin downtime**.

**Pasos:**

1. Disparás un update "malo":

   ```bash
   kubectl argo rollouts set image rollouts-demo \
     rollouts-demo=argoproj/rollouts-demo:red
   ```

2. Cuando llegue a la pausa, **abortá**:

   ```bash
   kubectl argo rollouts abort rollouts-demo
   ```

   El `abort` escala el canary a 0 y devuelve el 100% del tráfico a la versión estable. Salida esperada:

   ```
   Status:          ✖ Degraded
   Message:         RolloutAborted: Rollout aborted update to revision 3
     Step:          0/8
     SetWeight:     0
     ActualWeight:  0
   Images:          argoproj/rollouts-demo:yellow (stable)
   ```

   > **Punto clave:** el estado queda `Degraded` porque la *spec deseada* (revisión 3) no está sirviendo tráfico. El servicio sigue sano sobre la revisión estable, pero el `Rollout` no coincide con lo declarado.

3. Para "olvidar" la revisión abortada y volver a estable de forma limpia, revertí la imagen a la estable actual:

   ```bash
   kubectl argo rollouts set image rollouts-demo \
     rollouts-demo=argoproj/rollouts-demo:yellow
   ```

   El estado vuelve a `Healthy` sin desplegar nada nuevo (la revisión estable ya existe).

4. Alternativa — `undo` a una revisión anterior por número:

   ```bash
   kubectl argo rollouts get rollout rollouts-demo   # anotá los números de revisión
   kubectl argo rollouts undo rollouts-demo --to-revision=1
   ```

5. Si un canary quedó `Degraded` por un análisis fallido y querés **reintentar**:

   ```bash
   kubectl argo rollouts retry rollout rollouts-demo
   ```

**Preguntas de comprensión:**

- **4.a** Tras un `abort`, ¿el rollout queda `Healthy` o `Degraded`? ¿Por qué esa distinción es correcta y no un error?
- **4.b** ¿Por qué re-aplicar la imagen estable con `set image` es más rápido que un rollout normal?
- **4.c** ¿Qué hace `undo` internamente? ¿Crea una imagen nueva o reutiliza un `ReplicaSet` existente?
- **4.d** ¿Cuándo usarías `retry` en vez de `abort` + nuevo deploy?

---

## Ejercicio 5 — Estrategia blue-green

En blue-green conviven **dos entornos completos**. `activeService` apunta al que sirve producción; `previewService` apunta a la versión nueva antes de promoverla.

**Pasos:**

1. Guardá `rollout-bluegreen.yaml`:

   ```yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: bluegreen-active
   spec:
     selector:
       app: bluegreen-demo
     ports:
     - port: 80
       targetPort: 8080
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: bluegreen-preview
   spec:
     selector:
       app: bluegreen-demo
     ports:
     - port: 80
       targetPort: 8080
   ---
   apiVersion: argoproj.io/v1alpha1
   kind: Rollout
   metadata:
     name: bluegreen-demo
   spec:
     replicas: 3
     selector:
       matchLabels:
         app: bluegreen-demo
     template:
       metadata:
         labels:
           app: bluegreen-demo
       spec:
         containers:
         - name: bluegreen-demo
           image: argoproj/rollouts-demo:blue
           ports:
           - containerPort: 8080
     strategy:
       blueGreen:
         activeService: bluegreen-active
         previewService: bluegreen-preview
         autoPromotionEnabled: false
         scaleDownDelaySeconds: 30
   ```

2. Aplicá y disparás un update:

   ```bash
   kubectl apply -f rollout-bluegreen.yaml
   kubectl argo rollouts set image bluegreen-demo \
     bluegreen-demo=argoproj/rollouts-demo:green
   ```

3. Observá: la versión nueva (`green`) se levanta completa en paralelo y el `previewService` la enruta, pero `activeService` sigue en `blue`. Salida esperada:

   ```
   Status:          ॥ Paused
   Message:         BlueGreenPause
   Images:          argoproj/rollouts-demo:blue (stable, active)
                    argoproj/rollouts-demo:green (preview)
   ```

4. Verificá a qué `ReplicaSet` apunta cada Service leyendo el selector con hash:

   ```bash
   kubectl get svc bluegreen-active -o jsonpath='{.spec.selector}'
   echo
   kubectl get svc bluegreen-preview -o jsonpath='{.spec.selector}'
   echo
   ```

   Los selectores incluyen `rollouts-pod-template-hash` distintos.

5. Promocioná (corta el `activeService` a `green`):

   ```bash
   kubectl argo rollouts promote bluegreen-demo
   ```

   El entorno viejo (`blue`) queda vivo `scaleDownDelaySeconds` segundos por si necesitás un rollback instantáneo, y luego se escala a 0.

**Preguntas de comprensión:**

- **5.a** En blue-green, en el momento de la promoción, ¿cuántas réplicas de la aplicación existen simultáneamente (con `replicas: 3`)? ¿Qué implica eso para la capacidad del cluster frente a un canary?
- **5.b** ¿Para qué sirve `scaleDownDelaySeconds`? ¿Qué perdés si lo ponés en 0?
- **5.c** ¿Cómo modifica Argo Rollouts a qué Pods apunta un `Service` sin editar el `.spec.selector` que vos escribiste? (pista: `rollouts-pod-template-hash`)
- **5.d** Si `autoPromotionEnabled: true`, ¿qué comportamiento cambia?

---

## Ejercicio 6 — Análisis automático con Prometheus (AnalysisTemplate)

El valor real del *progressive delivery* es promover o abortar según **métricas**, no según un humano mirando. Un `AnalysisTemplate` define consultas y condiciones de éxito.

**Pasos:**

1. Definí un `AnalysisTemplate` parametrizado en `analysis-success-rate.yaml`:

   ```yaml
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
       count: 5
       # el análisis falla si acumula 3 mediciones por debajo del umbral
       failureLimit: 3
       successCondition: result[0] >= 0.95
       provider:
         prometheus:
           address: http://prometheus.monitoring.svc.cluster.local:9090
           query: |
             sum(irate(
               http_requests_total{service="{{args.service-name}}",status!~"5.."}[2m]
             )) /
             sum(irate(
               http_requests_total{service="{{args.service-name}}"}[2m]
             ))
   ```

2. Referenciá el template en la estrategia canary. Reemplazá los `steps` del ejercicio 2 por esta variante y volvé a aplicar:

   ```yaml
     strategy:
       canary:
         steps:
         - setWeight: 20
         - pause: {duration: 1m}
         - analysis:                     # análisis puntual, bloquea la progresión
             templates:
             - templateName: success-rate
             args:
             - name: service-name
               value: rollouts-demo
         - setWeight: 60
         - pause: {duration: 1m}
   ```

3. Aplicá el template y disparás un update:

   ```bash
   kubectl apply -f analysis-success-rate.yaml
   kubectl argo rollouts set image rollouts-demo \
     rollouts-demo=argoproj/rollouts-demo:yellow
   ```

4. Observá el `AnalysisRun` que se genera cuando el rollout llega al paso de `analysis`:

   ```bash
   kubectl argo rollouts get rollout rollouts-demo
   kubectl get analysisrun
   kubectl describe analysisrun <nombre-del-analysisrun>
   ```

   Salida esperada (fragmento del árbol):

   ```
   ├──# revision:2
   │  ├──⧉ rollouts-demo-6f9b8c5d4c   ReplicaSet   ✔ Healthy       canary
   │  └──α rollouts-demo-6f9b8c5d4c-2-1  AnalysisRun  ◌ Running    ✔ 3
   ```

5. **Análisis en background** (evalúa durante *todos* los pasos, no en uno puntual). Alternativa a `steps[].analysis`:

   ```yaml
     strategy:
       canary:
         analysis:
           templates:
           - templateName: success-rate
           startingStep: 2         # empieza a medir recién en el paso 2
           args:
           - name: service-name
             value: rollouts-demo
         steps:
         - setWeight: 20
         - pause: {duration: 5m}
         - setWeight: 50
         - pause: {duration: 5m}
   ```

**Preguntas de comprensión:**

- **6.a** ¿Qué diferencia hay entre poner `analysis` como un *step* (inline) y ponerlo en `strategy.canary.analysis` (background)?
- **6.b** Con `interval: 30s`, `count: 5` y `failureLimit: 3`: ¿cuántas mediciones toma como máximo un `AnalysisRun` exitoso, y cuántas mediciones fallidas hacen falta para abortar?
- **6.c** Si el `AnalysisRun` entra en estado `Failed`, ¿qué le pasa al `Rollout`? ¿Vuelve el tráfico a estable automáticamente?
- **6.d** ¿Por qué `successCondition` usa `result[0]` y no simplemente `result`?

---

## Ejercicio 7 — Migrar un Deployment existente con `workloadRef`

En producción rara vez creás un `Rollout` desde cero: migrás un `Deployment` que ya existe. `workloadRef` deja que el `Rollout` **referencie** el `template` del Deployment en lugar de copiarlo, evitando drift entre ambos.

**Pasos:**

1. Partí de un Deployment existente (`legacy-deploy.yaml`):

   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: legacy-app
   spec:
     replicas: 4
     selector:
       matchLabels:
         app: legacy-app
     template:
       metadata:
         labels:
           app: legacy-app
       spec:
         containers:
         - name: legacy-app
           image: argoproj/rollouts-demo:blue
           ports:
           - containerPort: 8080
   ```

   ```bash
   kubectl apply -f legacy-deploy.yaml
   ```

2. Creá un `Rollout` que referencia ese Deployment con `workloadRef` (`rollout-ref.yaml`):

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Rollout
   metadata:
     name: legacy-app-rollout
   spec:
     replicas: 4
     selector:
       matchLabels:
         app: legacy-app
     workloadRef:
       apiVersion: apps/v1
       kind: Deployment
       name: legacy-app
       scaleDown: onsuccess    # escala el Deployment a 0 cuando el Rollout está sano
     strategy:
       canary:
         steps:
         - setWeight: 25
         - pause: {duration: 30s}
         - setWeight: 75
         - pause: {duration: 30s}
   ```

   > Notá que **no hay `template`** en el `Rollout`: lo toma del Deployment referenciado.

3. Aplicá y observá cómo el Rollout adopta el template del Deployment:

   ```bash
   kubectl apply -f rollout-ref.yaml
   kubectl argo rollouts get rollout legacy-app-rollout
   ```

4. Confirmá que, con `scaleDown: onsuccess`, el Deployment original quedó en 0 réplicas una vez que el Rollout llegó a `Healthy`:

   ```bash
   kubectl get deploy legacy-app
   # READY   0/0
   ```

5. A partir de acá, para desplegar cambios editás el **Deployment** (o el Rollout); el Rollout detecta el cambio de `template` y ejecuta el canary.

**Preguntas de comprensión:**

- **7.a** ¿Qué ventaja operativa da `workloadRef` frente a copiar el `template` completo dentro del `Rollout`?
- **7.b** ¿Qué hace `scaleDown: onsuccess`? ¿En qué se diferencia de `scaleDown: never`?
- **7.c** Durante la migración, si el `Rollout` y el `Deployment` comparten el mismo `selector` (`app: legacy-app`), ¿por qué no pelean por los mismos Pods de forma caótica? (pista: `rollouts-pod-template-hash`)
- **7.d** ¿Qué campo del `Rollout` es **obligatorio** repetir aunque uses `workloadRef`, y cuál se hereda?

---

## Ejercicio 8 — Diagnóstico y limpieza

**Pasos:**

1. Vista de árbol de todos los rollouts del namespace y sus eventos:

   ```bash
   kubectl argo rollouts list rollouts
   kubectl describe rollout rollouts-demo | sed -n '/Events/,$p'
   ```

2. Lanzá el dashboard web local (sirve la misma vista de árbol en el navegador, útil para demos):

   ```bash
   kubectl argo rollouts dashboard
   # Servido en http://localhost:3100/rollouts
   ```

3. Inspeccioná el estado crudo del CRD para ver los campos que el plugin resume:

   ```bash
   kubectl get rollout rollouts-demo -o jsonpath='{.status.currentPodHash}'
   echo
   kubectl get rollout rollouts-demo -o jsonpath='{.status.stableRS}'
   echo
   ```

4. Limpieza:

   ```bash
   kubectl delete rollout rollouts-demo bluegreen-demo legacy-app-rollout
   kubectl delete analysistemplate success-rate
   kubectl delete svc bluegreen-active bluegreen-preview
   kubectl delete deploy legacy-app
   ```

**Preguntas de comprensión:**

- **8.a** ¿Qué representa `status.stableRS` y en qué se diferencia de `status.currentPodHash`?
- **8.b** Al borrar un `Rollout`, ¿qué pasa con sus `ReplicaSets` y Pods? ¿Y con los `AnalysisRun` que generó?
- **8.c** `revisionHistoryLimit: 3` (ejercicio 2). ¿Qué controla exactamente ese número y por qué importa en un cluster con recursos limitados?

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1
- **1.a** El **controller** que corre en el namespace `argo-rollouts` (el Deployment `argo-rollouts`). Observa los CRDs `Rollout`/`AnalysisRun`/`Experiment` mediante un *reconcile loop* y ejecuta toda la lógica: escalar ReplicaSets, ajustar pesos, evaluar análisis, honrar pausas. El plugin CLI es solo un cliente de lectura/comando; no participa en la reconciliación.
- **1.b** Un `AnalysisTemplate` está *namespaced* (solo se puede referenciar desde Rollouts del mismo namespace); un `ClusterAnalysisTemplate` es *cluster-scoped* y sirve como plantilla reutilizable por Rollouts de cualquier namespace. Se referencian con `templateName` vs `clusterTemplateName`.
- **1.c** No. El Rollout sigue avanzando porque quien lo maneja es el controller en el cluster. Perdés la vista de árbol y los comandos `promote/abort/...`, pero podés operar igual con `kubectl patch`/`kubectl edit` sobre el CRD (aunque es más incómodo).

### Ejercicio 2
- **2.a** Porque no existe una versión previa estable con la cual comparar/repartir tráfico. El canary reparte entre "estable" y "nueva"; en la creación inicial no hay estable, así que el controller escala directo al 100%. Los pasos solo corren cuando cambia `spec.template` habiendo ya una revisión estable.
- **2.b** `SetWeight` es el peso **deseado** declarado por el paso actual; `ActualWeight` es el peso **efectivo** que el controller logró aplicar (según réplicas disponibles o lo que reporta el traffic router). Suelen coincidir, pero divergen transitoriamente mientras los Pods se crean o si el router aún no propagó la config.
- **2.c** `pause: {}` es una pausa **indefinida**: se queda ahí hasta un `promote` manual (o hasta un `abort`). `pause: {duration: 30s}` es una pausa **temporizada** de 30 segundos que se resuelve sola (acepta sufijos `s`, `m`, `h`; un número sin sufijo se interpreta en segundos).
- **2.d** Sin traffic router, el peso se aproxima por **cantidad de réplicas**: con 5 réplicas, `setWeight: 20` ≈ 1 Pod nuevo y 4 viejos. La granularidad está limitada por el número de réplicas; para pesos finos (p. ej. 5%) necesitás un traffic router real (Istio, NGINX, SMI, ALB, etc.).

### Ejercicio 3
- **3.a** `promote` avanza **un paso** (desbloquea la pausa actual y sigue hasta la próxima pausa/análisis). `promote --full` **salta todos los pasos, pausas y análisis restantes** y promueve la revisión a estable inmediatamente.
- **3.b** Porque "estable" es la revisión que ya pasó todo el proceso y sirve la mayoría del tráfico. Mientras el canary está `Paused` a mitad de camino, `:yellow` es aún la revisión **canary**, no estable. Recién al completar todos los pasos `:yellow` se convierte en `stable`.
- **3.c** No es un bug: por diseño `status` **bloquea** hasta que el rollout alcance un estado terminal (`Healthy`/`Degraded`) o quede pausado. Para no bloquear en CI usás `--watch=false`, o dejás que bloquee a propósito como *gate* del pipeline (retorna exit code 0 si sale sano, ≠0 si degradado).
- **3.d** Ambos disparan el canary: cualquier cambio en `spec.template` lo hace. `set image` es azúcar sintáctico del plugin que hace exactamente ese patch al campo de imagen; `kubectl edit` te deja tocar cualquier parte del template. La diferencia no es el efecto sino la ergonomía y el riesgo de tipeo.

### Ejercicio 4
- **4.a** Queda `Degraded`. Es correcto: el `Rollout` declara como deseada la revisión que abortaste, pero esa revisión **no** está sirviendo tráfico (se escaló a 0). Hay divergencia entre "lo declarado" y "lo servido", y eso es precisamente `Degraded`. El servicio sigue disponible sobre la estable; "degraded" describe el objeto, no una caída.
- **4.b** Porque el `ReplicaSet` de la versión estable **ya existe y está corriendo**; volver a apuntar a esa imagen es reconocer una revisión conocida, sin crear Pods nuevos ni recorrer los pasos del canary. Es casi instantáneo.
- **4.c** `undo` reutiliza un `ReplicaSet`/revisión **existente** del historial (por eso `--to-revision`), revirtiendo el `spec.template` a esa revisión previa. No construye una imagen nueva; reactiva una revisión ya registrada dentro de `revisionHistoryLimit`.
- **4.d** Usás `retry` cuando el rollout quedó `Degraded` por una causa **transitoria** (un `AnalysisRun` que falló por un pico momentáneo, un pull de imagen que ya se resolvió) y querés reintentar **la misma** revisión sin re-disparar un deploy nuevo. `abort` + nuevo deploy es para cuando la revisión en sí está mal.

### Ejercicio 5
- **5.a** En la promoción existen **6** réplicas simultáneas (3 blue + 3 green), más el delay de scale-down. Blue-green duplica la capacidad requerida durante la transición; un canary solo agrega una fracción (el peso del canary), por lo que es más barato en recursos pero expone a los usuarios a la versión nueva de forma gradual.
- **5.b** `scaleDownDelaySeconds` mantiene el entorno viejo vivo N segundos tras la promoción para permitir un **rollback instantáneo** (volver a apuntar el `activeService` sin recrear Pods). Con 0, el viejo se escala inmediatamente y un rollback obliga a recrear todo el entorno anterior (más lento).
- **5.c** El controller agrega automáticamente el label `rollouts-pod-template-hash` a los Pods de cada ReplicaSet e **inyecta ese hash en el `.spec.selector` de los Services** gestionados (`activeService`/`previewService`). Así reenruta el tráfico cambiando el selector del Service al hash de la revisión deseada, sin que vos toques el selector.
- **5.d** Con `autoPromotionEnabled: true`, el Rollout **promueve solo** en cuanto la versión preview está `Healthy` (no espera un `promote` manual). Con `false`, se queda en `Paused/BlueGreenPause` esperando promoción explícita.

### Ejercicio 6
- **6.a** Como *step* inline (`steps[].analysis`), el análisis corre en **ese punto** del canary y **bloquea** la progresión hasta terminar. En `strategy.canary.analysis` (background), corre **en paralelo** a lo largo de los pasos (desde `startingStep`), monitoreando de forma continua; si falla en cualquier momento, aborta el rollout.
- **6.b** Máximo **5** mediciones exitosas (`count: 5`, una cada `interval: 30s`). El `AnalysisRun` aborta al acumular **3** mediciones que violan `successCondition` (`failureLimit: 3`).
- **6.c** El `Rollout` pasa a `Degraded` y **se aborta**: el canary se escala a 0 y el tráfico vuelve al 100% de la versión estable automáticamente. No requiere intervención manual; ese es el objetivo del análisis automático.
- **6.d** Porque el provider de Prometheus devuelve un **vector/lista** de resultados (una serie o más); `result[0]` toma el primer elemento (un escalar) sobre el cual evaluar la condición. Usar `result` a secas compararía contra la estructura entera, no contra el valor.

### Ejercicio 7
- **7.a** Evita el *drift*: el `template` vive en un solo lugar (el Deployment). Facilita la migración gradual y permite herramientas/GitOps que ya manejan Deployments sigan funcionando, mientras el Rollout solo añade la estrategia. Menos duplicación = menos chance de que Rollout y Deployment se desincronicen.
- **7.b** `scaleDown: onsuccess` escala el Deployment referenciado a **0 réplicas** una vez que el Rollout alcanza `Healthy` (evita correr doble carga). `scaleDown: never` deja el Deployment con sus réplicas intactas (útil durante una migración cautelosa o si otra cosa depende de él). También existe `progressively`, que va bajando el Deployment a medida que sube el Rollout.
- **7.c** Porque cada ReplicaSet (los del Deployment y los del Rollout) tiene un `rollouts-pod-template-hash`/`pod-template-hash` distinto en su selector real. Los controllers solo adoptan los Pods cuyo hash coincide con el suyo, así que no se disputan los mismos Pods pese a compartir el label `app`.
- **7.d** El `selector` (y `replicas`) es obligatorio en el `Rollout`; el `template` (la spec del Pod) es lo que se **hereda** del Deployment vía `workloadRef`.

### Ejercicio 8
- **8.a** `status.stableRS` es el hash del ReplicaSet marcado como **estable** (la versión que pasó todo el proceso). `status.currentPodHash` es el hash del template **deseado actual** (la última revisión declarada). Cuando coinciden, no hay update en curso; cuando difieren, hay un canary/blue-green progresando o abortado.
- **8.b** Al borrar el `Rollout`, por *owner references* se recolectan en cascada sus `ReplicaSets` y por lo tanto sus Pods. Los `AnalysisRun` generados por ese Rollout también son propiedad suya y se borran en cascada (salvo que hayas configurado políticas de retención distintas).
- **8.c** `revisionHistoryLimit` controla cuántos `ReplicaSets` **antiguos** (escalados a 0) conserva el controller para permitir `undo`/rollback. Un número alto acumula ReplicaSets vacíos (objetos en etcd, algo de overhead de listado); uno bajo ahorra recursos pero limita cuántas revisiones atrás podés revertir.

</details>