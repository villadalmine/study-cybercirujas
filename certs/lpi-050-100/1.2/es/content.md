# LPI Open Source Essentials (Examen 050-100) — Tema 1.2: Arquitectura de Software

## 1. Problema Arquitectónico de Producción y Motivación

La arquitectura de software moderna dicta cómo la lógica computacional, la persistencia de datos y las interfaces de comunicación se organizan, despliegan y escalan. Para los SREs y Platform Architects, seleccionar un patrón arquitectónico no es simplemente una elección de diseño de software: es una decisión operacional fundamental que define la confiabilidad del sistema, la complejidad operacional, la topología de red, los modos de falla y las características de recuperación.

```
+---------------------------------------------------------------------------------------------------+
|                                 EVOLUTION OF SOFTWARE ARCHITECTURE                                |
+---------------------------------------------------------------------------------------------------+
|                                                                                                   |
|  [ 1. MONOLITHIC ]           [ 2. CLIENT-SERVER / TIERED ]        [ 3. MICROSERVICES / EVENT ]   |
|  +-----------------------+   +---------------+  +---------------+   +-------+  +-------+  +-----+ |
|  | UI + Logic + DB Access|   | Thin/Fat Client|  | App Tier      |   | Svc A |  | Svc B |  |Svc C| |
|  | Single Process/Binary |==>| (Web Browser) |==>| (Business Lgc)|==>| (Go)  |  | (Rust)|  |(Node| |
|  +-----------------------+   +---------------+  +---------------+   +---+---+  +---+---+  +--+--+ |
|            |                         |                  |               |          |         |    |
|       (IPC/Shared Mem)          (HTTP / REST)     (SQL Connection)  (gRPC / HTTP2 / Event Bus)  |
|            |                         |                  |               |          |         |    |
|  +-----------------------+   +---------------+  +---------------+   +---+----------+---------+--+ |
|  | Single RDBMS / Disk   |   | Web Server    |  | RDBMS Pool    |   | Distributed Storage /   | |
|  +-----------------------+   +---------------+  +---------------+   | Kafka Event Log / Redis | |
|                                                                     +-------------------------+ |
+---------------------------------------------------------------------------------------------------+
```

### Modelos Arquitectónicos Principales y Mecánica Interna

#### Arquitectura Monolítica
* **Mecánica**: Todos los dominios funcionales (renderizado de UI, lógica de negocio, mecanismos de acceso a datos) se ejecutan dentro de un único proceso o espacio de memoria. La comunicación entre módulos ocurre a través de llamadas a funciones en proceso (In-Process Function Calls) de baja latencia y asignación de memoria compartida (Shared Memory).
* **Realidad en Producción**: Simplifica el despliegue inicial, las pruebas locales y la consistencia de datos (transacciones ACID dentro de una sola base de datos relacional). Sin embargo, introduce un único radio de impacto (blast radius) unificado: una fuga de memoria (memory leak), un panic no controlado o un consumo excesivo de CPU en un módulo (por ejemplo, generación de PDF) destruye la instancia completa de la aplicación. El escalado requiere escalar todo el proceso monolíticamente, consumiendo recursos de manera ineficiente.

#### Arquitectura Cliente-Servidor (Clientes Thin vs. Thick/Fat)
* **Mecánica**: Divide la carga de trabajo entre proveedores de servicios (servidores) y solicitantes de servicios (clientes) sobre protocolos de red (TCP/IP, HTTP, TLS).
  * **Thin Client**: El cliente (por ejemplo, un navegador web moderno estándar, una CLI liviana) ejecuta una lógica mínima, actuando principalmente como una capa de presentación. La lógica de negocio, la validación de entrada, la gestión de estado y el acceso a datos se aplican completamente del lado del servidor (server-side).
  * **Fat / Thick Client**: El cliente (por ejemplo, una aplicación de escritorio nativa, una app móvil pesada, una app Electron) ejecuta una cantidad sustancial de lógica de negocio, almacenamiento en caché local y procesamiento de datos localmente, enviando solo mutaciones de estado crudas o solicitudes de sincronización a los servidores backend a través de APIs.
* **Realidad en Producción**: Los Thin Clients minimizan los requerimientos de hardware del lado del cliente y garantizan el despliegue inmediato de soluciones a errores (las actualizaciones del servidor se reflejan instantáneamente para todos los usuarios). Los Fat Clients reducen la carga de cómputo de los servidores backend y pueden operar sin conexión (offline), pero introducen un severo desvío de estado (state drift) en el cliente, sobrecosto de mantenimiento de compatibilidad hacia atrás en las APIs y riesgos de seguridad (ingeniería inversa de código).

#### Arquitectura Multi-Tier (N-Tier / 3-Tier)
* **Mecánica**: Segrega explícitamente las responsabilidades del software a través de capas lógicas y físicas distintas:
  1. **Presentation Tier**: Sirve activos HTTP, plantillas de UI y recursos estáticos (servidores web como NGINX, Apache, CDN).
  2. **Application Tier**: Ejecuta la lógica central del dominio de la aplicación y las reglas de negocio (Node.js, Java Spring, Python Gunicorn).
  3. **Database Tier**: Gestiona el almacenamiento persistente, el aislamiento del registro de transacciones (transaction log) y el procesamiento de consultas (PostgreSQL, MySQL).
* **Realidad en Producción**: Permite el escalado horizontal enfocado (por ejemplo, escalar instancias stateless de la capa App Tier según la utilización de CPU sin modificar la huella de la DB) y un aislamiento estricto de firewall (Network Security Groups/NetworkPolicies garantizando que el Database Tier solo sea accesible por el Application Tier, nunca directamente desde Internet).

#### Microservicios y Arquitectura Orientada a Servicios (SOA)
* **Mecánica**: Descompone la funcionalidad de la aplicación en servicios autónomos, desacoplados (loosely-coupled) y desplegables de manera independiente. Cada microservicio es dueño de su modelo de datos de dominio (patrón Database-per-service) y se comunica a través de protocolos de red estandarizados (gRPC, REST, NATS).
* **Realidad en Producción**: Elimina puntos únicos de falla (single points of failure) a lo largo de los dominios de negocio y permite pipelines de publicación independientes entre equipos de ingeniería. Sin embargo, convierte las llamadas de memoria local en saltos de red (network hops), exponiendo la arquitectura a las **Falacias de la Computación Distribuida de Deutsch**: introduciendo jitter en la latencia de red, pérdida de paquetes (packet drops), sobrecosto de serialización, desafíos de consenso distribuido (teoremas CAP/PACELC) y complejos escenarios de fallas en cascada.

#### Arquitectura Peer-to-Peer (P2P)
* **Mecánica**: Modelo de red descentralizado donde los nodos (peers) actúan simultáneamente como clientes y servidores (servents). Los peers comparten cómputo, almacenamiento o ancho de banda directamente sin depender de una autoridad o broker centralizado (por ejemplo, BitTorrent, IPFS, redes de nodos blockchain).
* **Realidad en Producción**: Altamente resiliente contra interrupciones dirigidas a un solo nodo y ataques DDoS, ofreciendo un escalado de ancho de banda distribuido infinito. Extremadamente desafiante para la consistencia transaccional en tiempo real, consultas de baja latencia y control estricto de acceso a la seguridad.

#### Arquitectura Orientada a Eventos (EDA) y Serverless (FaaS)
* **Mecánica**: Los cambios de estado del sistema emiten mensajes inmutables (Events) a un broker de mensajes asincrónico (por ejemplo, Apache Kafka, NATS, RabbitMQ). Los consumidores se suscriben a los topics y procesan los eventos de forma independiente. Serverless (Function-as-a-Service) combina EDA con entornos de ejecución efímeros, levantando Pods de cómputo estrictamente bajo demanda en respuesta a disparadores (triggers) entrantes.
* **Realidad en Producción**: Desacopla el rendimiento del productor de la latencia del consumidor. Los productores emiten un evento en $<5\text{ms}$ y retornan inmediatamente, evitando el desabastecimiento de hilos (thread starvation) del cliente. Introduce demandas operacionales de colas de mensajes muertos (Dead-Letter Queues - DLQ), patrones de procesamiento idempotentes (manejo de entrega at-least-once) y la gestión de latencias de inicio en frío (cold-start) en FaaS.

---

## 2. Comparaciones Técnicas y Matrices de Balance (Trade-off Matrices)

### Tabla 1: Matriz Completa de Balances (Trade-offs) en Arquitectura de Software

| Patrón Arquitectónico | Latencia y Sobrecosto de Red | Complejidad de Estado y Datos | Escalabilidad y Control del Blast Radius | Sobrecosto Operacional y de Observabilidad | Caso de Uso Principal en Producción |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Monolítica** | **El más bajo** (Ejecución en memoria, IPC, sin serialización RPC) | **La más baja** (DB ACID única, consistencia inmediata fuerte) | **Deficiente** (Escala todo el monolito; 1 caída derriba todos los dominios) | **Bajo** (Un solo binario/flujo de logs; rastreo simple) | Productos en etapas tempranas, motores de dominio estrechamente acoplados, estrategias de monolito primero |
| **Cliente-Servidor (Thin)** | **De baja a moderada** (1 salto de red Cliente $\rightarrow$ Servidor Web/App) | **Centralizado** (El servidor mantiene la fuente de la verdad; cliente stateless) | **Alta (Del lado del servidor)** (Escala horizontalmente servidores de aplicaciones stateless detrás de un LB) | **De bajo a moderado** (Observabilidad estándar de Ingress/Egress web) | Portales web SaaS empresariales, apps web cloud-native, consolas de administración centralizadas |
| **Cliente-Servidor (Fat)** | **Baja (Del lado del cliente)** / **Alta (Sincronización)** (Procesamiento local pesado; sincronización periódica en lote por API) | **Compleja** (Sincronización de caché local, resolución de conflictos, almacenamiento offline) | **Alta (Cómputo)** (Descarga el procesamiento al hardware del usuario; el cuello de botella es la sincronización de la DB) | **Alto** (Fragmentación de versiones del cliente, requerimientos de compatibilidad hacia atrás) | Aplicaciones móviles offline-first, herramientas de procesamiento de audio/video en tiempo real, IDEs |
| **Multi-Tier (3-Tier)** | **Moderada** (Cliente $\rightarrow$ Web $\rightarrow$ App $\rightarrow$ DB; 2-3 saltos de red internos) | **Estructurada** (Capa de datos relacionales con capas de connection pooling) | **De moderada a alta** (Escalado independiente de las capas Web/App; la DB sigue siendo el cuello de botella) | **Moderado** (Requiere rastreo APM a través de los límites de Tier y firewalls de red) | Sistemas web empresariales tradicionales, aplicaciones de comercio electrónico, portales bancarios |
| **Microservicios** | **Alta** (Múltiples saltos de red RPC/gRPC intra-servicio, costo de TLS handshake) | **Muy alta** (Datos distribuidos, consistencia eventual, requerimiento de patrón Saga) | **Máxima** (Autoscaling horizontal de Pods fino por servicio; blast radius contenido) | **Extremo** (Requiere Service Mesh, Distributed Tracing [OpenTelemetry], Prometheus/Grafana) | Plataformas cloud multiequipo a gran escala, ecosistemas de dominio complejos (por ejemplo, Uber, Netflix) |
| **Event-Driven (EDA)** | **Asincrónico/Desacoplado** (Baja latencia de publicación; latencia eventual de procesamiento del consumidor) | **Alta** (Consistencia eventual, persistencia de registro de flujo de eventos, garantías de ordenamiento) | **Máxima** (Los productores operan a velocidad máxima independientemente de la capacidad del consumidor aguas abajo) | **Alto** (Requiere gestión de clústeres Kafka/NATS, registros de esquemas, monitoreo de retraso del consumidor [consumer lag]) | Pipelines de transacciones financieras, transmisión de analítica en tiempo real, webhooks, notificaciones asincrónicas |
| **Serverless (FaaS)** | **Variable** (Penalizaciones de cold start $+50\text{ms}$ a $2\text{s}$; latencia de ejecución mínima) | **Externalizada** (Debe usar proxies externos de conexión redis/DB como PgBouncer) | **Elástica / Auto** (Escalado instantáneo a 0 y a 1,000s de invocaciones concurrentes) | **Moderado** (Sin gestión de SO; alta dependencia en herramientas de observabilidad de la plataforma) | Manejadores de eventos, transformaciones de archivos ETL en lote, receptores de webhooks, tareas de baja frecuencia |
| **Peer-to-Peer (P2P)** | **Variable** (Dependiente de la topología de peers, recorrido NAT [NAT traversal], latencia de red superpuesta [overlay network]) | **Extrema** (Tablas de Hash Distribuidas [DHT], CRDTs, protocolos de consenso [Raft, Paxos]) | **Alta (Ancho de banda)** (Escala linealmente con los nodos participantes) | **Alto** (Rastreo del estado de los peers, depuración de fallas de recorrido NAT, monitoreo descentralizado) | Distribución de contenido distribuido (BitTorrent), libros contables descentralizados (decentralized ledgers), sistemas de archivos distribuidos |

### Tabla 2: Comparación de Protocolos de Comunicación e IPC

| Protocolo / Paradigma | Transporte Subyacente | Modelo de Comunicación | Formato de Carga Útil (Payload) | Multiplexación / Streaming | Herramientas de Diagnóstico SRE |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **REST API** | HTTP/1.1 o HTTP/2 | Solicitud/Respuesta Sincrónica | JSON, XML, Texto | No (bloqueo head-of-line de conexión HTTP/1.1); Sí (HTTP/2) | `curl`, `httpie`, `Postman`, `tcpdump` |
| **gRPC** | HTTP/2 | Sync / Async / Streaming Bidireccional | Protocol Buffers (Binario) | **Multiplexación completa** sobre una sola conexión TCP | `grpcurl`, `ghz`, `wireshark`, `buf` |
| **WebSockets** | TCP (Actualizado desde HTTP/1.1) | Bidireccional Full-Duplex | Binario, Trama de Texto | Un solo flujo TCP persistente | `wscat`, browser dev tools, `tcpdump` |
| **AMQP / Kafka** | TCP (Protocolo binario personalizado) | Publicación / Suscripción Asincrónica | Bytes en crudo (Avro, JSON, Protobuf) | Multiplexación basada en Topic/Partition | `kafka-console-consumer`, `kcat`, `nats` |

---

## 3. Infraestructura de Producción y Manifiestos de Despliegue

A continuación se presenta un manifiesto de Kubernetes completo y sintácticamente válido que representa un stack arquitectónico moderno cloud-native de 3-tier / microservicios. Despliega:
1. Un **Ingress Edge Controller** (capa de enrutamiento Gateway).
2. Una **Capa de Microservicios de API Stateless** (con HPA, PodDisruptionBudget, contextos de seguridad y liveness/readiness probes).
3. Una **Capa de Caché y Mensajería Stateful** (StatefulSet con PersistentVolumeClaims para persistencia backend).

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: production-architecture
  labels:
    environment: production
    architecture: microservices-3tier
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: api-service-config
  namespace: production-architecture
data:
  APP_ENV: "production"
  LOG_LEVEL: "info"
  DB_HOST: "stateful-db-0.stateful-db-headless.production-architecture.svc.cluster.local"
  DB_PORT: "5432"
  CACHE_HOST: "redis-cluster.production-architecture.svc.cluster.local"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-microservice
  namespace: production-architecture
  labels:
    app.kubernetes.io/name: api-microservice
    app.kubernetes.io/tier: application
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: api-microservice
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app.kubernetes.io/name: api-microservice
        app.kubernetes.io/tier: application
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
      containers:
        - name: api-engine
          image: registry.k8s.io/e2e-test-images/agnhost:2.45
          args:
            - netexec
            - --http-port=8080
          ports:
            - containerPort: 8080
              name: http-api
          envFrom:
            - configMapRef:
                name: api-service-config
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              cpu: 1000m
              memory: 512Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 2
            successThreshold: 1
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 15
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
---
apiVersion: v1
kind: Service
metadata:
  name: api-microservice-svc
  namespace: production-architecture
  labels:
    app.kubernetes.io/name: api-microservice
spec:
  type: ClusterIP
  ports:
    - port: 80
      targetPort: 8080
      protocol: TCP
      name: http
  selector:
    app.kubernetes.io/name: api-microservice
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: api-microservice-hpa
  namespace: production-architecture
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api-microservice
  minReplicas: 3
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: api-microservice-pdb
  namespace: production-architecture
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: api-microservice
---
apiVersion: v1
kind: Service
metadata:
  name: stateful-db-headless
  namespace: production-architecture
spec:
  clusterIP: None
  selector:
    app.kubernetes.io/name: stateful-db
  ports:
    - port: 5432
      name: postgres
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: stateful-db
  namespace: production-architecture
  labels:
    app.kubernetes.io/name: stateful-db
    app.kubernetes.io/tier: database
spec:
  serviceName: "stateful-db-headless"
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: stateful-db
  template:
    metadata:
      labels:
        app.kubernetes.io/name: stateful-db
        app.kubernetes.io/tier: database
    spec:
      containers:
        - name: postgres
          image: postgres:15-alpine
          env:
            - name: POSTGRES_DB
              value: app_db
            - name: POSTGRES_USER
              value: postgres_user
            - name: POSTGRES_PASSWORD
              value: SecureProductionPassword123!
          ports:
            - containerPort: 5432
              name: postgres
          volumeMounts:
            - name: db-data
              mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
    - metadata:
        name: db-data
      spec:
        accessModes: [ "ReadWriteOnce" ]
        resources:
          requests:
            storage: 10Gi
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: edge-api-ingress
  namespace: production-architecture
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "5"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "15"
spec:
  ingressClassName: nginx
  rules:
    - host: api.production.internal
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: api-microservice-svc
                port:
                  number: 80
```

---

## 4. Comandos CLI Reales y Salidas de Terminal

Las siguientes invocaciones de terminal reales demuestran cómo auditar, verificar e inspeccionar componentes de arquitectura de software en un entorno Linux cloud-native.

### Comando 1: Inspección de Arquitectura de Procesos, Límites de Memoria y Sockets de Red

Verifique si una aplicación se está ejecutando como un único proceso monolítico o como un conjunto desacoplado de servicios examinando los sockets de red abiertos, los IDs de proceso y el mapeo de memoria.

```bash
$ ss -tulpn | grep -E '8080|5432|6379'
```

```text
tcp   LISTEN 0      4096          0.0.0.0:8080      0.0.0.0:*    users:(("agnhost",pid=10432,fd=3))
tcp   LISTEN 0      128           0.0.0.0:5432      0.0.0.0:*    users:(("postgres",pid=11204,fd=6))
tcp   LISTEN 0      512           0.0.0.0:6379      0.0.0.0:*    users:(("redis-server",pid=11560,fd=7))
```

### Comando 2: Auditoría del Descubrimiento de Servicios dentro del Clúster y Resolución DNS entre Capas (Cross-Tier)

En arquitecturas multi-tier y de microservicios, los componentes interactúan mediante el descubrimiento de servicios (service discovery). Pruebe la resolución interna del dominio del clúster desde el interior de un Pod de aplicación para verificar la separación de capas.

```bash
$ kubectl exec -it deployment/api-microservice -n production-architecture -- nslookup stateful-db-0.stateful-db-headless.production-architecture.svc.cluster.local
```

```text
Server:		10.96.0.10
Address:	10.96.0.10#53

Name:	stateful-db-0.stateful-db-headless.production-architecture.svc.cluster.local
Address: 10.244.1.45
```

### Comando 3: Ejecución de una Solicitud de API de Ingress End-to-End con Encabezados y Tiempos HTTP

Verifique la conexión del cliente liviano (thin-client) a la capa de presentación/API, inspeccionando la negociación TLS, los códigos de estado HTTP y las métricas de tiempo.

```bash
$ curl -v -w "\n--- Timings ---\nDNS Lookup: %{time_namelookup}s\nConnect: %{time_connect}s\nAppConnect: %{time_appconnect}s\nTTFB: %{time_starttransfer}s\nTotal: %{time_total}s\n" \
  -H "Host: api.production.internal" \
  http://10.96.150.20/healthz
```

```text
*   Trying 10.96.150.20:80...
* Connected to 10.96.150.20 (10.96.150.20) port 80 (#0)
> GET /healthz HTTP/1.1
> Host: api.production.internal
> User-Agent: curl/7.88.1
> Accept: */*
> 
< HTTP/1.1 200 OK
< Date: Thu, 06 Aug 2026 22:50:12 GMT
< Content-Type: text/plain; charset=utf-8
< Content-Length: 4
< Connection: keep-alive
< 
NOW!

--- Timings ---
DNS Lookup: 0.001231s
Connect: 0.002415s
AppConnect: 0.000000s
TTFB: 0.005120s
Total: 0.005210s
```

### Comando 4: Verificación de la Elasticidad del Horizontal Pod Autoscaler (HPA) bajo Carga

Inspeccione cómo la arquitectura de microservicios escala dinámicamente las capas de cómputo de la aplicación de manera independiente de las capas de bases de datos stateful.

```bash
$ kubectl get hpa api-microservice-hpa -n production-architecture
```

```text
NAME                   REFERENCE                       TARGETS   MINPODS   MAXPODS   REPLICAS   AGE
api-microservice-hpa   Deployment/api-microservice     84%/70%   3         10        5          14m
```

```bash
$ kubectl get pods -n production-architecture -l app.kubernetes.io/name=api-microservice
```

```text
NAME                                READY   STATUS    RESTARTS   AGE
api-microservice-7d8b5c9499-2x8pl   1/1     Running   0          14m
api-microservice-7d8b5c9499-8k2qm   1/1     Running   0          14m
api-microservice-7d8b5c9499-d4n9z   1/1     Running   0          14m
api-microservice-7d8b5c9499-m9qp2   1/1     Running   0          1m12s
api-microservice-7d8b5c9499-x7lvt   1/1     Running   0          1m12s
```

---

## 5. Guía de Diagnóstico y Verificación de Fallas

Al operar arquitecturas distribuidas cliente-servidor y de microservicios en producción, los SREs con frecuencia encuentran modos de falla arquitectónicos específicos. A continuación se presentan flujos de trabajo de diagnóstico sistemáticos para identificar y resolver estas fallas.

```
+---------------------------------------------------------------------------------------------------+
|                            SRE ARCHITECTURAL DIAGNOSTIC FLOWCHART                                 |
+---------------------------------------------------------------------------------------------------+
|                                                                                                   |
|  [ ISSUE: High Latency / 5xx Errors Detected at Edge ]                                            |
|                          |                                                                        |
|                          v                                                                        |
|  1. Check Network & Sockets  ===> (`ss -s`, `netstat`)  ===> Accumulating CLOSE_WAIT / TIME_WAIT?   |
|                          |                                   | YES: Socket / Connection Leak      |
|                          v                                                                        |
|  2. Check Service Discovery  ===> (`dig`, `nslookup`)   ===> DNS Resolution Timeout / NXDOMAIN?   |
|                          |                                   | YES: CoreDNS / Mesh Discovery Failure|
|                          v                                                                        |
|  3. Inspect Intra-Svc Call   ===> (`tcpdump`, `strace`) ===> TCP Retransmissions / Packet Drops?   |
|                          |                                   | YES: Network Partition / MTU Issue |
|                          v                                                                        |
|  4. Analyze Upstream State   ===> (`kubectl exec`)      ===> DB Pool Exhaustion / Lock Contention?  |
+---------------------------------------------------------------------------------------------------+
```

### Modo de Falla 1: Agotamiento del Connection Pool y Fuga de Sockets (Acumulación de `CLOSE_WAIT`)

* **Síntoma**: El microservicio de API deja de aceptar nuevas conexiones HTTP, devolviendo `504 Gateway Timeout` o `500 Internal Server Error` a la capa de Ingress.
* **Causa Raíz**: El código de la aplicación se comunica de forma sincrónica con servicios o bases de datos aguas abajo (downstream) sin especificar timeouts de socket o sin cerrar adecuadamente los sockets TCP al recibir respuestas. Los sockets permanecen atascados en estado `CLOSE_WAIT`, agotando los descriptores de archivo del proceso (`ulimit -n`).

#### Paso de Diagnóstico 1: Contar los estados de los sockets por proceso

```bash
$ ss -ton state close-wait '( dport = :5432 or sport = :8080 )'
```

```text
Recv-Q Send-Q Local Address:Port  Peer Address:Port
1      0      10.244.1.12:43902   10.244.1.45:5432     timer:(off,0min,0sec)
1      0      10.244.1.12:43908   10.244.1.45:5432     timer:(off,0min,0sec)
1      0      10.244.1.12:43914   10.244.1.45:5432     timer:(off,0min,0sec)
```

#### Paso de Diagnóstico 2: Rastrear la asignación de descriptores de archivo para el proceso API

```bash
$ pidof agnhost | xargs -I {} ls -l /proc/{}/fd | wc -l
```

```text
1024
```

*(Nota: Alcanzar el límite estricto predeterminado de 1024 descriptores de archivos abiertos causa errores `accept4(): Too many open files`).*

#### Plan de Remediación
1. Configure timeouts explícitos para el connection pool del cliente HTTP (`KeepAliveTimeout 15s`, `MaxIdleConnsPerHost 100`) en la capa de aplicación.
2. Aplique el ajuste del rango de puertos efímeros y los parámetros de TCP keepalive a nivel de SO/Kernel a través de `/etc/sysctl.conf`:
   ```ini
   net.ipv4.tcp_tw_reuse = 1
   net.ipv4.tcp_fin_timeout = 15
   ```

---

### Modo de Falla 2: Amplificación de Latencia en Cascada (Thundering Herd / Ausencia de Circuit Breakers)

* **Síntoma**: Un pico momentáneo de latencia en la capa de base de datos causa un encolamiento exponencial de solicitudes en los microservicios de API aguas arriba (upstream), desencadenando un pico de CPU en todo el clúster y derribando todos los Pods de la aplicación.
* **Causa Raíz**: Cadenas de llamadas sincrónicas ($A \rightarrow B \rightarrow C \rightarrow D$) sin reintentos con jitter (retries-with-jitter), limitación de tasa (rate-limiting) o cortacircuitos (circuit breakers, por ejemplo, Resilience4j, Envoy Circuit Breaking).

#### Paso de Diagnóstico 1: Capturar la latencia de paquetes en vivo entre microservicios usando `tcpdump`

```bash
$ tcpdump -i any -nn -tt -s 0 'tcp port 8080 or tcp port 5432' -w /tmp/latency_trace.pcap
```

Analice las diferencias de marcas de tiempo de los paquetes TCP para aislar qué capa introduce el retraso de encolamiento.

#### Paso de Diagnóstico 2: Inspeccionar las métricas de disparo del circuit breaker en el proxy Envoy/Service Mesh

```bash
$ curl -s http://127.0.0.1:15000/stats | grep "circuit_breakers"
```

```text
cluster.outbound|80||api-microservice-svc.production-architecture.svc.cluster.local.upstream_cq_overflow: 482
cluster.outbound|80||api-microservice-svc.production-architecture.svc.cluster.local.cx_open: 1
```

#### Plan de Remediación
1. **Implementar Desacoplamiento Asincrónico**: Convertir las llamadas RPC sincrónicas para rutas no críticas en emisiones de eventos a través de una Arquitectura Orientada a Eventos (NATS/Kafka).
2. **Configurar Circuit Breaking y Rate Limiting**: Limitar el máximo de solicitudes pendientes concurrentes a dependencias aguas abajo. Si la latencia aguas abajo supera los $500\text{ms}$, falle rápidamente (fail fast) de inmediato para liberar carga y proteger la capa de base de datos.

---

### Modo de Falla 3: Split-Brain y Pérdida de Consenso en Arquitecturas Stateful Distribuidas

* **Síntoma**: Los nodos de base de datos stateful (por ejemplo, PostgreSQL HA primary-replica, clústeres Raft) aceptan operaciones de escritura conflictivas simultáneamente, causando corrupción de datos.
* **Causa Raíz**: La partición de red (por ejemplo, una `NetworkPolicy` de Kubernetes o un grupo de seguridad en la nube mal configurados) aisla el nodo A del nodo B. El nodo B asume incorrectamente que el nodo A está muerto, se promueve a sí mismo a Primary y acepta escrituras mientras el nodo A aún está vivo.

#### Paso de Diagnóstico 1: Verificar la conectividad de red entre nodos a través de las réplicas de Pods stateful

```bash
$ kubectl exec -it stateful-db-1 -n production-architecture -- nc -zv -w 3 stateful-db-0.stateful-db-headless 5432
```

```text
nc: connect to stateful-db-0.stateful-db-headless (10.244.1.45) port 5432 (tcp) failed: Connection timed out
```

#### Paso de Diagnóstico 2: Verificar el estado del quorum Raft / Consenso

```bash
$ journalctl -u patroni -n 50 --no-pager | grep -E 'ERROR|promoted|demoted|quorum'
```

```text
2026-08-06T22:55:01Z ERROR: Demoting node: lost connectivity to etcd distributed lock leader.
2026-08-06T22:55:02Z CRITICAL: Quorum lost. Node switching to Read-Only mode to prevent split-brain.
```

#### Plan de Remediación
1. Aplique **Requerimientos de Quorum** estrictos ($Q = \lfloor N/2 \rfloor + 1$). Asegúrese de que los clústeres stateful siempre desplieguen un número impar de miembros votantes (mínimo 3).
2. Implemente **Mecanismos STONITH / Fencing**: Asegúrese de que los nodos revoquen automáticamente su propia capacidad de escritura (cambiando a modo solo lectura o autoterminándose) en el instante en que se pierda el contacto con el almacenamiento de consenso distribuido (por ejemplo, etcd).

---

## 6. Referencias

* **Linux Professional Institute (LPI) Open Source Essentials (050-100)**:  
  https://www.lpi.org/our-certifications/open-source-essentials-overview/
* **LPI Learning Portal — Materiales para el Examen 050**:  
  https://learning.lpi.org/en/learning-materials/050-100/
* **CNCF Cloud Native Glossary — Arquitectura de Software y Microservicios**:  
  https://glossary.cncf.io/
* **Documentación de Kubernetes — Patrones y Conceptos de Arquitectura de Producción**:  
  https://kubernetes.io/docs/concepts/
* **Arquitectura de Envoy Proxy y Visión General de Sistemas Distribuidos**:  
  https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/arch_overview
* **La Metodología Arquitectónica The Twelve-Factor App**:  
  https://12factor.net/