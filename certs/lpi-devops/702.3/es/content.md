# 702.3 — Construcción de imágenes de contenedores

**Certificación:** LPI DevOps Tools Engineer · **Examen:** 701-100 · **Versión del temario:** 2.0.0
**Peso del objetivo:** 8.33 — uno de los objetivos individuales de mayor peso del examen. Esperá preguntas sobre la semántica de `Dockerfile`/`Containerfile`, builds multi-stage, caché en tiempo de build, builders daemonless/rootless, interacción con registries y metadatos de imagen.

**Mapa de cobertura (resumen original del objetivo, atribuido a los objetivos de examen publicados — ver *Referencias*):**

| Área | Qué tenés que ser capaz de hacer |
|---|---|
| Ficheros de build | Escribir y razonar sobre instrucciones de `Dockerfile` / `Containerfile` y su semántica exacta en runtime |
| Ejecución del build | Construir imágenes con `docker build` / BuildKit, `podman build`, `buildah`, y entender las alternativas daemonless |
| Capas y caché | Explicar la creación de capas, el direccionamiento por contenido, la derivación de la clave de caché, su invalidación y `.dockerignore` |
| Multi-stage | Separar las dependencias de build de las de runtime; seleccionar y apuntar a stages concretos |
| Registries | Etiquetar, hacer push, pull, autenticarse; entender tags vs digests y las manifest lists |
| Modelo de imagen | Entender la especificación de imagen OCI: index, manifest, config, capas, anotaciones |
| Builders alternativos | Conocer Cloud Native Buildpacks, Kaniko, `ko`, Jib y sus compromisos |
| Hardening | Imágenes base mínimas, usuarios no root, secretos de build, SBOM/provenance, reproducibilidad |

---

## 1. El problema de producción: la imagen es una ABI, no un archivo comprimido

Una imagen de contenedor no es "un zip de mi aplicación". Es la **interfaz binaria** entre la organización de ingeniería de software y la plataforma de ejecución. Todo lo que viene después — la admisión en Kubernetes, las decisiones de localidad de imagen del scheduler, el escáner de CVE, la traza de auditoría, el procedimiento de rollback — toma el digest de la imagen como clave primaria. De equivocarse en el build se derivan directamente cuatro modos de fallo en producción.

### 1.1 La no reproducibilidad destruye la respuesta a incidentes

A las 03:00, `api:2.7.0` está en crash-loop. Reconstruís desde el tag `v2.7.0` en el nodo de build y el bug desapareció. La imagen que está corriendo se construyó hace seis semanas a partir de un `FROM python:3.12` que resolvió a un digest de base distinto, trajo `requests` de un rango sin fijar, y horneó dentro un snapshot del índice de `pip` que ya no existe. No podés reproducir el artefacto que estás depurando, así que no podés bisecarlo. **La reproducibilidad no es una cuestión estética; es la precondición del diagnóstico diferencial.**

### 1.2 El tamaño es un multiplicador de latencia y de coste en toda la flota

El tamaño de la imagen se paga en cada pull en frío: escalado de nodos, reemplazo de nodos, despliegue de un DaemonSet, recuperación de instancias spot, rotación del cluster autoscaler.

| Imagen | Tamaño comprimido | Pull @ 300 Mb/s | Escalado a 200 nodos (serializado en el registry) | Egress mensual del registry @ 40k pulls |
|---|---:|---:|---:|---:|
| `ubuntu:24.04` + Python + toolchain de build | 1.18 GB | ~31 s | ~236 GB | ~47 TB |
| `python:3.12-slim` solo runtime | 148 MB | ~4 s | ~29 GB | ~5.9 TB |
| `gcr.io/distroless/python3-debian12` | 52 MB | ~1.4 s | ~10 GB | ~2.1 TB |
| Go estático sobre `scratch` | 8.4 MB | ~0.2 s | ~1.7 GB | ~336 GB |

El pull de 31 s no es meramente lento: se suma a tu tiempo de recuperación p99 en cada fallo de nodo, y es la diferencia entre un HPA que absorbe un pico de tráfico y uno que no.

### 1.3 Cada paquete de build es superficie de ataque permanente en runtime

`gcc`, `curl`, `git`, `make`, `apt`, una shell, un gestor de paquetes y la clave SSH que usaste para traer un módulo privado siguen *todos dentro de la imagen* a menos que los hayas excluido deliberadamente — y un `RUN rm -rf` en una capa posterior **no** los elimina, solo los tapa con un whiteout. El blob sigue en el registry, sigue siendo descargable y sigue siendo grepeable.

### 1.4 El nodo de build es el blanco más blando de todo el pipeline

El patrón clásico de CI — montar `/var/run/docker.sock` dentro del contenedor de build — le concede al build **root sobre el nodo**, porque el daemon corre como root y el job de build ya puede arrancar un contenedor privilegiado con `hostPID` y `/` montado. Cualquier `Dockerfile` no confiable, cualquier dependencia comprometida ejecutada durante un `RUN`, y el atacante es dueño de la flota de CI y de todas las credenciales de registry que haya en ella. Por eso el objetivo cubre builders daemonless (Buildah, Kaniko, BuildKit rootless) y por eso "cómo construyo imágenes dentro de Kubernetes sin `privileged: true`" es una pregunta arquitectónica real, tratada en §8.

---

## 2. Qué estás produciendo realmente: el modelo de imagen OCI

Antes de la sintaxis, el artefacto. Una imagen OCI es un **DAG de Merkle direccionado por contenido** almacenado en un registry.

```
index (manifest list)            ← optional; one per multi-arch image
 ├── manifest (linux/amd64)
 │    ├── config  (JSON: env, entrypoint, user, labels, rootfs.diff_ids, history)
 │    └── layers  [blob, blob, blob]   ← gzipped tar archives, ordered
 ├── manifest (linux/arm64)
 └── manifest (unknown/unknown)  ← attestations (SBOM, provenance) when built with buildx
```

Hay dos hashes que se confunden constantemente y al examen le gusta la distinción:

| Término | Hash de | Dónde aparece |
|---|---|---|
| **`digest`** | el blob **comprimido** tal como se almacena en el registry | `layers[].digest` del manifest, `image@sha256:...` |
| **`diff_id`** | el tar **sin comprimir** de esa misma capa | `rootfs.diff_ids[]` de la config de imagen |
| **`chain_id`** | hash acumulado de los diff_ids hasta la capa *n* | la clave de snapshot local del runtime |

Inspeccioná una imagen real sin descargarla:

```
$ skopeo inspect --raw docker://registry.example.com/platform/api:2.7.0 | jq .
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "manifests": [
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:2b7e5a1c9f0a4d6b8e3c1f7a2d94b6e0c5a8f31d47b2e9c60a1f3d8b7c4e2059",
      "size": 1214,
      "platform": { "architecture": "amd64", "os": "linux" }
    },
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:c4a1f83b2d7e05c9a6b41f2e8d30c75a9e1b4d6f8027c3a5e9d1b7f04c68a23e",
      "size": 1214,
      "platform": { "architecture": "arm64", "os": "linux" }
    },
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:7d90b1e4c8a2f36d05b9e7c1a4f82d6039b5e8c7a1d4f60b2e9c3a8d5f741062",
      "size": 840,
      "annotations": {
        "vnd.docker.reference.digest": "sha256:2b7e5a1c9f0a4d6b8e3c1f7a2d94b6e0c5a8f31d47b2e9c60a1f3d8b7c4e2059",
        "vnd.docker.reference.type": "attestation-manifest"
      },
      "platform": { "architecture": "unknown", "os": "unknown" }
    }
  ]
}
```

Y la config — esto es a lo que compilan `ENV`, `USER`, `ENTRYPOINT`, `LABEL`, `WORKDIR`, `EXPOSE` y `HEALTHCHECK`:

```
$ crane config registry.example.com/platform/api:2.7.0 | jq '{config, rootfs, history: (.history|length)}'
{
  "config": {
    "User": "10001:10001",
    "Env": [
      "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
      "PYTHONDONTWRITEBYTECODE=1",
      "PYTHONUNBUFFERED=1",
      "APP_HOME=/app"
    ],
    "Entrypoint": ["/app/.venv/bin/python", "-m", "uvicorn"],
    "Cmd": ["api.main:app", "--host", "0.0.0.0", "--port", "8080"],
    "WorkingDir": "/app",
    "ExposedPorts": { "8080/tcp": {} },
    "Labels": {
      "org.opencontainers.image.revision": "9f3ac21b7d0e4c58a6b1f2e39d47c80512ab6e3f",
      "org.opencontainers.image.source": "https://github.com/example/api",
      "org.opencontainers.image.version": "2.7.0"
    },
    "StopSignal": "SIGTERM"
  },
  "rootfs": {
    "type": "layers",
    "diff_ids": [
      "sha256:8a1f2c0d9b74e35a6c8f01d3b29e7a45c6d80f1b3e2a49c7d5b0f836a1e94c72",
      "sha256:d40c7b1e93a852f6c0b4d17e2a693f8c15d0b7e4a92c36f8d1b05e7a4c39ف..."
    ]
  },
  "history": 11
}
```

**Consecuencia clave:** una imagen es inmutable y se identifica por digest. Un *tag* es un puntero mutable. Todo lo de §13 se deriva de ahí.

---

## 3. El conjunto de instrucciones, con semántica de producción

Usá la directiva de sintaxis en la línea 1 para que el build use un frontend fijado y completo en funcionalidades, sin importar la versión local de Docker:

```dockerfile
# syntax=docker/dockerfile:1.7
```

### 3.1 Qué instrucciones crean capas

| Instrucción | Crea una capa de sistema de ficheros | Notas que muerden en producción |
|---|---|---|
| `FROM` | hereda capas | `FROM x AS name` nombra un stage; un `ARG` antes del primer `FROM` es global |
| `RUN` | **sí** | La mayor fuente individual de bloat y de invalidación de caché |
| `COPY` / `ADD` | **sí** | `ADD` autoextrae tars locales y puede traer URLs/refs de git; preferí `COPY` |
| `WORKDIR` | sí (crea el directorio) | Metadato + `mkdir -p`; usá siempre rutas absolutas |
| `ENV` | no (metadato) | Persiste en el **contenedor en ejecución**; se filtra en `docker inspect` |
| `ARG` | no (metadato) | Solo en tiempo de build, **pero visible en `docker history`** para las líneas `RUN` |
| `LABEL`, `EXPOSE`, `USER`, `VOLUME`, `ENTRYPOINT`, `CMD`, `HEALTHCHECK`, `STOPSIGNAL`, `SHELL`, `ONBUILD` | no | Mutaciones puras del objeto de configuración |

Con BuildKit, las instrucciones que solo generan metadatos son en la práctica gratuitas y *no* son blobs separados; el recuento de capas que ves en `docker history` incluye entradas de metadatos de cero bytes.

### 3.2 `ENTRYPOINT` / `CMD`: la matriz que decide si SIGTERM funciona

```dockerfile
ENTRYPOINT ["/app/server"]        # exec form  → PID 1 is /app/server
ENTRYPOINT /app/server            # shell form → PID 1 is /bin/sh -c, signals are swallowed
```

| `ENTRYPOINT` | `CMD` | Se ejecuta |
|---|---|---|
| ausente | `["nginx","-g","daemon off;"]` | `nginx -g daemon off;` |
| `["/app/server"]` | `["--config","/etc/app.yaml"]` | `/app/server --config /etc/app.yaml` |
| `["/app/server"]` | ausente | `/app/server` |
| shell form `/app/server` | cualquier cosa | `/bin/sh -c "/app/server"` — **`CMD` se ignora** |

**Por qué importa:** en shell form, `/bin/sh` es PID 1. `sh` no reenvía `SIGTERM` a su hijo y no recolecta zombies. Kubernetes envía `SIGTERM`, no pasa nada, y 30 s más tarde expira `terminationGracePeriodSeconds` y el pod recibe `SIGKILL` en mitad de una petición. Síntoma: 502 en cada rollout. Regla: **`ENTRYPOINT` en exec form, siempre**; agregá `tini` (`ENTRYPOINT ["/sbin/tini","--","/app/server"]`) solo cuando tu proceso realmente hace fork de hijos que no va a recolectar.

### 3.3 Ámbito de `ARG` vs `ENV` — una de las tres trampas top del examen

```dockerfile
# syntax=docker/dockerfile:1.7
ARG PY_VERSION=3.12                  # global scope: usable in FROM lines only

FROM python:${PY_VERSION}-slim AS base
ARG PY_VERSION                       # MUST be re-declared to be visible inside the stage
RUN echo "building on ${PY_VERSION}" # without the redeclaration this prints "building on "

ARG BUILD_MODE=release               # stage-scoped, not present at runtime
ENV APP_MODE=${BUILD_MODE}           # promoted to runtime config
```

Build args predefinidos, disponibles en cada stage sin declararlos cuando se usa BuildKit/buildx:

`TARGETPLATFORM` `TARGETOS` `TARGETARCH` `TARGETVARIANT` `BUILDPLATFORM` `BUILDOS` `BUILDARCH` `BUILDVARIANT`, más los args de proxy (`HTTP_PROXY`, `NO_PROXY`, …) que están **excluidos de la clave de caché y de `docker history`**.

### 3.4 Flags de `COPY` que vale la pena conocer

```dockerfile
COPY --chown=10001:10001 --chmod=0550 ./bin/server /app/server
COPY --from=builder /src/dist /app/dist        # from another stage
COPY --from=ghcr.io/aquasecurity/trivy:0.55.0 /usr/local/bin/trivy /usr/local/bin/
COPY --link ./static /app/static               # layer is built independently of its parent
```

`--link` es el flag de mayor apalancamiento y el menos conocido: la capa se crea sin dependencia del estado previo del sistema de ficheros, así que cambiar una capa anterior **no la invalida** y la capa puede reutilizarse entre imágenes. Coste: los directorios padre de la ruta de destino se crean con la propiedad por defecto, así que combinalo con `--chown`.

---

## 4. Mecánica de la caché de capas y el teorema del orden

BuildKit calcula una **clave de caché** por paso de build:

- `RUN`: hash de (clave de caché del paso padre + la cadena literal del comando + los valores de los `ARG` referenciados + las definiciones de mounts).
- `COPY`/`ADD`: hash de (clave del padre + el **checksum de contenido** de cada fichero copiado + destino + flags).

Por lo tanto: **la primera instrucción cuyas entradas cambian invalida ese paso y todos los posteriores.** De ahí el teorema del orden — ordená las instrucciones de menos a más frecuentemente cambiantes.

El error canónico y su corrección:

```dockerfile
# ✗ every source edit re-runs the 90-second dependency install
COPY . /app
RUN pip install -r /app/requirements.txt

# ✓ dependency layer is keyed only on the lockfile
COPY requirements.txt /app/
RUN pip install -r /app/requirements.txt
COPY . /app
```

### 4.1 `.dockerignore` — corrección, no solo velocidad

```gitignore
# .dockerignore
.git
.github
**/__pycache__
**/*.pyc
.venv
node_modules
.env
*.pem
*.key
secrets/
dist/
.pytest_cache
.mypy_cache
Dockerfile*
docker-compose*.yml
README.md
```

Tres efectos separados: (1) la transferencia del contexto se achica — un `.git` de 900 MB deja de viajar al builder en cada build; (2) `COPY . .` deja de empotrar credenciales; (3) la clave de caché de `COPY . .` deja de cambiar cada vez que se regenera un `.pyc`. **Salvedad:** si tu build deriva una versión de `git describe`, excluir `.git` lo rompe; pasá el valor como `--build-arg` en vez de volver a incluir el repositorio.

### 4.2 Backends de caché — cómo elegir uno para CI

| Backend | Sintaxis de exportación | Sobrevive a runners efímeros | Compartible entre runners | Salvedades |
|---|---|---|---|---|
| `inline` | `--cache-to type=inline` | sí (viaja en la imagen) | sí | Solo metadatos; sin capas intermedias de multi-stage |
| `registry` | `--cache-to type=registry,ref=repo/cache,mode=max` | sí | sí | `mode=max` guarda todos los stages; requiere cuota de registry + GC |
| `gha` | `--cache-to type=gha,mode=max` | sí | dentro de un repo | tope de 10 GB por repo, con desalojo LRU |
| `s3` / `azblob` | `--cache-to type=s3,region=…,bucket=…` | sí | sí | Lo mejor para flotas autogestionadas; requiere reglas de ciclo de vida |
| `local` | `--cache-to type=local,dest=/cache` | solo con un volumen persistente | no | Crece sin límite si no hay `mode` + poda |

```
$ docker buildx build \
    --cache-from type=registry,ref=registry.example.com/platform/api/cache \
    --cache-to   type=registry,ref=registry.example.com/platform/api/cache,mode=max \
    --tag registry.example.com/platform/api:2.7.0 --push .
```

### 4.3 Cache mounts: la caché que nunca entra en la imagen

```dockerfile
RUN --mount=type=cache,target=/root/.cache/pip,sharing=locked \
    pip install --require-hashes -r requirements.txt
```

`sharing=locked` serializa los builds concurrentes sobre el mismo mount (lo correcto para gestores de paquetes que no son seguros ante concurrencia); `shared` (por defecto) permite acceso paralelo; `private` le da a cada build su propia copia. El mount existe **solo durante ese `RUN`** y nunca se confirma en una capa.

---

## 5. Builds multi-stage

### 5.1 Servicio en Go → `scratch`, estático, 8 MB, non-root

```dockerfile
# syntax=docker/dockerfile:1.7
ARG GO_VERSION=1.23
ARG ALPINE_VERSION=3.20

FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-alpine${ALPINE_VERSION} AS builder
WORKDIR /src

RUN apk add --no-cache ca-certificates tzdata git

COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download -x

COPY . .

ARG TARGETOS
ARG TARGETARCH
ARG VERSION=dev
ARG REVISION=unknown
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build \
      -trimpath \
      -buildvcs=false \
      -ldflags="-s -w -X main.version=${VERSION} -X main.revision=${REVISION}" \
      -o /out/server ./cmd/server

FROM builder AS test
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go vet ./... && go test -race -count=1 ./...

FROM scratch AS runtime
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /usr/share/zoneinfo /usr/share/zoneinfo
COPY --from=builder --chown=10001:10001 --chmod=0555 /out/server /server

USER 10001:10001
ENV TZ=UTC
EXPOSE 8080
STOPSIGNAL SIGTERM
ENTRYPOINT ["/server"]
CMD ["--listen=:8080"]

LABEL org.opencontainers.image.title="platform-api" \
      org.opencontainers.image.source="https://github.com/example/api" \
      org.opencontainers.image.licenses="Apache-2.0"
```

Tres detalles que separan esto de un `Dockerfile` de tutorial:

- `--platform=$BUILDPLATFORM` en el stage builder fija el *compilador* a la arquitectura nativa y compila cruzado vía `GOARCH`. Sin eso, un build `arm64` en un runner `amd64` ejecuta todo el toolchain de Go bajo emulación QEMU — típicamente **5–20× más lento**.
- `CGO_ENABLED=0` es obligatorio para `scratch`: con cgo, el binario enlaza dinámicamente `libc` y el resolver de Go, y en runtime obtenés `exec /server: no such file or directory` (ver §16).
- En `scratch` no hay `/etc/passwd`, así que `USER 10001:10001` debe ser numérico. Un nombre no podría resolverse.

Construí solo el stage de test en CI sin producir una imagen:

```
$ docker buildx build --target test --progress=plain .
#12 [test 2/2] RUN go vet ./... && go test -race -count=1 ./...
#12 0.412 ok      github.com/example/api/internal/handler 0.183s
#12 1.904 ok      github.com/example/api/internal/store   1.402s
#12 DONE 2.1s
```

### 5.2 Servicio Python → `python:3.12-slim`, virtualenv transportado entre stages

```dockerfile
# syntax=docker/dockerfile:1.7
ARG PY_VERSION=3.12
ARG BASE_DIGEST=sha256:2f8c1e94b0d7a35f6c1b804e2d9a37fb50c6e8143d7b09a2e6c5f1d38b70a49e

FROM python:${PY_VERSION}-slim@${BASE_DIGEST} AS base
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=0 \
    VIRTUAL_ENV=/app/.venv \
    PATH="/app/.venv/bin:$PATH"

FROM base AS builder
RUN apt-get update \
 && apt-get install --no-install-recommends -y build-essential libpq-dev \
 && rm -rf /var/lib/apt/lists/*

RUN python -m venv "$VIRTUAL_ENV"
WORKDIR /app

COPY requirements.txt requirements.lock ./
RUN --mount=type=cache,target=/root/.cache/pip,sharing=locked \
    --mount=type=secret,id=pip_extra_index,env=PIP_EXTRA_INDEX_URL \
    pip install --require-hashes -r requirements.lock

COPY . /app
RUN python -m compileall -q /app/api

FROM base AS runtime
RUN apt-get update \
 && apt-get install --no-install-recommends -y libpq5 \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --gid 10001 app \
 && useradd --uid 10001 --gid 10001 --home-dir /app --no-create-home --shell /usr/sbin/nologin app

WORKDIR /app
COPY --from=builder --chown=10001:10001 /app/.venv /app/.venv
COPY --from=builder --chown=10001:10001 /app/api  /app/api

USER 10001:10001
EXPOSE 8080
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD ["/app/.venv/bin/python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/healthz', timeout=2).status==200 else 1)"]
ENTRYPOINT ["/app/.venv/bin/python", "-m", "uvicorn"]
CMD ["api.main:app", "--host", "0.0.0.0", "--port", "8080", "--no-access-log"]
```

`build-essential` y `libpq-dev` (≈ 420 MB) existen solo en `builder`; `runtime` se queda con `libpq5` (≈ 1 MB). Fijate en el `HEALTHCHECK` en exec form — Kubernetes ignora los `HEALTHCHECK` de la imagen (usa probes), pero Docker, Compose y Nomad los respetan, y `docker inspect --format '{{.State.Health.Status}}'` es una respuesta legítima de examen.

### 5.3 El grafo de build es paralelo

BuildKit resuelve los stages como un DAG y ejecuta las ramas independientes de forma concurrente:

```
$ docker buildx build --progress=plain -t app:ci .
#7  [frontend 3/4] RUN npm ci --omit=dev        ...  DONE 22.4s
#9  [backend  3/4] RUN go build -o /out/server  ...  DONE 19.8s   ← ran in parallel with #7
#12 [runtime  4/6] COPY --from=frontend /ui/dist /app/static  DONE 0.3s
```

El tiempo de reloj es el camino más largo, no la suma de los stages. Esta es una razón real para preferir BuildKit al builder legacy en monorepos.

---

## 6. Elección de la imagen base

| Base | Tamaño típico | libc | Shell / gestor de paquetes | Non-root por defecto | Mejor para | Riesgo principal |
|---|---:|---|---|---|---|---|
| `scratch` | 0 B | ninguna | ninguno | lo definís vos | Go/Rust estático | Sin CA certs, sin `/etc/passwd`, sin datos de TZ, sin `nsswitch` |
| `gcr.io/distroless/static-debian12:nonroot` | ~2 MB | ninguna | ninguno | **sí (65532)** | Binarios estáticos con certs+TZ incluidos | No podés hacer `exec` para depurar (usá el tag `:debug`) |
| `gcr.io/distroless/cc-debian12` | ~22 MB | glibc | ninguno | tag opcional | cgo, Rust con `libgcc` | Sin shell para probes |
| `cgr.dev/chainguard/static` (Wolfi) | ~2 MB | ninguna | ninguno | sí | Postura de bajo CVE, rebuilds diarios | Tags que se mueven rápido; fijá digests |
| `alpine:3.20` | ~7.8 MB | **musl** | `ash` + `apk` | no | Imágenes pequeñas de ops | musl ≠ glibc — ver abajo |
| `debian:12-slim` | ~29 MB | glibc | `bash` + `apt` | no | Cualquier cosa con glibc | Requiere adelgazado manual |
| `python:3.12-slim` | ~48 MB de base | glibc | sí | no | Servicios Python | Lleva pip/setuptools al runtime |
| `registry.access.redhat.com/ubi9/ubi-micro` | ~12 MB | glibc | ninguno (instalás desde el host con `dnf --installroot`) | no | Parques con soporte RHEL | Requiere la mecánica de suscripción UBI para los repos completos |

**La trampa de musl, en concreto.** Alpine usa musl, no glibc. Consecuencias que vas a encontrar en producción:

- Las wheels de Python se construyen como `manylinux` (glibc); en Alpine `pip` cae a compilar desde fuente, así que una instalación de 20 segundos se vuelve una de 12 minutos — y necesita `gcc`, que después hay que purgar.
- Cualquier binario de proveedor enlazado contra glibc falla con `Error loading shared library libc.musl-x86_64.so.1` o `not found` desde `ldd`.
- El resolver de musl históricamente difiere del de glibc en el manejo de search domains y en el fallback a TCP para respuestas de más de 512 bytes — el clásico incidente de "el DNS solo falla de forma intermitente en los pods de Alpine".

Alpine es una base excelente para un binario estático o una caja de herramientas de ops. Es una mala opción por defecto para un servicio Python o Node con extensiones nativas.

---

## 7. Comparativa de builders

| Builder | Daemon | Requiere root | Rootless | Compatible con `Dockerfile` | Multi-arch nativo | Caché | Dónde encaja |
|---|---|---|---|---|---|---|---|
| `docker build` (BuildKit) | dockerd | el daemon corre como root | con Docker rootless | sí | vía buildx | la mejor de su clase | Estaciones de trabajo de desarrollo |
| `docker buildx` (driver `docker-container`) | buildkitd en contenedor | no (imagen rootless) | sí | sí | **sí** (QEMU o pool de nodos) | registry/gha/s3/local | CI, builds de release multi-arch |
| `buildctl` + buildkitd remoto | buildkitd compartido | no | sí | sí | sí | compartida entre todos los jobs de CI | Servicio central de build en K8s |
| `podman build` / `buildah bud` | **ninguno** | no | **sí** (user namespaces) | sí | vía `--platform` + qemu-user-static | caché de capas con `--layers` | Hosts Fedora/RHEL, CI rootless |
| `buildah` en modo script | ninguno | no | sí | n/a (script de shell) | sí | manual | Builds que no encajan en el modelo `Dockerfile` |
| **Kaniko** | ninguno | root **dentro** del contenedor | no (necesita root en el contenedor) | sí | una arquitectura por ejecución | `--cache-repo` | Jobs de Kubernetes, sin privileged |
| **Cloud Native Buildpacks** (`pack`) | Docker o `--trust-builder` | depende del driver | con un driver rootless | **sin Dockerfile en absoluto** | depende del builder | lifecycle `restore`/`analyze` | Equipos de plataforma estandarizando 200 apps |
| **`ko`** (solo Go) | ninguno | no | sí | no | **sí, incorporado** | caché de build de Go | Microservicios en Go, GitOps |
| **Jib** (Java) | ninguno | no | sí | no | sí | consciente de Maven/Gradle | Tiendas JVM |
| **Bazel `rules_oci`** | ninguno | no | sí | no | sí | hermética, basada en contenido | Monorepos que exigen hermeticidad |

**Heurísticas de selección.** Un solo lenguaje y una convención fuerte → `ko`/Jib/Buildpacks (sin `Dockerfile` que mantener, imagen base parcheada con `rebase` sin reconstruir). Parque heterogéneo → BuildKit como servicio compartido. CI nativo de Kubernetes donde no podés conceder `privileged` ni correr un servicio compartido → Kaniko o Buildah con `vfs`. Hosts Linux rootless y sin daemon permitido → Podman/Buildah.

**Salvedad de Kaniko que conviene decir sin rodeos:** corre como *root dentro del contenedor* y desempaqueta cada capa base en el propio sistema de ficheros raíz del contenedor. Elimina la necesidad de `privileged` y del socket de docker, pero no es un sandbox — nunca ejecutes `Dockerfile`s no confiables con él en un nodo compartido sin gVisor/Kata o un pool de nodos dedicado.

---

## 8. Construir imágenes dentro de Kubernetes sin `privileged`

### 8.1 BuildKit rootless como servicio de build compartido

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: build
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: buildkitd
  namespace: build
---
apiVersion: v1
kind: Service
metadata:
  name: buildkitd
  namespace: build
spec:
  clusterIP: None
  selector:
    app: buildkitd
  ports:
    - name: grpc
      port: 1234
      targetPort: 1234
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: buildkitd
  namespace: build
spec:
  serviceName: buildkitd
  replicas: 3
  podManagementPolicy: Parallel
  selector:
    matchLabels:
      app: buildkitd
  template:
    metadata:
      labels:
        app: buildkitd
      annotations:
        container.apparmor.security.beta.kubernetes.io/buildkitd: unconfined
    spec:
      serviceAccountName: buildkitd
      automountServiceAccountToken: false
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        runAsNonRoot: true
        seccompProfile:
          type: Unconfined          # rootlesskit needs unrestricted clone()/unshare()
      containers:
        - name: buildkitd
          image: moby/buildkit:v0.16.0-rootless
          args:
            - --addr
            - unix:///home/user/.local/share/buildkit/buildkitd.sock
            - --addr
            - tcp://0.0.0.0:1234
            - --tlscacert=/certs/ca.pem
            - --tlscert=/certs/cert.pem
            - --tlskey=/certs/key.pem
            - --oci-worker-no-process-sandbox
            - --config=/etc/buildkit/buildkitd.toml
          ports:
            - name: grpc
              containerPort: 1234
          readinessProbe:
            exec:
              command: ["buildctl", "debug", "workers"]
            initialDelaySeconds: 5
            periodSeconds: 30
          livenessProbe:
            exec:
              command: ["buildctl", "debug", "workers"]
            initialDelaySeconds: 15
            periodSeconds: 60
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: false
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: "2"
              memory: 4Gi
              ephemeral-storage: 20Gi
            limits:
              cpu: "8"
              memory: 16Gi
              ephemeral-storage: 80Gi
          volumeMounts:
            - name: buildkitd-state
              mountPath: /home/user/.local/share/buildkit
            - name: certs
              mountPath: /certs
              readOnly: true
            - name: config
              mountPath: /etc/buildkit
              readOnly: true
      volumes:
        - name: certs
          secret:
            secretName: buildkit-daemon-certs
        - name: config
          configMap:
            name: buildkitd-config
  volumeClaimTemplates:
    - metadata:
        name: buildkitd-state
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: fast-ssd
        resources:
          requests:
            storage: 200Gi
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: buildkitd-config
  namespace: build
data:
  buildkitd.toml: |
    debug = false
    insecure-entitlements = []

    [worker.oci]
      enabled = true
      snapshotter = "overlayfs"
      gc = true
      gckeepstorage = "120GB"
      max-parallelism = 4

      [[worker.oci.gcpolicy]]
        keepBytes = "20GB"
        keepDuration = "48h"
        filters = ["type==source.local", "type==exec.cachemount"]
      [[worker.oci.gcpolicy]]
        all = true
        keepBytes = "120GB"

    [registry."registry.example.com"]
      mirrors = ["registry-mirror.build.svc.cluster.local:5000"]
    [registry."docker.io"]
      mirrors = ["registry-mirror.build.svc.cluster.local:5000"]
```

Tres puntos que le importan tanto al examen como a la realidad:

- **`--oci-worker-no-process-sandbox`** deshabilita el sandbox de procesos anidado, que es lo que permite a buildkitd correr sin `CAP_SYS_ADMIN`. Compromiso: los builds comparten el aislamiento de namespaces del pod, así que un inquilino por pool de builders.
- **`seccompProfile: Unconfined` + AppArmor `unconfined`** son necesarios porque `rootlesskit` llama a `unshare(CLONE_NEWUSER|CLONE_NEWNS)`; los perfiles por defecto lo bloquean. Esto es *menos* privilegio que `privileged: true`, no más, pero debe ser una decisión consciente registrada en tus excepciones de política.
- El **`StatefulSet` + PVC** es deliberado: una caché de build tiene estado, y perderla convierte un build de 40 segundos en uno de 8 minutos.

Del lado del cliente:

```
$ buildctl --addr tcp://buildkitd.build.svc.cluster.local:1234 \
    --tlscacert /certs/ca.pem --tlscert /certs/client.pem --tlskey /certs/client-key.pem \
    build \
    --frontend dockerfile.v0 \
    --local context=. \
    --local dockerfile=./build \
    --opt filename=Dockerfile \
    --opt build-arg:VERSION=2.7.0 \
    --opt platform=linux/amd64,linux/arm64 \
    --secret id=pip_extra_index,src=/tmp/pip_index \
    --output type=image,\"name=registry.example.com/platform/api:2.7.0\",push=true \
    --export-cache type=registry,ref=registry.example.com/platform/api/cache,mode=max \
    --import-cache type=registry,ref=registry.example.com/platform/api/cache
```

### 8.2 Job de Kaniko — un build, sin daemon, sin privileged

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: build-api-2-7-0
  namespace: build
spec:
  backoffLimit: 1
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app.kubernetes.io/name: kaniko
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      nodeSelector:
        workload: build
      tolerations:
        - key: dedicated
          operator: Equal
          value: build
          effect: NoSchedule
      containers:
        - name: kaniko
          image: gcr.io/kaniko-project/executor:v1.23.2
          args:
            - --context=git://github.com/example/api.git#refs/tags/v2.7.0
            - --dockerfile=build/Dockerfile
            - --destination=registry.example.com/platform/api:2.7.0
            - --destination=registry.example.com/platform/api:latest
            - --digest-file=/dev/termination-log
            - --cache=true
            - --cache-repo=registry.example.com/platform/api/cache
            - --cache-ttl=168h
            - --snapshot-mode=redo
            - --use-new-run
            - --push-retry=3
            - --image-fs-extract-retry=2
            - --build-arg=VERSION=2.7.0
            - --label=org.opencontainers.image.revision=9f3ac21b7d0e4c58a6b1f2e39d47c80512ab6e3f
            - --reproducible
          env:
            - name: GIT_TOKEN
              valueFrom:
                secretKeyRef:
                  name: git-credentials
                  key: token
          resources:
            requests:
              cpu: "2"
              memory: 4Gi
              ephemeral-storage: 30Gi
            limits:
              cpu: "4"
              memory: 8Gi
              ephemeral-storage: 60Gi
          volumeMounts:
            - name: docker-config
              mountPath: /kaniko/.docker
              readOnly: true
      volumes:
        - name: docker-config
          secret:
            secretName: registry-credentials
            items:
              - key: .dockerconfigjson
                path: config.json
```

`--snapshot-mode=redo` hashea los metadatos de los ficheros en lugar del contenido completo (mucho más rápido en árboles grandes); `--reproducible` elimina las marcas de tiempo para que entradas idénticas den un digest idéntico — a costa de descartar el histórico `created` de las capas.

### 8.3 Job de Buildah — rootless, `fuse-overlayfs`

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: buildah-api
  namespace: build
spec:
  backoffLimit: 1
  template:
    metadata:
      annotations:
        container.apparmor.security.beta.kubernetes.io/buildah: unconfined
    spec:
      restartPolicy: Never
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: Unconfined
      containers:
        - name: buildah
          image: quay.io/buildah/stable:v1.37
          command: ["/bin/bash", "-c"]
          args:
            - |
              set -euo pipefail
              buildah --storage-driver vfs bud \
                --isolation chroot \
                --format oci \
                --layers \
                --build-arg VERSION="${VERSION}" \
                --label org.opencontainers.image.revision="${GIT_SHA}" \
                -f build/Dockerfile \
                -t "${IMAGE}" .
              buildah --storage-driver vfs push \
                --authfile /auth/config.json \
                "${IMAGE}" "docker://${IMAGE}"
          env:
            - name: IMAGE
              value: registry.example.com/platform/api:2.7.0
            - name: VERSION
              value: "2.7.0"
            - name: GIT_SHA
              value: 9f3ac21b7d0e4c58a6b1f2e39d47c80512ab6e3f
            - name: STORAGE_DRIVER
              value: vfs
            - name: BUILDAH_ISOLATION
              value: chroot
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: workspace
              mountPath: /workspace
            - name: containers-storage
              mountPath: /home/build/.local/share/containers
            - name: auth
              mountPath: /auth
              readOnly: true
          resources:
            requests: { cpu: "2", memory: 4Gi, ephemeral-storage: 40Gi }
            limits:   { cpu: "4", memory: 8Gi, ephemeral-storage: 80Gi }
      volumes:
        - name: workspace
          emptyDir: {}
        - name: containers-storage
          emptyDir:
            sizeLimit: 40Gi
        - name: auth
          secret:
            secretName: registry-credentials
            items:
              - key: .dockerconfigjson
                path: config.json
```

`vfs` es la salida de emergencia por compatibilidad: copia todo el sistema de ficheros para cada capa en vez de usar overlay, así que no necesita **ni `/dev/fuse`, ni mapeo de user namespaces, ni ninguna capability extra** — pero el uso de disco y el tiempo de build escalan con el número de capas. Si tus nodos exponen `/dev/fuse` (device plugin o `hostPath`), pasate a `--storage-driver overlay` con `fuse-overlayfs` y los builds se vuelven 3–10× más rápidos.

### 8.4 Buildah en modo script — cuando el modelo `Dockerfile` no encaja

```bash
#!/usr/bin/env bash
set -euo pipefail

ctr=$(buildah from registry.access.redhat.com/ubi9/ubi-micro:9.4)
mnt=$(buildah mount "$ctr")

# Install into the mounted rootfs using the HOST's package manager.
dnf install --installroot "$mnt" --releasever 9 --setopt=install_weak_deps=false \
    -y python3.12 && dnf clean all --installroot "$mnt"

install -m 0755 ./dist/server "$mnt/usr/local/bin/server"

buildah config \
  --entrypoint '["/usr/local/bin/server"]' \
  --cmd '["--listen=:8080"]' \
  --port 8080 \
  --user 10001:10001 \
  --env APP_MODE=production \
  --label org.opencontainers.image.version=2.7.0 \
  --annotation org.opencontainers.image.created="$(date -u -d @"${SOURCE_DATE_EPOCH}" +%Y-%m-%dT%H:%M:%SZ)" \
  "$ctr"

buildah umount "$ctr"
buildah commit --format oci --squash "$ctr" registry.example.com/platform/api:2.7.0
buildah rm "$ctr"
```

Esta es la respuesta a "instalar RPMs en una imagen base que no tiene gestor de paquetes" — imposible con un `Dockerfile`, trivial con `buildah mount`.

---

## 9. Builds multiarquitectura

```
$ docker buildx create --name multi --driver docker-container \
    --driver-opt image=moby/buildkit:v0.16.0,network=host --use
multi

$ docker buildx inspect --bootstrap
Name:          multi
Driver:        docker-container
Nodes:
Name:          multi0
Endpoint:      unix:///var/run/docker.sock
Status:        running
BuildKit:      v0.16.0
Platforms:     linux/amd64, linux/amd64/v2, linux/amd64/v3, linux/386,
               linux/arm64, linux/riscv64, linux/ppc64le, linux/s390x, linux/arm/v7, linux/arm/v6
```

Las plataformas no nativas se ejecutan a través de QEMU registrado en `binfmt_misc`. Registralo una vez por host:

```
$ docker run --privileged --rm tonistiigi/binfmt --install arm64,arm
installing: arm64 OK
installing: arm OK
{ "supported": ["linux/amd64","linux/arm64","linux/arm/v7","linux/arm/v6"], "emulators": ["qemu-aarch64","qemu-arm"] }
```

| Estrategia | Velocidad | Fidelidad | Coste de puesta en marcha |
|---|---|---|---|
| Compilación cruzada (`--platform=$BUILDPLATFORM` + `GOARCH`/`--target`) | La más rápida | Binarios nativos, sin bugs de emulación | Solo funciona con toolchains capaces de cross-compilar |
| Emulación QEMU | 5–20× más lenta; algún `Illegal instruction` ocasional en JITs | Ejecuta cualquier cosa | Una instalación de `binfmt` |
| Nodos nativos remotos (`buildx create --append`) | Velocidad nativa en ambas arquitecturas | La más alta | Requiere una flota de build arm64 |

Builder nativo multinodo:

```
$ docker buildx create --name fleet --node amd64 --platform linux/amd64 ssh://build@runner-amd64
$ docker buildx create --name fleet --append --node arm64 --platform linux/arm64 ssh://build@runner-arm64
$ docker buildx build --builder fleet --platform linux/amd64,linux/arm64 -t registry.example.com/platform/api:2.7.0 --push .
```

### 9.1 `docker-bake.hcl` — el grafo de build como código

```hcl
variable "REGISTRY" { default = "registry.example.com/platform" }
variable "VERSION"  { default = "dev" }
variable "REVISION" { default = "unknown" }
variable "SOURCE_DATE_EPOCH" { default = "1735689600" }

group "default" {
  targets = ["api", "worker"]
}

target "_common" {
  context    = "."
  dockerfile = "build/Dockerfile"
  platforms  = ["linux/amd64", "linux/arm64"]
  args = {
    VERSION           = VERSION
    REVISION          = REVISION
    SOURCE_DATE_EPOCH = SOURCE_DATE_EPOCH
  }
  labels = {
    "org.opencontainers.image.version"  = VERSION
    "org.opencontainers.image.revision" = REVISION
    "org.opencontainers.image.source"   = "https://github.com/example/api"
    "org.opencontainers.image.licenses" = "Apache-2.0"
  }
  attest = [
    "type=provenance,mode=max",
    "type=sbom"
  ]
  output = ["type=image,push=true,rewrite-timestamp=true"]
}

target "api" {
  inherits = ["_common"]
  target   = "runtime"
  tags = [
    "${REGISTRY}/api:${VERSION}",
    "${REGISTRY}/api:latest"
  ]
  cache-from = ["type=registry,ref=${REGISTRY}/api/cache"]
  cache-to   = ["type=registry,ref=${REGISTRY}/api/cache,mode=max"]
}

target "worker" {
  inherits   = ["_common"]
  dockerfile = "build/Dockerfile.worker"
  target     = "runtime"
  tags       = ["${REGISTRY}/worker:${VERSION}"]
  cache-from = ["type=registry,ref=${REGISTRY}/worker/cache"]
  cache-to   = ["type=registry,ref=${REGISTRY}/worker/cache,mode=max"]
}

target "test" {
  inherits = ["_common"]
  target   = "test"
  output   = ["type=cacheonly"]
  platforms = ["linux/amd64"]
}
```

```
$ VERSION=2.7.0 REVISION=$(git rev-parse HEAD) docker buildx bake --print api
$ VERSION=2.7.0 REVISION=$(git rev-parse HEAD) docker buildx bake test api
```

---

## 10. Builds reproducibles

Tres fuentes de no determinismo, y la solución para cada una:

| Fuente | Efecto | Solución |
|---|---|---|
| mtimes de ficheros dentro de las capas | El digest cambia en cada build | `SOURCE_DATE_EPOCH` + `rewrite-timestamp=true` |
| `created` en la config de la imagen | El digest cambia | Lo mismo; o `--reproducible` de Kaniko |
| Tag base o repos de paquetes sin fijar | Contenido completamente distinto | Fijá `FROM …@sha256:`, usá lockfiles con hashes, fijá snapshots de apt/apk |

```
$ export SOURCE_DATE_EPOCH=$(git log -1 --pretty=%ct)
$ docker buildx build \
    --build-arg SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
    --output type=image,name=registry.example.com/platform/api:2.7.0,push=true,rewrite-timestamp=true \
    --provenance=mode=max --sbom=true .
```

Verificación — construí dos veces, en dos hosts distintos, y compará digests:

```
$ crane digest registry.example.com/platform/api:2.7.0
sha256:9f1c47ad0b3e6528c1a94f70d8b23e6a5c07f4d19b8e6203a7c5d1f84b09e376

$ crane digest registry.example.com/platform/api:2.7.0-rebuild
sha256:9f1c47ad0b3e6528c1a94f70d8b23e6a5c07f4d19b8e6203a7c5d1f84b09e376
# identical → the build is reproducible; the artifact is now falsifiable evidence
```

Si difieren, hacé diff de las configs para encontrar qué perilla se movió:

```
$ diff <(crane config .../api:2.7.0 | jq -S .) <(crane config .../api:2.7.0-rebuild | jq -S .)
```

---

## 11. Secretos durante el build

### 11.1 Las cuatro formas incorrectas

```dockerfile
ENV NPM_TOKEN=abc123                    # ✗ persists in the image config, visible to any puller
ARG NPM_TOKEN                           # ✗ appears verbatim in `docker history` on every RUN line
COPY .npmrc /root/.npmrc                # ✗ committed to a layer; `rm` later does NOT remove the blob
RUN echo "$KEY" > /k && use /k && rm /k # ✗ the blob still contains /k
```

### 11.2 La forma correcta — mounts de tipo secret y ssh de BuildKit

```dockerfile
# syntax=docker/dockerfile:1.7
RUN --mount=type=secret,id=npmrc,target=/root/.npmrc,mode=0400 \
    npm ci --omit=dev

RUN --mount=type=secret,id=aws,env=AWS_SECRET_ACCESS_KEY \
    aws s3 cp s3://artifacts/blob.tar.gz /tmp/

RUN --mount=type=ssh,id=default \
    git clone git@github.com:example/private-lib.git /src/lib
```

```
$ docker buildx build \
    --secret id=npmrc,src=$HOME/.npmrc \
    --secret id=aws,env=AWS_SECRET_ACCESS_KEY \
    --ssh default=$SSH_AUTH_SOCK \
    -t app:2.7.0 .
```

El secreto es un mount tmpfs visible solo durante la duración de ese `RUN`; nunca se convierte en capa, nunca entra en el contenido de la clave de caché y nunca llega al registry.

### 11.3 Demostrar que no hay filtración

```
$ skopeo copy docker://registry.example.com/platform/api:2.7.0 oci:/tmp/api:2.7.0
Getting image source signatures
Copying blob 8a1f2c0d9b74 done
Copying blob d40c7b1e93a8 done
Copying config 5e2b09fa73 done
Writing manifest to image destination

$ for b in /tmp/api/blobs/sha256/*; do
>   if tar -tzf "$b" 2>/dev/null | grep -Eq '(^|/)(\.npmrc|\.git-credentials|id_rsa|\.env)$'; then
>     echo "LEAK in blob $b"; tar -tzf "$b" | grep -E '\.npmrc|id_rsa|\.env'
>   fi
> done
# (no output = clean)

$ docker history --no-trunc --format '{{.CreatedBy}}' api:2.7.0 | grep -iE 'token|passwd|secret|key='
# (no output = no build-arg leakage in the config history)
```

Contrastalo con un build roto a propósito — esta es la firma de fallo que buscás durante una revisión:

```
$ docker history --no-trunc --format '{{.CreatedBy}}' api:leaky | head -3
|1 NPM_TOKEN=npm_9fA2kQ7xLm0pRt4vZc RUN /bin/sh -c npm ci --omit=dev # buildkit
```

---

## 12. Metadatos, SBOM, provenance y firma

Anotaciones estándar — usalas; los escáneres, el tooling de GitOps y los catálogos estilo `Backstage` las leen:

```dockerfile
LABEL org.opencontainers.image.title="platform-api" \
      org.opencontainers.image.description="Public order-intake API" \
      org.opencontainers.image.source="https://github.com/example/api" \
      org.opencontainers.image.documentation="https://docs.example.com/api" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.vendor="Example S.A." \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.created="${BUILD_DATE}"
```

Generá attestations en tiempo de build y volvé a leerlas:

```
$ docker buildx build --provenance=mode=max --sbom=true -t registry.example.com/platform/api:2.7.0 --push .

$ docker buildx imagetools inspect registry.example.com/platform/api:2.7.0 \
    --format '{{ json .SBOM.SPDX.packages }}' | jq -r '.[].name' | head -5
ca-certificates
libc6
libssl3
python3.12-minimal
tzdata

$ docker buildx imagetools inspect registry.example.com/platform/api:2.7.0 \
    --format '{{ json .Provenance.SLSA.invocation.configSource }}'
{
  "uri": "https://github.com/example/api@refs/tags/v2.7.0",
  "digest": {"sha1": "9f3ac21b7d0e4c58a6b1f2e39d47c80512ab6e3f"},
  "entryPoint": "build/Dockerfile"
}
```

Escaneá y firmá, y después aplicalo en la admisión:

```
$ trivy image --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 \
    registry.example.com/platform/api:2.7.0
registry.example.com/platform/api:2.7.0 (debian 12.6)
Total: 0 (HIGH: 0, CRITICAL: 0)

$ cosign sign --yes \
    registry.example.com/platform/api@sha256:9f1c47ad0b3e6528c1a94f70d8b23e6a5c07f4d19b8e6203a7c5d1f84b09e376
Generating ephemeral keys...
Retrieving signed certificate...
tlog entry created with index: 148392017

$ cosign verify \
    --certificate-identity-regexp='^https://github\.com/example/api/\.github/workflows/.+@refs/tags/v.+$' \
    --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
    registry.example.com/platform/api@sha256:9f1c47ad... | jq '.[0].optional.Subject'
"https://github.com/example/api/.github/workflows/release.yaml@refs/tags/v2.7.0"
```

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-signed-platform-images
spec:
  validationFailureAction: Enforce
  background: false
  webhookTimeoutSeconds: 30
  rules:
    - name: verify-cosign-signature
      match:
        any:
          - resources:
              kinds: ["Pod"]
              namespaces: ["prod-*"]
      verifyImages:
        - imageReferences:
            - "registry.example.com/platform/*"
          mutateDigest: true          # rewrites the tag to the resolved digest
          verifyDigest: true
          required: true
          attestors:
            - count: 1
              entries:
                - keyless:
                    subject: "https://github.com/example/api/.github/workflows/release.yaml@refs/tags/*"
                    issuer: "https://token.actions.githubusercontent.com"
                    rekor:
                      url: https://rekor.sigstore.dev
```

`mutateDigest: true` es el rédito operativo de todo lo anterior: la especificación del pod que llega a etcd nombra un digest, así que la carga de trabajo queda fijada al artefacto exacto que firmaste.

---

## 13. Mecánica de los registries

```
$ docker login registry.example.com -u ci-bot --password-stdin < /run/secrets/registry_token
Login Succeeded

$ docker push registry.example.com/platform/api:2.7.0
The push refers to repository [registry.example.com/platform/api]
d40c7b1e93a8: Pushed
8a1f2c0d9b74: Layer already exists
2.7.0: digest: sha256:9f1c47ad0b3e6528c1a94f70d8b23e6a5c07f4d19b8e6203a7c5d1f84b09e376 size: 1214
```

`Layer already exists` es el direccionamiento por contenido en acción: el registry responde a un `HEAD /v2/<name>/blobs/<digest>` y el cliente se salta la subida por completo. Por eso compartir capas base es una optimización de ancho de banda y almacenamiento en todo tu parque — y por eso cambiar de imagen base por equipo sale caro.

| Forma de referencia | Mutable | Usala para |
|---|---|---|
| `api:latest` | sí | Nunca en producción |
| `api:2.7.0` | sí (un tag puede volver a publicarse) | Identidad de release de cara a humanos |
| `api@sha256:9f1c…` | **no** | Despliegues, líneas `FROM`, forense de incidentes |

Reetiquetar sin descargar las capas (el camino de promoción barato y correcto de staging a prod):

```
$ crane copy registry.example.com/staging/api:2.7.0 registry.example.com/platform/api:2.7.0
2026/09/03 11:42:07 Copying from registry.example.com/staging/api:2.7.0 to registry.example.com/platform/api:2.7.0
2026/09/03 11:42:08 existing blob: sha256:8a1f2c0d9b74…
2026/09/03 11:42:09 pushed blob: sha256:d40c7b1e93a8…
2026/09/03 11:42:09 registry.example.com/platform/api:2.7.0: digest: sha256:9f1c47ad… size: 1214
```

Habilitá tags inmutables en el registry (Harbor, ECR, GAR y Quay lo soportan). Sin eso, "hicimos rollback a 2.6.0 y el bug seguía ahí" es un desenlace que tarde o temprano vas a vivir.

---

## 14. Cloud Native Buildpacks — construir sin `Dockerfile`

```
$ pack build registry.example.com/platform/api:2.7.0 \
    --builder paketobuildpacks/builder-jammy-base \
    --env BP_JVM_VERSION=21 \
    --env BP_OCI_SOURCE=https://github.com/example/api \
    --cache-image registry.example.com/platform/api/pack-cache \
    --publish
jammy-base: Pulling from paketobuildpacks/builder
===> ANALYZING
Restoring metadata for "paketo-buildpacks/ca-certificates:helper" from app image
===> DETECTING
5 of 12 buildpacks participating
paketo-buildpacks/ca-certificates 3.8.3
paketo-buildpacks/bellsoft-liberica 10.7.2
paketo-buildpacks/syft            1.44.0
paketo-buildpacks/gradle           7.6.1
paketo-buildpacks/executable-jar   6.9.1
===> RESTORING
===> BUILDING
===> EXPORTING
Adding layer 'paketo-buildpacks/ca-certificates:helper'
Adding layer 'launch.sbom'
Setting default process type 'web'
Saving registry.example.com/platform/api:2.7.0...
*** Images (sha256:41c9e0d7…):
      registry.example.com/platform/api:2.7.0
Successfully built image registry.example.com/platform/api:2.7.0
```

El lifecycle ejecuta `detect → analyze → restore → build → export`. La funcionalidad estrella es `rebase`: cuando la imagen de ejecución se parchea por un CVE, intercambiás las capas base sin recompilar la aplicación.

```
$ pack rebase registry.example.com/platform/api:2.7.0 --run-image paketobuildpacks/run-jammy-base:latest --publish
Rebasing registry.example.com/platform/api:2.7.0 on run image paketobuildpacks/run-jammy-base:latest
Saving registry.example.com/platform/api:2.7.0...
*** Images (sha256:7bd214ac…):
      registry.example.com/platform/api:2.7.0
Rebased Image: sha256:7bd214ac…
```

| Dimensión | `Dockerfile` | Buildpacks |
|---|---|---|
| Control | Total | Limitado a las convenciones del buildpack |
| Consistencia entre 200 apps | Depende de la disciplina | La impone la imagen del builder |
| Parche de CVE en la base | Reconstruir cada imagen | `pack rebase` — segundos, sin necesidad del código fuente |
| SBOM | Lo agregás vos | Lo emite el lifecycle |
| Necesidades de runtime inusuales | Trivial | Puede requerir un buildpack a medida |
| Curva de aprendizaje para los equipos de app | Alta | Casi nula (`pack build`, sin fichero) |

---

## 15. Pipelines de CI, completos

### 15.1 GitHub Actions — multi-arch, con caché, con attestations y firmado

```yaml
name: release
on:
  push:
    tags: ["v*"]

permissions:
  contents: read
  packages: write
  id-token: write        # required for cosign keyless (OIDC)

jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Compute build metadata
        id: meta
        run: |
          echo "version=${GITHUB_REF_NAME#v}" >> "$GITHUB_OUTPUT"
          echo "revision=$(git rev-parse HEAD)" >> "$GITHUB_OUTPUT"
          echo "source_date_epoch=$(git log -1 --pretty=%ct)" >> "$GITHUB_OUTPUT"

      - uses: docker/setup-qemu-action@v3
        with:
          platforms: arm64

      - uses: docker/setup-buildx-action@v3
        with:
          driver-opts: image=moby/buildkit:v0.16.0

      - uses: docker/login-action@v3
        with:
          registry: registry.example.com
          username: ${{ secrets.REGISTRY_USER }}
          password: ${{ secrets.REGISTRY_TOKEN }}

      - name: Build and push
        id: build
        uses: docker/build-push-action@v6
        env:
          SOURCE_DATE_EPOCH: ${{ steps.meta.outputs.source_date_epoch }}
        with:
          context: .
          file: build/Dockerfile
          target: runtime
          platforms: linux/amd64,linux/arm64
          push: true
          provenance: mode=max
          sbom: true
          outputs: type=image,rewrite-timestamp=true
          tags: |
            registry.example.com/platform/api:${{ steps.meta.outputs.version }}
            registry.example.com/platform/api:latest
          build-args: |
            VERSION=${{ steps.meta.outputs.version }}
            REVISION=${{ steps.meta.outputs.revision }}
          labels: |
            org.opencontainers.image.version=${{ steps.meta.outputs.version }}
            org.opencontainers.image.revision=${{ steps.meta.outputs.revision }}
            org.opencontainers.image.source=${{ github.server_url }}/${{ github.repository }}
          secrets: |
            pip_extra_index=${{ secrets.PIP_EXTRA_INDEX_URL }}
          cache-from: type=gha,scope=api
          cache-to: type=gha,scope=api,mode=max

      - name: Scan
        uses: aquasecurity/trivy-action@0.24.0
        with:
          image-ref: registry.example.com/platform/api@${{ steps.build.outputs.digest }}
          severity: HIGH,CRITICAL
          ignore-unfixed: true
          exit-code: "1"

      - uses: sigstore/cosign-installer@v3
      - name: Sign
        run: |
          cosign sign --yes \
            "registry.example.com/platform/api@${{ steps.build.outputs.digest }}"
```

### 15.2 GitLab CI — Kaniko, sin socket de docker

```yaml
stages: [build, scan, sign]

variables:
  IMAGE: $CI_REGISTRY_IMAGE
  CACHE_REPO: $CI_REGISTRY_IMAGE/cache

build:image:
  stage: build
  image:
    name: gcr.io/kaniko-project/executor:v1.23.2-debug
    entrypoint: [""]
  script:
    - |
      cat > /kaniko/.docker/config.json <<EOF
      { "auths": { "${CI_REGISTRY}": { "auth": "$(printf '%s:%s' "${CI_REGISTRY_USER}" "${CI_REGISTRY_PASSWORD}" | base64 | tr -d '\n')" } } }
      EOF
    - export SOURCE_DATE_EPOCH="$(git log -1 --pretty=%ct)"
    - |
      /kaniko/executor \
        --context "dir://${CI_PROJECT_DIR}" \
        --dockerfile "${CI_PROJECT_DIR}/build/Dockerfile" \
        --target runtime \
        --destination "${IMAGE}:${CI_COMMIT_TAG:-$CI_COMMIT_SHORT_SHA}" \
        --cache=true \
        --cache-repo "${CACHE_REPO}" \
        --cache-ttl=168h \
        --snapshot-mode=redo \
        --use-new-run \
        --reproducible \
        --build-arg VERSION="${CI_COMMIT_TAG:-0.0.0-${CI_COMMIT_SHORT_SHA}}" \
        --label org.opencontainers.image.revision="${CI_COMMIT_SHA}" \
        --label org.opencontainers.image.source="${CI_PROJECT_URL}" \
        --digest-file "${CI_PROJECT_DIR}/image.digest"
  artifacts:
    paths: ["image.digest"]
    expire_in: 1 week

scan:image:
  stage: scan
  image: aquasec/trivy:0.55.0
  script:
    - trivy image --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 "${IMAGE}@$(cat image.digest)"
```

---

## 16. Verificación y diagnóstico de fallos

### 16.1 Síntoma → causa → comando

| Síntoma | Causa más probable | Primer comando |
|---|---|---|
| `failed to solve: process "/bin/sh -c …" did not complete successfully: exit code: 1` | Fallo real del comando, oculto por la TUI | `docker buildx build --progress=plain --no-cache` |
| `COPY failed: file not found in build context` | Ruta excluida por `.dockerignore`, o stage equivocado | `docker buildx build --target <stage> …` + revisar `.dockerignore` |
| `exec /server: no such file or directory` (¡el binario existe!) | Binario enlazado dinámicamente sobre `scratch`/distroless — falta el loader | `file dist/server` / `ldd dist/server` |
| `exec format error` | Desajuste de arquitectura | `docker image inspect --format '{{.Architecture}}'` |
| La caché nunca acierta en CI | Sin `--cache-from/--cache-to`; runner efímero | Agregar `type=registry,mode=max` |
| Fallos de caché tras una edición trivial del código | `COPY . .` antes de instalar dependencias | Reordenar; ver §4 |
| `max depth exceeded` | Más de 127 capas | Hacer squash o colapsar los `RUN` |
| `no space left on device` en el builder | Crecimiento de la caché de build | `docker buildx du` → `docker builder prune` |
| Imagen 10× más grande de lo esperado | Herramientas de build en el stage final, o `rm` a posteriori | `dive` / `docker history` |
| `Error loading shared library libc.musl…` | Binario glibc sobre Alpine | Cambiar de base o compilar contra musl |
| `unauthorized: authentication required` al hacer push | `config.json` ausente/caducado; host de registry equivocado en el tag | `docker login` + revisar el prefijo del tag |
| `error checking push permissions` (Kaniko) | Secreto no montado en `/kaniko/.docker/config.json` | Revisar `items[].path` del volumen |
| `operation not permitted` en un builder rootless | seccomp/AppArmor bloqueando `unshare` | Poner `seccompProfile: Unconfined` + AppArmor unconfined |
| El pod ignora `SIGTERM` y lo matan tras el periodo de gracia | `ENTRYPOINT` en shell form | `docker inspect --format '{{json .Config.Entrypoint}}'` |
| "Funciona en local, prod ejecuta código viejo" | Tag mutable republicado / `imagePullPolicy: IfNotPresent` | Comparar `crane digest` con el `imageID` del pod |

### 16.2 Hacer hablar a un build que falla

```
$ docker buildx build --progress=plain --no-cache -t api:debug . 2>&1 | tail -20
#14 [builder 5/6] RUN pip install --require-hashes -r requirements.lock
#14 3.117 Collecting psycopg2==2.9.9
#14 4.902   Running setup.py install for psycopg2: started
#14 6.740     Error: pg_config executable not found.
#14 6.741     ERROR: Command errored out with exit status 1
#14 ERROR: process "/bin/sh -c pip install --require-hashes -r requirements.lock" did not complete successfully: exit code: 1
------
 > [builder 5/6] RUN pip install --require-hashes -r requirements.lock:
6.740     Error: pg_config executable not found.
------
Dockerfile:22
--------------------
  21 |     COPY requirements.txt requirements.lock ./
  22 | >>> RUN --mount=type=cache,target=/root/.cache/pip \
  23 | >>>     pip install --require-hashes -r requirements.lock
--------------------
```

Después conseguí una shell **en el último estado correcto** apuntando al stage anterior:

```
$ docker buildx build --target builder --load -t api:builder-debug . || true
$ docker run --rm -it --entrypoint /bin/sh api:builder-debug
/ # which pg_config
/ # apt-get install -y libpq-dev && which pg_config
/usr/bin/pg_config
```

Para un build que falla *dentro* de un stage al que no podés llegar, el depurador interactivo de BuildKit:

```
$ export BUILDX_EXPERIMENTAL=1
$ docker buildx debug --invoke /bin/sh build --target builder .
```

### 16.3 Auditar tamaño y composición de capas

```
$ docker history --format 'table {{.Size}}\t{{.CreatedBy}}' api:2.7.0
SIZE      CREATED BY
0B        CMD ["api.main:app" "--host" "0.0.0.0" "--port" "8080"]
0B        ENTRYPOINT ["/app/.venv/bin/python" "-m" "uvicorn"]
0B        USER 10001:10001
41.2MB    COPY /app/.venv /app/.venv # buildkit
2.14MB    COPY /app/api /app/api # buildkit
7.83MB    RUN /bin/sh -c apt-get update && apt-get install --no-install-recommends -y libpq5 …
0B        ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 …
48.1MB    /bin/sh -c #(nop) ADD file:… in /

$ dive registry.example.com/platform/api:2.7.0 --ci --lowestEfficiency=0.95
Analyzing image...
efficiency: 97.4 %
wastedBytes: 3.1 MB
userWastedPercent: 2.6 %
Run CI Validations...
  PASS: highestUserWastedPercent
  PASS: highestWastedBytes
  PASS: lowestEfficiency
Result:PASS
```

Los "wasted bytes" de `dive` son el total de ficheros escritos en una capa y sobrescritos o borrados en una posterior — exactamente el antipatrón del `rm` a posteriori.

### 16.4 Verificar el artefacto producido antes de publicarlo

```
# 1. Architecture and entrypoint are what you intended
$ docker buildx imagetools inspect registry.example.com/platform/api:2.7.0 \
    --format '{{range .Manifest.Manifests}}{{.Platform.OS}}/{{.Platform.Architecture}} {{end}}'
linux/amd64 linux/arm64 unknown/unknown

# 2. It does not run as root
$ crane config registry.example.com/platform/api:2.7.0 | jq -r '.config.User'
10001:10001

# 3. There is no shell or package manager in the runtime image
$ crane export registry.example.com/platform/api:2.7.0 - | tar -t 2>/dev/null \
    | grep -E '(bin/(ba)?sh|usr/bin/(apt|apk|dnf|yum))$'
usr/bin/dash          # ← still present: acceptable for slim, unacceptable for a hardened tier

# 4. The binary actually starts
$ docker run --rm --read-only --tmpfs /tmp --cap-drop=ALL --security-opt no-new-privileges \
    -p 8080:8080 registry.example.com/platform/api:2.7.0 &
$ curl -fsS localhost:8080/healthz && echo OK
{"status":"ok","version":"2.7.0"}
OK

# 5. Metadata is populated (GitOps and catalogues depend on it)
$ crane config registry.example.com/platform/api:2.7.0 | jq '.config.Labels'
{
  "org.opencontainers.image.revision": "9f3ac21b7d0e4c58a6b1f2e39d47c80512ab6e3f",
  "org.opencontainers.image.source": "https://github.com/example/api",
  "org.opencontainers.image.version": "2.7.0"
}
```

El paso 4 es el que los equipos se saltan. Ejecutar el candidato con `--read-only --cap-drop=ALL` en local reproduce el `securityContext` restrictivo que aplicará producción, y detecta "la app escribe en `/app/logs` al arrancar" **antes** de que lo haga el rollout.

### 16.5 Mantenimiento del builder

```
$ docker buildx du --verbose | tail -12
ID:             xk3n9q1w7p2m4c6v8b0z5a3f
Created at:     2026-08-29 07:14:22 +0000 UTC
Mutable:        false
Reclaimable:    true
Shared:         false
Size:           4.19GB
Description:    [builder 5/6] RUN pip install --require-hashes -r requirements.lock
Usage count:    31
Last used:      2 days ago
Type:           regular

Reclaimable:    58.4GB
Total:          71.2GB

$ docker builder prune --filter until=168h --keep-storage 40GB -f
Total reclaimed space: 22.7GB
```

Ejecutá esto desde un `CronJob`/timer de systemd en los nodos de build. "No space left on device" a las 02:00 la noche de una release es un fallo de planificación, no un fallo de Docker.

---

## 17. Referencia de comandos

```
# Build
docker build -t app:1.0 .                             # legacy/BuildKit depending on DOCKER_BUILDKIT
DOCKER_BUILDKIT=1 docker build --secret id=x,src=f .  # BuildKit features
docker buildx build --platform linux/amd64,linux/arm64 --push -t repo/app:1.0 .
docker buildx build --target builder --load .          # single-arch load into the local daemon
docker buildx bake --print                             # resolve the HCL build graph
podman build -t app:1.0 -f Containerfile .
buildah bud --layers --format oci -t app:1.0 .
buildah from / run / copy / config / commit            # script-mode build
/kaniko/executor --context dir:// --destination repo/app:1.0

# Inspect
docker history --no-trunc app:1.0
docker image inspect app:1.0
docker buildx imagetools inspect repo/app:1.0
podman image tree app:1.0
skopeo inspect --raw docker://repo/app:1.0
crane config repo/app:1.0 ; crane digest repo/app:1.0 ; crane export repo/app:1.0 -
dive repo/app:1.0 --ci

# Registry
docker login registry.example.com
docker tag app:1.0 registry.example.com/team/app:1.0
docker push registry.example.com/team/app:1.0
skopeo copy docker://src:tag docker://dst:tag
crane copy src:tag dst:tag

# Housekeeping
docker buildx du ; docker builder prune --filter until=24h
docker system df ; docker image prune -a
podman system prune -a --volumes
```

---

## 18. Referencias

**Objetivos del examen**
- LPI DevOps Tools Engineer — objetivos del examen 701: https://www.lpi.org/our-certifications/exam-701-objectives/
- Visión general de la certificación LPI DevOps Tools Engineer: https://www.lpi.org/our-certifications/devops-overview/

**Especificaciones**
- OCI Image Format Specification: https://github.com/opencontainers/image-spec/blob/main/spec.md
- OCI Image Manifest / Index / Config: https://github.com/opencontainers/image-spec/blob/main/manifest.md · https://github.com/opencontainers/image-spec/blob/main/image-index.md · https://github.com/opencontainers/image-spec/blob/main/config.md
- OCI Pre-defined Annotation Keys: https://github.com/opencontainers/image-spec/blob/main/annotations.md
- OCI Distribution Specification: https://github.com/opencontainers/distribution-spec/blob/main/spec.md

**Ficheros de build y builders**
- Referencia de Dockerfile: https://docs.docker.com/reference/dockerfile/
- Sintaxis del frontend de Dockerfile (BuildKit): https://docs.docker.com/build/dockerfile/frontend/
- Buenas prácticas de construcción: https://docs.docker.com/build/building/best-practices/
- Builds multi-stage: https://docs.docker.com/build/building/multi-stage/
- Documentación de BuildKit: https://docs.docker.com/build/buildkit/
- Caché de build y backends de caché: https://docs.docker.com/build/cache/ · https://docs.docker.com/build/cache/backends/
- Secretos de build: https://docs.docker.com/build/building/secrets/
- Builds multiplataforma: https://docs.docker.com/build/building/multi-platform/
- Referencia de Bake: https://docs.docker.com/build/bake/reference/
- Build attestations (SBOM, provenance): https://docs.docker.com/build/metadata/attestations/
- Builds reproducibles: https://docs.docker.com/build/ci/github-actions/reproducible-builds/
- Referencia de `.dockerignore`: https://docs.docker.com/reference/dockerfile/#dockerignore-file
- Proyecto BuildKit (rootless, ejemplos de Kubernetes): https://github.com/moby/buildkit · https://github.com/moby/buildkit/blob/master/docs/rootless.md · https://github.com/moby/buildkit/tree/master/examples/kubernetes
- Buildah: https://buildah.io/ · `buildah-bud(1)`: https://github.com/containers/buildah/blob/main/docs/buildah-build.1.md
- Podman `podman-build(1)`: https://docs.podman.io/en/latest/markdown/podman-build.1.html
- Modo rootless de Podman: https://github.com/containers/podman/blob/main/docs/tutorials/rootless_tutorial.md
- Kaniko: https://github.com/GoogleContainerTools/kaniko
- `ko`: https://ko.build/
- Jib: https://github.com/GoogleContainerTools/jib
- Cloud Native Buildpacks: https://buildpacks.io/docs/ · CLI `pack`: https://buildpacks.io/docs/for-platform-operators/how-to/integrate-ci/pack/
- Bazel `rules_oci`: https://github.com/bazel-contrib/rules_oci

**Imágenes base**
- Distroless: https://github.com/GoogleContainerTools/distroless
- Alpine Linux: https://alpinelinux.org/ · diferencias entre musl y glibc: https://wiki.musl-libc.org/functional-differences-from-glibc.html
- Red Hat UBI: https://developers.redhat.com/products/rhel/ubi
- Chainguard Images / Wolfi: https://edu.chainguard.dev/chainguard/chainguard-images/ · https://github.com/wolfi-dev

**Cadena de suministro e inspección**
- Sigstore `cosign`: https://docs.sigstore.dev/cosign/signing/overview/
- Framework SLSA: https://slsa.dev/spec/v1.0/
- Trivy: https://aquasecurity.github.io/trivy/
- Syft: https://github.com/anchore/syft
- `skopeo`: https://github.com/containers/skopeo
- `crane` (go-containerregistry): https://github.com/google/go-containerregistry/blob/main/cmd/crane/doc/crane.md
- `dive`: https://github.com/wagoodman/dive
- Kubernetes — Imágenes e `imagePullPolicy`: https://kubernetes.io/docs/concepts/containers/images/
- Kubernetes — Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Verificación de imágenes en Kyverno: https://kyverno.io/docs/writing-policies/verify-images/