# 702.1 — Gestión de contenedores de aplicación

**Examen:** LPI DevOps Tools Engineer, 701-100 (objetivos v2.0.0)
**Peso del tema:** 8.33 — uno de los objetivos individuales más pesados del examen. Esperá preguntas que van más allá de `docker run` y entran en construcción de imágenes, identidad, primitivas de aislamiento y diagnóstico de fallos.

**Alcance cubierto acá (parafraseado del conjunto oficial de objetivos):** construcción, distribución y ejecución de contenedores de aplicación; escritura de Dockerfile/Containerfile; registries de imágenes e identidad de imagen; ciclo de vida, almacenamiento, red y restricciones de recursos de los contenedores; definición de aplicaciones multi-contenedor; postura de seguridad de contenedores; y el ecosistema de herramientas alrededor de Docker, Podman, Buildah y Skopeo. La orquestación (Kubernetes, scheduling, controladores) corresponde a **702.2/702.3** y acá solo se menciona donde cambia una decisión de diseño a nivel de contenedor.

---

## 1. El problema de producción

### 1.1 Qué resuelven realmente los contenedores — y qué no

La versión ingenua ("los contenedores resuelven *funciona en mi máquina*") es cierta pero inútil para un arquitecto de plataforma. El enunciado preciso es:

> Una imagen de contenedor es un **paquete de sistema de archivos inmutable, en capas y direccionable por contenido, más un contrato de ejecución**, y un contenedor es un **árbol de procesos arrancado desde ese paquete con una vista restringida del kernel**.

Dos consecuencias gobiernan todas las decisiones de producción de este objetivo:

1. **El kernel es compartido.** No hay frontera de hipervisor. Un contenedor es un proceso Linux normal cuya visibilidad recortan los namespaces, cuyo consumo de recursos limitan los cgroups y cuyo privilegio recortan las capabilities, seccomp y los LSM (SELinux/AppArmor). Toda propiedad de aislamiento en la que confiás está a un flag mal configurado de dejar de existir.
2. **El artefacto es inmutable y direccionable.** La unidad de promoción entre entornos deja de ser "un script de despliegue que instala paquetes" y pasa a ser "un digest". `sha256:1a2b…` en staging y `sha256:1a2b…` en producción son *idénticos bit a bit*. Esta es la mayor ganancia de fiabilidad, y se descarta en silencio en el momento en que alguien despliega `:latest`.

### 1.2 Los modos de fallo arquitectónicos que introducen los contenedores

Los contenedores eliminan clases de fallo y agregan otras nuevas. Un SRE tiene que conocer las nuevas de memoria:

| Clase de fallo | Causa raíz | Síntoma en producción |
|---|---|---|
| **Semántica de PID 1** | El primer proceso del contenedor es PID 1 en su namespace de PID. PID 1 no recibe manejadores de señal por defecto y debe recolectar huérfanos. | `docker stop` tarda exactamente 10 s y luego hace SIGKILL; se acumulan procesos zombie; el drenaje ordenado nunca se ejecuta; se cortan las peticiones en vuelo. |
| **Pérdida de señales por forma shell** | `ENTRYPOINT cmd` ejecuta `/bin/sh -c "cmd"`; `sh` se vuelve PID 1 y no reenvía SIGTERM. | Igual que arriba, más código de salida 137 en lugar de un 0/143 limpio. |
| **Runtimes que ignoran los cgroups** | La JVM/Node/Go leen `/proc/cpuinfo` y `/proc/meminfo` (valores del host) salvo que sean conscientes de cgroups. | Heap dimensionado para un host de 256 GB dentro de un límite de 512 MiB → OOMKill; `GOMAXPROCS` = 96 con una cuota de 0.5 CPU → thrashing del planificador y cola de latencia. |
| **Tags mutables** | `:latest` / `:v1` reapuntados en el registry. | Dos réplicas de "la misma versión" ejecutan código distinto; el rollback restaura un tag que ya no significa lo que significaba. |
| **Herencia de CVE por capas** | Imagen base congelada en tiempo de build; nada la vuelve a traer. | Existe una base parcheada upstream; tu flota sigue enviando la vulnerable durante meses. |
| **Amplificación de escritura en el sistema de archivos de unión** | overlay2 copia el archivo completo a la capa superior en la primera escritura (copy-up). | Un contenedor que agrega texto a un archivo de log de 4 GiB heredado de la imagen consume 4 GiB del almacenamiento gráfico del host al instante. |
| **Colisión de UID en bind mounts** | El UID 1000 del contenedor ≠ la semántica del UID 1000 del host bajo user namespaces rootless. | `Permission denied` en un volumen que en el host tiene `0777`. |
| **Logs efímeros** | Logs escritos dentro de la capa de escritura del contenedor. | Los logs desaparecen con el contenedor; el disco se llena porque `json-file` no tiene rotación por defecto en Docker plano. |

### 1.3 El contrato de diseño que impone este objetivo

Todo lo que sigue se deriva de cuatro reglas:

1. **Construí una vez, promové un digest.** Los tags son etiquetas para humanos; los digests son la identidad de despliegue.
2. **La imagen de runtime contiene la aplicación y nada más.** Sin compiladores, sin gestor de paquetes, sin shell si se puede evitar. Cada binario de la imagen es superficie de ataque *y* ruido para el escáner de CVE.
3. **Ejecutá como usuario no root, con el sistema de archivos raíz de solo lectura, con todas las capabilities eliminadas, con `no-new-privileges`.** Son cuatro flags; no hay excusa para omitirlos.
4. **Cada contenedor declara su envolvente de recursos y su contrato de liveness.** Un contenedor sin `memory.max` es una caída de todo el host esperando a que haya una fuga de memoria.

---

## 2. Mecánica: qué hace realmente el kernel

### 2.1 Namespaces

Un contenedor se define por qué namespaces *no* comparte con el host.

| Namespace | Flag de `clone()` | Aísla | Efecto práctico |
|---|---|---|---|
| `mnt` | `CLONE_NEWNS` | Tabla de montajes | El contenedor ve el rootfs de la imagen, no `/`. |
| `pid` | `CLONE_NEWPID` | IDs de proceso | El entrypoint es PID 1; los procesos del host son invisibles. Requiere un montaje fresco de `/proc`. |
| `net` | `CLONE_NEWNET` | Interfaces, rutas, netfilter, sockets, `/proc/net` | `lo` propio, `eth0` propio (par veth), tablas iptables/nftables propias. |
| `ipc` | `CLONE_NEWIPC` | IPC SysV, colas de mensajes POSIX, memoria compartida | Aísla `/dev/shm` (64 MiB por defecto — un fallo clásico de Chrome/Postgres). |
| `uts` | `CLONE_NEWUTS` | Hostname, dominio NIS | `--hostname` funciona sin tocar el host. |
| `user` | `CLONE_NEWUSER` | Mapas UID/GID, conjuntos de capabilities | **La base de rootless.** El root de adentro mapea a un UID no privilegiado del host. |
| `cgroup` | `CLONE_NEWCGROUP` | Raíz de cgroup | El contenedor ve `/sys/fs/cgroup` como su propia raíz, no la jerarquía del host. |
| `time` | `CLONE_NEWTIME` | Desplazamientos de `CLOCK_MONOTONIC`/`BOOTTIME` | Usado por checkpoint/restore de CRIU; rara vez lo establecen los motores de contenedores. |

Observalos directamente:

```console
$ podman run -d --rm --name ns-demo docker.io/library/alpine:3.20 sleep 600
9f2c4b1e7a3d5c8f0e6b2a4d7c9e1f3b5a7c9e1f3b5d7f9a1c3e5b7d9f1a3c5e

$ pid=$(podman inspect -f '{{.State.Pid}}' ns-demo); echo "$pid"
48213

$ ls -l /proc/$pid/ns
total 0
lrwxrwxrwx. 1 dev dev 0 Sep  3 10:21 cgroup -> 'cgroup:[4026533112]'
lrwxrwxrwx. 1 dev dev 0 Sep  3 10:21 ipc    -> 'ipc:[4026533049]'
lrwxrwxrwx. 1 dev dev 0 Sep  3 10:21 mnt    -> 'mnt:[4026533047]'
lrwxrwxrwx. 1 dev dev 0 Sep  3 10:21 net    -> 'net:[4026533051]'
lrwxrwxrwx. 1 dev dev 0 Sep  3 10:21 pid    -> 'pid:[4026533050]'
lrwxrwxrwx. 1 dev dev 0 Sep  3 10:21 user   -> 'user:[4026531837]'
lrwxrwxrwx. 1 dev dev 0 Sep  3 10:21 uts    -> 'uts:[4026533048]'

$ readlink /proc/self/ns/net
net:[4026531840]
```

El inodo `net` difiere (`4026533051` frente al `4026531840` del host) → el contenedor tiene su propio namespace de red. El inodo `user` acá es *idéntico* al del host, porque esta fue una ejecución rootful de Podman; bajo rootless sería distinto. Esa única comparación es la forma más rápida de demostrar si el aislamiento por user namespace está realmente en efecto.

```console
$ lsns -t pid -p $pid
        NS TYPE NPROCS   PID USER COMMAND
4026533050 pid       1 48213 root sleep 600

$ sudo nsenter -t $pid -a ps -ef
PID   USER     TIME  COMMAND
    1 root      0:00 sleep 600
    7 root      0:00 ps -ef
```

### 2.2 cgroups v2 — el contrato de recursos

En un host moderno (jerarquía unificada `cgroup2fs`), los límites del contenedor son archivos comunes.

```console
$ stat -fc %T /sys/fs/cgroup
cgroup2fs

$ id=$(docker inspect -f '{{.Id}}' api)
$ cg=/sys/fs/cgroup/system.slice/docker-$id.scope

$ cat $cg/memory.max $cg/memory.high $cg/pids.max $cg/cpu.max
536870912
max
512
50000 100000
```

Lectura: techo duro de memoria de 512 MiB; sin estrangulamiento suave; máximo 512 PID; cuota de CPU de 50 000 µs por período de 100 000 µs = **0.5 CPU**.

```console
$ cat $cg/memory.events
low 0
high 0
max 1174
oom 2
oom_kill 2

$ cat $cg/cpu.stat
usage_usec 91827364
user_usec 71029844
system_usec 20797520
nr_periods 18342
nr_throttled 4471
throttled_usec 2310945000
```

`nr_throttled / nr_periods = 24 %` — en uno de cada cuatro períodos de planificación la carga de trabajo quedó detenida en su cuota. Eso es un problema de latencia, no de capacidad, y es invisible para `docker stats`. `oom_kill 2` demuestra que el kernel mató procesos dos veces; `max 1174` cuenta las veces que la asignación llegó al techo.

Podman rootless ubica los contenedores en otro lugar:

```console
$ cat /sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/user.slice/\
libpod-$(podman inspect -f '{{.Id}}' api).scope/memory.max
268435456
```

> **Advertencia sobre cgroup v1:** los límites de recursos en rootless requieren cgroups v2 + systemd. En un host v1, `podman run --memory` desde un usuario no root se ignora silenciosamente o da error. La comprobación es `podman info --format '{{.Host.CgroupsVersion}}'`.

### 2.3 Capabilities

El root dentro de un contenedor no es el root del host — es un *conjunto de capabilities*. Docker/Podman otorgan un conjunto reducido por defecto y descartan el resto.

```console
$ docker run --rm alpine:3.20 sh -c 'apk add -q libcap; capsh --print | head -3'
Current: cap_chown,cap_dac_override,cap_fowner,cap_fsetid,cap_kill,cap_setgid,
cap_setuid,cap_setpcap,cap_net_bind_service,cap_net_raw,cap_sys_chroot,
cap_mknod,cap_audit_write,cap_setfcap=ep
Bounding set: cap_chown,cap_dac_override,cap_fowner,cap_fsetid,cap_kill,...
```

La postura de producción descarta todo y vuelve a agregar únicamente lo que es demostrablemente necesario:

```console
$ docker run --rm --cap-drop=ALL --security-opt=no-new-privileges \
    alpine:3.20 sh -c 'apk add -q libcap; capsh --print | head -1'
Current: =
```

| Capability | Por qué una app podría necesitarla | Alternativa más segura |
|---|---|---|
| `NET_BIND_SERVICE` | Escuchar en un puerto < 1024 | Escuchar en 8080, publicar `-p 443:8080`; o el sysctl `net.ipv4.ip_unprivileged_port_start=80` |
| `CHOWN`, `DAC_OVERRIDE`, `FOWNER` | Entrypoint que corrige permisos de volúmenes | Corregir la propiedad en tiempo de build / usar `:U` (Podman) o un init container |
| `NET_RAW` | `ping`, sockets raw | Descartarla — habilita ARP spoofing dentro del namespace de red |
| `SYS_ADMIN` | "Docker-in-Docker", montajes, algunos profilers | Podman rootless, sysbox, o un sidecar con un perfil seccomp acotado |
| `SYS_PTRACE` | Depuradores, `py-spy`, `perf` | Adjuntar solo en un contenedor de depuración temporal |

### 2.4 La imagen en disco: overlayfs

```console
$ docker image inspect nginx:1.27-alpine \
    --format '{{json .GraphDriver}}' | jq .
{
  "Data": {
    "LowerDir": "/var/lib/docker/overlay2/8a1f.../diff:/var/lib/docker/overlay2/3b7c.../diff",
    "MergedDir": "/var/lib/docker/overlay2/f04e.../merged",
    "UpperDir": "/var/lib/docker/overlay2/f04e.../diff",
    "WorkDir": "/var/lib/docker/overlay2/f04e.../work"
  },
  "Name": "overlay2"
}
```

* `LowerDir` — las capas de solo lectura de la imagen, apiladas de derecha a izquierda (la más a la derecha es la base).
* `UpperDir` — la capa de escritura del contenedor. **Todo lo escrito en tiempo de ejecución que no sea un volumen aterriza acá.**
* `MergedDir` — la vista unificada que el proceso ve como `/`.
* Borrar un archivo de una capa inferior crea un *whiteout* (un dispositivo de caracteres `0:0`) en `UpperDir` — los bytes siguen en la imagen. Por eso `RUN rm -rf /secret` en una capa posterior del Dockerfile **no elimina el secreto de la imagen**.

```console
$ docker diff api | head
C /etc
C /etc/nginx/conf.d
A /etc/nginx/conf.d/upstream.conf
C /var/cache/nginx
A /var/cache/nginx/client_temp
C /tmp
A /tmp/heapdump-20260903.hprof
```

`A` = añadido, `C` = cambiado, `D` = borrado. Un contenedor que debería ser inmutable y muestra decenas de líneas `A` fuera de `/tmp` tiene un defecto de diseño.

### 2.5 La pila de runtime

```
docker CLI ──REST/unix socket──► dockerd ──gRPC──► containerd ──► containerd-shim-runc-v2 ──► runc ──► your process
                                                                        (shim survives daemon restart)

podman CLI ──(no daemon; fork/exec)──────────────────────────────────► conmon ──► crun|runc ──► your process

kubelet ────CRI (gRPC)────► containerd | CRI-O ──► shim ──► runc|crun ──► your process
```

* **`runc`** — la implementación de referencia del runtime OCI (Go). Aplica namespaces/cgroups/capabilities/seccomp y luego hace `execve()`.
* **`crun`** — implementación en C, arranque más rápido, menor memoria, soporte nativo de cgroup v2; el runtime por defecto de Podman en Fedora/RHEL.
* **`conmon`** — el monitor por contenedor de Podman: sostiene la PTY, escribe el log, reporta el código de salida. Es el equivalente sin daemon del shim de containerd.
* **La ausencia de daemon importa operativamente:** reiniciar `dockerd` es un evento que afecta a toda la flota; Podman no tiene un punto único de fallo así, y sus contenedores son servicios systemd corrientes cuando se gestionan con Quadlet (§8).

```console
$ podman info --format '{{.Host.OCIRuntime.Name}} {{.Host.OCIRuntime.Version}}'
crun 1.15

$ docker info --format '{{.DefaultRuntime}} / {{.CgroupDriver}} / {{.CgroupVersion}}'
runc / systemd / 2
```

---

## 3. Comparación de motores y herramientas

### 3.1 Motores de contenedores

| | **Docker Engine** | **Podman** | **containerd + nerdctl** | **CRI-O** |
|---|---|---|---|---|
| Arquitectura | Cliente → daemon (`dockerd`) → containerd | Sin daemon, fork/exec, `conmon` por contenedor | Daemon (`containerd`), la CLI es delgada | Daemon, solo para Kubernetes |
| Ejecuta como no root | Modo rootless (configuración extra, `dockerd-rootless.sh`) | **Rootless es de primera clase y el modo por defecto** | Rootless soportado | No (dirigido por kubelet) |
| Modelo de privilegio del socket | Pertenecer al grupo `docker` ≈ root en el host | No hace falta socket; servicio de API opcional | `containerd.sock` ≈ root | Socket CRI, solo kubelet |
| Integración con systemd | Los contenedores son hijos del daemon | **Quadlet** — los contenedores *son* unidades systemd | Manual | Gestionado por kubelet |
| Pods (netns compartido) | No | **Sí** (`podman pod`) | No | Sí (CRI) |
| Motor de build | BuildKit (integrado) | Buildah (integrado como `podman build`) | BuildKit (separado) | Ninguno — solo pull |
| Compose | `docker compose` (plugin v2, de primera clase) | Shim `podman compose` / `podman kube play` | `nerdctl compose` | N/A |
| Compatibilidad con la API de Docker | Nativa | `podman system service` expone una API compatible | Parcial | No |
| Mejor encaje | Portátiles de desarrollo, Swarm, ecosistemas que asumen `/var/run/docker.sock` | Hosts RHEL/Fedora, CI rootless, servicios de producción en un solo nodo, entornos aislados | Nodos de Kubernetes, huella mínima | Nodos de Kubernetes, superficie de ataque mínima |

**El argumento de seguridad, enunciado con precisión:** agregar un usuario al grupo `docker` le otorga la capacidad de ejecutar `docker run -v /:/host --privileged`, es decir, root completo en el host, sin `sudo` y sin un rastro de auditoría atribuible a una acción privilegiada. Podman rootless no tiene una vía de escalada equivalente porque el "root" del contenedor es un UID no privilegiado mapeado.

### 3.2 Herramientas de construcción

| | **`docker build` (BuildKit)** | **Buildah** | **Kaniko** | **`podman build`** |
|---|---|---|---|---|
| Requiere un daemon | Sí (o `buildx` con un contenedor builder) | No | No | No (usa Buildah) |
| Requiere privilegios | El daemon corre como root (o modo rootless) | Capaz de rootless | Corre en el clúster, casi sin privilegios | Capaz de rootless |
| Soporte de Dockerfile | Completo, canónico | Completo (`buildah bud`) | La mayoría | Completo |
| Programable sin Dockerfile | No | **Sí** (`buildah from` / `run` / `commit`) | No | No |
| Ejecución de etapas en paralelo / DAG | **Sí** | Secuencial | Secuencial | Secuencial |
| Montajes de caché, de secretos y de SSH | **Sí** | Parcial | Parcial | Parcial (`--mount` estilo BuildKit soportado para caché/secretos) |
| Multi-arquitectura en un solo comando | **Sí** (`buildx --platform`) | Vía `buildah manifest` | Trabajos por arquitectura | Vía `podman manifest` |
| Uso típico | Todo, CI incluido | Entornos aislados, ensamblado de imágenes por script, fábricas de imágenes base | CI nativo de Kubernetes donde no se permite un daemon | CI basado en Podman |

**El diferenciador de Buildah** — construir una imagen sin ningún Dockerfile, útil cuando el "build" es en realidad un paso de composición:

```console
$ ctr=$(buildah from registry.access.redhat.com/ubi9/ubi-micro:9.4)
$ mnt=$(buildah mount $ctr)
$ install -D -m 0755 ./dist/api "$mnt/usr/local/bin/api"
$ buildah umount $ctr
$ buildah config --entrypoint '["/usr/local/bin/api"]' \
    --port 8080 \
    --user 65532:65532 \
    --label org.opencontainers.image.revision="$(git rev-parse HEAD)" $ctr
$ buildah commit --format oci --squash $ctr registry.example.com/platform/api:1.8.3
Getting image source signatures
Copying blob 4f2a1c0e9b31 done
Copying config 8c1d3e5a72 done
Writing manifest to image destination
8c1d3e5a72f9b4d0e6a8c2f4b6d8e0a2c4f6b8d0e2a4c6f8b0d2e4a6c8f0b2d4
```

### 3.3 Elección de la imagen base

| Base | Tamaño (amd64, típico) | Shell | libc | Gestor de paquetes | Superficie de CVE | Depurabilidad | Usar cuando |
|---|---|---|---|---|---|---|---|
| `scratch` | 0 B | no | ninguna (solo estático) | ninguno | mínima | ninguna | Binario Go/Rust totalmente estático, endurecimiento máximo |
| `gcr.io/distroless/static-debian12` | ~2 MiB | no (la variante `:debug` trae busybox) | ninguna | ninguno | muy baja | pobre sin `:debug` | Binarios estáticos con certificados CA, tzdata, `/etc/passwd` |
| `gcr.io/distroless/base-debian12` | ~20 MiB | no | glibc | ninguno | baja | pobre | Binarios con CGO habilitado |
| `alpine:3.20` | ~7 MiB | ash | **musl** | apk | baja | buena | Imágenes pequeñas donde se verificó que musl es seguro |
| `debian:12-slim` | ~75 MiB | bash | glibc | apt | media | buena | Apps dependientes de glibc, compatibilidad amplia |
| `ubi9/ubi-micro` | ~25 MiB | no | glibc | ninguno (construir con `microdnf` desde `ubi`) | baja | pobre | Requisitos de soporte/entitlement de Red Hat |
| `ubi9/ubi-minimal` | ~100 MiB | bash | glibc | microdnf | media | buena | Ecosistema RHEL, necesita un gestor de paquetes |

**La trampa de musl.** Alpine usa musl libc. Consecuencias conocidas en producción: los binarios solo-glibc fallan con `Error loading shared library ld-linux-x86-64.so.2`; la resolución DNS históricamente difería (sin reintento de dominios de `search` ante `SERVFAIL`, sin fallback a TCP en versiones antiguas); el tamaño de pila de hilo por defecto es de 128 KiB frente a los 8 MiB de glibc, lo que hace fallar cargas con recursión profunda; los wheels de Python necesitan builds `musllinux` o compilar desde fuente. Alpine es una excelente elección *una vez verificada*, y un incidente latente cuando se adopta solo por el tamaño.

---

## 4. Construir imágenes de producción

### 4.1 `.dockerignore` — corrección, no solo velocidad

BuildKit envía el contexto de build al builder. Sin un archivo de exclusión enviás `.git` (historial completo, incluidos secretos rotados), `node_modules`, archivos `.env` locales y cachés de CI — todo lo cual además invalida la caché en cada commit.

```gitignore
# .dockerignore
*
!cmd/
!internal/
!pkg/
!go.mod
!go.sum
!requirements.txt
!worker/
```

Denegar todo y luego permitir es el único patrón que falla de forma segura: un nuevo archivo de secretos agregado al repositorio mañana queda excluido por defecto.

### 4.2 Containerfile multietapa — servicio Go sobre distroless

```dockerfile
# syntax=docker/dockerfile:1.7
# Containerfile — API service. Cross-compiled, static, distroless, non-root.

ARG GO_VERSION=1.22.5
ARG RUNTIME_IMAGE=gcr.io/distroless/static-debian12:nonroot

# ---------------------------------------------------------------- build stage
# --platform=$BUILDPLATFORM pins the toolchain to the builder's native arch and
# cross-compiles via GOOS/GOARCH. Emulating the toolchain under QEMU instead is
# roughly 10x slower for a multi-arch build.
FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-bookworm AS build

ARG TARGETOS
ARG TARGETARCH
ARG VERSION=dev
ARG REVISION=unknown

WORKDIR /src

# Dependency layer: invalidated only when go.mod/go.sum change.
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod,sharing=locked \
    go mod download -x

# Source layer.
COPY cmd/ ./cmd/
COPY internal/ ./internal/
COPY pkg/ ./pkg/

# CGO_ENABLED=0        -> static binary, runnable on scratch/distroless-static
# -trimpath            -> reproducible builds: no absolute build paths embedded
# -ldflags "-s -w"     -> strip symbol table and DWARF (~30% smaller)
# -X main.version=...  -> stamp version metadata into the binary
RUN --mount=type=cache,target=/go/pkg/mod,sharing=locked \
    --mount=type=cache,target=/root/.cache/go-build,sharing=locked \
    CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build \
      -trimpath \
      -ldflags="-s -w -X main.version=${VERSION} -X main.revision=${REVISION}" \
      -o /out/api ./cmd/api

# ----------------------------------------------------------------- test stage
# Not in the runtime path; built explicitly with --target=test in CI.
FROM build AS test
RUN --mount=type=cache,target=/go/pkg/mod,sharing=locked \
    --mount=type=cache,target=/root/.cache/go-build,sharing=locked \
    go vet ./... && go test -race -covermode=atomic -coverprofile=/out/cover.out ./...

# -------------------------------------------------------------- runtime stage
FROM ${RUNTIME_IMAGE} AS runtime

ARG VERSION=dev
ARG REVISION=unknown
ARG CREATED=1970-01-01T00:00:00Z

# OCI standard annotations: consumed by registries, scanners and policy engines.
LABEL org.opencontainers.image.title="platform-api" \
      org.opencontainers.image.description="Public HTTP API for the ordering platform" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.created="${CREATED}" \
      org.opencontainers.image.source="https://git.example.com/platform/api" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.base.name="${RUNTIME_IMAGE}"

# distroless:nonroot ships uid/gid 65532 in /etc/passwd and /etc/group.
COPY --from=build --chown=65532:65532 --chmod=0555 /out/api /usr/local/bin/api

USER 65532:65532
WORKDIR /
EXPOSE 8080 9090

ENV GOMAXPROCS=0 \
    OTEL_SERVICE_NAME=platform-api \
    API_LISTEN_ADDR=":8080" \
    API_METRICS_ADDR=":9090"

# The image has no shell and no curl, so the health probe is a subcommand of the
# application binary itself. This is the correct pattern for distroless.
HEALTHCHECK --interval=10s --timeout=2s --start-period=15s --retries=3 \
  CMD ["/usr/local/bin/api", "healthcheck", "--addr", "127.0.0.1:8080"]

# Exec form only: the binary is PID 1 and receives SIGTERM directly.
ENTRYPOINT ["/usr/local/bin/api"]
CMD ["serve"]
```

### 4.3 Containerfile multietapa — worker de Python

```dockerfile
# syntax=docker/dockerfile:1.7
# Containerfile.worker — Python worker. Wheel-only install, venv copy, non-root.

ARG PYTHON_VERSION=3.12.5

# ---------------------------------------------------------------- build stage
FROM docker.io/library/python:${PYTHON_VERSION}-slim-bookworm AS build

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_COMPILE=0 \
    PYTHONDONTWRITEBYTECODE=0

# Toolchain needed only to compile C extensions; never reaches the runtime image.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential=12.9 \
        libpq-dev=15.* \
        git

WORKDIR /src
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY requirements.txt requirements.lock ./
# --require-hashes turns the lock file into a supply-chain control: a tampered
# artifact on PyPI or a compromised mirror fails the build instead of shipping.
RUN --mount=type=cache,target=/root/.cache/pip,sharing=locked \
    pip install --require-hashes --no-deps -r requirements.lock

COPY worker/ ./worker/
RUN pip install --no-deps . && python -m compileall -q /opt/venv

# -------------------------------------------------------------- runtime stage
FROM docker.io/library/python:${PYTHON_VERSION}-slim-bookworm AS runtime

ARG VERSION=dev
ARG REVISION=unknown

LABEL org.opencontainers.image.title="platform-worker" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.source="https://git.example.com/platform/worker"

# Runtime shared libraries only — no compilers, no headers, no git.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    apt-get update && \
    apt-get install -y --no-install-recommends libpq5 tini && \
    rm -rf /var/lib/apt/lists/*

RUN groupadd --gid 10001 worker && \
    useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin worker

COPY --from=build --chown=root:root /opt/venv /opt/venv

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONFAULTHANDLER=1 \
    HOME=/tmp

USER 10001:10001
WORKDIR /opt/venv

HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --retries=3 \
  CMD ["python", "-m", "worker.healthcheck"]

# tini as PID 1: reaps zombies (Python multiprocessing/subprocess leave them)
# and forwards SIGTERM to the process group.
ENTRYPOINT ["/usr/bin/tini", "--", "python", "-m", "worker"]
CMD ["--queue", "default", "--concurrency", "4"]
```

### 4.4 `ENTRYPOINT` frente a `CMD`, forma exec frente a forma shell

| Dockerfile | Proceso realmente ejecutado | PID 1 | Recibe SIGTERM | `docker run img X` sobrescribe |
|---|---|---|---|---|
| `CMD ["nginx","-g","daemon off;"]` | `nginx` | `nginx` | sí | el comando completo |
| `CMD nginx -g "daemon off;"` | `/bin/sh -c 'nginx -g "daemon off;"'` | `sh` | **no** | el comando completo |
| `ENTRYPOINT ["nginx"]` + `CMD ["-g","daemon off;"]` | `nginx -g daemon off;` | `nginx` | sí | solo los argumentos |
| `ENTRYPOINT nginx` (forma shell) | `/bin/sh -c nginx` | `sh` | **no** | nada (`CMD` se ignora) |
| `ENTRYPOINT ["/entrypoint.sh"]` con `exec "$@"` al final | binario final | el binario | sí | argumentos |

Demostración del defecto de la forma shell:

```console
$ printf 'FROM alpine:3.20\nENTRYPOINT sleep 300\n' | docker build -q -t bad -
sha256:6c9a8e2f1b4d7a3c5e9f0b2d4a6c8e0f2b4d6a8c0e2f4b6d8a0c2e4f6b8d0a2c

$ docker run -d --name bad bad && time docker stop bad
bad
real    0m10.412s          # <-- the full grace period; SIGTERM went nowhere

$ docker inspect -f '{{.State.ExitCode}} {{.State.OOMKilled}}' bad
137 false                  # 128+9 = SIGKILL

$ printf 'FROM alpine:3.20\nENTRYPOINT ["sleep","300"]\n' | docker build -q -t good -
sha256:2f8b0d4a6c8e0f2b4d6a8c0e2f4b6d8a0c2e4f6b8d0a2c4e6f8b0d2a4c6e8f0b

$ docker run -d --name good good && time docker stop good
good
real    0m0.238s

$ docker inspect -f '{{.State.ExitCode}}' good
143                        # 128+15 = SIGTERM, handled
```

Un entrypoint envoltorio correcto, cuando es inevitable:

```bash
#!/bin/sh
# /entrypoint.sh — must exec, so the app becomes PID 1 and inherits signals.
set -eu

: "${DATABASE_URL:?DATABASE_URL is required}"

if [ -n "${DATABASE_PASSWORD_FILE:-}" ]; then
    DATABASE_PASSWORD="$(cat "$DATABASE_PASSWORD_FILE")"
    export DATABASE_PASSWORD
fi

# exec replaces the shell: no extra process, signals reach the application.
exec "$@"
```

### 4.5 Mecánica de la caché de capas

BuildKit calcula para cada instrucción una clave de caché derivada del digest de la capa padre más la instrucción. Para `COPY`/`ADD`, la clave incluye la **suma de verificación del contenido** de los archivos copiados; para `RUN`, incluye solo la **cadena del comando** — no el estado de la red ni del repositorio upstream. Dos consecuencias:

* Copiá los manifiestos de dependencias antes que el código fuente, para que una edición del fuente no invalide la instalación de dependencias.
* `RUN apt-get update` solo, en su propia capa, es un error: la capa cacheada fija un índice de paquetes de hace meses, y el `apt-get install` posterior resuelve contra él. Siempre `update && install` en un único `RUN`.

```console
$ docker buildx build --target=runtime --platform=linux/amd64 \
    --build-arg VERSION=1.8.3 \
    --build-arg REVISION="$(git rev-parse HEAD)" \
    --build-arg CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    -t registry.example.com/platform/api:1.8.3 -f Containerfile .
[+] Building 41.7s (19/19) FINISHED                              docker:default
 => [internal] load build definition from Containerfile                    0.0s
 => resolve image config for docker.io/docker/dockerfile:1.7               0.6s
 => [internal] load metadata for gcr.io/distroless/static-debian12:nonroot 0.5s
 => [internal] load metadata for docker.io/library/golang:1.22.5-bookworm  0.4s
 => [internal] load .dockerignore                                          0.0s
 => [build 1/7] FROM docker.io/library/golang:1.22.5-bookworm@sha256:3f2a… 0.0s
 => CACHED [build 2/7] WORKDIR /src                                        0.0s
 => CACHED [build 3/7] COPY go.mod go.sum ./                               0.0s
 => CACHED [build 4/7] RUN --mount=type=cache,target=/go/pkg/mod go mod …  0.0s
 => [build 5/7] COPY cmd/ ./cmd/                                           0.1s
 => [build 6/7] COPY internal/ ./internal/                                 0.1s
 => [build 7/7] RUN --mount=type=cache,target=/go/pkg/mod --mount=type=c… 37.9s
 => [runtime 1/1] COPY --from=build --chown=65532:65532 --chmod=0555 /ou…  0.2s
 => exporting to image                                                     0.3s
 => => exporting layers                                                    0.2s
 => => writing image sha256:c41d8f2a90b7e3c5d6a8f0b2c4e6a8d0f2b4c6e8a0d2f…  0.0s
 => => naming to registry.example.com/platform/api:1.8.3                   0.0s
```

Las filas 2–4 aparecen como `CACHED`; solo se volvieron a ejecutar las copias del fuente y la compilación, porque `go.mod`/`go.sum` no cambiaron. Ahí es donde el ordenamiento rinde.

```console
$ docker image ls registry.example.com/platform/api
REPOSITORY                            TAG    IMAGE ID       CREATED          SIZE
registry.example.com/platform/api     1.8.3  c41d8f2a90b7   12 seconds ago   14.2MB

$ docker history registry.example.com/platform/api:1.8.3
IMAGE          CREATED          CREATED BY                                      SIZE
c41d8f2a90b7   12 seconds ago   ENTRYPOINT ["/usr/local/bin/api"]                0B
<missing>      12 seconds ago   CMD ["serve"]                                    0B
<missing>      12 seconds ago   HEALTHCHECK &{["CMD" "/usr/local/bin/api" "he…   0B
<missing>      12 seconds ago   ENV GOMAXPROCS=0 OTEL_SERVICE_NAME=platform-a…   0B
<missing>      12 seconds ago   EXPOSE map[8080/tcp:{} 9090/tcp:{}]              0B
<missing>      12 seconds ago   USER 65532:65532                                 0B
<missing>      12 seconds ago   COPY /out/api /usr/local/bin/api # buildkit    12.1MB
<missing>      3 weeks ago      LABEL org.opencontainers.image.base.name=gcr.…   0B
<missing>      3 weeks ago      COPY /etc/passwd /etc/passwd # buildkit          1.3kB
<missing>      3 weeks ago      COPY /etc/ssl/certs /etc/ssl/certs # buildkit  2.05MB
```

14.2 MB en total, una capa de aplicación, sin shell, sin gestor de paquetes. Comparalo con el mismo binario sobre `debian:12-slim` (~87 MB) o construido en una sola etapa sobre `golang` (~1.1 GB, enviando a producción toda la cadena de herramientas de Go y el árbol de fuentes).

### 4.6 Secretos de build — la forma incorrecta y la correcta

Los valores de `ARG` y cualquier archivo escrito en una capa intermedia son recuperables desde la imagen o desde el historial de build. El único mecanismo seguro es un montaje de secretos de BuildKit, que está presente durante el `RUN` y ausente de la capa.

```dockerfile
# syntax=docker/dockerfile:1.7
RUN --mount=type=secret,id=npmrc,target=/root/.npmrc,mode=0400 \
    npm ci --omit=dev

RUN --mount=type=ssh \
    git clone git@git.example.com:platform/private-lib.git /src/lib
```

```console
$ docker buildx build --secret id=npmrc,src=$HOME/.npmrc --ssh default -t app:1.0 .
```

Verificación de que nada se filtró:

```console
$ docker history --no-trunc app:1.0 | grep -ci npmrc
0
$ docker save app:1.0 | tar -xO --wildcards '*/layer.tar' 2>/dev/null \
    | tar -tv 2>/dev/null | grep -c '\.npmrc'
0
```

---

## 5. Identidad de imagen, registries y distribución

### 5.1 Los tags son etiquetas; los digests son identidad

| Forma de referencia | Ejemplo | Mutable | Reproducible | Usar para |
|---|---|---|---|---|
| Nombre desnudo | `nginx` | sí | no | nunca |
| Tag flotante | `nginx:latest`, `api:main` | sí | no | solo desarrollo local |
| Tag semver | `api:1.8.3` | sí (se puede volver a publicar) | no | nomenclatura de releases para humanos |
| Política de tag inmutable | `api:1.8.3` en un registry con inmutabilidad de tags habilitada | no | sí | buen compromiso |
| **Digest** | `api@sha256:c41d8f…` | **no** | **sí** | manifiestos de despliegue, imágenes base en Containerfiles, políticas |
| Tag + digest | `api:1.8.3@sha256:c41d8f…` | no | sí | lo mejor: legible *y* fijado |

```console
$ docker buildx imagetools inspect registry.example.com/platform/api:1.8.3
Name:      registry.example.com/platform/api:1.8.3
MediaType: application/vnd.oci.image.index.v1+json
Digest:    sha256:9d4e2b8a1c6f3e5079b2d4a6c8e0f2b4d6a8c0e2f4b6d8a0c2e4f6b8d0a2c4e6

Manifests:
  Name:        registry.example.com/platform/api:1.8.3@sha256:c41d8f2a90b7e3c5…
  MediaType:   application/vnd.oci.image.manifest.v1+json
  Platform:    linux/amd64

  Name:        registry.example.com/platform/api:1.8.3@sha256:7b3e1a9c5d0f2b4e…
  MediaType:   application/vnd.oci.image.manifest.v1+json
  Platform:    linux/arm64

  Name:        registry.example.com/platform/api:1.8.3@sha256:e2f4b6d8a0c2e4f6…
  MediaType:   application/vnd.in-toto+json
  Platform:    unknown/unknown
  Annotations:
    vnd.docker.reference.digest: sha256:c41d8f2a90b7e3c5d6a8f0b2c4e6a8d0f2b4c6e8a…
    vnd.docker.reference.type:   attestation-manifest
```

El digest de nivel superior es un **índice de imagen** (lista de manifiestos). Hacer pull de `…:1.8.3` en arm64 resuelve automáticamente a `sha256:7b3e1a9c…`. Fijar el digest del *índice* mantiene simultáneamente el comportamiento multi-arquitectura y la inmutabilidad — este es el pin correcto para una flota heterogénea.

### 5.2 Builds multi-arquitectura

```console
$ docker buildx create --name multi --driver docker-container --bootstrap --use
[+] Building 8.4s (1/1) FINISHED
 => [internal] booting buildkit                                            8.4s
 => => pulling image moby/buildkit:buildx-stable-1                         6.9s
 => => creating container buildx_buildkit_multi0                           1.5s
multi

$ docker buildx build \
    --platform linux/amd64,linux/arm64 \
    --build-arg VERSION=1.8.3 \
    --provenance=mode=max --sbom=true \
    -t registry.example.com/platform/api:1.8.3 \
    --push -f Containerfile .
[+] Building 96.3s (34/34) FINISHED                              docker-container:multi
 => [linux/amd64 build 7/7] RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go…  38.2s
 => [linux/arm64 build 7/7] RUN CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go…  41.7s
 => exporting to image                                                      6.1s
 => => exporting manifest list sha256:9d4e2b8a1c6f3e5079b2d4a6c8e0f2b4d6a…  0.0s
 => => pushing layers                                                       5.2s
 => => pushing manifest for registry.example.com/platform/api:1.8.3@sha25…  0.7s
```

Equivalente en Podman/Buildah usando una lista de manifiestos explícita:

```console
$ podman manifest create registry.example.com/platform/api:1.8.3
$ podman build --platform linux/amd64,linux/arm64 \
    --manifest registry.example.com/platform/api:1.8.3 -f Containerfile .
$ podman manifest push --all \
    registry.example.com/platform/api:1.8.3 \
    docker://registry.example.com/platform/api:1.8.3
```

### 5.3 Skopeo — operaciones de registry sin daemon y sin pull local

Skopeo es la herramienta correcta para promoción, replicación e inspección porque copia blobs de registry a registry sin desempaquetarlos localmente.

```console
$ skopeo inspect docker://registry.example.com/platform/api:1.8.3 | jq '{Digest,Architecture,Labels,Layers}'
{
  "Digest": "sha256:c41d8f2a90b7e3c5d6a8f0b2c4e6a8d0f2b4c6e8a0d2f4b6c8e0a2d4f6b8c0e2",
  "Architecture": "amd64",
  "Labels": {
    "org.opencontainers.image.revision": "4c9e1f7b2a8d3e5c0f6b1a4d7c9e2f5b8a0c3e6d",
    "org.opencontainers.image.source": "https://git.example.com/platform/api",
    "org.opencontainers.image.version": "1.8.3"
  },
  "Layers": [
    "sha256:1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f",
    "sha256:2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a"
  ]
}

# Promotion staging -> production, digest-preserving, no local storage:
$ skopeo copy --all \
    docker://registry.example.com/staging/api:1.8.3 \
    docker://registry.example.com/prod/api:1.8.3
Getting image list signatures
Copying 2 images generated from 2 images in list
Copying image sha256:c41d8f2a90b7… (1/2)
Copying blob 1e2f3a4b5c6d skipped: already exists
Copying blob 2f3a4b5c6d7e done   |  12.1MiB / 12.1MiB
Writing manifest to image destination
Copying image sha256:7b3e1a9c5d0f… (2/2)
Writing manifest list to image destination
Storing list signatures

# Air-gap export/import through a directory or an OCI layout:
$ skopeo copy docker://registry.example.com/prod/api:1.8.3 \
    oci-archive:/transfer/api-1.8.3.oci.tar:api:1.8.3
$ skopeo copy oci-archive:/transfer/api-1.8.3.oci.tar:api:1.8.3 \
    docker://airgap-registry.internal:5000/platform/api:1.8.3
```

### 5.4 Autenticación contra registries

| Motor | Archivo de credenciales | Notas |
|---|---|---|
| Docker | `~/.docker/config.json` | `auths.<registry>.auth` es **base64, no cifrado**. Usá `credsStore`/`credHelpers`. |
| Podman/Buildah/Skopeo | `${XDG_RUNTIME_DIR}/containers/auth.json` | Alcance de sesión por defecto; `--authfile` lo sobrescribe. `podman login --compat-auth-file` escribe el formato de Docker. |

```console
$ podman login registry.example.com
Username: ci-bot
Password:
Login Succeeded!

$ cat $XDG_RUNTIME_DIR/containers/auth.json
{
	"auths": {
		"registry.example.com": {
			"auth": "Y2ktYm90OnMzY3IzdC10b2tlbg=="
		}
	}
}

$ echo Y2ktYm90OnMzY3IzdC10b2tlbg== | base64 -d
ci-bot:s3cr3t-token
```

Ese último comando es todo el argumento a favor de los helpers de credenciales y los tokens de vida corta.

### 5.5 Cadena de suministro: escanear, SBOM, firmar, verificar

```console
$ trivy image --severity HIGH,CRITICAL --ignore-unfixed \
    registry.example.com/platform/api:1.8.3
2026-09-03T10:44:11Z  INFO  Vulnerability scanning is enabled
2026-09-03T10:44:13Z  INFO  Detected OS: debian  (distroless)
2026-09-03T10:44:13Z  INFO  Number of language-specific files: 1

registry.example.com/platform/api:1.8.3 (debian 12.6)
====================================================
Total: 0 (HIGH: 0, CRITICAL: 0)

usr/local/bin/api (gobinary)
============================
Total: 1 (HIGH: 1, CRITICAL: 0)

┌──────────────────┬────────────────┬──────────┬────────┬───────────────────┬───────────────┐
│     Library      │ Vulnerability  │ Severity │ Status │ Installed Version │ Fixed Version │
├──────────────────┼────────────────┼──────────┼────────┼───────────────────┼───────────────┤
│ golang.org/x/net │ CVE-2024-45338 │ HIGH     │ fixed  │ v0.29.0           │ 0.33.0        │
└──────────────────┴────────────────┴──────────┴────────┴───────────────────┴───────────────┘

$ syft registry.example.com/platform/api:1.8.3 -o spdx-json > api-1.8.3.sbom.spdx.json

$ cosign sign --yes registry.example.com/platform/api@sha256:9d4e2b8a1c6f3e50…
$ cosign attest --yes --predicate api-1.8.3.sbom.spdx.json --type spdxjson \
    registry.example.com/platform/api@sha256:9d4e2b8a1c6f3e50…

$ cosign verify \
    --certificate-identity-regexp '^https://git\.example\.com/platform/.+$' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    registry.example.com/platform/api@sha256:9d4e2b8a1c6f3e50… | jq -r '.[0].critical.image'
{
  "docker-manifest-digest": "sha256:9d4e2b8a1c6f3e5079b2d4a6c8e0f2b4d6a8c0e2f4b6d8a0c2e4f6b8d0a2c4e6"
}
```

Podman puede aplicar políticas de firma en el momento del pull mediante `/etc/containers/policy.json`:

```json
{
    "default": [{ "type": "reject" }],
    "transports": {
        "docker": {
            "registry.example.com/platform": [
                {
                    "type": "sigstoreSigned",
                    "keyPath": "/etc/pki/containers/platform-release.pub",
                    "signedIdentity": { "type": "matchRepository" }
                }
            ],
            "docker.io/library": [{ "type": "insecureAcceptAnything" }]
        }
    }
}
```

```console
$ podman pull registry.example.com/platform/api:1.8.3
Trying to pull registry.example.com/platform/api:1.8.3...
Error: Source image rejected: A signature was required, but no signature exists
```

---

## 6. Configuración en tiempo de ejecución

### 6.1 Almacenamiento: los tres tipos de montaje

| Tipo | Flag | Ciclo de vida | Ruta en el host | Rendimiento | Uso correcto |
|---|---|---|---|---|---|
| **Volumen con nombre** | `-v appdata:/var/lib/app` | Independiente del contenedor | Gestionada por el motor (`/var/lib/docker/volumes/…`) | FS nativo | Bases de datos, cualquier estado que deba sobrevivir a `rm` |
| **Bind mount** | `-v /srv/conf:/etc/app:ro` | Propiedad del host | Explícita | FS nativo | Inyección de configuración, montajes de fuente en desarrollo, directorios de logs del host |
| **tmpfs** | `--tmpfs /tmp:rw,noexec,nosuid,size=64m` | Muere con el contenedor, nunca toca disco | RAM | RAM | Espacio temporal, secretos descifrados, archivos PID bajo un rootfs de solo lectura |
| Capa de escritura (por defecto) | — | Muere con el contenedor | overlay2 upper | **penalización por copy-up** | Nada que se escriba con frecuencia |

```console
$ docker volume create --driver local \
    --opt type=none --opt device=/srv/pgdata --opt o=bind pgdata
pgdata

$ docker volume inspect pgdata
[
    {
        "CreatedAt": "2026-09-03T10:51:07Z",
        "Driver": "local",
        "Labels": null,
        "Mountpoint": "/var/lib/docker/volumes/pgdata/_data",
        "Name": "pgdata",
        "Options": { "device": "/srv/pgdata", "o": "bind", "type": "none" },
        "Scope": "local"
    }
]
```

**SELinux (RHEL/Fedora):** un bind mount sin etiqueta produce `Permission denied` incluso como root, y `ls -Z` muestra por qué.

```console
$ podman run --rm -v /srv/conf:/etc/app:ro registry.example.com/platform/api:1.8.3
Error: open /etc/app/api.yaml: permission denied

$ ls -Z /srv/conf/api.yaml
unconfined_u:object_r:var_t:s0 /srv/conf/api.yaml

$ podman run --rm -v /srv/conf:/etc/app:ro,Z registry.example.com/platform/api:1.8.3 healthcheck
ok

$ ls -Z /srv/conf/api.yaml
system_u:object_r:container_file_t:s0:c142,c799 /srv/conf/api.yaml
```

`:z` = etiqueta compartida (varios contenedores pueden leer); `:Z` = etiqueta privada (exclusiva, con categorías MCS). **Nunca apliques `:Z` a `/home`, `/usr` o `/etc`** — reetiqueta el árbol del host de forma recursiva y rompe el sistema.

Sufijos de montaje exclusivos de Podman que conviene conocer: `:U` hace chown del volumen al UID mapeado del contenedor (resuelve los permisos de volúmenes en rootless); `:idmap` aplica un montaje con mapeo de IDs en lugar de copiar la propiedad.

### 6.2 Red

| Driver | Alcance | Dirección IP | DNS contenedor a contenedor | Usar cuando |
|---|---|---|---|---|
| `bridge` (por defecto) | Un solo host | Subred NAT privada | **Solo en redes definidas por el usuario**, no en `bridge` | Aplicaciones multi-contenedor estándar |
| `host` | Un solo host | Pila del host, sin netns | N/A | Tasas de paquetes extremas; pierde el aislamiento de puertos |
| `none` | Un solo host | Solo `lo` | N/A | Trabajos por lotes sin necesidad de red |
| `macvlan` | Un solo host | Directamente en la LAN, MAC propia | DNS externo | Aplicaciones heredadas que requieren presencia en L2; necesita modo promiscuo |
| `ipvlan` (L2/L3) | Un solo host | IP de la LAN, comparte la MAC del host | DNS externo | Igual que macvlan cuando el switch bloquea MAC adicionales |
| `overlay` | Multi-host (Swarm) | Malla VXLAN | Sí | Servicios de Swarm |

La red `bridge` por defecto deliberadamente **no tiene servidor DNS embebido**. La resolución de nombres de contenedor requiere una red definida por el usuario:

```console
$ docker run -d --name db --network bridge postgres:16-alpine
$ docker run --rm --network bridge alpine:3.20 getent hosts db
$ echo $?
2                                        # <-- no resolution on the default bridge

$ docker network create --driver bridge \
    --subnet 10.89.7.0/24 --gateway 10.89.7.1 \
    --opt com.docker.network.bridge.name=br-platform platform-backend
6f2a9c1e4b8d0f3a5c7e9b1d3f5a7c9e1b3d5f7a9c1e3b5d7f9a1c3e5b7d9f1a

$ docker network connect platform-backend db
$ docker run --rm --network platform-backend alpine:3.20 getent hosts db
10.89.7.2         db

$ docker network inspect platform-backend --format '{{json .Containers}}' | jq
{
  "a1b2c3d4e5f6…": {
    "Name": "db",
    "EndpointID": "9f8e7d6c5b4a…",
    "MacAddress": "02:42:0a:59:07:02",
    "IPv4Address": "10.89.7.2/24",
    "IPv6Address": ""
  }
}
```

Podman usa **netavark** (driver de red/firewall) más **aardvark-dns** (resolución de nombres) desde la versión 4.0:

```console
$ podman info --format '{{.Host.NetworkBackend}}'
netavark

$ podman network create --subnet 10.90.1.0/24 platform-backend
platform-backend

$ podman network inspect platform-backend | jq '.[0] | {name,driver,subnets,dns_enabled}'
{
  "name": "platform-backend",
  "driver": "bridge",
  "subnets": [{ "subnet": "10.90.1.0/24", "gateway": "10.90.1.1" }],
  "dns_enabled": true
}
```

**Publicación de puertos** — `-p [host_ip:]host_port:container_port[/proto]`. Enlazar a `0.0.0.0` (el valor por defecto) expone el servicio en todas las interfaces del host y, en Docker, **evita `firewalld`/`ufw`** porque Docker inserta sus reglas en la cadena `DOCKER` por delante de las reglas de filtrado que los usuarios suelen editar. Enlazá explícitamente:

```console
$ docker run -d -p 127.0.0.1:9090:9090 --name metrics registry.example.com/platform/api:1.8.3
$ ss -lntp | grep 9090
LISTEN 0  4096   127.0.0.1:9090   0.0.0.0:*   users:(("docker-proxy",pid=51204,fd=4))
```

Enlace de puertos por debajo de 1024 en rootless:

```console
$ podman run -d -p 443:8443 registry.example.com/platform/api:1.8.3
Error: rootlessport cannot expose privileged port 443, you can add
'net.ipv4.ip_unprivileged_port_start=443' to /etc/sysctl.conf ...

$ sudo sysctl -w net.ipv4.ip_unprivileged_port_start=443
net.ipv4.ip_unprivileged_port_start = 443
```

### 6.3 Límites de recursos

| Flag | Archivo de cgroup v2 | Significado | Modo de fallo si no se define |
|---|---|---|---|
| `--memory 512m` | `memory.max` | Techo duro; superarlo dispara un OOM kill dentro del contenedor | Un contenedor con fuga provoca OOM en el host |
| `--memory-reservation 384m` | `memory.high` | Límite blando; el kernel estrangula la recuperación por encima de él | Sin contrapresión antes del kill duro |
| `--memory-swap 512m` | `memory.swap.max` | Memoria+swap total. Igual a `--memory` ⇒ swap deshabilitado | Precipicio de latencia por swapping |
| `--cpus 1.5` | `cpu.max` = `150000 100000` | Cuota CFS por período de 100 ms | Un vecino ruidoso satura los núcleos |
| `--cpu-shares 512` | `cpu.weight` | Peso relativo **solo bajo contención** | — |
| `--cpuset-cpus 4-7` | `cpuset.cpus` | Fijar a núcleos concretos | Latencia por cruce de NUMA en cargas fijadas |
| `--pids-limit 256` | `pids.max` | Máximo de procesos/hilos | Una fork bomb agota el espacio de PID del host |
| `--ulimit nofile=65535:65535` | (rlimit, no cgroup) | Descriptores de archivo abiertos | `too many open files` con concurrencia moderada |
| `--blkio-weight 500` | `io.weight` | Peso relativo de E/S de bloque | Inanición de E/S |
| `--shm-size 256m` | (tamaño de tmpfs) | Tamaño de `/dev/shm`, por defecto **64 MiB** | `Bus error` en Postgres/Chromium/PyTorch |

```console
$ docker run -d --name api \
    --memory 512m --memory-swap 512m --memory-reservation 384m \
    --cpus 1.5 --pids-limit 256 --shm-size 128m \
    --ulimit nofile=65535:65535 \
    registry.example.com/platform/api:1.8.3

$ docker stats --no-stream api
CONTAINER ID   NAME   CPU %    MEM USAGE / LIMIT     MEM %    NET I/O          BLOCK I/O    PIDS
d7f3a91c4e28   api    43.17%   211.4MiB / 512MiB     41.29%   38.4MB / 12.1MB  0B / 4.1kB   14
```

**Hacer que el runtime sea consciente de los cgroups** es un paso distinto de fijar el límite:

| Runtime | Síntoma | Solución |
|---|---|---|
| Go | `GOMAXPROCS` = cantidad de núcleos del host → estrangulamiento CFS | `GOMAXPROCS` a partir de la cuota (`automaxprocs`), o establecerlo explícitamente |
| JVM (11+) | Heap = ¼ de la RAM del host, ignorando el límite solo en JVM antiguas | `-XX:MaxRAMPercentage=70` (el soporte de contenedores está activo por defecto en 11+) |
| Node.js | Valor por defecto del old-space derivado de la RAM del host | `--max-old-space-size=<0.75 × límite en MiB>` |
| Python | Pools de hilos dimensionados a partir de `os.cpu_count()` (valor del host) | `len(os.sched_getaffinity(0))` o una variable de entorno explícita |

### 6.4 Políticas de reinicio y registro de logs

| Política | Reinicia ante salida no cero | Reinicia ante `docker stop` | Reinicia al arrancar el daemon/host | Uso |
|---|---|---|---|---|
| `no` (por defecto) | no | no | no | Trabajos por lotes, pasos de CI |
| `on-failure[:5]` | sí, hasta N, con backoff exponencial | no | sí, si estaba en ejecución | Trabajos que pueden fallar transitoriamente |
| `always` | sí | no (pero reinicia al reiniciar el daemon) | **sí, incluso si lo detuviste** | Rara vez es lo correcto |
| `unless-stopped` | sí | no | sí, salvo que se haya detenido manualmente | **Elección por defecto para servicios** |

| Driver de log | A dónde va | Rotación | `docker logs` funciona | Notas |
|---|---|---|---|---|
| `json-file` | `/var/lib/docker/containers/<id>/<id>-json.log` | **solo si se configura** | sí | Por defecto; sin rotar llena el disco |
| `local` | Binario, comprimido | sí, por defecto | sí | Mejor valor por defecto que `json-file` |
| `journald` | Journal de systemd | Las reglas de journald | sí | Amigable con Podman, integrado con el host |
| `syslog` / `fluentd` / `gelf` | Colector remoto | remota | **no** | El modo bloqueante puede detener el contenedor |
| `none` | descartado | — | no | Solo cuando la app envía sus propios logs |

Configurá la rotación globalmente — esta única omisión es una causa recurrente de discos llenos:

```json
// /etc/docker/daemon.json
{
  "log-driver": "local",
  "log-opts": { "max-size": "50m", "max-file": "5", "compress": "true" },
  "default-ulimits": {
    "nofile": { "Name": "nofile", "Hard": 65535, "Soft": 65535 }
  },
  "live-restore": true,
  "userland-proxy": false,
  "no-new-privileges": true,
  "icc": false
}
```

```console
$ sudo systemctl reload docker
$ docker info --format '{{.LoggingDriver}} / live-restore={{.LiveRestoreEnabled}}'
local / live-restore=true
```

`live-restore: true` mantiene los contenedores en ejecución durante un reinicio de `dockerd` — obligatorio en cualquier host que ejecute cargas de producción bajo Docker.

### 6.5 Referencia: un `run` completamente endurecido

```console
$ docker run -d \
    --name api \
    --restart unless-stopped \
    --user 65532:65532 \
    --read-only \
    --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --security-opt seccomp=/etc/docker/seccomp/api.json \
    --memory 512m --memory-swap 512m --cpus 1.5 --pids-limit 256 \
    --network platform-backend \
    --publish 127.0.0.1:8080:8080 \
    --health-cmd '/usr/local/bin/api healthcheck --addr 127.0.0.1:8080' \
    --health-interval 10s --health-timeout 2s --health-retries 3 \
    --env-file /etc/platform/api.env \
    --mount type=bind,source=/etc/platform/api.yaml,target=/etc/api/api.yaml,readonly \
    --label com.example.team=platform \
    registry.example.com/platform/api@sha256:9d4e2b8a1c6f3e5079b2d4a6c8e0f2b4d6a8c0e2f4b6d8a0c2e4f6b8d0a2c4e6
d7f3a91c4e28b5f7a9c1e3b5d7f9a1c3e5b7d9f1a3c5e7b9d1f3a5c7e9b1d3f5a
```

---

## 7. Aplicaciones multi-contenedor

### 7.1 Especificación Compose — archivo de producción completo

```yaml
# compose.yaml — four-service application, hardened, with explicit dependency
# ordering, resource envelopes, split networks and file-based secrets.
# Compose Specification (https://compose-spec.io); run with `docker compose`.

name: platform

x-logging: &default-logging
  driver: local
  options:
    max-size: "50m"
    max-file: "5"

x-hardening: &hardening
  security_opt:
    - no-new-privileges:true
  cap_drop:
    - ALL
  restart: unless-stopped
  logging: *default-logging

services:

  api:
    <<: *hardening
    image: registry.example.com/platform/api:1.8.3@sha256:9d4e2b8a1c6f3e5079b2d4a6c8e0f2b4d6a8c0e2f4b6d8a0c2e4f6b8d0a2c4e6
    container_name: platform-api
    user: "65532:65532"
    read_only: true
    tmpfs:
      - /tmp:rw,noexec,nosuid,nodev,size=64m
    cap_add:
      - NET_BIND_SERVICE          # only because it also serves :80 internally
    environment:
      API_LISTEN_ADDR: ":8080"
      API_METRICS_ADDR: ":9090"
      DATABASE_HOST: db
      DATABASE_PORT: "5432"
      DATABASE_NAME: platform
      DATABASE_USER: platform
      DATABASE_PASSWORD_FILE: /run/secrets/db_password
      DATABASE_SSLMODE: require
      REDIS_URL: redis://cache:6379/0
      LOG_LEVEL: ${LOG_LEVEL:-info}
      OTEL_EXPORTER_OTLP_ENDPOINT: http://otel-collector:4317
    secrets:
      - db_password
    configs:
      - source: api_config
        target: /etc/api/api.yaml
        mode: 0444
    ports:
      - target: 8080
        published: "127.0.0.1:8080"
        protocol: tcp
        mode: host
    networks:
      - frontend
      - backend
    depends_on:
      db:
        condition: service_healthy
        restart: true
      cache:
        condition: service_started
    healthcheck:
      test: ["CMD", "/usr/local/bin/api", "healthcheck", "--addr", "127.0.0.1:8080"]
      interval: 10s
      timeout: 2s
      retries: 3
      start_period: 15s
      start_interval: 2s
    stop_grace_period: 30s
    stop_signal: SIGTERM
    deploy:
      replicas: 1
      resources:
        limits:
          cpus: "1.5"
          memory: 512M
          pids: 256
        reservations:
          cpus: "0.25"
          memory: 256M
    ulimits:
      nofile:
        soft: 65535
        hard: 65535

  worker:
    <<: *hardening
    image: registry.example.com/platform/worker:1.8.3@sha256:5a7c9e1b3d5f7a9c1e3b5d7f9a1c3e5b7d9f1a3c5e7b9d1f3a5c7e9b1d3f5a7c
    container_name: platform-worker
    user: "10001:10001"
    read_only: true
    tmpfs:
      - /tmp:rw,noexec,nosuid,nodev,size=256m
    command: ["--queue", "default", "--concurrency", "8"]
    environment:
      DATABASE_HOST: db
      DATABASE_NAME: platform
      DATABASE_USER: platform
      DATABASE_PASSWORD_FILE: /run/secrets/db_password
      REDIS_URL: redis://cache:6379/0
      PYTHONFAULTHANDLER: "1"
    secrets:
      - db_password
    networks:
      - backend
    depends_on:
      db:
        condition: service_healthy
      cache:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "python", "-m", "worker.healthcheck"]
      interval: 15s
      timeout: 3s
      retries: 3
      start_period: 20s
    stop_grace_period: 60s          # drain in-flight jobs before SIGKILL
    deploy:
      replicas: 2
      resources:
        limits:
          cpus: "2.0"
          memory: 1G
        reservations:
          memory: 512M

  db:
    <<: *hardening
    image: docker.io/library/postgres:16.4-alpine@sha256:0b1c3e5a7d9f1b3d5f7a9c1e3b5d7f9a1c3e5b7d9f1a3c5e7b9d1f3a5c7e9b1d
    container_name: platform-db
    user: "70:70"                   # postgres uid/gid in the alpine image
    cap_add:
      - CHOWN
      - DAC_READ_SEARCH
      - FOWNER
      - SETGID
      - SETUID
    environment:
      POSTGRES_DB: platform
      POSTGRES_USER: platform
      POSTGRES_PASSWORD_FILE: /run/secrets/db_password
      POSTGRES_INITDB_ARGS: "--data-checksums"
      PGDATA: /var/lib/postgresql/data/pgdata
    secrets:
      - db_password
    volumes:
      - type: volume
        source: pgdata
        target: /var/lib/postgresql/data
      - type: bind
        source: ./ops/postgres/postgresql.conf
        target: /etc/postgresql/postgresql.conf
        read_only: true
    command:
      - postgres
      - -c
      - config_file=/etc/postgresql/postgresql.conf
    networks:
      - backend
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U platform -d platform -h 127.0.0.1"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
    shm_size: 256mb                 # Postgres parallel query needs > 64MiB
    stop_grace_period: 120s         # allow a clean shutdown checkpoint
    deploy:
      resources:
        limits:
          cpus: "2.0"
          memory: 2G
        reservations:
          memory: 1G

  cache:
    <<: *hardening
    image: docker.io/library/redis:7.4-alpine@sha256:3e5b7d9f1a3c5e7b9d1f3a5c7e9b1d3f5a7c9e1b3d5f7a9c1e3b5d7f9a1c3e5b
    container_name: platform-cache
    user: "999:1000"
    read_only: true
    command:
      - redis-server
      - --save
      - ""
      - --appendonly
      - "no"
      - --maxmemory
      - 192mb
      - --maxmemory-policy
      - allkeys-lru
    networks:
      - backend
    healthcheck:
      test: ["CMD", "redis-cli", "-h", "127.0.0.1", "ping"]
      interval: 10s
      timeout: 2s
      retries: 3
      start_period: 5s
    deploy:
      resources:
        limits:
          cpus: "0.5"
          memory: 256M

networks:
  frontend:
    driver: bridge
    ipam:
      config:
        - subnet: 10.89.10.0/24
  backend:
    driver: bridge
    internal: true               # no route to the outside world
    ipam:
      config:
        - subnet: 10.89.11.0/24

volumes:
  pgdata:
    driver: local

secrets:
  db_password:
    file: ./secrets/db_password.txt   # mounted read-only at /run/secrets/db_password

configs:
  api_config:
    file: ./ops/api/api.yaml
```

Puntos de diseño que importan y que con frecuencia se hacen mal:

* **`backend` es `internal: true`.** La base de datos y el worker no tienen ruta por defecto fuera del host. Solo `api` está en ambas redes. Esto es segmentación de red expresada en diez caracteres.
* **`depends_on: condition: service_healthy`** espera a que el health check pase, no simplemente a que el contenedor arranque. Un `depends_on: [db]` a secas solo ordena la *creación*, y es la razón por la que tantas pilas necesitan bucles de reintento.
* **Los secretos son archivos, no variables de entorno.** `docker inspect` imprime las variables de entorno; `/proc/<pid>/environ` las filtra a cualquier cosa que pueda leerlo; terminan en volcados de fallo y en líneas de log. `/run/secrets/<name>` es un archivo en tmpfs, modo 0444, legible solo dentro del contenedor.
* **`stop_grace_period` difiere por servicio.** 30 s para la API (drenaje de conexiones), 60 s para el worker (finalización de trabajos), 120 s para Postgres (checkpoint final). El valor por defecto de 10 s trunca los tres.
* **Las imágenes están fijadas por digest.** El tag se mantiene por legibilidad.

Operarla:

```console
$ docker compose config --quiet && echo "valid"
valid

$ docker compose up -d --wait --wait-timeout 180
[+] Running 8/8
 ✔ Network platform_backend        Created                                  0.1s
 ✔ Network platform_frontend       Created                                  0.1s
 ✔ Volume  platform_pgdata         Created                                  0.0s
 ✔ Container platform-cache        Healthy                                  6.3s
 ✔ Container platform-db           Healthy                                 31.8s
 ✔ Container platform-api          Healthy                                 48.4s
 ✔ Container platform-worker-1     Healthy                                 69.2s
 ✔ Container platform-worker-2     Healthy                                 69.4s

$ docker compose ps --format table
NAME                IMAGE                                    STATUS                   PORTS
platform-api        registry.example.com/platform/api:1.8.3  Up 2 minutes (healthy)   127.0.0.1:8080->8080/tcp
platform-cache      redis:7.4-alpine                         Up 2 minutes (healthy)
platform-db         postgres:16.4-alpine                     Up 2 minutes (healthy)   5432/tcp
platform-worker-1   registry.example.com/platform/worker:…   Up 1 minute (healthy)
platform-worker-2   registry.example.com/platform/worker:…   Up 1 minute (healthy)

$ docker compose logs --since 2m --tail 5 api
platform-api  | {"ts":"2026-09-03T11:02:41Z","level":"info","msg":"listening","addr":":8080"}
platform-api  | {"ts":"2026-09-03T11:02:41Z","level":"info","msg":"db pool ready","conns":10}
platform-api  | {"ts":"2026-09-03T11:02:41Z","level":"info","msg":"redis ready","addr":"cache:6379"}

$ docker compose down --volumes --remove-orphans      # destroys pgdata — deliberate
```

### 7.2 Equivalentes en Podman

Podman ofrece dos caminos más allá del shim de compose. El modelo de pod comparte un namespace de red, exactamente como un Pod de Kubernetes:

```console
$ podman pod create --name platform \
    --network platform-backend \
    --publish 127.0.0.1:8080:8080 \
    --share net,ipc,uts
c9e1f3b5d7f9a1c3e5b7d9f1a3c5e7b9d1f3a5c7e9b1d3f5a7c9e1b3d5f7a9c1

$ podman run -d --pod platform --name db \
    -e POSTGRES_DB=platform -e POSTGRES_USER=platform \
    --secret db_password,type=mount,target=/run/secrets/db_password \
    -e POSTGRES_PASSWORD_FILE=/run/secrets/db_password \
    -v pgdata:/var/lib/postgresql/data \
    docker.io/library/postgres:16.4-alpine

$ podman run -d --pod platform --name api \
    registry.example.com/platform/api:1.8.3

$ podman pod ps
POD ID        NAME      STATUS   CREATED         INFRA ID      # OF CONTAINERS
c9e1f3b5d7f9  platform  Running  2 minutes ago   4a6c8e0f2b4d  3

# Inside the pod, services reach each other on localhost — shared netns.
$ podman exec api /usr/local/bin/api healthcheck --addr 127.0.0.1:8080
ok
```

Y el camino del YAML de Kubernetes, que hace que la definición para un solo host y la del clúster sean el mismo artefacto:

```console
$ podman kube generate platform > platform-pod.yaml
$ podman kube play platform-pod.yaml
Pod:
c9e1f3b5d7f9a1c3e5b7d9f1a3c5e7b9d1f3a5c7e9b1d3f5a7c9e1b3d5f7a9c1
Containers:
  1a3c5e7b9d1f3a5c7e9b1d3f5a7c9e1b3d5f7a9c1e3b5d7f9a1c3e5b7d9f1a3c
  7e9b1d3f5a7c9e1b3d5f7a9c1e3b5d7f9a1c3e5b7d9f1a3c5e7b9d1f3a5c7e9b
```

```yaml
# platform-pod.yaml — trimmed to the parts you must be able to read/write.
# Note: `podman kube play` supports a subset of the Kubernetes Pod schema;
# the same file applies with `kubectl apply -f` in a cluster.
apiVersion: v1
kind: Pod
metadata:
  name: platform
  labels:
    app: platform
spec:
  restartPolicy: OnFailure
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  volumes:
    - name: pgdata
      persistentVolumeClaim:
        claimName: pgdata
    - name: tmp
      emptyDir:
        medium: Memory
        sizeLimit: 64Mi
  containers:
    - name: api
      image: registry.example.com/platform/api:1.8.3
      imagePullPolicy: IfNotPresent
      args: ["serve"]
      ports:
        - containerPort: 8080
          hostPort: 8080
          protocol: TCP
      env:
        - name: DATABASE_HOST
          value: 127.0.0.1
        - name: DATABASE_PASSWORD_FILE
          value: /run/secrets/db_password
      volumeMounts:
        - name: tmp
          mountPath: /tmp
      securityContext:
        runAsUser: 65532
        runAsGroup: 65532
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        limits:
          cpu: "1500m"
          memory: 512Mi
        requests:
          cpu: "250m"
          memory: 256Mi
      livenessProbe:
        exec:
          command: ["/usr/local/bin/api", "healthcheck", "--addr", "127.0.0.1:8080"]
        initialDelaySeconds: 15
        periodSeconds: 10
        timeoutSeconds: 2
        failureThreshold: 3
    - name: db
      image: docker.io/library/postgres:16.4-alpine
      env:
        - name: POSTGRES_DB
          value: platform
        - name: POSTGRES_USER
          value: platform
        - name: PGDATA
          value: /var/lib/postgresql/data/pgdata
      volumeMounts:
        - name: pgdata
          mountPath: /var/lib/postgresql/data
      securityContext:
        runAsUser: 70
        runAsGroup: 70
        allowPrivilegeEscalation: false
      resources:
        limits:
          cpu: "2"
          memory: 2Gi
      readinessProbe:
        exec:
          command: ["pg_isready", "-U", "platform", "-h", "127.0.0.1"]
        initialDelaySeconds: 10
        periodSeconds: 10
```

---

## 8. Contenedores rootless, postura de seguridad e integración con systemd

### 8.1 Cómo funciona rootless en realidad

```console
$ grep "^$USER:" /etc/subuid /etc/subgid
/etc/subuid:dev:100000:65536
/etc/subgid:dev:100000:65536

$ podman unshare cat /proc/self/uid_map
         0       1000          1
         1     100000      65536
```

Lectura del mapa: UID 0 dentro del contenedor ⇒ UID 1000 en el host (tu usuario). Los UID 1–65536 de adentro ⇒ 100000–165535 en el host. Un proceso que es "root" en el contenedor tiene, en el host, los privilegios de un usuario no privilegiado con **cero** capabilities sobre los recursos del host.

```console
$ podman run --rm -v $PWD/data:/data:Z alpine:3.20 sh -c 'id; touch /data/probe; ls -ln /data'
uid=0(root) gid=0(root) groups=0(root),1(bin),...
total 0
-rw-r--r--    1 0        0                0 Sep  3 11:14 probe

$ ls -ln data/
total 0
-rw-r--r--. 1 1000 1000 0 Sep  3 11:14 probe      # <-- host sees your UID, not 0
```

El fallo clásico de volúmenes en rootless y su solución:

```console
$ podman run --rm --user 10001:10001 -v $PWD/data:/data:Z alpine:3.20 touch /data/x
touch: /data/x: Permission denied

# UID 10001 inside maps to host UID 100000+10000 = 110000, which does not own ./data.
$ podman unshare chown 10001:10001 data
$ ls -ln data/
total 0
drwxr-xr-x. 2 110000 110000 60 Sep  3 11:16 data

$ podman run --rm --user 10001:10001 -v $PWD/data:/data:Z alpine:3.20 touch /data/x
$ echo $?
0

# Or let Podman do it, at the cost of a recursive chown on every start:
$ podman run --rm --user 10001:10001 -v $PWD/data:/data:Z,U alpine:3.20 touch /data/x
```

| Aspecto | Rootful (root o grupo `docker`) | Rootless (Podman/Docker rootless) |
|---|---|---|
| Radio de daño en el host ante un escape de contenedor | Root completo | Solo el UID del usuario que invoca |
| Enlazar puertos < 1024 | Permitido | Necesita el sysctl, o un proxy inverso |
| `--network host` | Pila completa del host | Red en espacio de usuario (pasta/slirp4netns), no la pila del host |
| Rendimiento de red | Bridge del kernel | pasta ≈ casi nativo; slirp4netns notablemente más lento |
| Límites de cgroup | Siempre | Requiere cgroup v2 + systemd |
| Volúmenes NFS / CIFS / fuse | Funciona | A menudo restringido |
| Persistencia al arranque | Daemon o unidad systemd | `loginctl enable-linger <user>` + unidad systemd de usuario |
| Almacenamiento overlay | overlayfs del kernel | `fuse-overlayfs` en kernels antiguos (más lento); overlay nativo en 5.11+ con un kernel compatible |

### 8.2 Quadlet — contenedores como unidades systemd de primera clase

Quadlet (Podman ≥ 4.4) reemplaza al obsoleto `podman generate systemd`. Escribís un archivo declarativo `.container`; `podman-system-generator` genera un `.service` real en el arranque.

```ini
# /etc/containers/systemd/platform-db.container
[Unit]
Description=Platform PostgreSQL 16
Wants=network-online.target
After=network-online.target

[Container]
Image=docker.io/library/postgres:16.4-alpine
ContainerName=platform-db
AutoUpdate=registry
Network=platform-backend.network
User=70:70
Environment=POSTGRES_DB=platform
Environment=POSTGRES_USER=platform
Environment=POSTGRES_PASSWORD_FILE=/run/secrets/db_password
Environment=PGDATA=/var/lib/postgresql/data/pgdata
Secret=db_password,type=mount,target=/run/secrets/db_password
Volume=platform-pgdata.volume:/var/lib/postgresql/data:Z
Volume=/etc/platform/postgresql.conf:/etc/postgresql/postgresql.conf:ro,Z
Exec=postgres -c config_file=/etc/postgresql/postgresql.conf
PodmanArgs=--shm-size=256m
HealthCmd=pg_isready -U platform -h 127.0.0.1
HealthInterval=10s
HealthTimeout=5s
HealthRetries=5
HealthStartPeriod=30s
NoNewPrivileges=true
DropCapability=ALL
AddCapability=CHOWN
AddCapability=DAC_READ_SEARCH
AddCapability=FOWNER
AddCapability=SETGID
AddCapability=SETUID
Memory=2G
PidsLimit=512

[Service]
Restart=always
RestartSec=10
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/containers/systemd/platform-api.container
[Unit]
Description=Platform API
Requires=platform-db.service
After=platform-db.service

[Container]
Image=registry.example.com/platform/api:1.8.3
ContainerName=platform-api
AutoUpdate=registry
Network=platform-backend.network
PublishPort=127.0.0.1:8080:8080
User=65532:65532
ReadOnly=true
Tmpfs=/tmp:rw,noexec,nosuid,nodev,size=64m
NoNewPrivileges=true
DropCapability=ALL
SecurityLabelType=container_t
Environment=DATABASE_HOST=platform-db
Environment=DATABASE_PASSWORD_FILE=/run/secrets/db_password
Secret=db_password,type=mount,target=/run/secrets/db_password
HealthCmd=/usr/local/bin/api healthcheck --addr 127.0.0.1:8080
HealthInterval=10s
HealthStartPeriod=15s
HealthOnFailure=kill
Memory=512M
PidsLimit=256

[Service]
Restart=unless-stopped
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/containers/systemd/platform-backend.network
[Network]
NetworkName=platform-backend
Subnet=10.90.1.0/24
Gateway=10.90.1.1
Internal=true
```

```ini
# /etc/containers/systemd/platform-pgdata.volume
[Volume]
VolumeName=platform-pgdata
```

```console
$ sudo podman secret create db_password /root/secrets/db_password.txt
1f3a5c7e9b1d3f5a7c9e1b3d

$ sudo systemctl daemon-reload
$ sudo systemctl start platform-api.service

$ systemctl status platform-api.service --no-pager
● platform-api.service - Platform API
     Loaded: loaded (/etc/containers/systemd/platform-api.container; generated)
     Active: active (running) since Thu 2026-09-03 11:31:04 -03; 42s ago
   Main PID: 62148 (conmon)
      Tasks: 12 (limit: 4915)
     Memory: 47.2M (max: 512.0M available: 464.7M)
        CPU: 1.284s
     CGroup: /system.slice/platform-api.service
             ├─62148 /usr/bin/conmon --api-version 1 -c d7f3a91c4e28 …
             └─container
                 └─62161 /usr/local/bin/api serve

Sep 03 11:31:04 node01 podman[62130]: Starting platform-api
Sep 03 11:31:05 node01 platform-api[62161]: {"level":"info","msg":"listening","addr":":8080"}

$ sudo journalctl -u platform-api.service -f --output=cat
{"ts":"2026-09-03T11:31:05Z","level":"info","msg":"db pool ready","conns":10}
```

Como son unidades corrientes, obtenés ordenamiento con `Requires=`/`After=`, grafos de dependencias con `systemd-analyze`, agregación de logs en journald, semántica de `Restart=` y `systemctl` como única interfaz operativa — nada de lo cual proporciona el flag `--restart` de Docker. `AutoUpdate=registry` junto con `podman-auto-update.timer` trae un digest más nuevo para el mismo tag y hace rollback automático si falla el health check:

```console
$ sudo systemctl enable --now podman-auto-update.timer
$ sudo podman auto-update --dry-run
            UNIT                    CONTAINER              IMAGE                                     POLICY      UPDATED
            platform-api.service    d7f3a91c4e28 (api)     registry.example.com/platform/api:1.8.3   registry    pending
            platform-db.service     a1b2c3d4e5f6 (db)      docker.io/library/postgres:16.4-alpine    registry    false
```

---

## 9. Verificación y diagnóstico de fallos

### 9.1 Códigos de salida — leelos primero, siempre

| Código de salida | Significado | Primer comando a ejecutar |
|---|---|---|
| `0` | Salida limpia. Un servicio que sale con 0 normalmente significa "la configuración le dijo que no hiciera nada". | `docker logs <c>` |
| `1` / `2` | Error de aplicación / error de uso | `docker logs <c>` |
| `125` | **El motor mismo falló** — flag incorrecto, referencia de imagen incorrecta, red inexistente | Volvé a leer la línea de `docker run` |
| `126` | Comando encontrado pero no ejecutable — permisos incorrectos o arquitectura incorrecta | `docker run --rm --entrypoint ls img -l /path` |
| `127` | Comando no encontrado — error de tipeo, o un binario enlazado dinámicamente sobre una base sin sus bibliotecas | `ldd`, o revisá la imagen base |
| `137` | 128+9 SIGKILL — **OOM kill o un stop que agotó el tiempo** | `docker inspect -f '{{.State.OOMKilled}}'` |
| `139` | 128+11 SIGSEGV | volcado de memoria, `dmesg` |
| `143` | 128+15 SIGTERM — apagado normal y manejado | nada; esto es saludable |

```console
$ docker inspect api --format '{{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} err="{{.State.Error}}" restarts={{.RestartCount}}'
exited exit=137 oom=true err="" restarts=6
```

### 9.2 La caja de herramientas básica de verificación

| Pregunta | Comando |
|---|---|
| Estado completo en ejecución, resuelto | `docker inspect <c>` / `podman inspect <c>` |
| Qué hizo el motor y cuándo | `docker events --since 30m --filter container=<c>` |
| Uso de recursos en vivo frente a los límites | `docker stats <c>` |
| Procesos internos, con PID del host | `docker top <c> -eo pid,ppid,user,pcpu,rss,args` |
| Qué cambió en la capa de escritura | `docker diff <c>` |
| Historial del health check con su salida | `docker inspect -f '{{json .State.Health}}' <c> \| jq` |
| Adónde se fue el disco | `docker system df -v` |
| Qué cuesta cada capa | `docker history --no-trunc <img>` |
| Configuración efectiva de una pila compose | `docker compose config` |
| Verificación cruzada de los puertos realmente en escucha | `ss -lntp` en el host, `ss -lntp` vía `nsenter` adentro |

### 9.3 Runbook — el contenedor sale de inmediato

```console
$ docker compose up -d api
$ docker compose ps -a api
NAME           IMAGE                    STATUS                       PORTS
platform-api   platform/api:1.8.3       Exited (1) 3 seconds ago

$ docker logs --timestamps platform-api
2026-09-03T11:44:02.118Z {"level":"fatal","msg":"config: DATABASE_URL is required"}

# Confirm what the container actually received, not what you think you set:
$ docker inspect platform-api --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -i database
DATABASE_HOST=db
DATABASE_PORT=5432
# DATABASE_URL is absent -> the app wants a URL, compose supplies parts.

# Reproduce interactively, overriding the entrypoint to get a shell:
$ docker run --rm -it --entrypoint /bin/sh --network platform_backend \
    --env-file ./api.env platform/api:1.8.3
/ # env | grep -c DATABASE_URL
0
```

### 9.4 Runbook — OOMKilled

```console
$ docker inspect api --format '{{.State.OOMKilled}} {{.State.ExitCode}} {{.RestartCount}}'
true 137 6

$ dmesg -T | grep -i -A3 'killed process' | tail -8
[Thu Sep  3 11:47:31 2026] Memory cgroup out of memory: Killed process 62161 (api)
  total-vm:1284736kB, anon-rss:518912kB, file-rss:12288kB, shmem-rss:0kB,
  UID:65532 pgtables:1284kB oom_score_adj:0
[Thu Sep  3 11:47:31 2026] oom_reaper: reaped process 62161 (api), now anon-rss:0kB

$ cg=/sys/fs/cgroup/system.slice/docker-$(docker inspect -f '{{.Id}}' api).scope
$ cat $cg/memory.max $cg/memory.peak $cg/memory.events
536870912
536870912
low 0
high 0
max 1174
oom 2
oom_kill 2

$ cat $cg/memory.stat | egrep '^(anon|file|slab|sock|kernel_stack) '
anon 511705088
file 8check388608
slab 3506176
sock 1245184
kernel_stack 393216
```

`anon` ≈ 488 MiB del límite de 512 MiB es heap de la aplicación, no caché de páginas. Decidí entre subir el límite y arreglar la fuga — pero primero confirmá que el runtime siquiera es consciente del límite:

```console
$ docker exec api /usr/local/bin/api debug runtime
GOMAXPROCS=16   # <-- host cores, under a 1.5 CPU quota
GOMEMLIMIT=off  # <-- Go GC has no idea a 512MiB ceiling exists
```

Solución: fijar `GOMEMLIMIT` a ~90 % del límite del cgroup y `GOMAXPROCS` a `ceil(cuota de CPU)`. La misma clase de error aplica a la JVM (`-XX:MaxRAMPercentage`) y a Node (`--max-old-space-size`).

### 9.5 Runbook — "el healthcheck nunca pasa"

```console
$ docker inspect api --format '{{json .State.Health}}' | jq
{
  "Status": "unhealthy",
  "FailingStreak": 9,
  "Log": [
    {
      "Start": "2026-09-03T11:52:11.402Z",
      "End": "2026-09-03T11:52:11.418Z",
      "ExitCode": 127,
      "Output": "OCI runtime exec failed: exec failed: unable to start container process: exec: \"curl\": executable file not found in $PATH"
    }
  ]
}
```

La imagen es distroless; `curl` no existe. O bien usás un binario que la imagen sí contiene (el subcomando `api healthcheck`), o bajás a la variante `:debug` de la base solo para diagnosticar.

Un segundo fallo, más sutil — el health check apunta a `0.0.0.0` pero la app está enlazada a otra interfaz:

```console
$ docker exec api /usr/local/bin/api healthcheck --addr 127.0.0.1:8080
dial tcp 127.0.0.1:8080: connect: connection refused

$ pid=$(docker inspect -f '{{.State.Pid}}' api)
$ sudo nsenter -t $pid -n ss -lntp
State  Recv-Q Send-Q  Local Address:Port  Peer Address:Port  Process
LISTEN 0      4096    10.89.11.4:8080     0.0.0.0:*          users:(("api",pid=1,fd=7))
```

La app se enlazó a la IP propia del contenedor, no a todas las interfaces, así que una sonda por loopback falla. Enlazá a `0.0.0.0:8080` o sondeá la IP del contenedor.

### 9.6 Runbook — falla la resolución DNS dentro del contenedor

```console
$ docker exec api getent hosts db
$ echo $?
2

$ docker exec api cat /etc/resolv.conf
nameserver 127.0.0.11
options ndots:0

$ docker inspect api --format '{{range $k,$v := .NetworkSettings.Networks}}{{println $k}}{{end}}'
bridge

$ docker inspect db --format '{{range $k,$v := .NetworkSettings.Networks}}{{println $k}}{{end}}'
platform_backend
```

Causa raíz: los contenedores están en redes distintas; además, `127.0.0.11` (el resolutor embebido de Docker) solo sirve nombres para redes **definidas por el usuario**. Solución:

```console
$ docker network connect platform_backend api
$ docker exec api getent hosts db
10.89.11.2        db
```

Equivalente en Podman — verificá que `aardvark-dns` esté corriendo y que la red tenga DNS habilitado:

```console
$ podman network inspect platform-backend --format '{{.DNSEnabled}}'
true
$ pgrep -a aardvark-dns
71204 /usr/libexec/podman/aardvark-dns --config /run/containers/networks/aardvark-dns -p 53 run
```

### 9.7 Runbook — `no space left on device`

```console
$ docker system df -v | head -20
TYPE            TOTAL   ACTIVE  SIZE      RECLAIMABLE
Images          148     9       92.4GB    81.7GB (88%)
Containers      37      6       14.2GB    13.9GB (97%)
Local Volumes   22      4       61.8GB    47.1GB (76%)
Build Cache     412     0       38.9GB    38.9GB

$ df -h /var/lib/docker
Filesystem              Size  Used Avail Use% Mounted on
/dev/mapper/vg0-docker  200G  199G  418M 100% /var/lib/docker

$ du -sh /var/lib/docker/containers/*/*-json.log 2>/dev/null | sort -h | tail -3
2.1G  /var/lib/docker/containers/8c1d.../8c1d...-json.log
6.7G  /var/lib/docker/containers/a1b2.../a1b2...-json.log
11G   /var/lib/docker/containers/d7f3.../d7f3...-json.log
```

Logs `json-file` sin rotar, exactamente como se predijo en §6.4. Alivio inmediato, y después la solución permanente:

```console
$ docker builder prune --all --force
Total reclaimed space: 38.9GB

$ docker image prune --all --filter "until=168h" --force
Total reclaimed space: 74.2GB

$ docker container prune --filter "until=72h" --force
Total reclaimed space: 13.9GB

# Never run `docker volume prune` reflexively — it deletes unreferenced data volumes.
$ docker volume ls --filter dangling=true
DRIVER    VOLUME NAME
local     0f3a5c7e9b1d3f5a7c9e1b3d5f7a9c1e3b5d7f9a1c3e5b7d9f1a3c5e7b9d1f3a
```

Después configurá `log-opts` en `/etc/docker/daemon.json` y programá la limpieza como un timer de systemd en lugar de como un reflejo humano.

### 9.8 Runbook — `exec format error` / arquitectura incorrecta

```console
$ docker run --rm registry.example.com/platform/api:1.8.3
exec /usr/local/bin/api: exec format error

$ docker image inspect registry.example.com/platform/api:1.8.3 \
    --format '{{.Os}}/{{.Architecture}} {{.Variant}}'
linux/amd64

$ uname -m
aarch64
```

Al índice de imagen le falta un manifiesto arm64, o el pull se forzó a amd64. Confirmá qué ofrece el registry:

```console
$ docker buildx imagetools inspect registry.example.com/platform/api:1.8.3 \
    --format '{{range .Manifest.Manifests}}{{.Platform.OS}}/{{.Platform.Architecture}}{{println}}{{end}}'
linux/amd64
unknown/unknown
```

Solo se publicó amd64. Reconstruí con `--platform linux/amd64,linux/arm64` (§5.2). La ejecución emulada como solución provisional requiere manejadores binfmt:

```console
$ docker run --rm --privileged tonistiigi/binfmt --install arm64
installing: arm64 OK
{"supported":["linux/amd64","linux/arm64","linux/riscv64","linux/ppc64le","linux/s390x"]}
```

### 9.9 Runbook — la caché de build nunca acierta

```console
$ docker buildx build --progress=plain -t api:dev . 2>&1 | grep -E '^#[0-9]+ (CACHED|\[)'
#8 [build 3/7] COPY . .
#9 [build 4/7] RUN go mod download
```

`COPY . .` antes de `RUN go mod download` significa que *cualquier* cambio de archivo — incluida una edición del README — invalida la descarga de dependencias. Verificá además que el contexto no sea enorme:

```console
$ docker buildx build --progress=plain . 2>&1 | grep 'transferring context'
#2 transferring context: 1.84GB 21.4s
```

1.84 GB de contexto significa que falta el `.dockerignore` o que es inefectivo. Verificá qué se está enviando realmente:

```console
$ tar --exclude-from=<(sed 's/^!//' .dockerignore) -cf - . | wc -c
```

### 9.10 Runbook — se acumulan procesos zombie

```console
$ docker exec worker ps -eo pid,ppid,stat,comm | awk '$3 ~ /Z/'
   47     1 Z    ffmpeg
   52     1 Z    ffmpeg
   61     1 Z    ffmpeg

$ docker inspect worker --format '{{json .Config.Entrypoint}}'
["python","-m","worker"]
```

Python es PID 1 y no recolecta hijos huérfanos. Se soluciona con un init: `--init` (Docker inyecta `tini`), `init: true` en compose, o `ENTRYPOINT ["/usr/bin/tini","--", …]` como en §4.3.

```console
$ docker run -d --init --name worker platform/worker:1.8.3
$ docker exec worker ps -eo pid,ppid,stat,comm | head -3
  PID  PPID STAT COMMAND
    1     0 Ss   docker-init
    7     1 Ssl  python
```

### 9.11 Depurar un contenedor que no tiene shell

```console
$ docker exec -it api /bin/sh
OCI runtime exec failed: exec failed: unable to start container process:
exec: "/bin/sh": stat /bin/sh: no such file or directory
```

Tres enfoques correctos, en orden de preferencia:

```console
# 1. Attach a debug container sharing the target's namespaces (Docker 25+):
$ docker debug api
# or the portable equivalent:
$ docker run --rm -it \
    --pid=container:api --network=container:api \
    --cap-add SYS_PTRACE --security-opt seccomp=unconfined \
    nicolaka/netshoot
netshoot> ss -lntp
netshoot> tcpdump -i any -nn port 5432 -c 20
netshoot> dig +short db

# 2. Enter the namespaces from the host:
$ pid=$(docker inspect -f '{{.State.Pid}}' api)
$ sudo nsenter -t $pid -n -p -m ss -lntp

# 3. Read the container's filesystem from the host via the merged dir:
$ sudo ls -l "$(docker inspect -f '{{.GraphDriver.Data.MergedDir}}' api)/etc"
```

Equivalente rootless de Podman para inspeccionar el sistema de archivos:

```console
$ podman unshare ls -l "$(podman mount api)/etc"
$ podman unmount api
```

### 9.12 Puerta de aceptación posterior al build

Toda imagen debería pasar esto antes de que se le permita acercarse a producción:

```bash
#!/usr/bin/env bash
# ops/verify-image.sh — fail the pipeline on any violated invariant.
set -euo pipefail
IMAGE="$1"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# 1. Must not run as root.
user="$(docker image inspect "$IMAGE" --format '{{.Config.User}}')"
[ -n "$user" ] && [ "$user" != "root" ] && [ "${user%%:*}" != "0" ] \
    || fail "image runs as root (Config.User='${user}')"

# 2. Must declare an exec-form entrypoint.
docker image inspect "$IMAGE" --format '{{json .Config.Entrypoint}}' \
    | grep -qv '"/bin/sh","-c"' || fail "shell-form ENTRYPOINT: signals will be lost"

# 3. Must carry provenance labels.
for label in revision source version; do
    v="$(docker image inspect "$IMAGE" \
         --format "{{index .Config.Labels \"org.opencontainers.image.${label}\"}}")"
    [ -n "$v" ] || fail "missing label org.opencontainers.image.${label}"
done

# 4. Must declare a health check.
docker image inspect "$IMAGE" --format '{{json .Config.Healthcheck}}' \
    | grep -q 'Test' || fail "no HEALTHCHECK declared"

# 5. Must have no fixable HIGH/CRITICAL vulnerabilities.
trivy image --quiet --exit-code 1 --severity HIGH,CRITICAL --ignore-unfixed "$IMAGE" \
    || fail "fixable HIGH/CRITICAL vulnerabilities present"

# 6. Must not ship a package manager or a compiler in the runtime layer.
if docker run --rm --entrypoint /bin/sh "$IMAGE" -c \
     'command -v apt-get apk dnf yum gcc 2>/dev/null' 2>/dev/null | grep -q .; then
    fail "package manager or compiler present in the runtime image"
fi

# 7. Must actually start and become healthy.
cid="$(docker run -d --rm "$IMAGE")"
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT
for _ in $(seq 1 30); do
    st="$(docker inspect -f '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo starting)"
    [ "$st" = "healthy" ] && { printf 'OK: %s\n' "$IMAGE"; exit 0; }
    sleep 2
done
docker logs "$cid" >&2
fail "container never became healthy within 60s"
```

```console
$ ops/verify-image.sh registry.example.com/platform/api:1.8.3
OK: registry.example.com/platform/api:1.8.3

$ ops/verify-image.sh registry.example.com/legacy/billing:3.2.0
FAIL: image runs as root (Config.User='')
```

### 9.13 Referencia de comandos

| Tarea | Docker | Podman |
|---|---|---|
| Construir | `docker buildx build -t X .` | `podman build -t X .` |
| Ejecutar en segundo plano | `docker run -d --name c X` | `podman run -d --name c X` |
| Entrar con shell | `docker exec -it c sh` | `podman exec -it c sh` |
| Logs, seguimiento | `docker logs -f --since 10m c` | `podman logs -f --since 10m c` |
| Estado completo | `docker inspect c` | `podman inspect c` |
| Métricas en vivo | `docker stats c` | `podman stats c` |
| Procesos | `docker top c` | `podman top c` |
| Cambios en el FS | `docker diff c` | `podman diff c` |
| Copiar archivos | `docker cp c:/p ./p` | `podman cp c:/p ./p` |
| Eventos del motor | `docker events --since 1h` | `podman events --since 1h` |
| Push / pull | `docker push X` | `podman push X` |
| Inspección del registry (sin pull) | `docker buildx imagetools inspect X` | `skopeo inspect docker://X` |
| Guardar / cargar | `docker save X -o x.tar` | `podman save --format oci-archive X -o x.tar` |
| Multi-contenedor | `docker compose up -d` | `podman kube play f.yaml` / `podman-compose` |
| Uso de disco | `docker system df -v` | `podman system df -v` |
| Recuperar espacio | `docker system prune -a` | `podman system prune -a` |
| Arranque automático al iniciar | `--restart unless-stopped` | Unidad Quadlet `.container` |
| Generar YAML de K8s | — | `podman kube generate c` |

---

## Referencias

Especificaciones y estándares oficiales:

- OCI Image Format Specification — https://github.com/opencontainers/image-spec/blob/main/spec.md
- OCI Runtime Specification — https://github.com/opencontainers/runtime-spec/blob/main/spec.md
- OCI Distribution Specification — https://github.com/opencontainers/distribution-spec/blob/main/spec.md
- OCI pre-defined annotation keys — https://github.com/opencontainers/image-spec/blob/main/annotations.md
- The Compose Specification — https://github.com/compose-spec/compose-spec/blob/main/spec.md

Objetivos de certificación:

- LPI DevOps Tools Engineer, Exam 701 objectives — https://www.lpi.org/our-certifications/exam-701-objectives/

Docker:

- Dockerfile reference — https://docs.docker.com/reference/dockerfile/
- Multi-stage builds — https://docs.docker.com/build/building/multi-stage/
- BuildKit build mounts (`cache`, `secret`, `ssh`) — https://docs.docker.com/reference/dockerfile/#run---mount
- Building multi-platform images — https://docs.docker.com/build/building/multi-platform/
- Runtime resource constraints — https://docs.docker.com/engine/containers/resource_constraints/
- Networking overview and drivers — https://docs.docker.com/engine/network/
- Manage data: volumes, bind mounts, tmpfs — https://docs.docker.com/engine/storage/
- Configure logging drivers — https://docs.docker.com/engine/logging/configure/
- Container security options (`--security-opt`, seccomp, capabilities) — https://docs.docker.com/engine/security/
- Rootless mode — https://docs.docker.com/engine/security/rootless/
- Daemon configuration file — https://docs.docker.com/reference/cli/dockerd/#daemon-configuration-file
- `docker compose` CLI reference — https://docs.docker.com/reference/cli/docker/compose/

Podman, Buildah, Skopeo:

- Podman documentation index — https://docs.podman.io/en/latest/
- `podman run` manual — https://docs.podman.io/en/latest/markdown/podman-run.1.html
- Quadlet — `podman-systemd.unit(5)` — https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html
- `podman kube play` — https://docs.podman.io/en/latest/markdown/podman-kube-play.1.html
- `podman auto-update` — https://docs.podman.io/en/latest/markdown/podman-auto-update.1.html
- Rootless containers tutorial — https://github.com/containers/podman/blob/main/docs/tutorials/rootless_tutorial.md
- Buildah — https://buildah.io/
- Skopeo — https://github.com/containers/skopeo/blob/main/docs/skopeo.1.md
- `containers-policy.json(5)` (signature enforcement) — https://github.com/containers/image/blob/main/docs/containers-policy.json.5.md
- Netavark and Aardvark-dns — https://github.com/containers/netavark

Primitivas del kernel y del runtime:

- `namespaces(7)` — https://man7.org/linux/man-pages/man7/namespaces.7.html
- `user_namespaces(7)` — https://man7.org/linux/man-pages/man7/user_namespaces.7.html
- `capabilities(7)` — https://man7.org/linux/man-pages/man7/capabilities.7.html
- `cgroups(7)` — https://man7.org/linux/man-pages/man7/cgroups.7.html
- Linux cgroup v2 kernel documentation — https://docs.kernel.org/admin-guide/cgroup-v2.html
- OverlayFS kernel documentation — https://docs.kernel.org/filesystems/overlayfs.html
- `seccomp(2)` — https://man7.org/linux/man-pages/man2/seccomp.2.html
- runc — https://github.com/opencontainers/runc
- crun — https://github.com/containers/crun
- containerd — https://containerd.io/docs/

Cadena de suministro e imágenes:

- Distroless container images — https://github.com/GoogleContainerTools/distroless
- Red Hat Universal Base Image — https://catalog.redhat.com/software/base-images
- Trivy — https://trivy.dev/latest/docs/
- Syft (SBOM) — https://github.com/anchore/syft
- Sigstore Cosign — https://docs.sigstore.dev/cosign/signing/overview/
- SLSA provenance levels — https://slsa.dev/spec/v1.0/levels