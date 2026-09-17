# LPI DevOps Tools Engineer (701-100) - Tópico 1.1: Desenvolvimento Moderno de Software

---

## 1. Motivação Arquitetural de Produção e Definição do Problema

### 1.1 O Gargalo do Monólito Legado
Em ambientes corporativos legados, as aplicações são tradicionalmente construídas como bases de código monolíticas únicas, onde a lógica de negócio, as camadas de acesso a dados, o processamento em segundo plano e a apresentação web compartilham um único processo de runtime e espaço de memória.

```
                                  +-------------------------------------------------------+
                                  |                 MONOLITHIC RUNTIME                    |
                                  |                                                       |
                                  |  +-----------------+  +----------------------------+  |
                                  |  |   UI / Layout   |  |   Auth & User Directory    |  |
                                  |  +-----------------+  +----------------------------+  |
                                  |  |   Order Engine  |  |   Payment Processing       |  |
                                  |  +-----------------+  +----------------------------+  |
                                  |  |   Inventory     |  |   Notification Engine      |  |
                           +----->|  +-----------------+  +----------------------------+  |<-----+
                           |      +-------------------------------------------------------+      |
                           |                                  |                                  |
                           |                                  v                                  |
                           |               +-------------------------------------+               |
                           |               |      SHARED RDBMS (Single SPOF)      |               |
                           |               +-------------------------------------+               |
                           |                                                                     |
                           |                                                                     |
+----------------------------------------------------+               +----------------------------------------------------+
| FAIL-STOP SCENARIO A: Memory Leak                  |               | FAIL-STOP SCENARIO B: Deployment Risk              |
| Payment module leaks heap memory -> OOMKiller      |               | Updating Notification Engine requires redeploying  |
| terminates entire monolith -> Full Outage.         |               | entire 5GB binary -> 15-minute downtime window.    |
+----------------------------------------------------+               +----------------------------------------------------+
```

Da perspectiva de SRE e de Platform Engineering, o modelo monolítico introduz antipadrões operacionais severos em escala:

1. **Raio de Impacto Indiferenciado**: Um vazamento de memória (`java.lang.OutOfMemoryError` ou desreferência de ponteiro não tratada) em um módulo não crítico (por exemplo, geração de PDF) encerra o processo do sistema operacional, derrubando caminhos críticos (por exemplo, o Payment Gateway).
2. **Cadência de Release Acoplada e Atraso de Enfileiramento**: Fazer merge de código exige coordenação contínua entre equipes. Os trens de deployment desaceleram até o ritmo da feature branch mais lenta, aumentando o lead time para mudanças ($T_{lead}$) de horas para semanas.
3. **Escalonamento de Recursos de Granularidade Grossa**: O escalonamento horizontal exige replicar a instância inteira do monólito nos nós de computação. Se o módulo de processamento de pedidos exige alta CPU enquanto o de inventário exige muita memória, a plataforma precisa provisionar nós capazes de satisfazer ambas as restrições simultaneamente, elevando o Custo de Infraestrutura ($OpEx$).
4. **Contenção e Bloqueios de Banco de Dados**: Múltiplas equipes de domínio consultam e modificam um único esquema relacional monolítico. Operações de alta concorrência causam contenção de locks, esgotamento do thread pool e quedas em cascata de conexões com o banco de dados.

---

### 1.2 O Paradigma Cloud-Native de Microservices
Para resolver a dívida operacional do monólito, a engenharia de plataforma moderna decompõe as aplicações em microservices distribuídos, alinhados aos Bounded Contexts do Domain-Driven Design (DDD).

```
       +-----------------------------------------------------------------------------------+
       |                               INGRESS EDGE LAYER                                  |
       |                   API Gateway / Layer 7 Ingress Controller                        |
       +-----------------------------------------------------------------------------------+
                                   |                                |
                      +------------+                                +------------+
                      | gRPC / HTTP2                                             | gRPC / HTTP2
                      v                                                          v
       +-------------------------------+                          +-------------------------------+
       |       ORDER MICROSERVICE      |                          |     PAYMENT MICROSERVICE      |
       |  - Language: Go               |                          |  - Language: Rust             |
       |  - Pod Scale: 10 replicas     |                          |  - Pod Scale: 3 replicas      |
       |  - Disposability: < 2s boot   |                          |  - Disposability: < 500ms boot|
       +-------------------------------+                          +-------------------------------+
                      |                                                          |
                      v                                                          v
       +-------------------------------+                          +-------------------------------+
       |  Isolated PostgreSQL Database |                          |    Isolated Redis Cache / DB  |
       +-------------------------------+                          +-------------------------------+
```

A arquitetura cloud-native desacopla estado, ciclo de vida de processos e rede:

* **Isolamento de Estado**: Cada microservice encapsula estritamente seu mecanismo de armazenamento. Consultas entre domínios ocorrem via contratos de API fortemente tipados (gRPC/Protobuf ou OpenAPI REST), evitando o acoplamento por banco de dados compartilhado.
* **Isolamento de Falhas**: Os limites de computação são restringidos por primitivas do Kernel Linux (`cgroups v2`, `namespaces`, `seccomp`). Uma falha em um pod fica isolada e é automaticamente mitigada pelos orquestradores (Kubernetes) por meio de reinícios automáticos de pods.
* **Elasticidade e Alta Disponibilidade**: O escalonamento independente permite alocação direcionada de recursos. Serviços de alta vazão escalam horizontalmente com rapidez via Horizontal Pod Autoscalers (HPA) guiados por métricas customizadas (por exemplo, taxas de requisições HTTP ou profundidade da fila de mensagens).

---

## 2. Arquiteturas Técnicas e Matrizes de Trade-off

### 2.1 Comparação entre Arquitetura Monolítica, Microservices e Serverless

| Atributo Arquitetural | Arquitetura Monolítica | Arquitetura de Microservices | Serverless / Orientada a Eventos (FaaS) |
| :--- | :--- | :--- | :--- |
| **Unidade de Deployment** | Arquivo único unificado (`.war`, `.jar`, binário fat) | Imagens de container compatíveis com OCI (camadas `.tar`) | Funções / Handlers (`.zip`, runtime de imagem) |
| **Ciclo de Vida do Processo** | Processo de SO de longa duração; gerenciado manualmente ou via Systemd | Microprocessos de longa duração gerenciados pelo Kubernetes | Execução efêmera disparada por eventos (latência de cold start) |
| **Modelo de Consistência de Dados** | Consistência forte (transações ACID via RDBMS) | Consistência eventual (padrão SAGA, padrão Outbox) | Consistência eventual (streaming assíncrono de eventos / PubSub) |
| **Modo de Falha e Raio de Impacto** | Indisponibilidade global diante de exceções de runtime não tratadas | Contido ao limite do microservice; mitigado por retentativas | Contido por invocação; sandbox de runtime isolado |
| **Overhead de Rede** | Invocação de função em memória ($\approx 0\text{ms}$) | Chamadas de rede RPC/HTTP sobre CNI ($\approx 1-10\text{ms}$) | Gateway gerenciado + execução com cold start ($\approx 50-500\text{ms}$) |
| **Complexidade de Observabilidade** | Baixa: agente APM padrão acoplado a um único runtime | Alta: Distributed Tracing (OpenTelemetry), telemetria de mesh | Alta: amostragem de traces distribuídos entre filas do provedor de nuvem |
| **Overhead Operacional** | Baixo overhead de plataforma; alto custo de manutenção da aplicação | Alto overhead de plataforma (Kubernetes, Service Mesh, CI/CD) | Baixo overhead de plataforma; alto lock-in de fornecedor e de ferramental |

---

### 2.2 A Metodologia Twelve-Factor App: Auditoria SRE e Aplicação em Produção

A metodologia 12-Factor App fornece regras sistêmicas para construir software cloud-native escalável. Abaixo está o detalhamento operacional dos 12 fatores:

```
+----------------------------------------------------------------------------------------------------+
|                                    12-FACTOR METHODOLOGY AUDIT                                     |
+------------------------------+----------------------------------+----------------------------------+
| Factor                       | Production Anti-Pattern          | Cloud-Native SRE Pattern         |
+------------------------------+----------------------------------+----------------------------------+
| I. Codebase                  | Multiple apps sharing 1 repo or  | One repo tracked in VCS per app; |
|                              | 1 app spread across repos        | multiple deploys via CI/CD tags  |
+------------------------------+----------------------------------+----------------------------------+
| II. Dependencies             | Implicit reliance on system      | Explicitly isolated via OCI      |
|                              | binaries (`curl`, `python3`)     | multi-stage builds (Distroless)  |
+------------------------------+----------------------------------+----------------------------------+
| III. Config                  | Hardcoded values or config files | Config passed via environment    |
|                              | baked inside image/code          | variables or K8s ConfigMaps      |
+------------------------------+----------------------------------+----------------------------------+
| IV. Backing Services         | Treating local DB different from | Local & remote services treated  |
|                              | cloud DB; hardcoded handles      | as attached resources via URIs   |
+------------------------------+----------------------------------+----------------------------------+
| V. Build, Release, Run       | Mutating code directly on prod   | Strict pipeline separation; immutable|
|                              | servers at runtime               | deployment artifacts with IDs    |
+------------------------------+----------------------------------+----------------------------------+
| VI. Processes                | Storing sticky sessions on local | Stateless execution; shared      |
|                              | filesystem memory                | datastores (Redis) for state     |
+------------------------------+----------------------------------+----------------------------------+
| VII. Port Binding            | Exporting HTTP via host web      | App self-contains HTTP server    |
|                              | servers (Apache/Tomcat)          | and binds to `$PORT` environment |
+------------------------------+----------------------------------+----------------------------------+
| VIII. Concurrency            | Scaling via internal OS threads  | Scale out via process model      |
|                              | on a single huge machine         | (Kubernetes Pod replicas)        |
+------------------------------+----------------------------------+----------------------------------+
| IX. Disposability            | Slow boot times; unhandled       | Fast startup times; graceful     |
|                              | SIGKILL; corrupt state on restart| handling of SIGTERM signals      |
+------------------------------+----------------------------------+----------------------------------+
| X. Dev/Prod Parity           | Long divergence between local    | Continuous Deployment; local dev |
|                              | SQLite and prod Postgres DB      | matches prod via Docker Compose  |
+------------------------------+----------------------------------+----------------------------------+
| XI. Logs                     | Writing log files to local disk  | Unbuffered streams to stdout/err;|
|                              | with custom rotation scripts     | captured by Fluentbit/Vector     |
+------------------------------+----------------------------------+----------------------------------+
| XII. Admin Processes         | Running maintenance scripts      | One-off admin tasks executed as  |
|                              | manually on live web app pod     | ephemeral K8s Jobs in same code  |
+------------------------------+----------------------------------+----------------------------------+
```

---

### 2.3 Matriz de Arquitetura Monorepo vs. Polyrepo

| Métrica / Dimensão | Estratégia Monorepo | Estratégia Polyrepo |
| :--- | :--- | :--- |
| **Visibilidade e Compartilhamento de Código** | Acesso universal entre equipes; refatoração entre serviços simples | Isolamento estrito de fronteiras; código compartilhado distribuído via gerenciadores de pacotes |
| **Desempenho do Controle de Versão** | Exige ferramental de VCS avançado (Git Sparse-Checkout, Bazel, VFS) | Operações git rápidas; repositórios de tamanho pequeno |
| **Gerenciamento de Dependências** | Commits atômicos entre múltiplos microservices; versão única como fonte de verdade | Risco de dependency drift e de "dependency hell" entre repositórios |
| **Execução do Pipeline de CI/CD** | Exige engines de cache com detecção de mudanças (Nx, Turborepo, Bazel) | Pipelines simples por repositório; risco de deploys de múltiplos serviços descoordenados |
| **Controle de Acesso (RBAC)** | Exige permissões de diretório complexas e granulares | Permissões Git nativas no nível do repositório |

---

## 3. Manifests de Produção e Infraestrutura Declarativa

Abaixo estão manifests de produção sintaticamente válidos, demonstrando padrões modernos de deployment para um microservice cloud-native em conformidade com os 12 fatores.

### 3.1 `Dockerfile` Multi-Stage de Produção

```dockerfile
# ==========================================
# STAGE 1: Build & Compilation Environment
# ==========================================
FROM golang:1.22-alpine3.19 AS builder

# Enforce security best practices during build
RUN apk add --no-cache ca-certificates git tzdata \
    && update-ca-certificates

WORKDIR /build

# Copy dependency definitions to optimize layer caching
COPY go.mod go.sum ./
RUN go mod download && go mod verify

# Copy full application source code
COPY . .

# Build static, stripped binary without CGO dependency
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -ldflags="-w -s -X main.Version=v1.4.2 -X main.BuildTime=$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    -o /build/orderservice ./cmd/orderservice

# ==========================================
# STAGE 2: Minimal Security Distroless Runtime
# ==========================================
FROM gcr.io/distroless/static-debian12:nonroot

# Copy security artifacts and binaries from builder
COPY --from=builder /usr/share/zoneinfo /usr/share/zoneinfo
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /build/orderservice /app/orderservice

# Enforce non-root security context (UID 65532 is built into distroless:nonroot)
USER 65532:65532

WORKDIR /app

# Expose HTTP service port and Prometheus metrics port
EXPOSE 8080 9090

# Environmental override for 12-factor port binding
ENV PORT=8080 \
    METRICS_PORT=9090 \
    GIN_MODE=release

# Directly execute binary to ensure it receives PID 1 OS signals (SIGTERM)
ENTRYPOINT ["/app/orderservice"]
```

---

### 3.2 Manifest de Deployment de Produção no Kubernetes (`deployment.yaml`)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-service
  namespace: production
  labels:
    app.kubernetes.io/name: order-service
    app.kubernetes.io/instance: order-service-prod
    app.kubernetes.io/version: "1.4.2"
    app.kubernetes.io/component: api-backend
    app.kubernetes.io/part-of: e-commerce-platform
    app.kubernetes.io/managed-by: argocd
spec:
  replicas: 3
  revisionHistoryLimit: 10
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 25%
      maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: order-service
      app.kubernetes.io/instance: order-service-prod
  template:
    metadata:
      labels:
        app.kubernetes.io/name: order-service
        app.kubernetes.io/instance: order-service-prod
        app.kubernetes.io/version: "1.4.2"
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9090"
        prometheus.io/path: "/metrics"
        checksum/config: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    spec:
      terminationGracePeriodSeconds: 30
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        fsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: order-service
          image: registry.production.internal/apps/order-service:v1.4.2
          imagePullPolicy: IfNotPresent
          command: ["/app/orderservice"]
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          env:
            - name: PORT
              value: "8080"
            - name: METRICS_PORT
              value: "9090"
            - name: ENVIRONMENT
              value: "production"
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: order-service-db-credentials
                  key: DATABASE_URL
            - name: REDIS_HOST
              valueFrom:
                configMapKeyRef:
                  name: order-service-config
                  key: REDIS_HOST
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
              port: 8080
            initialDelaySeconds: 2
            periodSeconds: 3
            failureThreshold: 10
          livenessProbe:
            httpGet:
              path: /healthz/liveness
              port: 8080
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /healthz/readiness
              port: 8080
            periodSeconds: 5
            timeoutSeconds: 2
            successThreshold: 1
            failureThreshold: 2
```

---

### 3.3 Infraestrutura de Apoio no Kubernetes (`config-services.yaml`)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: order-service-config
  namespace: production
data:
  REDIS_HOST: "redis-cluster.cache.production.internal:6379"
  LOG_LEVEL: "info"
  LOG_FORMAT: "json"
---
apiVersion: v1
kind: Service
metadata:
  name: order-service
  namespace: production
  labels:
    app.kubernetes.io/name: order-service
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
    app.kubernetes.io/name: order-service
    app.kubernetes.io/instance: order-service-prod
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: order-service-hpa
  namespace: production
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: order-service
  minReplicas: 3
  maxReplicas: 15
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 80
```

---

## 4. Sessões de Terminal Reais e Saídas de Execução

### 4.1 Fluxos de Trabalho Git e Verificação de Trunk-Based Development
Os SREs dependem de históricos git limpos para garantir a auditabilidade durante a integração contínua.

```bash
$ git status
On branch main
Your branch is up to date with 'origin/main'.

nothing to commit, working tree clean

$ git log --graph --oneline --decorate -n 5
* a7f8b91 (HEAD -> main, tag: v1.4.2, origin/main) feat(order): implement grace period shutdown handler (#402)
* c3d2e1f fix(db): configure connection pool max idle lifetime (#399)
* 9b8a7c6 refactor(api): transition metrics endpoint to OpenTelemetry registry (#395)
* 1e2d3c4 docs(architecture): update 12-factor compliance matrix (#390)
* 5f4e3d2 chore(deps): bump golang.org/x/net from 0.17.0 to 0.23.0 (#388)
```

---

### 4.2 Compilação de Imagem Docker Multi-Stage e Auditoria de Segurança

Executar builds de container isola de forma limpa os artefatos de runtime das dependências de compilação.

```bash
$ docker build -t registry.production.internal/apps/order-service:v1.4.2 .
[+] Building 14.2s (15/15) FINISHED                                              docker:default
 => [internal] load build definition from Dockerfile                                       0.0s
 => => transferring dockerfile: 1.25kB                                                   0.0s
 => [internal] load .dockerignore                                                        0.0s
 => => transferring context: 52B                                                         0.0s
 => [internal] load metadata for gcr.io/distroless/static-debian12:nonroot               0.4s
 => [internal] load metadata for docker.io/library/golang:1.22-alpine3.19                0.6s
 => [builder 1/6] FROM docker.io/library/golang:1.22-alpine3.19@sha256:c0d355...         0.0s
 => [stage-1 1/3] FROM gcr.io/distroless/static-debian12:nonroot@sha256:6e0d0a...       0.0s
 => [internal] load build context                                                        0.8s
 => => transferring context: 4.12MB                                                      0.8s
 => [builder 2/6] RUN apk add --no-cache ca-certificates git tzdata                     1.2s
 => [builder 3/6] WORKDIR /build                                                         0.1s
 => [builder 4/6] COPY go.mod go.sum ./                                                  0.1s
 => [builder 5/6] RUN go mod download && go mod verify                                   3.4s
 => [builder 6/6] RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="..."      6.5s
 => [stage-1 2/3] COPY --from=builder /build/orderservice /app/orderservice             0.2s
 => exporting to image                                                                   0.9s
 => => exporting layers                                                                  0.8s
 => => writing image sha256:d8a9f3b1e4c7a6d5c2e1f0b9a8c7d6e5f4a3b2c1                      0.0s
 => => naming to registry.production.internal/apps/order-service:v1.4.2                  0.0s

$ docker images registry.production.internal/apps/order-service:v1.4.2
REPOSITORY                                        TAG       IMAGE ID       CREATED         SIZE
registry.production.internal/apps/order-service   v1.4.2    d8a9f3b1e4c7   2 minutes ago   24.8MB
```

---

### 4.3 Rollout do Deployment no Kubernetes e Status do Cluster

Implantando a infraestrutura nativamente no Kubernetes, verificando a inicialização dos containers e inspecionando os pods em execução.

```bash
$ kubectl apply -f deployment.yaml -f config-services.yaml
configmap/order-service-config created
service/order-service created
horizontalpodautoscaler.autoscaling/order-service-hpa created
deployment.apps/order-service created

$ kubectl rollout status deployment/order-service -n production --timeout=60s
Waiting for deployment "order-service" rollout to finish: 1 decision replicas are available...
Waiting for deployment "order-service" rollout to finish: 2 of 3 updated replicas are available...
deployment "order-service" successfully rolled out

$ kubectl get pods -n production -l app.kubernetes.io/name=order-service -o wide
NAME                             READY   STATUS    RESTARTS   AGE   IP           NODE           NOMINATED NODE   READINESS GATES
order-service-6789b7868d-8x4zk   1/1     Running   0          42s   10.244.2.14  k8s-worker-01  <none>           <none>
order-service-6789b7868d-9l7mq   1/1     Running   0          42s   10.244.3.88  k8s-worker-02  <none>           <none>
order-service-6789b7868d-q5p2v   1/1     Running   0          42s   10.244.1.53  k8s-worker-03  <none>           <none>
```

---

### 4.4 Verificação da API e Telemetria de Observabilidade em Produção

Verificando o port-binding, o logging JSON na saída padrão e a propagação de headers de trace do OpenTelemetry via `curl`.

```bash
$ curl -i -X POST http://order-service.production.internal/api/v1/orders \
    -H "Content-Type: application/json" \
    -H "traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" \
    -d '{"customer_id": "usr_99812", "sku": "SKU-4412", "quantity": 2}'

HTTP/1.1 202 Accepted
Date: Fri, 07 Aug 2026 04:35:52 GMT
Content-Type: application/json; charset=utf-8
Content-Length: 134
Connection: keep-alive
X-Correlation-ID: 4bf92f3577b34da6a3ce929d0e0e4736

{"order_id":"ord_8819234","status":"PENDING_PROCESSING","timestamp":"2026-08-07T04:35:52.104Z","trace_id":"4bf92f3577b34da6a3ce929d0e0e4736"}
```

Verificando os streams de log não bufferizados capturados em `stdout` no container alvo:

```bash
$ kubectl logs deployment/order-service -n production --tail=1 -c order-service
{"level":"info","ts":"2026-08-07T04:35:52.105Z","logger":"order.api","caller":"v1/order.go:88","msg":"Order processing initiated","trace_id":"4bf92f3577b34da6a3ce929d0e0e4736","span_id":"00f067aa0ba902b7","customer_id":"usr_99812","order_id":"ord_8819234","http_status":202,"latency_ms":1.42}
```

---

## 5. Verificação de Falhas, Diagnóstico e Guia de Troubleshooting

```
                                  +-------------------------------------------------------+
                                  |            SRE TROUBLESHOOTING FLOWCHART              |
                                  +-------------------------------------------------------+
                                                              |
                                                              v
                                              /-------------------------------\
                                             /     Pod Status / Behavior?      \
                                             \-------------------------------/
                                              /              |              \
                                             /               |               \
                        +-------------------+         +------+------+         +-------------------+
                        |                             |                     |                     |
                        v                             v                     v                     v
              [ CrashLoopBackOff ]           [ Terminated / OOM ]   [ Stale / Unresponsive ]  [ High Latency / 5xx ]
                        |                             |                     |                     |
                        v                             v                     v                     v
              +-------------------+         +-------------------+ +-------------------+ +-------------------+
              | Scenario C:       |         | Scenario A:       | | Scenario A (Alt): | | Scenario B:       |
              | Liveness Probe    |         | Memory Leak /     | | Zombie Process    | | Cascading Failure |
              | Deadlock          |         | cgroup OOMKilled  | | Ignores SIGTERM   | | Timeout / Mesh  |
              +-------------------+         +-------------------+ +-------------------+ +-------------------+
```

---

### Cenário A: Processos Zumbis e Supressão do Sinal SIGTERM (Problema do PID 1)

#### Hipótese Diagnóstica
O processo em container não termina de forma graciosa dentro do `terminationGracePeriodSeconds` (30s) durante uma atualização de deployment no Kubernetes. O Kubelet é forçado a emitir um `SIGKILL` (sinal 9) não gracioso, causando a perda de transações HTTP em voo e a corrupção de conexões com o banco de dados.

#### Identificação da Causa Raiz
O `Dockerfile` usava um entrypoint em shell-form (`ENTRYPOINT /app/start.sh` ou `CMD ./orderservice`) em vez do array em exec-form (`ENTRYPOINT ["/app/orderservice"]`). O shell (`/bin/sh`) executa como PID 1 e não encaminha os sinais `SIGTERM` recebidos aos processos filhos.

#### Sequência de Verificação e Depuração

Execute `kubectl describe` para verificar o código de saída 137 (`128 + 9 (SIGKILL)`), indicando encerramento não gracioso:

```bash
$ kubectl describe pod order-service-6789b7868d-8x4zk -n production
...
    State:          Terminated
      Reason:       Error
      Exit Code:    137
      Started:      Fri, 07 Aug 2026 04:00:00 GMT
      Finished:     Fri, 07 Aug 2026 04:30:30 GMT
...
```

Inspecione os processos ativos em execução dentro do ambiente do container:

```bash
$ kubectl exec -it order-service-6789b7868d-8x4zk -n production -- ps aux
USER         PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
root           1  0.0  0.0   4248  1420 ?        Ss   04:00   0:00 /bin/sh /app/start.sh
root           7  0.1  0.8 712404 34120 ?        Sl   04:00   0:02 /app/orderservice
```

*Causa Raiz Confirmada*: o PID 1 é `/bin/sh`, que intercepta os sinais sem encaminhá-los ao `/app/orderservice` (PID 7).

#### Matriz de Resolução
1. Converta o entrypoint do `Dockerfile` para o formato de array JSON:
   ```dockerfile
   # INCORRECT (Shell Form):
   # ENTRYPOINT /app/orderservice

   # CORRECT (Exec Form):
   ENTRYPOINT ["/app/orderservice"]
   ```
2. Implemente a escuta nativa de sinais do SO dentro do código da aplicação (`os.Notify` em Go, `process.on('SIGTERM')` em Node.js).

---

### Cenário B: Falhas em Cascata por Ausência de Circuit Breakers e Esgotamento do Connection Pool

#### Hipótese Diagnóstica
Uma degradação localizada de banco de dados downstream causa o esgotamento do thread pool e do connection pool em todas as réplicas de API upstream, disparando HTTP 504 Gateway Timeouts em cascata por toda a plataforma do cluster.

#### Identificação da Causa Raiz
O cliente da aplicação omite timeouts de conexão, timeouts de leitura e padrões de circuit breaking. As requisições recebidas bloqueiam indefinidamente em conexões lentas de banco de dados, consumindo rapidamente memória e workers de thread até que os endpoints de health check falhem.

#### Sequência de Verificação e Depuração

Inspecione os códigos de status HTTP nas fronteiras de ingress do cluster:

```bash
$ kubectl logs -l app.kubernetes.io/name=ingress-nginx -n ingress-nginx --tail=100 \
  | grep "HTTP/1.1\" 504" | head -n 5
2026-08-07T04:36:10Z [error] 142#142: *991201 upstream timed out (110: Connection timed out) while reading response header from upstream, client: 172.16.0.4, server: api.production.internal, request: "GET /api/v1/orders HTTP/1.1", upstream: "http://10.244.2.14:8080/api/v1/orders"
```

Verifique o estado ativo das conexões de banco de dados dentro do container do microservice:

```bash
$ kubectl exec -it order-service-6789b7868d-8x4zk -n production -- netstat -an | grep 5432 | wc -l
100
```

Todas as 100 conexões do limite máximo do pool estão presas em estado `ESTABLISHED` ou `WAITING` sem retornar dados.

#### Matriz de Resolução
1. Imponha timeouts agressivos no cliente, em nível de rede, no código:
   ```go
   // Configure HTTP client with strict timeout context
   ctx, cancel := context.WithTimeout(req.Context(), 2*time.Second)
   defer cancel()
   ```
2. Implemente Service Mesh (Istio / Linkerd) ou Circuit Breaking em nível de aplicação (por exemplo, padrão resilience4j / Hystrix):
   ```yaml
   apiVersion: networking.istio.io/v1alpha3
   kind: DestinationRule
   metadata:
     name: order-service-circuit-breaker
     namespace: production
   spec:
     host: order-service
     trafficPolicy:
       connectionPool:
         tcp:
           maxConnections: 100
         http:
           http1MaxPendingRequests: 10
           maxRequestsPerConnection: 10
       outlierDetection:
         consecutive5xxErrors: 3
         interval: 10s
         baseEjectionTime: 30s
   ```

---

### Cenário C: Liveness Probes Mal Configurados Causando Loops Infinitos de Reinício (CrashLoopBackOff)

#### Hipótese Diagnóstica
Os pods entram em estado permanente de `CrashLoopBackOff` imediatamente sob carga pesada, mesmo que o processo da aplicação esteja executando corretamente.

#### Identificação da Causa Raiz
O `livenessProbe` apontava para um endpoint de API pesado (`/healthz/full-check`) que consulta o banco de dados SQL de forma síncrona. Sob carga, a latência do banco sobe para 3 segundos. O timeout do liveness probe (`timeoutSeconds: 2`) expira, fazendo o Kubelet matar por engano pods saudáveis, agravando a sobrecarga do cluster.

#### Sequência de Verificação e Depuração

Verifique as contagens de reinício dos pods e o histórico de encerramentos:

```bash
$ kubectl get pods -n production -l app.kubernetes.io/name=order-service
NAME                             READY   STATUS CONF   RESTARTS      AGE
order-service-6789b7868d-8x4zk   0/1     CrashLoopBackOff   12 (2m ago)   14m

$ kubectl get events -n production --field-selector reason=Unhealthy --sort-by='.metadata.creationTimestamp'
LAST SEEN   TYPE      REASON      OBJECT                           MESSAGE
2m12s       Warning   Unhealthy   pod/order-service-6789b7868d-8x4zk  Liveness probe failed: HTTP probe failed with statuscode: 500 / timeout after 2s
```

#### Matriz de Resolução
1. Desacople a semântica do Liveness e do Readiness Probe:
   * **Liveness Probe**: Verifica *apenas* o estado interno do processo da aplicação (há deadlock?). **Não** verifique dependências externas (DB, Redis) aqui.
   * **Readiness Probe**: Verifica se a instância consegue, no momento, aceitar tráfego de rede (o DB está conectado?). Se falhar, remove o pod dos endpoints do Service sem matar o processo.
2. Atualize os probes para endpoints leves, em memória:
   ```yaml
   # CORRECT SEPARATION:
   livenessProbe:
     httpGet:
       path: /healthz/liveness # Returns 200 OK statically from memory
       port: 8080
     timeoutSeconds: 1
     periodSeconds: 10
   readinessProbe:
     httpGet:
       path: /healthz/readiness # Checks DB connectivity pool
       port: 8080
     timeoutSeconds: 2
     periodSeconds: 5
   ```

---

## 6. Referências

* **Certificação Oficial DevOps do Linux Professional Institute (LPI)**: [LPI DevOps Tools Engineer Overview & Objectives](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
* **A Metodologia Twelve-Factor App**: [Especificação Oficial 12-Factor](https://12factor.net/)
* **Cloud Native Computing Foundation (CNCF)**: [CNCF Trail Map & Cloud-Native Definition](https://www.cncf.io/)
* **Documentação do Kubernetes**: [Kubernetes Pod Lifecycle & Probes](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/)
* **Segurança do Docker e Boas Práticas Multi-Stage**: [Docker Architecture & Multi-Stage Builds Guide](https://docs.docker.com/build/building/multi-stage/)
* **Google SRE Book**: [Monitoring Distributed Systems & Cascading Failures](https://sre.google/sre-book/table-of-contents/)