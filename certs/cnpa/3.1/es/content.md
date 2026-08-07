# Tema 3.1 — Continuous Integration: Fundamentos y Buenas Prácticas

> **Dominio 3 — Continuous Integration & Delivery** · Peso del ítem: **2.3** · CNPA v2025-04-01
> Perfil: Platform Architect / SRE Senior. Se asume dominio previo de Git, contenedores OCI y Kubernetes.

---

## 1. Motivación y el problema arquitectónico de producción

Continuous Integration (CI) no es "correr los tests en cada push". Es una **estrategia de control de la deriva (drift) del código** frente a una rama principal integrable en todo momento. El problema que resuelve es económico y matemático antes que técnico.

### 1.1 El coste no-lineal de la integración diferida

Cuando *N* desarrolladores trabajan en aislamiento durante *t* días, cada rama acumula divergencia respecto de `main`. El coste de reconciliar dos ramas crece con el producto de sus cambios, no con la suma. Sin integración frecuente, la deuda de merge (*merge debt*) crece de forma superlineal: es el clásico **"integration hell"** descrito por Fowler.

```
Coste de integración ≈ Σ (conflictos_semánticos) × (tiempo_de_contexto_perdido)
donde conflictos_semánticos crece ~ O(divergencia_A × divergencia_B)
```

CI ataca la variable dominante — la **divergencia** — forzando integraciones pequeñas y frecuentes contra un *mainline* siempre verde. La consecuencia arquitectónica: la unidad de trabajo deja de ser "la feature" y pasa a ser "el commit integrable".

### 1.2 El feedback loop como SLI de la plataforma

Para un Platform Engineer, el pipeline de CI **es un servicio de producción** con sus propios SLIs/SLOs. El SLI dominante es la **latencia del feedback loop**: tiempo desde `git push` hasta un veredicto verde/rojo confiable.

| Rango de feedback | Comportamiento del desarrollador | Consecuencia sistémica |
|---|---|---|
| < 10 min | Espera el resultado, itera en caliente | Flujo óptimo, WIP bajo |
| 10–30 min | Cambia de contexto, vuelve | Coste de context-switch |
| > 30 min | Abandona el loop, acumula commits | Batches grandes → integration hell |
| Flaky (no determinista) | Ignora el veredicto ("re-run") | **Erosión de confianza → CI inútil** |

El peor estado no es "CI lento": es **CI no confiable** (flaky). Un pipeline con 5 % de flakiness por job y 10 jobs tiene una probabilidad de rojo espurio de `1 − 0.95¹⁰ ≈ 40 %`. A ese nivel, el equipo aprende a re-ejecutar por reflejo y CI deja de ser una señal. **La flakiness es el fallo de SLO más grave de un pipeline.**

### 1.3 El giro cloud-native: de máquinas mascota a runners efímeros

El modelo tradicional (Jenkins con *build agents* de larga vida) trae los patologías de las *pet servers*: deriva de configuración, dependencias globales contaminadas, "funciona en el agente 3 pero no en el 7". El modelo cloud-native de CI impone:

- **Runners efímeros**: cada build corre en un Pod/contenedor recién creado y destruido al terminar. Cero estado compartido entre builds.
- **Builds herméticos**: entradas declaradas explícitamente, sin acceso a la red no controlado, salida reproducible bit-a-bit (idealmente).
- **Pipeline-as-Code**: la definición del pipeline vive en el repositorio, versionada junto al código que construye.
- **CI como *paved road***: la plataforma ofrece plantillas/pipelines dorados (golden paths) que los equipos consumen sin reimplementar cada vez.

Este tema cubre CI con esa lente: **reproducibilidad, efimeridad y trazabilidad de la supply chain** como requisitos de primera clase, no como extras.

---

## 2. Modelo mental: qué es (y qué no es) CI

### 2.1 Definición operativa

> **Continuous Integration** es la práctica de integrar el trabajo de todos los contribuyentes a una rama compartida (*mainline*) con **alta frecuencia** (idealmente varias veces al día), donde **cada integración dispara una build y una suite de tests automatizados**, y donde **romper el mainline es el evento de máxima prioridad del equipo**.

Las tres propiedades no negociables:

1. **Mainline siempre integrable** — `main` compila y pasa tests en todo momento; un rojo se arregla o se revierte de inmediato.
2. **Build + test automatizados y determinísticos** — sin intervención manual, mismo input → mismo veredicto.
3. **Feedback rápido y visible** — el estado del mainline es de conocimiento público y el veredicto llega antes de que el contexto se enfríe.

### 2.2 CI vs. CD vs. Continuous Deployment

Confusión frecuente en el examen. Son etapas de un continuo, con *gates* distintos:

| Concepto | Alcance | Gate de promoción | Artefacto de salida |
|---|---|---|---|
| **Continuous Integration** | `commit → build → test → artefacto validado` | Suite de tests verde | Imagen/artefacto firmado + provenance |
| **Continuous Delivery** | El artefacto queda **siempre listo para desplegar** | Aprobación manual (botón) | Release candidata desplegable |
| **Continuous Deployment** | Todo cambio que pasa gates **va a prod automáticamente** | Gates automáticos (canary, SLO) | Despliegue en producción |

Regla mnemónica: **CI produce un artefacto en el que confiás; CD lo pone a un clic de producción; Continuous Deployment elimina el clic.** Este tema (3.1) se detiene en el límite CI/CD: **el artefacto validado, firmado y trazable.**

### 2.3 La línea divisoria exacta

El *handoff* de CI a CD es el **artefacto inmutable, direccionable por digest y firmado**:

```
registry.example.com/team/app@sha256:9b2c...e41   ← esto es lo que CI entrega
```

No un tag mutable (`:latest`, `:v1.2`), sino un **digest**. Todo lo aguas arriba del digest es CI; todo lo aguas abajo (qué se despliega, dónde, cuándo) es CD/GitOps. Mantener esa frontera limpia es lo que hace auditable la supply chain.

---

## 3. Estrategias de branching — comparativa de trade-offs

La estrategia de ramas **determina la frecuencia de integración**, que es la variable que CI intenta maximizar. No es una preferencia estética: es una decisión de arquitectura de entrega.

| Estrategia | Vida de rama | Frec. integración a mainline | Complejidad de release | Feature flags requeridas | Fit con CI/Continuous Deployment |
|---|---|---|---|---|---|
| **Trunk-Based Development** | Horas (< 1 día) | Muy alta (varias/día) | Baja | Sí (para trabajo incompleto) | ★★★★★ — modelo objetivo |
| **GitHub Flow** | Días | Alta | Baja | Recomendadas | ★★★★☆ |
| **GitLab Flow** | Días–semana | Media | Media (env branches) | Opcionales | ★★★☆☆ |
| **GitFlow** | Semanas | Baja | Alta (`develop`/`release`/`hotfix`) | No | ★☆☆☆☆ — antipatrón para CI moderno |

### 3.1 Por qué Trunk-Based es el estándar de CI de alto rendimiento

Los estudios de **DORA (DevOps Research and Assessment)** correlacionan consistentemente el trunk-based development (ramas de vida corta, < 3 ramas activas, integración diaria) con las métricas de élite (lead time, deploy frequency, MTTR, change failure rate). La razón es directa: **maximiza la frecuencia de integración**, que es exactamente lo que CI optimiza.

El coste que impone: el trabajo incompleto debe integrarse a `main` **oculto tras feature flags**, no aislado en una rama. Se cambia *merge debt* (implícita, explosiva) por *flag debt* (explícita, gestionable).

```go
// Trabajo incompleto integrado a main, apagado en runtime.
// El código se integra y se testea continuamente aunque la feature no esté "lista".
if flags.Enabled(ctx, "checkout-v2") {
    return checkoutV2(ctx, cart)
}
return checkoutV1(ctx, cart)
```

### 3.2 GitFlow como antipatrón de CI

GitFlow (ramas `develop`, `release/*`, `feature/*` de larga vida, `hotfix/*`) fue diseñado para **releases versionadas y poco frecuentes** de software empaquetado. Aplicado a servicios cloud-native con despliegue continuo produce lo contrario de CI: ramas que viven semanas, integración diferida, y el "integration hell" que CI existe para eliminar. En el examen CNPA, **GitFlow es el ejemplo canónico de estrategia contraria a la integración continua.**

---

## 4. Anatomía de un pipeline de CI de producción

Un pipeline de CI maduro es un **DAG de stages** con propiedades de fail-fast, paralelismo y cacheo. El orden **no es arbitrario**: se ordena por *coste creciente* y *probabilidad de fallo decreciente*, para maximizar el fail-fast.

```
                    ┌─→ lint ────────┐
                    ├─→ unit-test ───┤
   checkout ──→ deps├─→ sast ────────┼─→ build-image ─→ scan-image ─→ sign ─→ push
   (fetch+cache)    └─→ license-check┘   (kaniko)       (trivy)      (cosign) (@digest)
        │
        └─ (fail-fast: cualquier stage barato en rojo aborta el DAG antes del build caro)
```

### 4.1 Principios de diseño (best practices examinables)

| Principio | Qué significa | Antipatrón que evita |
|---|---|---|
| **Fail-fast** | Los checks baratos y frecuentemente-rojos van primero | Gastar 8 min en build para fallar en un `gofmt` |
| **Paralelización** | Stages independientes corren concurrentes | Pipeline serial de 25 min que podría durar 8 |
| **Cacheo de dependencias** | `~/.m2`, `node_modules`, `go/pkg/mod` persistidos entre runs | Descargar internet en cada build |
| **Build hermético** | Toolchain e inputs pineados (digests, lockfiles) | "Ayer compilaba" tras un `apt-get update` upstream |
| **Idempotencia** | Re-ejecutar un run da el mismo resultado | Builds que dependen de la hora o de estado externo |
| **Un artefacto, muchos entornos** | Se construye **una vez**, se promueve por digest | Re-build por entorno → "es otro binario" |
| **Sin secretos en la imagen ni en logs** | Secrets vía volúmenes/refs efímeras, nunca en capas | Token de registry filtrado en una capa OCI |

### 4.2 El principio "build once, promote many"

Regla de oro de CI/CD: **el binario/imagen se construye exactamente una vez**, se identifica por digest inmutable, y ese **mismo** artefacto atraviesa dev → staging → prod. Reconstruir por entorno rompe la garantía fundamental — "lo que testeaste en staging es lo que corre en prod" — porque una re-build puede resolver dependencias distintas. El digest es el ancla de confianza de toda la supply chain aguas abajo.

---

## 5. Comparativa técnica de motores de CI

| Motor | Modelo de ejecución | Pipeline-as-Code | Runner efímero nativo | K8s-native | Modelo de extensión | Mejor encaje |
|---|---|---|---|---|---|---|
| **Jenkins** | Controller + agents persistentes | `Jenkinsfile` (Groovy) | Vía k8s plugin (parcial) | Plugin | Plugins (miles, calidad dispar) | Legacy, on-prem, flexibilidad máxima |
| **GitHub Actions** | Runners hosted/self-hosted | `.github/workflows/*.yml` | Sí (ARC en k8s) | Vía ARC | Marketplace de actions | SaaS Git en GitHub, ecosistema amplio |
| **GitLab CI** | Runners (docker/k8s executor) | `.gitlab-ci.yml` | Sí | Executor k8s | `include:`, componentes | Plataforma DevOps integrada |
| **Tekton** | **CRDs sobre Kubernetes** | `Task`/`Pipeline` (YAML) | **Sí, cada step = contenedor en un Pod** | **Nativo (es la razón de ser)** | Tekton Hub, Tasks reusables | **CI/CD como infraestructura declarativa** |
| **Argo Workflows** | **CRD `Workflow` (DAG/steps)** | `Workflow` (YAML) | **Sí (cada step = Pod)** | **Nativo** | Templates, WorkflowTemplates | Pipelines batch/DAG, ML, CI k8s-native |
| **Drone / Woodpecker** | Runners contenerizados | `.drone.yml` | Sí | Runner k8s | Plugins como imágenes | Ligero, self-hosted simple |

### 5.1 Tekton vs. Argo Workflows (el eje cloud-native del examen)

Ambos son **CI/CD como recursos de Kubernetes** (cada paso es un Pod/contenedor efímero), pero con foco distinto:

| Dimensión | Tekton | Argo Workflows |
|---|---|---|
| Abstracción primaria | `Task` (secuencia de steps) → `Pipeline` (DAG de Tasks) | `Workflow` (DAG o steps de templates) |
| Modelo de datos | `Workspaces` (PVC/volúmenes compartidos) + `Results` | Artifacts (S3/GCS/MinIO) + parameters |
| Enfoque | CI/CD específico, Tasks reusables (Tekton Hub) | Orquestación de workflows genérica (CI, ML, ETL) |
| Triggers | Tekton Triggers (EventListener + webhooks) | Argo Events / sensors |
| Signing/supply chain | **Tekton Chains** (firma automática de provenance) | Vía steps explícitos |

Punto de examen: **Tekton Chains** genera y firma automáticamente atestaciones de provenance (in-toto/SLSA) de cada `TaskRun`, sin que el autor del pipeline escriba el paso de firma. Es la respuesta "cloud-native" a la trazabilidad de la supply chain dentro de CI.

---

## 6. CI cloud-native con Tekton — manifiestos completos

Pipeline de CI de producción: `git-clone → run-tests → build-and-push (kaniko) → scan (trivy)`, con **workspace compartido**, **results** propagados y **fail-fast**. Todos los manifiestos son sintácticamente completos y aplicables tal cual.

### 6.1 `Task` — ejecutar tests con caché de módulos Go

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: go-test
  labels:
    app.kubernetes.io/version: "0.3"
spec:
  description: >-
    Ejecuta la suite de tests de Go de forma hermética, reutilizando el módulo
    cache montado en el workspace para acelerar runs sucesivos.
  workspaces:
    - name: source
      description: Checkout del repositorio (compartido con las demás Tasks).
    - name: gocache
      description: Persistencia de $GOMODCACHE entre PipelineRuns.
      optional: true
  params:
    - name: packages
      description: Paquetes a testear.
      type: string
      default: "./..."
    - name: version
      description: Tag de la imagen oficial de Go (pineada por confianza).
      type: string
      default: "1.22-alpine"
  steps:
    - name: unit-test
      image: docker.io/library/golang:$(params.version)
      workingDir: $(workspaces.source.path)
      env:
        - name: GOMODCACHE
          value: $(workspaces.gocache.path)
        - name: CGO_ENABLED
          value: "0"
      script: |
        #!/bin/sh
        set -eu
        echo "→ go vet"
        go vet $(params.packages)
        echo "→ go test (race + cover)"
        go test -race -covermode=atomic \
          -coverprofile=coverage.out \
          $(params.packages)
        go tool cover -func=coverage.out | tail -n 1
```

### 6.2 `Task` — build + push con Kaniko (build hermético sin daemon)

Kaniko construye imágenes OCI **sin acceso al Docker daemon** (sin privilegios de root sobre el nodo), lo cual es el patrón correcto para builds dentro de un cluster de Kubernetes multi-tenant.

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: kaniko-build
spec:
  description: Construye y publica una imagen OCI, exponiendo el digest como result.
  workspaces:
    - name: source
    - name: dockerconfig
      description: Secret con .dockerconfigjson para autenticar al registry.
      optional: false
  params:
    - name: IMAGE
      description: Referencia destino sin digest (registry/repo:tag).
      type: string
    - name: DOCKERFILE
      type: string
      default: ./Dockerfile
    - name: CONTEXT
      type: string
      default: .
  results:
    - name: IMAGE_DIGEST
      description: Digest sha256 de la imagen publicada (ancla de la supply chain).
    - name: IMAGE_URL
      description: Referencia completa publicada.
  steps:
    - name: build-and-push
      image: gcr.io/kaniko-project/executor:v1.23.2
      workingDir: $(workspaces.source.path)
      env:
        - name: DOCKER_CONFIG
          value: $(workspaces.dockerconfig.path)
      args:
        - --dockerfile=$(params.DOCKERFILE)
        - --context=$(workspaces.source.path)/$(params.CONTEXT)
        - --destination=$(params.IMAGE)
        - --digest-file=$(results.IMAGE_DIGEST.path)
        - --reproducible          # timestamps normalizados → builds reproducibles
        - --cache=true
        - --cache-ttl=168h
    - name: write-url
      image: docker.io/library/bash:5.2
      script: |
        #!/usr/bin/env bash
        printf '%s' "$(params.IMAGE)" > "$(results.IMAGE_URL.path)"
```

### 6.3 `Task` — scan de vulnerabilidades con Trivy (gate de seguridad)

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: trivy-scan
spec:
  workspaces:
    - name: source
  params:
    - name: IMAGE
      type: string
    - name: SEVERITY
      type: string
      default: "HIGH,CRITICAL"
    - name: EXIT_CODE
      description: 1 = falla el pipeline si hay hallazgos (gate duro).
      type: string
      default: "1"
  steps:
    - name: scan
      image: docker.io/aquasec/trivy:0.55.0
      script: |
        #!/bin/sh
        set -eu
        trivy image \
          --severity "$(params.SEVERITY)" \
          --ignore-unfixed \
          --exit-code "$(params.EXIT_CODE)" \
          --format table \
          "$(params.IMAGE)"
```

### 6.4 `Pipeline` — el DAG completo con fail-fast

```yaml
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: ci-go-service
spec:
  params:
    - name: repo-url
      type: string
    - name: revision
      type: string
      default: main
    - name: image
      type: string
  workspaces:
    - name: shared-data     # source compartido entre Tasks
    - name: go-cache        # persistencia del module cache
    - name: docker-creds    # secret del registry
  results:
    - name: image-digest
      value: $(tasks.build.results.IMAGE_DIGEST)
  tasks:
    - name: fetch-source
      taskRef:
        name: git-clone      # Task del catálogo Tekton Hub
      params:
        - name: url
          value: $(params.repo-url)
        - name: revision
          value: $(params.revision)
      workspaces:
        - name: output
          workspace: shared-data

    - name: test
      runAfter: ["fetch-source"]
      taskRef:
        name: go-test
      workspaces:
        - name: source
          workspace: shared-data
        - name: gocache
          workspace: go-cache

    # build depende de test → fail-fast: si los tests fallan, nunca se construye
    - name: build
      runAfter: ["test"]
      taskRef:
        name: kaniko-build
      params:
        - name: IMAGE
          value: $(params.image)
      workspaces:
        - name: source
          workspace: shared-data
        - name: dockerconfig
          workspace: docker-creds

    - name: scan
      runAfter: ["build"]
      taskRef:
        name: trivy-scan
      params:
        - name: IMAGE
          value: "$(params.image)@$(tasks.build.results.IMAGE_DIGEST)"
      workspaces:
        - name: source
          workspace: shared-data

  finally:
    # Se ejecuta SIEMPRE (éxito o fallo): notificación/limpieza.
    - name: report
      taskRef:
        name: slack-notify
      params:
        - name: message
          value: >-
            CI ci-go-service: estado=$(tasks.status) digest=$(tasks.build.results.IMAGE_DIGEST)
      when:
        - input: "$(tasks.status)"
          operator: in
          values: ["Failed", "Succeeded"]
```

### 6.5 `PipelineRun` — instanciación con workspaces

```yaml
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: ci-go-service-run-
spec:
  pipelineRef:
    name: ci-go-service
  params:
    - name: repo-url
      value: https://github.com/acme/payments.git
    - name: revision
      value: main
    - name: image
      value: registry.example.com/acme/payments
  workspaces:
    - name: shared-data
      volumeClaimTemplate:      # PVC efímero: nace y muere con el run
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 1Gi
    - name: go-cache
      persistentVolumeClaim:    # PVC persistente: caché entre runs
        claimName: tekton-go-cache
    - name: docker-creds
      secret:
        secretName: registry-dockerconfig
  taskRunTemplate:
    serviceAccountName: tekton-ci   # SA con permisos de push al registry
  timeouts:
    pipeline: "1h0m0s"
```

---

## 7. GitHub Actions self-hosted runners en Kubernetes (ARC)

Cuando el motor es GitHub Actions pero se quiere **efimeridad y aislamiento en el cluster propio**, el patrón de producción es **Actions Runner Controller (ARC)**: cada job corre en un Pod efímero, autoescalado por demanda.

### 7.1 `AutoscalingRunnerSet` (ARC moderno, gha-runner-scale-set)

```yaml
# values de referencia para el chart gha-runner-scale-set (Helm),
# expresados como el recurso que el controller reconcilia.
apiVersion: actions.github.com/v1alpha1
kind: AutoscalingRunnerSet
metadata:
  name: payments-ci
  namespace: arc-runners
spec:
  githubConfigUrl: https://github.com/acme/payments
  githubConfigSecret: github-app-credentials   # GitHub App: nunca PAT en prod
  minRunners: 1
  maxRunners: 20
  runnerScaleSetName: payments-ci
  template:
    spec:
      containers:
        - name: runner
          image: ghcr.io/actions/actions-runner:2.319.1
          command: ["/home/runner/run.sh"]
          resources:
            requests:
              cpu: "1"
              memory: 2Gi
            limits:
              cpu: "2"
              memory: 4Gi
      # Runner efímero: se destruye tras un job (--ephemeral), cero estado residual
      securityContext:
        runAsNonRoot: true
```

### 7.2 Workflow de CI equivalente (`.github/workflows/ci.yml`)

```yaml
name: ci
on:
  pull_request:
    branches: [main]
  push:
    branches: [main]

# Cancela runs previos del mismo ref → no malgastar runners en commits obsoletos
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read
  id-token: write        # OIDC → cosign keyless (sin claves de larga vida)
  packages: write

jobs:
  test:
    runs-on: payments-ci    # el runner set de ARC
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version: '1.22'
          cache: true       # cachea $GOMODCACHE por hash de go.sum
      - name: vet + test
        run: |
          go vet ./...
          go test -race -covermode=atomic -coverprofile=coverage.out ./...

  build:
    needs: test             # fail-fast: sin tests verdes no hay build
    runs-on: payments-ci
    outputs:
      digest: ${{ steps.push.outputs.digest }}
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - id: push
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: ghcr.io/acme/payments:${{ github.sha }}
          provenance: true            # atestación SLSA de build
          sbom: true                  # SBOM adjunto al push
      - name: sign (cosign keyless)
        env:
          COSIGN_EXPERIMENTAL: "1"
        run: |
          cosign sign --yes \
            ghcr.io/acme/payments@${{ steps.push.outputs.digest }}
```

Puntos de best practice en este workflow: `concurrency.cancel-in-progress` (economía de runners), `permissions` mínimos (least privilege), **OIDC + cosign keyless** (sin claves de firma persistentes), y `needs:` para fail-fast.

---

## 8. Builds herméticos y reproducibles

Un build **hermético** produce el mismo output dado el mismo input, aislado del entorno host. Es el requisito que separa "CI que corre tests" de "CI en el que se puede confiar para producción".

### 8.1 Comparativa de builders de imágenes OCI en CI

| Builder | Requiere daemon Docker | Requiere root/privileged | Cache | Reproducible | Encaje en k8s CI |
|---|---|---|---|---|---|
| `docker build` (DinD) | Sí (docker-in-docker) | Sí (privileged) | Sí | Parcial | Antipatrón en multi-tenant (privileged) |
| **Kaniko** | No | No (userspace) | Sí (registry/layer) | Sí (`--reproducible`) | ★★★★☆ estándar Tekton |
| **BuildKit** (rootless) | No (buildkitd) | No (rootless) | Sí (avanzado) | Sí | ★★★★★ moderno, cache mount |
| **Buildah** | No | No (rootless) | Sí | Sí | ★★★★☆ ecosistema Red Hat |

### 8.2 Las tres capas de reproducibilidad

1. **Inputs pineados** — imágenes base por **digest** (`golang@sha256:...`), no por tag; lockfiles (`go.sum`, `package-lock.json`, `Cargo.lock`) commiteados.
2. **Toolchain pineado** — versión exacta del compilador/builder en el manifiesto del pipeline.
3. **Metadatos normalizados** — timestamps de capas fijados (`SOURCE_DATE_EPOCH`, Kaniko `--reproducible`), orden de archivos determinista.

```dockerfile
# Multi-stage hermético: base pineada por digest, build sin red en runtime
FROM golang:1.22-alpine@sha256:2c58e...bd9 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download          # capa cacheable e independiente del código
COPY . .
RUN CGO_ENABLED=0 GOFLAGS=-trimpath \
    go build -ldflags="-s -w -buildid=" -o /app ./cmd/server

FROM gcr.io/distroless/static-debian12:nonroot@sha256:5f9b3...a10
COPY --from=build /app /app
USER nonroot:nonroot
ENTRYPOINT ["/app"]
```

`-trimpath` y `-buildid=` eliminan rutas absolutas y IDs no deterministas del binario → dos builds del mismo commit producen **el mismo digest**.

---

## 9. Supply chain security dentro de CI

CI es el punto donde nace el artefacto; por tanto es donde debe generarse la **evidencia de confianza**. El marco de referencia es **SLSA (Supply-chain Levels for Software Artifacts)**.

### 9.1 Los tres artefactos de confianza que CI debe emitir

| Artefacto | Qué responde | Herramienta típica |
|---|---|---|
| **SBOM** (Software Bill of Materials) | ¿Qué contiene la imagen? | `syft`, `docker sbom` (SPDX/CycloneDX) |
| **Firma** | ¿Quién construyó este digest y es auténtico? | `cosign` (keyless vía OIDC + Fulcio + Rekor) |
| **Provenance / attestation** | ¿Cómo, dónde y con qué inputs se construyó? | `cosign attest`, Tekton Chains, SLSA generator |

### 9.2 Niveles SLSA (mapa mental de examen)

| Nivel | Requisito clave | Cómo lo cumple CI |
|---|---|---|
| **SLSA 1** | Provenance existe y es consumible | El pipeline genera atestación de build |
| **SLSA 2** | Build en servicio hosted + provenance firmada | Runner gestionado + firma automática |
| **SLSA 3** | Build endurecido, no falsificable, aislado | Runner efímero aislado + provenance no manipulable |

### 9.3 Firma keyless (patrón cloud-native)

El antipatrón es una **clave privada de firma almacenada como secret** (larga vida, rotación manual, superficie de robo). El patrón moderno es **keyless**: la identidad del pipeline (token OIDC del runner) se intercambia por un certificado efímero de **Fulcio**, se firma, y la firma se registra en el log de transparencia **Rekor**. Cero claves persistentes.

```
Runner (OIDC token) ──→ Fulcio ──→ cert efímero (10 min)
                                       │
                          cosign firma el digest
                                       │
                                       └──→ Rekor (log de transparencia público/privado)
```

---

## 10. Comandos CLI y salidas de terminal reales

### 10.1 Aplicar y seguir un `PipelineRun` con `tkn`

```console
$ tkn pipeline start ci-go-service \
    --param repo-url=https://github.com/acme/payments.git \
    --param revision=main \
    --param image=registry.example.com/acme/payments \
    --workspace name=shared-data,volumeClaimTemplateFile=pvc.yaml \
    --workspace name=go-cache,claimName=tekton-go-cache \
    --workspace name=docker-creds,secret=registry-dockerconfig \
    --use-param-defaults --showlog
PipelineRun started: ci-go-service-run-8k2mf
Waiting for logs to be available...

[fetch-source : clone] + git clone -depth 1 https://github.com/acme/payments.git /workspace/output
[fetch-source : clone] Cloning into '/workspace/output'...

[test : unit-test] → go vet
[test : unit-test] → go test (race + cover)
[test : unit-test] ok      github.com/acme/payments/internal/ledger   1.284s  coverage: 91.2%
[test : unit-test] total:                                    (statements)  88.7%

[build : build-and-push] INFO[0004] Retrieving image manifest golang:1.22-alpine
[build : build-and-push] INFO[0031] Pushed registry.example.com/acme/payments@sha256:9b2c...e41

[scan : scan] payments (alpine 3.20.1)
[scan : scan] Total: 0 (HIGH: 0, CRITICAL: 0)

[report : notify] CI ci-go-service: estado=Succeeded
```

### 10.2 Inspección del resultado

```console
$ tkn pipelinerun describe ci-go-service-run-8k2mf
Name:              ci-go-service-run-8k2mf
Namespace:         ci
Pipeline Ref:      ci-go-service
Status:            Succeeded

⏱  Duration: 3m41s

📦 Results
 NAME           VALUE
 ∙ image-digest sha256:9b2c1f0a4e2d...e41

🗂  Taskruns
 NAME                          TASK           STATUS      DURATION
 ∙ ...-fetch-source-xk29p      fetch-source   Succeeded   6s
 ∙ ...-test-p8n2q              test           Succeeded   47s
 ∙ ...-build-mk91w             build          Succeeded   2m38s
 ∙ ...-scan-zz10r              scan           Succeeded   9s
 ∙ ...-report-a1b2c            report         Succeeded   3s
```

### 10.3 Generar SBOM y verificar firma/provenance

```console
$ syft registry.example.com/acme/payments@sha256:9b2c...e41 -o spdx-json > sbom.spdx.json
 ✔ Parsed image          sha256:9b2c...e41
 ✔ Cataloged packages    [23 packages]

$ cosign sign --yes registry.example.com/acme/payments@sha256:9b2c...e41
Generating ephemeral keys...
Retrieving signed certificate from Fulcio...
tlog entry created with index: 48210937
Pushing signature to: registry.example.com/acme/payments

$ cosign verify \
    --certificate-identity-regexp="https://github.com/acme/payments/.github/workflows/ci.yml@.*" \
    --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
    registry.example.com/acme/payments@sha256:9b2c...e41
Verification for registry.example.com/acme/payments@sha256:9b2c...e41 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority certificates
```

### 10.4 Atestación SLSA de Tekton Chains (firma automática)

```console
$ kubectl get taskrun ci-go-service-run-8k2mf-build-mk91w \
    -o jsonpath='{.metadata.annotations.chains\.tekton\.dev/signed}'
true

$ tkn chain payload ci-go-service-run-8k2mf-build-mk91w --format slsa | jq '.predicateType'
"https://slsa.dev/provenance/v1"
```

---

## 11. Verificación y diagnóstico de fallas

### 11.1 Tabla de diagnóstico de fallos comunes de CI

| Síntoma | Causa raíz probable | Diagnóstico | Remediación |
|---|---|---|---|
| `TaskRun` en `Pending` indefinido | PVC del workspace no se puede provisionar / SA sin permisos | `kubectl describe taskrun`; buscar eventos `FailedScheduling`/`ProvisioningFailed` | Verificar `StorageClass`, `ResourceQuota`, RBAC del `serviceAccountName` |
| Kaniko: `error checking push permissions` | Secret `dockerconfig` ausente o mal formado | `kubectl get secret registry-dockerconfig -o jsonpath='{.data}'` | Recrear secret `--type=kubernetes.io/dockerconfigjson` |
| Tests verdes localmente, rojos en CI | Dependencia de estado no declarada (orden de tests, TZ, red) | Correr con `-race` y `-shuffle=on`; revisar timestamps | Herметizar: fijar `TZ`, seed, aislar tests; sin red no declarada |
| Pipeline "flaky" (rojo espurio intermitente) | Timeouts ajustados, deps de red, recursos insuficientes | Reintentar N veces y medir tasa; `kubectl top pod` durante el run | Subir `resources.requests`, `retries:` en Task, aislar red |
| Build lento y creciente | Cache miss (workspace de cache no montado o key inestable) | Comparar duración de `go mod download` entre runs | Persistir `go-cache` PVC; estabilizar cache key por hash de lockfile |
| Imagen distinta con el mismo commit | Build no reproducible (tags flotantes, timestamps) | `cosign verify` de dos builds → digests distintos | Pinear base por digest, `--reproducible`, `-trimpath` |
| `cosign verify` falla en despliegue | Identidad OIDC / issuer no coinciden con la política | Revisar `--certificate-identity-regexp` vs. workflow real | Alinear policy (Kyverno/policy-controller) con el path del pipeline |
| Runners de ARC no escalan | GitHub App sin permisos / listener caído | `kubectl logs -n arc-systems deploy/arc-gha-rs-controller` | Revisar credenciales de la App y el `AutoscalingListener` |

### 11.2 Checklist de verificación de un pipeline de CI "listo para producción"

```console
# 1. ¿El mainline está verde AHORA?
$ tkn pipelinerun list --label tekton.dev/pipeline=ci-go-service --limit 1
NAME                      STARTED   DURATION   STATUS
ci-go-service-run-8k2mf   4m ago    3m41s      Succeeded

# 2. ¿El artefacto es direccionable por digest (no por tag mutable)?
$ crane digest registry.example.com/acme/payments:main
sha256:9b2c1f0a4e2d...e41           # coincide con el result del PipelineRun ✔

# 3. ¿Está firmado y con provenance verificable?
$ cosign tree registry.example.com/acme/payments@sha256:9b2c...e41
📦 Supply Chain Security Related artifacts for an image: ...@sha256:9b2c...e41
├── 🔐 Signatures for an image tag: ...sha256-9b2c...e41.sig
├── 📦 SBOMs for an image tag: ...sha256-9b2c...e41.sbom
└── 💾 Attestations for an image tag: ...sha256-9b2c...e41.att

# 4. ¿El feedback loop cumple el SLO (< 10 min)?
#    Duración del último run: 3m41s  ✔  (SLO p95 < 10m)

# 5. ¿Los checks baratos van primero (fail-fast verificable)?
#    Orden observado: fetch → test → build → scan  ✔
```

### 11.3 Golden signals de CI como servicio de plataforma

Un Platform Engineer instrumenta el pipeline como cualquier otro servicio:

| Señal | Métrica | SLO de referencia |
|---|---|---|
| **Latencia** | Duración p50/p95 del pipeline (commit → veredicto) | p95 < 10 min |
| **Tasa de error** | % de runs rojos por **fallo del pipeline** (no del código) | < 1 % |
| **Flakiness** | % de runs que pasan al reintentar sin cambios | < 0.5 % |
| **Saturación** | Runners ocupados / capacidad; tiempo en cola | Cola p95 < 30 s |
| **Frecuencia de integración** | Merges a `main` por día por equipo | Alta (proxy de salud de CI) |

Estas métricas se exportan a Prometheus (Tekton expone métricas `tekton_pipelinerun_duration_seconds`, ARC expone métricas de scale-set) y se alertan como un servicio de producción de primera clase.

---

## 12. Referencias

- **CNPA Curriculum (CNCF/Linux Foundation)** — dominio Continuous Integration & Delivery: https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- **Continuous Integration — Martin Fowler**: https://martinfowler.com/articles/continuousIntegration.html
- **Trunk-Based Development**: https://trunkbaseddevelopment.com/
- **DORA / State of DevOps — capabilities (Trunk-Based Development, CI)**: https://dora.dev/capabilities/trunk-based-development/ y https://dora.dev/capabilities/continuous-integration/
- **Tekton Pipelines — documentación oficial**: https://tekton.dev/docs/pipelines/
- **Tekton Chains (provenance/firma automática)**: https://tekton.dev/docs/chains/
- **Argo Workflows**: https://argo-workflows.readthedocs.io/en/stable/
- **Actions Runner Controller (ARC)**: https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners-with-actions-runner-controller/about-actions-runner-controller
- **GitHub Actions — documentación**: https://docs.github.com/en/actions
- **Kaniko (build de imágenes en userspace)**: https://github.com/GoogleContainerTools/kaniko
- **BuildKit**: https://github.com/moby/buildkit
- **Sigstore Cosign (firma keyless, Fulcio, Rekor)**: https://docs.sigstore.dev/cosign/signing/overview/
- **SLSA — Supply-chain Levels for Software Artifacts**: https://slsa.dev/spec/v1.0/levels
- **Syft (SBOM)**: https://github.com/anchore/syft
- **Trivy (scanning)**: https://trivy.dev/latest/docs/
- **OpenSSF Best Practices / Scorecard**: https://openssf.org/