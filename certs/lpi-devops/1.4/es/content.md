# LPI DevOps Tools Engineer (701-100) — Tema 1.4: Integración Continua y Entrega Continua

---

## 1. Motivación Arquitectónica y Planteamiento del Problema de Producción

En la ingeniería de sistemas empresariales, el ciclo de entrega de software heredado se caracterizaba por calendarios de lanzamiento monolíticos, ramas de características (feature branches) de larga duración y promoción manual de entornos. Este patrón introduce una fricción sistémica severa:

```
[ Developer Branch 1 ] ──┐
[ Developer Branch 2 ] ──┼──> [ Long-lived Integration Branch ] ──> [ Manual QA Gate ] ──> [ High-Risk Monolithic Release ]
[ Developer Branch 3 ] ──┘         (Severe Merge Conflicts)             (State Drift)            (High MTTR / Low Velocity)
```

### 1.1 Anti-patrones de Producción

1. **Infierno de Integración y Divergencia de Ramas (Integration Hell & Branch Divergence):** Cuando las feature branches divergen de `main` a lo largo de días o semanas, fusionar (merge) código desencadena una complejidad de conflictos exponencial. La complejidad matemática del merge manual escala de forma cuadrática en relación con el número de commits no fusionados y ramas activas.
2. **Deriva de Entorno y Configuración (Environment & Configuration Drift):** Los entornos (Development, Staging, Pre-Production, Production) gestionados de forma imperativa sufren deriva (drift) con el tiempo. El código probado en Staging falla en Production debido a dependencias del SO no documentadas, actualizaciones de librerías no coordinadas o topologías de red asimétricas.
3. **Alto Radio de Impacto (Blast Radius) y Tiempo Medio de Recuperación (MTTR) Prolongado:** El lanzamiento de lotes grandes y multicomponente dificulta la identificación de causas raíz durante caídas de producción. Los procedimientos de rollback para despliegues monolíticos a menudo implican degradaciones complejas del esquema de base de datos y reconciliaciones de estado, extendiendo el tiempo de inactividad.
4. **Gates de Calidad Manuales y Error Humano:** Depender de listas de verificación de pruebas manuales y pasos de despliegue ejecutados por humanos introduce fatiga operacional, validación inconsistente y brechas de cumplimiento de seguridad (por ejemplo, secretos no rastreados, dependencias de terceros no revisadas).

### 1.2 La Solución de Arquitectura de Plataforma y SRE

Continuous Integration (CI) y Continuous Delivery/Deployment (CD) convierten la entrega de software en un pipeline automatizado, predecible, determinista e idempotente gobernado por un Gráfico Acíclico Dirigido (DAG).

```
   +-----------------------------------------------------------------------------------------------+
   |                                  AUTOMATED CI/CD ENGINE (DAG)                                 |
   |                                                                                               |
   |  [ Git Push ] ──> [ Commit Hook ] ──> [ Build Engine ] ──> [ Static Analysis & Unit Tests ]   |
   |                                                                 │                             |
   |                                                                 ▼                             |
   |  [ Automated Rollback ] <── [ Production Deployment ] <── [ Artifact Registry (Immutable) ]   |
   |             ▲                         │                         │                             |
   |             └───── [ SLO Gate ] <─────┴─── [ Integration / ] <──┘                             |
   |                                            [ Smoke Tests   ]                                  |
   +-----------------------------------------------------------------------------------------------+
```

* **Continuous Integration (CI):** Los desarrolladores integran código en una línea base compartida (idealmente a diario). Cada push activa un motor de build automatizado que ejecuta análisis estático de código (SAST), unit testing, escaneo de dependencias y empaquetado de artefactos binarios.
* **Continuous Delivery (CDelivery):** Cada build validada se despliega automáticamente en un entorno de staging y prepara un artefacto inmutable listo para producción. El despliegue a producción requiere un único paso de aprobación programático o humano.
* **Continuous Deployment (CDeployment):** Los cambios validados fluyen automáticamente a través de staging hacia producción sin intervención manual, protegidos por SLO gates guiados por telemetría y análisis de canary automatizado.

---

## 2. Comparativas Técnicas y Transacciones de Arquitectura (Architecture Trade-Offs)

### 2.1 Estrategias de Ramificación (Branching Strategies)

| Métrica / Dimensión | Trunk-Based Development (TBD) | GitFlow | Feature Branching (GitHub Flow) |
| :--- | :--- | :--- | :--- |
| **Frecuencia de Integración** | Múltiples veces por día | Semanal / Bisemanal / Ciclos de release | Al finalizar la característica (1–3 días) |
| **Tiempo de Vida de la Rama** | Corto (< 24 horas) | De larga duración (`develop`, `release/*`) | Corto a Medio (1–3 días) |
| **Complejidad del Merge** | Mínima (rebases pequeños constantes) | Extremadamente alta (merges de ramas de release) | Baja a Moderada |
| **Aislamiento de Característica** | Gestionado mediante Feature Toggles/Flags | Aislado en ramas de release/feature | Aislado en ramas temáticas (topic branches) |
| **Modo de Disparo del Pipeline** | Micro-builds por commit en `main` | Builds multietapa a través de ramas | Build en Pull/Merge Request |
| **Mejor Adecuado Para** | Microservicios de alta velocidad, equipos SRE | Software heredado con releases programados | Aplicaciones web, proyectos open-source |

### 2.2 Estrategias de Despliegue (Deployment Strategies)

| Dimensión | Blue/Green Deployment | Canary Deployment | Rolling Update | Shadow (Mirroring) |
| :--- | :--- | :--- | :--- | :--- |
| **Radio de Impacto (Blast Radius)** | Alto (conmutación de tráfico al 100%) | Progresivo (1% → 5% → 25% → 100%) | Moderado (1/N pods actualizados secuencialmente) | Cero (Tráfico espejado sin impacto en el usuario) |
| **Sobrecarga de Recursos** | +100% infraestructura duplicada | +10% a +25% durante el rollout | +0% a +25% capacidad máxima de surge | +100% stack de cómputo duplicado |
| **Latencia de Rollback** | Casi instantánea (conmutación de router) | Instantánea (peso de tráfico a 0) | Lenta (reemplazo secuencial inverso de pods) | Instantánea (detener regla de espejo) |
| **Seguridad de Estado / BD** | Requiere esquema compatible hacia atrás | Requiere esquema compatible hacia atrás | Requiere esquema compatible hacia atrás | Debe descartar escrituras en shadow (solo lectura) |
| **Acoplamiento de Telemetría** | Pruebas de humo manuales o métrica post-conmutación | Acoplamiento profundo con Prometheus/Datadog | Dependencia básica de probes de readiness/liveness | Los comparadores evalúan salidas de shadow vs en vivo |

### 2.3 Arquitecturas de Motores de CI

```
Centralized Orchestrator Pattern (e.g., Jenkins)
+------------------------------------------------------------+
| [ Controller Node ]                                        |
|   ├── Pipeline Scheduler                                   |
|   └── Executor Dispatcher ──> [ Worker Node A (Static Host) ]|
|                           └──> [ Worker Node B (Docker Host) ]|
+------------------------------------------------------------+

Distributed Event-Driven Pattern (e.g., GitLab CI / GitHub Actions)
+------------------------------------------------------------+
| [ Event Bus / API Server ]                                 |
|   └── Webhook Listener ──> [ Dynamic Runner Pool (K8s Pods) ]|
+------------------------------------------------------------+

GitOps Pull-Based Controller Pattern (e.g., Argo CD / Flux)
+------------------------------------------------------------+
| [ In-Cluster GitOps Engine ]                               |
|   ├── Git Repository Poller (Desired State)                |
|   └── K8s API Reconciler  <──> [ Live Kubernetes Cluster ] |
+------------------------------------------------------------+
```

---

## 3. Manifiestos de Producción e Infraestructura de Pipelines

### 3.1 Jenkinsfile Declarativo (`Jenkinsfile`)

Este pipeline declarativo completo y listo para producción incorpora asignación dinámica de agentes a través de pods de Kubernetes, etapas de ejecución secuenciales, pruebas en paralelo, quality gates de SonarQube, contenedorización con Docker buildx, push a Nexus y despliegues canarios dinámicos con Helm.

```groovy
pipeline {
    agent {
        kubernetes {
            yaml '''
apiVersion: v1
kind: Pod
metadata:
  labels:
    component: ci-executor
spec:
  containers:
  - name: golang
    image: golang:1.22-alpine
    command: ["cat"]
    tty: true
  - name: docker
    image: docker:25.0-cli
    command: ["cat"]
    tty: true
    volumeMounts:
    - mountPath: /var/run/docker.sock
      name: docker-sock
  - name: helm
    image: alpine/helm:3.14.0
    command: ["cat"]
    tty: true
  volumes:
  - name: docker-sock
    hostPath:
      path: /var/run/docker.sock
'''
        }
    }
    options {
        timeout(time: 2, unit: 'HOURS')
        buildDiscarder(logRotator(numToKeepStr: '30'))
        disableConcurrentBuilds()
        ansiColor('xterm')
    }
    environment {
        REGISTRY_HOST     = 'registry.enterprise.internal'
        IMAGE_NAME        = 'platform/payment-service'
        NEXUS_CREDENTIALS = credentials('nexus-docker-auth')
        SONAR_TOKEN       = credentials('sonarqube-token')
        APP_VERSION       = "1.4.${BUILD_NUMBER}"
    }
    stages {
        stage('Checkout & Lint') {
            steps {
                container('golang') {
                    sh '''
                        echo "=== Verifying Source Code Integrity ==="
                        git log -1 --stat
                        go fmt ./...
                        go vet ./...
                    '''
                }
            }
        }
        stage('Parallel Quality Analysis') {
            parallel {
                stage('Unit & Integration Tests') {
                    steps {
                        container('golang') {
                            sh '''
                                echo "=== Running Unit and Coverage Tests ==="
                                go test -v -race -coverprofile=coverage.out -covermode=atomic ./...
                            '''
                        }
                    }
                }
                stage('SonarQube Security Scan') {
                    steps {
                        container('golang') {
                            withSonarQubeEnv('SonarQube-Server') {
                                sh '''
                                    echo "=== Executing SonarScanner ==="
                                    wget https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-5.0.1.3006-linux.zip
                                    unzip -q sonar-scanner-cli-5.0.1.3006-linux.zip
                                    ./sonar-scanner-5.0.1.3006-linux/bin/sonar-scanner \
                                        -Dsonar.projectKey=payment-service \
                                        -Dsonar.sources=. \
                                        -Dsonar.tests=. \
                                        -Dsonar.test.inclusions=**/*_test.go \
                                        -Dsonar.go.coverage.reportPaths=coverage.out \
                                        -Dsonar.host.url=https://sonarqube.enterprise.internal \
                                        -Dsonar.login=${SONAR_TOKEN}
                                '''
                            }
                        }
                    }
                }
            }
        }
        stage('SonarQube Quality Gate') {
            steps {
                timeout(time: 10, unit: 'MINUTES') {
                    waitForQualityGate abortPipeline: true
                }
            }
        }
        stage('Build & Push OCI Image') {
            steps {
                container('docker') {
                    sh '''
                        echo "=== Authenticating with Enterprise Registry ==="
                        echo "${NEXUS_CREDENTIALS_PSW}" | docker login ${REGISTRY_HOST} -u "${NEXUS_CREDENTIALS_USR}" --password-stdin

                        echo "=== Building OCI Container Image ==="
                        docker build \
                            --build-arg VERSION=${APP_VERSION} \
                            --tag ${REGISTRY_HOST}/${IMAGE_NAME}:${APP_VERSION} \
                            --tag ${REGISTRY_HOST}/${IMAGE_NAME}:latest \
                            -f Dockerfile .

                        echo "=== Pushing Artifacts to Nexus ==="
                        docker push ${REGISTRY_HOST}/${IMAGE_NAME}:${APP_VERSION}
                        docker push ${REGISTRY_HOST}/${IMAGE_NAME}:latest
                    '''
                }
            }
        }
        stage('Deploy Canary to Kubernetes') {
            steps {
                container('helm') {
                    sh '''
                        echo "=== Executing Helm Canary Deployment ==="
                        helm upgrade --install payment-service-canary ./helm/payment-service \
                            --namespace production \
                            --set image.repository=${REGISTRY_HOST}/${IMAGE_NAME} \
                            --set image.tag=${APP_VERSION} \
                            --set canary.enabled=true \
                            --set canary.weight=10 \
                            --wait --timeout 5m0s
                    '''
                }
            }
        }
    }
    post {
        always {
            cleanWs()
        }
        success {
            echo "Pipeline succeeded! Artifact ${REGISTRY_HOST}/${IMAGE_NAME}:${APP_VERSION} deployed to Canary."
        }
        failure {
            echo "Pipeline failed. Initiating notification protocols."
        }
    }
}
```

---

### 3.2 Pipeline de CI/CD de GitLab de Producción (`.gitlab-ci.yml`)

Este pipeline completo de `.gitlab-ci.yml` define entornos de staging dinámicos, análisis SAST, almacenamiento en caché de contenedores, pruebas automatizadas, gates de promoción manual y disparadores de limpieza.

```yaml
stages:
  - lint
  - test
  - security
  - package
  - deploy_staging
  - promote_production
  - cleanup

variables:
  DOCKER_DRIVER: overlay2
  DOCKER_TLS_CERTDIR: "/certs"
  CONTAINER_IMAGE: $CI_REGISTRY_IMAGE:$CI_COMMIT_SHA
  RELEASE_IMAGE: $CI_REGISTRY_IMAGE:$CI_COMMIT_TAG

default:
  image: docker:25.0
  services:
    - name: docker:25.0-dind
      alias: docker

cache:
  key: "${CI_COMMIT_REF_SLUG}"
  paths:
    - .go/pkg/mod/
    - .cache/

lint_code:
  stage: lint
  image: golang:1.22-alpine
  script:
    - mkdir -p .go/pkg/mod
    - export GOPATH=$CI_PROJECT_DIR/.go
    - go fmt ./...
    - go vet ./...

unit_testing:
  stage: test
  image: golang:1.22-alpine
  script:
    - mkdir -p .go/pkg/mod
    - export GOPATH=$CI_PROJECT_DIR/.go
    - go test -v -race -coverprofile=coverage.txt ./...
  artifacts:
    expire_in: 7 days
    paths:
      - coverage.txt

sast_security_scan:
  stage: security
  image: returntocorp/semgrep:1.60.0
  script:
    - semgrep scan --config auto --json -o semgrep-sast-results.json
  artifacts:
    reports:
      sast: semgrep-sast-results.json

package_oci_image:
  stage: package
  script:
    - docker login -u $CI_REGISTRY_USER -p $CI_REGISTRY_PASSWORD $CI_REGISTRY
    - docker build --pull -t $CONTAINER_IMAGE .
    - docker push $CONTAINER_IMAGE
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
    - if: '$CI_COMMIT_TAG'

deploy_to_staging:
  stage: deploy_staging
  image: alpine/helm:3.14.0
  environment:
    name: staging
    url: https://staging-payment.enterprise.internal
    on_stop: stop_staging_environment
  script:
    - mkdir -p ~/.kube
    - echo "$KUBE_CONFIG_STAGING" | base64 -d > ~/.kube/config
    - helm upgrade --install payment-service-staging ./chart \
        --namespace staging \
        --set image.repository=$CI_REGISTRY_IMAGE \
        --set image.tag=$CI_COMMIT_SHA \
        --wait --timeout 300s
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'

stop_staging_environment:
  stage: cleanup
  image: alpine/helm:3.14.0
  environment:
    name: staging
    action: stop
  script:
    - mkdir -p ~/.kube
    - echo "$KUBE_CONFIG_STAGING" | base64 -d > ~/.kube/config
    - helm uninstall payment-service-staging --namespace staging
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
      when: manual

promote_to_production:
  stage: promote_production
  image: alpine/helm:3.14.0
  environment:
    name: production
    url: https://payment.enterprise.internal
  script:
    - mkdir -p ~/.kube
    - echo "$KUBE_CONFIG_PROD" | base64 -d > ~/.kube/config
    - helm upgrade --install payment-service-prod ./chart \
        --namespace production \
        --set image.repository=$CI_REGISTRY_IMAGE \
        --set image.tag=$CI_COMMIT_TAG \
        --wait --timeout 600s
  rules:
    - if: '$CI_COMMIT_TAG =~ /^v[0-9]+\.[0-9]+\.[0-9]+$/'
      when: manual
```

---

### 3.3 Manifiesto Declarativo de GitOps (`Application` de Argo CD)

Este manifiesto configura el despliegue continuo con GitOps vinculando el estado de un repositorio remoto a un clúster en vivo de Kubernetes.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: payment-service-prod
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: 'https://gitlab.enterprise.internal/platform/gitops-manifests.git'
    targetRevision: HEAD
    path: 'environments/production/payment-service'
    helm:
      valueFiles:
        - values.yaml
  destination:
    server: 'https://kubernetes.default.svc'
    namespace: production
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - Validate=true
      - PruneLast=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m0s
```

---

## 4. Comandos de CLI Reales y Registros de Ejecución de Terminal

### 4.1 Inspección de CLI y API REST de Jenkins

Ejecución de un disparador de build remoto a través de la interfaz CLI de Jenkins y evaluación del estado de la build:

```bash
$ jenkins-cli -s https://jenkins.enterprise.internal/ -auth admin:11a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6 build platform/payment-service/main -p APP_VERSION=1.4.102 -s -v
```

```text
Started by user Admin (SRE Team)
Obtained Jenkinsfile from git https://gitlab.enterprise.internal/platform/payment-service.git
Loading library enterprise-shared-library@v2.4.0
[Pipeline] Start of Pipeline
[Pipeline] podTemplate
[Pipeline] node
Ready to run on kubernetes-ci-executor-84fd9b7c-x9z2l
[Pipeline] { (Checkout & Lint)
[Pipeline] sh
+ git log -1 --stat
commit a1b2c3d4e5f678901234567890abcdef12345678
Author: SRE Engineer <sre@enterprise.internal>
Date:   Fri Aug 7 04:30:00 2026 -0400

    feat(api): optimize connection pooling parameters

 main.go | 12 ++++++------
 1 file changed, 6 insertions(+), 6 deletions(-)
+ go fmt ./...
+ go vet ./...
[Pipeline] }
[Pipeline] // stage (Checkout & Lint)
[Pipeline] { (Parallel Quality Analysis)
[Pipeline] parallel
[Pipeline] { (Branch: Unit & Integration Tests)
[Pipeline] { (Branch: SonarQube Security Scan)
[Pipeline] sh
+ go test -v -race -coverprofile=coverage.out -covermode=atomic ./...
=== RUN   TestDatabaseConnectionPool
--- PASS: TestDatabaseConnectionPool (0.12s)
=== RUN   TestPaymentProcessingSuccess
--- PASS: TestPaymentProcessingSuccess (0.45s)
PASS
coverage: 88.4% of statements
[Pipeline] }
[Pipeline] }
[Pipeline] // parallel
[Pipeline] stage (SonarQube Quality Gate)
[Pipeline] waitForQualityGate
Checking status of SonarQube task 'AY8x9z0A1B2C3D4E5F6G'
SonarQube task 'AY8x9z0A1B2C3D4E5F6G' status is 'SUCCESS'
Quality Gate status: OK
[Pipeline] stage (Build & Push OCI Image)
[Pipeline] sh
+ echo ***
+ docker login registry.enterprise.internal -u service-account-ci --password-stdin
WARNING! Your password will be stored unencrypted in /home/jenkins/.docker/config.json.
Configure a credential helper to remove this warning.
Login Succeeded
+ docker build --build-arg VERSION=1.4.102 --tag registry.enterprise.internal/platform/payment-service:1.4.102 -f Dockerfile .
Step 1/8 : FROM golang:1.22-alpine AS builder
 ---> 7a8b9c0d1e2f
Step 2/8 : WORKDIR /app
 ---> Using cache 3f4e5d6c7b8a
Step 3/8 : COPY . .
 ---> a1b2c3d4e5f6
Step 4/8 : RUN CGO_ENABLED=0 GOOS=linux go build -o payment-service .
 ---> Running in c9d8e7f6a5b4
Removing intermediate container c9d8e7f6a5b4
 ---> 5e6f7a8b9c0d
Step 5/8 : FROM alpine:3.19
 ---> 1a2b3c4d5e6f
Step 6/8 : COPY --from=builder /app/payment-service /usr/local/bin/
 ---> e9f8d7c6b5a4
Step 7/8 : EXPOSE 8080
 ---> Running in a1b2c3d4e5f6
Removing intermediate container a1b2c3d4e5f6
 ---> d4c3b2a1e6f5
Step 8/8 : CMD ["payment-service"]
 ---> Running in 1234567890ab
Removing intermediate container 1234567890ab
 ---> f5e4d3c2b1a0
Successfully built f5e4d3c2b1a0
Successfully tagged registry.enterprise.internal/platform/payment-service:1.4.102
+ docker push registry.enterprise.internal/platform/payment-service:1.4.102
The push refers to repository [registry.enterprise.internal/platform/payment-service]
8f9e0a1b2c3d: Pushed
7a6b5c4d3e2f: Pushed
1.4.102: digest: sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 size: 739
[Pipeline] stage (Deploy Canary to Kubernetes)
[Pipeline] sh
+ helm upgrade --install payment-service-canary ./helm/payment-service --namespace production --set image.repository=registry.enterprise.internal/platform/payment-service --set image.tag=1.4.102 --set canary.enabled=true --set canary.weight=10 --wait --timeout 5m0s
Release "payment-service-canary" does not exist. Installing it now.
NAME: payment-service-canary
LAST DEPLOYED: Fri Aug 7 04:32:15 2026
NAMESPACE: production
STATUS: deployed
REVISION: 1
TEST SUITE: None
NOTES:
Canary release deployed successfully with 10% traffic weight.
[Pipeline] End of Pipeline
Finished: SUCCESS
```

---

### 4.2 Depuración Local de GitLab CI (`gitlab-runner`)

Prueba de un job de pipeline localmente utilizando `gitlab-runner exec`:

```bash
$ gitlab-runner exec docker unit_testing --docker-volumes "/var/run/docker.sock:/var/run/docker.sock"
```

```text
Runtime platform                                    arch=amd64 os=linux pid=14092 revision=7545f44e version=16.8.0
Running with gitlab-runner 16.8.0 (7545f44e)
  on Local Host Executor

Preparing the "docker" executor
00:02
Using Docker executor with image golang:1.22-alpine ...
Pulling docker image golang:1.22-alpine ...
Using docker image sha256:7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b for golang:1.22-alpine with digest golang@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae4...
Preparing environment
00:01
Running on runner--project-0-concurrent-0 via localhost...
Getting source from Git repository
00:01
Initialized empty Git repository in /builds/0/project-0/.git/
Fetching changes...
Created fresh repository.
Checking out a1b2c3d4 as detached HEAD...
Skipping Git submodules setup
Restoring cache
00:01
Checking cache for default-1...
Downloading cache.tar.gz from https://minio.enterprise.internal/gitlab-runner-cache/default-1 
Successfully extracted cache
Executing "step_script" stage of the job script
00:08
$ mkdir -p .go/pkg/mod
$ export GOPATH=$CI_PROJECT_DIR/.go
$ go test -v -race -coverprofile=coverage.txt ./...
=== RUN   TestDatabaseConnectionPool
--- PASS: TestDatabaseConnectionPool (0.11s)
=== RUN   TestPaymentProcessingSuccess
--- PASS: TestPaymentProcessingSuccess (0.42s)
PASS
coverage: 88.4% of statements
Saving cache for successful job
00:02
Creating cache default-1...
.go/pkg/mod/: found 412 files
.cache/: found 84 files
Created cache
Job succeeded
```

---

### 4.3 Verificación de Estado de GitOps y Operadores de Kubernetes

Inspección del estado de sincronización y convergencia de recursos a través de la CLI de Argo CD:

```bash
$ argocd app get payment-service-prod --server argocd.enterprise.internal:443 --auth-token $ARGO_AUTH_TOKEN
```

```text
Name:               argocd/payment-service-prod
Project:            default
Server:             https://kubernetes.default.svc
Namespace:          production
URL:                https://argocd.enterprise.internal/applications/payment-service-prod
Repo:               https://gitlab.enterprise.internal/platform/gitops-manifests.git
Target:             HEAD
Path:               environments/production/payment-service
Sync Window:        Sync Allowed
Sync Status:        Synced to HEAD (a1b2c3d)
Health Status:      Healthy

GROUP  KIND        NAMESPACE   NAME                   STATUS  HEALTH   HOOK  MESSAGE
       Service     production  payment-service        Synced  Healthy        service/payment-service created
apps   Deployment  production  payment-service        Synced  Healthy        deployment.apps/payment-service configured
autoscaling HorizontalPodAutoscaler production payment-service-hpa Synced Healthy horizontalpodautoscaler.autoscaling/payment-service-hpa created

CONDITION  STATUS  MESSAGE
---        ---     ---
```

```bash
$ kubectl get pods -n production -l app=payment-service -o wide
```

```text
NAME                               READY   STATUS    RESTARTS   AGE     IP            NODE           NOMINATED NODE   READINESS GATES
payment-service-58977d44-2x7kn     1/1     Running   0          4m12s   10.244.3.45   worker-node-1   <none>           <none>
payment-service-58977d44-8p9qm     1/1     Running   0          4m12s   10.244.4.89   worker-node-2   <none>           <none>
payment-service-58977d44-l4z1x     1/1     Running   0          4m12s   10.244.1.12   worker-node-3   <none>           <none>
```

---

## 5. Protocolo de Verificación, Diagnóstico de Fallos y Solución de Problemas (Troubleshooting)

Cuando las etapas del pipeline fallan o la sincronización de estado de GitOps sufre deriva, los SRE deben aplicar procedimientos diagnósticos sistemáticos y guiados por registros (logs).

```
                  +---------------------------------------------------+
                  |            Pipeline Execution Failure             |
                  +---------------------------------------------------+
                                            │
               ┌────────────────────────────┴────────────────────────────┐
               ▼                                                         ▼
    [ Runner / Infrastructure ]                               [ Pipeline Application ]
               │                                                         │
   ┌───────────┴───────────┐                                 ┌───────────┴───────────┐
   ▼                       ▼                                 ▼                       ▼
[ DinD Daemon   ]  [ OOM Killed / ]                       [ Sonar Gate   ]   [ GitOps Sync   ]
[ Deadlock      ]  [ Pod Limits   ]                       [ Timeout      ]   [ Drift         ]
```

### 5.1 Escenario A: Bloqueo Mutuo (Deadlock) de Socket en Docker-in-Docker (DinD) y Fallo del Demon (Daemon)

#### Causa Raíz
Una alta concurrencia provoca que el socket compartido de Docker (`/var/run/docker.sock`) o el motor de almacenamiento sidecar del contenedor DinD (`overlay2`) agoten los descriptores de archivo disponibles o entren en bloqueo mutuo (deadlock) en archivos de bloqueo (lockfiles).

#### Protocolo Diagnóstico
Inspeccionar los registros del sistema (system logs) del host que ejecuta el executor runner:

```bash
$ journalctl -u docker.service --since "10 minutes ago" --no-pager | grep -iE "error|timeout|driver"
```

```text
Aug 07 04:35:12 runner-node-01 dockerd[1244]: time="2026-08-07T04:35:12.102938475-04:00" level=error msg="Handler for POST /v1.44/build returned error: error backing up activation file: open /var/lib/docker/overlay2/our-lock: device or resource busy"
Aug 07 04:35:15 runner-node-01 dockerd[1244]: time="2026-08-07T04:35:15.892019283-04:00" level=fatal msg="Error starting daemon: layer store locked"
```

#### Remediación
1. Migrar de la arquitectura DinD / socket compartido a motores de build de contenedores sin raíz (rootless) como **Kaniko** o **Buildah**.
2. Forzar un bucle de recolección de basura (garbage collection) en contenedores zombi y capas de builder no vinculadas:

```bash
$ docker system prune --all --force --volumes
```

---

### 5.2 Escenario B: Tiempo de Espera Agotado (Timeout) del Quality Gate de SonarQube

#### Causa Raíz
El servidor de SonarQube está sobrecargado por tareas de análisis concurrentes en segundo plano (saturación de la cola del Compute Engine), lo que provoca que el paso `waitForQualityGate` en el pipeline alcance su límite de tiempo de ejecución.

#### Protocolo Diagnóstico
Consultar el endpoint de la API del Compute Engine de SonarQube para extraer la profundidad de la cola:

```bash
$ curl -s -u "${SONAR_TOKEN}:" "https://sonarqube.enterprise.internal/api/ce/component?component=payment-service" | jq .
```

```json
{
  "queue": [
    {
      "id": "AY8x9z0A1B2C3D4E5F6G",
      "type": "REPORT",
      "componentId": "AV-x12345678",
      "componentKey": "payment-service",
      "componentName": "Payment Service",
      "status": "PENDING",
      "submittedAt": "2026-08-07T04:31:00-0400",
      "executedAt": null,
      "executionTimeMs": 0
    }
  ],
  "current": null
}
```

#### Remediación
1. Ajustar la escala de los workers del Compute Engine de SonarQube (`sonar.ce.workerCount`) en `sonar.properties`.
2. Incrementar los tiempos de espera (timeouts) de sondeo (polling) del pipeline de manera gradual para gestionar picos de carga de procesamiento de CI:

```groovy
timeout(time: 30, unit: 'MINUTES') {
    waitForQualityGate abortPipeline: true
}
```

---

### 5.3 Escenario C: Desincronización (Out-of-Sync) en GitOps y Deriva por Mutación de Recursos

#### Causa Raíz
Un comando manual fuera de banda (por ejemplo, `kubectl edit deployment`) alteró el estado del clúster en vivo, lo que provocó que Argo CD informe un estado `OutofSync` debido a un delta de esquema con el repositorio de Git.

#### Protocolo Diagnóstico
Comparar (diff) el estado del clúster en vivo contra el estado objetivo deseado especificado en Git:

```bash
$ argocd app diff payment-service-prod --server argocd.enterprise.internal:443
```

```diff
===== apps/Deployment production/payment-service ======
--- Live Manifest
+++ Target Manifest
@@ -18,7 +18,7 @@
     spec:
       containers:
       - name: payment-service
-        image: registry.enterprise.internal/platform/payment-service:1.3.99
+        image: registry.enterprise.internal/platform/payment-service:1.4.102
-        resources:
-          limits:
-            cpu: "4"
+        resources:
+          limits:
+            cpu: "2"
```

#### Remediación
Forzar una reconciliación inmediata y habilitar la autoreparación (self-healing) automatizada para sobrescribir las mutaciones fuera de banda:

```bash
$ argocd app sync payment-service-prod --force --prune
$ argocd app set payment-service-prod --self-heal
```

---

## 6. Referencias

* **Visión General y Objetivos de LPI DevOps Tools Engineer:**  
  [https://www.lpi.org/our-certifications/devops-tools-engineer-overview/](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
* **Documentación de Usuario y Sintaxis de Declarative Pipeline de Jenkins:**  
  [https://www.jenkins.io/doc/book/pipeline/syntax/](https://www.jenkins.io/doc/book/pipeline/syntax/)
* **Documentación Oficial y Referencia de GitLab CI/CD:**  
  [https://docs.gitlab.com/ee/ci/](https://docs.gitlab.com/ee/ci/)
* **Argo CD - GitOps CD Declarativo para Kubernetes:**  
  [https://argo-cd.readthedocs.io/en/stable/](https://argo-cd.readthedocs.io/en/stable/)
* **Mejores Prácticas de Continuous Delivery Foundation (CDF):**  
  [https://cd.foundation/](https://cd.foundation/)
* **Especificación de Imagen de Open Container Initiative (OCI):**  
  [https://opencontainers.org/](https://opencontainers.org/)