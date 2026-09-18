# 701.2 — Componentes y plataformas estándar para software

**Examen:** LPI DevOps Tools Engineer, 701-100 (v2.0.0) · **Peso:** 5

Estos ejercicios recorren las familias de componentes que nombra el objetivo — almacenamiento de objetos, bases de datos relacionales y NoSQL, brokers y colas de mensajes, procesamiento de big data, y OAuth 2.0 / OpenID Connect — ejecutando una instancia real de cada uno y observando el comportamiento que impulsa las decisiones de arquitectura. Cada paso es ejecutable; después de cada bloque hay preguntas de comprensión, y las respuestas están en la sección plegable del final.

**Tiempo:** ~4 horas en total. Cada ejercicio es autocontenido excepto el Ejercicio 7 (Spark), que reutiliza el directorio `lab-data`.

---

## 0. Entorno de laboratorio

Necesitas Docker Engine ≥ 24 con el plugin Compose v2 (o Podman con `podman compose`), `curl`, `jq`, `python3`, y aproximadamente 6 GB de RAM libre. Nada de esto toca una cuenta en la nube ni cuesta dinero.

**Paso 0.1** — Crea el directorio del laboratorio y el directorio de datos que Spark y `mc` van a compartir:

```bash
mkdir -p ~/lab-701.2/lab-data && cd ~/lab-701.2
```

**Paso 0.2** — Escribe `compose.yaml`:

```yaml
name: devops701

services:
  minio:
    image: quay.io/minio/minio:latest
    command: 'server /data --console-address ":9001"'
    environment:
      MINIO_ROOT_USER: minioadmin
      MINIO_ROOT_PASSWORD: minioadmin123
    ports:
      - "9000:9000"
      - "9001:9001"
    volumes:
      - minio-data:/data

  mc:
    image: quay.io/minio/mc:latest
    profiles:
      - tools
    depends_on:
      - minio
    volumes:
      - mc-config:/root/.mc
      - ./lab-data:/data:z

  postgres:
    image: postgres:16
    environment:
      POSTGRES_PASSWORD: secret
      POSTGRES_DB: shop
    ports:
      - "5432:5432"
    volumes:
      - pg-data:/var/lib/postgresql/data

  mongo:
    image: mongo:7
    command: 'mongod --replSet rs0 --bind_ip_all'
    ports:
      - "27017:27017"
    volumes:
      - mongo-data:/data/db

  redis:
    image: redis:7
    command: 'redis-server --maxmemory 32mb --maxmemory-policy allkeys-lru --appendonly no'
    ports:
      - "6379:6379"

  rabbitmq:
    image: rabbitmq:3.13-management
    ports:
      - "5672:5672"
      - "15672:15672"

  kafka:
    image: apache/kafka:3.9.0

  keycloak:
    image: quay.io/keycloak/keycloak:26.0
    command: start-dev
    environment:
      KC_BOOTSTRAP_ADMIN_USERNAME: admin
      KC_BOOTSTRAP_ADMIN_PASSWORD: admin
    ports:
      - "8080:8080"

volumes:
  minio-data:
  mc-config:
  pg-data:
  mongo-data:
```

**Paso 0.3** — Levanta la plataforma y confirma que todos los servicios están arriba:

```bash
docker compose up -d
docker compose ps
```

Salida similar a:

```
NAME                  IMAGE                          STATUS          PORTS
devops701-kafka-1     apache/kafka:3.9.0             Up 12 seconds
devops701-keycloak-1  quay.io/keycloak/keycloak:26.0 Up 12 seconds   0.0.0.0:8080->8080/tcp
devops701-minio-1     quay.io/minio/minio:latest     Up 12 seconds   0.0.0.0:9000-9001->9000-9001/tcp
devops701-mongo-1     mongo:7                        Up 12 seconds   0.0.0.0:27017->27017/tcp
devops701-postgres-1  postgres:16                    Up 12 seconds   0.0.0.0:5432->5432/tcp
devops701-rabbitmq-1  rabbitmq:3.13-management       Up 12 seconds   0.0.0.0:5672->5672/tcp, 0.0.0.0:15672->15672/tcp
devops701-redis-1     redis:7                        Up 12 seconds   0.0.0.0:6379->6379/tcp
```

> En un host con SELinux (Fedora, RHEL, CentOS Stream) el sufijo `:z` en el montaje de `./lab-data` es lo que permite que el contenedor escriba ahí. Sin él obtienes `Permission denied` aunque el directorio tenga permisos de escritura para todo el mundo.

**Preguntas 0**

1. El servicio `mc` tiene `profiles: ["tools"]`. ¿Por qué `docker compose up -d` no lo levantó, y cómo se ejecuta?
2. Keycloak 25 y anteriores usaban `KEYCLOAK_ADMIN` / `KEYCLOAK_ADMIN_PASSWORD`. ¿Qué pasa si usas esos nombres contra la imagen 26.0, y por qué una etiqueta de imagen como `:latest` hace que esta clase de fallo sea difícil de reproducir?
3. `kafka` no publica ningún puerto. ¿Qué te dice eso sobre cómo se espera que lo alcances en este laboratorio?

---

## 1. Almacenamiento de objetos (MinIO / la API S3)

El almacenamiento de objetos no es un sistema de archivos: no hay directorios, ni escrituras parciales, ni rename, ni bloqueo POSIX. Hay un espacio de claves plano dentro de un bucket, PUT/GET del objeto completo sobre HTTP, y metadatos por objeto. Cada decisión de diseño de este ejercicio se desprende de eso.

**Paso 1.1** — Registra el endpoint de MinIO como un alias de `mc` (el alias se persiste en el volumen `mc-config`, así que las invocaciones posteriores de `run` lo reutilizan):

```bash
docker compose run --rm mc alias set local http://minio:9000 minioadmin minioadmin123
```

```
Added `local` successfully.
```

**Paso 1.2** — Crea dos buckets: uno común, y otro con object locking habilitado (que requiere versionado y solo puede configurarse en el momento de la creación):

```bash
docker compose run --rm mc mb local/reports
docker compose run --rm mc mb --with-lock local/audit
docker compose run --rm mc version enable local/reports
docker compose run --rm mc ls local
```

```
Bucket created successfully `local/reports`.
Bucket created successfully `local/audit`.
local/reports versioning is enabled
[2026-09-18 10:12:03 UTC]     0B audit/
[2026-09-18 10:12:01 UTC]     0B reports/
```

**Paso 1.3** — Crea un objeto, súbelo dos veces con contenido distinto y lista las versiones:

```bash
echo "revenue,region
1200,latam" > lab-data/q3.csv
docker compose run --rm mc cp /data/q3.csv local/reports/2026/q3.csv

echo "revenue,region
1450,latam" > lab-data/q3.csv
docker compose run --rm mc cp /data/q3.csv local/reports/2026/q3.csv

docker compose run --rm mc ls --versions local/reports/2026/
```

```
[2026-09-18 10:15:44 UTC]    28B STANDARD 0f2c1b6e-7a41-4a0e-9b1d-3c4a51f0d2aa v2 PUT q3.csv
[2026-09-18 10:15:31 UTC]    28B STANDARD 9d13a8c0-1e55-4f32-8d77-2b0e6a7c9f14 v1 PUT q3.csv
```

**Paso 1.4** — Inspecciona los metadatos del objeto y define una cabecera personalizada:

```bash
docker compose run --rm mc stat local/reports/2026/q3.csv
docker compose run --rm mc cp --attr "x-amz-meta-owner=finance;x-amz-meta-retention-class=annual" \
  /data/q3.csv local/reports/2026/q3.csv
docker compose run --rm mc stat local/reports/2026/q3.csv
```

```
Name      : q3.csv
Date      : 2026-09-18 10:18:02 UTC
Size      : 28 B
ETag      : 4a9f0c2b19e7d5a83f6b1c0d2e4f7a91
Type      : file
Metadata  :
  Content-Type              : text/csv
  X-Amz-Meta-Owner          : finance
  X-Amz-Meta-Retention-Class: annual
```

**Paso 1.5** — Genera una URL prefirmada y descárgala *desde el host*. El endpoint de MinIO es `minio:9000` en la red de Compose, y la firma SigV4 cubre la cabecera `Host` — así que no puedes simplemente reescribir el nombre de host a `localhost`:

```bash
URL=$(docker compose run --rm mc share download --expire=10m local/reports/2026/q3.csv \
  | awk '/^Share:/ {print $2}')
echo "$URL"

curl --resolve minio:9000:127.0.0.1 -s -D - -o /dev/null "$URL"
```

```
HTTP/1.1 200 OK
Accept-Ranges: bytes
Content-Length: 28
Content-Type: text/csv
ETag: "4a9f0c2b19e7d5a83f6b1c0d2e4f7a91"
Last-Modified: Fri, 18 Sep 2026 10:18:02 GMT
X-Amz-Meta-Owner: finance
x-amz-request-id: 185F2C4A9B1E7D3C
```

**Paso 1.6** — Solicita solo los primeros 12 bytes, y luego rompe la firma deliberadamente:

```bash
curl --resolve minio:9000:127.0.0.1 -s -D - -r 0-11 "$URL"
curl --resolve minio:9000:127.0.0.1 -s "${URL}&extra=tampered" | head -20
```

```
HTTP/1.1 206 Partial Content
Content-Range: bytes 0-11/28
Content-Length: 12

revenue,regi
```

```
<?xml version="1.0" encoding="UTF-8"?>
<Error><Code>SignatureDoesNotMatch</Code><Message>The request signature we calculated does not match the signature you provided.</Message></Error>
```

**Paso 1.7** — Haz el bucket legible anónimamente, verifícalo, y después deshazlo:

```bash
docker compose run --rm mc anonymous set download local/reports
curl --resolve minio:9000:127.0.0.1 -s http://minio:9000/reports/2026/q3.csv
docker compose run --rm mc anonymous set none local/reports
```

**Paso 1.8** — Aplica una retención WORM por defecto sobre el bucket bloqueado e intenta borrar un objeto protegido:

```bash
docker compose run --rm mc retention set --default COMPLIANCE 30d local/audit
docker compose run --rm mc cp /data/q3.csv local/audit/2026-q3-audit.csv
docker compose run --rm mc rm local/audit/2026-q3-audit.csv
```

```
mc: <ERROR> Failed to remove `local/audit/2026-q3-audit.csv`. Object, overwrite or version delete is not allowed due to object retention or legal hold.
```

**Preguntas 1**

1. Subiste `q3.csv` tres veces a la misma clave. ¿Cuántos objetos facturables existen en `reports`, y qué muestra un `mc ls` a secas? ¿Qué riesgo operativo genera eso a lo largo de un año?
2. La URL prefirmada funcionó con `--resolve` pero fallaría si simplemente reemplazaras `minio` por `localhost` en la URL. Explica por qué en términos de lo que firma SigV4, y nombra el ajuste de MinIO que resuelve esto correctamente en un despliegue de producción detrás de un balanceador de carga.
3. El paso 1.6 devolvió `206 Partial Content`. ¿Cuál de estas *no* es posible con almacenamiento de objetos, y por qué: leer el rango de bytes 5000–6000 de un log de 1 GB, agregar una línea a ese log, reemplazar el log entero?
4. El `ETag` aquí fue un MD5 simple. ¿Qué te dice un ETag terminado en `-4` sobre cómo se subió el objeto, y por qué eso rompe las verificaciones ingenuas de integridad?
5. La retención `COMPLIANCE` impide el borrado por parte de *cualquiera*, incluida la credencial root, durante el período de retención. Da un caso en el que quieras el modo `GOVERNANCE` en su lugar.
6. Un colega propone guardar el estado de sesión de la aplicación en S3 en vez de en Redis, "porque es más barato por GB". Da las dos objeciones técnicas más fuertes.

---

## 2. Bases de datos relacionales (PostgreSQL) — ACID, aislamiento y planes

**Paso 2.1** — Abre una sesión de psql y crea un esquema con restricciones reales:

```bash
docker compose exec postgres psql -U postgres -d shop
```

```sql
CREATE TABLE accounts (
    id      int PRIMARY KEY,
    owner   text NOT NULL,
    balance numeric(12,2) NOT NULL CHECK (balance >= 0)
);

INSERT INTO accounts VALUES (1, 'ana', 1000.00), (2, 'beto', 500.00);

CREATE TABLE orders (
    id          bigserial PRIMARY KEY,
    account_id  int NOT NULL REFERENCES accounts(id),
    email       text NOT NULL,
    total_cents bigint NOT NULL CHECK (total_cents >= 0),
    status      text NOT NULL DEFAULT 'pending',
    created_at  timestamptz NOT NULL DEFAULT now()
);
```

**Paso 2.2** — Comprueba que las restricciones las hace cumplir el motor, no la aplicación:

```sql
UPDATE accounts SET balance = balance - 5000 WHERE id = 1;
INSERT INTO orders (account_id, email, total_cents) VALUES (99, 'x@example.com', 100);
```

```
ERROR:  new row for relation "accounts" violates check constraint "accounts_balance_check"
DETAIL:  Failing row contains (1, ana, -4000.00).
ERROR:  insert or update on table "orders" violates foreign key constraint "orders_account_id_fkey"
DETAIL:  Key (account_id)=(99) is not present in table "accounts".
```

**Paso 2.3** — Reproduce una actualización perdida. Abre una **segunda** terminal con una segunda sesión de psql; las dos sesiones se etiquetan **A** y **B**.

En A:

```sql
BEGIN;
SELECT balance FROM accounts WHERE id = 1;   -- 1000.00
```

En B:

```sql
BEGIN;
SELECT balance FROM accounts WHERE id = 1;   -- 1000.00
```

En A:

```sql
UPDATE accounts SET balance = 900.00 WHERE id = 1;
COMMIT;
```

En B:

```sql
UPDATE accounts SET balance = 900.00 WHERE id = 1;
COMMIT;
SELECT balance FROM accounts WHERE id = 1;
```

```
 balance
---------
  900.00
```

Se aplicaron dos retiros de 100 y el saldo bajó 100. Desapareció dinero del libro contable.

**Paso 2.4** — Repite el mismo entrelazado bajo `REPEATABLE READ`. Primero reinicia (`UPDATE accounts SET balance = 1000.00 WHERE id = 1;`), y luego, en ambas sesiones, comienza con:

```sql
BEGIN ISOLATION LEVEL REPEATABLE READ;
```

Ejecuta la misma secuencia. El `UPDATE` de B ahora se bloquea hasta que A hace commit, y entonces:

```
ERROR:  could not serialize access due to concurrent update
```

**Paso 2.5** — Escríbelo como debería haberse escrito desde el principio, y observa el bloqueo:

En A:

```sql
BEGIN;
SELECT balance FROM accounts WHERE id = 1 FOR UPDATE;
```

En B:

```sql
BEGIN;
UPDATE accounts SET balance = balance - 100 WHERE id = 1;   -- blocks
```

En una tercera sesión:

```sql
SELECT pid, state, wait_event_type, wait_event, left(query, 60) AS query
FROM pg_stat_activity WHERE datname = 'shop' AND state <> 'idle';
```

```
 pid  |        state        | wait_event_type | wait_event |                   query
------+---------------------+-----------------+------------+--------------------------------------------
  241 | idle in transaction |  Client         | ClientRead | SELECT balance FROM accounts WHERE id = 1 F
  258 | active              |  Lock           | transactionid | UPDATE accounts SET balance = balance - 100
```

Haz commit en A y observa cómo B se completa.

**Paso 2.6** — Carga 300 000 filas y mira un plan:

```sql
INSERT INTO orders (account_id, email, total_cents, status)
SELECT 1,
       'user' || (random() * 50000)::int || '@example.com',
       (random() * 100000)::bigint,
       (ARRAY['pending','paid','shipped','cancelled'])[1 + floor(random() * 4)::int]
FROM generate_series(1, 300000);

ANALYZE orders;

EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM orders WHERE email = 'user4242@example.com';
```

```
 Gather  (cost=1000.00..8792.10 rows=6 width=61) (actual time=0.412..38.907 rows=7 loops=1)
   Workers Planned: 2
   Workers Launched: 2
   ->  Parallel Seq Scan on orders  (cost=0.00..7791.50 rows=3 width=61) (actual time=22.1..31.4 rows=2 loops=3)
         Filter: (email = 'user4242@example.com'::text)
         Rows Removed by Filter: 99998
         Buffers: shared hit=3021
 Planning Time: 0.121 ms
 Execution Time: 38.956 ms
```

**Paso 2.7** — Agrega el índice y vuelve a ejecutar la consulta idéntica:

```sql
CREATE INDEX orders_email_idx ON orders (email);
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM orders WHERE email = 'user4242@example.com';
```

```
 Bitmap Heap Scan on orders  (cost=4.35..28.12 rows=6 width=61) (actual time=0.031..0.041 rows=7 loops=1)
   Recheck Cond: (email = 'user4242@example.com'::text)
   Buffers: shared hit=10
   ->  Bitmap Index Scan on orders_email_idx  (cost=0.00..4.35 rows=6 width=0) (actual time=0.022..0.022 rows=7 loops=1)
         Index Cond: (email = 'user4242@example.com'::text)
 Planning Time: 0.198 ms
 Execution Time: 0.068 ms
```

**Paso 2.8** — Agrega un índice parcial para la consulta caliente de la cola, y revisa el techo de conexiones:

```sql
CREATE INDEX orders_pending_idx ON orders (created_at DESC) WHERE status = 'pending';
EXPLAIN SELECT * FROM orders WHERE status = 'pending' ORDER BY created_at DESC LIMIT 20;

SELECT pg_size_pretty(pg_relation_size('orders_email_idx'))   AS full_idx,
       pg_size_pretty(pg_relation_size('orders_pending_idx')) AS partial_idx;

SHOW max_connections;
SELECT count(*) FROM pg_stat_activity;
```

**Preguntas 2**

1. En el paso 2.3 ambas transacciones hicieron commit con éxito y los datos quedaron mal. ¿Qué letra de ACID *no* fue violada por esto, y cómo se llama esta anomalía?
2. `REPEATABLE READ` convirtió una pérdida silenciosa de datos en el error `40001`. ¿Qué debe hacer ahora la *aplicación* que antes no tenía que hacer, y por qué eso es una decisión de diseño y no solo de configuración?
3. `UPDATE accounts SET balance = balance - 100` es seguro en `READ COMMITTED` donde `SELECT` seguido de `UPDATE balance = 900` no lo era. Explica con precisión por qué.
4. La sesión A del paso 2.5 estaba `idle in transaction` mientras mantenía un bloqueo de fila. ¿Por qué ese estado es lo más peligroso de toda esta lista en producción, y qué dos ajustes acotan el daño?
5. El recorrido secuencial leyó 3021 shared buffers y el recorrido por índice leyó 10. ¿Con qué selectividad tendría *razón* el planificador al ignorar tu índice, y por qué eso no es un bug del planificador?
6. `max_connections` es 100. Tu despliegue de Kubernetes escala a 40 pods con un pool de 20 conexiones cada uno. ¿Qué se rompe, y qué componente pones delante de PostgreSQL?

---

## 3. NoSQL — almacén de documentos (MongoDB)

**Paso 3.1** — Abre `mongosh` e inicializa el replica set de un solo nodo (un `mongod` standalone no soporta ni transacciones ni change streams):

```bash
docker compose exec mongo mongosh
```

```javascript
rs.initiate({ _id: "rs0", members: [{ _id: 0, host: "mongo:27017" }] })
rs.status().myState   // 1 = PRIMARY, may take a few seconds
```

**Paso 3.2** — Inserta documentos cuya forma difiere, que es todo el sentido de un almacén de documentos:

```javascript
use shop

db.products.insertMany([
  { sku: "kbd-01", name: "Mechanical keyboard", price: 89.90, tags: ["input", "usb"], stock: 12 },
  { sku: "mon-27", name: "27\" monitor", price: 310.00, tags: ["display"], stock: 3,
    specs: { panel: "IPS", hz: 144, ports: ["hdmi", "dp"] } },
  { sku: "cbl-hd", name: "HDMI cable", price: 7.50, stock: 240 }
])

db.products.find({ price: { $lt: 100 } }, { sku: 1, price: 1, _id: 0 })
db.products.find({ "specs.ports": "dp" }, { sku: 1, _id: 0 })
```

**Paso 3.3** — Agrega un índice único y observa cómo rechaza un duplicado:

```javascript
db.products.createIndex({ sku: 1 }, { unique: true })
db.products.insertOne({ sku: "kbd-01", name: "Clone", price: 1.00 })
```

```
MongoServerError: E11000 duplicate key error collection: shop.products index: sku_1 dup key: { sku: "kbd-01" }
```

**Paso 3.4** — Compara un recorrido de colección con un recorrido por índice:

```javascript
for (let i = 0; i < 100000; i++) {
  db.products.insertOne({ sku: "bulk-" + i, name: "Bulk " + i, price: Math.random() * 500, stock: i % 50 })
}

db.products.find({ sku: "bulk-99999" }).explain("executionStats").executionStats
db.products.find({ stock: 42 }).explain("executionStats").executionStats
```

Compara `totalDocsExamined` y `executionStages.stage` (`IXSCAN` vs `COLLSCAN`) entre ambos.

**Paso 3.5** — Ejecuta un pipeline de agregación:

```javascript
db.products.aggregate([
  { $match: { price: { $gte: 100 } } },
  { $group: { _id: { $cond: [{ $gt: ["$stock", 25] }, "healthy", "low"] },
              count: { $sum: 1 }, avgPrice: { $avg: "$price" } } },
  { $sort: { count: -1 } }
])
```

**Paso 3.6** — "Schemaless" no significa "sin esquema" — mueve el esquema dentro de la base de datos:

```javascript
db.runCommand({
  collMod: "products",
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: ["sku", "name", "price"],
      properties: {
        sku:   { bsonType: "string", pattern: "^[a-z0-9-]+$" },
        price: { bsonType: "number", minimum: 0 }
      }
    }
  },
  validationLevel: "strict",
  validationAction: "error"
})

db.products.insertOne({ sku: "no-price", name: "Broken" })
```

```
MongoServerError: Document failed validation
```

**Paso 3.7** — Ejecuta una transacción multidocumento y un write concern:

```javascript
const s = db.getMongo().startSession()
s.startTransaction({ writeConcern: { w: "majority" } })
const col = s.getDatabase("shop").products
col.updateOne({ sku: "kbd-01" }, { $inc: { stock: -1 } })
col.updateOne({ sku: "cbl-hd" }, { $inc: { stock: -1 } })
s.commitTransaction()
s.endSession()

db.products.insertOne({ sku: "wc-demo", name: "Write concern", price: 1 },
                      { writeConcern: { w: "majority", wtimeout: 5000 } })
```

**Preguntas 3**

1. El paso 3.1 era obligatorio antes del paso 3.7. ¿Cuál es la razón de fondo por la que un único `mongod` no puede ofrecer transacciones multidocumento, y qué te dice eso sobre dónde vive realmente la garantía de durabilidad de MongoDB?
2. Te conectaste con `docker compose exec`. Si te conectas desde el host con `mongosh mongodb://localhost:27017`, el handshake tiene éxito y luego el driver falla. ¿Por qué? (La respuesta es la misma razón por la que un StatefulSet de Kubernetes necesita un Service headless).
3. El paso 3.6 puso un JSON Schema en la base de datos cuando la colección ya tenía documentos dentro. ¿Qué le hace `validationLevel: "strict"` a los documentos preexistentes que lo violan, y qué valor elegirías durante una migración en vivo?
4. Tanto PostgreSQL (Ejercicio 2) como MongoDB rechazaron datos inválidos. Nombra dos clases de restricción de integridad que PostgreSQL hace cumplir y `$jsonSchema` no puede.
5. `w: "majority"` cuesta latencia en cada escritura. Describe una colección de esta tienda donde `w: 1` es la elección correcta y una donde es negligencia.
6. Da la señal concreta sobre la forma de los datos — no un argumento vago de "flexibilidad" — que indica que una carga de trabajo pertenece a un almacén de documentos y no a PostgreSQL. Después da la contraseñal que indica que no.

---

## 4. NoSQL — caché clave/valor (Redis)

**Paso 4.1** — Abre la CLI y construye las primitivas que realmente usa una capa de aplicación:

```bash
docker compose exec redis redis-cli
```

```
SET session:u42 "{\"user\":42,\"role\":\"editor\"}" EX 30
TTL session:u42
INCR metrics:page:home
INCRBY metrics:page:home 5
HSET cart:u42 sku:kbd-01 2 sku:cbl-hd 1
HGETALL cart:u42
EXPIRE cart:u42 3600
OBJECT ENCODING cart:u42
```

```
OK
(integer) 30
(integer) 1
(integer) 6
(integer) 2
1) "sku:kbd-01"
2) "2"
3) "sku:cbl-hd"
4) "1"
(integer) 1
"listpack"
```

**Paso 4.2** — Espera 30 segundos y confirma que la sesión desapareció:

```
TTL session:u42
GET session:u42
```

```
(integer) -2
(nil)
```

**Paso 4.3** — Implementa un lock distribuido correcto, y después rompe el ingenuo:

```
SET lock:invoice:2026-09 "worker-a-token-93f1" NX PX 10000
SET lock:invoice:2026-09 "worker-b-token-2ac7" NX PX 10000
PTTL lock:invoice:2026-09
```

```
OK
(nil)
(integer) 8422
```

**Paso 4.4** — Dispara la expulsión (eviction). `maxmemory` es 32 MB con `allkeys-lru`:

```
CONFIG GET maxmemory
CONFIG GET maxmemory-policy
DEBUG POPULATE 500000
DBSIZE
INFO stats
INFO memory
```

Busca `evicted_keys` en `INFO stats` y `used_memory_human` en `INFO memory`. `DBSIZE` estará muy por debajo de 500 000.

```
# Stats
expired_keys:2
evicted_keys:238417
keyspace_misses:0
```

**Paso 4.5** — Revisa la postura de durabilidad de esta instancia:

```
CONFIG GET appendonly
CONFIG GET save
BGSAVE
LASTSAVE
INFO persistence
```

**Paso 4.6** — Observa lo que tu aplicación está enviando realmente, en una segunda terminal:

```bash
docker compose exec redis redis-cli MONITOR
```

Luego, en la primera sesión, ejecuta algunos comandos y míralos aparecer. Detén `MONITOR` con `Ctrl-C`.

**Preguntas 4**

1. El paso 4.4 destruyó un cuarto de millón de claves y Redis informó éxito todo el tiempo. ¿Qué único valor de configuración convierte a esta instancia de una caché en algo que le entregará a tu aplicación datos sin obsolescencia pero *incompletos*, y cuál es el modo de fallo si lo pones en `noeviction`?
2. `SET key value NX PX 10000` es la adquisición de lock correcta. ¿Por qué `SETNX` seguido de `EXPIRE` está mal, y por qué la *liberación* también requiere cuidado — para qué es el token?
3. `MONITOR` y `DEBUG POPULATE` están ambos en este ejercicio y ninguno pertenece a producción. Da el costo específico de cada uno.
4. `OBJECT ENCODING` devolvió `listpack` para un hash de dos campos. ¿Qué le pasa a la memoria y a la complejidad de acceso cuando ese hash crece más allá de `hash-max-listpack-entries`?
5. El archivo compose define `--appendonly no`. Describe la ventana exacta de pérdida de datos después de un `kill -9` de este contenedor, y di cuáles de los datos del ejercicio (sesiones, carrito, métricas de página) estás dispuesto a perder de esa forma.
6. Redis y RabbitMQ pueden ambos mantener una lista de trabajos pendientes (`LPUSH`/`BRPOP` vs una cola). Nombra las dos garantías que da el broker y que la lista de Redis no da.

---

## 5. Broker de mensajes — enrutamiento AMQP y dead-lettering (RabbitMQ)

**Paso 5.1** — Descarga la CLI de administración desde el broker en ejecución (es un script Python servido por el plugin de management) y confirma que habla con el nodo:

```bash
curl -fsSL http://localhost:15672/cli/rabbitmqadmin -o rabbitmqadmin
chmod +x rabbitmqadmin
./rabbitmqadmin -u guest -p guest list exchanges name type
```

```
+--------------------+---------+
|        name        |  type   |
+--------------------+---------+
|                    | direct  |
| amq.direct         | direct  |
| amq.fanout         | fanout  |
| amq.topic          | topic   |
+--------------------+---------+
```

**Paso 5.2** — Declara un topic exchange y dos consumidores con intereses distintos:

```bash
./rabbitmqadmin -u guest -p guest declare exchange name=orders type=topic durable=true
./rabbitmqadmin -u guest -p guest declare queue name=billing durable=true
./rabbitmqadmin -u guest -p guest declare queue name=audit   durable=true
./rabbitmqadmin -u guest -p guest declare binding source=orders destination=billing routing_key=order.created
./rabbitmqadmin -u guest -p guest declare binding source=orders destination=audit   routing_key='order.#'
./rabbitmqadmin -u guest -p guest list bindings source destination routing_key
```

**Paso 5.3** — Publica tres mensajes con routing keys distintas y cuenta qué llegó a dónde:

```bash
./rabbitmqadmin -u guest -p guest publish exchange=orders routing_key=order.created \
  payload='{"id":1,"total":8990}' properties='{"delivery_mode":2,"content_type":"application/json"}'
./rabbitmqadmin -u guest -p guest publish exchange=orders routing_key=order.cancelled \
  payload='{"id":1}' properties='{"delivery_mode":2}'
./rabbitmqadmin -u guest -p guest publish exchange=orders routing_key=shipment.dispatched \
  payload='{"id":1}' properties='{"delivery_mode":2}'

./rabbitmqadmin -u guest -p guest list queues name messages
```

```
+---------+----------+
|  name   | messages |
+---------+----------+
| audit   | 2        |
| billing | 1        |
+---------+----------+
```

**Paso 5.4** — Publica hacia una routing key a la que nadie está vinculado, y hacia un exchange inexistente:

```bash
./rabbitmqadmin -u guest -p guest publish exchange=orders routing_key=nobody.listens payload='lost'
./rabbitmqadmin -u guest -p guest publish exchange=does-not-exist routing_key=x payload='lost'
```

```
Message published but NOT routed
*** Not found: /api/exchanges/%2F/does-not-exist/publish
```

**Paso 5.5** — Agrega una ruta de dead-letter. Primero intenta redeclarar `billing` con argumentos nuevos, y lee el error con atención:

```bash
./rabbitmqadmin -u guest -p guest declare queue name=billing durable=true \
  arguments='{"x-dead-letter-exchange":"","x-dead-letter-routing-key":"billing.dlq"}'
```

```
*** Error: 400 Bad Request: inequivalent arg 'x-dead-letter-exchange' for queue 'billing' in vhost '/': received the value 'none' of type 'longstr' but current is none
```

Bórrala y vuelve a crearla correctamente, después re-vincúlala:

```bash
./rabbitmqadmin -u guest -p guest declare queue name=billing.dlq durable=true
./rabbitmqadmin -u guest -p guest delete queue name=billing
./rabbitmqadmin -u guest -p guest declare queue name=billing durable=true \
  arguments='{"x-dead-letter-exchange":"","x-dead-letter-routing-key":"billing.dlq","x-max-length":1000}'
./rabbitmqadmin -u guest -p guest declare binding source=orders destination=billing routing_key=order.created
```

**Paso 5.6** — Publica, consume con un *reject*, y observa cómo el mensaje se mueve a la DLQ:

```bash
./rabbitmqadmin -u guest -p guest publish exchange=orders routing_key=order.created \
  payload='{"id":2,"total":"not-a-number"}' properties='{"delivery_mode":2}'

./rabbitmqadmin -u guest -p guest get queue=billing ackmode=reject_requeue_false count=1
./rabbitmqadmin -u guest -p guest list queues name messages
```

```
+---------+----------+
|  name   | messages |
+---------+----------+
| audit   | 3        |
| billing | 0        |
| billing.dlq | 1    |
+---------+----------+
```

**Paso 5.7** — Comprueba que la durabilidad son dos decisiones separadas. Publica un mensaje persistente y uno transitorio, y después reinicia el broker:

```bash
./rabbitmqadmin -u guest -p guest publish exchange=orders routing_key=order.created \
  payload='persistent' properties='{"delivery_mode":2}'
./rabbitmqadmin -u guest -p guest publish exchange=orders routing_key=order.created \
  payload='transient' properties='{"delivery_mode":1}'

docker compose restart rabbitmq
sleep 20
./rabbitmqadmin -u guest -p guest list queues name messages
```

**Preguntas 5**

1. `order.cancelled` llegó a `audit` pero no a `billing`. Reconstruye la decisión de enrutamiento que tomó el broker, y di qué habría coincidido con `order.*` que `order.#` sí hizo coincidir.
2. El paso 5.4 informó "published but NOT routed" y devolvió éxito al publicador. ¿Qué dos características de AMQP le habrían avisado al productor que su mensaje no fue a ninguna parte?
3. Explica el error `inequivalent arg` en una oración, y después explica por qué es un *buen* error — ¿qué se rompería silenciosamente si RabbitMQ hubiera aceptado la redeclaración?
4. La DLQ del paso 5.5 usó `x-dead-letter-exchange: ""`. ¿Qué exchange es ese, y por qué la routing key tiene que ser el nombre exacto de la cola en ese caso?
5. Tres cosas deben cumplirse todas para que un mensaje sobreviva al reinicio de un broker. Nómbralas.
6. Se configuró `x-max-length: 1000` en `billing`. Cuando se alcanza el límite, ¿qué mensaje se descarta — el más viejo o el más nuevo — y cuál es el comportamiento alternativo que puedes configurar?

---

## 6. Log de mensajes — particiones, offsets y replay (Apache Kafka)

Un broker borra un mensaje una vez que fue confirmado. Un log lo conserva durante un período de retención y permite que cada grupo de consumidores lo lea de forma independiente. Esa diferencia es todo el ejercicio.

**Paso 6.1** — Crea un topic con tres particiones y descríbelo:

```bash
docker compose exec kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 \
  --create --topic orders --partitions 3 --replication-factor 1

docker compose exec kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 \
  --describe --topic orders
```

```
Topic: orders	PartitionCount: 3	ReplicationFactor: 1	Configs:
	Topic: orders	Partition: 0	Leader: 1	Replicas: 1	Isr: 1
	Topic: orders	Partition: 1	Leader: 1	Replicas: 1	Isr: 1
	Topic: orders	Partition: 2	Leader: 1	Replicas: 1	Isr: 1
```

**Paso 6.2** — Produce registros con clave. La clave decide la partición, y la partición es la única garantía de orden que te da Kafka:

```bash
docker compose exec -T kafka /opt/kafka/bin/kafka-console-producer.sh \
  --bootstrap-server localhost:9092 --topic orders \
  --property parse.key=true --property key.separator=: <<'EOF'
cust-1:{"order":101,"state":"created"}
cust-2:{"order":102,"state":"created"}
cust-1:{"order":101,"state":"paid"}
cust-3:{"order":103,"state":"created"}
cust-1:{"order":101,"state":"shipped"}
EOF
```

**Paso 6.3** — Lee todo desde el principio, mostrando clave y partición:

```bash
docker compose exec kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 --topic orders --from-beginning \
  --property print.key=true --property print.partition=true --property print.offset=true \
  --timeout-ms 5000
```

```
Partition:1	Offset:0	cust-1	{"order":101,"state":"created"}
Partition:1	Offset:1	cust-1	{"order":101,"state":"paid"}
Partition:1	Offset:2	cust-1	{"order":101,"state":"shipped"}
Partition:0	Offset:0	cust-2	{"order":102,"state":"created"}
Partition:2	Offset:0	cust-3	{"order":103,"state":"created"}
[2026-09-18 11:40:12,004] ERROR Error processing message, terminating consumer process:  (kafka.tools.ConsoleConsumer$)
org.apache.kafka.common.errors.TimeoutException
Processed a total of 5 messages
```

El `TimeoutException` es `--timeout-ms` haciendo su trabajo; la línea "Processed a total of 5 messages" es el resultado.

**Paso 6.4** — Lee como un consumer group, y después inspecciona los offsets confirmados:

```bash
docker compose exec kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 --topic orders --from-beginning \
  --group billing --timeout-ms 5000

docker compose exec kafka /opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 --describe --group billing
```

```
GROUP    TOPIC   PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG  CONSUMER-ID  HOST  CLIENT-ID
billing  orders  0          1               1               0    -            -     -
billing  orders  1          3               3               0    -            -     -
billing  orders  2          1               1               0    -            -     -
```

**Paso 6.5** — Ejecuta el mismo consumidor otra vez: no devuelve nada. Después rebobina el grupo y vuelve a ejecutarlo — los mismos cinco registros regresan:

```bash
docker compose exec kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 --topic orders --group billing --timeout-ms 5000

docker compose exec kafka /opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 --group billing --topic orders \
  --reset-offsets --to-earliest --execute

docker compose exec kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 --topic orders --group billing --timeout-ms 5000
```

**Paso 6.6** — Agrega un segundo grupo independiente y confirma que arranca desde cero sin afectar a `billing`:

```bash
docker compose exec kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 --topic orders --from-beginning \
  --group analytics --timeout-ms 5000

docker compose exec kafka /opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 --list
```

**Paso 6.7** — Cambia la retención, y crea un topic compactado:

```bash
docker compose exec kafka /opt/kafka/bin/kafka-configs.sh --bootstrap-server localhost:9092 \
  --entity-type topics --entity-name orders --alter --add-config retention.ms=60000

docker compose exec kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 \
  --create --topic customer-state --partitions 3 --replication-factor 1 \
  --config cleanup.policy=compact --config min.cleanable.dirty.ratio=0.01

docker compose exec kafka /opt/kafka/bin/kafka-configs.sh --bootstrap-server localhost:9092 \
  --entity-type topics --entity-name customer-state --describe
```

**Preguntas 6**

1. Los tres registros de `cust-1` cayeron en la partición 1, en orden. Indica el mecanismo, y después indica exactamente qué garantía de orden tienes entre `cust-1` y `cust-2`.
2. Ejecutas 5 instancias de consumidor en el grupo `billing` contra este topic de 3 particiones. ¿Cuántas hacen trabajo útil, y cuál es la regla que lo decide?
3. En el paso 6.5 la segunda ejecución no devolvió nada aunque los datos seguían en disco. ¿Dónde se guarda el estado de "ya leído", y por qué eso es arquitectónicamente distinto del acknowledgement de RabbitMQ?
4. El paso 6.7 puso `retention.ms=60000` en un topic que `analytics` quizá aún no consumió. Describe el fallo y la excepción que terminará viendo el consumidor rezagado.
5. `cleanup.policy=compact` conserva el último registro por clave para siempre. Da una cosa para la que ahora puede usarse ese topic y que uno con retención por tiempo no puede, y di qué significa ahí un registro con valor `null`.
6. El servicio `kafka` no publica puertos. Si mapeas `9092:9092` y conectas un cliente desde el host, la petición de metadatos tiene éxito y luego el productor se cuelga. Nombra el ajuste del broker responsable y explica la conexión en dos pasos que hacen los clientes de Kafka.

---

## 7. Procesamiento de big data (Apache Spark)

**Paso 7.1** — Arranca una shell de PySpark en modo local, con la UI de Spark expuesta y el directorio del laboratorio montado:

```bash
docker run --rm -it -u root -p 4040:4040 -v "$PWD/lab-data:/data:z" \
  spark:3.5.1-python3 /opt/spark/bin/pyspark
```

> Si tu mirror de registry no tiene esa etiqueta, `spark:python3` resuelve a la build actual habilitada para Python.

```
Welcome to
      ____              __
     / __/__  ___ _____/ /__
    _\ \/ _ \/ _ `/ __/  '_/
   /__ / .__/\_,_/_/ /_/\_\   version 3.5.1
      /_/

Using Python version 3.11.x
Spark context Web UI available at http://...:4040
SparkSession available as 'spark'.
```

**Paso 7.2** — Genera dos millones de eventos sintéticos y escríbelos como CSV:

```python
from pyspark.sql import functions as F

events = (spark.range(0, 2000000)
    .withColumn("user_id", (F.rand(seed=42) * 10000).cast("int"))
    .withColumn("country", F.element_at(
        F.array(F.lit("ar"), F.lit("br"), F.lit("de"), F.lit("us")),
        (F.rand(seed=7) * 4 + 1).cast("int")))
    .withColumn("amount_cents", (F.rand(seed=13) * 50000).cast("long")))

events.write.mode("overwrite").option("header", True).csv("/data/events_csv")
```

**Paso 7.3** — Vuelve a leerlos y ejecuta una agregación:

```python
df = spark.read.option("header", True).option("inferSchema", True).csv("/data/events_csv")
df.count()

(df.groupBy("country")
   .agg(F.count("*").alias("events"), F.sum("amount_cents").alias("total_cents"))
   .orderBy(F.desc("total_cents"))
   .show())
```

```
+-------+------+-----------+
|country|events|total_cents|
+-------+------+-----------+
|     us|500213|12503991284|
|     de|499812|12491020117|
|     br|500104|12498773905|
|     ar|499871|12489330442|
+-------+------+-----------+
```

**Paso 7.4** — Mira el plan físico y encuentra el shuffle:

```python
(df.groupBy("country")
   .agg(F.sum("amount_cents"))
   .explain())
```

```
== Physical Plan ==
AdaptiveSparkPlan isFinalPlan=false
+- HashAggregate(keys=[country#23], functions=[sum(amount_cents#24L)])
   +- Exchange hashpartitioning(country#23, 200), ENSURE_REQUIREMENTS
      +- HashAggregate(keys=[country#23], functions=[partial_sum(amount_cents#24L)])
         +- FileScan csv [country#23,amount_cents#24L] Batched: false, ...
```

**Paso 7.5** — Escribe los mismos datos como Parquet particionado y compara los planes:

```python
df.write.mode("overwrite").partitionBy("country").parquet("/data/events_parquet")

pq = spark.read.parquet("/data/events_parquet")
pq.filter("country = 'ar'").filter("amount_cents > 49000").explain()
```

```
== Physical Plan ==
*(1) Filter (isnotnull(amount_cents#61L) AND (amount_cents#61L > 49000))
+- *(1) ColumnarToRow
   +- FileScan parquet [id#59L,user_id#60,amount_cents#61L,country#62]
        PartitionFilters: [isnotnull(country#62), (country#62 = ar)],
        PushedFilters: [IsNotNull(amount_cents), GreaterThan(amount_cents,49000)],
        ReadSchema: struct<id:bigint,user_id:int,amount_cents:bigint>
```

**Paso 7.6** — Deja la shell abierta, y desde el host compara las dos disposiciones en disco:

```bash
du -sh lab-data/events_csv lab-data/events_parquet
ls lab-data/events_parquet
```

```
612M	lab-data/events_csv
 84M	lab-data/events_parquet
_SUCCESS  country=ar  country=br  country=de  country=us
```

**Paso 7.7** — Abre `http://localhost:4040` en un navegador mientras corre un job. Dispara uno y observa las etapas:

```python
df.groupBy("user_id").count().orderBy(F.desc("count")).limit(5).collect()
```

En las pestañas **SQL / DataFrame** y **Stages**, encuentra el límite de etapa y los tamaños de lectura/escritura del shuffle. Sal de la shell con `Ctrl-D`.

**Preguntas 7**

1. `spark.range(...).withColumn(...)` retornó al instante; `df.count()` tardó segundos. Nombra el modelo de evaluación y di cuáles de las llamadas de los pasos 7.2 y 7.3 fueron acciones.
2. En el plan aparece `Exchange hashpartitioning(country, 200)`. ¿Qué ocurre físicamente en esa línea, por qué es lo más caro en la mayoría de los jobs de Spark, y de dónde sale el número 200?
3. Parquet fue 7× más pequeño *y* además produjo `PushedFilters` y `PartitionFilters` donde CSV no produjo ninguno. Explica ambos beneficios a partir de la misma propiedad subyacente del formato.
4. `partitionBy("country")` creó cuatro directorios. ¿Qué sale mal si en cambio haces `partitionBy("user_id")`, y cómo se llama ese antipatrón?
5. En el paso 7.3 se usó `inferSchema`. ¿Qué cuesta, y qué haces en su lugar en un pipeline de producción?
6. Esto corrió en modo local sin ningún clúster. Nombra los tres roles de un despliegue real de Spark y di cuál de ellos estaba desempeñando tu proceso `/opt/spark/bin/pyspark`.
7. Aquí Spark procesó un conjunto de datos acotado. Enuncia en una línea la diferencia entre esto y aquello para lo que está construido Apache Flink, y nombra el componente de plataforma del Ejercicio 6 que lo alimentaría.

---

## 8. OAuth 2.0 y OpenID Connect (Keycloak)

OAuth 2.0 es **autorización delegada**: un access token dice que un cliente puede llamar a una API. OpenID Connect es una capa fina de identidad encima: un ID token dice *quién es el usuario*. Confundir ambos es el error de producción más común en esta área.

**Paso 8.1** — Lee el documento de discovery. Todo lo demás en este ejercicio es una URL que sale de él:

```bash
curl -s http://localhost:8080/realms/master/.well-known/openid-configuration \
  | jq '{issuer, token_endpoint, authorization_endpoint, jwks_uri, grant_types_supported, code_challenge_methods_supported}'
```

```
{
  "issuer": "http://localhost:8080/realms/master",
  "token_endpoint": "http://localhost:8080/realms/master/protocol/openid-connect/token",
  "authorization_endpoint": "http://localhost:8080/realms/master/protocol/openid-connect/auth",
  "jwks_uri": "http://localhost:8080/realms/master/protocol/openid-connect/certs",
  "grant_types_supported": [
    "authorization_code",
    "refresh_token",
    "client_credentials",
    "urn:ietf:params:oauth:grant-type:device_code"
  ],
  "code_challenge_methods_supported": [
    "plain",
    "S256"
  ]
}
```

**Paso 8.2** — Crea un realm, un cliente de servicio confidencial, y un cliente público de navegador que exija PKCE:

```bash
docker compose exec keycloak /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 --realm master --user admin --password admin

docker compose exec keycloak /opt/keycloak/bin/kcadm.sh create realms \
  -s realm=devops -s enabled=true

docker compose exec keycloak /opt/keycloak/bin/kcadm.sh create clients -r devops \
  -s clientId=orders-api -s publicClient=false -s serviceAccountsEnabled=true \
  -s standardFlowEnabled=false -s secret=s3cr3t-orders

docker compose exec keycloak /opt/keycloak/bin/kcadm.sh create clients -r devops \
  -s clientId=portal-ui -s publicClient=true -s standardFlowEnabled=true \
  -s 'redirectUris=["http://localhost:3000/callback"]' \
  -s 'attributes."pkce.code.challenge.method"=S256'

docker compose exec keycloak /opt/keycloak/bin/kcadm.sh create users -r devops \
  -s username=ana -s enabled=true -s email=ana@example.com -s emailVerified=true

docker compose exec keycloak /opt/keycloak/bin/kcadm.sh set-password -r devops \
  --username ana --new-password 'Passw0rd!'
```

> Pon `'Passw0rd!'` entre comillas simples: en una shell bash interactiva, `!` dentro de comillas dobles dispara la expansión de historial.

**Paso 8.3** — Máquina a máquina: el grant `client_credentials`, que no tiene usuario alguno:

```bash
AT=$(curl -s -X POST http://localhost:8080/realms/devops/protocol/openid-connect/token \
  -d grant_type=client_credentials \
  -d client_id=orders-api \
  -d client_secret=s3cr3t-orders | jq -r .access_token)

echo "${AT:0:40}..."
```

**Paso 8.4** — Decodifica el token. Un JWT es base64url, no base64 — decodifícalo correctamente:

```bash
decode() {
  python3 -c "import sys,base64,json; p=sys.argv[1].split('.')[int(sys.argv[2])]; \
print(json.dumps(json.loads(base64.urlsafe_b64decode(p + '=' * (-len(p) % 4))), indent=2))" "$1" "$2"
}

decode "$AT" 0     # header
decode "$AT" 1     # payload
```

```
{
  "alg": "RS256",
  "typ": "JWT",
  "kid": "rF8k2QpVn3YtLc0aHs7xJdWmB1oEuZgN9iKvTr4XyPc"
}
```

```
{
  "exp": 1789740123,
  "iat": 1789739823,
  "jti": "5a0c3b71-90e2-4f1c-8d44-6b2e19a7c0fd",
  "iss": "http://localhost:8080/realms/devops",
  "aud": "account",
  "sub": "c9b1f2a4-7d33-4e58-9ac0-1f7b6d2e8a35",
  "typ": "Bearer",
  "azp": "orders-api",
  "scope": "email profile",
  "clientId": "orders-api",
  "preferred_username": "service-account-orders-api"
}
```

**Paso 8.5** — Obtén las claves de firma que la API usaría para verificar ese token sin conexión, y haz coincidir el `kid`:

```bash
curl -s http://localhost:8080/realms/devops/protocol/openid-connect/certs \
  | jq '.keys[] | {kid, kty, alg, use}'
```

**Paso 8.6** — Verifica el token por la otra vía, en el endpoint de introspección (RFC 7662):

```bash
curl -s -u orders-api:s3cr3t-orders \
  -X POST http://localhost:8080/realms/devops/protocol/openid-connect/token/introspect \
  -d "token=$AT" | jq '{active, exp, client_id, scope, token_type}'

curl -s -u orders-api:s3cr3t-orders \
  -X POST http://localhost:8080/realms/devops/protocol/openid-connect/token/introspect \
  -d "token=not.a.real.token" | jq .
```

```
{
  "active": true,
  "exp": 1789740123,
  "client_id": "orders-api",
  "scope": "email profile",
  "token_type": "Bearer"
}
```

```
{
  "active": false
}
```

**Paso 8.7** — Ahora el flujo orientado al usuario: Authorization Code con PKCE (RFC 7636). Construye el verifier y el challenge:

```bash
VERIFIER=$(openssl rand -base64 60 | tr -d '\n=' | tr '/+' '_-')
CHALLENGE=$(printf '%s' "$VERIFIER" | openssl dgst -binary -sha256 | openssl base64 | tr -d '\n=' | tr '/+' '_-')
echo "verifier:  $VERIFIER"
echo "challenge: $CHALLENGE"
```

**Paso 8.8** — Arranca un listener para poder leer la redirección, después abre la URL de autorización en un navegador e inicia sesión como `ana` / `Passw0rd!`:

```bash
python3 -m http.server 3000 &

echo "http://localhost:8080/realms/devops/protocol/openid-connect/auth?client_id=portal-ui&response_type=code&scope=openid%20profile%20email&redirect_uri=http://localhost:3000/callback&state=xyz123&code_challenge=${CHALLENGE}&code_challenge_method=S256"
```

El listener registra la redirección:

```
127.0.0.1 - - [18/Sep/2026 12:31:09] "GET /callback?state=xyz123&session_state=...&code=8f3c...a1 HTTP/1.1" 404 -
```

**Paso 8.9** — Intercambia el code por tokens, aportando el verifier:

```bash
CODE='<paste the code value here>'

curl -s -X POST http://localhost:8080/realms/devops/protocol/openid-connect/token \
  -d grant_type=authorization_code \
  -d client_id=portal-ui \
  -d code="$CODE" \
  -d redirect_uri=http://localhost:3000/callback \
  -d code_verifier="$VERIFIER" | jq 'keys'
```

```
[
  "access_token",
  "expires_in",
  "id_token",
  "not-before-policy",
  "refresh_expires_in",
  "refresh_token",
  "scope",
  "session_state",
  "token_type"
]
```

**Paso 8.10** — Repite el paso 8.9 con un `code_verifier` incorrecto (cambia un carácter), y con el mismo code dos veces. Registra ambos errores. Después decodifica el `id_token` y compara sus claims con los del `access_token`:

```bash
kill %1   # stop the http.server
```

**Preguntas 8**

1. `orders-api` usó `client_credentials`; `portal-ui` usó `authorization_code`. Enuncia la regla que decide qué grant le toca a cada componente, y di por qué `portal-ui` no tiene client secret.
2. PKCE protege contra un ataque específico. Descríbelo concretamente — ¿qué roba el atacante, y qué le impide usarlo?
3. Decodificaste el JWT con `base64.urlsafe_b64decode`. ¿Qué tiene de inseguro *decodificar* un token para confiar en su contenido, y cuáles son las cuatro cosas que un servidor de recursos debe verificar antes de aceptarlo?
4. El paso 8.5 (JWKS, verificación offline) y el paso 8.6 (introspección) validan ambos un token. Da el compromiso de cada uno en una oración, y di cuál eliges para una API de 10 000 rps y cuál para un endpoint de transferencia bancaria.
5. Ambos tokens del paso 8.10 vinieron de la misma respuesta. ¿Cuál envías a `orders-api` en la cabecera `Authorization`, cuál no debe salir jamás del cliente, y cuál es el papel del claim `aud` en esa distinción?
6. Reutilizar un authorization code falla. ¿Qué amenaza de OAuth aborda la aplicación de un solo uso, y qué debería hacer un servidor de autorización correcto con los tokens ya emitidos para ese code?
7. El issuer aquí es `http://localhost:8080/...`. Nombra tres cosas que deben cambiar antes de que esta configuración sea aceptable en producción.

---

## 9. Ejercicio de diseño — ubicando los componentes

Sin comandos. Lee el escenario y escribe tu respuesta antes de abrir la clave.

> Una plataforma de ticketing vende asientos para eventos en vivo. El pico de tráfico es 40× la línea base durante los diez minutos en que un evento popular sale a la venta. Requisitos: (a) un asiento nunca puede venderse dos veces; (b) cada compra debe enviar un correo de confirmación, actualizar un saldo de fidelidad y alimentar un modelo de fraude, y agregar un cuarto consumidor más adelante no debe requerir tocar el código de compra; (c) los usuarios suben vouchers en PDF y escaneos de documentos de identidad, retenidos siete años, auditables; (d) el negocio quiere tableros horarios de ingresos por sede sobre dos años de historia; (e) las boleterías socias llaman a una API REST en nombre de sí mismas, y los usuarios finales inician sesión a través de una aplicación web; (f) el mapa de asientos de un evento se lee miles de veces por segundo y cambia rara vez.

**Preguntas 9**

1. Asigna una familia de componentes de este objetivo a cada uno de los puntos (a) a (f), y nombra una implementación concreta para cada uno.
2. Para (a), indica qué tecnología *no* usarías y por qué, refiriéndote a un resultado específico del Ejercicio 2 o 4.
3. Para (b), justifica la elección entre un broker de mensajes y un log de mensajes usando la última cláusula del requisito (b).
4. Para (d), explica por qué el tablero no debería consultar el mismo almacén que (a).
5. Para (e), nombra los dos grants de OAuth involucrados y cuál obtiene un ID token.
6. Para (f), describe la estrategia de invalidación de caché y qué le pasa a la corrección si la caché se pierde por completo durante el pico de venta.

---

## 10. Limpieza

```bash
cd ~/lab-701.2
docker compose down -v
docker image rm spark:3.5.1-python3 2>/dev/null
rm -f rabbitmqadmin
```

`-v` elimina los volúmenes con nombre; sin él, `minio-data`, `pg-data`, `mongo-data` y `mc-config` sobreviven y el siguiente `up` arranca con el estado anterior.

---

<details>
<summary><strong>Respuestas</strong></summary>

#### Respuestas 0

1. Un servicio con una clave `profiles` queda excluido de `up` salvo que el perfil esté activado. Se ejecuta bajo demanda con `docker compose run --rm mc <args>`, que levanta sus servicios de `depends_on` y luego corre el contenedor con `mc` como entrypoint y tus argumentos anexados. Este es el patrón estándar para contenedores de administración/herramientas de un solo disparo en un stack de Compose.
2. Keycloak 26 renombró las variables de bootstrap a `KC_BOOTSTRAP_ADMIN_USERNAME` / `KC_BOOTSTRAP_ADMIN_PASSWORD`; los nombres viejos todavía funcionan pero están obsoletos y se eliminarán. Con una etiqueta flotante como `:latest`, el contenedor que funcionaba ayer deja de crear silenciosamente el usuario admin después de una release upstream, y tu único síntoma es un fallo de login — nada cambió en tu repositorio, así que `git bisect` no encuentra nada. Este es el argumento para fijar digests de imagen o, al menos, versiones exactas en todos los entornos.
3. La imagen `apache/kafka` por defecto anuncia `PLAINTEXT://localhost:9092`, que solo tiene sentido dentro del contenedor. Publicar el puerto te dejaría abrir una conexión TCP, pero el broker le devolvería al cliente una dirección inalcanzable. Por eso el laboratorio maneja Kafka con `docker compose exec`, y la pregunta 6.6 hace explícita la trampa.

#### Respuestas 1

1. Existen tres *versiones* de objeto y las tres son facturables; `mc ls` muestra una sola entrada, porque un listado simple devuelve solo la versión actual de cada clave. A lo largo de un año, un job que reescribe la misma clave cada hora acumula ~8 800 versiones de datos que no ves en la consola y que estás pagando. La solución es una regla de ciclo de vida que expire las versiones no actuales después de N días (`mc ilm rule add --noncurrent-expire-days 30`).
2. SigV4 firma una petición canónica que incluye la cabecera `Host`. Cambiar el nombre de host cambia la cadena que se firmó, así que la firma calculada ya no coincide y obtienes `SignatureDoesNotMatch`. El arreglo correcto para producción es definir `MINIO_SERVER_URL` (y `MINIO_BROWSER_REDIRECT_URL`) al nombre de host público que los clientes realmente usan, para que MinIO firme las URLs prefirmadas para ese nombre y no para el interno.
3. Leer un rango de bytes es posible — eso es la cabecera `Range` y el `206` que viste, y es la razón por la que Parquet funciona bien sobre almacenamiento de objetos. Agregar (append) no es posible: no hay escritura parcial; la única forma de "agregar" es leer el objeto completo, modificarlo, y hacer PUT de vuelta entero. Reemplazar el objeto completo sí es posible y es lo que hizo la tercera subida del paso 1.3.
4. Un sufijo como `-4` significa que el objeto se subió como multipart upload en 4 partes, y el ETag es el MD5 de los MD5 de las partes concatenados, vuelto a hashear — no el MD5 del contenido del archivo. Cualquier verificación de integridad que calcule `md5sum localfile` y lo compare con el ETag reportará una discrepancia falsa para todos los objetos grandes. Usa checksums (`x-amz-checksum-sha256`) o compara tamaños más tu propio digest almacenado.
5. El modo `GOVERNANCE` permite que un principal con el permiso `s3:BypassGovernanceRetention` acorte o quite el bloqueo. Lo quieres cuando la retención es una red de seguridad contra borrados accidentales y errores operativos más que un requisito regulatorio — por ejemplo, un bloqueo de 7 días sobre objetos de backup que un equipo de plataforma debe poder limpiar ocasionalmente. `COMPLIANCE` es para retención regulatoria, donde "nadie, nunca" es justamente el punto.
6. Primero, latencia y modelo de costo: el almacenamiento de objetos cobra y está optimizado por petición, con decenas de milisegundos por GET; la búsqueda de sesión ocurre en cada petición y necesita lecturas por debajo del milisegundo. Segundo, no hay expiración por TTL en el camino de datos ni lectura-modificación-escritura atómica, así que mutar la sesión es una carrera de actualización perdida y la expiración se convierte en un barrido de ciclo de vida que corre una vez al día. El precio de almacenamiento por GB es irrelevante cuando los objetos son de 2 KB y el patrón de acceso es de 50 000 rps.

#### Respuestas 2

1. Se violó el aislamiento (específicamente, el nivel por defecto `READ COMMITTED` lo permite); atomicidad, consistencia y durabilidad se respetaron todas — cada transacción fue atómica, no se rompió ninguna restricción, y ambos commits son durables. La anomalía se llama **actualización perdida** (lost update).
2. La aplicación ahora debe capturar SQLSTATE `40001` (`serialization_failure`) y **reintentar la transacción completa**, desde la primera sentencia, porque el snapshot que leyó ya no existe. Eso es una decisión de diseño porque el reintento debe ser seguro: el cuerpo de la transacción tiene que ser idempotente, o el reintento tiene que releer todo lo que calcula. No puedes agregar esto a último momento cambiando un flag de configuración en producción y cruzando los dedos.
3. `balance = balance - 100` relee el valor actual de la fila *dentro del UPDATE*, bajo un bloqueo de fila. En `READ COMMITTED`, cuando una transacción concurrente confirma una actualización sobre esa fila, el UPDATE bloqueado reevalúa su cláusula `WHERE` y su expresión contra la nueva versión de la fila. El valor 900 de la versión rota lo calculó el *cliente* a partir de una lectura obsoleta, y la base de datos no tiene forma de saber que derivaba de datos que cambiaron desde entonces.
4. `idle in transaction` mantiene bloqueos y, peor, retiene el snapshot de la transacción más antigua: `VACUUM` no puede eliminar tuplas muertas más nuevas que él, así que el bloat de tablas crece en toda la base de datos mientras esa sesión está ahí sentada — una fuga de conexión en un servicio degrada a todos los demás. Los dos ajustes son `idle_in_transaction_session_timeout` (mata la sesión) y `statement_timeout` (acota cualquier sentencia individual); `log_min_duration_statement` te da la evidencia.
5. Aproximadamente cuando la consulta devuelve más que un pequeño porcentaje de la tabla. Por encima de eso, la E/S aleatoria a través del índice más una lectura del heap por fila cuesta más que leer la tabla secuencialmente, y el planificador elige correctamente el recorrido secuencial. No es un bug — es el modelo de costos funcionando. Se convierte en un bug cuando las estadísticas están desactualizadas, que es la razón por la que se ejecutó `ANALYZE` antes de `EXPLAIN`.
6. 40 × 20 = 800 conexiones solicitadas contra un techo de 100, así que los pods fallan con `FATAL: sorry, too many clients already` — y subir `max_connections` es el arreglo equivocado, porque cada backend de PostgreSQL es un proceso con su propia memoria y el servidor se degrada mal mucho antes de 800. Pon un pooler de conexiones delante — **PgBouncer** en modo transaction pooling (o `pgpool-II`), que multiplexa cientos de conexiones de cliente sobre unas pocas decenas de conexiones de servidor.

#### Respuestas 3

1. La maquinaria de transacciones y rollback de MongoDB está construida sobre el **oplog** y sobre read/write concerns de mayoría, que solo existen en un replica set; un `mongod` standalone no tiene oplog, así que no hay mecanismo para avanzar o revertir consistentemente un commit multidocumento. La garantía de durabilidad vive, por lo tanto, en la **replicación**, no en la escritura de un solo nodo — que es exactamente lo que expresa `w: "majority"`.
2. `rs.initiate()` registró el miembro como `mongo:27017`. Un driver se conecta al seed, recibe la topología del replica set, y después se conecta a los miembros *por los nombres de esa topología* — `mongo` no resuelve en tu host. El arreglo es usar un nombre resoluble por todos los clientes. Es la misma razón por la que un StatefulSet necesita un Service headless: cada réplica debe tener un nombre DNS estable que sea válido desde donde vivan los clientes.
3. `strict` aplica el validador a **todas las inserciones y todas las actualizaciones**, incluidas las actualizaciones de documentos que ya eran inválidos — así que un documento heredado sin `price` ya no puede modificarse en absoluto, ni siquiera con una actualización que no tenga nada que ver con `price`. Durante una migración usas `validationLevel: "moderate"`, que aplica las reglas a las inserciones y a las actualizaciones de documentos *ya válidos*, permitiéndote arreglar los viejos progresivamente. `validationAction: "warn"` (registrar, no rechazar) es el primer paso aún más suave.
4. Integridad referencial entre colecciones (no hay `FOREIGN KEY`, ni comportamiento en cascada) y restricciones entre documentos/filas, como un `UNIQUE` sobre una combinación que abarca varias tablas, restricciones `EXCLUDE`, o un `CHECK` que compara contra un agregado. `$jsonSchema` valida un documento en aislamiento; no puede expresar una relación entre documentos.
5. `w: 1` es correcto para una colección de alto volumen, bajo valor y regenerable — un log de clics/telemetría donde perder las últimas escrituras en un failover del primario es aceptable y la tasa de escritura hace caro el acknowledgement de mayoría. Es negligencia en cualquier cosa que represente dinero o una acción irreversible: una orden, un pago, un decremento de stock. Perder un decremento de stock en un failover sobrevende el producto.
6. La señal es la **localidad de agregado**: la entidad se lee y se escribe como un todo, su estructura anidada varía legítimamente por instancia (el subdocumento `specs` difiere según la categoría de producto), y casi nunca necesitas unirla con algo más ni consultar entre instancias sobre un campo que no todas tienen. La contraseñal es que te encuentres haciendo `$lookup` habitualmente, o que dos clientes no se pongan de acuerdo sobre qué significa un campo — en ese punto tienes un esquema relacional escrito dentro de un almacén de documentos, y PostgreSQL (con `jsonb` para la parte genuinamente variable) te servirá mejor.

#### Respuestas 4

1. `maxmemory-policy`. Con `allkeys-lru` Redis descarta claves silenciosamente bajo presión, lo cual es correcto para una caché y catastrófico para un sistema de registro. Con `noeviction`, Redis deja de aceptar escrituras y devuelve `OOM command not allowed when used memory > 'maxmemory'` a cada escritura mientras sigue sirviendo lecturas — tus datos sobreviven pero tu aplicación empieza a dar errores, que es el intercambio correcto para una cola o un almacén de locks y el equivocado para una caché.
2. `SETNX` y luego `EXPIRE` son dos viajes de ida y vuelta: si el cliente se cae entre ambos, el lock existe sin TTL y queda retenido para siempre — el deadlock que intentabas evitar. `SET ... NX PX` es un único comando atómico. El token importa al liberar: debes borrar la clave **solo si todavía contiene tu token**, o de lo contrario un worker cuyo lock expiró a mitad del trabajo borrará el lock que un segundo worker adquirió legítimamente. La liberación debe ser un script Lua que haga comparar-y-borrar, ya que `GET` y luego `DEL` tiene la misma carrera.
3. `MONITOR` transmite a tu cliente cada comando procesado por el servidor, lo que puede costar una fracción grande del throughput en una instancia ocupada (la documentación mide un impacto de ~50 %) y filtra cada clave y cada valor, incluidos tokens de sesión, a quien esté mirando. `DEBUG POPULATE` escribe cientos de miles de claves en el keyspace en vivo, lo que bajo `allkeys-lru` expulsa tu working set real y destruye la tasa de aciertos hasta que vuelve a calentarse.
4. Por debajo del umbral, un hash se almacena como un `listpack` — una codificación contigua y compacta con búsqueda O(n) sobre un puñado de entradas, que es más rápida y mucho más pequeña que una tabla hash real a ese tamaño. Pasado `hash-max-listpack-entries` (o `hash-max-listpack-value` para un valor largo), Redis lo convierte en un `hashtable`: las búsquedas pasan a ser O(1) pero la memoria por campo se multiplica varias veces, y la conversión es de ida para esa clave. Muchos hashes pequeños son dramáticamente más baratos que uno grande.
5. Se pierde todo desde el último snapshot RDB — y con `--appendonly no` más ningún punto `save` configurado en la línea de comandos de la imagen, potencialmente *todo* lo que está en memoria, ya que `BGSAVE` solo corrió porque lo escribiste. Las sesiones y el contador de vistas de página son pérdidas aceptables (los usuarios vuelven a autenticarse; las métricas tienen huecos). El carrito no lo es: perderlo es un bug visible para el usuario y una venta perdida, así que pertenece a un almacén durable, con Redis usado solo como caché de lectura.
6. Acknowledgement por mensaje con reentrega (si un consumidor muere a mitad del trabajo, `BRPOP` ya quitó el elemento y se perdió; AMQP lo vuelve a encolar), y enrutamiento/topología — una publicación que alcanza varias colas independientes mediante bindings, más dead-lettering para mensajes venenosos. Redis Streams cierra parte de esta brecha con consumer groups y `XACK`, pero una lista simple no te da ninguna de las dos.

#### Respuestas 5

1. La publicación llevó la routing key `order.cancelled` al topic exchange `orders`. El broker la comparó con cada binding: `order.created` no coincidió, `order.#` sí (`#` coincide con cero o más palabras separadas por puntos). Así que una copia fue a `audit` y ninguna a `billing`. `order.*` coincide con exactamente una palabra, así que también habría coincidido con `order.cancelled` pero **no** con una clave de tres palabras como `order.payment.failed`, que `order.#` sí hace coincidir.
2. Los **publisher confirms** (`confirm.select`), que le dicen al productor que el broker se hizo responsable del mensaje, y el flag **mandatory**, que hace que el broker devuelva al productor un mensaje no enrutable vía `basic.return` en vez de descartarlo. Los confirms por sí solos no ayudan aquí: un mensaje confirmado pero no enrutable está confirmado como *descartado* exitosamente.
3. Los argumentos de una cola son parte de su identidad, y redeclarar una cola existente con argumentos distintos es un error en vez de una mutación. Es un buen error porque la alternativa — aceptar silenciosamente los nuevos argumentos, o ignorarlos silenciosamente — significa que dos servicios que declaran la misma cola con TTLs o ajustes de DLX distintos pelearían, y cuál gana dependería del orden de arranque. Fallar ruidosamente en el momento de la declaración es mucho mejor que una cola cuyo comportamiento depende de quién arrancó último.
4. `""` es el **default exchange**, un direct exchange al que cada cola está vinculada automáticamente usando su propio nombre como routing key. Por eso hacer dead-lettering hacia él exige que `x-dead-letter-routing-key` sea exactamente el nombre de la cola destino — no hay otro binding con el que coincidir. Usar un DLX con nombre y bindings explícitos es el patrón más mantenible en cuanto tienes más de una DLQ.
5. El exchange debe ser durable, la cola debe ser durable, y el mensaje debe publicarse como persistente (`delivery_mode: 2`). Que falte cualquiera de los tres pierde el mensaje al reiniciar — que es por lo que el mensaje `transient` del paso 5.7 desapareció y el `persistent` no. (Aun así, un mensaje puede perderse en la ventana entre la aceptación y el volcado a disco a menos que uses publisher confirms y quorum queues).
6. Por defecto se descarta el mensaje **más viejo** de la cabeza de la cola para hacer lugar — `x-overflow: drop-head`. La alternativa es `x-overflow: reject-publish`, que rechaza los mensajes nuevos y, con publisher confirms, se lo dice al productor con un `basic.nack` para que pueda aplicar contrapresión en vez de perder historia silenciosamente.

#### Respuestas 6

1. El productor hashea la clave del registro (murmur2 por defecto) módulo la cantidad de particiones, así que la misma clave cae siempre en la misma partición — y Kafka garantiza el orden **dentro de una partición**. Entre `cust-1` y `cust-2` no tienes **ninguna garantía de orden en absoluto**: están en particiones distintas y se consumen de forma independiente y concurrente. El orden en Kafka es por clave, por construcción.
2. Tres hacen trabajo útil; dos quedan ociosos. Una partición se asigna a lo sumo a un consumidor dentro de un grupo, así que el paralelismo del grupo está limitado por la cantidad de particiones. Por eso el número de particiones es una decisión de capacidad que se toma por adelantado — puedes aumentarlo después, pero hacerlo cambia el mapeo clave→partición y rompe el orden por clave a través del cambio.
3. En el topic interno `__consumer_offsets`, como un offset confirmado por (grupo, topic, partición) — es un marcador, no un borrado. El ack de RabbitMQ elimina el mensaje de la cola: el estado está en el contenido de la cola del broker y se consume destructivamente, así que un segundo lector no puede obtenerlo. Los datos de Kafka son inmutables y compartidos; el consumidor es dueño de su posición, que es exactamente lo que hace posible el replay y múltiples consumidores independientes.
4. Una vez que un segmento es más viejo que `retention.ms`, el broker lo borra sin importar quién lo haya leído. Un consumidor cuyo offset confirmado apunta a un segmento borrado obtiene `OffsetOutOfRangeException`, y después se comporta según `auto.offset.reset` — saltando silenciosamente a `latest` (omitiendo todos los datos no leídos sin que nadie note un error) o releyendo desde `earliest` (reprocesando todo). Monitorear el **lag del consumidor** contra la retención es lo que previene esto.
5. Puede usarse como un **changelog / snapshot de estado** que una nueva instancia de servicio reproduce desde el offset 0 para reconstruir el estado actual completo de cada cliente — una vista materializada, o una `KTable` de Kafka Streams. Un registro con valor `null` es una **tombstone**: marca la clave como borrada, y después de `delete.retention.ms` el compactador elimina tanto la tombstone como todos los registros previos de esa clave.
6. `advertised.listeners`. Un cliente se conecta primero a un bootstrap server y pide los metadatos del clúster; el broker responde con la dirección *anunciada* del líder de cada partición, y el cliente abre entonces una **segunda** conexión a esa dirección para producir o consumir. Si la dirección anunciada es `localhost:9092` y el cliente está en el host, el bootstrap tiene éxito y la segunda conexión va al lugar equivocado. Debes anunciar una dirección alcanzable por el cliente — típicamente dos listeners, uno interno y uno externo, vía `listener.security.protocol.map`.

#### Respuestas 7

1. Evaluación perezosa: las transformaciones construyen un plan lógico y retornan de inmediato; solo una **acción** dispara la ejecución. Las acciones fueron `events.write...csv(...)` en 7.2, y `df.count()` y `.show()` en 7.3. `.explain()` compila el plan sin ejecutarlo, así que tampoco es una acción.
2. En esa línea cada executor escribe sus resultados parciales a disco local, particionados por el hash de `country`, y cada otro executor lee por la red las piezas que le corresponden — un movimiento de datos de todos contra todos. Es caro porque serializa, escribe a disco y cruza la red para potencialmente todo el conjunto de datos, y es un límite de etapa duro, así que nada aguas abajo arranca hasta que termina. 200 es el valor por defecto de `spark.sql.shuffle.partitions` — un número fijo que está mal tanto para conjuntos de datos pequeños como enormes, y por eso Adaptive Query Execution (`AdaptiveSparkPlan` en la salida) lo fusiona en tiempo de ejecución.
3. Parquet es **columnar con estadísticas y codificación por chunk de columna**. La disposición columnar significa que los valores de un mismo tipo quedan juntos, así que la codificación run-length y por diccionario más la compresión lo encogen dramáticamente — la ganancia de tamaño. La misma disposición significa que el lector puede saltarse columnas enteras que no necesita y saltarse row groups cuyas estadísticas min/max excluyen el filtro — la ganancia del pushdown. CSV es texto orientado a filas, sin tipos y sin estadísticas, así que cada consulta debe leer y parsear cada byte.
4. Con ~10 000 valores distintos de `user_id` crearías ~10 000 directorios, cada uno con archivos diminutos — el **problema de los archivos pequeños**. Listar el conjunto de datos se vuelve miles de operaciones de metadatos (brutalmente lento sobre almacenamiento de objetos, donde LIST es una petición HTTP), cada archivo carga la sobrecarga del footer de Parquet que empequeñece su contenido, y el planificador crea una tarea por archivo. Particiona sobre una columna de baja cardinalidad por la que realmente filtres — `country`, o una fecha.
5. `inferSchema` lee los datos una vez extra antes del job real solo para adivinar tipos, duplicando la E/S en cada ejecución; peor, la suposición puede cambiar entre ejecuciones cuando cambian los datos, así que una columna se vuelve silenciosamente un string y la aritmética aguas abajo se rompe. En producción declaras un `StructType` explícito (o lees un formato que lleve su propio esquema, como Parquet o Avro con un schema registry).
6. **Driver** (ejecuta tu programa, construye el plan, agenda tareas), **cluster manager** (YARN, Kubernetes o Spark standalone — asigna recursos), y **executors** (ejecutan tareas y guardan los datos cacheados). En modo `local[*]` tu único proceso `pyspark` es el driver *y* los executors, con hilos haciendo las veces del clúster; por eso no hubo que desplegar nada y por eso los resultados de aquí no dicen nada sobre cómo se comportará el job distribuido.
7. Spark aquí procesó un conjunto de datos **acotado** en lotes; Flink está diseñado para flujos **no acotados** con semántica de tiempo de evento, watermarks para eventos fuera de orden, y operadores continuos con estado — latencia medida en milisegundos en vez de por lote. El componente que lo alimenta es **Kafka**, del Ejercicio 6: el log es la fuente del stream, y los offsets son lo que le permite a Flink hacer checkpoint y recuperarse exactly-once.

#### Respuestas 8

1. La regla: ¿hay un humano frente al teclado cuya identidad y consentimiento importan? Si sí, el cliente actúa *en nombre de un usuario* y usa el flujo de authorization code; si no, el cliente actúa *como sí mismo* y usa `client_credentials`. `portal-ui` no tiene secret porque es un cliente público — su código corre en el navegador, donde cualquier "secreto" es legible por el usuario y por cualquiera que tenga el bundle, así que el protocolo no finge lo contrario y se apoya en PKCE más la coincidencia exacta de redirect URI.
2. **Intercepción del authorization code.** En un cliente móvil o SPA, el code llega vía una redirección que una app maliciosa registrada para el mismo esquema personalizado, o un log/referrer filtrado, puede observar. Sin PKCE el atacante reproduce el code en el endpoint de token y obtiene los tokens. Con PKCE el code queda ligado al SHA-256 de un `code_verifier` aleatorio que el cliente legítimo nunca transmitió hasta el intercambio; el atacante tiene el code y el challenge pero no el verifier, así que el intercambio falla con `invalid_grant`.
3. Decodificar no es verificar — el payload es base64url, no está cifrado, y cualquiera puede falsificar uno editando claims y recodificando, incluso poniendo `"alg": "none"`. Un servidor de recursos debe verificar: (i) la **firma**, contra la clave identificada por `kid` obtenida de JWKS, con el algoritmo fijado a lo que espera; (ii) que el **issuer** `iss` coincida con el servidor de autorización esperado; (iii) que la **audiencia** `aud` incluya a esta API; (iv) que los claims de **tiempo** `exp` y `nbf`/`iat` sean válidos en este momento. Las comprobaciones de scope/roles vienen después de las cuatro.
4. La verificación con JWKS es local y sin estado: ninguna llamada de red por petición, latencia de microsegundos, pero el token sigue siendo válido hasta `exp` aunque haya sido revocado. La introspección le pregunta al servidor de autorización en cada petición: revocación instantánea y política central, al costo de un viaje de red y una dependencia dura de la disponibilidad del AS. Usa verificación local de JWT con tokens de vida corta para la API de 10 000 rps; usa introspección (o como mínimo una comprobación de revocación) para el endpoint de transferencia bancaria, donde que un token robado siga siendo válido los próximos 5 minutos no es aceptable.
5. Envía el **access token** a `orders-api`. El **ID token** nunca debe enviarse a una API como credencial — es prueba de autenticación emitida *para el cliente*, y su `aud` es el client ID, no la API. Ese es exactamente el papel del claim `aud`: nombra al destinatario previsto, y una API que acepta un token cuyo `aud` es otra parte está aceptando una credencial acuñada para otro propósito — la clásica vulnerabilidad del diputado confundido.
6. Replay / intercepción del code (RFC 6749 §10.5 y la Security BCP). Más allá de rechazar el segundo intercambio, un servidor de autorización correcto debe **revocar todos los tokens ya emitidos para ese code**, porque una segunda presentación significa que o el cliente o un atacante lo reprodujo y el servidor no puede distinguir cuál era el legítimo.
7. TLS en todas partes con un issuer `https://` (de lo contrario tokens y codes viajan en claro, y PKCE no te salva de eso); secretos reales — no `admin/admin` y no un secreto hardcodeado en un archivo de Compose — provenientes de un gestor de secretos, con client secrets rotables; y un Keycloak en modo producción: `start` en vez de `start-dev`, respaldado por una base de datos externa con réplicas en vez del almacén de desarrollo en memoria, detrás de un nombre de host que esté configurado, sea resoluble y sea idéntico para todos los clientes.

#### Respuestas 9

1. (a) **Base de datos relacional con transacciones ACID** — PostgreSQL, con la fila del asiento bloqueada con `FOR UPDATE` o protegida por una restricción única sobre `(event_id, seat_id)` en la tabla `sold`. (b) **Log de mensajes** — Apache Kafka, topic `purchases`, un consumer group por consumidor. (c) **Almacenamiento de objetos** — S3 o MinIO, versionado, con object lock en modo `COMPLIANCE` y una política de ciclo de vida de siete años. (d) **Plataforma de big data / analítica** — Parquet sobre almacenamiento de objetos procesado con Spark, o un warehouse columnar; alimentado desde el mismo topic de Kafka. (e) **OAuth 2.0 / OpenID Connect** — Keycloak: `client_credentials` para las boleterías, authorization code + PKCE para la aplicación web. (f) **Caché clave/valor** — Redis, conteniendo el mapa de asientos serializado por evento.
2. Redis no, y MongoDB en configuración de un solo nodo tampoco. La demostración de actualización perdida del Ejercicio 2 es exactamente la doble venta: dos peticiones leen "asiento libre", ambas escriben "asiento vendido", ambas tienen éxito. Redis puede expresar un lock correcto (`SET NX PX`), pero el registro autoritativo de una venta debe estar en un almacén con transacciones durables y restricciones aplicadas — y el Ejercicio 4 mostró a esa instancia expulsando alegremente un cuarto de millón de claves bajo presión de memoria, que es precisamente lo que pasa durante un pico de 40×.
3. "Agregar un cuarto consumidor más adelante no debe requerir tocar el código de compra" es la cláusula decisiva, y ambas tecnologías la satisfacen en principio — un topic exchange te deja vincular una cola nueva sin cambiar el productor. El log gana en lo demás: cada consumidor mantiene su propio offset, así que un nuevo modelo de fraude puede agregarse y **reproducirse sobre los últimos dos años de compras** para rellenar su estado, algo que un broker no puede hacer porque sus mensajes se consumieron destructivamente. Además te da (d) gratis desde el mismo topic.
4. El almacén transaccional está afinado para muchas escrituras pequeñas, críticas en latencia y altamente concurrentes; una agregación horaria sobre dos años recorre millones de filas, desaloja la caché de buffers de la que depende el camino de venta, y mantiene snapshots largos que bloquean `VACUUM` (Ejercicio 2, pregunta 4). Durante el pico de venta esas dos cargas de trabajo compiten por el recurso que no puede fallar. Sepáralas: transmite las compras hacia almacenamiento columnar y deja que los analistas consulten ahí.
5. `client_credentials` para las boleterías socias (una máquina actuando como sí misma, sin usuario, sin ID token) y authorization code con PKCE para la aplicación web del usuario final. Solo el segundo obtiene un **ID token**, porque solo él autenticó a un humano.
6. Cache-aside con invalidación explícita al escribir: la transacción de compra hace commit en PostgreSQL, y después borra o actualiza la clave `seatmap:<event>`, más un TTL corto como red de seguridad ante una invalidación perdida. Si la caché se pierde por completo durante el pico, **la corrección no se ve afectada** — el mapa de asientos es un dato derivado, y toda lectura cae a PostgreSQL. Lo que sí se ve afectada es la disponibilidad: ese fallback es una estampida de miles de consultas idénticas por segundo contra la base de datos, así que el camino de lectura necesita coalescencia de peticiones (single-flight) o una política stale-while-revalidate. Esa asimetría — perder una caché cuesta rendimiento, perder el sistema de registro cuesta dinero — es lo que hace distintos a los componentes (a) y (f).

</details>

---

## Fuentes

- LPI, *Exam 701-100 Objectives (DevOps Tools Engineer, v2.0.0)* — https://www.lpi.org/our-certifications/exam-701-objectives/
- MinIO, *MinIO Object Storage Documentation* — https://min.io/docs/minio/linux/index.html
- AWS, *Amazon S3 User Guide* — https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html
- PostgreSQL Global Development Group, *Transaction Isolation* — https://www.postgresql.org/docs/16/transaction-iso.html
- PostgreSQL Global Development Group, *Using EXPLAIN* — https://www.postgresql.org/docs/16/using-explain.html
- MongoDB, *Schema Validation* — https://www.mongodb.com/docs/manual/core/schema-validation/
- MongoDB, *Transactions* — https://www.mongodb.com/docs/manual/core/transactions/
- Redis, *Key eviction* — https://redis.io/docs/latest/develop/reference/eviction/
- Redis, *Distributed Locks with Redis* — https://redis.io/docs/latest/develop/use/patterns/distributed-locks/
- RabbitMQ, *AMQP 0-9-1 Model Explained* — https://www.rabbitmq.com/tutorials/amqp-concepts
- RabbitMQ, *Dead Letter Exchanges* — https://www.rabbitmq.com/docs/dlx
- Apache Kafka, *Design* and *Log Compaction* — https://kafka.apache.org/documentation/#design
- Apache Spark, *Spark SQL, DataFrames and Datasets Guide* — https://spark.apache.org/docs/latest/sql-programming-guide.html
- IETF, *RFC 6749 — The OAuth 2.0 Authorization Framework* — https://datatracker.ietf.org/doc/html/rfc6749
- IETF, *RFC 7636 — Proof Key for Code Exchange* — https://datatracker.ietf.org/doc/html/rfc7636
- IETF, *RFC 7519 — JSON Web Token* — https://datatracker.ietf.org/doc/html/rfc7519
- IETF, *RFC 7662 — OAuth 2.0 Token Introspection* — https://datatracker.ietf.org/doc/html/rfc7662
- OpenID Foundation, *OpenID Connect Core 1.0* — https://openid.net/specs/openid-connect-core-1_0.html
- Keycloak, *Server Administration Guide* — https://www.keycloak.org/documentation