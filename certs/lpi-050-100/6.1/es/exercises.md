# Guía de Estudio LPI 050-100: Tema 6.1 – Herramientas de Desarrollo

**Certificación del Examen:** LPI Open Source Essentials (Examen 050-100)  
**Tema:** 6.1 / 056.1 Herramientas de Desarrollo  
**Ponderación:** 5  
**Nivel Objetivo:** Senior SRE / Principal Platform Architect  

---

## 1. Arquitectura Técnica Profunda y Mecánica Interna

### 1.1 Clasificación del Ecosistema de Herramientas de Desarrollo y Mecánica de Ejecución

El desarrollo de software moderno se basa en una suite desacoplada e interoperable de herramientas de desarrollo. Comprender cómo interactúan estas herramientas a nivel de kernel, proceso y sistema es crítico para diseñar entornos de desarrollo reproducibles y pipelines de plataforma CI/CD de alto rendimiento.

```
+-----------------------------------------------------------------------------------+
|                                  DEVELOPER LAYER                                  |
|  +---------------------------+                +---------------------------------+  |
|  |     IDE / Text Editor     | <--- JSON-RPC | Language Server Protocol (LSP)  |  |
|  |  (VS Code, Neovim, Emacs) |      (stdio)   | (clangd, gopls, pyright, etc.)  |  |
|  +---------------------------+                +---------------------------------+  |
+----------------------------------------|------------------------------------------+
                                         | File System Events / AST Parsing
+----------------------------------------v------------------------------------------+
|                              BUILD & EXECUTION LAYER                              |
|  +------------------------+      +---------------------+      +----------------+  |
|  | Build Automation (DAG) | ---> | Compiler / Linker   | ---> | Executable ELF |  |
|  | (Make, Bazel, CMake)   |      | (GCC, Clang, Rustc) |      | Binary / JIT   |  |
|  +------------------------+      +---------------------+      +----------------+  |
|               |                             ^                          ^          |
|               v                             |                          |          |
|  +------------------------+                 |                          |          |
|  | Static Analysis / AST  | ----------------+                          |          |
|  | (ShellCheck, ESLint)   |                                            |          |
|  +------------------------+                                            |          |
+----------------------------------------|------------------------------------------+
                                         | Runtime Process Tracking
+----------------------------------------v------------------------------------------+
|                            DIAGNOSTICS & RUNTIME LAYER                            |
|  +------------------------+      +---------------------+      +----------------+  |
|  | Dynamic Debuggers      | ---> | Kernel ptrace() API | ---> | Process Memory |  |
|  | (GDB, LLDB, Delve)     |      | Call Traps & Signals|      | Registers / RAM|  |
|  +------------------------+      +---------------------+      +----------------+  |
+-----------------------------------------------------------------------------------+
```

#### A. Modelos de Compilación vs. Interpretación
*   **Compiladores (ej., GCC, Clang, Rustc):** Transforman el código fuente de alto nivel a través de fases distintas: Análisis Léxico (tokenización) $\rightarrow$ Análisis Sintáctico (Árbol de Sintaxis Abstracta / generación de AST) $\rightarrow$ Optimización de Representación Intermedia (IR) $\rightarrow$ Generación de Código Máquina. El enlazador (`ld`) resuelve símbolos a través de archivos objeto (`.o`) y bibliotecas compartidas (`.so`) para construir un binario Formato Ejecutable y Enlazable (ELF) en Linux.
*   **Intérpretes y Runtimes JIT (ej., Python, Node.js/V8, JVM):** Analizan el código fuente directamente en bytecode intermedio. Los compiladores Just-In-Time (JIT) realizan un perfilado dinámico de los puntos críticos (hot-spots) de ejecución en tiempo de ejecución y traducen las rutas de bytecode ejecutadas con frecuencia en bloques de instrucciones nativas de CPU almacenados en búferes de memoria ejecutable (`mmap` con `PROT_EXEC`).

#### B. Arquitectura del Protocolo de Servidor de Lenguaje (LSP) y Protocolo Adaptador de Depuración (DAP)
*   **LSP:** Desacopla la inteligencia del lenguaje (autocompletado, ir a la definición, diagnósticos en tiempo real) de los editores de texto utilizando un protocolo estandarizado JSON-RPC 2.0 sobre `stdio` o sockets TCP. El editor actúa como un Cliente LSP; el servidor de lenguaje se ejecuta como un demonio independiente, analizando de forma incremental los árboles de fuentes en AST residentes en memoria.
*   **DAP:** Estandariza las operaciones abstractas de depuración (establecer puntos de interrupción [breakpoints], avanzar paso a paso por las instrucciones, inspeccionar marcos de pila [stack frames]) entre las GUI de los IDE y los depuradores de procesos dinámicos (`gdb`, `lldb`, `dlv`).

#### C. Sistemas de Construcción y Mecánica del Motor de Caché DAG
Las herramientas de construcción modernas (`Make`, `Ninja`, `Bazel`) modelan los objetivos de compilación como nodos dentro de un **Grafo Acíclico Dirigido (DAG)**. 
*   **Evaluación basada en marcas de tiempo (Make):** Evalúa el tiempo de modificación (`mtime`) del nodo objetivo frente a los tiempos de modificación de las dependencias. Si `mtime(dependencia) > mtime(objetivo)`, el subárbol de la rama se recompila.
*   **Almacenamiento Direccionable por Contenido (Bazel/Turbo):** Calcula hashes criptográficos (SHA-256) del código de entrada, variables de entorno, binarios de la cadena de herramientas (toolchain) y flags del compilador. Los aciertos en caché omiten la invocación del compilador por completo.

#### D. Análisis Estático de Código y Verificación de AST
Los analizadores estáticos (`ShellCheck`, `ESLint`, `SonarQube`, `cppcheck`) inspeccionan el código sin ejecutarlo. Escanean léxicamente los archivos, construyen nodos AST y ejecutan pasadas de coincidencia de patrones estructurales para atrapar antipatrones en tiempo de ejecución (ej., expansión de shell sin entrecomillar, fugas de memoria, retornos de error no manejados y vulnerabilidades de inyección).

---

### 1.2 Matriz de Compensaciones Arquitectónicas y Operativas

| Categoría de Herramienta de Desarrollo | Mecanismo Principal | Ventajas Clave | Sobrecarga de Producción / Compensaciones Operativas |
| :--- | :--- | :--- | :--- |
| **Cadenas de herramientas nativas (GCC/Make)** | Compilación directa C/C++ a través de llamadas al sistema POSIX | Rendimiento máximo de CPU en tiempo de ejecución, huella de memoria mínima | Alto desvío de dependencias del host; falta de reproducibilidad del entorno entre máquinas de dev |
| **Servidores de Lenguaje LSP / DAP** | Demonio JSON-RPC fuera de proceso sobre `stdio` | Elección de editor desacoplada, diagnósticos IDE en tiempo real | Alto uso de RAM residente (ej., `gopls` o `rust-analyzer` ocupando 1-4GB en monorepos grandes) |
| **Flujos de trabajo contenedorizados (Devcontainers)** | Contenedorización Docker/Podman con bind mounts | Entornos 100% reproducibles, dependencias de toolchain aisladas | Alta sobrecarga de I/O en bind mounts a través de barreras del kernel; mayor consumo de memoria |
| **Analizadores Estáticos (ShellCheck/Linter)** | Coincidencia de patrones en nodos AST y escaneo de tokens | Captura errores antes de la compilación/despliegue en CI | Mayor tiempo de ejecución del pipeline de CI; potencial fatiga por falsos positivos |
| **Depuradores Dinámicos (GDB/ptrace)** | Intercepción de llamadas al sistema Linux `ptrace()` en el kernel | Inspección paso a paso de instrucciones y estado de memoria | Sustancial ralentización del rendimiento durante la ejecución; riesgo de seguridad si se ejecuta en producción |

---

## 2. Manifiestos y Configuraciones Sintácticamente Válidos para Producción

### 2.1 GNU Makefile de Grado de Producción con Rastreo de Dependencias DAG

Guarde este archivo como `Makefile`. Incluye una comprobación estricta de errores, rastreo automático de dependencias de encabezados (generación `.d`) y orquestación de compilación multiobjetivo.

```makefile
# ==============================================================================
# Production-Grade Multi-Target Makefile
# Provides strict C compilation, automatic DAG dependency tracking, and clean targets
# ==============================================================================

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

# Compiler and Flags
CC := gcc
CFLAGS := -std=c11 -Wall -Wextra -Werror -pedantic -MMD -MP -O2 -g
LDFLAGS := -Wl,-z,relro,-z,now

# Directory Structure
SRC_DIR := src
BUILD_DIR := build
BIN_DIR := bin

# Target Executable Name
TARGET := $(BIN_DIR)/app_server

# Source and Object Files
SRCS := $(wildcard $(SRC_DIR)/*.c)
OBJS := $(SRCS:$(SRC_DIR)/%.c=$(BUILD_DIR)/%.o)
DEPS := $(OBJS:.o=.d)

.PHONY: all clean lint test info

all: $(TARGET)

# Build Rule for Target Binary
$(TARGET): $(OBJS) | $(BIN_DIR)
	@echo "[LINK] Creating executable binary: $@"
	$(CC) $(OBJS) $(LDFLAGS) -o $@

# Build Rule for Object Files with Auto Dependency (.d) Generation
$(BUILD_DIR)/%.o: $(SRC_DIR)/%.c | $(BUILD_DIR)
	@echo "[CC] Compiling source file: $<"
	$(CC) $(CFLAGS) -c $< -o $@

# Directory Creation Rules
$(BUILD_DIR) $(BIN_DIR):
	@mkdir -p $@

# Automated Static Code Linting
lint:
	@echo "[LINT] Running static analysis..."
	@which shellcheck >/dev/null && shellcheck scripts/*.sh || true

# Test Execution
test: all
	@echo "[TEST] Executing test suit..."
	@./$(TARGET) --test

# Environment Clean Up
clean:
	@echo "[CLEAN] Purging build artifacts..."
	rm -rf $(BUILD_DIR) $(BIN_DIR)

# Include Generated Dependency Files (DAG resolution)
-include $(DEPS)
```

---

### 2.2 Manifiesto de Contenedor de Desarrollo de Producción (`devcontainer.json`)

Guarde este archivo como `.devcontainer/devcontainer.json` para definir un entorno de desarrollo estandarizado utilizando la especificación Dev Container.

```json
{
  "name": "SRE Production C/Linux Toolchain",
  "image": "mcr.microsoft.com/devcontainers/base:debian-12",
  "features": {
    "ghcr.io/devcontainers/features/common-utils:2": {
      "installZsh": true,
      "username": "vscode",
      "userUid": "1000",
      "userGid": "1000"
    },
    "ghcr.io/devcontainers/features/rust:1": {
      "version": "latest"
    }
  },
  "customizations": {
    "vscode": {
      "settings": {
        "terminal.integrated.defaultProfile.linux": "zsh",
        "editor.formatOnSave": true,
        "C_Cpp.default.compilerPath": "/usr/bin/gcc",
        "C_Cpp.default.cStandard": "c11"
      },
      "extensions": [
        "ms-vscode.cpptools",
        "timonwong.shellcheck",
        "golang.go",
        "esbenp.prettier-vscode"
      ]
    }
  },
  "postCreateCommand": "sudo apt-get update && sudo apt-get install -y gcc make gdb valgrind shellcheck build-essential",
  "remoteUser": "vscode",
  "runArgs": [
    "--cap-add=SYS_PTRACE",
    "--security-opt",
    "seccomp=unconfined"
  ]
}
```

---

### 2.3 Flujo de Trabajo de Quality Gate de CI de GitHub Actions para Producción

Guarde este archivo como `.github/workflows/dev-quality-gate.yml`.

```yaml
name: Development Quality Gate & Build Verification

on:
  push:
    branches: [ "main", "develop" ]
  pull_request:
    branches: [ "main" ]

jobs:
  static-analysis-and-build:
    name: Code Quality Gate & Automated Build
    runs-on: ubuntu-22.04

    steps:
      - name: Checkout Source Code
        uses: actions/checkout@v4

      - name: Install System Dependencies & Toolchain
        run: |
          sudo apt-get update
          sudo apt-get install -y gcc make gdb valgrind shellcheck

      - name: Execute ShellCheck Static Analysis
        run: |
          echo "=== Running ShellCheck on repository scripts ==="
          find . -type f -name "*.sh" -exec shellcheck -S warning {} +

      - name: Validate Makefile Structure & DAG Dependencies
        run: |
          echo "=== Verifying Build System Execution ==="
          make clean
          make info || true
          make all

      - name: Run Binary Memory Leak Diagnostic (Valgrind)
        run: |
          echo "=== Executing Valgrind Diagnostics ==="
          valgrind --leak-check=full --error-exitcode=1 ./bin/app_server --test || true

      - name: Upload Binary Artifact
        uses: actions/upload-artifact@v4
        with:
          name: app_server-linux-amd64
          path: bin/app_server
          retention-days: 7
```

---

## 3. Flujos de Trabajo de CLI de Diagnóstico Avanzado y Ejecución

### Flujo de trabajo 3.1: Fases de Compilación de GCC e Inspección de Ensamblador AST
Inspeccione cómo un compilador de C procesa el código a través de las fases de preprocesamiento, ensamblado y enlazado.

```bash
# 1. Create a minimal C program for testing
cat << 'EOF' > main.c
#include <stdio.h>
#define APP_VERSION "2.4.0"

int calculate_capacity(int nodes, int cpu_per_node) {
    return nodes * cpu_per_node;
}

int main(void) {
    int total = calculate_capacity(16, 8);
    printf("Cluster Capacity (vCPU): %d (Version: %s)\n", total, APP_VERSION);
    return 0;
}
EOF

# 2. Run Preprocessor Phase (Macro Expansion & Header Inclusion)
gcc -E main.c -o main.i
tail -n 10 main.i

# Output expected:
# int calculate_capacity(int nodes, int cpu_per_node) {
#     return nodes * cpu_per_node;
# }
# 
# int main(void) {
#     int total = calculate_capacity(16, 8);
#     printf("Cluster Capacity (vCPU): %d (Version: %s)\n", total, "2.4.0");
#     return 0;
# }

# 3. Generate Assembly Instructions (Target Assembly Code)
gcc -S -O2 main.c -o main.s
grep -A 10 "main:" main.s

# Output expected:
# main:
# .LFB12:
# 	.cfi_startproc
# 	subq	$8, %rsp
# 	.cfi_def_cfa_offset 16
# 	movl	$128, %edx
# 	leaq	.LC0(%rip), %rsi
# 	movl	$1, %edi
# 	xorl	%eax, %eax
# 	call	__printf_chk@PLT

# 4. Compile into Object File and Inspect ELF Symbols
gcc -c main.c -o main.o
readelf -s main.o | grep FUNC
```

Resultado esperado para la resolución de símbolos:
```text
    8: 0000000000000000    20 FUNC    GLOBAL DEFAULT    1 calculate_capacity
    9: 0000000000000014    42 FUNC    GLOBAL DEFAULT    1 main
```

---

### Flujo de trabajo 3.2: Diagnósticos Estáticos de Código con ShellCheck
Escanee scripts de shell en busca de errores ocultos, riesgos de división de palabras (word-splitting) y expansiones de variables sin entrecomillar.

```bash
# Create an insecure shell script with deliberate flaws
cat << 'EOF' > deploy.sh
#!/bin/bash
TARGET_DIR=$1
files=$(ls $TARGET_DIR)

for file in $files; do
    echo Processing $file
    rm -rf /tmp/backup/$file
done
EOF

# Run ShellCheck analysis over the script
shellcheck deploy.sh
```

Resultado esperado:
```text
In deploy.sh line 3:
TARGET_DIR=$1
           ^-- SC2086 (info): Double quote to prevent globbing and word splitting.

In deploy.sh line 4:
files=$(ls $TARGET_DIR)
      ^-- SC2045 (warning): Iterating over ls output is fragile. Use globs.
           ^-- SC2086 (info): Double quote to prevent globbing and word splitting.

In deploy.sh line 6:
    echo Processing $file
                    ^-- SC2086 (info): Double quote to prevent globbing and word splitting.

In deploy.sh line 7:
    rm -rf /tmp/backup/$file
                       ^-- SC2086 (info): Double quote to prevent globbing and word splitting.
```

---

### Flujo de trabajo 3.3: Depuración Interactiva de Procesos mediante GDB
Inspeccione la memoria y avance paso a paso a través de la ejecución del binario utilizando GDB.

```bash
# Compile binary with debugging symbols (-g) and disabled optimizations (-O0)
gcc -g -O0 main.c -o app_debug

# Launch GDB in non-interactive batch mode to inspect breakpoint and stack frame
gdb -batch \
    -ex "break calculate_capacity" \
    -ex "run" \
    -ex "info args" \
    -ex "print nodes" \
    -ex "print cpu_per_node" \
    -ex "backtrace" \
    ./app_debug
```

Resultado esperado:
```text
Breakpoint 1 at 0x1149: file main.c, line 5.
Starting program: /home/user/app_debug 

Breakpoint 1, calculate_capacity (nodes=16, cpu_per_node=8) at main.c:5
5	    return nodes * cpu_per_node;
nodes = 16
cpu_per_node = 8
$1 = 16
$2 = 8
#0  calculate_capacity (nodes=16, cpu_per_node=8) at main.c:5
#1  0x000055555555517b in main () at main.c:9
```

---

## 4. Ejercicios Guiados Prácticos

### Ejercicio 1: Automatización de Construcción e Inspección de Dependencias DAG con GNU Make

#### Paso 1: Inicializar el Directorio del Espacio de Trabajo
Cree una estructura de proyecto que contenga código fuente C y encabezados modulares.

```bash
mkdir -p dev_tools_lab/src dev_tools_lab/include
cd dev_tools_lab

cat << 'EOF' > include/metrics.h
#ifndef METRICS_H
#define METRICS_H
void print_metrics(const char* service_name, int requests);
#endif
EOF

cat << 'EOF' > src/metrics.c
#include <stdio.h>
#include "../include/metrics.h"

void print_metrics(const char* service_name, int requests) {
    printf("[METRICS] Service: %s | Total Requests: %d\n", service_name, requests);
}
EOF

cat << 'EOF' > src/main.c
#include "../include/metrics.h"

int main(void) {
    print_metrics("api-gateway", 50400);
    return 0;
}
EOF
```

#### Paso 2: Crear un Makefile Básico
Cree un `Makefile` en `dev_tools_lab/`:

```makefile
CC = gcc
CFLAGS = -Iinclude -Wall -g

app: src/main.o src/metrics.o
	$(CC) src/main.o src/metrics.o -o app

src/main.o: src/main.c
	$(CC) $(CFLAGS) -c src/main.c -o src/main.o

src/metrics.o: src/metrics.c
	$(CC) $(CFLAGS) -c src/metrics.c -o src/metrics.o

clean:
	rm -f src/*.o app
```

#### Paso 3: Ejecutar la Construcción Incremental y Observar la Evaluación de Marcas de Tiempo DAG
Ejecute `make`, modifique un archivo y vuelva a ejecutar `make`.

```bash
# Initial compilation
make

# Check timestamp of generated binary
ls -l app

# Modify metrics header file
touch include/metrics.h

# Re-run make
make
```

#### Preguntas de Verificación (Ejercicio 1)
1. **Pregunta 1.1:** Cuando se ejecutó `touch include/metrics.h`, ¿recompiló `make` los archivos `src/main.o` y `src/metrics.o`? ¿Por qué sí o por qué no según las definiciones de reglas del Paso 2?
2. **Pregunta 1.2:** ¿Cómo altera la adición de los flags `-MMD -MP` a `CFLAGS` el manejo interno de GNU Make de las dependencias de archivos de encabezado?

---

### Ejercicio 2: Análisis Estático, Linting de AST e Integración con Devcontainer

#### Paso 1: Escribir un Script de Aplicación con Posibles Fallos de Seguridad y Parsing
Cree un script llamado `server_check.sh`:

```bash
cat << 'EOF' > server_check.sh
#!/bin/bash
HOSTS="10.0.0.1 10.0.0.2 10.0.0.3"
LOGFILE=/var/log/checker.log

echo "Checking hosts..." >> $LOGFILE

for host in $HOSTS; do
    ping -c 1 $host > /dev/null
    if [ $? -eq 0 ]; then
        echo "Host $host is UP"
    fi
done
EOF
```

#### Paso 2: Ejecutar Análisis Estático y Reparar Advertencias de Calidad de Código
Ejecute `shellcheck` contra el script y observe las advertencias del AST.

```bash
shellcheck server_check.sh
```

#### Paso 3: Refactorizar el Script para Pasar las Puertas de Análisis Estático
Refactorice `server_check.sh` para que ShellCheck devuelva cero advertencias (código de salida 0).

```bash
cat << 'EOF' > server_check.sh
#!/bin/bash
hosts=("10.0.0.1" "10.0.0.2" "10.0.0.3")
logfile="/var/log/checker.log"

echo "Checking hosts..." >> "$logfile"

for host in "${hosts[@]}"; do
    if ping -c 1 "$host" > /dev/null 2>&1; then
        echo "Host $host is UP"
    fi
done
EOF

shellcheck server_check.sh
echo "ShellCheck Exit Code: $?"
```

#### Preguntas de Verificación (Ejercicio 2)
1. **Pregunta 2.1:** ¿Qué vulnerabilidad o comportamiento inesperado ocurre al iterar sobre una variable de cadena no entrecomillada `for host in $HOSTS; do` si `$HOSTS` contiene espacios o caracteres comodín (`*`)?
2. **Pregunta 2.2:** ¿Cuál es la diferencia fundamental entre cómo un Linter (como ShellCheck) inspecciona el código frente a cómo opera una herramienta de Pruebas de Seguridad de Aplicaciones Dinámicas (DAST)?

---

### Ejercicio 3: Depuración de Procesos e Inspección de Símbolos Binarios

#### Paso 1: Compilar un Programa en C con Asignación de Memoria
Cree `mem_lab.c`:

```bash
cat << 'EOF' > mem_lab.c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void leak_memory(void) {
    char *buffer = malloc(256);
    strcpy(buffer, "SRE Memory Leak Test");
    printf("Buffer Content: %s\n", buffer);
    // free(buffer); // Intentionally omitted
}

int main(void) {
    leak_memory();
    return 0;
}
EOF

gcc -g mem_lab.c -o mem_lab
```

#### Paso 2: Analizar el Binario con la Herramienta de Diagnóstico de Memoria Valgrind
Ejecute `valgrind` para rastrear las asignaciones de heap y las fugas de memoria.

```bash
valgrind --leak-check=full ./mem_lab
```

#### Preguntas de Verificación (Ejercicio 3)
1. **Pregunta 3.1:** ¿Qué mecanismo del kernel y secciones ejecutables permiten a Valgrind y GDB señalar el número de línea exacto del código fuente (`mem_lab.c:7`) al analizar un fallo de memoria?
2. **Pregunta 3.2:** ¿Cuál es la compensación operativa de compilar binarios de producción conservando las tablas de símbolos intactas (`-g`) frente a despojar (strip) los símbolos (`strip --strip-unneeded`)?

---

## 5. Respuestas y Explicaciones

<details>
<summary><strong>Haga clic aquí para desplegar las Respuestas y Explicaciones Detalladas</strong></summary>

### Respuestas del Ejercicio 1

*   **Respuesta a la Pregunta 1.1:** En el Paso 2, `make` **no** recompiló los archivos objeto cuando se modificó `include/metrics.h`. Esto ocurrió porque `include/metrics.h` no estaba listado explícitamente como un prerrequisito en las reglas del `Makefile` para `src/main.o` o `src/metrics.o` (`src/main.o: src/main.c`). GNU Make solo evalúa las marcas de tiempo de modificación de archivos (`mtime`) de los archivos listados explícitamente en la lista de dependencias de la regla objetivo.
*   **Respuesta a la Pregunta 1.2:** El flag `-MMD` le indica a GCC que genere archivos de dependencias (`.d`) que contienen el árbol exacto de dependencias de encabezados para cada archivo fuente. El flag `-MP` agrega objetivos ficticios (phony dummy targets) para cada archivo de encabezado para evitar errores de `make` si se elimina un encabezado. Incluir `-include $(DEPS)` en el `Makefile` garantiza que Make rastree dinámicamente las modificaciones de los encabezados sin actualizaciones manuales.

---

### Respuestas del Ejercicio 2

*   **Respuesta a la Pregunta 2.1:** Una expansión de variable no entrecomillada `$HOSTS` hace que la shell realice **División de Palabras (Word Splitting)** (basada en `$IFS`) y **Expansión de Rutas (Globbing)**. Si `$HOSTS` contiene espacios en blanco o caracteres comodín como `*` o `?`, la shell los expande en nombres de archivos que coincidan en el directorio local, distorsionando la iteración del array e introduciendo riesgos de ejecución/inyección de comandos.
*   **Respuesta a la Pregunta 2.2:** Un Linter evalúa el código de forma **estática** analizando el texto plano en un Árbol de Sintaxis Abstracta (AST) y aplicando comprobadores de reglas sin ejecutar el código. Las herramientas DAST (Pruebas de Seguridad de Aplicaciones Dinámicas) evalúan el código de forma **dinámica** en tiempo de ejecución ejecutando el binario/servicio e inyectando cargas útiles (payloads) reales para observar los estados de memoria en tiempo de ejecución, las respuestas HTTP o el comportamiento del proceso.

---

### Respuestas del Ejercicio 3

*   **Respuesta a la Pregunta 3.1:** Compilar con `-g` incrusta secciones de depuración **DWARF (Debugging With Attributed Record Formats)** (`.debug_info`, `.debug_line`, `.debug_str`) dentro del binario ELF. Estas secciones mapean direcciones de memoria física y punteros de instrucciones directamente a los nombres de archivos de código fuente, ámbitos de función y números de línea.
*   **Respuesta a la Pregunta 3.2:** 
    *   *Conservar símbolos (`-g`):* Esencial para los diagnósticos de SRE en producción (análisis de core dumps, desmantelamiento de stack traces, perfiladores), pero aumenta el tamaño del binario en disco.
    *   *Despojar símbolos (`strip`):* Reduce el tamaño del archivo ejecutable y elimina metadatos detallados del diseño interno del código, pero complica la depuración en tiempo real durante caídas inesperadas de procesos en producción.

</details>

---

## 6. Referencias Oficiales y Enlaces de Citación

*   **Visión general de LPI Open Source Essentials:**  
    [https://www.lpi.org/our-certifications/open-source-essentials-overview/](https://www.lpi.org/our-certifications/open-source-essentials-overview/)
*   **Portal de Materiales de Aprendizaje de LPI:**  
    [https://learning.lpi.org/](https://learning.lpi.org/)
*   **Documentación Oficial de GNU Make (DAG y Motor de Dependencias):**  
    [https://www.gnu.org/software/make/manual/](https://www.gnu.org/software/make/manual/)
*   **Especificación del Protocolo de Servidor de Lenguaje (LSP):**  
    [https://microsoft.github.io/language-server-protocol/](https://microsoft.github.io/language-server-protocol/)
*   **Especificación de Contenedores de Desarrollo (Development Containers):**  
    [https://containers.dev/](https://containers.dev/)
*   **Manual y Wiki de Análisis Estático de ShellCheck:**  
    [https://www.shellcheck.net/](https://www.shellcheck.net/)