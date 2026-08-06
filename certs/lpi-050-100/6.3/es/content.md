# LPI 050-100: Open Source Essentials — Tema 6.3: Herramientas de Comunicación y Colaboración
## Manual de Referencia de Arquitectura de Producción Avanzada y SRE

---

## 1. Motivación de Producción y Declaración del Problema Arquitectónico

En entornos de producción empresariales, las herramientas de comunicación y colaboración de código abierto forman el **sistema nervioso central de Operaciones y Respuesta a Incidentes**. Mucho más allá del simple chat de equipo o páginas wiki, la ingeniería de plataformas moderna integra estos sistemas directamente en pipelines de CI/CD automatizados, plataformas de observabilidad y motores de remediación automatizada (ChatOps).

### Desafíos de SRE Empresarial y Requisitos Arquitectónicos

```
                                +---------------------------------------+
                                |      Observability & CI/CD Drivers    |
                                | (Prometheus, Alertmanager, GitLab CI) |
                                +-------------------+-------------------+
                                                    |
                                       HTTP Webhooks / JSON Payload
                                                    |
                                                    v
+------------------------+      +-------------------+-------------------+
|  Stateless Web Access  |----->|  Ingress Gateway (Reverse Proxy / TLS) |
| (REST API / Nextcloud) |      +-------------------+-------------------+
+------------------------+                          |
                                       Persistent WebSockets / HTTP/2
                                                    |
                                                    v
                                +-------------------+-------------------+
                                | Collaboration App Cluster (Mattermost)|
                                +---------+-------------------+---------+
                                          |                   |
                     Shared Session State |                   | Object Storage
                                          v                   v
                                +---------+-------+   +-------+---------+
                                | Redis Cluster   |   | S3 / MinIO Store|
                                | (Pub/Sub Sync)  |   | (Blobs / Attach)|
                                +-----------------+   +-----------------+
                                          |
                                          | Relational State & ACID
                                          v
                                +---------+-------------------+
                                | PostgreSQL HA Database Cluster|
                                +-------------------------------+
```

1. **Sincronización de Estado a Escala (WebSockets y Long-Polling):**
   Las plataformas de chat en tiempo real (por ejemplo, Mattermost, Matrix Synapse) mantienen miles de conexiones TCP/WebSocket persistentes, concurrentes y de larga duración. A diferencia de las aplicaciones web stateless, los despliegues multinodo de motores de colaboración en tiempo real requieren una capa pub/sub de baja latencia (por ejemplo, Redis Cluster) para transmitir actualizaciones de estado entre nodos instantáneamente cuando ocurre un evento en cualquier nodo.

2. **Resiliencia ante Tormentas de Incidentes y Throttling:**
   Durante una caída mayor (eventos P0/P1), las herramientas de monitoreo automatizado (Prometheus Alertmanager, Datadog) generan ráfagas masivas de webhooks entrantes hacia los canales de incidentes. Si el stack de colaboración carece de búfer de cola de entrada, controles de backpressure o connection pooling, la propia plataforma sufrirá contención de bloqueos de base de datos, picos de memoria y failovers en cascada precisamente cuando los ingenieros más la necesitan.

3. **Soberanía de Datos, Cumplimiento Operativo y Operación Air-Gapped:**
   Las industrias reguladas (FinTech, Salud, Defensa) requieren un gobierno de datos completo. Las plataformas SaaS propietarias (Slack, Teams, Notion) introducen vendor lock-in, riesgos de cumplimiento externos y dependencia de enrutamiento de internet externo. Las soluciones de código abierto self-hosted permiten cifrado de extremo a extremo (E2EE), almacenamiento de base de datos local, registro de auditoría inmutable y operación completa dentro de VPCs air-gapped o clusters de Kubernetes soberanos.

4. **Arquitectura de Integración (ChatOps e Interoperabilidad de API):**
   Un stack de colaboración robusto actúa como un event bus. Los equipos de SRE automatizan acciones de infraestructura utilizando webhooks bidireccionales, slash commands y frameworks de bots. El backend debe hacer cumplir la integridad criptográfica de los payloads (firmas HMAC), TLS mutuo (mTLS) y un Control de Acceso Basado en Roles (RBAC) de grano fino para prevenir la escalada no autorizada de privilegios a través de interfaces de chat.

---

## 2. Mecanismo Técnico y Comparación de Arquitectura

Las plataformas de colaboración de código abierto abarcan distintos patrones de arquitectura según su enfoque operativo: mensajería síncrona, intercambio asíncrono de conocimiento, sincronización distribuida de archivos y colaboración de código.

### Clasificaciones Arquitectónicas Principales

1. **Plataformas de Mensajería Síncrona y ChatOps:**
   * **Mattermost:** Binario monolítico basado en Go diseñado para escalado horizontal. Utiliza PostgreSQL/MySQL para persistencia relacional, Redis para sincronización de WebSockets multinodo y almacenamiento compatible con S3 para archivos adjuntos. Alta compatibilidad con webhooks y esquemas de API de Slack.
   * **Matrix (Synapse/Dendrite):** Protocolo de comunicación abierto, descentralizado y federado. Los eventos forman un Grafo Acíclico Dirigido (DAG) replicado a través de servidores federados mediante E2EE. Altamente resiliente a fallos de un solo nodo, pero requiere una indexación de base de datos y almacenamiento en caché significativos debido a la sobrecarga de resolución de estado del DAG.
   * **Rocket.Chat:** Aplicación Node.js/TypeScript que aprovecha MongoDB para almacenamiento de documentos y el framework Meteor/WebSockets para la distribución reactiva de datos en tiempo real.

2. **Repositorios de Conocimiento y Documentación Asíncrona:**
   * **BookStack:** Plataforma PHP/Laravel que utiliza MySQL/MariaDB. Emplea una jerarquía visual (Estantes -> Libros -> Capítulos -> Páginas) diseñada para documentación operativa y Bases de Conocimiento (KB) internas.
   * **MediaWiki:** Motor wiki basado en base de datos PHP que impulsa Wikipedia. Altamente extensible con complejas capas de almacenamiento en caché (Varnish, Redis, Memcached) para servir cargas de trabajo de documentación en producción intensivas en lectura.
   * **DokuWiki:** Wiki ligero y sin base de datos que almacena contenido en archivos de texto plano. Utiliza árboles de directorios y bloqueos del sistema de archivos, ideal para documentación de infraestructura simple sin la sobrecarga de una base de datos.

3. **Ecosistemas de Control de Revisiones y Colaboración de Código:**
   * **GitLab CE:** Suite empresarial que combina Ruby on Rails, microservicios en Go (Gitaly para RPCs de Git), PostgreSQL, Redis y Workhorse. Altamente escalable, proporciona integración completa de pipelines de CI/CD, revisión de código y seguimiento de issues.
   * **Gitea / Forgejo:** Aplicación Go ultraligera con una utilización mínima de recursos. Funciona sobre SQLite, MySQL o PostgreSQL, adecuada para despliegues en el edge y colaboración de código ligera.

4. **Suites de Sincronización de Archivos y Productividad:**
   * **Nextcloud:** Plataforma en la nube empresarial basada en PHP que implementa WebDAV, CalDAV y CardDAV. Utiliza bloqueo transaccional de archivos mediante Redis y bases de datos relacionales para gestionar la indexación de archivos, la sincronización de escritorio y el montaje de almacenamiento externo.

### Matriz Exhaustiva de Trade-Offs de SRE

| Sistema | Modelo de Arquitectura | Backend de Persistencia de Estado | Mecanismo de Transporte en Tiempo Real | Vector de Escalado Horizontal | Perfil de Latencia | Complejidad Operativa (1-10) | Caso de Uso Principal de SRE |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Mattermost** | Servicio monolítico en Go + Micro-plugins stateful | PostgreSQL / MySQL + S3 | WebSockets + Long-Polling | App: Horiz. Stateless DB: Primaria-Réplica Caché: Redis | Baja (< 50ms) | 4 / 10 | ChatOps empresarial, alertas de incidentes automatizadas |
| **Matrix (Synapse)**| Malla de servidores federados (Python/Go) | PostgreSQL (Estado DAG federado) | API HTTP Matrix Client-Server / WS | Malla de federación Matrix + Workers de Matrix | Baja-Media (50-200ms) | 8 / 10 | Infraestructura E2EE federada air-gapped |
| **GitLab CE** | Microservicios distribuidos (Rails + Go/Gitaly) | PostgreSQL + Redis + S3 + Git RPC | WebSockets (ActionCable) + REST/gRPC | Nodos Gitaly + Runners stateless de App | Media (100-300ms) | 9 / 10 | SCM empresarial, motor de CI/CD, seguimiento de issues |
| **BookStack** | Monolito MVC (PHP/Laravel) | MariaDB / PostgreSQL | Sincronización HTTP (REST API) | Web Stateless + Cluster de BD | Baja (Lectura en caché) | 3 / 10 | Runbooks operativos estandarizados y KBs |
| **Nextcloud** | Monolito WebDAV / Microservicios OCIS | PostgreSQL / MariaDB + S3 / NFS Local | WebDAV / WebSockets (Notify Push) | App PHP horizontal + Gestor de bloqueos Redis | Media (Dependiente de E/S de WebDAV) | 6 / 10 | Almacenamiento y sincronización empresarial soberana |

---

## 3. Infraestructura de Nivel de Producción y Manifiestos de Kubernetes

El siguiente manifiesto de Kubernetes listo para producción define un despliegue empresarial de Mattermost de Alta Disponibilidad (HA). Incluye despliegues de nodos de aplicación, almacenamiento en caché de estado de sesión mediante Redis, conectividad de base de datos a PostgreSQL, enrutamiento de Ingress con configuraciones explícitas de actualización del protocolo WebSocket, un PodDisruptionBudget y NetworkPolicies estrictas.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: collaboration-system
  labels:
    environment: production
    tier: collaboration
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: mattermost-config
  namespace: collaboration-system
data:
  config.json: |
    {
      "ServiceSettings": {
        "SiteURL": "https://chat.production.internal",
        "ListenAddress": ":8065",
        "WebsocketPort": 8065,
        "EnableDeveloper": false,
        "EnableIncomingWebhooks": true,
        "EnableOutgoingWebhooks": true,
        "EnablePostMetadata": true,
        "GoroutineEventLoopSize": 2048,
        "ReadTimeout": 300,
        "WriteTimeout": 300,
        "IdleTimeout": 60
      },
      "SqlSettings": {
        "DriverName": "postgres",
        "DataSourceReplicas": [
          "postgres://mm_user:SecretDBPass123@postgres-read.database.svc.cluster.local:5432/mattermost?sslmode=require&connect_timeout=10"
        ],
        "MaxIdleConns": 20,
        "MaxOpenConns": 300,
        "ConnMaxLifetimeMilliseconds": 3600000,
        "Trace": false
      },
      "ClusterSettings": {
        "Enable": true,
        "ClusterName": "prod-cluster",
        "OverrideHostname": "",
        "UseIpAddress": false,
        "EnableExperimentalGossipEncryption": true,
        "GossipPort": 8074,
        "StreamingPort": 8075
      },
      "RedisSettings": {
        "Enable": true,
        "Url": "redis://redis-sentinel.collaboration-system.svc.cluster.local:26379",
        "MaxIdle": 50,
        "MaxActive": 500,
        "IdleTimeoutInSeconds": 60
      },
      "FileSettings": {
        "DriverName": "amazons3",
        "AmazonS3AccessKeyId": "AKIAIOSFODNN7EXAMPLE",
        "AmazonS3Bucket": "enterprise-chat-attachments",
        "AmazonS3Region": "us-east-1",
        "AmazonS3Endpoint": "s3.us-east-1.amazonaws.com",
        "AmazonS3SSL": true
      }
    }
---
apiVersion: v1
kind: Secret
metadata:
  name: mattermost-secrets
  namespace: collaboration-system
type: Opaque
stringData:
  MM_SQLSETTINGS_DATASOURCE: "postgres://mm_user:SecretDBPass123@postgres-primary.database.svc.cluster.local:5432/mattermost?sslmode=require&connect_timeout=10"
  MM_REDISSETTINGS_PASSWORD: "ProductionRedisPasswordStrong987!"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mattermost-app
  namespace: collaboration-system
  labels:
    app.kubernetes.io/name: mattermost
    app.kubernetes.io/component: app-server
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: mattermost
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app.kubernetes.io/name: mattermost
        app.kubernetes.io/component: app-server
    spec:
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
                        - mattermost
                topologyKey: "kubernetes.io/hostname"
      containers:
        - name: mattermost-node
          image: mattermost/mattermost-enterprise-edition:9.5.1
          imagePullPolicy: IfNotPresent
          ports:
            - name: http-ws
              containerPort: 8065
              protocol: TCP
            - name: gossip
              containerPort: 8074
              protocol: TCP
            - name: streaming
              containerPort: 8075
              protocol: TCP
          env:
            - name: MM_SQLSETTINGS_DATASOURCE
              valueFrom:
                secretKeyRef:
                  name: mattermost-secrets
                  key: MM_SQLSETTINGS_DATASOURCE
            - name: MM_REDISSETTINGS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mattermost-secrets
                  key: MM_REDISSETTINGS_PASSWORD
          volumeMounts:
            - name: config-volume
              mountPath: /mattermost/config/config.json
              subPath: config.json
          resources:
            requests:
              cpu: "1000m"
              memory: "2Gi"
            limits:
              cpu: "4000m"
              memory: "8Gi"
          readinessProbe:
            httpGet:
              path: /api/v4/system/ping
              port: 8065
            initialDelaySeconds: 15
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /api/v4/system/ping
              port: 8065
            initialDelaySeconds: 30
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 3
      volumes:
        - name: config-volume
          configMap:
            name: mattermost-config
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: mattermost-pdb
  namespace: collaboration-system
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: mattermost
---
apiVersion: v1
kind: Service
metadata:
  name: mattermost-service
  namespace: collaboration-system
  labels:
    app.kubernetes.io/name: mattermost
spec:
  type: ClusterIP
  ports:
    - name: http-ws
      port: 8065
      targetPort: 8065
      protocol: TCP
  selector:
    app.kubernetes.io/name: mattermost
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: mattermost-ingress
  namespace: collaboration-system
  annotations:
    kubernetes.io/ingress.class: "nginx"
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "300"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "300"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "300"
    nginx.ingress.kubernetes.io/proxy-body-size: "100M"
    nginx.ingress.kubernetes.io/websocket-services: "mattermost-service"
    nginx.ingress.kubernetes.io/configuration-snippet: |
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection "upgrade";
      proxy_set_header X-Forwarded-Ssl on;
spec:
  tls:
    - hosts:
        - chat.production.internal
      secretName: chat-tls-certificate
  rules:
    - host: chat.production.internal
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: mattermost-service
                port:
                  number: 8065
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: mattermost-network-policy
  namespace: collaboration-system
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: mattermost
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # Allow traffic from NGINX Ingress Controller
    - from:
        - namespaceSelector:
            matchLabels:
              network.ingress: "true"
      ports:
        - protocol: TCP
          port: 8065
    # Allow gossip/mesh traffic between Mattermost pods in the same namespace
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: mattermost
      ports:
        - protocol: TCP
          port: 8074
        - protocol: TCP
          port: 8075
  egress:
    # Allow connection to PostgreSQL database cluster
    - to:
        - namespaceSelector:
            matchLabels:
              name: database
      ports:
        - protocol: TCP
          port: 5432
    # Allow connection to Redis Caching cluster
    - to:
        - podSelector:
            matchLabels:
              app: redis
      ports:
        - protocol: TCP
          port: 26379
        - protocol: TCP
          port: 6379
    # Allow CoreDNS lookups
    - to:
        - namespaceSelector: {}
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
```

---

## 4. Operaciones CLI y Flujos de Ejecución

Esta sección contiene comandos administrativos del mundo real y patrones de ejecución de API REST HTTP utilizados para gestionar la infraestructura de colaboración empresarial, administrar Webhooks y verificar el estado del sistema.

### 4.1 Administración CLI con `mmctl`

La herramienta de CLI `mmctl` permite a los operadores interactuar con servidores de Mattermost mediante APIs REST.

```bash
$ mmctl auth login https://chat.production.internal --name prod-cluster --username sre-admin --password 'SuperSecureAdminPass2026!'
Credentials stored for server https://chat.production.internal

$ mmctl system status
[✔] Server Version: 9.5.1
[✔] Database Status: OK (Connections Active: 42, Max: 300)
[✔] Redis Cluster Status: OK (Ping response: PONG)
[✔] License Status: Enterprise Edition (Valid until: 2027-12-31)

$ mmctl team list
+------------------+------------------+------------------+
|        ID        |       Name       |   Display Name   |
+------------------+------------------+------------------+
| 9zk4j18p7fb3...  | incident-ops     | Incident Ops     |
| 3bm2n89a1cc4...  | platform-eng     | Platform Eng     |
+------------------+------------------+------------------+

$ mmctl channel create --team incident-ops --name p0-war-room --display-name "P0 Emergency War Room" --header "Active Outage Diagnostics & ChatOps Channel"
Successfully created channel 'p0-war-room' (ID: q71m5x98p3y1z2a4b5c6d7e8f9)
```

### 4.2 Gestión de Webhooks y Activación Diagnóstica de Webhooks mediante `curl`

Los motores de ChatOps dependen de los webhooks entrantes. Los siguientes comandos generan un webhook entrante y ejecutan el envío de un payload autenticado con formato JSON estructural.

```bash
$ mmctl webhook create-incoming \
  --channel incident-ops:p0-war-room \
  --user sre-bot \
  --display-name "Alertmanager Ingestion Bot" \
  --description "Receives PAGER notifications from Alertmanager Cluster"

URL: https://chat.production.internal/hooks/8f9a2b3c4d5e6f7a8b9c0d1e2f
Id: 8f9a2b3c4d5e6f7a8b9c0d1e2f
Token: tok_9876543210fedcba
Channel Id: q71m5x98p3y1z2a4b5c6d7e8f9
User Id: u1v2w3x4y5z6a7b8c9d0e1f2
Create At: 1770415791000
```

Ejecutando un HTTP POST de prueba contra el endpoint de la API del Webhook entrante:

```bash
$ curl -i -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "channel": "p0-war-room",
    "username": "Prometheus-Alertmanager",
    "icon_url": "https://prometheus.io/assets/prometheus_logo.png",
    "attachments": [
      {
        "fallback": "[FIRING:1] HighDatabaseLatency (postgres-primary database/production critical)",
        "color": "#FF0000",
        "title": "🚨 [CRITICAL] High Database Query Latency Exceeded 500ms",
        "title_link": "https://grafana.production.internal/d/pg-perf?orgId=1",
        "fields": [
          {
            "short": true,
            "title": "Severity",
            "value": "P1 - Critical"
          },
          {
            "short": true,
            "title": "Service Impacted",
            "value": "PostgreSQL Primary Node 01"
          },
          {
            "short": false,
            "title": "Alert Details",
            "value": "p99 query execution latency currently at 1240ms. Transaction buffer pool utilization > 94%."
          }
        ],
        "footer": "Kubernetes Alertmanager | Cluster: prod-us-east-1",
        "ts": 1770415820
      }
    ]
  }' \
  https://chat.production.internal/hooks/8f9a2b3c4d5e6f7a8b9c0d1e2f
```

**Salida esperada del servidor:**

```http
HTTP/2 200 OK
content-type: text/html; charset=utf-8
x-request-id: r8a7f6e5d4c3b2a1
x-version-id: 9.5.1.9.5.1.84759392.plain
date: Thu, 06 Aug 2026 23:30:20 GMT
content-length: 3

ok
```

### 4.3 Inspección de Bajo Nivel del Backend mediante `psql` y `redis-cli`

Verificación de las claves de suscripción en tiempo real del backend y los estados de conexión de la base de datos durante eventos de alta carga:

```bash
$ kubectl exec -it -n collaboration-system deployment/mattermost-app -- redis-cli -h redis-sentinel -a 'ProductionRedisPasswordStrong987!' PUBSUB CHANNELS
1) "websocket_hub:events"
2) "cluster_events"
3) "user_status_broadcast"

$ kubectl exec -it -n database statefulset/postgres-primary -- psql -U mm_user -d mattermost -c "SELECT count(*), state, query FROM pg_stat_activity WHERE datname='mattermost' GROUP BY state, query;"
 count | state  |                                   query                                    
-------+--------+----------------------------------------------------------------------------
    38 | idle   | 
     4 | active | SELECT * FROM Posts WHERE ChannelId = 'q71m5x98p3y1z2a4b5c6d7e8f9' ORDER BY CreateAt DESC LIMIT 60;
(2 rows)
```

---

## 5. Guía de Verificación, Diagnósticos y Solución de Problemas

Las plataformas de comunicación de alta disponibilidad sufren distintos modos de fallo operativo cuando se someten a incidentes de producción. El siguiente runbook de diagnóstico proporciona procedimientos de mitigación estructurados.

### Matriz de Mitigación de Fallos de SRE

```
                      +----------------------------------+
                      |   Ingress HTTP 502/504 Detected  |
                      +----------------+-----------------+
                                       |
                                       v
                     /-----------------------------------\
                    < Is WebSocket Connection Failing?    >
                     \-----------------------------------/
                               /               \
                       YES    /                 \ NO
                             v                   v
            +------------------------+   +------------------------+
            | Check Ingress Header   |   | Inspect App Readiness  |
            | Settings (Upgrade/Conn)|   | Probes & DB Pool Saturation|
            +------------------------+   +------------------------+
                         |                           |
                         v                           v
            +------------------------+   +------------------------+
            | Verify NGINX Proxy     |   | Query pg_stat_activity |
            | Read/Write Timeouts    |   | Check Redis PubSub     |
            +------------------------+   +------------------------+
```

#### Problema 1: Caídas de Conexión WebSocket y Tormentas de Reconexión de Clientes (`HTTP 504 / WS Code 1006`)
* **Síntoma:** Los clientes se desconectan repetidamente, mostrando banners de "Conectando...". Los logs de Ingress muestran `504 Gateway Time-out` en `/api/v4/websocket`.
* **Causa Raíz:** Los timeouts de lectura/escritura del reverse proxy están configurados con los valores predeterminados estándar de HTTP (por ejemplo, 60 segundos). El proxy corta los WebSockets inactivos cuando las señales de heartbeat caen fuera de la ventana de timeout.
* **Comando de Diagnóstico:**
  ```bash
  $ kubectl logs -n collaboration-system -l app.kubernetes.io/name=mattermost --tail=100 | grep -E "websocket|timeout|ping"
  ```
* **Remediación:** Asegúrese de que las anotaciones de Ingress anulen explícitamente los timeouts del proxy a al menos 300s (`nginx.ingress.kubernetes.io/proxy-read-timeout: "300"`) y verifique que los encabezados HTTP `Upgrade` y `Connection` se inyecten correctamente en la configuración de NGINX.

#### Problema 2: Agotamiento del Connection Pool de PostgreSQL durante Ráfagas de Alertas
* **Síntoma:** Los webhooks entrantes fallan con `HTTP 500 Internal Server Error`. Los logs de Mattermost muestran `sql: database is closed` o `pq: sorry, too many clients already`.
* **Causa Raíz:** Un pico repentino en los webhooks entrantes combinado con altas acciones de lectura concurrentes por parte de usuarios satura `MaxOpenConns`.
* **Comando de Diagnóstico:**
  ```bash
  $ kubectl exec -it -n database statefulset/postgres-primary -- psql -U mm_user -d mattermost -c "SELECT max_val, current_val FROM (SELECT setting::int AS max_val FROM pg_settings WHERE name='max_connections') a, (SELECT count(*) AS current_val FROM pg_stat_activity) b;"
  ```
* **Remediación:** 
  1. Desplegar `PgBouncer` para multiplexar las conexiones de los clientes.
  2. Incrementar `MaxOpenConns` en `config.json` manteniendo umbrales de memoria seguros en PostgreSQL.
  3. Configurar el escalado de lectura por réplicas (`SqlSettings.DataSourceReplicas`) para liberar a la BD primaria de consultas de lectura.

#### Problema 3: Webhook Entrante Descartado por Discordancia de HMAC o Rate Limiting
* **Síntoma:** Herramientas de CI/CD de terceros (por ejemplo, webhooks de GitLab, GitHub Actions) reportan `HTTP 403 Forbidden` o `HTTP 429 Too Many Requests`.
* **Comando de Diagnóstico:**
  ```bash
  $ kubectl logs -n collaboration-system -l app.kubernetes.io/name=mattermost | grep -i "webhook rate limit"
  ```
* **Remediación:** Ajuste el rate limiter de la aplicación en `config.json`:
  ```json
  "RateLimitSettings": {
    "Enable": true,
    "PerSec": 100,
    "MaxBurst": 200,
    "MemoryStoreSize": 10000,
    "VaryByRemoteAddr": false,
    "VaryByHeader": "X-Forwarded-For"
  }
  ```

### Reglas de Alertas Clave de Prometheus para Monitoreo de SRE

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: collaboration-sre-alerts
  namespace: collaboration-system
spec:
  groups:
    - name: mattermost.rules
      rules:
        - alert: MattermostWebSocketDropSpike
          expr: rate(mattermost_websocket_broadcast_buffer_users_dropped_total[2m]) > 10
          for: 1m
          labels:
            severity: critical
          annotations:
            summary: "High rate of WebSocket message drops detected"
            description: "Mattermost node {{ $labels.pod }} is dropping WebSocket events due to buffer saturation."

        - alert: MattermostDatabaseConnPoolExhausted
          expr: (mattermost_db_open_connections / mattermost_db_max_open_connections) > 0.85
          for: 3m
          labels:
            severity: warning
          annotations:
            summary: "Database connection pool utilization > 85%"
            description: "PostgreSQL pool on {{ $labels.pod }} is near exhaustion. Current utilization: {{ $value | humanizePercentage }}."
```

---

## 6. Referencias y Documentación Oficial

* **Sitio Oficial de Linux Professional Institute (LPI):**
  * Resumen de LPI Open Source Essentials 050-100: [https://www.lpi.org/our-certifications/open-source-essentials-overview/](https://www.lpi.org/our-certifications/open-source-essentials-overview/)
  * Recursos de Aprendizaje de LPI: [https://learning.lpi.org/](https://learning.lpi.org/)

* **Guías de Arquitectura Empresarial y Despliegue de Mattermost:**
  * Resumen de Despliegue de Mattermost: [https://docs.mattermost.com/deploy/deployment-overview.html](https://docs.mattermost.com/deploy/deployment-overview.html)
  * Configuración de Alta Disponibilidad de Mattermost: [https://docs.mattermost.com/scale/high-availability-cluster.html](https://docs.mattermost.com/scale/high-availability-cluster.html)
  * Referencia de API REST v4 de Mattermost: [https://api.mattermost.com/](https://api.mattermost.com/)

* **Especificación del Protocolo Matrix y Arquitectura Synapse:**
  * Especificación de Matrix: [https://spec.matrix.org/latest/](https://spec.matrix.org/latest/)
  * Guía del Administrador de Sistemas de Synapse: [https://matrix-org.github.io/synapse/latest/](https://matrix-org.github.io/synapse/latest/)

* **Referencia de Escalabilidad y Arquitectura de GitLab:**
  * Resumen de Arquitectura de GitLab: [https://docs.gitlab.com/ee/development/architecture.html](https://docs.gitlab.com/ee/development/architecture.html)
  * Arquitectura de Gitaly: [https://docs.gitlab.com/ee/administration/gitaly/](https://docs.gitlab.com/ee/administration/gitaly/)

* **Arquitectura Empresarial de Nextcloud:**
  * Manual de Administración del Servidor Nextcloud: [https://docs.nextcloud.com/server/latest/admin_manual/](https://docs.nextcloud.com/server/latest/admin_manual/)