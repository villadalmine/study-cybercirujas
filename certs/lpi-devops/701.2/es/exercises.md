# LPI DevOps Tools Engineer (Exam 701-100) — Topic 1.2: Standard Components and Platforms for Software

**Ponderación del examen:** 3.33  
**Certificación objetivo:** LPI DevOps Tools Engineer (Exam 701-100, Version 1.0)  
**Objetivo 101.2:** Standard Components and Platforms for Software  
**Referencia oficial:** [LPI DevOps Tools Engineer Overview](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)

---

## Descripción General de la Arquitectura y Fundamentos de Producción

Las arquitecturas modernas cloud-native y DevOps se basan en componentes de infraestructura estandarizados para manejar la persistencia de datos, el almacenamiento en caché de estado, la mensajería asíncrona y el almacenamiento de objetos (blob storage). Como DevOps Engineer o Platform Architect, dominar estos bloques de construcción requiere comprender sus mecánicas internas, protocolos de comunicación, modos de falla y trade-offs.

```
                    +-------------------------------------------------+
                    |                API Gateway / Edge               |
                    +-------------------------------------------------+
                                             |
                                             v
                    +-------------------------------------------------+
                    |           Application Microservices             |
                    +-------------------------------------------------+
                      /                      |                      \
                     /                       v                       \
                    v              +-------------------+              v
  +-------------------+            |  Message Queue    |            +-------------------+
  |  In-Memory Cache  |            |    (RabbitMQ)     |            |  Object Storage   |
  |     (Redis)       |            +-------------------+            |  (MinIO / S3)     |
  +-------------------+                      |                      +-------------------+
            ^                                v                                ^
            |                      +-------------------+                      |
            +----------------------|  Worker Service   |----------------------+
                                   +-------------------+
                                             |
                                             v
                                   +-------------------+
                                   | Relational RDBMS  |
                                   |   (PostgreSQL)    |
                                   +-------------------+
```

### Matriz de Arquitectura de Componentes Clave

| Tipo de Componente | Tecnología Principal | Protocolo / API | Caso de Uso Principal | Modelo de Persistencia de Estado | Consenso / Replicación |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Relational DB** | PostgreSQL | PostgreSQL Wire Protocol (TCP 5432) | Datos transaccionales, cumplimiento ACID | WAL (Write-Ahead Logging) + Page files | Streaming Replication (Sync/Async), Patroni (Raft/etcd) |
| **In-Memory Store** | Redis | RESP (Redis Serialization Protocol, TCP 6379) | Caching, session store, rate limiting | RDB Snapshots & AOF (Append-Only File) | Redis Sentinel (Asincrónico), Redis Cluster (Gossip) |
| **Message Broker** | RabbitMQ | AMQP 0-9-1 (TCP 5672) / MQTT | Distribución asíncrona de tareas, desacoplamiento | Disk-backed queues, Mnesia DB | Quorum Queues (Raft Consensus), Mirrored Queues (Classic) |
| **Object Storage** | MinIO / OpenStack Swift | S3 REST API (HTTP 9000) / Swift API | Assets no estructurados, backups, artifacts | Erasure Coding & Bitrot Protection | Hash Ring (Swift), Distributed Erasure Sets (MinIO) |

---

## Bloque de Ejercicios Prácticos 1: Capas de Persistencia de Datos Relacionales y NoSQL (PostgreSQL y Redis)

### Arquitectura en Profundidad y Trade-offs en Producción
1. **Mecánica de ACID y WAL en PostgreSQL**: PostgreSQL garantiza la Durabilidad (Durability) a través del Write-Ahead Log (WAL). Antes de que cualquier modificación de datos (INSERT/UPDATE/DELETE) se escriba en los archivos de almacenamiento heap, se registra secuencialmente en el WAL. Los connection poolers como `PgBouncer` mitigan el overhead de proceso-por-conexión de PostgreSQL manteniendo un pool reutilizable de conexiones backend.
2. **Persistencia en Memoria y Evicción en Redis**: Redis procesa comandos en un event loop de un solo hilo (single-threaded). Cuando se alcanzan los límites de memoria (`maxmemory`), Redis aplica políticas de evicción como `volatile-lru` (Least Recently Used con TTL) o `allkeys-lru`. Las opciones de persistencia incluyen **RDB** (snapshots binarios en un punto en el tiempo) y **AOF** (logs append-only de operaciones de escritura).

---

### Ejecución Guiada del Laboratorio Paso a Paso

#### Paso 1: Aprovisionamiento del Manifiesto de Infraestructura de Persistencia
Crea un directorio de trabajo llamado `lpi-block1` y crea un manifiesto `docker-compose.yml` de grado de producción que implemente PostgreSQL con configuraciones personalizadas de WAL y Redis configurado con una estrategia de persistencia AOF y política de evicción LRU.

```bash
mkdir -p lpi-block1 && cd lpi-block1
cat << 'EOF' > docker-compose.yml
version: '3.8'

services:
  postgres:
    image: postgres:15-alpine
    container_name: lpi-postgres
    environment:
      POSTGRES_DB: devops_db
      POSTGRES_USER: lpi_admin
      POSTGRES_PASSWORD: SecurePassword123!
    command:
      - "postgres"
      - "-c"
      - "max_connections=100"
      - "-c"
      - "shared_buffers=128MB"
      - "-c"
      - "wal_level=replica"
      - "-c"
      - "max_wal_size=1GB"
      - "-c"
      - "archive_mode=on"
      - "-c"
      - "archive_command=cd ."
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U lpi_admin -d devops_db"]
      interval: 5s
      timeout: 3s
      retries: 5

  redis:
    image: redis:7-alpine
    container_name: lpi-redis
    command: >
      redis-server 
      --requirepass RedisAuthPass123! 
      --maxmemory 256mb 
      --maxmemory-policy allkeys-lru 
      --appendonly yes 
      --appendfsync everysec
    ports:
      - "6379:6379"
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "RedisAuthPass123!", "ping"]
      interval: 5s
      timeout: 3s
      retries: 5
EOF
```

#### Paso 2: Inicio de Servicios y Verificación del Estado en Tiempo de Ejecución
Inicia el stack y verifica que ambos contenedores alcancen un estado saludable (healthy).

```bash
docker compose up -d
docker compose ps
```

*Salida Esperada:*
```text
NAME           IMAGE                COMMAND                  SERVICE    CREATED          STATUS                    PORTS
lpi-postgres   postgres:15-alpine   "docker-entrypoint.s…"   postgres   5 seconds ago    Up 4 seconds (healthy)    0.0.0.0:5432->5432/tcp
lpi-redis      redis:7-alpine       "docker-entrypoint.s…"   redis      5 seconds ago    Up 4 seconds (healthy)    0.0.0.0:6379->6379/tcp
```

#### Paso 3: Diagnóstico de Transacciones de PostgreSQL e Inspección de WAL
Conéctate a la instancia de PostgreSQL a través de `psql` para inspeccionar las conexiones activas, el tamaño de la base de datos y el estado de la configuración de WAL.

```bash
docker exec -it lpi-postgres psql -U lpi_admin -d devops_db -c "SHOW wal_level;"
docker exec -it lpi-postgres psql -U lpi_admin -d devops_db -c "SELECT name, setting, unit FROM pg_settings WHERE name IN ('shared_buffers', 'max_connections');"
docker exec -it lpi-postgres psql -U lpi_admin -d devops_db -c "SELECT pid, usename, client_addr, state, query FROM pg_stat_activity;"
```

*Salida Esperada:*
```text
 wal_level 
-----------
 replica
(1 row)

     name      | setting | unit 
---------------+---------+------
 max_connections| 100     | 
 shared_buffers| 16384   | 8kB
(2 rows)

 pid |  usename  | client_addr | state  |                        query                         
-----+-----------+-------------+--------+------------------------------------------------------
  42 | lpi_admin |             | active | SELECT pid, usename, client_addr, state, query FROM pg_stat_activity;
(1 row)
```

#### Paso 4: Métricas del Motor de Redis e Inspección de Evicción
Ejecuta comandos administrativos en el cluster de Redis para analizar la asignación de memoria y las reglas de evicción.

```bash
docker exec -it lpi-redis redis-cli -a RedisAuthPass123! INFO memory
docker exec -it lpi-redis redis-cli -a RedisAuthPass123! CONFIG GET maxmemory-policy
```

*Salida Esperada:*
```text
# Memory
used_memory:872344
used_memory_human:851.90K
used_memory_rss:9842688
used_memory_peak:872344
maxmemory:268435456
maxmemory_human:256.00M
1) "maxmemory-policy"
2) "allkeys-lru"
```

---

### Preguntas de Verificación — Bloque 1

1. **Pregunta 1.1**: En PostgreSQL, ¿cuál es el impacto operativo preciso de seleccionar `wal_level = replica` en comparación con `wal_level = minimal`?
2. **Pregunta 1.2**: Si Redis está configurado con `--maxmemory-policy allkeys-lru` y se superan los límites de memoria, ¿cómo difiere su comportamiento con respecto a `noeviction`?

---

## Bloque de Ejercicios Prácticos 2: Arquitectura de Almacenamiento de Objetos Enterprise (Alineación con MinIO y OpenStack Swift)

### Arquitectura en Profundidad y Trade-offs en Producción
1. **Principios de Object Storage**: A diferencia de los sistemas de archivos POSIX o el almacenamiento en bloques (EBS/SAN), Object Storage es plano, orientado a metadatos y accesible exclusivamente a través de HTTP REST APIs (S3/Swift). Los objetos son inmutables; actualizar un objeto requiere reemplazarlo por completo.
2. **Erasure Coding y Protección contra Bitrot**: MinIO y OpenStack Swift dividen los payloads de los objetos en bloques de datos y paridad a través de múltiples discos/nodos (por ejemplo, $N/2$ datos + $N/2$ paridad). Esto permite la recuperación de datos incluso durante fallas de múltiples discos y repara automáticamente la corrupción silenciosa de datos (bitrot).
3. **Arquitectura de Referencia de OpenStack Swift**: OpenStack Swift gestiona la distribución de objetos mediante **Rings**. Un Ring mapea rutas virtuales lógicas (`/account/container/object`) a endpoints de almacenamiento físico utilizando algoritmos de hashing consistente.

```
Logical Request Path: GET /v1/AUTH_tenant/container/object.jpg
                           |
                           v
              +---------------------------+
              |     Swift Proxy Node      |
              +---------------------------+
                           |
            Lookup Partition in Hash Ring
                           |
        +------------------+------------------+
        |                  |                  |
        v                  v                  v
+---------------+  +---------------+  +---------------+
| Storage Node 1|  | Storage Node 2|  | Storage Node 3|
|  (Account)    |  |  (Container)  |  |   (Object)    |
+---------------+  +---------------+  +---------------+
```

---

### Ejecución Guiada del Laboratorio Paso a Paso

#### Paso 1: Despliegue del Emulador Distribuido MinIO Compatible con S3
Crea el directorio `lpi-block2` y escribe un `docker-compose.yml` para aprovisionar MinIO junto con la herramienta CLI `mc` (MinIO Client).

```bash
mkdir -p lpi-block2 && cd lpi-block2
cat << 'EOF' > docker-compose.yml
version: '3.8'

services:
  minio:
    image: minio/minio:RELEASE.2023-09-20T22-40-07Z
    container_name: lpi-minio
    environment:
      MINIO_ROOT_USER: minioadmin
      MINIO_ROOT_PASSWORD: MinioAdminPassword123!
    command: server /data --console-address ":9001"
    ports:
      - "9000:9000"
      - "9001:9001"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/live"]
      interval: 5s
      timeout: 3s
      retries: 5

  mc:
    image: minio/mc:RELEASE.2023-09-18T19-50-47Z
    container_name: lpi-mc
    depends_on:
      minio:
        condition: service_healthy
    entrypoint: >
      /bin/sh -c "
      mc alias set myminio http://minio:9000 minioadmin MinioAdminPassword123!;
      mc mb myminio/production-artifacts;
      mc anonymous set download myminio/production-artifacts;
      tail -f /dev/null
      "
EOF
```

#### Paso 2: Ejecución del Despliegue de Object Storage
Inicia el stack para crear el bucket S3 automáticamente.

```bash
docker compose up -d
docker compose ps
```

*Salida Esperada:*
```text
NAME        IMAGE                                        COMMAND                  SERVICE   CREATED          STATUS                    PORTS
lpi-mc      minio/mc:RELEASE.2023-09-18T19-50-47Z        "/bin/sh -c '/bin/sh…"   mc        6 seconds ago    Up 4 seconds              
lpi-minio   minio/minio:RELEASE.2023-09-20T22-40-07Z   "/usr/bin/docker-ent…"   minio     6 seconds ago    Up 5 seconds (healthy)    0.0.0.0:9000-9001->9000-9001/tcp
```

#### Paso 3: Aprovisionamiento de Objetos y Validación de Headers S3 mediante CLI
Sube un asset de prueba al bucket utilizando `mc` e inspecciona los headers HTTP devueltos utilizando `curl`.

```bash
echo "BUILD_COMMIT_HASH=a1b2c3d4e5f6" > build.env
docker cp build.env lpi-mc:/tmp/build.env
docker exec -it lpi-mc mc cp /tmp/build.env myminio/production-artifacts/build.env
docker exec -it lpi-mc mc ls myminio/production-artifacts/
curl -I http://localhost:9000/production-artifacts/build.env
```

*Salida Esperada:*
```text
[2026-08-07 04:40:00 UTC]  30B STANDARD build.env

HTTP/1.1 200 OK
Accept-Ranges: bytes
Content-Length: 30
Content-Type: text/plain; charset=utf-8
ETag: "8b9e6c4bf97b1029c3d4a8e2f1123456"
Last-Modified: Fri, 07 Aug 2026 04:40:00 GMT
Server: MinIO
Strict-Transport-Security: max-age=31536000; includeSubDomains
Vary: Origin
X-Amz-Request-Id: 177B7C8419A9B480
X-Content-Type-Options: nosniff
X-Xss-Protection: 1; mode=block
```

---

### Preguntas de Verificación — Bloque 2

1. **Pregunta 2.1**: En OpenStack Swift, ¿qué tres roles distintos desempeñan los servicios Account, Container y Object dentro de la arquitectura?
2. **Pregunta 2.2**: ¿Por qué los headers HTTP `ETag` son críticos durante los uploads multipart de objetos S3 en pipelines de CI/CD en producción?

---

## Bloque de Ejercicios Prácticos 3: Mensajería Desacoplada, Event Streaming y Arquitecturas de Encolamiento (RabbitMQ)

### Arquitectura en Profundidad y Trade-offs en Producción
1. **Arquitectura de Mensajería AMQP 0-9-1**: RabbitMQ funciona sobre el Advanced Message Queuing Protocol (AMQP 0-9-1). Las aplicaciones publican mensajes en un **Exchange**, el cual los enruta a una o más **Queues** basándose en **Bindings** y **Routing Keys**. Los consumidores se suscriben a las queues para procesar tareas de forma asíncrona.
2. **Tipos de Topologías de Exchange**:
   - **Direct**: Coincidencia exacta entre la routing key del mensaje y la binding key de la queue.
   - **Fanout**: Transmite mensajes a todas las queues vinculadas, ignorando las routing keys.
   - **Topic**: Coincidencia de patrones utilizando wildcards (`*` para una palabra, `#` para cero o más palabras).
   - **Headers**: Enruta basándose en los atributos del header del mensaje.
3. **Primitivas de Confiabilidad**: Para evitar la pérdida de mensajes durante fallas del broker:
   - **Publisher Confirms**: El broker confirma la recepción del mensaje al publicador.
   - **Durabilidad de Mensajes y Queues**: Las queues marcadas como `durable=true` persisten metadatos; los mensajes configurados con `delivery_mode=2` persisten el payload en disco.
   - **Dead Letter Exchanges (DLX)**: Los mensajes fallidos, no reconocidos o expirados se enrutan automáticamente a una queue DLX de respaldo para su análisis.

```
                     +---------------------------------------+
                     |          Direct Exchange              |
                     |         (orders.exchange)             |
                     +---------------------------------------+
                                   /           \
                 Routing Key:     /             \ Routing Key:
               "order.created"   /               \ "order.created"
                                v                 v
          +-----------------------+     +-----------------------+
          | Queue: inventory-proc |     | Queue: billing-proc   |
          |  (durable=true)       |     |  (durable=true)       |
          +-----------------------+     +-----------------------+
                                                   |
                                            On Max-Retries / NACK
                                                   v
                                        +-----------------------+
                                        | Dead Letter Exchange  |
                                        |      (dlx.orders)     |
                                        +-----------------------+
```

---

### Ejecución Guiada del Laboratorio Paso a Paso

#### Paso 1: Aprovisionamiento del Broker RabbitMQ con Infraestructura de Gestión
Crea el directorio `lpi-block3` y define un manifiesto que despliegue RabbitMQ con los plugins de gestión habilitados.

```bash
mkdir -p lpi-block3 && cd lpi-block3
cat << 'EOF' > docker-compose.yml
version: '3.8'

services:
  rabbitmq:
    image: rabbitmq:3.12-management-alpine
    container_name: lpi-rabbitmq
    environment:
      RABBITMQ_DEFAULT_USER: mqadmin
      RABBITMQ_DEFAULT_PASS: RabbitMqPassword123!
    ports:
      - "5672:5672"   # AMQP Protocol
      - "15672:15672" # Management UI / API
    healthcheck:
      test: ["CMD", "rabbitmq-diagnostics", "-q", "ping"]
      interval: 5s
      timeout: 3s
      retries: 5
EOF
```

#### Paso 2: Bootstrapping de RabbitMQ y Verificación de la Salud Operativa del Nodo
Inicia el contenedor y verifica la disponibilidad operativa utilizando `rabbitmq-diagnostics`.

```bash
docker compose up -d
docker exec -it lpi-rabbitmq rabbitmq-diagnostics check_running
```

*Salida Esperada:*
```text
Successfully connected to the RabbitMQ management plugin API.
Node 'rabbit@lpi-rabbitmq' is running.
```

#### Paso 3: Configuración de la Topología AMQP mediante CLI (`rabbitmqadmin`)
Declara un Dead Letter Exchange (DLX), un exchange principal, una queue DLX y una queue principal configurada con capacidades de dead-lettering.

```bash
# Declare DLX and DLX Queue
docker exec -it lpi-rabbitmq rabbitmqadmin -u mqadmin -p RabbitMqPassword123! declare exchange name=dlx.exchange type=direct
docker exec -it lpi-rabbitmq rabbitmqadmin -u mqadmin -p RabbitMqPassword123! declare queue name=orders.dlq durable=true
docker exec -it lpi-rabbitmq rabbitmqadmin -u mqadmin -p RabbitMqPassword123! declare binding source=dlx.exchange destination=orders.dlq routing_key=order.dead

# Declare Main Exchange and Queue bound to DLX
docker exec -it lpi-rabbitmq rabbitmqadmin -u mqadmin -p RabbitMqPassword123! declare exchange name=orders.exchange type=direct
docker exec -it lpi-rabbitmq rabbitmqadmin -u mqadmin -p RabbitMqPassword123! declare queue name=orders.main durable=true arguments='{"x-dead-letter-exchange":"dlx.exchange", "x-dead-letter-routing-key":"order.dead"}'
docker exec -it lpi-rabbitmq rabbitmqadmin -u mqadmin -p RabbitMqPassword123! declare binding source=orders.exchange destination=orders.main routing_key=order.created
```

*Salida Esperada:*
```text
exchange declared
queue declared
binding declared
exchange declared
queue declared
binding declared
```

#### Paso 4: Prueba de Publicación de Mensajes Persistentes e Inspección de Queues
Publica un mensaje persistente en el exchange e inspecciona la profundidad de la queue a través de `rabbitmqctl`.

```bash
docker exec -it lpi-rabbitmq rabbitmqadmin -u mqadmin -p RabbitMqPassword123! publish exchange=orders.exchange routing_key=order.created payload="{'order_id': 9942, 'status': 'PENDING'}" delivery_mode=2
docker exec -it lpi-rabbitmq rabbitmqctl list_queues name messages messages_ready messages_unacknowledged
```

*Salida Esperada:*
```text
Message published
Timeout: 60 seconds ...
Listing queues ...
name	messages	messages_ready	messages_unacknowledged
orders.dlq	0	0	0
orders.main	1	1	0
```

---

### Preguntas de Verificación — Bloque 3

1. **Pregunta 3.1**: ¿Qué condición específica activa que un mensaje sea enrutado automáticamente desde una queue principal hacia su Dead Letter Exchange configurado (`x-dead-letter-exchange`)?
2. **Pregunta 3.2**: En clusters de RabbitMQ de alta disponibilidad, ¿cómo difieren las **Quorum Queues** de las **Mirrored Queues** legadas en cuanto a consenso y seguridad de datos?

---

## Bloque de Ejercicios Prácticos 4: Abstracciones de Servicios de Plataformas Cloud y Service Discovery (Alineación con OpenStack)

### Arquitectura en Profundidad y Trade-offs en Producción
1. **Implementación de Referencia de Componentes de OpenStack**:
   - **Keystone**: Gestión de identidad, autenticación y catálogo de servicios (emite tokens Fernet).
   - **Nova**: Orquestación del ciclo de vida de instancias de cómputo.
   - **Neutron**: Redes Definidas por Software (SDN), routers, IPs flotantes, security groups.
   - **Glance**: Registro de imágenes de máquinas virtuales.
   - **Cinder**: Proveedor de almacenamiento en bloques (block storage).
   - **Swift**: Proveedor de almacenamiento de objetos (object storage).
2. **Arquitectura de Service Discovery**: Los microservicios requieren resolución dinámica de endpoints. Los sistemas utilizan **Client-Side Discovery** (el cliente consulta directamente a un registro como Consul/Eureka) o **Server-Side Discovery** (el cliente llega a un load balancer/DNS que consulta al registro).
3. **Database per Service vs Shared Database**: Los microservicios deben aislar sus data stores para forzar un desacoplamiento débil y escalado independiente. Compartir una sola base de datos monolítica crea un acoplamiento fuerte y puntos únicos de falla (single points of failure).

```
                    +----------------------------------+
                    |  Keystone / Auth Service API     |
                    +----------------------------------+
                                     |
                          Validates Fernet Token
                                     v
+------------------------+  REST   +------------------------+  SDN   +------------------------+
| Nova (Compute Service) |-------> | Neutron (Network Svc)  |------->| Floating IP / Router   |
+------------------------+         +------------------------+        +------------------------+
            |                                  |                                  |
   Attaches Volume                     Attaches Subnet                     Attaches Port
            v                                  v                                  v
+------------------------+         +------------------------+        +------------------------+
| Cinder (Block Storage) |         |  Glance (Image Svc)    |        | Target Compute Node    |
+------------------------+         +------------------------+        +------------------------+
```

---

### Ejecución Guiada del Laboratorio Paso a Paso

#### Paso 1: Aprovisionamiento de la Infraestructura de Plataforma Políglota Unificada
Crea el directorio `lpi-block4` y construye un stack completo de plataforma que simule un ecosistema de microservicios integrado con comprobaciones explícitas de dependencias de servicios y aislamiento de red.

```bash
mkdir -p lpi-block4 && cd lpi-block4
cat << 'EOF' > docker-compose.yml
version: '3.8'

networks:
  frontend-net:
    driver: bridge
  backend-net:
    driver: bridge

services:
  app-db:
    image: postgres:15-alpine
    container_name: platform-db
    networks:
      - backend-net
    environment:
      POSTGRES_DB: app_production
      POSTGRES_USER: app_user
      POSTGRES_PASSWORD: AppPassword456!
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U app_user -d app_production"]
      interval: 5s
      timeout: 3s
      retries: 5

  app-cache:
    image: redis:7-alpine
    container_name: platform-cache
    networks:
      - backend-net
    command: redis-server --requirepass CachePassword456!
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "CachePassword456!", "ping"]
      interval: 5s
      timeout: 3s
      retries: 5

  api-gateway:
    image: nginx:1.25-alpine
    container_name: platform-gateway
    networks:
      - frontend-net
      - backend-net
    ports:
      - "8080:80"
    volumes:
      - ./gateway.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      app-db:
        condition: service_healthy
      app-cache:
        condition: service_healthy
EOF
```

#### Paso 2: Definición de la Configuración del Proxy Gateway NGINX
Crea la configuración del reverse proxy gateway que simule el enrutamiento dinámico de servicios.

```bash
cat << 'EOF' > gateway.conf
server {
    listen 80;
    server_name localhost;

    location /health {
        add_header Content-Type text/plain;
        return 200 'GATEWAY_OK';
    }

    location /db-status {
        proxy_pass http://platform-db:5432;
    }
}
EOF
```

#### Paso 3: Inicialización de la Topología de la Plataforma y Auditoría de Diagnóstico
Lanza la plataforma completa y ejecuta diagnósticos de red para verificar la conectividad entre contenedores a través de bridges aislados.

```bash
docker compose up -d
docker compose ps
docker exec -it platform-gateway ping -c 2 platform-db
docker exec -it platform-gateway ping -c 2 platform-cache
curl -i http://localhost:8080/health
```

*Salida Esperada:*
```text
NAME               IMAGE                COMMAND                  SERVICE       CREATED          STATUS                    PORTS
platform-cache     redis:7-alpine       "docker-entrypoint.s…"   app-cache     8 seconds ago    Up 7 seconds (healthy)    6379/tcp
platform-db        postgres:15-alpine   "docker-entrypoint.s…"   app-db        8 seconds ago    Up 7 seconds (healthy)    5432/tcp
platform-gateway   nginx:1.25-alpine    "/docker-entrypoint.s…"   api-gateway   8 seconds ago    Up 7 seconds              0.0.0.0:8080->80/tcp

PING platform-db (172.28.0.2): 56 data bytes
64 bytes from 172.28.0.2: seq=0 ttl=64 time=0.081 ms
64 bytes from 172.28.0.2: seq=1 ttl=64 time=0.095 ms

PING platform-cache (172.28.0.3): 56 data bytes
64 bytes from 172.28.0.3: seq=0 ttl=64 time=0.075 ms
64 bytes from 172.28.0.3: seq=1 ttl=64 time=0.088 ms

HTTP/1.1 200 OK
Server: nginx/1.25.3
Date: Fri, 07 Aug 2026 04:42:00 GMT
Content-Type: text/plain
Content-Length: 10
Connection: keep-alive

GATEWAY_OK
```

---

### Preguntas de Verificación — Bloque 4

1. **Pregunta 4.1**: En OpenStack, ¿qué servicio actúa como la autoridad central de autenticación emitiendo los tokens requeridos por Nova, Neutron y Glance para ejecutar operaciones?
2. **Pregunta 4.2**: ¿Por qué el uso de una única base de datos relacional compartida entre múltiples microservicios se considera un anti-patrón arquitectónico en plataformas cloud-native?

---

<details>
<summary>Respuestas y Explicaciones Detalladas</summary>

### Respuestas del Bloque 1

1. **Respuesta 1.1**: Configurar `wal_level = replica` le indica a PostgreSQL que registre suficiente información en el Write-Ahead Log (WAL) para admitir el registro de escritura adelantada, la recuperación en un punto en el tiempo (PITR) y las réplicas standby de solo lectura. En contraste, `wal_level = minimal` elimina los detalles de registro necesarios para la replicación (como las entradas de WAL para cargas masivas), haciendo imposible la replicación con servidores standby.

2. **Respuesta 1.2**: Bajo `allkeys-lru`, cuando la memoria alcanza `maxmemory`, Redis intenta reclamar espacio eliminando las claves menos recientemente utilizadas (LRU) en todo el conjunto de datos, independientemente de si tienen una expiración (TTL) establecida. Bajo `noeviction`, Redis rechaza todos los comandos de escritura (devolviendo errores de memoria agotada como `OOM command not allowed when used memory > 'maxmemory'`), permitiendo únicamente operaciones de solo lectura.

---

### Respuestas del Bloque 2

1. **Respuesta 2.1**:
   - **Account Service**: Gestiona cuentas (tenants), listados de containers dentro de la cuenta y metadatos a nivel de cuenta almacenados en bases de datos SQLite.
   - **Container Service**: Gestiona containers (análogos a los buckets de S3), listados de objetos dentro de un container específico y metadatos a nivel de container almacenados en bases de datos SQLite.
   - **Object Service**: Gestiona los payloads binarios sin procesar de los objetos reales y sus metadatos HTTP asociados almacenados directamente en dispositivos de bloques del sistema de archivos local utilizando atributos extendidos de archivo (xattrs).

2. **Respuesta 2.2**: El header `ETag` en S3/Swift almacena el hash MD5 (o checksum del payload) del payload del objeto. Durante la subida multipart de artifacts de CI/CD en producción, verificar el `ETag` devuelto con respecto al hash del payload calculado localmente garantiza la integridad de datos de extremo a extremo, confirmando que la corrupción de red o los streams truncados no contaminaron el bucket de almacenamiento.

---

### Respuestas del Bloque 3

1. **Respuesta 3.1**: Un mensaje se entrega a un Dead Letter Exchange (DLX) bajo tres condiciones operativas específicas:
   - El mensaje es rechazado explícitamente o no reconocido (`basic.reject` o `basic.nack`) por un consumidor con `requeue=false`.
   - El mensaje expira debido al TTL (Time-To-Live) por mensaje o por queue.
   - El mensaje se descarta porque la queue de destino superó su límite de longitud máxima (`x-max-length`).

2. **Respuesta 3.2**: Las **Quorum Queues** están construidas sobre el **Raft Consensus Algorithm**, proporcionando seguridad de datos determinista, elecciones de líder predecibles y un mayor rendimiento bajo particiones de red. Las **Mirrored Queues** (queues clásicas legadas) dependen de protocolos de sincronización asíncrona personalizados que pueden sufrir pérdida de mensajes, comportamiento de bloqueo de sincronización durante la reincorporación de nodos y fallas de split-brain.

---

### Respuestas del Bloque 4

1. **Respuesta 4.1**: **Keystone** (OpenStack Identity Service). Proporciona autenticación, emisión de tokens (por ejemplo, tokens Fernet) y mantiene el Service Catalog unificado. Cada solicitud enviada a Nova, Neutron, Cinder o Glance debe presentar un token de autenticación válido de Keystone.

2. **Respuesta 4.2**: Una base de datos compartida acopla los microservicios en la capa de datos física. Crea puntos únicos de falla en la base de datos, invalida migraciones de esquema independientes, conduce a la contención de recursos compartidos (escalación de bloqueos, agotamiento de conexiones) y evita que los microservicios individuales elijan motores de datos adecuados para su carga de trabajo (por ejemplo, Document vs Relational vs In-Memory).

</details>

---

## Referencias de la Documentación Oficial

- **Linux Professional Institute (LPI)**: [DevOps Tools Engineer 701-100 Overview](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
- **Documentación de OpenStack**: [OpenStack Architecture & Component Guides](https://docs.openstack.org/)
- **Documentación de PostgreSQL**: [WAL Configuration & Architecture](https://www.postgresql.org/docs/current/wal-configuration.html)
- **Documentación de Redis**: [Redis Persistence & Memory Management](https://redis.io/docs/management/optimizations/memory-optimization/)
- **Documentación de RabbitMQ**: [AMQP 0-9-1 Concepts & Quorum Queues](https://www.rabbitmq.com/documentation.html)
- **Documentación de MinIO**: [MinIO Erasure Coding & S3 Architecture](https://min.io/docs/minio/linux/index.html)