# 701.2 — Componentes y plataformas estándar para software

**Certificación:** LPI DevOps Tools Engineer (examen 701-100, versión 2.0.0)
**Peso del tema:** 5.0
**Perfil:** Principal Platform Architect / Senior SRE

---

## 1. El problema arquitectónico: estás ensamblando una plataforma, no escribiéndola

Todo servicio no trivial que vayas a correr alguna vez en producción es una capa delgada de lógica de negocio propia apoyada sobre seis o siete componentes que ya escribió otra persona: un sustrato de cómputo, un almacenamiento durable, una base de datos transaccional, una caché, un broker de mensajes, un almacén de objetos y un borde de ingress/CDN. La decisión de ingeniería casi nunca es *«¿deberíamos tener una caché?»* — es **qué caché, operada por quién, con qué semántica de fallo, a qué costo, y qué le pasa al resto de la plataforma cuando falla.**

Este objetivo existe porque la clase de incidente de producción más cara no es un bug en el código de la aplicación. Es un **desajuste entre las garantías que un componente estándar realmente ofrece y las garantías que la aplicación supuso que ofrecía.**

Tres formas concretas de ese fallo, todas presentes en el mapa conceptual del examen:

1. **Desajuste de semántica de entrega.** Un equipo construye un pipeline de pedidos sobre RabbitMQ con `autoAck` habilitado porque «iba más rápido en el benchmark». Un pod consumidor muere por OOM en medio de una transacción. El broker ya había eliminado el mensaje en el momento de la entrega. Los pedidos desaparecen sin error, sin alerta y sin rastro — el gráfico de profundidad de cola está plano y en verde. El componente era correcto; la suposición («el broker va a reentregar») no lo era.

2. **Desajuste del límite de responsabilidad.** Un equipo migra de PostgreSQL autogestionado a un DBaaS gestionado y mantiene un cron nocturno de `pg_dump` en un host bastión. Dieciocho meses después se descubre que los backups automáticos del proveedor tienen una retención de 7 días mientras que el requisito de cumplimiento es de 35 días, y que el bastión fue dado de baja en una ronda de recorte de costos. Nadie era dueño de la brecha, porque cada lado asumió que lo era el otro.

3. **Desajuste de elasticidad.** Se pone una función serverless delante de una base de datos relacional de tamaño fijo. El tráfico se triplica. La plataforma FaaS escala solícitamente a 900 invocaciones concurrentes, cada una abriendo una conexión. El `max_connections = 200` de PostgreSQL se agota en cuatro segundos; todos los demás servicios que comparten la base — incluido el camino del healthcheck — empiezan a fallar. La capa elástica convirtió en arma a la inelástica.

La disciplina que previene los tres es la misma: **para cada componente estándar, conocé su modelo de servicio, su modelo de consistencia, su semántica de entrega, su eje de escalado y su modelo de costos — y escribilos como un contrato explícito antes de la primera línea de código.**

---

## 2. Modelos de servicio y el límite de responsabilidad

La división clásica IaaS/PaaS/SaaS no es taxonomía de marketing; es un **mapa de a quién le llega el aviso a las 03:00**. Leé la tabla como una matriz de responsabilidades, no como una lista de productos.

| Capa | IaaS | CaaS | PaaS | FaaS | SaaS |
|---|---|---|---|---|---|
| Físico / DC | Proveedor | Proveedor | Proveedor | Proveedor | Proveedor |
| Hipervisor | Proveedor | Proveedor | Proveedor | Proveedor | Proveedor |
| SO invitado + CVEs del kernel | **Vos** | Proveedor | Proveedor | Proveedor | Proveedor |
| Runtime de contenedores | **Vos** | Proveedor | Proveedor | Proveedor | Proveedor |
| Orquestación / planificación | **Vos** | Proveedor* | Proveedor | Proveedor | Proveedor |
| Runtime del lenguaje + parches | **Vos** | **Vos** (imagen) | Proveedor (buildpack) | Proveedor | Proveedor |
| Código de la aplicación | **Vos** | **Vos** | **Vos** | **Vos** | Proveedor |
| Datos / control de acceso | **Vos** | **Vos** | **Vos** | **Vos** | **Vos** |
| Política de escalado | **Vos** | **Vos** | Declarativa | Automática | Proveedor |
| Unidad de despliegue | Imagen de VM | Imagen de contenedor | Fuente / buildpack | Handler de función | Nada |
| Tiempo típico hasta el primer despliegue | Días | Horas | Minutos | Minutos | Cero |
| Superficie de lock-in | Baja (imágenes, cloud-init) | Baja (OCI, API de Kubernetes) | Media (buildpacks, service brokers) | **Alta** (formas de los eventos, IAM, runtime) | Total |

\* Plano de control de Kubernetes gestionado; el node pool sigue siendo tuyo salvo que sea un runtime de contenedores totalmente serverless.

**La regla que sobrevive a toda reorganización:** *los datos y el control de acceso nunca se mueven al proveedor.* Que el cifrado en reposo sea «gestionado por el proveedor» significa que el proveedor gestiona el cifrador, no tu política de bucket.

### 2.1 El modelo de costos es parte de la arquitectura

| Eje de precio | Dónde duele | Magnitud típica (nube pública, 2026) | Consecuencia arquitectónica |
|---|---|---|---|
| Cómputo on-demand | Servicios de régimen permanente | Línea base 1.0× | Nunca es el precio correcto para una capa 24/7 |
| Reservado / uso comprometido | Compromiso de 1–3 años | 0.4–0.65× | Necesita un pronóstico de capacidad, crea un piso |
| Spot / preemptible | Trabajo interrumpible | 0.1–0.3× | Exige manejo del drenado y checkpointing |
| Egreso a Internet | Cualquier API charlatana o contenido multimedia | $0.05–0.12 / GiB | Domina la factura en servicios de contenido; motiva el CDN |
| Tráfico entre AZ | Almacenes de datos replicados | $0.01–0.02 / GiB en cada sentido | Un clúster Kafka en 3 AZ paga cada salto de réplica |
| Por request | FaaS, almacenamiento de objetos, API gateways | $0.20–0.40 / millón | Mata la conversación de grano fino; batchear o morir |
| IOPS aprovisionadas | Bases de datos | $0.05–0.65 / IOPS-mes | A menudo supera al costo de la capacidad en sí |
| Sobreprecio del servicio gestionado | DBaaS vs. autogestionado | 1.3–2.5× la infra cruda | Compará contra un salario SRE cargado, no contra cero |

El cálculo honesto de autogestionado-versus-gestionado es:

```
cost_managed  =  list_price
cost_selfhost =  infra + (engineer_fte_fraction * loaded_salary)
                 + expected_annual_downtime_hours * revenue_per_hour
                 + opportunity_cost_of_not_building_product
```

Un clúster PostgreSQL HA de tres nodos son aproximadamente 0.2–0.3 FTE una vez que contás parcheo, upgrades de versión mayor, simulacros de restauración de backups y pruebas de failover. A €120k cargados, eso son €24k–€36k/año antes de un solo euro de hardware — que es por lo que las bases de datos relacionales gestionadas ganan para casi todo el mundo por debajo de escalas muy grandes, y pierden por encima.

---

## 3. Cómputo: máquinas virtuales, contenedores, funciones

### 3.1 Matriz de compromisos

| Propiedad | VM (KVM/Xen) | microVM (Firecracker/Cloud Hypervisor) | Contenedor (runc) | Contenedor en sandbox (gVisor/Kata) | FaaS |
|---|---|---|---|---|---|
| Arranque en frío | 20–60 s | 125 ms – 1 s | 50–500 ms | 200 ms – 2 s | 100 ms – 10 s en frío, ~1 ms en caliente |
| Kernel | Propio | Propio (mínimo) | **Compartido con el host** | Propio / en espacio de usuario | Del proveedor |
| Frontera de aislamiento | Hipervisor | Hipervisor + modelo de dispositivos mínimo | namespaces, cgroups, seccomp, LSM | Intercepción de syscalls / hipervisor | microVM del proveedor |
| Densidad por host | 10–40 | 100–1 000 | 100–300 | 50–200 | n/a |
| Tamaño de imagen | GiB | GiB | MiB | MiB | KiB–MiB |
| Estado local persistente | Nativo | Nativo | Solo vía volúmenes | Vía volúmenes | **Ninguno** |
| Tiempo máximo de ejecución | Sin límite | Sin límite | Sin límite | Sin límite | 15 min (AWS Lambda), 60 min (Cloud Run jobs) |
| Granularidad de facturación | Por segundo, mínimo 60 s | Por ms | Por nodo-segundo | Por nodo-segundo | Por ms + por request |
| Migración en vivo | Sí | Limitada | No | No | n/a |
| Indicado para | Legacy, módulos de kernel, aislamiento duro multi-tenant | Sustrato serverless multi-tenant | Microservicios sin estado | Código no confiable en nodos compartidos | Trabajo corto, con picos, orientado a eventos |

**La salvedad sobre el aislamiento de contenedores que se pregunta tanto en entrevistas como en exámenes:** un contenedor es un *proceso* con namespaces (`pid`, `net`, `mnt`, `uts`, `ipc`, `user`, `cgroup`), límites de cgroup, un filtro seccomp y un perfil LSM. **No** es una frontera de seguridad equivalente a una VM — una escalada local de privilegios en el kernel se le escapa. Precisamente por eso existen Firecracker, gVisor y Kata: las plataformas públicas de FaaS y CaaS no pueden correr inquilinos mutuamente desconfiados sobre un kernel compartido.

### 3.2 FaaS, de forma portable: Knative Serving

Knative es la respuesta neutral respecto del proveedor a «Lambda, pero en mi Kubernetes». Te da escalado a cero, autoescalado dirigido por requests y división de tráfico basada en revisiones. Manifiesto completo y desplegable:

```yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: invoice-renderer
  namespace: functions
  labels:
    app.kubernetes.io/name: invoice-renderer
    app.kubernetes.io/part-of: billing-platform
spec:
  template:
    metadata:
      name: invoice-renderer-00007
      annotations:
        autoscaling.knative.dev/class: kpa.autoscaling.knative.dev
        autoscaling.knative.dev/metric: concurrency
        autoscaling.knative.dev/target: "20"
        autoscaling.knative.dev/min-scale: "2"
        autoscaling.knative.dev/max-scale: "60"
        autoscaling.knative.dev/window: "60s"
        autoscaling.knative.dev/scale-down-delay: "120s"
    spec:
      containerConcurrency: 25
      timeoutSeconds: 300
      responseStartTimeoutSeconds: 15
      serviceAccountName: invoice-renderer
      containers:
        - name: user-container
          image: registry.internal.example.com/billing/invoice-renderer@sha256:9f2c1d4b8a6e5037c2b1ae94d3f70c5d81ea2b46f0c9d7381ba5e6c0f4a21d38
          ports:
            - name: http1
              containerPort: 8080
          env:
            - name: PDF_ENGINE
              value: weasyprint
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "http://otel-collector.observability.svc.cluster.local:4317"
            - name: DB_DSN
              valueFrom:
                secretKeyRef:
                  name: invoice-renderer-db
                  key: dsn
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              cpu: "2"
              memory: 1Gi
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            periodSeconds: 5
            failureThreshold: 3
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            runAsUser: 10001
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          volumeMounts:
            - name: scratch
              mountPath: /tmp
      volumes:
        - name: scratch
          emptyDir:
            medium: Memory
            sizeLimit: 256Mi
  traffic:
    - revisionName: invoice-renderer-00006
      percent: 90
    - revisionName: invoice-renderer-00007
      percent: 10
      tag: canary
```

Desplegá y observá el comportamiento de escalado desde cero:

```
$ kubectl apply -f invoice-renderer.yaml
service.serving.knative.dev/invoice-renderer configured

$ kn service list -n functions
NAME               URL                                                      LATEST                   AGE   CONDITIONS   READY
invoice-renderer   http://invoice-renderer.functions.example.com             invoice-renderer-00007   12d   3 OK / 3     True

$ kn revision list -n functions
NAME                     SERVICE            TRAFFIC   TAGS     GENERATION   AGE   CONDITIONS   READY
invoice-renderer-00007   invoice-renderer        10%   canary            7   4m    3 OK / 3     True
invoice-renderer-00006   invoice-renderer        90%                     6   3d    3 OK / 3     True

$ hey -z 30s -c 200 http://invoice-renderer.functions.example.com/render
Summary:
  Total:        30.0041 secs
  Slowest:      2.9137 secs
  Fastest:      0.0193 secs
  Average:      0.1842 secs
  Requests/sec: 1083.4

Latency distribution:
  50% in 0.0921 secs
  95% in 0.6110 secs
  99% in 2.4483 secs

$ kubectl get pods -n functions -l serving.knative.dev/service=invoice-renderer
NAME                                                     READY   STATUS    RESTARTS   AGE
invoice-renderer-00007-deployment-6b47c9f5d8-2xq4k       2/2     Running   0          31s
invoice-renderer-00007-deployment-6b47c9f5d8-7hjvn       2/2     Running   0          28s
invoice-renderer-00007-deployment-6b47c9f5d8-c9pmz       2/2     Running   0          25s
...
```

El `2/2` es el contenedor de usuario más el sidecar `queue-proxy` — el búfer de requests por pod de Knative, su ejecutor de concurrencia y su fuente de métricas. Cuando depures un problema de latencia en Knative, **leé los logs de `queue-proxy` antes que los de la aplicación**: es el componente que reporta el retardo de encolado por separado del tiempo del handler.

> **La trampa del pool de conexiones, en un solo manifiesto.** El servicio de arriba puede alcanzar 60 réplicas × 25 de concurrencia = 1 500 requests en vuelo. Si cada uno abre su propia conexión a PostgreSQL, necesitás un pooler de conexiones (PgBouncer en modo transacción) entre medio, o `max-scale` debe estar acotado por `max_connections / conexiones_por_pod`. Nunca hay que permitir que las capas elásticas desborden a las inelásticas — esta es la caída serverless-más-RDBMS más común de todas.

---

## 4. Almacenamiento: bloques, archivos, objetos — y el borde CDN

### 4.1 Las tres formas de la persistencia

| | Bloque | Archivo | Objeto |
|---|---|---|---|
| Unidad | Bloques de tamaño fijo sobre un dispositivo crudo | Archivos en una jerarquía POSIX | Blobs inmutables + metadatos bajo una clave |
| Acceso | `/dev/nvme1n1`, formateado por vos | `open()/read()/write()`, por rango de bytes | `GET`/`PUT`/`DELETE` HTTP de objetos completos |
| Mutación | In situ, a nivel de byte | In situ, a nivel de byte | **Reemplazo del objeto completo** (o multipart) |
| Latencia típica | 0.1–1 ms en NVMe local; 0.5–10 ms por red | 0.5–5 ms | 20–200 ms de time-to-first-byte |
| Compartición | Un solo escritor (`ReadWriteOnce`) | Muchos escritores (`ReadWriteMany`) | Lectores concurrentes ilimitados |
| Consistencia | Fuerte | Close-to-open (NFS) | Read-after-write fuerte para PUT/DELETE (S3 desde diciembre de 2020) |
| Techo de escalado | Por volumen (decenas de TiB) | Por sistema de archivos | Prácticamente ilimitado |
| Costo / GiB-mes | $0.08–0.12 (+ IOPS) | $0.16–0.30 | $0.004–0.023 |
| Indicado para | Bases de datos, write-ahead logs | Assets compartidos, apps legacy, directorios home | Backups, multimedia, data lake, artefactos, logs |
| Productos | EBS, Cinder, Ceph RBD, iSCSI/NVMe-oF | NFS, SMB, CephFS, EFS, Manila | S3, Swift, MinIO, Ceph RGW, GCS |

**La regla práctica que menos plata cuesta:** poné las bases de datos en bloque, poné en objetos todo lo que se escribe una vez y se lee muchas, y usá almacenamiento de archivos solo cuando una aplicación que no podés cambiar exige una ruta POSIX compartida entre escritores. Los volúmenes `ReadWriteMany` son los más lentos, más caros y más frágiles de los tres; cada uno de ellos en un diseño es una pregunta a responder, no un valor por defecto.

**APIs de almacenamiento de objetos.** S3 es el protocolo de facto sobre el cable; OpenStack Swift es el otro grande, y Ceph RADOS Gateway habla ambos. MinIO, Ceph RGW y el middleware S3 de Swift te permiten correr la API S3 on-premises — que es la decisión anti-lock-in más efectiva disponible en la capa de almacenamiento, porque las herramientas de backup, los log shippers, los almacenes de artefactos de CI y los motores de data lake hablan todos S3 y nada más.

### 4.2 Consumir almacenamiento declarativamente en Kubernetes (CSI)

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast-ssd
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  iops: "6000"
  throughput: "500"
  encrypted: "true"
  kmsKeyId: arn:aws:kms:eu-central-1:111122223333:key/6f1a2b3c-4d5e-6789-abcd-ef0123456789
reclaimPolicy: Retain
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
allowedTopologies:
  - matchLabelExpressions:
      - key: topology.ebs.csi.aws.com/zone
        values:
          - eu-central-1a
          - eu-central-1b
          - eu-central-1c
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: orders-db-data
  namespace: data
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: fast-ssd
  resources:
    requests:
      storage: 200Gi
```

Dos parámetros de ese manifiesto son decisiones arquitectónicas disfrazadas de campos:

- `reclaimPolicy: Retain` — con `Delete`, borrar un namespace destruye el volumen subyacente. En cualquier carga con estado, esto es una primitiva de pérdida de datos a una sola tecla.
- `volumeBindingMode: WaitForFirstConsumer` — con `Immediate`, el volumen se aprovisiona en una zona elegida antes de que el scheduler haya ubicado el pod, y el pod puede quedar permanentemente en `Pending` porque ningún nodo de esa zona tiene capacidad.

Verificación:

```
$ kubectl get pvc -n data orders-db-data
NAME             STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
orders-db-data   Bound    pvc-3f7a1e2c-9b04-4d61-8a7e-2c5d18f0b933   200Gi      RWO            fast-ssd       6d

$ kubectl get pv pvc-3f7a1e2c-9b04-4d61-8a7e-2c5d18f0b933 -o jsonpath='{.spec.nodeAffinity}' | jq .
{
  "required": {
    "nodeSelectorTerms": [
      {
        "matchExpressions": [
          {
            "key": "topology.ebs.csi.aws.com/zone",
            "operator": "In",
            "values": [
              "eu-central-1b"
            ]
          }
        ]
      }
    ]
  }
}
```

Esa salida es la respuesta a «¿por qué mi pod con estado nunca se reprograma después de la caída de un nodo?» — el PV está clavado a una zona, así que el pod de reemplazo solo puede planificarse ahí.

### 4.3 Contenido estático versus dinámico, y el CDN

| | Contenido estático | Contenido dinámico |
|---|---|---|
| Producido por | Un paso de build, subido una vez | La aplicación, en cada request |
| Varía según | Solo la URL (más `Accept-Encoding`) | Sesión, inquilino, geografía, tiempo |
| Cacheable en el borde | Sí, durante meses | Rara vez; solo con surrogate keys y purga |
| Origen ideal | Bucket de almacenamiento de objetos | Capa de aplicación |
| Cabeceras correctas | `Cache-Control: public, max-age=31536000, immutable` | `Cache-Control: private, no-store` |
| Motor del costo | Egreso (mitigado por el hit ratio del CDN) | CPU e IOPS de base de datos |

El CDN es el único componente de esta lista que simultáneamente mejora la latencia, reduce el costo y aumenta la disponibilidad, y lo hace **solo si el contenido se direcciona de forma inmutable**. Poné una huella en el nombre del archivo (`app.7f3c91a2.js`) y cacheálo para siempre; nunca caches `app.js` para después intentar purgarlo globalmente bajo la presión de un incidente.

```
$ curl -sSI https://cdn.example.com/assets/app.7f3c91a2.js
HTTP/2 200
content-type: application/javascript; charset=utf-8
content-length: 284713
cache-control: public, max-age=31536000, immutable
etag: "7f3c91a2b4e6"
age: 84213
x-cache: HIT
x-cache-hits: 1842
server-timing: cdn-cache;desc=HIT, edge;dur=2

$ curl -sSI https://api.example.com/v1/orders/8812
HTTP/2 200
content-type: application/json
cache-control: private, no-store
x-cache: MISS
server-timing: origin;dur=41
```

`age`, `x-cache` y `server-timing` son las tres cabeceras a revisar primero cuando alguien reporta «el deploy no salió» — un objeto viejo en el borde lo explica muchísimo más seguido que un pipeline roto.

---

## 5. Bases de datos: relacionales y NoSQL

### 5.1 Elegir un modelo de datos

| Familia | Ejemplos | Modelo de datos | Consistencia | Eje de escalado | Transacciones | Mejor encaje | Modo de fallo a prever |
|---|---|---|---|---|---|---|---|
| Relacional (OLTP) | PostgreSQL, MySQL/MariaDB, SQL Server | Tablas, esquema impuesto, joins | Fuerte, serializable disponible | Vertical + réplicas de lectura; el sharding es manual | ACID completo, multi-fila | Cualquier cosa con invariantes entre entidades: dinero, inventario, identidad | Agotamiento de conexiones; retardo de replicación en réplicas de lectura |
| Clave-valor | Redis, Memcached, DynamoDB, etcd | Valor opaco bajo una clave | Redis: fuerte por nodo; DynamoDB: ajustable | Horizontal, trivialmente | Limitadas (Lua, ítem único) | Sesiones, caché, contadores, feature flags | Hot key; crecimiento de memoria sin cota |
| Documental | MongoDB, Couchbase, DocumentDB | Documentos tipo JSON, esquema flexible | Read/write concern ajustables | Horizontal vía shard key | Multi-documento desde MongoDB 4.0 | Agregados que se leen enteros, esquemas en evolución | Shard key equivocada = hotspot permanente |
| Wide-column | Cassandra, ScyllaDB, HBase, Bigtable | Clave de partición + columnas de clustering | Quórum ajustable (`ONE`…`ALL`) | Horizontal, lineal | Solo lightweight transactions | Series temporales, volumen de escritura muy alto | Tombstones; consultas que la clave de partición no soporta |
| Grafo | Neo4j, JanusGraph, Neptune | Nodos y aristas con propiedades | Usualmente fuerte | Mayormente vertical | ACID (Neo4j) | Redes de fraude, permisos, recomendaciones | Supernodos; explosión de recorridos |
| Búsqueda | Elasticsearch, OpenSearch, Solr | Índice invertido, documentos | **Casi en tiempo real, no es sistema de registro** | Horizontal vía shards | Ninguna | Texto completo, analítica de logs, facetas | Usarlo como almacén primario; split-brain en versiones viejas |
| OLAP columnar | ClickHouse, Druid, BigQuery, Redshift | Orientado a columnas, comprimido | Inserciones eventualmente consistentes | Horizontal | Limitadas | Agregaciones sobre miles de millones de filas | Búsquedas puntuales y `UPDATE`s |
| Series temporales | Prometheus, InfluxDB, TimescaleDB, VictoriaMetrics | Serie = métrica + labels, con downsampling | Eventual | Horizontal (federación/sharding) | Ninguna | Métricas, telemetría IoT | Explosión de cardinalidad de labels |

### 5.2 CAP, y la parte que todo el mundo olvida: PACELC

CAP dice que durante una **P**artición de red hay que elegir entre **C**onsistencia y **A**vailability (disponibilidad). Es verdad y es casi inútil para el diseño diario, porque las particiones son raras. **PACELC** es la versión que realmente aplicás:

> **si P**artición entonces (**A**vailability o **C**onsistency) **e**lse (**L**atency o **C**onsistency)

| Sistema | Durante una partición | Operación normal |
|---|---|---|
| PostgreSQL (replicación síncrona) | PC — rechaza escrituras | EC — paga latencia por durabilidad |
| PostgreSQL (replicación asíncrona) | PA — el primario sigue aceptando | EL — las réplicas pueden servir lecturas desactualizadas |
| Cassandra `QUORUM` | PC | EC |
| Cassandra `ONE` | PA | EL |
| DynamoDB (lectura eventualmente consistente) | PA | EL |
| DynamoDB (lectura fuertemente consistente) | PC | EC |
| MongoDB `w:majority` | PC | EC |
| etcd / ZooKeeper (Raft, ZAB) | **PC siempre** — el lado minoritario se detiene | EC |

La rama «else» es con la que convivís el 99,99 % del tiempo. Una réplica de lectura dos segundos atrás del primario no es una partición; es el compromiso cotidiano entre latencia y consistencia, y el bug que produce es *«lo guardé y la página siguiente dice que no existe.»* Se arregla con enrutamiento read-your-writes (mandar las lecturas de una sesión al primario durante N segundos después de una escritura), no volviendo fuertemente consistente cada lectura.

### 5.3 Un clúster PostgreSQL completo, con forma de producción (CloudNativePG)

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: orders-db
  namespace: data
spec:
  instances: 3
  imageName: ghcr.io/cloudnative-pg/postgresql:17.2
  primaryUpdateStrategy: unsupervised
  primaryUpdateMethod: switchover
  enableSuperuserAccess: false

  postgresql:
    parameters:
      max_connections: "200"
      shared_buffers: 4GB
      effective_cache_size: 12GB
      work_mem: 16MB
      maintenance_work_mem: 512MB
      wal_compression: "on"
      max_wal_size: 4GB
      min_wal_size: 1GB
      checkpoint_completion_target: "0.9"
      random_page_cost: "1.1"
      effective_io_concurrency: "200"
      log_min_duration_statement: "500"
      log_checkpoints: "on"
      log_lock_waits: "on"
      log_autovacuum_min_duration: "0"
      shared_preload_libraries: pg_stat_statements
      track_io_timing: "on"
    pg_hba:
      - hostssl orders orders_app 10.42.0.0/16 scram-sha-256
      - hostssl all all 0.0.0.0/0 reject
    synchronous:
      method: any
      number: 1

  bootstrap:
    initdb:
      database: orders
      owner: orders_app
      secret:
        name: orders-db-app-credentials
      encoding: UTF8
      localeCollate: C
      localeCType: C
      postInitApplicationSQL:
        - CREATE EXTENSION IF NOT EXISTS pg_stat_statements
        - CREATE EXTENSION IF NOT EXISTS pgcrypto

  storage:
    size: 200Gi
    storageClass: fast-ssd
  walStorage:
    size: 50Gi
    storageClass: fast-ssd

  resources:
    requests:
      cpu: "2"
      memory: 8Gi
    limits:
      cpu: "4"
      memory: 16Gi

  affinity:
    enablePodAntiAffinity: true
    topologyKey: topology.kubernetes.io/zone
    podAntiAffinityType: required

  monitoring:
    enablePodMonitor: true

  backup:
    retentionPolicy: 35d
    barmanObjectStore:
      destinationPath: "s3://platform-backups/orders-db"
      endpointURL: "https://s3.eu-central-1.amazonaws.com"
      s3Credentials:
        accessKeyId:
          name: backup-object-store
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: backup-object-store
          key: ACCESS_SECRET_KEY
      wal:
        compression: gzip
        maxParallel: 8
      data:
        compression: gzip
        immediateCheckpoint: false
        jobs: 4
---
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: orders-db-nightly
  namespace: data
spec:
  schedule: "0 30 2 * * *"
  backupOwnerReference: self
  cluster:
    name: orders-db
---
apiVersion: postgresql.cnpg.io/v1
kind: Pooler
metadata:
  name: orders-db-rw-pool
  namespace: data
spec:
  cluster:
    name: orders-db
  instances: 3
  type: rw
  pgbouncer:
    poolMode: transaction
    parameters:
      max_client_conn: "2000"
      default_pool_size: "40"
      reserve_pool_size: "10"
      reserve_pool_timeout: "3"
      server_idle_timeout: "120"
```

Fijate en `schedule: "0 30 2 * * *"` — CloudNativePG usa una expresión cron de **seis campos** (los segundos primero). Escribir ahí una expresión de cinco campos es una mala configuración silenciosa clásica: los backups corren a la hora equivocada, o no corren.

Operalo y verificalo:

```
$ kubectl cnpg status orders-db -n data
Cluster Summary
Name:                orders-db
Namespace:           data
System ID:           7412908371445023745
PostgreSQL Image:    ghcr.io/cloudnative-pg/postgresql:17.2
Primary instance:    orders-db-1
Primary start time:  2026-09-11 08:14:02 +0000 UTC (uptime 7d04h)
Status:              Cluster in healthy state
Instances:           3
Ready instances:     3
Current Write LSN:   3F/6A1C4E80 (Timeline: 4 - WAL File: 0000000400000
                     03F00000006A)

Certificates Status
Certificate Name          Expiration Date                Days Left Until Expiration
----------------          ---------------                --------------------------
orders-db-ca              2027-06-08 08:11:41 +0000 UTC  263.00
orders-db-replication     2027-06-08 08:11:41 +0000 UTC  263.00
orders-db-server          2027-06-08 08:11:41 +0000 UTC  263.00

Continuous Backup status
First Point of Recoverability:  2026-08-14T02:31:07Z
Working WAL archiving:          OK
WALs waiting to be archived:    0
Last Archived WAL:              000000040000003F0000006A   @   2026-09-18T09:02:11Z

Streaming Replication status
Name         Sent LSN     Write LSN    Flush LSN    Replay LSN   Write Lag  Flush Lag  Replay Lag  State      Sync State  Sync Priority
----         --------     ---------    ---------    ----------   ---------  ---------  ----------  -----      ----------  -------------
orders-db-2  3F/6A1C4E80  3F/6A1C4E80  3F/6A1C4E80  3F/6A1C4E80  00:00:00   00:00:00   00:00:00    streaming  quorum      1
orders-db-3  3F/6A1C4E80  3F/6A1C4E80  3F/6A1C4E80  3F/6A1C1220  00:00:00   00:00:00   00:00:00.001 streaming  quorum      1

Instances status
Name         Database Size  Current LSN  Replication role  Status  QoS         Manager Version  Node
----         -------------  -----------  ----------------  ------  ---         ---------------  ----
orders-db-1  147 GB         3F/6A1C4E80  Primary           OK      Burstable   1.24.1           node-a-07
orders-db-2  147 GB         3F/6A1C4E80  Standby (sync)    OK      Burstable   1.24.1           node-b-03
orders-db-3  147 GB         3F/6A1C1220  Standby (sync)    OK      Burstable   1.24.1           node-c-11
```

Simulacro deliberado de failover — la única forma de saber que la HA funciona:

```
$ kubectl cnpg promote orders-db orders-db-2 -n data
Node orders-db-2 in cluster orders-db will be promoted

$ kubectl get pods -n data -l cnpg.io/cluster=orders-db -w
NAME          READY   STATUS    RESTARTS   AGE
orders-db-1   1/1     Running   0          7d4h
orders-db-2   1/1     Running   0          7d4h
orders-db-3   1/1     Running   0          7d4h
orders-db-1   0/1     Running   0          7d4h
orders-db-1   1/1     Running   0          7d4h

$ kubectl get endpoints -n data orders-db-rw
NAME           ENDPOINTS           AGE
orders-db-rw   10.42.3.117:5432    7d4h
```

La interrupción de servicio medida en un clúster sano de tres nodos es típicamente de **2–8 segundos** — el tiempo de aislar (fence) al primario viejo, promover el standby y reapuntar el Service `-rw`. Tu aplicación debe reintentar las escrituras idempotentes a lo largo de esa ventana, o la base «HA» igual produce una caída visible para el usuario.

---

## 6. Cachés

### 6.1 Redis versus Memcached

| | Redis (Valkey) | Memcached |
|---|---|---|
| Tipos de datos | Strings, listas, sets, sorted sets, hashes, streams, bitmaps, HyperLogLog, geo | Solo strings |
| Persistencia | Snapshots RDB + AOF | Ninguna |
| Replicación | Primario/réplica asíncrona; sharding con Redis Cluster | Ninguna (sharding del lado del cliente) |
| Threading | Bucle de comandos de un solo hilo (+ hilos de E/S) | Multihilo |
| Tamaño máximo de ítem | 512 MiB | 1 MiB por defecto |
| Desalojo | 8 políticas (`allkeys-lru`, `volatile-ttl`, …) | LRU por clase de slab |
| Modo clúster | Nativo, 16 384 hash slots | Hashing consistente del lado del cliente |
| Scripting / transacciones | Lua, `MULTI`/`EXEC`, funciones | No |
| Pub/Sub, streams, locks | Sí | No |
| Eficiencia de memoria para valores diminutos | Menor (estructuras más ricas) | Mayor (asignador de slabs) |
| Indicado para | Casi todo: caché, cola, rate limiter, leaderboard, almacén de sesiones | Caché LRU pura, enorme y simple, con necesidad de throughput multinúcleo |

Redis es la opción por defecto en 2026; Memcached sigue siendo genuinamente mejor solo para cachés muy grandes y muy simples, donde domina el throughput multihilo por nodo y no se necesita ninguna estructura de datos más allá de `GET`/`SET`.

### 6.2 Patrones de cacheo y sus modos de fallo

| Patrón | Camino de escritura | Camino de lectura | Modo de fallo |
|---|---|---|---|
| Cache-aside (perezoso) | La app escribe en la DB e invalida la clave | Miss → DB → poblar | Estampida al expirar una hot key; ventana de datos viejos entre la escritura y la invalidación |
| Read-through | Igual | La librería de caché carga desde la DB | La misma estampida; esconde errores de la DB detrás de errores de caché |
| Write-through | La app escribe en la caché, la caché escribe en la DB de forma síncrona | Siempre hit | Latencia de escritura = caché + DB; la caché pasa a ser camino crítico |
| Write-behind | La app escribe en la caché, flush asíncrono a la DB | Siempre hit | **Pérdida de datos si falla la caché** — solo para datos tolerables |
| Refresh-ahead | Refresco en segundo plano antes del TTL | Siempre hit | Trabajo desperdiciado en claves frías |

La **estampida de caché** (thundering herd) es el incidente que deberías poder describir de memoria: una clave muy popular expira, diez mil requests concurrentes fallan simultáneamente, los diez mil consultan la base de datos, la base se satura, la latencia trepa, y se apilan más requests. Tres mitigaciones, aplicadas juntas:

1. **TTL con jitter** — `ttl = base + rand(0, base * 0.1)` para que las claves nunca expiren al unísono.
2. **Mutex por clave / single-flight** — el primer miss toma un lock corto (`SET key:lock 1 NX PX 5000`) y rellena; el resto espera un instante o sirve datos viejos.
3. **Servir-viejo-mientras-se-revalida** — mantené un TTL blando dentro del valor; pasado el TTL blando servís el valor viejo y refrescás en segundo plano.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: redis-config
  namespace: data
data:
  redis.conf: |
    bind 0.0.0.0
    protected-mode yes
    port 6379
    maxmemory 6gb
    maxmemory-policy allkeys-lru
    maxmemory-samples 10
    save ""
    appendonly no
    tcp-keepalive 60
    timeout 0
    lazyfree-lazy-eviction yes
    lazyfree-lazy-expire yes
    latency-monitor-threshold 100
    slowlog-log-slower-than 10000
    slowlog-max-len 256
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: redis-cache
  namespace: data
spec:
  serviceName: redis-cache
  replicas: 1
  selector:
    matchLabels:
      app: redis-cache
  template:
    metadata:
      labels:
        app: redis-cache
    spec:
      securityContext:
        fsGroup: 999
        runAsUser: 999
        runAsNonRoot: true
      containers:
        - name: redis
          image: redis:7.4-alpine
          args:
            - /etc/redis/redis.conf
          ports:
            - name: redis
              containerPort: 6379
          resources:
            requests:
              cpu: "1"
              memory: 7Gi
            limits:
              cpu: "2"
              memory: 7Gi
          livenessProbe:
            exec:
              command:
                - sh
                - -c
                - "redis-cli ping | grep -q PONG"
            initialDelaySeconds: 10
            periodSeconds: 10
          readinessProbe:
            exec:
              command:
                - sh
                - -c
                - "redis-cli ping | grep -q PONG"
            periodSeconds: 5
          volumeMounts:
            - name: config
              mountPath: /etc/redis
      volumes:
        - name: config
          configMap:
            name: redis-config
```

`maxmemory 6gb` contra un límite de contenedor de 7 GiB es deliberado: Redis contabiliza su dataset, no el copy-on-write durante `BGSAVE`, ni los búferes de réplica, ni la fragmentación. Poner `maxmemory` igual al límite del cgroup es la forma de conseguir un OOM-kill en lugar de un desalojo.

Sesión de diagnóstico:

```
$ kubectl exec -n data redis-cache-0 -- redis-cli info stats | head -20
# Stats
total_connections_received:184023
total_commands_processed:2914773219
instantaneous_ops_per_sec:41208
total_net_input_bytes:418273401923
total_net_output_bytes:1209374012883
rejected_connections:0
sync_full:0
expired_keys:18402711
evicted_keys:9127334
keyspace_hits:2610338211
keyspace_misses:203114882

$ kubectl exec -n data redis-cache-0 -- redis-cli info memory | grep -E 'used_memory_human|maxmemory_human|mem_fragmentation_ratio'
used_memory_human:5.94G
maxmemory_human:6.00G
mem_fragmentation_ratio:1.31

$ kubectl exec -n data redis-cache-0 -- redis-cli --bigkeys --memkeys -i 0.01
[00.00%] Biggest string found so far '"session:d41d8cd98f00"' with 1284 bytes
[12.41%] Biggest hash   found so far '"cart:9928374"' with 214 fields
[63.02%] Biggest zset   found so far '"leaderboard:global"' with 1840223 members

-------- summary -------
Sampled 8241093 keys in the keyspace!
```

El hit ratio acá es 2610338211 / (2610338211 + 203114882) = **92,8 %**. Que `evicted_keys` crezca de forma sostenida mientras `used_memory` se sienta en `maxmemory` significa que el working set ya no entra — o escalás memoria o acortás TTLs. Un `mem_fragmentation_ratio` por encima de ~1,5 justifica `activedefrag yes`; por debajo de 1,0 significa que Redis está haciendo swap, lo cual es una emergencia.

---

## 7. Colas de mensajes y brokers

### 7.1 La comparación que importa

| | Apache Kafka | RabbitMQ | NATS JetStream | ActiveMQ Artemis | Redis Streams | AWS SQS | ZeroMQ |
|---|---|---|---|---|---|---|---|
| Modelo | **Commit log** distribuido | **Broker** con exchanges + colas | Mensajería por subject + almacén de streams | Broker JMS | Log en memoria/AOF | Cola gestionada | **Librería**, sin broker |
| Consumo | Pull, el consumer group posee particiones | Push (prefetch), consumidores en competencia | Pull o push | Push | Pull (`XREADGROUP`) | Pull (long poll) | Socket directo |
| Mensaje retenido tras la lectura | **Sí** (por tiempo/tamaño) | No (el ack lo elimina) | Sí (configurable) | No | Sí (hasta `XTRIM`) | No | n/a |
| Replay | Nativo (seek a un offset) | Requiere republicar | Nativo | No | Nativo | No | No |
| Orden | Por partición | Por cola (consumidor único) | Por subject/stream | Por cola | Por stream | Solo colas FIFO | n/a |
| Semántica de entrega | At-least-once; exactly-once dentro de Kafka con productor idempotente + transacciones | At-least-once (ack manual) | At-least-once, ventana exactly-once | At-least-once | At-least-once | At-least-once (estándar) / exactly-once (FIFO) | At-most-once por defecto |
| Inteligencia de enrutamiento | **Broker tonto, consumidor listo** | **Broker listo** (direct/topic/fanout/headers) | Comodines de subject | Selectores JMS | Ninguna | Ninguna | n/a |
| Throughput por nodo | Muy alto (100 k–1 M msg/s) | Moderado (20–50 k msg/s) | Muy alto | Moderado | Alto | Gestionado | El más alto (sin broker) |
| Latencia | ms (batching ajustable) | sub-ms posible | **µs–ms** | ms | sub-ms | 10–100 ms | µs |
| Protocolo | Binario propio | AMQP 0-9-1, MQTT, STOMP | Protocolo NATS | AMQP 1.0, MQTT, STOMP, OpenWire | RESP | API HTTPS | TCP/IPC crudo |
| Peso operativo | Alto (KRaft/ZK, rebalanceos, particiones) | Medio | Bajo (un solo binario) | Medio | Bajo | **Cero** | Cero (pero construís todo) |
| Indicado para | Event streaming, agregación de logs, CDC, pipelines reproducibles | Colas de tareas con enrutamiento complejo, RPC, prioridades | Edge/IoT, RPC entre microservicios, baja latencia | Parques Java/JMS | Ya tenés Redis, volumen modesto | Desacople nativo en AWS | Patrones in-process/intra-DC sin necesidad de durabilidad |

**La distinción más importante de esta tabla** es *broker listo / consumidor tonto* (RabbitMQ) versus *broker tonto / consumidor listo* (Kafka). RabbitMQ decide adónde va un mensaje, lleva la cuenta del acknowledgement por mensaje y lo olvida una vez confirmado — excelente para distribuir trabajo. Kafka agrega al final de un log particionado, no recuerda nada sobre los consumidores individuales salvo un offset comprometido, y guarda los datos durante días — excelente para muchos consumidores independientes que leen los mismos eventos a su propio ritmo, y para reproducir la historia después de un bug.

**ZeroMQ no es un broker.** Es una librería de sockets que te da patrones PUB/SUB, REQ/REP, PUSH/PULL y DEALER/ROUTER sin servidor, sin persistencia y sin garantía de entrega. Saber que pertenece a una categoría distinta de los otros seis es exactamente el tipo de distinción que este objetivo evalúa.

### 7.2 Un despliegue de Kafka completo (Strimzi, modo KRaft)

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: controller
  namespace: messaging
  labels:
    strimzi.io/cluster: platform-events
spec:
  replicas: 3
  roles:
    - controller
  storage:
    type: jbod
    volumes:
      - id: 0
        type: persistent-claim
        size: 20Gi
        class: fast-ssd
        deleteClaim: false
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: broker
  namespace: messaging
  labels:
    strimzi.io/cluster: platform-events
spec:
  replicas: 3
  roles:
    - broker
  storage:
    type: jbod
    volumes:
      - id: 0
        type: persistent-claim
        size: 1000Gi
        class: fast-ssd
        deleteClaim: false
  resources:
    requests:
      cpu: "2"
      memory: 16Gi
    limits:
      cpu: "4"
      memory: 16Gi
  jvmOptions:
    -Xms: 6g
    -Xmx: 6g
  template:
    pod:
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              strimzi.io/cluster: platform-events
---
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: platform-events
  namespace: messaging
  annotations:
    strimzi.io/node-pools: enabled
    strimzi.io/kraft: enabled
spec:
  kafka:
    version: 3.9.0
    metadataVersion: "3.9-IV0"
    listeners:
      - name: tls
        port: 9093
        type: internal
        tls: true
        authentication:
          type: tls
      - name: external
        port: 9094
        type: loadbalancer
        tls: true
        authentication:
          type: scram-sha-512
        configuration:
          bootstrap:
            annotations:
              external-dns.alpha.kubernetes.io/hostname: kafka.example.com
    authorization:
      type: simple
      superUsers:
        - CN=platform-admin
    config:
      default.replication.factor: 3
      min.insync.replicas: 2
      offsets.topic.replication.factor: 3
      transaction.state.log.replication.factor: 3
      transaction.state.log.min.isr: 2
      auto.create.topics.enable: false
      unclean.leader.election.enable: false
      log.retention.hours: 168
      log.segment.bytes: 1073741824
      num.replica.fetchers: 4
      replica.lag.time.max.ms: 30000
      compression.type: producer
    metricsConfig:
      type: jmxPrometheusExporter
      valueFrom:
        configMapKeyRef:
          name: kafka-metrics
          key: kafka-metrics-config.yml
  entityOperator:
    topicOperator: {}
    userOperator: {}
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: orders.created.v1
  namespace: messaging
  labels:
    strimzi.io/cluster: platform-events
spec:
  partitions: 12
  replicas: 3
  config:
    retention.ms: "604800000"
    segment.bytes: "1073741824"
    min.insync.replicas: "2"
    cleanup.policy: delete
    max.message.bytes: "1048576"
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: customers.state.v1
  namespace: messaging
  labels:
    strimzi.io/cluster: platform-events
spec:
  partitions: 12
  replicas: 3
  config:
    cleanup.policy: compact
    min.cleanable.dirty.ratio: "0.1"
    delete.retention.ms: "86400000"
    min.insync.replicas: "2"
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaUser
metadata:
  name: orders-service
  namespace: messaging
  labels:
    strimzi.io/cluster: platform-events
spec:
  authentication:
    type: scram-sha-512
  authorization:
    type: simple
    acls:
      - resource:
          type: topic
          name: orders.created.v1
          patternType: literal
        operations:
          - Describe
          - Write
        host: "*"
      - resource:
          type: group
          name: orders-consumer
          patternType: prefix
        operations:
          - Read
        host: "*"
```

Fijate en `host: "*"` — entre comillas, porque un `*` sin comillas es un token de alias de YAML y el documento no parsearía.

Los dos valores de `cleanup.policy` codifican una distinción arquitectónica real: `delete` para **flujos de eventos** (hechos que ocurrieron, retenidos durante una ventana), `compact` para **topics de estado** (el último valor por clave, retenido para siempre). Un topic compactado es un almacén clave-valor distribuido y reproducible — el fundamento del patrón «la base de datos dada vuelta» y de los state stores de Kafka Streams.

Verificación y diagnóstico de lag:

```
$ kubectl -n messaging exec -it platform-events-broker-0 -- bin/kafka-topics.sh \
    --bootstrap-server localhost:9092 --describe --topic orders.created.v1
Topic: orders.created.v1  TopicId: 8Kx2mQ1nTx-PqW0dRf7ZxA  PartitionCount: 12  ReplicationFactor: 3  Configs: min.insync.replicas=2,segment.bytes=1073741824,retention.ms=604800000,cleanup.policy=delete
    Topic: orders.created.v1  Partition: 0  Leader: 3  Replicas: 3,4,5  Isr: 3,4,5  Elr:   LastKnownElr:
    Topic: orders.created.v1  Partition: 1  Leader: 4  Replicas: 4,5,3  Isr: 4,5,3  Elr:   LastKnownElr:
    Topic: orders.created.v1  Partition: 2  Leader: 5  Replicas: 5,3,4  Isr: 5,3      Elr:   LastKnownElr:
    ...

$ kubectl -n messaging exec -it platform-events-broker-0 -- bin/kafka-consumer-groups.sh \
    --bootstrap-server localhost:9092 --describe --group orders-consumer

GROUP            TOPIC              PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG      CONSUMER-ID                                     HOST           CLIENT-ID
orders-consumer  orders.created.v1  0          48210394        48210401        7        consumer-orders-1-9a1c...-0  /10.42.2.31    consumer-orders-1
orders-consumer  orders.created.v1  1          48198221        48198230        9        consumer-orders-2-4f70...-0  /10.42.3.19    consumer-orders-2
orders-consumer  orders.created.v1  2          47110882        48203994        1093112  consumer-orders-3-1b2e...-0  /10.42.1.44    consumer-orders-3
orders-consumer  orders.created.v1  3          48204118        48204118        0        consumer-orders-4-7c93...-0  /10.42.2.88    consumer-orders-4
...
```

Dos hallazgos en una sola pantalla:

- **La partición 2 tiene `Isr: 5,3` mientras que `Replicas: 5,3,4`** — el broker 4 se cayó del conjunto de réplicas en sincronía. Con `min.insync.replicas=2` la partición todavía acepta escrituras con `acks=all`, pero ahora está a un fallo de rechazar todas las escrituras. Este es el estado sobre el que hay que alertar, *antes* de que se convierta en una caída.
- **La partición 2 tiene 1 093 112 mensajes de lag mientras sus hermanas tienen dígitos sueltos** — el lag concentrado en una partición nunca es «los consumidores son lentos». Es una **partición caliente** causada por una clave de partición sesgada (por ejemplo, el ID de un inquilino grande que hashea a la partición 2), o un mensaje envenenado en el que el consumidor falla una y otra vez y vuelve a leer. Un lag parejo en todas las particiones es un problema de capacidad; un lag sesgado es un problema de claves, y agregar consumidores no lo va a arreglar — un consumer group no puede tener más consumidores activos que particiones.

### 7.3 RabbitMQ: quorum queues, DLX y la vista operativa

```yaml
apiVersion: rabbitmq.com/v1beta1
kind: RabbitmqCluster
metadata:
  name: tasks
  namespace: messaging
spec:
  replicas: 3
  image: rabbitmq:4.0-management
  resources:
    requests:
      cpu: "1"
      memory: 4Gi
    limits:
      cpu: "2"
      memory: 4Gi
  persistence:
    storageClassName: fast-ssd
    storage: 100Gi
  rabbitmq:
    additionalConfig: |
      cluster_partition_handling = pause_minority
      vm_memory_high_watermark.relative = 0.6
      disk_free_limit.absolute = 10GB
      channel_max = 512
      management.rates_mode = basic
    additionalPlugins:
      - rabbitmq_prometheus
      - rabbitmq_shovel
  override:
    statefulSet:
      spec:
        template:
          spec:
            topologySpreadConstraints:
              - maxSkew: 1
                topologyKey: topology.kubernetes.io/zone
                whenUnsatisfiable: DoNotSchedule
                labelSelector:
                  matchLabels:
                    app.kubernetes.io/name: tasks
---
apiVersion: rabbitmq.com/v1beta1
kind: Queue
metadata:
  name: invoices-work
  namespace: messaging
spec:
  name: invoices.work
  vhost: "/"
  type: quorum
  durable: true
  rabbitmqClusterReference:
    name: tasks
  arguments:
    x-queue-type: quorum
    x-delivery-limit: 5
    x-dead-letter-exchange: invoices.dlx
    x-dead-letter-routing-key: invoices.failed
---
apiVersion: rabbitmq.com/v1beta1
kind: Queue
metadata:
  name: invoices-dead
  namespace: messaging
spec:
  name: invoices.dead
  vhost: "/"
  type: quorum
  durable: true
  rabbitmqClusterReference:
    name: tasks
---
apiVersion: rabbitmq.com/v1beta1
kind: Exchange
metadata:
  name: invoices-dlx
  namespace: messaging
spec:
  name: invoices.dlx
  vhost: "/"
  type: direct
  durable: true
  rabbitmqClusterReference:
    name: tasks
---
apiVersion: rabbitmq.com/v1beta1
kind: Binding
metadata:
  name: invoices-dead-binding
  namespace: messaging
spec:
  vhost: "/"
  source: invoices.dlx
  destination: invoices.dead
  destinationType: queue
  routingKey: invoices.failed
  rabbitmqClusterReference:
    name: tasks
```

`x-delivery-limit: 5` más un dead-letter exchange es el **cortacircuitos de mensajes envenenados**. Sin eso, un mensaje que el consumidor no puede procesar se reentrega para siempre, quemando CPU y bloqueando la cola — una caída de producción genuina causada por un solo payload malformado.

```
$ kubectl exec -n messaging tasks-server-0 -- rabbitmqctl list_queues \
    name type messages messages_ready messages_unacknowledged consumers memory
Timeout: 60.0 seconds ...
Listing queues for vhost / ...
name             type    messages  messages_ready  messages_unacknowledged  consumers  memory
invoices.work    quorum  18432     18420           12                       6          78123456
invoices.dead    quorum  41        41              0                        0          212992
notifications    quorum  0         0               0                        12         98304

$ kubectl exec -n messaging tasks-server-0 -- rabbitmqctl cluster_status
Cluster status of node rabbit@tasks-server-0.tasks-nodes.messaging ...
Basics
Cluster name: tasks

Disk Nodes
rabbit@tasks-server-0.tasks-nodes.messaging
rabbit@tasks-server-1.tasks-nodes.messaging
rabbit@tasks-server-2.tasks-nodes.messaging

Running Nodes
rabbit@tasks-server-0.tasks-nodes.messaging
rabbit@tasks-server-1.tasks-nodes.messaging
rabbit@tasks-server-2.tasks-nodes.messaging

Feature flags
Flag: quorum_queue, state: enabled
Flag: stream_queue, state: enabled
Flag: message_containers, state: enabled
```

Que `messages_ready` trepe con `consumers` distinto de cero significa que los consumidores son demasiado lentos o que el `prefetch` es demasiado bajo. Un `messages_unacknowledged` grande y estático significa que los consumidores tomaron mensajes y dejaron de confirmarlos — buscá un deadlock o una llamada de E/S bloqueada en el handler. Una `invoices.dead` que crece es tu señal de mensajes envenenados y debería tener alerta: es silenciosa por construcción.

### 7.4 Elegir la semántica de entrega deliberadamente

| Garantía | Cómo se logra | Costo | Cuándo corresponde |
|---|---|---|---|
| At-most-once | Auto-ack / disparar y olvidar | Lo más barato, la menor latencia | Métricas, muestras de telemetría, cualquier cosa donde la pérdida sea invisible |
| At-least-once | Ack manual tras procesar; reintentos del productor | Los duplicados **van a ocurrir** | El valor por defecto para casi todos los eventos de negocio |
| Effectively-once | At-least-once + consumidor idempotente (clave de deduplicación, upsert, tabla de idempotencia) | Una consulta extra al almacén por mensaje | Pagos, pedidos, cualquier cosa con un efecto lateral con forma de dinero |
| Exactly-once (nativo del broker) | Productor idempotente de Kafka + transacciones, aislamiento read-committed | ~10–20 % del throughput, acoplamiento al broker | Solo procesamiento de streams Kafka-a-Kafka |

La regla práctica: **asumí at-least-once y hacé que el consumidor sea idempotente.** El «exactly-once» entre un broker y un sistema externo (una base de datos, una pasarela de pagos, un proveedor de email) no existe sin una transacción distribuida que el sistema externo casi con certeza no ofrece. Una clave de idempotencia almacenada junto a la escritura de negocio es el diseño que realmente aguanta.

---

## 8. Plataformas de big data y analítica

| Motor | Paradigma | Clase de latencia | Almacenamiento que lee | Unidad de escalado | Indicado para | Modo de fallo |
|---|---|---|---|---|---|---|
| Hadoop MapReduce | Batch, limitado por disco | Minutos–horas | HDFS | Nodo | ETL legacy; ampliamente superado | Problema de archivos pequeños en el NameNode de HDFS |
| Apache Spark | Batch + micro-batch, DAG en memoria | Segundos–horas | HDFS, S3, JDBC, Delta/Iceberg | Executor | ETL general, pipelines de ML, joins grandes | OOM de executor por sesgo de datos; spill de shuffle |
| Apache Flink | Streaming real, event time, con estado | Milisegundos | Kafka, S3 | Task slot | Procesamiento continuo, agregación por ventanas, CEP | Crecimiento del checkpoint/backend de estado |
| Trino / Presto | SQL MPP distribuido, federado | Segundos | S3, Hive, Iceberg, RDBMS | Worker | SQL ad-hoc interactivo entre fuentes | Memoria del coordinador; consultas sin cota |
| Elasticsearch / OpenSearch | Índice invertido, casi en tiempo real | Milisegundos | Shards propios | Nodo de datos | Texto completo, búsqueda de logs, observabilidad | Explosión de shards; explosión de mapeos de campos; **no es sistema de registro** |
| ClickHouse | OLAP columnar, vectorizado | Milisegundos–segundos | MergeTree propio, S3 | Shard/réplica | Analítica de alta cardinalidad, métricas de producto | Demasiados `INSERT`s pequeños → tormenta de merges |
| Apache Druid | OLAP columnar en tiempo real | Sub-segundo | Deep storage + segmentos | Historical/MiddleManager | Dashboards por rebanadas de tiempo | Complejidad operativa |

### 8.1 Batch versus streaming, arquitectónicamente

| | Arquitectura Lambda | Arquitectura Kappa |
|---|---|---|
| Caminos | Dos: batch (exacto) + speed (rápido) | Uno: solo stream |
| Reprocesamiento | Volver a correr el job batch | Reproducir el log desde el offset 0 |
| Duplicación de código | **Sí** — dos implementaciones de la misma lógica | No |
| Reconciliación de correctitud | La capa batch pisa a la capa speed | Fuente única de verdad |
| Prerrequisito | Ninguno | Un log durable y reproducible (Kafka con retención larga) |
| Carga operativa | Alta | Moderada |

Kappa es el valor por defecto moderno precisamente porque un topic de Kafka con 30 días de retención convierte «reprocesar todo con el código corregido» en un replay en lugar de en una segunda base de código.

### 8.2 Spark sobre Kubernetes

```
$ spark-submit \
    --master k8s://https://k8s-api.internal.example.com:6443 \
    --deploy-mode cluster \
    --name orders-daily-rollup \
    --class com.example.analytics.OrdersRollup \
    --conf spark.kubernetes.namespace=analytics \
    --conf spark.kubernetes.container.image=registry.internal.example.com/analytics/spark:3.5.4 \
    --conf spark.kubernetes.authenticate.driver.serviceAccountName=spark \
    --conf spark.executor.instances=20 \
    --conf spark.executor.cores=4 \
    --conf spark.executor.memory=12g \
    --conf spark.executor.memoryOverhead=2g \
    --conf spark.driver.memory=4g \
    --conf spark.sql.shuffle.partitions=400 \
    --conf spark.sql.adaptive.enabled=true \
    --conf spark.sql.adaptive.skewJoin.enabled=true \
    --conf spark.hadoop.fs.s3a.endpoint=s3.eu-central-1.amazonaws.com \
    --conf spark.hadoop.fs.s3a.aws.credentials.provider=com.amazonaws.auth.WebIdentityTokenCredentialsProvider \
    --conf spark.kubernetes.executor.deleteOnTermination=true \
    s3a://platform-artifacts/analytics/orders-rollup-2.1.0.jar \
    --date 2026-09-17

26/09/18 09:41:02 INFO SparkKubernetesClientFactory: Auto-configuring K8S client using current context
26/09/18 09:41:04 INFO KubernetesClientUtils: Spark configuration files loaded from Some(/opt/spark/conf)
26/09/18 09:41:06 INFO LoggingPodStatusWatcherImpl: State changed, new state:
     pod name: orders-daily-rollup-b41f7c93f2a10d84-driver
     namespace: analytics
     phase: Pending
26/09/18 09:41:19 INFO LoggingPodStatusWatcherImpl: State changed, new state:
     phase: Running
26/09/18 09:48:37 INFO LoggingPodStatusWatcherImpl: Container final statuses:
     container name: spark-kubernetes-driver
     exit code: 0
26/09/18 09:48:37 INFO LoggingPodStatusWatcherImpl: Application orders-daily-rollup finished.
```

`spark.sql.adaptive.skewJoin.enabled=true` es el ajuste que convierte la mayoría de los incidentes de «un executor corre tres horas mientras diecinueve están ociosos» en una corrida normal. El sesgo de datos es el modo de fallo dominante en Spark, y AQE parte las particiones sobredimensionadas en tiempo de ejecución.

---

## 9. Runtimes de aplicación y Plataforma como Servicio

### 9.1 Comparación de PaaS

| | Cloud Foundry | OpenShift | Heroku | Knative | Dokku |
|---|---|---|---|---|---|
| Unidad de despliegue | Fuente o droplet (`cf push`) | Fuente (S2I), Dockerfile, imagen | Fuente (git push) | Imagen de contenedor | Fuente (git push) |
| Mecanismo de build | Buildpacks | S2I / Dockerfile / Cloud Native Buildpacks | Buildpacks | Externo (lo construís vos) | Buildpacks |
| Orquestador subyacente | Diego, o Kubernetes (Korifi) | Kubernetes | Gestor de dynos | Kubernetes | Docker en un solo host |
| Servicios de respaldo | Service broker (API OSB) | Operadores / Service Binding | Marketplace de add-ons | Los ponés vos | Plugins |
| Enrutamiento | Gorouter | Router (HAProxy) / Gateway API | Router | Kourier / Istio / Contour | nginx |
| Escalar a cero | No | No (add-on Serverless: sí) | Los eco dynos duermen | **Sí** | No |
| Multi-tenencia | Orgs / spaces | Proyectos + SCC | Equipos | Namespaces | Ninguna |
| Autohospedable | Sí | Sí | No | Sí | Sí |
| Indicado para | Grandes empresas con un mandato 12-factor | Empresas ya sobre Kubernetes que necesitan autoservicio para desarrolladores | Equipos chicos, el camino más rápido a producción | Cargas orientadas a eventos sobre un Kubernetes existente | Un solo host, proyectos personales |

### 9.2 Cloud Foundry: la interacción canónica con un PaaS

```yaml
---
applications:
  - name: orders-api
    memory: 1G
    disk_quota: 1G
    instances: 4
    stack: cflinuxfs4
    buildpacks:
      - java_buildpack_offline
    path: build/libs/orders-api-2.4.1.jar
    health-check-type: http
    health-check-http-endpoint: /actuator/health/readiness
    health-check-invocation-timeout: 5
    timeout: 120
    routes:
      - route: orders.apps.example.com
      - route: orders-internal.apps.internal
    services:
      - orders-postgres
      - orders-redis
      - orders-kafka
    env:
      SPRING_PROFILES_ACTIVE: production
      JAVA_OPTS: "-XX:MaxRAMPercentage=75"
      JBP_CONFIG_OPEN_JDK_JRE: "{ jre: { version: 21.+ } }"
      OTEL_SERVICE_NAME: orders-api
```

`JBP_CONFIG_OPEN_JDK_JRE` debe ir entre comillas: un valor sin comillas que empieza con `{` es interpretado por YAML como un mapeo de flujo, y el buildpack recibiría un mapa renderizado en lugar del string literal que espera.

```
$ cf push -f manifest.yml
Pushing app orders-api to org platform / space production as ci@example.com...
Applying manifest file /workspace/manifest.yml...
Uploading files...
 3.41 MiB / 3.41 MiB [=========================================] 100.00% 2s

Staging app and tracing logs...
   Downloading java_buildpack_offline...
   Downloaded java_buildpack_offline (242.1M)
   Cell 6b8a2f1c creating container for instance 0f3a...
   Downloading build artifacts cache...
   -----> Java Buildpack v4.68 | https://github.com/cloudfoundry/java-buildpack.git
   -----> Downloading Jvmkill Agent 1.17.0 from https://java-buildpack.cloudfoundry.org/...
   -----> Downloading Open Jdk JRE 21.0.5_11 from https://java-buildpack.cloudfoundry.org/...
          Expanding Open Jdk JRE to .java-buildpack/open_jdk_jre (1.4s)
   -----> Downloading Spring Auto Reconfiguration 2.15.0 ...
          Uploading droplet (118.2M)

Waiting for app orders-api to start...

name:              orders-api
requested state:   started
routes:            orders.apps.example.com, orders-internal.apps.internal
last uploaded:     Thu 18 Sep 09:52:14 UTC 2026
stack:             cflinuxfs4
buildpacks:        java_buildpack_offline

type:            web
sidecars:
instances:       4/4
memory usage:    1024M
     state     since                  cpu    memory         disk           logging
#0   running   2026-09-18T09:53:02Z   3.1%   412.9M of 1G   198.4M of 1G   0/s of unlimited
#1   running   2026-09-18T09:53:04Z   2.8%   408.1M of 1G   198.4M of 1G   0/s of unlimited
#2   running   2026-09-18T09:53:07Z   3.4%   417.2M of 1G   198.4M of 1G   0/s of unlimited
#3   running   2026-09-18T09:53:09Z   2.9%   404.6M of 1G   198.4M of 1G   0/s of unlimited

$ cf env orders-api | head -30
Getting env variables for app orders-api in org platform / space production...

System-Provided:
VCAP_SERVICES
{
  "postgresql": [
    {
      "label": "postgresql",
      "name": "orders-postgres",
      "plan": "ha-200",
      "credentials": {
        "host": "pg-7841.service.internal",
        "port": 5432,
        "database": "orders",
        "username": "u_a91f",
        "uri": "postgresql://u_a91f:REDACTED@pg-7841.service.internal:5432/orders"
      }
    }
  ]
}
```

`VCAP_SERVICES` es la implementación concreta de los **factores III (configuración en el entorno) y IV (servicios de respaldo como recursos adjuntos) de los doce factores**. La aplicación nunca hardcodea un host de base de datos; lee el binding que la plataforma le inyectó. El equivalente en Kubernetes es un `Secret` proyectado como variables de entorno o como archivo, producido por un Service Binding o por un operador — el mismo contrato, distinto mecanismo.

### 9.3 Buildpacks versus Dockerfiles

| | Cloud Native Buildpacks | Dockerfile |
|---|---|---|
| Entrada | Código fuente | Instrucciones explícitas |
| Actualización de la imagen base | **Rebase sin reconstruir** (`pack rebase`) | Requiere rebuild completo |
| Parcheo de seguridad a escala | Una actualización del builder rebasa miles de apps | Hay que tocar cada repositorio |
| Reproducibilidad | Alta (builder fijo, SBOM emitido) | Depende enteramente de la disciplina |
| Flexibilidad | Limitada a los lenguajes detectados | Total |
| Optimización de capas | Automática (dependencias vs. código de la app) | Manual |
| Indicado para | Muchos servicios parecidos, equipo de plataforma central | Runtimes inusuales, paquetes de sistema, control preciso |

```
$ pack build registry.internal.example.com/billing/orders-api:2.4.1 \
    --builder paketobuildpacks/builder-jammy-base \
    --env BP_JVM_VERSION=21 \
    --publish
jammy-base: Pulling from paketobuildpacks/builder-jammy-base
Digest: sha256:fd1e9a2c8b4737f0e51c2a9d8c4e71b03fa62d5c9e1a7b48d0a3f2c65e91b774
===> DETECTING
5 of 18 buildpacks participating
paketo-buildpacks/ca-certificates   3.8.5
paketo-buildpacks/bellsoft-liberica 10.7.2
paketo-buildpacks/syft              1.45.0
paketo-buildpacks/gradle            7.6.1
paketo-buildpacks/spring-boot       5.29.1
===> BUILDING
Paketo Buildpack for BellSoft Liberica 10.7.2
  https://github.com/paketo-buildpacks/bellsoft-liberica
  Build Configuration:
    $BP_JVM_VERSION 21  the Java version
  Launch Configuration:
    $BPL_JVM_HEAD_ROOM  0   the headroom in memory calculation
===> EXPORTING
Adding layer 'paketo-buildpacks/ca-certificates:helper'
Adding layer 'paketo-buildpacks/bellsoft-liberica:helper'
Adding 1/1 app layer(s)
Adding layer 'launcher'
Adding layer 'config'
Adding label 'io.buildpacks.lifecycle.metadata'
Adding label 'io.buildpacks.project.metadata'
Setting default process type 'web'
Saving registry.internal.example.com/billing/orders-api:2.4.1...
*** Images (sha256:3b7f0d91ac):
      registry.internal.example.com/billing/orders-api:2.4.1
Successfully built image registry.internal.example.com/billing/orders-api:2.4.1

$ pack rebase registry.internal.example.com/billing/orders-api:2.4.1 --publish
Rebasing registry.internal.example.com/billing/orders-api:2.4.1 on run image paketobuildpacks/run-jammy-base
Saving registry.internal.example.com/billing/orders-api:2.4.1...
*** Images (sha256:91c4e7fa02):
      registry.internal.example.com/billing/orders-api:2.4.1
Rebased Image: sha256:91c4e7fa02...
```

`pack rebase` terminó en unos dos segundos y no volvió a correr el build: intercambió las capas del sistema operativo por debajo de las capas de aplicación, que no cambiaron. Parchear un CVE de la imagen base en 400 servicios pasa a ser un bucle sobre 400 rebases en vez de 400 pipelines de CI — el argumento más fuerte a favor de los buildpacks a escala de plataforma.

---

## 10. OpenStack: el IaaS de código abierto de referencia

OpenStack importa para este objetivo porque es la descomposición canónica de «una nube» en servicios con nombre y APIs documentadas. Aprendé el mapa de componentes y vas a poder razonar sobre cualquier nube, porque todo proveedor tiene las mismas piezas bajo otras marcas.

| Proyecto | Rol | Servicio AWS análogo | Concepto clave a conocer |
|---|---|---|---|
| **Keystone** | Identidad, authN/authZ, catálogo de servicios | IAM + STS | Todos los demás servicios buscan sus endpoints acá; emite tokens con alcance |
| **Nova** | Cómputo — ciclo de vida de VMs | EC2 | El scheduler ubica instancias en nodos de cómputo según flavor + filtros |
| **Neutron** | Redes — SDN, L2/L3, security groups, FIPs | VPC | Drivers ML2 enchufables (OVS, OVN, Linux bridge) |
| **Glance** | Registro de imágenes | Catálogo de AMIs | Las imágenes son la entrada inmutable de Nova |
| **Cinder** | Almacenamiento de bloques | EBS | Los volúmenes se adjuntan a una instancia; snapshots |
| **Swift** | Almacenamiento de objetos | S3 | Eventualmente consistente, basado en ring, API propia (+ middleware S3) |
| **Placement** | Inventario y asignación de recursos | — | Nova le pregunta qué host tiene VCPU/MEMORY_MB/DISK_GB libres |
| **Heat** | Orquestación — stacks declarativos | CloudFormation | Plantillas HOT; el punto de entrada a IaC |
| **Horizon** | Dashboard web | Consola | Cliente delgado sobre las mismas APIs |
| **Ironic** | Aprovisionamiento bare-metal | Instancias Bare Metal | Nova puede planificar sobre hosts físicos |
| **Octavia** | Balanceo de carga como servicio | ELB/NLB | VMs Amphora corriendo HAProxy |
| **Designate** | DNS como servicio | Route 53 | Registros creados junto con las instancias |
| **Barbican** | Gestión de claves y secretos | KMS / Secrets Manager | Respalda el cifrado de Cinder/Octavia |
| **Magnum** | Aprovisionamiento de motores de orquestación de contenedores | EKS | Crea clústeres Kubernetes sobre Nova/Heat |
| **Manila** | Sistemas de archivos compartidos | EFS | Compartidos NFS/CIFS |
| **Ceilometer / Gnocchi / Aodh** | Telemetría, almacenamiento de métricas, alarmas | CloudWatch | Alimenta el autoescalado |

### 10.1 Una plantilla Heat Orchestration completa

```yaml
heat_template_version: 2021-04-16

description: >
  Two-tier reference stack for the orders platform: a private tenant network
  routed to the external provider network, a security group per tier, an
  autoscaled application tier behind an Octavia load balancer, and a Cinder
  volume for the application's local cache.

parameters:
  image:
    type: string
    label: Glance image
    default: ubuntu-24.04-server-cloudimg-amd64
    constraints:
      - custom_constraint: glance.image
  flavor:
    type: string
    label: Nova flavor
    default: m1.large
    constraints:
      - custom_constraint: nova.flavor
  key_name:
    type: string
    label: SSH keypair name
    default: platform-ops
  external_network:
    type: string
    label: Provider network for floating IPs
    default: public
  app_image_ref:
    type: string
    label: OCI image reference deployed on each instance
    default: "registry.example.com/billing/orders-api:2.4.1"
  min_instances:
    type: number
    default: 2
  max_instances:
    type: number
    default: 8

resources:

  app_network:
    type: OS::Neutron::Net
    properties:
      name: orders-app-net

  app_subnet:
    type: OS::Neutron::Subnet
    properties:
      name: orders-app-subnet
      network:
        get_resource: app_network
      cidr: 10.30.10.0/24
      gateway_ip: 10.30.10.1
      enable_dhcp: true
      dns_nameservers:
        - 10.30.0.10
        - 10.30.0.11
      allocation_pools:
        - start: 10.30.10.50
          end: 10.30.10.250

  app_router:
    type: OS::Neutron::Router
    properties:
      name: orders-app-router
      external_gateway_info:
        network:
          get_param: external_network

  app_router_interface:
    type: OS::Neutron::RouterInterface
    properties:
      router:
        get_resource: app_router
      subnet:
        get_resource: app_subnet

  app_security_group:
    type: OS::Neutron::SecurityGroup
    properties:
      name: orders-app-sg
      description: Application tier - HTTP from the load balancer, SSH from bastion
      rules:
        - protocol: tcp
          port_range_min: 8080
          port_range_max: 8080
          remote_ip_prefix: 10.30.10.0/24
        - protocol: tcp
          port_range_min: 22
          port_range_max: 22
          remote_ip_prefix: 10.30.0.0/24
        - protocol: icmp
          remote_ip_prefix: 10.30.0.0/16

  app_cache_volume:
    type: OS::Cinder::Volume
    properties:
      name: orders-app-cache
      size: 50
      volume_type: ssd

  app_server:
    type: OS::Nova::Server
    properties:
      name: orders-app-01
      image:
        get_param: image
      flavor:
        get_param: flavor
      key_name:
        get_param: key_name
      security_groups:
        - get_resource: app_security_group
      networks:
        - subnet:
            get_resource: app_subnet
      metadata:
        stack_id:
          get_param: "OS::stack_id"
        tier: application
      user_data_format: RAW
      user_data:
        str_replace:
          template: |
            #!/bin/bash
            set -euo pipefail
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y podman
            mkdir -p /var/cache/orders
            systemctl enable --now podman.socket
            podman run -d --name orders-api --restart=always \
              --publish 8080:8080 \
              --volume /var/cache/orders:/cache:Z \
              --env SPRING_PROFILES_ACTIVE=production \
              $APP_IMAGE
          params:
            $APP_IMAGE:
              get_param: app_image_ref

  app_volume_attachment:
    type: OS::Cinder::VolumeAttachment
    properties:
      volume_id:
        get_resource: app_cache_volume
      instance_uuid:
        get_resource: app_server
      mountpoint: /dev/vdb

  app_floating_ip:
    type: OS::Neutron::FloatingIP
    properties:
      floating_network:
        get_param: external_network

  app_floating_ip_association:
    type: OS::Nova::FloatingIPAssociation
    properties:
      floating_ip:
        get_resource: app_floating_ip
      server_id:
        get_resource: app_server

  app_loadbalancer:
    type: OS::Octavia::LoadBalancer
    properties:
      name: orders-lb
      vip_subnet:
        get_resource: app_subnet

  app_listener:
    type: OS::Octavia::Listener
    properties:
      name: orders-lb-http
      loadbalancer:
        get_resource: app_loadbalancer
      protocol: HTTP
      protocol_port: 80

  app_pool:
    type: OS::Octavia::Pool
    properties:
      name: orders-lb-pool
      listener:
        get_resource: app_listener
      protocol: HTTP
      lb_algorithm: LEAST_CONNECTIONS
      session_persistence:
        type: APP_COOKIE
        cookie_name: ORDERSSESSION

  app_health_monitor:
    type: OS::Octavia::HealthMonitor
    properties:
      pool:
        get_resource: app_pool
      type: HTTP
      url_path: /healthz
      expected_codes: "200"
      delay: 5
      timeout: 3
      max_retries: 3

outputs:
  load_balancer_vip:
    description: VIP address of the Octavia load balancer
    value:
      get_attr:
        - app_loadbalancer
        - vip_address
  app_public_ip:
    description: Floating IP attached to the first application instance
    value:
      get_attr:
        - app_floating_ip
        - floating_ip_address
  app_private_ip:
    description: Fixed IP of the first application instance
    value:
      get_attr:
        - app_server
        - first_address
```

Desplegar e inspeccionar:

```
$ openstack stack create -t orders-stack.yaml \
    --parameter flavor=m1.xlarge \
    --parameter app_image_ref=registry.example.com/billing/orders-api:2.4.1 \
    --wait orders-production
2026-09-18 10:04:11Z [orders-production]: CREATE_IN_PROGRESS  Stack CREATE started
2026-09-18 10:04:13Z [orders-production.app_network]: CREATE_IN_PROGRESS  state changed
2026-09-18 10:04:16Z [orders-production.app_network]: CREATE_COMPLETE  state changed
2026-09-18 10:04:17Z [orders-production.app_subnet]: CREATE_IN_PROGRESS  state changed
2026-09-18 10:04:21Z [orders-production.app_subnet]: CREATE_COMPLETE  state changed
2026-09-18 10:04:22Z [orders-production.app_router]: CREATE_IN_PROGRESS  state changed
2026-09-18 10:04:39Z [orders-production.app_router]: CREATE_COMPLETE  state changed
2026-09-18 10:05:02Z [orders-production.app_server]: CREATE_IN_PROGRESS  state changed
2026-09-18 10:06:48Z [orders-production.app_server]: CREATE_COMPLETE  state changed
2026-09-18 10:08:31Z [orders-production.app_loadbalancer]: CREATE_COMPLETE  state changed
2026-09-18 10:08:55Z [orders-production]: CREATE_COMPLETE  Stack CREATE completed successfully

+---------------------+--------------------------------------+
| Field               | Value                                |
+---------------------+--------------------------------------+
| id                  | 4d81b2f0-5a1e-49c7-9f2b-7a3e1c084b62 |
| stack_name          | orders-production                    |
| stack_status        | CREATE_COMPLETE                      |
| creation_time       | 2026-09-18T10:04:11Z                 |
+---------------------+--------------------------------------+

$ openstack stack output show orders-production --all
+---------------------+------------------------------------------------------------+
| Field               | Value                                                      |
+---------------------+------------------------------------------------------------+
| load_balancer_vip   | 10.30.10.72                                                |
| app_public_ip       | 203.0.113.184                                              |
| app_private_ip      | 10.30.10.113                                               |
+---------------------+------------------------------------------------------------+

$ openstack service list
+----------------------------------+------------+----------------+
| ID                               | Name       | Type           |
+----------------------------------+------------+----------------+
| 0a1f3c5e7b9d2f4a6c8e0b2d4f6a8c0e | keystone   | identity       |
| 1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e | nova       | compute        |
| 2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f | neutron    | network        |
| 3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f80 | glance     | image          |
| 4e5f6a7b8c9d0e1f2a3b4c5d6e7f8091 | cinderv3   | block-storage  |
| 5f6a7b8c9d0e1f2a3b4c5d6e7f8091a2 | swift      | object-store   |
| 6a7b8c9d0e1f2a3b4c5d6e7f8091a2b3 | heat       | orchestration  |
| 7b8c9d0e1f2a3b4c5d6e7f8091a2b3c4 | placement  | placement      |
| 8c9d0e1f2a3b4c5d6e7f8091a2b3c4d5 | octavia    | load-balancer  |
| 9d0e1f2a3b4c5d6e7f8091a2b3c4d5e6 | barbican   | key-manager    |
+----------------------------------+------------+----------------+

$ openstack server show orders-app-01 -f value -c status -c OS-EXT-SRV-ATTR:host -c addresses
ACTIVE
compute-node-07.dc1.example.com
orders-app-net=10.30.10.113, 203.0.113.184
```

### 10.2 Diagnosticar una instancia de OpenStack trabada

```
$ openstack server list --status ERROR
+--------------------------------------+---------------+--------+----------+
| ID                                   | Name          | Status | Networks |
+--------------------------------------+---------------+--------+----------+
| 9f2a1c84-73b1-4e20-9d5c-08a2f61b4e37 | orders-app-04 | ERROR  |          |
+--------------------------------------+---------------+--------+----------+

$ openstack server show orders-app-04 -f value -c fault
{'code': 500, 'created': '2026-09-18T10:22:04Z', 'message': 'No valid host was found. There are not enough hosts available.', 'details': 'Traceback (most recent call last):\n  File "/usr/lib/python3/dist-packages/nova/conductor/manager.py", line 1548, in schedule_and_build_instances\n    host_lists = self._schedule_instances(context, request_specs[0], ...'}

$ openstack hypervisor list --long
+----+----------------------------------+-----------------+---------------+-------+------------+---------+
| ID | Hypervisor Hostname              | Hypervisor Type | Host IP       | State | vCPUs Used | vCPUs   |
+----+----------------------------------+-----------------+---------------+-------+------------+---------+
|  1 | compute-node-07.dc1.example.com  | QEMU            | 10.30.0.107   | up    |         62 |      64 |
|  2 | compute-node-08.dc1.example.com  | QEMU            | 10.30.0.108   | up    |         64 |      64 |
|  3 | compute-node-09.dc1.example.com  | QEMU            | 10.30.0.109   | down  |          0 |      64 |
+----+----------------------------------+-----------------+---------------+-------+------------+---------+

$ openstack quota show --detail $(openstack project show platform -f value -c id) | grep -E 'cores|ram|instances'
| cores     | {'in_use': 126, 'limit': 128, 'reserved': 0} |
| instances | {'in_use': 31, 'limit': 64, 'reserved': 0}   |
| ram       | {'in_use': 507904, 'limit': 524288, 'reserved': 0} |
```

**«No valid host was found» tiene exactamente tres causas**, y los tres comandos de arriba las distinguen: (1) agotamiento genuino de capacidad — visible en `hypervisor list`; (2) agotamiento de la cuota del proyecto — visible en `quota show`, y acá `cores` está en 126/128, que es la causa real; (3) un filtro del scheduler que ningún host satisface (agregado, zona de disponibilidad, PCI passthrough, topología NUMA) — visible solo en los logs de `nova-scheduler`. Revisá la cuota antes que la capacidad: es la respuesta más común y la consulta más barata.

---

## 11. Equivalentes gestionados como código (Terraform)

El mismo conjunto de componentes, contratado en vez de operado. Este es el artefacto que hace revisable la decisión de construir-versus-comprar.

```hcl
terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }
}

resource "aws_db_instance" "orders" {
  identifier     = "orders-production"
  engine         = "postgres"
  engine_version = "17.2"
  instance_class = "db.r7g.2xlarge"

  allocated_storage     = 200
  max_allocated_storage = 1000
  storage_type          = "gp3"
  iops                  = 12000
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.data.arn

  multi_az                     = true
  backup_retention_period      = 35
  backup_window                = "02:30-03:30"
  maintenance_window           = "sun:04:00-sun:05:00"
  performance_insights_enabled = true
  monitoring_interval          = 30
  deletion_protection          = true
  auto_minor_version_upgrade   = true

  db_subnet_group_name   = aws_db_subnet_group.data.name
  vpc_security_group_ids = [aws_security_group.orders_db.id]

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  tags = {
    Service     = "orders"
    Tier        = "data"
    Environment = "production"
  }
}

resource "aws_elasticache_replication_group" "orders_cache" {
  replication_group_id = "orders-cache"
  description          = "Session and read-through cache for the orders service"
  engine               = "valkey"
  engine_version       = "8.0"
  node_type            = "cache.r7g.large"

  num_node_groups         = 2
  replicas_per_node_group = 1

  automatic_failover_enabled = true
  multi_az_enabled           = true

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true

  parameter_group_name = aws_elasticache_parameter_group.lru.name
  subnet_group_name    = aws_elasticache_subnet_group.data.name
  security_group_ids   = [aws_security_group.orders_cache.id]

  snapshot_retention_limit = 0
}

resource "aws_elasticache_parameter_group" "lru" {
  name   = "orders-cache-lru"
  family = "valkey8"

  parameter {
    name  = "maxmemory-policy"
    value = "allkeys-lru"
  }
}

resource "aws_msk_cluster" "events" {
  cluster_name           = "platform-events"
  kafka_version          = "3.9.0"
  number_of_broker_nodes = 3

  broker_node_group_info {
    instance_type   = "kafka.m7g.large"
    client_subnets  = aws_subnet.data[*].id
    security_groups = [aws_security_group.kafka.id]

    storage_info {
      ebs_storage_info {
        volume_size = 1000
      }
    }
  }

  encryption_info {
    encryption_in_transit {
      client_broker = "TLS"
      in_cluster    = true
    }
    encryption_at_rest_kms_key_arn = aws_kms_key.data.arn
  }

  configuration_info {
    arn      = aws_msk_configuration.events.arn
    revision = aws_msk_configuration.events.latest_revision
  }
}

resource "aws_msk_configuration" "events" {
  name           = "platform-events-config"
  kafka_versions = ["3.9.0"]

  server_properties = <<-PROPERTIES
    auto.create.topics.enable=false
    default.replication.factor=3
    min.insync.replicas=2
    unclean.leader.election.enable=false
    log.retention.hours=168
  PROPERTIES
}

resource "aws_s3_bucket" "artifacts" {
  bucket = "platform-artifacts-eu-central-1"
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "STANDARD_IA"
    }

    noncurrent_version_expiration {
      noncurrent_days = 365
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

Dos ajustes merecen que se los nombre porque son la diferencia entre un diseño HA y uno con forma de HA: `unclean.leader.election.enable=false` (Kafka se va a negar a elegir como líder a una réplica fuera de sincronía, eligiendo indisponibilidad antes que pérdida silenciosa de datos) y `deletion_protection = true` en la base de datos (un `terraform destroy` contra el workspace equivocado es un error humano de rutina). `snapshot_retention_limit = 0` en la caché es deliberado en el sentido opuesto: una caché no es un sistema de registro, y pagar por respaldarla es pagar por restaurar datos viejos.

---

## 12. Verificación y diagnóstico de fallos

### 12.1 El método genérico

Cuando un servicio respaldado por componentes se degrada, trabajá **de afuera hacia adentro** a lo largo del camino del request y hacé una pregunta en cada salto: *¿este salto está agregando latencia, agregando errores, o encolando?*

```
client → DNS → CDN/edge → LB → ingress → app pod → pool → { DB | cache | broker } → downstream
```

Las tres familias de síntomas y su firma:

| Síntoma | Firma | Componente más probable | Primer comando |
|---|---|---|---|
| Latencia arriba, tasa de error plana | El p99 trepa antes que el p50 | Encolado: agotamiento del pool, GC, disco | `pg_stat_activity` / `redis-cli --latency` |
| Tasa de error arriba, latencia abajo | Fallos rápidos | Circuit breaker, conexión rechazada, autenticación | `kubectl logs`, `ss -s` |
| Latencia arriba **y** errores arriba | Saturación | Se alcanzó el límite de CPU/memoria/IOPS | `kubectl top`, `iostat -x 1` |
| Throughput plano con más carga | Techo duro | Límite de conexiones, partición única, hilo único | `kafka-consumer-groups.sh`, `SHOW max_connections` |
| Todo bien, datos mal | Ninguna señal en absoluto | Semántica de entrega, retardo de replicación, datos viejos en caché | Comparar los conteos de origen y destino |

### 12.2 Un runbook de triage concreto

**Síntoma: la API de pedidos devuelve HTTP 503 en el 12 % de los requests.**

```
$ kubectl get pods -n orders -l app=orders-api
NAME                          READY   STATUS      RESTARTS      AGE
orders-api-6f9d4c7b8d-2k4xq   1/1     Running     0             3h
orders-api-6f9d4c7b8d-7vnzl   0/1     CrashLoopBackOff  6 (42s ago)   3h
orders-api-6f9d4c7b8d-9wqrt   1/1     Running     0             3h
orders-api-6f9d4c7b8d-pm8zc   1/1     Running     2 (11m ago)   3h

$ kubectl logs -n orders orders-api-6f9d4c7b8d-7vnzl --previous --tail=20
2026-09-18T11:02:14.882Z ERROR [HikariPool-1] Connection is not available, request timed out after 30001ms
2026-09-18T11:02:14.884Z ERROR o.s.b.w.s.ErrorPageFilter  org.springframework.jdbc.CannotGetJdbcConnectionException
2026-09-18T11:02:44.901Z ERROR [HikariPool-1] Connection is not available, request timed out after 30002ms

$ kubectl exec -n data orders-db-1 -- psql -U postgres -c "
    SELECT state, wait_event_type, count(*)
    FROM pg_stat_activity
    WHERE datname = 'orders'
    GROUP BY 1, 2 ORDER BY 3 DESC;"
      state       | wait_event_type | count
------------------+-----------------+-------
 idle in transaction | Client        |   147
 active           | Lock            |    31
 idle             | Client          |    14
 active           |                 |     6
(4 rows)

$ kubectl exec -n data orders-db-1 -- psql -U postgres -c "
    SELECT pid, now() - xact_start AS xact_age, left(query, 60) AS query
    FROM pg_stat_activity
    WHERE state = 'idle in transaction'
    ORDER BY xact_start LIMIT 5;"
  pid  |    xact_age     |                    query
-------+-----------------+----------------------------------------------
 28471 | 00:41:12.882713 | SELECT * FROM orders WHERE customer_id = $1
 28492 | 00:40:57.114029 | SELECT * FROM orders WHERE customer_id = $1
 28503 | 00:40:44.900112 | UPDATE inventory SET reserved = reserved + $1
```

**Diagnóstico.** 147 sesiones están `idle in transaction` con edades de transacción de más de cuarenta minutos. La aplicación abrió transacciones y nunca hizo commit ni rollback — casi siempre un camino de excepción que se saltea el `close()`, o una transacción que abarca una llamada HTTP saliente. Esas sesiones mantienen locks (los 31 que esperan en `Lock`) y consumen `max_connections`, así que el pool no puede entregar conexiones y la readiness probe falla, sacando pods de la lista de endpoints → 503.

**Mitigación inmediata, y después el arreglo real:**

```
$ kubectl exec -n data orders-db-1 -- psql -U postgres -c "
    SELECT pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE datname = 'orders'
      AND state = 'idle in transaction'
      AND now() - xact_start > interval '5 minutes';"
 pg_terminate_backend
----------------------
 t
 t
... (147 rows)
```

Los arreglos durables, en orden de valor: poner `idle_in_transaction_session_timeout = '60s'` en la base de datos para que esto no pueda volver a agotar las conexiones; poner PgBouncer en modo de pooling por transacción entre la app y la base para que 1 500 conexiones del lado de la app se mapeen a 40 del lado del servidor; y sacar la llamada de red de adentro de la transacción en la aplicación.

### 12.3 Checklist de verificación por componente

| Componente | Vitalidad | Correctitud | Saturación | Comando |
|---|---|---|---|---|
| Base relacional | Acepta conexiones | LSN de la réplica == LSN del primario | Conteo de `pg_stat_activity` vs. `max_connections`; checkpoints de `pg_stat_bgwriter` | `kubectl cnpg status`, `pg_isready` |
| Caché | `PING` → `PONG` | Hit ratio estable | Tasa de `evicted_keys`; `used_memory` vs. `maxmemory` | `redis-cli info`, `--bigkeys` |
| Kafka | Broker en el ISR de todas las particiones | Tamaño de `Isr` == tamaño de `Replicas` | Tasa de cambio del lag del consumidor, % de disco | `kafka-topics.sh --describe --under-replicated-partitions` |
| RabbitMQ | Todos los nodos en `cluster_status` | Profundidad de la DLQ == 0 | Tendencia de `messages_ready`, alarma de memoria | `rabbitmqctl list_queues`, `status` |
| Almacenamiento de objetos | `HEAD` al bucket | Checksum al restaurar | Tasa de requests vs. límites por prefijo | `aws s3api head-bucket` |
| Knative/FaaS | Revisión en `Ready` | La división de tráfico coincide con la intención | Tiempo de encolado del `queue-proxy`, throttling | `kn revision list` |
| CDN | 200 sobre un asset conocido | Ratio de `x-cache: HIT` | Tasa de requests al origen | `curl -I`, analítica del proveedor |
| OpenStack | `openstack service list` con todos presentes | Stack en `CREATE_COMPLETE` | Cuota vs. en uso, vCPUs del hipervisor | `openstack quota show --detail` |

### 12.4 Reglas de alerta que codifican lo anterior

```yaml
groups:
  - name: platform-standard-components
    interval: 30s
    rules:
      - alert: KafkaUnderReplicatedPartitions
        expr: |
          sum by (cluster) (kafka_server_replicamanager_underreplicatedpartitions) > 0
        for: 5m
        labels:
          severity: critical
          component: kafka
        annotations:
          summary: "Under-replicated partitions on {{ $labels.cluster }}"
          description: "min.insync.replicas is at risk; one more broker loss stops writes."
          runbook_url: "https://runbooks.example.com/kafka/under-replicated"

      - alert: KafkaConsumerLagGrowing
        expr: |
          sum by (consumergroup, topic) (kafka_consumergroup_lag) > 100000
          and
          deriv(sum by (consumergroup, topic) (kafka_consumergroup_lag)[15m:1m]) > 0
        for: 15m
        labels:
          severity: warning
          component: kafka
        annotations:
          summary: "Lag above 100k and still growing for {{ $labels.consumergroup }}"

      - alert: PostgresReplicationLagHigh
        expr: |
          max by (cluster) (cnpg_pg_replication_lag) > 30
        for: 5m
        labels:
          severity: warning
          component: postgresql
        annotations:
          summary: "Replica more than 30s behind on {{ $labels.cluster }}"

      - alert: PostgresConnectionsNearLimit
        expr: |
          sum by (cluster) (cnpg_backends_total)
          /
          max by (cluster) (cnpg_pg_settings_setting{name="max_connections"})
          > 0.85
        for: 10m
        labels:
          severity: critical
          component: postgresql
        annotations:
          summary: "Connection usage above 85% of max_connections"

      - alert: RedisCacheHitRatioDegraded
        expr: |
          sum(rate(redis_keyspace_hits_total[10m]))
          /
          (sum(rate(redis_keyspace_hits_total[10m])) + sum(rate(redis_keyspace_misses_total[10m])))
          < 0.80
        for: 20m
        labels:
          severity: warning
          component: redis
        annotations:
          summary: "Cache hit ratio below 80% - working set may exceed maxmemory"

      - alert: RabbitDeadLetterQueueNotEmpty
        expr: |
          rabbitmq_queue_messages{queue=~".*\\.dead"} > 0
        for: 5m
        labels:
          severity: warning
          component: rabbitmq
        annotations:
          summary: "Messages in {{ $labels.queue }} - poison messages are being discarded"

      - alert: ObjectStorageBackupStale
        expr: |
          time() - cnpg_collector_last_available_backup_timestamp > 90000
        for: 30m
        labels:
          severity: critical
          component: backup
        annotations:
          summary: "No successful backup in over 25 hours"
```

Cada `expr` de arriba es un escalar de bloque cuyas líneas llevan una indentación idéntica, incluidos los operadores sueltos `/` y `and` — una sola línea desindentada termina el escalar en silencio y Prometheus se niega a cargar el archivo de reglas completo.

---

## 13. Resumen de decisiones

| Si el requisito es… | Elegí | Porque |
|---|---|---|
| Invariantes entre entidades, dinero | Relacional (PostgreSQL) | ACID entre filas no se emula barato |
| Último valor por clave, reproducible | Topic compactado de Kafka | El log es el estado, el replay es gratis |
| Distribución de trabajo con enrutamiento y prioridades | Quorum queues de RabbitMQ | Broker listo, ack por mensaje, DLX |
| Event streaming con muchos lectores independientes | Kafka | La retención está desacoplada del consumo |
| Sub-milisegundo, sin necesidad de durabilidad | Redis / NATS | En memoria, un solo salto |
| Volumen de escritura muy alto, ordenado por tiempo | Cassandra / ClickHouse | Motor de almacenamiento optimizado para escritura |
| Búsqueda de texto completo | OpenSearch, **con un sistema de registro detrás** | El índice es una proyección derivada y reconstruible |
| Trabajo corto, con picos, sin estado | FaaS / Knative | Escala a cero, facturación por ms |
| Servicio estable 24/7 | Contenedor sobre capacidad reservada | El costo fijo le gana al por-request con ciclo de trabajo alto |
| Artefactos inmutables, de lectura múltiple | Almacenamiento de objetos + CDN | Lo más barato por GiB, ilimitado, cacheable |
| Autoservicio para desarrolladores sin alfabetización en Kubernetes | PaaS (Cloud Foundry / OpenShift) | Buildpacks y service brokers eliminan la superficie de la plataforma |
| Una nube on-premises con una API | OpenStack | La descomposición de referencia, con todas las piezas direccionables |

**Y las cuatro preguntas que hay que hacerle a cada componente antes de que entre en un diseño:**

1. **¿Qué garantiza?** Modelo de consistencia, semántica de entrega, durabilidad con `fsync` o sin él.
2. **¿Quién lo opera?** Trazá la línea de responsabilidad explícitamente, incluyendo backups, parcheo y simulacros de restauración.
3. **¿Cómo escala, y cuál es el techo duro?** Particiones, conexiones, memoria, IOPS — todo componente tiene uno.
4. **¿Qué hace el resto de la plataforma cuando falla?** Si la respuesta es «todo se detiene», no diseñaste una dependencia; diseñaste un punto único de fallo con pasos extra.

---

## Referencias

**Objetivos del examen**
- LPI DevOps Tools Engineer, objetivos del examen 701 — https://www.lpi.org/our-certifications/exam-701-objectives/

**Plataformas cloud y modelos de servicio**
- Documentación de OpenStack (índice de componentes) — https://docs.openstack.org/
- Especificación de la plantilla Heat Orchestration de OpenStack — https://docs.openstack.org/heat/latest/template_guide/hot_spec.html
- OpenStack Nova (cómputo) — https://docs.openstack.org/nova/latest/
- OpenStack Neutron (redes) — https://docs.openstack.org/neutron/latest/
- OpenStack Cinder (almacenamiento de bloques) — https://docs.openstack.org/cinder/latest/
- OpenStack Swift (almacenamiento de objetos) — https://docs.openstack.org/swift/latest/
- OpenStack Keystone (identidad) — https://docs.openstack.org/keystone/latest/
- OpenStack Octavia (balanceo de carga) — https://docs.openstack.org/octavia/latest/
- NIST SP 800-145, The NIST Definition of Cloud Computing — https://csrc.nist.gov/publications/detail/sp/800-145/final

**Cómputo y contenedores**
- Documentación de Kubernetes — https://kubernetes.io/docs/home/
- Storage Classes de Kubernetes — https://kubernetes.io/docs/concepts/storage/storage-classes/
- Knative Serving — https://knative.dev/docs/serving/
- Referencia de autoescalado de Knative — https://knative.dev/docs/serving/autoscaling/
- Firecracker microVM — https://firecracker-microvm.github.io/
- gVisor — https://gvisor.dev/docs/
- Especificaciones de la Open Container Initiative — https://opencontainers.org/

**PaaS y sistemas de build**
- Documentación de Cloud Foundry — https://docs.cloudfoundry.org/
- Referencia del manifiesto de aplicación de Cloud Foundry — https://docs.cloudfoundry.org/devguide/deploy-apps/manifest-attributes.html
- Open Service Broker API — https://www.openservicebrokerapi.org/
- Cloud Native Buildpacks — https://buildpacks.io/docs/
- Paketo Buildpacks — https://paketo.io/docs/
- Documentación de Red Hat OpenShift — https://docs.openshift.com/
- The Twelve-Factor App — https://12factor.net/

**Bases de datos**
- Documentación de PostgreSQL — https://www.postgresql.org/docs/current/
- Alta disponibilidad y replicación en PostgreSQL — https://www.postgresql.org/docs/current/high-availability.html
- Manual de referencia de MySQL — https://dev.mysql.com/doc/refman/8.4/en/
- Base de conocimiento de MariaDB — https://mariadb.com/kb/en/documentation/
- Manual de MongoDB — https://www.mongodb.com/docs/manual/
- Documentación de Apache Cassandra — https://cassandra.apache.org/doc/latest/
- Documentación de CloudNativePG — https://cloudnative-pg.io/documentation/current/
- Guía de usuario de Amazon RDS — https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Welcome.html

**Cacheo**
- Documentación de Redis — https://redis.io/docs/latest/
- Políticas de desalojo de Redis — https://redis.io/docs/latest/develop/reference/eviction/
- Documentación de Valkey — https://valkey.io/docs/
- Wiki de Memcached — https://github.com/memcached/memcached/wiki

**Mensajería**
- Documentación de Apache Kafka — https://kafka.apache.org/documentation/
- Diseño y semántica de entrega de Kafka — https://kafka.apache.org/documentation/#semantics
- Documentación de Strimzi — https://strimzi.io/docs/operators/latest/overview
- Documentación de RabbitMQ — https://www.rabbitmq.com/docs
- Quorum queues de RabbitMQ — https://www.rabbitmq.com/docs/quorum-queues
- Especificación del protocolo AMQP 0-9-1 — https://www.rabbitmq.com/tutorials/amqp-concepts
- Especificación OASIS AMQP 1.0 — https://www.amqp.org/resources/specifications
- Apache ActiveMQ Artemis — https://activemq.apache.org/components/artemis/documentation/
- Documentación de NATS — https://docs.nats.io/
- Guía de ZeroMQ — https://zguide.zeromq.org/
- Guía del desarrollador de Amazon SQS — https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/welcome.html

**Big data y analítica**
- Documentación de Apache Hadoop — https://hadoop.apache.org/docs/stable/
- Documentación de Apache Spark — https://spark.apache.org/docs/latest/
- Ejecutar Spark sobre Kubernetes — https://spark.apache.org/docs/latest/running-on-kubernetes.html
- Documentación de Apache Flink — https://nightlies.apache.org/flink/flink-docs-stable/
- Documentación de OpenSearch — https://opensearch.org/docs/latest/
- Referencia de Elasticsearch — https://www.elastic.co/guide/en/elasticsearch/reference/current/index.html
- Documentación de ClickHouse — https://clickhouse.com/docs
- Documentación de Trino — https://trino.io/docs/current/

**Almacenamiento, entrega y observabilidad**
- Guía de usuario de Amazon S3 — https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html
- Modelo de consistencia de Amazon S3 — https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html#ConsistencyModel
- Documentación de MinIO — https://min.io/docs/minio/linux/index.html
- Documentación de Ceph — https://docs.ceph.com/en/latest/
- Documentación para desarrolladores de CSI en Kubernetes — https://kubernetes-csi.github.io/docs/
- RFC 9111, HTTP Caching — https://www.rfc-editor.org/rfc/rfc9111.html
- Documentación de Prometheus — https://prometheus.io/docs/introduction/overview/
- Reglas de alerta de Prometheus — https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/

**Infraestructura como código**
- Documentación de Terraform — https://developer.hashicorp.com/terraform/docs
- Proveedor AWS de Terraform — https://registry.terraform.io/providers/hashicorp/aws/latest/docs