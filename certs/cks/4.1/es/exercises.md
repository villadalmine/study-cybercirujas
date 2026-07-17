# CKS 4.1 — Minimize base image footprint

**Peso en el examen:** 5
**Fuente de referencia:** [CKS Curriculum v1.34 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf)

Requisitos previos: acceso a un daemon de Docker (o `nerdctl`/`buildah` equivalente) y un cluster de Kubernetes (`kind` o `minikube` alcanza) con `kubectl` configurado. Trabajá en un directorio vacío, por ejemplo `~/cks-4-1/`.

---

## Ejercicio 1 — Medir el problema: una imagen "gorda"

1. Creá un directorio de trabajo y una app mínima en Go:

```bash
mkdir -p ~/cks-4-1/app && cd ~/cks-4-1/app
cat <<'EOF' > main.go
package main

import (
	"fmt"
	"net/http"
)

func handler(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintln(w, "hello from CKS 4.1")
}

func main() {
	http.HandleFunc("/", handler)
	http.ListenAndServe(":8080", nil)
}
EOF
```

2. Escribí un `Dockerfile` "ingenuo", basado en `ubuntu:22.04`, que instala el toolchain de Go y compila adentro de la misma imagen final:

```bash
cat <<'EOF' > Dockerfile.bloated
FROM ubuntu:22.04
RUN apt-get update
RUN apt-get install -y golang-go curl vim sudo git
COPY main.go /app/main.go
WORKDIR /app
RUN go build -o server main.go
CMD ["./server"]
EOF
```

3. Construí la imagen y medí su tamaño:

```bash
docker build -t demo:bloated -f Dockerfile.bloated .
docker images demo:bloated
```

<details>
<summary>Preguntas de comprensión — Ejercicio 1</summary>

**P1. ¿Por qué esta imagen es un problema desde el punto de vista de seguridad, más allá de su tamaño en disco?**
Incluye un compilador (`golang-go`), un editor (`vim`), `curl`, `git` y `sudo` en el runtime final. Cada uno de esos binarios amplía la *attack surface*: si un atacante logra RCE en la app, tiene herramientas para descargar payloads (`curl`), escalar privilegios (`sudo`) o pivotear. Además, cada paquete instalado suma su propio árbol de dependencias, y por lo tanto más CVEs potenciales a parchear.

**P2. El toolchain de Go (`golang-go`) solo se usa para compilar. ¿Debería estar en la imagen que corre en producción?**
No. Es una dependencia de *build*, no de *runtime*. Dejarla en la imagen final viola el principio de minimizar el footprint: agrega ~300-500 MB y un compilador completo que nunca se ejecuta después del `docker build`.

</details>

---

## Ejercicio 2 — Multi-stage build

4. Reescribí el `Dockerfile` separando la etapa de compilación de la etapa de runtime, y compilá un binario estático:

```bash
cat <<'EOF' > Dockerfile.multistage
FROM golang:1.22 AS builder
WORKDIR /src
COPY main.go .
RUN CGO_ENABLED=0 GOOS=linux go build -o server main.go

FROM ubuntu:22.04
COPY --from=builder /src/server /server
CMD ["/server"]
EOF
```

5. Construí la imagen y compará el tamaño contra la del Ejercicio 1:

```bash
docker build -t demo:multistage -f Dockerfile.multistage .
docker images | grep -E 'demo|REPOSITORY'
```

<details>
<summary>Preguntas de comprensión — Ejercicio 2</summary>

**P3. ¿Por qué la etapa `builder` (con `golang:1.22` completo) no infla el tamaño de la imagen final?**
En un multi-stage build, Docker construye cada `FROM` como una imagen intermedia independiente. Solo los archivos copiados explícitamente con `COPY --from=builder` pasan a la imagen final; el resto de la etapa `builder` (compilador, cache de módulos, etc.) se descarta al finalizar el build.

**P4. `demo:multistage` todavía usa `ubuntu:22.04` como base final. ¿Sigue siendo mejor que `demo:bloated`? ¿Por qué no es suficiente?**
Es mejor porque ya no tiene el compilador ni herramientas de desarrollo, pero sigue arrastrando una base image completa (shell, package manager `apt`, coreutils, glibc completo con sus propias CVEs). El objetivo de 4.1 es llegar a la base *mínima suficiente* para correr el binario, no solo mover el problema de una etapa a otra.

</details>

---

## Ejercicio 3 — Distroless: eliminar shell y package manager

6. Reemplazá la imagen final por `gcr.io/distroless/static-debian12`, que no tiene shell, package manager ni libc dinámica (sirve porque el binario es estático gracias a `CGO_ENABLED=0`):

```bash
cat <<'EOF' > Dockerfile.distroless
FROM golang:1.22 AS builder
WORKDIR /src
COPY main.go .
RUN CGO_ENABLED=0 GOOS=linux go build -o server main.go

FROM gcr.io/distroless/static-debian12
COPY --from=builder /src/server /server
USER nonroot:nonroot
ENTRYPOINT ["/server"]
EOF
```

7. Construí y comparate el tamaño final contra las dos versiones anteriores:

```bash
docker build -t demo:distroless -f Dockerfile.distroless .
docker images | grep -E 'demo|REPOSITORY'
```

8. Corré el contenedor y probá obtener una shell interactiva dentro:

```bash
docker run -d --name test-distroless -p 8080:8080 demo:distroless
docker exec -it test-distroless /bin/sh
```

<details>
<summary>Preguntas de comprensión — Ejercicio 3</summary>

**P5. El comando `docker exec -it test-distroless /bin/sh` del paso 8 falla. ¿Por qué es esto una mejora de seguridad y no un bug a "arreglar"?**
`distroless/static` no incluye ningún shell (`sh`, `bash`), ni `coreutils`, ni package manager. Un atacante que logre ejecutar código en el proceso de la app no puede abrir una shell interactiva, listar el filesystem con herramientas estándar, ni instalar tooling de post-explotación — no existen los binarios para hacerlo. Esto es exactamente el objetivo de "minimize base image footprint": cuanto menos hay en la imagen, menos hay para que un atacante abuse.

**P6. ¿Por qué el Dockerfile usa `USER nonroot:nonroot` en vez de dejar el contenedor correr como root?**
Las imágenes distroless de Google incluyen un usuario `nonroot` (UID 65532) predefinido. Correr como no-root reduce el impacto de un container breakout: si el proceso corre como root dentro del contenedor y hay una vulnerabilidad de kernel o una configuración insegura (por ejemplo `hostPID` o una capability de más), el atacante hereda privilegios de root en el host. Esto combina con el tema de PSA/`securityContext.runAsNonRoot` de otros dominios del CKS, pero acá el punto es que la imagen ya *fuerza* esa postura desde el build.

**P7. Si necesitás debuggear un pod corriendo con esta imagen en producción, ¿qué mecanismo de Kubernetes usás ya que no hay shell disponible con `kubectl exec`?**
`kubectl debug` con un *ephemeral container* (`kubectl debug -it <pod> --image=busybox --target=<container>`), que inyecta un contenedor temporal con shell en el mismo namespace de red/PID que el pod, sin modificar la imagen original.

</details>

---

## Ejercicio 4 — Alpine como alternativa (y su trade-off)

9. Repetí el build pero contra `alpine:3.20`, que sí tiene shell y `apk` pero es mucho más chica que `ubuntu`:

```bash
cat <<'EOF' > Dockerfile.alpine
FROM golang:1.22 AS builder
WORKDIR /src
COPY main.go .
RUN CGO_ENABLED=0 GOOS=linux go build -o server main.go

FROM alpine:3.20
RUN adduser -D -u 65532 nonroot
COPY --from=builder /src/server /server
USER nonroot
ENTRYPOINT ["/server"]
EOF
docker build -t demo:alpine -f Dockerfile.alpine .
docker images | grep -E 'demo|REPOSITORY'
```

<details>
<summary>Preguntas de comprensión — Ejercicio 4</summary>

**P8. `alpine` usa `musl libc` en vez de `glibc`. ¿Qué riesgo introduce esto que no aparece con `distroless/static` o `scratch`?**
Un binario compilado o linkeado esperando `glibc` puede fallar silenciosamente o comportarse distinto sobre `musl` (por ejemplo, resolución DNS o `cgo` con bibliotecas C). Si el binario es Go puro y estático (`CGO_ENABLED=0`), el riesgo es bajo, pero para lenguajes o dependencias que sí usan `cgo` es una fuente real de bugs sutiles — vale la pena probarlo, no asumirlo.

**P9. Si `alpine` sigue teniendo `apk` y `/bin/sh`, ¿por qué elegirla en vez de `distroless`?**
Trade-off entre superficie de ataque y operabilidad/debuggability. `alpine` permite `kubectl exec` directo para debug rápido y es más chica que una distro completa (~5-8 MB de base), a costa de tener shell y package manager disponibles para un atacante. `distroless` minimiza aún más el footprint pero obliga a usar ephemeral debug containers. La elección depende del apetito de riesgo del equipo, no hay una respuesta única correcta en el examen — CKS evalúa que sepas justificar la elección.

</details>

---

## Ejercicio 5 — `.dockerignore` y limpieza de cache en la misma capa

10. Simulá un contexto de build con archivos que no deberían viajar a la imagen:

```bash
cd ~/cks-4-1/app
mkdir -p .git
echo "AWS_SECRET_ACCESS_KEY=fake123" > .env
echo "some binary log" > build.log
```

11. Creá un `.dockerignore` que excluya esos archivos del contexto de build:

```bash
cat <<'EOF' > .dockerignore
.git
.env
*.log
Dockerfile*
EOF
```

12. Compará una imagen que instala paquetes con `apt-get` en capas separadas contra una que limpia el cache en el mismo `RUN`:

```bash
cat <<'EOF' > Dockerfile.dirty
FROM ubuntu:22.04
RUN apt-get update
RUN apt-get install -y curl
RUN rm -rf /var/lib/apt/lists/*
EOF

cat <<'EOF' > Dockerfile.clean
FROM ubuntu:22.04
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl && \
    rm -rf /var/lib/apt/lists/*
EOF

docker build -t demo:dirty -f Dockerfile.dirty .
docker build -t demo:clean -f Dockerfile.clean .
docker images | grep -E 'demo:(dirty|clean)'
```

<details>
<summary>Preguntas de comprensión — Ejercicio 5</summary>

**P10. ¿Por qué `demo:dirty` pesa más que `demo:clean` a pesar de que ambos terminan corriendo el mismo `rm -rf /var/lib/apt/lists/*`?**
Cada instrucción `RUN` crea una nueva capa (layer) del filesystem, y las capas son inmutables y aditivas. En `Dockerfile.dirty`, el cache de `apt` se escribe en la capa del segundo `RUN` y el `rm` ocurre en una tercera capa distinta: el archivo "borrado" sigue existiendo en la capa anterior y sigue ocupando espacio en la imagen final (que es la unión de todas las capas). En `Dockerfile.clean`, todo pasa en un único `RUN`, así que la capa resultante ya no contiene el cache.

**P11. ¿Qué riesgo de seguridad concreto previene el `.dockerignore` del paso 11, más allá de ahorrar espacio?**
Evita que secretos o metadata sensible (`.env`, `.git` con historial de commits, credenciales) terminen embebidos en una capa de la imagen. Aunque el `Dockerfile` no haga `COPY .env`, un `COPY . .` sin `.dockerignore` los incluiría en el build context y, dependiendo del Dockerfile, podrían filtrarse en una capa — y una vez en una capa, quedan ahí aunque se borren en un paso posterior (ver P10).

**P12. `--no-install-recommends` en `apt-get install`, ¿qué reduce exactamente?**
Por defecto, `apt` instala no solo el paquete pedido sino también sus dependencias "recomendadas" (no estrictamente obligatorias). `--no-install-recommends` instala únicamente las dependencias necesarias (`Depends`), lo que reduce tanto el tamaño como la cantidad de paquetes — y por lo tanto de CVEs potenciales — sin romper la funcionalidad del paquete pedido.

</details>

---

## Ejercicio 6 — Inspeccionar capas con `docker history`

13. Compará la composición de capas entre la imagen "sucia" y la limpia:

```bash
docker history demo:dirty
docker history demo:clean
```

14. (Opcional, si tenés [`dive`](https://github.com/wagoodman/dive) instalado) Inspeccioná visualmente el desperdicio de capas:

```bash
dive demo:dirty
```

<details>
<summary>Preguntas de comprensión — Ejercicio 6</summary>

**P13. En la salida de `docker history demo:dirty`, ¿qué deberías buscar para identificar el desperdicio que causó el `rm -rf` tardío?**
El tamaño (columna `SIZE`) reportado por cada capa individual. Vas a ver que la capa del `RUN apt-get install` tiene un tamaño considerable (incluye el cache de `apt`) y la capa del `RUN rm -rf ...` aparece con tamaño ~0 o muy chico — confirmando que el `rm` no liberó espacio de la imagen, solo lo "ocultó" en la vista del filesystem final montado.

**P14. Como examen práctico bajo tiempo, ¿por qué `docker history` es más rápido de usar que instalar `dive` para una primera pasada?**
`docker history` viene con el Docker CLI, no requiere instalar nada extra ni configurar tooling adicional — importante en el entorno controlado del examen CKS donde no siempre hay acceso a internet para bajar herramientas de terceros. `dive` da una vista más rica (por capa, qué archivos se agregaron/modificaron/borraron) pero es un plus, no algo para depender en el examen.

</details>

---

## Ejercicio 7 — Escanear con Trivy y correlacionar tamaño con CVEs

15. Instalá o usá [Trivy](https://github.com/aquasecurity/trivy) vía contenedor para no ensuciar el host, y escaneá las tres imágenes construidas:

```bash
for img in demo:bloated demo:multistage demo:distroless; do
  echo "== $img =="
  docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
    aquasec/trivy image --severity HIGH,CRITICAL --quiet "$img"
done
```

<details>
<summary>Preguntas de comprensión — Ejercicio 7</summary>

**P15. ¿Qué relación esperás ver entre el tamaño de la imagen y la cantidad de CVEs reportadas por Trivy, y por qué no es una relación perfecta 1:1?**
En general, a menor tamaño y menor cantidad de paquetes instalados, menos CVEs — porque el escaneo de vulnerabilidades recorre el listado de paquetes y sus versiones conocidas con CVEs publicadas. No es 1:1 porque una sola dependencia grande y vieja (por ejemplo una versión desactualizada de OpenSSL) puede aportar más CVEs críticas que decenas de paquetes chicos y actualizados. Minimizar el footprint reduce la *probabilidad* de arrastrar CVEs, no las elimina por completo — igual hay que mantener la base image actualizada.

**P16. `demo:distroless` normalmente reporta cero o casi cero CVEs de sistema operativo. ¿Significa que la imagen es 100% segura?**
No. Trivy en modo `image` escanea paquetes de SO y, si se le indica, dependencias de la app (por ejemplo `go.sum`). Una imagen distroless minimiza las CVEs del *sistema operativo base*, pero vulnerabilidades en el código de la aplicación, en sus dependencias de lenguaje, o configuraciones inseguras (RBAC, secrets en variables de entorno, etc.) siguen siendo posibles y quedan fuera del alcance de "minimize base image footprint".

</details>

---

## Ejercicio 8 — Desplegar en Kubernetes y verificar el comportamiento

16. Cargá la imagen distroless en tu cluster local (ejemplo con `kind`) y desplegala:

```bash
kind load docker-image demo:distroless
cat <<'EOF' > pod-distroless.yaml
apiVersion: v1
kind: Pod
metadata:
  name: demo-distroless
spec:
  containers:
  - name: server
    image: demo:distroless
    imagePullPolicy: Never
    ports:
    - containerPort: 8080
EOF
kubectl apply -f pod-distroless.yaml
kubectl wait --for=condition=Ready pod/demo-distroless --timeout=60s
```

17. Confirmá que el pod responde pero no ofrece shell:

```bash
kubectl exec -it demo-distroless -- /bin/sh
kubectl debug -it demo-distroless --image=busybox:1.36 --target=server -- /bin/sh
```

<details>
<summary>Preguntas de comprensión — Ejercicio 8</summary>

**P17. El paso 16 usa `imagePullPolicy: Never`. ¿Por qué es necesario acá y cuándo NO lo usarías en un cluster real?**
`kind load docker-image` carga la imagen directamente en los nodos del cluster `kind` sin pasarla por un registry; con la `imagePullPolicy` por defecto (`IfNotPresent` o `Always` según el tag), el kubelet podría intentar bajarla de un registry remoto y fallar porque `demo:distroless` no existe ahí. En un cluster real de producción, las imágenes deberían venir de un registry (idealmente con escaneo e *image signing*), así que `Never` no aplica — es un atajo válido solo para desarrollo/laboratorio local.

**P18. ¿Qué diferencia clave hay entre lo que logra `kubectl exec` (paso 17, primer comando) y lo que logra `kubectl debug` con ephemeral container (segundo comando), en términos de superficie de ataque de la imagen original?**
`kubectl exec -- /bin/sh` intenta ejecutar un binario *dentro* de la imagen `demo:distroless` — falla porque ese binario no existe ahí. `kubectl debug --image=busybox ... --target=server` crea un *ephemeral container* nuevo, basado en una imagen distinta (`busybox`) que sí trae shell, compartiendo los namespaces de proceso (y opcionalmente de red) con el contenedor `server`. La imagen de producción (`demo:distroless`) nunca se modifica ni gana un shell — el tooling de debug vive en un contenedor efímero separado, preservando el footprint mínimo del contenedor real.

</details>