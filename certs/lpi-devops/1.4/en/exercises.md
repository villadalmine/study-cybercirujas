# LPI DevOps Tools Engineer (Exam 701-100, v1.0)
## Topic 701.4: Continuous Integration and Continuous Delivery (Weight: 8.34)

### Official Reference Documentation
* **LPI DevOps Tools Engineer Overview**: [https://www.lpi.org/our-certifications/devops-tools-engineer-overview/](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
* **Jenkins User Handbook & Pipeline Syntax**: [https://www.jenkins.io/doc/book/pipeline/](https://www.jenkins.io/doc/book/pipeline/)
* **GitLab CI/CD Official Documentation**: [https://docs.gitlab.com/ee/ci/](https://docs.gitlab.com/ee/ci/)
* **Kubernetes Deployment Strategies & Rollouts**: [https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#strategy](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#strategy)

---

### Architectural Overview & Core Principles

Continuous Integration (CI) and Continuous Delivery/Deployment (CD) form the backbone of modern platform engineering. 
* **Continuous Integration**: Requires developers to commit code to a shared repository multiple times a day. Every commit triggers an automated build and test sequence. The goal is to detect integration errors within minutes.
* **Continuous Delivery**: Ensures that every code change passing the automated test suite is automatically packaged, tested in production-like staging environments, and ready for zero-downtime deployment to production at any given moment.
* **Continuous Deployment**: Extends Continuous Delivery by automatically releasing every passing build straight to production without human intervention.

```
 +-----------------------------------------------------------------------------------+
 |                               CONTINUOUS INTEGRATION                              |
 |  +---------------+    +---------------+    +---------------+    +---------------+ |
 |  |  Source Code  |--->| Automated     |--->|  Unit & Lint  |--->| Build Docker  | |
 |  |  Commit (Git) |    | Trigger (Hook)|    |  Testing      |    | Image/Artifact| |
 |  +---------------+    +---------------+    +---------------+    +---------------+ |
 +-------------------------------------------------------------------------|---------+
                                                                           v
 +-----------------------------------------------------------------------------------+
 |                               CONTINUOUS DELIVERY                                 |
 |  +---------------+    +---------------+    +---------------+    +---------------+ |
 |  | Push to Image |--->| Deploy to     |--->| Integration & |--->| Ready for     | |
 |  | Registry      |    | Staging (K8s) |    | Smoke Tests   |    | Production    | |
 |  +---------------+    +---------------+    +---------------+    +---------------+ |
 +-------------------------------------------------------------------------|---------+
                                                                           v (Automated or 1-Click)
 +-----------------------------------------------------------------------------------+
 |                              CONTINUOUS DEPLOYMENT                                |
 |  +------------------------------------------------------------------------------+  |
 |  | Production Deployment (Canary / Blue-Green) + Automated Health Metrics Check |  |
 |  +------------------------------------------------------------------------------+  |
 +-----------------------------------------------------------------------------------+
```

---

### Guided Exercise 1: Advanced Jenkins Declarative Pipeline with Docker Agents, Credentials, and Secret Masking

#### Objective
Build a production-grade, syntactically valid Jenkins Declarative Pipeline (`Jenkinsfile`) utilizing an isolated Docker agent container, safe credential injection, static code analysis, parallel execution, and structured notification handling.

#### Step 1.1: Environment Preparation and Jenkins CLI Authentication
Inspect the Jenkins controller environment via `jenkins-cli` and verify plugin availability and worker agent readiness.

Execute the following commands on your terminal:

```bash
# Export Jenkins credentials and URL
export JENKINS_URL="http://localhost:8080"
export JENKINS_USER="admin"
export JENKINS_API_TOKEN="11a62961d7a31b46a9e223d7023190ab"

# Download Jenkins CLI jar from server
curl -sO ${JENKINS_URL}/jnlpJars/jenkins-cli.jar

# Query Jenkins node list and plugin status
java -jar jenkins-cli.jar -s ${JENKINS_URL} -auth ${JENKINS_USER}:${JENKINS_API_TOKEN} list-nodes
java -jar jenkins-cli.jar -s ${JENKINS_URL} -auth ${JENKINS_USER}:${JENKINS_API_TOKEN} list-plugins | grep -E "(docker|git|workflow-aggregator)"
```

**Expected Output:**
```text
Name         Description   # Executors   State
Built-In Node  Local node    4             In Service
agent-linux-01 Linux Worker  2             In Service

docker-workflow            Docker Pipeline                   1.29         Success
git                        Git plugin                        5.2.1        Success
workflow-aggregator        Pipeline                          596.v8c21... Success
```

#### Step 1.2: Construct the Complete Declarative `Jenkinsfile`
Create a pipeline script containing isolated agent allocation, secret management via `withCredentials`, parallel steps, and post-execution hooks.

Save the following complete file as `Jenkinsfile`:

```groovy
pipeline {
    agent {
        docker {
            image 'golang:1.22-alpine'
            args '-v /var/run/docker.sock:/var/run/docker.sock -u 0:0'
        }
    }
    
    options {
        timeout(time: 30, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '10'))
        disableConcurrentBuilds()
        ansiColor('xterm')
    }

    environment {
        APP_NAME       = 'payment-gateway'
        REGISTRY_HOST  = 'registry.internal.net'
        REGISTRY_CREDS = credentials('docker-registry-production-key')
    }

    stages {
        stage('Initialize & Lint') {
            steps {
                echo "Initializing build workspace for ${env.APP_NAME}..."
                sh '''
                    go version
                    apk add --no-libc-dev git curl gcc musl-dev
                    go install golang.org/x/lint/golint@latest
                    golint -set_exit_status ./...
                '''
            }
        }

        stage('Parallel Quality Gate') {
            parallel {
                stage('Unit Tests') {
                    steps {
                        sh '''
                            go test -v -race -coverprofile=coverage.out ./...
                        '''
                    }
                }
                stage('Security Scan') {
                    steps {
                        sh '''
                            go install github.com/securego/gosec/v2/cmd/gosec@latest
                            gosec -fmt=json -out=security-report.json ./...
                        '''
                    }
                }
            }
        }

        stage('Build & Push Artifact') {
            steps {
                withCredentials([usernamePassword(credentialsId: 'docker-registry-production-key', usernameVariable: 'REG_USER', passwordVariable: 'REG_PASS')]) {
                    sh '''
                        echo "$REG_PASS" | docker login "$REGISTRY_HOST" -u "$REG_USER" --password-stdin
                        docker build -t ${REGISTRY_HOST}/${APP_NAME}:${BUILD_NUMBER} -t ${REGISTRY_HOST}/${APP_NAME}:latest .
                        docker push ${REGISTRY_HOST}/${APP_NAME}:${BUILD_NUMBER}
                        docker push ${REGISTRY_HOST}/${APP_NAME}:latest
                        docker logout "$REGISTRY_HOST"
                    '''
                }
            }
        }
    }

    post {
        always {
            archiveArtifacts artifacts: 'security-report.json, coverage.out', allowEmptyArchive: true
            cleanWs deleteDirs: true, notFailBuild: true
        }
        success {
            echo "Pipeline completed successfully for Build #${env.BUILD_NUMBER}."
        }
        failure {
            echo "Pipeline failed! Alerting SRE On-Call..."
        }
    }
}
```

#### Step 1.3: Trigger Jenkins Pipeline and Monitor Streamed Output
Trigger the job execution via `jenkins-cli` and watch build logs in real-time.

Execute:

```bash
java -jar jenkins-cli.jar -s ${JENKINS_URL} -auth ${JENKINS_USER}:${JENKINS_API_TOKEN} build payment-gateway-pipeline -f -v
```

**Expected Output:**
```text
Started by user admin
Obtained Jenkinsfile from git https://git.internal.net/platform/payment-gateway.git
[Pipeline] Start of Pipeline
[Pipeline] node
Running on agent-linux-01 in /workspace/payment-gateway-pipeline
[Pipeline] isUnix
[Pipeline] sh
+ docker inspect -f . golang:1.22-alpine
.
[Pipeline] withDockerContainer
agent-linux-01 does not seem to be running inside a container
$ docker run -t -d -u 0:0 -v /var/run/docker.sock:/var/run/docker.sock ... golang:1.22-alpine cat
[Pipeline] {
[Pipeline] stage (Initialize & Lint)
[Pipeline] sh
+ go version
go version go1.22.0 linux/amd64
+ golint -set_exit_status ./...
[Pipeline] stage (Parallel Quality Gate)
[Pipeline] parallel
[Pipeline] { (Branch: Unit Tests)
[Pipeline] { (Branch: Security Scan)
...
[Pipeline] stage (Build & Push Artifact)
[Pipeline] withCredentials
Masking supported pattern matches of $REG_PASS
+ echo **** | docker login registry.internal.net -u admin-ci --password-stdin
WARNING! Your password will be stored unencrypted in /root/.docker/config.json.
Login Succeeded
[Pipeline] // withCredentials
[Pipeline] post
[Pipeline] archiveArtifacts
Archiving artifacts
[Pipeline] cleanWs
[Pipeline] Finished: SUCCESS
```

---

#### Comprehension Check: Exercise 1

##### Question 1.1
What is the precise security function of `withCredentials` in Jenkins Declarative pipelines, and what happens if a script attempts to execute `echo "$REG_PASS"` to stdout inside that block?

##### Question 1.2
In the Jenkins Declarative syntax, what is the operational difference between configuring `agent { docker { ... } }` at the root `pipeline` level versus configuring it inside a specific `stage` block?

---

### Guided Exercise 2: Production GitLab CI/CD Pipeline Architecture with Caching, Dynamic Environments, and Runner Orchestration

#### Objective
Configure a complete, multi-stage, syntactically valid `.gitlab-ci.yml` pipeline that leverages DAG (Directed Acyclic Graph) execution, distributed caching, secure runner tags, and dynamic deployment environments.

#### Step 2.1: Register and Inspect a Dedicated GitLab Runner
Register an isolated `docker` executor runner with the local GitLab instance using `gitlab-runner CLI`.

Execute:

```bash
# Register runner non-interactively
sudo gitlab-runner register \
  --non-interactive \
  --url "https://gitlab.internal.net/" \
  --registration-token "GR1348941tX9zY2aB_pQ8z" \
  --executor "docker" \
  --docker-image "alpine:3.19" \
  --description "prod-sre-runner-01" \
  --tag-list "docker,linux,high-perf" \
  --run-untagged="false" \
  --locked="false" \
  --docker-volumes "/var/run/docker.sock:/var/run/docker.sock" \
  --docker-privileged="false"

# Verify runner status
sudo gitlab-runner verify
```

**Expected Output:**
```text
Runtime platform                                    arch=amd64 os=linux pid=4012 revision=f5da3c5a version=16.8.0
Running in system-mode.                            
                                                   
Verifying runner... is alive                        runner=tX9zY2aB
```

#### Step 2.2: Construct the Complete Production `.gitlab-ci.yml`
Save the following configuration as `.gitlab-ci.yml` in the root of your Git repository:

```yaml
stages:
  - prepare
  - test
  - package
  - deploy

variables:
  DOCKER_DRIVER: overlay2
  DOCKER_TLS_CERTDIR: ""
  IMAGE_TAG: $CI_REGISTRY_IMAGE:$CI_COMMIT_SHA
  CACHE_KEY: "deps-go-$CI_COMMIT_REF_SLUG"

default:
  tags:
    - docker
    - linux
  interruptible: true

.go-cache: &go-cache-config
  cache:
    key: $CACHE_KEY
    paths:
      - .go/pkg/mod/
    policy: pull-push

fetch-deps:
  stage: prepare
  image: golang:1.22-alpine
  <<: *go-cache-config
  script:
    - export GOPATH=$CI_PROJECT_DIR/.go
    - go mod download
  rules:
    - changes:
        - go.mod
        - go.sum

unit-testing:
  stage: test
  image: golang:1.22-alpine
  <<: *go-cache-config
  cache:
    policy: pull
  script:
    - export GOPATH=$CI_PROJECT_DIR/.go
    - go test -v -coverprofile=coverage.txt ./...
  artifacts:
    name: "coverage-$CI_COMMIT_SHA"
    expire_in: 7 days
    paths:
      - coverage.txt
    reports:
      coverage_report:
        coverage_format: cobertura
        path: coverage.txt

build-container-image:
  stage: package
  image: docker:25.0-alpine
  services:
    - docker:25.0-dind
  needs:
    - job: unit-testing
      artifacts: false
  script:
    - echo "$CI_REGISTRY_PASSWORD" | docker login $CI_REGISTRY -u $CI_REGISTRY_USER --password-stdin
    - docker build --build-arg VERSION=$CI_COMMIT_SHA -t $IMAGE_TAG -t $CI_REGISTRY_IMAGE:latest .
    - docker push $IMAGE_TAG
    - docker push $CI_REGISTRY_IMAGE:latest
  rules:
    - if: '$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'

deploy-to-staging:
  stage: deploy
  image: bitnami/kubectl:1.29
  environment:
    name: staging
    url: https://staging.internal.net
    on_stop: stop-staging-env
  script:
    - kubectl config set-cluster k8s-cluster --server=$KUBERNETES_SERVER --insecure-skip-tls-verify=true
    - kubectl config set-credentials ci-user --token=$KUBERNETES_TOKEN
    - kubectl config set-context k8s-ctx --cluster=k8s-cluster --user=ci-user --namespace=staging
    - kubectl config use-context k8s-ctx
    - kubectl set image deployment/payment-app payment-app=$IMAGE_TAG --record
    - kubectl rollout status deployment/payment-app --timeout=120s
  rules:
    - if: '$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'

stop-staging-env:
  stage: deploy
  image: bitnami/kubectl:1.29
  environment:
    name: staging
    action: stop
  script:
    - kubectl delete namespace staging-dynamic-$CI_COMMIT_REF_SLUG || true
  rules:
    - if: '$CI_COMMIT_BRANCH != $CI_DEFAULT_BRANCH'
      when: manual
```

#### Step 2.3: Validate GitLab CI Syntax and Pipeline Execution DAG
Validate the pipeline structure using the GitLab CI lint API via `curl`.

Execute:

```bash
# Convert YAML to JSON string and validate against GitLab CI Lint API
jq --slurp --raw-input '{content: .}' .gitlab-ci.yml > payload.json

curl -s --header "Content-Type: application/json" \
     --header "PRIVATE-TOKEN: glpat-v9X_z88a7BqP1Lm09xY" \
     --data @payload.json \
     "https://gitlab.internal.net/api/v4/ci/lint" | jq .
```

**Expected Output:**
```json
{
  "valid": true,
  "errors": [],
  "warnings": [],
  "merged_yaml": "stages:\n  - prepare\n  - test\n  - package\n  - deploy..."
}
```

---

#### Comprehension Check: Exercise 2

##### Question 2.1
What is the structural difference between `artifacts` and `cache` in GitLab CI/CD pipelines regarding persistence, storage backend, and target usage across non-sequential jobs or branches?

##### Question 2.2
In the `build-container-image` job, what does the `needs: [{ job: unit-testing, artifacts: false }]` key specify, and how does it change pipeline execution compared to standard sequential stage ordering?

---

### Guided Exercise 3: Advanced Continuous Delivery - Zero-Downtime Blue-Green & Canary Deployment Strategies

#### Objective
Implement a production-grade Kubernetes traffic split strategy executing Blue-Green and Canary deployments using native manifests and CLI automation to handle health checks and automated rollback.

```
                   [ INGRESS / ROUTER ]
                            |
                 +----------+----------+
                 | (Traffic Split: 90%/10%)
                 v                     v
        +------------------+  +------------------+
        | Service: BLUE    |  | Service: GREEN   |
        | Version: v1.1.0  |  | Version: v1.2.0  |
        | (Production Main)|  | (Canary Stage)   |
        +------------------+  +------------------+
                 |                     |
                 v                     v
          [ Pods: v1.1.0 ]      [ Pods: v1.2.0 ]
```

#### Step 3.1: Deploy Baseline Blue Workload and Service Infrastructure
Create the active "Blue" deployment (`v1.1.0`) along with its dedicated router service.

Save the following complete manifest as `blue-green-app.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-service-blue
  namespace: production
  labels:
    app: payment-service
    version: "1.1.0"
spec:
  replicas: 3
  selector:
    matchLabels:
      app: payment-service
      version: "1.1.0"
  template:
    metadata:
      labels:
        app: payment-service
        version: "1.1.0"
    spec:
      containers:
      - name: app
        image: registry.internal.net/payment-api:1.1.0
        ports:
        - containerPort: 8080
        readinessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 3
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: payment-service-live
  namespace: production
spec:
  type: ClusterIP
  ports:
  - port: 80
    targetPort: 8080
    protocol: TCP
    name: http
  selector:
    app: payment-service
    version: "1.1.0"
```

Apply the baseline manifest:

```bash
kubectl create namespace production --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f blue-green-app.yaml
kubectl rollout status deployment/payment-service-blue -n production --timeout=60s
```

**Expected Output:**
```text
namespace/production created
deployment.apps/payment-service-blue created
service/payment-service-live created
Waiting for deployment "payment-service-blue" rollout to finish: 0 of 3 updated replicas are available...
Waiting for deployment "payment-service-blue" rollout to finish: 1 of 3 updated replicas are available...
Waiting for deployment "payment-service-blue" rollout to finish: 2 of 3 updated replicas are available...
deployment "payment-service-blue" successfully rolled out
```

#### Step 3.2: Deploy Green Workload (v1.2.0) Alongside Blue
Deploy the upgraded application build ("Green") into the production cluster without exposing it to public live traffic yet.

Save the following manifest as `green-deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-service-green
  namespace: production
  labels:
    app: payment-service
    version: "1.2.0"
spec:
  replicas: 3
  selector:
    matchLabels:
      app: payment-service
      version: "1.2.0"
  template:
    metadata:
      labels:
        app: payment-service
        version: "1.2.0"
    spec:
      containers:
      - name: app
        image: registry.internal.net/payment-api:1.2.0
        ports:
        - containerPort: 8080
        readinessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 3
```

Apply and verify deployment health:

```bash
kubectl apply -f green-deployment.yaml
kubectl rollout status deployment/payment-service-green -n production --timeout=60s
```

**Expected Output:**
```text
deployment.apps/payment-service-green created
deployment "payment-service-green" successfully rolled out
```

#### Step 3.3: Execute Zero-Downtime Blue-Green Traffic Switch and Validation
Instantly switch live production traffic from Blue (`1.1.0`) to Green (`1.2.0`) by modifying the selector on `payment-service-live`.

Execute:

```bash
# Patch live service selector to point to version 1.2.0
kubectl patch service payment-service-live -n production -p '{"spec":{"selector":{"version":"1.2.0"}}}'

# Inspect endpoints to confirm IP mapping update
kubectl get endpoints payment-service-live -n production
```

**Expected Output:**
```text
service/payment-service-live patched
NAME                   ENDPOINTS                                     AGE
payment-service-live   10.244.1.45:8080,10.244.2.12:8080,10.244.3.88:8080   5m12s
```

#### Step 3.4: Perform Automated Health Verification and Emergency Rollback
Simulate an automated post-deployment health check failure and execute an instant rollback if HTTP checks fail.

Execute the following verification and rollback script:

```bash
#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="production"
SERVICE="payment-service-live"
PREVIOUS_VERSION="1.1.0"
CURRENT_VERSION="1.2.0"

echo "Executing post-deployment HTTP health probes on ${SERVICE}..."

# Port-forward temporarily to run health checks
kubectl port-forward svc/${SERVICE} 8888:80 -n ${NAMESPACE} > /dev/null 2>&1 &
FORWARD_PID=$!

sleep 2

# Perform 5 health check attempts
HEALTH_FAILED=0
for i in {1..5}; do
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8888/healthz || echo "000")
  if [ "$HTTP_STATUS" -ne 200 ]; then
    echo "Check $i failed with status: $HTTP_STATUS"
    HEALTH_FAILED=$((HEALTH_FAILED + 1))
  else
    echo "Check $i passed with status: 200"
  fi
  sleep 1
done

kill $FORWARD_PID || true

if [ "$HEALTH_FAILED" -gt 0 ]; then
  echo "CRITICAL: Health checks failed ($HEALTH_FAILED failures)! Reverting traffic to ${PREVIOUS_VERSION}..."
  kubectl patch service ${SERVICE} -n ${NAMESPACE} -p "{\"spec\":{\"selector\":{\"version\":\"${PREVIOUS_VERSION}\"}}}"
  echo "Rollback completed. Removing broken Green deployment..."
  kubectl scale deployment/payment-service-green --replicas=0 -n ${NAMESPACE}
  exit 1
else
  echo "SUCCESS: All health probes passed. Decommissioning Blue deployment (${PREVIOUS_VERSION})..."
  kubectl scale deployment/payment-service-blue --replicas=0 -n ${NAMESPACE}
fi
```

**Expected Output (Successful Verification):**
```text
Executing post-deployment HTTP health probes on payment-service-live...
Check 1 passed with status: 200
Check 2 passed with status: 200
Check 3 passed with status: 200
Check 4 passed with status: 200
Check 5 passed with status: 200
SUCCESS: All health probes passed. Decommissioning Blue deployment (1.1.0)...
deployment.apps/payment-service-blue scaled
```

---

#### Comprehension Check: Exercise 3

##### Question 3.1
In Kubernetes rolling updates (`RollingUpdate`), what are the exact roles of `maxSurge` and `maxUnavailable`, and what risk is introduced if `maxUnavailable: 100%` is configured during a deployment update?

##### Question 3.2
Compare Blue-Green deployments with Canary deployments in terms of infrastructure resource cost, blast radius control, and routing mechanism requirements.

---

### Guided Exercise 4: Advanced CI/CD Diagnostics, Failure Analysis, and Performance Optimization

#### Objective
Apply diagnostic techniques to troubleshoot hanging Jenkins pipelines, stuck GitLab Runners, Docker-in-Docker socket permissions, and container image layer caching bottlenecks.

#### Step 4.1: Diagnose Jenkins Build Agent Deadlocks via Thread Dumps and CLI Diagnostics
When a Jenkins pipeline freezes without logging output, extract thread dumps directly via the CLI to isolate deadlocked worker threads.

Execute:

```bash
# Fetch thread dump from Jenkins controller
java -jar jenkins-cli.jar -s ${JENKINS_URL} -auth ${JENKINS_USER}:${JENKINS_API_TOKEN} thread-dump > jenkins_threads.txt

# Search thread dump for blocked threads or IO waits
grep -A 10 -i "BLOCKED" jenkins_threads.txt || echo "No BLOCKED threads detected."
grep -B 2 -A 8 "hudson.remoting.Channel" jenkins_threads.txt | head -n 15
```

**Expected Output:**
```text
"RPC handler agent-linux-01" prio=5 tid=0x00007f8a1402a800 nid=0x4a11 waiting on condition [0x00007f89eb7fd000]
   java.lang.Thread.State: TIMED_WAITING (parking)
	at sun.misc.Unsafe.park(Native Method)
	- parking to wait for  <0x00000000f0a12b88> (java.util.concurrent.locks.AbstractQueuedSynchronizer$ConditionObject)
	at java.util.concurrent.locks.LockSupport.parkNanos(LockSupport.java:215)
	at hudson.remoting.Request$Finished.get(Request.java:571)
	at hudson.remoting.Request.call(Request.java:209)
	at hudson.remoting.Channel.call(Channel.java:999)
```

#### Step 4.2: Troubleshoot GitLab Runner Docker-in-Docker (DinD) Socket Failures
Diagnose common permission and connection errors encountered when building Docker images inside unprivileged GitLab CI runner containers.

Run the following test inside a runner environment:

```bash
# Test socket accessibility and TLS settings
docker info
```

**Diagnostic Output (Error Scenario):**
```text
Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?
```

**Remediation Command Execution:**
Update `/etc/gitlab-runner/config.toml` on the runner host to correctly mount `/var/run/docker.sock` or enable privileged mode for DinD:

```bash
# Check current config.toml settings for runner
sudo grep -A 12 "\[runners.docker\]" /etc/gitlab-runner/config.toml
```

**Expected Output (Corrected Configuration):**
```toml
  [runners.docker]
    tls_verify = false
    image = "alpine:3.19"
    privileged = true
    disable_entrypoint_overwrite = false
    oom_kill_disable = false
    disable_cache = false
    volumes = ["/var/run/docker.sock:/var/run/docker.sock", "/cache"]
    shm_size = 2147483648
```

#### Step 4.3: Optimize Container Image Build Caching in Pipelines
Rewrite an unoptimized multi-stage `Dockerfile` to leverage layer caching, reducing build time from minutes to seconds in CI pipelines.

Save the following optimized multi-stage file as `Dockerfile`:

```dockerfile
# Syntax directive for BuildKit cache mounts
# syntax=docker/dockerfile:1.4

# Stage 1: Build binary with cache mounts
FROM golang:1.22-alpine AS builder
WORKDIR /app

RUN apk add --no-libc-dev git ca-certificates tzdata

# Cache dependency layer separately
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

COPY . .

# Build statically linked binary
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux go build -ldflags="-w -s" -o /bin/server .

# Stage 2: Minimal scratch production image
FROM scratch
COPY --from=builder /usr/share/zoneinfo /usr/share/zoneinfo
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /bin/server /server

EXPOSE 8080
USER 65534:65534
ENTRYPOINT ["/server"]
```

Build using Docker BuildKit to verify execution time and cache hits:

```bash
DOCKER_BUILDKIT=1 docker build --progress=plain -t payment-api:optimized .
```

**Expected Output:**
```text
#1 [internal] load build definition from Dockerfile
#1 copying dockerfile: 712b done
#2 [builder 3/6] COPY go.mod go.sum ./
#2 CACHED
#3 [builder 4/6] RUN --mount=type=cache,target=/go/pkg/mod go mod download
#3 CACHED
#4 [builder 6/6] RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build CGO_ENABLED=0 GOOS=linux go build...
#4 CACHED
#5 exporting to image
#5 writing image sha256:8f3a... done
#5 naming to docker.io/library/payment-api:optimized done
Successfully built payment-api:optimized
```

---

#### Comprehension Check: Exercise 4

##### Question 4.1
In a Dockerized GitLab CI environment utilizing Docker-in-Docker (`dind`), what security risk does enabling `privileged = true` introduce to the underlying host node, and what is the safer alternative using user space container builders (e.g., Kaniko or Buildah)?

##### Question 4.2
Why is ordering instructions in a `Dockerfile` critical for CI pipeline speed, and why should `COPY go.mod go.sum ./` precede `COPY . .`?

---

<details>
<summary>Comprehension Check Answers and Detailed Explanations</summary>

### Exercise 1 Answers

#### Answer 1.1
* **Security Function**: The `withCredentials` wrapper binds Jenkins stored credential objects (passwords, tokens, SSH keys) to local environment variables strictly within the block's execution context. Jenkins automatically intercepts stdout/stderr streams emitted by any child process spawned inside this block and replaces instances matching secret values with `****` (asterisk masking).
* **Behavior on `echo "$REG_PASS"`**: The secret string will **not** be exposed in the build logs. Jenkins log sanitizer detects the value stored in `$REG_PASS` and masks it outputting `****`. However, writing secrets to disk files or encoding them (e.g., `echo "$REG_PASS" | base64`) bypasses text-matching maskers and must be strictly avoided.

#### Answer 1.2
* **Global Agent (`pipeline { agent { docker { ... } } }`)**: Spawns a single container instance at the start of the build. The entire workspace is mounted inside this container, and **all** stages execute within this isolated container environment unless explicitly overridden.
* **Stage-level Agent (`stage { agent { docker { ... } } }`)**: The controller runs steps outside a container by default, but provisions a specific Docker container dynamically **only** for the duration of that specific stage. This allows multi-language pipelines (e.g., a Node.js lint stage followed by a Go build stage) to execute in isolated, language-specific runtime environments without cluttering a single monolith build image.

---

### Exercise 2 Answers

#### Answer 2.1
* **Artifacts**:
  * **Purpose**: Used to transfer intermediate build outputs (binaries, test reports, coverage XMLs) **between sequential stages** within a single pipeline run.
  * **Storage**: Uploaded directly to the GitLab Coordinator instance (or S3 object storage bucket configured in GitLab).
  * **Persistence**: Temporary; governed by `expire_in` (e.g., 7 days). They can be downloaded via the GitLab UI/API.
* **Cache**:
  * **Purpose**: Used to speed up build times by storing project dependencies (e.g., `node_modules/`, `.go/pkg/mod/`) **across multiple pipeline executions** and branches.
  * **Storage**: Stored locally on the runner host or in a shared distributed bucket (MinIO/S3).
  * **Persistence**: Long-term, not guaranteed to exist (runners can purge local caches). Caches are **never** passed as build results to end users.

#### Answer 2.2
* **Function of `needs: [{ job: unit-testing, artifacts: false }]`**: It implements a **Directed Acyclic Graph (DAG)** pipeline. The `build-container-image` job will start executing **immediately** as soon as `unit-testing` completes successfully, without waiting for other unrelated jobs in the `test` stage to finish.
* **Effect of `artifacts: false`**: Prevents the `build-container-image` job from downloading any artifacts produced by `unit-testing`, saving network bandwidth and IO build time.

---

### Exercise 3 Answers

#### Answer 3.1
* **`maxSurge`**: Defines the maximum number of Pods that can be created **above** the desired replica count during an update (e.g., `25%` on 4 replicas allows 5 Pods max).
* **`maxUnavailable`**: Defines the maximum number of Pods that can be unavailable/terminated **below** the desired replica count during the update.
* **Risk of `maxUnavailable: 100%`**: If set to 100%, Kubernetes will terminate **all existing production Pods simultaneously** before starting new ones. This causes a complete service outage (downtime) until the new image is pulled and container readiness probes pass.

#### Answer 3.2
* **Resource Cost**: Blue-Green requires **200% capacity** (doubling active computing nodes/pods during deployment), making it expensive. Canary starts with minimal extra capacity (e.g., +10% to +20%).
* **Blast Radius**: Blue-Green switches 100% of production traffic instantly upon cutover; if a hidden bug eludes health checks, all users are impacted simultaneously. Canary exposes only a tiny fraction of users (e.g., 5%) to the new version while monitoring metrics (Prometheus error rates/latency).
* **Routing Requirements**: Blue-Green simply requires switching a Service selector or DNS/Ingress endpoint target. Canary requires an advanced Service Mesh (Istio, Linkerd) or Ingress Controller (Nginx Ingress, Argo Rollouts) capable of weighted HTTP traffic splitting (e.g., 95% to v1, 5% to v2).

---

### Exercise 4 Answers

#### Answer 4.1
* **Security Risk of `privileged = true`**: Grants the Docker container full root capabilities on the host kernel, effectively disabling Docker isolation barriers. A compromised container or malicious code in a build step can escape the container, modify host kernel parameters, access host devices, and compromise the host node.
* **Safer Alternative**: Rootless / unprivileged image builders like **Kaniko** or **Buildah**. They build container images from a `Dockerfile` inside standard unprivileged containers without requiring a running Docker daemon or socket access (`/var/run/docker.sock`).

#### Answer 4.2
* **Reasoning**: Docker executes `Dockerfile` instructions sequentially and caches the resulting filesystem layer at each step. If a layer change is detected, that layer and **all subsequent layers** invalidate their cache and must re-execute.
* **Why split `go.mod` from code**: Source code changes frequently, whereas dependencies (`go.mod`, `go.sum`) change infrequently. By running `COPY go.mod go.sum ./` followed by `go mod download` *before* `COPY . .`, Docker caches the heavy dependency download layer. Subsequent code-only commits reuse the cached dependency layer, reducing build times dramatically.

</details>