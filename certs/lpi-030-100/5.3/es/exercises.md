# LPI 030-100 (v1.0) — Tema 5.3: SQL Basics

**Objetivo del examen:** LPI Web Development Essentials (Código de examen 030-100, Versión 1.0)  
**Código del tema:** 035.3 / Tema 5.3: SQL Basics  
**Peso del examen:** 7.5  
**Fuentes de referencia oficiales:**  
*   [LPI Web Development Essentials Overview](https://www.lpi.org/our-certifications/web-development-essentials-overview/)  
*   [LPI Learning Materials — 030-100 Objective 035.3](https://learning.lpi.org/en/learning-materials/030-100/)  
*   [SQLite Official Documentation & Architecture](https://www.sqlite.org/docs.html)  

---

## 1. Production Architecture & Internal Mechanics

### 1.1 Embedded Engine Architecture vs. Client-Server RDBMS
En entornos de producción de aplicaciones web, las bases de datos operan bajo dos paradigmas principales:
1. **Embedded Databases (ej., SQLite):** El motor RDBMS se ejecuta dentro del espacio de memoria del proceso de la aplicación. No hay socket de red, overhead de inter-process communication (IPC) ni handshake cliente-servidor. Las operaciones de lectura se mapean directamente a páginas del sistema de archivos mapeadas en memoria (`mmap`), proporcionando latencias de consulta sub-microsegundo.
2. **Client-Server RDBMS (ej., PostgreSQL, MariaDB/MySQL):** Las consultas viajan a través de sockets TCP/IP hacia un proceso daemon dedicado. Esta arquitectura aisla el almacenamiento de los fallos de la aplicación y escala horizontalmente, pero introduce latencia de red, overhead de connection pooling y serialización compleja.

```
       [ Client-Server Architecture ]                     [ Embedded Architecture ]
+-------------------+     TCP/IP Socket     +-------+    +---------------------------------+
| Node.js Web App   | <-------------------> | MySQL |    | Node.js Web App Process Space   |
| (Process 1042)    |   (Port 3306 / IPC)   | Daemon|    |  +---------------------------+  |
+-------------------+                       +-------+    |  | SQLite Engine (In-Memory) |  |
                                                         |  +---------------------------+  |
                                                         |              | Direct VFS I/O   |
                                                         |              v                  |
                                                         |    [ production_app.db ]        |
                                                         +---------------------------------+
```

### 1.2 Storage Mechanics, Locking, and Journaling
SQLite estructura los datos dentro de representaciones en disco de un solo archivo utilizando páginas de tamaño fijo (típicamente 4096 bytes). 
*   **Diseño B-Tree & B+Tree:** Los datos de la tabla se almacenan en estructuras B-Tree donde los nodos hoja almacenan los payloads de datos, mientras que las páginas de índice usan B+Trees para mapear claves a identificadores de fila (`ROWID`).
*   **Rollback Journal vs. Write-Ahead Logging (WAL):**
    *   *Rollback Journal (por defecto):* Modifica páginas directamente en el archivo principal de la base de datos después de copiar las páginas originales sin modificar en un archivo `.db-journal`. Durante una transacción de escritura, un bloqueo `EXCLUSIVE` previene a todos los lectores concurrentes.
    *   *Modo WAL (`PRAGMA journal_mode=WAL;`):* Anexa nuevas escrituras a un archivo `-wal` separado. Las páginas de la base de datos original permanecen intactas. Los lectores no bloquean a los escritores y los escritores no bloquean a los lectores. Un lector concurrente accede a un snapshot de la base de datos combinando páginas sin cambios del archivo principal con páginas actualizadas en el índice WAL (`-shm`).

```
                    Write-Ahead Logging (WAL) Architecture

                             +-----------------------+
                             |   Active DB Pages     |
                             |  (production_app.db)  |
                             +-----------------------+
                                         ^
                                         | Read Unmodified Pages
+-----------------------+                |                +-----------------------+
|   Concurrent Reader   | ---------------+--------------->|   Concurrent Writer   |
+-----------------------+                                 +-----------------------+
            |                                                         |
            | Read Latest Snapshot                                    | Append New Writes
            v                                                         v
+-----------------------+                                 +-----------------------+
| Shared Memory Index   | <-------------------------------+ |   WAL Journal File    |
| (production_app.db-shm)|                                 | (production_app.db-wal)|
+-----------------------+                                 +-----------------------+
```

### 1.3 Abstract Syntax Tree (AST) Parsing & SQL Injection Prevention
Cuando un motor de base de datos procesa un string de consulta:
1. **Tokenizer & Lexer:** Divide las cadenas de entrada ASCII/UTF-8 en bruto en tokens léxicos (`SELECT`, `FROM`, `WHERE`, identificadores, literales).
2. **Parser:** Construye un Abstract Syntax Tree (AST) validando la sintaxis gramatical.
3. **Query Optimizer:** Traduce el AST en instrucciones bytecode ejecutadas por la Virtual Database Engine (VDBE).

**Causa raíz mecánica de SQL Injection (SQLi):**  
La concatenación dinámica de strings fusiona la entrada del usuario en la estructura del comando SQL *antes* de la generación del AST. Un payload que contenga delimitadores de cadena o palabras clave SQL altera la estructura del propio AST.

```
Dynamic Query Concatenation (Vulnerable):
"SELECT * FROM users WHERE email = '" + userInput + "';"

User Input: admin@example.com' OR '1'='1
Resulting AST Mutation:
        [SELECT]
       /        \
   [users]     [OR]
              /    \
         [=]        [=]
        /   \      /   \
    email  admin  '1'  '1'  <-- Structural branch added to AST!
```

**Mecánica de prevención con Prepared Statement / Parameterized Query:**  
Las Parameterized queries dividen la ejecución en dos pasos aislados:
1. El motor compila el esqueleto de la consulta en un AST y bytecode VDBE utilizando placeholders para parámetros (`?` o `$1`).
2. Los parámetros se vinculan directamente a registros de memoria VDBE preasignados. El string de entrada se trata estrictamente como un valor de datos escalar, omitiendo por completo el Lexer y el Parser. La estructura del AST permanece inmutable independientemente del contenido de la entrada.

---

## 2. Guided Hands-On Lab Exercises

### System Prerequisites
Asegurate de que `sqlite3` y `node` estén instalados en tu máquina Linux antes de comenzar:
```bash
sudo apt-get update && sudo apt-get install -y sqlite3 nodejs npm
```

---

### Lab Block 1: DDL Table Creation, Schema Constraints, and Metadata Diagnostics

En este bloque, construirás un esquema de base de datos de producción para un módulo de usuarios de una aplicación web utilizando comandos de Data Definition Language (DDL), inspeccionarás los metadatos del motor de almacenamiento y ejecutarás alteraciones del esquema.

#### Steps to Execute

1. Abrí una terminal y creá un directorio de trabajo dedicado, luego inicializá una base de datos SQLite llamada `platform_prod.db`:
```bash
mkdir -p ~/lpi_sql_lab && cd ~/lpi_sql_lab
sqlite3 platform_prod.db
```
*Prompt de terminal esperado:* `sqlite>`

2. Habilitá el modo WAL y la aplicación de restricciones de foreign key:
```sql
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;
```
*Salida esperada:*
```
wal
```

3. Creá la tabla `users` con tipos de datos estrictos, primary key autoincremental, marcas de tiempo por defecto y restricciones de unicidad:
```sql
CREATE TABLE IF NOT EXISTS users (
    user_id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT NOT NULL UNIQUE,
    email TEXT NOT NULL UNIQUE,
    account_balance REAL DEFAULT 0.00,
    is_active INTEGER NOT NULL CHECK (is_active IN (0, 1)) DEFAULT 1,
    created_at TEXT NOT NULL DEFAULT (CURRENT_TIMESTAMP)
);
```

4. Verificá la creación de la tabla utilizando metacomandos internos de la CLI de SQLite:
```text
.schema users
.tables
```
*Salida esperada:*
```sql
CREATE TABLE users (
    user_id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT NOT NULL UNIQUE,
    email TEXT NOT NULL UNIQUE,
    account_balance REAL DEFAULT 0.00,
    is_active INTEGER NOT NULL CHECK (is_active IN (0, 1)) DEFAULT 1,
    created_at TEXT NOT NULL DEFAULT (CURRENT_TIMESTAMP)
);
users
```

5. Modificá el esquema agregando una columna `last_login`, luego eliminá una tabla de prueba temporal:
```sql
ALTER TABLE users ADD COLUMN last_login TEXT;

CREATE TABLE temp_scratch (id INT);
DROP TABLE IF EXISTS temp_scratch;
```

6. Confirmá la estructura de la tabla actualizada:
```text
.schema users
```
*Salida esperada:*
```sql
CREATE TABLE users (
    user_id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT NOT NULL UNIQUE,
    email TEXT NOT NULL UNIQUE,
    account_balance REAL DEFAULT 0.00,
    is_active INTEGER NOT NULL CHECK (is_active IN (0, 1)) DEFAULT 1,
    created_at TEXT NOT NULL DEFAULT (CURRENT_TIMESTAMP)
, last_login TEXT);
```

#### Verification Questions (Block 1)

1. **Pregunta 1.1:** ¿Por qué `user_id INTEGER PRIMARY KEY AUTOINCREMENT` se trata de manera especial en SQLite en comparación con las declaraciones de columnas estándar? ¿Qué sucede con el `ROWID` interno?
2. **Pregunta 1.2:** Si una aplicación intenta ejecutar `INSERT INTO users (username, email, is_active) VALUES ('dev_user', 'dev@example.com', 5);`, ¿qué error específico del motor se lanzará y por qué?

---

### Lab Block 2: DML Data Manipulation, Filtering, and Execution Plan Analysis

En este bloque, ejecutarás operaciones de Data Manipulation Language (DML) (`INSERT`, `SELECT`, `UPDATE`, `DELETE`), implementarás filtrado/ordenamiento/paginación de consultas y analizarás las rutas de ejecución de consultas utilizando `EXPLAIN QUERY PLAN`.

#### Steps to Execute

1. Insertá datos de prueba de producción en la tabla `users`:
```sql
INSERT INTO users (username, email, account_balance) VALUES
('alice_sre', 'alice@platform.io', 1250.50),
('bob_dev', 'bob@platform.io', 450.00),
('charlie_arch', 'charlie@platform.io', 3200.75),
('david_sec', 'david@platform.io', 890.20),
('eve_ops', 'eve@platform.io', 0.00);
```

2. Formateá los encabezados y la disposición de la salida CLI para una inspección de diagnóstico clara:
```text
.mode column
.headers on
```

3. Consultá usuarios activos con un `account_balance` mayor a $500.00, ordenados por saldo de forma descendente, limitados a 2 registros:
```sql
SELECT user_id, username, email, account_balance 
FROM users 
WHERE is_active = 1 AND account_balance > 500.00 
ORDER BY account_balance DESC 
LIMIT 2;
```
*Salida esperada:*
```text
user_id  username      email                account_balance
-------  ------------  -------------------  ---------------
3        charlie_arch  charlie@platform.io  3200.75        
1        alice_sre     alice@platform.io    1250.5         
```

4. Realizá una coincidencia de patrones usando `LIKE` para encontrar todas las cuentas bajo el dominio `platform.io` con nombres de usuario que comiencen con `a` o `b`:
```sql
SELECT user_id, username, email 
FROM users 
WHERE email LIKE '%@platform.io' 
  AND (username LIKE 'a%' OR username LIKE 'b%');
```
*Salida esperada:*
```text
user_id  username   email            
-------  ---------  -----------------
1        alice_sre  alice@platform.io
2        bob_dev    bob@platform.io  
```

5. Actualizá el saldo de `bob_dev` de forma atómica y establecé `last_login`:
```sql
UPDATE users 
SET account_balance = account_balance + 150.00, 
    last_login = CURRENT_TIMESTAMP 
WHERE username = 'bob_dev';
```

6. Eliminá cuentas de prueba operacionales inactivas o con saldo cero (`eve_ops`):
```sql
DELETE FROM users 
WHERE account_balance = 0.00 AND username = 'eve_ops';
```

7. Analizá el plan de ejecución de la consulta para el filtrado por `username` antes y después de crear un índice B-Tree:
```sql
EXPLAIN QUERY PLAN SELECT * FROM users WHERE username = 'alice_sre';
```
*Salida esperada:*
```text
QUERY PLAN
`--SEARCH users USING INDEX sqlite_autoindex_users_1 (username=?)
```
*(Nota: SQLite creó automáticamente un índice único `sqlite_autoindex_users_1` cuando se declaró la restricción `UNIQUE` en `username`).*

8. Probá el plan de ejecución en una columna no indexada (`account_balance`):
```sql
EXPLAIN QUERY PLAN SELECT * FROM users WHERE account_balance = 450.00;
```
*Salida esperada:*
```text
QUERY PLAN
`--SCAN users
```

9. Creá un índice B-Tree explícito en `account_balance` y volvé a verificar el plan de ejecución:
```sql
CREATE INDEX idx_users_balance ON users(account_balance);
EXPLAIN QUERY PLAN SELECT * FROM users WHERE account_balance = 450.00;
```
*Salida esperada:*
```text
QUERY PLAN
`--SEARCH users USING INDEX idx_users_balance (account_balance=?)
```

10. Salí de la herramienta CLI de SQLite:
```sql
.quit
```

#### Verification Questions (Block 2)

1. **Pregunta 2.1:** ¿Cuál es la diferencia fundamental de rendimiento entre `SCAN users` y `SEARCH users USING INDEX` en el diagnóstico de rendimiento de bases de datos?
2. **Pregunta 2.2:** ¿Qué anomalía de datos potencial ocurre si se ejecuta un comando `UPDATE` sin una cláusula `WHERE` en un entorno de producción?

---

### Lab Block 3: Transaction Control (ACID) and Node.js Database Integration

En este bloque, implementarás transacciones ACID explícitas (`BEGIN`, `COMMIT`, `ROLLBACK`) y escribirás un script de integración de backend web en Node.js ejecutando consultas SQL parametrizadas para prevenir vulnerabilidades de SQL Injection.

#### Steps to Execute

1. Volvé a abrir `sqlite3 platform_prod.db` para probar la mecánica de rollback de transacciones atómicas:
```bash
sqlite3 platform_prod.db
```

2. Iniciá una transacción, ejecutá una deducción de saldo especulativa, verificá el estado y emití un `ROLLBACK`:
```sql
BEGIN TRANSACTION;
UPDATE users SET account_balance = account_balance - 500.00 WHERE username = 'alice_sre';
SELECT username, account_balance FROM users WHERE username = 'alice_sre';
ROLLBACK;
```
*Salida esperada durante la transacción:*
```text
username   account_balance
---------  ---------------
alice_sre  750.5          
```

3. Verificá que el saldo de `alice_sre` se haya restaurado por completo después del rollback:
```sql
SELECT username, account_balance FROM users WHERE username = 'alice_sre';
.quit
```
*Salida esperada después del rollback:*
```text
username   account_balance
---------  ---------------
alice_sre  1250.5         
```

4. Inicializá un módulo backend de Node.js en tu espacio de trabajo:
```bash
cd ~/lpi_sql_lab
npm init -y
npm install sqlite3
```

5. Creá un archivo de interfaz de base de datos de nivel de producción llamado `db_service.js`:
```bash
cat << 'EOF' > db_service.js
const sqlite3 = require('sqlite3').verbose();
const path = require('path');

const dbPath = path.resolve(__dirname, 'platform_prod.db');
const db = new sqlite3.Database(dbPath, sqlite3.OPEN_READWRITE, (err) => {
    if (err) {
        console.error('Fatal: Failed to connect to SQLite database:', err.message);
        process.exit(1);
    }
    console.log('[SUCCESS] Connected to SQLite platform_prod.db');
});

// Function using Parameterized Statements (Secure against SQL Injection)
function getUserByUsername(username) {
    const sql = `SELECT user_id, username, email, account_balance FROM users WHERE username = ?`;
    
    db.get(sql, [username], (err, row) => {
        if (err) {
            console.error('[ERROR] Query execution failed:', err.message);
            return;
        }
        if (row) {
            console.log('[DATA RETRIEVED]', row);
        } else {
            console.log('[WARN] No record found for username:', username);
        }
    });
}

// Test secure lookup with standard input
console.log('--- Test 1: Standard Lookup ---');
getUserByUsername('charlie_arch');

// Test secure lookup with malicious SQL Injection payload
console.log('--- Test 2: SQL Injection Attack Simulation ---');
const maliciousPayload = "' OR '1'='1";
getUserByUsername(maliciousPayload);

// Graceful cleanup
setTimeout(() => {
    db.close((err) => {
        if (err) console.error(err.message);
        console.log('[SUCCESS] Database connection pool closed cleanly.');
    });
}, 1000);
EOF
```

6. Ejecutá el servicio de base de datos Node.js:
```bash
node db_service.js
```
*Salida de terminal esperada:*
```text
[SUCCESS] Connected to SQLite platform_prod.db
--- Test 1: Standard Lookup ---
--- Test 2: SQL Injection Attack Simulation ---
[DATA RETRIEVED] {
  user_id: 3,
  username: 'charlie_arch',
  email: 'charlie@platform.io',
  account_balance: 3200.75
}
[WARN] No record found for username: ' OR '1'='1
[SUCCESS] Database connection pool closed cleanly.
```

#### Verification Questions (Block 3)

1. **Pregunta 3.1:** En la `Test 2`, ¿por qué la entrada `' OR '1'='1` no logró extraer todos los registros de la base de datos al ser procesada por la consulta parametrizada `db.get(sql, [username], ...)`?
2. **Pregunta 3.2:** ¿Cuáles son las ventajas y desventajas operativas (trade-offs) de usar `db.get()` vs `db.all()` vs `db.each()` en el modelo de ejecución asíncrono del driver `sqlite3` de Node.js?

---

## 4. Detailed Answer Key & Architectural Solutions

<details>
<summary>Hacé clic para desplegar las soluciones y el análisis de producción</summary>

### Respuestas del Bloque 1 y análisis de arquitectura

*   **Respuesta 1.1:**  
    En SQLite, declarar una columna como `INTEGER PRIMARY KEY` crea un alias para el `ROWID` de entero de 64 bits con signo interno que identifica de manera única a cada registro en una tabla B-Tree estándar. Agregar la palabra clave `AUTOINCREMENT` modifica el algoritmo de generación de claves:
    *   *Sin AUTOINCREMENT:* SQLite elige un `ROWID` igual al `ROWID` máximo existente más 1. Si se eliminan filas, los IDs anteriores se pueden reutilizar.
    *   *Con AUTOINCREMENT:* SQLite impone IDs estrictamente crecientes de forma monotónica mediante el seguimiento del ID asignado más alto en una tabla de sistema interna llamada `sqlite_sequence`. Nunca reutilizará una clave previamente eliminada, lo que previene vulnerabilidades sutiles de suplantación de ID (ID spoofing) en aplicaciones web.
*   **Respuesta 1.2:**  
    El motor lanzará un error de violación de restricción: `Error: CHECK constraint failed: is_active IN (0, 1)`.  
    *Mecánica:* Durante la fase de ejecución DML, SQLite valida todos los valores contra las restricciones de dominio definidas en el esquema. Dado que `5` no está presente en el conjunto `(0, 1)`, la transacción se aborta antes de alterar cualquier página de la base de datos.

---

### Respuestas del Bloque 2 y análisis de arquitectura

*   **Respuesta 2.1:**  
    *   `SCAN users` (Full Table Scan): El motor itera a través de cada página y fila individual en la tabla `users` de principio a fin. La complejidad temporal es **$\mathcal{O}(N)$**. A medida que las filas de la tabla se escalan a millones, la latencia de lectura se degrada linealmente y la I/O de CPU/disco se dispara.
    *   `SEARCH users USING INDEX` (Index Lookup): El motor realiza un recorrido en árbol de búsqueda binaria en la estructura del índice B-Tree para ubicar el puntero de clave objetivo en tiempo **$\mathcal{O}(\log N)$**, luego recupera directamente la página de datos objetivo.
*   **Respuesta 2.2:**  
    Ejecutar `UPDATE users SET account_balance = 0.00;` sin una cláusula `WHERE` aplica la mutación de saldo a **cada una de las filas** en la tabla incondicionalmente. En producción, esto causa una corrupción de datos catastrófica que requiere una recuperación en un punto en el tiempo (PITR) a partir de logs WAL o copias de seguridad.

---

### Respuestas del Bloque 3 y análisis de arquitectura

*   **Respuesta 3.1:**  
    Al usar el placeholder parametrizado `?`, el driver de Node.js y el motor de SQLite compilan la cadena SQL `SELECT ... WHERE username = ?` en bytecode fijo *antes* de recibir el payload. El string del payload `' OR '1'='1` se vincula directamente al registro de memoria del argumento. El motor busca literalmente un usuario cuya columna `username` contenga el valor de cadena verbatim `"' OR '1'='1"`. Como no existe tal usuario, la consulta devuelve de forma segura cero registros (`[WARN] No record found`).
*   **Respuesta 3.2:**  
    *   `db.get(sql, params, callback)`: Recupera **solo la primera fila que coincida** en memoria. Ideal para búsquedas de clave primaria de un solo registro (`user_id`). Altamente eficiente en memoria.
    *   `db.all(sql, params, callback)`: Recupera **todas las filas que coincidan en un array en la RAM del proceso de Node.js** a la vez. Si el conjunto de resultados contiene 500,000 filas, puede causar un desbordamiento de memoria severo o bloquear el heap de V8 con un error de `Out of Memory (OOM)`.
    *   `db.each(sql, params, rowCallback, completeCallback)`: Transmite filas que coinciden de forma secuencial, invocando `rowCallback` una vez por fila. Esencial para procesar grandes conjuntos de resultados sin agotar la memoria del heap de Node.js.

</details>

---

## 4. Verification & Summary

### Resumen de objetivos completados
1. **Arquitectura DDL:** Se diseñaron e implementaron esquemas de tablas relacionales con restricciones explícitas (`PRIMARY KEY AUTOINCREMENT`, `FOREIGN KEY`, `CHECK`, `DEFAULT`, `UNIQUE`).
2. **Mecánica DML:** Se dominó el filtrado de conjuntos de datos (`WHERE`, `LIKE`), ordenamiento (`ORDER BY`), paginación (`LIMIT`), modificaciones atómicas de datos (`UPDATE`) y eliminaciones condicionales (`DELETE`).
3. **Diagnóstico de rendimiento:** Se aprovechó `EXPLAIN QUERY PLAN` para detectar exploraciones de tablas no indexadas (`SCAN`) vs búsquedas optimizadas de B-Tree (`SEARCH USING INDEX`).
4. **Integridad y seguridad de datos:** Se ejecutaron rollbacks de transacciones ACID (`BEGIN`, `ROLLBACK`) y se aseguraron aplicaciones backend de Node.js contra SQL Injection mediante el uso de declaraciones preparadas parametrizadas (parameterized prepared statements).