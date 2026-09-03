# 702.3 — Construcción de Imágenes de Contenedor
## Ejercicios Guiados

**Certificación:** LPI DevOps Tools Engineer — Examen 701-100, versión 2.0.0
**Objetivo:** 702.3 Container Image Building — **peso del examen 8.33**
**Formato:** pasos numerados que ejecutás, seguidos de puntos de control de comprensión. Todas las respuestas están en la sección plegable al final.

---

### Entorno y convenciones

Cada digest, ID de imagen y tamaño en bytes impreso en este documento es **representativo**. Los tuyos van a diferir — las imágenes base se reconstruyen upstream y el contenido de las capas depende del host y de la fecha. Lo que sí debe coincidir es la *forma* de la salida y las *relaciones* entre valores (mismo digest ⇒ mismos bytes, digest distinto ⇒ bytes distintos).

Requisitos: Docker Engine ≥ 23 (BuildKit es el builder por defecto a partir de esa versión), o Podman ≥ 4 donde se indique. Acceso de red a Docker Hub. Aproximadamente 3 GB de disco libre.

```bash
docker version --format 'client={{.Client.Version}} server={{.Server.Version}}'
docker buildx version
docker info --format 'storage-driver={{.Driver}} rootless={{.SecurityOptions}}'
```

```
client=27.3.1 server=27.3.1
github.com/docker/buildx v0.17.1
storage-driver=overlay2 rootless=[name=seccomp,profile=builtin name=cgroupns]
```

Creá un espacio de trabajo temporal usado por todos los ejercicios:

```bash
mkdir -p ~/lab-702.3 && cd ~/lab-702.3
```

---

## Ejercicio 1 — Anatomía de una imagen: capas, config, manifest

Antes de escribir un `Dockerfile`, necesitás un modelo mental preciso de lo que una build *produce*. Una imagen OCI no es un sistema de archivos — es un **blob JSON de configuración** más una **lista ordenada de capas tar**, unidos por un **manifest**. El registry almacena los tres como blobs direccionados por contenido.

### Pasos

1. Descargá una imagen base pequeña y mirá lo que registró el daemon.

```bash
docker pull alpine:3.20
docker image ls alpine:3.20
```

```
REPOSITORY   TAG    IMAGE ID       CREATED       SIZE
alpine       3.20   91ef0af61f39   3 weeks ago   8.83MB
```

2. Imprimí la **lista de capas del rootfs**. Estos son `diffID`s — digests SHA-256 del tar *sin comprimir* de cada capa.

```bash
docker image inspect alpine:3.20 --format '{{range .RootFS.Layers}}{{println .}}{{end}}'
```

```
sha256:63ca1fbb43ae5034640e5e6cb3e083e05c290072c5366fcaa9d62435a4cced85
```

3. Ahora pedile el manifest al *registry*. Estos digests son de los blobs **comprimidos** — valores deliberadamente distintos para el mismo contenido.

```bash
docker buildx imagetools inspect --raw alpine:3.20 | head -40
```

```json
{
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "schemaVersion": 2,
  "manifests": [
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:beefdbd8a1da6d2915566fde36db9db0b524eb737fc57cd1367effd16dc0d06d",
      "size": 581,
      "platform": { "architecture": "amd64", "os": "linux" }
    },
    ...
  ]
}
```

4. Inspeccioná la **configuración de la imagen** — la parte que guarda `Env`, `Cmd`, `Entrypoint`, `User`, `WorkingDir` y el historial de build.

```bash
docker image inspect alpine:3.20 \
  --format '{{json .Config}}' | python3 -m json.tool
```

```json
{
    "Hostname": "",
    "Env": [ "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" ],
    "Cmd": [ "/bin/sh" ],
    "WorkingDir": "",
    "Entrypoint": null,
    "Labels": null
}
```

5. Leé el historial de build, incluidos los pasos que produjeron **ningún** cambio en el sistema de archivos.

```bash
docker image history alpine:3.20
```

```
IMAGE          CREATED       CREATED BY                                      SIZE      COMMENT
91ef0af61f39   3 weeks ago   CMD ["/bin/sh"]                                 0B        buildkit.dockerfile.v0
<missing>      3 weeks ago   ADD alpine-minirootfs-3.20.3-x86_64.tar.gz /…   8.83MB    buildkit.dockerfile.v0
```

### Punto de control 1

- **Q1.** El digest en `.RootFS.Layers` y el digest de capa en el manifest del registry describen la misma capa, pero difieren. ¿Por qué, y cuál usa `docker pull` para decidir si puede saltearse una descarga?
- **Q2.** `docker image ls` reporta `8.83MB` para `alpine:3.20`. Si descargás diez imágenes que derivan todas `FROM alpine:3.20`, ¿va a reportar `docker system df` unos 88 MB de datos de imagen? Justificá.
- **Q3.** En `docker image history`, ¿por qué la columna IMAGE de una fila dice `<missing>`, y qué te dice eso sobre si podés hacer `docker run` de una capa intermedia de una imagen que descargaste?
- **Q4.** La fila `CMD ["/bin/sh"]` tiene `SIZE 0B`. ¿Dónde se almacena realmente el efecto de esa instrucción?

---

## Ejercicio 2 — Tu primer Dockerfile, y la mecánica de caché que decide tu tiempo de build

### Pasos

1. Creá una aplicación mínima:

```bash
mkdir -p ~/lab-702.3/app && cd ~/lab-702.3/app
cat > requirements.txt <<'EOF'
flask==3.0.3
EOF
cat > server.py <<'EOF'
from flask import Flask

app = Flask(__name__)


@app.get("/healthz")
def healthz():
    return {"status": "ok"}, 200


@app.get("/")
def index():
    return {"service": "lab-702.3"}, 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
EOF
```

2. Escribí un Dockerfile **deliberadamente mal ordenado**:

```bash
cat > Dockerfile.slow <<'EOF'
# syntax=docker/dockerfile:1.7
FROM python:3.12-slim

WORKDIR /srv
COPY . /srv
RUN pip install --no-cache-dir -r requirements.txt
CMD ["python", "server.py"]
EOF
```

3. Construilo y tomale el tiempo:

```bash
time docker build -f Dockerfile.slow -t lab:slow .
```

```
[+] Building 14.2s (9/9) FINISHED
 => [internal] load build definition from Dockerfile.slow            0.0s
 => [internal] load metadata for docker.io/library/python:3.12-slim  0.9s
 => [internal] load .dockerignore                                    0.0s
 => [internal] load build context                                    0.0s
 => => transferring context: 1.13kB                                  0.0s
 => CACHED [1/4] FROM docker.io/library/python:3.12-slim@sha256:2a3…  0.0s
 => [2/4] WORKDIR /srv                                               0.1s
 => [3/4] COPY . /srv                                                0.0s
 => [4/4] RUN pip install --no-cache-dir -r requirements.txt        11.8s
 => exporting to image                                               1.2s

real    0m14.4s
```

4. Cambiá **una línea de código de la aplicación** — no una dependencia — y reconstruí:

```bash
sed -i 's/"lab-702.3"/"lab-702.3-v2"/' server.py
time docker build -f Dockerfile.slow -t lab:slow .
```

```
 => [3/4] COPY . /srv                                                0.0s
 => [4/4] RUN pip install --no-cache-dir -r requirements.txt        11.6s

real    0m13.9s
```

5. Ahora escribí la versión correctamente ordenada:

```bash
cat > Dockerfile <<'EOF'
# syntax=docker/dockerfile:1.7
FROM python:3.12-slim

WORKDIR /srv

# Dependency manifest first: this layer's cache key changes only when
# requirements.txt changes, not when application code changes.
COPY requirements.txt /srv/requirements.txt
RUN pip install --no-cache-dir -r /srv/requirements.txt

COPY server.py /srv/server.py

EXPOSE 8080
CMD ["python", "server.py"]
EOF

docker build -t lab:fast .
sed -i 's/-v2/-v3/' server.py
time docker build -t lab:fast .
```

```
 => CACHED [2/5] WORKDIR /srv                                        0.0s
 => CACHED [3/5] COPY requirements.txt /srv/requirements.txt         0.0s
 => CACHED [4/5] RUN pip install --no-cache-dir -r /srv/requireme…   0.0s
 => [5/5] COPY server.py /srv/server.py                              0.0s

real    0m0.9s
```

6. Demostrá *por qué* la caché acertó o falló. BuildKit computa una clave de caché por paso; para `COPY`/`ADD` la clave incluye un checksum de los archivos copiados, para `RUN` incluye la cadena literal del comando y la clave del paso padre.

```bash
docker build --progress=plain --no-cache -t lab:fast . 2>&1 | grep -E '^#[0-9]+ '
```

7. Rompé la caché sin tocar ningún archivo, usando solamente la cadena del comando:

```bash
sed -i 's/pip install --no-cache-dir/pip install  --no-cache-dir/' Dockerfile
docker build -t lab:fast .
```

Observá que el paso 4 se reconstruye, por un único espacio extra.

### Punto de control 2

- **Q5.** En el paso 4, `requirements.txt` era idéntico byte a byte, y sin embargo `pip install` se volvió a ejecutar. ¿Qué instrucción invalidó la caché, y qué había exactamente en su clave de caché?
- **Q6.** Explicá con precisión por qué agregar un espacio a la línea `RUN` en el paso 7 forzó una reconstrucción. ¿BuildKit inspecciona alguna vez el *efecto* de un `RUN` para decidir la validez de la caché?
- **Q7.** Un colega no fija nada y escribe `RUN apt-get update && apt-get install -y curl`. Seis semanas después la capa sigue en `CACHED` y distribuye un curl con un CVE conocido. Explicá el modo de falla y dá dos mitigaciones que no impliquen `--no-cache` en cada build.
- **Q8.** ¿Por qué se le pasa `--no-cache-dir` a `pip` acá, si el `RUN` ya se ejecuta en un contenedor de build efímero? ¿Qué quedaría atrás sin eso?
- **Q9.** ¿Cuál es la diferencia práctica entre `docker build --no-cache` y `docker builder prune`?

---

## Ejercicio 3 — Contexto de build y `.dockerignore`

El contexto de build se *sube* al builder antes de que se ejecute la primera instrucción. En un repositorio con un directorio `.git`, un `node_modules` o un `target/`, esto solo puede dominar el tiempo de build — y ampliar silenciosamente tu superficie de ataque vía `COPY . .`.

### Pasos

1. Fabricá un árbol sucio realista:

```bash
cd ~/lab-702.3/app
mkdir -p .git/objects node_modules
head -c 40M /dev/urandom > .git/objects/pack.bin
head -c 25M /dev/urandom > node_modules/blob.bin
echo "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY" > .env
```

2. Construí y leé la línea de transferencia del contexto:

```bash
docker build --no-cache --progress=plain -t lab:ctx . 2>&1 | grep -i 'transferring context'
```

```
#2 [internal] load build context
#2 transferring context: 68.15MB 2.4s done
```

3. Agregá un `.dockerignore` y reconstruí:

```bash
cat > .dockerignore <<'EOF'
# Everything git-related
.git
.gitignore

# Build artefacts and dependency trees rebuilt inside the image
node_modules
__pycache__/
**/*.pyc

# Local configuration and credentials — never in an image
.env
*.pem
*.key
secrets/

# Docker's own files
Dockerfile*
.dockerignore

# Re-include a file that a broad rule above would have excluded
!Dockerfile.keep
EOF

docker build --no-cache --progress=plain -t lab:ctx . 2>&1 | grep -i 'transferring context'
```

```
#2 transferring context: 3.42kB done
```

4. Verificá que el archivo sensible realmente esté ausente de la imagen, y de cada capa:

```bash
docker run --rm lab:ctx ls -la /srv
docker save lab:ctx | tar -tv 2>/dev/null | head
```

5. Confirmá que la regla de negación funciona:

```bash
touch Dockerfile.keep
docker build --no-cache --progress=plain -t lab:ctx . 2>&1 | grep 'transferring context'
```

### Punto de control 3

- **Q10.** `Dockerfile` está listado en `.dockerignore`, y sin embargo la build igual tiene éxito. ¿Por qué eso no es una contradicción?
- **Q11.** Un compañero de equipo argumenta que `.dockerignore` es innecesario porque su Dockerfile solo hace `COPY server.py /srv/`. Dá dos costos concretos que igual está pagando.
- **Q12.** Agregás `.env` a `.dockerignore` *después* de haber construido y publicado `myco/api:1.4.0`. ¿La credencial está ahora a salvo? ¿Cuál es la secuencia correcta de remediación?

---

## Ejercicio 4 — `ARG` vs `ENV`, y la fuga de secretos clásica

### Pasos

1. Escribí un Dockerfile que use argumentos de build en cada posición legal:

```bash
cd ~/lab-702.3/app
cat > Dockerfile.args <<'EOF'
# syntax=docker/dockerfile:1.7

# An ARG declared *before* the first FROM is "global": it is usable in FROM
# lines only, and is NOT inherited by build stages automatically.
ARG PYTHON_VERSION=3.12
ARG BASE=python:${PYTHON_VERSION}-slim

FROM ${BASE} AS runtime

# Re-declaration is mandatory to use a pre-FROM ARG inside a stage.
ARG PYTHON_VERSION
ARG BUILD_REV=unknown
ARG API_TOKEN=none

ENV APP_HOME=/srv \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

LABEL org.opencontainers.image.title="lab-702.3" \
      org.opencontainers.image.revision="${BUILD_REV}" \
      org.opencontainers.image.base.name="${BASE}"

WORKDIR ${APP_HOME}
RUN echo "built on python ${PYTHON_VERSION}, rev ${BUILD_REV}" > /srv/BUILDINFO
RUN echo "token seen at build time: ${API_TOKEN}" >> /srv/BUILDINFO

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY server.py .

CMD ["python", "server.py"]
EOF
```

2. Construí con los argumentos suministrados:

```bash
docker build -f Dockerfile.args \
  --build-arg BUILD_REV="$(git rev-parse --short HEAD 2>/dev/null || echo local)" \
  --build-arg API_TOKEN='s3cr3t-do-not-ship' \
  -t lab:args .
```

3. Investigá qué sobrevivió dentro de la imagen:

```bash
docker run --rm lab:args cat /srv/BUILDINFO
docker image inspect lab:args --format '{{json .Config.Env}}'
docker image inspect lab:args --format '{{json .Config.Labels}}'
```

```
built on python 3.12, rev a91c4f2
token seen at build time: s3cr3t-do-not-ship

["PATH=/usr/local/bin:...","LANG=C.UTF-8","APP_HOME=/srv","PYTHONDONTWRITEBYTECODE=1","PYTHONUNBUFFERED=1"]
{"org.opencontainers.image.base.name":"python:3.12-slim","org.opencontainers.image.revision":"a91c4f2","org.opencontainers.image.title":"lab-702.3"}
```

4. Ahora encontrá la fuga en los metadatos, sin ejecutar el contenedor:

```bash
docker image history --no-trunc lab:args | grep -i token
```

```
<missing>  2 minutes ago  RUN |3 PYTHON_VERSION=3.12 BUILD_REV=a91c4f2 API_TOKEN=s3cr3t-do-not-ship /bin/sh -c echo "token seen at build time: ${API_TOKEN}" >> /srv/BUILDINFO # buildkit    58B
```

5. Demostrá que borrar el archivo en una capa posterior **no** lo elimina:

```bash
cat >> Dockerfile.args <<'EOF'
RUN rm -f /srv/BUILDINFO
EOF
docker build -f Dockerfile.args --build-arg API_TOKEN='s3cr3t-do-not-ship' -t lab:args-rm .
docker run --rm lab:args-rm ls /srv/BUILDINFO || echo "gone from the union mount"
docker image history --no-trunc lab:args-rm | grep -c 's3cr3t' 
```

6. Contrastá `ARG` y `ENV` en tiempo de ejecución:

```bash
docker run --rm lab:args sh -c 'echo "ARG=[${BUILD_REV}] ENV=[${APP_HOME}]"'
```

```
ARG=[] ENV=[/srv]
```

### Punto de control 4

- **Q13.** ¿Por qué `BUILD_REV` está vacío en tiempo de ejecución mientras que `APP_HOME` tiene valor? Enunciá la regla en una sola oración.
- **Q14.** En el paso 5, `ls /srv/BUILDINFO` falla pero el secreto sigue siendo recuperable. Explicá el mecanismo de almacenamiento que hace que esto sea cierto, y nombrá el marcador de archivo involucrado.
- **Q15.** `ARG PYTHON_VERSION=3.12` se declara antes de `FROM` y se vuelve a declarar después. ¿Qué se rompe si omitís la re-declaración, y a qué evalúa entonces la expansión `${PYTHON_VERSION}` dentro del stage?
- **Q16.** Alguien propone `--build-arg API_TOKEN=...` combinado con `RUN unset API_TOKEN` como arreglo. ¿Por qué no funciona?
- **Q17.** ¿Qué dos claves de anotación OCI usadas arriba le permiten a un escáner determinar la imagen base upstream y el commit de origen? ¿Por qué importa eso para el triage de CVEs?

---

## Ejercicio 5 — `ENTRYPOINT`, `CMD`, PID 1 y manejo de señales

Acá es donde imágenes que parecen correctas fallan en producción: las actualizaciones progresivas se toman el período de gracia de terminación completo, las peticiones en vuelo quedan cortadas, y el código de salida del pod es `137`.

### Pasos

1. Escribí una aplicación que registre su propio manejo de señales:

```bash
cd ~/lab-702.3
mkdir -p sig && cd sig
cat > app.sh <<'EOF'
#!/bin/sh
term() {
  echo "$(date -Is) SIGTERM received — draining"
  exit 0
}
trap term TERM

echo "$(date -Is) started with pid $$ argv: $*"
while :; do
  sleep 1 &
  wait $!
done
EOF
chmod +x app.sh
```

2. Construí dos imágenes que difieran **únicamente** en la forma del `ENTRYPOINT`:

```bash
cat > Dockerfile.exec <<'EOF'
FROM alpine:3.20
COPY app.sh /app.sh
STOPSIGNAL SIGTERM
ENTRYPOINT ["/app.sh"]
CMD ["--default-flag"]
EOF

cat > Dockerfile.shell <<'EOF'
FROM alpine:3.20
COPY app.sh /app.sh
ENTRYPOINT /app.sh && echo "never reached"
CMD ["--default-flag"]
EOF

docker build -f Dockerfile.exec  -t sig:exec  .
docker build -f Dockerfile.shell -t sig:shell .
```

3. Inspeccioná qué es realmente PID 1 en cada uno:

```bash
docker run -d --name c-exec  sig:exec
docker run -d --name c-shell sig:shell
docker exec c-exec  ps -o pid,args
docker exec c-shell ps -o pid,args
```

```
# c-exec
PID   COMMAND
    1 {app.sh} /bin/sh /app.sh --default-flag
   ...

# c-shell
PID   COMMAND
    1 /bin/sh -c /app.sh && echo "never reached"
    7 {app.sh} /bin/sh /app.sh
   ...
```

4. Compará el comportamiento al detener y el código de salida:

```bash
time docker stop c-exec  ; docker inspect -f '{{.State.ExitCode}}' c-exec
time docker stop c-shell ; docker inspect -f '{{.State.ExitCode}}' c-shell
docker logs c-exec ; echo '---' ; docker logs c-shell
```

```
c-exec
real    0m0.35s
0
---
c-shell
real    0m10.29s
137
```

```
2026-09-03T10:14:02+00:00 started with pid 1 argv: --default-flag
2026-09-03T10:14:19+00:00 SIGTERM received — draining
---
2026-09-03T10:14:05+00:00 started with pid 1 argv:
```

> La espera exacta de 10 segundos depende de la implementación del shell: BusyBox `ash` y `dash` se bloquean en `wait()` y nunca entregan la señal hacia adelante, así que transcurre el período de gracia del daemon y `SIGKILL` lo termina. Algunos shells hacen `exec` de un único comando simple y se comportarían como la forma exec. La evidencia *determinista* es la salida de `ps` del paso 3 — leé eso, no los tiempos, para identificar la falla.

5. Verificá las reglas de composición de argumentos:

```bash
docker run --rm sig:exec --custom-flag & sleep 1; docker logs "$(docker ps -lq)"
docker run --rm sig:shell --custom-flag & sleep 1; docker logs "$(docker ps -lq)"
```

6. Agregá un init apropiado para la recolección de zombis y observá la diferencia:

```bash
docker run -d --init --name c-init sig:exec
docker exec c-init ps -o pid,args | head -3
```

```
PID   COMMAND
    1 /sbin/docker-init -- /app.sh --default-flag
    7 {app.sh} /bin/sh /app.sh --default-flag
```

### Punto de control 5

- **Q18.** Enunciá la regla que determina cuándo se usa `CMD` como *argumentos para* `ENTRYPOINT` versus como el *comando en sí*, y explicá por qué `sig:shell` imprimió un `argv` vacío.
- **Q19.** `c-shell` salió con `137`. Descomponé ese número y nombrá la señal.
- **Q20.** Tu Deployment de Kubernetes define `terminationGracePeriodSeconds: 60` y tu imagen usa `ENTRYPOINT` en forma shell. Describí exactamente cómo se ve una actualización progresiva para los usuarios finales, y cuánto tarda cada pod en desaparecer.
- **Q21.** ¿Qué cambia acá `STOPSIGNAL SIGTERM`, y qué runtime lo respeta — Docker, Kubernetes, o ambos?
- **Q22.** ¿Cuándo es `--init` (o `tini`) realmente necesario, dado que tu aplicación ya atrapa `SIGTERM` correctamente?

---

## Ejercicio 6 — Builds multi-etapa: de 800 MB a 6 MB

### Pasos

1. Creá un servicio pequeño en Go:

```bash
mkdir -p ~/lab-702.3/go-svc && cd ~/lab-702.3/go-svc
cat > go.mod <<'EOF'
module example.com/svc

go 1.23
EOF
cat > main.go <<'EOF'
package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
)

func main() {
	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
	})

	addr := ":8080"
	log.Printf("listening on %s as uid %d", addr, os.Getuid())
	log.Fatal(http.ListenAndServe(addr, nil))
}
EOF
```

2. Construí primero la imagen ingenua de una sola etapa, para tener una línea base:

```bash
cat > Dockerfile.single <<'EOF'
FROM golang:1.23-alpine3.20
WORKDIR /src
COPY . .
RUN go build -o /src/svc ./main.go
EXPOSE 8080
CMD ["/src/svc"]
EOF
docker build -f Dockerfile.single -t svc:single .
```

3. Ahora la versión multi-etapa, apuntando a un runtime distroless:

```bash
cat > Dockerfile <<'EOF'
# syntax=docker/dockerfile:1.7

##############################################################################
# Stage 1 — build. Contains the toolchain, the module cache and the sources.
# None of this reaches the final image.
##############################################################################
FROM golang:1.23-alpine3.20 AS build

WORKDIR /src

# Module graph first, so `go mod download` is cached independently of sources.
COPY go.mod ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

COPY . .

ARG TARGETOS=linux
ARG TARGETARCH=amd64

# CGO_ENABLED=0 produces a statically linked binary with no libc dependency,
# which is what makes a scratch/distroless base viable.
# -trimpath removes local filesystem paths; -ldflags "-s -w" drops the symbol
# table and DWARF data (smaller binary, no debugger symbols).
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-s -w" -o /out/svc ./main.go

##############################################################################
# Stage 2 — optional test stage. Built only when explicitly targeted.
##############################################################################
FROM build AS test
RUN go vet ./...

##############################################################################
# Stage 3 — runtime. No shell, no package manager, no libc, non-root by tag.
##############################################################################
FROM gcr.io/distroless/static-debian12:nonroot AS runtime

COPY --from=build --chown=65532:65532 /out/svc /usr/local/bin/svc

USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/svc"]
EOF

docker build -t svc:multi .
docker image ls svc
```

```
REPOSITORY   TAG     IMAGE ID       CREATED          SIZE
svc          multi   4b7f1c9e2a30   5 seconds ago    8.42MB
svc          single  1ad3e8c05b71   40 seconds ago   358MB
```

4. Construí solo la etapa de test — notá que la etapa de runtime nunca se ejecuta:

```bash
docker build --target test -t svc:test .
```

5. Confirmá que el toolchain realmente se fue y que el proceso no es root:

```bash
docker run --rm --entrypoint /bin/sh svc:multi -c 'echo hi' || echo "no shell in image"
docker run -d --name svc -p 8080:8080 svc:multi
docker exec svc id 2>&1 || echo "no exec possible: distroless has no shell"
docker inspect -f '{{.Config.User}}' svc:multi
curl -s localhost:8080/healthz ; echo
docker logs svc
```

```
no shell in image
65532:65532
{"status":"ok"}
2026/09/03 10:31:44 listening on :8080 as uid 65532
```

6. Depurá un contenedor distroless de todos modos, usando un enfoque efímero estilo sidecar:

```bash
docker run --rm -it --pid=container:svc --network=container:svc \
  --cap-add SYS_PTRACE alpine:3.20 sh -c 'apk add -q procps && ps -o pid,user,args'
```

### Punto de control 6

- **Q23.** `svc:single` pesa 358 MB y `svc:multi` 8,4 MB, a partir de fuentes idénticas. Enumerá lo que *no* está presente en la segunda imagen.
- **Q24.** ¿Por qué `CGO_ENABLED=0` es un prerrequisito para `gcr.io/distroless/static-debian12`? ¿Qué pasa en tiempo de ejecución si lo olvidás?
- **Q25.** La etapa `test` está entre `build` y `runtime` en el archivo. Cuando ejecutás `docker build -t svc:multi .` sin `--target`, ¿se ejecuta `go vet`? Explicá el modelo de evaluación de BuildKit.
- **Q26.** `USER 65532:65532` usa un UID numérico en vez de un nombre. Dá la razón de producción por la que esto le importa a Kubernetes, específicamente a `runAsNonRoot`.
- **Q27.** La imagen de runtime no tiene shell, así que `docker exec` y `kubectl exec` son inútiles. Nombrá el compromiso que aceptaste y los dos mecanismos que te devuelven la capacidad de depuración.

---

## Ejercicio 7 — BuildKit: montajes de caché, secretos de build, heredocs

### Pasos

1. Demostrá que un montaje de caché sobrevive entre builds. Los montajes de caché **no son capas** — persisten en el builder, nunca en la imagen.

```bash
cd ~/lab-702.3/app
cat > Dockerfile.cache <<'EOF'
# syntax=docker/dockerfile:1.7
FROM python:3.12-slim

# sharing=locked serialises concurrent builds that use the same cache id,
# which is what you want for package managers that are not concurrency-safe.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends curl ca-certificates

WORKDIR /srv
COPY requirements.txt .
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install -r requirements.txt
COPY server.py .
CMD ["python", "server.py"]
EOF

docker build -f Dockerfile.cache -t lab:cache .
docker build --no-cache -f Dockerfile.cache -t lab:cache .   # note: still fast
```

2. Notá que **no** hay ningún `rm -rf /var/lib/apt/lists/*` y sin embargo:

```bash
docker run --rm lab:cache sh -c 'du -sh /var/lib/apt/lists /var/cache/apt'
```

```
4.0K	/var/lib/apt/lists
8.0K	/var/cache/apt
```

3. Manejá los secretos correctamente. Creá una credencial y consumila sin persistirla:

```bash
echo 'ghp_EXAMPLE_do_not_ship' > token.txt
cat > Dockerfile.secret <<'EOF'
# syntax=docker/dockerfile:1.7
FROM alpine:3.20

# The secret is bind-mounted into the RUN's mount namespace only, at
# /run/secrets/<id> by default. It is not part of the layer diff, not part
# of the cache key content, and not visible in image history.
RUN --mount=type=secret,id=gh_token \
    sh -c 'test -s /run/secrets/gh_token && \
           echo "token length: $(wc -c < /run/secrets/gh_token)" > /build.log'

CMD ["cat", "/build.log"]
EOF

docker build -f Dockerfile.secret --secret id=gh_token,src=./token.txt -t lab:secret .
docker run --rm lab:secret
```

```
token length: 41
```

4. Confirmá forensemente que el secreto está ausente de todo artefacto:

```bash
docker image history --no-trunc lab:secret | grep -c 'ghp_' || echo "0 hits in history"
docker save lab:secret -o /tmp/lab-secret.tar
tar -xOf /tmp/lab-secret.tar | strings | grep -c 'ghp_EXAMPLE_do' || echo "0 hits in layers"
docker run --rm lab:secret ls /run/secrets 2>&1 || echo "mount does not exist at runtime"
```

5. Usá heredocs para mantener legibles los bloques `RUN` multilínea sin sopa de barras invertidas:

```bash
cat > Dockerfile.heredoc <<'OUTER'
# syntax=docker/dockerfile:1.7
FROM debian:12-slim

RUN <<EOF
set -eux
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl
apt-get clean
rm -rf /var/lib/apt/lists/*
EOF

COPY <<'EOF' /etc/app/config.yaml
server:
  listen: "0.0.0.0:8080"
  timeout: 30s
logging:
  level: info
EOF

CMD ["cat", "/etc/app/config.yaml"]
OUTER

docker build -f Dockerfile.heredoc -t lab:heredoc .
docker run --rm lab:heredoc
```

6. Compará explícitamente la semántica de `ADD` y `COPY`:

```bash
cat > Dockerfile.addcopy <<'EOF'
# syntax=docker/dockerfile:1.7
FROM alpine:3.20

# ADD with a checksum is the only safe way to fetch a remote artefact:
# the build fails if the bytes do not match, making it reproducible.
ADD --checksum=sha256:9b2cabe89643d0d4b0a09b0f1c9f0e0c5b1e9c2a1f6f3f4b8b0c2d1e0f9a8b7c \
    https://example.com/tool.tar.gz /tmp/tool.tar.gz

# ADD auto-extracts a *local* tar; COPY never does.
ADD payload.tar.gz /opt/payload/
COPY payload.tar.gz /opt/raw/
EOF
```

### Punto de control 7

- **Q28.** En el paso 1, `docker build --no-cache` igual fue rápido. Se supone que `--no-cache` invalida todo — ¿qué invalidó, y qué dejó intacto deliberadamente?
- **Q29.** La imagen del paso 2 tiene un `/var/lib/apt/lists` vacío aunque el Dockerfile nunca lo borra. Explicá el mecanismo, y decí por qué existe siquiera el clásico idioma `&& rm -rf /var/lib/apt/lists/*`.
- **Q30.** Contrastá `--mount=type=secret` con `--build-arg` y con `COPY token.txt . && RUN ... && rm token.txt` en tres ejes: persistencia en capas, historial de la imagen y caché de build.
- **Q31.** Dá dos diferencias de comportamiento entre `ADD` y `COPY`, y enunciá la regla práctica sobre cuál usar por defecto. ¿Por qué `--checksum` cambia la postura de seguridad de un `ADD` remoto?

---

## Ejercicio 8 — Tags, digests, registries y multi-arquitectura

### Pasos

1. Ejecutá un registry local:

```bash
docker run -d --name registry -p 5000:5000 --restart=unless-stopped registry:2
curl -s http://localhost:5000/v2/_catalog ; echo
```

```
{"repositories":[]}
```

2. Etiquetá deliberadamente. Un tag es un **puntero mutable**; un digest es **contenido inmutable**.

```bash
cd ~/lab-702.3/go-svc
docker tag svc:multi localhost:5000/lab/svc:1.0.0
docker tag svc:multi localhost:5000/lab/svc:1.0
docker tag svc:multi localhost:5000/lab/svc:latest

docker push localhost:5000/lab/svc:1.0.0
docker push localhost:5000/lab/svc:1.0
docker push localhost:5000/lab/svc:latest
```

```
The push refers to repository [localhost:5000/lab/svc]
6a1f0d3b8c2e: Pushed
1d2a5e0f7b91: Pushed
1.0.0: digest: sha256:c7d9e0a5b41f6a2d3c8e9f0b1a2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e size: 946
```

3. Capturá el digest y fijá por él:

```bash
DIG=$(docker image inspect localhost:5000/lab/svc:1.0.0 \
      --format '{{index .RepoDigests 0}}')
echo "$DIG"
docker pull "$DIG"
```

4. Demostrá que un tag puede reapuntarse mientras que el digest no:

```bash
docker tag alpine:3.20 localhost:5000/lab/svc:1.0.0
docker push localhost:5000/lab/svc:1.0.0
docker buildx imagetools inspect localhost:5000/lab/svc:1.0.0 --format '{{.Manifest.Digest}}'
docker buildx imagetools inspect "$DIG" --format '{{.Manifest.Digest}}'
```

5. Construí una imagen multi-arquitectura. Esto necesita un driver `docker-container` — el driver `docker` por defecto no puede emitir una lista de manifests.

```bash
docker buildx create --name multi --driver docker-container --use
docker buildx inspect --bootstrap | head -20

docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t localhost:5000/lab/svc:multiarch \
  --push .
```

6. Inspeccioná el **índice de imagen** (lista de manifests) resultante:

```bash
docker buildx imagetools inspect localhost:5000/lab/svc:multiarch
```

```
Name:      localhost:5000/lab/svc:multiarch
MediaType: application/vnd.oci.image.index.v1+json
Digest:    sha256:31ab7e5d0c9f...

Manifests:
  Name:      localhost:5000/lab/svc:multiarch@sha256:a0c1...
  MediaType: application/vnd.oci.image.manifest.v1+json
  Platform:  linux/amd64

  Name:      localhost:5000/lab/svc:multiarch@sha256:b4d7...
  MediaType: application/vnd.oci.image.manifest.v1+json
  Platform:  linux/arm64
```

7. Entendé por qué el Dockerfile del Ejercicio 6 cross-compila correctamente. BuildKit inyecta `TARGETOS`/`TARGETARCH`/`TARGETPLATFORM` automáticamente; combinado con `FROM --platform=$BUILDPLATFORM`, el toolchain corre nativamente y solo la salida se cross-compila:

```bash
sed -i 's|^FROM golang:1.23-alpine3.20 AS build|FROM --platform=$BUILDPLATFORM golang:1.23-alpine3.20 AS build|' Dockerfile
time docker buildx build --platform linux/amd64,linux/arm64 \
  -t localhost:5000/lab/svc:xc --push .
```

8. Exportá la caché para que los runners de CI la compartan:

```bash
docker buildx build \
  --cache-to   type=registry,ref=localhost:5000/lab/svc:buildcache,mode=max \
  --cache-from type=registry,ref=localhost:5000/lab/svc:buildcache \
  -t localhost:5000/lab/svc:1.0.1 --push .
```

### Punto de control 8

- **Q32.** Después del paso 4, un Deployment que referencia `localhost:5000/lab/svc:1.0.0` con `imagePullPolicy: IfNotPresent` se escala hacia arriba en un nodo nuevo. ¿Qué imagen corre ahí, y cuál corre en los nodos viejos? Nombrá la clase de bug que esto produce.
- **Q33.** Escribí la referencia totalmente calificada de `nginx:1.27` tal como la resuelve el cliente del registry, e identificá cada uno de los cuatro componentes.
- **Q34.** ¿Por qué el driver `docker` de buildx por defecto no puede producir una imagen multi-arquitectura, y qué agrega el driver `docker-container`?
- **Q35.** Sin `--platform=$BUILDPLATFORM` en la etapa de build, ¿cómo produce BuildKit la variante `linux/arm64` en un host amd64, y por qué el paso 7 es dramáticamente más rápido?
- **Q36.** ¿Qué cambia `mode=max` respecto de la caché exportada por defecto, y cuál es el costo de almacenamiento?

---

## Ejercicio 9 — Construcción sin daemon: Podman, Buildah y builds dentro del clúster

El daemon de Docker corre como root y su socket es equivalente a root. Montar `/var/run/docker.sock` en un job de CI para construir imágenes le entrega a ese job control total del host. Los builders rootless y sin daemon existen precisamente para eliminar esto.

### Pasos

1. Construí el Dockerfile idéntico con Podman, en modo rootless:

```bash
cd ~/lab-702.3/go-svc
podman build -t svc:podman .
podman image ls svc
podman unshare cat /proc/self/uid_map
```

```
         0       1000          1
         1     100000      65536
```

2. Notá el requisito de nombre totalmente calificado — Podman no asume silenciosamente Docker Hub:

```bash
podman image inspect svc:podman --format '{{.Config.User}}'
grep -A5 '^\[registries.search\]\|unqualified-search' /etc/containers/registries.conf
```

3. Usá Buildah con un Dockerfile (`bud` = *build using Dockerfile*):

```bash
buildah bud -t svc:buildah -f Dockerfile .
buildah images
```

4. Ahora construí **sin ningún Dockerfile**, guionando la imagen directamente. Esta es la capacidad distintiva de Buildah: la definición de la imagen se vuelve un programa de shell.

```bash
#!/usr/bin/env bash
set -euo pipefail

ctr=$(buildah from gcr.io/distroless/static-debian12:nonroot)
mnt=$(buildah mount "$ctr")

install -D -m 0555 -o 65532 -g 65532 \
    ./svc-binary "${mnt}/usr/local/bin/svc"

buildah config \
  --user 65532:65532 \
  --port 8080 \
  --entrypoint '["/usr/local/bin/svc"]' \
  --label org.opencontainers.image.title="svc" \
  --label org.opencontainers.image.source="https://example.com/svc" \
  "$ctr"

buildah unmount "$ctr"
buildah commit --format oci --rm "$ctr" localhost/svc:scripted
buildah push --tls-verify=false localhost/svc:scripted \
    docker://localhost:5000/lab/svc:scripted
```

5. Construí dentro de Kubernetes sin daemon privilegiado, usando BuildKit rootless:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: buildkit-build
spec:
  restartPolicy: Never
  containers:
    - name: buildkit
      image: moby/buildkit:v0.16.0-rootless
      command:
        - buildctl-daemonless.sh
        - build
        - --frontend=dockerfile.v0
        - --local=context=/workspace
        - --local=dockerfile=/workspace
        - --output=type=image,name=registry.example.com/lab/svc:ci,push=true
      env:
        - name: BUILDKITD_FLAGS
          value: --oci-worker-no-process-sandbox
      securityContext:
        seccompProfile:
          type: Unconfined
        appArmorProfile:
          type: Unconfined
        runAsUser: 1000
        runAsGroup: 1000
      volumeMounts:
        - name: workspace
          mountPath: /workspace
        - name: docker-config
          mountPath: /home/user/.docker
  volumes:
    - name: workspace
      emptyDir: {}
    - name: docker-config
      secret:
        secretName: registry-credentials
        items:
          - key: .dockerconfigjson
            path: config.json
```

6. El equivalente con Kaniko, que los objetivos del 701 listan explícitamente:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: kaniko-build
spec:
  restartPolicy: Never
  containers:
    - name: kaniko
      image: gcr.io/kaniko-project/executor:latest
      args:
        - --context=git://github.com/example/svc.git#refs/heads/main
        - --dockerfile=Dockerfile
        - --destination=registry.example.com/lab/svc:ci
        - --cache=true
        - --cache-repo=registry.example.com/lab/svc-cache
        - --snapshot-mode=redo
      volumeMounts:
        - name: docker-config
          mountPath: /kaniko/.docker
  volumes:
    - name: docker-config
      secret:
        secretName: registry-credentials
        items:
          - key: .dockerconfigjson
            path: config.json
```

> Kaniko ejecuta las instrucciones `RUN` **en el sistema de archivos de su propio contenedor** y hace un snapshot del diff después de cada una — por eso no necesita daemon ni privilegios, y también por eso ejecutarlo fuera de un contenedor está explícitamente no soportado. Verificá el estado actual de mantenimiento del proyecto antes de adoptarlo para pipelines nuevos; varios equipos migraron a BuildKit rootless o Buildah para el mismo trabajo.

### Punto de control 9

- **Q37.** Un job de CI monta `/var/run/docker.sock` para construir imágenes. Describí concretamente cómo un `Dockerfile` malicioso — o una dependencia comprometida en la build — escala a root en el host de CI.
- **Q38.** Explicá qué imprimió `podman unshare cat /proc/self/uid_map` y cómo le permite a un usuario no root crear un contenedor cuyos procesos creen ser UID 0.
- **Q39.** Buildah puede construir sin ningún `Dockerfile`. Dá un escenario de producción donde eso sea materialmente mejor que un `Dockerfile`, y una cosa que perdés.
- **Q40.** Tanto el Pod de BuildKit como el de Kaniko montan un Secret `kubernetes.io/dockerconfigjson` en vez de pasar credenciales como argumentos. Nombrá dos razones distintas.

---

## Ejercicio 10 — Diagnóstico: una build rota y una imagen inflada

### Pasos

1. Guardá este Dockerfile. Contiene **cinco** defectos — algunos rompen la build, otros solo fallan en producción.

```bash
mkdir -p ~/lab-702.3/broken && cd ~/lab-702.3/broken
cp ../app/server.py ../app/requirements.txt .

cat > Dockerfile <<'EOF'
FROM python:3.12

RUN useradd -m -u 10001 appuser
USER appuser

WORKDIR /opt/app
RUN pip install -r requirements.txt

COPY . .

VOLUME /opt/app/data
RUN mkdir -p /opt/app/data && echo "seed" > /opt/app/data/seed.txt

ENV FLASK_SECRET=hunter2
EXPOSE 8080
ENTRYPOINT python server.py
EOF
```

2. Construí con salida completa y leé la primera falla:

```bash
docker build --progress=plain -t broken:1 . 2>&1 | tail -30
```

```
#7 [4/8] RUN pip install -r requirements.txt
#7 0.412 ERROR: Could not open requirements file:
#7 0.412 [Errno 2] No such file or directory: 'requirements.txt'
#7 ERROR: process "/bin/sh -c pip install -r requirements.txt" did not exit with code 0
```

3. Arreglá esa, reconstruí, y leé la siguiente:

```bash
sed -i 's|^RUN pip install -r requirements.txt|COPY requirements.txt .\nRUN pip install --no-cache-dir -r requirements.txt|' Dockerfile
docker build --progress=plain -t broken:2 . 2>&1 | tail -20
```

```
#9 [6/9] COPY requirements.txt .
#9 ERROR: failed to calculate checksum ... permission denied
```

4. Usá un target de depuración para obtener un shell en el punto exacto de la falla — BuildKit no deja imágenes intermedias ejecutables como lo hacía el builder clásico:

```bash
cat >> Dockerfile <<'EOF'

FROM python:3.12 AS debug
RUN useradd -m -u 10001 appuser
WORKDIR /opt/app
RUN ls -ld /opt/app && id appuser
EOF
docker build --target debug --progress=plain -t broken:debug . 2>&1 | grep -A3 'ls -ld'
```

```
#12 0.298 drwxr-xr-x 2 root root 4096 Sep  3 10:52 /opt/app
#12 0.301 uid=10001(appuser) gid=10001(appuser) groups=10001(appuser)
```

5. Reparalo todo y medí:

```bash
cat > Dockerfile <<'EOF'
# syntax=docker/dockerfile:1.7
FROM python:3.12-slim AS runtime

RUN useradd --create-home --uid 10001 --shell /usr/sbin/nologin appuser \
 && install -d -o appuser -g appuser -m 0755 /opt/app /opt/app/data

WORKDIR /opt/app

# Dependencies installed as root into the system site-packages, then the
# process drops privileges. The app never needs write access to its own code.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY --chown=appuser:appuser server.py .

# Secrets come from the orchestrator at runtime, never baked into the config.
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

USER 10001:10001
EXPOSE 8080
STOPSIGNAL SIGTERM

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/healthz').status==200 else 1)"

ENTRYPOINT ["python", "server.py"]
EOF

docker build -t fixed:1 .
docker image ls | grep -E '^(broken|fixed)'
docker run -d --name fixed -p 8080:8080 fixed:1
sleep 8
docker inspect -f '{{.State.Health.Status}} uid={{.Config.User}}' fixed
docker inspect -f '{{json .Mounts}}' fixed
```

```
healthy uid=10001:10001
[]
```

6. Encontrá adónde se fueron los bytes restantes:

```bash
docker image history fixed:1 --format 'table {{.Size}}\t{{.CreatedBy}}' | head
docker system df -v | head -20
```

### Punto de control 10

- **Q41.** Listá los cinco defectos del Dockerfile original del paso 1. Para cada uno, decí si rompe la build o si solo se manifiesta en tiempo de ejecución.
- **Q42.** En el paso 3, `COPY requirements.txt .` falló con `permission denied` aunque `COPY` lo ejecuta el builder, no `appuser`. ¿Qué determina realmente la propiedad y los permisos del directorio destino acá, y por qué `COPY --chown` lo soluciona?
- **Q43.** A `VOLUME /opt/app/data` le siguió un `RUN` que siembra un archivo en esa ruta. Explicá qué le pasa a `seed.txt`, y describí el segundo problema, más sutil, que `VOLUME` crea cada vez que se ejecuta la imagen.
- **Q44.** La imagen arreglada declara `HEALTHCHECK` y reporta `healthy`. Tu equipo de plataforma dice que esto es peso muerto en el despliegue de Kubernetes. ¿Tienen razón? ¿Cuál es el equivalente en Kubernetes, y el runtime de contenedores bajo Kubernetes evalúa siquiera `HEALTHCHECK`?

---

## Limpieza

```bash
docker rm -f fixed svc c-exec c-shell c-init registry 2>/dev/null
docker buildx rm multi 2>/dev/null
docker image rm -f $(docker image ls -q 'lab' 'svc' 'sig' 'broken' 'fixed') 2>/dev/null
docker builder prune -af
rm -rf ~/lab-702.3
```

---

## Fuentes

- LPI — Exam 701-100 Objectives (DevOps Tools Engineer, v2.0): https://www.lpi.org/our-certifications/exam-701-objectives/
- Referencia de Dockerfile: https://docs.docker.com/reference/dockerfile/
- Caché de build de Docker: https://docs.docker.com/build/cache/
- Builds multi-etapa: https://docs.docker.com/build/building/multi-stage/
- Secretos de build: https://docs.docker.com/build/building/secrets/
- Builds multiplataforma: https://docs.docker.com/build/building/multi-platform/
- Drivers de buildx: https://docs.docker.com/build/builders/drivers/
- BuildKit: https://github.com/moby/buildkit
- OCI Image Format Specification: https://github.com/opencontainers/image-spec/blob/main/spec.md
- Claves de anotación predefinidas de OCI: https://github.com/opencontainers/image-spec/blob/main/annotations.md
- Podman build: https://docs.podman.io/en/latest/markdown/podman-build.1.html
- Buildah: https://buildah.io/ — https://github.com/containers/buildah/blob/main/docs/tutorials/
- Kaniko: https://github.com/GoogleContainerTools/kaniko
- Imágenes base distroless: https://github.com/GoogleContainerTools/distroless
- Probes de Kubernetes: https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- Security context de Pod en Kubernetes (`runAsNonRoot`): https://kubernetes.io/docs/tasks/configure-pod-container/security-context/

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1

**A1.** Son digests de dos flujos de bytes distintos de la misma capa lógica. `.RootFS.Layers` guarda **diffID**s — `sha256` del tar *sin comprimir*. El manifest del registry guarda el digest del blob *comprimido* (gzip o zstd) tal como se transfiere y almacena realmente. El diffID es lo que hace determinista la configuración de la imagen independientemente de los parámetros de compresión; el digest del blob es lo que direcciona por contenido los bytes transferidos. `docker pull` compara los **digests de blob** del manifest contra lo que ya tiene, así que ese es el que decide si se saltea una descarga. La configuración misma también es un blob, direccionado por su propio digest — y el digest del *manifest* es lo que nombra una referencia fijada `image@sha256:...`.

**A2.** No. Las capas se comparten y se almacenan una sola vez, indexadas por su digest de contenido. Diez imágenes que comparten la base `alpine:3.20` almacenan esos 8,83 MB una única vez. `docker image ls` reporta el *tamaño virtual acumulado* de la cadena completa de capas de una imagen, lo que cuenta dos veces las capas compartidas cuando sumás a lo largo de las filas. `docker system df -v` reporta la realidad deduplicada en disco y muestra una columna `SHARED SIZE`. Esta es la mala lectura más común del tamaño de imagen en la planificación de capacidad.

**A3.** `<missing>` significa que el almacén de contenido local tiene la capa pero ninguna *configuración de imagen* que la nombre — las configuraciones intermedias no se distribuyen. Un registry envía una configuración más los blobs de capa, no una configuración por cada paso histórico. En consecuencia no podés hacer `docker run` de una capa intermedia de una imagen descargada: no hay ID de imagen que referenciar. (Con BuildKit esto también es cierto para las imágenes que construís vos mismo, a diferencia del builder legacy que creaba una imagen intermedia real por paso. Usá `--target` sobre una etapa de depuración en su lugar — Ejercicio 10, paso 4).

**A4.** En el **JSON de configuración de la imagen**, bajo `.config.Cmd`. `CMD`, `ENV`, `ENTRYPOINT`, `USER`, `WORKDIR`, `EXPOSE`, `LABEL`, `VOLUME` y `STOPSIGNAL` son instrucciones de solo metadatos: mutan el blob de configuración y producen un diff de capa vacío, de ahí el `0B`. El arreglo `history` en la configuración las registra con `empty_layer: true`.

### Ejercicio 2

**A5.** `COPY . /srv`. Su clave de caché se deriva de un checksum sobre el *contenido y los metadatos de cada archivo del contexto de build que el patrón hace coincidir*. `server.py` cambió, así que cambió el checksum, así que ese paso falló la caché. La invalidación de caché es **transitiva y ordenada**: una vez que un paso falla, cada paso subsiguiente de esa etapa también falla, sin importar si sus propias entradas cambiaron. `pip install` está aguas abajo del `COPY`, así que se volvió a ejecutar.

**A6.** La clave de caché de BuildKit para un `RUN` es un hash de `(clave de caché del paso padre, la cadena literal del comando, las especificaciones de los montajes, los valores ARG/ENV relevantes referenciados)`. La cadena del comando se compara byte a byte, así que un espacio extra produce una clave distinta. BuildKit nunca inspecciona el *resultado* de un `RUN` para juzgar la validez de la caché — no puede, porque tendría que ejecutar el paso para averiguarlo. Esta es toda la razón por la que el caché de `RUN apt-get update` es peligroso.

**A7.** El modo de falla es un **índice de paquetes obsoleto congelado en caché**. La cadena del `RUN` nunca cambia, su padre nunca cambia, así que BuildKit reutiliza la capa construida hace seis semanas — incluidos el índice de `apt` y las versiones de paquetes resueltas entonces. Mitigaciones, cualquiera de:
1. Fijar explícitamente: `apt-get install -y curl=8.5.0-2ubuntu10.4`, para que una actualización sea un cambio en el Dockerfile y por lo tanto un fallo de caché.
2. Reconstruir de forma programada con `--pull --no-cache` (refresco nocturno de imagen base en CI), publicando un nuevo tag de parche.
3. Romper la caché intencionalmente con un argumento de build periódico: `ARG CACHEBUST=weekly-2026-w36` ubicado justo antes del bloque de `apt`.
4. Escanear la imagen *publicada* (Trivy/Grype) en CI y hacer fallar el pipeline sobre un umbral, para que una capa obsoleta no pueda distribuirse en silencio.

**A8.** `pip` escribe una caché de wheels en `~/.cache/pip`, y esa escritura ocurre *dentro de la capa que se está construyendo*. El contenedor de build es efímero, pero su diff de sistema de archivos es exactamente lo que se convierte en la capa, así que la caché quedaría comprometida permanentemente dentro de la imagen — típicamente decenas o cientos de MB de wheels que nunca se vuelven a usar. `--no-cache-dir` evita la escritura. La alternativa superior es el `--mount=type=cache,target=/root/.cache/pip` del Ejercicio 7, que mantiene la caché *fuera de la capa* mientras la sigue reutilizando entre builds.

**A9.** `--no-cache` ignora las entradas de caché existentes **solo para esta build**; las entradas permanecen en disco y builds posteriores todavía pueden acertarlas. `docker builder prune` **elimina** los registros de caché y los blobs asociados del almacenamiento del builder, liberando disco. Usá `--no-cache` para forzar una resolución fresca de paquetes; usá `builder prune` para recuperar espacio. Notá que `--no-cache` *no* limpia los volúmenes de `--mount=type=cache` (ver A28).

### Ejercicio 3

**A10.** `.dockerignore` filtra el contexto que se **transfiere al builder para `COPY`/`ADD`**. El `Dockerfile` mismo se lee por un canal separado — el frontend `dockerfile` de BuildKit lo recibe como una entrada distinta (`--local=dockerfile=...` / la ruta de `-f`), no pescándolo del contexto copiado. Ignorarlo es práctica estándar para que editar el Dockerfile no invalide por sí mismo el checksum de un `COPY . .`.

**A11.** (1) **Costo de transferencia y agitación de caché**: los 68 MB completos de contexto se checksummean y se envían en cada build, agregando de segundos a minutos por build y por runner de CI. (2) **Radio de impacto en ediciones futuras**: en el momento en que alguien cambie ese `COPY` por `COPY . .` — una refactorización rutinaria — cada archivo ignorado aterriza en la imagen, incluidos `.env` y `.git` (que contiene el historial completo, secretos borrados incluidos). `.dockerignore` es un guardia permanente, no una optimización por Dockerfile. (3) Secundariamente, `.git` en el contexto alcanza para que un log de build filtrado o un volcado de `--progress=plain` exponga rutas y nombres de ramas.

**A12.** **No, no está a salvo.** La credencial está en una capa publicada, en un registry, direccionable por digest, y posiblemente descargada en cada nodo que la ejecutó y replicada por cualquier caché de tipo pull-through. Remediación, en orden:
1. **Rotá la credencial inmediatamente.** Este es el único paso que realmente restaura la seguridad; todo lo demás es limpieza.
2. Borrá el tag *y los manifests subyacentes* del registry, después ejecutá la recolección de basura para que los blobs queden inalcanzables. Borrar solo el tag deja el digest descargable.
3. Purgá cualquier caché pull-through, cachés de imágenes de nodo y almacenes de artefactos de CI.
4. Reconstruí desde un contexto limpio con `.dockerignore` en su lugar y republicá bajo una versión nueva.
5. Agregá un escaneo de secretos previo al push (`trivy image --scanners secret`, `gitleaks`) en CI para que esto haga fallar el pipeline la próxima vez.

### Ejercicio 4

**A13.** `ENV` escribe en el arreglo `Env` de la configuración de la imagen, que el runtime inyecta en el entorno del contenedor. `ARG` existe solo en el ámbito de variables del builder durante la build y nunca se escribe en `.Config.Env`. **Regla: `ARG` es solo de tiempo de build y no sobrevive al contenedor en ejecución; `ENV` queda horneado en la configuración de la imagen y sí sobrevive.**

**A14.** Las capas se apilan mediante un sistema de archivos de unión (overlay2). Un borrado en una capa superior se registra como un **whiteout** — con overlayfs, un dispositivo de caracteres con major/minor `0/0` nombrado según el archivo borrado (`.wh.BUILDINFO` en la representación de capa tar de OCI). La capa inferior todavía contiene los bytes originales textualmente; el montaje de unión meramente los oculta. Cualquiera con la imagen puede extraer el tarball de la capa (`docker save`, `crane export`, o simplemente leyendo el blob del registry) y recuperar el archivo. **Borrar un secreto en una instrucción posterior nunca lo elimina de una imagen.** Los únicos arreglos son: nunca escribirlo (usar `--mount=type=secret`), o escribirlo en una etapa que se descarta (multi-etapa), o hacer squash — y rotar la credencial de todos modos.

**A15.** Sin la re-declaración, `PYTHON_VERSION` **no está en ámbito dentro de la etapa** y `${PYTHON_VERSION}` se expande a la **cadena vacía**. La build tiene éxito (no se lanza ningún error por una variable indefinida), y `/srv/BUILDINFO` dice silenciosamente `built on python , rev ...`. Este es un bug clásico de corrupción silenciosa: la línea `FROM ${BASE}` funcionó, así que quien desarrolla asume que la variable está disponible en todas partes. Los ARG previos a `FROM` son globales solo para las líneas `FROM`; `ARG NAME` sin valor por defecto dentro de una etapa reimporta el valor global.

**A16.** Porque la fuga no está en el entorno — está en los **metadatos del historial de build**. BuildKit registra el comando `RUN` completamente expandido en el campo `history[].created_by` de la configuración de la imagen, incluido el prefijo `|N ARG=valor` que lista cada argumento de build en ámbito. `docker image history --no-trunc` lo lee directo de la configuración; y también lo hace cualquiera que descargue la imagen. `unset` en tiempo de ejecución no puede editar retroactivamente un blob JSON que se escribió en tiempo de build. Además, si el `RUN` escribió el valor a disco (como acá), también aplica A14.

**A17.** `org.opencontainers.image.base.name` (desde qué imagen y tag upstream se construyó esto) y `org.opencontainers.image.revision` (el commit de origen). Juntas le permiten a un escáner responder las dos preguntas que el triage de CVEs realmente necesita: *"¿está afectada mi imagen base, y se publicó una base corregida?"* y *"¿qué árbol de fuentes produjo este artefacto, para poder parchear y reconstruir lo correcto?"* Sin ellas, un reporte de vulnerabilidad contra un contenedor en ejecución te da un digest y ningún camino de vuelta al código fuente. `org.opencontainers.image.source` (URL del repositorio) y `.version` completan el conjunto; los registries modernos y herramientas como Grype y Syft leen estas anotaciones directamente.

### Ejercicio 5

**A18.** **Regla:** `CMD` se pasa como argumentos por defecto a `ENTRYPOINT` **solo cuando `ENTRYPOINT` está en forma exec** (arreglo JSON). En forma shell, BuildKit reescribe `ENTRYPOINT cmd` como `["/bin/sh", "-c", "cmd"]` — el vector de argumentos queda completamente determinado por esa cadena, así que `CMD` y cualquier argumento de `docker run` no tienen adónde ir y se **descartan silenciosamente**. Por eso `sig:shell` registró un `argv` vacío: el shell invocó `/app.sh` sin parámetros. En el paso 5 aplica lo mismo a `--custom-flag`, que la imagen en forma exec recibe y la imagen en forma shell ignora.

**A19.** `137 = 128 + 9`. Convención Unix: un proceso terminado por la señal *N* es reportado por el shell/runtime como `128 + N`. La señal 9 es `SIGKILL`. Así que el contenedor fue forzado a morir, que es exactamente lo que hace el daemon cuando expira el período de gracia. `143 = 128 + 15 = SIGTERM` indicaría una salida limpia inducida por señal; `0` (lo que produjo `c-exec`) indica que el trap la manejó y salió deliberadamente.

**A20.** El kubelet envía `SIGTERM` al PID 1 — el shell — que nunca la retransmite. Mientras tanto el endpoint se elimina del Service, así que no llega tráfico *nuevo*, pero **cada petición en vuelo queda cortada** cuando aterriza el kill. El pod queda en `Terminating` durante los **60 segundos** completos, y después recibe `SIGKILL`. Con `maxUnavailable: 1` y 10 réplicas, una actualización progresiva que debería tomar segundos toma **~10 minutos**, durante los cuales los usuarios ven conexiones reseteadas y 502 del ingress en cada ciclo. El síntoma que lo delata en el campo: pods atascados en `Terminating` por exactamente `terminationGracePeriodSeconds`, con `lastState.terminated.exitCode: 137`.

**A21.** `STOPSIGNAL SIGTERM` establece `.Config.StopSignal` en la configuración de la imagen — la señal que el *daemon de Docker* envía en `docker stop`. Es útil para aplicaciones que esperan otra cosa (nginx quiere `SIGQUIT` para un apagado ordenado, Apache `SIGWINCH`). **Kubernetes no la lee**: la ruta de apagado de CRI envía `SIGTERM` incondicionalmente. Así que `STOPSIGNAL` lo respetan Docker/Podman y lo ignora Kubernetes — si tu aplicación necesita una señal distinta en un clúster, envolvela o usá un hook de ciclo de vida `preStop`.

**A22.** `--init` (o `tini` como PID 1) es necesario para la **recolección de zombis** y para la **entrega de señales a un árbol de procesos**. PID 1 en un namespace de PID tiene dos propiedades especiales: los hijos huérfanos se reparentan a él y debe hacer `wait()` sobre ellos, y el kernel no le aplica las disposiciones de señal por defecto. Un script de shell o una aplicación que lanza subprocesos (un supervisor, un runtime de lenguaje que forkea workers, cualquier cosa que invoque una CLI) va a acumular zombis si no los recolecta, agotando eventualmente la tabla de PIDs. Atrapar `SIGTERM` correctamente resuelve el apagado, no la recolección. Si tu PID 1 es un único binario estático que no forkea nada, `--init` es innecesario.

### Ejercicio 6

**A23.** Ausente de `svc:multi`: el toolchain de Go (`go`, `gofmt`, el árbol de fuentes de la biblioteca estándar, ~250 MB), la caché de módulos, el código fuente de la aplicación (`main.go`, `go.mod`), el userland base de Alpine (`apk`, BusyBox, `/bin/sh`), la base de datos de paquetes, `libc`, y cualquier entorno de CA/shell/coreutils. Lo que queda es la base distroless (certificados CA, `/etc/passwd` con la entrada `nonroot`, datos de zona horaria, unas pocas docenas de archivos) más el único binario estático. La consecuencia de seguridad importa más que el tamaño: sin shell y sin gestor de paquetes, el kit estándar de post-explotación no está disponible en el contenedor, y un escáner de CVEs reporta esencialmente cero hallazgos de paquetes de sistema operativo porque no hay paquetes de sistema operativo.

**A24.** `gcr.io/distroless/static-debian12` deliberadamente no contiene **ni cargador dinámico ni libc**. Un binario de Go construido con `CGO_ENABLED=1` (el valor por defecto cuando hay un toolchain de C presente) enlaza contra `libc` para la resolución de `net` y `os/user`, produciendo un ELF enlazado dinámicamente. Ejecutarlo sobre `static` falla inmediatamente en el exec con el error menos útil del runtime: `exec /usr/local/bin/svc: no such file or directory` — el archivo faltante es el *intérprete* (`/lib/x86_64-linux-gnu/libc.so.6`), no el binario. Diagnosticá con `file svc` (buscá "statically linked" vs "dynamically linked, interpreter …") o `ldd svc`. Si realmente necesitás cgo, usá `gcr.io/distroless/base-debian12` en su lugar, que trae glibc.

**A25.** **No, `go vet` no se ejecuta.** BuildKit construye un DAG de etapas y evalúa solo las dependencias transitivas del target solicitado. Sin `--target`, el target es la **última etapa del archivo** (`runtime`), cuya única dependencia es `build` (vía `COPY --from=build`). Nada referencia a `test`, así que ese nodo se poda y nunca se ejecuta. Esta es una trampa real en CI: poner una etapa de test en el Dockerfile no hace que se ejecute — necesitás un paso explícito `docker build --target test .`, o necesitás que la etapa de runtime dependa de ella (por ejemplo, `COPY --from=test /dev/null /tmp/.test-passed`).

**A26.** `securityContext.runAsNonRoot: true` de Kubernetes lo valida el kubelet **antes de que el contenedor arranque**, y el kubelet solo ve la cadena `User` de la configuración de la imagen — no tiene el `/etc/passwd` del contenedor. Si `User` es un *nombre* como `appuser`, el kubelet no puede resolverlo a un UID y el pod falla la admisión con `CreateContainerConfigError: container has runAsNonRoot and image has non-numeric user (appuser), cannot verify user is non-root`. Un `USER 65532:65532` numérico es resoluble sin el sistema de archivos de la imagen, así que la verificación pasa. También es más robusto en general: el mapeo de nombre a UID depende del `/etc/passwd` de la imagen base, que una actualización de la imagen base puede cambiar por debajo tuyo.

**A27.** El compromiso: cambiaste **capacidad de depuración interactiva** por una superficie de ataque mínima y un reporte de CVEs casi vacío. Recuperás la depuración mediante:
1. **Contenedores de depuración efímeros** — `kubectl debug -it <pod> --image=busybox --target=<container>`, que adjunta un contenedor que comparte los namespaces de PID y de red del objetivo sin modificar el pod. El equivalente en Docker es el `--pid=container: --network=container:` del paso 6.
2. **Observabilidad externalizada** — logs estructurados a stdout, métricas, trazas, y un tag variante `:debug` de la misma imagen (`gcr.io/distroless/static-debian12:debug-nonroot` incluye un shell BusyBox) que podés desplegar temporalmente cuando tenés que entrar.

### Ejercicio 7

**A28.** `--no-cache` invalida la **caché de capas/pasos** de BuildKit — cada instrucción se vuelve a ejecutar. Deliberadamente **no** limpia los volúmenes de `--mount=type=cache`, que son directorios de trabajo persistentes propiedad del builder, indexados por su `target` (o por un `id=` explícito), y compartidos entre builds. Así que `apt-get update` y `pip install` se volvieron a ejecutar, pero encontraron sus `.deb` y wheels descargados ya presentes y se saltearon la red. Ese es el punto: `--no-cache` debe forzar una *evaluación* fresca, no una lenta. Para limpiar los montajes de caché, usá `docker builder prune --filter type=exec.cachemount` (o `-af`).

**A29.** Los directorios de `--mount=type=cache` existen solo dentro del namespace de montaje de ese `RUN`. Cuando la instrucción termina, el montaje se desacopla y el diff de la capa se computa contra los directorios subyacentes (vacíos) — así que el índice descargado y los archivos `.deb` **nunca fueron parte de la capa**. El tradicional `&& rm -rf /var/lib/apt/lists/*` existe porque sin un montaje de caché esos archivos *sí* se escriben en la capa, agregando 30–50 MB permanentemente; y por A14, borrarlos en un `RUN` *separado* no ayudaría — de ahí el idioma del `&&` encadenado en un único `RUN`. Los montajes de caché hacen innecesario ese idioma y son estrictamente mejores, ya que además hacen rápidas las reconstrucciones.

**A30.**

| | persistencia en capas | historial de imagen | caché de build |
|---|---|---|---|
| `--mount=type=secret` | **nunca** — se bind-montea en el namespace de montaje del RUN en `/run/secrets/<id>`, y se desacopla antes del diff | **no se registra**; aparece la especificación del montaje, el valor no | el **contenido** del secreto queda excluido de la clave de caché por defecto (solo participa su `id`), así que rotar un token no invalida la build |
| `--build-arg` | no directamente, pero cualquier archivo que el RUN escriba con el valor es permanente | **queda completamente registrado** en `created_by` como `\|N NOMBRE=valor` — trivialmente legible por cualquiera con la imagen | participa en la clave de caché, así que el valor también queda almacenado en los metadatos de caché |
| `COPY` y después `rm` | **permanente** en la capa del `COPY`, oculto por un whiteout en la capa del `rm` | el `COPY` queda registrado; el contenido del archivo está en el blob de la capa | el checksum del archivo está en la clave de caché |

Solo el primero es seguro. Los otros dos requieren rotación de credenciales si se usaron.

**A31.** Diferencias:
1. `ADD` **auto-extrae archivos tar locales** (`.tar`, `.tar.gz`, `.tar.bz2`, `.tar.xz`) en el destino; `COPY` los copia como archivos opacos.
2. `ADD` puede obtener **URLs remotas** y (con Dockerfile 1.4+) **repositorios Git**; `COPY` no puede — solo lee el contexto de build u otra etapa vía `--from`.

**Regla práctica: usá `COPY` por defecto; usá `ADD` solo cuando querés específicamente la auto-extracción de tar o una descarga remota con checksum.** La extracción implícita de `ADD` es un tiro en el pie — un `.tar.gz` que querías distribuir intacto explota silenciosamente dentro de la imagen, y la extracción remota históricamente habilitó path-traversal mediante archivos manipulados.

`--checksum=sha256:...` cambia la postura de dos maneras: la build **falla** si los bytes remotos difieren del valor fijado, así que una URL de descarga comprometida o reapuntada no puede inyectar contenido; y la descarga se vuelve **reproducible y cacheable por contenido** en vez de por URL, ya que BuildKit puede usar el checksum como clave de caché sin volver a descargar. Sin eso, `ADD <url>` es un punto de entrada de cadena de suministro no autenticado cuyo resultado puede cambiar entre builds.

### Ejercicio 8

**A32.** El nodo nuevo descarga `1.0.0` fresco y obtiene el **manifest reapuntado — `alpine:3.20`**, que no tiene ninguna aplicación adentro y va a entrar en crash-loop. Los nodos viejos ya tienen una imagen local etiquetada `1.0.0`, y `IfNotPresent` significa que nunca vuelven a consultar el registry, así que siguen ejecutando el **servicio Go original**. Ahora tenés un Deployment cuyas réplicas ejecutan **código distinto bajo el mismo tag**. Esta clase de bug es la **deriva de tags mutables** (o "reutilización de tags"): produce heisenbugs que se reproducen en algunos pods y en otros no, derrota el rollback (volver a `1.0.0` te da lo que sea que `1.0.0` apunte *hoy*), y rompe la auditoría. El arreglo es desplegar por **digest** — `image: registry/lab/svc@sha256:c7d9e0...` — y habilitar la **inmutabilidad de tags** en el registry para que un push a un tag existente sea rechazado.

**A33.** `docker.io/library/nginx:1.27` — y, resuelto por completo, `index.docker.io/library/nginx:1.27@sha256:<digest>`.
- **Host del registry**: `docker.io` (resuelto a `index.docker.io`). Si se omite, la CLI de Docker toma Docker Hub por defecto; **Podman no** y va a consultar `unqualified-search-registries` en `/etc/containers/registries.conf` o se va a negar.
- **Namespace/organización**: `library` — el namespace implícito de Docker Hub para las imágenes oficiales.
- **Repositorio**: `nginx`.
- **Tag**: `1.27` — un puntero mutable. Opcionalmente reemplazado o acompañado por `@sha256:<digest>`, una referencia de contenido inmutable. Si se dan ambos, gana el digest y el tag es documentación.

**A34.** El driver `docker` por defecto construye **a través del BuildKit embebido en el Docker Engine y exporta al almacén local de imágenes**, que usa el formato de imagen legacy de Docker — ese almacén no tiene representación para una lista de manifests / índice de imagen, así que puede contener exactamente una plataforma por tag. Tampoco tiene forma de emular una arquitectura foránea. El driver `docker-container` ejecuta BuildKit en un **contenedor dedicado**, lo que te da: salida de lista de manifests (`--platform` con múltiples valores), emulación basada en QEMU para arquitecturas foráneas vía `binfmt_misc`, exportación de caché remota/al registry (`--cache-to type=registry`), y el conjunto completo de exportadores (`type=oci`, `type=local`, attestations). Alternativas: el driver `kubernetes` (builders como pods, nodos nativos por arquitectura — más rápido que la emulación) y el driver `remote`.

**A35.** Sin `--platform=$BUILDPLATFORM`, `FROM golang:...` hereda la plataforma **objetivo**, así que BuildKit descarga el toolchain de Go `linux/arm64` y lo ejecuta bajo **emulación en modo usuario de QEMU** en tu host amd64. Cada instrucción del compilador se traduce — típicamente **5–20× más lento**, y propenso a bugs oscuros de emulación en JITs y builds multihilo.

Con `--platform=$BUILDPLATFORM`, la etapa de build se fija a la plataforma **nativa del host**, así que el toolchain de Go amd64 corre a velocidad plena y cross-compila vía `GOOS`/`GOARCH` (que BuildKit suministra automáticamente como `TARGETOS`/`TARGETARCH`). Solo la diminuta etapa de runtime es por plataforma. Este patrón funciona para cualquier lenguaje con un cross-compilador real — Go, Rust, Zig — y es la palanca más grande sobre el tiempo de build multi-arquitectura.

**A36.** El `mode=min` por defecto exporta **solo las capas de la imagen final** — suficiente para saltear la re-exportación en una reconstrucción, pero inútil para los pasos intermedios de las builds multi-etapa, que es donde vive el trabajo caro. `mode=max` exporta **caché para cada paso intermedio de cada etapa**, incluidas las etapas de build descartadas. En un runner de CI que arranca desde una caché vacía cada vez, `mode=max` es lo que realmente hace que `go mod download` y `pip install` acierten. El costo es almacenamiento en el registry y tiempo de push/pull: la imagen de caché fácilmente puede ser varias veces el tamaño de la imagen de runtime (contiene todo el conjunto de capas del toolchain). Mitigalo con un repositorio `-cache` separado, una política de retención más corta sobre él, y `--cache-to type=registry,...,compression=zstd`.

### Ejercicio 9

**A37.** El socket de Docker es una **API sin autenticación equivalente a root**. Cualquier proceso que pueda escribir en él puede emitir:

```bash
docker run -v /:/host --privileged --pid=host -it alpine chroot /host sh
```

que monta el sistema de archivos raíz del host en modo lectura-escritura dentro de un contenedor privilegiado y da un shell interactivo de root en el host. Desde ahí: leer los secretos de cualquier otro job y las credenciales de registry del runner de CI, instalar una puerta trasera persistente, pivotar hacia el clúster con las credenciales del kubelet del nodo. Notá que quien ataca no necesita un `Dockerfile` malicioso — alcanza con una dependencia transitiva comprometida que se ejecute durante un `RUN`, o cualquier código con acceso al socket montado en el contenedor del job. **"Acceso al socket de Docker" y "root en el host" son el mismo privilegio.** Precisamente por esto existen BuildKit rootless, Buildah y Kaniko.

**A38.** Imprimió el **mapeo de UID del user namespace** para el entorno de contenedores rootless:
```
         0       1000          1     ← in-namespace UID 0  → host UID 1000 (you), range 1
         1     100000      65536     ← in-namespace UIDs 1..65536 → host UIDs 100000..165535
```
Los user namespaces del kernel permiten que un usuario sin privilegios cree un namespace en el que posee `CAP_SYS_ADMIN` y otras capacidades *acotadas solo a ese namespace*. Tu UID real (1000) se mapea al UID 0 adentro, así que un proceso ahí se ve a sí mismo como root y puede hacer `chown`, `mknod` en el namespace, y montar sistemas de archivos — pero cada operación contra el host se sigue aplicando contra el UID 1000 o contra el rango subordinado. Los UIDs adicionales vienen de `/etc/subuid` y `/etc/subgid` (`newuidmap`/`newgidmap` de `shadow-utils` establecen el mapeo). Esto es lo que hace que `podman build` como usuario normal produzca imágenes cuyos archivos son propiedad de "root" sin ningún privilegio en el host — y por qué un escape de imagen desde un contenedor rootless te deja como un usuario sin privilegios del host en vez de como root.

**A39.** **Mejor con Buildah:** construir una imagen cuyo contenido lo produce herramienta que ya existe fuera del contenedor — por ejemplo, ensamblar una imagen a partir de RPMs resueltos por el `dnf` del host, desde un directorio de salida de Nix o Bazel, o desde un artefacto que tu sistema de build existente ya produjo. No hay gimnasia de `Dockerfile` para meter a la fuerza un árbol preconstruido en capas; `buildah from scratch` + `buildah copy`/`buildah add` + `buildah config` + `buildah commit` lo compone directamente, con control total de shell sobre el orden, los reintentos, los condicionales y las decisiones por capa. También compone naturalmente con `buildah mount`, permitiéndote manipular el rootfs con herramientas ordinarias del host.

**Lo que perdés:** el `Dockerfile` como **contrato declarativo, portable y universalmente legible**. Un script de shell no es analizable por `hadolint`, no lo puede construir ninguna otra herramienta, no lo renderiza la interfaz de un registry, y su comportamiento depende del shell del host y de las utilidades instaladas. También perdés la caché de build automática del frontend — tenés que inventar tu propia idempotencia. En la práctica la mayoría de los equipos usa `buildah bud` con un Dockerfile y reserva la API guionada para los casos de arriba.

**A40.** (1) **Los argumentos son visibles en todas partes.** `args:` en una especificación de Pod se almacena en etcd en texto plano, lo repite `kubectl describe pod`, `kubectl get pod -o yaml`, cada entrada de log de auditoría, y cada log de CI que imprima el manifiesto — además aparecen en `/proc/<pid>/cmdline`, legible por cualquier proceso del contenedor. Un `Secret` montado como archivo al menos está restringido por RBAC sobre el objeto Secret, no lo imprime `describe`, y puede cifrarse en reposo vía `EncryptionConfiguration`. (2) **Es la interfaz que las herramientas esperan**: tanto BuildKit como Kaniko leen un `~/.docker/config.json` estándar, así que el mismo Secret sirve para `imagePullSecrets`, para `docker login`, y para los credential helpers — sin plomería de flags a medida, y la rotación es una actualización del Secret en vez de un cambio de manifiesto en cada pipeline. Una tercera razón que vale la pena enunciar: un Secret montado puede intercambiarse por un token de vida corta derivado de identidad de carga de trabajo (IRSA, Workload Identity Federation), cosa que un argumento en línea no puede.

### Ejercicio 10

**A41.**

| # | Defecto | Cuándo pega |
|---|---|---|
| 1 | `RUN pip install -r requirements.txt` **antes** de que ningún `COPY` traiga el archivo | **Falla de build** — `No such file or directory` |
| 2 | `USER appuser` puesto antes de `WORKDIR`/`COPY`, así que `WORKDIR /opt/app` se crea **propiedad de root** y el `COPY` sin privilegios no puede escribir ahí | **Falla de build** — `permission denied` |
| 3 | `ENV FLASK_SECRET=hunter2` hornea una credencial en la configuración de la imagen, legible con `docker image inspect` por cualquiera que pueda descargarla | **Runtime / seguridad** — la imagen es un secreto publicado |
| 4 | `VOLUME /opt/app/data` seguido de un `RUN` que escribe ahí: la escritura se **descarta** (ver A43) | **Runtime** — `seed.txt` falta silenciosamente |
| 5 | `ENTRYPOINT python server.py` en **forma shell**: PID 1 es `/bin/sh`, `SIGTERM` no se reenvía, `CMD` y los argumentos de ejecución se ignoran | **Runtime** — apagados de 10 s (o del período de gracia completo), salida 137 |

Bonus, no contados pero relevantes en producción: `FROM python:3.12` es la imagen Debian completa de ~1 GB donde `python:3.12-slim` (~120 MB) alcanza; no hay `HEALTHCHECK`; `pip` corre sin `--no-cache-dir`; nada está fijado por versión; `USER` es un nombre en vez de un UID numérico (A26).

**A42.** `COPY` lo ejecuta el **proceso builder**, pero el archivo que escribe aterriza en la capa con una propiedad determinada y dentro de un directorio cuyos permisos fueron establecidos por instrucciones anteriores. Acá se combinan dos cosas:
- `WORKDIR /opt/app` **crea el directorio si no existe, siempre propiedad de `root:root` con modo `0755`** — el `USER` activo no cambia eso.
- `COPY` establece por defecto la propiedad del *archivo copiado* como `0:0` (root), pero BuildKit realiza la escritura en el contexto del `USER` actual. Con `USER appuser` activo y el destino `root:root 0755`, la escritura dentro de un directorio no escribible falla.

`COPY --chown=appuser:appuser` establece la propiedad del archivo resultante, lo que atiende el *archivo*; el arreglo duradero es **crear el directorio con la propiedad correcta antes de cambiar de usuario** — `install -d -o appuser -g appuser /opt/app` — y ubicar `USER` lo más tarde posible, inmediatamente antes de `ENTRYPOINT`. Eso es lo que hace el Dockerfile reparado: instalar dependencias como root, después soltar privilegios una sola vez, al final. También significa que la aplicación no puede reescribir su propio código en tiempo de ejecución, que es una propiedad de seguridad que vale la pena tener.

**A43.** `seed.txt` **no existe en la imagen.** Después de una declaración `VOLUME`, cualquier cambio hecho por una instrucción *posterior* a esa ruta se hace dentro de un montaje temporal que se descarta cuando la instrucción termina — el sistema de build explícitamente no compromete escrituras a rutas declaradas como volumen. La build reporta éxito, `docker image history` muestra el `RUN`, y el archivo simplemente está ausente en tiempo de ejecución. El arreglo es el orden: escribí los datos primero, declará `VOLUME` después — o, mejor, no lo declares en absoluto.

El segundo problema, más sutil: `VOLUME` en una imagen significa que **cada `docker run` crea un volumen anónimo nuevo**. Esos volúmenes nunca se recolectan junto con el contenedor a menos que pases `--rm` o les hagas `docker volume prune`, así que un servicio reiniciado unos pocos miles de veces acumula miles de volúmenes huérfanos y eventualmente llena el disco. También vuelve no obvia la ruta de datos del contenedor y rompe el razonamiento sobre `--read-only`. Bajo Kubernetes, `VOLUME` en la imagen en el mejor de los casos se ignora y en el peor confunde — el almacenamiento pertenece a la especificación del Pod (`emptyDir`, `PersistentVolumeClaim`), declarado por quien opera, no horneado en el artefacto por quien autora la imagen. **No uses `VOLUME` en imágenes de aplicación.**

**A44.** **Tienen razón respecto de Kubernetes, y aun así vale la pena conservarlo.**

`HEALTHCHECK` es una **extensión de Docker/Moby**, no parte de la especificación de imagen OCI. Bajo Kubernetes el runtime de CRI (containerd, CRI-O) **no lo evalúa en absoluto** — no se ejecuta ninguna prueba, `.State.Health` nunca existe, y nada en el clúster reacciona a él. Kubernetes usa `livenessProbe`, `readinessProbe` y `startupProbe` en la especificación del Pod, que son estrictamente más expresivas (semánticas de falla separadas: readiness quita el endpoint, liveness reinicia el contenedor, startup suprime a las otras dos durante un arranque lento) y son decisión de quien opera, no de quien autora la imagen.

Conservalo igual porque: es el único contrato de salud que funciona bajo `docker run` a secas, `docker compose` (`depends_on: condition: service_healthy`), Podman y Swarm — que es donde quienes desarrollan ejecutan la imagen localmente y donde corren los tests de integración en CI. Y **documenta el endpoint de salud** para quien escriba la especificación del Pod. El costo es una línea y un proceso periódico dentro del contenedor, así que el trato es fácil. Simplemente no dependas de él en el clúster: escribí probes reales.

```yaml
readinessProbe:
  httpGet: { path: /healthz, port: 8080 }
  periodSeconds: 5
  failureThreshold: 3
livenessProbe:
  httpGet: { path: /healthz, port: 8080 }
  periodSeconds: 20
  failureThreshold: 3
startupProbe:
  httpGet: { path: /healthz, port: 8080 }
  periodSeconds: 5
  failureThreshold: 30
```

</details>