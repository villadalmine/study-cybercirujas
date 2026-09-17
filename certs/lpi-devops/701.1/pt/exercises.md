# Tópico 701.1: Desenvolvimento Moderno de Software — Exercícios de Laboratório Guiados de Nível de Produção

## 1. Visão Geral e Referências Oficiais

A certificação **LPI DevOps Tools Engineer (701-100, Version 1.0)** avalia a capacidade do candidato de conectar práticas de engenharia de software com arquiteturas modernas de infraestrutura. O **Tópico 701.1: Desenvolvimento Moderno de Software** avalia seu domínio técnico de arquiteturas orientadas a serviços e de microsserviços, os princípios da aplicação 12-Factor, padrões de projeto de APIs RESTful, gerenciamento de estado e de sessão, compensações em sistemas distribuídos (teorema CAP, ACID vs. BASE), mitigações de segurança de aplicações (OWASP Top 10) e padrões de prontidão operacional (descartabilidade, escalabilidade dinâmica, logging estruturado e sondagem de saúde).

### Referências Oficiais
*   **Visão geral do LPI DevOps Tools Engineer:** [https://www.lpi.org/our-certifications/devops-tools-engineer-overview/](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
*   **Objetivos do Exame 701 na LPI Wiki:** [https://wiki.lpi.org/wiki/DevOps_Tools_Engineer_Objectives_V1](https://wiki.lpi.org/wiki/DevOps_Tools_Engineer_Objectives_V1)
*   **Metodologia The Twelve-Factor App:** [https://12factor.net/](https://12factor.net/)
*   **NIST Special Publication 800-204 (Segurança de Microsserviços):** [https://csrc.nist.gov/publications/detail/sp/800-204/final](https://csrc.nist.gov/publications/detail/sp/800-204/final)

---

## 2. Pré-requisitos de Sistema e Preparação do Ambiente

Antes de começar os exercícios, garanta que seu ambiente Linux tenha Docker, Docker Compose, `curl`, `jq` e as ferramentas padrão de depuração (`iproute2`, `procps`, `wrk`) instaladas.

```bash
# Verify environment readiness
docker --version
docker compose version
curl --version
jq --version
```

Saída esperada:
```text
Docker version 24.0.7, build afdd53b
Docker Compose version v2.21.0
curl 8.5.0 (x86_64-pc-linux-gnu) libcurl/8.5.0
jq-1.7
```

---

## 3. Exercício Guiado 1: Microsserviços Stateless Cloud-Native e Mecânica 12-Factor

### Objetivos
*   Construir um microsserviço REST stateless aderente aos princípios 12-Factor.
*   Implementar isolamento explícito de dependências, externalização de configuração dirigida pelo ambiente e logging como fluxo de eventos.
*   Configurar a descartabilidade do processo e o tratamento de sinais do kernel (`SIGTERM` vs `SIGKILL`) para atualizações graduais sem downtime.
*   Construir um build Docker multi-stage seguro, utilizando runtimes não-root e um wrapper de init como PID 1 (`tini`).

---

### Passo 1: Escrever o Código da Aplicação Python/FastAPI 12-Factor

Crie um diretório chamado `lab1-stateless-service` e crie `app.py`:

```bash
mkdir -p lab1-stateless-service && cd lab1-stateless-service
```

Crie `app.py`:

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

Crie `requirements.txt`:
```text
fastapi==0.110.0
uvicorn==0.28.0
gunicorn==21.2.0
```

---

### Passo 2: Construir o Dockerfile/OCI Multi-Stage com Wrapper de Sinais Init

Crie `Dockerfile`:

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

### Passo 3: Construir, Executar e Inspecionar a Captura de Sinais e a Descartabilidade

Execute os seguintes comandos no seu shell:

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

Saída esperada da CLI:
```text
USER         PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
10001          1  0.0  0.0   2480  1632 ?        Ss   04:40   0:00 /usr/bin/tini -- gunicorn -w 2 -k uvicorn.workers.UvicornWorker -b 0.0.0.0:8080 app:app
10001          7  0.3  1.2  54312 25890 ?        S    04:40   0:00 python /usr/local/bin/gunicorn -w 2 -k uvicorn.workers.UvicornWorker -b 0.0.0.0:8080 app:app
10001          8  0.8  1.8 184320 37412 ?        Sl   04:40   0:00 python /usr/local/bin/gunicorn -w 2 -k uvicorn.workers.UvicornWorker -b 0.0.0.0:8080 app:app
10001          9  0.8  1.8 184320 37420 ?        Sl   04:40   0:00 python /usr/local/bin/gunicorn -w 2 -k uvicorn.workers.UvicornWorker -b 0.0.0.0:8080 app:app
```

Agora, teste a terminação graciosa emitindo um `docker stop` (que envia `SIGTERM` seguido de um timeout antes de enviar `SIGKILL`):

```bash
# Send SIGTERM via docker stop and stream stdout logs
docker stop --time=10 orders-service-container &
docker logs -f orders-service-container
```

Saída esperada dos logs do contêiner:
```
{"timestamp":"2026-08-07 04:41:12,102", "level":"WARNING", "service":"orders-api", "message":"Received kernel signal SIGTERM. Initiating 12-Factor graceful shutdown..."}
{"timestamp":"2026-08-07 04:41:12,103", "level":"INFO", "service":"orders-api", "message":"Draining inflight HTTP requests (simulated 3-second grace period)..."}
{"timestamp":"2026-08-07 04:41:15,106", "level":"INFO", "service":"orders-api", "message":"Database connection pools closed cleanly. Process exiting with code 0."}
```

Limpeza do contêiner:
```bash
docker rm orders-service-container
```

---

### Perguntas de Compreensão do Exercício 1

1.  **Pergunta 1.1:** Por que executar um processo Python diretamente como PID 1 dentro de um contêiner OCI, sem um daemon de init como o `tini`, causa problemas no tratamento de `SIGTERM` e acúmulo de processos filhos zumbis?
2.  **Pergunta 1.2:** Sob a metodologia 12-Factor (Fator III: Config e Fator VI: Processes), por que armazenar parâmetros de configuração em constantes do código-fonte da aplicação ou em arquivos de configuração empacotados dentro da imagem do contêiner é considerado um antipadrão arquitetural para implantações cloud-native modernas?

---

## 4. Exercício Guiado 2: Projeto de APIs RESTful, Segurança OAuth2/JWT e Mitigação de Ameaças

### Objetivos
*   Implantar um API Gateway NGINX que forneça controle de CORS, rate limiting e cabeçalhos HTTP defensivos de segurança.
*   Demonstrar mecanismos de vulnerabilidade de microsserviços frente às ameaças do OWASP Top 10 (SQL Injection e Stored XSS) e implementar estratégias de remediação.
*   Validar a verificação criptográfica assimétrica de tokens (JWT RS256) para fluxos stateless de autorização entre serviços.

---

### Passo 1: Gerar Chaves Criptográficas e Configurar o API Gateway NGINX

Crie o diretório `lab2-api-security`:
```bash
mkdir -p lab2-api-security && cd lab2-api-security
```

Gere um par de chaves RSA de 2048 bits para assinatura e verificação assimétrica de JWT:
```bash
openssl genpkey -algorithm RSA -out jwt_private.pem -pkeyopt rsa_keygen_bits:2048
openssl rsa -pubout -in jwt_private.pem -out jwt_public.pem
```

Crie `nginx-gateway.conf`:

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

### Passo 2: Implementar Endpoints de Microsserviço Vulneráveis vs. Endurecidos

Crie `secure_app.py`:

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

### Passo 3: Executar a API e Disparar Vetores de Ameaça pela CLI

1. Instale PyJWT, Cryptography e FastAPI no seu ambiente Python local:
```bash
pip install fastapi uvicorn pyjwt cryptography pydantic
```

2. Inicie o microsserviço de backend:
```bash
uvicorn secure_app:app --host 0.0.0.0 --port 8080 &
```

3. **Vetor de Ataque 1: Executar SQL Injection no Endpoint Vulnerável**

```bash
# Normal Request
curl -s "http://localhost:8080/api/v1/vulnerable/user?email=admin@company.com" | jq .

# SQL Injection Payload: Tautology bypass to extract all table contents
curl -s "http://localhost:8080/api/v1/vulnerable/user?email=admin@company.com'%20OR%20'1'='1" | jq .
```

Saída esperada da CLI (SQL Injection bem-sucedida no endpoint vulnerável):
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

4. **Vetor de Ataque 2: Tentar SQL Injection no Endpoint Seguro (sem JWT)**

```bash
curl -i "http://localhost:8080/api/v1/secure/user?email=admin@company.com'%20OR%20'1'='1"
```

Saída esperada da CLI:
```http
HTTP/1.1 401 Unauthorized
date: Fri, 07 Aug 2026 04:45:00 GMT
server: uvicorn
content-length: 63
content-type: application/json

{"detail":"Missing or invalid Authorization header scheme"}
```

5. **Gerar um Token JWT Válido Assinado com RS256 e Executar uma Requisição Autorizada**

Gere um token JWT válido usando um script Python temporário inline:

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

Saída esperada da CLI (SQL Injection neutralizada pela query parametrizada):
```json
{"detail":"User not found"}
```

Encerre o processo de backend ao terminar os testes:
```bash
pkill -f uvicorn
```

---

### Perguntas de Compreensão do Exercício 2

1.  **Pergunta 2.1:** Como o uso de prepared statements parametrizados (bind variables) previne fundamentalmente ataques de SQL Injection na camada do motor do driver de banco de dados, em comparação com concatenação dinâmica de strings ou sanitização por regex?
2.  **Pergunta 2.2:** Em uma arquitetura de microsserviços que usa OAuth2/JWT para autenticação stateless, qual é a falha arquitetural de segurança de usar criptografia simétrica (`HS256`) em vez de pares de chaves assimétricas (`RS256`) ao verificar assinaturas entre múltiplos microsserviços internos gerenciados de forma independente?

---

## 5. Exercício Guiado 3: Gerenciamento de Estado, Consistência de Dados e Mecânica do Teorema CAP

### Objetivos
*   Desacoplar os nós de computação da aplicação da persistência de estado usando Redis para distribuição centralizada e efêmera de sessões.
*   Analisar níveis de isolamento de transações em bancos relacionais (ACID) versus o paradigma de consistência eventual BASE.
*   Simular uma partição de rede em uma configuração de armazenamento de dados multi-nó para avaliar as compensações ditadas pelo Teorema CAP e pelo modelo PACELC.

---

### Passo 1: Implantar um Cluster de Aplicação Stateless Apoiado por Redis e PostgreSQL

Crie o diretório `lab3-state-cap`:
```bash
mkdir -p lab3-state-cap && cd lab3-state-cap
```

Crie `docker-compose.yml`:

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

Inicie os contêineres de infraestrutura:
```bash
docker compose up -d
```

---

### Passo 2: Testar a Externalização Stateless de Sessão e os Níveis de Isolamento

Crie `session_txn_demo.py`:

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

Execute o script de demonstração:
```bash
pip install redis psycopg2-binary
python3 session_txn_demo.py
```

Saída esperada da CLI:
```text
Stored Distributed Session Key in Redis: session:4a8b79e1-2c1b-4d43-9878-3a9d18c1b3f9
Fetched Session Data across Compute Nodes: {'username': 'sre_admin', 'role': 'operator'}

--- Demonstrating READ COMMITTED Isolation Level ---
Transaction 1 - Initial Read Balance: $1000.00
Transaction 1 - Read Balance (T2 uncommitted update): $1000.00
Transaction 1 - Read Balance (T2 committed update / Non-Repeatable Read): $500.00
```

---

### Passo 3: Simular uma Partição de Rede e a Mecânica do Teorema CAP

1. Entenda a restrição do Teorema CAP: na presença de uma Partição de Rede (**P**), um sistema de dados distribuído DEVE escolher entre Consistência (**C**) — retornar a escrita mais recente ou um erro — e Disponibilidade (**A**) — retornar uma resposta sem erro, mas sem garantia de que seja a escrita mais recente.

2. Execute uma simulação de Redis Sentinel / Cluster com 3 nós ou inspecione o comportamento de isolamento de rede usando regras `iptables` entre as sub-redes dos contêineres:

```bash
# Inspect the active docker bridge network to locate node IP addresses
docker inspect postgres-db | jq -r '.[0].NetworkSettings.Networks[].IPAddress'
```

Saída esperada da CLI:
```text
172.18.0.3
```

Simule a queda da comunicação da interface de rede usando iptables (requer permissões de `sudo`):

```bash
# Block TCP traffic from specific container IP to simulate split-brain / network partition
sudo iptables -A INPUT -s 172.18.0.3 -j DROP

# Verify network unreachable state
curl -m 2 http://172.18.0.3:5432 || echo "Network Partition Simulated: Target Host Unreachable"

# Flush iptables rule to restore topology
sudo iptables -D INPUT -s 172.18.0.3 -j DROP
```

Limpeza do ambiente Compose:
```bash
docker compose down -v
```

---

### Perguntas de Compreensão do Exercício 3

1.  **Pergunta 3.1:** Qual é a diferença entre *Non-Repeatable Reads* (observáveis no isolamento `READ COMMITTED`) e *Phantom Reads* (evitáveis sob isolamento `SERIALIZABLE`)? Como os locks de banco de dados ou o Multi-Version Concurrency Control (MVCC) resolvem essas anomalias?
2.  **Pergunta 3.2:** De acordo com o **teorema PACELC** (uma extensão do teorema CAP), como um armazenamento de dados distribuído se comporta em operação normal (quando não existe partição de rede **P**)? Detalhe a compensação especificada pela cláusula **E** (Else).

---

## 6. Exercício Guiado 4: Resiliência Operacional, Concorrência em Microsserviços e Observabilidade

### Objetivos
*   Configurar endpoints nativos de readiness e liveness do Kubernetes com verificações de dependências.
*   Implementar o padrão Circuit Breaker com estado para proteger microsserviços upstream de falhas em cascata sob carga pesada do sistema.
*   Medir gargalos de concorrência, distribuições de latência ($p95$, $p99$) e taxas de falha do serviço usando o motor de benchmarking HTTP `wrk`.

---

### Passo 1: Implementar a Mecânica do Circuit Breaker e as Health Probes

Crie o diretório `lab4-resilience`:
```bash
mkdir -p lab4-resilience && cd lab4-resilience
```

Crie `resilient_service.py`:

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

### Passo 2: Executar o Microsserviço e Medir Latência e Resiliência sob Carga

1. Inicie o serviço resiliente usando o Uvicorn:
```bash
uvicorn resilient_service:app --host 0.0.0.0 --port 8080 --workers 2 &
```

2. Execute requisições HTTP concorrentes com o `wrk` para disparar o circuit breaker e observar as métricas de taxa/estado:

```bash
# Run benchmarking tool: 2 threads, 20 concurrent connections, for 10 seconds
wrk -t2 -c20 -d10s http://localhost:8080/api/v1/payments
```

Saída esperada da CLI:
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

3. Transmita os logs de stdout da aplicação no contêiner para observar a lógica de transição do Circuit Breaker:

```bash
# Inspect application log output
curl -s http://localhost:8080/api/v1/payments | jq .
```

Saída esperada:
```json
{
  "detail": "Circuit breaker is OPEN. Upstream payment service currently unreachable."
}
```

Pare o serviço de backend:
```bash
pkill -f uvicorn
```

---

### Perguntas de Compreensão do Exercício 4

1.  **Pergunta 4.1:** Como a `livenessProbe` e a `readinessProbe` do Kubernetes diferem em comportamento operacional ao lidar com um serviço cujo Circuit Breaker interno disparou por degradação de um banco de dados downstream? O que acontece se um arquiteto configurar incorretamente uma verificação profunda de dependências dentro de uma `livenessProbe`?
2.  **Pergunta 4.2:** Explique a diferença arquitetural entre um *Load Balancer* operando na **Camada 4 (Camada de Transporte)** e na **Camada 7 (Camada de Aplicação)** em termos de connection pooling, terminação TLS, roteamento baseado em caminho e utilização de recursos.

---

## 7. Gabarito dos Exercícios e Explicações Técnicas

<details>
<summary><strong>Clique para Expandir o Gabarito e as Explicações dos Exercícios</strong></summary>

### Gabarito do Exercício 1

*   **Resposta 1.1:**
    *   **Mecânica Interna:** No Linux, o Process ID 1 (PID 1) é o processo init, que carrega regras únicas de tratamento de sinais no kernel. Diferentemente de processos normais, o PID 1 ignora as ações padrão do kernel para sinais (como `SIGTERM`) a menos que handlers explícitos sejam registrados. Se Python/Gunicorn roda como PID 1 sem um handler customizado ou um wrapper de processo init como o `tini`, os sinais `SIGTERM` enviados pelos orquestradores de contêineres (`docker stop` ou o despejo de um pod no Kubernetes) são silenciosamente ignorados. O orquestrador é então forçado a esperar o fim do período de graça (padrão de 10s) antes de emitir um `SIGKILL` (`kill -9`) incapturável, impedindo a drenagem graciosa de conexões, o encerramento do pool de banco de dados e a persistência do estado ativo.
    *   **Coleta de Processos Zumbis:** Além disso, quando processos worker fazem fork e posteriormente órfãos seus processos filhos, o PID 1 é responsável por adotar esses processos órfãos e chamar `waitpid()` para coletar seus status de saída. Um runtime de aplicação padrão rodando como PID 1 frequentemente não possui um laço de coleta (reaping) de init, levando a vazamentos de memória no contêiner devido ao acúmulo de processos zumbis (`defunct`). O `tini` registra o encaminhamento apropriado de sinais e coleta continuamente os processos filhos zumbis.

*   **Resposta 1.2:**
    *   **Fundamento Arquitetural:** O Fator III da metodologia 12-Factor App exige a separação completa entre configuração e código da aplicação. Armazenar configuração dentro do código ou em artefatos embutidos na imagem viola a regra fundamental da **Infraestrutura Imutável**: exatamente o mesmo binário da imagem de contêiner deve ser implantado nos ambientes de Desenvolvimento, Staging, QA e Produção, sem rebuilds.
    *   **Compensações de Segurança e Operação:** Fixar configuração no código (como credenciais de banco de dados, segredos de API ou feature flags) dentro das imagens arrisca o vazamento de credenciais sensíveis via registries de contêineres. Injetar a configuração dinamicamente em tempo de execução por variáveis de ambiente ou cofres de segredos montados garante isolamento estrito entre ambientes, rotação dinâmica de segredos de produção sem reconstruir a imagem e conformidade estrita com o Princípio do Menor Privilégio.

---

### Gabarito do Exercício 2

*   **Resposta 2.1:**
    *   **Mecanismo no Nível do Motor:** Quando se usa concatenação dinâmica bruta de strings (`SELECT * FROM users WHERE email = '` + input + `'`), o parser SQL do banco de dados interpreta a string de entrada não confiável como estrutura de código executável. Isso permite que atacantes injetem palavras-chave da sintaxe SQL (por exemplo, `' OR '1'='1`), alterando a Árvore Sintática Abstrata (AST) construída pelo motor de consultas.
    *   **Queries Parametrizadas / Prepared Statements:** Prepared statements desacoplam a fase de compilação da fase de execução. A estrutura da consulta SQL é enviada primeiro ao motor do banco de dados e compilada em um plano de execução com placeholders (`?` ou `$1`). Quando os valores dos parâmetros são transmitidos em seguida pelo protocolo de rede, o motor do banco trata estritamente essas entradas como valores escalares literais, nunca como tokens SQL executáveis. Mesmo que a entrada contenha `' OR '1'='1`, ela é interpretada estritamente como um valor de string literal comparado contra a coluna, neutralizando completamente a injeção de código independentemente do conteúdo da entrada.

*   **Resposta 2.2:**
    *   **Risco Simétrico (`HS256`):** O `HS256` usa uma única chave secreta compartilhada tanto para assinar quanto para verificar tokens JWT. Em uma malha de microsserviços onde o Serviço A emite tokens e os Serviços B, C e D verificam esses tokens, cada serviço precisa possuir uma cópia da chave secreta privada. Se qualquer serviço downstream (por exemplo, o Serviço D) for comprometido, o atacante extrai a chave compartilhada e pode forjar tokens administrativos válidos para *qualquer* serviço em toda a arquitetura corporativa.
    *   **Garantia de Segurança Assimétrica (`RS256`):** O `RS256` usa um par de chaves RSA assimétricas (Chave Privada / Chave Pública). O Provedor de Identidade / Serviço de Autenticação mantém a Chave Privada para assinar tokens. Os microsserviços downstream apenas recebem e armazenam a Chave Pública. Os Serviços B, C e D podem verificar criptograficamente que o token foi assinado pelo Servidor de Autenticação legítimo, mas mesmo que o Serviço D seja totalmente comprometido, a chave pública não pode ser usada para forjar novas assinaturas.

---

### Gabarito do Exercício 3

*   **Resposta 3.1:**
    *   **Non-Repeatable Reads:** Ocorrem sob o isolamento `READ COMMITTED` quando a Transação A lê uma linha, a Transação B modifica e faz commit de uma atualização nessa mesma linha, e a Transação A relê a linha, observando dados diferentes nas colunas dentro do mesmo contexto transacional.
    *   **Phantom Reads:** Ocorrem quando a Transação A executa uma consulta de intervalo (por exemplo, `SELECT COUNT(*) WHERE age > 30`), a Transação B insere uma *nova* linha correspondente e faz commit, e a Transação A reexecuta a consulta de intervalo, observando novas linhas "fantasma" que antes não existiam.
    *   **Prevenção via MVCC e Locking:** Motores de banco de dados como o PostgreSQL usam **Multi-Version Concurrency Control (MVCC)**. Sob o isolamento `REPEATABLE READ` ou `SERIALIZABLE`, o PostgreSQL atribui a cada transação um timestamp lógico de snapshot. A Transação A lê apenas versões de dados criadas antes do timestamp de início de sua transação. Sob o isolamento `SERIALIZABLE`, os motores utilizam **Predicate Locking** ou **Serializable Snapshot Isolation (SSI)** para rastrear dependências entre transações e abortar qualquer transação que introduza anomalias de serialização de leitura/escrita.

*   **Resposta 3.2:**
    *   **Definição de PACELC:** O PACELC expande o teorema CAP para tratar das compensações durante estados operacionais normais (sem partição):
        *   **Se Partição (P):** compensação entre Disponibilidade (**A**) e Consistência (**C**).
        *   **Senão (E):** compensação entre Latência (**L**) e Consistência (**C**).
    *   **Compensações do Sistema:** Mesmo quando a rede está plenamente saudável, um banco de dados distribuído não consegue alcançar simultaneamente latência instantaneamente baixa e consistência forte absoluta entre múltiplos nós. Para garantir consistência forte (**C**), uma operação de escrita deve replicar de forma síncrona e aguardar a confirmação de um quórum de nós réplica antes de retornar sucesso ao cliente, aumentando a **Latência (L)** operacional. Se um arquiteto prioriza **Latência (L)** ultrabaixa (por exemplo, replicação assíncrona em segundo plano), leituras executadas contra réplicas de leitura podem retornar dados obsoletos, sacrificando a consistência forte imediata (**C**).

---

### Gabarito do Exercício 4

*   **Resposta 4.1:**
    *   **Diferenças de Comportamento das Probes:**
        *   `livenessProbe`: determina se o processo do contêiner está saudável. Se a liveness probe falha, o orquestrador (Kubernetes) **mata o contêiner e o reinicia**.
        *   `readinessProbe`: determina se o contêiner está pronto para servir tráfego de rede. Se a readiness probe falha, o orquestrador **remove o IP do pod do load balancer de endpoints do Service**, interrompendo o roteamento de tráfego sem reiniciar o processo.
    *   **Configuração Catastrófica de Liveness:** Se um arquiteto configura uma `livenessProbe` para consultar um banco de dados downstream ou um serviço de terceiros, e essa dependência downstream sofre uma indisponibilidade, *a liveness probe de cada instância da aplicação falhará simultaneamente*. O Kubernetes reagirá reiniciando todos os pods do cluster em um crash-loop infinito (Falha em Cascata / Thundering Herd), agravando a indisponibilidade e destruindo os pools de conexão ativos. Verificações de saúde de dependências downstream devem ser avaliadas *apenas* em endpoints de `readinessProbe` ou mascaradas por trás de fallbacks de circuit breaker.

*   **Resposta 4.2:**
    *   **Balanceamento de Carga na Camada 4 (Camada de Transporte):** opera no nível do protocolo TCP/UDP (por exemplo, AWS NLB, IPVS). Encaminha pacotes IP brutos sem inspecionar ou terminar o payload da aplicação subjacente (HTTP/TLS).
        *   *Prós:* throughput extremamente alto, sobrecarga mínima de CPU, baixa latência.
        *   *Contras:* não consegue inspecionar cabeçalhos HTTP, rotas de caminho ou cookies; limitado ao balanceamento pela tupla IP/Porta; não pode realizar offloading de TLS nem roteamento por caminho HTTP.
    *   **Balanceamento de Carga na Camada 7 (Camada de Aplicação):** opera no nível do protocolo de aplicação (por exemplo, NGINX, HAProxy, Envoy, AWS ALB). Termina as conexões TCP e TLS de entrada, faz parsing dos cabeçalhos HTTP/gRPC, URIs e corpo do payload.
        *   *Prós:* regras avançadas de roteamento (por exemplo, rotear `/api/v1/orders` para o Microsserviço A, `/static` para o S3), manipulação de cabeçalhos HTTP, CORS, rate limiting, hospedagem virtual baseada em host e multiplexação inteligente de HTTP/2.
        *   *Contras:* maior utilização de CPU e memória devido à descriptografia TLS e à sobrecarga de parsing HTTP; latência por requisição mais alta em comparação com o repasse de pacotes na L4.

</details>