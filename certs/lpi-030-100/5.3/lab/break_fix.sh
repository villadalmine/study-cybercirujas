#!/usr/bin/env bash
# ==============================================================================
# LPI 030-100 (Web Development Essentials v1.0) - Topic 5.3: SQL Basics
# Exam Weight: 7.5
# Official Reference: https://www.lpi.org/our-certifications/web-development-essentials-overview/
#
# Production Break & Fix Lab: Troubleshooting SQL Schemas, Syntax & Aggregations
# Author: Senior SRE & Principal Platform Architect
# ==============================================================================

set -euo pipefail

LAB_DIR="/var/lab/sql_basics"
DB_PATH="${LAB_DIR}/production.db"
REPORT_SCRIPT="/usr/local/bin/generate_revenue_report.sh"

echo "========================================================================"
echo "  INITIALIZING PRODUCTION BREAK & FIX LAB: SQL BASICS (LPI 030-100)"
echo "========================================================================"

# 1. Ensure dependencies are installed
if ! command -v sqlite3 &> /dev/null; then
    echo "[+] Installing sqlite3 package..."
    if command -v apt-get &> /dev/null; then
        apt-get update -qq && apt-get install -y -qq sqlite3
    elif command -v dnf &> /dev/null; then
        dnf install -y -q sqlite3
    elif command -v apk &> /dev/null; then
        apk add --no-cache sqlite3
    else
        echo "[!] Error: Package manager not supported. Please install 'sqlite3' manually."
        exit 1
    fi
fi

# 2. Setup Lab Directory
echo "[+] Preparing lab environment at ${LAB_DIR}..."
mkdir -p "${LAB_DIR}"
rm -f "${DB_PATH}"

# 3. Create initial database schema with deliberate schema defects
echo "[+] Initializing SQLite database schema..."
sqlite3 "${DB_PATH}" << 'EOF'
PRAGMA foreign_keys = ON;

-- Table: customers
CREATE TABLE customers (
    customer_id INTEGER PRIMARY KEY AUTOINCREMENT,
    first_name TEXT NOT NULL,
    last_name TEXT NOT NULL,
    email TEXT UNIQUE NOT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Table: products
CREATE TABLE products (
    product_id INTEGER PRIMARY KEY AUTOINCREMENT,
    product_name TEXT NOT NULL,
    sku TEXT UNIQUE NOT NULL,
    unit_price DECIMAL(10, 2) NOT NULL
);

-- Table: orders (BROKEN SCHEMA: Missing 'status' and 'total_amount' columns expected by the API)
CREATE TABLE orders (
    order_id INTEGER PRIMARY KEY AUTOINCREMENT,
    customer_id INTEGER NOT NULL,
    order_date DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (customer_id) REFERENCES customers(customer_id)
);

-- Table: order_items
CREATE TABLE order_items (
    item_id INTEGER PRIMARY KEY AUTOINCREMENT,
    order_id INTEGER NOT NULL,
    product_id INTEGER NOT NULL,
    quantity INTEGER NOT NULL CHECK(quantity > 0),
    unit_price DECIMAL(10, 2) NOT NULL,
    FOREIGN KEY (order_id) REFERENCES orders(order_id),
    FOREIGN KEY (product_id) REFERENCES products(product_id)
);

-- Seed Initial Data
INSERT INTO customers (first_name, last_name, email) VALUES
('Alice', 'Smith', 'alice@example.com'),
('Bob', 'Jones', 'bob@example.com'),
('Charlie', 'Brown', 'charlie@example.com');

INSERT INTO products (product_name, sku, unit_price) VALUES
('Cloud Server vCPU', 'SKU-CPU-01', 45.00),
('Block Storage 100GB', 'SKU-STO-01', 15.00),
('Load Balancer', 'SKU-LB-01', 25.00);

INSERT INTO orders (customer_id) VALUES (1), (2), (1);

INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
(1, 1, 2, 45.00),
(1, 2, 1, 15.00),
(2, 3, 1, 25.00),
(3, 1, 1, 45.00);
EOF

# 4. Deploy broken reporting script containing SQL syntax errors and bad query logic
echo "[+] Deploying broken reporting script at ${REPORT_SCRIPT}..."
cat << 'EOF' > "${REPORT_SCRIPT}"
#!/usr/bin/env bash
set -e

DB_PATH="/var/lab/sql_basics/production.db"

echo "=== Processing New Orders Ingestion ==="
# Attempt 1: SQL DML Insert Failure due to missing schema columns ('status', 'total_amount')
sqlite3 "${DB_PATH}" "INSERT INTO orders (customer_id, status, total_amount) VALUES (3, 'completed', 105.00);"

echo "=== Generating Customer Revenue Summary ==="
# Attempt 2: SQL DQL Syntax Error (Malformed JOIN ON clause, bad grouping expression)
sqlite3 -header -column "${DB_PATH}" "
SELECT 
    c.customer_id,
    c.first_name || ' ' || c.last_name AS customer_name,
    COUNT(o.order_id) AS total_orders,
    SUM(oi.quantity * oi.unit_price) AS total_spent
FROM customers c
INNER JOIN orders o
INNER JOIN order_items oi ON o.order_id = oi.order_id
WHERE o.status = 'completed'
GROUP BY c.customer_id
ORDER BY total_spent DESC;
"
EOF

chmod +x "${REPORT_SCRIPT}"

# 5. Display Incident Briefing
cat << 'EOF'

========================================================================
[INCIDENT ALERT]: FINANCIAL REPORTING PIPELINE FAILURE IN PRODUCTION
========================================================================

SYSTEM CONTEXT:
You are an SRE responding to an automated alert on the core e-commerce data pipeline. 
The nightly ETL report script '/usr/local/bin/generate_revenue_report.sh' failed 
during execution against SQLite database '/var/lab/sql_basics/production.db'.

SYMPTOMS:
Running '/usr/local/bin/generate_revenue_report.sh' fails immediately with SQL errors:
1. Schema mismatch: SQLite returns "table orders has no column named status"
2. Query syntax error: Broken table JOIN predicates and missing schema definitions.

YOUR OBJECTIVE:
1. Inspect the existing schema using sqlite3 CLI meta-commands (.schema, .tables).
2. Fix the DDL Schema for table 'orders' in '/var/lab/sql_basics/production.db':
   - Add column 'status' (TEXT, default 'completed').
   - Add column 'total_amount' (DECIMAL(10,2), default 0.00).
3. Fix the SQL statements inside '/usr/local/bin/generate_revenue_report.sh':
   - Correct the DML 'INSERT INTO orders' statement so new orders insert correctly.
   - Correct the DQL 'SELECT' query to properly JOIN 'customers' -> 'orders' -> 'order_items'.
     Ensure all JOIN ON conditions are explicitly stated (`c.customer_id = o.customer_id` AND `o.order_id = oi.order_id`).
   - Filter by `o.status = 'completed'`.
   - Aggregate revenue using `SUM(oi.quantity * oi.unit_price)` and group by `c.customer_id` and customer name.
4. Execute '/usr/local/bin/generate_revenue_report.sh' and confirm zero exit code and expected tabular output.

OFFICIAL REFERENCE:
- LPI Web Development Essentials 030-100 Topic 5.3 (SQL Basics)
  https://www.lpi.org/our-certifications/web-development-essentials-overview/

------------------------------------------------------------------------
The scenario is LIVE. Run '/usr/local/bin/generate_revenue_report.sh' to reproduce!
------------------------------------------------------------------------
EOF

exit 0

# ==============================================================================
# DETAILED STEP-BY-STEP SOLUTION & DEEP DIVE (FOR INSTRUCTORS / SELF-STUDY)
# ==============================================================================
: << 'SOLUTION_READ_ONLY_BLOCK'

1. DIAGNOSIS & RECONNAISSANCE
--------------------------------------------------------------------------------
First, execute the reporting script to capture exact error trace:
$ /usr/local/bin/generate_revenue_report.sh

Output:
=== Processing New Orders Ingestion ===
Runtime error at line 1: table orders has no column named status

Inspect the database schema using sqlite3 CLI meta-command:
$ sqlite3 /var/lab/sql_basics/production.db ".schema orders"

Expected output showing missing columns:
CREATE TABLE orders (
    order_id INTEGER PRIMARY KEY AUTOINCREMENT,
    customer_id INTEGER NOT NULL,
    order_date DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (customer_id) REFERENCES customers(customer_id)
);


2. ROOT CAUSE ANALYSIS
--------------------------------------------------------------------------------
Issue A (DDL Schema Defect):
Table 'orders' lacks the required 'status' and 'total_amount' columns.
When the application executes an INSERT statement specifying `(customer_id, status, total_amount)`,
SQLite aborts because the column definitions do not exist in the system catalog schema.

Issue B (DQL Syntax Defect):
In the SELECT query in '/usr/local/bin/generate_revenue_report.sh':
- The JOIN between `customers c` and `orders o` is missing its ON predicate (`INNER JOIN orders o` lacks `ON c.customer_id = o.customer_id`).
- Without the proper predicate, SQL syntax validation fails.
- The `GROUP BY` clause must include non-aggregated SELECT columns (`c.customer_id`, `c.first_name`, `c.last_name` or `customer_name`) under standard ANSI SQL rules.


3. REMEDIATION STEPS
--------------------------------------------------------------------------------

Step 1: Execute ALTER TABLE DDL statements on SQLite database to update schema:

$ sqlite3 /var/lab/sql_basics/production.db << 'SQL_FIX'
ALTER TABLE orders ADD COLUMN status TEXT DEFAULT 'completed';
ALTER TABLE orders ADD COLUMN total_amount DECIMAL(10, 2) DEFAULT 0.00;
SQL_FIX

Verify schema update:
$ sqlite3 /var/lab/sql_basics/production.db ".schema orders"


Step 2: Update existing seed orders to ensure consistency:

$ sqlite3 /var/lab/sql_basics/production.db "UPDATE orders SET status = 'completed' WHERE status IS NULL;"


Step 3: Fix '/usr/local/bin/generate_revenue_report.sh':

Replace `/usr/local/bin/generate_revenue_report.sh` with the corrected script:

$ cat << 'FIXED_SCRIPT' > /usr/local/bin/generate_revenue_report.sh
#!/usr/bin/env bash
set -e

DB_PATH="/var/lab/sql_basics/production.db"

echo "=== Processing New Orders Ingestion ==="
sqlite3 "${DB_PATH}" "INSERT INTO orders (customer_id, status, total_amount) VALUES (3, 'completed', 105.00);"

echo "=== Generating Customer Revenue Summary ==="
sqlite3 -header -column "${DB_PATH}" "
SELECT 
    c.customer_id,
    c.first_name || ' ' || c.last_name AS customer_name,
    COUNT(DISTINCT o.order_id) AS total_orders,
    ROUND(SUM(oi.quantity * oi.unit_price), 2) AS total_spent
FROM customers c
INNER JOIN orders o ON c.customer_id = o.customer_id
INNER JOIN order_items oi ON o.order_id = oi.order_id
WHERE o.status = 'completed'
GROUP BY c.customer_id, customer_name
ORDER BY total_spent DESC;
"
FIXED_SCRIPT

chmod +x /usr/local/bin/generate_revenue_report.sh


4. VERIFICATION & ACCEPTANCE TESTING
--------------------------------------------------------------------------------
Execute the fixed script:

$ /usr/local/bin/generate_revenue_report.sh

Expected Successful Output:
=== Processing New Orders Ingestion ===
=== Generating Customer Revenue Summary ===
customer_id  customer_name  total_orders  total_spent
-----------  -------------  ------------  -----------
1            Alice Smith    2             150.0      
2            Bob Jones      1             25.0       

Verify table contents directly in SQLite:
$ sqlite3 /var/lab/sql_basics/production.db "SELECT order_id, customer_id, status, total_amount FROM orders;"

SOLUTION_READ_ONLY_BLOCK