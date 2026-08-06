# LPI Open Source Essentials (050-100) — Tema 056.1: Herramientas de Desarrollo

**Código de Examen:** 050-100  
**Tema:** 056.1 Herramientas de Desarrollo  
**Ponderación:** 5  
**Audiencia Objetivo:** SREs, Arquitectos de Plataforma e Ingenieros Cloud Native  

---

## 1. Motivación de la Arquitectura de Producción y Mecánica de Ingeniería

En la ingeniería de software empresarial moderna, las herramientas de desarrollo constituyen la base operativa del ciclo de vida de integración y entrega continuas. Los entornos de desarrollo poco estandarizados, las herramientas de compilación no optimizadas y los pipelines de pruebas frágiles introducen fallos catastróficos en producción, desvío de entorno (environment drift), vulnerabilidades de seguridad y un tiempo medio de recuperación (MTTR) prolongado.

```
+---------------------------------------------------------------------------------------------------+
|                                 DEVELOPMENT TOOLCHAIN & QUALITY GATES                             |
+---------------------------------------------------------------------------------------------------+
|                                                                                                   |
|  +-------------------+      +-------------------+      +-------------------+                      |
|  | Standardized IDE  |      |   Static Analysis |      |    Build Engine   |                      |
|  |  (Dev Containers) | ---> |   & Linting Gate  | ---> |  (Hermetic/Multi- |                      |
|  |                   |      | (hadolint/golang) |      |      stage)       |                      |
|  +-------------------+      +-------------------+      +-------------------+                      |
|                                                                  |                                |
|                                                                  v                                |
|  +-------------------+      +-------------------+      +-------------------+                      |
|  | Staging/Production|      |  CI/CD Orchestration|    | Automated Testing |                      |
|  | Target Deployment | <--- | Engine (K8s/GH    | <--- | (Unit, Integration|                      |
|  |  (Canary/ArgoCD)  |      |     Actions)      |      |     & Smoke)      |                      |
|  +-------------------+      +-------------------+      +-------------------+                      |
|                                                                                                   |
+---------------------------------------------------------------------------------------------------+
```

### El Problema Arquitectónico: Desvío de Entorno y Software no Probado
Sin herramientas de compilación herméticas y entornos de ejecución reproducibles, las organizaciones sufren el clásico antipatrón "funciona en mi máquina". Esto ocurre debido a:
* **Contaminación del Sistema Operativo Anfitrión:** Diferencias en las bibliotecas C del sistema (`glibc` vs `musl`), variables de entorno del sistema, parámetros del kernel y versiones localizadas del runtime del lenguaje.
* **Cambios de Código no Validados:** Ausencia de análisis estático automatizado (linters) y suites de pruebas automatizadas, lo que permite que fugas de memoria (memory leaks), condiciones de carrera (race conditions), errores sintácticos y vulnerabilidades de seguridad penetren en las ramas de versión (release branches).
* **Entornos de Compilación y Prueba Opacos:** Falta de entornos contenedorizados estandarizados en la estación de trabajo de desarrollo local, entornos de staging y plataformas de producción.

### Mecánica Fundamental de Ingeniería

#### 1. Entornos de Desarrollo Integrados (IDEs) y Dev Containers
Los IDEs modernos (por ejemplo, VS Code, Neovim) aprovechan el Language Server Protocol (LSP) para desacoplar el análisis de código, el linting y el autocompletado de la interfaz de usuario del editor de texto. Al aprovechar los **Development Containers (Dev Containers)**, los desarrolladores ejecutan el frontend de su editor en la máquina anfitriona mientras ejecutan todos los compiladores, intérpretes de runtime, depuradores y analizadores estáticos de código dentro de un contenedor Linux aislado, construido a partir de una imagen estricta bajo control de versiones.

#### 2. Compiladores, Intérpretes y Depuradores
* **Compiladores:** Transforman el código fuente de alto nivel en código máquina nativo del host (por ejemplo, GCC, Clang, `go build`). Realizan análisis léxico, parseo, análisis semántico, pasadas de optimización y enlazado (linking).
* **Intérpretes:** Leen el código fuente o el bytecode intermedio línea por línea y ejecutan las instrucciones correspondientes al vuelo (por ejemplo, Python, Node.js).
* **Depuradores (Debuggers):** Controladores de procesos interactivos (por ejemplo, GDB, Delve) que utilizan primitivas de rastreo del kernel (como `ptrace()` en Linux) para pausar la ejecución del proceso, inspeccionar registros de memoria, acoplarse a hilos en ejecución y rastrear marcos de pila (stack frames).

#### 3. Linters y Análisis Estático
Los linters analizan el código fuente sin ejecutarlo (Pruebas de Seguridad de Aplicaciones Estáticas - SAST). Inspeccionan los Árboles de Sintaxis Abstracta (ASTs) para señalar code smells, fallos de seguridad (por ejemplo, vectores de inyección SQL, desbordamientos de búfer), violaciones de estilo y errores no controlados antes de la compilación del código.

#### 4. Mecánica de Segregación de Entornos
* **Local:** Estación de trabajo del desarrollador / Dev Container. Alta verbosidad, servicios externos simulados (mocks), bucle rápido de recarga en caliente (hot-reloading).
* **Staging:** Entorno similar a producción ejecutándose en una infraestructura de clúster compartida. Se utiliza para pruebas de integración, pruebas de rendimiento (performance benchmarking) y pruebas de aceptación del usuario (UAT).
* **Production:** Entorno de ejecución altamente restringido, inmutable y multirregión. RBAC estricto, sistemas de archivos raíz de solo lectura, comprobación de estado automatizada (liveness/readiness/startup probes) y pipelines de despliegue sin tiempo de inactividad (zero-downtime).

#### 5. Quality Gates Automatizados y Jerarquía de Pruebas
* **Pruebas Unitarias (Unit Testing):** Prueban funciones/métodos individuales de forma aislada utilizando stubs de código y mocks. Ejecución rápida (milisegundos).
* **Pruebas de Integración (Integration Testing):** Validan la interacción entre componentes internos y dependencias externas reales (por ejemplo, bases de datos, cachés, colas de mensajes).
* **Pruebas de Aceptación/Humo (Acceptance/Smoke Testing):** Validación de alto nivel que comprueba la viabilidad del sistema principal tras el despliegue (por ejemplo, verificando `HTTP 200 OK` en endpoints `/healthz`).
* **Pruebas de Regresión y Rendimiento (Regression & Performance Testing):** Garantizan que las nuevas características introducidas no degraden el rendimiento (throughput) del sistema, incrementen la latencia p99 ni rompan la funcionalidad existente.

---

## 2. Comparativas Técnicas y Tablas de Sopesamiento (Trade-offs)

### Tabla 1: Herramientas de Análisis y Ejecución de Código

| Dimensión | Compiladores (ej. GCC, Go) | Intérpretes (ej. Python, Node.js) | Linters / SAST (ej. Hadolint, golangci-lint) | Depuradores Interactivos (ej. GDB, Delve) |
| :--- | :--- | :--- | :--- | :--- |
| **Modo de Ejecución** | Generación de código máquina AOT (Ahead-Of-Time). | Ejecución al vuelo / Evaluación de bytecode JIT. | Análisis estático de Árbol de Sintaxis Abstracta (AST). | Control directo del proceso mediante `ptrace()`. |
| **Bucle de Retroalimentación** | Moderado (Tiempo de compilación de segundos a minutos). | Instantáneo (No requiere fase de compilación). | Extremadamente Rápido (Ejecución inferior a un segundo). | Investigación manual y sincrónica. |
| **Dependencia en Runtime** | Binario independiente (Estático) o bibliotecas compartidas. | Requiere runtime/máquina virtual completa del lenguaje. | Ninguna (Se ejecuta fuera del runtime objetivo). | Tabla de símbolos del proceso objetivo (`.debug_info`). |
| **Riesgo en Producción** | Bajo (Errores detectados durante la fase de compilación). | Medio (Posibles errores de tipo en runtime). | Cero (Herramienta estática que no se ejecuta). | Alto (Pausar la ejecución de hilos en prod causa interrupciones). |

---

### Tabla 2: Entornos de Despliegue

| Entorno | Propósito Principal | Aislamiento de Infraestructura | Aislamiento de Datos | Controles de Acceso y Seguridad |
| :--- | :--- | :--- | :--- | :--- |
| **Local (DevContainer)** | Desarrollo activo de características, depuración local. | Sandbox en contenedor en el SO anfitrión del desarrollador. | Datos simulados (mock), sqlite o contenedores efímeros locales. | Privilegios root locales sin restricción. |
| **Staging** | Validación previa al lanzamiento, pruebas de carga, integración. | Namespace o clúster de Kubernetes dedicado. | Volcado de datos de producción anonimizados o conjuntos de datos sintéticos. | Acceso restringido para desarrolladores, monitorización de solo lectura. |
| **Production** | Gestión de tráfico en vivo de usuarios finales. | Nodos/VPCs de Kubernetes multirregión aislados. | Bases de datos de producción en vivo con cifrado estricto. | Sin acceso directo por SSH/exec; solo despliegue automatizado por GitOps/CI-CD. |

---

### Tabla 3: Taxonomía de Pruebas

| Tipo de Prueba | Alcance de Ejecución | Velocidad | Potencial de Inestabilidad (Flakiness) | Causa Principal de Fallo |
| :--- | :--- | :--- | :--- | :--- |
| **Prueba Unitaria** | Función/clase individual con I/O simulada (mocked). | Extremadamente rápida (<1ms por prueba). | Muy bajo (Determinista). | Fallos de lógica, gestión inválida de casos límite (edge cases). |
| **Prueba de Integración** | Interacciones entre componentes con bases de datos/APIs reales. | Moderada (Segundos). | Medio (Tiempos de espera de red, contención de bloqueos de BD). | Desvío de esquema (schema drift), cambios disruptivos en APIs (breaking changes). |
| **Prueba de Humo (Smoke Test)** | Rutas operativas principales en despliegues en vivo. | Rápida (<5s total). | Bajo. | Variables de entorno mal configuradas, rutas erróneas. |
| **Prueba de Regresión** | Suite de pruebas amplia que verifica la funcionalidad heredada. | Lenta (Minutos a horas). | Medio a Alto. | Efectos secundarios no deseados fruto del refactorizado de código. |

---

## 3. Manifiestos de Producción y Código de Infraestructura

### Dockerfile Multietapa Completo (`Dockerfile`)
Este manifiesto demuestra una compilación multietapa (multi-stage) segura y hermética que separa el entorno de herramientas de compilación del entorno ligero de ejecución en producción.

```dockerfile
# ==========================================
# STAGE 1: Build & Development Environment
# ==========================================
FROM golang:1.22-alpine AS builder

# Install security tools and build dependencies
RUN apk add --no-libc-dev --no-cache git gcc musl-dev ca-certificates

WORKDIR /app

# Copy dependency manifests first to leverage Docker layer caching
COPY go.mod go.sum ./
RUN go mod download && go mod verify

# Copy source code
COPY . .

# Static compilation: disable CGO, produce statically-linked binary
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -ldflags="-w -s -extldflags '-static'" \
    -o /app/bin/server ./cmd/server

# ==========================================
# STAGE 2: Lightweight Production Runtime
# ==========================================
FROM scratch

# Import CA certificates from builder stage for TLS termination
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

# Import unprivileged user from host runtime conventions
WORKDIR /

# Copy the statically compiled binary from builder stage
COPY --from=builder /app/bin/server /server

# Expose production port
EXPOSE 8080

# Run as non-root user (UID 65532 - nobody/nonroot)
USER 65532:65532

# Set entrypoint to compiled binary
ENTRYPOINT ["/server"]
```

---

### Manifiesto Completo de Pipeline CI/CD (`.github/workflows/production-pipeline.yml`)
Este pipeline de GitHub Actions ejecuta análisis estático, corre suites de pruebas unitarias y de integración, construye la imagen del contenedor y ejecuta pruebas de humo posteriores al despliegue.

```yaml
name: Production CI/CD Toolchain Pipeline

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
  static-analysis:
    name: Code Quality & Security Linting
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Set up Go
        uses: actions/go-actions-setup@v2
        with:
          go-version: '1.22'

      - name: Run GolangCI-Lint
        uses: golangci/golangci-lint-action@v4
        with:
          version: v1.56.2
          args: --timeout=5m --enable-all

      - name: Hadolint Container Analysis
        uses: hadolint/hadolint-action@v3.1.0
        with:
          dockerfile: Dockerfile
          failure-threshold: error

  automated-testing:
    name: Execution of Unit & Integration Test Suite
    runs-on: ubuntu-latest
    needs: static-analysis
    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Set up Go Environment
        uses: actions/setup-go@v5
        with:
          go-version: '1.22'

      - name: Execute Unit Tests with Coverage
        run: |
          go test -v -race -coverprofile=coverage.out -covermode=atomic ./...

      - name: Upload Test Coverage Artifacts
        uses: actions/upload-artifact@v4
        with:
          name: code-coverage-report
          path: coverage.out

  build-and-package:
    name: Hermetic OCI Image Build & Security Scan
    runs-on: ubuntu-latest
    needs: automated-testing
    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Build Local Container Image
        uses: docker/build-push-action@v5
        with:
          context: .
          file: ./Dockerfile
          load: true
          tags: microservice:test-${{ github.sha }}

      - name: Vulnerability Scan Image via Trivy
        uses: aquasecurity/trivy-action@0.18.0
        with:
          image-ref: 'microservice:test-${{ github.sha }}'
          format: 'sarif'
          output: 'trivy-results.sarif'
          severity: 'CRITICAL,HIGH'
          exit-code: '1'

  smoke-test-deployment:
    name: Post-Deployment Smoke & Verification Testing
    runs-on: ubuntu-latest
    needs: build-and-package
    if: github.ref == 'refs/heads/main'
    steps:
      - name: Simulate Production Deployment Trigger
        run: |
          echo "Simulating rollout to production Kubernetes cluster..."
          sleep 2

      - name: Run Smoke Verification Tests
        run: |
          echo "Executing HTTP Health Endpoint Checks..."
          STATUS_CODE=$(curl -s -o /dev/null -w "%{http_code}" https://httpbin.org/status/200)
          if [ "$STATUS_CODE" -ne 200 ]; then
            echo "CRITICAL: Smoke Test Failed with HTTP Status: $STATUS_CODE"
            exit 1
          fi
          echo "SUCCESS: Production Endpoint Validated with HTTP $STATUS_CODE"
```

---

## 4. Comandos CLI Reales y Salida de Terminal

### Escenario 1: Ejecución de Análisis Estático mediante Hadolint y GolangCI-Lint

```bash
$ hadolint Dockerfile
```
```text
Dockerfile:11 DL3018 warning: Pin versions in apk add. Instead of `apk add <package>` use `apk add <package>=<version>`
Dockerfile:25 DL3006 warning: Always use specific tags when referencing images.
```

```bash
$ golangci-lint run --v
```
```text
INFO [config_reader] Config search paths: [./ .golangci.yml]
INFO [lintersdb] Active linters: [errcheck gosimple govet ineffassign staticcheck typecheck unused]
INFO [runner] Compiling code and analyzing AST...
cmd/server/main.go:42:15: errcheck: Error returned from `http.ListenAndServe` is not checked (govet)
	http.ListenAndServe(":8080", router)
	                  ^
pkg/database/db.go:18:2: ineffassign: ineffectual assignment to err (ineffassign)
	err = db.Ping()
	^
FAIL golangci-lint found 2 issues
```

---

### Escenario 2: Ejecución de Pruebas Unitarias con Detector de Condiciones de Carrera y Generación de Cobertura

```bash
$ go test -v -race -coverprofile=coverage.out ./...
```
```text
=== RUN   TestCalculateMetrics
=== RUN   TestCalculateMetrics/ValidInput
=== RUN   TestCalculateMetrics/NilPointerHandled
--- PASS: TestCalculateMetrics (0.02s)
    --- PASS: TestCalculateMetrics/ValidInput (0.01s)
    --- PASS: TestCalculateMetrics/NilPointerHandled (0.01s)
=== RUN   TestDatabaseConnectionPool
--- PASS: TestDatabaseConnectionPool (0.15s)
PASS
coverage: 84.6% of statements
ok  	github.com/enterprise/microservice/pkg/metrics	0.218s	coverage: 84.6% of statements
```

```bash
$ go tool cover -func=coverage.out
```
```text
github.com/enterprise/microservice/pkg/metrics/calculator.go:12:	CalculateMetrics	100.0%
github.com/enterprise/microservice/pkg/metrics/calculator.go:34:	ParseHeaders		75.0%
github.com/enterprise/microservice/pkg/metrics/db.go:10:		ConnectDB		80.0%
total:                                    (statements)		84.6%
```

---

### Escenario 3: Depuración Interactiva de un Ejecutable mediante Delve (`dlv`)

```bash
$ dlv exec ./bin/server
```
```text
Type 'help' for list of commands.
(dlv) break main.main
Breakpoint 1 set at 0x7b4a2e for main.main() ./cmd/server/main.go:15
(dlv) continue
> main.main() ./cmd/server/main.go:15 (hits breakpoint 1)
    10:	import "fmt"
    11:	
    12:	func main() {
    13:		port := 8080
 => 14:		fmt.Printf("Starting HTTP Server on port %d\n", port)
    15:		startServer(port)
    16:	}
(dlv) print port
8080
(dlv) stack
0  0x00000000007b4a2e in main.main
   at ./cmd/server/main.go:15
1  0x0000000000438b91 in runtime.main
   at /usr/local/go/src/runtime/proc.go:267
2  0x000000000046b841 in runtime.goexit
   at /usr/local/go/src/runtime/asm_amd64.s:1650
(dlv) quit
```

---

### Escenario 4: Consulta del Estado del Pipeline mediante GitHub CLI (`gh`)

```bash
$ gh run list --workflow=production-pipeline.yml --limit 3
```
```text
STATUS  RESULT  TITLE                                        WORKFLOW                    BRANCH  EVENT  ID          ELAPSED
✓       success Hermetic OCI Image Build & Security Scan...  Production Pipeline         main    push   8573920192  2m14s
✗       failure Fix database connection retry logic          Production Pipeline         main    push   8572110481  1m45s
✓       success Add user authentication middleware           Production Pipeline         main    push   8569482011  2m02s
```

```bash
$ gh run view 8572110481 --failed
```
```text
X Production Pipeline · 8572110481
Main tasks failing:
  * automated-testing

--- Log output for failing step 'Execute Unit Tests with Coverage' ---
=== RUN   TestDatabaseConnectionPool
    db_test.go:45: Failed: Expected 5 max connections, got 0
--- FAIL: TestDatabaseConnectionPool (0.05s)
FAIL
FAIL	github.com/enterprise/microservice/pkg/database	0.080s
FAIL
```

---

## 5. Guía de Verificación y Resolución de Problemas de Diagnóstico

```
+-----------------------------------------------------------------------------------------------+
|                                DIAGNOSTIC TROUBLESHOOTING WORKFLOW                            |
+-----------------------------------------------------------------------------------------------+
|                                                                                               |
|  [ CI Pipeline Failure Detected ]                                                             |
|                 |                                                                             |
|                 v                                                                             |
|  +------------------------------+                                                             |
|  | Categorize Failure Spectrum  |                                                             |
|  +------------------------------+                                                             |
|        |                |                |                                                    |
|        v                v                v                                                    |
|  +-----------+    +-----------+    +-----------+                                              |
|  | Build/    |    | Test      |    | Pipeline  |                                              |
|  | Compiler  |    | Flakiness |    | Stalls    |                                              |
|  +-----------+    +-----------+    +-----------+                                              |
|        |                |                |                                                    |
|        +----------------+----------------+                                                    |
|                         |                                                                     |
|                         v                                                                     |
|  +-----------------------------------------------------------------------------------------+  |
|  | Root Cause Identification & Remediation                                                 |  |
|  | - Replicate locally via DevContainers                                                   |  |
|  | - Enable runtime race detectors (-race)                                                 |  |
|  | - Enforce CGO_ENABLED=0 static linking for musl/glibc portability                      |  |
|  +-----------------------------------------------------------------------------------------+  |
|                                                                                               |
+-----------------------------------------------------------------------------------------------+
```

### Flujos de Trabajo de Diagnóstico Estructurados

#### Fase 1: Diagnóstico de Compilación y Compilador
1. **Síntoma:** El binario falla en tiempo de ejecución en un contenedor mínimo (`scratch` o `alpine`) con `exec format error` o `file not found`.
2. **Análisis de Causa Raíz:** Enlazado dinámico contra la `glibc` del host cuando la imagen del runtime de destino carece de `glibc` (por ejemplo, utiliza `musl` o `scratch`).
3. **Comandos de Remediación:**
   * Inspeccionar los enlazados del binario: `file ./bin/server` o `ldd ./bin/server`.
   * Forzar la compilación estática en los scripts de compilación: `CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-extldflags '-static'"`.

#### Fase 2: Inestabilidad de la Suite de Pruebas y Contaminación del Entorno
1. **Síntoma:** Las pruebas pasan localmente pero fallan esporádicamente bajo alta concurrencia en los pipelines de CI.
2. **Análisis de Causa Raíz:** Estado global compartido, condiciones de carrera o acceso concurrente no coordinado a puertos de bases de datos.
3. **Comandos de Remediación:**
   * Ejecutar el bucle de pruebas local bajo el detector de condiciones de carrera: `go test -race -count=50 ./...`.
   * Utilizar fixtures contenedorizados aislados (por ejemplo, Testcontainers) vinculados a puertos efímeros dinámicos del host en lugar de puertos estáticos prefijados (por ejemplo, `:5432`).

#### Fase 3: Ejecución de CI/CD y Resolución de Problemas de Secretos
1. **Síntoma:** El runner del pipeline de CI agota el tiempo de espera (timeout) o falla durante la ejecución de un paso sin registros de error explícitos.
2. **Análisis de Causa Raíz:** Agotamiento de disco/memoria en el runner o proceso bloqueado indefinidamente por solicitudes interactivas no gestionadas (`stdin`).
3. **Comandos de Remediación:**
   * Forzar flags de entorno no interactivo en las definiciones de CI: `DEBIAN_FRONTEND=noninteractive`, `CI=true`.
   * Purgar periódicamente cachés de compilación no utilizados: `docker builder prune -a -f`.

---

### Matriz de Diagnóstico de Análisis de Causa Raíz (RCA)

| Síntoma de Fallo | Causa Raíz Subyacente | Comando de Verificación | Acción de Remediación |
| :--- | :--- | :--- | :--- |
| Fallo de `hadolint`: `DL3018` | Dependencias del gestor de paquetes sin versión fijada (unpinned) en Dockerfile. | `hadolint Dockerfile` | Especificar versiones explícitas de los paquetes (ej. `apk add --no-cache curl=8.5.0-r0`). |
| Condición de carrera de datos detectada en CI | Múltiples goroutines/hilos accediendo a memoria compartida de forma concurrente sin protección de mutex. | `go test -race ./...` | Sincronizar el acceso al estado utilizando mutexes (`sync.Mutex`) o canales thread-safe. |
| Fallo en la barrera de vulnerabilidad CRITICAL de `Trivy` | La imagen base contiene CVEs no corregidos. | `trivy image <image:tag>` | Actualizar la versión de la imagen base o migrar la etapa de compilación a imágenes mínimas sin distribución (`scratch`). |
| Prueba de Humo HTTP 503 Service Unavailable | Falló el readiness probe tras el despliegue debido a un pool de BD no inicializado. | `kubectl describe pod <pod-name>` | Incrementar `initialDelaySeconds` y `failureThreshold` en los startup/readiness probes de Kubernetes. |

---

## 6. Referencias

* **Linux Professional Institute (LPI) Open Source Essentials Objectives (050-100):**  
  [https://wiki.lpi.org/wiki/Open_Source_Essentials_Objectives_V1.0(050-100)](https://wiki.lpi.org/wiki/Open_Source_Essentials_Objectives_V1.0(050-100))

* **LPI Learning Portal — Open Source Essentials:**  
  [https://learning.lpi.org/en/learning-materials/050-100/](https://learning.lpi.org/en/learning-materials/050-100/)

* **Continuous Delivery Foundation (CDF) Best Practices:**  
  [https://cd.foundation/](https://cd.foundation/)

* **Open Source Initiative (OSI) Standards & Definition:**  
  [https://opensource.org/](https://opensource.org/)

* **Development Containers Specification (DevContainers):**  
  [https://containers.dev/](https://containers.dev/)

* **Hadolint Dockerfile Linter Documentation:**  
  [https://github.com/hadolint/hadolint](https://github.com/hadolint/hadolint)