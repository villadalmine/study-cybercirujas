# LPI DevOps Tools Engineer (Exam 701-100) — Material de Estudio Avanzado
## Tema 2.3: Infraestructura de Contenedores (Ponderación: 6.67 / Ponderación 5)

**Público Objetivo:** Senior Platform Engineers, Site Reliability Engineers (SRE), Systems Architects  
**Referencia Oficial:** [LPI DevOps Tools Engineer Objectives](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/) | [Docker Architecture Documentation](https://docs.docker.com/engine/architecture/) | [Linux Kernel Namespaces & Cgroups v2](https://man7.org/linux/man-pages/man7/namespaces.7.html)

---

## Visión General Técnica y Fundamentos Arquitectónicos

La contenerización se basa en primitivas de bajo nivel del kernel de Linux en lugar de la virtualización de hardware mediante hipervisor. Comprender cómo el runtime de contenedores (por ejemplo, `containerd`, `runc`) orquesta estas primitivas es necesario para operar infraestructura de contenedores a escala en entornos de producción.

### Primitivas Arquitectónicas Principales

1. **Linux Namespaces (Aislamiento):**
   * `pid`: Aislamiento del árbol de procesos (el PID 1 del contenedor se mapea a un PID estándar en el host).
   * `net`: Aislamiento de dispositivos de red, tablas de enrutamiento IP, reglas de firewall y binding de puertos.
   * `mnt`: Aislamiento de puntos de montaje del sistema de archivos.
   * `ipc`: Aislamiento de Comunicación Inter-Proceso (System V IPC, colas de mensajes POSIX).
   * `uts`: Aislamiento del Hostname y nombre de dominio NIS.
   * `user`: Mapeo de ID de usuario y grupo (permite que el UID 0 root no privilegiado del contenedor se mapee a un UID del host no privilegiado).
   * `cgroup`: Aislamiento del directorio raíz para las rutas de Control Groups.

2. **Control Groups v2 (Gestión de Recursos y Contabilidad):**
   * Aplica límites estrictos (hard) y flexibles (soft) de memoria (`memory.max`, `memory.high`), asignaciones de ancho de banda de CPU (`cpu.max`) y rendimiento de E/S de bloques (`io.weight`).
   * Desencadena el Out-Of-Memory (OOM) Killer cuando se sobrepasan los límites de `memory.max` más `memory.swap.max` sin causar kernel panics en el host.

3. **OverlayFS (Arquitectura del Storage Driver):**
   * Utiliza un sistema de archivos de montaje union que combina cuatro directorios:
     * `lowerdir`: Capas base de solo lectura (construidas a partir de los pasos del Dockerfile).
     * `upperdir`: Capa del contenedor de lectura-escritura (mutaciones transitorias en runtime).
     * `workdir`: Espacio de trabajo interno del kernel para mutaciones atómicas.
     * `merged`: Punto de montaje consolidado visible dentro del contenedor en ejecución.
   * **Copy-on-Write (CoW):** Cuando un proceso dentro del contenedor modifica un archivo existente de solo lectura de `lowerdir`, OverlayFS copia el archivo en `upperdir` antes de ejecutar operaciones de escritura.

4. **Interfaz de Red de Contenedores y Enrutamiento de Tráfico:**
   * **Modo Bridge (`bridge`):** Red predeterminada local del host. Docker crea una interfaz bridge virtual (por ejemplo, `docker0` o personalizada `br-xxxxxxxxxxxx`). Cada contenedor recibe un par Virtual Ethernet (`veth`); un extremo reside dentro del namespace de red del contenedor (`eth0`), mientras que el otro se adjunta al bridge del host.
   * **Arquitectura de Port Forwarding:** El tráfico dirigido a los puertos del host es interceptado por reglas NAT de `iptables` del host dentro de la cadena `DOCKER` y enrutado a la IP interna del contenedor mediante `DNAT` (Destination Network Address Translation).

---

## Ejercicio 1: Primitivas del Kernel de Linux y Mecánica del Runtime de Contenedores

**Objetivo:** Inspeccionar y depurar el aislamiento de procesos (Namespaces), contabilidad de recursos de Cgroups v2 y montajes de capas OverlayFS directamente en el sistema host.

### Ejecución Paso a Paso

1. Iniciar un contenedor Nginx aislado y con recursos limitados ejecutándose en segundo plano:
   ```bash
   docker run -d \
     --name prod-nginx-edge \
     --memory="256m" \
     --cpus="0.5" \
     --publish 8080:80 \
     nginx:1.25-alpine
   ```
   *Salida Esperada:*
   ```text
   a1b2c3d4e5f67890abcdef1234567890abcdef1234567890abcdef1234567890
   ```

2. Obtener el Process ID (PID) del host del proceso principal de Nginx dentro del namespace del contenedor utilizando `docker inspect`:
   ```bash
   CONTAINER_PID=$(docker inspect --format '{{ .State.Pid }}' prod-nginx-edge)
   echo "Host PID of Container PID 1: ${CONTAINER_PID}"
   ```
   *Salida Esperada:*
   ```text
   Host PID of Container PID 1: 42189
   ```

3. Inspeccionar los Linux Namespaces activos asignados a este PID del host utilizando `lsns`:
   ```bash
   lsns -p ${CONTAINER_PID}
   ```
   *Salida Esperada:*
   ```text
   NS TIME NSECT        TYPE   NPROCS   PID USER    COMMAND
   4026531835 net      1        1 42189 root    nginx: master process nginx -g daemon off;
   4026531836 mnt      1        1 42189 root    nginx: master process nginx -g daemon off;
   4026531837 uts      1        1 42189 root    nginx: master process nginx -g daemon off;
   4026531838 pid      1        1 42189 root    nginx: master process nginx -g daemon off;
   4026531839 ipc      1        1 42189 root    nginx: master process nginx -g daemon off;
   4026531840 cgroup   1        1 42189 root    nginx: master process nginx -g daemon off;
   ```

4. Ejecutar comandos dentro de los namespaces Network y Mount del contenedor objetivo directamente desde el host usando `nsenter` sin utilizar `docker exec`:
   ```bash
   sudo nsenter --target ${CONTAINER_PID} --net --mnt ip addr show eth0
   ```
   *Salida Esperada:*
   ```text
   7: eth0@if8: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default 
       link/ether 02:42:ac:11:00:02 brd ff:ff:ff:ff:ff:ff link-netnsid 0
       inet 172.17.0.2/16 brd 172.17.255.255 scope global eth0
          valid_lft forever preferred_lft forever
   ```

5. Verificar la aplicación de límites de los controladores de memoria y CPU de Cgroups v2 en `/sys/fs/cgroup`:
   ```bash
   CGROUP_PATH=$(docker inspect --format '{{ .Id }}' prod-nginx-edge)
   cat /sys/fs/cgroup/docker/${CGROUP_PATH}/memory.max
   cat /sys/fs/cgroup/docker/${CGROUP_PATH}/cpu.max
   ```
   *Salida Esperada:*
   ```text
   268435456
   50000 100000
   ```
   *(Nota: `268435456` bytes = 256MB. `50000 100000` indica una cuota de 50,000µs por período de 100,000µs = 0.5 CPUs).*

6. Inspeccionar los directorios lower, upper, work y merged de OverlayFS mediante `docker inspect`:
   ```bash
   docker inspect --format '{{ json .GraphDriver.Data }}' prod-nginx-edge | jq .
   ```
   *Salida Esperada:*
   ```json
   {
     "LowerDir": "/var/lib/docker/overlay2/a89f.../diff:/var/lib/docker/overlay2/b12c.../diff",
     "MergedDir": "/var/lib/docker/overlay2/c34d.../merged",
     "UpperDir": "/var/lib/docker/overlay2/c34d.../diff",
     "WorkDir": "/var/lib/docker/overlay2/c34d.../work"
   }
   ```

---

### Preguntas (Bloque 1)

1. ¿Qué sucede con el rendimiento de escritura cuando un contenedor escribe intensivamente en un archivo preexistente de 10GB ubicado dentro de `lowerdir` bajo el storage driver OverlayFS?
2. Si un contenedor supera su límite configurado `--memory="256m"` sin swap habilitado, ¿qué subsistema del kernel actúa y cómo puede un operador distinguir una terminación por OOM de un código de salida por fallo a nivel de aplicación?

---

## Ejercicio 2: Arquitectura Avanzada de Redes de Contenedores y Enrutamiento de Tráfico

**Objetivo:** Construir redes bridge aisladas, rastrear emparejamientos de interfaces `veth` entre namespaces del host y del contenedor, y depurar cadenas NAT de `iptables`.

### Ejecución Paso a Paso

1. Crear una red bridge aislada personalizada con una subred CIDR explícita, gateway y MTU fijo:
   ```bash
   docker network create \
     --driver bridge \
     --subnet 10.240.50.0/24 \
     --gateway 10.240.50.1 \
     --opt "com.docker.network.driver.mtu"="1450" \
     prod-vpc-net
   ```
   *Salida Esperada:*
   ```text
   e7c10b9f3a4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f
   ```

2. Ejecutar dos contenedores de microservicios conectados a `prod-vpc-net`:
   ```bash
   docker run -d --name app-backend --network prod-vpc-net alpine sleep 3600
   docker run -d --name app-frontend --network prod-vpc-net -p 9000:80 nginx:alpine
   ```
   *Salida Esperada:*
   ```text
   11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff
   223344556677889900aabbccddeeff11223344556677889900aabbccddeeff11
   ```

3. Identificar la interfaz del host que coincide con el endpoint virtual ethernet (`veth`) del contenedor para `app-frontend`:
   ```bash
   # Retrieve container side veth index
   IFINDEX=$(docker exec app-frontend cat /sys/class/net/eth0/iflink)
   # Map to host interface name
   ip link | grep "^${IFINDEX}:"
   ```
   *Salida Esperada:*
   ```text
   14: vethb4a1c2d@if13: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450 qdisc noqueue master br-e7c10b9f3a4d state UP mode DEFAULT group default
   ```

4. Auditar la tabla NAT de `iptables` del kernel de Linux para rastrear el port forwarding de destino (`DNAT`) para el puerto `9000`:
   ```bash
   sudo iptables -t nat -L DOCKER -n -v --line-numbers
   ```
   *Salida Esperada:*
   ```text
   Chain DOCKER (2 references)
   num   pkts bytes target     prot opt in     out     source               destination         
   1        0     0 DNAT       tcp  --  !br-e7c10b9f3a4d * 0.0.0.0/0 0.0.0.0/0 tcp dpt:9000 to:10.240.50.3:80
   ```

5. Verificar la resolución DNS embebida (`127.0.0.11`) entre contenedores en redes personalizadas definidas por el usuario:
   ```bash
   docker exec app-backend ping -c 2 app-frontend
   ```
   *Salida Esperada:*
   ```text
   PING app-frontend (10.240.50.3): 56 data bytes
   64 bytes from 10.240.50.3: seq=0 ttl=64 time=0.082 ms
   64 bytes from 10.240.50.3: seq=1 ttl=64 time=0.065 ms

   --- app-frontend ping statistics ---
   2 packets transmitted, 2 packets received, 0% packet loss
   ```

---

### Preguntas (Bloque 2)

1. ¿Por qué la resolución automática de nombres DNS de contenedores funciona en redes bridge definidas por el usuario (por ejemplo, `prod-vpc-net`), pero falla en la red `bridge` heredada predeterminada (`docker0`)?
2. Cuando el tráfico fluye desde `10.240.50.2` (dentro del contenedor) hacia un endpoint externo de internet (por ejemplo, `8.8.8.8`), ¿qué tabla y cadena de `iptables` convierte la IP privada del contenedor en la dirección IP de la interfaz pública del nodo host?

---

## Ejercicio 3: Hardening del Docker Daemon en Producción y Ajuste del Storage Engine

**Objetivo:** Configurar propiedades del daemon de nivel empresarial a través de `/etc/docker/daemon.json`, implementar rotación de logs, aplicar Live Restore y optimizar los tipos de montaje de volúmenes de almacenamiento.

### Ejecución Paso a Paso

1. Crear un archivo de configuración `/etc/docker/daemon.json` listo para producción con rotación de logs, daemon live-restore, endpoints de métricas y storage drivers predeterminados:
   ```bash
   sudo mkdir -p /etc/docker
   sudo tee /etc/docker/daemon.json > /dev/null <<'EOF'
   {
     "storage-driver": "overlay2",
     "live-restore": true,
     "log-driver": "json-file",
     "log-opts": {
       "max-size": "50m",
       "max-file": "5"
     },
     "metrics-addr": "127.0.0.1:9323",
     "userland-proxy": false,
     "no-new-privileges": true
   }
   EOF
   ```

2. Recargar la configuración del daemon sin interrumpir los contenedores en ejecución (posible al configurar `"live-restore": true`):
   ```bash
   sudo systemctl reload docker
   sudo docker info | grep -E "Logging Driver|Storage Driver|Live Restore"
   ```
   *Salida Esperada:*
   ```text
    Storage Driver: overlay2
    Logging Driver: json-file
    Live Restore Enabled: true
   ```

3. Probar los límites de persistencia y las diferencias de rendimiento entre configuraciones de almacenamiento de contenedores:
   ```bash
   # Create a managed named volume
   docker volume create prod-db-data

   # Run container with named volume and tmpfs mount
   docker run -d \
     --name storage-bench \
     --mount type=volume,source=prod-db-data,target=/var/lib/postgresql/data \
     --mount type=tmpfs,target=/tmp/cache,tmpfs-size=67108864 \
     postgres:15-alpine
   ```
   *Salida Esperada:*
   ```text
   99887766554433221100aabbccddeeff99887766554433221100aabbccddeeff
   ```

4. Verificar las propiedades del montaje de almacenamiento a través de `docker inspect`:
   ```bash
   docker inspect --format '{{ json .Mounts }}' storage-bench | jq .
   ```
   *Salida Esperada:*
   ```json
   [
     {
       "Type": "volume",
       "Name": "prod-db-data",
       "Source": "/var/lib/docker/volumes/prod-db-data/_data",
       "Destination": "/var/lib/postgresql/data",
       "Driver": "local",
       "Mode": "z",
       "RW": true,
       "Propagation": ""
     },
     {
       "Type": "tmpfs",
       "Destination": "/tmp/cache",
       "Mode": ""
     }
   ]
   ```

---

### Preguntas (Bloque 3)

1. ¿Qué beneficio operativo proporciona configurar `"userland-proxy": false` en despliegues de edge routers contenerizados de alto rendimiento?
2. ¿Cuál es la diferencia funcional clave entre un `bind mount` y un `named volume` con respecto a la inicialización de archivos al montar sobre un directorio no vacío en la imagen del contenedor?

---

## Ejercicio 4: Orquestación Multicontenedor y Resiliencia con Docker Compose v2

**Objetivo:** Escribir un manifiesto `docker-compose.yml` de producción sintácticamente válido utilizando los estándares de Compose Specification, aplicar healthchecks de dependencia, límites de recursos y depurar transiciones de estado de servicios.

### Ejecución Paso a Paso

1. Crear un directorio y definir un manifiesto de plataforma multicontenedor (`docker-compose.yml`) que contenga PostgreSQL, Redis y una aplicación Web:
   ```bash
   mkdir -p ~/compose-lab && cd ~/compose-lab
   cat <<'EOF' > docker-compose.yml
   name: enterprise-stack

   services:
     postgres-db:
       image: postgres:15-alpine
       environment:
         POSTGRES_DB: app_db
         POSTGRES_USER: db_user
         POSTGRES_PASSWORD: SecretPassword123!
       volumes:
         - pgdata:/var/lib/postgresql/data
       networks:
         - backplane
       healthcheck:
         test: ["CMD-SHELL", "pg_isready -U db_user -d app_db"]
         interval: 5s
         timeout: 3s
         retries: 5
         start_period: 10s
       deploy:
         resources:
           limits:
             cpus: '1.0'
             memory: 512M
           reservations:
             cpus: '0.25'
             memory: 128M
       restart: unless-stopped

     redis-cache:
       image: redis:7-alpine
       command: redis-server --save 60 1 --loglevel notice
       networks:
         - backplane
       healthcheck:
         test: ["CMD", "redis-cli", "ping"]
         interval: 5s
         timeout: 2s
         retries: 3
       deploy:
         resources:
           limits:
             memory: 256M
       restart: always

     api-gateway:
       image: nginx:1.25-alpine
       ports:
         - "80:80"
       networks:
         - backplane
       depends_on:
         postgres-db:
           condition: service_healthy
         redis-cache:
           condition: service_healthy
       deploy:
         resources:
           limits:
             memory: 128M
       restart: always

   volumes:
     pgdata:
       driver: local

   networks:
     backplane:
       driver: bridge
       ipam:
         config:
           - subnet: 172.28.0.0/16
   EOF
   ```

2. Validar la sintaxis del archivo compose y compilar la especificación normalizada usando `docker compose config`:
   ```bash
   docker compose config
   ```
   *Salida Esperada:*
   ```yaml
   name: enterprise-stack
   services:
     api-gateway:
       depends_on:
         postgres-db:
           condition: service_healthy
           required: true
         redis-cache:
           condition: service_healthy
           required: true
       image: nginx:1.25-alpine
       networks:
         backplane: null
       ports:
         - mode: ingress
           target: 80
           published: "80"
           protocol: tcp
       restart: always
   ...
   ```

3. Iniciar el stack de la aplicación en modo desacoplado (detached) y monitorear el orden de inicialización:
   ```bash
   docker compose up -d
   ```
   *Salida Esperada:*
   ```text
   [+] Running 5/5
    ✔ Network enterprise-stack_backplane      Created                             0.1s
    ✔ Volume "enterprise-stack_pgdata"        Created                             0.0s
    ✔ Container enterprise-stack-redis-cache-1   Healthy                             6.2s
    ✔ Container enterprise-stack-postgres-db-1   Healthy                            11.4s
    ✔ Container enterprise-stack-api-gateway-1   Started                            11.6s
   ```

4. Verificar el estado, estado de salud y mapeos de puertos a través del stack utilizando `docker compose ps`:
   ```bash
   docker compose ps
   ```
   *Salida Esperada:*
   ```text
   NAME                                   IMAGE              COMMAND                  SERVICE       CREATED          STATUS                    PORTS
   enterprise-stack-api-gateway-1   nginx:1.25-alpine   "/docker-entrypoint.…"   api-gateway   15 seconds ago   Up 4 seconds              0.0.0.0:80->80/tcp
   enterprise-stack-postgres-db-1   postgres:15-alpine  "docker-entrypoint.s…"   postgres-db   15 seconds ago   Up 14 seconds (healthy)   5432/tcp
   enterprise-stack-redis-cache-1   redis:7-alpine     "docker-entrypoint.s…"   redis-cache   15 seconds ago   Up 14 seconds (healthy)   6379/tcp
   ```

5. Inspeccionar el consumo de recursos en todos los contenedores del stack en tiempo real:
   ```bash
   docker compose top
   ```
   *Salida Esperada:*
   ```text
   enterprise-stack-api-gateway-1
   UID   PID     PPID    C   STIME   TTY   TIME       CMD
   root  52140   52110   0   04:30   ?     00:00:00   nginx: master process nginx -g daemon off;
   101   52195   52140   0   04:30   ?     00:00:00   nginx: worker process

   enterprise-stack-postgres-db-1
   UID   PID     PPID    C   STIME   TTY   TIME       CMD
   70    51800   51760   0   04:30   ?     00:00:00   postgres
   ...
   ```

6. Limpiar recursos y eliminar los volúmenes asociados:
   ```bash
   docker compose down -v
   ```
   *Salida Esperada:*
   ```text
   [+] Running 4/4
    ✔ Container enterprise-stack-api-gateway-1   Removed                             0.2s
    ✔ Container enterprise-stack-postgres-db-1   Removed                             0.3s
    ✔ Container enterprise-stack-redis-cache-1   Removed                             0.2s
    ✔ Network enterprise-stack_backplane      Removed                             0.1s
    ✔ Volume enterprise-stack_pgdata           Removed                             0.0s
   ```

---

### Preguntas (Bloque 4)

1. ¿En qué se diferencia `condition: service_healthy` del `depends_on` estándar sin condiciones al inicializar contenedores dependientes?
2. Si se especifica `restart: unless-stopped` en un contenedor, ¿qué hará Docker cuando el sistema host se reinicie, asumiendo que el contenedor fue detenido manualmente por un operador antes del reinicio?

---

<details>
<summary>Clave de Respuestas de los Ejercicios y Explicaciones Técnicas</summary>

### Clave de Respuestas del Ejercicio 1

1. **Impacto de Rendimiento de Copy-on-Write en OverlayFS:**
   * OverlayFS opera a nivel de archivo, no a nivel de bloque. Al modificar un archivo de 10GB que reside en `lowerdir`, el kernel debe copiar el **archivo completo de 10GB** en `upperdir` antes de ejecutar el primer byte de escritura. Esto causa una grave latencia de I/O de disco, alto consumo de almacenamiento y posibles timeouts de escritura en la aplicación.
   * *Mitigación en Producción:* Las aplicaciones con alto consumo de I/O (por ejemplo, bases de datos) nunca deben escribir datos pesados en el sistema de archivos raíz del contenedor (`overlay2`). Se deben usar **Named Volumes** o **Bind Mounts**, los cuales omiten OverlayFS por completo y escriben directamente en los bloques de almacenamiento del host a velocidades nativas.

2. **Detección del OOM Killer y Códigos de Salida:**
   * Cuando la memoria del contenedor excede `memory.max`, el OOM Killer de Cgroup del kernel de Linux termina el proceso principal dentro del namespace usando `SIGKILL` (Señal 9).
   * **Comando de Diagnóstico:** `docker inspect <container_id> --format '{{ .State.ExitCode }} {{ .State.OOMKilled }}'`
   * Un contenedor terminado por OOM devuelve `ExitCode: 137` (Convención estándar: `128 + Signal 9 = 137`) y `.State.OOMKilled: true`. Las excepciones a nivel de aplicación devuelven el código de salida `1` o códigos personalizados distintos de cero sin marcar el flag `OOMKilled` del kernel como `true`.

---

### Clave de Respuestas del Ejercicio 2

1. **DNS en Bridge Definida por el Usuario vs Bridge Predeterminada:**
   * **Redes Bridge Definidas por el Usuario:** Cuentan con un servidor DNS embebido escuchando en la IP `127.0.0.11` dentro del namespace de cada contenedor adjunto. Docker resuelve automáticamente los nombres de los contenedores y alias de servicios a las IPs de los contenedores a través de este resolvedor embebido.
   * **Red Bridge Predeterminada (`docker0`):** **No** admite el servidor DNS embebido para la resolución de nombres de contenedores debido a compatibilidad hacia atrás. Los contenedores en `docker0` solo pueden comunicarse a través de direcciones IP o mediante los flags explícitos heredados `--link`.

2. **Enrutamiento SNAT de Paquetes Salientes:**
   * **Tabla:** `nat`
   * **Cadena:** `POSTROUTING`
   * **Mecánica de la Regla:** El daemon de Docker inserta una regla con el objetivo `MASQUERADE` en la cadena `POSTROUTING` para el tráfico saliente originado desde el CIDR de la red bridge (por ejemplo, `10.240.50.0/24`). Esto realiza Source Network Address Translation (SNAT), reemplazando la IP de origen privada del contenedor (`10.240.50.2`) por la dirección IP de la interfaz pública del nodo antes de enviar los paquetes a la red del host.

---

### Clave de Respuestas del Ejercicio 3

1. **Deshabilitar Userland Proxy (`"userland-proxy": false`):**
   * De forma predeterminada, Docker genera un proceso de espacio de usuario `docker-proxy` para cada puerto publicado con el fin de reenviar tráfico entre las interfaces del host y del contenedor. Esto añade sobrecarga de procesos, cambios de contexto y uso de CPU.
   * Deshabilitar `userland-proxy` fuerza a Docker a enrutar todo el tráfico de puertos entrante estrictamente a través de reglas NAT de `iptables` del kernel de alto rendimiento (`DNAT`), reduciendo el consumo de CPU y la latencia de red bajo alta concurrencia de solicitudes.

2. **Inicialización de Directorios (Bind Mounts vs Named Volumes):**
   * **Named Volume:** Si se monta un nuevo volumen con nombre en un directorio no vacío de una imagen de contenedor (por ejemplo, `/var/lib/postgresql/data` que contiene archivos de configuración predeterminados), Docker **copia** los archivos existentes de la imagen al volumen durante la inicialización antes de montar.
   * **Bind Mount:** Montar una carpeta existente del host sobre una ruta no vacía de la imagen del contenedor **oculta** los archivos de la imagen del contenedor. El contenido de la ruta del host sobrescribe el sistema de archivos visible dentro del directorio objetivo del contenedor inmediatamente, sin realizar la copia del contenido de la imagen.

---

### Clave de Respuestas del Ejercicio 4

1. **Control de Dependencias con `service_healthy`:**
   * El `depends_on` estándar solo espera hasta que el contenedor objetivo transicione al estado `Running` (proceso iniciado), independientemente de si la aplicación en su interior está lista para aceptar conexiones de socket.
   * `condition: service_healthy` bloquea la ejecución del servicio dependiente hasta que el contenedor objetivo de aguas arriba cumpla con sus criterios de `healthcheck` definidos (por ejemplo, Postgres pasando `pg_isready` y entrando en estado `healthy`), evitando rechazos en el pool de conexiones durante cascadas de arranque.

2. **Comportamiento de la Política de Reinicio `unless-stopped`:**
   * Si un operador ejecuta explícitamente `docker stop <container>` antes de un reinicio del sistema, Docker registra el estado de detención explícita en su base de datos de estado.
   * Al reiniciar el sistema, el daemon de Docker **no** reiniciará automáticamente el contenedor porque fue detenido manualmente antes del reinicio. Si el sistema se bloqueó o se reinició mientras el contenedor estaba en ejecución, Docker lo reiniciará automáticamente al arrancar.

</details>

---

## Fuentes Oficiales y Documentación Estándar
* **Especificaciones de Certificación LPI:** [LPI DevOps Tools Engineer Exam 701-100 Objectives](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
* **Arquitectura de Docker Engine y Almacenamiento:** [Docker OverlayFS Storage Driver Manual](https://docs.docker.com/engine/storage/drivers/overlayfs-driver/)
* **Primitivas del Kernel de Linux:** [Linux Programmer's Manual: Namespaces (7)](https://man7.org/linux/man-pages/man7/namespaces.7.html)
* **Especificación de Linux Cgroups:** [Linux Kernel Control Groups v2 Documentation](https://docs.kernel.org/admin-guide/cgroup-v2.html)
* **Especificación de Docker Compose:** [Official Compose File Specification](https://docs.docker.com/compose/compose-file/)