# CKS 4.1 — Minimizar la huella de la imagen base

**Dominio:** Supply Chain Security · **Peso en el examen:** 5% · **Versión del examen:** CKS 1.34 (Kubernetes v1.34)

---

## 1. El problema en producción

### 1.1 "Huella" no es "megabytes"

La mayoría de los equipos reduce este tema al tamaño de la imagen. El tamaño es una *métrica indirecta*, y bastante pobre. Lo que realmente determina la postura de seguridad de una imagen de contenedor es el conjunto de **capacidades ejecutables alcanzables por un proceso que logró ejecución de código dentro del contenedor**.

Descomponé la huella en cinco ejes independientes:

| Eje | Qué es | Por qué importa después de un compromiso |
|---|---|---|
| **Superficie de paquetes** | Cada `.deb`/`.rpm`/`.apk` y sus dependencias transitivas | Cada paquete es un feed de CVEs al que te suscribiste de forma permanente. Ahora sos dueño de SLAs de parcheo para código que tu aplicación nunca invoca. |
| **Superficie ejecutable** | Shells, coreutils, `curl`, `wget`, `nc`, `python`, `perl`, `tar`, `find` | Estas son las herramientas del atacante. Un contenedor sin `sh` obliga al atacante a traer su propio binario *y* encontrar una ubicación del sistema de archivos que sea escribible y ejecutable. |
| **Superficie del gestor de paquetes** | `apt`, `apk`, `dnf/microdnf`, `pip`, `npm` | Convierte una primitiva de ejecución de código en instalación arbitraria de herramientas, y da persistencia basada en egress. |
| **Superficie de privilegios** | Binarios setuid/setgid, capacidades de archivo (`getcap`), `/etc/sudoers` | Escalada local de privilegios dentro del namespace del contenedor — la primera mitad de la mayoría de las cadenas de escape. |
| **Superficie de credenciales** | Secretos de build dejados en capas, `~/.npmrc`, `~/.docker/config.json`, cachés de SDKs de nube | Movimiento lateral. Las capas son inmutables y direccionadas por contenido: un `rm` en una capa posterior **no** borra el blob. |

Una imagen "pequeña" puede ser igualmente terrible (Alpine trae un shell BusyBox completo + `apk` + `wget` en 7 MB). Una imagen "grande" puede ser defendible (una imagen JVM de 200 MB sin shell, sin gestor de paquetes y sin binarios setuid). **Optimizá los ejes, y el tamaño cae como efecto secundario.**

### 1.2 La aritmética de los CVEs heredados

El conteo de vulnerabilidades de tu imagen es:

```
CVE(image) = CVE(base OS packages)
           + CVE(language runtime)
           + CVE(application dependencies)
           + CVE(your code)
```

El primer término es el único que es *pura responsabilidad* — heredás la carga de mantenimiento sin ganar funcionalidad. En un microservicio Go típico construido `FROM ubuntu:24.04`, el término 1 es el 90–98% de los hallazgos reportados, y el 100% de eso es innecesario: el binario compilado no enlaza nada de la base.

Esto tiene consecuencias operativas directas que aparecen en el error budget de un SRE, no solo en el dashboard de un escáner:

- **Amplificación del parcheo.** Un aviso de `glibc`/`openssl`/`zlib` fuerza la reconstrucción y el redespliegue de *cada* servicio que comparte la base, sin importar si el servicio usa la biblioteca. Con 300 servicios sobre una base Ubuntu compartida, un CVE son 300 despliegues.
- **Los gates de política bloquean releases.** Un gate de CI con `trivy --exit-code 1 --severity CRITICAL` sobre una base gorda bloquea releases por CVEs en `passwd`, `apt` o `perl-base` que la carga de trabajo nunca invoca. Los equipos entonces hacen lo peor posible: agregan entradas genéricas en `.trivyignore` y dejan de leer al escáner.
- **El ruido de auditoría destruye la señal.** 480 hallazgos donde 470 son inalcanzables significa que los 10 reales no se triagean.

### 1.3 Post-explotación: qué encuentra realmente el atacante

Considerá un SSRF-a-RCE en una aplicación web. La diferencia entre imágenes base decide si el incidente queda *contenido* o si hay *pivoteo*:

```
┌───────────────────────────────────────────────────────────────────────────────┐
│  Attacker obtains code execution as the container's UID                       │
└───────────────────────────────────────────────────────────────────────────────┘
        │                                                    │
        │  FROM ubuntu:24.04                                 │  FROM distroless/static:nonroot
        ▼                                                    ▼
  /bin/bash            → interactive shell               (absent)  → no interpreter
  apt-get install      → arbitrary tooling               (absent)  → must smuggle a static ELF
  curl / wget          → C2 egress + payload staging     (absent)  → must write raw sockets in-process
  /usr/bin/mount (suid)→ local privesc primitive         (absent)  → no setuid binaries at all
  python3 / perl       → reverse shell one-liner         (absent)  → nothing to interpret
  ps / find / netstat  → in-cluster reconnaissance       (absent)  → blind
  /var/run/secrets/... → ServiceAccount token            present   → still present (K8s-level control)
```

La imagen mínima **no** detiene el RCE inicial. Eleva el costo de *cada paso posterior* y — algo crítico para la detección — obliga al atacante a escribir un archivo en disco o a ejecutar un binario inesperado, que es exactamente el evento que un sensor de runtime (Falco, Tetragon) detecta de forma confiable. Combinado con `readOnlyRootFilesystem: true`, el atacante tiene ejecución de código en un proceso sin shell, sin ruta ejecutable escribible y sin gestor de paquetes. Ese es el punto.

> **Honestidad sobre el modelo de amenazas:** una imagen mínima *no* es un sandbox. No hace nada contra exploits del kernel, no hace nada contra un token de ServiceAccount montado con RBAC excesivo, y no hace nada contra montajes `hostPath`. Es un control dentro de una cadena que también debe incluir Pod Security Standards, seccomp, minimización de RBAC y NetworkPolicy.

### 1.4 Economía a nivel de nodo

La huella también es una propiedad de fiabilidad del nodo:

- **Latencia de pull en el camino crítico.** Una falla de nodo dispara reprogramación → pull de imagen → readiness. Una imagen de 900 MB en un nodo con enlace de 200 Mbit/s cuesta ~40 s de pull *por nodo* antes de que el contenedor siquiera arranque, y está serializado detrás de la descompresión del runtime. El escalado horizontal bajo carga (HPA) está limitado por el mismo número.
- **Presión de disco y GC de imágenes.** El kubelet recolecta imágenes entre `imageGCLowThresholdPercent` e `imageGCHighThresholdPercent`. Las imágenes gordas hacen más probable el desalojo por `DiskPressure`, que desaloja pods de *otros* tenants — un acoplamiento de fiabilidad entre tenants creado puramente por el inflado de la imagen.
- **Costo de registry y tasa de aciertos de caché.** La deduplicación de capas solo ayuda cuando las bases se *comparten*; una flota con 12 bases gordas distintas se lleva lo peor de ambos mundos.

---

## 2. Taxonomía de imágenes base

### 2.1 La tabla comparativa

Los tamaños son **sin comprimir**, tal como los reporta `docker image ls` (el registry almacena blobs comprimidos, típicamente ~35–45% de esto). Medidos el 2026-08-04 en `linux/amd64`; reproducilo con el script de §5.1. Tratá los números como órdenes de magnitud, no como constantes.

| Imagen base | Tamaño | libc | Shell | Gestor de pqts | Certs CA | `/etc/passwd` | tzdata | Uso típico |
|---|---:|---|---|---|---|---|---|---|
| `scratch` | 0 B | ninguna | ✗ | ✗ | ✗ | ✗ | ✗ | Binario totalmente estático, sin TLS hacia el exterior, sin archivos temporales |
| `gcr.io/distroless/static-debian12` | ~2.4 MB | ninguna | ✗ | ✗ | ✓ | ✓ (`nonroot`=65532) | ✓ | **Opción por defecto para Go/Rust estático** |
| `cgr.dev/chainguard/static` | ~3 MB | ninguna | ✗ | ✗ | ✓ | ✓ (65532) | ✓ | Mismo rol, mantenida con Wolfi, con SBOM+firma adjuntos |
| `gcr.io/distroless/base-debian12` | ~20 MB | glibc | ✗ | ✗ | ✓ | ✓ | ✓ | Go con CGO habilitado, C enlazado dinámicamente |
| `gcr.io/distroless/cc-debian12` | ~22 MB | glibc + libstdc++ | ✗ | ✗ | ✓ | ✓ | ✓ | Aplicaciones C++, Rust con target `gnu` |
| `alpine:3.20` | ~7.8 MB | musl | ✓ BusyBox `ash` | ✓ `apk` | ✓ (vía paquete) | ✓ | ✗ (vía paquete) | Imágenes de ops/debug; imágenes de aplicación solo con reservas (§2.2) |
| `cgr.dev/chainguard/wolfi-base` | ~14 MB | glibc | ✓ | ✓ `apk` | ✓ | ✓ | ✓ | Etapa de build/debug compatible con glibc y con la comodidad de apk |
| `registry.access.redhat.com/ubi9/ubi-micro` | ~26 MB | glibc | ✗ | ✗ (se instala desde afuera) | ✓ | ✓ | ✓ | Soportada por RHEL, sin shell |
| `registry.access.redhat.com/ubi9/ubi-minimal` | ~100 MB | glibc | ✓ | ✓ `microdnf` | ✓ | ✓ | ✓ | Requiere contrato de soporte RHEL |
| `debian:12-slim` | ~74 MB | glibc | ✓ | ✓ `apt` | ✗ (vía paquete) | ✓ | ✓ | Aplicaciones legacy que necesitan `apt` en tiempo de build |
| `ubuntu:24.04` | ~78 MB | glibc | ✓ | ✓ `apt` | ✗ (vía paquete) | ✓ | ✓ | Evitala como base de *runtime* |
| `gcr.io/distroless/java21-debian12` | ~190 MB | glibc | ✗ | ✗ | ✓ | ✓ | ✓ | Aplicaciones JVM sin runtime jlink a medida |
| `gcr.io/distroless/nodejs22-debian12` | ~150 MB | glibc | ✗ | ✗ | ✓ | ✓ | ✓ | Aplicaciones Node; el ENTRYPOINT es `node` |

**Resumen de compromisos:**

| Elección | Ganancias | Costos / riesgos |
|---|---|---|
| `scratch` | Mínimo absoluto; cero CVEs heredados | Sin bundle de CAs (TLS hacia internet falla), sin `/etc/passwd` (`user.Current()` falla), sin `/tmp`, sin tzdata, sin `nsswitch.conf`. Tenés que proveer cada cosa explícitamente. |
| Distroless `static` | Las mismas garantías que scratch **más** las cuatro cosas anteriores ya resueltas | Feed de CVEs de Debian para `ca-certificates`/`tzdata` (mínimo). Sin shell → flujo de depuración con contenedores efímeros obligatorio. |
| Distroless `base`/`cc` | Soporta CGO / enlazado dinámico | glibc + OpenSSL pasan a estar en tu superficie de CVEs. |
| Alpine | Pequeña, `apk` disponible, índice de paquetes enorme | **musl ≠ glibc**: diferencias sutiles en runtime (§2.2). Trae shell + gestor de paquetes + applets de BusyBox — exactamente la superficie de post-explotación que estabas tratando de eliminar. |
| Wolfi / Chainguard | glibc, casi cero CVEs, firmada + SBOM por defecto, reconstrucciones diarias | El tier gratuito fija `:latest` (sin tags de versiones históricas sin suscripción) — entra en conflicto con la disciplina de fijar por digest salvo que hagas un mirror. |
| UBI | Ciclo de vida de soporte de CVEs de Red Hat, camino criptográfico validado FIPS | La más grande de la familia "mínima"; `ubi-minimal` sigue trayendo un shell. |

### 2.2 glibc vs musl — el compromiso que nadie documenta en la entrevista

El tamaño pequeño de Alpine viene de BusyBox + **musl libc**, no de ser "más limpia". musl es una libc distinta, y las divergencias son relevantes en producción:

| Aspecto | glibc | musl | Impacto específico en Kubernetes |
|---|---|---|---|
| Resolver DNS | Nameservers secuenciales, fallback a TCP en truncamiento, `nsswitch.conf` | Consulta todas las entradas `nameserver` en paralelo; **fallback a TCP solo desde musl 1.2.4** (Alpine 3.18+) | Con `ndots: 5` y 4 dominios de búsqueda, una sola resolución se abre en ~20 consultas. musl anterior a 1.2.4 falla silenciosamente con respuestas de más de 512 bytes (listas grandes de endpoints de Services headless). |
| Stack de hilo por defecto | 8 MB | 128 KB (elevado a 128 KB en 1.2.x; históricamente 80 KB) | Código JVM/Rust/con recursión profunda hace segfault sin ningún mensaje útil. |
| malloc | ptmalloc2, arena por hilo | mallocng — más pequeño, **medible­mente más lento bajo alta contención de hilos** | Se han reportado regresiones de throughput del 20–40% en cargas intensivas en asignación de memoria. |
| Compatibilidad binaria | La ABI de facto | No es compatible con la ABI de glibc | Cualquier wheel `manylinux` precompilado, `.so` incluido por el SDK de un proveedor, o binario Go construido con `CGO_ENABLED=1` en Debian va a fallar en Alpine. |
| Wheels de Python | Los wheels `manylinux` se instalan | Necesita wheels `musllinux`, si no compila desde el código fuente | Un `pip install` en una etapa de build Alpine tarda silenciosamente 15 minutos y arrastra `gcc`. |

**Regla práctica:** si controlás el compilador y podés producir un binario totalmente estático, usá `distroless/static` — obtenés el tamaño de Alpine *sin* musl y *sin* shell. Usá Alpine cuando quieras una imagen pequeña de **debug/ops**, o cuando el ecosistema ya sea nativo de musl.

### 2.3 El contrato distroless

Las imágenes `gcr.io/distroless/*` (Google, `GoogleContainerTools/distroless`) contienen las dependencias de runtime de la aplicación y nada más. Concretamente, `static-debian12` contiene:

```
/etc/passwd, /etc/group        → root(0) and nonroot(65532) entries
/etc/nsswitch.conf             → "hosts: files dns"  (needed by Go's cgo resolver path)
/etc/ssl/certs/ca-certificates.crt
/usr/share/zoneinfo/           → tzdata
/tmp                           → mode 1777
/var/lib/dpkg/status.d/        → package metadata so scanners can enumerate contents
```

Variantes de tag que importan para el examen y para producción:

| Tag | Efecto |
|---|---|
| `:latest` | Corre como **root (UID 0)** |
| `:nonroot` | Corre como **UID/GID 65532**, `$HOME=/home/nonroot` |
| `:debug` | Agrega un shell BusyBox en `/busybox/sh` — **nunca la publiques a producción**, usala solo para reproducir un bug |
| `:debug-nonroot` | Ambas cosas |

El detalle de `/var/lib/dpkg/status.d/` es importante: es lo que le permite a Trivy/Grype enumerar los paquetes de la base. Las imágenes basadas en `scratch` son *inescaneables* a nivel de sistema operativo — el escáner reporta "0 vulnerabilidades" porque no encontró base de datos de paquetes, lo cual no es lo mismo que "segura". Preferí distroless sobre scratch en parte por esta razón de observabilidad.

### 2.4 Procedimiento de decisión

```
Can the app be compiled to a fully static binary (Go CGO_ENABLED=0, Rust musl target)?
├── yes → gcr.io/distroless/static-debian12:nonroot        (2.4 MB, no shell, no libc)
└── no
    ├── Needs glibc only (CGO, C libs)?      → gcr.io/distroless/base-debian12:nonroot
    ├── Needs libstdc++ (C++, Rust gnu)?     → gcr.io/distroless/cc-debian12:nonroot
    ├── JVM?
    │     ├── can run jlink/jdeps  → jlink custom runtime → distroless/base or chainguard/jre
    │     └── cannot                → gcr.io/distroless/java21-debian12:nonroot
    ├── Node.js?                             → gcr.io/distroless/nodejs22-debian12:nonroot
    ├── Python / Ruby / PHP?                 → cgr.dev/chainguard/python (or wolfi-base + apk, then strip)
    └── Vendor blob demanding RHEL/FIPS?     → ubi9/ubi-micro (install RPMs from a ubi9 builder stage)
```

---

## 3. Técnicas de build — Dockerfiles completos y funcionales

La aplicación de referencia para §3 y §5 es un pequeño servicio HTTP en Go.

```go
// main.go
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
	_ "time/tzdata" // embed the IANA database in the binary; survives a scratch base
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintln(w, "ok")
	})
	mux.HandleFunc("GET /", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "served at %s\n", time.Now().UTC().Format(time.RFC3339))
	})

	srv := &http.Server{
		Addr:              ":8080",
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		logger.Info("listening", "addr", srv.Addr, "uid", os.Getuid())
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("server failed", "err", err)
			os.Exit(1)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = srv.Shutdown(ctx)
	logger.Info("stopped")
}
```

### 3.1 El antipatrón (lo que una tarea del examen te entrega para arreglar)

```dockerfile
# Dockerfile.bad — DO NOT SHIP. Reference for the "before" measurement.
FROM ubuntu:24.04

RUN apt-get update && apt-get install -y golang-go ca-certificates curl vim net-tools

WORKDIR /src
COPY . .
RUN go build -o /usr/local/bin/webapp .

EXPOSE 8080
CMD ["/usr/local/bin/webapp"]
```

Defectos, en el orden en que los busca un evaluador de CKS:

1. **Etapa única** — el compilador, sus fuentes, la caché de módulos y `/src` van todos a producción.
2. **Corre como root** — no hay instrucción `USER`.
3. **`curl`, `vim`, `net-tools`** — herramientas de atacante instaladas deliberadamente.
4. **`apt` presente en runtime** — instalación arbitraria de herramientas tras el compromiso.
5. **Tag base sin fijar** — `ubuntu:24.04` es un blanco móvil; los builds no son reproducibles.
6. **Sin `apt-get clean` / eliminación de listas** — los índices de paquetes persisten en la capa.
7. **`apt-get update` e `install` son cacheables y sin versiones fijadas** — el clásico bug de envenenamiento/obsolescencia de caché.

### 3.2 El objetivo: multi-etapa → distroless static, non-root

```dockerfile
# syntax=docker/dockerfile:1.9
# ---------------------------------------------------------------------------
# Stage 1 — build. Never ships.
# ---------------------------------------------------------------------------
FROM golang:1.23.4-bookworm@sha256:7ea4c9dcb2b97ff8ee80a67db3d44f98c8ffa0d191399197007d8459c1453041 AS build

WORKDIR /src

# Dependency layer, cached independently of source changes.
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download && go mod verify

COPY . .

# CGO_ENABLED=0  -> pure-Go, statically linked; no ELF interpreter needed.
# -trimpath      -> strips absolute build paths (reproducibility + info leak).
# -buildvcs=false-> avoid embedding VCS state that changes every commit.
# -ldflags "-s -w" -> drop symbol table and DWARF; smaller, harder to reverse.
# -tags timetzdata -> belt-and-braces with the `_ "time/tzdata"` import.
ARG TARGETOS=linux
ARG TARGETARCH=amd64
ARG VERSION=dev
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build \
      -trimpath \
      -buildvcs=false \
      -tags timetzdata \
      -ldflags="-s -w -X main.version=${VERSION}" \
      -o /out/webapp .

# Fail the build here, not in production, if the binary is not static.
RUN set -eux; \
    file /out/webapp | grep -q 'statically linked'; \
    ! ldd /out/webapp 2>/dev/null | grep -q '=>' || (echo "BUILD FAILED: dynamic deps present" && exit 1)

# ---------------------------------------------------------------------------
# Stage 2 — runtime. 2.4 MB base, no shell, no libc, no package manager.
# ---------------------------------------------------------------------------
FROM gcr.io/distroless/static-debian12:nonroot@sha256:3f2b64ef97bd285e36132c684e6b2ae8f2fb1fa8bda9c0e5b3f0bd1f1b12e26f

COPY --from=build --chown=65532:65532 /out/webapp /usr/local/bin/webapp

# Numeric UID:GID — mandatory for securityContext.runAsNonRoot (see §5.4, F-05).
USER 65532:65532

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/webapp"]
```

Construir y medir:

```console
$ DOCKER_BUILDKIT=1 docker build -f Dockerfile.bad -t webapp:fat .
$ DOCKER_BUILDKIT=1 docker build -f Dockerfile     -t webapp:min --build-arg VERSION=1.4.2 .

$ docker image ls --format 'table {{.Repository}}:{{.Tag}}\t{{.Size}}' | grep webapp
REPOSITORY:TAG    SIZE
webapp:fat        847MB
webapp:min        9.51MB
```

```console
$ trivy image --scanners vuln --severity HIGH,CRITICAL --quiet webapp:fat
webapp:fat (ubuntu 24.04)
=========================
Total: 34 (HIGH: 31, CRITICAL: 3)

┌──────────────────┬────────────────┬──────────┬──────────────┬───────────────┐
│     Library      │ Vulnerability  │ Severity │   Status     │ Installed Ver │
├──────────────────┼────────────────┼──────────┼──────────────┼───────────────┤
│ libssl3t64       │ CVE-2024-XXXXX │ HIGH     │ fixed        │ 3.0.13-0ub…   │
│ perl-base        │ CVE-2024-XXXXX │ HIGH     │ will_not_fix │ 5.38.2-3.2    │
│ ...              │                │          │              │               │
└──────────────────┴────────────────┴──────────┴──────────────┴───────────────┘

$ trivy image --scanners vuln --severity HIGH,CRITICAL --quiet webapp:min
webapp:min (debian 12.8)
========================
Total: 0 (HIGH: 0, CRITICAL: 0)

/usr/local/bin/webapp (gobinary)
================================
Total: 0 (HIGH: 0, CRITICAL: 0)
```

Demostrar que la superficie para el atacante desapareció:

```console
$ docker run --rm -it webapp:min sh
docker: Error response from daemon: failed to create task for container:
failed to create shim task: OCI runtime create failed: runc create failed:
unable to start container process: exec: "sh": executable file not found in $PATH: unknown.

$ docker run --rm --entrypoint /bin/ls webapp:min /
docker: Error response from daemon: ... exec: "/bin/ls": stat /bin/ls: no such file or directory

$ docker run --rm webapp:min &
$ docker exec -it <id> id
OCI runtime exec failed: exec failed: unable to start container process:
exec: "id": executable file not found in $PATH: unknown
```

### 3.3 Cuando CGO es inevitable — distroless `base`

```dockerfile
# syntax=docker/dockerfile:1.9
FROM golang:1.23.4-bookworm AS build
WORKDIR /src
RUN apt-get update && apt-get install -y --no-install-recommends \
        libsqlite3-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*
COPY . .
RUN CGO_ENABLED=1 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/app .

# Enumerate the exact shared objects the binary needs, and nothing else.
RUN mkdir -p /out/libs && \
    ldd /out/app | awk '/=> \//{print $3}' | xargs -I{} cp -v --parents {} /out/libs && \
    cp -v --parents /lib64/ld-linux-x86-64.so.2 /out/libs

FROM gcr.io/distroless/base-debian12:nonroot
COPY --from=build /out/libs/ /
COPY --from=build /out/app /usr/local/bin/app
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/app"]
```

### 3.4 JVM — runtime a medida con `jdeps` + `jlink`

La imagen genérica `distroless/java21` trae un runtime completo derivado del JDK (~190 MB). Un runtime `jlink` que contenga solo los módulos que tu aplicación resuelve es típicamente de 45–70 MB y elimina superficies de ataque enteras (`jdk.attach`, `java.rmi`, `jdk.jshell`, las herramientas `jcmd`/`jstack`).

```dockerfile
# syntax=docker/dockerfile:1.9
# ---------------------------------------------------------------------------
FROM eclipse-temurin:21.0.5_11-jdk-jammy AS build
WORKDIR /src
COPY . .
RUN ./mvnw -B -q -DskipTests package

# ---------------------------------------------------------------------------
FROM eclipse-temurin:21.0.5_11-jdk-jammy AS jre-build
WORKDIR /build
COPY --from=build /src/target/app.jar app.jar

# jdeps resolves the module graph actually reachable from the fat jar.
RUN jdeps \
      --ignore-missing-deps \
      --print-module-deps \
      --multi-release 21 \
      --recursive \
      app.jar > /build/deps.txt \
    && cat /build/deps.txt

RUN jlink \
      --add-modules "$(cat /build/deps.txt),jdk.crypto.ec" \
      --strip-debug \
      --no-man-pages \
      --no-header-files \
      --compress=zip-6 \
      --output /javaruntime \
    && /javaruntime/bin/java --version

# ---------------------------------------------------------------------------
FROM gcr.io/distroless/base-debian12:nonroot
ENV JAVA_HOME=/opt/java
ENV PATH="${JAVA_HOME}/bin:${PATH}"
COPY --from=jre-build /javaruntime ${JAVA_HOME}
COPY --from=jre-build /build/app.jar /app/app.jar
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/opt/java/bin/java", \
            "-XX:MaxRAMPercentage=75.0", \
            "-XX:+ExitOnOutOfMemoryError", \
            "-Djava.security.egd=file:/dev/urandom", \
            "-jar", "/app/app.jar"]
```

```console
$ docker build -t svc:jvm .
...
#14 [jre-build 4/4] RUN jdeps ... > /build/deps.txt
#14 1.882 java.base,java.logging,java.management,java.naming,java.sql,java.xml
#14 DONE 2.1s

$ docker image ls svc:jvm --format '{{.Size}}'
118MB          # vs 341MB for eclipse-temurin:21-jre-jammy + jar
```

> `--add-modules "$(cat deps.txt),jdk.crypto.ec"` — `jdeps` hace análisis *estático* y sistemáticamente se pierde los módulos cargados por reflexión y por ServiceLoader. `jdk.crypto.ec` (necesario para TLS con ECDHE), `jdk.localedata` y los drivers JDBC son las omisiones habituales. Agregalos siempre de forma explícita y validá con un test de integración, no solo con una verificación de arranque.

### 3.5 Node.js — distroless `nodejs`

```dockerfile
# syntax=docker/dockerfile:1.9
FROM node:22.11.0-bookworm AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev --ignore-scripts

FROM node:22.11.0-bookworm AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci --ignore-scripts
COPY . .
RUN npm run build && npm prune --omit=dev

# ENTRYPOINT of this base is already ["/nodejs/bin/node"] — CMD supplies args only.
FROM gcr.io/distroless/nodejs22-debian12:nonroot
WORKDIR /app
COPY --from=deps  --chown=65532:65532 /app/node_modules ./node_modules
COPY --from=build --chown=65532:65532 /app/dist          ./dist
COPY --from=build --chown=65532:65532 /app/package.json  ./
USER 65532:65532
ENV NODE_ENV=production
EXPOSE 3000
CMD ["dist/server.js"]
```

`--ignore-scripts` en `npm ci` es un control de cadena de suministro, no de huella: bloquea los hooks `postinstall`, el vector de ataque npm más explotado. Cuando un paquete realmente necesita su script de build, ejecutalo únicamente en la etapa de *build*.

### 3.6 Python — el caso difícil

Python no se puede enlazar estáticamente, y el intérprete + la biblioteca estándar son irreductiblemente ~40 MB. El objetivo realista es: sin compilador, sin `pip`, sin shell en la imagen final.

```dockerfile
# syntax=docker/dockerfile:1.9
FROM python:3.12.7-slim-bookworm AS build

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Self-contained venv: everything the runtime needs lives under one prefix.
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

COPY requirements.txt .
# --require-hashes turns requirements.txt into an integrity manifest.
RUN pip install --require-hashes -r requirements.txt

COPY src/ /app/

# ---------------------------------------------------------------------------
FROM gcr.io/distroless/python3-debian12:nonroot

COPY --from=build --chown=65532:65532 /opt/venv /opt/venv
COPY --from=build --chown=65532:65532 /app      /app

ENV PYTHONPATH="/opt/venv/lib/python3.12/site-packages" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app
USER 65532:65532
EXPOSE 8000
# ENTRYPOINT of this base is /usr/bin/python3.
CMD ["-m", "gunicorn", "--bind", "0.0.0.0:8000", "--workers", "2", "app:application"]
```

> **Advertencias que tenés que conocer.** `gcr.io/distroless/python3-*` está marcada como *experimental* upstream y su versión menor de Python sigue a la de Debian, así que la ruta de `site-packages` del venv debe coincidir con la versión del intérprete de la base o los imports fallan silenciosamente en runtime. Una alternativa de nivel productivo es `cgr.dev/chainguard/python:latest` (glibc, Wolfi, intérprete versionado, firmada + SBOM), o `ubi9/ubi-micro` con los RPMs de Python instalados desde una etapa builder `ubi9` vía `dnf --installroot`.

### 3.7 Si tenés que conservar un gestor de paquetes en tiempo de build

```dockerfile
# Debian/Ubuntu
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates=20230311 \
      curl=7.88.1-10+deb12u8 \
 && apt-get purge -y --auto-remove \
 && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# Alpine
RUN apk add --no-cache ca-certificates=20240705-r0 tzdata=2024b-r0

# UBI — install into an empty root, then COPY that root into ubi-micro
FROM registry.access.redhat.com/ubi9/ubi:9.5 AS installer
RUN mkdir -p /mnt/rootfs \
 && dnf install -y --installroot /mnt/rootfs --releasever 9 \
      --setopt install_weak_deps=false --nodocs \
      python3.12 \
 && dnf --installroot /mnt/rootfs clean all \
 && rm -rf /mnt/rootfs/var/cache/* /mnt/rootfs/var/log/dnf* /mnt/rootfs/var/log/yum.*

FROM registry.access.redhat.com/ubi9/ubi-micro:9.5
COPY --from=installer /mnt/rootfs /
```

`--no-install-recommends` por sí solo típicamente elimina el 30–60% de los paquetes transitivos de una instalación Debian. Fijar la versión de cada paquete es lo que hace reproducible al build; sin eso, `apt-get install curl` devuelve un binario distinto el martes que viene y tus atestaciones basadas en digest pierden sentido.

### 3.8 Endurecer la capa final

Aplicá esto en la **última etapa** cuando la base no sea ya distroless:

```dockerfile
# 1. Remove every setuid/setgid bit — kills local privesc primitives.
RUN find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -exec chmod ug-s {} + 2>/dev/null || true

# 2. Remove file capabilities (ping, etc.) — invisible to `find -perm`.
RUN command -v setcap >/dev/null && \
    getcap -r / 2>/dev/null | cut -d' ' -f1 | xargs -r setcap -r || true

# 3. Remove shells and package managers if the base insisted on shipping them.
RUN rm -rf /usr/bin/apt* /usr/bin/dpkg* /sbin/apk /usr/bin/wget /usr/bin/curl \
           /bin/sh /bin/bash /usr/bin/nc /usr/bin/netcat

# 4. Create a numeric non-root identity if the base has none.
RUN echo 'app:x:10001:10001::/nonexistent:/sbin/nologin' >> /etc/passwd && \
    echo 'app:x:10001:' >> /etc/group

USER 10001:10001
```

Verificar:

```console
$ docker run --rm --entrypoint /bin/sh webapp:hardened -c 'find / -xdev -perm /6000 -type f 2>/dev/null'
# (no output — but note: you needed a shell to run this. Do it in the build stage,
#  or from outside with `docker export | tar tv`, see §5.1)

$ docker export $(docker create webapp:min) | tar -tvf - | awk '$1 ~ /^[-l]/ && $1 ~ /s/'
# empty → no setuid/setgid files in the image at all
```

### 3.9 Reproducibilidad: fijá por digest, no por tag

Un tag es un puntero mutable. `FROM alpine:3.20` hoy y mañana pueden ser imágenes distintas con conjuntos de CVEs distintos, lo que rompe el análisis forense de incidentes ("¿qué imagen estaba corriendo realmente?") y anula cualquier atestación.

```console
$ crane digest gcr.io/distroless/static-debian12:nonroot
sha256:3f2b64ef97bd285e36132c684e6b2ae8f2fb1fa8bda9c0e5b3f0bd1f1b12e26f

$ docker buildx imagetools inspect gcr.io/distroless/static-debian12:nonroot
Name:      gcr.io/distroless/static-debian12:nonroot
MediaType: application/vnd.oci.image.index.v1+json
Digest:    sha256:3f2b64ef97bd285e36132c684e6b2ae8f2fb1fa8bda9c0e5b3f0bd1f1b12e26f

Manifests:
  Name:      gcr.io/distroless/static-debian12:nonroot@sha256:1c2b...
  Platform:  linux/amd64
  Name:      gcr.io/distroless/static-debian12:nonroot@sha256:9d4e...
  Platform:  linux/arm64
```

Fijá **el digest del índice** (seguro para multi-arquitectura) en el Dockerfile, y automatizá las actualizaciones con Renovate/Dependabot para que fijar no se convierta en "congelado y sin parchear" — el modo de falla que hace que los equipos abandonen la práctica de fijar.

Para reconstrucciones idénticas byte a byte, normalizá además las marcas de tiempo:

```console
$ SOURCE_DATE_EPOCH=$(git log -1 --pretty=%ct) \
  docker buildx build --build-arg SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH \
    --output type=image,name=webapp:min,rewrite-timestamp=true .
```

### 3.10 Higiene de capas — los secretos son para siempre

```dockerfile
# WRONG — the token is in layer 3 forever, regardless of the rm in layer 4.
COPY .npmrc /root/.npmrc
RUN npm ci
RUN rm /root/.npmrc

# RIGHT — BuildKit secret mount: never materialized in any layer.
RUN --mount=type=secret,id=npmrc,target=/root/.npmrc,uid=0 \
    npm ci --omit=dev
```

```console
$ docker buildx build --secret id=npmrc,src=$HOME/.npmrc -t app:build .
```

Detectar filtraciones en una imagen existente:

```console
$ docker history --no-trunc --format '{{.Size}}\t{{.CreatedBy}}' webapp:fat | head -5
121MB   /bin/sh -c apt-get update && apt-get install -y golang-go ca-certificates curl vim net-tools
0B      /bin/sh -c #(nop) COPY dir:8a3f... in /src
6.15MB  /bin/sh -c go build -o /usr/local/bin/webapp .

$ docker save webapp:fat -o /tmp/fat.tar && trivy image --scanners secret --input /tmp/fat.tar
```

---

## 4. El lado de Kubernetes — hacer que la imagen mínima rinda

Una imagen mínima sin un `securityContext` acorde deja la mayor parte del beneficio sin aprovechar. Este es el manifiesto que espera un evaluador de CKS.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp
  namespace: prod
  labels:
    app.kubernetes.io/name: webapp
spec:
  replicas: 3
  revisionHistoryLimit: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: webapp
  template:
    metadata:
      labels:
        app.kubernetes.io/name: webapp
    spec:
      automountServiceAccountToken: false      # the app never calls the API server
      serviceAccountName: webapp
      # Pod-level context: applies to every container unless overridden.
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        fsGroup: 65532
        seccompProfile:
          type: RuntimeDefault                 # blocks ~44 dangerous syscalls
      containers:
        - name: webapp
          # Digest-pinned: the tag is documentation, the digest is the contract.
          image: registry.example.com/team/webapp:1.4.2@sha256:5b7e2c9d1a4f8e6b0c3d2a1f9e8d7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a2f1e0d
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          securityContext:
            allowPrivilegeEscalation: false    # no_new_privs; neutralizes any setuid bit
            privileged: false
            readOnlyRootFilesystem: true       # no writable path => no dropped payloads
            capabilities:
              drop: ["ALL"]                    # not even NET_BIND_SERVICE (we bind 8080)
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 500m
              memory: 128Mi
              ephemeral-storage: 256Mi
          # The image has no shell — probes MUST be httpGet/tcpSocket, never exec.
          startupProbe:
            httpGet: { path: /healthz, port: http }
            failureThreshold: 30
            periodSeconds: 2
          livenessProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 10
            timeoutSeconds: 2
          readinessProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 5
            timeoutSeconds: 2
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            - name: cache
              mountPath: /var/cache/app
      volumes:
        # readOnlyRootFilesystem makes these the ONLY writable paths, and they are
        # mounted noexec/nosuid/nodev-equivalent from the workload's point of view
        # because the kernel still honours the emptyDir's mount options on the node.
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 32Mi
        - name: cache
          emptyDir:
            sizeLimit: 128Mi
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: webapp
  namespace: prod
automountServiceAccountToken: false
---
apiVersion: v1
kind: Service
metadata:
  name: webapp
  namespace: prod
spec:
  selector:
    app.kubernetes.io/name: webapp
  ports:
    - name: http
      port: 80
      targetPort: http
```

Línea base a nivel de namespace vía Pod Security Admission:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: prod
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.34
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.34
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.34
```

### 4.1 Forzar la procedencia de imágenes con ValidatingAdmissionPolicy (sin controlador externo)

`ValidatingAdmissionPolicy` alcanzó GA en v1.30 y es la forma in-tree, basada en CEL, de imponer reglas sobre imágenes en un clúster 1.34. Esto es relevante para el examen porque no necesita ni un chart de Helm ni TLS de webhook.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: minimal-image-policy
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["pods"]
  variables:
    - name: allContainers
      expression: >-
        object.spec.containers +
        (has(object.spec.initContainers) ? object.spec.initContainers : []) +
        (has(object.spec.ephemeralContainers) ? object.spec.ephemeralContainers : [])
    - name: allowedRegistries
      expression: "['registry.example.com/', 'gcr.io/distroless/', 'cgr.dev/chainguard/']"
  validations:
    # 1. Registry allow-list.
    - expression: >-
        variables.allContainers.all(c,
          variables.allowedRegistries.exists(r, c.image.startsWith(r)))
      message: "image must come from an approved registry (registry.example.com, gcr.io/distroless, cgr.dev/chainguard)"
      reason: Forbidden

    # 2. Digest pinning — rejects :latest and every mutable tag.
    - expression: "variables.allContainers.all(c, c.image.contains('@sha256:'))"
      message: "image must be pinned by digest (name:tag@sha256:...)"
      reason: Forbidden

    # 3. Refuse the distroless :debug variants in this cluster.
    - expression: "variables.allContainers.all(c, !c.image.contains(':debug'))"
      message: "distroless :debug images ship a shell and are not allowed here"
      reason: Forbidden

    # 4. Enforce the securityContext that makes a minimal image worth having.
    - expression: >-
        variables.allContainers.all(c,
          has(c.securityContext) &&
          has(c.securityContext.readOnlyRootFilesystem) &&
          c.securityContext.readOnlyRootFilesystem == true)
      message: "readOnlyRootFilesystem: true is required"
      reason: Forbidden
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: minimal-image-policy-binding
spec:
  policyName: minimal-image-policy
  validationActions: ["Deny", "Audit"]
  matchResources:
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system", "kube-node-lease"]
```

```console
$ kubectl apply -f vap-minimal-image.yaml
validatingadmissionpolicy.admissionregistration.k8s.io/minimal-image-policy created
validatingadmissionpolicybinding.admissionregistration.k8s.io/minimal-image-policy-binding created

$ kubectl -n prod run bad --image=nginx:latest
Error from server (Forbidden): admission webhook denied the request:
ValidatingAdmissionPolicy 'minimal-image-policy' with binding 'minimal-image-policy-binding'
denied request: image must come from an approved registry
(registry.example.com, gcr.io/distroless, cgr.dev/chainguard)

$ kubectl -n prod run dbg --image=gcr.io/distroless/static-debian12:debug-nonroot
Error from server (Forbidden): ... denied request: image must be pinned by digest (name:tag@sha256:...)
```

Política Kyverno equivalente, para clústeres que ya lo ejecutan:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-image-footprint
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: allowed-registries
      match:
        any:
          - resources:
              kinds: ["Pod"]
      exclude:
        any:
          - resources:
              namespaces: ["kube-system"]
      validate:
        message: "Images must originate from an approved minimal-base registry."
        pattern:
          spec:
            =(ephemeralContainers):
              - image: "registry.example.com/* | gcr.io/distroless/* | cgr.dev/chainguard/*"
            =(initContainers):
              - image: "registry.example.com/* | gcr.io/distroless/* | cgr.dev/chainguard/*"
            containers:
              - image: "registry.example.com/* | gcr.io/distroless/* | cgr.dev/chainguard/*"
    - name: require-digest
      match:
        any:
          - resources:
              kinds: ["Pod"]
      validate:
        message: "Images must be referenced by digest."
        foreach:
          - list: "request.object.spec.containers"
            deny:
              conditions:
                all:
                  - key: "{{ contains(element.image, '@sha256:') }}"
                    operator: Equals
                    value: false
```

### 4.2 A nivel de nodo: recolección de basura de imágenes del kubelet

```yaml
# /var/lib/kubelet/config.yaml  (KubeletConfiguration)
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
imageGCHighThresholdPercent: 80    # start GC when imagefs usage exceeds this
imageGCLowThresholdPercent: 65     # GC until usage drops below this
imageMinimumGCAge: 5m              # never delete images younger than this
imageMaximumGCAge: 168h            # delete unused images older than 7 days (v1.30+)
serializeImagePulls: false
maxParallelImagePulls: 5
evictionHard:
  imagefs.available: "10%"
  nodefs.available: "10%"
```

```console
$ sudo systemctl restart kubelet
$ kubectl get --raw "/api/v1/nodes/node-1/proxy/configz" | jq '.kubeletconfig | {imageGCHighThresholdPercent, imageMaximumGCAge}'
{
  "imageGCHighThresholdPercent": 80,
  "imageMaximumGCAge": "168h0m0s"
}
```

---

## 5. Verificación y diagnóstico de fallas

### 5.1 Inspeccionar una imagen sin ejecutarla

Esta es la habilidad que separa a un operador de un usuario: no podés hacer `exec` dentro de una imagen distroless, así que toda la inspección tiene que ocurrir desde afuera.

```console
# Full config: entrypoint, user, env, architecture — no pull of the layers needed for the config alone
$ crane config gcr.io/distroless/static-debian12:nonroot | jq '{user: .config.User, entrypoint: .config.Entrypoint, arch: .architecture, os: .os}'
{
  "user": "65532:65532",
  "entrypoint": null,
  "arch": "amd64",
  "os": "linux"
}

# Enumerate every file in the image without executing anything
$ crane export webapp:min - | tar -tvf - | head -20
drwxr-xr-x  0/0               0 2026-08-04 00:00 etc/
-rw-r--r--  0/0             363 1970-01-01 00:00 etc/passwd
-rw-r--r--  0/0             225 1970-01-01 00:00 etc/group
-rw-r--r--  0/0              41 1970-01-01 00:00 etc/nsswitch.conf
drwxr-xr-x  0/0               0 1970-01-01 00:00 etc/ssl/certs/
-rw-r--r--  0/0          200330 1970-01-01 00:00 etc/ssl/certs/ca-certificates.crt
drwxrwxrwt  0/0               0 1970-01-01 00:00 tmp/
drwxr-xr-x  0/0               0 1970-01-01 00:00 usr/share/zoneinfo/
-rwxr-xr-x  65532/65532 7208960 1970-01-01 00:00 usr/local/bin/webapp

# Count executables — the real "footprint" metric
$ crane export webapp:min - | tar -tvf - | awk '$1 ~ /x/ && $1 ~ /^-/ {n++} END {print n" executable files"}'
1 executable files

$ crane export webapp:fat - | tar -tvf - | awk '$1 ~ /x/ && $1 ~ /^-/ {n++} END {print n" executable files"}'
1743 executable files

# Any setuid/setgid?
$ crane export webapp:fat - | tar -tvf - | awk '$1 ~ /s/ {print $1, $6}'
-rwsr-xr-x usr/bin/passwd
-rwsr-xr-x usr/bin/su
-rwsr-xr-x usr/bin/chsh
-rwsr-xr-x usr/bin/mount
-rwxr-sr-x usr/bin/wall

# Layer-by-layer waste analysis
$ dive webapp:fat --ci --lowestEfficiency=0.95
Analyzing image...
efficiency: 78.3141 %
wastedBytes: 141283042 bytes (141 MB)
userWastedPercent: 16.6721 %
Result:FAIL  [Total:3] [Passed:2] [Failed:1]

# Skopeo works without a Docker daemon — useful on exam nodes
$ skopeo inspect docker://gcr.io/distroless/static-debian12:nonroot | jq '{Digest, Layers: (.Layers|length)}'
{
  "Digest": "sha256:3f2b64ef97bd285e36132c684e6b2ae8f2fb1fa8bda9c0e5b3f0bd1f1b12e26f",
  "Layers": 2
}
```

Generador reproducible de la tabla de tamaños:

```bash
#!/usr/bin/env bash
# bases.sh — reproduce the §2.1 table on your own architecture
set -euo pipefail
BASES=(
  "gcr.io/distroless/static-debian12:nonroot"
  "gcr.io/distroless/base-debian12:nonroot"
  "gcr.io/distroless/cc-debian12:nonroot"
  "cgr.dev/chainguard/static:latest"
  "alpine:3.20"
  "debian:12-slim"
  "ubuntu:24.04"
  "registry.access.redhat.com/ubi9/ubi-micro:9.5"
  "registry.access.redhat.com/ubi9/ubi-minimal:9.5"
)
printf '%-55s %10s %8s %8s\n' IMAGE SIZE HIGH CRIT
for b in "${BASES[@]}"; do
  docker pull -q "$b" >/dev/null
  size=$(docker image inspect "$b" --format '{{.Size}}' | numfmt --to=iec)
  json=$(trivy image --quiet --format json --scanners vuln "$b")
  high=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH")]  | length' <<<"$json")
  crit=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length' <<<"$json")
  printf '%-55s %10s %8s %8s\n' "$b" "$size" "$high" "$crit"
done
```

### 5.2 Escaneo y SBOM

```console
$ trivy image --scanners vuln,secret,misconfig --severity HIGH,CRITICAL \
      --exit-code 1 --ignore-unfixed registry.example.com/team/webapp:1.4.2
2026-08-04T11:02:14Z  INFO  Vulnerability scanning is enabled
2026-08-04T11:02:14Z  INFO  Secret scanning is enabled
registry.example.com/team/webapp:1.4.2 (debian 12.8)
Total: 0 (HIGH: 0, CRITICAL: 0)

/usr/local/bin/webapp (gobinary)
Total: 0 (HIGH: 0, CRITICAL: 0)

$ echo $?
0

# Generate and store an SBOM alongside the image
$ syft registry.example.com/team/webapp:1.4.2 -o spdx-json=sbom.spdx.json
 ✔ Parsed image        sha256:5b7e2c9d1a4f...
 ✔ Cataloged contents  sha256:5b7e2c9d1a4f...
   ├── ✔ Packages           [4 packages]
   └── ✔ Executables        [1 executables]

$ jq -r '.packages[].name' sbom.spdx.json
base-files
ca-certificates
netbase
tzdata

$ grype sbom:sbom.spdx.json --fail-on high
 ✔ Scanned for vulnerabilities     [0 vulnerability matches]
No vulnerabilities found
```

Cuatro paquetes. Esa es toda la superficie de mantenimiento a nivel de sistema operativo del servicio.

### 5.3 Depurar un contenedor que no tiene shell

**Este es el costo operativo de las imágenes mínimas y la pregunta de seguimiento favorita del examen.** No podés hacer `kubectl exec -it pod -- sh`. Tres técnicas, en orden de preferencia:

**(a) Contenedor efímero compartiendo el namespace de procesos del objetivo**

```console
$ kubectl -n prod debug -it webapp-6f8d9c7b54-x2n4p \
    --image=busybox:1.36 \
    --target=webapp \
    --profile=general \
    -- sh
Targeting container "webapp". If you don't see processes from this container it may be
because the container runtime doesn't support this feature.
Defaulting debug container name to debugger-mqz7k.
If you don't see a command prompt, try pressing enter.

/ # ps aux
PID   USER     COMMAND
    1 65532    /usr/local/bin/webapp
   14 root     sh
   21 root     ps aux

/ # ls /proc/1/root/usr/local/bin/
webapp

/ # cat /proc/1/environ | tr '\0' '\n'
PATH=/usr/local/bin:/usr/bin:/bin
HOSTNAME=webapp-6f8d9c7b54-x2n4p
HOME=/home/nonroot

/ # wget -qO- http://localhost:8080/healthz
ok

/ # cat /proc/1/net/tcp | head -3
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid
   0: 00000000:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000 65532
```

`--target=<container>` es lo que comparte el namespace de PID, dándote `/proc/1/root` — una vista completa del sistema de archivos del objetivo desde un contenedor que *sí* tiene herramientas. Sin `--target`, solo compartís el namespace de red.

**(b) Depuración a nivel de nodo con `kubectl debug node/`**

```console
$ kubectl debug node/worker-2 -it --image=busybox:1.36
Creating debugging pod node-debugger-worker-2-hb4kq with container debugger on node worker-2.

/ # chroot /host
# crictl ps --name webapp
CONTAINER      IMAGE          CREATED         STATE     NAME      POD ID
7d9a1c4e2b8f3  5b7e2c9d1a4f   18 minutes ago  Running   webapp    2f8e1a9c7d3b5

# crictl inspect 7d9a1c4e2b8f3 | jq '.info.pid, .status.image.image'
14472
"registry.example.com/team/webapp@sha256:5b7e2c9d1a4f..."

# nsenter -t 14472 -m -n -p -- /usr/local/bin/webapp --version
webapp 1.4.2

# ls -l /proc/14472/root/
total 0
drwxr-xr-x 2 root root 60 Aug  4 11:02 etc
drwxrwxrwt 2 root root 40 Aug  4 11:02 tmp
drwxr-xr-x 3 root root 60 Aug  4 11:02 usr
```

**(c) Reconstruir una vez con el tag `:debug` — nunca la publiques**

```console
$ docker build --build-arg BASE=gcr.io/distroless/static-debian12:debug-nonroot -t webapp:dbg .
$ kubectl -n staging set image deploy/webapp webapp=registry.example.com/team/webapp:dbg
$ kubectl -n staging exec -it deploy/webapp -- /busybox/sh
/ $ id
uid=65532(nonroot) gid=65532(nonroot)
```

> Los contenedores efímeros no se pueden eliminar de un pod una vez agregados, y eluden el PSA `restricted` a nivel de namespace solo si tus políticas de VAP/Kyverno permiten explícitamente `ephemeralContainers` — por eso la política de §4.1 los incluye en `variables.allContainers`. Otorgá el RBAC de `pods/ephemeralcontainers` de forma deliberada; es efectivamente "hacer exec en cualquier cosa con cualquier imagen".

### 5.4 Catálogo de fallas — síntoma → causa raíz → solución

| ID | Síntoma (cadena exacta) | Causa raíz | Solución |
|---|---|---|---|
| F-01 | `exec /usr/local/bin/app: no such file or directory` — *y el archivo demostrablemente existe* | El binario está enlazado dinámicamente; el kernel no encuentra el intérprete ELF `/lib64/ld-linux-x86-64.so.2`, ausente en `scratch`/`static` | `CGO_ENABLED=0`, o pasar a `distroless/base` y copiar el cierre de `ldd` (§3.3) |
| F-02 | `sh: /app/bin/svc: not found` en Alpine | Binario enlazado con glibc sobre musl — BusyBox reporta el loader faltante como "not found" | Compilar con el target musl (`GOOS=linux CGO_ENABLED=0`, o `--target x86_64-unknown-linux-musl` para Rust), o usar una base con glibc |
| F-03 | `x509: certificate signed by unknown authority` | No hay `/etc/ssl/certs/ca-certificates.crt` en `scratch` | Usar `distroless/static` (incluye el bundle), o `COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/` |
| F-04 | `open /tmp/upload-9182: no such file or directory` | `scratch` no tiene `/tmp`; o `readOnlyRootFilesystem: true` sin un `emptyDir` en `/tmp` | Usar distroless (`/tmp` modo 1777) **y** montar un `emptyDir` en `/tmp` |
| F-05 | Pod trabado en `CreateContainerConfigError`: `container has runAsNonRoot and image has non-numeric user (nonroot), cannot verify user is non-root` | El kubelet no puede resolver un `USER` *con nombre* en tiempo de admisión — no tiene acceso al `/etc/passwd` dentro de la imagen | Usar un `USER 65532:65532` numérico en el Dockerfile **o** definir `securityContext.runAsUser: 65532` |
| F-06 | `user: unknown userid 65532` (Go `user.Current()`, Java `System.getProperty("user.name")`) | `/etc/passwd` no tiene entrada para el UID en ejecución | Usar el tag distroless `:nonroot`, o agregar la entrada (§3.8 paso 4) |
| F-07 | `time: missing Location in call to Time.In` / todas las marcas de tiempo en UTC | No hay `/usr/share/zoneinfo` | `import _ "time/tzdata"` (Go), o `COPY --from=build /usr/share/zoneinfo /usr/share/zoneinfo` |
| F-08 | `lookup svc.ns.svc.cluster.local: no such host` intermitente en Alpine | musl < 1.2.4 no tiene fallback a TCP en DNS; las respuestas > 512 B (Services headless grandes) se truncan y se descartan | Alpine ≥ 3.18, o reducir `ndots`/dominios de búsqueda vía `dnsConfig`, o salir de musl |
| F-09 | `exec /app: exec format error` | La arquitectura de la imagen ≠ la del nodo (imagen amd64 en nodo arm64) | `crane config <img> \| jq .architecture`; reconstruir con `docker buildx build --platform linux/amd64,linux/arm64` |
| F-10 | El contenedor arranca y luego da `read-only file system` en la primera escritura | `readOnlyRootFilesystem: true`, la aplicación escribe fuera de un volumen montado | Identificar las rutas (`strace` vía contenedor efímero, o la documentación de la aplicación) y agregar montajes `emptyDir`; **no** desactives la bandera |
| F-11 | `Error: Cannot find module '/app/dist/server.js'` en distroless nodejs | El `ENTRYPOINT` de la base ya es `node`; un `CMD ["node", "dist/server.js"]` se convierte en `node node dist/server.js` | Usar solo `CMD ["dist/server.js"]` |
| F-12 | `java.lang.NoClassDefFoundError: javax.naming.*` después de jlink | `jdeps` se perdió un módulo cargado por reflexión | Agregarlo explícitamente: `--add-modules $(cat deps.txt),java.naming,jdk.crypto.ec,jdk.localedata` |
| F-13 | `Liveness probe failed: OCI runtime exec failed: exec: "sh": executable file not found` | Probe de tipo `exec` contra una imagen sin shell | Convertir las probes a `httpGet` o `tcpSocket` |
| F-14 | `ImportError: cannot import name ... from 'site-packages'` en distroless python | El venv se construyó contra una versión menor de Python distinta a la que trae la base | Hacer coincidir exactamente las versiones del intérprete, o migrar a `cgr.dev/chainguard/python` |
| F-15 | El escáner reporta `Total: 0` en una imagen `scratch` con bibliotecas viejas evidentes | No hay base de datos de paquetes → nada que enumerar; esto es un *punto ciego*, no un certificado de buena salud | Usar distroless (trae `/var/lib/dpkg/status.d/`); escanear la capa del lenguaje explícitamente (`trivy fs`, `syft` sobre el binario) |

Reproducción de F-01, la que vale la pena hacer a mano:

```console
$ CGO_ENABLED=1 go build -o webapp . && docker build -f - -t webapp:broken . <<'EOF'
FROM gcr.io/distroless/static-debian12:nonroot
COPY webapp /webapp
ENTRYPOINT ["/webapp"]
EOF

$ docker run --rm webapp:broken
exec /webapp: no such file or directory

$ file webapp
webapp: ELF 64-bit LSB pie executable, x86-64, dynamically linked,
        interpreter /lib64/ld-linux-x86-64.so.2, Go BuildID=..., not stripped

$ ldd webapp
	linux-vdso.so.1 (0x00007ffd4b3f2000)
	libresolv.so.2 => /lib/x86_64-linux-gnu/libresolv.so.2 (0x00007f2a8c1f4000)
	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f2a8c000000)
	/lib64/ld-linux-x86-64.so.2 (0x00007f2a8c21e000)

$ CGO_ENABLED=0 go build -o webapp . && file webapp
webapp: ELF 64-bit LSB executable, x86-64, statically linked, Go BuildID=..., stripped
```

---

## 6. Aplicación en CI

```yaml
# .github/workflows/build.yaml
name: build-and-harden
on:
  push:
    branches: [main]

permissions:
  contents: read
  packages: write
  id-token: write        # for keyless cosign signing

jobs:
  image:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4

      - name: Set up Buildx
        uses: docker/setup-buildx-action@v3

      - name: Build (load locally, do not push yet)
        uses: docker/build-push-action@v6
        with:
          context: .
          load: true
          tags: webapp:candidate
          provenance: mode=max
          sbom: true
          build-args: |
            VERSION=${{ github.sha }}
            SOURCE_DATE_EPOCH=0

      # Gate 1 — footprint budget. A regression here means someone added a base layer.
      - name: Enforce size budget
        run: |
          BYTES=$(docker image inspect webapp:candidate --format '{{.Size}}')
          MAX=$((30 * 1024 * 1024))
          echo "image size: $((BYTES/1024/1024)) MiB (budget $((MAX/1024/1024)) MiB)"
          [ "$BYTES" -le "$MAX" ] || { echo "::error::image exceeds size budget"; exit 1; }

      # Gate 2 — no shell, no package manager, no setuid.
      - name: Enforce executable surface
        run: |
          docker create --name c webapp:candidate
          docker export c | tar -tvf - > /tmp/files.txt
          docker rm c
          if grep -Eq '(bin/(ba|a|da|z|)sh|bin/busybox|bin/apt|bin/dpkg|sbin/apk|bin/dnf|bin/microdnf)$' /tmp/files.txt; then
            echo "::error::shell or package manager present in final image"; grep -E 'sh$|apt|apk|dnf' /tmp/files.txt; exit 1
          fi
          if awk '$1 ~ /^-.*s/' /tmp/files.txt | grep -q .; then
            echo "::error::setuid/setgid binaries present"; awk '$1 ~ /^-.*s/' /tmp/files.txt; exit 1
          fi

      # Gate 3 — non-root numeric user.
      - name: Enforce non-root numeric UID
        run: |
          USER=$(docker image inspect webapp:candidate --format '{{.Config.User}}')
          echo "image USER = '${USER}'"
          case "$USER" in
            ""|root|0|0:*) echo "::error::image runs as root"; exit 1 ;;
            [0-9]*)        echo "ok: numeric UID" ;;
            *)             echo "::error::USER must be numeric for runAsNonRoot"; exit 1 ;;
          esac

      # Gate 4 — vulnerabilities.
      - name: Trivy scan
        uses: aquasecurity/trivy-action@0.28.0
        with:
          image-ref: webapp:candidate
          format: sarif
          output: trivy.sarif
          severity: HIGH,CRITICAL
          ignore-unfixed: true
          exit-code: '1'

      - name: Upload SARIF
        if: always()
        uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: trivy.sarif

      # Gate 5 — Dockerfile static analysis (CKS 4.4 overlap).
      - name: Hadolint
        uses: hadolint/hadolint-action@v3.1.0
        with:
          dockerfile: Dockerfile
          failure-threshold: warning

      - name: Push and sign
        run: |
          docker tag webapp:candidate ghcr.io/${{ github.repository }}:${{ github.sha }}
          docker push ghcr.io/${{ github.repository }}:${{ github.sha }}
          DIGEST=$(docker image inspect ghcr.io/${{ github.repository }}:${{ github.sha }} \
                     --format '{{index .RepoDigests 0}}')
          cosign sign --yes "$DIGEST"
          echo "DIGEST=$DIGEST" >> "$GITHUB_STEP_SUMMARY"
```

---

## 7. Checklist para el examen

Cuando una tarea de CKS dice *"minimizá la huella de esta imagen"*, las acciones evaluadas son, en orden:

1. **Convertir a multi-etapa.** El compilador, las fuentes y las cachés no deben aparecer en la etapa final.
2. **Cambiar la base de runtime** a `gcr.io/distroless/static-debian12:nonroot` (binarios estáticos) o la variante distroless/Alpine correspondiente. No dejes `ubuntu`/`debian` como etapa final.
3. **Agregar un `USER` numérico.** `USER 65532:65532`, nunca `USER nonroot` si el manifiesto define `runAsNonRoot: true`.
4. **Eliminar las herramientas** que no necesitabas: `curl`, `wget`, `vim`, `net-tools`, build-essential.
5. **Limpiar el estado del gestor de paquetes** en la misma capa `RUN`: `rm -rf /var/lib/apt/lists/*`, `apk add --no-cache`, `microdnf clean all`.
6. **Fijar versiones** — la base por digest, los paquetes por versión.
7. **Hacer coincidir el manifiesto del Pod**: `runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]`, `seccompProfile: RuntimeDefault`, más un `emptyDir` para cada ruta escribible.
8. **Convertir las probes `exec`** a `httpGet`/`tcpSocket` — el shell ya no está.
9. **Verificar** con `docker image ls`, `trivy image --severity HIGH,CRITICAL` y `docker run --rm --entrypoint sh <img>` (debe fallar).

Atajos para ganar tiempo en condiciones de examen:

```console
$ kubectl create deploy web --image=IMG --dry-run=client -o yaml > d.yaml
$ kubectl explain pod.spec.containers.securityContext --recursive | head -30
$ kubectl -n prod debug -it POD --image=busybox:1.36 --target=CONTAINER -- sh
$ trivy image --severity HIGH,CRITICAL --quiet IMG
```

---

## Referencias

**Examen y currícula**
- CKS Curriculum v1.34 — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Repositorio de currícula de la CNCF — https://github.com/cncf/curriculum
- Linux Foundation, Certified Kubernetes Security Specialist — https://training.linuxfoundation.org/certification/certified-kubernetes-security-specialist-cks/

**Documentación de Kubernetes**
- Images — https://kubernetes.io/docs/concepts/containers/images/
- Configure a Security Context for a Pod or Container — https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Pod Security Admission — https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Validating Admission Policy — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Ephemeral Containers — https://kubernetes.io/docs/concepts/workloads/pods/ephemeral-containers/
- Debug Running Pods — https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Garbage Collection (recolección de imágenes y contenedores) — https://kubernetes.io/docs/concepts/architecture/garbage-collection/
- Kubelet Configuration (v1beta1) — https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
- Seccomp for a Container — https://kubernetes.io/docs/tutorials/security/seccomp/
- Node-pressure Eviction — https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/
- Cloud Native Security Overview (modelo 4C) — https://kubernetes.io/docs/concepts/security/overview/

**Herramientas de build**
- Referencia de Dockerfile — https://docs.docker.com/reference/dockerfile/
- Multi-stage builds — https://docs.docker.com/build/building/multi-stage/
- Build secrets — https://docs.docker.com/build/building/secrets/
- BuildKit cache mounts — https://docs.docker.com/build/cache/optimize/
- Builds reproducibles con BuildKit — https://docs.docker.com/build/ci/github-actions/reproducible-builds/
- Imágenes multiplataforma — https://docs.docker.com/build/building/multi-platform/
- OCI Image Format Specification — https://github.com/opencontainers/image-spec

**Imágenes base**
- Distroless (GoogleContainerTools) — https://github.com/GoogleContainerTools/distroless
- Imágenes base y tags de distroless — https://github.com/GoogleContainerTools/distroless/blob/main/base/README.md
- Chainguard Images — https://images.chainguard.dev/ y https://edu.chainguard.dev/chainguard/chainguard-images/
- Wolfi OS — https://github.com/wolfi-dev/os
- Red Hat Universal Base Image — https://catalog.redhat.com/software/base-images
- Construir imágenes UBI micro — https://developers.redhat.com/articles/2021/12/13/build-ubi-micro-container-images
- Alpine Linux — https://alpinelinux.org/ ; diferencias funcionales de musl vs glibc — https://wiki.musl-libc.org/functional-differences-from-glibc.html

**Específico de cada lenguaje**
- Go: flags de build de `cmd/go` — https://pkg.go.dev/cmd/go#hdr-Compile_packages_and_dependencies
- Go: `time/tzdata` — https://pkg.go.dev/time/tzdata
- JDK: `jlink` — https://docs.oracle.com/en/java/javase/21/docs/specs/man/jlink.html
- JDK: `jdeps` — https://docs.oracle.com/en/java/javase/21/docs/specs/man/jdeps.html
- npm `ci` y `--ignore-scripts` — https://docs.npmjs.com/cli/v10/commands/npm-ci

**Escaneo, inspección, políticas**
- Trivy — https://trivy.dev/latest/docs/
- Grype — https://github.com/anchore/grype
- Syft (SBOM) — https://github.com/anchore/syft
- Dive — https://github.com/wagoodman/dive
- crane (go-containerregistry) — https://github.com/google/go-containerregistry/blob/main/cmd/crane/README.md
- Skopeo — https://github.com/containers/skopeo
- Hadolint — https://github.com/hadolint/hadolint
- Políticas de Kyverno — https://kyverno.io/policies/
- Sigstore cosign — https://docs.sigstore.dev/cosign/signing/overview/

**Estándares y guías**
- NIST SP 800-190, Application Container Security Guide — https://csrc.nist.gov/publications/detail/sp/800-190/final
- CIS Docker Benchmark — https://www.cisecurity.org/benchmark/docker
- CIS Kubernetes Benchmark — https://www.cisecurity.org/benchmark/kubernetes
- OpenSSF Secure Supply Chain Consumption Framework — https://openssf.org/projects/s2c2f/
- SLSA — https://slsa.dev/spec/v1.0/
- Reproducible Builds, `SOURCE_DATE_EPOCH` — https://reproducible-builds.org/docs/source-date-epoch/