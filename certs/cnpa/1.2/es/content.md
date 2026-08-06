# 1.2 — DevOps Practices and Culture in Platform Engineering

**Certificación:** CNPA (Cloud Native Platform Engineering Associate) — versión 2025-04-01
**Peso en el examen:** 7.2

---

## 1. Motivación: el problema arquitectónico de producción

### 1.1 El punto de partida: "you build it, you run it"

DevOps nació como respuesta a un problema de *flujo*: los equipos de desarrollo optimizaban para velocidad de cambio y los equipos de operaciones para estabilidad, y el muro entre ambos ("throw it over the wall") producía handoffs lentos, colas de tickets y despliegues traumáticos de baja frecuencia. La respuesta cultural — resumida en la frase de Werner Vogels de 2006, *"you build it, you run it"* — fue que el mismo equipo que escribe el servicio lo opere en producción: on-call incluido, feedback loop cerrado.

Esto funciona de manera excelente con 5 equipos. El problema arquitectónico aparece con 50.

### 1.2 El problema N×M

Cuando cada *stream-aligned team* (equipo alineado a un flujo de valor de negocio) es "full DevOps" y dueño de todo su stack, cada equipo termina resolviendo por su cuenta el mismo conjunto de preocupaciones transversales:

```
                         Concerns transversales (M)
                 ┌──────────┬──────────┬──────────┬──────────┐
                 │  CI/CD   │ Observa- │ Secrets  │ Network  │
                 │          │ bility   │ mgmt     │ policy   │
   ┌─────────┐   ├──────────┼──────────┼──────────┼──────────┤
   │ Team A  │──▶│ Jenkins  │ ELK      │ .env en  │ ninguna  │
   ├─────────┤   ├──────────┼──────────┼──────────┼──────────┤
   │ Team B  │──▶│ GH       │ Prom +   │ Vault    │ Calico   │
   │         │   │ Actions  │ Grafana  │          │ manual   │
   ├─────────┤   ├──────────┼──────────┼──────────┼──────────┤
   │ Team C  │──▶│ GitLab   │ Datadog  │ Sealed   │ Istio    │
   │         │   │ CI       │          │ Secrets  │ AuthZ    │
   └─────────┘   └──────────┴──────────┴──────────┴──────────┘

   Sin plataforma:  costo ≈ N equipos × M concerns  (cada celda se paga)
   Con plataforma:  costo ≈ N + M  (cada concern se resuelve UNA vez
                    y se consume como servicio self-service)
```

Las consecuencias de producción del modelo N×M son medibles y graves:

- **Tool sprawl y pipelines snowflake:** cada pipeline es único, nadie puede auditarlos todos, y un CVE en una GitHub Action de terceros exige parchear N variantes distintas.
- **Postura de seguridad inconsistente:** la política "todas las imágenes se escanean antes de producción" no es verificable si existen 50 caminos distintos hacia producción.
- **Cognitive load extráneo:** el desarrollador de un servicio de pagos dedica horas semanales a mantener Helm charts, reglas de Prometheus y IAM, en vez de lógica de pagos. Esto es exactamente lo que *Team Topologies* (Skelton & Pais) identifica como carga cognitiva **extrínseca**: necesaria para entregar, pero sin valor de negocio directo.
- **Fragilidad del on-call:** "you build it, you run it" sin soporte de plataforma degenera en burnout, porque cada equipo opera en soledad un stack que no domina completo.

### 1.3 La respuesta: Platform Engineering como industrialización de DevOps

Platform Engineering **no reemplaza** DevOps: lo implementa a escala. El *CNCF Platforms White Paper* lo formula así: una plataforma interna es la manera de conservar los beneficios culturales de DevOps (ownership, feedback rápido, autonomía) reduciendo el costo de que cada equipo los pague individualmente. La plataforma ofrece las capacidades transversales (build, deploy, observar, asegurar) como **producto self-service con golden paths**, y los stream-aligned teams conservan la responsabilidad de operar *su* servicio — pero sobre cimientos operados por expertos.

La tesis central que el examen CNPA evalúa en este tema: **la plataforma es la materialización técnica de la cultura DevOps, no su negación**. Un equipo de plataforma que atiende por tickets y aprueba despliegues manualmente reconstruyó el silo de operaciones con un nombre nuevo — el anti-pattern más citado del dominio.

---

## 2. Fundamentos culturales que la plataforma hereda

### 2.1 CALMS

El framework CALMS (Humble/Willis) descompone DevOps en cinco dimensiones. Para el examen, importa mapear cada una a su mecanismo concreto en una plataforma:

| Dimensión | Significado DevOps | Materialización en Platform Engineering |
|---|---|---|
| **C**ulture | Ownership compartido, sin blame | Blameless postmortems como servicio de la plataforma; error budgets compartidos |
| **A**utomation | Eliminar trabajo manual repetitivo | Golden paths: pipeline templates, GitOps, provisioning declarativo self-service |
| **L**ean | Flujo de valor, lotes chicos, eliminar waste | Trunk-based development, límites WIP, despliegues pequeños y frecuentes |
| **M**easurement | Decidir con datos | DORA metrics instrumentadas *por la plataforma* para todos los equipos, gratis |
| **S**haring | Conocimiento circula, no se acapara | InnerSource sobre los repos de plataforma; documentación y catálogo en el portal |

### 2.2 The Three Ways

Los *Three Ways* (Gene Kim, *The Phoenix Project* / *The DevOps Handbook*) son el modelo de flujo subyacente:

1. **First Way — Flow (izquierda → derecha):** optimizar el flujo completo de commit a producción. Mecánica de plataforma: un solo camino pavimentado, colas cortas, despliegue continuo, entornos efímeros por pull request.
2. **Second Way — Feedback (derecha → izquierda):** amplificar señales de producción hacia el desarrollo. Mecánica: observability por defecto (cada workload desplegado por el golden path ya emite métricas, logs y traces), alertas ruteadas al equipo dueño, DORA dashboards.
3. **Third Way — Continual Learning:** experimentación y aprendizaje sistémico. Mecánica: blameless postmortems, chaos engineering, game days, y — clave para plataforma — tratar cada fricción reportada por un equipo como un bug del producto plataforma.

### 2.3 Cultura organizacional de Westrum

DORA correlaciona desempeño de delivery con la tipología de Westrum. Es material de examen frecuente:

| Tipo | Cómo fluye la información | Síntoma típico | Correlación DORA |
|---|---|---|---|
| **Pathological** (orientada al poder) | Se acapara; el mensajero es castigado | Incidentes ocultados, deploy freeze permanentes | Bajo desempeño |
| **Bureaucratic** (orientada a reglas) | Fluye por canales formales; los silos se protegen | CAB (Change Advisory Board) de aprobación manual, tickets entre equipos | Desempeño medio |
| **Generative** (orientada a la misión) | Fluye libremente; el fracaso dispara *inquiry*, no castigo | Postmortems públicos, self-service, riesgo gestionado por automatización | Alto desempeño |

Una plataforma bien diseñada *empuja* hacia cultura generativa porque reemplaza aprobaciones humanas (bureaucratic) por controles automatizados en el pipeline: policy-as-code, escaneo obligatorio, progressive delivery.

### 2.4 Anti-patterns culturales que el examen espera que reconozcas

| Anti-pattern | Descripción | Por qué falla |
|---|---|---|
| **"DevOps team" como silo** | Renombrar al equipo de Ops como "DevOps" y seguir atendiendo tickets | Agrega un handoff en vez de eliminarlo; el muro sigue, con otro cartel |
| **Ticket-ops** | La plataforma existe pero se consume abriendo tickets a humanos | Destruye el flow; la cola humana es el cuello de botella que DevOps vino a eliminar |
| **Golden cage** | Golden path obligatorio, sin escape hatch, sin escuchar a los usuarios | Los equipos lo bypassean (shadow IT) o se frustran; la adopción forzada mata el feedback |
| **Platform build trap** | Construir features de plataforma por roadmap propio sin descubrimiento de usuarios | Se construye lo que nadie pidió; adopción cercana a cero |
| **Hero culture** | Incidentes resueltos por individuos irremplazables, sin postmortem | Conocimiento no circula; el bus factor es 1; Westrum pathological |

---

## 3. De DevOps a Platform Engineering: Team Topologies y cognitive load

### 3.1 Los cuatro tipos de equipo

*Team Topologies* es el vocabulario estándar del dominio (y del curriculum CNPA):

| Tipo de equipo | Propósito | Ejemplo en plataforma |
|---|---|---|
| **Stream-aligned** | Entregar valor de negocio en un flujo (producto, journey) | Equipo de checkout, equipo de búsqueda |
| **Platform** | Ofrecer servicios internos que reducen el cognitive load de los stream-aligned | Equipo del IDP: CI/CD, Kubernetes, observability como producto |
| **Enabling** | Acompañar temporalmente a otros equipos para cerrar brechas de capacidad | "SRE coaches" que enseñan SLOs a un equipo durante un trimestre |
| **Complicated-subsystem** | Encapsular un subsistema que exige conocimiento especializado profundo | Equipo del motor de pricing, del codec de video |

Y los tres **modos de interacción**:

| Modo | Cuándo usarlo | Señal de que está mal usado |
|---|---|---|
| **X-as-a-Service** | Relación estable plataforma → consumidores; API/portal claro | Si requiere reuniones constantes, la abstracción es incorrecta |
| **Collaboration** | Descubrimiento conjunto de algo nuevo, por tiempo acotado | Si se vuelve permanente, hay acoplamiento y ownership difuso |
| **Facilitating** | Un enabling team destraba a otro | Si el enabling team hace el trabajo en lugar de enseñar, creó dependencia |

El estado objetivo maduro es **X-as-a-Service**: la plataforma se consume como se consume un cloud provider, sin hablar con humanos para el caso común. *Collaboration* es correcto en la fase de descubrimiento de una capability nueva; el error es fosilizarlo.

### 3.2 Thinnest Viable Platform (TVP)

Skelton & Pais definen la TVP: la plataforma más chica que reduce el cognitive load de sus consumidores. Puede ser *una página de wiki* que estandariza cómo usar servicios cloud. La implicancia arquitectónica: la plataforma es una **capa de producto**, no una pila de tecnología — se empieza por el problema del usuario, no por instalar herramientas. Construir de más es un modo de falla tan real como construir de menos (mantener cada componente tiene costo perpetuo de operación y de migración).

### 3.3 Platform as a Product

La práctica cultural distintiva de platform engineering, heredada de product management:

- **Usuarios internos tratados como clientes:** user research, entrevistas, encuestas de fricción, NPS interno.
- **Roadmap dirigido por adopción y dolor**, no por novedad tecnológica.
- **Adopción opcional (por atracción)** como default: si el golden path es realmente mejor, los equipos lo eligen. La obligatoriedad se reserva para controles de compliance, y se implementa como policy-as-code, no como aprobación humana.
- **Métricas de producto:** adoption rate, time-to-first-deploy de un equipo nuevo, ticket deflection (qué porcentaje del uso no requirió humanos), retención.
- **Docs y onboarding son features**, no un anexo: en un producto self-service, la documentación *es* la interfaz de soporte.

---

## 4. Comparativas técnicas y trade-offs

### 4.1 DevOps vs SRE vs Platform Engineering

Las tres disciplinas coexisten; el examen pide distinguir foco y unidad de trabajo:

| Dimensión | DevOps | SRE | Platform Engineering |
|---|---|---|---|
| Naturaleza | Filosofía/cultura de colaboración | Implementación con ingeniería de la confiabilidad (Google) | Disciplina de construir productos internos |
| Pregunta central | ¿Cómo eliminamos el muro dev/ops? | ¿Cuánta falta de confiabilidad toleramos y cómo la gestionamos? | ¿Cómo escalamos DevOps a N equipos sin ahogarlos? |
| Unidad de trabajo | Prácticas (CI/CD, IaC, colaboración) | SLI/SLO, error budgets, toil reduction | Capabilities self-service, golden paths |
| Métrica de éxito | DORA four keys | Cumplimiento de SLO, toil < 50% | Adopción, cognitive load reducido, DORA de sus consumidores |
| Modo de falla típico | "DevOps team" como silo renombrado | Gatekeeping de confiabilidad, on-call mercenario | Golden cage, build trap, ticket-ops |
| Relación | Define el *por qué* | Aporta el *cuán confiable* | Construye el *con qué* |

### 4.2 Ticket-driven ops vs self-service platform

| Criterio | Ticket-driven | Self-service |
|---|---|---|
| Lead time de un entorno nuevo | Días–semanas (cola humana) | Minutos (API/portal/PR) |
| Escalabilidad | Lineal con headcount de Ops | Independiente del headcount |
| Consistencia/compliance | Depende de la disciplina del operador | Garantizada por el template + policy-as-code |
| Auditabilidad | Tickets dispersos | Git history: quién, qué, cuándo, por qué (PR) |
| Costo inicial | Bajo (statu quo) | Alto (construir el producto) |
| Conocimiento | Concentrado en Ops (bus factor) | Codificado en templates y docs |
| Modo de falla | Burnout de Ops, colas, shadow IT | Abstracción incorrecta → escape hatches necesarios |

### 4.3 Estandarización vs autonomía (el trade-off permanente)

| | Estandarización fuerte (golden path estricto) | Autonomía total (cada equipo su stack) |
|---|---|---|
| Ventaja | Auditable, barato de operar, onboarding rápido, seguridad uniforme | Fit perfecto por caso de uso, innovación en los bordes |
| Costo | Riesgo de golden cage; casos de uso legítimos que no encajan | Problema N×M completo; imposible de asegurar y auditar |
| Resolución madura | Golden path **por defecto** + escape hatch **explícito y visible**: quien se sale, asume la operación de lo que se sale ("you own what you deviate") | |

### 4.4 DORA metrics: definiciones y umbrales

Las *four keys* de DORA (dora.dev, reportes *Accelerate State of DevOps*) miden throughput y estabilidad. Umbrales de referencia del cluster "elite" (reporte 2023 — los cortes exactos varían por año, memorizá el orden de magnitud):

| Métrica | Qué mide | Elite (referencia) | Low (referencia) |
|---|---|---|---|
| **Deployment Frequency** | Frecuencia de deploy exitoso a producción | On-demand (varias/día) | Entre 1/semana y 1/mes o menos |
| **Lead Time for Changes** | Commit → corriendo en producción | < 1 día | 1 semana – 6 meses |
| **Change Failure Rate** | % de deploys que causan degradación (rollback, hotfix, incidente) | ~5 % | > 40–60 % |
| **Failed Deployment Recovery Time** (ex MTTR) | Tiempo de restaurar servicio tras deploy fallido | < 1 hora | 1 semana – 1 mes |

Puntos que el examen suele explotar:

- Throughput y estabilidad **no son un trade-off**: los equipos elite son mejores en *las cuatro* a la vez. Deploys chicos y frecuentes son *menos* riesgosos, no más.
- DORA mide el **flujo**, no a las personas. Usar four keys para rankear individuos es un anti-pattern (goodharting garantizado).
- **SPACE** (Forsgren et al., ACM Queue) complementa a DORA para productividad de desarrolladores: Satisfaction, Performance, Activity, Communication, Efficiency/flow. Ninguna métrica única alcanza; siempre combinar dimensiones.
- El rol de la plataforma: **instrumentar DORA para todos los equipos automáticamente** (del historial de Git + eventos de deploy + incidentes), en vez de que cada equipo lo mida a mano.

---

## 5. Prácticas de ingeniería: implementación completa de referencia

Escenario de referencia usado en el resto del tema: el servicio `shop-api`, desplegado por el golden path de la plataforma: **trunk-based development → CI (build, test, scan, push por digest) → commit al repo GitOps → Argo CD sincroniza → métricas DORA derivadas de Argo CD y Prometheus**.

```
 developer ──PR──▶ repo app (shop-api) ──merge a main──▶ CI pipeline
                                                            │
                                              build + test + scan + push
                                                            │
                                            commit de digest al repo GitOps
                                                            │
                          Argo CD (pull) ◀── repo gitops (shop-platform-deploy)
                              │
                        cluster productivo ──métricas──▶ Prometheus ──▶ DORA dashboard
```

### 5.1 CI pipeline del golden path (GitHub Actions, completa)

`.github/workflows/golden-path-ci.yaml` — este workflow es el *template* que la plataforma versiona y los equipos consumen; el escaneo y el push por digest no son opcionales, son el control de compliance codificado:

```yaml
name: golden-path-ci
# Golden path CI: build -> test -> scan -> push by digest -> promote via GitOps.
# Owned by: platform-team. Consumers pin a major tag (golden-path-ci@v2).

on:
  push:
    branches: ["main"]
  pull_request:
    branches: ["main"]

permissions:
  contents: read
  packages: write
  id-token: write   # keyless signing (OIDC), no long-lived secrets

env:
  IMAGE: ghcr.io/acme/shop-api
  GITOPS_REPO: acme/shop-platform-deploy

jobs:
  test:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version: "1.23"
      - name: Unit tests with race detector
        run: go test -race -count=1 -coverprofile=cover.out ./...
      - name: Enforce coverage floor
        run: |
          pct=$(go tool cover -func=cover.out | awk '/^total:/ {gsub("%","",$3); print $3}')
          echo "coverage=${pct}%"
          awk -v p="$pct" 'BEGIN { exit (p < 70.0) }'

  build-and-push:
    needs: test
    if: github.event_name == 'push'   # only trunk builds publish artifacts
    runs-on: ubuntu-24.04
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
      - name: Build and push
        id: push
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: ${{ env.IMAGE }}:${{ github.sha }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
          provenance: true
          sbom: true
      - name: Scan image (fail on HIGH/CRITICAL)
        uses: aquasecurity/trivy-action@0.28.0
        with:
          image-ref: ${{ env.IMAGE }}@${{ steps.push.outputs.digest }}
          exit-code: "1"
          severity: HIGH,CRITICAL
          ignore-unfixed: true
      - name: Sign image (keyless, OIDC)
        run: |
          curl -sSfL https://github.com/sigstore/cosign/releases/download/v2.4.1/cosign-linux-amd64 \
            -o /usr/local/bin/cosign && chmod +x /usr/local/bin/cosign
          cosign sign --yes "${IMAGE}@${{ steps.push.outputs.digest }}"

  promote:
    needs: build-and-push
    if: github.event_name == 'push'
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
        with:
          repository: ${{ env.GITOPS_REPO }}
          token: ${{ secrets.GITOPS_PUSH_TOKEN }}   # scoped bot token
      - name: Bump image digest in the GitOps repo
        run: |
          cd apps/shop-api/overlays/production
          kustomize edit set image \
            "${IMAGE}@${{ needs.build-and-push.outputs.digest }}"
          git config user.name  "platform-bot"
          git config user.email "platform-bot@acme.example"
          git commit -am "deploy(shop-api): ${GITHUB_SHA} -> production" \
            --trailer "Source-Commit: ${GITHUB_SHA}"
          git push origin main
```

Decisiones de diseño que el material de examen espera que puedas justificar:

- **Push por digest, no por tag mutable:** `image@sha256:...` es inmutable y hace el deploy reproducible y auditable; `:latest` rompe el rollback y la trazabilidad.
- **El trailer `Source-Commit`** enlaza el commit de deploy con el commit de código: es la materia prima para calcular *lead time for changes* sin herramientas adicionales.
- **CI no toca el cluster.** El único actor con acceso de escritura al cluster es Argo CD (modelo *pull*). Esto reduce la superficie de credenciales: no hay kubeconfig en el CI.

### 5.2 GitOps: Argo CD Application (completa)

`apps/shop-api/application.yaml` en el repo GitOps:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: shop-api-production
  namespace: argocd
  labels:
    app.kubernetes.io/managed-by: platform-team
    acme.example/stream-team: checkout
  finalizers:
    - resources-finalizer.argocd.argoproj.io   # cascade delete on app removal
spec:
  project: production
  source:
    repoURL: https://github.com/acme/shop-platform-deploy.git
    targetRevision: main
    path: apps/shop-api/overlays/production
  destination:
    server: https://kubernetes.default.svc
    namespace: shop
  syncPolicy:
    automated:
      prune: true       # delete resources removed from Git
      selfHeal: true    # revert manual drift (kubectl edit) automatically
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
      - ApplyOutOfSyncOnly=true
    retry:
      limit: 5
      backoff:
        duration: 30s
        factor: 2
        maxDuration: 5m
  ignoreDifferences:
    # The HPA owns replicas; do not fight it from Git.
    - group: apps
      kind: Deployment
      name: shop-api
      jsonPointers:
        - /spec/replicas
  revisionHistoryLimit: 10
```

Y el workload del golden path, `apps/shop-api/base/deployment.yaml` — fijate que las probes, los recursos y las labels estándar vienen del template de plataforma, no de la memoria de cada desarrollador:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop-api
  labels:
    app.kubernetes.io/name: shop-api
    app.kubernetes.io/part-of: checkout
    acme.example/golden-path: "v2"
spec:
  replicas: 3
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app.kubernetes.io/name: shop-api
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  template:
    metadata:
      labels:
        app.kubernetes.io/name: shop-api
        app.kubernetes.io/part-of: checkout
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
        prometheus.io/path: "/metrics"
    spec:
      serviceAccountName: shop-api
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: shop-api
          image: ghcr.io/acme/shop-api@sha256:0000000000000000000000000000000000000000000000000000000000000000
          ports:
            - name: http
              containerPort: 8080
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              memory: 256Mi
          readinessProbe:
            httpGet:
              path: /healthz/ready
              port: http
            periodSeconds: 5
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /healthz/live
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
```

### 5.3 DORA instrumentado por la plataforma (PrometheusRule, completa)

Argo CD expone métricas en `argocd-metrics:8082` (`argocd_app_sync_total`, `argocd_app_info`). Con eso, la plataforma deriva deployment frequency y un proxy de change failure rate para *todos* los equipos sin que hagan nada:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: platform-dora-metrics
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: dora.recording
      interval: 1m
      rules:
        # Successful production syncs per app, over 7 days (deployment frequency).
        - record: platform:dora_deployment_frequency:7d
          expr: |
            sum by (name) (
              increase(argocd_app_sync_total{phase="Succeeded"}[7d])
            )
        # Failed syncs / total syncs, over 7 days (change failure rate proxy).
        - record: platform:dora_change_failure_ratio:7d
          expr: |
            sum by (name) (increase(argocd_app_sync_total{phase=~"Failed|Error"}[7d]))
            /
            clamp_min(sum by (name) (increase(argocd_app_sync_total[7d])), 1)
    - name: dora.alerting
      rules:
        - alert: ChangeFailureRateHigh
          expr: platform:dora_change_failure_ratio:7d > 0.15
          for: 1h
          labels:
            severity: warning
            team: platform
          annotations:
            summary: >-
              App {{ $labels.name }} exceeds 15% change failure rate over 7d.
            runbook_url: https://portal.acme.example/runbooks/dora-cfr
        - alert: DeploymentFrequencyStalled
          expr: platform:dora_deployment_frequency:7d == 0
          for: 6h
          labels:
            severity: info
            team: platform
          annotations:
            summary: >-
              App {{ $labels.name }} had zero successful deploys in 7 days;
              check for a broken pipeline or an abandoned golden path.
```

Nota de precisión: el sync count es un *proxy*. El lead time fino se calcula con el trailer `Source-Commit` (timestamp del commit de código) contra `argocd_app_sync_total`/el evento `Synced` (timestamp de producción). Herramientas como el *Four Keys* de DORA o un exporter propio hacen exactamente ese join.

### 5.4 Trunk-based development y prácticas de flujo

- **Trunk-based development:** ramas de vida corta (< 1 día) integradas a `main` continuamente; `main` siempre desplegable. Es la práctica con correlación más fuerte con las four keys según DORA. Feature flags desacoplan *deploy* de *release*.
- **Everything as Code:** aplicación, infraestructura (IaC), pipeline, políticas (OPA/Kyverno), dashboards y alertas viven en Git, con PR review. El PR es la unidad de cambio universal y el audit trail gratis.
- **Blameless postmortems:** ante un incidente se documenta la línea de tiempo, los factores contribuyentes sistémicos y los action items — nunca "quién fue". El castigo al error garantiza (Westrum) que el próximo incidente se oculte. La plataforma aporta el template, el archivo público y el tracking de action items.

---

## 6. Comandos CLI y salidas esperadas

Verificación del estado GitOps del servicio:

```console
$ argocd app get shop-api-production
Name:               argocd/shop-api-production
Project:            production
Server:             https://kubernetes.default.svc
Namespace:          shop
URL:                https://argocd.acme.example/applications/shop-api-production
Source:
- Repo:             https://github.com/acme/shop-platform-deploy.git
  Target:           main
  Path:             apps/shop-api/overlays/production
SyncWindow:         Sync Allowed
Sync Policy:        Automated (Prune)
Sync Status:        Synced to main (9f31c2a)
Health Status:      Healthy

GROUP  KIND        NAMESPACE  NAME      STATUS  HEALTH   HOOK  MESSAGE
       Service     shop       shop-api  Synced  Healthy        service/shop-api unchanged
apps   Deployment  shop       shop-api  Synced  Healthy        deployment.apps/shop-api configured
```

Seguimiento de un rollout disparado por un commit GitOps:

```console
$ kubectl -n shop rollout status deployment/shop-api
Waiting for deployment "shop-api" rollout to finish: 1 out of 3 new replicas have been updated...
Waiting for deployment "shop-api" rollout to finish: 2 of 3 updated replicas are available...
deployment "shop-api" successfully rolled out
```

Historial de deploys (la base de deployment frequency y del rollback):

```console
$ argocd app history shop-api-production
ID  DATE                           REVISION
7   2026-08-05 14:02:11 -0300 -03  main (1b8e0d4)
8   2026-08-05 18:45:03 -0300 -03  main (77aa910)
9   2026-08-06 10:12:56 -0300 -03  main (9f31c2a)
```

Rollback operativo — dos formas, y la diferencia es material de examen:

```console
$ # Forma correcta (GitOps puro): revertir el commit en Git; Argo CD converge solo.
$ git -C shop-platform-deploy revert 9f31c2a --no-edit && git -C shop-platform-deploy push origin main
[main 3c07f1e] Revert "deploy(shop-api): 4e21ab7 -> production"

$ # Forma de emergencia: rollback imperativo. Requiere DESACTIVAR el auto-sync,
$ # porque si no, selfHeal vuelve a aplicar lo que dice Git.
$ argocd app set shop-api-production --sync-policy none
$ argocd app rollback shop-api-production 8
```

Lead time de un cambio puntual, calculado desde los dos repos usando el trailer:

```console
$ git -C shop-platform-deploy log -1 --format='%H %cI' main -- apps/shop-api/
77aa910f2 2026-08-05T18:45:03-03:00
$ git -C shop-platform-deploy show -s --format='%(trailers:key=Source-Commit,valueonly)' 77aa910f2
4e21ab7c9
$ git -C shop-api show -s --format='%cI' 4e21ab7c9
2026-08-05T17:58:41-03:00
# Lead time commit -> producción ≈ 47 minutos
```

Estado del pipeline CI del golden path:

```console
$ gh run list --repo acme/shop-api --branch main --limit 3
STATUS     TITLE                       WORKFLOW        BRANCH  EVENT  ID           ELAPSED  AGE
completed  fix: idempotent retry       golden-path-ci  main    push   9182736450   6m12s    2h
completed  feat: partial refunds       golden-path-ci  main    push   9182710021   5m48s    8h
failure    chore: bump go 1.23.4       golden-path-ci  main    push   9182688893   3m02s    1d
```

---

## 7. Guía de verificación y diagnóstico de fallas

### 7.1 Matriz de triage

| Síntoma | Causa probable | Primer comando |
|---|---|---|
| App `OutOfSync` permanente | Drift manual, o un controller (HPA, webhook) mutando campos que Git también declara | `argocd app diff shop-api-production` |
| `Synced` pero `Degraded` | El manifiesto aplicó, pero el workload no levanta (probe, imagen, recursos) | `kubectl -n shop describe pod -l app.kubernetes.io/name=shop-api` |
| Sync loop infinito (flapping) | Pelea entre `selfHeal` y un mutating controller; falta `ignoreDifferences` | `kubectl -n argocd logs deploy/argocd-application-controller \| grep shop-api` |
| Deployment frequency = 0 | Pipeline roto, o el bot no puede pushear al repo GitOps | `gh run list`; luego revisar el job `promote` |
| Change failure rate en alza | Deploys grandes/poco frecuentes, tests insuficientes, o probes mal calibradas que marcan rollouts sanos como fallidos | `argocd app history` + postmortems recientes |
| Lead time alto con CI rápido | La cola está en el proceso humano: PR reviews lentas, aprobaciones manuales, sync windows | Medir por etapas: commit→merge, merge→CI done, CI→sync |

### 7.2 Diagnóstico paso a paso: drift y pelea de controllers

El caso clásico: alguien hizo `kubectl edit` en producción, o un HPA ajusta `replicas` mientras Git declara `replicas: 3`.

```console
$ argocd app diff shop-api-production
===== apps/Deployment shop/shop-api ======
--- live
+++ desired
@@ spec.replicas @@
-  replicas: 7
+  replicas: 3
```

Interpretación: si el `7` lo puso el HPA, esto **no es un incidente**, es una configuración incorrecta de la Application: con `selfHeal: true`, Argo CD baja a 3, el HPA vuelve a subir, y el ciclo repite para siempre (sync flapping — visible como cientos de syncs en `argocd_app_sync_total`). La corrección es declarativa: el bloque `ignoreDifferences` sobre `/spec/replicas` que ya está en el manifiesto de la sección 5.2. Si en cambio el drift es un `kubectl edit` humano, `selfHeal` lo revierte solo — y la conversación correcta es cultural, no técnica: ¿por qué esa persona necesitó tocar producción a mano? Esa respuesta es un bug del golden path.

### 7.3 Diagnóstico paso a paso: `Synced` pero `Degraded`

```console
$ argocd app get shop-api-production | grep -E 'Sync Status|Health'
Sync Status:        Synced to main (3c07f1e)
Health Status:      Degraded

$ kubectl -n shop get pods -l app.kubernetes.io/name=shop-api
NAME                        READY   STATUS             RESTARTS   AGE
shop-api-6d9f7b4c8-2xkqp    0/1     ImagePullBackOff   0          4m
shop-api-6d9f7b4c8-9wl2d    0/1     ImagePullBackOff   0          4m
shop-api-58c4d8f9b-h7t6m    1/1     Running            0          3h

$ kubectl -n shop describe pod shop-api-6d9f7b4c8-2xkqp | tail -n 4
  Warning  Failed   2m (x4 over 4m)  kubelet  Failed to pull image
    "ghcr.io/acme/shop-api@sha256:ab12...": manifest unknown
  Warning  Failed   2m (x4 over 4m)  kubelet  Error: ErrImagePull
  Normal   BackOff  1m (x6 over 4m)  kubelet  Back-off pulling image
```

Lectura de producción: GitOps hizo su trabajo (el manifiesto deseado está aplicado) pero el digest no existe en el registry — típicamente el job `promote` corrió antes de que el push del build terminara de replicarse, o alguien editó el digest a mano. Notá que `maxUnavailable: 0` en la strategy contuvo el blast radius: el ReplicaSet viejo sigue sirviendo tráfico. El deploy cuenta para el change failure rate; la recuperación (`git revert` o re-run del pipeline) cuenta para el recovery time. **Los mecanismos del golden path convierten un error humano en un evento métrico sin downtime** — ese es el argumento cultural completo del tema en una sola falla.

### 7.4 Checklist de verificación del golden path (para game days)

1. `argocd app list` — ninguna app en `Unknown`/`Degraded` sin issue asociado.
2. Merge de un cambio trivial → medir commit-a-producción de punta a punta (< objetivo del SLO interno de la plataforma).
3. `kubectl -n shop edit deploy/shop-api` (cambiar algo menor) → verificar que `selfHeal` lo revierte en < 5 min y que quedó registrado.
4. Matar el registry token del bot → verificar que la alerta `DeploymentFrequencyStalled` o el fallo de `promote` se detecta antes que un humano lo note.
5. Simular imagen sin firma / con CVE HIGH → el pipeline debe fallar en `scan`, nunca llegar a producción.

---

## Referencias

- CNCF TAG App Delivery — *Platforms White Paper*: https://tag-app-delivery.cncf.io/whitepapers/platforms/
- CNCF TAG App Delivery — *Platform Engineering Maturity Model*: https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/
- DORA — investigación y *Accelerate State of DevOps Reports*: https://dora.dev/
- DORA — guía de las four keys: https://dora.dev/guides/dora-metrics-four-keys/
- Team Topologies (Skelton & Pais): https://teamtopologies.com/
- Google SRE Book (relación SRE ↔ DevOps, toil, postmortem culture): https://sre.google/sre-book/table-of-contents/
- OpenGitOps — principios GitOps v1.0 (CNCF): https://opengitops.dev/
- Argo CD — documentación oficial (sync policies, metrics): https://argo-cd.readthedocs.io/en/stable/
- The SPACE of Developer Productivity (Forsgren et al., ACM Queue): https://queue.acm.org/detail.cfm?id=3454124
- Trunk Based Development: https://trunkbaseddevelopment.com/
- CNPA Curriculum (CNCF): https://github.com/cncf/curriculum