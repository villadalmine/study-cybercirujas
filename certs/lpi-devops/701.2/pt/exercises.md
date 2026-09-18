# 701.2 — Componentes e Plataformas Padrão para Software

**Exame:** LPI DevOps Tools Engineer, 701-100 (v2.0.0) · **Peso:** 5

Estes exercícios percorrem as famílias de componentes que o objetivo nomeia — armazenamento de objetos, bancos de dados relacionais e NoSQL, message brokers e filas, processamento de big data e OAuth 2.0 / OpenID Connect — executando uma instância real de cada um e observando o comportamento que orienta as decisões de arquitetura. Cada passo é executável; após cada bloco há perguntas de compreensão, e as respostas estão na seção recolhível ao final.

**Tempo:** ~4 horas no total. Cada exercício é autocontido, exceto o Exercício 7 (Spark), que reutiliza o diretório `lab-data`.

---

## 0. Ambiente de laboratório

Você precisa do Docker Engine ≥ 24 com o plugin Compose v2 (ou Podman com `podman compose`), `curl`, `jq`, `python3` e cerca de 6 GB de RAM livre. Nada aqui toca em uma conta de nuvem e nada custa dinheiro.

**Passo 0.1** — Crie o diretório do laboratório e o diretório de dados que o Spark e o `mc` vão compartilhar:

```bash
mkdir -p ~/lab-701.2/lab-data && cd ~/lab-701.2
```

**Passo 0.2** — Escreva o `compose.yaml`:

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

**Passo 0.3** — Suba a plataforma e confirme que todos os serviços estão no ar:

```bash
docker compose up -d
docker compose ps
```

Saída semelhante a:

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

> Em um host com SELinux (Fedora, RHEL, CentOS Stream) o sufixo `:z` no mount de `./lab-data` é o que permite ao contêiner escrever ali. Sem ele você recebe `Permission denied` mesmo que o diretório tenha permissão de escrita para todos.

**Perguntas 0**

1. O serviço `mc` tem `profiles: ["tools"]`. Por que o `docker compose up -d` não o iniciou, e como você o executa?
2. O Keycloak 25 e anteriores usavam `KEYCLOAK_ADMIN` / `KEYCLOAK_ADMIN_PASSWORD`. O que acontece se você usar esses nomes contra a imagem 26.0, e por que uma tag de imagem como `:latest` torna essa classe de falha difícil de reproduzir?
3. O `kafka` não publica porta alguma. O que isso diz sobre como se espera que você o alcance neste laboratório?

---

## 1. Armazenamento de objetos (MinIO / a API S3)

Armazenamento de objetos não é um sistema de arquivos: não há diretórios, não há escritas parciais, não há rename, não há travamento POSIX. Há um keyspace plano dentro de um bucket, PUT/GET de objetos inteiros sobre HTTP e metadados por objeto. Toda decisão de projeto neste exercício decorre disso.

**Passo 1.1** — Registre o endpoint do MinIO como um alias do `mc` (o alias é persistido no volume `mc-config`, então invocações posteriores de `run` o reutilizam):

```bash
docker compose run --rm mc alias set local http://minio:9000 minioadmin minioadmin123
```

```
Added `local` successfully.
```

**Passo 1.2** — Crie dois buckets: um comum e outro com object locking habilitado (o que exige versionamento e só pode ser definido no momento da criação):

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

**Passo 1.3** — Crie um objeto, envie-o duas vezes com conteúdos diferentes e liste as versões:

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

**Passo 1.4** — Inspecione os metadados do objeto e defina um cabeçalho customizado:

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

**Passo 1.5** — Gere uma URL presigned e busque-a *a partir do host*. O endpoint do MinIO é `minio:9000` na rede do Compose, e a assinatura SigV4 cobre o cabeçalho `Host` — então você não pode simplesmente reescrever o hostname para `localhost`:

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

**Passo 1.6** — Solicite apenas os primeiros 12 bytes e depois quebre a assinatura deliberadamente:

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

**Passo 1.7** — Torne o bucket legível anonimamente, verifique e depois desfaça:

```bash
docker compose run --rm mc anonymous set download local/reports
curl --resolve minio:9000:127.0.0.1 -s http://minio:9000/reports/2026/q3.csv
docker compose run --rm mc anonymous set none local/reports
```

**Passo 1.8** — Aplique uma retenção WORM padrão no bucket com lock e tente apagar um objeto protegido:

```bash
docker compose run --rm mc retention set --default COMPLIANCE 30d local/audit
docker compose run --rm mc cp /data/q3.csv local/audit/2026-q3-audit.csv
docker compose run --rm mc rm local/audit/2026-q3-audit.csv
```

```
mc: <ERROR> Failed to remove `local/audit/2026-q3-audit.csv`. Object, overwrite or version delete is not allowed due to object retention or legal hold.
```

**Perguntas 1**

1. Você enviou `q3.csv` três vezes para a mesma key. Quantos objetos faturáveis existem em `reports`, e o que um `mc ls` simples mostra? Que risco operacional isso cria ao longo de um ano?
2. A URL presigned funcionou com `--resolve`, mas falharia se você simplesmente substituísse `minio` por `localhost` na URL. Explique por quê, em termos do que o SigV4 assina, e nomeie a configuração do MinIO que resolve isso adequadamente em uma implantação de produção atrás de um load balancer.
3. O passo 1.6 retornou `206 Partial Content`. Qual destes *não* é possível com armazenamento de objetos, e por quê: ler o intervalo de bytes 5000–6000 de um log de 1 GB, acrescentar uma linha a esse log, substituir o log inteiro?
4. O `ETag` aqui era um MD5 simples. O que um ETag terminado em `-4` diz sobre como o objeto foi enviado, e por que isso quebra verificações ingênuas de integridade?
5. A retenção `COMPLIANCE` impede a exclusão por *qualquer um*, inclusive pela credencial root, durante o período de retenção. Dê um caso em que você quer o modo `GOVERNANCE` no lugar.
6. Um colega propõe guardar o estado de sessão da aplicação no S3 em vez do Redis, "porque é mais barato por GB". Dê as duas objeções técnicas mais fortes.

---

## 2. Bancos de dados relacionais (PostgreSQL) — ACID, isolamento e planos

**Passo 2.1** — Abra uma sessão psql e crie um esquema com restrições reais:

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

**Passo 2.2** — Prove que as restrições são impostas pelo engine, não pela aplicação:

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

**Passo 2.3** — Reproduza um lost update. Abra um **segundo** terminal com uma segunda sessão psql; as duas sessões são rotuladas **A** e **B**.

Em A:

```sql
BEGIN;
SELECT balance FROM accounts WHERE id = 1;   -- 1000.00
```

Em B:

```sql
BEGIN;
SELECT balance FROM accounts WHERE id = 1;   -- 1000.00
```

Em A:

```sql
UPDATE accounts SET balance = 900.00 WHERE id = 1;
COMMIT;
```

Em B:

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

Dois saques de 100 foram aplicados e o saldo caiu 100. Dinheiro sumiu do livro-razão.

**Passo 2.4** — Repita o mesmo intercalamento sob `REPEATABLE READ`. Reinicie primeiro (`UPDATE accounts SET balance = 1000.00 WHERE id = 1;`) e então, em ambas as sessões, comece com:

```sql
BEGIN ISOLATION LEVEL REPEATABLE READ;
```

Execute a mesma sequência. O `UPDATE` de B agora bloqueia até A fazer commit, e então:

```
ERROR:  could not serialize access due to concurrent update
```

**Passo 2.5** — Escreva do jeito que deveria ter sido escrito desde o início e observe o lock:

Em A:

```sql
BEGIN;
SELECT balance FROM accounts WHERE id = 1 FOR UPDATE;
```

Em B:

```sql
BEGIN;
UPDATE accounts SET balance = balance - 100 WHERE id = 1;   -- blocks
```

Em uma terceira sessão:

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

Faça commit em A e veja B concluir.

**Passo 2.6** — Carregue 300 000 linhas e olhe um plano:

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

**Passo 2.7** — Adicione o índice e execute novamente a consulta idêntica:

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

**Passo 2.8** — Adicione um índice parcial para a consulta quente da fila e verifique o teto de conexões:

```sql
CREATE INDEX orders_pending_idx ON orders (created_at DESC) WHERE status = 'pending';
EXPLAIN SELECT * FROM orders WHERE status = 'pending' ORDER BY created_at DESC LIMIT 20;

SELECT pg_size_pretty(pg_relation_size('orders_email_idx'))   AS full_idx,
       pg_size_pretty(pg_relation_size('orders_pending_idx')) AS partial_idx;

SHOW max_connections;
SELECT count(*) FROM pg_stat_activity;
```

**Perguntas 2**

1. No passo 2.3 ambas as transações fizeram commit com sucesso e os dados terminaram errados. Qual letra do ACID *não* foi violada por isso, e como se chama essa anomalia?
2. O `REPEATABLE READ` transformou uma perda silenciosa de dados no erro `40001`. O que a *aplicação* precisa fazer agora que antes não precisava, e por que isso é uma decisão de projeto e não apenas de configuração?
3. `UPDATE accounts SET balance = balance - 100` é seguro sob `READ COMMITTED`, enquanto `SELECT` seguido de `UPDATE balance = 900` não era. Explique precisamente por quê.
4. A sessão A no passo 2.5 estava `idle in transaction` enquanto segurava um lock de linha. Por que esse estado é a coisa mais perigosa desta lista em produção, e quais dois parâmetros limitam o dano?
5. O sequential scan leu 3021 shared buffers e o index scan leu 10. Em qual seletividade o planner estaria *certo* em ignorar seu índice, e por que isso não é um bug do planner?
6. `max_connections` é 100. Seu deployment no Kubernetes escala para 40 pods com um pool de 20 conexões cada. O que quebra, e que componente você coloca à frente do PostgreSQL?

---

## 3. NoSQL — banco de documentos (MongoDB)

**Passo 3.1** — Abra o `mongosh` e inicialize o replica set de nó único (um `mongod` standalone não suporta nem transações nem change streams):

```bash
docker compose exec mongo mongosh
```

```javascript
rs.initiate({ _id: "rs0", members: [{ _id: 0, host: "mongo:27017" }] })
rs.status().myState   // 1 = PRIMARY, may take a few seconds
```

**Passo 3.2** — Insira documentos cujo formato difere, que é justamente o propósito de um banco de documentos:

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

**Passo 3.3** — Adicione um índice único e veja-o rejeitar uma duplicata:

```javascript
db.products.createIndex({ sku: 1 }, { unique: true })
db.products.insertOne({ sku: "kbd-01", name: "Clone", price: 1.00 })
```

```
MongoServerError: E11000 duplicate key error collection: shop.products index: sku_1 dup key: { sku: "kbd-01" }
```

**Passo 3.4** — Compare um collection scan com um index scan:

```javascript
for (let i = 0; i < 100000; i++) {
  db.products.insertOne({ sku: "bulk-" + i, name: "Bulk " + i, price: Math.random() * 500, stock: i % 50 })
}

db.products.find({ sku: "bulk-99999" }).explain("executionStats").executionStats
db.products.find({ stock: 42 }).explain("executionStats").executionStats
```

Compare `totalDocsExamined` e `executionStages.stage` (`IXSCAN` vs `COLLSCAN`) entre os dois.

**Passo 3.5** — Execute um pipeline de agregação:

```javascript
db.products.aggregate([
  { $match: { price: { $gte: 100 } } },
  { $group: { _id: { $cond: [{ $gt: ["$stock", 25] }, "healthy", "low"] },
              count: { $sum: 1 }, avgPrice: { $avg: "$price" } } },
  { $sort: { count: -1 } }
])
```

**Passo 3.6** — "Schemaless" não significa "sem esquema" — mova o esquema para dentro do banco:

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

**Passo 3.7** — Execute uma transação multi-documento e um write concern:

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

**Perguntas 3**

1. O passo 3.1 era obrigatório antes do passo 3.7. Qual é a razão de fundo pela qual um único `mongod` não pode oferecer transações multi-documento, e o que isso diz sobre onde a garantia de durabilidade do MongoDB realmente reside?
2. Você conectou com `docker compose exec`. Se você conectar a partir do host com `mongosh mongodb://localhost:27017`, o handshake tem sucesso e depois o driver falha. Por quê? (A resposta é a mesma razão pela qual um StatefulSet do Kubernetes precisa de um headless Service.)
3. O passo 3.6 colocou um JSON Schema no banco depois que a collection já tinha documentos. O que `validationLevel: "strict"` faz com os documentos preexistentes que o violam, e qual valor você escolheria durante uma migração em produção?
4. Tanto o PostgreSQL (Exercício 2) quanto o MongoDB rejeitaram dados ruins. Nomeie duas classes de restrição de integridade que o PostgreSQL impõe e o `$jsonSchema` não consegue.
5. `w: "majority"` custa latência em cada escrita. Descreva uma collection nesta loja em que `w: 1` é a escolha correta e uma em que é negligência.
6. Dê o sinal concreto no formato dos dados — não um argumento vago de "flexibilidade" — que indica que uma carga de trabalho pertence a um banco de documentos em vez do PostgreSQL. Depois dê o contra-sinal que indica que não pertence.

---

## 4. NoSQL — cache chave/valor (Redis)

**Passo 4.1** — Abra a CLI e construa as primitivas que uma camada de aplicação realmente usa:

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

**Passo 4.2** — Espere 30 segundos e confirme que a sessão sumiu:

```
TTL session:u42
GET session:u42
```

```
(integer) -2
(nil)
```

**Passo 4.3** — Implemente um lock distribuído correto e depois quebre o ingênuo:

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

**Passo 4.4** — Dispare a eviction. `maxmemory` é 32 MB com `allkeys-lru`:

```
CONFIG GET maxmemory
CONFIG GET maxmemory-policy
DEBUG POPULATE 500000
DBSIZE
INFO stats
INFO memory
```

Procure por `evicted_keys` em `INFO stats` e `used_memory_human` em `INFO memory`. O `DBSIZE` ficará bem abaixo de 500 000.

```
# Stats
expired_keys:2
evicted_keys:238417
keyspace_misses:0
```

**Passo 4.5** — Verifique a postura de durabilidade desta instância:

```
CONFIG GET appendonly
CONFIG GET save
BGSAVE
LASTSAVE
INFO persistence
```

**Passo 4.6** — Observe o que sua aplicação está realmente enviando, em um segundo terminal:

```bash
docker compose exec redis redis-cli MONITOR
```

Então, na primeira sessão, execute alguns comandos e veja-os aparecer. Pare o `MONITOR` com `Ctrl-C`.

**Perguntas 4**

1. O passo 4.4 destruiu um quarto de milhão de chaves e o Redis reportou sucesso o tempo todo. Qual valor único de configuração transforma esta instância de um cache em algo que entregará à sua aplicação dados livres de obsolescência mas *incompletos*, e qual é o modo de falha se você o definir como `noeviction`?
2. `SET key value NX PX 10000` é a aquisição correta do lock. Por que `SETNX` seguido de `EXPIRE` está errado, e por que a *liberação* também exige cuidado — para que serve o token?
3. `MONITOR` e `DEBUG POPULATE` estão ambos neste exercício e nenhum dos dois pertence à produção. Dê o custo específico de cada um.
4. `OBJECT ENCODING` retornou `listpack` para um hash de dois campos. O que acontece com a memória e com a complexidade de acesso quando esse hash cresce além de `hash-max-listpack-entries`?
5. O arquivo compose define `--appendonly no`. Descreva a janela exata de perda de dados após um `kill -9` deste contêiner, e diga qual dos dados do exercício (sessões, carrinho, métricas de página) você está disposto a perder dessa forma.
6. Redis e RabbitMQ podem ambos manter uma lista de jobs pendentes (`LPUSH`/`BRPOP` vs uma fila). Nomeie as duas garantias que o broker dá e a lista do Redis não.

---

## 5. Message broker — roteamento AMQP e dead-lettering (RabbitMQ)

**Passo 5.1** — Baixe a CLI de gerenciamento do broker em execução (é um script Python servido pelo plugin de management) e confirme que ela fala com o nó:

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

**Passo 5.2** — Declare um topic exchange e dois consumidores com interesses diferentes:

```bash
./rabbitmqadmin -u guest -p guest declare exchange name=orders type=topic durable=true
./rabbitmqadmin -u guest -p guest declare queue name=billing durable=true
./rabbitmqadmin -u guest -p guest declare queue name=audit   durable=true
./rabbitmqadmin -u guest -p guest declare binding source=orders destination=billing routing_key=order.created
./rabbitmqadmin -u guest -p guest declare binding source=orders destination=audit   routing_key='order.#'
./rabbitmqadmin -u guest -p guest list bindings source destination routing_key
```

**Passo 5.3** — Publique três mensagens com routing keys diferentes e conte o que chegou onde:

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

**Passo 5.4** — Publique com uma routing key à qual ninguém está vinculado, e para um exchange inexistente:

```bash
./rabbitmqadmin -u guest -p guest publish exchange=orders routing_key=nobody.listens payload='lost'
./rabbitmqadmin -u guest -p guest publish exchange=does-not-exist routing_key=x payload='lost'
```

```
Message published but NOT routed
*** Not found: /api/exchanges/%2F/does-not-exist/publish
```

**Passo 5.5** — Adicione um caminho de dead-letter. Primeiro tente redeclarar `billing` com novos argumentos e leia o erro com atenção:

```bash
./rabbitmqadmin -u guest -p guest declare queue name=billing durable=true \
  arguments='{"x-dead-letter-exchange":"","x-dead-letter-routing-key":"billing.dlq"}'
```

```
*** Error: 400 Bad Request: inequivalent arg 'x-dead-letter-exchange' for queue 'billing' in vhost '/': received the value 'none' of type 'longstr' but current is none
```

Apague e recrie corretamente, depois refaça o binding:

```bash
./rabbitmqadmin -u guest -p guest declare queue name=billing.dlq durable=true
./rabbitmqadmin -u guest -p guest delete queue name=billing
./rabbitmqadmin -u guest -p guest declare queue name=billing durable=true \
  arguments='{"x-dead-letter-exchange":"","x-dead-letter-routing-key":"billing.dlq","x-max-length":1000}'
./rabbitmqadmin -u guest -p guest declare binding source=orders destination=billing routing_key=order.created
```

**Passo 5.6** — Publique, consuma com um *reject* e veja a mensagem mover-se para a DLQ:

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

**Passo 5.7** — Prove que durabilidade são duas decisões separadas. Publique uma mensagem persistente e uma transiente, depois reinicie o broker:

```bash
./rabbitmqadmin -u guest -p guest publish exchange=orders routing_key=order.created \
  payload='persistent' properties='{"delivery_mode":2}'
./rabbitmqadmin -u guest -p guest publish exchange=orders routing_key=order.created \
  payload='transient' properties='{"delivery_mode":1}'

docker compose restart rabbitmq
sleep 20
./rabbitmqadmin -u guest -p guest list queues name messages
```

**Perguntas 5**

1. `order.cancelled` chegou a `audit` mas não a `billing`. Reconstrua a decisão de roteamento que o broker tomou e diga o que `order.*` teria casado que `order.#` casou.
2. O passo 5.4 reportou "published but NOT routed" e devolveu sucesso ao publicador. Quais dois recursos do AMQP teriam informado ao produtor que sua mensagem não foi a lugar algum?
3. Explique o erro `inequivalent arg` em uma frase, e depois explique por que ele é um erro *bom* — o que quebraria silenciosamente se o RabbitMQ tivesse aceitado a redeclaração?
4. A DLQ no passo 5.5 usou `x-dead-letter-exchange: ""`. Que exchange é esse, e por que a routing key precisa ser exatamente o nome da fila nesse caso?
5. Três coisas precisam ser verdadeiras para uma mensagem sobreviver a um restart do broker. Nomeie-as.
6. `x-max-length: 1000` foi definido em `billing`. Quando o limite é atingido, qual mensagem é descartada — a mais antiga ou a mais nova — e qual é o comportamento alternativo que você pode configurar?

---

## 6. Message log — partições, offsets e replay (Apache Kafka)

Um broker apaga uma mensagem assim que ela é confirmada. Um log a mantém por um período de retenção e permite que cada consumer group a leia de forma independente. Essa diferença é todo o exercício.

**Passo 6.1** — Crie um tópico com três partições e descreva-o:

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

**Passo 6.2** — Produza registros com chave. A chave decide a partição, e a partição é a única garantia de ordenação que o Kafka lhe dá:

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

**Passo 6.3** — Leia tudo desde o começo, mostrando chave e partição:

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

A `TimeoutException` é o `--timeout-ms` fazendo seu trabalho; a linha "Processed a total of 5 messages" é o resultado.

**Passo 6.4** — Leia como um consumer group e depois inspecione os offsets confirmados:

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

**Passo 6.5** — Execute o mesmo consumidor de novo: ele não retorna nada. Depois rebobine o grupo e execute novamente — os mesmos cinco registros voltam:

```bash
docker compose exec kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 --topic orders --group billing --timeout-ms 5000

docker compose exec kafka /opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 --group billing --topic orders \
  --reset-offsets --to-earliest --execute

docker compose exec kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 --topic orders --group billing --timeout-ms 5000
```

**Passo 6.6** — Adicione um segundo grupo independente e confirme que ele começa do zero sem afetar `billing`:

```bash
docker compose exec kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 --topic orders --from-beginning \
  --group analytics --timeout-ms 5000

docker compose exec kafka /opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 --list
```

**Passo 6.7** — Mude a retenção e crie um tópico compactado:

```bash
docker compose exec kafka /opt/kafka/bin/kafka-configs.sh --bootstrap-server localhost:9092 \
  --entity-type topics --entity-name orders --alter --add-config retention.ms=60000

docker compose exec kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 \
  --create --topic customer-state --partitions 3 --replication-factor 1 \
  --config cleanup.policy=compact --config min.cleanable.dirty.ratio=0.01

docker compose exec kafka /opt/kafka/bin/kafka-configs.sh --bootstrap-server localhost:9092 \
  --entity-type topics --entity-name customer-state --describe
```

**Perguntas 6**

1. Todos os três registros `cust-1` caíram na partição 1, em ordem. Enuncie o mecanismo e depois enuncie exatamente que garantia de ordenação você tem entre `cust-1` e `cust-2`.
2. Você roda 5 instâncias de consumidor no grupo `billing` contra este tópico de 3 partições. Quantas fazem trabalho útil, e qual é a regra que decide?
3. No passo 6.5 a segunda execução não retornou nada mesmo com os dados ainda em disco. Onde fica armazenado o estado de "já lido", e por que isso é arquiteturalmente diferente do acknowledgement do RabbitMQ?
4. O passo 6.7 definiu `retention.ms=60000` em um tópico que `analytics` pode ainda não ter consumido. Descreva a falha e a exceção que o consumidor atrasado acabará vendo.
5. `cleanup.policy=compact` mantém o último registro por chave para sempre. Dê uma coisa para a qual esse tópico pode agora ser usado e que um tópico com retenção por tempo não pode, e diga o que significa ali um registro com valor `null`.
6. O serviço `kafka` não publica portas. Se você mapear `9092:9092` e conectar um cliente a partir do host, a requisição de metadados tem sucesso e depois o produtor trava. Nomeie a configuração do broker responsável e explique a conexão em duas etapas que os clientes Kafka fazem.

---

## 7. Processamento de big data (Apache Spark)

**Passo 7.1** — Inicie um shell PySpark em modo local, com a UI do Spark exposta e o diretório do laboratório montado:

```bash
docker run --rm -it -u root -p 4040:4040 -v "$PWD/lab-data:/data:z" \
  spark:3.5.1-python3 /opt/spark/bin/pyspark
```

> Se o seu mirror de registry não tiver essa tag, `spark:python3` resolve para o build atual com Python habilitado.

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

**Passo 7.2** — Gere dois milhões de eventos sintéticos e grave-os como CSV:

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

**Passo 7.3** — Leia de volta e execute uma agregação:

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

**Passo 7.4** — Olhe o plano físico e encontre o shuffle:

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

**Passo 7.5** — Grave os mesmos dados como Parquet particionado e compare os planos:

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

**Passo 7.6** — Deixe o shell aberto e, a partir do host, compare os dois layouts em disco:

```bash
du -sh lab-data/events_csv lab-data/events_parquet
ls lab-data/events_parquet
```

```
612M	lab-data/events_csv
 84M	lab-data/events_parquet
_SUCCESS  country=ar  country=br  country=de  country=us
```

**Passo 7.7** — Abra `http://localhost:4040` em um navegador enquanto um job roda. Dispare um e observe os stages:

```python
df.groupBy("user_id").count().orderBy(F.desc("count")).limit(5).collect()
```

Nas abas **SQL / DataFrame** e **Stages**, encontre a fronteira de stage e os tamanhos de shuffle read/write. Saia do shell com `Ctrl-D`.

**Perguntas 7**

1. `spark.range(...).withColumn(...)` retornou instantaneamente; `df.count()` levou segundos. Nomeie o modelo de avaliação e diga quais das chamadas nos passos 7.2 e 7.3 foram as actions.
2. `Exchange hashpartitioning(country, 200)` aparece no plano. O que acontece fisicamente nessa linha, por que é a coisa mais cara na maioria dos jobs Spark, e de onde vem o número 200?
3. O Parquet foi 7× menor *e* produziu `PushedFilters` e `PartitionFilters` onde o CSV não produziu nenhum. Explique ambos os benefícios a partir da mesma propriedade subjacente do formato.
4. `partitionBy("country")` criou quatro diretórios. O que dá errado se você usar `partitionBy("user_id")` no lugar, e qual é o nome desse antipadrão?
5. `inferSchema` foi usado no passo 7.3. Quanto isso custa, e o que você faz em vez disso em um pipeline de produção?
6. Isto rodou em modo local, sem cluster. Nomeie os três papéis em uma implantação Spark real e diga qual deles seu processo `/opt/spark/bin/pyspark` estava desempenhando.
7. O Spark processou um dataset limitado aqui. Enuncie em uma linha a diferença entre isso e aquilo para o qual o Apache Flink foi construído, e nomeie o componente de plataforma do Exercício 6 que o alimentaria.

---

## 8. OAuth 2.0 e OpenID Connect (Keycloak)

OAuth 2.0 é **autorização delegada**: um access token diz que um cliente pode chamar uma API. OpenID Connect é uma fina camada de identidade por cima: um ID token diz *quem é o usuário*. Confundir os dois é o erro de produção mais comum nesta área.

**Passo 8.1** — Leia o documento de discovery. Todo o resto deste exercício é uma URL dele:

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

**Passo 8.2** — Crie um realm, um cliente de serviço confidencial e um cliente público de navegador que exige PKCE:

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

> Coloque `'Passw0rd!'` entre aspas simples: em um shell bash interativo, `!` dentro de aspas duplas dispara a expansão de histórico.

**Passo 8.3** — Máquina para máquina: o grant `client_credentials`, que não tem usuário algum:

```bash
AT=$(curl -s -X POST http://localhost:8080/realms/devops/protocol/openid-connect/token \
  -d grant_type=client_credentials \
  -d client_id=orders-api \
  -d client_secret=s3cr3t-orders | jq -r .access_token)

echo "${AT:0:40}..."
```

**Passo 8.4** — Decodifique o token. Um JWT é base64url, não base64 — decodifique-o corretamente:

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

**Passo 8.5** — Busque as chaves de assinatura que a API usaria para verificar esse token offline e case o `kid`:

```bash
curl -s http://localhost:8080/realms/devops/protocol/openid-connect/certs \
  | jq '.keys[] | {kid, kty, alg, use}'
```

**Passo 8.6** — Verifique o token pelo outro caminho, no endpoint de introspection (RFC 7662):

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

**Passo 8.7** — Agora o fluxo voltado ao usuário: Authorization Code com PKCE (RFC 7636). Construa o verifier e o challenge:

```bash
VERIFIER=$(openssl rand -base64 60 | tr -d '\n=' | tr '/+' '_-')
CHALLENGE=$(printf '%s' "$VERIFIER" | openssl dgst -binary -sha256 | openssl base64 | tr -d '\n=' | tr '/+' '_-')
echo "verifier:  $VERIFIER"
echo "challenge: $CHALLENGE"
```

**Passo 8.8** — Inicie um listener para poder ler o redirect, depois abra a URL de autorização no navegador e faça login como `ana` / `Passw0rd!`:

```bash
python3 -m http.server 3000 &

echo "http://localhost:8080/realms/devops/protocol/openid-connect/auth?client_id=portal-ui&response_type=code&scope=openid%20profile%20email&redirect_uri=http://localhost:3000/callback&state=xyz123&code_challenge=${CHALLENGE}&code_challenge_method=S256"
```

O listener registra o redirect:

```
127.0.0.1 - - [18/Sep/2026 12:31:09] "GET /callback?state=xyz123&session_state=...&code=8f3c...a1 HTTP/1.1" 404 -
```

**Passo 8.9** — Troque o code por tokens, fornecendo o verifier:

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

**Passo 8.10** — Repita o passo 8.9 com um `code_verifier` errado (mude um caractere) e com o mesmo code duas vezes. Registre os dois erros. Depois decodifique o `id_token` e compare suas claims com as do `access_token`:

```bash
kill %1   # stop the http.server
```

**Perguntas 8**

1. `orders-api` usou `client_credentials`; `portal-ui` usou `authorization_code`. Enuncie a regra que decide qual grant um dado componente recebe, e diga por que `portal-ui` não tem client secret.
2. O PKCE protege contra um ataque específico. Descreva-o concretamente — o que o atacante rouba, e o que o impede de usá-lo?
3. Você decodificou o JWT com `base64.urlsafe_b64decode`. O que há de inseguro em *decodificar* um token para confiar em seu conteúdo, e quais são as quatro coisas que um resource server deve verificar antes de aceitá-lo?
4. O passo 8.5 (JWKS, verificação offline) e o passo 8.6 (introspection) ambos validam um token. Dê o trade-off de cada um em uma frase, e diga qual você escolhe para uma API de 10 000 rps e qual para um endpoint de transferência bancária.
5. Ambos os tokens no passo 8.10 vieram da mesma resposta. Qual deles você envia para `orders-api` no cabeçalho `Authorization`, qual jamais deve sair do cliente, e qual é o papel da claim `aud` nessa distinção?
6. Reutilizar um authorization code falha. Qual ameaça do OAuth a imposição de uso único endereça, e o que um authorization server correto deve fazer com os tokens já emitidos para aquele code?
7. O issuer aqui é `http://localhost:8080/...`. Nomeie três coisas que precisam mudar antes de essa configuração ser aceitável em produção.

---

## 9. Exercício de projeto — posicionando os componentes

Sem comandos. Leia o cenário e escreva sua resposta antes de abrir o gabarito.

> Uma plataforma de bilheteria vende assentos para eventos ao vivo. O tráfego de pico é 40× a linha de base durante os dez minutos em que um evento popular entra em venda. Requisitos: (a) um assento nunca pode ser vendido duas vezes; (b) cada compra deve enviar um e-mail de confirmação, atualizar um saldo de fidelidade e alimentar um modelo de fraude, e adicionar um quarto consumidor mais tarde não deve exigir tocar no código de compra; (c) usuários enviam vouchers em PDF e digitalizações de documentos, retidos por sete anos, auditáveis; (d) o negócio quer dashboards horários de receita por local sobre dois anos de histórico; (e) bilheterias parceiras chamam uma API REST em nome de si mesmas, e usuários finais fazem login através de um aplicativo web; (f) o mapa de assentos de um evento é lido milhares de vezes por segundo e muda raramente.

**Perguntas 9**

1. Atribua uma família de componentes deste objetivo a cada um dos itens (a) até (f), e nomeie uma implementação concreta para cada.
2. Para (a), diga qual tecnologia você *não* usaria e por quê, referindo-se a um resultado específico do Exercício 2 ou 4.
3. Para (b), justifique a escolha entre um message broker e um message log usando a última cláusula do requisito (b).
4. Para (d), explique por que o dashboard não deveria consultar o mesmo store de (a).
5. Para (e), nomeie os dois grants OAuth envolvidos e qual deles recebe um ID token.
6. Para (f), descreva a estratégia de invalidação de cache e o que acontece com a correção se o cache for perdido por completo durante o pico de venda.

---

## 10. Limpeza

```bash
cd ~/lab-701.2
docker compose down -v
docker image rm spark:3.5.1-python3 2>/dev/null
rm -f rabbitmqadmin
```

`-v` remove os volumes nomeados; sem ele, `minio-data`, `pg-data`, `mongo-data` e `mc-config` sobrevivem e o próximo `up` começa com o estado antigo.

---

<details>
<summary><strong>Respostas</strong></summary>

#### Respostas 0

1. Um serviço com a chave `profiles` é excluído do `up` a menos que o profile seja ativado. Você o executa sob demanda com `docker compose run --rm mc <args>`, que inicia seus serviços de `depends_on` e então roda o contêiner com `mc` como entrypoint e seus argumentos anexados. Este é o padrão usual para contêineres de administração/ferramentas de uso único em uma stack Compose.
2. O Keycloak 26 renomeou as variáveis de bootstrap para `KC_BOOTSTRAP_ADMIN_USERNAME` / `KC_BOOTSTRAP_ADMIN_PASSWORD`; os nomes antigos ainda funcionam, mas estão obsoletos e serão removidos. Com uma tag flutuante como `:latest`, o contêiner que funcionava ontem silenciosamente deixa de criar o usuário admin após um release upstream, e seu único sintoma é uma falha de login — nada no seu repositório mudou, então o `git bisect` não encontra nada. Este é o argumento para fixar digests de imagem ou ao menos versões exatas em todos os ambientes.
3. A imagem `apache/kafka` padrão anuncia `PLAINTEXT://localhost:9092`, o que só faz sentido dentro do contêiner. Publicar a porta permitiria abrir uma conexão TCP, mas o broker devolveria ao cliente um endereço inalcançável. O laboratório, portanto, opera o Kafka com `docker compose exec`, e a pergunta 6.6 torna a armadilha explícita.

#### Respostas 1

1. Existem três *versões* de objeto e todas as três são faturáveis; o `mc ls` mostra uma entrada, porque uma listagem simples retorna apenas a versão atual de cada key. Ao longo de um ano, um job que reescreve a mesma key de hora em hora acumula ~8 800 versões de dados que você não vê no console e pelas quais está pagando. A correção é uma regra de lifecycle que expira versões não correntes após N dias (`mc ilm rule add --noncurrent-expire-days 30`).
2. O SigV4 assina uma requisição canônica que inclui o cabeçalho `Host`. Mudar o hostname muda a string que foi assinada, então a assinatura calculada deixa de casar e você recebe `SignatureDoesNotMatch`. A correção de produção adequada é definir `MINIO_SERVER_URL` (e `MINIO_BROWSER_REDIRECT_URL`) para o hostname público que os clientes realmente usam, de modo que o MinIO assine as URLs presigned para esse nome em vez do interno.
3. Ler um intervalo de bytes é possível — é o cabeçalho `Range` e o `206` que você viu, e é por isso que o Parquet funciona bem em armazenamento de objetos. Acrescentar não é possível: não há escrita parcial; a única forma de "acrescentar" é ler o objeto inteiro, modificá-lo e fazer PUT dele de volta por completo. Substituir o objeto inteiro é possível e foi o que o terceiro upload no passo 1.3 fez.
4. Um sufixo como `-4` significa que o objeto foi enviado como um multipart upload em 4 partes, e o ETag é o MD5 dos MD5s das partes concatenados, re-hasheado — não o MD5 do conteúdo do arquivo. Qualquer verificação de integridade que compute `md5sum localfile` e compare com o ETag reportará uma divergência falsa para todo objeto grande. Use checksums (`x-amz-checksum-sha256`) ou compare tamanhos mais o seu próprio digest armazenado.
5. O modo `GOVERNANCE` permite que um principal com a permissão `s3:BypassGovernanceRetention` encurte ou remova o lock. Você quer isso quando a retenção é uma rede de segurança contra exclusão acidental e erros operacionais, em vez de uma exigência regulatória — por exemplo, um lock de 7 dias em objetos de backup que uma equipe de plataforma precisa ocasionalmente poder limpar. `COMPLIANCE` é para retenção regulatória, onde "ninguém, nunca" é justamente o ponto.
6. Primeiro, o modelo de latência e custo: o armazenamento de objetos cobra e é otimizado por requisição, com dezenas de milissegundos por GET; a busca de sessão acontece em toda requisição e precisa de leituras em sub-milissegundo. Segundo, não há expiração dirigida por TTL no caminho dos dados nem read-modify-write atômico, então a mutação de sessão é uma corrida de lost update e a expiração vira uma varredura de lifecycle que roda uma vez por dia. O preço de armazenamento por GB é irrelevante quando os objetos têm 2 KB e o padrão de acesso é de 50 000 rps.

#### Respostas 2

1. O isolamento foi violado (especificamente, o nível padrão `READ COMMITTED` o permite); atomicidade, consistência e durabilidade foram todas honradas — cada transação foi atômica, nenhuma restrição foi quebrada e ambos os commits são duráveis. A anomalia é um **lost update**.
2. A aplicação agora precisa capturar o SQLSTATE `40001` (`serialization_failure`) e **repetir a transação inteira**, desde a primeira instrução, porque o snapshot que ela leu se foi. Isso é uma decisão de projeto porque o retry precisa ser seguro: o corpo da transação tem de ser idempotente, ou o retry tem de reler tudo a partir do que ele calcula. Você não pluga isso mudando uma flag de configuração em produção e torcendo.
3. `balance = balance - 100` relê o valor atual da linha *dentro do UPDATE*, sob um lock de linha. Sob `READ COMMITTED`, quando uma transação concorrente faz commit de uma atualização naquela linha, o UPDATE bloqueado reavalia sua cláusula `WHERE` e sua expressão contra a nova versão da linha. O valor 900 na versão quebrada foi computado pelo *cliente* a partir de uma leitura obsoleta, e o banco não tem como saber que ele foi derivado de dados que mudaram desde então.
4. `idle in transaction` segura locks e, pior, segura o snapshot da transação mais antiga: o `VACUUM` não pode remover tuplas mortas mais novas que ele, então o inchaço das tabelas cresce por todo o banco enquanto aquela sessão fica parada ali — um vazamento de conexão em um serviço degrada todos os outros. Os dois parâmetros são `idle_in_transaction_session_timeout` (encerra a sessão) e `statement_timeout` (limita qualquer instrução isolada); `log_min_duration_statement` lhe dá a evidência.
5. Aproximadamente quando a consulta retorna mais do que alguns por cento da tabela. Acima disso, I/O aleatório através do índice mais um heap fetch por linha custa mais do que ler a tabela sequencialmente, e o planner corretamente escolhe o sequential scan. Não é um bug — é o modelo de custo funcionando. Vira um bug quando as estatísticas estão obsoletas, e é por isso que o `ANALYZE` foi rodado antes do `EXPLAIN`.
6. 40 × 20 = 800 conexões solicitadas contra um teto de 100, então os pods falham com `FATAL: sorry, too many clients already` — e aumentar `max_connections` é a correção errada, porque cada backend do PostgreSQL é um processo com sua própria memória e o servidor degrada feio bem antes de 800. Coloque um connection pooler à frente — **PgBouncer** em modo transaction pooling (ou `pgpool-II`), que multiplexa centenas de conexões de cliente sobre algumas dezenas de conexões de servidor.

#### Respostas 3

1. A maquinaria de transação e rollback do MongoDB é construída sobre o **oplog** e sobre read/write concerns de maioria, que só existem em um replica set; um `mongod` standalone não tem oplog, então não há mecanismo para levar um commit multi-documento adiante ou para trás de forma consistente. A garantia de durabilidade, portanto, reside na **replicação**, não na escrita de um nó único — que é exatamente o que `w: "majority"` expressa.
2. `rs.initiate()` registrou o membro como `mongo:27017`. Um driver conecta ao seed, recebe a topologia do replica set e então conecta aos membros *pelos nomes dessa topologia* — `mongo` não resolve no seu host. A correção é usar um nome resolvível por todos os clientes. É a mesma razão pela qual um StatefulSet precisa de um headless Service: cada réplica precisa de um nome DNS estável e válido de onde quer que os clientes vivam.
3. `strict` aplica o validador a **todos os inserts e todos os updates**, incluindo updates de documentos que já eram inválidos — de modo que um documento legado sem `price` não pode mais ser modificado de forma alguma, nem mesmo por um update que não tenha relação com `price`. Durante uma migração você usa `validationLevel: "moderate"`, que aplica as regras a inserts e a updates de documentos *já válidos*, deixando você corrigir os antigos progressivamente. `validationAction: "warn"` (registrar, não rejeitar) é o primeiro passo ainda mais suave.
4. Integridade referencial entre collections (não há `FOREIGN KEY`, nem comportamento de cascata) e restrições entre documentos/entre linhas, como `UNIQUE` sobre uma combinação que atravessa tabelas, restrições `EXCLUDE`, ou um `CHECK` que compara a um agregado. `$jsonSchema` valida um documento isoladamente; não consegue expressar uma relação entre documentos.
5. `w: 1` é adequado para uma collection de alto volume, baixo valor e regenerável — um log de cliques/telemetria em que perder as últimas escritas em um failover de primary é aceitável e a taxa de escrita torna a confirmação por maioria cara. É negligência em qualquer coisa que represente dinheiro ou uma ação irreversível: um pedido, um pagamento, um decremento de estoque. Perder um decremento de estoque em um failover causa venda além do disponível.
6. O sinal é a **localidade do agregado**: a entidade é lida e escrita como um todo, sua estrutura aninhada varia legitimamente por instância (o subdocumento `specs` difere por categoria de produto), e você quase nunca precisa juntá-la a outra coisa ou consultar entre instâncias por um campo que nem todas possuem. O contra-sinal é você se pegar fazendo `$lookup` regularmente, ou dois clientes discordarem sobre o que um campo significa — nesse ponto você tem um esquema relacional escrito em um banco de documentos, e o PostgreSQL (com `jsonb` para a parte genuinamente variável) lhe servirá melhor.

#### Respostas 4

1. `maxmemory-policy`. Com `allkeys-lru` o Redis descarta chaves silenciosamente sob pressão, o que é correto para um cache e catastrófico para um sistema de registro. Com `noeviction`, o Redis para de aceitar escritas e retorna `OOM command not allowed when used memory > 'maxmemory'` a toda escrita enquanto continua servindo leituras — seus dados sobrevivem mas sua aplicação começa a dar erro, o que é a troca certa para uma fila ou um store de locks e a errada para um cache.
2. `SETNX` e depois `EXPIRE` são duas viagens de ida e volta: se o cliente travar entre elas, o lock existe sem TTL e fica retido para sempre — o deadlock que você estava tentando evitar. `SET ... NX PX` é um único comando atômico. O token importa no momento da liberação: você deve apagar a chave **apenas se ela ainda contiver seu token**, senão um worker cujo lock expirou no meio do job apagará o lock que um segundo worker adquiriu legitimamente. A liberação deve ser um script Lua fazendo compare-and-delete, já que `GET` e depois `DEL` tem a mesma corrida.
3. `MONITOR` transmite ao seu cliente todo comando processado pelo servidor, o que pode custar uma fração grande da vazão em uma instância ocupada (a documentação mede um impacto de ~50 %) e vaza toda chave e valor, inclusive tokens de sessão, a quem estiver observando. `DEBUG POPULATE` escreve centenas de milhares de chaves no keyspace vivo, o que, sob `allkeys-lru`, despeja seu working set real e destrói a taxa de acerto até ela se reaquecer.
4. Abaixo do limiar, um hash é armazenado como um `listpack` — uma codificação compacta e contígua com busca O(n) sobre um punhado de entradas, o que é mais rápido e muito menor que uma tabela hash de verdade nesse tamanho. Além de `hash-max-listpack-entries` (ou `hash-max-listpack-value` para um valor longo), o Redis o converte para um `hashtable`: as buscas passam a ser O(1), mas a memória por campo salta várias vezes, e a conversão é irreversível para aquela chave. Muitos hashes pequenos são drasticamente mais baratos do que um grande.
5. Tudo desde o último snapshot RDB é perdido — e com `--appendonly no` mais nenhum ponto de `save` configurado pela linha de comando da imagem, potencialmente *tudo* que está em memória, já que o `BGSAVE` só rodou porque você o digitou. Sessões e o contador de page views são perdas aceitáveis (usuários se reautenticam; métricas têm lacunas). O carrinho não: perdê-lo é um bug visível ao usuário e uma venda perdida, então ele pertence a um store durável, com o Redis usado apenas como cache de leitura.
6. Acknowledgement por mensagem com reentrega (se um consumidor morre no meio do job, o `BRPOP` já removeu o item e ele se foi; o AMQP o recoloca na fila), e roteamento/topologia — uma publicação alcançando várias filas independentes por binding, mais dead-lettering para mensagens envenenadas. Os Redis Streams fecham parte dessa lacuna com consumer groups e `XACK`, mas uma lista simples não lhe dá nenhum dos dois.

#### Respostas 5

1. A publicação carregou a routing key `order.cancelled` para o topic exchange `orders`. O broker a comparou a cada binding: `order.created` não casou, `order.#` casou (`#` casa zero ou mais palavras separadas por ponto). Assim uma cópia foi para `audit` e nenhuma para `billing`. `order.*` casa exatamente uma palavra, então também teria casado `order.cancelled` mas **não** uma key de três palavras como `order.payment.failed`, que `order.#` casa.
2. **Publisher confirms** (`confirm.select`), que informam ao produtor que o broker assumiu a responsabilidade pela mensagem, e a flag **mandatory**, que faz o broker devolver ao produtor uma mensagem não roteável via `basic.return` em vez de descartá-la. Os confirms sozinhos não ajudam aqui: uma mensagem confirmada mas não roteável é confirmada como *descartada* com sucesso.
3. Os argumentos de uma fila fazem parte de sua identidade, e redeclarar uma fila existente com argumentos diferentes é um erro em vez de uma mutação. É um erro bom porque a alternativa — aceitar silenciosamente os novos argumentos, ou ignorá-los silenciosamente — significa que dois serviços que declaram a mesma fila com TTLs ou configurações de DLX diferentes brigariam, e qual deles venceria dependeria da ordem de reinício. Uma falha ruidosa no momento da declaração é muito melhor que uma fila cujo comportamento depende de quem iniciou por último.
4. `""` é o **default exchange**, um direct exchange ao qual toda fila é automaticamente vinculada usando seu próprio nome como routing key. Fazer dead-letter para ele exige, portanto, que `x-dead-letter-routing-key` seja exatamente o nome da fila de destino — não há outro binding a casar. Usar um DLX nomeado com bindings explícitos é o padrão mais manutenível assim que você tem mais de uma DLQ.
5. O exchange deve ser durável, a fila deve ser durável e a mensagem deve ser publicada como persistente (`delivery_mode: 2`). Faltar qualquer uma das três perde a mensagem no restart — que é por que a mensagem `transient` no passo 5.7 desapareceu e a `persistent` não. (Mesmo assim, uma mensagem pode ser perdida na janela entre o aceite e a descarga em disco, a menos que você use publisher confirms e quorum queues.)
6. Por padrão a mensagem **mais antiga**, na cabeça da fila, é descartada para abrir espaço — `x-overflow: drop-head`. A alternativa é `x-overflow: reject-publish`, que recusa novas mensagens e, com publisher confirms, avisa o produtor com um `basic.nack` para que ele possa aplicar backpressure em vez de perder histórico silenciosamente.

#### Respostas 6

1. O produtor aplica hash à chave do registro (murmur2 por padrão) módulo a contagem de partições, de modo que a mesma chave sempre cai na mesma partição — e o Kafka garante ordem **dentro de uma partição**. Entre `cust-1` e `cust-2` você **não tem garantia de ordenação alguma**: eles estão em partições diferentes e são consumidos de forma independente e concorrente. A ordenação no Kafka é por chave, por construção.
2. Três fazem trabalho útil; duas ficam ociosas. Uma partição é atribuída a no máximo um consumidor dentro de um grupo, então o paralelismo do grupo é limitado pela contagem de partições. É por isso que a contagem de partições é uma decisão de capacidade tomada de antemão — você pode aumentá-la depois, mas fazê-lo muda o mapeamento chave-para-partição e quebra a ordenação por chave através da mudança.
3. No tópico interno `__consumer_offsets`, como um offset confirmado por (grupo, tópico, partição) — é um marcador de página, não uma exclusão. O ack do RabbitMQ remove a mensagem da fila: o estado está no conteúdo da fila do broker e é consumido destrutivamente, então um segundo leitor não consegue obtê-la. Os dados do Kafka são imutáveis e compartilhados; o consumidor é dono de sua posição, que é exatamente o que torna possíveis o replay e múltiplos consumidores independentes.
4. Assim que um segmento fica mais velho que `retention.ms`, o broker o apaga independentemente de quem o leu. Um consumidor cujo offset confirmado aponta para um segmento apagado recebe `OffsetOutOfRangeException`, e então se comporta conforme `auto.offset.reset` — pulando silenciosamente para `latest` (ignorando todos os dados não lidos, sem erro que alguém perceba) ou relendo desde `earliest` (reprocessando tudo). Monitorar o **consumer lag** contra a retenção é o que previne isso.
5. Pode ser usado como um **changelog / snapshot de estado** que uma nova instância de serviço reproduz desde o offset 0 para reconstruir o estado atual completo de cada cliente — uma visão materializada, ou uma `KTable` do Kafka Streams. Um registro com valor `null` é uma **tombstone**: marca a chave como apagada, e após `delete.retention.ms` o compactador remove tanto a tombstone quanto todos os registros anteriores daquela chave.
6. `advertised.listeners`. Um cliente primeiro conecta a um bootstrap server e pede os metadados do cluster; o broker responde com o endereço *anunciado* do leader de cada partição, e o cliente então abre uma **segunda** conexão para esse endereço para produzir ou consumir. Se o endereço anunciado for `localhost:9092` e o cliente estiver no host, o bootstrap tem sucesso e a segunda conexão vai para o lugar errado. Você precisa anunciar um endereço alcançável pelo cliente — tipicamente dois listeners, um interno e um externo, via `listener.security.protocol.map`.

#### Respostas 7

1. Avaliação preguiçosa: as transformações constroem um plano lógico e retornam imediatamente; apenas uma **action** dispara a execução. As actions foram `events.write...csv(...)` em 7.2, e `df.count()` e `.show()` em 7.3. `.explain()` compila o plano sem executá-lo, então também não é uma action.
2. Naquela linha cada executor grava seus resultados parciais em disco local, particionados pelo hash de `country`, e cada outro executor lê pela rede as partes que lhe pertencem — uma movimentação de dados todos-para-todos. É caro porque serializa, escreve em disco e atravessa a rede para potencialmente o dataset inteiro, e é uma fronteira rígida de stage, então nada a jusante começa até que se complete. 200 é o padrão de `spark.sql.shuffle.partitions` — um número fixo que é errado tanto para datasets pequenos quanto para enormes, que é por que a Adaptive Query Execution (`AdaptiveSparkPlan` na saída) o agrupa em tempo de execução.
3. O Parquet é **colunar com estatísticas e codificação por chunk de coluna**. Layout colunar significa que valores de um mesmo tipo ficam juntos, então run-length e dictionary encoding mais compressão o encolhem drasticamente — o ganho de tamanho. O mesmo layout significa que o leitor pode pular colunas inteiras de que não precisa e pular row groups cujas estatísticas min/max excluem o filtro — o ganho de pushdown. O CSV é texto orientado a linhas, sem tipos e sem estatísticas, então toda consulta precisa ler e interpretar cada byte.
4. Com ~10 000 valores distintos de `user_id` você criaria ~10 000 diretórios, cada um contendo arquivos minúsculos — o **problema dos arquivos pequenos**. Listar o dataset vira milhares de operações de metadados (brutalmente lentas em armazenamento de objetos, onde LIST é uma requisição HTTP), cada arquivo carrega o overhead do footer Parquet que supera seu conteúdo, e o escalonador cria uma task por arquivo. Particione por uma coluna de baixa cardinalidade pela qual você realmente filtra — `country`, ou uma data.
5. `inferSchema` lê os dados uma vez a mais antes do job real só para adivinhar os tipos, dobrando o I/O a cada execução; pior, o palpite pode mudar entre execuções quando os dados mudam, então uma coluna vira silenciosamente uma string e a aritmética a jusante quebra. Em produção você declara um `StructType` explícito (ou lê um formato que carrega seu próprio esquema, como Parquet ou Avro com um schema registry).
6. **Driver** (roda seu programa, constrói o plano, agenda as tasks), **cluster manager** (YARN, Kubernetes ou Spark standalone — aloca recursos) e **executors** (rodam as tasks e guardam os dados em cache). No modo `local[*]` seu único processo `pyspark` é o driver *e* os executors, com threads no lugar do cluster; é por isso que nada precisou ser implantado e por que os resultados aqui não dizem nada sobre como o job se comportará distribuído.
7. O Spark aqui processou um dataset **limitado** em batch; o Flink é projetado para streams **ilimitados** com semântica de event-time, watermarks para eventos fora de ordem e operadores contínuos com estado — latência medida em milissegundos em vez de por batch. O componente que o alimenta é o **Kafka** do Exercício 6: o log é a fonte do stream, e os offsets são o que permite ao Flink fazer checkpoint e recuperar exatamente-uma-vez.

#### Respostas 8

1. A regra: há um humano ao teclado cuja identidade e consentimento importam? Se sim, o cliente age *em nome de um usuário* e usa o fluxo de authorization code; se não, o cliente age *como si mesmo* e usa `client_credentials`. `portal-ui` não tem secret porque é um cliente público — seu código roda no navegador, onde qualquer "segredo" é legível pelo usuário e por qualquer um com o bundle, então o protocolo não finge o contrário e se apoia em PKCE mais correspondência exata de redirect URI.
2. **Interceptação do authorization code.** Em um cliente móvel ou SPA, o code chega via um redirect que um aplicativo malicioso registrado para o mesmo custom scheme, ou um log/referrer vazado, pode observar. Sem PKCE o atacante repete o code no token endpoint e obtém os tokens. Com PKCE o code fica atrelado ao SHA-256 de um `code_verifier` aleatório que o cliente legítimo nunca transmitiu até a troca; o atacante tem o code e o challenge, mas não o verifier, então a troca falha com `invalid_grant`.
3. Decodificar não é verificar — o payload é base64url, não é criptografado, e qualquer um pode forjar um editando claims e recodificando, inclusive definindo `"alg": "none"`. Um resource server deve verificar: (i) a **assinatura**, contra a chave identificada pelo `kid` obtido do JWKS, com o algoritmo fixado no que ele espera; (ii) o **issuer** `iss` corresponde ao authorization server esperado; (iii) a **audiência** `aud` inclui esta API; (iv) as claims de **tempo** `exp` e `nbf`/`iat` são válidas no momento. As verificações de scope/roles vêm depois das quatro.
4. A verificação via JWKS é local e sem estado: nenhuma chamada de rede por requisição, latência de microssegundos, mas o token continua válido até o `exp` mesmo que tenha sido revogado. A introspection consulta o authorization server a cada requisição: revogação instantânea e política centralizada, ao custo de um round trip de rede e de uma dependência dura da disponibilidade do AS. Use verificação JWT local com tokens de vida curta para a API de 10 000 rps; use introspection (ou no mínimo uma checagem de revogação) para o endpoint de transferência bancária, onde um token roubado valer pelos próximos 5 minutos não é aceitável.
5. Envie o **access token** para `orders-api`. O **ID token** jamais deve ser enviado a uma API como credencial — ele é prova de autenticação emitida *para o cliente*, e seu `aud` é o client ID, não a API. É exatamente esse o papel da claim `aud`: ela nomeia o destinatário pretendido, e uma API que aceita um token cujo `aud` é outra parte está aceitando uma credencial cunhada para outro propósito — a clássica vulnerabilidade do confused deputy.
6. Replay/interceptação de code (RFC 6749 §10.5 e o Security BCP). Além de rejeitar a segunda troca, um authorization server correto deve **revogar todos os tokens já emitidos para aquele code**, porque uma segunda apresentação significa que ou o cliente ou um atacante o repetiu, e o servidor não tem como dizer qual dos dois era o legítimo.
7. TLS em toda parte com um issuer `https://` (senão tokens e codes trafegam em claro, e o PKCE não o salva disso); segredos reais — não `admin/admin` e não um segredo fixo em um arquivo Compose — vindos de um secret manager, com client secrets rotacionáveis; e um Keycloak em modo de produção: `start` em vez de `start-dev`, apoiado em um banco de dados externo com réplicas em vez do store em memória de desenvolvimento, atrás de um hostname configurado, resolvível e idêntico para todos os clientes.

#### Respostas 9

1. (a) **Banco de dados relacional com transações ACID** — PostgreSQL, com a linha do assento travada com `FOR UPDATE` ou protegida por uma restrição unique em `(event_id, seat_id)` na tabela `sold`. (b) **Message log** — Apache Kafka, tópico `purchases`, um consumer group por consumidor. (c) **Armazenamento de objetos** — S3 ou MinIO, versionado, com object lock em modo `COMPLIANCE` e uma política de lifecycle de sete anos. (d) **Plataforma de big data / analítica** — Parquet em armazenamento de objetos processado pelo Spark, ou um data warehouse colunar; alimentado a partir do mesmo tópico Kafka. (e) **OAuth 2.0 / OpenID Connect** — Keycloak: `client_credentials` para as bilheterias, authorization code + PKCE para o aplicativo web. (f) **Cache chave/valor** — Redis, guardando o mapa de assentos serializado por evento.
2. Nem Redis, nem MongoDB em configuração de nó único. A demonstração de lost update no Exercício 2 é exatamente a venda dupla: duas requisições leem "assento livre", ambas escrevem "assento vendido", ambas têm sucesso. O Redis consegue expressar um lock correto (`SET NX PX`), mas o registro autoritativo de uma venda precisa estar em um store com transações duráveis e com restrições impostas — e o Exercício 4 mostrou aquela instância alegremente despejando um quarto de milhão de chaves sob pressão de memória, que é precisamente o que acontece durante um pico de 40×.
3. "Adicionar um quarto consumidor mais tarde não deve exigir tocar no código de compra" é a cláusula decisiva, e ambas as tecnologias a satisfazem em princípio — um topic exchange permite vincular uma nova fila sem mudar o produtor. O log vence no resto: cada consumidor mantém seu próprio offset, então um novo modelo de fraude pode ser adicionado e **reprocessado sobre os últimos dois anos de compras** para preencher seu estado, o que um broker não consegue fazer porque suas mensagens foram consumidas destrutivamente. Ele também lhe dá (d) de graça a partir do mesmo tópico.
4. O store transacional é afinado para muitas escritas pequenas, críticas em latência e altamente concorrentes; uma agregação horária sobre dois anos varre milhões de linhas, despeja o buffer cache do qual o caminho de venda depende, e mantém snapshots longos que bloqueiam o `VACUUM` (Exercício 2, pergunta 4). Durante o pico de venda essas duas cargas competem pelo recurso que não pode falhar. Separe-as: faça stream das compras para um armazenamento colunar e deixe os analistas consultarem isso.
5. `client_credentials` para as bilheterias parceiras (uma máquina agindo como si mesma, sem usuário, sem ID token) e authorization code com PKCE para o aplicativo web do usuário final. Apenas o segundo recebe um **ID token**, porque apenas ele autenticou um humano.
6. Cache-aside com invalidação explícita na escrita: a transação de compra faz commit no PostgreSQL, depois apaga ou atualiza a chave `seatmap:<event>`, mais um TTL curto como rede de segurança contra uma invalidação perdida. Se o cache for perdido por completo durante o pico, a **correção não é afetada** — o mapa de assentos é dado derivado, e toda leitura cai no PostgreSQL. O que é afetado é a disponibilidade: essa queda é um rebanho em disparada de milhares de consultas idênticas por segundo contra o banco, então o caminho de leitura precisa de coalescência de requisições (single-flight) ou de uma política stale-while-revalidate. Essa assimetria — perder um cache custa desempenho, perder o sistema de registro custa dinheiro — é o que torna (a) e (f) componentes diferentes.

</details>

---

## Fontes

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