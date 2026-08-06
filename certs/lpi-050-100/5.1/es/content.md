# LPI 050-100: Open Source Essentials — Tema 5.1: Modelos de desarrollo de software

---

## 1. Motivación de producción y declaración del problema arquitectónico

En la ingeniería de plataformas empresariales y Site Reliability Engineering (SRE), los modelos de desarrollo de software dictan directamente la velocidad operativa de una organización, la disponibilidad del sistema y su perfil de resiliencia. Históricamente, la industria del software sufrió del **Wall of Confusion**: una profunda desconexión arquitectónica y cultural entre los equipos de Desarrollo (optimizados para la velocidad de cambio) y los equipos de Operaciones/SRE (optimizados para la estabilidad de la infraestructura).

```
         LEGACY: THE WALL OF CONFUSION
+-------------------+      +-------------------+
|    Development    |      |    Operations     |
| (Velocity Driven) |      | (Stability Driven)|
| - Long Feature    | ---> | - Manual Gates    |
|   Branches        |  W   | - Complex Deploys |
| - Big-Bang Builds |  A   | - High Failure    |
| - Monolithic Code |  L   |   Rates           |
+-------------------+  L   +-------------------+
                         |
                         v
            HIGH MTTR & LEAD TIME FOR CHANGES

-----------------------------------------------------

         MODERN: GITOPS & SRE RECONCILIATION
+---------------------------------------------------+
|          Single Source of Truth (Git)             |
|   Trunk-Based Dev + Automated CI/CD + Feature Flags|
+---------------------------------------------------+
                         |
             Continuous Reconciliation
                         v
+---------------------------------------------------+
|         Declarative Infrastructure Loop           |
| (ArgoCD / Kubernetes Operators / Automated Drift) |
+---------------------------------------------------+
                         |
                         v
             DORA ELITE PERFORMANCE:
  Low Lead Time | High Frequency | Low MTTR | Low CFR
```

### Modos de fallo arquitectónico de los modelos tradicionales
1. **Modelos Secuenciales y Waterfall**: Enfatizan una separación rígida de fases (Requirements $\rightarrow$ Design $\rightarrow$ Implementation $\rightarrow$ Verification $\rightarrow$ Maintenance). En entornos de producción, esto resulta en **big-bang releases** donde se acumulan meses de cambios de código no probados. El blast radius de los deployments se escala de forma no lineal con el tamaño del release, causando picos catastróficos en el Mean Time to Restore (MTTR) y elevadas Change Failure Rates (CFR).
2. **Modelos de desarrollo Cathedral vs. Bazaar**: Formulados por Eric S. Raymond en el contexto del software de código abierto:
   - **El Modelo Cathedral**: El desarrollo se restringe a un grupo exclusivo de desarrolladores principales (core developers). Los releases de código fuente ocurren con poca frecuencia entre milestones oficiales. El control arquitectónico está fuertemente centralizado, lo que limita la revisión por pares externa y crea ventanas prolongadas de exposición a bugs.
   - **El Modelo Bazaar**: El desarrollo ocurre en entornos públicos y altamente distribuidos donde el código se envía tempranamente y se publica a menudo. Fundado en la **Ley de Linus** (*"Given enough eyeballs, all bugs are shallow"*), este modelo aprovecha el paralelismo masivo de la comunidad, las pruebas descentralizadas y los bucles de retroalimentación continua.
3. **Cuellos de botella de las estrategias de branching**: Las estrategias complejas de branching (por ejemplo, feature branches de larga duración en Gitflow heredado) introducen un severo **merge debt**. La divergencia de ramas aleja el esfuerzo de los ingenieros de las funcionalidades del producto hacia la resolución compleja de conflictos, rompiendo la reproducibilidad local y las garantías de Continuous Integration.

### Paradigma de solución moderno: DevOps, SRE y GitOps
La ingeniería de plataformas moderna reemplaza los release gates manuales con bucles de retroalimentación continuos y automatizados. Al combinar **Trunk-Based Development (TBD)**, **Continuous Integration/Continuous Delivery (CI/CD)** y **bucles de reconciliación de GitOps**, las organizaciones alcanzan las cuatro métricas clave de DORA (Four Key DORA Metrics):
- **Deployment Frequency**: Múltiples deployments a producción por día.
- **Lead Time for Changes**: Menos de una hora desde el commit del código hasta el estado de ejecución en producción.
- **Mean Time to Restore (MTTR)**: Rollback automatizado e instantáneo (< 5 minutos) ante fallas en los health checks.
- **Change Failure Rate (CFR)**: Reducida mediante análisis estático automatizado, canary rollouts y aislamiento con feature flags.

---

## 2. Comparaciones técnicas y tablas de trade-offs

### Tabla 1: Matriz de trade-offs de modelos de desarrollo de software y release

| Métrica / Dimensión | Waterfall (Secuencial) | Cathedral (OSS cerrado) | Agile (Scrum / Kanban) | Bazaar (OSS distribuido) | DevOps & GitOps (SRE/Plataforma) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Alineación de arquitectura** | Componentes monolíticos fuertemente acoplados | Monolitos centralizados o librerías específicas | Monolitos modulares o enfocados a servicios | Arquitecturas modulares, impulsadas por API y plugins | Microservicios, Cloud-Native, CRDs declarativos |
| **Cadencia de release** | Meses a años | Milestones semestrales / anuales | Sprints quincenales / semanales | Merges de PR continuos / asincrónicos | Continuo (Múltiples deployments por día) |
| **Lead Time for Changes** | Extremo (> 90 días) | Alto (30–180 días) | Medio (1–2 semanas) | Variable (Horas a días) | Bajo (< 1 hora) |
| **Change Failure Rate (CFR)** | Alto (> 30%) | Moderado (15–30%) | Moderado (10–20%) | Bajo a moderado (5–15%) | Muy bajo (< 5%) |
| **MTTR (Velocidad de recuperación)** | Días a semanas | Días | Horas a días | Horas | Segundos a minutos (Rollback automatizado) |
| **Configuration Drift** | Crónico entre entornos | Alineación binaria manual | Variación ambiental moderada | Alta entre entornos de colaboradores | Inexistente (Reconciliación declarativa) |
| **Gobernanza y control** | Comité de dirección centralizado | Core Maintainer Gatekeepers | Product Owner / Scrum Master | Consenso de mantenedores / Dictador benévolo | Motores de políticas automatizados (OPA/Kyverno) |
| **Mitigación del blast radius** | Deficiente (Release todo o nada) | Baja (Entregas binarias infrecuentes) | Moderada (Alcance de sprint) | Alta (Releases de módulos independientes) | Élite (Canary, Blue/Green, progresivo) |

### Tabla 2: Matriz arquitectónica de estrategias de branching de código fuente

| Estrategia | Frecuencia de integración | Complejidad de conflictos de merge | Velocidad de feedback de CI/CD | Disponibilidad para producción (Production Readiness) | Mejor caso de uso (Best Fit Use Case) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Gitflow** | Baja (Al completar la funcionalidad) | Alta (Drift en feature branches de larga duración) | Retardada (Pruebas posteriores al merge) | Restringida por release branches | Sistemas empresariales heredados con releases trimestrales rígidos |
| **GitHub Flow** | Moderada (Por Pull Request) | Moderada | Media (Al hacer push del PR) | La rama main siempre es desplegable | Aplicaciones web y equipos SaaS de pequeño a mediano tamaño |
| **Trunk-Based Development (TBD)** | Alta (Múltiples veces por día hacia `main`) | Baja (Commits pequeños y de corta duración < 24h) | Rápida (Bucle de build/test < 10 min) | Siempre desplegable mediante Feature Flags | Equipos SRE de alta velocidad, GitOps y Microservicios |

---

## 3. Manifiestos YAML y configuraciones de infraestructura sintácticamente válidos completos

### Manifiesto 1: Pipeline de CI de producción basado en Trunk (`.github/workflows/ci-trunk-pipeline.yaml`)

```yaml
name: Production Trunk-Based Integration Pipeline

on:
  push:
    branches:
      - main
  pull_request:
    branches:
      - main

permissions:
  contents: read
  packages: write
  security-events: write

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  static-analysis-and-unit-tests:
    name: Code Quality & Unit Testing
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - name: Checkout Source Code
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Setup Go Environment
        uses: actions/setup-go@v5
        with:
          go-version: '1.22'
          check-latest: true
          cache: true

      - name: Run Static Security Analysis (golangci-lint)
        uses: golangci/golangci-lint-action@v4
        with:
          version: v1.55.2
          args: --timeout=5m --enable=gosec,govet,revive

      - name: Execute Unit & Integration Tests with Coverage
        run: |
          go test -race -v -coverprofile=coverage.out -covermode=atomic ./...

      - name: Validate Coverage Threshold
        run: |
          COVERAGE=$(go tool cover -func=coverage.out | grep total | awk '{print $3}' | sed 's/%//')
          echo "Total Coverage: ${COVERAGE}%"
          if (( $(echo "${COVERAGE} < 80.0" | bc -l) )); then
            echo "::error::Code coverage (${COVERAGE}%) is below required threshold of 80.0%"
            exit 1
          fi

  container-build-and-scan:
    name: Immutable Artifact Build & Security Vulnerability Scanning
    needs: static-analysis-and-unit-tests
    runs-on: ubuntu-latest
    timeout-minutes: 20
    steps:
      - name: Checkout Source Code
        uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to Container Registry
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Extract Metadata (Tags, Labels)
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ghcr.io/${{ github.repository }}/payment-service
          tags: |
            type=sha,prefix=,format=long
            type=raw,value=latest,enable=${{ github.ref == 'refs/heads/main' }}

      - name: Build Container Image
        uses: docker/build-push-action@v5
        with:
          context: .
          file: ./Dockerfile
          push: false
          load: true
          tags: ${{ steps.meta.outputs.tags }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Run Trivy Vulnerability Scanner
        uses: aquasecurity/trivy-action@0.18.0
        with:
          image-ref: ghcr.io/${{ github.repository }}/payment-service:${{ github.sha }}
          format: 'sarif'
          output: 'trivy-results.sarif'
          severity: 'CRITICAL,HIGH'
          exit-code: '1'

      - name: Push Container Image to Registry
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        uses: docker/build-push-action@v5
        with:
          context: .
          file: ./Dockerfile
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha
```

---

### Manifiesto 2: Manifiesto de entrega declarativa de GitOps (`argocd-production-application.yaml`)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: payment-service-production
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
  labels:
    tier: core-financial
    environment: production
spec:
  project: default
  source:
    repoURL: 'https://github.com/enterprise-org/payment-service-gitops.git'
    targetRevision: HEAD
    path: environments/production
  destination:
    server: 'https://kubernetes.default.svc'
    namespace: payment-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      allowEmpty: false
    syncOptions:
      - CreateNamespace=true
      - Validate=true
      - PruneLast=true
      - ApplyOutOfSyncOnly=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

---

### Manifiesto 3: Workload de Kubernetes en producción con controles de resiliencia (`k8s-production-service.yaml`)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-service
  namespace: payment-system
  labels:
    app.kubernetes.io/name: payment-service
    app.kubernetes.io/component: API
    app.kubernetes.io/part-of: financial-engine
    app.kubernetes.io/managed-by: argocd
spec:
  replicas: 4
  revisionHistoryLimit: 10
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 25%
      maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: payment-service
  template:
    metadata:
      labels:
        app.kubernetes.io/name: payment-service
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchExpressions:
                    - key: app.kubernetes.io/name
                      operator: In
                      values:
                        - payment-service
                topologyKey: kubernetes.io/hostname
      containers:
        - name: payment-api
          image: ghcr.io/enterprise-org/payment-service/payment-service:6c2a4f6d4d1a0e1234567890abcdef1234567890
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
            - name: metrics
              containerPort: 9090
              protocol: TCP
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              cpu: 1000m
              memory: 512Mi
          startupProbe:
            httpGet:
              path: /healthz/startup
              port: http
            initialDelaySeconds: 5
            periodSeconds: 3
            failureThreshold: 10
          livenessProbe:
            httpGet:
              path: /healthz/liveness
              port: http
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /healthz/readiness
              port: http
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 2
---
apiVersion: v1
kind: Service
metadata:
  name: payment-service
  namespace: payment-system
  labels:
    app.kubernetes.io/name: payment-service
spec:
  type: ClusterIP
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
    - name: metrics
      port: 9090
      targetPort: metrics
      protocol: TCP
  selector:
    app.kubernetes.io/name: payment-service
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: payment-service-hpa
  namespace: payment-system
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: payment-service
  minReplicas: 4
  maxReplicas: 20
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

---

## 4. Comandos reales de CLI y salidas de terminal ($)

### Comando 1: Ejecución de un flujo de trabajo de rebase en una feature branch de corta duración (Trunk-Based Development)

Los ingenieros de plataforma mantienen las feature branches con una vida corta (< 24h) y realizan rebase continuamente contra `main` antes de hacer merge para mantener un historial de Git limpio y bisectable.

```bash
$ git checkout -b feat/add-stripe-webhook-handler
Switched to a new branch 'feat/add-stripe-webhook-handler'

$ git fetch origin main
From github.com:enterprise-org/payment-service
 * branch            main       -> FETCH_HEAD

$ git rebase origin/main
Current branch feat/add-stripe-webhook-handler is up to date.

$ git log --oneline -n 5
6c2a4f6 (HEAD -> feat/add-stripe-webhook-handler) feat: implement stripe webhook event parsing
8a1b2c3 (origin/main, main) test: add integration tests for payment ledger
4d5e6f7 fix: mitigate race condition on database connection pool
901234a refactor: optimize json deserialization path
b890123 chore: bump golangci-lint to v1.55.2
```

---

### Comando 2: Validación del estado de sincronización de GitOps a través de la CLI de ArgoCD

Los ingenieros verifican que el estado en vivo del clúster coincida con el historial de commits de git sin realizar modificaciones manuales en el clúster.

```bash
$ argocd app get payment-service-production --server argocd.internal.net:443
Name:               argocd/payment-service-production
Project:            default
Server:             https://kubernetes.default.svc
Namespace:          payment-system
URL:                https://argocd.internal.net/applications/payment-service-production
Repo:               https://github.com/enterprise-org/payment-service-gitops.git
Target:             HEAD
Path:               environments/production
Sync Window:        Sync Allowed
Sync Status:        Synced to HEAD (6c2a4f6)
Health Status:      Healthy

GROUP  KIND                   NAMESPACE       NAME                 STATUS  HEALTH   HOOK  MESSAGE
       Namespace              payment-system  payment-system       Synced           
apps   Deployment             payment-system  payment-service      Synced  Healthy        deployment.apps/payment-service configured
       Service                payment-system  payment-service      Synced  Healthy        service/payment-service unchanged
autoscaling HorizontalPodAutoscaler payment-system payment-service-hpa  Synced  Healthy        horizontalpodautoscaler.autoscaling/payment-service-hpa configured
```

---

### Comando 3: Consulta del estado del Deployment de producción en Kubernetes y del historial de Rollout

Los ingenieros inspeccionan el estado del workload en ejecución para verificar las actualizaciones progresivas (rolling updates) sin tiempo de inactividad (zero-downtime).

```bash
$ kubectl rollout status deployment/payment-service -n payment-system --timeout=60s
deployment "payment-service" successfully rolled out

$ kubectl get pods -n payment-system -l app.kubernetes.io/name=payment-service -o wide
NAME                               READY   STATUS    RESTARTS   AGE     IP           NODE                         NOMINATED NODE   READINESS GATES
payment-service-75b6d9f489-4k2x8   1/1     Running   0          4m12s   10.244.2.14  gke-prod-pool-1-a8b2c        <none>           <none>
payment-service-75b6d9f489-8j9p1   1/1     Running   0          4m12s   10.244.3.89  gke-prod-pool-1-b9c3d        <none>           <none>
payment-service-75b6d9f489-l9m4n   1/1     Running   0          3m45s   10.244.1.66  gke-prod-pool-1-c1d4e        <none>           <none>
payment-service-75b6d9f489-q3w5e   1/1     Running   0          3m45s   10.244.2.18  gke-prod-pool-1-a8b2c        <none>           <none>

$ kubectl rollout history deployment/payment-service -n payment-system
deployment.apps/payment-service 
REVISION  CHANGE-CAUSE
8         kubectl.kubernetes.io/restartedAt=2026-08-01T10:00:00Z
9         gitops.sync.commit=8a1b2c3d4e5f6g7h8i9j0k
10        gitops.sync.commit=6c2a4f6d4d1a0e1234567890abcdef1234567890
```

---

## 5. Guía de verificación y resolución de problemas (Troubleshooting)

### Diagrama de flujo de decisión de diagnóstico

```
                 SRE INCIDENT DETECTED
                           |
            Is ArgoCD Application Synced?
                     /           \
                 NO /             \ YES
                   /               \
         Check ArgoCD Diff     Are Pods Healthy?
      $ argocd app diff        $ kubectl get pods
                 |                     |
      +----------+----------+   +------+------+
      |                     |   |             |
Git Drift / Conflict  Cluster Out-Of-Memory  Readiness Failure
      |             Quota Exceeded     |
Reconcile Git State        |        Inspect App Logs
& Hard Sync         Fix HPA/Limits  $ kubectl logs -f
```

---

### Modo de fallo 1: Estado de sincronización de GitOps "OutOfSync" / Drift por mutación de recursos del clúster

#### Síntoma
La interfaz de usuario (UI) de ArgoCD marca `payment-service-production` como `OutOfSync`. La reconciliación automatizada se bloquea debido a la modificación manual de recursos en el clúster o a un conflicto en el esquema de campos.

#### Runbook de diagnóstico
1. Inspeccionar el drift preciso a nivel de campo utilizando la CLI de ArgoCD:
   ```bash
   $ argocd app diff payment-service-production --server argocd.internal.net:443
   ```
   *Salida:*
   ```text
   ===== apps/Deployment payment-system/payment-service ======
   --- Resource Spec (Git HEAD)
   +++ Live Spec (Cluster State)
   @@ -35,3 +35,3 @@
              resources:
                limits:
   -              cpu: 1000m
   +              cpu: 2000m
   ```
2. Identificar quién o qué mutó el estado del clúster:
   ```bash
   $ kubectl get deployment payment-service -n payment-system -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}'
   ```
3. Remediar el drift forzando la reconciliación automatizada de regreso al estado de Git:
   ```bash
   $ argocd app sync payment-service-production --force --prune --server argocd.internal.net:443
   ```

---

### Modo de fallo 2: Build roto en la rama principal (rotura en Trunk-Based Development)

#### Síntoma
Un desarrollador hace merge de un commit directamente en `main` que rompe las pruebas de integración debido a una condición de carrera (race condition) no detectada. Los pipelines bloqueados impiden deployments posteriores en toda la organización.

#### Runbook de diagnóstico
1. Inspeccionar los registros (logs) de commits recientes para identificar el commit defectuoso:
   ```bash
   $ git log --oneline origin/main -n 10
   ```
2. Aislar el fallo utilizando `git bisect`:
   ```bash
   $ git bisect start
   $ git bisect bad origin/main
   $ git bisect good 8a1b2c3
   Bisecting: 3 revisions left to test after this (roughly 2 steps)
   $ go test -race ./...
   $ git bisect run go test -race ./...
   ```
   *Salida:*
   ```text
   6c2a4f6d4d1a0e1234567890abcdef1234567890 is the first bad commit
   commit 6c2a4f6d4d1a0e1234567890abcdef1234567890
   Author: Alex Dev <alex@enterprise.org>
   Date:   Thu Aug 6 18:22:10 2026 -0400

       feat: implement stripe webhook event parsing
   ```
3. Ejecutar una reversión automatizada inmediata (principio de Roll-Forward):
   ```bash
   $ git revert 6c2a4f6d4d1a0e1234567890abcdef1234567890 --no-edit
   [main 9f8e7d6] Revert "feat: implement stripe webhook event parsing"
   $ git push origin main
   ```

---

### Modo de fallo 3: Fallo en cascada durante un despliegue progresivo (Progressive Rolling Deployment)

#### Síntoma
Las nuevas réplicas de los pods fallan en las readiness probes (devuelven un código de estado 500 en `/healthz/readiness` debido a una incompatibilidad con el esquema de la base de datos), lo que provoca que la estrategia `RollingUpdate` se detenga al aplicar la restricción `maxUnavailable: 0`.

#### Runbook de diagnóstico
1. Inspeccionar los estados de los pods y eventos del deployment:
   ```bash
   $ kubectl get pods -n payment-system -l app.kubernetes.io/name=payment-service
   ```
   *Salida:*
   ```text
   NAME                               READY   STATUS    RESTARTS   AGE
   payment-service-75b6d9f489-4k2x8   1/1     Running   0          12m
   payment-service-75b6d9f489-8j9p1   1/1     Running   0          12m
   payment-service-86c7ea5b90-x4y9z   0/1     Running   0          90s
   payment-service-86c7ea5b90-w2v1u   0/1     Running   0          90s
   ```
2. Obtener las descripciones de los eventos del pod:
   ```bash
   $ kubectl describe pod payment-service-86c7ea5b90-x4y9z -n payment-system
   ```
   *Extracto de salida:*
   ```text
   Events:
     Type     Reason     Age                  From               Message
     ----     ------     ----                 ----               -------
     Warning  Unhealthy  10s (x8 over 80s)   kubelet            Readiness probe failed: HTTP probe failed with statuscode: 500
   ```
3. Extraer los logs de fallo de la aplicación desde el pod no preparado (unready):
   ```bash
   $ kubectl logs payment-service-86c7ea5b90-x4y9z -n payment-system --tail=20
   ```
   *Salida:*
   ```json
   {"timestamp":"2026-08-06T19:14:02Z","level":"FATAL","msg":"failed to initialize payment processor","error":"column 'stripe_signature_v2' does not exist on table 'ledger'"}
   ```
4. Activar un rollback instantáneo inmediato sin tiempo de inactividad (zero-downtime):
   ```bash
   $ kubectl rollout undo deployment/payment-service -n payment-system
   deployment.apps/payment-service rolled back
   ```
5. Confirmar la estabilidad del deployment:
   ```bash
   $ kubectl rollout status deployment/payment-service -n payment-system
   deployment "payment-service" successfully rolled out
   ```

---

## 6. Referencias

- **Linux Professional Institute (LPI) Open Source Essentials Overview**:  
  https://www.lpi.org/our-certifications/open-source-essentials-overview/
- **LPI Learning Portal (Official Study Materials)**:  
  https://learning.lpi.org/
- **The Cathedral and the Bazaar (Eric S. Raymond)**:  
  https://catb.org/~esr/writings/cathedral-bazaar/
- **Git Official Documentation & Branching Workflows**:  
  https://git-scm.com/doc
- **ArgoCD Declarative GitOps Documentation**:  
  https://argo-cd.readthedocs.io/
- **DevOps Research and Assessment (DORA) Core Metrics**:  
  https://dora.dev/

---
### Resumen técnico de artefactos completados
- **Mecánicas arquitectónicas**: Análisis de los modelos Waterfall, Cathedral vs. Bazaar, Agile, DevOps y GitOps en términos de lead time, MTTR, CFR y velocidad operativa.
- **Análisis de trade-offs**: Formulación de matrices de comparación detallando métricas para paradigmas de desarrollo y estrategias de branching de Git (Gitflow vs. Trunk-Based Development).
- **Infraestructura de producción**: Construcción de manifiestos YAML completos y sintácticamente válidos para un pipeline de CI de GitHub Actions, un CRD de Aplicación GitOps de ArgoCD y un Deployment de Kubernetes de alta disponibilidad con reglas de HPA y anti-afinidad.
- **Diagnósticos por CLI**: Demostración de comandos exactos de terminal y salidas de diagnóstico de `git`, `argocd` y `kubectl`.
- **Resolución de fallos (Troubleshooting)**: Documentación paso a paso de runbooks de SRE para drift de sincronización de GitOps, roturas en la build de la rama principal y fallos en las readiness probes durante releases progresivos.