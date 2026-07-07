# 4.3 Where Data is Stored (Dónde se almacenan los datos)

**Certificación:** LPI Linux Essentials (010-160, versión 1.6)
**Peso en el examen:** 3

---

## Introducción

En Linux, "todo es un archivo": la configuración del sistema, los logs, los programas, las librerías e incluso la información sobre el hardware y los procesos en ejecución se representan como archivos dentro de una jerarquía única de directorios que comienza en la raíz (`/`). Este tema cubre **dónde vive cada tipo de dato** en esa jerarquía, cómo el kernel expone información del sistema, cómo consultar procesos y memoria, y cómo funciona el sistema de logging.

Los objetivos del examen incluyen: **programs, libraries, packages y package databases, system configuration, processes, memory addresses, system messaging y logging**. Las utilidades clave son: `ps`, `top`, `free`, `dmesg`, y los directorios `/etc`, `/var/log`, `/boot`, `/proc`, `/dev`, `/sys`, `/lib`, `/usr/lib`.

---

## 1. La jerarquía de directorios y el FHS

El **Filesystem Hierarchy Standard (FHS)** define qué debe contener cada directorio del sistema. Los más relevantes para este objetivo:

| Directorio | Contenido |
|---|---|
| `/boot` | Kernel (`vmlinuz-*`), `initrd`/`initramfs` y archivos del bootloader (GRUB) |
| `/etc` | Configuración del sistema (archivos de texto) |
| `/bin`, `/usr/bin` | Binarios (programas) para todos los usuarios |
| `/sbin`, `/usr/sbin` | Binarios de administración del sistema |
| `/lib`, `/usr/lib` | Shared libraries (librerías compartidas) y módulos del kernel |
| `/var` | Datos variables: logs, colas de correo, caches, bases de datos |
| `/var/log` | Archivos de log del sistema |
| `/proc` | Filesystem virtual: procesos y parámetros del kernel |
| `/sys` | Filesystem virtual: dispositivos y drivers (exportado por el kernel) |
| `/dev` | Archivos de dispositivo (device files) |
| `/home` | Directorios personales de los usuarios |
| `/tmp` | Archivos temporales (suele vaciarse al reiniciar) |

En muchas distribuciones modernas, `/bin`, `/sbin` y `/lib` son enlaces simbólicos a sus equivalentes bajo `/usr` (el llamado *usr merge*):

```bash
$ ls -ld /bin /lib
lrwxrwxrwx. 1 root root 7 may 12 10:01 /bin -> usr/bin
lrwxrwxrwx. 1 root root 7 may 12 10:01 /lib -> usr/lib
```

---

## 2. Programas, librerías y paquetes

### 2.1 Programas (binarios)

Los ejecutables se ubican principalmente en `/usr/bin` (uso general) y `/usr/sbin` (administración). Para localizar un programa:

```bash
$ which ps
/usr/bin/ps

$ type cd
cd is a shell builtin
```

### 2.2 Shared libraries

Las **librerías compartidas** (shared objects, extensión `.so`) contienen código reutilizado por muchos programas, lo que evita duplicación en disco y en memoria. Viven en `/lib`, `/usr/lib` (y variantes como `/usr/lib64`). El nombre típico incluye versión: `libc.so.6`.

El comando `ldd` muestra qué librerías necesita un binario:

```bash
$ ldd /usr/bin/ls
        linux-vdso.so.1 (0x00007ffd5b5fe000)
        libselinux.so.1 => /lib64/libselinux.so.1 (0x00007f2a1c000000)
        libc.so.6 => /lib64/libc.so.6 (0x00007f2a1be00000)
        ...
```

La librería más importante es la **C standard library** (`glibc`), de la que dependen casi todos los programas del sistema.

### 2.3 Paquetes y bases de datos de paquetes

El software se instala mediante **packages** gestionados por un package manager. Cada familia de distribuciones mantiene su propia **package database**, que registra qué paquetes están instalados y qué archivos pertenecen a cada uno:

- **Debian/Ubuntu:** paquetes `.deb`, herramientas `dpkg` y `apt`. Base de datos en `/var/lib/dpkg`.
- **Red Hat/Fedora/SUSE:** paquetes `.rpm`, herramientas `rpm`, `dnf`/`yum`, `zypper`. Base de datos en `/var/lib/rpm`.

Ejemplos de consulta a la base de datos:

```bash
# Debian/Ubuntu: ¿a qué paquete pertenece un archivo?
$ dpkg -S /usr/bin/ls
coreutils: /usr/bin/ls

# RPM: idem
$ rpm -qf /usr/bin/ls
coreutils-9.4-6.fc40.x86_64
```

Notá el patrón: las bases de datos de paquetes están en `/var/lib`, porque son **datos variables** que cambian con cada instalación o actualización.

---

## 3. Configuración del sistema: `/etc`

`/etc` contiene la configuración de todo el sistema, casi siempre en **archivos de texto plano** editables. Algunos ejemplos clásicos:

| Archivo | Función |
|---|---|
| `/etc/passwd` | Cuentas de usuario (nombre, UID, GID, home, shell) |
| `/etc/shadow` | Contraseñas cifradas (solo legible por root) |
| `/etc/group` | Grupos del sistema |
| `/etc/hostname` | Nombre del equipo |
| `/etc/hosts` | Resolución de nombres local |
| `/etc/fstab` | Filesystems a montar al arrancar |
| `/etc/os-release` | Identificación de la distribución |

Ejemplo — una línea de `/etc/passwd`:

```bash
$ grep carol /etc/passwd
carol:x:1000:1000:Carol Smith:/home/carol:/bin/bash
```

Los campos, separados por `:`, son: usuario, contraseña (la `x` indica que está en `/etc/shadow`), UID, GID, comentario/GECOS, directorio home y shell de login.

> **Importante para el examen:** las contraseñas *no* están en `/etc/passwd` sino en `/etc/shadow`, que solo root puede leer.

La configuración **por usuario** no va en `/etc`, sino en archivos ocultos (dotfiles) dentro del home de cada usuario, por ejemplo `~/.bashrc`.

---

## 4. El kernel y los filesystems virtuales

### 4.1 `/proc` — procesos y kernel

`/proc` es un **filesystem virtual**: sus archivos no existen en disco, el kernel los genera al vuelo cuando se leen. Contiene:

- Un subdirectorio numérico por cada proceso (`/proc/1234/`), con su línea de comandos (`cmdline`), entorno, archivos abiertos, etc.
- Archivos con información global del sistema:

```bash
$ cat /proc/cpuinfo | head -5
processor       : 0
vendor_id       : GenuineIntel
cpu family      : 6
model           : 158
model name      : Intel(R) Core(TM) i7-8550U CPU @ 1.80GHz

$ head -3 /proc/meminfo
MemTotal:       16114496 kB
MemFree:         2378964 kB
MemAvailable:    9058232 kB
```

Otros archivos útiles: `/proc/version` (versión del kernel), `/proc/partitions`, `/proc/interrupts`, `/proc/ioports`, `/proc/dma` (recursos de hardware: interrupciones, puertos de E/S y canales DMA).

Los parámetros ajustables del kernel viven en `/proc/sys` y se administran con `sysctl`:

```bash
$ cat /proc/sys/net/ipv4/ip_forward
0
```

### 4.2 `/sys` — dispositivos y drivers

`/sys` (sysfs) es otro filesystem virtual, más estructurado que `/proc`, donde el kernel expone **dispositivos, buses y drivers**. Por ejemplo, `/sys/block` lista los dispositivos de bloque, y `/sys/class/net` las interfaces de red.

### 4.3 `/dev` — device files

`/dev` contiene los **archivos de dispositivo** con los que los programas acceden al hardware:

- **Block devices:** discos y particiones, p. ej. `/dev/sda`, `/dev/sda1`, `/dev/nvme0n1p1`.
- **Character devices:** terminales, ratón, etc., p. ej. `/dev/tty1`.
- **Pseudo-devices:** `/dev/null` (descarta todo lo escrito), `/dev/zero` (devuelve bytes cero), `/dev/urandom` (datos aleatorios).

```bash
$ ls -l /dev/sda /dev/null
brw-rw----. 1 root disk 8, 0 jul  7 08:15 /dev/sda
crw-rw-rw-. 1 root root 1, 3 jul  7 08:15 /dev/null
```

La `b` inicial indica block device y la `c`, character device.

---

## 5. Procesos

Un **proceso** es un programa en ejecución. Cada proceso tiene un **PID** (Process ID) único y un **PPID** (Parent Process ID, el proceso que lo creó). El primer proceso que arranca el kernel es el *init system* (habitualmente `systemd`), con PID 1, del que descienden todos los demás.

### 5.1 `ps` — foto instantánea de los procesos

```bash
# Procesos de la sesión actual
$ ps
    PID TTY          TIME CMD
   2261 pts/0    00:00:00 bash
   3512 pts/0    00:00:00 ps

# Todos los procesos, formato detallado (estilo BSD)
$ ps aux | head -4
USER   PID %CPU %MEM    VSZ   RSS TTY  STAT START   TIME COMMAND
root     1  0.1  0.4 172712 13980 ?   Ss   08:15   0:02 /usr/lib/systemd/systemd
root     2  0.0  0.0      0     0 ?   S    08:15   0:00 [kthreadd]
root     3  0.0  0.0      0     0 ?   I<   08:15   0:00 [rcu_gp]
```

En `ps aux`: `a` muestra procesos de todos los usuarios, `u` agrega columnas de usuario y consumo, `x` incluye procesos sin terminal asociada. Las columnas **VSZ** (memoria virtual asignada) y **RSS** (Resident Set Size, memoria física realmente usada) se ven en el punto 6.

### 5.2 `top` — vista dinámica

`top` muestra los procesos en tiempo real, ordenados por defecto por uso de CPU, y se actualiza cada pocos segundos (se sale con `q`):

```bash
$ top
top - 09:42:11 up  1:27,  1 user,  load average: 0.35, 0.42, 0.38
Tasks: 215 total,   1 running, 214 sleeping,   0 stopped,   0 zombie
%Cpu(s):  2.3 us,  0.8 sy,  0.0 ni, 96.5 id,  0.3 wa, ...
MiB Mem :  15736.8 total,   2323.2 free,   5410.5 used,   8003.1 buff/cache
    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
   1804 carol     20   0 4525640 512340 210044 S   4.7   3.2   3:12.45 firefox
```

Existe también `htop`, una alternativa más visual e interactiva (no siempre instalada por defecto).

---

## 6. Memoria y direcciones de memoria

### 6.1 `free` — estado de la memoria

```bash
$ free -h
               total        used        free      shared  buff/cache   available
Mem:            15Gi       5.3Gi       2.3Gi       420Mi       7.8Gi       8.8Gi
Swap:           8.0Gi          0B       8.0Gi
```

Conceptos clave:

- **total / used / free:** memoria física instalada, usada y sin usar.
- **buff/cache:** memoria que el kernel usa como cache de disco. *No está "ocupada"*: se libera automáticamente si un programa la necesita. Por eso la columna importante es **available** (memoria realmente disponible para nuevas aplicaciones), no `free`.
- **Swap:** espacio en disco (partición o archivo) usado como extensión de la RAM cuando esta se agota. Es mucho más lento que la memoria física.

La opción `-h` (*human readable*) muestra unidades legibles; `-m` y `-g` fuerzan MiB y GiB.

### 6.2 Direcciones de memoria y memoria virtual

Cada proceso trabaja con **direcciones de memoria virtuales**: el kernel, con ayuda de la MMU del procesador, traduce esas direcciones al espacio físico real. Esto aísla a los procesos entre sí (uno no puede leer la memoria de otro) y permite que la suma de memoria virtual asignada (columna **VSZ** de `ps`) supere la RAM física. El mapa de memoria de un proceso puede verse en `/proc/<PID>/maps`.

---

## 7. System messaging y logging

### 7.1 Mensajes del kernel: `dmesg`

Durante el arranque, el kernel escribe mensajes en un buffer circular en memoria (el **kernel ring buffer**): hardware detectado, drivers cargados, errores. Se consulta con `dmesg` (en muchas distribuciones requiere root):

```bash
$ sudo dmesg | head -3
[    0.000000] Linux version 6.8.9-300.fc40.x86_64 ...
[    0.000000] Command line: BOOT_IMAGE=(hd0,gpt2)/vmlinuz-6.8.9 root=UUID=...
[    0.004321] BIOS-provided physical RAM map:

# Filtrar mensajes sobre un disco
$ sudo dmesg | grep sda
[    1.923400] sd 0:0:0:0: [sda] 976773168 512-byte logical blocks
```

Por ser un buffer **circular**, los mensajes más antiguos se sobrescriben cuando se llena. En sistemas con systemd, `journalctl -k` muestra los mismos mensajes del kernel.

### 7.2 Syslog y `/var/log`

El servicio de **syslog** (implementaciones modernas: `rsyslog`, `syslog-ng`) recibe mensajes de los programas del sistema y los clasifica por **facility** (origen: `kern`, `mail`, `auth`, `cron`, ...) y **priority** (gravedad: de `debug` a `emerg`), escribiéndolos en archivos bajo `/var/log`:

| Archivo | Contenido |
|---|---|
| `/var/log/syslog` (Debian/Ubuntu) o `/var/log/messages` (Red Hat) | Mensajes generales del sistema |
| `/var/log/auth.log` (Debian) o `/var/log/secure` (Red Hat) | Autenticación: logins, `sudo`, SSH |
| `/var/log/kern.log` | Mensajes del kernel |
| `/var/log/dmesg` | Copia de los mensajes de arranque |
| `/var/log/boot.log` | Mensajes del proceso de arranque |

Ejemplo de lectura (los logs suelen requerir privilegios):

```bash
$ sudo tail -3 /var/log/auth.log
Jul  7 09:15:02 srv1 sshd[4102]: Accepted publickey for carol from 192.168.1.20 port 51442
Jul  7 09:15:02 srv1 sshd[4102]: pam_unix(sshd:session): session opened for user carol
Jul  7 09:20:31 srv1 sudo:  carol : TTY=pts/0 ; PWD=/home/carol ; COMMAND=/usr/bin/dnf update
```

Para que los logs no crezcan indefinidamente, **logrotate** los rota periódicamente: comprime y archiva los antiguos (`syslog.1`, `syslog.2.gz`, ...) y elimina los más viejos según la configuración de `/etc/logrotate.conf`.

### 7.3 El journal de systemd: `journalctl`

En sistemas con systemd, el daemon `systemd-journald` guarda los logs en formato **binario** (no texto plano), por lo que se consultan con `journalctl`:

```bash
# Todo el journal (paginado)
$ sudo journalctl

# Solo mensajes del kernel (equivale a dmesg)
$ sudo journalctl -k

# Mensajes de una unidad/servicio
$ sudo journalctl -u sshd.service

# Seguir mensajes en vivo (como tail -f)
$ sudo journalctl -f

# Desde el arranque actual
$ sudo journalctl -b
```

El journal se almacena en `/run/log/journal` (volátil, se pierde al reiniciar) o en `/var/log/journal` (persistente, si el directorio existe). En muchas distribuciones, journald además reenvía los mensajes a rsyslog, por lo que conviven ambos sistemas.

---

## 8. Resumen para el examen

- **Programas:** `/usr/bin`, `/usr/sbin`. **Librerías compartidas (`.so`):** `/lib`, `/usr/lib` — se inspeccionan con `ldd`.
- **Package databases:** `/var/lib/dpkg` (Debian) y `/var/lib/rpm` (RPM).
- **Configuración del sistema:** `/etc` (texto plano); usuarios en `/etc/passwd`, contraseñas en `/etc/shadow`.
- **Kernel y bootloader:** `/boot`. **Info del kernel y procesos:** `/proc` (virtual). **Dispositivos/drivers:** `/sys`. **Device files:** `/dev`.
- **Procesos:** `ps` (foto), `top` (dinámico); PID 1 es el init system (systemd).
- **Memoria:** `free` (recordar que `buff/cache` se libera bajo demanda y que la columna útil es `available`); swap = RAM en disco; los procesos usan direcciones virtuales.
- **Logging:** `dmesg` / `journalctl -k` para el kernel ring buffer; syslog escribe en `/var/log`; systemd-journald usa formato binario y se lee con `journalctl`; logrotate rota los archivos.

---

## Referencias

- LPI Learning Materials — 010-160, Lesson 4.3 "Where Data is Stored": https://learning.lpi.org/en/learning-materials/010-160/4/4.3/
- Objetivos del examen Linux Essentials 010-160 v1.6: https://www.lpi.org/our-certifications/exam-010-objectives/
- Filesystem Hierarchy Standard (FHS 3.0): https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html
- Documentación del kernel — The /proc Filesystem: https://docs.kernel.org/filesystems/proc.html
- Documentación del kernel — sysfs: https://docs.kernel.org/filesystems/sysfs.html
- man pages online (man7.org): `ps(1)`: https://man7.org/linux/man-pages/man1/ps.1.html · `top(1)`: https://man7.org/linux/man-pages/man1/top.1.html · `free(1)`: https://man7.org/linux/man-pages/man1/free.1.html · `dmesg(1)`: https://man7.org/linux/man-pages/man1/dmesg.1.html · `journalctl(1)`: https://man7.org/linux/man-pages/man1/journalctl.1.html
- rsyslog — documentación oficial: https://www.rsyslog.com/doc/