# LPI DevOps Tools Engineer (701-100, v1.0) — Guía de Estudio

# Tema 2.3: Infraestructura de Contenedores (Peso: 6.67)

---

## 1. Motivación y Problema Arquitectónico de Producción

### 1.1 El Cambio de Paradigma Arquitectónico: Máquinas Virtuales vs. Contenedores a Nivel de Kernel

En el diseño de infraestructura empresarial, la virtualización de hardware tradicional (Hipervisores Tipo-1/Tipo-2) impone el aislamiento emulando conjuntos completos de hardware. Cada Máquina Virtual (VM) ejecuta su propio kernel de sistema operativo independiente, controladores de hardware (drivers) y servicios del sistema. Este modelo incurre en un overhead sustancial:
- **Overhead de Memoria**: Cada VM asigna RAM dedicada para el estado del kernel, buffer caches y daemons del sistema.
- **Latencia de I/O**: Las operaciones de almacenamiento y red atraviesan múltiples capas de traducción de virtualización (por ejemplo, hypercalls, colas virtio).
- **Latencia de Inicio**: El arranque requiere secuencias completas de inicialización del SO (BIOS/UEFI, kernel init, targets de systemd), que duran de decenas de segundos a minutos.

La infraestructura de contenedores reemplaza la emulación de hardware con **virtualización a nivel de SO de kernel compartido**. Un proceso contenedorizado se ejecuta como un proceso nativo del SO programado directamente por el kernel de Linux del host, envuelto en límites estrictos de aislamiento definidos por primitivas del kernel:

```
+-----------------------------------------------------------------------------------+
|                                 USER SPACE                                        |
|  +---------------------------+  +---------------------------+                     |
|  |    Container A (App)      |  |    Container B (App)      |  ... [Workstation /   |
|  +---------------------------+  +---------------------------+      Prod Host]     |
|  | Mount | Net | PID | User  |  | Mount | Net | PID | User  |                     |
|  | Namespaces & cgroups v2   |  | Namespaces & cgroups v2   |                     |
+--+---------------------------+--+---------------------------+---------------------+
|                                 KERNEL SPACE                                      |
|  +-----------------------------------------------------------------------------+  |
|  |                         Host Linux Kernel (Shared)                          |  |
|  |  - cgroups (cpu, memory, io)    - iptables / eBPF (network filtering)     |  |
|  |  - Overlay2 VFS driver          - Seccomp / AppArmor security filters     |  |
|  +-----------------------------------------------------------------------------+  |
+-----------------------------------------------------------------------------------+
|                               PHYSICAL HARDWARE                                   |
|   [ CPU / Memory / Network Interfaces (NIC) / NVMe Storage / Hardware Security ]  |
+-----------------------------------------------------------------------------------+
```

#### Mecánica de las Primitivas del Kernel

1. **Linux Namespaces (Límites de Aislamiento)**:
   - `PID Namespace`: Aisla el espacio de IDs de procesos. Un proceso dentro de un contenedor se ve a sí mismo como `PID 1`, mientras que en el kernel del host se mapea a un PID arbitrario (por ejemplo, `PID 14209`).
   - `NET Namespace`: Proporciona stacks de red virtual aislados (interfaces `veth`, tablas de enrutamiento IP, listas de sockets, cadenas de `iptables`).
   - `MNT Namespace`: Aisla los puntos de montaje del sistema de archivos. Combinado con `pivot_root`, evita que los procesos accedan al sistema de archivos raíz del host.
   - `IPC Namespace`: Aisla la IPC de System V y las colas de mensajes POSIX, evitando exploits de memoria compartida entre contenedores.
   - `UTS Namespace`: Aisla el hostname y los nombres de dominio NIS.
   - `USER Namespace`: Mapea el `root` dentro del contenedor (UID 0) a un UID sin privilegios diferente de cero en el host (por ejemplo, UID 100000), eliminando los privilegios de root en el SO host ante una fuga del contenedor (container breakout).
   - `CGROUP Namespace`: Oculta la disposición (layout) de cgroups del host a los procesos contenedorizados.

2. **Control Groups - cgroups v1 / v2 (Contabilidad y Aplicación de Recursos)**:
   - **Memory**: Aplica límites duros (`memory.max`), límites suaves (`memory.high`) y el comportamiento del OOM-killer.
   - **CPU**: Aplica cuotas CFS (Completely Fair Scheduler). Configurar `--cpus 2.0` configura `cpu.cfs_quota_us=200000` sobre un `cpu.cfs_period_us=100000` predeterminado.
   - **blkio / io**: Limita (throttles) IOPS y BPS de lectura/escritura por dispositivo de bloques (`io.max`).

3. **Motor de Almacenamiento (Driver Overlay2 VFS)**:
   Los runtimes de contenedores aprovechan sistemas de archivos Copy-on-Write (CoW). `overlay2` combina múltiples árboles de directorios en una sola vista unificada utilizando cuatro componentes del kernel:
   - `lowerdir`: Capas de imagen de solo lectura apiladas secuencialmente.
   - `upperdir`: Capa de contenedor de lectura-escritura donde ocurren las modificaciones.
   - `merged`: Directorio unificado virtual montado como el sistema de archivos raíz del contenedor.
   - `workdir`: Directorio interno utilizado por el kernel para preparar operaciones atómicas CoW antes de confirmarlas en `upperdir`.

---

### 1.2 Arquitectura de Host de Contenedores Dedicado: Estación de Trabajo vs. Producción

Desplegar contenedores en una estación de trabajo de desarrollador local difiere fundamentalmente de configurar un host de contenedores de producción empresarial.

| Dimensión Arquitectónica | Configuración de Estación de Trabajo | Host de Producción Dedicado |
| :--- | :--- | :--- |
| **Daemon Socket** | Unix Socket sin cifrar (`/var/run/docker.sock`) accesible a través del grupo local wheel/docker. | Mutual TLS (mTLS) sobre TCP socket (`tcp://0.0.0.0:2376`) + Unix domain socket restringido. |
| **Storage Driver** | Configuración predeterminada del sistema, a menudo propensa al consumo no monitoreado de espacio en disco. | Partición de almacenamiento de bloques dedicada (NVMe/SSD) formateada explícitamente para `overlay2` (ext4 con `ftype=1` o xfs con `d_type=true`). |
| **Logging Subsystem** | Driver `json-file` predeterminado sin límites de max-size; los logs consumen el disco raíz del host (`/var/lib/docker/containers`). | Driver de logs centralizado (`journald`, `fluentd` o `syslog`) o `json-file` con rotación estricta de tamaño/archivo (`10m`, `max-file=5`). |
| **Límites de Procesos y Ulimits** | Heredados de los valores predeterminados del shell del SO de escritorio (`nofile=1024`), lo que lleva al agotamiento de FD. | Ulimits del daemon a nivel de sistema (`nofile=64535`, `nproc=4096`, `memlock=-1`). |
| **Endurecimiento del Kernel (Kernel Hardening)** | Configuración estándar de kernel de escritorio; perfil seccomp predeterminado. | Perfil Seccomp personalizado, aplicación estricta de AppArmor/SELinux, endurecimiento de red sysctl (`net.ipv4.ip_forward=1`, `net.ipv4.conf.all.rp_filter=1`). |
| **Disponibilidad del Daemon** | Detenido al suspender/apagar la máquina; los contenedores mueren al reiniciar el daemon. | `live-restore: true` habilitado en la configuración del daemon, permitiendo que los contenedores permanezcan activos durante las actualizaciones del daemon de Docker. |

---

### 1.3 Arquitectura de Aprovisionamiento de Daemons Remotos y Mecánica de Docker Machine

Aprovisionar hosts de contenedores dedicados en proveedores de nube (AWS, GCP, Azure) o hipervisores bare-metal requiere automatizar la instalación remota del daemon de Docker, la carga de módulos del kernel y la protección del endpoint de la API remota.

`docker-machine` automatiza este proceso a través de un pipeline de orquestación estructurado:

```
[ Management Workstation ]
         |
         | 1. Provision VM / SSH Keypair
         v
[ Target Cloud / Hypervisor ]  ---> Creates Machine Instance
         |
         | 2. Connect via SSH (Port 22)
         |    - Detect OS (e.g., Ubuntu/RHEL)
         |    - Install Docker Engine binaries
         |    - Write /etc/docker/daemon.json
         v
[ Remote Docker Host ]
         |
         | 3. Provision Mutual TLS (mTLS) Infrastructure:
         |    - Generate Remote Server CA, Cert & Key
         |    - Generate Local Client Cert & Key signed by CA
         |    - Configure daemon listener: tcp://0.0.0.0:2376
         v
[ Client Workstation ] <=== Secure TLS Tunnel (Port 2376) ===> [ Remote Docker Daemon ]
 (Evaluates env vars: DOCKER_HOST, DOCKER_TLS_VERIFY, DOCKER_CERT_PATH)
```

#### Modelo de Seguridad de la API Remota de Docker

Exponer un socket TCP de Docker sin autenticar (`tcp://0.0.0.0:2375`) otorga privilegios totales de root sobre la máquina host, debido a que montar directorios del sistema host (`-v /:/host`) permite la manipulación arbitraria del host.

Para prevenir la explotación remota, los hosts de producción aplican **Mutual TLS (mTLS)** en el puerto 2376:
1. **Verificación del Servidor**: El cliente verifica el certificado del servidor utilizando una Autoridad Certificadora (CA) confiable (`--tlsverify`, `--tlscacert=ca.pem`).
2. **Verificación del Cliente**: El daemon de Docker valida la identidad del cliente antes de aceptar comandos de la API REST entrantes (`--tlscert=cert.pem`, `--tlskey=key.pem`).

---

## 2. Comparaciones Técnicas y Matrices de Compromisos (Trade-Offs)

### 2.1 Runtimes de Contenedores y Motores de Aislamiento

| Característica / Métrica | Docker Engine (runc + containerd) | Kata Containers (MicroVM) | Firecracker (MicroVM) | LXC / LXD (Contenedores de Sistema) |
| :--- | :--- | :--- | :--- | :--- |
| **Límites de Aislamiento** | Shared Linux Kernel (Namespaces + cgroups) | Dedicated Linux Kernel per container inside lightweight QEMU/Cloud-Hypervisor VM | Minimalist dedicated Rust kernel via KVM | Shared Linux Kernel (OS container model) |
| **Límite de Seguridad** | Process-level (Vulnerable a exploits zero-day del kernel) | Virtualización asistida por hardware (Intel VT-x / AMD-V) | Virtualización asistida por hardware (Superficie de ataque mínima) | Process-level (Aislamiento enfocado en init del sistema) |
| **Overhead de Inicio** | ~50ms - 200ms | ~500ms - 2s | ~5ms - 10ms | ~1s - 3s |
| **Huella de Memoria** | Extremadamente bajo (~5MB - 15MB de overhead por cont.) | Moderado (~100MB - 150MB de overhead por cont.) | Muy bajo (~5MB - 10MB de overhead por microVM) | Moderado (~30MB - 50MB por contenedor) |
| **Cumplimiento OCI** | 100% OCI Compliant | 100% OCI Compliant (vía plugin CRI/containerd) | Requiere shim específico (por ejemplo, `containerd-shim-aws-firecracker`) | Estándar No-OCI |
| **Caso de Uso en Producción** | Microservicios, cargas de trabajo generales de CI/CD | Cargas de trabajo multinquilino (multi-tenant) no confiables, aplicaciones legacy que necesitan capacidades completas del kernel | Ejecución de alta densidad Serverless / Function-as-a-Service (FaaS) | Virtualización completa del SO sin overhead de hipervisor |

---

### 2.2 Storage Drivers de Docker

| Storage Driver | Requisitos Previos del Kernel | Rendimiento de Escritura (CoW) | Eficiencia de Inodos | Estado en Producción y Recomendación |
| :--- | :--- | :--- | :--- | :--- |
| **`overlay2`** | Linux Kernel >= 4.0, ext4 (con `ftype=1`) o XFS (con `d_type=true`) | Alto (Rendimiento nativo de VFS overlay del kernel) | Alta (Page cache compartida entre contenedores para las capas inferiores) | **Estándar Predeterminado de Producción**. Recomendado para todas las cargas de trabajo Linux. |
| **`btrfs`** | Respaldado por sistema de archivos Btrfs (`/var/lib/docker`) | Medio (Overhead de copy-on-write de subvolúmenes) | Alta | Soportado. Adecuado si el sistema host utiliza nativamente pools de almacenamiento Btrfs. |
| **`zfs`** | Respaldado por ZFS en Linux | Alto (Cuando la caché ARC de ZFS está afinada correctamente) | Alta | Soportado. Excelente para sistemas de almacenamiento empresarial con requisitos de deduplicación y snapshots. |
| **`devicemapper`** | Modo LVM Direct-LVM (Thin Provisioning) | Bajo (Latencia de asignación a nivel de bloques) | Baja (Las asignaciones de bloques preasignadas consumen espacio en disco) | **Obsoleto (Deprecated)** en Docker Engine 18.09; eliminado por completo en motores modernos. |

---

### 2.3 Drivers de Red de Contenedores

| Driver | Mecánica y Recorrido de Paquetes | Conectividad entre Hosts (Cross-Host) | Overhead de Rendimiento | Caso de Uso Principal en Producción |
| :--- | :--- | :--- | :--- | :--- |
| **`bridge`** | Crea el bridge virtual `docker0` en el host. Los contenedores se conectan mediante un par `veth`. Network Address Translation (NAT) a través de `iptables`. | No (Solo local al host) | Medio (Overhead de NAT para paquetes entrantes/salientes) | Aplicaciones en un solo host, desarrollo local, servicios aislados de múltiples capas (multi-tier). |
| **`host`** | Omite el aislamiento de red. El contenedor comparte directamente el namespace de red, IP y bindings de puertos del host. | No (Vinculado a la IP del host) | Cero (Throughput nativo de la red del host) | Servicios de alto rendimiento críticos en latencia (por ejemplo, balanceadores de carga bare-metal, streaming de medios en tiempo real). |
| **`macvlan`** | Asigna una dirección MAC al contenedor desde la interfaz física del host. El contenedor aparece como un dispositivo físico en la red subyacente. | Sí (Enrutamiento nativo de red L2) | Extremadamente Bajo (Binding directo a hardware/sub-interfaz) | Migración de aplicaciones legacy que requieren asignación directa de IP desde DHCP/VLAN físico de la red. |
| **`overlay`** | Crea encapsulamiento de túnel VXLAN (puerto UDP 4789) a través de nodos host utilizando un almacén clave-valor embebido o gossip de Docker Swarm. | Sí (Red de contenedores entre múltiples hosts) | Medio-Alto (Costo de CPU por encapsulamiento/desencapsulamiento) | Clusters de contenedores entre múltiples hosts, despliegues de múltiples nodos en Docker Swarm. |

---

### 2.4 Estrategias de Aprovisionamiento de Daemons Remotos y Gestión de Nodos

| Estrategia | Velocidad de Aprovisionamiento | Cumplimiento de Seguridad | Complejidad de Mantenimiento | Idoneidad para Producción |
| :--- | :--- | :--- | :--- | :--- |
| **`docker-machine`** | Rápida (~2-5 minutos por host) | Básica (Genera PKI mTLS autofirmada automáticamente) | Alta (Herramienta obsoleta upstream; requiere gestión manual del archivo de estado) | **Gestión de hosts Legacy / Standalone** (Estándar de referencia LPI 701-100). |
| **Cloud-Init + Ansible** | Media (~3-7 minutos) | Empresarial (Se integra con Vault, PKI, CA empresarial) | Baja (Gestión declarativa de la configuración) | Ideal para aprovisionamiento de hosts inmutables en IaaS (AWS EC2, OpenStack). |
| **Container-Optimized OS** | Rápida (Arranque de imagen <1 minuto) | Máxima (Sistema de archivos raíz de solo lectura, runtime con actualización automática) | Extremadamente Baja | Estándar para nodos gestionados de Kubernetes (GKE, EKS) y plataformas de contenedores modernas. |

---

## 3. Manifiestos Sintácticamente Válidos Completos y Configuraciones de Infraestructura

### 3.1 Configuración Endurecida del Daemon de Docker en Producción

Ubicación: `/etc/docker/daemon.json`

```json
{
  "storage-driver": "overlay2",
  "storage-opts": [
    "overlay2.override_kernel_check=true"
  ],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "5",
    "compress": "true"
  },
  "live-restore": true,
  "userland-proxy": false,
  "no-new-privileges": true,
  "cgroupdriver": "systemd",
  "userns-remap": "default",
  "tlsverify": true,
  "tlscacert": "/etc/docker/certs.d/ca.pem",
  "tlscert": "/etc/docker/certs.d/server-cert.pem",
  "tlskey": "/etc/docker/certs.d/server-key.pem",
  "hosts": [
    "fd://",
    "tcp://0.0.0.0:2376"
  ],
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 64535,
      "Soft": 64535
    },
    "nproc": {
      "Name": "nproc",
      "Hard": 4096,
      "Soft": 4096
    }
  },
  "metrics-addr": "0.0.0.0:9323",
  "experimental": false
}
```

---

### 3.2 Archivo de Override de Unidad de Systemd para Listeners Remotos

Al configurar `"hosts"` dentro de `/etc/docker/daemon.json`, el comando de inicio predeterminado de systemd (`-H fd://`) entra en conflicto con la configuración del archivo JSON. Para solucionar esto, cree un override de systemd.

Ubicación: `/etc/systemd/system/docker.service.d/override.conf`

```ini
[Service]
# Clear the existing ExecStart directive set by the base unit file
ExecStart=
# Redefine ExecStart without inline -H options, delegating socket configuration to daemon.json
ExecStart=/usr/bin/dockerd
# Ensure systemd limits do not constrain container execution
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
# Auto-restart daemon on crash
Restart=always
RestartSec=2s
```

---

### 3.3 Script de Generación de PKI con Mutual TLS (mTLS) de OpenSSL para Producción

Este script genera una Autoridad Certificadora (CA) interna de nivel empresarial y certificados firmados de servidor/cliente para la seguridad de la API Remota de Docker.

Ubicación: `/usr/local/bin/generate-docker-certs.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

CERT_DIR="/etc/docker/certs.d"
HOST_FQDN="node-01.production.internal"
HOST_IP="192.168.10.50"
DAYS_VALID=365

mkdir -p "${CERT_DIR}"
cd "${CERT_DIR}"

echo "=== 1. Generating CA Private Key and Certificate ==="
openssl genrsa -aes256 -out ca-key.pem -passout pass:SecretCAPassword123 4096
openssl req -new -x509 -days ${DAYS_VALID} -key ca-key.pem \
  -sha256 -out ca.pem -passin pass:SecretCAPassword123 \
  -subj "/C=US/ST=Texas/L=Austin/O=Enterprise SRE/CN=${HOST_FQDN}"

echo "=== 2. Generating Server Private Key and CSR ==="
openssl genrsa -out server-key.pem 4096
openssl req -subj "/CN=${HOST_FQDN}" -sha256 -new -key server-key.pem -out server.csr

echo "=== 3. Creating Server SAN Extension File ==="
cat <<EOF > server-ext.cnf
subjectAltName = DNS:${HOST_FQDN},IP:${HOST_IP},IP:127.0.0.1
extendedKeyUsage = serverAuth
EOF

echo "=== 4. Signing Server Certificate with CA ==="
openssl x509 -req -days ${DAYS_VALID} -sha256 -in server.csr \
  -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out server-cert.pem \
  -extfile server-ext.cnf -passin pass:SecretCAPassword123

echo "=== 5. Generating Client Private Key and CSR ==="
openssl genrsa -out client-key.pem 4096
openssl req -subj '/CN=client' -new -key client-key.pem -out client.csr

echo "=== 6. Creating Client Extension File ==="
cat <<EOF > client-ext.cnf
extendedKeyUsage = clientAuth
EOF

echo "=== 7. Signing Client Certificate with CA ==="
openssl x509 -req -days ${DAYS_VALID} -sha256 -in client.csr \
  -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out client-cert.pem \
  -extfile client-ext.cnf -passin pass:SecretCAPassword123

echo "=== 8. Securing Permissions ==="
chmod -v 0400 ca-key.pem server-key.pem client-key.pem
chmod -v 0444 ca.pem server-cert.pem client-cert.pem

rm -v server.csr client.csr server-ext.cnf client-ext.cnf
echo "=== PKI Generation Complete ==="
```

---

### 3.4 Infraestructura Avanzada de Docker Compose Múltiple Host / Producción

Ubicación: `docker-compose.production.yml`

```yaml
version: '3.8'

networks:
  frontend-net:
    driver: bridge
    driver_opts:
      com.docker.network.bridge.name: "br-frontend"
      com.docker.network.bridge.enable_icc: "false"
      com.docker.network.bridge.enable_ip_masquerade: "true"
    ipam:
      driver: default
      config:
        - subnet: 172.28.10.0/24
          gateway: 172.28.10.1

  backend-net:
    driver: bridge
    internal: true
    driver_opts:
      com.docker.network.bridge.name: "br-backend"
      com.docker.network.bridge.enable_icc: "true"
    ipam:
      driver: default
      config:
        - subnet: 172.28.20.0/24
          gateway: 172.28.20.1

volumes:
  db-data:
    driver: local
    driver_opts:
      type: "none"
      o: "bind"
      device: "/mnt/fast-nvme/postgres-data"
  redis-data:
    driver: local

services:
  reverse-proxy:
    image: nginx:1.25-alpine
    container_name: prod-nginx-proxy
    restart: always
    ports:
      - "80:80"
      - "443:443"
    networks:
      - frontend-net
    security_opt:
      - no-new-privileges:true
      - seccomp:/etc/docker/seccomp-strict.json
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
      - CHOWN
      - SETGID
      - SETUID
    resources:
      limits:
        cpus: '1.50'
        memory: 512M
      reservations:
        cpus: '0.25'
        memory: 128M
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  app-backend:
    image: node:20-alpine
    container_name: prod-api-backend
    restart: unless-stopped
    command: ["node", "server.js"]
    working_dir: /usr/src/app
    environment:
      NODE_ENV: production
      DATABASE_URL: postgresql://dbuser:SecurePass123@database:5432/appdb
    networks:
      - frontend-net
      - backend-net
    security_opt:
      - no-new-privileges:true
    read_only: true
    tmpfs:
      - /tmp:rw,noexec,nosuid,size=64m
    depends_on:
      - database
    resources:
      limits:
        cpus: '2.00'
        memory: 1024M

  database:
    image: postgres:16-alpine
    container_name: prod-postgres-db
    restart: always
    environment:
      POSTGRES_USER: dbuser
      POSTGRES_PASSWORD: SecurePass123
      POSTGRES_DB: appdb
    volumes:
      - db-data:/var/lib/postgresql/data
    networks:
      - backend-net
    resources:
      limits:
        cpus: '4.00'
        memory: 4096M
```

---

## 4. Comandos Reales de CLI y Salidas Completas de Terminal ($)

### 4.1 Aprovisionamiento de Host de Contenedores Remoto mediante `docker-machine`

Creación de un host de Docker remoto en una instancia en la nube mediante el driver genérico de SSH.

```bash
$ docker-machine create \
  --driver generic \
  --generic-ip-address 192.168.10.50 \
  --generic-ssh-user sysadmin \
  --generic-ssh-key ~/.ssh/id_rsa_production \
  --engine-opt storage-driver=overlay2 \
  --engine-opt log-driver=json-file \
  --engine-opt log-opt=max-size=10m \
  --engine-opt live-restore=true \
  prod-node-01
```

```text
Running pre-create checks...
[prod-node-01] Connecting to 192.168.10.50 via SSH...
[prod-node-01] Validating SSH connection...
Creating machine...
[prod-node-01] Provisioning with ubuntu(systemd)...
[prod-node-01] Installing Docker Engine...
[prod-node-01] Customizing Docker Engine flags...
[prod-node-01] Configuring daemon in /etc/docker/daemon.json...
[prod-node-01] Copying certs to the local machine directory...
[prod-node-01] Copying certs to the remote machine...
[prod-node-01] Setting Docker configuration on the remote daemon...
[prod-node-01] Restarting Docker daemon...
Checking connection to Docker daemon...
Machine "prod-node-01" was created successfully!
To point your Docker client to the new machine, run: eval $(docker-machine env prod-node-01)
```

---

### 4.2 Inspección del Entorno del Host Remoto y del Estado del Daemon

Inspeccionando la configuración del shell generada por `docker-machine`.

```bash
$ docker-machine env prod-node-01
```

```text
export DOCKER_TLS_VERIFY="1"
export DOCKER_HOST="tcp://192.168.10.50:2376"
export DOCKER_CERT_PATH="/home/sreuser/.docker/machine/machines/prod-node-01"
export DOCKER_MACHINE_NAME="prod-node-01"
# Run this command to configure your shell:
# eval $(docker-machine env prod-node-01)
```

Activando el entorno del motor remoto:

```bash
$ eval $(docker-machine env prod-node-01)
$ docker-machine ls
```

```text
NAME           ACTIVE   DRIVER    STATE     URL                      SWARM   DOCKER     ERRORS
prod-node-01   *        generic   Running   tcp://192.168.10.50:2376         v24.0.5    
```

---

### 4.3 Validación del Estado Profundo del Sistema del Daemon (`docker info`)

```bash
$ docker info
```

```text
Client: Docker Engine - Community
 Version:    24.0.5
 Context:    default
 Debug Mode: false

Server:
 Containers: 3
  Running: 3
  Paused: 0
  Stopped: 0
 Images: 12
 Server Version: 24.0.5
 Storage Driver: overlay2
  Backing Filesystem: extfs
  Supports d_type: true
  Using metacopy: false
 Logging Driver: json-file
 Cgroup Driver: systemd
 Cgroup Version: 2
 Plugins:
  Volume: local
  Network: bridge host ipvlan macvlan null overlay
 Swarm: inactive
 Runtimes: io.containerd.runc.v2 runc
 Default Runtime: runc
 Init Binary: docker-init
 containerd version: 3ed1639f771a82276e144c15d9601fcb47708b5e
 runc version: v1.1.8-0-g82f1b90
 init version: de40ad0
 Security Options:
  apparmor
  seccomp
   Profile: default
  cgroupns
 Kernel Version: 6.2.0-32-generic
 Operating System: Ubuntu 22.04.3 LTS
 OSType: linux
 Architecture: x86_64
 CPUs: 8
 Total Memory: 31.36GiB
 Name: prod-node-01
 ID: 7A5C:4DB3:8B12:3E9A:901C:2B11
 Docker Root Dir: /var/lib/docker
 Debug Mode: false
 Experimental: false
 Live Restore Enabled: true
```

Comprobando la utilización del disco a través de los componentes del contenedor:

```bash
$ docker system df -v
```

```text
Images space usage:

REPOSITORY          TAG       IMAGE ID       CREATED        SIZE      SHARED SIZE   UNIQUE SIZE   CONTAINERS
nginx               1.25-alpine 0f1c...        2 weeks ago    42.5MB    0B            42.5MB        1
postgres            16-alpine  3b8f...        3 weeks ago    85.2MB    0B            85.2MB        1
node                20-alpine  9e4d...        1 month ago    178.4MB   0B            178.4MB       1

Containers space usage:

CONTAINER ID   IMAGE                 COMMAND                  LOCAL VOLUMES   SIZE      CREATED        STATUS          NAMES
a8f921bc4102   nginx:1.25-alpine     "/docker-entrypoint.…"   0               1.2kB     2 hours ago    Up 2 hours      prod-nginx-proxy
c5e12890db7f   node:20-alpine        "docker-entrypoint.s…"   0               4.8MB     2 hours ago    Up 2 hours      prod-api-backend
7d4a108e68cc   postgres:16-alpine    "docker-entrypoint.s…"   1               45B       2 hours ago    Up 2 hours      prod-postgres-db

Local Volumes space usage:

VOLUME NAME                                                        LINKS     SIZE
4f8a0e9d4128f7724128c1192e10a218174e...                             1         124.8MB
```

---

### 4.4 Inspección de Primitivas del Kernel de Bajo Nivel

#### 4.4.1 Inspección de Namespaces Activos a través de `lsns`

```bash
$ sudo lsns -t net
```

```text
        NS TYPE ID NPROCS   PID USER    COMMAND
4026531992 net       1    134 root    /sbin/init
4026532450 net       1   4120 100000  nginx: master process nginx -g daemon off;
4026532512 net       1   4290 100000  node server.js
4026532590 net       1   4380 999     postgres
```

#### 4.4.2 Inspección del Límite Duro de Memoria en Cgroups v2

Consultando directamente el sistema de archivos cgroup v2 del host para `prod-api-backend` (ID de Contenedor `c5e12890db7f`):

```bash
$ sudo cat /sys/fs/cgroup/system.slice/docker-c5e12890db7f.scope/memory.max
```

```text
1073741824
```

*(Nota: `1073741824` bytes corresponden exactamente a los `1024M` configurados en el manifiesto compose).*

#### 4.4.3 Inspección de Puntos de Montaje Overlay2 del Kernel

```bash
$ mount -t overlay
```

```text
overlay on /var/lib/docker/overlay2/a38b174fd9e812.../merged type overlay (rw,relatime,lowerdir=/var/lib/docker/overlay2/l/6W7X...:/var/lib/docker/overlay2/l/3H9Z...,upperdir=/var/lib/docker/overlay2/a38b174fd9e812.../diff,workdir=/var/lib/docker/overlay2/a38b174fd9e812.../work)
```

---

### 4.5 CLI de Aprovisionamiento Avanzado de Redes y Volúmenes

Creación de una red bridge aislada con Comunicación entre Contenedores (ICC) restringida:

```bash
$ docker network create \
  --driver bridge \
  --subnet 10.200.50.0/24 \
  --gateway 10.200.50.1 \
  -o "com.docker.network.bridge.name"="br-secure-zone" \
  -o "com.docker.network.bridge.enable_icc"="false" \
  -o "com.docker.network.bridge.enable_ip_masquerade"="true" \
  secure-zone-net
```

```text
09f27d81a42b10a2489e2c69c89012a4b12591024bc981249e019284bd02194a
```

Creación de un volumen persistente de producción mapeado a un punto de montaje XFS subyacente:

```bash
$ docker volume create \
  --driver local \
  --opt type=xfs \
  --opt o=noatime,pquota \
  --opt device=/dev/sdb1 \
  prod-nvme-volume
```

```text
prod-nvme-volume
```

---

## 5. Guía de Verificación y Diagnóstico (Runbook de Producción SRE)

```
                       +-----------------------------------+
                       | CONTAINER INFRASTRUCTURE INCIDENT |
                       +-----------------------------------+
                                         |
               +-------------------------+-------------------------+
               |                                                   |
      [ Storage / Disk Issue ]                             [ Network / DNS Issue ]
               |                                                   |
               v                                                   v
 1. Check `docker system df`                         1. Test veth link: `ip link`
 2. Verify ftype: `xfs_info`                         2. Check FORWARD chain: `iptables -L -n -v`
 3. Prune dead layers: `docker system prune`        3. Inspect daemon DNS resolution
               |                                                   |
               +-------------------------+-------------------------+
                                         |
               +-------------------------+-------------------------+
               |                                                   |
      [ OOM / Throttling Issue ]                           [ Daemon / TLS Issue ]
               |                                                   |
               v                                                   v
 1. Parse kernel log: `dmesg -T | grep oom`          1. Test mTLS: `curl --cert ...`
 2. Check cgroup: `cat memory.events`                2. Check SANs: `openssl x509 -text`
 3. Verify CPU quota in `cpu.max`                    3. Inspect `journalctl -u docker`
```

---

### Escenario A: Agotamiento de Inodos / Almacenamiento en Overlay2 y Fugas de Capas Obsoletas (Stale Layers)

#### Síntomas
Los despliegues de contenedores fallan con la salida: `No space left on device`. Sin embargo, `df -h` muestra capacidad de disco disponible, pero `df -i` muestra un consumo del 100% de inodos.

#### Flujo de Trabajo de Diagnóstico

1. **Verificar la Utilización de Inodos**:
   ```bash
   $ df -i /var/lib/docker
   ```
   ```text
   Filesystem     Inodes  IUsed  IFree IUse% Mounted on
   /dev/sda1     2621440 2621440     0  100% /
   ```

2. **Localizar el Directorio con Alta Densidad de Inodos**:
   ```bash
   $ sudo du --inodes /var/lib/docker/overlay2 | sort -rh | head -n 10
   ```
   ```text
   2580192 /var/lib/docker/overlay2
   1204021 /var/lib/docker/overlay2/b49f82190.../diff
   ```

3. **Identificar Imágenes Colgantes (Dangling) y Volúmenes No Utilizados**:
   ```bash
   $ docker image ls -f "dangling=true" -q
   ```

#### Plan de Remediación

Ejecutar la limpieza atómica sin interrumpir las cargas de trabajo activas en ejecución:

```bash
# Remove stopped containers, dangling images, and unused networks
$ docker system prune --filter "until=24h" -f

# Remove dangling volumes consuming orphaned inodes
$ docker volume prune -f
```

Si se utiliza XFS como almacenamiento de respaldo, verifique que se haya especificado `d_type=true` durante el formateo:

```bash
$ xfs_info /var/lib/docker | grep ftype
```
```text
naming   =version 2              bsize=4096   ftype=1
```
*(Si `ftype=0`, el almacenamiento de respaldo debe reformatearse con `mkfs.xfs -n ftype=1 /dev/sdb1` porque `overlay2` fallará en silencio o filtrará inodos).*

---

### Escenario B: Aislamiento de Red de Contenedores, Caídas (Drops) en FORWARD de IPTables y Fallos de DNS

#### Síntomas
Los contenedores conectados a redes bridge personalizadas no pueden enrutar paquetes hacia endpoints externos o las consultas de red entre contenedores fallan con `Temporary failure in name resolution`.

#### Flujo de Trabajo de Diagnóstico

1. **Inspeccionar el Estado de Reenvío de Paquetes (Packet Forwarding) del Host**:
   ```bash
   $ sysctl net.ipv4.ip_forward
   ```
   ```text
   net.ipv4.ip_forward = 0
   ```
   *Hallazgo Diagnóstico*: El reenvío IP del kernel está deshabilitado. Docker no puede enrutar el tráfico fuera de las interfaces bridge.

2. **Inspeccionar la Cadena de Filtro FORWARD de IPTables**:
   ```bash
   $ sudo iptables -L FORWARD -n -v --line-numbers
   ```
   ```text
   Chain FORWARD (policy DROP 0 packets, 0 bytes)
   num   pkts bytes target     prot opt in     out     source               destination         
   1        0     0 DROP       all  --  *      *       0.0.0.0/0            0.0.0.0/0           
   ```
   *Hallazgo Diagnóstico*: Las reglas del firewall inyectadas por herramientas de terceros (por ejemplo, `UFW` o `firewalld`) establecen la política predeterminada de la cadena FORWARD en `DROP` sin preservar las reglas gestionadas dinámicamente por Docker.

3. **Inspeccionar el Mapeo de DNS Interno del Contenedor**:
   Ejecutar dentro del contenedor en ejecución:
   ```bash
   $ docker exec -it prod-api-backend cat /etc/resolv.conf
   ```
   ```text
   nameserver 127.0.0.11
   options ndots:0
   ```
   *Nota*: `127.0.0.11` es el listener del servidor DNS embebido de Docker. Si la red bridge personalizada tiene `enable_icc=false`, los contenedores no pueden alcanzarse entre sí por nombre de servicio a menos que estén enlazados (linked) o se permita explícitamente.

#### Plan de Remediación

1. Habilitar el reenvío de paquetes del kernel de forma persistente:
   ```bash
   $ echo "net.ipv4.ip_forward = 1" | sudo tee -a /etc/sysctl.d/99-docker.conf
   $ sudo sysctl -p /etc/sysctl.d/99-docker.conf
   ```

2. Restaurar las Reglas de IPTables de Docker:
   ```bash
   $ sudo systemctl restart docker
   ```

---

### Escenario C: Invocación del OOM-Killer del Kernel y Diagnósticos de Limitación (Throttling) de CPU

#### Síntomas
El proceso de la aplicación dentro del contenedor se termina abruptamente con el código de salida `137`.

#### Flujo de Trabajo de Diagnóstico

1. **Verificar el Contexto del Código de Salida**:
   Un código de salida de `137` indica `128 + 9 (SIGKILL)`. El kernel terminó forzadamente el proceso.

2. **Inspeccionar el Estado del Contenedor**:
   ```bash
   $ docker inspect prod-api-backend --format '{{.State.ExitCode}} | OOMKilled: {{.State.OOMKilled}}'
   ```
   ```text
   137 | OOMKilled: true
   ```

3. **Consultar el Ring Buffer del Kernel del Host (`dmesg`)**:
   ```bash
   $ sudo dmesg -T | grep -i -E 'oom[-_]killer|killed process'
   ```
   ```text
   [Fri Aug  7 04:30:12 2026] Memory cgroup out of memory: Kill process 14209 (node) score 1002 or sacrifice child
   [Fri Aug  7 04:30:12 2026] Killed process 14209 (node) total-vm:1482012kB, anon-rss:1042100kB, file-rss:12044kB, shmem-rss:0kB cgroup /system.slice/docker-c5e12890db7f.scope
   ```

4. **Diagnosticar el Throttling de CPU mediante Métricas de Cgroup**:
   ```bash
   $ sudo cat /sys/fs/cgroup/system.slice/docker-c5e12890db7f.scope/cpu.stat
   ```
   ```text
   usage_usec 489201923
   user_usec 391029301
   system_usec 98172622
   nr_periods 45000
   nr_throttled 12450
   throttled_usec 890123992
   ```
   *Análisis*: `nr_throttled` indica que el 27.6% de los períodos de ejecución fueron limitados (throttled) porque la aplicación excedió su límite de cuota de CPU de CFS.

#### Plan de Remediación

1. Ajustar el límite superior (ceiling) de memoria en `docker-compose.production.yml` para adaptarse a los requisitos de pico de heap.
2. Incrementar la asignación de cuota de CPU CFS u optimizar el bucle de eventos (event loop) de la aplicación para evitar la inanición de hilos (thread starvation) durante picos de ejecución.

---

### Escenario D: Solución de Problemas de Conexión TLS del Daemon y Expiración de Certificados mTLS

#### Síntomas
Los comandos CLI remotos dirigidos al daemon fallan:
`Could not connect to API: x509: certificate has expired or is not valid for the requested IP`.

#### Flujo de Trabajo de Diagnóstico

1. **Validar las Fechas de Expiración de los Certificados**:
   ```bash
   $ openssl x509 -in ~/.docker/machine/machines/prod-node-01/server.pem -text -noout | grep -A 2 "Validity"
   ```
   ```text
           Validity
               Not Before: Aug  5 00:00:00 2025 GMT
               Not After : Aug  5 00:00:00 2026 GMT
   ```
   *Hallazgo Diagnóstico*: El certificado expiró hace 2 días.

2. **Verificar Nombres Alternativos del Sujeto (SANs)**:
   ```bash
   $ openssl x509 -in ~/.docker/machine/machines/prod-node-01/server.pem -text -noout | grep -A 1 "Subject Alternative Name"
   ```
   ```text
               X509v3 Subject Alternative Name: 
                   DNS:node-01.production.internal, IP:192.168.10.50
   ```
   *Hallazgo Diagnóstico*: Acceder al host a través de una nueva IP (por ejemplo, `192.168.10.60`) falla porque la IP no está presente en el bloque de extensión SAN.

#### Plan de Remediación

Regenerar los certificados dirigidos al host utilizando `docker-machine`:

```bash
$ docker-machine regenerate-certs -f prod-node-01
```

```text
Regenerating TLS certificates...
[prod-node-01] Copying certs to the local machine directory...
[prod-node-01] Copying certs to the remote machine...
[prod-node-01] Setting Docker configuration on the remote daemon...
[prod-node-01] Restarting Docker daemon...
Successfully regenerated certificates!
```

---

## 6. Referencias

- [LPI DevOps Tools Engineer Exam Objectives](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
- [Docker Engine Production Documentation](https://docs.docker.com/engine/)
- [Protect the Docker Daemon Socket with mTLS](https://docs.docker.com/engine/security/protect-access/)
- [Understand the Overlay2 Storage Driver](https://docs.docker.com/storage/storagedriver/overlayfs-driver/)
- [Docker Engine daemon.json Configuration Reference](https://docs.docker.com/engine/reference/commandline/dockerd/#daemon-configuration-file)
- [Linux Kernel Control Groups v2 Documentation](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html)
- [Open Container Initiative (OCI) Runtime Specification](https://github.com/opencontainers/runtime-spec)