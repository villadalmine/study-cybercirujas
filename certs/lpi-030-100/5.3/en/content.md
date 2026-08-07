# LPI 030-100 (v1.0) Topic 5.3: SQL Basics & Database Integration
## SRE & Platform Architecture Production Study Guide (Exam Weight: 7.5)

---

## 1. Production Architectural Motivation & Problem Statement

### 1.1 The Enterprise State Challenge in Stateless Application Architecture
Modern web architectures separate execution state from persistent storage. While Node.js microservices operate state-lessly behind cloud load balancers, the backing store must preserve data durability, transactional integrity, and linearizability under high-concurrency environments.

```
                      +---------------------------------------+
                      |   Ingress Controller / Load Balancer   |
                      +---------------------------------------+
                                          |
                        +-----------------+-----------------+
                        |                                   |
            +-----------------------+           +-----------------------+
            | Node.js App Pod (SRE) |           | Node.js App Pod (SRE) |
            |  Stateless Execution  |           |  Stateless Execution  |
            +-----------------------+           +-----------------------+
                        |                                   |
                        +-----------------+-----------------+
                                          |
                 +-------------------------------------------------+
                 | Data Layer (SQLite WAL / PostgreSQL Engine)     |
                 | - Concurrency & Serialization Control           |
                 | - ACID Transaction Guarantee                     |
                 +-------------------------------------------------+
```

### 1.2 Structural Failure Modes of Unmitigated Database Interfaces
When connecting asynchronous application runtimes (such as Node.js) to relational database engines, three critical failure vectors emerge in production environments:

1. **SQL Injection (SQLi) Vulnerabilities**: Direct dynamic string interpolation inside raw queries allows unauthenticated attackers to escape input bounds, manipulate abstract syntax trees (AST), bypass authentication filters, or execute arbitrary data-wiping commands (`DROP TABLE`, `UNION SELECT`).
2. **Concurrency & Thread Contention (File-Locking & Pool Exhaustion)**: 
   - Embedded engines (e.g., SQLite) default to rollback journal modes that obtain exclusive database write locks. High-frequency parallel writes trigger `SQLITE_BUSY` errors and lead to thread exhaustion in the application event loop.
   - Client-server engines (e.g., PostgreSQL/MySQL) can experience connection pool starvation when application pods open unmanaged sockets without timeouts or bounded connection counts.
3. **Data Integrity & Corruption**: Unenforced database constraints (`NOT NULL`, `UNIQUE`, `PRIMARY KEY`, `FOREIGN KEY`) offload integrity validation to the application tier. In multi-pod deployments, concurrent requests race past application validation checks, inserting duplicate or orphaned records.

---

## 2. Technical Comparisons & Architecture Trade-off Tables

### 2.1 Embedded Relational Engine (SQLite) vs. Client-Server Engine (PostgreSQL/MySQL)

| Feature / Metric | SQLite (Embedded Engine) | PostgreSQL / MySQL (Client-Server) |
| :--- | :--- | :--- |
| **Architecture** | Single-file embedded library inside application process | Independent multi-process daemon accessed over IPC/TCP-IP |
| **Write Concurrency** | Single-writer process lock (Mitigated via WAL mode) | Multi-writer row-level locking (MVCC - Multi-Version Concurrency Control) |
| **Network Overhead** | 0 ms network latency (Direct memory / NVMe POSIX I/O) | 1-5 ms local network overhead per query round-trip |
| **Deployment Complexity** | Low (Zero external dependencies, local disk mount) | High (Requires stateful orchestration, replica sets, connection proxies) |
| **Ideal Production Use Case** | Edge nodes, read-heavy APIs, CLI tools, local caching | High-concurrency enterprise OLTP, multi-region web applications |

### 2.2 Dynamic String Concatenation vs. Parameterized Queries (Prepared Statements)

| Parameter | Dynamic Query Concatenation | Parameterized Statements (`?` / `$1`) |
| :--- | :--- | :--- |
| **AST Parsing** | Re-parsed on every execution; query code merged with data | Parsed and compiled once; parameters bound separately |
| **SQLi Protection** | **None**. Input values alter query execution paths | **Full**. User input is treated strictly as data literals |
| **Query Plan Reuse** | Low (Unique string generates unique hash in query cache) | High (Pre-compiled AST reused across variable executions) |
| **Compliance Standard** | Fails OWASP Top 10 A03:2021 (Injection) | Meets PCI-DSS 6.5.1 and NIST SP 800-53 controls |

### 2.3 ACID Guarantees in Production Relational Systems

| Guarantees | Mechanism | SRE Operational Impact |
| :--- | :--- | :--- |
| **Atomicity** | Undo logs / Write-Ahead Logging (WAL) | Ensures multi-statement transactions fail cleanly without partial writes. |
| **Consistency** | Schema Constraints, Foreign Keys, Indexes | Prevents invalid states at the engine level regardless of application bugs. |
| **Isolation** | Lock Managers / Snapshot Isolation (MVCC) | Prevents Dirty Reads, Non-Repeatable Reads, and Phantom Reads. |
| **Durability** | `fsync()` flushing to non-volatile storage | Guarantees committed transactions survive host kernel crashes or power failures. |

---

## 3. Complete Syntax-Valid Manifests & Infrastructure Files

### 3.1 Infrastructure Deployment (`k8s-production-db-app.yaml`)
This production-grade Kubernetes manifest deploys a Node.js stateless application paired with persistent volume storage for database state management, incorporating liveness/readiness probes, resource limits, and mounting configuration maps.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: production-data-tier
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-db-config
  namespace: production-data-tier
data:
  DB_FILE_PATH: "/var/lib/data/production.db"
  NODE_ENV: "production"
  DB_BUSY_TIMEOUT: "5000"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: sqlite-pvc
  namespace: production-data-tier
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  storageClassName: standard
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nodejs-sql-api
  namespace: production-data-tier
  labels:
    app.kubernetes.io/name: nodejs-sql-api
    app.kubernetes.io/part-of: core-platform
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: nodejs-sql-api
  template:
    metadata:
      labels:
        app: nodejs-sql-api
    spec:
      containers:
        - name: api-server
          image: node:20-alpine
          workingDir: /usr/src/app
          command: ["sh", "-c", "npm install sqlite3 express && node server.js"]
          ports:
            - containerPort: 3000
              name: http
          envFrom:
            - configMapRef:
                name: app-db-config
          resources:
            requests:
              cpu: "250m"
              memory: "256Mi"
            limits:
              cpu: "1000m"
              memory: "512Mi"
          readinessProbe:
            httpGet:
              path: /healthz
              port: 3000
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /healthz
              port: 3000
            initialDelaySeconds: 15
            periodSeconds: 20
          volumeMounts:
            - name: db-storage
              mountPath: /var/lib/data
            - name: app-code
              mountPath: /usr/src/app
      volumes:
        - name: db-storage
          persistentVolumeClaim:
            claimName: sqlite-pvc
        - name: app-code
          configMap:
            name: app-source-code
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-source-code
  namespace: production-data-tier
data:
  server.js: |
    const express = require('express');
    const sqlite3 = require('sqlite3').verbose();
    const path = require('path');

    const app = express();
    app.use(express.json());

    const dbPath = process.env.DB_FILE_PATH || './production.db';
    const busyTimeout = parseInt(process.env.DB_BUSY_TIMEOUT || '5000', 10);

    const db = new sqlite3.Database(dbPath, (err) => {
      if (err) {
        console.error('CRITICAL: Failed to connect to SQLite database:', err.message);
        process.exit(1);
      }
      console.log(`Successfully connected to SQLite engine at ${dbPath}`);
    });

    db.configure('busyTimeout', busyTimeout);

    db.serialize(() => {
      db.run(`PRAGMA journal_mode = WAL;`);
      db.run(`PRAGMA synchronous = NORMAL;`);
      db.run(`PRAGMA foreign_keys = ON;`);
      
      db.run(`
        CREATE TABLE IF NOT EXISTS users (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          username TEXT NOT NULL UNIQUE,
          email TEXT NOT NULL UNIQUE,
          status TEXT CHECK(status IN ('active', 'suspended', 'pending')) DEFAULT 'pending',
          created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        )
      `, (err) => {
        if (err) {
          console.error('Failed to initialize schema:', err.message);
        } else {
          console.log('Database schema verified successfully.');
        }
      });
    });

    app.get('/healthz', (req, res) => {
      db.get('SELECT 1', (err) => {
        if (err) {
          return res.status(500).json({ status: 'UNHEALTHY', error: err.message });
        }
        res.status(200).json({ status: 'HEALTHY' });
      });
    });

    app.get('/api/v1/users', (req, res) => {
      const sql = 'SELECT id, username, email, status, created_at FROM users ORDER BY id DESC';
      db.all(sql, [], (err, rows) => {
        if (err) {
          return res.status(500).json({ error: 'Database execution failure', details: err.message });
        }
        res.status(200).json({ count: rows.length, data: rows });
      });
    });

    app.post('/api/v1/users', (req, res) => {
      const { username, email, status } = req.body;
      if (!username || !email) {
        return res.status(400).json({ error: 'Validation Error: username and email are required.' });
      }

      const sql = 'INSERT INTO users (username, email, status) VALUES (?, ?, ?)';
      const params = [username, email, status || 'pending'];

      db.run(sql, params, function(err) {
        if (err) {
          if (err.message.includes('UNIQUE constraint failed')) {
            return res.status(409).json({ error: 'Conflict: Username or Email already exists.' });
          }
          return res.status(500).json({ error: 'Failed to insert user', details: err.message });
        }
        res.status(201).json({ id: this.lastID, username, email, status: status || 'pending' });
      });
    });

    app.get('/api/v1/users/:id', (req, res) => {
      const sql = 'SELECT id, username, email, status, created_at FROM users WHERE id = ?';
      db.get(sql, [req.params.id], (err, row) => {
        if (err) {
          return res.status(500).json({ error: 'Query execution error', details: err.message });
        }
        if (!row) {
          return res.status(404).json({ error: 'User not found' });
        }
        res.status(200).json({ data: row });
      });
    });

    app.put('/api/v1/users/:id', (req, res) => {
      const { status } = req.body;
      const sql = 'UPDATE users SET status = ? WHERE id = ?';
      db.run(sql, [status, req.params.id], function(err) {
        if (err) {
          return res.status(500).json({ error: 'Update failed', details: err.message });
        }
        if (this.changes === 0) {
          return res.status(404).json({ error: 'Target user record not found' });
        }
        res.status(200).json({ updated: this.changes });
      });
    });

    app.delete('/api/v1/users/:id', (req, res) => {
      const sql = 'DELETE FROM users WHERE id = ?';
      db.run(sql, [req.params.id], function(err) {
        if (err) {
          return res.status(500).json({ error: 'Delete execution failed', details: err.message });
        }
        if (this.changes === 0) {
          return res.status(404).json({ error: 'Target user record not found' });
        }
        res.status(200).json({ deleted: this.changes });
      });
    });

    const PORT = 3000;
    app.listen(PORT, () => {
      console.log(`Production API Server listening on port ${PORT}`);
    });
```

---

### 3.2 Enterprise Node.js Database Module (`db-client.js`)
This standalone database abstraction layer implements a Promisified API around the asynchronous `sqlite3` driver, establishing connection lifecycle management, transaction control, parameterized execution safety, and robust error handling.

```javascript
/**
 * Production SQLite Database Client Wrapper
 * Implements Promisified SQLite operations with WAL tuning, transaction handling,
 * and Parameterized Query interfaces to prevent SQL injection.
 */

const sqlite3 = require('sqlite3').verbose();
const path = require('path');

class DatabaseClient {
  constructor(dbPath) {
    this.dbPath = dbPath || process.env.DB_FILE_PATH || './production.db';
    this.db = null;
  }

  /**
   * Initializes connection and sets WAL Pragma options
   */
  async connect() {
    return new Promise((resolve, reject) => {
      this.db = new sqlite3.Database(this.dbPath, (err) => {
        if (err) {
          return reject(new Error(`Failed to open database [${this.dbPath}]: ${err.message}`));
        }
        
        // Configure engine settings for high availability & concurrency
        this.db.configure('busyTimeout', 5000);
        
        this.db.serialize(() => {
          this.db.run('PRAGMA journal_mode = WAL;');
          this.db.run('PRAGMA synchronous = NORMAL;');
          this.db.run('PRAGMA foreign_keys = ON;', (pragmaErr) => {
            if (pragmaErr) return reject(pragmaErr);
            resolve(true);
          });
        });
      });
    });
  }

  /**
   * Executes DDL or DML statements (INSERT, UPDATE, DELETE)
   * Returns metadata including lastID and changes count.
   */
  run(sql, params = []) {
    return new Promise((resolve, reject) => {
      this.db.run(sql, params, function (err) {
        if (err) {
          return reject(new Error(`SQL Run Execution Failure: ${err.message} | SQL: ${sql}`));
        }
        resolve({ lastID: this.lastID, changes: this.changes });
      });
    });
  }

  /**
   * Fetches a single record matching the query
   */
  get(sql, params = []) {
    return new Promise((resolve, reject) => {
      this.db.get(sql, params, (err, row) => {
        if (err) {
          return reject(new Error(`SQL Get Execution Failure: ${err.message} | SQL: ${sql}`));
        }
        resolve(row || null);
      });
    });
  }

  /**
   * Fetches all matching records
   */
  all(sql, params = []) {
    return new Promise((resolve, reject) => {
      this.db.all(sql, params, (err, rows) => {
        if (err) {
          return reject(new Error(`SQL All Execution Failure: ${err.message} | SQL: ${sql}`));
        }
        resolve(rows);
      });
    });
  }

  /**
   * Wraps operations inside an explicit database transaction
   */
  async transaction(actionCallback) {
    await this.run('BEGIN TRANSACTION;');
    try {
      const result = await actionCallback(this);
      await this.run('COMMIT;');
      return result;
    } catch (error) {
      await this.run('ROLLBACK;');
      throw new Error(`Transaction aborted and rolled back. Cause: ${error.message}`);
    }
  }

  /**
   * Gracefully shuts down database file handles
   */
  close() {
    return new Promise((resolve, reject) => {
      if (!this.db) return resolve();
      this.db.close((err) => {
        if (err) return reject(err);
        resolve(true);
      });
    });
  }
}

module.exports = DatabaseClient;
```

---

## 4. Real CLI Commands & Terminal Outputs ($)

### 4.1 CLI Database Creation & Schema Inspection via `sqlite3`

```bash
$ sqlite3 /var/lib/data/production.db
```
```
SQLite version 3.42.0 2023-05-16 12:36:15
Enter ".help" for usage hints.
sqlite> PRAGMA journal_mode=WAL;
wal
sqlite> CREATE TABLE users (
   ...>   id INTEGER PRIMARY KEY AUTOINCREMENT,
   ...>   username TEXT NOT NULL UNIQUE,
   ...>   email TEXT NOT NULL UNIQUE,
   ...>   status TEXT CHECK(status IN ('active', 'suspended', 'pending')) DEFAULT 'pending',
   ...>   created_at DATETIME DEFAULT CURRENT_TIMESTAMP
   ...> );
sqlite> .schema users
CREATE TABLE users (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  username TEXT NOT NULL UNIQUE,
  email TEXT NOT NULL UNIQUE,
  status TEXT CHECK(status IN ('active', 'suspended', 'pending')) DEFAULT 'pending',
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
sqlite> .tables
users
sqlite> .exit
```

---

### 4.2 CRUD Command Execution and Terminal Output Verification

```bash
$ sqlite3 /var/lib/data/production.db "INSERT INTO users (username, email, status) VALUES ('sre_admin', 'admin@platform.internal', 'active');"
$ sqlite3 /var/lib/data/production.db "INSERT INTO users (username, email, status) VALUES ('dev_user', 'dev@platform.internal', 'pending');"
```

```bash
$ sqlite3 -header -column /var/lib/data/production.db "SELECT id, username, email, status, created_at FROM users;"
```
```
id  username   email                    status  created_at         
--  ---------  -----------------------  ------  -------------------
1   sre_admin  admin@platform.internal  active  2026-08-07 03:30:12
2   dev_user   dev@platform.internal    pending 2026-08-07 03:30:45
```

```bash
$ sqlite3 /var/lib/data/production.db "UPDATE users SET status = 'active' WHERE username = 'dev_user';"
$ sqlite3 -header -column /var/lib/data/production.db "SELECT id, username, status FROM users WHERE username = 'dev_user';"
```
```
id  username  status
--  --------  ------
2   dev_user  active
```

```bash
$ sqlite3 /var/lib/data/production.db "DELETE FROM users WHERE id = 2;"
$ sqlite3 -header -column /var/lib/data/production.db "SELECT COUNT(*) AS total_users FROM users;"
```
```
total_users
-----------
1
```

---

### 4.3 Kubernetes Operational Commands & Runtime Log Extraction

```bash
$ kubectl apply -f k8s-production-db-app.yaml
```
```
namespace/production-data-tier created
configmap/app-db-config created
persistentvolumeclaim/sqlite-pvc created
deployment.apps/nodejs-sql-api created
configmap/app-source-code created
```

```bash
$ kubectl get pods -n production-data-tier -o wide
```
```
NAME                             READY   STATUS    RESTARTS   AGE   IP           NODE
nodejs-sql-api-6b69446d4-x9qzp   1/1     Running   0          42s   10.244.1.15  node-01
```

```bash
$ kubectl logs -n production-data-tier deployment/nodejs-sql-api -c api-server
```
```
Successfully connected to SQLite engine at /var/lib/data/production.db
Database schema verified successfully.
Production API Server listening on port 3000
```

---

## 5. Verification, Diagnostic Workflows & Failure Troubleshooting

```
              +-------------------------------------------------+
              |     Database / Application Failure Observed     |
              +-------------------------------------------------+
                                       |
                       +---------------+---------------+
                       |                               |
        [HTTP 500 / SQLITE_BUSY]             [Constraint Violation]
                       |                               |
       +-------------------------------+   +-------------------------------+
       | Check Lock State & WAL Mode   |   | Test Input Sanitization       |
       | - Check file locks via fcntl  |   | - Execute parameterized query |
       | - Execute PRAGMA compile_opt  |   | - Verify schema bounds        |
       +-------------------------------+   +-------------------------------+
                       |                               |
                       +---------------+---------------+
                                       |
                       +-------------------------------+
                       | Remediate & Re-verify Service |
                       +-------------------------------+
```

### 5.1 Troubleshooting `SQLITE_BUSY: database is locked`

#### Root Cause:
When multiple Node.js workers write concurrently to SQLite running in `DELETE` journal mode, exclusive file-level locks cause secondary write attempts to instantly throw `SQLITE_BUSY` errors.

#### Diagnostic Commands:
Inspect the database header journal mode via CLI:
```bash
$ sqlite3 /var/lib/data/production.db "PRAGMA journal_mode;"
```
```
delete
```

Check if active lock processes hold file descriptors:
```bash
$ lsof /var/lib/data/production.db
```
```
COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF    NODE NAME
node    12431 root    3u   REG  252,1    40960 1049281 /var/lib/data/production.db
```

#### Remediation Step:
Enable Write-Ahead Logging (WAL) mode and configure a busy timeout in application initialization:
```bash
$ sqlite3 /var/lib/data/production.db "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;"
```
```
wal
normal
```

Confirm presence of WAL auxiliary files (`.db-wal` and `.db-shm`):
```bash
$ ls -la /var/lib/data/
```
```
drwxr-xr-x 2 root root  4096 Aug  7 03:32 .
drwxr-xr-x 3 root root  4096 Aug  7 03:28 ..
-rw-r--r-- 1 root root 40960 Aug  7 03:32 production.db
-rw-r--r-- 1 root root 32768 Aug  7 03:32 production.db-shm
-rw-r--r-- 1 root root 12492 Aug  7 03:32 production.db-wal
```

---

### 5.2 SQL Injection (SQLi) Vulnerability Verification & Mitigation

#### Vulnerable Code Pattern (VULNERABLE):
```javascript
// DANGEROUS: Direct string concatenation permits SQLi
const userEmail = req.body.email; 
const query = "SELECT * FROM users WHERE email = '" + userEmail + "'";
db.get(query, [], callback);
```

#### Exploit Payload Test:
Sending payload: `' OR '1'='1`
Generated SQL statement:
```sql
SELECT * FROM users WHERE email = '' OR '1'='1';
```

Executing via cURL to test vulnerability mitigation:
```bash
$ curl -X POST http://localhost:3000/api/v1/users \
  -H "Content-Type: application/json" \
  -d '{"username": "hacker", "email": "malicious'\'' OR '\''1'\ '\''='\'1", "status": "active"}'
```

#### Secure Code Pattern (REMEDIATED):
```javascript
// SECURE: Parameterized query isolates data from execution context
const userEmail = req.body.email;
const query = "SELECT * FROM users WHERE email = ?";
db.get(query, [userEmail], callback);
```

Terminal output verifying parameterized escape safety:
```bash
$ sqlite3 -header -column /var/lib/data/production.db "SELECT id, email FROM users WHERE email = 'malicious'' OR ''1''=''1';"
```
```
(0 rows returned - string treated literally as value)
```

---

### 5.3 Database File Corruption Recovery Workflow

#### Scenario:
Unclean pod termination or disk IO truncation causes header invalidation.

#### Diagnosis:
```bash
$ sqlite3 /var/lib/data/production.db "PRAGMA quick_check;"
```
```
Error: database disk image is malformed
```

#### Emergency Recovery Steps:
1. Dump surviving SQL operations into a recovery file:
```bash
$ sqlite3 /var/lib/data/production.db ".dump" > /tmp/corrupted_dump.sql
```
2. Re-create a clean database from the SQL dump file:
```bash
$ sqlite3 /var/lib/data/production_recovered.db < /tmp/corrupted_dump.sql
```
3. Verify integrity of the recovered database:
```bash
$ sqlite3 /var/lib/data/production_recovered.db "PRAGMA integrity_check;"
```
```
ok
```
4. Atomic swap recovered database file into production path:
```bash
$ mv /var/lib/data/production_recovered.db /var/lib/data/production.db
```

---

## 6. References & Official Documentation

- **LPI Web Development Essentials Overview**:  
  https://www.lpi.org/our-certifications/web-development-essentials-overview/

- **LPI Web Development Essentials Official Exam Objectives v1.0**:  
  https://wiki.lpi.org/wiki/Web_Development_Essentials_Objectives_V1.0

- **SQLite Official Write-Ahead Logging (WAL) Architecture Guide**:  
  https://www.sqlite.org/wal.html

- **Node.js `sqlite3` Driver API Documentation**:  
  https://github.com/TryGhost/node-sqlite3/wiki/API

- **OWASP SQL Injection Prevention Cheat Sheet**:  
  https://cheatsheetseries.owasp.org/cheatsheets/SQL_Injection_Prevention_Cheat_Sheet.html