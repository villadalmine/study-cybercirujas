# 701.1 — Desenvolvimento de Software Moderno: Exercícios Guiados

**Exame:** LPI DevOps Tools Engineer, 701-100 (versão 2.0.0) · **Peso do tópico:** 10

Estes exercícios constroem um pequeno sistema — um serviço `orders` e suas dependências — e depois o atacam sob todos os ângulos que o objetivo nomeia: decomposição de serviços, design de API, configuração, estado, armazenamento, segurança e imutabilidade. Tudo roda em um único host Linux com Python 3.12 e um runtime de contêineres. Nada aqui conversa com uma rede que você não possua.

Faça-os em ordem; cada um deixa artefatos que o seguinte utiliza.

**Pré-requisitos do laboratório**

```bash
mkdir -p ~/lab-701.1 && cd ~/lab-701.1
python3.12 -m venv .venv
.venv/bin/pip install --quiet --upgrade pip
.venv/bin/pip install --quiet \
  "fastapi==0.115.6" "uvicorn[standard]==0.34.0" "httpx==0.28.1" "pytest==8.3.4"
.venv/bin/python -c "import fastapi, sys; print(fastapi.__version__, sys.version.split()[0])"
podman --version || docker --version
```

Esperado:

```
0.115.6 3.12.9
podman version 5.4.0
```

Ao longo do texto, `podman` e `docker` são intercambiáveis; substitua pelo que você tiver.

---

## Exercício 1 — Encontre as costuras antes de desenhar as fronteiras dos serviços

O objetivo pede que você *projete* aplicações baseadas em serviços. A falha mais comum é desenhar fronteiras em um quadro branco por intuição de negócio e descobrir, na hora da implementação, que dois serviços "independentes" compartilham uma tabela. A técnica confiável é o caminho inverso: mapeie qual código toca quais dados e corte onde o mapa já é fino.

**Passo 1.** Crie o monólito que você vai decompor.

```bash
mkdir -p ~/lab-701.1/decompose && cd ~/lab-701.1/decompose
cat > monolith.py <<'EOF'
import sqlite3

DB = "shop.db"


def create_customer(name, email):
    with sqlite3.connect(DB) as c:
        c.execute("INSERT INTO customers (name, email) VALUES (?, ?)", (name, email))


def place_order(customer_id, sku, qty):
    with sqlite3.connect(DB) as c:
        row = c.execute("SELECT email FROM customers WHERE id = ?", (customer_id,)).fetchone()
        c.execute("UPDATE inventory SET on_hand = on_hand - ? WHERE sku = ?", (qty, sku))
        c.execute("INSERT INTO orders (customer_id, sku, qty) VALUES (?, ?, ?)",
                  (customer_id, sku, qty))
        c.execute("INSERT INTO outbox (topic, payload) VALUES ('order.placed', ?)", (row[0],))


def restock(sku, qty):
    with sqlite3.connect(DB) as c:
        c.execute("UPDATE inventory SET on_hand = on_hand + ? WHERE sku = ?", (qty, sku))


def customer_report(customer_id):
    with sqlite3.connect(DB) as c:
        return c.execute(
            "SELECT customers.name, orders.sku FROM customers "
            "JOIN orders ON orders.customer_id = customers.id WHERE customers.id = ?",
            (customer_id,),
        ).fetchall()
EOF
```

**Passo 2.** Escreva o mapeador de acoplamento. Ele analisa o módulo com a própria AST do Python e extrai nomes de tabelas dos literais de string SQL por função — sem LLM, sem conexão com banco de dados, sem execução.

```bash
cat > seams.py <<'EOF'
import ast
import re
import sys

TABLE = re.compile(r"\b(?:FROM|INTO|UPDATE|JOIN)\s+([a-z_]+)", re.I)

tree = ast.parse(open(sys.argv[1]).read())
for fn in (n for n in tree.body if isinstance(n, ast.FunctionDef)):
    tables = set()
    for node in ast.walk(fn):
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            tables.update(t.lower() for t in TABLE.findall(node.value))
    print(f"{fn.name:16s} -> {', '.join(sorted(tables)) or '-'}")
EOF
```

**Passo 3.** Execute-o.

```bash
cd ~/lab-701.1/decompose && ../.venv/bin/python seams.py monolith.py
```

Saída esperada:

```
create_customer  -> customers
place_order      -> customers, inventory, orders, outbox
restock          -> inventory
customer_report  -> customers, orders
```

**Passo 4.** Proponha a divisão. Anote, no papel, qual serviço é dono de cada uma das quatro tabelas e marque toda função que passaria então a cruzar uma fronteira de processo.

> **Perguntas — bloco 1**
>
> 1. `restock` e `create_customer` tocam exatamente uma tabela cada. O que isso lhe diz sobre onde deve ficar o primeiro corte, e por que "toca uma tabela" é um sinal melhor do que "soa como um domínio"?
> 2. `customer_report` emite um `JOIN` entre `customers` e `orders`. Depois da divisão esse JOIN não pode ser executado pelo banco de dados. Cite as duas respostas padrão e enuncie o custo que cada uma impõe.
> 3. `place_order` escreve em `orders` e em `outbox` dentro da mesma conexão. Por que isso é mais forte do que "faça o commit do pedido e depois publique no message broker"? O que exatamente pode dar errado na segunda versão?
> 4. Depois da divisão, `place_order` precisa do endereço de e-mail do cliente. Dê um argumento a favor de buscá-lo de forma síncrona no serviço Customers no momento do pedido, e um argumento a favor de guardar uma cópia desnormalizada no serviço Orders.

---

## Exercício 2 — Configuração twelve-factor e a separação build/release/run

O fator III diz que a configuração vive no ambiente; o fator V diz que build, release e run são estritamente separados. Ambas são afirmações testáveis, não slogans.

**Passo 1.** Crie o pacote da aplicação e um módulo de configuração que falha no momento da importação.

```bash
mkdir -p ~/lab-701.1/app && cd ~/lab-701.1
cat > app/__init__.py <<'EOF'
EOF
cat > app/config.py <<'EOF'
import os


class ConfigError(RuntimeError):
    """Raised at import time when the environment is incomplete."""


def _require(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise ConfigError(f"missing or empty required environment variable: {name}")
    return value


def _optional(name: str, default: str) -> str:
    return os.environ.get(name) or default


DATABASE_URL = _require("DATABASE_URL")
SESSION_SECRET = _require("SESSION_SECRET")
PORT = int(_optional("PORT", "8080"))
LOG_LEVEL = _optional("LOG_LEVEL", "info")
RELEASE = _optional("RELEASE", "dev")
EOF
```

**Passo 2.** Importe-o com um ambiente vazio e inspecione o status de saída.

```bash
cd ~/lab-701.1 && env -u DATABASE_URL -u SESSION_SECRET .venv/bin/python -c "import app.config"
echo "exit=$?"
```

Esperado (traceback abreviado):

```
Traceback (most recent call last):
  File "<string>", line 1, in <module>
  File "/home/user/lab-701.1/app/config.py", line 18, in <module>
    DATABASE_URL = _require("DATABASE_URL")
                   ^^^^^^^^^^^^^^^^^^^^^^^^
app.config.ConfigError: missing or empty required environment variable: DATABASE_URL
exit=1
```

**Passo 3.** Forneça o ambiente e confirme que o mesmo código agora inicia.

```bash
cd ~/lab-701.1
export DATABASE_URL="sqlite:///orders.db"
export SESSION_SECRET="dev-only-not-a-real-secret"
export RELEASE="1.0.0+dev"
.venv/bin/python -c "import app.config as c; print(c.DATABASE_URL, c.PORT, c.LOG_LEVEL, c.RELEASE)"
```

Esperado:

```
sqlite:///orders.db 8080 info 1.0.0+dev
```

**Passo 4.** Aplique o teste decisivo do fator III.

```bash
cd ~/lab-701.1 && grep -rIn -E "(password|secret|token|api[_-]?key)\s*=\s*['\"]" app/ || echo "no literal credentials in app/"
```

Esperado:

```
no literal credentials in app/
```

**Passo 5.** Demonstre build/release/run com um artefato e dois releases. Escreva o arquivo compose que descreve dois ambientes da *mesma* imagem:

```yaml
services:
  orders-staging:
    image: "localhost/orders:1.0.0"
    environment:
      DATABASE_URL: "postgresql://orders:staging-pw@db-staging:5432/orders"
      LOG_LEVEL: "debug"
      RELEASE: "1.0.0+staging.17"
    ports:
      - "8081:8080"
  orders-production:
    image: "localhost/orders:1.0.0"
    environment:
      DATABASE_URL: "postgresql://orders:prod-pw@db-prod:5432/orders"
      LOG_LEVEL: "info"
      RELEASE: "1.0.0+production.17"
    ports:
      - "8082:8080"
```

> **Perguntas — bloco 2**
>
> 1. `config.py` lança a exceção durante a *importação*, não na primeira requisição. Cite dois benefícios operacionais concretos de falhar tão cedo, especificamente em um ambiente orquestrado como o Kubernetes.
> 2. Um colega propõe `config/staging.yaml`, `config/production.yaml` no repositório, selecionados por `APP_ENV`. Dê a objeção precisa do twelve-factor — e diga qual parte da proposta é, ainda assim, aceitável.
> 3. Ambos os serviços do compose usam `image: "localhost/orders:1.0.0"`. Qual fator isso satisfaz, e o que estaria quebrado se staging usasse `orders:1.0.0-staging` construído a partir do mesmo commit?
> 4. `PORT` tem um default de `8080`, mas `SESSION_SECRET` não tem nenhum. Enuncie a regra que decide quais valores de configuração podem carregar um default.

---

## Exercício 3 — Semântica REST: recursos, códigos de status e idempotência

**Passo 1.** Escreva a primeira versão da API.

```bash
cd ~/lab-701.1
cat > app/main.py <<'EOF'
import hashlib
import json
import uuid
from typing import Annotated

from fastapi import FastAPI, Header, HTTPException, Response
from pydantic import BaseModel, Field

from app import config

app = FastAPI(title="Orders", version="1.0.0")

ORDERS: dict[str, dict] = {}
IDEMPOTENCY: dict[str, str] = {}


class OrderIn(BaseModel):
    sku: str = Field(min_length=1, max_length=32)
    qty: int = Field(gt=0, le=100)


def _etag(payload: dict) -> str:
    blob = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    return '"' + hashlib.sha256(blob).hexdigest()[:16] + '"'


@app.post("/orders", status_code=201)
def create_order(
    order: OrderIn,
    response: Response,
    idempotency_key: Annotated[str | None, Header()] = None,
):
    if idempotency_key and idempotency_key in IDEMPOTENCY:
        existing = IDEMPOTENCY[idempotency_key]
        response.status_code = 200
        response.headers["Location"] = f"/orders/{existing}"
        return ORDERS[existing]

    order_id = str(uuid.uuid4())
    record = {"id": order_id, "sku": order.sku, "qty": order.qty, "status": "placed"}
    ORDERS[order_id] = record
    if idempotency_key:
        IDEMPOTENCY[idempotency_key] = order_id
    response.headers["Location"] = f"/orders/{order_id}"
    return record


@app.get("/orders/{order_id}")
def get_order(
    order_id: str,
    response: Response,
    if_none_match: Annotated[str | None, Header()] = None,
):
    record = ORDERS.get(order_id)
    if record is None:
        raise HTTPException(status_code=404, detail="order not found")
    etag = _etag(record)
    headers = {"ETag": etag, "Cache-Control": "private, max-age=30"}
    if if_none_match == etag:
        return Response(status_code=304, headers=headers)
    response.headers.update(headers)
    return record


@app.delete("/orders/{order_id}", status_code=204)
def cancel_order(order_id: str):
    record = ORDERS.get(order_id)
    if record is None:
        raise HTTPException(status_code=404, detail="order not found")
    if record["status"] == "shipped":
        raise HTTPException(status_code=409, detail="a shipped order cannot be cancelled")
    record["status"] = "cancelled"
    return Response(status_code=204)


@app.get("/healthz", include_in_schema=False)
def healthz():
    return {"status": "ok", "release": config.RELEASE}
EOF
```

**Passo 2.** Inicie-o em um segundo terminal (mantenha as variáveis de ambiente do Exercício 2 exportadas ali também).

```bash
cd ~/lab-701.1 && .venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8080
```

Esperado:

```
INFO:     Started server process [24118]
INFO:     Waiting for application startup.
INFO:     Application startup complete.
INFO:     Uvicorn running on http://127.0.0.1:8080 (Press CTRL+C to quit)
```

**Passo 3.** Crie um recurso e leia a linha de resposta e os headers.

```bash
curl -isS -X POST http://127.0.0.1:8080/orders \
  -H 'Content-Type: application/json' \
  -d '{"sku":"SKU-1","qty":2}'
```

Esperado (as datas e os UUIDs vão diferir):

```
HTTP/1.1 201 Created
date: Fri, 18 Sep 2026 09:12:44 GMT
server: uvicorn
content-length: 83
content-type: application/json
location: /orders/0f2b7c1e-6a4d-4f83-9a55-8e1d5c0b21aa

{"id":"0f2b7c1e-6a4d-4f83-9a55-8e1d5c0b21aa","sku":"SKU-1","qty":2,"status":"placed"}
```

**Passo 4.** Reproduza o bug de submissão duplicada: envie a requisição idêntica duas vezes sem chave de idempotência.

```bash
for i in 1 2; do
  curl -sS -X POST http://127.0.0.1:8080/orders \
    -H 'Content-Type: application/json' -d '{"sku":"SKU-9","qty":1}' \
  | .venv/bin/python -c "import json,sys; print(json.load(sys.stdin)['id'])"
done
```

Esperado — dois identificadores diferentes, ou seja, dois pedidos reais:

```
3c9f1d80-7b21-4d0e-b0c8-2a1f5e4477c1
b5e2a744-19ad-4c6f-8f27-6de0c3b91f52
```

**Passo 5.** Repita com uma chave de idempotência.

```bash
KEY=$(uuidgen)
for i in 1 2; do
  curl -sS -o /tmp/body -w "%{http_code} %{redirect_url}\n" -X POST http://127.0.0.1:8080/orders \
    -H 'Content-Type: application/json' -H "Idempotency-Key: $KEY" \
    -d '{"sku":"SKU-9","qty":1}'
  cat /tmp/body; echo
done
```

Esperado — um pedido, duas respostas seguras:

```
201 
{"id":"a71c0e55-4f9b-42d6-9b58-1cc3d77e08b1","sku":"SKU-9","qty":1,"status":"placed"}
200 
{"id":"a71c0e55-4f9b-42d6-9b58-1cc3d77e08b1","sku":"SKU-9","qty":1,"status":"placed"}
```

**Passo 6.** Exercite os caminhos de erro e observe qual camada produziu cada status.

```bash
curl -sS -o /dev/null -w "invalid body : %{http_code}\n" -X POST http://127.0.0.1:8080/orders \
  -H 'Content-Type: application/json' -d '{"sku":"SKU-1","qty":0}'
curl -sS -o /dev/null -w "unknown id  : %{http_code}\n" http://127.0.0.1:8080/orders/does-not-exist
curl -sS -o /dev/null -w "wrong verb  : %{http_code}\n" -X PUT http://127.0.0.1:8080/orders
curl -sS -X POST http://127.0.0.1:8080/orders -H 'Content-Type: application/json' \
  -d '{"sku":"SKU-1","qty":0}' | .venv/bin/python -c "import json,sys; print(json.load(sys.stdin)['detail'][0]['msg'])"
```

Esperado:

```
invalid body : 422
unknown id  : 404
wrong verb  : 405
Input should be greater than 0
```

> **Perguntas — bloco 3**
>
> 1. O passo 3 retornou `201` com um header `Location`. O que um cliente deve ser capaz de fazer com `Location` que não conseguiria fazer apenas com o corpo?
> 2. No passo 5 a segunda chamada retornou `200`, não `201`. Justifique essa escolha contra a alternativa de retornar `201` nas duas vezes.
> 3. `DELETE /orders/{id}` em um pedido já cancelado retorna `204`, mas em um pedido já enviado retorna `409`. Explique por que o primeiro *não* é um erro e o segundo é, em termos da definição de idempotência.
> 4. O corpo inválido produziu `422`, não `400`. Ambos são defensáveis. Enuncie a distinção que está sendo feita e diga o que um cliente deveria fazer de diferente em cada caso.
> 5. `POST /orders` com `qty: 0` falha no framework antes que seu handler rode. Por que validação na borda, expressa como um schema, é uma propriedade de design e não uma conveniência?

---

## Exercício 4 — Requisições condicionais, cache e os headers que os tornam seguros

**Passo 1.** Busque um pedido e capture seu `ETag`.

```bash
ID=$(curl -sS -X POST http://127.0.0.1:8080/orders -H 'Content-Type: application/json' \
  -d '{"sku":"SKU-CACHE","qty":3}' \
  | .venv/bin/python -c "import json,sys; print(json.load(sys.stdin)['id'])")
curl -isS "http://127.0.0.1:8080/orders/$ID" | grep -Ei '^(HTTP|etag|cache-control)'
```

Esperado:

```
HTTP/1.1 200 OK
etag: "4c0d1f7a9b3e5821"
cache-control: private, max-age=30
```

**Passo 2.** Refaça a requisição com o validador.

```bash
ETAG=$(curl -sS -D - -o /dev/null "http://127.0.0.1:8080/orders/$ID" | awk -F': ' 'tolower($1)=="etag"{print $2}' | tr -d '\r')
curl -isS -H "If-None-Match: $ETAG" "http://127.0.0.1:8080/orders/$ID" | head -n 1
curl -sS -o /dev/null -w "bytes transferred: %{size_download}\n" \
  -H "If-None-Match: $ETAG" "http://127.0.0.1:8080/orders/$ID"
```

Esperado:

```
HTTP/1.1 304 Not Modified
bytes transferred: 0
```

**Passo 3.** Altere o recurso e prove que o validador invalida.

```bash
curl -sS -o /dev/null -X DELETE "http://127.0.0.1:8080/orders/$ID"
curl -isS -H "If-None-Match: $ETAG" "http://127.0.0.1:8080/orders/$ID" | grep -Ei '^(HTTP|etag)'
```

Esperado:

```
HTTP/1.1 200 OK
etag: "8f3b2c60d14ae997"
```

**Passo 4.** Examine o que aconteceria atrás de um cache compartilhado. A resposta carrega `private`; mude-a temporariamente para `public, max-age=30` em `app/main.py`, reinicie e repita o passo 1 com dois headers `Authorization` diferentes.

> **Perguntas — bloco 4**
>
> 1. O `304` retornou zero bytes de corpo, mas a requisição ainda atravessou a rede. Cite o recurso que isso economiza e o recurso que *não* economiza, e dê um caso em que essa troca não vale a pena.
> 2. `Cache-Control: private` em um pedido por cliente. Descreva com precisão o incidente que `public` causaria em um CDN compartilhado e cite o header que seria necessário se a resposta legitimamente variasse por `Authorization`.
> 3. O `ETag` aqui é um hash do corpo serializado — um validador *forte*. O que quebra se você, em vez disso, derivar o `ETag` de `updated_at` truncado em segundos inteiros?
> 4. O `ETag` também habilita `If-Match` em escritas. Esboce a troca requisição/resposta que impede dois clientes de sobrescreverem silenciosamente a edição um do outro, e dê o código de status que o perdedor recebe.

---

## Exercício 5 — Processos stateless: reproduza a falha de sticky session e elimine-a

**Passo 1.** Construa um serviço deliberadamente stateful.

```bash
cd ~/lab-701.1
mkdir -p cart
cat > cart/stateful.py <<'EOF'
import os
import uuid

from fastapi import Cookie, FastAPI, Response

app = FastAPI()
INSTANCE = os.environ.get("INSTANCE", "unknown")
CARTS: dict[str, list[str]] = {}


@app.post("/cart/items")
def add_item(sku: str, response: Response, cart_id: str | None = Cookie(default=None)):
    if cart_id is None:
        cart_id = str(uuid.uuid4())
        response.set_cookie("cart_id", cart_id, httponly=True, samesite="lax")
    CARTS.setdefault(cart_id, []).append(sku)
    return {"instance": INSTANCE, "cart_id": cart_id, "items": CARTS[cart_id]}


@app.get("/cart")
def show_cart(cart_id: str | None = Cookie(default=None)):
    return {"instance": INSTANCE, "items": CARTS.get(cart_id, [])}
EOF
```

**Passo 2.** Rode duas instâncias, como faria um deployment escalado.

```bash
cd ~/lab-701.1
INSTANCE=a .venv/bin/uvicorn cart.stateful:app --port 9001 &
INSTANCE=b .venv/bin/uvicorn cart.stateful:app --port 9002 &
sleep 2
```

**Passo 3.** Adicione um item na instância `a` e depois leia o carrinho da instância `b` — exatamente o que um load balancer round-robin faz.

```bash
cd /tmp && rm -f jar.txt
curl -sS -c jar.txt -X POST "http://127.0.0.1:9001/cart/items?sku=SKU-1"; echo
curl -sS -b jar.txt "http://127.0.0.1:9001/cart"; echo
curl -sS -b jar.txt "http://127.0.0.1:9002/cart"; echo
```

Esperado:

```
{"instance":"a","cart_id":"1f5d9a02-0f4c-4f31-8a8e-b41c0f0a5c33","items":["SKU-1"]}
{"instance":"a","items":["SKU-1"]}
{"instance":"b","items":[]}
```

**Passo 4.** Torne o processo stateless movendo o estado para fora. Aqui o estado é carregado pelo cliente em um token assinado e à prova de adulteração; o servidor não guarda nada.

```bash
cd ~/lab-701.1
cat > cart/stateless.py <<'EOF'
import base64
import hashlib
import hmac
import json
import os

from fastapi import Cookie, FastAPI, HTTPException, Response

app = FastAPI()
INSTANCE = os.environ.get("INSTANCE", "unknown")
SECRET = os.environ["SESSION_SECRET"].encode()


def _b64(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def _unb64(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def seal(state: dict) -> str:
    body = _b64(json.dumps(state, separators=(",", ":"), sort_keys=True).encode())
    mac = _b64(hmac.new(SECRET, body.encode(), hashlib.sha256).digest())
    return f"{body}.{mac}"


def unseal(token: str | None) -> dict:
    if not token or "." not in token:
        return {"items": []}
    body, mac = token.rsplit(".", 1)
    expected = _b64(hmac.new(SECRET, body.encode(), hashlib.sha256).digest())
    if not hmac.compare_digest(mac, expected):
        raise HTTPException(status_code=400, detail="tampered session cookie")
    return json.loads(_unb64(body))


@app.post("/cart/items")
def add_item(sku: str, response: Response, cart: str | None = Cookie(default=None)):
    state = unseal(cart)
    state["items"].append(sku)
    response.set_cookie("cart", seal(state), httponly=True, samesite="lax")
    return {"instance": INSTANCE, "items": state["items"]}


@app.get("/cart")
def show_cart(cart: str | None = Cookie(default=None)):
    return {"instance": INSTANCE, "items": unseal(cart)["items"]}
EOF
```

**Passo 5.** Repita o teste entre instâncias.

```bash
cd ~/lab-701.1
kill %1 %2 2>/dev/null
INSTANCE=a .venv/bin/uvicorn cart.stateless:app --port 9001 &
INSTANCE=b .venv/bin/uvicorn cart.stateless:app --port 9002 &
sleep 2
cd /tmp && rm -f jar.txt
curl -sS -c jar.txt -o /dev/null -X POST "http://127.0.0.1:9001/cart/items?sku=SKU-1"
curl -sS -b jar.txt -c jar.txt "http://127.0.0.1:9002/cart"; echo
curl -sS -b jar.txt -c jar.txt -X POST "http://127.0.0.1:9002/cart/items?sku=SKU-2"; echo
curl -sS -b jar.txt "http://127.0.0.1:9001/cart"; echo
```

Esperado:

```
{"instance":"b","items":["SKU-1"]}
{"instance":"b","items":["SKU-1","SKU-2"]}
{"instance":"a","items":["SKU-1","SKU-2"]}
```

**Passo 6.** Confirme que a assinatura é estrutural.

```bash
cd /tmp
BAD=$(sed -n 's/.*cart\s*\(.*\)/\1/p' jar.txt | tr -d '\r')
curl -sS -o /dev/null -w "%{http_code}\n" -H "Cookie: cart=${BAD%.*}.AAAAAAAA" "http://127.0.0.1:9001/cart"
kill %1 %2 2>/dev/null
```

Esperado:

```
400
```

> **Perguntas — bloco 5**
>
> 1. O passo 3 produziu um carrinho vazio na instância `b`. Cite o fator do twelve-factor que isso viola e descreva o que "habilitar sticky sessions no load balancer" realmente lhe custa durante um rolling deploy.
> 2. O cookie selado é assinado, mas *não* criptografado. Enuncie o que um atacante de posse do cookie pode e não pode fazer, e dê uma categoria de dados que, portanto, jamais pode estar ali.
> 3. Compare a abordagem de cookie assinado com um session store compartilhado em Redis em exatamente um eixo: revogar uma sessão imediatamente. Qual vence, e o que o perdedor precisa acrescentar para compensar?
> 4. Seu colega diz "não temos estado; gravamos os arquivos enviados em `/var/lib/app/uploads`". Por que isso ainda é stateful, e qual é a prescrição do twelve-factor?

---

## Exercício 6 — Acoplamento fraco: timeouts, amplificação de retries e um circuit breaker

**Passo 1.** Crie uma dependência cuja latência você controla.

```bash
cd ~/lab-701.1
mkdir -p pricing
cat > pricing/main.py <<'EOF'
import asyncio
import os

from fastapi import FastAPI

app = FastAPI()
LATENCY = float(os.environ.get("FAULT_LATENCY_SECONDS", "0"))


@app.get("/rate/{sku}")
async def rate(sku: str):
    await asyncio.sleep(LATENCY)
    return {"sku": sku, "price_cents": 1999}
EOF
FAULT_LATENCY_SECONDS=30 .venv/bin/uvicorn pricing.main:app --port 9100 &
sleep 2
```

**Passo 2.** Chame-a do jeito que a maioria do código de primeira versão faz — com o timeout explicitamente desabilitado, que é o que `requests` lhe dá por padrão.

```bash
cd ~/lab-701.1
cat > call_unbounded.py <<'EOF'
import time

import httpx

start = time.monotonic()
try:
    with httpx.Client(timeout=None) as client:
        client.get("http://127.0.0.1:9100/rate/SKU-1")
except KeyboardInterrupt:
    print(f"still waiting after {time.monotonic() - start:.1f}s")
EOF
timeout 8 .venv/bin/python call_unbounded.py; echo "exit=$?"
```

Esperado — o processo nunca retorna por conta própria; `timeout` o mata:

```
exit=124
```

**Passo 3.** Limite-o e meça a diferença.

```bash
cd ~/lab-701.1
cat > call_bounded.py <<'EOF'
import time

import httpx

budget = httpx.Timeout(connect=1.0, read=2.0, write=2.0, pool=1.0)
start = time.monotonic()
try:
    with httpx.Client(timeout=budget) as client:
        client.get("http://127.0.0.1:9100/rate/SKU-1")
except httpx.ReadTimeout:
    print(f"read timeout after {time.monotonic() - start:.2f}s -> serve degraded response")
EOF
.venv/bin/python call_bounded.py
```

Esperado:

```
read timeout after 2.01s -> serve degraded response
```

**Passo 4.** Acrescente um circuit breaker para que uma dependência que está fora do ar pare de consumir sua capacidade por completo.

```bash
cd ~/lab-701.1
cat > breaker.py <<'EOF'
import time

import httpx


class CircuitOpen(RuntimeError):
    pass


class Breaker:
    def __init__(self, threshold: int = 3, cooldown: float = 5.0):
        self.threshold = threshold
        self.cooldown = cooldown
        self.failures = 0
        self.opened_at = 0.0

    @property
    def state(self) -> str:
        if self.failures < self.threshold:
            return "closed"
        if time.monotonic() - self.opened_at >= self.cooldown:
            return "half-open"
        return "open"

    def call(self, fn):
        if self.state == "open":
            raise CircuitOpen("circuit open, not calling dependency")
        try:
            result = fn()
        except Exception:
            self.failures += 1
            if self.failures == self.threshold:
                self.opened_at = time.monotonic()
            raise
        self.failures = 0
        return result


budget = httpx.Timeout(connect=1.0, read=1.0, write=1.0, pool=1.0)
breaker = Breaker(threshold=3, cooldown=5.0)

with httpx.Client(timeout=budget) as client:
    for attempt in range(1, 9):
        started = time.monotonic()
        try:
            breaker.call(lambda: client.get("http://127.0.0.1:9100/rate/SKU-1"))
            outcome = "ok"
        except CircuitOpen:
            outcome = "short-circuited (fallback served)"
        except httpx.TimeoutException:
            outcome = "timeout"
        print(f"attempt {attempt}: state={breaker.state:11s} "
              f"elapsed={time.monotonic() - started:.2f}s {outcome}")
        time.sleep(0.5)
EOF
.venv/bin/python breaker.py
```

Esperado:

```
attempt 1: state=closed      elapsed=1.01s timeout
attempt 2: state=closed      elapsed=1.01s timeout
attempt 3: state=open        elapsed=1.01s timeout
attempt 4: state=open        elapsed=0.00s short-circuited (fallback served)
attempt 5: state=open        elapsed=0.00s short-circuited (fallback served)
attempt 6: state=open        elapsed=0.00s short-circuited (fallback served)
attempt 7: state=open        elapsed=0.00s short-circuited (fallback served)
attempt 8: state=half-open   elapsed=1.01s timeout
```

**Passo 5.** Limpeza.

```bash
kill %1 2>/dev/null
```

> **Perguntas — bloco 6**
>
> 1. O passo 2 travou indefinidamente. Em um servidor síncrono com um pool fixo de workers, descreva a sequência que transforma "uma dependência lenta" em "o serviço inteiro retorna 503".
> 2. Três serviços estão encadeados A → B → C, e cada um tenta 3 vezes em caso de falha. Quando C falha, quantas requisições C recebe por requisição original do cliente? Generalize a fórmula e cite as duas mitigações.
> 3. O breaker curto-circuita em 0,00 s enquanto está aberto. Quais duas partes se beneficiam disso, e como isso difere de simplesmente baixar o timeout para 0,1 s?
> 4. O estado `half-open` do breaker deixa passar exatamente uma sonda. O que dá errado se, em vez disso, ele reabrisse a porteira para tráfego total depois do cooldown?
> 5. Todo este exercício trata de acoplamento síncrono. Descreva a mesma interação `orders → pricing` sobre um message broker e enuncie qual propriedade você ganha e qual propriedade você perde.

---

## Exercício 7 — Armazenamento de dados: escolha o modelo pelo invariante que ele precisa manter

**Passo 1.** Construa a tabela de inventário com a restrição escrita.

```bash
cd ~/lab-701.1
.venv/bin/python - <<'EOF'
import sqlite3

conn = sqlite3.connect("stock.db")
conn.executescript("""
DROP TABLE IF EXISTS inventory;
CREATE TABLE inventory (
    sku     TEXT PRIMARY KEY,
    on_hand INTEGER NOT NULL CHECK (on_hand >= 0)
);
INSERT INTO inventory VALUES ('SKU-1', 5);
""")
conn.commit()
print(conn.execute("SELECT sku, on_hand FROM inventory").fetchall())
EOF
```

Esperado:

```
[('SKU-1', 5)]
```

**Passo 2.** Escreva um harness de concorrência com duas implementações de "vender uma unidade": um read-modify-write no código da aplicação e um compare-and-set dentro do banco de dados.

```bash
cd ~/lab-701.1
cat > oversell.py <<'EOF'
import sqlite3
import sys
import threading
import time

DB, MODE, BUYERS = sys.argv[1], sys.argv[2], 20
results, lock = [], threading.Lock()


def connect():
    conn = sqlite3.connect(DB, timeout=30, isolation_level=None)
    conn.execute("PRAGMA journal_mode=WAL")
    return conn


def buy():
    conn = connect()
    try:
        if MODE == "cas":
            conn.execute("BEGIN IMMEDIATE")
            cur = conn.execute(
                "UPDATE inventory SET on_hand = on_hand - 1 "
                "WHERE sku = 'SKU-1' AND on_hand >= 1")
            ok = cur.rowcount == 1
            conn.execute("COMMIT")
        else:
            on_hand = conn.execute(
                "SELECT on_hand FROM inventory WHERE sku = 'SKU-1'").fetchone()[0]
            time.sleep(0.01)
            ok = on_hand >= 1
            if ok:
                conn.execute("BEGIN IMMEDIATE")
                conn.execute("UPDATE inventory SET on_hand = ? WHERE sku = 'SKU-1'",
                             (on_hand - 1,))
                conn.execute("COMMIT")
    finally:
        conn.close()
    with lock:
        results.append(ok)


threads = [threading.Thread(target=buy) for _ in range(BUYERS)]
for t in threads:
    t.start()
for t in threads:
    t.join()

conn = connect()
on_hand = conn.execute("SELECT on_hand FROM inventory WHERE sku = 'SKU-1'").fetchone()[0]
print(f"mode={MODE:20s} buyers={BUYERS} sold={sum(results)} on_hand={on_hand}")
EOF
```

**Passo 3.** Rode a versão ingênua. Reponha o estoque primeiro.

```bash
cd ~/lab-701.1
.venv/bin/python -c "import sqlite3; c=sqlite3.connect('stock.db'); c.execute(\"UPDATE inventory SET on_hand=5 WHERE sku='SKU-1'\"); c.commit()"
.venv/bin/python oversell.py stock.db read-modify-write
```

Esperado (os números exatos variam entre execuções; o formato não):

```
mode=read-modify-write  buyers=20 sold=20 on_hand=4
```

**Passo 4.** Rode a versão compare-and-set.

```bash
cd ~/lab-701.1
.venv/bin/python -c "import sqlite3; c=sqlite3.connect('stock.db'); c.execute(\"UPDATE inventory SET on_hand=5 WHERE sku='SKU-1'\"); c.commit()"
.venv/bin/python oversell.py stock.db cas
```

Esperado — em toda execução, sem exceção:

```
mode=cas                  buyers=20 sold=5 on_hand=0
```

**Passo 5.** Decida onde cada artefato pertence. Para o PDF de confirmação do pedido (≈ 300 kB, escrito uma vez, lido raramente, servido ao cliente por sete anos), compare armazená-lo como uma coluna `BLOB` contra armazenar uma chave em object storage:

```
relational BLOB            object storage (S3-compatible)
--------------------------  ------------------------------
in the backup/restore path  out of it
costs DB IOPS on read       served directly, presigned URL
transactional with the row  eventually consistent with the row
row locking on large writes no lock contention
```

> **Perguntas — bloco 7**
>
> 1. A restrição `CHECK (on_hand >= 0)` estava ativa durante o passo 3 e o banco de dados ainda assim acabou inconsistente com a realidade. Explique exatamente por que a restrição não disparou, e o que isso diz sobre a diferença entre validar um *valor* e serializar uma *operação*.
> 2. A versão `cas` vendeu exatamente 5 de 5, todas as vezes. Qual propriedade única do comando a torna segura, e cite o padrão equivalente no PostgreSQL quando o update é complexo demais para um único comando.
> 3. Você move o inventário para um document store sem transações multi-documento. Cite dois mecanismos que podem restaurar a garantia de "nunca vender além do estoque" e enuncie o custo de cada um.
> 4. Usando a tabela do passo 5, argumente o único caso em que a coluna `BLOB` *é* a resposta certa.
> 5. Propõe-se uma camada de cache na frente da leitura de inventário. Quais leituras podem ser cacheadas, quais não podem, e por que "cachear o nível de estoque por 5 segundos" é mais perigoso do que parece?

---

## Exercício 8 — Segurança de aplicações: SQL injection, XSS e CSRF no seu próprio serviço de laboratório

Tudo abaixo roda contra `127.0.0.1` em código que você acabou de escrever. O objetivo é ver o mecanismo e depois ver a correção funcionar.

**Passo 1.** Construa o serviço vulnerável.

```bash
cd ~/lab-701.1
mkdir -p insecure
cat > insecure/main.py <<'EOF'
import sqlite3

from fastapi import FastAPI, Form, Header, Request
from fastapi.responses import HTMLResponse, JSONResponse

app = FastAPI()
DB = "users.db"


def db():
    conn = sqlite3.connect(DB)
    conn.executescript("""
    CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, name TEXT, role TEXT);
    """)
    if conn.execute("SELECT count(*) FROM users").fetchone()[0] == 0:
        conn.executemany("INSERT INTO users (name, role) VALUES (?, ?)",
                         [("alice", "admin"), ("bob", "user"), ("carol", "user")])
        conn.commit()
    return conn


@app.get("/users/vulnerable")
def users_vulnerable(name: str):
    conn = db()
    sql = f"SELECT id, name, role FROM users WHERE name = '{name}'"
    return {"sql": sql, "rows": conn.execute(sql).fetchall()}


@app.get("/users/safe")
def users_safe(name: str):
    conn = db()
    rows = conn.execute("SELECT id, name, role FROM users WHERE name = ?", (name,)).fetchall()
    return {"rows": rows}


@app.get("/search/vulnerable", response_class=HTMLResponse)
def search_vulnerable(q: str):
    return f"<html><body><p>No results for {q}</p></body></html>"


@app.get("/search/safe", response_class=HTMLResponse)
def search_safe(q: str):
    import html
    body = f"<html><body><p>No results for {html.escape(q)}</p></body></html>"
    return HTMLResponse(body, headers={"Content-Security-Policy": "default-src 'self'"})


@app.post("/profile/vulnerable")
def profile_vulnerable(email: str = Form(...), session: str = Header(default="")):
    return {"changed_email_to": email, "authenticated_by": "cookie only"}


@app.post("/profile/safe")
def profile_safe(request: Request, email: str = Form(...), csrf_token: str = Form(default="")):
    origin = request.headers.get("origin", "")
    allowed = {"http://127.0.0.1:8080", "https://shop.example"}
    if origin and origin not in allowed:
        return JSONResponse({"detail": f"cross-site request rejected: {origin}"}, status_code=403)
    if csrf_token != "server-issued-token":
        return JSONResponse({"detail": "missing or invalid CSRF token"}, status_code=403)
    return {"changed_email_to": email}
EOF
rm -f users.db
.venv/bin/uvicorn insecure.main:app --port 9200 &
sleep 2
```

**Passo 2.** Confirme o caminho normal e depois injete.

```bash
curl -sS --get --data-urlencode "name=alice" http://127.0.0.1:9200/users/vulnerable; echo
curl -sS --get --data-urlencode "name=' OR '1'='1" http://127.0.0.1:9200/users/vulnerable; echo
```

Esperado:

```
{"sql":"SELECT id, name, role FROM users WHERE name = 'alice'","rows":[[1,"alice","admin"]]}
{"sql":"SELECT id, name, role FROM users WHERE name = '' OR '1'='1'","rows":[[1,"alice","admin"],[2,"bob","user"],[3,"carol","user"]]}
```

**Passo 3.** Envie o payload idêntico ao endpoint parametrizado.

```bash
curl -sS --get --data-urlencode "name=' OR '1'='1" http://127.0.0.1:9200/users/safe; echo
```

Esperado — o payload é dado, então não casa com nada:

```
{"rows":[]}
```

**Passo 4.** XSS refletido: olhe os bytes brutos que o servidor emite.

```bash
curl -sS --get --data-urlencode "q=<script>alert(1)</script>" http://127.0.0.1:9200/search/vulnerable; echo
curl -isS --get --data-urlencode "q=<script>alert(1)</script>" http://127.0.0.1:9200/search/safe \
  | grep -Ei '^(content-security-policy)|<html'
```

Esperado:

```
<html><body><p>No results for <script>alert(1)</script></p></body></html>
content-security-policy: default-src 'self'
<html><body><p>No results for &lt;script&gt;alert(1)&lt;/script&gt;</p></body></html>
```

**Passo 5.** CSRF: forje a requisição que uma página maliciosa faria. O navegador anexaria o cookie de sessão automaticamente; o `curl` o faz explicitamente.

```bash
curl -sS -X POST http://127.0.0.1:9200/profile/vulnerable \
  -H 'Origin: https://evil.example' -H 'Cookie: session=victim-session-id' \
  -d 'email=attacker@evil.example'; echo
curl -sS -o /dev/null -w "%{http_code}\n" -X POST http://127.0.0.1:9200/profile/safe \
  -H 'Origin: https://evil.example' -H 'Cookie: session=victim-session-id' \
  -d 'email=attacker@evil.example'
curl -sS -X POST http://127.0.0.1:9200/profile/safe \
  -H 'Origin: http://127.0.0.1:8080' -H 'Cookie: session=victim-session-id' \
  -d 'email=owner@shop.example&csrf_token=server-issued-token'; echo
kill %1 2>/dev/null
```

Esperado:

```
{"changed_email_to":"attacker@evil.example","authenticated_by":"cookie only"}
403
{"changed_email_to":"owner@shop.example"}
```

> **Perguntas — bloco 8**
>
> 1. `/users/safe` usa placeholders `?`. Explique o que o driver do banco de dados faz que o escaping de strings não faz — e por que "eu escapo aspas com uma função auxiliar" é uma afirmação mais fraca do que "eu uso bind parameters".
> 2. Seu ORM oferece `.raw("SELECT ... WHERE name = %s")`. Isso é seguro? Sob qual única condição volta a ser inseguro?
> 3. O endpoint "safe" do passo 4 escapa a saída em vez de sanitizar a entrada. Dê a razão arquitetural de a codificação de saída ser o lugar correto, e cite um contexto em que o escaping HTML é o codificador *errado*.
> 4. A correção de CSRF verifica `Origin` **e** um token. Por que nenhum dos dois basta sozinho na prática, e onde `SameSite=Lax` se encaixa como uma terceira camada?
> 5. `SameSite=Lax` ainda permite navegação `GET` de nível superior entre sites. Que regra de design isso impõe à sua API, e de qual definição HTTP ela vem?
> 6. O endpoint vulnerável devolve o SQL gerado ao chamador. Independentemente da injeção, cite a categoria OWASP a que isso sozinho pertence e o que um atacante aprende com ela.

---

## Exercício 9 — O contrato da API: OpenAPI como fronteira de acoplamento

**Passo 1.** Exporte o contrato legível por máquina da aplicação em execução e congele-o.

```bash
cd ~/lab-701.1
.venv/bin/python -c "import json; from app.main import app; print(json.dumps(app.openapi(), indent=2, sort_keys=True))" > openapi.json
.venv/bin/python -c "import json; d=json.load(open('openapi.json')); print(d['openapi'], sorted(d['paths']))"
cp openapi.json openapi.frozen.json
```

Esperado:

```
3.1.0 ['/orders', '/orders/{order_id}']
```

**Passo 2.** Leia como fica um contrato escrito à mão para o mesmo endpoint, incluindo as partes que o gerador não consegue inferir — o comportamento de requisição condicional e o media type de erro.

```yaml
openapi: "3.1.0"
info:
  title: "Orders"
  version: "1.0.0"
paths:
  "/orders/{orderId}":
    get:
      operationId: "getOrder"
      parameters:
        - name: "orderId"
          in: "path"
          required: true
          schema:
            type: "string"
            format: "uuid"
        - name: "If-None-Match"
          in: "header"
          required: false
          schema:
            type: "string"
      responses:
        "200":
          description: "The order"
          headers:
            ETag:
              required: true
              schema:
                type: "string"
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/Order"
        "304":
          description: "Client cache is still valid; no body is returned"
        "404":
          description: "No such order"
          content:
            application/problem+json:
              schema:
                $ref: "#/components/schemas/Problem"
components:
  schemas:
    Order:
      type: "object"
      required: ["id", "sku", "qty", "status"]
      properties:
        id:
          type: "string"
          format: "uuid"
        sku:
          type: "string"
          maxLength: 32
        qty:
          type: "integer"
          minimum: 1
          maximum: 100
        status:
          type: "string"
          enum: ["placed", "picked", "shipped", "cancelled"]
    Problem:
      type: "object"
      required: ["type", "title", "status"]
      properties:
        type:
          type: "string"
          format: "uri"
        title:
          type: "string"
        status:
          type: "integer"
        detail:
          type: "string"
```

**Passo 3.** Escreva o detector de mudanças quebradiças que pertence ao CI.

```bash
cd ~/lab-701.1
cat > check_contract.py <<'EOF'
import json
import sys

old = json.load(open(sys.argv[1]))
new = json.load(open(sys.argv[2]))
breaks = []

for path, ops in old.get("paths", {}).items():
    if path not in new.get("paths", {}):
        breaks.append(f"removed path: {path}")
        continue
    for verb in ops:
        if verb not in new["paths"][path]:
            breaks.append(f"removed operation: {verb.upper()} {path}")

old_schemas = old.get("components", {}).get("schemas", {})
new_schemas = new.get("components", {}).get("schemas", {})
for name, schema in old_schemas.items():
    if name not in new_schemas:
        breaks.append(f"removed schema: {name}")
        continue
    gone = set(schema.get("properties", {})) - set(new_schemas[name].get("properties", {}))
    for prop in sorted(gone):
        breaks.append(f"removed response field: {name}.{prop}")
    added_required = set(new_schemas[name].get("required", [])) - set(schema.get("required", []))
    for prop in sorted(added_required):
        breaks.append(f"newly required field: {name}.{prop}")

for line in breaks:
    print(f"BREAKING: {line}")
print(f"{len(breaks)} breaking change(s)")
sys.exit(1 if breaks else 0)
EOF
.venv/bin/python check_contract.py openapi.frozen.json openapi.json; echo "exit=$?"
```

Esperado:

```
0 breaking change(s)
exit=0
```

**Passo 4.** Introduza uma mudança quebradiça e veja o CI pegá-la. Edite `app/main.py` para que `OrderIn` exija um novo campo:

```bash
cd ~/lab-701.1
sed -i 's/    qty: int = Field(gt=0, le=100)/    qty: int = Field(gt=0, le=100)\n    warehouse: str = Field(min_length=1)/' app/main.py
.venv/bin/python -c "import json; from app.main import app; print(json.dumps(app.openapi(), indent=2, sort_keys=True))" > openapi.json
.venv/bin/python check_contract.py openapi.frozen.json openapi.json; echo "exit=$?"
```

Esperado:

```
BREAKING: newly required field: OrderIn.warehouse
1 breaking change(s)
exit=1
```

**Passo 5.** Reverta e torne o campo aditivo.

```bash
cd ~/lab-701.1
sed -i 's/    warehouse: str = Field(min_length=1)/    warehouse: str = Field(default="default", min_length=1)/' app/main.py
.venv/bin/python -c "import json; from app.main import app; print(json.dumps(app.openapi(), indent=2, sort_keys=True))" > openapi.json
.venv/bin/python check_contract.py openapi.frozen.json openapi.json; echo "exit=$?"
```

Esperado:

```
0 breaking change(s)
exit=0
```

**Passo 6.** Escreva um teste de contrato de consumidor — a verificação de que as expectativas do *cliente* continuam valendo.

```bash
cd ~/lab-701.1
cat > test_contract.py <<'EOF'
from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_create_order_returns_location_and_identifier():
    response = client.post("/orders", json={"sku": "SKU-1", "qty": 2})
    assert response.status_code == 201
    assert "location" in response.headers
    body = response.json()
    assert {"id", "sku", "qty", "status"} <= set(body)


def test_idempotency_key_collapses_duplicates():
    headers = {"Idempotency-Key": "fixed-key-for-the-test"}
    first = client.post("/orders", json={"sku": "SKU-2", "qty": 1}, headers=headers)
    second = client.post("/orders", json={"sku": "SKU-2", "qty": 1}, headers=headers)
    assert first.status_code == 201
    assert second.status_code == 200
    assert first.json()["id"] == second.json()["id"]


def test_unknown_order_is_not_found():
    assert client.get("/orders/00000000-0000-0000-0000-000000000000").status_code == 404
EOF
.venv/bin/pip install --quiet "httpx==0.28.1"
.venv/bin/python -m pytest -q test_contract.py
```

Esperado:

```
...                                                                      [100%]
3 passed in 0.41s
```

> **Perguntas — bloco 9**
>
> 1. O passo 4 sinalizou `newly required field` e o passo 5 não. Formule a regra geral sobre o que um provedor pode acrescentar a uma requisição e a uma resposta sem quebrar consumidores. Em qual direção está a assimetria?
> 2. O gerador produziu o contrato a partir do código. Cite o risco concreto dessa direção frente a escrever o contrato primeiro, e uma situação em que gerá-lo é, ainda assim, correto.
> 3. `test_contract.py` verifica `{"id","sku","qty","status"} <= set(body)` em vez de igualdade. Por que a verificação de subconjunto é a asserção certa para um teste de consumidor?
> 4. Uma mudança quebradiça é genuinamente necessária. Descreva a sequência de passos que a entrega sem um deploy coordenado em dia marcado, e cite o mecanismo que lhe diz quando a versão antiga pode ser removida.
> 5. O `404` no passo 2 declara `application/problem+json`. O que padronizar o corpo de erro dá a um cliente que inventar `{"error": "..."}` não dá?

---

## Exercício 10 — Servidores imutáveis e processos descartáveis

**Passo 1.** Escreva a definição da imagem.

```bash
cd ~/lab-701.1
cat > Containerfile <<'EOF'
FROM docker.io/library/python:3.12-slim

RUN useradd --create-home --uid 10001 app
WORKDIR /srv
COPY requirements.txt /srv/requirements.txt
RUN pip install --no-cache-dir -r /srv/requirements.txt
COPY app /srv/app
USER 10001
EXPOSE 8080
ENV PORT=8080
CMD ["python", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
EOF
cat > requirements.txt <<'EOF'
fastapi==0.115.6
uvicorn[standard]==0.34.0
EOF
```

**Passo 2.** Construa-a, marcada com o commit que a produziu.

```bash
cd ~/lab-701.1
git init -q 2>/dev/null; git add -A 2>/dev/null; git -c user.email=lab@example -c user.name=lab commit -qm "lab" 2>/dev/null
SHA=$(git rev-parse --short HEAD)
podman build -q -t "localhost/orders:$SHA" .
podman images --format '{{.Repository}}:{{.Tag}} {{.Size}}' | head -n 1
```

Esperado:

```
localhost/orders:3fa91c2 158 MB
```

**Passo 3.** Rode-a e confirme que o release vem do ambiente, não da imagem.

```bash
cd ~/lab-701.1
SHA=$(git rev-parse --short HEAD)
podman run -d --name orders-1 -p 8090:8080 \
  -e DATABASE_URL="sqlite:///orders.db" \
  -e SESSION_SECRET="lab-secret" \
  -e RELEASE="1.0.0+$SHA" \
  "localhost/orders:$SHA"
sleep 2
curl -sS http://127.0.0.1:8090/healthz; echo
```

Esperado:

```
{"status":"ok","release":"1.0.0+3fa91c2"}
```

**Passo 4.** Altere o contêiner em execução do jeito que um "hotfix rápido na máquina" faz, e depois reinicie-o.

```bash
podman exec -u 0 orders-1 sh -c 'echo "PATCHED BY HAND" > /srv/app/hotfix.txt && cat /srv/app/hotfix.txt'
podman restart orders-1 >/dev/null && sleep 2
podman exec orders-1 sh -c 'cat /srv/app/hotfix.txt 2>&1 || true'
```

Esperado — a escrita sobrevive a um restart do mesmo contêiner, que é precisamente a armadilha:

```
PATCHED BY HAND
PATCHED BY HAND
```

**Passo 5.** Agora faça o que o orquestrador faz — substitua o contêiner a partir da imagem.

```bash
SHA=$(git rev-parse --short HEAD)
podman rm -f orders-1 >/dev/null
podman run -d --name orders-1 -p 8090:8080 \
  -e DATABASE_URL="sqlite:///orders.db" -e SESSION_SECRET="lab-secret" -e RELEASE="1.0.0+$SHA" \
  "localhost/orders:$SHA" >/dev/null
sleep 2
podman exec orders-1 sh -c 'cat /srv/app/hotfix.txt 2>&1 || true'
```

Esperado:

```
cat: /srv/app/hotfix.txt: No such file or directory
```

**Passo 6.** Verifique o desligamento gracioso. Adicione um endpoint lento, rode-o fora do contêiner para poder observar os logs, inicie uma requisição e envie `SIGTERM` no meio do voo.

```bash
cd ~/lab-701.1
cat >> app/main.py <<'EOF'


@app.get("/slow", include_in_schema=False)
async def slow():
    import asyncio
    await asyncio.sleep(6)
    return {"status": "finished despite shutdown"}
EOF
.venv/bin/uvicorn app.main:app --port 8095 &
UV=$!
sleep 2
curl -sS http://127.0.0.1:8095/slow &
sleep 1
kill -TERM $UV
wait
```

Esperado — a requisição em voo é drenada, não cortada:

```
INFO:     Shutting down
INFO:     Waiting for connections to close. (CTRL+C to force quit)
{"status":"finished despite shutdown"}
INFO:     Waiting for application shutdown.
INFO:     Application shutdown complete.
INFO:     Finished server process [24701]
```

**Passo 7.** Limpeza.

```bash
podman rm -f orders-1 >/dev/null 2>&1; echo cleaned
```

> **Perguntas — bloco 10**
>
> 1. O patch manual do passo 4 sobreviveu ao `podman restart` e o do passo 5 não. Explique a diferença em termos do ciclo de vida do contêiner e diga por que o primeiro comportamento é mais perigoso do que se o patch tivesse desaparecido imediatamente.
> 2. A imagem é marcada com o SHA do commit em vez de `latest`. Cite três problemas operacionais distintos que uma tag móvel `latest` causa.
> 3. `podman commit` pode tirar um snapshot de um contêiner em execução e com patch aplicado, gerando uma nova imagem. Por que isso é um antipadrão sob os princípios de infraestrutura imutável, e qual é o único uso legítimo?
> 4. No passo 6, o uvicorn continuou servindo até a requisição em voo terminar. Descreva o que um orquestrador precisa fazer *além disso* para que um rolling update seja genuinamente sem downtime, e de qual sinal de readiness ele depende.
> 5. A imagem roda como UID 10001 e a aplicação não escreve nada no sistema de arquivos. Qual fator do twelve-factor isso apoia, e o que você teria de mudar para tornar o sistema de arquivos somente leitura?
6. `DATABASE_URL` aponta para um SQLite dentro do contêiner. Enuncie por que isso é aceitável neste laboratório e exatamente qual propriedade isso destrói em produção.

---

## Respostas

<details>
<summary>Clique para revelar as respostas de todos os dez blocos</summary>

### Bloco 1 — Encontrando as costuras

**1.** Uma função que toca exatamente uma tabela não tem nenhuma transação cruzando fronteiras para quebrar. `restock` vira um endpoint do serviço Inventory e `create_customer` um endpoint do serviço Customers, sem mais nada a negociar — a divisão é mecânica. "Soa como um domínio" é uma hipótese sobre linguagem; "toca uma tabela" é uma observação sobre o acoplamento transacional que de fato vai lhe morder. Linguagem de domínio e propriedade de dados costumam concordar, mas quando discordam, os dados vencem, porque o banco de dados é onde vive a atomicidade que você está prestes a perder. Comece pelas costuras que o código já tem, não pelas que você gostaria que ele tivesse.

**2.** As duas respostas são (a) **composição de API**: o chamador do relatório busca o cliente no Customers e os pedidos no Orders e faz o join no código da aplicação; o custo é padrões de chamada N+1, latência adicional, tratamento de falha parcial e nenhuma capacidade de filtrar ou ordenar eficientemente entre os dois conjuntos de dados. (b) **Replicação de dados / read model CQRS**: Orders assina eventos de cliente e mantém uma cópia local dos campos de que precisa, de modo que o join volta a ser local; o custo é consistência eventual, um pipeline de replicação para operar e os dados duplicados envelhecendo ou divergindo. Não existe uma terceira resposta que preserve ao mesmo tempo consistência forte e independência plena — essa é a troca que a divisão compra.

**3.** Escrever no `outbox` na mesma transação é o padrão **transactional outbox**, e ele torna "o pedido existe" e "o evento será publicado" um único fato atômico. Na versão "commit e depois publique" há uma janela entre o commit e o ack do broker: se o processo morre, reinicia ou o broker está inalcançável, o pedido existe e nenhum evento foi emitido. Nada rio abaixo — fulfillment, cobrança, o e-mail de confirmação — jamais acontece, e nenhum erro fica visível em lugar algum, porque o próprio pedido teve sucesso. Um processo relay separado então lê o `outbox` e publica com entrega at-least-once, que é por que os consumidores precisam ser idempotentes (veja o Exercício 3).

**4.** *Busca síncrona:* o endereço de e-mail está sempre atual — um cliente que mudou seu endereço dez segundos atrás recebe a confirmação no lugar certo; existe exatamente uma cópia e portanto nenhuma divergência, e o Customers permanece a única autoridade sobre os dados do cliente. *Cópia local:* o Orders pode registrar um pedido enquanto o Customers está fora do ar, o que importa enormemente porque "não podemos aceitar pedidos porque o diretório de clientes está degradado" é uma cascata que afeta receita; a latência também tem um salto de rede a menos no caminho crítico. A resposta usual em produção é a cópia, mais atualização orientada a eventos — e você aceita que uma confirmação possa ocasionalmente ir para um endereço recentemente substituído.

### Bloco 2 — Configuração e build/release/run

**1.** (a) O contêiner entra em **crash-loop imediatamente** em vez de iniciar, passar em seu liveness probe e então falhar em toda requisição; o `CrashLoopBackOff` do orquestrador e o status de saída não-zero viram o alerta, com o nome da variável faltante no log. (b) Um rolling update com um ConfigMap/Secret ruim ou incompleto **nunca conclui**, de modo que o deployment estagna com os pods antigos, funcionais, ainda servindo. Se a falha acontecesse na primeira requisição, os pods novos ficariam Ready, os antigos seriam derrubados, e você teria substituído um release funcional por um quebrado antes que qualquer coisa lhe avisasse.

**2.** A objeção não é ao YAML — é que o *conteúdo da configuração de produção está no repositório*. O teste do fator III é se o codebase poderia se tornar open source neste exato instante sem vazar uma credencial; `production.yaml` com uma senha de banco de dados reprova nesse teste. Isso também acopla mudanças de configuração a deploys de código (mudar um timeout exige um commit, um build e um release), e o número de valores de `APP_ENV` cresce a cada ambiente, de modo que os "ambientes" viram uma enumeração fechada dentro do código. O que é aceitável: um arquivo de **defaults** com valores não secretos e independentes de ambiente versionado, sobrescrito por variáveis de ambiente. A regra é: valores por deploy no ambiente, valores invariantes no build.

**3.** Satisfaz o **fator V, separação estrita de build, release e run**: um artefato de build imutável, combinado com configurações diferentes para formar releases diferentes. Se staging usasse `orders:1.0.0-staging`, os bytes que você testou em staging não seriam os bytes rodando em produção — um build diferente, com um cache de camadas diferente, possivelmente um digest de imagem base diferente e uma resolução de dependências transitivas diferente. Todo resultado de staging seria então evidência sobre um artefato que você não está entregando, que é exatamente a classe de bug "funciona em staging" mais difícil de diagnosticar.

**4.** Um valor pode carregar um default quando um **valor errado mas plausível é inofensivo e detectável**; não pode quando um valor errado é ou inseguro ou silenciosamente incorreto. `PORT=8080` é inofensivo: se estiver errado, nada conecta e você descobre em segundos. `SESSION_SECRET` com um default é catastrófico: a aplicação inicia, funciona perfeitamente, e todo cookie de sessão em produção é forjável por qualquer um que leia o código-fonte. O mesmo raciocínio proíbe defaults para `DATABASE_URL` — um default apontando para um arquivo SQLite local deixaria a produção iniciar e acumular dados silenciosamente em um arquivo que some no próximo restart do pod.

### Bloco 3 — Semântica REST

**1.** `Location` dá ao cliente a **URI canônica atribuída pelo servidor** do novo recurso, coisa que o `id` do corpo sozinho não dá: caso contrário, o cliente teria de conhecer o template da URI (`/orders/{id}`) e construí-la, cravando seu roteamento dentro de cada consumidor. Com `Location`, o servidor pode mover recursos para `/v2/orders/`, fragmentá-los em outro host ou emitir identificadores opacos, e o cliente continua funcionando ao seguir a URI que recebeu.

**2.** O `201` na primeira resposta é uma afirmação factual: *um recurso foi criado por esta requisição*. A segunda requisição não criou nada; retornar `201` de novo seria uma mentira sobre a qual o cliente pode agir — um cliente que registra "pedido criado" a cada `201` contaria em dobro, e um intermediário contando criações também. `200` com o mesmo corpo e o mesmo `Location` diz com verdade "eis o recurso a que sua chave se refere; ele já existia". A visão alternativa — sempre `201`, sob o argumento de que a intenção do cliente foi satisfeita de qualquer forma — é defensável e algumas APIs fazem isso; o argumento decisivo contra é que o código de status descreve o que *aconteceu*, não o que o cliente queria.

**3.** Idempotência significa *o efeito de N requisições idênticas é igual ao efeito de uma*. `DELETE` em um pedido já cancelado tem exatamente essa propriedade: a pós-condição que o cliente pediu ("este pedido está cancelado") é verdadeira, então retornar sucesso é correto, não uma mentira — e um cliente que tenta de novo depois de uma resposta perdida recebe uma resposta limpa em vez de um erro espúrio. O pedido enviado é diferente em natureza: a pós-condição requisitada **não pode ser alcançada de forma alguma**, não importa quantas vezes você peça. `409 Conflict` reporta um conflito com o estado atual do recurso e, ao contrário de um timeout, não deve ser repetido — o cliente precisa de uma ação diferente (uma devolução, um recall), não de outra tentativa.

**4.** `400 Bad Request` diz que a requisição está malformada no nível de protocolo ou sintaxe — JSON truncado, um `Content-Type` ruim, um corpo impossível de parsear. `422 Unprocessable Content` diz que a sintaxe estava boa e o servidor entendeu, mas a *semântica* está errada — `qty: 0` é JSON válido e do tipo certo, só não é um valor permitido. A diferença para o cliente é concreta: no `400` o cliente tem um bug de serialização ou transporte e repetir os mesmos bytes é inútil; no `422` os dados do cliente estão errados e ele geralmente pode mapear o campo `loc` do erro direto para um campo de formulário e mostrar ao usuário o que corrigir.

**5.** Porque o schema *é* o contrato, e a validação na borda é o que torna o contrato exigível em vez de aspiracional. Três consequências seguem. Primeira, todo handler abaixo da borda pode assumir que suas entradas estão bem formadas, de modo que não há reverificação defensiva espalhada pelo codebase nem caminho pelo qual um valor não validado chegue ao banco de dados. Segunda, as regras de validação são introspectáveis — elas geram o documento OpenAPI do Exercício 9, de modo que o contrato publicado não pode divergir do contrato aplicado. Terceira, rejeitar entrada ruim antes que qualquer lógica de negócio ou trabalho de banco rode é a falha mais barata possível, o que importa quando a entrada ruim é volume hostil e não um engano honesto.

### Bloco 4 — Cache e requisições condicionais

**1.** Economiza **banda e trabalho de serialização do servidor** — zero bytes de corpo, e a origem muitas vezes pode responder a partir de uma verificação barata do validador em vez de renderizar a representação completa. **Não** economiza o round-trip: a requisição ainda viaja até a origem e o cliente ainda espera um RTT completo. Essa troca é ruim quando a latência domina — um cliente móvel em um link de 300 ms buscando cinquenta recursos pequenos paga cinquenta round-trips para não aprender nada. Ali, um tempo de frescor (`max-age`) é o que você quer, porque uma resposta cacheada fresca é servida sem nenhuma rede; validadores são para quando a correção exige perguntar.

**2.** Com `public`, um CDN compartilhado guarda a representação do pedido de Alice sob a URL `/orders/{id}` e serve exatamente esses bytes ao próximo requisitante daquela URL — um vazamento de dados entre clientes, e do pior tipo, porque é intermitente, invisível nos seus próprios logs e depende de uma topologia de cache que você não controla. `private` diz aos caches compartilhados que eles não podem armazená-la, ainda permitindo o cache do próprio navegador. Se uma resposta genuinamente varia por credencial e você ainda quer cache compartilhado, precisa enviar `Vary: Authorization` para que o cache também chaveie pela credencial — mas `private` mais autorização é o default seguro para dados por cliente, e `Vary: Authorization` é um header fácil de um intermediário tratar mal.

**3.** Um `updated_at` com granularidade de segundo não consegue distinguir duas mudanças que acontecem dentro do mesmo segundo. A falha é um lost update do ponto de vista do cliente: um cliente busca em `t`, o recurso é modificado duas vezes em `t+0,2` e `t+0,7`, e o validador é idêntico para ambas — então o `If-None-Match` do cliente casa, ele recebe `304`, e fica com uma representação duas revisões desatualizada sem ter como saber. É exatamente por isso que o HTTP distingue validadores fortes de fracos: só um validador forte pode ser usado para requisições de intervalo de bytes e para `If-Match` em escritas. Um hash do corpo é forte por construção.

**4.** Isto é **controle de concorrência otimista**. O cliente A faz `GET` no pedido e recebe `ETag: "abc"`. O cliente B faz o mesmo. A envia `PUT /orders/{id}` com `If-Match: "abc"`; o servidor compara, casa, aplica a escrita, e o ETag do recurso passa a ser `"def"`. B agora envia seu `PUT` com `If-Match: "abc"`; o servidor compara, não casa, e rejeita com **`412 Precondition Failed`**. B precisa buscar de novo, ver a mudança de A e decidir — mesclar, tentar de novo ou expor o conflito ao usuário. Sem `If-Match`, a escrita de B simplesmente sobrescreve a de A e ninguém fica sabendo de nada. Note a distinção em relação ao `409`: `412` diz "sua pré-condição era falsa"; `409` diz "o estado do recurso proíbe isto independentemente de pré-condições".

### Bloco 5 — Statelessness

**1.** Viola o **fator VI, processos são stateless e nada compartilham** — o carrinho vivia no heap de um processo, então existia para exatamente uma das duas réplicas. Sticky sessions aparentam corrigir isso e custam justamente aquilo pelo que você escalou: durante um rolling deploy, cada pod em terminação leva suas sessões junto, de modo que uma fração dos usuários perde seus carrinhos a *cada deploy*; o load balancer já não consegue balancear, então uma instância quente não pode ser aliviada; o autoscaling para dentro só ajuda as instâncias sem sessões; e você já não consegue drenar um nó para manutenção sem perda visível ao usuário. Você trocou um problema de roteamento por um problema de deployment, que é o pior dos dois porque recorre a cada release.

**2.** O atacante **pode ler todo o conteúdo** — é base64, não criptografia — e pode decodificá-lo offline com calma. O atacante **não pode modificá-lo sem ser detectado**, porque qualquer alteração no corpo invalida o HMAC e `unseal` lança a exceção. Portanto o cookie nunca pode conter nada confidencial: nenhum endereço de e-mail, nenhum identificador interno de usuário que você trate como secreto, nenhum dado de direitos que você não imprimiria num cartão-postal e, acima de tudo, nenhuma credencial ou token para outros sistemas. SKUs de carrinho estão ok. Se você precisa de confidencialidade além de integridade, precisa de criptografia autenticada, não de uma assinatura.

**3.** **Redis vence decisivamente em revogação.** Um session store no servidor torna a revogação um único `DEL` — a sessão some na próxima requisição, em todo lugar, imediatamente. Isso importa para logout-everywhere, para uma troca de senha, para uma conta que você acabou de descobrir comprometida. O cookie assinado é autocontido precisamente para que o servidor não precise ser consultado, que é a mesma razão pela qual o servidor não pode desemiti-lo. As compensações são todas parciais: tempos de expiração curtos mais refresh (encolhe mas não fecha a janela, e adiciona um endpoint de refresh que é ele mesmo uma consulta no servidor), uma claim `jti` verificada contra uma deny-list (o que reintroduz o store compartilhado que você evitava, ainda que só para a minoria revogada), ou um `token_version` por usuário incrementado na revogação (uma consulta barata, granularidade mais grossa). Escolha a troca deliberadamente; não finja que a janela não existe.

**4.** Um diretório local de uploads é estado que (a) não é replicado para as outras instâncias, de modo que um upload escrito pela réplica A retorna 404 quando a próxima requisição cai na réplica B; (b) não sobrevive à substituição do contêiner, então cada deploy perde arquivos; e (c) torna as instâncias não intercambiáveis, que é a definição do problema. A resposta do twelve-factor é o **fator IV, trate serviços de apoio como recursos anexados**: object storage (compatível com S3) ou um sistema de arquivos de rede montado, endereçado por uma URL no ambiente, de modo que qualquer instância alcance os mesmos bytes e destruir uma instância não destrua nada. O sistema de arquivos local só pode ser usado como área de rascunho dentro de uma única requisição.

### Bloco 6 — Acoplamento fraco

**1.** Cada requisição à dependência lenta ocupa um worker pela duração. Sem timeout, essa duração é ilimitada. Novas requisições chegam à taxa normal, cada uma tomando um worker e nunca devolvendo, de modo que o pool drena na taxa de chegada; uma vez que todo worker está parado em uma leitura de socket, as requisições enfileiram no accept backlog, a latência sobe até o limite de enfileiramento, e então a fila de listen transborda ou o próprio endpoint de health-check não pode ser servido — momento em que o load balancer marca a instância como não saudável e desloca seu tráfego para as outras instâncias, que já estão falhando do mesmo jeito. O serviço inteiro está fora por causa de uma dependência que estava apenas lenta e — a parte cruel — a dependência pode ter estado lenta só em um endpoint que importava a 2% do tráfego.

**2.** C recebe **9** requisições por requisição original do cliente: A faz 3 tentativas a B, e cada tentativa de B faz 3 a C. A fórmula geral para n camadas encadeadas, cada uma com r tentativas, é **rⁿ⁻¹** requisições na camada mais profunda por requisição original (com tentativas contadas como total de tries, então "2 retries" significa r = 3). Isso é amplificação de retries, e é por isso que um serviço em dificuldades é atingido *com mais força* no momento em que começa a falhar — a carga se multiplica exatamente quando a capacidade cai. As duas mitigações: **retry em apenas uma camada** (normalmente a mais externa, mais próxima do cliente, com as camadas internas falhando rápido e propagando), e **backoff exponencial com full jitter** para que os retries se espalhem no tempo em vez de chegarem como uma manada sincronizada. Um orçamento de retries — limitar retries a uma porcentagem do total de requisições — é o terceiro item, de nível de produção.

**3.** Duas partes se beneficiam. **O chamador** para de queimar um worker, uma conexão e 1 s de latência por requisição em um resultado que ele já consegue prever, de modo que se mantém saudável e serve a resposta degradada rapidamente. **A dependência** ganha uma chance de se recuperar: um serviço colapsando sob carga não consegue drenar suas filas se os chamadores mantêm a pressão, e o circuito aberto remove essa pressão por completo. Baixar o timeout para 0,1 s ajuda só a primeira parte e prejudica a segunda — você ainda envia todas as requisições, ainda consome a accept queue e o thread pool da dependência, e agora também falha requisições que a dependência poderia ter servido em 0,15 s. O breaker distingue "esta chamada está lenta" de "esta dependência está fora", o que um timeout não consegue.

**4.** Você tem uma estampida de recuperação. Durante o cooldown, as requisições upstream vêm enfileirando, repetindo e acumulando; liberar todas de uma vez atinge uma dependência que acabou de voltar com caches frios, pools de conexão vazios e JITs sem aquecimento — então ela falha de novo imediatamente, o circuito reabre, e você oscila. O design de sonda única do `half-open` faz com que o custo de estar errado seja exatamente uma requisição: se falha, volta a aberto sem dano; se tem sucesso, fecha e retoma. Implementações de produção normalmente fazem rampa em vez de saltar direto para o tráfego total.

**5.** Orders publica uma mensagem `order.placed` e retorna ao cliente imediatamente; Pricing a consome no seu próprio ritmo e publica `order.priced`, que Orders consome para atualizar o registro. **Ganho:** desacoplamento temporal — Pricing pode ficar fora por uma hora, ser reiniciado ou escalado a zero, e os pedidos continuam sendo aceitos, com o broker absorvendo o backlog; os dois serviços deixam de compartilhar destino, e você pode adicionar um segundo consumidor de `order.placed` sem tocar em Orders. **Perda:** a resposta síncrona. O preço não pode ser mostrado ao cliente na resposta, então a UI precisa tratar um estado pendente; o sistema passa a ser eventualmente consistente, então "o pedido existe mas ainda não tem preço" é agora um estado real que você precisa modelar, exibir e monitorar; a entrega é at-least-once, então todo consumidor precisa ser idempotente; e depurar fica mais difícil porque a cadeia causal já não é um único stack trace. Você também acrescentou o broker como uma nova dependência operacional.

### Bloco 7 — Armazenamento de dados

**1.** A restrição verifica o *valor sendo escrito*, e todo valor escrito no passo 3 era legal. Vinte threads leram cada uma `on_hand = 5`, cada uma concluiu `5 >= 1`, e cada uma escreveu `4` — um número perfeitamente válido e que satisfaz a restrição. Dezenove dessas escritas são **lost updates**: elas se sobrescreveram, e o banco de dados não tem como saber que o `4` foi calculado a partir de um `5` que já estava obsoleto na hora em que foi escrito. Esta é a lição central: restrições validam estados, não serializam operações. A leitura e a escrita eram duas transações separadas com uma lacuna desprotegida entre elas, e a correção aqui dependia de essa lacuna não existir. O decremento precisa ser expresso como uma única operação atômica, ou a leitura precisa tomar um lock que a escrita ainda segure.

**2.** O comando é seguro porque a **leitura e a escrita acontecem atomicamente dentro de um único comando**: `on_hand = on_hand - 1 WHERE ... AND on_hand >= 1` avalia o predicado e aplica o decremento sob o lock de linha que o próprio `UPDATE` toma, de modo que nenhuma outra transação consegue observar ou modificar a linha no intervalo. O `rowcount` então lhe diz com verdade se você conseguiu uma unidade. O equivalente no PostgreSQL quando a lógica é complexa demais para um único comando é **`SELECT ... FOR UPDATE`**: tome o lock de linha no momento da leitura e segure-o até a escrita dentro de uma transação, de modo que vendedores concorrentes bloqueiem em vez de correrem. (`SELECT ... FOR UPDATE SKIP LOCKED` é o idioma relacionado para cargas semelhantes a filas, onde você quer a próxima linha *disponível* em vez de esperar.)

**3.** (a) **Um update condicional / atômico no próprio document store** — o `findAndModify` do MongoDB com um predicado no campo de estoque, ou a escrita condicional do DynamoDB, ou um compare-and-set em nível de documento sobre um campo de versão. Custo: funciona só por documento, então o invariante precisa ser expressável dentro de um documento; no momento em que sua regra abrange dois documentos, você voltou ao ponto de partida. (b) **Tire o invariante do store** — uma partição de escritor único por SKU (um ator, um consumidor particionado, um lock distribuído), de modo que duas operações para um SKU nunca sejam concorrentes. Custo: um fardo de disponibilidade e complexidade — o serviço de lock vira uma dependência que pode falhar, e a partição vira um teto de throughput e um ponto quente. Uma terceira resposta, genuinamente comum, é **aceitar a venda além do estoque e compensar** — reserve otimisticamente, detecte a violação de forma assíncrona e cancele ou coloque em backorder. Essa é a escolha certa com mais frequência do que os engenheiros gostam de admitir, porque o custo de negócio de uma venda além do estoque rara é muitas vezes bem menor que o custo de disponibilidade da serialização estrita. O ponto é que precisa ser uma decisão, não um acidente.

**4.** Quando a existência do documento precisa ser **transacionalmente idêntica** à da linha, e o volume é pequeno. Um registro assinado com relevância fiscal, em que "a linha da nota fiscal existe mas o PDF não" é uma falha de conformidade e não um retry, é o caso canônico: o `BLOB` lhe dá commit-ou-rollback para ambos em uma única transação, ao passo que linha-mais-chave-de-objeto lhe dá uma janela em que um existe sem o outro e exige um outbox ou um job de reconciliação para fechá-la. Em baixo volume, os argumentos de IOPS e backup simplesmente não mordem. O limiar é aproximadamente quando o volume total de blobs começa a dominar o tempo de backup ou o RTO de restauração — momento em que você migra para object storage e paga pela reconciliação.

**5.** **Pode ser cacheado:** a descrição do produto, nome, imagens, categoria — dados que mudam raramente e cuja obsolescência não custa nada. **Não pode ser cacheado para a decisão:** o nível de estoque usado para decidir se uma venda pode prosseguir; essa leitura precisa vir do store autoritativo dentro da mesma operação atômica da escrita, que é exatamente o que o comando `cas` faz. "Cachear o nível de estoque por 5 segundos" soa prudente e é perigoso porque reintroduz a lacuna de read-modify-write do passo 3 com uma largura *garantida* de 5 segundos em vez de uma lacuna de corrida de 10 milissegundos — você institucionalizou o bug. A versão viável é cachear um nível de estoque de *exibição* ("em estoque" / "estoque baixo") para a página de catálogo, claramente separado do caminho autoritativo de decremento, e aceitar que a página pode dizer "em estoque" para um item que se esgota um segundo depois. Todo sistema real de e-commerce faz exatamente isso, que é por que o checkout, e não a página de produto, é onde você descobre.

### Bloco 8 — Segurança de aplicações

**1.** Com bind parameters o comando SQL é enviado ao banco de dados **separadamente dos valores**, e o comando é parseado e planejado antes de qualquer valor ser anexado. Não resta nenhuma etapa de parsing em que um valor pudesse virar sintaxe — `' OR '1'='1` chega como uma string de 12 caracteres para comparar com `name`, e não casa com nenhuma linha. O escaping tenta atingir o mesmo resultado *transformando o valor para que o parser não o leia errado*, o que significa que a função de escaping precisa modelar o parser exatamente: cada modo de quoting, cada conjunto de caracteres (a quebra clássica é uma codificação multibyte em que uma sequência forjada consome a barra invertida do escaping), cada dialeto SQL, cada versão. Um descompasso e a garantia se foi. "Eu uso bind parameters" é uma afirmação estrutural sobre onde está a fronteira; "eu escapo aspas" é a afirmação de que sua função de string e o parser do banco concordam sobre tudo, para sempre.

**2.** Sim, `%s` nessa forma é um placeholder de bind parameter passado ao driver, não formatação de string do Python — o driver o parametriza. Torna-se inseguro no momento em que alguém escreve `.raw(f"SELECT ... WHERE name = '{name}'")` ou `.raw("SELECT ... WHERE name = %s" % name)`, que parecem quase idênticos em um diff e são exatamente o bug. Também é inseguro para as partes de um comando que **não podem** ser parametrizadas — nomes de tabela, nomes de coluna, alvos de `ORDER BY`, `ASC`/`DESC`. Essas precisam ser validadas contra uma allow-list de identificadores conhecidos e bons; não há placeholder que o salve ali, e um `ORDER BY {user_column}` dinâmico é um ponto de injeção vivo em código de resto bem escrito.

**3.** Porque a codificação correta **depende do contexto em que o dado aterrissa**, e esse contexto é conhecido no momento da saída, não no da entrada. A mesma string é segura em um nó de texto HTML, perigosa sem aspas em um atributo HTML, precisa de escaping de string JavaScript dentro de um `<script>`, precisa de codificação de URL em um parâmetro de query e precisa de escaping CSS em um bloco de estilo. Sanitizar na entrada obriga você a adivinhar todos os destinos futuros, corrompe dados legítimos (um apóstrofo em `O'Brien`, um `<` em uma fórmula matemática) e falha silenciosamente no momento em que alguém adiciona um novo template. Codifique no destino, onde você conhece o destino. O escaping HTML é **errado** quando o valor é interpolado em um contexto JavaScript — `var q = "<%= html_escape(q) %>"` deixa `</script>` e sequências de barra invertida exploráveis, e é um bypass bem conhecido; esse contexto precisa de um codificador de string JavaScript, ou melhor, passe o valor como JSON por um data attribute. É igualmente errado para um contexto de URL, onde `&amp;` não é o que você quer. O header CSP é defesa em profundidade para quando a codificação for esquecida em algum lugar.

**4.** Nenhum é suficiente sozinho. **`Origin` sozinho** falha porque está ausente em algumas requisições legítimas (certas navegações e clientes mais antigos), então você precisa decidir o que fazer quando ele falta — rejeitar e quebrar usuários reais, ou aceitar e perder a defesa; proxies e gateways também podem reescrevê-lo, e origens `null` de contextos em sandbox complicam a allow-list. **Um token sozinho** falha se vazar — por uma URL em um `Referer`, um XSS que lê o DOM, um subdomain takeover lendo um cookie com escopo amplo demais — ou se a comparação do framework for fraca. Juntos, eles exigem que um atacante derrote dois mecanismos independentes. **`SameSite=Lax`** é a terceira camada, imposta pelo navegador: o navegador simplesmente não anexa o cookie a `POST`s cross-site, então a requisição forjada chega sem autenticação e as verificações do lado do servidor nem precisam disparar. É a mais forte das três porque não depende de o código da sua aplicação estar correto — mas depende do navegador do usuário, não protege contra um atacante same-site (outra aplicação em um subdomínio irmão) e não substitui o token, razão pela qual a resposta em camadas é a correta.

**5.** `Lax` anexa o cookie a **navegações `GET` de nível superior** cross-site — um clique em link, um redirecionamento, um `window.location`. Portanto, se qualquer operação que altera estado for alcançável por `GET`, `SameSite=Lax` não a protege: `<img src="https://shop.example/account/delete">` na página de um atacante é uma requisição quase de nível superior que o navegador autenticará de bom grado. A regra de design é, portanto, que **`GET` (e `HEAD`) devem ser seguros** — sem efeitos colaterais, sem mudança de estado, jamais — e toda mutação deve usar `POST`, `PUT`, `PATCH` ou `DELETE`. Isso vem da definição de métodos *seguros* na semântica HTTP (RFC 9110 §9.2.1), e não é meramente uma convenção: navegadores, proxies, crawlers, prefetchers de links e aceleradores todos assumem isso. Um endpoint como `GET /orders/123/cancel` acabará sendo disparado por um buscador indexando uma página, sem nenhum atacante envolvido.

**6.** **Configuração incorreta de segurança** — mais precisamente, saída verbosa de erro e depuração exposta ao chamador (a categoria A05 do OWASP Top 10, com a fraqueza subjacente sendo exposição de informação sensível por meio de uma mensagem de erro). Independentemente de a injeção ter sucesso, o atacante aprende o dialeto SQL exato e seu comportamento de quoting, os nomes reais de tabelas e colunas, como a query é construída (a interpolação de strings é visível no formato da saída) e, portanto, exatamente como forjar um payload — transformando um exercício de sondagem cega em um exercício direcionado. A mesma categoria cobre stack traces, banners de versão de framework e listagens de diretório: cada um individualmente "não é uma vulnerabilidade" e coletivamente é o reconhecimento que torna barato encontrar a vulnerabilidade de verdade.

### Bloco 9 — O contrato

**1.** A regra é **"seja conservador no que você envia, liberal no que você aceita"**, aplicada por direção. Um provedor pode **acrescentar um campo opcional a uma requisição** (clientes antigos que o omitem continuam funcionando), mas não pode acrescentar um *obrigatório*, nem remover ou estreitar um existente. Um provedor pode **acrescentar um campo a uma resposta** (clientes antigos ignoram o que não conhecem, desde que não validem estritamente), mas não pode remover um, nem mudar o tipo de um campo, nem remover um valor de um enum sobre o qual um cliente possa estar fazendo switch. A assimetria é que **requisições quebram com adições e respostas quebram com remoções**, porque o consumidor constrói a requisição e consome a resposta — você não consegue quebrar alguém dando-lhe mais do que pediu, mas consegue exigindo mais do que ele sabia enviar. Acrescentar um valor a um enum de resposta é o caso sutil: é uma adição, mas quebra qualquer consumidor com um `match` exaustivo, razão pela qual enums devem ser documentados como abertos desde o primeiro dia.

**2.** Gerar o contrato a partir do código significa que o contrato só consegue descrever o que o código já faz, de modo que ele não pode ser um instrumento de design nem um artefato de negociação — a equipe consumidora não tem nada para revisar até que o provedor já tenha construído, e qualquer estranheza na implementação vira um formato de API publicado. Também significa que uma mudança acidental no código silenciosamente vira uma mudança no contrato; o diff contra a baseline congelada do passo 3 existe precisamente para recolocar um portão nesse caminho. Gerá-lo é, ainda assim, correto quando o código é a autoridade mais antiga — um serviço existente sendo documentado pela primeira vez, onde uma spec escrita à mão seria imediatamente uma segunda fonte da verdade que diverge. O padrão saudável para trabalho novo é contrato-primeiro para o design, e então gerar-e-comparar no CI para provar que a implementação continua batendo.

**3.** Porque o contrato do consumidor é "os campos de que eu dependo estão presentes e corretos", não "a resposta contém exatamente estes campos". Uma asserção de igualdade falharia no momento em que o provedor fizesse uma adição legítima e não quebradiça — um novo `created_at`, uma nova `currency` — transformando cada mudança aditiva em um build vermelho em todos os consumidores, o que ensina todo mundo a parar de confiar nos testes. A verificação de subconjunto codifica o acoplamento real: falha exatamente quando algo de que o consumidor precisa desaparece, e permanece verde no resto. Essa é toda a ideia por trás de contratos orientados ao consumidor — cada consumidor publica a fatia estreita que realmente usa, e o provedor fica livre em todo o resto.

**4.** **Expand / migrate / contract**, às vezes chamado de mudança paralela. (1) *Expand:* implante uma versão que suporte ambos os formatos simultaneamente — o novo campo é opcional e o antigo ainda é aceito, ou o novo endpoint existe ao lado do antigo; nada quebrou, e isso é entregue independentemente de cada consumidor. (2) *Migrate:* os consumidores migram para o novo formato no seu próprio ritmo, nos seus próprios ciclos de release, sem janela de coordenação. (3) *Contract:* remova o formato antigo. O mecanismo que lhe diz quando o passo 3 é seguro é **telemetria de uso por consumidor no caminho obsoleto** — um contador rotulado por identidade de cliente ou chave de API sobre o campo/endpoint antigo, mais um header `Deprecation` e `Sunset` nas respostas, para que os consumidores sejam avisados in-band. Você o remove quando o contador esteve em zero por mais tempo que o ciclo de release do seu consumidor mais lento, e você sabe *quem* cobrar quando não estiver. Adivinhar, ou anunciar uma data e torcer, é como os flag days voltam.

**5.** Um corpo de erro padrão (RFC 9457 *Problem Details*) significa que o cliente pode escrever **um** tratador de erros em vez de um por endpoint por serviço. Ele ganha uma URI `type` estável e legível por máquina sobre a qual pode ramificar — distinguindo "estoque insuficiente" de "SKU inválido" sem casar strings de uma mensagem humana que será reescrita ou traduzida —, um `status` que sobrevive a proxies reescrevendo a linha de resposta, e um lugar documentado (`detail`, mais membros de extensão) para as especificidades. Com `{"error": "..."}` o cliente tem apenas prosa: ramificar sobre ela é frágil, localizá-la é impossível, e cada novo serviço inventa um formato diferente, de modo que a camada de agregação, o SDK e o pipeline de logs todos precisam de casos especiais por serviço. O padrão também resolve as questões que as equipes, de outro modo, rediscutem para sempre — onde vão os erros de validação por campo, se há um identificador para correlacionar com os logs.

### Bloco 10 — Imutabilidade e descartabilidade

**1.** `podman restart` para e inicia **o mesmo contêiner** — a mesma camada gravável sobre a imagem — de modo que as mudanças no sistema de arquivos persistem. `podman rm` seguido de `podman run` cria um **novo contêiner** com uma camada gravável nova derivada apenas da imagem, de modo que a mudança se foi. Isso é mais perigoso do que a perda imediata porque cria um **sobrevivente**: o patch funciona, sobrevive a restarts, sobrevive ao reboot do host e, portanto, deixa de parecer uma medida temporária. Ele desaparece no próximo deploy, no próximo drain de nó, no próximo evento de autoscaling, ou em uma réplica mas não nas outras — de modo que o sintoma é uma regressão intermitente que não se correlaciona com nada no seu changelog, e a correção que "com certeza foi aplicada" não está em lugar algum no git. A perda imediata teria sido um feedback honesto.

**2.** (a) **Você não consegue saber o que está rodando.** `orders:latest` em dois nós pode ser duas imagens diferentes, porque cada um fez o pull em um momento diferente; `podman images` mostra a mesma tag e os digests diferem. Depurar um incidente em produção passa então a começar por uma pergunta sem resposta. (b) **O rollback não tem alvo.** Fazer rollback significa implantar o artefato anterior, e com uma tag móvel o artefato anterior não tem nome — existe só como um digest que você teria de ter registrado à parte, e que pode já ter sido coletado como lixo no registry. (c) **Os deploys tornam-se não determinísticos e não reprodutíveis.** Um pod reagendado às 03:00 com `imagePullPolicy: Always` pega silenciosamente o que quer que `latest` signifique naquele instante, de modo que uma falha de nó vira um deploy não planejado; e reexecutar o mesmo manifesto duas vezes pode produzir dois sistemas diferentes, o que destrói a propriedade que faz a infraestrutura declarativa funcionar. Uma tag com SHA (ou melhor, uma referência por digest) torna cada uma dessas perguntas respondível por inspeção.

**3.** Porque inverte a proveniência: o conteúdo da imagem resultante é explicado por uma sequência de comandos interativos que ninguém registrou, e não por um Containerfile sob controle de versão. Você não consegue fazer diff, não consegue revisar, não consegue reconstruí-la a partir do código-fonte, não consegue dizer se o binário com patch corresponde a algum commit, e não consegue reproduzi-la depois que uma CVE na imagem base forçar um rebuild — momento em que o patch manual é silenciosamente perdido ou precisa ser reconstituído por engenharia reversa a partir de um processo em execução. Também tende a assar qualquer estado de runtime presente no momento do snapshot: arquivos temporários, um cache populado, credenciais escritas por um passo de init, o próprio hostname do contêiner. O uso legítimo é **forense**: tirar um snapshot de um contêiner com comportamento anômalo para dissecá-lo offline enquanto o orquestrador o substitui — um artefato para investigação, explicitamente nunca para deploy.

**4.** O uvicorn drenou a requisição em voo, mas zero downtime exige adicionalmente que **nenhuma requisição nova seja roteada ao processo depois que ele começa a desligar**, e isso não é algo que o processo possa arranjar sozinho. O orquestrador precisa (a) remover o pod da lista de endpoints do load balancer *antes de ou junto com* o envio do `SIGTERM`, (b) permitir um período de graça `preStop` longo o bastante para que essa remoção se propague a todo proxy — a propagação de endpoints é assíncrona, e um pod que para de aceitar conexões antes que o último proxy tenha sido atualizado produz exatamente os erros de conexão recusada que você tentava evitar — e (c) definir `terminationGracePeriodSeconds` maior que a requisição legítima mais longa da aplicação, ou a drenagem é interrompida pelo `SIGKILL`. O sinal de que isso depende é o **readiness probe**: readiness, não liveness, controla a participação no conjunto de endpoints, de modo que um contêiner que falha o readiness é removido do serviço enquanto continua rodando e terminando seu trabalho em voo. Confundir os dois — usar liveness para sinalizar "estou drenando" — faz o pod ser morto em vez de drenado.

**5.** Apoia o **fator VI (processos stateless, que nada compartilham)** e, junto com a imagem marcada por SHA, o **fator V** — o contêiner em execução é byte a byte idêntico ao artefato, sem divergência gravável. Para tornar o sistema de arquivos somente leitura (`readOnlyRootFilesystem: true`), você precisa dar ao processo um `emptyDir`/`tmpfs` gravável para todo caminho de que ele genuinamente precise: `/tmp` (o Python escreve ali, assim como muitas bibliotecas), qualquer diretório de cache que o framework ou o gerenciador de dependências use, e o caminho do socket Unix se você usar um. Você também precisa garantir que nada escreva no diretório da aplicação em runtime — nenhuma geração de `.pyc` em `/srv/app` (defina `PYTHONDONTWRITEBYTECODE=1`, ou pré-compile no build), nenhum arquivo de log, nenhum arquivo de PID. Os logs vão para stdout, que é o fator XI e não lhe custa nada aqui.

**6.** É aceitável no laboratório porque o exercício trata de imutabilidade de imagem e da fronteira de configuração, e um banco SQLite em arquivo mantém as partes móveis em uma só. Destrói **a descartabilidade do processo**, e com ela tudo que depende dela: os dados vivem na camada gravável do contêiner, então somem quando o contêiner é substituído — o que, conforme o passo 5, é o que todo deploy, drain de nó e reagendamento faz. Duas réplicas teriam dois bancos de dados divergentes sem reconciliação, de modo que o serviço não pode ser escalado de jeito nenhum. A forma correta é o fator IV: o banco de dados é um **serviço de apoio anexado**, alcançável em uma URL fornecida pelo ambiente, cujo ciclo de vida é inteiramente independente de qualquer instância da aplicação, de modo que destruir uma instância não destrói nada além da instância.

</details>

---

## Fontes

- LPI, *Exam 701 Objectives (DevOps Tools Engineer)* — <https://www.lpi.org/our-certifications/exam-701-objectives/>
- Adam Wiggins et al., *The Twelve-Factor App* — <https://12factor.net/>
- IETF RFC 9110, *HTTP Semantics* (métodos, códigos de status, requisições condicionais, métodos seguros e idempotentes) — <https://www.rfc-editor.org/rfc/rfc9110.html>
- IETF RFC 9111, *HTTP Caching* (`Cache-Control`, frescor, validadores, `Vary`) — <https://www.rfc-editor.org/rfc/rfc9111.html>
- IETF RFC 9457, *Problem Details for HTTP APIs* — <https://www.rfc-editor.org/rfc/rfc9457.html>
- IETF RFC 6265bis / atributo de cookie `SameSite` — <https://datatracker.ietf.org/doc/html/draft-ietf-httpbis-rfc6265bis>
- IETF, *The Idempotency-Key HTTP Header Field* — um Internet-Draft, ainda não um padrão; o header é amplamente implantado, mas não especificado normativamente — <https://datatracker.ietf.org/doc/draft-ietf-httpapi-idempotency-key-header/>
- OpenAPI Initiative, *OpenAPI Specification 3.1.0* — <https://spec.openapis.org/oas/v3.1.0.html>
- OWASP, *Top 10 Web Application Security Risks* — <https://owasp.org/www-project-top-ten/>
- OWASP, *Cross-Site Scripting Prevention Cheat Sheet* — <https://cheatsheetseries.owasp.org/cheatsheets/Cross_Site_Scripting_Prevention_Cheat_Sheet.html>
- OWASP, *Cross-Site Request Forgery Prevention Cheat Sheet* — <https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html>
- OWASP, *SQL Injection Prevention Cheat Sheet* — <https://cheatsheetseries.owasp.org/cheatsheets/SQL_Injection_Prevention_Cheat_Sheet.html>
- SQLite, *Transaction control* (`BEGIN IMMEDIATE`, WAL) — <https://www.sqlite.org/lang_transaction.html>
- PostgreSQL, *Explicit Locking / `SELECT ... FOR UPDATE`* — <https://www.postgresql.org/docs/current/explicit-locking.html>
- Kubernetes, *Pod Lifecycle — termination and readiness* — <https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/>
- Documentação do FastAPI — <https://fastapi.tiangolo.com/>
- Documentação de deployment do Uvicorn (tratamento de sinais e desligamento gracioso) — <https://www.uvicorn.org/deployment/>