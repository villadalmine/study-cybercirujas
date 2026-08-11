# LPIC-3 305 · Tema 352.4 — Plataformas de orquestación de contenedores
## Ejercicios guiados (examen 305-300, v3.0 · peso 5)

> **Alcance de este tema.** El objetivo 352.4 del 305-300 te pide *entender la importancia de la orquestación de contenedores y los conceptos clave de Docker Compose y Docker Swarm*, *usar* ambos de verdad, y tener *conocimiento de Kubernetes y Helm*. Los términos y utilidades con los que debés tener soltura son: `docker-compose.yml`, `docker compose`, `docker swarm`, `docker node`, `docker service`, `docker stack`.
> Fuente: LPI Exam 305 Objectives — <https://www.lpi.org/our-certifications/exam-305-objectives/>
>
> **Prerrequisitos del laboratorio.** Necesitás Docker Engine ≥ 20.10 con el plugin Compose v2 (`docker compose version`). Para los ejercicios de Swarm necesitás al menos un host con una IP enrutable; un segundo host (o una segunda VM) te permite observar los roles manager/worker de verdad, pero un swarm de un solo nodo alcanza para cada comando de este objetivo.

---

## Ejercicio 1 — Definir y ejecutar una aplicación multiservicio con `docker compose`

**Objetivo:** entender qué declara un `docker-compose.yml` (servicios, redes, volúmenes, dependencias, salud) y por qué la orquestación declarativa es mejor que un script de shell lleno de `docker run`.

### Pasos

1. Creá un directorio de trabajo y entrá en él:

   ```bash
   mkdir -p ~/lab-3524/compose && cd ~/lab-3524/compose
   ```

2. Escribí el siguiente `docker-compose.yml`. Declara tres servicios — un reverse proxy, una API sin estado y una base de datos con estado — más un volumen con nombre y dos redes definidas por el usuario:

   ```yaml
   # docker-compose.yml
   services:
     proxy:
       image: nginx:1.27-alpine
       ports:
         - "8080:80"
       volumes:
         - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
       depends_on:
         api:
           condition: service_healthy
       networks:
         - frontend

     api:
       image: hashicorp/http-echo:1.0
       command: ["-text=hello from api", "-listen=:5678"]
       healthcheck:
         test: ["CMD", "wget", "-qO-", "http://localhost:5678"]
         interval: 5s
         timeout: 3s
         retries: 5
         start_period: 5s
       networks:
         - frontend
         - backend

     db:
       image: postgres:16-alpine
       environment:
         POSTGRES_PASSWORD: s3cret
         POSTGRES_DB: appdb
       volumes:
         - pgdata:/var/lib/postgresql/data
       networks:
         - backend

   volumes:
     pgdata:

   networks:
     frontend:
     backend:
   ```

3. Creá el `nginx.conf` referenciado por el servicio proxy:

   ```bash
   cat > nginx.conf <<'EOF'
   server {
       listen 80;
       location / {
           proxy_pass http://api:5678;
       }
   }
   EOF
   ```

4. Validá y normalizá el archivo **antes** de arrancar nada. `docker compose config` resuelve variables, aplica valores por defecto y falla ruidosamente ante errores de esquema:

   ```bash
   docker compose config
   ```

   Esperado (truncado) — fijate que inyecta los nombres de red/volumen con alcance de proyecto:

   ```yaml
   name: compose
   services:
     api:
       image: hashicorp/http-echo:1.0
       ...
   networks:
     backend:
       name: compose_backend
     frontend:
       name: compose_frontend
   volumes:
     pgdata:
       name: compose_pgdata
   ```

5. Levantá el stack en segundo plano:

   ```bash
   docker compose up -d
   ```

   Esperado:

   ```
   [+] Running 6/6
    ✔ Network compose_frontend  Created
    ✔ Network compose_backend   Created
    ✔ Volume  compose_pgdata     Created
    ✔ Container compose-db-1     Started
    ✔ Container compose-api-1    Healthy
    ✔ Container compose-proxy-1  Started
   ```

6. Inspeccioná el estado y el grafo de servicios resuelto:

   ```bash
   docker compose ps
   ```

   ```
   NAME              IMAGE                    COMMAND                  SERVICE   STATUS                 PORTS
   compose-api-1     hashicorp/http-echo:1.0  "/http-echo -text=he…"   api       Up (healthy)
   compose-db-1      postgres:16-alpine       "docker-entrypoint.s…"   db        Up
   compose-proxy-1   nginx:1.27-alpine        "/docker-entrypoint.…"   proxy     Up                     0.0.0.0:8080->80/tcp
   ```

7. Verificá que la ruta de la petición proxy → api funciona de verdad:

   ```bash
   curl -s http://localhost:8080
   ```

   ```
   hello from api
   ```

8. Demostrá el aislamiento de red. El `proxy` está solo en `frontend`; la `db` está solo en `backend`. Desde el proxy, `api` resuelve pero `db` **no** debe hacerlo:

   ```bash
   docker compose exec proxy sh -c 'getent hosts api; echo "---"; getent hosts db || echo "db unreachable"'
   ```

   ```
   172.19.0.3      api
   ---
   db unreachable
   ```

**Verificación de comprensión — Bloque 1**

1. `docker compose up` creó `compose_frontend` en lugar de una red literalmente llamada `frontend`. ¿De dónde viene el prefijo `compose_` y cómo lo sobrescribís?
2. El servicio `proxy` usa `depends_on ... condition: service_healthy`. ¿Qué espera exactamente, y por qué un simple `depends_on: [api]` (forma de lista) es insuficiente para un servicio que no debe recibir tráfico hasta que la API esté sirviendo de verdad?
3. ¿Por qué el `proxy` pudo resolver `api` por nombre pero no `db`, aunque los tres contenedores corren bajo el mismo proyecto de Compose?
4. El volumen `pgdata` está declarado bajo la clave `volumes:` de nivel superior. ¿Qué pasa con los datos de Postgres si ejecutás `docker compose down`? ¿Y con `docker compose down -v`?

---

## Ejercicio 2 — Escalar un servicio sin estado y leer los límites de Compose

**Objetivo:** ver el escalado horizontal y entender por qué Compose por sí solo es una herramienta de *un solo host* (sin planificación entre máquinas, sin primitiva de rolling update).

### Pasos

1. Escalá la `api` sin estado a tres réplicas sin editar el archivo:

   ```bash
   docker compose up -d --scale api=3
   ```

   ```
   [+] Running 6/6
    ✔ Container compose-api-1    Running
    ✔ Container compose-api-2    Started
    ✔ Container compose-api-3    Started
    ...
   ```

2. Confirmá que ahora tres contenedores respaldan el único nombre de servicio `api`:

   ```bash
   docker compose ps api
   ```

   ```
   NAME            IMAGE                    SERVICE   STATUS
   compose-api-1   hashicorp/http-echo:1.0  api       Up (healthy)
   compose-api-2   hashicorp/http-echo:1.0  api       Up (healthy)
   compose-api-3   hashicorp/http-echo:1.0  api       Up (healthy)
   ```

3. Observá que el DNS embebido de Docker balancea la carga del nombre de servicio entre las tres IPs de los contenedores. Ejecutá la consulta varias veces:

   ```bash
   for i in 1 2 3 4; do docker compose exec -T proxy getent hosts tasks.api 2>/dev/null || docker compose exec -T proxy sh -c 'nslookup api 2>/dev/null | grep Address | tail -n +2'; done
   ```

   Vas a ver rotar las tres IPs de backend. (En Compose el proxy sigue apuntando a un único VIP salvo que hagas round-robin a nivel de DNS; contrastá esto con el VIP + IPVS incorporado de Swarm en el Ejercicio 4.)

4. Ahora intentá hacer un **cambio de imagen sin downtime** como lo hacen los orquestadores. Compose no tiene un verbo de rolling-update — lo más cercano es recrear:

   ```bash
   docker compose up -d --force-recreate api
   ```

   Observá la salida: Compose detiene y recrea los contenedores. No hay `max_parallelism`, ni `order: start-first`, ni rollback automático. Este hueco es toda la razón por la que existe `docker service update` de Swarm.

5. Desarmá el stack (conservá los datos):

   ```bash
   docker compose down
   ```

**Verificación de comprensión — Bloque 2**

1. `docker compose up --scale api=3` funcionó, pero si intentaras `--scale proxy=2` con el archivo actual fallaría. ¿Por qué? (Pista: mirá el mapeo `ports:`.)
2. Nombrá dos capacidades de orquestación que Docker Compose **no** provee por sí solo, y que son precisamente lo que agregan Swarm/Kubernetes.
3. Durante el paso 4, ¿hubo un momento en que cero contenedores `api` estaban sirviendo? ¿Qué ajuste de `update_config` de Swarm lo evitaría?

---

## Ejercicio 3 — Iniciar un Docker Swarm y leer su plano de control

**Objetivo:** entender la arquitectura de Swarm — managers vs workers, el almacén replicado por Raft, los tokens de unión y los roles de nodo.

### Pasos

1. Inicializá un swarm en el host actual. Usá la IP real del host para `--advertise-addr` (reemplazá `192.168.178.20`):

   ```bash
   docker swarm init --advertise-addr 192.168.178.20
   ```

   ```
   Swarm initialized: current node (kf9c... ) is now a manager.

   To add a worker to this swarm, run the following command:

       docker swarm join --token SWMTKN-1-49nj1...-8vx...  192.168.178.20:2377

   To add a manager to this swarm, run 'docker swarm join-token manager' and follow the instructions.
   ```

2. Mirá el inventario de nodos. En un laboratorio de un solo host el único nodo es a la vez manager (plano de control) y worker (ejecuta tareas):

   ```bash
   docker node ls
   ```

   ```
   ID          HOSTNAME   STATUS   AVAILABILITY   MANAGER STATUS   ENGINE VERSION
   kf9c...*    node-a     Ready    Active         Leader           27.1.1
   ```

   El `*` marca el nodo con el que estás hablando; `Leader` es el líder de Raft entre los managers.

3. Recuperá los dos tokens de unión. Son secretos distintos — uno otorga membresía de worker, otro otorga membresía de manager (plano de control):

   ```bash
   docker swarm join-token worker
   docker swarm join-token manager
   ```

4. *(Opcional, laboratorio de dos hosts.)* En un segundo host, unite como worker usando el token de worker del paso 1, luego volvé a ejecutar `docker node ls` **en el manager** para verlo aparecer:

   ```bash
   # on host B:
   docker swarm join --token SWMTKN-1-49nj1...-8vx...  192.168.178.20:2377
   # on host A (manager):
   docker node ls
   ```

   ```
   ID          HOSTNAME   STATUS   AVAILABILITY   MANAGER STATUS   ENGINE VERSION
   kf9c...*    node-a     Ready    Active         Leader           27.1.1
   pa72...     node-b     Ready    Active                          27.1.1
   ```

5. Inspeccioná un nodo para leer su rol, disponibilidad y recursos:

   ```bash
   docker node inspect self --format 'Role={{.Spec.Role}} Availability={{.Spec.Availability}} Addr={{.Status.Addr}}'
   ```

   ```
   Role=manager Availability=active Addr=192.168.178.20
   ```

6. Agregá una etiqueta a un nodo — las etiquetas guían las restricciones de ubicación más adelante:

   ```bash
   docker node update --label-add tier=edge node-a
   docker node inspect node-a --format '{{ .Spec.Labels }}'
   ```

   ```
   map[tier:edge]
   ```

**Verificación de comprensión — Bloque 3**

1. ¿Qué rol cumple el algoritmo de consenso Raft en un Swarm, y qué nodos participan en él — managers, workers, o ambos?
2. En un swarm de producción te dicen que ejecutes 4 managers. ¿Por qué es una *peor* elección que 3 o 5? Enunciá la regla de tolerancia a fallos.
3. El token de unión de worker y el de manager son distintos. ¿Cuál es la consecuencia de seguridad de filtrar específicamente el token de **manager**?
4. ¿Cuál es la diferencia entre que la `AVAILABILITY` de un nodo sea `Active`, `Pause` o `Drain`?

---

## Ejercicio 4 — Desplegar, escalar y actualizar un `docker service`

**Objetivo:** usar el planificador de Swarm directamente — `docker service` — y observar el bucle de reconciliación, la routing mesh, los rolling updates y el rollback.

### Pasos

1. Creá un servicio replicado. Swarm planifica tareas (contenedores) para satisfacer el número de réplicas declarado y publica el puerto 8080 en la **routing mesh** (cada nodo acepta el puerto y reenvía a una tarea saludable):

   ```bash
   docker service create --name web --replicas 3 --publish published=8080,target=80 nginx:1.27-alpine
   ```

   ```
   z1k3m... 
   overall progress: 3 out of 3 tasks
   1/3: running
   2/3: running
   3/3: running
   verify: Service converged
   ```

2. Listá los servicios e inspeccioná las tareas individuales y dónde quedaron ubicadas:

   ```bash
   docker service ls
   docker service ps web
   ```

   ```
   ID       NAME   MODE         REPLICAS   IMAGE               PORTS
   z1k3m…   web    replicated   3/3        nginx:1.27-alpine   *:8080->80/tcp

   ID       NAME    IMAGE               NODE     DESIRED STATE   CURRENT STATE
   a1b2…    web.1   nginx:1.27-alpine   node-a   Running         Running 40 seconds ago
   c3d4…    web.2   nginx:1.27-alpine   node-b   Running         Running 40 seconds ago
   e5f6…    web.3   nginx:1.27-alpine   node-a   Running         Running 40 seconds ago
   ```

3. Probá el bucle de reconciliación. Matá a mano el contenedor de una tarea y observá cómo Swarm lo reemplaza:

   ```bash
   docker rm -f $(docker ps --filter "name=web." -q | head -1)
   sleep 3
   docker service ps web --filter desired-state=running
   ```

   Vas a ver una nueva tarea con un nombre incrementado (p. ej. `web.2` obtiene un ID de tarea nuevo) — el estado declarado (`3/3`) se restaura automáticamente. La tarea fallida muestra `Shutdown/Failed` en el historial.

4. Escalá de forma imperativa:

   ```bash
   docker service scale web=5
   ```

   ```
   web scaled to 5
   overall progress: 5 out of 5 tasks
   verify: Service converged
   ```

5. Configurá una política de rolling update adecuada y aplicá una nueva imagen. `--update-parallelism 1` y `--update-delay 5s` significan una tarea a la vez; `start-first` mantiene la capacidad:

   ```bash
   docker service update \
     --update-parallelism 1 \
     --update-delay 5s \
     --update-order start-first \
     --update-failure-action rollback \
     --image nginx:1.27 web
   ```

   ```
   image nginx:1.27 pinned to ... 
   overall progress: 5 out of 5 tasks
   1/5: running
   2/5: running
   ...
   verify: Service converged
   ```

6. Forzá un rollback a la especificación de imagen anterior:

   ```bash
   docker service rollback web
   docker service ps web --format '{{.Name}} {{.Image}} {{.CurrentState}}' | sort -u
   ```

7. Fijá una tarea a un nodo etiquetado usando una restricción de ubicación (recordá la etiqueta `tier=edge` del Ejercicio 3):

   ```bash
   docker service update --constraint-add 'node.labels.tier == edge' web
   docker service ps web
   ```

   Todas las tareas en ejecución ahora quedan solo en nodos que llevan `tier=edge`.

8. Eliminá el servicio:

   ```bash
   docker service rm web
   ```

**Verificación de comprensión — Bloque 4**

1. Publicaste el puerto 8080 y tenés 3 réplicas repartidas en 2 nodos, pero hacés `curl` a node-B en 8080 y obtenés una respuesta incluso cuando *ninguna* tarea `web` corre en node-B. ¿Qué característica de Swarm hace que eso funcione, y qué realiza el reenvío por debajo?
2. En el paso 3 eliminaste un contenedor con un simple `docker rm -f`. Explicá, en términos de *estado deseado* vs *estado observado*, por qué apareció un reemplazo sin que lo pidieras.
3. ¿Cuál es la diferencia práctica entre `--update-order stop-first` (el valor por defecto) y `start-first`, y para qué tipo de carga de trabajo es `start-first` inseguro?
4. `docker service scale web=5` y `docker service update --replicas 5 web` hacen lo mismo. ¿Cuándo recurrirías a `docker service update` en lugar de `scale`?

---

## Ejercicio 5 — Desplegar un stack completo con `docker stack` (archivo Compose sobre Swarm)

**Objetivo:** conectar las dos mitades del objetivo — reutilizar el *mismo* formato de archivo Compose para desplegar en un swarm vía `docker stack`, usando la clave `deploy:` que Compose (un solo host) ignora pero Swarm respeta.

### Pasos

1. En un directorio nuevo, escribí un archivo Compose consciente de Swarm. El bloque `deploy:` es la parte exclusiva de Swarm — réplicas, política de rolling-update, política de reinicio y ubicación:

   ```yaml
   # stack.yml
   services:
     web:
       image: nginx:1.27-alpine
       ports:
         - "8080:80"
       deploy:
         replicas: 4
         update_config:
           parallelism: 2
           delay: 10s
           order: start-first
           failure_action: rollback
         restart_policy:
           condition: on-failure
           max_attempts: 3
         placement:
           constraints:
             - node.role == worker
       networks:
         - appnet

     redis:
       image: redis:7-alpine
       deploy:
         replicas: 1
         placement:
           constraints:
             - node.role == manager
       networks:
         - appnet

   networks:
     appnet:
       driver: overlay
   ```

2. Desplegá el stack. En un laboratorio de un solo nodo, relajá primero la restricción de `web` (un único nodo es un manager, así que `node.role == worker` dejaría a `web` sin planificar) — quitá esa restricción; agregar `--with-registry-auth` no hace falta acá:

   ```bash
   docker stack deploy -c stack.yml myapp
   ```

   ```
   Creating network myapp_appnet
   Creating service myapp_redis
   Creating service myapp_web
   ```

3. Listá el stack, sus servicios y sus tareas:

   ```bash
   docker stack ls
   docker stack services myapp
   docker stack ps myapp
   ```

   ```
   NAME    SERVICES
   myapp   2

   ID       NAME          MODE         REPLICAS   IMAGE
   x9…      myapp_web     replicated   4/4        nginx:1.27-alpine
   y8…      myapp_redis   replicated   1/1        redis:7-alpine
   ```

4. Confirmá que la red `driver: overlay` abarca todo el swarm (L2 multi-host sobre VXLAN) en lugar de ser un bridge local:

   ```bash
   docker network ls --filter name=myapp_appnet
   ```

   ```
   NETWORK ID     NAME            DRIVER    SCOPE
   a1b2c3d4e5f6   myapp_appnet    overlay   swarm
   ```

5. Actualizá todo el stack editando la imagen (`nginx:1.27` → `nginx:1.27.1`) en `stack.yml` y volviendo a desplegar — `docker stack deploy` es declarativo e idempotente, aplicando el diff:

   ```bash
   sed -i 's#nginx:1.27-alpine#nginx:1.27.1-alpine#' stack.yml
   docker stack deploy -c stack.yml myapp
   docker stack ps myapp --filter desired-state=running
   ```

6. Eliminá todo el stack con un solo comando:

   ```bash
   docker stack rm myapp
   ```

   ```
   Removing service myapp_web
   Removing service myapp_redis
   Removing network myapp_appnet
   ```

7. Salí del swarm (limpieza de un solo nodo):

   ```bash
   docker swarm leave --force
   ```

**Verificación de comprensión — Bloque 5**

1. La clave `deploy:` fue *ignorada silenciosamente* cuando usaste `docker compose up` en el Ejercicio 1, pero respetada por `docker stack deploy`. ¿Qué te dice eso sobre la división de responsabilidades entre el *formato* del archivo Compose y el *motor* que lo consume?
2. ¿Por qué `myapp_appnet` se creó con el driver `overlay` y alcance `swarm`, y por qué eso es obligatorio para que un servicio multi-nodo se comunique — a diferencia del `bridge` por defecto?
3. `docker stack deploy` se describe como idempotente. Si ejecutás exactamente el mismo comando dos veces con un `stack.yml` sin cambios, ¿qué pasa en la segunda ejecución?
4. Tu servicio `web` declara `restart_policy: condition: on-failure, max_attempts: 3`. Una tarea se cae 4 veces seguidas. ¿En qué estado termina, y en qué se diferencia esto de la reconciliación que viste en el paso 3 del Ejercicio 4?

---

## Ejercicio 6 — Conocimiento de Kubernetes y Helm

**Objetivo:** el objetivo solo requiere *conocimiento*. Deberías poder mapear los conceptos de Swarm sobre Kubernetes y decir para qué sirve Helm — sin necesidad de un clúster.

### Pasos

1. Estudiá este mapa de conceptos y sé capaz de reproducirlo. Es la tabla más relevante para el examen en este subtema:

   | Docker Swarm | Kubernetes | Propósito |
   |---|---|---|
   | Nodo manager | Nodo del plano de control (`kube-apiserver`, `etcd`, `scheduler`, `controller-manager`) | Cerebro del clúster / almacén del estado deseado |
   | Nodo worker | Nodo worker (`kubelet`, `kube-proxy`, container runtime) | Ejecuta las cargas de trabajo |
   | Almacén Raft (en los managers) | `etcd` | Estado del clúster consistente y replicado |
   | Tarea (un contenedor en ejecución) | **Pod** (uno o más contenedores) | Unidad planificable más pequeña |
   | Service (`replicated`) | **ReplicaSet** (normalmente vía un **Deployment**) | Mantiene N réplicas |
   | `docker service update --image` | Rolling update de **Deployment** | Cambio de versión con cero/bajo downtime |
   | Service + routing mesh / VIP | **Service** (ClusterIP / NodePort / LoadBalancer) | Endpoint virtual estable + balanceo de carga |
   | Red overlay | Plugin CNI (Calico, Cilium, Flannel …) | Red pod-a-pod |
   | `docker stack deploy -c file` | `kubectl apply -f file` / un release de **Helm** | Despliegue declarativo de múltiples objetos |

2. Leé (no ejecutes — solo conocimiento) un Deployment + Service mínimo de Kubernetes equivalente al servicio `web` que construiste en el Ejercicio 4:

   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web
   spec:
     replicas: 3
     selector:
       matchLabels: { app: web }
     template:
       metadata:
         labels: { app: web }
       spec:
         containers:
           - name: web
             image: nginx:1.27-alpine
             ports:
               - containerPort: 80
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: web
   spec:
     selector: { app: web }
     ports:
       - port: 8080
         targetPort: 80
     type: ClusterIP
   ```

   Notá la correspondencia: `replicas: 3` ≈ `--replicas 3`; el `Deployment` te da el rolling update que configuraste con `--update-parallelism`; el `Service` cumple el rol del VIP/routing mesh de Swarm.

3. Entendé qué agrega **Helm**. Helm es el *gestor de paquetes* de Kubernetes: un **chart** es un paquete de manifiestos parametrizado y versionado; `values.yaml` provee los parámetros; instalar un chart crea un **release** rastreado que podés actualizar o revertir. El modelo mental:

   ```
   apt package  : Debian system   ::  Helm chart : Kubernetes cluster
   ```

   Comandos a nivel de conocimiento que deberías reconocer (no ejecutar):

   ```bash
   helm repo add bitnami https://charts.bitnami.com/bitnami
   helm install my-nginx bitnami/nginx        # create a release from a chart
   helm upgrade my-nginx bitnami/nginx --set replicaCount=3
   helm rollback my-nginx 1                    # revert to revision 1
   helm list                                   # show releases
   ```

**Verificación de comprensión — Bloque 6**

1. En Kubernetes, ¿cuál es la unidad más pequeña que ubica el scheduler, y en qué se diferencia de una *tarea* de Swarm?
2. ¿Qué objeto de Kubernetes creás normalmente para obtener *N* réplicas más rolling updates y rollback — el ReplicaSet o el Deployment? ¿Por qué la diferencia?
3. En una oración: ¿qué problema resuelve Helm que `kubectl apply -f` puro no resuelve?
4. Un colega dice "la routing mesh de Docker Swarm es básicamente un Service de Kubernetes". ¿Es una analogía justa de una línea? Nombrá una cosa que la analogía pasa por alto.

---

## Referencia de comandos (imprescindible para 352.4)

| Utilidad | Comandos representativos |
|---|---|
| `docker-compose.yml` | el archivo declarativo: `services:`, `volumes:`, `networks:`, `deploy:`, `healthcheck:`, `depends_on:` |
| `docker compose` | `up -d`, `down [-v]`, `ps`, `logs -f`, `config`, `up -d --scale svc=N`, `exec` |
| `docker swarm` | `init --advertise-addr <ip>`, `join --token <t> <mgr>:2377`, `join-token worker\|manager`, `leave --force` |
| `docker node` | `ls`, `inspect self`, `update --label-add k=v`, `update --availability drain`, `promote`, `demote`, `rm` |
| `docker service` | `create`, `ls`, `ps <svc>`, `scale svc=N`, `update --image ...`, `rollback`, `logs`, `rm` |
| `docker stack` | `deploy -c file <name>`, `ls`, `services <name>`, `ps <name>`, `rm <name>` |

---

<details>
<summary><strong>Respuestas — clic para expandir</strong></summary>

### Bloque 1 — Fundamentos de Compose
1. **El prefijo `compose_` es el *nombre del proyecto*.** Por defecto Compose lo deriva del directorio donde vive el archivo (acá `compose`). Todo lo que Compose crea — redes, volúmenes, nombres de contenedor por defecto — queda espaciado por nombre con él, para que múltiples copias del mismo stack no colisionen. Sobrescribilo con `docker compose -p <name> ...`, la variable de entorno `COMPOSE_PROJECT_NAME`, o la clave `name:` de nivel superior en el archivo.
2. `condition: service_healthy` espera hasta que el **healthcheck** del contenedor `api` reporte `healthy` (la sonda `wget` tiene éxito), no meramente hasta que el proceso del contenedor haya arrancado. La forma de lista `depends_on: [api]` solo ordena el *arranque* — espera a que el contenedor sea *creado/iniciado*, lo que puede ocurrir segundos antes de que la app de adentro esté aceptando conexiones de verdad. Para un proxy que no debe reenviar a un upstream muerto, necesitás la condición de salud.
3. Porque `proxy` y `db` **no comparten ninguna red definida por el usuario en común**. El DNS embebido de Docker solo resuelve un nombre de servicio para contenedores conectados a la misma red. `proxy` está en `frontend`, `db` está en `backend`, y solo `api` conecta ambas — así que `api` puede alcanzar a `db`, `proxy` puede alcanzar a `api`, pero `proxy` ni siquiera puede resolver `db`. Así es como se impone la segmentación de red por capas de forma declarativa.
4. `docker compose down` elimina los contenedores y las redes por defecto pero **conserva los volúmenes con nombre** — los datos de Postgres en `pgdata` sobreviven. `docker compose down -v` *también* elimina los volúmenes con nombre declarados en el archivo, destruyendo la base de datos. (Los datos anónimos/bind se comportan distinto; acá el único objetivo de `-v` es el volumen con nombre de nivel superior.)

### Bloque 2 — Escalado y límites de Compose
1. No podés escalar `proxy` a 2 mientras publica estáticamente el puerto de host `8080:80`, porque dos contenedores no pueden enlazar el *mismo puerto de host* en un mismo host — la segunda réplica no tiene dónde mapear 8080. Los servicios sin estado que escalás deben, o bien no publicar un puerto de host fijo, o bien necesitás un orquestador con una routing mesh/balanceador de carga (Swarm, Kubernetes) que desacople el puerto publicado de las réplicas individuales.
2. Dos cualesquiera de: **planificación multi-host** (ubicar contenedores a lo largo de un clúster), **rolling updates incorporados con rollback**, **auto-recuperación/reconciliación** (reiniciar en un host *distinto* tras la caída de un nodo), **descubrimiento de servicios + balanceo de carga entre hosts (VIP/routing mesh)**, **mantenimiento declarativo del estado deseado**, **secrets/configs distribuidos a todo el clúster**. Compose es de un solo host y no hace nada de esto por sí solo.
3. Sí — `--force-recreate` realiza detener-y-luego-iniciar, así que hay una ventana con capacidad reducida (o, para una única réplica, cero). En Swarm evitás esto con `update_config: order: start-first` (levantar la nueva tarea y que esté saludable *antes* de detener la vieja) combinado con `parallelism` para limitar cuántas cambian a la vez.

### Bloque 3 — Arquitectura de Swarm
1. **Raft** provee el consenso para el almacén de estado replicado de Swarm — el "estado deseado" de cada service, secret y config. Solo los nodos **manager** participan en Raft; los workers no guardan ni votan el estado del clúster, solo ejecutan las tareas que se les asignan. Un manager es elegido **Leader**; el resto son followers que pueden tomar el control si este falla.
2. La tolerancia a fallos sigue la regla de quórum: un clúster de *N* managers tolera la pérdida de `floor((N-1)/2)` y necesita `floor(N/2)+1` vivos para el quórum. 3 managers toleran 1 fallo; **4 managers también toleran solo 1** (el quórum es 3) pero suman costo y un grupo Raft más grande — así que 4 no aporta nada sobre 3 mientras aumenta las probabilidades de perder el quórum. Usá un número **impar** (3 o 5). Más de 7 managers se desaconseja por rendimiento.
3. El token de manager otorga **membresía del plano de control**: cualquiera que lo tenga puede unirse como manager, leer todo el almacén Raft (incluidos los secrets), planificar/matar cualquier carga de trabajo, y efectivamente adueñarse del clúster. Filtrar el token de *worker* es malo (un atacante puede ejecutar tareas y leer el tráfico overlay que tocan) pero filtrar el token de *manager* es un compromiso total. Rotalo con `docker swarm join-token --rotate`.
4. `Active` — el scheduler puede ubicar nuevas tareas en el nodo. `Pause` — las tareas existentes siguen corriendo pero **no se planifican** tareas nuevas ahí. `Drain` — las tareas existentes se **replanifican fuera** del nodo y no se ubican nuevas; se usa para mantenimiento o para mantener a los managers libres de tareas.

### Bloque 4 — docker service
1. La **routing mesh**. Cada nodo del swarm escucha en el puerto publicado del servicio y, vía la red overlay de ingress y el balanceo de carga **IPVS** en el kernel, reenvía la conexión a una tarea saludable *donde sea que corra* — incluso si ese nodo no hospeda ninguna de las tareas del servicio. Así que `curl node-B:8080` funciona porque node-B te reenvía dentro de la mesh.
2. Swarm compara continuamente el **estado deseado** (`replicas: 3`, almacenado en Raft) contra el **estado observado** (tareas realmente en ejecución). Eliminar un contenedor hace que el observado = 2, que ya no coincide con el deseado = 3, así que el bucle de reconciliación del orquestador planifica una tarea de reemplazo para cerrar la brecha. Vos nunca lo pediste; lo hizo el controlador, porque su trabajo es converger el observado hacia el deseado.
3. `stop-first` (por defecto) detiene la tarea vieja, luego inicia la nueva — una breve caída de capacidad por réplica, pero solo el data-path de una versión está activo a la vez. `start-first` inicia la nueva tarea y espera a que esté saludable *antes* de detener la vieja — sin caída de capacidad, pero **la vieja y la nueva corren simultáneamente**. Eso es inseguro para cargas de trabajo que no pueden tolerar dos versiones a la vez (p. ej. un cambio incompatible de esquema, o un singleton que no debe correr dos veces).
4. Usá `docker service update` cuando estás cambiando las réplicas **junto con** otras propiedades en una sola operación convergida (imagen, restricciones, env, política de actualización), o cuando scripteás un cambio declarativo. `docker service scale` es el atajo cuando el número de réplicas es lo *único* que cambia (y puede escalar varios servicios en una línea: `docker service scale a=3 b=5`).

### Bloque 5 — docker stack
1. El **formato de archivo** de Compose es un esquema de datos; la clave `deploy:` es parte de él, pero *actuar* sobre `deploy:` es responsabilidad del **motor** que consume el archivo. `docker compose` (un solo host) parsea el archivo y simplemente ignora `deploy:` (no hay scheduler que respete réplicas/ubicación); `docker stack deploy` entrega el mismo archivo al **orquestador de Swarm**, que sí lo respeta. Mismo formato, distinto motor de ejecución.
2. Los servicios multi-host necesitan una red **overlay**: construye un segmento L2 sobre la red física usando encapsulación **VXLAN**, de modo que contenedores en distintos hosts comparten una subred y pueden alcanzarse por nombre de servicio. Una red `bridge` por defecto es **local al host** — no puede abarcar nodos, así que tareas en distintos hosts no podrían comunicarse. La overlay con alcance de swarm se crea automáticamente para los stacks; el alcance se muestra como `swarm`.
3. En la segunda ejecución idéntica, `docker stack deploy` computa un diff entre el deseado (el archivo) y el actual (estado de Raft), no encuentra diferencias, y **no hace cambios** — los servicios quedan como están (`Updating`/no-op). Eso es lo que significa "declarativo e idempotente": el comando expresa un estado objetivo, no un paso a realizar, así que re-ejecutarlo es seguro.
4. `restart_policy` gobierna el reinicio de una tarea **en el lugar** ante un fallo; tras `max_attempts: 3` reinicios fallidos la tarea queda en un estado terminal **`Failed`/`Rejected`** y *no* se reintenta en el lugar. Esto es distinto de la reconciliación del Ejercicio 4: aquella era el orquestador creando una **tarea completamente nueva** para restaurar el número de réplicas tras eliminar una tarea. Política de reinicio = recuperación local por tarea; reconciliación/mantenimiento de réplicas = convergencia a nivel de servicio que puede generar una tarea nueva (a menudo en otro nodo).

### Bloque 6 — Conocimiento de Kubernetes y Helm
1. La unidad planificable más pequeña en Kubernetes es el **Pod** — un grupo de uno o más contenedores que comparten un namespace de red (una IP) y opcionalmente almacenamiento. Una **tarea** de Swarm es un único contenedor. Así que un Pod es un envoltorio de nivel ligeramente superior: los contenedores co-planificados ("sidecars") viven en un mismo Pod, lo que no tiene equivalente directo en Swarm.
2. El **Deployment**. Gestiona los ReplicaSets por vos y agrega la maquinaria de rollout — rolling updates versionados, pausa/reanudación, y rollback a una revisión previa. Un ReplicaSet pelado solo garantiza *N* réplicas; no tiene controlador de rollout/rollback. Casi nunca creás un ReplicaSet directamente.
3. Helm convierte una pila de manifiestos estáticos en un **paquete parametrizado, versionado e instalable (chart)** con un **release** rastreado, de modo que podés templatizar valores, compartir/reutilizar el paquete, y hacer `upgrade`/`rollback` de forma atómica — nada de lo cual te da `kubectl apply -f` puro.
4. Es una frase *razonable* de una línea (ambos proveen un endpoint virtual estable y balancean carga entre backends), pero pasa por alto que un **Service** de Kubernetes tiene múltiples tipos (ClusterIP, NodePort, LoadBalancer, más Ingress por encima) y usa selectores de etiquetas para encontrar sus Pods, mientras que la routing mesh de Swarm es un único mecanismo (overlay de ingress + VIP IPVS) atado a un puerto publicado. Distinta flexibilidad y distinta plomería.

</details>

---

**Fuentes**
- LPI Exam 305 Objectives (352.4) — <https://www.lpi.org/our-certifications/exam-305-objectives/>
- Docker Compose file reference — <https://docs.docker.com/reference/compose-file/>
- `docker compose` CLI — <https://docs.docker.com/reference/cli/docker/compose/>
- Swarm mode overview & key concepts — <https://docs.docker.com/engine/swarm/key-concepts/>
- Raft consensus in Swarm — <https://docs.docker.com/engine/swarm/raft/>
- Routing mesh — <https://docs.docker.com/engine/swarm/ingress/>
- `docker service` / rolling updates — <https://docs.docker.com/engine/swarm/swarm-tutorial/rolling-update/>
- `docker stack deploy` — <https://docs.docker.com/reference/cli/docker/stack/deploy/>
- Kubernetes components — <https://kubernetes.io/docs/concepts/overview/components/>
- Kubernetes Deployments — <https://kubernetes.io/docs/concepts/workloads/controllers/deployment/>
- Helm documentation — <https://helm.sh/docs/>