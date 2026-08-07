# LPI 702-100: Certificación BSD Specialist
## Tema 712.3: Control del montaje y desmontaje de sistemas de archivos
**Peso:** 3.33 | **Nivel objetivo:** SRE avanzado / Arquitecto principal de plataformas

---

### 1. Motivación en producción y problema arquitectónico

En entornos de producción BSD empresariales (FreeBSD, NetBSD, OpenBSD), la capa de abstracción del Sistema de Archivos Virtual (VFS) conecta los controladores de almacenamiento físico, los puntos de enlace de almacenamiento en red y las estructuras en memoria con el árbol de sistema de archivos raíz unificado (`/`). Controlar el acoplamiento (montaje) y desacoplamiento (desmontaje) de sistemas de archivos no es simplemente una conveniencia administrativa: es un límite de seguridad central, un vector de ajuste de rendimiento y un mecanismo de resiliencia.

```
                  +-------------------------------------------------+
                  |              User Space Applications            |
                  +-------------------------------------------------+
                                           |
                                  POSIX System Calls
                               (open, read, write, stat)
                                           |
                  +-------------------------------------------------+
                  |              VFS (Virtual File System)          |
                  |                vnode / mount table              |
                  +-------------------------------------------------+
                     /                     |                     \
                    /                      |                      \
    +-----------------------+    +-------------------+    +-----------------------+
    |   UFS2 / FFS VFS      |    |      ZFS VFS      |    |      NFS VFS          |
    | (softdep, journal)    |    | (SPA, ZPL, ARC)   |    | (RPC, Client VFS)     |
    +-----------------------+    +-------------------+    +-----------------------+
                |                          |                          |
    +-----------------------+    +-------------------+    +-----------------------+
    |   GEOM Storage Layer  |    |   vdev / Disks    |    | Network Stack (ixgbe) |
    |  (gpart, gmirror, etc)|    +-------------------+    +-----------------------+
    +-----------------------+
```

#### Desafíos arquitectónicos en producción
1. **Aislamiento de seguridad y límites de privilegios:** Exponer montajes de lectura-escritura directos con permisos setuid (`suid`) y bits de ejecución (`exec`) dentro de directorios de aplicaciones web o Jails de FreeBSD multitenant presenta riesgos catastróficos de escalación de privilegios. Los ingenieros deben aplicar opciones de seguridad estrictas a nivel de montaje (`noexec`, `nosuid`, `nosymfollow`, `wxneeded`) en el límite del kernel VFS.
2. **Actualizaciones atómicas e infraestructura inmutable:** Las actualizaciones del SO sin tiempo de inactividad (zero-downtime) dependen de montajes del sistema base de solo lectura combinados con capas `nullfs` (loopback) o `unionfs`, o entornos de arranque ZFS (ZFS boot environments) (`beadm`/`bectl`). La conversión de un sistema de archivos montado de solo lectura a lectura-escritura debe realizarse de forma atómica mediante operaciones de remontaje en tiempo de ejecución (`mount -u`).
3. **Desacoplamiento fluido frente a fallos de almacenamiento:** Las caídas de redes de área de almacenamiento (SAN), fallos del servidor NFS o procesos descontrolados que mantienen vnodes abiertos provocan que los puntos de montaje de destino se bloqueen en estados `EBUSY`. Los SREs requieren diagnósticos precisos (`fstat`, `fuser`, `lsof`) y rutinas de forzado controladas (`umount -f`) para evitar condiciones de bloqueo del kernel (kernel hang) o bloqueos mutuos del sistema (deadlocks).
4. **Ordenamiento de la secuencia de arranque y gestión de dependencias:** Los sistemas BSD modernos analizan tablas estáticas (`/etc/fstab`) durante la inicialización temprana (`/etc/rc.d/mountcritlocal`, `/etc/rc.d/mountcritremote`). Las dependencias de sistemas de archivos de red mal configuradas sin opciones no bloqueantes (`late`, `bg`, `noauto`) provocan que la ejecución del inicio se cuelgue indefinidamente antes de que se inicie sshd.

---

### 2. Tablas de comparación técnica y de compromisos (Trade-offs)

#### 2.1 Paradigmas de montaje de sistemas de archivos

| Paradigma | Fuente de configuración | Sobrecarga de rendimiento | Mecanismo VFS del kernel | Mejor caso de uso | Principal compromiso (Trade-off) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`/etc/fstab` estático** | `/etc/fstab` analizado en el arranque por `/etc/rc` | Cero sobrecarga de control en tiempo de ejecución | Registro directo del punto de montaje en VFS | Particiones base del SO (`/`, `/usr`, `/var`), swap | Estructura rígida; requiere reinicio o `mount -a` manual al editar |
| **Automontaje de ZFS** | Propiedades de ZFS Pool (`mountpoint`, `canmount`) | Búsqueda en microsegundos vía metadatos ZPL | Acoplamiento dinámico de VFS omitiendo `/etc/fstab` | Almacenamiento empresarial, volúmenes de base de datos, datasets de contenedores | Incompatible con herramientas UFS heredadas; omite los flujos tradicionales de auditoría de fstab |
| **Automounter (`autofs` / `amd`)** | `/etc/auto_master`, mapas directos/indirectos | Latencia menor en el acceso inicial a directorios | El demonio autofs del kernel desencadena el montaje dinámico | Directorios personales NFS bajo demanda, unidades ópticas | Penalización de latencia en el primer acceso; sobrecarga en la limpieza de montajes obsoletos |
| **Nullfs (Montaje Loopback)** | CLI manual o `/etc/fstab` (`nullfs` / `null`) | Mínima (capa de redirección de vnode) | Mapea un árbol de directorios en otro espacio de nombres | FreeBSD Jails, chroots, raíces de compilación aisladas | Posibles bucles de recursión si se anida de forma incorrecta |
| **Tmpfs (Memory FS)** | `/etc/fstab` (`tmpfs`) | Ultra-rápido (rendimiento a velocidad de RAM) | Asignación del asignador de memoria de page cache | `/tmp`, `/var/run`, artefactos de compilación efímeros | Almacenamiento volátil; consume RAM del sistema/pool de swap |

#### 2.2 Flags de montaje VFS y opciones de seguridad en BSD

| Flag | Opción del kernel VFS | Función de seguridad / operacional | Impacto en el rendimiento | SO soportado |
| :--- | :--- | :--- | :--- | :--- |
| `ro` | `MNT_RDONLY` | Fuerza el acceso de solo lectura en el sistema de archivos. Evita modificaciones de archivos. | Elimina operaciones de escritura y actualizaciones de metadatos | FreeBSD, NetBSD, OpenBSD |
| `rw` | Default | Permite operaciones de lectura y escritura. | Ruta estándar de I/O de disco | FreeBSD, NetBSD, OpenBSD |
| `nosuid` | `MNT_NOSUID` | Deshabilita la ejecución de binarios Set-User-ID y Set-Group-ID. | Cero | FreeBSD, NetBSD, OpenBSD |
| `noexec` | `MNT_NOEXEC` | Evita la ejecución de cualquier binario ubicado en la partición. | Previene ataques de ejecución | FreeBSD, NetBSD, OpenBSD |
| `noatime` | `MNT_NOATIME` | Deshabilita la actualización del tiempo de acceso en vnodes cuando se leen archivos. | Alta reducción de escritura; aumenta los IOPS de lectura | FreeBSD, NetBSD, OpenBSD |
| `async` | `MNT_ASYNC` | Escrituras de metadatos asincrónicas. Las operaciones de metadatos retornan antes de llegar al disco. | Rendimiento ultra alto; riesgo extremo de corrupción de datos ante un panic | FreeBSD, NetBSD, OpenBSD |
| `softdep` | `UFS_SOFTUPDATES` | Utiliza Soft Updates para mantener la consistencia de metadatos UFS sin bloquear escrituras sincrónicas. | Gran aumento de rendimiento para operaciones de metadatos UFS | FreeBSD, NetBSD, OpenBSD |
| `wxneeded` | `MNT_WXNEEDED` | Aplica la seguridad W^X (Write XOR Execute); permite a los procesos violar W^X solo si el binario está marcado. | Despreciable; refuerza la seguridad | Específico de OpenBSD |

#### 2.3 Utilidades y diferencias de montaje entre variantes de BSD

| Característica / Utilidad | FreeBSD | NetBSD | OpenBSD |
| :--- | :--- | :--- | :--- |
| **Sistema de archivos principal** | UFS2 / ZFS | FFSv2 (Fast File System) | FFS (Fast File System) |
| **Herramienta de montaje Loopback** | `mount_nullfs` (FSType: `nullfs`) | `mount_null` (FSType: `null`) | `mount_null` (FSType: `null`) |
| **Flag de actualización de FSType** | `mount -u` | `mount -u` | `mount -u` |
| **Soporte nativo de ZFS** | Sistema base (`openzfs`) | Soporte mediante módulo / port | Sin soporte nativo |
| **Flags de seguridad predeterminados** | Definidos explícitamente en `/etc/fstab` | Definidos explícitamente en `/etc/fstab` | Valores predeterminados endurecidos (`wxneeded`, `nosuid` en `/tmp`) |
| **Servicio Automounter** | `autofs` (`autofs_enable="YES"`) | Demonio `amd` | Demonio `amd` |

---

### 3. Manifiestos de configuración de grado de producción

#### 3.1 `/etc/fstab` de producción endurecido en FreeBSD

Esta configuración define una estructura de múltiples particiones que incorpora UFS2, datasets de ZFS, `tmpfs`, aislamiento `nullfs` para Jails y montajes NFS no bloqueantes.

```fstab
# /etc/fstab - Production FreeBSD Infrastructure Node
# Device                Mountpoint           FSType    Options                                  Dump Pass
# ------------------------------------------------------------------------------------------------------
# Root Partition (UFS2 with Soft Updates and Journaling)
/dev/ada0p3             /                    ufs       rw,noatime,acls                          1    1

# Dedicated Boot Partition
/dev/ada0p2             /boot/efi            msdosfs   ro,noauto                                0    0

# System Partitions Hardened with Security Flags
/dev/ada0p4             /var                 ufs       rw,noatime,nosuid                        2    2
/dev/ada0p5             /var/tmp             ufs       rw,noatime,nosuid,noexec                 2    2
/dev/ada0p6             /usr                 ufs       rw,noatime                               2    2

# In-Memory Ephemeral Storage for High IOPS / Isolation
tmpfs                   /tmp                 tmpfs     rw,mode=1777,size=4G,nosuid,noexec       0    0
procfs                  /proc                procfs    rw,noauto                                0    0

# FreeBSD Jail Infrastructure - Base System Read-Only Loopback Nullfs Mounts
/usr/jails/basejail     /usr/jails/containers/app01/basejail nullfs ro,nosuid                        0    0
/usr/jails/basejail     /usr/jails/containers/app02/basejail nullfs ro,nosuid                        0    0

# Enterprise NFS Mount (Non-blocking, background, hardened against server failures)
nfs-storage.internal:/export/assets /mnt/assets nfs rw,noatime,soft,bg,intr,retrycnt=3,nosuid,noexec 0 0
```

#### 3.2 `/etc/fstab` de producción endurecido en seguridad para OpenBSD

OpenBSD utiliza esquemas de particionado estrictos que aplican límites de seguridad W^X.

```fstab
# /etc/fstab - OpenBSD Hardened Server Node
# Device UUID / DUID    Mountpoint           FSType    Options                                  Dump Pass
# ------------------------------------------------------------------------------------------------------
a1b2c3d4e5f6a7b8.a      /                    ffs       rw,noatime                               1    1
a1b2c3d4e5f6a7b8.b      none                 swap      sw                                       0    0
a1b2c3d4e5f6a7b8.d      /tmp                 ffs       rw,noatime,nosuid,noexec,nodev           2    2
a1b2c3d4e5f6a7b8.e      /var                 ffs       rw,noatime,nosuid,nodev                  2    2
a1b2c3d4e5f6a7b8.f      /usr                 ffs       rw,noatime,nodev                         2    2
a1b2c3d4e5f6a7b8.g      /usr/X11R6           ffs       ro,nodev                                 2    2
a1b2c3d4e5f6a7b8.h      /usr/local           ffs       rw,noatime,nodev,wxneeded                2    2
a1b2c3d4e5f6a7b8.i      /usr/obj             ffs       rw,noatime,nosuid,nodev                  2    2
a1b2c3d4e5f6a7b8.j      /home                ffs       rw,noatime,nosuid,nodev,noexec           2    2
```

#### 3.3 Configuración del Automounter de FreeBSD (`/etc/auto_master` y `/etc/auto_direct`)

##### Archivo: `/etc/auto_master`
```conf
# Master Automounter Map
/-                      auto_direct             -noatime,soft
/net                    -hosts                  -nobrowse,nosuid
```

##### Archivo: `/etc/auto_direct`
```conf
# Direct Automounter Map for Dynamic Storage Volumes
/mnt/database/backups   -fstype=nfs,rw,hard,intr,nosuid   san01.internal:/exports/backups
/mnt/media/archive      -fstype=nfs,ro,soft               nas01.internal:/exports/archive
```

---

### 4. Comandos CLI reales y salidas de terminal

#### 4.1 Visualización e inspección de montajes VFS activos

Examine los sistemas de archivos montados actualmente utilizando `mount`, `df` y `sysctl`.

```console
$ mount -v
zroot/ROOT/default on / (zfs, local, noatime, nfsv4acls)
devfs on /dev (devfs, local, jid=0)
zroot/tmp on /tmp (zfs, local, noatime, noexec, nosuid, nfsv4acls)
zroot/usr/home on /usr/home (zfs, local, noatime, nfsv4acls)
zroot/usr/src on /usr/src (zfs, local, noatime, nfsv4acls)
zroot/var/audit on /var/audit (zfs, local, noatime, noexec, nosuid, nfsv4acls)
zroot/var/log on /var/log (zfs, local, noatime, noexec, nosuid, nfsv4acls)
zroot/var/tmp on /var/tmp (zfs, local, noatime, noexec, nosuid, nfsv4acls)
/usr/jails/basejail on /usr/jails/containers/web01/basejail (nullfs, local, read-only)
```

```console
$ df -hT
Filesystem                                  Type      Size    Used   Avail Capacity  Mounted on
zroot/ROOT/default                          zfs       450G    12G    438G     3%     /
devfs                                       devfs     1.0Ki    0B   1.0Ki     0%     /dev
zroot/tmp                                   zfs       438G    120Ki  438G     0%     /tmp
zroot/usr/home                              zfs       465G    27G    438G     6%     /usr/home
zroot/var/log                               zfs       440G    2.1G   438G     0%     /var/log
/usr/jails/basejail                         nullfs    450G    12G    438G     3%     /usr/jails/containers/web01/basejail
```

#### 4.2 Montaje manual, endurecimiento y remontaje en vivo

Montaje manual de una partición UFS con restricciones de seguridad explícitas:

```console
# mount -t ufs -o ro,nosuid,noexec /dev/ada1p1 /mnt/secure_data
```

Verifique las flags de montaje registradas en el espacio del kernel VFS:

```console
$ mount | grep secure_data
/dev/ada1p1 on /mnt/secure_data (ufs, local, read-only, noexec, nosuid)
```

Realice una **actualización atómica en tiempo de ejecución (remontaje)** para cambiar el modo de acceso de solo lectura (`ro`) a lectura-escritura (`rw`) sin desmontar ni perturbar las rutas activas del kernel:

```console
# mount -u -o rw,nosuid,noexec /mnt/secure_data
```

Confirme el cambio:

```console
$ mount | grep secure_data
/dev/ada1p1 on /mnt/secure_data (ufs, local, noexec, nosuid)
```

#### 4.3 Operaciones con Loopback (`nullfs`) y en memoria (`tmpfs`)

Montaje de un árbol de directorios loopback dentro de una estructura de directorios de destino (útil para chroots/jails):

```console
# mount -t nullfs -o ro /var/cache/pkg /usr/jails/containers/web01/var/cache/pkg
```

Creación de un sistema de archivos respaldado en memoria de alta velocidad utilizando `tmpfs`:

```console
# mount -t tmpfs -o size=2G,mode=1777,noexec,nosuid tmpfs /mnt/ramdisk
```

Verifique la capacidad y propiedades de montaje de `tmpfs`:

```console
$ df -h /mnt/ramdisk
Filesystem    Size    Used   Avail Capacity  Mounted on
tmpfs         2.0G     4.0Ki  2.0G     0%     /mnt/ramdisk
```

#### 4.4 Gestión de montajes ZFS

ZFS gestiona el montaje de forma declarativa a través de propiedades de dataset en lugar de líneas estáticas en `/etc/fstab`.

Verifique las propiedades de montaje del dataset ZFS:

```console
$ zfs get mountpoint,canmount,mounted zroot/data/db
NAME           PROPERTY    VALUE       SOURCE
zroot/data/db  mountpoint  /var/db/db  local
zroot/data/db  canmount    on          default
zroot/data/db  mounted     yes         -
```

Desmonte explícitamente un dataset de ZFS:

```console
# zfs unmount zroot/data/db
```

Verifique el estado del dataset:

```console
$ zfs get mounted zroot/data/db
NAME           PROPERTY  VALUE  SOURCE
zroot/data/db  mounted   no     -
```

Monte todos los datasets ZFS configurados según las definiciones de los pools:

```console
# zfs mount -a
```

Cambie la ruta del punto de montaje dinámicamente:

```console
# zfs set mountpoint=/mnt/postgres_data zroot/data/db
```

---

### 5. Guía de verificación y diagnóstico de fallos

#### 5.1 Solución de problemas de errores de "Dispositivo ocupado" (`EBUSY` / Bloqueo de recursos)

Al intentar desmontar un sistema de archivos, el kernel devuelve `Device busy` (`EBUSY`) si hay procesos activos que mantienen manejadores vnode abiertos, referencias de directorio de trabajo o archivos mapeados en memoria en la partición de destino.

##### Escenario: Intento de desmontaje fallido
```console
# umount /mnt/data
umount: unmount of /mnt/data failed: Device busy
```

##### Paso 1: Identificar procesos bloqueantes mediante `fstat` (FreeBSD) o `lsof`
`fstat` consulta referencias de vnode abiertas en toda la tabla de procesos del kernel:

```console
# fstat /mnt/data
USER     CMD          PID   FD MOUNT      INUM MODE         SZ|DV R/W
www      nginx      84920 text /mnt/data 10492 -rwxr-xr-x  524288  r
www      nginx      84921   wd /mnt/data     2 drwxr-xr-x    4096  r
postgres postgres   85102    5 /mnt/data 84910 -rw------- 1048576 rw
```

##### Paso 2: Identificar procesos bloqueantes mediante `fuser`
`fuser` muestra los ID de proceso que utilizan archivos o sistemas de archivos especificados:

```console
# fuser -c /mnt/data
/mnt/data: 84920c 84921c 85102e
```
*(Flags: `c` = directorio actual, `e` = archivo de texto ejecutable, `f` = manejador de archivo abierto)*

##### Paso 3: Terminar procesos bloqueantes y desmontar
Termine los PIDs bloqueantes de forma gradual:

```console
# kill -TERM 84920 84921 85102
```

Si los procesos no se terminan, envíe `SIGKILL`:

```console
# fuser -k -9 /mnt/data
/mnt/data: 84920 84921 85102
```

Reintente el desmontaje estándar:

```console
# umount /mnt/data
```

#### 5.2 Manejo de montajes de red que no responden (Desmontaje forzado)

Cuando un servidor NFS se cuelga o queda inaccesible en la red, las llamadas estándar a `umount` se bloquean indefinidamente mientras esperan que expiren los tiempos de espera de la respuesta RPC.

##### Comando de desmontaje forzado:
```console
# umount -f /mnt/assets
```
`umount -f` invalida por la fuerza los vnodes abiertos dentro de la capa VFS, devolviendo `EIO` a los procesos de aplicación que intenten realizar llamadas activas de lectura/escritura, y desvincula la estructura de montaje inmediatamente.

#### 5.3 Recuperación de arranque de emergencia: `/etc/fstab` dañado

Si se introduce un error de sintaxis o un ID de dispositivo inexistente en `/etc/fstab`, la secuencia de arranque de BSD se detiene y entra en modo monousuario con un sistema de archivos raíz de solo lectura.

```
Mounting local filesystems:
mount: /dev/ada9p1: No such file or directory
Mounting /etc/fstab filesystems failed, startup aborted
Enter full pathname of shell or RETURN for /bin/sh:
```

##### Procedimiento de recuperación en monousuario:

1. Presione `Enter` para acceder a `/bin/sh`.
2. Remonte la partición raíz (`/`) en modo lectura-escritura (`rw`):

```console
# mount -u -w /
```

3. Si `/var` o `/usr` están en particiones separadas necesarias para las herramientas de edición, mónteals individualmente:

```console
# mount /usr
# mount /var
```

4. Verifique los montajes actuales:

```console
# mount
/dev/ada0p3 on / (ufs, local, read-only) -> updated to (ufs, local)
```

5. Corrija `/etc/fstab` utilizando `vi` o `ee`:

```console
# vi /etc/fstab
```

6. Pruebe las definiciones de montaje de `/etc/fstab` sin reiniciar:

```console
# mount -a
```

7. Salga del modo monousuario para reanudar el arranque multiusuario normal:

```console
# exit
```

---

#### 5.4 Diagrama de flujo para diagnóstico y toma de decisiones

```
                 +-----------------------------------+
                 |    File System Operation Fails    |
                 +-----------------------------------+
                                   |
                  Is error "Device busy" (EBUSY)?
                                  / \
                                 /   \
                               YES   NO
                               /       \
                              /         \
  +--------------------------------+   +------------------------------------+
  | Run: fstat <mountpoint>        |   | Is it an unresponsive network FS?  |
  |  OR: fuser -c <mountpoint>     |   +------------------------------------+
  +--------------------------------+                  / \
                  |                                  /   \
  +--------------------------------+               YES   NO
  | Terminate blocking PIDs:       |               /       \
  | # kill -15 <PID>               |              /         \
  | # kill -9 <PID> (if persistent)|  +------------------+  +-------------------+
  +--------------------------------+  | Force unmount:   |  | Check sysctl/dmesg|
                  |                   | # umount -f <mp> |  | Verify fstab syntax|
  +--------------------------------+  +------------------+  +-------------------+
  | Retry: # umount <mountpoint>   |
  +--------------------------------+
```

---

### 6. Referencias

* **LPI BSD Specialist Certification Overview:**  
  https://www.lpi.org/our-certifications/bsd-specialist-overview/
* **FreeBSD Manual Pages - `mount(8)`:**  
  https://man.freebsd.org/cgi/man.cgi?query=mount&sektion=8
* **FreeBSD Manual Pages - `fstab(5)`:**  
  https://man.freebsd.org/cgi/man.cgi?query=fstab&sektion=5
* **FreeBSD Handbook - Mounting and Unmounting File Systems:**  
  https://docs.freebsd.org/en/books/handbook/basics/#filesystems-mounting
* **OpenBSD Manual Pages - `mount(8)` & `fstab(5)`:**  
  https://man.openbsd.org/mount.8  
  https://man.openbsd.org/fstab.5
* **NetBSD Manual Pages - `mount(8)`:**  
  https://man.netbsd.org/mount.8
* **OpenZFS Documentation - Mounting & Datasets:**  
  https://openzfs.github.io/openzfs-docs/Getting%20Started/FreeBSD/index.html