# Topic 701.1: Modern Software Development — Production-Grade Guided Lab Exercises

## 1. Overview & Official References

The **LPI DevOps Tools Engineer (701-100, Version 1.0)** certification assesses a candidate's ability to bridge software engineering practices with modern infrastructure architectures. **Topic 701.1: Modern Software Development** evaluates your technical mastery of service-oriented and microservice architectures, 12-Factor application principles, RESTful API design standards, state and session management, distributed system trade-offs (CAP theorem, ACID vs. BASE), application security mitigations (OWASP Top 10), and operational readiness patterns (disposability, dynamic scaling, structured logging, and health probing).

### Official References
*   **LPI DevOps Tools Engineer Overview:** [https://www.lpi.org/our-certifications/devops-tools-engineer-overview/](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
*   **LPI Wiki Exam 701 Objectives:** [https://wiki.lpi.org/wiki/DevOps_Tools_Engineer_Objectives_V1](https://wiki.lpi.org/wiki/DevOps_Tools_Engineer_Objectives_V1)
*   **The Twelve-Factor App Methodology:** [https://12factor.net/](https://12factor.net/)
*   **NIST Special Publication 800-204 (Microservices Security):** [https://csrc.nist.gov/publications/detail/sp/800-204/final](https://csrc.nist.gov/publications/detail/sp/800-204/final)

---

## 2. System Prerequisites & Environment Setup

Before starting the exercises, ensure your Linux environment has Docker, Docker Compose, `curl`, `jq`, and standard debugging tools (`iproute2`, `procps`, `wrk`) installed.

```bash
# Verify environment readiness
docker --version
docker compose version
curl --version
jq --version
```

Expected output:
```text
Docker version 24.0.7, build afdd53b
Docker Compose version v2.21.0
curl 8.5.0 (x86_64-pc-linux-gnu) libcurl/8.5.0
jq-1.7
```

---

## 3. Guided Exercise 1: Cloud-Native Stateless Microservices & 12-Factor Mechanics

### Objectives
*   Build a stateless REST microservice adhering to 12-Factor principles.
*   Implement explicit dependency isolation, environment-driven configuration externalization, and event-stream logging.
*   Configure process disposability and kernel signal handling (`SIGTERM` vs `SIGKILL`) for zero-downtime rolling updates.
*   Construct a secure multi-stage Docker build utilizing non-root runtimes and a PID 1 init wrapper (`tini`).

---

### Step 1: Write the 12-Factor Python/FastAPI Application Code

Create a directory named `lab1-stateless-service` and create `app.py`:

```bash
mkdir -p lab1-stateless-service && cd lab1-stateless-service
```

Create `app.py`:

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

Create `requirements.txt`:
```text
fastapi==0.110.0
uvicorn==0.28.0
gunicorn==21.2.0
```

---

### Step 2: Construct the Multi-Stage OCI/Dockerfile with Init Signal Wrapper

Create `Dockerfile`:

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

### Step 3: Build, Run, and Inspect Signal Trapping & Disposability

Execute the following commands in your shell:

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

Expected CLI Output:
```text
USER         PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
10001          1  0.0  0.0   2480  1632 ?        Ss   04:40   0:00 /usr/bin/tini -- gunicorn -w 2 -k uvicorn.workers.UvicornWorker -b 0.0.0.0:8080 app:app
10001          7  0.3  1.2  54312 25890 ?        S    04:40   0:00 python /usr/local/bin/gunicorn -w 2 -k uvicorn.workers.UvicornWorker -b 0.0.0.0:8080 app:app
10001          8  0.8  1.8 184320 37412 ?        Sl   04:40   0:00 python /usr/local/bin/gunicorn -w 2 -k uvicorn.workers.UvicornWorker -b 0.0.0.0:8080 app:app
10001          9  0.8  1.8 184320 37420 ?        Sl   04:40   0:00 python /usr/local/bin/gunicorn -w 2 -k uvicorn.workers.UvicornWorker -b 0.0.0.0:8080 app:app
```

Now, test graceful termination by issuing a `docker stop` (which sends `SIGTERM` followed by a timeout before sending `SIGKILL`):

```bash
# Send SIGTERM via docker stop and stream stdout logs
docker stop --time=10 orders-service-container &
docker logs -f orders-service-container
```

Expected Container Logs Output:
```json
{"timestamp":"2026-08-07 04:41:12,102", "level":"WARNING", "service":"orders-api", "message":"Received kernel signal SIGTERM. Initiating 12-Factor graceful shutdown..."}
{"timestamp":"2026-08-07 04:41:12,103", "level":"INFO", "service":"orders-api", "message":"Draining inflight HTTP requests (simulated 3-second grace period)..."}
{"timestamp":"2026-08-07 04:41:15,106", "level":"INFO", "service":"orders-api", "message":"Database connection pools closed cleanly. Process exiting with code 0."}
```

Cleanup container:
```bash
docker rm orders-service-container
```

---

### Exercise 1 Comprehension Questions

1.  **Question 1.1:** Why does running a Python process as PID 1 directly inside an OCI container without an init daemon like `tini` cause `SIGTERM` handling issues and accumulated zombie child processes?
2.  **Question 1.2:** Under the 12-Factor methodology (Factor III: Config and Factor VI: Processes), why is storing configuration parameters inside application codebase constants or configuration files bundled within the container image considered an architectural anti-pattern for modern cloud-native deployments?

---

## 4. Guided Exercise 2: RESTful API Design, OAuth2/JWT Security, and Threat Mitigation

### Objectives
*   Deploy an NGINX API Gateway providing CORS control, rate limiting, and defensive HTTP security headers.
*   Demonstrate microservice vulnerability mechanisms to OWASP Top 10 threats (SQL Injection & Stored XSS) and implement remediation strategies.
*   Validate asymmetric cryptographic token verification (RS256 JWT) for stateless cross-service authorization flows.

---

### Step 1: Generate Cryptographic Keys and Configure NGINX API Gateway

Create directory `lab2-api-security`:
```bash
mkdir -p lab2-api-security && cd lab2-api-security
```

Generate an RSA 2048-bit key pair for asymmetric JWT signing and verification:
```bash
openssl genpkey -algorithm RSA -out jwt_private.pem -pkeyopt rsa_keygen_bits:2048
openssl rsa -pubout -in jwt_private.pem -out jwt_public.pem
```

Create `nginx-gateway.conf`:

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

### Step 2: Implement Vulnerable vs. Hardened Microservice Endpoints

Create `secure_app.py`:

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

### Step 3: Run the API and Execute Threat Vectors via CLI

1. Install PyJWT, Cryptography, and FastAPI in your local Python environment:
```bash
pip install fastapi uvicorn pyjwt cryptography pydantic
```

2. Launch the backend microservice:
```bash
uvicorn secure_app:app --host 0.0.0.0 --port 8080 &
```

3. **Attack Vector 1: Execute SQL Injection on Vulnerable Endpoint**

```bash
# Normal Request
curl -s "http://localhost:8080/api/v1/vulnerable/user?email=admin@company.com" | jq .

# SQL Injection Payload: Tautology bypass to extract all table contents
curl -s "http://localhost:8080/api/v1/vulnerable/user?email=admin@company.com'%20OR%20'1'='1" | jq .
```

Expected CLI Output (SQL Injection Success on Vulnerable Endpoint):
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

4. **Attack Vector 2: Attempt SQL Injection on Secure Endpoint (Without JWT)**

```bash
curl -i "http://localhost:8080/api/v1/secure/user?email=admin@company.com'%20OR%20'1'='1"
```

Expected CLI Output:
```http
HTTP/1.1 401 Unauthorized
date: Fri, 07 Aug 2026 04:45:00 GMT
server: uvicorn
content-length: 63
content-type: application/json

{"detail":"Missing or invalid Authorization header scheme"}
```

5. **Generate Valid RS256 Signed JWT Token & Perform Authorized Request**

Generate a valid JWT token using a temporary inline Python script:

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

Expected CLI Output (SQL Injection Neutralized by Parameterized Query):
```json
{"detail":"User not found"}
```

Kill backend process when done testing:
```bash
pkill -f uvicorn
```

---

### Exercise 2 Comprehension Questions

1.  **Question 2.1:** How does using parameterized prepared statements (bind variables) fundamentally prevent SQL Injection attacks at the database driver engine layer compared to dynamic string concatenation or regex sanitization?
2.  **Question 2.2:** In a microservices architecture utilizing OAuth2/JWT for stateless authentication, what is the architectural security flaw of using symmetric encryption (`HS256`) vs asymmetric key pairs (`RS256`) when verifying signatures across multiple independently managed internal microservices?

---

## 5. Guided Exercise 3: State Management, Data Consistency, & CAP Theorem Mechanics

### Objectives
*   Decouple application compute nodes from state persistence using Redis for centralized, ephemeral session distribution.
*   Analyze relational database transaction isolation levels (ACID) vs BASE eventual consistency paradigms.
*   Simulate a network partition in a multi-node datastore setup to evaluate trade-offs dictated by the CAP Theorem and PACELC model.

---

### Step 1: Deploy a Stateless App Cluster backed by Redis and PostgreSQL

Create directory `lab3-state-cap`:
```bash
mkdir -p lab3-state-cap && cd lab3-state-cap
```

Create `docker-compose.yml`:

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

Start infrastructure containers:
```bash
docker compose up -d
```

---

### Step 2: Test Stateless Session Externalization and Isolation Levels

Create `session_txn_demo.py`:

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

Run the demonstration script:
```bash
pip install redis psycopg2-binary
python3 session_txn_demo.py
```

Expected CLI Output:
```text
Stored Distributed Session Key in Redis: session:4a8b79e1-2c1b-4d43-9878-3a9d18c1b3f9
Fetched Session Data across Compute Nodes: {'username': 'sre_admin', 'role': 'operator'}

--- Demonstrating READ COMMITTED Isolation Level ---
Transaction 1 - Initial Read Balance: $1000.00
Transaction 1 - Read Balance (T2 uncommitted update): $1000.00
Transaction 1 - Read Balance (T2 committed update / Non-Repeatable Read): $500.00
```

---

### Step 3: Simulate Network Partition and CAP Theorem Mechanics

1. Understand the CAP Theorem constraint: In the presence of a Network Partition (**P**), a distributed data system MUST trade off between Consistency (**C**) — returning the most recent write or an error — and Availability (**A**) — returning a non-error response without guarantee of latest write.

2. Run a 3-node Redis Sentinel / Cluster simulation or inspect network isolation behavior using `iptables` rules between container subnets:

```bash
# Inspect the active docker bridge network to locate node IP addresses
docker inspect postgres-db | jq -r '.[0].NetworkSettings.Networks[].IPAddress'
```

Expected CLI Output:
```text
172.18.0.3
```

Simulate dropping network interface communications using iptables (Requires `sudo` permissions):

```bash
# Block TCP traffic from specific container IP to simulate split-brain / network partition
sudo iptables -A INPUT -s 172.18.0.3 -j DROP

# Verify network unreachable state
curl -m 2 http://172.18.0.3:5432 || echo "Network Partition Simulated: Target Host Unreachable"

# Flush iptables rule to restore topology
sudo iptables -D INPUT -s 172.18.0.3 -j DROP
```

Cleanup Compose environment:
```bash
docker compose down -v
```

---

### Exercise 3 Comprehension Questions

1.  **Question 3.1:** What is the difference between *Non-Repeatable Reads* (observable in `READ COMMITTED` isolation) and *Phantom Reads* (preventable under `SERIALIZABLE` isolation)? How do database locks or Multi-Version Concurrency Control (MVCC) resolve these anomalies?
2.  **Question 3.2:** According to the **PACELC theorem** (an extension of the CAP theorem), how does a distributed datastore behave under normal operation (when no network partition **P** exists)? Detail the trade-off specified by the **E** (Else) clause.

---

## 6. Guided Exercise 4: Operational Resilience, Microservice Concurrency, & Observability

### Objectives
*   Configure Kubernetes-native readiness and liveness endpoints with dependency checks.
*   Implement a stateful Circuit Breaker pattern to protect upstream microservices from cascading failures under heavy system load.
*   Measure concurrency bottlenecks, latency distributions ($p95$, $p99$), and service failure rates using the `wrk` HTTP benchmarking engine.

---

### Step 1: Implement Circuit Breaker Mechanics and Health Probes

Create directory `lab4-resilience`:
```bash
mkdir -p lab4-resilience && cd lab4-resilience
```

Create `resilient_service.py`:

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

### Step 2: Run Microservice & Measure Latency and Resilience under Load

1. Launch the resilient service using Uvicorn:
```bash
uvicorn resilient_service:app --host 0.0.0.0 --port 8080 --workers 2 &
```

2. Execute concurrent HTTP requests using `wrk` to trip the circuit breaker and observe rate/state metrics:

```bash
# Run benchmarking tool: 2 threads, 20 concurrent connections, for 10 seconds
wrk -t2 -c20 -d10s http://localhost:8080/api/v1/payments
```

Expected CLI Output:
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

3. Stream container application stdout logs to observe the Circuit Breaker transition logic:

```bash
# Inspect application log output
curl -s http://localhost:8080/api/v1/payments | jq .
```

Expected Output:
```json
{
  "detail": "Circuit breaker is OPEN. Upstream payment service currently unreachable."
}
```

Stop backend service:
```bash
pkill -f uvicorn
```

---

### Exercise 4 Comprehension Questions

1.  **Question 4.1:** How do Kubernetes `livenessProbe` and `readinessProbe` differ in operational behavior when dealing with a service whose internal Circuit Breaker has tripped due to downstream database degradation? What happens if an architect incorrectly configures a deep dependency check inside a `livenessProbe`?
2.  **Question 4.2:** Explain the architectural difference between a *Load Balancer* operating at **Layer 4 (Transport Layer)** vs. **Layer 7 (Application Layer)** in terms of connection pooling, TLS termination, path-based routing, and resource utilization.

---

## 7. Exercise Answer Key & Technical Explanations

<details>
<summary><strong>Click to Expand Exercise Answer Key & Explanations</strong></summary>

### Exercise 1 Answer Key

*   **Answer 1.1:**
    *   **Internal Mechanics:** In Linux, Process ID 1 (PID 1) is the init process, which carries unique signal-handling rules in the kernel. Unlike normal processes, PID 1 ignores standard kernel default actions for signals (such as `SIGTERM`) unless explicit signal handlers are registered. If Python/Gunicorn runs as PID 1 without a custom handler or an init process wrapper like `tini`, incoming `SIGTERM` signals sent by container orchestrators (`docker stop` or Kubernetes pod eviction) are silently ignored. The orchestrator is then forced to wait out the grace period (default 10s) before issuing a uncatchable `SIGKILL` (`kill -9`), preventing graceful connection draining, database pool termination, and active state persistence.
    *   **Zombie Process Reaping:** Furthermore, when worker processes fork and subsequently orphan child processes, PID 1 is responsible for adopting those orphaned processes and calling `waitpid()` to collect their exit statuses. A standard application runtime running as PID 1 often lacks an init reaping loop, leading to container memory leaks due to accumulated zombie processes (`defunct`). `tini` registers appropriate signal forwarding and continuously reaps zombie child processes.

*   **Answer 1.2:**
    *   **Architectural Rationale:** Factor III of the 12-Factor App methodology mandates complete separation of configuration from application code. Storing config inside code or baked image artifacts violates the fundamental rule of **Immutable Infrastructure**: the exact same container image binary must be deployed across Development, Staging, QA, and Production environments without rebuilds.
    *   **Security & Ops Trade-offs:** Hardcoding config (such as database credentials, API secrets, or feature flags) inside images risks sensitive credential leakage via container registries. Injecting configuration dynamically at runtime via Environment Variables or mounted secret stores ensures strict environment isolation, dynamic rotation of production secrets without image rebuilding, and strict compliance with the Principle of Least Privilege.

---

### Exercise 2 Answer Key

*   **Answer 2.1:**
    *   **Engine-Level Mechanism:** When raw dynamic string concatenation is used (`SELECT * FROM users WHERE email = '` + input + `'`), the database SQL parser interprets the untrusted input string as executable code structure. This enables attackers to inject SQL syntax keywords (e.g., `' OR '1'='1`), altering the Abstract Syntax Tree (AST) constructed by the query engine.
    *   **Parameterized Queries / Prepared Statements:** Prepared statements decouple the compilation phase from the execution phase. The SQL query structure is sent to the database engine first and compiled into an execution plan with placeholders (`?` or `$1`). When the parameter values are subsequently transmitted over the wire protocol, the database engine strictly treats those inputs as literal scalar values, never as executable SQL tokens. Even if the input contains `' OR '1'='1`, it is interpreted strictly as a literal string value matching against the column, completely neutralizing code injection regardless of input contents.

*   **Answer 2.2:**
    *   **Symmetric (`HS256`) Risk:** `HS256` uses a single shared secret key for both signing and verifying JWT tokens. In a microservices mesh where Service A issues tokens and Services B, C, and D verify those tokens, every single service must possess a copy of the private secret key. If any downstream service (e.g., Service D) is compromised, the attacker extracts the shared key and can forge valid administrative tokens for *any* service across the entire enterprise architecture.
    *   **Asymmetric (`RS256`) Security Guarantee:** `RS256` uses an asymmetric RSA key pair (Private Key / Public Key). The Identity Provider / Auth Service retains the Private Key to sign tokens. Downstream microservices only receive and store the Public Key. Services B, C, and D can cryptographically verify that the token was signed by the legitimate Auth Server, but even if Service D is fully compromised, the public key cannot be used to forge new signatures.

---

### Exercise 3 Answer Key

*   **Answer 3.1:**
    *   **Non-Repeatable Reads:** Occurs under `READ COMMITTED` isolation when Transaction A reads a row, Transaction B modifies and commits an update to that same row, and Transaction A re-reads the row, observing different column data within the same transaction context.
    *   **Phantom Reads:** Occurs when Transaction A executes a range query (e.g., `SELECT COUNT(*) WHERE age > 30`), Transaction B inserts a *new* matching row and commits, and Transaction A re-executes the range query, observing new "phantom" rows that did not previously exist.
    *   **Prevention via MVCC & Locking:** Database engines like PostgreSQL use **Multi-Version Concurrency Control (MVCC)**. Under `REPEATABLE READ` or `SERIALIZABLE` isolation, PostgreSQL assigns each transaction a logical snapshot timestamp. Transaction A only reads data versions created prior to its transaction start timestamp. Under `SERIALIZABLE` isolation, engines utilize **Predicate Locking** or **Serializable Snapshot Isolation (SSI)** to track dependencies across transactions and abort any transaction that introduces read/write serialization anomalies.

*   **Answer 3.2:**
    *   **PACELC Definition:** PACELC expands the CAP theorem to address trade-offs during normal (non-partitioned) operational states:
        *   **If Partition (P):** Trade-off between Availability (**A**) vs. Consistency (**C**).
        *   **Else (E):** Trade-off between Latency (**L**) vs. Consistency (**C**).
    *   **System Trade-Offs:** Even when the network is fully healthy, a distributed database cannot achieve both instantaneous low latency and absolute strong consistency across multiple nodes. To guarantee strong consistency (**C**), a write operation must synchronously replicate and wait for acknowledgment from a quorum of replica nodes before returning success to the client, increasing operational **Latency (L)**. If an architect prioritizes ultra-low **Latency (L)** (e.g., asynchronous background replication), reads executed against read-replicas may yield stale data, sacrificing immediate strong consistency (**C**).

---

### Exercise 4 Answer Key

*   **Answer 4.1:**
    *   **Probe Behavioral Differences:**
        *   `livenessProbe`: Determines if the container process is healthy. If the liveness probe fails, the orchestrator (Kubernetes) **kills the container and restarts it**.
        *   `readinessProbe`: Determines if the container is ready to serve network traffic. If the readiness probe fails, the orchestrator **removes the pod IP from the Service endpoint load balancer**, stopping traffic routing without restarting the process.
    *   **Catastrophic Liveness Misconfiguration:** If an architect configures a `livenessProbe` to ping a downstream database or third-party service, and that downstream dependency experiences an outage, *every single application instance's liveness probe will simultaneously fail*. Kubernetes will react by rebooting all pods across the cluster in an infinite crash-loop (Cascading Failure / Thundering Herd), worsening the outage and destroying active connection pools. Downstream dependency health checks must *only* be evaluated in `readinessProbe` endpoints or masked behind circuit breaker fallbacks.

*   **Answer 4.2:**
    *   **Layer 4 (Transport Layer) Load Balancing:** Operates at the TCP/UDP protocol level (e.g., AWS NLB, IPVS). It forwards raw IP packets without inspecting or terminating the underlying application payload (HTTP/TLS).
        *   *Pros:* Extremely high throughput, minimal CPU overhead, low latency.
        *   *Cons:* Cannot inspect HTTP headers, path routes, or cookies; limited to IP/Port tuple balancing; cannot perform TLS offloading or HTTP path routing.
    *   **Layer 7 (Application Layer) Load Balancing:** Operates at the Application protocol level (e.g., NGINX, HAProxy, Envoy, AWS ALB). It terminates incoming TCP and TLS connections, parses the HTTP/gRPC request headers, URIs, and payload body.
        *   *Pros:* Advanced routing rules (e.g., route `/api/v1/orders` to Microservice A, `/static` to S3), HTTP header manipulation, CORS, rate limiting, host-based virtual hosting, and intelligent HTTP/2 multiplexing.
        *   *Cons:* Higher CPU and memory utilization due to TLS decryption and HTTP parsing overhead; higher per-request latency compared to L4 packet passing.

</details>