# 2.3 — Smart Analytics, Business Intelligence y Streaming Analytics

**Google Cloud Digital Leader — Dominio 2 (Innovar con datos y Google Cloud), Objetivo 2.3**
**Peso en el examen: 6.0** · **Versión del temario: 2026-08-12**
**Perfil de lectura: Principal Platform Architect / Senior SRE**

---

## 1. El problema de producción: por qué "tenemos un data warehouse" no es una arquitectura de analítica

### 1.1 El modo de fallo que genera el requisito

Toda organización que llega a unos cientos de millones de eventos por día converge en el mismo informe de incidente. Dice, más o menos, esto:

> **INC-4471 — Las reglas de fraude dispararon 9 horas después de que terminara la sesión fraudulenta.**
> Causa raíz: el modelo de scoring de fraude consume `dw.sessions_daily`, materializada por un job nocturno de Spark que arranca a las 02:00 UTC y termina a las 05:40 UTC. Las transacciones fraudulentas ocurrieron a las 17:20 UTC del día anterior. El pipeline funcionaba exactamente como fue diseñado. El diseño era el incidente.

Esto es el **colapso de la ventana batch**. No es un bug, es una propiedad arquitectónica: cualquier sistema cuya unidad mínima de frescura es un job nocturno tiene una latencia de decisión *esperada* de la mitad del intervalo batch más la duración del job. Si el valor de negocio de una decisión decae más rápido que ese número, el pipeline es un archivo muy caro.

El segundo modo de fallo es más sutil y peor:

> **INC-5102 — Dos dashboards, dos números de ingresos, una reunión de directorio.**
> Finanzas lee `looker::revenue.gross_bookings` (normalizado por moneda a fecha de liquidación, reembolsos netados, cuentas de prueba excluidas). Growth lee un informe de Looker Studio construido directamente sobre `raw.orders` (sin join de reembolsos, sin filtro de cuentas de prueba, FX a fecha de pedido). Delta: 4,1%. Ambos son "los datos".

Este es el fallo de **deriva semántica**. Es lo que pasa cuando cada consumidor reimplementa la lógica de negocio en su propio SQL. La solución no son más dashboards; es una *capa semántica gobernada* — una definición única, versionada, de lo que significa "ingresos", compilada a SQL en tiempo de consulta.

El tercer modo de fallo es el que mata presupuestos:

> **INC-5533 — $41.200 de gasto on-demand de BigQuery en 36 horas.**
> Un dashboard de Looker Studio programado con refresco cada 15 minutos, respaldado por una tabla sin particionar de 84 TiB, compartido con 60 usuarios. Cada refresco hacía un full scan.

Esto es **amplificación de escaneo descontrolada**. En un warehouse serverless, el modelo de costo pasa de "la capacidad que compramos" a "los bytes que tocamos", y toda tabla sin particionar es un arma cargada apuntando al departamento de finanzas.

### 1.2 El triángulo arquitectónico que en realidad estás negociando

```
                     FRESHNESS
                  (decision latency)
                        /\
                       /  \
                      /    \
                     /      \
                    /        \
                   /          \
                  /            \
           COST  /______________\  CORRECTNESS
        ($/TiB,               (completeness, ordering,
      slot-hours)              exactly-once, late data)
```

No podés maximizar los tres. Cada elección de servicio en este objetivo es un punto específico y documentado dentro de ese triángulo:

| Optimizás para | Aceptás | Patrón canónico de GCP |
|---|---|---|
| Frescura (sub-segundo) | Mayor costo por byte, garantías de completitud más débiles en el borde de la ventana | Pub/Sub → Dataflow streaming → BigQuery Storage Write API |
| Corrección (completo, reconciliable) | Latencia medida en horas | Cloud Storage → Dataproc/Dataflow batch → BigQuery, con sobrescritura idempotente de partición |
| Costo | Latencia y flexibilidad operativa | Suscripción BigQuery de Pub/Sub (sin Dataflow), consultas programadas, tablas particionadas + clusterizadas |
| Frescura *y* corrección | Costo, y la complejidad de un doble camino de código | Arquitectura Lambda: capa de velocidad en streaming + capa de reconciliación batch sobre los mismos eventos |

**Encuadre SRE:** tratá la *frescura de los datos* como un SLI con presupuesto de error, exactamente igual que la latencia de requests. Un SLO útil se ve así:

> El 99% de las ventanas de 5 minutos tienen `oldest_unacked_message_age < 120s` en la suscripción `sub-clickstream-enrich`, medido sobre 28 días móviles.

Esa única línea convierte una discusión arquitectónica sin límites ("¿esto debería ser en tiempo real?") en un presupuesto del que el negocio es dueño.

### 1.3 Qué significa "smart analytics" en el vocabulario de Google

El término de marketing de Google **smart analytics** no es humo — denota una propiedad de producto específica: *servicios de analítica con machine learning e IA integrados en la propia superficie de consulta*, de modo que el paso de ML no requiere exportar datos a una plataforma aparte. Concretamente:

- **BigQuery ML** — entrenar y servir modelos con `CREATE MODEL` / `ML.PREDICT` en SQL, sobre datos que nunca salen del warehouse.
- **Modelos remotos** — `ML.GENERATE_TEXT`, `ML.GENERATE_EMBEDDING` llamando a Vertex AI (incluido Gemini) desde una sentencia SQL.
- **Vector search en BigQuery** — `VECTOR_SEARCH()` sobre columnas de embeddings con `CREATE VECTOR INDEX`, es decir, recuperación semántica sin una base de datos vectorial aparte para escalas moderadas.
- **Forecasting integrado** — `ARIMA_PLUS` / `ARIMA_PLUS_XREG` y `AI.FORECAST` sobre tablas de series temporales.
- **La capa semántica de Looker alimentando a la IA** — las definiciones de métricas gobernadas se convierten en el contexto de grounding para la consulta en lenguaje natural, que es la diferencia entre un LLM adivinando un JOIN y un LLM leyendo una métrica certificada.

El **argumento de valor de negocio** — que es lo que el examen CDL realmente evalúa — es que eliminar el paso de exportar/importar elimina las tres cosas que matan proyectos de ML: el riesgo de gobernanza por copia de datos, el desfase entre entrenamiento y servicio, y el cuello de botella del equipo especialista. Un data analyst con SQL puede entregar un modelo de churn.

---

## 2. Mapa de servicios: el ciclo de vida del dato como arquitectura

Google organiza este dominio en torno a un ciclo de vida de cinco etapas. Memorizá las etapas y el servicio *principal* de cada una — el examen evalúa la ubicación, y la producción evalúa los trade-offs.

```
 ┌──────────┐   ┌──────────┐   ┌───────────┐   ┌──────────┐   ┌────────────┐
 │  INGEST  │──▶│  STORE   │──▶│  PROCESS  │──▶│ ANALYZE  │──▶│  ACTIVATE  │
 └──────────┘   └──────────┘   └───────────┘   └──────────┘   └────────────┘
  Pub/Sub        Cloud Storage   Dataflow        BigQuery       Looker
  Datastream     BigQuery        Dataproc        BigQuery ML    Looker Studio
  Storage        Bigtable        Dataform        Vertex AI      Connected Sheets
   Transfer      Cloud SQL       Data Fusion     Notebooks      Analytics Hub
  Data Transfer  Spanner         Composer                       Reverse ETL
  Managed Kafka  AlloyDB         Dataproc                       Pub/Sub (out)
                                  Serverless
                    ▲                                                │
                    └────────── GOVERNANCE: Dataplex Universal ──────┘
                                Catalog, IAM, VPC-SC, CMEK, DLP
```

### 2.1 Capa de ingesta — comparación técnica

| Servicio | Modelo | Orden | Retención | Garantía de entrega | Mejor para | Antipatrón |
|---|---|---|---|---|---|---|
| **Pub/Sub** | Topic/subscription global serverless, autoescalado, sin particiones que dimensionar | Por `ordering_key`, dentro de una región | Topic: hasta 31 días; subscription: 10 min – 7 días | At-least-once por defecto; **exactly-once** disponible en suscripciones pull regionales | Backbone de eventos desacoplado, fan-out, cross-region | Necesitar semántica de replay por partición idéntica a los consumer groups de Kafka |
| **Managed Service for Apache Kafka** | Clústeres Kafka gestionados (brokers reales, particiones reales) | Por partición | Configurable, limitada por disco | At-least-once; exactly-once vía transacciones de Kafka | Lift-and-shift de apps Kafka existentes, ecosistemas Kafka Connect / Streams | Greenfield donde de otro modo no querrías dimensionar particiones |
| **Datastream** | Change data capture (CDC) serverless desde Oracle, MySQL, PostgreSQL, SQL Server | Por stream de transacciones de origen | Gestionada | At-least-once con reconciliación por upsert en BigQuery | Replicar una base OLTP a BigQuery con lag de segundos a minutos, sin cambiar la aplicación | Transformación pesada en vuelo — es replicación, no ETL |
| **Storage Transfer Service** | Transferencia masiva programada/puntual (S3, Azure Blob, HTTP, on-prem vía agentes) | N/A | N/A | Verificada por checksum | Backfill, migración, sincronización cross-cloud | Cualquier cosa sub-horaria |
| **BigQuery Data Transfer Service** | Cargas programadas gestionadas desde SaaS (Google Ads, Campaign Manager, YouTube, S3, Redshift…) | N/A | N/A | Reintentos gestionados | Datos de marketing/ads SaaS hacia BigQuery sin código | APIs personalizadas |
| **Escrituras directas del cliente** (Storage Write API) | Append por streaming gRPC hacia BigQuery | Por stream | N/A | Exactly-once con offsets de stream | Ingesta de alto throughput propiedad de la aplicación | Cuando además necesitás fan-out a otros consumidores — acoplaste el productor al warehouse |

> **Nota de deprecación:** Pub/Sub Lite está deprecado con una fecha de apagado publicada; no diseñes sistemas nuevos sobre él. Verificá el estado actual en la documentación oficial de Pub/Sub antes de citarlo en una revisión de diseño.

### 2.2 Capa de procesamiento — comparación técnica

| Servicio | Motor | Autoescalado | Modelo de estado | Unidad de costo | Elegilo cuando |
|---|---|---|---|---|---|
| **Dataflow** | Apache Beam (Runner v2), batch + streaming unificados | Horizontal + vertical (Prime); Streaming Engine desacopla el estado de los workers | Estado por clave gestionado, timers, watermarks, exactly-once dentro del pipeline | vCPU-h, GB-h, datos procesados por Streaming Engine, Shuffle | Necesitás corrección en tiempo de evento, ventanas, manejo de datos tardíos, una sola base de código para batch y stream |
| **Dataproc (clúster)** | Hadoop/Spark/Flink/Presto sobre GCE o GKE | Políticas de autoescalado de clúster | Lo que provea el framework | Horas de VM + premium de Dataproc por vCPU | Migrar Spark/Hive/Oozie existentes; necesitar versiones o librerías OSS específicas |
| **Dataproc Serverless for Spark** | Spark, sin clúster que gestionar | Automático | Spark | Horas DCU, almacenamiento de shuffle | Cargas Spark sin operaciones de ciclo de vida de clúster |
| **Dataform** | ELT solo con SQL dentro de BigQuery, con grafo de dependencias, aserciones, versionado | N/A (slots de BigQuery) | N/A | Cómputo de BigQuery | Transformaciones expresables en SQL — que es la mayor parte del modelado de warehouse |
| **Cloud Data Fusion** | CDAP, constructor visual de pipelines, más de 150 conectores | Dataproc efímero por debajo | Gestionado por el framework | Horas de instancia + Dataproc | ETL low-code para equipos sin ingenieros; amplitud de conectores |
| **Cloud Composer** | Apache Airflow gestionado | A nivel de entorno | N/A — orquesta, no procesa | Horas de entorno | Orquestación de DAGs entre servicios, dependencias, SLAs, backfills |
| **BigQuery continuous queries** | SQL de streaming ejecutándose de forma continua sobre BigQuery | Slots de reserva | Gestionado por el warehouse | Slots (ediciones Enterprise) | Transformación/enriquecimiento/enrutamiento simple de streaming expresable en SQL, sin una base de código Beam |

**La decisión que más importa en una revisión:** Dataflow contra "solo SQL". Un pipeline Beam es un artefacto de código con build, deploy, drain, un contrato de compatibilidad de actualización y una rotación de guardia. Si la transformación es `SELECT … FROM … WHERE …`, una consulta programada, una vista materializada o una acción de Dataform es un orden de magnitud más barata de mantener. Reservá Dataflow para lo que SQL genuinamente no puede expresar: **ventanas en tiempo de evento con watermarks, ventanas de sesión, máquinas de estado por clave, reprocesamiento de datos tardíos y side inputs contra dimensiones que cambian lentamente.**

### 2.3 Analizar y activar — comparación de herramientas de BI

| Herramienta | Capa semántica | Gobernanza | Perfil de latencia | Usuario típico | Encuadre de valor de negocio |
|---|---|---|---|---|---|
| **Looker** | **Sí — LookML**, versionado en Git, compilado a SQL en tiempo de consulta; métricas definidas una sola vez | A nivel de fila y de columna vía `access_filter` + políticas de BigQuery; auditoría completa | In-database (sin extracción), o sea tan rápido como el warehouse; PDTs y aggregate awareness para acelerar | Los analytics engineers autoran; todos consumen | "Un número, en todas partes" — elimina la deriva semántica; embebible en productos de cara al cliente; API-first |
| **Looker Studio** | No — fuente de datos por informe | Compartición de informe/fuente de datos; credenciales de propietario o de visor | Depende del conector; capa de caché | Analistas, usuarios de negocio | Gratis, exploración y compartición self-service rápidas |
| **Looker Studio Pro** | No | Agrega Cloud IAM, workspaces de equipo, SLA, soporte | Igual | Self-service empresarial | Self-service gobernado sin la inversión completa de modelado en Looker |
| **Connected Sheets** | No | Aplica IAM de BigQuery | Interactivo contra BigQuery, miles de millones de filas, sin extracción | Finanzas/operaciones en hojas de cálculo | Elimina la exportación a CSV — la mayor fuente individual de copias de datos no gobernadas |
| **BigQuery Studio / notebooks** | No | IAM | Interactivo | Data scientists | Exploración, ML, Python + SQL en una sola superficie |

> **Trampa de examen:** "¿Qué herramienta permite a usuarios de negocio consultar miles de millones de filas *en una interfaz de hoja de cálculo* sin exportar?" → **Connected Sheets**. "¿Qué herramienta provee un *modelo semántico gobernado y reutilizable*?" → **Looker**. "¿Cuál es la herramienta de dashboarding gratuita y liviana?" → **Looker Studio**.

---

## 3. Streaming analytics: la mecánica que tenés que entender para operarlo

### 3.1 Tiempo de evento vs tiempo de procesamiento, y por qué existen los watermarks

Un cliente móvil emite un evento a las `2026-09-06T11:00:03Z` (**tiempo de evento**). El dispositivo está en un túnel. El evento llega a Pub/Sub a las `11:04:47Z` (**tiempo de procesamiento**). La ventana del minuto 11:00–11:01 hace rato que "pasó" en términos de reloj de pared.

Un sistema de streaming correcto debe responder: *¿cuándo es seguro emitir el resultado de la ventana 11:00–11:01?* Ese es el trabajo del **watermark** — la estimación del runner de "creemos haber visto todos los eventos con tiempo de evento ≤ W". Dataflow deriva el watermark del timestamp de publicación más antiguo sin acknowledge de Pub/Sub y lo propaga por el DAG.

Las tres perillas, y sus trade-offs:

| Perilla | Construcción de Beam | Efecto | Trade-off |
|---|---|---|---|
| **Ventana** | `FixedWindows`, `SlidingWindows`, `Sessions`, `GlobalWindows` | Agrupa eventos por tiempo de evento | Ventana más grande = más estado, más memoria, más latencia |
| **Trigger** | `AfterWatermark`, `.withEarlyFirings(AfterProcessingTime)`, `.withLateFirings(AfterCount)` | *Cuándo* emitir un pane | Disparos tempranos = menor latencia, más panes aguas abajo, mayor costo de escritura |
| **Latencia permitida** | `withAllowedLateness(Duration)` | Cuánto tiempo se retiene el estado para aceptar datos tardíos | Más largo = más corrección, riesgo de crecimiento no acotado del estado |
| **Acumulación** | `ACCUMULATING` vs `DISCARDING` | Si los panes posteriores reformulan o entregan el delta de los anteriores | ACCUMULATING requiere un upsert idempotente aguas abajo; DISCARDING requiere sumatoria aguas abajo |

**Regla de producción:** un pipeline `ACCUMULATING` que escribe en una tabla append-only de BigQuery produce métricas contadas por duplicado. O escribís deltas `DISCARDING` y hacés `SUM()` en lectura, o escribís panes `ACCUMULATING` con una clave `pane_index`/`window_start` y deduplicás con `QUALIFY ROW_NUMBER() OVER (PARTITION BY window_start, key ORDER BY pane_index DESC) = 1`. Elegir el modo de acumulación sin decidir el contrato del lado de lectura es el defecto de corrección en streaming más común de todos.

### 3.2 Semántica de entrega — qué significa realmente "exactly-once"

Hay tres garantías distintas y los proveedores las mezclan:

| Garantía | Alcance | Mecanismo en GCP | Riesgo residual |
|---|---|---|---|
| Entrega at-least-once | Pub/Sub → suscriptor | Por defecto | Duplicados; el consumidor debe ser idempotente |
| **Entrega** exactly-once | Pub/Sub → suscriptor, suscripción pull regional | `--enable-exactly-once-delivery` | Acotada a una sola región; el manejo del ack deadline se vuelve más estricto (los ack IDs expiran) |
| **Procesamiento** exactly-once | Dentro de un pipeline de Dataflow | Shuffle determinista + estado con checkpoints | No se extiende a efectos secundarios externos no idempotentes |
| **Escritura** exactly-once | Dataflow/app → BigQuery | Storage Write API con committed streams y offsets | Requiere que el escritor gestione los offsets; las escrituras al default stream son at-least-once |

**El exactly-once extremo a extremo es una cadena, y es tan fuerte como su eslabón más débil.** Si tu pipeline llama a una API REST externa en un `DoFn`, los reintentos la van a llamar dos veces. Diseñá el sink para que sea idempotente (clave natural + `MERGE`, o `insertId`/offset determinista) en vez de intentar que la red sea confiable.

### 3.3 Tipos de suscripción de Pub/Sub — elegí antes de construir

| Tipo | Consumidor | Transformación | Costo | Cuándo |
|---|---|---|---|---|
| **Pull** (incl. StreamingPull) | Tu código / Dataflow | Arbitraria | Cómputo del suscriptor + entrega de Pub/Sub | Control total, lógica compleja |
| **Push** | Endpoint HTTPS (Cloud Run, Cloud Functions, GKE Ingress) | Arbitraria | Cómputo del endpoint | Event-driven serverless, bajo volumen |
| **Suscripción BigQuery** | Escritura directa en una tabla de BigQuery | **Ninguna** (opcionalmente con mapeo de esquema, o escribiendo a un esquema rico en metadatos) | Sin Dataflow en absoluto — drásticamente más barato | Zona de aterrizaje cruda, estilo ELT; transformar después en SQL |
| **Suscripción Cloud Storage** | Escritura directa de archivos por lotes a GCS | Ninguna | Sin Dataflow | Archivado barato / fuente de replay / aterrizaje en el data lake |

> **La decisión de costo de mayor apalancamiento en este objetivo:** si tu pipeline de streaming no hace *ninguna* lógica por evento más allá del parseo, reemplazá Dataflow por una **suscripción BigQuery** más SQL programado o una vista materializada. Eso saca un sistema distribuido always-on entero de tu superficie de guardia. Mantené una **suscripción Cloud Storage** sobre el mismo topic como fuente de replay inmutable — ese es tu botón de deshacer cuando el SQL esté mal.

---

## 4. BigQuery: los internos que gobiernan tu costo y tu latencia

### 4.1 Arquitectura

BigQuery separa almacenamiento de cómputo a través de cuatro componentes de infraestructura de Google:

- **Colossus** — el sistema de archivos distribuido que guarda los datos de tabla en **Capacitor**, un formato columnar con codificación por columna y estadísticas usadas para predicate pushdown.
- **Dremel** — el motor de ejecución en árbol de servicio multinivel. Una consulta se convierte en un árbol de mixers y nodos hoja; las hojas leen de Colossus, los mixers agregan.
- **Jupiter** — la red de datacenter a escala de petabit que hace viable la separación de almacenamiento y cómputo; un shuffle puede mover terabytes entre etapas.
- **Borg** — el gestor de clúster que asigna **slots** (unidades de CPU/RAM/IO) a las etapas de la consulta.

La consecuencia operativa: **no hay índice que ajustar ni VM que dimensionar.** Tus palancas son (a) cuántos datos debe leer una consulta (particionado, clustering, vistas materializadas), y (b) cuántos slots hay disponibles (ediciones y reservas).

### 4.2 Modelos de precio — la tabla de trade-offs

| Modelo | Unidad de facturación | Previsibilidad | Comportamiento de concurrencia bajo carga | Elegilo cuando |
|---|---|---|---|---|
| **On-demand** | Bytes *procesados* por consulta (por TiB) | Mala — una sola consulta mala puede costar miles | Reparto equitativo de un pool compartido grande; sin tope duro sin cuotas personalizadas | Picos, bajo volumen, exploratorio; para empezar |
| **Editions — Standard** | Horas de slot, autoescalado | Buena | Acotado por el tamaño máximo de la reserva | Dev/test, cargas básicas |
| **Editions — Enterprise** | Horas de slot, autoescalado, compromisos opcionales a 1 o 3 años | Buena | Acotado; aislamiento de cargas vía reservas + asignaciones | La mayoría de los parques productivos |
| **Editions — Enterprise Plus** | Horas de slot (tarifa más alta) | Buena | Igual que arriba, más funciones avanzadas de seguridad/cumplimiento y DR cross-region | Cargas reguladas, requisitos de DR multirregión |

El almacenamiento se factura por separado (activo vs long-term, lógico vs **físico/comprimido** — la facturación comprimida suele ser un ahorro grande en datos columnares que comprimen bien, pero se elige por dataset y tiene un período de espera para cambiar).

> **Todos los precios de lista varían por región y cambian. Nunca cites un número en un documento de diseño sin enlazar la página de precios e indicar la fecha. Verificá con `gcloud billing` / la Calculadora de precios.**

**El único control que previene el INC-5533:** poné cada carga productiva en una **reserva** con un `max_slots` duro, y habilitá `maximum_bytes_billed` en toda consulta programada o de BI. El sobrecosto pasa a ser una *consulta fallida* — una página — en vez de una factura.

### 4.3 Caminos de ingesta hacia BigQuery — comparación

| Camino | Latencia hasta ser consultable | Exactly-once | Forma del costo | Notas |
|---|---|---|---|---|
| `bq load` / job de carga batch | Minutos | Sí (job atómico) | **Gratis** (slots de carga del pool compartido) o slots de reserva | Mejor costo por byte; usalo para backfills |
| **Storage Write API** — default stream | Segundos | At-least-once | Por GiB ingerido | Alto throughput, baja latencia, lo más simple |
| **Storage Write API** — committed stream + offsets | Segundos | **Sí** | Por GiB ingerido | La elección correcta para streams de grado financiero |
| **Storage Write API** — pending stream | Al hacer commit | Sí, atómico | Por GiB ingerido | Atomicidad tipo batch con API de streaming |
| `tabledata.insertAll` legacy (streaming inserts) | Segundos | Deduplicación best-effort vía `insertId` | Más caro por byte que Storage Write API | Legacy — migrar a Storage Write API |
| **Suscripción BigQuery de Pub/Sub** | Segundos | At-least-once | Solo entrega de Pub/Sub; sin cómputo | El camino de streaming más barato; sin transformación |
| **Datastream a BigQuery** | Segundos–minutos | Reconciliado por upsert | GB procesados por Datastream + BQ | Replicación CDC |
| **Tablas externas / BigLake** | N/A — consulta in situ | N/A | Bytes escaneados en GCS | Evita una copia; más lento que nativo, sin poda de particiones salvo que esté hive-particionado |

---

## 5. Arquitectura de referencia — completa, desplegable

**Escenario.** Un retailer, `acme`, necesita tres cosas de un mismo clickstream:
1. **Streaming:** detección en menos de 60 segundos de señales de abandono de carrito y anomalías de pago, empujadas a un topic de activación.
2. **Warehouse:** una tabla de eventos append-only, particionada y clusterizada para analistas, más marts gobernados.
3. **BI:** una capa semántica de Looker para que Finanzas y Growth no puedan volver a discrepar sobre una métrica.

```
                                  ┌──────────────────────────┐
  Web/App/POS ──▶ GKE gateway ──▶ │ Pub/Sub topic            │
   (Avro, schema-validated)       │ ingest-clickstream        │
                                  └───┬────────┬─────────┬────┘
                                      │        │         │
             ┌────────────────────────┘        │         └─────────────────┐
             ▼                                 ▼                           ▼
   ┌───────────────────┐          ┌─────────────────────┐      ┌────────────────────┐
   │ Dataflow          │          │ BigQuery            │      │ Cloud Storage      │
   │ streaming (Beam)  │          │ subscription        │      │ subscription       │
   │ sessionise+score  │          │ → raw.events_landing│      │ → gs://…/replay/   │
   └───┬───────────┬───┘          └─────────────────────┘      └────────────────────┘
       │           │                        │                             │
       ▼           ▼                        ▼                             │
 ┌──────────┐  ┌────────────────┐   ┌───────────────┐                     │
 │ Pub/Sub  │  │ BigQuery       │   │ Dataform ELT  │◀────────────────────┘
 │ activate │  │ analytics.*    │   │ marts.*       │   (backfill / replay)
 └────┬─────┘  │ (Storage Write │   └───────┬───────┘
      │        │  API, EO)      │           │
      ▼        └────────────────┘           ▼
  Cloud Run                          ┌─────────────┐    ┌───────────────┐
  activation svc                     │ BigQuery ML │───▶│    Looker     │
  (email/push)                       │ churn/ARIMA │    │ LookML models │
                                     └─────────────┘    └───────────────┘
        ▲                                                       │
        └────────────── Dead-letter topic + BQ DLQ table ───────┘
```

### 5.1 Esquema Avro de Pub/Sub (`schemas/clickstream-v1.avsc`)

```json
{
  "type": "record",
  "name": "ClickstreamEvent",
  "namespace": "club.acme.analytics",
  "doc": "Canonical clickstream envelope. Additive changes only; new fields MUST have defaults.",
  "fields": [
    { "name": "event_id",     "type": "string", "doc": "UUIDv4, client-generated, dedup key" },
    { "name": "event_time",   "type": { "type": "long", "logicalType": "timestamp-micros" } },
    { "name": "event_type",   "type": { "type": "enum", "name": "EventType",
        "symbols": ["PAGE_VIEW","ADD_TO_CART","REMOVE_FROM_CART","CHECKOUT_START",
                    "PAYMENT_ATTEMPT","PAYMENT_RESULT","SEARCH","HEARTBEAT"] } },
    { "name": "session_id",   "type": "string" },
    { "name": "user_pseudo_id", "type": "string", "doc": "Pseudonymous; never the raw account id" },
    { "name": "store_id",     "type": "string" },
    { "name": "country",      "type": "string", "default": "XX" },
    { "name": "device",       "type": { "type": "record", "name": "Device", "fields": [
        { "name": "platform", "type": "string" },
        { "name": "os_version", "type": ["null","string"], "default": null },
        { "name": "app_version", "type": ["null","string"], "default": null } ] } },
    { "name": "cart_value_micros", "type": ["null","long"], "default": null,
      "doc": "Minor-unit * 1e6 to avoid float; null for non-cart events" },
    { "name": "currency",     "type": ["null","string"], "default": null },
    { "name": "payment_result", "type": ["null", { "type": "enum", "name": "PaymentResult",
        "symbols": ["APPROVED","DECLINED","ERROR","TIMEOUT"] }], "default": null },
    { "name": "attributes",   "type": { "type": "map", "values": "string" }, "default": {} },
    { "name": "schema_version", "type": "int", "default": 1 }
  ]
}
```

**Contrato de evolución del esquema:** las revisiones de esquema de Pub/Sub solo aceptan cambios compatibles hacia atrás/hacia adelante. En la práctica esto significa: *agregar* campos opcionales con valores por defecto; nunca eliminar un campo, nunca cambiar un tipo, nunca reordenar los símbolos de un enum. Eliminar un campo rompe a todo consumidor que no haya sido redesplegado — y en un sistema de streaming, el redespliegue no es atómico.

### 5.2 Terraform — el módulo completo de la plataforma de datos

```hcl
# ---------------------------------------------------------------------------
# main.tf — acme smart-analytics platform
# terraform >= 1.7, google provider >= 5.x
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.7.0"
  required_providers {
    google = { source = "hashicorp/google", version = "~> 5.40" }
  }
  backend "gcs" {
    bucket = "acme-tfstate-prod"
    prefix = "analytics/platform"
  }
}

variable "project_id" { type = string,  default = "acme-analytics-prod" }
variable "region"     { type = string,  default = "us-central1" }
variable "env"        { type = string,  default = "prod" }

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  labels = {
    env        = var.env
    domain     = "analytics"
    cost_center = "cc-4410"
    managed_by = "terraform"
  }
}

# ---------------------------------------------------------------------------
# 0. APIs
# ---------------------------------------------------------------------------
resource "google_project_service" "apis" {
  for_each = toset([
    "pubsub.googleapis.com",
    "dataflow.googleapis.com",
    "bigquery.googleapis.com",
    "bigquerydatatransfer.googleapis.com",
    "bigqueryconnection.googleapis.com",
    "datacatalog.googleapis.com",
    "dataplex.googleapis.com",
    "dataform.googleapis.com",
    "storage.googleapis.com",
    "monitoring.googleapis.com",
    "aiplatform.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

# ---------------------------------------------------------------------------
# 1. Service accounts and least-privilege IAM
# ---------------------------------------------------------------------------
resource "google_service_account" "producer" {
  account_id   = "sa-clickstream-producer"
  display_name = "Clickstream producer (GKE, Workload Identity)"
}

resource "google_service_account" "dataflow" {
  account_id   = "sa-dataflow-clickstream"
  display_name = "Dataflow worker SA for clickstream-enrich"
}

resource "google_service_account" "pubsub_bq" {
  account_id   = "sa-pubsub-bq-writer"
  display_name = "Pub/Sub BigQuery subscription writer"
}

resource "google_pubsub_topic_iam_member" "producer_publish" {
  topic  = google_pubsub_topic.clickstream.name
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_service_account.producer.email}"
}

# Dataflow worker needs: worker role, subscribe, publish to activation+DLQ,
# BigQuery data edit on the analytics dataset only, and GCS temp.
resource "google_project_iam_member" "df_worker" {
  project = var.project_id
  role    = "roles/dataflow.worker"
  member  = "serviceAccount:${google_service_account.dataflow.email}"
}

resource "google_pubsub_subscription_iam_member" "df_subscribe" {
  subscription = google_pubsub_subscription.enrich.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${google_service_account.dataflow.email}"
}

resource "google_pubsub_topic_iam_member" "df_publish_activation" {
  for_each = toset([
    google_pubsub_topic.activation.name,
    google_pubsub_topic.dlq.name,
  ])
  topic  = each.value
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_service_account.dataflow.email}"
}

resource "google_bigquery_dataset_iam_member" "df_bq_editor" {
  dataset_id = google_bigquery_dataset.analytics.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.dataflow.email}"
}

resource "google_project_iam_member" "df_bq_jobuser" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.dataflow.email}"
}

# ---------------------------------------------------------------------------
# 2. Pub/Sub: schema, topics, subscriptions, DLQ
# ---------------------------------------------------------------------------
resource "google_pubsub_schema" "clickstream" {
  name       = "clickstream-v1"
  type       = "AVRO"
  definition = file("${path.module}/schemas/clickstream-v1.avsc")
}

resource "google_pubsub_topic" "clickstream" {
  name                       = "ingest-clickstream"
  message_retention_duration = "604800s" # 7 days — replay window
  labels                     = local.labels

  schema_settings {
    schema   = google_pubsub_schema.clickstream.id
    encoding = "BINARY"
  }

  message_storage_policy {
    allowed_persistence_regions = ["us-central1", "us-east1"] # data residency
  }

  depends_on = [google_project_service.apis]
}

resource "google_pubsub_topic" "activation" {
  name                       = "activation-signals"
  message_retention_duration = "86400s"
  labels                     = local.labels
}

resource "google_pubsub_topic" "dlq" {
  name                       = "clickstream-dlq"
  message_retention_duration = "604800s"
  labels                     = local.labels
}

# --- 2a. Dataflow subscription: exactly-once, ordered per session -----------
resource "google_pubsub_subscription" "enrich" {
  name  = "sub-clickstream-enrich"
  topic = google_pubsub_topic.clickstream.id

  ack_deadline_seconds         = 60
  message_retention_duration   = "604800s"
  retain_acked_messages        = false
  enable_exactly_once_delivery = true
  enable_message_ordering      = true

  expiration_policy { ttl = "" } # never expire

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dlq.id
    max_delivery_attempts = 5
  }

  labels = local.labels
}

# --- 2b. BigQuery subscription: raw landing zone, zero compute --------------
resource "google_pubsub_subscription" "bq_landing" {
  name  = "sub-clickstream-bq-landing"
  topic = google_pubsub_topic.clickstream.id

  bigquery_config {
    table                 = "${var.project_id}.raw.events_landing"
    use_topic_schema      = true
    write_metadata        = false
    drop_unknown_fields   = true
    service_account_email = google_service_account.pubsub_bq.email
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dlq.id
    max_delivery_attempts = 5
  }

  labels = local.labels
}

# --- 2c. Cloud Storage subscription: immutable replay source ---------------
resource "google_pubsub_subscription" "gcs_archive" {
  name  = "sub-clickstream-gcs-archive"
  topic = google_pubsub_topic.clickstream.id

  cloud_storage_config {
    bucket          = google_storage_bucket.replay.name
    filename_prefix = "clickstream/"
    filename_suffix = ".avro"
    max_duration    = "300s"
    max_bytes       = 268435456 # 256 MiB

    avro_config { write_metadata = true }
  }

  labels = local.labels
}

resource "google_storage_bucket" "replay" {
  name                        = "${var.project_id}-clickstream-replay"
  location                    = "US"
  uniform_bucket_level_access = true
  storage_class               = "STANDARD"

  versioning { enabled = false }

  lifecycle_rule {
    condition { age = 30 }
    action { type = "SetStorageClass", storage_class = "NEARLINE" }
  }
  lifecycle_rule {
    condition { age = 365 }
    action { type = "SetStorageClass", storage_class = "ARCHIVE" }
  }
  labels = local.labels
}

resource "google_storage_bucket" "dataflow_temp" {
  name                        = "${var.project_id}-dataflow-temp"
  location                    = var.region
  uniform_bucket_level_access = true
  lifecycle_rule {
    condition { age = 7 }
    action { type = "Delete" }
  }
  labels = local.labels
}

# ---------------------------------------------------------------------------
# 3. BigQuery: datasets and tables
# ---------------------------------------------------------------------------
resource "google_bigquery_dataset" "raw" {
  dataset_id                      = "raw"
  location                        = "US"
  description                     = "Landing zone. Append-only. No business logic. 30-day TTL."
  default_partition_expiration_ms = 2592000000 # 30 days
  labels                          = local.labels
}

resource "google_bigquery_dataset" "analytics" {
  dataset_id  = "analytics"
  location    = "US"
  description = "Curated, conformed event and session tables."
  labels      = local.labels
}

resource "google_bigquery_dataset" "marts" {
  dataset_id  = "marts"
  location    = "US"
  description = "Business-facing marts consumed by Looker. Contract-stable."
  labels      = local.labels
}

resource "google_bigquery_table" "events_landing" {
  dataset_id          = google_bigquery_dataset.raw.dataset_id
  table_id            = "events_landing"
  deletion_protection = true

  time_partitioning {
    type  = "DAY"
    field = "event_time"
  }
  clustering = ["event_type", "store_id"]

  schema = jsonencode([
    { name = "event_id",         type = "STRING",    mode = "REQUIRED" },
    { name = "event_time",       type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "event_type",       type = "STRING",    mode = "REQUIRED" },
    { name = "session_id",       type = "STRING",    mode = "REQUIRED" },
    { name = "user_pseudo_id",   type = "STRING",    mode = "REQUIRED" },
    { name = "store_id",         type = "STRING",    mode = "REQUIRED" },
    { name = "country",          type = "STRING",    mode = "NULLABLE" },
    { name = "device",           type = "RECORD",    mode = "NULLABLE", fields = [
        { name = "platform",    type = "STRING", mode = "NULLABLE" },
        { name = "os_version",  type = "STRING", mode = "NULLABLE" },
        { name = "app_version", type = "STRING", mode = "NULLABLE" }
      ] },
    { name = "cart_value_micros", type = "INT64",   mode = "NULLABLE" },
    { name = "currency",          type = "STRING",  mode = "NULLABLE" },
    { name = "payment_result",    type = "STRING",  mode = "NULLABLE" },
    { name = "attributes",        type = "JSON",    mode = "NULLABLE" },
    { name = "schema_version",    type = "INT64",   mode = "NULLABLE" }
  ])
  labels = local.labels
}

resource "google_bigquery_table" "session_metrics" {
  dataset_id          = google_bigquery_dataset.analytics.dataset_id
  table_id            = "session_metrics"
  deletion_protection = true

  time_partitioning {
    type                     = "DAY"
    field                    = "window_start"
    require_partition_filter = true # <-- the guard against full scans
  }
  clustering = ["store_id", "country"]

  schema = jsonencode([
    { name = "window_start",       type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "window_end",         type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "session_id",         type = "STRING",    mode = "REQUIRED" },
    { name = "user_pseudo_id",     type = "STRING",    mode = "REQUIRED" },
    { name = "store_id",           type = "STRING",    mode = "REQUIRED" },
    { name = "country",            type = "STRING",    mode = "NULLABLE" },
    { name = "event_count",        type = "INT64",     mode = "REQUIRED" },
    { name = "cart_value_micros",  type = "INT64",     mode = "NULLABLE" },
    { name = "abandoned_cart",     type = "BOOL",      mode = "REQUIRED" },
    { name = "payment_failures",   type = "INT64",     mode = "REQUIRED" },
    { name = "anomaly_score",      type = "FLOAT64",   mode = "NULLABLE" },
    { name = "pane_index",         type = "INT64",     mode = "REQUIRED",
      description = "Beam pane index; dedup with QUALIFY ROW_NUMBER() ... ORDER BY pane_index DESC" },
    { name = "pipeline_version",   type = "STRING",    mode = "REQUIRED" },
    { name = "ingested_at",        type = "TIMESTAMP", mode = "REQUIRED" }
  ])
  labels = local.labels
}

resource "google_bigquery_table" "dlq_events" {
  dataset_id = google_bigquery_dataset.raw.dataset_id
  table_id   = "dlq_events"
  time_partitioning { type = "DAY", field = "received_at" }
  schema = jsonencode([
    { name = "received_at",      type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "subscription",     type = "STRING",    mode = "NULLABLE" },
    { name = "delivery_attempt", type = "INT64",     mode = "NULLABLE" },
    { name = "error_class",      type = "STRING",    mode = "NULLABLE" },
    { name = "error_message",    type = "STRING",    mode = "NULLABLE" },
    { name = "raw_payload",      type = "BYTES",     mode = "NULLABLE" },
    { name = "attributes",       type = "JSON",      mode = "NULLABLE" }
  ])
  labels = local.labels
}

# ---------------------------------------------------------------------------
# 4. Governance: column-level policy tag + row-level access
# ---------------------------------------------------------------------------
resource "google_data_catalog_taxonomy" "pii" {
  region                 = var.region
  display_name           = "acme-pii-taxonomy"
  description            = "Sensitivity classification for analytics columns"
  activated_policy_types = ["FINE_GRAINED_ACCESS_CONTROL"]
}

resource "google_data_catalog_policy_tag" "pseudonymous_id" {
  taxonomy     = google_data_catalog_taxonomy.pii.id
  display_name = "pseudonymous-identifier"
  description  = "Re-identifiable only when joined with the identity service"
}

# ---------------------------------------------------------------------------
# 5. BigQuery reservation — the cost guardrail
# ---------------------------------------------------------------------------
resource "google_bigquery_reservation" "prod" {
  name              = "res-analytics-prod"
  location          = "US"
  edition           = "ENTERPRISE"
  slot_capacity     = 500
  autoscale { max_slots = 1500 }
  ignore_idle_slots = false
}

resource "google_bigquery_reservation_assignment" "prod_queries" {
  assignee    = "projects/${var.project_id}"
  job_type    = "QUERY"
  reservation = google_bigquery_reservation.prod.id
}

# ---------------------------------------------------------------------------
# 6. Dataflow streaming job (Flex Template)
# ---------------------------------------------------------------------------
resource "google_dataflow_flex_template_job" "clickstream_enrich" {
  provider                = google-beta
  name                    = "clickstream-enrich-v7"
  container_spec_gcs_path = "gs://${var.project_id}-dataflow-templates/clickstream-enrich/v7.json"
  region                  = var.region

  on_delete                    = "drain"   # never "cancel" a stateful streaming job
  service_account_email        = google_service_account.dataflow.email
  temp_location                = "gs://${google_storage_bucket.dataflow_temp.name}/temp"
  staging_location             = "gs://${google_storage_bucket.dataflow_temp.name}/staging"
  enable_streaming_engine      = true
  machine_type                 = "n2-standard-4"
  max_workers                  = 40
  num_workers                  = 4
  ip_configuration             = "WORKER_IP_PRIVATE"
  network                      = "vpc-analytics"
  subnetwork                   = "regions/${var.region}/subnetworks/snet-dataflow-${var.region}"

  parameters = {
    inputSubscription   = google_pubsub_subscription.enrich.id
    activationTopic     = google_pubsub_topic.activation.id
    dlqTopic            = google_pubsub_topic.dlq.id
    outputTable         = "${var.project_id}:analytics.session_metrics"
    sessionGapSeconds   = "1800"
    allowedLatenessSec  = "3600"
    earlyFiringSec      = "30"
    pipelineVersion     = "v7"
    autoscalingAlgorithm = "THROUGHPUT_BASED"
  }

  labels = local.labels
}

# ---------------------------------------------------------------------------
# 7. Observability — SLO-driven alert policies
# ---------------------------------------------------------------------------
resource "google_monitoring_notification_channel" "oncall" {
  display_name = "data-platform-oncall"
  type         = "pagerduty"
  sensitive_labels { service_key = var.pagerduty_key }
}

resource "google_monitoring_alert_policy" "backlog_age" {
  display_name = "[P1] Clickstream subscription backlog age > 300s"
  combiner     = "OR"
  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      **Symptom:** `oldest_unacked_message_age` on `sub-clickstream-enrich` exceeded 300s.
      **Impact:** Cart-abandonment activation is late; the 60s freshness SLO is burning budget.
      **First checks:**
      1. `gcloud dataflow jobs list --region=us-central1 --status=active` — is the job Running?
      2. Dataflow → Job graph → look for a stage with rising `system_lag`.
      3. Check `job/current_num_vcpus` vs `max_workers` — are we pinned at the cap?
      4. Check DLQ publish rate — a poison message loops until `max_delivery_attempts`.
      **Runbook:** go/runbook-clickstream-backlog
    EOT
  }
  conditions {
    display_name = "oldest_unacked_message_age > 300s for 5m"
    condition_threshold {
      filter = join(" AND ", [
        "metric.type=\"pubsub.googleapis.com/subscription/oldest_unacked_message_age\"",
        "resource.type=\"pubsub_subscription\"",
        "resource.label.\"subscription_id\"=\"sub-clickstream-enrich\"",
      ])
      comparison      = "COMPARISON_GT"
      threshold_value = 300
      duration        = "300s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MAX"
      }
    }
  }
  notification_channels = [google_monitoring_notification_channel.oncall.id]
  severity              = "CRITICAL"
}

resource "google_monitoring_alert_policy" "watermark_stalled" {
  display_name = "[P1] Dataflow data watermark age > 900s"
  combiner     = "OR"
  conditions {
    display_name = "data_watermark_age > 900s"
    condition_threshold {
      filter = join(" AND ", [
        "metric.type=\"dataflow.googleapis.com/job/per_stage_data_watermark_age\"",
        "resource.type=\"dataflow_job\"",
        "metadata.user_labels.\"domain\"=\"analytics\"",
      ])
      comparison      = "COMPARISON_GT"
      threshold_value = 900
      duration        = "600s"
      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_MAX"
        cross_series_reducer = "REDUCE_MAX"
        group_by_fields      = ["resource.label.job_name"]
      }
    }
  }
  notification_channels = [google_monitoring_notification_channel.oncall.id]
  severity              = "CRITICAL"
}

resource "google_monitoring_alert_policy" "dlq_rate" {
  display_name = "[P2] Dead-letter publish rate > 1 msg/s"
  combiner     = "OR"
  conditions {
    display_name = "dlq topic publish rate"
    condition_threshold {
      filter = join(" AND ", [
        "metric.type=\"pubsub.googleapis.com/topic/send_message_operation_count\"",
        "resource.type=\"pubsub_topic\"",
        "resource.label.\"topic_id\"=\"clickstream-dlq\"",
      ])
      comparison      = "COMPARISON_GT"
      threshold_value = 1
      duration        = "300s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_RATE"
      }
    }
  }
  notification_channels = [google_monitoring_notification_channel.oncall.id]
  severity              = "WARNING"
}

resource "google_monitoring_alert_policy" "bq_scan_spike" {
  display_name = "[P2] BigQuery slot utilisation sustained at reservation cap"
  combiner     = "OR"
  conditions {
    display_name = "slots_allocated at max for 15m"
    condition_threshold {
      filter = join(" AND ", [
        "metric.type=\"bigquery.googleapis.com/slots/allocated_for_reservation\"",
        "resource.type=\"bigquery_project\"",
      ])
      comparison      = "COMPARISON_GT"
      threshold_value = 1450
      duration        = "900s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }
  notification_channels = [google_monitoring_notification_channel.oncall.id]
  severity              = "WARNING"
}
```

### 5.3 Metadatos del Flex Template de Dataflow (`templates/clickstream-enrich.metadata.json`)

```json
{
  "name": "clickstream-enrich",
  "description": "Sessionises clickstream events, scores cart abandonment and payment anomalies, writes session metrics to BigQuery and activation signals to Pub/Sub.",
  "parameters": [
    { "name": "inputSubscription", "label": "Input Pub/Sub subscription",
      "helpText": "projects/<p>/subscriptions/<s>",
      "regexes": ["^projects/[^/]+/subscriptions/[^/]+$"] },
    { "name": "outputTable", "label": "BigQuery output table",
      "helpText": "PROJECT:DATASET.TABLE",
      "regexes": ["^[^:]+:[^.]+[.].+$"] },
    { "name": "activationTopic", "label": "Activation topic",
      "regexes": ["^projects/[^/]+/topics/[^/]+$"] },
    { "name": "dlqTopic", "label": "Dead-letter topic",
      "regexes": ["^projects/[^/]+/topics/[^/]+$"] },
    { "name": "sessionGapSeconds", "label": "Session gap (s)",
      "isOptional": true, "regexes": ["^[0-9]+$"] },
    { "name": "allowedLatenessSec", "label": "Allowed lateness (s)",
      "isOptional": true, "regexes": ["^[0-9]+$"] },
    { "name": "earlyFiringSec", "label": "Early firing interval (s)",
      "isOptional": true, "regexes": ["^[0-9]+$"] },
    { "name": "pipelineVersion", "label": "Pipeline version tag",
      "isOptional": true }
  ]
}
```

### 5.4 El pipeline Beam (`pipeline/clickstream_enrich.py`)

```python
"""Streaming sessionisation and anomaly scoring for the acme clickstream.

Correctness contract
--------------------
* Windowing:      session windows, gap = --session_gap_seconds (default 1800s)
* Trigger:        AfterWatermark, early firings every --early_firing_sec,
                  late firings on every element
* Accumulation:   ACCUMULATING  -> downstream MUST deduplicate on
                  (window_start, session_id) ORDER BY pane_index DESC
* Lateness:       --allowed_lateness_sec (default 3600s); anything later is
                  routed to the DLQ, never silently dropped
* Sink:           BigQuery Storage Write API (exactly-once within the pipeline)
"""

import json
import logging
from typing import Any, Dict, Iterable, Tuple

import apache_beam as beam
from apache_beam.io.gcp.pubsub import ReadFromPubSub, WriteToPubSub
from apache_beam.options.pipeline_options import (
    GoogleCloudOptions, PipelineOptions, SetupOptions, StandardOptions,
)
from apache_beam.transforms import trigger, window
from apache_beam.utils.timestamp import Duration

DEAD_LETTER = "dead_letter"
MAIN = "main"


class Options(PipelineOptions):
    @classmethod
    def _add_argparse_args(cls, parser):
        parser.add_argument("--input_subscription", required=True)
        parser.add_argument("--output_table", required=True)
        parser.add_argument("--activation_topic", required=True)
        parser.add_argument("--dlq_topic", required=True)
        parser.add_argument("--session_gap_seconds", type=int, default=1800)
        parser.add_argument("--allowed_lateness_sec", type=int, default=3600)
        parser.add_argument("--early_firing_sec", type=int, default=30)
        parser.add_argument("--pipeline_version", default="dev")


class ParseEvent(beam.DoFn):
    """Decode the Avro-encoded envelope. Malformed payloads go to the DLQ.

    A parse failure MUST NOT crash the bundle: an unparseable message would be
    retried until max_delivery_attempts, blocking the ordering key and stalling
    the watermark for every session sharing that key.
    """

    def process(self, element: Tuple[bytes, Dict[str, str]]):
        payload, attributes = element
        try:
            # In the deployed template this is an Avro decode against the
            # schema fetched from the Pub/Sub schema registry at startup.
            record = json.loads(payload.decode("utf-8"))
            if "session_id" not in record or "event_time" not in record:
                raise ValueError("missing required field session_id/event_time")
            yield beam.pvalue.TaggedOutput(MAIN, record)
        except Exception as exc:  # noqa: BLE001 — deliberate catch-all
            logging.warning("parse_failure: %s", exc)
            yield beam.pvalue.TaggedOutput(
                DEAD_LETTER,
                {
                    "error_class": type(exc).__name__,
                    "error_message": str(exc)[:2000],
                    "attributes": attributes,
                    "raw_payload_b64": payload.hex(),
                },
            )


class ScoreSession(beam.DoFn):
    """Reduce a session's events into a metrics row plus optional signals."""

    def __init__(self, pipeline_version: str):
        self._version = pipeline_version

    def process(
        self,
        keyed: Tuple[str, Iterable[Dict[str, Any]]],
        win=beam.DoFn.WindowParam,
        pane=beam.DoFn.PaneInfoParam,
        ts=beam.DoFn.TimestampParam,
    ):
        session_id, events = keyed
        events = sorted(events, key=lambda e: e["event_time"])

        added = sum(1 for e in events if e["event_type"] == "ADD_TO_CART")
        removed = sum(1 for e in events if e["event_type"] == "REMOVE_FROM_CART")
        checked_out = any(e["event_type"] == "CHECKOUT_START" for e in events)
        approved = any(e.get("payment_result") == "APPROVED" for e in events)
        failures = sum(
            1 for e in events
            if e.get("payment_result") in ("DECLINED", "ERROR", "TIMEOUT")
        )
        cart_value = max(
            (e.get("cart_value_micros") or 0 for e in events), default=0
        )

        abandoned = bool(added > removed and not approved)

        # Deliberately simple, auditable heuristic. The model-based score is
        # computed in BigQuery ML on the same rows — see marts/anomaly.sqlx.
        anomaly = 0.0
        if failures >= 3:
            anomaly += 0.6
        if failures >= 1 and cart_value > 500_000_000:  # > 500 units
            anomaly += 0.3
        if len({e.get("country") for e in events if e.get("country")}) > 1:
            anomaly += 0.4
        anomaly = min(anomaly, 1.0)

        row = {
            "window_start": win.start.to_rfc3339(),
            "window_end": win.end.to_rfc3339(),
            "session_id": session_id,
            "user_pseudo_id": events[0]["user_pseudo_id"],
            "store_id": events[0]["store_id"],
            "country": events[0].get("country"),
            "event_count": len(events),
            "cart_value_micros": cart_value or None,
            "abandoned_cart": abandoned,
            "payment_failures": failures,
            "anomaly_score": anomaly,
            "pane_index": pane.index,
            "pipeline_version": self._version,
            "ingested_at": ts.to_rfc3339(),
        }
        yield beam.pvalue.TaggedOutput(MAIN, row)

        # Emit activation signals only on the ON_TIME or LATE pane, never on an
        # early speculative pane: an early firing would page a customer whose
        # checkout simply had not arrived yet.
        if pane.timing != window.PaneInfoTiming.EARLY:
            if abandoned and cart_value > 0:
                yield beam.pvalue.TaggedOutput(
                    "activation",
                    json.dumps({
                        "signal": "CART_ABANDONED",
                        "session_id": session_id,
                        "user_pseudo_id": row["user_pseudo_id"],
                        "cart_value_micros": cart_value,
                        "store_id": row["store_id"],
                    }).encode("utf-8"),
                )
            if anomaly >= 0.7:
                yield beam.pvalue.TaggedOutput(
                    "activation",
                    json.dumps({
                        "signal": "PAYMENT_ANOMALY",
                        "session_id": session_id,
                        "anomaly_score": anomaly,
                        "payment_failures": failures,
                        "store_id": row["store_id"],
                    }).encode("utf-8"),
                )


def run(argv=None) -> None:
    opts = PipelineOptions(argv, streaming=True, save_main_session=True)
    custom = opts.view_as(Options)
    opts.view_as(StandardOptions).streaming = True
    opts.view_as(SetupOptions).save_main_session = True

    with beam.Pipeline(options=opts) as p:
        parsed = (
            p
            | "ReadPubSub" >> ReadFromPubSub(
                subscription=custom.input_subscription,
                with_attributes=True,
                timestamp_attribute="event_time",  # event time, NOT publish time
            )
            | "ToTuple" >> beam.Map(lambda m: (m.data, dict(m.attributes)))
            | "Parse" >> beam.ParDo(ParseEvent()).with_outputs(
                DEAD_LETTER, MAIN, main=MAIN
            )
        )

        sessions = (
            parsed[MAIN]
            | "KeyBySession" >> beam.Map(lambda r: (r["session_id"], r))
            | "SessionWindow" >> beam.WindowInto(
                window.Sessions(custom.session_gap_seconds),
                trigger=trigger.AfterWatermark(
                    early=trigger.AfterProcessingTime(custom.early_firing_sec),
                    late=trigger.AfterCount(1),
                ),
                accumulation_mode=trigger.AccumulationMode.ACCUMULATING,
                allowed_lateness=Duration(seconds=custom.allowed_lateness_sec),
            )
            | "GroupBySession" >> beam.GroupByKey()
            | "Score" >> beam.ParDo(
                ScoreSession(custom.pipeline_version)
            ).with_outputs("activation", MAIN, main=MAIN)
        )

        _ = (
            sessions[MAIN]
            | "WriteBQ" >> beam.io.WriteToBigQuery(
                table=custom.output_table,
                write_disposition=beam.io.BigQueryDisposition.WRITE_APPEND,
                create_disposition=beam.io.BigQueryDisposition.CREATE_NEVER,
                method=beam.io.WriteToBigQuery.Method.STORAGE_WRITE_API,
                triggering_frequency=10,
                with_auto_sharding=True,
            )
        )

        _ = (
            sessions["activation"]
            | "PublishActivation" >> WriteToPubSub(topic=custom.activation_topic)
        )

        _ = (
            parsed[DEAD_LETTER]
            | "EncodeDLQ" >> beam.Map(lambda d: json.dumps(d).encode("utf-8"))
            | "PublishDLQ" >> WriteToPubSub(topic=custom.dlq_topic)
        )


if __name__ == "__main__":
    logging.getLogger().setLevel(logging.INFO)
    run()
```

### 5.5 Productor en GKE — Deployment con Workload Identity

```yaml
# k8s/clickstream-gateway.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: analytics
  labels:
    domain: analytics
    env: prod
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: clickstream-gateway
  namespace: analytics
  annotations:
    # Workload Identity: bind KSA -> GSA. No JSON key ever touches the cluster.
    iam.gke.io/gcp-service-account: sa-clickstream-producer@acme-analytics-prod.iam.gserviceaccount.com
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: clickstream-gateway-config
  namespace: analytics
data:
  PUBSUB_TOPIC: "projects/acme-analytics-prod/topics/ingest-clickstream"
  PUBSUB_ORDERING_ENABLED: "true"
  # Batching: trade publish latency for cost. 100ms/1000 msgs is a good
  # starting point for a 50k msg/s gateway; measure publish latency after.
  PUBLISH_MAX_MESSAGES: "1000"
  PUBLISH_MAX_BYTES: "1048576"
  PUBLISH_MAX_LATENCY_MS: "100"
  PUBLISH_FLOW_CONTROL_MAX_OUTSTANDING_MESSAGES: "20000"
  PUBLISH_FLOW_CONTROL_LIMIT_EXCEEDED_BEHAVIOR: "block"
  OTEL_EXPORTER_OTLP_ENDPOINT: "http://otel-collector.observability:4317"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: clickstream-gateway
  namespace: analytics
  labels:
    app.kubernetes.io/name: clickstream-gateway
    app.kubernetes.io/component: ingest
spec:
  replicas: 6
  revisionHistoryLimit: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 2
      maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: clickstream-gateway
  template:
    metadata:
      labels:
        app.kubernetes.io/name: clickstream-gateway
        app.kubernetes.io/component: ingest
    spec:
      serviceAccountName: clickstream-gateway
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: clickstream-gateway
      containers:
        - name: gateway
          image: us-central1-docker.pkg.dev/acme-analytics-prod/apps/clickstream-gateway:1.9.2
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
            - name: metrics
              containerPort: 9090
          envFrom:
            - configMapRef:
                name: clickstream-gateway-config
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
          resources:
            requests:
              cpu: "500m"
              memory: "512Mi"
            limits:
              memory: "1Gi"     # no CPU limit: avoids CFS throttling on a
                                # latency-sensitive publisher
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: tmp
              mountPath: /tmp
          startupProbe:
            httpGet: { path: /healthz, port: http }
            failureThreshold: 30
            periodSeconds: 2
          readinessProbe:
            httpGet: { path: /readyz, port: http }
            periodSeconds: 5
            timeoutSeconds: 2
          livenessProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 10
            failureThreshold: 3
          lifecycle:
            preStop:
              exec:
                # Flush the publisher batch before the pod dies, otherwise the
                # in-memory batch (up to 1000 msgs) is lost on every rollout.
                command: ["/bin/sh", "-c", "sleep 15"]
      terminationGracePeriodSeconds: 45
      volumes:
        - name: tmp
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: clickstream-gateway
  namespace: analytics
spec:
  selector:
    app.kubernetes.io/name: clickstream-gateway
  ports:
    - name: http
      port: 80
      targetPort: http
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: clickstream-gateway
  namespace: analytics
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: clickstream-gateway
  minReplicas: 6
  maxReplicas: 60
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 65
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 30
      policies:
        - type: Percent
          value: 100
          periodSeconds: 30
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Percent
          value: 20
          periodSeconds: 60
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: clickstream-gateway
  namespace: analytics
spec:
  minAvailable: 80%
  selector:
    matchLabels:
      app.kubernetes.io/name: clickstream-gateway
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: clickstream-gateway-egress
  namespace: analytics
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: clickstream-gateway
  policyTypes: ["Egress"]
  egress:
    # Google APIs via Private Google Access / restricted VIP
    - to:
        - ipBlock:
            cidr: 199.36.153.4/30
      ports:
        - protocol: TCP
          port: 443
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

### 5.6 Dataform — la capa de transformación gobernada

`definitions/analytics/sessions_deduped.sqlx`:

```sql
config {
  type: "incremental",
  schema: "analytics",
  name: "sessions_deduped",
  description: "One row per (window_start, session_id): the final ACCUMULATING pane.",
  bigquery: {
    partitionBy: "DATE(window_start)",
    clusterBy: ["store_id", "country"],
    requirePartitionFilter: true
  },
  assertions: {
    uniqueKey: ["window_start", "session_id"],
    nonNull: ["session_id", "store_id", "event_count"]
  },
  tags: ["hourly", "analytics"]
}

SELECT * EXCEPT(rn)
FROM (
  SELECT
    *,
    ROW_NUMBER() OVER (
      PARTITION BY window_start, session_id
      ORDER BY pane_index DESC, ingested_at DESC
    ) AS rn
  FROM ${ref("session_metrics")}
  WHERE window_start >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 3 DAY)
  ${when(incremental(),
    `AND ingested_at > (SELECT COALESCE(MAX(ingested_at), TIMESTAMP('1970-01-01'))
                        FROM ${self()}
                        WHERE window_start >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 3 DAY))`)}
)
WHERE rn = 1
```

`definitions/marts/store_daily.sqlx`:

```sql
config {
  type: "table",
  schema: "marts",
  name: "store_daily",
  description: "Contract-stable daily store mart. Looker reads ONLY marts.*",
  bigquery: {
    partitionBy: "activity_date",
    clusterBy: ["store_id", "country"],
    requirePartitionFilter: false
  },
  tags: ["daily", "looker-contract"]
}

SELECT
  DATE(window_start)                                    AS activity_date,
  store_id,
  country,
  COUNT(DISTINCT session_id)                            AS sessions,
  COUNT(DISTINCT user_pseudo_id)                        AS visitors,
  COUNTIF(abandoned_cart)                               AS abandoned_carts,
  SAFE_DIVIDE(COUNTIF(abandoned_cart), COUNT(DISTINCT session_id)) AS abandonment_rate,
  SUM(IF(abandoned_cart, cart_value_micros, 0)) / 1e6   AS abandoned_value,
  SUM(payment_failures)                                 AS payment_failures,
  AVG(anomaly_score)                                    AS avg_anomaly_score,
  APPROX_QUANTILES(event_count, 100)[OFFSET(50)]        AS median_events_per_session
FROM ${ref("sessions_deduped")}
WHERE window_start >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 400 DAY)
GROUP BY 1, 2, 3
```

`definitions/marts/materialized_recent.sqlx` — la capa de aceleración de BI:

```sql
config { type: "operations", schema: "marts", name: "mv_store_hourly", tags: ["ddl"] }

CREATE MATERIALIZED VIEW IF NOT EXISTS `acme-analytics-prod.marts.mv_store_hourly`
PARTITION BY DATE(hour_start)
CLUSTER BY store_id
OPTIONS (
  enable_refresh = true,
  refresh_interval_minutes = 10,
  max_staleness = INTERVAL "0:30:0" HOUR TO SECOND
)
AS
SELECT
  TIMESTAMP_TRUNC(window_start, HOUR) AS hour_start,
  store_id,
  COUNT(1)              AS session_rows,
  COUNTIF(abandoned_cart) AS abandoned_carts,
  SUM(payment_failures) AS payment_failures
FROM `acme-analytics-prod.analytics.sessions_deduped`
GROUP BY 1, 2
```

> **Por qué importa `max_staleness`:** sin él, una vista materializada sobre una tabla de streaming obliga a BigQuery a leer las filas recientes (no materializadas) de la tabla base en cada consulta, lo que reintroduce el costo que estabas evitando. `max_staleness` permite que la vista sirva resultados precalculados dentro de un límite de frescura declarado — un punto explícito y negociado sobre el eje frescura/costo.

### 5.7 BigQuery ML — smart analytics dentro del warehouse

```sql
-- 1. Demand forecasting per store: 30 days ahead, from 400 days of history.
CREATE OR REPLACE MODEL `acme-analytics-prod.marts.store_demand_arima`
OPTIONS (
  model_type          = 'ARIMA_PLUS',
  time_series_timestamp_col = 'activity_date',
  time_series_data_col      = 'sessions',
  time_series_id_col        = 'store_id',
  holiday_region      = 'US',
  auto_arima          = TRUE,
  data_frequency      = 'DAILY',
  decompose_time_series = TRUE
) AS
SELECT activity_date, store_id, sessions
FROM `acme-analytics-prod.marts.store_daily`
WHERE activity_date BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 400 DAY)
                        AND DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY);

-- 2. Serve the forecast with prediction intervals.
SELECT
  store_id,
  forecast_timestamp,
  ROUND(forecast_value, 1)              AS forecast_sessions,
  ROUND(prediction_interval_lower_bound, 1) AS lo_80,
  ROUND(prediction_interval_upper_bound, 1) AS hi_80
FROM ML.FORECAST(
  MODEL `acme-analytics-prod.marts.store_demand_arima`,
  STRUCT(30 AS horizon, 0.8 AS confidence_level)
)
WHERE store_id = 'ST-0417'
ORDER BY forecast_timestamp;

-- 3. Fraud-adjacent classifier trained on the same session rows.
CREATE OR REPLACE MODEL `acme-analytics-prod.marts.payment_risk`
OPTIONS (
  model_type              = 'BOOSTED_TREE_CLASSIFIER',
  input_label_cols        = ['is_chargeback'],
  auto_class_weights      = TRUE,          -- the positive class is ~0.3%
  data_split_method       = 'SEQ',
  data_split_col          = 'window_start',
  data_split_eval_fraction = 0.2,
  max_iterations          = 50,
  early_stop              = TRUE
) AS
SELECT
  s.payment_failures,
  s.event_count,
  s.cart_value_micros,
  s.country,
  s.anomaly_score,
  s.window_start,
  c.is_chargeback
FROM `acme-analytics-prod.analytics.sessions_deduped` s
JOIN `acme-analytics-prod.marts.chargebacks` c USING (session_id)
WHERE s.window_start >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 180 DAY);

-- 4. Evaluate before anyone builds a dashboard on it.
SELECT * FROM ML.EVALUATE(MODEL `acme-analytics-prod.marts.payment_risk`);

-- 5. Explain a single prediction — required for any decision affecting a customer.
SELECT session_id, predicted_is_chargeback_probs, top_feature_attributions
FROM ML.EXPLAIN_PREDICT(
  MODEL `acme-analytics-prod.marts.payment_risk`,
  (SELECT * FROM `acme-analytics-prod.analytics.sessions_deduped`
    WHERE window_start >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 HOUR)),
  STRUCT(3 AS top_k_features)
);
```

### 5.8 Looker — la capa semántica que termina con el problema de los dos números

`views/store_daily.view.lkml`:

```lkml
view: store_daily {
  sql_table_name: `acme-analytics-prod.marts.store_daily` ;;

  dimension: pk {
    primary_key: yes
    hidden: yes
    type: string
    sql: CONCAT(${TABLE}.activity_date, '|', ${TABLE}.store_id) ;;
  }

  dimension_group: activity {
    type: time
    timeframes: [raw, date, week, month, quarter, year]
    convert_tz: no
    datatype: date
    sql: ${TABLE}.activity_date ;;
  }

  dimension: store_id { type: string  sql: ${TABLE}.store_id ;; }
  dimension: country  { type: string  map_layer_name: countries
                        sql: ${TABLE}.country ;; }

  measure: sessions {
    type: sum
    sql: ${TABLE}.sessions ;;
    description: "Distinct sessions, deduplicated on the final Beam pane."
  }

  measure: abandoned_carts {
    type: sum
    sql: ${TABLE}.abandoned_carts ;;
  }

  # THE definition of abandonment rate. There is exactly one, and it lives here.
  measure: abandonment_rate {
    type: number
    value_format_name: percent_2
    sql: SAFE_DIVIDE(${abandoned_carts}, NULLIF(${sessions}, 0)) ;;
    description: "abandoned_carts / sessions. Certified by Analytics Eng, 2026-09-01."
  }

  measure: abandoned_value {
    type: sum
    value_format_name: usd
    sql: ${TABLE}.abandoned_value ;;
  }

  measure: payment_failures { type: sum sql: ${TABLE}.payment_failures ;; }
}
```

`models/acme_retail.model.lkml`:

```lkml
connection: "bigquery_prod"
include: "/views/**/*.view.lkml"

datagroup: daily_marts {
  sql_trigger: SELECT MAX(activity_date) FROM `acme-analytics-prod.marts.store_daily` ;;
  max_cache_age: "4 hours"
}
persist_with: daily_marts

explore: store_performance {
  from: store_daily
  label: "Store Performance"
  description: "Certified store-level daily metrics. Source of truth for Finance and Growth."

  # Row-level security: a regional manager sees only their own stores.
  access_filter: {
    field: store_id
    user_attribute: allowed_store_ids
  }

  # Cost guardrail: never let a user scan the whole partitioned table.
  always_filter: {
    filters: [store_daily.activity_date: "90 days"]
  }

  # Aggregate awareness: route coarse queries to a small rollup.
  aggregate_table: monthly_by_country {
    query: {
      dimensions: [activity_month, country]
      measures: [sessions, abandoned_carts, abandoned_value]
    }
    materialization: { datagroup_trigger: daily_marts }
  }
}
```

### 5.9 DAG de Cloud Composer — orquestación y reconciliación

```python
"""Nightly reconciliation: the batch layer of the Lambda architecture.

Recomputes the previous day's sessions from the GCS replay archive and
compares them against what the streaming layer produced. A divergence above
the tolerance is a paging event, not a ticket: it means the streaming numbers
on the executive dashboard are wrong right now.
"""

from datetime import datetime, timedelta

from airflow import DAG
from airflow.providers.google.cloud.operators.bigquery import (
    BigQueryInsertJobOperator, BigQueryCheckOperator,
)
from airflow.providers.google.cloud.operators.dataflow import (
    DataflowStartFlexTemplateOperator,
)

DEFAULT_ARGS = {
    "owner": "data-platform",
    "retries": 2,
    "retry_delay": timedelta(minutes=10),
    "email_on_failure": False,
    "sla": timedelta(hours=3),
}

with DAG(
    dag_id="clickstream_reconcile_daily",
    schedule="0 3 * * *",
    start_date=datetime(2026, 8, 1),
    catchup=False,
    max_active_runs=1,
    default_args=DEFAULT_ARGS,
    tags=["analytics", "reconciliation"],
) as dag:

    replay_batch = DataflowStartFlexTemplateOperator(
        task_id="replay_batch_sessionise",
        location="us-central1",
        body={
            "launchParameter": {
                "jobName": "clickstream-replay-{{ ds_nodash }}",
                "containerSpecGcsPath":
                    "gs://acme-analytics-prod-dataflow-templates/clickstream-batch/v7.json",
                "parameters": {
                    "inputPattern":
                        "gs://acme-analytics-prod-clickstream-replay/clickstream/{{ ds }}/*.avro",
                    "outputTable": "acme-analytics-prod:analytics.session_metrics_batch$"
                                   "{{ ds_nodash }}",
                    "sessionGapSeconds": "1800",
                    "pipelineVersion": "batch-v7",
                },
                "environment": {
                    "serviceAccountEmail":
                        "sa-dataflow-clickstream@acme-analytics-prod.iam.gserviceaccount.com",
                    "tempLocation": "gs://acme-analytics-prod-dataflow-temp/temp",
                    "maxWorkers": 100,
                    "ipConfiguration": "WORKER_IP_PRIVATE",
                },
            }
        },
    )

    reconcile = BigQueryInsertJobOperator(
        task_id="compute_divergence",
        configuration={
            "query": {
                "useLegacySql": False,
                "query": """
                CREATE OR REPLACE TABLE `acme-analytics-prod.marts.reconciliation`
                PARTITION BY activity_date AS
                WITH stream AS (
                  SELECT DATE(window_start) AS activity_date, store_id,
                         COUNT(DISTINCT session_id) AS sessions_stream
                  FROM `acme-analytics-prod.analytics.sessions_deduped`
                  WHERE DATE(window_start) = DATE('{{ ds }}')
                  GROUP BY 1, 2
                ),
                batch AS (
                  SELECT DATE(window_start) AS activity_date, store_id,
                         COUNT(DISTINCT session_id) AS sessions_batch
                  FROM `acme-analytics-prod.analytics.session_metrics_batch`
                  WHERE DATE(window_start) = DATE('{{ ds }}')
                  GROUP BY 1, 2
                )
                SELECT
                  COALESCE(s.activity_date, b.activity_date) AS activity_date,
                  COALESCE(s.store_id, b.store_id)           AS store_id,
                  IFNULL(sessions_stream, 0)                 AS sessions_stream,
                  IFNULL(sessions_batch, 0)                  AS sessions_batch,
                  ABS(IFNULL(sessions_stream,0) - IFNULL(sessions_batch,0))
                    / NULLIF(IFNULL(sessions_batch,0), 0)    AS relative_divergence
                FROM stream s
                FULL OUTER JOIN batch b
                  USING (activity_date, store_id)
                """,
                "priority": "BATCH",
                "maximumBytesBilled": 5 * 1024**4,  # 5 TiB hard ceiling
            }
        },
        location="US",
    )

    assert_convergence = BigQueryCheckOperator(
        task_id="assert_divergence_within_tolerance",
        use_legacy_sql=False,
        location="US",
        sql="""
        SELECT COUNTIF(relative_divergence > 0.005) = 0
        FROM `acme-analytics-prod.marts.reconciliation`
        WHERE activity_date = DATE('{{ ds }}')
        """,
    )

    replay_batch >> reconcile >> assert_convergence
```

---

## 6. Operarlo: recorrido por CLI con salida real

### 6.1 Aprovisionar y verificar la capa de ingesta

```console
$ gcloud config set project acme-analytics-prod
Updated property [core/project].

$ gcloud pubsub schemas create clickstream-v1 \
    --type=AVRO \
    --definition-file=schemas/clickstream-v1.avsc
Created schema [clickstream-v1].

$ gcloud pubsub schemas validate-message \
    --schema-name=clickstream-v1 \
    --message-encoding=json \
    --message='{"event_id":"7f1c...","event_time":1757155203000000,"event_type":"ADD_TO_CART","session_id":"s-991","user_pseudo_id":"u-4412","store_id":"ST-0417","country":"US","device":{"platform":"ios"},"cart_value_micros":149990000,"currency":"USD","attributes":{},"schema_version":1}'
Message is valid.

$ gcloud pubsub topics create ingest-clickstream \
    --message-retention-duration=7d \
    --schema=clickstream-v1 \
    --message-encoding=binary \
    --message-storage-policy-allowed-regions=us-central1,us-east1
Created topic [projects/acme-analytics-prod/topics/ingest-clickstream].

$ gcloud pubsub subscriptions create sub-clickstream-enrich \
    --topic=ingest-clickstream \
    --ack-deadline=60 \
    --message-retention-duration=7d \
    --enable-exactly-once-delivery \
    --enable-message-ordering \
    --dead-letter-topic=clickstream-dlq \
    --max-delivery-attempts=5 \
    --min-retry-delay=10s --max-retry-delay=600s
Created subscription [projects/acme-analytics-prod/subscriptions/sub-clickstream-enrich].

$ gcloud pubsub subscriptions describe sub-clickstream-enrich \
    --format='yaml(name,ackDeadlineSeconds,enableExactlyOnceDelivery,enableMessageOrdering,deadLetterPolicy)'
ackDeadlineSeconds: 60
deadLetterPolicy:
  deadLetterTopic: projects/acme-analytics-prod/topics/clickstream-dlq
  maxDeliveryAttempts: 5
enableExactlyOnceDelivery: true
enableMessageOrdering: true
name: projects/acme-analytics-prod/subscriptions/sub-clickstream-enrich
```

**Verificación de que el esquema efectivamente se aplica** — publicá algo inválido y confirmá que se rechaza en el topic, no que se descubre tres etapas más abajo:

```console
$ gcloud pubsub topics publish ingest-clickstream --message='{"event_type":"NOT_A_REAL_TYPE"}'
ERROR: (gcloud.pubsub.topics.publish) INVALID_ARGUMENT: Invalid data in message.
- '@type': type.googleapis.com/google.rpc.BadRequest
  fieldViolations:
  - description: Message failed schema validation
    field: message
```

Ese único error vale una clase entera de páginas a las 3 de la mañana. La validación de esquema en el topic es el control de calidad de datos más barato de toda la pila.

### 6.2 Lanzar e inspeccionar el pipeline de streaming

```console
$ gcloud dataflow flex-template build \
    gs://acme-analytics-prod-dataflow-templates/clickstream-enrich/v7.json \
    --image-gcr-path=us-central1-docker.pkg.dev/acme-analytics-prod/dataflow/clickstream-enrich:v7 \
    --sdk-language=PYTHON \
    --flex-template-base-image=PYTHON3 \
    --metadata-file=templates/clickstream-enrich.metadata.json \
    --py-path=pipeline/ \
    --env=FLEX_TEMPLATE_PYTHON_PY_FILE=clickstream_enrich.py \
    --env=FLEX_TEMPLATE_PYTHON_REQUIREMENTS_FILE=requirements.txt
Successfully built and pushed image.
Template file created: gs://acme-analytics-prod-dataflow-templates/clickstream-enrich/v7.json

$ gcloud dataflow flex-template run clickstream-enrich-v7 \
    --template-file-gcs-location=gs://acme-analytics-prod-dataflow-templates/clickstream-enrich/v7.json \
    --region=us-central1 \
    --service-account-email=sa-dataflow-clickstream@acme-analytics-prod.iam.gserviceaccount.com \
    --subnetwork=regions/us-central1/subnetworks/snet-dataflow-us-central1 \
    --disable-public-ips \
    --enable-streaming-engine \
    --max-workers=40 --num-workers=4 --worker-machine-type=n2-standard-4 \
    --parameters=input_subscription=projects/acme-analytics-prod/subscriptions/sub-clickstream-enrich,output_table=acme-analytics-prod:analytics.session_metrics,activation_topic=projects/acme-analytics-prod/topics/activation-signals,dlq_topic=projects/acme-analytics-prod/topics/clickstream-dlq,session_gap_seconds=1800,allowed_lateness_sec=3600,early_firing_sec=30,pipeline_version=v7
job:
  createTime: '2026-09-06T11:12:34.882Z'
  currentStateTime: '1970-01-01T00:00:00Z'
  id: 2026-09-06_04_12_33-1184773290183746512
  location: us-central1
  name: clickstream-enrich-v7
  projectId: acme-analytics-prod
  startTime: '2026-09-06T11:12:34.882Z'

$ gcloud dataflow jobs list --region=us-central1 --status=active
JOB_ID                                    NAME                   TYPE       CREATION_TIME        STATE    REGION
2026-09-06_04_12_33-1184773290183746512   clickstream-enrich-v7  Streaming  2026-09-06 11:12:34  Running  us-central1

$ gcloud dataflow jobs describe 2026-09-06_04_12_33-1184773290183746512 \
    --region=us-central1 --format='yaml(currentState,environment.workerPools[0].numWorkers,jobMetadata)'
currentState: JOB_STATE_RUNNING
environment:
  workerPools:
  - numWorkers: 4

$ gcloud dataflow metrics list 2026-09-06_04_12_33-1184773290183746512 \
    --region=us-central1 --source=service --filter='name.name~"Watermark|Lag|Backlog"'
---
name:
  name: DataWatermarkAge
  origin: dataflow/v1b3
scalar: 41
updateTime: '2026-09-06T11:38:02.117Z'
---
name:
  name: SystemLag
  origin: dataflow/v1b3
scalar: 12
updateTime: '2026-09-06T11:38:02.117Z'
---
name:
  name: CurrentNumVcpus
  origin: dataflow/v1b3
scalar: 16
updateTime: '2026-09-06T11:38:02.117Z'
```

**Cómo leer esto correctamente:** `DataWatermarkAge: 41` significa que la frontera de tiempo de evento del pipeline está 41 segundos detrás del ahora — saludable. `SystemLag: 12` es la edad del elemento más antiguo actualmente en vuelo — también saludable. Cuando estos dos divergen (system lag bajo, edad del watermark subiendo), tenés una *fuente atascada*, no un pipeline lento. Esa distinción determina si escalás workers (inútil) o investigás la ordering key/la fuente (correcto).

### 6.3 Verificar que los datos están aterrizando y son correctos

```console
$ bq query --use_legacy_sql=false --format=pretty '
SELECT
  TIMESTAMP_TRUNC(window_start, MINUTE) AS minute,
  COUNT(*)                              AS rows_written,
  COUNT(DISTINCT session_id)            AS sessions,
  MAX(pane_index)                       AS max_pane,
  ROUND(AVG(TIMESTAMP_DIFF(ingested_at, window_end, SECOND)), 1) AS avg_emit_lag_s
FROM `acme-analytics-prod.analytics.session_metrics`
WHERE window_start >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 10 MINUTE)
GROUP BY 1 ORDER BY 1 DESC'

+---------------------+--------------+----------+----------+----------------+
|       minute        | rows_written | sessions | max_pane | avg_emit_lag_s |
+---------------------+--------------+----------+----------+----------------+
| 2026-09-06 11:36:00 |         9412 |     7188 |        3 |           38.2 |
| 2026-09-06 11:35:00 |        11077 |     8203 |        4 |           41.7 |
| 2026-09-06 11:34:00 |        10884 |     8140 |        4 |           39.9 |
| 2026-09-06 11:33:00 |        10731 |     8095 |        3 |           40.4 |
+---------------------+--------------+----------+----------+----------------+
```

`rows_written > sessions` es esperado y correcto — esos son los panes ACCUMULATING. Si alguna vez un dashboard lee `session_metrics` directamente en lugar de `sessions_deduped`, cada métrica se infla un ~35%. Precisamente por eso el `explore` de Looker está atado a `marts.*` y nunca a `analytics.*`.

**Verificación de costo antes de que alguien construya encima:**

```console
$ bq query --use_legacy_sql=false --dry_run '
SELECT store_id, COUNT(*) FROM `acme-analytics-prod.analytics.session_metrics`
GROUP BY 1'
Error in query string: Cannot query over table
'acme-analytics-prod.analytics.session_metrics' without a filter over column(s)
'window_start' that can be used for partition elimination

$ bq query --use_legacy_sql=false --dry_run '
SELECT store_id, COUNT(*) FROM `acme-analytics-prod.analytics.session_metrics`
WHERE window_start >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 DAY)
GROUP BY 1'
Query successfully validated. Assuming the tables are not modified, running this
query will process 2418576384 bytes of data.
```

`require_partition_filter = true` convirtió un escaneo de tabla completa en un error de compilación. Activalo en toda tabla de hechos grande; es el control de costo individual más fuerte que ofrece BigQuery.

### 6.4 Forense de slots y costo con `INFORMATION_SCHEMA`

```console
$ bq query --use_legacy_sql=false --format=pretty '
SELECT
  user_email,
  COUNT(*)                                       AS jobs,
  ROUND(SUM(total_bytes_billed)/POW(1024,4), 3)  AS tib_billed,
  ROUND(SUM(total_slot_ms)/1000/3600, 1)         AS slot_hours,
  ROUND(AVG(TIMESTAMP_DIFF(end_time, start_time, MILLISECOND))/1000, 2) AS avg_sec
FROM `region-us`.INFORMATION_SCHEMA.JOBS_BY_PROJECT
WHERE creation_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 24 HOUR)
  AND job_type = "QUERY" AND state = "DONE"
GROUP BY 1 ORDER BY slot_hours DESC LIMIT 8'

+------------------------------------------+------+------------+------------+---------+
|                user_email                | jobs | tib_billed | slot_hours | avg_sec |
+------------------------------------------+------+------------+------------+---------+
| looker-prod@acme-analytics-prod.iam.g... | 8412 |     41.882 |      612.4 |    2.11 |
| dataform@acme-analytics-prod.iam.gser... |  204 |     18.441 |      388.7 |   41.62 |
| lstudio-shared@acme-analytics-prod.ia... | 2887 |    103.219 |      944.8 |    9.84 |
| alice@acme.example                       |   61 |      6.004 |       71.2 |   18.03 |
+------------------------------------------+------+------------+------------+---------+
```

Esa tercera fila es el INC-5533 en curso: una credencial compartida de Looker Studio quemando 103 TiB/día en 2.887 consultas cortas. Profundizá:

```console
$ bq query --use_legacy_sql=false --format=pretty '
SELECT
  REGEXP_EXTRACT(query, r"FROM\s+`?([A-Za-z0-9_.\-]+)`?") AS source_table,
  COUNT(*) AS jobs,
  ROUND(SUM(total_bytes_billed)/POW(1024,4), 2) AS tib_billed
FROM `region-us`.INFORMATION_SCHEMA.JOBS_BY_PROJECT
WHERE creation_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 24 HOUR)
  AND user_email LIKE "lstudio-shared@%"
GROUP BY 1 ORDER BY tib_billed DESC LIMIT 5'

+-----------------------------------------------+------+------------+
|                 source_table                  | jobs | tib_billed |
+-----------------------------------------------+------+------------+
| acme-analytics-prod.raw.events_landing        | 2731 |     101.88 |
| acme-analytics-prod.marts.store_daily         |  156 |       1.34 |
+-----------------------------------------------+------+------------+
```

El informe está consultando la **tabla cruda de aterrizaje** directamente. Solución: revocar el acceso al dataset `raw` para la service account de BI, reapuntar el informe a `marts.store_daily`, y agregar una vista materializada para la ruta caliente. La gobernanza es un control de costo, no solo un control de cumplimiento.

### 6.5 Gobernanza y compartición

```console
$ bq update --schema_update_option=ALLOW_FIELD_ADDITION \
    --policy_tags='projects/acme-analytics-prod/locations/us-central1/taxonomies/8812.../policyTags/4471...' \
    acme-analytics-prod:analytics.session_metrics.user_pseudo_id
Table 'acme-analytics-prod:analytics.session_metrics' successfully updated.

$ bq query --use_legacy_sql=false '
CREATE OR REPLACE ROW ACCESS POLICY emea_managers
ON `acme-analytics-prod.marts.store_daily`
GRANT TO ("group:emea-managers@acme.example")
FILTER USING (country IN ("ES","FR","DE","IT","PT"))'
Created row access policy emea_managers on table
acme-analytics-prod:marts.store_daily.

$ bq ls --row_access_policies acme-analytics-prod:marts.store_daily
       policyId       |            filterPredicate            |     creationTime
 ---------------------+---------------------------------------+----------------------
  emea_managers       | country IN ("ES","FR","DE","IT","PT")  | 2026-09-06T11:44:12Z
```

Compartir un producto curado con un socio **sin copiar datos** — esto es Analytics Hub, y es la respuesta del examen a "¿cómo monetizamos o compartimos nuestros datos de forma segura?":

```console
$ bq mk --data_exchange --location=us --display_name="Acme Retail Insights" acme_retail_exchange
Data exchange 'projects/acme-analytics-prod/locations/us/dataExchanges/acme_retail_exchange' successfully created.

$ bq mk --listing --location=us \
    --data_exchange=acme_retail_exchange \
    --display_name="Store Daily Performance" \
    --source_dataset=acme-analytics-prod:marts \
    store_daily_listing
Listing 'projects/.../dataExchanges/acme_retail_exchange/listings/store_daily_listing' successfully created.
```

El suscriptor obtiene un **linked dataset**: un puntero de solo lectura, siempre actualizado. Sin exportación, sin egress, sin copia obsoleta, sin un segundo linaje que gobernar. Ese es el argumento de valor de negocio en una sola frase.

---

## 7. Verificación y diagnóstico de fallos

### 7.1 Las señales doradas de una plataforma de streaming analytics

| Señal | Métrica | Saludable | Paginar en | Qué significa realmente |
|---|---|---|---|---|
| **Edad del backlog** | `pubsub.googleapis.com/subscription/oldest_unacked_message_age` | < 60 s | > 300 s durante 5 m | Frescura extremo a extremo. El SLI del que es dueño tu negocio. |
| **Tamaño del backlog** | `subscription/num_undelivered_messages` | plano | creciendo monótonamente 15 m | Los consumidores no dan abasto — o están muertos |
| **Edad del watermark** | `dataflow.googleapis.com/job/per_stage_data_watermark_age` | < 120 s | > 900 s | Progreso en tiempo de evento. Si se estanca, las ventanas nunca cierran y los resultados nunca se emiten |
| **System lag** | `job/system_lag` | < 60 s | > 300 s | Elemento más antiguo en vuelo. Lag alto + edad de watermark baja = procesamiento lento |
| **Saturación de workers** | `job/current_num_vcpus` vs `max_workers` | < 80% del tope | clavado en el tope 15 m | El autoscaler se quedó sin margen |
| **Tasa de DLQ** | `topic/send_message_operation_count` en el topic DLQ | ~0 | > 1/s durante 5 m | Mensajes envenenados o una ruptura de esquema aguas arriba |
| **Errores de publicación** | `topic/send_request_count` filtrado por códigos de respuesta distintos de OK | 0 | cualquiera sostenido | IAM del productor, cuota, o fallo de esquema |
| **Errores de escritura en BQ** | Contador personalizado de Dataflow + logs de error de `Storage Write API` | 0 | cualquiera sostenido | Deriva de esquema, cuota, o violación del filtro de partición |
| **Saturación de slots** | `bigquery.googleapis.com/slots/allocated_for_reservation` | < 80% del máximo | en el tope 15 m | Encolamiento de consultas; los usuarios interactivos lo ven como "la BI está lenta" |
| **Frescura de los marts** | `MAX(ingested_at)` en cada mart, exportado como métrica personalizada | < SLA | > SLA | El dashboard está mostrando ayer |

### 7.2 Tabla síntoma → diagnóstico

| Síntoma | Causa más probable | Evidencia que lo confirma | Remediación |
|---|---|---|---|
| Backlog subiendo, watermark subiendo, workers al máximo | Subaprovisionamiento genuino | `current_num_vcpus == max_workers`, uso de CPU > 80% | Subir `--max-workers`; si ya es alto, buscar una hot key o un `DoFn` costoso |
| Backlog subiendo, workers **ociosos** | Hot key / sesgo de ordering key — todo el tráfico en una clave se serializa en un solo worker | El grafo del job muestra una etapa con conteos de elementos sesgados; habilitar `--experiments=enable_stackdriver_agent_metrics` | Agregar un salt a la clave y reagregar, o quitar `enable_message_ordering` si el orden por clave no es realmente necesario |
| Watermark estancado, system lag bajo | Fuente atascada: un mensaje sin ack fija el watermark; con frecuencia es un mensaje envenenado reintentándose | `oldest_unacked_message_age` subiendo linealmente (1 s por s) | Revisar la DLQ; confirmar que existe `dead_letter_policy` — **sin una DLQ, un mensaje envenenado estanca el pipeline para siempre** |
| El watermark avanza pero no salen filas | Las ventanas no cierran: latencia permitida enorme, o el trigger nunca dispara | Los contadores de Beam muestran elementos entrando pero ninguno saliendo de `GroupByKey` | Agregar disparos tempranos; reducir la latencia permitida; verificar que `timestamp_attribute` esté configurado — sin él Beam usa el tiempo de publicación y la lógica de tiempo de evento cambia de significado en silencio |
| Las filas en BigQuery están duplicadas ~2–4× | Panes ACCUMULATING leídos sin deduplicación | `SELECT session_id, COUNT(*) … HAVING COUNT(*)>1` devuelve filas con `pane_index` distintos | Leer `sessions_deduped`, no `session_metrics`. Hacerlo cumplir con IAM de dataset |
| Faltan filas de una hora específica | Los datos llegaron más tarde que `allowed_lateness` y fueron descartados | Contador de Beam `droppedDueToLateness` > 0 | Aumentar la latencia permitida; agregar una rama de "llegadas tardías" que escriba a una tabla aparte en vez de descartar |
| La DLQ se llena con `PERMISSION_DENIED` | La SA escritora push/BQ de la suscripción no tiene `roles/bigquery.dataEditor` | `gcloud logging read 'resource.type=pubsub_subscription severity>=ERROR'` | Otorgar el rol; notá que las suscripciones BigQuery usan la SA de la **suscripción**, no la del topic |
| La suscripción BigQuery descarta campos en silencio | `drop_unknown_fields = true` con un esquema que derivó | Comparar la revisión de esquema del topic contra el esquema de la tabla | Agregar columnas a la tabla primero, *después* publicar la nueva revisión del esquema. El orden importa |
| Los streaming inserts fallan con `quotaExceeded` | Cuota de streaming por tabla o límites de throughput de Storage Write API | Logs de error en el paso de escritura; métricas `bigquery.googleapis.com/quota/*` | Aumentar `triggering_frequency` para agrupar más, habilitar `with_auto_sharding`, o repartir las escrituras entre tablas |
| Pico de costo de consultas de un día para el otro | Una nueva consulta programada o informe de BI escaneando una tabla sin particionar | `INFORMATION_SCHEMA.JOBS_BY_PROJECT` agrupado por `user_email` y tabla origen | `require_partition_filter`, `maximum_bytes_billed`, cuotas personalizadas, topes de reserva |
| Dashboards de Looker lentos, el warehouse "bien" | Contención de slots: la BI compite con el ELT en la misma reserva | `slots/allocated_for_reservation` en el tope durante la ventana de ELT | Separar reservas con asignaciones: `res-bi` (interactivo) y `res-elt` (batch), `ignore_idle_slots = false` en BI |
| Dos dashboards, dos números | Deriva semántica — lógica duplicada fuera del modelo | Diferenciar el SQL compilado de Looker contra el SQL del informe ad-hoc | Revocar el acceso directo a `analytics.*` para usuarios de BI; exponer solo `marts.*` y las medidas de LookML |
| La actualización del pipeline falla con "not update-compatible" | El DAG de Beam cambió de una forma que invalida el estado persistido | Error de `gcloud dataflow jobs update` nombrando el paso incompatible | Usar `--transform_name_mapping`, o drenar el job viejo y arrancar de cero — aceptando un hueco de una ventana |

### 7.3 Secuencia de comandos de diagnóstico para "el dashboard está desactualizado"

```console
# 1. Is data still arriving at the topic at all?
$ gcloud monitoring time-series list \
    --filter='metric.type="pubsub.googleapis.com/topic/send_message_operation_count"
              AND resource.labels.topic_id="ingest-clickstream"' \
    --format='value(points[0].value.int64Value)' --interval-end-time="$(date -u +%FT%TZ)"
184203

# 2. Is the subscription draining?
$ gcloud pubsub subscriptions describe sub-clickstream-enrich --format='value(name)' >/dev/null && \
  gcloud monitoring time-series list \
    --filter='metric.type="pubsub.googleapis.com/subscription/num_undelivered_messages"
              AND resource.labels.subscription_id="sub-clickstream-enrich"' \
    --format='value(points[0].value.int64Value)'
4188271          # <-- 4.1M backlog. Consumers are not keeping up.

# 3. Is the Dataflow job even alive?
$ gcloud dataflow jobs list --region=us-central1 --status=all --limit=3
JOB_ID                                    NAME                   TYPE       CREATION_TIME        STATE     REGION
2026-09-06_04_12_33-1184773290183746512   clickstream-enrich-v7  Streaming  2026-09-06 11:12:34  Running   us-central1
2026-09-05_02_00_11-9928374651029384756   clickstream-enrich-v6  Streaming  2026-09-05 09:00:12  Drained   us-central1

# 4. Where is it stuck?
$ gcloud logging read '
  resource.type="dataflow_step"
  AND resource.labels.job_id="2026-09-06_04_12_33-1184773290183746512"
  AND severity>=WARNING' --limit=5 --format='value(timestamp,jsonPayload.message)'
2026-09-06T12:04:11Z  Operation ongoing in step Score/GroupBySession for at least 20m00s
                      without outputting or completing in state process-timers
2026-09-06T12:04:11Z    at java.base@17/java.lang.Thread.sleep(Native Method)
2026-09-06T12:02:47Z  Processing stuck in step Score for at least 15m00s

# 5. Confirm the hot-key hypothesis.
$ bq query --use_legacy_sql=false --format=pretty '
SELECT session_id, COUNT(*) AS events
FROM `acme-analytics-prod.raw.events_landing`
WHERE event_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 MINUTE)
GROUP BY 1 ORDER BY events DESC LIMIT 3'
+---------------------------+---------+
|        session_id         | events  |
+---------------------------+---------+
| s-UNKNOWN                 | 3914772 |
| s-8f21a0c4-...            |      41 |
| s-1b09ee77-...            |      38 |
+---------------------------+---------+
```

**Diagnóstico:** una release del cliente está emitiendo `session_id = "s-UNKNOWN"` cuando su almacén de sesión está vacío. El ordenamiento está habilitado, así que 3,9 M de eventos se serializan sobre una única ordering key y un único worker. Todas las demás sesiones quedan encoladas detrás.

**Mitigación inmediata** (frenar la hemorragia, después arreglar el cliente):

```console
$ gcloud dataflow flex-template run clickstream-enrich-v7-hotfix \
    --template-file-gcs-location=gs://.../clickstream-enrich/v7.json \
    --region=us-central1 \
    --parameters=...,excludeSessionIds=s-UNKNOWN,dlqUnknownSessions=true
```

**Arreglo estructural:** saltear la clave (`session_id || '#' || MOD(FARM_FINGERPRINT(event_id), 16)`) y reagregar, más una restricción de esquema que rechace session IDs centinela en el topic.

### 7.4 Replay: demostrar que la arquitectura puede recuperarse

La suscripción de Cloud Storage existe exactamente para este momento.

```console
# Option A — Pub/Sub seek, when the bad window is inside the retention period.
$ gcloud pubsub subscriptions seek sub-clickstream-enrich \
    --time=2026-09-06T10:00:00Z
Set the subscription [projects/acme-analytics-prod/subscriptions/sub-clickstream-enrich]
to the specified time.

# Option B — batch replay from the archive into a shadow table, then swap.
$ gcloud dataflow flex-template run clickstream-replay-20260906 \
    --template-file-gcs-location=gs://.../clickstream-batch/v7.json \
    --region=us-central1 --max-workers=100 \
    --parameters=inputPattern=gs://acme-analytics-prod-clickstream-replay/clickstream/2026-09-06/*.avro,outputTable=acme-analytics-prod:analytics.session_metrics_replay,sessionGapSeconds=1800,pipelineVersion=replay-v7

$ bq query --use_legacy_sql=false --format=pretty '
SELECT
  (SELECT COUNT(DISTINCT session_id) FROM `acme-analytics-prod.analytics.sessions_deduped`
    WHERE DATE(window_start)=DATE("2026-09-06")) AS stream_sessions,
  (SELECT COUNT(DISTINCT session_id) FROM `acme-analytics-prod.analytics.session_metrics_replay`
    WHERE DATE(window_start)=DATE("2026-09-06")) AS replay_sessions'
+-----------------+-----------------+
| stream_sessions | replay_sessions |
+-----------------+-----------------+
|          811402 |          847933 |
+-----------------+-----------------+
```

Un déficit del 4,5% en la capa de streaming confirma que se perdieron eventos durante el estancamiento por hot key. Corregí la partición atómicamente:

```console
$ bq query --use_legacy_sql=false '
CREATE OR REPLACE TABLE `acme-analytics-prod.analytics.sessions_deduped$20260906` AS
SELECT * FROM `acme-analytics-prod.analytics.session_metrics_replay`
WHERE DATE(window_start) = DATE("2026-09-06")'
Waiting on bqjob_r4c1a...  ... (12s) Current status: DONE
```

**Esto es la arquitectura Lambda haciendo su trabajo**: la capa de velocidad te da una respuesta en 40 segundos que suele ser correcta; la capa batch te da una respuesta autoritativa que siempre es correcta, y sobrescribe la partición de la capa de velocidad. Diseñá la capa batch *antes* del incidente, no después.

---

## 8. Ingeniería de costos — los números de los que un platform architect es responsable

| Palanca | Mecanismo | Impacto típico | Riesgo si se aplica mal |
|---|---|---|---|
| Particionado + `require_partition_filter` | Elimina los full scans en tiempo de compilación | Reducción de 10–100× en hechos de series temporales | Rompe consultas ingenuas — ese es el punto |
| Clustering | Poda a nivel de bloque en filtros de alta cardinalidad | 2–10× en predicados selectivos | Ningún beneficio si las columnas de filtro no son las claves de clustering, en orden |
| Vistas materializadas con `max_staleness` | Agregados precalculados, refresco incremental | 5–50× en agregaciones de BI repetidas | La obsolescencia debe negociarse con el negocio, por escrito |
| Reserva de BI Engine | Aceleración en memoria para consultas de BI | Dashboards sub-segundo, menos slots | Limitado por memoria; no todas las consultas son elegibles |
| Aggregate awareness de Looker | Enruta automáticamente las consultas gruesas a rollups pequeños | Grande, invisible para los usuarios | Los rollups deben mantenerse sincronizados vía datagroups |
| Editions + topes de reserva | Convierte un costo no acotado en un techo fijo | Previsibilidad | El subaprovisionamiento se manifiesta como encolamiento de consultas |
| Facturación de almacenamiento físico (comprimido) | Factura bytes comprimidos | Frecuentemente 2–5× en datos amigables al formato columnar | Elección a nivel de dataset con un período de espera para cambiar |
| Reemplazar Dataflow por una suscripción BigQuery | Elimina un sistema distribuido always-on | Elimina la línea entera de cómputo de streaming | Solo válido cuando no se requiere lógica por evento |
| `bq load` batch en lugar de streaming | Los jobs de carga son gratis o facturados por reserva | Elimina por completo el costo de ingesta por streaming | Minutos de latencia en lugar de segundos |
| Batching de Pub/Sub en el publicador | Menos requests, más grandes | Menor costo de publicación y CPU | Agrega latencia de publicación; hacer flush en `preStop` |
| `maximum_bytes_billed` en toda consulta automatizada | Falla en vez de gastar de más | Previene el desmadre | Requiere un runbook para los fallos resultantes |
| Lifecycle de GCS en el archivo de replay | STANDARD → NEARLINE → ARCHIVE | Grande en retenciones largas | Costo de recuperación y cargos por duración mínima al acceder antes de tiempo |

**La pregunta rectora en toda revisión de diseño:** *¿cuál es el valor de negocio de un minuto de frescura en este dataset, y supera el costo marginal de lograrlo?* Si nadie puede responder, la respuesta es batch.

---

## 9. Mapeo a casos de uso de negocio (el encuadre real del examen)

El examen CDL te pide conectar una *situación de negocio* con la *capacidad de analítica correcta*. Esta es la tabla de mapeo que hay que internalizar.

| Situación de negocio | Motor de valor | Patrón de GCP | Por qué no la alternativa |
|---|---|---|---|
| **Retail:** recuperar carritos abandonados | Recuperación de ingresos dentro de la ventana de intención (minutos) | Pub/Sub → sesiones en Dataflow → topic de activación → mensajería en Cloud Run | El batch nocturno pierde la ventana de intención por completo; el cliente ya compró en otro lado |
| **Servicios financieros:** fraude con tarjeta | Prevención de pérdidas; la decisión debe preceder a la autorización | Pub/Sub (exactly-once) → scoring con estado en Dataflow + BigQuery ML / endpoint de Vertex AI | Un dashboard que reporta el fraude de ayer es un artefacto de auditoría, no un control |
| **Manufactura/IoT:** mantenimiento predictivo | Downtime no planificado evitado | Gateway IoT → Pub/Sub → Dataflow (ventanas de anomalía) → BigQuery + Bigtable para series temporales de alta tasa | Bigtable para la serie cruda de alta cardinalidad, BigQuery para los agregados analíticos — usar uno para ambos es el error clásico |
| **Gaming:** live-ops y salud del matchmaking | Retención de jugadores; actuar durante la sesión | Pub/Sub → Dataflow → BigQuery + dashboards en tiempo real de Looker | La misma lógica de ventana de intención que en retail, en minutos |
| **Medios:** recomendación de contenido | Engagement, tiempo de visionado | Factorización de matrices / embeddings con BigQuery ML + `VECTOR_SEARCH`, servido vía reverse ETL | Exportar a una plataforma de ML externa agrega una frontera de gobernanza y un hueco de obsolescencia |
| **Cadena de suministro:** pronóstico de demanda | Costo de mantener inventario, quiebres de stock | `ARIMA_PLUS` de BigQuery sobre el mart diario, Looker para los planificadores | El streaming no aporta nada — la cadencia de decisión es semanal |
| **A nivel de toda la empresa:** "una sola versión de la verdad" | Velocidad de decisión y confianza | Capa semántica de Looker sobre `marts.*` gobernados | Más dashboards sobre tablas crudas empeora el problema, no lo mejora |
| **Socios/monetización:** compartir datos curados | Nuevos ingresos, sin riesgo de copia | Linked datasets de Analytics Hub, data clean rooms | Exportar CSVs crea copias descontroladas sin linaje y sin posibilidad de revocación |
| **El equipo de finanzas vive en hojas de cálculo** | Adopción sin exportaciones no gobernadas | Connected Sheets sobre BigQuery | Una exportación a CSV es una pérdida inmediata y permanente de gobernanza |
| **Parque Hadoop legacy** | Migración sin reescritura | Dataproc / Dataproc Serverless, y luego movimiento incremental a BigQuery | Una reescritura big-bang a BigQuery se estanca; aterrizar-y-después-modernizar sí llega |

### 9.1 El árbol de decisión para el examen

```
Is the decision worthless if it arrives an hour late?
├── YES → STREAMING
│    └── Does the transformation need event-time windows, state, or late data?
│         ├── YES → Pub/Sub → Dataflow → BigQuery (Storage Write API)
│         └── NO  → Pub/Sub → BigQuery subscription (+ SQL / continuous queries)
└── NO  → BATCH
     └── Where does the data live?
          ├── OLTP database        → Datastream (CDC)
          ├── SaaS / ads platform  → BigQuery Data Transfer Service
          ├── Another cloud / S3   → Storage Transfer Service, or BigLake in place
          ├── Files in GCS         → bq load / Dataflow batch
          └── Existing Spark jobs  → Dataproc (or Dataproc Serverless)

Then: who consumes it?
├── Governed, org-wide metrics, embedded analytics → Looker (LookML)
├── Free, quick, self-service dashboards           → Looker Studio
├── Spreadsheet users, billions of rows            → Connected Sheets
├── Data scientists                                → BigQuery Studio / notebooks / Vertex AI
├── ML predictions inside SQL                      → BigQuery ML
└── External partners, no data copy                → Analytics Hub
```

---

## 10. Qué hay que saber decir de memoria el día del examen

1. **El ciclo de vida**: ingest → store → process → analyze → activate, con el servicio principal en cada etapa.
2. **Pub/Sub es el backbone de eventos global y serverless**; Dataflow es el procesador unificado batch+stream construido sobre Apache Beam; BigQuery es el warehouse serverless; Looker es la capa semántica gobernada; Looker Studio es la herramienta de dashboarding gratuita; Connected Sheets es BigQuery en una hoja de cálculo.
3. **El batch responde "qué pasó"; el streaming responde "qué está pasando"** — y la elección la determina qué tan rápido decae el valor de la decisión, no la preferencia técnica.
4. **BigQuery ML lleva el ML a los datos**, eliminando el paso de exportación, su riesgo de gobernanza y su cuello de botella de especialistas. Ese es el valor de negocio de "smart analytics".
5. **Dataproc es para hacer lift-and-shift de Hadoop/Spark**; Dataflow es para pipelines nuevos donde la corrección en tiempo de evento importa.
6. **Datastream** replica bases de datos operativas hacia BigQuery con baja latencia y sin cambios en la aplicación.
7. **Analytics Hub** comparte datos sin copiarlos. **Dataplex Universal Catalog** los gobierna y los descubre a lo largo de todo el parque.
8. **El error arquitectónico más común** es poner la BI directamente sobre tablas crudas: produce números en conflicto *y* costo descontrolado, por la misma causa raíz — la ausencia de una capa gobernada entre el almacenamiento y el consumo.

---

## Referencias

**Examen y certificación**
- Guía del examen Cloud Digital Leader (PDF): https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
- Certificación Cloud Digital Leader: https://cloud.google.com/learn/certification/cloud-digital-leader

**Plataforma de smart analytics**
- Soluciones de smart analytics: https://cloud.google.com/solutions/smart-analytics
- Panorama de productos de analítica de datos: https://cloud.google.com/products/#data-analytics
- Ciclo de vida del dato en Google Cloud: https://cloud.google.com/architecture/data-lifecycle-cloud-platform

**Ingesta — Pub/Sub, Datastream, transferencias**
- Documentación de Pub/Sub: https://cloud.google.com/pubsub/docs
- Esquemas de Pub/Sub: https://cloud.google.com/pubsub/docs/schemas
- Entrega exactly-once: https://cloud.google.com/pubsub/docs/exactly-once-delivery
- Ordenamiento de mensajes: https://cloud.google.com/pubsub/docs/ordering
- Dead-letter topics: https://cloud.google.com/pubsub/docs/handling-failures
- Suscripciones BigQuery: https://cloud.google.com/pubsub/docs/bigquery
- Suscripciones Cloud Storage: https://cloud.google.com/pubsub/docs/cloudstorage
- Replay y seek: https://cloud.google.com/pubsub/docs/replay-overview
- Monitoreo de Pub/Sub: https://cloud.google.com/pubsub/docs/monitoring
- Managed Service for Apache Kafka: https://cloud.google.com/managed-service-for-apache-kafka/docs
- Documentación de Datastream: https://cloud.google.com/datastream/docs
- Datastream hacia BigQuery: https://cloud.google.com/datastream/docs/destination-bigquery
- Storage Transfer Service: https://cloud.google.com/storage-transfer/docs
- BigQuery Data Transfer Service: https://cloud.google.com/bigquery/docs/dts-introduction

**Procesamiento — Dataflow, Beam, Dataproc, Dataform, Composer**
- Documentación de Dataflow: https://cloud.google.com/dataflow/docs
- Pipelines de streaming: https://cloud.google.com/dataflow/docs/concepts/streaming-pipelines
- Streaming Engine: https://cloud.google.com/dataflow/docs/streaming-engine
- Dataflow Prime: https://cloud.google.com/dataflow/docs/guides/enable-dataflow-prime
- Flex Templates: https://cloud.google.com/dataflow/docs/guides/templates/using-flex-templates
- Actualizar / drenar un job de streaming: https://cloud.google.com/dataflow/docs/guides/updating-a-pipeline
- Resolución de problemas de Dataflow: https://cloud.google.com/dataflow/docs/guides/troubleshooting-your-pipeline
- Métricas de monitoreo de Dataflow: https://cloud.google.com/dataflow/docs/guides/using-monitoring-intf
- Guía de programación de Apache Beam (ventanas, triggers, watermarks): https://beam.apache.org/documentation/programming-guide/
- Modelo de streaming de Beam ("Streaming 101/102"): https://beam.apache.org/documentation/basics/
- Documentación de Dataproc: https://cloud.google.com/dataproc/docs
- Dataproc Serverless for Spark: https://cloud.google.com/dataproc-serverless/docs
- Cloud Data Fusion: https://cloud.google.com/data-fusion/docs
- Dataform: https://cloud.google.com/dataform/docs
- Cloud Composer: https://cloud.google.com/composer/docs

**Análisis — BigQuery**
- Documentación de BigQuery: https://cloud.google.com/bigquery/docs
- Arquitectura de BigQuery / por dentro: https://cloud.google.com/bigquery/docs/introduction
- Tablas particionadas: https://cloud.google.com/bigquery/docs/partitioned-tables
- Tablas clusterizadas: https://cloud.google.com/bigquery/docs/clustered-tables
- Vistas materializadas: https://cloud.google.com/bigquery/docs/materialized-views-intro
- BigQuery Storage Write API: https://cloud.google.com/bigquery/docs/write-api
- Streaming de datos hacia BigQuery: https://cloud.google.com/bigquery/docs/streaming-data-into-bigquery
- Vistas de jobs de INFORMATION_SCHEMA: https://cloud.google.com/bigquery/docs/information-schema-jobs
- Ediciones y reservas: https://cloud.google.com/bigquery/docs/editions-intro
- Gestión de cargas de trabajo con reservas: https://cloud.google.com/bigquery/docs/reservations-intro
- Control de costos: https://cloud.google.com/bigquery/docs/best-practices-costs
- Controles de costo personalizados / cuotas: https://cloud.google.com/bigquery/docs/custom-quotas
- BI Engine: https://cloud.google.com/bigquery/docs/bi-engine-intro
- Seguridad a nivel de fila: https://cloud.google.com/bigquery/docs/row-level-security-intro
- Control de acceso a nivel de columna: https://cloud.google.com/bigquery/docs/column-level-security-intro
- BigLake: https://cloud.google.com/biglake/docs
- Analytics Hub: https://cloud.google.com/bigquery/docs/analytics-hub-introduction
- Precios de BigQuery: https://cloud.google.com/bigquery/pricing

**Smart analytics / ML en el warehouse**
- Introducción a BigQuery ML: https://cloud.google.com/bigquery/docs/bqml-introduction
- Sintaxis de `CREATE MODEL`: https://cloud.google.com/bigquery/docs/reference/standard-sql/bigqueryml-syntax-create
- Pronóstico de series temporales con ARIMA_PLUS: https://cloud.google.com/bigquery/docs/arima-plus-single-time-series-forecasting-tutorial
- `ML.EXPLAIN_PREDICT`: https://cloud.google.com/bigquery/docs/reference/standard-sql/bigqueryml-syntax-explain-predict
- IA generativa en BigQuery: https://cloud.google.com/bigquery/docs/generative-ai-overview
- Vector search en BigQuery: https://cloud.google.com/bigquery/docs/vector-search-intro
- Documentación de Vertex AI: https://cloud.google.com/vertex-ai/docs

**Business intelligence**
- Documentación de Looker: https://cloud.google.com/looker/docs
- Panorama de LookML: https://cloud.google.com/looker/docs/what-is-lookml
- Access filters y seguridad a nivel de fila en Looker: https://cloud.google.com/looker/docs/reference/param-explore-access-filter
- Aggregate awareness: https://cloud.google.com/looker/docs/aggregate-awareness
- Looker Studio: https://support.google.com/looker-studio/answer/6283323
- Looker Studio Pro: https://cloud.google.com/looker-studio/docs
- Connected Sheets: https://cloud.google.com/bigquery/docs/connected-sheets

**Gobernanza y fiabilidad**
- Documentación de Dataplex: https://cloud.google.com/dataplex/docs
- Gobernanza de datos en Google Cloud: https://cloud.google.com/architecture/data-governance
- Políticas de alertas de Cloud Monitoring: https://cloud.google.com/monitoring/alerts
- Google Cloud Architecture Framework — Fiabilidad: https://cloud.google.com/architecture/framework/reliability
- Proveedor Terraform de Google: https://registry.terraform.io/providers/hashicorp/google/latest/docs
- Workload Identity Federation en GKE: https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity