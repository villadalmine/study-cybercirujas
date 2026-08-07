# LPI DevOps Tools Engineer (701-100) — Topic 1.4: Continuous Integration and Continuous Delivery

---

## 1. Architectural Motivation & Production Problem Statement

In enterprise systems engineering, the legacy software delivery cycle was characterized by monolithic release schedules, long-lived feature branches, and manual environment promotion. This pattern introduces severe systemic friction:

```
[ Developer Branch 1 ] ──┐
[ Developer Branch 2 ] ──┼──> [ Long-lived Integration Branch ] ──> [ Manual QA Gate ] ──> [ High-Risk Monolithic Release ]
[ Developer Branch 3 ] ──┘         (Severe Merge Conflicts)             (State Drift)            (High MTTR / Low Velocity)
```

### 1.1 The Production Anti-Patterns

1. **Integration Hell & Branch Divergence:** When feature branches diverge from `main` over days or weeks, merging code triggers exponential conflict complexity. The mathematical complexity of manual merging scales quadratically relative to the number of unmerged commits and active branches.
2. **Environment & Configuration Drift:** Environments (Development, Staging, Pre-Production, Production) managed imperatively drift over time. Code tested in Staging fails in Production due to undocumented OS dependencies, uncoordinated library updates, or asymmetric network topologies.
3. **High Blast Radius & Prolonged Mean Time to Recovery (MTTR):** Releasing large, multi-component batches makes identifying root causes during production outages difficult. Rollback procedures for monolithic deployments often involve complex database schema downgrades and state reconciliations, extending downtime.
4. **Manual Quality Gates & Human Error:** Relying on manual testing checklists and human-driven deployment steps introduces operational fatigue, inconsistent validation, and security compliance gaps (e.g., untracked secrets, unvetted third-party dependencies).

### 1.2 The SRE & Platform Architecture Solution

Continuous Integration (CI) and Continuous Delivery/Deployment (CD) convert software delivery into an automated, predictable, deterministic, and idempotent pipeline governed by a Directed Acyclic Graph (DAG).

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

* **Continuous Integration (CI):** Developers merge code into a shared baseline (ideally daily). Every push triggers an automated build engine that executes static code analysis (SAST), unit testing, dependency scanning, and binary artifact packaging.
* **Continuous Delivery (CDelivery):** Every validated build automatically deploys to a staging environment and prepares a production-ready immutable artifact. Production deployment requires a single programmatic or human approval step.
* **Continuous Deployment (CDeployment):** Validated changes automatically flow through staging into production without manual intervention, guarded by telemetry-driven SLO gates and automated canary analysis.

---

## 2. Technical Comparisons & Architecture Trade-Offs

### 2.1 Branching Strategies

| Metric / Dimension | Trunk-Based Development (TBD) | GitFlow | Feature Branching (GitHub Flow) |
| :--- | :--- | :--- | :--- |
| **Integration Frequency** | Multiple times per day | Weekly / Bi-weekly / Release cycles | End of feature completion (1–3 days) |
| **Branch Lifetime** | Short (< 24 hours) | Long-lived (`develop`, `release/*`) | Short-to-Medium (1–3 days) |
| **Merge Complexity** | Minimal (constant small rebases) | Extremely high (release branch merges) | Low-to-Moderate |
| **Feature Isolation** | Managed via Feature Toggles/Flags | Isolated in release/feature branches | Isolated in topic branches |
| **Pipeline Trigger Mode** | Micro-builds per commit on `main` | Multi-stage builds across branches | Build on Pull/Merge Request |
| **Best Suited For** | High-velocity microservices, SRE teams | Legacy software with scheduled releases | Web applications, open-source projects |

### 2.2 Deployment Strategies

| Dimension | Blue/Green Deployment | Canary Deployment | Rolling Update | Shadow (Mirroring) |
| :--- | :--- | :--- | :--- | :--- |
| **Blast Radius** | High (100% traffic cutover) | Progressive (1% → 5% → 25% → 100%) | Moderate (1/N pods updated sequentially) | Zero (Traffic mirrored without user impact) |
| **Resource Overhead** | +100% duplicate infrastructure | +10% to +25% during rollout | +0% to +25% max surge capacity | +100% duplicate compute stack |
| **Rollback Latency** | Near instantaneous (Router switch) | Instantaneous (Traffic weight to 0) | Slow (Sequential inverse pod replacement) | Instantaneous (Stop mirror rule) |
| **State / DB Safety** | Requires backward-compatible schema | Requires backward-compatible schema | Requires backward-compatible schema | Must discard shadow writes (read-only) |
| **Telemetry Coupling** | Manual smoke testing or post-switch metric | Deep coupling with Prometheus/Datadog | Basic readiness/liveness probe reliance | Comparators evaluate shadow vs live outputs |

### 2.3 CI Engine Architectures

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

## 3. Production Manifests & Pipeline Infrastructure

### 3.1 Declarative Jenkinsfile (`Jenkinsfile`)

This complete, production-ready declarative pipeline incorporates dynamic agent allocation via Kubernetes pods, sequential execution stages, parallel testing, SonarQube quality gates, Docker buildx containerization, Nexus push, and Helm dynamic canary deployments.

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

### 3.2 Production GitLab CI/CD Pipeline (`.gitlab-ci.yml`)

This complete `.gitlab-ci.yml` pipeline defines dynamic staging environments, SAST analysis, container caching, automated testing, manual promotion gates, and cleanup triggers.

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

### 3.3 GitOps Declarative Manifest (Argo CD `Application`)

This manifest configures GitOps continuous deployment by binding a remote repository state to a live Kubernetes cluster.

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

## 4. Real CLI Commands & Terminal Execution Logs

### 4.1 Jenkins CLI & REST API Inspection

Executing a remote build trigger via the Jenkins CLI interface and evaluating build status:

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

### 4.2 GitLab CI Local Debugging (`gitlab-runner`)

Testing a pipeline job locally using `gitlab-runner exec`:

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

### 4.3 GitOps & Kubernetes Operator State Verification

Inspecting synchronization status and resource convergence via Argo CD CLI:

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

## 5. Verification, Failure Diagnostics & Troubleshooting Protocol

When pipeline stages fail or GitOps state synchronization drifts, SREs must apply systematic, log-driven diagnostic procedures.

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

### 5.1 Scenario A: Docker-in-Docker (DinD) Socket Deadlock & Daemon Failure

#### Root Cause
High concurrency causes the shared Docker socket (`/var/run/docker.sock`) or DinD container sidecar storage engine (`overlay2`) to exhaust available file descriptors or deadlock on lockfiles.

#### Diagnostic Protocol
Inspect the system logs of the host running the executor runner:

```bash
$ journalctl -u docker.service --since "10 minutes ago" --no-pager | grep -iE "error|timeout|driver"
```

```text
Aug 07 04:35:12 runner-node-01 dockerd[1244]: time="2026-08-07T04:35:12.102938475-04:00" level=error msg="Handler for POST /v1.44/build returned error: error backing up activation file: open /var/lib/docker/overlay2/our-lock: device or resource busy"
Aug 07 04:35:15 runner-node-01 dockerd[1244]: time="2026-08-07T04:35:15.892019283-04:00" level=fatal msg="Error starting daemon: layer store locked"
```

#### Remediation
1. Migrate from DinD / shared socket architecture to rootless container build engines such as **Kaniko** or **Buildah**.
2. Force a garbage collection loop on zombie containers and unlinked builder layers:

```bash
$ docker system prune --all --force --volumes
```

---

### 5.2 Scenario B: SonarQube Quality Gate Timeout

#### Root Cause
The SonarQube server is overwhelmed by concurrent background analysis tasks (Compute Engine queue saturation), causing the `waitForQualityGate` step in the pipeline to hit its execution deadline.

#### Diagnostic Protocol
Query the SonarQube Compute Engine API endpoint to extract queue depth:

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

#### Remediation
1. Adjust the scale of SonarQube Compute Engine workers (`sonar.ce.workerCount`) in `sonar.properties`.
2. Increase pipeline polling timeouts gracefully to handle peak CI processing loads:

```groovy
timeout(time: 30, unit: 'MINUTES') {
    waitForQualityGate abortPipeline: true
}
```

---

### 5.3 Scenario C: GitOps Out-of-Sync & Resource Mutation Drift

#### Root Cause
An out-of-band manual command (e.g., `kubectl edit deployment`) altered live cluster state, causing Argo CD to report an `OutofSync` status due to a schema delta with the Git repository.

#### Diagnostic Protocol
Diff the live cluster state against the desired target state specified in Git:

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

#### Remediation
Force immediate reconciliation and enable automated self-healing to override out-of-band mutations:

```bash
$ argocd app sync payment-service-prod --force --prune
$ argocd app set payment-service-prod --self-heal
```

---

## 6. References

* **LPI DevOps Tools Engineer Overview & Objectives:**  
  [https://www.lpi.org/our-certifications/devops-tools-engineer-overview/](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
* **Jenkins User Documentation & Declarative Pipeline Syntax:**  
  [https://www.jenkins.io/doc/book/pipeline/syntax/](https://www.jenkins.io/doc/book/pipeline/syntax/)
* **GitLab CI/CD Official Documentation & Reference:**  
  [https://docs.gitlab.com/ee/ci/](https://docs.gitlab.com/ee/ci/)
* **Argo CD - Declarative GitOps CD for Kubernetes:**  
  [https://argo-cd.readthedocs.io/en/stable/](https://argo-cd.readthedocs.io/en/stable/)
* **Continuous Delivery Foundation (CDF) Best Practices:**  
  [https://cd.foundation/](https://cd.foundation/)
* **Open Container Initiative (OCI) Image Specification:**  
  [https://opencontainers.org/](https://opencontainers.org/)