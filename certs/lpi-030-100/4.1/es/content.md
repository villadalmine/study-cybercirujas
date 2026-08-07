# Tema 4.1: Ejecución y Sintaxis de JavaScript

**Certificación del examen:** LPI Web Development Essentials (Exam 030-100, Version 1.0)  
**Peso del tema:** 2.5  
**Audiencia objetivo:** SREs, Platform Engineers y Cloud Architects  

---

## 1. Arquitectura de Producción y Motivación

Los modelos de ejecución de JavaScript difieren fundamentalmente de los lenguajes compilados como C++ o Go. En entornos de producción empresariales —ya sea ejecutando bundles frontend del lado del cliente en navegadores de usuario o microservicios backend en Pods de contenedores de Node.js— comprender la mecánica de la sintaxis de ejecución de JavaScript, el alcance de las variables (scope), el ciclo de vida de la memoria y los componentes internos del motor es esencial para prevenir fallos catastróficos en tiempo de ejecución, tales como la inanición del Event Loop (Event Loop starvation), pánicos de Out-Of-Memory (OOM) en el V8 heap y fugas de memoria sutiles.

```
                  +-------------------------------------------------------------+
                  |                     V8 Engine Instance                      |
                  |                                                             |
                  |  +--------------------+             +--------------------+  |
  JavaScript ---->|  | Ignition           | Bytecode    | TurboFan           |  |
  Source Code     |  | (Interpreter)      |------------>| (JIT Compiler)     |  |
                  |  +--------------------+             +--------------------+  |
                  |            |                                  |             |
                  |            v                                  v             |
                  |  +-------------------------------------------------------+  |
                  |  |                 Optimized Machine Code                |  |
                  |  +-------------------------------------------------------+  |
                  +-------------------------------------------------------------+
                                                 |
                                                 v
                  +-------------------------------------------------------------+
                  |                   Execution Architecture                    |
                  |                                                             |
                  |  +------------------------+      +-----------------------+  |
                  |  | Call Stack             |      | Memory Heap           |  |
                  |  | (Stack Frames / ECs)   |      | (Objects, Closures)   |  |
                  |  +------------------------+      +-----------------------+  |
                  |              |                                              |
                  |              v                                              |
                  |  +-------------------------------------------------------+  |
                  |  | Libuv / Event Loop (Macrotask & Microtask Queues)     |  |
                  |  +-------------------------------------------------------+  |
                  +-------------------------------------------------------------+
```

### Conceptos Arquitectónicos Clave

1. **Pipeline de Compilación JIT del Motor V8**:
   - **Parser**: Convierte el texto fuente raw de JavaScript en un Abstract Syntax Tree (AST).
   - **Ignition (Interpreter)**: Compila el AST en bytecode basado en registros. La ejecución comienza inmediatamente sin esperar la compilación completa.
   - **TurboFan (Optimizing Compiler)**: Analiza el perfilado de retroalimentación durante la ejecución (type feedback vectors). Las rutas de código caliente (hot code paths) se compilan directamente a código de máquina nativo optimizado. Si una suposición de tipo cambia en tiempo de ejecución (por ejemplo, pasar un `Float` a una función que previamente solo recibía enteros pequeños `Smi`), TurboFan realiza una desoptimización (**Deoptimization**), haciendo un bail-out a bytecodes en Ignition.

2. **Contextos de Ejecución y Scope**:
   - **Global Execution Context (GEC)**: Creado al iniciar el motor. Asigna bindings globales (`window` en navegadores, `global` en Node.js, estandarizándose en `globalThis` en entornos modernos).
   - **Function Execution Context (FEC)**: Se apila en el Call Stack al invocar una función. Asigna su propio `VariableEnvironment` y `LexicalEnvironment`.
   - **Block Scope Execution Context**: Introducido con ES6 `let` y `const`. Crea un scope de Lexical Environment efímero dentro de bloques `{ ... }` sin requerir un nuevo call frame de función.

3. **Modelo de Asignación de Memoria**:
   - **Call Stack**: Asignación de memoria fija que almacena tipos primitivos (`number`, `boolean`, `symbol`, `undefined`, `null`, `bigint`, punteros de referencia `string`) y frames de Execution Context.
   - **Memory Heap**: Asignación de memoria dinámica que almacena tipos de referencia complejos (`Object`, `Array`, `Function`, `Map`, `Set`). Administrado por el recolector de basura generacional de V8 (Scavenger para la Young Generation, Mark-Sweep-Compact para la Old Generation).

4. **Concurrencia de Un Solo Hilo (Single-Threaded) y Event Loop**:
   - El código de JavaScript se ejecuta estrictamente en un único hilo principal del Call Stack. Las operaciones sincrónicas bloqueantes detienen la ejecución por completo.
   - Los callbacks asincrónicos pasan a través de las colas del Event Loop:
     - **Microtask Queue**: `Promise.then()`, `process.nextTick()`, `queueMicrotask()`. Se vacía completamente antes de devolver el control al motor de renderizado o al loop de I/O.
     - **Macrotask Queue**: `setTimeout()`, `setInterval()`, `setImmediate()`, callbacks de I/O. Procesados una tarea por cada tick del Event Loop.

---

## 2. Comparativas Técnicas y Trade-Offs

### 2.1 Mecánica de Declaración de Variables: `var` vs `let` vs `const`

| Dimensión Técnica | `var` | `let` | `const` |
| :--- | :--- | :--- | :--- |
| **Nivel de Scope** | Function Scope / Global | Block Scope (`{}`) | Block Scope (`{}`) |
| **Comportamiento de Hoisting** | Con hoisting, inicializado como `undefined` | Con hoisting, no inicializado (Temporal Dead Zone) | Con hoisting, no inicializado (Temporal Dead Zone) |
| **Re-declaración** | Permitida dentro del mismo scope | SyntaxError dentro del mismo scope | SyntaxError dentro del mismo scope |
| **Re-asignación** | Permitida | Permitida | TypeError (el binding es inmutable) |
| **Propiedad del Objeto Global** | Se adjunta a `globalThis` si está en el nivel superior | NO se adjunta a `globalThis` | NO se adjunta a `globalThis` |
| **Mutación de Objetos** | N/A | Totalmente mutable | Valor mutable; binding inmutable |
| **Riesgo en Producción** | Alto (fuga global accidental, bugs de variable shadowing) | Bajo | El más bajo (previene la mutación del puntero de la variable) |

### 2.2 Mecánica de Igualdad: Igualdad Abstracta (`==`) vs Estricta (`===`)

La Igualdad Abstracta (`==`) invoca una conversión implícita de tipos (Type Coercion) a través del algoritmo `Abstract Equality Comparison Algorithm` de ECMA-262. La Igualdad Estricta (`===`) evalúa tanto la identidad de valor como la de tipo sin conversión.

| Expresión | Resultado Abstracto (`==`) | Resultado Estricto (`===`) | Mecanismo de Coerción / Regla Interna |
| :--- | :--- | :--- | :--- |
| `0 == "0"` | `true` | `false` | String convertido a Number (`ToNumber("0") -> 0`) |
| `0 == []` | `true` | `false` | Array convertido a Primitive mediante `ToPrimitive([]) -> ""` y luego `ToNumber("") -> 0` |
| `"0" == []` | `false` | `false` | Array convertido a Primitive `ToPrimitive([]) -> ""`, luego `"0" == ""` compara strings |
| `null == undefined` | `true` | `false` | Regla especial en la especificación ECMA: `null` y `undefined` solo son suavemente iguales (loosely equal) entre sí |
| `false == "0"` | `true` | `false` | `ToNumber(false) -> 0`, luego `0 == ToNumber("0")` |
| `NaN == NaN` | `false` | `false` | Requisito de la especificación ECMA: `NaN` nunca es igual a ningún valor, incluyéndose a sí mismo (requiere `Number.isNaN()`) |

---

## 3. Infraestructura de Producción y Manifiestos

Para observar la mecánica de ejecución de JavaScript, el comportamiento del scope de variables, los límites de recolección de basura de V8 y la ejecución en modo estricto en un entorno contenedorizado, construimos una aplicación de Node.js de producción desplegada en Kubernetes.

### 3.1 Aplicación Node.js (`app/server.js`)

```javascript
'use strict';

/**
 * Production JavaScript Runtime Demonstrator
 * Demonstrates Execution Contexts, Strict Mode, Temporal Dead Zone catching,
 * and V8 Heap Diagnostics.
 */

const http = require('http');
const v8 = require('v8');

const PORT = process.env.PORT || 8080;

// Verify strict mode behavior at runtime
function verifyStrictMode() {
  try {
    // In strict mode, assigning to an undeclared variable throws a ReferenceError
    undeclaredGlobalLeak = 42; 
  } catch (err) {
    return {
      strictModeActive: true,
      errorName: err.name,
      errorMessage: err.message
    };
  }
  return { strictModeActive: false };
}

// Demonstrate Scope and Temporal Dead Zone (TDZ) semantics
function evaluateScopeMechanics() {
  let tdzCaught = false;
  try {
    // Attempting to access let variable before declaration inside block scope
    const value = tdzVariable;
    let tdzVariable = 'initialized';
  } catch (err) {
    if (err instanceof ReferenceError) {
      tdzCaught = true;
    }
  }

  // Demonstrate closure memory retainment
  const heapBefore = process.memoryUsage().heapUsed;
  return {
    tdzProtectionVerified: tdzCaught,
    heapUsedBytes: heapBefore
  };
}

const server = http.createServer((req, res) => {
  if (req.url === '/healthz') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'HEALTHY' }));
    return;
  }

  if (req.url === '/diagnostics') {
    const strictMetrics = verifyStrictMode();
    const scopeMetrics = evaluateScopeMechanics();
    const v8HeapStats = v8.getHeapStatistics();

    const payload = {
      timestamp: new Date().toISOString(),
      nodeVersion: process.version,
      pid: process.pid,
      executionEngine: {
        strictMode: strictMetrics,
        scopeScopeSafety: scopeMetrics,
        v8Heap: {
          totalHeapSizeMb: (v8HeapStats.total_heap_size / 1024 / 1024).toFixed(2),
          usedHeapSizeMb: (v8HeapStats.used_heap_size / 1024 / 1024).toFixed(2),
          heapSizeLimitMb: (v8HeapStats.heap_size_limit / 1024 / 1024).toFixed(2),
        }
      }
    };

    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(payload, null, 2));
    return;
  }

  res.writeHead(404, { 'Content-Type': 'text/plain' });
  res.end('Not Found');
});

// Process-level unhandled rejection handling (Production SRE Best Practice)
process.on('unhandledRejection', (reason, promise) => {
  console.error('[FATAL] Unhandled Promise Rejection at:', promise, 'reason:', reason);
  // Fail fast in production to allow container orchestrator to restart instance
  process.exit(1);
});

process.on('uncaughtException', (err) => {
  console.error('[FATAL] Uncaught Exception thrown:', err);
  process.exit(1);
});

server.listen(PORT, () => {
  console.log(`[INFO] Server running on pid ${process.pid}, listening on port ${PORT}`);
});
```

### 3.2 Manifiesto del Contenedor Multi-Etapa de Producción (`Dockerfile`)

```dockerfile
# Stage 1: Build & Dependency Audit
FROM node:20-alpine AS builder
WORKDIR /usr/src/app
COPY package*.json ./
RUN npm ci --only=production

# Stage 2: Runtime Production Image
FROM node:20-alpine
LABEL maintainer="sre-team@platform.internal"
LABEL description="Production Node.js Runtime for JavaScript Execution Analysis"

# Enforce secure non-root user
USER node
WORKDIR /usr/src/app

COPY --chown=node:node --from=builder /usr/src/app/node_modules ./node_modules
COPY --chown=node:node app/server.js ./server.js

ENV NODE_ENV=production
ENV PORT=8080

# Tune V8 Heap Limit to match container cgroup limits (e.g., 512MB RAM total -> ~384MB V8 Heap)
ENV NODE_OPTIONS="--max-old-space-size=384 --use-strict"

EXPOSE 8080

CMD ["node", "server.js"]
```

### 3.3 Manifiesto de Despliegue y Recursos de Kubernetes (`deployment.yaml`)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: js-execution-runtime
  namespace: default
  labels:
    app.kubernetes.io/name: js-execution-runtime
    app.kubernetes.io/part-of: platform-essentials
spec:
  replicas: 2
  selector:
    matchLabels:
      app: js-execution-runtime
  template:
    metadata:
      labels:
        app: js-execution-runtime
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
      containers:
        - name: node-runtime
          image: js-execution-runtime:1.0.0
          imagePullPolicy: IfNotPresent
          env:
            - name: PORT
              value: "8080"
            - name: NODE_OPTIONS
              value: "--max-old-space-size=384 --use-strict"
          ports:
            - containerPort: 8080
              name: http
          resources:
            requests:
              cpu: "250m"
              memory: "256Mi"
            limits:
              cpu: "500m"
              memory: "512Mi"
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 2
            periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: js-execution-service
  namespace: default
spec:
  type: ClusterIP
  ports:
    - port: 80
      targetPort: 8080
      protocol: TCP
      name: http
  selector:
    app: js-execution-runtime
```

---

## 4. Comandos Reales de CLI y Salida de Terminal

### 4.1 Inspección de Opciones del Motor V8 y Flags de Ejecución por Defecto

```bash
$ node --v8-options | grep -E "(max_old_space_size|use_strict|trace_gc)"
```

**Salida esperada:**
```text
  --use_strict (enforcing strict mode)
        type: bool  default: false
  --trace_gc (trace garbage collection occurrences)
        type: bool  default: false
  --max_old_space_size (max size of the old space (in Mbytes))
        type: int  default: 0
```

### 4.2 Verificación de Variable Hoisting vs Temporal Dead Zone (TDZ) mediante CLI

Probando el hoisting de `var` vs la semántica TDZ de `let` de forma interactiva utilizando `node -e`:

```bash
$ node -e "
console.log('--- VAR Hoisting Test ---');
console.log('Value of hoistedVar:', hoistedVar);
var hoistedVar = 'I am hoisted';
console.log('Value after assignment:', hoistedVar);
"
```

**Salida esperada:**
```text
--- VAR Hoisting Test ---
Value of hoistedVar: undefined
Value after assignment: I am hoisted
```

Ahora ejecutando `let` con alcance de bloque para verificar el cumplimiento de TDZ:

```bash
$ node -e "
console.log('--- LET TDZ Test ---');
try {
  console.log(tdzVar);
  let tdzVar = 'I am in TDZ';
} catch (err) {
  console.error('Caught expected exception:', err.name + ':', err.message);
}
"
```

**Salida esperada:**
```text
--- LET TDZ Test ---
Caught expected exception: ReferenceError: Cannot access 'tdzVar' before initialization
```

### 4.3 Ejecución en Modo Estricto (`'use strict'`) vs Modo Sloppy

Evaluando trampas de errores silenciosos en modo no estricto vs excepciones en modo estricto:

```bash
$ node -e "
function sloppyMode() {
  globalLeak = 'Leaked to global object';
  console.log('Sloppy global leak successful:', global.globalLeak);
}
sloppyMode();
"
```

**Salida esperada:**
```text
Sloppy global leak successful: Leaked to global object
```

Ejecutando la aplicación de modo estricto:

```bash
$ node -e "
'use strict';
function strictMode() {
  try {
    globalLeak = 'Will fail';
  } catch (err) {
    console.error('Strict mode block caught:', err.name + ':', err.message);
  }
}
strictMode();
"
```

**Salida esperada:**
```text
Strict mode block caught: ReferenceError: globalLeak is not defined
```

### 4.4 Evaluación de Comportamientos del Motor en Coerción y Comparación de Tipos

```bash
$ node -e "
const tests = [
  { a: 0, b: '0' },
  { a: false, b: '0' },
  { a: null, b: undefined },
  { a: [], b: false }
];

console.table(tests.map(t => ({
  'Value A': JSON.stringify(t.a),
  'Value B': JSON.stringify(t.b),
  'Abstract (==)': t.a == t.b,
  'Strict (===)': t.a === t.b,
  'Type A': typeof t.a,
  'Type B': typeof t.b
})));
"
```

**Salida esperada:**
```text
┌──────────────────────┬─────────┬───────────┬───────────────┬──────────────┬─────────────┬─────────────┐
│ (index)   │ Value A │ Value B   │ Abstract (==) │ Strict (===) │ Type A      │ Type B      │
├──────────────────────┼─────────┼───────────┼───────────────┼──────────────┼─────────────┼─────────────┤
│ 0         │ '0'     │ '"0"'     │ true          │ false        │ 'number'    │ 'string'    │
│ 1         │ 'false' │ '"0"'     │ true          │ false        │ 'boolean'   │ 'string'    │
│ 2         │ 'null'  │ undefined │ true          │ false        │ 'object'    │ 'undefined' │
│ 3         │ '[]'    │ 'false'   │ true          │ false        │ 'object'    │ 'boolean'   │
└──────────────────────┴─────────┴───────────┴───────────────┴──────────────┴─────────────┴─────────────┤
```

### 4.5 Inspección del Endpoint de Diagnósticos HTTP de Producción

```bash
$ curl -s http://localhost:8080/diagnostics | jq .
```

**Salida esperada:**
```json
{
  "timestamp": "2026-08-07T03:22:23.102Z",
  "nodeVersion": "v20.15.0",
  "pid": 12480,
  "executionEngine": {
    "strictMode": {
      "strictModeActive": true,
      "errorName": "ReferenceError",
      "errorMessage": "undeclaredGlobalLeak is not defined"
    },
    "scopeScopeSafety": {
      "tdzProtectionVerified": true,
      "heapUsedBytes": 5429816
    },
    "v8Heap": {
      "totalHeapSizeMb": "11.25",
      "usedHeapSizeMb": "5.18",
      "heapSizeLimitMb": "384.00"
    }
  }
}
```

---

## 5. Guía de Verificación y Diagnóstico de Fallos

Al administrar entornos de ejecución de JavaScript a escala empresarial, los Platform Architects y SREs se encuentran con modos de fallo específicos derivados de la mecánica de ejecución de la sintaxis y del comportamiento del Event Loop.

```
                           Production JavaScript Diagnostics Workflow
                           
+---------------------------------------------------------------------------------------------------+
| Is the Node.js Process Crashing or Unresponsive?                                                  |
+---------------------------------------------------------------------------------------------------+
                                                  |
                     +----------------------------+----------------------------+
                     |                                                         |
                     v                                                         v
        [ Process Crashing / OOM ]                                 [ High CPU / Stalled I/O ]
                     |                                                         |
                     v                                                         v
+------------------------------------------+               +------------------------------------------+
| 1. Check exit code:                      |               | 1. Check Event Loop Delay:               |
|    - 137 (OOM Killer via kernel)         |               |    - `perf_hooks.monitorEventLoopDelay()`|
|    - 120 / Fatal Error (V8 Heap Limit)   |               | 2. Take CPU Profile:                     |
| 2. Inspect GC Logs:                      |               |    - `node --cpu-prof`                   |
|    - `--trace-gc` or `--trace-gc-verbose`|               | 3. Inspect Call Stack:                   |
| 3. Inspect Heap Dump:                    |               |    - Identify sync long-running loops,   |
|    - `node --heap-prof`                  |               |      regex backtracking, or heavy sync   |
| 4. Audit Scope & Memory:                 |               |      JSON parsing.                       |
|    - Look for global array accumulation, |               +------------------------------------------+
|      uncleared `setInterval`, or         |
|      stale closures retaining outer scope|
+------------------------------------------+
```

### 5.1 Out-Of-Memory (OOM) mediante Fugas por Alcance Global / Retención de Closures

#### Escenario de Diagnóstico
Un servicio de Node.js colapsa intermitentemente en Kubernetes con `OOMKilled` (Exit Code 137) o error fatal de V8: `JavaScript heap out of memory`.

#### Mecánica de la Causa Raíz
Las variables declaradas en el nivel de scope global (`var` o `let`/`const` fuera de los límites de las funciones) o capturadas dentro de closures de larga duración nunca son liberadas por los recolectores de basura Scavenger o Mark-Sweep de V8.

#### Procedimiento de Diagnóstico

1. **Habilitar el Rastreo de GC de V8**:
   Agregue `--trace-gc` a `NODE_OPTIONS` para monitorear el comportamiento del heap en la salida estándar (stdout) del contenedor:
   ```bash
   $ kubectl logs deployment/js-execution-runtime -n default --tail=100 | grep "Mark-sweep"
   ```
   *Ejemplo de salida:*
   ```text
   [1:0x55b1f2b4e000]   12450 ms: Mark-sweep 380.2 (384.0) -> 378.1 (384.0) MB, 142.3 ms (average mu = 0.082, current mu = 0.005) allocation failure; scavenge might not succeed
   ```
   *Interpretación*: El recolector Mark-sweep liberó menos de 2MB de memoria tras una pausa de 142ms. El V8 heap está saturado.

2. **Generar y Analizar Heap Snapshot**:
   Active un perfil de heap utilizando la señal de diagnóstico de Node.js `SIGUSR2` o el flag de CLI:
   ```bash
   $ node --heap-prof --heap-prof-dir=/tmp/dumps app/server.js
   ```
   Inspeccione los mayores retenedores usando Chrome DevTools o `clinic heapprofiler`. Busque asignaciones de arrays que retengan scopes léxicos externos.

3. **Remediación**:
   - Elimine buffers de estado `var` / `let` de nivel superior.
   - Fuerce la liberación explícita de referencias (`variable = null`) al utilizar maps de almacenamiento en caché.
   - Utilice `WeakMap` o `WeakSet` para la asociación de objetos clave-valor de modo que la recolección de basura no se vea bloqueada por las claves del map.

### 5.2 Bloqueo del Event Loop (Saturación de Ejecución Sincrónica)

#### Escenario de Diagnóstico
La latencia del servicio se eleva a segundos, los readiness probes fallan, pero el uso de CPU permanece estancado cerca del 100% en un solo núcleo.

#### Mecánica de la Causa Raíz
Debido a que JavaScript se ejecuta en un único hilo de Call Stack, los bucles sincrónicos (por ejemplo, bucles `for` que procesan millones de iteraciones, APIs sincrónicas del sistema de archivos `fs.readFileSync` o evaluaciones catastróficas de expresiones regulares por ReDoS) impiden que el Event Loop ceda el control a los callbacks de I/O o a los manejadores de solicitudes HTTP.

#### Procedimiento de Diagnóstico

1. **Monitorear el Retraso del Event Loop mediante `perf_hooks`**:
   Inserte el rastreo del retraso del Event Loop en el código de la aplicación:
   ```javascript
   const { monitorEventLoopDelay } = require('perf_hooks');
   const h = monitorEventLoopDelay({ resolution: 20 });
   h.enable();

   setInterval(() => {
     console.log(`[METRIC] Event Loop Delay P99: ${h.percentile(99) / 1e6} ms`);
     h.reset();
   }, 5000);
   ```

2. **Recolectar Perfil de CPU**:
   Ejecute el proceso de Node con el perfilador de CPU integrado:
   ```bash
   $ node --cpu-prof --cpu-prof-interval=1000 app/server.js
   ```
   Busque en el archivo `.cpuprofile` generado las funciones que consumen un alto `selfTime` en el Call Stack.

3. **Remediación**:
   - Delegue los cálculos pesados de CPU a hilos de trabajo (worker threads) utilizando el módulo `worker_threads`.
   - Reemplace los métodos sincrónicos (`fs.readFileSync`, `JSON.parse` en payloads gigantes) con variantes en streaming o asincrónicas (`fs.promises.readFile`).

---

## 6. Referencias

- **Visión General de LPI Web Development Essentials**:  
  [https://www.lpi.org/our-certifications/web-development-essentials-overview/](https://www.lpi.org/our-certifications/web-development-essentials-overview/)
- **Especificación del Lenguaje ECMA-262 (Conceptos Generales de ECMAScript)**:  
  [https://tc39.es/ecma262/](https://tc39.es/ecma262/)
- **Arquitectura del Motor de JavaScript V8 y Recolección de Basura**:  
  [https://v8.dev/](https://v8.dev/)
- **Documentación Oficial de Node.js y Opciones de Línea de Comandos**:  
  [https://nodejs.org/en/docs/](https://nodejs.org/en/docs/)
- **MDN Web Docs: Gramática, Scoping y Contextos de Ejecución de JavaScript**:  
  [https://developer.mozilla.org/en-US/docs/Web/JavaScript](https://developer.mozilla.org/en-US/docs/Web/JavaScript)