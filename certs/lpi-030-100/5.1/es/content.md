# Guía de Estudio LPI 030-100 — Tema 5.1: Conceptos Básicos de Node.js

**Certificación del Examen:** Linux Professional Institute Web Development Essentials (Examen 030-100, Versión 1.0)  
**Objetivo del Tema:** Tema 5.1 Conceptos Básicos de Node.js  
**Peso del Tema:** 2.5  
**Audiencia Objetivo:** SREs, DevOps Engineers, Platform Architects  

---

## 1. Motivación Arquitectónica y Planteamiento del Problema en Producción

### 1.1 El Problema C10K y los Cuellos de Botella de Hilo por Petición (Thread-per-Request)
Las arquitecturas tradicionales de servidores web (por ejemplo, Apache HTTP Server con `mod_php` o los contenedores tradicionales de Java Servlets) se basan en un modelo de concurrencia de **hilo por petición** (thread-per-request) o **proceso por petición** (process-per-request). En este modelo, cada conexión TCP entrante se vincula a un hilo dedicado del sistema operativo (OS).

```
Thread-per-Request Concurrency Bottleneck:
[ HTTP Client 1 ] ---> [ OS Thread 1 (Stack ~1MB) ] ---> [ Blocking DB Read ] (Thread Idle)
[ HTTP Client 2 ] ---> [ OS Thread 2 (Stack ~1MB) ] ---> [ Blocking File I/O ] (Thread Idle)
...
[ HTTP Client N ] ---> Context Switching Overhead + RAM Exhaustion (10,000 Threads = ~10GB Overhead)
```

**Modos de Fallo Arquitectónico en Producción:**
1. **Sobrecarga de Memoria (Memory Overhead):** Cada hilo del sistema operativo asigna un tamaño de memoria de pila (stack memory) predeterminado (típicamente de 512KB a 2MB). Gestionar 10,000 conexiones inactivas concurrentes consume ~10GB de RAM puramente para las pilas de los hilos.
2. **Sobrecarga por Cambio de Contexto (Context Switching Thrashing):** A medida que aumenta el número de conexiones ($N$), el kernel del sistema operativo dedica más ciclos de CPU a realizar cambios de contexto de hilos (guardar/restaurar registros, invalidación de la caché de la CPU) que a ejecutar el código de la aplicación.
3. **Desperdicio por Bloqueo de I/O:** En las aplicaciones web típicas, más del 90% de la latencia de la petición se pasa esperando I/O externa (consultas a bases de datos, acceso al sistema de archivos, llamadas a API de red). Bajo el modelo de hilo por petición, el hilo del sistema operativo permanece bloqueado e inactivo durante estos periodos.

### 1.2 La Arquitectura Dirigida por Eventos y No Bloqueante de Node.js
Node.js resuelve el problema C10K utilizando un **Event Loop monohilo (single-threaded)** combinado con multiplexación de I/O no bloqueante respaldada por `libuv` y el motor de JavaScript Google V8.

```
Node.js Architecture High-Level Component Stack:

+-----------------------------------------------------------------------+
|                        Node.js Core API (JS)                          |
|             (http, fs, net, crypto, stream, events, process)          |
+-----------------------------------------------------------------------+
|                    Node.js C++ Binding Layer                          |
+-----------------------------------+-----------------------------------+
|     V8 JavaScript Engine          |             libuv                 |
| (JIT Compilation, Garbage Coll.)  |  (Event Loop, Async I/O, Pool)    |
+-----------------------------------+-----------------------------------+
                                    | OS I/O Demux (epoll/kqueue/IOCP)  |
                                    +-----------------------------------+
                                    | libuv Thread Pool (4 Workers)     |
                                    +-----------------------------------+
```

#### Componentes Clave de la Arquitectura:
* **Google V8 Engine:** Compila JavaScript directamente a código máquina nativo (JIT), gestiona la pila de ejecución y maneja la asignación de memoria/recolección de basura (Scavenge/Mark-Sweep).
* **libuv:** Una biblioteca C multiplataforma que actúa como capa de abstracción sobre las primitivas de I/O asíncronas de bajo nivel:
  * **Linux:** `epoll`
  * **macOS/BSD:** `kqueue`
  * **Windows:** `IOCP` (Input/Output Completion Ports)
* **Main Thread (Hilo Principal):** Ejecuta el código JavaScript, evalúa operaciones síncronas y ejecuta los callbacks de eventos de forma secuencial.

---

### 1.3 Análisis Profundo: El Event Loop de libuv y Mecánica del Thread Pool

El Event Loop opera en un solo hilo, pero delega las operaciones asíncronas. No todas las operaciones asíncronas utilizan handles no bloqueantes del sistema operativo; algunas operaciones son fundamentalmente bloqueantes a nivel de kernel (por ejemplo, operaciones síncronas de archivos, resolución DNS a través de `/etc/hosts`).

```
libuv Event Loop Lifecycle Phases:

      +-----------------------------------------+
----> |                 Timers                  | ---> [ setTimeout(), setInterval() ]
      +-----------------------------------------+
                           |
      +-----------------------------------------+
      |            Pending Callbacks            | ---> [ Executed deferred I/O callbacks ]
      +-----------------------------------------+
                           |
      +-----------------------------------------+
      |           Idle, Prepare                 | ---> [ Internal libuv usage ]
      +-----------------------------------------+
                           |
      +-----------------------------------------+
      |                 Poll                    | ---> [ Retrieve new I/O events; block if idle ]
      +-----------------------------------------+
                           |
      +-----------------------------------------+
      |                 Check                   | ---> [ setImmediate() callbacks ]
      +-----------------------------------------+
                           |
      +-----------------------------------------+
      |            Close Callbacks              | ---> [ e.g. socket.on('close') ]
      +-----------------------------------------+
                           |
                           v
           [ Microtask Queue Check: process.nextTick() -> Promises ]
```

#### Operaciones del Thread Pool de libuv
Cuando una operación no se puede realizar mediante multiplexación de I/O no bloqueante del sistema operativo, `libuv` delega el trabajo a un pool de hilos interno gestionado a través de la variable de entorno `UV_THREADPOOL_SIZE` (predeterminado: `4`, máximo: `1024`).

**Operaciones delegadas al Thread Pool:**
1. **File System (módulo `fs`):** Las llamadas a archivos asíncronas (`fs.readFile`, `fs.writeFile`) utilizan tareas del thread pool porque los principales kernels de SO carecen de interfaces de I/O de archivos no bloqueantes unificadas.
2. **Crypto (módulo `crypto`):** Operaciones intensivas de CPU como `crypto.pbkdf2()`, `crypto.scrypt()`, y `crypto.randomBytes()`.
3. **Zlib (módulo `zlib`):** Operaciones de compresión/descompresión.
4. **DNS (módulo `dns`):** `dns.lookup()` utiliza `getaddrinfo(3)`, el cual bloquea de forma síncrona. Nota: `dns.resolve()` utiliza c-ares y realiza llamadas directas a sockets de red no bloqueantes sin intervención del thread pool.

---

## 2. Comparaciones Técnicas y Matriz de Compromisos (Trade-Off Matrix)

### 2.1 Compromisos del Modelo de Concurrencia

| Característica Dimensional | Node.js (Event-Driven / Single-Threaded Main Loop) | Thread-per-Request (Java Tomcat / Apache Prefork) | Go (Goroutines / Planificador M:N) |
| :--- | :--- | :--- | :--- |
| **Unidad Principal de Ejecución** | Hilo único de ejecución V8 + Event Loop | 1 hilo de SO por conexión HTTP | Goroutines en espacio de usuario multiplexadas en $M$ hilos de SO |
| **Estrategia de Manejo de I/O** | Asíncrona no bloqueante vía `epoll`/`kqueue` del SO | I/O síncrona bloqueante por hilo | No bloqueante vía `netpoller` oculta tras sintaxis síncrona |
| **Huella de Memoria / Conexión** | Extremadamente baja (~2KB - 4KB por socket handle) | Alta (~512KB - 2MB por pila de hilo) | Muy baja (~2KB por pila de goroutine) |
| **Impacto de Tareas Limitadas por CPU (CPU-Bound)** | **Severo:** Bloquea el hilo principal, detiene todo el loop del servidor | **Aislado:** Afecta únicamente al hilo worker individual | **Distribuido:** El planificador de robo de trabajo (work-stealing) migra las tareas |
| **Sobrecarga por Cambio de Contexto (Context Switching)** | Cero para la ejecución del Event Loop principal | Alto costo de cambio de contexto a nivel de kernel | Cambio de contexto en espacio de usuario extremadamente bajo |
| **Mejor Caso de Uso en Producción** | APIs intensivas en I/O, WebSockets, Proxy/Gateway | Aplicaciones legacy empresariales, Procesamiento síncrono pesado | Microservicios de alta concurrencia, Herramientas de red |

---

### 2.2 Sistemas de Módulos en Node.js: CommonJS (CJS) vs. ECMAScript Modules (ESM)

| Característica | CommonJS (CJS) | ECMAScript Modules (ESM) |
| :--- | :--- | :--- |
| **Especificación** | Estándar de facto de Node.js (`require` / `module.exports`) | Estándar oficial de ECMAScript (`import` / `export`) |
| **Momento de Resolución de Módulos** | **Dinámica en Runtime:** Se carga de forma síncrona cuando se invoca `require()` | **Estática en Parsing:** Se carga y vincula de forma asíncrona antes de la ejecución del código |
| **`await` de Nivel Superior (Top-Level `await`)** | No soportado (requiere envolver en una IIFE `async`) | Soportado nativamente en el nivel superior |
| **Soporte para Tree-Shaking** | Pobre / Imposible debido a la semántica dinámica de `require` | Excelente: El grafo de dependencias estático permite la eliminación de código muerto (dead-code elimination) |
| **Identificadores de Scope Integrados** | Proporciona `__dirname` y `__filename` | Excluye `__dirname`/`__filename` (Requiere `import.meta.url` + `fileURLToPath`) |
| **Interoperabilidad** | No puede utilizar `require()` directamente en paquetes ESM puros | Puede importar (`import`) módulos CJS, pero solo imports por defecto (default imports) |

---

### 2.3 Prioridad de Ejecución entre Microtask Queue y Macrotask Queue

Orden de ejecución dentro de un único giro (turn) del Event Loop:

```
[ Current Synchronous Stack ] 
            |
            v
[ Microtask: process.nextTick() Queue ]
            |
            v
[ Microtask: Promise Jobs (Microtask Queue) ]
            |
            v
[ Macrotask Phase Callback (e.g., Timers / Poll / Check) ]
```

```javascript
// Demonstration of Queue Execution Priority
console.log('1: Synchronous');

setTimeout(() => console.log('2: Macrotask (setTimeout)'), 0);
setImmediate(() => console.log('3: Macrotask (setImmediate)'));

Promise.resolve().then(() => console.log('4: Microtask (Promise.then)'));

process.nextTick(() => console.log('5: Microtask (process.nextTick)'));

console.log('6: Synchronous End');

// Execution Output Order:
// 1: Synchronous
// 6: Synchronous End
// 5: Microtask (process.nextTick)
// 4: Microtask (Promise.then)
// 2: Macrotask (setTimeout)  <-- Or 3 depending on timer resolution phase
// 3: Macrotask (setImmediate)
```

---

## 3. Infraestructura en Producción y Manifestos de Código

### 3.1 `package.json`

```json
{
  "name": "production-node-service",
  "version": "1.0.0",
  "description": "Production-grade enterprise Node.js HTTP Service",
  "main": "server.js",
  "type": "module",
  "engines": {
    "node": ">=20.10.0",
    "npm": ">=10.2.0"
  },
  "scripts": {
    "start": "node server.js",
    "dev": "node --watch server.js",
    "test": "node --test"
  },
  "dependencies": {
    "express": "^4.19.2"
  },
  "devDependencies": {
    "autocannon": "^7.15.0"
  },
  "private": true
}
```

---

### 3.2 `server.js` (Servidor de Producción con Graceful Shutdown y Probes de Salud)

```javascript
import http from 'node:http';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import express from 'express';

const app = express();
const PORT = process.env.PORT || 3000;

// State flags for Kubernetes Readiness Probe
let isShuttingDown = false;

// Middleware for parsing JSON requests
app.use(express.json());

// Liveness Probe Endpoint (Checks if process is alive)
app.get('/healthz', (req, res) => {
  res.status(200).json({ status: 'UP', timestamp: new Date().toISOString() });
});

// Readiness Probe Endpoint (Checks if application can accept traffic)
app.get('/readyz', (req, res) => {
  if (isShuttingDown) {
    return res.status(503).json({ status: 'DRAINING', message: 'Service is shutting down' });
  }
  // Check database or external dependencies connection state here
  res.status(200).json({ status: 'READY' });
});

// Business Logic Endpoint
app.get('/api/v1/resource', (req, res) => {
  res.status(200).json({
    id: 'res-9842',
    data: 'Production Operational Data',
    pid: process.pid,
  });
});

// HTTP Server Initialization
const server = http.createServer(app);

server.listen(PORT, () => {
  console.log(JSON.stringify({
    level: 'INFO',
    message: `Server initialized and listening on port ${PORT}`,
    pid: process.pid,
    nodeVersion: process.version,
  }));
});

// Graceful Shutdown Handler
function gracefulShutdown(signal) {
  console.log(JSON.stringify({
    level: 'WARN',
    message: `Received ${signal}. Starting graceful shutdown sequence...`,
    pid: process.pid,
  }));

  // Step 1: Mark app as shutting down to fail Readiness probes immediately
  isShuttingDown = true;

  // Step 2: Stop accepting new TCP connections
  server.close((err) => {
    if (err) {
      console.error(JSON.stringify({
        level: 'ERROR',
        message: 'Error encountered during HTTP server closure',
        error: err.message,
      }));
      process.exit(1);
    }

    console.log(JSON.stringify({
      level: 'INFO',
      message: 'All active HTTP connections closed cleanly. Exiting process.',
    }));
    process.exit(0);
  });

  // Step 3: Hard shutdown timeout force-kill if connections do not drain
  const FORCE_SHUTDOWN_TIMEOUT = 10000; // 10 Seconds
  const timer = setTimeout(() => {
    console.error(JSON.stringify({
      level: 'FATAL',
      message: 'Forced shutdown executed: Active connections failed to drain within timeout window.',
    }));
    process.exit(1);
  }, FORCE_SHUTDOWN_TIMEOUT);

  // Allow process to exit naturally if server closes before timer completes
  timer.unref();
}

// Signal Listeners
process.on('SIGTERM', () => gracefulShutdown('SIGTERM'));
process.on('SIGINT', () => gracefulShutdown('SIGINT'));

// Process Failure Protection Handlers
process.on('uncaughtException', (err) => {
  console.error(JSON.stringify({
    level: 'FATAL',
    message: 'Uncaught Exception detected in execution stack',
    error: err.message,
    stack: err.stack,
  }));
  // Uncaught exceptions leave the process in an undefined state; force termination
  process.exit(1);
});

process.on('unhandledRejection', (reason, promise) => {
  console.error(JSON.stringify({
    level: 'ERROR',
    message: 'Unhandled Promise Rejection detected',
    reason: reason instanceof Error ? reason.message : reason,
  }));
});
```

---

### 3.3 Dockerfile de Producción (Construcción Multietapa Segura con Distroless)

```dockerfile
# Stage 1: Build & Dependency Resolution
FROM node:20.15.0-alpine AS builder

WORKDIR /usr/src/app

# Copy dependency manifests
COPY package*.json ./

# Install production dependencies only via clean install
RUN npm ci --only=production && npm cache clean --force

# Copy application source code
COPY . .

# Stage 2: Final Minimal Runtime Image
FROM gcr.io/distroless/nodejs20-debian12:nonroot

WORKDIR /usr/src/app

# Copy built application and node_modules from builder
COPY --from=builder /usr/src/app /usr/src/app

# Set Production Environment Variables
ENV NODE_ENV=production \
    PORT=3000 \
    UV_THREADPOOL_SIZE=8

# Expose HTTP Port
EXPOSE 3000

# Execute as default non-root user (UID 65532 in distroless)
USER nonroot

# Run Node.js App
CMD ["server.js"]
```

---

### 3.4 Manifesto de Infraestructura para Kubernetes (`k8s-deployment.yaml`)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: node-service-deployment
  namespace: production
  labels:
    app.kubernetes.io/name: node-service
    app.kubernetes.io/tier: api
spec:
  replicas: 3
  selector:
    matchLabels:
      app: node-service
  template:
    metadata:
      labels:
        app: node-service
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        fsGroup: 65532
      containers:
        - name: node-service
          image: registry.internal.net/apps/node-service:1.0.0
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 3000
              name: http
          env:
            - name: NODE_ENV
              value: "production"
            - name: PORT
              value: "3000"
            - name: UV_THREADPOOL_SIZE
              value: "8"
          resources:
            requests:
              cpu: "250m"
              memory: "256Mi"
            limits:
              cpu: "1000m"
              memory: "512Mi"
          startupProbe:
            httpGet:
              path: /healthz
              port: 3000
            initialDelaySeconds: 2
            periodSeconds: 3
            failureThreshold: 5
          livenessProbe:
            httpGet:
              path: /healthz
              port: 3000
            initialDelaySeconds: 5
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /readyz
              port: 3000
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 2
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
---
apiVersion: v1
kind: Service
metadata:
  name: node-service-svc
  namespace: production
spec:
  type: ClusterIP
  ports:
    - port: 80
      targetPort: http
      protocol: TCP
      name: http
  selector:
    app: node-service
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: node-service-hpa
  namespace: production
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: node-service-deployment
  minReplicas: 3
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

---

### 3.5 Manifesto de Unidad de Servicio para Systemd (`/etc/systemd/system/node-app.service`)

```ini
[Unit]
Description=Production Node.js Application Service
After=network.target syslog.target

[Service]
Type=simple
User=node
Group=node
WorkingDirectory=/var/www/node-app
ExecStart=/usr/bin/node --max-old-space-size=4096 server.js
Restart=always
RestartSec=5s

# Environment Configuration
Environment=NODE_ENV=production
Environment=PORT=3000
Environment=UV_THREADPOOL_SIZE=8

# Security Isolation & Hardening
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
CapabilityBoundingSet=

# Resource Limits
LimitNOFILE=65536
LimitNPROC=4096
MemoryMax=4.5G

# Logging Redirect
StandardOutput=journal
StandardError=journal
SyslogIdentifier=node-app

[Install]
WantedBy=multi-user.target
```

---

## 4. Comandos Reales de CLI y Secuencias de Salida de Terminal

### 4.1 Gestión de Dependencias y Ejecución de Auditorías

```bash
$ npm init -y
Wrote to /var/www/node-app/package.json:

{
  "name": "node-app",
  "version": "1.0.0",
  "description": "",
  "main": "index.js",
  "scripts": {
    "test": "echo \"Error: no test specified\" && exit 1"
  },
  "keywords": [],
  "author": "",
  "license": "ISC"
}

$ npm install express --save
added 64 packages, and audited 65 packages in 1s

3 packages are looking for funding
  run `npm fund` for details

found 0 vulnerabilities

$ npm audit --production
found 0 vulnerabilities in 65 scanned packages
```

---

### 4.2 Inspección de Métricas de Memoria V8 y Estadísticas del Heap

```bash
$ node -e "console.log(v8.getHeapStatistics())"
{
  total_heap_size: 4743168,
  total_heap_size_executable: 524288,
  total_physical_size: 4743168,
  total_available_size: 4341738776,
  used_heap_size: 2712536,
  heap_size_limit: 4345298944,
  malloced_memory: 254128,
  peak_malloced_memory: 585720,
  does_zap_garbage: 0,
  number_of_native_contexts: 2,
  number_of_detached_contexts: 0,
  total_global_handles_size: 8192,
  used_global_handles_size: 2304
}
```

---

### 4.3 Activación de Depuración Remota con Node.js Inspector

```bash
$ node --inspect=0.0.0.0:9229 server.js
Debugger listening on ws://0.0.0.0:9229/c8a90fd1-512b-47e1-b1e9-4e781df5a021
For help, see: https://nodejs.org/en/docs/inspector
{"level":"INFO","message":"Server initialized and listening on port 3000","pid":40892,"nodeVersion":"v20.15.0"}
```

---

### 4.4 CPU Profiling y Análisis de Perfiles

```bash
$ node --prof server.js
# [Execute load test in separate terminal: autocannon -c 100 -d 10 http://localhost:3000/api/v1/resource]
^C

$ ls isolate-*.log
isolate-0x55d8f99e3000-41005-v8.log

$ node --prof-process isolate-0x55d8f99e3000-41005-v8.log > processed_profile.txt
$ head -n 25 processed_profile.txt
Statistical profiling result from isolate-0x55d8f99e3000-41005-v8.log, (15420 ticks, 12 unaccounted, 0 excluded).

 Shared libraries:
   ticks  total  nonlib   name
   11200   72.6%    0.0%  /usr/lib/x86_64-linux-gnu/libc.so
    2400   15.5%    0.0%  /usr/local/bin/node

 JavaScript:
   ticks  total  nonlib   name
     850    5.5%   46.7%  LazyCompile: *express /var/www/node-app/node_modules/express/lib/router/index.js:136:15
     320    2.1%   17.5%  LazyCompile: *http.createServer node:http:362:24

 C++:
   ticks  total  nonlib   name
     410    2.7%   22.5%  node::crypto::PBKDF2(v8::FunctionCallbackInfo<v8::Value> const&)
     150    1.0%    8.2%  uv__epoll_wait
```

---

### 4.5 Verificación de Señales de Terminación de Proceso (Traza de Graceful Shutdown)

```bash
# Terminal 1: Application Execution
$ node server.js
{"level":"INFO","message":"Server initialized and listening on port 3000","pid":42110,"nodeVersion":"v20.15.0"}

# Terminal 2: Send SIGTERM Signal
$ kill -SIGTERM 42110

# Terminal 1 Output Log:
{"level":"WARN","message":"Received SIGTERM. Starting graceful shutdown sequence...","pid":42110}
{"level":"INFO","message":"All active HTTP connections closed cleanly. Exiting process."}
$ echo $?
0
```

---

## 5. Guía de Verificación y Diagnóstico de Problemas (Troubleshooting)

### 5.1 Matriz de Árbol de Decisión de Diagnóstico

```
                          [ Issue Reported ]
                                  |
            +---------------------+---------------------+
            |                                           |
  [ High Latency / Lag ]                       [ OOM Crash / Leak ]
            |                                           |
            v                                           v
  Check Event Loop Lag                       Check V8 Heap Metrics
  (clinic doctor / perf)                     (node --trace-gc / heapdump)
            |                                           |
     +------+------+                             +------+------+
     |             |                             |             |
[Sync CPU]   [Thread Pool]                 [Global Vars] [Unclosed Sockets]
  Block        Exhaustion                    Reference      or Listeners
```

---

### 5.2 Síntoma 1: Inanición del Event Loop (Event Loop Starvation) / Bloqueo del Hilo Principal

#### Causa Raíz:
Ejecución de operaciones síncronas (algoritmos $O(N^2)$, `JSON.parse()` voluminosos, I/O de archivos síncrona con `fs.readFileSync`, o evaluación de expresiones regulares con ReDoS) directamente en el hilo principal.

#### Comando de Verificación de Diagnóstico:
Utilice `clinic doctor` para detectar el bloqueo del Event Loop:

```bash
$ npx clinic doctor -- node server.js
$ autocannon -c 100 -d 10 http://localhost:3000/api/v1/compute
```

#### Traza de Log de Diagnóstico (`node --trace-event-categories v8,node,node.async_hooks server.js`):

```json
{"pid":43102,"tid":1,"ts":17109201,"ph":"B","cat":"node.perf","name":"event_loop_delay","args":{"delay":4582.12}}
```

#### Arquitectura de Mitigación:
Delegar los cálculos síncronos a **Worker Threads**:

```javascript
import { Worker, isMainThread, parentPort, workerData } from 'node:worker_threads';

if (isMainThread) {
  // Main Thread Route Delegate
  app.get('/api/v1/compute', (req, res) => {
    const worker = new Worker(new URL(import.meta.url), { workerData: { target: 45 } });
    worker.on('message', (result) => res.json({ result }));
    worker.on('error', (err) => res.status(500).json({ error: err.message }));
  });
} else {
  // Worker Thread Execution Logic
  const fibonacci = (n) => (n <= 1 ? n : fibonacci(n - 1) + fibonacci(n - 2));
  const result = fibonacci(workerData.target);
  parentPort.postMessage(result);
}
```

---

### 5.3 Síntoma 2: Fuga de Memoria V8 (V8 Memory Leak) / Out of Memory (OOM)

#### Causa Raíz:
Retención de referencias a objetos en memoria impidiendo la Recolección de Basura (Garbage Collection) (por ejemplo, arrays globales en constante crecimiento, listeners de `EventEmitter` olvidados, sockets de BD no cerrados).

#### Comando de Verificación de Diagnóstico:

```bash
$ node --trace-gc --max-old-space-size=512 server.js
```

#### Secuencia Real de Log del GC (Indicando Presión de Memoria):

```
[44100:0x559e12000000]     1254 ms: Scavenge 240.5 (258.0) -> 235.1 (258.0) MB, 4.2 ms 
[44100:0x559e12000000]     2410 ms: Mark-sweep 480.2 (512.0) -> 460.5 (512.0) MB, 82.4 ms 
[44100:0x559e12000000]     3120 ms: Mark-sweep 505.8 (512.0) -> 501.2 (512.0) MB, 110.1 ms 

<--- Last few GCs --->
[44100:0x559e12000000]     3850 ms: Mark-sweep (reduce) 510.1 (512.0) -> 509.8 (512.0) MB, 145.2 ms

<--- JS stack trace --->
FATAL ERROR: Reached heap limit Allocation failed - JavaScript heap out of memory
 1: 0xb83a40 node::Abort() [/usr/local/bin/node]
 2: 0xa9c25e node::FatalError(char const*, char const*) [/usr/local/bin/node]
 3: 0xd3e512 v8::internal::V8::FatalProcessOutOfMemory(v8::internal::Isolate*, char const*, v8::OOMDetails const&) [/usr/local/bin/node]
```

#### Remediación y Captura de Heap Snapshot:
Inyectar volcado programático de Heap Snapshot:

```javascript
import v8 from 'node:v8';
import fs from 'node:fs';

app.get('/admin/heapdump', (req, res) => {
  const fileName = `/tmp/heap-${Date.now()}.heapsnapshot`;
  const stream = v8.getHeapSnapshot();
  const writeStream = fs.createWriteStream(fileName);
  stream.pipe(writeStream);
  
  writeStream.on('finish', () => {
    res.json({ message: 'Snapshot generated', path: fileName });
  });
});
```

---

### 5.4 Síntoma 3: Agotamiento del Thread Pool de libuv (Thread Pool Exhaustion)

#### Causa Raíz:
Ejecución concurrente de operaciones asíncronas bloqueantes que exceden el `UV_THREADPOOL_SIZE` predeterminado (4). Por ejemplo, 10 peticiones concurrentes que invocan `crypto.pbkdf2()` detendrán las operaciones de I/O de archivos restantes hasta que se liberen slots en el thread pool.

#### Comando de Prueba de Verificación y Resolución:

```bash
# Execute with default UV_THREADPOOL_SIZE=4
$ time node -e "
const crypto = require('crypto');
for(let i=0; i<8; i++) {
  crypto.pbkdf2('pass', 'salt', 100000, 512, 'sha512', () => console.log('Done', i));
}
"
Done 0
Done 1
Done 2
Done 3
# Pauses...
Done 4
Done 5
Done 6
Done 7
real    0m1.842s

# Execute with expanded UV_THREADPOOL_SIZE=8
$ UV_THREADPOOL_SIZE=8 time node -e "
const crypto = require('crypto');
for(let i=0; i<8; i++) {
  crypto.pbkdf2('pass', 'salt', 100000, 512, 'sha512', () => console.log('Done', i));
}
"
Done 0
Done 1
Done 2
Done 3
Done 4
Done 5
Done 6
Done 7
real    0m0.920s
```

---

## 6. Referencias

* **Visión General de LPI Web Development Essentials:**  
  https://www.lpi.org/our-certifications/web-development-essentials-overview/
* **Documentación Oficial y Referencia de la API de Node.js:**  
  https://nodejs.org/en/docs/
* **Event Loop, Timers y process.nextTick() en Node.js:**  
  https://nodejs.org/en/docs/guides/event-loop-timers-and-nexttick/
* **Documentación del Diseño Arquitectónico de libuv:**  
  https://docs.libuv.org/en/v1.x/design.html
* **Arquitectura del Motor de JavaScript Google V8:**  
  https://v8.dev/