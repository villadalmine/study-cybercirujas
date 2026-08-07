# CNCF / LPI-030-100 Material de Estudio: Tema 5.1 – Node.js Basics

**Objetivo del Examen:** LPI Web Development Essentials (Examen 030-100, Versión 1.0)  
**Tema 5.1:** Node.js Basics  
**Ponderación:** 2.5  
**Referencias Oficiales:**
* [LPI Web Development Essentials Overview](https://www.lpi.org/our-certifications/web-development-essentials-overview/)
* [Node.js Official Documentation: Event Loop, Timers, and process.nextTick()](https://nodejs.org/en/learn/asynchronous-work/event-loop-timers-and-nexttick)
* [Node.js Official Documentation: Modules System](https://nodejs.org/api/modules.html)

---

## Análisis Arquitectónico Profundo: Runtime e Internales de Node.js

Node.js es un entorno de ejecución (runtime) de JavaScript de código abierto, multiplataforma y de un solo hilo (single-threaded) construido sobre el **V8 JavaScript Engine** de Google Chrome y la biblioteca en C **libuv**.

```
+-------------------------------------------------------+
|                    Application Code                   |
+-------------------------------------------------------+
|        Node.js Standard Library (fs, http, path)      |
+---------------------------+---------------------------+
|      V8 Engine (JS)       |   Node.js C++ Bindings    |
+---------------------------+---------------------------+
|                          libuv                        |
|  (Event Loop, Asynchronous I/O Pool, Thread Pool)     |
+-------------------------------------------------------+
|                   Operating System                    |
+-------------------------------------------------------+
```

### Componentes Core de la Arquitectura

1. **V8 Engine**: Compila el código fuente de JavaScript directamente a código de máquina nativo (compilación JIT) y maneja la asignación de memoria, la ejecución del Call Stack y la recolección de basura (Mark-and-Sweep).
2. **libuv**: Implementa una capa de abstracción multiplataforma para I/O asíncrono orientado a eventos. Maneja el **Event Loop** y gestiona un Thread Pool en segundo plano (tamaño por defecto: 4 threads, configurable a través de `UV_THREADPOOL_SIZE`) para operaciones de I/O bloqueantes como el acceso a disco (`fs`) y búsquedas DNS.
3. **Fases de Ejecución del Event Loop**:
   * **Timers Phase**: Ejecuta callbacks programados por `setTimeout()` e `setInterval()`.
   * **Pending Callbacks Phase**: Ejecuta callbacks de I/O diferidos a la siguiente iteración del loop (ej., manejo de errores TCP).
   * **Idle / Prepare Phase**: Usado internamente por Node.js.
   * **Poll Phase**: Obtiene nuevos eventos de I/O; ejecuta callbacks relacionados con I/O. Node.js se bloqueará aquí cuando sea apropiado.
   * **Check Phase**: Ejecuta callbacks invocados por `setImmediate()`.
   * **Close Callbacks Phase**: Ejecuta handlers de cierre (ej., `socket.on('close', ...)`).

> **Prioridad de Ejecución de la Microtask Queue:**  
> Las Microtasks se ejecutan inmediatamente después de la fase actual, antes de pasar a la siguiente fase del Event Loop. La cola de `process.nextTick()` tiene prioridad absoluta sobre la Microtask Queue de `Promise`.

---

## Ejercicio 1: Mecánica del Event Loop, Microtasks y Orden de Ejecución

### Objetivo
Diagnosticar el orden de programación de eventos a bajo nivel observando cómo `process.nextTick()`, `Promise.then()`, `setTimeout()`, `setImmediate()` y la ejecución síncrona se intercalan a través de V8 y `libuv`.

### Instrucciones Paso a Paso

1. Creá un directorio de trabajo e inicializá un nuevo script de prueba llamado `event-loop-test.js`:

```bash
mkdir -p node-sre-lab && cd node-sre-lab
cat << 'EOF' > event-loop-test.js
const fs = require('node:fs');

console.log('[1] Synchronous: Call Stack start');

setTimeout(() => {
  console.log('[2] Timers Phase: setTimeout (0ms)');
}, 0);

setImmediate(() => {
  console.log('[3] Check Phase: setImmediate');
});

process.nextTick(() => {
  console.log('[4] Microtask: process.nextTick');
});

Promise.resolve().then(() => {
  console.log('[5] Microtask: Promise.then');
});

fs.readFile(__filename, () => {
  console.log('[6] Poll Phase: I/O Callback completed');

  setTimeout(() => {
    console.log('[7] Nested Timers Phase: setTimeout inside I/O');
  }, 0);

  setImmediate(() => {
    console.log('[8] Nested Check Phase: setImmediate inside I/O');
  });
});

console.log('[9] Synchronous: Call Stack end');
EOF
```

2. Ejecutá el script usando el runtime de Node.js:

```bash
node event-loop-test.js
```

**Salida de CLI Esperada:**
```text
[1] Synchronous: Call Stack start
[9] Synchronous: Call Stack end
[4] Microtask: process.nextTick
[5] Microtask: Promise.then
[2] Timers Phase: setTimeout (0ms)
[3] Check Phase: setImmediate
[6] Poll Phase: I/O Callback completed
[8] Nested Check Phase: setImmediate inside I/O
[7] Nested Timers Phase: setTimeout inside I/O
```

---

### Preguntas de Comprensión - Ejercicio 1

1. ¿Por qué `[8] Nested Check Phase: setImmediate inside I/O` se ejecuta de manera consistente **antes** de `[7] Nested Timers Phase: setTimeout inside I/O` cuando se programa dentro de un callback de I/O?
2. ¿Qué le sucedería al Event Loop si una función recursiva invocara `process.nextTick()` indefinidamente sin retornar?

---

## Ejercicio 2: Sistemas de Módulos (CommonJS vs. ESM) y Ciclo de Vida de Paquetes

### Objetivo
Comparar las diferencias estructurales, la semántica de carga de módulos y los mecanismos de aislamiento de dependencias entre **CommonJS (CJS)** y **ECMAScript Modules (ESM)**, y configurar un manifiesto `package.json` estricto.

### Instrucciones Paso a Paso

1. Inicializá un manifiesto de proyecto moderno de Node.js:

```bash
cat << 'EOF' > package.json
{
  "name": "sre-node-app",
  "version": "1.0.0",
  "description": "Production Node.js Architecture Lab",
  "main": "index.js",
  "type": "module",
  "scripts": {
    "start": "node index.js",
    "test": "node --test"
  },
  "dependencies": {
    "uuid": "^9.0.1"
  },
  "engines": {
    "node": ">=18.0.0"
  }
}
EOF
```

2. Creá un módulo auxiliar CJS llamado `legacy-config.cjs`:

```bash
cat << 'EOF' > legacy-config.cjs
module.exports = {
  environment: process.env.NODE_ENV || 'development',
  maxConnections: 100
};
EOF
```

3. Creá un módulo de servicio ESM llamado `metrics.js`:

```bash
cat << 'EOF' > metrics.js
import { performance } from 'node:perf_hooks';

export class SystemMetrics {
  #startTime = performance.now();

  getUptime() {
    return (performance.now() - this.#startTime).toFixed(2);
  }
}

export const formatBytes = (bytes) => `${(bytes / 1024 / 1024).toFixed(2)} MB`;
EOF
```

4. Creá el punto de entrada de la aplicación `index.js` importando módulos ESM y CJS:

```bash
cat << 'EOF' > index.js
import { SystemMetrics, formatBytes } from './metrics.js';
import legacyConfig from './legacy-config.cjs';
import os from 'node:os';

const metrics = new SystemMetrics();

console.log('--- System Diagnostic initialized ---');
console.log(`Environment: ${legacyConfig.environment}`);
console.log(`Max Connections: ${legacyConfig.maxConnections}`);
console.log(`Total Memory: ${formatBytes(os.totalmem())}`);
console.log(`Free Memory: ${formatBytes(os.freemem())}`);
console.log(`Initial Uptime: ${metrics.getUptime()} ms`);
EOF
```

5. Ejecutá la aplicación:

```bash
node index.js
```

**Salida de CLI Esperada:**
```text
--- System Diagnostic initialized ---
Environment: development
Max Connections: 100
Total Memory: 16384.00 MB
Free Memory: 8192.00 MB
Initial Uptime: 2.15 ms
```

---

### Preguntas de Comprensión - Ejercicio 2

1. ¿Cómo difiere el proceso de resolución e instanciación de módulos entre CommonJS (`require()`) y ECMAScript Modules (`import`)?
2. Si `package.json` define `"type": "module"`, ¿cómo puede un desarrollador forzar que un archivo específico sea interpretado como un módulo CommonJS sin modificar `package.json`?

---

## Ejercicio 3: Servidor Web HTTP Asíncrono sin Dependencias y Streams

### Objetivo
Implementar un servidor web HTTP listo para producción usando los módulos nativos `node:http` y `node:stream`, manejando ruteo de peticiones, resolución de queries, manipulación de cabeceras, errores de forma elegante (graceful errors) e I/O por streaming eficiente en memoria.

### Instrucciones Paso a Paso

1. Creá un archivo llamado `server.js`:

```bash
cat << 'EOF' > server.js
import http from 'node:http';
import { URL } from 'node:url';
import fs from 'node:fs';
import path from 'node:path';
import { pipeline } from 'node:stream/promises';

const PORT = process.env.PORT || 8080;
const LOG_FILE = path.join(process.cwd(), 'access.log');

const logStream = fs.createWriteStream(LOG_FILE, { flags: 'a' });

const server = http.createServer(async (req, res) => {
  const parsedUrl = new URL(req.url, `http://${req.headers.host}`);
  const timestamp = new Date().toISOString();

  logStream.write(`[${timestamp}] ${req.method} ${parsedUrl.pathname}\n`);

  // Route: GET /api/health
  if (req.method === 'GET' && parsedUrl.pathname === '/api/health') {
    const payload = JSON.stringify({ status: 'UP', uptime: process.uptime() });
    res.writeHead(200, {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(payload)
    });
    return res.end(payload);
  }

  // Route: GET /api/log
  if (req.method === 'GET' && parsedUrl.pathname === '/api/log') {
    if (!fs.existsSync(LOG_FILE)) {
      res.writeHead(404, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: 'Log file not found' }));
    }

    res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
    try {
      const readStream = fs.createReadStream(LOG_FILE);
      await pipeline(readStream, res);
    } catch (err) {
      console.error('Stream failure:', err);
    }
    return;
  }

  // 404 Fallback
  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'Route not found' }));
});

server.listen(PORT, () => {
  console.log(`Server listening on port ${PORT}`);
});
EOF
```

2. Iniciá el servidor HTTP en segundo plano:

```bash
node server.js &
SERVER_PID=$!
sleep 1
```

3. Consultá el endpoint de health usando `curl`:

```bash
curl -i http://localhost:8080/api/health
```

**Salida de CLI Esperada:**
```http
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 35
Date: Fri, 07 Aug 2026 03:30:44 GMT
Connection: keep-alive

{"status":"UP","uptime":0.123456}
```

4. Transmití el archivo de registro (log) de vuelta a través de HTTP vía streaming:

```bash
curl -i http://localhost:8080/api/log
```

**Salida de CLI Esperada:**
```http
HTTP/1.1 200 OK
Content-Type: text/plain; charset=utf-8
Date: Fri, 07 Aug 2026 03:30:45 GMT
Connection: keep-alive

[2026-08-07T03:30:44.100Z] GET /api/health
[2026-08-07T03:30:45.200Z] GET /api/log
```

5. Limpiá el proceso en segundo plano:

```bash
kill $SERVER_PID
```

---

### Preguntas de Comprensión - Ejercicio 3

1. ¿Por qué es preferible el `pipeline` de `stream/promises` frente a `fs.readFileSync()` o encadenar directamente `.pipe()` al manejar descargas de archivos sobre HTTP en Node.js?
2. ¿Qué problema ocurre cuando un cliente de red lento consume datos más lentamente de lo que el servidor los lee del disco, y cómo resuelven este problema los Streams de Node.js?

---

## Ejercicio 4: Control de Procesos en Producción, Señales y Depuración

### Objetivo
Implementar el manejo de señales para un apagado gradual o elegante (graceful shutdown) (`SIGINT`/`SIGTERM`), capturar excepciones no manejadas y habilitar flags de inspección en runtime para monitoreo en producción.

### Instrucciones Paso a Paso

1. Creá un script llamado `resilient-app.js`:

```bash
cat << 'EOF' > resilient-app.js
import http from 'node:http';

const server = http.createServer((req, res) => {
  res.writeHead(200);
  res.end('Processing workload...\n');
});

server.listen(3000, () => {
  console.log('[App] Operational on PID:', process.pid);
});

// Unhandled Promise Rejection Handler
process.on('unhandledRejection', (reason, promise) => {
  console.error('[ALERT] Unhandled Rejection at:', promise, 'reason:', reason);
});

// Uncaught Exception Handler
process.on('uncaughtException', (err) => {
  console.error('[CRITICAL] Uncaught Exception:', err.message);
  // Graceful shutdown after critical failure
  shutdown('UNCAUGHT_EXCEPTION', 1);
});

// Signal Handling
const shutdown = (signal, exitCode = 0) => {
  console.log(`[Lifecycle] Received ${signal}. Initiating graceful shutdown...`);
  
  server.close(() => {
    console.log('[Lifecycle] HTTP server closed. Releasing resources.');
    process.exit(exitCode);
  });

  // Force shutdown if cleanup hangs
  setTimeout(() => {
    console.error('[Lifecycle] Forced shutdown due to timeout.');
    process.exit(1);
  }, 5000).unref();
};

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
EOF
```

2. Iniciá la aplicación resiliente en segundo plano:

```bash
node resilient-app.js &
APP_PID=$!
sleep 1
```

3. Enviá una señal `SIGTERM` para activar la secuencia de finalización elegante:

```bash
kill -s SIGTERM $APP_PID
```

**Salida de CLI Esperada:**
```text
[App] Operational on PID: 42109
[Lifecycle] Received SIGTERM. Initiating graceful shutdown...
[Lifecycle] HTTP server closed. Releasing resources.
```

---

### Preguntas de Comprensión - Ejercicio 4

1. ¿Cuál es el peligro operativo de capturar `uncaughtException` y optar por **no** salir del proceso (`process.exit()`)?
2. ¿Qué hace `.unref()` cuando se invoca en el temporizador `setTimeout()` durante la secuencia de apagado elegante (graceful shutdown)?

---

<details>
<summary><b>Soluciones y Respuestas del Chequeo de Comprensión</b></summary>

### Soluciones del Ejercicio 1
1. **`setImmediate` vs `setTimeout` dentro de I/O:**  
   Dentro de un callback de I/O (fase Poll), el Event Loop completa la fase Poll y pasa inmediatamente a la **Check Phase**. Debido a que los callbacks de `setImmediate()` se ejecutan en la Check Phase, se garantiza que `setImmediate` se ejecute *antes* de la siguiente **Timers Phase** (donde reside `setTimeout`). Cuando se programa en el Call Stack principal, el orden depende de la alineación del reloj del sistema; dentro de callbacks de I/O, `setImmediate` es determinista.
2. **Recursión Infinita de `process.nextTick()`:**  
   Debido a que los callbacks de `process.nextTick()` se ejecutan en la Microtask Queue *inmediatamente después de que finaliza la operación actual y antes de que el Event Loop avance a la siguiente fase*, encolar `nextTick` de forma recursiva causa inanición (starvation) en el Event Loop. El loop nunca llegará a las fases Poll o Timers, congelando efectivamente todo el manejo de I/O y temporizadores (causando un crash por inanición del Event Loop).

---

### Soluciones del Ejercicio 2
1. **Diferencias en los Sistemas de Módulos:**  
   - **CommonJS (CJS):** Se carga de forma síncrona en runtime utilizando wrappers de funciones dinámicos (`require()`). Las salidas del módulo son valores copiados mutables (`module.exports`).
   - **ECMAScript Modules (ESM):** Se analizan sintácticamente (parse) y resuelven de forma asíncrona en tres fases estáticas distintas (Parsing/Loading, Instantiation, Evaluation) antes de la ejecución. Las exportaciones son **live bindings** (referencias de solo lectura a ubicaciones de memoria).
2. **Forzar CJS en Proyectos ESM:**  
   Un desarrollador puede forzar a Node.js a analizar un archivo como CommonJS asignándole la extensión de archivo `.cjs`. Alternativamente, definir `"type": "commonjs"` dentro de un `package.json` anidado en una subcarpeta invalida las configuraciones del proyecto padre para los archivos en ese directorio.

---

### Soluciones del Ejercicio 3
1. **Por qué `pipeline` de `stream/promises` es superior:**  
   `fs.readFileSync()` almacena todo el archivo en búfer en memoria (RAM) a la vez, causando picos severos de memoria para archivos grandes. Encadenar `.pipe()` sin manejo de errores deja los streams abiertos si la conexión HTTP se cae a mitad de la transferencia, lo que genera fugas de memoria y de file descriptors. `pipeline()` transmite datos fragmento a fragmento (chunk-by-chunk) y maneja automáticamente la limpieza, la contrapresión (backpressure) y la destrucción por error.
2. **Backpressure (Contrapresión):**  
   La contrapresión ocurre cuando la fuente (ej., stream de lectura rápida de disco) produce datos más rápido de lo que el destino (ej., stream de escritura lento en socket de red) puede consumirlos. El almacenamiento en búfer descontrolado genera un crecimiento ilimitado de la RAM. Los Streams de Node.js resuelven esto mediante límites de búfer internos (`highWaterMark`). Cuando el búfer de escritura se llena, el destino emite la señal `write() === false`, lo que indica al stream legible que haga `pause()` hasta que se emita un evento `drain`.

---

### Soluciones del Ejercicio 4
1. **Peligro de ignorar `uncaughtException`:**  
   Una excepción no capturada significa que el proceso V8 se encuentra en un estado indeterminado. Pueden quedar fugas de memoria, bloqueos de base de datos pendientes, estados globales corruptos o sockets escritos a medias. Continuar la ejecución después de una excepción no capturada corre el riesgo de servir datos corruptos o entrar en bloqueos mutuos (deadlocks). La aplicación debe registrar el error y finalizar para que un orquestador (como Kubernetes o Systemd) pueda iniciar una instancia limpia.
2. **Rol de `.unref()`:**  
   `.unref()` desvincula el temporizador del conteo de handles activos del Event Loop. Esto garantiza que si todas las conexiones de red activas y tareas de I/O se cierran antes del umbral de 5000 ms, Node.js saldrá de forma limpia e inmediata sin esperar a que expire el temporizador de 5 segundos.

</details>