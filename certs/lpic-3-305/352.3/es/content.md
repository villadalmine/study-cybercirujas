# Docker — Arquitectura de producción, operaciones e ingeniería de seguridad
### LPIC-3 305-300 · Topic 352.3 (exam version 3.0, weight 15)

---

## 1. Motivación: el problema arquitectónico de producción

Antes de los containers, la unidad de despliegue en la mayoría de los entornos era o bien un paquete pelado (`.deb`/`.rpm` más una pila de pegamento de gestión de configuración) o bien una máquina virtual completa. Ambos filtran el estado del host hacia la aplicación:

- **El modelo de paquete** comparte el userland del host. Dos aplicaciones que necesitan versiones incompatibles de `glibc`, `openssl` o un intérprete de Python no pueden coexistir de forma limpia. La resolución de dependencias se convierte en un problema global de satisfacción de restricciones a lo largo de cada servicio de la máquina ("dependency hell"), y el artefacto que pasó CI *no* es el artefacto que corre en producción — es solo una receta para reconstruirlo.
- **El modelo de VM completa** resuelve el aislamiento pero lo paga: un hipervisor virtualiza el hardware, cada guest carga su propio kernel, y el tiempo de arranque se mide en decenas de segundos. La densidad en un host de 128 GB tope en unos pocos cientos de guests, y la imagen pesa gigabytes.

La apuesta arquitectónica de Docker es que el **kernel es compartido y lo suficientemente estable como para ser un contrato**, y que lo *único* que una aplicación legítimamente necesita cargar es su propio userland — bibliotecas, binarios y un sistema de archivos raíz — empaquetado como una **imagen inmutable y direccionable por contenido**. El aislamiento lo proveen no un hipervisor sino primitivas del kernel (namespaces, cgroups, capabilities, seccomp, LSMs) que ya estaban en Linux. El resultado:

| Propiedad | VM completa (KVM/Xen) | Container de Docker |
|---|---|---|
| Kernel | Uno por guest | Compartido con el host |
| Tiempo de arranque / inicio | 10–60 s | 20–200 ms |
| Tamaño de imagen | GBs | decenas de MB (con multi-stage) |
| Densidad por host | 10²–10³ | 10³–10⁴ |
| Frontera de aislamiento | Virtualizada por hardware, fuerte | Impuesta por el kernel, más débil (superficie de ataque compartida) |
| Live migration | Madura | No es un concepto de primera clase |
| Inmutabilidad / reproducibilidad | Débil (disco mutable) | Fuerte (por capas, fijada por digest) |

Las consecuencias de producción de las que este topic realmente trata:

1. **El daemon es un punto único de falla compartido, propiedad de root.** `dockerd` corre como root, escucha en un socket, y el ciclo de vida de cada container cuelga de él. Un reinicio del daemon históricamente mataba a cada container; `/var/run/docker.sock` montado por bind dentro de un container equivale a darle a ese container root sobre el host. Esto empujó a la industria hacia el **rootless mode**, `live-restore` y el **split containerd/runc**.
2. **Cadena de suministro y procedencia.** Una imagen es código que no escribiste, corriendo como root por defecto, traído por un tag mutable. El escaneo de CVE, la fijación por digest y la firma (Notation/cosine, Docker Content Trust) existen porque `docker pull nginx:latest` es una descarga no autenticada de un ejecutable.
3. **El aislamiento de recursos es opcional, no por defecto.** Un container sin límite de `--memory`/`--cpus` puede matar de hambre a sus vecinos. El Docker de producción se trata en su mayor parte de los flags que *agregás* a `docker run`.

> **Encuadre oficial:** el propio overview de Docker, "Docker overview / architecture," docs.docker.com/get-started/docker-overview/ — el modelo cliente–daemon–registry descrito abajo.

---

## 2. Arquitectura de Docker e internals

### 2.1 El árbol de procesos: client → dockerd → containerd → shim → runc

El Docker moderno **no** es un monolito. La CLI que tipeás es un cliente delgado; el trabajo real se delega hacia abajo en una cadena de daemons, cada uno cumpliendo con una especificación OCI.

```
docker (CLI)  ──REST/gRPC──►  dockerd (Docker Engine API)
                                   │  (image build, networking, volumes, API)
                                   ▼
                              containerd            (OCI image + container lifecycle)
                                   │
                                   ▼
                          containerd-shim-runc-v2   (one per container; reparents to init)
                                   │  exec
                                   ▼
                                 runc                (creates namespaces/cgroups, execs entrypoint, exits)
                                   │
                                   ▼
                          your process (PID 1 in the container's PID namespace)
```

- **`runc`** es un runtime de tipo *fork-and-exec*: arma los namespaces/cgroups, aplica el OCI runtime spec (`config.json`), hace `exec` del entrypoint del container, y **sale**. No permanece residente.
- **`containerd-shim-runc-v2`** es el padre residente. Como `runc` sale, el shim mantiene abierto el `stdio` del container, lo cosecha (reap), reporta el estado de salida, y — de manera crucial — **sobrevive a un reinicio de `dockerd`**. Esto es lo que hace posible `live-restore`: los containers siguen corriendo mientras el engine se actualiza.
- **`containerd`** es dueño del image store, los snapshots y los metadatos de los containers. `dockerd` por encima agrega la UX de más alto nivel: `docker build`, networking (libnetwork), volumes, Swarm, la API de cara a Compose.

Verificá la cadena en un host corriendo:

```console
$ docker run -d --name web nginx:1.27-alpine
9f1c0a3b...
$ ps -eo pid,ppid,comm | grep -E 'dockerd|containerd|runc|nginx'
    901     1 dockerd
    950     1 containerd
   1442   950 containerd-shim
   1465  1442 nginx
$ sudo ctr --namespace moby containers ls        # containerd sees the same container
CONTAINER       IMAGE    RUNTIME
9f1c0a3b...     -        io.containerd.runc.v2
```

Notá que el PPID del shim es `containerd` (950), y `nginx` se reparenta al shim (1442), **no** a `dockerd`. Matá `dockerd` y `nginx` sigue sirviendo.

### 2.2 Las especificaciones OCI

Docker interopera porque tres specs desacoplan las piezas:

| Spec | Gobierna | Artefacto |
|---|---|---|
| **OCI Image Spec** | Layout en disco/registry: layers, manifest, config | layers `sha256:` + manifest.json |
| **OCI Runtime Spec** | Cómo un "filesystem bundle" se convierte en un proceso corriendo | `config.json` + `rootfs/` |
| **OCI Distribution Spec** | API HTTP del registry (push/pull/discovery) | endpoints `/v2/...` |

Por esto es que `skopeo copy`, `buildah`, `podman` y `containerd` pueden todos consumir imágenes de Docker: hablan el mismo formato de cable OCI.

### 2.3 Las primitivas del kernel que *son* el container

Un "container" no es un objeto del kernel. Es un **proceso** envuelto en:

| Primitiva | Aísla | Exposición en Docker |
|---|---|---|
| **PID namespace** | Árbol de procesos (container PID 1) | por defecto; `--pid=host` para desactivar |
| **Network namespace** | Interfaces, rutas, iptables, puertos | driver de `--network` |
| **Mount namespace** | Vista del filesystem (rootfs, overlayfs) | siempre |
| **UTS namespace** | Hostname/domainname | `--hostname`, `--uts=host` |
| **IPC namespace** | SysV IPC, POSIX message queues | `--ipc` |
| **User namespace** | Mapeo de UID/GID (root-in-container ≠ root-on-host) | `userns-remap`, rootless |
| **cgroup namespace** | La vista del container sobre su propio cgroup | por defecto (cgroup v2) |
| **cgroups v2** | *Límites* de CPU, memoria, IO, PIDs | `--cpus`, `--memory`, `--pids-limit` |
| **Capabilities** | Poderes de root de grano fino | `--cap-drop`/`--cap-add` |
| **seccomp-BPF** | Syscalls permitidas | perfil por defecto; `--security-opt seccomp=` |
| **LSM (AppArmor/SELinux)** | Política MAC | `--security-opt apparmor=`/`label=` |

Probá que los namespaces son distintos:

```console
$ docker run -d --name ns-demo alpine sleep 1000
$ pid=$(docker inspect -f '{{.State.Pid}}' ns-demo)
$ sudo ls -l /proc/$pid/ns/
lrwxrwxrwx 1 root root 0 net -> 'net:[4026532567]'
lrwxrwxrwx 1 root root 0 pid -> 'pid:[4026532571]'
lrwxrwxrwx 1 root root 0 mnt -> 'mnt:[4026532565]'
...
$ sudo ls -l /proc/1/ns/net        # host's net namespace inode differs
lrwxrwxrwx 1 root root 0 net -> 'net:[4026531840]'
```

### 2.4 Storage driver: `overlay2` y copy-on-write

Una imagen es una pila de **capas de solo lectura**; el container agrega una fina **capa de lectura-escritura** encima. `overlay2` es el default de producción, implementado con el OverlayFS del kernel:

```
container rw layer  (upperdir)   ← writes land here (copy-up on modify)
─────────────────
image layer N       (lowerdir)   ← read-only
image layer N-1     (lowerdir)
...                              ← merged view = mountpoint
```

- **Copy-on-write:** modificar un archivo de una capa inferior primero lo copia hacia arriba, a la capa escribible — la penalización de "copy-up", que es la razón por la que las cargas con muchas escrituras deberían usar **volumes**, no el filesystem del container.
- Las capas son **direccionadas por contenido** (`sha256`), así que las capas idénticas se comparten entre imágenes en disco — la razón por la que traer una segunda imagen basada en `-alpine` es casi gratis.

```console
$ docker info --format '{{.Driver}}'
overlay2
$ docker system df
TYPE            TOTAL   ACTIVE  SIZE      RECLAIMABLE
Images          14      6       2.1GB     1.3GB (61%)
Containers      9       4       115MB     46MB (40%)
Local Volumes   5       3       820MB     210MB (25%)
Build Cache     102     0       640MB     640MB
```

### 2.5 Docker frente al resto del campo

| | Docker Engine | Podman | containerd (crudo) | LXC |
|---|---|---|---|---|
| Daemon | `dockerd` root de larga vida | **Sin daemon** (fork/exec) | Daemon `containerd` | Monitor `lxc` por container |
| Rootless | Sí (setup extra) | **Nativo/de primera clase** | Vía nerdctl | Sí |
| Integración con systemd | Débil (brecha de PID 1) | `podman generate systemd`/Quadlet | — | Fuerte |
| Build | BuildKit integrado | Buildah | Necesita BuildKit/img | Templates |
| Imágenes OCI | Sí | Sí | Sí | No nativamente (system containers) |
| Orquestación | Swarm / alimenta K8s | Pods (tipo K8s) | Target CRI de K8s | No es su foco |
| Uso típico | Dev + prod de un solo host | Rootless/RHEL, drop-in `alias docker=podman` | Runtime de nodo de Kubernetes | Containers de sistema/SO completo |

**Podman, Buildah, Skopeo** (LPI espera *conocimiento*): `podman` es un drop-in sin daemon, mayormente compatible con la CLI (`alias docker=podman` funciona para la mayoría de los flujos); `buildah` construye imágenes OCI sin daemon y con control más fino de los pasos; `skopeo` copia/inspecciona/firma imágenes **entre registries y stores sin traerlas a un runtime local** (`skopeo copy docker://... docker://...`).

---

## 3. Gestión de imágenes y Dockerfiles

### 3.1 Anatomía de una referencia de imagen

```
registry.example.com:5000 / team / api : 1.4.2 @ sha256:9b2a...   
└──── registry host ────┘  └repo path┘  └tag┘  └── immutable digest ──┘
```

- Un **tag** es mutable (`:latest` puede apuntar a cualquier lado mañana). Un **digest** (`@sha256:...`) es direccionado por contenido e inmutable. **Fijá digests en producción** por reproducibilidad y seguridad de la cadena de suministro.

### 3.2 Un Dockerfile multi-stage de grado producción (completo)

Los builds multi-stage compilan en una etapa "builder" gorda y copian *solo el artefacto* a una etapa de runtime mínima — la palanca individual más grande sobre el tamaño de la imagen y la superficie de ataque.

```dockerfile
# syntax=docker/dockerfile:1.7
# ---- Stage 1: build ----
FROM golang:1.22-bookworm AS build
WORKDIR /src

# Cache module downloads separately from source for better layer caching.
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

COPY . .
# Static build: no libc dependency, so it runs on scratch/distroless.
RUN --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux GOFLAGS=-trimpath \
    go build -ldflags="-s -w" -o /out/api ./cmd/api

# ---- Stage 2: runtime ----
FROM gcr.io/distroless/static-debian12:nonroot AS runtime
# distroless: no shell, no package manager -> minimal CVE surface.

# Copy only the compiled binary from the build stage.
COPY --from=build /out/api /usr/local/bin/api

# Run as an unprivileged, numeric UID (works even without /etc/passwd).
USER 65532:65532

EXPOSE 8080
# Exec form -> PID 1 is the app, receives SIGTERM directly (clean shutdown).
ENTRYPOINT ["/usr/local/bin/api"]
```

`.dockerignore` de acompañamiento (mantiene chico el contexto de build y los secretos fuera de las capas):

```gitignore
.git
.gitignore
*.md
**/*_test.go
.env
.env.*
secrets/
Dockerfile
docker-compose*.yml
```

Construir e inspeccionar:

```console
$ DOCKER_BUILDKIT=1 docker build -t registry.example.com/team/api:1.4.2 .
[+] Building 22.7s (16/16) FINISHED
 => [build 4/6] RUN go mod download                              6.1s
 => [build 6/6] RUN CGO_ENABLED=0 ... go build -o /out/api       9.8s
 => [runtime 2/2] COPY --from=build /out/api /usr/local/bin/api  0.1s
 => exporting to image                                           0.3s
 => => writing image sha256:3c1f...                              0.0s
 => => naming to registry.example.com/team/api:1.4.2

$ docker image ls registry.example.com/team/api
REPOSITORY                        TAG     IMAGE ID       SIZE
registry.example.com/team/api     1.4.2   3c1f2a9d8e4b   11.9MB
```

### 3.3 Semántica de instrucciones que hace tropezar a la gente

| Preocupación | Hacé | No hagas |
|---|---|---|
| Manejo de señales | `ENTRYPOINT ["/app"]` (exec form) | `ENTRYPOINT /app` (shell form → PID 1 es `sh`, se traga SIGTERM) |
| Cache de capas | Copiar `go.mod`/`package.json` antes del fuente | `COPY . .` primero (invalida la cache ante cualquier cambio) |
| Secretos | `RUN --mount=type=secret` | `ARG TOKEN` / `COPY .env` (horneados en una capa para siempre) |
| Tamaño de imagen | Multi-stage, `--no-install-recommends`, limpiar listas de apt en el mismo `RUN` | `RUN apt clean` separado (la capa previa todavía retiene la cache) |
| `ADD` vs `COPY` | `COPY` para archivos; `ADD` solo para URL remota/auto-extracción de tar | `ADD` para todo |

### 3.4 Registry, digests y pull-by-digest

```console
$ docker push registry.example.com/team/api:1.4.2
The push refers to repository [registry.example.com/team/api]
5f70bf18a086: Pushed
1.4.2: digest: sha256:9b2a4c... size: 949

# Pin the digest downstream so the tag can never be swapped under you:
$ docker pull registry.example.com/team/api@sha256:9b2a4c...
$ docker inspect --format '{{index .RepoDigests 0}}' registry.example.com/team/api:1.4.2
registry.example.com/team/api@sha256:9b2a4c...
```

### 3.5 Escaneo de CVE (la brecha honesta de la cadena de suministro)

```console
$ docker scout cves registry.example.com/team/api:1.4.2
    ✓ Image stored for indexing
    ✓ Indexed 1 package
  No vulnerabilities found.

# Or vendor-neutral, in CI:
$ trivy image --severity HIGH,CRITICAL --exit-code 1 registry.example.com/team/api:1.4.2
registry.example.com/team/api:1.4.2 (debian 12)
Total: 0 (HIGH: 0, CRITICAL: 0)
```

`--exit-code 1` hace que el escaneo **falle el pipeline** ante un CRITICAL — el punto de escanear es una compuerta, no un reporte.

---

## 4. Ciclo de vida del container y controles de runtime

### 4.1 Un `docker run` endurecido y acotado en recursos (forma de producción)

Cada flag acá es un default de producción por el que deberías ir, no una rareza:

```console
$ docker run -d \
    --name api \
    --restart=on-failure:5 \
    --memory=512m --memory-swap=512m \      # hard cap; swap=mem disables swap
    --cpus=1.5 \                            # 1.5 cores of CPU time
    --pids-limit=200 \                      # fork-bomb guard
    --read-only \                           # immutable rootfs
    --tmpfs /tmp:rw,noexec,nosuid,size=64m \ # writable scratch, non-exec
    --cap-drop=ALL --cap-add=NET_BIND_SERVICE \
    --security-opt no-new-privileges:true \  # block setuid escalation
    --user 65532:65532 \
    --health-cmd='wget -qO- http://localhost:8080/healthz || exit 1' \
    --health-interval=10s --health-timeout=2s --health-retries=3 \
    -p 127.0.0.1:8080:8080 \                 # bind to loopback, not 0.0.0.0
    registry.example.com/team/api:1.4.2
```

### 4.2 Políticas de reinicio

| Política | Comportamiento | Usar para |
|---|---|---|
| `no` (por defecto) | Nunca reinicia | trabajos de una sola vez |
| `on-failure[:N]` | Reinicia ante salida no-cero, hasta N | cargas batch/idempotentes |
| `always` | Reinicia siempre, incl. al arranque del daemon | servicios de larga vida |
| `unless-stopped` | Como `always` pero honra un `docker stop` manual a través de reinicios del daemon | servicios que a veces parás a mano |

### 4.3 Healthchecks y estados del ciclo de vida

```console
$ docker ps --format 'table {{.Names}}\t{{.Status}}'
NAMES   STATUS
api     Up 2 minutes (healthy)

$ docker inspect --format '{{json .State.Health}}' api | jq
{
  "Status": "healthy",
  "FailingStreak": 0,
  "Log": [ { "ExitCode": 0, "Output": "OK" } ]
}
```

### 4.4 Logging drivers (los logs sin límite son una de las principales caídas de guardia)

El driver por defecto `json-file` **crece sin límite** y ha llenado `/var/lib/docker` en incontables hosts. Acotalo por container o globalmente (ver §7):

```console
$ docker run -d --log-driver=json-file \
    --log-opt max-size=10m --log-opt max-file=3 nginx
```

| Driver | Destino | Notas |
|---|---|---|
| `json-file` | disco local | por defecto; **fijá `max-size`/`max-file`** |
| `local` | disco local (binario) | más eficiente que json-file |
| `journald` | journal de systemd | rotación central, `journalctl CONTAINER_NAME=` |
| `syslog`/`fluentd`/`gelf`/`awslogs` | remoto | enviar a un agregador |

---

## 5. Networking

### 5.1 Drivers y sus compromisos

| Driver | Modelo | L2/L3 | Cross-host | Perf | Caso de uso |
|---|---|---|---|---|---|
| **bridge** (por defecto) | NAT vía `docker0`/veth | L3 (NAT) | No | Bueno | Multi-container de un solo host |
| **user-defined bridge** | Igual + **DNS embebido** | L3 (NAT) | No | Bueno | **Elección por defecto**: descubrimiento de servicios por nombre |
| **host** | Comparte el netns del host | — | No | **Nativo** | Crítico en latencia, sin mapeo de puertos |
| **none** | Solo loopback | — | No | — | Totalmente aislado / netns a medida |
| **macvlan** | El container obtiene una MAC en la LAN física | L2 | Sí (físico) | Nativo | Container como host de primera clase en la LAN |
| **ipvlan** | Comparte la MAC del host, IP propia | L2/L3 | Sí | Nativo | macvlan sin proliferación de MAC |
| **overlay** | VXLAN a través de un Swarm | L2 sobre L3 | **Sí** | Moderado | Clusters multi-host (Swarm) |

### 5.2 Por qué user-defined bridges, no el bridge por defecto

Los containers en el `bridge` **por defecto** solo pueden alcanzarse entre sí por IP. Los containers en un **user-defined** bridge obtienen el **DNS embebido de Docker en 127.0.0.11**, así que se resuelven entre sí por nombre de container/servicio — el fundamento del descubrimiento de servicios en Compose.

```console
$ docker network create --driver bridge \
    --subnet 172.28.0.0/16 --gateway 172.28.0.1 appnet
$ docker run -d --name db  --network appnet postgres:16
$ docker run -d --name api --network appnet registry.example.com/team/api:1.4.2

$ docker exec api getent hosts db
172.28.0.2       db                       # resolved by name via embedded DNS
$ docker exec api cat /etc/resolv.conf
nameserver 127.0.0.11
```

### 5.3 Qué hace realmente la publicación de puertos (iptables/NAT)

`-p 8080:80` inserta una regla **DNAT** para que el tráfico del host se reescriba hacia la IP del namespace del container:

```console
$ docker run -d -p 8080:80 --name web nginx
$ sudo iptables -t nat -L DOCKER -n
Chain DOCKER (2 references)
target  prot opt source     destination
DNAT    tcp  --  0.0.0.0/0  0.0.0.0/0   tcp dpt:8080 to:172.17.0.2:80

$ docker port web
80/tcp -> 0.0.0.0:8080
```

Publicar a `0.0.0.0` expone el puerto en **cada** interfaz del host — atalo a `127.0.0.1:8080:80` cuando solo el host debería alcanzarlo.

### 5.4 Inspeccionar conectividad

```console
$ docker network inspect appnet --format '{{json .Containers}}' | jq
{
  "api...": { "Name": "api", "IPv4Address": "172.28.0.3/16" },
  "db...":  { "Name": "db",  "IPv4Address": "172.28.0.2/16" }
}
$ docker exec api wget -qO- http://db:5432 2>&1 | head -1   # name reachability test
```

---

## 6. Storage: volumes vs bind mounts vs tmpfs

| Tipo de mount | Gestionado por Docker | Ubicación | Sobrevive a `rm` | Mejor para |
|---|---|---|---|---|
| **Named volume** | Sí (`/var/lib/docker/volumes`) | Gestionado por Docker | Sí (hasta `volume rm`) | **Datos persistentes (DBs)**, portabilidad, volume drivers |
| **Bind mount** | No | Ruta arbitraria del host | Sí (el host es dueño) | Montajes de fuente en dev, config/socket del host |
| **tmpfs** | Sí | Solo RAM | No | Secretos/scratch que nunca deben tocar el disco |

Reglas de oro: **nunca escribas datos calientes en la capa escribible del container** (costo de copy-up, se pierde con `rm`); usá **volumes** para el estado; usá **bind mounts** con moderación y de solo lectura en prod.

```console
$ docker volume create pgdata
$ docker run -d --name db \
    -v pgdata:/var/lib/postgresql/data \        # named volume (persistent)
    --mount type=bind,src=/etc/pg/pg.conf,dst=/etc/postgresql/postgresql.conf,ro \
    --tmpfs /run/postgresql:rw,size=32m \
    -e POSTGRES_PASSWORD_FILE=/run/secrets/pw \
    postgres:16

$ docker volume inspect pgdata --format '{{.Mountpoint}}'
/var/lib/docker/volumes/pgdata/_data
```

La sintaxis explícita de `--mount` (`type=`,`src=`,`dst=`,`ro`) se prefiere sobre `-v` en producción porque es inequívoca y falla ruidosamente ante errores de tipeo en lugar de crear silenciosamente un volume vacío.

---

## 7. Configuración del daemon: `/etc/docker/daemon.json`

El comportamiento del daemon se centraliza acá (un reinicio de `dockerd` la aplica; algunas claves recargan con `SIGHUP`). Una línea base de producción:

```json
{
  "data-root": "/var/lib/docker",
  "storage-driver": "overlay2",
  "live-restore": true,
  "userland-proxy": false,
  "no-new-privileges": true,
  "icc": false,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "default-ulimits": {
    "nofile": { "Name": "nofile", "Soft": 65536, "Hard": 65536 }
  },
  "default-address-pools": [
    { "base": "172.30.0.0/16", "size": 24 }
  ],
  "insecure-registries": [],
  "registry-mirrors": ["https://mirror.internal.example.com"],
  "userns-remap": "default",
  "features": { "buildkit": true }
}
```

Perillas clave de producción:

- **`live-restore: true`** — los containers siguen corriendo a través de una actualización/reinicio de `dockerd` (funciona porque el shim sobrevive al daemon; no es compatible con nodos gestionados por Swarm).
- **`userns-remap: default`** — remapea el root del container a un rango de UID no privilegiado del host (`/etc/subuid`), de modo que root-in-container ≠ root-on-host.
- **`icc: false`** — desactiva la comunicación entre containers en el bridge por defecto; fuerza redes user-defined explícitas.
- **`userland-proxy: false`** — usa el hairpin de iptables en lugar del proceso userspace `docker-proxy` para los puertos publicados (menor overhead).
- **`default-address-pools`** — evita que Docker colisione con tu LAN corporativa `172.17.0.0/16`.
- **`log-opts`** — el arreglo más común para "disco lleno".

Aplicar y verificar:

```console
$ sudo dockerd --validate --config-file /etc/docker/daemon.json
configuration OK
$ sudo systemctl restart docker
$ docker info --format '{{.LiveRestoreEnabled}} {{.SecurityOptions}}'
true [name=seccomp,profile=builtin name=userns name=rootless...]
```

### 7.1 Rootless mode

El Docker rootless corre `dockerd` y los containers **enteramente como un usuario no privilegiado**, usando user namespaces + `slirp4netns` para networking. Elimina la clase de escapes de "socket = root del host".

```console
$ dockerd-rootless-setuptool.sh install
[INFO] Creating /home/deploy/.config/systemd/user/docker.service
[INFO] Installed docker.service successfully.
$ export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock
$ docker info --format '{{.SecurityOptions}}'
[name=seccomp,profile=builtin name=rootless name=cgroupns]
```
Compromisos: no se puede atar a puertos < 1024 sin `sysctl net.ipv4.ip_unprivileged_port_start`, algunas advertencias de storage-driver/overlay, y aislamiento por usuario en lugar de un daemon compartido.

---

## 8. Modelo de seguridad

Defensa en profundidad — cada capa es independiente y aditiva:

| Control | Flag / config | Efecto |
|---|---|---|
| Bajar de root | `--user`, `USER` en el Dockerfile, `userns-remap` | el proceso no es UID 0 (in-container y/o on-host) |
| Capabilities | `--cap-drop=ALL --cap-add=…` | reducir las ~14 caps por defecto a lo necesario |
| Sin escalada de privilegios | `--security-opt no-new-privileges` | los binarios setuid no pueden elevar privilegios |
| Filtro de syscalls | perfil **seccomp** por defecto (bloquea ~44 syscalls) | reduce la superficie de ataque del kernel |
| MAC | AppArmor (`docker-default`) / SELinux (`--security-opt label=`) | control de acceso obligatorio |
| Rootfs inmutable | `--read-only` + `--tmpfs` | sin persistencia de un compromiso en el fs |
| Nunca hagas esto | `--privileged`, `-v /var/run/docker.sock:...` | = root sobre el host |

Verificá lo que un container realmente tiene:

```console
$ docker run --rm --cap-drop=ALL --cap-add=NET_BIND_SERVICE alpine \
    sh -c 'apk add -q libcap; capsh --print | grep Current'
Current: cap_net_bind_service=ep

$ docker inspect --format '{{.HostConfig.SecurityOpt}} priv={{.HostConfig.Privileged}}' api
[no-new-privileges:true label=type:container_t] priv=false
```

**Docker Content Trust** (firma de imágenes) y el escaneo de CVE cierran la parte de arriba de la cadena de suministro:

```console
$ export DOCKER_CONTENT_TRUST=1
$ docker pull registry.example.com/team/api:1.4.2
Tagging registry.example.com/team/api@sha256:9b2a... as ...:1.4.2   # only if signed
```

---

## 9. Docker Compose

Compose es la spec declarativa multi-container de un solo host (o Swarm). El Docker moderno trae **Compose v2** como el **plugin** `docker compose` (Go), reemplazando el binario legado `docker-compose` v1 en Python. La clave de nivel superior `version:` ahora es obsoleta y se ignora.

Un `compose.yaml` completo, con forma de producción:

```yaml
name: web-stack

services:
  api:
    image: registry.example.com/team/api:1.4.2
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy       # wait for db's healthcheck, not just start
    environment:
      DATABASE_URL: postgres://app@db:5432/app
    secrets:
      - db_password
    ports:
      - "127.0.0.1:8080:8080"
    networks: [frontend, backend]
    read_only: true
    tmpfs:
      - /tmp:size=64m
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE]
    security_opt:
      - no-new-privileges:true
    deploy:
      resources:
        limits:   { cpus: "1.5", memory: 512M }
        reservations: { memory: 256M }
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:8080/healthz"]
      interval: 10s
      timeout: 2s
      retries: 3
      start_period: 15s

  db:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: app
      POSTGRES_DB: app
      POSTGRES_PASSWORD_FILE: /run/secrets/db_password
    secrets:
      - db_password
    volumes:
      - pgdata:/var/lib/postgresql/data
    networks: [backend]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U app -d app"]
      interval: 5s
      timeout: 3s
      retries: 5

networks:
  frontend:
  backend:
    internal: true          # no egress; DB tier can't reach the outside world

volumes:
  pgdata:

secrets:
  db_password:
    file: ./secrets/db_password.txt
```

Operarlo:

```console
$ docker compose config -q          # validate/interpolate without running
$ docker compose up -d
[+] Running 4/4
 ✔ Network web-stack_backend   Created
 ✔ Network web-stack_frontend  Created
 ✔ Container web-stack-db-1     Healthy
 ✔ Container web-stack-api-1    Started

$ docker compose ps
NAME               IMAGE                    STATUS                    PORTS
web-stack-api-1    .../team/api:1.4.2       Up (healthy)              127.0.0.1:8080->8080/tcp
web-stack-db-1     postgres:16-alpine       Up (healthy)

$ docker compose logs -f --tail=20 api
$ docker compose down -v            # -v also removes named volumes
```

`depends_on … condition: service_healthy` es el arreglo correcto para la clásica carrera donde `api` arranca antes de que `db` esté aceptando conexiones — el `depends_on` simple solo ordena el *arranque*, no la *disponibilidad*.

---

## 10. Verificación y diagnóstico de fallas

### 10.1 Comandos de triage de primera pasada

```console
$ docker info                       # daemon: driver, cgroup version, warnings
$ docker version                    # client/server API skew
$ docker system df -v               # where disk went (images/containers/volumes/cache)
$ docker events --since 10m         # lifecycle stream: OOM, die, health_status
$ docker stats --no-stream          # live CPU/mem/net/IO per container
$ journalctl -u docker --since '10 min ago'   # daemon-side errors
```

### 10.2 Un container no arranca / sale inmediatamente

```console
$ docker ps -a --filter name=api
CONTAINER   STATUS
a1b2c3      Exited (1) 3 seconds ago
$ docker logs --tail=50 api          # the app's own error
$ docker inspect --format '{{.State.ExitCode}} {{.State.Error}} oom={{.State.OOMKilled}}' api
137  <no value> oom=true
```

**Exit 137 = 128 + 9 (SIGKILL)**, y `OOMKilled: true` confirma que se disparó el OOM killer del kernel — subí `--memory` o arreglá el leak. **Exit 143 = 128 + 15 (SIGTERM)** es una parada limpia.

### 10.3 Diagnosticar OOM contra el cgroup

```console
$ cid=$(docker inspect -f '{{.Id}}' api)
$ cat /sys/fs/cgroup/system.slice/docker-$cid.scope/memory.max
536870912
$ cat /sys/fs/cgroup/system.slice/docker-$cid.scope/memory.events
oom 0
oom_kill 3                          # the kernel killed the workload 3 times
$ dmesg | grep -i 'killed process'
Out of memory: Killed process 1465 (api) total-vm:... anon-rss:...
```

### 10.4 Fallas de networking

```console
# DNS resolution inside the container:
$ docker exec api getent hosts db || echo "name not resolvable"
# Is the port actually published?
$ docker port web
80/tcp -> 0.0.0.0:8080
# Enter the container's network namespace with host tools (no tools in the image):
$ pid=$(docker inspect -f '{{.State.Pid}}' api)
$ sudo nsenter -t $pid -n ss -tlnp
State   Local Address:Port   Process
LISTEN  0.0.0.0:8080         users:(("api",pid=1))
# Is the DNAT rule present?
$ sudo iptables -t nat -S DOCKER | grep 8080
```

`nsenter -t <pid> -n` es el truco clave: corre un binario del **host** (`ss`, `tcpdump`, `ip`) dentro del **network namespace** del container, así que podés diagnosticar un container distroless que no trae herramienta alguna.

### 10.5 Storage / disco lleno

```console
$ docker system df
$ docker system prune -a --volumes    # reclaim: dangling images, stopped containers, unused volumes, build cache
Total reclaimed space: 3.8GB
$ df -h /var/lib/docker
```

### 10.6 Salud y disponibilidad

```console
$ docker inspect --format '{{.State.Health.Status}}' api
unhealthy
$ docker inspect --format '{{range .State.Health.Log}}{{.End}} exit={{.ExitCode}} {{.Output}}{{"\n"}}{{end}}' api
2026-08-11T... exit=1 wget: can't connect to localhost:8080
```

### 10.7 Forense interactivo sobre un container detenido/mínimo

```console
# Copy a file out of a dead container's filesystem:
$ docker cp api:/var/log/app.log ./app.log
# Attach a debug sidecar sharing the target's namespaces (no shell in the image):
$ docker run -it --rm \
    --pid=container:api --net=container:api \
    --cap-add=SYS_PTRACE nicolaka/netshoot \
    sh -c 'ps aux; ss -tlnp'
```

`nicolaka/netshoot` compartiendo `--pid`/`--net` del target es la manera estándar de depurar un container distroless/scratch que no tiene shell, `ps` ni `ss` propios.

---

## Referencias

- Docker overview & architecture — https://docs.docker.com/get-started/docker-overview/
- Docker Engine daemon configuration (`/etc/docker/daemon.json`) — https://docs.docker.com/engine/daemon/
- `dockerd` reference — https://docs.docker.com/reference/cli/dockerd/
- Dockerfile reference — https://docs.docker.com/reference/dockerfile/
- BuildKit & multi-stage builds — https://docs.docker.com/build/building/multi-stage/
- `.dockerignore` — https://docs.docker.com/reference/dockerfile/#dockerignore-file
- Storage drivers / `overlay2` — https://docs.docker.com/engine/storage/drivers/overlayfs-driver/
- Volumes and bind mounts — https://docs.docker.com/engine/storage/volumes/
- Networking overview & drivers — https://docs.docker.com/engine/network/
- Bridge / user-defined networks & embedded DNS — https://docs.docker.com/engine/network/drivers/bridge/
- Runtime resource constraints — https://docs.docker.com/engine/containers/resource_constraints/
- Container security & seccomp — https://docs.docker.com/engine/security/seccomp/
- AppArmor profile — https://docs.docker.com/engine/security/apparmor/
- Rootless mode — https://docs.docker.com/engine/security/rootless/
- User namespace remapping — https://docs.docker.com/engine/security/userns-remap/
- Docker Content Trust — https://docs.docker.com/engine/security/trust/
- Docker Scout (CVE scanning) — https://docs.docker.com/scout/
- Compose file reference (v2) — https://docs.docker.com/reference/compose-file/
- Compose `depends_on` / healthcheck conditions — https://docs.docker.com/reference/compose-file/services/#depends_on
- `docker system prune` — https://docs.docker.com/reference/cli/docker/system/prune/
- containerd — https://containerd.io/docs/
- runc (OCI runtime) — https://github.com/opencontainers/runc
- OCI Image / Runtime / Distribution specs — https://github.com/opencontainers/image-spec · https://github.com/opencontainers/runtime-spec · https://github.com/opencontainers/distribution-spec
- Podman — https://docs.podman.io/ · Buildah — https://buildah.io/ · Skopeo — https://github.com/containers/skopeo
- LPIC-3 305-300 exam objectives (352.3) — https://www.lpi.org/our-certifications/exam-305-objectives/