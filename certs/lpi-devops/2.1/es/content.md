# Guía de Estudio para LPI DevOps Tools Engineer (Examen 701-100)
## Tema 701.2 / 2.1: Uso de Contenedores y Arquitectura de Runtime (Peso: 11.67)

---

## 1. Motivación en Producción y Planteamiento del Problema Arquitectónico

En entornos de producción empresariales, los paradigmas de despliegue heredados—como los despliegues bare-metal y la virtualización tradicional por hardware (Virtual Machines a través de hipervisores como KVM/ESXi)—presentan una severa fricción operativa:

1. **Alto Overhead y Latencia de Cold Start**: Las Virtual Machines requieren un sistema operativo guest completo (Kernel, `systemd`/`init`, controladores de dispositivos, daemons del sistema). Los tiempos de arranque varían desde decenas de segundos hasta minutos, consumiendo cientos de megabytes a gigabytes de RAM antes de que se ejecute el código de la aplicación.
2. **Dependency Drift y Builds No Deterministas**: Las variaciones en los paquetes del OS host subyacente, bibliotecas compartidas (`glibc`), enlaces de rutas de enlace dinámico y configuraciones de entorno conducen a un comportamiento operativo no reproducible entre staging y producción.
3. **Contención de Recursos por Noisy Neighbor**: La falta de throttling de CPU y memoria de grano fino a nivel de proceso provoca que procesos deshonestos priven de recursos a las cargas de trabajo adyacentes en hardware compartido.

### La Solución Basada en Primitivas del Kernel de Linux

La contenedorización moderna elimina la capa del OS guest aprovechando las primitivas nativas del Kernel de Linux para aplicar virtualización a nivel de OS. Los contenedores son procesos aislados de Linux que se ejecutan directamente en el kernel del host.

```
+-------------------------------------------------------------------+
|                        User Application                           |
+-------------------------------------------------------------------+
|                 Container Engine (dockerd / containerd)           |
+-------------------------------------------------------------------+
| OCI Runtime Interface (runc) -> Linux Kernel Primitives (cgroups) |
+-------------------------------+-----------------------------------+
| Linux Namespaces (Isolation)  | Control Groups v1/v2 (Limits)     |
| - PID, NET, MNT, IPC, UTS...  | - cpu.cfs_quota_us, memory.max... |
+-------------------------------+-----------------------------------+
|             Host Linux Kernel (Shared Kernel Space)               |
+-------------------------------------------------------------------+
```

#### Linux Namespaces (Límites de Aislamiento de Recursos)
Los namespaces restringen lo que un proceso puede **ver**. El kernel de Linux expone 8 namespaces primarios utilizados por los container runtimes:

*   **`PID` (Process IDs)**: Proporciona numeración independiente de PID. El PID 1 dentro del namespace del contenedor se mapea a un PID arbitrario de número alto en el host.
*   **`NET` (Network Devices)**: Aisla interfaces de red, tablas de enrutamiento IP, reglas de firewall (`iptables`/`nftables`) y sockets de vinculación de puertos (`socket()`).
*   **`MNT` (Mount Points)**: Aisla las tablas de montaje del sistema de archivos (`/proc/mounts`). Combinado con `pivot_root`, aisla el sistema de archivos raíz del contenedor (`/`).
*   **`IPC` (Inter-Process Communication)**: Aisla objetos IPC System V y colas de mensajes POSIX, evitando el acceso a memoria compartida entre contenedores (`shmget`).
*   **`UTS` (UNIX Timesharing System)**: Permite establecer un hostname e NIS domain name independiente por contenedor.
*   **`USER` (User IDs)**: Remapea los rangos UID/GID del contenedor a UIDs/GIDs no privilegiados en el host (ej. el UID 0 `root` del contenedor se mapea al UID 100000 del host).
*   **`CGROUP` (Control Group Root)**: Oculta la estructura jerárquica de cgroups del host ante la inspección de procesos a través de `/proc/self/cgroup`.
*   **`TIME` (Monotonic & Boot Clocks)**: Permite establecer offsets de reloj específicos del contenedor sin alterar la hora del sistema host.

#### Control Groups - cgroups v1 y cgroups v2 (Restricciones de Recursos)
Los cgroups controlan lo que un proceso puede **usar**. Aplican límites cuantitativos de recursos, contabilidad y control sobre los recursos del sistema:

*   **Control de Ancho de Banda CFS**: Implementa la asignación de cuota de CPU mediante `cpu.cfs_quota_us` (cuota permitida por período) y `cpu.cfs_period_us` (por defecto 100000µs / 100ms). Definir `quota=200000` en `period=100000` limita el proceso a 2.0 núcleos vCPU.
*   **Contabilidad de Memoria y Ejecución OOM**: Monitorea el uso de RSS (Resident Set Size), Page Cache y Swap. Alcanzar los umbrales estrictos de memoria (`memory.max` en cgroups v2) desencadena la invocación del kernel out-of-memory (`oom-killer`).

#### Almacenamiento Copy-on-Write (CoW) (OverlayFS)
Combina capas de imagen de solo lectura inferiores (`lowerdir`) con una única capa de contenedor escribible (`upperdir`) fusionadas a través de un punto de montaje unificado (`merged`), permitiendo la instanciación de contenedores en menos de un segundo sin copiar sistemas de archivos de imagen.

---

## 2. Comparaciones Técnicas y Matrices de Trade-offs

### 2.1 Paradigmas de Aislamiento: Bare Metal vs Virtual Machines vs Contenedores

| Feature / Metric | Bare Metal | Hardware Virtualization (VMs) | OS-Level Virtualization (Containers) |
| :--- | :--- | :--- | :--- |
| **Isolation Primitive** | Physical Hardware Boundaries | Hardware Hypervisor (Intel VT-x, AMD-V, KVM) | Linux Kernel Namespaces & cgroups |
| **Kernel Model** | Single Dedicated Kernel | Independent Guest Kernel per VM | Shared Host Linux Kernel |
| **Startup Overhead** | 3 - 10 Minutes | 30 - 90 Seconds | 50 - 500 Milliseconds |
| **Memory Footprint** | Host OS Overhead Only | High (Guest OS + Hypervisor Reserved RAM) | Low (Process RSS + Writable Overlay Layer) |
| **I/O Overhead** | Native Hardware Speed | Near-native (virtio) to Virtualization Loss | Near-native (Direct Kernel syscall / Direct I/O) |
| **Security Surface** | Hardware/Firmware Attack Surface | Strong Hypervisor Isolation Barrier | Kernel Syscall Attack Surface (`seccomp`, `apparmor`) |

### 2.2 Trade-offs de Rendimiento de Storage Drivers

| Storage Driver | Requisitos de Backing Filesystem | Rendimiento Lectura/Escritura | Eficiencia de Memoria | Idoneidad en Producción y Estado |
| :--- | :--- | :--- | :--- | :--- |
| **`overlay2`** | `ext4` o `xfs` (con `ftype=1`) | **Alto**: Excelente uso compartido de page cache, búsqueda rápida | **Alto**: Cache de inode compartido entre contenedores | **Recomendado**: Estándar por defecto en distribuciones modernas de Linux |
| **`btrfs`** | Native pool de `btrfs` | **Moderado**: Overhead de CoW en escrituras aleatorias pesadas | **Moderado**: Rastreo de subvolúmenes dedicado | **Especializado**: Requiere una partición de pool Btrfs dedicada |
| **`zfs`** | zpool de `zfs` | **Moderado**: Alta utilización de RAM (ARC cache) | **Moderado**: Alto uso de memoria para ARC | **Especializado**: Excelentes capacidades de snapshot para almacenamiento de alta densidad |
| **`devicemapper`** | Volumen LVM directo | **Bajo - Moderado**: Bloqueos de asignación a nivel de bloque | **Bajo**: Sin uso compartido de page cache entre capas | **Obsoleto**: Eliminado en versiones modernas de Docker Engine |

### 2.3 Drivers de Red de Contenedores

| Network Driver | Asignación de Dirección IP | Mecanismo de Asignación de Puertos | Nivel de Aislamiento del Host | Caso de Uso |
| :--- | :--- | :--- | :--- | :--- |
| **`bridge`** | Subred privada (ej., `172.17.0.0/16`) vía par `veth` | NAT Port Forwarding (`iptables` DNAT) | Network namespace aislado por contenedor | **Por defecto**: Aplicaciones multicontenedor independientes estándar |
| **`host`** | Comparte la dirección IP del host directamente | Utiliza el namespace de puertos TCP/UDP del host directamente | Aislamiento de red cero (comparte el stack de red del host) | **Alto Rendimiento**: Latencia ultra baja, red de alto rendimiento |
| **`macvlan`** | MAC e IP únicas de la LAN física del host | Vinculación directa a la interfaz física del host (`eth0`) | Aislado del network namespace del host, accesible vía LAN | **Migración Heredada**: La app requiere presencia física directa en la red |
| **`none`** | Sin IP asignada (solo interfaz `loopback`) | Ninguno | Aislamiento de red completo | **Crítico para Seguridad**: Procesadores de datos en lote, trabajos aislados en air-gap |

---

## 3. Manifiestos de Infraestructura de Producción

### 3.1 `Dockerfile` de Producción Multi-Stage Asegurado

The following Dockerfile uses multi-stage builds, non-root execution, `tini` as PID 1, and explicit metadata:

```dockerfile
# ==========================================
# Stage 1: Build & Compilation Environment
# ==========================================
FROM golang:1.22-alpine3.19 AS builder

# Enforce secure compiler flags and module caching
ENV GO111MODULE=on \
    CGO_ENABLED=0 \
    GOOS=linux \
    GOARCH=amd64

WORKDIR /build

# Cache dependency layer independently
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download -x

# Copy source and compile immutable, statically linked binary
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go build -a -installsuffix cgo -ldflags="-w -s -extldflags '-static'" -o /build/api-server ./cmd/server

# ==========================================
# Stage 2: Minimal Distroless Execution Layer
# ==========================================
FROM alpine:3.19.1

# Install security patches, CA certificates, and Tini signal init processor
RUN apk add --no-cache \
    ca-certificates=20240226-r0 \
    tzdata=2024a-r0 \
    tini=0.19.0-r2 \
    && addgroup -g 10001 -S appgroup \
    && adduser -u 10001 -S appuser -G appgroup -h /app

WORKDIR /app

# Copy binary from builder stage with strict non-root ownership
COPY --from=builder --chown=10001:10001 /build/api-server /app/api-server

# Enforce security context: Non-root execution
USER 10001:10001

# Expose service port
EXPOSE 8080

# Health check configuration to ensure operational status
HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
  CMD ["/app/api-server", "-healthcheck"]

# Use Tini as PID 1 to handle SIGTERM, SIGINT, and reap zombie child processes
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/app/api-server"]
```

---

## 3.2 `docker-compose.yml` Empresarial (Especificación Compose V2)

Production multi-container orchestration manifest enforcing strict resource limits, logging constraints, health checks, and non-default bridge networks:

```yaml
version: "3.8"

services:
  database:
    image: postgres:16.2-alpine
    container_name: production_postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: production_db
      POSTGRES_USER_FILE: /run/secrets/db_user
      POSTGRES_PASSWORD_FILE: /run/secrets/db_password
    secrets:
      - db_user
      - db_password
    volumes:
      - postgres_data:/var/lib/postgresql/data:rw
    networks:
      - backend_network
    deploy:
      resources:
        limits:
          cpus: "2.00"
          memory: 2048M
        reservations:
          cpus: "0.50"
          memory: 512M
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $$(cat /run/secrets/db_user) -d production_db"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s
    logging:
      driver: "json-file"
      options:
        max-size: "50m"
        max-file: "5"
        compress: "true"

  api_gateway:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: production_api
    restart: always
    ports:
      - "443:8080"
    environment:
      NODE_ENV: production
      DB_HOST: database
      DB_PORT: "5432"
    depends_on:
      database:
        condition: service_healthy
    networks:
      - frontend_network
      - backend_network
    read_only: true
    tmpfs:
      - /tmp:rw,noexec,nosuid,size=64m
    deploy:
      resources:
        limits:
          cpus: "1.50"
          memory: 1024M
        reservations:
          cpus: "0.25"
          memory: 256M
    healthcheck:
      test: ["CMD", "/app/api-server", "-healthcheck"]
      interval: 10s
      timeout: 3s
      retries: 3
      start_period: 5s
    logging:
      driver: "json-file"
      options:
        max-size: "100m"
        max-file: "3"
        compress: "true"

networks:
  frontend_network:
    driver: bridge
    ipam:
      config:
        - subnet: 172.28.10.0/24
  backend_network:
    driver: bridge
    internal: true
    ipam:
      config:
        - subnet: 172.28.20.0/24

volumes:
  postgres_data:
    driver: local

secrets:
  db_user:
    file: ./secrets/db_user.txt
  db_password:
    file: ./secrets/db_password.txt
```

---

## 3.3 Configuración del Daemon de Docker de Producción Empresarial (`/etc/docker/daemon.json`)

```json
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "storage-driver": "overlay2",
  "storage-opts": [
    "overlay2.override_kernel_check=true"
  ],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3",
    "compress": "true"
  },
  "live-restore": true,
  "userland-proxy": false,
  "no-new-privileges": true,
  "icc": false,
  "userns-remap": "default",
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 64535,
      "Soft": 64535
    },
    "nproc": {
      "Name": "nproc",
      "Hard": 4096,
      "Soft": 4096
    }
  },
  "dns": ["1.1.1.1", "8.8.8.8"]
}
```

---

## 4. Ejecuciones de CLI en el Mundo Real y Salidas de Terminal

### 4.1 Inspección de Runtime de Contenedores de Bajo Nivel (`docker inspect`)

Inspecting specific network, storage mount, and state parameters using Golang template formatting:

```bash
$ docker inspect --format='{{json .State}}' production_api | jq .
```
```json
{
  "Status": "running",
  "Running": true,
  "Paused": false,
  "Restarting": false,
  "OOMKilled": false,
  "Dead": false,
  "Pid": 348912,
  "ExitCode": 0,
  "Error": "",
  "StartedAt": "2026-08-07T04:12:01.481923102Z",
  "FinishedAt": "0001-01-01T00:00:00Z",
  "Health": {
    "Status": "healthy",
    "FailingStreak": 0,
    "Log": [
      {
        "Start": "2026-08-07T04:40:01.102931201Z",
        "End": "2026-08-07T04:40:01.142019482Z",
        "ExitCode": 0,
        "Output": "HTTP 200 OK - Database connection alive"
      }
    ]
  }
}
```

---

### 4.2 Inspección de Recursos Activos de Control Groups (`docker stats`)

Monitoring realtime cgroup CPU, memory limits, and network I/O utilization without streaming:

```bash
$ docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}\t{{.PIDs}}"
```
```text
NAME             CPU %     MEM USAGE / LIMIT     MEM %     NET I/O           BLOCK I/O         PIDS
production_api   0.14%     42.18MiB / 1GiB       4.12%     12.4MB / 8.92MB   0B / 1.24MB       8
production_postgres 0.85%  184.5MiB / 2GiB       9.01%     8.92MB / 12.4MB   45.8MB / 182MB    23
```

---

### 4.3 Auditoría del Mapeo de Namespaces de Linux en el Host (`lsns` y `/proc`)

Tracing the actual host PID for a containerized process and displaying its allocated kernel namespaces:

```bash
$ HOST_PID=$(docker inspect --format='{{.State.Pid}}' production_api)
$ echo "Container Host PID: ${HOST_PID}"
```
```text
Container Host PID: 348912
```

Inspecting namespace symlinks inside the Linux proc filesystem:

```bash
$ ls -la /proc/${HOST_PID}/ns/
```
```text
total 0
drxf-x--x 2 appuser appgroup 0 Aug  7 04:12 .
dr-xr-xr-x 9 appuser appgroup 0 Aug  7 04:12 ..
lrwxrwxrwx 1 appuser appgroup 0 Aug  7 04:15 cgroup -> 'cgroup:[4026533104]'
lrwxrwxrwx 1 appuser appgroup 0 Aug  7 04:15 ipc -> 'ipc:[4026533099]'
lrwxrwxrwx 1 appuser appgroup 0 Aug  7 04:15 mnt -> 'mnt:[4026533101]'
lrwxrwxrwx 1 appuser appgroup 0 Aug  7 04:12 net -> 'net:[4026533102]'
lrwxrwxrwx 1 appuser appgroup 0 Aug  7 04:12 pid -> 'pid:[4026533100]'
lrwxrwxrwx 1 appuser appgroup 0 Aug  7 04:15 pid_for_children -> 'pid:[4026533098]'
lrwxrwxrwx 1 appuser appgroup 0 Aug  7 04:15 time -> 'time:[4026531834]'
lrwxrwxrwx 1 appuser appgroup 0 Aug  7 04:15 time_for_children -> 'time:[4026531834]'
lrwxrwxrwx 1 appuser appgroup 0 Aug  7 04:15 user -> 'user:[4026531837]'
lrwxrwxrwx 1 appuser appgroup 0 Aug  7 04:15 uts -> 'uts:[4026533097]'
```

---

### 4.4 Diagnóstico de Bajo Nivel del OCI Container Runtime vía `ctr` CLI de `containerd`

Querying task states directly via containerd's socket API (`/run/containerd/containerd.sock`), bypassing the Docker daemon wrapper:

```bash
$ sudo ctr --namespace moby tasks list
```
```text
TASK                PID       STATUS    
348912a7f8e1...     348912    RUNNING
a9411d8c11e2...     349015    RUNNING
```

```bash
$ sudo ctr --namespace moby tasks metrics 348912a7f8e1...
```
```text
ID: 348912a7f8e1...
METRIC                   VALUE
CPU User                 148291024ns
CPU System               41902811ns
Memory Usage (bytes)     44228608
Memory Limit (bytes)     1073741824
OOM Events               0
PIDs Current             8
PIDs Limit               4096
```

---

## 5. Playbook de Verificación y Solución de Problemas para SRE

### Diagrama de Flujo de Diagnóstico

```
                     +---------------------------------------+
                     | Issue Detected: Container Failure/OOM  |
                     +---------------------------------------+
                                         |
                                         v
                     +---------------------------------------+
                     | Run: docker inspect --format '{{...}}'|
                     +---------------------------------------+
                                         |
                   +---------------------+---------------------+
                   |                                           |
                   v                                           v
      [ ExitCode 137 / OOMKilled ]               [ ExitCode 143 / Timeout ]
                   |                                           |
                   v                                           v
      +-------------------------+                 +-------------------------+
      | Check dmesg / Kern log  |                 | Check PID 1 Signal      |
      | Inspect cgroup memory   |                 | Handling / Tini         |
      +-------------------------+                 +-------------------------+
```

---

### Escenario A: Caída Silenciosa del Contenedor (Exit Code 137 / Out-Of-Memory)

#### Análisis de Causa Raíz
El Memory Resource Controller (`cgroup`) del kernel aplica los límites de memoria especificados mediante `--memory` o `deploy.resources.limits.memory`. Cuando la asignación del proceso del contenedor excede los límites estrictos, el OOM killer del Kernel de Linux selecciona y envía la señal `SIGKILL` (9) al principal infractor de memoria, provocando una terminación abrupta con código de salida `137` (`128 + 9`).

#### Ejecución Diagnóstica Paso a Paso

1. **Verificar el Estado vía `docker inspect`**:
   ```bash
   $ docker inspect production_api --format='ExitCode={{.State.ExitCode}} OOMKilled={{.State.OOMKilled}}'
   ```
   *Expected Output*:
   ```text
   ExitCode=137 OOMKilled=true
   ```

2. **Inspeccionar los Logs del Kernel Ring Buffer (`dmesg`)**:
   ```bash
   $ sudo dmesg -T --level=alert,crit,err | grep -i -E "oom|killed process"
   ```
   *Expected Output*:
   ```text
   [Fri Aug  7 04:22:19 2026] Memory cgroup out of memory: Killed process 348912 (api-server) total-vm:1894212kB, anon-rss:1048124kB, file-rss:412kB, shmem-rss:0kB, uid:10001 pgtables:2180kB oom_score_adj:0
   [Fri Aug  7 04:22:19 2026] oom_reaper: reaped process 348912 (api-server), now anon-rss:0kB, file-rss:0kB, shmem-rss:0kB
   ```

3. **Verificar la Aplicación de Limites en cgroups v2 del Kernel del Host**:
   ```bash
   $ CGROUP_PATH=$(docker inspect production_api --format='{{.CgroupParent}}')
   $ cat /sys/fs/cgroup/${CGROUP_PATH}/memory.max
   $ cat /sys/fs/cgroup/${CGROUP_PATH}/memory.events
   ```
   *Expected Output*:
   ```text
   1073741824
   low 0
   high 0
   max 14
   oom 14
   oom_kill 14
   ```

#### Plan de Remediación
*   Aumentar los límites de memoria en `docker-compose.yml` (`memory: 2048M`).
*   Analizar el perfil de las asignaciones de memoria usando `pprof` de Go o profilers de heap para detectar fugas de memoria.
*   Configurar los límites de runtime de la aplicación (ej., Node.js `--max-old-space-size=768` o Java `-Xmx768m`) para asegurar que la recolección de basura del runtime se active *antes* de alcanzar los límites de cgroup.

---

### Escenario B: Acumulación de Procesos Zombie y Fallo en Graceful Shutdown (SIGTERM Ignorado)

#### Análisis de Causa Raíz
Cuando se ejecuta `docker stop`, `dockerd` envía `SIGTERM` (señal 15) al PID 1 dentro del network/PID namespace del contenedor. Si el binario de la aplicación en el contenedor se ejecuta directamente como PID 1 sin manejadores explícitos de señales POSIX implementados, se aplican los valores por defecto del Kernel de Linux: el PID 1 **ignora las señales** a menos que exista un manejador explícito.

Después de un tiempo de espera por defecto de 10 segundos, `dockerd` emite la señal incapturable `SIGKILL` (señal 9), causando corrupción de datos o la terminación abrupta de sockets.

#### Ejecución Diagnóstica Paso a Paso

1. **Probar la Latencia de Respuesta al Detener el Contenedor**:
   ```bash
   $ time docker stop production_api
   ```
   *Expected Output*:
   ```text
   production_api

   real    0m10.412s
   user    0m0.031s
   sys     0m0.015s
   ```
   *Nota: Una duración de ejecución de exactamente ~10 segundos indica un fallo en la terminación limpia (graceful termination).*

2. **Inspeccionar el Árbol de Procesos Interno Dentro del Contenedor**:
   ```bash
   $ docker exec production_api ps aux
   ```
   *Expected Output*:
   ```text
   PID   USER     TIME  COMMAND
       1 10001     0:00 node /app/server.js
      42 10001     0:00 [sh] <defunct>
      43 10001     0:00 [curl] <defunct>
   ```
   *Nota: Las entradas defunct indican procesos zombie que permanecen sin ser recolectados por el PID 1.*

#### Plan de Remediación
Opción 1: Incluir `tini` como wrapper de inicialización init en el Dockerfile (`ENTRYPOINT ["/sbin/tini", "--"]`).

Opción 2: Habilitar el sistema init integrado mediante la CLI de docker o el manifiesto de Compose:
```bash
$ docker run --init -d --name production_api custom_image:v1.0
```
O en `docker-compose.yml`:
```yaml
services:
  api_gateway:
    init: true
```

---

### Escenario C: Agotamiento del Espacio en Disco del Host vía Capa Escribible de Contenedor no Vinculada (`upperdir`)

#### Análisis de Causa Raíz
Los procesos que se ejecutan dentro de contenedores escribiendo datos efímeros en rutas no vinculadas a volúmenes externos contaminan la capa CoW escribible (`/var/lib/docker/overlay2/<hash>/upper`). Esto conduce al agotamiento de inodes/bloques en la partición `/var` del host y a un rendimiento de E/S degradado en todos los contenedores que comparten el storage driver.

#### Ejecución Diagnóstica Paso a Paso

1. **Analizar el Uso del Espacio en Disco en Docker**:
   ```bash
   $ docker system df -v
   ```
   *Expected Output*:
   ```text
   Images space usage:
   REPOSITORY          TAG       IMAGE ID       CREATED        SIZE      SHARED SIZE
   postgres            16.2      a129d3810f92   2 weeks ago    379.2MB   0B

   Containers space usage:
   CONTAINER ID   IMAGE            COMMAND                  LOCAL VOLUMES   SIZE
   348912a7f8e1   custom_image:v1  "/sbin/tini -- /app…"   1               48.2GB (virtual 48.3GB)
   ```

2. **Identificar las Rutas de la Capa Escribible que Más Espacio en Disco Consumen**:
   ```bash
   $ docker diff 348912a7f8e1 | grep "^A" | head -n 10
   ```
   *Expected Output*:
   ```text
   A /app/logs/application-debug.log
   A /tmp/cache/buffer.tmp
   ```

3. **Inspeccionar la Configuración de Montaje vía `docker inspect`**:
   ```bash
   $ docker inspect --format='{{range .Mounts}}{{.Source}} -> {{.Destination}} (RW: {{.RW}}){{"\n"}}{{end}}' 348912a7f8e1
   ```
   *Expected Output*:
   ```text
   /var/lib/docker/volumes/postgres_data/_data -> /var/lib/postgresql/data (RW: true)
   ```
   *Nota: Las rutas de logs (`/app/logs`) y rutas temporales (`/tmp`) están ausentes de los montajes de volumen, lo que provoca que las escrituras se desborden hacia la capa OverlayFS escribible.*

#### Plan de Remediación
1. Aplicar un **Sistema de Archivos Raíz de Solo Lectura** (`read_only: true`) en manifiestos de producción.
2. Vincular explícitamente rutas de escritura efímeras a montajes `tmpfs` en RAM:
   ```yaml
   read_only: true
   tmpfs:
     - /tmp:rw,noexec,nosuid,size=64m
   ```
3. Dirigir los logs de la aplicación exclusivamente a los flujos de salida estándar (`/dev/stdout` y `/dev/stderr`) para delegar el procesamiento de logs al driver de registro con rotación del Docker Engine (`json-file` con límites de `max-size`).

---

## 6. Referencias y Documentación Oficial

*   **LPI DevOps Tools Engineer Overview & Syllabus**:
    *   [https://www.lpi.org/our-certifications/devops-tools-engineer-overview/](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
    *   [https://wiki.lpi.org/wiki/LPIC-OT_DevOps_Tools_Engineer_Objectives_V1.0](https://wiki.lpi.org/wiki/LPIC-OT_DevOps_Tools_Engineer_Objectives_V1.0)
*   **Docker Engine Reference Documentation**:
    *   [https://docs.docker.com/engine/reference/builder/](https://docs.docker.com/engine/reference/builder/)
    *   [https://docs.docker.com/engine/reference/commandline/dockerd/](https://docs.docker.com/engine/reference/commandline/dockerd/)
    *   [https://docs.docker.com/storage/storagedriver/overlayfs-driver/](https://docs.docker.com/storage/storagedriver/overlayfs-driver/)
*   **Open Container Initiative (OCI) Specifications**:
    *   [https://opencontainers.org/specifications/runtime-spec/](https://opencontainers.org/specifications/runtime-spec/)
    *   [https://github.com/opencontainers/runc](https://github.com/opencontainers/runc)
*   **Linux Kernel Manual Pages & Documentation**:
    *   `namespaces(7)`: [https://man7.org/linux/man-pages/man7/namespaces.7.html](https://man7.org/linux/man-pages/man7/namespaces.7.html)
    *   `cgroups(7)`: [https://man7.org/linux/man-pages/man7/cgroups.7.html](https://man7.org/linux/man-pages/man7/cgroups.7.html)
    *   Control Group v2 Kernel Documentation: [https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html)