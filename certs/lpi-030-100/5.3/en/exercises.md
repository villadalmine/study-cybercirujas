# LPI 030-100 (v1.0) — Topic 5.3: SQL Basics

**Exam Target:** LPI Web Development Essentials (Exam Code 030-100, Version 1.0)  
**Topic Code:** 035.3 / Topic 5.3: SQL Basics  
**Exam Weight:** 7.5  
**Official Reference Sources:**  
*   [LPI Web Development Essentials Overview](https://www.lpi.org/our-certifications/web-development-essentials-overview/)  
*   [LPI Learning Materials — 030-100 Objective 035.3](https://learning.lpi.org/en/learning-materials/030-100/)  
*   [SQLite Official Documentation & Architecture](https://www.sqlite.org/docs.html)  

---

## 1. Production Architecture & Internal Mechanics

### 1.1 Embedded Engine Architecture vs. Client-Server RDBMS
In web application production environments, databases operate under two primary paradigms:
1. **Embedded Databases (e.g., SQLite):** The RDBMS engine runs inside the application process memory space. There is no network socket, inter-process communication (IPC) overhead, or client-server handshake. Read operations map directly to memory-mapped filesystem pages (`mmap`), providing sub-microsecond query latencies.
2. **Client-Server RDBMS (e.g., PostgreSQL, MariaDB/MySQL):** Queries travel over TCP/IP sockets to a dedicated daemon process. This architecture isolates storage from application crashes and scales horizontally, but introduces network latency, connection pooling overhead, and complex serialization.

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
SQLite structures data inside single-file disk representations using fixed-size pages (typically 4096 bytes). 
*   **B-Tree & B+Tree Layout:** Table data is stored in B-Tree structures where leaf nodes store data payloads, while index pages use B+Trees to map keys to row identifiers (`ROWID`).
*   **Rollback Journal vs. Write-Ahead Logging (WAL):**
    *   *Rollback Journal (Default):* Modifies pages directly in the main database file after copying original un-modified pages into a `.db-journal` file. During a write transaction, an `EXCLUSIVE` lock prevents all concurrent readers.
    *   *WAL Mode (`PRAGMA journal_mode=WAL;`):* Appends new writes to a separate `-wal` file. Original database pages remain untouched. Readers do not block writers, and writers do not block readers. A concurrent reader accesses a snapshot of the database by combining unchanged pages from the main file with updated pages in the WAL index (`-shm`).

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
When a database engine processes a query string:
1. **Tokenizer & Lexer:** Breaks raw ASCII/UTF-8 input strings into lexical tokens (`SELECT`, `FROM`, `WHERE`, identifiers, literals).
2. **Parser:** Builds an Abstract Syntax Tree (AST) validating grammatical syntax.
3. **Query Optimizer:** Translates the AST into bytecode instructions executed by the Virtual Database Engine (VDBE).

**SQL Injection (SQLi) Mechanical Root Cause:**  
Dynamic string concatenation merges user input into the SQL command structure *before* AST generation. A payload containing string delimiters or SQL keywords alters the structure of the AST itself.

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

**Prepared Statement / Parameterized Query Prevention Mechanics:**  
Parameterized queries split the execution into two isolated steps:
1. The engine compiles the query skeleton into an AST and VDBE bytecode using parameter placeholders (`?` or `$1`).
2. Parameters are bound directly to pre-allocated VDBE memory registers. The input string is strictly treated as a scalar data value, bypassing the Lexer and Parser completely. The AST structure remains immutable regardless of input content.

---

## 2. Guided Hands-On Lab Exercises

### System Prerequisites
Ensure `sqlite3` and `node` are installed on your Linux machine before starting:
```bash
sudo apt-get update && sudo apt-get install -y sqlite3 nodejs npm
```

---

### Lab Block 1: DDL Table Creation, Schema Constraints, and Metadata Diagnostics

In this block, you will build a production database schema for a web application user module using Data Definition Language (DDL) commands, inspect storage engine metadata, and execute schema alterations.

#### Steps to Execute

1. Open a terminal and create a dedicated workspace directory, then initialize an SQLite database named `platform_prod.db`:
```bash
mkdir -p ~/lpi_sql_lab && cd ~/lpi_sql_lab
sqlite3 platform_prod.db
```
*Expected Terminal Prompt:* `sqlite>`

2. Enable WAL mode and foreign key constraint enforcement:
```sql
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;
```
*Expected Output:*
```
wal
```

3. Create the `users` table with strict data types, auto-incrementing primary key, default timestamps, and uniqueness constraints:
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

4. Verify table creation using SQLite CLI internal meta-commands:
```text
.schema users
.tables
```
*Expected Output:*
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

5. Modify the schema by adding a `last_login` column, then drop a temporary test table:
```sql
ALTER TABLE users ADD COLUMN last_login TEXT;

CREATE TABLE temp_scratch (id INT);
DROP TABLE IF EXISTS temp_scratch;
```

6. Confirm the updated table structure:
```text
.schema users
```
*Expected Output:*
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

1. **Question 1.1:** Why is `user_id INTEGER PRIMARY KEY AUTOINCREMENT` treated specially in SQLite compared to standard column declarations? What happens to the internal `ROWID`?
2. **Question 1.2:** If an application attempts to execute `INSERT INTO users (username, email, is_active) VALUES ('dev_user', 'dev@example.com', 5);`, what specific engine error will be thrown and why?

---

### Lab Block 2: DML Data Manipulation, Filtering, and Execution Plan Analysis

In this block, you will execute Data Manipulation Language (DML) operations (`INSERT`, `SELECT`, `UPDATE`, `DELETE`), implement query filtering/sorting/pagination, and analyze query execution paths using `EXPLAIN QUERY PLAN`.

#### Steps to Execute

1. Insert sample production data into the `users` table:
```sql
INSERT INTO users (username, email, account_balance) VALUES
('alice_sre', 'alice@platform.io', 1250.50),
('bob_dev', 'bob@platform.io', 450.00),
('charlie_arch', 'charlie@platform.io', 3200.75),
('david_sec', 'david@platform.io', 890.20),
('eve_ops', 'eve@platform.io', 0.00);
```

2. Format CLI output headers and layout for clear diagnostic inspection:
```text
.mode column
.headers on
```

3. Query active users with an `account_balance` greater than $500.00, ordered by balance descending, limited to 2 records:
```sql
SELECT user_id, username, email, account_balance 
FROM users 
WHERE is_active = 1 AND account_balance > 500.00 
ORDER BY account_balance DESC 
LIMIT 2;
```
*Expected Output:*
```text
user_id  username      email                account_balance
-------  ------------  -------------------  ---------------
3        charlie_arch  charlie@platform.io  3200.75        
1        alice_sre     alice@platform.io    1250.5         
```

4. Perform pattern matching using `LIKE` to find all accounts under the `platform.io` domain with usernames starting with `a` or `b`:
```sql
SELECT user_id, username, email 
FROM users 
WHERE email LIKE '%@platform.io' 
  AND (username LIKE 'a%' OR username LIKE 'b%');
```
*Expected Output:*
```text
user_id  username   email            
-------  ---------  -----------------
1        alice_sre  alice@platform.io
2        bob_dev    bob@platform.io  
```

5. Update `bob_dev`'s balance atomically and set `last_login`:
```sql
UPDATE users 
SET account_balance = account_balance + 150.00, 
    last_login = CURRENT_TIMESTAMP 
WHERE username = 'bob_dev';
```

6. Delete inactive or zero-balance operational test accounts (`eve_ops`):
```sql
DELETE FROM users 
WHERE account_balance = 0.00 AND username = 'eve_ops';
```

7. Analyze the query execution plan for filtering by `username` before and after creating a B-Tree index:
```sql
EXPLAIN QUERY PLAN SELECT * FROM users WHERE username = 'alice_sre';
```
*Expected Output:*
```text
QUERY PLAN
`--SEARCH users USING INDEX sqlite_autoindex_users_1 (username=?)
```
*(Note: SQLite automatically created a unique index `sqlite_autoindex_users_1` when the `UNIQUE` constraint was declared on `username`).*

8. Test execution plan on a non-indexed column (`account_balance`):
```sql
EXPLAIN QUERY PLAN SELECT * FROM users WHERE account_balance = 450.00;
```
*Expected Output:*
```text
QUERY PLAN
`--SCAN users
```

9. Create an explicit B-Tree index on `account_balance` and re-verify execution plan:
```sql
CREATE INDEX idx_users_balance ON users(account_balance);
EXPLAIN QUERY PLAN SELECT * FROM users WHERE account_balance = 450.00;
```
*Expected Output:*
```text
QUERY PLAN
`--SEARCH users USING INDEX idx_users_balance (account_balance=?)
```

10. Exit the SQLite CLI tool:
```sql
.quit
```

#### Verification Questions (Block 2)

1. **Question 2.1:** What is the fundamental performance difference between `SCAN users` and `SEARCH users USING INDEX` in database performance diagnostics?
2. **Question 2.2:** What potential data anomaly occurs if an `UPDATE` command is executed without a `WHERE` clause in a production environment?

---

### Lab Block 3: Transaction Control (ACID) and Node.js Database Integration

In this block, you will implement explicit ACID transactions (`BEGIN`, `COMMIT`, `ROLLBACK`) and write a Node.js web backend integration script executing parameterized SQL queries to prevent SQL Injection vulnerabilities.

#### Steps to Execute

1. Re-open `sqlite3 platform_prod.db` to test atomic transaction rollback mechanics:
```bash
sqlite3 platform_prod.db
```

2. Start a transaction, execute a speculative balance deduction, verify the state, and issue a `ROLLBACK`:
```sql
BEGIN TRANSACTION;
UPDATE users SET account_balance = account_balance - 500.00 WHERE username = 'alice_sre';
SELECT username, account_balance FROM users WHERE username = 'alice_sre';
ROLLBACK;
```
*Expected Output during transaction:*
```text
username   account_balance
---------  ---------------
alice_sre  750.5          
```

3. Verify that `alice_sre`'s balance was completely restored post-rollback:
```sql
SELECT username, account_balance FROM users WHERE username = 'alice_sre';
.quit
```
*Expected Output post-rollback:*
```text
username   account_balance
---------  ---------------
alice_sre  1250.5         
```

4. Initialize a Node.js backend module in your workspace:
```bash
cd ~/lpi_sql_lab
npm init -y
npm install sqlite3
```

5. Create a production-grade database interface file named `db_service.js`:
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

6. Execute the Node.js database service:
```bash
node db_service.js
```
*Expected Terminal Output:*
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

1. **Question 3.1:** In `Test 2`, why did the input `' OR '1'='1` fail to extract all database records when processed by the parameterized query `db.get(sql, [username], ...)`?
2. **Question 3.2:** What are the operational trade-offs of using `db.get()` vs `db.all()` vs `db.each()` in the Node.js `sqlite3` driver asynchronous execution model?

---

## 3. Detailed Answer Key & Architectural Solutions

<details>
<summary>Click to expand Solutions and Production Analysis</summary>

### Block 1 Answers & Architectural Analysis

*   **Answer 1.1:**  
    In SQLite, declaring a column as `INTEGER PRIMARY KEY` creates an alias for the internal 64-bit signed integer `ROWID` that uniquely identifies every record in a standard B-Tree table. Adding the keyword `AUTOINCREMENT` modifies the key generation algorithm:
    *   *Without AUTOINCREMENT:* SQLite chooses a `ROWID` equal to the maximum existing `ROWID` plus 1. If rows are deleted, previous IDs can be reused.
    *   *With AUTOINCREMENT:* SQLite enforces strict monotonically increasing IDs by tracking the highest allocated ID in an internal system table named `sqlite_sequence`. It will never reuse a previously deleted key, preventing subtle ID spoofing vulnerabilities in web applications.
*   **Answer 1.2:**  
    The engine will throw a constraint violation error: `Error: CHECK constraint failed: is_active IN (0, 1)`.  
    *Mechanics:* During the DML execution phase, SQLite validates all values against domain constraints defined in the schema. Because `5` is not present in the set `(0, 1)`, the transaction aborts before altering any database pages.

---

### Block 2 Answers & Architectural Analysis

*   **Answer 2.1:**  
    *   `SCAN users` (Full Table Scan): The engine iterates through every single page and row in the `users` table from start to finish. Time complexity is **$\mathcal{O}(N)$**. As table rows scale to millions, read latency degrades linearly and CPU/disk I/O surges.
    *   `SEARCH users USING INDEX` (Index Lookup): The engine performs a binary search tree traversal on the B-Tree index structure to locate the target key pointer in **$\mathcal{O}(\log N)$** time, then directly fetches the target data page.
*   **Answer 2.2:**  
    Executing `UPDATE users SET account_balance = 0.00;` without a `WHERE` clause applies the balance mutation to **every single row** in the table unconditionally. In production, this causes catastrophic data corruption requiring point-in-time recovery (PITR) from WAL logs or backups.

---

### Block 3 Answers & Architectural Analysis

*   **Answer 3.1:**  
    When using the parameterized placeholder `?`, the Node.js driver and SQLite engine compile the SQL string `SELECT ... WHERE username = ?` into fixed bytecode *prior* to receiving the payload. The payload string `' OR '1'='1` is bound directly to the argument memory register. The engine searches literally for a user whose `username` column contains the verbatim string value `"' OR '1'='1"`. Because no such user exists, the query safely returns zero records (`[WARN] No record found`).
*   **Answer 3.2:**  
    *   `db.get(sql, params, callback)`: Fetches **only the first matching row** into memory. Ideal for single-record primary key lookups (`user_id`). Highly memory efficient.
    *   `db.all(sql, params, callback)`: Fetches **all matching rows into an array in Node.js process RAM** at once. If the result set contains 500,000 rows, it can cause severe memory bloat or crash the V8 heap with an `Out of Memory (OOM)` error.
    *   `db.each(sql, params, rowCallback, completeCallback)`: Streams matching rows sequentially, invoking `rowCallback` once per row. Essential for processing large result sets without exhausting Node.js heap memory.

</details>

---

## 4. Verification & Summary

### Summary of Completed Objectives
1. **DDL Architecture:** Designed and implemented relational table schemas with explicit constraints (`PRIMARY KEY AUTOINCREMENT`, `FOREIGN KEY`, `CHECK`, `DEFAULT`, `UNIQUE`).
2. **DML Mechanics:** Mastered dataset filtering (`WHERE`, `LIKE`), sorting (`ORDER BY`), pagination (`LIMIT`), atomic data modifications (`UPDATE`), and conditional removals (`DELETE`).
3. **Performance Diagnostics:** Leveraged `EXPLAIN QUERY PLAN` to detect unindexed table scans (`SCAN`) vs optimized B-Tree lookups (`SEARCH USING INDEX`).
4. **Data Integrity & Security:** Executed ACID transaction rollbacks (`BEGIN`, `ROLLBACK`) and secured Node.js backend applications against SQL Injection using parameterized prepared statements.