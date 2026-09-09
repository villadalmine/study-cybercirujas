# gcp-cdl — Tema 2.2

## Determinar qué productos de gestión de datos de Google Cloud son aplicables a distintos casos de uso de negocio

**Peso en el examen: 6.0 · Versión del examen 2026-08-12**
**Formato:** ejercicios guiados. Ejecutá todos los pasos numerados y después respondé las preguntas de control antes de seguir. La clave de respuestas está plegada al final — no la abras hasta haber escrito tus propias respuestas.

> **Referencia:** [Guía del examen Cloud Digital Leader (PDF)](https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf), sección 2.2.

---

## 0. Prerrequisitos del laboratorio

El examen CDL es un examen de decisiones de negocio, pero una decisión que nunca viste ejecutar es una decisión que no podés defender. La mayor parte de lo que sigue corre **gratis**: llamadas de list/describe, validación con `--dry-run` y emuladores locales. Los pasos que crean recursos facturables están marcados con **💸 FACTURABLE** y cada uno tiene su paso de desmantelamiento.

### Pasos

1. Verificá el SDK y tu proyecto activo:

```bash
gcloud version | head -3
gcloud config list
```

Esperado:

```
Google Cloud SDK 5xx.0.0
bq 2.x.x
core 2026.xx.xx

[core]
account = you@example.com
disable_usage_reporting = False
project = cdl-lab-2026
```

2. Exportá el proyecto una vez para que todos los comandos posteriores sean copiables y pegables:

```bash
export PROJECT_ID="$(gcloud config get-value project)"
export REGION="us-central1"
echo "project=$PROJECT_ID region=$REGION"
```

3. Habilitá solamente las APIs que necesitan las partes gratuitas del laboratorio:

```bash
gcloud services enable storage.googleapis.com bigquery.googleapis.com \
  pubsub.googleapis.com --project="$PROJECT_ID"
```

Esperado: `Operation "operations/acat.p2-...-...." finished successfully.`

4. Confirmá cuáles de los servicios de datos ya están alcanzables en tu organización (esto es un inventario de solo lectura, no crea recursos):

```bash
gcloud services list --available --project="$PROJECT_ID" \
  --filter="config.name~(sqladmin|spanner|alloydb|bigtableadmin|firestore|redis|datastream|datafusion|dataflow|dataproc|dataplex|datamigration)" \
  --format="table(config.name, config.title)"
```

Esperado (abreviado):

```
NAME                          TITLE
alloydb.googleapis.com        AlloyDB API
bigtableadmin.googleapis.com  Cloud Bigtable Admin API
datamigration.googleapis.com  Database Migration API
dataflow.googleapis.com       Dataflow API
firestore.googleapis.com      Cloud Firestore API
spanner.googleapis.com        Cloud Spanner API
sqladmin.googleapis.com       Cloud SQL Admin API
```

### Control 0

- **P1.** `gcloud services list --available` devolvió Spanner y AlloyDB aunque nunca los usaste. ¿Qué te dice eso sobre el costo, y qué *no* te dice?
- **P2.** ¿Por qué un Cloud Digital Leader necesita distinguir entre *habilitar una API* y *aprovisionar una instancia* cuando habla con alguien del área de finanzas?

---

## 1. Clasificá la carga de trabajo antes de nombrar un producto

Todo ítem 2.2 del examen es el mismo rompecabezas con distinta ropa: una frase de negocio esconde una **clase de carga de trabajo**, y la clase de carga de trabajo elige el producto. Aprendé la clasificación, no el catálogo.

Las cuatro preguntas que resuelven casi todos los casos:

| Pregunta | Si la respuesta es… | Estás en… |
|---|---|---|
| ¿Cuál es la *forma* de los datos? | Filas con esquema fijo y relaciones | Relacional (Cloud SQL / AlloyDB / Spanner) |
| | Documentos semiestructurados, por entidad | Documento (Firestore) |
| | Filas enormes, dispersas, ordenadas por clave | Wide-column (Bigtable) |
| | Bytes opacos: imágenes, video, backups, logs | Objeto (Cloud Storage) |
| | Rutas de archivo POSIX, montaje compartido | Archivo (Filestore) |
| ¿Cuál es el *patrón de acceso*? | Muchas lecturas/escrituras pequeñas, transaccional | OLTP |
| | Pocos escaneos y agregaciones enormes | OLAP (BigQuery) |
| | Búsquedas sub-milisegundo de valores calientes | Caché (Memorystore) |
| ¿Cuál es el *techo de escala*? | Entra en el crecimiento vertical de una máquina | Cloud SQL / AlloyDB |
| | Debe escalar escrituras horizontalmente, a nivel global | Spanner / Bigtable |
| ¿Cuál es el *contrato operativo*? | El equipo quiere un motor gestionado, el mismo SQL | Cloud SQL |
| | El equipo no quiere planificar capacidad en absoluto | BigQuery, Firestore, Cloud Storage |

### Pasos

1. Tomá estas seis afirmaciones de negocio. Para cada una, anotá (a) forma de los datos, (b) patrón de acceso, (c) techo de escala, (d) el producto que nombrarías, **antes** de leer cualquier otra cosa en este documento:

   - **S1.** "Nuestro sitio WordPress y nuestra app interna de RR. HH. corren ambos MySQL 8 en una VM metida en un armario. Queremos que los backups, el failover y el parcheo dejen de ser mi problema."
   - **S2.** "Vendemos entradas en todo el mundo. A las 09:00 de cada zona horaria, una estampida de escrituras golpea la misma tabla de inventario. Un asiento vendido dos veces es un juicio."
   - **S3.** "Cada uno de nuestros 400.000 aerogeneradores emite 20 métricas por segundo. Los ingenieros consultan 'aerogenerador X, últimas 6 horas'."
   - **S4.** "Nuestra app móvil tiene que funcionar en el subte sin señal y resincronizar el carrito del usuario cuando el tren sale a la superficie."
   - **S5.** "Marketing quiere cruzar cinco años de clickstream con la exportación del CRM y obtener una respuesta durante la reunión. Nadie en marketing sabe dimensionar un clúster."
   - **S6.** "Legales exige que conservemos contratos escaneados durante 10 años. Los vamos a leer prácticamente nunca, pero cuando el auditor pregunte, tenemos 48 horas."

2. Ahora registrá el *descalificador* de cada una — la propiedad de la carga de trabajo que elimina la segunda mejor opción. (Ejemplo para S6: BigQuery queda eliminado no solo por precio sino porque un PDF escaneado son bytes opacos, no filas consultables.)

3. Guardá esta hoja. El ejercicio 9 la califica.

### Control 1

- **P3.** Dos cargas de trabajo dicen ambas "relacional" y "alta disponibilidad". ¿Qué única propiedad separa una respuesta Cloud SQL de una respuesta Spanner?
- **P4.** ¿Por qué "tenemos muchos datos" nunca alcanza para elegir Bigtable sobre BigQuery?
- **P5.** Alguien del negocio dice "necesitamos una base de datos para nuestras imágenes". Reescribí ese requisito correctamente y nombrá el producto.

---

## 2. Almacenamiento de objetos: clases, ciclo de vida y el costo de equivocarse

Cloud Storage es la zona de aterrizaje por defecto para datos no estructurados y el sustrato debajo de casi todo pipeline de analítica. El examen evalúa **clases de almacenamiento** y **ciclo de vida**, porque ahí es donde se gana o se pierde plata.

| Clase | Duración mínima de almacenamiento | Almacenamiento típico $/GB-mes | Cargo por recuperación $/GB | Uso previsto |
|---|---|---|---|---|
| Standard | ninguna | ~0.020 | ninguno | Caliente, en tránsito, assets de sitio web |
| Nearline | 30 días | ~0.010 | ~0.01 | Acceso ≤ una vez por mes |
| Coldline | 90 días | ~0.004 | ~0.02 | Acceso ≤ una vez por trimestre |
| Archive | 365 días | ~0.0012 | ~0.05 | Retención de cumplimiento, DR |

> Las cifras son los precios de lista publicados para `us-central1` al momento de escribir esto; siempre reverificá en [Cloud Storage pricing](https://cloud.google.com/storage/pricing). Lo que el examen espera que sepas es el *ordenamiento* y la *duración mínima*, no los decimales.
> Clases y su semántica: <https://cloud.google.com/storage/docs/storage-classes>

**La trampa que le encanta al examen:** el borrado temprano. Borrá o reescribí un objeto Archive a los 20 días y te siguen facturando 365 días de almacenamiento por él. Una clase "barata" aplicada a datos que rotan es más cara que Standard.

### Pasos

1. Creá un bucket con los valores por defecto modernos (acceso uniforme a nivel de bucket, sin dispersión de ACLs):

```bash
gcloud storage buckets create "gs://cdl-lab-raw-${PROJECT_ID}" \
  --location="$REGION" \
  --default-storage-class=STANDARD \
  --uniform-bucket-level-access
```

Esperado:

```
Creating gs://cdl-lab-raw-cdl-lab-2026/...
```

2. Confirmá qué obtuviste realmente:

```bash
gcloud storage buckets describe "gs://cdl-lab-raw-${PROJECT_ID}" \
  --format="yaml(name,location,locationType,storageClass,iamConfiguration.uniformBucketLevelAccess.enabled)"
```

Esperado:

```yaml
iamConfiguration:
  uniformBucketLevelAccess:
    enabled: true
location: US-CENTRAL1
locationType: region
name: cdl-lab-raw-cdl-lab-2026
storageClass: STANDARD
```

3. Subí un objeto testigo e inspeccioná su clase:

```bash
echo "contract-2026-0001 scanned placeholder" > /tmp/contract.txt
gcloud storage cp /tmp/contract.txt "gs://cdl-lab-raw-${PROJECT_ID}/contracts/2026/contract.txt"
gcloud storage objects describe \
  "gs://cdl-lab-raw-${PROJECT_ID}/contracts/2026/contract.txt" \
  --format="value(storage_class,size,time_created)"
```

Esperado:

```
STANDARD	40	2026-09-06T14:22:11+00:00
```

4. Escribí una política de ciclo de vida que codifique la regla de negocio de retención de **S6** — caliente por un mes, barato por un trimestre, archivado por una década, borrado a los diez años:

```bash
cat > /tmp/lifecycle.json <<'JSON'
{
  "lifecycle": {
    "rule": [
      {
        "action": {"type": "SetStorageClass", "storageClass": "NEARLINE"},
        "condition": {"age": 30, "matchesPrefix": ["contracts/"]}
      },
      {
        "action": {"type": "SetStorageClass", "storageClass": "COLDLINE"},
        "condition": {"age": 90, "matchesPrefix": ["contracts/"]}
      },
      {
        "action": {"type": "SetStorageClass", "storageClass": "ARCHIVE"},
        "condition": {"age": 365, "matchesPrefix": ["contracts/"]}
      },
      {
        "action": {"type": "Delete"},
        "condition": {"age": 3650, "matchesPrefix": ["contracts/"]}
      }
    ]
  }
}
JSON

gcloud storage buckets update "gs://cdl-lab-raw-${PROJECT_ID}" \
  --lifecycle-file=/tmp/lifecycle.json
```

Esperado:

```
Updating gs://cdl-lab-raw-cdl-lab-2026/...
  Completed 1
```

5. Volvé a leer la política — nunca confíes en una escritura que no leíste:

```bash
gcloud storage buckets describe "gs://cdl-lab-raw-${PROJECT_ID}" \
  --format="json(lifecycle_config)" | head -20
```

6. Ahora considerá la *otra* respuesta. Cuando el patrón de acceso es desconocido o errático, la decisión de producto correcta no es un ciclo de vida escrito a mano — es **Autoclass**, que mueve cada objeto entre clases según su propio historial de acceso, sin cargos por borrado temprano derivados de las transiciones en sí:

```bash
gcloud storage buckets create "gs://cdl-lab-auto-${PROJECT_ID}" \
  --location="$REGION" --uniform-bucket-level-access --enable-autoclass

gcloud storage buckets describe "gs://cdl-lab-auto-${PROJECT_ID}" \
  --format="value(autoclass.enabled,autoclass.toggleTime)"
```

Esperado:

```
True	2026-09-06T14:31:02.551000+00:00
```

> Referencia de ciclo de vida: <https://cloud.google.com/storage/docs/lifecycle> · Autoclass: <https://cloud.google.com/storage/docs/autoclass>

7. Desmantelamiento de este ejercicio:

```bash
gcloud storage rm --recursive "gs://cdl-lab-raw-${PROJECT_ID}"
gcloud storage rm --recursive "gs://cdl-lab-auto-${PROJECT_ID}"
```

### Control 2

- **P6.** Un equipo guarda 5 TB de shards de entrenamiento de ML en Archive y relee el conjunto completo en cada corrida de entrenamiento, dos veces por mes. Calculá cualitativamente qué sale mal y nombrá los dos cargos distintos que están disparando.
- **P7.** ¿Cuándo es Autoclass la *mejor respuesta de negocio* frente a la política de ciclo de vida de cuatro reglas que escribiste en el paso 4, y cuándo es la peor?
- **P8.** Una pregunta CDL describe "un recurso compartido NFS on-premises que montan 300 analistas, con permisos POSIX, que debe moverse a Google Cloud sin cambios". ¿Por qué Cloud Storage es la respuesta equivocada, y cuál es la correcta?
- **P9.** Multi-región vs. región dual vs. región para un bucket: ¿cuál quiere un *trabajo de cómputo de baja latencia en una sola región*, y cuál quiere una carga de trabajo de *distribución global de contenido*?

---

## 3. Relacional: Cloud SQL vs. AlloyDB vs. Spanner

Los tres hablan SQL. Difieren en **cómo escalan** y **qué garantizan**, y esa es toda la pregunta del examen.

| | Cloud SQL | AlloyDB for PostgreSQL | Spanner |
|---|---|---|---|
| Motores | MySQL, PostgreSQL, SQL Server | Compatible con PostgreSQL | GoogleSQL + interfaz PostgreSQL |
| Modelo de escalado | Vertical (máquina más grande) + réplicas de lectura | Vertical + read pools; motor columnar para analítica | **Horizontal**, particionado de forma transparente |
| Escrituras | Un único primario | Un único primario | Multi-región, distribuidas globalmente |
| Consistencia | Fuerte dentro de la instancia | Fuerte dentro de la instancia | **Consistencia externa** entre regiones |
| SLA de disponibilidad | 99,95% (config. HA) | 99,99% | 99,99% regional / **99,999%** multi-región |
| ¿Lift-and-shift de una app existente? | Sí, es su razón de ser | Sí, para PostgreSQL exigente | Normalmente requiere trabajo de diseño |
| Frase disparadora típica | "MySQL gestionado", "dejar de parchear" | "Postgres, pero 4× más rápido HTOP + HTAP" | "global", "escala ilimitada", "nunca se cae" |

> <https://cloud.google.com/sql/docs/introduction> · <https://cloud.google.com/alloydb/docs/overview> · <https://cloud.google.com/spanner/docs/overview>

### Pasos

1. Inspeccioná qué significa concretamente "escalado vertical" — listá los niveles de máquina que Cloud SQL te va a vender:

```bash
gcloud sql tiers list --format="table(tier, RAM, Disk, region.list())" | head -15
```

Esperado (abreviado):

```
TIER                 RAM         DISK              REGION
db-f1-micro          644245094   3758096384        us-central1,europe-west1,...
db-g1-small          1becomes... 
db-custom-1-3840     4026531840  10737418240       us-central1,...
db-custom-8-30720    32212254720 10737418240       us-central1,...
```

La lista *termina*. Ese techo es el hecho arquitectónico detrás de "Cloud SQL escala verticalmente".

2. Ahora mirá las unidades de Spanner. Spanner no te vende una máquina; te vende **capacidad de cómputo** en nodos / unidades de procesamiento, y la colocación es una *configuración*, no una zona:

```bash
gcloud spanner instance-configs list \
  --format="table(name.basename(), displayName, replicas.len())" | head -12
```

Esperado (abreviado):

```
NAME                     DISPLAY_NAME                       REPLICAS
regional-us-central1     us-central1                        3
nam3                     United States (northern Virginia/South Carolina)  5
nam-eur-asia1            Global: Americas, Europe, Asia     7
eur6                     Europe (Belgium/Netherlands)       5
```

Leé los conteos de réplicas. **Esa columna es el SLA de 99,999%.** Una configuración multi-región mantiene un quórum síncrono entre regiones; el precio de ese quórum es latencia de commit, y el beneficio es que perder una región no pierde nada.

3. **💸 FACTURABLE (opcional, ~$0.03/hora, borrar dentro de la hora).** Si querés ver existir una instancia relacional HA, creá la más chica:

```bash
gcloud sql instances create cdl-lab-pg \
  --database-version=POSTGRES_16 \
  --tier=db-g1-small \
  --region="$REGION" \
  --availability-type=REGIONAL \
  --storage-auto-increase \
  --backup-start-time=03:00
```

Esperado (tarda 4–8 minutos):

```
Creating Cloud SQL instance for POSTGRES_16...done.
Created [https://sqladmin.googleapis.com/sql/v1beta4/projects/cdl-lab-2026/instances/cdl-lab-pg].
NAME         DATABASE_VERSION  LOCATION       TIER          PRIMARY_ADDRESS  STATUS
cdl-lab-pg   POSTGRES_16       us-central1-a  db-g1-small   34.28.x.x        RUNNABLE
```

4. Verificá que la "disponibilidad regional" es una propiedad real e inspeccionable y no una palabra de marketing:

```bash
gcloud sql instances describe cdl-lab-pg \
  --format="value(settings.availabilityType, gceZone, secondaryGceZone, settings.backupConfiguration.enabled)"
```

Esperado:

```
REGIONAL	us-central1-a	us-central1-c	True
```

Un **standby síncrono en una segunda zona** es lo que compra el SLA de 99,95%. Fijate qué *no* es: no es una segunda región, y no es capacidad de lectura adicional — el standby no atiende tráfico.

5. Desmantelá inmediatamente:

```bash
gcloud sql instances delete cdl-lab-pg --quiet
```

6. Alternativa gratuita a los pasos 3–5 — corré el **emulador de Spanner** y mirá la API del modelo horizontal sin pagar por un nodo:

```bash
gcloud emulators spanner start &
sleep 5
gcloud config configurations create spanner-emu 2>/dev/null || gcloud config configurations activate spanner-emu
gcloud config set auth/disable_credentials true
gcloud config set project "$PROJECT_ID"
gcloud config set api_endpoint_overrides/spanner http://localhost:9020/

gcloud spanner instances create cdl-emu --config=emulator-config \
  --description="CDL lab" --nodes=1
gcloud spanner databases create inventory --instance=cdl-emu \
  --ddl="CREATE TABLE Seats (EventId STRING(36) NOT NULL, SeatId STRING(16) NOT NULL, SoldTo STRING(64)) PRIMARY KEY (EventId, SeatId)"
gcloud spanner databases ddl describe inventory --instance=cdl-emu
```

Esperado:

```
CREATE TABLE Seats (
  EventId STRING(36) NOT NULL,
  SeatId STRING(16) NOT NULL,
  SoldTo STRING(64),
) PRIMARY KEY(EventId, SeatId);
```

Después restaurá tu configuración normal:

```bash
gcloud config configurations activate default
```

> Emulador de Spanner: <https://cloud.google.com/spanner/docs/emulator>

### Control 3

- **P10.** En el paso 4, `availabilityType=REGIONAL` te dio un standby en `us-central1-c`. Alguien del negocio pregunta: "¿entonces sobrevivimos a una caída de región?". Respondé con precisión, y decí qué producto cambia la respuesta.
- **P11.** La empresa de venta de entradas (S2) está actualmente sobre una única instancia grande de PostgreSQL y está llegando a la saturación de escrituras. Ordená las réplicas de lectura de Cloud SQL, AlloyDB y Spanner como respuestas candidatas, e indicá qué hace que cada una sea correcta o incorrecta *específicamente para escrituras*.
- **P12.** Un cliente quiere PostgreSQL, necesita 4× de throughput transaccional y además quiere correr consultas analíticas sobre los mismos datos en vivo sin un ETL a BigQuery. ¿Qué producto, y cuál es la funcionalidad específica que satisface la segunda mitad de la frase?
- **P13.** ¿Por qué "queremos migrar nuestra base Oracle con cambios mínimos de código" *no* lleva a Spanner en una respuesta CDL, y qué dos productos son los candidatos realistas?

---

## 4. No relacional: Firestore, Bigtable, Memorystore

### Pasos

1. **Bigtable** — el modelo es un mapa ordenado, disperso y de columnas anchas. La clave de fila *es* el plan de consulta. Arrancá el emulador y construí la tabla de telemetría de aerogeneradores de **S3**:

```bash
gcloud beta emulators bigtable start --host-port=localhost:8086 &
sleep 3
export BIGTABLE_EMULATOR_HOST=localhost:8086

cbt -project "$PROJECT_ID" -instance cdl-emu createtable telemetry families=metrics
cbt -project "$PROJECT_ID" -instance cdl-emu ls
```

Esperado:

```
telemetry
```

2. Escribí dos filas usando una clave con **timestamp invertido y prefijo de entidad** — el diseño canónico de series temporales — y leé de vuelta un rango:

```bash
cbt -project "$PROJECT_ID" -instance cdl-emu set telemetry \
  "turbine-000042#20260906T140000" metrics:rpm=17.4 metrics:temp_c=41.2
cbt -project "$PROJECT_ID" -instance cdl-emu set telemetry \
  "turbine-000042#20260906T140001" metrics:rpm=17.6 metrics:temp_c=41.3

cbt -project "$PROJECT_ID" -instance cdl-emu read telemetry \
  prefix="turbine-000042#202609061400"
```

Esperado:

```
----------------------------------------
turbine-000042#20260906T140000
  metrics:rpm                              @ 2026/09/06-14:03:11.000000
    "17.4"
  metrics:temp_c                           @ 2026/09/06-14:03:11.000000
    "41.2"
----------------------------------------
turbine-000042#20260906T140001
  metrics:rpm                              @ 2026/09/06-14:03:11.000000
    "17.6"
...
```

Fijate qué **no** hiciste: ningún `JOIN`, ningún índice secundario, ninguna agregación. Pediste un rango contiguo de claves. Ese es todo el modelo de acceso de Bigtable, y es la razón por la que Bigtable es correcto para S3 e incorrecto para los cruces ad-hoc de marketing (S5).

3. Desactivá la variable del emulador para que los pasos posteriores no le peguen en silencio:

```bash
unset BIGTABLE_EMULATOR_HOST
```

4. **Firestore** — modelo de documentos, documentos por usuario, y la propiedad que decide S4: **persistencia offline con sincronización automática**. Inspeccioná los dos modos:

```bash
gcloud firestore databases list --format="table(name.basename(), type, locationId, concurrencyMode)" 2>/dev/null \
  || echo "No Firestore database provisioned in this project"
```

Esperado, una vez que exista una:

```
NAME       TYPE                LOCATION_ID   CONCURRENCY_MODE
(default)  FIRESTORE_NATIVE    nam5          PESSIMISTIC
```

`FIRESTORE_NATIVE` es el modo que ofrece SDKs móviles/web, listeners en tiempo real y caché offline; `DATASTORE_MODE` es el modo del lado servidor, heredado de App Engine, sin esas capacidades. Para S4, solo el modo Native responde al requisito.

> <https://cloud.google.com/firestore/docs> · comparación de modos: <https://cloud.google.com/datastore/docs/firestore-or-datastore>

5. **Memorystore** — no es un sistema de registro. Es un Redis/Valkey/Memcached gestionado delante de uno. Inspeccioná qué vende el servicio:

```bash
gcloud redis regions list --format="value(locationId)" | head -5
gcloud redis instances list --region="$REGION" --format="table(name, tier, memorySizeGb, state)"
```

Esperado (una lista vacía es la salida correcta si no aprovisionaste nada):

```
us-central1
us-east1
...
Listed 0 items.
```

El dato relevante para el examen: el tier `BASIC` **no tiene réplica ni failover** — un caché cuya pérdida es aceptable; `STANDARD_HA` agrega una réplica y failover automático. Elegir `BASIC` para estado de sesión que debe sobrevivir es un error de diseño.

> <https://cloud.google.com/memorystore/docs/redis/redis-tiers>

### Control 4

- **P14.** Reescribí la clave de fila de S3 `turbine-000042#20260906T140000` como `20260906T140000#turbine-000042` y explicá, en términos operativos, qué le pasa a una flota de escritores a las 14:00:01.
- **P15.** Un equipo propone Bigtable para almacenar 400 GB de datos de catálogo de productos que la tienda web consulta por cualquiera de 12 atributos. Rechazá la propuesta en una oración y nombrá un producto mejor.
- **P16.** Firestore Native vs. modo Datastore: ¿qué único requisito de negocio en S4 vuelve la elección innegociable?
- **P17.** Un comercio pone el carrito de compras en Memorystore `BASIC` para reducir la carga de Cloud SQL. Describí el incidente de negocio que sigue a un evento de mantenimiento de nodo, y el arreglo de dos palabras.

---

## 5. Analítica: BigQuery y la economía de un escaneo

BigQuery es serverless, columnar y separa el almacenamiento del cómputo. Para CDL importan tres consecuencias: **nadie dimensiona un clúster**, **pagás por bytes escaneados (on-demand) o por slots reservados (editions)**, y **el diseño del esquema cambia la factura en órdenes de magnitud**.

> <https://cloud.google.com/bigquery/docs/introduction> · <https://cloud.google.com/bigquery/pricing>

### Pasos

1. Consultá un dataset público con **cero configuración** — esta es la afirmación de "no hay clúster que dimensionar", hecha concreta:

```bash
bq query --use_legacy_sql=false --max_rows=5 \
'SELECT starttime, tripduration, start_station_name
 FROM `bigquery-public-data.new_york_citibike.citibike_trips`
 WHERE tripduration IS NOT NULL
 ORDER BY starttime DESC
 LIMIT 5'
```

Esperado:

```
+---------------------+--------------+--------------------------------+
|      starttime      | tripduration |       start_station_name       |
+---------------------+--------------+--------------------------------+
| 2018-05-31 23:59:56 |          301 | E 33 St & 1 Ave                |
| ...                                                                 |
+---------------------+--------------+--------------------------------+
```

2. Ahora la parte que al examen realmente le importa. **Estimá el costo antes de gastarlo** con `--dry_run`:

```bash
bq query --use_legacy_sql=false --dry_run \
'SELECT COUNT(*) FROM `bigquery-public-data.new_york_citibike.citibike_trips`'
```

Esperado:

```
Query successfully validated. Assuming the tables are not modified, running this
query will process 0 bytes of data.
```

Después compará contra una consulta que toque columnas reales:

```bash
bq query --use_legacy_sql=false --dry_run \
'SELECT start_station_name, AVG(tripduration)
 FROM `bigquery-public-data.new_york_citibike.citibike_trips`
 GROUP BY start_station_name'
```

Esperado (tu cifra va a diferir):

```
Query successfully validated. Assuming the tables are not modified, running this
query will process 1246953984 bytes of data.
```

3. **Almacenamiento columnar, demostrado.** Agregá una columna más a la misma consulta y volvé a correr el dry run:

```bash
bq query --use_legacy_sql=false --dry_run \
'SELECT start_station_name, usertype, AVG(tripduration)
 FROM `bigquery-public-data.new_york_citibike.citibike_trips`
 GROUP BY start_station_name, usertype'
```

El conteo de bytes sube aproximadamente el tamaño de una columna. En un almacenamiento por filas no se habría movido. `SELECT *` no es, por lo tanto, una preferencia de estilo en BigQuery — es un ítem en la factura.

4. **Particionado, demostrado.** Las tablas públicas particionadas suelen *exigir* un filtro de partición, precisamente para frenar el accidente que estás por ver:

```bash
bq query --use_legacy_sql=false --dry_run \
'SELECT SUM(views) FROM `bigquery-public-data.wikipedia.pageviews_2021`'
```

Esperado — esto es la barrera de protección actuando, no una falla tuya:

```
Error in query string: Cannot query over table
'bigquery-public-data.wikipedia.pageviews_2021' without a filter over column(s)
'datehour' that can be used for partition elimination
```

Ahora proveé el filtro:

```bash
bq query --use_legacy_sql=false --dry_run \
'SELECT SUM(views) FROM `bigquery-public-data.wikipedia.pageviews_2021`
 WHERE datehour BETWEEN "2021-03-01" AND "2021-03-02"'
```

Esperado: un conteo de bytes varios órdenes de magnitud menor que la tabla completa.

5. Convertí bytes en dinero. El precio on-demand se factura por TiB escaneado (precio de lista ≈ **$6.25/TiB** en regiones de EE. UU., con el primer 1 TiB por mes gratis — reverificá en la página de precios):

```bash
BYTES=1246953984
python3 -c "b=$BYTES; print(f'{b/2**40:.6f} TiB  ->  \${b/2**40*6.25:.4f}')"
```

Esperado:

```
0.001134 TiB  ->  $0.0071
```

6. Inspeccioná los metadatos de la tabla para ver almacenamiento y conteo de filas sin escanear nada:

```bash
bq show --format=prettyjson \
  bigquery-public-data:new_york_citibike.citibike_trips \
  | grep -E '"numBytes"|"numRows"|"type"'
```

Esperado:

```
  "numBytes": "7217426947",
  "numRows": "58937715",
  "type": "TABLE"
```

7. Entendé el segundo modelo de precios, porque el examen los contrasta. **On-demand** = pagás por byte escaneado, sin compromiso, total mensual impredecible. **BigQuery editions** (Standard / Enterprise / Enterprise Plus) = comprás **slots** (capacidad de cómputo) con autoescalado y compromisos opcionales, lo que da una factura predecible y aislamiento de cargas de trabajo. Listá cualquier reserva en el proyecto:

```bash
bq ls --reservation --location="US" --project_id="$PROJECT_ID" 2>&1 | head -5
```

Esperado en un proyecto nuevo:

```
No reservations found.
```

> <https://cloud.google.com/bigquery/docs/reservations-intro>

### Control 5

- **P18.** Marketing (S5) corre 40 consultas exploratorias por día, cada una escaneando 2 TiB, y el CFO quiere un número mensual predecible. ¿On-demand o editions? Justificá con el mecanismo, no con el precio.
- **P19.** Un equipo reporta "BigQuery se puso caro después de que agregamos la columna con el payload JSON crudo". Explicá la cadena causal en términos de almacenamiento columnar, y dá dos mitigaciones.
- **P20.** En el paso 2, `SELECT COUNT(*)` procesó **0 bytes**. ¿Qué revela eso sobre la arquitectura de BigQuery, y por qué es un mal benchmark de "BigQuery es barato"?
- **P21.** La empresa ya mantiene 300 TB de Parquet en Cloud Storage y no quiere cargarlos en el almacenamiento de BigQuery. Nombrá la capacidad que permite a BigQuery consultarlos en su lugar, e indicá el compromiso.

---

## 6. Cómo entran los datos: Pub/Sub, Dataflow, Dataproc, Datastream, Data Fusion, Composer

Una decisión de producto acá es una decisión sobre **quién escribe el código** y **con qué forma llegan los datos**.

| Necesidad | Producto | Rasgo decisivo |
|---|---|---|
| Desacoplar productores de consumidores; absorber picos | **Pub/Sub** | Mensajería global, serverless; entrega at-least-once, retención |
| Un solo pipeline para streaming y batch, autoescalado | **Dataflow** | Apache Beam gestionado; batch+stream unificado, sin clúster |
| Ya tenemos jobs Spark/Hadoop y habilidades Spark | **Dataproc** | Spark/Hadoop gestionado; lift-and-shift de jobs existentes |
| Replicar una base OLTP viva a BigQuery de forma continua | **Datastream** | CDC (change data capture) serverless, bajo impacto en el origen |
| Los analistas deben construir ETL sin escribir código | **Cloud Data Fusion** | Constructor gráfico de pipelines (CDAP) |
| Orquestar un DAG de jobs interdependientes con planificación | **Cloud Composer** | Apache Airflow gestionado |
| Consultar archivos en Cloud Storage como si fueran tablas | **BigLake / tablas externas** | El almacenamiento se queda donde está, un único modelo de gobernanza |
| Catalogar, clasificar y gobernar datos en todo el patrimonio | **Dataplex** | Metadatos unificados, calidad de datos, linaje |

> <https://cloud.google.com/pubsub/docs/overview> · <https://cloud.google.com/dataflow/docs> · <https://cloud.google.com/dataproc/docs> · <https://cloud.google.com/datastream/docs/overview> · <https://cloud.google.com/data-fusion/docs> · <https://cloud.google.com/composer/docs> · <https://cloud.google.com/dataplex/docs>

### Pasos

1. Construí la capa de desacoplamiento para la flota de aerogeneradores — esto es gratis al volumen del laboratorio:

```bash
gcloud pubsub topics create turbine-telemetry
gcloud pubsub subscriptions create turbine-telemetry-archive \
  --topic=turbine-telemetry \
  --message-retention-duration=7d \
  --ack-deadline=30
```

Esperado:

```
Created topic [projects/cdl-lab-2026/topics/turbine-telemetry].
Created subscription [projects/cdl-lab-2026/subscriptions/turbine-telemetry-archive].
```

2. Publicá y consumí, para ver la semántica de buffering con tus propios ojos:

```bash
gcloud pubsub topics publish turbine-telemetry \
  --message='{"turbine":"000042","rpm":17.4,"temp_c":41.2}' \
  --attribute=site=patagonia-3

gcloud pubsub subscriptions pull turbine-telemetry-archive --auto-ack --limit=1 \
  --format="table(message.data.decode(base64), message.attributes)"
```

Esperado:

```
DATA                                                  ATTRIBUTES
{"turbine":"000042","rpm":17.4,"temp_c":41.2}         {'site': 'patagonia-3'}
```

3. Observá la propiedad que hace de Pub/Sub el amortiguador. Revisá la métrica de backlog sobre la que alertan los equipos de operaciones:

```bash
gcloud pubsub subscriptions describe turbine-telemetry-archive \
  --format="value(messageRetentionDuration, ackDeadlineSeconds, expirationPolicy.ttl)"
```

Esperado:

```
604800s	30	2678400s
```

Siete días de retención es la respuesta de negocio a "¿qué pasa si el pipeline de analítica está caído todo un fin de semana?" — no se pierde nada, el backlog se drena después.

4. Inspeccioná el catálogo de plantillas de Dataflow provistas por Google. El punto relevante para el examen es que el camino de streaming de referencia (Pub/Sub → BigQuery) no requiere **nada de código**:

```bash
gcloud dataflow jobs list --region="$REGION" --format="table(name,type,state)" 2>/dev/null
gcloud storage ls gs://dataflow-templates-"$REGION"/latest/ | grep -i -E "PubSub_to_BigQuery|GCS_Text_to_BigQuery" 
```

Esperado:

```
gs://dataflow-templates-us-central1/latest/PubSub_to_BigQuery
gs://dataflow-templates-us-central1/latest/GCS_Text_to_BigQuery
```

5. Desmantelamiento:

```bash
gcloud pubsub subscriptions delete turbine-telemetry-archive --quiet
gcloud pubsub topics delete turbine-telemetry --quiet
```

### Control 6

- **P22.** El ETL nocturno existente de un comercio son 4.000 líneas de PySpark mantenidas por un equipo de ingenieros Spark. El mandato es "migrar a la nube en un trimestre". ¿Dataflow o Dataproc? Dá la razón de negocio, y después nombrá la condición bajo la cual la otra respuesta pasa a ser la correcta.
- **P23.** El equipo de finanzas necesita sus datos operativos de Cloud SQL for PostgreSQL disponibles en BigQuery en cuestión de minutos, y el DBA se niega a cualquier cosa que agregue carga al primario. Nombrá el producto y la técnica que usa.
- **P24.** ¿Por qué Pub/Sub, y no Dataflow, es la respuesta a "nuestra API de ingesta se cae durante las ventas flash"?
- **P25.** Una empresa tiene 60 fuentes de datos, tres unidades de negocio, y nadie puede decir qué tablas contienen datos personales. Nombrá el producto para el problema de catálogo/gobernanza, y el producto *separado* para encontrar los datos personales en sí.

---

## 7. Migración: la aritmética de ancho de banda que elige el producto

El examen te da un volumen de datos, una ventana de tiempo y a veces una velocidad de enlace. Hay un cálculo detrás de la respuesta "correcta".

| Situación | Producto |
|---|---|
| Datos ya en otra nube o en un bucket/endpoint HTTP on-prem, red adecuada | **Storage Transfer Service** |
| Volumen demasiado grande para el enlace disponible, o sin enlace usable | **Transfer Appliance** (TA40 ≈ 40 TB, TA300 ≈ 300 TB utilizables) |
| Base de datos viva → base gestionada, downtime mínimo | **Database Migration Service** |
| Replicación continua de cambios hacia analítica | **Datastream** |
| Acceso híbrido continuo a archivos | **Filestore** / **Storage Transfer Service for on-prem** |

> <https://cloud.google.com/storage-transfer/docs/overview> · <https://cloud.google.com/transfer-appliance/docs> · <https://cloud.google.com/database-migration/docs>

### Pasos

1. Hacé la aritmética vos mismo. Guardá este helper:

```bash
cat > /tmp/transfer_time.py <<'PY'
import sys
tb, mbps = float(sys.argv[1]), float(sys.argv[2])
bytes_total = tb * 10**12
bytes_per_sec = mbps * 10**6 / 8
days = bytes_total / bytes_per_sec / 86400
print(f"{tb:g} TB over {mbps:g} Mbps (100% utilised) = {days:.1f} days")
print(f"realistic at 70% utilisation           = {days/0.7:.1f} days")
PY
```

2. Corré los tres casos que el examen repite:

```bash
python3 /tmp/transfer_time.py 10 100
python3 /tmp/transfer_time.py 100 1000
python3 /tmp/transfer_time.py 500 100
```

Esperado:

```
10 TB over 100 Mbps (100% utilised) = 9.3 days
realistic at 70% utilisation           = 13.2 days

100 TB over 1000 Mbps (100% utilised) = 9.3 days
realistic at 70% utilisation           = 13.2 days

500 TB over 100 Mbps (100% utilised) = 463.0 days
realistic at 70% utilisation           = 661.4 days
```

La tercera línea es la pregunta de Transfer Appliance del examen. Cuando la estimación honesta supera la fecha límite del negocio — y, críticamente, cuando saturar el enlace dejaría sin recursos al negocio en producción — la respuesta es el envío físico.

3. Creá una descripción (gratuita de definir) de un job de Storage Transfer Service para el caso en que la red *sí* es adecuada. Listá primero el inventario de jobs del servicio:

```bash
gcloud transfer jobs list --format="table(name.basename(), status, transferSpec.gcsDataSink.bucketName)" 2>&1 | head -5
```

Esperado en un proyecto nuevo:

```
Listed 0 items.
```

4. Leé la decisión de DMS, sin aprovisionarlo. DMS realiza un volcado completo inicial más **replicación continua**, y hacés el cutover cuando el retraso de replicación está cerca de cero — eso es lo que significa concretamente "migración con downtime mínimo":

```bash
gcloud database-migration connection-profiles list --region="$REGION" \
  --format="table(name.basename(), provider, state)" 2>&1 | head -5
```

Esperado:

```
Listed 0 items.
```

### Control 7

- **P26.** Una empresa de medios debe mover 900 TB de metraje de archivo; su enlace a internet es de 500 Mbps y es también el enlace que usan sus 400 empleados. Calculá el tiempo de transferencia ingenuo, y después dá la recomendación *y* la razón de segundo orden que la aritmética por sí sola no captura.
- **P27.** Un banco migra una base MySQL de 2 TB y puede permitirse 15 minutos de downtime. ¿Qué producto, y cuál es la *secuencia* de eventos en el cutover?
- **P28.** ¿Cuál es la diferencia de intención entre Storage Transfer Service y Datastream, dado que ambos "mueven datos de forma continua"?

---

## 8. Trabajo final: mapear ocho afirmaciones de negocio a productos

### Pasos

1. Para cada afirmación, escribí **un producto** (o una cadena mínima, p. ej. `Pub/Sub → Dataflow → BigQuery`) más **una oración** que nombre la propiedad decisiva.

   - **C1.** "Una tabla de posiciones global de un juego: 50 M de jugadores, escrituras desde todos los continentes, nunca debe mostrar un ranking desactualizado ni perder un puntaje."
   - **C2.** "Diez años de imágenes de resonancia magnética, abiertas solo durante litigios, recuperadas dentro del día."
   - **C3.** "La app Java heredada de un hospital sobre SQL Server 2019 debe salir del datacenter este año; el proveedor no va a cambiar una sola línea de código."
   - **C4.** "Ad-tech: 4 millones de eventos/segundo de logs de impresiones, consultados por `advertiser_id` y rango temporal para pujas en tiempo real."
   - **C5.** "Un equipo de BI de retail quiere una única definición gobernada de 'ingreso neto' que lean Sheets, Looker Studio y un bot de Slack."
   - **C6.** "Estado de sesión para una flota web: lecturas de microsegundos, reconstruible desde la base de datos si se pierde."
   - **C7.** "Una startup de logística necesita una app móvil donde los conductores actualicen el estado de entrega en túneles y se sincronice cuando salen."
   - **C8.** "Cumplimiento exige que descubramos y enmascaremos números de tarjeta de crédito escritos accidentalmente en las exportaciones de tickets de soporte antes de que los vean los analistas."

2. Para cada una, escribí también la **respuesta incorrecta más fuerte** y la oración que la elimina. Si no podés nombrar una respuesta incorrecta plausible, no entendiste el compromiso.

3. Volvé a tu hoja del ejercicio 1 (S1–S6) y calificala contra la clave de respuestas.

### Control 8

- **P29.** A lo largo de C1–C8, ¿cuáles dos afirmaciones cambiarían de producto si agregaras la restricción "el equipo no tiene ingenieros de datos ni presupuesto para planificación de capacidad"? Explicá.
- **P30.** Escribí la justificación de un párrafo que le darías a un CFO no técnico para elegir Spanner sobre Cloud SQL en C1, usando el costo del fallo en lugar de listas de funcionalidades.

---

<details>
<summary><strong>Clave de respuestas — abrir solo después de escribir tus propias respuestas</strong></summary>

### Control 0

**P1.** Te dice que **habilitar y listar APIs no cuesta nada** — Google Cloud factura por recursos aprovisionados y operaciones consumidas, no por la disponibilidad de un servicio en el catálogo. *No* te dice que tengas permiso para usarlos (Organization Policy o IAM pueden bloquear el aprovisionamiento), ni que tu proyecto tenga cuota, ni que algo esté corriendo. `--available` es un listado de catálogo; `gcloud services list --enabled` es lo que está encendido en este proyecto.

**P2.** Porque el modelo mental de alguien de finanzas ante "encendimos Spanner" es "empezamos a pagar Spanner". Habilitar una API no genera ningún cargo; una instancia de Spanner con un nodo en configuración multi-región es un compromiso mensual de cuatro cifras desde el momento en que existe. El rol de CDL es precisamente mantener esos dos hechos separados en la conversación — y señalar que el control de costos significativo no es "no habilites APIs" sino presupuestos, cuotas, restricciones de Organization Policy sobre ubicación/tamaño de recursos, y etiquetas para atribución de costos.

### Control 1

**P3.** **Si las escrituras deben escalar horizontalmente más allá de un primario, o si los datos deben ser fuertemente consistentes entre regiones.** Cloud SQL (y AlloyDB) tiene exactamente un primario de escritura; lo escalás agrandando la máquina y agregando réplicas de lectura. Spanner particiona las escrituras entre nodos y mantiene consistencia externa entre regiones. "Alta disponibilidad" a secas lo satisface la HA regional de Cloud SQL; "escrituras globalmente consistentes a escala no acotada" no.

**P4.** Porque el volumen no es un patrón de acceso. Bigtable se elige cuando las consultas son **búsquedas por rango de clave con baja latencia y muy alto throughput de escritura** — una entidad conocida, una porción de tiempo. BigQuery se elige cuando las consultas son **escaneos ad-hoc, joins y agregaciones sobre todo el corpus**. Un petabyte consultado por analistas con SQL arbitrario es BigQuery; un terabyte machacado por un motor de pujas a 4 M de escrituras/segundo sobre una clave conocida es Bigtable. Muchas arquitecturas usan ambos: Bigtable para el camino de servicio, BigQuery para el camino analítico.

**P5.** "Necesitamos almacenamiento durable, barato y escalable para *archivos* de imagen, con metadatos sobre esas imágenes guardados en algún lugar consultable." Las imágenes van a **Cloud Storage**; los metadatos (dueño, etiquetas, dimensiones, URI de almacenamiento) van a una base de datos — Firestore o Cloud SQL según el patrón de consulta. Guardar blobs binarios en una base relacional es el antipatrón que se está evaluando.

### Control 2

**P6.** Dos cargos distintos, ambos evitables:
1. **Cargos por recuperación.** La recuperación desde Archive es ~$0.05/GB. 5 TB × 2 por mes ≈ 10.000 GB × $0.05 = **~$500/mes solo en recuperación**, contra un ahorro de almacenamiento de aproximadamente (0.020 − 0.0012) × 5.000 ≈ $94/mes. La clase "barata" les cuesta ~5× lo que costaría Standard.
2. **Cargos por borrado temprano**, si los shards de entrenamiento se reescriben o reemplazan antes de los 365 días: cada objeto se sigue facturando por el resto de su mínimo de 365 días.
La regla: las clases frías son para datos que *almacenás* seguido y *leés* poco. La frecuencia de lectura, no el tamaño, elige la clase.

**P7.** Autoclass es mejor cuando el patrón de acceso es **desconocido, por objeto o cambiante** — un data lake donde algunos objetos se enfrían en una semana y otros siguen calientes por un año, y ningún humano puede escribir una regla de edad correcta. Elimina el riesgo de penalización por borrado temprano derivado de las transiciones y la falla del tipo "pusimos Coldline y después tuvimos que releer todo". Es peor cuando el patrón es **conocido y determinista** (retención regulatoria, como en el paso 4) — ahí una regla explícita de ciclo de vida llega a la clase más barata de inmediato y de forma predecible, mientras que Autoclass cobra una pequeña tarifa de gestión por objeto y solo degrada tras un período de inactividad observado. Regla conocida → ciclo de vida. Comportamiento desconocido → Autoclass.

**P8.** Cloud Storage es un **almacén de objetos**: espacio de nombres plano, sin semántica POSIX, sin bloqueo de archivos, sin escrituras parciales in situ, sin un `mount` que se comporte como NFS (Cloud Storage FUSE lo aproxima pero no provee garantías POSIX ni el perfil de rendimiento). El requisito dice "montar, permisos POSIX, sin cambios". La respuesta es **Filestore** — NFS gestionado. Ver <https://cloud.google.com/filestore/docs/overview>.

**P9.** Un trabajo de cómputo de una sola región quiere un bucket **regional** en la *misma región que el cómputo*: menor latencia, mayor throughput, sin egreso entre regiones. La distribución global de contenido quiere **multi-región** (máxima disponibilidad, datos servidos desde la huella continental, típicamente detrás de Cloud CDN). **Región dual** es el caso intermedio: dos regiones nombradas con latencia baja predecible hacia ambas, elegida cuando necesitás rendimiento regional *y* redundancia geográfica para DR — la respuesta habitual a "tenemos que sobrevivir a la pérdida de una región pero nuestro cómputo está en una de ellas".

### Control 3

**P10.** No. La disponibilidad `REGIONAL` significa un **standby síncrono en una segunda zona de la misma región**; sobrevive a una falla de zona con failover automático, no a una falla de región. Sobrevivir a una falla de región con Cloud SQL requiere una **réplica de lectura entre regiones** que promovés manualmente (un RPO/RTO medido en minutos, con posible pérdida de datos porque la replicación es asíncrona). El producto que cambia la respuesta a "sí, automáticamente, sin pérdida de datos" es **Spanner en una configuración multi-región**, donde el quórum síncrono abarca regiones — las configuraciones `nam3`/`nam-eur-asia1` que listaste en el paso 2.

**P11.**
- **Réplicas de lectura de Cloud SQL — incorrecto.** Las réplicas atienden lecturas. La saturación planteada es de *escrituras*; agregar réplicas suma carga de replicación al primario y no resuelve nada.
- **AlloyDB — correcto si el volumen de escritura entra en un primario.** Eleva materialmente el techo (un primario más rápido, mejor camino de escritura, read pools que descargan el reporting) manteniéndose compatible con PostgreSQL, así que la aplicación cambia poco. Este es el primer movimiento correcto si la curva de crecimiento es 2–5×, no 100×.
- **Spanner — correcto si las escrituras deben escalar sin techo, o deben ser globalmente consistentes.** La estampida de S2 es exactamente ese perfil: escrituras concurrentes a filas calientes de inventario desde todas las regiones, y un requisito de corrección ("un asiento vendido dos veces es un juicio") que exige consistencia externa. El costo es el esfuerzo de migración y el diseño de esquema (interleaving, evitar hotspots).
El desempate del examen suele ser la frase "global" o "escala ilimitada".

**P12.** **AlloyDB for PostgreSQL.** La segunda mitad — analítica sobre datos transaccionales en vivo sin ETL — la satisface su **motor columnar**, que mantiene una representación columnar de los datos calientes en memoria junto al almacén por filas, de modo que las consultas analíticas corren contra la base operativa (HTAP). Ver <https://cloud.google.com/alloydb/docs/columnar-engine/about>.

**P13.** Porque Spanner no es compatible con Oracle; migrar a él es una **re-arquitectura**, lo que contradice "cambios mínimos de código". Los candidatos realistas son **Cloud SQL for SQL Server / PostgreSQL** o **Bare Metal Solution for Oracle** (correr el propio Oracle sobre hardware dedicado adyacente a Google Cloud) cuando la licencia y el código deben quedar intactos; si algo de conversión es aceptable, **DMS con conversión Oracle→PostgreSQL** hacia Cloud SQL o AlloyDB. Ver <https://cloud.google.com/bare-metal/docs> y <https://cloud.google.com/database-migration/docs/oracle-to-postgresql>.

### Control 4

**P14.** Creás un **hotspot**. Bigtable guarda las filas en orden lexicográfico de clave y divide ese espacio de claves en tablets contiguos servidos por nodos individuales. Con el timestamp primero, todos los escritores de la flota a las 14:00:01 producen claves que comparten el mismo prefijo, así que las 400.000 escrituras por segundo caen todas en un tablet sobre **un solo nodo**, mientras el resto del clúster está ocioso. El throughput colapsa al throughput de un nodo y la latencia se dispara. Poner primero el identificador de entidad distribuye las escrituras por el espacio de claves; el timestamp al final te sigue dando escaneos baratos por rango temporal con `prefix=turbine-X`. Esta es la regla de diseño más importante de Bigtable: <https://cloud.google.com/bigtable/docs/schema-design>.

**P15.** Bigtable no tiene camino de consulta eficiente más allá de la clave de fila (y prefijos/rangos de clave de fila), así que atender 12 filtros arbitrarios por atributo requeriría 12 copias desnormalizadas de la tabla — usá **Firestore** (indexación automática sobre campos de documento, ideal para un catálogo de este tamaño), o Cloud SQL si el catálogo es genuinamente relacional y hacen falta joins.

**P16.** "Tiene que funcionar en el subte sin señal y resincronizar cuando el tren sale a la superficie." La **persistencia offline con sincronización automática con resolución de conflictos y listeners en tiempo real** existe solo en el **modo Native** de Firestore, vía los SDKs cliente móviles/web. El modo Datastore es una API del lado servidor sin SDKs cliente y sin soporte offline.

**P17.** Memorystore `BASIC` tiene un único nodo y **ninguna réplica ni failover automático**; un evento de mantenimiento o una falla de nodo significa que la instancia reinicia vacía. Todos los carritos de todos los clientes se pierden a mitad de sesión y al mismo tiempo — carritos abandonados, llamadas a soporte, pérdida directa de ingresos. Peor: el carrito se estaba usando como *sistema de registro*, no como caché, así que no hay nada desde donde reconstruirlo. El arreglo de dos palabras es **`STANDARD_HA`** (réplica + failover automático); el arreglo arquitectónico es mantener el carrito durable en una base de datos y tratar a Memorystore como caché delante de ella. Ver <https://cloud.google.com/memorystore/docs/redis/redis-tiers>.

### Control 5

**P18.** **Editions con un compromiso de slots (Enterprise, más autoescalado).** El mecanismo: on-demand factura por byte escaneado, así que el total mensual es una función del comportamiento de los analistas — un equipo exploratorio que descubre `SELECT *` puede multiplicar la factura sin ningún cambio en el valor de negocio, y el CFO no puede pronosticarlo. Editions factura por **capacidad (slots) a lo largo del tiempo**; un compromiso base más un techo de autoescalado convierte un costo variable no acotado en uno acotado, y agrega aislamiento de cargas de trabajo para que la exploración de marketing no pueda demorar el cierre de finanzas. El control secundario, válido en cualquiera de los dos modelos, son las **cuotas personalizadas** sobre bytes facturados por usuario/proyecto.

**P19.** BigQuery almacena cada columna por separado, y te factura por los bytes de las **columnas que tu consulta toca**. Una columna con payload JSON crudo es grande, poco comprimible y — críticamente — la arrastra todo `SELECT *`, así que consultas que nunca la necesitaron ahora la escanean. Mitigaciones: (1) dejar de usar `SELECT *`; seleccionar columnas nombradas. (2) Mover el payload crudo a una tabla separada (o a Cloud Storage con una tabla externa/BigLake) que se une solo cuando hace falta. (3) Parsear el JSON en columnas tipadas en la ingesta, o usar el tipo nativo `JSON` para que BigQuery pueda podar subcampos. (4) Agregar **particionado** (normalmente por fecha de ingesta) y **clustering** sobre las columnas de filtro habituales, y considerar `require_partition_filter = true`. (5) Pasar a editions si la carga es estable, para que el volumen escaneado deje de ser la unidad de facturación.

**P20.** `COUNT(*)` se responde desde los **metadatos de la tabla**, no desde los datos: BigQuery mantiene los conteos de filas en su metastore, así que no se leen columnas ni se facturan bytes. Revela la separación entre almacenamiento y metadatos — y es un mal benchmark precisamente porque no ejercita nada del camino de escaneo. Cualquier afirmación de costo o rendimiento debe hacerse con una consulta que lea columnas reales. (La misma precaución aplica a los resultados de consulta cacheados, que también son gratis y pueden hacer que una consulta repetida parezca imposiblemente barata.)

**P21.** **Tablas BigLake** (o tablas externas comunes) — BigQuery consulta el Parquet en su lugar, en Cloud Storage. Compromisos: el rendimiento de consulta es en general menor que con el almacenamiento nativo de BigQuery (sin clustering sobre el layout de almacenamiento nativo, lecturas remotas, y el modelo de costo se corre hacia los bytes de objeto escaneados), y algunas funcionalidades se comportan distinto. La ganancia es que no hay movimiento de datos, no hay copia duplicada, otros motores (Spark, Trino) pueden seguir leyendo los archivos, y BigLake agrega control de acceso de grano fino y un modelo único de gobernanza sobre el lake. Ver <https://cloud.google.com/bigquery/docs/biglake-intro>.

### Control 6

**P22.** **Dataproc.** La razón de negocio es el time-to-value y el riesgo: Dataproc corre su PySpark existente esencialmente sin cambios sobre clústeres gestionados, así que un plazo de un trimestre es alcanzable y las habilidades del equipo siguen valiendo. Dataflow exigiría reescribir 4.000 líneas a Apache Beam — una reescritura con su propio riesgo de defectos, contra una fecha límite. La condición que da vuelta la respuesta: si el mandato *no* es un lift-and-shift dictado por un plazo sino una migración a largo plazo hacia serverless sin gestión de clústeres, o si la carga pasa a ser **streaming**, entonces **Dataflow** es lo correcto — es batch+stream unificado y autoescala sin dimensionar clústeres, mientras que Dataproc sigue implicando pensar en clústeres (incluso con autoescalado y Spark serverless).

**P23.** **Datastream**, usando **change data capture (CDC)** — lee el log de replicación de la base de datos (decodificación lógica de PostgreSQL / binlog de MySQL / redo de Oracle) en lugar de consultar tablas, así que la carga sobre el primario es mínima y ningún escaneo `SELECT` compite con el tráfico de producción. El patrón estándar es Datastream → BigQuery (un destino integrado) para replicación casi en tiempo real. Ver <https://cloud.google.com/datastream/docs/overview>.

**P24.** Porque la falla es un **desajuste de tasa**, no un problema de transformación. Pub/Sub desacopla a los productores de los consumidores y absorbe el pico en un buffer durable y retenido; los consumidores lo drenan al ritmo que puedan sostener, y no se descarta nada. Dataflow es una capa de *procesamiento* — puede autoescalar, pero si es la puerta de entrada sigue acoplado a la tasa del productor y a sus propios destinos aguas abajo. La arquitectura idiomática es Pub/Sub como amortiguador, Dataflow como consumidor.

**P25.** Gobernanza/catálogo: **Dataplex** (metadatos unificados, catálogo de datos, calidad de datos y linaje sobre BigQuery, Cloud Storage y más) — y es Dataplex Universal Catalog el que absorbió al antiguo Data Catalog independiente. Encontrar y clasificar los datos personales en sí: **Sensitive Data Protection** (antes Cloud DLP), que inspecciona, clasifica y puede desidentificar/enmascarar PII. Responden preguntas distintas: "qué datos tenemos y quién es su dueño" vs. "¿esta columna contiene un número de tarjeta de crédito?". Ver <https://cloud.google.com/dataplex/docs> y <https://cloud.google.com/sensitive-data-protection/docs>.

### Control 7

**P26.** 900 TB a 500 Mbps ≈ 900×10¹²/(62,5×10⁶) s ≈ 14,4 M s ≈ **167 días al 100% de utilización**, ~238 días a un 70% realista. Recomendación: **Transfer Appliance** — 900 TB son tres unidades TA300, enviadas e ingestadas en semanas. La razón de segundo orden que la aritmética no captura: el enlace está **compartido con 400 empleados**. Aun si 167 días fueran aceptables, saturar ese circuito degrada todas las demás funciones del negocio durante medio año; la transferencia tendría que limitarse, lo que empeora aún más el cronograma real. El ancho de banda no es capacidad gratis tirada al ocio — es infraestructura de producción.

**P27.** **Database Migration Service (DMS).** La secuencia: (1) crear perfiles de conexión de origen y destino; (2) DMS realiza un **volcado completo** inicial de los 2 TB hacia el destino Cloud SQL mientras el origen sigue vivo; (3) DMS aplica luego **replicación continua de cambios** desde el binlog del origen, de modo que el destino converge y sigue al origen; (4) monitorear el **retraso de replicación** hasta que esté cerca de cero; (5) en la ventana elegida, detener las escrituras al origen, dejar que drenen los últimos cambios, **promover** el destino y reapuntar la aplicación. El downtime es solo el drenado y reapuntado del paso 5 — minutos, no las horas que llevaría un volcado y restauración de 2 TB.

**P28.** **Storage Transfer Service** mueve **archivos/objetos** entre sistemas de almacenamiento — S3, Azure Blob, sistemas de archivos on-prem, endpoints HTTP, otros buckets de Cloud Storage — como un job de copia masiva o programada; la unidad es un objeto y la intención es *relocalización o sincronización continua de un corpus de archivos*. **Datastream** mueve **cambios de filas de base de datos** vía CDC desde un origen OLTP hacia un destino analítico; la unidad es una transacción y la intención es *mantener fresca una copia analítica*. Síntomas de herramienta equivocada: usar Storage Transfer para frescura de base de datos te deja volcados nocturnos desactualizados y carga pesada en el origen; usar Datastream para mover un archivo de medios es un error de categoría — no hay filas.

### Control 8 — Mapeo del trabajo final

| # | Producto | Propiedad decisiva | Respuesta incorrecta más fuerte, y por qué falla |
|---|---|---|---|
| **C1** | **Spanner** | Escrituras distribuidas globalmente con consistencia externa y SLA multi-región de 99,999%; "nunca desactualizado, nunca perdido" es una garantía de consistencia, no un objetivo de rendimiento | *Bigtable* — throughput de escritura enorme y baja latencia, pero sin transacciones entre filas ni consistencia fuerte global, así que un ranking puede leerse desactualizado o un puntaje perderse en una carrera |
| **C2** | **Cloud Storage, clase Archive** | Objetos binarios opacos, frecuencia de lectura casi nula, retención ≥365 días, recuperación dentro del día está muy holgada frente a la latencia de primer byte de Archive (milisegundos a segundos) | *Coldline* — forma correcta, economía incorrecta: con retención a diez años y lecturas casi nulas, Archive es ~3× más barato de almacenar y la prima de recuperación casi nunca se paga |
| **C3** | **Cloud SQL for SQL Server** | SQL Server gestionado mantiene idénticos el motor, el dialecto y los drivers, así que "ni una línea de código" es literalmente satisfacible | *AlloyDB / Cloud SQL for PostgreSQL* — más barato y más capaz, pero es otro motor; la restricción del proveedor lo prohíbe. (Si la licencia o la versión no están soportadas, el fallback es SQL Server sobre Compute Engine, no un motor distinto.) |
| **C4** | **Bigtable** | Millones de escrituras/segundo con lecturas de milisegundos de un dígito sobre un rango de clave; la consulta es literalmente `advertiser_id` + rango temporal, que es un escaneo por prefijo de clave de fila | *BigQuery* — va a almacenar y analizar estos eventos sin problema, pero no es un almacén de servicio de baja latencia para un camino de pujas en tiempo real. La arquitectura real es ambos: Bigtable sirviendo, BigQuery analizando |
| **C5** | **Looker** (capa semántica, LookML) | Una definición de métrica única, gobernada y versionada, consumida por Sheets, Looker Studio, apps embebidas y APIs — el requisito es *gobernanza de la definición*, no un gráfico | *Looker Studio solo* — gratis y bueno para dashboards, pero cada reporte reimplementa su propio "ingreso neto", que es exactamente el problema que se está resolviendo |
| **C6** | **Memorystore** (Redis/Valkey) | Lecturas en memoria sub-milisegundo, explícitamente reconstruibles — el requisito dice que los datos son descartables, y eso es lo que hace del caché el sistema correcto | *Firestore* — durable y rápido, pero milisegundos, no microsegundos, y estarías pagando por una durabilidad que el requisito dice no necesitar |
| **C7** | **Firestore (modo Native)** | Persistencia offline en el SDK móvil con sincronización automática y resolución de conflictos al reconectar; listeners en tiempo real para las vistas de despacho | *Cloud SQL* — un cliente móvil no puede sostener una conexión en un túnel; estarías construyendo a mano la cola offline y la capa de sincronización que Firestore ya trae |
| **C8** | **Sensitive Data Protection** (ex-Cloud DLP) | Inspección, clasificación y desidentificación/enmascarado de PII como `CREDIT_CARD_NUMBER`, hecho a propósito, ejecutable sobre BigQuery y Cloud Storage antes de que los analistas tengan acceso | *Control de acceso a nivel de columna de BigQuery* — necesario pero insuficiente: protege columnas que ya identificaste, y el problema es que los números de tarjeta están escondidos dentro de cuerpos de texto libre de los tickets |

**P29.** **C3 y C4** son las dos que se mueven.
- **C3**: la restricción "sin ingenieros de datos, sin planificación de capacidad" empuja todavía más fuerte hacia **Cloud SQL** por sobre cualquier SQL Server autogestionado sobre Compute Engine — la respuesta no cambia de producto, pero la *justificación* pasa de "restricción del proveedor" a "capacidad operativa", que es el argumento más duradero.
- **C4** es el cambio real: **Bigtable requiere verdadera habilidad de diseño de esquema** (diseño de clave de fila, evitar hotspots, dimensionamiento del clúster / política de autoescalado). Un equipo sin ingenieros de datos va a construir una tabla con hotspots y concluir que el producto es lento. Sin esa habilidad, la recomendación honesta es **BigQuery** para la mitad analítica más un almacén de servicio más simple (Firestore, o Memorystore delante) para la mitad de baja latencia — aceptando un techo peor a cambio de un sistema que el equipo pueda operar de verdad. Nombrar un producto que un equipo no puede operar es una recomendación fallida, sin importar sus números de benchmark.

*(Una respuesta alternativa defendible nombra **C5** — Looker acarrea un costo real de modelado y de LookML, y a un equipo sin ingenieros de datos quizá le sirva mejor Looker Studio sobre una vista de BigQuery bien diseñada. Dale crédito si además nombraste la regresión de gobernanza que eso provoca.)*

**P30.** Respuesta modelo:

> Ambos productos almacenarían la tabla de posiciones correctamente en un día cualquiera. La diferencia aparece el peor día. Con Cloud SQL, cada puntaje del mundo se escribe a través de una única base de datos primaria en una sola región: si esa región tiene una caída, la tabla de posiciones queda no disponible para los 50 millones de jugadores hasta que promovamos una réplica a mano, y cualquier puntaje escrito en los últimos segundos antes de la falla puede haber desaparecido. Con Spanner, esa misma escritura se confirma en un quórum de réplicas en múltiples regiones antes de que la reconozcamos, así que perder una región entera no nos cuesta ni disponibilidad ni un solo puntaje — el objetivo de disponibilidad publicado es 99,999%, aproximadamente cinco minutos de caída al año, contra el 99,95% de Cloud SQL, unas cuatro horas y media. Spanner también elimina un segundo riesgo, más silencioso: como Cloud SQL escala agrandando una máquina, nuestro crecimiento tiene un techo que eventualmente alcanzaríamos durante un lanzamiento — el peor momento posible — mientras que Spanner suma capacidad sumando nodos, sin reescritura. Pagamos más por mes por Spanner. Lo que estamos comprando es que una caída regional y un pico de crecimiento viral se vuelvan ambos no-eventos en lugar de incidentes, y para un producto cuyo valor entero es un ranking global en vivo, una hora de rankings erróneos o faltantes cuesta más en confianza de los jugadores que la diferencia en la factura anual.

</details>

---

## Fuentes

- Guía del examen Cloud Digital Leader — <https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf>
- Clases / ciclo de vida / Autoclass de Cloud Storage — <https://cloud.google.com/storage/docs/storage-classes>, <https://cloud.google.com/storage/docs/lifecycle>, <https://cloud.google.com/storage/docs/autoclass>
- Filestore — <https://cloud.google.com/filestore/docs/overview>
- Cloud SQL — <https://cloud.google.com/sql/docs/introduction>
- AlloyDB for PostgreSQL — <https://cloud.google.com/alloydb/docs/overview>
- Spanner (incl. emulador) — <https://cloud.google.com/spanner/docs/overview>, <https://cloud.google.com/spanner/docs/emulator>
- Diseño de esquema de Bigtable — <https://cloud.google.com/bigtable/docs/schema-design>
- Firestore, y Native vs. modo Datastore — <https://cloud.google.com/firestore/docs>, <https://cloud.google.com/datastore/docs/firestore-or-datastore>
- Tiers de Memorystore — <https://cloud.google.com/memorystore/docs/redis/redis-tiers>
- Introducción, precios, reservas y BigLake de BigQuery — <https://cloud.google.com/bigquery/docs/introduction>, <https://cloud.google.com/bigquery/pricing>, <https://cloud.google.com/bigquery/docs/reservations-intro>, <https://cloud.google.com/bigquery/docs/biglake-intro>
- Pub/Sub — <https://cloud.google.com/pubsub/docs/overview>
- Dataflow / Dataproc / Data Fusion / Composer — <https://cloud.google.com/dataflow/docs>, <https://cloud.google.com/dataproc/docs>, <https://cloud.google.com/data-fusion/docs>, <https://cloud.google.com/composer/docs>
- Datastream — <https://cloud.google.com/datastream/docs/overview>
- Dataplex — <https://cloud.google.com/dataplex/docs>
- Sensitive Data Protection — <https://cloud.google.com/sensitive-data-protection/docs>
- Database Migration Service — <https://cloud.google.com/database-migration/docs>
- Storage Transfer Service / Transfer Appliance — <https://cloud.google.com/storage-transfer/docs/overview>, <https://cloud.google.com/transfer-appliance/docs>
- Looker — <https://cloud.google.com/looker/docs>