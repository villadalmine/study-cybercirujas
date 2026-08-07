# 3.3 Continuous Integration Pipelines: Overview and Architecture

> **Dominio:** CI/CD y Delivery de plataforma · **Peso en el examen:** 2.3
> **Perfil:** Platform Architect / SRE Senior · **Nivel:** producción

---

## 1. Motivación y el problema arquitectónico de producción

En platform engineering, la CI **no es una herramienta que cada equipo elige**: es una *capability* del plano de plataforma, expuesta como un **paved road** (golden path) que el equipo de plataforma opera como producto interno. El estudiante debe dejar de pensar en "un Jenkins" y empezar a pensar en un **control plane de ejecución de workloads efímeros, multi-tenant, auditado y firmado**.

El problema arquitectónico que resuelve un sistema de CI de producción tiene cinco ejes que suelen entrar en tensión:

1. **Fan-out y concurrencia.** Un monorepo con 400 servicios puede disparar cientos de builds simultáneos ante un merge a `main`. El sistema debe planificar, encolar y escalar ejecución sin que un equipo ruidoso agote la capacidad de los demás (noisy-neighbor).
2. **Aislamiento y reproducibilidad.** Un runner persistente y compartido acumula estado (cachés envenenadas, credenciales filtradas entre jobs, binarios instalados por un build previo). El *build 1234 de hoy* debe producir el mismo resultado que dentro de seis meses.
3. **Cadena de suministro (supply chain).** El pipeline es el punto donde el código fuente se convierte en un artefacto ejecutable que correrá en producción. Es, literalmente, el objetivo de mayor valor para un atacante (SolarWinds, Codecov, event-stream). El pipeline debe **firmar y atestiguar** lo que produce.
4. **Coste y elasticidad.** Los runners "always-on" desperdician dinero fuera de horario pico; los efímeros pagan cold-start. La arquitectura decide dónde cae ese trade-off.
5. **Self-service seguro.** El developer debe poder definir su pipeline (pipeline-as-code) sin poder escalar privilegios, montar secretos ajenos ni escapar de su namespace.

### 1.1 El anti-patrón que estás reemplazando

```
┌──────────────────────────────────────────────────────────┐
│  Jenkins controller (pet, 1 VM, 200 plugins)             │
│    - Ejecutor "master" que también corre builds          │
│    - Agentes estáticos con Docker socket montado (root)  │
│    - Credenciales globales en el controller              │
│    - Estado en $JENKINS_HOME (SPOF, backup manual)       │
└──────────────────────────────────────────────────────────┘
        ▲  Blast radius = toda la organización
        ▲  Un plugin comprometido = RCE en todos los builds
        ▲  No hay tenancy real, no hay provenance
```

Frente a esto, la arquitectura cloud-native separa **definición**, **plano de control (orquestación)** y **plano de ejecución (runners efímeros)**, y hace de la seguridad de la cadena de suministro una propiedad del sistema, no un plugin.

---

## 2. Anatomía de un pipeline de CI (arquitectura de referencia)

Todo sistema de CI moderno — más allá del vendor — se descompone en las mismas capas. Reconocerlas es lo que el examen evalúa:

```
   [1] EVENT SOURCE            git push / PR / tag / cron / webhook / manual
        │
        ▼
   [2] TRIGGER / EVENT GATEWAY  valida firma HMAC, filtra (rama, path), extrae payload
        │                       (GitHub Actions events, Tekton EventListener, GitLab webhooks)
        ▼
   [3] CONTROL PLANE           interpreta la definición (pipeline-as-code),
       (orquestador)           resuelve el DAG, planifica jobs, gestiona estado,
                               reintentos, timeouts, matriz, dependencias
        │
        ▼
   [4] SCHEDULER / QUEUE       asigna trabajo a runners disponibles (labels/tags),
                               aplica cuotas y prioridades por tenant
        │
        ▼
   [5] EXECUTOR / RUNNER       ejecuta los steps en un entorno aislado
       (efímero)               (pod, contenedor, microVM). Monta workspace,
                               inyecta secretos, publica logs y results
        │
        ├──► [6] WORKSPACE / CACHE   volumen compartido entre steps + caché de deps
        ├──► [7] ARTIFACT STORE      registry OCI, object storage (SBOM, binarios, reports)
        └──► [8] STATUS FEEDBACK     commit status / checks API, notificaciones, métricas
```

### 2.1 DAG vs. stages secuenciales

El modelo de ejecución del orquestador determina paralelismo y expresividad.

| Modelo | Semántica | Paralelismo | Ejemplo |
|---|---|---|---|
| **Stages secuenciales** | Grupos ordenados; el stage N espera a *todo* el stage N-1 | Sólo dentro del stage; barrera entre stages | GitLab CI (`stages:`), Jenkins declarative stages |
| **DAG explícito** | Cada nodo declara sus dependencias (`runAfter` / `needs` / `dependencies`) | Máximo: un nodo corre en cuanto sus predecesores terminan | Tekton (`runAfter`), GitHub Actions (`needs`), Argo Workflows |
| **DAG + `finally`** | DAG más un conjunto de tareas garantizadas al final (cleanup) | Igual, con post-hooks siempre ejecutados | Tekton (`finally`), Actions (`if: always()`) |

**Trade-off clave:** el modelo por stages es más simple de razonar y auditar, pero introduce **barreras artificiales** (un test lento retrasa un build que no depende de él). El DAG maximiza el wall-clock throughput a costa de una definición más compleja y más difícil de visualizar. En producción, un monorepo grande **siempre** quiere DAG; un pipeline lineal de 4 pasos no gana nada con él.

---

## 3. Modelos de ejecución: topología de runners (comparativa)

La decisión de mayor impacto operativo es **qué es un runner** y **cuánto vive**.

| Topología | Aislamiento | Cold start | Reproducibilidad | Coste | Blast radius de un compromiso | Uso recomendado |
|---|---|---|---|---|---|---|
| **VM persistente compartida** | Débil (estado entre jobs) | ~0 s | Baja (drift acumulado) | Alto (idle) | **Toda la fila de builds** | Legacy; evitar |
| **Contenedor efímero en VM fija** | Media (namespace del contenedor) | 1–5 s (image pull) | Alta si la imagen es pinneada | Medio | El nodo host | CI mediana, Docker executor |
| **Pod efímero en Kubernetes** | Media-alta (pod + PSA + NetworkPolicy) | 3–15 s (schedule + pull) | Alta | Bajo (bin-packing + autoscaling) | El namespace / node según hardening | **Estándar cloud-native** |
| **microVM efímera (Firecracker/Kata)** | **Fuerte** (kernel aislado) | 5–20 s | Muy alta | Medio-alto | El propio microVM | Multi-tenant hostil, untrusted PRs |

**Ephemeral vs. persistente:** un runner **efímero** se registra, ejecuta **exactamente un** job y se destruye. Elimina la fuga de estado y de credenciales entre ejecuciones, y convierte "limpiar el runner" en "borrar el pod". El coste es el cold-start y la presión sobre el registry (image pulls). La mitigación estándar es un **warm pool** mínimo (`minRunners > 0`) más autoscaling.

> **Regla de producción:** para PRs de forks (código no confiable), **microVM o, como mínimo, pod efímero sin Docker socket, con `runAsNonRoot`, seccomp `RuntimeDefault` y sin credenciales de push**. Nunca un runner persistente con acceso al registry.

---

## 4. Comparativa de plataformas de CI

| Dimensión | **Tekton** | **GitHub Actions (+ ARC)** | **GitLab CI** | **Jenkins** | **Argo Workflows** |
|---|---|---|---|---|---|
| Definición | CRDs (`Task`,`Pipeline`) | YAML `.github/workflows` | `.gitlab-ci.yml` | Groovy `Jenkinsfile` | CRD `Workflow` |
| Plano de control | Controller K8s | SaaS GitHub | GitLab server | Controller (pet) | Controller K8s |
| Ejecución | Pod por `TaskRun` | Runner (VM/pod vía ARC) | Runner (shell/docker/k8s) | Agente (estático/k8s) | Pod por step |
| K8s-native | **Sí (nativo)** | Con ARC | Con k8s executor | Con plugin | **Sí (nativo)** |
| Modelo | DAG (`runAfter`) + `finally` | DAG (`needs`) + matrix | Stages + `needs` (DAG) | Stages | DAG / steps |
| Reutilización | `Task` en Artifact Hub | Reusable/composite actions | `include:` + templates | Shared libraries | `WorkflowTemplate` |
| Provenance/firma | **Tekton Chains (SLSA)** | Actions provenance + attest | SLSA vía plantilla | Manual | Vía integración |
| Fortaleza | Bloques CI/CD componibles y neutrales | Ecosistema y DX | Todo-en-uno integrado | Ubicuo, plugins | Orquestación de DAGs/ML |
| Debilidad | Verbosidad, curva de aprendizaje | Lock-in a GitHub, ARC opex | Acoplado a GitLab | Deuda técnica, seguridad | No es "CI" puro |

**Lectura para el examen:** en el contexto CNCF/cloud-native, **Tekton** es la referencia canónica porque modela el pipeline como recursos de Kubernetes (declarativo, GitOps-friendly, RBAC nativo, sin control plane externo). Es el eje del resto del capítulo.

---

## 5. Tekton en profundidad (la arquitectura CI cloud-native)

Tekton descompone el pipeline en CRDs. La jerarquía y sus API groups **actuales** (GA):

| CRD | API version | Rol | Recurso de ejecución |
|---|---|---|---|
| `Task` | `tekton.dev/v1` | Secuencia de `steps` (cada step = 1 contenedor) | `TaskRun` |
| `Pipeline` | `tekton.dev/v1` | DAG de `tasks` con `workspaces`, `params`, `results`, `finally` | `PipelineRun` |
| `EventListener` | `triggers.tekton.dev/v1beta1` | Recibe webhooks, valida, dispara | Pod + Service |
| `TriggerBinding` | `triggers.tekton.dev/v1beta1` | Extrae campos del payload | — |
| `TriggerTemplate` | `triggers.tekton.dev/v1beta1` | Instancia el `PipelineRun` | — |

Cada `step` corre como un contenedor **dentro del mismo pod** del `TaskRun`; los steps comparten el `emptyDir` `/workspace` y se ejecutan secuencialmente (Tekton reordena los entrypoints para forzar el orden). Cada `Task` del pipeline es **un pod distinto** — por eso los datos entre tasks viajan por un `Workspace` (PVC/volumen), no por el filesystem local.

### 5.1 `Task`: build de imagen con Kaniko (rootless-capable)

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: build-image
  labels:
    app.kubernetes.io/part-of: ci-paved-road
spec:
  description: >-
    Construye y publica una imagen OCI con Kaniko, sin daemon Docker.
    Emite el digest como result para trazabilidad y firma downstream.
  params:
    - name: IMAGE
      type: string
      description: Referencia completa de la imagen a publicar (repo:tag).
    - name: DOCKERFILE
      type: string
      default: ./Dockerfile
    - name: EXTRA_ARGS
      type: array
      default: []
  workspaces:
    - name: source
      description: Repo clonado por la task previa.
    - name: dockerconfig
      description: Secret con config.json del registry.
      optional: true
      mountPath: /kaniko/.docker
  results:
    - name: IMAGE_DIGEST
      description: Digest sha256 de la imagen publicada.
      type: string
    - name: IMAGE_URL
      description: Referencia publicada.
      type: string
  steps:
    - name: build-and-push
      image: gcr.io/kaniko-project/executor:v1.23.2
      workingDir: $(workspaces.source.path)
      securityContext:
        runAsUser: 0            # Kaniko requiere UID 0 para manipular el rootfs de build
      env:
        - name: DOCKER_CONFIG
          value: /kaniko/.docker
      command: ["/kaniko/executor"]
      args:
        - --dockerfile=$(params.DOCKERFILE)
        - --context=$(workspaces.source.path)
        - --destination=$(params.IMAGE)
        - --digest-file=$(results.IMAGE_DIGEST.path)
        - --reproducible
        - $(params.EXTRA_ARGS[*])
      computeResources:
        requests:
          cpu: "1"
          memory: 2Gi
        limits:
          memory: 4Gi
    - name: write-url
      image: cgr.dev/chainguard/busybox:latest
      script: |
        #!/bin/sh
        printf '%s' "$(params.IMAGE)" | tee "$(results.IMAGE_URL.path)"
```

> **Trade-off de aislamiento:** Kaniko construye sin daemon pero necesita UID 0 dentro del pod. Para tenancy hostil, la alternativa es **BuildKit rootless** (`--oci-worker-no-process-sandbox`) o `buildah` con user namespaces, que evitan root a costa de configuración extra. El examen valora que sepas que "build de imagen dentro de un pod" ≠ "montar `/var/run/docker.sock`" (anti-patrón: privilegios de nodo).

### 5.2 `Pipeline`: DAG completo con `workspaces`, `results` y `finally`

```yaml
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: build-test-push
spec:
  params:
    - name: repo-url
      type: string
    - name: revision
      type: string
      default: main
    - name: image-ref
      type: string
  workspaces:
    - name: shared-data
      description: Código fuente compartido entre tasks (PVC).
    - name: docker-credentials
      description: Credenciales del registry.
  results:
    - name: image-digest
      description: Digest de la imagen final.
      value: $(tasks.build-image.results.IMAGE_DIGEST)
  tasks:
    - name: fetch-source
      taskRef:
        name: git-clone          # instalada desde Tekton Hub / Catalog
      workspaces:
        - name: output
          workspace: shared-data
      params:
        - name: url
          value: $(params.repo-url)
        - name: revision
          value: $(params.revision)

    - name: unit-test
      runAfter: ["fetch-source"]
      taskRef:
        name: golang-test
      workspaces:
        - name: source
          workspace: shared-data

    - name: lint
      runAfter: ["fetch-source"]     # corre EN PARALELO con unit-test (DAG)
      taskRef:
        name: golangci-lint
      workspaces:
        - name: source
          workspace: shared-data

    - name: build-image
      runAfter: ["unit-test", "lint"]  # barrera: espera a ambos
      taskRef:
        name: build-image
      params:
        - name: IMAGE
          value: $(params.image-ref)
      workspaces:
        - name: source
          workspace: shared-data
        - name: dockerconfig
          workspace: docker-credentials

  finally:
    - name: report-status
      taskRef:
        name: send-slack
      params:
        - name: message
          value: >-
            Pipeline $(context.pipelineRun.name) terminó con estado
            $(tasks.build-image.status) — digest $(tasks.build-image.results.IMAGE_DIGEST)
```

El DAG resultante:

```
              ┌──────────► unit-test ──┐
fetch-source ─┤                        ├──► build-image ──► (finally) report-status
              └──────────► lint ───────┘
```

### 5.3 `PipelineRun`: la instancia de ejecución

```yaml
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: build-test-push-
spec:
  pipelineRef:
    name: build-test-push
  params:
    - name: repo-url
      value: https://github.com/acme/widget-api.git
    - name: revision
      value: main
    - name: image-ref
      value: registry.internal.acme.io/widget-api:$(context.pipelineRun.uid)
  taskRunTemplate:
    serviceAccountName: tekton-ci        # RBAC mínimo por tenant
    podTemplate:
      securityContext:
        fsGroup: 65532
      nodeSelector:
        workload: ci
      tolerations:
        - key: dedicated
          value: ci
          effect: NoSchedule
  workspaces:
    - name: shared-data
      volumeClaimTemplate:               # PVC efímero, borrado con el PipelineRun
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 1Gi
          storageClassName: ci-fast-ssd
    - name: docker-credentials
      secret:
        secretName: kaniko-registry-creds
  timeouts:
    pipeline: "1h0m0s"
    tasks: "45m0s"
```

> **Cuidado con `ReadWriteOnce`:** un `volumeClaimTemplate` RWO ata todos los `TaskRun` de ese workspace al **mismo nodo**. Si el cluster no puede colocar todos los pods ahí, el `PipelineRun` queda `Pending`. Para fan-out entre nodos, usar un `StorageClass` RWX (CephFS, EFS) o pasar datos por artefactos (OCI/object storage) en lugar de un PVC compartido. **Este es el fallo #1 de Tekton en producción.**

### 5.4 Triggers: del webhook al `PipelineRun`

`TriggerBinding` — extrae del payload de GitHub:

```yaml
apiVersion: triggers.tekton.dev/v1beta1
kind: TriggerBinding
metadata:
  name: github-push-binding
spec:
  params:
    - name: git-repo-url
      value: $(body.repository.clone_url)
    - name: git-revision
      value: $(body.after)
    - name: image-ref
      value: registry.internal.acme.io/$(body.repository.name):$(body.after)
```

`TriggerTemplate` — instancia el `PipelineRun`:

```yaml
apiVersion: triggers.tekton.dev/v1beta1
kind: TriggerTemplate
metadata:
  name: github-push-template
spec:
  params:
    - name: git-repo-url
    - name: git-revision
    - name: image-ref
  resourcetemplates:
    - apiVersion: tekton.dev/v1
      kind: PipelineRun
      metadata:
        generateName: build-test-push-
      spec:
        pipelineRef:
          name: build-test-push
        params:
          - name: repo-url
            value: $(tt.params.git-repo-url)
          - name: revision
            value: $(tt.params.git-revision)
          - name: image-ref
            value: $(tt.params.image-ref)
        workspaces:
          - name: shared-data
            volumeClaimTemplate:
              spec:
                accessModes: ["ReadWriteOnce"]
                resources:
                  requests:
                    storage: 1Gi
          - name: docker-credentials
            secret:
              secretName: kaniko-registry-creds
```

`EventListener` — el event gateway (valida HMAC y filtra la rama con CEL):

```yaml
apiVersion: triggers.tekton.dev/v1beta1
kind: EventListener
metadata:
  name: github-listener
spec:
  serviceAccountName: tekton-triggers-sa
  triggers:
    - name: github-push
      interceptors:
        - ref:
            name: github          # valida la firma HMAC del webhook
          params:
            - name: secretRef
              value:
                secretName: github-webhook-secret
                secretKey: token
            - name: eventTypes
              value: ["push"]
        - ref:
            name: cel             # filtra: sólo main
          params:
            - name: filter
              value: "body.ref == 'refs/heads/main'"
      bindings:
        - ref: github-push-binding
      template:
        ref: github-push-template
```

El `EventListener` crea un `Deployment` + `Service`; se expone al webhook de GitHub con un `Ingress`/`Route`. La validación HMAC (`github` interceptor) es **obligatoria**: sin ella, cualquiera puede disparar builds arbitrarios (DoS y, peor, con un `image-ref` derivado del payload, envenenamiento del registry).

---

## 6. Autoescalado de runners efímeros (patrón de plataforma)

Cuando la plataforma expone **GitHub Actions** como paved road pero la ejecución debe ocurrir dentro del cluster (data locality, secretos internos, coste), se usa **Actions Runner Controller (ARC)** con `gha-runner-scale-set`: runners **efímeros** que escalan a demanda según los jobs encolados.

Instalación (controller + scale set):

```bash
$ helm install arc \
    --namespace arc-systems --create-namespace \
    oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller
NAME: arc
STATUS: deployed
NAMESPACE: arc-systems

$ helm install k8s-runners \
    --namespace arc-runners --create-namespace \
    --set githubConfigUrl="https://github.com/acme" \
    --set githubConfigSecret.github_token="ghp_xxxxxxxxxxxx" \
    --set minRunners=1 \
    --set maxRunners=30 \
    --set runnerScaleSetName="k8s-runners" \
    --set 'containerMode.type=kubernetes' \
    oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set
NAME: k8s-runners
STATUS: deployed
```

Recurso generado y estado:

```bash
$ kubectl get autoscalingrunnerset -n arc-runners
NAME          MINIMUM   MAXIMUM   CURRENT   STATE      PENDING   RUNNING
k8s-runners   1         30        1         Running    0         0

# Al mergear 8 PRs, ARC escala runners efímeros:
$ kubectl get pods -n arc-runners
NAME                        READY   STATUS    RESTARTS   AGE
k8s-runners-abcd-runner-0   1/1     Running   0          12s
k8s-runners-abcd-runner-1   1/1     Running   0          12s
...
k8s-runners-abcd-runner-7   1/1     Running   0          11s
```

El workflow que los consume (`runs-on: k8s-runners`), con matrix, caché y firma keyless:

```yaml
name: ci
on:
  push:
    branches: [main]
  pull_request:
jobs:
  test:
    runs-on: k8s-runners
    strategy:
      fail-fast: false
      matrix:
        go: ["1.22", "1.23"]
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version: ${{ matrix.go }}
          cache: true                    # cachea ~/go/pkg/mod por go.sum
      - run: go test -race ./...

  build:
    needs: test
    runs-on: k8s-runners
    permissions:
      contents: read
      id-token: write                    # OIDC para cosign keyless
      packages: write
    steps:
      - uses: actions/checkout@v4
      - uses: docker/build-push-action@v6
        id: push
        with:
          push: true
          tags: ghcr.io/acme/widget-api:${{ github.sha }}
      - uses: sigstore/cosign-installer@v3
      - run: cosign sign --yes ghcr.io/acme/widget-api@${{ steps.push.outputs.digest }}
```

> **Modelo legacy vs. actual:** el ARC clásico (`actions.summerwind.dev/v1alpha1`, CRDs `RunnerDeployment` + `HorizontalRunnerAutoscaler`) sigue existiendo en la comunidad, pero la ruta soportada por GitHub es `gha-runner-scale-set` (`actions.github.com/v1alpha1`, CRD `AutoscalingRunnerSet`), que escala por **jobs encolados** en lugar de por webhooks/métricas, eliminando el race del autoscaler antiguo. Conocé la diferencia.

Para GitLab, el equivalente es el **Kubernetes executor**, que corre cada job como un pod efímero:

```toml
# config.toml del GitLab Runner
concurrent = 30
[[runners]]
  name = "k8s-runner"
  url = "https://gitlab.acme.io/"
  token = "glrt-xxxxxxxxxxxx"
  executor = "kubernetes"
  [runners.kubernetes]
    namespace = "gitlab-runners"
    image = "alpine:3.20"
    cpu_request = "500m"
    memory_request = "512Mi"
    poll_timeout = 600
    [runners.kubernetes.pod_security_context]
      run_as_non_root = true
      run_as_user = 65532
```

---

## 7. Caché y artefactos: la capa que decide el wall-clock

Dos flujos de datos distintos, con requisitos opuestos:

| Aspecto | **Caché** | **Artefacto** |
|---|---|---|
| Propósito | Acelerar builds (deps, capas) | Producto entregable (imagen, binario, SBOM, reporte) |
| Correctitud si falta | Indiferente (se reconstruye) | **Crítica** (rompe el downstream) |
| Clave | Hash de `go.sum`/`package-lock.json` | Digest inmutable |
| Almacén | Object storage / capa de registry | Registry OCI / object storage |
| Invalidación | Por cambio de lockfile | Nunca (inmutable, direccionado por contenido) |

**Anti-patrón:** cachear entre tenants con la misma clave → *cache poisoning* (un tenant inyecta un artefacto malicioso que otro consume). Las cachés deben estar **namespaced por tenant** y, para PRs de forks, **read-only o deshabilitadas**. Para pasar datos entre `TaskRun` de Tekton en distintos nodos, no uses un PVC RWX "porque sí": empujá el artefacto al registry OCI (`oras push`) y consumilo por digest — es inmutable, firmable y no ata la ejecución a un nodo.

---

## 8. Seguridad de la cadena de suministro en el pipeline

El pipeline debe emitir **provenance verificable**: quién construyó qué, desde qué fuente, con qué builder. El marco es **SLSA** (Supply-chain Levels for Software Artifacts), Build track v1.0:

| Nivel SLSA (Build track) | Garantía | Requisito de pipeline |
|---|---|---|
| **L1** | Existe provenance | El build genera atestación de cómo se hizo |
| **L2** | Provenance firmada + build service hospedado | Firma automática (no falsificable por el autor) |
| **L3** | Build endurecido, aislado, no falsificable | Runner efímero aislado, claves inaccesibles al build |

> Nota: SLSA v1.0 **eliminó el antiguo "L4"**; el Build track hoy es L1–L3. Un pod efímero de Tekton con Chains firmando fuera del contexto del build apunta a **L3**.

**Tekton Chains** observa cada `TaskRun`, genera una atestación in-toto/SLSA y la firma:

```bash
$ kubectl get pods -n tekton-chains
NAME                              READY   STATUS    RESTARTS   AGE
tekton-chains-controller-abc123   1/1     Running   0          9d

# Configurar formato SLSA + almacenamiento en el registry + transparencia (Rekor):
$ kubectl patch configmap chains-config -n tekton-chains --type merge -p '
data:
  artifacts.taskrun.format: "slsa/v2alpha3"
  artifacts.taskrun.storage: "oci"
  artifacts.oci.storage: "oci"
  transparency.enabled: "true"
'
configmap/chains-config patched
```

La clave de firma vive en el Secret `signing-secrets` del namespace `tekton-chains`, **fuera del alcance del pod de build** (propiedad L3). Verificación downstream con cosign:

```bash
$ cosign verify-attestation \
    --type slsaprovenance \
    --key k8s://tekton-chains/signing-secrets \
    registry.internal.acme.io/widget-api@sha256:9f2c...e41a | jq '.payload |= @base64d | .payload | fromjson | .predicate.builder'
{
  "id": "https://tekton.dev/chains/v2"
}
```

Si la verificación falla, el admission controller (p. ej. Kyverno/Sigstore policy-controller) **rechaza el deploy** — el pipeline y el runtime cierran el lazo.

---

## 9. Comandos CLI y salidas reales

Ciclo completo con el CLI de Tekton (`tkn`) y `kubectl`:

```bash
$ tkn pipeline start build-test-push \
    --param repo-url=https://github.com/acme/widget-api.git \
    --param revision=main \
    --param image-ref=registry.internal.acme.io/widget-api:main \
    --workspace name=shared-data,volumeClaimTemplateFile=pvc.yaml \
    --workspace name=docker-credentials,secret=kaniko-registry-creds \
    --serviceaccount tekton-ci \
    --showlog
PipelineRun started: build-test-push-run-4x8k2
Waiting for logs to be available...
```

Seguimiento de logs en vivo:

```bash
$ tkn pipelinerun logs build-test-push-run-4x8k2 -f
[fetch-source : clone] + git clone -v https://github.com/acme/widget-api.git /workspace/output
[fetch-source : clone] Cloning into '/workspace/output'...
[fetch-source : clone] HEAD is now at 9f2ce41 feat: add rate limiter

[unit-test : run] ok  	github.com/acme/widget-api/internal/api	0.412s
[lint : run] 0 issues.

[build-image : build-and-push] INFO[0002] Retrieving image manifest golang:1.23
[build-image : build-and-push] INFO[0041] Pushed registry.internal.acme.io/widget-api:main@sha256:9f2c...e41a
```

Estado agregado y por `TaskRun`:

```bash
$ kubectl get pipelinerun build-test-push-run-4x8k2
NAME                        SUCCEEDED   REASON      STARTTIME   COMPLETIONTIME
build-test-push-run-4x8k2   True        Succeeded   4m12s       58s

$ kubectl get taskrun -l tekton.dev/pipelineRun=build-test-push-run-4x8k2
NAME                                      SUCCEEDED   REASON      STARTTIME   COMPLETIONTIME
build-test-push-run-4x8k2-fetch-source    True        Succeeded   4m12s       3m50s
build-test-push-run-4x8k2-unit-test       True        Succeeded   3m48s       3m10s
build-test-push-run-4x8k2-lint            True        Succeeded   3m48s       3m22s
build-test-push-run-4x8k2-build-image     True        Succeeded   3m08s       58s

$ tkn pipelinerun describe build-test-push-run-4x8k2 -o jsonpath='{.status.results}'
[{"name":"image-digest","value":"sha256:9f2ce41a8b7d..."}]
```

---

## 10. Guía de verificación y diagnóstico de fallas

| Síntoma | Causa raíz probable | Diagnóstico | Remediación |
|---|---|---|---|
| `PipelineRun` en `Pending`/`Running` sin pods | PVC RWO no vinculable a un nodo, o falta capacidad | `kubectl describe pr <name>` → eventos; `kubectl get pvc`; `kubectl get events --sort-by=.lastTimestamp` | `StorageClass` RWX o WaitForFirstConsumer; ajustar `nodeSelector`; escalar node pool |
| `TaskRun` `Failed` con `ImagePullBackOff` | Imagen de step inaccesible / sin `imagePullSecret` | `kubectl describe pod <taskrun-pod>` | Añadir `imagePullSecrets` al `serviceAccountName`; pinnear digest |
| Push al registry `401/403` | Secret de credenciales mal montado en `/kaniko/.docker` | `tkn tr logs`; verificar `workspace dockerconfig` | Secret tipo `kubernetes.io/dockerconfigjson`; `mountPath` correcto |
| Datos vacíos entre tasks | Cada `Task` es un pod distinto; no comparten `/workspace` | Confirmar que ambas tasks referencian el **mismo** `workspace` | Declarar `workspaces` en pipeline y en cada task |
| Webhook no dispara nada | Firma HMAC inválida o filtro CEL descarta el evento | `kubectl logs deploy/el-github-listener`; revisar `Recent Deliveries` en GitHub | Verificar `github-webhook-secret`; revisar `filter` CEL |
| Runners ARC no aparecen | Token/PAT sin scope o `githubConfigUrl` errónea | `kubectl logs -n arc-systems deploy/arc-gha-rs-controller` | PAT con `repo`+`workflow`; validar URL de org/repo |
| Build no reproducible | Runner persistente con drift, o tags mutables (`:latest`) | Diff de dos builds; auditar imágenes de steps | Runners efímeros; **pinnear por digest**; `--reproducible` |
| Provenance no verifica | Chains mal configurado o clave rotada | `kubectl logs -n tekton-chains ...`; `cosign verify-attestation` | Revisar `chains-config`; re-firmar; validar `signing-secrets` |

Ejemplo de la falla #1 (PVC RWO no schedulable):

```bash
$ kubectl describe pipelinerun build-test-push-run-9zzz1 | tail -n 8
Events:
  Type     Reason            Age   From         Message
  ----     ------            ----  ----         -------
  Warning  Failed            30s   PipelineRun  TaskRun ... failed: pods "..." is
           forbidden: 0/6 nodes are available: 3 node(s) had volume node affinity
           conflict, 3 Insufficient cpu.

$ kubectl get pvc -l tekton.dev/pipelineRun=build-test-push-run-9zzz1
NAME                              STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS
pvc-build-test-push-run-9zzz1     Pending                                     ci-fast-ssd
```

**Checklist de verificación de un pipeline nuevo (paved road):**

1. `tkn task list` / `tkn pipeline list` → los recursos existen en el namespace del tenant.
2. `PipelineRun` de prueba con `--dry-run`/manual → el DAG resuelve y termina `Succeeded`.
3. `kubectl auth can-i --as=system:serviceaccount:<ns>:tekton-ci ...` → RBAC mínimo, no puede leer secretos ajenos.
4. Webhook end-to-end: push real → `EventListener` recibe → `PipelineRun` generado (`kubectl get pr -w`).
5. `cosign verify-attestation` sobre la imagen → provenance SLSA presente y válida.
6. Runner efímero se destruye tras el job (`kubectl get pods -w` no deja pods `Completed` colgados).

---

## 11. Referencias

- CNPA — CNCF Certification Curriculum (fuente del temario): https://github.com/cncf/curriculum
- CNCF TAG App Delivery — CI/CD y Platforms WG: https://tag-app-delivery.cncf.io/
- Tekton — documentación general: https://tekton.dev/docs/
- Tekton Pipelines (`Task`, `Pipeline`, `PipelineRun`, `Workspaces`, `Results`): https://tekton.dev/docs/pipelines/
- Tekton Triggers (`EventListener`, `TriggerBinding`, `TriggerTemplate`, interceptores): https://tekton.dev/docs/triggers/
- Tekton Chains (provenance y firma SLSA): https://tekton.dev/docs/chains/
- GitHub Actions — Actions Runner Controller (ARC): https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners-with-actions-runner-controller
- GitHub Actions — sintaxis de workflows: https://docs.github.com/en/actions/using-workflows/workflow-syntax-for-github-actions
- GitLab Runner — Kubernetes executor: https://docs.gitlab.com/runner/executors/kubernetes/
- Argo Workflows: https://argo-workflows.readthedocs.io/en/latest/
- SLSA — especificación v1.0 (Build track): https://slsa.dev/spec/v1.0/
- Sigstore cosign — firma y verificación keyless: https://docs.sigstore.dev/
- in-toto — atestaciones de cadena de suministro: https://in-toto.io/
- Kaniko — build de imágenes sin daemon: https://github.com/GoogleContainerTools/kaniko