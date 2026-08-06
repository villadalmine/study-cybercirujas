# LPIC-2 (Exámenes 201-450 y 202-450, v4.5) — Tema 206 / 1.7: Mantenimiento del Sistema
**Ponderación del examen:** 8  
**Audiencia objetivo:** SREs, Platform Engineers y Administradores de Sistemas Linux Senior preparándose para la certificación LPIC-2.

---

## Documentación de Referencia Oficial y Especificaciones

- **Objetivos y Visión General de LPI LPIC-2:**  
  [https://www.lpi.org/our-certifications/lpic-2-overview/](https://www.lpi.org/our-certifications/lpic-2-overview/)
- **Especificación del Sistema de Compilación GNU Autotools y Configure:**  
  [https://www.gnu.org/software/autoconf/manual/autoconf.html](https://www.gnu.org/software/autoconf/manual/autoconf.html)
- **Manual de Referencia de GNU Make:**  
  [https://www.gnu.org/software/make/manual/make.html](https://www.gnu.org/software/make/manual/make.html)
- **Especificación de GNU Tar y Algoritmos de Backup Incremental:**  
  [https://www.gnu.org/software/tar/manual/html_node/Using-tar-to-Perform-Incremental-Dumps.html](https://www.gnu.org/software/tar/manual/html_node/Using-tar-to-Perform-Incremental-Dumps.html)
- **Protocolo de Actualización Remota y Algoritmo de Delta-Transfer de rsync:**  
  [https://rsync.samba.org/tech_report/](https://rsync.samba.org/tech_report/)
- **Arquitectura de Linux PAM (Pluggable Authentication Modules) y MOTD:**  
  [https://man7.org/linux/man-pages/man8/pam_motd.8.html](https://man7.org/linux/man-pages/man8/pam_motd.8.html)

---

## 1. Arquitectura Técnica Profunda y Mecánica Interna

### 1.1 Compilación de Código Fuente, Sistemas de Build y Enlazado de Librerías Compartidas

Compilar software de producción desde el código fuente requiere comprender las etapas de compilación, las flags del preprocesador, el comportamiento del linker y los prefijos de instalación.

```
                  +-------------------------------------------------------+
                  |                 Source Files (.c, .h)                 |
                  +-------------------------------------------------------+
                                              |
                                              v  C Preprocessor (cpp / CFLAGS)
                  +-------------------------------------------------------+
                  |               Expanded Source Code                    |
                  +-------------------------------------------------------+
                                              |
                                              v  Compiler (gcc / clang)
                  +-------------------------------------------------------+
                  |               Assembly Code (.s)                      |
                  +-------------------------------------------------------+
                                              |
                                              v  Assembler (as)
                  +-------------------------------------------------------+
                  |             Relocatable Object Code (.o)              |
                  +-------------------------------------------------------+
                                              |
                                              v  Linker (ld / LDFLAGS)
           +----------------------------------+----------------------------------+
           |                                                                     |
           v Static Linking (-static)                                            v Dynamic Linking (-Wl,-rpath)
+------------------------------------+                                +------------------------------------+
| Self-contained Monolithic Binary   |                                | Binary + Dynamic Dependencies      |
+------------------------------------+                                | (.so libraries via ld-linux.so)    |
                                                                      +------------------------------------+
```

#### La Mecánica de la Cadena de Herramientas (Toolchain) de GNU Autotools
1. **Ejecución del Shell Script `./configure`:**
   El script `./configure` se genera mediante Autoconf. Realiza una introspección del sistema (verificando los header files disponibles, APIs del kernel, características del compilador y librerías de dependencias).
   - Genera `config.log` (logs detallados de diagnóstico de compilación).
   - Genera `config.status` (un script ejecutable que produce el `Makefile` final a partir de `Makefile.in`).
2. **Inyecciones de Variables Estándar:**
   - `CPPFLAGS`: Incluye flags del preprocesador (ej., `-I/opt/custom/include`).
   - `CFLAGS` / `CXXFLAGS`: Flags de optimización y depuración pasadas a compiladores estándar de C/C++ (ej., `-O2 -g -fstack-protector-strong`).
   - `LDFLAGS`: Flags pasadas directamente al linker `ld` (ej., `-L/opt/custom/lib -Wl,-rpath=/opt/custom/lib`).
   - `--prefix=PREFIX`: Establece el directorio destino base (por defecto `/usr/local`).
   - `DESTDIR`: Se utiliza durante `make install DESTDIR=/tmp/stage` para builds por etapas sin root o para la creación de paquetes binarios (ej., construcción de paquetes `.deb` o `.rpm`).

#### Orden de Resolución de Objetos Compartidos Dinámicos (DSO)
Cuando un ejecutable llama a una librería compartida dinámica (`.so`), el intérprete ELF (`/lib64/ld-linux-x86-64.so.2`) resuelve las dependencias compartidas utilizando el siguiente orden de búsqueda:
1. Etiqueta `DT_RPATH` incrustada en el encabezado del binario ELF (si `DT_RUNPATH` no está configurado).
2. Variable de entorno `LD_LIBRARY_PATH` (evaluada en tiempo de ejecución; anulable).
3. Etiqueta `DT_RUNPATH` incrustada en el encabezado del binario ELF.
4. Caché binario `/etc/ld.so.cache` (generado por `/sbin/ldconfig` al analizar `/etc/ld.so.conf` y `/etc/ld.so.conf.d/*.conf`).
5. Directorios de librerías estándar del sistema: `/lib64`, `/usr/lib64`.

---

### 1.2 Mecánica de Backup, Transferencias Delta y Consistencia de Snapshots

#### Compromisos entre Backup Full, Incremental y Diferencial

| Parámetro | Backup Full | Backup Diferencial | Backup Incremental |
| :--- | :--- | :--- | :--- |
| **Alcance de los Datos** | Todo el conjunto de datos designado | Todos los cambios desde el *último backup Full* | Todos los cambios desde el *último backup de cualquier tipo* |
| **Velocidad de Backup** | Más lenta | Media | Más rápida |
| **Velocidad de Restauración** | Más rápida (Restauración de un solo conjunto de datos) | Media (Full + 1 Diferencial) | Más lenta (Full + N Incrementales Secuenciales) |
| **Uso de Almacenamiento** | Máximo | Moderado | Mínimo |
| **Aislamiento de Fallos**| Alto | Moderado | Bajo (Un fallo en 1 incremental rompe la cadena) |

#### Mecánica del Algoritmo Rolling Checksum de Rsync
Rsync minimiza la transferencia de red utilizando una verificación de hash de dos pasadas:
1. **División de Bloques:** El archivo destino en el sistema de destino se divide en bloques no superpuestos de tamaño $S$ (típicamente de 512 a 2048 bytes).
2. **Dos Checksums por Bloque:**
   - **Rolling Checksum (derivado de Adler-32):** Un algoritmo rápido de 32 bits calculado sobre una ventana deslizante.
   - **Strong Checksum (MD5/MD4):** Un hash criptográficamente fuerte de 128 bits.
3. **Escaneo con Ventana Deslizante:** La máquina de origen calcula el checksum rápido de 32 bits (rolling checksum) para una ventana deslizante de tamaño $S$ a través del archivo de origen byte por byte.
   - Si el checksum rápido de 32 bits coincide con un bloque del destino, el origen calcula el hash fuerte de 128 bits.
   - Si ambos hashes coinciden, el bloque existe en el destino. El origen transmite únicamente el puntero de offset.
   - Si no hay coincidencia, el byte individual se transmite como datos sin procesar (raw data), y la ventana se desliza 1 byte hacia la derecha.

#### Árboles de Snapshots Basados en Hardlinks (`--link-dest`)
Cuando se ejecuta `rsync --link-dest=/backups/backup.0`:
- Rsync compara la metadata (mtime, tamaño, permisos) de los archivos de origen con `/backups/backup.0`.
- Los archivos no modificados se crean en el directorio destino `/backups/backup.1` como **hardlinks** (el contador de referencias de inodo de `inotify`/`stat` se incrementa) apuntando al inodo idéntico en `backup.0`.
- Los archivos modificados se transfieren y se escriben en un nuevo inodo.
- **Resultado:** Proporciona árboles de directorios point-in-time completamente accesibles y aislados mientras ocupa almacenamiento únicamente para los deltas de bloques modificados.

---

### 1.3 Notificaciones del Sistema, IPC e Integración Dinámica de MOTD

#### Mecánica de Mensajería de Terminal de Usuario (`utmp`, `wtmp`, `/dev/pts/*`)
Linux gestiona las sesiones de usuario con sesión iniciada mediante el seguimiento de estructuras binarias:
- `/var/run/utmp`: Rastrea los usuarios actualmente autenticados, sesiones de terminal activas (`/dev/pts/X`) y marcas de tiempo de inicio de sesión.
- `/var/log/wtmp`: Log histórico append-only de inicios y cierres de sesión.
- `/var/log/btmp`: Registra los intentos fallidos de autenticación.

Comandos como `wall` y `write` operan:
1. Iterando a través de `/var/run/utmp` para mapear los usuarios activos a sus dispositivos de pseudo-terminal designados (`/dev/pts/X`).
2. Verificando los permisos de escritura del terminal mediante los bits de modo de archivo en el archivo de dispositivo (gestionados a través de `mesg y` [modo `0620`] o `mesg n` [modo `0600`]).
3. Escribiendo el buffer de mensaje directamente en `/dev/pts/X`.

#### Jerarquía de Notificaciones de Login y Ejecución Dinámica de PAM
```
+------------------------------------------------------------------------------------+
| System Login Event (Console / SSH / TTY)                                           |
+------------------------------------------------------------------------------------+
                                         |
                                         v
+------------------------------------------------------------------------------------+
| 1. Pre-Authentication Display: /etc/issue (Local TTY) or /etc/issue.net (SSH)       |
+------------------------------------------------------------------------------------+
                                         |
                                         v
+------------------------------------------------------------------------------------+
| 2. Authentication Stage (PAM Stack Processing)                                     |
+------------------------------------------------------------------------------------+
                                         |
                                         v
+------------------------------------------------------------------------------------+
| 3. Post-Authentication Stage: pam_motd.so                                          |
|    - Executes /etc/update-motd.d/* executable scripts in numerical order           |
|    - Aggregates stdout into dynamic runtime file /run/motd.dynamic                 |
|    - Appends contents of static file /etc/motd (if present)                        |
+------------------------------------------------------------------------------------+
                                         |
                                         v
+------------------------------------------------------------------------------------+
| User Interactive Shell Spawned ($SHELL)                                           |
+------------------------------------------------------------------------------------+
```

---

## 2. Laboratorios Prácticos Guiados de Producción y Preguntas de Verificación

### Ejercicio 1: Compilación de Código Fuente Personalizada, Parcheo, Aislamiento de Prefijos y Gestión de Librerías Compartidas

#### Objetivo
Descargar, desempaquetar, parchear, compilar y aislar una herramienta open-source moderna (`memcached`) en un prefijo de producción no estándar (`/opt/services/memcached`), configurar rpaths personalizados y verificar las dependencias de enlaces dinámicos sin contaminar los directorios estándar del sistema.

#### Paso 1: Preparar el Espacio de Trabajo Sandbox y Obtener Archivos Fuente
Ejecutá los siguientes comandos para crear un espacio de trabajo de build aislado y descargar los archivos fuente:

```bash
mkdir -p /tmp/build-workspace/src
cd /tmp/build-workspace/src

# Create a sample bugfix patch file simulating an SRE security/logging hotfix
cat << 'EOF' > /tmp/build-workspace/src/sre_custom_logging.patch
--- a/memcached.c	2023-01-01 00:00:00.000000000 +0000
+++ b/memcached.c	2023-01-01 00:00:05.000000000 +0000
@@ -1,5 +1,6 @@
 /* SRE Production Hotfix Hook */
 #include <stdio.h>
+/* Custom SRE Audit Log Initialization */
 EOF

# Download libevent (dependency) and memcached source tarballs
curl -sSL -O https://github.com/libevent/libevent/releases/download/release-2.1.12-stable/libevent-2.1.12-stable.tar.gz
curl -sSL -O https://memcached.org/files/memcached-1.6.22.tar.gz

# Extract archives using tar with verbose output and gzip decompression
tar -zxvf libevent-2.1.12-stable.tar.gz
tar -zxvf memcached-1.6.22.tar.gz
```

*Salida Esperada (Truncada):*
```text
libevent-2.1.12-stable/
libevent-2.1.12-stable/configure
...
memcached-1.6.22/
memcached-1.6.22/memcached.c
memcached-1.6.22/configure
```

#### Paso 2: Compilar la Librería de Dependencia con Prefijo de Aislamiento
Compilá `libevent` e instalalo en `/opt/services/libevent`:

```bash
cd /tmp/build-workspace/src/libevent-2.1.12-stable

# Configure with custom prefix
./configure --prefix=/opt/services/libevent --disable-static

# Compile utilizing all available CPU cores
make -j$(nproc)

# Perform staged target installation
make install
```

*Salida Esperada (Truncada):*
```text
config.status: creating Makefile
...
Libraries have been installed in:
   /opt/services/libevent/lib
```

#### Paso 3: Aplicar el Parche y Compilar la Aplicación con Flags de Linker Personalizadas
Navegá a `memcached`, aplicá el parche y construí con las variables de entorno del linker enlazando contra `/opt/services/libevent`:

```bash
cd /tmp/build-workspace/src/memcached-1.6.22

# Apply patch cleanly with dry-run verification first
patch -p1 --dry-run < /tmp/build-workspace/src/sre_custom_logging.patch
patch -p1 < /tmp/build-workspace/src/sre_custom_logging.patch

# Set C preprocessor, Linker, and RPATH options
export CPPFLAGS="-I/opt/services/libevent/include"
export LDFLAGS="-L/opt/services/libevent/lib -Wl,-rpath=/opt/services/libevent/lib"

# Configure memcached pointing to the dependency prefix
./configure --prefix=/opt/services/memcached --with-libevent=/opt/services/libevent

# Build and Install
make -j$(nproc)
make install
```

*Salida Esperada (Truncada):*
```text
checking for libevent directory... /opt/services/libevent
config.status: creating Makefile
...
make[1]: Leaving directory '/tmp/build-workspace/src/memcached-1.6.22'
Installing /opt/services/memcached/bin/memcached
```

#### Paso 4: Verificar el Encabezado de Ejecución del Binario ELF y el Enlace Dinámico
Inspeccioná el binario ELF generado para verificar la inclusión del rpath y la resolución de dependencias:

```bash
# Verify shared library resolution via ldd
ldd /opt/services/memcached/bin/memcached

# Read ELF dynamic tag section using readelf
readelf -d /opt/services/memcached/bin/memcached | grep -E "(RPATH|RUNPATH|NEEDED)"
```

*Salida Esperada:*
```text
	linux-vdso.so.1 (0x00007ffc91bfe000)
	libevent-2.1.so.6 => /opt/services/libevent/lib/libevent-2.1.so.6 (0x00007f3a8b4a2000)
	libc.so.6 => /lib64/libc.so.6 (0x00007f3a8b200000)
 0x0000000000000001 (NEEDED)             Shared library: [libevent-2.1.so.6]
 0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]
 0x000000000000000f (RPATH)              Library rpath: [/opt/services/libevent/lib]
```

---

#### Preguntas de Verificación — Ejercicio 1

1. **Pregunta 1.1:** ¿Cuál es la diferencia operativa fundamental entre pasar `-L/path/to/lib` durante la compilación versus incrustar `-Wl,-rpath=/path/to/lib` en el binario?
2. **Pregunta 1.2:** Si se ejecuta `make install` con `DESTDIR=/tmp/pkg-root`, ¿en qué ruta exacta termina el binario considerando `--prefix=/opt/app`, y cuál es el propósito técnico de `DESTDIR`?
3. **Pregunta 1.3:** Supongamos que `ldd /opt/services/memcached/bin/memcached` devuelve `libevent-2.1.so.6 => not found` en una máquina donde `LD_LIBRARY_PATH` está vacío y `/etc/ld.so.conf` no contiene `/opt/services/libevent/lib`. ¿Cómo puede un operador solucionar esto dinámicamente sin recompilar ni modificar archivos globales del sistema?

---

### Ejercicio 2: Backups Automatizados de Rsync Point-in-Time con Consistencia de Snapshots LVM y Cifrado GPG

#### Objetivo
Configurar una estrategia de backup consistente a nivel de bloques y sin tiempo de inactividad (zero-downtime). Crear un volumen lógico LVM simulado que albergue datos de producción, ejecutar un snapshot de LVM para garantizar la integridad transaccional, realizar un backup incremental diferencial con hardlinks eficiente en espacio utilizando `rsync --link-dest`, y comprimir/cifrar la salida mediante claves GPG para un archivado remoto seguro.

#### Paso 1: Crear el Grupo de Volúmenes Simulado y la Partición de Almacenamiento de Producción
Configurá un dispositivo loopback para simular almacenamiento físico, configurá un Grupo de Volúmenes LVM (`vg_data`) y formateá un volumen de producción (`lv_prod`):

```bash
# Create a 2GB storage file to simulate a disk
dd if=/dev/zero of=/tmp/disk_backend.img bs=1M count=2048 status=none

# Attach storage file as a loopback device
LOOP_DEV=$(losetup --find --show /tmp/disk_backend.img)
echo "Attached loop device: ${LOOP_DEV}"

# Create LVM Physical Volume and Volume Group
pvcreate ${LOOP_DEV}
vgcreate vg_data ${LOOP_DEV}

# Create a 1GB Logical Volume for Production Data
lvcreate -L 1G -n lv_prod vg_data

# Format with ext4 and mount
mkfs.ext4 -q /dev/vg_data/lv_prod
mkdir -p /mnt/production_data
mount /dev/vg_data/lv_prod /mnt/production_data

# Populate production data
echo "Critical Transaction Log 1" > /mnt/production_data/db_log_1.txt
echo "Critical Config File" > /mnt/production_data/app_config.json
dd if=/dev/urandom of=/mnt/production_data/blob_data.bin bs=1M count=50 status=none
```

*Salida Esperada:*
```text
Attached loop device: /dev/loop0
  Physical volume "/dev/loop0" successfully created.
  Volume group "vg_data" successfully created.
  Logical volume "lv_prod" created.
```

#### Paso 2: Realizar la Creación de un Snapshot LVM Consistente
Pausá cualquier operación de I/O pendiente en el sistema de archivos y tomá un snapshot LVM (`lv_prod_snap`):

```bash
# Create a 250MB snapshot volume
lvcreate -L 250M --snapshot --name lv_prod_snap /dev/vg_data/lv_prod

# Mount snapshot volume read-only
mkdir -p /mnt/snapshot_raw
mount -o ro /dev/vg_data/lv_prod_snap /mnt/snapshot_raw

# Verify snapshot block mapping status
lvs /dev/vg_data/lv_prod_snap
```

*Salida Esperada:*
```text
  LV           VG      Attr       LSize   Pool Origin  Data%  Meta%  Move Log Cpy%Sync Log%
  lv_prod_snap vg_data swi-a-s--- 250.00m      lv_prod 0.05
```

#### Paso 3: Implementar Backups Multigeneracionales de Rsync Eficientes en Espacio (`--link-dest`)
Construí un árbol de snapshots incrementales point-in-time automatizado utilizando hardlinks de `rsync`:

```bash
# Define backup repository base
mkdir -p /backups/repository/daily.0

# Initial Full Backup (daily.0)
rsync -aHAX --delete /mnt/snapshot_raw/ /backups/repository/daily.0/

# Unmount and drop snapshot
umount /mnt/snapshot_raw
lvremove -y /dev/vg_data/lv_prod_snap

# Modify production data to simulate new changes (Day 2)
echo "Critical Transaction Log 2" > /mnt/production_data/db_log_2.txt
rm /mnt/production_data/db_log_1.txt

# Create new snapshot for Day 2 backup
lvcreate -L 250M --snapshot --name lv_prod_snap /dev/vg_data/lv_prod
mount -o ro /dev/vg_data/lv_prod_snap /mnt/snapshot_raw

# Rotate backup generations
mv /backups/repository/daily.0 /backups/repository/daily.1

# Execute Incremental Backup using --link-dest referencing daily.1
rsync -aHAX --delete --link-dest=/backups/repository/daily.1 /mnt/snapshot_raw/ /backups/repository/daily.0/

# Clean up snapshot
umount /mnt/snapshot_raw
lvremove -y /dev/vg_data/lv_prod_snap
```

*Salida Esperada:*
```text
  Logical volume "lv_prod_snap" successfully removed
  Logical volume "lv_prod_snap" created.
  Logical volume "lv_prod_snap" successfully removed
```

#### Paso 4: Verificar la Compartición de Inodos y la Eficiencia del Almacenamiento con Hardlinks
Verificá que los archivos no modificados en `daily.0` compartan inodos con `daily.1`, mientras que los archivos modificados ocupen inodos independientes:

```bash
# Inspect inode numbers of unchanged binary blob across backups
ls -i /backups/repository/daily.1/blob_data.bin
ls -i /backups/repository/daily.0/blob_data.bin

# Check disk space consumption (Notice total size vs actual disk usage)
du -sh /backups/repository/*
du -sh --apparent-size /backups/repository/*
```

*Salida Esperada:*
```text
1052673 /backups/repository/daily.1/blob_data.bin
1052673 /backups/repository/daily.0/blob_data.bin
51M	/backups/repository/daily.0
4.0K	/backups/repository/daily.1
51M	total
```

#### Paso 5: Cifrado en Streaming para Transferencia Remota
Transmití `daily.0` a través de `tar`, cifralo con GPG usando `AES256` y verificá la integridad del archivo:

```bash
# Compress and symmetrically encrypt stream on the fly
tar -cf - -C /backups/repository/daily.0 . | \
  gpg --batch --yes --symmetric --cipher-algo AES256 --passphrase "SuperSecretSREPassphrase123" \
  -o /backups/offsite_archive_$(date +%F).tar.gpg

# Test decryption stream without writing to disk
gpg --batch --yes --decrypt --passphrase "SuperSecretSREPassphrase123" \
  /backups/offsite_archive_$(date +%F).tar.gpg | tar -tzf - | head -n 5
```

*Salida Esperada:*
```text
./
./db_log_2.txt
./app_config.json
./blob_data.bin
```

---

#### Preguntas de Verificación — Ejercicio 2

1. **Pregunta 2.1:** ¿Qué sucede con un snapshot LVM activo si el espacio de volumen asignado a él (ej., 250MB en nuestro laboratorio) experimenta más cambios de bloques en el volumen de origen (`lv_prod`) de los que la capacidad asignada puede almacenar?
2. **Pregunta 2.2:** En el comando `rsync`, ¿por qué es crítico que `--link-dest` utilice una ruta absoluta o una ruta relativa al directorio *destino* en lugar del directorio de trabajo en ejecución?
3. **Pregunta 2.3:** ¿Por qué las flags `-H`, `-A` y `-X` se incluyen explícitamente en los scripts de backup de producción de SRE que utilizan `rsync` o `tar`?

---

### Ejercicio 3: Motor MOTD Dinámico Basado en PAM, Notificaciones de Emergencia del Sistema y Aislamiento de Terminales

#### Objetivo
Configurar advertencias legales previas al inicio de sesión a nivel de todo el sistema, construir un script dinámico de Message of the Day (MOTD) posterior a la autenticación que reporte el estado de salud del sistema y del backup mediante Linux PAM, y ejecutar notificaciones dirigidas o de transmisión general (broadcast) a los usuarios utilizando `wall` y `write`.

#### Paso 1: Configurar Advertencias Previas al Inicio de Sesión (`/etc/issue` y `/etc/issue.net`)
Configurá banners de advertencia utilizando secuencias de escape para TTYs locales y clientes SSH remotos:

```bash
# Backup original banners
cp /etc/issue /etc/issue.bak
cp /etc/issue.net /etc/issue.net.bak

# Set local TTY issue banner with escape sequences (\n = node name, \l = tty line, \t = time)
cat << 'EOF' > /etc/issue
*******************************************************************
* AUTHORIZED USE ONLY!                                            *
* Hostname: \n  | Line: \l | System Time: \t                     *
*******************************************************************
EOF

# Set remote network SSH banner (Plain text without local escape codes)
cat << 'EOF' > /etc/issue.net
*******************************************************************
* AUTHORIZED ACCESS ONLY - ALL ACTIVITIES ARE LOGGED AND MONITORED *
*******************************************************************
EOF
```

#### Paso 2: Construir un Script de Generación de MOTD Dinámico para PAM
Creá un script personalizado dentro de `/etc/update-motd.d/` que emita dinámicamente las estadísticas del sistema al iniciar sesión el usuario:

```bash
# Ensure update-motd directory exists
mkdir -p /etc/update-motd.d

# Create script 99-sre-health-status
cat << 'EOF' > /etc/update-motd.d/99-sre-health-status
#!/bin/bash
# Description: Custom SRE Production Status Generator

echo ""
echo "=== SRE PLATFORM HEALTH STATUS ==="
echo "Host: $(hostname -f)"
echo "Uptime: $(uptime -p)"
echo "Kernel: $(uname -r)"
echo "Memory Usage: $(free -m | awk '/Mem:/ { printf "%3.1f%%", $3/$2*100 }')"
echo "Root FS Usage: $(df -h / | awk 'NR==2 {print $5}')"

# Check backup integrity state
if [ -f /backups/offsite_archive_$(date +%F).tar.gpg ]; then
    echo "Backup Status: [ OK ] Today's offsite encrypted archive present."
else
    echo "Backup Status: [ WARNING ] No encrypted backup found for $(date +%F)!"
fi
echo "=================================="
echo ""
EOF

# Grant execution permissions (Mandatory for PAM processing)
chmod +x /etc/update-motd.d/99-sre-health-status
```

#### Paso 3: Configurar PAM para Procesar el MOTD Dinámico
Verificá y actualizá los bloques de configuración `/etc/pam.d/sshd` y `/etc/pam.d/login` para asegurar que `pam_motd.so` ejecute la pila (stack) de MOTD dinámico:

```bash
# Inspect PAM configuration for pam_motd calls
grep -E "pam_motd" /etc/pam.d/sshd /etc/pam.d/login
```

*Snippet de Configuración Esperado (`/etc/pam.d/sshd`):*
```text
session    optional     pam_motd.so motd=/run/motd.dynamic
session    optional     pam_motd.so noupdate
```

#### Paso 4: Activar Manualmente la Regeneración del MOTD Dinámico
Proba el script manualmente invocando `run-parts` sobre la carpeta del MOTD dinámico:

```bash
# Execute scripts in numerical order and dump output to /run/motd.dynamic
run-parts /etc/update-motd.d/ > /run/motd.dynamic
cat /run/motd.dynamic
```

*Salida Esperada:*
```text
=== SRE PLATFORM HEALTH STATUS ===
Host: production-node-1.internal
Uptime: up 4 hours, 12 minutes
Kernel: 5.14.0-362.8.1.el9_3.x86_64
Memory Usage: 14.2%
Root FS Usage: 22%
Backup Status: [ OK ] Today's offsite encrypted archive present.
==================================
```

#### Paso 5: Ejecutar Notificaciones de Transmisión de Emergencia y Probar el Aislamiento de Terminales
Simulá comunicación de mantenimiento de emergencia SRE a todas las terminales activas usando `wall`, luego probá el aislamiento de escritura en terminal a través de `mesg`:

```bash
# Send system-wide emergency broadcast message
wall "URGENT: Emergency Kernel Patching starting in 5 minutes. Save your work!"

# Verify current terminal write status
mesg

# Disable messages to current terminal session
mesg n
mesg

# Enable messages to current terminal session
mesg y
```

*Salida Esperada:*
```text
Broadcast message from root@production-node-1 (pts/0) (Thu Aug 06 10:25:21 2026):

URGENT: Emergency Kernel Patching starting in 5 minutes. Save your work!

is y
is n
is y
```

---

#### Preguntas de Verificación — Ejercicio 3

1. **Pregunta 3.1:** ¿Por qué `/etc/issue.net` evita el uso de códigos de escape especiales de terminal (tales como `\n`, `\l`, `\t`), mientras que `/etc/issue` los utiliza por estándar?
2. **Pregunta 3.2:** Si un script ubicado en `/etc/update-motd.d/50-custom` tiene permisos `0644` (`-rw-r--r--`), ¿cómo responderá `pam_motd.so` cuando un usuario inicie sesión?
3. **Pregunta 3.3:** ¿Puede un usuario que no sea root bloquear notificaciones de transmisión de emergencia del sistema emitidas por `root` usando `wall` ejecutando `mesg n` en su sesión de shell TTY? Explicá el mecanismo subyacente del kernel/permisos.

---

## 3. Clave de Respuestas y Soluciones Detalladas

<details>
<summary>Hacé clic para desplegar la clave de respuestas y explicaciones técnicas</summary>

### Soluciones del Ejercicio 1

- **Respuesta 1.1:**  
  `-L/path/to/lib` es una directiva en **tiempo de compilación/enlazado**. Le indica al linker (`ld`) dónde encontrar definiciones de símbolos de objetos compartidos dinámicos (`.so`) durante la fase de compilación. Una vez que la compilación se completa, la información de `-L` se descarta.  
  `-Wl,-rpath=/path/to/lib` es una directiva en **tiempo de ejecución**. Incrusta un atributo explícito `DT_RPATH` o `DT_RUNPATH` dentro del encabezado del binario ELF compilado. Al momento de la ejecución del binario, el cargador dinámico (`ld-linux.so`) utiliza esta cadena incrustada para localizar dependencias compartidas sin depender de configuraciones externas del entorno del sistema.

- **Respuesta 1.2:**  
  El binario se ubicará en `/tmp/pkg-root/opt/app/bin/binary_name`.  
  El propósito de `DESTDIR` es admitir instalaciones por etapas sin privilegios de root. Antepone un directorio raíz alternativo a todas las rutas de instalación de destino. Esto permite a los creadores de paquetes (RPM, DEB) ensamblar la jerarquía completa de directorios del sistema de archivos dentro de un sandbox sin sobrescribir archivos reales del sistema ni requerir privilegios de `root` durante los pasos de compilación.

- **Respuesta 1.3:**  
  Establecer la variable de entorno `LD_LIBRARY_PATH` inline al ejecutar el binario:  
  `LD_LIBRARY_PATH=/opt/services/libevent/lib /opt/services/memcached/bin/memcached`  
  Alternativamente, agregar `/opt/services/libevent/lib` a un nuevo archivo de configuración en `/etc/ld.so.conf.d/memcached.conf` y ejecutar `ldconfig` como root.

---

### Soluciones del Ejercicio 2

- **Respuesta 2.1:**  
  Cuando se crea un snapshot LVM, se asigna una tabla de mapeo de bloques de metadata Copy-on-Write (CoW). Si el espacio CoW asignado al snapshot se llena por completo (100% de uso), el snapshot se invalida. El kernel descarta el objetivo del snapshot, invalida el volumen lógico del snapshot, lo marca como "INACTIVE" y las lecturas de I/O en el punto de montaje del snapshot fallarán con errores de Input/Output (`EIO`).

- **Respuesta 2.2:**  
  `rsync` evalúa las rutas de `--link-dest` **de manera relativa al directorio de destino**, no al directorio de trabajo actual desde el cual se ejecuta el comando. Si se proporciona una ruta relativa como `--link-dest=daily.1` mientras el argumento de destino es `/backups/repository/daily.0`, `rsync` busca correctamente en `/backups/repository/daily.0/../daily.1` (lo que se resuelve como `/backups/repository/daily.1`). Pasar una ruta incorrecta provoca que `rsync` falle silenciosamente en coincidir con archivos existentes, convirtiendo la operación en un backup full redundante.

- **Respuesta 2.3:**  
  - `-H` (`--hard-links`): Preserva los hardlinks entre archivos. Sin esto, los archivos enlazados mediante hardlinks se expanden en archivos duplicados separados en el destino, disparando el uso de almacenamiento.
  - `-A` (`--acls`): Preserva las Listas de Control de Acceso (ACLs) de POSIX adjuntas a archivos/directorios.
  - `-X` (`--xattrs`): Preserva los Atributos Extendidos (tales como contextos de seguridad SELinux `security.selinux` o capacidades del sistema de archivos `security.capability`).

---

### Soluciones del Ejercicio 3

- **Respuesta 3.1:**  
  `/etc/issue` es analizado directamente por el proceso local de terminal `getty` / `agetty`, el cual interpreta nativamente los caracteres de escape locales (`\n`, `\l`, etc.).  
  `/etc/issue.net` se envía sobre protocolos de red (como SSH a través de `sshd`). La RFC 4253 especifica que los payloads de autenticación del banner SSH deben ser cadenas de texto raw UTF-8. `sshd` no analiza los códigos de escape locales de `getty`; enviarlos sin analizar directamente a los clientes remotos mostraría cadenas de escape literales sin procesar (ej., `\n \l`) en el cliente de terminal SSH.

- **Respuesta 3.2:**  
  `pam_motd.so` invoca a `run-parts` para descubrir scripts en `/etc/update-motd.d/`. `run-parts` filtra estrictamente los archivos y ejecuta **únicamente los archivos que tienen activado el bit de permiso de ejecución** (`+x`). Si un script tiene permisos `0644`, `pam_motd.so` lo ignorará y su contenido de stdout no se incluirá en `/run/motd.dynamic`.

- **Respuesta 3.3:**  
  **No.** Los comandos `wall` (write all) emitidos por `root` eluden las verificaciones de permisos de terminal del usuario.  
  Ejecutar `mesg n` elimina los permisos de escritura para los usuarios no-root al cambiar los permisos del dispositivo `/dev/pts/X` al modo `0600` (perteneciente al usuario que inició sesión). Sin embargo, dado que `root` posee la capacidad `CAP_DAC_OVERRIDE`, el kernel permite a los procesos de `root` eludir los modos de permiso de archivos y escribir directamente en cualquier dispositivo de caracteres pseudo-terminal (`/dev/pts/*`) independientemente del estado de `mesg`.

</details>