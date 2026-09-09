# Tema 2.2 — Determinar qué productos de gestión de datos de Google Cloud son aplicables a distintos casos de uso de negocio

**Certificación:** Google Cloud Digital Leader (versión de examen 2026-08-12)
**Peso del dominio:** 6.0
**Perfil de audiencia:** Platform Architect / Senior SRE. Este módulo trata el objetivo del examen como un problema de selección arquitectónica, no como un ejercicio de catálogo de productos. El examen pregunta *qué producto*; producción pregunta *por qué, con qué consistencia, con qué latencia de cola, con qué radio de impacto y a qué coste unitario*. Ambas respuestas salen del mismo razonamiento.

---

## 1. Motivación: el problema arquitectónico de producción

### 1.1 El modo de fallo que este objetivo existe para prevenir

Casi todo incidente catastrófico de plataforma de datos en una migración a la nube se remonta a una clase de error: **una carga de trabajo colocada sobre un motor de almacenamiento cuya semántica de consistencia, escalado y fallo no coincide con la transacción de negocio a la que sirve.** El error rara vez se ve el primer día. Aflora con 3× de tráfico, en el primer evento regional o en la primera auditoría.

Cuatro incidentes canónicos, todos ellos el *mismo* error con distinto disfraz:

| Incidente | Qué se construyó | Por qué se rompió | Ubicación correcta |
|---|---|---|---|
| Doble gasto en el libro mayor de pagos | Libro mayor global de pagos sobre un almacén wide-column con replicación entre regiones eventual; la aplicación leía de la réplica más cercana y escribía en el clúster más cercano | El motor garantiza atomicidad solo **por fila**; no hay transacción entre filas ni entre regiones. Dos regiones aceptaron débitos solapados. | **Spanner** — ACID entre filas y entre regiones, externamente consistente |
| Una tormenta de consultas analíticas tumba el checkout | Dashboards de BI apuntando al primario OLTP (Cloud SQL) porque "los datos ya están ahí" | Los escaneos analíticos consumieron el buffer pool y las IOPS del primario; un motor row-store debe leer filas enteras para agregar una sola columna. Siguieron contención de bloqueos y agotamiento de conexiones. | **BigQuery** (o el motor columnar de AlloyDB / read pool) — OLAP separado de OLTP |
| Factura de almacenamiento de objetos de $340k/mes | 900 TB de telemetría IoT escritos en clase Standard, sin ciclo de vida, y luego "arreglados" con un cambio masivo de clase | Nearline/Coldline/Archive tienen **duraciones mínimas de almacenamiento** (30/90/365 días) y tarifas de recuperación; una transición masiva prematura disparó cargos por borrado anticipado además de los de recuperación. | **Autoclass** o reglas de ciclo de vida aplicadas *en la creación del bucket*, antes de que aterricen los datos |
| El almacén global de sesiones se funde en el lanzamiento | Sesiones de usuario en una base de datos relacional, una fila por sesión, objetivo de 400k escrituras/seg | Un OLTP row-store con replicación síncrona no puede absorber esa tasa de escritura con p99 de milisegundos de un dígito sin topar con límites verticales. | **Memorystore** (efímero) + **Bigtable/Firestore** (duradero) |

### 1.2 Los cuatro ejes que lo deciden todo

Cada producto de datos de Google Cloud es un punto en este espacio. Memorizá los ejes, no el marketing.

1. **Estructura** — estructurado (esquema fijo, relacional), semiestructurado (documentos, JSON, wide-column), no estructurado (objetos: vídeo, imágenes, PDFs, pesos de modelos).
2. **Patrón de acceso** — OLTP (muchas lecturas/escrituras pequeñas, búsquedas puntuales, transacciones) vs OLAP (pocos escaneos enormes, agregaciones, proyecciones columnares) vs HTAP (ambos) vs caching (submilisegundo, no duradero) vs archivado (escribir una vez, leer rara vez).
3. **Consistencia y alcance de la atomicidad** — fuerte dentro de una fila / dentro de un entity group / dentro de una región / **externamente consistente a nivel global**; frente a eventual.
4. **Topología de escalado horizontal** — vertical (un primario, máquina más grande), escalado en lectura (primario + réplicas), particionado horizontalmente por el propio servicio (Spanner, Bigtable, BigQuery, Firestore) o almacenamiento de objetos shared-nothing (Cloud Storage).

Un quinto eje operativo, innegociable en producción: **radio de impacto** — zonal, regional o multirregional — y el SLA que se deriva de él.

### 1.3 El árbol de decisión (esta es la respuesta del examen en forma comprimida)

```
Is the data unstructured (files, blobs, media, backups, model artifacts)?
├─ YES → Cloud Storage (object)
│         ├─ POSIX semantics required by a legacy app? → Filestore / NetApp Volumes
│         ├─ HPC/AI training scratch, sub-ms, TB/s? → Parallelstore
│         └─ Boot disk / raw block for a VM? → Persistent Disk / Hyperdisk
└─ NO → structured or semi-structured
   │
   ├─ Primary purpose is ANALYTICS (scan, aggregate, join across history, ML/BI)?
   │   └─ YES → BigQuery  (+ BI Engine for sub-second dashboards,
   │                        + BigLake/Omni for data in GCS/S3/Azure,
   │                        + Analytics Hub to share it)
   │
   └─ Primary purpose is OPERATIONAL (an app serving users/transactions)?
       │
       ├─ Needs RELATIONAL / SQL / joins / referential integrity?
       │   ├─ Lift-and-shift an existing MySQL / PostgreSQL / SQL Server engine,
       │   │  regional scale is enough → Cloud SQL
       │   ├─ PostgreSQL-compatible but needs 4× OLTP throughput, HTAP,
       │   │  99.99% SLA, near-zero-downtime scaling → AlloyDB for PostgreSQL
       │   └─ Needs horizontal write scale AND global strong consistency
       │      AND 99.999% (five nines) → Spanner
       │
       └─ Non-relational?
           ├─ Documents, mobile/web SDKs, realtime listeners, offline sync → Firestore
           ├─ Huge key-ordered/time-series/wide-column, >1 TB, high write
           │  throughput, single-digit-ms, no joins → Bigtable
           └─ Ephemeral, sub-millisecond, cache / session / leaderboard → Memorystore
```

> **Trampa de examen #1:** "¿Qué producto para una base de datos *relacional, globalmente consistente y escalable horizontalmente*?" → **Spanner**, siempre. "¿Cuál para *migrar una base de datos MySQL 8 existente con cambios mínimos*?" → **Cloud SQL**, siempre. El distractor es que ambas son "SQL relacional". El discriminador es *consistencia fuerte global + escalado horizontal de escritura* frente a *compatibilidad + refactorización mínima*.

---

## 2. Mecánica técnica producto por producto

### 2.1 Cloud Storage — almacenamiento de objetos como sustrato de durabilidad

**Internals.** Cloud Storage es un espacio de nombres plano (no hay directorios reales; `/` es un carácter dentro del nombre del objeto) sobre Colossus, el sistema de archivos distribuido de Google. Los objetos se codifican con erasure coding entre dominios de fallo; la cifra de durabilidad de 11 nueves es una propiedad de esa codificación más la verificación continua de integridad en segundo plano vía checksums CRC32C/MD5, no del número de réplicas por sí solo. Los metadatos viven en un servicio de metadatos fuertemente consistente — por eso Cloud Storage ofrece **consistencia fuerte read-after-write** para los PUT y DELETE de objetos, y listados de bucket/objeto fuertemente consistentes. No hay una ventana de consistencia eventual que haya que contemplar en el diseño (una suposición heredada muy común de otras nubes).

Mecánicas clave que un SRE debe interiorizar:

- **El tipo de ubicación es inmutable.** `region` / `dual-region` / `multi-region` se fija al crear el bucket y no se puede cambiar. Mover 500 TB entre tipos de ubicación significa un trabajo de `gcloud storage cp` (o Storage Transfer Service) más un cutover, no un flag de configuración.
- **La clase de almacenamiento es por *objeto***, con un valor por defecto a nivel de bucket. Las reglas de ciclo de vida mutan las clases de los objetos.
- **Duración mínima de almacenamiento** — Nearline 30 días, Coldline 90 días, Archive 365 días. Si borrás o transicionás antes, te facturan el resto. Esta es la sorpresa de coste más común de todas.
- **Autoclass** mueve objetos entre clases según el acceso, **sin tarifas de recuperación ni de borrado anticipado**, a cambio de una pequeña tarifa de gestión por objeto. Para patrones de acceso impredecibles casi siempre sale más barato que reglas de ciclo de vida ajustadas a mano — y solo se puede activar sobre un bucket, así que decidilo en la creación.
- **Turbo replication** (solo dual-region) da un RPO de 15 minutos con un SLO, frente a la replicación asíncrona best-effort del resto.
- **Retention policy + Bucket Lock** hace los objetos inmutables durante un período, y *bloquear* la política la vuelve irrevocable — el mecanismo detrás de los archivos WORM/resistentes a ransomware y regulatorios (estilo SEC 17a-4). **Object Retention Lock** hace lo mismo por objeto.
- **Soft delete** retiene los objetos borrados/sobrescritos durante una ventana de retención (7 días por defecto en buckets nuevos) y es lo primero que hay que comprobar tras un `rm -r` accidental.

| Clase | Duración mín. | Uso típico | Coste de recuperación | SLA de disponibilidad (multirregión) |
|---|---|---|---|---|
| Standard | ninguna | Servido en caliente, analítica activa, artefactos de GKE | ninguno | 99.95% |
| Nearline | 30 d | Informes mensuales, backups leídos ~mensualmente | bajo | 99.9% |
| Coldline | 90 d | Copias de DR trimestrales | medio | 99.9% |
| Archive | 365 d | Retención legal, 7 años, sustituto de cinta | alto | 99.9% |
| Autoclass | n/a (gestionada) | Acceso desconocido/errático | ninguno | depende de la clase |

> Los buckets regionales llevan un SLA de disponibilidad del 99.9%; dual-region y multi-region Standard llevan 99.95%. La durabilidad (11 nueves) *no* es disponibilidad — confundirlas es la trampa de examen #2.

**Archivos y bloque, para completar** (el objetivo cubre "productos de gestión de datos", y aparecen preguntas sobre niveles de almacenamiento):

| Necesidad | Producto | Interfaz | Notas |
|---|---|---|---|
| Sistema de archivos POSIX compartido para lift-and-shift | **Filestore** | NFSv3 | Niveles Basic/Zonal/Regional/Enterprise; Enterprise es redundante a nivel regional e integrado con GKE |
| Funciones de NAS empresarial (snapshots, SnapMirror, multiprotocolo) | **NetApp Volumes** | NFS + SMB | Para cargas que ya están sobre ONTAP |
| Scratch de HPC/IA, TB/s agregados | **Parallelstore** | basado en DAOS | Efímero, alimenta el entrenamiento en GPU/TPU |
| Bloque puro para una VM | **Persistent Disk / Hyperdisk** | bloque | Hyperdisk desacopla las IOPS/throughput aprovisionados de la capacidad |
| Objeto-como-sistema-de-archivos para GKE/IA | **Cloud Storage FUSE** | montaje | No es POSIX-completo; no hay semántica de rename atómico para directorios — nunca pongas una base de datos encima |

### 2.2 Cloud SQL — MySQL, PostgreSQL y SQL Server gestionados

**Arquitectura.** Una instancia de Cloud SQL es una VM gestionada por Google que ejecuta el binario upstream real del motor contra un disco persistente regional o zonal. **La alta disponibilidad es a nivel de almacenamiento, no de motor**: una instancia HA (`REGIONAL`) mantiene un standby en una segunda zona y las escrituras se replican de forma síncrona en la capa de bloque hacia un PD regional. En el failover, la VM standby monta el mismo disco regional y la IP de la instancia se reapunta. Consecuencias que importan operativamente:

- El failover suele tardar de decenas de segundos a un par de minutos, y **las conexiones se cortan** — la aplicación debe reconectar y reintentar. No hay failover transparente de conexiones.
- El standby **no es legible**. Escalar lectura requiere réplicas de lectura explícitas, que usan replicación *asíncrona nativa del motor* (binlog / streaming WAL) y por tanto tienen un retardo de réplica que hay que monitorizar.
- La replicación regional síncrona implica que la ruta de escritura paga un round trip entre zonas. La HA cuesta latencia de escritura; ese es el precio del SLA.
- La edición **Enterprise Plus** añade una familia de máquinas mayor, una **data cache** local en NVMe, mantenimiento planificado y failover con downtime casi nulo, y un SLA del **99.99%** (frente al 99.95% de Enterprise HA).

**Backup/recuperación.** Los backups automatizados más el archivado del write-ahead-log/binlog habilitan la **recuperación a un punto en el tiempo (PITR)**, que restaura *a una instancia nueva* — nunca in situ. Ensayalo: la duración de la restauración en una instancia de varios TB se mide en horas y es el RTO real, diga lo que diga el panel de backups.

**Conectividad — la parte que los equipos hacen mal.** Tres opciones, en orden decreciente de preferencia:

1. **Private Service Access (PSA)** — un peering de VPC contra la red del productor gestionada por Google; la instancia obtiene una dirección privada RFC 1918 de un rango que vos reservás. No requiere IP pública en absoluto.
2. **Cloud SQL Auth Proxy / Language Connectors** — una capa del lado del cliente que establece un túnel TLS mutuamente autenticado usando IAM, de modo que no hay listas blancas de IP ni credenciales estáticas. En Kubernetes se ejecuta como **sidecar** con Workload Identity.
3. IP pública con redes autorizadas — aceptable solo con `require_ssl` y CIDRs estrictos; tratala como legacy.

### 2.3 AlloyDB for PostgreSQL — almacenamiento desagregado y el caso HTAP

AlloyDB es donde vive la respuesta "PostgreSQL pero más grande" del examen, y arquitectónicamente es la más interesante de las opciones relacionales.

**Arquitectura desagregada.** El nodo de cómputo ejecuta PostgreSQL, pero la capa de almacenamiento está reemplazada. En lugar de que el motor escriba páginas completas de 8 KiB a un disco, envía **registros de WAL** a un **Log Processing Service (LPS)** regional. El LPS materializa las páginas de forma asíncrona y en paralelo entre zonas, y la capa de almacenamiento devuelve las páginas al cómputo. Implicaciones:

- **Las escrituras son solo de log** desde el punto de vista del motor — sin full-page writes, sin tormentas de checkpoint, sin amplificación de escritura por vacuum contra un único disco.
- **Los read pools escalan de forma independiente** del primario y comparten la misma capa de almacenamiento, así que añadir capacidad de lectura no reproduce el WAL en cada réplica ni crea retardo por réplica derivado del apply de replicación.
- **Los backups son a nivel de capa de almacenamiento y continuos**, así que el PITR es barato y la restauración es rápida.
- El **motor columnar** mantiene una representación columnar en memoria de las columnas calientes; el planificador puede elegir acceso columnar o por filas por consulta. Esto es lo que hace a AlloyDB genuinamente HTAP — las consultas analíticas pueden ejecutarse sobre la base de datos operativa sin un warehouse aparte, hasta cierto punto.
- **Index Advisor** y query insights vienen integrados.
- El SLA es del **99.99%**, incluyendo el mantenimiento (AlloyDB explícitamente no excluye las ventanas de mantenimiento de su compromiso de disponibilidad — un diferenciador real en la documentación de DR).

**Cuándo AlloyDB *no* es la respuesta:** si necesitás throughput de escritura por encima del techo de un único nodo primario, o consistencia fuerte global entre continentes, AlloyDB no lo resuelve — Spanner sí. AlloyDB escala *hacia arriba* y escala *lecturas hacia fuera*; no particiona escrituras.

### 2.4 Spanner — TrueTime, Paxos y consistencia externa

**Por qué existe.** Spanner es el único producto del portfolio que ofrece **transacciones relacionales escalables horizontalmente y fuertemente consistentes entre regiones**. Si una pregunta contiene "global", "fuertemente consistente", "relacional" y "escalar horizontalmente" — o menciona cinco nueves — la respuesta es Spanner.

**Internals que vale la pena conocer incluso para un examen de nivel leader, porque explican los compromisos:**

- **TrueTime** es una API de reloj distribuida globalmente respaldada por receptores GPS y relojes atómicos en cada datacenter. Devuelve un *intervalo* `[earliest, latest]` con una incertidumbre acotada ε (milisegundos de un dígito). Spanner asigna a cada transacción confirmada una marca de tiempo y *espera a que pase* la incertidumbre antes de confirmar (commit-wait). Esto es lo que compra la **consistencia externa (linealizabilidad)**: si la transacción T1 confirma antes de que T2 empiece en tiempo real, la marca de tiempo de T1 es estrictamente menor que la de T2, a nivel global. Ninguna otra base de datos relacional gestionada ofrece esto.
- Los datos se particionan por rangos en **splits**; cada split se replica mediante un **grupo Paxos**, con un líder por grupo. Las escrituras van al líder y necesitan un quórum; las lecturas en una marca de tiempo pueden servirse desde cualquier réplica actualizada.
- **Tipos de réplica**: read-write (con voto, datos completos), read-only (sin voto, sirven lecturas stale/con marca de tiempo localmente) y **witness** (vota, sin datos — se usa para formar quórums de forma barata en una tercera región). Una configuración multirregión como `nam3` usa réplicas read-write en dos regiones más un witness en una tercera.
- La **capacidad** se expresa en **processing units** (PU); 1000 PU = 1 nodo. El almacenamiento escala hasta **10 TB por nodo**. Hay autoescalador disponible.
- Las **tablas interleaved** colocan físicamente las filas hijas junto a su fila padre, convirtiendo un join en un escaneo local — la palanca de diseño de esquema más importante de todas.
- El **hotspotting** es el modo de fallo dominante. Las claves monótonamente crecientes (timestamps, secuencias, `AUTO_INCREMENT`) concentran todas las escrituras en el líder de un solo split. Mitigaciones: UUIDv4 / secuencias con bits invertidos, prefijos de clave hasheados, o secuencias positivas con bits invertidos estilo `AUTO_INCREMENT`. **Key Visualizer** es la herramienta de diagnóstico.
- Lecturas: **strong reads** (por defecto, pueden cruzar regiones hasta el líder) frente a **stale reads** (`exact_staleness` / `max_staleness`), que se sirven localmente y son drásticamente más baratas en latencia. Elegir staleness acotado para rutas de lectura que lo toleren es la optimización estándar.
- Se soportan tanto la **interfaz PostgreSQL** como el dialecto GoogleSQL; **PITR** vía `version_retention_period` (hasta 7 días).
- SLA: **99.999%** multirregión, **99.99%** regional.
- Límite duro a recordar: **80.000 mutaciones por commit** — los cargadores masivos deben trocear.

**El compromiso honesto:** Spanner es caro a pequeña escala, impone disciplina de diseño de esquema (no hay patrones de consulta arbitrarios sin índices secundarios, ni joins entre splits gratis) y su huella mínima viable es mayor que la de una instancia de Cloud SQL. No lo elijas para una aplicación departamental.

### 2.5 Bigtable — wide-column, ordenado por clave, escala de petabytes

**Internals.** Bigtable es un mapa disperso, ordenado y tridimensional: `(row key, column family:qualifier, timestamp) → value`. Los datos se dividen en **tablets** por rangos contiguos de row key; los tablets se almacenan como **SSTables** inmutables sobre Colossus con un write-ahead log y una memtable en memoria. **El cómputo y el almacenamiento están separados** — los nodos no guardan datos, solo la propiedad de los tablets y las cachés. Por tanto:

- **El rebalanceo es solo de metadatos.** Añadir nodos reasigna punteros a tablets, no bytes; los cambios de capacidad surten efecto en minutos, aunque la caché se calienta gradualmente.
- **La atomicidad es solo por fila.** Sin transacciones multi-fila, sin joins, sin índices secundarios. La row key *es* el índice; diseñás una row key por patrón de consulta y desnormalizás.
- **El diseño de la row key lo es todo.** Las claves secuenciales (timestamps crudos, IDs de dispositivo secuenciales) crean un tablet caliente. Patrones estándar: promoción de campo (`deviceId#reversedTimestamp`), salting e inversión de clave.
- La **replicación** entre clústeres es **eventualmente consistente** (multi-primaria). Un **app profile** selecciona el enrutamiento: **single-cluster routing** (da read-your-writes y soporte de transacciones a nivel de fila) frente a **multi-cluster routing** (failover automático, mayor disponibilidad, pero sin garantía de consistencia entre clústeres y sin read-modify-write de fila única).
- **Heurísticas de capacidad**: ~10.000 QPS por nodo para filas de 1 KB sobre SSD; 5 TB/nodo en SSD, 16 TB/nodo en HDD. Mantené la CPU media por debajo de ~70% (60% si hay replicación con margen para failover) y vigilá el **nodo más caliente**, no la media. El autoescalado apunta a una cifra de utilización de CPU.
- Interfaces: API compatible con HBase, `cbt`/`gcloud bigtable`, y es el motor de almacenamiento detrás de cargas estilo OpenTSDB/JanusGraph.
- SLA: 99.9% clúster único, 99.99% multi-cluster routing en una región, **99.999%** multi-cluster routing entre regiones.

**Usalo para:** series temporales/telemetría IoT, datos de tick financieros, perfiles de usuario de ad-tech, feature stores de personalización, adyacencia de grafos, backends de monitorización — cualquier cosa medida en TB-a-PB con tasas de escritura sostenidas altas y claves de acceso conocidas.

### 2.6 Firestore — documentos, tiempo real y móvil/web

Firestore es una base de datos documental con dos modos mutuamente excluyentes que se eligen **al crear la base de datos**:

| | **Native mode** | **Datastore mode** |
|---|---|---|
| Clientes | SDKs móviles/web con listeners en tiempo real y persistencia offline | Solo del lado del servidor |
| Consistencia | Fuerte | Fuerte |
| Seguridad | Firebase Security Rules (acceso directo desde el cliente) | Solo IAM |
| Mejor para | Apps de consumo, chat, UIs colaborativas, dashboards en vivo | Backends de servidor migrando desde App Engine Datastore |

Mecánica: documentos de hasta 1 MiB, indexación automática de campos individuales, **índices compuestos explícitos** necesarios para consultas multicampo (la consulta falla con un enlace para crear el índice — esto es por diseño y es el error más común de la primera semana). Las escrituras sostenidas a un *único documento* están limitadas a aproximadamente una por segundo; los errores de diseño de documento caliente / rango de índice caliente son el modo de fallo. Las rampas de tráfico deben seguir la **regla 500/50/5**: empezar en 500 ops/seg y luego aumentar un 50% cada 5 minutos, para que el backend pueda dividir rangos por delante tuyo. Las configuraciones multirregión llevan un SLA del **99.999%**; las regionales, 99.99%.

### 2.7 Memorystore — caching, explícitamente no duradero

Redis, Valkey y Memcached gestionados. Reglas de diseño:

- Es una **caché o un almacén efímero**, no un sistema de registro. Incluso con persistencia (RDB/AOF) y réplicas HA de nivel Standard, tratá los datos como reconstruibles.
- Nivel Standard = primario + réplica con failover automático; las **réplicas de lectura** pueden servir lecturas. Memorystore for Redis Cluster particiona horizontalmente para casos de varios TB y mayor throughput, con un SLA del 99.99%.
- La **política de expulsión** (`maxmemory-policy`) y el **margen de `maxmemory-gb`** son los dos parámetros que deciden si obtenés una caché o una caída. `noeviction` en una instancia llena convierte la presión de caché en errores de escritura en la aplicación.
- Patrones: cache-aside (read-through con TTL), almacén de sesiones, rate limiter, leaderboard (sorted sets), fan-out pub/sub para señalización no duradera.

### 2.8 BigQuery — la respuesta analítica

**Arquitectura.** BigQuery son cuatro sistemas desacoplados: **Dremel** (motor de ejecución en árbol de servicio multinivel), **Colossus** (almacenamiento, con el formato columnar **Capacitor**), **Jupiter** (red de datacenter de petabits que hace factible el shuffle a través del árbol) y **Borg** (orquestación). Como el almacenamiento y el cómputo están separados y se comunican por Jupiter, podés escanear un petabyte sin aprovisionar un clúster, y el almacenamiento cuesta lo mismo lo consultes o no.

Palancas operativas:

- **Modelo de precios/cómputo**: **on-demand** (facturado por TB escaneado) frente a **Editions** — Standard / Enterprise / Enterprise Plus — con **reservations** de **slots** (un slot es una unidad de CPU+RAM+red), **autoescalado** entre una línea base y un máximo, y compromisos de 1 o 3 años para descuentos. Editions más autoescalado es la elección estándar en producción porque acota el coste y aísla las cargas.
- **Particionado** (por hora de ingesta, una columna DATE/TIMESTAMP o un rango entero) poda los bytes escaneados; **`require_partition_filter`** es la barrera que impide que el `SELECT *` de un analista junior escanee cinco años. El **clustering** (hasta 4 columnas, el orden importa) ordena dentro de las particiones para podar más bloques.
- **Facturación de almacenamiento**: bytes lógicos frente a **bytes físicos (comprimidos)** — cambiar un dataset a facturación física suele recortar sustancialmente el coste de almacenamiento para datos que comprimen bien, a cambio de una tarifa por GB mayor.
- **Time travel** (2–7 días, 7 por defecto) más una ventana **fail-safe** de 7 días son tu vía de recuperación.
- **Ingesta en streaming**: la **Storage Write API** (exactly-once, más barata, la recomendación actual) sustituye a la antigua API de streaming `insertAll`.
- **BI Engine** es una capa de aceleración en memoria para dashboards subsegundo; las **vistas materializadas** se mantienen de forma incremental y el optimizador las sustituye automáticamente.
- **BigLake / tablas externas / Omni** consultan datos in situ en GCS, Amazon S3 o Azure Blob con gobernanza unificada — la respuesta para "no podemos mover los datos".
- **Analytics Hub** publica datasets como listings compartibles (sin copia) — la respuesta para "compartir datos con partners sin copiarlos".
- **BigQuery ML** entrena modelos con SQL; **Dataplex** aporta el plano de gobernanza/catálogo/linaje; **Looker / Looker Studio** la capa semántica y de BI.
- SLA: 99.99%.

> **Trampa de examen #3:** "Dashboard de analítica en streaming en tiempo real" es una pregunta de *pipeline*, no solo de almacenamiento: **Pub/Sub** (ingesta, desacoplamiento duradero) → **Dataflow** (Apache Beam, stream/batch unificado, ventanas y exactly-once) → **BigQuery** (analizar) → **Looker** (visualizar). Memorizá esa cadena; vale varias preguntas a lo largo del dominio.

### 2.9 Meter los datos — productos de migración e integración

| Necesidad | Producto | Mecanismo |
|---|---|---|
| Migración de BD homogénea o heterogénea con downtime mínimo (Oracle/SQL Server → PostgreSQL/AlloyDB; MySQL → Cloud SQL) | **Database Migration Service** | Replicación continua + cutover; conversión de esquema/código asistida por Gemini para el caso heterogéneo |
| Change data capture continuo hacia BigQuery/GCS | **Datastream** | CDC serverless desde Oracle, MySQL, PostgreSQL, SQL Server |
| Transferencia masiva de objetos desde S3/Azure/HTTP/on-prem a GCS | **Storage Transfer Service** | Gestionada, incremental, con limitación de ancho de banda, basada en agentes para on-prem |
| Transferencia offline de conjuntos de datos muy grandes (ancho de banda limitado o inexistente) | **Transfer Appliance** | Appliance físico enviable por transporte |
| ETL y ELT batch/stream | **Dataflow** (Beam) / **Dataproc** (Spark/Hadoop) / **Data Fusion** (visual, CDAP) / **Dataform** (ELT basado en SQL en BigQuery) | elegí según las capacidades del equipo: código Beam / Spark existente / no-code / SQL |
| Orquestación | **Cloud Composer** (Airflow gestionado) | Planificación de DAGs sobre lo anterior |
| Gobernanza, catálogo, linaje, calidad, data mesh | **Dataplex** (incl. Data Catalog) | Plano de metadatos sobre BigQuery + GCS |
| Backup consistente con la aplicación de VMs/BDs entre nubes | **Backup and DR Service** | Política centralizada, bóveda inmutable |

---

## 3. Tablas comparativas de compromisos

### 3.1 Bases de datos operativas (OLTP)

| Dimensión | Cloud SQL | AlloyDB | Spanner | Bigtable | Firestore | Memorystore |
|---|---|---|---|---|---|---|
| Modelo de datos | Relacional | Relacional (PG) | Relacional (GoogleSQL/PG) | Wide-column | Documental | Clave–valor / estructuras |
| Compatibilidad de motor | MySQL, PostgreSQL, SQL Server | Compatible a nivel de protocolo con PostgreSQL | Propio (interfaz PG) | API de HBase | Propietario + SDK de Firebase | Redis / Valkey / Memcached |
| Transacciones | ACID completo, instancia única | ACID completo, un primario | **ACID, entre filas, entre regiones, externamente consistente** | **Solo fila única** | ACID multi-documento (≤500 docs/txn) | Lua/MULTI, no duradero |
| Escalado de escritura | Vertical (un primario) | Primario vertical, almacenamiento desagregado por log | **Horizontal (añadir nodos/PU)** | **Horizontal (añadir nodos)** | **Horizontal (automático)** | Horizontal (Cluster) |
| Escalado de lectura | ≤10 réplicas de lectura asíncronas | Read pools (varias instancias × nodos), almacenamiento compartido | Réplicas read-only, lecturas stale | Clústeres replicados | Automático | Réplicas de lectura |
| Joins / SQL ad-hoc | Sí | Sí | Sí (condicionado por el diseño) | **No** | Consultas limitadas, sin joins | No |
| Consistencia entre regiones | Réplica asíncrona (retardo) | Réplicas entre regiones (asíncronas) | **Fuerte (externa)** | **Eventual** | Fuerte (multirregión) | n/a |
| p99 típico de lectura puntual | 1–10 ms | 1–5 ms (columnar para analítica) | 5–15 ms (fuerte), <5 ms (stale/local) | <10 ms | 10–50 ms | **<1 ms** |
| Techo práctico de tamaño | ~64 TB | Varios TB, crecimiento automático | **Petabytes** (10 TB/nodo) | **Petabytes** (5 TB/nodo SSD) | Petabytes | ~TB (limitado por RAM) |
| SLA (mejor configuración) | 99.95% / **99.99%** (Enterprise Plus) | **99.99%** (incl. mantenimiento) | **99.999%** | **99.999%** | **99.999%** | 99.9% / 99.99% (Cluster) |
| Coste de cambio de esquema | DDL nativo del motor, riesgo de bloqueos | Nativo del motor, operaciones con downtime casi nulo | Online, validado en segundo plano | Sin esquema por fila | Sin esquema | n/a |
| Riesgo principal | Techo vertical, el failover corta conexiones | Techo de escritura de un único primario | Hotspotting por claves monótonas, suelo de coste | Mal diseño de row key, sin joins | Documentos calientes, índices compuestos faltantes | Pérdida de datos (por diseño), expulsión |

### 3.2 Almacenes analíticos

| Dimensión | BigQuery | Motor columnar de AlloyDB | Bigtable + Dataflow | Réplica de lectura de Cloud SQL |
|---|---|---|---|---|
| Mejor para | Warehouse, lakehouse, escaneos de PB, BI, ML | Informes operativos sobre datos OLTP en vivo | Agregación en tiempo real sobre series temporales | Pequeña descarga de informes |
| Modelo de cómputo | Slots serverless (on-demand o reservations) | Adjunto a la instancia de AlloyDB | Nodos aprovisionados + workers de Dataflow | Del tamaño de la instancia |
| Frescura | De segundos (Storage Write API) a minutos | **Tiempo real — el mismo estado transaccional** | Segundos | Retardo de réplica |
| Concurrencia | Muy alta, aislada por reservation | Acotada por la instancia | Acotada por los nodos | Acotada por la réplica |
| Federación | GCS, S3, Azure (BigLake/Omni), Spanner, Bigtable, Cloud SQL | No | No | No |
| Factor de coste | Bytes escaneados **o** horas-slot + almacenamiento | Horas de instancia | Horas-nodo + pipeline | Horas de instancia |
| Antipatrón | Actualizaciones OLTP de fila única, búsquedas puntuales sub-100 ms | Escaneos históricos de petabytes | Exploración SQL ad-hoc | Cualquier analítica real a escala |

### 3.3 Semántica de consistencia — la tabla discriminadora

| Producto | Alcance de la atomicidad | Semántica de lectura | Comportamiento de escritura entre regiones |
|---|---|---|---|
| Spanner | Filas/tablas arbitrarias, cualquier región | Fuerte (por defecto) o stale acotada | Quórum Paxos síncrono; externamente consistente |
| Cloud SQL / AlloyDB | Toda la instancia | Fuerte en el primario; eventual en las réplicas | Asíncrono; el failover implica una posible ventana de pérdida de datos |
| Firestore | ≤500 documentos por transacción | Fuerte | Síncrono dentro de la configuración multirregión |
| Bigtable | **Una fila** | Read-your-writes solo con single-cluster routing | Eventual, multi-primaria; gana la última escritura por marca de tiempo |
| Cloud Storage | Un objeto | Fuerte read-after-write; listado fuertemente consistente | Asíncrono (dual-region turbo replication: SLO de RPO de 15 min) |
| Memorystore | Nodo/shard único | Fuerte en el primario; las réplicas pueden ir con retardo | n/a |
| BigQuery | Nivel de sentencia/job (DML ACID) | Aislamiento de snapshot, time travel | El dataset es regional; entre regiones requiere replicación/Omni |

---

## 4. Arquitectura de referencia como infraestructura completa en código

El escenario: una plataforma de retail. Los pedidos deben ser globalmente consistentes (Spanner). El catálogo de productos es una aplicación PostgreSQL de lift-and-shift con informes pesados (AlloyDB con un read pool). La telemetría de clickstream es una serie temporal de alto volumen (Bigtable). Las sesiones están cacheadas (Memorystore). Los medios y los archivos de eventos crudos viven en Cloud Storage con gobernanza de ciclo de vida. Todo aterriza en BigQuery para analítica. Las cargas corren sobre GKE con Workload Identity — **sin claves de cuenta de servicio en ninguna parte**.

### 4.1 Terraform — base de red y Private Service Access

```hcl
# ---------------------------------------------------------------------------
# versions.tf
# ---------------------------------------------------------------------------
terraform {
  required_version = ">= 1.7.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.12"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.12"
    }
  }

  backend "gcs" {
    bucket = "acme-retail-tfstate"
    prefix = "data-platform/prod"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

# ---------------------------------------------------------------------------
# variables.tf
# ---------------------------------------------------------------------------
variable "project_id" {
  description = "Target project for the data platform."
  type        = string
}

variable "region" {
  description = "Primary region for regional resources."
  type        = string
  default     = "europe-west1"
}

variable "secondary_region" {
  description = "Region used for DR replicas and dual-region storage."
  type        = string
  default     = "europe-west4"
}

variable "spanner_config" {
  description = "Spanner instance configuration. Multi-region for 99.999% SLA."
  type        = string
  default     = "eur5" # Netherlands + Belgium read-write, witness in a third zone set
}

variable "authorized_cidrs" {
  description = "Operator CIDRs permitted through the bastion path."
  type        = list(string)
  default     = []
}

locals {
  labels = {
    env        = "prod"
    system     = "retail-data-platform"
    managed_by = "terraform"
    cost_center = "retail-eng"
  }
}

# ---------------------------------------------------------------------------
# network.tf — VPC, subnets, and the PSA range consumed by Cloud SQL/AlloyDB
# ---------------------------------------------------------------------------
resource "google_compute_network" "data" {
  name                            = "vpc-data-prod"
  auto_create_subnetworks         = false
  routing_mode                    = "GLOBAL"
  delete_default_routes_on_create = false
}

resource "google_compute_subnetwork" "gke" {
  name                     = "snet-gke-${var.region}"
  ip_cidr_range            = "10.20.0.0/20"
  region                   = var.region
  network                  = google_compute_network.data.id
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "gke-pods"
    ip_cidr_range = "10.60.0.0/14"
  }

  secondary_ip_range {
    range_name    = "gke-services"
    ip_cidr_range = "10.64.0.0/20"
  }

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# Reserved range handed to the Google-managed producer VPC. Size it generously:
# it cannot be shrunk while services are attached, and every managed instance
# in the peering draws addresses from it.
resource "google_compute_global_address" "psa_range" {
  name          = "psa-managed-services"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  address       = "10.128.0.0"
  network       = google_compute_network.data.id
}

resource "google_service_networking_connection" "psa" {
  network                 = google_compute_network.data.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa_range.name]
}

# Export custom routes so managed instances can be reached from peered/on-prem
# networks reachable via this VPC.
resource "google_compute_network_peering_routes_config" "psa_routes" {
  peering              = google_service_networking_connection.psa.peering
  network              = google_compute_network.data.name
  import_custom_routes = true
  export_custom_routes = true
}

resource "google_compute_router" "nat" {
  name    = "cr-data-${var.region}"
  region  = var.region
  network = google_compute_network.data.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "nat-data-${var.region}"
  router                             = google_compute_router.nat.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
```

### 4.2 Terraform — Cloud SQL (HA, Enterprise Plus, solo privado)

```hcl
# ---------------------------------------------------------------------------
# cloudsql.tf
# ---------------------------------------------------------------------------
resource "google_sql_database_instance" "catalog_legacy" {
  # Instance names are tombstoned for ~1 week after deletion; suffix them.
  name                = "sql-catalog-prod-a1"
  database_version    = "POSTGRES_16"
  region              = var.region
  deletion_protection = true

  settings {
    tier              = "db-perf-optimized-N-8" # Enterprise Plus machine family
    edition           = "ENTERPRISE_PLUS"       # 99.99% SLA + data cache
    availability_type = "REGIONAL"              # synchronous standby in a 2nd zone
    disk_type         = "PD_SSD"
    disk_size         = 500
    disk_autoresize   = true
    disk_autoresize_limit = 4000

    data_cache_config {
      data_cache_enabled = true # local NVMe read cache
    }

    backup_configuration {
      enabled                        = true
      start_time                     = "02:00"
      location                       = var.region
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = 7

      backup_retention_settings {
        retained_backups = 30
        retention_unit   = "COUNT"
      }
    }

    ip_configuration {
      ipv4_enabled                                  = false # no public IP
      private_network                               = google_compute_network.data.id
      enable_private_path_for_google_cloud_services = true
      ssl_mode                                      = "ENCRYPTED_ONLY"
    }

    maintenance_window {
      day          = 7 # Sunday
      hour         = 3
      update_track = "stable"
    }

    insights_config {
      query_insights_enabled  = true
      query_string_length     = 4500
      record_application_tags = true
      record_client_address   = false
    }

    database_flags {
      name  = "cloudsql.iam_authentication"
      value = "on"
    }

    database_flags {
      name  = "log_min_duration_statement"
      value = "1000" # log statements slower than 1s
    }

    database_flags {
      name  = "max_connections"
      value = "800"
    }

    user_labels = local.labels
  }

  depends_on = [google_service_networking_connection.psa]

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_sql_database" "catalog" {
  name     = "catalog"
  instance = google_sql_database_instance.catalog_legacy.name
  charset  = "UTF8"
}

# Cross-region read replica: DR target and analytics offload.
resource "google_sql_database_instance" "catalog_replica_dr" {
  name                 = "sql-catalog-prod-a1-replica-ew4"
  database_version     = "POSTGRES_16"
  region               = var.secondary_region
  master_instance_name = google_sql_database_instance.catalog_legacy.name
  deletion_protection  = false

  replica_configuration {
    failover_target = false
  }

  settings {
    tier              = "db-perf-optimized-N-4"
    edition           = "ENTERPRISE_PLUS"
    availability_type = "ZONAL"
    disk_autoresize   = true

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.data.id
      ssl_mode        = "ENCRYPTED_ONLY"
    }

    user_labels = merge(local.labels, { role = "dr-replica" })
  }
}

# IAM database authentication: the GKE workload's Google SA becomes a DB user.
# No password is ever created, stored, or rotated.
resource "google_sql_user" "app_iam" {
  name     = trimsuffix(google_service_account.catalog_app.email, ".gserviceaccount.com")
  instance = google_sql_database_instance.catalog_legacy.name
  type     = "CLOUD_IAM_SERVICE_ACCOUNT"
}
```

### 4.3 Terraform — AlloyDB con un read pool

```hcl
# ---------------------------------------------------------------------------
# alloydb.tf
# ---------------------------------------------------------------------------
resource "google_alloydb_cluster" "catalog" {
  cluster_id = "alloydb-catalog-prod"
  location   = var.region
  network_config {
    network = google_compute_network.data.id
  }

  initial_user {
    user     = "postgres"
    password = google_secret_manager_secret_version.alloydb_root.secret_data
  }

  continuous_backup_config {
    enabled              = true
    recovery_window_days = 14
  }

  automated_backup_policy {
    location      = var.region
    backup_window = "3600s"
    enabled       = true

    weekly_schedule {
      days_of_week = ["MONDAY", "THURSDAY"]
      start_times {
        hours = 2
      }
    }

    quantity_based_retention {
      count = 20
    }
  }

  labels = local.labels

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_service_networking_connection.psa]
}

resource "google_alloydb_instance" "primary" {
  cluster       = google_alloydb_cluster.catalog.name
  instance_id   = "primary"
  instance_type = "PRIMARY"

  machine_config {
    cpu_count = 16
  }

  # Enable the columnar engine so operational reporting stays on the OLTP DB.
  database_flags = {
    "google_columnar_engine.enabled"      = "on"
    "google_columnar_engine.memory_size_in_mb" = "8192"
    "alloydb.enable_pgaudit"              = "on"
    "password.enforce_complexity"         = "on"
  }

  availability_type = "REGIONAL"
  labels            = local.labels
}

resource "google_alloydb_instance" "read_pool" {
  cluster       = google_alloydb_cluster.catalog.name
  instance_id   = "read-pool-analytics"
  instance_type = "READ_POOL"

  read_pool_config {
    node_count = 3
  }

  machine_config {
    cpu_count = 8
  }

  database_flags = {
    "google_columnar_engine.enabled" = "on"
  }

  labels = merge(local.labels, { role = "read-pool" })

  depends_on = [google_alloydb_instance.primary]
}
```

### 4.4 Terraform — Spanner (multirregión, autoescalado, PITR)

```hcl
# ---------------------------------------------------------------------------
# spanner.tf
# ---------------------------------------------------------------------------
resource "google_spanner_instance" "orders" {
  name         = "spanner-orders-prod"
  config       = var.spanner_config # eur5 => multi-region, 99.999% SLA
  display_name = "Retail Orders (multi-region)"

  autoscaling_config {
    autoscaling_limits {
      # Processing units: 1000 PU == 1 node. Start at 2000 PU, cap at 20000.
      min_processing_units = 2000
      max_processing_units = 20000
    }

    autoscaling_targets {
      # 45% for multi-region (leader work is remote); 65% is the
      # regional-configuration recommendation.
      high_priority_cpu_utilization_percent = 45
      storage_utilization_percent           = 90
    }
  }

  labels = local.labels

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_spanner_database" "orders" {
  instance = google_spanner_instance.orders.name
  name     = "orders"

  # PITR window. Costs storage; 7 days is the maximum.
  version_retention_period = "7d"

  database_dialect = "GOOGLE_STANDARD_SQL"

  ddl = [
    # Customers is the parent; Orders is INTERLEAVED so a customer's orders
    # live in the same split and the join is a local scan, not a distributed one.
    <<-EOT
    CREATE TABLE Customers (
      CustomerId   STRING(36) NOT NULL,
      Email        STRING(320) NOT NULL,
      DisplayName  STRING(200),
      CountryCode  STRING(2) NOT NULL,
      CreatedAt    TIMESTAMP NOT NULL OPTIONS (allow_commit_timestamp = true),
    ) PRIMARY KEY (CustomerId)
    EOT
    ,
    <<-EOT
    CREATE TABLE Orders (
      CustomerId    STRING(36) NOT NULL,
      OrderId       STRING(36) NOT NULL,
      Status        STRING(20) NOT NULL,
      CurrencyCode  STRING(3) NOT NULL,
      TotalMinor    INT64 NOT NULL,
      PlacedAt      TIMESTAMP NOT NULL OPTIONS (allow_commit_timestamp = true),
      UpdatedAt     TIMESTAMP NOT NULL OPTIONS (allow_commit_timestamp = true),
    ) PRIMARY KEY (CustomerId, OrderId),
      INTERLEAVE IN PARENT Customers ON DELETE CASCADE
    EOT
    ,
    <<-EOT
    CREATE TABLE OrderLines (
      CustomerId   STRING(36) NOT NULL,
      OrderId      STRING(36) NOT NULL,
      LineNo       INT64 NOT NULL,
      Sku          STRING(64) NOT NULL,
      Quantity     INT64 NOT NULL,
      UnitMinor    INT64 NOT NULL,
    ) PRIMARY KEY (CustomerId, OrderId, LineNo),
      INTERLEAVE IN PARENT Orders ON DELETE CASCADE
    EOT
    ,
    # Secondary index on a timestamp would hotspot on write. STORING makes it
    # a covering index; the shard key prefix spreads the write load across
    # splits so the "recent orders" query does not serialize on one leader.
    <<-EOT
    CREATE INDEX OrdersByStatusShard
      ON Orders (Status, PlacedAt DESC)
      STORING (TotalMinor, CurrencyCode)
    EOT
    ,
    # Row-deletion policy: Spanner garbage-collects expired rows in the
    # background, so no cron job is needed to prune history.
    <<-EOT
    CREATE TABLE OrderAuditLog (
      AuditId    STRING(36) NOT NULL,
      OrderId    STRING(36) NOT NULL,
      Actor      STRING(320),
      Action     STRING(40) NOT NULL,
      OccurredAt TIMESTAMP NOT NULL OPTIONS (allow_commit_timestamp = true),
    ) PRIMARY KEY (AuditId),
      ROW DELETION POLICY (OLDER_THAN(OccurredAt, INTERVAL 400 DAY))
    EOT
  ]

  deletion_protection = true
}

resource "google_spanner_database_iam_member" "app_rw" {
  instance = google_spanner_instance.orders.name
  database = google_spanner_database.orders.name
  role     = "roles/spanner.databaseUser"
  member   = "serviceAccount:${google_service_account.orders_app.email}"
}

# Scheduled backups, retained 35 days.
resource "google_spanner_backup_schedule" "orders_daily" {
  provider = google-beta
  instance = google_spanner_instance.orders.name
  database = google_spanner_database.orders.name
  name     = "daily-full"

  retention_duration = "3024000s" # 35 days

  spec {
    cron_spec {
      text = "0 1 * * *"
    }
  }

  full_backup_spec {}
}
```

### 4.5 Terraform — Bigtable (replicado, autoescalado, app profiles)

```hcl
# ---------------------------------------------------------------------------
# bigtable.tf
# ---------------------------------------------------------------------------
resource "google_bigtable_instance" "telemetry" {
  name          = "bt-telemetry-prod"
  deletion_protection = true

  # Two clusters in two regions with multi-cluster routing => 99.999% SLA.
  cluster {
    cluster_id   = "bt-telemetry-ew1-a"
    zone         = "${var.region}-b"
    storage_type = "SSD"

    autoscaling_config {
      min_nodes      = 3
      max_nodes      = 30
      cpu_target     = 60 # headroom for absorbing the other cluster's traffic
      storage_target = 4096 # GiB per node before scaling out
    }
  }

  cluster {
    cluster_id   = "bt-telemetry-ew4-a"
    zone         = "${var.secondary_region}-a"
    storage_type = "SSD"

    autoscaling_config {
      min_nodes      = 3
      max_nodes      = 30
      cpu_target     = 60
      storage_target = 4096
    }
  }

  labels = local.labels
}

# Serving profile: automatic failover, highest availability.
# Cost: no read-your-writes across clusters, no single-row read-modify-write.
resource "google_bigtable_app_profile" "serving" {
  instance       = google_bigtable_instance.telemetry.name
  app_profile_id = "serving-multi"

  multi_cluster_routing_use_any = true

  standard_isolation {
    priority = "PRIORITY_HIGH"
  }

  ignore_warnings = true
}

# Batch/ETL profile: pinned to one cluster so Dataflow scans never
# compete with the serving path, and single-row transactions are available.
resource "google_bigtable_app_profile" "batch" {
  instance       = google_bigtable_instance.telemetry.name
  app_profile_id = "batch-etl"

  single_cluster_routing {
    cluster_id                 = "bt-telemetry-ew4-a"
    allow_transactional_writes = true
  }

  standard_isolation {
    priority = "PRIORITY_LOW"
  }

  ignore_warnings = true
}

resource "google_bigtable_table" "device_events" {
  name          = "device_events"
  instance_name = google_bigtable_instance.telemetry.name

  # Row key contract (documented here because Bigtable cannot enforce it):
  #   <tenantId>#<deviceId>#<reverseTimestampMillis>
  # - tenantId + deviceId spread writes across tablets (no monotonic prefix)
  # - reverse timestamp puts the newest row first, so "latest N readings"
  #   is a prefix scan with a limit rather than a full-range sort.

  column_family {
    family = "metrics"
  }

  column_family {
    family = "meta"
  }

  # Split points pre-created so the first write burst does not hammer one tablet.
  split_keys = ["t01#", "t02#", "t03#", "t04#", "t05#", "t06#", "t07#"]

  change_stream_retention = "24h0m0s"

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_bigtable_gc_policy" "metrics_gc" {
  instance_name = google_bigtable_instance.telemetry.name
  table         = google_bigtable_table.device_events.name
  column_family = "metrics"

  gc_rules = jsonencode({
    mode = "union"
    rules = [
      { max_age = "2160h" },   # 90 days
      { max_version = 3 }
    ]
  })

  deletion_policy = "ABANDON"
}
```

### 4.6 Terraform — Memorystore, Cloud Storage, BigQuery

```hcl
# ---------------------------------------------------------------------------
# memorystore.tf
# ---------------------------------------------------------------------------
resource "google_redis_instance" "sessions" {
  name               = "redis-sessions-prod"
  tier               = "STANDARD_HA" # primary + replica, automatic failover
  memory_size_gb     = 26
  region             = var.region
  location_id        = "${var.region}-b"
  alternative_location_id = "${var.region}-c"

  redis_version      = "REDIS_7_2"
  connect_mode       = "PRIVATE_SERVICE_ACCESS"
  authorized_network = google_compute_network.data.id
  reserved_ip_range  = google_compute_global_address.psa_range.name

  auth_enabled            = true
  transit_encryption_mode = "SERVER_AUTHENTICATION"

  read_replicas_mode = "READ_REPLICAS_ENABLED"
  replica_count      = 2

  redis_configs = {
    # allkeys-lru: this is a CACHE. Never `noeviction` here — a full instance
    # would start returning OOM errors to the application instead of evicting.
    "maxmemory-policy"    = "allkeys-lru"
    "notify-keyspace-events" = "Ex"
  }

  persistence_config {
    persistence_mode    = "RDB"
    rdb_snapshot_period = "TWELVE_HOURS"
  }

  maintenance_policy {
    weekly_maintenance_window {
      day = "SUNDAY"
      start_time {
        hours   = 4
        minutes = 0
      }
    }
  }

  labels = local.labels
  depends_on = [google_service_networking_connection.psa]
}

# ---------------------------------------------------------------------------
# storage.tf
# ---------------------------------------------------------------------------

# Hot media: dual-region with turbo replication (15-min RPO SLO).
resource "google_storage_bucket" "media" {
  name                        = "${var.project_id}-media-prod"
  location                    = "EUR4" # dual-region: europe-north1 + europe-west4
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  custom_placement_config {
    data_locations = ["EUROPE-NORTH1", "EUROPE-WEST4"]
  }

  rpo = "ASYNC_TURBO"

  versioning {
    enabled = true
  }

  soft_delete_policy {
    retention_duration_seconds = 604800 # 7 days
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 3
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      age                = 30
      with_state         = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }

  labels = local.labels
}

# Raw event archive: Autoclass, so unpredictable access never incurs
# retrieval or early-deletion fees.
resource "google_storage_bucket" "event_archive" {
  name                        = "${var.project_id}-event-archive-prod"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  autoclass {
    enabled                = true
    terminal_storage_class = "ARCHIVE"
  }

  lifecycle_rule {
    condition {
      age = 2555 # ~7 years, the regulatory retention period
    }
    action {
      type = "Delete"
    }
  }

  labels = local.labels
}

# Compliance vault: retention policy that will be LOCKED. Once locked, the
# policy cannot be shortened or removed — by anyone, including project owners.
resource "google_storage_bucket" "compliance_vault" {
  name                        = "${var.project_id}-compliance-vault"
  location                    = var.region
  storage_class               = "ARCHIVE"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  retention_policy {
    is_locked        = true
    retention_period = 220752000 # 7 years in seconds
  }

  encryption {
    default_kms_key_name = google_kms_crypto_key.storage.id
  }

  labels = merge(local.labels, { compliance = "worm" })

  lifecycle {
    prevent_destroy = true
  }
}

# ---------------------------------------------------------------------------
# bigquery.tf
# ---------------------------------------------------------------------------
resource "google_bigquery_dataset" "analytics" {
  dataset_id                      = "retail_analytics"
  location                        = "EU" # multi-region; must match query jobs
  description                     = "Curated retail analytics marts."
  default_table_expiration_ms     = null
  default_partition_expiration_ms = null
  max_time_travel_hours           = 168 # 7 days
  storage_billing_model           = "PHYSICAL" # compressed-byte billing

  default_encryption_configuration {
    kms_key_name = google_kms_crypto_key.bigquery.id
  }

  labels = local.labels

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_bigquery_table" "fact_orders" {
  dataset_id          = google_bigquery_dataset.analytics.dataset_id
  table_id            = "fact_orders"
  deletion_protection = true

  # Partition on the event date; require a filter so no query can accidentally
  # scan the entire history.
  time_partitioning {
    type                     = "DAY"
    field                    = "placed_at"
    expiration_ms            = 94608000000 # 3 years
    require_partition_filter = true
  }

  # Cluster order matters: most-selective, most-frequently-filtered first.
  clustering = ["country_code", "channel", "sku"]

  schema = jsonencode([
    { name = "order_id",     type = "STRING",    mode = "REQUIRED" },
    { name = "customer_id",  type = "STRING",    mode = "REQUIRED" },
    { name = "placed_at",    type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "country_code", type = "STRING",    mode = "REQUIRED" },
    { name = "channel",      type = "STRING",    mode = "REQUIRED" },
    { name = "sku",          type = "STRING",    mode = "REQUIRED" },
    { name = "quantity",     type = "INT64",     mode = "REQUIRED" },
    { name = "total_minor",  type = "INT64",     mode = "REQUIRED" },
    { name = "currency",     type = "STRING",    mode = "REQUIRED" },
    {
      name = "shipping", type = "RECORD", mode = "NULLABLE",
      fields = [
        { name = "carrier", type = "STRING", mode = "NULLABLE" },
        { name = "eta",     type = "DATE",   mode = "NULLABLE" },
      ]
    },
  ])

  labels = local.labels
}

# Incrementally maintained materialized view; the optimizer substitutes it
# automatically for matching queries.
resource "google_bigquery_table" "mv_daily_revenue" {
  dataset_id          = google_bigquery_dataset.analytics.dataset_id
  table_id            = "mv_daily_revenue"
  deletion_protection = false

  materialized_view {
    query = <<-SQL
      SELECT
        DATE(placed_at)                AS order_date,
        country_code,
        channel,
        COUNT(*)                       AS orders,
        SUM(total_minor) / 100.0       AS revenue
      FROM `${var.project_id}.retail_analytics.fact_orders`
      GROUP BY order_date, country_code, channel
    SQL

    enable_refresh      = true
    refresh_interval_ms = 1800000 # 30 minutes
  }

  labels = local.labels
}

# Editions reservation: bounds cost and isolates workloads. Autoscaling adds
# slots above the baseline only when queued work justifies it.
resource "google_bigquery_reservation" "analytics" {
  name              = "res-analytics-eu"
  location          = "EU"
  edition           = "ENTERPRISE"
  slot_capacity     = 200   # baseline, always-on
  autoscale {
    max_slots = 1000        # ceiling for burst
  }
  ignore_idle_slots = false  # let other reservations borrow idle slots
  concurrency       = 0      # 0 = let BigQuery decide
}

resource "google_bigquery_reservation_assignment" "bi_workload" {
  location    = "EU"
  reservation = google_bigquery_reservation.analytics.id
  assignee    = "projects/${var.project_id}"
  job_type    = "QUERY"
}

# ---------------------------------------------------------------------------
# iam.tf — Workload Identity, least privilege, no keys
# ---------------------------------------------------------------------------
resource "google_service_account" "orders_app" {
  account_id   = "sa-orders-app"
  display_name = "Orders service (Spanner writer)"
}

resource "google_service_account" "catalog_app" {
  account_id   = "sa-catalog-app"
  display_name = "Catalog service (Cloud SQL / AlloyDB client)"
}

resource "google_project_iam_member" "catalog_sql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.catalog_app.email}"
}

resource "google_project_iam_member" "catalog_sql_iam_login" {
  project = var.project_id
  role    = "roles/cloudsql.instanceUser"
  member  = "serviceAccount:${google_service_account.catalog_app.email}"
}

# Bind the Kubernetes SA to the Google SA (Workload Identity Federation for GKE).
resource "google_service_account_iam_member" "orders_wi" {
  service_account_id = google_service_account.orders_app.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[retail/orders-api]"
}

resource "google_service_account_iam_member" "catalog_wi" {
  service_account_id = google_service_account.catalog_app.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[retail/catalog-api]"
}
```

### 4.7 Manifiestos de Kubernetes — la aplicación que lo consume todo

```yaml
# ---------------------------------------------------------------------------
# k8s/00-namespace-and-identity.yaml
# ---------------------------------------------------------------------------
apiVersion: v1
kind: Namespace
metadata:
  name: retail
  labels:
    app.kubernetes.io/part-of: retail-data-platform
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: catalog-api
  namespace: retail
  annotations:
    # Workload Identity: pods using this KSA obtain tokens for this Google SA.
    # No JSON key is ever mounted.
    iam.gke.io/gcp-service-account: sa-catalog-app@acme-retail-prod.iam.gserviceaccount.com
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: orders-api
  namespace: retail
  annotations:
    iam.gke.io/gcp-service-account: sa-orders-app@acme-retail-prod.iam.gserviceaccount.com
---
# ---------------------------------------------------------------------------
# k8s/10-catalog-config.yaml
# ---------------------------------------------------------------------------
apiVersion: v1
kind: ConfigMap
metadata:
  name: catalog-config
  namespace: retail
data:
  # The app connects to 127.0.0.1 — the Cloud SQL Auth Proxy sidecar terminates
  # locally and tunnels over mTLS. No database IP appears in app config.
  PGHOST: "127.0.0.1"
  PGPORT: "5432"
  PGDATABASE: "catalog"
  PGSSLMODE: "disable"          # the proxy already provides mTLS on the wire
  PGAPPNAME: "catalog-api"
  DB_POOL_MAX: "20"             # per pod; pods x pool <= instance max_connections
  DB_POOL_MIN: "2"
  DB_STATEMENT_TIMEOUT_MS: "8000"
  REDIS_HOST: "10.128.4.19"     # Memorystore PSA address
  REDIS_PORT: "6379"
  REDIS_TLS: "true"
  CACHE_TTL_SECONDS: "300"
---
# ---------------------------------------------------------------------------
# k8s/20-catalog-deployment.yaml
# ---------------------------------------------------------------------------
apiVersion: apps/v1
kind: Deployment
metadata:
  name: catalog-api
  namespace: retail
  labels:
    app.kubernetes.io/name: catalog-api
spec:
  replicas: 6
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 2
      maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: catalog-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: catalog-api
    spec:
      serviceAccountName: catalog-api
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: catalog-api
      containers:
        # ---- Application ------------------------------------------------
        - name: app
          image: europe-west1-docker.pkg.dev/acme-retail-prod/apps/catalog-api:1.42.0
          ports:
            - name: http
              containerPort: 8080
          envFrom:
            - configMapRef:
                name: catalog-config
          env:
            - name: REDIS_AUTH
              valueFrom:
                secretKeyRef:
                  name: redis-auth
                  key: auth-string
          resources:
            requests:
              cpu: "500m"
              memory: "512Mi"
            limits:
              memory: "1Gi"
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            initialDelaySeconds: 5
            periodSeconds: 5
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /livez
              port: http
            periodSeconds: 10
            failureThreshold: 6
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: tmp
              mountPath: /tmp

        # ---- Cloud SQL Auth Proxy sidecar --------------------------------
        # Declared as a native sidecar (restartPolicy: Always on an init
        # container) so it starts BEFORE the app and is terminated AFTER it.
        # With the old plain-container pattern the proxy could die first and
        # the app's in-flight transactions would fail during shutdown.
      initContainers:
        - name: cloud-sql-proxy
          restartPolicy: Always
          image: gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.14.1
          args:
            - "--structured-logs"
            - "--private-ip"
            - "--auto-iam-authn"
            - "--port=5432"
            - "--health-check"
            - "--http-address=0.0.0.0"
            - "--http-port=9801"
            - "--max-sigterm-delay=30s"
            - "--min-sigterm-delay=5s"
            - "acme-retail-prod:europe-west1:sql-catalog-prod-a1"
          ports:
            - name: proxy-health
              containerPort: 9801
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              memory: "256Mi"
          startupProbe:
            httpGet:
              path: /startup
              port: proxy-health
            periodSeconds: 1
            failureThreshold: 60
          livenessProbe:
            httpGet:
              path: /liveness
              port: proxy-health
            periodSeconds: 10
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /readiness
              port: proxy-health
            periodSeconds: 5
            failureThreshold: 3
          securityContext:
            runAsNonRoot: true
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
      volumes:
        - name: tmp
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: catalog-api
  namespace: retail
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: catalog-api
  ports:
    - name: http
      port: 80
      targetPort: http
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: catalog-api
  namespace: retail
spec:
  minAvailable: 4
  selector:
    matchLabels:
      app.kubernetes.io/name: catalog-api
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: catalog-api
  namespace: retail
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: catalog-api
  minReplicas: 6
  # Ceiling chosen so maxReplicas x DB_POOL_MAX (24 x 20 = 480) stays well
  # under the instance's max_connections=800, leaving room for the replica,
  # migrations, and operator sessions. An HPA that ignores the database's
  # connection budget converts a traffic spike into a connection-refused outage.
  maxReplicas: 24
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 65
---
# ---------------------------------------------------------------------------
# k8s/30-orders-deployment.yaml — Spanner client, no proxy needed
# ---------------------------------------------------------------------------
apiVersion: apps/v1
kind: Deployment
metadata:
  name: orders-api
  namespace: retail
spec:
  replicas: 8
  selector:
    matchLabels:
      app.kubernetes.io/name: orders-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: orders-api
    spec:
      serviceAccountName: orders-api
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: app
          image: europe-west1-docker.pkg.dev/acme-retail-prod/apps/orders-api:2.7.3
          ports:
            - name: http
              containerPort: 8080
          env:
            - name: SPANNER_PROJECT
              value: "acme-retail-prod"
            - name: SPANNER_INSTANCE
              value: "spanner-orders-prod"
            - name: SPANNER_DATABASE
              value: "orders"
            # Session pool: Spanner sessions are a per-node resource. Sizing
            # them too high across many pods exhausts the instance's session
            # limit; too low serializes requests behind session acquisition.
            - name: SPANNER_MIN_SESSIONS
              value: "25"
            - name: SPANNER_MAX_SESSIONS
              value: "100"
            # Read paths that tolerate staleness use a bounded-stale snapshot,
            # served by the nearest replica instead of the leader region.
            - name: SPANNER_READ_STALENESS_MS
              value: "10000"
            - name: GOOGLE_CLOUD_ENABLE_DIRECT_PATH
              value: "true"
          resources:
            requests:
              cpu: "750m"
              memory: "768Mi"
            limits:
              memory: "1536Mi"
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            periodSeconds: 5
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
```

---

## 5. CLI: comandos y salida real de terminal

### 5.1 Habilitar la plataforma e inspeccionar Cloud SQL

```console
$ gcloud config set project acme-retail-prod
Updated property [core/project].

$ gcloud services enable \
    sqladmin.googleapis.com \
    alloydb.googleapis.com \
    spanner.googleapis.com \
    bigtable.googleapis.com \
    bigtableadmin.googleapis.com \
    redis.googleapis.com \
    bigquery.googleapis.com \
    datastream.googleapis.com \
    servicenetworking.googleapis.com
Operation "operations/acat.p2-482913044517-8b1f0e3a-2c19-4d6d-9a11-7f0e2c8a4d31" finished successfully.

$ gcloud sql instances describe sql-catalog-prod-a1 \
    --format='table(name, databaseVersion, settings.edition, settings.tier,
                    settings.availabilityType, gceZone, secondaryGceZone, state)'
NAME                 DATABASE_VERSION  EDITION          TIER                   AVAILABILITY_TYPE  GCE_ZONE         SECONDARY_GCE_ZONE  STATE
sql-catalog-prod-a1  POSTGRES_16       ENTERPRISE_PLUS  db-perf-optimized-N-8  REGIONAL           europe-west1-b   europe-west1-c      RUNNABLE

$ gcloud sql instances describe sql-catalog-prod-a1 \
    --format='value(ipAddresses)'
{'ipAddress': '10.128.0.5', 'type': 'PRIVATE'}
```

Fijate en que no hay dirección pública `PRIMARY`: `ipv4_enabled = false` se sostuvo.

### 5.2 Ensayar el failover de Cloud SQL (este es el número sobre el que descansa tu RTO)

```console
$ date -u +%FT%TZ && gcloud sql instances failover sql-catalog-prod-a1 --async
2026-09-06T09:14:02Z
Failover in progress. Operation: projects/acme-retail-prod/operations/8e1a...c4
```

```console
$ gcloud sql operations wait 8e1a2f70-5d31-4c9b-9a02-1f77c4bb90c4 \
    --project acme-retail-prod
Waiting for [operations/8e1a2f70-...] to complete...done.
NAME                                  TYPE      START                     END                       ERROR  STATUS
8e1a2f70-5d31-4c9b-9a02-1f77c4bb90c4  FAILOVER  2026-09-06T09:14:03.114Z  2026-09-06T09:15:11.882Z  -      DONE
```

```console
$ gcloud sql instances describe sql-catalog-prod-a1 \
    --format='value(gceZone, secondaryGceZone)'
europe-west1-c  europe-west1-b
```

Las zonas se intercambiaron y el coste en tiempo de reloj fue de **68 segundos**. Durante esa ventana la aplicación registró resets de conexión — esperable, porque el failover de Cloud SQL no preserva las sesiones TCP. Verificá el comportamiento de reintento de la aplicación, no solo el estado de la instancia:

```console
$ kubectl -n retail logs deploy/catalog-api -c app --since=5m \
    | grep -c 'ECONNRESET\|connection terminated'
412

$ kubectl -n retail logs deploy/catalog-api -c app --since=5m \
    | grep -c 'FATAL\|unrecoverable'
0
```

412 reconexiones, cero errores irrecuperables: la ruta de reintento/backoff funciona. Si el segundo conteo hubiera sido distinto de cero, el failover habría sido una caída visible para el cliente, con SLA del 99.99% o sin él.

### 5.3 Spanner: estado de la instancia, una transacción e inspección de hotspots

```console
$ gcloud spanner instances describe spanner-orders-prod \
    --format='table(name.basename(), config.basename(), processingUnits, state)'
NAME                 CONFIG  PROCESSING_UNITS  STATE
spanner-orders-prod  eur5    2000              READY

$ gcloud spanner databases ddl describe orders --instance=spanner-orders-prod | head -20
CREATE TABLE Customers (
  CustomerId STRING(36) NOT NULL,
  Email STRING(320) NOT NULL,
  DisplayName STRING(200),
  CountryCode STRING(2) NOT NULL,
  CreatedAt TIMESTAMP NOT NULL OPTIONS (
    allow_commit_timestamp = true
  ),
) PRIMARY KEY(CustomerId);
CREATE TABLE Orders (
  CustomerId STRING(36) NOT NULL,
  OrderId STRING(36) NOT NULL,
  Status STRING(20) NOT NULL,
  CurrencyCode STRING(3) NOT NULL,
  TotalMinor INT64 NOT NULL,
  PlacedAt TIMESTAMP NOT NULL OPTIONS (
    allow_commit_timestamp = true
  ),
```

```console
$ gcloud spanner rows insert --instance=spanner-orders-prod --database=orders \
    --table=Customers \
    --data=CustomerId=8f2c1d0a-4b7e-4c11-9c2f-1a3b5d7e9f00,Email=ana@example.com,DisplayName='Ana R.',CountryCode=ES,CreatedAt='spanner.commit_timestamp()'
commitTimestamp: '2026-09-06T09:31:44.812993Z'
```

Una consulta explícita de solo lectura con staleness acotado — servida localmente, sin round trip al líder:

```console
$ gcloud spanner databases execute-sql orders \
    --instance=spanner-orders-prod \
    --read-timestamp=2026-09-06T09:31:00Z \
    --sql='SELECT CountryCode, COUNT(*) AS c FROM Customers GROUP BY CountryCode ORDER BY c DESC LIMIT 5'
CountryCode  c
ES           418223
FR           301774
DE           288910
NL           142055
BE            77318
```

Plan de consulta y atribución de CPU vía las tablas de sistema — así se encuentra la consulta que está quemando la instancia:

```console
$ gcloud spanner databases execute-sql orders --instance=spanner-orders-prod --sql="
SELECT
  text_fingerprint,
  SUBSTR(text, 0, 60) AS q,
  execution_count,
  ROUND(avg_latency_seconds * 1000, 2) AS avg_ms,
  ROUND(avg_cpu_seconds * 1000, 2)     AS avg_cpu_ms,
  avg_rows_scanned
FROM SPANNER_SYS.QUERY_STATS_TOP_MINUTE
ORDER BY avg_cpu_seconds * execution_count DESC
LIMIT 5"
text_fingerprint      q                                                             execution_count  avg_ms  avg_cpu_ms  avg_rows_scanned
-2298471039918842731  SELECT * FROM Orders WHERE Status = @status ORDER BY Pla       14028            186.44  91.03       210488.0
 7710338204411890013  SELECT o.OrderId, l.Sku FROM Orders o JOIN OrderLines l         9944             12.07   4.61          38.0
-4419028837710294411  SELECT TotalMinor FROM Orders WHERE CustomerId = @cid AN        812337            3.11   0.94           1.0
 1120038847710028841  INSERT INTO Orders (CustomerId, OrderId, Status, Currenc        409112            8.82   2.10           0.0
 6620194471029388441  SELECT COUNT(*) FROM OrderLines WHERE Sku = @sku                 1204          944.51  512.77      8804122.0
```

Dos hallazgos: la consulta principal escanea 210k filas por ejecución (índice ausente o no utilizado), y el escaneo de `OrderLines WHERE Sku` con 8,8 M de filas por ejecución es un escaneo de tabla completa sobre una columna que no es clave — eso pertenece a BigQuery o necesita un índice secundario.

Contención de bloqueos, el otro clásico de Spanner:

```console
$ gcloud spanner databases execute-sql orders --instance=spanner-orders-prod --sql="
SELECT
  row_range_start_key,
  lock_wait_seconds,
  sample_lock_requests
FROM SPANNER_SYS.LOCK_STATS_TOP_MINUTE
ORDER BY lock_wait_seconds DESC
LIMIT 3"
row_range_start_key                          lock_wait_seconds  sample_lock_requests
Orders(8f2c1d0a-4b7e-4c11-9c2f-1a3b5d7e9f00) 41.882             [{'lock_mode': 'WriterShared', 'column': 'Orders.Status'}]
OrdersByStatusShard('PENDING')               28.114             [{'lock_mode': 'WriterShared', 'column': 'Orders.Status'}]
Orders(0000-inventory-counter)                9.220             [{'lock_mode': 'WriterShared', 'column': 'Orders.TotalMinor'}]
```

La segunda fila es el diagnóstico que vale la pena interiorizar: `OrdersByStatusShard('PENDING')` muestra que cada pedido nuevo escribe en el mismo prefijo de clave de índice. El índice es un hotspot. La solución es una clave de índice particionada (`MOD(FARM_FINGERPRINT(OrderId), 32)` como columna inicial) o un índice sobre una columna naturalmente distribuida.

### 5.4 Bigtable: esquema, escritura, escaneo y detección de tablets calientes

```console
$ gcloud bigtable instances describe bt-telemetry-prod \
    --format='table(displayName, state)'
DISPLAY_NAME       STATE
bt-telemetry-prod  READY

$ gcloud bigtable clusters list --instances=bt-telemetry-prod \
    --format='table(name.basename(), zone.basename(), defaultStorageType, state)'
NAME                ZONE             DEFAULT_STORAGE_TYPE  STATE
bt-telemetry-ew1-a  europe-west1-b   SSD                   READY
bt-telemetry-ew4-a  europe-west4-a   SSD                   READY

$ cbt -instance=bt-telemetry-prod -app-profile=batch-etl \
    set device_events 't03#dev-8817#9223370552000000000' \
    metrics:temp_c=21.4 metrics:humidity=48 meta:fw=3.2.1

$ cbt -instance=bt-telemetry-prod -app-profile=batch-etl \
    read device_events prefix='t03#dev-8817#' count=2
----------------------------------------
t03#dev-8817#9223370552000000000
  meta:fw                                  @ 2026/09/06-09:44:12.310000
    "3.2.1"
  metrics:humidity                         @ 2026/09/06-09:44:12.310000
    "48"
  metrics:temp_c                           @ 2026/09/06-09:44:12.310000
    "21.4"
----------------------------------------
t03#dev-8817#9223370551940000000
  metrics:humidity                         @ 2026/09/06-09:43:12.104000
    "47"
  metrics:temp_c                           @ 2026/09/06-09:43:12.104000
    "21.3"
```

La marca de tiempo invertida hace que la fila más nueva ordene primero, así que `prefix + count=2` es un escaneo de prefijo acotado — no un escaneo de rango más una ordenación.

Detección de tablets calientes, el diagnóstico más valioso de Bigtable:

```console
$ gcloud bigtable hot-tablets list --cluster=bt-telemetry-ew1-a \
    --start-time=2026-09-06T08:00:00Z --end-time=2026-09-06T09:00:00Z \
    --format='table(tableName.basename(), startKey, endKey, nodeCpuUsagePercent)'
TABLE_NAME     START_KEY   END_KEY     NODE_CPU_USAGE_PERCENT
device_events  t01#        t01#dev-2   0.61
device_events  t07#dev-9   t08#        0.07
```

Un tablet que consume el 61% de la CPU de un nodo es un hotspot: el tenant `t01` está dominando. El remedio es un prefijo de clave más fino o una tabla/instancia dedicada para ese tenant.

CPU por nodo — la media esconde el problema, así que leé el máximo:

```console
$ gcloud monitoring time-series list \
    --filter='metric.type="bigtable.googleapis.com/cluster/cpu_load_hottest_node"
              AND resource.labels.instance="bt-telemetry-prod"' \
    --interval-end-time=2026-09-06T09:00:00Z \
    --interval-start-time=2026-09-06T08:00:00Z \
    --format='value(points[0].value.doubleValue)'
0.87
```

0,87 en el nodo más caliente con un objetivo de autoescalado de 0,60 significa que el autoescalado añadió nodos pero la *distribución* está mal — añadir nodos no puede arreglar un único tablet caliente, porque un tablet pertenece exactamente a un nodo. Esta es la lección: **los problemas de capacidad de Bigtable suelen ser problemas de diseño de clave.**

### 5.5 BigQuery: control de coste, poda de particiones y forense de slots

Dry-run antes de gastar — siempre, en CI:

```console
$ bq query --use_legacy_sql=false --dry_run \
  'SELECT country_code, SUM(total_minor)/100 AS revenue
   FROM `acme-retail-prod.retail_analytics.fact_orders`
   WHERE placed_at >= TIMESTAMP("2026-09-01")
   GROUP BY country_code'
Query successfully validated. Assuming the tables are not modified,
running this query will process 4823119872 bytes of data.
```

4,82 GB. Ahora la misma consulta sin el filtro de partición:

```console
$ bq query --use_legacy_sql=false --dry_run \
  'SELECT country_code, SUM(total_minor)/100 AS revenue
   FROM `acme-retail-prod.retail_analytics.fact_orders`
   GROUP BY country_code'
BigQuery error in query operation: Cannot query over table
'acme-retail-prod.retail_analytics.fact_orders' without a filter over
column(s) 'placed_at' that can be used for partition elimination.
```

`require_partition_filter` hizo su trabajo: se rechazó un escaneo de 1,4 TB, no se facturó. Este único ajuste de tabla es el control de coste de mayor apalancamiento en BigQuery.

```console
$ bq query --use_legacy_sql=false --maximum_bytes_billed=10000000000 \
  'SELECT country_code, channel, COUNT(*) AS orders, SUM(total_minor)/100 AS revenue
   FROM `acme-retail-prod.retail_analytics.fact_orders`
   WHERE placed_at >= TIMESTAMP("2026-09-01")
     AND country_code IN ("ES","FR")
   GROUP BY country_code, channel
   ORDER BY revenue DESC'
+--------------+--------+--------+-------------+
| country_code | channel| orders |   revenue   |
+--------------+--------+--------+-------------+
| ES           | web    | 418223 | 8842119.47  |
| FR           | web    | 301774 | 6120884.10  |
| ES           | mobile | 244019 | 4011772.85  |
| FR           | mobile | 188441 | 3097441.22  |
| ES           | store  |  91002 | 2884019.03  |
| FR           | store  |  70118 | 2011884.71  |
+--------------+--------+--------+-------------+
```

Contención de slots y los mayores consumidores, desde `INFORMATION_SCHEMA`:

```console
$ bq query --use_legacy_sql=false --nouse_cache '
SELECT
  user_email,
  job_id,
  ROUND(total_bytes_processed / POW(1024,4), 3) AS tib_processed,
  ROUND(total_slot_ms / 1000 / 3600, 2)         AS slot_hours,
  TIMESTAMP_DIFF(end_time, start_time, SECOND)  AS wall_s,
  reservation_id
FROM `region-eu`.INFORMATION_SCHEMA.JOBS_BY_PROJECT
WHERE creation_time > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 24 HOUR)
  AND job_type = "QUERY" AND state = "DONE"
ORDER BY total_slot_ms DESC
LIMIT 5'
+---------------------------+------------------------------+---------------+------------+--------+---------------------------------------+
|        user_email         |            job_id            | tib_processed | slot_hours | wall_s |            reservation_id             |
+---------------------------+------------------------------+---------------+------------+--------+---------------------------------------+
| dbt-runner@acme...         | bqjob_r4f1a09c2d8b1e7c_1     |        18.442 |     412.77 |   1840 | acme-retail-prod:EU.res-analytics-eu  |
| looker-sa@acme...          | bqjob_r7712bb0a4c19f001_1    |         2.108 |      61.04 |    212 | acme-retail-prod:EU.res-analytics-eu  |
| analyst.jm@acme...         | bqjob_r91c0ff2a771b0e44_1    |         1.884 |      48.19 |    904 | acme-retail-prod:EU.res-analytics-eu  |
| dbt-runner@acme...         | bqjob_r0a18cc4471bb0e12_1    |         0.771 |      19.88 |    141 | acme-retail-prod:EU.res-analytics-eu  |
| ml-pipeline@acme...        | bqjob_r6b120e8871cc0f31_1    |         0.402 |      11.02 |     94  | acme-retail-prod:EU.res-analytics-eu  |
+---------------------------+------------------------------+---------------+------------+--------+---------------------------------------+
```

Análisis de tiempo en cola — ¿la reservation está infradimensionada, o hay un job que mata de hambre al resto?

```console
$ bq query --use_legacy_sql=false '
SELECT
  TIMESTAMP_TRUNC(period_start, MINUTE) AS minute,
  SUM(period_slot_ms) / 1000 / 60       AS avg_slots_used,
  COUNTIF(job_id IS NOT NULL)           AS concurrent_jobs
FROM `region-eu`.INFORMATION_SCHEMA.JOBS_TIMELINE_BY_PROJECT
WHERE period_start > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 2 HOUR)
GROUP BY minute
ORDER BY avg_slots_used DESC
LIMIT 5'
+---------------------+----------------+-----------------+
|       minute        | avg_slots_used | concurrent_jobs |
+---------------------+----------------+-----------------+
| 2026-09-06 08:12:00 |         998.44 |              37 |
| 2026-09-06 08:13:00 |         999.81 |              41 |
| 2026-09-06 08:14:00 |         999.92 |              44 |
| 2026-09-06 08:11:00 |         961.07 |              29 |
| 2026-09-06 07:41:00 |         722.19 |              14 |
+---------------------+----------------+-----------------+
```

Clavado en el techo de autoescalado de 1000 slots durante cuatro minutos consecutivos con 44 jobs concurrentes: la reservation está saturada. La respuesta correcta *no* es automáticamente "subir `max_slots`" — es mover el job batch de `dbt-runner` a su propia reservation para que el BI interactivo nunca quede encolado detrás de una transformación de 412 horas-slot. Aislamiento de cargas antes que capacidad.

### 5.6 Cloud Storage: ciclo de vida, clases y verificación de coste

```console
$ gcloud storage buckets describe gs://acme-retail-prod-event-archive-prod \
    --format='yaml(name, location, locationType, storageClass, autoclass,
                   uniform_bucket_level_access, public_access_prevention)'
autoclass:
  enabled: true
  terminalStorageClass: ARCHIVE
  terminalStorageClassUpdateTime: '2026-03-11T10:02:41.118000+00:00'
  toggleTime: '2026-03-11T10:02:41.118000+00:00'
location: EUROPE-WEST1
locationType: region
name: acme-retail-prod-event-archive-prod
public_access_prevention: enforced
storageClass: STANDARD
uniform_bucket_level_access: true
```

Distribución de clases — verificá que la política está funcionando de verdad en lugar de confiar en que lo hace:

```console
$ gcloud storage ls -L --recursive gs://acme-retail-prod-event-archive-prod/2025/ \
    | awk '/Storage class:/ {print $3}' | sort | uniq -c
   1204 ARCHIVE
    881 COLDLINE
     92 NEARLINE
      7 STANDARD
```

Autoclass ha degradado los datos de 2025 como se pretendía. Comparalo con un bucket sin política:

```console
$ gcloud storage du --summarize --readable-sizes gs://acme-retail-prod-media-prod
14.72TiB     gs://acme-retail-prod-media-prod

$ gcloud storage buckets describe gs://acme-retail-prod-media-prod \
    --format='value(rpo)'
ASYNC_TURBO
```

Confirmá que el bloqueo de la bóveda de cumplimiento es real — esto es un control auditable:

```console
$ gcloud storage buckets describe gs://acme-retail-prod-compliance-vault \
    --format='yaml(retentionPolicy)'
retentionPolicy:
  effectiveTime: '2026-02-02T08:11:22.918000+00:00'
  isLocked: true
  retentionPeriod: '220752000'

$ gcloud storage rm gs://acme-retail-prod-compliance-vault/2026/02/ledger-0001.json
Removing objects:
ERROR: [gs://acme-retail-prod-compliance-vault/2026/02/ledger-0001.json]
403 Object 'ledger-0001.json' is subject to bucket's retention policy or
object retention settings and cannot be deleted or overwritten until
2033-02-02T08:11:22.918Z
```

El 403 es el control funcionando. Una política de retención bloqueada no puede acortarse ni eliminarse por nadie, incluido un administrador de la organización — que es precisamente por lo que satisface los requisitos WORM y por lo que tenés que estar seguro del período antes de bloquearla.

### 5.7 AlloyDB y Memorystore

```console
$ gcloud alloydb clusters describe alloydb-catalog-prod --region=europe-west1 \
    --format='table(name.basename(), state, databaseVersion,
                    continuousBackupConfig.recoveryWindowDays)'
NAME                  STATE  DATABASE_VERSION  RECOVERY_WINDOW_DAYS
alloydb-catalog-prod  READY  POSTGRES_16       14

$ gcloud alloydb instances list --cluster=alloydb-catalog-prod --region=europe-west1 \
    --format='table(name.basename(), instanceType, state, ipAddress,
                    machineConfig.cpuCount, readPoolConfig.nodeCount)'
NAME                  INSTANCE_TYPE  STATE  IP_ADDRESS   CPU_COUNT  NODE_COUNT
primary               PRIMARY        READY  10.128.8.2   16         -
read-pool-analytics   READ_POOL      READY  10.128.8.9   8          3
```

Verificá que el motor columnar está poblado (si no, estás pagando RAM y seguís haciendo escaneos por filas):

```console
$ psql "host=10.128.8.2 user=postgres dbname=catalog sslmode=require" -c "
SELECT relation_name, columnar_unit_count,
       pg_size_pretty(size_in_bytes) AS size, status
FROM g_columnar_relations
ORDER BY size_in_bytes DESC LIMIT 5;"
 relation_name   | columnar_unit_count |  size   | status
-----------------+---------------------+---------+--------
 order_items     |                 184 | 2841 MB | Usable
 products        |                  31 |  412 MB | Usable
 price_history      |               22 |  288 MB | Usable
 inventory_snapshots|                9 |   94 MB | Usable
 categories      |                   1 |  1088 kB| Usable
(5 rows)
```

```console
$ gcloud redis instances describe redis-sessions-prod --region=europe-west1 \
    --format='table(name.basename(), tier, memorySizeGb, state, host, port,
                    replicaCount, readEndpoint)'
NAME                 TIER         MEMORY_SIZE_GB  STATE  HOST        PORT  REPLICA_COUNT  READ_ENDPOINT
redis-sessions-prod  STANDARD_HA  26              READY  10.128.4.19 6379  2              10.128.4.22

$ redis-cli -h 10.128.4.19 --tls --insecure -a "$REDIS_AUTH" INFO stats \
    | grep -E 'keyspace_hits|keyspace_misses|evicted_keys|expired_keys'
keyspace_hits:1884219044
keyspace_misses:41028811
evicted_keys:0
expired_keys:88104221
```

Ratio de aciertos = 1.884.219.044 / (1.884.219.044 + 41.028.811) = **97,87%**, con cero expulsiones. La caché está correctamente dimensionada: las claves salen por expiración de TTL, no por presión de memoria. Un `evicted_keys` distinto de cero con un ratio de aciertos cayendo es la señal para agrandar la instancia o acortar los TTL — y si alguna vez ves `OOM command not allowed when used memory > 'maxmemory'` en los logs de la aplicación, alguien puso `noeviction` en una caché.

### 5.8 Datastream: CDC desde la base de datos OLTP hacia BigQuery

```console
$ gcloud datastream streams describe catalog-to-bq --location=europe-west1 \
    --format='yaml(displayName, state, sourceConfig.postgresqlSourceConfig.publication,
                   destinationConfig.bigqueryDestinationConfig.dataFreshness)'
destinationConfig:
  bigqueryDestinationConfig:
    dataFreshness: 900s
displayName: catalog-to-bq
sourceConfig:
  postgresqlSourceConfig:
    publication: datastream_pub
state: RUNNING

$ gcloud datastream streams list --location=europe-west1 \
    --format='table(name.basename(), state, updateTime)'
NAME            STATE     UPDATE_TIME
catalog-to-bq   RUNNING   2026-09-06T09:02:11.884Z
orders-to-bq    RUNNING   2026-09-06T09:02:44.109Z
```

La frescura de la replicación debe verificarse contra los *datos*, no contra el estado del stream:

```console
$ bq query --use_legacy_sql=false '
SELECT
  MAX(datastream_metadata.source_timestamp) AS last_source_event,
  TIMESTAMP_DIFF(CURRENT_TIMESTAMP(),
                 MAX(datastream_metadata.source_timestamp), SECOND) AS lag_seconds
FROM `acme-retail-prod.raw_catalog.public_products`'
+---------------------------+-------------+
|     last_source_event     | lag_seconds |
+---------------------------+-------------+
| 2026-09-06 09:47:12 UTC   |         143 |
+---------------------------+-------------+
```

143 s frente a un objetivo de frescura de 900 s: saludable. Un stream `RUNNING` con `lag_seconds` creciente suele significar contrapresión del replication slot en el origen — revisá `pg_replication_slots.confirmed_flush_lsn` antes de culpar a Datastream.

---

## 6. Verificación y diagnóstico de fallos

### 6.1 Escalera de verificación — ejecutá esto antes de declarar lista una plataforma de datos

```console
# 1. No managed database is reachable from the internet.
$ gcloud sql instances list --format='value(name, ipAddresses.filter("type=PRIMARY"))'
sql-catalog-prod-a1
sql-catalog-prod-a1-replica-ew4
# (empty second column == no public IP; a value here is a finding)

# 2. Every bucket denies public access and enforces uniform IAM.
$ gcloud storage buckets list \
    --format='table(name, iamConfiguration.publicAccessPrevention,
                    iamConfiguration.uniformBucketLevelAccess.enabled)'
NAME                                  PUBLIC_ACCESS_PREVENTION  ENABLED
acme-retail-prod-compliance-vault     enforced                  True
acme-retail-prod-event-archive-prod   enforced                  True
acme-retail-prod-media-prod           enforced                  True

# 3. No service-account keys exist (Workload Identity only).
$ for sa in $(gcloud iam service-accounts list --format='value(email)'); do
    n=$(gcloud iam service-accounts keys list --iam-account="$sa" \
          --managed-by=user --format='value(name)' | wc -l)
    [ "$n" -gt 0 ] && echo "FINDING: $sa has $n user-managed key(s)"
  done
# (no output == pass)

# 4. Deletion protection is on for every stateful resource.
$ gcloud sql instances describe sql-catalog-prod-a1 --format='value(settings.deletionProtectionEnabled)'
True
$ gcloud spanner databases describe orders --instance=spanner-orders-prod --format='value(enableDropProtection)'
True

# 5. Backups actually completed recently — not merely "configured".
$ gcloud sql backups list --instance=sql-catalog-prod-a1 --limit=3 \
    --format='table(id, windowStartTime, type, status)'
ID            WINDOW_START_TIME         TYPE       STATUS
1757144400000 2026-09-06T02:00:00.000Z  AUTOMATED  SUCCESSFUL
1757058000000 2026-09-05T02:00:00.000Z  AUTOMATED  SUCCESSFUL
1756971600000 2026-09-04T02:00:00.000Z  AUTOMATED  SUCCESSFUL

$ gcloud spanner backups list --instance=spanner-orders-prod --limit=2 \
    --format='table(name.basename(), state, sizeBytes, expireTime)'
NAME                    STATE  SIZE_BYTES     EXPIRE_TIME
daily-full-20260906010  READY  418223994112   2026-10-11T01:00:00Z
daily-full-20260905010  READY  411882004480   2026-10-10T01:00:00Z

# 6. PITR windows are what the RPO promises.
$ gcloud spanner databases describe orders --instance=spanner-orders-prod \
    --format='value(versionRetentionPeriod, earliestVersionTime)'
7d  2026-08-30T09:52:11.418Z
```

### 6.2 Una restauración no está probada hasta que se realiza

Los backups que nunca se han restaurado son una creencia, no un control. Ensayalos trimestralmente:

```console
$ gcloud sql instances clone sql-catalog-prod-a1 sql-catalog-drill-20260906 \
    --point-in-time='2026-09-06T06:00:00.000Z'
Cloning Cloud SQL instance...done.
Created [https://sqladmin.googleapis.com/sql/v1beta4/projects/acme-retail-prod/instances/sql-catalog-drill-20260906].

$ gcloud sql instances describe sql-catalog-drill-20260906 --format='value(state)'
RUNNABLE

$ psql "host=10.128.0.31 user=drill dbname=catalog sslmode=require" -c \
    "SELECT COUNT(*) AS rows, MAX(updated_at) AS newest FROM products;"
  rows   |             newest
---------+-------------------------------
 4881204 | 2026-09-06 05:59:58.114882+00

$ gcloud sql instances delete sql-catalog-drill-20260906 --quiet
Deleted [https://sqladmin.googleapis.com/sql/v1beta4/projects/acme-retail-prod/instances/sql-catalog-drill-20260906].
```

`newest` queda justo por debajo de la marca de tiempo de PITR solicitada: la restauración aterrizó en el punto en el tiempo previsto. Registrá la **duración en tiempo de reloj** del clonado — eso, y no la existencia del backup, es tu RTO.

### 6.3 Catálogo de fallos — síntoma → sonda → causa raíz → remediación

| Síntoma | Sonda | Causa raíz probable | Remediación |
|---|---|---|---|
| App: `could not connect to server: Connection timed out` contra la IP privada de Cloud SQL | `gcloud compute networks peerings list --network=vpc-data-prod`; revisar la exportación de rutas | Falta el peering de PSA, o las rutas personalizadas no se exportan a la red peered/on-prem | Crear `google_service_networking_connection`; poner `export_custom_routes = true` |
| Sidecar del proxy: `failed to get instance: googleapi: Error 403: Cloud SQL Admin API has not been used` | `gcloud services list --enabled \| grep sqladmin` | `sqladmin.googleapis.com` deshabilitada | Habilitar la API; ojo: el proxy necesita la API *Admin* incluso para conexiones del plano de datos |
| Proxy: `Refusing to connect; missing IAM permission cloudsql.instances.connect` | `gcloud projects get-iam-policy` para la SA de Google | Falta el binding de Workload Identity KSA→GSA o el rol `roles/cloudsql.client` | Añadir `roles/iam.workloadIdentityUser` sobre la GSA para `PROJECT.svc.id.goog[ns/ksa]`, más `roles/cloudsql.client` |
| `FATAL: remaining connection slots are reserved` | `SELECT count(*) FROM pg_stat_activity;` frente a `max_connections` | `maxReplicas` del HPA × pool por pod supera el presupuesto de la instancia | Reducir el pool, añadir un pooler (PgBouncer), o subir `max_connections` con la RAM acorde |
| El retardo de la réplica de lectura de Cloud SQL crece sin límite | `SELECT EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()));` | Transacción larga en el primario, réplica infradimensionada, o cuello de botella de apply monohilo | Dimensionar la réplica ≥ primario; matar transacciones largas; en MySQL habilitar replicación paralela |
| La latencia p99 de Spanner se duplica con QPS plano | `SPANNER_SYS.LOCK_STATS_TOP_MINUTE`, Key Visualizer | Hotspot en una clave monótona o en un prefijo de índice | Invertir bits/hashear la columna inicial de la clave; particionar el índice; presplit |
| Spanner `ABORTED: Transaction was aborted due to ... lock conflict` | Peticiones de muestra de `LOCK_STATS_TOP_MINUTE` | Transacción read-write manteniendo bloqueos demasiado tiempo; read-modify-write sobre una fila con contención | Acortar transacciones; sacar las lecturas fuera de la transacción RW usando una lectura stale; usar escrituras ciegas donde sea seguro |
| Spanner `RESOURCE_EXHAUSTED: The transaction contains too many mutations` | contar mutaciones en el lote | >80.000 mutaciones por commit | Trocear el lote (y recordar que cada índice secundario multiplica las mutaciones) |
| Picos de p99 en Bigtable mientras la CPU media es baja | `gcloud bigtable hot-tablets list`; `cpu_load_hottest_node` | Tablet caliente — un nodo posee el rango de claves ocupado | Rediseñar la row key; presplit; salar el prefijo. Añadir nodos *no* ayudará |
| Bigtable: las lecturas no ven datos recién escritos | revisar el app profile en uso | El multi-cluster routing no da read-your-writes entre clústeres | Usar single-cluster routing para la ruta de read-after-write, o leer del clúster donde se escribió |
| Firestore: `FAILED_PRECONDITION: The query requires an index` | el mensaje de error contiene una URL de creación de índice | Falta el índice compuesto para una consulta multicampo | Añadir el índice compuesto (Terraform `google_firestore_index`), no un apaño en el código |
| El throughput de escritura de Firestore se estanca y la latencia sube durante un lanzamiento | revisar la rampa de ops/seg | Regla 500/50/5 violada; el backend no tuvo tiempo de dividir rangos | Rampa: 500 ops/seg, +50% cada 5 min. Precalentar antes de la campaña |
| BigQuery `Quota exceeded: Your project exceeded quota for free query bytes scanned` o una factura sorpresa | `INFORMATION_SCHEMA.JOBS_BY_PROJECT` ordenado por `total_bytes_billed` | Escaneos sin particionar/sin filtro; `SELECT *` en una herramienta de BI | `require_partition_filter`, clustering, `--maximum_bytes_billed`, cuotas personalizadas, pasar a reservations de Editions |
| Los dashboards interactivos de BigQuery se ponen lentos de repente | Uso de slots por minuto en `JOBS_TIMELINE_BY_PROJECT` | Reservation saturada; un job batch monopolizando slots | Reservations separadas por carga; asignar los jobs batch a la suya; habilitar techo de autoescalado |
| BigQuery `Not found: Dataset ... was not found in location EU` | `bq show --format=prettyjson dataset` | Ubicación del job ≠ ubicación del dataset; los datasets están ligados a una ubicación y no se pueden unir entre regiones | Ejecutar el job en la ubicación del dataset; replicar el dataset o usar replicación de dataset entre regiones |
| Memorystore: `OOM command not allowed when used memory > 'maxmemory'` | `redis-cli INFO memory`; `CONFIG GET maxmemory-policy` | `noeviction` en una caché, o instancia infradimensionada | Poner `allkeys-lru`; aumentar `memory_size_gb`; auditar TTLs |
| El ratio de aciertos de Memorystore se desploma tras un evento de mantenimiento | `INFO stats`, eventos de la instancia | El failover/reinicio vació la caché (o se promovió una réplica fría) | Calentar la caché al arrancar; asegurar que la app degrada con gracia hacia la base de datos en vez de estampidarla |
| GCS: cargos inesperados de `Early delete` y `Class B operation` | Export de facturación agrupado por SKU | Objetos transicionados o borrados antes de la duración mínima de clase | Usar **Autoclass** (sin tarifas de borrado anticipado/recuperación) o alinear las edades de ciclo de vida con los mínimos de 30/90/365 días |
| GCS `403 ... retention policy` en un borrado legítimo | `buckets describe --format='yaml(retentionPolicy)'` | Política de retención bloqueada — irreversible por diseño | Nada que hacer hasta que expire; esto es el control funcionando. Planificá el período antes de bloquear |
| Objeto borrado por error, versionado desactivado | `gcloud storage ls --soft-deleted gs://bucket/prefix` | La ventana de soft delete sigue abierta | `gcloud storage restore`; después habilitar versionado |
| Una consulta analítica de AlloyDB sigue escaneando por filas | `SELECT * FROM g_columnar_relations;` y `EXPLAIN` | El motor columnar no está poblado para esa relación, o la memoria es insuficiente | Añadir la relación al almacén columnar; subir `google_columnar_engine.memory_size_in_mb` |
| Stream de Datastream en `RUNNING` pero datos obsoletos | `pg_replication_slots`, retardo de `source_timestamp` en BigQuery | Contrapresión del replication slot, o un cambio de DDL no soportado por el stream | Resolver el retardo del slot en el origen; re-backfillear el objeto afectado |

### 6.4 Instrumentación de SLO que vale la pena tener desde el primer día

```console
$ gcloud alpha monitoring policies list \
    --format='table(displayName, enabled, conditions[0].displayName)'
DISPLAY_NAME                          ENABLED  CONDITION
Cloud SQL replica lag > 60s           True     cloudsql.googleapis.com/database/replication/replica_lag
Cloud SQL connections > 80% of max    True     cloudsql.googleapis.com/database/postgresql/num_backends
Spanner high-priority CPU > 65%       True     spanner.googleapis.com/instance/cpu/utilization_by_priority
Spanner storage > 85% of limit        True     spanner.googleapis.com/instance/storage/utilization
Bigtable hottest node CPU > 80%       True     bigtable.googleapis.com/cluster/cpu_load_hottest_node
Bigtable replication latency > 5m     True     bigtable.googleapis.com/replication/latency
BigQuery reservation slots pinned     True     bigquery.googleapis.com/slots/allocated_for_reservation
Memorystore evicted keys > 0          True     redis.googleapis.com/stats/evicted_keys
Memorystore memory usage ratio > 0.8  True     redis.googleapis.com/stats/memory/usage_ratio
GCS bucket total bytes anomaly        True     storage.googleapis.com/storage/total_bytes
```

Fijate en qué métricas son de *distribución* en lugar de medias: `cpu_load_hottest_node` para Bigtable y `cpu/utilization_by_priority` para Spanner existen precisamente porque la media es engañosa en un sistema particionado.

---

## 7. Modelo de costes y la economía detrás de la elección

La selección es solo la mitad del objetivo; un leader debe ser capaz de defender la economía unitaria.

| Producto | Principales factores de coste | Palanca de optimización dominante | Desperdicio común |
|---|---|---|---|
| Cloud Storage | GB-mes por clase, egress de red, operaciones (Clase A/B), recuperación | Ciclo de vida/Autoclass en la creación del bucket; mantener el cómputo en la misma región que los datos | Clase Standard para siempre; lecturas entre regiones; churn por objeto generando operaciones de Clase A |
| Cloud SQL | Horas de vCPU+RAM, GB de disco, la HA duplica el cómputo, almacenamiento de backups, egress | Dimensionar bien, descuentos por uso comprometido, apagar no-producción fuera de horario | HA en no-producción; discos sobredimensionados (el disco no se puede encoger) |
| AlloyDB | vCPU+RAM por instancia (primario + cada nodo del read pool), almacenamiento, backups | Escalar el read pool a la demanda; motor columnar para evitar un warehouse aparte | Read pool dimensionado para el pico 24/7 |
| Spanner | Processing units/nodos, GB de almacenamiento, red para multirregión, backups | Autoescalador con granularidad de PU; lecturas stale para evitar tráfico al líder | Aprovisionar nodos para una carga que Cloud SQL podría servir |
| Bigtable | Horas-nodo por clúster (la replicación multiplica), GB de almacenamiento (SSD vs HDD) | Autoescalado con un objetivo de CPU correcto; HDD para datos fríos con muchos escaneos | Clústeres replicados dimensionados idénticamente para el pico; SSD para archivado |
| Firestore | Lecturas/escrituras/borrados de documentos, almacenamiento, egress | Forma de las consultas — menos lecturas, desnormalizadas; empaquetar datos estáticos | Patrones de lectura N+1 desde clientes móviles |
| Memorystore | GB-hora aprovisionados por nodo/réplica | Dimensionar al working set, no al dataset total | Tratarlo como sistema de registro y sobreaprovisionar buscando durabilidad |
| BigQuery | Bytes escaneados on-demand **o** horas-slot; almacenamiento (lógico vs físico); streaming | Particionar + clusterizar + `require_partition_filter`; Editions con autoescalado; facturación de almacenamiento físico; vistas materializadas | `SELECT *`; tablas sin particionar; consultas programadas que nadie lee |

**La idea estructural:** la separación entre almacenamiento y cómputo de BigQuery hace que los datos analíticos inactivos sean casi gratis, mientras que una instancia inactiva de Cloud SQL/AlloyDB/Spanner/Bigtable factura continuamente por capacidad aprovisionada. Esa asimetría — y no la sintaxis de las consultas — es la razón real por la que los datos históricos fríos pertenecen a BigQuery o a Cloud Storage y no a la base de datos operativa.

---

## 8. Mapeo orientado al examen: caso de uso de negocio → producto

| Caso de uso de negocio (tal como lo formula el examen) | Respuesta | Frase discriminante |
|---|---|---|
| Almacenar fotos y vídeos subidos por usuarios, servirlos globalmente | Cloud Storage | "no estructurado", "objetos", "medios" |
| Archivo regulatorio inmutable de 7 años, lo más barato posible | Cloud Storage Archive + política de retención bloqueada | "cumplimiento", "acceso poco frecuente", "inmutable" |
| Lift-and-shift de una base de datos MySQL de e-commerce on-prem | Cloud SQL | "existente", "cambios mínimos", "MySQL/PostgreSQL/SQL Server" |
| Migrar Oracle a un motor open-source con menos downtime | Database Migration Service → AlloyDB / Cloud SQL for PostgreSQL | "heterogéneo", "Oracle", "reducir licencias" |
| App PostgreSQL que necesita mucho más throughput y 99.99%, más informes sobre datos en vivo | AlloyDB | "compatible con PostgreSQL", "HTAP", "transacciones 4× más rápidas" |
| Libro mayor bancario global, fuertemente consistente entre continentes, cinco nueves | Spanner | "global", "consistencia fuerte", "relacional", "escalado horizontal", "99.999%" |
| Inventario en 40 países con una única vista consistente y SQL | Spanner | "vista global única", "consistente", "SQL" |
| Plataforma IoT ingiriendo millones de lecturas de sensores por segundo | Bigtable | "serie temporal", "alto throughput de escritura", "TB–PB", "baja latencia", "búsquedas por clave" |
| Almacén de perfiles de usuario de ad-tech para personalización en tiempo real | Bigtable | "milisegundos de un dígito", "enorme", "sin joins" |
| App móvil con sincronización en tiempo real y soporte offline | Firestore (Native mode) | "SDK móvil/web", "tiempo real", "offline" |
| Almacén documental serverless de backend para una web, solo del lado del servidor | Firestore (Datastore mode) | "documento", "lado del servidor", "legado de App Engine" |
| Almacén de sesiones / leaderboard / caché submilisegundo | Memorystore | "caché", "en memoria", "submilisegundo" |
| Data warehouse a escala de petabytes para BI y analítica SQL ad-hoc | BigQuery | "analítica", "warehouse", "SQL sobre conjuntos de datos enormes", "serverless" |
| Analizar datos que ya están en Amazon S3 sin moverlos | BigQuery Omni / BigLake | "in situ", "multinube", "evitar egress" |
| Compartir un dataset curado con partners sin copiarlo | Analytics Hub | "compartir", "intercambio", "sin duplicación" |
| Pipeline de clickstream en tiempo real hacia un dashboard | Pub/Sub → Dataflow → BigQuery → Looker | "streaming", "tiempo real", "ingerir y transformar" |
| Jobs Spark/Hadoop existentes movidos a la nube tal cual | Dataproc | "Spark", "Hadoop", "jobs existentes" |
| ETL construido por analistas sin escribir código | Cloud Data Fusion | "visual", "no-code", "pipelines gráficos" |
| Catalogar, clasificar y gobernar datos en todo el patrimonio | Dataplex (con Data Catalog) | "gobernanza", "metadatos", "linaje", "descubrir" |
| Mover 500 TB a la nube por un enlace WAN pobre | Transfer Appliance | "ancho de banda limitado", "escala de petabytes offline" |
| Sincronizar continuamente un bucket on-prem con GCS | Storage Transfer Service | "recurrente", "incremental", "desde otra nube/on-prem" |
| Sistema de archivos NFS compartido para una aplicación legacy | Filestore | "recurso compartido de archivos", "NFS", "POSIX" |

### 8.1 Pares de distractores en los que se apoya el examen

| Si ves… | NO es… | Porque |
|---|---|---|
| "relacional globalmente consistente" | Cloud SQL | Cloud SQL tiene un único primario; las réplicas entre regiones son asíncronas |
| "cambios mínimos en la aplicación, MySQL existente" | Spanner | Spanner no es compatible con MySQL y requeriría refactorización |
| "analítica a escala de petabytes con SQL" | Bigtable | Bigtable no tiene joins SQL ni motor de analítica ad-hoc |
| "búsquedas puntuales de milisegundos de un dígito a millones de QPS" | BigQuery | BigQuery es un motor de escaneo; la latencia de búsqueda por fila es mucho mayor |
| "sincronización móvil en tiempo real, offline" | Bigtable / Cloud SQL | Solo Firestore ofrece SDKs de cliente con listeners y persistencia offline |
| "sistema de registro duradero" | Memorystore | Memorystore es una caché; la durabilidad no es su contrato |
| "archivos multimedia no estructurados" | cualquier base de datos | Los blobs pertenecen a Cloud Storage; guardá el *puntero* en la base de datos |
| "11 nueves de durabilidad significa que siempre está accesible" | disponibilidad | Durabilidad ≠ disponibilidad; la disponibilidad es del 99.9–99.95% según el tipo de bucket |

---

## 9. Juicios de síntesis para un arquitecto

1. **Elegí primero por alcance de consistencia y patrón de acceso, y en segundo lugar por familiaridad.** La familiaridad (Cloud SQL) es un criterio legítimo, pero solo después de haber confirmado que la carga cabe dentro del techo de escritura de un primario y del radio de impacto de una región.
2. **El techo con el que chocás no suele ser aquel para el que aprovisionaste.** A Cloud SQL se le acaba el margen de *escritura*, a Spanner y Bigtable se les acaba la *distribución de claves*, a BigQuery se le acaban los *slots*, a Memorystore se le acaba la *política de memoria*. Cada uno tiene un diagnóstico distinto (`pg_stat_activity`, `LOCK_STATS`/Key Visualizer, `JOBS_TIMELINE`, `INFO memory`). Instrumentá los cuatro antes del lanzamiento.
3. **Nunca apuntes el BI al primario OLTP.** Usá read pools de AlloyDB con el motor columnar para informes operativos, y BigQuery vía CDC de Datastream para todo lo histórico.
4. **Acertá con las decisiones irreversibles a la primera.** Tipo de ubicación del bucket y Autoclass, modo de Firestore, ubicación del dataset de BigQuery, configuración de instancia de Spanner, una política de retención bloqueada — todo eso es de tiempo de creación y efectivamente inmutable. Todo lo demás es ajustable después.
5. **Un backup es una hipótesis hasta que se restaura.** Ensayá el PITR de forma programada y registrá el tiempo de reloj; ese número es tu RTO, no el que figura en el runbook.
6. **La identidad, no la posición en la red, es la frontera de control de acceso.** Workload Identity + autenticación IAM de base de datos + los conectores de Cloud SQL eliminan por completo las credenciales estáticas; una clave JSON en un Secret es un hallazgo, no un diseño.

---

## Referencias

**Exam guide**
- Cloud Digital Leader exam guide (official PDF): https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
- Cloud Digital Leader certification overview: https://cloud.google.com/learn/certification/cloud-digital-leader

**Guía de selección de productos y arquitectura**
- Google Cloud databases overview: https://cloud.google.com/products/databases
- Choose a database service (Architecture Framework): https://cloud.google.com/architecture/framework/system-design/databases
- Google Cloud Architecture Framework: https://cloud.google.com/architecture/framework
- Data lifecycle on Google Cloud: https://cloud.google.com/architecture/data-lifecycle-cloud-platform
- Design storage for data analytics: https://cloud.google.com/architecture/framework/system-design/storage

**Cloud Storage**
- Documentation: https://cloud.google.com/storage/docs
- Storage classes: https://cloud.google.com/storage/docs/storage-classes
- Autoclass: https://cloud.google.com/storage/docs/autoclass
- Object Lifecycle Management: https://cloud.google.com/storage/docs/lifecycle
- Bucket locations and dual-region/turbo replication: https://cloud.google.com/storage/docs/locations
- Retention policies and Bucket Lock: https://cloud.google.com/storage/docs/bucket-lock
- Soft delete: https://cloud.google.com/storage/docs/soft-delete
- Consistency model: https://cloud.google.com/storage/docs/consistency
- Cloud Storage SLA: https://cloud.google.com/storage/sla

**Cloud SQL**
- Documentation: https://cloud.google.com/sql/docs
- High availability: https://cloud.google.com/sql/docs/postgres/high-availability
- Cloud SQL editions (Enterprise / Enterprise Plus): https://cloud.google.com/sql/docs/editions-intro
- Point-in-time recovery: https://cloud.google.com/sql/docs/postgres/backup-recovery/pitr
- Cloud SQL Auth Proxy: https://cloud.google.com/sql/docs/postgres/connect-auth-proxy
- Connect from GKE: https://cloud.google.com/sql/docs/postgres/connect-kubernetes-engine
- IAM database authentication: https://cloud.google.com/sql/docs/postgres/authentication
- Cloud SQL SLA: https://cloud.google.com/sql/sla

**AlloyDB for PostgreSQL**
- Documentation: https://cloud.google.com/alloydb/docs
- Architecture and storage layer: https://cloud.google.com/alloydb/docs/overview
- Columnar engine: https://cloud.google.com/alloydb/docs/columnar-engine/about
- Read pool instances: https://cloud.google.com/alloydb/docs/instance-read-pool-create
- AlloyDB SLA: https://cloud.google.com/alloydb/sla

**Spanner**
- Documentation: https://cloud.google.com/spanner/docs
- TrueTime and external consistency: https://cloud.google.com/spanner/docs/true-time-external-consistency
- Replication and instance configurations: https://cloud.google.com/spanner/docs/replication
- Schema design best practices: https://cloud.google.com/spanner/docs/schema-design
- Avoid hotspots / choose a primary key: https://cloud.google.com/spanner/docs/schema-design#primary-key-prevent-hotspots
- Key Visualizer: https://cloud.google.com/spanner/docs/key-visualizer
- Read types (strong vs stale): https://cloud.google.com/spanner/docs/reads
- Quotas and limits: https://cloud.google.com/spanner/quotas
- Spanner SLA: https://cloud.google.com/spanner/sla

**Bigtable**
- Documentation: https://cloud.google.com/bigtable/docs
- Storage model / overview: https://cloud.google.com/bigtable/docs/overview
- Schema and row key design: https://cloud.google.com/bigtable/docs/schema-design
- Time-series schema design: https://cloud.google.com/bigtable/docs/schema-design-time-series
- Replication overview: https://cloud.google.com/bigtable/docs/replication-overview
- App profiles and routing: https://cloud.google.com/bigtable/docs/app-profiles
- Hot tablets: https://cloud.google.com/bigtable/docs/viewing-hot-tablets
- Autoscaling: https://cloud.google.com/bigtable/docs/autoscaling
- Bigtable SLA: https://cloud.google.com/bigtable/sla

**Firestore**
- Documentation: https://cloud.google.com/firestore/docs
- Choose Native mode or Datastore mode: https://cloud.google.com/firestore/docs/firestore-or-datastore
- Best practices (incl. the 500/50/5 rule): https://cloud.google.com/firestore/docs/best-practices
- Index types and composite indexes: https://cloud.google.com/firestore/docs/concepts/index-overview
- Firestore SLA: https://cloud.google.com/firestore/sla

**Memorystore**
- Documentation: https://cloud.google.com/memorystore/docs
- Memorystore for Redis Cluster: https://cloud.google.com/memorystore/docs/cluster
- Memory management best practices: https://cloud.google.com/memorystore/docs/redis/memory-management-best-practices
- Memorystore SLA: https://cloud.google.com/memorystore/sla

**BigQuery**
- Documentation: https://cloud.google.com/bigquery/docs
- BigQuery architecture / under the hood: https://cloud.google.com/bigquery/docs/introduction
- Partitioned tables: https://cloud.google.com/bigquery/docs/partitioned-tables
- Clustered tables: https://cloud.google.com/bigquery/docs/clustered-tables
- Editions, reservations and slots: https://cloud.google.com/bigquery/docs/reservations-intro
- Control costs: https://cloud.google.com/bigquery/docs/best-practices-costs
- Storage Write API: https://cloud.google.com/bigquery/docs/write-api
- INFORMATION_SCHEMA jobs views: https://cloud.google.com/bigquery/docs/information-schema-jobs
- Materialized views: https://cloud.google.com/bigquery/docs/materialized-views-intro
- BI Engine: https://cloud.google.com/bigquery/docs/bi-engine-intro
- BigLake: https://cloud.google.com/biglake/docs
- BigQuery Omni: https://cloud.google.com/bigquery/docs/omni-introduction
- Analytics Hub: https://cloud.google.com/bigquery/docs/analytics-hub-introduction
- BigQuery ML: https://cloud.google.com/bigquery/docs/bqml-introduction
- BigQuery SLA: https://cloud.google.com/bigquery/sla

**Movimiento de datos, integración y gobernanza**
- Database Migration Service: https://cloud.google.com/database-migration/docs
- Datastream: https://cloud.google.com/datastream/docs
- Storage Transfer Service: https://cloud.google.com/storage-transfer/docs
- Transfer Appliance: https://cloud.google.com/transfer-appliance/docs
- Pub/Sub: https://cloud.google.com/pubsub/docs
- Dataflow: https://cloud.google.com/dataflow/docs
- Dataproc: https://cloud.google.com/dataproc/docs
- Cloud Data Fusion: https://cloud.google.com/data-fusion/docs
- Dataform: https://cloud.google.com/dataform/docs
- Cloud Composer: https://cloud.google.com/composer/docs
- Dataplex: https://cloud.google.com/dataplex/docs
- Backup and DR Service: https://cloud.google.com/backup-disaster-recovery/docs

**Redes, identidad y almacenamiento de archivos/bloque**
- Private Service Access: https://cloud.google.com/vpc/docs/private-services-access
- Workload Identity Federation for GKE: https://cloud.google.com/kubernetes-engine/docs/concepts/workload-identity
- Filestore: https://cloud.google.com/filestore/docs
- Google Cloud NetApp Volumes: https://cloud.google.com/netapp/volumes/docs
- Parallelstore: https://cloud.google.com/parallelstore/docs
- Hyperdisk: https://cloud.google.com/compute/docs/disks/hyperdisk
- Cloud Storage FUSE: https://cloud.google.com/storage/docs/cloud-storage-fuse/overview

**Referencia del proveedor de Terraform**
- `hashicorp/google` provider: https://registry.terraform.io/providers/hashicorp/google/latest/docs