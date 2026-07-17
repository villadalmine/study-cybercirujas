# 4.1 Minimize base image footprint

## ¿Por qué importa?

Cada paquete, binario o shell que agregás a una imagen de contenedor es superficie de ataque adicional: más CVEs potenciales, más herramientas que un atacante puede usar post-compromiso (living-off-the-land: `curl`, `wget`, `bash`, compiladores, package managers) y más tiempo de build/pull. Minimizar el footprint de la imagen base es el primer control de la cadena de suministro (*supply chain security*) y complementa directamente el escaneo de vulnerabilidades (tema 4.4) y el análisis estático de manifests (tema 4.3): una imagen más chica tiene, por definición, menos CVEs que escanear y menos que parchear.

Principios clave:

- **Menos paquetes = menos CVEs.** Una imagen `ubuntu:latest` completa trae cientos de paquetes que la app nunca usa.
- **Sin shell ni package manager = menos post-exploitation.** Si un atacante logra RCE en el contenedor, no tener `sh`, `bash`, `apt`, `curl` dificulta mucho moverse lateralmente o descargar herramientas.
- **Multi-stage builds** separan las herramientas de build (compiladores, SDKs) del runtime final, que solo lleva el artefacto compilado.
- **Imágenes inmutables y de solo lectura** reducen la posibilidad de que se instalen paquetes en runtime.

## Estrategias de reducción

### 1. Elegir una base image mínima

De mayor a menor footprint típico:

| Base image | Tamaño aprox. | Shell | Package manager | Uso típico |
|---|---|---|---|---|
| `ubuntu:22.04` | ~77 MB | sí (bash) | apt | evitar en producción |
| `debian:12-slim` | ~30 MB | sí (bash/dash) | apt | intermedio |
| `alpine:3.19` | ~7 MB | sí (ash/busybox) | apk | liviana, pero con libc musl (puede romper binarios glibc) |
| `gcr.io/distroless/*` | ~2-20 MB según variante | **no** | **no** | apps compiladas (Go, Java, Node, Python) |
| `scratch` | 0 MB | **no** | **no** | binarios estáticos (Go con `CGO_ENABLED=0`) |

```bash
$ docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}"
REPOSITORY                  TAG        SIZE
ubuntu                      22.04      77.9MB
debian                      12-slim    29.7MB
alpine                      3.19       7.38MB
gcr.io/distroless/static    latest     2.36MB
```

**Distroless** (proyecto de Google, `github.com/GoogleContainerTools/distroless`) provee imágenes con solo el runtime necesario (glibc, certificados TLS, timezone data) sin shell, sin package manager, sin coreutils. Variantes comunes: `distroless/static` (binarios estáticos), `distroless/base` (glibc dinámica), `distroless/java`, `distroless/nodejs`, `distroless/python3`.

### 2. Multi-stage builds

Separar el *build stage* (con compiladores, headers, herramientas) del *runtime stage* (solo el artefacto final):

```dockerfile
# --- Build stage ---
FROM golang:1.22 AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o server ./cmd/server

# --- Runtime stage ---
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /app/server /server
USER nonroot:nonroot
ENTRYPOINT ["/server"]
```

Resultado: la imagen final no contiene el toolchain de Go, source code, ni caché de módulos — solo el binario estático. Compará el tamaño:

```bash
$ docker build -t app:builder-stage --target builder .
$ docker build -t app:final .
$ docker images app
REPOSITORY   TAG            SIZE
app          builder-stage  ~900MB
app          final          ~9MB
```

Para lenguajes interpretados (Python, Node), el multi-stage sirve para instalar dependencias con compiladores (`gcc`, `build-essential` para wheels nativas) en un stage y copiar solo el `venv`/`node_modules` resultante al stage final, sin dejar el compilador en la imagen de runtime.

### 3. Eliminar artefactos innecesarios en cada capa

Si no se puede usar distroless/scratch (por ejemplo, se necesita debugging temporal), al menos limpiar dentro de la **misma capa** RUN para no dejar residuos en el historial de capas:

```dockerfile
FROM debian:12-slim
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl && \
    rm -rf /var/lib/apt/lists/* && \
    apt-get purge -y --auto-remove
```

Si el `apt-get purge` va en un `RUN` distinto al `apt-get install`, la capa anterior sigue existiendo en la imagen (las capas son inmutables) y el tamaño no baja. Este es un error común en el examen: pensar que borrar en un layer posterior reduce el tamaño de la imagen.

### 4. Inspeccionar y auditar el resultado

**`docker history`** muestra el tamaño de cada capa:

```bash
$ docker history app:final
IMAGE          CREATED         CREATED BY                        SIZE
a1b2c3d4e5f6   2 minutes ago   COPY /app/server /server           8.9MB
<missing>      3 weeks ago     /bin/sh -c #(nop)  USER nonroot     0B
```

**`dive`** (herramienta open source) permite explorar capa por capa qué archivos ocupan espacio y detectar archivos duplicados o desperdiciados:

```bash
$ dive app:final
```

**Verificar que no hay shell** en una imagen distroless/scratch:

```bash
$ docker run --rm app:final sh
docker: Error response from daemon: OCI runtime create failed:
  exec: "sh": executable file not found in $PATH: unknown.
```

Esto es justamente el comportamiento deseado: sin shell disponible, un atacante que logre ejecución dentro del contenedor no puede abrir una interactive shell trivialmente.

### 5. Escanear la imagen resultante

Complementa la minimización con escaneo (tema 4.4), por ejemplo con `trivy`:

```bash
$ trivy image app:final
app:final (debian 12.5)
=======================
Total: 0 (UNKNOWN: 0, LOW: 0, MEDIUM: 0, HIGH: 0, CRITICAL: 0)
```

Una imagen distroless/scratch bien construida típicamente reporta cero o muy pocos CVEs, versus decenas en una base `ubuntu:latest` sin actualizar.

## Buenas prácticas resumidas

- Preferir `FROM scratch` o `distroless` para binarios compilados estáticamente (Go, Rust).
- Usar `alpine` cuando se necesite un package manager mínimo, pero verificar compatibilidad musl/glibc.
- Siempre usar **multi-stage builds** para no arrastrar toolchains de compilación al runtime.
- Fijar tags específicos (`golang:1.22`, no `golang:latest`) para builds reproducibles y trazables.
- Usar `--no-install-recommends` (apt) o `--no-cache` (apk) para evitar dependencias transitivas innecesarias.
- Combinar `install` + limpieza en el mismo `RUN` para que no queden residuos en capas previas.
- Terminar con `USER nonroot` (o un UID no-root explícito) — ver tema 4.4/hardening de contenedores.
- Auditar con `docker history`, `dive` y un scanner de vulnerabilidades antes de publicar.

## Referencias

- CKS Curriculum v1.34: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Distroless images (Google): https://github.com/GoogleContainerTools/distroless
- Docker multi-stage builds: https://docs.docker.com/build/building/multi-stage/
- Docker best practices para Dockerfiles: https://docs.docker.com/build/building/best-practices/
- Alpine Linux: https://www.alpinelinux.org/
- `dive` (image layer explorer): https://github.com/wagoodman/dive
- Trivy (vulnerability scanner): https://trivy.dev/
- Kubernetes docs, Pod Security Standards (contexto de hardening de contenedores): https://kubernetes.io/docs/concepts/security/pod-security-standards/