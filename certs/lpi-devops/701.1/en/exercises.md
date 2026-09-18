# 701.1 — Modern Software Development: Guided Exercises

**Exam:** LPI DevOps Tools Engineer, 701-100 (version 2.0.0) · **Topic weight:** 10

These exercises build one small system — an `orders` service and its dependencies — and then attack it from every angle the objective names: service decomposition, API design, configuration, state, storage, security and immutability. Everything runs on a single Linux host with Python 3.12 and a container runtime. Nothing here talks to a network you do not own.

Work through them in order; each one leaves artifacts the next one uses.

**Lab prerequisites**

```bash
mkdir -p ~/lab-701.1 && cd ~/lab-701.1
python3.12 -m venv .venv
.venv/bin/pip install --quiet --upgrade pip
.venv/bin/pip install --quiet \
  "fastapi==0.115.6" "uvicorn[standard]==0.34.0" "httpx==0.28.1" "pytest==8.3.4"
.venv/bin/python -c "import fastapi, sys; print(fastapi.__version__, sys.version.split()[0])"
podman --version || docker --version
```

Expected:

```
0.115.6 3.12.9
podman version 5.4.0
```

Throughout, `podman` and `docker` are interchangeable; substitute whichever you have.

---

## Exercise 1 — Find the seams before you draw the service boundaries

The objective asks you to *design* service-based applications. The most common failure is drawing boundaries on a whiteboard by business intuition and discovering at implementation time that two "independent" services share a table. The reliable technique is the opposite direction: map which code touches which data, and cut where the map is already thin.

**Step 1.** Create the monolith you are going to decompose.

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

**Step 2.** Write the coupling mapper. It parses the module with Python's own AST and extracts table names from SQL string literals per function — no LLM, no database connection, no runtime.

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

**Step 3.** Run it.

```bash
cd ~/lab-701.1/decompose && ../.venv/bin/python seams.py monolith.py
```

Expected output:

```
create_customer  -> customers
place_order      -> customers, inventory, orders, outbox
restock          -> inventory
customer_report  -> customers, orders
```

**Step 4.** Propose the split. Write down, on paper, which service owns each of the four tables, and mark every function that would then cross a process boundary.

> **Questions — block 1**
>
> 1. `restock` and `create_customer` each touch exactly one table. What does that tell you about where the first cut should go, and why is "touches one table" a better signal than "sounds like one domain"?
> 2. `customer_report` issues a `JOIN` across `customers` and `orders`. After the split that JOIN cannot be executed by the database. Name the two standard answers, and state the cost each one imposes.
> 3. `place_order` writes to `orders` and to `outbox` inside the same connection. Why is that stronger than "commit the order, then publish to the message broker"? What exactly can go wrong in the second version?
> 4. After the split, `place_order` needs the customer's e-mail address. Give one argument for fetching it synchronously from the Customers service at order time, and one argument for storing a denormalised copy in the Orders service instead.

---

## Exercise 2 — Twelve-factor configuration, and the build/release/run split

Factor III says configuration lives in the environment; factor V says build, release and run are strictly separated. Both are testable claims, not slogans.

**Step 1.** Create the application package and a configuration module that fails at import time.

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

**Step 2.** Import it with an empty environment and inspect the exit status.

```bash
cd ~/lab-701.1 && env -u DATABASE_URL -u SESSION_SECRET .venv/bin/python -c "import app.config"
echo "exit=$?"
```

Expected (traceback abbreviated):

```
Traceback (most recent call last):
  File "<string>", line 1, in <module>
  File "/home/user/lab-701.1/app/config.py", line 18, in <module>
    DATABASE_URL = _require("DATABASE_URL")
                   ^^^^^^^^^^^^^^^^^^^^^^^^
app.config.ConfigError: missing or empty required environment variable: DATABASE_URL
exit=1
```

**Step 3.** Supply the environment and confirm the same code now starts.

```bash
cd ~/lab-701.1
export DATABASE_URL="sqlite:///orders.db"
export SESSION_SECRET="dev-only-not-a-real-secret"
export RELEASE="1.0.0+dev"
.venv/bin/python -c "import app.config as c; print(c.DATABASE_URL, c.PORT, c.LOG_LEVEL, c.RELEASE)"
```

Expected:

```
sqlite:///orders.db 8080 info 1.0.0+dev
```

**Step 4.** Apply the litmus test for factor III.

```bash
cd ~/lab-701.1 && grep -rIn -E "(password|secret|token|api[_-]?key)\s*=\s*['\"]" app/ || echo "no literal credentials in app/"
```

Expected:

```
no literal credentials in app/
```

**Step 5.** Demonstrate build/release/run with one artifact and two releases. Write the compose file that describes two environments of the *same* image:

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

> **Questions — block 2**
>
> 1. `config.py` raises during *import*, not on the first request. Name two concrete operational benefits of failing that early, specifically in an orchestrated environment such as Kubernetes.
> 2. A colleague proposes `config/staging.yaml`, `config/production.yaml` in the repository, selected by `APP_ENV`. Give the precise twelve-factor objection — and say which part of the proposal is nevertheless fine.
> 3. Both compose services use `image: "localhost/orders:1.0.0"`. Which factor does that satisfy, and what would be broken if staging used `orders:1.0.0-staging` built from the same commit?
> 4. `PORT` has a default of `8080` but `SESSION_SECRET` has none. State the rule that decides which configuration values may carry a default.

---

## Exercise 3 — REST semantics: resources, status codes and idempotency

**Step 1.** Write the first version of the API.

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

**Step 2.** Start it in a second terminal (keep the environment variables from Exercise 2 exported there too).

```bash
cd ~/lab-701.1 && .venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8080
```

Expected:

```
INFO:     Started server process [24118]
INFO:     Waiting for application startup.
INFO:     Application startup complete.
INFO:     Uvicorn running on http://127.0.0.1:8080 (Press CTRL+C to quit)
```

**Step 3.** Create a resource and read the response line and headers.

```bash
curl -isS -X POST http://127.0.0.1:8080/orders \
  -H 'Content-Type: application/json' \
  -d '{"sku":"SKU-1","qty":2}'
```

Expected (dates and UUIDs will differ):

```
HTTP/1.1 201 Created
date: Fri, 18 Sep 2026 09:12:44 GMT
server: uvicorn
content-length: 83
content-type: application/json
location: /orders/0f2b7c1e-6a4d-4f83-9a55-8e1d5c0b21aa

{"id":"0f2b7c1e-6a4d-4f83-9a55-8e1d5c0b21aa","sku":"SKU-1","qty":2,"status":"placed"}
```

**Step 4.** Reproduce the duplicate-submission bug: send the identical request twice with no idempotency key.

```bash
for i in 1 2; do
  curl -sS -X POST http://127.0.0.1:8080/orders \
    -H 'Content-Type: application/json' -d '{"sku":"SKU-9","qty":1}' \
  | .venv/bin/python -c "import json,sys; print(json.load(sys.stdin)['id'])"
done
```

Expected — two different identifiers, i.e. two real orders:

```
3c9f1d80-7b21-4d0e-b0c8-2a1f5e4477c1
b5e2a744-19ad-4c6f-8f27-6de0c3b91f52
```

**Step 5.** Repeat with an idempotency key.

```bash
KEY=$(uuidgen)
for i in 1 2; do
  curl -sS -o /tmp/body -w "%{http_code} %{redirect_url}\n" -X POST http://127.0.0.1:8080/orders \
    -H 'Content-Type: application/json' -H "Idempotency-Key: $KEY" \
    -d '{"sku":"SKU-9","qty":1}'
  cat /tmp/body; echo
done
```

Expected — one order, two safe responses:

```
201 
{"id":"a71c0e55-4f9b-42d6-9b58-1cc3d77e08b1","sku":"SKU-9","qty":1,"status":"placed"}
200 
{"id":"a71c0e55-4f9b-42d6-9b58-1cc3d77e08b1","sku":"SKU-9","qty":1,"status":"placed"}
```

**Step 6.** Exercise the error paths and note which layer produced each status.

```bash
curl -sS -o /dev/null -w "invalid body : %{http_code}\n" -X POST http://127.0.0.1:8080/orders \
  -H 'Content-Type: application/json' -d '{"sku":"SKU-1","qty":0}'
curl -sS -o /dev/null -w "unknown id  : %{http_code}\n" http://127.0.0.1:8080/orders/does-not-exist
curl -sS -o /dev/null -w "wrong verb  : %{http_code}\n" -X PUT http://127.0.0.1:8080/orders
curl -sS -X POST http://127.0.0.1:8080/orders -H 'Content-Type: application/json' \
  -d '{"sku":"SKU-1","qty":0}' | .venv/bin/python -c "import json,sys; print(json.load(sys.stdin)['detail'][0]['msg'])"
```

Expected:

```
invalid body : 422
unknown id  : 404
wrong verb  : 405
Input should be greater than 0
```

> **Questions — block 3**
>
> 1. Step 3 returned `201` with a `Location` header. What must a client be able to do with `Location` that it could not do with the body alone?
> 2. In step 5 the second call returned `200`, not `201`. Justify that choice against the alternative of returning `201` both times.
> 3. `DELETE /orders/{id}` on an already-cancelled order returns `204`, but on a shipped order returns `409`. Explain why the first is *not* an error while the second is, in terms of the definition of idempotency.
> 4. The invalid body produced `422`, not `400`. Both are defensible. State the distinction being drawn, and say what a client should do differently on each.
> 5. `POST /orders` with `qty: 0` fails in the framework before your handler runs. Why is validation at the edge, expressed as a schema, a design property rather than a convenience?

---

## Exercise 4 — Conditional requests, caching and the headers that make them safe

**Step 1.** Fetch an order and capture its `ETag`.

```bash
ID=$(curl -sS -X POST http://127.0.0.1:8080/orders -H 'Content-Type: application/json' \
  -d '{"sku":"SKU-CACHE","qty":3}' \
  | .venv/bin/python -c "import json,sys; print(json.load(sys.stdin)['id'])")
curl -isS "http://127.0.0.1:8080/orders/$ID" | grep -Ei '^(HTTP|etag|cache-control)'
```

Expected:

```
HTTP/1.1 200 OK
etag: "4c0d1f7a9b3e5821"
cache-control: private, max-age=30
```

**Step 2.** Re-request with the validator.

```bash
ETAG=$(curl -sS -D - -o /dev/null "http://127.0.0.1:8080/orders/$ID" | awk -F': ' 'tolower($1)=="etag"{print $2}' | tr -d '\r')
curl -isS -H "If-None-Match: $ETAG" "http://127.0.0.1:8080/orders/$ID" | head -n 1
curl -sS -o /dev/null -w "bytes transferred: %{size_download}\n" \
  -H "If-None-Match: $ETAG" "http://127.0.0.1:8080/orders/$ID"
```

Expected:

```
HTTP/1.1 304 Not Modified
bytes transferred: 0
```

**Step 3.** Change the resource and prove the validator invalidates.

```bash
curl -sS -o /dev/null -X DELETE "http://127.0.0.1:8080/orders/$ID"
curl -isS -H "If-None-Match: $ETAG" "http://127.0.0.1:8080/orders/$ID" | grep -Ei '^(HTTP|etag)'
```

Expected:

```
HTTP/1.1 200 OK
etag: "8f3b2c60d14ae997"
```

**Step 4.** Inspect what would happen behind a shared cache. The response carries `private`; change it temporarily to `public, max-age=30` in `app/main.py`, restart, and repeat step 1 with two different `Authorization` headers.

> **Questions — block 4**
>
> 1. `304` returned zero bytes of body, but the request still crossed the network. Name the resource it saves and the resource it does *not* save, and give a case where that trade-off is not worth it.
> 2. `Cache-Control: private` on a per-customer order. Describe precisely the incident that `public` would cause on a shared CDN, and name the header that would be required if the response legitimately varied by `Authorization`.
> 3. The `ETag` here is a hash of the serialised body — a *strong* validator. What breaks if you instead derive the `ETag` from `updated_at` truncated to whole seconds?
> 4. `ETag` also enables `If-Match` on writes. Sketch the request/response exchange that stops two clients from silently overwriting each other's edit, and give the status code the loser receives.

---

## Exercise 5 — Stateless processes: reproduce the sticky-session failure and remove it

**Step 1.** Build a deliberately stateful service.

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

**Step 2.** Run two instances, as a scaled deployment would.

```bash
cd ~/lab-701.1
INSTANCE=a .venv/bin/uvicorn cart.stateful:app --port 9001 &
INSTANCE=b .venv/bin/uvicorn cart.stateful:app --port 9002 &
sleep 2
```

**Step 3.** Add an item on instance `a`, then read the cart from instance `b` — exactly what a round-robin load balancer does.

```bash
cd /tmp && rm -f jar.txt
curl -sS -c jar.txt -X POST "http://127.0.0.1:9001/cart/items?sku=SKU-1"; echo
curl -sS -b jar.txt "http://127.0.0.1:9001/cart"; echo
curl -sS -b jar.txt "http://127.0.0.1:9002/cart"; echo
```

Expected:

```
{"instance":"a","cart_id":"1f5d9a02-0f4c-4f31-8a8e-b41c0f0a5c33","items":["SKU-1"]}
{"instance":"a","items":["SKU-1"]}
{"instance":"b","items":[]}
```

**Step 4.** Make the process stateless by moving the state out. Here the state is carried by the client in a signed, tamper-evident token; the server keeps nothing.

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

**Step 5.** Repeat the cross-instance test.

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

Expected:

```
{"instance":"b","items":["SKU-1"]}
{"instance":"b","items":["SKU-1","SKU-2"]}
{"instance":"a","items":["SKU-1","SKU-2"]}
```

**Step 6.** Confirm the signature is load-bearing.

```bash
cd /tmp
BAD=$(sed -n 's/.*cart\s*\(.*\)/\1/p' jar.txt | tr -d '\r')
curl -sS -o /dev/null -w "%{http_code}\n" -H "Cookie: cart=${BAD%.*}.AAAAAAAA" "http://127.0.0.1:9001/cart"
kill %1 %2 2>/dev/null
```

Expected:

```
400
```

> **Questions — block 5**
>
> 1. Step 3 produced an empty cart on instance `b`. Name the twelve-factor factor this violates and describe what "enable sticky sessions on the load balancer" actually costs you during a rolling deploy.
> 2. The sealed cookie is signed but *not* encrypted. State what an attacker with the cookie can and cannot do, and give one category of data that therefore must never go in it.
> 3. Compare the signed-cookie approach against a shared Redis session store on exactly one axis: revoking a session immediately. Which one wins, and what does the loser have to add to compensate?
> 4. Your colleague says "we have no state; we write uploaded files to `/var/lib/app/uploads`". Why is that still stateful, and what is the twelve-factor prescription?

---

## Exercise 6 — Loose coupling: timeouts, retry amplification and a circuit breaker

**Step 1.** Create a dependency whose latency you control.

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

**Step 2.** Call it the way most first-draft code does — with the timeout explicitly disabled, which is what `requests` gives you by default.

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

Expected — the process never returns on its own; `timeout` kills it:

```
exit=124
```

**Step 3.** Bound it, and measure the difference.

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

Expected:

```
read timeout after 2.01s -> serve degraded response
```

**Step 4.** Add a circuit breaker so that a dependency which is down stops consuming your capacity at all.

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

Expected:

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

**Step 5.** Clean up.

```bash
kill %1 2>/dev/null
```

> **Questions — block 6**
>
> 1. Step 2 hung indefinitely. In a synchronous server with a fixed worker pool, describe the sequence that turns "one slow dependency" into "the whole service returns 503".
> 2. Three services are chained A → B → C, and each retries 3 times on failure. When C fails, how many requests does C receive per original client request? Generalise the formula, and name the two mitigations.
> 3. The breaker short-circuits in 0.00 s while open. Which two parties benefit from that, and how does it differ from simply lowering the timeout to 0.1 s?
> 4. The breaker's `half-open` state lets exactly one probe through. What goes wrong if, instead, it reopened the gate to full traffic after the cooldown?
> 5. This whole exercise is about synchronous coupling. Describe the same `orders → pricing` interaction over a message broker, and state what property you gain and what property you lose.

---

## Exercise 7 — Data storage: pick the model by the invariant it must hold

**Step 1.** Build the inventory table with the constraint written down.

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

Expected:

```
[('SKU-1', 5)]
```

**Step 2.** Write a concurrency harness with two implementations of "sell one unit": a read-modify-write in application code, and a compare-and-set inside the database.

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

**Step 3.** Run the naive version. Reset the stock first.

```bash
cd ~/lab-701.1
.venv/bin/python -c "import sqlite3; c=sqlite3.connect('stock.db'); c.execute(\"UPDATE inventory SET on_hand=5 WHERE sku='SKU-1'\"); c.commit()"
.venv/bin/python oversell.py stock.db read-modify-write
```

Expected (exact numbers vary between runs; the shape does not):

```
mode=read-modify-write  buyers=20 sold=20 on_hand=4
```

**Step 4.** Run the compare-and-set version.

```bash
cd ~/lab-701.1
.venv/bin/python -c "import sqlite3; c=sqlite3.connect('stock.db'); c.execute(\"UPDATE inventory SET on_hand=5 WHERE sku='SKU-1'\"); c.commit()"
.venv/bin/python oversell.py stock.db cas
```

Expected — every run, without exception:

```
mode=cas                  buyers=20 sold=5 on_hand=0
```

**Step 5.** Decide where each artifact belongs. For the order confirmation PDF (≈ 300 kB, written once, read rarely, served to the customer for seven years), compare storing it as a `BLOB` column against storing a key in object storage:

```
relational BLOB            object storage (S3-compatible)
--------------------------  ------------------------------
in the backup/restore path  out of it
costs DB IOPS on read       served directly, presigned URL
transactional with the row  eventually consistent with the row
row locking on large writes no lock contention
```

> **Questions — block 7**
>
> 1. The `CHECK (on_hand >= 0)` constraint was in place during step 3 and the database still ended up inconsistent with reality. Explain exactly why the constraint did not fire, and what that says about the difference between validating a *value* and serialising an *operation*.
> 2. The `cas` version sold exactly 5 of 5, every time. Which single property of the statement makes it safe, and name the equivalent pattern in PostgreSQL when the update is too complex for one statement.
> 3. You move inventory to a document store with no multi-document transactions. Name two mechanisms that can restore the "never oversell" guarantee, and state the cost of each.
> 4. Using the table in step 5, argue the one case where the `BLOB` column *is* the right answer.
> 5. A caching layer is proposed in front of the inventory read. Which reads may be cached, which must not be, and why is "cache the stock level for 5 seconds" more dangerous than it sounds?

---

## Exercise 8 — Application security: SQL injection, XSS and CSRF on your own lab service

Everything below runs against `127.0.0.1` on code you just wrote. The point is to see the mechanism, then see the fix work.

**Step 1.** Build the vulnerable service.

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

**Step 2.** Confirm the normal path, then inject.

```bash
curl -sS --get --data-urlencode "name=alice" http://127.0.0.1:9200/users/vulnerable; echo
curl -sS --get --data-urlencode "name=' OR '1'='1" http://127.0.0.1:9200/users/vulnerable; echo
```

Expected:

```
{"sql":"SELECT id, name, role FROM users WHERE name = 'alice'","rows":[[1,"alice","admin"]]}
{"sql":"SELECT id, name, role FROM users WHERE name = '' OR '1'='1'","rows":[[1,"alice","admin"],[2,"bob","user"],[3,"carol","user"]]}
```

**Step 3.** Send the identical payload to the parameterised endpoint.

```bash
curl -sS --get --data-urlencode "name=' OR '1'='1" http://127.0.0.1:9200/users/safe; echo
```

Expected — the payload is data, so it matches nothing:

```
{"rows":[]}
```

**Step 4.** Reflected XSS: look at the raw bytes the server emits.

```bash
curl -sS --get --data-urlencode "q=<script>alert(1)</script>" http://127.0.0.1:9200/search/vulnerable; echo
curl -isS --get --data-urlencode "q=<script>alert(1)</script>" http://127.0.0.1:9200/search/safe \
  | grep -Ei '^(content-security-policy)|<html'
```

Expected:

```
<html><body><p>No results for <script>alert(1)</script></p></body></html>
content-security-policy: default-src 'self'
<html><body><p>No results for &lt;script&gt;alert(1)&lt;/script&gt;</p></body></html>
```

**Step 5.** CSRF: forge the request a malicious page would make. The browser would attach the session cookie automatically; `curl` does it explicitly.

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

Expected:

```
{"changed_email_to":"attacker@evil.example","authenticated_by":"cookie only"}
403
{"changed_email_to":"owner@shop.example"}
```

> **Questions — block 8**
>
> 1. `/users/safe` uses `?` placeholders. Explain what the database driver does that string escaping does not — and why "I escape quotes with a helper function" is a weaker claim than "I use bind parameters".
> 2. Your ORM offers `.raw("SELECT ... WHERE name = %s")`. Is that safe? Under what one condition does it become unsafe again?
> 3. Step 4's "safe" endpoint escapes output rather than sanitising input. Give the architectural reason output encoding is the correct place, and name one context where HTML escaping is the *wrong* encoder.
> 4. The CSRF fix checks `Origin` **and** a token. Why is neither alone sufficient in practice, and where does `SameSite=Lax` fit as a third layer?
> 5. `SameSite=Lax` still permits cross-site top-level `GET` navigation. What design rule does that impose on your API, and which HTTP definition does it come from?
> 6. The vulnerable endpoint echoes the generated SQL back to the caller. Independently of injection, name the OWASP category that alone belongs to and what an attacker learns from it.

---

## Exercise 9 — The API contract: OpenAPI as the coupling boundary

**Step 1.** Export the machine-readable contract from the running application and freeze it.

```bash
cd ~/lab-701.1
.venv/bin/python -c "import json; from app.main import app; print(json.dumps(app.openapi(), indent=2, sort_keys=True))" > openapi.json
.venv/bin/python -c "import json; d=json.load(open('openapi.json')); print(d['openapi'], sorted(d['paths']))"
cp openapi.json openapi.frozen.json
```

Expected:

```
3.1.0 ['/orders', '/orders/{order_id}']
```

**Step 2.** Read what a hand-written contract for the same endpoint looks like, including the pieces the generator cannot infer — the conditional-request behaviour and the error media type.

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

**Step 3.** Write the breaking-change detector that belongs in CI.

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

Expected:

```
0 breaking change(s)
exit=0
```

**Step 4.** Introduce a breaking change and watch CI catch it. Edit `app/main.py` so `OrderIn` requires a new field:

```bash
cd ~/lab-701.1
sed -i 's/    qty: int = Field(gt=0, le=100)/    qty: int = Field(gt=0, le=100)\n    warehouse: str = Field(min_length=1)/' app/main.py
.venv/bin/python -c "import json; from app.main import app; print(json.dumps(app.openapi(), indent=2, sort_keys=True))" > openapi.json
.venv/bin/python check_contract.py openapi.frozen.json openapi.json; echo "exit=$?"
```

Expected:

```
BREAKING: newly required field: OrderIn.warehouse
1 breaking change(s)
exit=1
```

**Step 5.** Revert, and make the field additive instead.

```bash
cd ~/lab-701.1
sed -i 's/    warehouse: str = Field(min_length=1)/    warehouse: str = Field(default="default", min_length=1)/' app/main.py
.venv/bin/python -c "import json; from app.main import app; print(json.dumps(app.openapi(), indent=2, sort_keys=True))" > openapi.json
.venv/bin/python check_contract.py openapi.frozen.json openapi.json; echo "exit=$?"
```

Expected:

```
0 breaking change(s)
exit=0
```

**Step 6.** Write a consumer contract test — the check that the *client's* expectations still hold.

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

Expected:

```
...                                                                      [100%]
3 passed in 0.41s
```

> **Questions — block 9**
>
> 1. Step 4 flagged `newly required field` while step 5 did not. Formulate the general rule about what a provider may add to a request and to a response without breaking consumers. Which direction is the asymmetry?
> 2. The generator produced the contract from the code. Name the concrete risk of that direction versus writing the contract first, and one situation where generating it is nevertheless correct.
> 3. `test_contract.py` asserts `{"id","sku","qty","status"} <= set(body)` rather than equality. Why is the subset check the right assertion for a consumer test?
> 4. A breaking change is genuinely necessary. Describe the sequence of steps that ships it without a coordinated flag-day deploy, and name the mechanism that tells you when the old version can be removed.
> 5. The `404` in step 2 declares `application/problem+json`. What does standardising the error body buy a client that inventing `{"error": "..."}` does not?

---

## Exercise 10 — Immutable servers and disposable processes

**Step 1.** Write the image definition.

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

**Step 2.** Build it, tagged with the commit that produced it.

```bash
cd ~/lab-701.1
git init -q 2>/dev/null; git add -A 2>/dev/null; git -c user.email=lab@example -c user.name=lab commit -qm "lab" 2>/dev/null
SHA=$(git rev-parse --short HEAD)
podman build -q -t "localhost/orders:$SHA" .
podman images --format '{{.Repository}}:{{.Tag}} {{.Size}}' | head -n 1
```

Expected:

```
localhost/orders:3fa91c2 158 MB
```

**Step 3.** Run it and confirm the release comes from the environment, not the image.

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

Expected:

```
{"status":"ok","release":"1.0.0+3fa91c2"}
```

**Step 4.** Mutate the running container the way a "quick hotfix on the box" does, then restart it.

```bash
podman exec -u 0 orders-1 sh -c 'echo "PATCHED BY HAND" > /srv/app/hotfix.txt && cat /srv/app/hotfix.txt'
podman restart orders-1 >/dev/null && sleep 2
podman exec orders-1 sh -c 'cat /srv/app/hotfix.txt 2>&1 || true'
```

Expected — the write survives a restart of the same container, which is precisely the trap:

```
PATCHED BY HAND
PATCHED BY HAND
```

**Step 5.** Now do what the orchestrator does — replace the container from the image.

```bash
SHA=$(git rev-parse --short HEAD)
podman rm -f orders-1 >/dev/null
podman run -d --name orders-1 -p 8090:8080 \
  -e DATABASE_URL="sqlite:///orders.db" -e SESSION_SECRET="lab-secret" -e RELEASE="1.0.0+$SHA" \
  "localhost/orders:$SHA" >/dev/null
sleep 2
podman exec orders-1 sh -c 'cat /srv/app/hotfix.txt 2>&1 || true'
```

Expected:

```
cat: /srv/app/hotfix.txt: No such file or directory
```

**Step 6.** Verify graceful shutdown. Add a slow endpoint, run it outside the container so you can watch the logs, start a request, and send `SIGTERM` mid-flight.

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

Expected — the in-flight request is drained, not severed:

```
INFO:     Shutting down
INFO:     Waiting for connections to close. (CTRL+C to force quit)
{"status":"finished despite shutdown"}
INFO:     Waiting for application shutdown.
INFO:     Application shutdown complete.
INFO:     Finished server process [24701]
```

**Step 7.** Clean up.

```bash
podman rm -f orders-1 >/dev/null 2>&1; echo cleaned
```

> **Questions — block 10**
>
> 1. Step 4's hand-patch survived `podman restart` and step 5's did not. Explain the difference in terms of container lifecycle, and say why the first behaviour is more dangerous than if the patch had vanished immediately.
> 2. The image is tagged with the commit SHA rather than `latest`. Name three separate operational problems that a moving `latest` tag causes.
> 3. `podman commit` can snapshot a running, patched container into a new image. Why is that an anti-pattern under immutable-infrastructure principles, and what is the one legitimate use?
> 4. In step 6, uvicorn kept serving until the in-flight request finished. Describe what an orchestrator must do *in addition* for a rolling update to be genuinely zero-downtime, and which readiness signal it depends on.
> 5. The image runs as UID 10001 and the application writes nothing to the filesystem. Which twelve-factor factor does that support, and what would you have to change to make the filesystem read-only?
6. `DATABASE_URL` points at SQLite inside the container. State why that is acceptable for this lab and exactly which property it destroys in production.

---

## Answers

<details>
<summary>Click to reveal the answers to all ten blocks</summary>

### Block 1 — Finding the seams

**1.** A function that touches exactly one table has no cross-boundary transaction to break. `restock` becomes an Inventory service endpoint and `create_customer` a Customers service endpoint with nothing else to negotiate — the split is mechanical. "Sounds like one domain" is a hypothesis about language; "touches one table" is an observation about the transactional coupling that will actually bite you. Domain language and data ownership usually agree, but when they disagree, the data wins, because the database is where the atomicity you are about to lose lives. Start with the seams the code already has, not the ones you wish it had.

**2.** The two answers are (a) **API composition**: the reporting caller fetches the customer from Customers and the orders from Orders and joins in application code; cost is N+1 call patterns, added latency, partial-failure handling, and no ability to filter or sort efficiently across the two data sets. (b) **Data replication / CQRS read model**: Orders subscribes to customer events and maintains a local copy of the fields it needs, so the join is again local; cost is eventual consistency, a replication pipeline to operate, and the duplicated data going stale or diverging. There is no third answer that keeps both strong consistency and full independence — that is the trade the split buys.

**3.** Writing to `outbox` in the same transaction is the **transactional outbox** pattern, and it makes "the order exists" and "the event will be published" a single atomic fact. In the "commit then publish" version there is a window between the commit and the broker acknowledgement: if the process dies, restarts, or the broker is unreachable, the order exists and no event was ever emitted. Nothing downstream — fulfilment, billing, the confirmation e-mail — ever happens, and no error is visible anywhere, because the order itself succeeded. A separate relay process then reads `outbox` and publishes with at-least-once delivery, which is why consumers must be idempotent (see Exercise 3).

**4.** *Synchronous fetch:* the e-mail address is always current — a customer who changed their address ten seconds ago gets the confirmation at the right place; there is exactly one copy and therefore no divergence, and Customers remains the sole authority over customer data. *Local copy:* Orders can place an order while Customers is down, which matters enormously because "cannot take orders because the customer directory is degraded" is a revenue-affecting cascade; latency is also one fewer network hop on the critical path. The usual production answer is the copy, plus event-driven refresh — and you accept that a confirmation may occasionally go to a recently-superseded address.

### Block 2 — Configuration and build/release/run

**1.** (a) The container **crash-loops immediately** rather than starting, passing its liveness probe and then failing every request; the orchestrator's `CrashLoopBackOff` and the non-zero exit status become the alert, with the missing variable's name in the log. (b) A rolling update with a bad or incomplete ConfigMap/Secret **never completes**, so the deployment stalls with the old, working pods still serving. If the failure happened on the first request instead, the new pods would go Ready, the old ones would be torn down, and you would have replaced a working release with a broken one before anything told you.

**2.** The objection is not to YAML — it is that the *contents of production configuration are in the repository*. Factor III's test is whether the codebase could be made open source at this instant without leaking a credential; `production.yaml` with a database password fails that test. It also couples config changes to code deploys (changing a timeout needs a commit, build and release), and the number of `APP_ENV` values grows with every environment, so the "environments" become a closed enumeration inside the code. What is fine: a **defaults** file with non-secret, environment-independent values checked in, overridden by environment variables. The rule is per-deploy values in the environment, invariant values in the build.

**3.** It satisfies **factor V, strict separation of build, release and run**: one immutable build artifact, combined with different config to make different releases. If staging used `orders:1.0.0-staging`, the bytes you tested in staging would not be the bytes running in production — a different build, with a different layer cache, possibly a different base-image digest and different transitive dependency resolution. Every staging result would then be evidence about an artifact you are not shipping, which is exactly the class of "works in staging" bug that is hardest to diagnose.

**4.** A value may carry a default when a **wrong-but-plausible value is harmless and detectable**; it may not when a wrong value is either insecure or silently incorrect. `PORT=8080` is harmless: if it is wrong, nothing connects and you find out in seconds. `SESSION_SECRET` with a default is catastrophic: the application starts, works perfectly, and every session cookie in production is forgeable by anyone who read the source. The same reasoning bans defaults for `DATABASE_URL` — a default pointing at a local SQLite file would let production start and quietly accumulate data in a file that vanishes on the next pod restart.

### Block 3 — REST semantics

**1.** `Location` gives the client the **canonical, server-assigned URI** of the new resource, which the body's `id` alone does not: the client would otherwise have to know the URI template (`/orders/{id}`) and construct it, hard-coding your routing into every consumer. With `Location` the server may move resources under `/v2/orders/`, shard them onto another host, or issue opaque identifiers, and the client keeps working by following the URI it was given.

**2.** The `201` in the first response is a factual claim: *a resource was created by this request*. The second request created nothing; returning `201` again would be a lie the client can act on — a client that logs "order created" per `201` would double-count, and an intermediary counting creations would too. `200` with the same body and the same `Location` says truthfully "here is the resource your key refers to; it already existed". The alternative view — always `201`, on the grounds that the client's intent was satisfied either way — is defensible and some APIs do it; the decisive argument against is that the status code describes what *happened*, not what the client wanted.

**3.** Idempotency means *the effect of N identical requests equals the effect of one*. `DELETE` on an already-cancelled order has exactly that property: the post-condition the client asked for ("this order is cancelled") is true, so returning success is correct, not a lie — and a client retrying after a lost response gets a clean answer instead of a spurious error. The shipped order is different in kind: the requested post-condition **cannot be reached at all**, regardless of how many times you ask. `409 Conflict` reports a conflict with the current state of the resource, and unlike a timeout it must not be retried — the client needs a different action (a return, a recall), not another attempt.

**4.** `400 Bad Request` says the request is malformed at the protocol or syntax level — truncated JSON, a bad `Content-Type`, an unparseable body. `422 Unprocessable Content` says the syntax was fine and the server understood it, but the *semantics* are wrong — `qty: 0` is valid JSON and the right type, it just is not a permitted value. The client difference is concrete: on `400` the client has a serialisation or transport bug and retrying the same bytes is pointless; on `422` the client's data is wrong and it can usually map the error's `loc` field straight onto a form field and show the user what to fix.

**5.** Because the schema *is* the contract, and validation at the edge is what makes the contract enforceable rather than aspirational. Three consequences follow. First, every handler below the edge can assume its inputs are well-formed, so there is no defensive re-checking scattered through the codebase and no path by which an unvalidated value reaches the database. Second, the validation rules are introspectable — they generate the OpenAPI document of Exercise 9, so the published contract cannot drift from the enforced one. Third, rejecting bad input before any business logic or database work runs is the cheapest possible failure, which matters when the bad input is hostile volume rather than an honest mistake.

### Block 4 — Caching and conditional requests

**1.** It saves **bandwidth and server serialisation work** — zero body bytes, and the origin can often answer from a cheap validator check instead of rendering the full representation. It does **not** save the round-trip: the request still travels to the origin and the client still waits one full RTT. That trade is bad when latency dominates — a mobile client on a 300 ms link fetching fifty small resources pays fifty round-trips to learn nothing changed. There, a freshness lifetime (`max-age`) is what you want, because a fresh cached response is served with no network at all; validators are for when correctness requires asking.

**2.** With `public`, a shared CDN caches Alice's order representation under the URL `/orders/{id}` and serves those exact bytes to the next requester of that URL — a cross-customer data leak, and the worst kind, because it is intermittent, invisible in your own logs, and depends on cache topology you do not control. `private` tells shared caches they may not store it while still permitting the browser's own cache. If a response genuinely varies by credential and you still want shared caching, you must send `Vary: Authorization` so the cache keys on the credential too — but `private` plus authorization is the safe default for per-customer data, and `Vary: Authorization` is an easy header for an intermediary to mishandle.

**3.** A second-granularity `updated_at` cannot distinguish two changes that happen within the same second. The failure is a lost update from the client's point of view: a client fetches at `t`, the resource is modified twice at `t+0.2` and `t+0.7`, and the validator is identical for both — so the client's `If-None-Match` matches, it gets `304`, and it keeps a representation that is two revisions stale with no way to know. That is precisely why HTTP distinguishes strong from weak validators: only a strong validator may be used for byte-range requests and for `If-Match` on writes. A hash of the body is strong by construction.

**4.** This is **optimistic concurrency control**. Client A `GET`s the order and receives `ETag: "abc"`. Client B does the same. A sends `PUT /orders/{id}` with `If-Match: "abc"`; the server compares, matches, applies the write, and the resource's ETag becomes `"def"`. B now sends its `PUT` with `If-Match: "abc"`; the server compares, does not match, and rejects with **`412 Precondition Failed`**. B must re-fetch, see A's change, and decide — merge, retry, or surface the conflict to the user. Without `If-Match`, B's write simply overwrites A's and nobody learns anything. Note the distinction from `409`: `412` says "your precondition was false"; `409` says "the state of the resource forbids this regardless of preconditions".

### Block 5 — Statelessness

**1.** It violates **factor VI, processes are stateless and share nothing** — the cart lived in one process's heap, so it existed for exactly one of the two replicas. Sticky sessions appear to fix it and cost you the thing you scaled for: during a rolling deploy every terminating pod takes its sessions with it, so a fraction of users lose their carts on *every single deploy*; the load balancer can no longer balance, so one hot instance cannot be relieved; autoscaling in only helps the instances with no sessions; and you can no longer drain a node for maintenance without user-visible loss. You have traded a routing problem for a deployment problem, which is the worse one because it recurs on every release.

**2.** The attacker **can read the entire contents** — it is base64, not encryption — and can decode it offline at leisure. The attacker **cannot modify it undetected**, because any change to the body invalidates the HMAC and `unseal` raises. Therefore the cookie must never contain anything confidential: no e-mail addresses, no internal user identifiers you treat as secret, no entitlement data you would not print on a postcard, and above all no credentials or tokens for other systems. Cart SKUs are fine. If you need confidentiality as well as integrity, you need authenticated encryption, not a signature.

**3.** **Redis wins decisively on revocation.** A server-side session store makes revocation a single `DEL` — the session is gone on the next request, everywhere, immediately. That matters for logout-everywhere, for a password change, for an account you have just discovered is compromised. The signed cookie is self-contained precisely so the server need not be consulted, which is the same reason the server cannot un-issue it. The compensations are all partial: short expiry times plus refresh (shrinks but does not close the window, and adds a refresh endpoint that is itself a server-side lookup), a `jti` claim checked against a deny-list (which reintroduces the shared store you were avoiding, though only for the revoked minority), or a per-user `token_version` bumped on revocation (one cheap lookup, coarser granularity). Pick the trade deliberately; do not pretend the window does not exist.

**4.** A local upload directory is state that (a) is not replicated to the other instances, so an upload written by replica A returns 404 when the next request lands on replica B; (b) does not survive the container's replacement, so every deploy loses files; and (c) makes the instances non-interchangeable, which is the definition of the problem. The twelve-factor answer is **factor IV, treat backing services as attached resources**: object storage (S3-compatible) or a mounted network filesystem, addressed by a URL in the environment, so any instance reaches the same bytes and destroying an instance destroys nothing. The local filesystem may be used only as a scratch space within a single request.

### Block 6 — Loose coupling

**1.** Each request to the slow dependency occupies one worker for the duration. With no timeout, that duration is unbounded. New requests arrive at the normal rate, each one taking a worker and never giving it back, so the pool drains at the arrival rate; once every worker is parked on a socket read, requests queue in the accept backlog, latency climbs to the queueing limit, and then the listen queue overflows or the health-check endpoint itself cannot be served — at which point the load balancer marks the instance unhealthy and shifts its traffic to the other instances, which are already failing the same way. The whole service is down because of a dependency that was merely slow, and — the cruel part — the dependency may have been slow only on one endpoint that mattered to 2% of traffic.

**2.** C receives **9** requests per original client request: A makes 3 attempts to B, and each of B's attempts makes 3 to C. The general formula for n chained layers each with r attempts is **rⁿ⁻¹** requests at the deepest layer per original request (with attempts counted as total tries, so "2 retries" means r = 3). This is retry amplification, and it is why a struggling service gets *harder* hit the moment it starts failing — the load multiplies exactly when capacity drops. The two mitigations: **retry at one layer only** (usually the outermost, closest to the client, with the inner layers failing fast and propagating), and **exponential backoff with full jitter** so that retries spread out in time instead of arriving as a synchronised thundering herd. A retry budget — cap retries at a percentage of total requests — is the production-grade third.

**3.** Two parties benefit. **The caller** stops burning a worker, a connection and 1 s of latency per request on an outcome it can already predict, so it stays healthy and serves the degraded response fast. **The dependency** gets a chance to recover: a service collapsing under load cannot drain its queues if the callers keep the pressure on, and the open circuit removes that pressure entirely. Lowering the timeout to 0.1 s helps only the first party and hurts the second — you still send every request, you still consume the dependency's accept queue and thread pool, and you now also fail requests that the dependency could have served in 0.15 s. The breaker distinguishes "this call is slow" from "this dependency is down", which a timeout cannot.

**4.** You get a recovery stampede. During the cooldown, upstream requests have been queueing, retrying and accumulating; releasing all of them at once hits a dependency that has just come back with cold caches, empty connection pools and unwarmed JITs — so it fails again immediately, the circuit reopens, and you oscillate. The `half-open` single-probe design makes the cost of being wrong exactly one request: if it fails, back to open with no damage done; if it succeeds, close and resume. Production implementations usually ramp rather than jumping straight to full traffic.

**5.** Orders publishes an `order.placed` message and returns to the customer immediately; Pricing consumes it at its own rate and publishes `order.priced`, which Orders consumes to update the record. **Gained:** temporal decoupling — Pricing can be down for an hour, restarted, or scaled to zero, and orders keep being accepted, with the broker absorbing the backlog; the two services no longer share a fate, and you may add a second consumer of `order.placed` without touching Orders. **Lost:** the synchronous answer. The customer cannot be shown the price in the response, so the UI must handle a pending state; the system becomes eventually consistent, so "the order exists but has no price yet" is now a real state you must model, display and monitor; delivery is at-least-once, so every consumer must be idempotent; and debugging becomes harder because the causal chain is no longer one stack trace. You have also added the broker as a new operational dependency.

### Block 7 — Data storage

**1.** The constraint checks the *value being written*, and every value written in step 3 was legal. Twenty threads each read `on_hand = 5`, each concluded `5 >= 1`, and each wrote `4` — a perfectly valid, constraint-satisfying number. Nineteen of those writes are **lost updates**: they overwrote each other, and the database has no way to know that the `4` was computed from a `5` that was already stale by the time it was written. This is the central lesson: constraints validate states, they do not serialise operations. The read and the write were two separate transactions with an unprotected gap between them, and correctness here depended on that gap not existing. The decrement must be expressed as a single atomic operation, or the read must take a lock that the write still holds.

**2.** The statement is safe because the **read and the write happen atomically inside one statement**: `on_hand = on_hand - 1 WHERE ... AND on_hand >= 1` evaluates the predicate and applies the decrement under the row lock the `UPDATE` itself takes, so no other transaction can observe or modify the row in between. `rowcount` then tells you truthfully whether you got a unit. The PostgreSQL equivalent when the logic is too complex for one statement is **`SELECT ... FOR UPDATE`**: take the row lock at read time and hold it through the write within one transaction, so concurrent sellers block instead of racing. (`SELECT ... FOR UPDATE SKIP LOCKED` is the related idiom for queue-like workloads where you want the next *available* row rather than to wait.)

**3.** (a) **A conditional / atomic update in the document store itself** — MongoDB's `findAndModify` with a predicate on the stock field, or DynamoDB's conditional write, or a document-level compare-and-set on a version field. Cost: it works per document only, so the invariant must be expressible within one document; the moment your rule spans two documents, you are back where you started. (b) **Move the invariant out of the store** — a single-writer partition per SKU (an actor, a partitioned consumer, a distributed lock), so no two operations for a SKU are ever concurrent. Cost: an availability and complexity burden — the lock service becomes a dependency that can fail, and the partition becomes a throughput ceiling and a hot spot. A third, genuinely common answer is to **accept oversell and compensate** — reserve optimistically, detect the breach asynchronously, and cancel or backorder. That is the right choice more often than engineers like to admit, because the business cost of a rare oversell is often far lower than the availability cost of strict serialisation. The point is that it must be a decision, not an accident.

**4.** When the document's existence must be **transactionally identical** to the row's, and the volume is small. A signed tax-relevant record where "the invoice row exists but the PDF does not" is a compliance failure, not a retry, is the canonical case: the `BLOB` gets you commit-or-rollback for both in a single transaction, whereas row-plus-object-key gives you a window where one exists without the other and requires an outbox or a reconciliation job to close. At low volume the IOPS and backup arguments simply do not bite. The threshold is roughly when total blob volume starts to dominate backup time or restore RTO — at which point you move to object storage and pay for the reconciliation.

**5.** **May be cached:** the product description, name, images, category — data that changes rarely and whose staleness costs nothing. **Must not be cached for the decision:** the stock level used to decide whether a sale may proceed; that read must come from the authoritative store inside the same atomic operation as the write, which is exactly what the `cas` statement does. "Cache the stock level for 5 seconds" sounds prudent and is dangerous because it reintroduces the read-modify-write gap of step 3 with a *guaranteed* 5-second width instead of a racy 10-millisecond one — you have institutionalised the bug. The workable version is to cache a *display* stock level ("in stock" / "low stock") for the catalogue page, clearly separated from the authoritative decrement path, and to accept that the page may say "in stock" for an item that sells out a second later. Every real e-commerce system does exactly this, which is why checkout, not the product page, is where you find out.

### Block 8 — Application security

**1.** With bind parameters the SQL statement is sent to the database **separately from the values**, and the statement is parsed and planned before any value is attached. There is no parsing step left in which a value could become syntax — `' OR '1'='1` arrives as a 12-character string to compare against `name`, and matches no row. Escaping tries to achieve the same result by *transforming the value so that the parser will not misread it*, which means the escaping function must model the parser exactly: every quoting mode, every character set (the classic break is a multi-byte encoding in which a crafted sequence consumes the escaping backslash), every SQL dialect, every version. One mismatch and the guarantee is gone. "I use bind parameters" is a structural claim about where the boundary lies; "I escape quotes" is a claim that your string function and the database's parser agree on everything, forever.

**2.** Yes, `%s` in that form is a bind parameter placeholder passed to the driver, not Python string formatting — the driver parameterises it. It becomes unsafe the moment anyone writes `.raw(f"SELECT ... WHERE name = '{name}'")` or `.raw("SELECT ... WHERE name = %s" % name)`, which look almost identical in a diff and are exactly the bug. It is also unsafe for the parts of a statement that **cannot** be parameterised — table names, column names, `ORDER BY` targets, `ASC`/`DESC`. Those must be validated against an allow-list of known-good identifiers; there is no placeholder that will save you there, and a dynamic `ORDER BY {user_column}` is a live injection point in otherwise well-written code.

**3.** Because the correct encoding **depends on the context the data lands in**, and that context is known at output time, not at input time. The same string is safe in an HTML text node, dangerous unquoted in an HTML attribute, needs JavaScript string escaping inside a `<script>`, needs URL encoding in a query parameter, and needs CSS escaping in a style block. Sanitising on input forces you to guess every future destination, mangles legitimate data (an apostrophe in `O'Brien`, a `<` in a maths formula), and silently fails the moment someone adds a new template. Encode at the sink, where you know the sink. HTML escaping is **wrong** when the value is interpolated into a JavaScript context — `var q = "<%= html_escape(q) %>"` leaves `</script>` and backslash sequences exploitable, and is a well-known bypass; that context needs a JavaScript-string encoder, or better, pass the value as JSON via a data attribute. It is likewise wrong for a URL context, where `&amp;` is not what you want. The CSP header is defence in depth for when the encoding is missed somewhere.

**4.** Neither is sufficient alone. **`Origin` alone** fails because it is absent on some legitimate requests (certain navigations and older clients), so you must decide what to do when it is missing — reject and break real users, or accept and lose the defence; proxies and gateways can also rewrite it, and `null` origins from sandboxed contexts complicate the allow-list. **A token alone** fails if it leaks — through a URL in a `Referer`, an XSS that reads the DOM, a subdomain takeover reading a too-broadly-scoped cookie — or if the framework's comparison is weak. Together they require an attacker to defeat two independent mechanisms. **`SameSite=Lax`** is the browser-enforced third layer: the browser simply does not attach the cookie to cross-site `POST`s, so the forged request arrives unauthenticated and the server-side checks never need to fire. It is the strongest of the three because it does not depend on your application code being right — but it depends on the user's browser, it does not protect against a same-site attacker (another application on a sibling subdomain), and it is not a substitute for the token, which is why the layered answer is correct.

**5.** `Lax` attaches the cookie to cross-site **top-level `GET` navigations** — a link click, a redirect, a `window.location`. So if any state-changing operation is reachable by `GET`, `SameSite=Lax` does not protect it: `<img src="https://shop.example/account/delete">` on an attacker's page is a top-level-ish request the browser will happily authenticate. The design rule is therefore that **`GET` (and `HEAD`) must be safe** — no side effects, no state change, ever — and every mutation must use `POST`, `PUT`, `PATCH` or `DELETE`. That comes from the HTTP semantics definition of *safe* methods (RFC 9110 §9.2.1), and it is not merely a convention: browsers, proxies, crawlers, link prefetchers and accelerators all assume it. An endpoint like `GET /orders/123/cancel` will eventually be triggered by a search engine indexing a page, with no attacker involved at all.

**6.** **Security misconfiguration** — more precisely, verbose error and debug output exposed to the caller (the OWASP Top 10 category A05, with the underlying weakness being exposure of sensitive information through an error message). Independently of whether injection succeeds, the attacker learns the exact SQL dialect and its quoting behaviour, the real table and column names, how the query is constructed (string interpolation is visible in the shape of the output), and therefore precisely how to craft a payload — turning a blind probing exercise into a targeted one. The same category covers stack traces, framework version banners and directory listings: each is individually "not a vulnerability" and collectively the reconnaissance that makes the real one cheap to find.

### Block 9 — The contract

**1.** The rule is **"be conservative in what you send, liberal in what you accept"** applied per direction. A provider may **add an optional field to a request** (old clients that omit it still work) but may not add a *required* one, and may not remove or narrow an existing one. A provider may **add a field to a response** (old clients ignore what they do not know, provided they do not validate strictly) but may not remove one, nor change a field's type, nor remove a value from an enum a client might be switching on. The asymmetry is that **requests break on additions and responses break on removals**, because the consumer constructs the request and consumes the response — you cannot break someone by giving them more than they asked for, but you can by demanding more than they knew to send. Adding a value to a response enum is the subtle one: it is an addition, but it breaks any consumer with an exhaustive `match`, which is why enums should be documented as open-ended from day one.

**2.** Generating the contract from the code means the contract can only ever describe what the code already does, so it cannot be a design instrument or a negotiation artifact — the consumer team has nothing to review until the provider has already built it, and any awkwardness in the implementation becomes a published API shape. It also means an accidental change to the code silently becomes a change to the contract; the frozen-baseline diff in step 3 exists precisely to put a gate back in that path. Generating it is nevertheless right when the code is the older authority — an existing service being documented for the first time, where a hand-written spec would immediately be a second source of truth that drifts. The healthy pattern for new work is contract-first for the design, then generate-and-diff in CI to prove the implementation still matches.

**3.** Because the consumer's contract is "the fields I depend on are present and correct", not "the response contains exactly these fields". An equality assertion would fail the moment the provider makes a legitimate, non-breaking addition — a new `created_at`, a new `currency` — turning every additive change into a red build across every consumer, which trains everyone to stop trusting the tests. The subset check encodes the actual coupling: it fails exactly when something the consumer needs disappears, and stays green otherwise. This is the whole idea behind consumer-driven contracts — each consumer publishes the narrow slice it truly uses, and the provider is free everywhere else.

**4.** **Expand / migrate / contract**, sometimes called parallel change. (1) *Expand:* deploy a version that supports both shapes simultaneously — the new field is optional and the old one still accepted, or the new endpoint exists alongside the old; nothing has broken, and this ships independently of every consumer. (2) *Migrate:* consumers move to the new shape at their own pace, in their own release cycles, with no coordination window. (3) *Contract:* remove the old shape. The mechanism that tells you when step 3 is safe is **per-consumer usage telemetry on the deprecated path** — a counter labelled by client identity or API key on the old field/endpoint, plus a `Deprecation` and `Sunset` header on the responses so consumers are warned in-band. You remove it when the counter has been zero for longer than your slowest consumer's release cycle, and you know *who* to chase when it is not. Guessing, or announcing a date and hoping, is how flag days come back.

**5.** A standard error body (RFC 9457 *Problem Details*) means the client can write **one** error handler instead of one per endpoint per service. It gets a stable machine-readable `type` URI it can branch on — distinguishing "insufficient stock" from "invalid SKU" without string-matching a human message that will be reworded or translated — a `status` that survives proxies rewriting the response line, and a documented place (`detail`, plus extension members) for the specifics. With `{"error": "..."}` the client has only prose: branching on it is fragile, localising it is impossible, and every new service invents a different shape, so the aggregation layer, the SDK and the log pipeline all need per-service special cases. The standard also settles the questions teams otherwise re-argue forever — where the field-level validation errors go, whether there is an identifier for correlating with logs.

### Block 10 — Immutability and disposability

**1.** `podman restart` stops and starts **the same container** — the same writable layer on top of the image — so filesystem changes persist. `podman rm` followed by `podman run` creates a **new container** with a fresh writable layer derived from the image alone, so the change is gone. This is more dangerous than immediate loss because it creates a **survivor**: the patch works, it survives restarts, it survives the reboot of the host, and it therefore stops looking like a temporary measure. It disappears at the next deploy, the next node drain, the next autoscaling event, or on one replica but not the others — so the symptom is an intermittent regression that correlates with nothing in your change log, and the fix that "was definitely applied" is nowhere in git. Immediate loss would have been honest feedback.

**2.** (a) **You cannot tell what is running.** `orders:latest` on two nodes may be two different images, because each pulled at a different time; `podman images` shows the same tag and the digests differ. Debugging a production incident then starts with an unanswerable question. (b) **Rollback has no target.** Rolling back means deploying the previous artifact, and with a moving tag the previous artifact has no name — it exists only as a digest you would have had to record separately, and may already have been garbage-collected from the registry. (c) **Deploys become non-deterministic and non-reproducible.** A pod rescheduled at 03:00 with `imagePullPolicy: Always` silently picks up whatever `latest` means then, so a node failure becomes an unplanned deploy; and re-running the same manifest twice can produce two different systems, which destroys the property that makes declarative infrastructure work at all. A SHA tag (or better, a digest reference) makes each of these questions answerable by inspection.

**3.** Because it inverts the provenance: the resulting image's contents are explained by a sequence of interactive commands nobody recorded, not by a Containerfile in version control. You cannot diff it, cannot review it, cannot rebuild it from source, cannot tell whether the patched binary matches any commit, and cannot reproduce it after a base-image CVE forces a rebuild — at which point the hand-patch is silently lost or must be reverse-engineered from a running process. It also tends to bake in whatever runtime state was present at snapshot time: temporary files, a populated cache, credentials written by an init step, the container's own hostname. The legitimate use is **forensics**: snapshotting a misbehaving container so you can dissect it offline while the orchestrator replaces it — an artifact for investigation, explicitly never for deployment.

**4.** Uvicorn drained the in-flight request, but zero downtime additionally requires that **no new request is routed to the process after it begins shutting down**, and that is not something the process can arrange alone. The orchestrator must (a) remove the pod from the load balancer's endpoint list *before or as* it sends `SIGTERM`, (b) allow a `preStop` grace period long enough for that removal to propagate to every proxy — endpoint propagation is asynchronous, and a pod that stops accepting connections before the last proxy has been updated produces exactly the connection-refused errors you were trying to avoid — and (c) set `terminationGracePeriodSeconds` longer than the application's longest legitimate request, or the drain is cut short by `SIGKILL`. The signal it depends on is the **readiness probe**: readiness, not liveness, controls endpoint membership, so a container that fails readiness is removed from service while continuing to run and finish its in-flight work. Confusing the two — using liveness to signal "I am draining" — gets the pod killed instead of drained.

**5.** It supports **factor VI (stateless, share-nothing processes)** and, together with the SHA-tagged image, **factor V** — the running container is byte-identical to the artifact, with no writable divergence. To make the filesystem read-only (`readOnlyRootFilesystem: true`) you must give the process a writable `emptyDir`/`tmpfs` for every path it genuinely needs: `/tmp` (Python writes there, as do many libraries), any cache directory the framework or dependency manager uses, and the Unix socket path if you use one. You must also ensure nothing writes into the application directory at runtime — no `.pyc` generation into `/srv/app` (set `PYTHONDONTWRITEBYTECODE=1`, or pre-compile at build time), no log files, no PID files. Logs go to stdout, which is factor XI and costs you nothing here.

**6.** It is acceptable in the lab because the exercise is about image immutability and the config boundary, and a file-backed SQLite database keeps the moving parts to one. It destroys **the disposability of the process**, and with it everything that depends on it: the data lives in the container's writable layer, so it vanishes when the container is replaced — which, per step 5, is what every deploy, node drain and reschedule does. Two replicas would have two divergent databases with no reconciliation, so the service cannot be scaled at all. The correct form is factor IV: the database is an **attached backing service**, reachable at a URL supplied by the environment, whose lifecycle is entirely independent of any application instance, so that destroying an instance destroys nothing but the instance.

</details>

---

## Sources

- LPI, *Exam 701 Objectives (DevOps Tools Engineer)* — <https://www.lpi.org/our-certifications/exam-701-objectives/>
- Adam Wiggins et al., *The Twelve-Factor App* — <https://12factor.net/>
- IETF RFC 9110, *HTTP Semantics* (methods, status codes, conditional requests, safe and idempotent methods) — <https://www.rfc-editor.org/rfc/rfc9110.html>
- IETF RFC 9111, *HTTP Caching* (`Cache-Control`, freshness, validators, `Vary`) — <https://www.rfc-editor.org/rfc/rfc9111.html>
- IETF RFC 9457, *Problem Details for HTTP APIs* — <https://www.rfc-editor.org/rfc/rfc9457.html>
- IETF RFC 6265bis / `SameSite` cookie attribute — <https://datatracker.ietf.org/doc/html/draft-ietf-httpbis-rfc6265bis>
- IETF, *The Idempotency-Key HTTP Header Field* — an Internet-Draft, not yet a standard; the header is widely deployed but not normatively specified — <https://datatracker.ietf.org/doc/draft-ietf-httpapi-idempotency-key-header/>
- OpenAPI Initiative, *OpenAPI Specification 3.1.0* — <https://spec.openapis.org/oas/v3.1.0.html>
- OWASP, *Top 10 Web Application Security Risks* — <https://owasp.org/www-project-top-ten/>
- OWASP, *Cross-Site Scripting Prevention Cheat Sheet* — <https://cheatsheetseries.owasp.org/cheatsheets/Cross_Site_Scripting_Prevention_Cheat_Sheet.html>
- OWASP, *Cross-Site Request Forgery Prevention Cheat Sheet* — <https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html>
- OWASP, *SQL Injection Prevention Cheat Sheet* — <https://cheatsheetseries.owasp.org/cheatsheets/SQL_Injection_Prevention_Cheat_Sheet.html>
- SQLite, *Transaction control* (`BEGIN IMMEDIATE`, WAL) — <https://www.sqlite.org/lang_transaction.html>
- PostgreSQL, *Explicit Locking / `SELECT ... FOR UPDATE`* — <https://www.postgresql.org/docs/current/explicit-locking.html>
- Kubernetes, *Pod Lifecycle — termination and readiness* — <https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/>
- FastAPI documentation — <https://fastapi.tiangolo.com/>
- Uvicorn deployment documentation (signal handling and graceful shutdown) — <https://www.uvicorn.org/deployment/>