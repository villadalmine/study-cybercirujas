# LPI 030-100: Tema 5.2 – Fundamentos de Node.js Express
**Objetivo del examen:** LPI Web Development Essentials (Examen 030-100, Versión 1.0)  
**Peso del tema:** 10  
**Audiencia objetivo:** SREs, Platform Engineers y Cloud Native Architects  
**Referencia oficial:** [LPI Web Development Essentials Overview](https://www.lpi.org/our-certifications/web-development-essentials-overview/) | [ExpressJS Official Documentation](https://expressjs.com/) | [Node.js Documentation](https://nodejs.org/docs/)

---

## Visión General Técnica y Arquitectura

Express es un framework web minimalista y no opinado (unopinionated) construido sobre el `http.Server` nativo de Node.js. Comprender Express a nivel de producción requiere saber cómo extiende las primitivas HTTP nativas de Node.js (`http.IncomingMessage` y `http.ServerResponse`) y cómo su motor de enrutamiento interno maneja el despacho de solicitudes a través de una pila de ejecución de middleware por capas.

```
                              Node.js HTTP Server Pipeline
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                                    v8 Event Loop                                        │
│                                                                                         │
│  Incoming TCP Connection ──> http.Server ('request' event)                             │
│                                           │                                             │
│                                           ▼                                             │
│                                  express() app function                                 │
│                                           │                                             │
│                                           ▼                                             │
│                                  app.handle(req, res)                                   │
│                                           │                                             │
│  ┌────────────────────────────────────────┴──────────────────────────────────────────┐  │
│  │                              express.Router.stack                               │  │
│  │                                                                                 │  │
│  │   Layer 1: Built-in Body Parser (express.json) ──> next()                         │  │
│  │   Layer 2: Security Middleware (Helmet/Cors)  ──> next()                         │  │
│  │   Layer 3: Custom Logger Middleware           ──> next()                         │  │
│  │   Layer 4: Router Match (/api/v1/metrics)     ──> next()                         │  │
│  │   Layer 5: Terminal Route Handler             ──> res.json(...)                  │  │
│  │   Layer 6: Error Handler Middleware           ──> (err, req, res, next)          │  │
│  └─────────────────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

### Arquitectura Central e Internos Mecánicos

1. **Delegación de Request y Response:**
   Express extiende el `http.IncomingMessage` nativo en `express.Request` (`req`) y el `http.ServerResponse` en `express.Response` (`res`) a través de herencia de prototipos. Métodos como `res.json()`, `res.status()` y `req.get()` envuelven operaciones de stream y manipulaciones de encabezados de más bajo nivel de Node.js.

2. **El Pipeline de Middleware (`app._router.stack`):**
   Las aplicaciones de Express mantienen un arreglo interno de instancias de `Layer`. Cada llamada a `app.use()`, `app.get()` o `app.post()` agrega un nuevo objeto `Layer` a `app._router.stack`. Un `Layer` encapsula:
   - Una expresión regular de coincidencia de ruta (route path matching).
   - La referencia a la función middleware.
   - El número de parámetros declarados (`fn.length`). Express se basa en la aridad de la firma de la función para diferenciar el middleware normal (`(req, res, next)`) del middleware de manejo de errores (`(err, req, res, next)`).

3. **Ejecución Asíncrona y Consideraciones del Event Loop:**
   Express 4.x **no** captura automáticamente Promesas rechazadas dentro de los handlers de middleware asíncronos (`async (req, res, next)`). Si ocurre un rechazo de promesa no capturado (unhandled promise rejection) dentro de un route handler `async`, este omite el middleware de error de Express y puede desencadenar un `UnhandledPromiseRejection` o hacer colapsar el proceso de Node.js. Las configuraciones de producción deben envolver explícitamente los handlers async, usar un wrapper global o actualizar a Express 5.x.

---

## Ejercicios Guiados Prácticos

### Ejercicio 1: Arquitectura de Middleware, Inspección del Layer Stack y Ciclo de Vida de la Solicitud

#### Objetivo
Construir un servidor nativo de Express 4, examinar la pila de capas (router layer stack) interna del router, inspeccionar la herencia de prototipos en los objetos request/response y escribir un middleware de diagnóstico personalizado.

#### Paso 1: Inicializar el Entorno del Proyecto
Crear un directorio limpio e inicializar un proyecto de Node.js usando `npm`.

```bash
mkdir -p express-sre-lab && cd express-sre-lab
npm init -y
npm install express@4.19.2
```

Salida esperada:
```text
Wrote to /home/student/express-sre-lab/package.json:
...
+ express@4.19.2
added 64 packages in 1.2s
```

#### Paso 2: Crear `server-internals.js`
Crear el archivo de aplicación `server-internals.js` con código completo y sintácticamente válido que exponga `app._router.stack` y demuestre la ejecución de middleware basada en aridad.

```javascript
const express = require('express');
const app = express();
const PORT = process.env.PORT || 3000;

// Built-in middleware to parse JSON bodies
app.use(express.json());

// Custom Middleware 1: Request Timing & SRE Diagnostics Header
app.use((req, res, next) => {
  req.startTime = process.hrtime.bigint();
  res.setHeader('X-SRE-Engine', 'Express-V8-Runtime');
  
  // Intercept completion to log latency
  res.on('finish', () => {
    const durationNs = process.hrtime.bigint() - req.startTime;
    const durationMs = Number(durationNs) / 1e6;
    console.log(`[METRIC] ${req.method} ${req.originalUrl} - Status: ${res.statusCode} - Latency: ${durationMs.toFixed(3)}ms`);
  });

  next();
});

// Route Handler: GET /health
app.get('/health', (req, res) => {
  res.status(200).json({ status: 'UP', timestamp: new Date().toISOString() });
});

// Route Handler: Internal Diagnostics Route
app.get('/debug/stack', (req, res) => {
  // Inspect internal router stack
  const stackSummary = app._router.stack.map((layer, index) => {
    return {
      index,
      name: layer.name,
      keys: layer.keys,
      regexp: layer.regexp.toString(),
      handleArity: layer.handle.length,
      isRoute: !!layer.route
    };
  });

  res.json({
    prototypeChecks: {
      reqInheritsIncomingMessage: Object.getPrototypeOf(Object.getPrototypeOf(req)).constructor.name === 'IncomingMessage',
      resInheritsServerResponse: Object.getPrototypeOf(Object.getPrototypeOf(res)).constructor.name === 'ServerResponse'
    },
    routerStack: stackSummary
  });
});

// Terminal Error Handling Middleware (Arity = 4)
app.use((err, req, res, next) => {
  console.error('[ERROR] Caught by terminal handler:', err.message);
  res.status(500).json({ error: 'Internal Error', message: err.message });
});

app.listen(PORT, () => {
  console.log(`[INFO] Server listening on port ${PORT}`);
});
```

#### Paso 3: Ejecutar el Servidor y Verificar los Diagnósticos
Iniciar el servidor en segundo plano o en la terminal:

```bash
node server-internals.js
```

Salida esperada en la terminal del servidor:
```text
[INFO] Server listening on port 3000
```

Ejecutar una solicitud a `/debug/stack` usando `curl`:

```bash
curl -s http://localhost:3000/debug/stack | node -e "console.log(JSON.stringify(JSON.parse(require('fs').readFileSync(0, 'utf-8')), null, 2))"
```

Fragmento de salida HTTP esperada:
```json
{
  "prototypeChecks": {
    "reqInheritsIncomingMessage": true,
    "resInheritsServerResponse": true
  },
  "routerStack": [
    {
      "index": 0,
      "name": "query",
      "handleArity": 3,
      "isRoute": false
    },
    {
      "index": 1,
      "name": "expressInit",
      "handleArity": 3,
      "isRoute": false
    },
    {
      "index": 2,
      "name": "jsonParser",
      "handleArity": 3,
      "isRoute": false
    },
    {
      "index": 3,
      "name": "<anonymous>",
      "handleArity": 3,
      "isRoute": false
    },
    {
      "index": 4,
      "name": "bound dispatch",
      "handleArity": 3,
      "isRoute": true
    },
    {
      "index": 5,
      "name": "bound dispatch",
      "handleArity": 3,
      "isRoute": true
    },
    {
      "index": 6,
      "name": "<anonymous>",
      "handleArity": 4,
      "isRoute": false
    }
  ]
}
```

Verificar la salida de la consola del servidor para el seguimiento de métricas:
```text
[METRIC] GET /debug/stack - Status: 200 - Latency: 4.120ms
```

---

#### Preguntas de Comprensión - Ejercicio 1

1. ¿Por qué Express inspecciona `layer.handle.length` para identificar el middleware de manejo de errores, y qué sucede si un ingeniero define un handler de errores como `(err, req, res) => {}` omitiendo `next`?
2. Si se llama a `next()` múltiples veces dentro de una sola función de middleware, ¿cuál es el comportamiento exacto en tiempo de ejecución en Node.js?

---

### Ejercicio 2: Enrutamiento Modular, Propagación de Errores Async y Parseo de Solicitudes

#### Objetivo
Implementar sub-routers modulares (`express.Router()`), parsear parámetros de ruta (`req.params`) y cuerpos de solicitud (`req.body`), y diseñar un wrapper de propagación de errores async seguro para producción en Express 4.x.

#### Paso 1: Crear `routes/api.js`
Crear un directorio llamado `routes` y crear `api.js` implementando un recurso REST modular con handlers async.

```bash
mkdir -p routes
```

Crear `routes/api.js`:

```javascript
const express = require('express');
const router = express.Router();

// Simulated database resource
const metricsDB = new Map([
  ['node-1', { id: 'node-1', cpuUsage: 42.5, memoryFreeMB: 1024 }],
  ['node-2', { id: 'node-2', cpuUsage: 89.1, memoryFreeMB: 128 }]
]);

// Utility: Async Handler Wrapper for Express 4.x
const asyncHandler = (fn) => (req, res, next) => {
  Promise.resolve(fn(req, res, next)).catch(next);
};

// GET /api/v1/nodes/:id - Path Parameter Extraction
router.get('/nodes/:id', asyncHandler(async (req, res) => {
  const nodeId = req.params.id;
  
  if (!metricsDB.has(nodeId)) {
    const err = new Error(`Node identifier '${nodeId}' not found in cluster state.`);
    err.statusCode = 404;
    throw err; // Caught by asyncHandler and forwarded to next(err)
  }

  res.status(200).json({
    success: true,
    data: metricsDB.get(nodeId)
  });
}));

// POST /api/v1/nodes - JSON Body Parsing & Mutation
router.post('/nodes', asyncHandler(async (req, res) => {
  const { id, cpuUsage, memoryFreeMB } = req.body;

  if (!id || typeof cpuUsage !== 'number' || typeof memoryFreeMB !== 'number') {
    const err = new Error('Invalid payload parameters. Required: id (string), cpuUsage (number), memoryFreeMB (number)');
    err.statusCode = 400;
    throw err;
  }

  if (metricsDB.has(id)) {
    const err = new Error(`Node '${id}' already registered.`);
    err.statusCode = 409;
    throw err;
  }

  const newNode = { id, cpuUsage, memoryFreeMB };
  metricsDB.set(id, newNode);

  res.status(201).json({
    success: true,
    data: newNode
  });
}));

module.exports = router;
```

#### Paso 2: Crear `app-modular.js`
Crear `app-modular.js` para montar el sub-router y manejar códigos de estado HTTP estándar dinámicamente.

```javascript
const express = require('express');
const apiRouter = require('./routes/api');

const app = express();
const PORT = 3001;

// Body Parsers
app.use(express.json({ limit: '1mb' }));
app.use(express.urlencoded({ extended: false }));

// Mount Modular Sub-Router
app.use('/api/v1', apiRouter);

// 404 Catch-All Route Handler
app.use((req, res, next) => {
  const err = new Error(`Resource not found: ${req.method} ${req.originalUrl}`);
  err.statusCode = 404;
  next(err);
});

// Centralized Production Error Handling Middleware
app.use((err, req, res, next) => {
  const statusCode = err.statusCode || 500;
  
  console.error(`[ERROR] [${new Date().toISOString()}] ${req.method} ${req.originalUrl} - Status: ${statusCode} - ${err.message}`);
  
  res.status(statusCode).json({
    error: {
      status: statusCode,
      message: err.message,
      timestamp: new Date().toISOString()
    }
  });
});

app.listen(PORT, () => {
  console.log(`[INFO] Modular App listening on port ${PORT}`);
});
```

#### Paso 3: Ejecutar y Probar los Endpoints de la API
Iniciar la aplicación:

```bash
node app-modular.js
```

En otra terminal, probar solicitudes válidas e inválidas usando `curl`.

1. **Probar GET de un nodo existente:**
```bash
curl -i http://localhost:3001/api/v1/nodes/node-1
```
Salida esperada:
```http
HTTP/1.1 200 OK
Content-Type: application/json; charset=utf-8
Content-Length: 68

{"success":true,"data":{"id":"node-1","cpuUsage":42.5,"memoryFreeMB":1024}}
```

2. **Probar GET de un nodo inexistente (Propagación de Errores Async):**
```bash
curl -i http://localhost:3001/api/v1/nodes/node-99
```
Salida esperada:
```http
HTTP/1.1 404 Not Found
Content-Type: application/json; charset=utf-8

{"error":{"status":404,"message":"Node identifier 'node-99' not found in cluster state.","timestamp":"2026-08-07T03:32:00.000Z"}}
```

3. **Probar POST con payload inválido:**
```bash
curl -i -X POST http://localhost:3001/api/v1/nodes \
  -H "Content-Type: application/json" \
  -d '{"id": "node-3", "cpuUsage": "invalid_number"}'
```
Salida esperada:
```http
HTTP/1.1 400 Bad Request
Content-Type: application/json; charset=utf-8

{"error":{"status":400,"message":"Invalid payload parameters. Required: id (string), cpuUsage (number), memoryFreeMB (number)","timestamp":"2026-08-07T03:32:00.000Z"}}
```

---

#### Preguntas de Comprensión - Ejercicio 2

1. ¿Qué ocurre internamente cuando `express.json()` recibe una solicitud con el encabezado `Content-Type: application/json` donde el tamaño del cuerpo excede el `limit: '1mb'` configurado?
2. Si se omite `asyncHandler` en un route handler de Express 4 que lanza un error después de un punto `await`, ¿qué le sucede a la conexión del cliente HTTP?

---

### Ejercicio 3: Apagado Gradual (Señales POSIX) y Gestión de Memoria con Streams

#### Objetivo
Implementar un patrón SRE para la gestión del ciclo de vida con cero tiempo de inactividad (zero-downtime), interceptando señales POSIX (`SIGTERM`, `SIGINT`), rechazando nuevas conexiones, drenando las solicitudes en curso e implementando respuestas en stream para prevenir el agotamiento de memoria de V8.

#### Paso 1: Crear `server-sre-lifecycle.js`
Escribir un servidor de producción que demuestre el manejo adecuado de señales y el streaming de respuestas utilizando streams nativos de Node.js a través de respuestas de Express.

```javascript
const express = require('express');
const { Readable } = require('stream');
const app = express();
const PORT = 3002;

let isShuttingDown = false;

// Health Check with Liveness/Readiness Awareness
app.use((req, res, next) => {
  if (isShuttingDown && req.path !== '/health/liveness') {
    res.setHeader('Connection', 'close');
    return res.status(530).json({ error: 'Service Unavailable - Server Shutting Down' });
  }
  next();
});

app.get('/health/liveness', (req, res) => {
  res.status(200).json({ status: 'ALIVE' });
});

app.get('/health/readiness', (req, res) => {
  if (isShuttingDown) {
    return res.status(503).json({ status: 'NOT_READY', reason: 'SIGTERM received' });
  }
  res.status(200).json({ status: 'READY' });
});

// Route: Stream Large Log Payload (Zero V8 Memory Buffering)
app.get('/logs/stream', (req, res) => {
  res.setHeader('Content-Type', 'text/plain; charset=utf-8');
  res.setHeader('Transfer-Encoding', 'chunked');

  let lineCount = 0;
  const maxLines = 10000;

  // Create custom readable stream simulating log tailing
  const logStream = new Readable({
    read() {
      if (lineCount >= maxLines) {
        this.push(null); // End of stream
        return;
      }
      lineCount++;
      const chunk = `[LOG-LINE ${lineCount}] ${new Date().toISOString()} - SRE Event Monitoring Log Entry\n`;
      this.push(chunk);
    }
  });

  logStream.pipe(res);
});

const server = app.listen(PORT, () => {
  console.log(`[INFO] SRE Production Server running on PID ${process.pid} at port ${PORT}`);
});

// POSIX Signal Handling for Graceful Shutdown
const initiateGracefulShutdown = (signal) => {
  console.log(`[NOTICE] Received signal: ${signal}. Initiating graceful shutdown sequence...`);
  isShuttingDown = true;

  // Stop accepting new connections on the underlying HTTP server
  server.close((err) => {
    if (err) {
      console.error('[ERROR] Error closing HTTP server:', err);
      process.exit(1);
    }
    console.log('[INFO] HTTP server successfully closed. Cleaning up database connections & event loops.');
    process.exit(0);
  });

  // Forced termination timeout if connections fail to drain
  setTimeout(() => {
    console.error('[FATAL] Forced shutdown threshold (10s) reached. Terminating un-drained process.');
    process.exit(1);
  }, 10000).unref(); // Prevent timer from keeping event loop alive unnecessarily
};

process.on('SIGTERM', () => initiateGracefulShutdown('SIGTERM'));
process.on('SIGINT', () => initiateGracefulShutdown('SIGINT'));
```

#### Paso 2: Verificar la Latencia del Stream y el Manejo de Señales
Iniciar el servidor en ejecución en segundo plano:

```bash
node server-sre-lifecycle.js &
SERVER_PID=$!
sleep 1
```

Salida esperada:
```text
[INFO] SRE Production Server running on PID 12345 at port 3002
```

Transmitir registros en stream usando `curl` e inspeccionar los fragmentos del stream:

```bash
curl -s http://localhost:3002/logs/stream | head -n 5
```

Salida esperada:
```text
[LOG-LINE 1] 2026-08-07T03:32:00.000Z - SRE Event Monitoring Log Entry
[LOG-LINE 2] 2026-08-07T03:32:00.000Z - SRE Event Monitoring Log Entry
[LOG-LINE 3] 2026-08-07T03:32:00.000Z - SRE Event Monitoring Log Entry
[LOG-LINE 4] 2026-08-07T03:32:00.000Z - SRE Event Monitoring Log Entry
[LOG-LINE 5] 2026-08-07T03:32:00.000Z - SRE Event Monitoring Log Entry
```

Enviar `SIGTERM` para probar el apagado gradual:

```bash
kill -s SIGTERM $SERVER_PID
```

Salida esperada en consola:
```text
[NOTICE] Received signal: SIGTERM. Initiating graceful shutdown sequence...
[INFO] HTTP server successfully closed. Cleaning up database connections & event loops.
```

---

#### Preguntas de Comprensión - Ejercicio 3

1. ¿Por qué se utiliza `setTimeout(...).unref()` al configurar un temporizador de seguridad para la limpieza durante la finalización del proceso?
2. ¿Cuál es la ventaja en términos de memoria de utilizar `logStream.pipe(res)` en comparación con construir una sola cadena grande en memoria y ejecutar `res.send(largeString)`?

---

### Ejercicio 4: Diagnóstico Avanzado: Seguimiento del Retraso del Event Loop y Heap Dumps

#### Objetivo
Integrar los módulos `perf_hooks` y `v8` de Node.js para construir endpoints de diagnóstico dentro de Express para monitorear los picos de retraso del Event Loop y activar heap dumps bajo carga.

#### Paso 1: Crear `server-diagnostics.js`
Escribir el servidor de diagnóstico que demuestre la gestión del heap de V8 y el seguimiento del Event Loop.

```javascript
const express = require('express');
const { monitorEventLoopDelay } = require('perf_hooks');
const v8 = require('v8');
const path = require('path');
const fs = require('fs');

const app = express();
const PORT = 3003;

// Initialize Event Loop Delay Monitor (Resolution: 10ms)
const hgram = monitorEventLoopDelay({ resolution: 10 });
hgram.enable();

// Route: Real-Time Event Loop Metrics
app.get('/metrics/event-loop', (req, res) => {
  res.json({
    minNs: hgram.min,
    maxNs: hgram.max,
    meanNs: hgram.mean,
    stddevNs: hgram.stddev,
    p50Ns: hgram.percentile(50),
    p99Ns: hgram.percentile(99),
    memoryUsage: process.memoryUsage()
  });
});

// Route: Intentionally Block Event Loop (Simulating CPU Intensive Task)
app.get('/debug/block', (req, res) => {
  const durationMs = parseInt(req.query.ms, 10) || 500;
  const start = Date.now();
  
  // Synchronous CPU blocking loop
  while (Date.now() - start < durationMs) {
    Math.sqrt(Math.random() * 100000);
  }

  res.json({ message: `Event loop blocked synchronously for ${durationMs}ms` });
});

// Route: Generate Heap Snapshot for Memory Leak Diagnosis
app.get('/debug/heapdump', (req, res) => {
  const snapshotFileName = `heapdump-${Date.now()}.heapsnapshot`;
  const filePath = path.join(__dirname, snapshotFileName);

  const stream = v8.getHeapSnapshot();
  const writeStream = fs.createWriteStream(filePath);

  stream.pipe(writeStream);

  writeStream.on('finish', () => {
    const stats = fs.statSync(filePath);
    res.json({
      success: true,
      file: snapshotFileName,
      sizeBytes: stats.size
    });
  });
});

app.listen(PORT, () => {
  console.log(`[INFO] SRE Diagnostics Server listening on port ${PORT}`);
});
```

#### Paso 2: Ejecutar Diagnósticos y Desencadenar la Degradación del Event Loop
Iniciar el servidor:

```bash
node server-diagnostics.js &
DIAG_PID=$!
sleep 1
```

1. **Obtener estadísticas base del Event Loop:**
```bash
curl -s http://localhost:3003/metrics/event-loop | node -e "console.log(JSON.stringify(JSON.parse(require('fs').readFileSync(0, 'utf-8')), null, 2))"
```

2. **Inducir un bloqueo del Event Loop de 1000ms:**
```bash
curl -s "http://localhost:3003/debug/block?ms=1000"
```
Salida esperada:
```json
{"message":"Event loop blocked synchronously for 1000ms"}
```

3. **Obtener métricas actualizadas para verificar el pico de latencia P99:**
```bash
curl -s http://localhost:3003/metrics/event-loop | node -e "const data=JSON.parse(require('fs').readFileSync(0, 'utf-8')); console.log('p99 (ms):', data.p99Ns / 1e6);"
```
Salida esperada que muestra el pico de retraso:
```text
p99 (ms): 1000.447
```

4. **Desencadenar un V8 Heap Dump:**
```bash
curl -s http://localhost:3003/debug/heapdump
```
Salida esperada:
```json
{"success":true,"file":"heapdump-1770435120000.heapsnapshot","sizeBytes":4820194}
```

Proceso de limpieza:
```bash
kill -s SIGTERM $DIAG_PID
```

---

#### Preguntas de Comprensión - Ejercicio 4

1. ¿Por qué un bucle síncrono limitado por CPU dentro de un handler de Node.js Express degrada la latencia en *todas* las solicitudes de clientes concurrentes conectadas a ese proceso?
2. En un despliegue de Kubernetes en producción, ¿cómo afectan los altos retrasos del Event Loop a las verificaciones de los probes de liveness y readiness HTTP?

---

## Soluciones y Claves de Respuestas

<details>
<summary>Hacé clic para ver las respuestas de las Preguntas de Comprensión</summary>

### Respuestas para el Ejercicio 1

1. **Aridad de Funciones y Registro de Handlers de Error:**
   Express se basa en la propiedad `.length` del objeto Function de JavaScript para reflejar la cantidad de parámetros declarados (aridad). Un middleware normal declara 3 parámetros `(req, res, next)`, mientras que el middleware de manejo de errores requiere strictly 4 parámetros `(err, req, res, next)`. Si un ingeniero define un handler de errores como `(err, req, res) => {}`, `fn.length` se evalúa como `3`. Express lo tratará como una función de middleware estándar durante la iteración del stack, pasando `req` en el primer parámetro `err`, `res` en `req` y `next` en `res`. Esto da como resultado fallos en tiempo de ejecución de tipo `TypeError: res.status is not a function` y omite por completo el procesamiento de errores.

2. **Invocaciones Múltiples de `next()`:**
   El callback `next()` avanza el puntero de índice dentro de `app._router.stack`. Llamar a `next()` múltiples veces dentro de una sola función de middleware hace que Express ejecute las capas subsecuentes múltiples veces para el mismo ciclo de solicitud. Si los handlers descendentes realizan la emisión de la respuesta (`res.send()` o `res.json()`), la segunda llamada lanza una excepción no capturada del núcleo de Node.js: `ERR_HTTP_HEADERS_SENT: Cannot set headers after they are sent to the client`.

---

### Respuestas para el Ejercicio 2

1. **Aplicación del Límite de Body-Parser:**
   Cuando el tamaño del payload excede el umbral especificado (por ejemplo, `1mb`), el parser de stream interno de `body-parser` aborta el consumo del stream y crea un objeto `PayloadTooLargeError` (`err.type = 'entity.too.large'`, `err.statusCode = 413`). Luego invoca a `next(err)`, omitiendo los route handlers descendentes y pasando el control directamente al middleware de manejo de errores configurado.

2. **Errores Async sin Envolver en Express 4.x:**
   Los despachadores de ruta de Express 4 se ejecutan sincrónicamente en relación con la cadena de llamadas de middleware. Si una función `async` rechaza una promesa o lanza un error después de un punto `await` y **no** está envuelta en un try/catch que invoque a `next(err)` (o usando un wrapper como `asyncHandler`), el rechazo de la Promesa devuelta no es manejado por Express. La conexión HTTP permanece colgada hasta que ocurre el timeout del cliente, y Node.js registra un `UnhandledPromiseRejectionWarning` (o termina el proceso dependiendo del modo `--unhandled-rejections`).

---

### Respuestas para el Ejercicio 3

1. **Propósito de `setTimeout(...).unref()`:**
   Por defecto, los temporizadores activos mantienen activo el Event Loop de Node.js. Llamar a `.unref()` en el objeto `Timeout` lo desvincula del contador de referencias del Event Loop. Si todas las solicitudes HTTP en curso y las conexiones de socket terminan de drenarse antes de que expire el umbral de 10 segundos, el proceso de Node.js finaliza inmediatamente sin esperar a que el temporizador se active.

2. **Sobrecarga de Memoria de `pipe(res)` frente a `res.send()`:**
   Utilizar `res.send(largeString)` requiere asignar todo el buffer de respuesta en el Heap de V8 antes de la serialización, lo que puede exceder el límite máximo de memoria del heap (`--max-old-space-size`) o provocar pausas frecuentes de Recolección de Basura (Garbage Collection / GC). En contraste, `logStream.pipe(res)` transmite datos en pequeños fragmentos (típicamente buffers de 16KB-64KB), utilizando codificación de transferencia fragmentada HTTP (`Transfer-Encoding: chunked`). El uso de memoria se mantiene plano independientemente del tamaño total de la respuesta, y la contrapresión de TCP (backpressure) pausa automáticamente la lectura del stream si el socket de red del cliente es lento.

---

### Respuestas para el Ejercicio 4

1. **Impacto Global del Bloqueo del Event Loop:**
   Node.js opera en una arquitectura de Event Loop de un solo hilo (single-threaded) para la ejecución de JavaScript y el despacho de solicitudes. Cuando se ejecuta un bucle síncrono limitado por CPU, bloquea completamente el hilo principal. El Event Loop no puede procesar eventos de I/O, completar lecturas/escrituras de sockets ni programar callbacks de temporizadores para *ninguna* conexión HTTP entrante o existente en ese hilo hasta que se complete la operación síncrona.

2. **Impacto en los Probes de Kubernetes:**
   Kubernetes envía periódicamente solicitudes HTTP GET a los endpoints de liveness (`/health/liveness`) y readiness (`/health/readiness`) del contenedor. Si el Event Loop está bloqueado por una tarea de CPU de larga duración, el proceso de Node.js no puede responder a las solicitudes de probe dentro del `timeoutSeconds` configurado. Si los intentos fallidos exceden el `failureThreshold`, Kubernetes marca erróneamente el pod como no listo (removiéndolo de los Endpoints) o reinicia el contenedor (fallo de liveness), creando caídas en cascada del servicio (cascading service outages).

</details>

---

## Resumen de Referencia de Comandos

| Tarea | Comando |
| :--- | :--- |
| **Inicializar Proyecto Express** | `npm init -y && npm install express@4.19.2` |
| **Iniciar Servidor Express** | `node server.js` |
| **Inspeccionar Encabezados y Respuesta** | `curl -i http://localhost:3000/health` |
| **Simular Payload JSON** | `curl -X POST http://localhost:3001/api/v1/nodes -H "Content-Type: application/json" -d '{"id":"node-1","cpuUsage":50,"memoryFreeMB":512}'` |
| **Enviar Señal de Finalización POSIX** | `kill -s SIGTERM <PID>` |
| **Transmitir Endpoint de Seguimiento de Logs en Stream** | `curl -s http://localhost:3002/logs/stream \| head -n 20` |
| **Generar V8 Heap Snapshot** | `curl -s http://localhost:3003/debug/heapdump` |