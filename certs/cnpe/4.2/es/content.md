# Tema 4.2: Building and Configuring CI/CD Pipelines Integrated with Kubernetes

## 1. Motivación y el problema arquitectónico de producción

El desafío central de integrar CI/CD con Kubernetes no es "cómo ejecutar `kubectl apply` desde un runner". Ese es el error de diseño más costoso que comete una plataforma inmadura. El problema real es de **reconciliación de estado en un sistema distribuido** donde tres verdades compiten:

1. **El estado deseado declarado** (lo que dice Git).
2. **El estado renderizado** (lo que un pipeline produjo tras interpolar variables, tags de imagen y secrets).
3. **El estado observado** (lo que el `kube-apiserver` reporta como realidad en `etcd`, que a su vez difiere del estado *runtime* de los controllers).

### 1.1 Por qué el modelo `push` clásico se rompe en producción

El pipeline tradicional imperativo hace `push`: el runner de CI tiene credenciales de cluster y ejecuta `kubectl apply` o `helm upgrade` al final del build. Esto genera fallas sistémicas:

- **Deriva de configuración (drift) invisible.** Un operador ejecuta `kubectl edit deployment` para mitigar un incidente a las 3 AM. El pipeline no lo sabe. El próximo deploy sobrescribe la mitigación, o peor, un `apply` parcial deja el cluster en un estado que no existe en ningún commit. No hay una única fuente de verdad.

- **Superficie de ataque del credential.** El runner de CI necesita credenciales `cluster-admin` (o casi) para desplegar en cualquier namespace. Ese runner ejecuta código de terceros (dependencias de build, actions del marketplace). Un `postinstall` malicioso en `npm` roba el `kubeconfig` y tiene acceso directo al plano de control. Esta es la clase de ataque **CI-to-cluster lateral movement**.

- **Acoplamiento CI↔CD.** Si el deploy vive dentro del job de build, un rollback exige re-ejecutar el pipeline completo, recompilando artefactos que ya existían. El "tiempo de recuperación" (MTTR) se acopla al tiempo de build.

- **No hay auditoría del estado real.** "¿Qué versión está corriendo en producción?" no tiene respuesta autoritativa; hay que consultar el cluster vivo, que puede haber sido modificado fuera de banda.

### 1.2 La respuesta arquitectónica: separación CI/CD + modelo `pull` (GitOps)

La arquitectura de producción moderna separa dos planos con responsabilidades disjuntas:

```
┌─────────────────────────┐        ┌──────────────────────────┐
│   CONTINUOUS INTEGRATION │        │  CONTINUOUS DELIVERY (CD) │
│   (Tekton / GH Actions)  │        │   (Argo CD / Flux)        │
│                          │        │                           │
│  git push ──▶ test       │        │  reconcile loop           │
│           ──▶ build img  │        │   ┌────────────────────┐  │
│           ──▶ sign+SBOM  │        │   │ desired = git       │  │
│           ──▶ push image │        │   │ live    = apiserver │  │
│           ──▶ bump tag   │        │   │ if drift: apply     │  │
│              in config   │        │   └────────────────────┘  │
│              repo (PR)   │────────▶│  PULL, no cluster creds  │
└─────────────────────────┘  git    │  in CI                    │
                             commit  └──────────────────────────┘
```

- **CI** produce artefactos inmutables (imágenes firmadas + SBOM) y actualiza el *config repo* con el nuevo tag. **No toca el cluster.**
- **CD** es un controller que corre *dentro* del cluster, hace `pull` de Git, y reconcilia. El cluster jala su propio estado; nadie le empuja nada.

El principio operativo es **el commit de Git como la única fuente de verdad y el único mecanismo de cambio**. Todo cambio en producción es un commit auditable, revisable y reversible con `git revert`.

> **Trade-off fundamental que el examen evalúa:** GitOps resuelve drift, auditoría y superficie de credenciales, pero introduce **latencia de reconciliación** (el loop es de polling, típicamente 3 min por defecto en Argo CD) y complejidad operativa (ahora hay que operar el propio controller de GitOps). No es gratis, y no todo caso de uso lo justifica.

---

## 2. Comparativas técnicas y trade-offs

### 2.1 Modelo de despliegue: `push` imperativo vs `pull` GitOps

| Dimensión | Push (kubectl/helm desde CI) | Pull (GitOps: Argo CD / Flux) |
|---|---|---|
| Fuente de verdad | Ambigua (Git + estado vivo) | Git, autoritativo |
| Credenciales de cluster en CI | Sí (alto riesgo) | No |
| Corrección de drift | Manual / inexistente | Automática (self-heal) |
| Rollback | Re-ejecutar pipeline | `git revert` (segundos) |
| Auditoría de "qué corre en prod" | Consultar cluster vivo | `git log` del config repo |
| Latencia de despliegue | Inmediata (segundos) | Polling (hasta el intervalo de reconcile) |
| Multi-cluster | N pipelines con N kubeconfigs | 1 controller por cluster, config declarativa |
| Complejidad operativa añadida | Baja | Media (operar el controller) |
| Ajuste para jobs efímeros / batch | Bueno | Pobre (GitOps es para estado deseado continuo) |

### 2.2 Motores de CI orquestados en Kubernetes

| Motor | Modelo de ejecución | Nativo K8s | Fortaleza | Debilidad en producción |
|---|---|---|---|---|
| **Tekton** | Cada `Step` es un container; `Task`/`Pipeline` son CRDs | Sí (nativo, todo son pods) | Componible, reusable, sin servidor central con estado | UX cruda; hay que montar dashboard, triggers y results por separado |
| **Jenkins (+ kubernetes plugin)** | Agentes efímeros como pods | Parcial | Ecosistema masivo de plugins, madurez | Master con estado (SPOF), Groovy, mantenimiento pesado de plugins |
| **GitHub Actions (+ ARC)** | Runners como pods vía Actions Runner Controller | Vía controller | UX excelente, integración con PR | Lógica atada a GitHub, salir del ecosistema es caro |
| **GitLab CI** | Runners como pods vía `gitlab-runner` | Vía runner | Todo-en-uno (SCM+CI+registry) | Monolítico; escalar el runner exige tuning fino |
| **Argo Workflows** | DAG de pasos como pods | Sí (nativo) | Fan-out/fan-in, batch/ML, paralelismo | No es un CI "de propósito general"; sin triggers de SCM integrados |

### 2.3 Construcción de imágenes sin Docker daemon (rootless / daemonless)

El problema: construir imágenes *dentro* de Kubernetes. Montar `/var/run/docker.sock` (DooD) o correr Docker-in-Docker con `--privileged` es una vulnerabilidad de escape de container. Las alternativas daemonless son obligatorias en clusters endurecidos.

| Builder | Requiere privilegios | Cache | Dockerfile | Modelo |
|---|---|---|---|---|
| **Kaniko** | No (userspace) | Layers a registry/repo | Sí | Ejecuta cada instrucción del Dockerfile en userspace, snapshotea el FS |
| **BuildKit (rootless)** | No (con `RootlessKit`) | Avanzado (mount cache, distribuido) | Sí | Daemon `buildkitd`, el motor moderno de Docker |
| **Buildah** | No (rootless) | Layer cache | Sí + API imperativa | Del stack de Podman; scriptable |
| **ko** | No | N/A (no usa Dockerfile) | No | Sólo Go; empaqueta el binario sin Dockerfile, ultra rápido |
| **Jib** | No | Layer cache de Maven/Gradle | No | Sólo JVM; build reproducible desde el build tool |

> **Regla de decisión:** para Go, `ko` (segundos, reproducible, sin Dockerfile). Para JVM, `Jib`. Para Dockerfiles arbitrarios en un cluster sin privilegios, `Kaniko` o `BuildKit rootless`. `BuildKit` gana en cache distribuido si el volumen de builds es alto; `Kaniko` es más simple de operar como un `Task` de Tekton.

### 2.4 Controllers de GitOps: Argo CD vs Flux

| Dimensión | Argo CD | Flux (v2 / GitOps Toolkit) |
|---|---|---|
| Arquitectura | Aplicación con UI + API server | Conjunto de controllers componibles (source, kustomize, helm, notification, image) |
| UI | Rica, first-class | Terceros (Weave GitOps) |
| Modelo de app | CRD `Application` / `ApplicationSet` | `GitRepository` + `Kustomization`/`HelmRelease` |
| Multi-tenancy | Projects + RBAC | Namespaces + RBAC nativo de K8s |
| Image automation | Requiere Argo CD Image Updater (add-on) | `image-reflector` + `image-automation` nativos |
| Filosofía | Aplicación monolítica orientada a UX | Toolkit Unix-like, componer controllers |
| Reconcile por defecto | 180s (polling) + webhook opcional | Intervalo por `Kustomization`, configurable |

### 2.5 Progressive delivery: estrategias

| Estrategia | Riesgo de blast radius | Costo de infra | Complejidad | Herramienta típica |
|---|---|---|---|---|
| Recreate | Máximo (downtime) | Bajo | Trivial | Deployment nativo |
| RollingUpdate | Medio | Bajo | Baja | Deployment nativo |
| Blue/Green | Bajo (switch atómico) | Alto (2x capacidad) | Media | Argo Rollouts / Flagger |
| Canary (por réplicas) | Bajo | Medio | Media | Argo Rollouts |
| Canary (por tráfico + análisis) | Mínimo | Medio | Alta | Argo Rollouts + Prometheus / Flagger |

---

## 3. Manifiestos completos de producción

### 3.1 Pipeline de CI con Tekton: test → build (Kaniko) → firma (Cosign)

**Task de test unitario** (`ci/tasks/go-test.yaml`):

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: go-test
  namespace: ci
spec:
  description: Run Go unit tests with race detector and coverage gate.
  workspaces:
    - name: source
      description: The cloned git repository.
  params:
    - name: coverage-threshold
      type: string
      default: "80"
  steps:
    - name: test
      image: golang:1.23-alpine
      workingDir: $(workspaces.source.path)
      script: |
        #!/bin/sh
        set -eu
        apk add --no-cache git build-base
        go test -race -covermode=atomic -coverprofile=cover.out ./...
        COVER=$(go tool cover -func=cover.out | awk '/^total:/ {print substr($3, 1, length($3)-1)}')
        echo "Total coverage: ${COVER}%"
        THRESHOLD="$(params.coverage-threshold)"
        awk -v c="$COVER" -v t="$THRESHOLD" 'BEGIN { exit (c < t) }' || {
          echo "FAIL: coverage ${COVER}% below threshold ${THRESHOLD}%"
          exit 1
        }
      resources:
        requests:
          cpu: "500m"
          memory: 512Mi
        limits:
          memory: 1Gi
```

**Task de build con Kaniko, sin privilegios** (`ci/tasks/kaniko-build.yaml`):

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: kaniko-build
  namespace: ci
spec:
  description: Build and push an image with Kaniko (rootless, no docker daemon).
  params:
    - name: IMAGE
      description: Fully qualified target image, e.g. registry.example.com/app.
      type: string
    - name: DOCKERFILE
      default: ./Dockerfile
      type: string
    - name: CONTEXT
      default: .
      type: string
  workspaces:
    - name: source
    - name: docker-credentials
      description: Mounted at /kaniko/.docker with a config.json.
  results:
    - name: IMAGE_DIGEST
      description: Digest of the pushed image.
  steps:
    - name: build-and-push
      image: gcr.io/kaniko-project/executor:v1.23.2
      args:
        - --dockerfile=$(params.DOCKERFILE)
        - --context=dir://$(workspaces.source.path)/$(params.CONTEXT)
        - --destination=$(params.IMAGE)
        - --digest-file=$(results.IMAGE_DIGEST.path)
        - --cache=true
        - --cache-ttl=168h
        - --reproducible
      env:
        - name: DOCKER_CONFIG
          value: $(workspaces.docker-credentials.path)
      # Kaniko needs no privileged securityContext; runs in userspace.
      securityContext:
        runAsNonRoot: false   # kaniko executor requires uid 0 inside its own userns
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
```

**Task de firma keyless con Cosign + OIDC** (`ci/tasks/cosign-sign.yaml`):

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: cosign-sign
  namespace: ci
spec:
  params:
    - name: IMAGE
      type: string
    - name: DIGEST
      type: string
  steps:
    - name: sign
      image: gcr.io/projectsigstore/cosign:v2.4.1
      env:
        - name: COSIGN_EXPERIMENTAL
          value: "1"
      script: |
        #!/busybox/sh
        set -eu
        # Keyless signing: identity comes from the workload's OIDC token,
        # recorded in the Rekor transparency log. No private key to steal.
        cosign sign --yes "$(params.IMAGE)@$(params.DIGEST)"
```

**Pipeline que encadena los Tasks** (`ci/pipeline.yaml`):

```yaml
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: build-sign-promote
  namespace: ci
spec:
  params:
    - name: repo-url
    - name: revision
      default: main
    - name: image
  workspaces:
    - name: shared-workspace
    - name: docker-credentials
  tasks:
    - name: fetch-source
      taskRef:
        name: git-clone   # from Tekton Hub
      workspaces:
        - name: output
          workspace: shared-workspace
      params:
        - name: url
          value: $(params.repo-url)
        - name: revision
          value: $(params.revision)

    - name: unit-test
      runAfter: ["fetch-source"]
      taskRef:
        name: go-test
      workspaces:
        - name: source
          workspace: shared-workspace

    - name: build
      runAfter: ["unit-test"]
      taskRef:
        name: kaniko-build
      params:
        - name: IMAGE
          value: $(params.image)
      workspaces:
        - name: source
          workspace: shared-workspace
        - name: docker-credentials
          workspace: docker-credentials

    - name: sign
      runAfter: ["build"]
      taskRef:
        name: cosign-sign
      params:
        - name: IMAGE
          value: $(params.image)
        - name: DIGEST
          value: $(tasks.build.results.IMAGE_DIGEST)

  finally:
    - name: notify
      taskRef:
        name: send-slack-notification
      params:
        - name: pipeline-status
          value: $(tasks.status)
```

**PipelineRun disparado por un push** (`ci/pipelinerun.yaml`):

```yaml
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: build-sign-promote-
  namespace: ci
spec:
  pipelineRef:
    name: build-sign-promote
  taskRunTemplate:
    serviceAccountName: tekton-ci   # bound to registry push + OIDC issuance
  params:
    - name: repo-url
      value: https://github.com/example/app.git
    - name: revision
      value: 3f9a1c2
    - name: image
      value: registry.example.com/app:3f9a1c2
  workspaces:
    - name: shared-workspace
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 1Gi
    - name: docker-credentials
      secret:
        secretName: registry-credentials
  timeouts:
    pipeline: "1h0m0s"
```

### 3.2 Application de Argo CD (el plano CD, modelo pull)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: payments-prod
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io   # cascade delete on app removal
spec:
  project: payments
  source:
    repoURL: https://github.com/example/deploy-config.git
    targetRevision: main
    path: apps/payments/overlays/prod   # Kustomize overlay
  destination:
    server: https://kubernetes.default.svc
    namespace: payments
  syncPolicy:
    automated:
      prune: true       # delete resources removed from Git
      selfHeal: true    # revert manual drift automatically
      allowEmpty: false
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
      - ApplyOutOfSyncOnly=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
  revisionHistoryLimit: 10
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas   # HPA owns replica count; don't fight it
```

### 3.3 ApplicationSet: generar N Applications sin duplicar YAML

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: payments-all-clusters
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - clusters:
        selector:
          matchLabels:
            environment: production
  template:
    metadata:
      name: 'payments-{{.name}}'
    spec:
      project: payments
      source:
        repoURL: https://github.com/example/deploy-config.git
        targetRevision: main
        path: 'apps/payments/overlays/{{.metadata.labels.region}}'
      destination:
        server: '{{.server}}'
        namespace: payments
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
```

### 3.4 Progressive delivery: Argo Rollouts canary con análisis Prometheus

**AnalysisTemplate** (gate de métricas, `rollouts/analysis.yaml`):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: success-rate
  namespace: payments
spec:
  args:
    - name: service-name
  metrics:
    - name: success-rate
      interval: 30s
      count: 5
      successCondition: result[0] >= 0.99
      failureLimit: 1
      provider:
        prometheus:
          address: http://prometheus.monitoring:9090
          query: |
            sum(rate(http_requests_total{
              service="{{args.service-name}}", code!~"5.."}[2m]))
            /
            sum(rate(http_requests_total{
              service="{{args.service-name}}"}[2m]))
```

**Rollout con pasos de canary automatizados** (`rollouts/rollout.yaml`):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: payments
  namespace: payments
spec:
  replicas: 10
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app: payments
  template:
    metadata:
      labels:
        app: payments
    spec:
      containers:
        - name: payments
          image: registry.example.com/app:3f9a1c2
          ports:
            - containerPort: 8080
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 5
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              memory: 512Mi
  strategy:
    canary:
      canaryService: payments-canary
      stableService: payments-stable
      trafficRouting:
        # Requires a service mesh or ingress that supports weighted routing.
        nginx:
          stableIngress: payments-ingress
      steps:
        - setWeight: 10
        - pause: {duration: 2m}
        - analysis:
            templates:
              - templateName: success-rate
            args:
              - name: service-name
                value: payments-canary
        - setWeight: 30
        - pause: {duration: 5m}
        - analysis:
            templates:
              - templateName: success-rate
            args:
              - name: service-name
                value: payments-canary
        - setWeight: 60
        - pause: {duration: 5m}
        - setWeight: 100
```

### 3.5 GitHub Actions con OIDC (sin secrets estáticos de cloud)

`.github/workflows/ci.yaml`:

```yaml
name: build-and-promote
on:
  push:
    branches: [main]

permissions:
  contents: read
  id-token: write   # required to mint the OIDC token
  packages: write

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Authenticate to registry via OIDC (no long-lived secret)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::111122223333:role/gha-ecr-push
          aws-region: us-east-1

      - name: Build and push with ko
        env:
          KO_DOCKER_REPO: 111122223333.dkr.ecr.us-east-1.amazonaws.com/app
        run: |
          go install github.com/google/ko@latest
          IMAGE=$(ko build --bare --tags "${GITHUB_SHA::7}" ./cmd/app)
          echo "IMAGE=$IMAGE" >> "$GITHUB_ENV"

      - name: Sign image (keyless)
        run: |
          cosign sign --yes "${IMAGE}"

      - name: Bump image tag in config repo (GitOps handoff)
        run: |
          git clone https://x-access-token:${{ secrets.CONFIG_REPO_TOKEN }}@github.com/example/deploy-config.git
          cd deploy-config/apps/payments/overlays/prod
          kustomize edit set image app="${IMAGE}"
          git config user.name "ci-bot"
          git config user.email "ci-bot@example.com"
          git commit -am "chore: bump payments to ${GITHUB_SHA::7}"
          git push
          # CI ends here. Argo CD pulls this commit and reconciles. CI never touched the cluster.
```

---

## 4. Comandos CLI y salidas reales de terminal

### 4.1 Ejecutar y observar el PipelineRun de Tekton

```console
$ kubectl create -f ci/pipelinerun.yaml
pipelinerun.tekton.dev/build-sign-promote-x7k2p created

$ tkn pipelinerun logs build-sign-promote-x7k2p -f -n ci
[fetch-source : clone] + git clone -depth 1 https://github.com/example/app.git
[fetch-source : clone] Cloning into '.'...

[unit-test : test] Total coverage: 84.2%
[unit-test : test] ok      github.com/example/app/internal/ledger    0.412s  coverage: 84.2%

[build : build-and-push] INFO[0002] Retrieving image manifest golang:1.23-alpine
[build : build-and-push] INFO[0031] Pushing image to registry.example.com/app:3f9a1c2
[build : build-and-push] INFO[0044] Pushed registry.example.com/app@sha256:9b2e...c1a4

[sign : sign] Generating ephemeral keys...
[sign : sign] Retrieving signed certificate from Fulcio...
[sign : sign] tlog entry created with index: 84213771

$ tkn pipelinerun describe build-sign-promote-x7k2p -n ci
Name:              build-sign-promote-x7k2p
Status
STARTED          DURATION     STATUS
2 minutes ago    1m48s        Succeeded

Taskruns
 NAME                                   TASK NAME      STATUS
 build-sign-promote-x7k2p-sign          sign           Succeeded
 build-sign-promote-x7k2p-build         build          Succeeded
 build-sign-promote-x7k2p-unit-test     unit-test      Succeeded
 build-sign-promote-x7k2p-fetch-source  fetch-source   Succeeded
```

### 4.2 Verificar la firma antes de admitir la imagen

```console
$ cosign verify \
    --certificate-identity-regexp 'https://github.com/example/.*' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    registry.example.com/app@sha256:9b2e...c1a4

Verification for registry.example.com/app@sha256:9b2e...c1a4 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority certificates
```

### 4.3 Estado de sincronización en Argo CD

```console
$ argocd app get payments-prod
Name:               argocd/payments-prod
Project:            payments
Server:             https://kubernetes.default.svc
Namespace:          payments
Sync Status:        Synced to main (a1b2c3d)
Health Status:      Healthy

GROUP  KIND        NAMESPACE  NAME      STATUS  HEALTH   HOOK  MESSAGE
       Service     payments   payments  Synced  Healthy        service/payments created
apps   Deployment  payments   payments  Synced  Healthy        deployment.apps/payments configured

$ argocd app history payments-prod
ID  DATE                           REVISION
5   2026-08-07 14:22:10 +0000 UTC  a1b2c3d (bump payments to 3f9a1c2)
4   2026-08-06 09:11:44 +0000 UTC  8e4f0aa (bump payments to 2d7c9b1)

# Rollback declarativo (revierte el estado deseado a un commit previo):
$ argocd app rollback payments-prod 4
Rollback 'payments-prod' to 4? [y/n] y
TIMESTAMP                  GROUP  KIND        MESSAGE
2026-08-07T14:35:02+00:00  apps   Deployment  Rolled back to 8e4f0aa
```

### 4.4 Observar la progresión del canary con Argo Rollouts

```console
$ kubectl argo rollouts get rollout payments -n payments --watch
Name:            payments
Namespace:       payments
Status:          ॥ Paused
Message:         CanaryPauseStep
Strategy:        Canary
  Step:          1/8
  SetWeight:     10
  ActualWeight:  10
Images:          registry.example.com/app:2d7c9b1 (stable)
                 registry.example.com/app:3f9a1c2 (canary)
Replicas:
  Desired:       10
  Current:       11
  Updated:       1
  Ready:         11
  Available:     11

NAME                                 KIND        STATUS     AGE  INFO
⟳ payments                           Rollout     ॥ Paused   6d
├──# revision:12
│  └──⧉ payments-6df9c8b7f9          ReplicaSet  ✔ Healthy  40s  canary
│     └──□ payments-6df9c8b7f9-k2m4  Pod         ✔ Running  40s  ready:1/1
└──# revision:11
   └──⧉ payments-7c9b4f6d55          ReplicaSet  ✔ Healthy  6d   stable

# Promoción manual si se decide avanzar antes del pause:
$ kubectl argo rollouts promote payments -n payments
rollout 'payments' promoted

# Abortar y volver al stable de forma inmediata:
$ kubectl argo rollouts abort payments -n payments
rollout 'payments' aborted
```

---

## 5. Guía de verificación y diagnóstico de fallas

### 5.1 Matriz de diagnóstico por síntoma

| Síntoma | Causa raíz probable | Comando de diagnóstico | Resolución |
|---|---|---|---|
| Argo CD queda `OutOfSync` y no se cura | `selfHeal: false`, o un controller externo edita el recurso (HPA sobre `replicas`) | `argocd app diff payments-prod` | Añadir `ignoreDifferences` para el campo disputado |
| `OutOfSync` permanente en un solo campo | Un `MutatingWebhook` inyecta un valor (sidecar, label) | `kubectl get deploy -o yaml` y comparar | Excluir con `ignoreDifferences` o `Respect ignore differences` |
| PipelineRun `Failed` sin logs claros | El pod del TaskRun no arranca (imagen/quota/SA) | `kubectl describe taskrun <tr> -n ci` | Revisar `Events`: `ImagePullBackOff`, `Forbidden`, `FailedScheduling` |
| Kaniko: `error checking push permissions` | `config.json` mal montado o sin credencial del registry | `kubectl get secret registry-credentials -o yaml` | Verificar `.dockerconfigjson` y el `DOCKER_CONFIG` env |
| Kaniko OOMKilled en layers grandes | Snapshot en memoria excede el límite | `kubectl describe pod` → `OOMKilled` | Subir memory limit; usar `--single-snapshot` o `--use-new-run` |
| `cosign verify` falla en admission | Identidad/issuer no coincide con la policy | `cosign verify ... --certificate-identity ...` | Alinear la policy (Kyverno/Sigstore Policy Controller) con el identity real |
| Canary avanza sin correr el análisis | `AnalysisTemplate` no referenciado o Prometheus inalcanzable | `kubectl get analysisrun -n payments` | Revisar `Status.Message` del AnalysisRun; comprobar el endpoint de Prometheus |
| Deploy "exitoso" pero pods viejos | Push a config repo sin cambio de digest (tag mutable reutilizado) | `argocd app get` (revision no cambió) | Usar tags inmutables (SHA/digest), nunca `latest` |

### 5.2 Verificación de un despliegue: la escalera de aserciones

No confíes en "el pipeline pasó en verde". Verificá en capas, de la más barata a la más cara:

```console
# 1. ¿El estado deseado en Git es el que esperás? (autoritativo, gratis)
$ git -C deploy-config log -1 --oneline apps/payments/overlays/prod
a1b2c3d chore: bump payments to 3f9a1c2

# 2. ¿Argo CD reconcilió ese commit exacto?
$ argocd app get payments-prod -o json | jq '.status.sync.revision'
"a1b2c3d..."

# 3. ¿El apiserver refleja el digest correcto? (no el tag — el digest)
$ kubectl get deploy payments -n payments \
    -o jsonpath='{.spec.template.spec.containers[0].image}'
registry.example.com/app@sha256:9b2e...c1a4

# 4. ¿Los pods están realmente Ready y sirviendo, no sólo Running?
$ kubectl get pods -n payments -l app=payments \
    -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[0].ready
NAME              READY
payments-6df9c8b7f9-k2m4  true

# 5. ¿La firma es válida contra la identidad esperada? (la aserción más fuerte)
$ cosign verify --certificate-identity-regexp 'https://github.com/example/.*' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    registry.example.com/app@sha256:9b2e...c1a4
```

> **Distinción crítica que el examen evalúa:** "el rollout terminó" ≠ "la aplicación funciona". El `progressDeadlineSeconds` de un Deployment mide *readiness de pods*, no *corrección de negocio*. Un pod puede pasar su readiness probe y devolver 500 en cada request de negocio. Por eso el gate real es el **AnalysisRun sobre métricas de aplicación** (tasa de éxito, latencia p99), no el estado del ReplicaSet.

### 5.3 Diagnóstico de un `AnalysisRun` fallido

```console
$ kubectl get analysisrun -n payments
NAME                          STATUS         AGE
payments-6df9c8b7f9-1-1       Failed         3m

$ kubectl describe analysisrun payments-6df9c8b7f9-1-1 -n payments
Status:
  Phase:   Failed
  Metric Results:
    Name:   success-rate
    Phase:  Failed
    Measurements:
      Value:       0.982
      Phase:       Failed
      Started At:  2026-08-07T14:25:00Z
    Message:  metric "success-rate" assessed Failed:
              failed (1) > failureLimit (1)
Events:
  Type     Reason           Message
  ----     ------           -------
  Warning  MetricFailed     Metric 'success-rate' Completed. Result: Failed
  Warning  RolloutAborted   Rollout aborted update to revision 12
```

Aquí el canary devolvió 98.2% de éxito, por debajo del `successCondition: >= 0.99`. Argo Rollouts **abortó automáticamente** y revirtió el tráfico al stable. Este es el comportamiento correcto: el análisis de métricas de producción, no un humano mirando un dashboard, tomó la decisión de rollback.

---

## 6. Referencias

- **CNPE Curriculum (CNCF)** — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- **Tekton Pipelines** — https://tekton.dev/docs/pipelines/
- **Tekton Tasks & Results** — https://tekton.dev/docs/pipelines/tasks/
- **Argo CD** — https://argo-cd.readthedocs.io/en/stable/
- **Argo CD ApplicationSet** — https://argo-cd.readthedocs.io/en/stable/user-guide/application-set/
- **Argo Rollouts** — https://argoproj.github.io/argo-rollouts/
- **Argo Rollouts Analysis** — https://argoproj.github.io/argo-rollouts/features/analysis/
- **Flux (GitOps Toolkit)** — https://fluxcd.io/flux/
- **Flux Image Automation** — https://fluxcd.io/flux/guides/image-update/
- **Kaniko** — https://github.com/GoogleContainerTools/kaniko
- **BuildKit** — https://github.com/moby/buildkit
- **ko** — https://ko.build/
- **Jib** — https://github.com/GoogleContainerTools/jib
- **Sigstore Cosign** — https://docs.sigstore.dev/cosign/signing/overview/
- **Sigstore Policy Controller** — https://docs.sigstore.dev/policy-controller/overview/
- **Actions Runner Controller (ARC)** — https://github.com/actions/actions-runner-controller
- **GitHub OIDC hardening** — https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/about-security-hardening-with-openid-connect
- **OpenGitOps Principles (CNCF)** — https://opengitops.dev/
- **Kustomize** — https://kubectl.docs.kubernetes.io/references/kustomize/
- **SLSA (Supply-chain Levels for Software Artifacts)** — https://slsa.dev/