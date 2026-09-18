# 701.1 — Desarrollo de software moderno: ejercicios guiados

**Examen:** LPI DevOps Tools Engineer, 701-100 (versión 2.0.0) · **Peso del tema:** 10

Estos ejercicios construyen un sistema pequeño — un servicio `orders` y sus dependencias — y después lo atacan desde todos los ángulos que nombra el objetivo: descomposición en servicios, diseño de API, configuración, estado, almacenamiento, seguridad e inmutabilidad. Todo corre en un único host Linux con Python 3.12 y un runtime de contenedores. Nada de lo que hay acá habla con una red que no sea tuya.

Recorrelos en orden; cada uno deja artefactos que usa el siguiente.

**Requisitos previos del laboratorio**

```bash
mkdir -p ~/lab-701.1 && cd ~/lab-701.1
python3.12 -m venv .venv
.venv/bin/pip install --quiet --upgrade pip
.venv/bin/pip install --quiet \
  "fastapi==0.115.6" "uvicorn[standard]==0.34.0" "httpx==0.28.1" "pytest==8.3.4"
.venv/bin/python -c "import fastapi, sys; print(fastapi.__version__, sys.version.split()[0])"
podman --version || docker --version
```

Salida esperada:

```
0.115.6 3.12.9
podman version 5.4.0
```

A lo largo de todo el documento, `podman` y `docker` son intercambiables; sustituí el que tengas.

---

## Ejercicio 1 — Encontrar las costuras antes de trazar los límites de los servicios

El objetivo pide *diseñar* aplicaciones basadas en servicios. El fallo más común es trazar los límites en una pizarra por intuición de negocio y descubrir en el momento de implementar que dos servicios "independientes" comparten una tabla. La técnica confiable va en el sentido contrario: mapear qué código toca qué datos y cortar donde el mapa ya es fino.

**Paso 1.** Creá el monolito que vas a descomponer.

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

**Paso 2.** Escribí el mapeador de acoplamiento. Parsea el módulo con el propio AST de Python y extrae los nombres de tablas de los literales SQL por función — sin LLM, sin conexión a base de datos, sin ejecución.

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

**Paso 3.** Ejecutalo.

```bash
cd ~/lab-701.1/decompose && ../.venv/bin/python seams.py monolith.py
```

Salida esperada:

```
create_customer  -> customers
place_order      -> customers, inventory, orders, outbox
restock          -> inventory
customer_report  -> customers, orders
```

**Paso 4.** Proponé la división. Anotá en papel qué servicio es dueño de cada una de las cuatro tablas y marcá cada función que pasaría a cruzar un límite de proceso.

> **Preguntas — bloque 1**
>
> 1. `restock` y `create_customer` tocan exactamente una tabla cada una. ¿Qué te dice eso sobre dónde debería ir el primer corte, y por qué "toca una tabla" es mejor señal que "suena a un dominio"?
> 2. `customer_report` hace un `JOIN` entre `customers` y `orders`. Después de la división, la base de datos no puede ejecutar ese JOIN. Nombrá las dos respuestas estándar e indicá el costo que impone cada una.
> 3. `place_order` escribe en `orders` y en `outbox` dentro de la misma conexión. ¿Por qué es más fuerte que "confirmar el pedido y después publicar en el broker de mensajes"? ¿Qué puede salir mal exactamente en la segunda versión?
> 4. Después de la división, `place_order` necesita la dirección de correo del cliente. Dá un argumento a favor de obtenerla de forma síncrona desde el servicio Customers en el momento del pedido, y un argumento a favor de guardar en su lugar una copia desnormalizada en el servicio Orders.

---

## Ejercicio 2 — Configuración de doce factores y la separación build/release/run

El factor III dice que la configuración vive en el entorno; el factor V dice que build, release y run están estrictamente separados. Ambas son afirmaciones verificables, no eslóganes.

**Paso 1.** Creá el paquete de la aplicación y un módulo de configuración que falla en tiempo de importación.

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

**Paso 2.** Importalo con un entorno vacío e inspeccioná el estado de salida.

```bash
cd ~/lab-701.1 && env -u DATABASE_URL -u SESSION_SECRET .venv/bin/python -c "import app.config"
echo "exit=$?"
```

Salida esperada (traceback abreviado):

```
Traceback (most recent call last):
  File "<string>", line 1, in <module>
  File "/home/user/lab-701.1/app/config.py", line 18, in <module>
    DATABASE_URL = _require("DATABASE_URL")
                   ^^^^^^^^^^^^^^^^^^^^^^^^
app.config.ConfigError: missing or empty required environment variable: DATABASE_URL
exit=1
```

**Paso 3.** Suministrá el entorno y confirmá que el mismo código ahora arranca.

```bash
cd ~/lab-701.1
export DATABASE_URL="sqlite:///orders.db"
export SESSION_SECRET="dev-only-not-a-real-secret"
export RELEASE="1.0.0+dev"
.venv/bin/python -c "import app.config as c; print(c.DATABASE_URL, c.PORT, c.LOG_LEVEL, c.RELEASE)"
```

Salida esperada:

```
sqlite:///orders.db 8080 info 1.0.0+dev
```

**Paso 4.** Aplicá la prueba de fuego del factor III.

```bash
cd ~/lab-701.1 && grep -rIn -E "(password|secret|token|api[_-]?key)\s*=\s*['\"]" app/ || echo "no literal credentials in app/"
```

Salida esperada:

```
no literal credentials in app/
```

**Paso 5.** Demostrá build/release/run con un artefacto y dos releases. Escribí el archivo compose que describe dos entornos de la *misma* imagen:

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

> **Preguntas — bloque 2**
>
> 1. `config.py` lanza la excepción durante la *importación*, no en la primera petición. Nombrá dos beneficios operativos concretos de fallar tan temprano, específicamente en un entorno orquestado como Kubernetes.
> 2. Un colega propone `config/staging.yaml`, `config/production.yaml` en el repositorio, seleccionados por `APP_ENV`. Dá la objeción precisa desde los doce factores — y decí qué parte de la propuesta sí está bien.
> 3. Ambos servicios de compose usan `image: "localhost/orders:1.0.0"`. ¿Qué factor satisface eso y qué se rompería si staging usara `orders:1.0.0-staging` construido desde el mismo commit?
> 4. `PORT` tiene un valor por defecto de `8080` pero `SESSION_SECRET` no tiene ninguno. Enunciá la regla que decide qué valores de configuración pueden llevar un valor por defecto.

---

## Ejercicio 3 — Semántica REST: recursos, códigos de estado e idempotencia

**Paso 1.** Escribí la primera versión de la API.

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

**Paso 2.** Arrancala en una segunda terminal (mantené exportadas ahí también las variables de entorno del ejercicio 2).

```bash
cd ~/lab-701.1 && .venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8080
```

Salida esperada:

```
INFO:     Started server process [24118]
INFO:     Waiting for application startup.
INFO:     Application startup complete.
INFO:     Uvicorn running on http://127.0.0.1:8080 (Press CTRL+C to quit)
```

**Paso 3.** Creá un recurso y leé la línea de respuesta y las cabeceras.

```bash
curl -isS -X POST http://127.0.0.1:8080/orders \
  -H 'Content-Type: application/json' \
  -d '{"sku":"SKU-1","qty":2}'
```

Salida esperada (las fechas y los UUID van a diferir):

```
HTTP/1.1 201 Created
date: Fri, 18 Sep 2026 09:12:44 GMT
server: uvicorn
content-length: 83
content-type: application/json
location: /orders/0f2b7c1e-6a4d-4f83-9a55-8e1d5c0b21aa

{"id":"0f2b7c1e-6a4d-4f83-9a55-8e1d5c0b21aa","sku":"SKU-1","qty":2,"status":"placed"}
```

**Paso 4.** Reproducí el bug de envío duplicado: mandá la petición idéntica dos veces sin clave de idempotencia.

```bash
for i in 1 2; do
  curl -sS -X POST http://127.0.0.1:8080/orders \
    -H 'Content-Type: application/json' -d '{"sku":"SKU-9","qty":1}' \
  | .venv/bin/python -c "import json,sys; print(json.load(sys.stdin)['id'])"
done
```

Salida esperada — dos identificadores distintos, es decir, dos pedidos reales:

```
3c9f1d80-7b21-4d0e-b0c8-2a1f5e4477c1
b5e2a744-19ad-4c6f-8f27-6de0c3b91f52
```

**Paso 5.** Repetí con una clave de idempotencia.

```bash
KEY=$(uuidgen)
for i in 1 2; do
  curl -sS -o /tmp/body -w "%{http_code} %{redirect_url}\n" -X POST http://127.0.0.1:8080/orders \
    -H 'Content-Type: application/json' -H "Idempotency-Key: $KEY" \
    -d '{"sku":"SKU-9","qty":1}'
  cat /tmp/body; echo
done
```

Salida esperada — un pedido, dos respuestas seguras:

```
201 
{"id":"a71c0e55-4f9b-42d6-9b58-1cc3d77e08b1","sku":"SKU-9","qty":1,"status":"placed"}
200 
{"id":"a71c0e55-4f9b-42d6-9b58-1cc3d77e08b1","sku":"SKU-9","qty":1,"status":"placed"}
```

**Paso 6.** Recorré los caminos de error y anotá qué capa produjo cada estado.

```bash
curl -sS -o /dev/null -w "invalid body : %{http_code}\n" -X POST http://127.0.0.1:8080/orders \
  -H 'Content-Type: application/json' -d '{"sku":"SKU-1","qty":0}'
curl -sS -o /dev/null -w "unknown id  : %{http_code}\n" http://127.0.0.1:8080/orders/does-not-exist
curl -sS -o /dev/null -w "wrong verb  : %{http_code}\n" -X PUT http://127.0.0.1:8080/orders
curl -sS -X POST http://127.0.0.1:8080/orders -H 'Content-Type: application/json' \
  -d '{"sku":"SKU-1","qty":0}' | .venv/bin/python -c "import json,sys; print(json.load(sys.stdin)['detail'][0]['msg'])"
```

Salida esperada:

```
invalid body : 422
unknown id  : 404
wrong verb  : 405
Input should be greater than 0
```

> **Preguntas — bloque 3**
>
> 1. El paso 3 devolvió `201` con una cabecera `Location`. ¿Qué tiene que poder hacer un cliente con `Location` que no podría hacer solo con el cuerpo?
> 2. En el paso 5 la segunda llamada devolvió `200`, no `201`. Justificá esa elección frente a la alternativa de devolver `201` las dos veces.
> 3. `DELETE /orders/{id}` sobre un pedido ya cancelado devuelve `204`, pero sobre un pedido enviado devuelve `409`. Explicá por qué lo primero *no* es un error y lo segundo sí, en términos de la definición de idempotencia.
> 4. El cuerpo inválido produjo `422`, no `400`. Ambos son defendibles. Enunciá la distinción que se está trazando y decí qué debería hacer distinto un cliente en cada caso.
> 5. `POST /orders` con `qty: 0` falla en el framework antes de que corra tu handler. ¿Por qué la validación en el borde, expresada como un esquema, es una propiedad de diseño y no una comodidad?

---

## Ejercicio 4 — Peticiones condicionales, caché y las cabeceras que las vuelven seguras

**Paso 1.** Obtené un pedido y capturá su `ETag`.

```bash
ID=$(curl -sS -X POST http://127.0.0.1:8080/orders -H 'Content-Type: application/json' \
  -d '{"sku":"SKU-CACHE","qty":3}' \
  | .venv/bin/python -c "import json,sys; print(json.load(sys.stdin)['id'])")
curl -isS "http://127.0.0.1:8080/orders/$ID" | grep -Ei '^(HTTP|etag|cache-control)'
```

Salida esperada:

```
HTTP/1.1 200 OK
etag: "4c0d1f7a9b3e5821"
cache-control: private, max-age=30
```

**Paso 2.** Volvé a pedirlo con el validador.

```bash
ETAG=$(curl -sS -D - -o /dev/null "http://127.0.0.1:8080/orders/$ID" | awk -F': ' 'tolower($1)=="etag"{print $2}' | tr -d '\r')
curl -isS -H "If-None-Match: $ETAG" "http://127.0.0.1:8080/orders/$ID" | head -n 1
curl -sS -o /dev/null -w "bytes transferred: %{size_download}\n" \
  -H "If-None-Match: $ETAG" "http://127.0.0.1:8080/orders/$ID"
```

Salida esperada:

```
HTTP/1.1 304 Not Modified
bytes transferred: 0
```

**Paso 3.** Cambiá el recurso y demostrá que el validador invalida.

```bash
curl -sS -o /dev/null -X DELETE "http://127.0.0.1:8080/orders/$ID"
curl -isS -H "If-None-Match: $ETAG" "http://127.0.0.1:8080/orders/$ID" | grep -Ei '^(HTTP|etag)'
```

Salida esperada:

```
HTTP/1.1 200 OK
etag: "8f3b2c60d14ae997"
```

**Paso 4.** Analizá qué pasaría detrás de una caché compartida. La respuesta lleva `private`; cambialo temporalmente a `public, max-age=30` en `app/main.py`, reiniciá y repetí el paso 1 con dos cabeceras `Authorization` distintas.

> **Preguntas — bloque 4**
>
> 1. El `304` devolvió cero bytes de cuerpo, pero la petición igual cruzó la red. Nombrá el recurso que ahorra y el recurso que *no* ahorra, y dá un caso donde ese intercambio no vale la pena.
> 2. `Cache-Control: private` sobre un pedido de un cliente concreto. Describí con precisión el incidente que causaría `public` en una CDN compartida, y nombrá la cabecera que haría falta si la respuesta variara legítimamente según `Authorization`.
> 3. El `ETag` de acá es un hash del cuerpo serializado — un validador *fuerte*. ¿Qué se rompe si en su lugar derivás el `ETag` de `updated_at` truncado a segundos enteros?
> 4. El `ETag` también habilita `If-Match` en las escrituras. Esbozá el intercambio petición/respuesta que impide que dos clientes se sobrescriban silenciosamente la edición mutua, y dá el código de estado que recibe el perdedor.

---

## Ejercicio 5 — Procesos sin estado: reproducir el fallo de sesiones pegajosas y eliminarlo

**Paso 1.** Construí un servicio deliberadamente con estado.

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

**Paso 2.** Ejecutá dos instancias, como haría un deployment escalado.

```bash
cd ~/lab-701.1
INSTANCE=a .venv/bin/uvicorn cart.stateful:app --port 9001 &
INSTANCE=b .venv/bin/uvicorn cart.stateful:app --port 9002 &
sleep 2
```

**Paso 3.** Agregá un ítem en la instancia `a` y después leé el carrito desde la instancia `b` — exactamente lo que hace un balanceador de carga round-robin.

```bash
cd /tmp && rm -f jar.txt
curl -sS -c jar.txt -X POST "http://127.0.0.1:9001/cart/items?sku=SKU-1"; echo
curl -sS -b jar.txt "http://127.0.0.1:9001/cart"; echo
curl -sS -b jar.txt "http://127.0.0.1:9002/cart"; echo
```

Salida esperada:

```
{"instance":"a","cart_id":"1f5d9a02-0f4c-4f31-8a8e-b41c0f0a5c33","items":["SKU-1"]}
{"instance":"a","items":["SKU-1"]}
{"instance":"b","items":[]}
```

**Paso 4.** Volvé el proceso sin estado sacando el estado afuera. Acá el estado lo lleva el cliente en un token firmado y a prueba de manipulación; el servidor no guarda nada.

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

**Paso 5.** Repetí la prueba entre instancias.

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

Salida esperada:

```
{"instance":"b","items":["SKU-1"]}
{"instance":"b","items":["SKU-1","SKU-2"]}
{"instance":"a","items":["SKU-1","SKU-2"]}
```

**Paso 6.** Confirmá que la firma es estructural.

```bash
cd /tmp
BAD=$(sed -n 's/.*cart\s*\(.*\)/\1/p' jar.txt | tr -d '\r')
curl -sS -o /dev/null -w "%{http_code}\n" -H "Cookie: cart=${BAD%.*}.AAAAAAAA" "http://127.0.0.1:9001/cart"
kill %1 %2 2>/dev/null
```

Salida esperada:

```
400
```

> **Preguntas — bloque 5**
>
> 1. El paso 3 produjo un carrito vacío en la instancia `b`. Nombrá el factor de los doce factores que esto viola y describí qué te cuesta en realidad "activar sesiones pegajosas en el balanceador de carga" durante un despliegue progresivo.
> 2. La cookie sellada está firmada pero *no* cifrada. Enunciá qué puede y qué no puede hacer un atacante que la tenga, y dá una categoría de datos que por lo tanto nunca debe ir ahí.
> 3. Compará el enfoque de cookie firmada contra un almacén de sesiones compartido en Redis en exactamente un eje: revocar una sesión de inmediato. ¿Cuál gana y qué tiene que agregar el perdedor para compensar?
> 4. Tu colega dice "no tenemos estado; escribimos los archivos subidos en `/var/lib/app/uploads`". ¿Por qué eso sigue siendo tener estado y cuál es la prescripción de los doce factores?

---

## Ejercicio 6 — Acoplamiento débil: timeouts, amplificación de reintentos y un circuit breaker

**Paso 1.** Creá una dependencia cuya latencia controlás.

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

**Paso 2.** Llamala como lo hace la mayoría del código de primer borrador — con el timeout explícitamente desactivado, que es lo que te da `requests` por defecto.

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

Salida esperada — el proceso nunca retorna por sí solo; `timeout` lo mata:

```
exit=124
```

**Paso 3.** Acotala y medí la diferencia.

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

Salida esperada:

```
read timeout after 2.01s -> serve degraded response
```

**Paso 4.** Agregá un circuit breaker para que una dependencia caída deje de consumir tu capacidad por completo.

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

Salida esperada:

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

**Paso 5.** Limpiá.

```bash
kill %1 2>/dev/null
```

> **Preguntas — bloque 6**
>
> 1. El paso 2 se colgó indefinidamente. En un servidor síncrono con un pool de workers fijo, describí la secuencia que convierte "una dependencia lenta" en "todo el servicio devuelve 503".
> 2. Tres servicios están encadenados A → B → C, y cada uno reintenta 3 veces ante un fallo. Cuando C falla, ¿cuántas peticiones recibe C por cada petición original del cliente? Generalizá la fórmula y nombrá las dos mitigaciones.
> 3. El breaker cortocircuita en 0,00 s mientras está abierto. ¿Qué dos partes se benefician de eso y en qué se diferencia de simplemente bajar el timeout a 0,1 s?
> 4. El estado `half-open` del breaker deja pasar exactamente una sonda. ¿Qué sale mal si, en cambio, reabriera la compuerta al tráfico completo después del enfriamiento?
> 5. Todo este ejercicio trata sobre acoplamiento síncrono. Describí la misma interacción `orders → pricing` sobre un broker de mensajes, e indicá qué propiedad ganás y qué propiedad perdés.

---

## Ejercicio 7 — Almacenamiento de datos: elegir el modelo por el invariante que debe sostener

**Paso 1.** Construí la tabla de inventario con la restricción escrita.

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

Salida esperada:

```
[('SKU-1', 5)]
```

**Paso 2.** Escribí un banco de pruebas de concurrencia con dos implementaciones de "vender una unidad": un read-modify-write en el código de la aplicación y un compare-and-set dentro de la base de datos.

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

**Paso 3.** Ejecutá la versión ingenua. Reiniciá el stock primero.

```bash
cd ~/lab-701.1
.venv/bin/python -c "import sqlite3; c=sqlite3.connect('stock.db'); c.execute(\"UPDATE inventory SET on_hand=5 WHERE sku='SKU-1'\"); c.commit()"
.venv/bin/python oversell.py stock.db read-modify-write
```

Salida esperada (los números exactos varían entre ejecuciones; la forma no):

```
mode=read-modify-write  buyers=20 sold=20 on_hand=4
```

**Paso 4.** Ejecutá la versión compare-and-set.

```bash
cd ~/lab-701.1
.venv/bin/python -c "import sqlite3; c=sqlite3.connect('stock.db'); c.execute(\"UPDATE inventory SET on_hand=5 WHERE sku='SKU-1'\"); c.commit()"
.venv/bin/python oversell.py stock.db cas
```

Salida esperada — en cada ejecución, sin excepción:

```
mode=cas                  buyers=20 sold=5 on_hand=0
```

**Paso 5.** Decidí dónde va cada artefacto. Para el PDF de confirmación del pedido (≈ 300 kB, escrito una vez, leído rara vez, servido al cliente durante siete años), compará almacenarlo como una columna `BLOB` contra almacenar una clave en almacenamiento de objetos:

```
relational BLOB            object storage (S3-compatible)
--------------------------  ------------------------------
in the backup/restore path  out of it
costs DB IOPS on read       served directly, presigned URL
transactional with the row  eventually consistent with the row
row locking on large writes no lock contention
```

> **Preguntas — bloque 7**
>
> 1. La restricción `CHECK (on_hand >= 0)` estaba vigente durante el paso 3 y la base de datos igual terminó inconsistente con la realidad. Explicá exactamente por qué la restricción no se disparó, y qué dice eso sobre la diferencia entre validar un *valor* y serializar una *operación*.
> 2. La versión `cas` vendió exactamente 5 de 5, todas las veces. ¿Qué única propiedad de la sentencia la vuelve segura, y cuál es el patrón equivalente en PostgreSQL cuando la actualización es demasiado compleja para una sola sentencia?
> 3. Movés el inventario a un almacén de documentos sin transacciones multi-documento. Nombrá dos mecanismos que puedan restaurar la garantía de "nunca sobrevender" e indicá el costo de cada uno.
> 4. Usando la tabla del paso 5, argumentá el único caso en el que la columna `BLOB` *sí* es la respuesta correcta.
> 5. Se propone una capa de caché delante de la lectura de inventario. ¿Qué lecturas pueden cachearse, cuáles no deben, y por qué "cachear el nivel de stock durante 5 segundos" es más peligroso de lo que suena?

---

## Ejercicio 8 — Seguridad de aplicaciones: inyección SQL, XSS y CSRF sobre tu propio servicio de laboratorio

Todo lo de abajo corre contra `127.0.0.1` sobre código que acabás de escribir. El objetivo es ver el mecanismo y después ver funcionar la corrección.

**Paso 1.** Construí el servicio vulnerable.

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

**Paso 2.** Confirmá el camino normal y después inyectá.

```bash
curl -sS --get --data-urlencode "name=alice" http://127.0.0.1:9200/users/vulnerable; echo
curl -sS --get --data-urlencode "name=' OR '1'='1" http://127.0.0.1:9200/users/vulnerable; echo
```

Salida esperada:

```
{"sql":"SELECT id, name, role FROM users WHERE name = 'alice'","rows":[[1,"alice","admin"]]}
{"sql":"SELECT id, name, role FROM users WHERE name = '' OR '1'='1'","rows":[[1,"alice","admin"],[2,"bob","user"],[3,"carol","user"]]}
```

**Paso 3.** Enviá la misma carga útil al endpoint parametrizado.

```bash
curl -sS --get --data-urlencode "name=' OR '1'='1" http://127.0.0.1:9200/users/safe; echo
```

Salida esperada — la carga útil es dato, así que no coincide con nada:

```
{"rows":[]}
```

**Paso 4.** XSS reflejado: mirá los bytes crudos que emite el servidor.

```bash
curl -sS --get --data-urlencode "q=<script>alert(1)</script>" http://127.0.0.1:9200/search/vulnerable; echo
curl -isS --get --data-urlencode "q=<script>alert(1)</script>" http://127.0.0.1:9200/search/safe \
  | grep -Ei '^(content-security-policy)|<html'
```

Salida esperada:

```
<html><body><p>No results for <script>alert(1)</script></p></body></html>
content-security-policy: default-src 'self'
<html><body><p>No results for &lt;script&gt;alert(1)&lt;/script&gt;</p></body></html>
```

**Paso 5.** CSRF: falsificá la petición que haría una página maliciosa. El navegador adjuntaría la cookie de sesión automáticamente; `curl` lo hace explícitamente.

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

Salida esperada:

```
{"changed_email_to":"attacker@evil.example","authenticated_by":"cookie only"}
403
{"changed_email_to":"owner@shop.example"}
```

> **Preguntas — bloque 8**
>
> 1. `/users/safe` usa marcadores `?`. Explicá qué hace el driver de la base de datos que el escapado de cadenas no hace — y por qué "escapo las comillas con una función auxiliar" es una afirmación más débil que "uso parámetros ligados".
> 2. Tu ORM ofrece `.raw("SELECT ... WHERE name = %s")`. ¿Es seguro? ¿Bajo qué única condición vuelve a ser inseguro?
> 3. El endpoint "seguro" del paso 4 escapa la salida en lugar de sanear la entrada. Dá la razón arquitectónica por la que la codificación de salida es el lugar correcto, y nombrá un contexto donde el escapado HTML es el codificador *equivocado*.
> 4. La corrección de CSRF comprueba `Origin` **y** un token. ¿Por qué ninguno alcanza por sí solo en la práctica, y dónde encaja `SameSite=Lax` como tercera capa?
> 5. `SameSite=Lax` sigue permitiendo la navegación de nivel superior `GET` entre sitios. ¿Qué regla de diseño impone eso sobre tu API y de qué definición HTTP proviene?
> 6. El endpoint vulnerable devuelve al llamante el SQL generado. Independientemente de la inyección, nombrá la categoría de OWASP a la que eso pertenece por sí solo y qué aprende un atacante de ello.

---

## Ejercicio 9 — El contrato de la API: OpenAPI como límite de acoplamiento

**Paso 1.** Exportá el contrato legible por máquina desde la aplicación en ejecución y congelalo.

```bash
cd ~/lab-701.1
.venv/bin/python -c "import json; from app.main import app; print(json.dumps(app.openapi(), indent=2, sort_keys=True))" > openapi.json
.venv/bin/python -c "import json; d=json.load(open('openapi.json')); print(d['openapi'], sorted(d['paths']))"
cp openapi.json openapi.frozen.json
```

Salida esperada:

```
3.1.0 ['/orders', '/orders/{order_id}']
```

**Paso 2.** Leé cómo se ve un contrato escrito a mano para el mismo endpoint, incluidas las piezas que el generador no puede inferir — el comportamiento de las peticiones condicionales y el tipo de medio del error.

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

**Paso 3.** Escribí el detector de cambios incompatibles que corresponde tener en CI.

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

Salida esperada:

```
0 breaking change(s)
exit=0
```

**Paso 4.** Introducí un cambio incompatible y mirá cómo CI lo atrapa. Editá `app/main.py` para que `OrderIn` requiera un campo nuevo:

```bash
cd ~/lab-701.1
sed -i 's/    qty: int = Field(gt=0, le=100)/    qty: int = Field(gt=0, le=100)\n    warehouse: str = Field(min_length=1)/' app/main.py
.venv/bin/python -c "import json; from app.main import app; print(json.dumps(app.openapi(), indent=2, sort_keys=True))" > openapi.json
.venv/bin/python check_contract.py openapi.frozen.json openapi.json; echo "exit=$?"
```

Salida esperada:

```
BREAKING: newly required field: OrderIn.warehouse
1 breaking change(s)
exit=1
```

**Paso 5.** Revertí y hacé que el campo sea aditivo en su lugar.

```bash
cd ~/lab-701.1
sed -i 's/    warehouse: str = Field(min_length=1)/    warehouse: str = Field(default="default", min_length=1)/' app/main.py
.venv/bin/python -c "import json; from app.main import app; print(json.dumps(app.openapi(), indent=2, sort_keys=True))" > openapi.json
.venv/bin/python check_contract.py openapi.frozen.json openapi.json; echo "exit=$?"
```

Salida esperada:

```
0 breaking change(s)
exit=0
```

**Paso 6.** Escribí una prueba de contrato de consumidor — la comprobación de que las expectativas del *cliente* siguen valiendo.

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

Salida esperada:

```
...                                                                      [100%]
3 passed in 0.41s
```

> **Preguntas — bloque 9**
>
> 1. El paso 4 marcó `newly required field` y el paso 5 no. Formulá la regla general sobre lo que un proveedor puede agregar a una petición y a una respuesta sin romper a los consumidores. ¿En qué dirección está la asimetría?
> 2. El generador produjo el contrato a partir del código. Nombrá el riesgo concreto de esa dirección frente a escribir el contrato primero, y una situación en la que generarlo es, de todos modos, lo correcto.
> 3. `test_contract.py` afirma `{"id","sku","qty","status"} <= set(body)` en lugar de igualdad. ¿Por qué la comprobación de subconjunto es la aserción correcta para una prueba de consumidor?
> 4. Un cambio incompatible es genuinamente necesario. Describí la secuencia de pasos que lo despliega sin un "día de la bandera" coordinado, y nombrá el mecanismo que te dice cuándo se puede eliminar la versión vieja.
> 5. El `404` del paso 2 declara `application/problem+json`. ¿Qué le da al cliente estandarizar el cuerpo del error que inventar `{"error": "..."}` no le da?

---

## Ejercicio 10 — Servidores inmutables y procesos desechables

**Paso 1.** Escribí la definición de la imagen.

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

**Paso 2.** Construila, etiquetada con el commit que la produjo.

```bash
cd ~/lab-701.1
git init -q 2>/dev/null; git add -A 2>/dev/null; git -c user.email=lab@example -c user.name=lab commit -qm "lab" 2>/dev/null
SHA=$(git rev-parse --short HEAD)
podman build -q -t "localhost/orders:$SHA" .
podman images --format '{{.Repository}}:{{.Tag}} {{.Size}}' | head -n 1
```

Salida esperada:

```
localhost/orders:3fa91c2 158 MB
```

**Paso 3.** Ejecutala y confirmá que el release viene del entorno, no de la imagen.

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

Salida esperada:

```
{"status":"ok","release":"1.0.0+3fa91c2"}
```

**Paso 4.** Mutá el contenedor en ejecución como lo hace un "hotfix rápido en la máquina" y después reinicialo.

```bash
podman exec -u 0 orders-1 sh -c 'echo "PATCHED BY HAND" > /srv/app/hotfix.txt && cat /srv/app/hotfix.txt'
podman restart orders-1 >/dev/null && sleep 2
podman exec orders-1 sh -c 'cat /srv/app/hotfix.txt 2>&1 || true'
```

Salida esperada — la escritura sobrevive a un reinicio del mismo contenedor, que es precisamente la trampa:

```
PATCHED BY HAND
PATCHED BY HAND
```

**Paso 5.** Ahora hacé lo que hace el orquestador: reemplazar el contenedor a partir de la imagen.

```bash
SHA=$(git rev-parse --short HEAD)
podman rm -f orders-1 >/dev/null
podman run -d --name orders-1 -p 8090:8080 \
  -e DATABASE_URL="sqlite:///orders.db" -e SESSION_SECRET="lab-secret" -e RELEASE="1.0.0+$SHA" \
  "localhost/orders:$SHA" >/dev/null
sleep 2
podman exec orders-1 sh -c 'cat /srv/app/hotfix.txt 2>&1 || true'
```

Salida esperada:

```
cat: /srv/app/hotfix.txt: No such file or directory
```

**Paso 6.** Verificá el apagado ordenado. Agregá un endpoint lento, ejecutalo fuera del contenedor para poder ver los logs, iniciá una petición y enviá `SIGTERM` en pleno vuelo.

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

Salida esperada — la petición en vuelo se drena, no se corta:

```
INFO:     Shutting down
INFO:     Waiting for connections to close. (CTRL+C to force quit)
{"status":"finished despite shutdown"}
INFO:     Waiting for application shutdown.
INFO:     Application shutdown complete.
INFO:     Finished server process [24701]
```

**Paso 7.** Limpiá.

```bash
podman rm -f orders-1 >/dev/null 2>&1; echo cleaned
```

> **Preguntas — bloque 10**
>
> 1. El parche manual del paso 4 sobrevivió a `podman restart` y el del paso 5 no. Explicá la diferencia en términos del ciclo de vida del contenedor, y decí por qué el primer comportamiento es más peligroso que si el parche hubiera desaparecido de inmediato.
> 2. La imagen está etiquetada con el SHA del commit en lugar de `latest`. Nombrá tres problemas operativos distintos que causa una etiqueta `latest` móvil.
> 3. `podman commit` puede tomar una instantánea de un contenedor en ejecución y parcheado y convertirla en una imagen nueva. ¿Por qué es un antipatrón bajo los principios de infraestructura inmutable, y cuál es el único uso legítimo?
> 4. En el paso 6, uvicorn siguió sirviendo hasta que terminó la petición en vuelo. Describí qué debe hacer *además* un orquestador para que una actualización progresiva sea genuinamente sin caídas, y de qué señal de readiness depende.
> 5. La imagen corre como UID 10001 y la aplicación no escribe nada en el sistema de archivos. ¿Qué factor de los doce factores sostiene eso, y qué tendrías que cambiar para que el sistema de archivos sea de solo lectura?
6. `DATABASE_URL` apunta a SQLite dentro del contenedor. Enunciá por qué eso es aceptable para este laboratorio y exactamente qué propiedad destruye en producción.

---

## Respuestas

<details>
<summary>Hacé clic para revelar las respuestas de los diez bloques</summary>

### Bloque 1 — Encontrar las costuras

**1.** Una función que toca exactamente una tabla no tiene ninguna transacción que cruce límites y que se pueda romper. `restock` se convierte en un endpoint del servicio Inventory y `create_customer` en un endpoint del servicio Customers, sin nada más que negociar — la división es mecánica. "Suena a un dominio" es una hipótesis sobre el lenguaje; "toca una tabla" es una observación sobre el acoplamiento transaccional que efectivamente te va a morder. El lenguaje del dominio y la propiedad de los datos suelen coincidir, pero cuando discrepan ganan los datos, porque la base de datos es donde vive la atomicidad que estás por perder. Empezá por las costuras que el código ya tiene, no por las que te gustaría que tuviera.

**2.** Las dos respuestas son (a) **composición de API**: el llamante del reporte obtiene el cliente desde Customers y los pedidos desde Orders y hace el join en el código de la aplicación; el costo son patrones de llamadas N+1, latencia adicional, manejo de fallos parciales y la imposibilidad de filtrar u ordenar eficientemente entre los dos conjuntos de datos. (b) **Replicación de datos / modelo de lectura CQRS**: Orders se suscribe a los eventos de cliente y mantiene una copia local de los campos que necesita, así el join vuelve a ser local; el costo es consistencia eventual, un pipeline de replicación para operar y los datos duplicados quedándose viejos o divergiendo. No hay una tercera respuesta que conserve a la vez consistencia fuerte e independencia total — ese es el intercambio que compra la división.

**3.** Escribir en `outbox` dentro de la misma transacción es el patrón **transactional outbox**, y hace que "el pedido existe" y "el evento se va a publicar" sean un único hecho atómico. En la versión "confirmar y después publicar" hay una ventana entre el commit y el acuse del broker: si el proceso muere, se reinicia o el broker es inalcanzable, el pedido existe y nunca se emitió ningún evento. Nada aguas abajo — fulfillment, facturación, el correo de confirmación — ocurre jamás, y no hay error visible en ninguna parte, porque el pedido en sí tuvo éxito. Un proceso relay separado lee entonces `outbox` y publica con entrega al-menos-una-vez, que es la razón por la que los consumidores deben ser idempotentes (ver el ejercicio 3).

**4.** *Obtención síncrona:* la dirección de correo siempre está al día — un cliente que cambió su dirección hace diez segundos recibe la confirmación en el lugar correcto; hay exactamente una copia y por lo tanto no hay divergencia, y Customers sigue siendo la única autoridad sobre los datos de clientes. *Copia local:* Orders puede registrar un pedido mientras Customers está caído, lo que importa enormemente porque "no podemos tomar pedidos porque el directorio de clientes está degradado" es una cascada que afecta los ingresos; además la latencia es un salto de red menos en el camino crítico. La respuesta habitual en producción es la copia, más refresco dirigido por eventos — y aceptás que ocasionalmente una confirmación vaya a una dirección recientemente reemplazada.

### Bloque 2 — Configuración y build/release/run

**1.** (a) El contenedor **entra en crash-loop de inmediato** en lugar de arrancar, pasar su sonda de liveness y después fallar cada petición; el `CrashLoopBackOff` del orquestador y el estado de salida distinto de cero se vuelven la alerta, con el nombre de la variable faltante en el log. (b) Una actualización progresiva con un ConfigMap/Secret malo o incompleto **nunca se completa**, así que el deployment se estanca con los pods viejos, que funcionan, todavía sirviendo. Si el fallo ocurriera en la primera petición, en cambio, los pods nuevos pasarían a Ready, los viejos se destruirían y habrías reemplazado un release que funcionaba por uno roto antes de que nada te avisara.

**2.** La objeción no es al YAML — es que el *contenido de la configuración de producción está en el repositorio*. La prueba del factor III es si el código base podría hacerse open source en este instante sin filtrar una credencial; `production.yaml` con una contraseña de base de datos no pasa esa prueba. Además acopla los cambios de configuración a los despliegues de código (cambiar un timeout exige un commit, un build y un release), y la cantidad de valores de `APP_ENV` crece con cada entorno, así que los "entornos" se vuelven una enumeración cerrada dentro del código. Lo que sí está bien: un archivo de **valores por defecto**, con valores no secretos e independientes del entorno, versionado y sobrescrito por variables de entorno. La regla es: los valores por despliegue en el entorno, los valores invariantes en el build.

**3.** Satisface el **factor V, separación estricta de build, release y run**: un artefacto de build inmutable, combinado con configuración distinta para producir releases distintos. Si staging usara `orders:1.0.0-staging`, los bytes que probaste en staging no serían los bytes que corren en producción — un build distinto, con una caché de capas distinta, posiblemente un digest de imagen base distinto y una resolución de dependencias transitivas distinta. Cada resultado de staging sería entonces evidencia sobre un artefacto que no vas a desplegar, que es exactamente la clase de bug "funciona en staging" más difícil de diagnosticar.

**4.** Un valor puede llevar un valor por defecto cuando un **valor equivocado pero plausible es inofensivo y detectable**; no puede cuando un valor equivocado es inseguro o silenciosamente incorrecto. `PORT=8080` es inofensivo: si está mal, nada se conecta y te enterás en segundos. `SESSION_SECRET` con un valor por defecto es catastrófico: la aplicación arranca, funciona perfecto, y cualquiera que haya leído el código fuente puede falsificar todas las cookies de sesión en producción. El mismo razonamiento prohíbe los valores por defecto para `DATABASE_URL` — uno que apunte a un archivo SQLite local dejaría que producción arranque y acumule datos en silencio en un archivo que desaparece en el próximo reinicio del pod.

### Bloque 3 — Semántica REST

**1.** `Location` le da al cliente la **URI canónica asignada por el servidor** del recurso nuevo, cosa que el `id` del cuerpo por sí solo no hace: de otro modo el cliente tendría que conocer la plantilla de URI (`/orders/{id}`) y construirla, incrustando tu enrutamiento en cada consumidor. Con `Location` el servidor puede mover los recursos bajo `/v2/orders/`, distribuirlos en otro host o emitir identificadores opacos, y el cliente sigue funcionando siguiendo la URI que se le dio.

**2.** El `201` de la primera respuesta es una afirmación fáctica: *esta petición creó un recurso*. La segunda petición no creó nada; devolver `201` otra vez sería una mentira sobre la que el cliente puede actuar — un cliente que registra "pedido creado" por cada `201` contaría doble, y un intermediario que cuente creaciones también. `200` con el mismo cuerpo y el mismo `Location` dice con veracidad "acá está el recurso al que se refiere tu clave; ya existía". La visión alternativa — siempre `201`, con el argumento de que la intención del cliente se satisfizo en ambos casos — es defendible y algunas APIs lo hacen; el argumento decisivo en contra es que el código de estado describe lo que *ocurrió*, no lo que el cliente quería.

**3.** Idempotencia significa que *el efecto de N peticiones idénticas es igual al efecto de una*. `DELETE` sobre un pedido ya cancelado tiene exactamente esa propiedad: la poscondición que el cliente pidió ("este pedido está cancelado") es verdadera, así que devolver éxito es correcto, no una mentira — y un cliente que reintenta después de una respuesta perdida obtiene una respuesta limpia en lugar de un error espurio. El pedido enviado es distinto en naturaleza: la poscondición pedida **no se puede alcanzar en absoluto**, sin importar cuántas veces preguntes. `409 Conflict` informa un conflicto con el estado actual del recurso y, a diferencia de un timeout, no debe reintentarse — el cliente necesita una acción diferente (una devolución, una retirada), no otro intento.

**4.** `400 Bad Request` dice que la petición está mal formada a nivel de protocolo o sintaxis — JSON truncado, un `Content-Type` incorrecto, un cuerpo no parseable. `422 Unprocessable Content` dice que la sintaxis estaba bien y el servidor la entendió, pero la *semántica* está mal — `qty: 0` es JSON válido y del tipo correcto, simplemente no es un valor permitido. La diferencia para el cliente es concreta: con `400` el cliente tiene un bug de serialización o de transporte y reintentar los mismos bytes no sirve de nada; con `422` los datos del cliente están mal y normalmente puede mapear el campo `loc` del error directamente a un campo del formulario y mostrarle al usuario qué corregir.

**5.** Porque el esquema *es* el contrato, y la validación en el borde es lo que vuelve ese contrato exigible en lugar de aspiracional. De ahí se siguen tres consecuencias. Primera: todo handler por debajo del borde puede asumir que sus entradas están bien formadas, así que no hay re-chequeos defensivos dispersos por el código base ni ningún camino por el que un valor sin validar llegue a la base de datos. Segunda: las reglas de validación son introspectables — generan el documento OpenAPI del ejercicio 9, así que el contrato publicado no puede desviarse del contrato aplicado. Tercera: rechazar entradas malas antes de que corra cualquier lógica de negocio o trabajo de base de datos es el fallo más barato posible, lo que importa cuando la entrada mala es volumen hostil y no un error honesto.

### Bloque 4 — Caché y peticiones condicionales

**1.** Ahorra **ancho de banda y el trabajo de serialización del servidor** — cero bytes de cuerpo, y el origen a menudo puede responder con una comprobación barata del validador en lugar de renderizar la representación completa. **No** ahorra el viaje de ida y vuelta: la petición igual viaja hasta el origen y el cliente igual espera un RTT completo. Ese intercambio es malo cuando domina la latencia — un cliente móvil en un enlace de 300 ms que obtiene cincuenta recursos pequeños paga cincuenta viajes de ida y vuelta para no enterarse de nada nuevo. Ahí lo que querés es un tiempo de frescura (`max-age`), porque una respuesta fresca en caché se sirve sin red en absoluto; los validadores son para cuando la corrección exige preguntar.

**2.** Con `public`, una CDN compartida cachea la representación del pedido de Alice bajo la URL `/orders/{id}` y sirve esos mismos bytes al siguiente que pida esa URL — una fuga de datos entre clientes, y de la peor clase, porque es intermitente, invisible en tus propios logs y depende de una topología de caché que no controlás. `private` les dice a las cachés compartidas que no pueden almacenarla, sin dejar de permitir la caché propia del navegador. Si una respuesta realmente varía según la credencial y aun así querés caché compartida, tenés que enviar `Vary: Authorization` para que la caché también incluya la credencial en su clave — pero `private` más autorización es el valor por defecto seguro para datos por cliente, y `Vary: Authorization` es una cabecera fácil de manejar mal para un intermediario.

**3.** Un `updated_at` con granularidad de segundos no puede distinguir dos cambios que ocurren dentro del mismo segundo. El fallo es una actualización perdida desde el punto de vista del cliente: un cliente obtiene el recurso en `t`, el recurso se modifica dos veces en `t+0,2` y `t+0,7`, y el validador es idéntico para ambos — así que el `If-None-Match` del cliente coincide, recibe `304`, y se queda con una representación dos revisiones atrasada sin manera de saberlo. Por eso exactamente HTTP distingue validadores fuertes de débiles: solo un validador fuerte puede usarse para peticiones de rango de bytes y para `If-Match` en escrituras. Un hash del cuerpo es fuerte por construcción.

**4.** Esto es **control de concurrencia optimista**. El cliente A hace `GET` del pedido y recibe `ETag: "abc"`. El cliente B hace lo mismo. A envía `PUT /orders/{id}` con `If-Match: "abc"`; el servidor compara, coincide, aplica la escritura y el ETag del recurso pasa a ser `"def"`. B envía ahora su `PUT` con `If-Match: "abc"`; el servidor compara, no coincide y rechaza con **`412 Precondition Failed`**. B debe volver a obtener el recurso, ver el cambio de A y decidir — fusionar, reintentar o exponer el conflicto al usuario. Sin `If-Match`, la escritura de B simplemente sobrescribe la de A y nadie se entera de nada. Notá la distinción con `409`: `412` dice "tu precondición era falsa"; `409` dice "el estado del recurso prohíbe esto independientemente de las precondiciones".

### Bloque 5 — Ausencia de estado

**1.** Viola el **factor VI, los procesos son sin estado y no comparten nada** — el carrito vivía en el heap de un proceso, así que existía para exactamente una de las dos réplicas. Las sesiones pegajosas parecen arreglarlo y te cuestan justo aquello por lo que escalaste: durante un despliegue progresivo cada pod que termina se lleva sus sesiones, así que una fracción de los usuarios pierde su carrito en *cada despliegue*; el balanceador ya no puede balancear, así que una instancia caliente no puede aliviarse; el autoescalado hacia adentro solo ayuda a las instancias sin sesiones; y ya no podés drenar un nodo para mantenimiento sin pérdida visible para el usuario. Cambiaste un problema de enrutamiento por un problema de despliegue, que es el peor de los dos porque se repite en cada release.

**2.** El atacante **puede leer todo el contenido** — es base64, no cifrado — y puede decodificarlo offline con toda tranquilidad. El atacante **no puede modificarlo sin ser detectado**, porque cualquier cambio en el cuerpo invalida el HMAC y `unseal` lanza una excepción. Por lo tanto la cookie nunca debe contener nada confidencial: ni direcciones de correo, ni identificadores internos de usuario que trates como secretos, ni datos de derechos que no imprimirías en una postal, y sobre todo ninguna credencial o token para otros sistemas. Los SKU del carrito están bien. Si necesitás confidencialidad además de integridad, necesitás cifrado autenticado, no una firma.

**3.** **Redis gana de forma contundente en revocación.** Un almacén de sesiones del lado del servidor convierte la revocación en un único `DEL` — la sesión desaparece en la próxima petición, en todas partes, de inmediato. Eso importa para el cierre de sesión en todos los dispositivos, para un cambio de contraseña, para una cuenta que acabás de descubrir comprometida. La cookie firmada es autocontenida precisamente para que no haga falta consultar al servidor, que es la misma razón por la que el servidor no puede desemitirla. Las compensaciones son todas parciales: tiempos de expiración cortos más refresco (achica la ventana pero no la cierra, y agrega un endpoint de refresco que es en sí mismo una consulta del lado del servidor), un claim `jti` verificado contra una lista de denegación (que reintroduce el almacén compartido que estabas evitando, aunque solo para la minoría revocada), o una `token_version` por usuario incrementada al revocar (una consulta barata, granularidad más gruesa). Elegí el intercambio deliberadamente; no finjas que la ventana no existe.

**4.** Un directorio local de subidas es estado que (a) no se replica a las demás instancias, así que una subida escrita por la réplica A devuelve 404 cuando la siguiente petición aterriza en la réplica B; (b) no sobrevive al reemplazo del contenedor, así que cada despliegue pierde archivos; y (c) vuelve las instancias no intercambiables, que es la definición del problema. La respuesta de los doce factores es el **factor IV, tratar los servicios de respaldo como recursos adjuntos**: almacenamiento de objetos (compatible con S3) o un sistema de archivos de red montado, direccionado por una URL en el entorno, de modo que cualquier instancia alcance los mismos bytes y destruir una instancia no destruya nada. El sistema de archivos local solo puede usarse como espacio temporal dentro de una única petición.

### Bloque 6 — Acoplamiento débil

**1.** Cada petición a la dependencia lenta ocupa un worker durante toda su duración. Sin timeout, esa duración no tiene cota. Las peticiones nuevas llegan al ritmo normal, cada una toma un worker y nunca lo devuelve, así que el pool se vacía al ritmo de llegada; una vez que todos los workers están parados en una lectura de socket, las peticiones se encolan en el backlog de accept, la latencia sube hasta el límite de la cola, y después la cola de escucha se desborda o el propio endpoint de health check no puede servirse — momento en el cual el balanceador marca la instancia como no saludable y desplaza su tráfico a las demás instancias, que ya están fallando de la misma manera. Todo el servicio está caído por una dependencia que solo estaba lenta y — la parte cruel — la dependencia pudo haber estado lenta solo en un endpoint que importaba al 2 % del tráfico.

**2.** C recibe **9** peticiones por cada petición original del cliente: A hace 3 intentos hacia B, y cada intento de B hace 3 hacia C. La fórmula general para n capas encadenadas con r intentos cada una es **rⁿ⁻¹** peticiones en la capa más profunda por petición original (contando los intentos como total de pruebas, así que "2 reintentos" significa r = 3). Esto es amplificación de reintentos, y es la razón por la que un servicio con problemas recibe golpes *más fuertes* en cuanto empieza a fallar — la carga se multiplica exactamente cuando cae la capacidad. Las dos mitigaciones: **reintentar en una sola capa** (normalmente la más externa, la más cercana al cliente, con las capas internas fallando rápido y propagando), y **backoff exponencial con jitter completo** para que los reintentos se dispersen en el tiempo en lugar de llegar como una manada sincronizada. Un presupuesto de reintentos — limitar los reintentos a un porcentaje del total de peticiones — es el tercero, de grado productivo.

**3.** Se benefician dos partes. **El llamante** deja de quemar un worker, una conexión y 1 s de latencia por petición en un resultado que ya puede predecir, así que se mantiene saludable y sirve rápido la respuesta degradada. **La dependencia** tiene una oportunidad de recuperarse: un servicio que colapsa bajo carga no puede drenar sus colas si los llamantes mantienen la presión, y el circuito abierto elimina esa presión por completo. Bajar el timeout a 0,1 s ayuda solo a la primera parte y perjudica a la segunda — seguís mandando todas las peticiones, seguís consumiendo la cola de accept y el pool de hilos de la dependencia, y ahora además fallás peticiones que la dependencia podría haber servido en 0,15 s. El breaker distingue "esta llamada está lenta" de "esta dependencia está caída", cosa que un timeout no puede.

**4.** Obtenés una estampida de recuperación. Durante el enfriamiento, las peticiones aguas arriba estuvieron encolándose, reintentando y acumulándose; soltarlas todas de golpe golpea a una dependencia que recién volvió con cachés frías, pools de conexiones vacíos y JIT sin calentar — así que falla otra vez de inmediato, el circuito se reabre y oscilás. El diseño de sonda única de `half-open` hace que el costo de equivocarse sea exactamente una petición: si falla, vuelta a abierto sin daño; si tiene éxito, cerrar y continuar. Las implementaciones de producción normalmente hacen una rampa en lugar de saltar directo al tráfico completo.

**5.** Orders publica un mensaje `order.placed` y le responde al cliente de inmediato; Pricing lo consume a su propio ritmo y publica `order.priced`, que Orders consume para actualizar el registro. **Ganado:** desacoplamiento temporal — Pricing puede estar caído una hora, reiniciarse o escalar a cero, y los pedidos se siguen aceptando, con el broker absorbiendo la acumulación; los dos servicios ya no comparten destino, y podés agregar un segundo consumidor de `order.placed` sin tocar Orders. **Perdido:** la respuesta síncrona. No se le puede mostrar el precio al cliente en la respuesta, así que la UI debe manejar un estado pendiente; el sistema pasa a ser eventualmente consistente, así que "el pedido existe pero todavía no tiene precio" es ahora un estado real que hay que modelar, mostrar y monitorear; la entrega es al-menos-una-vez, así que cada consumidor debe ser idempotente; y depurar se vuelve más difícil porque la cadena causal ya no es un solo stack trace. También agregaste el broker como una nueva dependencia operativa.

### Bloque 7 — Almacenamiento de datos

**1.** La restricción verifica el *valor que se escribe*, y todos los valores escritos en el paso 3 eran legales. Veinte hilos leyeron cada uno `on_hand = 5`, cada uno concluyó `5 >= 1`, y cada uno escribió `4` — un número perfectamente válido que satisface la restricción. Diecinueve de esas escrituras son **actualizaciones perdidas**: se sobrescribieron entre sí, y la base de datos no tiene forma de saber que ese `4` se calculó a partir de un `5` que ya estaba viejo cuando se escribió. Esta es la lección central: las restricciones validan estados, no serializan operaciones. La lectura y la escritura fueron dos transacciones separadas con un hueco desprotegido entre ellas, y acá la corrección dependía de que ese hueco no existiera. El decremento debe expresarse como una única operación atómica, o la lectura debe tomar un lock que la escritura todavía sostenga.

**2.** La sentencia es segura porque **la lectura y la escritura ocurren atómicamente dentro de una sola sentencia**: `on_hand = on_hand - 1 WHERE ... AND on_hand >= 1` evalúa el predicado y aplica el decremento bajo el lock de fila que el propio `UPDATE` toma, así que ninguna otra transacción puede observar ni modificar la fila en el medio. `rowcount` te dice entonces con veracidad si conseguiste una unidad. El equivalente en PostgreSQL cuando la lógica es demasiado compleja para una sola sentencia es **`SELECT ... FOR UPDATE`**: tomar el lock de fila en el momento de la lectura y sostenerlo hasta la escritura dentro de una transacción, de modo que los vendedores concurrentes se bloqueen en lugar de competir. (`SELECT ... FOR UPDATE SKIP LOCKED` es el modismo relacionado para cargas de trabajo tipo cola, donde querés la siguiente fila *disponible* en lugar de esperar.)

**3.** (a) **Una actualización condicional / atómica en el propio almacén de documentos** — el `findAndModify` de MongoDB con un predicado sobre el campo de stock, o una escritura condicional de DynamoDB, o un compare-and-set a nivel de documento sobre un campo de versión. Costo: funciona solo por documento, así que el invariante debe ser expresable dentro de un documento; en el momento en que tu regla abarca dos documentos, volviste al punto de partida. (b) **Sacar el invariante fuera del almacén** — una partición de escritor único por SKU (un actor, un consumidor particionado, un lock distribuido), de modo que nunca haya dos operaciones concurrentes para un SKU. Costo: una carga de disponibilidad y complejidad — el servicio de locks pasa a ser una dependencia que puede fallar, y la partición pasa a ser un techo de throughput y un punto caliente. Una tercera respuesta, genuinamente común, es **aceptar la sobreventa y compensar** — reservar de forma optimista, detectar la infracción de manera asíncrona y cancelar o generar un pedido pendiente. Esa es la elección correcta más a menudo de lo que a los ingenieros les gusta admitir, porque el costo de negocio de una sobreventa rara suele ser muchísimo menor que el costo de disponibilidad de una serialización estricta. El punto es que debe ser una decisión, no un accidente.

**4.** Cuando la existencia del documento debe ser **transaccionalmente idéntica** a la de la fila, y el volumen es pequeño. Un registro firmado con relevancia fiscal, donde "la fila de la factura existe pero el PDF no" es un incumplimiento normativo y no un reintento, es el caso canónico: el `BLOB` te da commit o rollback para ambos en una sola transacción, mientras que fila más clave de objeto te deja una ventana en la que uno existe sin el otro y exige un outbox o un job de reconciliación para cerrarla. A bajo volumen, los argumentos de IOPS y backup simplemente no muerden. El umbral es aproximadamente cuando el volumen total de blobs empieza a dominar el tiempo de backup o el RTO de restauración — momento en el cual pasás a almacenamiento de objetos y pagás la reconciliación.

**5.** **Se puede cachear:** la descripción del producto, el nombre, las imágenes, la categoría — datos que cambian rara vez y cuya desactualización no cuesta nada. **No se debe cachear para la decisión:** el nivel de stock usado para decidir si una venta puede proceder; esa lectura debe venir del almacén autoritativo dentro de la misma operación atómica que la escritura, que es exactamente lo que hace la sentencia `cas`. "Cachear el nivel de stock durante 5 segundos" suena prudente y es peligroso porque reintroduce el hueco read-modify-write del paso 3 con un ancho *garantizado* de 5 segundos en lugar de uno azaroso de 10 milisegundos — institucionalizaste el bug. La versión viable es cachear un nivel de stock de *visualización* ("en stock" / "poco stock") para la página del catálogo, claramente separado del camino autoritativo de decremento, y aceptar que la página puede decir "en stock" para un artículo que se agota un segundo después. Todo sistema real de comercio electrónico hace exactamente esto, y por eso es en el checkout, y no en la página del producto, donde te enterás.

### Bloque 8 — Seguridad de aplicaciones

**1.** Con parámetros ligados, la sentencia SQL se envía a la base de datos **por separado de los valores**, y la sentencia se parsea y planifica antes de que se adjunte ningún valor. No queda ningún paso de parseo en el que un valor pudiera volverse sintaxis — `' OR '1'='1` llega como una cadena de 12 caracteres para comparar contra `name`, y no coincide con ninguna fila. El escapado intenta lograr el mismo resultado *transformando el valor para que el parser no lo malinterprete*, lo que significa que la función de escapado debe modelar el parser exactamente: cada modo de comillas, cada conjunto de caracteres (el fallo clásico es una codificación multibyte en la que una secuencia preparada se come la barra invertida del escapado), cada dialecto de SQL, cada versión. Una sola discrepancia y la garantía desaparece. "Uso parámetros ligados" es una afirmación estructural sobre dónde está el límite; "escapo las comillas" es una afirmación de que tu función de cadenas y el parser de la base de datos coinciden en todo, para siempre.

**2.** Sí, `%s` en esa forma es un marcador de parámetro ligado que se pasa al driver, no formateo de cadenas de Python — el driver lo parametriza. Se vuelve inseguro en el momento en que alguien escribe `.raw(f"SELECT ... WHERE name = '{name}'")` o `.raw("SELECT ... WHERE name = %s" % name)`, que se ven casi idénticos en un diff y son exactamente el bug. También es inseguro para las partes de una sentencia que **no** pueden parametrizarse — nombres de tablas, nombres de columnas, destinos de `ORDER BY`, `ASC`/`DESC`. Esas deben validarse contra una lista de permitidos de identificadores conocidos y buenos; no hay marcador que te salve ahí, y un `ORDER BY {user_column}` dinámico es un punto de inyección vivo dentro de código por lo demás bien escrito.

**3.** Porque la codificación correcta **depende del contexto en el que aterrizan los datos**, y ese contexto se conoce en el momento de la salida, no en el de la entrada. La misma cadena es segura en un nodo de texto HTML, peligrosa sin comillas en un atributo HTML, necesita escapado de cadena JavaScript dentro de un `<script>`, necesita codificación URL en un parámetro de consulta y necesita escapado CSS en un bloque de estilo. Sanear en la entrada te obliga a adivinar todos los destinos futuros, destroza datos legítimos (un apóstrofo en `O'Brien`, un `<` en una fórmula matemática) y falla en silencio en cuanto alguien agrega una plantilla nueva. Codificá en el sumidero, donde conocés el sumidero. El escapado HTML es **incorrecto** cuando el valor se interpola en un contexto JavaScript — `var q = "<%= html_escape(q) %>"` deja `</script>` y secuencias de barra invertida explotables, y es un bypass bien conocido; ese contexto necesita un codificador de cadenas JavaScript o, mejor, pasar el valor como JSON mediante un atributo de datos. Es igualmente incorrecto para un contexto de URL, donde `&amp;` no es lo que querés. La cabecera CSP es defensa en profundidad para cuando la codificación se pasa por alto en algún lado.

**4.** Ninguno alcanza por sí solo. **`Origin` solo** falla porque está ausente en algunas peticiones legítimas (ciertas navegaciones y clientes antiguos), así que tenés que decidir qué hacer cuando falta — rechazar y romper usuarios reales, o aceptar y perder la defensa; los proxies y gateways también pueden reescribirlo, y los orígenes `null` de contextos en sandbox complican la lista de permitidos. **Un token solo** falla si se filtra — por una URL en un `Referer`, un XSS que lee el DOM, una toma de control de subdominio que lee una cookie con alcance demasiado amplio — o si la comparación del framework es débil. Juntos exigen que un atacante derrote dos mecanismos independientes. **`SameSite=Lax`** es la tercera capa, aplicada por el navegador: el navegador simplemente no adjunta la cookie a los `POST` entre sitios, así que la petición falsificada llega sin autenticar y las comprobaciones del lado del servidor nunca necesitan dispararse. Es la más fuerte de las tres porque no depende de que el código de tu aplicación esté bien — pero depende del navegador del usuario, no protege contra un atacante del mismo sitio (otra aplicación en un subdominio hermano) y no sustituye al token, que es por lo que la respuesta en capas es la correcta.

**5.** `Lax` adjunta la cookie a las **navegaciones `GET` de nivel superior entre sitios** — un clic en un enlace, una redirección, un `window.location`. Así que si alguna operación que cambia estado es alcanzable por `GET`, `SameSite=Lax` no la protege: `<img src="https://shop.example/account/delete">` en la página de un atacante es una petición de nivel casi superior que el navegador va a autenticar sin problema. La regla de diseño es por lo tanto que **`GET` (y `HEAD`) deben ser seguros** — sin efectos secundarios, sin cambio de estado, nunca — y que toda mutación debe usar `POST`, `PUT`, `PATCH` o `DELETE`. Eso proviene de la definición de métodos *seguros* de la semántica HTTP (RFC 9110 §9.2.1), y no es una mera convención: navegadores, proxies, rastreadores, prefetchers de enlaces y aceleradores lo dan todos por supuesto. Un endpoint como `GET /orders/123/cancel` terminará disparado tarde o temprano por un buscador indexando una página, sin ningún atacante involucrado.

**6.** **Configuración de seguridad incorrecta** — más precisamente, salida verbosa de errores y depuración expuesta al llamante (la categoría A05 del OWASP Top 10, con la debilidad subyacente siendo la exposición de información sensible a través de un mensaje de error). Independientemente de si la inyección tiene éxito, el atacante aprende el dialecto exacto de SQL y su comportamiento de comillas, los nombres reales de tablas y columnas, cómo se construye la consulta (la interpolación de cadenas es visible en la forma de la salida) y, por lo tanto, exactamente cómo preparar una carga útil — convirtiendo un ejercicio de sondeo a ciegas en uno dirigido. La misma categoría cubre los stack traces, los banners de versión del framework y los listados de directorios: cada uno individualmente "no es una vulnerabilidad" y en conjunto son el reconocimiento que vuelve barato encontrar la real.

### Bloque 9 — El contrato

**1.** La regla es **"sé conservador en lo que enviás, liberal en lo que aceptás"** aplicada por dirección. Un proveedor puede **agregar un campo opcional a una petición** (los clientes viejos que lo omiten siguen funcionando) pero no puede agregar uno *obligatorio*, ni eliminar o restringir uno existente. Un proveedor puede **agregar un campo a una respuesta** (los clientes viejos ignoran lo que no conocen, siempre que no validen estrictamente) pero no puede eliminar uno, ni cambiar el tipo de un campo, ni quitar un valor de un enum sobre el que un cliente pueda estar ramificando. La asimetría es que **las peticiones se rompen con las adiciones y las respuestas con las eliminaciones**, porque el consumidor construye la petición y consume la respuesta — no podés romper a alguien dándole más de lo que pidió, pero sí exigiéndole más de lo que sabía que tenía que enviar. Agregar un valor a un enum de respuesta es el caso sutil: es una adición, pero rompe a cualquier consumidor con un `match` exhaustivo, y por eso los enums deberían documentarse como abiertos desde el primer día.

**2.** Generar el contrato a partir del código significa que el contrato solo puede describir lo que el código ya hace, así que no puede ser un instrumento de diseño ni un artefacto de negociación — el equipo consumidor no tiene nada que revisar hasta que el proveedor ya lo construyó, y cualquier torpeza de la implementación se convierte en una forma de API publicada. También significa que un cambio accidental en el código se vuelve en silencio un cambio en el contrato; el diff contra la línea base congelada del paso 3 existe precisamente para volver a poner una compuerta en ese camino. Generarlo es, aun así, lo correcto cuando el código es la autoridad más antigua — un servicio existente que se documenta por primera vez, donde una especificación escrita a mano sería de inmediato una segunda fuente de verdad que se desvía. El patrón sano para trabajo nuevo es contrato primero para el diseño, y después generar y diferenciar en CI para demostrar que la implementación sigue coincidiendo.

**3.** Porque el contrato del consumidor es "los campos de los que dependo están presentes y son correctos", no "la respuesta contiene exactamente estos campos". Una aserción de igualdad fallaría en el momento en que el proveedor hiciera una adición legítima y no rompedora — un `created_at` nuevo, una `currency` nueva — convirtiendo cada cambio aditivo en un build rojo en todos los consumidores, lo que entrena a todos a dejar de confiar en las pruebas. La comprobación de subconjunto codifica el acoplamiento real: falla exactamente cuando desaparece algo que el consumidor necesita, y se mantiene en verde en los demás casos. Esa es toda la idea detrás de los contratos dirigidos por el consumidor — cada consumidor publica la porción estrecha que realmente usa, y el proveedor queda libre en todo lo demás.

**4.** **Expandir / migrar / contraer**, a veces llamado cambio paralelo. (1) *Expandir:* desplegar una versión que soporte ambas formas simultáneamente — el campo nuevo es opcional y el viejo se sigue aceptando, o el endpoint nuevo existe junto al viejo; nada se rompió, y esto se despliega independientemente de cada consumidor. (2) *Migrar:* los consumidores pasan a la forma nueva a su propio ritmo, en sus propios ciclos de release, sin ventana de coordinación. (3) *Contraer:* eliminar la forma vieja. El mecanismo que te dice cuándo el paso 3 es seguro es la **telemetría de uso por consumidor sobre el camino obsoleto** — un contador etiquetado por identidad de cliente o clave de API sobre el campo/endpoint viejo, más las cabeceras `Deprecation` y `Sunset` en las respuestas para que los consumidores queden avisados en banda. Lo eliminás cuando el contador estuvo en cero durante más tiempo que el ciclo de release de tu consumidor más lento, y sabés *a quién* perseguir cuando no lo está. Adivinar, o anunciar una fecha y confiar, es la forma en que vuelven los días de la bandera.

**5.** Un cuerpo de error estándar (RFC 9457, *Problem Details*) significa que el cliente puede escribir **un** manejador de errores en vez de uno por endpoint por servicio. Obtiene una URI `type` estable y legible por máquina sobre la que ramificar — distinguiendo "stock insuficiente" de "SKU inválido" sin hacer coincidencia de cadenas sobre un mensaje humano que va a reescribirse o traducirse —, un `status` que sobrevive a los proxies que reescriben la línea de respuesta, y un lugar documentado (`detail`, más miembros de extensión) para los detalles. Con `{"error": "..."}` el cliente solo tiene prosa: ramificar sobre ella es frágil, localizarla es imposible, y cada servicio nuevo inventa una forma distinta, así que la capa de agregación, el SDK y el pipeline de logs necesitan todos casos especiales por servicio. El estándar además zanja las preguntas que los equipos discuten eternamente de otro modo — dónde van los errores de validación a nivel de campo, si hay un identificador para correlacionar con los logs.

### Bloque 10 — Inmutabilidad y desechabilidad

**1.** `podman restart` detiene y arranca **el mismo contenedor** — la misma capa escribible sobre la imagen — así que los cambios en el sistema de archivos persisten. `podman rm` seguido de `podman run` crea un **contenedor nuevo** con una capa escribible fresca derivada solo de la imagen, así que el cambio desaparece. Esto es más peligroso que la pérdida inmediata porque crea un **sobreviviente**: el parche funciona, sobrevive a los reinicios, sobrevive al reinicio del host, y por lo tanto deja de parecer una medida temporal. Desaparece en el próximo despliegue, el próximo drenaje de nodo, el próximo evento de autoescalado, o en una réplica y no en las otras — así que el síntoma es una regresión intermitente que no se correlaciona con nada en tu registro de cambios, y el arreglo que "seguro se aplicó" no está en ningún lado en git. La pérdida inmediata habría sido retroalimentación honesta.

**2.** (a) **No podés saber qué está corriendo.** `orders:latest` en dos nodos puede ser dos imágenes distintas, porque cada uno hizo pull en un momento distinto; `podman images` muestra la misma etiqueta y los digests difieren. Depurar un incidente de producción arranca entonces con una pregunta incontestable. (b) **El rollback no tiene destino.** Hacer rollback significa desplegar el artefacto anterior, y con una etiqueta móvil el artefacto anterior no tiene nombre — existe solo como un digest que habrías tenido que registrar por separado, y puede que ya haya sido recolectado como basura del registro. (c) **Los despliegues se vuelven no deterministas e irreproducibles.** Un pod reprogramado a las 03:00 con `imagePullPolicy: Always` toma en silencio lo que sea que `latest` signifique en ese momento, así que un fallo de nodo se convierte en un despliegue no planificado; y volver a ejecutar el mismo manifiesto dos veces puede producir dos sistemas distintos, lo que destruye la propiedad que hace funcionar a la infraestructura declarativa. Una etiqueta con SHA (o mejor, una referencia por digest) hace que cada una de estas preguntas se responda por inspección.

**3.** Porque invierte la procedencia: el contenido de la imagen resultante se explica por una secuencia de comandos interactivos que nadie registró, no por un Containerfile en control de versiones. No podés diferenciarla, ni revisarla, ni reconstruirla desde el código fuente, ni saber si el binario parcheado corresponde a algún commit, ni reproducirla después de que un CVE en la imagen base fuerce una reconstrucción — momento en el cual el parche manual se pierde en silencio o debe reconstruirse por ingeniería inversa a partir de un proceso en ejecución. También tiende a hornear cualquier estado de ejecución presente en el momento de la instantánea: archivos temporales, una caché poblada, credenciales escritas por un paso de inicialización, el propio hostname del contenedor. El uso legítimo es la **forense**: tomar una instantánea de un contenedor que se comporta mal para diseccionarlo offline mientras el orquestador lo reemplaza — un artefacto para investigar, explícitamente nunca para desplegar.

**4.** Uvicorn drenó la petición en vuelo, pero el cero downtime exige además que **no se enrute ninguna petición nueva al proceso después de que empieza a apagarse**, y eso no es algo que el proceso pueda arreglar solo. El orquestador debe (a) quitar el pod de la lista de endpoints del balanceador *antes o al mismo tiempo* que le envía `SIGTERM`, (b) permitir un período de gracia `preStop` lo bastante largo para que esa eliminación se propague a todos los proxies — la propagación de endpoints es asíncrona, y un pod que deja de aceptar conexiones antes de que el último proxy se haya actualizado produce exactamente los errores de conexión rechazada que intentabas evitar — y (c) fijar `terminationGracePeriodSeconds` por encima de la petición legítima más larga de la aplicación, o el drenaje queda cortado por `SIGKILL`. La señal de la que depende es la **sonda de readiness**: readiness, no liveness, controla la pertenencia a los endpoints, así que un contenedor que falla readiness se saca de servicio mientras sigue corriendo y termina su trabajo en vuelo. Confundir las dos — usar liveness para señalar "estoy drenando" — hace que el pod muera en lugar de drenarse.

**5.** Sostiene el **factor VI (procesos sin estado que no comparten nada)** y, junto con la imagen etiquetada por SHA, el **factor V** — el contenedor en ejecución es idéntico byte a byte al artefacto, sin divergencia escribible. Para volver el sistema de archivos de solo lectura (`readOnlyRootFilesystem: true`) tenés que darle al proceso un `emptyDir`/`tmpfs` escribible para cada ruta que realmente necesite: `/tmp` (Python escribe ahí, y muchas bibliotecas también), cualquier directorio de caché que use el framework o el gestor de dependencias, y la ruta del socket Unix si usás uno. También tenés que asegurarte de que nada escriba en el directorio de la aplicación en tiempo de ejecución — nada de generación de `.pyc` dentro de `/srv/app` (fijá `PYTHONDONTWRITEBYTECODE=1`, o precompilá en tiempo de build), nada de archivos de log, nada de archivos PID. Los logs van a stdout, que es el factor XI y acá no te cuesta nada.

**6.** Es aceptable en el laboratorio porque el ejercicio trata sobre la inmutabilidad de la imagen y el límite de la configuración, y una base SQLite respaldada por un archivo reduce las piezas móviles a una. Destruye **la desechabilidad del proceso**, y con ella todo lo que de eso depende: los datos viven en la capa escribible del contenedor, así que desaparecen cuando el contenedor se reemplaza — lo que, según el paso 5, es lo que hace cada despliegue, cada drenaje de nodo y cada reprogramación. Dos réplicas tendrían dos bases de datos divergentes sin reconciliación, así que el servicio no se puede escalar en absoluto. La forma correcta es el factor IV: la base de datos es un **servicio de respaldo adjunto**, alcanzable en una URL suministrada por el entorno, cuyo ciclo de vida es completamente independiente de cualquier instancia de la aplicación, de modo que destruir una instancia no destruya nada más que la instancia.

</details>

---

## Fuentes

- LPI, *Exam 701 Objectives (DevOps Tools Engineer)* — <https://www.lpi.org/our-certifications/exam-701-objectives/>
- Adam Wiggins et al., *The Twelve-Factor App* — <https://12factor.net/>
- IETF RFC 9110, *HTTP Semantics* (métodos, códigos de estado, peticiones condicionales, métodos seguros e idempotentes) — <https://www.rfc-editor.org/rfc/rfc9110.html>
- IETF RFC 9111, *HTTP Caching* (`Cache-Control`, frescura, validadores, `Vary`) — <https://www.rfc-editor.org/rfc/rfc9111.html>
- IETF RFC 9457, *Problem Details for HTTP APIs* — <https://www.rfc-editor.org/rfc/rfc9457.html>
- IETF RFC 6265bis / atributo de cookie `SameSite` — <https://datatracker.ietf.org/doc/html/draft-ietf-httpbis-rfc6265bis>
- IETF, *The Idempotency-Key HTTP Header Field* — un Internet-Draft, todavía no un estándar; la cabecera está ampliamente desplegada pero no especificada normativamente — <https://datatracker.ietf.org/doc/draft-ietf-httpapi-idempotency-key-header/>
- OpenAPI Initiative, *OpenAPI Specification 3.1.0* — <https://spec.openapis.org/oas/v3.1.0.html>
- OWASP, *Top 10 Web Application Security Risks* — <https://owasp.org/www-project-top-ten/>
- OWASP, *Cross-Site Scripting Prevention Cheat Sheet* — <https://cheatsheetseries.owasp.org/cheatsheets/Cross_Site_Scripting_Prevention_Cheat_Sheet.html>
- OWASP, *Cross-Site Request Forgery Prevention Cheat Sheet* — <https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html>
- OWASP, *SQL Injection Prevention Cheat Sheet* — <https://cheatsheetseries.owasp.org/cheatsheets/SQL_Injection_Prevention_Cheat_Sheet.html>
- SQLite, *Transaction control* (`BEGIN IMMEDIATE`, WAL) — <https://www.sqlite.org/lang_transaction.html>
- PostgreSQL, *Explicit Locking / `SELECT ... FOR UPDATE`* — <https://www.postgresql.org/docs/current/explicit-locking.html>
- Kubernetes, *Pod Lifecycle — termination and readiness* — <https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/>
- Documentación de FastAPI — <https://fastapi.tiangolo.com/>
- Documentación de despliegue de Uvicorn (manejo de señales y apagado ordenado) — <https://www.uvicorn.org/deployment/>