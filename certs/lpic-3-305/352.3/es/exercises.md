# 352.3 Docker — Ejercicios guiados

> **Contexto del examen** — LPIC-3 305-300, Tópico 352.3 (peso 15, el objetivo más pesado de la certificación). Estos ejercicios recorren las áreas de conocimiento oficiales: arquitectura de Docker, la CLI, gestión de imágenes y contenedores, Dockerfiles, `docker compose`, networking, almacenamiento y seguridad, además del conocimiento de Podman/Buildah/skopeo.
> **Referencia:** LPI Exam 305 Objectives — https://www.lpi.org/our-certifications/exam-305-objectives/ · Docker docs — https://docs.docker.com/
>
> **Prerrequisitos del laboratorio**
> - Un host Linux (familia Debian/Ubuntu o Fedora/RHEL) con Docker Engine ≥ 24.x y el plugin Compose v2 instalado.
> - Root o un usuario en el grupo `docker`. Cuando un comando necesita privilegios se muestra con `sudo`.
> - Acceso de salida a Docker Hub (`registry-1.docker.io`) para descargar imágenes.
> - Confirmá tu línea base antes de empezar:
> ```bash
> docker version --format '{{.Server.Version}}'
> docker compose version
> ```

---

## Ejercicio 1 — Mapear la arquitectura de Docker de punta a punta

**Objetivo:** ver la división cliente/daemon y el stack de runtime `dockerd → containerd → runc` que realmente ejecuta un contenedor.

1. Consultá ambas mitades del par cliente–servidor y notá que la API es una API REST sobre un socket Unix:
   ```bash
   docker version
   ls -l /var/run/docker.sock
   ```
2. Inspeccioná el árbol de procesos del daemon y sus componentes de runtime. Iniciá primero un contenedor de larga duración para tener algo que ver:
   ```bash
   docker run -d --name arch-demo nginx:1.27-alpine
   ps -ef | grep -E 'dockerd|containerd|runc|shim' | grep -v grep
   ```
3. Mirá el shim que es dueño de tu contenedor. `containerd-shim-runc-v2` es el padre del PID 1 del contenedor y es lo que mantiene vivo al contenedor si `dockerd` se reinicia:
   ```bash
   ps -ef | grep containerd-shim | grep -v grep
   pgrep -a nginx
   ```
4. Confirmá que el daemon es un servicio systemd y que puede detenerse de forma independiente de los contenedores en ejecución:
   ```bash
   systemctl status docker.service --no-pager | head -n 5
   systemctl status docker.socket --no-pager | head -n 5
   ```
5. Preguntale al daemon sobre sí mismo. `docker info` reporta el storage driver, la versión de cgroup, el runtime por defecto y el directorio raíz:
   ```bash
   docker info --format 'Storage: {{.Driver}} | Runtime: {{.DefaultRuntime}} | Cgroup: {{.CgroupVersion}} | Root: {{.DockerRootDir}}'
   ```

La salida esperada del paso 5 se parece a:
```
Storage: overlay2 | Runtime: runc | Cgroup: v2 | Root: /var/lib/docker
```

> **Q1.1** — Cuando escribís `docker run`, ¿qué proceso crea realmente los namespaces y cgroups del contenedor: `docker`, `dockerd`, `containerd` o `runc`?
> **Q1.2** — Ejecutás `systemctl restart docker`. Tu contenedor `arch-demo` sigue corriendo durante todo el proceso. ¿Qué componente hace eso posible, y por qué es deliberadamente *no* un hijo de `dockerd`?
> **Q1.3** — ¿Para qué sirve `docker.socket`, y cómo cambia la activación por socket cuando el daemon arranca por primera vez?

---

## Ejercicio 2 — Configurar el daemon a través de `/etc/docker/daemon.json`

**Objetivo:** cambiar el comportamiento a nivel de todo el daemon de forma declarativa (el archivo de configuración relevante para el examen) y probar que el cambio surtió efecto.

1. Inspeccioná el logging driver actual y el pool de direcciones por defecto *antes* de cambiar nada:
   ```bash
   docker info --format 'Log driver: {{.LoggingDriver}}'
   ```
2. Creá o editá la configuración del daemon. Si el archivo no existe, crealo:
   ```bash
   sudo install -d -m 0755 /etc/docker
   sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
   {
     "log-driver": "json-file",
     "log-opts": {
       "max-size": "10m",
       "max-file": "3"
     },
     "default-address-pools": [
       { "base": "172.30.0.0/16", "size": 24 }
     ],
     "live-restore": true
   }
   EOF
   ```
3. Validá que el JSON esté bien formado *antes* de recargar (un error de sintaxis impedirá que el daemon arranque):
   ```bash
   sudo dockerd --validate --config-file /etc/docker/daemon.json
   ```
4. Aplicalo. `log-driver` y `default-address-pools` requieren un reinicio completo; muchas opciones (como `live-restore`) pueden aplicarse con una recarga por SIGHUP:
   ```bash
   sudo systemctl restart docker
   docker info --format 'Log driver: {{.LoggingDriver}}'
   ```
5. Probá que el nuevo pool de direcciones se usa en una red recién creada:
   ```bash
   docker network create pooltest
   docker network inspect pooltest --format '{{(index .IPAM.Config 0).Subnet}}'
   ```

Esperado: la subred cae dentro de `172.30.0.0/16` con una máscara `/24`, p. ej. `172.30.1.0/24`.

> **Q2.1** — Agregás `"hosts": ["tcp://0.0.0.0:2375"]` a `daemon.json` y el daemon no arranca bajo systemd. ¿Por qué, y cuál es la forma correcta de exponer el daemon sobre TCP?
> **Q2.2** — ¿Qué cambia `live-restore` respecto de la relación entre `dockerd` y los contenedores en ejecución, y cuál es su principal limitación?
> **Q2.3** — ¿Cuál es autoritativo cuando el mismo flag aparece tanto en `daemon.json` como en la línea de comandos de `dockerd`, y por qué se niegan a coexistir para la misma clave?

---

## Ejercicio 3 — Gestionar imágenes: capas, historial, tags, digests

**Objetivo:** entender las imágenes como pilas de capas de solo lectura y gestionarlas con precisión.

1. Descargá una imagen y leé sus metadatos de capas/digest:
   ```bash
   docker pull nginx:1.27-alpine
   docker images --digests nginx
   ```
2. Leé el historial de build — cada línea es una capa, las líneas `<missing>` son capas importadas de una imagen base sin sus propios metadatos de build:
   ```bash
   docker history nginx:1.27-alpine
   ```
3. Inspeccioná el sistema de archivos por capas y la config. Notá `RootFS.Layers` (diff IDs direccionables por contenido) frente al `Env`/`Cmd` de la config:
   ```bash
   docker image inspect nginx:1.27-alpine --format '{{len .RootFS.Layers}} layers'
   docker image inspect nginx:1.27-alpine --format '{{json .Config.Cmd}}'
   ```
4. Reetiquetá la imagen con un nombre local y observá que no se copia ningún dato — ambos nombres apuntan al mismo image ID:
   ```bash
   docker tag nginx:1.27-alpine myteam/web:v1
   docker images --format '{{.Repository}}:{{.Tag}} => {{.ID}}' | grep -E 'nginx|myteam'
   ```
5. Fijá por digest inmutable en lugar de un tag mutable, luego recuperá espacio con un prune filtrado:
   ```bash
   docker inspect --format '{{index .RepoDigests 0}}' nginx:1.27-alpine
   docker image prune -a --filter "until=24h" --dry-run 2>/dev/null || docker image prune -a --filter "until=24h"
   ```

> **Q3.1** — ¿Por qué `docker tag` puede crear diez nombres para una imagen al instante, mientras que un `docker pull` de un tag nuevo puede no descargar nada? ¿Qué propiedad subyacente de las capas explica ambas cosas?
> **Q3.2** — En la salida de `docker history`, ¿qué significa realmente un valor `<missing>` en la columna `IMAGE` — la capa se perdió?
> **Q3.3** — Un colega despliega `nginx:1.27-alpine` hoy y vos desplegás el "mismo" tag el mes que viene, y sin embargo corren bits diferentes. ¿Cómo hacés el despliegue reproducible, y qué comando te da el valor para fijar?

---

## Ejercicio 4 — Construir imágenes con un Dockerfile (multi-stage + cache)

**Objetivo:** escribir un Dockerfile sintácticamente completo, explotar la invalidación de la caché de build y achicar el resultado con un build multi-stage.

1. Creá un directorio de proyecto y un pequeño programa Go para compilar:
   ```bash
   mkdir -p ~/lab/docker-build && cd ~/lab/docker-build
   cat > main.go <<'EOF'
   package main

   import (
       "fmt"
       "net/http"
   )

   func main() {
       http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
           fmt.Fprintln(w, "hello from a multi-stage build")
       })
       http.ListenAndServe(":8080", nil)
   }
   EOF
   ```
2. Escribí un Dockerfile **multi-stage**: una etapa `builder` compila un binario estático, la etapa final copia solo ese binario sobre una base mínima:
   ```dockerfile
   # syntax=docker/dockerfile:1
   FROM golang:1.22-alpine AS builder
   WORKDIR /src
   COPY go.* ./
   RUN go mod download 2>/dev/null || true
   COPY . .
   RUN CGO_ENABLED=0 GOOS=linux go build -o /out/app ./...

   FROM gcr.io/distroless/static-debian12:nonroot
   COPY --from=builder /out/app /app
   EXPOSE 8080
   USER nonroot:nonroot
   ENTRYPOINT ["/app"]
   ```
3. Inicializá el módulo y construí, etiquetando el resultado:
   ```bash
   printf 'module example.com/app\n\ngo 1.22\n' > go.mod
   docker build -t multistage-demo:1 .
   ```
4. Compará el tamaño final contra un build de una sola etapa ingenuo (el toolchain del builder nunca se envía):
   ```bash
   docker images multistage-demo:1 --format 'final image: {{.Size}}'
   docker images golang:1.22-alpine --format 'builder base: {{.Size}}'
   ```
5. Demostrá la invalidación de la caché. Tocá el código fuente, reconstruí y observá qué pasos dicen `CACHED`:
   ```bash
   docker build -t multistage-demo:2 . 2>&1 | grep -E 'CACHED|RUN go build'
   sed -i 's/hello from/HELLO from/' main.go
   docker build -t multistage-demo:3 . 2>&1 | grep -E 'CACHED|RUN go build'
   ```
6. Confirmá que la imagen final corre como un usuario no-root (la línea `USER nonroot` importa para la seguridad):
   ```bash
   docker run --rm --entrypoint /bin/sh multistage-demo:3 -c 'id' 2>/dev/null || echo "distroless has no shell — that is the point"
   ```

> **Q4.1** — ¿Por qué `COPY go.* ./` se coloca en su propia línea *antes* de `COPY . .`? ¿Qué te aporta ese orden a lo largo de las reconstrucciones?
> **Q4.2** — Después de editar `main.go`, la capa `go build` se vuelve a ejecutar pero la capa `go mod download` permanece `CACHED`. Explicá la regla de caché que produce esto.
> **Q4.3** — Contrastá `ENTRYPOINT ["/app"]` (forma exec) con `ENTRYPOINT /app` (forma shell). ¿Cuál permite que el proceso reciba `SIGTERM` como PID 1, y por qué importa eso para `docker stop`?
> **Q4.4** — La etapa final es `distroless` sin shell. Nombrá dos compromisos operativos — un beneficio, un costo.

---

## Ejercicio 5 — Ciclo de vida del contenedor, exec, logs, límites de recursos

**Objetivo:** llevar un contenedor por su ciclo de vida completo y restringirlo con límites de cgroup.

1. Corré un contenedor en modo detached con una política de reinicio explícita y topes de recursos:
   ```bash
   docker run -d --name lc-demo \
     --restart=on-failure:3 \
     --memory=128m --memory-swap=128m \
     --cpus=0.5 \
     --pids-limit=100 \
     nginx:1.27-alpine
   ```
2. Observá los estados del ciclo de vida y los límites aplicados:
   ```bash
   docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.RunningFor}}'
   docker inspect lc-demo --format 'Mem: {{.HostConfig.Memory}} | CPUs: {{.HostConfig.NanoCpus}} | PIDs: {{.HostConfig.PidsLimit}}'
   ```
3. Entrá al contenedor en ejecución y leé su vista de cgroup (se muestra la ruta de cgroup v2):
   ```bash
   docker exec lc-demo cat /sys/fs/cgroup/memory.max
   docker exec lc-demo cat /sys/fs/cgroup/pids.max
   ```
4. Transmití los logs y confirmá que el logging driver del lado del daemon que configuraste en el Ejercicio 2 está en efecto:
   ```bash
   docker logs --tail 5 --timestamps lc-demo
   docker inspect lc-demo --format '{{.HostConfig.LogConfig.Type}}'
   ```
5. Recorré las transiciones pause/stop/start y leé el código de salida:
   ```bash
   docker pause lc-demo && docker ps --filter name=lc-demo --format '{{.Status}}'
   docker unpause lc-demo
   docker stop lc-demo
   docker inspect lc-demo --format 'Exited: {{.State.ExitCode}} | OOMKilled: {{.State.OOMKilled}}'
   docker start lc-demo
   ```
6. Dispará el límite de memoria para ver un OOM kill (asigná más de 128 MB):
   ```bash
   docker run --rm --memory=64m --memory-swap=64m python:3.12-alpine \
     python -c "x = bytearray(200*1024*1024)" ; echo "exit=$?"
   ```

Esperado: el contenedor es eliminado y el shell imprime un código de salida distinto de cero (`137`, es decir `128 + SIGKILL(9)`).

> **Q5.1** — ¿Por qué debés poner `--memory-swap` igual a `--memory` para realmente topear la memoria? ¿Qué pasa si omitís `--memory-swap`?
> **Q5.2** — Un código de salida `137` y `139` significan cosas diferentes. Decodificá ambos.
> **Q5.3** — Con `--restart=on-failure:3`, un contenedor sale con `0`. ¿Docker lo reinicia? ¿Y con salida `1`? Enunciá la regla.
> **Q5.4** — ¿Cuál es la diferencia entre `docker stop` y `docker kill` en términos de la señal enviada y el período de gracia?

---

## Ejercicio 6 — Networking: bridge, redes definidas por el usuario, DNS, publicación

**Objetivo:** entender el bridge por defecto frente a un bridge definido por el usuario, el DNS embebido y la publicación de puertos.

1. Listá las redes por defecto que crea el daemon e inspeccioná el bridge por defecto:
   ```bash
   docker network ls
   docker network inspect bridge --format 'Subnet: {{(index .IPAM.Config 0).Subnet}} | Gateway: {{(index .IPAM.Config 0).Gateway}}'
   ip -brief addr show docker0
   ```
2. Creá un **bridge definido por el usuario** — esto habilita el DNS automático por nombre de contenedor, que el bridge por defecto *no* provee:
   ```bash
   docker network create --driver bridge appnet
   docker run -d --name db  --network appnet redis:7-alpine
   docker run -d --name api --network appnet nginx:1.27-alpine
   ```
3. Probá que el descubrimiento de servicios por nombre funciona en la red definida por el usuario:
   ```bash
   docker exec api getent hosts db
   docker exec api ping -c1 db
   ```
4. Mostrá que el bridge *por defecto* no puede resolver nombres (solo funcionan el legacy `--link` o las IPs):
   ```bash
   docker run -d --name legacy1 nginx:1.27-alpine
   docker run -d --name legacy2 nginx:1.27-alpine
   docker exec legacy1 getent hosts legacy2 || echo "no DNS on default bridge — expected"
   ```
5. Publicá un puerto y rastreá la regla de NAT que Docker instala:
   ```bash
   docker run -d --name pub -p 8081:80 nginx:1.27-alpine
   curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8081
   sudo iptables -t nat -L DOCKER -n | grep 8081 || sudo nft list chain ip nat DOCKER 2>/dev/null | grep 8081
   ```
6. Compará `--network host` (comparte el netns del host, sin NAT, sin aislamiento) y `--network none` (sin conectividad):
   ```bash
   docker run --rm --network host nginx:1.27-alpine sh -c 'ip addr show | grep -c inet'
   docker run --rm --network none  alpine ip addr show
   ```

> **Q6.1** — Dos contenedores en el bridge *por defecto*; uno necesita alcanzar al otro por nombre. ¿Por qué falla `ping db`, y cuál es el arreglo único más limpio?
> **Q6.2** — `-p 8081:80` — ¿qué número es el puerto del host y cuál el puerto del contenedor? ¿Qué restringe adicionalmente `-p 127.0.0.1:8081:80`?
> **Q6.3** — Con `--network host`, ¿qué hace `-p 8081:80`? ¿Por qué la publicación no tiene sentido en el modo de networking host?
> **Q6.4** — ¿Qué tabla y cadena de iptables usa Docker para implementar el DNAT de puertos publicados, y cuál es el riesgo de que las reglas de Docker eludan una política de `ufw`/`firewalld` del host?

---

## Ejercicio 7 — Almacenamiento: volúmenes con nombre vs bind mounts vs tmpfs

**Objetivo:** persistir y compartir datos correctamente, y saber cuándo el daemon gestiona el ciclo de vida frente a cuándo lo hacés vos.

1. Creá un volumen con nombre e inspeccioná dónde lo almacena el daemon:
   ```bash
   docker volume create pgdata
   docker volume inspect pgdata --format 'Driver: {{.Driver}} | Mountpoint: {{.Mountpoint}}'
   ```
2. Adjuntalo y escribí datos; luego destruí el contenedor y probá que los datos sobreviven:
   ```bash
   docker run -d --name pg -e POSTGRES_PASSWORD=secret -v pgdata:/var/lib/postgresql/data postgres:16-alpine
   sleep 5
   docker exec pg psql -U postgres -c 'CREATE TABLE t(id int); INSERT INTO t VALUES (42);'
   docker rm -f pg
   docker run -d --name pg2 -e POSTGRES_PASSWORD=secret -v pgdata:/var/lib/postgresql/data postgres:16-alpine
   sleep 5
   docker exec pg2 psql -U postgres -c 'SELECT * FROM t;'
   ```
3. Compará con un **bind mount** — la ruta del host es la fuente de verdad y Docker nunca gestiona su ciclo de vida:
   ```bash
   mkdir -p ~/lab/site && echo '<h1>bind-mounted</h1>' > ~/lab/site/index.html
   docker run -d --name bindweb -p 8082:80 \
     --mount type=bind,source="$HOME/lab/site",target=/usr/share/nginx/html,readonly \
     nginx:1.27-alpine
   curl -s http://localhost:8082
   echo '<h1>changed on host</h1>' > ~/lab/site/index.html
   curl -s http://localhost:8082
   ```
4. Usá `tmpfs` para datos sensibles o efímeros que nunca deben tocar el disco:
   ```bash
   docker run --rm --tmpfs /scratch:rw,size=16m,noexec alpine \
     sh -c 'mount | grep scratch; dd if=/dev/zero of=/scratch/f bs=1M count=8 && echo written'
   ```
5. Limpiá los volúmenes colgantes de forma segura:
   ```bash
   docker rm -f pg2 bindweb
   docker volume ls --filter dangling=true
   docker volume prune -f
   ```

> **Q7.1** — Ambos sobreviven a un `docker rm`. ¿Cuál es la diferencia esencial en *quién es dueño del ciclo de vida* de un volumen con nombre frente a un bind mount?
> **Q7.2** — ¿Por qué la sintaxis `--mount type=bind,...` generalmente se prefiere sobre `-v /host:/container` para bind mounts? Dá un modo de falla que `-v` oculta.
> **Q7.3** — Hacés un bind mount de un directorio vacío del host sobre `/var/lib/mysql`, que la imagen prepobló. ¿Qué pasa con los datos pre-sembrados de la imagen, y por qué esto difiere de un *volumen con nombre* nuevo?
> **Q7.4** — ¿Cuándo elegirías deliberadamente `tmpfs` en lugar de un volumen?

---

## Ejercicio 8 — Docker Compose (stack multi-servicio)

**Objetivo:** declarar una aplicación multi-contenedor, gestionar su ciclo de vida como una unidad y usar ordenamiento de dependencias con health checks.

1. Escribí un `compose.yaml` describiendo una web app, una caché Redis y una red/volumen:
   ```bash
   mkdir -p ~/lab/compose && cd ~/lab/compose
   cat > compose.yaml <<'EOF'
   name: labstack
   services:
     cache:
       image: redis:7-alpine
       healthcheck:
         test: ["CMD", "redis-cli", "ping"]
         interval: 2s
         timeout: 3s
         retries: 5
       networks: [backend]

     web:
       image: nginx:1.27-alpine
       ports:
         - "8083:80"
       depends_on:
         cache:
           condition: service_healthy
       volumes:
         - webcontent:/usr/share/nginx/html:ro
       networks: [backend]
       deploy:
         resources:
           limits:
             memory: 128M

   networks:
     backend:
       driver: bridge

   volumes:
     webcontent:
   EOF
   ```
2. Levantá el stack en modo detached y leé su estado. Fijate que `web` espera a que `cache` esté *healthy*, no meramente iniciado:
   ```bash
   docker compose up -d
   docker compose ps
   ```
3. Mostrá el naming con scope de proyecto y la red/volumen auto-creados (con prefijo del `name:` del proyecto):
   ```bash
   docker network ls | grep labstack
   docker volume ls | grep labstack
   docker compose config --services
   ```
4. Escalá horizontalmente un servicio sin estado y ver los logs agregados:
   ```bash
   docker compose up -d --scale cache=1 web=2 2>&1 | tail -n 3 || echo "note: 'web' publishes a fixed host port, so it cannot scale >1 as written"
   docker compose logs --tail 3 cache
   ```
5. Desmontá todo el stack, incluyendo los volúmenes con nombre:
   ```bash
   docker compose down --volumes --remove-orphans
   docker compose ls
   ```

> **Q8.1** — ¿Qué garantiza `depends_on: { cache: { condition: service_healthy } }` que un simple `depends_on: [cache]` *no* garantiza?
> **Q8.2** — ¿Por qué el servicio `web` de este archivo no puede escalarse más allá de una réplica tal como está escrito, y qué cambio lo haría escalable?
> **Q8.3** — ¿Cómo deriva Compose los nombres de la red `labstack_backend` y del contenedor `labstack-web-1`? ¿Qué controla el prefijo?
> **Q8.4** — ¿Cuál es la diferencia práctica entre `docker compose down`, `docker compose down --volumes` y `docker compose stop`?

---

## Ejercicio 9 — Endurecimiento de la seguridad de contenedores

**Objetivo:** aplicar los controles de defensa en profundidad que el objetivo menciona — capabilities, usuario no-root, rootfs de solo lectura, no-new-privileges, seccomp — y verificar cada uno.

1. Mostrá las capabilities de Linux por defecto que recibe un contenedor, luego dropealas todas y volvé a agregar solo lo necesario:
   ```bash
   docker run --rm alpine sh -c 'apk add -q libcap; capsh --print' 2>/dev/null | grep Current || \
   docker run --rm alpine grep CapEff /proc/1/status
   docker run --rm --cap-drop=ALL --cap-add=NET_BIND_SERVICE alpine grep CapEff /proc/1/status
   ```
2. Corré un contenedor endurecido: usuario no-root, sistema de archivos raíz de solo lectura, sin escalada de privilegios, con un `tmpfs` escribible para la única ruta que lo necesita:
   ```bash
   docker run -d --name hardened \
     --user 10001:10001 \
     --read-only \
     --tmpfs /tmp:rw,size=8m \
     --security-opt no-new-privileges=true \
     --cap-drop=ALL \
     nginx:1.27-alpine 2>&1 | tail -n1 || true
   ```
   (El `nginx` de stock escribe en varias rutas; esperá que falle — esa es la lección. Usá una imagen diseñada para rootfs de solo lectura, o agregá las rutas `--tmpfs` necesarias.)
3. Verificá la postura de seguridad en ejecución de una carga de trabajo correctamente endurecida:
   ```bash
   docker run -d --name safe --user 10001:10001 --security-opt no-new-privileges=true --cap-drop=ALL alpine sleep 600
   docker exec safe id
   docker exec safe grep NoNewPrivs /proc/1/status
   docker inspect safe --format 'ReadOnly: {{.HostConfig.ReadonlyRootfs}} | Caps dropped: {{json .HostConfig.CapDrop}}'
   ```
4. Confirmá que el perfil seccomp por defecto está activo y demostrá que bloquea un syscall peligroso. Compará contra `--security-opt seccomp=unconfined`:
   ```bash
   docker run --rm alpine sh -c 'unshare --map-root-user --user echo ok' 2>&1 | head -n1 || echo "blocked by default seccomp/userns"
   docker run --rm --security-opt seccomp=unconfined alpine sh -c 'echo unconfined runs'
   ```
5. Contrastá con un contenedor inseguro. **Nunca hagas esto en producción** — `--privileged` deshabilita casi todos los controles a la vez:
   ```bash
   docker run --rm --privileged alpine grep CapEff /proc/1/status
   # Compare the CapEff bitmask against the --cap-drop=ALL run from step 1.
   ```

> **Q9.1** — `--privileged` vs `--cap-add=SYS_ADMIN` — ¿por qué el primero es mucho más peligroso que agregar incluso una única capability poderosa?
> **Q9.2** — ¿Qué previene exactamente `--security-opt no-new-privileges=true`, y qué vector de ataque clásico (un bit de permiso de archivo específico) neutraliza?
> **Q9.3** — Un sistema de archivos raíz de solo lectura rompió `nginx`. Explicá la remediación correcta sin simplemente quitar `--read-only`.
> **Q9.4** — ¿Qué es Docker *rootless*, y qué clase de vulnerabilidad (compromiso del daemon → root del host) mitiga fundamentalmente que un contenedor rootful endurecido no mitiga?

---

## Ejercicio 10 — Conocimiento: Podman, Buildah, skopeo

**Objetivo:** el objetivo lista estos como ítems de conocimiento. Contrastá el modelo sin daemon frente a Docker sin necesariamente tenerlos instalados.

1. Notá la afirmación arquitectónica a verificar conceptualmente: Docker usa un daemon root de larga duración (`dockerd`); Podman es sin daemon y forkea `conmon` por contenedor, corriendo rootless por defecto.
2. Si Podman está disponible, mostrá la compatibilidad de CLI drop-in y el modelo de procesos sin daemon:
   ```bash
   command -v podman && podman run --rm alpine echo "podman: no daemon required" || echo "podman not installed — awareness only"
   command -v podman && podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null
   ```
3. Si Buildah está disponible, construí sin un daemon ni un Dockerfile (builds imperativos):
   ```bash
   command -v buildah && buildah --version || echo "buildah not installed — awareness only"
   ```
4. Si skopeo está disponible, inspeccioná y copiá imágenes entre registries **sin descargarlas a un runtime local**:
   ```bash
   command -v skopeo && skopeo inspect docker://docker.io/library/nginx:1.27-alpine | head -n 12 || echo "skopeo not installed — awareness only"
   ```
5. Independientemente de lo que esté instalado, conocé la división del trabajo: **Podman** corre contenedores, **Buildah** construye imágenes, **skopeo** mueve/inspecciona imágenes.

> **Q10.1** — ¿Qué única diferencia arquitectónica entre Podman y Docker cambia más la historia de seguridad, y cómo cambia quién es dueño de los procesos de un contenedor?
> **Q10.2** — Emparejá cada herramienta con su trabajo: correr contenedores / construir imágenes / copiar e inspeccionar imágenes entre registries.
> **Q10.3** — ¿Por qué skopeo puede copiar una imagen de Docker Hub a un registry privado en un host que no tiene ningún container runtime corriendo?
> **Q10.4** — Un equipo quiere comandos compatibles con `docker` pero sin daemon root. ¿Qué herramienta, y qué les da (y qué no les da) `alias docker=podman`?

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1
- **Q1.1** — `runc`. La cadena es `docker` (CLI, habla REST con el daemon) → `dockerd` (acepta la llamada de API, prepara la config) → `containerd` (gestiona el ciclo de vida del contenedor, imagen/snapshot) → `containerd-shim` (supervisor por contenedor) → **`runc`**, el runtime OCI que realmente llama a `clone()`/`unshare()` para crear los namespaces y escribe los límites de cgroup, luego hace `execve()` del entrypoint y sale. Después del exec, `runc` desaparece; el shim permanece.
- **Q1.2** — El proceso **`containerd-shim-runc-v2`**. Cada contenedor en ejecución tiene su propio shim, y el shim — no `dockerd` — es el padre del PID 1 del contenedor. Como el shim es reparentado a `init`/systemd y es independiente del daemon, reiniciar o crashear `dockerd`/`containerd` no mata a los contenedores en ejecución (esto es lo que proveen `live-restore` y la arquitectura del shim). Si el shim fuera hijo de `dockerd`, matar el daemon dispararía una cascada de señales a cada contenedor.
- **Q1.3** — `docker.socket` es una unit de socket de systemd que es dueña de `/var/run/docker.sock` y provee **activación por socket**: systemd crea y escucha en el socket, e inicia `docker.service` en la primera conexión de un cliente. Esto significa que el socket existe (y los clientes pueden conectarse) incluso antes/mientras el daemon está arrancando; el daemon hereda el fd del socket ya abierto en lugar de crearlo él mismo.

### Ejercicio 2
- **Q2.1** — Bajo systemd, el `ExecStart` de la unit normalmente ya pasa `-H fd://` (activación por socket). Especificar `hosts` en `daemon.json` *y* en la línea de comandos para la misma clave es un conflicto y el daemon aborta con "unable to configure the Docker daemon with file … the following directives are specified both as a flag and in the configuration file: hosts". El arreglo correcto es un **drop-in de systemd** que sobreescriba `ExecStart` (borrando el `-H fd://` y agregando `-H fd:// -H tcp://…`), o quitar `-H` de la unit y setear `hosts` solo en `daemon.json`. Y exponer `2375` sin cifrar es root sin autenticación — usá TLS (`2376`) o un contexto SSH en su lugar.
- **Q2.2** — `live-restore: true` permite que los contenedores sigan corriendo mientras el daemon está **caído** (detenido o actualizándose), apoyándose en el shim/containerd. Su principal limitación: solo soporta **reinicios del daemon**, no cambios de configuración que requieran reconfigurar contenedores en ejecución, y es incompatible con el modo swarm; además, que el *daemon* esté caído significa que no hay nuevas operaciones de API, monitoreo de health ni recolección de logs hasta que vuelva.
- **Q2.3** — Ninguno es "autoritativo" — Docker deliberadamente **se niega a arrancar** si la misma clave está seteada tanto en `daemon.json` como en un flag de línea de comandos, porque una precedencia silenciosa ocultaría una mala configuración. Debés elegir exactamente un lugar para cada opción.

### Ejercicio 3
- **Q3.1** — Las imágenes son **pilas de capas de solo lectura direccionables por contenido**, y un tag es solo un puntero con nombre a una config de imagen (que a su vez es un digest). `docker tag` solo escribe un puntero nuevo — no se mueven bytes. `docker pull` de un tag nuevo descarga solo las capas cuyos digests no tenés ya localmente; si el tag nuevo comparte todas las capas con una imagen que ya tenés, no se transfiere nada.
- **Q3.2** — La capa **no** desapareció. `<missing>` significa que esa capa fue descargada como parte de una imagen base y Docker no tiene metadatos de build-history locales (la config de la imagen intermedia) para ella — solo la imagen padre tenía eso. Los datos de la capa están presentes y en uso; solo se desconoce localmente su comando/image-ID de build histórico.
- **Q3.3** — Fijá por **digest**, no por tag: `nginx@sha256:…`. Los tags son punteros mutables que pueden ser re-pusheados; un digest es el hash de contenido inmutable del manifest. Obtenelo con `docker inspect --format '{{index .RepoDigests 0}}' nginx:1.27-alpine` (o `docker images --digests`).

### Ejercicio 4
- **Q4.1** — Para maximizar la **reutilización de la caché de build**. Los manifests de dependencias (`go.mod`/`go.sum`) cambian raramente; el código fuente cambia con frecuencia. Copiar solo los manifests y correr `go mod download` en su propia capa hace que ese paso costoso de fetch de dependencias permanezca cacheado en cada rebuild donde solo cambió el código. Copiar todo primero invalidaría la capa de download ante cualquier edición del código.
- **Q4.2** — La invalidación de la caché es **secuencial y basada en contenido**: una capa se reutiliza solo si su instrucción *y* el checksum de sus entradas están sin cambios *y* toda capa previa también fue un cache hit. Editar `main.go` cambia la entrada de los pasos posteriores `COPY . .`/`go build`, invalidándolos, pero los pasos anteriores `COPY go.* ./` + `go mod download` tienen entradas sin cambios y predecesores sin cambios, así que permanecen `CACHED`.
- **Q4.3** — La **forma exec** `ENTRYPOINT ["/app"]` corre el binario directamente como PID 1, así que recibe `SIGTERM` de `docker stop`. La **forma shell** `ENTRYPOINT /app` corre `/bin/sh -c "/app"`, haciendo que `sh` sea PID 1; la señal va a `sh`, que típicamente no la reenvía, así que `docker stop` espera todo el período de gracia y luego hace `SIGKILL`. La forma exec es requerida para un apagado correcto y rápido.
- **Q4.4** — Beneficio: **superficie de ataque mínima** — sin shell, sin gestor de paquetes, tamaño diminuto, menos CVEs. Costo: **sin depuración dentro del contenedor** — no podés hacer `docker exec … sh`; debés depurar vía un contenedor de debug efímero / `docker debug` / copiando herramientas adentro, y no hay tooling basado en libc.

### Ejercicio 5
- **Q5.1** — `--memory` topea la RAM, pero por defecto `--memory-swap` se setea al doble de `--memory`, así que el contenedor puede volcarse a swap y exceder el presupuesto de RAM previsto. Setear `--memory-swap` **igual a** `--memory` deshabilita el swap para ese contenedor, haciendo que el tope de RAM sea duro. Omitirlo → hasta 2× el límite se vuelve utilizable vía swap.
- **Q5.2** — Salida `137` = `128 + 9` → el proceso fue eliminado por **SIGKILL** (comúnmente un OOM kill o `docker kill`). Salida `139` = `128 + 11` → eliminado por **SIGSEGV** (fallo de segmentación). Chequeá `.State.OOMKilled` para distinguir un `137` por OOM de un kill manual.
- **Q5.3** — `on-failure` reinicia solo ante una salida **distinta de cero**. Salida `0` → sin reinicio. Salida `1` → reinicia, hasta el máximo de reintentos `:3`, tras lo cual Docker se rinde.
- **Q5.4** — `docker stop` envía **SIGTERM**, espera el período de gracia (por defecto 10s, `-t` para cambiarlo), luego **SIGKILL** si sigue vivo — una detención elegante. `docker kill` envía **SIGKILL** inmediatamente (o la señal de `--signal`), sin período de gracia.

### Ejercicio 6
- **Q6.1** — El **bridge por defecto** no corre el servidor DNS embebido de Docker para nombres de contenedor (solo para resolución externa), así que `db` no resuelve. Arreglo más limpio: poner ambos contenedores en una **red bridge definida por el usuario** (`docker network create` + `--network`), que habilita el DNS automático por nombre. (El legacy `--link` también funciona pero está deprecado.)
- **Q6.2** — El formato es `-p HOST:CONTAINER`, así que `8081` es el puerto del host y `80` el puerto del contenedor. `-p 127.0.0.1:8081:80` adicionalmente **enlaza el puerto publicado solo a la interfaz loopback**, así que es alcanzable desde el propio host pero no desde otras máquinas en la red.
- **Q6.3** — Con `--network host` el contenedor comparte el network namespace del host directamente, así que su puerto 80 *es* el puerto 80 del host. `-p` es **ignorado** (Docker avisa) porque no hay un namespace separado hacia el cual hacer NAT — la publicación solo tiene sentido cuando el contenedor tiene su propio netns.
- **Q6.4** — Docker inserta reglas de DNAT en la **tabla `nat`, cadena `DOCKER`** (a la que se salta desde `PREROUTING`/`OUTPUT`), y reglas FORWARD en la tabla `filter`. Como Docker manipula iptables/nftables directamente y su cadena `DOCKER` se evalúa antes que las típicas reglas de usuario de `ufw`, un puerto publicado puede ser alcanzable **incluso si el firewall del host parece bloquearlo** — un footgun bien conocido; mitigá con `-p 127.0.0.1:…`, las opciones userland-proxy/`iptables:false`, o una integración de firewall consciente de Docker.

### Ejercicio 7
- **Q7.1** — El **ciclo de vida de un volumen con nombre es gestionado por el daemon de Docker** (almacenado bajo `/var/lib/docker/volumes/…`, listado por `docker volume ls`, removible por `docker volume rm`). Un **bind mount es solo una ruta del host**; Docker lo monta pero nunca es su dueño — los comandos `docker volume` no lo ven y remover el contenedor nunca toca el directorio del host.
- **Q7.2** — `--mount` es explícito y **falla ruidosamente** ante un error. Con `-v /host:/container`, si la ruta del host no existe Docker silenciosamente **la crea como un directorio propiedad de root** (y `-v name:/path` vs `-v /abs/path:/path` cambia de significado según si el source parece una ruta) — bugs sutiles que `--mount` previene al requerir `type=` y parámetros con nombre.
- **Q7.3** — Un **bind mount** superpone el directorio del host sobre `/var/lib/mysql`, **ocultando los archivos pre-sembrados de la imagen** (quedan sombreados, y si el directorio del host está vacío la DB ve un datadir vacío). Un **volumen con nombre** nuevo es diferente: cuando un contenedor monta por primera vez un volumen con nombre *vacío* sobre una ruta poblada de la imagen, Docker **copia el contenido existente de la imagen al volumen**. Los bind mounts nunca hacen esta copia inicial.
- **Q7.4** — Elegí `tmpfs` cuando los datos deban ser **rápidos y efímeros y nunca persistir en disco** — secretos/tokens, espacio de scratch, cachés — especialmente para evitar escribir material sensible al sistema de archivos del host o a la ruta escribible de un contenedor con rootfs de solo lectura.

### Ejercicio 8
- **Q8.1** — Un simple `depends_on: [cache]` solo garantiza **el orden de inicio** — `web` inicia después de que el contenedor de `cache` es creado/iniciado, pero `cache` puede no estar todavía listo para servir. `condition: service_healthy` hace que `web` espere hasta que el **healthcheck de `cache` reporte healthy**, garantizando la disponibilidad real.
- **Q8.2** — `web` publica un **puerto de host fijo** (`8083:80`). Escalar a N réplicas haría que N contenedores intenten todos enlazar el puerto de host 8083 — una colisión. Hacelo escalable publicando un **rango o puerto de host efímero** (p. ej. `- "80"` o `"8083-8085:80"`) y/o poniendo un balanceador de carga/reverse proxy delante.
- **Q8.3** — Compose deriva los nombres del **nombre del proyecto** (aquí seteado explícitamente por `name: labstack`; si no, por defecto el nombre del directorio). Red = `<project>_<network>` → `labstack_backend`; contenedor = `<project>-<service>-<index>` → `labstack-web-1`. `-p/--project-name` o `COMPOSE_PROJECT_NAME` sobreescriben el prefijo.
- **Q8.4** — `docker compose stop` detiene los contenedores pero los mantiene, junto con sus redes y volúmenes (reanudación rápida). `docker compose down` detiene **y remueve** los contenedores y la red por defecto, pero **mantiene los volúmenes con nombre**. `docker compose down --volumes` adicionalmente **remueve los volúmenes con nombre** declarados en el archivo — pérdida de datos permanente.

### Ejercicio 9
- **Q9.1** — `--privileged` hace mucho más que otorgar todas las capabilities: también **deshabilita seccomp, deshabilita el confinamiento de AppArmor/SELinux, y expone todos los dispositivos del host** (`/dev`) con acceso completo — eliminando efectivamente el límite de aislamiento, así que el contenedor puede reconfigurar el host, cargar módulos del kernel y acceder a discos crudos. `--cap-add=SYS_ADMIN` otorga una (muy poderosa) capability pero deja en pie seccomp, el LSM y las restricciones del device cgroup.
- **Q9.2** — Setea el bit `no_new_privs` del kernel en el proceso, previniendo que los procesos del contenedor **ganen más privilegios de los que empiezan** vía `execve`. Concretamente neutraliza los **binarios setuid/setgid** — un binario `setuid-root` dentro del contenedor ya no puede elevar a root, bloqueando una vía clásica de escalada de privilegios.
- **Q9.3** — Mantené `--read-only` y **otorgá espacio escribible solo donde la app realmente lo necesita** usando `--tmpfs` (o un volumen montado) para esas rutas específicas (para `nginx`: `/var/cache/nginx`, `/var/run`, `/tmp`, el archivo PID). La postura correcta es raíz de solo lectura más montajes escribibles explícitos y mínimos — no deshabilitar la protección.
- **Q9.4** — **Docker rootless** corre `dockerd` y los contenedores como un **usuario sin privilegios** usando user namespaces, así que el "root" del contenedor mapea a un UID no-root del host. Mitiga fundamentalmente el **breakout de daemon/contenedor → root del host**: incluso si el daemon o un contenedor es comprometido, el atacante tiene solo un usuario del host sin privilegios, no UID 0. Un contenedor *rootful* endurecido todavía tiene un daemon propiedad de root cuyo compromiso significa root del host.

### Ejercicio 10
- **Q10.1** — **Sin daemon + rootless por defecto.** Docker centraliza todo en un `dockerd` propiedad de root; Podman no tiene daemon — cada contenedor es hijo de un `conmon` por contenedor bajo el usuario invocante (típicamente no-root). Así que no hay un único daemon root como objetivo, y los contenedores pertenecen al usuario que los corrió (modelo fork/exec), no a un servicio privilegiado compartido.
- **Q10.2** — **Podman** → correr contenedores (y pods). **Buildah** → construir imágenes (Dockerfile o imperativo, sin daemon). **skopeo** → copiar e inspeccionar imágenes entre registries/almacenamiento.
- **Q10.3** — skopeo trabaja directamente con las **APIs de registry y los manifests/blobs de imagen**; copia capas de registry a registry (o hacia/desde almacenamiento OCI/dir local) sin desempaquetarlas en un runtime, así que no se requiere `dockerd`/`containerd` ni ejecución local de contenedores.
- **Q10.4** — **Podman.** `alias docker=podman` da una compatibilidad de CLI casi completa (`run`, `build`, `ps`, `images`, `compose` vía `podman-compose`/`podman compose`) sin daemon root. Lo que *no* da de forma transparente: semántica idéntica del socket del daemon para herramientas que hablan con `/var/run/docker.sock` (necesita el socket de Podman/`podman system service`), Swarm, y algunos plugins/comportamientos específicos de Docker.

</details>