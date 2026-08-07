# LPI Security Essentials (020-100) — Tema 3.1: Seguridad de Nodos, Dispositivos y Almacenamiento

## 1. Motivación y Problema Arquitectónico de Producción

En la ingeniería de plataformas cloud-native y en las operaciones de infraestructura moderna, la seguridad de nodos, dispositivos y almacenamiento constituye la línea base fundamental del límite de confianza operativo. Un entorno host inseguro invalida todas las abstracciones de capas superiores, incluidos los container runtimes, service meshes y proveedores de identidad. 

La infraestructura host de producción se enfrenta a vectores de amenaza multidimensionales que operan en los dominios físico, del kernel, de almacenamiento de bloques (block-storage) y del user-space:

1. **Manipulación Física y de Firmware (Physical & Firmware Tampering):** El acceso físico no autorizado o la vulneración del entorno Unified Extensible Firmware Interface (UEFI) pueden omitir la autenticación del sistema operativo, sustituir el kernel del SO o extraer secretos sensibles directamente de la memoria no volátil a través de ataques Cold Boot o exploits de Direct Memory Access (DMA).
2. **Exposición y Robo de Datos en Reposo (Data-at-Rest Exposure & Theft):** Los volúmenes de almacenamiento (NVMe, SSD, dispositivos de bloques SAN, discos persistentes en la nube) fuera de servicio, desinfectados de manera inadecuada, robados o accedidos fuera de banda exponen bloques no cifrados en bruto que contienen material criptográfico, secretos, estado de la aplicación y registros sensibles a regulaciones de cumplimiento.
3. **Escalación de Privilegios en Aplicaciones Host y Escape de Contenedor (Host Application Privilege Escalation & Container Escape):** Los procesos del user-space comprometidos que se ejecutan con capacidades elevadas del kernel o módulos de seguridad de Linux no confinados (AppArmor/SELinux) pueden realizar secuestros de llamadas al sistema (system-call hijacking), modificar parámetros del kernel del host (`/proc/sys`) o leer nodos de dispositivos sensibles (`/dev/mem`, `/dev/kmem`).
4. **Persistencia de Malware y Violación de Integridad de Archivos (Malware Persistence & File Integrity Violation):** Los binarios maliciosos (rootkits, troyanos, ransomware) que establecen persistencia en rutas no volátiles del sistema (`/usr/bin`, `/lib64`, módulos del kernel) corrompen los contextos de ejecución del nodo y socavan el aislamiento de las cargas de trabajo (workloads).
5. **Catástrofes de Disponibilidad e Integridad de Datos (Data Availability & Integrity Catastrophes):** Los fallos en las controladoras de almacenamiento, la corrupción silenciosa de datos (silent bit rot), la replicación split-brain o la ejecución no coordinada de snapshots causan pérdidas catastróficas de datos, Objetivos de Tiempo de Recuperación (RTO) inaceptables y Objetivos de Punto de Recuperación (RPO) elevados.

### Blueprint de Arquitectura de Host y Almacenamiento Zero Trust

```
+-----------------------------------------------------------------------------------+
|                              HARDWARE ROOT OF TRUST                               |
|       [ TPM 2.0 ] ---> [ UEFI Secure Boot ] ---> [ Measured Boot (MOK/PCR) ]      |
+-----------------------------------------------------------------------------------+
                                         |
                                         v
+-----------------------------------------------------------------------------------+
|                             STORAGE SECURITY LAYER                                |
|   [ dm-crypt / LUKS2 ] <--- Clevis / systemd-cryptenroll (Bound to TPM PCR 7/11)  |
|   [ dm-verity / Read-Only Root FS ] <--- Cryptographic Block Integrity Check      |
+-----------------------------------------------------------------------------------+
                                         |
                                         v
+-----------------------------------------------------------------------------------+
|                              KERNEL & ISOLATION LAYER                             |
|  [ Linux Security Modules: AppArmor / SELinux ] <---> [ Seccomp Syscall Filters ] |
|  [ Namespaces & cgroups v2 ] <---> [ Hardware-Enforced Control Flow (CET/SMEP) ]  |
+-----------------------------------------------------------------------------------+
                                         |
                                         v
+-----------------------------------------------------------------------------------+
|                           WORKLOAD & DATA AVAILABILITY                            |
|  [ Immutable Container Workloads ] <---> [ Velero / ZFS Offsite Air-Gapped Backup]|
+-----------------------------------------------------------------------------------+
```

Diseñar nodos de producción requiere aplicar una cadena de confianza continua: las mediciones de hardware (TPM 2.0) validan el estado de arranque antes de liberar las claves de cifrado para el almacenamiento de bloques (LUKS2/dm-crypt), seguido de la aplicación de políticas estrictas de llamadas al sistema y acceso a archivos (AppArmor/Seccomp) en las aplicaciones, respaldado por copias de seguridad remotas (offsite) automatizadas y firmadas criptográficamente.

---

## 2. Tablas de Comparación Técnica y Análisis de Compensaciones (Trade-offs)

### Tabla 3.1.1: Mecanismos de Cifrado de Almacenamiento de Bloques vs. Archivos vs. Nube

| Métrica / Dimensión | LUKS2 / dm-crypt (Full Disk Encryption) | fscrypt (Linux Kernel File-Based Encryption) | Cloud Managed Storage (AWS EBS / GCP Persistent Disk) | dm-verity (Kernel Block Integrity) |
| :--- | :--- | :--- | :--- | :--- |
| **Capa de Operación** | Capa de dispositivo de bloques (`/dev/mapper`) | Capa de sistema de archivos (ext4, f2fs) | Capa de Hipervisor / Storage Fabric | Capa de dispositivo de bloques (Verificación de solo lectura) |
| **Granularidad** | Partición / volumen completo | Por directorio / Por archivo | Volumen virtual completo | Partición / imagen completa |
| **Gestión de Claves** | Master Key protegida mediante Key Slots (TPM2, Passphrase, Keyfile) | Claves criptográficas por usuario / por directorio vía `keyctl` | Cloud KMS (Envelope Encryption, rotación automática) | Firma de raíz de árbol Hash verificada contra la clave pública del kernel |
| **Impacto en el Rendimiento** | Bajo overhead de CPU (aceleración por hardware AES-NI ~2-5%) | Extremadamente bajo, aplica solo a rutas específicas | Cero overhead de CPU en el host (delegado al hipervisor) | Overhead de lectura moderado debido al hashing de árbol Merkle (~5-10%) |
| **Resistencia a Cold Boot** | Alta (si se combina con vinculación TPM 2.0 PCR) | Media (claves almacenadas en caché en el kernel keyring durante la sesión de usuario) | Alta contra el robo físico de discos; Baja contra un hipervisor comprometido | N/A (Se centra en la integridad, no en la confidencialidad) |
| **Protección de Metadatos** | Protege nombres de archivos, estructuras de directorios, tamaños de archivos, marcas de tiempo | Protege contenido y nombres de archivos; la estructura del directorio permanece legible | Protección completa a nivel de bloque | Protección de integridad completa del diseño de bloques |
| **Caso de Uso en Producción** | Hosts Bare-metal, edge nodes, unidades NVMe locales | Directorios home multitenant, volúmenes efímeros de contenedores | VMs cloud-native, worker nodes de K8s administrados | Imágenes de SO inmutables (Talos Linux, Android, ChromeOS) |

---

### Tabla 3.1.2: Paradigmas de Aislamiento y Sandboxing de Aplicaciones Host

| Paradigma | Mecanismos de Control | Overhead de Rendimiento | Superficie de Ataque de Syscalls | Fuerza de Aislamiento | Complejidad de Implementación |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Contenedores Estándar de Linux** | Namespaces (`mnt`, `pid`, `net`) + cgroups v2 | Casi Nulo (< 1%) | Kernel compartido completo (~350+ syscalls expuestas) | Baja a Media | Baja (Predeterminado en Docker, containerd) |
| **Contenedores Fortalecidos (LSM + Seccomp)** | Namespaces + cgroups v2 + AppArmor/SELinux + Seccomp-BPF | Muy Bajo (< 2%) | Kernel filtrado (~80-120 syscalls permitidas) | Alta | Media a Alta (Requiere creación de políticas) |
| **User-Space Kernel Sandbox (gVisor)** | Interceptor Sentry que traduce syscalls al user-space de Go | Moderado a Alto (10-30% overhead de E/S) | Restringido a ~70 syscalls del host sanitizadas | Muy Alta | Media |
| **Aislamiento MicroVM (Firecracker / KVM)** | Hipervisor KVM + VMM mínimo | Bajo a Moderado (5-15% de costo en memoria/E-S) | Instancia de Kernel Virtualizada Aislada | Máxima (Virtualización asistida por hardware) | Alta |

---

### Tabla 3.1.3: Arquitecturas de Disponibilidad de Almacenamiento y Backup

| Arquitectura | RTO (Recovery Time Objective) | RPO (Recovery Point Objective) | Resiliencia al Radio de Impacto (Blast Radius) | Overhead de Almacenamiento | Protección Contra Ransomware |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **RAID 10 (Espejos en Bandas)** | Segundos (Failover transparente automático) | Cero (Espejo de bloques sincrónico) | Fallo de un solo disco dentro del par en espejo | 100% (Requiere 2x la capacidad bruta) | Ninguna (Las eliminaciones se reflejan al instante) |
| **Snapshots Locales Copy-on-Write en ZFS / Btrfs** | Minutos (Rollbacks locales instantáneos) | Minutos a Horas | Protege contra la corrupción de software local | Bajo (Basado en punteros, almacenamiento delta) | Baja (Los snapshots locales pueden ser eliminados por un usuario root comprometido) |
| **Replicación Asíncrona a Nivel de Bloque (DRBD)** | Minutos (Failover manual/automatizado) | Segundos a Minutos | Protege contra la pérdida total del host/chasis | 100% (Requiere capacidad remota en el destino) | Baja a Media (Replica las corrupciones rápidamente) |
| **Backups Air-Gapped en Object Storage (Velero / Restic)** | Horas a Días (Requiere reaprovisionamiento de nodos) | Horas (Intervalos de snapshots programados) | Pérdida completa de nodo, centro de datos y región | Moderado (Deduplicado, comprimido) | Máxima (Aplicada mediante Object Lock / Write Once Read Many) |

---

## 3. Manifiestos y Configuraciones Completas de Infraestructura de Producción

### 3.1 Aprovisionamiento Automatizado de Volúmenes LUKS2 Vinculados a TPM2 (`systemd-cryptsetup` y Clevis)

Los siguientes archivos de manifiesto y configuración establecen un volumen de almacenamiento cifrado y atestiguado por hardware, montado en `/var/lib/containerd` utilizando PCR de TPM 2.0 (PCR 7 para el estado de Secure Boot, PCR 11 para la integridad de la imagen de kernel unificada).

#### Archivo 1: `/etc/crypttab`
```etc
# /etc/crypttab: Production LUKS2 Volume Configuration
# Mapping Name         UUID                                     Keyfile Path                             Cryptsetup Options
var-lib-containerd     UUID=c49a3182-8d76-4a41-b0e6-123456789abc none                                     tpm2-device=auto,tpm2-pcrs=7+11,cipher=aes-xts-plain64,key-size=512,hash=sha512,discard
```

#### Archivo 2: `/etc/systemd/system/var-lib-containerd.mount`
```ini
[Unit]
Description=Mount Encrypted Production Containerd Storage Directory
Documentation=https://github.com/containerd/containerd
After=systemd-cryptsetup@var-lib-containerd.service
BindsTo=systemd-cryptsetup@var-lib-containerd.service

[Mount]
What=/dev/mapper/var-lib-containerd
Where=/var/lib/containerd
Type=ext4
Options=defaults,noatime,nodev,nosuid,errors=remount-ro

[Install]
WantedBy=multi-user.target
```

#### Archivo 3: Script de Automatización de Aprovisionamiento y Cifrado de Hardware (`/usr/local/bin/provision-secure-storage.sh`)
```bash
#!/usr/bin/env bash
set -euo pipefail

TARGET_DEVICE="/dev/nvme1n1"
MAPPER_NAME="var-lib-containerd"
MOUNT_POINT="/var/lib/containerd"
KEY_FILE="/etc/keys/luks-recovery.key"

echo "=== [1/5] Creating Secure Recovery Key Directory ==="
mkdir -p -m 0700 /etc/keys
dd if=/dev/urandom of="${KEY_FILE}" bs=64 count=1 status=none
chmod 0400 "${KEY_FILE}"

echo "=== [2/5] Formatting LUKS2 Volume on ${TARGET_DEVICE} ==="
cryptsetup luksFormat \
    --type luks2 \
    --cipher aes-xts-plain64 \
    --key-size 512 \
    --hash sha512 \
    --pbkdf argon2id \
    --use-urandom \
    --label CONTAINER_DATA \
    --batch-mode \
    "${TARGET_DEVICE}" \
    "${KEY_FILE}"

echo "=== [3/5] Binding LUKS2 Key Slot to TPM 2.0 (PCR 7 + 11) ==="
systemd-cryptenroll \
    --tpm2-device=auto \
    --tpm2-pcrs=7+11 \
    --tpm2-with-pin=no \
    "${TARGET_DEVICE}"

echo "=== [4/5] Opening Encrypted Mapping ==="
cryptsetup open "${TARGET_DEVICE}" "${MAPPER_NAME}" --key-file "${KEY_FILE}"

echo "=== [5/5] Creating Filesystem and Mounting ==="
mkfs.ext4 -F -E lazy_itable_init=0,lazy_journal_init=0 -L containerd-data "/dev/mapper/${MAPPER_NAME}"
mkdir -p "${MOUNT_POINT}"
mount -o defaults,noatime,nodev,nosuid "/dev/mapper/${MAPPER_NAME}" "${MOUNT_POINT}"

echo "SUCCESS: Hardware-bound encrypted volume provisioned and mounted."
```

---

### 3.2 Manifiestos de Seguridad de Aislamiento de Aplicaciones de Producción

Para aislar las aplicaciones host y los container runtimes, combinamos perfiles de AppArmor, filtrado estricto de syscalls con Seccomp y Pod Security Standards de Kubernetes (perfil `Restricted`).

#### Archivo 1: Perfil de AppArmor para el Host (`/etc/apparmor.d/usr.bin.production-workload`)
```apparmor
#include <tunables/global>

profile production-workload /usr/bin/production-workload flags=(attach_disconnected,enforce) {
  #include <abstractions/base>
  #include <abstractions/nameservice>

  # Network Restrictions: Allow outbound TCP socket creation only
  network inet stream,
  network inet6 stream,
  deny network raw,
  deny network dgram,

  # Capabilities Restrictions: Drop all dangerous kernel capabilities
  deny capability sys_admin,
  deny capability sys_ptrace,
  deny capability sys_module,
  deny capability sys_rawio,
  deny capability dac_override,
  deny capability setuid,
  deny capability setgid,

  # File System Access Rules (Explicit White-listing)
  /usr/bin/production-workload mr,
  /etc/ssl/certs/** r,
  /etc/hosts r,
  /etc/resolv.conf r,
  /var/log/production-workload/*.log w,
  /tmp/ rw,
  /tmp/** rw,

  # Explicit Denials for Host Isolation
  deny /proc/sys/** w,
  deny /sys/** w,
  deny /etc/shadow* rw,
  deny /etc/passwd* w,
  deny /root/** rw,
  deny /dev/sd* rw,
  deny /dev/nvme* rw,
}
```

#### Archivo 2: Perfil de Seccomp para Producción (`/var/lib/kubelet/seccomp/profiles/strict-microservice.json`)
```json
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "architectures": [
    "SCMP_ARCH_X86_64",
    "SCMP_ARCH_AARCH64"
  ],
  "syscalls": [
    {
      "names": [
        "accept4",
        "access",
        "arch_prctl",
        "bind",
        "brk",
        "clock_gettime",
        "clone3",
        "close",
        "connect",
        "epoll_create1",
        "epoll_ctl",
        "epoll_pwait",
        "execve",
        "exit",
        "exit_group",
        "fcntl",
        "fstat",
        "futex",
        "getdents64",
        "getpid",
        "getrandom",
        "getsockopt",
        "listen",
        "lseek",
        "madvise",
        "mmap",
        "mprotect",
        "munmap",
        "newfstatat",
        "pipe2",
        "poll",
        "read",
        "readlink",
        "recvfrom",
        "rseq",
        "rt_sigaction",
        "rt_sigprocmask",
        "rt_sigreturn",
        "sched_yield",
        "sendto",
        "set_robust_list",
        "setsockopt",
        "socket",
        "write",
        "writev"
      ],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
```

#### Archivo 3: Manifiesto de Seguridad de Cargas de Trabajo (Workloads) de Kubernetes (`hardened-workload.yaml`)
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: secure-api-gateway
  namespace: production
  labels:
    app.kubernetes.io/name: secure-api-gateway
    security.cncf.io/tier: restricted
spec:
  replicas: 3
  selector:
    matchLabels:
      app: secure-api-gateway
  template:
    metadata:
      labels:
        app: secure-api-gateway
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: Localhost
          localhostProfile: profiles/strict-microservice.json
      containers:
        - name: gateway
          image: registry.production.internal/gateway:v2.4.1
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            capabilities:
              drop:
                - ALL
          resources:
            limits:
              cpu: "1"
              memory: "512Mi"
            requests:
              cpu: "250m"
              memory: "128Mi"
          volumeMounts:
            - name: tmp-volume
              mountPath: /tmp
            - name: log-volume
              mountPath: /var/log/gateway
      volumes:
        - name: tmp-volume
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
        - name: log-volume
          emptyDir:
            sizeLimit: 128Mi
```

---

### 3.3 Manifiestos de Disponibilidad de Datos y Backup Automatizado (Velero y Motor ZFS)

#### Archivo 1: Manifiesto de BackupStorageLocation de Velero (`velero-bsl-s3-immutable.yaml`)
```yaml
apiVersion: velero.io/v1
kind: BackupStorageLocation
metadata:
  name: aws-s3-airgapped-immutable
  namespace: velero
spec:
  provider: aws
  objectStorage:
    bucket: prod-k8s-backups-immutable-us-east-1
    prefix: cluster-alpha
  config:
    region: us-east-1
    s3ForcePathStyle: "false"
    checksumAlgorithm: "SHA256"
  credential:
    name: cloud-credentials
    key: cloud
  accessMode: ReadWrite
  backupSyncPeriod: 30m0s
```

#### Archivo 2: Recurso Personalizado Schedule de Velero (`velero-schedule-stateful.yaml`)
```yaml
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: stateful-workloads-hourly
  namespace: velero
spec:
  schedule: "0 * * * *"
  template:
    ttl: 720h0m0s
    includedNamespaces:
      - production-databases
      - stateful-services
    includedResources:
      - PersistentVolumeClaim
      - PersistentVolume
      - StatefulSet
      - Secret
      - ConfigMap
    storageLocation: aws-s3-airgapped-immutable
    snapshotVolumes: true
    defaultVolumesToFsBackup: false
    hooks:
      resources:
        - name: postgresql-quiesce
          includedNamespaces:
            - production-databases
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: postgresql
          pre:
            - exec:
                container: postgresql
                command:
                  - /bin/sh
                  - -c
                  - "psql -U postgres -c 'SELECT pg_backup_start(\"velero-snapshot\", true);'"
                onError: Fail
          post:
            - exec:
                container: postgresql
                command:
                  - /bin/sh
                  - -c
                  - "psql -U postgres -c 'SELECT pg_backup_stop();'"
                onError: Log
```

#### Archivo 3: Daemon de Replicación Remota (Offsite) y Snapshots de ZFS Automatizados (`/usr/local/bin/zfs-backup-daemon.sh`)
```bash
#!/usr/bin/env bash
set -euo pipefail

POOL_NAME="tank/production-data"
REMOTE_BACKUP_SERVER="backup-node01.infra.internal"
REMOTE_POOL="backup_tank/nodes/node01"
TIMESTAMP=$(date -u +"%Y%m%d_%H%M%S")
SNAPSHOT_NAME="${POOL_NAME}@auto_${TIMESTAMP}"

echo "=== [1/3] Creating Local Atomic ZFS Snapshot: ${SNAPSHOT_NAME} ==="
zfs snapshot "${SNAPSHOT_NAME}"

echo "=== [2/3] Streaming Snapshot to Remote Air-Gapped Backup Node ==="
LATEST_COMMON_SNAP=$(zfs list -t snapshot -o name -H -s creation | grep "${POOL_NAME}@" | tail -n 2 | head -n 1 || true)

if [ -n "${LATEST_COMMON_SNAP}" ]; then
    echo "Performing Incremental Replication from ${LATEST_COMMON_SNAP} to ${SNAPSHOT_NAME}..."
    zfs send -i "${LATEST_COMMON_SNAP}" "${SNAPSHOT_NAME}" | ssh -i /etc/keys/backup_ed25519 "root@${REMOTE_BACKUP_SERVER}" "zfs recv -F ${REMOTE_POOL}"
else
    echo "Performing Full Initial Replication of ${SNAPSHOT_NAME}..."
    zfs send "${SNAPSHOT_NAME}" | ssh -i /etc/keys/backup_ed25519 "root@${REMOTE_BACKUP_SERVER}" "zfs recv -F ${REMOTE_POOL}"
fi

echo "=== [3/3] Enforcing Retention Policy (Pruning Snapshots > 30 Days) ==="
zfs list -t snapshot -o name,creation -H | grep "${POOL_NAME}@auto_" | while read -r SNAP CREATED; do
    SNAP_EPOCH=$(date -d "${CREATED}" +%s 2>/dev/null || stat -c %Y "/dev/zvol/${SNAP}" 2>/dev/null || echo 0)
    NOW_EPOCH=$(date +%s)
    AGE_DAYS=$(( (NOW_EPOCH - SNAP_EPOCH) / 86400 ))
    if [ "${AGE_DAYS}" -gt 30 ]; then
        echo "Pruning expired snapshot: ${SNAP} (Age: ${AGE_DAYS} days)"
        zfs destroy "${SNAP}"
    fi
done

echo "SUCCESS: ZFS availability pipeline execution completed."
```

---

## 4. Comandos Reales de CLI y Salidas de Terminal ($)

### 4.1 Auditoría de UEFI Secure Boot, Estado de PCR de TPM 2.0 y Estado de Cifrado LUKS

```bash
$ bootctl status
```
```text
System:
     Firmware: UEFI 2.70 (Lenovo 1.45)
  Firmware Arch: x86-64
    Secure Boot: enabled (user-mode)
   Current Boot: 0001
    Boot Loader: systemd-boot 255.4-1-arch

Kernel:
    Machine ID: e9f38a104b9c467fa1289123456789ab
       Systemd: systemd 255 (255.4-1-arch)

Current Boot Loader Entry:
          title: Linux Production Kernel (Unified Kernel Image)
            id: linux-uki-production.conf
         source: /EFI/Linux/linux-uki-production.efi
```

```bash
$ tpm2_pcrread sha256:7,11
```
```text
sha256:
  7 : 0xB4D98C4E78120A9C1283F89A0123456789ABCDEF0123456789ABCDEF01234567
  11: 0x7E3A91280B4C129A847120398127391827391827391827391827391827391827
```

```bash
$ cryptsetup status var-lib-containerd
```
```text
/dev/mapper/var-lib-containerd is active and is in use.
  type:    LUKS2
  cipher:  aes-xts-plain64
  keysize: 512 bits
  key location: keyring
  device:  /dev/nvme1n1
  sector size:  512 bytes
  offset:  32768 sectors
  size:    1875350000 sectors
  mode:    read/write
  flags:   discards 
```

```bash
$ cryptsetup luksDump /dev/nvme1n1
```
```text
LUKS header information
Version:        2
Epoch:          3
Metadata area:  16384 bytes
Keyslots:
  0: luks2
	Key:        512 bits
	Priority:   normal
	Cipher:     aes-xts-plain64
	PBKDF:      argon2id
	Time cost:  4
	Memory:     1048576
	CPUs:       4
  1: systemd-tpm2
	Key:        512 bits
	Priority:   normal
	TPM2 PCRs:  7,11
	TPM2 Primary Policy: abc123def4567890...
Data area:
  offset: 16777216 bytes
  encryption: aes-xts-plain64
```

---

### 4.2 Verificación del Aislamiento de Aplicaciones (Motor AppArmor y Seccomp)

```bash
$ aa-status
```
```text
apparmor module is loaded.
42 profiles are loaded.
38 profiles are in enforce mode.
   /usr/bin/production-workload
   /usr/sbin/named
   /usr/sbin/dhcpd
   cri-containerd-default
4 profiles are in complain mode.
   /usr/bin/legacy-telemetry
0 processes have profiles defined.
3 processes are in enforce mode.
   /usr/bin/production-workload (14209)
   /usr/bin/production-workload (14210)
   /usr/bin/production-workload (14211)
```

```bash
$ journalctl -k --grep="audit" --no-pager -n 5
```
```text
Aug 07 01:15:22 node-01 audit[14209]: AVC apparmor="DENIED" operation="open" profile="/usr/bin/production-workload" name="/etc/shadow" pid=14209 comm="worker" requested_mask="r" denied_mask="r" fsuid=10001 ouid=0
Aug 07 01:15:23 node-01 audit[14209]: SECCOMP auid=4294967295 uid=10001 gid=10001 ses=4294967295 pid=14209 comm="worker" exe="/usr/bin/production-workload" sig=31 arch=c000003e syscall=165 compat=0 ip=0x7f9a8123b41a code=0x0
```

---

### 4.3 Verificación de Disponibilidad de Almacenamiento, Estado de Salud de ZFS y Estado de Backup de Velero

```bash
$ zpool status tank
```
```text
  pool: tank
 state: ONLINE
  scan: scrub repaired 0B in 01:24:12 with 0 errors on Thu Aug  6 04:00:00 2026
config:

	NAME                        STATE     READ WRITE CKSUM
	tank                        ONLINE       0     0     0
	  mirror-0                  ONLINE       0     0     0
	    nvme0n1p2               ONLINE       0     0     0
	    nvme1n1p2               ONLINE       0     0     0
	  mirror-1                  ONLINE       0     0     0
	    nvme2n1p2               ONLINE       0     0     0
	    nvme3n1p2               ONLINE       0     0     0

errors: No known data errors
```

```bash
$ velero backup get
```
```text
NAME                                STATUS      ERRORS   WARNINGS   CREATED                         EXPIRES   STORAGE LOCATION             SELECTOR
stateful-workloads-hourly-20260807010000   Completed   0        0          2026-08-07 01:00:00 -0400 EDT   29d       aws-s3-airgapped-immutable   <none>
stateful-workloads-hourly-20260807000000   Completed   0        0          2026-08-07 00:00:00 -0400 EDT   29d       aws-s3-airgapped-immutable   <none>
```

```bash
$ velero backup describe stateful-workloads-hourly-20260807010000
```
```text
Name:         stateful-workloads-hourly-20260807010000
Namespace:    velero
Labels:       velero.io/schedule-name=stateful-workloads-hourly
Annotations:  velero.io/resource-timeout=10m0s

Phase:  Completed

Namespaces:
  Included:  production-databases, stateful-services
  Excluded:  <none>

Resources:
  Included:  PersistentVolumeClaim, PersistentVolume, StatefulSet, Secret, ConfigMap
  Excluded:  <none>

Storage Location:  aws-s3-airgapped-immutable

Velero-Native Snapshots:  Enabled

Hooks:
  Exec:
    Number of targeted pods: 2

Volume Snapshots:
  PersistentVolumeClaim: production-databases/data-postgresql-0
    Snapshot ID:        snap-0a1b2c3d4e5f67890
    Type:               aws-ebs
    Availability Zone:  us-east-1a
    IOPS:               3000
```

---

## 5. Guía de Verificación y Diagnóstico de Fallos

```
+-----------------------------------------------------------------------------------+
|                        PRODUCTION TROUBLESHOOTING TREE                            |
+-----------------------------------------------------------------------------------+
                                         |
                       [ Event Triggered / Failure State ]
                                         |
                +------------------------+------------------------+
                |                                                 |
                v                                                 v
   [ Storage / Boot Failure ]                       [ Workload Execution Failure ]
                |                                                 |
   +------------+------------+                       +------------+------------+
   |                         |                       |                         |
   v                         v                       v                         v
[LUKS Unlock Fails]    [ZFS / Array Fault]    [AppArmor Denial]        [Seccomp SIGSYS]
   |                         |                       |                         |
   v                         v                       v                         v
Check TPM PCR 7/11    Run `zpool status`     Inspect `dmesg`          Parse `audit.log`
Mismatches via MOK    Replace Faulty Disk    Identify AVC Rule        Find Syscall ID
Update `cryptenroll`  Trigger `zpool replace` Append Path Rule         Update Seccomp List
```

### Escenario A: Fallo en el Desbloqueo de Arranque de LUKS2 debido a Incoincidencia de PCR en TPM

#### Causa Raíz
Una actualización de firmware, la carga de un controlador EFI o la actualización de un certificado de Secure Boot modificaron el estado de hash del PCR 7 (estado de Secure Boot) o del PCR 0 (System Firmware). Como resultado, el secreto sellado del TPM 2.0 se niega a desencriptar (unseal) la clave del volumen LUKS2.

#### Flujo de Trabajo Diagnóstico
1. Reiniciar el host en el Shell de Recuperación de Emergencia (Emergency Recovery Shell) o Live OS.
2. Verificar el estado físico del TPM y medir el estado del PCR:
   ```bash
   tpm2_pcrread sha256:7,11
   ```
3. Intentar desencriptar (unseal) manualmente o desempaquetar (unwrap) usando la frase de contraseña (passphrase) o archivo de clave (keyfile) de recuperación:
   ```bash
   cryptsetup open /dev/nvme1n1 var-lib-containerd --key-file /etc/keys/luks-recovery.key
   ```
4. Volver a vincular el slot de clave del TPM 2.0 al estado de PCR recién actualizado:
   ```bash
   # Remove old TPM2 slot (Slot 1)
   systemd-cryptenroll --tpm2-device=list /dev/nvme1n1
   cryptsetup luksKillSlot /dev/nvme1n1 1

   # Re-enroll with current PCR policy
   systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7+11 /dev/nvme1n1
   ```

---

### Escenario B: Caída de Aplicación Host Causada por Violación de Seccomp/AppArmor

#### Causa Raíz
Una versión recién desplegada de un binario o imagen de contenedor invocó una llamada al sistema no incluida en la lista blanca (por ejemplo, `clone3`, `epoll_pwait2`) o intentó leer una ruta restringida (`/sys/devices`), lo que resultó en la terminación por señal del kernel (`SIGSYS` código 31).

#### Flujo de Trabajo Diagnóstico
1. Inspeccionar el kernel ring buffer en busca de violaciones de Seccomp:
   ```bash
   dmesg -T | grep -i "seccomp"
   ```
   *Ejemplo de Salida:*
   `[Fri Aug 7 01:20:11 2026] audit: type=1326 audit(1786166411.102:44): auid=4294967295 uid=10001 gid=10001 ses=4294967295 pid=18902 comm="gateway" exe="/usr/bin/gateway" sig=31 arch=c000003e syscall=435 compat=0 ip=0x7f920`

2. Traducir el código de arquitectura (`c000003e` = x86_64) y el número de llamada al sistema (`435`) a un formato legible por humanos usando `ausyscall`:
   ```bash
   ausyscall x86_64 435
   ```
   *Salida:*
   `clone3`

3. Modificar `/var/lib/kubelet/seccomp/profiles/strict-microservice.json` para incluir `clone3` dentro del arreglo permitido y volver a aplicar el manifiesto.

---

### Escenario C: Fallo de Backup de Snapshot de Volumen Persistente (Timeout de Quiesce en Velero)

#### Causa Raíz
Los hooks de quiescencia de la base de datos previos al snapshot (`pg_backup_start()`) se bloquearon debido a transacciones de larga duración no confirmadas o contención de bloqueos (locks), superando el límite de ejecución del hook de Velero (predeterminado en 10 minutos).

#### Flujo de Trabajo Diagnóstico
1. Inspeccionar los logs de ejecución del pod de backup de Velero:
   ```bash
   velero backup logs stateful-workloads-hourly-20260807010000 --namespace velero | grep -i "error"
   ```
2. Inspeccionar los logs stderr del contenedor de la carga de trabajo (workload) de destino:
   ```bash
   kubectl logs -n production-databases postgresql-0 -c postgresql --tail=100
   ```
3. Solucionar estableciendo un tiempo de espera de instrucción (statement timeout) explícito para la sesión de backup en el manifiesto del hook:
   ```bash
   psql -U postgres -c 'SET statement_timeout = "30s"; SELECT pg_backup_start("velero-snapshot", true);'
   ```

---

## 6. Referencias

- Visión General de LPI Security Essentials (Linux Professional Institute):  
  https://www.lpi.org/our-certifications/security-essentials-overview/
- Objetivos Detallados de LPI Security Essentials (020-100) V1.0:  
  https://wiki.lpi.org/wiki/Security_Essentials_Objectives_V1.0
- Especificación de Formato en Disco de Cryptsetup y dm-crypt (LUKS2):  
  https://gitlab.com/cryptsetup/cryptsetup/-/wikis/LUKS-standard/LUKS2-architecture.pdf
- Especificación de la Biblioteca TPM 2.0 de Trusted Computing Group (TCG):  
  https://trustedcomputinggroup.org/resource/tpm-library-specification/
- Documentación de AppArmor en el Kernel de Linux y Arquitectura de Perfiles:  
  https://apparmor.net/
- Kubernetes Pod Security Standards e Integración de Seccomp:  
  https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Arquitectura de Backup Cloud-Native y Recuperación ante Desastres de Velero:  
  https://velero.io/docs/