# Guía de Estudio para Nivel de Producción: LPI-702 BSD Specialist (Examen 702-100)
## Tema 712.3: Control del Montaje y Desmontaje de Sistemas de Archivos
**Peso:** 3.33  
**Referencia Oficial:** [LPI BSD Specialist Overview](https://www.lpi.org/our-certifications/bsd-specialist-overview/)

---

### Mecánica Técnica Profunda y Visión General de la Arquitectura

En los sistemas operativos BSD (FreeBSD, OpenBSD, NetBSD), el montaje de un sistema de archivos es el proceso del kernel de vincular la estructura del directorio raíz de un dispositivo de almacenamiento a la jerarquía global de VFS (Virtual File System) en un vnode de punto de montaje especificado.

```
       +--------------------------------------------------------+
       |                  BSD VFS Layer                         |
       |  (Translates generic file Ops to FS-specific vops)     |
       +--------------------------------------------------------+
              |                                            |
              v                                            v
     +-----------------+                          +-----------------+
     |   struct mount  |                          |   struct mount  |
     |   (UFS / ZFS)   |                          |     (NFS / BSD) |
     +-----------------+                          +-----------------+
        |           |                                      |
        v           v                                      v
    +-------+   +-------+                              +-------+
    | vnode |   | vnode |                              | vnode |
    | (File)|   | (Dir) |                              | (NFS) |
    +-------+   +-------+                              +-------+
```

#### Estructuras de Datos Clave del Kernel
*   **`struct vnode`**: Representa un archivo activo, directorio, socket o nodo de dispositivo en la memoria del kernel. Cada referencia a un archivo abierto o directorio activo mantiene un bloqueo de vnode o un recuento de referencias (`v_usecount`, `v_holdcnt`).
*   **`struct mount`**: Representa una instancia de sistema de archivos montado, que contiene punteros a las flags de montaje (`MNT_RDONLY`, `MNT_NOEXEC`, `MNT_NOSUID`, `MNT_NOATIME`, `MNT_SYNCHRONOUS`), vectores de operaciones específicos del sistema de archivos (`vfsops`), y el vnode raíz del sistema de archivos montado (`mnt_vnodecovered`).

#### Ciclo de Vida de la Operación de Montaje en VFS
1.  **Búsqueda y Validación**: El kernel resuelve la ruta del punto de montaje a un `struct vnode`. Verifica que la ruta de destino sea un directorio y que el usuario ejecutante tenga privilegios de root (`priv_check(td, PRIV_VFS_MOUNT)`).
2.  **Privilegio de Acceso y Adquisición de Bloqueos**: El vnode del punto de montaje se bloquea de forma exclusiva (`vn_lock(vp, LK_EXCLUSIVE)`).
3.  **Inicialización del FS**: Se invoca el punto de entrada `vfs_mount` del controlador del sistema de archivos. Se valida el superblock o el handshake del protocolo de red.
4.  **Registro en VFS**: Se inicializa un nuevo `struct mount` y se vincula a la lista global de montajes de VFS (`mountlist`). El estado `VDIR` del vnode del punto de montaje se vincula al vnode raíz del nuevo sistema de archivos.

#### El Ciclo de Vida del Desmontaje y Fallos de `EBUSY`
Al invocar `umount(8)`:
1.  El kernel llama a `vfs_unmount()`, el cual intenta vaciar (flush) todos los búferes sucios (`vfs_object_sync()`).
2.  El kernel verifica si existen vnodes activos con recuentos de referencias distintos de cero (`v_usecount > 0` o bloqueos de archivos activos).
3.  Si existen vnodes activos y la flag de forzado (`MNT_FORCE`) **no** está establecida, la llamada al sistema falla inmediatamente con el código de error `16` (`EBUSY`: *Device busy*).
4.  Si `MNT_FORCE` (`umount -f`) está establecida, los vnodes activos se invalidan o revocan a la fuerza mediante `vgone()`, rompiendo los descriptores de archivo (file handles) activos para las aplicaciones del espacio de usuario.

---

### Ejercicio 1: Montaje Avanzado de Sistemas de Archivos Locales e Ingeniería de `/etc/fstab`

En este ejercicio, crearás un disco de memoria respaldado por RAM (`mdconfig`), lo formatearás con UFS2, configurarás el montaje a través de `/etc/fstab` y alterarás dinámicamente los parámetros de montaje del kernel en tiempo de ejecución sin desmontar.

#### Paso 1: Crear un Nodo de Almacenamiento Respaldado por RAM y un Sistema de Archivos
Crea un dispositivo de memoria de 128MB respaldado por swap usando `mdconfig(8)` (FreeBSD) y formatéalo con UFS2 usando `newfs(8)`.

```bash
# Create a swap-backed memory disk of 128MB
sudo mdconfig -a -t swap -s 128M -u md99

# Verify the block device exists
ls -l /dev/md99

# Create a UFS2 filesystem with softupdates enabled
sudo newfs -U /dev/md99
```

**Salida Esperada:**
```text
/dev/md99: 128.0MB (262144 sectors) block size 32768, fragment size 4096
	using 4 cylinder groups of 32.00MB, 1024 blks, 4160 inodes.
	with soft updates
super-block backups (for fsck -b #) at:
 192, 65728, 131264, 196800
```

#### Paso 2: Configurar el Destino de Montaje y la Configuración Persistente
Crea una ruta de montaje absoluta `/mnt/secure_data` y agrega una entrada sintácticamente válida a `/etc/fstab`.

```bash
sudo mkdir -p /mnt/secure_data

# Append the entry to /etc/fstab using standard BSD fstab options
# Schema: <device> <mountpoint> <fstype> <options> <dump> <pass>
echo "/dev/md99 /mnt/secure_data ufs rw,noexec,nosuid,noatime 2 2" | sudo tee -a /etc/fstab
```

#### Paso 3: Montar a Través de `fstab` e Inspeccionar las Flags de Montaje del Kernel en Tiempo de Ejecución
Monta el sistema de archivos recién definido usando `mount(8)` haciendo referencia a `/etc/fstab`, luego verifica las flags mediante `mount -v`.

```bash
# Mount the entry defined in fstab
sudo mount /mnt/secure_data

# Display detailed mount status for the filesystem
mount -v -t ufs | grep /mnt/secure_data
```

**Salida Esperada:**
```text
/dev/md99 on /mnt/secure_data (ufs, local, noatime, noexec, nosuid, soft-updates)
```

#### Paso 4: Validar la Aplicación por Parte del Kernel de las Flags de Montaje (`noexec`, `nosuid`)
Prueba la aplicación de la seguridad intentando ejecutar un binario dentro de `/mnt/secure_data`.

```bash
# Copy a standard binary to the mount point
sudo cp /bin/echo /mnt/secure_data/test_echo
sudo chmod 755 /mnt/secure_data/test_echo

# Attempt execution
/mnt/secure_data/test_echo "Testing noexec"
```

**Salida Esperada:**
```text
bash: /mnt/secure_data/test_echo: Permission denied
```

#### Paso 5: Realizar una Actualización del Montaje en Tiempo de Ejecución en Vivo (Modificación en Caliente)
Degrada el sistema de archivos a solo lectura (read-only) en tiempo de ejecución sin desmontar las aplicaciones mediante la flag `-u` (update).

```bash
# Update kernel mount flags to read-only (ro)
sudo mount -u -o ro /mnt/secure_data

# Attempt to write a file
touch /mnt/secure_data/test_file
```

**Salida Esperada:**
```text
touch: /mnt/secure_data/test_file: Read-only file system
```

---

#### Preguntas de Verificación - Ejercicio 1

1. **¿Cuál es la diferencia funcional exacta entre los campos `dump` y `pass` (columnas 5 y 6) en `/etc/fstab` en sistemas BSD?**
2. **Si un sistema de archivos está montado con `-o noexec`, ¿se puede seguir ejecutando un script de shell ubicado en esa partición usando `sh /mnt/secure_data/script.sh`? ¿Por qué sí o por qué no desde la perspectiva de VFS?**

---

### Ejercicio 2: Sistemas de Archivos Especiales y En Capas (`nullfs`, `tmpfs`, `devfs`)

Los sistemas de archivos en capas pasan las llamadas VFS a través de una capa de sistema de archivos existente hacia un sistema de archivos inferior. `nullfs(5)` (loopback/bind mount) construye vistas secundarias de árboles de directorios existentes. `tmpfs(5)` utiliza directamente la caché de páginas de la memoria virtual (VM page cache).

#### Paso 1: Configurar un Almacén de Memoria `tmpfs` de Alto Rendimiento
Monta un sistema de archivos respaldado por memoria con tamaño de memoria restringido y permisos estrictos.

```bash
sudo mkdir -p /tmp/volatile_cache

# Mount tmpfs restricted to 64MB with 0700 permissions
sudo mount -t tmpfs -o size=64M,mode=0700 tmpfs /tmp/volatile_cache

# Inspect tmpfs allocation using df
df -h /tmp/volatile_cache
```

**Salida Esperada:**
```text
Filesystem    Size    Used   Avail Capacity  Mounted on
tmpfs          64M    4.0Ki     64M     0%    /tmp/volatile_cache
```

#### Paso 2: Construir un Montaje Loopback en Capas (`nullfs`)
Monta un directorio existente `/var/log` en `/mnt/log_shadow` usando `nullfs`.

```bash
sudo mkdir -p /mnt/log_shadow

# Mount /var/log into /mnt/log_shadow using nullfs
sudo mount -t nullfs /var/log /mnt/log_shadow

# Create a test log file in the lower filesystem shadow
touch /mnt/log_shadow/nullfs_test.log

# Verify file presence in the underlying physical directory
ls -l /var/log/nullfs_test.log
```

**Salida Esperada:**
```text
-rw-r--r--  1 root  wheel  0 Aug  6 20:30 /var/log/nullfs_test.log
```

#### Paso 3: Implementar un Overlay Passthrough de Solo Lectura con `nullfs`
Configura una capa `nullfs` de solo lectura sobre un sistema de archivos subyacente de lectura y escritura para exponer vistas de datos seguras a aplicaciones sin privilegios o Jails.

```bash
sudo mkdir -p /mnt/log_readonly

# Mount lower filesystem with read-only overlay
sudo mount -t nullfs -o ro /var/log /mnt/log_readonly

# Attempt to write to the read-only layer
touch /mnt/log_readonly/should_fail.log
```

**Salida Esperada:**
```text
touch: /mnt/log_readonly/should_fail.log: Read-only file system
```

---

#### Preguntas de Verificación - Ejercicio 2

1. **¿Cómo afecta `nullfs` a la retención de vnodes y a los números de inode? ¿`/mnt/log_shadow/nullfs_test.log` comparte el mismo número de inode que `/var/log/nullfs_test.log`?**
2. **Si el sistema de archivos inferior (`/var/log`) se desmonta o se modifica, ¿qué sucede con los descriptores de archivo abiertos que acceden al overlay superior de `nullfs`?**

---

### Ejercicio 3: Diagnosticar y Resolver Fallos de Montaje/Desmontaje (`EBUSY`)

Los administradores de sistemas se encuentran con frecuencia con errores `Device busy` (`EBUSY`) al intentar desmontar almacenamiento. Este ejercicio cubre la inspección de vnodes del kernel usando `fstat(1)`, `procstat(1)`, y la mecánica de desmontaje forzado.

#### Paso 1: Simular una Condición de Sistema de Archivos Bloqueado
Crea un bloqueo activo en `/mnt/secure_data` abriendo un proceso de larga duración con su directorio de trabajo dentro del punto de montaje.

```bash
# Ensure /mnt/secure_data is mounted read-write
sudo mount -u -o rw /mnt/secure_data

# Launch a background process holding a file descriptor open inside the mount
( cd /mnt/secure_data && sleep 300 ) &
LOCKED_PID=$!
echo "Background process holding lock PID: ${LOCKED_PID}"
```

#### Paso 2: Reproducir el Fallo de Desmontaje
Intenta desmontar el sistema de archivos usando `umount(8)`.

```bash
sudo umount /mnt/secure_data
```

**Salida Esperada:**
```text
umount: unmount of /mnt/secure_data failed: Device busy
```

#### Paso 3: Inspeccionar Vnodes Activos y Descriptores de Archivo Abiertos
Identifica el proceso preciso, usuario, descriptor de archivo y vnode que bloquea el sistema de archivos usando `fstat(1)` y `procstat(1)`.

```bash
# Query fstat for any process holding open files on the mount point
fstat /mnt/secure_data

# Alternatively, use procstat to inspect file descriptors across processes
procstat -f -a | grep "/mnt/secure_data"
```

**Salida Esperada:**
```text
USER     CMD          PID   FD MOUNT      INUM MODE         SZ|DV R/W
root     sh         45129 text /mnt/secure_data     2 drwxr-xr-x     512 r
root     sh         45129 cwd  /mnt/secure_data     2 drwxr-xr-x     512 r
```

#### Paso 4: Ejecutar Protocolos de Terminación Graceful vs Forzada
Remedia el bloqueo primero a través de la terminación dirigida de procesos y luego evalúa el desmontaje forzado (`umount -f`).

```bash
# Method A: Graceful Process Termination via PID identified by fstat
sudo kill -TERM 45129
sleep 1

# Retry unmount
sudo umount /mnt/secure_data
echo "Unmount return code: $?"
```

**Salida Esperada:**
```text
Unmount return code: 0
```

#### Paso 5: Mecanismo de Desmontaje Forzado (`umount -f` / `umount -N`)
Vuelve a montar `/mnt/secure_data`, bloquéalo de nuevo y ejecuta un desmontaje de invalidación forzada del kernel.

```bash
# Remount and hold lock
sudo mount /mnt/secure_data
( cd /mnt/secure_data && sleep 300 ) &

# Execute forced unmount
sudo umount -f /mnt/secure_data
```

**Salida Esperada:**
```text
/mnt/secure_data: unmounted
```

---

#### Preguntas de Verificación - Ejercicio 3

1. **¿Qué ocurre internamente dentro del kernel cuando se ejecuta `umount -f` en un sistema de archivos con solicitudes de escritura activas en progreso? ¿Qué le sucede al proceso que intenta escribir?**
2. **¿Cuál es el propósito de `umount -N` en sistemas BSD?**

---

### Ejercicio 4: Sistemas de Archivos de Red (NFS) e Infraestructura de Automontaje (`autofs`)

Este ejercicio cubre la configuración de exportaciones (`/etc/exports`), el montaje de exportaciones NFS remotas con parámetros tolerantes a fallos y la configuración de montajes por disparador (trigger mounts) mediante `autofs(5)`.

#### Paso 1: Configurar la Definición de Exportación del Servidor NFS Local
Define una regla de exportación NFS en `/etc/exports` que permita el acceso a subredes locales con opciones de mapeo de credenciales de root.

```bash
# Ensure NFS server daemon configurations exist in /etc/exports
# Format: <directory> <flags> <network/host>
echo "/var/exports -alldirs -network 192.168.1.0/24 -maproot=root" | sudo tee -a /etc/exports

# Create exported directory
sudo mkdir -p /var/exports/shared_data
sudo touch /var/exports/shared_data/nfs_marker.txt

# Reload mountd daemon to apply exports modifications
sudo reload mountd || sudo service mountd reload
```

#### Paso 2: Montar Recursos Compartidos NFS Remotos con Opciones de Producción Robustas
Monta el recurso compartido exportado localmente usando `mount_nfs` con opciones `soft`, `retry` y de ajuste de rendimiento.

```bash
sudo mkdir -p /mnt/nfs_client

# Mount NFS share using optimized options:
# soft: Fail operations after retries (prevents permanent process hang if server drops)
# timeo: Timeout interval in tenths of a second (50 = 5.0 seconds)
# retrans: Number of minor timeouts before major timeout
sudo mount -t nfs -o rw,soft,timeo=50,retrans=3 127.0.0.1:/var/exports/shared_data /mnt/nfs_client

# Verify remote mount status
mount -v -t nfs
```

**Salida Esperada:**
```text
127.0.0.1:/var/exports/shared_data on /mnt/nfs_client (nfs, performance options: soft, retrans=3, timeo=50)
```

#### Paso 3: Configurar Mapas Directos e Indirectos de `autofs(5)`
`autofs` monta dinámicamente sistemas de archivos bajo demanda cuando un proceso accede a una ruta de destino, desmontándolos automáticamente después de un tiempo de espera de inactividad (`automountd`).

Edita `/etc/auto_master` para definir un punto de mapa de automontaje indirecto:

```bash
# Append an automount point to /etc/auto_master
# Syntax: <mount-point> <map-name> [ -options ]
echo "/net_auto /etc/auto_direct -timeout=30" | sudo tee -a /etc/auto_master
```

Crea el archivo de mapa `/etc/auto_direct`:

```bash
# Syntax: <key> [ -options ] <location>
echo "data -rw,soft,timeo=30 127.0.0.1:/var/exports/shared_data" | sudo tee -a /etc/auto_direct

# Set correct permissions on map configuration
sudo chmod 644 /etc/auto_direct
```

#### Paso 4: Activar los Demonios de Automontaje y Probar el Montaje Bajo Demanda
Inicia los demonios `automount(8)` y `automountd(8)` y dispara un montaje automatizado.

```bash
# Enable autofs daemons in /etc/rc.conf
sudo sysrc autofs_enable="YES"

# Start the autofs service
sudo service autofs start

# Force update of kernel automount triggers
sudo automount -c

# Confirm the automount trigger directory exists but is NOT mounted yet
df -h | grep net_auto
```

*(No se espera salida de `df`, lo que indica que el montaje no se ha disparado)*

Accede a la ruta del disparador para forzar el montaje dinámico:

```bash
# Accessing the key path 'data' inside /net_auto triggers automountd
ls -l /net_auto/data
```

**Salida Esperada:**
```text
total 0
-rw-r--r--  1 root  wheel  0 Aug  6 20:35 nfs_marker.txt
```

Verifica que la capa VFS montó dinámicamente con éxito el recurso compartido:

```bash
df -h /net_auto/data
```

**Salida Esperada:**
```text
Filesystem                             Size    Used   Avail Capacity  Mounted on
127.0.0.1:/var/exports/shared_data    45G    2.1G    39G     5%    /net_auto/data
```

---

#### Preguntas de Verificación - Ejercicio 4

1. **¿Cuál es el compromiso (trade-off) crítico de recuperación ante fallos entre montar una exportación NFS con `-o hard` versus `-o soft` en un sistema de producción?**
2. **¿Cómo detecta `autofs` cuándo un sistema de archivos ya no está en uso y qué impide que `automountd` desmonte un montaje dinámico inactivo?**

---

<details>
<summary><b>Haz clic para ver las claves de respuestas y explicaciones técnicas detalladas</b></summary>

### Clave de Respuestas del Ejercicio 1

1.  **Campos `dump` vs `pass` en `/etc/fstab`:**
    *   **Columna 5 (`dump`):** Utilizada por la utilidad de respaldo `dump(8)` para determinar qué sistemas de archivos requieren respaldo automático en cinta/disco. Un valor de `1` marca el sistema de archivos para respaldo; `0` lo ignora.
    *   **Columna 6 (`pass`):** Utilizada por `fsck(8)` durante el arranque del sistema para determinar la secuencia en la que se comprueban los sistemas de archivos.
        *   `0`: No comprobar (utilizado para `tmpfs`, `procfs`, `nullfs`, o swap).
        *   `1`: Comprobado primero (estrictamente reservado para el sistema de archivos raíz `/`).
        *   `2`: Comprobado de forma concurrente o secuencial después de que finalice el sistema de archivos raíz.

2.  **Ejecución de scripts en montajes con `noexec`:**
    *   **Sí**, `sh /mnt/secure_data/script.sh` **se ejecutará**.
    *   **Razón Arquitectónica:** La flag de montaje `noexec` le indica a la capa VFS que haga fallar las llamadas al sistema `execve(2)` que se originen en vnodes de ese sistema de archivos (verificación de `MNT_NOEXEC` en `exec_check_permissions()` del kernel). Al ejecutar `sh script.sh`, el binario ejecutado por `execve(2)` es `/bin/sh` (ubicado en `/`), el cual tiene permisos de ejecución. `/bin/sh` abre `script.sh` mediante llamadas VFS `read(2)`, analiza el flujo de texto y lo interpreta. `noexec` bloquea la ejecución binaria, no la lectura del contenido de texto.

---

### Clave de Respuestas del Ejercicio 2

1.  **Retención de vnodes y números de inode en `nullfs`:**
    *   `nullfs` crea vnodes alias (`struct null_node`) en la capa VFS que envuelven a los vnodes de destino subyacentes (`lower vnode`).
    *   `nullfs` **preserva explícitamente los números de inode subyacentes** (`v_id`) y los atributos del sistema de archivos inferior. Ejecutar `stat` o `ls -i` en `/mnt/log_shadow/nullfs_test.log` y `/var/log/nullfs_test.log` devolverá números de inode idénticos porque `nullfs` reenvía las consultas de atributos (`vop_getattr`) directamente al vector del vnode inferior.

2.  **Impacto del desmontaje del sistema de archivos inferior en `nullfs`:**
    *   Si el sistema de archivos inferior subyacente se desmonta (por ejemplo, usando `umount -f /var`), todos los vnodes inferiores asociados se reclaman e invalidan (`vgone()`).
    *   Las llamadas al sistema de lectura/escritura posteriores a descriptores de archivo abiertos en el overlay superior de `nullfs` devolverán `EBADF` o `EIO` (Error de entrada/salida), debido a que los punteros `struct vnode` subyacentes dentro del envoltorio `null_node` ahora apuntan a operaciones de vnodes reclamados/muertos (`dead_vnodeops`).

---

### Clave de Respuestas del Ejercicio 3

1.  **Mecánica del kernel durante un desmontaje forzado (`umount -f`):**
    *   El kernel omite la verificación de validación `v_usecount == 0` dentro de `vfs_unmount()`.
    *   Ejecuta `vflush(mp, 0, FORCECLOSE)`, recorriendo todos los vnodes activos asociados con el `struct mount`.
    *   Cualquier vnode activo se convierte a la fuerza en un vnode muerto (`vgone()`), y su vector de operaciones se reemplaza con `dead_vnodeops`.
    *   Las operaciones de I/O activas en curso fallan de inmediato. Los procesos que mantienen descriptores de archivo abiertos reciben `EIO` o `ESTALE` en su siguiente llamada al sistema de lectura/escritura/fsync. Los búferes sucios que no fueron escritos en el disco se descartan, lo que arriesga la inconsistencia del sistema de archivos si había actualizaciones suaves (soft updates) o vaciados de diario (journal flushes) pendientes.

2.  **Propósito de `umount -N`:**
    *   La flag `-N` en el `umount(8)` de BSD le indica al comando que desmonte sistemas de archivos directamente por su **nombre de punto de montaje**, omitiendo la búsqueda por nombre de nodo de dispositivo. Esto es esencial cuando múltiples sistemas de archivos virtuales o en capas (como instancias de `nullfs` o `tmpfs` dinámicas) están montados desde pseudodispositivos idénticos o al resolver rutas ambiguas de dispositivos de bloques.

---

### Clave de Respuestas del Ejercicio 4

1.  **Compromiso (trade-off) entre montajes NFS `-o hard` y `-o soft`:**
    *   **`-o hard` (Predeterminado/Recomendado para producción por integridad de datos):** Si el servidor NFS remoto deja de responder, las solicitudes RPC reintentan indefinidamente. Los procesos que intentan la I/O se bloquean en un estado de suspensión ininterrumpible (estado `D` en `ps`). El sistema **nunca** corromperá archivos ni devolverá errores de escritura parciales a las aplicaciones, pero los hilos de las aplicaciones se cuelgan hasta que el servidor se recupere.
    *   **`-o soft` (Recomendado solo para datos no críticos/transitorios):** Si un servidor NFS no responde después de los intentos de `retrans`, el kernel devuelve un error de I/O (`EIO`) a la aplicación que realiza la llamada. Si bien esto evita que los procesos se cuelguen permanentemente en estado `D`, la mayoría de las aplicaciones (bases de datos, compiladores, herramientas de copia de archivos) no manejan adecuadamente los errores `EIO` inesperados, lo que conduce a **corrupción silenciosa de datos o escrituras de archivos defectuosas**.

2.  **Detección de inactividad y prevención de desmontaje en `autofs`:**
    *   El módulo del kernel `autofs` rastrea los tiempos de acceso en los vnodes montados automáticamente. Cuando no se producen búsquedas VFS ni accesos a archivos en el sistema de archivos montado durante la duración especificada por `-timeout` (por defecto 600 s), `automountd(8)` recibe una notificación del kernel para desmontar el árbol mediante `vfs_unmount()`.
    *   Un automontaje inactivo **no** se puede desmontar si:
        1. Cualquier proceso tiene su directorio de trabajo actual (`cwd`) dentro del árbol de montaje.
        2. Cualquier descriptor de archivo permanece abierto (`v_usecount > 0`).
        3. Existe un mapeo de memoria activo (`mmap(2)`) para un archivo en ese montaje.

</details>