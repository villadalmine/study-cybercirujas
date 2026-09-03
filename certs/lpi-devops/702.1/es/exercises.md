# 702.1 Gestión de Contenedores de Aplicación — Ejercicios Guiados

**Certificación:** LPI DevOps Tools Engineer (Examen 701-100, v2.0.0)
**Peso del objetivo:** 8.33
**Formato:** cada bloque es una secuencia de comandos que ejecutás realmente, seguida de preguntas de verificación. Todas las respuestas están en la sección plegable al final.

---

## Requisitos previos del laboratorio

Un host Linux con Docker Engine ≥ 24 o Podman ≥ 4.x, `curl`, y unos 3 GB de disco libre. Cada ejercicio es autocontenido y termina con su propia limpieza. Donde Podman difiere, la diferencia se señala — el examen evalúa la cadena de herramientas OCI, no un único proveedor.

```bash
mkdir -p ~/lab-702.1 && cd ~/lab-702.1
docker version --format '{{.Server.Version}}'   # or: podman version --format '{{.Version}}'
```

---

## Ejercicio 1 — La pila de runtime debajo de la CLI

Un contenedor no es un objeto de primera clase del kernel. Es un proceso con namespaces, cgroups, un rootfs proveniente de un sistema de archivos por capas, y un perfil LSM. Antes de gestionar contenedores debés saber qué implementación de cada uno provee tu host, porque cada límite que definas después aterriza en uno de ellos.

1. Imprimí los datos estructurales del daemon:

```bash
docker info --format '{{.ServerVersion}} storage={{.Driver}} cgroup=v{{.CgroupVersion}} driver={{.CgroupDriver}} runtime={{.DefaultRuntime}}'
```

```
27.3.1 storage=overlay2 cgroup=v2 driver=systemd runtime=runc
```

2. Mirá el árbol de procesos que el daemon construye para un contenedor en ejecución:

```bash
docker run -d --name probe alpine:3.20 sleep 600
ps -ef --forest | grep -A2 -E 'containerd-shim|dockerd' | head -20
```

```
root  1180     1  0 09:11 ?  00:00:04 /usr/bin/dockerd -H fd://
root  2044     1  0 09:12 ?  00:00:00 /usr/bin/containerd-shim-runc-v2 -namespace moby -id 9f3c... -address /run/containerd/containerd.sock
root  2066  2044  0 09:12 ?  00:00:00  \_ sleep 600
```

3. Confirmá que los namespaces son reales y por contenedor:

```bash
pid=$(docker inspect -f '{{.State.Pid}}' probe)
sudo ls -l /proc/$pid/ns/
sudo readlink /proc/$pid/ns/net /proc/self/ns/net
```

```
lrwxrwxrwx 1 root root 0 mnt -> 'mnt:[4026532584]'
lrwxrwxrwx 1 root root 0 net -> 'net:[4026532647]'
lrwxrwxrwx 1 root root 0 pid -> 'pid:[4026532586]'
lrwxrwxrwx 1 root root 0 uts -> 'uts:[4026532583]'
...
net:[4026532647]
net:[4026531840]
```

4. Encontrá el cgroup del contenedor y leé un límite en vivo desde él:

```bash
cat /proc/$pid/cgroup
cat /sys/fs/cgroup/system.slice/docker-$(docker inspect -f '{{.Id}}' probe).scope/pids.current
```

```
0::/system.slice/docker-9f3c1b8e....scope
1
```

5. Limpieza:

```bash
docker rm -f probe
```

> **Q1.1** `runc` no aparece en la salida de `ps` mientras el contenedor corre. ¿Por qué, y para qué existe `containerd-shim-runc-v2`?
> **Q1.2** El inodo del namespace `net` del contenedor difiere del del host, pero vos no creaste ninguna red. ¿A qué red se unió el contenedor, y qué cambiaría `--network host` en el paso 3?
> **Q1.3** Tu host reporta `cgroup=v1`. ¿Cuáles de los límites usados más adelante en este laboratorio (`--cpus`, `--memory`, `--pids-limit`, `--memory-swap`) cambian de comportamiento, y dónde los leerías en lugar de `/sys/fs/cgroup/<scope>/`?

---

## Ejercicio 2 — Anatomía de la imagen: manifest, config, capas, digest

Una "imagen" son tres artefactos separados en el registry: un manifest, un blob de config, y N blobs de capas. Confundir el *image ID* (un hash de la config local) con el *repository digest* (un hash del manifest tal como está almacenado en el registry) es la causa individual más común de los incidentes del tipo "pero si desplegué el mismo tag".

1. Descargá una imagen pequeña multicapa y listá lo que obtuviste:

```bash
docker pull nginx:1.27-alpine
docker image inspect nginx:1.27-alpine \
  --format 'ID={{.Id}}{{"\n"}}Digest={{index .RepoDigests 0}}{{"\n"}}Layers={{len .RootFS.Layers}}'
```

```
ID=sha256:1ae4bcd8b0a0f8f4a3a4dbd6ff3b3c1a70c0e2c4a1f1d0a5b3e9e2c1d4f6a7b8
Digest=nginx@sha256:41523187cf7d7a2f2677a80609d9caa14388bf5c1d2eaf7ab3eb0e5f8e0ef1b1
Layers=8
```

2. Mostrá cómo se produjo cada capa, y cuáles cuestan bytes:

```bash
docker history nginx:1.27-alpine --format 'table {{.Size}}\t{{.CreatedBy}}' | head -12
```

```
SIZE      CREATED BY
0B        CMD ["nginx" "-g" "daemon off;"]
0B        STOPSIGNAL SIGQUIT
0B        EXPOSE map[80/tcp:{}]
0B        ENTRYPOINT ["/docker-entrypoint.sh"]
1.62kB    COPY 30-tune-worker-processes.sh /docker-entrypoint.d/ # buildkit
...
44.7MB    RUN /bin/sh -c set -x  && apkArch="$(cat /etc/apk/arch)" ...
8.83MB    ADD alpine-minirootfs-3.20.3-x86_64.tar.gz / # buildkit
```

3. Leé el manifest crudo tal como lo sirve el registry (sin daemon involucrado):

```bash
skopeo inspect --raw docker://docker.io/library/nginx:1.27-alpine | head -20
```

```json
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "manifests": [
    { "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:0f2e0a4...", "size": 1741,
      "platform": { "architecture": "amd64", "os": "linux" } },
    { "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:9c1b7d3...", "size": 1741,
      "platform": { "architecture": "arm64", "os": "linux", "variant": "v8" } }
  ]
}
```

4. Fijá por digest y comprobá que el pin es inmutable:

```bash
docker pull nginx@sha256:41523187cf7d7a2f2677a80609d9caa14388bf5c1d2eaf7ab3eb0e5f8e0ef1b1
docker image ls --digests nginx
```

```
REPOSITORY  TAG          DIGEST                     IMAGE ID       SIZE
nginx       1.27-alpine  sha256:41523187cf7d...     1ae4bcd8b0a0   52.5MB
nginx       <none>       sha256:41523187cf7d...     1ae4bcd8b0a0   52.5MB
```

5. Inspeccioná las capas deduplicadas en disco:

```bash
docker system df -v | head -6
```

> **Q2.1** El paso 1 imprimió dos valores `sha256:` distintos. ¿Cuál identifica bytes que existen en el registry, y cuál existe solo en este host? ¿Cuál escribirías en un manifest de producción?
> **Q2.2** El paso 3 devolvió un *índice*, no un manifest. ¿Qué contiene ese objeto, y qué haría `docker pull` con él en un host arm64?
> **Q2.3** Varias filas de `docker history` muestran `0B`. ¿Siguen siendo capas? Explicalo en términos de capas del manifest vs. entradas de history de la config.
> **Q2.4** Reconstruís una imagen a partir del Dockerfile idéntico en dos máquinas y obtenés dos image IDs distintos. Dá dos razones por las que esto ocurre incluso sin cambios en el código fuente.

---

## Ejercicio 3 — Construcción: orden de caché, multi-stage y fuga de build-args

1. Creá una construcción deliberadamente mal ordenada:

```bash
mkdir -p build-lab && cd build-lab
cat > requirements.txt <<'EOF'
flask==3.0.3
EOF
cat > app.py <<'EOF'
from flask import Flask
app = Flask(__name__)

@app.get("/healthz")
def healthz():
    return {"status": "ok"}, 200

@app.get("/")
def index():
    return {"service": "demo", "version": "1"}, 200
EOF
cat > Dockerfile <<'EOF'
FROM python:3.12-slim
WORKDIR /app
COPY . /app
RUN pip install --no-cache-dir -r requirements.txt
CMD ["python", "-m", "flask", "run", "--host=0.0.0.0"]
EOF

docker build -t demo:bad .
```

2. Cambiá solamente el código fuente de la aplicación y reconstruí, midiendo el tiempo:

```bash
sed -i 's/"version": "1"/"version": "2"/' app.py
time docker build -t demo:bad .
```

```
 => [3/4] COPY . /app                                          0.1s
 => [4/4] RUN pip install --no-cache-dir -r requirements.txt   9.4s
real    0m11.7s
```

3. Reordená para que las dependencias queden cacheadas independientemente del código fuente, y agregá un `.dockerignore`:

```bash
cat > Dockerfile <<'EOF'
FROM python:3.12-slim AS base
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py ./
ENV FLASK_APP=app.py
EXPOSE 5000
CMD ["python", "-m", "flask", "run", "--host=0.0.0.0"]
EOF
printf '.git\n__pycache__\n*.pyc\n.env\n' > .dockerignore

docker build -t demo:good .
sed -i 's/"version": "2"/"version": "3"/' app.py
time docker build -t demo:good .
```

```
 => CACHED [base 3/4] RUN pip install --no-cache-dir -r requirements.txt   0.0s
 => [base 4/4] COPY app.py ./                                             0.1s
real    0m1.3s
```

4. Ahora filtrá un secreto de la forma en que lo hacen los pipelines reales, y encontralo:

```bash
cat > Dockerfile.leak <<'EOF'
FROM alpine:3.20
ARG API_TOKEN
RUN echo "fetching with $API_TOKEN" > /tmp/build.log
EOF
docker build -f Dockerfile.leak --build-arg API_TOKEN=s3cr3t-prod-token -t demo:leak .
docker history --no-trunc demo:leak | grep -o 's3cr3t[^ "]*'
```

```
s3cr3t-prod-token
```

5. Hacelo correctamente con un secret mount de BuildKit, y verificá que la fuga desapareció:

```bash
echo -n 's3cr3t-prod-token' > token.txt
cat > Dockerfile.safe <<'EOF'
# syntax=docker/dockerfile:1
FROM alpine:3.20
RUN --mount=type=secret,id=api_token \
    wc -c < /run/secrets/api_token > /tmp/token.len
EOF
DOCKER_BUILDKIT=1 docker build -f Dockerfile.safe --secret id=api_token,src=token.txt -t demo:safe .
docker history --no-trunc demo:safe | grep -c 's3cr3t' ; docker run --rm demo:safe cat /tmp/token.len
```

```
0
17
```

6. Construí una imagen multi-stage y compará tamaños:

```bash
cat > Dockerfile.multi <<'EOF'
FROM golang:1.23-alpine AS build
WORKDIR /src
RUN cat > main.go <<'GO'
package main
import ("fmt"; "net/http")
func main() {
  http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) { fmt.Fprintln(w, "ok") })
  http.ListenAndServe(":8080", nil)
}
GO
RUN go mod init demo && CGO_ENABLED=0 go build -o /out/server main.go

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/server /server
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/server"]
EOF
docker build -f Dockerfile.multi -t demo:multi .
docker image ls --format 'table {{.Repository}}:{{.Tag}}\t{{.Size}}' | grep -E 'demo|golang'
```

```
demo:multi        6.31MB
golang:1.23-alpine 249MB
```

> **Q3.1** En el paso 2, `COPY . /app` invalidó la caché. ¿*Qué* hashea BuildKit exactamente para decidir que una instrucción `COPY` es un acierto de caché?
> **Q3.2** ¿Por qué agregar `.dockerignore` importó para la corrección de la caché y no solamente para el tamaño del contexto de build? Nombrá un archivo que de otro modo causaría un fallo de caché en la máquina de cada desarrollador.
> **Q3.3** El secreto del paso 4 nunca fue `COPY`ado a la imagen y el archivo vive en `/tmp`. Explicá las dos formas independientes en que sigue siendo recuperable por cualquiera que descargue `demo:leak`.
> **Q3.4** `demo:multi` no tiene shell ni gestor de paquetes. Indicá un costo operativo concreto de eso y la técnica de diagnóstico del Ejercicio 10 que lo elimina.
> **Q3.5** `docker build --target build -t demo:builder .` — ¿qué produciría eso, y dá un uso legítimo en CI.

---

## Ejercicio 4 — PID 1, señales y apagado limpio

Los contenedores se detienen por señal. Si el PID 1 de tu contenedor no maneja `SIGTERM`, cada despliegue se convierte en un kill duro de 10 segundos y cada petición en vuelo se descarta.

1. Escribí un servicio que maneje la terminación correctamente:

```bash
cd ~/lab-702.1 && mkdir -p signals && cd signals
cat > app.sh <<'EOF'
#!/bin/sh
term() { echo "SIGTERM received: draining"; sleep 1; echo "drained"; exit 0; }
trap term TERM
echo "started as pid $$"
while :; do sleep 1 & wait $!; done
EOF
chmod +x app.sh
```

2. Construí la variante en **forma shell**:

```bash
cat > Dockerfile.shell <<'EOF'
FROM alpine:3.20
COPY app.sh /app.sh
ENTRYPOINT /app.sh
EOF
docker build -f Dockerfile.shell -t sig:shell .
docker run -d --name s-shell sig:shell
docker exec s-shell ps -o pid,args
```

```
PID   COMMAND
    1 /bin/sh -c /app.sh
    7 /bin/sh /app.sh
   14 sleep 1
```

3. Medí el tiempo del stop y leé el código de salida:

```bash
time docker stop s-shell ; docker inspect -f '{{.State.ExitCode}}' s-shell ; docker logs s-shell
```

```
real    0m10.4s
137
started as pid 7
```

4. Construí la variante en **forma exec** y repetí:

```bash
cat > Dockerfile.exec <<'EOF'
FROM alpine:3.20
COPY app.sh /app.sh
STOPSIGNAL SIGTERM
ENTRYPOINT ["/app.sh"]
EOF
docker build -f Dockerfile.exec -t sig:exec .
docker run -d --name s-exec sig:exec
docker exec s-exec ps -o pid,args | head -3
time docker stop s-exec ; docker inspect -f '{{.State.ExitCode}}' s-exec ; docker logs s-exec
```

```
PID   COMMAND
    1 /bin/sh /app.sh
    7 sleep 1

real    0m1.3s
0
started as pid 1
SIGTERM received: draining
drained
```

5. Mostrá la recolección de zombies, el otro deber del PID 1:

```bash
docker run --rm alpine:3.20 sh -c 'sleep 0.1 & sleep 0.5; ps -o pid,stat,args'
docker run --rm --init alpine:3.20 sh -c 'sleep 0.1 & sleep 0.5; ps -o pid,stat,args'
```

```
PID   STAT COMMAND
    1 S    sh -c sleep 0.1 & sleep 0.5; ps ...
    7 Z    [sleep]
...
PID   STAT COMMAND
    1 S    /sbin/docker-init -- sh -c ...
    7 S    sh -c ...
```

6. Extendé el período de gracia como lo necesita un servicio de drenaje lento:

```bash
docker run -d --name s-slow --stop-timeout 30 sig:exec
docker stop s-slow ; docker rm -f s-shell s-exec s-slow
```

> **Q4.1** En el paso 2, el PID 1 era `/bin/sh -c /app.sh` y el script corría como PID 7. Dos mecanismos independientes impidieron entonces un apagado limpio — nombrá ambos.
> **Q4.2** El código de salida 137 y el código de salida 143 significan ambos "matado". Descomponé cada número y decí cuál indica que tu handler funcionó.
> **Q4.3** `nginx` viene con `STOPSIGNAL SIGQUIT`. ¿Por qué `SIGTERM` sería el default equivocado para él, y dónde se registra `STOPSIGNAL` para que el runtime pueda leerlo?
> **Q4.4** Un contenedor con un `ENTRYPOINT` en forma shell que genera workers en segundo plano filtra zombies. `--init` arregla la recolección, pero no el reenvío de señales a esos workers. ¿Por qué no, y cuál es la corrección adecuada dentro de la imagen?

---

## Ejercicio 5 — Redes: bridges, DNS embebido y puertos publicados

1. Comprobá que el bridge por defecto no tiene descubrimiento de servicios:

```bash
docker run -d --name db  alpine:3.20 sleep 600
docker run -d --name web alpine:3.20 sleep 600
docker exec web getent hosts db ; echo "exit=$?"
```

```
exit=2
```

2. Creá una red definida por el usuario y repetí:

```bash
docker network create --driver bridge --subnet 172.28.0.0/24 appnet
docker rm -f db web
docker run -d --name db  --network appnet alpine:3.20 sleep 600
docker run -d --name web --network appnet --network-alias frontend alpine:3.20 sleep 600
docker exec web getent hosts db
docker exec web cat /etc/resolv.conf
```

```
172.28.0.2        db
nameserver 127.0.0.11
options ndots:0
```

3. Inspeccioná el plan de direcciones desde el lado del daemon:

```bash
docker network inspect appnet -f '{{range $k,$v := .Containers}}{{$v.Name}} {{$v.IPv4Address}}{{"\n"}}{{end}}'
```

```
db 172.28.0.2/24
web 172.28.0.3/24
```

4. Publicá un puerto y mirá qué hizo realmente el kernel:

```bash
docker run -d --name site -p 127.0.0.1:8080:80 nginx:1.27-alpine
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/
sudo iptables -t nat -S DOCKER | grep 8080
ss -lntp | grep 8080
```

```
200
-A DOCKER ! -i docker0 -p tcp -m tcp --dport 8080 -j DNAT --to-destination 172.17.0.3:80
LISTEN 0 4096 127.0.0.1:8080 0.0.0.0:* users:(("docker-proxy",pid=5120,fd=4))
```

5. Contrastá con la red de host:

```bash
docker run -d --name hostnet --network host nginx:1.27-alpine
docker exec hostnet ip -o addr show | wc -l   # host interfaces, not 2
docker run -d --name hostnet2 --network host nginx:1.27-alpine ; docker logs hostnet2 | tail -2
```

```
bind() to 0.0.0.0:80 failed (98: Address in use)
```

6. Limpieza:

```bash
docker rm -f db web site hostnet hostnet2 ; docker network rm appnet
```

> **Q5.1** El paso 1 falló y el paso 2 tuvo éxito sin cambiar la imagen. ¿Qué componente aparece en `127.0.0.11` en una red definida por el usuario, y por qué es una dirección link-local dentro del netns del contenedor en lugar de un servidor real?
> **Q5.2** Publicás `-p 8080:80` en un host con una regla de `ufw`/`firewalld` que deniega el 8080 desde afuera, y el puerto es alcanzable igual. Explicá la razón de ordenamiento de cadenas y nombrá la cadena de iptables destinada a tus reglas.
> **Q5.3** `--network host` eliminó el namespace de red. ¿Cuáles de estos siguen aislando al contenedor: mount ns, PID ns, límites de cgroup, bindeos de puertos? Respondé cada uno.
> **Q5.4** Un contenedor necesita alcanzar un servicio en el host mismo. Dá el enfoque portable en Docker Desktop/Podman y la alternativa nativa de Linux.
> **Q5.5** ¿Cuál es la diferencia entre `--network-alias frontend` y `--name frontend` para la resolución, y cuándo necesitás el alias?

---

## Ejercicio 6 — Almacenamiento: bind mounts, volúmenes con nombre, copy-up, tmpfs

1. Observá cómo un volumen con nombre realiza el *copy-up* desde la imagen:

```bash
docker volume create sitedata
docker run -d --name v1 -v sitedata:/usr/share/nginx/html -p 8081:80 nginx:1.27-alpine
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8081/
docker run --rm -v sitedata:/data alpine:3.20 ls /data
```

```
200
50x.html
index.html
```

2. Hacé lo mismo con un bind mount y observá el comportamiento opuesto:

```bash
mkdir -p ~/lab-702.1/html-empty
docker run -d --name v2 -v ~/lab-702.1/html-empty:/usr/share/nginx/html -p 8082:80 nginx:1.27-alpine
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8082/
```

```
403
```

3. Localizá un volumen con nombre en el host y confirmá que sobrevive al contenedor:

```bash
docker volume inspect sitedata -f '{{.Mountpoint}}'
docker rm -f v1
sudo ls $(docker volume inspect sitedata -f '{{.Mountpoint}}')
```

```
/var/lib/docker/volumes/sitedata/_data
50x.html  index.html
```

4. Ejecutá con un sistema de archivos raíz inmutable — el default de producción:

```bash
docker run -d --name ro \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=64m \
  --tmpfs /var/cache/nginx --tmpfs /var/run \
  -v sitedata:/usr/share/nginx/html:ro \
  -p 8083:80 nginx:1.27-alpine
docker exec ro sh -c 'touch /etc/canary' ; echo "exit=$?"
docker exec ro sh -c 'touch /tmp/canary && mount | grep " /tmp "'
```

```
touch: /etc/canary: Read-only file system
exit=1
tmpfs on /tmp type tmpfs (rw,nosuid,nodev,noexec,relatime,size=65536k,...)
```

5. En un host con SELinux (Fedora/RHEL), observá el requisito de reetiquetado:

```bash
mkdir -p ~/lab-702.1/selinux-demo && echo hello > ~/lab-702.1/selinux-demo/f.txt
docker run --rm -v ~/lab-702.1/selinux-demo:/d alpine:3.20 cat /d/f.txt   # may fail: Permission denied
ls -Z ~/lab-702.1/selinux-demo/f.txt
docker run --rm -v ~/lab-702.1/selinux-demo:/d:Z alpine:3.20 cat /d/f.txt
ls -Z ~/lab-702.1/selinux-demo/f.txt
```

```
unconfined_u:object_r:user_home_t:s0    f.txt
hello
system_u:object_r:container_file_t:s0:c214,c806    f.txt
```

6. Limpieza:

```bash
docker rm -f v2 ro ; docker volume rm sitedata
```

> **Q6.1** Enunciá la regla que explica tanto el paso 1 (el contenido apareció) como el paso 2 (el contenido desapareció), incluyendo la precondición exacta para el copy-up.
> **Q6.2** El paso 3 muestra que el volumen sobrevive al contenedor. ¿Qué flag de `docker rm` borra los volúmenes anónimos, y por qué no borra `sitedata`?
> **Q6.3** En el paso 4 tuviste que agregar tres montajes `--tmpfs`. ¿Cuál es la forma sistemática de descubrir en qué rutas escribe una imagen desconocida antes de que definas `--read-only`?
> **Q6.4** Explicá la diferencia entre `:z` y `:Z` y describí la falla concreta causada por usar `:Z` en `/home/user/src` compartido con un segundo contenedor.
> **Q6.5** Un directorio montado por bind muestra archivos propiedad de `nobody` dentro del contenedor. Dá la causa bajo Podman rootless y el flag que lo corrige.

---

## Ejercicio 7 — Límites de recursos y comportamiento OOM

1. Verificá que los límites aterrizan en los archivos de cgroup v2:

```bash
docker run --rm -m 64m --cpus 0.5 --pids-limit 16 alpine:3.20 sh -c \
  'cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/cpu.max /sys/fs/cgroup/pids.max'
```

```
67108864
50000 100000
16
```

2. Provocá un OOM kill real y leé la evidencia forense:

```bash
docker run --name oom -m 64m --memory-swap 64m --shm-size 128m alpine:3.20 \
  sh -c 'dd if=/dev/zero of=/dev/shm/balloon bs=1M count=128'
echo "exit=$?"
docker inspect oom -f 'OOMKilled={{.State.OOMKilled}} ExitCode={{.State.ExitCode}} Status={{.State.Status}}'
sudo dmesg | tail -3
```

```
Killed
exit=137
OOMKilled=true ExitCode=137 Status=exited
[ 8123.4] Memory cgroup out of memory: Killed process 20441 (dd) total-vm:...,anon-rss:...
```

3. Alcanzá el límite de PIDs:

```bash
docker run --rm --pids-limit 16 alpine:3.20 sh -c \
  'i=0; while [ $i -lt 50 ]; do sleep 30 & i=$((i+1)); done; echo spawned=$i'
```

```
sh: can't fork: Resource temporarily unavailable
```

4. Medí la cuota de CPU en lugar de confiar en ella:

```bash
docker run --rm --cpus 0.5 alpine:3.20 sh -c \
  'time (i=0; while [ $i -lt 300000 ]; do i=$((i+1)); done)'
docker run --rm --cpus 2 alpine:3.20 sh -c \
  'time (i=0; while [ $i -lt 300000 ]; do i=$((i+1)); done)'
```

5. Observá el consumo en vivo y los procesos por contenedor:

```bash
docker run -d --name busy --cpus 0.25 alpine:3.20 sh -c 'while :; do :; done'
docker stats --no-stream busy
docker top busy
docker rm -f busy oom
```

```
CONTAINER  CPU %   MEM USAGE / LIMIT   MEM %   PIDS
busy       24.93%  512KiB / 15.35GiB   0.00%   1
```

> **Q7.1** `--cpus 0.5` produjo `50000 100000` en `cpu.max`. Leé esos dos números en voz alta en términos del kernel, y decí qué le pasa a un hilo que agota la cuota a mitad del período.
> **Q7.2** ¿Por qué el ejercicio pasó `--memory-swap 64m` explícitamente? ¿Cuál es el default cuando solo se da `-m`, y cómo haría el omitirlo que la prueba de OOM fuera no determinista?
> **Q7.3** `--cpus` y `--cpu-shares` son ambos controles de CPU. ¿Cuál es un techo duro, cuál es un peso, y cuál *no tiene efecto* en un host ocioso?
> **Q7.4** `docker stats` reportó `MEM USAGE 512KiB / 15.35GiB` para un contenedor con `--cpus 0.25` y sin límite de memoria. ¿Por qué la columna de límite es el total del host, y qué riesgo crea eso en un nodo compartido?
> **Q7.5** Tu aplicación es una JVM en un contenedor con `-m 512m` y es matada por OOM a pesar de `-Xmx256m`. Dá dos causas plausibles enraizadas en lo que el cgroup de memoria cuenta realmente.

---

## Ejercicio 8 — Postura de seguridad: usuario, capabilities, privilegios

1. Mirá qué se le otorga a un contenedor por defecto:

```bash
docker run --rm alpine:3.20 sh -c 'id; grep CapEff /proc/self/status'
docker run --rm alpine:3.20 sh -c 'apk add -q libcap-ng 2>/dev/null; capsh --decode=$(grep CapEff /proc/self/status | cut -f2)' 2>/dev/null \
  || docker run --rm alpine:3.20 sh -c 'grep Cap /proc/self/status'
```

```
uid=0(root) gid=0(root) groups=0(root),1(bin),...
CapEff:	00000000a80425fb
```

2. Descartá todo y volvé a agregar solo lo necesario:

```bash
docker run --rm --cap-drop ALL alpine:3.20 sh -c 'ping -c1 -W1 127.0.0.1 >/dev/null 2>&1; echo ping=$?'
docker run --rm --cap-drop ALL --cap-add NET_RAW alpine:3.20 sh -c 'ping -c1 -W1 127.0.0.1 >/dev/null 2>&1; echo ping=$?'
```

```
ping=1
ping=0
```

3. Ejecutá como un UID no-root que no existe en `/etc/passwd`:

```bash
docker run --rm -u 10001:10001 alpine:3.20 sh -c 'id; touch /root/x 2>&1 | head -1'
```

```
uid=10001 gid=10001
touch: /root/x: Permission denied
```

4. Horneá el usuario no-root dentro de la imagen — la única versión que sobrevive a que alguien se olvide del flag:

```bash
cd ~/lab-702.1 && mkdir -p sec && cd sec
cat > Dockerfile <<'EOF'
FROM alpine:3.20
RUN addgroup -g 10001 app && adduser -D -u 10001 -G app app \
 && mkdir -p /var/lib/app && chown app:app /var/lib/app
USER 10001:10001
WORKDIR /var/lib/app
ENTRYPOINT ["/bin/sh","-c","id; sleep 300"]
EOF
docker build -t sec:nonroot .
docker run -d --name s1 --cap-drop ALL --security-opt no-new-privileges \
  --read-only --tmpfs /tmp sec:nonroot
docker logs s1
```

```
uid=10001(app) gid=10001(app) groups=10001(app)
```

5. Demostrá `no-new-privileges` contra un binario setuid:

```bash
docker run --rm -u 10001 alpine:3.20 sh -c 'ls -l /bin/busybox; su -c id 2>&1 | head -1'
docker run --rm -u 10001 --security-opt no-new-privileges alpine:3.20 sh -c 'su -c id 2>&1 | head -1'
```

6. Mostrá qué quita realmente `--privileged` (ejecutalo una vez, después nunca en producción):

```bash
docker run --rm alpine:3.20 sh -c 'ls /dev | wc -l; mount -t tmpfs none /mnt 2>&1 | head -1'
docker run --rm --privileged alpine:3.20 sh -c 'ls /dev | wc -l; mount -t tmpfs none /mnt && echo MOUNTED; head -1 /dev/sda 2>&1 | head -c 40'
```

```
16
mount: permission denied (are you root?)
...
408
MOUNTED
```

7. Compará el mapeo de identidad de Podman rootless:

```bash
podman unshare cat /proc/self/uid_map
grep "^$(id -un):" /etc/subuid
podman run --rm alpine:3.20 id
podman run --rm --userns=keep-id alpine:3.20 id
```

```
         0       1000          1
         1     100000      65536
dalmine:100000:65536
uid=0(root) gid=0(root)
uid=1000 gid=1000
```

8. Limpieza: `docker rm -f s1`

> **Q8.1** El paso 1 mostró `uid=0` dentro del contenedor. ¿Es ese el root del host? Respondé por separado para Docker rootful y Podman rootless, haciendo referencia al uid_map del paso 7.
> **Q8.2** `--cap-drop ALL` rompió `ping` pero el proceso seguía siendo uid 0. Explicá la relación entre las capabilities y el uid root en un kernel moderno.
> **Q8.3** Tu aplicación debe bindear el puerto 80. Dá tres formas de lograrlo sin otorgar root completo, y ordenalas por radio de impacto.
> **Q8.4** ¿Qué establece exactamente `--security-opt no-new-privileges`, y por qué es el flag de endurecimiento individual más barato cuando se combina con un `USER` no-root?
> **Q8.5** `-u 10001` en tiempo de ejecución y `USER 10001` en el Dockerfile producen ambos el uid 10001. Dá dos razones por las que la versión del Dockerfile es más fuerte, y una cosa que aun así no garantiza.
> **Q8.6** La documentación de un proveedor dice "ejecutar con `--privileged`". Enumerá qué desactiva ese flag y describí cómo lo reemplazarías con un conjunto mínimo de flags.

---

## Ejercicio 9 — Health checks, políticas de reinicio, logging y Compose

1. Construí una imagen con un health check y observá la máquina de estados:

```bash
cd ~/lab-702.1 && mkdir -p compose && cd compose
cat > Dockerfile.web <<'EOF'
FROM nginx:1.27-alpine
HEALTHCHECK --interval=5s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1/ || exit 1
EOF
docker build -f Dockerfile.web -t hc:web .
docker run -d --name hc hc:web
for i in 1 2 3 4; do docker inspect -f '{{.State.Health.Status}}' hc; sleep 4; done
```

```
starting
starting
healthy
healthy
```

2. Rompelo y leé la salida registrada de la sonda:

```bash
docker exec hc nginx -s stop ; sleep 20
docker inspect -f '{{.State.Health.Status}} failing={{.State.Health.FailingStreak}}' hc
docker inspect -f '{{(index .State.Health.Log 0).Output}}' hc
docker ps -a --filter name=hc --format '{{.Status}}'
```

```
unhealthy failing=4
Exited (1)
```

3. Probá las políticas de reinicio:

```bash
docker run -d --name flap --restart on-failure:3 alpine:3.20 sh -c 'sleep 2; exit 1'
sleep 25
docker inspect -f 'restarts={{.RestartCount}} status={{.State.Status}} exit={{.State.ExitCode}}' flap
```

```
restarts=3 status=exited exit=1
```

4. Acotá los logs antes de que llenen el disco:

```bash
docker run -d --name loud \
  --log-driver json-file --log-opt max-size=1m --log-opt max-file=3 \
  alpine:3.20 sh -c 'i=0; while :; do echo "line $i $(head -c 200 /dev/zero | tr "\0" "x")"; i=$((i+1)); done'
sleep 10
sudo ls -lh /var/lib/docker/containers/$(docker inspect -f '{{.Id}}' loud)/ | grep json.log
docker logs --tail 2 --timestamps loud
docker rm -f loud flap hc
```

```
-rw-r----- 1 root root 1.0M ... 9f3c...-json.log
-rw-r----- 1 root root 1.0M ... 9f3c...-json.log.1
-rw-r----- 1 root root 1.0M ... 9f3c...-json.log.2
2026-09-03T09:41:22.118Z line 84213 xxxxxxxx...
```

5. Componé todo el conjunto, con un ordenamiento que depende de la salud y no del arranque:

```bash
cat > compose.yaml <<'EOF'
name: lab702
services:
  cache:
    image: redis:7-alpine
    command: ["redis-server","--save","","--appendonly","no"]
    healthcheck:
      test: ["CMD","redis-cli","ping"]
      interval: 5s
      timeout: 3s
      retries: 5
    networks: [back]
    read_only: true
    tmpfs: [/tmp]

  web:
    build:
      context: .
      dockerfile: Dockerfile.web
    depends_on:
      cache:
        condition: service_healthy
    ports: ["127.0.0.1:8090:80"]
    networks: [back]
    deploy:
      resources:
        limits:
          cpus: "0.50"
          memory: 128M
    logging:
      driver: json-file
      options: { max-size: "1m", max-file: "3" }
    restart: unless-stopped
networks:
  back: {}
EOF

docker compose config --quiet && echo "schema OK"
docker compose up -d --wait
docker compose ps
```

```
schema OK
NAME             SERVICE  STATUS                   PORTS
lab702-cache-1   cache    Up 22 seconds (healthy)
lab702-web-1     web      Up 12 seconds (healthy)  127.0.0.1:8090->80/tcp
```

6. Verificá los límites que aplicó Compose y el descubrimiento basado en nombres:

```bash
docker inspect lab702-web-1 -f 'mem={{.HostConfig.Memory}} cpuquota={{.HostConfig.NanoCpus}}'
docker compose exec web getent hosts cache
docker compose logs --tail 3 cache
docker compose down -v
```

```
mem=134217728 cpuquota=500000000
172.29.0.2        cache lab702-cache-1
```

> **Q9.1** En el paso 2 el contenedor estaba `unhealthy` pero `docker ps` seguía mostrándolo `Up`. ¿Qué hace Docker Engine por sí mismo con un contenedor unhealthy, y qué dos sistemas *sí* actúan sobre ese estado?
> **Q9.2** `restart: unless-stopped` vs `restart: always` — describí el único escenario, que involucra un reinicio del daemon, en el que se comportan distinto.
> **Q9.3** `--restart on-failure:3` se detuvo después de 3 intentos. ¿Cuál es el intervalo entre intentos, y por qué esa política es peligrosa con un `HEALTHCHECK` que no tiene `--start-period`?
> **Q9.4** Cambiás a `--log-driver journald`. ¿Qué se rompe de la verificación del paso 4, y qué drivers de log mantienen `docker logs` funcionando?
> **Q9.5** Explicá por qué `depends_on: condition: service_healthy` sigue siendo insuficiente como garantía a nivel de aplicación, y qué debe implementar la aplicación de todos modos.
> **Q9.6** El archivo de Compose usó `deploy.resources.limits`. Bajo `docker compose up` (no Swarm), ¿se respeta eso? Justificalo a partir de la salida de `docker inspect` del paso 6.

---

## Ejercicio 10 — Diagnosticar un contenedor en el que no podés entrar por shell

La imagen distroless del Ejercicio 3 no tiene shell. Esta es la técnica que hace que eso sea aceptable.

1. Arrancá el servicio sin shell y confirmá que el enfoque obvio falla:

```bash
cd ~/lab-702.1/build-lab
docker run -d --name svc -p 8091:8080 demo:multi
curl -s http://127.0.0.1:8091/ ; docker exec -it svc sh
```

```
ok
OCI runtime exec failed: exec failed: unable to start container process: exec: "sh": executable file not found in $PATH
```

2. Conectá un contenedor completamente equipado a los *mismos namespaces*:

```bash
docker run -it --rm \
  --network container:svc \
  --pid container:svc \
  --cap-add SYS_PTRACE \
  nicolaka/netshoot \
  sh -c 'ps -ef; ss -lntp; wget -qO- http://127.0.0.1:8080/'
```

```
PID   USER     COMMAND
    1 65532    /server
   16 root     sh -c ps -ef; ss -lntp; ...
State  Recv-Q Send-Q Local Address:Port  Process
LISTEN 0      4096        *:8080         users:(("server",pid=1,fd=3))
ok
```

3. Alcanzá el sistema de archivos del target desde el host, sin un shell en la imagen:

```bash
pid=$(docker inspect -f '{{.State.Pid}}' svc)
sudo ls /proc/$pid/root/
sudo cat /proc/$pid/environ | tr '\0' '\n' | head -3
sudo nsenter -t $pid -n ss -lntp
```

```
etc  server  var
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
HOSTNAME=4b8c2d1e9a77
```

4. Diferenciá el rootfs en ejecución contra la imagen — la pregunta de auditoría "¿qué cambió en producción?":

```bash
docker diff svc | head
docker inspect svc -f '{{json .State}}' | python3 -m json.tool | head -12
```

5. Observá el stream de eventos del daemon mientras algo falla:

```bash
docker events --since 5m --filter container=svc --format '{{.Time}} {{.Action}}' &
docker kill --signal SIGKILL svc ; sleep 1 ; kill %1
docker inspect svc -f 'exit={{.State.ExitCode}} oom={{.State.OOMKilled}} err={{.State.Error}}'
```

```
1756890123 kill
1756890123 die
exit=137 oom=false err=
```

6. Exportá los bytes exactos para análisis forense offline:

```bash
docker commit svc svc:postmortem
docker export svc -o svc-rootfs.tar ; tar -tf svc-rootfs.tar | head -5
docker rm -f svc ; docker rmi svc:postmortem ; rm -f svc-rootfs.tar
```

> **Q10.1** El paso 2 compartió `--network` y `--pid` pero no el namespace de montaje. ¿Qué diagnósticos habilita eso, y cuáles *no*?
> **Q10.2** `/proc/$pid/root/` mostró el sistema de archivos del contenedor desde el host. ¿Qué característica del kernel hace que esa ruta se resuelva dentro de otro namespace de montaje, y cuál es el único requisito previo para que funcione?
> **Q10.3** `docker export` y `docker save` producen ambos un tar. Indicá la diferencia de contenido y cuál preserva las capas y los metadatos de la imagen.
> **Q10.4** `docker inspect` reportó `exit=137 oom=false`. Dos causas distintas producen 137 — distinguilas usando exactamente estos campos.
> **Q10.5** En Kubernetes el equivalente del paso 2 es un solo comando. Nombralo y decí qué comparte con el contenedor target por defecto.

---

## Limpieza

```bash
docker rm -f $(docker ps -aq --filter label=lab=702.1) 2>/dev/null
docker compose -f ~/lab-702.1/compose/compose.yaml down -v 2>/dev/null
docker image rm demo:bad demo:good demo:leak demo:safe demo:multi sig:shell sig:exec sec:nonroot hc:web 2>/dev/null
docker system prune -f
docker system df
```

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1

**A1.1** `runc` no es un daemon; es un binario de un solo disparo. Configura namespaces, cgroups, etiquetas seccomp/LSM y el rootfs, hace `exec()` del entrypoint del contenedor, y luego termina. Nada de `runc` permanece en el árbol de procesos. El shim (`containerd-shim-runc-v2`) es lo que queda: se convierte en el padre del PID 1, mantiene el stdio/TTY del contenedor, reporta el estado de salida, y — críticamente — permite que `containerd` y `dockerd` sean reiniciados o actualizados sin matar los contenedores en ejecución, porque los padres de los contenedores son shims, no el daemon.

**A1.2** El contenedor se unió a la red bridge por defecto (`docker0` / `bridge`), y por eso obtuvo su propio namespace `net` con un par veth hacia ese bridge. Con `--network host` el enlace simbólico del namespace `net` del contenedor sería *idéntico* al del host — el mismo número de inodo — porque no se crea ningún namespace de red nuevo.

**A1.3** Los cuatro siguen funcionando, pero se escriben en una jerarquía distinta. Bajo cgroup v1 los controladores son montajes separados: memoria en `/sys/fs/cgroup/memory/docker/<id>/memory.limit_in_bytes` y `memory.memsw.limit_in_bytes`, CPU en `/sys/fs/cgroup/cpu/docker/<id>/cpu.cfs_quota_us` + `cpu.cfs_period_us`, pids en `/sys/fs/cgroup/pids/docker/<id>/pids.max`. Diferencias de comportamiento: en v1 `memsw` cuenta memoria+swap juntas (así que la semántica de `--memory-swap` difiere), y v1 no tiene un mecanismo unificado de presión `memory.high`, ni PSI por cgroup apropiado, y los contenedores rootless no pueden obtener límites de recursos en absoluto sin cgroup v2 + delegación de systemd.

### Ejercicio 2

**A2.1** `Digest` (la entrada de `RepoDigests`) es la dirección de contenido del *manifest* tal como lo sirve el registry — los mismos bytes en todas partes, y el único valor que sobrevive a que se mueva un tag. `Id` es el digest local del *blob de config de la imagen*, calculado por este daemon; no es por lo que hacés pull. Los manifests de producción fijan `image@sha256:<manifest-digest>`.

**A2.2** Es un índice de imagen (lista de manifests): una lista de manifests por plataforma más sus campos `platform`. `docker pull` en arm64 lee el índice, selecciona la entrada con `architecture: arm64`, y descarga solo ese manifest y sus capas. Por lo tanto el tag resuelve a bytes distintos en hosts distintos — una razón más por la que un tag no es una identidad.

**A2.3** No. Esas filas son *entradas de history* en la config de la imagen, que registran instrucciones de solo metadatos (`CMD`, `ENV`, `EXPOSE`, `LABEL`, `ENTRYPOINT`, `WORKDIR`) que cambian el JSON de config y no producen diferencia en el sistema de archivos. `len .RootFS.Layers` (8) cuenta las capas reales; `docker history` imprimió más filas que eso. Solo las instrucciones que escriben en el sistema de archivos (`RUN`, `COPY`, `ADD`) crean capas.

**A2.4** (1) Marcas de tiempo: sin `SOURCE_DATE_EPOCH` / flags de build reproducible, los campos `created` y las mtimes de los archivos difieren, cambiando el hash de la config. (2) Entradas no fijadas: `FROM python:3.12-slim` o `apt-get install`/`pip install` sin lockfiles resuelven a bytes upstream distintos en momentos distintos. También el orden/los permisos de los archivos del contexto de build, y versiones distintas de BuildKit emitiendo metadatos distintos.

### Ejercicio 3

**A3.1** Para `COPY`/`ADD`, BuildKit hashea el *contenido* de los archivos coincidentes en el contexto de build — un checksum sobre el contenido de cada archivo más su ruta, modo, uid/gid — no la mtime. La clave de caché es ese checksum combinado con la clave de caché del stage padre y la cadena literal de la instrucción. Un `COPY . /app` toma por lo tanto cualquier cambio en cualquier parte del contexto como un fallo de caché.

**A3.2** Porque el checksum cubre todo lo que hay en el contexto, las rutas volátiles no ignoradas causan fallos espurios y pueden enviar secretos silenciosamente. `.git/` es el clásico: cambia en cada commit, fetch, o incluso `git status` (mtime del índice/refs), así que cada desarrollador y cada ejecución de CI obtiene un fallo de caché en `COPY . .`. `__pycache__/`, `node_modules/`, `.venv/` y `.env` son los otros — y `.env` es además una fuga de secretos.

**A3.3** (1) El valor queda embebido en el *history de la config* de la imagen como la cadena literal del comando de la capa `RUN` — `docker history --no-trunc` o `docker inspect` lo imprimen, y cualquiera que descargue la imagen puede leerlo sin ejecutarla. (2) El `RUN` creó una capa que contiene `/tmp/build.log` con el token adentro; incluso si un `RUN rm` posterior lo borró, el blob de la capa anterior sigue existiendo en la imagen y puede extraerse con `docker save`/`skopeo copy` + `tar`. Borrar un archivo en una capa posterior solo agrega una entrada whiteout; no elimina los bytes.

**A3.4** Costo: no hay `sh`, `ps`, `curl`, `nslookup`, ni gestor de paquetes, así que `docker exec` para triaje es imposible — no podés inspeccionar la tabla de procesos ni probar la conectividad desde adentro. La solución del Ejercicio 10 es conectar un contenedor de depuración a los namespaces del target (`--network container:<name> --pid container:<name>`, o `kubectl debug --target`), que aporta su propia cadena de herramientas mientras observa la vista de red y de procesos del target.

**A3.5** Construye solo hasta el stage `build` y etiqueta esa imagen intermedia — la cadena de herramientas completa de Go con las fuentes y los artefactos compilados. Usos legítimos: correr tests unitarios y linters en CI contra el entorno de build exacto, extraer artefactos de cobertura o SBOM, y precalentar una caché de build compartida (`--cache-from`) para que los stages posteriores del pipeline se salteen la recompilación.

### Ejercicio 4

**A4.1** (1) `/bin/sh -c` no hizo `exec` del script — lo bifurcó como hijo — así que el shell era el PID 1, y `docker stop` entrega `SIGTERM` **solo al PID 1**, nunca al árbol. El script nunca vio la señal. (2) Incluso llegando al PID 1, ese shell no tenía trap de `TERM`, y el kernel *ignora* las señales con disposiciones por defecto para el PID 1 dentro de un namespace de PID (la regla de "protección de init"): un proceso que no ha instalado un handler no puede ser matado por `SIGTERM` siendo PID 1. Después del período de gracia de 10 segundos Docker envió `SIGKILL`, que no es enmascarable.

**A4.2** Ambos son `128 + señal`. `137 = 128 + 9` (`SIGKILL`) — el período de gracia expiró y el runtime lo mató duro; nada drenó. `143 = 128 + 15` (`SIGTERM`) — el proceso murió por TERM, lo que significa que al menos la recibió. En el caso funcional el handler llamó a `exit 0`, así que la firma de un apagado limpio es el código de salida **0**, no 143. Ver 137 en cada despliegue es la huella digital de un PID 1 roto.

**A4.3** Para nginx, `SIGTERM` significa *apagado rápido*: los workers abandonan inmediatamente las conexiones en vuelo. `SIGQUIT` es el apagado *elegante* de nginx: dejar de aceptar conexiones nuevas, terminar las que están en curso, y luego salir. `STOPSIGNAL` se almacena en la config de la imagen (`Config.StopSignal`), así que `docker stop` lo lee de la imagen y envía la señal correcta sin que nadie tenga que acordarse de `--signal`. Verificalo con `docker inspect -f '{{.Config.StopSignal}}'`.

**A4.4** `--init` inserta `tini`/`docker-init` como PID 1, que recolecta huérfanos y reenvía señales **a su hijo directo**. No reenvía a los nietos, y no puede conocer el árbol de procesos de tu aplicación. Un shell que genera workers y que él mismo no propaga `TERM` igual los deja corriendo. La corrección adecuada dentro de la imagen es `ENTRYPOINT ["/app"]` en forma exec para que el proceso real sea el PID 1, o — si un script wrapper es genuinamente necesario — terminarlo con `exec "$@"` para que el shell sea reemplazado en lugar de conservado, y usar `trap` + `kill -TERM 0`/`kill -- -$$` solo cuando un supervisor sea inevitable.

### Ejercicio 5

**A5.1** El servidor DNS embebido de Docker. Cada contenedor en una red definida por el usuario recibe `nameserver 127.0.0.11` en `/etc/resolv.conf`; el daemon instala reglas DNAT dentro del namespace de red de ese contenedor que redirigen 127.0.0.11:53 a un listener en el daemon, que responde por nombres de contenedor, alias de red y nombres de servicio, y reenvía todo lo demás a los resolvers del host. Es link-local y por namespace precisamente para que la misma dirección signifique "el resolver de mi red" en cada contenedor sin colisiones. El bridge por defecto heredado no tiene tal resolver — solo el mecanismo obsoleto `--link`, que escribe entradas en `/etc/hosts`.

**A5.2** Docker inserta sus reglas de NAT en las cadenas `PREROUTING`/`DOCKER` de la tabla `nat` y sus reglas de filtrado en `FORWARD` → `DOCKER`, que se evalúan *antes* de las cadenas de usuario de `ufw`/`firewalld` para el tráfico reenviado. Dado que el tráfico de los puertos publicados es DNAT-eado y reenviado en lugar de entregado a la cadena `INPUT` del host, las reglas del firewall del host escritas para `INPUT` nunca lo ven. La cadena que Docker deja para vos es **`DOCKER-USER`**, que se recorre antes de `DOCKER`; poné ahí tus reglas de denegación. Alternativamente publicá en loopback o en una IP de host específica (`-p 127.0.0.1:8080:80`), como hace este laboratorio.

**A5.3** Mount ns: **sigue aislado** — el contenedor conserva su propio rootfs. PID ns: **sigue aislado** — `--network host` solo comparte el namespace de red; usá `--pid host` para compartir ese. Límites de cgroup: **siguen aplicándose** — el control de recursos es ortogonal a los namespaces. Bindeos de puertos: **no aislados** — el contenedor bindea directamente en las interfaces del host, `-p` no tiene sentido y es rechazado/ignorado, y dos contenedores así colisionan en el mismo puerto, que es el error del paso 5.

**A5.4** Portable: el nombre DNS especial `host.docker.internal` (Docker Desktop; en Linux agregá `--add-host=host.docker.internal:host-gateway`) o, para Podman, `host.containers.internal`. Alternativa nativa de Linux: usar la dirección del gateway del bridge (`172.17.0.1`, o el gateway de `docker network inspect`), o ejecutar con `--network host` para que "el host" sea simplemente localhost.

**A5.5** `--name` da un nombre resoluble atado a la identidad del contenedor, único por daemon. `--network-alias` agrega nombres adicionales *acotados a una red*, y varios contenedores pueden compartir el mismo alias — el DNS embebido devuelve entonces todas sus direcciones, dando balanceo de carga round-robin del lado del cliente. Necesitás alias cuando múltiples réplicas deben responder a un nombre lógico de servicio, o cuando el mismo contenedor debe ser alcanzable bajo nombres distintos en redes distintas.

### Ejercicio 6

**A6.1** El copy-up aplica **solo a volúmenes con nombre (y anónimos)**, y solo cuando el volumen está **vacío** y el directorio destino de la imagen es **no vacío**: el runtime siembra el volumen con el contenido de la imagen, incluidos propiedad y permisos, en el primer uso. Los bind mounts nunca hacen copy-up — un bind mount es un montaje simple que oculta lo que haya debajo, así que un directorio vacío del host aparece vacío, y nginx devolvió 403 (autoindex desactivado, sin `index.html`).

**A6.2** `docker rm -v` (o `docker rm --volumes`) elimina los volúmenes *anónimos* adjuntos al contenedor. `sitedata` fue creado explícitamente con `docker volume create` y referenciado por nombre, así que es un volumen con nombre gestionado con un ciclo de vida independiente; solo `docker volume rm sitedata` (o `docker compose down -v` para los creados por Compose) lo borra. Esta asimetría es deliberada: los volúmenes con nombre son datos que quisiste conservar.

**A6.3** Ejecutalo en solo lectura y dejá que él te lo diga: arrancá con `--read-only` y leé los mensajes de fallo/`docker logs`; o observá las escrituras empíricamente — ejecutá el contenedor normalmente, ejercitalo, y después `docker diff <container>`, cuyas líneas `A`/`C` listan cada ruta agregada o modificada respecto de la imagen. Esas rutas se convierten en tus montajes `tmpfs` o de volumen. `strace -f -e trace=file` vía un contenedor de depuración conectado con `--cap-add SYS_PTRACE` da la misma respuesta para los casos tercos.

**A6.4** `:z` reetiqueta el contenido del host con una etiqueta SELinux **compartida** (`container_file_t` sin categorías MCS únicas), de modo que múltiples contenedores pueden acceder a él. `:Z` aplica una etiqueta **privada** con un par de categorías MCS único ligado a ese único contenedor. Usar `:Z` en un directorio fuente compartido reetiqueta esos archivos a una categoría que solo el primer contenedor puede leer, así que el segundo contenedor obtiene `Permission denied` — y si la ruta es algo como `/home/user/src` o, catastróficamente, un directorio del sistema, el reetiquetado además rompe el acceso de los procesos del host a él. Nunca uses `:Z` en rutas compartidas o del sistema.

**A6.5** Bajo Podman rootless el contenedor corre dentro de un namespace de usuario: el UID del host que es dueño de los archivos (tu 1000) no está mapeado dentro del rango del contenedor, así que aparece como el UID de desbordamiento `nobody` (65534). `--userns=keep-id` mapea tu UID del host al mismo UID dentro del contenedor, haciendo que la propiedad coincida; `--userns=keep-id:uid=1000,gid=1000` lo fija explícitamente. `podman unshare chown` es la alternativa cuando querés que los archivos sean propiedad de un UID interno del contenedor.

### Ejercicio 7

**A7.1** `cpu.max` es `<cuota> <período>` en microsegundos: 50.000 µs de tiempo de CPU por cada período de 100.000 µs — la mitad de una CPU, acumulativo entre todos los hilos del cgroup. Un hilo que agota la cuota a mitad del período es **throttled** (estrangulado): el controlador de ancho de banda de CFS desencola el cgroup entero hasta el límite del período siguiente. Esto es un bloqueo duro, no una ralentización, y se manifiesta como picos de latencia (visibles en `nr_throttled` / `throttled_usec` de `cpu.stat`), y por eso los límites de CPU agresivos en servicios sensibles a la latencia son un riesgo conocido en producción.

**A7.2** Default: cuando solo se da `-m 64m`, `--memory-swap` toma por defecto **el doble** del límite de memoria (128m), es decir se permiten 64 MB de swap. Si el host tiene swap habilitado, las páginas shmem podrían irse a swap en lugar de disparar el OOM killer, así que la prueba a veces pasaría y a veces se colgaría. Poner `--memory-swap` igual a `-m` deshabilita el swap para el cgroup y hace que el OOM sea determinista. (`--memory-swap=-1` significa swap ilimitado.)

**A7.3** `--cpus` (y `--cpu-quota`/`--cpu-period`) es un **techo duro** aplicado por el control de ancho de banda de CFS — el cgroup es estrangulado incluso cuando el host está ocioso. `--cpu-shares` (cgroup v2: `cpu.weight`) es un **peso relativo** usado solamente cuando hay contención; en un host ocioso **no tiene efecto** y el contenedor puede usar todos los núcleos. Confundir los dos es la razón por la que ocurre el "puse cpu-shares y aun así se comió la máquina".

**A7.4** `docker stats` reporta el límite *efectivo*, y sin `-m` el límite efectivo es la RAM total del host — el cgroup de memoria del contenedor tiene `memory.max = max`. El riesgo: un contenedor sin acotar puede consumir toda la memoria del host, momento en el cual el OOM killer **global** elige una víctima por puntaje de maldad, y esa víctima puede ser un contenedor no relacionado, el runtime de contenedores, o `sshd`. Un límite por contenedor convierte un incidente que abarca todo el host en el reinicio de un solo contenedor.

**A7.5** (1) El heap de la JVM no es la huella completa de la JVM: el metaspace, las pilas de hilos (~1 MB cada una), la caché de código, las estructuras del GC, los `ByteBuffer` directos/mapeados y las asignaciones JNI son todos memoria anónima contada por el cgroup y todos quedan fuera de `-Xmx`. (2) El cgroup de memoria también cuenta la caché de páginas y tmpfs/shmem atribuidos al cgroup — un archivo de log parlanchín o una asignación en `/dev/shm` empuja el total por encima del límite incluso con un heap pequeño. Causa secundaria: una JVM vieja que leía la RAM *del host* en lugar del límite del cgroup y dimensionaba sus defaults en consecuencia (corregido por la conciencia de contenedores / `-XX:MaxRAMPercentage`).

### Ejercicio 8

**A8.1** Docker rootful: sí — el uid 0 en el contenedor **es** el uid 0 en el host. El contenedor está restringido por capabilities, seccomp, AppArmor/SELinux y namespaces, no por identidad; un escape de montaje o un `/var/run/docker.sock` montado por bind da root del host inmediatamente. Podman rootless: no — el uid_map muestra que el uid 0 del contenedor está mapeado a tu uid no privilegiado del host (1000), y los uids 1..65536 mapeados al rango de `/etc/subuid` que empieza en 100000. Los archivos que crea en un bind mount pertenecen a esos uids del host, y no tiene privilegio en el host más allá del tuyo.

**A8.2** Desde Linux 2.2, "root" no es un único bit de privilegio — es el conjunto completo de capabilities que el kernel otorga al uid 0 por defecto. `ping` necesita `CAP_NET_RAW` para abrir un socket raw/ICMP; descartar todas las capabilities deja a un proceso uid 0 con un conjunto efectivo vacío, así que toda operación privilegiada falla a pesar del uid. En la práctica: `--cap-drop ALL --cap-add <solo lo que necesitás>` es mucho más significativo que el uid, y los dos controles se componen (`USER` + `--cap-drop ALL` es la combinación fuerte).

**A8.3** Ordenadas de menor a mayor radio de impacto: (1) **No bindear el 80** — escuchar en 8080 y publicar `-p 80:8080`; el NAT ocurre fuera del contenedor y el proceso nunca necesita privilegio. (2) **`sysctl net.ipv4.ip_unprivileged_port_start=0`** acotado al contenedor (`--sysctl`), permitiendo que un uid no privilegiado bindee puertos bajos sin ninguna capability. (3) **`--cap-drop ALL --cap-add NET_BIND_SERVICE`** con un `USER` no-root — una capability estrecha, pero aun así una capability que el proceso conserva toda su vida. Ejecutar como root para bindear y descartar después es la peor opción y es lo que reemplazan las tres primeras.

**A8.4** Establece el prctl `PR_SET_NO_NEW_PRIVS` del kernel sobre los procesos del contenedor, lo que hace que `execve()` no pueda otorgar privilegios adicionales — los bits setuid/setgid, las capabilities de archivo y las transiciones LSM que elevan privilegios son todas ignoradas para ese proceso y cada descendiente, permanentemente. Es barato porque no cuesta nada en tiempo de ejecución y cierra la vía de escalada estándar desde un contenedor no-root: encontrar un binario setuid en la imagen (`find / -perm -4000`) y usarlo para volverse uid 0.

**A8.5** Es más fuerte porque: (1) es el default de la imagen — no hay flag de operador que olvidar, y aplica a cada `docker run`, servicio de Compose y orquestador que consuma la imagen; (2) la construcción puede preparar el sistema de archivos para ese uid (`chown`, directorios escribibles, entrada en `/etc/passwd`), así que la imagen realmente *funciona* sin privilegios, mientras que `-u` sobre una imagen diseñada para root típicamente falla por permisos. Lo que **no** garantiza: `USER` en el Dockerfile es sobreescribible en tiempo de ejecución (`docker run -u 0`, o `securityContext.runAsUser` en Kubernetes), así que la aplicación también debe existir en la capa de plataforma (`runAsNonRoot: true`, Pod Security Admission, o un motor de políticas).

**A8.6** `--privileged` deshabilita esencialmente toda la capa de confinamiento: otorga **todas** las capabilities, monta el `/dev` completo (de modo que los dispositivos de bloque del host son legibles/escribibles), deshabilita el filtro seccomp, pone AppArmor/SELinux en unconfined, y hace escribibles las rutas de sysfs `/sys` y `/proc`. Es root del host con pasos extra. Para reemplazarlo, determiná qué necesita realmente la carga de trabajo y otorgá solo eso: `--cap-add` de las capabilities específicas (`SYS_ADMIN`, `NET_ADMIN`, `SYS_TIME`…), `--device /dev/xxx` para dispositivos específicos, `--security-opt seccomp=custom.json` en lugar de `unconfined`, `--sysctl` para perillas individuales del kernel. Método: ejecutalo privilegiado una vez bajo `strace`/auditoría o con `--security-opt seccomp=unconfined` y logging de auditoría, recolectá las denegaciones, y otorgá exactamente esas.

### Ejercicio 9

**A9.1** Docker Engine **no hace nada** — registra el estado y emite un evento `health_status: unhealthy`, pero no reinicia, no detiene, ni deja de enrutar hacia el contenedor; una política de reinicio tampoco reacciona a la salud, solo a la salida del proceso. Los dos sistemas que sí actúan sobre eso: **Docker Swarm** (reprograma una tarea unhealthy) y **Kubernetes** (un `livenessProbe` fallido reinicia el contenedor, un `readinessProbe` fallido lo quita de los endpoints del Service). En Docker a secas tenés que cablear vos mismo la acción, p. ej. un supervisor observando `docker events --filter event=health_status`.

**A9.2** Difieren solo después de que el **daemon (o el host) se reinicia**. `always` arranca el contenedor de nuevo incluso si vos lo habías `docker stop`eado explícitamente antes del reinicio. `unless-stopped` recuerda que lo detuviste deliberadamente y lo deja detenido. En todo lo demás — reiniciar ante cualquier salida distinta de cero *y* cero, intentos ilimitados — son iguales. `unless-stopped` es el default más seguro porque respeta la intención del operador a través de los reinicios.

**A9.3** Docker usa retroceso exponencial empezando en 100 ms y duplicando (100 ms, 200 ms, 400 ms…) con tope de 1 minuto, y el contador se reinicia una vez que el contenedor se mantiene arriba durante 10 s. Es peligroso con un `HEALTHCHECK` sin `--start-period` porque la sonda empieza inmediatamente: una aplicación de arranque lento se marca como `unhealthy` durante el arranque normal, y cualquier supervisor que actúe sobre ese estado la reinicia, produciendo un crash-loop en el que la aplicación nunca tiene tiempo suficiente para estar lista. `--start-period` hace que los fallos durante la ventana de arranque no cuenten.

**A9.4** Con `journald`, los archivos `*-json.log` por contenedor bajo `/var/lib/docker/containers/<id>/` ya no existen, así que la verificación con `ls -lh` y las opciones de rotación `max-size`/`max-file` carecen de sentido — la rotación pasa a ser tarea de journald (`SystemMaxUse=` en `journald.conf`). `docker logs` sigue funcionando para los drivers que implementan lectura de logs: `json-file`, `local`, `journald`, y (con configuración de clúster) `awslogs`/`gcplogs`. Falla directamente para `syslog`, `fluentd`, `gelf` y `splunk`, donde tenés que consultar el destino en su lugar.

**A9.5** `service_healthy` solo garantiza que la dependencia estaba saludable en el momento en que `web` arrancó. No dice nada sobre que la dependencia se reinicie después, falle y haga failover, se vuelva inalcanzable por una partición de red, o esté lenta. Las aplicaciones deben implementar **reintentos de conexión con retroceso exponencial y jitter**, lógica de reconexión idempotente, timeouts en cada llamada saliente, e idealmente un circuit breaker — el ordenamiento de dependencias es una comodidad para el arranque local, nunca un mecanismo de corrección. Esta es la misma razón por la que Kubernetes no tiene `depends_on`.

**A9.6** Sí, `deploy.resources.limits` es respetado por Compose v2 fuera de Swarm — la salida de `docker inspect` lo prueba: `mem=134217728` son exactamente 128 MiB y `cpuquota=500000000` es 0,5 CPU expresado como NanoCpus. (El comportamiento heredado de Compose v1 de ignorar toda la clave `deploy:` fuera de Swarm ya no aplica a `limits`; otras claves de `deploy` como `replicas` y `placement` siguen siendo exclusivas de Swarm.) Los equivalentes fuera de `deploy`, `mem_limit` y `cpus`, también funcionan y son menos ambiguos.

### Ejercicio 10

**A10.1** Compartir el namespace de **red** te da las interfaces exactas del target, las rutas, la vista de `iptables`/`nftables`, los sockets en escucha (`ss -lntp`), la ruta de resolución DNS, y te permite hacer `curl` a sus listeners por `127.0.0.1` — por eso el `wget` a `127.0.0.1:8080` tuvo éxito desde un contenedor distinto. Compartir el namespace de **PID** muestra los procesos del target con sus PIDs reales dentro del contenedor, y con `SYS_PTRACE` permite `strace`, `gdb`, y leer `/proc/<pid>/`. Lo que **no** te da es el **sistema de archivos** del target: el contenedor de depuración tiene su propio rootfs, así que no podés leer directamente los archivos de configuración ni los binarios de la aplicación — para eso usá `/proc/<pid>/root/` desde el host (paso 3) o, en Kubernetes, un contenedor efímero con `--target` más volúmenes compartidos.

**A10.2** `/proc/<pid>/root` es un enlace simbólico mágico mantenido por el kernel que se resuelve relativo al **namespace de montaje y directorio raíz** de ese proceso, así que abrir una ruta a través de él entra en la vista del sistema de archivos del contenedor sin ningún montaje ni `nsenter`. El requisito previo es el privilegio: tenés que tener `CAP_SYS_PTRACE` en el host (en la práctica, ser root o el mismo UID con permiso de ptrace), y en Podman rootless tenés que ser el usuario propietario o entrar al namespace de usuario con `podman unshare`. También deja de funcionar en el instante en que el proceso termina.

**A10.3** `docker export` escribe un **tarball aplanado del rootfs de un contenedor** — un único árbol de sistema de archivos, sin capas, sin config de imagen, sin `ENTRYPOINT`/`ENV`/history; reimportarlo con `docker import` produce una imagen de una sola capa cuyos metadatos tenés que volver a especificar. `docker save` escribe una **imagen** (o imágenes) con todos sus blobs de capas, el JSON de config, el manifest y las referencias de tags — la forma por capas que preserva los metadatos, y la elección correcta para mover imágenes entre hosts o registries de manera offline. Para análisis forense a menudo querés ambos: `save` por la procedencia, `export` por los bytes exactos en ejecución incluidos los cambios hechos después del arranque.

**A10.4** `oom=false` con `exit=137` significa que el proceso recibió `SIGKILL` desde **fuera del subsistema de memoria del cgroup** — un `docker kill`, un `docker stop` cuyo período de gracia expiró (el caso del Ejercicio 4), un operador del host, o el OOM killer global actuando sobre el host en lugar de sobre el cgroup del contenedor. `oom=true` con `exit=137` significa que el **cgroup de memoria propio del contenedor** alcanzó su límite y el OOM killer del cgroup del kernel eligió un proceso dentro de él. Entonces: leé `State.OOMKilled` primero; si es falso y vos no lo mataste, sospechá de un apagado elegante fallido y compará `State.FinishedAt` contra el momento del stop — una brecha de ~10 s es la firma. Contrastalo con `dmesg` para el registro propio del kernel.

**A10.5** `kubectl debug -it <pod> --image=nicolaka/netshoot --target=<container>`. El contenedor efímero comparte el **namespace de red** del pod (todos los contenedores de un pod siempre lo hacen) y, gracias a `--target`, el **namespace de procesos** del contenedor target, así que `ps` y `/proc/<pid>` ven los procesos del target. **No** comparte el sistema de archivos del target ni sus volúmenes salvo que los volúmenes del pod también estén montados — la misma limitación que en A10.1. `kubectl debug node/<node>` es la variante a nivel de host, y `--copy-to` clona el pod cuando necesitás cambiarle el comando.

</details>

---

## Fuentes

- LPI — *DevOps Tools Engineer, Exam 701 Objectives*: https://www.lpi.org/our-certifications/exam-701-objectives/
- Docker — *Dockerfile reference*: https://docs.docker.com/reference/dockerfile/
- Docker — *Runtime options with Memory, CPUs, and GPUs*: https://docs.docker.com/engine/containers/resource_constraints/
- Docker — *Container networking*: https://docs.docker.com/engine/network/
- Docker — *Manage data in Docker (volumes, bind mounts, tmpfs)*: https://docs.docker.com/engine/storage/
- Docker — *Docker security / capabilities and privileged mode*: https://docs.docker.com/engine/security/
- Docker — *Configure logging drivers*: https://docs.docker.com/engine/logging/configure/
- Docker — *Build secrets*: https://docs.docker.com/build/building/secrets/
- Docker — *Compose file reference*: https://docs.docker.com/reference/compose-file/
- OCI — *Image Format Specification*: https://github.com/opencontainers/image-spec/blob/main/spec.md
- OCI — *Runtime Specification (Linux)*: https://github.com/opencontainers/runtime-spec/blob/main/config-linux.md
- Podman — *Rootless containers and user namespaces*: https://docs.podman.io/en/latest/markdown/podman-run.1.html
- Linux kernel — *Control Group v2*: https://docs.kernel.org/admin-guide/cgroup-v2.html
- Linux man-pages — *capabilities(7)*: https://man7.org/linux/man-pages/man7/capabilities.7.html
- Linux man-pages — *pid_namespaces(7)*: https://man7.org/linux/man-pages/man7/pid_namespaces.7.html