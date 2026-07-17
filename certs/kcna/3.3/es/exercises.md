# Ejercicios guiados — 3.3 Containerization (KCNA)

> Prerrequisitos: una máquina Linux (o VM) con **Docker Engine** o **containerd + nerdctl** instalados, acceso a `sudo`, y conexión a internet para descargar imágenes desde Docker Hub. Algunos ejercicios usan `ctr` y `crictl`, herramientas de bajo nivel que vienen con containerd — si no las tenés, podés instalarlas siguiendo la [documentación de containerd](https://github.com/containerd/containerd).

---

## Ejercicio 1 — De la imagen OCI al contenedor en ejecución

1. Descargá una imagen desde un registry público:
   ```bash
   docker pull nginx:1.27
   ```
2. Listá las imágenes locales y anotá el `IMAGE ID`:
   ```bash
   docker images
   ```
3. Inspeccioná los metadatos de la imagen, en particular la sección `RootFS`:
   ```bash
   docker inspect nginx:1.27 --format '{{json .RootFS}}' | jq .
   ```
4. Creá y arrancá un contenedor a partir de esa imagen:
   ```bash
   docker run -d --name ej1 -p 8080:80 nginx:1.27
   ```
5. Verificá que responde:
   ```bash
   curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080
   ```

**Preguntas:**
- ¿Qué diferencia hay entre una *imagen* y un *contenedor* en términos del OCI Image Spec y el OCI Runtime Spec?
- El array que viste en `RootFS.Layers`, ¿qué representa y por qué una imagen puede tener varias entradas ahí?

---

## Ejercicio 2 — Namespaces: aislamiento de procesos

1. Arrancá un contenedor de fondo:
   ```bash
   docker run -d --name ns-demo nginx:1.27
   ```
2. Listá los procesos **dentro** del contenedor:
   ```bash
   docker exec ns-demo ps aux
   ```
3. Obtené el PID del proceso principal visto **desde el host**:
   ```bash
   PID=$(docker inspect --format '{{.State.Pid}}' ns-demo)
   echo $PID
   ```
4. Compará ese PID con el PID que ve el proceso dentro del contenedor (paso 2). Después, listá los namespaces asignados a ese proceso:
   ```bash
   sudo ls -la /proc/$PID/ns
   ```
5. Compará contra los namespaces del propio shell del host:
   ```bash
   ls -la /proc/$$/ns
   ```

**Preguntas:**
- ¿Por qué el proceso `nginx` tiene un PID distinto visto desde dentro del contenedor (por ejemplo `1`) y desde el host (por ejemplo `48213`)?
- Nombrá al menos tres tipos de namespaces de Linux que un container runtime usa para aislar un contenedor y qué aísla cada uno.

---

## Ejercicio 3 — cgroups: límites de recursos

1. Arrancá un contenedor con límites explícitos de memoria y CPU:
   ```bash
   docker run -d --name cg-demo --memory=100m --cpus=0.5 nginx:1.27
   ```
2. Confirmá el límite configurado a nivel del runtime:
   ```bash
   docker inspect cg-demo --format 'Memory={{.HostConfig.Memory}} NanoCPUs={{.HostConfig.NanoCpus}}'
   ```
3. Ubicá el `ID` completo del contenedor y revisá el límite real aplicado por el kernel (cgroup v2; en v1 la ruta cambia a `/sys/fs/cgroup/memory/...`):
   ```bash
   CID=$(docker inspect --format '{{.Id}}' cg-demo)
   cat /sys/fs/cgroup/system.slice/docker-$CID.scope/memory.max
   ```
4. Intentá forzar el contenedor a superar el límite de memoria y observá qué pasa:
   ```bash
   docker exec cg-demo sh -c "cat /dev/zero | head -c 300m | tail"
   docker inspect cg-demo --format '{{.State.OOMKilled}}'
   ```

**Preguntas:**
- ¿Qué mecanismo del kernel de Linux hace cumplir los límites de memoria y CPU que le pasaste a `docker run`?
- Si `OOMKilled` da `true`, ¿qué significa eso y qué componente del sistema tomó la decisión de matar el proceso?

---

## Ejercicio 4 — Construir una imagen con Dockerfile (multi-stage build)

1. Creá un directorio de trabajo y un `Dockerfile` de una sola etapa:
   ```bash
   mkdir -p ~/kcna-build && cd ~/kcna-build
   cat > Dockerfile.single <<'EOF'
   FROM golang:1.22
   WORKDIR /app
   COPY main.go .
   RUN go build -o server main.go
   CMD ["./server"]
   EOF
   ```
2. Creá un `main.go` mínimo:
   ```bash
   cat > main.go <<'EOF'
   package main
   func main() { println("hola KCNA") }
   EOF
   ```
3. Construí la imagen de una sola etapa y anotá su tamaño:
   ```bash
   docker build -f Dockerfile.single -t demo:single .
   docker images demo:single
   ```
4. Ahora creá una versión **multi-stage**:
   ```bash
   cat > Dockerfile.multi <<'EOF'
   FROM golang:1.22 AS build
   WORKDIR /app
   COPY main.go .
   RUN go build -o server main.go

   FROM gcr.io/distroless/base-debian12
   COPY --from=build /app/server /server
   CMD ["/server"]
   EOF
   ```
5. Construila y compará el tamaño con la versión anterior:
   ```bash
   docker build -f Dockerfile.multi -t demo:multi .
   docker images | grep demo
   ```

**Preguntas:**
- ¿Por qué la imagen `demo:multi` es significativamente más chica que `demo:single`?
- ¿Qué queda descartado del build stage (`AS build`) cuando la imagen final solo copia el binario con `COPY --from=build`?

---

## Ejercicio 5 — Capas y filesystem de unión (OverlayFS)

1. Revisá el historial de capas de una imagen:
   ```bash
   docker history nginx:1.27
   ```
2. Arrancá un contenedor y modificá un archivo dentro de él:
   ```bash
   docker run -d --name ov-demo nginx:1.27
   docker exec ov-demo sh -c "echo 'hola' > /usr/share/nginx/html/test.txt"
   ```
3. Verificá qué cambió respecto a la imagen original:
   ```bash
   docker diff ov-demo
   ```
4. Detené y eliminá el contenedor, y confirmá que la imagen original no se modificó:
   ```bash
   docker rm -f ov-demo
   docker run --rm nginx:1.27 ls /usr/share/nginx/html/
   ```

**Preguntas:**
- ¿En qué capa (según `docker diff`) quedó registrado el archivo `test.txt`, y por qué desapareció al borrar el contenedor?
- Explicá en tus palabras qué hace un filesystem de unión (como OverlayFS) para permitir que muchos contenedores compartan las mismas capas de solo lectura sin interferir entre sí.

---

## Ejercicio 6 — containerd y CRI: `ctr` y `crictl`

1. Descargá una imagen directamente con `ctr` (cliente de bajo nivel de containerd, en el namespace por defecto):
   ```bash
   sudo ctr images pull docker.io/library/nginx:1.27
   ```
2. Listá las imágenes gestionadas por containerd:
   ```bash
   sudo ctr images ls
   ```
3. Corré un contenedor directamente con `ctr` (sin pasar por Docker):
   ```bash
   sudo ctr run -d docker.io/library/nginx:1.27 ctr-demo
   sudo ctr task ls
   ```
4. Si tenés `crictl` configurado apuntando al socket CRI de containerd, listá pods/contenedores gestionados vía CRI:
   ```bash
   sudo crictl images
   sudo crictl ps -a
   ```

**Preguntas:**
- ¿Qué rol cumple containerd entre el kubelet y el runtime de bajo nivel (por ejemplo `runc`) según la Container Runtime Interface (CRI)?
- `docker`, `ctr` y `crictl` terminan usando el mismo containerd por debajo. ¿Cuál es la diferencia de propósito entre `ctr` y `crictl`?

---

## Ejercicio 7 — Registro de imágenes OCI local

1. Levantá un registry OCI local:
   ```bash
   docker run -d -p 5000:5000 --name registry registry:2
   ```
2. Etiquetá una imagen existente para apuntar al registry local:
   ```bash
   docker tag nginx:1.27 localhost:5000/nginx:1.27
   ```
3. Subí (push) la imagen:
   ```bash
   docker push localhost:5000/nginx:1.27
   ```
4. Consultá el catálogo del registry vía su API HTTP:
   ```bash
   curl -s http://localhost:5000/v2/_catalog
   curl -s http://localhost:5000/v2/nginx/tags/list
   ```
5. Borrá la imagen local y volvela a bajar (pull) desde tu registry:
   ```bash
   docker rmi nginx:1.27 localhost:5000/nginx:1.27
   docker pull localhost:5000/nginx:1.27
   ```

**Preguntas:**
- ¿Qué especificación del OCI define el formato en que un cliente como `docker push` sube manifiestos y capas a un registry?
- ¿Por qué tuviste que hacer `docker tag` antes de poder hacer `push` a `localhost:5000/...`?

---

<details>
<summary><strong>Ver respuestas</strong></summary>

**Ejercicio 1**
- Una *imagen* es un artefacto estático e inmutable (definido por el OCI Image Spec: manifest, config y un conjunto de capas de filesystem). Un *contenedor* es la instancia en ejecución de esa imagen: un proceso (o grupo de procesos) aislado con namespaces y cgroups, gobernado por el OCI Runtime Spec, con una capa de escritura adicional encima del filesystem de la imagen.
- Cada entrada en `RootFS.Layers` es el digest de una capa de filesystem (un `tar` comprimido con los cambios de esa capa). Una imagen tiene varias porque se construye incrementalmente instrucción por instrucción del Dockerfile (o build), y esas capas se comparten y cachean entre imágenes.

**Ejercicio 2**
- Porque el PID namespace del contenedor le da su propio árbol de procesos: dentro de ese namespace el primer proceso creado siempre es PID 1, aunque desde el namespace del host ese mismo proceso tenga un PID distinto (es el mismo proceso del kernel, visto con dos "números" distintos según el namespace desde el que se mira).
- Ejemplos: PID namespace (aísla la vista del árbol de procesos), Network namespace (aísla interfaces de red, rutas, puertos), Mount namespace (aísla el árbol de montajes/filesystem), UTS namespace (aísla hostname), IPC namespace (aísla mecanismos de comunicación entre procesos como colas de mensajes/semáforos), User namespace (aísla mapeo de UIDs/GIDs).

**Ejercicio 3**
- Los **cgroups** (control groups) de Linux, que el container runtime configura al crear el contenedor para limitar y contabilizar CPU, memoria, I/O, etc. de ese grupo de procesos.
- `OOMKilled: true` significa que el kernel de Linux (el OOM killer, activado cuando el cgroup superó su `memory.max`) mató el proceso principal del contenedor por exceso de uso de memoria respecto al límite configurado.

**Ejercicio 4**
- Porque la imagen final (`demo:multi`) parte de una base mínima (`distroless`) y solo copia el binario compilado, sin incluir el compilador de Go, el código fuente, ni las herramientas de build de la etapa `build`, que en la versión de una sola etapa quedan todas presentes en la imagen.
- Se descarta todo lo del stage `build` que no fue copiado explícitamente: el SDK de Go, el caché de módulos, el código fuente `main.go`, y cualquier archivo intermedio — esa etapa ni siquiera queda como capa en la imagen final.

**Ejercicio 5**
- Quedó en la capa superior de escritura (writable layer) del contenedor `ov-demo`, que es exclusiva de ese contenedor. Al hacer `docker rm -f`, esa capa se destruye junto con el contenedor, y por eso el archivo desaparece; la imagen original nunca se tocó.
- Un filesystem de unión (union filesystem) como OverlayFS combina varias capas de solo lectura (`lowerdir`) con una capa de escritura por contenedor (`upperdir`) presentando una vista unificada (`merged`). Como las capas de solo lectura nunca se modifican, muchos contenedores pueden apuntar a las mismas capas base compartidas en disco, y cada uno solo agrega su propia capa de escritura encima.

**Ejercicio 6**
- containerd implementa el CRI (Container Runtime Interface) que expone el kubelet: recibe llamadas gRPC del kubelet (crear pod, correr contenedor, pull de imagen, etc.) y las traduce a operaciones concretas, delegando la creación real del proceso aislado a un runtime de bajo nivel compatible con OCI Runtime Spec, típicamente `runc` (vía `containerd-shim`).
- `ctr` es una herramienta de debugging de bajo nivel que habla directamente con la API nativa de containerd (no pasa por CRI); `crictl` habla con containerd a través del socket CRI, el mismo camino que usa el kubelet, por lo que sirve para inspeccionar el estado tal como lo vería Kubernetes (pods, sandboxes, etc.), no solo contenedores sueltos.

**Ejercicio 7**
- La **OCI Distribution Spec**, que define la API HTTP (`/v2/...`) que usan los clientes para subir y bajar manifiestos, configs y capas (blobs) hacia/desde un registry.
- Porque el nombre de la imagen local (`nginx:1.27`) no incluye el host del registry destino. Docker usa el nombre completo de la referencia (`<registry>/<repo>:<tag>`) para decidir a qué registry hacer push; sin el prefijo `localhost:5000/`, `docker push nginx:1.27` intentaría subir a Docker Hub.

</details>

---

**Fuente de referencia:** [KCNA Curriculum — CNCF](https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf)