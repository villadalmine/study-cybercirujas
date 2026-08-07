# LPI DevOps Tools Engineer (Exam 701-100, Version 1.0)
## Topic 2.1: Container Usage (Weight: 11.67)

---

### Official References
* **LPI DevOps Tools Engineer Overview**: [https://www.lpi.org/our-certifications/devops-tools-engineer-overview/](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
* **Docker CLI Reference**: [https://docs.docker.com/engine/reference/commandline/cli/](https://docs.docker.com/engine/reference/commandline/cli/)
* **Docker Storage Drivers & Overlay2**: [https://docs.docker.com/storage/storagedriver/overlayfs-driver/](https://docs.docker.com/storage/storagedriver/overlayfs-driver/)
* **Docker Container Networking**: [https://docs.docker.com/network/](https://docs.docker.com/network/)
* **Linux Kernel Control Groups (cgroups v2)**: [https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html)
* **Linux Namespaces Overview**: [https://man7.org/linux/man-pages/man7/namespaces.7.html](https://man7.org/linux/man-pages/man7/namespaces.7.html)

---

## Visión General Técnica e Inmersión Arquitectónica Profunda

En los entornos de producción contenedorizados modernos, un contenedor no es una máquina virtual independiente, sino más bien un grupo aislado de procesos del kernel de Linux gobernados por **Namespaces** (para aislamiento) y **Control Groups (cgroups)** (para límites de recursos).

```
+-------------------------------------------------------------------------+
|                              HOST SYSTEM                                |
|                                                                         |
|  +-----------------------------------+  +----------------------------+  |
|  |           CONTAINER A             |  |        CONTAINER B         |  |
|  |  +-----------------------------+  |  |  +----------------------+  |  |
|  |  | Process (PID 1 in NS)       |  |  |  | Process (PID 1 in NS) |  |  |
|  |  | (PID 14201 on Host)         |  |  |  | (PID 14389 on Host)    |  |  |
|  |  +-----------------------------+  |  |  +----------------------+  |  |
|  |  +-----------------------------+  |  |  +----------------------+  |  |
|  |  | Mount NS / Overlay2 Merged  |  |  |  | Mount NS / Volume    |  |  |
|  |  +-----------------------------+  |  |  +----------------------+  |  |
|  +-----------------------------------+  +----------------------------+  |
|                    |                                  |                 |
|  ==================v==================================v===============  |
|                               LINUX KERNEL                              |
|  Namespaces: pid, net, mnt, ipc, uts, user | cgroups v2: cpu, memory, io|
+-------------------------------------------------------------------------+
```

### Mecanismos Arquitectónicos Clave
1. **Linux Namespaces**:
   * `pid`: Aislamiento de procesos (los procesos dentro del contenedor ven su propio árbol de PID comenzando en PID 1).
   * `net`: Aislamiento de dispositivos de red, tabla de enrutamiento IP y enlace de puertos (port binding).
   * `mnt`: Aislamiento de puntos de montaje, permitiendo una vista aislada del sistema de archivos raíz.
   * `ipc`: Aislamiento de comunicación entre procesos (POSIX message queues, System V IPC).
   * `uts`: Aislamiento de UNIX Timesharing System (hostname y nombre de dominio).
   * `user`: Mapeo de ID de usuario y grupo (mapeo de root dentro del contenedor a un UID que no es root en el host).
2. **Control Groups (cgroups v1 / v2)**:
   * Aplica límites estrictos (hard) y flexibles (soft) en los subsistemas del kernel (`memory.max`, `cpu.max`, `io.weight`).
   * Gestiona los disparadores del Out-Of-Memory (OOM) killer cuando se alcanzan los límites de memoria.
3. **Abstracción de Almacenamiento**:
   * **Overlay2 Union File System**: Combina capas de imagen de solo lectura (`lowerdir`) con una capa efímera de lectura-escritura del contenedor (`upperdir`) fusionadas a través de una vista unificada del sistema de archivos (`merged`).
   * **Volumes**: Gestionados directamente por Docker bajo `/var/lib/docker/volumes/`, omitiendo la sobrecarga de copy-on-write.
   * **Bind Mounts**: Mapea la ruta del host directamente dentro del namespace de montaje del contenedor.
   * **tmpfs Mounts**: Monta la memoria del host directamente, sin escribir nunca datos en capas de almacenamiento no volátil.

---

## Ejercicios Guiados

---

### Ejercicio 1: Ejecución de Contenedores, Aislamiento de Procesos e Inspección de Kernel Namespaces

#### Escenario y Objetivo
Necesitás ejecutar un contenedor de aplicación Nginx, inspeccionar su aislamiento de procesos a nivel de host, analizar los IDs de los kernel namespaces, interactuar con los procesos del contenedor en ejecución y copiar artefactos de diagnóstico sin modificar la capa de imagen del contenedor.

#### Pasos de Ejecución

1. Iniciar un servidor web Nginx aislado en modo desacoplado (detached) con mapeos de puertos específicos y nombre de contenedor.
   ```bash
   docker run -d --name web-prod-01 -p 8080:80 nginx:1.25-alpine
   ```
   *Expected Output:*
   ```text
   a1b2c3d4e5f67890abcdef1234567890abcdef1234567890abcdef1234567890
   ```

2. Listar los procesos en ejecución dentro del namespace del contenedor usando `docker top`.
   ```bash
   docker top web-prod-01
   ```
   *Expected Output:*
   ```text
   UID         PID         PPID        C           STIME       TTY         TIME        CMD
   root        14201       14180       0           04:45       ?           00:00:00    nginx: master process nginx -g daemon off;
   101         14245       14201       0           04:45       ?           00:00:00    nginx: worker process
   ```

3. Identificar el PID del host para el proceso principal del contenedor usando `docker inspect`.
   ```bash
   HOST_PID=$(docker inspect --format '{{.State.Pid}}' web-prod-01)
   echo "Host PID of container PID 1: ${HOST_PID}"
   ```
   *Expected Output:*
   ```text
   Host PID of container PID 1: 14201
   ```

4. Comparar los enlaces simbólicos de los kernel namespaces entre el proceso actual del host (`self`) y el PID del contenedor en el host (`14201`).
   ```bash
   ls -l /proc/self/ns/pid /proc/${HOST_PID}/ns/pid
   ```
   *Expected Output:*
   ```text
   lrwxrwxrwx 1 root root 0 Aug  7 04:45 /proc/14201/ns/pid -> 'pid:[4026532588]'
   lrwxrwxrwx 1 root root 0 Aug  7 04:45 /proc/self/ns/pid -> 'pid:[4026531836]'
   ```

5. Ejecutar una sesión interactiva de diagnóstico dentro del contenedor en ejecución para inspeccionar el PID 1 y escribir un archivo index personalizado.
   ```bash
   docker exec -it web-prod-01 sh -c "ps aux && echo '<h1>SRE Diagnostics OK</h1>' > /usr/share/nginx/html/index.html"
   ```
   *Expected Output:*
   ```text
   PID   USER     TIME  COMMAND
       1 root      0:00 nginx: master process nginx -g daemon off;
       7 101       0:00 nginx: worker process
      15 root      0:00 sh -c ps aux && echo '<h1>SRE Diagnostics OK</h1>' > /usr/share/nginx/html/index.html
   ```

6. Extraer `/etc/nginx/nginx.conf` del contenedor hacia el sistema de archivos de la máquina host para auditoría.
   ```bash
   docker cp web-prod-01:/etc/nginx/nginx.conf ./nginx-host-audit.conf
   head -n 5 ./nginx-host-audit.conf
   ```
   *Expected Output:*
   ```text
   user  nginx;
   worker_processes  auto;

   error_log  /var/log/nginx/error.log notice;
   pid        /var/run/nginx.pid;
   ```

#### Preguntas de Comprensión - Ejercicio 1
1. **P1.1**: ¿Por qué `/proc/14201/ns/pid` muestra un número de inodo de namespace diferente (`4026532588`) que `/proc/self/ns/pid` (`4026531836`)?
2. **P1.2**: Si ejecutás `kill -9 14201` directamente desde la shell de root del sistema host, ¿qué le sucede al contenedor y por qué?
3. **P1.3**: ¿Cómo logra `docker exec` generar un nuevo proceso dentro de un contenedor existente sin crear una nueva instancia de contenedor?

---

### Ejercicio 2: Arquitectura de Almacenamiento - Mecánica de Overlay2, Bind Mounts, Named Volumes y Tmpfs

#### Escenario y Objetivo
Se te ha encomendado evaluar las opciones de almacenamiento para el almacenamiento persistente de una base de datos, secretos efímeros y uso compartido de configuración del host. Inspeccionarás la disposición de directorios subyacente del driver de almacenamiento `overlay2` y compararás las características de rendimiento/aislamiento entre los tipos de volúmenes.

```
+-----------------------------------------------------------------------------------+
| CONTAINER STORAGE LAYERS                                                          |
|                                                                                   |
| +-------------------------------------------------------------------------------+ |
| | RW Container Layer (UpperDir) -> Modifications, diffs, temporary writes      | |
| +-------------------------------------------------------------------------------+ |
| | Merged View (OverlayFS)      -> Unified filesystem exposed to container         | |
| +-------------------------------------------------------------------------------+ |
| | RO Image Layer 2 (LowerDir)  -> Modified software packages                     | |
| +-------------------------------------------------------------------------------+ |
| | RO Image Layer 1 (LowerDir)  -> Base OS (Alpine / Debian)                       | |
| +-------------------------------------------------------------------------------+ |
|                                                                                   |
| DIRECT STORAGE BYPASS MOUNTS:                                                     |
|  * Named Volume -> /var/lib/docker/volumes/<name>/_data  (High performance IO)    |
|  * Bind Mount   -> /path/on/host                         (Host file integration)  |
|  * Tmpfs Mount  -> Host RAM (tmpfs)                      (Secure ephemeral write) |
+-----------------------------------------------------------------------------------+
```

#### Pasos de Ejecución

1. Inspeccionar las rutas del layout del driver de almacenamiento `overlay2` para el contenedor `web-prod-01`.
   ```bash
   docker inspect --format 'LowerDir: {{.GraphDriver.Data.LowerDir}}{{"\n"}}UpperDir: {{.GraphDriver.Data.UpperDir}}{{"\n"}}MergedDir: {{.GraphDriver.Data.MergedDir}}' web-prod-01
   ```
   *Expected Output:*
   ```text
   LowerDir: /var/lib/docker/overlay2/a89f.../diff:/var/lib/docker/overlay2/b12c.../diff
   UpperDir: /var/lib/docker/overlay2/e56f.../diff
   MergedDir: /var/lib/docker/overlay2/e56f.../merged
   ```

2. Crear un Docker Named Volume para el almacenamiento persistente de datos de PostgreSQL.
   ```bash
   docker volume create pg-data-prod
   docker volume inspect pg-data-prod
   ```
   *Expected Output:*
   ```text
   [
       {
           "CreatedAt": "2026-08-07T04:46:10Z",
           "Driver": "local",
           "Labels": {},
           "Mountpoint": "/var/lib/docker/volumes/pg-data-prod/_data",
           "Name": "pg-data-prod",
           "Options": {},
           "Scope": "local"
       }
   ]
   ```

3. Iniciar un contenedor con tres configuraciones de almacenamiento distintas:
   * Named volume montado en `/var/lib/postgresql/data`
   * Bind mount montado en `/var/log/app_host_logs`
   * Tmpfs mount montado en `/tmp/secrets` (límite de tamaño 64MB, modo 0700)
   ```bash
   mkdir -p /tmp/host_logs

   docker run -d \
     --name db-store-01 \
     --mount type=volume,source=pg-data-prod,target=/var/lib/postgresql/data \
     --mount type=bind,source=/tmp/host_logs,target=/var/log/app_host_logs \
     --mount type=tmpfs,target=/tmp/secrets,tmpfs-size=67108864,tmpfs-mode=0700 \
     alpine tail -f /dev/null
   ```
   *Expected Output:*
   ```text
   d7e8f9a0b1c234567890abcdef1234567890abcdef1234567890abcdef123456
   ```

4. Verificar la propagación de montaje y las operaciones de escritura a través de los backends de almacenamiento dentro del contenedor.
   ```bash
   docker exec db-store-01 sh -c \
     "echo 'vol_data' > /var/lib/postgresql/data/db.dat && \
      echo 'log_data' > /var/log/app_host_logs/app.log && \
      echo 'secret_key' > /tmp/secrets/api.key"
   ```

5. Confirmar la persistencia en el host para los archivos del named volume y del bind mount.
   ```bash
   cat /var/lib/docker/volumes/pg-data-prod/_data/db.dat
   cat /tmp/host_logs/app.log
   ```
   *Expected Output:*
   ```text
   vol_data
   log_data
   ```

6. Detener y remover el contenedor `db-store-01` y verificar la no persistencia de `tmpfs`.
   ```bash
   docker rm -f db-store-01
   ls -la /tmp/secrets 2>/dev/null || echo "Tmpfs mount unmounted and memory purged."
   ```
   *Expected Output:*
   ```text
   Tmpfs mount unmounted and memory purged.
   ```

#### Preguntas de Comprensión - Ejercicio 2
1. **P2.1**: ¿Cómo impacta la estrategia copy-on-write (CoW) en `overlay2` al rendimiento de escritura cuando se modifica un archivo de 10GB contenido en una capa de imagen `lowerdir` subyacente?
2. **P2.2**: ¿Por qué se prefieren los Docker Named Volumes sobre los Bind Mounts del host para motores de bases de datos en producción que se ejecutan en Linux?
3. **P2.3**: ¿Qué ventajas de seguridad y rendimiento ofrece `tmpfs` para archivos sensibles (por ejemplo, claves API, claves privadas SSL)?

---

### Ejercicio 3: Redes de Contenedores Avanzadas - Custom Bridges, Publicación de Puertos y Network Namespaces

#### Escenario y Objetivo
Necesitás construir una topología de red multinivel aislada utilizando redes bridge definidas por el usuario en Docker. Configurarás la resolución DNS interna del contenedor, publicarás puertos objetivo a las interfaces del host y depurarás las reglas de iptables del contenedor usando herramientas de red del kernel.

```
+-------------------------------------------------------------------------------------+
| HOST NETWORK INTERFACE (eth0: 192.168.1.50)                                        |
|  |                                                                                  |
|  +--- Published Port 8080:80 (iptables DNAT rule)                                   |
|                                                                                     |
| DOCKER CUSTOM BRIDGE (net-prod-backend: 172.28.0.0/16)                             |
|  |                                                                                  |
|  +---> [ app-api-01 ] (IP: 172.28.0.2) --- Embedded DNS (127.0.0.11)                 |
|  |         ^                               |                                        |
|  |         | Automatic DNS Resolution      | Automatic DNS Resolution               |
|  |         v                               v                                        |
|  +---> [ app-db-01 ]  (IP: 172.28.0.3) <----+                                       |
+-------------------------------------------------------------------------------------+
```

#### Pasos de Ejecución

1. Crear una red bridge aislada personalizada con parámetros específicos de subred y gateway.
   ```bash
   docker network create \
     --driver bridge \
     --subnet 172.28.0.0/16 \
     --gateway 172.28.0.1 \
     net-prod-backend
   ```
   *Expected Output:*
   ```text
   c3b2a10987654321fedcba9876543210fedcba9876543210fedcba9876543210
   ```

2. Iniciar un contenedor de base de datos conectado a `net-prod-backend` sin exponer puertos a la interfaz del host.
   ```bash
   docker run -d \
     --name app-db-01 \
     --network net-prod-backend \
     --network-alias database.internal \
     alpine sleep 3600
   ```
   *Expected Output:*
   ```text
   e1f2a3b4c5d678901234567890abcdef1234567890abcdef1234567890abcdef
   ```

3. Iniciar un contenedor de servidor de aplicaciones conectado a `net-prod-backend` publicando el puerto 8080.
   ```bash
   docker run -d \
     --name app-api-01 \
     --network net-prod-backend \
     -p 8080:80 \
     nginx:1.25-alpine
   ```
   *Expected Output:*
   ```text
   f9e8d7c6b5a432109876543210fedcba9876543210fedcba9876543210fedcba
   ```

4. Probar el descubrimiento automático de servicios DNS embebido desde `app-api-01` hacia `app-db-01` mediante el nombre y el alias de red.
   ```bash
   docker exec app-api-01 ping -c 2 app-db-01
   docker exec app-api-01 nslookup database.internal
   ```
   *Expected Output:*
   ```text
   PING app-db-01 (172.28.0.2): 56 data bytes
   64 bytes from 172.28.0.2: seq=0 ttl=64 time=0.082 ms
   64 bytes from 172.28.0.2: seq=1 ttl=64 time=0.075 ms

   Server:		127.0.0.11
   Address:	127.0.0.11:53

   Name:	database.internal
   Address: 172.28.0.2
   ```

5. Inspeccionar las reglas de la tabla NAT de `iptables` en el host creadas por Docker para la redirección de puertos (port forwarding).
   ```bash
   iptables -t nat -L DOCKER -n -v
   ```
   *Expected Output:*
   ```text
   Chain DOCKER (2 references)
    pkts bytes target     prot opt in     out     source               destination         
       0     0 ACCEPT     tcp  --  !br-c3b2a1098765 br-c3b2a1098765  0.0.0.0/0            172.28.0.3           tcp dpt:80
   ```

6. Verificar los detalles del enlace de puertos en las interfaces de red del host usando `docker port`.
   ```bash
   docker port app-api-01
   ```
   *Expected Output:*
   ```text
   80/tcp -> 0.0.0.0:8080
   80/tcp -> [::]:8080
   ```

#### Preguntas de Comprensión - Ejercicio 3
1. **P3.1**: ¿Por qué la resolución automática de DNS por nombre de contenedor funciona en redes bridge definidas por el usuario, pero falla en la red `bridge` por defecto (`docker0`)?
2. **P3.2**: ¿Cuál es el propósito de la IP del resolvedor DNS interno `127.0.0.11` enumerada dentro de `/etc/resolv.conf` del contenedor `app-api-01`?
3. **P3.3**: ¿En qué se diferencia el modo `--network host` del modo de red bridge con respecto a la latencia de red, el aislamiento de seguridad y las colisiones de puertos?

---

### Ejercicio 4: Asignación de Recursos, Control de Cgroups v2, Limitación de Memoria y Diagnósticos de OOM

#### Escenario y Objetivo
Necesitás evitar problemas de contenedores "noisy-neighbor" (vecinos ruidosos) aplicando cuotas explícitas de CPU y límites de memoria. Provocarás una condición de Out-Of-Memory (OOM), verificarás los archivos de control cgroup del kernel e inspeccionarás los códigos de salida (exit codes) usando diagnósticos estándar de CLI.

```
+-------------------------------------------------------------------------------------+
| CGROUPS V2 RESOURCE BOUNDARIES                                                      |
|                                                                                     |
| Container Configuration: --memory=128m --cpus="0.5"                                |
|                                                                                     |
| Kernel Control Path: /sys/fs/cgroup/docker/<container-id>/                          |
|                                                                                     |
|   +-----------------------+     +-----------------------------------------------+   |
|   | memory.max = 134217728|     | cpu.max = 50000 100000                        |   |
|   | (Hard memory limit)   |     | (50ms quota per 100ms period = 0.5 Cores)     |   |
|   +-----------------------+     +-----------------------------------------------+   |
|               |                                         |                           |
|   Exceeding limit triggers                  CFS Scheduler throttles CPU             |
|   Kernel OOM Killer (Exit 137)              time when quota is exhausted            |
+-------------------------------------------------------------------------------------+
```

#### Pasos de Ejecución

1. Iniciar un contenedor con restricciones de recursos con 128MB de memoria, límite de Swap de 64MB y asignación de 0.5 CPU.
   ```bash
   docker run -d \
     --name stress-limit-01 \
     --memory 128m \
     --memory-swap 192m \
     --cpus 0.5 \
     progrium/stress --cpu 2 --io 1 --vm 1 --vm-bytes 64M
   ```
   *Expected Output:*
   ```text
   a1b2c3d4e5f678901234567890abcdef1234567890abcdef1234567890abcdef
   ```

2. Inspeccionar la utilización de recursos en tiempo real mediante streaming usando `docker stats` (ejecución única sin streaming).
   ```bash
   docker stats stress-limit-01 --no-stream
   ```
   *Expected Output:*
   ```text
   CONTAINER ID   NAME              CPU %     MEM USAGE / LIMIT   MEM %     NET I/O     BLOCK I/O   PIDS
   a1b2c3d4e5f6   stress-limit-01   50.12%    68.4MiB / 128MiB    53.44%    1.02kB/0B   0B / 0B     5
   ```

3. Leer los archivos de parámetros de cgroup v2 del kernel del host para el contenedor `stress-limit-01`.
   ```bash
   FULL_ID=$(docker inspect --format '{{.Id}}' stress-limit-01)
   
   # Read memory hard limit
   cat /sys/fs/cgroup/system.slice/docker-${FULL_ID}.scope/memory.max 2>/dev/null || \
   cat /sys/fs/cgroup/docker/${FULL_ID}/memory.max
   
   # Read CPU limit quota/period
   cat /sys/fs/cgroup/system.slice/docker-${FULL_ID}.scope/cpu.max 2>/dev/null || \
   cat /sys/fs/cgroup/docker/${FULL_ID}/cpu.max
   ```
   *Expected Output:*
   ```text
   134217728
   50000 100000
   ```

4. Provocar un estado de Out-Of-Memory (OOM) intencional al iniciar un contenedor que intente asignar 256MB con un límite de 64MB.
   ```bash
   docker run --name oom-test-01 --memory 64m alpine sh -c "python3 -c 'a = \"A\" * 200000000' 2>/dev/null || tail -c 200M /dev/zero | grep -a a"
   ```
   *Expected Output:*
   ```text
   Killed
   ```

5. Inspeccionar el estado de salida, flags de error y el estado de OOMKilled usando `docker inspect`.
   ```bash
   docker inspect --format 'State: ExitCode={{.State.ExitCode}}, OOMKilled={{.State.OOMKilled}}, Error={{.State.Error}}' oom-test-01
   ```
   *Expected Output:*
   ```text
   State: ExitCode=137, OOMKilled=true, Error=
   ```

6. Limpiar los contenedores de prueba de estrés de diagnóstico.
   ```bash
   docker rm -f stress-limit-01 oom-test-01
   ```

#### Preguntas de Comprensión - Ejercicio 4
1. **P4.1**: ¿Qué indica un código de salida (Exit Code) `137` cuando es devuelto por un contenedor Docker detenido?
2. **P4.2**: Si `--memory` está configurado en `256m` y `--memory-swap` está configurado en `256m`, ¿cuánto espacio swap total está disponible para el contenedor?
3. **P4.3**: ¿Cómo aplica el kernel Completely Fair Scheduler (CFS) la opción `--cpus="0.5"` usando `cpu.cfs_quota_us` y `cpu.cfs_period_us` bajo cgroups v1/v2?

---

### Ejercicio 5: Logging en Producción, Inspección de Contenedores con Plantillas Go y Diagnósticos en Tiempo Real

#### Escenario y Objetivo
Necesitás implementar pipelines de diagnóstico avanzados para la resolución de problemas en contenedores de producción. Filtrarás metadatos de contenedores usando plantillas de Go en `docker inspect`, controlarás los límites del driver de logging, rastrearás el uso de recursos de procesos con `docker top` y monitorearás logs de ejecución en tiempo real.

#### Pasos de Ejecución

1. Iniciar un servicio de producción generador de logs configurado con límites de rotación mediante `--log-opt`.
   ```bash
   docker run -d \
     --name logger-prod-01 \
     --log-driver json-file \
     --log-opt max-size=10m \
     --log-opt max-file=3 \
     alpine sh -c "i=0; while true; do echo \"$(date -u -Iseconds) [INFO] Processing batch record #\$i\"; i=\$((i+1)); sleep 1; done"
   ```
   *Expected Output:*
   ```text
   b2c3d4e5f6a178901234567890abcdef1234567890abcdef1234567890abcdef
   ```

2. Extraer campos de metadatos complejos (dirección IP, puntos de montaje, política de reinicio, estado) usando `docker inspect` con plantillas de formato Go.
   ```bash
   docker inspect --format '
   Container Name  : {{.Name}}
   Status          : {{.State.Status}} (Running: {{.State.Running}})
   IP Address      : {{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}
   Log Path        : {{.LogPath}}
   Restart Policy  : {{.HostConfig.RestartPolicy.Name}}
   ' logger-prod-01
   ```
   *Expected Output:*
   ```text
   Container Name  : /logger-prod-01
   Status          : running (Running: true)
   IP Address      : 172.17.0.2
   Log Path        : /var/lib/docker/containers/b2c3d4e5f6a1.../b2c3d4e5f6a1...-json.log
   Restart Policy  : no
   ```

3. Transmitir (stream) la salida de logs del contenedor con marca de tiempo (timestamping) y seguimiento del final del log (tailing).
   ```bash
   docker logs --timestamps --tail 5 logger-prod-01
   ```
   *Expected Output:*
   ```text
   2026-08-07T04:48:01.123456789Z 2026-08-07T04:48:01Z [INFO] Processing batch record #0
   2026-08-07T04:48:02.124567890Z 2026-08-07T04:48:02Z [INFO] Processing batch record #1
   2026-08-07T04:48:03.125678901Z 2026-08-07T04:48:03Z [INFO] Processing batch record #2
   2026-08-07T04:48:04.126789012Z 2026-08-07T04:48:04Z [INFO] Processing batch record #3
   2026-08-07T04:48:05.127890123Z 2026-08-07T04:48:05Z [INFO] Processing batch record #4
   ```

4. Mostrar procesos específicos del SO que se ejecutan dentro del contenedor con argumentos de salida personalizados usando `docker top`.
   ```bash
   docker top logger-prod-01 -o pid,comm,args
   ```
   *Expected Output:*
   ```text
   PID         COMMAND         COMMAND
   15102       sh              sh -c i=0; while true; do echo "$(date -u -Iseconds) [INFO] Processing batch record #$i"; i=$((i+1)); sleep 1; done
   15145       sleep           sleep 1
   ```

5. Obtener las ubicaciones de los archivos de log y comprobar el uso del disco físico de los logs del contenedor en el sistema host.
   ```bash
   LOG_FILE=$(docker inspect --format '{{.LogPath}}' logger-prod-01)
   ls -lh ${LOG_FILE}
   ```
   *Expected Output:*
   ```text
   -rw-r----- 1 root root 402 Aug  7 04:48 /var/lib/docker/containers/b2c3d4e5f6a1.../b2c3d4e5f6a1...-json.log
   ```

6. Realizar la limpieza masiva de todos los contenedores de ejercicios activos y redes definidas por el usuario.
   ```bash
   docker rm -f web-prod-01 app-api-01 app-db-01 logger-prod-01
   docker network rm net-prod-backend
   docker volume rm pg-data-prod
   ```

#### Preguntas de Comprensión - Ejercicio 5
1. **P5.1**: ¿Qué riesgo se introduce si los contenedores de producción de alto rendimiento usan el driver de logging por defecto `json-file` sin especificar `--log-opt max-size`?
2. **P5.2**: ¿Cómo podés formatear `docker inspect` usando salida JSON canalizada a `jq` para extraer todas las variables de entorno que comiencen con `PORT`?
3. **P5.3**: ¿Cuál es la diferencia entre `docker stop` y `docker kill` con respecto a la entrega de señales (`SIGTERM` vs `SIGKILL`) y los períodos de gracia?

---

<details>
<summary><b>Respuestas y Explicaciones Detalladas</b></summary>

### Respuestas del Ejercicio 1

* **R1.1**: Los inodos del Linux Kernel Namespace aíslan los recursos globales del sistema. `/proc/14201/ns/pid` hace referencia al inodo `4026532588`, el cual define el límite del PID namespace aislado para `web-prod-01`. Dentro de este namespace, al proceso maestro de Nginx se le asigna el PID 1. `/proc/self/ns/pid` hace referencia al inodo `4026531836`, representando el PID namespace raíz del host donde el proceso tiene el PID `14201`.
* **R1.2**: Ejecutar `kill -9 14201` envía una señal `SIGKILL` no capturable directamente al proceso del host que representa el PID 1 dentro del PID namespace del contenedor. Como el PID 1 es el proceso entrypoint del contenedor, matarlo hace que el kernel de Linux termine inmediatamente todos los procesos hijos en ese PID namespace y destruya el contenedor.
* **R1.3**: `docker exec` invoca la llamada al sistema (system call) `setns()` del kernel para unirse a los namespaces existentes (PID, NET, MNT, IPC, UTS) del proceso objetivo PID 1 (`/proc/14201/ns/`). Una vez dentro de esos descriptores de archivo de namespace, `execve()` ejecuta el binario especificado (`sh`), ejecutándolo bajo los límites del contenedor existente sin crear una nueva estructura de contenedor.

---

### Respuestas del Ejercicio 2

* **R2.1**: Cuando un proceso escribe en un archivo preexistente en `lowerdir` bajo `overlay2`, el kernel realiza una operación **Copy-on-Write (CoW)**: copia el archivo completo desde la capa inferior de solo lectura a la capa superior de lectura-escritura del contenedor (`upperdir`) antes de completar la modificación. Para un archivo de 10GB, esto incurre en una latencia masiva de I/O de disco, una severa sobrecarga de asignación de bloques y un consumo de almacenamiento duplicado.
* **R2.2**: Los Named Volumes se almacenan directamente en `/var/lib/docker/volumes/<name>/_data` utilizando formatos nativos del sistema de archivos del host (por ejemplo, ext4, xfs) omitiendo por completo el driver CoW de `overlay2`. Esto garantiza el máximo rendimiento de I/O nativo en bruto. Además, los Named Volumes son gestionados por abstracciones de la CLI de Docker y aislados de cambios accidentales en la ruta del sistema de archivos del host.
* **R2.3**: Los montajes `tmpfs` escriben directamente en la RAM del host (memoria volátil) y se desmontan por completo al finalizar el contenedor. Los secretos sensibles (claves privadas, tokens) escritos en `tmpfs` nunca se escriben en unidades de almacenamiento físico del host (SSD/NVMe), evitando fugas de almacenamiento, exposición de datos residuales en imágenes de disco del host o sobrecarga de almacenamiento CoW.

---

### Respuestas del Ejercicio 3

* **R3.1**: Docker habilita su servidor DNS embebido (`127.0.0.11`) **únicamente** para redes bridge personalizadas definidas por el usuario. En la red `bridge` por defecto heredada (`docker0`), la resolución de nombres de contenedores está deshabilitada por compatibilidad hacia atrás, requiriendo flags heredados `--link` o comunicación explícita por dirección IP.
* **R3.2**: `127.0.0.11` es la dirección IP de loopback del resolvedor DNS embebido de Docker. Cuando un contenedor en una red bridge personalizada consulta un nombre de dominio, las reglas de iptables redirigen el tráfico del puerto 53 al demonio resolvedor interno del demonio de Docker, el cual mapea dinámicamente nombres de contenedores y alias de red a sus direcciones IP de contenedor activas.
* **R3.3**: Bajo `--network host`, el contenedor comparte directamente el namespace de red del host:
  * **Latencia**: Elimina la superposición de abstracción de red y la sobrecarga de NAT de iptables, ofreciendo un rendimiento nativo bare-metal.
  * **Seguridad**: Elimina el aislamiento de la capa de red; los procesos del contenedor pueden enlazarse directamente a las interfaces del host y escuchar (sniff) el tráfico del host.
  * **Colisiones de puertos**: Los enlaces de puertos son globales; dos contenedores no pueden enlazarse al puerto 80 simultáneamente en el host.

---

### Respuestas del Ejercicio 4

* **R4.1**: Un código de salida (Exit Code) `137` indica que el proceso fue terminado por `SIGKILL` (Señal 9) emitida por el Linux Kernel Out-Of-Memory (OOM) Killer (`128 + 9 = 137`). Esto ocurre cuando un proceso de contenedor excede su techo estricto de memoria cgroup (`memory.max`).
* **R4.2**: Cero espacio swap total. Docker define `--memory-swap` como la **suma total** de RAM más Swap. Si `--memory` es `256m` y `--memory-swap` es `256m`, el Swap se calcula como `256m - 256m = 0m`. Para otorgar 256MB de RAM y 128MB de Swap, `--memory-swap` debe configurarse en `384m`.
* **R4.3**: El Completely Fair Scheduler (CFS) del kernel de Linux aplica la asignación fraccionada de CPU utilizando un sistema de cuotas sobre un período definido (por defecto 100ms / `100000us`):
  * `cpu.cfs_period_us` = `100000` (100ms)
  * `cpu.cfs_quota_us` = `50000` (50ms)
  Una configuración de `--cpus="0.5"` configura el cgroup para permitir a los procesos del contenedor un presupuesto de ejecución máximo de 50ms por cada ventana de 100ms en todos los núcleos de CPU del host.

---

### Respuestas del Ejercicio 5

* **R5.1**: Los logs `json-file` no limitados llenan las particiones de almacenamiento del host sin restricción. Si la salida stdout/stderr del contenedor genera un exceso de logs, `/var/lib/docker/containers/<id>/<id>-json.log` consumirá el 100% del espacio en disco del host, resultando en fallas del sistema host, remontajes del sistema de archivos a solo lectura e interrupciones de aplicaciones en cascada.
* **R5.2**: Canalizás (pipe) la salida JSON formateada de `docker inspect` directamente a `jq`:
  ```bash
  docker inspect logger-prod-01 | jq '.[0].Config.Env | map(select(startswith("PORT=")))'
  ```
* **R5.3**: 
  * `docker stop`: Envía `SIGTERM` al proceso PID 1 dentro del contenedor, iniciando un período de apagado gradual (graceful shutdown, por defecto 10 segundos). Si el proceso no termina dentro del período de gracia, Docker envía `SIGKILL`.
  * `docker kill`: Omite por completo el apagado gradual enviando `SIGKILL` (o una señal personalizada especificada) de manera inmediata al PID 1, terminando la ejecución del proceso instantáneamente sin manejadores de limpieza.

</details>