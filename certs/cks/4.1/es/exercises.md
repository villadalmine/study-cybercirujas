# CKS 4.1 — Minimizar la Superficie de la Imagen Base
## Ejercicios Guiados (examen v1.34 · Supply Chain Security · peso 5)

> **Qué estás practicando.** Cada byte de una imagen de contenedor es o bien código que ejecutás o bien superficie de ataque que heredás. Este laboratorio recorre el camino completo de reducción — *imagen builder gorda → distro slim → distroless → scratch* — y te obliga a **medir** el resultado en cada paso (tamaño, cantidad de paquetes, cantidad de CVEs, presencia de una shell), en lugar de confiar en el marketing del README de una imagen base. También vas a romper cosas a propósito: las imágenes mínimas fallan de maneras muy específicas y muy reconocibles (falta el bundle de CAs, falta `/etc/passwd`, falta `/tmp`, `kubectl exec` devolviendo `exec: "sh": executable file not found`), y reconocer esas fallas al instante es lo que separa un build endurecido de un deployment revertido.

### Prerrequisitos del laboratorio

| Herramienta | Mínimo | Verificación |
|---|---|---|
| Docker Engine (BuildKit activado por defecto) | 24.x | `docker version --format '{{.Server.Version}}'` |
| kubectl | 1.34 | `kubectl version --client` |
| Un clúster (kind / minikube / k3s) | 1.32+ | `kubectl get nodes` |
| Trivy | 0.58+ | `trivy --version` |
| Syft | 1.18+ | `syft version` |
| dive (opcional, explorador de capas) | 0.12+ | `dive --version` |
| crane (`go-containerregistry`) | 0.20+ | `crane version` |

```bash
mkdir -p ~/cks/4.1 && cd ~/cks/4.1
export DOCKER_BUILDKIT=1
```

> Usuarios de Podman: todos los comandos `docker` de abajo funcionan con `podman`, excepto `docker history --no-trunc` (usá `podman history --no-trunc`) y `dive` (usá `dive podman://<image>`).

---

## Ejercicio 1 — Construir la línea base que vas a achicar

No podés afirmar una reducción sin un "antes". Construí primero la imagen ingenua: la que casi todo equipo publica el primer día, donde el **toolchain de compilación es también el runtime**.

1. Creá la aplicación. Expone un endpoint de salud, reporta su propio UID/GID, y hace una llamada TLS saliente (ese último handler importa en el Ejercicio 6).

```bash
cat > main.go <<'EOF'
package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
)

func main() {
	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "ok")
	})

	http.HandleFunc("/whoami", func(w http.ResponseWriter, r *http.Request) {
		host, _ := os.Hostname()
		fmt.Fprintf(w, "host=%s uid=%d gid=%d\n", host, os.Getuid(), os.Getgid())
	})

	// Exercises the system trust store: fails on `scratch` without a CA bundle.
	http.HandleFunc("/fetch", func(w http.ResponseWriter, r *http.Request) {
		resp, err := http.Get("https://kubernetes.io/")
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		defer resp.Body.Close()
		fmt.Fprintf(w, "upstream status: %s\n", resp.Status)
	})

	log.Println("listening on :8080")
	log.Fatal(http.ListenAndServe(":8080", nil))
}
EOF

cat > go.mod <<'EOF'
module example.com/minimal

go 1.24
EOF
```

2. Escribí el Dockerfile ingenuo — compilar y ejecutar en la misma imagen `golang`.

```bash
cat > Dockerfile.fat <<'EOF'
FROM golang:1.24
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN go build -o /usr/local/bin/app ./...
EXPOSE 8080
CMD ["app"]
EOF

docker build -f Dockerfile.fat -t cks41/app:fat .
```

3. Medila. Tamaño, cantidad de capas, y qué hay realmente instalado adentro.

```bash
docker images cks41/app:fat --format 'table {{.Repository}}:{{.Tag}}\t{{.Size}}'
docker image inspect cks41/app:fat --format '{{len .RootFS.Layers}} layers'
docker run --rm cks41/app:fat dpkg-query -f '${binary:Package}\n' -W | wc -l
```

Forma esperada de la salida (tus cifras exactas van a diferir según la fecha de build de la imagen base):

```
REPOSITORY:TAG      SIZE
cks41/app:fat       1.03GB
9 layers
430
```

4. Enumerá la superficie de ataque *interactiva*: shells, gestores de paquetes y binarios setuid.

```bash
docker run --rm cks41/app:fat sh -c 'ls /bin/sh /bin/bash /usr/bin/apt /usr/bin/curl /usr/bin/wget 2>&1'
docker run --rm cks41/app:fat find / -xdev -perm -4000 -type f 2>/dev/null
```

```
/bin/bash
/bin/sh
/usr/bin/apt
/usr/bin/curl
/usr/bin/wget
/usr/bin/chsh
/usr/bin/gpasswd
/usr/bin/mount
/usr/bin/newgrp
/usr/bin/passwd
/usr/bin/su
/usr/bin/umount
/usr/bin/chfn
/usr/bin/sudo
```

5. Escaneala. Registrá los totales en un archivo borrador — vas a compararlos repetidamente.

```bash
trivy image --scanners vuln --severity HIGH,CRITICAL cks41/app:fat | tail -20
trivy image --scanners vuln --format json cks41/app:fat \
  | jq '[.Results[].Vulnerabilities // [] | length] | add'
```

```
Total: 1187 (HIGH: 78, CRITICAL: 4)
```

**Preguntas — bloque 1**

- **Q1.1** El binario compilado pesa aproximadamente 7 MB. ¿De dónde salió el otro ~1 GB, y por qué *nada* de eso es necesario en runtime para este programa en particular?
- **Q1.2** `docker run --rm cks41/app:fat` ejecuta `CMD ["app"]` y funciona, pero la forma exec **no** invoca una shell. ¿Cómo se resuelve `app` sin una?
- **Q1.3** Ordenando por riesgo realista de examen/producción, ¿qué es peor en esta imagen: los 4 CVEs CRITICAL, o la presencia de `/bin/sh`, `apt` y `curl`? Justificá en términos de la kill chain de un atacante.
- **Q1.4** Volvés a correr el escaneo en tres semanas contra el *idéntico* digest de la imagen y el total de CVEs sube. ¿Cambió la imagen? ¿Qué cambió?
- **Q1.5** ¿Por qué `find / -xdev -perm -4000` usa `-xdev`, y qué te perderías si lo quitaras al escanear un contenedor *en ejecución* en lugar de una imagen?

---

## Ejercicio 2 — Higiene de capas: la reducción que no te cuesta nada

Antes de cambiar imágenes base, corregí los errores mecánicos. Estos aplican a *cualquier* Dockerfile, incluidos los que te van a pedir criticar en un escenario de examen.

1. Construí una imagen deliberadamente derrochadora con los tres antipatrones clásicos: un `RUN` por comando, `apt-get` sin `--no-install-recommends`, y un paso de limpieza en una capa *posterior*.

```bash
cat > Dockerfile.wasteful <<'EOF'
FROM debian:12
RUN apt-get update
RUN apt-get install -y ca-certificates curl jq
RUN rm -rf /var/lib/apt/lists/*
COPY --from=cks41/app:fat /usr/local/bin/app /usr/local/bin/app
CMD ["app"]
EOF

docker build -f Dockerfile.wasteful -t cks41/app:wasteful .
```

2. Construí la versión corregida: un solo `RUN`, recommends deshabilitados, caché purgado **dentro de la misma capa**.

```bash
cat > Dockerfile.tidy <<'EOF'
FROM debian:12-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY --from=cks41/app:fat /usr/local/bin/app /usr/local/bin/app
CMD ["app"]
EOF

docker build -f Dockerfile.tidy -t cks41/app:tidy .
```

3. Compará, después inspeccioná dónde se fueron los bytes.

```bash
docker images 'cks41/app' --format 'table {{.Tag}}\t{{.Size}}'
docker history cks41/app:wasteful --format 'table {{.Size}}\t{{.CreatedBy}}' | head -8
```

```
TAG         SIZE
fat         1.03GB
wasteful    218MB
tidy        105MB
```

```
SIZE      CREATED BY
7.31MB    COPY /usr/local/bin/app /usr/local/bin/app # buildkit
0B        RUN /bin/sh -c rm -rf /var/lib/apt/lists/* # buildkit
71.4MB    RUN /bin/sh -c apt-get install -y ca-certificates curl jq # buildkit
23.6MB    RUN /bin/sh -c apt-get update # buildkit
117MB     <missing>
```

4. Confirmá que la capa del `rm -rf` es una mentira leyendo la *unión* de capas versus una capa individual.

```bash
docker run --rm cks41/app:wasteful ls /var/lib/apt/lists/     # empty at runtime
dive cks41/app:wasteful                                       # press Tab, inspect layer 3
```

5. Agregá un `.dockerignore`. Creá primero una fuga de contexto de build plausible, después probá la corrección.

```bash
mkdir -p .git && echo 'https://ci-bot:ghp_REDACTEDTOKEN@github.com' > .git/credentials
echo 'AWS_SECRET_ACCESS_KEY=wJalrXUtn' > .env

cat > Dockerfile.ctx <<'EOF'
FROM debian:12-slim
COPY . /build
CMD ["sleep", "infinity"]
EOF

docker build -f Dockerfile.ctx -t cks41/ctx:leaky .
docker run --rm cks41/ctx:leaky cat /build/.git/credentials /build/.env
```

```bash
cat > .dockerignore <<'EOF'
.git
.env
*.pem
*.key
node_modules
Dockerfile*
EOF

docker build -f Dockerfile.ctx -t cks41/ctx:clean .
docker run --rm cks41/ctx:clean ls -a /build
```

**Preguntas — bloque 2**

- **Q2.1** `docker history` reporta la capa del `rm -rf /var/lib/apt/lists/*` como `0B`, y sin embargo la imagen es 113 MB más grande que `tidy`. Explicá con precisión qué es un archivo whiteout y por qué los datos borrados igual se envían a cada nodo que baja la imagen.
- **Q2.2** `--no-install-recommends` eliminó aproximadamente cuánto, y — más importante — ¿qué *clase* de paquetes excluye? Nombrá una consecuencia de seguridad de enviar paquetes recomendados.
- **Q2.3** Fusionar todos los comandos en un solo `RUN` achica la imagen pero perjudica otra cosa. ¿Cuál, y cuándo ese compromiso es equivocado?
- **Q2.4** `.dockerignore` impidió que el directorio `.git` entrara a la imagen. ¿Impidió que la credencial fuera *legible por el build*? ¿Cuál es el mecanismo correcto cuando un build genuinamente necesita un secreto?
- **Q2.5** Un compañero propone `docker build --squash` como corrección universal para capas filtradas. Dá dos razones por las que esa es la respuesta equivocada para un pipeline de nivel CKS.

---

## Ejercicio 3 — Builds multi-stage: separar el toolchain del runtime

1. Escribí el build canónico de dos etapas. Fijate en cada flag — cada uno es deliberado.

```bash
cat > Dockerfile.multi <<'EOF'
# ---- build stage -------------------------------------------------------
FROM golang:1.24-bookworm AS builder
WORKDIR /src
COPY go.mod ./
COPY main.go ./
# CGO_ENABLED=0 -> statically linked, no libc dependency at runtime.
# -trimpath     -> strips absolute build paths (reproducibility, no path leak).
# -ldflags="-s -w" -> drops the symbol table and DWARF debug info.
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags="-s -w" -o /out/app ./...

# ---- runtime stage -----------------------------------------------------
FROM debian:12-slim AS runtime
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY --from=builder /out/app /usr/local/bin/app
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/app"]
EOF

docker build -f Dockerfile.multi -t cks41/app:multi .
```

2. Verificá que el toolchain no sobrevivió a la imagen final.

```bash
docker run --rm cks41/app:multi sh -c 'command -v go gcc git make; echo exit=$?'
docker run --rm cks41/app:multi id
```

```
exit=1
uid=65532 gid=65532 groups=65532
```

3. Probá que el binario es estático (esta es la precondición para los próximos dos ejercicios).

```bash
docker run --rm cks41/app:multi sh -c 'ldd /usr/local/bin/app' 2>&1 | head -2
```

```
	not a dynamic executable
```

4. Construí una variante enlazada *dinámicamente* para que puedas ver el modo de falla más adelante.

```bash
docker build -f Dockerfile.multi -t cks41/app:cgo \
  --build-arg X=1 --target builder .
docker run --rm -v "$PWD":/src -w /src golang:1.24-bookworm \
  sh -c 'CGO_ENABLED=1 go build -o /tmp/app-cgo ./... && ldd /tmp/app-cgo'
```

```
	linux-vdso.so.1 (0x00007ffd8b5f8000)
	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f2c4a000000)
	/lib64/ld-linux-x86-64.so.2 (0x00007f2c4a2b0000)
```

5. Compará la cantidad de vulnerabilidades contra la línea base.

```bash
for t in fat tidy multi; do
  printf '%-8s ' "$t"
  trivy image --scanners vuln --quiet --format json "cks41/app:$t" \
    | jq -r '[.Results[]?.Vulnerabilities // [] | length] | add // 0'
done
```

**Preguntas — bloque 3**

- **Q3.1** Multi-stage eliminó el compilador, pero el runtime sigue siendo `debian:12-slim` con ~90 paquetes. ¿Qué categoría de CVE eliminó multi-stage por completo, y qué categoría no tocó en absoluto?
- **Q3.2** ¿Qué cambia exactamente `CGO_ENABLED=0` en el binario producido, y por qué es un *prerrequisito* para `FROM scratch` en lugar de simplemente una optimización?
- **Q3.3** `-ldflags="-s -w"` achica el binario. Nombrá una capacidad operativa que perdés, y un beneficio de seguridad que ganás.
- **Q3.4** `USER 65532:65532` aparece en la etapa de runtime. ¿Por qué la forma numérica en lugar de `USER nonroot`, dado que Kubernetes después va a evaluar `runAsNonRoot: true`?
- **Q3.5** La etapa de build hace `COPY go.mod ./` antes de `COPY main.go ./`. ¿Cuál es la razón para separar eso en dos instrucciones, y qué se rompe si escribís `COPY . .` en su lugar?

---

## Ejercicio 4 — Distroless: quitar la shell, el gestor de paquetes y la distro

Las imágenes distroless llevan el runtime del lenguaje y sus dependencias — nada más. Sin shell, sin `apt`, sin `busybox`, sin binarios setuid.

1. Reconstruí sobre `gcr.io/distroless/static-debian12`.

```bash
cat > Dockerfile.distroless <<'EOF'
FROM golang:1.24-bookworm AS builder
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/app ./...

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /out/app /app
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/app"]
EOF

docker build -f Dockerfile.distroless -t cks41/app:distroless .
docker images cks41/app --format 'table {{.Tag}}\t{{.Size}}'
```

```
TAG          SIZE
fat          1.03GB
wasteful     218MB
tidy         105MB
multi        104MB
distroless   9.63MB
```

2. Intentá obtener una shell. Esta es la propiedad definitoria de la imagen.

```bash
docker run --rm -it cks41/app:distroless sh
```

```
docker: Error response from daemon: failed to create task for container:
failed to create shim task: OCI runtime create failed: runc create failed:
unable to start container process: exec: "sh": executable file not found in $PATH
```

3. Enumerá qué *sí* hay adentro, usando una herramienta que no necesite una shell en la imagen.

```bash
docker export "$(docker create cks41/app:distroless)" | tar -tv | head -30
```

```
drwxr-xr-x 0/0               0 2026-08-04 00:00 ./
-rwxr-xr-x 0/0         7315456 2026-08-04 00:00 app
drwxr-xr-x 0/0               0 1970-01-01 00:00 etc/
-rw-r--r-- 0/0             127 1970-01-01 00:00 etc/passwd
-rw-r--r-- 0/0              82 1970-01-01 00:00 etc/group
-rw-r--r-- 0/0            1748 1970-01-01 00:00 etc/nsswitch.conf
drwxr-xr-x 0/0               0 1970-01-01 00:00 etc/ssl/certs/
-rw-r--r-- 0/0          213234 1970-01-01 00:00 etc/ssl/certs/ca-certificates.crt
drwxrwxrwx 0/0               0 1970-01-01 00:00 tmp/
drwxr-xr-x 0/0               0 1970-01-01 00:00 var/run/
```

4. Compará inventarios de paquetes con un SBOM en lugar de `dpkg`.

```bash
for t in fat tidy distroless; do
  printf '%-11s ' "$t"
  syft -q -o json "cks41/app:$t" | jq '.artifacts | length'
done
```

```
fat         431
tidy        94
distroless  3
```

5. Escaneá, y observá cómo se ven ahora los números.

```bash
trivy image --scanners vuln --severity LOW,MEDIUM,HIGH,CRITICAL cks41/app:distroless
```

```
cks41/app:distroless (debian 12.11)
Total: 0 (LOW: 0, MEDIUM: 0, HIGH: 0, CRITICAL: 0)

app (gobinary)
Total: 0 (LOW: 0, MEDIUM: 0, HIGH: 0, CRITICAL: 0)
```

6. Mirá la variante debug, y entendé por qué existe.

```bash
crane manifest gcr.io/distroless/static-debian12:debug-nonroot | jq '.config.digest'
docker run --rm -it gcr.io/distroless/static-debian12:debug-nonroot sh -c 'busybox | head -1; ls /busybox'
```

**Preguntas — bloque 4**

- **Q4.1** Trivy reporta `Total: 0`. Dá dos razones distintas por las que "cero hallazgos" *no* es lo mismo que "sin vulnerabilidades", y cómo detectarías una falla que este escaneo estructuralmente no puede ver.
- **Q4.2** Quitar `/bin/sh` bloquea un paso de explotación específico y muy común. Nombralo, y nombrá una clase de RCE que quitar la shell **no** bloquea.
- **Q4.3** `gcr.io/distroless/static-debian12` sigue llevando `/etc/ssl/certs/ca-certificates.crt` y `/etc/passwd`. ¿Por qué se mantienen deliberadamente esos dos archivos, si todo el punto es el minimalismo?
- **Q4.4** ¿Cuál es la diferencia operativa entre el tag `:nonroot` y el tag simple, y qué pasa si usás el tag simple junto con un Pod que fija `runAsNonRoot: true` pero no `runAsUser`?
- **Q4.5** `debug-nonroot` incluye una shell BusyBox. Explicá por qué enviar ese tag a producción anula el ejercicio, y cuál es la alternativa soportada en Kubernetes 1.34.

---

## Ejercicio 5 — `scratch`: el piso absoluto, y sus cuatro modos de falla

`scratch` no es una imagen — es la base vacía. Todo lo que el proceso necesite debe copiarse explícitamente. Construila, después rompela de cuatro maneras distintas para reconocer cada error a simple vista.

1. Construí la imagen `scratch` deliberadamente ingenua.

```bash
cat > Dockerfile.scratch-naive <<'EOF'
FROM golang:1.24-bookworm AS builder
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/app ./...

FROM scratch
COPY --from=builder /out/app /app
ENTRYPOINT ["/app"]
EOF

docker build -f Dockerfile.scratch-naive -t cks41/app:scratch-naive .
docker images cks41/app:scratch-naive --format '{{.Size}}'
```

```
7.32MB
```

2. **Modo de falla 1 — sin almacén de confianza TLS.** Arrancala y llamá al handler saliente.

```bash
docker run -d --name s1 -p 8081:8080 cks41/app:scratch-naive
curl -s localhost:8081/whoami
curl -s localhost:8081/fetch
```

```
host=3f2c1b4d9a77 uid=0 gid=0
Get "https://kubernetes.io/": tls: failed to verify certificate: x509: certificate signed by unknown authority
```

3. **Modo de falla 2 — la forma shell de `ENTRYPOINT`.** Reconstruí con `ENTRYPOINT /app` (sin array JSON) y observá.

```bash
sed 's|ENTRYPOINT \["/app"\]|ENTRYPOINT /app|' Dockerfile.scratch-naive > Dockerfile.scratch-shellform
docker build -f Dockerfile.scratch-shellform -t cks41/app:scratch-shellform .
docker run --rm cks41/app:scratch-shellform
```

```
exec: "/bin/sh": stat /bin/sh: no such file or directory: unknown
```

4. **Modo de falla 3 — sin `/etc/passwd`, sin `/tmp`.** Confirmá que el contenedor corre como UID 0 sin base de datos de usuarios, y que cualquier código que llame a `os.TempDir()` o escriba en `/tmp` va a fallar.

```bash
docker run --rm cks41/app:scratch-naive 2>/dev/null || true
docker export "$(docker create cks41/app:scratch-naive)" | tar -tv
```

```
-rwxr-xr-x 0/0         7315456 2026-08-04 00:00 app
```

5. Ahora construí la imagen `scratch` **correcta**: bundle de CAs, una entrada no-root en la base de datos de usuarios, un directorio temporal escribible, y datos de zona horaria.

```bash
cat > Dockerfile.scratch <<'EOF'
FROM golang:1.24-bookworm AS builder
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/app ./...

# Manufacture a minimal user database instead of copying the builder's.
RUN printf 'app:x:65532:65532:app:/nonexistent:/sbin/nologin\n' > /out/passwd \
 && printf 'app:x:65532:\n'                                    > /out/group \
 && mkdir -p /out/tmp && chmod 1777 /out/tmp

FROM scratch
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=builder /usr/share/zoneinfo /usr/share/zoneinfo
COPY --from=builder /out/passwd /etc/passwd
COPY --from=builder /out/group  /etc/group
COPY --from=builder --chown=65532:65532 /out/tmp /tmp
COPY --from=builder /out/app /app
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/app"]
EOF

docker build -f Dockerfile.scratch -t cks41/app:scratch .
docker rm -f s1 >/dev/null 2>&1
docker run -d --name s2 -p 8082:8080 cks41/app:scratch
curl -s localhost:8082/whoami
curl -s localhost:8082/fetch
docker images cks41/app:scratch --format '{{.Size}}'
```

```
host=91ac5e0f77b2 uid=65532 gid=65532
upstream status: 200 OK
7.55MB
```

6. **Modo de falla 4 — enlazado dinámico.** Copiá el binario CGO del Ejercicio 3 dentro de `scratch` y ejecutalo.

```bash
cat > Dockerfile.scratch-cgo <<'EOF'
FROM golang:1.24-bookworm AS builder
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=1 GOOS=linux go build -o /out/app ./...

FROM scratch
COPY --from=builder /out/app /app
ENTRYPOINT ["/app"]
EOF

docker build -f Dockerfile.scratch-cgo -t cks41/app:scratch-cgo .
docker run --rm cks41/app:scratch-cgo
```

```
exec /app: no such file or directory
```

**Preguntas — bloque 5**

- **Q5.1** En el paso 6 el binario `/app` demostrablemente existe dentro de la imagen, y sin embargo el kernel reporta `no such file or directory`. Explicá cuál es el archivo que realmente falta.
- **Q5.2** La imagen `scratch` resolvió `kubernetes.io` correctamente sin `/etc/nsswitch.conf` ni `/etc/resolv.conf` copiados adentro. ¿Por qué funcionó el DNS, y bajo exactamente qué flag de build dejaría de funcionar?
- **Q5.3** Copiás `/etc/passwd` de la etapa builder tal cual en lugar de fabricar uno. Nombrá dos problemas concretos de ese atajo.
- **Q5.4** `scratch` pesa 7,55 MB versus distroless con 9,63 MB — un ahorro de 2 MB. Argumentá a favor de elegir distroless igualmente en un entorno de producción regulado.
- **Q5.5** Trivy sobre la imagen `scratch` no reporta ningún paquete de sistema operativo. ¿Qué significa eso para un requisito de cumplimiento que dice "todas las imágenes desplegadas deben tener un SBOM de paquetes del SO", y cómo lo satisfacés?

---

## Ejercicio 6 — Alpine y el compromiso de musl

Alpine es el punto medio popular: ~8 MB, un gestor de paquetes real, una shell real. Entendé con precisión qué comprás y qué pagás.

1. Construí sobre Alpine.

```bash
cat > Dockerfile.alpine <<'EOF'
FROM golang:1.24-alpine AS builder
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/app ./...

FROM alpine:3.22
RUN apk add --no-cache ca-certificates \
 && addgroup -g 65532 -S app \
 && adduser  -u 65532 -S app -G app
COPY --from=builder /out/app /app
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/app"]
EOF

docker build -f Dockerfile.alpine -t cks41/app:alpine .
docker images cks41/app --format 'table {{.Tag}}\t{{.Size}}' | sort -k2 -h
```

2. Confirmá qué le da Alpine a un atacante que distroless no.

```bash
docker run --rm cks41/app:alpine sh -c 'command -v sh wget apk busybox; apk list --installed | wc -l'
```

```
/bin/sh
/usr/bin/wget
/sbin/apk
/bin/busybox
19
```

3. Observá el idiom `--no-cache` versus el equivalente de `apt`.

```bash
docker run --rm cks41/app:alpine ls /var/cache/apk/
docker history cks41/app:alpine --format 'table {{.Size}}\t{{.CreatedBy}}' | head -5
```

4. Demostrá la diferencia de libc. Compilá un binario CGO contra glibc e intentá ejecutarlo en Alpine.

```bash
docker run --rm -v "$PWD":/src -w /src golang:1.24-bookworm \
  sh -c 'CGO_ENABLED=1 go build -o /src/app-glibc ./...'
docker run --rm -v "$PWD":/src alpine:3.22 /src/app-glibc
```

```
/src/app-glibc: /lib/x86_64-linux-gnu/libc.so.6: not found
```

5. Compará resultados de escaneo en toda la familia.

```bash
for t in fat tidy multi alpine distroless scratch; do
  printf '%-11s %-9s ' "$t" "$(docker images -q --format '{{.Size}}' cks41/app:$t)"
  trivy image --scanners vuln --quiet --format json "cks41/app:$t" \
    | jq -r '[.Results[]?.Vulnerabilities // [] | length] | add // 0'
done
```

**Preguntas — bloque 6**

- **Q6.1** `apk add --no-cache` es un solo flag; el equivalente de Debian necesita `rm -rf /var/lib/apt/lists/*` encadenado dentro del mismo `RUN`. Explicá la diferencia de comportamiento subyacente.
- **Q6.2** La cantidad de paquetes de Alpine (19) está muy por debajo de la de Debian slim (94) pero muy por encima de la de distroless (3). ¿Qué componentes específicos explican ese punto medio, y qué capacidad le dan a un kit de post-explotación?
- **Q6.3** El binario glibc falla en Alpine con `libc.so.6: not found`. Más allá de la portabilidad, nombrá una diferencia de *comportamiento en runtime* entre musl y glibc que haya afectado cargas de trabajo Kubernetes en producción.
- **Q6.4** Un equipo dice "Alpine es más seguro que Debian porque tiene menos CVEs". Dá dos razones por las que esa comparación no es sólida tal como está planteada.
- **Q6.5** Para un servicio Python que requiere `psycopg2` compilado contra bibliotecas nativas, ¿elegirías `alpine`, `python:3.13-slim`, o `gcr.io/distroless/python3-debian12`? Defendé la elección tanto por superficie como por confiabilidad del build.

---

## Ejercicio 7 — Probar que los secretos de build sobreviven al borrado de capas

Esta es la demostración de mayor valor de este tema. Minimizar una imagen no vale nada si una capa borrada igual envía una credencial.

1. Construí una imagen que copia un secreto, lo usa, y después lo borra.

```bash
echo 'REGISTRY_TOKEN=dckr_pat_9f3b1c2e7a5d4088' > secrets.env

cat > Dockerfile.leaky <<'EOF'
FROM debian:12-slim
COPY secrets.env /tmp/secrets.env
RUN . /tmp/secrets.env && echo "using token ${REGISTRY_TOKEN:0:9}..." \
 && rm -f /tmp/secrets.env
COPY --from=cks41/app:fat /usr/local/bin/app /app
ENTRYPOINT ["/app"]
EOF

sed -i '/^.dockerignore$/d' .dockerignore 2>/dev/null || true
docker build -f Dockerfile.leaky -t cks41/app:leaky .
```

2. Confirmá que el archivo realmente desapareció del sistema de archivos en ejecución.

```bash
docker run --rm cks41/app:leaky ls -l /tmp/secrets.env; echo "exit=$?"
```

```
ls: cannot access '/tmp/secrets.env': No such file or directory
exit=2
```

3. Ahora leé las capas directamente. Esto funciona sin importar si Docker escribió un archivo con layout legacy u OCI.

```bash
rm -rf /tmp/leaky && mkdir -p /tmp/leaky
docker save cks41/app:leaky | tar -x -C /tmp/leaky

find /tmp/leaky -type f | while read -r f; do
  if tar -tf "$f" >/dev/null 2>&1; then
    if tar -tf "$f" 2>/dev/null | grep -q 'tmp/secrets.env'; then
      echo "SECRET PRESENT IN LAYER: $f"
      tar -xOf "$f" tmp/secrets.env
    fi
  fi
done
```

```
SECRET PRESENT IN LAYER: /tmp/leaky/blobs/sha256/4c1d0ea9b3f7...
REGISTRY_TOKEN=dckr_pat_9f3b1c2e7a5d4088
```

4. Contrastá solo con metadatos — a menudo suficiente para detectar el problema en una revisión de código.

```bash
docker history --no-trunc cks41/app:leaky | grep -i secrets
trivy image --scanners secret cks41/app:leaky
```

5. Corregilo correctamente con un montaje de secreto de BuildKit, que nunca se materializa en ninguna capa.

```bash
cat > Dockerfile.sealed <<'EOF'
# syntax=docker/dockerfile:1.7
FROM debian:12-slim
RUN --mount=type=secret,id=regtoken,target=/run/secrets/regtoken \
    . /run/secrets/regtoken && echo "using token ${REGISTRY_TOKEN:0:9}..."
COPY --from=cks41/app:fat /usr/local/bin/app /app
ENTRYPOINT ["/app"]
EOF

docker build -f Dockerfile.sealed --secret id=regtoken,src=secrets.env -t cks41/app:sealed .

rm -rf /tmp/sealed && mkdir -p /tmp/sealed
docker save cks41/app:sealed | tar -x -C /tmp/sealed
find /tmp/sealed -type f -exec sh -c 'tar -tf "$1" 2>/dev/null | grep -H "secrets" ' _ {} \; ; echo "scan complete"
trivy image --scanners secret cks41/app:sealed
```

6. Limpiá el material del secreto local.

```bash
rm -f secrets.env
```

**Preguntas — bloque 7**

- **Q7.1** El paso 2 muestra que el archivo está ausente en runtime; el paso 3 recupera el token en texto plano. Reconciliá esos dos hechos en términos de cómo se ensambla el sistema de archivos raíz de un contenedor.
- **Q7.2** ¿Habría sido `ARG REGISTRY_TOKEN` + `--build-arg` más seguro que `COPY`? Mostrá el comando que lo refutaría.
- **Q7.3** `--mount=type=secret` coloca el archivo en `/run/secrets/regtoken` solo durante ese `RUN`. ¿Dónde vive físicamente el dato durante el build, y por qué no se convierte en una capa?
- **Q7.4** La línea `# syntax=docker/dockerfile:1.7` es obligatoria para algunos builders. ¿Qué hace realmente esa directiva, y cuál es el mensaje de falla si falta en un frontend más viejo?
- **Q7.5** El token se filtró, después la imagen se subió a un registry y más tarde se borró. ¿Rotar el token es opcional? Justificá con referencia a cómo los registries y los cachés de CI retienen blobs.

---

## Ejercicio 8 — Consecuencias en el clúster: ejecutar, depurar y fijar imágenes mínimas

Una imagen mínima cambia cómo operás la carga de trabajo. Practicá el ciclo completo en un clúster vivo.

1. Cargá las imágenes en tu clúster (se muestra kind; para k3s usá `k3s ctr images import`).

```bash
kind load docker-image cks41/app:distroless cks41/app:fat --name kind 2>/dev/null \
  || echo "adjust for your cluster runtime"
```

2. Desplegá la imagen distroless con una especificación de Pod endurecida.

```bash
cat > pod-distroless.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: app-distroless
  labels:
    app: minimal
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    fsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: cks41/app:distroless
      imagePullPolicy: IfNotPresent
      ports:
        - name: http
          containerPort: 8080
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        privileged: false
        capabilities:
          drop: ["ALL"]
      resources:
        requests:
          cpu: 25m
          memory: 32Mi
        limits:
          cpu: 200m
          memory: 128Mi
      livenessProbe:
        httpGet:
          path: /healthz
          port: http
        initialDelaySeconds: 2
        periodSeconds: 10
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir:
        medium: Memory
        sizeLimit: 16Mi
EOF

kubectl apply -f pod-distroless.yaml
kubectl wait --for=condition=Ready pod/app-distroless --timeout=60s
```

3. Intentá hacer exec dentro de él — y mirá el error exacto que el examen espera que reconozcas.

```bash
kubectl exec -it app-distroless -- sh
```

```
error: Internal error occurred: error executing command in container:
failed to exec in container: failed to start exec "…":
OCI runtime exec failed: exec failed: unable to start container process:
exec: "sh": executable file not found in $PATH: unknown
```

4. Depuralo de la manera soportada: un **contenedor efímero** compartiendo el espacio de nombres de procesos del objetivo.

```bash
kubectl debug -it app-distroless \
  --image=busybox:1.37 \
  --target=app \
  --profile=general \
  -- sh
```

Dentro del contenedor efímero:

```sh
ps -ef
ls -l /proc/1/root/app
cat /proc/1/root/etc/passwd
wget -qO- http://localhost:8080/whoami
exit
```

```
PID   USER     TIME  COMMAND
    1 65532     0:00 /app
   22 root      0:00 sh
host=app-distroless uid=65532 gid=65532
```

5. Verificá que el endurecimiento tuvo efecto realmente.

```bash
kubectl get pod app-distroless -o jsonpath='{.spec.containers[0].securityContext}' | jq
kubectl debug -q -it app-distroless --image=busybox:1.37 --target=app -- \
  sh -c 'touch /proc/1/root/newfile 2>&1'
```

6. Demostrá qué pasa cuando una imagen mínima **sin `:nonroot`** se encuentra con `runAsNonRoot: true` sin `runAsUser`.

```bash
cat > pod-badroot.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: app-badroot
spec:
  securityContext:
    runAsNonRoot: true
  containers:
    - name: app
      image: cks41/app:scratch-naive
      imagePullPolicy: IfNotPresent
EOF

kubectl apply -f pod-badroot.yaml
kubectl get pod app-badroot
kubectl describe pod app-badroot | grep -A3 -i 'reason\|message'
```

```
NAME          READY   STATUS                       RESTARTS   AGE
app-badroot   0/1     CreateContainerConfigError   0          6s

  Reason:  CreateContainerConfigError
  Message: container has runAsNonRoot and image will run as root
```

7. Fijá por digest en lugar de por tag, para que la superficie que auditaste sea la superficie que ejecutás.

```bash
crane digest gcr.io/distroless/static-debian12:nonroot
```

```
sha256:6ec5aa99dc335666e79dc64e4a6c8b89c33a543a1967f20d360922a80dd21f02
```

```bash
cat > Dockerfile.pinned <<'EOF'
FROM golang:1.24-bookworm@sha256:1c04c2a9b3f0ee2b5c8f6f2c6a5b9c9d7e1f4a3b8c2d5e9f0a1b2c3d4e5f6a7b AS builder
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/app ./...

FROM gcr.io/distroless/static-debian12@sha256:6ec5aa99dc335666e79dc64e4a6c8b89c33a543a1967f20d360922a80dd21f02
COPY --from=builder /out/app /app
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/app"]
EOF
```

8. Limpiá.

```bash
kubectl delete pod app-distroless app-badroot --ignore-not-found
```

**Preguntas — bloque 8**

- **Q8.1** `kubectl exec -- sh` falló, pero `kubectl debug --target=app` te dio una shell que podía leer `/proc/1/root/app`. Explicá el mecanismo, y decí qué compartición de espacio de nombres hace que `/proc/1/root` sea alcanzable.
- **Q8.2** El Pod fija `readOnlyRootFilesystem: true` y monta un `emptyDir` en `/tmp`. ¿Por qué ese montaje es necesario *incluso para una imagen distroless*, y qué cambia `medium: Memory` respecto de la postura de seguridad?
- **Q8.3** En el paso 6 el kubelet rechazó el Pod con `container has runAsNonRoot and image will run as root`. ¿En qué punto del ciclo de vida del Pod se realiza esa verificación, y por qué no puede hacerla el API server?
- **Q8.4** `imagePullPolicy: IfNotPresent` combinado con un tag mutable crea un riesgo específico de cadena de suministro. Describí el ataque, y explicá cómo lo cierra el fijado por digest.
- **Q8.5** Los contenedores efímeros le dan a un operador un kit BusyBox completo dentro de los espacios de nombres de tu Pod. ¿Cuál es el verbo RBAC que controla esto, y por qué otorgarlo ampliamente deshace buena parte del beneficio de una imagen sin shell?

---

## Ejercicio 9 — Consolidación: auditar un Dockerfile desconocido contra la checklist

1. Recibís este Dockerfile en un pull request. Guardalo e identificá cada defecto de superficie y de endurecimiento antes de leer las respuestas.

```dockerfile
FROM python:3.13
WORKDIR /app
ADD https://internal.example.com/app.tar.gz /app/
COPY . /app
COPY id_rsa /root/.ssh/id_rsa
RUN pip install --upgrade pip
RUN pip install -r requirements.txt
RUN apt-get update && apt-get install -y curl vim netcat-openbsd
RUN rm /root/.ssh/id_rsa
ENV DB_PASSWORD=supersecret123
EXPOSE 8000
CMD python /app/server.py
```

2. Escribí tu versión corregida, después compará contra la referencia en las respuestas.

3. Verificá tu reescritura mecánicamente:

```bash
docker build -f Dockerfile.fixed -t cks41/py:fixed .
docker images cks41/py:fixed --format '{{.Size}}'
trivy image --scanners vuln,secret,misconfig cks41/py:fixed
trivy config Dockerfile.fixed
syft -q -o json cks41/py:fixed | jq '.artifacts | length'
docker run --rm cks41/py:fixed sh -c 'id' 2>&1 | head -1
```

**Preguntas — bloque 9**

- **Q9.1** Listá cada defecto del Dockerfile original, clasificado como *superficie*, *exposición de secretos*, o *endurecimiento en runtime*.
- **Q9.2** `ADD https://...` versus `RUN curl -fsSL ... | tar xz` versus `COPY`. ¿Cuál es correcto acá y por qué `ADD` desde una URL no pasa una revisión de seguridad?
- **Q9.3** `ENV DB_PASSWORD=supersecret123` — mostrá el único comando que ejecuta un atacante con solo acceso de lectura al registry para extraerlo.
- **Q9.4** `CMD python /app/server.py` usa la forma shell. Nombrá los dos problemas operativos que esto causa en Kubernetes, independientemente del tamaño de la imagen.
- **Q9.5** Después de tu reescritura, `trivy image` sigue reportando CVEs HIGH en wheels de Python. ¿Hacia cuál de las cuatro competencias de cadena de suministro de CKS te empuja eso, y cuál es la acción concreta siguiente?

---

<details>
<summary><strong>Respuestas — clic para expandir</strong></summary>

### Bloque 1 — Línea base

**A1.1** La imagen `golang:1.24` es un userland Debian bookworm completo más todo el toolchain de Go: `gc`, el ensamblador y el linker, las fuentes de la biblioteca estándar, `gofmt`, `go vet`, la caché de módulos, más GCC/binutils traídos por el linaje `buildpack-deps` sobre el que está construido `golang`. Un programa Go compilado con `CGO_ENABLED=0` está enlazado estáticamente — en runtime necesita la interfaz de llamadas al sistema del kernel Linux y literalmente nada más del userland. Así que ~99% de la imagen es material exclusivo de tiempo de compilación que no obstante va a ser descargado a cada nodo, almacenado en el disco de cada nodo, escaneado por cada escáner, y puesto a disposición de cualquiera que logre ejecución de código en el contenedor.

**A1.2** La forma exec `CMD ["app"]` no lanza una shell, pero el runtime de contenedores (`runc`) igual realiza la resolución de `$PATH` mediante una búsqueda estilo `execvp(3)` cuando el comando no es una ruta absoluta. `app` fue escrito en `/usr/local/bin`, que está en el `PATH` por defecto heredado de la configuración de la imagen. Esta es una trampa de portabilidad: funciona acá por accidente del `PATH` de la imagen base, y se rompe apenas te movés a `scratch` donde el `PATH` puede estar vacío. Usá siempre una ruta absoluta en la forma exec.

**A1.3** La shell y el gestor de paquetes son peores. Los 4 CVEs CRITICAL pueden estar en paquetes que el proceso nunca carga (`perl`, `git`, el propio `apt`) y por lo tanto pueden ser inalcanzables. `/bin/sh`, `apt`, `curl` y `wget`, en cambio, son *incondicionalmente* útiles para un atacante que consiguió aunque sea una primitiva de ejecución de código restringida: convierten una primitiva limitada en acceso interactivo, permiten preparar una carga útil de segunda etapa desde la red, permiten instalar herramientas (`nmap`, `kubectl`), y permiten guionar el movimiento lateral contra la API de Kubernetes usando el token de ServiceAccount montado. La cantidad de CVEs es una métrica indirecta; los binarios removidos son un control duro.

**A1.4** La imagen no cambió — un digest de imagen es inmutable por construcción (es el SHA-256 del manifiesto, que se compromete con la configuración y con cada digest de capa). Lo que cambió es la base de datos de vulnerabilidades: se publicaron CVEs nuevos contra paquetes que ya estaban presentes. Por eso "escaneada limpia en tiempo de build" no es una afirmación duradera, por eso reescaneás digests desplegados de forma programada, y por eso menos paquetes significa menos CVEs futuros, no solo menos CVEs actuales.

**A1.5** `-xdev` impide que `find` descienda a otros sistemas de archivos. En una imagen inspeccionada vía `docker run` ya tenés `/proc`, `/sys` y `/dev` montados por el runtime; sin `-xdev` los recorrés, produciendo ruido y errores. Si escanearas un contenedor *en ejecución* sin `-xdev` recorrerías además cada volumen `emptyDir`, `configMap`, `secret` y `projected` montado — y si bien eso es ruidoso, es también donde encontrarías un binario setuid que llegó por un `hostPath` montado, que `-xdev` ocultaría. Entonces: usá `-xdev` para inventario de imágenes, y quitalo deliberadamente (con filtros `-mount`/`-fstype`) cuando cazás binarios inyectados en runtime.

### Bloque 2 — Higiene de capas

**A2.1** Las imágenes de contenedor son pilas de capas de solo lectura unidas por un sistema de archivos overlay (`overlayfs` en los runtimes modernos). Borrar un archivo en la capa *N* no puede modificar la capa *N-1*, que ya está sellada y direccionada por contenido. En cambio el build registra una **entrada whiteout** — en el formato tar de OCI, un archivo de cero bytes llamado `.wh.<filename>` (o `.wh..wh..opq` para un directorio opaco) — en la capa *N*. El driver overlay lee ese marcador y oculta el archivo subyacente de la vista fusionada. Los bytes originales permanecen en el blob de la capa *N-1*, que se sube al registry, se descarga a cada nodo, y es extraíble por cualquiera con `docker save`, `crane export`, o acceso de lectura al registry. `docker history` muestra `0B` porque el *delta* de esa capa son solo los marcadores whiteout.

**A2.2** Aproximadamente 70–90 MB en este ejemplo. `--no-install-recommends` excluye los paquetes listados en el campo `Recommends:` del archivo de control de Debian — paquetes que son "muy deseables pero no requeridos", lo que en la práctica significa documentación, datos de locale, editores, `dbus`, y con frecuencia toolchains secundarios enteros. Consecuencia de seguridad: los paquetes recomendados instalan binarios que nunca auditaste, nunca pensaste enviar, y no podés enumerar desde tu manifiesto de dependencias. Instalar `curl` en Debian sin el flag puede traer `libssh`, `libldap`, `libpsl` y sus CVEs transitivos; instalar cualquier cosa que recomiende `perl-modules` agrega miles de scripts. Cada uno de ellos es una dependencia no revisada en tu SBOM y un candidato para el próximo CVE.

**A2.3** Perdés granularidad de caché de build. Con un `RUN` monolítico, cambiar cualquier parte invalida la capa entera, así que agregar un paquete de una línea vuelve a descargar y reconstruir todo. El compromiso es equivocado cuando la capa es cara y cambia poco — por ejemplo un `pip install` de 4 minutos de wheels científicos. La resolución correcta no es "dividir en muchas capas" sino **ordenar las instrucciones de menos a más frecuentemente cambiante**, y usar cache mounts de BuildKit (`RUN --mount=type=cache,target=/root/.cache/pip`) que te dan reutilización de caché *sin* que los bytes entren a la imagen.

**A2.4** No. `.dockerignore` controla qué se sube al **contexto de build** (lo que `COPY .` puede ver); no hace nada respecto de material leído por otros medios. La credencial seguía en el disco del desarrollador y seguiría presente si el Dockerfile ejecutara `RUN git clone` con un token, o si un paso `RUN --network` la trajera. Para un build que genuinamente necesita un secreto, el mecanismo correcto es `RUN --mount=type=secret,id=…` de BuildKit (Ejercicio 7), o `--mount=type=ssh` para reenvío de agente SSH — ambos exponen el material a exactamente un paso `RUN` vía un tmpfs, y ninguno produce una capa.

**A2.5** Primero, `--squash` es una funcionalidad legacy del builder clásico, deprecada e indisponible en el builder BuildKit por defecto; depender de ella hace que el pipeline no sea portable. Segundo y más fundamental, aplanar es una *limpieza posterior a un build que ya manejó el secreto de forma equivocada* — colapsa capas pero el secreto igual fue escrito a la caché de build, puede seguir existiendo en imágenes intermedias retenidas por el builder, y ahora se sabe que la credencial existió en un entorno de build que no controlás de punta a punta. Las respuestas correctas son builds multi-stage (el secreto nunca llega a la etapa final) y montajes de secretos (el secreto nunca llega a ninguna capa). Aplanar además destruye la compartición de capas entre imágenes, aumentando el almacenamiento total en el registry y en los nodos.

### Bloque 3 — Multi-stage

**A3.1** Eliminadas por completo: las vulnerabilidades en componentes **exclusivos de tiempo de compilación** — el toolchain de Go, GCC, `git`, `make`, `binutils`, dependencias de módulos del build, y el linaje `buildpack-deps`. Sin tocar en absoluto: las vulnerabilidades en los **paquetes restantes de la distro de runtime** (glibc, zlib, OpenSSL, `coreutils`, `bash`, `libssl`) y en las **dependencias propias compiladas dentro de la aplicación**, que Trivy detecta parseando los metadatos de build de Go embebidos en el binario (tipo de resultado `gobinary`). Multi-stage es ortogonal a la elección de imagen base; necesitás ambas cosas.

**A3.2** Con `CGO_ENABLED=0`, el compilador de Go no enlaza contra la biblioteca C del sistema y sustituye implementaciones en Go puro para los paquetes que de otro modo llamarían a libc — principalmente `net` (resolución DNS) y `os/user`. El resultado es un ELF completamente estático sin encabezado de programa `PT_INTERP` y sin entradas `DT_NEEDED`, lo que significa que el kernel lo carga y ejecuta directamente sin invocar un cargador dinámico. Ese es el prerrequisito para `scratch`: `scratch` no contiene `/lib64/ld-linux-x86-64.so.2` ni `libc.so.6`, así que un binario enlazado dinámicamente no puede arrancar en absoluto (ver A5.1).

**A3.3** `-s` elimina la tabla de símbolos, `-w` omite la información de depuración DWARF. Capacidad perdida: trazas de pila significativas desde un core dump y la posibilidad de adjuntar `delve`/`gdb` con resolución de símbolos — la depuración post-mortem se vuelve materialmente más difícil, así que conservá artefactos sin strippear en tu archivo de builds. Ganado: el binario se achica 25–35%, y dejás de enviar nombres de funciones, rutas de archivos fuente y layouts de estructuras que hacen significativamente más barata la ingeniería inversa y la búsqueda de gadgets para un atacante. `-trimpath` complementa esto removiendo rutas absolutas de build (que de otro modo filtran la estructura de directorios y los nombres de usuario de CI) y mejorando la reproducibilidad del build.

**A3.4** El kubelet aplica `runAsNonRoot: true` inspeccionando el campo `User` de la configuración de la imagen. **No tiene forma de resolver un nombre de usuario a un UID**, porque hacerlo requeriría leer `/etc/passwd` desde adentro de la imagen antes de que el contenedor exista. Si la imagen declara `USER nonroot` (un nombre), el kubelet no puede determinar si eso es UID 0 y — según la versión y el runtime — o bien rechazará el Pod o bien no podrá verificar la restricción. Declarar `USER 65532:65532` numéricamente hace la verificación inequívoca y permite que `runAsNonRoot: true` pase sin tener que especificar además `runAsUser` en cada especificación de Pod.

**A3.5** Optimización de caché de capas: los manifiestos de dependencias cambian mucho menos seguido que el código fuente. Al copiar primero `go.mod` (y en un proyecto real `go.sum`, seguido de `RUN go mod download`), la capa cara de resolución de dependencias queda en caché y se reutiliza en cada cambio que sea solo de fuentes. `COPY . .` colapsa eso en una sola capa cuya clave es el hash del contexto completo, así que editar una sola línea de código invalida la descarga de dependencias en cada build. `COPY . .` además arrastra todo el contexto de build — incluido cualquier cosa que `.dockerignore` no haya logrado excluir — dentro de la etapa de build.

### Bloque 4 — Distroless

**A4.1** (i) **Brecha de cobertura:** Trivy compara metadatos de paquetes contra bases de datos de avisos. Distroless casi no lleva metadatos de paquetes, y las dependencias del binario Go solo son detectables porque Go embebe información de módulos — un binario en C, Rust o strippeado puede producir cero detecciones simplemente porque no hay nada que parsear. La ausencia de evidencia no es evidencia de ausencia. (ii) **Brecha de alcance:** un escáner de paquetes de SO no puede ver fallas de lógica, mala configuración, credenciales embebidas, valores por defecto inseguros, ni un zero-day en tu propio código — la clase entera que en realidad causa la mayoría de las brechas. Detectá el resto con `trivy image --scanners vuln,secret,misconfig`, análisis estático de los manifiestos de la carga de trabajo (`kubesec`, `kube-linter` — competencia CKS 4.4), un SBOM que generás en tiempo de build y reevaluás continuamente, y detección en runtime (Falco — dominio 6).

**A4.2** Bloqueado: la **inyección de comandos hacia una shell y la post-explotación interactiva** — inyecciones estilo `os.system()`, reverse shells con `sh -c`, `kubectl exec` para un atacante en vivo, y cualquier payload que asuma que puede invocar `curl | sh`. No bloqueado: la **ejecución de código en el proceso** — un exploit de corrupción de memoria, una cadena de gadgets de deserialización insegura, un SSRF, o un RCE a nivel Go/Java/Python que corre enteramente dentro del runtime de la aplicación. Ese atacante puede igual abrir sockets, leer el token de ServiceAccount en `/var/run/secrets/kubernetes.io/serviceaccount/token`, y hablar con el API server — todo sin una shell. Distroless eleva el costo; no elimina la clase.

**A4.3** Ambos los necesitan programas ordinarios y correctos. `ca-certificates.crt` es el almacén de confianza del sistema: sin él cualquier conexión TLS saliente — a la API de Kubernetes, a una base de datos, a un emisor OIDC — falla con `x509: certificate signed by unknown authority`. `/etc/passwd` (y `/etc/group`) proveen el mapeo UID→nombre que `os/user`, muchas bibliotecas de logging, y algunos runtimes consultan al arrancar; más importante aún, es lo que hace del usuario `nonroot` una identidad real y resoluble para que las búsquedas estilo `id` y la semántica de `fsGroup` se comporten de forma predecible. Distroless es mínima *para una aplicación en ejecución*, no vacía por el gusto de serlo — esa es precisamente la distinción respecto de `scratch`.

**A4.4** El tag simple (`:latest`, `:debug`) no declara ningún `USER`, así que el contenedor cae por defecto a UID 0. El tag `:nonroot` fija `USER 65532:65532` en la configuración de la imagen y prepopula `/etc/passwd` con esa entrada. Si usás el tag simple en un Pod con `runAsNonRoot: true` y sin `runAsUser`, el kubelet ve una imagen que va a correr como root, se niega a arrancar el contenedor, y el Pod entra en `CreateContainerConfigError` con `container has runAsNonRoot and image will run as root` — exactamente la falla reproducida en el paso 6 del Ejercicio 8. Correcciones: usar el tag `:nonroot`, o fijar `runAsUser: 65532` explícitamente en la especificación del Pod.

**A4.5** Las variantes `debug` agregan una shell BusyBox en `/busybox/sh` más un conjunto de coreutils enlazados simbólicamente. Enviar ese tag reinstaura precisamente la capacidad que removiste: un atacante con RCE en el proceso recupera `sh`, `wget`, `nc` y un kit completo de procesamiento de texto. La alternativa soportada son los **contenedores efímeros** (`kubectl debug -it <pod> --image=busybox --target=<container>`, GA desde Kubernetes 1.25): las herramientas de depuración viven en una imagen de contenedor *separada*, se adjuntan bajo demanda por un operador con RBAC explícito sobre `pods/ephemeralcontainers`, quedan registradas en la auditoría, y desaparecen cuando el Pod se reemplaza — ninguna de ellas es jamás parte de la imagen de la carga de trabajo que está en tu registry.

### Bloque 5 — scratch

**A5.1** El archivo que falta es el **cargador dinámico**, `/lib64/ld-linux-x86-64.so.2`. Un ELF enlazado dinámicamente lleva un encabezado `PT_INTERP` que nombra a su intérprete; `execve(2)` carga ese intérprete, no el binario. El kernel devuelve `ENOENT` cuando la ruta del *intérprete* no existe, y el runtime lo muestra textualmente como `no such file or directory` apuntando a `/app` — uno de los errores más engañosos del trabajo con contenedores. Confirmalo con `readelf -l /out/app | grep interpreter` en la etapa builder, o con `file /out/app` que va a decir `dynamically linked, interpreter /lib64/ld-linux-x86-64.so.2`.

**A5.2** Porque `CGO_ENABLED=0` fuerza el **resolvedor en Go puro**, que no consulta `/etc/nsswitch.conf` ni llama a `getaddrinfo(3)`; lee `/etc/resolv.conf` — y en un Pod de Kubernetes (y bajo Docker) el runtime *monta por bind* `/etc/resolv.conf` dentro del contenedor al arrancar, así que existe incluso en `scratch`. El DNS deja de funcionar si compilás con `CGO_ENABLED=1`, que hace que Go prefiera el resolvedor cgo: ese camino llama a la maquinaria NSS de glibc, que hace `dlopen()` de `libnss_dns.so.2` en runtime — un objeto compartido que está ausente en `scratch`, produciendo fallas de resolución intermitentes y dependientes del host. (También podés forzar el resolvedor puro con `GODEBUG=netdns=go`, pero compilar estático es la corrección duradera.)

**A5.3** (i) Importás la base de datos de usuarios entera de la imagen builder — decenas de cuentas de sistema (`daemon`, `bin`, `sys`, `nobody`, y lo que sea que agregó el toolchain) — reintroduciendo identidades y rutas de shell que nunca quisiste declarar, y ampliando aquello a lo que podría apuntar una escalada estilo `setuid`. (ii) Los UIDs no van a coincidir con tu especificación de Pod: el builder no tiene una entrada `65532`, así que `runAsUser: 65532` corre un UID sin mapear y las búsquedas de `os/user` fallan, mientras que cualquier UID que *sí* coincida (por ejemplo `nobody` en 65534) es uno que vos no elegiste. Fabricar un par `passwd`/`group` de dos líneas hace la identidad explícita, auditable y estable a través de actualizaciones de la imagen base.

**A5.4** Porque los 2 MB son irrelevantes y los 2 MB faltantes están haciendo trabajo real. Distroless te da: un almacén de confianza mantenido que se **actualiza con la imagen base** (en `scratch` congelaste un bundle de CAs en tiempo de build y tenés que acordarte de reconstruir cuando se desconfía de una raíz), un `/etc/passwd` real con una identidad nonroot documentada, datos de zona horaria, `/tmp` con permisos correctos, procedencia y firmas publicadas para la imagen base, y — críticamente para el cumplimiento — metadatos de paquetes de SO reconocibles para que los escáneres y las herramientas de SBOM produzcan salida significativa. `scratch` traslada todo ese mantenimiento a tu Dockerfile, donde se pudre silenciosamente. Elegí `scratch` solo para un único binario estático sin TLS, sin archivos temporales, y sin requisitos de identidad.

**A5.5** Significa que el escaneo es estructuralmente silencioso, no limpio: sin base de datos de paquetes no hay nada que el analizador de paquetes de SO pueda enumerar, así que `trivy image` no reporta resultados de SO y el requisito queda incumplido por construcción. Satisfacelo generando el SBOM **en tiempo de build en la etapa builder**, donde todavía existen los metadatos completos — pasale `syft` a la etapa builder o usá `docker buildx build --sbom=true --provenance=true` para adjuntar una atestación SPDX/CycloneDX a la imagen — después escaneá el SBOM directamente (`trivy sbom app.spdx.json`) y guardalo como una atestación firmada junto a la imagen. Este es el puente de CKS 4.1 hacia 4.2, "entendé tu cadena de suministro".

### Bloque 6 — Alpine

**A6.1** `apt-get update` descarga archivos de índice de paquetes a `/var/lib/apt/lists/` y `apt-get install` cachea los archivos `.deb` en `/var/cache/apt/archives/`; ambos persisten como archivos, así que se vuelven parte de la capa que produjo ese `RUN` y deben removerse *dentro de ese mismo `RUN`*. `apk add --no-cache` le indica a apk que traiga el índice directamente a memoria para la transacción y que nunca escriba `/var/cache/apk/` en absoluto — no hay nada que limpiar, así que ninguna capa se contamina sin importar cómo estén dispuestas las instrucciones `RUN`. (El idiom más viejo `apk add --update … && rm -rf /var/cache/apk/*` es el equivalente estilo Debian y hoy está obsoleto.)

**A6.2** El punto medio es: **BusyBox** (que provee `sh`, `wget`, `nc`, `vi`, `wget`, `ps`, `ash` y ~200 applets desde un único binario multi-llamada), **musl libc**, **apk-tools**, y **ca-certificates** con su dependencia de OpenSSL/libcrypto. Para un kit de post-explotación esto es casi todo lo necesario: BusyBox por sí solo aporta una shell, un descargador HTTP para payloads de segunda etapa, una herramienta de sockets crudos para reverse shells y escaneo de puertos, y una suite de procesamiento de texto para parsear el token de ServiceAccount y las respuestas de la API. `apk` además le permite a un atacante instalar herramientas adicionales arbitrarias si la salida a red está permitida.

**A6.3** La más conocida es el **comportamiento de resolución DNS**: el resolvedor de musl históricamente consultaba IPv4 e IPv6 en paralelo y, en versiones más viejas, no hacía fallback de una respuesta UDP truncada a TCP, y además ignora la semántica de `options ndots` de forma distinta a glibc — lo que interactúa mal con la configuración de dominios de búsqueda `ndots: 5` de Kubernetes y produjo una larga cola de incidentes de "timeouts de DNS intermitentes de 5 segundos en Alpine". Otras que vale conocer: el tamaño de pila de hilo por defecto mucho más chico de musl (~128 KB versus 8 MB de glibc), que causa desbordamientos de pila en extensiones C con hilos, y la implementación de `malloc` distinta de musl, que produce perfiles de fragmentación de memoria y rendimiento materialmente diferentes bajo cargas intensivas en asignación.

**A6.4** (i) **Base de conteo distinta.** La cobertura de avisos de Alpine en el secdb es menos completa que la de Debian; un conteo reportado más bajo puede reflejar menos avisos *rastreados* en lugar de menos *fallas*. El equipo de seguridad de Debian además rastrea y reporta problemas que otras distros arrastran silenciosamente. (ii) **Denominadores y alcanzabilidad distintos.** Alpine tiene menos paquetes, así que un total crudo compara conjuntos de software distintos, no cualidades de seguridad distintas del mismo software; y ninguno de los dos números considera si el código vulnerable es alcanzable desde tu proceso. La comparación defendible es: misma aplicación, mismo escáner, misma fecha de base de datos, contando solo `HIGH`/`CRITICAL` con `--ignore-unfixed`, y razonando sobre qué hallazgos están efectivamente cargados en runtime.

**A6.5** `python:3.13-slim` para el build, e idealmente `gcr.io/distroless/python3-debian12` para el runtime en un build multi-stage. Razonamiento: `psycopg2` (la variante no binaria) necesita `libpq` y un compilador de C. En Alpine, los wheels manylinux de PyPI no aplican (apuntan a glibc), así que **cada** wheel con código nativo compila desde el fuente — lento, frágil, y fuerza a `gcc`, `musl-dev`, `postgresql-dev` y los headers de Python dentro del build, terminando frecuentemente también en el runtime. El resultado que se cita a menudo es que una imagen "Alpine Python" termina siendo *más grande* y más lenta de construir que el equivalente Debian slim. La forma de producción es: etapa de build sobre `python:3.13-slim` con `pip install --no-cache-dir` hacia un venv o un directorio `--target`, etapa de runtime sobre distroless-python copiando solo el venv y la app — superficie chica, sin compilador, y wheels manylinux estándar en todo momento.

### Bloque 7 — Secretos de build

**A7.1** El sistema de archivos raíz del contenedor es un **overlay de capas inmutables**. `COPY secrets.env /tmp/secrets.env` selló el texto plano en la capa *N*, direccionada por contenido y subida al registry. El `rm -f` posterior se ejecutó en la capa *N+1* y solo pudo escribir un marcador whiteout (`.wh.secrets.env`) en esa capa. La vista fusionada que ve el proceso — y por lo tanto `ls` — respeta el whiteout y reporta el archivo ausente. Pero `docker save`, `crane export --platform`, `skopeo copy`, o el acceso plano a los blobs del registry leen todos las capas *individuales*, donde el texto plano está intacto. Ausencia en runtime y ausencia en las capas son propiedades completamente distintas.

**A7.2** No — `--build-arg` es estrictamente peor, porque los build args quedan registrados en el historial de la configuración de la imagen y son trivialmente legibles sin extraer ninguna capa:

```bash
docker history --no-trunc cks41/app:leaky
docker image inspect cks41/app:leaky --format '{{json .Config}}' | jq
crane config cks41/app:leaky | jq '.history[].created_by'
```

Cualquiera de estos imprime `ARG REGISTRY_TOKEN=dckr_pat_…` directamente desde los metadatos. Lo mismo aplica a `ENV` (ver A9.3), que es todavía peor porque además persiste en el entorno del contenedor en ejecución, donde cualquier proceso — o cualquier lectura de `/proc/1/environ` — puede verlo.

**A7.3** BuildKit guarda el secreto en la sesión de build, sostenida por el *cliente* (tu proceso `docker build`), y lo expone al paso `RUN` como un **montaje tmpfs** en la ruta destino. Como es un montaje y no una escritura al sistema de archivos, existe solo en el espacio de nombres de montaje de ese único paso de build y no produce ningún delta de sistema de archivos. Los contenidos de las capas se calculan como el diff de los cambios de sistema de archivos del paso, y un punto de montaje tmpfs no aporta nada a ese diff — así que no hay blob, no hay entrada de historial, no hay nada que extraer. El secreto tampoco atraviesa nunca la caché persistente del demonio de BuildKit.

**A7.4** `# syntax=docker/dockerfile:1.7` es una **directiva de parser** que le dice a BuildKit que descargue esa imagen *frontend* específica de Dockerfile desde el registry y la use para interpretar el archivo, desacoplando las funcionalidades de sintaxis de Dockerfile de la versión de Docker instalada. Sin ella (o con un frontend por defecto más viejo, o con `DOCKER_BUILDKIT=0` forzando el builder clásico) obtenés un error de parseo del tipo `Dockerfile parse error line 3: Unknown flag: mount` — el builder clásico no implementa `RUN --mount` en absoluto. Fijar el frontend además hace los builds reproducibles entre máquinas de desarrollo con versiones distintas de Docker.

**A7.5** La rotación es **obligatoria, no opcional**. Borrar un tag no borra blobs: los registries recolectan basura de forma asíncrona y a menudo solo en una corrida de mantenimiento explícita, las réplicas y los cachés pull-through conservan sus propias copias, los runners de CI conservan cachés de capas en disco, cada nodo que alguna vez bajó la imagen tiene la capa en su almacén de contenido, y cualquiera que la haya descargado en el ínterin tiene una copia permanente. Tratá cualquier credencial que haya entrado a una capa o a una configuración de imagen como completamente divulgada desde el momento del primer push: rotala, después auditá su uso, después arreglá el build. El mismo razonamiento aplica a un secreto commiteado a git y luego eliminado con un force-push.

### Bloque 8 — Consecuencias en el clúster

**A8.1** `kubectl debug --target=app` crea un **contenedor efímero** en el Pod existente, y `--target` fija `targetContainerName`, lo que hace que el runtime coloque el nuevo contenedor en el **espacio de nombres de PID** del contenedor objetivo. Compartir el espacio de nombres de PID significa que el contenedor efímero ve a la aplicación como PID 1, y Linux expone la raíz del espacio de nombres de montaje de cada proceso a través de `/proc/<pid>/root` — así que `/proc/1/root/app` es una vista en vivo del sistema de archivos del contenedor distroless, legible con herramientas BusyBox que nunca se enviaron en la imagen de la carga de trabajo. El contenedor efímero además comparte por defecto el espacio de nombres de red del Pod, que es por lo que `wget http://localhost:8080/whoami` alcanza a la app.

**A8.2** `readOnlyRootFilesystem: true` hace que el overlay fusionado del contenedor sea de solo lectura, así que *cualquier* escritura falla — incluidas las que el runtime de Go y la biblioteca estándar hacen sin preguntar (`os.CreateTemp`, `httputil.ReverseProxy` volcando cuerpos grandes a disco, material de sesión TLS en algunas bibliotecas, volcados de fallos). Ser distroless no cambia eso: la imagen es chica, pero el programa igual espera un `/tmp` escribible. Montar un `emptyDir` ahí da una ruta escribible con un ciclo de vida acotado ligado al Pod. `medium: Memory` lo respalda con tmpfs, así que los contenidos nunca tocan el disco del nodo (nada que recuperar forensemente de un nodo dado de baja, y sin persistencia entre reinicios) y, combinado con `sizeLimit: 16Mi`, queda acotado — de lo contrario un `emptyDir` tmpfs se carga contra la memoria del Pod y uno sin límite puede provocar presión de memoria en el nodo.

**A8.3** La verificación la realiza el **kubelet**, inmediatamente antes de la creación del contenedor, en el camino de `CreateContainer` — que es por lo que la falla aparece como `CreateContainerConfigError` en un Pod ya planificado en lugar de como un `POST` rechazado. El API server no puede hacerla porque determinar el UID efectivo requiere leer la **configuración de la imagen**, y solo el nodo tiene (o puede obtener) la imagen: debe descargarla de un registry que puede requerir credenciales de alcance de nodo, puede ser un espejo privado inalcanzable desde el plano de control, y el tag puede resolver a un digest distinto en el momento de la descarga. El API server valida la *especificación*; solo el kubelet puede validar la *especificación contra la imagen*. Si querés que esto se rechace en tiempo de admisión, eso es asunto de Pod Security Admission (perfil `restricted`) o de un motor de políticas (Kyverno/Gatekeeper) operando sobre los campos de la especificación, no sobre la imagen.

**A8.4** Con un tag mutable e `IfNotPresent`, el digest que un nodo ejecuta es el que le tocó cachear primero. Un atacante (o un job de CI comprometido) que pueda hacer push al registry sobrescribe `:v1.2` con una imagen maliciosa; los nodos que ya cachearon el tag siguen ejecutando la vieja mientras los nodos recién planificados descargan la maliciosa — así que la flota ejecuta una mezcla, tus resultados de escaneo describen una imagen que nadie está ejecutando, y revertir por tag no restaura un estado conocido. `imagePullPolicy: Always` estrecha pero no cierra el problema (el tag sigue apuntando a donde el atacante apuntó). Referenciar `image: repo/app@sha256:…` hace la referencia **direccionada por contenido**: el kubelet verifica que el manifiesto descargado hashea a ese digest, así que el nodo o bien ejecuta exactamente los bytes que auditaste o bien no arranca. Este es además el prerrequisito para la verificación de firmas (CKS 4.3).

**A8.5** El verbo es `create` sobre el subrecurso `pods/ephemeralcontainers` — por ejemplo `kubectl auth can-i create pods/ephemeralcontainers`. Otorgarlo ampliamente le entrega a cualquier portador una shell con imagen arbitraria dentro de los espacios de nombres de PID, red y (con `--profile=sysadmin` o un `securityContext` permisivo) IPC de tu Pod, con acceso a los Secrets montados del objetivo, al token de ServiceAccount y al sistema de archivos a través de `/proc/1/root`. Eso es un bypass casi completo de la imagen sin shell: quitaste la shell del artefacto pero dejaste una API para adjuntar una. Tratalo como un permiso de emergencia — acotalo a un namespace, ligalo a un rol de operaciones en lugar de a desarrolladores o a service accounts, asegurate de que la política de auditoría lo registre a nivel `RequestResponse`, y combinalo con una política de admisión que restrinja qué imágenes de depuración pueden usarse.

### Bloque 9 — Auditoría de consolidación

**A9.1**

*Superficie:*
1. `FROM python:3.13` — la imagen completa basada en Debian (~1,0 GB) en lugar de `-slim` (~130 MB) o un runtime distroless; envía el toolchain de C completo desde `buildpack-deps`.
2. Sin build multi-stage — las dependencias de compilación y el runtime de la app son la misma imagen.
3. `RUN apt-get install -y curl vim netcat-openbsd` — `vim` y `netcat` no tienen ningún propósito en runtime; `netcat` es una herramienta de post-explotación de manual. Además falta `--no-install-recommends` y falta `rm -rf /var/lib/apt/lists/*` en la misma capa.
4. Cuatro instrucciones `RUN` separadas donde dos alcanzarían, cada una agregando una capa.
5. `pip install` sin `--no-cache-dir` deja la caché de wheels en `~/.cache/pip` dentro de la imagen.
6. `COPY . /app` sin `.dockerignore` — arrastra `.git`, `.env`, virtualenvs, fixtures de test y configuración de CI dentro de la imagen.
7. `RUN pip install --upgrade pip` como capa propia duplica pip.

*Exposición de secretos:*
8. `COPY id_rsa /root/.ssh/id_rsa` — clave privada sellada en una capa; el `rm` posterior solo escribe un whiteout (Ejercicio 7). La clave debe rotarse.
9. `ENV DB_PASSWORD=supersecret123` — texto plano en la configuración de la imagen, visible vía `docker inspect`/`crane config` y en el entorno de cada contenedor.
10. `COPY . /app` puede llevar `.env`, `.git/credentials`, `*.pem`.
11. `ADD https://internal.example.com/app.tar.gz` — descarga remota sin fijar ni verificar (ver A9.2).

*Endurecimiento en runtime:*
12. Sin `USER` — corre como root, incompatible con `runAsNonRoot: true`.
13. `CMD python /app/server.py` en forma shell (ver A9.4).
14. Sin digest de imagen base fijado; `python:3.13` es un tag mutable.
15. `requirements.txt` sin versiones fijadas ni hashes (sin `--require-hashes`), así que los builds no son reproducibles y son vulnerables a confusión de dependencias y typosquatting.
16. `WORKDIR /app` seguido de `COPY . /app` con propiedad de root, cuando el proceso debería correr sin privilegios y el sistema de archivos raíz debería ser de solo lectura.

**A9.2** `COPY` es correcto para artefactos de build locales; para un tarball remoto, traelo en una **etapa builder** con una verificación de integridad explícita. `ADD <url>` no pasa la revisión porque: realiza una descarga no autenticada en tiempo de build sin verificación de checksum ni de firma, así que el contenido es lo que sea que el servidor devolvió ese día (sin reproducibilidad, y un `internal.example.com` comprometido o suplantado inyecta código directamente en tu imagen); antes del flag `--checksum` más reciente de BuildKit no había forma alguna de fijarlo; crea una capa que contiene el archivo comprimido; y extrae automáticamente en silencio los archivos comprimidos locales, lo que sorprende a los revisores. Las formas defendibles son `ADD --checksum=sha256:<digest> <url> /tmp/` en una etapa builder, o `RUN curl -fsSL <url> -o /tmp/app.tar.gz && echo "<sha256>  /tmp/app.tar.gz" | sha256sum -c - && tar -xzf …` — con el resultado extraído traído con `COPY --from=builder` a una etapa de runtime limpia.

**A9.3** Un solo comando contra el registry, sin necesidad de descargar capas:

```bash
crane config internal.example.com/app:latest | jq '.config.Env'
```

o equivalentemente `docker inspect --format '{{json .Config.Env}}' <image>` después de descargarla, o `skopeo inspect --config docker://<image>`. Los valores de `ENV` viven en el **blob de configuración** de la imagen, que es un documento JSON chico que se trae antes de cualquier capa — así que la contraseña está disponible para cualquiera con acceso de lectura al repositorio, y además está presente en `/proc/<pid>/environ` para cada proceso del contenedor. La configuración que varía por entorno pertenece a un `Secret` de Kubernetes montado como archivo (o inyectado por un operador de secretos externo), nunca horneada dentro de la imagen.

**A9.4** (i) **Manejo de señales.** La forma shell ejecuta `/bin/sh -c "python /app/server.py"`, haciendo que `sh` sea PID 1. Según la shell puede no reenviar `SIGTERM` al proceso Python, así que al borrar el Pod la aplicación nunca recibe la señal de terminación, ignora la lógica de `preStop`/apagado ordenado, y recibe `SIGKILL` después de `terminationGracePeriodSeconds` — produciendo conexiones cortadas en cada actualización progresiva. (ii) **Semántica de sobrescritura de `args`.** Con la forma shell, el `args:` de una especificación de Pod no puede agregar argumentos como lo hace con la forma exec — `command`/`args` de Kubernetes mapean sobre `ENTRYPOINT`/`CMD`, y el envoltorio de forma shell hace el mapeo no obvio, así que las sobrescrituras hacen silenciosamente lo incorrecto. Un tercero: el proceso `sh` extra rompe la recolección de zombis de PID 1 y confunde a la lógica de liveness basada en `ps`. Usá `ENTRYPOINT ["python", "/app/server.py"]` (forma exec, rutas absolutas) — y sobre una imagen base sin shell la forma shell falla directamente (Ejercicio 5, paso 3).

**A9.5** Te empuja hacia **4.2 "Entendé tu cadena de suministro"** y **4.4 "Realizá análisis estático de cargas de trabajo de usuario e imágenes de contenedor"** — la minimización de la superficie alcanzó su límite, porque las vulnerabilidades restantes están en código del que dependés deliberadamente, no en paquetes incidentales de la imagen base. Acciones concretas siguientes: generar y almacenar un SBOM por build (`syft` / `docker buildx --sbom=true`) para poder responder "dónde está desplegado este paquete" sin reconstruir; fijar dependencias por hash (`pip-compile --generate-hashes`, después `pip install --require-hashes`) para que el conjunto resuelto sea reproducible y auditable; condicionar el pipeline con `trivy image --exit-code 1 --severity HIGH,CRITICAL --ignore-unfixed` para que los hallazgos sin corrección disponible no bloqueen mientras que los corregibles sí; correr `trivy config` / `kube-linter` / `kubesec` contra el Dockerfile y los manifiestos; y alimentar el riesgo aceptado restante hacia controles de runtime (seccomp `RuntimeDefault`, capacidades descartadas, restricciones de egreso con NetworkPolicy) para que una dependencia explotada igual no pueda alcanzar nada útil.

</details>

---

## Checklist para el día del examen de esta competencia

| Señal que ves | Qué significa | Acción |
|---|---|---|
| `exec: "sh": executable file not found` | Distroless/scratch, sin shell | Usar `kubectl debug --target=<c>`, no `kubectl exec` |
| `exec /app: no such file or directory` (el archivo existe) | Binario enlazado dinámicamente sobre `scratch` | Recompilar con `CGO_ENABLED=0`, o usar distroless-base |
| `x509: certificate signed by unknown authority` | Sin bundle de CAs | `COPY --from=builder /etc/ssl/certs/ca-certificates.crt …` |
| `CreateContainerConfigError` + `image will run as root` | `runAsNonRoot: true` sin `USER`/`runAsUser` numérico | Usar el tag `:nonroot` o fijar `runAsUser: 65532` |
| `exec: "/bin/sh": stat …: no such file` | `CMD`/`ENTRYPOINT` en forma shell sobre una base sin shell | Convertir a forma exec JSON con rutas absolutas |
| `read-only file system` en `/tmp` | `readOnlyRootFilesystem: true` | Montar `emptyDir` (`medium: Memory`, con `sizeLimit`) |
| Secreto en `docker history` o `crane config` | `ARG`/`ENV`/`COPY` de una credencial | Rotar la credencial, después migrar a `RUN --mount=type=secret` |

## Fuentes

- CNCF, *Certified Kubernetes Security Specialist (CKS) Curriculum v1.34* — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubernetes, *Configure a Security Context for a Pod or Container* — https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- Kubernetes, *Debug Running Pods (Ephemeral Containers)* — https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Kubernetes, *Images — image pull policy and digests* — https://kubernetes.io/docs/concepts/containers/images/
- Kubernetes, *Pod Security Standards* — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Docker, *Dockerfile reference* — https://docs.docker.com/reference/dockerfile/
- Docker, *Multi-stage builds* — https://docs.docker.com/build/building/multi-stage/
- Docker, *Build secrets* — https://docs.docker.com/build/building/secrets/
- Docker, *Build context and `.dockerignore`* — https://docs.docker.com/build/concepts/context/
- GoogleContainerTools, *distroless — language-focused Docker images, minus the operating system* — https://github.com/GoogleContainerTools/distroless
- Open Container Initiative, *Image Layer Filesystem Changeset (whiteouts)* — https://github.com/opencontainers/image-spec/blob/main/layer.md
- Aqua Security, *Trivy documentation* — https://trivy.dev/latest/docs/
- Anchore, *Syft — SBOM generation* — https://github.com/anchore/syft
- Alpine Linux, *Package management with apk* — https://wiki.alpinelinux.org/wiki/Alpine_Package_Keeper
- Go, *cgo and build modes* — https://pkg.go.dev/cmd/cgo and https://pkg.go.dev/net#hdr-Name_Resolution