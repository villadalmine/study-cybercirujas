# Guía de Estudio de Producción Avanzada: LPI 030-100 (Web Development Essentials v1.0)
## Tema 5.2: Node.js Express Basics
**Peso del examen:** 10 | **Audiencia objetivo:** Principal Platform Architects & Senior SREs

---

## 1. Motivación Arquitectónica de Producción y Planteamiento del Problema

### 1.1 El Paradigma de I/O No Bloqueante Monohilo (Single-Threaded Non-Blocking I/O)
Node.js se basa en el motor JavaScript V8 y en `libuv`, una biblioteca de abstracción de notificación de eventos de I/O asíncrona. A diferencia de las arquitecturas tradicionales de un hilo por petición (thread-per-request) (por ejemplo, Apache HTTP Server con `mod_php` o contenedores de Servlet de Java síncronos), Node.js ejecuta el JavaScript de la aplicación en un **hilo principal único** (single main thread). 

La concurrencia se logra a través del **Event Loop**, el cual delega las primitivas operativas asíncronas (tales como I/O de red no bloqueante, operaciones del sistema de archivos y callbacks de temporizadores) al kernel subyacente o a un pool de hilos en segundo plano (libuv worker pool).

```
                 +-----------------------------------+
                 |        V8 JavaScript Engine       |
                 |      (Main Execution Thread)      |
                 +-----------------------------------+
                                   |
                         Call Stack / Microtasks
                                   |
+----------------------------------v----------------------------------+
|                            libuv Event Loop                         |
|                                                                     |
|  +-----------------+   +------------------+   +------------------+  |
|  |     Timers      |   | Pending Callbacks|   |   Idle, Prepare  |  |
|  | (setTimeout/Interval)| (I/O Errors/OS)  |   |    (Internal)    |  |
|  +--------+--------+   +--------+---------+   +--------+---------+  |
|           |                     |                      |            |
|  +--------v--------+   +--------v---------+   +--------v---------+  |
|  |   Poll Phase    |---|   Check Phase    |---|   Close Callbacks|  |
|  | (Incoming I/O)  |   | (setImmediate)   |   | (socket.on('close'))|
|  +-----------------+   +------------------+   +------------------+  |
+----------------------------------+----------------------------------+
                                   |
           +-----------------------+-----------------------+
           |                                               |
+----------v----------+                         +----------v----------+
|  Kernel Async I/O   |                         |  libuv Worker Pool  |
| (epoll / kqueue /   |                         | (default: 4 threads |
|  IOCP for Network)  |                         |  DNS, Crypto, FS)   |
+---------------------+                         +---------------------+
```

### 1.2 El Problema de Inanición del Event Loop (Event Loop Starvation)
En las aplicaciones Node.js Express, cualquier operación síncrona y de uso intensivo de CPU bloquea directamente el hilo principal único. Mientras el hilo principal está ocupado ejecutando código síncrono (por ejemplo, operaciones criptográficas, procesamiento de JSON intensivo en CPU o expresiones regulares síncronas), el Event Loop no puede avanzar para procesar paquetes de red entrantes, manejar peticiones HTTP o ejecutar temporizadores expirados.

**Modo de Fallo Arquitectónico:**
1. Un endpoint de Express realiza un cálculo síncrono (por ejemplo, `JSON.parse()` en un payload de 50 MB o un hashing bcrypt síncrono).
2. El stack de ejecución del hilo principal de V8 se bloquea durante 1500 ms.
3. Node.js deja de procesar las colas de sockets (los eventos de `epoll` quedan sin procesar en el buffer del kernel).
4. Los nodos proxy de Ingress (Nginx/Envoy) registran alta latencia / errores HTTP 504 Gateway Timeout.
5. Las Liveness Probes de Kubernetes (`/livez`) dirigidas al contenedor de Express fallan porque el servidor HTTP no puede procesar las peticiones de prueba, desencadenando reinicios de Pods en cascada.

### 1.3 Memoria del Contenedor y Mecánica de Garbage Collection en V8
Dentro de contenedores Docker gobernados por Linux Control Groups (cgroups v1/v2), los procesos de Node.js deben ser ajustados explícitamente con respecto al consumo de memoria. El asignador de heap de V8 impone límites predeterminados al consumo de memoria (`--max-old-space-size`). Si el heap de V8 se expande más allá del límite de memoria del cgroup, el Out-Of-Memory (OOM) killer del kernel de Linux envía un `SIGKILL` (`signal 9`) directamente al proceso, omitiendo los manejadores de errores a nivel de aplicación y las rutinas de graceful shutdown.

---

## 2. Tablas de Comparación Técnica y Trade-offs

### 2.1 Modelos de Concurrencia en Runtimes Web

| Dimensión | Node.js / Express | Go / Gin | Java / Spring Boot (Tomcat clásico) | Python / FastAPI (uvicorn) |
| :--- | :--- | :--- | :--- | :--- |
| **Modelo de Ejecución** | Single Thread + Event Loop + Worker Pool | CSP Goroutines (M:N Scheduler) | Thread-per-request (Hilos de SO o Hilos Virtuales) | Asyncio Event Loop + Procesos Worker |
| **Huella de Memoria / Conexión Base** | ~30MB - 60MB base; baja memoria por conexión (~2-4KB por socket inactivo) | ~10MB base; ultra baja memoria por conexión (~2KB por stack de goroutine) | ~200MB - 500MB base; alta memoria por conexión (~1MB por stack de hilo) | ~40MB - 80MB base; baja memoria por conexión (~3-5KB por socket) |
| **Descarga de Tareas CPU-Bound** | Requiere Worker Threads (`worker_threads`) o Modo Cluster | Concurrencia nativa a través de procesadores multinúcleo | Multihilo nativo a través de todos los núcleos de CPU del SO | Multiprocesamiento (`ProcessPoolExecutor`) o Celery |
| **Manejo de Cuellos de Botella de I/O** | I/O Asíncrono No Bloqueante mediante libuv (`epoll`) | I/O asíncrono no bloqueante envuelto en sintaxis síncrona | I/O Síncrono Bloqueante (o Asíncrono mediante WebFlux / Hilos Virtuales) | I/O Asíncrono No Bloqueante mediante `uvloop` |
| **Máximo de Sockets Inactivos Concurrentes (Instancia Única)** | Alto (~50.000+) | Extremadamente Alto (~100.000+) | Moderado (~5.000 con hilos del SO) | Alto (~30.000+) |

### 2.2 Comparación de Arquitectura de Frameworks Web de Node.js

| Característica / Métrica | Express.js (v4/v5) | Fastify | Koa | NestJS (Express Engine) |
| :--- | :--- | :--- | :--- | :--- |
| **Arquitectura de Enrutamiento** | Middleware de enrutamiento lineal basado en regex | Coincidencia basada en árboles radix (vía `find-my-way`) | Cadena composicional de middlewares asíncronos | Abstracción de Controller basada en decoradores sobre Express |
| **Serialización JSON** | `JSON.stringify()` estándar (Llamada nativa bloqueante de V8) | Serialización compilada con esquemas (`fast-json-stringify`) | `JSON.stringify()` estándar | `JSON.stringify()` estándar / Class-transformer |
| **Cadena de Middleware** | Basada en callbacks (`req, res, next`) | Árbol de plugins encapsulado | Cascada Async/Await (`ctx, next`) | Inyección de dependencias empresarial + Pipes/Filters |
| **Madurez del Ecosistema de Producción** | Estándar de facto (Benchmark LPI 030-100) | Alternativa de alto rendimiento | Núcleo minimalista | Framework empresarial / de opinión firme (Opinionated) |

---

## 3. Código de Producción, Infraestructura y Manifiestos de Configuración

Los siguientes archivos sintácticamente válidos demuestran una aplicación Express de nivel de producción equipada con cabeceras de seguridad, rate limiting, registro estructurado (structured logging), métricas de Prometheus, manejo de graceful shutdown y manifiestos completos de despliegue en Kubernetes.

### 3.1 `package.json`

```json
{
  "name": "express-production-service",
  "version": "1.0.0",
  "description": "Production-grade Node.js Express Service for LPI 030-100 Architecture",
  "main": "server.js",
  "type": "commonjs",
  "scripts": {
    "start": "node server.js",
    "test": "node --test"
  },
  "dependencies": {
    "compression": "^1.7.4",
    "express": "^4.19.2",
    "express-rate-limit": "^7.3.0",
    "helmet": "^7.1.0",
    "pino": "^9.1.0",
    "pino-http": "^10.1.0",
    "prom-client": "^15.1.2"
  }
}
```

### 3.2 `server.js`

```javascript
'use strict';

const express = require('express');
const helmet = require('helmet');
const compression = require('compression');
const rateLimit = require('express-rate-limit');
const pino = require('pino');
const pinoHttp = require('pino-http');
const client = require('prom-client');

// Initialize Structured Logger
const logger = pino({
  level: process.env.LOG_LEVEL || 'info',
  formatters: {
    level: (label) => ({ level: label.toUpperCase() }),
  },
  timestamp: pino.stdTimeFunctions.isoTime,
});

const httpLogger = pinoHttp({ logger });
const app = express();

// Initialize Prometheus Metrics Registry
const register = new client.Registry();
client.collectDefaultMetrics({ register });

// Custom Prometheus Histogram for HTTP Latency Tracking
const httpRequestDurationMicroseconds = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'Duration of HTTP requests in seconds',
  labelNames: ['method', 'route', 'code'],
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5]
});
register.registerMetric(httpRequestDurationMicroseconds);

// Global State Flag for Readiness Probe
let isReady = true;

// 1. Security Middleware Layer (HTTP Headers hardening)
app.use(helmet());

// 2. Response Compression Layer
app.use(compression());

// 3. Structured Request Logging
app.use(httpLogger);

// 4. Rate Limiting Layer
const limiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutes
  limit: 100, // Limit each IP to 100 requests per window
  standardHeaders: true,
  legacyHeaders: false,
  message: { status: 429, error: 'Too Many Requests' }
});
app.use('/api/', limiter);

// 5. Body Parsing Layer
app.use(express.json({ limit: '1mb' }));
app.use(express.urlencoded({ extended: true, limit: '1mb' }));

// 6. Metrics Middleware Pipeline
app.use((req, res, next) => {
  const end = httpRequestDurationMicroseconds.startTimer();
  res.on('finish', () => {
    const route = req.route ? req.route.path : req.path;
    end({ method: req.method, route: route, code: res.statusCode });
  });
  next();
});

// Primary Business Logic Routes
app.get('/api/v1/resource', (req, res) => {
  res.status(200).json({
    status: 'success',
    data: {
      id: 'res_09af23',
      name: 'production-workload',
      environment: process.env.NODE_ENV || 'development'
    }
  });
});

// Liveness Probe Endpoint (Checks if V8 event loop responds)
app.get('/livez', (req, res) => {
  res.status(200).send('OK');
});

// Readiness Probe Endpoint (Checks if process can serve external traffic)
app.get('/readyz', (req, res) => {
  if (isReady) {
    res.status(200).send('OK');
  } else {
    res.status(503).send('Service Unavailable - Shutting Down');
  }
});

// Prometheus Metrics Endpoint
app.get('/metrics', async (req, res) => {
  try {
    res.set('Content-Type', register.contentType);
    res.end(await register.metrics());
  } catch (err) {
    res.status(500).end(err);
  }
});

// Centralized 404 Route Handler
app.use((req, res, next) => {
  res.status(404).json({ error: 'Resource Not Found' });
});

// Centralized Error Handling Middleware (4 arguments required by Express specification)
app.use((err, req, res, next) => {
  req.log.error({ err }, 'Unhandled application exception caught in middleware pipeline');
  res.status(err.status || 500).json({
    error: {
      message: process.env.NODE_ENV === 'production' ? 'Internal Server Error' : err.message
    }
  });
});

// Start Server Binding
const PORT = parseInt(process.env.PORT || '3000', 10);
const HOST = '0.0.0.0';

const server = app.listen(PORT, HOST, () => {
  logger.info(`Server initialized and listening on http://${HOST}:${PORT}`);
});

// Keep-Alive Configuration (Must exceed ingress timeout to avoid socket race conditions)
server.keepAliveTimeout = 65000; // 65 seconds
server.headersTimeout = 66000;   // 66 seconds

// Graceful Shutdown Mechanics
const shutdown = (signal) => {
  logger.warn(`Received ${signal}. Starting graceful shutdown procedure...`);
  isReady = false; // Fail readiness probes immediately so load balancer stops sending traffic

  // Allow existing in-flight connections to complete (up to 10 seconds)
  const forceShutdownTimeout = setTimeout(() => {
    logger.error('Forced shutdown invoked due to timeout draining connections.');
    process.exit(1);
  }, 10000);

  server.close(() => {
    logger.info('HTTP server closed successfully. Drained all active connections.');
    clearTimeout(forceShutdownTimeout);
    process.exit(0);
  });
};

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

process.on('uncaughtException', (err) => {
  logger.fatal({ err }, 'Fatal: Uncaught Exception detected');
  process.exit(1);
});

process.on('unhandledRejection', (reason, promise) => {
  logger.error({ reason, promise }, 'Unhandled Promise Rejection detected');
});
```

### 3.3 `Dockerfile` Multietapa de Producción

```dockerfile
# Stage 1: Build & Dependency Resolution
FROM node:20-alpine AS builder
WORKDIR /usr/src/app

# Install build dependencies if needed
COPY package*.json ./
RUN npm ci --only=production

# Stage 2: Final Secure Production Runtime Environment
FROM node:20-alpine AS runner
WORKDIR /usr/src/app

# Install tini for correct OS process init and signal forwarding (PID 1 handling)
RUN apk add --no-cache tini

ENV NODE_ENV=production \
    PORT=3000

COPY --chown=node:node package*.json ./
COPY --chown=node:node --from=builder /usr/src/app/node_modules ./node_modules
COPY --chown=node:node server.js ./

# Drop root privileges and run as non-root user 'node'
USER node

EXPOSE 3000

# Set entrypoint using tini to correctly forward SIGTERM/SIGINT signals to Node
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "--max-old-space-size=448", "server.js"]
```

### 3.4 Manifiesto Completo de Infraestructura de Kubernetes (`app-infrastructure.yaml`)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: express-app-deployment
  namespace: production
  labels:
    app.kubernetes.io/name: express-app
    app.kubernetes.io/part-of: e-commerce-backend
spec:
  replicas: 3
  selector:
    matchLabels:
      app: express-app
  template:
    metadata:
      labels:
        app: express-app
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      containers:
      - name: express-node-container
        image: registry.enterprise.internal/backend/express-service:1.0.0
        imagePullPolicy: IfNotPresent
        env:
        - name: NODE_ENV
          value: "production"
        - name: PORT
          value: "3000"
        - name: LOG_LEVEL
          value: "info"
        ports:
        - containerPort: 3000
          name: http-express
        resources:
          requests:
            cpu: "250m"
            memory: "256Mi"
          limits:
            cpu: "1000m"
            memory: "512Mi"
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop:
            - ALL
        livenessProbe:
          httpGet:
            path: /livez
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
        terminationMessagePolicy: File
        terminationMessagePath: /dev/termination-log
      terminationGracePeriodSeconds: 30
---
apiVersion: v1
kind: Service
metadata:
  name: express-app-service
  namespace: production
  labels:
    app.kubernetes.io/name: express-app
spec:
  type: ClusterIP
  ports:
  - port: 80
    targetPort: 3000
    protocol: TCP
    name: http
  selector:
    app: express-app
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: express-app-hpa
  namespace: production
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: express-app-deployment
  minReplicas: 3
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: express-app-pdb
  namespace: production
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: express-app
```

---

## 4. Comandos CLI Reales y Salidas de Terminal ($)

### 4.1 Construcción y Ejecución Local del Contenedor Docker
```bash
$ docker build -t express-service:1.0.0 .
[+] Building 8.4s (12/12) FINISHED
 => [internal] load build definition from Dockerfile                               0.0s
 => => transferring dockerfile: 712B                                               0.0s
 => [internal] load .dockerignore                                                  0.0s
 => => transferring context: 52B                                                   0.0s
 => [builder 1/4] FROM docker.io/library/node:20-alpine                            0.0s
 => CACHED [builder 2/4] WORKDIR /usr/src/app                                      0.0s
 => CACHED [builder 3/4] COPY package*.json ./                                     0.0s
 => CACHED [builder 4/4] RUN npm ci --only=production                              2.1s
 => CACHED [runner 3/5] RUN apk add --no-cache tini                                0.4s
 => [runner 4/5] COPY --chown=node:node package*.json ./                           0.1s
 => [runner 5/5] COPY --chown=node:node server.js ./                               0.1s
 => exporting to image                                                             0.2s
 => => naming to docker.io/library/express-service:1.0.0                          0.0s

$ docker run -d --name express-prod-node -p 3000:3000 --memory="512m" express-service:1.0.0
c4b281f62194a8f117c2f6d0f191b3901b0ad3a948e918d36bb931a72df9e89d
```

### 4.2 Inspección de Logs de Inicio de la Aplicación
```bash
$ docker logs express-prod-node
{"level":"INFO","time":"2026-08-07T07:35:10.112Z","pid":1,"hostname":"c4b281f62194","msg":"Server initialized and listening on http://0.0.0.0:3000"}
```

### 4.3 Consulta a la API e Inspección de Cabeceras de Respuesta
```bash
$ curl -i http://localhost:3000/api/v1/resource
HTTP/1.1 200 OK
Content-Security-Policy: default-src 'self';base-uri 'self';font-src 'self' https: data:;form-action 'self';frame-ancestors 'self';img-src 'self' data:;object-src 'none';script-src 'self';script-src-attr 'none';style-src 'self' https: 'unsafe-inline';upgrade-insecure-requests
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Resource-Policy: same-origin
Origin-Agent-Cluster: ?1
Referrer-Policy: no-referrer
Strict-Transport-Security: max-age=15552000; includeSubDomains
X-Content-Type-Options: nosniff
X-DNS-Prefetch-Control: off
X-Download-Options: noopen
X-Frame-Options: SAMEORIGIN
X-Permitted-Cross-Domain-Policies: none
X-XSS-Protection: 0
Content-Type: application/json; charset=utf-8
Content-Length: 104
ETag: W/"68-A3vN2a5Y4y/Nf0HlVj5T6S0rBtw"
Vary: Accept-Encoding
Date: Fri, 07 Aug 2026 07:36:00 GMT
Connection: keep-alive
Keep-Alive: timeout=65

{"status":"success","data":{"id":"res_09af23","name":"production-workload","environment":"production"}}
```

### 4.4 Verificación de la Salida de Métricas de Prometheus
```bash
$ curl -s http://localhost:3000/metrics | grep -E "^http_request_duration_seconds"
# HELP http_request_duration_seconds Duration of HTTP requests in seconds
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{le="0.005",method="GET",route="/api/v1/resource",code="200"} 1
http_request_duration_seconds_bucket{le="0.01",method="GET",route="/api/v1/resource",code="200"} 1
http_request_duration_seconds_bucket{le="+Inf",method="GET",route="/api/v1/resource",code="200"} 1
http_request_duration_seconds_sum{method="GET",route="/api/v1/resource",code="200"} 0.001842
http_request_duration_seconds_count{method="GET",route="/api/v1/resource",code="200"} 1
```

### 4.5 Prueba del Comportamiento de Graceful Shutdown (`SIGTERM`)
```bash
$ docker stop --time=15 express-prod-node
express-prod-node

$ docker logs express-prod-node
{"level":"INFO","time":"2026-08-07T07:35:10.112Z","pid":1,"hostname":"c4b281f62194","msg":"Server initialized and listening on http://0.0.0.0:3000"}
{"level":"WARN","time":"2026-08-07T07:40:12.441Z","pid":1,"hostname":"c4b281f62194","msg":"Received SIGTERM. Starting graceful shutdown procedure..."}
{"level":"INFO","time":"2026-08-07T07:40:12.445Z","pid":1,"hostname":"c4b281f62194","msg":"HTTP server closed successfully. Drained all active connections."}
```

---

## 5. Guía de Verificación, Depuración y Diagnóstico de Fallos

### 5.1 Diagnóstico de Retraso del Event Loop (Inanición)
El retraso del event loop indica que el código síncrono está reteniendo el hilo principal de V8. Los SRE pueden rastrear la latencia del event loop utilizando el módulo nativo `perf_hooks` de Node.js.

#### Fragmento de monitoreo integrado en la aplicación (In-App Monitoring):
```javascript
const { monitorEventLoopDelay } = require('perf_hooks');
const h = monitorEventLoopDelay({ resolution: 10 });
h.enable();

setInterval(() => {
  const p99 = h.percentile(99) / 1e6; // Convert nanoseconds to milliseconds
  if (p99 > 50) {
    logger.warn({ eventLoopLagMs: p99 }, 'CRITICAL: High Event Loop Lag detected');
  }
  h.reset();
}, 5000);
```

#### Comandos de diagnóstico a través de la CLI:
Inspeccione los sockets del sistema y el estado de los procesos mediante herramientas estándar de diagnóstico de red en Linux:
```bash
# Check socket queue backlogs on the Node.js port (Recv-Q > 0 indicates unhandled socket packets)
$ ss -tlpn 'sport = :3000'
State      Recv-Q Send-Q Local Address:Port  Peer Address:Port
LISTEN     128    128          0.0.0.0:3000       0.0.0.0:*     users:(("node",pid=14201,fd=18))
```

### 5.2 Análisis de Fugas de Memoria en el Heap y OOM Kills
Cuando un contenedor finaliza con el código de estado `137` (`128 + SIGKILL`), fue terminado por el OOM killer del kernel del SO debido a la aplicación del límite de memoria.

#### Paso 1: Confirmar el evento OOM en los logs del kernel de Linux
```bash
$ dmesg -T | grep -i "out of memory"
[Fri Aug 7 07:45:22 2026] Memory cgroup out of memory: Kill process 14201 (node) score 981 or sacrifice child
```

#### Paso 2: Capturar V8 Heap Snapshots de forma programática
Para diagnosticar fugas de memoria sin instalar herramientas APM de terceros:
```javascript
const v8 = require('v8');
const fs = require('fs');

app.post('/admin/heapdump', (req, res) => {
  const fileName = `/tmp/heapdump-${Date.now()}.heapsnapshot`;
  const stream = v8.getHeapSnapshot();
  const writeStream = fs.createWriteStream(fileName);
  stream.pipe(writeStream);
  
  writeStream.on('finish', () => {
    res.status(200).json({ status: 'Snapshot created', path: fileName });
  });
});
```

### 5.3 Modos de Fallo en la Ejecución Asíncrona del Middleware de Express
En Express 4.x, los errores no capturados dentro de los manejadores de rutas `async/await` **no se pasan automáticamente al middleware de errores**. Resultan en un **Unhandled Promise Rejection**, lo que potencialmente causa caídas del proceso o peticiones colgadas indefinidamente.

#### Antipatrón (Trampa asíncrona en Express 4):
```javascript
// BROKEN: If database Call fails, Express hangs until timeout and never returns HTTP 500
app.get('/api/async-broken', async (req, res, next) => {
  const data = await databaseQuery(); // If this rejects, next(err) is NEVER invoked!
  res.json(data);
});
```

#### Solución para producción 1: Envoltura explícita con Try-Catch
```javascript
// CORRECT: Catch error and pass explicitly to Express next()
app.get('/api/async-correct', async (req, res, next) => {
  try {
    const data = await databaseQuery();
    res.json(data);
  } catch (err) {
    next(err); // Route error into Centralized Error Handling Middleware
  }
});
```

#### Solución para producción 2: Función envolvente de orden superior (Higher-Order Wrapper Function)
```javascript
const asyncHandler = (fn) => (req, res, next) => {
  Promise.resolve(fn(req, res, next)).catch(next);
};

app.get('/api/async-wrapped', asyncHandler(async (req, res, next) => {
  const data = await databaseQuery();
  res.json(data);
}));
```

---

## 6. Referencias

* **Linux Professional Institute (LPI) Web Development Essentials Overview:**  
  [https://www.lpi.org/our-certifications/web-development-essentials-overview/](https://www.lpi.org/our-certifications/web-development-essentials-overview/)
* **Node.js Official Documentation - The Node.js Event Loop, Timers, and process.nextTick():**  
  [https://nodejs.org/en/docs/guides/event-loop-timers-and-nexttick/](https://nodejs.org/en/docs/guides/event-loop-timers-and-nexttick/)
* **Express.js Production Best Practices - Performance and Reliability:**  
  [https://expressjs.com/en/advanced/best-practice-performance.html](https://expressjs.com/en/advanced/best-practice-performance.html)
* **Express.js Production Best Practices - Security:**  
  [https://expressjs.com/en/advanced/best-practice-security.html](https://expressjs.com/en/advanced/best-practice-security.html)
* **Kubernetes Documentation - Pod Lifecycle & Probes:**  
  [https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/)