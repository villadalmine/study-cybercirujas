# LPI 030-100 (v1.0) Tema 5.3: SQL Basics & Database Integration
## Guía de Estudio de Producción para SRE & Platform Architecture (Peso en el examen: 7.5)

---

## 1. Motivación Arquitectónica de Producción & Planteamiento del Problema

### 1.1 El Desafío del Estado Empresarial en la Arquitectura de Aplicaciones Stateless
Las arquitecturas web modernas separan el estado de ejecución del almacenamiento persistente. Mientras los microservicios de Node.js operan de forma stateless detrás de load balancers en la nube, el almacenamiento subyacente debe preservar la durabilidad de los datos, la integridad transaccional y la linearizabilidad en entornos de alta concurrencia.

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

### 1.2 Modos de Falla Estructural en Interfaces de Base de Datos No Mitigadas
Al conectar runtimes de aplicaciones asíncronas (como Node.js) con motores de bases de datos relacionales, surgen tres vectores críticos de falla en entornos de producción:

1. **Vulnerabilidades de SQL Injection (SQLi)**: La interpolación dinámica directa de cadenas dentro de consultas raw permite a atacantes no autenticados escapar de los límites de entrada, manipular árboles de sintaxis abstracta (AST), eludir filtros de autenticación o ejecutar comandos arbitrarios de borrado de datos (`DROP TABLE`, `UNION SELECT`).
2. **Concurrencia & Contención de Threads (Bloqueo de Archivos & Agotamiento del Pool)**: 
   - Los motores embebidos (por ejemplo, SQLite) utilizan por defecto modos de rollback journal que obtienen bloqueos de escritura exclusivos sobre la base de datos. Las escrituras paralelas de alta frecuencia activan errores `SQLITE_BUSY` y provocan el agotamiento de threads en el event loop de la aplicación.
   - Los motores cliente-servidor (por ejemplo, PostgreSQL/MySQL) pueden experimentar starvation en el connection pool cuando los Pods de la aplicación abren sockets no gestionados sin timeouts ni límites en la cantidad de conexiones.
3. **Integridad de Datos & Corrupción**: Las restricciones de base de datos no aplicadas (`NOT NULL`, `UNIQUE`, `PRIMARY KEY`, `FOREIGN KEY`) delegan la validación de integridad a la capa de aplicación. En despliegues multi-pod, las peticiones concurrentes superan las comprobaciones de validación de la aplicación, insertando registros duplicados u huérfanos.

---

## 2. Tablas de Comparativas Técnicas & Balance de Arquitectura (Trade-offs)

### 2.1 Motor Relacional Embebido (SQLite) vs. Motor Cliente-Servidor (PostgreSQL/MySQL)

| Característica / Métrica | SQLite (Motor Embebido) | PostgreSQL / MySQL (Cliente-Servidor) |
| :--- | :--- | :--- |
| **Arquitectura** | Librería embebida en un solo archivo dentro del proceso de la aplicación | Daemon independiente multiproceso al que se accede mediante IPC/TCP-IP |
| **Concurrencia de Escritura** | Bloqueo de proceso de un solo escritor (Mitigado mediante modo WAL) | Bloqueo a nivel de fila multiescritor (MVCC - Control de Concurrencia Multiversión) |
| **Overhead de Red** | 0 ms de latencia de red (Memoria directa / NVMe POSIX I/O) | 1-5 ms de overhead en la red local por ida y vuelta de la consulta |
| **Complejidad de Despliegue** | Baja (Cero dependencias externas, montaje en disco local) | Alta (Requiere orquestación stateful, replica sets, proxies de conexión) |
| **Caso de Uso Ideal en Producción** | Nodos edge, APIs de alta lectura, herramientas CLI, caching local | OLTP empresarial de alta concurrencia, aplicaciones web multirregionales |

### 2.2 Concatenación Dinámica de Cadenas vs. Consultas Parametrizadas (Prepared Statements)

| Parámetro | Concatenación Dinámica de Consultas | Sentencias Parametrizadas (`?` / `$1`) |
| :--- | :--- | :--- |
| **Parsing del AST** | Se re-analiza en cada ejecución; el código de la consulta se fusiona con los datos | Se analiza y compila una sola vez; los parámetros se vinculan por separado |
| **Protección contra SQLi** | **Ninguna**. Los valores de entrada alteran la ruta de ejecución de la consulta | **Completa**. La entrada del usuario se trata estrictamente como literales de datos |
| **Reutilización del Plan de Consulta** | Baja (Una cadena única genera un hash único en la caché de consultas) | Alta (El AST precompilado se reutiliza en ejecuciones con variables) |
| **Estándar de Cumplimiento** | Incumple OWASP Top 10 A03:2021 (Inyección) | Cumple con los controles de PCI-DSS 6.5.1 y NIST SP 800-53 |

### 2.3 Garantías ACID en Sistemas Relacionales de Producción

| Garantías | Mecanismo | Impacto Operacional en SRE |
| :--- | :--- | :--- |
| **Atomicidad** | Logs de deshacer (Undo logs) / Write-Ahead Logging (WAL) | Garantiza que las transacciones con múltiples sentencias fallen de forma limpia sin escrituras parciales. |
| **Consistencia** | Restricciones de Schema, Foreign Keys, Índices | Previene estados inválidos a nivel de motor independientemente de los bugs de la aplicación. |
| **Aislamiento** | Gestores de Bloqueo / Aislamiento por Snapshots (MVCC) | Evita Dirty Reads, Non-Repeatable Reads y Phantom Reads. |
| **Durabilidad** | Vaciado con `fsync()` a almacenamiento no volátil | Garantiza que las transacciones confirmadas (committed) sobrevivan a caídas del kernel del host o fallos de energía. |

---

## 3. Manifiestos & Archivos de Infraestructura Completos y de Sintaxis Válida

### 3.1 Despliegue de Infraestructura (`k8s-production-db-app.yaml`)
Este manifiesto de Kubernetes de nivel de producción despliega una aplicación stateless de Node.js junto con almacenamiento en volúmenes persistentes para la gestión del estado de la base de datos, incorporando probes de liveness/readiness, límites de recursos y mapas de configuración montados.

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

### 3.2 Módulo de Base de Datos Enterprise para Node.js (`db-client.js`)
Esta capa de abstracción de base de datos independiente implementa una API basada en Promesas (Promisified) alrededor del driver asíncrono `sqlite3`, estableciendo la gestión del ciclo de vida de la conexión, control de transacciones, seguridad en la ejecución parametrizada y un manejo de errores robusto.

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

## 4. Comandos Reales de CLI & Salidas de Terminal ($)

### 4.1 Creación de Base de Datos e Inspección de Schema mediante CLI con `sqlite3`

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

### 4.2 Ejecución de Comandos CRUD y Verificación de Salida en Terminal

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

### 4.3 Comandos Operacionales de Kubernetes & Extracción de Logs en Tiempo de Ejecución

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

## 5. Verificación, Flujos de Trabajo Diagnósticos & Solución de Fallas (Troubleshooting)

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

### 5.1 Solución del Error `SQLITE_BUSY: database is locked`

#### Causa Raíz:
Cuando múltiples workers de Node.js escriben de forma concurrente en SQLite ejecutándose en modo journal `DELETE`, los bloqueos exclusivos a nivel de archivo provocan que los intentos de escritura secundarios arrojen instantáneamente errores `SQLITE_BUSY`.

#### Comandos de Diagnóstico:
Inspeccionar el modo journal en el encabezado de la base de datos a través de la CLI:
```bash
$ sqlite3 /var/lib/data/production.db "PRAGMA journal_mode;"
```
```
delete
```

Verificar si hay procesos de bloqueo activos manteniendo file descriptors:
```bash
$ lsof /var/lib/data/production.db
```
```
COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF    NODE NAME
node    12431 root    3u   REG  252,1    40960 1049281 /var/lib/data/production.db
```

#### Paso de Remediación:
Habilitar el modo Write-Ahead Logging (WAL) y configurar un busy timeout en la inicialización de la aplicación:
```bash
$ sqlite3 /var/lib/data/production.db "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;"
```
```
wal
normal
```

Confirmar la presencia de los archivos auxiliares WAL (`.db-wal` y `.db-shm`):
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

### 5.2 Verificación & Mitigación de Vulnerabilidades de SQL Injection (SQLi)

#### Patrón de Código Vulnerable (VULNERABLE):
```javascript
// DANGEROUS: Direct string concatenation permits SQLi
const userEmail = req.body.email; 
const query = "SELECT * FROM users WHERE email = '" + userEmail + "'";
db.get(query, [], callback);
```

#### Prueba de Carga Útil (Payload Exploit):
Enviando payload: `' OR '1'='1`
Sentencia SQL generada:
```sql
SELECT * FROM users WHERE email = '' OR '1'='1';
```

Ejecutando a través de cURL para probar la mitigación de la vulnerabilidad:
```bash
$ curl -X POST http://localhost:3000/api/v1/users \
  -H "Content-Type: application/json" \
  -d '{"username": "hacker", "email": "malicious'\'' OR '\''1'\ '\''='\'1", "status": "active"}'
```

#### Patrón de Código Seguro (REMEDIADO):
```javascript
// SECURE: Parameterized query isolates data from execution context
const userEmail = req.body.email;
const query = "SELECT * FROM users WHERE email = ?";
db.get(query, [userEmail], callback);
```

Salida de terminal que verifica la seguridad del escape parametrizado:
```bash
$ sqlite3 -header -column /var/lib/data/production.db "SELECT id, email FROM users WHERE email = 'malicious'' OR ''1''=''1';"
```
```
(0 rows returned - string treated literally as value)
```

---

### 5.3 Flujo de Trabajo de Recuperación ante Corrupción de Archivos de Base de Datos

#### Escenario:
La terminación abrupta de un Pod o la truncación de I/O en disco causa la invalidación del encabezado.

#### Diagnóstico:
```bash
$ sqlite3 /var/lib/data/production.db "PRAGMA quick_check;"
```
```
Error: database disk image is malformed
```

#### Pasos de Recuperación de Emergencia:
1. Volcar (dump) las operaciones SQL supervivientes en un archivo de recuperación:
```bash
$ sqlite3 /var/lib/data/production.db ".dump" > /tmp/corrupted_dump.sql
```
2. Recrear una base de datos limpia a partir del archivo dump de SQL:
```bash
$ sqlite3 /var/lib/data/production_recovered.db < /tmp/corrupted_dump.sql
```
3. Verificar la integridad de la base de datos recuperada:
```bash
$ sqlite3 /var/lib/data/production_recovered.db "PRAGMA integrity_check;"
```
```
ok
```
4. Intercambio atómico (atomic swap) del archivo de base de datos recuperado a la ruta de producción:
```bash
$ mv /var/lib/data/production_recovered.db /var/lib/data/production.db
```

---

## 6. Referencias & Documentación Oficial

- **Visión General de LPI Web Development Essentials**:  
  https://www.lpi.org/our-certifications/web-development-essentials-overview/

- **Objetivos Oficiales del Examen LPI Web Development Essentials v1.0**:  
  https://wiki.lpi.org/wiki/Web_Development_Essentials_Objectives_V1.0

- **Guía Oficial de Arquitectura Write-Ahead Logging (WAL) de SQLite**:  
  https://www.sqlite.org/wal.html

- **Documentación de la API del Driver `sqlite3` para Node.js**:  
  https://github.com/TryGhost/node-sqlite3/wiki/API

- **Cheat Sheet de Prevención de SQL Injection de OWASP**:  
  https://cheatsheetseries.owasp.org/cheatsheets/SQL_Injection_Prevention_Cheat_Sheet.html