# Guía de estudio: LPI DevOps Tools Engineer (Examen 701-100) — Tema 1.2: Componentes y plataformas estándar para software

---

## 1. Architectural Motivation and Production Problem

### Escenario de producción y modos de fallo arquitectónicos
En la infraestructura monolítica tradicional, las aplicaciones de software dependen en gran medida del almacenamiento local del sistema de archivos POSIX (p. ej., dispositivos de bloques locales, exportaciones NFS montadas) e instancias de bases de datos coubicadas y fuertemente acopladas. En las plataformas en la nube distribuidas modernas, esta topología heredada introduce severos modos de fallo operacional:

1. **Stateful Compute Scaling Bottlenecks**: Cuando las instancias de cómputo mantienen un estado persistente en discos locales (`/var/data` o almacenamiento efímero de la instancia), el escalado horizontal mediante mecanismos automatizados (como AWS Auto Scaling Groups u OpenStack Heat) se vuelve imposible sin costosas fases de sincronización o corrupción de datos.
2. **POSIX Lock Contention & I/O Operations Limits**: Los sistemas de archivos compartidos tradicionales (NFSv3/v4) sufren por la sobrecarga de bloqueos (locking overhead) y la latencia de red cuando cientos de instancias de microservicios intentan realizar operaciones de escritura concurrentes contra nodos de archivos centralizados.
3. **Coupled Failures in Database Co-location**: Ejecutar daemons de bases de datos directamente en los nodos host de las aplicaciones crea contención de recursos (agotamiento de CPU/memoria) e impide el aislamiento independiente de los dominios de fallo, lo que lleva a caídas en cascada durante picos de tráfico de alta carga.

### Arquitectura de servicios de plataforma e implementación de referencia de OpenStack
Las plataformas en la nube modernas desacoplan la lógica de ejecución de los mecanismos de persistencia al proporcionar servicios de infraestructura estándar:

```
+-----------------------------------------------------------------------------------+
|                                 APPLICATION LAYER                                 |
|               (Stateless Microservices / Ephemeral Worker Nodes)                  |
+-----------------------------------------------------------------------------------+
          |                                  |                                  |
          | REST / S3 API                    | SQL / Protocol                   | Redis Protocol
          v                                  v                                  v
+-----------------------+  +---------------------------------+  +-----------------------+
|    OBJECT STORAGE     |  |       RELATIONAL DB (DBaaS)     |  |   NOSQL / IN-MEMORY   |
| (OpenStack Swift /    |  |  (OpenStack Trove / Patroni HA  |  |  (Redis Cluster /     |
|    Ceph RGW / S3)     |  |       PostgreSQL / MySQL)       |  |      Cassandra)       |
+-----------------------+  +---------------------------------+  +-----------------------+
          |                                  |                                  |
          +----------------------------------+----------------------------------+
                                             | Managed via Identity Engine
                                             v
                                 +-----------------------+
                                 |  IDENTITY & AUTH      |
                                 |  (OpenStack Keystone) |
                                 +-----------------------+
```

1. **Object Storage (OpenStack Swift / AWS S3 / Ceph RGW)**: Ofrece interfaces basadas en HTTP RESTful (`GET`, `PUT`, `DELETE`), anillos de hashing consistente, durabilidad WORM (Write Once, Read Many), etiquetado de metadatos y escalado arbitrario sin las restricciones del sistema de archivos POSIX.
2. **Block Storage (OpenStack Cinder / AWS EBS)**: Entrega volúmenes de bloques persistentes y puros adjuntos a través de redes de almacenamiento (iSCSI, Fibre Channel, Ceph RBD) directamente a los nodos de cómputo para cargas de trabajo transaccionales de alto IOPS.
3. **Database as a Service (DBaaS) (OpenStack Trove / Managed RDS)**: Proporciona aprovisionamiento automatizado, recuperación automatizada en un punto en el tiempo (PITR), gestión de réplicas de lectura y orquestación de failover para almacenes relacionales (RDBMS) y NoSQL.
4. **Identity & Catalog Service (OpenStack Keystone)**: Sirve como el API gateway central para autenticación, RBAC, validación de tokens de servicio y resolución dinámica de endpoints a través de los componentes de la nube.

---

## 2. Technical Comparisons and Trade-off Tables

### Paradigmas de almacenamiento: Object Storage vs Block Storage vs Shared File Systems

| Métrica / Característica | Object Storage (OpenStack Swift / AWS S3) | Block Storage (OpenStack Cinder / EBS) | Shared File System (OpenStack Manila / NFS) |
| :--- | :--- | :--- | :--- |
| **Interfaz primaria** | APIs REST HTTP (Swift API, S3 API) | Dispositivo de bloques puro (`/dev/vdb`, iSCSI, RBD) | Protocolo de red POSIX (NFSv4, SMB) |
| **Modelo de consistencia** | Consistencia eventual / Consistencia fuerte de lectura tras escritura | Consistencia inmediata estricta (Nivel de sector) | Consistencia fuerte inmediata (Bloqueo POSIX) |
| **Límite de escalabilidad** | Escala de Exabytes; espacio de nombres plano mediante hashing en anillo | Tamaño fijo por volumen; requiere expansión del sistema de archivos | Multi-Terabyte; limitado por bloqueos de nodo principal (head-node) |
| **Latencia y rendimiento (Throughput)** | Alta latencia TTFB (50–200 ms), rendimiento masivo | Latencia IOPS submilisegundo (<1–5 ms) | Latencia baja a media (retraso de red de 5–20 ms) |
| **Patrón de acceso de cliente** | Lectura/escritura multicliente concurrente sobre HTTP | Adjunto de una sola instancia (RWO) o Cluster FS (RWX) | Lectura/escritura compartida multinodo concurrente (RWX) |
| **Almacenamiento de metadatos** | Encabezados HTTP clave-valor definidos por el usuario | Tabla de particiones estándar / metadatos de FS local | Estructuras Inode, bloqueos de jerarquía del árbol de directorios |

### Arquitecturas de bases de datos: Relacional vs Clave-Valor en memoria vs Documento vs Columnas anchas (Wide-Column)

| Tipo de motor | Implementaciones de referencia | Modelo de consistencia | Mecanismo de escalado horizontal | Caso de uso ideal en producción | Compensaciones (Trade-offs) arquitectónicas |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Relacional (RDBMS)** | PostgreSQL, MySQL, OpenStack Trove | ACID estricto (Atomicidad, Consistencia, Aislamiento, Durabilidad) | Réplica en flujo (WAL), réplicas de lectura, sharding (Citus) | Transacciones financieras, modelos de dominio relacionales | Límite de escalado vertical; migraciones de esquema complejas a escala |
| **Clave-Valor en memoria** | Redis Cluster, KeyDB, Memcached | ACID en un solo nodo; consistencia eventual en cluster | Particionamiento por Hash Slot (16.384 slots asignados entre nodos) | Caché de sesiones en tiempo real, limitación de tasa (rate limiting), mensajería pub/sub | Costos de almacenamiento limitados por la RAM; retrasos en la persistencia de datos bajo un alto rendimiento de escritura |
| **NoSQL de documentos** | MongoDB, Couchbase | Configurable (Read/Write Concern ajustable) | Sharding distribuido mediante controladores de consulta por router | Esquemas dinámicos, catálogos JSON, gestión de contenidos | Sobrecarga de almacenamiento por duplicación de campos; consumo elevado de RAM para índices |
| **NoSQL de columnas anchas** | Apache Cassandra, ScyllaDB | Consistencia ajustable ($R + W > N$) | Topología en anillo P2P sin maestro con hashing consistente (Vnodes) | Métricas de series temporales de alto rendimiento, ingestión de telemetría IoT | Sin soporte para `JOIN` de SQL; los patrones de acceso a datos deben predeterminarse al diseñar las tablas |

---

## 3. Production-Grade Complete Infrastructure Manifests

### 3.1 Aprovisionamiento de contenedor de Object Storage OpenStack Swift vía Terraform (`main.tf`)
Este código HCL aprovisiona un contenedor de almacenamiento de objetos OpenStack Swift que cuenta con listas de control de acceso (ACL), metadatos definidos por el usuario y control de versiones.

```hcl
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    openstack = {
      source  = "openstack/openstack"
      version = "~> 1.53.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5.0"
    }
  }
}

provider "openstack" {
  auth_url    = "https://openstack.internal.net:5000/v3/"
  region      = "RegionOne"
  user_name   = "sre_deployer"
  password    = "ProductionVaultSecret2026!"
  tenant_name = "production-platform"
  domain_name = "Default"
}

resource "random_string" "container_suffix" {
  length  = 8
  special = false
  upper   = false
}

# Primary Swift Container for Production Artifacts
resource "openstack_objectstorage_container_v1" "app_artifacts_storage" {
  name = "prod-app-artifacts-${random_string.container_suffix.result}"

  metadata = {
    "Environment"  = "Production"
    "CostCenter"   = "PlatformSRE-1042"
    "StorageClass" = "Standard-Hot"
    "Auto-Archive" = "true"
  }

  # Container ACLs: Read accessible publicly; Write restricted to project deployer
  read_acl  = ".r:*,.rlistings"
  write_acl = "production-platform:sre_deployer"

  # Object Versioning Target Container
  history_container = openstack_objectstorage_container_v1.app_artifacts_versions.name

  content_type = "application/json"
}

# Dedicated Container for Storing Object Versions
resource "openstack_objectstorage_container_v1" "app_artifacts_versions" {
  name = "prod-app-artifacts-versions"

  metadata = {
    "Environment" = "Production"
    "Purpose"     = "Swift-Object-Versioning-Archive"
  }

  read_acl  = "production-platform:sre_deployer"
  write_acl = "production-platform:sre_deployer"
}
```

### 3.2 Configuración de cluster PostgreSQL de alta disponibilidad con Patroni (`patroni-postgresql.yaml`)
Este archivo de configuración completo establece Patroni para orquestar PostgreSQL HA utilizando `etcd3` para el consenso distribuido y el failover automático.

```yaml
scope: postgres-prod-cluster
namespace: /service
name: pg-node-01

etcd3:
  hosts:
    - 10.240.10.11:2379
    - 10.240.10.12:2379
    - 10.240.10.13:2379

restapi:
  listen: 0.0.0.0:8008
  connect_address: 10.240.10.21:8008

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    synchronous_mode: true
    synchronous_mode_strict: false
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        max_connections: 500
        shared_buffers: 8GB
        effective_cache_size: 24GB
        maintenance_work_mem: 2GB
        checkpoint_completion_target: 0.9
        wal_buffers: 16MB
        default_statistics_target: 100
        random_page_cost: 1.1
        effective_io_concurrency: 200
        work_mem: 16MB
        min_wal_size: 2GB
        max_wal_size: 16GB
        wal_level: replica
        max_wal_senders: 10
        max_replication_slots: 10
        hot_standby: "on"
        hot_standby_feedback: "on"

  initdb:
    - encoding: UTF8
    - data-checksums

  pg_hba:
    - host replication replicator 10.240.10.0/24 md5
    - host all all 10.240.10.0/24 md5
    - host all all 127.0.0.1/32 md5

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 10.240.10.21:5432
  data_dir: /var/lib/postgresql/data/pgdata
  bin_dir: /usr/lib/postgresql/15/bin
  pgpass: /var/lib/postgresql/.pgpass
  authentication:
    replication:
      username: replicator
      password: "StrongReplicationPassword2026!"
    superuser:
      username: postgres
      password: "SuperuserAdminPassword2026!"

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
```

### 3.3 Microservicio de Kubernetes integrado con Object Storage y DBaaS (`app-production.yaml`)
Este manifiesto de Kubernetes configura una carga de trabajo de aplicación que hace referencia a secretos de la plataforma para comunicarse con un bucket de OpenStack Swift y un cluster de DBaaS de PostgreSQL.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: cloud-platform-credentials
  namespace: production
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: "SWIFT_S3_KEY_PROD_1042"
  AWS_SECRET_ACCESS_KEY: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
  DATABASE_URL: "postgresql://app_user:DBPasswordProd2026!@10.240.10.21:5432/app_production?sslmode=verify-full&sslrootcert=/etc/ssl/certs/db-ca.crt"
  REDIS_URL: "redis://:RedisClusterAuth2026!@10.240.20.50:6379/0"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: platform-api-service
  namespace: production
  labels:
    app.kubernetes.io/name: platform-api
    app.kubernetes.io/tier: backend
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: platform-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: platform-api
    spec:
      containers:
        - name: api-engine
          image: internal-registry.net/platform/api-engine:v2.4.1
          imagePullPolicy: IfNotPresent
          envFrom:
            - secretRef:
                name: cloud-platform-credentials
          env:
            - name: OBJECT_STORAGE_ENDPOINT
              value: "https://swift.internal.net:8080/v1/AUTH_production-platform"
            - name: OBJECT_STORAGE_BUCKET
              value: "prod-app-artifacts-a1b2c3d4"
            - name: S3_COMPATIBLE_HOST
              value: "swift.internal.net"
          ports:
            - containerPort: 8080
              name: http-api
          resources:
            requests:
              cpu: "500m"
              memory: "1Gi"
            limits:
              cpu: "2000m"
              memory: "4Gi"
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 15
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /ready
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 2
```

---

## 4. Real CLI Commands and Actual Terminal Outputs ($)

### 4.1 Autenticación con OpenStack Keystone y operación de Swift CLI

```bash
$ export OS_AUTH_URL="https://openstack.internal.net:5000/v3/"
$ export OS_PROJECT_NAME="production-platform"
$ export OS_USERNAME="sre_deployer"
$ export OS_PASSWORD="ProductionVaultSecret2026!"
$ export OS_IDENTITY_API_VERSION=3
$ export OS_USER_DOMAIN_NAME="Default"

$ openstack token issue
+-----------+------------------------------------------------------------------+
| Field     | Value                                                            |
+-----------+------------------------------------------------------------------+
| expires   | 2026-08-07T12:00:00+0000                                         |
| id        | gAAAAABmpX8zN_8yK0...TRuncatedTokenString...9XzQ                 |
| project_id| 4a79df89b9104c86b2e7c3e59041b3a1                                 |
| user_id   | e90c5f21bd724e5aa9a288e404b901a2                                 |
+-----------+------------------------------------------------------------------+

$ openstack container create prod-app-artifacts-a1b2c3d4
+------------------------------+------------------------------+------------------------------------+
| account                      | container                    | x-trans-id                         |
+------------------------------+------------------------------+------------------------------------+
| AUTH_4a79df89b9104c86b2e7... | prod-app-artifacts-a1b2c3d4  | tx5b6f7e8a9d0c4b2a8e1f0-0066b2a4c1 |
+------------------------------+------------------------------+------------------------------------+

$ swift upload prod-app-artifacts-a1b2c3d4 --header "X-Object-Meta-Checksum: sha256" release-v2.4.1.tar.gz
release-v2.4.1.tar.gz

$ swift stat prod-app-artifacts-a1b2c3d4 release-v2.4.1.tar.gz
       Account: AUTH_4a79df89b9104c86b2e7c3e59041b3a1
     Container: prod-app-artifacts-a1b2c3d4
        Object: release-v2.4.1.tar.gz
  Content Type: application/x-gzip
Content Length: 52428800
 Last Modified: Fri, 07 Aug 2026 04:30:00 GMT
          ETag: 7c222fb2927d828af22f592134e89324
 Meta Checksum: sha256
 Accept-Ranges: bytes
   X-Trans-Id: txd8a1e2f3c4b5a67890-0066b2a5ef
```

### 4.2 Consulta del estado del cluster PostgreSQL Patroni

```bash
$ patronictl -c /etc/patroni/patroni.yaml list postgres-prod-cluster
+ Cluster: postgres-prod-cluster (7259104820194830192) ---+----+-----------+
| Member     | Host         | Role    | State   | TL | Lag in MB |
+------------+--------------+---------+---------+----+-----------+
| pg-node-01 | 10.240.10.21 | Leader  | running |  4 |           |
| pg-node-02 | 10.240.10.22 | Sync    | running |  4 |         0 |
| pg-node-03 | 10.240.10.23 | Replica | running |  4 |         0 |
+------------+--------------+---------+---------+----+-----------+

$ psql "postgresql://postgres@10.240.10.21:5432/app_production" -c "SELECT client_addr, state, sync_state, sync_priority FROM pg_stat_replication;"
  client_addr  |   state   | sync_state | sync_priority 
---------------+-----------+------------+---------------
 10.240.10.22  | streaming | sync       |             1
 10.240.10.23  | streaming | potential  |             2
(2 rows)
```

### 4.3 Inspección de Hash Slot y topología de nodos en Redis Cluster

```bash
$ redis-cli -h 10.240.20.50 -p 6379 -a "RedisClusterAuth2026!" cluster info
# Cluster
cluster_state:ok
cluster_slots_assigned:16384
cluster_slots_ok:16384
cluster_slots_pfail:0
cluster_slots_fail:0
cluster_known_nodes:6
cluster_size:3
cluster_current_epoch:6
cluster_my_epoch:1
cluster_stats_messages_sent:1849204
cluster_stats_messages_received:1849190

$ redis-cli -h 10.240.20.50 -p 6379 -a "RedisClusterAuth2026!" cluster nodes
e1a2b3c4d5e6... 10.240.20.50:6379@16379 master - 0 1691382600000 1 connected 0-5460
f7g8h9i0j1k2... 10.240.20.51:6379@16379 master - 0 1691382601000 2 connected 5461-10922
l3m4n5o6p7q8... 10.240.20.52:6379@16379 master - 0 1691382600500 3 connected 10923-16383
a9b8c7d6e5f4... 10.240.20.53:6379@16379 slave e1a2b3c4d5e6... 0 1691382601200 1 connected
b1c2d3e4f5g6... 10.240.20.54:6379@16379 slave f7g8h9i0j1k2... 0 1691382600800 2 connected
c7d8e9f0g1h2... 10.240.20.55:6379@16379 slave l3m4n5o6p7q8... 0 1691382601000 3 connected
```

---

## 5. Verification, Failure Diagnostics, and Troubleshooting Guide

### 5.1 Diagrama de flujo del árbol de decisión de diagnóstico

```
                      [ Production Incident / Service Degradation ]
                                           |
                   +-----------------------+-----------------------+
                   |                                               |
        [ Storage / Asset API Error ]                   [ Database Failure / Timeout ]
                   |                                               |
       +-----------+-----------+                       +-----------+-----------+
       |                       |                       |                       |
[HTTP 403 Forbidden]    [HTTP 503 Service      [Connection Refused     [High Replication
 / ACL Mismatch]         Unavailable]           / Pool Exhausted]       Lag / Disk Full]
       |                       |                       |                       |
 Verify Keystone Token  Inspect Swift Storage   Verify Patroni DCS      Check PG WAL Disk Usage
 & S3 Secret Access Key Ring & Account Audit   etcd Health & max_conn  & Network Bandwidth
       |                       |                       |                       |
 `openstack token       `swift-recon -g         `patronictl list`       `SELECT pg_wal_lsn_diff`
   issue`                 --all`                `pg_stat_activity`
```

### 5.2 Escenarios de fallo y guías de resolución (Runbooks)

#### Escenario de fallo 1: OpenStack Swift HTTP 503 Service Unavailable / Desincronización de anillo (Ring Desynchronization)
- **Síntoma**: Los microservicios registran en los logs `HTTP 503 Service Unavailable` o `Container ring checksum mismatch` al intentar lecturas o escrituras de objetos.
- **Causa raíz**: Desincronización entre los archivos `object.ring.gz` o `container.ring.gz` a través de los nodos de proxy de Swift y almacenamiento tras el reemplazo fallido de un nodo.
- **Procedimiento de diagnóstico**:
  ```bash
  # Check Swift ring consistency across storage nodes
  $ swift-recon -g /etc/swift/object.builder --md5

  # Inspect Swift proxy error logs for ring lookup failures
  $ grep -i "503" /var/log/swift/swift-proxy-server.log | tail -n 20
  ```
- **Plan de remediación**:
  1. Rebalancear los anillos de compilación (builder rings) de Swift en el controlador de almacenamiento: `swift-ring-builder /etc/swift/object.builder rebalance`.
  2. Sincronizar los artefactos `.ring.gz` actualizados a todos los nodos en `/etc/swift/`.
  3. Recargar los procesos de proxy de Swift: `systemctl reload openstack-swift-proxy.service`.

#### Escenario de fallo 2: Agotamiento de conexiones en PostgreSQL y protección Split-Brain de Patroni
- **Síntoma**: Las aplicaciones registran en los logs `FATAL: remaining connection slots are reserved for non-replication superuser connections`, lo que genera errores HTTP 500 en los endpoints de la API.
- **Causa raíz**: Microservicios abriendo conexiones directas sin pool a PostgreSQL, junto con particiones de red transitorias que provocan que Patroni pierda el cuórum con `etcd`.
- **Procedimiento de diagnóstico**:
  ```bash
  # Inspect active database backend states and running connections
  $ psql "postgresql://postgres@10.240.10.21:5432/app_production" -c "
  SELECT pid, age(clock_timestamp(), query_start), usename, query, state 
  FROM pg_stat_activity 
  WHERE state != 'idle' 
  ORDER BY age(clock_timestamp(), query_start) DESC LIMIT 10;"

  # Verify health of etcd consensus cluster
  $ etcdctl --endpoints=10.240.10.11:2379,10.240.10.12:2379,10.240.10.13:2379 endpoint health
  ```
- **Plan de remediación**:
  1. Cancelar consultas descontroladas (runaway queries): `SELECT pg_cancel_backend(pid);`.
  2. Desplegar o reconfigurar middleware de agrupación de conexiones (PgBouncer) entre el Deployment de la aplicación y los endpoints de Patroni.

#### Escenario de fallo 3: Desalojo de Hash Slot en Redis Cluster y pánico por falta de memoria (Out of Memory)
- **Síntoma**: Las escrituras en Redis fallan con `OOM command not allowed when used memory > 'maxmemory'` o `CLUSTERDOWN The cluster is down`.
- **Causa raíz**: Invalidación de las asignaciones de Hash Slot debido a la caída no gestionada de un nodo maestro sin promoción de réplica, o agotamiento del pool de memoria.
- **Procedimiento de diagnóstico**:
  ```bash
  # Inspect memory consumption and eviction stats
  $ redis-cli -h 10.240.20.50 -p 6379 -a "RedisClusterAuth2026!" info memory

  # Check slot state across cluster master nodes
  $ redis-cli -h 10.240.20.50 -p 6379 -a "RedisClusterAuth2026!" cluster check 10.240.20.50:6379
  ```
- **Plan de remediación**:
  1. Establecer políticas activas de desalojo de claves: `CONFIG SET maxmemory-policy allkeys-lru`.
  2. Forzar la toma de control (failover takeover) de la réplica si un nodo maestro pasa a estar no asignado: `CLUSTER FAILOVER TAKEOVER`.

---

## 6. Referencias

- [Linux Professional Institute (LPI) DevOps Tools Engineer Overview & Objectives](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
- [OpenStack Swift Object Storage Architectural Guide](https://docs.openstack.org/swift/latest/)
- [OpenStack Trove Database-as-a-Service Documentation](https://docs.openstack.org/trove/latest/)
- [Patroni High-Availability PostgreSQL Documentation](https://patroni.readthedocs.io/en/latest/)
- [Redis Cluster Specification & Hash Slot Architecture](https://redis.io/docs/reference/cluster-spec/)
- [Kubernetes Persistent Storage & Volume Architectural Concepts](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)