# LPI 030-100: Software Development Basics (Topic 1.1 / 031.1) - Guía de Estudio Avanzada de Producción

---

## 1. Motivación y Problema Arquitectónico de Producción

A nivel empresarial, la distinción entre escribir código y operar software a escala está definida por cómo los principios fundamentales del desarrollo de software interactúan con los kernels de Linux subyacentes, los execution runtimes y los orquestadores de contenedores. Los SRE y Platform Engineers deben evaluar los lenguajes de programación, los modelos de ejecución, los paradigmas de software y las herramientas no solo por la ergonomía del desarrollador, sino a través de la lente de la **latencia de cola predecible (p99/p99.9)**, la **densidad de utilización de recursos**, el **comportamiento de cold-start de contenedores** y el **aislamiento del dominio de fallas**.

```
+-----------------------------------------------------------------------------------+
|                                 APPLICATION LAYER                                 |
|   Procedural / OOP / Functional Paradigms | Dependencies & Dynamic Libraries     |
+-----------------------------------------------------------------------------------+
                                         |
                                         v
+-----------------------------------------------------------------------------------+
|                             EXECUTION RUNTIME LAYER                               |
|   Native AOT Binary   |   Bytecode VM + JIT (JVM/.NET)   |   Interpreted Engine     |
|   (Direct System)     |   (Garbage Collection/JIT)       |   (Node.js/Python V8/GIL)|
+-----------------------------------------------------------------------------------+
                                         |
                                         v
+-----------------------------------------------------------------------------------+
|                        LINUX KERNEL & CONTAINER SUBSYSTEM                         |
|   cgroups v2 (Memory/CPU limits) | POSIX Signals (SIGTERM) | Virtual Memory (mmap)|
+-----------------------------------------------------------------------------------+
```

### Puntos Clave de Fricción Arquitectónica en Producción:

1. **Compilación vs. Interpretación vs. JIT en el Ciclo de Vida Cloud-Native**:
   - **Lenguajes Compilados Ahead-of-Time (AOT) (C, C++, Go, Rust)**: compilan directamente a código máquina/binarios ELF. Presentan un memory footprint mínimo, cero overhead de bootstrap en el runtime y tiempos de inicio de contenedor de sub-milisegundos, lo que los hace ideales para microservicios de alto rendimiento y arquitecturas Serverless/FaaS.
   - **Lenguajes Bytecode VM / JIT (Java, C#)**: se ejecutan a través de bytecode intermedio compilado en tiempo de ejecución por un compilador Just-In-Time. Si bien ofrecen altas optimizaciones en runtime tras el warm-up, introducen un elevado overhead inicial de memoria, fases de inicio lentas (retrasos de PGO/compilación escalonada) y picos de CPU no deterministas durante las fases de compilación.
   - **Lenguajes Interpretados / Scripting Dinámico (Python, PHP, JavaScript/Node.js)**: ejecutan instrucciones línea por línea o a través de motores de event-loop de un solo hilo. Permiten ciclos de desarrollo rápidos pero sufren de un mayor overhead de ejecución de CPU por instrucción, bloat de memoria por tipado dinámico y cuellos de botella de ejecución en un solo núcleo impulsados por bloqueos del runtime como el Global Interpreter Lock (GIL) de Python.

2. **Gestión de Memoria y Garbage Collection (GC) en Entornos Contenedorizados**:
   - La gestión automatizada de memoria mediante Garbage Collection (JVM, V8, Go runtime) abstrae la asignación de heap. Sin embargo, bajo los límites de memoria de `cgroups v2` del kernel de Linux, si el GC del runtime no es cgroup-aware, el Out-Of-Memory (OOM) Killer del kernel de Linux enviará un `SIGKILL` (Exit Code 137) al proceso del contenedor antes de que el runtime active su ciclo de GC interno.
   - La gestión manual de memoria (C/C++) elimina el jitter de latencia del GC, pero requiere una disciplina absoluta para evitar memory leaks, errores de use-after-free y fragmentación de heap que conducen a estados de OOM en el kernel.

3. **Paradigmas de Software y Gestión de Estado**:
   - **Procedural**: Ejecución secuencial imperativa. Puede llevar a una dispersión procedimental monolítica y a mutaciones de estado global compartido que arruinan la escalabilidad de la concurrencia.
   - **Programación Orientada a Objetos (OOP)**: Encapsula el estado y el comportamiento dentro de clases. Jerarquías de clases excesivas y objetos compartidos mutables complican la seguridad multi-hilo y la ejecución de thread-pools.
   - **Programación Funcional (FP)**: Impone la inmutabilidad y funciones puras libres de efectos secundarios. En microservicios distribuidos, los flujos de datos inmutables eliminan las condiciones de carrera sin requerir bloqueos por mutex de grano grueso, lo que permite un escalado horizontal lineal en sistemas de múltiples núcleos.

---

## 2. Tablas de Comparaciones Técnicas y Trade-offs

### Tabla 1: Comparación de Paradigmas de Software

| Métrica / Dimensión | Programación Procedural | Programación Orientada a Objetos (OOP) | Programación Funcional (FP) |
| :--- | :--- | :--- | :--- |
| **Mutación de Estado** | Mutación directa y explícita de variables locales/globales. | Estado mutable encapsulado dentro de instancias de clase. | Inmutabilidad estricta; estructuras de datos persistentes. |
| **Seguridad de Concurrencia** | Baja; alto riesgo de data races en el estado global. | Moderada; requiere sincronización manual (mutexes/bloqueos). | Inherentemente segura; el estado inmutable evita la contención de bloqueos. |
| **Memory Footprint** | Mínimo; bajo overhead de stack/heap. | Mayor; metadatos de objetos, vtables, overhead de punteros. | Moderado-Alto; asignación de objetos para ciclos de inmutabilidad. |
| **Testabilidad y Mocking**| Difícil para estado global; fácil para procedimientos lineales. | Moderada; se apoya en interfaces, inyección de dependencias, mocks. | Superior; las funciones puras permiten unit testing determinista. |
| **Ajuste en Cloud-Native** | Utilidades legacy, herramientas procedimentales en shell/C. | Microservicios empresariales (Java Spring, C# .NET). | Event streaming de alta concurrencia, procesamiento en pipeline. |

### Tabla 2: Runtimes de Ejecución y Modelos de Compilación

| Dimensión | AOT Nativo (C, Go, Rust) | Bytecode VM + JIT (Java, C#) | Interpretado / Scripting (Python, PHP, Node.js) |
| :--- | :--- | :--- | :--- |
| **Binario de Ejecución** | Código Máquina Nativo (binario ELF). | Bytecode Intermedio (.class, .dll). | Código Fuente en Texto Plano / AST. |
| **Startup / Cold-Start** | Instantáneo (<10ms). | Lento (1s – 10s+) debido a la init de JVM/CLR y warm-up de JIT. | Rápido a Moderado (100ms – 1s). |
| **Overhead de CPU en Runtime**| Mínimo (Ejecución directa en CPU). | Bajo a Medio (Posterior al warm-up de JIT). | Máximo (Overhead del bucle del intérprete). |
| **Tamaño Base del Contenedor** | Mínimo (<15MB, `scratch` o `distroless`). | Grande (150MB - 500MB con JRE). | Medio (50MB - 200MB con el runtime del intérprete). |
| **Conciencia de cgroup v2** | Interacciones nativas del SO. | Requiere JRE moderno (Java 11+) para analizar las rutas de cgroup. | Node/Python se apoyan en llamadas al sistema de libuv/SO. |

### Tabla 3: Modelos de Gestión de Memoria en Producción

| Modelo | Lenguajes | Impacto en Latencia de Cola (p99) | Factor de Riesgo de OOM en K8s | Complejidad Operacional de SRE |
| :--- | :--- | :--- | :--- | :--- |
| **Manual (malloc/free)** | C, C++ | Cero pausas de GC; predecible. | Alto (Los memory leaks degradan el límite de cgroup). | Alta (Requiere profiling con Valgrind, ASan). |
| **Propiedad en Tiempo de Compilación**| Rust | Cero pausas de GC; liberación determinista.| Bajo (Forzado en tiempo de compilación). | Moderada (Curva de aprendizaje elevada). |
| **GC Concurrente** | Go | Bajas pausas de GC (<1ms stop-the-world).| Moderado (Requiere tuning de GOGC). | Baja-Moderada (Flags simples de runtime). |
| **GC Generacional** | Java (G1GC/ZGC)| Picos periódicos de latencia (Stop-The-World).| Alto si la `-Xmx` de la JVM excede el límite de memoria del contenedor.| Alta (Requiere tuning de `-Xms`, `-Xmx`, algoritmos de GC). |
| **Conteo de Referencias + GC**| Python, PHP | Jitter de latencia durante la recolección cíclica. | Moderado (Memoria no liberada bajo carga). | Moderada (Requiere profilers de memory leaks). |

---

## 3. Manifiestos Completos de Infraestructura de Producción

### Manifiesto 1: `Dockerfile` de Producción Multi-Stage
Un Dockerfile multi-stage endurecido para entorno de producción, que compila un servicio Go en un binario AOT ubicado dentro de una imagen de contenedor `scratch` mínima.

```dockerfile
# ==========================================
# STAGE 1: Build & Compilation Environment
# ==========================================
FROM golang:1.22-alpine AS builder

# Install security updates and build tools
RUN apk update && apk add --no-cache git ca-certificates tzdata && update-ca-certificates

# Create non-privileged build user
RUN adduser -D -g "" -u 10001 appuser

WORKDIR /src

# Leverage layer caching for dependencies
COPY go.mod go.sum ./
RUN go mod download && go mod verify

# Copy source code
COPY . .

# Compile static AOT executable (CGO disabled for pure static ELF)
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -ldflags="-w -s -extldflags '-static'" \
    -o /bin/server ./cmd/api

# ==========================================
# STAGE 2: Minimal Production Runtime
# ==========================================
FROM scratch

# Copy system metadata from builder
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /usr/share/zoneinfo /usr/share/zoneinfo
COPY --from=builder /etc/passwd /etc/passwd
COPY --from=builder /etc/group /etc/group

# Copy compiled AOT binary
COPY --from=builder --chown=10001:10001 /bin/server /server

# Enforce non-root execution
USER 10001:10001

# Expose service port
EXPOSE 8080

# Configure execution entrypoint
ENTRYPOINT ["/server"]
```

### Manifiesto 2: Deployment de Kubernetes en Producción (`deployment.yaml`)
Deployment de Kubernetes sintácticamente completo que impone cuotas de recursos, contextos de seguridad, configuraciones de probes y la configuración de apagado gradual (graceful shutdown) mediante POSIX `SIGTERM`.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-processor-api
  namespace: production
  labels:
    app.kubernetes.io/name: payment-processor-api
    app.kubernetes.io/part-of: finance-platform
    app.kubernetes.io/component: backend
spec:
  replicas: 3
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app.kubernetes.io/name: payment-processor-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: payment-processor-api
    spec:
      terminationGracePeriodSeconds: 30
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: api-runtime
          image: registry.enterprise.internal/finance/payment-api:v1.4.2
          imagePullPolicy: IfNotPresent
          command: ["/server"]
          env:
            - name: PORT
              value: "8080"
            - name: ENVIRONMENT
              value: "production"
            - name: GOMAXPROCS
              valueFrom:
                resourceFieldRef:
                  resource: limits.cpu
          ports:
            - containerPort: 8080
              name: http-api
              protocol: TCP
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          resources:
            requests:
              cpu: 250m
              memory: 128Mi
            limits:
              cpu: 1000m
              memory: 512Mi
          startupProbe:
            httpGet:
              path: /healthz/startup
              port: 8080
            initialDelaySeconds: 2
            periodSeconds: 3
            failureThreshold: 10
          livenessProbe:
            httpGet:
              path: /healthz/liveness
              port: 8080
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /healthz/readiness
              port: 8080
            periodSeconds: 5
            timeoutSeconds: 2
            successThreshold: 1
            failureThreshold: 2
```

### Manifiesto 3: Pipeline de CI/CD Empresarial Completo (`ci-cd-pipeline.yaml`)
Workflow declarativo de GitHub Actions que integra linting de código, unit testing, análisis estático de seguridad de aplicaciones (SAST), compilación de binarios, creación de imágenes de contenedor y envío a registro (registry pushing).

```yaml
name: Production CI/CD Pipeline

on:
  push:
    branches:
      - main
  pull_request:
    branches:
      - main

permissions:
  contents: read
  security-events: write
  packages: write

jobs:
  code-quality-and-test:
    name: Code Quality, Lint & Test
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Source Code
        uses: actions/checkout@v4

      - name: Setup Go Development Environment
        uses: actions/setup-go@v5
        with:
          go-version: '1.22'
          cache: true

      - name: Run Static Code Analysis (golangci-lint)
        uses: golangci/golangci-lint-action@v4
        with:
          version: v1.56.2

      - name: Execute Unit Tests with Coverage & Race Detection
        run: |
          go test -race -v -coverprofile=coverage.out ./...

      - name: Run SAST Security Scan (Trivy Code)
        uses: aquasecurity/trivy-action@0.18.0
        with:
          scan-type: 'fs'
          ignore-unfixed: true
          format: 'sarif'
          output: 'trivy-results.sarif'
          severity: 'CRITICAL,HIGH'

  build-and-publish:
    name: Build AOT & Publish Container Image
    needs: code-quality-and-test
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    steps:
      - name: Checkout Source Code
        uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Authenticate to Container Registry
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
            type=sha,prefix=,format=long
            type=ref,event=branch
            latest

      - name: Build and Push OCI Container Image
        uses: docker/build-push-action@v5
        with:
          context: .
          file: ./Dockerfile
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

---

## 4. Comandos de CLI Reales y Salidas de Terminal ($)

### 1. Inspección de Encabezados Binarios y Verificación de Enlazado de Librerías
Análisis de objetivos de ejecución para diferenciar binarios ELF compilados nativamente en AOT, dependencias dinámicas y motores de ejecución interpretados.

```bash
$ file /bin/ls /bin/server /usr/bin/python3
/bin/ls:          ELF 64-bit LSB pie executable, x86-64, version 1 (SYSV), dynamically linked, interpreter /lib64/ld-linux-x86-64.so.2, for GNU/Linux 3.2.0, BuildID[sha1]=1b2c3d4e5f, stripped
/bin/server:      ELF 64-bit LSB executable, x86-64, version 1 (SYSV), statically linked, Go BuildID=a1b2c3d4e5f6, stripped
/usr/bin/python3: ELF 64-bit LSB pie executable, x86-64, version 1 (SYSV), dynamically linked, interpreter /lib64/ld-linux-x86-64.so.2, for GNU/Linux 3.2.0, BuildID[sha1]=9f8e7d6c5b, stripped

$ ldd /bin/server
	statically linked

$ ldd /usr/bin/python3
	linux-vdso.so.1 (0x00007ffc12345000)
	libm.so.6 => /lib/x86_64-linux-gnu/libm.so.6 (0x00007f89ab000000)
	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f89aa800000)
	/lib64/ld-linux-x86-64.so.2 (0x00007f89ab400000)
```

### 2. Profiling de Hilos y Memoria en Runtime mediante `pidstat`
Inspección de asignaciones de páginas de memoria (`VSZ`, `RSS`), fallos de página (page faults) y comportamiento multi-hilo en los IDs de procesos objetivo.

```bash
$ pidstat -p $(pgrep -f "server") -r -u -t 1 3
Linux 6.6.13-amd64 (node-prod-01) 	08/06/2026 	_x86_64_	(8 CPU)

06:47:01 PM   UID      TGID       TID    %usr %system  %guest   %wait    %CPU   CPU  Command
06:47:02 PM 10001     41022         -    4.00    1.00    0.00    0.00    5.00     2  server
06:47:02 PM 10001         -     41022    1.00    0.00    0.00    0.00    1.00     2  |--server
06:47:02 PM 10001         -     41023    2.00    0.00    0.00    0.00    2.00     5  |--server
06:47:02 PM 10001         -     41024    1.00    1.00    0.00    0.00    2.00     7  |--server

06:47:01 PM   UID       PID  minflt/s  majflt/s     VSZ     RSS   %MEM  Command
06:47:02 PM 10001     41022    120.00      0.00   32456   18432   0.11  server
06:47:03 PM 10001     41022     45.00      0.00   32456   18496   0.11  server
06:47:04 PM 10001     41022      0.00      0.00   32456   18496   0.11  server
Average:    10001     41022     55.00      0.00   32456   18474   0.11  server
```

### 3. Diagnósticos de Control de Versiones con Git y Rastreo de Commits
Localización automatizada de fallos con git utilizando `git bisect` para ubicar regresiones en el historial del código fuente.

```bash
$ git bisect start
$ git bisect bad HEAD
$ git bisect good v1.4.0
Bisecting: 12 revisions left to test after this (roughly 4 steps)
[a1b2c3d4e5f67890123456789abcdef012345678] feat(api): update JSON serialization library

$ git bisect run go test -run TestPaymentProcessing ./...
running  go test -run TestPaymentProcessing ./...
--- FAIL: TestPaymentProcessing (0.04s)
    payment_test.go:42: Unexpected nil pointer reference during payload parse
FAIL
exit status 1
Bisecting: 5 revisions left to test after this (roughly 3 steps)
[89abcdef0123456789abcdef0123456789a1b2c3] fix(db): optimize connection pooling parameters
running  go test -run TestPaymentProcessing ./...
PASS
ok  	github.com/enterprise/finance/pkg/payment	0.038s
[a1b2c3d4e5f67890123456789abcdef012345678] is the first bad commit
commit a1b2c3d4e5f67890123456789abcdef012345678
Author: Developer <dev@enterprise.internal>
Date:   Wed Aug 5 14:22:10 2026 -0400

    feat(api): update JSON serialization library

:100644 100644 c1d2e3... f4a5b6... M	pkg/payment/serializer.go
```

---

## 5. Guía de Solución de Problemas y Diagnóstico de Fallas

```
                            +------------------------------------+
                            | KUBERNETES POD TERMINATED (FAIL)   |
                            +------------------------------------+
                                              |
                                              v
                            +------------------------------------+
                            | Inspect Exit Code & Status         |
                            | kubectl describe pod <pod-name>    |
                            +------------------------------------+
                                    /                    \
                                   /                      \
                         Exit Code 137                  Exit Code 143 / 1
                                 /                          \
                                v                            v
            +-----------------------+              +-----------------------+
            | OOMKilled by Kernel   |              | Graceful Termination  |
            | (cgroup Limit)        |              | Timeout / SIGKILL     |
            +-----------------------+              +-----------------------+
                        |                                      |
                        v                                      v
            +-----------------------+              +-----------------------+
            | Check Heap vs Limit   |              | Check SIGTERM Listener|
            | Tune Heap/GC Settings |              | Inspect Connection    |
            | (-Xmx, GOMAXPROCS)    |              | Draining Metrics      |
            +-----------------------+              +-----------------------+
```

### Problema A: Kubernetes OOMKilled (Exit Code 137) en Runtimes Administrados

#### Mecánica de la Causa Raíz:
Los lenguajes que se ejecutan sobre Máquinas Virtuales (JVM, Node.js V8) asignan memoria para code cache, thread stacks, memoria nativa fuera del heap (`mmap`) y el heap. Si el runtime de la VM no es consciente de los límites de cgroup, o si `-Xmx` (Max Heap) se configura igual o mayor que el límite de memoria de Kubernetes del contenedor, la huella total del proceso (Heap + Non-Heap) superará el límite de cgroup del SO. El `oom-killer` del kernel de Linux envía inmediatamente la señal `9` (`SIGKILL`), resultando en el Exit Code `137` (`128 + 9`).

#### Flujo de Trabajo de Diagnóstico y Remediación Paso a Paso:

1. **Verificar el Estado del Pod y la Razón de Terminación**:
   ```bash
   $ kubectl get pod payment-processor-api-7b89c-x4z9d -n production -o jsonpath='{.status.containerStatuses[0].lastState.terminated}'
   {"containerID":"containerd://a1b2c3d4...","exitCode":137,"finishedAt":"2026-08-06T18:30:12Z","reason":"OOMKilled","startedAt":"2026-08-06T18:00:00Z"}
   ```

2. **Inspeccionar Eventos de OOM de cgroup del Kernel mediante Diagnósticos del Nodo**:
   ```bash
   $ dmesg -T | grep -E -i "oom|killed process"
   [Thu Aug 6 18:30:12 2026] Memory cgroup out of memory: Kill process 41022 (java) score 995 or sacrifice child
   [Thu Aug 6 18:30:12 2026] Killed process 41022 (java) total-vm:4231200kB, anon-rss:523800kB, file-rss:12400kB, shmem-rss:0kB oom_reap_status 0
   ```

3. **Estrategia de Remediación**:
   - Para Java JVM: Forzar la ergonomía de cgroups a través de `-XX:+UseContainerSupport` y configurar proporciones dinámicas de heap en lugar de valores fijos: `-XX:MaxRAMPercentage=75.0`.
   - Para Node.js: Restringir explícitamente el límite de heap del garbage collector de V8 dentro del entorno de la especificación del pod:
     ```yaml
     env:
       - name: NODE_OPTIONS
         value: "--max-old-space-size=384" # Fits within 512Mi limit, leaving room for off-heap buffers
     ```

---

### Problema B: Event Loop Starvation y CPU Throttling en Runtimes de Un Solo Hilo

#### Mecánica de la Causa Raíz:
Los motores de event-loop de un solo hilo (JavaScript/Node.js, Python asyncio) manejan I/O no bloqueante a través de pools de hilos de trabajo (`libuv`) mientras ejecutan la lógica de la aplicación en un único hilo principal. Si un desarrollador introduce algoritmos síncronos e intensivos en CPU (p. ej., hashing criptográfico síncrono, parseo recursivo de JSON, bucles matemáticos intensivos), el hilo principal se bloquea. El event loop no puede procesar los callbacks de lectura/escritura de sockets ni los readiness probes de Kubernetes, lo que provoca timeouts en cascada HTTP 504 y fallos de probes.

#### Flujo de Trabajo de Diagnóstico y Remediación Paso a Paso:

1. **Identificar CPU Throttling a través de Métricas de cgroup**:
   ```bash
   $ kubectl exec -it payment-processor-api-7b89c-x4z9d -n production -- cat /sys/fs/cgroup/cpu.stat
   nr_periods 45120
   nr_throttled 12430
   throttled_usec 894320112
   ```
   *Interpretación*: Un valor elevado de `nr_throttled` en relación con `nr_periods` confirma que el runtime está restringido por los límites de cuota de CPU del kernel (`cpu.cfs_quota_us`).

2. **Hacer Profiling de la Latencia del Event Loop en el Hilo Principal**:
   Ejecutar un muestreo del event-loop de Node.js mediante `clinic.js` o inspeccionar los handles activos usando `process._getActiveHandles()` para encontrar bloques síncronos no liberados.

3. **Estrategia de Remediación**:
   - Descargar los cálculos pesados en CPU del hilo principal procedimental a Worker Threads en segundo plano (módulo `worker_threads` en Node.js, ProcessPoolExecutor de `concurrent.futures` en Python).
   - Incrementar los límites de CPU en Kubernetes o eliminar los límites estrictos de CPU si se utilizan clases QoS burstable para evitar pausas por cgroup CFS throttle.

---

### Problema C: Conexiones de Base de Datos Rota debido al Manejo No Gradual de la Señal `SIGTERM`

#### Mecánica de la Causa Raíz:
Cuando Kubernetes termina un Pod (durante deployments o autoscaling), envía una señal POSIX `SIGTERM` al Process ID 1 (`PID 1`) dentro del contenedor. Si el binario de la aplicación está envuelto dentro de un script de shell (`ENTRYPOINT /sh/start.sh`) sin `exec`, la shell intercepta y descarta `SIGTERM`. Como resultado, el proceso de la aplicación nunca recibe la notificación, continúa aceptando peticiones, no logra vaciar (drain) los sockets TCP abiertos y es asesinado abruptamente 30 segundos después por `SIGKILL` (Exit Code 143 / 137). Esto causa que las peticiones activas de los clientes me fallen con `ECONNRESET`.

#### Flujo de Trabajo de Diagnóstico y Remediación Paso a Paso:

1. **Verificar la Jerarquía de Procesos Dentro del Contenedor**:
   ```bash
   $ kubectl exec -it payment-processor-api-7b89c-x4z9d -n production -- ps -ef
   UID        PID  PPID  C STIME TTY          TIME CMD
   10001        1     0  0 18:00 ?        00:00:00 /bin/sh /start.sh
   10001        7     1  2 18:00 ?        00:00:15 node /app/index.js
   ```
   *Interpretación*: El PID 1 es `/bin/sh`, NO `node`. `/bin/sh` no reenviará señales POSIX al PID 7.

2. **Estrategia de Remediación**:
   - Actualizar el `ENTRYPOINT` del Dockerfile utilizando la sintaxis de array JSON para reemplazar a PID 1 directamente con el binario de la aplicación mediante la ejecución del shell:
     ```dockerfile
     # WRONG: ENTRYPOINT /start.sh
     # CORRECT (Direct execution as PID 1):
     ENTRYPOINT ["/server"]
     ```
   - Implementar un registro explícito de listener de señales del SO dentro del código de la aplicación (manejador Procedural/OOP):
     ```go
     // Graceful Shutdown Signal Handler in Go
     sigChan := make(chan os.Signal, 1)
     signal.Notify(sigChan, syscall.SIGTERM, syscall.SIGINT)

     <-sigChan // Block until signal received
     log.Println("SIGTERM received. Initiating graceful drain...")

     ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
     defer cancel()
     if err := httpServer.Shutdown(ctx); err != nil {
         log.Fatalf("Server forced to shutdown: %v", err)
     }
     ```

---

## 6. Referencias

- **Visión General de LPI (Linux Professional Institute) Web Development Essentials**:  
  https://www.lpi.org/our-certifications/web-development-essentials-overview/
- **LPI Wiki - Objetivos de Web Development Essentials V1.0 (Tema 031.1)**:  
  https://wiki.lpi.org/wiki/Web_Development_Essentials_Objectives_V1.0
- **Documentación de Kubernetes - Ciclo de Vida del Pod y Hooks de Contenedores**:  
  https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/
- **Documentación de Kubernetes - Gestión de Recursos para Pods y Contenedores**:  
  https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
- **Documentación de Docker - Mejores Prácticas de Builds Multi-stage**:  
  https://docs.docker.com/build/building/multi-stage/
- **Documentación del Kernel de Linux - Control Group v2 (cgroups v2)**:  
  https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html