# Topic 701.1: Modern Software Development — Ejercicios de Laboratorio Guiados de Nivel de Producción

## 1. Visión General y Referencias Oficiales

La certificación **LPI DevOps Tools Engineer (701-100, Versión 1.0)** evalúa la capacidad de un candidato para conectar las prácticas de ingeniería de software con las arquitecturas de infraestructura modernas. El **Topic 701.1: Modern Software Development** evalúa tu dominio técnico de las arquitecturas orientadas a servicios y microservicios, los principios de aplicaciones 12-Factor, los estándares de diseño de APIs RESTful, la gestión de estado y sesiones, los compromisos (trade-offs) de sistemas distribuidos (teorema CAP, ACID vs. BASE), las mitigaciones de seguridad en aplicaciones (OWASP Top 10) y los patrones de preparación operativa (desechabilidad/disposability, escalado dinámico, logging estructurado y health probing).

### Referencias Oficiales
*   **LPI DevOps Tools Engineer Overview:** [https://www.lpi.org/our-certifications/devops-tools-engineer-overview/](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
*   **LPI Wiki Exam 701 Objectives:** [https://wiki.lpi.org/wiki/DevOps_Tools_Engineer_Objectives_V1](https://wiki.lpi.org/wiki/DevOps_Tools_Engineer_Objectives_V1)
*   **The Twelve-Factor App Methodology:** [https://12factor.net/](https://12factor.net/)
*   **NIST Special Publication 800-204 (Microservices Security):** [https://csrc.nist.gov/publications/detail/sp/800-204/final](https://csrc.nist.gov/publications/detail/sp/800-204/final)

---

## 2. Requisitos Previos del Sistema y Configuración del Entorno

Antes de comenzar los ejercicios, asegurate de que tu entorno Linux tenga instalados Docker, Docker Compose, `curl`, `jq` y las herramientas estándar de depuración (`iproute2`, `procps`, `wrk`).

```bash
# Verify environment readiness
docker --version
docker compose version
curl --version
jq --version
```

Salida esperada:
```text
Docker version 24.0.7, build afdd53b
Docker Compose version v2.21.0
curl 8.5.0 (x86_64-pc-linux-gnu) libcurl/8.5.0
jq-1.7
```

---

## 3. Ejercicio Guiado 1: Microservicios Cloud-Native Stateless y Mecánica de los 12-Factor

### Objetivos
*   Construir un microservicio REST stateless adhiriéndose a los principios 12-Factor.
*   Implementar aislamiento explícito de dependencias, externalización de configuración impulsada por el entorno y logging de streams de eventos.
*   Configurar la desechabilidad (disposability) de procesos y el manejo de señales del kernel (`SIGTERM` vs `SIGKILL`) para rolling updates sin tiempo de inactividad (zero-downtime).
*   Construir una compilación multi-stage de Docker segura utilizando runtimes sin privilegios de root y un wrapper de init en PID 1 (`tini`).

---

### Paso 1: Escribir el Código de la Aplicación Python/FastAPI Siguiendo los 12-Factor

Crear un directorio llamado `lab1-stateless-service` y crear `app.py`:

```bash
mkdir -p lab1-stateless-service && cd lab1-stateless-service
```

Crear `app.py`:

```python
import os
import signal
import sys
import time
import logging
from typing import Dict
from fastapi import FastAPI, Response, status

# 12-Factor Factor XI: Logs as event streams
logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO").upper(),
    format='{"timestamp":"%(asctime)s", "level":"%(levelname)s", "service":"orders-api", "message":"%(message)s"}',
    handlers=[logging.StreamHandler(sys.stdout)]
)
logger = logging.getLogger("orders-api")

app = FastAPI(title="Orders Microservice", version="1.0.0")

# 12-Factor Factor III: Config in the environment
DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://app:secret@localhost:5432/orders_db")
MAX_CONNECTIONS = int(os.getenv("MAX_CONNECTIONS", "20"))
IS_SHUTTING_DOWN = False

@app.get("/healthz/liveness", status_code=status.HTTP_200_OK)
def liveness_probe() -> Dict[str, str]:
    if IS_SHUTTING_DOWN:
        return Response(content='{"status":"DRAINING"}', status_code=status.HTTP_503_SERVICE_UNAVAILABLE, media_type="application/json")
    return {"status": "ALIVE"}

@app.get("/healthz/readiness", status_code=status.HTTP_200_OK)
def readiness_probe(response: Response) -> Dict[str, str]:
    if IS_SHUTTING_DOWN:
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
        return {"status": "NOT_READY", "reason": "Process is terminating"}
    return {"status": "READY", "db_connected": "true"}

@app.post("/api/v1/orders", status_code=status.HTTP_201_CREATED)
def create_order(order: dict):
    if IS_SHUTTING_DOWN:
        return Response(content='{"error":"Server shutting down"}', status_code=status.HTTP_503_SERVICE_UNAVAILABLE)
    # Simulate processing work
    logger.info(f"Processing order payload: {order}")
    time.sleep(0.2)
    return {"order_id": "ord-99823", "status": "processed"}

def graceful_shutdown_handler(signum, frame):
    global IS_SHUTTING_DOWN
    logger.warning(f"Received kernel signal {signal.Signals(signum).name}. Initiating 12-Factor graceful shutdown...")
    IS_SHUTTING_DOWN = True
    
    # Simulate active HTTP request draining and database connection pool teardown
    logger.info("Draining inflight HTTP requests (simulated 3-second grace period)...")
    time.sleep(3)
    logger.info("Database connection pools closed cleanly. Process exiting with code 0.")
    sys.exit(0)

# Register POSIX signal handlers
signal.signal(signal.SIGTERM, graceful_shutdown_handler)
signal.signal(signal.SIGINT, graceful_shutdown_handler)
```

Crear `requirements.txt`:
```text
fastapi==0.110.0
uvicorn==0.28.0
gunicorn==21.2.0
```

---

### Paso 2: Construir el Dockerfile/OCI Multi-Stage con Envoltorio de Señales para Init

Crear `Dockerfile`:

```dockerfile
# Stage 1: Build & Dependency Isolation
FROM python:3.11-slim AS builder

WORKDIR /build

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# Stage 2: Hardened Runtime Environment
FROM python:3.11-slim AS runner

WORKDIR /app

# Install tini init process to handle PID 1 signal forwarding & zombie reaping
RUN apt-get update && apt-get install -y --no-install-recommends \
    tini \
    && rm -rf /var/lib/apt/lists/*

# Copy installed dependencies from builder
COPY --from=builder /install /usr/local
COPY app.py .

# Create non-privileged system user/group (Least Privilege Principle)
RUN groupadd -g 10001 appgroup && \
    useradd -u 10001 -g appgroup -s /sbin/nologin appuser && \
    chown -R appuser:appgroup /app

USER 10001:10001

EXPOSE 8080

# Use tini to correctly forward SIGTERM signals to Gunicorn/Uvicorn workers
ENTRYPOINT ["/usr/bin/tini", "--"]

CMD ["gunicorn", "-w", "2", "-k", "uvicorn.workers.UvicornWorker", "-b", "0.0.0.0:8080", "app:app"]
```

---

### Paso 3: Construir, Ejecutar e Inspeccionar la Captura de Señales y la Desechabilidad (Disposability)

Ejecutar los siguientes comandos en tu shell:

```bash
# 1. Build the OCI container image
docker build -t orders-api:v1.0.0 .

# 2. Run the container with custom environment variables
docker run -d \
  --name orders-service-container \
  -p 8080:8080 \
  -e LOG_LEVEL=DEBUG \
  -e MAX_CONNECTIONS=50 \
  orders-api:v1.0.0

# 3. Verify process hierarchy inside the container (Verify PID 1 is tini)
docker exec orders-service-container ps aux
```

Salida esperada en la CLI:
```text
USER         PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
10001          1  0.0  0.0   2480  1632 ?        Ss   04:40   0:00 /usr/bin/tini -- gunicorn -w 2 -k uvicorn.workers.UvicornWorker -b 0.0.0.0:8080 app:app
10001          7  0.3  1.2  54312 25890 ?        S    04:40   0:00 python /usr/local/bin/gunicorn -w 2 -k uvicorn.workers.UvicornWorker -b 0.0.0.0:8080 app:app
10001          8  0.8  1.8 184320 37412 ?        Sl   04:40   0:00 python /usr/local/bin/gunicorn -w 2 -k uvicorn.workers.UvicornWorker -b 0.0.0.0:8080 app:app
10001          9  0.8  1.8 184320 37420 ?        Sl   04:40   0:00 python /usr/local/bin/gunicorn -w 2 -k uvicorn.workers.UvicornWorker -b 0.0.0.0:8080 app:app
```

Ahora, probar la finalización suave (graceful termination) emitiendo un `docker stop` (el cual envía `SIGTERM` seguido de un tiempo de espera antes de enviar `SIGKILL`):

```bash
# Send SIGTERM via docker stop and stream stdout logs
docker stop --time=10 orders-service-container &
docker logs -f orders-service-container
```

Salida esperada en los logs del contenedor:
```json
{"timestamp":"2026-08-07 04:41:12,102", "level":"WARNING", "service":"orders-api", "message":"Received kernel signal SIGTERM. Initiating 12-Factor graceful shutdown..."}
{"timestamp":"2026-08-07 04:41:12,103", "level":"INFO", "service":"orders-api", "message":"Draining inflight HTTP requests (simulated 3-second grace period)..."}
{"timestamp":"2026-08-07 04:41:15,106", "level":"INFO", "service":"orders-api", "message":"Database connection pools closed cleanly. Process exiting with code 0."}
```

Limpiar el contenedor:
```bash
docker rm orders-service-container
```

---

### Preguntas de Comprensión del Ejercicio 1

1.  **Pregunta 1.1:** ¿Por qué ejecutar un proceso de Python directamente como PID 1 dentro de un contenedor OCI sin un demonio de init como `tini` causa problemas en el manejo de `SIGTERM` y acumula procesos hijo zombi?
2.  **Pregunta 1.2:** Bajo la metodología 12-Factor (Factor III: Configuración y Factor VI: Procesos), ¿por qué almacenar parámetros de configuración dentro de constantes del código base de la aplicación o archivos de configuración empaquetados dentro de la imagen del contenedor se considera un antipatrón arquitectónico para despliegues cloud-native modernos?

---

## 4. Ejercicio Guiado 2: Diseño de API RESTful, Seguridad OAuth2/JWT y Mitigación de Amenazas

### Objetivos
*   Desplegar un API Gateway NGINX que proporcione control de CORS, rate limiting y cabeceras defensivas de seguridad HTTP.
*   Demostrar los mecanismos de vulnerabilidad de microservicios ante amenazas del OWASP Top 10 (Inyección SQL y XSS Almacenado) e implementar estrategias de remediación.
*   Validar la verificación de tokens criptográficos asimétricos (RS256 JWT) para flujos de autorización stateless entre servicios.

---

### Paso 1: Generar Claves Criptográficas y Configurar NGINX API Gateway

Crear el directorio `lab2-api-security`:
```bash
mkdir -p lab2-api-security && cd lab2-api-security
```

Generar un par de claves RSA de 2048 bits para firma y verificación asimétrica de JWT:
```bash
openssl genpkey -algorithm RSA -out jwt_private.pem -pkeyopt rsa_keygen_bits:2048
openssl rsa -pubout -in jwt_private.pem -out jwt_public.pem
```

Crear `nginx-gateway.conf`:

```nginx
events { worker_connections 1024; }

http {
    # Rate Limiting Zone: 10 requests per second per IP
    limit_req_zone $binary_remote_addr zone=api_limit:10m rate=10r/s;

    upstream backend_service {
        server host.docker.internal:8080;
    }

    server {
        listen 80;
        server_name api.company.internal;

        # Hardened HTTP Response Security Headers
        add_header X-Frame-Options "DENY" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-XSS-Protection "1; mode=block" always;
        add_header Content-Security-Policy "default-src 'self';" always;
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

        # CORS Policy Configuration
        add_header 'Access-Control-Allow-Origin' 'https://dashboard.company.com' always;
        add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS, DELETE' always;
        add_header 'Access-Control-Allow-Headers' 'Authorization, Content-Type, X-Requested-With' always;

        location / {
            # Handle Preflight OPTIONS HTTP requests
            if ($request_method = 'OPTIONS') {
                add_header 'Access-Control-Allow-Origin' 'https://dashboard.company.com' always;
                add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS, DELETE' always;
                add_header 'Access-Control-Allow-Headers' 'Authorization, Content-Type, X-Requested-With' always;
                add_header 'Access-Control-Max-Age' 1728000;
                add_header 'Content-Type' 'text/plain; charset=utf-8';
                add_header 'Content-Length' 0;
                return 204;
            }

            # Apply Rate Limiting
            limit_req zone=api_limit burst=5 nodelay;

            proxy_pass http://backend_service;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
    }
}
```

---

### Paso 2: Implementar Endpoints de Microservicios Vulnerables vs. Protegidos (Hardened)

Crear `secure_app.py`:

```python
import sqlite3
import html
import jwt
from typing import Optional
from fastapi import FastAPI, Depends, HTTPException, Header, status
from pydantic import BaseModel, EmailStr

app = FastAPI()

# Load public RSA key for validating asymmetric JWT tokens signed by Auth Server
with open("jwt_public.pem", "rb") as f:
    PUBLIC_KEY = f.read()

# Database Setup (In-Memory SQLite)
def get_db():
    conn = sqlite3.connect(":memory:", check_same_thread=False)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()
    cursor.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT, bio TEXT)")
    cursor.execute("INSERT INTO users (email, bio) VALUES ('admin@company.com', 'System Administrator')")
    cursor.execute("INSERT INTO users (email, bio) VALUES ('user1@company.com', 'Regular User')")
    conn.commit()
    try:
        yield conn
    finally:
        conn.close()

# JWT Verification Dependency
def verify_jwt_token(authorization: Optional[str] = Header(None)) -> dict:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing or invalid Authorization header scheme")
    
    token = authorization.split(" ")[1]
    try:
        payload = jwt.decode(token, PUBLIC_KEY, algorithms=["RS256"], audience="api.company.internal")
        return payload
    except jwt.ExpiredSignatureError:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Token signature expired")
    except jwt.InvalidTokenError as e:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=f"Cryptographic validation failed: {str(e)}")

# VULNERABLE ENDPOINT: Vulnerable to SQL Injection
@app.get("/api/v1/vulnerable/user")
def get_user_vulnerable(email: str, conn: sqlite3.Connection = Depends(get_db)):
    # DANGER: String concatenation allows raw SQL injection attacks
    query = f"SELECT id, email, bio FROM users WHERE email = '{email}'"
    cursor = conn.cursor()
    cursor.execute(query)
    rows = cursor.fetchall()
    return [dict(row) for row in rows]

# HARDENED ENDPOINT: Parameterized Prepared Statements & JWT Protected
@app.get("/api/v1/secure/user")
def get_user_secure(
    email: str, 
    token_claims: dict = Depends(verify_jwt_token), 
    conn: sqlite3.Connection = Depends(get_db)
):
    # Parameterized query prevents SQL syntax alteration
    query = "SELECT id, email, bio FROM users WHERE email = ?"
    cursor = conn.cursor()
    cursor.execute(query, (email,))
    row = cursor.fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="User not found")
    
    user_data = dict(row)
    # Context-aware output encoding to prevent XSS execution in downstream clients
    user_data["bio"] = html.escape(user_data["bio"])
    return {"data": user_data, "requested_by": token_claims["sub"]}
```

---

### Paso 3: Ejecutar la API y Ejecutar Vectores de Amenaza mediante la CLI

1. Instalar PyJWT, Cryptography y FastAPI en tu entorno Python local:
```bash
pip install fastapi uvicorn pyjwt cryptography pydantic
```

2. Iniciar el microservicio de backend:
```bash
uvicorn secure_app:app --host 0.0.0.0 --port 8080 &
```

3. **Vector de Ataque 1: Ejecutar Inyección SQL en el Endpoint Vulnerable**

```bash
# Normal Request
curl -s "http://localhost:8080/api/v1/vulnerable/user?email=admin@company.com" | jq .

# SQL Injection Payload: Tautology bypass to extract all table contents
curl -s "http://localhost:8080/api/v1/vulnerable/user?email=admin@company.com'%20OR%20'1'='1" | jq .
```

Salida esperada en la CLI (Éxito de Inyección SQL en Endpoint Vulnerable):
```json
[
  {
    "id": 1,
    "email": "admin@company.com",
    "bio": "System Administrator"
  },
  {
    "id": 2,
    "email": "user1@company.com",
    "bio": "Regular User"
  }
]
```

4. **Vector de Ataque 2: Intentar Inyección SQL en el Endpoint Seguro (Sin JWT)**

```bash
curl -i "http://localhost:8080/api/v1/secure/user?email=admin@company.com'%20OR%20'1'='1"
```

Salida esperada en la CLI:
```http
HTTP/1.1 401 Unauthorized
date: Fri, 07 Aug 2026 04:45:00 GMT
server: uvicorn
content-length: 63
content-type: application/json

{"detail":"Missing or invalid Authorization header scheme"}
```

5. **Generar un Token JWT Firmado con RS256 Válido y Realizar una Solicitud Autorizada**

Generar un token JWT válido utilizando un script de Python temporal en línea (inline):

```bash
VALID_JWT=$(python3 -c '
import jwt, time
with open("jwt_private.pem", "rb") as f:
    priv_key = f.read()
payload = {
    "sub": "user_id_10928",
    "iss": "https://auth.company.com",
    "aud": "api.company.internal",
    "exp": time.time() + 3600
}
print(jwt.encode(payload, priv_key, algorithm="RS256"))
')

echo "Generated JWT Token: ${VALID_JWT}"

# Execute Secure Request using the Bearer Token
curl -s -H "Authorization: Bearer ${VALID_JWT}" \
  "http://localhost:8080/api/v1/secure/user?email=admin@company.com'%20OR%20'1'='1" | jq .
```

Salida esperada en la CLI (Inyección SQL Neutralizada por Consulta Parametrizada):
```json
{"detail":"User not found"}
```

Finalizar el proceso del backend al terminar las pruebas:
```bash
pkill -f uvicorn
```

---

### Preguntas de Comprensión del Ejercicio 2

1.  **Pregunta 2.1:** ¿Cómo el uso de prepared statements parametrizados (bind variables) previene fundamentalmente los ataques de Inyección SQL en la capa del motor del driver de la base de datos en comparación con la concatenación dinámica de cadenas o la sanitización por regex?
2.  **Pregunta 2.2:** En una arquitectura de microservicios que utiliza OAuth2/JWT para autenticación stateless, ¿cuál es la falla de seguridad arquitectónica de usar cifrado simétrico (`HS256`) frente a pares de claves asimétricas (`RS256`) al verificar firmas a través de múltiples microservicios internos administrados de forma independiente?

---

## 5. Ejercicio Guiado 3: Gestión de Estado, Consistencia de Datos y Mecánica del Teorema CAP

### Objetivos
*   Desacoplar los nodos de cómputo de la aplicación de la persistencia de estado utilizando Redis para una distribución de sesiones efímera y centralizada.
*   Analizar los niveles de aislamiento de transacciones en bases de datos relacionales (ACID) frente a los paradigmas de consistencia eventual BASE.
*   Simular una partición de red en una configuración de almacenamiento de datos multinodo para evaluar los compromisos (trade-offs) dictados por el Teorema CAP y el modelo PACELC.

---

### Paso 1: Desplegar un Cluster de Aplicaciones Stateless Respaldado por Redis y PostgreSQL

Crear el directorio `lab3-state-cap`:
```bash
mkdir -p lab3-state-cap && cd lab3-state-cap
```

Crear `docker-compose.yml`:

```yaml
version: '3.8'

services:
  redis-session-store:
    image: redis:7.2-alpine
    container_name: redis-session-store
    ports:
      - "6379:6379"
    command: redis-server --requirepass RedisSessionSecretKey --save ""

  postgres-db:
    image: postgres:16-alpine
    container_name: postgres-db
    environment:
      POSTGRES_USER: app_user
      POSTGRES_PASSWORD: DBPassword123
      POSTGRES_DB: transaction_db
    ports:
      - "5432:5432"
    volumes:
      - pgdata:/var/lib/postgresql/data

volumes:
  pgdata:
```

Iniciar los contenedores de infraestructura:
```bash
docker compose up -d
```

---

### Paso 2: Probar la Externalización de Sesiones Stateless y los Niveles de Aislamiento

Crear `session_txn_demo.py`:

```python
import redis
import psycopg2
import time
import uuid

# Connect to Externalized Session Store (Redis)
r = redis.Redis(host='localhost', port=6379, password='RedisSessionSecretKey', decode_responses=True)

def create_user_session(user_id: str, payload: dict) -> str:
    session_id = str(uuid.uuid4())
    session_key = f"session:{session_id}"
    # Store session data as a hash with a 15-minute TTL (Time-To-Live)
    r.hset(session_key, mapping=payload)
    r.expire(session_key, 900)
    return session_id

def get_session(session_id: str) -> dict:
    return r.hgetall(f"session:{session_id}")

# Demonstrate ACID Isolation Levels in PostgreSQL
def test_acid_isolation():
    conn1 = psycopg2.connect("dbname=transaction_db user=app_user password=DBPassword123 host=localhost")
    conn2 = psycopg2.connect("dbname=transaction_db user=app_user password=DBPassword123 host=localhost")
    
    # Initialize Table
    with conn1.cursor() as cur:
        cur.execute("DROP TABLE IF EXISTS account_balance;")
        cur.execute("CREATE TABLE account_balance (id INT PRIMARY KEY, balance NUMERIC(10, 2));")
        cur.execute("INSERT INTO account_balance VALUES (1, 1000.00);")
    conn1.commit()
    
    print("\n--- Demonstrating READ COMMITTED Isolation Level ---")
    conn1.set_session(isolation_level="READ COMMITTED")
    conn2.set_session(isolation_level="READ COMMITTED")
    
    cur1 = conn1.cursor()
    cur2 = conn2.cursor()
    
    cur1.execute("SELECT balance FROM account_balance WHERE id = 1;")
    print(f"Transaction 1 - Initial Read Balance: ${cur1.fetchone()[0]}")
    
    # Transaction 2 updates row but does NOT commit yet
    cur2.execute("UPDATE account_balance SET balance = 500.00 WHERE id = 1;")
    
    cur1.execute("SELECT balance FROM account_balance WHERE id = 1;")
    print(f"Transaction 1 - Read Balance (T2 uncommitted update): ${cur1.fetchone()[0]}")
    
    # Transaction 2 commits
    conn2.commit()
    
    cur1.execute("SELECT balance FROM account_balance WHERE id = 1;")
    print(f"Transaction 1 - Read Balance (T2 committed update / Non-Repeatable Read): ${cur1.fetchone()[0]}")
    conn1.commit()

if __name__ == "__main__":
    sid = create_user_session("usr_443", {"username": "sre_admin", "role": "operator"})
    print(f"Stored Distributed Session Key in Redis: session:{sid}")
    print(f"Fetched Session Data across Compute Nodes: {get_session(sid)}")
    
    test_acid_isolation()
```

Ejecutar el script de demostración:
```bash
pip install redis psycopg2-binary
python3 session_txn_demo.py
```

Salida esperada en la CLI:
```text
Stored Distributed Session Key in Redis: session:4a8b79e1-2c1b-4d43-9878-3a9d18c1b3f9
Fetched Session Data across Compute Nodes: {'username': 'sre_admin', 'role': 'operator'}

--- Demonstrating READ COMMITTED Isolation Level ---
Transaction 1 - Initial Read Balance: $1000.00
Transaction 1 - Read Balance (T2 uncommitted update): $1000.00
Transaction 1 - Read Balance (T2 committed update / Non-Repeatable Read): $500.00
```

---

### Paso 3: Simular una Partición de Red y la Mecánica del Teorema CAP

1. Comprender la restricción del Teorema CAP: En presencia de una Partición de Red (**P**), un sistema de datos distribuido DEBE elegir entre la Consistencia (**C**) —devolver la escritura más reciente o un error— y la Disponibilidad (**A**) —devolver una respuesta sin error sin garantía de que sea la última escritura.

2. Ejecutar una simulación de Redis Sentinel / Cluster de 3 nodos o inspeccionar el comportamiento del aislamiento de red usando reglas de `iptables` entre subredes de contenedores:

```bash
# Inspect the active docker bridge network to locate node IP addresses
docker inspect postgres-db | jq -r '.[0].NetworkSettings.Networks[].IPAddress'
```

Salida esperada en la CLI:
```text
172.18.0.3
```

Simular la caída de comunicaciones de interfaz de red usando iptables (Requiere permisos de `sudo`):

```bash
# Block TCP traffic from specific container IP to simulate split-brain / network partition
sudo iptables -A INPUT -s 172.18.0.3 -j DROP

# Verify network unreachable state
curl -m 2 http://172.18.0.3:5432 || echo "Network Partition Simulated: Target Host Unreachable"

# Flush iptables rule to restore topology
sudo iptables -D INPUT -s 172.18.0.3 -j DROP
```

Limpiar el entorno de Compose:
```bash
docker compose down -v
```

---

### Preguntas de Comprensión del Ejercicio 3

1.  **Pregunta 3.1:** ¿Cuál es la diferencia entre *Lecturas No Repetibles* (Non-Repeatable Reads, observables en el aislamiento `READ COMMITTED`) y *Lecturas Fantasma* (Phantom Reads, prevenibles bajo aislamiento `SERIALIZABLE`)? ¿Cómo los bloqueos de base de datos o el Control de Concurrencia Multiversión (MVCC) resuelven estas anomalías?
2.  **Pregunta 3.2:** De acuerdo con el **teorema PACELC** (una extensión del teorema CAP), ¿cómo se comporta un almacén de datos distribuido en funcionamiento normal (cuando no existe una partición de red **P**)? Detalla el compromiso (trade-off) especificado por la cláusula **E** (Else).

---

## 6. Ejercicio Guiado 4: Resiliencia Operativa, Concurrencia en Microservicios y Observabilidad

### Objetivos
*   Configurar endpoints de readiness y liveness nativos de Kubernetes con comprobaciones de dependencias.
*   Implementar un patrón Circuit Breaker con estado para proteger microservicios de upstream contra fallas en cascada bajo una alta carga del sistema.
*   Medir cuellos de botella de concurrencia, distribuciones de latencia ($p95$, $p99$) y tasas de falla del servicio utilizando el motor de benchmarking HTTP `wrk`.

---

### Paso 1: Implementar la Mecánica de Circuit Breaker y Health Probes

Crear el directorio `lab4-resilience`:
```bash
mkdir -p lab4-resilience && cd lab4-resilience
```

Crear `resilient_service.py`:

```python
import time
import random
import logging
import sys
from fastapi import FastAPI, HTTPException, Response, status

logging.basicConfig(
    level=logging.INFO,
    format='{"timestamp":"%(asctime)s", "level":"%(levelname)s", "circuit_state":"%(circuit_state)s", "message":"%(message)s"}',
    handlers=[logging.StreamHandler(sys.stdout)]
)
logger = logging.getLogger("resilience-demo")

app = FastAPI()

class CircuitBreakerOpenException(Exception):
    pass

class CircuitBreaker:
    def __init__(self, failure_threshold=3, recovery_timeout=5):
        self.failure_threshold = failure_threshold
        self.recovery_timeout = recovery_timeout
        self.failure_count = 0
        self.state = "CLOSED"  # States: CLOSED (Normal), OPEN (Failing), HALF-OPEN (Testing)
        self.last_state_change = time.time()

    def allow_request(self) -> bool:
        now = time.time()
        if self.state == "OPEN":
            if now - self.last_state_change > self.recovery_timeout:
                self.state = "HALF-OPEN"
                self.last_state_change = now
                logger.info("Circuit transition: OPEN -> HALF-OPEN", extra={"circuit_state": self.state})
                return True
            return False
        return True

    def record_success(self):
        self.failure_count = 0
        if self.state == "HALF-OPEN":
            self.state = "CLOSED"
            self.last_state_change = time.time()
            logger.info("Circuit transition: HALF-OPEN -> CLOSED", extra={"circuit_state": self.state})

    def record_failure(self):
        self.failure_count += 1
        logger.warning(f"Failure recorded. Count = {self.failure_count}/{self.failure_threshold}", extra={"circuit_state": self.state})
        if self.failure_count >= self.failure_threshold:
            self.state = "OPEN"
            self.last_state_change = time.time()
            logger.error("Circuit transition: CLOSED -> OPEN (Tripped)", extra={"circuit_state": self.state})

breaker = CircuitBreaker()

# Flaky External Unreliable Dependency
def call_unreliable_downstream_dependency():
    # Simulate a downstream microservice that fails 70% of the time under load
    if random.random() < 0.7:
        raise Exception("Downstream microservice connection timeout (504)")
    return {"status": "SUCCESS", "payload": "Data from Payment Gateway"}

@app.get("/api/v1/payments")
def process_payment():
    if not breaker.allow_request():
        logger.error("Request rejected by local Circuit Breaker", extra={"circuit_state": breaker.state})
        raise HTTPException(
            status_code=status.HTTP_530_SITE_IS_FROZEN, 
            detail="Circuit breaker is OPEN. Upstream payment service currently unreachable."
        )
    
    try:
        result = call_unreliable_downstream_dependency()
        breaker.record_success()
        return result
    except Exception as e:
        breaker.record_failure()
        raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY, detail=str(e))
```

---

### Paso 2: Ejecutar el Microservicio y Medir Latencia y Resiliencia bajo Carga

1. Iniciar el servicio resiliente usando Uvicorn:
```bash
uvicorn resilient_service:app --host 0.0.0.0 --port 8080 --workers 2 &
```

2. Ejecutar solicitudes HTTP concurrentes usando `wrk` para activar (trip) el circuit breaker y observar las métricas de tasa/estado:

```bash
# Run benchmarking tool: 2 threads, 20 concurrent connections, for 10 seconds
wrk -t2 -c20 -d10s http://localhost:8080/api/v1/payments
```

Salida esperada en la CLI:
```text
Running 10s test @ http://localhost:8080/api/v1/payments
  2 threads and 20 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency    12.45ms   18.32ms 142.10ms   91.12%
    Req/Sec   412.30    120.45   620.00     72.50%
  8140 requests in 10.01s, 2.14MB read
  Non-2xx or 3xx responses: 7921
Requests/sec:    813.18
Transfer/sec:    218.84KB
```

3. Transmitir los logs de stdout de la aplicación en contenedor para observar la lógica de transición del Circuit Breaker:

```bash
# Inspect application log output
curl -s http://localhost:8080/api/v1/payments | jq .
```

Salida esperada:
```json
{
  "detail": "Circuit breaker is OPEN. Upstream payment service currently unreachable."
}
```

Detener el servicio del backend:
```bash
pkill -f uvicorn
```

---

### Preguntas de Comprensión del Ejercicio 4

1.  **Pregunta 4.1:** ¿En qué se diferencian `livenessProbe` y `readinessProbe` de Kubernetes en su comportamiento operativo cuando se trata de un servicio cuyo Circuit Breaker interno se ha activado debido a la degradación de una base de datos downstream? ¿Qué sucede si un arquitecto configura incorrectamente una verificación de dependencia profunda dentro de una `livenessProbe`?
2.  **Pregunta 4.2:** Explica la diferencia arquitectónica entre un *Load Balancer* que opera en la **Capa 4 (Capa de Transporte)** vs. **Capa 7 (Capa de Aplicación)** en términos de connection pooling, terminación TLS, enrutamiento basado en rutas (path-based routing) y utilización de recursos.

---

## 7. Clave de Respuestas de los Ejercicios y Explicaciones Técnicas

<details>
<summary><strong>Haz clic para expandir la clave de respuestas y explicaciones técnicas</strong></summary>

### Clave de Respuestas del Ejercicio 1

*   **Respuesta 1.1:**
    *   **Mecánica Interna:** En Linux, el Process ID 1 (PID 1) es el proceso init, el cual cuenta con reglas únicas de manejo de señales en el kernel. A diferencia de los procesos normales, el PID 1 ignora las acciones predeterminadas estándar del kernel para las señales (como `SIGTERM`) a menos que se registren manejadores de señales explícitos. Si Python/Gunicorn se ejecuta como PID 1 sin un manejador personalizado o un envoltorio de proceso init como `tini`, las señales `SIGTERM` entrantes enviadas por orquestadores de contenedores (`docker stop` o desalojo de pods en Kubernetes) son ignoradas silenciosamente. El orquestador se ve entonces obligado a esperar que expire el período de gracia (por defecto 10s) antes de emitir un `SIGKILL` (`kill -9`) que no se puede capturar, lo que impide el drenado suave de conexiones (graceful connection draining), el cierre de pools de conexiones a bases de datos y la persistencia del estado activo.
    *   **Recolección de Procesos Zombi (Reaping):** Además, cuando los procesos worker hacen fork y posteriormente dejan procesos hijo huérfanos, el PID 1 es responsable de adoptar esos procesos huérfanos y llamar a `waitpid()` para recolectar sus estados de salida. Un runtime de aplicación estándar ejecutándose como PID 1 a menudo carece de un bucle de recolección de init, lo que genera fugas de memoria en el contenedor debido a la acumulación de procesos zombi (`defunct`). `tini` registra el reenvío de señales adecuado y recolecta continuamente los procesos hijo zombi.

*   **Respuesta 1.2:**
    *   **Justificación Arquitectónica:** El Factor III de la metodología 12-Factor App exige la separación completa de la configuración con respecto al código de la aplicación. Almacenar la configuración dentro del código o en artefactos empaquetados en la imagen viola la regla fundamental de la **Infraestructura Inmutable**: exactamente la misma imagen ejecutable de contenedor debe desplegarse en los entornos de Desarrollo, Staging, QA y Producción sin necesidad de reconstrucciones.
    *   **Compromisos de Seguridad y Operaciones:** Incluir configuración de forma fija (hardcoding), como credenciales de bases de datos, secretos de APIs o feature flags dentro de las imágenes, expone a la fuga de credenciales sensibles a través de registros de contenedores. Inyectar la configuración dinámicamente en tiempo de ejecución mediante Variables de Entorno o almacenes de secretos montados garantiza un estricto aislamiento entre entornos, la rotación dinámica de secretos de producción sin reconstruir la imagen y el cumplimiento estricto del Principio de Menor Privilegio (Principle of Least Privilege).

---

### Clave de Respuestas del Ejercicio 2

*   **Respuesta 2.1:**
    *   **Mecanismo a Nivel del Motor:** Cuando se utiliza concatenación dinámica de cadenas directa (`SELECT * FROM users WHERE email = '` + input + `'`), el parser SQL de la base de datos interpreta la cadena de entrada no confiable como parte de la estructura de código ejecutable. Esto permite a los atacantes inyectar palabras clave de sintaxis SQL (por ejemplo, `' OR '1'='1`), alterando el Árbol de Sintaxis Abstracta (AST) construido por el motor de consultas.
    *   **Consultas Parametrizadas / Prepared Statements:** Los prepared statements desacoplan la fase de compilación de la fase de ejecución. La estructura de la consulta SQL se envía primero al motor de la base de datos y se compila en un plan de ejecución con marcadores de posición (`?` o `$1`). Cuando los valores de los parámetros se transmiten posteriormente sobre el protocolo de red, el motor de la base de datos trata strictly esas entradas como valores escalares literales, nunca como tokens SQL ejecutables. Incluso si la entrada contiene `' OR '1'='1`, se interpreta estrictamente como un valor de cadena literal que se compara contra la columna, neutralizando por completo la inyección de código independientemente del contenido de la entrada.

*   **Respuesta 2.2:**
    *   **Riesgo Simétrico (`HS256`):** `HS256` utiliza una única clave secreta compartida tanto para firmar como para verificar tokens JWT. En una malla de microservicios donde el Servicio A emite tokens y los Servicios B, C y D verifican dichos tokens, cada uno de los servicios debe poseer una copia de la clave secreta privada. Si cualquier servicio downstream (por ejemplo, el Servicio D) se ve comprometido, el atacante extrae la clave compartida y puede falsificar tokens administrativos válidos para *cualquier* servicio en toda la arquitectura empresarial.
    *   **Garantía de Seguridad Asimétrica (`RS256`):** `RS256` utiliza un par de claves RSA asimétricas (Clave Privada / Clave Pública). El Proveedor de Identidad / Servicio de Autenticación conserva la Clave Privada para firmar los tokens. Los microservicios downstream solo reciben y almacenan la Clave Pública. Los Servicios B, C y D pueden verificar criptográficamente que el token fue firmado por el Auth Server legítimo, pero incluso si el Servicio D es totalmente comprometido, la clave pública no se puede utilizar para falsificar nuevas firmas.

---

### Clave de Respuestas del Ejercicio 3

*   **Respuesta 3.1:**
    *   **Lecturas No Repetibles (Non-Repeatable Reads):** Ocurre bajo el aislamiento `READ COMMITTED` cuando la Transacción A lee una fila, la Transacción B modifica y confirma (commit) una actualización en esa misma fila, y la Transacción A vuelve a leer la fila, observando datos de columna diferentes dentro del mismo contexto de transacción.
    *   **Lecturas Fantasma (Phantom Reads):** Ocurre cuando la Transacción A ejecuta una consulta de rango (por ejemplo, `SELECT COUNT(*) WHERE age > 30`), la Transacción B inserta una *nueva* fila coincidente y realiza el commit, y la Transacción A reejecuta la consulta de rango, observando nuevas filas "fantasma" que no existían previamente.
    *   **Prevención mediante MVCC y Bloqueos:** Los motores de bases de datos como PostgreSQL utilizan el **Control de Concurrencia Multiversión (MVCC)**. Bajo los niveles de aislamiento `REPEATABLE READ` o `SERIALIZABLE`, PostgreSQL asigna a cada transacción una marca de tiempo de snapshot lógica. La Transacción A solo lee versiones de datos creadas antes de la marca de tiempo de inicio de su transacción. Bajo el aislamiento `SERIALIZABLE`, los motores utilizan **Predicate Locking** o **Aislamiento de Snapshot Serializable (SSI)** para rastrear las dependencias entre transacciones y abortar cualquier transacción que introduzca anomalías de serialización de lectura/escritura.

*   **Respuesta 3.2:**
    *   **Definición de PACELC:** PACELC amplía el teorema CAP para abordar los compromisos durante estados operativos normales (sin particiones de red):
        *   **Si hay Partición (P):** Compromiso entre Disponibilidad (**A**) vs. Consistencia (**C**).
        *   **De lo contrario / Else (E):** Compromiso entre Latencia (**L**) vs. Consistencia (**C**).
    *   **Compromisos del Sistema:** Incluso cuando la red funciona con total normalidad, una base de datos distribuida no puede lograr simultáneamente una baja latencia instantánea y una consistencia fuerte absoluta a través de múltiples nodos. Para garantizar una consistencia fuerte (**C**), una operación de escritura debe replicarse de forma síncrona y esperar la confirmación de un cuórum de nodos réplica antes de devolver una respuesta exitosa al cliente, lo que incrementa la **Latencia (L)** operativa. Si un arquitecto prioriza una **Latencia (L)** ultra baja (por ejemplo, mediante replicación asíncrona en segundo plano), las lecturas realizadas contra las réplicas de lectura pueden devolver datos desactualizados (stale data), sacrificando la consistencia fuerte (**C**) inmediata.

---

### Clave de Respuestas del Ejercicio 4

*   **Respuesta 4.1:**
    *   **Diferencias en el Comportamiento de los Probes:**
        *   `livenessProbe`: Determina si el proceso del contenedor está saludable. Si la liveness probe falla, el orquestador (Kubernetes) **elimina el contenedor y lo reinicia**.
        *   `readinessProbe`: Determina si el contenedor está listo para recibir tráfico de red. Si la readiness probe falla, el orquestador **remueve la IP del pod del balanceador de carga del endpoint del Service**, deteniendo el enrutamiento de tráfico sin reiniciar el proceso.
    *   **Configuración Incorrecta Catastrófica de Liveness:** Si un arquitecto configura una `livenessProbe` para realizar un ping a una base de datos downstream o a un servicio de terceros, y esa dependencia downstream sufre una interrupción, *las liveness probes de cada una de las instancias de la aplicación fallarán simultáneamente*. Kubernetes reaccionará reiniciando todos los pods del cluster en un bucle infinito de caídas (Falla en Cascada / Thundering Herd), empeorando la caída y destruyendo los pools de conexiones activos. Las comprobaciones de salud de dependencias downstream solo deben ser evaluadas en endpoints de `readinessProbe` o enmascararse tras fallbacks de circuit breaker.

*   **Respuesta 4.2:**
    *   **Balanceo de Carga en Capa 4 (Capa de Transporte):** Opera a nivel de protocolo TCP/UDP (por ejemplo, AWS NLB, IPVS). Reenvía paquetes IP puros sin inspeccionar ni finalizar el payload de la aplicación subyacente (HTTP/TLS).
        *   *Pros:* Rendimiento (throughput) extremadamente alto, consumo de CPU mínimo, baja latencia.
        *   *Contras:* No puede inspeccionar cabeceras HTTP, rutas ni cookies; limitado al balanceo por tupla IP/Puerto; no puede realizar offloading TLS ni enrutamiento por rutas HTTP.
    *   **Balanceo de Carga en Capa 7 (Capa de Aplicación):** Opera a nivel del protocolo de Aplicación (por ejemplo, NGINX, HAProxy, Envoy, AWS ALB). Finaliza las conexiones TCP y TLS entrantes, analiza las cabeceras de las solicitudes HTTP/gRPC, las URIs y el cuerpo del payload.
        *   *Pros:* Reglas de enrutamiento avanzadas (por ejemplo, enrutar `/api/v1/orders` al Microservicio A, `/static` a S3), manipulación de cabeceras HTTP, CORS, rate limiting, virtual hosting basado en host y multiplexación inteligente HTTP/2.
        *   *Contras:* Mayor utilización de CPU y memoria debido a la sobrecarga del descifrado TLS y el análisis sintáctico (parsing) HTTP; mayor latencia por solicitud en comparación con el paso de paquetes de L4.

</details>