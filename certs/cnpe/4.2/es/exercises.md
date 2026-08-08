# Ejercicios Guiados — Tema 4.2: Building and Configuring CI/CD Pipelines Integrated with Kubernetes

> **Prerrequisitos.** Un cluster de Kubernetes funcional (`kind`, `minikube` o un cluster real), `kubectl` ≥ 1.28 configurado contra ese cluster, `git`, y acceso a un registry de contenedores (puede ser local con `kind`). Los ejercicios usan proyectos CNCF: **Tekton Pipelines** (CI in-cluster), **Argo CD** (GitOps/CD) y **Argo Rollouts** (progressive delivery). Trabajás sobre un namespace dedicado por ejercicio para poder limpiar sin efectos colaterales.
>
> Cada bloque termina con preguntas de verificación. Las respuestas están al final, en la sección colapsable.

---

## Ejercicio 1 — CI in-cluster con Tekton: de `git clone` a imagen publicada

El objetivo es entender por qué en Cloud Native el pipeline de CI corre *dentro* del cluster como cargas de trabajo efímeras, y cómo se modela un pipeline con recursos declarativos (`Task`, `Pipeline`, `PipelineRun`).

### Pasos

1. Creá el namespace y verificá que el cluster responde:

   ```bash
   kubectl create namespace ci
   kubectl config set-context --current --namespace=ci
   kubectl version --output=json | jq '.serverVersion.gitVersion'
   ```

2. Instalá Tekton Pipelines (componente de CI de la Continuous Delivery Foundation, incubado en CNCF landscape):

   ```bash
   kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
   kubectl -n tekton-pipelines rollout status deployment/tekton-pipelines-controller --timeout=180s
   kubectl -n tekton-pipelines rollout status deployment/tekton-pipelines-webhook   --timeout=180s
   ```

3. Inspeccioná los CRDs que Tekton registró. Estos son el "vocabulario" del pipeline:

   ```bash
   kubectl api-resources --api-group=tekton.dev
   ```

   Salida esperada (abreviada):

   ```
   NAME               SHORTNAMES   APIVERSION            NAMESPACED   KIND
   clustertasks                    tekton.dev/v1beta1    false        ClusterTask
   pipelineruns       pr,prs       tekton.dev/v1         true         PipelineRun
   pipelines                       tekton.dev/v1         true         Pipeline
   taskruns           tr,trs       tekton.dev/v1         true         TaskRun
   tasks                           tekton.dev/v1         true         Task
   ```

4. Definí una `Task` que clona un repositorio. Fijate en el `workspace`: es el mecanismo de Tekton para compartir un volumen entre `steps` y entre `Tasks`.

   ```yaml
   # task-git-clone.yaml
   apiVersion: tekton.dev/v1
   kind: Task
   metadata:
     name: git-clone
   spec:
     params:
       - name: url
         type: string
       - name: revision
         type: string
         default: main
     workspaces:
       - name: source
         description: El working tree clonado se deja acá
     steps:
       - name: clone
         image: alpine/git:2.43.0
         script: |
           #!/bin/sh
           set -eu
           git clone --depth 1 --branch "$(params.revision)" \
             "$(params.url)" "$(workspaces.source.path)/repo"
           echo "HEAD: $(git -C "$(workspaces.source.path)/repo" rev-parse HEAD)"
   ```

   ```bash
   kubectl apply -f task-git-clone.yaml
   ```

5. Definí una segunda `Task` que construye y publica la imagen con **Kaniko**. Kaniko construye imágenes OCI *sin* un daemon de Docker y *sin* privilegios de root sobre el nodo — clave en un cluster multi-tenant donde montar `/var/run/docker.sock` sería inaceptable.

   ```yaml
   # task-kaniko-build.yaml
   apiVersion: tekton.dev/v1
   kind: Task
   metadata:
     name: kaniko-build
   spec:
     params:
       - name: image
         type: string
     workspaces:
       - name: source
     steps:
       - name: build-and-push
         image: gcr.io/kaniko-project/executor:v1.20.0
         args:
           - --context=$(workspaces.source.path)/repo
           - --dockerfile=$(workspaces.source.path)/repo/Dockerfile
           - --destination=$(params.image)
           - --cache=true
   ```

   ```bash
   kubectl apply -f task-kaniko-build.yaml
   ```

6. Componé ambas `Tasks` en un `Pipeline`. El campo `runAfter` establece el orden explícito; sin él, Tekton intentaría paralelizar.

   ```yaml
   # pipeline-ci.yaml
   apiVersion: tekton.dev/v1
   kind: Pipeline
   metadata:
     name: build-app
   spec:
     params:
       - name: repo-url
       - name: image-ref
     workspaces:
       - name: shared-data
     tasks:
       - name: fetch
         taskRef:
           name: git-clone
         params:
           - name: url
             value: $(params.repo-url)
         workspaces:
           - name: source
             workspace: shared-data
       - name: build
         runAfter: ["fetch"]
         taskRef:
           name: kaniko-build
         params:
           - name: image
             value: $(params.image-ref)
         workspaces:
           - name: source
             workspace: shared-data
   ```

   ```bash
   kubectl apply -f pipeline-ci.yaml
   ```

7. Ejecutá el `Pipeline` disparando un `PipelineRun`. El `PipelineRun` es la *instancia de ejecución* — el `Pipeline` es la plantilla reutilizable. Fijate cómo el `workspace` se materializa como un `PersistentVolumeClaim` efímero (`volumeClaimTemplate`):

   ```yaml
   # pipelinerun-ci.yaml
   apiVersion: tekton.dev/v1
   kind: PipelineRun
   metadata:
     generateName: build-app-run-
   spec:
     pipelineRef:
       name: build-app
     params:
       - name: repo-url
         value: https://github.com/tektoncd/catalog
       - name: image-ref
         value: registry.ci.svc.cluster.local:5000/demo:$(context.pipelineRun.uid)
     workspaces:
       - name: shared-data
         volumeClaimTemplate:
           spec:
             accessModes: ["ReadWriteOnce"]
             resources:
               requests:
                 storage: 1Gi
   ```

   ```bash
   kubectl create -f pipelinerun-ci.yaml
   ```

8. Observá la ejecución en tiempo real. Cada `Task` corre como un `Pod`; cada `step` es un contenedor dentro de ese `Pod`:

   ```bash
   kubectl get pipelineruns -w
   # En otra terminal:
   kubectl get taskruns
   kubectl get pods -l tekton.dev/pipelineRun --show-labels
   ```

   Salida esperada de `get pipelineruns` al finalizar:

   ```
   NAME                  SUCCEEDED   REASON      STARTTIME   COMPLETIONTIME
   build-app-run-abc12   True        Succeeded   2m          30s
   ```

**Preguntas de verificación — Bloque 1**

1. ¿Por qué un `PipelineRun` y no simplemente ejecutar el `Pipeline`? ¿Qué relación conceptual tienen, y cómo se traduce eso a cargas de trabajo de Kubernetes (Pods, containers)?
2. Kaniko no usa un Docker daemon. Explicá qué problema de seguridad concreto resuelve eso en un cluster compartido, y qué implicaría la alternativa de montar `/var/run/docker.sock`.
3. Un `workspace` respaldado por `volumeClaimTemplate` genera un `PVC` nuevo por cada `PipelineRun`. ¿Qué ventaja de aislamiento da esto frente a un `PVC` fijo compartido, y qué trade-off de performance introduce?
4. Si quitás el `runAfter: ["fetch"]` de la task `build`, ¿qué haría Tekton y por qué el pipeline fallaría?

---

## Ejercicio 2 — CD por GitOps con Argo CD: el cluster converge hacia Git

El modelo push (el pipeline hace `kubectl apply`) y el modelo pull/GitOps (un controlador *reconcilia* el cluster contra un repositorio) tienen propiedades de seguridad y auditoría muy distintas. Acá montás el modelo pull.

### Pasos

1. Instalá Argo CD:

   ```bash
   kubectl create namespace argocd
   kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
   kubectl -n argocd rollout status deployment/argocd-server --timeout=300s
   ```

2. Recuperá la contraseña inicial del usuario `admin` (Argo CD la genera y la guarda en un `Secret`):

   ```bash
   kubectl -n argocd get secret argocd-initial-admin-secret \
     -o jsonpath='{.data.password}' | base64 -d; echo
   ```

3. Exponé la UI/API localmente y logueate con la CLI:

   ```bash
   kubectl -n argocd port-forward svc/argocd-server 8080:443 >/tmp/pf.log 2>&1 &
   argocd login localhost:8080 --username admin \
     --password "<pega-la-contraseña>" --insecure
   ```

4. Registrá una `Application`. Este objeto declarativo es el corazón de Argo CD: dice *qué repo/path* es la fuente de verdad y *a qué cluster/namespace* debe converger.

   ```yaml
   # app-guestbook.yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: guestbook
     namespace: argocd
   spec:
     project: default
     source:
       repoURL: https://github.com/argoproj/argocd-example-apps.git
       targetRevision: HEAD
       path: guestbook
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

   ```bash
   kubectl apply -f app-guestbook.yaml
   ```

5. Observá la reconciliación y el estado de salud/sync:

   ```bash
   argocd app get guestbook
   kubectl -n guestbook get deploy,svc,pods
   ```

   Salida esperada de `argocd app get` (abreviada):

   ```
   Name:               argocd/guestbook
   Health Status:      Healthy
   Sync Status:        Synced to HEAD (53e28ff)
   ```

6. **Demostrá `selfHeal`**. Introducí drift manual y observá cómo Argo CD lo revierte porque el estado real difiere de Git:

   ```bash
   kubectl -n guestbook scale deployment guestbook-ui --replicas=5
   # Esperá unos segundos y volvé a mirar:
   kubectl -n guestbook get deployment guestbook-ui -o jsonpath='{.spec.replicas}'; echo
   argocd app get guestbook --refresh
   ```

7. **Demostrá `prune`**. Un recurso que existe en el cluster pero ya *no* está en Git es basura para GitOps. Creá uno "huérfano" con la label de tracking y forzá un sync:

   ```bash
   kubectl -n guestbook create configmap orphan --from-literal=x=y
   kubectl -n guestbook label configmap orphan \
     app.kubernetes.io/instance=guestbook
   argocd app sync guestbook --prune
   kubectl -n guestbook get configmap orphan   # debería no existir
   ```

**Preguntas de verificación — Bloque 2**

1. Contrastá push vs. pull para CD. Nombrá **dos** ventajas concretas del modelo pull de GitOps en términos de credenciales del cluster y de superficie de ataque del pipeline de CI.
2. `selfHeal: true` revirtió tu `scale` manual. Describí un escenario operativo legítimo en el que `selfHeal` sea peligroso o indeseable, y cómo lo mitigarías.
3. ¿Qué hace exactamente `prune: true`? ¿Por qué Argo CD necesita una label/anotación de tracking (`app.kubernetes.io/instance` o la anotación de tracking) para poder podar con seguridad, en vez de borrar todo lo que "sobra" en el namespace?
4. La `Application` referencia `targetRevision: HEAD`. Desde el punto de vista de reproducibilidad y auditoría, ¿por qué en producción se prefiere fijar un tag inmutable o un SHA de commit?

---

## Ejercicio 3 — Cerrar el loop: CI actualiza el manifiesto, GitOps despliega

En un pipeline maduro, CI **no** hace `kubectl apply`. CI construye la imagen y luego escribe la nueva referencia de imagen en el repo de manifiestos; Argo CD detecta el commit y despliega. Acá modelás ese *image updater* con `kustomize`.

### Pasos

1. Preparate un repo de manifiestos con estructura Kustomize (podés hacerlo local para el ejercicio):

   ```bash
   mkdir -p ~/gitops-repo/app && cd ~/gitops-repo
   git init -q
   ```

   ```yaml
   # ~/gitops-repo/app/deployment.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web
   spec:
     replicas: 2
     selector:
       matchLabels: { app: web }
     template:
       metadata:
         labels: { app: web }
       spec:
         containers:
           - name: web
             image: registry.example.com/web:v1.0.0
   ```

   ```yaml
   # ~/gitops-repo/app/kustomization.yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - deployment.yaml
   images:
     - name: registry.example.com/web
       newTag: v1.0.0
   ```

   ```bash
   git add . && git commit -qm "initial manifests at v1.0.0"
   ```

2. Simulá el paso final de CI: la imagen `v1.1.0` ya fue construida y publicada, y ahora CI actualiza el tag *declarativamente* con `kustomize edit` (idempotente y sin `sed` frágil):

   ```bash
   cd ~/gitops-repo/app
   kustomize edit set image registry.example.com/web=registry.example.com/web:v1.1.0
   git -C ~/gitops-repo commit -aqm "ci: bump web to v1.1.0"
   ```

3. Verificá el render final que Argo CD aplicaría — es el mismo `kustomize build` que ejecuta el controlador:

   ```bash
   kustomize build ~/gitops-repo/app | grep -A1 'image:'
   ```

   Salida esperada:

   ```
           image: registry.example.com/web:v1.1.0
   ```

4. Discutí (no ejecutás) el disparo: en un setup real, este `git commit` proviene del `PipelineRun` del Ejercicio 1 mediante un step final `git-cli`, y Argo CD lo recoge en su próximo ciclo de reconciliación (por defecto ~3 min, o instantáneo vía webhook).

**Preguntas de verificación — Bloque 3**

1. ¿Por qué se prefiere `kustomize edit set image` sobre un `sed -i` en el YAML para actualizar el tag? Pensá en idempotencia y en qué pasa si el formato del YAML cambia.
2. En este patrón, ¿qué credencial *ya no* necesita tener el runner de CI, y por qué eso reduce el "blast radius" de un runner comprometido?
3. El repo de aplicación (código + Dockerfile) y el repo de manifiestos (GitOps) suelen estar **separados**. Dá una razón de auditoría/permisos y una razón de loops de reconciliación por la que se los mantiene aparte.

---

## Ejercicio 4 — Progressive delivery con Argo Rollouts: canary automatizado

Un `apply` de un nuevo tag reemplaza todos los Pods (rolling update). Progressive delivery introduce el nuevo release a una fracción del tráfico y **automatiza el rollback** según métricas. Acá usás `Rollout` con análisis.

### Pasos

1. Instalá Argo Rollouts:

   ```bash
   kubectl create namespace argo-rollouts
   kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
   kubectl -n argo-rollouts rollout status deployment/argo-rollouts --timeout=180s
   ```

2. Definí un `Rollout` (reemplaza al `Deployment`) con estrategia canary por pasos. `setWeight` mueve tráfico; `pause` espera (con o sin duración) antes de avanzar:

   ```yaml
   # rollout-web.yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Rollout
   metadata:
     name: web
     namespace: demo
   spec:
     replicas: 5
     selector:
       matchLabels: { app: web }
     template:
       metadata:
         labels: { app: web }
       spec:
         containers:
           - name: web
             image: argoproj/rollouts-demo:blue
             ports: [{ containerPort: 8080 }]
     strategy:
       canary:
         steps:
           - setWeight: 20
           - pause: { duration: 30s }
           - setWeight: 50
           - pause: {}            # pausa indefinida: requiere promoción manual
           - setWeight: 100
   ```

   ```bash
   kubectl create namespace demo
   kubectl apply -f rollout-web.yaml
   kubectl -n demo argo rollouts get rollout web --watch &
   ```

3. Dispará una actualización cambiando la imagen. Observá cómo el canary se detiene en el peso 20 %, luego 50 %, y **espera** en la pausa indefinida:

   ```bash
   kubectl -n demo argo rollouts set image web web=argoproj/rollouts-demo:yellow
   ```

   Salida esperada de `get rollout` (abreviada), detenido en el `pause: {}`:

   ```
   Name:            web
   Status:          ॥ Paused
   Strategy:        Canary
     Step:          3/5
     SetWeight:     50
   ```

4. Promové manualmente para superar la pausa indefinida:

   ```bash
   kubectl -n demo argo rollouts promote web
   ```

5. **Practicá un abort/rollback**. Iniciá otra actualización y abortala antes de completar: el tráfico vuelve al 100 % a la versión estable, casi instantáneo porque los Pods estables nunca se destruyeron:

   ```bash
   kubectl -n demo argo rollouts set image web web=argoproj/rollouts-demo:red
   kubectl -n demo argo rollouts abort web
   kubectl -n demo argo rollouts get rollout web
   ```

6. (Conceptual) Para automatizar el juicio, se asocia un `AnalysisTemplate` que consulta métricas (por ejemplo, error rate en Prometheus). Un ejemplo de la lógica de decisión:

   ```yaml
   # analysistemplate-success-rate.yaml
   apiVersion: argoproj.io/v1alpha1
   kind: AnalysisTemplate
   metadata:
     name: success-rate
   spec:
     args:
       - name: service
     metrics:
       - name: success-rate
         interval: 30s
         count: 5
         successCondition: result[0] >= 0.95
         failureLimit: 2
         provider:
           prometheus:
             address: http://prometheus.monitoring:9090
             query: |
               sum(rate(http_requests_total{service="{{args.service}}",code!~"5.."}[1m]))
               /
               sum(rate(http_requests_total{service="{{args.service}}"}[1m]))
   ```

   Referenciándolo desde el `Rollout` (bajo `strategy.canary.analysis`), un `success-rate` por debajo de 0.95 dos veces aborta el rollout **automáticamente**, sin intervención humana.

**Preguntas de verificación — Bloque 4**

1. Diferenciá `pause: { duration: 30s }` de `pause: {}`. ¿Qué comando desbloquea la segunda, y en qué se diferencia operativamente de la primera?
2. Cuando abortaste el rollout en el paso 5, el retorno a estable fue casi instantáneo. Explicá por qué, en términos de qué ReplicaSets/Pods mantiene Argo Rollouts vivos durante un canary.
3. En el `AnalysisTemplate`, ¿qué significan `successCondition: result[0] >= 0.95` y `failureLimit: 2` juntos? Describí la secuencia exacta que llevaría a un rollback automático.
4. Un canary por peso de tráfico necesita algo que *reparta* ese tráfico según el peso. ¿Qué componente de la infraestructura cumple ese rol (nombrá una categoría), y por qué el `Service` estándar de Kubernetes por sí solo no da control de peso fino?

---

## Ejercicio 5 — Endurecer el pipeline: secrets, quality gates y policy

Un pipeline de producción no es solo "build & deploy": incorpora escaneo de vulnerabilidades, gestión de secretos sin exponerlos en logs, y admission policies que bloquean lo que no cumple. Acá integrás esos gates.

### Pasos

1. Añadí un **quality gate** de escaneo de imágenes como `Task` de Tekton con Trivy, ubicada *entre* build y push (o post-push, antes de actualizar el manifiesto):

   ```yaml
   # task-trivy-scan.yaml
   apiVersion: tekton.dev/v1
   kind: Task
   metadata:
     name: trivy-scan
   spec:
     params:
       - name: image
       - name: severity
         default: "CRITICAL,HIGH"
     steps:
       - name: scan
         image: aquasec/trivy:0.50.0
         script: |
           #!/bin/sh
           set -eu
           trivy image --exit-code 1 \
             --severity "$(params.severity)" \
             --ignore-unfixed \
             "$(params.image)"
   ```

   ```bash
   kubectl apply -f task-trivy-scan.yaml
   ```

   El `--exit-code 1` es lo que convierte el escaneo en un *gate*: si hay CVEs CRITICAL/HIGH con fix disponible, el step falla y el `PipelineRun` se detiene.

2. Gestioná el secreto del registry sin filtrarlo. Creá un `Secret` de tipo `kubernetes.io/dockerconfigjson` y montalo vía `ServiceAccount`, de modo que Kaniko lo use sin que aparezca en el YAML del pipeline ni en logs:

   ```bash
   kubectl -n ci create secret docker-registry regcred \
     --docker-server=registry.example.com \
     --docker-username=ci-bot \
     --docker-password="$REG_TOKEN"

   kubectl -n ci patch serviceaccount default \
     -p '{"secrets":[{"name":"regcred"}]}'
   ```

3. Aplicá una **admission policy** que rechace imágenes con tag `:latest` (antipatrón: no reproducible). Usás las **Validating Admission Policies** nativas (CEL, GA desde Kubernetes 1.30):

   ```yaml
   # policy-no-latest.yaml
   apiVersion: admissionregistration.k8s.io/v1
   kind: ValidatingAdmissionPolicy
   metadata:
     name: no-latest-tag
   spec:
     failurePolicy: Fail
     matchConstraints:
       resourceRules:
         - apiGroups:   ["apps"]
           apiVersions: ["v1"]
           operations:  ["CREATE", "UPDATE"]
           resources:   ["deployments"]
     validations:
       - expression: >
           object.spec.template.spec.containers.all(c,
             !c.image.endsWith(":latest") && c.image.contains(":"))
         message: "Las imágenes deben usar un tag inmutable explícito, no ':latest' ni tag vacío"
   ```

   ```yaml
   # policy-binding.yaml
   apiVersion: admissionregistration.k8s.io/v1
   kind: ValidatingAdmissionPolicyBinding
   metadata:
     name: no-latest-tag-binding
   spec:
     policyName: no-latest-tag
     validationActions: ["Deny"]
     matchResources:
       namespaceSelector:
         matchLabels:
           policy-enforce: "true"
   ```

   ```bash
   kubectl apply -f policy-no-latest.yaml
   kubectl apply -f policy-binding.yaml
   kubectl label namespace demo policy-enforce=true
   ```

4. Probá que el gate de admisión funciona. Este `apply` debe ser **rechazado**:

   ```bash
   kubectl -n demo create deployment bad --image=nginx:latest
   ```

   Salida esperada:

   ```
   error: ... admission webhook denied the request:
   Las imágenes deben usar un tag inmutable explícito, no ':latest' ni tag vacío
   ```

5. Confirmá que una imagen con tag válido sí pasa:

   ```bash
   kubectl -n demo create deployment good --image=nginx:1.27.0
   kubectl -n demo get deploy good
   ```

**Preguntas de verificación — Bloque 5**

1. El `--exit-code 1` de Trivy es lo que hace que el escaneo sea un *gate* y no un *report*. Explicá la diferencia y por qué `--ignore-unfixed` es una decisión de política (no solo técnica).
2. Se montó `regcred` vía `ServiceAccount` en vez de ponerlo como variable en el YAML del pipeline. Nombrá **dos** formas concretas en que un secreto puesto inline se filtraría, y por qué el approach del `ServiceAccount` las evita.
3. La `ValidatingAdmissionPolicy` corre en el API server con CEL, sin webhook externo. ¿Qué ventaja de disponibilidad/latencia da eso frente a un `ValidatingWebhookConfiguration` que apunta a un pod externo (por ejemplo, un servicio de policy)?
4. La policy solo aplica a namespaces con la label `policy-enforce=true`. Explicá por qué en una adopción real se prefiere `validationActions: ["Audit", "Warn"]` primero, y recién después `["Deny"]`.

---

## Limpieza

```bash
kubectl delete namespace ci demo guestbook argocd argo-rollouts tekton-pipelines --ignore-not-found
kubectl delete validatingadmissionpolicy no-latest-tag --ignore-not-found
kubectl delete validatingadmissionpolicybinding no-latest-tag-binding --ignore-not-found
kubectl config set-context --current --namespace=default
```

---

<details>
<summary><strong>Respuestas — verificación de comprensión</strong></summary>

### Bloque 1 — Tekton / CI in-cluster

1. **`Pipeline` vs `PipelineRun`.** El `Pipeline` (y las `Task`) son *plantillas declarativas reutilizables* — definen el "qué" sin ejecutarse. El `PipelineRun` es una *instancia de ejecución* con parámetros concretos: es lo que provoca trabajo real. Al crear un `PipelineRun`, el controlador de Tekton genera un `TaskRun` por cada `Task`, y cada `TaskRun` se materializa como un **Pod**; cada `step` de la `Task` es un **container** dentro de ese Pod, ejecutados secuencialmente sobre el mismo volumen. Esto permite ejecutar el mismo pipeline muchas veces (por cada commit) con historial y parámetros distintos, sin mutar la definición.

2. **Kaniko sin daemon.** Construir con Docker requiere acceso al Docker daemon del nodo, típicamente montando `/var/run/docker.sock`. Ese socket es equivalente a **root en el nodo**: quien lo controla puede lanzar contenedores privilegiados, montar el filesystem del host y escapar del aislamiento — un vector de escalada de privilegios devastador en un cluster multi-tenant, donde el pipeline de CI ejecuta código (Dockerfiles) potencialmente no confiable. Kaniko construye la imagen enteramente en user-space dentro del contenedor, sin daemon y sin necesitar privilegios sobre el host, conteniendo el blast radius al propio Pod.

3. **`volumeClaimTemplate` por run.** Genera un `PVC` fresco y aislado por cada `PipelineRun`, así ejecuciones concurrentes no pisan el working tree de otras, no arrastran artefactos de builds previos (builds reproducibles, limpios) y no compiten por locks. El trade-off es de performance/costo: se aprovisiona y destruye almacenamiento en cada run (latencia de binding del PV, presión sobre el provisioner) y se pierde cualquier caché entre runs; un `PVC` fijo compartido sería más rápido y cacheable pero introduce acoplamiento y riesgo de contaminación cruzada.

4. **Sin `runAfter`.** Tekton, por defecto, ejecuta las `Task` de un `Pipeline` **en paralelo** salvo que exista una dependencia (por `runAfter` explícito o por un `result` que una task consume de otra). Sin `runAfter: ["fetch"]`, la task `build` (Kaniko) arrancaría al mismo tiempo que `fetch` (git-clone). Kaniko encontraría el workspace vacío — el código todavía no fue clonado — y fallaría porque no existe el `Dockerfile` ni el contexto de build.

### Bloque 2 — Argo CD / GitOps

1. **Push vs pull.** En push, el pipeline de CI tiene **credenciales del cluster** (kubeconfig con permisos de deploy) y las usa desde fuera; en pull/GitOps, un controlador *dentro* del cluster lee Git y aplica los cambios. Dos ventajas del pull: (a) **el runner de CI ya no necesita credenciales del cluster** — solo permiso de escritura en un repo Git — así un runner comprometido no puede tocar el cluster directamente; reduce la superficie de ataque del CI. (b) **Git es la única fuente de verdad y el registro de auditoría**: todo cambio de estado deseado pasa por un commit revisable, revertible y firmable, en vez de por `kubectl apply` imperativos que no dejan rastro estructurado.

2. **`selfHeal` peligroso.** Escenario legítimo: durante un **incidente** en el que operaciones necesita hacer un cambio de emergencia en caliente (escalar réplicas, editar un límite) más rápido de lo que se puede mergear un PR; `selfHeal` revertiría ese cambio en segundos, prolongando el incidente. También rompe cualquier autoscaling que mute `spec.replicas` (conflicto con HPA). Mitigación: excluir campos específicos de la comparación (`ignoreDifferences`, por ejemplo `spec.replicas`), deshabilitar temporalmente `selfHeal`/poner la app en modo manual durante la ventana de emergencia, o gestionar réplicas fuera de Git (HPA) y decirle a Argo que las ignore.

3. **`prune`.** `prune: true` borra del cluster los recursos que el controlador gestionaba pero que **ya no aparecen** en el estado deseado de Git (por ejemplo, eliminaste un manifiesto). Para hacerlo con seguridad, Argo CD marca cada recurso que crea con una **label/anotación de tracking** (`app.kubernetes.io/instance` o la tracking annotation configurable); solo poda lo que lleva su marca. Sin ese tracking, no podría distinguir "recurso obsoleto de esta app" de "recurso legítimo creado por otro controlador u otra app en el mismo namespace", y podar por presencia en el namespace destruiría cosas ajenas.

4. **`HEAD` vs SHA fijo.** `targetRevision: HEAD` sigue la punta de la rama: lo que se despliega cambia cada vez que alguien commitea, de forma no determinista respecto al estado que revisaste. Fijar un **tag inmutable o un SHA de commit** hace el deploy **reproducible y auditable**: sabés exactamente qué revisión está corriendo, podés reproducir el mismo estado meses después, y el rollback es "apuntá al SHA anterior". En producción esto es requisito de trazabilidad y de control de cambios.

### Bloque 3 — Loop CI→GitOps

1. **`kustomize edit` vs `sed`.** `kustomize edit set image` es **idempotente y consciente de la estructura**: entiende el modelo de datos de Kustomize (la lista `images:`), actualiza el `newTag` correcto y produce el mismo resultado si se corre dos veces. Un `sed -i` opera sobre texto crudo: es frágil ante cambios de formato (indentación, comillas, comentarios, múltiples ocurrencias de una cadena parecida), puede reemplazar coincidencias no deseadas y no garantiza idempotencia si el patrón ya no matchea tras un cambio previo.

2. **Credencial que desaparece.** El runner de CI ya **no necesita credenciales del cluster (kubeconfig con permiso de deploy)**; solo necesita permiso de escritura sobre el repo Git de manifiestos. Si el runner es comprometido, el atacante puede a lo sumo abrir un commit malicioso — que aún pasa por review, políticas de branch protection y la reconciliación de Argo — pero **no puede aplicar cambios arbitrarios directamente al cluster**. El blast radius se reduce de "control total del cluster" a "propuesta de cambio auditada".

3. **Repos separados.** (a) **Auditoría/permisos:** el repo de manifiestos tiene reglas de acceso, revisión y protección de ramas propias de "producción", distintas de las del repo de código donde muchos desarrolladores commitean libremente; separar evita que un push de código toque directamente el estado deseado del cluster. (b) **Loops de reconciliación:** si el bump de imagen se commitea en el mismo repo del código, cada actualización que hace CI dispara de nuevo el pipeline de CI (potencial bucle o builds redundantes) y mezcla el historial de "cambios de código" con el de "cambios de deploy"; separarlos mantiene el ciclo GitOps limpio y evita re-triggers.

### Bloque 4 — Argo Rollouts / progressive delivery

1. **`pause` con y sin duración.** `pause: { duration: 30s }` es una **pausa temporizada**: el rollout espera 30 s y avanza solo, automáticamente. `pause: {}` es una **pausa indefinida**: el rollout se detiene ahí hasta que un humano (o un sistema) lo promueva explícitamente con `kubectl argo rollouts promote <name>`. La primera sirve para dar tiempo a que las métricas se estabilicen sin intervención; la segunda es un *manual gate* — típicamente para aprobación humana antes de exponer más tráfico.

2. **Rollback casi instantáneo.** Durante un canary, Argo Rollouts **mantiene vivo el ReplicaSet estable** (la versión previa) con sus Pods corriendo, mientras levanta en paralelo el ReplicaSet canary con la nueva versión y va desplazando peso de tráfico. Al `abort`, no hay que reconstruir ni reprogramar nada: los Pods estables nunca se destruyeron, así que basta con volver el peso de tráfico al 100 % hacia el ReplicaSet estable y escalar a cero el canary. Es casi instantáneo porque es un cambio de enrutamiento, no un redeploy.

3. **`successCondition` + `failureLimit`.** `successCondition: result[0] >= 0.95` define que una medición individual es "exitosa" solo si la métrica (success rate) es ≥ 0.95. `failureLimit: 2` significa que el análisis tolera hasta 2 mediciones fallidas antes de declarar el análisis como fallido. Secuencia hacia rollback automático: el `AnalysisRun` consulta Prometheus cada `interval` (30 s); si en dos ocasiones el success rate cae por debajo de 0.95 (dos measurements que no cumplen la condición, superando `failureLimit: 2`), el `AnalysisRun` pasa a `Failed`, lo que hace que el `Rollout` **aborte automáticamente** y revierta al estable — sin intervención humana.

4. **Quién reparte el tráfico por peso.** Hace falta un componente de **traffic management**: un Ingress controller / service mesh capaz de weighted routing — por ejemplo, un ingress como NGINX o un mesh/proxy como Istio o Linkerd, o un gateway compatible con Gateway API. El `Service` estándar de Kubernetes reparte tráfico por **balanceo aproximadamente uniforme entre los endpoints** (los Pods listos detrás del selector); no puede asignar "20 % al canary" salvo manipulando la proporción de réplicas (grosero e impreciso). El control fino de peso vive en la capa de traffic routing, que Argo Rollouts programa a través de su integración con esos componentes.

### Bloque 5 — Endurecimiento

1. **Gate vs report.** Con `--exit-code 1`, Trivy termina con estado no-cero si encuentra vulnerabilidades de la severidad configurada, haciendo **fallar el step y detener el pipeline** — es un *gate*: bloquea la promoción. Sin él (`--exit-code 0`), Trivy solo imprime el reporte y el pipeline continúa — es un *report*: informa pero no impide. `--ignore-unfixed` es una **decisión de política**: elige no bloquear por CVEs que todavía no tienen fix disponible upstream (porque bloquear no aporta remediación posible y frena todos los deploys); es un trade-off consciente entre seguridad estricta y capacidad de entregar, no una limitación técnica.

2. **Secret inline se filtra.** Un secreto puesto directo en el YAML del pipeline se filtra al menos por: (a) queda **versionado en Git** en texto plano dentro del manifiesto del `Pipeline`/`Task`, visible para cualquiera con acceso al repo e imborrable del historial; (b) aparece en los **logs del `PipelineRun`/eventos/`describe`** si el step lo ecoa o si figura como env var en la spec del Pod (`kubectl get pod -o yaml` lo muestra). Montarlo vía `ServiceAccount` mantiene la credencial en un `Secret` de Kubernetes referenciado por nombre: no está en el YAML del pipeline ni en Git, y Kaniko lo consume desde el filesystem montado sin que su valor pase por los logs.

3. **VAP nativa vs webhook externo.** La `ValidatingAdmissionPolicy` se evalúa **dentro del propio API server** usando CEL, sin salto de red. Un `ValidatingWebhookConfiguration` obliga al API server a hacer una **llamada HTTP a un pod externo** en cada request de admisión: eso agrega latencia a *toda* operación que matchee, y crea una dependencia de disponibilidad — si el pod de policy está caído o lento y `failurePolicy: Fail`, se bloquean las admisiones (el propio servicio de policy podría no poder desplegarse). La VAP nativa no tiene ese hop de red ni ese punto único de falla: es más rápida y no puede quedar "colgada" esperando a un servicio externo.

4. **`Audit`/`Warn` antes de `Deny`.** Antes de bloquear (`Deny`), conviene correr la política en modo `Audit` (registra violaciones en el audit log / status) y `Warn` (devuelve una advertencia al usuario sin rechazar). Así se **mide el impacto real** sobre las cargas existentes: cuántos recursos ya desplegados o en pipelines la violarían. Pasar directo a `Deny` puede **bloquear deploys legítimos** o romper reconciliaciones de recursos preexistentes de golpe. La progresión Audit → Warn → Deny permite descubrir falsos positivos, avisar a los equipos y corregir manifiestos antes de que la política sea de cumplimiento obligatorio.

</details>

---

### Fuentes oficiales

- **CNPE Curriculum** — CNCF: https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- **Tekton Pipelines** (Tasks, Pipelines, PipelineRuns, Workspaces): https://tekton.dev/docs/pipelines/
- **Kaniko** (build de imágenes sin daemon): https://github.com/GoogleContainerTools/kaniko
- **Argo CD** (Application, sync policies, prune/selfHeal, tracking): https://argo-cd.readthedocs.io/en/stable/
- **Argo Rollouts** (canary, analysis, traffic management): https://argo-rollouts.readthedocs.io/en/stable/
- **Kustomize** (`edit set image`, images transformer): https://kubectl.docs.kubernetes.io/references/kustomize/
- **Validating Admission Policy** (CEL, GA en Kubernetes 1.30): https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- **Trivy** (image scanning, exit codes): https://aquasecurity.github.io/trivy/