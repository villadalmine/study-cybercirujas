# LPI DevOps Tools Engineer (Exam 701-100, v1.0)
## Topic 701.4: Continuous Integration and Continuous Delivery (Weight: 8.34)

### Documentación Oficial de Referencia
* **LPI DevOps Tools Engineer Overview**: [https://www.lpi.org/our-certifications/devops-tools-engineer-overview/](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
* **Jenkins User Handbook & Pipeline Syntax**: [https://www.jenkins.io/doc/book/pipeline/](https://www.jenkins.io/doc/book/pipeline/)
* **GitLab CI/CD Official Documentation**: [https://docs.gitlab.com/ee/ci/](https://docs.gitlab.com/ee/ci/)
* **Kubernetes Deployment Strategies & Rollouts**: [https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#strategy](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#strategy)

---

### Resumen Arquitectónico y Principios Fundamentales

Continuous Integration (CI) y Continuous Delivery/Deployment (CD) forman la columna vertebral de la ingeniería de plataformas moderna. 
* **Continuous Integration**: Requiere que los desarrolladores hagan commit de código a un repositorio compartido múltiples veces al día. Cada commit desencadena una secuencia automatizada de build y pruebas. El objetivo es detectar errores de integración en cuestión de minutos.
* **Continuous Delivery**: Garantiza que cada cambio de código que supere la suite de pruebas automatizadas se empaquete automáticamente, se pruebe en entornos de staging similares a producción y esté listo para un deployment en producción sin tiempo de inactividad (zero-downtime) en cualquier momento.
* **Continuous Deployment**: Extiende Continuous Delivery liberando automáticamente cada build aprobada directamente a producción sin intervención humana.

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

### Ejercicio Guiado 1: Declarative Pipeline Avanzado de Jenkins con Agentes Docker, Credenciales y Enmascaramiento de Secretos

#### Objetivo
Construir un Declarative Pipeline de Jenkins (`Jenkinsfile`) de grado de producción y sintácticamente válido, utilizando un contenedor agente de Docker aislado, inyección segura de credenciales, análisis estático de código, ejecución en paralelo y manejo estructurado de notificaciones.

#### Paso 1.1: Preparación del Entorno y Autenticación en Jenkins CLI
Inspeccioná el entorno del controller de Jenkins mediante `jenkins-cli` y verificá la disponibilidad de plugins y la preparación de los worker agents.

Ejecutá los siguientes comandos en tu terminal:

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

#### Paso 1.2: Construir el `Jenkinsfile` Declarativo Completo
Creá un script de pipeline que contenga asignación de agentes aislados, gestión de secretos mediante `withCredentials`, pasos en paralelo y hooks de post-ejecución.

Guardá el siguiente archivo completo como `Jenkinsfile`:

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

#### Paso 1.3: Disparar el Pipeline de Jenkins y Monitorear la Salida en Tiempo Real
Dispará la ejecución del job mediante `jenkins-cli` y observá los logs de build en tiempo real.

Ejecutá:

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

#### Control de Comprensión: Ejercicio 1

##### Pregunta 1.1
¿Cuál es la función de seguridad precisa de `withCredentials` en los Declarative pipelines de Jenkins y qué sucede si un script intenta ejecutar `echo "$REG_PASS"` a stdout dentro de ese bloque?

##### Pregunta 1.2
En la sintaxis de Jenkins Declarative, ¿cuál es la diferencia operativa entre configurar `agent { docker { ... } }` a nivel raíz de `pipeline` en comparación con configurarlo dentro de un bloque `stage` específico?

---

### Ejercicio Guiado 2: Arquitectura de Pipeline de GitLab CI/CD de Producción con Caching, Entornos Dinámicos y Orquestación de Runners

#### Objetivo
Configurar un pipeline `.gitlab-ci.yml` completo, multi-stage y sintácticamente válido que aproveche la ejecución DAG (Directed Acyclic Graph), caching distribuido, tags seguros de runner y entornos de deployment dinámicos.

#### Paso 2.1: Registrar e Inspeccionar un GitLab Runner Dedicado
Registrá un runner ejecutor `docker` aislado con la instancia local de GitLab utilizando `gitlab-runner CLI`.

Ejecutá:

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

#### Paso 2.2: Construir el `.gitlab-ci.yml` Completo de Producción
Guardá la siguiente configuración como `.gitlab-ci.yml` en la raíz de tu repositorio de Git:

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

#### Paso 2.3: Validar la Sintaxis de GitLab CI y el DAG de Ejecución del Pipeline
Validá la estructura del pipeline utilizando la API de lint de GitLab CI a través de `curl`.

Ejecutá:

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

#### Control de Comprensión: Ejercicio 2

##### Pregunta 2.1
¿Cuál es la diferencia estructural entre `artifacts` y `cache` en los pipelines de GitLab CI/CD en lo que respecta a la persistencia, el backend de almacenamiento y el uso objetivo a través de jobs o ramas no secuenciales?

##### Pregunta 2.2
En el job `build-container-image`, ¿qué especifica la clave `needs: [{ job: unit-testing, artifacts: false }]` y cómo cambia la ejecución del pipeline en comparación con el ordenamiento secuencial estándar de stages?

---

### Ejercicio Guiado 3: Continuous Delivery Avanzado - Estrategias de Deployment Blue-Green y Canary sin Tiempo de Inactividad (Zero-Downtime)

#### Objetivo
Implementar una estrategia de división de tráfico (traffic split) en Kubernetes de grado de producción ejecutando deployments Blue-Green y Canary utilizando manifiestos nativos y automatización por CLI para gestionar health checks y rollback automatizado.

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

#### Paso 3.1: Desplegar la Carga de Trabajo Blue Inicial y la Infraestructura de Service
Creá el deployment "Blue" activo (`v1.1.0`) junto con su service de enrutamiento dedicado.

Guardá el siguiente manifiesto completo como `blue-green-app.yaml`:

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

Aplicá el manifiesto inicial:

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

#### Paso 3.2: Desplegar la Carga de Trabajo Green (v1.2.0) junto a Blue
Desplegá la versión actualizada de la aplicación ("Green") en el cluster de producción sin exponerla aún al tráfico público en vivo.

Guardá el siguiente manifiesto como `green-deployment.yaml`:

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

Aplicá y verificá la salud del deployment:

```bash
kubectl apply -f green-deployment.yaml
kubectl rollout status deployment/payment-service-green -n production --timeout=60s
```

**Expected Output:**
```text
deployment.apps/payment-service-green created
deployment "payment-service-green" successfully rolled out
```

#### Paso 3.3: Ejecutar la Conmutación de Tráfico Blue-Green sin Tiempo de Inactividad y la Validación
Conmutá instantáneamente el tráfico de producción en vivo de Blue (`1.1.0`) a Green (`1.2.0`) modificando el selector en `payment-service-live`.

Ejecutá:

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

#### Paso 3.4: Realizar Verificación Automatizada de Salud y Rollback de Emergencia
Simulá una falla automatizada de comprobación de salud (health check) posterior al deployment y ejecutá un rollback instantáneo si fallan las verificaciones HTTP.

Ejecutá el siguiente script de verificación y rollback:

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

#### Control de Comprensión: Ejercicio 3

##### Pregunta 3.1
En las actualizaciones progresivas (`RollingUpdate`) de Kubernetes, ¿cuáles son los roles exactos de `maxSurge` y `maxUnavailable`, y qué riesgo se introduce si se configura `maxUnavailable: 100%` durante la actualización de un deployment?

##### Pregunta 3.2
Compará los deployments Blue-Green con los deployments Canary en términos de costo de recursos de infraestructura, control del radio de impacto (blast radius) y requerimientos del mecanismo de enrutamiento.

---

### Ejercicio Guiado 4: Diagnóstico Avanzado de CI/CD, Análisis de Fallas y Optimización del Rendimiento

#### Objetivo
Aplicar técnicas de diagnóstico para solucionar problemas de pipelines de Jenkins congelados, GitLab Runners atascados, permisos de socket en Docker-in-Docker y cuellos de botella en el caching de capas de imágenes de contenedor.

#### Paso 4.1: Diagnosticar Bloqueos Mutuos (Deadlocks) en Agentes de Build de Jenkins mediante Thread Dumps y Diagnósticos por CLI
Cuando un pipeline de Jenkins se congela sin emitir logs de salida, extraé thread dumps directamente mediante la CLI para aislar los hilos de worker en deadlock.

Ejecutá:

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

#### Paso 4.2: Solucionar Fallas de Socket en Docker-in-Docker (DinD) de GitLab Runner
Diagnosticá errores comunes de permisos y conexión que ocurren al construir imágenes de Docker dentro de contenedores ejecutor de GitLab CI no privilegiados.

Ejecutá la siguiente prueba dentro del entorno de un runner:

```bash
# Test socket accessibility and TLS settings
docker info
```

**Diagnostic Output (Error Scenario):**
```text
Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?
```

**Remediation Command Execution:**
Actualizá `/etc/gitlab-runner/config.toml` en el host del runner para montar correctamente `/var/run/docker.sock` o habilitar el modo privilegiado para DinD:

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

#### Paso 4.3: Optimizar el Caching de Construcción de Imágenes de Contenedor en Pipelines
Reescribí un `Dockerfile` multi-stage no optimizado para aprovechar el caching de capas, reduciendo el tiempo de build de minutos a segundos en los pipelines de CI.

Guardá el siguiente archivo multi-stage optimizado como `Dockerfile`:

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

Construí utilizando Docker BuildKit para verificar el tiempo de ejecución y los aciertos de cache (cache hits):

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

#### Control de Comprensión: Ejercicio 4

##### Pregunta 4.1
En un entorno de GitLab CI dockerizado que utiliza Docker-in-Docker (`dind`), ¿qué riesgo de seguridad introduce habilitar `privileged = true` en el nodo host subyacente y cuál es la alternativa más segura utilizando constructores de contenedores en espacio de usuario (por ejemplo, Kaniko o Buildah)?

##### Pregunta 4.2
¿Por qué el orden de las instrucciones en un `Dockerfile` es crítico para la velocidad del pipeline de CI y por qué `COPY go.mod go.sum ./` debería preceder a `COPY . .`?

---

<details>
<summary>Comprehension Check Answers and Detailed Explanations</summary>

### Respuestas del Ejercicio 1

#### Respuesta 1.1
* **Función de Seguridad**: El wrapper `withCredentials` vincula objetos de credenciales almacenados en Jenkins (contraseñas, tokens, claves SSH) a variables de entorno locales estrictamente dentro del contexto de ejecución del bloque. Jenkins intercepta automáticamente los flujos de stdout/stderr emitidos por cualquier proceso hijo generado dentro de este bloque y reemplaza las instancias que coincidan con los valores secretos por `****` (enmascaramiento con asteriscos).
* **Comportamiento en `echo "$REG_PASS"`**: La cadena secreta **no** se expondrá en los logs de build. El depurador de logs de Jenkins detecta el valor almacenado en `$REG_PASS` y lo enmascara mostrando `****`. Sin embargo, escribir secretos en archivos de disco o codificarlos (por ejemplo, `echo "$REG_PASS" | base64`) elude los enmascaradores de coincidencia de texto y debe evitarse estrictamente.

#### Respuesta 1.2
* **Agente Global (`pipeline { agent { docker { ... } } }`)**: Genera una única instancia de contenedor al inicio de la build. Todo el workspace se monta dentro de este contenedor y **todos** los stages se ejecutan dentro de este entorno de contenedor aislado a menos que se reemplace explícitamente.
* **Agente a Nivel de Stage (`stage { agent { docker { ... } } }`)**: El controller ejecuta los pasos fuera de un contenedor de forma predeterminada, pero aprovisiona un contenedor Docker específico dinámicamente **solo** durante la duración de ese stage en particular. Esto permite que los pipelines multilenguaje (por ejemplo, un stage de lint de Node.js seguido de un stage de build de Go) se ejecuten en entornos de ejecución aislados y específicos de cada lenguaje sin recargar una única imagen de build monolítica.

---

### Respuestas del Ejercicio 2

#### Respuesta 2.1
* **Artifacts**:
  * **Propósito**: Se utilizan para transferir salidas intermedias de build (binarios, reportes de prueba, XMLs de cobertura) **entre stages secuenciales** dentro de una misma ejecución del pipeline.
  * **Almacenamiento**: Se cargan directamente en la instancia de GitLab Coordinator (o en un bucket de almacenamiento de objetos S3 configurado en GitLab).
  * **Persistencia**: Temporal; gobernada por `expire_in` (por ejemplo, 7 días). Se pueden descargar a través de la UI/API de GitLab.
* **Cache**:
  * **Propósito**: Se utiliza para acelerar los tiempos de build almacenando dependencias del proyecto (por ejemplo, `node_modules/`, `.go/pkg/mod/`) **a través de múltiples ejecuciones de pipelines** y ramas.
  * **Almacenamiento**: Se almacena localmente en el host del runner o en un bucket distribuido compartido (MinIO/S3).
  * **Persistencia**: A largo plazo, sin garantía de existencia (los runners pueden purgar los caches locales). Los caches **nunca** se entregan como resultados de build a los usuarios finales.

#### Respuesta 2.2
* **Función de `needs: [{ job: unit-testing, artifacts: false }]`**: Implementa un pipeline de tipo **Grafos Acíclicos Dirigidos (DAG)**. El job `build-container-image` comenzará a ejecutarse **inmediatamente** tan pronto como `unit-testing` se complete con éxito, sin esperar a que finalicen otros jobs no relacionados en el stage `test`.
* **Efecto de `artifacts: false`**: Evita que el job `build-container-image` descargue artefactos producidos por `unit-testing`, ahorrando ancho de banda de red y tiempo de E/S de build.

---

### Respuestas del Ejercicio 3

#### Respuesta 3.1
* **`maxSurge`**: Define la cantidad máxima de Pods que se pueden crear por **encima** del número deseado de réplicas durante una actualización (por ejemplo, `25%` en 4 réplicas permite un máximo de 5 Pods).
* **`maxUnavailable`**: Define la cantidad máxima de Pods que pueden estar no disponibles/terminados por **debajo** del número deseado de réplicas durante la actualización.
* **Riesgo de `maxUnavailable: 100%`**: Si se establece en 100%, Kubernetes terminará **todos los Pods de producción existentes simultáneamente** antes de iniciar los nuevos. Esto causa una interrupción completa del servicio (downtime) hasta que se descargue la nueva imagen y se aprueben las comprobaciones de readiness del contenedor.

#### Respuesta 3.2
* **Costo de Recursos**: Blue-Green requiere **200% de capacidad** (duplicando los nodos/pods de cómputo activos durante el deployment), lo que lo hace costoso. Canary comienza con un mínimo de capacidad adicional (por ejemplo, del +10% al +20%).
* **Radio de Impacto (Blast Radius)**: Blue-Green conmuta el 100% del tráfico de producción instantáneamente al hacer el cambio; si un error oculto elude las comprobaciones de salud, todos los usuarios se ven impactados al mismo tiempo. Canary expone solo a una pequeña fracción de usuarios (por ejemplo, el 5%) a la nueva versión mientras monitorea métricas (tasas de error/latencia de Prometheus).
* **Requerimientos de Enrutamiento**: Blue-Green simplemente requiere cambiar un selector de Service o el destino de un endpoint de DNS/Ingress. Canary requiere un Service Mesh avanzado (Istio, Linkerd) o un Ingress Controller (Nginx Ingress, Argo Rollouts) capaz de realizar división ponderada de tráfico HTTP (por ejemplo, 95% a v1, 5% a v2).

---

### Respuestas del Ejercicio 4

#### Respuesta 4.1
* **Riesgo de Seguridad de `privileged = true`**: Otorga al contenedor Docker capacidades completas de root en el kernel del host, desactivando efectivamente las barreras de aislamiento de Docker. Un contenedor comprometido o código malicioso en un paso de build puede escapar del contenedor, modificar parámetros del kernel del host, acceder a dispositivos del host y comprometer el nodo host.
* **Alternativa Más Segura**: Constructores de imágenes rootless / no privilegiados como **Kaniko** o **Buildah**. Construyen imágenes de contenedor a partir de un `Dockerfile` dentro de contenedores estándar no privilegiados sin requerir un demonio de Docker en ejecución ni acceso a socket (`/var/run/docker.sock`).

#### Respuesta 4.2
* **Razonamiento**: Docker ejecuta las instrucciones del `Dockerfile` de forma secuencial y almacena en cache la capa resultante del sistema de archivos en cada paso. Si se detecta un cambio en una capa, esa capa y **todas las capas subsiguientes** invalidan su cache y deben volverse a ejecutar.
* **Por qué separar `go.mod` del código**: El código fuente cambia con frecuencia, mientras que las dependencias (`go.mod`, `go.sum`) cambian con poca frecuencia. Al ejecutar `COPY go.mod go.sum ./` seguido de `go mod download` *antes* de `COPY . .`, Docker almacena en cache la pesada capa de descarga de dependencias. Los commits posteriores que solo modifiquen código reutilizan la capa de dependencias en cache, reduciendo drásticamente los tiempos de build.

</details>