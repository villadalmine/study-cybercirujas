# Examen LPIC-3 305-300 (v3.0): Virtualización Avanzada de Contenedores y Arquitectura de Producción

## Descripción General del Tema y Objetivos de Análisis Profundo

La virtualización de contenedores aprovecha las primitivas a nivel de kernel para aislar procesos y restringir el consumo de recursos sin la sobrecarga de rendimiento del emulado completo de hardware (hipervisores). Este módulo proporciona ejercicios guiados prácticos de grado de producción dirigidos al **Examen LPIC-3 305-300 (Tema 352: Virtualización de Contenedores)** e ingeniería avanzada de runtimes de contenedores de la CNCF.

### Resumen de Arquitectura y Primitivas del Kernel
1. **Namespaces (Aislamiento):** Proporcionan vistas aisladas de los recursos del sistema.
   - `PID`: Aislamiento de procesos (PID 1 dentro del namespace).
   - `NET`: Stacks de red (pares veth, tablas de enrutamiento, iptables/nftables).
   - `MNT`: Puntos de montaje del sistema de archivos (`pivot_root`).
   - `IPC`: IPC de System V y colas de mensajes POSIX.
   - `UTS`: Hostname y nombre de dominio NIS.
   - `USER`: Mapeo de UID/GID (permite contenedores rootless).
   - `CGROUP`: Vista aislada de `/proc/self/cgroup`.
   - `TIME`: `CLOCK_MONOTONIC` y `CLOCK_REALTIME` virtualizados (Linux 5.6+).
2. **Control Groups v2 (Control de Recursos):** Jerarquía unificada que aplica límites en CPU (`cpu.max`), memoria (`memory.max`, `memory.high`), E/S de bloques (`io.weight`, `io.max`) y PIDs (`pids.max`).
3. **Primitivas de Seguridad:**
   - **Linux Capabilities:** División de los privilegios de `root` en permisos granulares a nivel de hilo (ej., `CAP_NET_ADMIN`, `CAP_SYS_ADMIN`, `CAP_CHOWN`).
   - **Seccomp (Secure Computing Mode):** Filtrado de llamadas al sistema basado en BPF para restringir la interacción con el kernel del host.
   - **LSM (AppArmor/SELinux):** Control de Acceso Obligatorio (MAC) que restringe rutas del sistema de archivos y capacidades de sockets.

---

## Lab 1: Primitivas del Kernel de Linux de Bajo Nivel (Namespaces, Cgroups v2, Capabilities, Seccomp)

### Objetivo
Deconstruir cómo los runtimes de contenedores instancian entornos aislados orquestando manualmente namespaces de Linux, configurando controladores de cgroup v2, eliminando capabilities y rastreando filtros seccomp usando utilidades de bajo nivel (`unshare`, `nsenter`, `capsh`, `systemd-run`).

### Pasos Guiados

1. **Auditar el Soporte y la Jerarquía de Cgroup v2:**
   Verificar que el host ejecute cgroup v2 unificado:
   ```bash
   stat -f -c %T /sys/fs/cgroup
   ```
   *Output Esperado:*
   ```text
   cgroup2fs
   ```

2. **Aprovisionar Manualmente un Directorio Cgroup v2 Delimitado para la Aplicación de Recursos:**
   Crear un control group dedicado bajo la jerarquía unificada, habilitar controladores y aplicar límites máximos de CPU y Memoria:
   ```bash
   sudo mkdir -p /sys/fs/cgroup/production-workload
   echo "+cpu +memory +pids" | sudo tee /sys/fs/cgroup/cgroup.subtree_control
   echo "100000 100000" | sudo tee /sys/fs/cgroup/production-workload/cpu.max
   echo "52428800" | sudo tee /sys/fs/cgroup/production-workload/memory.max
   ```

3. **Instanciar un Sandbox de Namespace Aislado usando `unshare`:**
   Ejecutar una shell aislada con namespaces `PID`, `NET`, `MNT`, `UTS` e `IPC` distintos adjuntos al cgroup creado:
   ```bash
   sudo unshare --pid --net --mount --uts --ipc --fork \
     /bin/bash -c "echo \$\$ > /sys/fs/cgroup/production-workload/cgroup.procs && exec hostname sandbox-node-01 && exec bash"
   ```

4. **Verificar el Aislamiento de Namespaces desde el Interior del Sandbox:**
   Dentro de la shell recién creada, montar `/proc` para observar el aislamiento de PID e inspeccionar el stack de red:
   ```bash
   mount -t proc proc /proc
   ps aux
   ip addr show
   ```
   *Output Esperado:*
   ```text
   USER         PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
   root           1  0.0  0.0   8944  4212 pts/0    S+   14:20   0:00 sandbox-node-01
   root           8  0.0  0.0   9820  3400 pts/0    R+   14:21   0:00 ps aux

   1: lo: <LOOPBACK> mtu 65536 qdisc noop state DOWN group default qlen 1000
       link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
   ```

5. **Probar la Aplicación del Límite de Recursos (Memory Out-Of-Memory Killer):**
   Intentar asignar 100MB de memoria dentro del sandbox (el cual tiene un límite de 50MB aplicado a través de `memory.max` = 52,428,800 bytes):
   ```bash
   python3 -c 'x = "A" * (100 * 1024 * 1024)'
   ```
   *Output Esperado:*
   ```text
   Killed
   ```

6. **Inspeccionar la Eliminación de Capabilities con `capsh`:**
   Lanzar una shell eliminando `CAP_SYS_ADMIN`, `CAP_NET_RAW` y `CAP_SYS_PTRACE`:
   ```bash
   capsh --drop=cap_sys_admin,cap_net_raw,cap_sys_ptrace --print -- -c "ping -c 1 127.0.0.1"
   ```
   *Output Esperado:*
   ```text
   Current: = cap_chown,cap_dac_override,...-cap_net_raw,-cap_sys_admin,-cap_sys_ptrace
   Bounding set =cap_chown,...-cap_net_raw,-cap_sys_admin,-cap_sys_ptrace
   ping: socket: Operation not permitted
   ```

---

### Preguntas de Verificación (Lab 1)

1. ¿Por qué montar `/proc` dentro del contenedor en el Paso 4 afectó la visibilidad de `/proc`, y qué riesgo potencial de seguridad a nivel de host ocurre si se ejecuta `unshare --mount` sin modificar la propagación de montaje (`--propagation private`)?
2. En Cgroup v2, ¿cuál es la diferencia operacional exacta entre `memory.max` y `memory.high`, y cómo trata el kernel a los procesos que superan cada umbral?
3. Un proceso en contenedor requiere vincularse al puerto 80 y ajustar el estado de la interfaz de red, pero no se le debe permitir realizar la carga arbitraria de módulos del kernel ni reinicios del sistema. ¿Qué Linux capabilities específicas se deben conservar y cuáles se deben eliminar?

---

## Lab 2: Contenedores de Sistema con Arquitectura LXC y Configuración de Producción

### Objetivo
Diseñar, configurar y gestionar contenedores a nivel de sistema utilizando LXC (Linux Containers). Configurar mapeos personalizados de contenedores no privilegiados, implementar bridging de red estático, aplicar restricciones de recursos de hardware y depurar fallos de inicialización de contenedores utilizando sub-sistemas de registro de LXC.

```
       +-------------------------------------------------------------+
       |                        LXC Host                             |
       |                                                             |
       |  +-----------------------+     +-------------------------+  |
       |  |  Privileged LXC       |     |  Unprivileged LXC       |  |
       |  |  (UID 0 -> Host UID 0)|     |  (UID 0 -> UID 100000)  |  |
       |  +-----------+-----------+     +------------+------------+  |
       |              |                              |               |
       |          veth-priv                      veth-unpriv         |
       |              |                              |               |
       |      +-------v------------------------------v--------+      |
       |      |             Bridge: lxcbr0                    |      |
       |      +-----------------------+-----------------------+      |
       |                              |                              |
       |                         eth0 / enp1s0                       |
       +------------------------------+------------------------------+
                                      |
                                  WAN / LAN
```

### Pasos Guiados

1. **Instalar y Validar las Utilidades del Ecosistema LXC:**
   Instalar LXC y verificar los componentes del runtime del demonio:
   ```bash
   sudo apt-get update && sudo apt-get install -y lxc lxc-templates bridge-utils uidmap
   lxc-checkconfig
   ```

2. **Configurar Mapeos SubUID/SubGID en el Host para Contenedores LXC No Privilegiados:**
   Verificar las entradas de `/etc/subuid` y `/etc/subgid` para el usuario `sreadmin`:
   ```bash
   echo "sreadmin:100000:65536" | sudo tee -a /etc/subuid
   echo "sreadmin:100000:65536" | sudo tee -a /etc/subgid
   ```

3. **Aprovisionar un Manifiesto de Contenedor LXC de Producción:**
   Crear un archivo de configuración de contenedor LXC definido en `/var/lib/lxc/sys-app-01/config`:
   ```bash
   sudo mkdir -p /var/lib/lxc/sys-app-01
   sudo tee /var/lib/lxc/sys-app-01/config << 'EOF'
   # Template configuration
   lxc.include = /usr/share/lxc/config/common.conf
   lxc.arch = amd64

   # Container Architecture & Hostname
   lxc.uts.name = sys-app-01
   lxc.rootfs.path = dir:/var/lib/lxc/sys-app-01/rootfs

   # UID/GID Unprivileged Mapping
   lxc.idmap = u 0 100000 65536
   lxc.idmap = g 0 100000 65536

   # Network Architecture (Virtual Ethernet Bridge)
   lxc.net.0.type = veth
   lxc.net.0.link = lxcbr0
   lxc.net.0.flags = up
   lxc.net.0.hwaddr = 00:16:3e:xx:xx:xx
   lxc.net.0.ipv4.address = 10.0.3.50/24
   lxc.net.0.ipv4.gateway = 10.0.3.1

   # Cgroup v2 Limits
   lxc.cgroup2.cpu.max = 200000 100000
   lxc.cgroup2.memory.max = 1073741824
   lxc.cgroup2.pids.max = 500

   # Security Profiles
   lxc.seccomp.profile = /usr/share/lxc/config/common.seccomp
   lxc.cap.drop = sys_time sys_rawio mac_admin
   EOF
   ```

4. **Inicializar el Sistema de Archivos Root e Iniciar el Contenedor:**
   Crear el rootfs del contenedor usando la plantilla de Alpine Linux y ejecutar comandos del ciclo de vida:
   ```bash
   sudo lxc-create -n sys-app-01 -t download -- -d alpine -r 3.19 -a amd64
   sudo lxc-start -n sys-app-01
   sudo lxc-info -n sys-app-01
   ```
   *Output Esperado:*
   ```text
   Name:           sys-app-01
   State:          RUNNING
   PID:            14230
   IP:             10.0.3.50
   CPU use:        0.12 seconds
   Memory use:     14.21 MiB
   KMem use:       2.10 MiB
   Link:           veth1001_xxxx
    TX bytes:      1.2 KiB
    RX bytes:      2.8 KiB
   ```

5. **Ejecutar Diagnósticos Dentro del Contenedor:**
   Adjuntarse directamente al contexto de ejecución de `sys-app-01` sin SSH:
   ```bash
   sudo lxc-attach -n sys-app-01 -- id
   ```
   *Output Esperado:*
   ```text
   uid=0(root) gid=0(root) groups=0(root)
   ```

6. **Diagnosticar Fallos de Inicialización a través del Registro TRACE:**
   Simular un fallo configurando una opción de arranque inválida e iniciando LXC en modo trace en primer plano:
   ```bash
   sudo lxc-start -n sys-app-01 -F --logpriority=TRACE --logfile=/tmp/lxc-trace.log
   ```
   Inspeccionar `/tmp/lxc-trace.log` para rastrear fallos de `clone3()`, pivot_root o adjunción de veth de red.

---

### Preguntas de Verificación (Lab 2)

1. ¿Cuál es la ventaja fundamental del modelo de seguridad de un contenedor LXC no privilegiado (`lxc.idmap = u 0 100000 65536`) sobre un contenedor privilegiado estándar si un atacante logra la ejecución remota de código arbitrario como `root` dentro del contenedor?
2. Explique cómo interactúan las interfaces `lxc.net.0.type = veth` con los bridges del host (`lxcbr0`) frente a `lxc.net.0.type = macvlan`. ¿Cuáles son los del balance (trade-offs) en el enrutamiento de red y el modo promiscuo en las NICs del host al seleccionar `macvlan`?

---

## Lab 3: Contenedores de Aplicación con Docker, Motor OCI Runtime (runc/containerd), Storage Drivers y Seguridad

### Objetivo
Analizar el stack completo del ciclo de vida de los contenedores de aplicación (`dockerd` $\rightarrow$ `containerd` $\rightarrow$ `containerd-shim-v2` $\rightarrow$ `runc`). Construir imágenes compatibles con OCI multietapa, inspeccionar la jerarquía de capas del storage driver `Overlay2` (`lowerdir`, `upperdir`, `merged`), y aplicar seccomp y sistemas de archivos root de solo lectura.

```
+-------------------------------------------------------------------------------+
|                                Host OS Kernel                                 |
+-------------------------------------------------------------------------------+
       ^                                 ^                               ^
       | syscalls                        | syscalls                      | syscalls
+--------------+                 +---------------+               +--------------+
| Container A  |                 | Container B   |               | Container C  |
| (App Proc)   |                 | (App Proc)    |               | (App Proc)   |
+--------------+                 +---------------+               +--------------+
       ^                                 ^                               ^
       | manages                         | manages                       | manages
+--------------+                 +---------------+               +--------------+
| containerd-  |                 | containerd-   |               | containerd-  |
| shim-v2 (PID)|                 | shim-v2 (PID) |               | shim-v2 (PID)|
+--------------+                 +---------------+               +--------------+
       ^                                 ^                               ^
       +---------------------------------+-------------------------------+
                                         |
                                  gRPC API Control
                                         v
                                 +---------------+
                                 |  containerd   |
                                 +---------------+
                                         ^
                                         | REST / gRPC API
                                 +---------------+
                                 |    dockerd    |
                                 +---------------+
```

### Pasos Guiados

1. **Deconstruir el Árbol de Procesos del Contenedor (`containerd-shim-v2` vs `runc`):**
   Ejecutar un contenedor Nginx desvinculado e inspeccionar la jerarquía de procesos:
   ```bash
   docker run -d --name web-prod -p 8080:80 nginx:alpine
   ps auxf | grep -E "(dockerd|containerd|shim|nginx)"
   ```
   *Output Esperado:*
   ```text
   root        1102  0.1  1.2 124500 48100 ?        Ssl  10:00   0:05 /usr/bin/dockerd -H fd://
   root        1215  0.2  0.9 984000 36200 ?        Ssl  10:00   0:08  \_ /usr/bin/containerd
   root       15420  0.0  0.2 708450  9210 ?        Sl   14:35   0:00      \_ containerd-shim-runc-v2 -namespace moby -id 8a3f... -address /run/containerd/containerd.sock
   101        15442  0.0  0.1   9910  5120 ?        Ss   14:35   0:00          \_ nginx: master process nginx -g daemon off;
   ```
   *Nota Arquitectónica:* `runc` se cierra inmediatamente después de generar el proceso del contenedor. `containerd-shim-v2` permanece activo para actuar como el proceso padre, manejando los streams de E/S de stdout/stderr y conservando los descriptores de archivos para que `containerd` o `dockerd` puedan reiniciarse sin detener el contenedor.

2. **Inspeccionar las Rutas del Graph Driver del Storage Driver Overlay2:**
   Consultar la disposición del sistema de archivos para `web-prod`:
   ```bash
   docker inspect web-prod --format '{{json .GraphDriver.Data}}' | jq .
   ```
   *Output Esperado:*
   ```json
   {
     "LowerDir": "/var/lib/docker/overlay2/e3f4.../diff:/var/lib/docker/overlay2/a1b2.../diff",
     "MergedDir": "/var/lib/docker/overlay2/c8d9.../merged",
     "UpperDir": "/var/lib/docker/overlay2/c8d9.../diff",
     "WorkDir": "/var/lib/docker/overlay2/c8d9.../work"
   }
   ```

3. **Verificar la Mecánica de Copy-on-Write (CoW) de Overlay2:**
   Crear un nuevo archivo dentro del contenedor y verificar que aparezca exclusivamente en `UpperDir` en el host:
   ```bash
   docker exec web-prod touch /var/log/test-cow.log
   UPPER_DIR=$(docker inspect web-prod --format '{{.GraphDriver.Data.UpperDir}}')
   sudo ls -la ${UPPER_DIR}/var/log/test-cow.log
   ```
   *Output Esperado:*
   ```text
   -rw-r--r-- 1 root root 0 Aug 6 14:40 /var/lib/docker/overlay2/c8d9.../diff/var/log/test-cow.log
   ```

4. **Escribir un Dockerfile Multietapa Endurecido para Producción:**
   Crear `Dockerfile.production` aplicando una superficie de ataque mínima, ejecución con usuario no root, eliminando capas escribibles y configurando explícitamente etiquetas OCI:
   ```dockerfile
   # Stage 1: Build Environment
   FROM golang:1.22-alpine AS builder
   WORKDIR /app
   RUN apk add --no-cache git ca-certificates
   COPY go.mod go.sum ./
   RUN go mod download
   COPY . .
   RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
       -ldflags="-w -s -extldflags '-static'" \
       -o microservice .

   # Stage 2: Hardened Runtime Environment
   FROM scratch
   # Copy CA Certificates for outbound TLS
   COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
   # Copy unprivileged non-root user from builder
   COPY --from=builder /etc/passwd /etc/passwd
   COPY --from=builder /app/microservice /microservice

   USER 65534:65534
   EXPOSE 8080
   ENTRYPOINT ["/microservice"]
   ```

5. **Desplegar el Contenedor con Sistema de Archivos Root de Solo Lectura y Capabilities Eliminadas:**
   Ejecutar el contenedor con las máximas restricciones de seguridad:
   ```bash
   docker run -d \
     --name secure-app \
     --read-only \
     --tmpfs /tmp:rw,noexec,nosuid,size=64m \
     --cap-drop=ALL \
     --cap-add=NET_BIND_SERVICE \
     --security-opt no-new-privileges:true \
     -p 8081:8080 \
     nginx:alpine
   ```

---

### Preguntas de Verificación (Lab 3)

1. Si `dockerd` se bloquea o sufre una actualización de binario con cero tiempo de inactividad, ¿por qué los contenedores en ejecución gestionados por `containerd-shim-v2` continúan funcionando sin interrupciones de red ni terminación de procesos?
2. En la arquitectura del storage driver `Overlay2`, describa qué ocurre en la capa VFS del kernel cuando una aplicación en contenedor intenta modificar un archivo de 2GB ubicado dentro de un `LowerDir` de solo lectura. ¿Qué penalización de rendimiento se incurre?
3. ¿Qué riesgo de vulnerabilidad previene `--security-opt no-new-privileges:true`, incluso si un binario dentro del contenedor tiene habilitado el bit `SUID` y es ejecutado por un usuario no privilegiado?

---

## Lab 4: Diagnóstico Avanzado en Producción, Redes de Contenedores y Resolución de Problemas

### Objetivo
Realizar rastreo de red de bajo nivel a través de pares de ethernet virtual (`veth`), atravesar namespaces de red utilizando `nsenter` e `ip netns`, inspeccionar especificaciones OCI utilizando herramientas de bajo nivel (`ctr`, `crictl`), y auditar eventos de violación de seccomp en el registro del sistema.

### Pasos Guiados

1. **Mapear la Interfaz del Contenedor al Par `veth` del Host:**
   Encontrar el índice de red (`iflink`) dentro del contenedor:
   ```bash
   docker exec -it web-prod cat /sys/class/net/eth0/iflink
   ```
   *Output Esperado:*
   ```text
   24
   ```
   Consultar las interfaces del host para identificar qué interfaz coincide con el índice `24`:
   ```bash
   ip link show | grep -E "^24:"
   ```
   *Output Esperado:*
   ```text
   24: veth9c4b12a@if23: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue master docker0 state UP mode DEFAULT group default
   ```

2. **Atravesar el Namespace de Red del Contenedor usando `nsenter`:**
   Obtener el PID del Host del contenedor e ingresar a su namespace de red aislado para realizar capturas de paquetes:
   ```bash
   CONTAINER_PID=$(docker inspect web-prod --format '{{.State.Pid}}')
   sudo nsenter -t ${CONTAINER_PID} -n ip addr show
   sudo nsenter -t ${CONTAINER_PID} -n tcpdump -i eth0 -n "port 80"
   ```

3. **Crear un Enlace Simbólico del Namespace de Red a `ip netns` para la Gestión de Red Estándar:**
   Exponer el namespace de red oculto de Docker a las utilidades de `ip netns`:
   ```bash
   NETNS_PATH=$(docker inspect web-prod --format '{{.NetworkSettings.SandboxKey}}')
   sudo mkdir -p /var/run/netns
   sudo ln -sf ${NETNS_PATH} /var/run/netns/web-prod-ns
   ip netns list
   sudo ip netns exec web-prod-ns ss -tulpn
   ```
   *Output Esperado:*
   ```text
   web-prod-ns (id: 1)
   Netid  State   Recv-Q  Send-Q   Local Address:Port   Peer Address:Port  Process
   tcp    LISTEN  0       511            0.0.0.0:80          0.0.0.0:*      users:(("nginx",pid=15442,fd=6))
   ```

4. **Depuración de Contenedores de Bajo Nivel con la CLI de `containerd` (`ctr`):**
   Interactuar directamente con `containerd` omitiendo el demonio de Docker:
   ```bash
   sudo ctr --namespace moby containers list
   sudo ctr --namespace moby tasks list
   ```

5. **Auditar Violaciones de Llamadas al Sistema Seccomp a través del Demonio de Auditoría del Kernel:**
   Desencadenar un bloqueo de seccomp ejecutando una operación prohibida (ej., modificar los relojes del sistema usando `clock_settime`) dentro de un contenedor estándar:
   ```bash
   docker run --rm --security-opt seccomp=/etc/docker/default-seccomp.json alpine date -s "2030-01-01 00:00:00"
   ```
   *Output Esperado:*
   ```text
   date: can't set date: Operation not permitted
   ```
   Inspeccionar el registro del sistema host para registros de violaciones de `SECCOMP` o `audit`:
   ```bash
   sudo journalctl -k | grep -i "seccomp" | tail -n 5
   ```
   *Output Esperado:*
   ```text
   audit: type=1326 audit(1722955200.124:941): auid=4294967295 uid=0 gid=0 ses=4294967295 subj=unconfined pid=18920 comm="date" exe="/bin/date" sig=31 arch=c000003e syscall=227 compat=0 ip=0x7f8a12345678 code=0x0
   ```
   *Nota de Diagnóstico:* `syscall=227` corresponde a `clock_settime` en la arquitectura x86_64.

---

### Preguntas de Verificación (Lab 4)

1. Al usar `nsenter -t <PID> -n -m`, ¿por qué las herramientas de diagnóstico instaladas en el host (como `tcpdump` o `htop`) podrían fallar o comportarse de manera diferente si se incluye `-m` (mount namespace) en comparación con usar solo `-n` (network namespace)?
2. En un escenario de nodo de Kubernetes usando `crictl`, ¿cuál es la relación funcional entre el "Pause container" (Pod Sandbox) y los contenedores de aplicación en términos de intercambio de namespaces de Linux?
3. Observa paquetes descartados entre dos contenedores conectados a la misma interfaz bridge personalizada. ¿Qué configuraciones específicas de `iptables` / `sysctl` (ej., `bridge-nf-call-iptables`) podrían hacer que las reglas del firewall del host filtren silenciosamente el tráfico de contenedores dentro del bridge?

---

<details>
<summary><strong>Clave de Respuestas Completa y Explicaciones Técnicas</strong></summary>

### Respuestas a las Preguntas del Lab 1

1. **Visibilidad de `/proc` y Propagación de Montaje:**
   - **Razón:** `/proc` es un pseudo-sistema de archivos generado dinámicamente por el kernel en función del PID namespace del proceso que lo monta. En el Paso 4, ejecutar explícitamente `mount -t proc proc /proc` sobreescribe la entrada de la tabla de montaje existente dentro del mount namespace del contenedor para que `ps aux` consulte el PID namespace aislado (donde la shell del contenedor es el PID 1).
   - **Riesgo en el Host:** Si se ejecuta `unshare --mount` sin configurar la propagación de montaje privada (`mount --make-rprivate /`), cualquier montaje o desmontaje posterior realizado dentro del nuevo mount namespace puede propagarse de regreso a la tabla de montaje root del host (`/`), interrumpiendo potencialmente los sistemas de archivos del host o filtrando montajes sensibles.

2. **Mecánica de `memory.max` vs `memory.high` en Cgroup v2:**
   - `memory.max`: Límite estricto. Si el uso de memoria alcanza este umbral y no se puede recuperar mediante la liberación del page cache, el Out-Of-Memory (OOM) killer del kernel termina inmediatamente el proceso dentro del cgroup.
   - `memory.high`: Límite suave / límite de restricción. Cuando el uso de memoria supera `memory.high`, el kernel **no** desencadena el OOM killer. En su lugar, fuerza a los procesos de ese cgroup a realizar una recuperación síncrona de páginas y frena su tiempo de ejecución, aplicando presión inversa para reducir el uso por debajo del umbral.

3. **Asignación Granular de Linux Capabilities:**
   - **Conservar:**
     - `CAP_NET_BIND_SERVICE`: Permite la vinculación a sockets privilegiados (puertos < 1024, como el puerto 80).
     - `CAP_NET_ADMIN`: Permite la configuración de red (cambios de estado de la interfaz, tablas de enrutamiento, asignación de direcciones IP).
   - **Eliminar:**
     - `CAP_SYS_MODULE`: Elimina explícitamente la capacidad de cargar/descargar módulos del kernel (`insmod`, `rmmod`).
     - `CAP_SYS_BOOT`: Elimina explícitamente la capacidad de reiniciar o detener el sistema host (syscall `reboot()`).
     - `CAP_SYS_ADMIN`: Privilegio de root excesivamente amplio que debe ser eliminado en entornos de producción seguros.

---

### Respuestas a las Preguntas del Lab 2

1. **Modelo de Seguridad de los Contenedores LXC No Privilegiados:**
   - Los contenedores no privilegiados utilizan `user_namespaces(7)`. El usuario root dentro del contenedor (UID 0) se mapea a un UID de alto rango no privilegiado en el host (ej., UID 100000) a través de `/etc/subuid`.
   - Si un atacante escapa del límite del contenedor o ejecuta código arbitrario, existe en el SO host como UID 100000, poseyendo cero privilegios sobre archivos del host propiedad de root (`/etc/shadow`, `/boot`, dispositivos de bloque de disco). En contraste, en un contenedor privilegiado, el UID 0 dentro del contenedor es el UID 0 en el sistema host.

2. **Bridges VETH vs. Interfaces MACVLAN:**
   - **VETH + Bridge (`lxcbr0`):** Los pares de ethernet virtual actúan como cables de parcheo virtuales. Un extremo permanece en el contenedor y el otro se conecta al bridge del host `lxcbr0`. El host actúa como un switch Layer-2 y un enrutador Layer-3 con NAT (enmascaramiento con `iptables`/`nftables`) para llegar a redes externas.
   - **MACVLAN:** Omite por completo el bridging del host asignando una dirección MAC única directamente a la interfaz del contenedor sobre una NIC física del host (`eth0`).
   - **Balances:** MACVLAN ofrece un mayor rendimiento y una menor sobrecarga de CPU porque evita el procesamiento de bridge y NAT. Sin embargo, por defecto, el kernel de Linux impide la comunicación directa entre el SO host y los contenedores MACVLAN en la misma interfaz física (a menos que se use el modo bridge de MACVLAN o una configuración hairpin). Además, las NICs del host deben admitir el modo promiscuo o múltiples filtros MAC en el puerto del switch de red.

---

### Respuestas a las Preguntas del Lab 3

1. **Arquitectura Desacoplada con `containerd-shim-v2`:**
   - `dockerd` delega la gestión del ciclo de vida de los contenedores a `containerd`. Al iniciar un contenedor, `containerd` invoca a `runc` para crear los namespaces y cgroups, y genera `containerd-shim-v2`.
   - `runc` inicializa la carga de trabajo y finaliza. `containerd-shim-v2` se convierte en el proceso padre independiente del payload del contenedor.
   - Debido a que `containerd-shim-v2` mantiene abiertos los descriptores de archivos de E/S Estándar (`stdin`, `stdout`, `stderr`) y los sockets PTY, `dockerd` o `containerd` pueden bloquearse, salir o sufrir actualizaciones de binarios sin enviar señales `SIGHUP` o `SIGKILL` hacia abajo en el árbol de procesos.

2. **Sobrecarga del Copy-on-Write (CoW) de Overlay2:**
   - Cuando un proceso solicita acceso de escritura a un archivo existente ubicado en una capa `LowerDir` de solo lectura, el driver VFS de `Overlay2` intercepta la llamada de apertura (`O_WRONLY` o `O_RDWR`).
   - El kernel realiza una operación CoW completa: copia todo el archivo de 2GB de `LowerDir` a `UpperDir` antes de permitir que se complete la operación de escritura.
   - **Penalización de Rendimiento:** Causa una severa latencia de E/S en disco, picos de asignación de almacenamiento y alto uso de CPU para archivos grandes. Las buenas prácticas dictan el uso de volúmenes OCI dedicados o bind mounts para archivos de bases de datos o cargas de trabajo con alta escritura para omitir `Overlay2`.

3. **Protección a través de `no-new-privileges`:**
   - Establecer `no-new-privileges:true` aplica la flag `PR_SET_NO_NEW_PRIVS` a través de `prctl()` en el proceso root del contenedor antes de `execve()`.
   - Esto evita que los procesos obtengan permisos elevados a través de binarios `SUID` o `SGID` o Linux Capabilities (ej., la ejecución de `/usr/bin/sudo` o un binario SUID personalizado malicioso dentro del rootfs del contenedor no otorgará privilegios de root en el host o contenedor).

---

### Respuestas a las Preguntas del Lab 4

1. **Impacto del Aislamiento del Mount Namespace en `nsenter`:**
   - Si se incluye `-m` (mount namespace) al ejecutar `nsenter`, la shell pasa a la tabla de montaje del sistema de archivos virtual del contenedor.
   - Si las herramientas de diagnóstico (ej., `tcpdump`, `gdb`, `strace`, `ss`) están instaladas en el SO host pero ausentes en el rootfs mínimo del contenedor (como `scratch` o `alpine`), la ejecución del comando fallará con `command not found` o le faltarán librerías dinámicas compartidas requeridas (`.so`).
   - **Mejor Práctica:** Usar `nsenter -t <PID> -n` (solo network namespace) sin `-m` para ejecutar utilidades binarias instaladas en el host contra el stack de red aislado del contenedor.

2. **Kubernetes Pause Container e Intercambio de Namespaces:**
   - El **Pause container** (Pod Sandbox) es inicializado primero por el runtime del contenedor (`cri-o` o `containerd`). Configura y mantiene abiertos los namespaces de Linux compartidos: `NET`, `IPC` y `UTSNAMESPACE`.
   - Todos los contenedores de aplicación reales dentro del mismo Pod de Kubernetes se unen exactamente a los mismos namespaces `NET` e `IPC` creados por el Pause container (`--net=container:pause_pid`).
   - En consecuencia, los contenedores dentro del mismo Pod se comunican a través de `localhost` (127.0.0.1) y comparten colas IPC mientras mantienen namespaces `PID` y `MNT` distintos.

3. **Filtrado Dentro del Bridge y Configuraciones de `sysctl`:**
   - Los parámetros de netfilter del kernel de Linux determinan si los paquetes que atraviesan un bridge Layer-2 pasan por las reglas de `iptables`/`nftables` del host.
   - Si `sysctl net.bridge.bridge-nf-call-iptables` está configurado en `1`, cualquier paquete que se mueva a través de interfaces virtuales en `docker0` o bridges personalizados se evalúa mediante las reglas del firewall de la cadena `FORWARD` del host.
   - Si la política FORWARD por defecto de `iptables` está configurada en `DROP` (común en líneas base de seguridad endurecidas) y faltan reglas `ACCEPT` explícitas para la subred del contenedor, la comunicación entre contenedores dentro del bridge se descartará silenciosamente.

---

### Referencias Oficiales y Lectura Adicional
- [Linux Kernel Manual - Namespaces(7)](https://man7.org/linux/man-pages/man7/namespaces.7.html)
- [Linux Kernel Documentation - Control Groups v2](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html)
- [LXC Official Documentation & Configuration Guide](https://linuxcontainers.org/lxc/introduction/)
- [OCI Image & Runtime Specification Standards](https://opencontainers.org/)
- [Docker Engine Storage Drivers Architecture (Overlay2)](https://docs.docker.com/storage/storagedriver/overlayfs-driver/)
- [LPIC-3 Exam 305-300 Detailed Objectives](https://www.lpi.org/our-certifications/lpic-3-305-overview/)
</details>