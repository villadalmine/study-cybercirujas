# Tema 3.4 — Identificar los servicios de bases de datos de AWS

**Certificación:** AWS Certified Cloud Practitioner (CLF-C02, guía de examen v1.0)
**Dominio 3:** Tecnología y servicios en la nube — **Enunciado de tarea 3.4**
**Peso en el examen:** 4,25 %
**Perfil del lector:** Platform Architect / SRE. Este módulo va más allá de la tarjeta mnemotécnica de "qué servicio para qué carga de trabajo" y entra en los motores de almacenamiento, los protocolos de quórum, los sobres de fallo y la telemetría operativa que deciden si la elección sobrevive al contacto con producción.

---

## 1. Motivación: el problema arquitectónico detrás del enunciado de tarea

### 1.1 Por qué "identificar el servicio de base de datos" es en realidad una decisión de durabilidad y radio de impacto

Toda capa sin estado en una plataforma moderna es descartable. Podés drenar un Auto Scaling group de EC2, hacer rolling de un Deployment de Kubernetes o volar una versión de Lambda, y el único costo es latencia durante el rollout. La base de datos es la única capa donde una decisión equivocada es *irreversible en la escala de tiempo de un incidente*: no podés re-shardear la partition key de una tabla DynamoDB de 4 TB a las 03:00, y no podés incorporar retroactivamente replicación síncrona entre AZ a una instancia RDS single-AZ cuya AZ acaba de apagarse.

Así que la verdadera pregunta de ingeniería no es "SQL o NoSQL". Es un problema de restricciones de cuatro ejes:

| Eje | La pregunta que realmente estás respondiendo | Qué se destruye si te equivocás |
|---|---|---|
| **Modelo de consistencia** | ¿Una lectura después de escritura tiene que ser linealizable, o se acepta staleness acotado? | Corrección — clientes cobrados dos veces, inventario fantasma |
| **Dominio de fallo** | ¿Qué fallos correlacionados (AZ, Región, plano de control, humano) tienen que sobrevivir los datos? | Durabilidad — pérdida de datos irrecuperable |
| **Forma del patrón de acceso** | ¿Búsquedas puntuales por clave, escaneos de rango, joins entre 12 tablas, recorridos de grafo, agregaciones por ventana temporal? | Latencia y costo — un p50 de 40 ms se vuelve un p99 de 4 s bajo escaneo |
| **Superficie operativa** | ¿Quién parchea, respalda, hace failover y sostiene el pager? | MTTR y dotación |

La guía de examen CLF-C02 lo formula como *"Identificar los servicios de bases de datos de AWS"* y enumera los subobjetivos: relacional vs. no relacional, gestionado vs. no gestionado (alojado en EC2), herramientas de migración y la familia de bases de datos de propósito específico. Debajo de esa formulación está la frontera de responsabilidad compartida — la idea más relevante de este tema, tanto para el examen como para producción.

### 1.2 La frontera de responsabilidad compartida, trazada con precisión

```
┌────────────────────────────────────────────────────────────────────────────┐
│  Self-managed on EC2          RDS / Aurora            DynamoDB / Serverless│
├────────────────────────────────────────────────────────────────────────────┤
│  App-side query tuning    ●        ●                          ●            │  ← YOU
│  Schema / index design    ●        ●                          ●            │  ← YOU
│  Data classification      ●        ●                          ●            │  ← YOU
│  IAM / network policy     ●        ●                          ●            │  ← YOU
├────────────────────────────────────────────────────────────────────────────┤
│  DB engine tuning         ●        ◐ (parameter groups)       ○            │
│  Backups / PITR           ●        ○ (toggle + retention)     ○ (toggle)   │
│  Minor version patching   ●        ○ (maintenance window)     ○            │
│  Failover orchestration   ●        ○                          ○            │
│  Replica provisioning     ●        ◐ (you pick count/size)    ○            │
├────────────────────────────────────────────────────────────────────────────┤
│  OS patching              ●        ○                          ○            │  ← AWS
│  Hypervisor / firmware    ○        ○                          ○            │  ← AWS
│  Physical facility        ○        ○                          ○            │  ← AWS
└────────────────────────────────────────────────────────────────────────────┘
   ● = customer   ◐ = shared   ○ = AWS
```

Heurística de examen: **en el momento en que podés hacer `ssh` a la máquina, el parcheo del SO es tuyo.** RDS te da un puerto y un endpoint, nunca una shell. La excepción es **RDS Custom** (Oracle y SQL Server), que deliberadamente vuelve a abrir el acceso al SO y a la base de datos para aplicaciones legacy que necesitan agentes propios o binarios de terceros — y que, en consecuencia, devuelve esa responsabilidad a tu lado.

### 1.3 El escenario de producción usado a lo largo de este módulo

Una plataforma SaaS multi-tenant, `orders-plat`, corriendo sobre EKS, con cuatro cargas de trabajo con forma de datos:

1. **Libro mayor transaccional de pedidos** — ACID estricto, joins entre `orders / order_items / customers`, pico de 2 000 escrituras TPS, pico de 30 000 lecturas TPS, RPO ≤ 5 min, RTO ≤ 2 min, debe sobrevivir la pérdida completa de una AZ.
2. **Estado de sesión y carrito** — lecturas de menos de un milisegundo, 200 000 ops/s, tolerante a la pérdida (reconstruible), con picos.
3. **Feed de eventos/auditoría por tenant** — intensivo en append, ~50 kB/s por tenant, sólo búsquedas por clave, crecimiento ilimitado, retención de 7 años.
4. **Reportes ejecutivos** — 900 GB de histórico, agregaciones sobre tablas completas, tolerante a 15 minutos de staleness, consultado por 20 analistas.

Cada servicio de abajo se evalúa contra estos cuatro.

---

## 2. El portafolio de bases de datos de AWS: taxonomía y tablas de compromisos

### 2.1 Taxonomía de propósito específico

La posición declarada de AWS es la de **bases de datos de propósito específico**: rechazar el modelo de un-motor-relacional-para-todo y hacer coincidir el modelo de datos con el patrón de acceso.

| Categoría | Servicio | Modelo de datos | Patrón de acceso canónico |
|---|---|---|---|
| Relacional (OLTP) | **Amazon RDS** | Filas, esquema fijo, SQL | Joins, transacciones, integridad referencial |
| Relacional (OLTP cloud-native) | **Amazon Aurora** | Igual, compatible a nivel de protocolo con MySQL/PostgreSQL | Patrones de RDS con mayor throughput/disponibilidad |
| Clave-valor / documento (NoSQL) | **Amazon DynamoDB** | Colecciones de ítems, atributos sin esquema | Búsquedas por clave de milisegundos de un dígito a cualquier escala |
| Caché en memoria | **Amazon ElastiCache** (Valkey / Redis OSS / Memcached) | Clave-valor, estructuras | Lecturas en microsegundos, cache-aside, rate limiting |
| En memoria **durable** | **Amazon MemoryDB** | API Redis/Valkey + log multi-AZ durable | Redis como almacén primario, no como caché |
| Documento | **Amazon DocumentDB** (compatibilidad con MongoDB) | Documentos JSON, CRUD + agregación | Catálogos de contenido, perfiles, esquema flexible |
| Grafo | **Amazon Neptune** | Property graph + RDF | Recorridos: redes de fraude, recomendaciones, linaje |
| Wide-column | **Amazon Keyspaces** (for Apache Cassandra) | Tablas CQL, particionadas | Aplicaciones Cassandra, serverless, sin ring que operar |
| Series temporales | **Amazon Timestream** (LiveAnalytics / InfluxDB) | Medida + dimensiones + timestamp | IoT/telemetría, agregación por ventana temporal |
| Data warehouse (OLAP) | **Amazon Redshift** | MPP columnar | Escaneos/agregaciones sobre TB–PB |
| Migración | **AWS DMS** + **AWS Schema Conversion Tool** | — | Migración homogénea y heterogénea, CDC |

> **Nota honesta sobre actualidad.** La guía de examen CLF-C02 v1.0 es un documento congelado. Dos diferencias importan al momento de escribir esto:
> - **Amazon QLDB** (Quantum Ledger Database) aparece en listas de alcance más antiguas del CLF-C02. AWS anunció su retiro, con **fin de soporte el 2025-07-31**. Puede seguir apareciendo en bancos de preguntas del examen como distractor de "ledger inmutable y verificable criptográficamente". Reconocé el concepto; no diseñes sobre él.
> - **Aurora DSQL** (serverless, SQL distribuido activo-activo multi-Región, compatible con PostgreSQL) alcanzó GA después de que la guía se congelara y por lo tanto está **fuera del alcance del examen**, pero es la respuesta moderna correcta a "escrituras relacionales fuertemente consistentes multi-Región". La sección 4.5 lo cubre como nota al pie.

### 2.2 Relacional vs. no relacional: la tabla de decisión

| Dimensión | Relacional (RDS / Aurora) | No relacional (DynamoDB) |
|---|---|---|
| Esquema | Fijo, impuesto en la escritura, `ALTER TABLE` es un evento de migración | Schema-on-read; sólo se declaran los atributos clave |
| Flexibilidad de consulta | SQL ad-hoc, joins, agregados, funciones de ventana | Sólo los patrones de acceso para los que indexaste; **sin joins** |
| Consistencia | ACID, aislamiento serializable/RC, un único escritor | ACID por ítem; `TransactWriteItems` para ACID multi-ítem; lecturas fuertes o eventuales seleccionables por llamada |
| Modelo de escalado | **Vertical** para escrituras (instancia más grande) + réplicas de lectura horizontales | **Horizontal** tanto para lecturas como escrituras, de forma transparente |
| Techo práctico de escritura | Lo que pueda una instancia escritora (clase `db.r6g.16xlarge`) | Prácticamente ilimitado; techo por partición de 1 000 WCU |
| Perfil de latencia | Milisegundos bajos, se degrada con contención de locks y regresiones de plan | p99 de milisegundos de un dígito, plano respecto al tamaño de la tabla |
| Modo de fallo bajo carga | Agotamiento de conexiones, esperas por lock, lag de replicación | Throttling (`ProvisionedThroughputExceededException`), particiones calientes |
| Modelo de costo | Horas de instancia (aprovisionada incluso ociosa) + almacenamiento + E/S | Capacidad por request o aprovisionada; escala casi a cero |
| Palanca operativa | Parameter groups, planes, `EXPLAIN`, tuning de vacuum | Diseño de claves; casi ninguna perilla (ese es el punto) |
| Mejor encaje en `orders-plat` | **Carga 1** (libro mayor de pedidos) | **Carga 3** (feed de auditoría) |

**La regla que resuelve la mayoría de las preguntas de examen:** si el enunciado menciona *joins, consultas complejas, integridad referencial, aplicación SQL existente o "lift and shift de una base de datos MySQL/Oracle/SQL Server"* → relacional. Si menciona *latencia de milisegundos a cualquier escala, serverless, clave-valor, esquema flexible, tráfico impredecible/con picos* → DynamoDB.

### 2.3 Dónde caen las cuatro cargas de trabajo

| Carga de trabajo | Servicio | Por qué | Alternativa descartada y por qué |
|---|---|---|---|
| 1. Libro mayor de pedidos | **Aurora PostgreSQL**, Multi-AZ, 1 escritor + 2 lectores, RDS Proxy | Joins + ACID + supervivencia a pérdida de AZ + 30 k lecturas TPS vía lectores | RDS Multi-AZ *instance*: 60–120 s de failover revienta el presupuesto de RTO de 2 min sin margen; el standby no es legible, así que las lecturas cuestan más instancias |
| 2. Sesión/carrito | **ElastiCache (Valkey)**, cluster mode habilitado | p99 en microsegundos, los datos son reconstruibles | MemoryDB: durabilidad que no necesitás, ~2× el costo |
| 3. Feed de auditoría | **DynamoDB**, on-demand, PK = `TENANT#<id>`, SK = `TS#<iso>#<uuid>`, TTL, Streams | Append ilimitado, lecturas por clave, sin planificación de capacidad | Aurora: una tabla append-only que crece para siempre convierte `VACUUM` y el bloat de índices en un impuesto operativo permanente |
| 4. Reportes | **Redshift Serverless**, cargado desde S3 vía zero-ETL / DMS | Escaneos columnares sobre 900 GB, aislamiento de concurrencia respecto del OLTP | Correr los reportes contra los lectores de Aurora: un solo escaneo de 900 GB desaloja el buffer cache y destruye el p99 del OLTP |

---

## 3. Amazon RDS — la línea base relacional gestionada

### 3.1 Motores y qué los distingue operativamente

| Motor | Licencia | Propiedad operativa notable |
|---|---|---|
| MySQL | Open source | El ecosistema más grande; el `binlog` alimenta el CDC de DMS |
| PostgreSQL | Open source | Extensiones (`pg_stat_statements`, `PostGIS`, `pgvector`); autovacuum es la preocupación operativa n.º 1 |
| MariaDB | Open source | Fork de MySQL; reemplazo directo para muchas aplicaciones MySQL |
| Oracle | BYOL o License Included | RDS Custom disponible para acceso a SO/DB; Data Guard para réplicas |
| SQL Server | Mayormente License Included | Máximo 16 TiB de almacenamiento; sin replicación automática de backups entre Regiones en todas las ediciones |
| **Db2** | BYOL vía AWS Marketplace | La incorporación más reciente; parques nicho cercanos al mainframe |

### 3.2 Clases de almacenamiento — la decisión de throughput

| Tipo | Respaldo | Modelo de IOPS | Usar cuando |
|---|---|---|---|
| `gp3` | SSD de propósito general | Línea base de 3 000 IOPS / 125 MiB/s, aprovisionable de forma independiente del tamaño | **Por defecto.** Desacopla IOPS de la capacidad — esta es la solución a la trampa clásica de `gp2` |
| `gp2` | SSD de propósito general (legacy) | 3 IOPS por GiB, créditos de ráfaga | Sólo legacy. Un volumen `gp2` de 100 GiB está limitado a 300 IOPS y hace throttling silencioso una vez que se agota el saldo de ráfaga |
| `io1` / `io2 Block Express` | SSD de IOPS aprovisionadas | Hasta 256 000 IOPS, durabilidad del 99,999 % (`io2`) | OLTP sensible a la latencia con un piso de IOPS medido |
| Magnético | Legacy | — | Obsoleto. Nunca. |

Almacenamiento máximo asignado: **64 TiB** para MySQL, MariaDB, PostgreSQL, Oracle; **16 TiB** para SQL Server. El autoescalado de almacenamiento puede hacer crecer el volumen pero **no puede reducirlo** — esa asimetría es una mina presupuestaria.

### 3.3 Alta disponibilidad: las dos topologías Multi-AZ

Esta distinción se enseña mal con frecuencia. Hay **dos productos diferentes** llamados Multi-AZ.

| | **Multi-AZ DB instance** | **Multi-AZ DB cluster** |
|---|---|---|
| Topología | 1 primaria + 1 standby | 1 escritor + **2 standbys legibles**, 3 AZ |
| Replicación | Síncrona, a nivel de bloque | **Semi-síncrona** — el commit se confirma cuando ≥1 de 2 standbys tiene el log |
| ¿Standby legible? | **No** — existe sólo para el failover | **Sí**, vía un endpoint de lectura |
| Failover típico | 60–120 s | **< 35 s** |
| Motores | Todos los motores de RDS | Sólo MySQL 8.0.28+, PostgreSQL 13.4+ |
| Almacenamiento | Cualquiera | Sólo `io1`, `io2`, `gp3` |
| Disparador de failover | Pérdida de AZ, fallo de la primaria, cambio de tipo de instancia, parcheo, reinicio manual con failover | Igual |

**Punto crítico para el examen y para producción:** Multi-AZ es para **disponibilidad**, las réplicas de lectura son para **escalabilidad de lectura**. Son ortogonales y se combinan habitualmente. La replicación Multi-AZ es síncrona (RPO = 0); la replicación de réplicas de lectura es **asíncrona** (RPO > 0, el lag de réplica es un número real sobre el que debés alarmar).

### 3.4 Réplicas de lectura

- Replicación asíncrona nativa del motor (binlog de MySQL / streaming WAL de PostgreSQL).
- Hasta **15** para MySQL, MariaDB, PostgreSQL; **5** para Oracle y SQL Server.
- Pueden ser **entre Regiones** (una herramienta de recuperación ante desastres y de localidad de lectura).
- Pueden ser **promovidas** a una instancia autónoma con escritura — la promoción es unidireccional y rompe la replicación.
- Las réplicas de réplicas (en cascada) están soportadas en MySQL/MariaDB/PostgreSQL.

### 3.5 Semántica de backup y recuperación

| Mecanismo | Retención | Granularidad | ¿Sobrevive al borrado de la instancia? |
|---|---|---|---|
| Backups automatizados | 0–35 días (0 = desactivado; **nunca** en producción) | PITR a cualquier segundo dentro de la retención, logs de transacciones enviados cada ~5 min | No (salvo que se elija "retain automated backups") |
| Snapshots manuales de DB | Hasta que los borres | El instante del snapshot | **Sí** |
| AWS Backup | Según plan/vault de backup, entre cuentas, entre Regiones | Basado en snapshots | Sí, en el vault |

Restaurar **siempre crea una instancia nueva con un endpoint nuevo**. No existe restauración in-place. Ese solo hecho dicta tu runbook de DR: la recuperación implica un cambio de DNS/configuración, y tenés que haberlo ensayado.

---

## 4. Amazon Aurora — el motor relacional con almacenamiento desacoplado

### 4.1 La arquitectura de almacenamiento (por qué Aurora no es "RDS pero más rápido")

Aurora reemplaza la capa de almacenamiento del motor por una flota de almacenamiento distribuida, multi-tenant y estructurada en log, construida a propósito.

```
                    ┌───────────────────────────────────────┐
   Writer ─────────►│  Redo log records only (not pages)     │
   (1 per cluster)  └───────────────┬───────────────────────┘
                                    │  fan-out
      ┌─────────────────────────────┼─────────────────────────────┐
      │                             │                             │
   ┌──▼───┐  ┌──────┐          ┌────▼─┐  ┌──────┐          ┌──────▼┐  ┌──────┐
   │ seg  │  │ seg  │          │ seg  │  │ seg  │          │ seg   │  │ seg  │
   │ 10GB │  │ 10GB │          │ 10GB │  │ 10GB │          │ 10GB  │  │ 10GB │
   └──────┘  └──────┘          └──────┘  └──────┘          └───────┘  └──────┘
      AZ-a (2 copies)             AZ-b (2 copies)             AZ-c (2 copies)

   Write quorum: 4 of 6      Read quorum: 3 of 6
   Tolerates: loss of an entire AZ + 1 additional copy without losing WRITE availability
              loss of an entire AZ                      without losing READ  availability
```

Consecuencias que importan operativamente:

- El escritor envía **registros de redo log**, no páginas sucias de 8 kB/16 kB. La amplificación de red cae aproximadamente en un orden de magnitud frente a un diseño de EBS espejado — esa es la fuente real de la ventaja de throughput de Aurora.
- El almacenamiento crece automáticamente en **segmentos de 10 GB hasta 128 TiB**. Nunca aprovisionás ni extendés un volumen.
- **Todas las réplicas leen el mismo volumen de almacenamiento.** Agregar una Aurora Replica no copia datos, así que una réplica queda en línea en minutos sin importar el tamaño de la base, y el lag de réplica es típicamente de **decenas de milisegundos**, no de segundos.
- El failover es una **promoción dentro de un cluster de almacenamiento compartido**, no una operación de puesta al día de datos. Típicamente < 30 s, con frecuencia ~10 s con RDS Proxy adelante.

### 4.2 Endpoints — la parte que las aplicaciones hacen mal

| Endpoint | Resuelve a | Usar para |
|---|---|---|
| **Cluster (escritor)** | El escritor actual, sigue al failover | Todas las escrituras; el único endpoint que sobrevive a un failover para escrituras |
| **Lector** | Round-robin de DNS entre las réplicas disponibles | Tráfico de sólo lectura |
| **Personalizado** | Un subconjunto nombrado de instancias que definís | Aislar lectores de analítica de los lectores de la aplicación |
| **Instancia** | Una instancia específica | Sólo diagnóstico — **nunca** en la configuración de la aplicación |

**Modo de fallo:** el endpoint de lectura balancea la carga *por resolución DNS*, no por conexión. Una JVM con `networkaddress.cache.ttl=-1` resuelve una vez al arrancar y fija cada conexión a una única réplica durante toda la vida del proceso. Poné el TTL de DNS de la JVM en 5–10 s o usá un pooler.

### 4.3 Matriz de características de Aurora

| Característica | Qué hace | Restricción |
|---|---|---|
| **Aurora Replicas** | Hasta 15 lectores compartiendo el volumen de almacenamiento | Misma Región que el cluster |
| **Backtrack** | Rebobina el cluster in situ, hasta 72 h, sin restaurar | **Sólo Aurora MySQL**; debe habilitarse en la creación |
| **Fast Database Cloning** | Clon copy-on-write de un cluster de varios TB en minutos | Misma Región; las páginas que divergen generan costo de almacenamiento |
| **Global Database** | Hasta 5 Regiones secundarias, replicación física a nivel de almacenamiento, lag típico < 1 s | RPO ≈ 1 s; las secundarias son de sólo lectura salvo que esté activo el reenvío de escrituras |
| **Serverless v2** | Capacidad de instancia en **ACU** (~2 GiB de RAM cada una), 0/0,5 → 256, escala en segundos | Se mezcla con instancias aprovisionadas en un mismo cluster |
| **RDS Proxy** | Pooling de conexiones, autenticación IAM, reduce el tiempo de failover hasta un 66 % | Agrega ~5 ms; precio por vCPU |
| **I/O-Optimized** | Precio plano, sin cargos por E/S | Tarifa de instancia/almacenamiento ~30 % más alta; conviene cuando la E/S > ~25 % de la factura |
| **Zero-ETL a Redshift** | Replicación casi en tiempo real a un warehouse, sin pipeline de DMS | Fuentes Aurora MySQL/PostgreSQL |

### 4.4 RDS vs. Aurora: el compromiso honesto

| Criterio | RDS (MySQL/PostgreSQL) | Aurora |
|---|---|---|
| Compatibilidad de motor | El motor upstream real | Reimplementación compatible a nivel de protocolo; **algunas extensiones/plugins no soportados** |
| Máximo de almacenamiento | 64 TiB, preasignado, no se puede reducir | 128 TiB, crece automáticamente en segmentos de 10 GB |
| Lag de réplica | Segundos (asíncrono, puede divergir bajo carga) | Típicamente < 100 ms (almacenamiento compartido) |
| Failover | 60–120 s (instance) / < 35 s (cluster) | Típicamente < 30 s |
| Durabilidad | 1 primaria + 1 standby síncrono (Multi-AZ) | 6 copias / 3 AZ, quórum de escritura 4 de 6 |
| Costo base | Menor para cargas pequeñas y estables | Tarifa de instancia mayor; cargos por E/S en Standard |
| Rebobinado a un punto en el tiempo | Sólo restauración a instancia nueva | Restauración **o** Backtrack (MySQL) |
| Elegilo cuando | Sensible al costo, necesitás extensiones exóticas, huella pequeña | Importan HA/throughput, o querés que la capa de almacenamiento deje de ser tu problema |

### 4.5 Nota al pie: Aurora DSQL (fuera del alcance del CLF-C02)

Aurora DSQL es una base de datos SQL **distribuida**, serverless y compatible con PostgreSQL, con escrituras activo-activo multi-Región y control de concurrencia optimista, apuntando a una disponibilidad multi-Región del 99,999 %. Resuelve la restricción que el Aurora Global Database clásico no puede: **escrituras fuertemente consistentes en más de una Región simultáneamente**. Es posterior a la guía de examen congelada — conocelo para trabajo de arquitectura, no para el examen.

---

## 5. Amazon DynamoDB — el motor clave-valor serverless

### 5.1 El modelo de particionado, que es todo el servicio

```
   PutItem(pk = "TENANT#4711", sk = "TS#2026-09-04T10:00:00Z#a1b2")
              │
              ▼
       MD5(partition key)  ──►  hash space  ──►  Partition P17
                                                     │
                          ┌──────────────────────────┼──────────────────────────┐
                          ▼                          ▼                          ▼
                    Replica AZ-a              Replica AZ-b              Replica AZ-c
                    (leader for P17)
                          │
                  Quorum write: leader + 1 of 2 followers
```

Límites duros que dan forma a toda decisión de esquema:

| Límite | Valor | Consecuencia |
|---|---|---|
| Tamaño de ítem | **400 KB** | Los blobs grandes van a S3; guardá la clave de S3 en el ítem |
| Capacidad de partición | **3 000 RCU / 1 000 WCU**, **10 GB** | Una sola clave caliente no puede superar esto — ninguna cantidad de capacidad de tabla ayuda |
| Página de resultados de query | 1 MB | La paginación es obligatoria, no opcional |
| `BatchGetItem` | 100 ítems / 16 MB | |
| `BatchWriteItem` | 25 ítems / 16 MB | No es atómico — los fallos parciales devuelven `UnprocessedItems` |
| `TransactWriteItems` | 100 ítems / 4 MB | Atómico; **consume 2× la capacidad** |
| GSI por tabla | 20 (por defecto, ajustable) | |
| LSI por tabla | 5, **declarados sólo en la creación de la tabla** | No se pueden agregar después — es una migración de esquema |

Aritmética de unidades de capacidad (memorizar):

- **1 RCU** = una lectura *fuertemente consistente* de hasta **4 KB/s**, o **dos** lecturas *eventualmente consistentes* de 4 KB/s.
- **1 WCU** = una escritura de hasta **1 KB/s**.
- Una lectura transaccional cuesta **2 RCU**; una escritura transaccional cuesta **2 WCU**.

### 5.2 Modos de capacidad

| Modo | Facturación | Escalado | Elegir cuando |
|---|---|---|---|
| **On-demand** | Por request (RRU/WRU) | Instantáneo hasta 2× el pico previo; se duplica automáticamente | Cargas desconocidas, con picos o nuevas; dev/test; utilización sostenida < ~15 % |
| **Provisioned** | Por unidad-de-capacidad-hora | Application Auto Scaling sobre un objetivo de utilización (70 % por defecto) | Tráfico predecible y estable — hasta ~7× más barato con utilización alta y plana |

Las tablas on-demand ahora pueden llevar techos **máximos** de unidades de request de lectura/escritura — usalos como cortacircuitos contra costos desbocados.

### 5.3 Tipos de índice

| | **LSI** (Local Secondary Index) | **GSI** (Global Secondary Index) |
|---|---|---|
| Partition key | **Igual a la de la tabla base** | **Cualquier atributo** |
| Sort key | Diferente | Cualquier atributo |
| Creación | **Sólo en la creación de la tabla** | En cualquier momento, en línea |
| Consistencia | Lecturas fuertes disponibles | **Sólo eventualmente consistente** |
| Capacidad | Comparte la de la tabla | **La propia** — un GSI con throttling hace throttling de las *escrituras* de la tabla base |
| Restricción | 10 GB por colección de ítems (por partition key) | Ninguna |

**El modo de fallo de contrapresión del GSI:** un GSI subaprovisionado no puede absorber las escrituras de índice, y DynamoDB hará throttling de las escrituras a la **tabla base** para protegerlo. Síntoma: `WriteThrottleEvents` en la tabla base con la capacidad de la tabla base ni cerca de su techo. Alarmá siempre sobre el throttling del GSI por separado.

### 5.4 El ecosistema de DynamoDB

| Característica | Propósito | Detalle clave |
|---|---|---|
| **DAX** | Caché en memoria delante de DynamoDB | Lecturas en **microsegundos**; compatible con la API (sin reescribir la app); caché de ítems + caché de queries; write-through |
| **Streams** | Log de cambios ordenado por ítem | Retención de **24 h**; dispara Lambda; opciones de vista `NEW_AND_OLD_IMAGES` |
| **Kinesis Data Streams for DynamoDB** | Los mismos cambios hacia Kinesis | Retención de hasta **365 días** |
| **Global Tables** | Replicación multi-Región, **multi-activa** | Resolución de conflictos **last-writer-wins** — no apta para contadores ni saldos financieros |
| **PITR** | Backup continuo | Restauración a cualquier segundo de los últimos **35 días**, a una **tabla nueva** |
| **Backup on-demand** | Snapshot completo | Retenido hasta que lo borres; impacto cero en el rendimiento |
| **TTL** | Expiración automática por atributo de epoch en segundos | **Gratis**, pero el borrado es best-effort dentro de ~48 h; un borrado por TTL aparece en Streams |
| **Clases de tabla** | Standard / Standard-IA | Standard-IA: ~60 % menos costo de almacenamiento, ~25 % más costo de request — para patrones de acceso de archivo |

**Trampa de examen:** DAX cachea *DynamoDB* solamente. ElastiCache es genérico. Si una pregunta dice "latencia en microsegundos para una aplicación DynamoDB existente sin cambios de código", la respuesta es **DAX**, no ElastiCache.

---

## 6. En memoria: ElastiCache y MemoryDB

### 6.1 Comparación de motores

| | **Valkey / Redis OSS** | **Memcached** | **MemoryDB** |
|---|---|---|---|
| Estructuras de datos | Strings, listas, sets, sorted sets, hashes, streams, HLL, geo | Sólo strings | Igual que Valkey/Redis |
| Threading | Mayormente mono-hilo por shard (dejando de lado enhanced I/O) | **Multi-hilo** — escala verticalmente sobre los cores | Multi-hilo |
| Replicación | Sí, hasta 5 réplicas por shard | **No** | Sí |
| Multi-AZ + failover automático | Sí | No | Sí, por diseño |
| Persistencia | Snapshots (RDB) / AOF | **Ninguna** | **Log de transacciones multi-AZ durable** |
| Garantía de durabilidad | Semántica de caché — se espera pérdida de datos | Ninguna | **Semántica de base de datos primaria** |
| Latencia de lectura | Microsegundos | Microsegundos | Microsegundos |
| Latencia de escritura | Microsegundos | Microsegundos | **Milisegundos de un dígito** (commit del log) |
| Pub/Sub, Lua, transacciones | Sí | No | Sí |
| Usar para | Cache-aside, sesiones, leaderboards, rate limits, colas | Caché de objetos simple, sharded horizontalmente | Aplicación con API Redis donde Redis **es** el sistema de registro |

Valkey (el fork de Redis de la Linux Foundation tras el cambio de licencia) es el valor por defecto de cara al futuro en ElastiCache y tiene un precio más bajo que los nodos Redis OSS.

### 6.2 Estrategias de caché y sus modos de fallo

| Estrategia | Mecánica | Modo de fallo |
|---|---|---|
| **Lazy loading / cache-aside** | Miss → leer la DB → poblar la caché | **Estampida de caché**: N misses concurrentes sobre la misma clave caliente pegan todos a la DB. Mitigar con un mutex por clave o un lock con `SETNX` |
| **Write-through** | Cada escritura actualiza la caché y la DB | La caché se llena de datos que nunca se leen; la latencia de escritura se duplica |
| **TTL en todo** | Staleness acotado | **Expiración sincronizada** — miles de claves expirando en el mismo segundo producen una estampida. Agregá jitter al TTL: `ttl = base + rand(0, base*0.1)` |

---

## 7. Motores de propósito específico

| Servicio | Modelo | Lenguaje de consulta | Notas de arquitectura |
|---|---|---|---|
| **DocumentDB** | Documentos JSON, compatibilidad con la API de MongoDB | API de consulta de MongoDB / pipeline de agregación | Almacenamiento separado al estilo Aurora: 6 copias / 3 AZ, hasta 64 TiB, hasta 15 réplicas. La compatibilidad es por versión — validá tu driver y operadores |
| **Neptune** | Property graph + tripletas RDF | **Gremlin**, **openCypher**, **SPARQL** | Almacenamiento estilo Aurora. Responde "camino más corto", "quién está conectado con quién", "detección de redes de fraude" — consultas donde una solución relacional necesita CTEs recursivas y self-joins |
| **Keyspaces** | Wide-column | **CQL** (compatible con Cassandra 3.11 / 4.x) | **Serverless** — sin ring, sin nodos, sin compactación, sin repair. On-demand o aprovisionado. Elimina la mayor carga operativa de Cassandra autogestionado |
| **Timestream** | Series temporales | SQL con funciones de series temporales (`INTERPOLATE`, `SPLINE`) | LiveAnalytics: memory store en niveles → magnetic store con movimiento automático. También se ofrece como **InfluxDB** gestionado |
| **Redshift** | Warehouse MPP columnar | SQL en dialecto PostgreSQL | Los nodos RA3 con almacenamiento gestionado separan el cómputo del almacenamiento; **Redshift Serverless** factura en RPU; **Spectrum** consulta S3 in situ; Concurrency Scaling agrega clusters transitorios para ráfagas de consultas |

### 7.1 OLTP vs. OLAP — la frontera que decide las preguntas de Redshift

| | OLTP (RDS/Aurora/DynamoDB) | OLAP (Redshift) |
|---|---|---|
| Unidad de trabajo | Una fila / un conjunto pequeño | Millones de filas, pocas columnas |
| Disposición del almacenamiento | **Orientado a filas** | **Columnar** + compresión + zone maps |
| Concurrencia | Miles de transacciones cortas | Decenas de consultas de larga duración |
| Objetivo de latencia | Milisegundos | Segundos a minutos |
| Frescura de los datos | Ahora | Minutos a horas (o casi en tiempo real vía zero-ETL) |
| Forma de la pregunta | "Traeme el pedido 4711" | "Ingresos por región por mes durante 3 años" |

Si un enunciado de examen contiene *data warehouse, business intelligence, analítica, consultas complejas sobre grandes conjuntos históricos, escala de petabytes* → **Redshift**. Si dice *consultar datos directamente en S3 con SQL, serverless, pagar por consulta escaneada* → **Athena**, no Redshift.

---

## 8. Migración: AWS DMS y SCT

### 8.1 Modelo de componentes

```
  Source                    DMS Replication Instance                Target
  ┌────────────┐            (or DMS Serverless)                  ┌────────────┐
  │ Oracle 19c │──endpoint─►┌──────────────────────┐──endpoint──►│  Aurora    │
  │ on-prem    │            │  Task: full load     │             │ PostgreSQL │
  │            │            │      + CDC (ongoing) │             │            │
  └────────────┘            │  Table mappings JSON │             └────────────┘
        │                   │  Transformation rules│
        │                   └──────────────────────┘
        │                              ▲
        └──── AWS SCT ─────────────────┘
              (schema, PL/SQL → PL/pgSQL, assessment report)
```

| Tipo de migración | ¿Requiere conversión de esquema? | Herramientas |
|---|---|---|
| **Homogénea** (Oracle → Oracle, MySQL → Aurora MySQL) | No | DMS solo |
| **Heterogénea** (Oracle → Aurora PostgreSQL, SQL Server → MySQL) | **Sí** | **SCT** (o DMS Schema Conversion) primero, después DMS para los datos |

### 8.2 Modos de tarea

| Modo | Comportamiento | Usar para |
|---|---|---|
| Full load | Copia masiva de una vez | Conjuntos de datos estáticos, refrescos de dev |
| Full load + CDC | Copia masiva y después streaming de los cambios en curso desde el log de transacciones de la fuente | **Cutover con downtime casi nulo** — el patrón canónico de producción |
| CDC only | Cambios a partir de un LSN/SCN especificado | Reanudar tras una carga masiva fuera de banda |

Hechos operativos clave:
- DMS **no** migra índices secundarios, secuencias, procedimientos almacenados, triggers ni claves foráneas por defecto — de eso se encarga SCT o una pasada manual de DDL. Las claves foráneas y los triggers típicamente se **deshabilitan durante el full load** y se rehabilitan antes del cutover, o la carga falla por orden.
- La base de datos fuente debe tener habilitada la replicación lógica / supplemental logging (`ARCHIVELOG` + supplemental logging para Oracle; `wal_level=logical` para PostgreSQL; `binlog_format=ROW` para MySQL).
- **DMS Fleet Advisor** descubre y dimensiona un parque on-prem; **DMS Serverless** elimina la planificación de capacidad de la instancia de replicación.

---

## 9. Infraestructura como código — manifiestos completos

### 9.1 CloudFormation: cluster Aurora PostgreSQL de producción con Serverless v2, RDS Proxy y alarmas

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >-
  orders-plat: production Aurora PostgreSQL cluster.
  1 provisioned writer + 2 Serverless v2 readers across 3 AZs,
  customer-managed KMS, Secrets Manager rotation, RDS Proxy,
  Performance Insights, Enhanced Monitoring and CloudWatch alarms.

Parameters:
  EnvName:
    Type: String
    Default: prod
    AllowedValues: [dev, staging, prod]
  VpcId:
    Type: AWS::EC2::VPC::Id
    Description: VPC hosting the EKS data plane.
  PrivateSubnetIds:
    Type: List<AWS::EC2::Subnet::Id>
    Description: At least three private subnets in three distinct AZs.
  AppSecurityGroupId:
    Type: AWS::EC2::SecurityGroup::Id
    Description: Security group attached to the EKS worker nodes.
  EngineVersion:
    Type: String
    Default: '16.4'
  WriterInstanceClass:
    Type: String
    Default: db.r6g.2xlarge
  ReaderMinCapacity:
    Type: Number
    Default: 2
    Description: Minimum Aurora Capacity Units per Serverless v2 reader.
  ReaderMaxCapacity:
    Type: Number
    Default: 32
  BackupRetentionDays:
    Type: Number
    Default: 35
    MinValue: 7
    MaxValue: 35
  AlarmTopicArn:
    Type: String
    Description: SNS topic ARN that pages the on-call rotation.

Conditions:
  IsProd: !Equals [!Ref EnvName, prod]

Resources:

  # ---------------------------------------------------------------- encryption
  DatabaseKmsKey:
    Type: AWS::KMS::Key
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      Description: !Sub 'CMK for orders-plat ${EnvName} Aurora cluster'
      EnableKeyRotation: true
      PendingWindowInDays: 30
      KeyPolicy:
        Version: '2012-10-17'
        Statement:
          - Sid: EnableIAMUserPermissions
            Effect: Allow
            Principal:
              AWS: !Sub 'arn:${AWS::Partition}:iam::${AWS::AccountId}:root'
            Action: 'kms:*'
            Resource: '*'
          - Sid: AllowRDSService
            Effect: Allow
            Principal:
              Service: rds.amazonaws.com
            Action:
              - kms:Decrypt
              - kms:GenerateDataKey*
              - kms:CreateGrant
              - kms:DescribeKey
            Resource: '*'

  DatabaseKmsAlias:
    Type: AWS::KMS::Alias
    Properties:
      AliasName: !Sub 'alias/orders-plat-${EnvName}-aurora'
      TargetKeyId: !Ref DatabaseKmsKey

  # ------------------------------------------------------------------ secrets
  MasterUserSecret:
    Type: AWS::SecretsManager::Secret
    Properties:
      Name: !Sub 'orders-plat/${EnvName}/aurora/master'
      Description: Aurora PostgreSQL master credentials for orders-plat.
      KmsKeyId: !Ref DatabaseKmsKey
      GenerateSecretString:
        SecretStringTemplate: '{"username":"ordersadmin"}'
        GenerateStringKey: password
        PasswordLength: 40
        ExcludeCharacters: '"@/\ '
      Tags:
        - Key: Environment
          Value: !Ref EnvName

  MasterUserSecretAttachment:
    Type: AWS::SecretsManager::SecretTargetAttachment
    Properties:
      SecretId: !Ref MasterUserSecret
      TargetId: !Ref AuroraCluster
      TargetType: AWS::RDS::DBCluster

  # ------------------------------------------------------------- networking
  DbSubnetGroup:
    Type: AWS::RDS::DBSubnetGroup
    Properties:
      DBSubnetGroupName: !Sub 'orders-plat-${EnvName}-aurora'
      DBSubnetGroupDescription: Private subnets across three AZs.
      SubnetIds: !Ref PrivateSubnetIds

  DbSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: !Sub 'orders-plat ${EnvName} Aurora ingress'
      VpcId: !Ref VpcId
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 5432
          ToPort: 5432
          SourceSecurityGroupId: !Ref AppSecurityGroupId
          Description: PostgreSQL from EKS worker nodes.
      SecurityGroupEgress:
        - IpProtocol: -1
          CidrIp: 0.0.0.0/0
          Description: Egress required for KMS/Secrets/CloudWatch endpoints.
      Tags:
        - Key: Name
          Value: !Sub 'orders-plat-${EnvName}-aurora-sg'

  ProxySecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: !Sub 'orders-plat ${EnvName} RDS Proxy'
      VpcId: !Ref VpcId
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 5432
          ToPort: 5432
          SourceSecurityGroupId: !Ref AppSecurityGroupId
          Description: PostgreSQL from EKS worker nodes.

  ProxyToDbIngress:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !Ref DbSecurityGroup
      IpProtocol: tcp
      FromPort: 5432
      ToPort: 5432
      SourceSecurityGroupId: !Ref ProxySecurityGroup
      Description: PostgreSQL from RDS Proxy.

  # ------------------------------------------------------- parameter groups
  ClusterParameterGroup:
    Type: AWS::RDS::DBClusterParameterGroup
    Properties:
      Description: !Sub 'orders-plat ${EnvName} cluster parameters'
      Family: aurora-postgresql16
      Parameters:
        rds.force_ssl: '1'
        log_min_duration_statement: '1000'
        log_statement: ddl
        log_lock_waits: '1'
        log_temp_files: '0'
        shared_preload_libraries: 'pg_stat_statements,auto_explain'
        'auto_explain.log_min_duration': '3000'
        'auto_explain.log_analyze': '1'
        track_activity_query_size: '4096'

  DbParameterGroup:
    Type: AWS::RDS::DBParameterGroup
    Properties:
      Description: !Sub 'orders-plat ${EnvName} instance parameters'
      Family: aurora-postgresql16
      Parameters:
        idle_in_transaction_session_timeout: '300000'   # 5 min, in ms
        statement_timeout: '60000'                      # 60 s, in ms
        tcp_keepalives_idle: '60'
        tcp_keepalives_interval: '10'
        tcp_keepalives_count: '6'

  # ------------------------------------------------------------- monitoring
  EnhancedMonitoringRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: monitoring.rds.amazonaws.com
            Action: sts:AssumeRole
      ManagedPolicyArns:
        - !Sub 'arn:${AWS::Partition}:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole'

  # ---------------------------------------------------------------- cluster
  AuroraCluster:
    Type: AWS::RDS::DBCluster
    DeletionPolicy: Snapshot
    UpdateReplacePolicy: Snapshot
    Properties:
      DBClusterIdentifier: !Sub 'orders-plat-${EnvName}'
      Engine: aurora-postgresql
      EngineVersion: !Ref EngineVersion
      DatabaseName: orders
      MasterUsername: !Sub '{{resolve:secretsmanager:${MasterUserSecret}:SecretString:username}}'
      MasterUserPassword: !Sub '{{resolve:secretsmanager:${MasterUserSecret}:SecretString:password}}'
      DBSubnetGroupName: !Ref DbSubnetGroup
      VpcSecurityGroupIds:
        - !Ref DbSecurityGroup
      DBClusterParameterGroupName: !Ref ClusterParameterGroup
      StorageEncrypted: true
      KmsKeyId: !Ref DatabaseKmsKey
      StorageType: aurora-iopt1              # Aurora I/O-Optimized: flat pricing
      BackupRetentionPeriod: !Ref BackupRetentionDays
      PreferredBackupWindow: '03:00-04:00'
      PreferredMaintenanceWindow: 'sun:05:00-sun:06:00'
      CopyTagsToSnapshot: true
      DeletionProtection: !If [IsProd, true, false]
      EnableIAMDatabaseAuthentication: true
      EnableCloudwatchLogsExports:
        - postgresql
      ServerlessV2ScalingConfiguration:
        MinCapacity: !Ref ReaderMinCapacity
        MaxCapacity: !Ref ReaderMaxCapacity
      Tags:
        - Key: Environment
          Value: !Ref EnvName
        - Key: DataClassification
          Value: confidential

  WriterInstance:
    Type: AWS::RDS::DBInstance
    Properties:
      DBInstanceIdentifier: !Sub 'orders-plat-${EnvName}-writer'
      DBClusterIdentifier: !Ref AuroraCluster
      Engine: aurora-postgresql
      DBInstanceClass: !Ref WriterInstanceClass
      DBParameterGroupName: !Ref DbParameterGroup
      PromotionTier: 0
      AutoMinorVersionUpgrade: true
      EnablePerformanceInsights: true
      PerformanceInsightsKMSKeyId: !Ref DatabaseKmsKey
      PerformanceInsightsRetentionPeriod: 465     # 15 months
      MonitoringInterval: 10
      MonitoringRoleArn: !GetAtt EnhancedMonitoringRole.Arn
      PubliclyAccessible: false

  ReaderInstanceOne:
    Type: AWS::RDS::DBInstance
    DependsOn: WriterInstance
    Properties:
      DBInstanceIdentifier: !Sub 'orders-plat-${EnvName}-reader-1'
      DBClusterIdentifier: !Ref AuroraCluster
      Engine: aurora-postgresql
      DBInstanceClass: db.serverless
      DBParameterGroupName: !Ref DbParameterGroup
      PromotionTier: 1
      EnablePerformanceInsights: true
      PerformanceInsightsKMSKeyId: !Ref DatabaseKmsKey
      MonitoringInterval: 10
      MonitoringRoleArn: !GetAtt EnhancedMonitoringRole.Arn
      PubliclyAccessible: false

  ReaderInstanceTwo:
    Type: AWS::RDS::DBInstance
    DependsOn: WriterInstance
    Properties:
      DBInstanceIdentifier: !Sub 'orders-plat-${EnvName}-reader-2'
      DBClusterIdentifier: !Ref AuroraCluster
      Engine: aurora-postgresql
      DBInstanceClass: db.serverless
      DBParameterGroupName: !Ref DbParameterGroup
      PromotionTier: 1
      EnablePerformanceInsights: true
      PerformanceInsightsKMSKeyId: !Ref DatabaseKmsKey
      MonitoringInterval: 10
      MonitoringRoleArn: !GetAtt EnhancedMonitoringRole.Arn
      PubliclyAccessible: false

  # -------------------------------------------------------------- RDS Proxy
  ProxyRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: rds.amazonaws.com
            Action: sts:AssumeRole
      Policies:
        - PolicyName: read-master-secret
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - secretsmanager:GetSecretValue
                Resource: !Ref MasterUserSecret
              - Effect: Allow
                Action:
                  - kms:Decrypt
                Resource: !GetAtt DatabaseKmsKey.Arn
                Condition:
                  StringEquals:
                    'kms:ViaService': !Sub 'secretsmanager.${AWS::Region}.amazonaws.com'

  DbProxy:
    Type: AWS::RDS::DBProxy
    Properties:
      DBProxyName: !Sub 'orders-plat-${EnvName}-proxy'
      EngineFamily: POSTGRESQL
      RoleArn: !GetAtt ProxyRole.Arn
      VpcSubnetIds: !Ref PrivateSubnetIds
      VpcSecurityGroupIds:
        - !Ref ProxySecurityGroup
      RequireTLS: true
      IdleClientTimeout: 1800
      DebugLogging: false
      Auth:
        - AuthScheme: SECRETS
          SecretArn: !Ref MasterUserSecret
          IAMAuth: REQUIRED
          ClientPasswordAuthType: POSTGRES_SCRAM_SHA_256

  DbProxyTargetGroup:
    Type: AWS::RDS::DBProxyTargetGroup
    Properties:
      DBProxyName: !Ref DbProxy
      TargetGroupName: default
      DBClusterIdentifiers:
        - !Ref AuroraCluster
      ConnectionPoolConfigurationInfo:
        MaxConnectionsPercent: 90
        MaxIdleConnectionsPercent: 50
        ConnectionBorrowTimeout: 120

  # ----------------------------------------------------------------- alarms
  WriterCpuAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub 'orders-plat-${EnvName}-writer-cpu-high'
      AlarmDescription: Writer CPU sustained above 80% for 15 minutes.
      Namespace: AWS/RDS
      MetricName: CPUUtilization
      Dimensions:
        - Name: DBInstanceIdentifier
          Value: !Ref WriterInstance
      Statistic: Average
      Period: 300
      EvaluationPeriods: 3
      Threshold: 80
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: breaching
      AlarmActions: [!Ref AlarmTopicArn]
      OKActions: [!Ref AlarmTopicArn]

  ReplicaLagAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub 'orders-plat-${EnvName}-replica-lag'
      AlarmDescription: Aurora replica lag above 1s — read-after-write may break.
      Namespace: AWS/RDS
      MetricName: AuroraReplicaLagMaximum
      Dimensions:
        - Name: DBClusterIdentifier
          Value: !Ref AuroraCluster
      Statistic: Maximum
      Period: 60
      EvaluationPeriods: 5
      Threshold: 1000            # milliseconds
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: notBreaching
      AlarmActions: [!Ref AlarmTopicArn]

  ConnectionSaturationAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub 'orders-plat-${EnvName}-connections-high'
      AlarmDescription: Database connections approaching max_connections.
      Namespace: AWS/RDS
      MetricName: DatabaseConnections
      Dimensions:
        - Name: DBClusterIdentifier
          Value: !Ref AuroraCluster
      Statistic: Maximum
      Period: 60
      EvaluationPeriods: 5
      Threshold: 1600
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: notBreaching
      AlarmActions: [!Ref AlarmTopicArn]

  DeadlockAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub 'orders-plat-${EnvName}-deadlocks'
      AlarmDescription: Deadlocks detected on the writer.
      Namespace: AWS/RDS
      MetricName: Deadlocks
      Dimensions:
        - Name: DBClusterIdentifier
          Value: !Ref AuroraCluster
      Statistic: Sum
      Period: 300
      EvaluationPeriods: 1
      Threshold: 0
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: notBreaching
      AlarmActions: [!Ref AlarmTopicArn]

  ClusterEventSubscription:
    Type: AWS::RDS::EventSubscription
    Properties:
      SnsTopicArn: !Ref AlarmTopicArn
      SourceType: db-cluster
      SourceIds:
        - !Ref AuroraCluster
      EventCategories:
        - failover
        - failure
        - maintenance
        - notification
      Enabled: true

Outputs:
  ClusterWriterEndpoint:
    Description: Writer endpoint — follows failover. Use for all writes.
    Value: !GetAtt AuroraCluster.Endpoint.Address
    Export:
      Name: !Sub '${AWS::StackName}-writer-endpoint'
  ClusterReaderEndpoint:
    Description: Reader endpoint — DNS round-robin across available readers.
    Value: !GetAtt AuroraCluster.ReadEndpoint.Address
    Export:
      Name: !Sub '${AWS::StackName}-reader-endpoint'
  ProxyEndpoint:
    Description: RDS Proxy endpoint — preferred for Lambda and short-lived pods.
    Value: !GetAtt DbProxy.Endpoint
    Export:
      Name: !Sub '${AWS::StackName}-proxy-endpoint'
  MasterSecretArn:
    Description: Secrets Manager ARN holding the master credentials.
    Value: !Ref MasterUserSecret
    Export:
      Name: !Sub '${AWS::StackName}-master-secret-arn'
  KmsKeyArn:
    Description: CMK protecting cluster storage, snapshots and Performance Insights.
    Value: !GetAtt DatabaseKmsKey.Arn
```

### 9.2 CloudFormation: tabla DynamoDB de auditoría con GSI, autoescalado, TTL, PITR y Streams

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >-
  orders-plat tenant audit feed. Single-table design with one GSI,
  provisioned capacity under Application Auto Scaling, TTL-based expiry,
  point-in-time recovery, KMS encryption and a Streams-driven consumer.

Parameters:
  EnvName:
    Type: String
    Default: prod
  TableReadMin:
    Type: Number
    Default: 50
  TableReadMax:
    Type: Number
    Default: 4000
  TableWriteMin:
    Type: Number
    Default: 100
  TableWriteMax:
    Type: Number
    Default: 8000
  TargetUtilization:
    Type: Number
    Default: 70

Resources:

  AuditKmsKey:
    Type: AWS::KMS::Key
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      Description: !Sub 'CMK for orders-plat ${EnvName} audit table'
      EnableKeyRotation: true
      KeyPolicy:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              AWS: !Sub 'arn:${AWS::Partition}:iam::${AWS::AccountId}:root'
            Action: 'kms:*'
            Resource: '*'

  AuditTable:
    Type: AWS::DynamoDB::Table
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      TableName: !Sub 'orders-plat-${EnvName}-audit'
      BillingMode: PROVISIONED
      TableClass: STANDARD
      DeletionProtectionEnabled: true

      # PK groups all events of one tenant; SK gives chronological range queries.
      AttributeDefinitions:
        - AttributeName: pk            # TENANT#<tenant_id>
          AttributeType: S
        - AttributeName: sk            # TS#<iso8601>#<event_uuid>
          AttributeType: S
        - AttributeName: gsi1pk        # ACTOR#<principal_arn>
          AttributeType: S
        - AttributeName: gsi1sk        # TS#<iso8601>
          AttributeType: S
      KeySchema:
        - AttributeName: pk
          KeyType: HASH
        - AttributeName: sk
          KeyType: RANGE

      ProvisionedThroughput:
        ReadCapacityUnits: !Ref TableReadMin
        WriteCapacityUnits: !Ref TableWriteMin

      GlobalSecondaryIndexes:
        - IndexName: gsi1-actor-time
          KeySchema:
            - AttributeName: gsi1pk
              KeyType: HASH
            - AttributeName: gsi1sk
              KeyType: RANGE
          Projection:
            ProjectionType: INCLUDE
            NonKeyAttributes:
              - action
              - resource
              - outcome
          ProvisionedThroughput:
            ReadCapacityUnits: !Ref TableReadMin
            WriteCapacityUnits: !Ref TableWriteMin

      TimeToLiveSpecification:
        AttributeName: expires_at        # epoch seconds
        Enabled: true

      PointInTimeRecoverySpecification:
        PointInTimeRecoveryEnabled: true

      SSESpecification:
        SSEEnabled: true
        SSEType: KMS
        KMSMasterKeyId: !Ref AuditKmsKey

      StreamSpecification:
        StreamViewType: NEW_AND_OLD_IMAGES

      ContributorInsightsSpecification:
        Enabled: true

      Tags:
        - Key: Environment
          Value: !Ref EnvName
        - Key: DataClassification
          Value: audit

  # ------------------------------------------------- Application Auto Scaling
  AutoScalingRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: application-autoscaling.amazonaws.com
            Action: sts:AssumeRole
      Policies:
        - PolicyName: dynamodb-autoscaling
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - dynamodb:DescribeTable
                  - dynamodb:UpdateTable
                Resource:
                  - !GetAtt AuditTable.Arn
                  - !Sub '${AuditTable.Arn}/index/*'
              - Effect: Allow
                Action:
                  - cloudwatch:PutMetricAlarm
                  - cloudwatch:DescribeAlarms
                  - cloudwatch:DeleteAlarms
                  - cloudwatch:GetMetricStatistics
                  - cloudwatch:SetAlarmState
                Resource: '*'

  TableWriteScalableTarget:
    Type: AWS::ApplicationAutoScaling::ScalableTarget
    Properties:
      ServiceNamespace: dynamodb
      ResourceId: !Sub 'table/${AuditTable}'
      ScalableDimension: 'dynamodb:table:WriteCapacityUnits'
      MinCapacity: !Ref TableWriteMin
      MaxCapacity: !Ref TableWriteMax
      RoleARN: !GetAtt AutoScalingRole.Arn

  TableWriteScalingPolicy:
    Type: AWS::ApplicationAutoScaling::ScalingPolicy
    Properties:
      PolicyName: !Sub '${AuditTable}-write-target-tracking'
      PolicyType: TargetTrackingScaling
      ScalingTargetId: !Ref TableWriteScalableTarget
      TargetTrackingScalingPolicyConfiguration:
        TargetValue: !Ref TargetUtilization
        ScaleInCooldown: 300
        ScaleOutCooldown: 60
        PredefinedMetricSpecification:
          PredefinedMetricType: DynamoDBWriteCapacityUtilization

  TableReadScalableTarget:
    Type: AWS::ApplicationAutoScaling::ScalableTarget
    Properties:
      ServiceNamespace: dynamodb
      ResourceId: !Sub 'table/${AuditTable}'
      ScalableDimension: 'dynamodb:table:ReadCapacityUnits'
      MinCapacity: !Ref TableReadMin
      MaxCapacity: !Ref TableReadMax
      RoleARN: !GetAtt AutoScalingRole.Arn

  TableReadScalingPolicy:
    Type: AWS::ApplicationAutoScaling::ScalingPolicy
    Properties:
      PolicyName: !Sub '${AuditTable}-read-target-tracking'
      PolicyType: TargetTrackingScaling
      ScalingTargetId: !Ref TableReadScalableTarget
      TargetTrackingScalingPolicyConfiguration:
        TargetValue: !Ref TargetUtilization
        ScaleInCooldown: 300
        ScaleOutCooldown: 60
        PredefinedMetricSpecification:
          PredefinedMetricType: DynamoDBReadCapacityUtilization

  # A throttled GSI back-pressures writes onto the BASE table. Scale it too.
  IndexWriteScalableTarget:
    Type: AWS::ApplicationAutoScaling::ScalableTarget
    Properties:
      ServiceNamespace: dynamodb
      ResourceId: !Sub 'table/${AuditTable}/index/gsi1-actor-time'
      ScalableDimension: 'dynamodb:index:WriteCapacityUnits'
      MinCapacity: !Ref TableWriteMin
      MaxCapacity: !Ref TableWriteMax
      RoleARN: !GetAtt AutoScalingRole.Arn

  IndexWriteScalingPolicy:
    Type: AWS::ApplicationAutoScaling::ScalingPolicy
    Properties:
      PolicyName: !Sub '${AuditTable}-gsi1-write-target-tracking'
      PolicyType: TargetTrackingScaling
      ScalingTargetId: !Ref IndexWriteScalableTarget
      TargetTrackingScalingPolicyConfiguration:
        TargetValue: !Ref TargetUtilization
        ScaleInCooldown: 300
        ScaleOutCooldown: 60
        PredefinedMetricSpecification:
          PredefinedMetricType: DynamoDBWriteCapacityUtilization

  # ----------------------------------------------------------------- alarms
  WriteThrottleAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub '${AuditTable}-write-throttles'
      AlarmDescription: Writes are being rejected — capacity or hot partition.
      Namespace: AWS/DynamoDB
      MetricName: WriteThrottleEvents
      Dimensions:
        - Name: TableName
          Value: !Ref AuditTable
      Statistic: Sum
      Period: 60
      EvaluationPeriods: 3
      Threshold: 0
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: notBreaching

  SystemErrorAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub '${AuditTable}-system-errors'
      AlarmDescription: HTTP 500s from DynamoDB — service-side failures.
      Namespace: AWS/DynamoDB
      MetricName: SystemErrors
      Dimensions:
        - Name: TableName
          Value: !Ref AuditTable
      Statistic: Sum
      Period: 300
      EvaluationPeriods: 1
      Threshold: 0
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: notBreaching

Outputs:
  TableName:
    Value: !Ref AuditTable
  TableArn:
    Value: !GetAtt AuditTable.Arn
  StreamArn:
    Description: Feed this to a Lambda EventSourceMapping or Kinesis consumer.
    Value: !GetAtt AuditTable.StreamArn
```

### 9.3 Kubernetes: ACK (AWS Controllers for Kubernetes) + External Secrets

Declarar las bases de datos de AWS desde el mismo repositorio GitOps que las cargas de trabajo mantiene un único bucle de reconciliación en lugar de dos.

```yaml
---
# Subnet group — the ACK RDS controller reconciles this into a real AWS resource.
apiVersion: rds.services.k8s.aws/v1alpha1
kind: DBSubnetGroup
metadata:
  name: orders-plat-prod
  namespace: data
spec:
  name: orders-plat-prod
  description: Private subnets across three AZs for orders-plat.
  subnetIDs:
    - subnet-0a1b2c3d4e5f60718
    - subnet-0a1b2c3d4e5f60719
    - subnet-0a1b2c3d4e5f6071a
  tags:
    - key: Environment
      value: prod
---
apiVersion: rds.services.k8s.aws/v1alpha1
kind: DBClusterParameterGroup
metadata:
  name: orders-plat-prod-cluster-pg
  namespace: data
spec:
  name: orders-plat-prod-cluster-pg
  description: orders-plat cluster parameters (TLS enforced, slow-query logging).
  family: aurora-postgresql16
  parameterOverrides:
    rds.force_ssl: "1"
    log_min_duration_statement: "1000"
    shared_preload_libraries: "pg_stat_statements,auto_explain"
---
apiVersion: v1
kind: Secret
metadata:
  name: aurora-master-password
  namespace: data
type: Opaque
stringData:
  # In practice this Secret is itself produced by External Secrets from
  # Secrets Manager; it is inlined here only to show the reference shape.
  password: "REPLACED-BY-EXTERNAL-SECRETS"
---
apiVersion: rds.services.k8s.aws/v1alpha1
kind: DBCluster
metadata:
  name: orders-plat-prod
  namespace: data
spec:
  dbClusterIdentifier: orders-plat-prod
  engine: aurora-postgresql
  engineVersion: "16.4"
  databaseName: orders
  masterUsername: ordersadmin
  masterUserPassword:
    namespace: data
    name: aurora-master-password
    key: password
  dbSubnetGroupName: orders-plat-prod
  dbClusterParameterGroupName: orders-plat-prod-cluster-pg
  vpcSecurityGroupIDs:
    - sg-0f1e2d3c4b5a69788
  storageEncrypted: true
  kmsKeyID: arn:aws:kms:eu-west-1:111122223333:key/1c9d2f4e-8a3b-4c5d-9e0f-1a2b3c4d5e6f
  backupRetentionPeriod: 35
  preferredBackupWindow: "03:00-04:00"
  preferredMaintenanceWindow: "sun:05:00-sun:06:00"
  deletionProtection: true
  enableIAMDatabaseAuthentication: true
  enableCloudwatchLogsExports:
    - postgresql
  serverlessV2ScalingConfiguration:
    minCapacity: 2
    maxCapacity: 32
  tags:
    - key: Environment
      value: prod
---
apiVersion: rds.services.k8s.aws/v1alpha1
kind: DBInstance
metadata:
  name: orders-plat-prod-writer
  namespace: data
spec:
  dbInstanceIdentifier: orders-plat-prod-writer
  dbClusterIdentifier: orders-plat-prod
  engine: aurora-postgresql
  dbInstanceClass: db.r6g.2xlarge
  promotionTier: 0
  enablePerformanceInsights: true
  performanceInsightsRetentionPeriod: 465
  monitoringInterval: 10
  publiclyAccessible: false
---
apiVersion: rds.services.k8s.aws/v1alpha1
kind: DBInstance
metadata:
  name: orders-plat-prod-reader-1
  namespace: data
spec:
  dbInstanceIdentifier: orders-plat-prod-reader-1
  dbClusterIdentifier: orders-plat-prod
  engine: aurora-postgresql
  dbInstanceClass: db.serverless
  promotionTier: 1
  enablePerformanceInsights: true
  publiclyAccessible: false
---
# DynamoDB audit table, same GitOps repo, same reconciliation loop.
apiVersion: dynamodb.services.k8s.aws/v1alpha1
kind: Table
metadata:
  name: orders-plat-prod-audit
  namespace: data
spec:
  tableName: orders-plat-prod-audit
  billingMode: PAY_PER_REQUEST
  attributeDefinitions:
    - attributeName: pk
      attributeType: S
    - attributeName: sk
      attributeType: S
    - attributeName: gsi1pk
      attributeType: S
    - attributeName: gsi1sk
      attributeType: S
  keySchema:
    - attributeName: pk
      keyType: HASH
    - attributeName: sk
      keyType: RANGE
  globalSecondaryIndexes:
    - indexName: gsi1-actor-time
      keySchema:
        - attributeName: gsi1pk
          keyType: HASH
        - attributeName: gsi1sk
          keyType: RANGE
      projection:
        projectionType: INCLUDE
        nonKeyAttributes: [action, resource, outcome]
  timeToLive:
    attributeName: expires_at
    enabled: true
  pointInTimeRecovery:
    enabled: true
  sseSpecification:
    enabled: true
    sseType: KMS
  streamSpecification:
    streamEnabled: true
    streamViewType: NEW_AND_OLD_IMAGES
  tags:
    - key: Environment
      value: prod
---
# Pull the rotated master credential out of Secrets Manager into the cluster.
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secretsmanager
spec:
  provider:
    aws:
      service: SecretsManager
      region: eu-west-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: orders-db-credentials
  namespace: orders
spec:
  refreshInterval: 15m       # shorter than the Secrets Manager rotation period
  secretStoreRef:
    name: aws-secretsmanager
    kind: ClusterSecretStore
  target:
    name: orders-db
    creationPolicy: Owner
    template:
      engineVersion: v2
      data:
        # libpq DSN assembled from the JSON that Secrets Manager stores.
        DATABASE_URL: >-
          postgresql://{{ .username }}:{{ .password }}@{{ .host }}:{{ .port }}/orders?sslmode=verify-full&sslrootcert=/etc/ssl/certs/rds-global-bundle.pem
  dataFrom:
    - extract:
        key: orders-plat/prod/aurora/master
---
# Application deployment: reads the DSN, mounts the RDS CA bundle, and
# points writes at the proxy endpoint.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: orders-api
  namespace: orders
spec:
  replicas: 6
  selector:
    matchLabels:
      app: orders-api
  template:
    metadata:
      labels:
        app: orders-api
    spec:
      serviceAccountName: orders-api
      containers:
        - name: api
          image: registry.internal/orders-api:1.42.0
          ports:
            - containerPort: 8080
          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: orders-db
                  key: DATABASE_URL
            - name: DATABASE_READ_HOST
              value: orders-plat-prod.cluster-ro-cxyz123abc.eu-west-1.rds.amazonaws.com
            - name: PGPOOL_MAX_CONNS
              value: "20"
            # Force short JVM/DNS caching so the reader endpoint rebalances.
            - name: AWS_STS_REGIONAL_ENDPOINTS
              value: regional
          volumeMounts:
            - name: rds-ca
              mountPath: /etc/ssl/certs/rds-global-bundle.pem
              subPath: rds-global-bundle.pem
              readOnly: true
          readinessProbe:
            httpGet:
              path: /healthz/db
              port: 8080
            initialDelaySeconds: 10
            periodSeconds: 5
          resources:
            requests:
              cpu: 500m
              memory: 512Mi
            limits:
              memory: 1Gi
      volumes:
        - name: rds-ca
          configMap:
            name: rds-ca-bundle
```

### 9.4 DMS: tarea de replicación con table mappings y settings

```json
{
  "rules": [
    {
      "rule-type": "selection",
      "rule-id": "1",
      "rule-name": "include-orders-schema",
      "object-locator": {
        "schema-name": "ORDERS",
        "table-name": "%"
      },
      "rule-action": "include",
      "filters": []
    },
    {
      "rule-type": "selection",
      "rule-id": "2",
      "rule-name": "exclude-staging-tables",
      "object-locator": {
        "schema-name": "ORDERS",
        "table-name": "STG_%"
      },
      "rule-action": "exclude",
      "filters": []
    },
    {
      "rule-type": "transformation",
      "rule-id": "3",
      "rule-name": "lowercase-schema",
      "rule-target": "schema",
      "object-locator": { "schema-name": "ORDERS" },
      "rule-action": "convert-lowercase"
    },
    {
      "rule-type": "transformation",
      "rule-id": "4",
      "rule-name": "lowercase-tables",
      "rule-target": "table",
      "object-locator": { "schema-name": "ORDERS", "table-name": "%" },
      "rule-action": "convert-lowercase"
    },
    {
      "rule-type": "transformation",
      "rule-id": "5",
      "rule-name": "lowercase-columns",
      "rule-target": "column",
      "object-locator": {
        "schema-name": "ORDERS",
        "table-name": "%",
        "column-name": "%"
      },
      "rule-action": "convert-lowercase"
    }
  ]
}
```

```json
{
  "TargetMetadata": {
    "TargetSchema": "",
    "SupportLobs": true,
    "FullLobMode": false,
    "LobChunkSize": 64,
    "LimitedSizeLobMode": true,
    "LobMaxSize": 32,
    "BatchApplyEnabled": true,
    "ParallelLoadThreads": 8,
    "ParallelLoadBufferSize": 200
  },
  "FullLoadSettings": {
    "TargetTablePrepMode": "DROP_AND_CREATE",
    "MaxFullLoadSubTasks": 8,
    "TransactionConsistencyTimeout": 600,
    "CommitRate": 10000,
    "StopTaskCachedChangesApplied": false,
    "StopTaskCachedChangesNotApplied": false
  },
  "Logging": {
    "EnableLogging": true,
    "LogComponents": [
      { "Id": "SOURCE_UNLOAD",  "Severity": "LOGGER_SEVERITY_DEFAULT" },
      { "Id": "TARGET_LOAD",    "Severity": "LOGGER_SEVERITY_DEFAULT" },
      { "Id": "SOURCE_CAPTURE", "Severity": "LOGGER_SEVERITY_DETAILED_DEBUG" },
      { "Id": "TARGET_APPLY",   "Severity": "LOGGER_SEVERITY_DETAILED_DEBUG" }
    ]
  },
  "ValidationSettings": {
    "EnableValidation": true,
    "ValidationMode": "ROW_LEVEL",
    "ThreadCount": 5,
    "PartitionSize": 10000,
    "FailureMaxCount": 10000,
    "HandleCollationDiff": true,
    "RecordFailureDelayLimitInMinutes": 0,
    "TableFailureMaxCount": 1000
  },
  "ErrorBehavior": {
    "DataErrorPolicy": "LOG_ERROR",
    "TableErrorPolicy": "SUSPEND_TABLE",
    "ApplyErrorDeletePolicy": "IGNORE_RECORD",
    "ApplyErrorInsertPolicy": "LOG_ERROR",
    "ApplyErrorUpdatePolicy": "LOG_ERROR",
    "FullLoadIgnoreConflicts": true
  },
  "ChangeProcessingTuning": {
    "BatchApplyPreserveTransaction": true,
    "BatchApplyTimeoutMin": 1,
    "BatchApplyTimeoutMax": 30,
    "MinTransactionSize": 1000,
    "CommitTimeout": 1,
    "MemoryLimitTotal": 1024,
    "MemoryKeepTime": 60,
    "StatementCacheSize": 50
  }
}
```

---

## 10. CLI: comandos y salida real de terminal

### 10.1 Desplegar e inspeccionar el cluster Aurora

```
$ aws cloudformation deploy \
    --stack-name orders-plat-prod-aurora \
    --template-file aurora-cluster.yaml \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides \
        EnvName=prod \
        VpcId=vpc-0d1e2f3a4b5c6d7e8 \
        PrivateSubnetIds=subnet-0a1b2c3d4e5f60718,subnet-0a1b2c3d4e5f60719,subnet-0a1b2c3d4e5f6071a \
        AppSecurityGroupId=sg-0aa11bb22cc33dd44 \
        AlarmTopicArn=arn:aws:sns:eu-west-1:111122223333:oncall-data \
    --tags Environment=prod Owner=platform-sre

Waiting for changeset to be created..
Waiting for stack create/update to complete
Successfully created/updated stack - orders-plat-prod-aurora
```

```
$ aws rds describe-db-clusters \
    --db-cluster-identifier orders-plat-prod \
    --query 'DBClusters[0].{Status:Status,Engine:EngineVersion,MultiAZ:MultiAZ,
             Writer:Endpoint,Reader:ReaderEndpoint,Storage:StorageType,
             Backup:BackupRetentionPeriod,Encrypted:StorageEncrypted,
             Members:DBClusterMembers[].{Id:DBInstanceIdentifier,IsWriter:IsClusterWriter,Tier:PromotionTier}}' \
    --output table

------------------------------------------------------------------------------------
|                                DescribeDBClusters                                |
+------------+---------------------------------------------------------------------+
|  Backup    |  35                                                                 |
|  Encrypted |  True                                                               |
|  Engine    |  16.4                                                               |
|  MultiAZ   |  True                                                               |
|  Reader    |  orders-plat-prod.cluster-ro-cxyz123abc.eu-west-1.rds.amazonaws.com |
|  Status    |  available                                                          |
|  Storage   |  aurora-iopt1                                                       |
|  Writer    |  orders-plat-prod.cluster-cxyz123abc.eu-west-1.rds.amazonaws.com    |
+------------+---------------------------------------------------------------------+
||                                    Members                                     ||
|+----------------------------------+--------------+------------------------------+|
||               Id                 |   IsWriter   |             Tier             ||
|+----------------------------------+--------------+------------------------------+|
||  orders-plat-prod-writer         |  True        |  0                           ||
||  orders-plat-prod-reader-1       |  False       |  1                           ||
||  orders-plat-prod-reader-2       |  False       |  1                           ||
|+----------------------------------+--------------+------------------------------+|
```

Confirmá que los miembros están realmente en tres AZ distintas — este es el chequeo que la gente se saltea:

```
$ aws rds describe-db-instances \
    --filters Name=db-cluster-id,Values=orders-plat-prod \
    --query 'DBInstances[].{Id:DBInstanceIdentifier,AZ:AvailabilityZone,
             Class:DBInstanceClass,Status:DBInstanceStatus,PI:PerformanceInsightsEnabled}' \
    --output table

--------------------------------------------------------------------------------
|                              DescribeDBInstances                             |
+----------------+---------------+----------------------+-----------+----------+
|      AZ        |    Class      |         Id           |    PI     |  Status  |
+----------------+---------------+----------------------+-----------+----------+
|  eu-west-1a    |  db.r6g.2xl   |  orders-plat-prod-w..|  True     |  available|
|  eu-west-1b    |  db.serverless|  orders-plat-prod-r1 |  True     |  available|
|  eu-west-1c    |  db.serverless|  orders-plat-prod-r2 |  True     |  available|
+----------------+---------------+----------------------+-----------+----------+
```

### 10.2 Conectarse con autenticación IAM y TLS

```
$ export PGHOST=orders-plat-prod-proxy.proxy-cxyz123abc.eu-west-1.rds.amazonaws.com
$ export PGPASSWORD="$(aws rds generate-db-auth-token \
      --hostname "$PGHOST" --port 5432 --username orders_app --region eu-west-1)"

$ psql "host=$PGHOST port=5432 dbname=orders user=orders_app \
        sslmode=verify-full sslrootcert=/etc/ssl/certs/rds-global-bundle.pem"

psql (16.4, server 16.4)
SSL connection (protocol: TLSv1.3, cipher: TLS_AES_256_GCM_SHA384, compression: off)
Type "help" for help.

orders=> SELECT current_setting('server_version'),
                pg_is_in_recovery() AS is_reader,
                inet_server_addr()  AS backend_ip;
 current_setting | is_reader |  backend_ip
-----------------+-----------+---------------
 16.4            | f         | 10.42.11.204
(1 row)
```

> El token de autenticación IAM es válido por **15 minutos**. Los pods de larga vida deben regenerarlo antes de cada conexión nueva, no una sola vez al arrancar — el clásico incidente de "funciona 15 minutos después del deploy y después `PAM authentication failed`".

### 10.3 Ensayar el failover (hacé esto en staging de forma programada)

```
$ date -u +%FT%TZ && aws rds failover-db-cluster \
    --db-cluster-identifier orders-plat-staging \
    --target-db-instance-identifier orders-plat-staging-reader-1 \
    --query 'DBCluster.Status' --output text
2026-09-04T09:41:07Z
failing-over
```

```
$ while true; do
    printf '%s ' "$(date -u +%T)"
    psql -h orders-plat-staging.cluster-cxyz123abc.eu-west-1.rds.amazonaws.com \
         -U ordersadmin -d orders -tAc \
         "select case when pg_is_in_recovery() then 'READER' else 'WRITER' end" \
         2>&1 | tr -d '\n'
    echo
    sleep 1
  done

09:41:08 WRITER
09:41:09 WRITER
09:41:10 psql: error: connection to server ... failed: server closed the connection unexpectedly
09:41:11 psql: error: connection to server ... failed: Connection refused
09:41:12 psql: error: connection to server ... failed: Connection refused
...
09:41:26 psql: error: connection to server ... failed: Connection refused
09:41:27 WRITER
09:41:28 WRITER
```

**RTO medido: 19 segundos.** Registrá este número; es la única cifra de failover que deberías citar en una revisión de diseño, porque el "típicamente menos de 30 segundos" del marketing es una distribución, no tu SLO.

Confirmá la promoción en el flujo de eventos:

```
$ aws rds describe-events \
    --source-identifier orders-plat-staging \
    --source-type db-cluster \
    --duration 10 \
    --query 'Events[].{Time:Date,Message:Message}' --output table

------------------------------------------------------------------------------------
|                                  DescribeEvents                                  |
+---------------------------+------------------------------------------------------+
|  2026-09-04T09:41:08Z     |  Started cross AZ failover to DB instance:            |
|                           |  orders-plat-staging-reader-1                         |
|  2026-09-04T09:41:24Z     |  Completed failover to DB instance:                   |
|                           |  orders-plat-staging-reader-1                         |
+---------------------------+------------------------------------------------------+
```

### 10.4 DynamoDB: la contabilidad de capacidad hecha visible

```
$ aws dynamodb describe-table --table-name orders-plat-prod-audit \
    --query 'Table.{Status:TableStatus,Items:ItemCount,Bytes:TableSizeBytes,
             Billing:BillingModeSummary.BillingMode,
             RCU:ProvisionedThroughput.ReadCapacityUnits,
             WCU:ProvisionedThroughput.WriteCapacityUnits,
             Stream:LatestStreamArn,Indexes:GlobalSecondaryIndexes[].IndexName}' \
    --output json
{
    "Status": "ACTIVE",
    "Items": 418293774,
    "Bytes": 902334119488,
    "Billing": "PROVISIONED",
    "RCU": 400,
    "WCU": 2200,
    "Stream": "arn:aws:dynamodb:eu-west-1:111122223333:table/orders-plat-prod-audit/stream/2026-08-19T11:04:22.117",
    "Indexes": [
        "gsi1-actor-time"
    ]
}
```

Pedí siempre la capacidad consumida cuando perfilás una consulta — convierte una opinión en un número:

```
$ aws dynamodb query \
    --table-name orders-plat-prod-audit \
    --key-condition-expression "pk = :t AND sk BETWEEN :a AND :b" \
    --expression-attribute-values '{
        ":t": {"S": "TENANT#4711"},
        ":a": {"S": "TS#2026-09-04T00:00:00Z"},
        ":b": {"S": "TS#2026-09-04T23:59:59Z"}
    }' \
    --return-consumed-capacity INDEXES \
    --max-items 5 \
    --query '{Count:Count,Scanned:ScannedCount,Capacity:ConsumedCapacity}' \
    --output json
{
    "Count": 5,
    "Scanned": 5,
    "Capacity": {
        "TableName": "orders-plat-prod-audit",
        "CapacityUnits": 3.5,
        "Table": {
            "CapacityUnits": 3.5
        }
    }
}
```

`Count == ScannedCount` significa que la condición de clave hizo todo el filtrado. Cuando `ScannedCount` es órdenes de magnitud mayor que `Count`, estás pagando por filas que una `FilterExpression` descartó **después** de haberlas leído y facturado — eso es un bug de esquema, no un problema de capacidad.

Observá el throttling en vivo:

```
$ aws cloudwatch get-metric-statistics \
    --namespace AWS/DynamoDB \
    --metric-name ThrottledRequests \
    --dimensions Name=TableName,Value=orders-plat-prod-audit \
    --start-time 2026-09-04T08:00:00Z --end-time 2026-09-04T10:00:00Z \
    --period 300 --statistics Sum \
    --query 'sort_by(Datapoints,&Timestamp)[?Sum>`0`].[Timestamp,Sum]' \
    --output text

2026-09-04T08:45:00Z    1842.0
2026-09-04T08:50:00Z    9317.0
2026-09-04T08:55:00Z    8804.0
2026-09-04T09:00:00Z    212.0
```

Después encontrá *qué clave* está caliente:

```
$ aws cloudwatch get-metric-data --cli-input-json file://hot-key-query.json \
    --query 'MetricDataResults[0].{Label:Label,Max:max(Values)}' --output json
{
    "Label": "MostAccessedKeys - pk=TENANT#4711",
    "Max": 3021.0
}
```

3 021 > el techo de 3 000 RCU por partición. Ninguna cantidad de capacidad a nivel de tabla arregla esto; la clave debe ser **write-sharded** (`TENANT#4711#<0..9>`) o la lectura tiene que pasar por DAX.

### 10.5 ElastiCache

```
$ aws elasticache describe-replication-groups \
    --replication-group-id orders-plat-prod-sessions \
    --query 'ReplicationGroups[0].{Status:Status,Engine:Engine,
             Shards:length(NodeGroups),MultiAZ:MultiAZ,
             Failover:AutomaticFailover,Encrypted:AtRestEncryptionEnabled,
             TLS:TransitEncryptionEnabled,Endpoint:ConfigurationEndpoint.Address}' \
    --output table

------------------------------------------------------------------------------------
|                            DescribeReplicationGroups                             |
+-------------+--------------------------------------------------------------------+
|  Encrypted  |  True                                                              |
|  Endpoint   |  orders-plat-prod-sessions.abc123.clustercfg.euw1.cache.amazonaws.com|
|  Engine     |  valkey                                                            |
|  Failover   |  enabled                                                           |
|  MultiAZ    |  enabled                                                           |
|  Shards     |  3                                                                 |
|  Status     |  available                                                         |
|  TLS        |  True                                                              |
+-------------+--------------------------------------------------------------------+
```

```
$ redis-cli --tls -h orders-plat-prod-sessions.abc123.clustercfg.euw1.cache.amazonaws.com -p 6379 \
    INFO stats | egrep 'keyspace_hits|keyspace_misses|evicted_keys|expired_keys'
keyspace_hits:884215663
keyspace_misses:19042771
evicted_keys:0
expired_keys:41228390
```

Ratio de aciertos = 884215663 / (884215663 + 19042771) ≈ **97,9 %**. `evicted_keys:0` significa que la presión de memoria no está forzando desalojos — si ese número trepa, la caché está subdimensionada y `maxmemory-policy` está decidiendo en silencio qué pierden tus usuarios.

### 10.6 Cutover de DMS

```
$ aws dms describe-replication-tasks \
    --filters Name=replication-task-id,Values=oracle-to-aurora-orders \
    --query 'ReplicationTasks[0].{Status:Status,Migration:MigrationType,
             Pct:ReplicationTaskStats.FullLoadProgressPercent,
             Tables:ReplicationTaskStats.TablesLoaded,
             Errored:ReplicationTaskStats.TablesErrored,
             LagSec:ReplicationTaskStats.ElapsedTimeMillis}' --output json
{
    "Status": "running",
    "Migration": "full-load-and-cdc",
    "Pct": 100,
    "Tables": 147,
    "Errored": 0,
    "LagSec": 5184000
}
```

```
$ aws dms describe-table-statistics \
    --replication-task-arn arn:aws:dms:eu-west-1:111122223333:task:ORACLE2AURORA \
    --query 'TableStatistics[?ValidationState!=`Validated`].[SchemaName,TableName,
             ValidationState,ValidationFailedRecords]' --output table

-----------------------------------------------------------------------------
|                          DescribeTableStatistics                          |
+----------+----------------+-----------------------+----------------------+
|  orders  |  order_items   |  Mismatched records   |  312                 |
+----------+----------------+-----------------------+----------------------+
```

312 filas con discrepancia significa **no hagas el cutover**. Inspeccioná `awsdms_validation_failures_v1` en el destino antes de que alguien declare terminada la migración:

```
$ psql -h orders-plat-prod.cluster-cxyz123abc.eu-west-1.rds.amazonaws.com -U ordersadmin -d orders \
    -c "SELECT table_name, failure_type, count(*)
        FROM awsdms_validation_failures_v1
        GROUP BY 1,2 ORDER BY 3 DESC LIMIT 5;"

 table_name  |   failure_type    | count
-------------+-------------------+-------
 order_items | RECORD_DIFF       |   298
 order_items | MISSING_TARGET    |    14
(2 rows)
```

`RECORD_DIFF` en este volumen sobre un mapeo `NUMBER` → `numeric` es casi siempre una **truncación de precisión/escala** introducida por los valores por defecto de SCT. Corregí el DDL del destino, recargá la tabla, revalidá.

---

## 11. Verificación y diagnóstico de fallos

### 11.1 Puerta de aceptación previa a producción

Ejecutá cada ítem; un "sí" que no fue producido por un comando no es un sí.

| # | Afirmación | Comando | Condición de aprobación |
|---|---|---|---|
| 1 | Los miembros del cluster ocupan ≥ 3 AZ | `aws rds describe-db-instances --filters Name=db-cluster-id,...` | 3 valores distintos de `AvailabilityZone` |
| 2 | Almacenamiento cifrado con una CMK | `aws rds describe-db-clusters --query 'DBClusters[0].[StorageEncrypted,KmsKeyId]'` | `True` + un ARN de clave de cliente, no `alias/aws/rds` |
| 3 | Retención de backups ≥ 7 días | la misma consulta, `BackupRetentionPeriod` | ≥ 7 (35 para datos regulados) |
| 4 | Protección contra borrado activada | `DeletionProtection` | `true` |
| 5 | No accesible públicamente | `aws rds describe-db-instances ... PubliclyAccessible` | `false` en todos los miembros |
| 6 | TLS forzado en el motor | `SHOW rds.force_ssl;` | `on` |
| 7 | RTO de failover medido, no supuesto | failover en staging + el bucle de sondeo de 1 s de §10.3 | RTO observado < SLO con margen |
| 8 | Restauración PITR ensayada | `aws rds restore-db-cluster-to-point-in-time` a un cluster descartable, después conteos de filas | Los conteos coinciden con la fuente en el timestamp de destino |
| 9 | PITR de DynamoDB habilitado | `aws dynamodb describe-continuous-backups` | `PointInTimeRecoveryStatus: ENABLED` |
| 10 | El throttling de GSI tiene su propia alarma | `aws cloudwatch describe-alarms --alarm-name-prefix ...` | Existe una alarma dimensionada sobre `GlobalSecondaryIndexName` |

Un ensayo de restauración que nunca se realizó no es una estrategia de backup — es una afirmación no verificada sobre una ruta de código que sólo se ejecuta durante tu peor hora.

### 11.2 Matriz de diagnóstico de fallos

| Síntoma | Señal primaria | Causa raíz | Remediación |
|---|---|---|---|
| `FATAL: remaining connection slots are reserved` | `DatabaseConnections` en el techo; pods de la app en `CrashLoopBackOff` | Tormenta de conexiones — cada pod abre su propio pool; `max_connections` escala con la memoria de la instancia | Poné **RDS Proxy** adelante; limitá el tamaño del pool por pod; configurá `idle_in_transaction_session_timeout` |
| Las lecturas devuelven datos obsoletos tras una escritura | `AuroraReplicaLag` > 0 (normal), la app lee del endpoint de lectura | La replicación al lector es asíncrona — la lectura tras escritura no está garantizada | Enrutá el tráfico de leer-tus-propias-escrituras al endpoint **escritor**; o usá el LSN de la sesión con un gating por `pg_wal_lsn_diff` |
| Las escrituras van bien, las lecturas de golpe 10× más lentas | El `BufferCacheHitRatio` se derrumba; los `ReadIOPS` se disparan | Una consulta de reporting escaneó una tabla grande y desalojó el working set | Mové la analítica a un **endpoint personalizado** con lectores dedicados, o a Redshift |
| La app pierde la DB durante minutos tras un failover | El evento de failover se completó en ~20 s pero la app se recuperó en ~300 s | **Caché de DNS.** JVM con `networkaddress.cache.ttl=-1`, o un driver aferrado a sockets muertos | Poné el TTL de DNS de la JVM en 5–10 s; habilitá validación de conexiones a nivel de driver; usá RDS Proxy (sostiene el lado de la DB a través del failover) |
| `ProvisionedThroughputExceededException` con baja utilización de la tabla | `ThrottledRequests` > 0, `ConsumedWriteCapacityUnits` ≪ lo aprovisionado | **Partición caliente** — una sola PK supera 1 000 WCU / 3 000 RCU | Hacé write-sharding de la clave (`PK#<n>`), o agregá un prefijo de alta cardinalidad; verificá con CloudWatch Contributor Insights |
| Escrituras de la tabla base con throttling, capacidad base ociosa | `WriteThrottleEvents` en la tabla, `OnlineIndexThrottleEvents` del GSI > 0 | **Contrapresión del GSI** — el índice no puede absorber las escrituras | Escalá el GSI de forma independiente, o eliminá los GSI sin uso |
| Latencia de consulta bien, costo 20× la estimación | `ScannedCount ≫ Count` | La `FilterExpression` descarta filas **después** de haberlas leído y facturado | Rediseñá la clave/GSI para que la condición de clave haga el filtrado |
| `Storage-full` y la instancia en estado `storage-full` | `FreeStorageSpace` → 0 | Volumen de RDS agotado (Aurora crece solo; RDS **no**) | Habilitá **autoescalado de almacenamiento** con un máximo; en Aurora, buscá bloat/archivos temporales en su lugar |
| El disco de PostgreSQL crece sin crecimiento de datos | `TransactionLogsDiskUsage`, `OldestReplicationSlotLag` trepando | **Slot de replicación huérfano** (una tarea DMS muerta o un suscriptor lógico) reteniendo WAL | `SELECT pg_drop_replication_slot('<slot>');` después de confirmar que el consumidor ya no existe |
| Aurora Serverless v2 clavado en el ACU máximo | `ServerlessDatabaseCapacity` == `MaxCapacity` de forma continua | El escalado no puede recuperar memoria retenida por sesiones/tablas temporales de larga duración | Subí `MaxCapacity` y corregí la consulta; Serverless v2 escala hacia arriba rápido pero hacia abajo lento bajo presión de memoria |
| El p99 de la caché se dispara cada hora en punto | `evicted_keys` y los `ReadIOPS` de la DB se disparan juntos | **Expiración de TTL sincronizada** → estampida sobre el origen | Agregá jitter a los TTL; agregá un lock de regeneración por clave |
| `SSL error: certificate verify failed` tras un despliegue en una Región | Fallos de conexión repentinos sólo en los pods nuevos | Bundle de CA de RDS ausente o desactualizado; `rds-ca-2019` expiró, se requiere `rds-ca-rsa2048-g1` | Montá el bundle global de CA; rotá la CA de la instancia en una ventana de mantenimiento |
| El lag de CDC de DMS trepa sin límite | `CDCLatencySource` vs `CDCLatencyTarget` | Lado fuente: el lector de logs no da abasto. Lado destino: la falta de PK/índice convierte `UPDATE`/`DELETE` en un escaneo completo | Agregá claves primarias en el destino; habilitá `BatchApplyEnabled`; agrandá la instancia de replicación |

### 11.3 Caja de herramientas de consultas de diagnóstico

```
-- Aurora PostgreSQL: what is actually running right now, oldest first.
orders=> SELECT pid, now() - query_start AS runtime, state, wait_event_type,
                wait_event, left(query, 80) AS query
         FROM pg_stat_activity
         WHERE state <> 'idle' AND pid <> pg_backend_pid()
         ORDER BY query_start;

  pid  |    runtime      | state  | wait_event_type |   wait_event    |                query
-------+-----------------+--------+-----------------+-----------------+--------------------------------------
 18234 | 00:04:12.881003 | active | IO              | DataFileRead    | SELECT o.*, c.name FROM orders o JOIN
 19011 | 00:00:31.220417 | active | Lock            | transactionid   | UPDATE inventory SET qty = qty - 1 WH
 19044 | 00:00:31.109882 | active | Lock            | transactionid   | UPDATE inventory SET qty = qty - 1 WH
(3 rows)
```

Dos sesiones esperando en `Lock / transactionid` sobre la misma fila son un punto caliente de contención a un paso de un deadlock.

```
-- Top statements by total time — requires pg_stat_statements in
-- shared_preload_libraries (set in the cluster parameter group above).
orders=> SELECT calls,
                round(total_exec_time::numeric, 1)          AS total_ms,
                round(mean_exec_time::numeric, 2)           AS mean_ms,
                round(100 * shared_blks_hit::numeric
                      / nullif(shared_blks_hit + shared_blks_read, 0), 1) AS hit_pct,
                left(query, 60) AS query
         FROM pg_stat_statements
         ORDER BY total_exec_time DESC LIMIT 5;

  calls   |  total_ms   | mean_ms | hit_pct |                    query
----------+-------------+---------+---------+----------------------------------------------
  1204881 |  8842119.4  |    7.34 |    99.8 | SELECT * FROM orders WHERE customer_id = $1
    31207 |  4410882.1  |  141.34 |    62.1 | SELECT o.*, c.name FROM orders o JOIN custo
      412 |  2201338.9  | 5342.57 |     3.2 | SELECT date_trunc('month', created_at), sum
```

La fila 3 — 412 llamadas, 5,3 s de media, **3,2 % de ratio de aciertos de buffer** — es la consulta de reporting que pertenece a Redshift. No es lenta porque la base de datos esté subdimensionada; es lenta porque es una consulta OLAP sobre un motor OLTP.

```
-- Replication slots: the silent disk-filler.
orders=> SELECT slot_name, plugin, active,
                pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
         FROM pg_replication_slots ORDER BY 4 DESC;

     slot_name      |  plugin  | active | retained_wal
--------------------+----------+--------+--------------
 dms_orders_task_01 | pgoutput | f      | 412 GB
 logical_analytics  | pgoutput | t      | 84 MB
(2 rows)
```

Un slot **inactivo** reteniendo 412 GB de WAL es un incidente con cuenta regresiva. Confirmá que el consumidor está realmente muerto, y después eliminalo.

### 11.4 Métricas que deben estar en el dashboard

| Servicio | Métrica | Por qué importa |
|---|---|---|
| RDS / Aurora | `CPUUtilization`, `DatabaseConnections`, `FreeableMemory` | Saturación |
| | `AuroraReplicaLagMaximum` / `ReplicaLag` | Corrección del enrutamiento de lecturas |
| | `Deadlocks`, `BufferCacheHitRatio` | Contención y ajuste del working set |
| | `FreeStorageSpace` (RDS), `VolumeBytesUsed` (Aurora) | Capacidad |
| | `ServerlessDatabaseCapacity` | Margen y costo de Serverless v2 |
| | `TransactionLogsDiskUsage`, `OldestReplicationSlotLag` | La trampa del slot |
| DynamoDB | `ThrottledRequests`, `ReadThrottleEvents`, `WriteThrottleEvents` | Capacidad y claves calientes |
| | `ConsumedRead/WriteCapacityUnits` vs. lo aprovisionado | Dimensionamiento correcto |
| | `SuccessfulRequestLatency` (por operación) | Latencia visible para el cliente |
| | `UserErrors` vs `SystemErrors` | 4xx (tu bug) vs 5xx (AWS) |
| | `AgeOfOldestUnprocessedRecord` (consumidores de Streams) | Salud del pipeline |
| ElastiCache | `CacheHitRate`, `Evictions`, `DatabaseMemoryUsagePercentage` | Efectividad y dimensionamiento de la caché |
| | `CurrConnections`, `ReplicationLag` | Saturación y HA |
| DMS | `CDCLatencySource`, `CDCLatencyTarget`, `FullLoadThroughputRowsTarget` | Preparación para el cutover |

---

## 12. Síntesis orientada al examen

### 12.1 Mapeo palabra clave → servicio

| Frase del enunciado | Respuesta |
|---|---|
| "relacional, joins, SQL complejo, aplicación MySQL/Oracle existente" | **Amazon RDS** |
| "compatible con MySQL/PostgreSQL, 5×/3× de throughput, cloud-native, 6 copias en 3 AZ" | **Amazon Aurora** |
| "milisegundos de un dígito, cualquier escala, clave-valor, serverless, NoSQL" | **Amazon DynamoDB** |
| "lecturas en microsegundos para una app DynamoDB existente, sin cambios de código" | **DynamoDB Accelerator (DAX)** |
| "caché en memoria, reducir la carga de la base de datos, almacén de sesiones" | **Amazon ElastiCache** |
| "compatible con Redis pero debe ser durable y ser la base de datos primaria" | **Amazon MemoryDB** |
| "compatible con MongoDB, documentos JSON" | **Amazon DocumentDB** |
| "datos altamente conectados, relaciones, grafo social/de fraude/de recomendación" | **Amazon Neptune** |
| "compatible con Apache Cassandra, CQL, serverless" | **Amazon Keyspaces** |
| "mediciones IoT/de series temporales, billones de eventos por día" | **Amazon Timestream** |
| "data warehouse, business intelligence, analítica a escala de petabytes" | **Amazon Redshift** |
| "SQL directamente sobre S3, serverless, pago por consulta" | **Amazon Athena** (no es un servicio de base de datos, distractor habitual) |
| "migrar una base de datos a AWS con downtime mínimo" | **AWS DMS** |
| "convertir un esquema Oracle y procedimientos almacenados a PostgreSQL" | **AWS SCT** (después DMS) |
| "pooling de conexiones, muchas funciones Lambda saturando la base de datos" | **Amazon RDS Proxy** |
| "log de transacciones inmutable y verificable criptográficamente" | **Amazon QLDB** (retirado el 2025-07-31 — sólo como respuesta legacy) |
| "control total del SO y del motor de base de datos, agentes propios" | **Base de datos en EC2** (o RDS Custom) |

### 12.2 Las cinco distinciones que más se fallan

1. **Multi-AZ ≠ réplica de lectura.** Multi-AZ = síncrono, disponibilidad, standby no legible (modo instance). Réplica de lectura = asíncrona, escalado de lectura, legible, promocionable.
2. **DAX ≠ ElastiCache.** DAX es específico de DynamoDB y transparente a nivel de API; ElastiCache es genérico y requiere cambios en la aplicación.
3. **Redshift ≠ RDS.** Redshift es OLAP/columnar para analítica; no es una base de datos transaccional y nunca es la respuesta a "carga de trabajo transaccional de alto volumen".
4. **`GSI` ≠ `LSI`.** El LSI comparte la partition key de la base y sólo puede crearse junto con la tabla; el GSI tiene su propia clave, su propia capacidad y consistencia eventual.
5. **Aurora Serverless v2 ≠ DynamoDB on-demand.** Serverless v2 escala la *capacidad de instancia* de un cluster aprovisionado; DynamoDB on-demand es un modelo de facturación *por request* sin instancias en absoluto.

### 12.3 Impulsores de costo, en breve

| Servicio | Pagás por |
|---|---|
| RDS / Aurora | Horas de instancia (o de ACU) + GB-mes de almacenamiento + E/S (sólo Aurora Standard) + almacenamiento de backups **por encima** del tamaño de la DB + transferencia de datos |
| DynamoDB | RRU/WRU (on-demand) **o** horas de RCU/WCU (aprovisionado) + GB-mes de almacenamiento + opcionalmente PITR, Streams, replicación de Global Tables |
| ElastiCache | Horas de nodo (o ECPU/GB para Serverless) + almacenamiento de backups |
| Redshift | Horas de nodo (o de RPU) + almacenamiento gestionado + bytes escaneados por Spectrum |
| DMS | Horas de instancia de replicación (o de DCU para Serverless) + almacenamiento; **sin cargo por la ingesta del servicio de destino más allá de sus propias tarifas** |

Dos palancas con efecto desproporcionado: **Reserved Instances / Savings Plans** sobre capacidad estable de RDS y Redshift (hasta ~69 % frente a on-demand), y **Aurora I/O-Optimized** cuando los cargos por E/S superan aproximadamente el 25 % de la factura del cluster.

---

## 13. Referencias

**Exam guide**
- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- AWS Certified Cloud Practitioner certification page — https://aws.amazon.com/certification/certified-cloud-practitioner/

**Shared responsibility**
- AWS Shared Responsibility Model — https://aws.amazon.com/compliance/shared-responsibility-model/

**Amazon RDS**
- Amazon RDS User Guide — https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Welcome.html
- Multi-AZ deployments — https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Concepts.MultiAZ.html
- Multi-AZ DB cluster deployments — https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/multi-az-db-clusters-concepts.html
- Working with read replicas — https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_ReadRepl.html
- RDS storage types — https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_Storage.html
- Backing up and restoring — https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_CommonTasks.BackupRestore.html
- Amazon RDS Proxy — https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy.html
- IAM database authentication — https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.IAMDBAuth.html
- Amazon RDS Custom — https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-custom.html

**Amazon Aurora**
- Aurora User Guide — https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/CHAP_AuroraOverview.html
- Aurora storage and reliability — https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/Aurora.Overview.StorageReliability.html
- Aurora connection management (endpoints) — https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/Aurora.Overview.Endpoints.html
- Aurora Serverless v2 — https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-serverless-v2.html
- Aurora Global Database — https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-global-database.html
- Backtracking an Aurora DB cluster — https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/AuroraMySQL.Managing.Backtrack.html
- Aurora I/O-Optimized — https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-storage-type.html
- Aurora DSQL — https://docs.aws.amazon.com/aurora-dsql/latest/userguide/what-is-aurora-dsql.html

**Amazon DynamoDB**
- DynamoDB Developer Guide — https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Introduction.html
- Read/write capacity mode — https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/HowItWorks.ReadWriteCapacityMode.html
- Partitions and data distribution — https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/HowItWorks.Partitions.html
- Service quotas — https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Limits.html
- Best practices for designing partition keys — https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/bp-partition-key-design.html
- Global tables — https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/GlobalTables.html
- Point-in-time recovery — https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/PointInTimeRecovery.html
- DynamoDB Accelerator (DAX) — https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/DAX.html
- DynamoDB Streams — https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Streams.html

**In-memory**
- Amazon ElastiCache documentation — https://docs.aws.amazon.com/elasticache/
- Valkey and Redis OSS vs Memcached — https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/SelectEngine.html
- Caching strategies — https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/Strategies.html
- Amazon MemoryDB — https://docs.aws.amazon.com/memorydb/latest/devguide/what-is-memorydb.html

**Purpose-built**
- Amazon DocumentDB — https://docs.aws.amazon.com/documentdb/latest/developerguide/what-is.html
- Amazon Neptune — https://docs.aws.amazon.com/neptune/latest/userguide/intro.html
- Amazon Keyspaces (for Apache Cassandra) — https://docs.aws.amazon.com/keyspaces/latest/devguide/what-is-keyspaces.html
- Amazon Timestream — https://docs.aws.amazon.com/timestream/latest/developerguide/what-is-timestream.html
- Amazon Redshift — https://docs.aws.amazon.com/redshift/latest/mgmt/welcome.html
- Redshift Serverless — https://docs.aws.amazon.com/redshift/latest/mgmt/serverless-whatis.html
- Amazon QLDB end of support — https://docs.aws.amazon.com/qldb/latest/developerguide/what-is.html

**Migration**
- AWS Database Migration Service User Guide — https://docs.aws.amazon.com/dms/latest/userguide/Welcome.html
- DMS task settings — https://docs.aws.amazon.com/dms/latest/userguide/CHAP_Tasks.CustomizingTasks.TaskSettings.html
- DMS data validation — https://docs.aws.amazon.com/dms/latest/userguide/CHAP_Validating.html
- AWS Schema Conversion Tool — https://docs.aws.amazon.com/SchemaConversionTool/latest/userguide/CHAP_Welcome.html

**Automation and observability**
- AWS CloudFormation `AWS::RDS::DBCluster` — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-rds-dbcluster.html
- AWS CloudFormation `AWS::DynamoDB::Table` — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-dynamodb-table.html
- AWS Controllers for Kubernetes (ACK) — https://aws-controllers-k8s.github.io/community/docs/community/overview/
- Monitoring Amazon RDS with CloudWatch — https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/monitoring-cloudwatch.html
- Amazon RDS Performance Insights — https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_PerfInsights.html
- Monitoring DynamoDB with CloudWatch — https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/monitoring-cloudwatch.html

**Framework guidance**
- AWS Well-Architected Framework — Reliability Pillar — https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/welcome.html
- AWS Well-Architected Framework — Performance Efficiency Pillar — https://docs.aws.amazon.com/wellarchitected/latest/performance-efficiency-pillar/welcome.html
- Purpose-built databases on AWS — https://aws.amazon.com/products/databases/