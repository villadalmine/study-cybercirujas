# LPI 030-100: Web Development Essentials — Tema 1.1: Software Development Basics
**Objetivo del examen**: LPI-030-100 (v1.0)  
**Peso del tema**: 2.5  
**Audiencia**: Site Reliability Engineers, Platform Architects y Systems Developers  

---

## Documentación de referencia oficial
* [LPI Web Development Essentials Overview & Objectives](https://www.lpi.org/our-certifications/web-development-essentials-overview/)
* [MDN Web Docs: HTTP Overview & Protocols](https://developer.mozilla.org/en-US/docs/Web/HTTP/Overview)
* [Git Documentation: Internals & Architecture](https://git-scm.com/book/en/v2/Git-Internals-Plumbing-and-Porcelain)
* [Node.js Documentation: V8 Execution & Event Loop](https://nodejs.org/en/learn/getting-started/the-v8-javascript-engine)
* [The Twelve-Factor App Methodology](https://12factor.net/)

---

## Visión general de la arquitectura y fundamentos mecánicos

```
+---------------------------------------------------------------------------------------------------+
|                                 SOFTWARE DEVELOPMENT PIPELINE                                     |
+---------------------------------------------------------------------------------------------------+
|  1. CODE CREATION        2. VERSION CONTROL        3. COMPILATION / BUILD      4. RUNTIME EXECUTION |
|  +----------------+      +---------------+         +-------------------+       +-----------------+ |
|  | Developer Work | ---> | Git Repository| ------> | CI/CD Pipeline    | ----> | Environment     | |
|  | (IDE / Local)  |      | (DAG/Objects) |         | (Artifact / Image)|       | (Dev/Stg/Prod)  | |
|  +----------------+      +---------------+         +-------------------+       +-----------------+ |
+---------------------------------------------------------------------------------------------------+
                                                                                          |          
   +--------------------------------------------------------------------------------------+          
   |                                                                                                 
   v                                                                                                 
+---------------------------------------------------------------------------------------------------+
|                                RUNTIME EXECUTION MECHANICS                                        |
+---------------------------------------------------------------------------------------------------+
|  A. COMPILED (C/Go)             B. INTERPRETED (Python)            C. JIT / HYBRID (JS / Node.js) |
|  +-----------------------+      +-------------------------+        +----------------------------+ |
|  | Source -> Machine Code|      | Source -> Bytecode      |        | Source -> AST -> Bytecode  | |
|  | Direct OS Kernel Exec |      | Executed via Virtual    |        | Ignited -> Profiler        | |
|  | (Native ELF Binary)   |      | Machine (PVM Loop)      |        | -> TurboFan Machine Code   | |
|  +-----------------------+      +-------------------------+        +----------------------------+ |
+---------------------------------------------------------------------------------------------------+
```

Software Development Basics cubre los paradigmas fundamentales, patrones arquitectónicos, modelos de runtime, técnicas de gestión de código fuente y modelos del ciclo de vida del entorno necesarios para desplegar sistemas web.

---

## Ejercicio 1: Paradigmas de ejecución en runtime — Compiled vs. Interpreted vs. JIT Engines

### Objetivo
Examinar cómo el código fuente se transforma en instrucciones ejecutables a través de los modelos de ejecución Compiled (C/Native ELF), Interpreted (Python Bytecode) y Just-In-Time compiled (JavaScript V8 Engine). Analizar los trade-offs de CPU/Memoria y diagnósticos de runtime.

### Pasos de ejecución práctica

#### Paso 1.1: Compilar y analizar un binario compilado estáticamente
Crear una aplicación de bajo nivel en C para observar la compilación nativa en un binario Executable and Linkable Format (ELF).

```bash
mkdir -p ~/lpi_lab/ex1 && cd ~/lpi_lab/ex1

cat << 'EOF' > app.c
#include <stdio.h>

int main() {
    unsigned long long sum = 0;
    for (unsigned long long i = 0; i < 100000000ULL; i++) {
        sum += i;
    }
    printf("Result: %llu\n", sum);
    return 0;
}
EOF

gcc -O2 app.c -o app_compiled
file app_compiled
```

**Salida esperada:**
```text
app_compiled: ELF 64-bit LSB executable, x86-64, version 1 (SYSV), dynamically linked, interpreter /lib64/ld-linux-x86-64.so.2, for GNU/Linux 3.2.0, BuildID[sha1]=..., stripped
```

Medir el tiempo de ejecución usando `time`:
```bash
time ./app_compiled
```

**Salida esperada:**
```text
Result: 4999999950000000

real    0m0.003s
user    0m0.003s
sys     0m0.000s
```

#### Paso 1.2: Inspeccionar la mecánica del runtime interpretado mediante Python Bytecode
Crear un script de Python equivalente e inspeccionar el opcode intermedio generado para la Python Virtual Machine (PVM).

```bash
cat << 'EOF' > app.py
import dis

def calculate():
    total = 0
    for i in range(100000000):
        total += i
    return total

if __name__ == "__main__":
    print(f"Result: {calculate()}")
EOF

python3 -m dis app.py | head -n 25
```

**Salida esperada:**
```text
  3           0 LOAD_CONST               1 (0)
              2 STORE_FAST               0 (total)

  4           4 LOAD_GLOBAL              0 (range)
              6 LOAD_CONST               2 (100000000)
              8 CALL_FUNCTION            1
             10 GET_ITER
        >>   12 FOR_ITER                 6 (to 26)
             14 STORE_FAST               1 (i)

  5          16 LOAD_FAST                0 (total)
             18 LOAD_FAST                1 (i)
             20 INPLACE_ADD
             22 STORE_FAST               0 (total)
             24 JUMP_ABSOLUTE           12
        >>   26 LOAD_FAST                0 (total)
             28 RETURN_VALUE
```

Medir el tiempo de ejecución del runtime interpretado:
```bash
time python3 app.py
```

**Salida esperada:**
```text
Result: 4999999950000000

real    0m3.842s
user    0m3.835s
sys     0m0.004s
```

#### Paso 1.3: Inspeccionar la compilación JIT y la optimización en Node.js (V8 Engine)
Crear un equivalente en JavaScript y observar la transición de V8 desde el bytecode del intérprete Ignition hasta el código máquina optimizado por TurboFan.

```bash
cat << 'EOF' > app.js
function calculate() {
    let total = 0;
    for (let i = 0; i < 100000000; i++) {
        total += i;
    }
    return total;
}

console.time("JS_Execution");
const result = calculate();
console.timeEnd("JS_Execution");
console.log("Result:", result);
EOF

node --trace-opt app.js
```

**Salida esperada:**
```text
[marking 0x... <JSFunction calculate ...> for optimization to TURBOFAN, reason: small function]
[compiling method 0x... <JSFunction calculate ...> (target TURBOFAN) using TurboFan]
[completed compiling 0x... <JSFunction calculate ...> (target TURBOFAN) - OSR]
JS_Execution: ~42.15ms
Result: 4999999950000000
```

---

### Preguntas de verificación (Ejercicio 1)

1. **¿Por qué el binario compilado (`app_compiled`) se ejecuta órdenes de magnitud más rápido que el script interpretado de Python (`app.py`) para exactamente la misma lógica de contador de bucle?**
2. **¿Qué ocurre dentro del motor V8 cuando `--trace-opt` reporta `marking for optimization to TURBOFAN`?**
3. **Si un sistema web backend requiere una latencia de inicio mínima (cold start < 10ms) y un consumo de memoria bajo y determinista, ¿qué paradigma de ejecución es el más adecuado y por qué?**

---

## Ejercicio 2: Arquitectura Web y mecánica HTTP — Ejecución Client vs. Server-Side

### Objetivo
Construir un servicio web HTTP liviano para producción en Node.js utilizando librerías estándar del núcleo. Inspeccionar el flujo del protocolo HTTP cliente/servidor, headers personalizados, estado del socket TCP y códigos de estado utilizando herramientas CLI de bajo nivel (`curl`, `ss`/`netstat`).

### Pasos de ejecución práctica

#### Paso 2.1: Implementar un servidor web HTTP sintácticamente válido
Crear un servidor HTTP nativo en Node.js que admita paradigmas de REST API, enrutamiento estructurado, respuestas JSON dinámicas y headers de respuesta HTTP.

```bash
mkdir -p ~/lpi_lab/ex2 && cd ~/lpi_lab/ex2

cat << 'EOF' > server.js
const http = require('http');
const url = require('url');

const PORT = 8080;

const server = http.createServer((req, res) => {
    const parsedUrl = url.parse(req.url, true);
    const method = req.method;

    // Security & Infrastructure Headers
    res.setHeader('Content-Type', 'application/json');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Server', 'SRE-Production-Core/1.0');

    if (parsedUrl.pathname === '/api/v1/health' && method === 'GET') {
        res.statusCode = 200;
        res.end(JSON.stringify({
            status: 'UP',
            timestamp: new Date().toISOString(),
            uptime: process.uptime()
        }));
    } else if (parsedUrl.pathname === '/api/v1/data' && method === 'POST') {
        let body = '';
        req.on('data', chunk => { body += chunk.toString(); });
        req.on('end', () => {
            try {
                const parsed = JSON.parse(body);
                res.statusCode = 201;
                res.end(JSON.stringify({ message: 'Resource created', data: parsed }));
            } catch (err) {
                res.statusCode = 400;
                res.end(JSON.stringify({ error: 'Invalid JSON payload' }));
            }
        });
    } else {
        res.statusCode = 404;
        res.end(JSON.stringify({ error: 'Route not found' }));
    }
});

server.listen(PORT, '127.0.0.1', () => {
    console.log(`Server running on http://127.0.0.1:${PORT}`);
});
EOF

node server.js &
SERVER_PID=$!
sleep 1
```

**Salida esperada:**
```text
Server running on http://127.0.0.1:8080
```

#### Paso 2.2: Inspeccionar los detalles del frame de petición/respuesta HTTP con `curl` detallado
Ejecutar peticiones HTTP para analizar códigos de estado, headers de petición y metadatos de respuesta.

```bash
curl -i -X GET http://127.0.0.1:8080/api/v1/health
```

**Salida esperada:**
```http
HTTP/1.1 200 OK
Content-Type: application/json
X-Content-Type-Options: nosniff
Server: SRE-Production-Core/1.0
Date: Thu, 06 Aug 2026 18:50:00 GMT
Connection: keep-alive
Keep-Alive: timeout=5
Content-Length: 78

{"status":"UP","timestamp":"2026-08-06T18:50:00.000Z","uptime":1.0421}
```

Probar la gestión de errores (400 Bad Request):
```bash
curl -i -X POST http://127.0.0.1:8080/api/v1/data \
  -H "Content-Type: application/json" \
  -d "{ invalid_json: "
```

**Salida esperada:**
```http
HTTP/1.1 400 Bad Request
Content-Type: application/json
X-Content-Type-Options: nosniff
Server: SRE-Production-Core/1.0
Date: Thu, 06 Aug 2026 18:50:05 GMT
Connection: keep-alive
Content-Length: 30

{"error":"Invalid JSON payload"}
```

#### Paso 2.3: Analizar los bindings de sockets TCP subyacentes
Inspeccionar el socket en escucha en las métricas del sistema Linux mediante `ss`.

```bash
ss -tulpn | grep 8080
```

**Salida esperada:**
```text
tcp   LISTEN 0      512        127.0.0.1:8080      0.0.0.0:*    users:(("node",pid=...,fd=18))
```

Limpiar el trabajo en segundo plano:
```bash
kill $SERVER_PID
```

---

### Preguntas de verificación (Ejercicio 2)

1. **En Client-Side Rendering (CSR) vs. Server-Side Rendering (SSR), ¿dónde tiene lugar la ejecución de JavaScript y cómo afecta esto al First Contentful Paint (FCP) y a la carga de CPU del servidor?**
2. **¿Cuál es la importancia arquitectónica de devolver `X-Content-Type-Options: nosniff` en los headers del servidor HTTP?**
3. **Durante el diagnóstico de una caída, `curl` devuelve `curl: (7) Failed to connect to 127.0.0.1 port 8080: Connection refused`. ¿Indica esto un error de código de aplicación HTTP (por ejemplo, 500 Internal Server Error) o un problema de la capa de transporte de más bajo nivel? Explique utilizando el ciclo de vida de TCP.**

---

## Ejercicio 3: Sistemas de control de versiones — Git DAG y mecánica interna

### Objetivo
Obtener una comprensión profunda a bajo nivel de la arquitectura interna de Git: el Directed Acyclic Graph (DAG), tipos de objetos (`blob`, `tree`, `commit`, `annotated tag`), comandos plumbing, punteros (`HEAD`, branches) y técnicas de resolución de conflictos.

```
+-----------------------------------------------------------------------------------+
|                                 GIT DAG INTERNALS                                 |
+-----------------------------------------------------------------------------------+
|  BRANCH REF: refs/heads/main -----> COMMIT OBJECT (hash: 7a8f...)                 |
|                                     |-- tree: 3b1c...                             |
|                                     |-- parent: 1e4a...                           |
|                                     |-- author / committer                        |
|                                     `-- message: "feat: initial API"              |
|                                              |                                    |
|                                              v                                    |
|                                     TREE OBJECT (hash: 3b1c...)                   |
|                                     |-- 100644 blob 9d2e...    app.js           |
|                                     `-- 040000 tree 8e4f...    src/             |
|                                                    |                              |
|                                                    v                              |
|                                           BLOB OBJECT (hash: 9d2e...)             |
|                                           (Raw File Contents Only)                |
+-----------------------------------------------------------------------------------+
```

### Pasos de ejecución práctica

#### Paso 3.1: Inicializar el repositorio e inspeccionar la estructura `.git`
Crear un repositorio sandbox y analizar el motor de almacenamiento de objetos subyacente.

```bash
mkdir -p ~/lpi_lab/ex3 && cd ~/lpi_lab/ex3
git init
ls -la .git
```

**Salida esperada:**
```text
total 24
drwxr-xr-x 7 user user 4096 Aug  6 18:50 .
drwxr-xr-x 5 user user 4096 Aug  6 18:50 ..
-rw-r--r-- 1 user user   23 Aug  6 18:50 HEAD
-rw-r--r-- 1 user user  130 Aug  6 18:50 config
-rw-r--r-- 1 user user   73 Aug  6 18:50 description
drwxr-xr-x 2 user user 4096 Aug  6 18:50 hooks
drwxr-xr-x 2 user user 4096 Aug  6 18:50 info
drwxr-xr-x 4 user user 4096 Aug  6 18:50 objects
drwxr-xr-x 2 user user 4096 Aug  6 18:50 refs
```

#### Paso 3.2: Crear objetos manualmente usando comandos plumbing de Git
Generar un blob sin procesar directamente en `.git/objects` sin usar `git add`.

```bash
BLOB_HASH=$(echo "Production Platform Config" | git hash-object -w --stdin)
echo "Blob Hash: ${BLOB_HASH}"
```

**Salida esperada:**
```text
Blob Hash: b4fa528a4794e6378c25dbfbf21a7114ff35aa94
```

Inspeccionar el tipo y contenido del objeto usando `git cat-file`:
```bash
git cat-file -t ${BLOB_HASH}
git cat-file -p ${BLOB_HASH}
```

**Salida esperada:**
```text
blob
Production Platform Config
```

#### Paso 3.3: Simular un conflicto de ramificación (branching) y realizar una resolución manual
Crear un historial de commits con ramas divergentes en las mismas líneas de archivo.

```bash
echo "log_level = info" > config.ini
git add config.ini
git commit -m "Initial config"

# Create feature branch
git checkout -b feature/verbose-logging
echo "log_level = debug" > config.ini
git commit -am "Set debug log level"

# Switch back to main branch and create conflicting change
git checkout main
echo "log_level = warn" > config.ini
git commit -am "Set warn log level"

# Trigger merge conflict
git merge feature/verbose-logging
```

**Salida esperada:**
```text
Auto-merging config.ini
CONFLICT (content): Merge conflict in config.ini
Automatic merge failed; fix conflicts and then commit the result.
```

Inspeccionar el estado y los marcadores de conflicto:
```bash
cat config.ini
```

**Salida esperada:**
```text
<<<<<<< HEAD
log_level = warn
=======
log_level = debug
>>>>>>> feature/verbose-logging
```

Resolver el conflicto, preparar el archivo (stage) y finalizar el merge:
```bash
cat << 'EOF' > config.ini
log_level = info
EOF

git add config.ini
git commit -m "Fix merge conflict in config.ini: retain info log level"
git log --graph --oneline --all
```

**Salida esperada:**
```text
*   e5a9b2c (HEAD -> main) Fix merge conflict in config.ini: retain info log level
|\  
| * 7d1f8a2 (feature/verbose-logging) Set debug log level
* | 3c4e1f9 Set warn log level
|/  
* 9a8b7c6 Initial config
```

---

### Preguntas de verificación (Ejercicio 3)

1. **¿Qué datos se almacenan dentro de un objeto `blob` de Git y por qué se omiten los nombres de archivos, permisos y estructuras de directorios en él?**
2. **¿Dónde se registran las rutas de archivos y las jerarquías de directorios en el modelo de objetos de Git?**
3. **Si un ingeniero de plataforma ejecuta `git reset --hard HEAD~1`, ¿se purgan inmediatamente del disco los objetos commit desvinculados? Explique cómo funciona la recolección de basura de Git (`git gc`).**

---

## Ejercicio 4: Aislamiento de entornos, gestión de configuración y CI/CD Pipelines

### Objetivo
Implementar la metodología Twelve-Factor App para la gestión de configuración. Construir flujos de trabajo de aislamiento de entornos (Development, Staging, Production), validar la inyección de variables de entorno y escribir un manifiesto de pipeline de CI/CD completo y sintácticamente válido.

### Pasos de ejecución práctica

#### Paso 4.1: Implementar la lectura de configuración compatible con Twelve-Factor
Crear una aplicación Node.js que imponga la configuración a través de variables de entorno en lugar de credenciales hardcodeadas o archivos de configuración específicos del entorno.

```bash
mkdir -p ~/lpi_lab/ex4 && cd ~/lpi_lab/ex4

cat << 'EOF' > app_config.js
function getRequiredEnv(key, defaultValue = null) {
    const value = process.env[key] || defaultValue;
    if (value === null) {
        console.error(`[CRITICAL CONFIG ERROR] Missing required env var: ${key}`);
        process.exit(1);
    }
    return value;
}

const config = {
    env: getRequiredEnv('NODE_ENV', 'development'),
    dbHost: getRequiredEnv('DB_HOST', '127.0.0.1'),
    dbPort: parseInt(getRequiredEnv('DB_PORT', '5432'), 10),
    maxConnections: parseInt(getRequiredEnv('MAX_CONN', '10'), 10),
};

console.log('Successfully loaded platform configuration:');
console.log(JSON.stringify(config, null, 2));
EOF
```

Ejecutar bajo el modo de entorno **Development**:
```bash
NODE_ENV=development DB_HOST=localhost DB_PORT=5432 app_config_run() {
    NODE_ENV=development DB_HOST=dev-db.local node app_config.js
}
app_config_run
```

**Salida esperada:**
```json
Successfully loaded platform configuration:
{
  "env": "development",
  "dbHost": "dev-db.local",
  "dbPort": 5432,
  "maxConnections": 10
}
```

Ejecutar bajo el modo de entorno **Production**:
```bash
NODE_ENV=production DB_HOST=prod-db-cluster.internal DB_PORT=5432 MAX_CONN=500 node app_config.js
```

**Salida esperada:**
```json
Successfully loaded platform configuration:
{
  "env": "production",
  "dbHost": "prod-db-cluster.internal",
  "dbPort": 5432,
  "maxConnections": 500
}
```

#### Paso 4.2: Construir un manifiesto de flujo de trabajo de CI/CD de GitHub Actions apto para producción
Crear una especificación YAML totalmente válida para un pipeline de CI/CD automatizado con etapas de build, test, lint, contenedorización y despliegue en staging/producción.

```bash
mkdir -p .github/workflows

cat << 'EOF' > .github/workflows/deploy.yml
name: Production SDLC CI/CD Pipeline

on:
  push:
    branches: [ main, staging ]
  pull_request:
    branches: [ main ]

permissions:
  contents: read
  packages: write

jobs:
  lint-and-test:
    name: Lint & Unit Test
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Source Code
        uses: actions/checkout@v4

      - name: Setup Node.js Runtime
        uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'

      - name: Install Dependencies
        run: npm ci --prefer-offline

      - name: Execute Linter
        run: npm run lint --if-present

      - name: Run Test Suite
        run: npm test --if-present
        env:
          NODE_ENV: test

  build-and-push:
    name: Build & Push OCI Image
    needs: lint-and-test
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Repository
        uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to Container Registry
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Extract Metadata (Tags, Labels)
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ghcr.io/${{ github.repository }}
          tags: |
            type=ref,event=branch
            type=sha,format=short

      - name: Build and Push Container Image
        uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}

  deploy-staging:
    name: Deploy to Staging
    needs: build-and-push
    if: github.ref == 'refs/heads/staging'
    runs-on: ubuntu-latest
    environment: staging
    steps:
      - name: Deploy to Kubernetes Staging Namespace
        run: |
          echo "Deploying image tag ${{ github.sha }} to Staging Environment..."
          # kubectl set image deployment/web-app web=${{ steps.meta.outputs.tags }} -n staging

  deploy-production:
    name: Deploy to Production
    needs: build-and-push
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    environment: production
    steps:
      - name: Deploy to Kubernetes Production Cluster
        run: |
          echo "Deploying image tag ${{ github.sha }} to Production Environment..."
          # kubectl set image deployment/web-app web=${{ steps.meta.outputs.tags }} -n production
EOF

python3 -c "import yaml; yaml.safe_load(open('.github/workflows/deploy.yml'))" && echo "YAML Syntax Valid"
```

**Salida esperada:**
```text
YAML Syntax Valid
```

---

### Preguntas de verificación (Ejercicio 4)

1. **¿Por qué la metodología Twelve-Factor App defiende estrictamente almacenar la configuración en variables de entorno en lugar de hardcodear archivos `.json` o `.yaml` específicos del entorno dentro del codebase?**
2. **¿Cuál es la diferencia estructural entre los entornos de Staging y Production en las arquitecturas modernas cloud-native?**
3. **En el manifiesto del pipeline de CI/CD (`deploy.yml`), ¿por qué se declara `needs: lint-and-test` antes del trabajo `build-and-push`? ¿Qué principio de SRE impone esto?**

---

## Clave de respuestas de verificación y explicaciones técnicas detalladas

<details>
<summary><strong>Haga clic para desplegar la clave de respuestas principal y explicaciones arquitectónicas</strong></summary>

### Soluciones del Ejercicio 1: Paradigmas de ejecución en runtime

1. **Mecánica de ejecución Compiled vs. Interpreted:**
   * **`app_compiled` (C/Native ELF)**: El compilador (`gcc -O2`) traduce el código fuente C directamente a código máquina nativo dirigido a la arquitectura de CPU host (conjunto de instrucciones x86-64). Los registros de CPU manejan la aritmética (`ADD`, `INC`), y el kernel del SO ejecuta el binario precompilado sin sobrecarga de traducción en runtime.
   * **`app.py` (Python/PVM)**: Python compila el código fuente en *bytecode* intermedio. La Python Virtual Machine (PVM) ejecuta un bucle leyendo opcodes (`FOR_ITER`, `INPLACE_ADD`). Cada interacción requiere el despacho de fetch-decode-execute del bytecode, evaluación de tipos dinámica, asignaciones de memoria para objetos enteros y conteo de referencias, lo que resulta en una sobrecarga de ejecución significativa.

2. **Optimización JIT de V8 y TurboFan:**
   * Node.js comienza ejecutando código JavaScript a través del intérprete de bytecode **Ignition** para un inicio instantáneo.
   * A medida que el código se ejecuta, el profiler de V8 monitorea la frecuencia de ejecución ("detección de hot spots").
   * Cuando `calculate()` realiza millones de iteraciones en el bucle, V8 marca la función como hot (`marking for optimization to TURBOFAN`).
   * **TurboFan** recompila ese bloque de bytecode específico directamente en código máquina nativo optimizado en segundo plano, omitiendo por completo el intérprete. Si las suposiciones dinámicas cambian (por ejemplo, pasar un string en lugar de un entero), V8 realiza una *de-optimization* de vuelta al bytecode de Ignition.

3. **Selección de runtime para cold starts bajos y memoria reducida:**
   * **Lenguajes compilados (Go, Rust, C)** son óptimos.
   * Compilan directamente a binarios nativos ELF estáticos sin sobrecarga de Virtual Machine ni de compilador JIT. Se inician al instante (<2ms), consumen una memoria RSS mínima (<10MB) y eliminan los picos de CPU de la compilación JIT durante el tráfico inicial de peticiones.

---

### Soluciones del Ejercicio 2: Arquitectura Web y mecánica HTTP

1. **Client-Side Rendering (CSR) vs. Server-Side Rendering (SSR):**
   * **CSR (Client-Side Rendering)**: El servidor devuelve un archivo HTML estructurado básico junto con bundles de JavaScript. El navegador web del usuario descarga, analiza y ejecuta el JS para renderizar el DOM.
     * *Trade-off*: Baja sobrecarga de CPU en el servidor; First Contentful Paint (FCP) retrasado porque los dispositivos cliente deben descargar y procesar toda la UI de la aplicación.
   * **SSR (Server-Side Rendering)**: Los motores de Node.js/servidor ejecutan JavaScript o plantillas en el servidor, produciendo cadenas HTML completamente pobladas devueltas directamente en el cuerpo de la respuesta HTTP.
     * *Trade-off*: FCP inicial rápido y alta optimización SEO; mayor carga de CPU/memoria en el servidor ya que el cómputo de renderizado se traslada por completo a la infraestructura backend.

2. **Importancia de seguridad de `X-Content-Type-Options: nosniff`:**
   * Este header de respuesta indica a los navegadores que respeten estrictamente el header `Content-Type` declarado (por ejemplo, `application/json` o `text/html`) sin intentar realizar MIME-type sniffing.
   * Esto mitiga los **ataques de confusión MIME** (por ejemplo, un atacante que sube un archivo JavaScript malicioso disfrazado como `.png` o `.txt`, forzando al navegador a ejecutar código no confiable).

3. **Diagnóstico para `Connection refused` (Errno 111):**
   * `Connection refused` ocurre en la **capa de transporte TCP (Capa 4)**. El cliente envió un paquete `TCP SYN` al puerto 8080, pero el stack de red del kernel respondió con un paquete `TCP RST` (Reset) porque ningún proceso estaba activamente vinculado a `LISTEN` en `127.0.0.1:8080`.
   * Esto indica un fallo de infraestructura o del ciclo de vida del proceso (el proceso se cayó, el servicio está caído, binding de IP/puerto incorrecto), **no** una caída de código de la capa de aplicación HTTP 500.

---

### Soluciones del Ejercicio 3: Git DAG y mecánica interna

1. **Modelo de almacenamiento Blob de Git:**
   * Un `blob` de Git (binary large object) almacena **solo el contenido bruto del archivo**.
   * No almacena metadatos: sin ruta de archivo, marcas de tiempo, ubicación de directorio ni permisos.
   * *Razón*: Eficiencia de almacenamiento y deduplicación. Si existen diez archivos idénticos en diferentes directorios o ramas, Git almacena un único objeto blob SHA-1/SHA-256 que representa ese contenido único.

2. **Almacenamiento de estructura de directorios en Git:**
   * Las jerarquías de directorios, las rutas de archivos y los modos de archivo (`100644` estándar, `100755` ejecutable) se almacenan en **Tree Objects**.
   * Un objeto Tree mapea los hashes de blobs a sus respectivos nombres de archivo y modos, o apunta a objetos Tree hijos anidados que representan subdirectorios.

3. **Mecánica de Git Reset vs. Garbage Collection:**
   * `git reset --hard HEAD~1` actualiza el puntero de la rama actual al commit padre, desvinculando el commit no referenciado.
   * El objeto commit permanece en el disco dentro de `.git/objects/`. Se conserva en el **Reflog** (`.git/logs/`) por seguridad (típicamente 90 días por defecto).
   * Los objetos solo se eliminan permanentemente cuando se ejecuta `git gc` (Garbage Collection), purgando los objetos no referenciados más antiguos que `gc.pruneExpire` (por defecto 2 semanas) y consolidando objetos sueltos en packfiles empaquetados (`.git/objects/pack/`).

---

### Soluciones del Ejercicio 4: Aislamiento de entornos y CI/CD Pipelines

1. **Justificación de la configuración en Twelve-Factor App:**
   * Hardcodear archivos de entorno (`config.production.json`) en los repositorios introduce riesgos de seguridad significativos (filtración accidental de credenciales de la base de datos de producción) y viola la estricta separación entre codebase y entorno.
   * Las variables de entorno permiten desplegar exactamente el mismo build de código inmutable o tag de imagen de contenedor en Development, Staging y Production sin modificaciones de código, cambiando solo las variables de entorno de runtime inyectadas en el despliegue.

2. **Separación de entornos Staging vs. Production:**
   * **Staging**: Una réplica arquitectónica exacta de producción (mismas versiones de base de datos, topología, políticas de red y runtimes del SO) aislada utilizando diferentes namespaces, VPCs o clusters. Utiliza datos sintéticos o sanitizados para validar artefactos de despliegue antes de que lleguen a los usuarios finales.
   * **Production**: El entorno en vivo que atiende el tráfico real de los usuarios, con métricas estrictas de SLA/SLO, bases de datos de producción, almacenes de secretos KMS y controles de auto-scaling de alta disponibilidad.

3. **Salvaguardas de SRE en CI/CD Pipelines (`needs: lint-and-test`):**
   * Declarar dependencias entre trabajos evita que **los artefactos defectuosos se propaguen downstream**.
   * Si las pruebas unitarias fallan, el pipeline falla de inmediato y cancela la compilación del contenedor (`build-and-push`) y el despliegue (`deploy-staging`/`deploy-production`). Esto conserva el almacenamiento del registro, evita lanzamientos de contenedores defectuosos y mantiene la seguridad del despliegue.

</details>

---

## Lista de verificación de resumen para la preparación del examen LPI 030-100

| Concepto del tema | Comando / Término clave | Punto de verificación crítico |
| :--- | :--- | :--- |
| **Compiled Languages** | `gcc -O2`, ELF format | Ejecución directa en kernel de código máquina; alto rendimiento, cero sobrecarga de VM en runtime. |
| **Interpreted Languages** | Python, `dis` module | Bucle de ejecución de fuente a bytecode a PVM; sobrecarga de tipado dinámico. |
| **JIT Engines** | Node.js V8 (`Ignition`/`TurboFan`) | Comienza como bytecode, optimiza dinámicamente bucles hot a código máquina nativo en runtime. |
| **HTTP Mechanics** | `curl -i`, `ss -tulpn` | Códigos de estado (200, 400, 404, 500), headers, análisis del estado de sockets TCP. |
| **Git Architecture** | `git hash-object`, `cat-file` | Blobs (datos), Trees (rutas/permisos), Commits (metadatos/padres), Refs (punteros). |
| **SDLC & 12-Factor** | `process.env`, GitHub Actions YAML | Separación estricta de entornos, configuración mediante variables de entorno, seguridad en CI/CD pipelines. |