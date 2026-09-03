# 702.2 Container Orchestration — Ejercicios guiados

**Certificación:** LPI DevOps Tools Engineer — Examen 701-100, versión 2.0.0
**Peso del tema:** 5
**Objetivos oficiales:** <https://www.lpi.org/our-certifications/exam-701-objectives/>

Estos ejercicios son prácticos. Cada comando está pensado para que lo escribas, y cada bloque de salida es lo que deberías ver (los IDs, las IPs y las marcas de tiempo van a diferir). Las preguntas que siguen a cada bloque no son retóricas: respondelas antes de seguir. Las respuestas completas están en la sección plegable del final.

---

## 0. Preparación del entorno

Necesitás un único host Linux con Docker Engine 25+ (plugin Compose V2 incluido) y acceso a un clúster de Kubernetes (kind, minikube, k3s o un clúster real), además de `kubectl` y `helm` 3.

```bash
docker version --format '{{.Server.Version}}'
docker compose version
kubectl version --client -o yaml | head -5
helm version --short
```

Forma esperada:

```
27.3.1
Docker Compose version v2.29.7
clientVersion:
  buildDate: "2024-11-13T..."
  gitVersion: v1.31.3
v3.16.2+g13f07e7
```

Creá un directorio de trabajo:

```bash
mkdir -p ~/lab-702.2/{compose,swarm,k8s,chart} && cd ~/lab-702.2
```

---

## Ejercicio 1 — Orquestación local declarativa con Compose

**Objetivo:** describir una aplicación multiservicio de forma declarativa, expresar el *orden* a través de la salud, y descubrir dónde Compose sobre un solo host deja de ser un orquestador.

### Bloque 1.1 — Escribir el modelo de la aplicación

1. Creá `~/lab-702.2/compose/compose.yaml`:

```yaml
name: shop

services:
  cache:
    image: redis:7-alpine
    command: ["redis-server", "--save", "60", "1", "--loglevel", "warning"]
    volumes:
      - cache-data:/data
    networks:
      - backend
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 5
      start_period: 5s

  seed:
    image: redis:7-alpine
    command: ["redis-cli", "-h", "cache", "set", "greeting", "hello-from-compose"]
    networks:
      - backend
    depends_on:
      cache:
        condition: service_healthy
    restart: "no"

  web:
    image: nginxdemos/hello:plain-text
    ports:
      - "8080:80"
    networks:
      - backend
      - frontend
    depends_on:
      seed:
        condition: service_completed_successfully
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://localhost/ || exit 1"]
      interval: 10s
      timeout: 3s
      retries: 3

networks:
  frontend:
  backend:
    internal: true

volumes:
  cache-data:
```

2. Renderizá el modelo *efectivo* sobre el que va a actuar el engine: este es el archivo después de la interpolación, los extends y la resolución de perfiles:

```bash
cd ~/lab-702.2/compose
docker compose config | head -30
```

3. Levantá el stack y mirá cómo se resuelve la cadena de dependencias:

```bash
docker compose up -d
```

```
[+] Running 6/6
 ✔ Network shop_backend   Created                                 0.1s
 ✔ Network shop_frontend  Created                                 0.1s
 ✔ Volume "shop_cache-data" Created                               0.0s
 ✔ Container shop-cache-1  Healthy                                6.2s
 ✔ Container shop-seed-1   Exited                                 7.0s
 ✔ Container shop-web-1    Started                                7.2s
```

4. Inspeccioná el resultado y demostrá que el seed realmente se ejecutó:

```bash
docker compose ps -a
docker compose exec cache redis-cli get greeting
```

```
NAME           IMAGE                          COMMAND                  SERVICE  STATUS                     PORTS
shop-cache-1   redis:7-alpine                 "docker-entrypoint.s…"   cache    Up 40s (healthy)           6379/tcp
shop-seed-1    redis:7-alpine                 "docker-entrypoint.s…"   seed     Exited (0) 35s ago
shop-web-1     nginxdemos/hello:plain-text    "/docker-entrypoint.…"   web      Up 34s (healthy)           0.0.0.0:8080->80/tcp
"hello-from-compose"
```

> **Q1.1** — `depends_on` en su forma corta (`depends_on: [cache]`) está descrito en la propia documentación de Docker como insuficiente para aplicaciones reales. ¿Qué garantiza exactamente la forma corta, y qué agrega `condition: service_healthy`?
>
> **Q1.2** — La red `backend` está declarada como `internal: true`. ¿Qué tráfico concreto bloquea eso, y qué *no* bloquea? ¿Por qué se puede seguir llegando a `web` por el puerto 8080?
>
> **Q1.3** — `seed` está declarado con `restart: "no"`. ¿Qué le pasaría a la convergencia de todo el stack si hubieras escrito `restart: always` en un contenedor de un solo uso que sale con 0?
>
> **Q1.4** — ¿Por qué el proyecto de Compose prefija todo con `shop_` / `shop-`, y qué clave lo controla? ¿Qué se rompe si dos ingenieros ejecutan este archivo desde directorios con nombres distintos y *sin* la clave `name:`?

### Bloque 1.2 — Escalar, y chocar contra el muro

5. Intentá ejecutar tres copias de `web`:

```bash
docker compose up -d --scale web=3
```

```
[+] Running 3/3
 ✔ Container shop-web-1  Running                                  0.0s
 ⠿ Container shop-web-2  Starting                                 0.3s
 ⠿ Container shop-web-3  Starting                                 0.3s
Error response from daemon: driver failed programming external connectivity on
endpoint shop-web-2: Bind for 0.0.0.0:8080 failed: port is already allocated
```

6. Arreglá el modelo para que pueda escalar, publicando un *rango* en vez de un puerto de host fijo. Editá el servicio `web`:

```yaml
    ports:
      - "8080-8090:80"
```

7. Reaplicá y verificá:

```bash
docker compose up -d --scale web=3
docker compose ps --format '{{.Name}}\t{{.Ports}}'
```

```
shop-cache-1    6379/tcp
shop-web-1      0.0.0.0:8080->80/tcp
shop-web-2      0.0.0.0:8081->80/tcp
shop-web-3      0.0.0.0:8082->80/tcp
```

8. Confirmá que cada réplica es un backend distinto:

```bash
for p in 8080 8081 8082; do curl -s localhost:$p | grep 'Server address'; done
```

```
Server address: 172.19.0.4:80
Server address: 172.19.0.5:80
Server address: 172.19.0.6:80
```

9. Ahora probá el service discovery *dentro* de la red:

```bash
docker compose exec cache sh -c 'for i in 1 2 3 4; do getent hosts web; done'
```

```
172.19.0.4      web
172.19.0.5      web
172.19.0.6      web
172.19.0.4      web
```

> **Q1.5** — El paso 5 falló. Indicá con precisión por qué, y explicá por qué esa falla es una *propiedad del modelo de orquestación*, no un bug de Compose.
>
> **Q1.6** — Después del paso 9, ¿Compose está balanceando tu tráfico? Explicá el mecanismo detrás de las respuestas variables de `getent hosts web`, y nombrá dos modos de falla en producción por depender de eso.
>
> **Q1.7** — Agregás `deploy: {replicas: 3}` a `web` en el mismo archivo. ¿Cuáles de estas claves respeta `docker compose up` y cuáles ignora silenciosamente: `deploy.replicas`, `deploy.resources.limits`, `deploy.placement.constraints`, `deploy.update_config`?

10. Desarmá todo, conservando el volumen, y después revisá qué sobrevivió:

```bash
docker compose down
docker volume ls --filter name=shop
```

```
DRIVER    VOLUME NAME
local     shop_cache-data
```

> **Q1.8** — `docker compose down` eliminó contenedores y redes, pero no el volumen. ¿Qué flag elimina los volúmenes nombrados, y por qué ese flag *no* es el comportamiento por defecto?

---

## Ejercicio 2 — Del archivo Compose al clúster: servicios de Swarm, VIPs y la routing mesh

**Objetivo:** desplegar el mismo modelo declarativo en un planificador que es dueño del estado deseado, y entender ingress vs. publicación en el host, descubrimiento VIP vs. DNSRR.

### Bloque 2.1 — Inicializar el clúster y desplegar un stack

1. Inicializá el modo Swarm en este host:

```bash
docker swarm init --advertise-addr $(hostname -I | awk '{print $1}')
```

```
Swarm initialized: current node (kx9c1r2m4v8n0tqz3l7wpsy6a) is now a manager.

To add a worker to this swarm, run the following command:
    docker swarm join --token SWMTKN-1-3n8...q1w 192.168.178.42:2377
```

2. Inspeccioná el nodo y las redes que Swarm creó para sí mismo:

```bash
docker node ls
docker network ls --filter driver=overlay
```

```
ID                            HOSTNAME   STATUS    AVAILABILITY   MANAGER STATUS   ENGINE VERSION
kx9c1r2m4v8n0tqz3l7wpsy6a *   node-01    Ready     Active         Leader           27.3.1

NETWORK ID     NAME              DRIVER    SCOPE
b1e0f4c9a233   ingress           overlay   swarm
```

3. Escribí `~/lab-702.2/swarm/stack.yaml`:

```yaml
services:
  api:
    image: nginxdemos/hello:plain-text
    networks:
      - appnet
    ports:
      - target: 80
        published: 8080
        protocol: tcp
        mode: ingress
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://localhost/ || exit 1"]
      interval: 10s
      timeout: 3s
      retries: 3
      start_period: 5s
    deploy:
      replicas: 3
      endpoint_mode: vip
      restart_policy:
        condition: on-failure
        delay: 5s
        max_attempts: 3
        window: 60s
      update_config:
        parallelism: 1
        delay: 10s
        order: start-first
        failure_action: rollback
        monitor: 20s
        max_failure_ratio: 0
      rollback_config:
        parallelism: 0
        order: stop-first
      resources:
        limits:
          cpus: "0.50"
          memory: 128M
        reservations:
          cpus: "0.05"
          memory: 32M
      placement:
        max_replicas_per_node: 3
        constraints:
          - "node.platform.os == linux"

  toolbox:
    image: busybox:1.36
    command: ["sleep", "infinity"]
    networks:
      - appnet
    deploy:
      replicas: 1

networks:
  appnet:
    driver: overlay
    attachable: false
```

4. Desplegalo:

```bash
cd ~/lab-702.2/swarm
docker stack deploy -c stack.yaml shop --detach=false
```

```
Creating network shop_appnet
Creating service shop_api
Creating service shop_toolbox

Service shop_api: converged
Service shop_toolbox: converged
```

5. Inspeccioná lo que el planificador creó realmente:

```bash
docker stack services shop
docker service ps shop_api --format 'table {{.Name}}\t{{.Node}}\t{{.DesiredState}}\t{{.CurrentState}}'
```

```
ID             NAME           MODE         REPLICAS   IMAGE                          PORTS
7f3q2m1x0abc   shop_api       replicated   3/3        nginxdemos/hello:plain-text    *:8080->80/tcp
9c1v8n2t5def   shop_toolbox   replicated   1/1        busybox:1.36

NAME           NODE      DESIRED STATE   CURRENT STATE
shop_api.1     node-01   Running         Running 45 seconds ago
shop_api.2     node-01   Running         Running 45 seconds ago
shop_api.3     node-01   Running         Running 44 seconds ago
```

> **Q2.1** — Compará `docker compose up` y `docker stack deploy`. ¿Dónde vive el *estado deseado* en cada caso, y qué pasa en cada uno si hacés `kill -9` al proceso principal de un contenedor?
>
> **Q2.2** — El archivo de stack no tiene `depends_on` ni clave `restart:`, pero sí tiene `deploy.restart_policy`. ¿Qué hace `docker stack deploy` con `build:`, `depends_on:` y `restart:` si los dejás puestos, y por qué eso es arquitectónicamente inevitable?
>
> **Q2.3** — `shop_appnet` se creó automáticamente con el driver `overlay`. ¿Qué hace el driver overlay que una red bridge no puede hacer, y qué puerto(s) tienen que estar abiertos entre nodos para que funcione?

### Bloque 2.2 — Service discovery: VIP, DNSRR y `tasks.<service>`

6. Desde el contenedor toolbox, resolvé el nombre del servicio:

```bash
TASK=$(docker ps -qf name=shop_toolbox)
docker exec -it $TASK nslookup api
```

```
Server:    127.0.0.11
Address:   127.0.0.11:53

Name:      api
Address 1: 10.0.1.2
```

7. Ahora resolvé la forma especial `tasks.`:

```bash
docker exec -it $TASK nslookup tasks.api
```

```
Name:      tasks.api
Address 1: 10.0.1.3
Address 2: 10.0.1.4
Address 3: 10.0.1.5
```

8. Confirmá que 10.0.1.2 es una IP virtual, no un contenedor:

```bash
docker service inspect shop_api \
  --format '{{range .Endpoint.VirtualIPs}}{{.NetworkID}} => {{.Addr}}{{"\n"}}{{end}}'
docker exec -it $TASK sh -c 'for i in 1 2 3 4 5 6; do wget -qO- http://api/ | grep "Server address"; done'
```

```
b1e0f4c9a233 => 10.0.0.9/24
d7a3e8f01b55 => 10.0.1.2/24

Server address: 10.0.1.3:80
Server address: 10.0.1.4:80
Server address: 10.0.1.5:80
Server address: 10.0.1.3:80
Server address: 10.0.1.4:80
Server address: 10.0.1.5:80
```

9. Ejercitá la routing mesh desde el host:

```bash
for i in 1 2 3 4; do curl -s localhost:8080 | grep 'Server address'; done
```

```
Server address: 10.0.1.3:80
Server address: 10.0.1.4:80
Server address: 10.0.1.5:80
Server address: 10.0.1.3:80
```

> **Q2.4** — `nslookup api` devuelve exactamente una dirección y `nslookup tasks.api` devuelve tres. Explicá los dos modos de descubrimiento detrás de esto, y cómo la VIP única igual reparte el tráfico entre tres tasks.
>
> **Q2.5** — Cambiás `endpoint_mode: vip` por `dnsrr` y redesplegás. ¿Qué cambia en la salida del paso 6, qué se rompe en la sección `ports:`, y para qué clase de cliente `dnsrr` es la elección *equivocada*?
>
> **Q2.6** — En el paso 9 hacés curl a `localhost:8080` en un nodo. Si esto fuera un clúster de 5 nodos con 3 réplicas todas planificadas en otros nodos, ¿el `curl` en un nodo sin réplicas seguiría funcionando? Nombrá el mecanismo y la red que usa.
>
> **Q2.7** — Cambiá `mode: ingress` por `mode: host` en el bloque `ports:`. Describí con precisión qué ganás y qué perdés, y qué limita ahora tu cantidad de réplicas por nodo.

---

## Ejercicio 3 — Rolling updates, rollback automatizado y drain

**Objetivo:** conducir una actualización controlada, forzarla a fallar, y observar cómo el planificador se repara solo según la política declarada.

### Bloque 3.1 — Un rolling update sano

1. Mirá la actualización en vivo (abrí una segunda terminal):

```bash
watch -n1 "docker service ps shop_api --filter desired-state=running \
  --format 'table {{.Name}}\t{{.Image}}\t{{.CurrentState}}'"
```

2. En la primera terminal, pasá a un tag de imagen distinto:

```bash
docker service update --image nginxdemos/hello:plain-text shop_api --detach=false
```

```
shop_api
overall progress: 3 out of 3 tasks
1/3: running   [==================================================>]
2/3: running   [==================================================>]
3/3: running   [==================================================>]
verify: Service shop_api converged
```

3. Leé el estado de actualización registrado:

```bash
docker service inspect shop_api --format '{{json .UpdateStatus}}' | python3 -m json.tool
```

```json
{
    "State": "completed",
    "StartedAt": "2026-09-03T10:12:41.882Z",
    "CompletedAt": "2026-09-03T10:13:09.117Z",
    "Message": "update completed"
}
```

> **Q3.1** — Tu `update_config` declara `parallelism: 1`, `order: start-first`, `delay: 10s`. Recorré la secuencia exacta para 3 réplicas. ¿Cómo cambiaría `order: stop-first` el perfil de disponibilidad, y cuándo es obligatorio `stop-first`?
>
> **Q3.2** — Están puestos `monitor: 20s` y `max_failure_ratio: 0`. ¿Qué está midiendo Swarm durante esos 20 segundos, y cuál es el rol del `healthcheck` del contenedor en esa decisión?

### Bloque 3.2 — Forzar una falla y dejar que la política la repare

4. Actualizá a un tag de imagen que no se pueda descargar:

```bash
docker service update --image nginxdemos/hello:this-tag-does-not-exist shop_api --detach=false
```

```
image nginxdemos/hello:this-tag-does-not-exist could not be accessed on a registry
to record its digest. Each node will access the image independently, possibly
leading to different nodes running different versions of the image.

shop_api
overall progress: rolling back update: 0 out of 3 tasks
...
service rolled back: rolled back to previous version
```

5. Inspeccioná la task fallida y el rollback registrado:

```bash
docker service ps shop_api --no-trunc --format 'table {{.Name}}\t{{.CurrentState}}\t{{.Error}}' | head -5
docker service inspect shop_api --format '{{json .UpdateStatus}}' | python3 -m json.tool
```

```
NAME             CURRENT STATE            ERROR
shop_api.1       Running 4 minutes ago
 \_ shop_api.1   Rejected 30 seconds ago  "No such image: nginxdemos/hello:this-tag-does-not-exist"
```

```json
{
    "State": "rollback_completed",
    "StartedAt": "2026-09-03T10:18:02.441Z",
    "CompletedAt": "2026-09-03T10:18:31.902Z",
    "Message": "rollback completed"
}
```

6. Escalá, y después simulá que un nodo se va a mantenimiento:

```bash
docker service scale shop_api=5 --detach=false
docker node update --availability drain node-01
docker service ps shop_api --format 'table {{.Name}}\t{{.DesiredState}}\t{{.CurrentState}}' | head -4
docker node update --availability active node-01
```

7. Volvé manualmente a la spec de servicio anterior en cualquier momento:

```bash
docker service rollback shop_api --detach=false
```

> **Q3.3** — En el paso 4 el estado de la task es `Rejected`, no `Failed`. ¿Cuál es la diferencia en la máquina de estados de tasks de Swarm, y qué componente produjo cada estado?
>
> **Q3.4** — `failure_action: rollback` te salvó acá. ¿Qué es exactamente "la versión anterior" a la que Swarm vuelve: el tag de imagen anterior, o algo más amplio? ¿Dónde se guarda?
>
> **Q3.5** — Docker advirtió "could not be accessed on a registry to record its digest". ¿Por qué Swarm resuelve los tags a digests por defecto, y qué incidente de producción previene eso? ¿Qué flag lo deshabilita?
>
> **Q3.6** — Después de `docker node update --availability drain`, ¿qué pasa con las tasks en ejecución en ese nodo, frente a `--availability pause`? ¿Cuál usás antes de una actualización de kernel?

8. Limpiá antes de los ejercicios de Kubernetes:

```bash
docker stack rm shop
docker swarm leave --force
```

---

## Ejercicio 4 — Kubernetes: Deployment, Service y un rollout controlado

**Objetivo:** expresar la misma carga de trabajo contra la API de Kubernetes, y entender los rollouts basados en ReplicaSet, la readiness gobernada por probes, y la deriva de configuración.

### Bloque 4.1 — Aplicar los manifiestos

1. Creá `~/lab-702.2/k8s/app.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: shop
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: shop-web-config
  namespace: shop
data:
  default.conf: |
    server {
        listen 8080;
        server_name _;
        default_type text/plain;

        location /healthz {
            access_log off;
            return 200 "ok\n";
        }

        location / {
            return 200 "shop release v1\n";
        }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop-web
  namespace: shop
  labels:
    app.kubernetes.io/name: shop-web
spec:
  replicas: 4
  revisionHistoryLimit: 5
  minReadySeconds: 5
  progressDeadlineSeconds: 120
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: shop-web
  template:
    metadata:
      labels:
        app.kubernetes.io/name: shop-web
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 101
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: nginx
          image: nginxinc/nginx-unprivileged:1.27-alpine
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 2
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
          resources:
            requests:
              cpu: 25m
              memory: 32Mi
            limits:
              memory: 64Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: conf
              mountPath: /etc/nginx/conf.d
              readOnly: true
            - name: cache
              mountPath: /var/cache/nginx
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: conf
          configMap:
            name: shop-web-config
        - name: cache
          emptyDir: {}
        - name: tmp
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: shop-web
  namespace: shop
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: shop-web
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
---
apiVersion: v1
kind: Service
metadata:
  name: shop-web-headless
  namespace: shop
spec:
  clusterIP: None
  selector:
    app.kubernetes.io/name: shop-web
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
```

2. Validá contra el API server *sin* aplicar, y después aplicá:

```bash
cd ~/lab-702.2/k8s
kubectl apply -f app.yaml --dry-run=server
kubectl apply -f app.yaml
```

```
namespace/shop created
configmap/shop-web-config created
deployment.apps/shop-web created
service/shop-web created
service/shop-web-headless created
```

3. Observá la cadena de controladores:

```bash
kubectl -n shop get deploy,rs,pod -o wide
```

```
NAME                       READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/shop-web   4/4     4            4           35s

NAME                                  DESIRED   CURRENT   READY   AGE
replicaset.apps/shop-web-6c8f9d5b74   4         4         4       35s

NAME                            READY   STATUS    RESTARTS   AGE   IP           NODE
pod/shop-web-6c8f9d5b74-2xk4t   1/1     Running   0          35s   10.244.1.7   worker-1
pod/shop-web-6c8f9d5b74-8vqzp   1/1     Running   0          35s   10.244.2.4   worker-2
pod/shop-web-6c8f9d5b74-jr9mn   1/1     Running   0          35s   10.244.1.8   worker-1
pod/shop-web-6c8f9d5b74-w7t2c   1/1     Running   0          35s   10.244.2.5   worker-2
```

4. Verificá que el Service realmente seleccionó esos Pods:

```bash
kubectl -n shop get endpointslices -l kubernetes.io/service-name=shop-web \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{" ready="}{.conditions.ready}{"\n"}{end}'
```

```
10.244.1.7 ready=true
10.244.2.4 ready=true
10.244.1.8 ready=true
10.244.2.5 ready=true
```

5. Probá el descubrimiento y el balanceo de carga desde dentro del clúster:

```bash
kubectl -n shop run curl --rm -it --restart=Never \
  --image=curlimages/curl:8.10.1 -- \
  sh -c 'for i in 1 2 3; do curl -s http://shop-web.shop.svc.cluster.local/; done'
```

```
shop release v1
shop release v1
shop release v1
pod "curl" deleted
```

6. Compará las respuestas DNS de los dos Services:

```bash
kubectl -n shop run dns --rm -it --restart=Never --image=busybox:1.36 -- \
  sh -c 'nslookup shop-web; echo ---; nslookup shop-web-headless'
```

```
Name:      shop-web.shop.svc.cluster.local
Address 1: 10.96.184.22
---
Name:      shop-web-headless.shop.svc.cluster.local
Address 1: 10.244.1.7
Address 2: 10.244.2.4
Address 3: 10.244.1.8
Address 4: 10.244.2.5
```

> **Q4.1** — Mapeá la cadena de propiedad de tres niveles Deployment → ReplicaSet → Pod. ¿Qué objeto guarda el historial de rollouts, y qué haría `kubectl delete rs shop-web-6c8f9d5b74`?
>
> **Q4.2** — Acá `spec.selector.matchLabels` y `spec.template.metadata.labels` son idénticos. ¿Qué pasa si hacés `kubectl apply` de un cambio en `spec.selector` sobre un Deployment existente, y por qué?
>
> **Q4.3** — El paso 6 es el análogo en Kubernetes del `api` vs `tasks.api` del Ejercicio 2. Emparejá cada construcción de Kubernetes con su contraparte de Swarm y explicá la única diferencia de comportamiento en cómo se implementa el balanceo de carga en el nodo.
>
> **Q4.4** — El Service escucha en `port: 80` con `targetPort: http`. ¿Por qué nombrar el puerto y referenciarlo por nombre es mejor práctica que `targetPort: 8080`?
>
> **Q4.5** — El contenedor define `readOnlyRootFilesystem: true` y aun así nginx arranca. ¿Qué dos volúmenes `emptyDir` lo hacen posible, y qué mostraría el log de eventos del Pod si los quitaras?
>
> **Q4.6** — Hay un `limit` de memoria pero deliberadamente ningún `limit` de CPU. Justificá esa elección en términos de lo que hace el kernel cuando se excede cada límite.

### Bloque 4.2 — Rolling update y la trampa del ConfigMap

7. Disparás un rollout cambiando la imagen, y registrás la causa del cambio:

```bash
kubectl -n shop set image deployment/shop-web nginx=nginxinc/nginx-unprivileged:1.27-alpine \
  --record=false
kubectl -n shop annotate deployment/shop-web \
  kubernetes.io/change-cause="bump nginx to 1.27-alpine" --overwrite
kubectl -n shop rollout status deployment/shop-web --timeout=180s
```

```
Waiting for deployment "shop-web" rollout to finish: 1 out of 4 new replicas have been updated...
Waiting for deployment "shop-web" rollout to finish: 3 of 4 updated replicas are available...
deployment "shop-web" successfully rolled out
```

8. Ahora cambiá *solamente* el ConfigMap y observá qué pasa:

```bash
kubectl -n shop patch configmap shop-web-config --type merge -p \
  '{"data":{"default.conf":"server {\n  listen 8080;\n  default_type text/plain;\n  location /healthz { access_log off; return 200 \"ok\\n\"; }\n  location / { return 200 \"shop release v2\\n\"; }\n}\n"}}'

kubectl -n shop rollout status deployment/shop-web --timeout=30s
kubectl -n shop get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.startTime}{"\n"}{end}'
```

```
deployment "shop-web" successfully rolled out
shop-web-6c8f9d5b74-2xk4t 2026-09-03T11:02:11Z
shop-web-6c8f9d5b74-8vqzp 2026-09-03T11:02:11Z
...
```

9. Fijate qué sirve el contenedor en ejecución:

```bash
kubectl -n shop run curl --rm -it --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -s http://shop-web/
```

```
shop release v1
```

10. Forzá que la configuración tome efecto:

```bash
kubectl -n shop rollout restart deployment/shop-web
kubectl -n shop rollout status deployment/shop-web
kubectl -n shop run curl --rm -it --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -s http://shop-web/
```

```
shop release v2
```

11. Inspeccioná y deshacé:

```bash
kubectl -n shop rollout history deployment/shop-web
kubectl -n shop rollout undo deployment/shop-web --to-revision=1
kubectl -n shop rollout status deployment/shop-web
```

> **Q4.7** — En el paso 8 `rollout status` reportó éxito pero no se reinició nada, y el paso 9 seguía sirviendo v1. Explicá las dos mitades: por qué el Deployment se consideró desplegado, y por qué el contenedor mantuvo la configuración vieja aunque los volúmenes proyectados de ConfigMap sí los refresca el kubelet.
>
> **Q4.8** — `kubectl rollout restart` no "reinicia" nada in situ. ¿Qué campo muta realmente, y qué hace que eso sea una operación *rolling* y no una matanza masiva?
>
> **Q4.9** — Con `maxSurge: 1` y `maxUnavailable: 0` sobre 4 réplicas, ¿cuál es el número mínimo y máximo de Pods existentes durante el rollout, y qué supuesto de capacidad hace ese par de parámetros sobre tu clúster?
>
> **Q4.10** — Están puestos `minReadySeconds: 5` y `progressDeadlineSeconds: 120`. Describí contra qué protege cada uno, y cómo se ven las `.status.conditions` del Deployment cuando se excede el plazo.
>
> **Q4.11** — `revisionHistoryLimit: 5`: ¿qué se retiene físicamente, y cuál es el modo de falla de ponerlo en `0`?

---

## Ejercicio 5 — Diagnosticar un rollout roto

**Objetivo:** construir la secuencia refleja para un despliegue trabado. Esta es la habilidad de mayor valor del objetivo.

1. Rompé el Deployment a propósito:

```bash
kubectl -n shop set image deployment/shop-web nginx=nginxinc/nginx-unprivileged:9.99-nope
kubectl -n shop rollout status deployment/shop-web --timeout=60s
```

```
Waiting for deployment "shop-web" rollout to finish: 1 out of 4 new replicas have been updated...
error: timed out waiting for the condition
```

2. Ejecutá la escalera de diagnóstico, de arriba hacia abajo:

```bash
kubectl -n shop get pods
kubectl -n shop describe pod -l app.kubernetes.io/name=shop-web | sed -n '/^Events/,$p' | head -20
```

```
NAME                        READY   STATUS             RESTARTS   AGE
shop-web-6c8f9d5b74-2xk4t   1/1     Running            0          22m
shop-web-7d4b8c9f11-q6r8s   0/1     ImagePullBackOff   0          65s
...

Events:
  Type     Reason     Age                From               Message
  ----     ------     ----               ----               -------
  Normal   Scheduled  66s                default-scheduler  Successfully assigned shop/shop-web-7d4b8c9f11-q6r8s to worker-1
  Normal   Pulling    66s                kubelet            Pulling image "nginxinc/nginx-unprivileged:9.99-nope"
  Warning  Failed     64s                kubelet            Failed to pull image ...: manifest unknown
  Warning  Failed     64s                kubelet            Error: ErrImagePull
  Warning  Failed     50s (x3 over 63s)  kubelet            Error: ImagePullBackOff
```

3. Confirmá a nivel del controlador:

```bash
kubectl -n shop get deploy shop-web -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
kubectl -n shop get events --sort-by=.lastTimestamp | tail -8
```

```
Available=True MinimumReplicasAvailable
Progressing=False ProgressDeadlineExceeded
```

4. Recuperate:

```bash
kubectl -n shop rollout undo deployment/shop-web
kubectl -n shop rollout status deployment/shop-web
```

5. Ahora rompelo de otra manera: hacé que falle la readiness probe:

```bash
kubectl -n shop patch deployment shop-web --type json -p \
  '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/nope"}]'
kubectl -n shop rollout status deployment/shop-web --timeout=45s
kubectl -n shop describe pod -l app.kubernetes.io/name=shop-web | grep -A3 'Readiness probe failed' | head -5
```

```
  Warning  Unhealthy  12s (x4 over 32s)  kubelet  Readiness probe failed: HTTP probe failed with statuscode: 404
```

6. Revertí y verificá la recuperación:

```bash
kubectl -n shop rollout undo deployment/shop-web
kubectl -n shop rollout status deployment/shop-web
```

> **Q5.1** — En el paso 1, los Pods viejos siguieron en `Running` y sirviendo tráfico mientras los nuevos fallaban. ¿Qué único campo del manifiesto garantizó eso, y qué habría pasado con `maxUnavailable: 1` y `maxSurge: 0`?
>
> **Q5.2** — El paso 3 muestra `Available=True` y `Progressing=False/ProgressDeadlineExceeded` simultáneamente. Explicá cómo pueden ser ciertas las dos, y cuál tiene que chequear tu gate de CI/CD.
>
> **Q5.3** — Distinguí `ErrImagePull`, `ImagePullBackOff`, `CrashLoopBackOff` y `CreateContainerConfigError`. Para cada uno, nombrá el primer comando que ejecutás y la capa responsable.
>
> **Q5.4** — En el paso 5 la falla de la probe nunca reinició el contenedor, a diferencia de una falla de liveness. Indicá la consecuencia exacta de que falle cada probe, y la caída clásica causada por apuntar ambas al mismo endpoint de salud profundo.
>
> **Q5.5** — Escribí el equivalente en Swarm de la escalera de diagnóstico de los pasos 2 y 3: qué tres comandos te dan el motivo de planificación, el error de la task y el estado de actualización a nivel de servicio.

---

## Ejercicio 6 — Empaquetar la orquestación: Helm

**Objetivo:** convertir los manifiestos en un release versionado y parametrizado, y resolver la trampa del ConfigMap del Ejercicio 4 de forma idiomática.

### Bloque 6.1 — Construir un chart mínimo a mano

1. Creá el esqueleto del chart:

```bash
mkdir -p ~/lab-702.2/chart/shop/templates && cd ~/lab-702.2/chart/shop
```

2. `Chart.yaml`:

```yaml
apiVersion: v2
name: shop
description: Guided-exercise chart for LPI 702.2
type: application
version: 0.1.0
appVersion: "1.27"
```

3. `values.yaml`:

```yaml
replicaCount: 3

image:
  repository: nginxinc/nginx-unprivileged
  tag: "1.27-alpine"
  pullPolicy: IfNotPresent

greeting: "hello from helm"

service:
  type: ClusterIP
  port: 80

resources:
  requests:
    cpu: 25m
    memory: 32Mi
  limits:
    memory: 64Mi
```

4. `templates/configmap.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Release.Name }}-config
  labels:
    app.kubernetes.io/name: {{ .Chart.Name }}
    app.kubernetes.io/instance: {{ .Release.Name }}
data:
  default.conf: |
    server {
        listen 8080;
        default_type text/plain;
        location /healthz { access_log off; return 200 "ok\n"; }
        location / { return 200 "{{ .Values.greeting }}\n"; }
    }
```

5. `templates/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}
  labels:
    app.kubernetes.io/name: {{ .Chart.Name }}
    app.kubernetes.io/instance: {{ .Release.Name }}
    app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
spec:
  replicas: {{ .Values.replicaCount }}
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: {{ .Chart.Name }}
      app.kubernetes.io/instance: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: {{ .Chart.Name }}
        app.kubernetes.io/instance: {{ .Release.Name }}
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 101
      containers:
        - name: nginx
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - name: http
              containerPort: 8080
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 5
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          volumeMounts:
            - name: conf
              mountPath: /etc/nginx/conf.d
            - name: cache
              mountPath: /var/cache/nginx
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: conf
          configMap:
            name: {{ .Release.Name }}-config
        - name: cache
          emptyDir: {}
        - name: tmp
          emptyDir: {}
```

6. `templates/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}
spec:
  type: {{ .Values.service.type }}
  selector:
    app.kubernetes.io/name: {{ .Chart.Name }}
    app.kubernetes.io/instance: {{ .Release.Name }}
  ports:
    - name: http
      port: {{ .Values.service.port }}
      targetPort: http
```

7. Pasá el lint y renderizá localmente: nunca instales algo que no leíste:

```bash
cd ~/lab-702.2/chart
helm lint ./shop
helm template demo ./shop --set greeting="rendered locally" | grep -A2 'checksum/config'
```

```
==> Linting ./shop
1 chart(s) linted, 0 chart(s) failed

      annotations:
        checksum/config: 8c1f0a4d9e2b6a7c5f31d0be44a9c7f2b8e1d603a5c7e9f0b2d4a6c8e0f1a3b5
```

8. Instalá e inspeccioná el estado del release:

```bash
helm upgrade --install demo ./shop -n shop --create-namespace --atomic --wait --timeout 3m
helm -n shop list
kubectl -n shop get secret -l owner=helm
```

```
NAME    NAMESPACE  REVISION  UPDATED               STATUS    CHART        APP VERSION
demo    shop       1         2026-09-03 12:04:11   deployed  shop-0.1.0   1.27

NAME                          TYPE                 DATA   AGE
sh.helm.release.v1.demo.v1    helm.sh/release.v1   1      40s
```

9. Cambiá solo el greeting y mirá cómo la anotación de checksum fuerza un rollout:

```bash
helm upgrade demo ./shop -n shop --set greeting="hello from helm v2" --atomic --wait
kubectl -n shop rollout status deployment/demo
kubectl -n shop run curl --rm -it --restart=Never --image=curlimages/curl:8.10.1 -- curl -s http://demo/
```

```
Release "demo" has been upgraded. Happy Helming!
REVISION: 2
deployment "demo" successfully rolled out
hello from helm v2
```

10. Revertí el release:

```bash
helm -n shop history demo
helm -n shop rollback demo 1 --wait
kubectl -n shop run curl --rm -it --restart=Never --image=curlimages/curl:8.10.1 -- curl -s http://demo/
```

```
REVISION  UPDATED              STATUS      CHART       APP VERSION  DESCRIPTION
1         2026-09-03 12:04:11  superseded  shop-0.1.0  1.27         Install complete
2         2026-09-03 12:09:33  deployed    shop-0.1.0  1.27         Upgrade complete

Rollback was a success! Happy Helming!
hello from helm v2   <-- read Q6.5 before trusting this
```

> **Q6.1** — Explicá la línea de la anotación `checksum/config` token por token: ¿a qué se resuelve `$.Template.BasePath`, por qué `include` y no `.Files.Get`, y qué problema del Ejercicio 4 resuelve la línea entera?
>
> **Q6.2** — Contrastá `helm template`, `helm install --dry-run` y `kubectl apply --dry-run=server`. ¿Cuál atrapa un `apiVersion` inválido, y cuál atrapa un template de Go mal escrito?
>
> **Q6.3** — Se usa `helm upgrade --install --atomic --wait` en vez de un `helm upgrade` pelado. ¿Qué te da cada uno de los tres flags, y qué hace `--atomic` ante una falla que `--wait` a secas no hace?
>
> **Q6.4** — Helm 3 guarda `sh.helm.release.v1.demo.v1` como un Secret en el namespace del release. ¿Cuáles son las consecuencias operativas: dónde lo respaldás, qué pasa si dos operadores actualizan concurrentemente, y en qué se diferencia esto de Helm 2?
>
> **Q6.5** — El rollback del paso 10 parece haber devuelto el contenido viejo, y sin embargo la salida de curl muestra `v2`. Dá las dos explicaciones más probables y los comandos exactos que las distinguen.
>
> **Q6.6** — Posicioná Helm frente a `docker stack deploy` y `kubectl apply -f` puro. ¿Cuál de los tres te da historial de releases y rollback atómico, y cuál te da reconciliación de estado deseado del lado del servidor? ¿Son la misma propiedad?

### Limpieza

```bash
helm -n shop uninstall demo
kubectl delete namespace shop
docker compose -f ~/lab-702.2/compose/compose.yaml down -v
```

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1 — Compose

**A1.1.** La forma corta garantiza solo el *orden de arranque*: Compose crea e inicia `cache` antes de iniciar `web`, y los detiene en orden inverso. No dice nada sobre que la dependencia sea utilizable: un contenedor de Redis está "iniciado" en el instante en que se hace exec del proceso, milisegundos antes de que pueda aceptar conexiones. `condition: service_healthy` condiciona a que el `healthcheck` del contenedor pase a `healthy`, es decir, que `redis-cli ping` devuelva `PONG`. Las tres condiciones son `service_started` (la forma corta por defecto), `service_healthy` (requiere un `healthcheck` en la dependencia; Compose da error si no lo hay) y `service_completed_successfully` (la dependencia salió con 0 — la condición correcta para jobs de migración/seed). Nota de producción: incluso `service_healthy` es una barrera solo de *arranque*. No te protege si la dependencia muere más tarde, así que la aplicación igual necesita reintentos de conexión con backoff. Ref: <https://docs.docker.com/reference/compose-file/services/#depends_on>

**A1.2.** `internal: true` quita el gateway por defecto de esa red bridge, así que los contenedores conectados *solo* a `backend` no tienen ruta hacia el mundo exterior: sin egress a internet y sin ingress externo. **No** bloquea el tráfico contenedor-a-contenedor dentro de la red, y no bloquea la resolución DNS vía el resolver embebido en 127.0.0.11. A `web` se le sigue llegando por el 8080 porque está conectado a *dos* redes: el puerto publicado se bindea en el host y se hace DNAT hacia el contenedor, y la red `frontend` provee el gateway. Este es el patrón estándar de dos capas: el almacén de datos no tiene camino a internet aunque sea comprometido.

**A1.3.** `restart: always` en un contenedor que legítimamente sale con 0 crea un bucle de reinicio: Docker lo reinicia, el comando corre de nuevo, sale con 0, Docker lo reinicia. Peor todavía: en este grafo de dependencias `web` espera por `service_completed_successfully`, y un servicio que se reinicia constantemente nunca se asienta en un estado terminal de completado — `docker compose up` se bloquea o expira. Los jobs de un solo uso tienen que ser `restart: "no"` (entre comillas, porque un `no` sin comillas es el booleano YAML `false`) u `on-failure`.

**A1.4.** El nombre del proyecto le da namespace a todos los recursos: contenedores `<project>-<service>-<index>`, redes y volúmenes `<project>_<name>`. Es lo que permite que dos stacks convivan en un mismo engine y lo que usa `docker compose down` para saber qué borrar. Precedencia: flag `-p` > variable de entorno `COMPOSE_PROJECT_NAME` > clave de nivel superior `name:` > basename saneado del directorio del proyecto. Sin `name:`, el ingeniero A en `~/work/shop` y el ingeniero B en `~/repos/shop-app` obtienen los proyectos `shop` y `shop-app` — redes distintas, volúmenes distintos, y un `docker compose down` ejecutado desde el directorio equivocado no hace nada, en silencio. Fijar `name:` en el archivo hace que el despliegue sea reproducible sin importar la ruta del checkout.

**A1.5.** Un puerto publicado es un recurso a nivel de host: `0.0.0.0:8080` puede ser bindeado por exactamente un proceso. Compose pidió tres contenedores haciendo cada uno DNAT del host 8080 → contenedor 80, y el segundo bind falló a nivel del kernel/`docker-proxy`. Esto es una propiedad del modelo: **Compose no tiene balanceador de carga ni routing mesh.** Es una herramienta de un solo host que mapea puertos del host directamente a contenedores. Cualquier orquestador que escale detrás de una sola dirección tiene que insertar una capa que Compose no tiene — la red ingress + IPVS de Swarm, o el Service + kube-proxy/eBPF de Kubernetes. El rango de puertos `8080-8090:80` esquiva el problema dándole a cada réplica su propio puerto de host, que es exactamente el problema de "ahora necesitás un balanceador externo y un registro de servicios" que los orquestadores existen para resolver.

**A1.6.** No: Compose no está balanceando carga. Lo que varía es el *DNS*. El servidor DNS embebido de Docker en 127.0.0.11 resuelve el nombre de servicio `web` a todas las IPs de contenedor de ese servicio y devuelve los registros en orden rotativo (round-robin DNS). La distribución de las *conexiones* queda entonces enteramente a criterio del cliente. Dos modos de falla en producción: (1) **caché del lado del cliente** — las JVMs y muchos clientes HTTP cachean el primer registro A durante toda la vida del proceso (o para siempre, con un `networkaddress.cache.ttl` por defecto de -1), fijando todo el tráfico a una sola réplica; (2) **sin conciencia de salud** — la IP de un contenedor muerto o no listo se retira solo cuando el contenedor se detiene, así que el DNS sigue entregando direcciones de contenedores que no pueden servir, y no hay ninguna barrera de readiness. Esto es precisamente por lo que Swarm usa VIP por defecto en vez de DNSRR.

**A1.7.** Compose V2 respeta `deploy.replicas` (equivalente a `--scale`) y `deploy.resources.limits` / `reservations` (traducidos a límites de cgroup). Ignora las claves exclusivas de Swarm: `deploy.placement`, `deploy.update_config`, `deploy.rollback_config`, `deploy.endpoint_mode`, `deploy.mode: global`. Las claves ignoradas se descartan en silencio o con una advertencia — y ahí está la trampa: el mismo archivo se comporta distinto bajo `docker compose up` y bajo `docker stack deploy`, y la política de actualización que escribiste con tanto cuidado simplemente no se aplica localmente.

**A1.8.** `docker compose down -v` (o `--volumes`) elimina los volúmenes nombrados declarados en la sección `volumes:`. No es el comportamiento por defecto porque los volúmenes nombrados guardan estado: archivos de base de datos, uploads, certificados. `down` es el verbo rutinario de "detener este stack"; hacerlo destructivo por defecto convertiría un reinicio ordinario en un evento de pérdida de datos. Los volúmenes anónimos también los elimina `--volumes`; `--rmi local|all` además elimina imágenes.

---

### Ejercicio 2 — Swarm

**A2.1.** Con Compose, el estado deseado vive en el archivo *más tu shell*: el cliente lee el archivo y emite llamadas imperativas a la API de contenedores. Nada en el host recuerda "tiene que haber tres de estos". Con Swarm, `docker stack deploy` envía una **service spec** al manager, que la persiste en el almacén del clúster replicado por Raft; el orquestador después reconcilia continuamente el estado real contra ella. Matar el PID 1 de un contenedor: con Compose, queda muerto salvo que hayas puesto `restart:` (y entonces es el *engine*, no un orquestador, reiniciándolo en el lugar — el mismo contenedor, con el contador de reinicios incrementado). Con Swarm, la task entra en `Failed` y el orquestador planifica una **task nueva** — un contenedor completamente nuevo, posiblemente en otro nodo — sujeto a `restart_policy`. La distinción entre "reiniciar el contenedor" y "replanificar la task" es la esencia de la orquestación.

**A2.2.** `docker stack deploy` imprime `Ignoring unsupported options: build, depends_on` e ignora `restart:` en favor de `deploy.restart_policy`. Arquitectónicamente: **`build:`** — el manager planifica tasks en nodos arbitrarios que todos tienen que poder descargar una imagen idéntica; un contexto de build existe solo en tu estación de trabajo, así que las imágenes tienen que construirse y publicarse en un registry de antemano. **`depends_on:`** — expresa un orden de arranque en un host, pero en un clúster el planificador ubica tasks concurrentemente entre nodos y cualquier nodo puede morir y replanificar en cualquier momento; no hay una primitiva global de "arrancá A y después B", ni tendría sentido, porque tras la caída de un nodo B puede reiniciar antes que A. Por lo tanto el orden lo tiene que manejar la aplicación (retry/backoff) o un patrón de init container. **`restart:`** es una política del engine por contenedor; en un clúster la decisión equivalente le corresponde al orquestador, de ahí `deploy.restart_policy` con `condition`, `delay`, `max_attempts` y `window`.

**A2.3.** El driver overlay construye una red de capa 2 que abarca múltiples hosts encapsulando las tramas Ethernet de los contenedores en **VXLAN** (UDP), de modo que contenedores en nodos distintos comparten un espacio de direcciones plano y un mismo namespace de DNS embebido; una red bridge es local al host y no puede hacer esto. Se requiere entre nodos: **TCP 2377** (gestión del clúster / Raft, solo managers), **TCP+UDP 7946** (gossip del plano de control, descubrimiento de nodos), **UDP 4789** (plano de datos VXLAN). Una falla muy común es que el 4789 esté bloqueado o colisione con un despliegue VXLAN/VMware NSX existente: los contenedores se resuelven entre sí pero el tráfico se pierde en silencio. Ref: <https://docs.docker.com/engine/network/drivers/overlay/>

**A2.4.** Los dos modos son **VIP** (por defecto) y **DNSRR**. En modo VIP, Swarm asigna una IP *virtual* por servicio y por red conectada. `nslookup api` devuelve esa única VIP estable. No pertenece a ningún contenedor; es un destino de balanceo de carga programado en el kernel de cada nodo participante con **IPVS** (vía iptables/ipvsadm en el network namespace del nodo). Una conexión a 10.0.1.2 recibe DNAT de IPVS por round-robin hacia una de las IPs de task sanas. `tasks.<service>` es la vía de escape: siempre devuelve los registros A de cada task individual, en cualquier modo. La ventaja de VIP del lado del cliente es decisiva: los clientes cachean una dirección para siempre y esa dirección nunca queda obsoleta, mientras IPVS actualiza el conjunto de backends a medida que las tasks van y vienen, y las tasks no sanas se quitan del conjunto.

**A2.5.** Con `endpoint_mode: dnsrr` no se asigna VIP: `nslookup api` devuelve las tres IPs de task directamente, exactamente como `tasks.api`, y la decisión de balanceo vuelve al cliente. La sección `ports:` se rompe: **DNSRR es incompatible con la publicación en `mode: ingress`**, porque la routing mesh está implementada sobre la VIP del servicio; desplegarlo falla con "port published with ingress mode can't be used with dnsrr mode" y tenés que pasar a `mode: host`. DNSRR es incorrecto para cualquier cliente que cachee DNS o mantenga conexiones de larga duración (aplicaciones JVM, pools de conexiones, canales gRPC): se fijan a un backend y nunca se enteran de la replanificación. Es correcto para clientes que hacen su propio balanceo consciente del servicio, y es obligatorio cuando el protocolo del backend no se lleva bien con DNAT TCP/UDP o cuando deliberadamente querés direccionamiento por endpoint (por ejemplo, bases de datos en clúster).

**A2.6.** Sí. Eso es la **routing mesh**. Cada nodo del swarm participa en la red overlay `ingress` y programa el puerto publicado en *todos* los nodos, corran o no una task. Un paquete que llega al 8080 en un nodo sin réplicas lo toma el sandbox de ingress, IPVS lo balancea hacia la IP de una task sana, y se reenvía por la red VXLAN `ingress` al nodo que efectivamente la ejecuta. Esto es lo que hace que cualquier nodo sea un destino válido para un balanceador L4 externo o un round-robin DNS: apuntás a todos los nodos y nunca tenés que rastrear la ubicación. Costo: un salto de red extra y la pérdida de la IP de origen del cliente (SNAT). Ref: <https://docs.docker.com/engine/swarm/ingress/>

**A2.7.** `mode: host` bindea el puerto publicado directamente en la interfaz del nodo, solo para la task local, sorteando por completo ingress e IPVS. **Ganás:** un salto menos (menor latencia) y se preserva la IP de origen real del cliente — algo que importa para logging de acceso, rate limiting y geo-routing. **Perdés:** tenés que saber qué nodos ejecutan el servicio, así que un balanceador externo necesita una integración real de service discovery; y no hay un puerto a nivel de clúster. **Límite de réplicas:** un puerto de host es exclusivo, así que hay como máximo **una task por nodo** por puerto publicado. En la práctica se combina `mode: host` con `deploy.mode: global` (una task por nodo): el patrón estándar para controladores de ingress y agentes locales de nodo.

---

### Ejercicio 3 — Rolling updates y rollback

**A3.1.** Con `parallelism: 1` y `order: start-first`, para cada una de las tres tasks por turno: arrancar la task nueva → esperar a que llegue a `Running` y pase sana la ventana de `monitor` → detener la task vieja → esperar `delay: 10s` → siguiente task. El pico es de 4 tasks (N+1), el mínimo es 3: la capacidad nunca baja del valor deseado. `order: stop-first` lo invierte: detiene la task vieja y después arranca la nueva, así que el pico es 3 y el **mínimo es 2** — corrés degradado durante la actualización. `stop-first` es obligatorio cuando la task retiene un recurso exclusivo que dos instancias no pueden compartir: un puerto de host bajo `mode: host`, un lock de volumen de único escritor, una identidad fija de clúster, o un producto limitado por asientos de licencia.

**A3.2.** Durante los `monitor: 20s` posteriores al arranque de cada task, Swarm observa si esa task se mantiene en `Running` y — si la imagen define un `healthcheck` — si llega a `healthy` y se mantiene así. Una task que sale, es rechazada o falla su healthcheck dentro de la ventana de monitor cuenta como una task de actualización fallida. `max_failure_ratio: 0` significa *tolerancia cero*: una task fallida de tres (ratio 0.33 > 0) dispara `failure_action`, acá `rollback`. Sin un `healthcheck`, la ventana de monitor solo puede detectar una *caída*: un proceso que arranca y después devuelve 500 a cada request le parece perfectamente sano al planificador, y la versión mala se despliega al 100%. El healthcheck es lo que convierte "el proceso está vivo" en "el servicio funciona", así que es la parte estructural de cualquier estrategia de rollback automatizado.

**A3.3.** `Rejected` significa que el **agente del nodo** se negó a ejecutar la task: nunca llegó a ser un contenedor. Causas: la imagen no se puede descargar, falta el origen de un mount, no existe un secret/config, un usuario o capability inválidos. `Failed` significa que el contenedor **corrió y después terminó** de forma anormal: salida distinta de cero, OOM-kill, healthcheck agotado. La distinción orienta tu investigación: `Rejected` es un problema de infraestructura/spec (credenciales del registry, configuración del nodo, typo en la spec), `Failed` es un problema de la aplicación. Los dos se ven con `docker service ps --no-trunc <svc>`; el `--no-trunc` importa porque la columna de error se trunca por defecto y el truncado suele cortar justo la parte interesante.

**A3.4.** Swarm vuelve a la **service spec anterior completa**, no solo a la imagen: entorno, mounts, límites de recursos, cantidad de réplicas, redes, labels, comando, healthcheck — cada campo del `ServiceSpec`. El manager guarda la última spec conocida como buena en `.PreviousSpec` del objeto de servicio, persistida en el almacén Raft de los managers. Dos consecuencias: hay exactamente **un** nivel de historial (revertir dos veces te devuelve al punto de partida — es un interruptor, no una pila), así que Swarm no sustituye manifiestos versionados en Git; y el rollback en sí se rige por `rollback_config`, no por `update_config`, que es por lo que `rollback_config: {parallelism: 0}` es una elección común — parallelism 0 significa "todas las tasks a la vez", es decir, volver a un estado seguro lo más rápido posible.

**A3.5.** Por defecto la CLI resuelve el tag a un digest de contenido inmutable (`sha256:...`) en el momento de la actualización y distribuye *ese* a cada nodo. Sin eso, cada nodo descarga `myapp:latest` de forma independiente en el momento en que le toque planificar una task — y si el tag se vuelve a publicar en medio del rollout, o un nodo tiene una capa cacheada obsoleta, terminás con código distinto corriendo bajo un mismo nombre de servicio, produciendo una caída casi imposible de diagnosticar porque `docker service ls` muestra un único string de imagen consistente. Fijar el digest hace que el rollout sea atómico en contenido. El flag es `--no-resolve-image`. La advertencia que viste simplemente decía que el tag no se pudo encontrar en el registry para resolverlo — que era el error real, expuesto como advertencia.

**A3.6.** `drain` marca el nodo como no disponible **y desaloja**: cada task en él se detiene y se replanifica en otros nodos `Active`, y no se ubican tasks nuevas ahí. `pause` frena la ubicación *nueva* pero **deja las tasks en ejecución donde están**. Antes de una actualización de kernel / reinicio querés `drain`, para que la carga ya se haya movido y convergido en otro lado antes de que el nodo caiga; después del reinicio ponés `--availability active` y (ojo) las tasks **no** se rebalancean de vuelta automáticamente — Swarm no mueve preventivamente tasks en ejecución, así que el nodo queda vacío hasta la próxima actualización o evento de escalado, o hasta que lo fuerces con `docker service update --force`. `pause` es para depurar un nodo sin perturbar lo que corre en él.

---

### Ejercicio 4 — Kubernetes

**A4.1.** El Deployment es un controlador declarativo de ReplicaSets; cada ReplicaSet es un controlador de un conjunto de Pods que coincide con un hash exacto de plantilla de pod. Ante un cambio de plantilla, el Deployment crea un ReplicaSet **nuevo** y traslada réplicas del viejo al nuevo según `strategy`. La propiedad se expresa mediante `metadata.ownerReferences` en cada hijo, que también es lo que hace que el borrado se propague en cascada. **El historial vive en los ReplicaSets viejos retenidos**: `kubectl rollout history` y `rollout undo` simplemente los leen y los reescalan; por eso `revisionHistoryLimit` controla hasta dónde podés retroceder. Borrar a mano el ReplicaSet actual borra sus Pods (en cascada), y entonces el controlador del Deployment reconcilia de inmediato y crea un ReplicaSet *nuevo*: una manera de hacer `rollout restart` con caída total.

**A4.2.** `spec.selector` es **inmutable** en los Deployments de `apps/v1`. El API server rechaza el cambio: `The Deployment "shop-web" is invalid: spec.selector: Invalid value: ...: field is immutable`. La razón es el orfanato: el selector es el único vínculo entre el Deployment y sus ReplicaSets/Pods. Cambiarlo dejaría los ReplicaSets existentes sin dueño y todavía corriendo, mientras el Deployment crea un conjunto nuevo — duplicando en silencio tu carga de trabajo sin ningún controlador gestionando la mitad vieja. Para cambiar un selector tenés que borrar y recrear el Deployment (con `--cascade=orphan` si querés un traspaso sin downtime, y después adoptar/limpiar manualmente).

**A4.3.** `shop-web` (ClusterIP) ↔ **modo VIP** de Swarm: una dirección virtual estable al frente de los backends sanos. `shop-web-headless` (`clusterIP: None`) ↔ **DNSRR** / `tasks.<service>` de Swarm: el DNS devuelve las IPs de los Pods directamente. La diferencia de comportamiento está en el camino de datos: la VIP de Swarm se implementa con **IPVS en el sandbox de ingress/overlay**, mientras que el ClusterIP de Kubernetes lo implementa **kube-proxy** — históricamente reglas de DNAT en iptables con `statistic random probability` (o sea, aleatorio estadístico más que round robin verdadero), opcionalmente en modo IPVS, y en las CNIs modernas (Cilium) reemplazado por completo por eBPF en la capa de socket. Una segunda diferencia, más importante: Kubernetes condiciona la membresía a la **readiness** (un Pod se saca del EndpointSlice en el momento en que su readiness probe falla, sin ser matado), algo que Swarm no tiene equivalente: allí la falla del healthcheck lleva al reemplazo de la task, no a una retirada silenciosa del conjunto de balanceo.

**A4.4.** `targetPort` acepta o bien un número o bien el *nombre* de un `containerPort`. Nombrarlo desacopla el Service del puerto de escucha del contenedor: si más adelante la imagen pasa de 8080 a 8081, editás solo la plantilla del Pod, y el Service, las probes (`port: http`) y cualquier NetworkPolicy que referencie el nombre siguen automáticamente. También documenta la intención — `http` versus `metrics` versus `grpc` — y es imprescindible en Services multipuerto, donde los números posicionales se vuelven ambiguos. El `port: 80` propio del Service es el contrato estable para los clientes y no debería seguir al contenedor.

**A4.5.** nginx tiene que escribir en dos rutas en tiempo de ejecución: `/var/cache/nginx` (rutas temporales de proxy/client/fastcgi, creadas por `ngx_create_paths` durante el arranque) y `/tmp` (la imagen unprivileged escribe su archivo PID en `/tmp/nginx.pid`). Montar volúmenes `emptyDir` ahí provee almacenamiento escribible, con alcance de vida del contenedor, sobre la raíz de solo lectura. Sin ellos el contenedor sale de inmediato y el Pod entra en `CrashLoopBackOff`; `kubectl logs` muestra `nginx: [emerg] mkdir() "/var/cache/nginx/client_temp" failed (30: Read-only file system)`. El patrón general: `readOnlyRootFilesystem: true` más una lista explícita y auditable de rutas escribibles — un atacante con ejecución de código no puede dejar un binario en ningún otro lado.

**A4.6.** Se aplican mediante mecanismos distintos del kernel con semánticas de falla distintas. La **memoria** es incompresible: exceder `limits.memory` hace que el proceso sea **OOM-killed** por el controlador de memoria del cgroup (contenedor terminado, `Reason: OOMKilled`, exit 137). No hay degradación gradual, así que el límite es esencial para impedir que un Pod tumbe su nodo. La **CPU** es compresible: exceder `limits.cpu` provoca **throttling del CFS** — el cgroup queda frenado hasta el próximo período de 100 ms. No se mata nada, pero la latencia de cola se degrada muchísimo y, como la cuota se aplica por período, los runtimes multihilo pueden ser throttleados con el nodo ocioso. La guía de producción mayoritaria es, por lo tanto: siempre poner requests de memoria **iguales a** los límites, siempre poner requests de CPU (para la planificación y el peso de reparto justo), y omitir los límites de CPU salvo que necesites aislamiento multi-tenant duro o benchmarking determinista.

**A4.7.** Dos hechos independientes. (1) `rollout status` reportó éxito porque el rollout del Deployment se dispara **únicamente** por cambios en `spec.template`. Editar un ConfigMap no toca la plantilla del Pod, así que no se crea un ReplicaSet nuevo, la generación observada ya coincide, y el Deployment está por definición "desplegado con éxito". El controlador no tiene noción de que un ConfigMap montado sea parte de la identidad de la carga de trabajo. (2) El kubelet *sí* refresca los volúmenes proyectados de ConfigMap — mediante un intercambio atómico de symlink del directorio `..data`, típicamente dentro de un período de sincronización más el TTL de la caché (del orden de un minuto). O sea que **el archivo en disco sí cambió**; lo que no cambió es la configuración en memoria de nginx, porque nginx lee su configuración una sola vez al arrancar y solo la vuelve a leer con `SIGHUP`. Cualquier aplicación que parsee la configuración al arranque necesita un reinicio explícito. (Nota: un ConfigMap consumido vía `envFrom`/`env` *nunca* se refresca — las variables de entorno se fijan al crear el contenedor. Y los mounts con `subPath` tampoco se refrescan nunca.)

**A4.8.** Parchea `spec.template.metadata.annotations["kubectl.kubernetes.io/restartedAt"]` con la marca de tiempo actual. Como ese campo está dentro de la plantilla del pod, el hash de la plantilla cambia, el Deployment crea un ReplicaSet nuevo y toma el control la `strategy` habitual — así que es un reemplazo rolling que respeta `maxSurge`/`maxUnavailable`, las readiness probes, `minReadySeconds` y cualquier PodDisruptionBudget, sin downtime. También se convierte en una revisión normal en `rollout history`, así que es reversible. Por eso `rollout restart` es el verbo correcto y `kubectl delete pod --all` no lo es.

**A4.9.** `maxUnavailable: 0` significa que la cantidad de Pods *disponibles* nunca baja de `replicas`, es decir, nunca baja de 4. `maxSurge: 1` permite un Pod extra por encima del deseado, así que el total nunca supera 5. El rollout avanza de a un Pod: crear el #5, esperar Ready + `minReadySeconds`, terminar un Pod viejo, repetir. El supuesto es que el clúster tiene **capacidad de sobra para un Pod más**: con `maxSurge: 1, maxUnavailable: 0` en un clúster sin margen planificable, el Pod de sobrecarga queda `Pending` (`Insufficient cpu`) y el rollout se cuelga hasta que salte `progressDeadlineSeconds`. Este par es el valor por defecto correcto para servicios web sin estado; los clústeres con capacidad restringida usan `maxSurge: 0, maxUnavailable: 1` y aceptan correr con N-1 durante el rollout.

**A4.10.** `minReadySeconds: 5` exige que un Pod nuevo se mantenga Ready de forma continua durante 5 segundos antes de contar como *disponible* y que el rollout avance. Defiende contra la clase de bug de "pasa la primera probe y después se cae": un Pod que está listo durante 200 ms si no dejaría que el rollout siguiera marchando y tumbara todas las réplicas. `progressDeadlineSeconds: 120` acota cuánto tiempo puede el Deployment *no progresar* antes de que el controlador se dé por vencido: pone

```
type: Progressing
status: "False"
reason: ProgressDeadlineExceeded
message: ReplicaSet "shop-web-7d4b8c9f11" has timed out progressing.
```

Fundamental: esto **marca** la falla; no revierte (los Deployments de Kubernetes, a diferencia de Swarm, no tienen un `failure_action: rollback` automático — eso es lo que provee `--atomic` en Helm, o Argo Rollouts). El temporizador del plazo se reinicia con cualquier progreso, así que un rollout lento pero que avanza no se penaliza.

**A4.11.** Kubernetes retiene los últimos 5 **objetos ReplicaSet viejos** (escalados a 0 réplicas: consumen almacenamiento de la API, no cómputo). Cada uno es una entrada en `rollout history` y un posible destino de `--to-revision`. Con `revisionHistoryLimit: 0`, los ReplicaSets viejos se recolectan de inmediato: `rollout history` no muestra nada útil y `rollout undo` falla con `error: no rollout history found`. Eliminaste tu camino de rollback más rápido — justo el que buscás a las 3 de la mañana cuando reaplicar desde Git está bloqueado porque el cambio en Git es exactamente lo que rompió todo.

---

### Ejercicio 5 — Diagnóstico

**A5.1.** `maxUnavailable: 0`. El controlador no va a terminar un Pod viejo hasta que uno nuevo esté Ready, y ningún Pod nuevo llegó nunca a Ready, así que los cuatro originales siguieron sirviendo: un rollout fallido con impacto cero para el usuario. Con `maxUnavailable: 1, maxSurge: 0` el controlador termina *primero* un Pod viejo y después crea el reemplazo; el reemplazo no logra descargar la imagen, así que quedás permanentemente al 3/4 de capacidad, y según el ritmo del controlador podés perder más. Ese único campo es la diferencia entre "un deploy roto" y "un deploy roto que además es una caída".

**A5.2.** Describen cosas distintas. `Available` refleja si hay al menos `replicas - maxUnavailable` Pods Ready **ahora mismo**, contando viejos y nuevos por igual: los cuatro Pods v1 sanos lo satisfacen, así que `Available=True`. `Progressing` refleja si el Deployment está convergiendo hacia la plantilla **deseada**; no lo está, de ahí `False/ProgressDeadlineExceeded`. Un gate de CI/CD tiene que chequear **`Progressing`**, que es exactamente lo que hace `kubectl rollout status` (sale con código distinto de cero ante `ProgressDeadlineExceeded` o `--timeout`). Condicionar sobre `Available` o sobre un `kubectl get deploy` que muestre `4/4` es el clásico pipeline de falla silenciosa: reporta verde mientras la versión nueva nunca se desplegó.

**A5.3.**

| Estado | Significado | Primer comando | Capa responsable |
|---|---|---|---|
| `ErrImagePull` | El intento de pull acaba de fallar (estado transitorio, primer intento) | `kubectl describe pod` → Events | Registry / referencia de imagen / credenciales |
| `ImagePullBackOff` | Fallas de pull repetidas; el kubelet aplica backoff exponencial (hasta 5 min) | `kubectl describe pod`; revisar `imagePullSecrets`, existencia del tag, red/proxy del nodo | Lo mismo, ahora confirmado como persistente |
| `CrashLoopBackOff` | El contenedor **arrancó** y salió repetidamente; el kubelet aplica backoff a los reinicios | `kubectl logs <pod> --previous` (`-c <container>` si es multicontenedor) | Aplicación / configuración / dependencia faltante |
| `CreateContainerConfigError` | El kubelet no puede construir la spec del contenedor: una clave de ConfigMap/Secret referenciada no existe, o hay una fuente de env inválida | `kubectl describe pod` → Events; después `kubectl get cm,secret` | El manifiesto en sí |

Relacionados: `CreateContainerError` (el runtime lo rechazó — comando inválido, usuario inválido), `RunContainerError`, y `Pending` sin nodo asignado (`kubectl describe pod` → eventos del scheduler: taints, recursos insuficientes, PVC sin vincular).

**A5.4.** Una **readiness** probe que falla quita la dirección del Pod del EndpointSlice del Service: deja de recibir tráfico pero **sigue corriendo**, así que podés hacer exec dentro y depurar, y se reincorpora automáticamente cuando se recupera. Una **liveness** probe que falla hace que el kubelet **mate el contenedor** y lo reinicie según `restartPolicy`, incrementando `RESTARTS`. La caída clásica: apuntar ambas probes a un endpoint `/health` que transitivamente chequea la base de datos. La base tiene un hipo → la liveness de cada Pod falla simultáneamente → el kubelet mata cada réplica de cada servicio a la vez → todas reinician, martillan la base en recuperación con reconexiones, fallan de nuevo, y el clúster entra en un `CrashLoopBackOff` en cascada que sobrevive a la falla original. Regla: **la liveness tiene que ser superficial y local** ("¿mi proceso está trabado?"), **la readiness puede ser profunda** ("¿puedo atender una request ahora mismo?"), y las aplicaciones de arranque lento llevan un `startupProbe` en vez de un `initialDelaySeconds` inflado.

**A5.5.**

```bash
docker service ps <svc> --no-trunc            # per-task node, desired/current state, and the full ERROR column
docker service logs <svc> --tail 100 -f       # aggregated stdout/stderr across all tasks (application layer)
docker service inspect <svc> --pretty         # or --format '{{json .UpdateStatus}}' — service-level update/rollback state
```

Más `docker inspect <task-container>` en el nodo para el log del healthcheck (`.State.Health.Log`), y `docker node ps <node>` para ver todo lo planificado en un nodo sospechoso. La correspondencia con la escalera de Kubernetes es: `service ps` ≈ `kubectl get pods` + eventos de `describe`, `service logs` ≈ `kubectl logs`, `service inspect .UpdateStatus` ≈ las `.status.conditions` del Deployment.

---

### Ejercicio 6 — Helm

**A6.1.** `$.Template.BasePath` es la ruta relativa al chart del directorio de templates del chart que se está renderizando (`shop/templates`); `$` es el contexto raíz, así que se resuelve correctamente incluso dentro de un bloque `range` o `with` donde `.` fue reasignado. `print` lo concatena con `/configmap.yaml` para formar el nombre del template tal como lo registró Helm. `include` renderiza ese template nombrado **como un string** con el contexto actual, así que todos los values, el nombre del release y las funciones que contiene se expanden — `.Files.Get` devolvería el archivo crudo, sin renderizar, con lo cual un cambio de greeting no alteraría el checksum. `sha256sum` hashea el texto renderizado dentro de la anotación de la plantilla del Pod. Efecto: cualquier cambio en el contenido renderizado del ConfigMap cambia `spec.template`, lo que cambia el hash de la plantilla del pod, lo que crea un ReplicaSet nuevo — un rolling update normal. Esto resuelve A4.7 de forma declarativa: los cambios de configuración se vuelven despliegues, reversibles vía `helm rollback` y `kubectl rollout undo`.

**A6.2.** `helm template` renderiza localmente **sin contacto con el clúster**: atrapa errores de template de Go, values faltantes e indentación mal formada, y es lo que diffeás en CI. `helm install --dry-run` renderiza *y además* envía los manifiestos al API server para validación, así que atrapa un `apiVersion` inválido, un campo desconocido, una violación de campo inmutable y rechazos de admission webhooks (agregá `--dry-run=server` en Helm 3.13+ para un dry run completo del lado del servidor; el `--dry-run` viejo a secas es renderizado del lado del cliente con validación limitada). `kubectl apply --dry-run=server` ejecuta la cadena completa de admisión, incluidos los webhooks de mutación/validación y los chequeos de cuota, pero recibe YAML ya renderizado, así que no puede ver un error de template de Go en absoluto. Pipeline práctico: `helm lint` → `helm template | kubeconform` → `helm upgrade --install --dry-run=server` → upgrade real.

**A6.3.** `--install` hace idempotente al comando: instala si el release no existe, actualiza si existe — un solo comando para ambos caminos de CI, sin rama de "release not found". `--wait` bloquea hasta que los recursos creados reporten estar listos (Deployments/StatefulSets/DaemonSets en sus cuentas de readiness esperadas, Services con endpoints, PVCs vinculados) o expire `--timeout`, de modo que el código de salida del pipeline refleje el estado real de la carga de trabajo y no un "el API server aceptó mi YAML". `--atomic` implica `--wait` **y agrega rollback automático ante falla**: si la espera expira o algún recurso falla, Helm restaura la revisión anterior del release, con lo cual un deploy fallido deja el clúster en el último estado bueno conocido en vez de a mitad de migrar. Sin `--atomic`, un upgrade que expira deja el release en estado `failed` *y además* deja corriendo los objetos rotos. Ojo que `--atomic` extiende el costo en tiempo de un mal deploy (esperás el timeout, y después el rollback), así que definí `--timeout` deliberadamente.

**A6.4.** Cada revisión es un Secret comprimido con gzip y codificado en base64, llamado `sh.helm.release.v1.<release>.v<revision>`, en el namespace del release. Consecuencias: (1) **Backup** — el historial del release es estado del clúster con alcance de namespace, así que tu backup de etcd/Velero lo cubre, pero un `kubectl delete ns` destruye todo el historial del release junto con la carga de trabajo; el chart en Git es la verdadera fuente de verdad. (2) **Concurrencia** — no hay lock distribuido; dos `helm upgrade` simultáneos compiten, y el desenlace común es un release trabado en `pending-upgrade`, tras lo cual todo upgrade posterior falla con `another operation is in progress` hasta que hagas `helm rollback` o borres el Secret de la revisión pendiente. Serializá los deploys por release en CI. (3) **Frente a Helm 2** — Helm 2 guardaba el estado como ConfigMaps en `kube-system`, escritos por **Tiller**, un componente del lado del servidor a nivel de clúster que típicamente corría con `cluster-admin`; cualquiera que pudiera hablarle a Tiller heredaba esos permisos. Helm 3 eliminó Tiller por completo: el cliente usa *tu* kubeconfig y tu RBAC, y el estado pasó a Secrets en el namespace del release. Notá también que un chart grande puede superar el límite de ~1 MiB por objeto de Secret/etcd.

**A6.5.** Lo más probable: (a) **el rollback todavía está convergiendo** — `helm rollback` sin `--wait` retorna apenas los objetos de la API quedan parcheados, y hiciste el curl mientras el ReplicaSet nuevo todavía estaba desplegándose; o (b) **diste con un endpoint obsoleto** — el Pod de `curl` resolvió el Service y se conectó a un Pod v2 todavía no terminado. Una tercera posibilidad, más sutil, en un chart real: el nombre del ConfigMap está templatizado por release pero la comparación de *contenido* ocurrió contra un patch de tres vías fusionado que descartó tu cambio. Comandos para distinguirlas:

```bash
helm -n shop history demo                                   # is revision 3 'deployed'?
helm -n shop status demo
kubectl -n shop rollout status deployment/demo              # has it converged?
kubectl -n shop get cm demo-config -o jsonpath='{.data.default\.conf}'   # what is the desired config now?
kubectl -n shop get rs -l app.kubernetes.io/instance=demo   # which ReplicaSets still have replicas?
kubectl -n shop get pods -o custom-columns=\
NAME:.metadata.name,ANN:.metadata.annotations.checksum/config
```

Comparar el contenido del ConfigMap con la anotación `checksum/config` de cada Pod te dice de inmediato si la configuración revirtió y los Pods no se pusieron al día, o si el rollback en sí no incluyó el ConfigMap. La lección general: **siempre usá `--wait` en un rollback, y verificá a nivel de objeto, nunca por un único request a través de un balanceador de carga.**

**A6.6.** Resuelven problemas ortogonales.

- **`kubectl apply -f`** — estado deseado del lado del servidor, reconciliado continuamente por los controladores. Sin agrupación por release, sin historial más allá del `rollout history` por recurso, sin rollback atómico multiobjeto.
- **`docker stack deploy`** — estado deseado del lado del servidor, reconciliado continuamente por el orquestador de Swarm. Historial limitado a una spec anterior por servicio (`.PreviousSpec`), el rollback es por servicio, no por stack.
- **Helm** — un *gestor de releases del lado del cliente*: templating, values, historial de revisiones, install/upgrade/rollback atómico de todo un release multiobjeto. Pero Helm **no** reconcilia: una vez aplicados los objetos, los propios controladores de Kubernetes hacen todo el trabajo continuo, y si alguien edita un Deployment a mano, Helm ni se entera ni lo corrige (solo lo nota en el siguiente upgrade, vía el merge de tres vías — de ahí `helm diff` y el instrumental de detección de deriva).

Así que **historial de releases + rollback atómico** y **reconciliación de estado deseado** son propiedades genuinamente distintas. Helm aporta la primera; Kubernetes y Swarm aportan la segunda. Las herramientas de GitOps (Argo CD, Flux) existen precisamente para agregar reconciliación continua *de la propia definición del release*, cerrando el bucle que Helm deja abierto.

</details>

---

## Fuentes

- LPI — Objetivos del Examen 701 (DevOps Tools Engineer, versión 2.0): <https://www.lpi.org/our-certifications/exam-701-objectives/>
- Docker — Referencia del archivo Compose: <https://docs.docker.com/reference/compose-file/>
- Docker — `depends_on` de Compose y condiciones de servicio: <https://docs.docker.com/reference/compose-file/services/#depends_on>
- Docker — Panorama del modo Swarm: <https://docs.docker.com/engine/swarm/>
- Docker — Desplegar un stack en un swarm: <https://docs.docker.com/engine/swarm/stack-deploy/>
- Docker — Usar la routing mesh del modo swarm: <https://docs.docker.com/engine/swarm/ingress/>
- Docker — Driver de red overlay: <https://docs.docker.com/engine/network/drivers/overlay/>
- Docker — Aplicar rolling updates a un servicio: <https://docs.docker.com/engine/swarm/swarm-tutorial/rolling-update/>
- Docker — Referencia de `docker service update`: <https://docs.docker.com/reference/cli/docker/service/update/>
- Kubernetes — Deployments: <https://kubernetes.io/docs/concepts/workloads/controllers/deployment/>
- Kubernetes — Service: <https://kubernetes.io/docs/concepts/services-networking/service/>
- Kubernetes — DNS para Services y Pods: <https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/>
- Kubernetes — Configurar probes de Liveness, Readiness y Startup: <https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/>
- Kubernetes — ConfigMaps: <https://kubernetes.io/docs/concepts/configuration/configmap/>
- Kubernetes — Gestión de recursos para Pods y contenedores: <https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/>
- Helm — Charts: <https://helm.sh/docs/topics/charts/>
- Helm — `helm upgrade`: <https://helm.sh/docs/helm/helm_upgrade/>
- Helm — Consejos y trucos para desarrollar charts (patrón del checksum de ConfigMap): <https://helm.sh/docs/howto/charts_tips_and_tricks/>