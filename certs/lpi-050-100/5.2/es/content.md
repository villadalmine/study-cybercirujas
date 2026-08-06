# LPI Open Source Essentials (050-100) — Topic 5.2: Product Management / Release Management

## 1. Motivación y problemas arquitectónicos en producción

En arquitecturas de microservicios de alta concurrencia, el software release management conecta el desarrollo de código con la confiabilidad de la infraestructura. Los procesos de release ingenuos causan fallas en cascada en producción, rupturas silenciosas de API y un mean time to recovery (MTTR) prolongado.

```
 +-----------------------------------------------------------------------------------+
 |                             UNCONTROLLED RELEASE PATH                             |
 |                                                                                   |
 |  [ Developer Commit ] ---> [ Mutable Tag :latest ] ---> [ All-at-Once Deploy ]    |
 |                                                                  |                |
 |                                                                  v                |
 |                                                       [ 100% Traffic Impact ]     |
 |                                                                  |                |
 |                                                                  v                |
 |                                                       [ Cascading Failures ]      |
 +-----------------------------------------------------------------------------------+

 +-----------------------------------------------------------------------------------+
 |                      ENTERPRISE SRE PROGRESSIVE RELEASE PATH                      |
 |                                                                                   |
 |  [ Developer Commit ] ---> [ SemVer 2.0.0 Tag ] ---> [ Immutable Build (Digest) ] |
 |                                                                  |                |
 |                                                                  v                |
 |                                                       [ Cosign Supply-Chain ]     |
 |                                                                  |                |
 |                                                                  v                |
 |                                                       [ Argo Canary Rollout ]     |
 |                                                                  |                |
 |                                        +-------------------------+----------------+
 |                                        |                                          |
 |                                        v                                          v
 |                                [ Metric Pass ]                            [ Metric Fail ]
 |                                        |                                          |
 |                                        v                                          v
 |                                [ 100% Release ]                          [ Automated Rollback ]
 +-----------------------------------------------------------------------------------+
```

### Principales vectores de falla en releases de producción

1. **Semantic Versioning Drift y breaking changes no comunicados**: Los microservicios upstream que consumen dependencias etiquetadas con restricciones flotantes (por ejemplo, `^1.2.0` o `latest`) ingieren modificaciones rompedoras de API cuando un patch o minor release altera estructuras de datos o elimina endpoints.
2. **Bloqueo de estado y esquema de base de datos**: Desplegar binarios de aplicación que dependen de cambios de esquema no compatibles hacia atrás (por ejemplo, eliminación de columnas) de forma simultánea al 100% de las instancias de la carga de trabajo imposibilita la ejecución concurrente de versiones antiguas y nuevas de la aplicación, resultando en bloqueos inmediatos de la base de datos o corrupción irrecuperable de datos.
3. **Mutabilidad de artefactos y compromiso de la supply-chain**: Volver a etiquetar imágenes de contenedor con tags mutables (por ejemplo, `v1.2-latest` o `main`) crea un scheduling de Pods no determinista, donde los nodos dentro del mismo cluster de Kubernetes descargan diferentes digests binarios subyacentes para exactamente el mismo tag de imagen.
4. **Blast radius de despliegue simultáneo (All-at-Once)**: Desplegar actualizaciones en toda una flota sin una configuración progresiva de tráfico o análisis de telemetría en tiempo real amplifica los errores críticos, impactando al 100% del tráfico de usuarios de forma instantánea.

---

## 2. Tablas de comparación técnica y trade-offs

### 2.1 Ciclos de software release

| Dimensión | Long-Term Support (LTS) | Standard Feature Release | Rolling Release | Nightly / Edge Build |
| :--- | :--- | :--- | :--- | :--- |
| **Cadencia** | 12 – 36 meses | 1 – 3 meses | Continuo (por commit) | Diario (automatizado) |
| **Nivel de estabilidad** | Muy alto (backports strictly controlados) | Alto (Feature complete) | Moderado (posibles bugs transitorios) | Bajo (Bleeding edge) |
| **Horizonte de mantenimiento** | 3 – 5 años | 6 – 12 meses | N/A (Solo el último commit) | Ninguno |
| **Riesgo operativo SRE** | Baja velocidad de cambio, ventanas de mantenimiento predecibles | Se requieren rutas de migración controladas | Se requiere alta validación continua | Alto; prohibido en producción |
| **Objetivo en producción** | Infraestructura core (OS, control plane de Kubernetes, RDBMS) | Microservicios de aplicaciones de negocio | Herramientas internas de rápida evolución, entornos de desarrollo | Canary testing y pruebas de integración de CI |

### 2.2 Estrategias de versionado

| Métrica / Característica | Semantic Versioning (SemVer 2.0.0) | Calendar Versioning (CalVer) | Hash / Commit Versioning |
| :--- | :--- | :--- | :--- |
| **Estructura de formato** | `MAJOR.MINOR.PATCH` | `YYYY.0M.0D` o `YY.MINOR` | `git-sha` (por ejemplo, `7a2f9b1`) |
| **Señalización de breaking changes** | Explícita mediante incremento de `MAJOR` | Implícita (comunicada a través de cronogramas de deprecación) | Ninguna |
| **Resolución de dependencias** | Soportado nativamente por gestores de dependencias (`npm`, `cargo`, `go`) | Limitado en el tiempo; requiere auditoría manual | Requiere lockfiles o fijaciones específicas en manifiestos |
| **Caso de uso principal** | Librerías reutilizables, APIs, Helm Charts, SDKs públicos | Sistemas operativos (Ubuntu), utilidades CLI (YouTube-dl) | Microservicios internos desplegados continuamente |

### 2.3 Mecánicas de despliegue y release

| Estrategia | Zero Downtime | Overhead de costo de infraestructura | Velocidad de Rollback | Granularidad de control de tráfico | Blast Radius |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Blue/Green** | Sí | 100% (Requiere cluster/flota duplicada) | Instantánea (DNS / Switch routing) | Binaria (0% o 100%) | Alto durante el switchover |
| **Canary Deployment** | Sí | Bajo (5% – 20% de Pods extra temporales) | Rápida (Escalado hacia abajo de Pods canary) | Precisa (incrementos a pasos del 1%) | Mínimo (subconjunto controlado) |
| **Rolling Update** | Sí | Bajo (Controlado por `maxSurge`/`maxUnavailable`) | Lenta (Requiere reemplazo secuencial inverso) | Gruesa (Basada en la cantidad de Pods) | Alto (Todos los Pods actualizados con el tiempo) |
| **Shadow / Mirroring** | Sí | 100% (Cómputo extra para peticiones duplicadas) | N/A (No impacta el tráfico de cara al usuario) | Replicación de payload en tiempo real | Cero (Sin impacto en usuarios en vivo) |

### 2.4 Flujos de trabajo de branching y release management

| Atributo | Trunk-Based Development | GitFlow | Release-Branch Workflow |
| :--- | :--- | :--- | :--- |
| **Ciclo de vida de ramas** | Feature branches de corta duración (<24h) | Ramas de larga duración `develop`, `master`, feature, release, hotfix | Rama `main` con ramas `release-vX.Y` dedicadas |
| **Frecuencia de merge** | Múltiples veces al día | Bisemanal o mensual | Por hito de release |
| **Mecanismo de release** | Automatizado desde `main` mediante feature flags | Preparación manual de la rama release y merge de retorno | Tags automatizados desde ramas release dedicadas |
| **Complejidad de CI/CD** | Alto requerimiento de pruebas automatizadas; feature flags | Alta complejidad en la orquestación de merge de Git | Moderada; mantenimiento de backports aislado |

---

## 3. Implementaciones completas de infraestructura y manifiestos

### 3.1 Pipeline automatizado de production release en GitHub Actions (`.github/workflows/release.yaml`)

```yaml
name: Production Release Engineering Pipeline

on:
  push:
    branches:
      - main

permissions:
  contents: write
  packages: write
  id-token: write

jobs:
  semantic-release:
    name: Execute Semantic Release & Package Artifacts
    runs-on: ubuntu-latest
    outputs:
      new_release_published: ${{ steps.semantic.outputs.new_release_published }}
      new_release_version: ${{ steps.semantic.outputs.new_release_version }}
      new_release_git_tag: ${{ steps.semantic.outputs.new_release_git_tag }}
    steps:
      - name: Checkout Source Code
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Setup Node.js Environment
        uses: actions/setup-node@v4
        with:
          node-version: 20.x

      - name: Install Semantic Release Dependencies
        run: |
          npm install -g \
            semantic-release@22.0.12 \
            @semantic-release/git@10.0.1 \
            @semantic-release/changelog@6.0.3 \
            @semantic-release/exec@6.0.3

      - name: Run Semantic Release
        id: semantic
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          npx semantic-release

  build-and-sign:
    name: Build OCI Image, Sign & Generate SLSA Attestation
    needs: semantic-release
    if: needs.semantic-release.outputs.new_release_published == 'true'
    runs-on: ubuntu-latest
    env:
      REGISTRY: ghcr.io
      IMAGE_NAME: ${{ github.repository }}
      VERSION: ${{ needs.semantic-release.outputs.new_release_version }}
    steps:
      - name: Checkout Source Code
        uses: actions/checkout@v4

      - name: Install Cosign CLI
        uses: sigstore/cosign-installer@v3.3.0

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3.1.0

      - name: Log in to GitHub Container Registry
        uses: docker/login-action@v3.0.0
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and Push OCI Image by Digest
        id: build-image
        uses: docker/build-push-action@v5.1.0
        with:
          context: .
          push: true
          tags: |
            ghcr.io/${{ github.repository }}:${{ env.VERSION }}
            ghcr.io/${{ github.repository }}:latest
          provenance: true
          sboms: true

      - name: Sign OCI Container Image Keylessly with Cosign
        env:
          IMAGE_DIGEST: ${{ steps.build-image.outputs.digest }}
        run: |
          cosign sign --yes "ghcr.io/${{ github.repository }}@${{ env.IMAGE_DIGEST }}"
```

---

### 3.2 Manifiesto de Argo Rollouts para Progressive Canary (`base/argo-rollout-canary.yaml`)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: payment-service-rollout
  namespace: production
  labels:
    app.kubernetes.io/name: payment-service
    app.kubernetes.io/part-of: core-banking
    app.kubernetes.io/version: "2.4.0"
spec:
  replicas: 10
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app: payment-service
  template:
    metadata:
      labels:
        app: payment-service
        app.kubernetes.io/name: payment-service
    spec:
      containers:
        - name: payment-service
          image: ghcr.io/enterprise/payment-service:2.4.0
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          env:
            - name: PORT
              value: "8080"
            - name: NODE_ENV
              value: "production"
          resources:
            requests:
              cpu: "250m"
              memory: "512Mi"
            limits:
              cpu: "1000m"
              memory: "1Gi"
          readinessProbe:
            httpGet:
              path: /healthz/ready
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /healthz/live
              port: http
            initialDelaySeconds: 15
            periodSeconds: 20
  strategy:
    canary:
      canaryService: payment-service-canary
      stableService: payment-service-stable
      trafficRouting:
        nginx:
          stableIngress: payment-service-ingress
      analysis:
        templates:
          - templateName: success-rate-analysis
        args:
          - name: service-name
            value: payment-service-canary
      steps:
        - setWeight: 5
        - pause: { duration: 10m }
        - setWeight: 20
        - pause: { duration: 30m }
        - setWeight: 50
        - pause: { duration: 1h }
---
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: success-rate-analysis
  namespace: production
spec:
  metrics:
    - name: success-rate
      interval: 1m
      successCondition: result[0] >= 0.999
      failureLimit: 3
      provider:
        prometheus:
          address: http://prometheus-k8s.monitoring.svc.cluster.local:9090
          query: |
            sum(rate(http_requests_total{app="payment-service-canary", status!~"5.*"}[2m]))
            /
            sum(rate(http_requests_total{app="payment-service-canary"}[2m]))
```

---

### 3.3 Empaquetado y metadatos de versión de Helm Chart (`helm/Chart.yaml` y `helm/values.yaml`)

```yaml
# helm/Chart.yaml
apiVersion: v2
name: payment-service
description: High-throughput banking payment service Helm release package
type: application
version: 2.4.0
appVersion: "2.4.0"
kubeVersion: ">=1.26.0"
maintainers:
  - name: Platform SRE Team
    email: sre-core@enterprise.io
dependencies:
  - name: common-library
    version: 1.3.2
    repository: https://charts.enterprise.io/internal
```

```yaml
# helm/values.yaml
replicaCount: 10

image:
  repository: ghcr.io/enterprise/payment-service
  pullPolicy: IfNotPresent
  tag: "2.4.0"

strategy:
  type: Canary
  canarySteps:
    - weight: 5
      pause: 600s
    - weight: 20
      pause: 1800s
    - weight: 50
      pause: 3600s

resources:
  limits:
    cpu: 1000m
    memory: 1Gi
  requests:
    cpu: 250m
    memory: 512Mi

metrics:
  enabled: true
  prometheusRule:
    enabled: true
    thresholds:
      errorRatePercent: 0.1
```

---

## 4. Comandos CLI reales y salidas esperadas de terminal

### 4.1 Cálculo automatizado de versión mediante `git-cliff` / `semantic-release`

```bash
$ git log --oneline -n 5
a8f9c1d feat(payment): add support for ISO20022 SEPA instant settlement transfers
3b12e4f fix(auth): resolve memory leak in JWT verification middleware
9c8d7e6 docs(readme): update API documentation URLs
1a2b3c4 chore(deps): bump golang.org/x/net from 0.17.0 to 0.19.0
5e6f7a8 ci(github): enable strict OIDC token verification

$ npx semantic-release --dry-run
[7:14:02 PM] [semantic-release] › i Loading plugin 'semantic-release-git'
[7:14:02 PM] [semantic-release] › i Found git tag v2.3.4 associated with version 2.3.4 on branch main
[7:14:03 PM] [semantic-release] › i Analyzing commit: feat(payment): add support for ISO20022 SEPA instant settlement transfers
[7:14:03 PM] [semantic-release] › i The release type for commit 'feat(payment): add support...' is minor
[7:14:03 PM] [semantic-release] › i Analysis of 5 commits complete: minor release recommended
[7:14:03 PM] [semantic-release] › i The next release version is 2.4.0
[7:14:03 PM] [semantic-release] › i Dry run complete. Proposed version: 2.4.0 (Tag: v2.4.0)
```

---

### 4.2 Empaquetado e inspección de artefactos OCI Helm Release

```bash
$ helm package helm/ --destination build/
Successfully packaged chart and saved it to: build/payment-service-2.4.0.tgz

$ helm push build/payment-service-2.4.0.tgz oci://ghcr.io/enterprise/charts
Pushed: ghcr.io/enterprise/charts/payment-service:2.4.0
Digest: sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855

$ helm inspect chart oci://ghcr.io/enterprise/charts/payment-service:2.4.0
apiVersion: v2
appVersion: 2.4.0
description: High-throughput banking payment service Helm release package
name: payment-service
type: application
version: 2.4.0
```

---

### 4.3 Verificación de firma keyless de imágenes OCI con Cosign

```bash
$ cosign verify \
  --certificate-identity-regexp "https://github.com/enterprise/payment-service/.github/workflows/release.yaml@refs/heads/main" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  ghcr.io/enterprise/payment-service:2.4.0

Verification for ghcr.io/enterprise/payment-service:2.4.0 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Claims below were verified against the signature issuer certificate:
    - Subject: https://github.com/enterprise/payment-service/.github/workflows/release.yaml@refs/heads/main
    - Issuer: https://token.actions.githubusercontent.com
[{"critical":{"identity":{"docker-reference":"ghcr.io/enterprise/payment-service"},"image":{"docker-manifest-digest":"sha256:d894b9101b44b82d49575e921d7b3281747805efd3e38708c3529367d3e69123"},"type":"cosign container image signature"}}]
```

---

### 4.4 Ejecución de tráfico Progressive Canary en Argo Rollouts e inspección de telemetría

```bash
$ kubectl argo rollouts get rollout payment-service-rollout -n production
Name:            payment-service-rollout
Namespace:       production
Status:          WaitTrack
Strategy:        Canary
  Step:          1/6 (setWeight: 5)
  SetWeight:     5
  ActualWeight:  5
Images:          ghcr.io/enterprise/payment-service:2.3.4 (stable)
                 ghcr.io/enterprise/payment-service:2.4.0 (canary)
Replicas:
  Desired:       10
  Current:       10
  Updated:       1
  Ready:         10
  Available:     10

NAME                                                     KIND        STATUS        AGE    INFO
WaitTrack payment-service-rollout                        Rollout     Paused        4m12s  
├──#revision:12                                          ReplicaSet  Healthy       14d    stable
│  ├──payment-service-rollout-5d4b8f9c7-12abc            Pod         Running       14d    ready:1/1
│  ├──payment-service-rollout-5d4b8f9c7-34def            Pod         Running       14d    ready:1/1
│  └──... (7 additional stable pods)
└──#revision:13                                          ReplicaSet  Healthy       4m12s  canary
   └──payment-service-rollout-7f8a9b0c1-99xyz            Pod         Running       4m05s  ready:1/1

NAME                                                     TYPE        STATUS        AGE    INFO
success-rate-analysis.13                                 AnalysisRun Successful    4m00s  pass:4
```

---

### 4.5 Ejecución de un rollback automatizado de emergencia

```bash
$ kubectl argo rollouts undo payment-service-rollout -n production
rollout.argoproj.io/payment-service-rollout undone

$ kubectl argo rollouts status payment-service-rollout -n production
Process Status: Rollout is fully rolled back to revision 12 (Image: ghcr.io/enterprise/payment-service:2.3.4)
Replicas: 10/10 stable pods running. Canary pods terminated.
```

---

## 5. Guía de verificación y diagnóstico

### 5.1 Modos de falla sistémicos en releases y protocolos de diagnóstico

```
+---------------------------------------------------------------------------------------------------------+
|                                    RELEASE TROUBLESHOOTING MATRIX                                       |
+------------------------------------+----------------------------------+---------------------------------+
| Symptom / Error                    | Root Cause                       | Remediation Protocol            |
+------------------------------------+----------------------------------+---------------------------------+
| Kyverno ImagePolicyDenied          | Unsigned OCI container image     | Execute cosign sign or re-run   |
|                                    | pushed to production registry    | pipeline with OIDC token        |
+------------------------------------+----------------------------------+---------------------------------+
| Argo Rollout Degraded              | Canary metric breach             | Automated rollback triggered;   |
| (AnalysisRun Failed)               | (Prometheus HTTP 5xx > 0.1%)     | inspect container crash logs    |
+------------------------------------+----------------------------------+---------------------------------+
| SemVer Conflict                    | Breaking change published in     | Y-stream rollback; bump MAJOR   |
| (Client panic on payload response) | MINOR release version            | version tag (e.g. 2.x -> 3.0.0) |
+------------------------------------+----------------------------------+---------------------------------+
```

#### Paso de diagnóstico 1: Verificar la atestación de imagen y firmas de Cosign
Si la creación de Pods en Kubernetes es bloqueada por motores de políticas (Kyverno o OPA Gatekeeper) debido a tags de imagen no firmados:

```bash
# Check Kyverno policy enforcement logs
$ kubectl get cve -A
$ kubectl get clusterpolicy enforce-signed-images -o yaml

# Inspect OCI image signatures directly on the registry
$ cosign tree ghcr.io/enterprise/payment-service:2.4.0
└── Signatures for image tag: ghcr.io/enterprise/payment-service:2.4.0
    └── digest: sha256:d894b9101b44b82d49575e921d7b3281747805efd3e38708c3529367d3e69123
        ├── Signature sha256:a1b2c3d4... verified!
        └── Certificate Subject: https://github.com/enterprise/payment-service/.github/workflows/release.yaml@refs/heads/main
```

#### Paso de diagnóstico 2: Depurar el análisis fallido de Progressive Canary
Cuando un Argo Rollout se detiene en el paso `N` e inicia un rollback debido a transgresiones en los umbrales de métricas:

```bash
# Obtain the active AnalysisRun status
$ kubectl get analysisrun -n production -l rollout=payment-service-rollout

# Output detailed metric evaluation results
$ kubectl get analysisrun success-rate-analysis-7f8a9b0c1 -n production -o jsonpath='{.status}' | jq .
{
  "metricResults": [
    {
      "consecutiveFailures": 3,
      "count": 4,
      "failed": 3,
      "measurements": [
        {
          "finishedAt": "2026-08-06T19:10:00Z",
          "phase": "Failed",
          "value": "[0.9782]"
        }
      ],
      "name": "success-rate",
      "phase": "Failed"
    }
  ],
  "phase": "Failed"
}
```
*Diagnóstico*: La tasa de éxito medida fue `0.9782` (97.82%), cayendo por debajo de la condición de SLA obligatoria de `0.999` (99.9%) definida en el `AnalysisTemplate`. Argo Rollouts detuvo correctamente el paso canary y activó un rollback automatizado e inmediato a la revisión 12.

---

## 6. Referencias

- Linux Professional Institute (LPI) Open Source Essentials Objectives: https://www.lpi.org/our-certifications/open-source-essentials-overview/
- Especificación Semantic Versioning 2.0.0: https://semver.org/spec/v2.0.0.html
- Supply-chain Levels for Software Artifacts (SLSA): https://slsa.dev/spec/v1.0/about
- Documentación de firmas de imágenes de contenedor con Sigstore Cosign: https://docs.sigstore.dev/cosign/overview/
- Documentación del controlador de Progressive Delivery Argo Rollouts: https://argoproj.github.io/argo-rollouts/
- Arquitectura y especificaciones OCI de CNCF Artifact Hub: https://artifacthub.io/docs/
- Proyectos de Continuous Delivery de la Cloud Native Computing Foundation (CNCF): https://www.cncf.io/projects/