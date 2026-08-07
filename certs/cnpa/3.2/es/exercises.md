# Ejercicios guiados — Tema 3.2: Continuous Delivery Concepts and GitOps Principles

> **Requisitos previos.** Un cluster de práctica local (`kind create cluster` o `minikube start`), `kubectl` apuntando a él, `git`, y acceso a un repositorio Git propio (GitHub/GitLab). Los ejercicios usan las herramientas de referencia del ecosistema CNCF: **Argo CD** y **Flux CD**. Cada bloque termina con preguntas de verificación; las respuestas están al final en una sección colapsable.
>
> Fuentes oficiales: OpenGitOps Principles v1.0.0 (https://opengitops.dev/), Argo CD docs (https://argo-cd.readthedocs.io/), Flux docs (https://fluxcd.io/flux/), Argo Rollouts (https://argo-rollouts.readthedocs.io/), Kubernetes Deployments (https://kubernetes.io/docs/concepts/workloads/controllers/deployment/).

---

## Ejercicio 1 — Los cuatro principios de OpenGitOps sobre un repositorio declarativo

Objetivo: materializar en un repositorio real los principios **Declarative**, **Versioned and Immutable**, **Pulled Automatically** y **Continuously Reconciled**, y distinguir el *desired state* (Git) del *actual state* (cluster).

### Pasos

1. Creá la estructura de un repositorio GitOps. El estado deseado es **declarativo**: describís *qué* querés, no *cómo* llegar ahí.

   ```bash
   mkdir -p gitops-cnpa/apps/guestbook && cd gitops-cnpa
   git init -b main
   ```

2. Escribí un manifiesto declarativo completo en `apps/guestbook/deployment.yaml`:

   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: guestbook
     labels:
       app: guestbook
   spec:
     replicas: 3
     selector:
       matchLabels:
         app: guestbook
     template:
       metadata:
         labels:
           app: guestbook
       spec:
         containers:
           - name: guestbook
             image: gcr.io/google-samples/gb-frontend:v5
             ports:
               - containerPort: 80
   ```

3. Versioná el estado. Cada commit es un punto **inmutable y auditable** al que podés volver:

   ```bash
   git add apps/guestbook/deployment.yaml
   git commit -m "guestbook: 3 replicas"
   git log --oneline
   ```

   Salida esperada (el SHA será distinto en tu máquina):

   ```
   a1b2c3d guestbook: 3 replicas
   ```

4. Simulá un cambio de estado deseado y observá que el historial preserva ambas versiones:

   ```bash
   sed -i 's/replicas: 3/replicas: 5/' apps/guestbook/deployment.yaml
   git commit -am "guestbook: scale to 5 replicas"
   git log --oneline
   ```

   ```
   e4f5g6h guestbook: scale to 5 replicas
   a1b2c3d guestbook: 3 replicas
   ```

5. Subí el repositorio a tu remoto (reemplazá `<tu-usuario>`):

   ```bash
   git remote add origin https://github.com/<tu-usuario>/gitops-cnpa.git
   git push -u origin main
   ```

**Preguntas de verificación (bloque 1)**

1. ¿Cuáles son los cuatro principios de OpenGitOps y a qué se refiere cada uno con una frase?
2. En este ejercicio, ¿dónde vive el *desired state* y dónde el *actual state*? ¿Cuál de los dos es la fuente de verdad (*source of truth*)?
3. El principio "Versioned and Immutable" no dice que edites el manifiesto en el cluster con `kubectl edit`. ¿Por qué ese `kubectl edit` violaría el modelo GitOps aunque el YAML resultante sea válido?
4. Todavía no instalaste ningún agente. ¿Qué dos de los cuatro principios **aún no** se cumplen con lo hecho hasta acá?

---

## Ejercicio 2 — Pulled Automatically: reconciliación pull-based con Argo CD

Objetivo: instalar un agente que **tira** (pull) el estado desde Git y lo aplica, en contraposición al modelo push clásico de un pipeline de CI que ejecuta `kubectl apply`.

### Pasos

1. Instalá Argo CD en el cluster:

   ```bash
   kubectl create namespace argocd
   kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
   kubectl -n argocd rollout status deploy/argocd-server
   ```

   Salida esperada:

   ```
   deployment "argocd-server" successfully rolled out
   ```

2. Definí una `Application` que declara *qué repo, qué path y a qué cluster/namespace* debe converger. Guardala como `application.yaml`:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: guestbook
     namespace: argocd
   spec:
     project: default
     source:
       repoURL: https://github.com/<tu-usuario>/gitops-cnpa.git
       targetRevision: main
       path: apps/guestbook
     destination:
       server: https://kubernetes.default.svc
       namespace: guestbook
     syncPolicy:
       automated:
         prune: true
         selfHeal: true
       syncOptions:
         - CreateNamespace=true
   ```

3. Aplicá la `Application`. Notá que este es el **único** `kubectl apply` manual: a partir de acá, el agente reconcilia solo.

   ```bash
   kubectl apply -f application.yaml
   ```

4. Observá cómo Argo CD detecta el estado deseado y converge:

   ```bash
   kubectl -n argocd get applications
   ```

   Salida esperada tras unos segundos:

   ```
   NAME        SYNC STATUS   HEALTH STATUS
   guestbook   Synced        Healthy
   ```

5. Verificá que los 5 replicas del commit más reciente existen realmente en el cluster:

   ```bash
   kubectl -n guestbook get deploy guestbook
   ```

   ```
   NAME        READY   UP-TO-DATE   AVAILABLE   AGE
   guestbook   5/5     5            5           40s
   ```

**Preguntas de verificación (bloque 2)**

1. Explicá la diferencia entre un modelo **push-based** (CI ejecuta `kubectl apply`) y **pull-based** (Argo CD/Flux). Nombrá una ventaja de seguridad del pull-based respecto de las credenciales del cluster.
2. En la `Application`, ¿qué representa `spec.source.targetRevision` y qué pasaría si lo fijaras a un tag inmutable como `v1.4.2` en lugar de `main`?
3. `SYNC STATUS: Synced` y `HEALTH STATUS: Healthy` responden preguntas distintas. ¿Qué mide cada uno?
4. Con `automated.selfHeal` y `automated.prune` activados, ¿qué hará Argo CD si (a) alguien crea un recurso a mano en el namespace que no está en Git, y (b) alguien borra el `deployment.yaml` del repo?

---

## Ejercicio 3 — Continuously Reconciled: drift detection y self-heal

Objetivo: comprobar empíricamente el principio de reconciliación continua provocando *drift* (deriva) entre cluster y Git, y observar la corrección automática.

### Pasos

1. Provocá drift imperativo: escalá el Deployment por fuera de Git.

   ```bash
   kubectl -n guestbook scale deploy guestbook --replicas=1
   kubectl -n guestbook get deploy guestbook
   ```

   ```
   NAME        READY   UP-TO-DATE   AVAILABLE   AGE
   guestbook   1/1     1            1           3m
   ```

2. Consultá el estado de la `Application` inmediatamente. Con `selfHeal` activo, la ventana de OutOfSync es breve:

   ```bash
   kubectl -n argocd get application guestbook -o jsonpath='{.status.sync.status}{"\n"}'
   ```

   Puede que veas fugazmente:

   ```
   OutOfSync
   ```

3. Esperá el próximo ciclo de reconciliación y volvé a mirar el Deployment:

   ```bash
   sleep 15
   kubectl -n guestbook get deploy guestbook
   ```

   ```
   NAME        READY   UP-TO-DATE   AVAILABLE   AGE
   guestbook   5/5     5            5           4m
   ```

   El cluster volvió a **5** replicas: el `actual state` fue arrastrado de nuevo al `desired state` de Git, sin intervención humana.

4. Ahora hacé el cambio "bien", por el canal correcto — un commit:

   ```bash
   sed -i 's/replicas: 5/replicas: 4/' apps/guestbook/deployment.yaml
   git commit -am "guestbook: scale to 4 replicas"
   git push
   ```

5. Forzá una reconciliación inmediata en vez de esperar el poll (por defecto Argo CD sondea Git cada ~3 min):

   ```bash
   kubectl -n argocd patch application guestbook --type merge \
     -p '{"operation":{"sync":{"revision":"main"}}}'
   sleep 10
   kubectl -n guestbook get deploy guestbook
   ```

   ```
   NAME        READY   UP-TO-DATE   AVAILABLE   AGE
   guestbook   4/4     4            4           6m
   ```

**Preguntas de verificación (bloque 3)**

1. En el paso 1 escalaste a 1 replica y el sistema volvió solo a 5; en el paso 4 escalaste a 4 y el sistema *aceptó* el cambio. ¿Cuál es la diferencia esencial entre ambos cambios y por qué GitOps trata uno como "drift a corregir" y el otro como "nuevo estado deseado"?
2. Definí *reconciliation loop* (bucle de reconciliación) y describí sus tres pasos conceptuales (observar, comparar/diff, actuar).
3. ¿Qué habría pasado en el paso 3 si `selfHeal` estuviera en `false`? ¿La `Application` habría quedado en `Synced` o en `OutOfSync`, y qué haría falta para reconciliar?
4. ¿Por qué un webhook desde el proveedor Git hacia Argo CD/Flux mejora la experiencia frente al polling por intervalo? ¿Elimina la necesidad del intervalo por completo?

---

## Ejercicio 4 — Estrategias de Continuous Delivery: rolling, blue-green y canary

Objetivo: relacionar los **conceptos de Continuous Delivery** (progressive delivery, reducción del blast radius) con los mecanismos concretos de despliegue.

### Pasos

1. Inspeccioná la estrategia por defecto de un Deployment de Kubernetes:

   ```bash
   kubectl -n guestbook get deploy guestbook -o jsonpath='{.spec.strategy}{"\n"}'
   ```

   ```
   {"rollingUpdate":{"maxSurge":"25%","maxUnavailable":"25%"},"type":"RollingUpdate"}
   ```

2. Hacé explícita la estrategia RollingUpdate afinando los parámetros en el manifiesto de Git (`apps/guestbook/deployment.yaml`), y agregá una `readinessProbe` para que el rollout respete la disponibilidad real:

   ```yaml
   spec:
     strategy:
       type: RollingUpdate
       rollingUpdate:
         maxSurge: 1
         maxUnavailable: 0
     template:
       spec:
         containers:
           - name: guestbook
             image: gcr.io/google-samples/gb-frontend:v5
             readinessProbe:
               httpGet:
                 path: /
                 port: 80
               initialDelaySeconds: 5
               periodSeconds: 5
   ```

   > `maxUnavailable: 0` garantiza que nunca baje la capacidad durante el update; `maxSurge: 1` permite un Pod extra temporal.

3. Para **canary** y **blue-green** reales, el Deployment nativo no alcanza: se usa un controlador de *progressive delivery*. Instalá Argo Rollouts:

   ```bash
   kubectl create namespace argo-rollouts
   kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
   ```

4. Declará un **canary** que promueve el tráfico por pasos con pausas (guardá como `apps/web/rollout.yaml`):

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Rollout
   metadata:
     name: web
   spec:
     replicas: 5
     selector:
       matchLabels:
         app: web
     template:
       metadata:
         labels:
           app: web
       spec:
         containers:
           - name: web
             image: argoproj/rollouts-demo:blue
             ports:
               - containerPort: 8080
     strategy:
       canary:
         steps:
           - setWeight: 20
           - pause: { duration: 60s }
           - setWeight: 50
           - pause: { duration: 60s }
           - setWeight: 100
   ```

5. Aplicá el Rollout, disparás una nueva versión y observás la promoción por pasos:

   ```bash
   kubectl apply -f apps/web/rollout.yaml
   kubectl argo rollouts set image web web=argoproj/rollouts-demo:yellow
   kubectl argo rollouts get rollout web --watch
   ```

   Salida esperada (recortada) durante la fase canary al 20 %:

   ```
   Name:            web
   Status:          ॥ Paused
   Strategy:        Canary
     Step:          1/5
     SetWeight:     20
     ActualWeight:  20
   Images:          argoproj/rollouts-demo:blue (stable)
                    argoproj/rollouts-demo:yellow (canary)
   Replicas:
     Desired:       5
     Updated:       1
     Ready:         5
     Available:     5
   ```

**Preguntas de verificación (bloque 4)**

1. Diferenciá **Continuous Delivery** de **Continuous Deployment**. ¿En cuál hay un gate/aprobación antes de producción?
2. Con `maxUnavailable: 0` y `maxSurge: 1`, describí qué le pasa a la cuenta de Pods durante un update de una versión a otra. ¿Por qué esta combinación es la más conservadora para disponibilidad?
3. Definí **blue-green** y **canary** y decí cuál de las dos: (a) mantiene dos entornos completos y cambia el tráfico de golpe, (b) desplaza el tráfico gradualmente hacia la versión nueva conviviendo con la vieja.
4. ¿Qué es **progressive delivery** y cómo se relaciona con el `pause` del Rollout? ¿Qué agregarías al canary para que la promoción entre pasos sea automática y basada en métricas en lugar de por tiempo?

---

## Ejercicio 5 — Flux CD: separar *source* de *reconciliation* y controlar el intervalo

Objetivo: implementar el mismo modelo pull-based con **Flux** para ver que los principios de GitOps son independientes de la herramienta, y entender la separación entre la fuente (`GitRepository`) y su aplicación (`Kustomization`).

### Pasos

1. Instalá el CLI y comprobá que el cluster cumple los requisitos:

   ```bash
   curl -s https://fluxcd.io/install.sh | sudo bash
   flux check --pre
   ```

   Salida esperada (recortada):

   ```
   ► checking prerequisites
   ✔ Kubernetes 1.29.0 >=1.28.0-0
   ✔ prerequisites checks passed
   ```

2. Instalá los controladores de Flux en el cluster (equivalente mínimo a `flux bootstrap`, sin escribir de vuelta al repo):

   ```bash
   flux install
   ```

3. Declará la **fuente** — de dónde y cada cuánto se sondea Git — como `GitRepository`, y la **reconciliación** — qué path aplicar — como `Kustomization`. Notá los dos `interval` distintos:

   ```yaml
   apiVersion: source.toolkit.fluxcd.io/v1
   kind: GitRepository
   metadata:
     name: gitops-cnpa
     namespace: flux-system
   spec:
     interval: 1m
     url: https://github.com/<tu-usuario>/gitops-cnpa.git
     ref:
       branch: main
   ---
   apiVersion: kustomize.toolkit.fluxcd.io/v1
   kind: Kustomization
   metadata:
     name: guestbook
     namespace: flux-system
   spec:
     interval: 10m
     sourceRef:
       kind: GitRepository
       name: gitops-cnpa
     path: ./apps/guestbook
     prune: true
     targetNamespace: guestbook
   ```

   > **Importante:** desplegá esto en un cluster *distinto* del ejercicio 2, o Argo CD y Flux se pelearán reconciliando el mismo namespace.

4. Aplicá y verificá el estado de source y de la reconciliación por separado:

   ```bash
   kubectl apply -f flux-guestbook.yaml
   flux get sources git
   flux get kustomizations
   ```

   Salida esperada:

   ```
   NAME          REVISION           SUSPENDED  READY  MESSAGE
   gitops-cnpa   main@sha1:e4f5g6h  False      True   stored artifact for revision 'main@sha1:e4f5g6h'

   NAME        REVISION           SUSPENDED  READY  MESSAGE
   guestbook   main@sha1:e4f5g6h  False      True   Applied revision: main@sha1:e4f5g6h
   ```

5. Forzá una reconciliación inmediata sin esperar el `interval` de 10 m:

   ```bash
   flux reconcile kustomization guestbook --with-source
   ```

   ```
   ► annotating GitRepository gitops-cnpa in flux-system namespace
   ✔ GitRepository annotated
   ◎ waiting for GitRepository reconciliation
   ✔ fetched revision main@sha1:e4f5g6h
   ✔ applied revision main@sha1:e4f5g6h
   ```

**Preguntas de verificación (bloque 5)**

1. ¿Por qué Flux separa `GitRepository` (source-controller) de `Kustomization` (kustomize-controller)? Dá un caso donde varias `Kustomization` compartan un mismo `GitRepository`.
2. El `GitRepository` tiene `interval: 1m` y la `Kustomization` `interval: 10m`. ¿Qué controla cada intervalo y por qué tiene sentido que el de source sea más corto?
3. ¿Qué hace `prune: true` en la `Kustomization` y a qué campo de Argo CD equivale? ¿Qué riesgo introduce si borrás un archivo por error?
4. Argo CD y Flux implementan los mismos cuatro principios de OpenGitOps. Nombrá el componente de cada uno que cumple el principio **Continuously Reconciled**.

---

<details>
<summary><strong>Respuestas</strong></summary>

### Bloque 1

1. Los cuatro principios de **OpenGitOps v1.0.0** (https://opengitops.dev/):
   - **Declarative:** el sistema entero se describe declarativamente (el *qué*, no el *cómo*).
   - **Versioned and Immutable:** el estado deseado se guarda versionado, de forma inmutable y con historial completo (Git); cada versión es un punto al que se puede volver.
   - **Pulled Automatically:** agentes de software *tiran* automáticamente el estado deseado desde el store.
   - **Continuously Reconciled:** esos agentes observan el estado real y lo reconcilian de forma continua contra el deseado.
2. El *desired state* vive en **Git** (los manifiestos versionados); el *actual state* vive en el **cluster** (los objetos vivos de Kubernetes). La **fuente de verdad es Git**.
3. Un `kubectl edit` cambia el `actual state` sin dejar rastro en Git: rompe la trazabilidad y la inmutabilidad (no hay commit, no hay revisión a la que volver, no hay review), y además ese cambio será tratado como drift y revertido por el agente. El cambio válido es siempre un commit.
4. Faltan **Pulled Automatically** y **Continuously Reconciled**: sin un agente instalado, nadie tira el estado ni reconcilia; el repo por sí solo solo satisface *Declarative* y *Versioned and Immutable*.

### Bloque 2

1. **Push-based:** un pipeline de CI, fuera del cluster, ejecuta `kubectl apply`/`helm upgrade` contra la API. **Pull-based:** un agente *dentro* del cluster tira el estado desde Git y lo aplica. Ventaja de seguridad: en pull-based las **credenciales del cluster nunca salen del cluster** — el CI no necesita `kubeconfig` con permisos de admin, con lo que se reduce la superficie de ataque y no hay secretos de cluster en el runner de CI.
2. `targetRevision` es la revisión de Git a la que converger (branch, tag o SHA). Fijarlo a un **tag inmutable** `v1.4.2` hace el despliegue reproducible y auditable: la `Application` no se moverá aunque `main` avance, y un rollback es cambiar el tag; el trade-off es que perdés la promoción automática al hacer push a la branch.
3. **Sync status** compara *Git vs cluster*: ¿el estado aplicado coincide con la revisión deseada? (`Synced`/`OutOfSync`). **Health status** evalúa el estado operativo *del recurso en sí*: ¿está sano y disponible? (`Healthy`/`Progressing`/`Degraded`/`Missing`). Un recurso puede estar `Synced` pero `Degraded` (aplicaste lo correcto, pero el Pod crashea).
4. (a) Con `prune`, un recurso que existe en el cluster pero **no** en Git se considera basura y se **elimina** en la reconciliación. (b) Si borrás el `deployment.yaml` del repo, `prune: true` hará que Argo CD **borre el Deployment** del cluster (Git es la fuente de verdad; lo que no está en Git no debe existir). `selfHeal` además revierte modificaciones in-cluster de recursos que sí están en Git.

### Bloque 3

1. El escalado a 1 se hizo **imperativamente contra el cluster** (no está en Git) → es *drift* respecto de la fuente de verdad, y el agente lo corrige. El escalado a 4 se hizo **con un commit a Git** → cambia el propio estado deseado, así que el agente converge *hacia* él. La regla: el cluster nunca es autoridad; solo Git redefine "lo correcto".
2. Un **reconciliation loop** es el bucle continuo que un controlador ejecuta para hacer converger `actual state` → `desired state`. Sus tres pasos: **observar** el estado real del cluster, **comparar/diff** contra el estado deseado (Git), y **actuar** aplicando las diferencias hasta eliminar la deriva; luego repite indefinidamente.
3. Con `selfHeal: false`, Argo CD **detecta** el drift y marca la `Application` como **`OutOfSync`**, pero **no** lo corrige automáticamente: quedaría en 1 replica hasta un sync manual (`argocd app sync guestbook`) o hasta que un cambio en Git dispare una nueva sync. `selfHeal` es lo que convierte "detección" en "corrección automática".
4. Un **webhook** notifica *push a push* (evento) en lugar de esperar al próximo poll, reduciendo la latencia de reconciliación de minutos a segundos. **No elimina el intervalo:** el polling sigue siendo la red de seguridad ante webhooks perdidos y, sobre todo, la reconciliación por intervalo es la que corrige el *drift in-cluster*, que no genera ningún evento en Git.

### Bloque 4

1. **Continuous Delivery:** cada cambio que pasa CI queda *listo* para producción, pero un **gate/aprobación manual** decide el release. **Continuous Deployment:** cada cambio que pasa CI se despliega a producción **sin intervención humana**. El gate está en Continuous *Delivery*.
2. Con `maxUnavailable: 0` y `maxSurge: 1`: Kubernetes primero **crea 1 Pod nuevo** (surge), espera a que pase la `readinessProbe`, y recién entonces **elimina 1 viejo**, repitiendo Pod por Pod. La capacidad disponible **nunca baja** del número deseado (a lo sumo sube en 1). Es la más conservadora porque prioriza disponibilidad total a costa de un rollout más lento y un Pod extra de recursos.
3. **Blue-green (a):** mantiene dos entornos completos (blue = actual, green = nuevo); se prueba green y el tráfico se **conmuta de golpe** (y se puede volver instantáneamente). **Canary (b):** la versión nueva convive con la vieja y el tráfico se **desplaza gradualmente** (20 % → 50 % → 100 %), limitando el *blast radius* si la versión nueva falla.
4. **Progressive delivery** es la extensión de CD que libera gradualmente y **con verificación entre pasos**, acotando el riesgo. El `pause` del Rollout es el punto de verificación entre incrementos de peso. Para que la promoción sea automática y basada en métricas se agrega un **`AnalysisTemplate`/`AnalysisRun`** (p. ej. consultando Prometheus): si la tasa de error/latencia del canary supera un umbral, el Rollout **aborta y hace rollback** solo; si está sana, promueve al paso siguiente sin esperar tiempo fijo.

### Bloque 5

1. Se separan por **responsabilidad y reutilización**: `GitRepository` (source-controller) solo se ocupa de *obtener y versionar el artefacto* del repo; `Kustomization` (kustomize-controller) se ocupa de *build + apply + prune* de un path. Caso típico: un único `GitRepository` (monorepo) alimenta **varias `Kustomization`** — una por app o por entorno (`./apps/frontend`, `./apps/backend`, `./clusters/prod`) — cada una con su propio intervalo y su propio `prune`.
2. El `interval` del **`GitRepository`** controla cada cuánto se *sondea Git* para traer una revisión nueva (aquí 1 m). El de la **`Kustomization`** controla cada cuánto se *reconcilia el cluster* contra el último artefacto (aquí 10 m). Tiene sentido que source sea más corto para enterarse rápido de commits nuevos; pero incluso sin commits, el intervalo de la `Kustomization` es el que corrige drift in-cluster.
3. `prune: true` **elimina del cluster** los objetos que Flux gestionó y que ya **no están en el source** (garbage collection). Equivale a `syncPolicy.automated.prune` en Argo CD. Riesgo: si borrás un archivo por error y hacés push, la próxima reconciliación **borra ese recurso en producción** — por eso prune se combina con review de PRs y, cuando conviene, con `suspend`/health checks.
4. El principio **Continuously Reconciled** lo cumple: en **Argo CD**, el `application-controller` (con su reconciliation loop y `selfHeal`); en **Flux**, los *reconcilers* de sus controladores — principalmente el **kustomize-controller** (y helm-controller), alimentados por el **source-controller**.

</details>