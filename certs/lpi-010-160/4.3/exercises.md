# Ejercicios guiados — Tema 4.3: Where Data is Stored

**Certificación:** LPI Linux Essentials (010-160, versión 1.6) · **Peso:** 3
**Fuente de referencia:** [LPI Learning Materials — Lesson 4.3](https://learning.lpi.org/en/learning-materials/010-160/4/4.3/)

> 💡 Todos los ejercicios se pueden hacer en cualquier distribución Linux moderna. Algunos comandos requieren privilegios de administrador: usalos con `sudo` cuando se indique. Nada de lo que sigue modifica el sistema.

---

## Ejercicio 1 — Explorar la jerarquía del filesystem (FHS)

Linux organiza todos los archivos en un único árbol que empieza en `/` (el *root directory*). El estándar que define qué va en cada directorio se llama **FHS** (*Filesystem Hierarchy Standard*).

1. Listá el contenido del directorio raíz:
   ```bash
   ls /
   ```
2. Mirá qué tipo de archivos hay en `/bin` (programas esenciales):
   ```bash
   ls /bin | head -20
   ```
3. Comprobá si en tu sistema `/bin` es un enlace simbólico a `/usr/bin` (algo común en distribuciones modernas):
   ```bash
   ls -ld /bin /sbin /usr/bin
   ```
4. Explorá el directorio de configuración del sistema:
   ```bash
   ls /etc | head -20
   ```
5. Mirá tu directorio personal y el de los demás usuarios:
   ```bash
   ls /home
   echo $HOME
   ```

**Preguntas:**

- **1.a)** ¿En qué directorio esperarías encontrar el archivo de configuración global de SSH? ¿Y los binarios que usan todos los usuarios?
- **1.b)** ¿Qué diferencia conceptual hay entre `/bin` y `/sbin`?
- **1.c)** Si un usuario se llama `maria`, ¿cuál es la ruta típica de su *home directory*? ¿Y la del usuario `root`?

---

## Ejercicio 2 — Datos variables y archivos temporales

Los datos que cambian mientras el sistema corre (logs, colas de impresión, cachés) viven en `/var`. Los archivos temporales van a `/tmp`.

1. Listá el contenido de `/var`:
   ```bash
   ls /var
   ```
2. Mirá cuánto espacio ocupa el directorio de logs:
   ```bash
   sudo du -sh /var/log
   ```
3. Creá un archivo temporal y verificá sus permisos:
   ```bash
   touch /tmp/prueba-$USER.txt
   ls -ld /tmp
   ```
4. Observá la `t` al final de los permisos de `/tmp` (por ejemplo `drwxrwxrwt`).

**Preguntas:**

- **2.a)** ¿Por qué los logs se guardan en `/var` y no en `/etc`?
- **2.b)** ¿Qué significa la `t` en los permisos de `/tmp` y para qué sirve?
- **2.c)** ¿Qué le puede pasar al contenido de `/tmp` después de un reinicio?

---

## Ejercicio 3 — Leer los logs del sistema

Los archivos de registro (*log files*) son la primera fuente de información cuando algo falla. Tradicionalmente los escribe el demonio **syslog**; en sistemas con **systemd**, el servicio **journald** mantiene un registro binario que se consulta con `journalctl`.

1. Listá los logs disponibles:
   ```bash
   ls /var/log
   ```
2. Mirá las últimas líneas del log principal del sistema (según tu distribución será uno u otro):
   ```bash
   sudo tail /var/log/syslog      # Debian/Ubuntu
   sudo tail /var/log/messages    # RHEL/Fedora/openSUSE
   ```
3. Consultá el *journal* de systemd:
   ```bash
   sudo journalctl -e
   ```
   (salí con `q`)
4. Filtrá solo los mensajes desde el último arranque:
   ```bash
   sudo journalctl -b | head -20
   ```
5. Mirá los intentos de autenticación:
   ```bash
   sudo tail /var/log/auth.log    # Debian/Ubuntu
   sudo tail /var/log/secure      # RHEL/Fedora
   ```

**Preguntas:**

- **3.a)** ¿Por qué hace falta `sudo` para leer la mayoría de los logs?
- **3.b)** ¿Qué diferencia clave hay entre los logs de texto de `/var/log` y el *journal* de systemd?
- **3.c)** ¿Con qué comando verías los mensajes del kernel generados durante el arranque? Nombrá dos opciones.

---

## Ejercicio 4 — El kernel y los filesystems virtuales `/proc` y `/sys`

`/proc` y `/sys` no contienen archivos reales en disco: son **filesystems virtuales** que el kernel genera en memoria para exponer información del sistema y de los procesos en ejecución.

1. Mirá información de la CPU y de la memoria:
   ```bash
   cat /proc/cpuinfo | head -10
   cat /proc/meminfo | head -5
   ```
2. Verificá la versión del kernel de dos maneras:
   ```bash
   cat /proc/version
   uname -r
   ```
3. Listá los directorios numéricos de `/proc` — cada número es el **PID** de un proceso:
   ```bash
   ls /proc | head -20
   ```
4. Inspeccioná el proceso de tu propia shell:
   ```bash
   echo $$
   ls /proc/$$/
   cat /proc/$$/cmdline; echo
   ```
5. Mirá los mensajes del *ring buffer* del kernel:
   ```bash
   sudo dmesg | head -15
   ```
6. Echale un vistazo a `/sys`, orientado a dispositivos:
   ```bash
   ls /sys/class
   ```

**Preguntas:**

- **4.a)** ¿Cuánto espacio en disco ocupan los archivos de `/proc`? ¿Por qué?
- **4.b)** ¿Qué representa cada directorio con nombre numérico dentro de `/proc`?
- **4.c)** ¿Qué archivo de `/proc` consultarías para saber la cantidad de RAM total del sistema?

---

## Ejercicio 5 — Procesos: `ps` y `top`

Un **proceso** es un programa en ejecución. Cada uno tiene un identificador único (**PID**) y un proceso padre (**PPID**).

1. Mirá los procesos de tu sesión actual:
   ```bash
   ps
   ```
2. Ahora todos los procesos del sistema, con detalle:
   ```bash
   ps aux | head -15
   ```
3. Buscá un proceso concreto:
   ```bash
   ps aux | grep sshd
   ```
4. Abrí el monitor interactivo:
   ```bash
   top
   ```
   Observá las columnas `PID`, `USER`, `%CPU`, `%MEM` y la línea de resumen de memoria. Salí con `q`.
5. Identificá el primer proceso del sistema:
   ```bash
   ps -p 1
   ```

**Preguntas:**

- **5.a)** ¿Qué proceso tiene siempre el PID 1 y cuál es su rol?
- **5.b)** En la salida de `ps aux`, ¿qué indican las columnas `%CPU` y `%MEM`?
- **5.c)** ¿Qué ventaja tiene `top` frente a `ps`?

---

## Ejercicio 6 — Memoria: `free` y la swap

1. Mostrá el uso de memoria en formato legible:
   ```bash
   free -h
   ```
2. Compará con la fuente original de esos datos:
   ```bash
   head -3 /proc/meminfo
   ```
3. Fijate en la fila `Swap` de `free -h` y en las columnas `total`, `used`, `free` y `available`.

**Preguntas:**

- **6.a)** ¿Qué es la memoria *swap* y cuándo la usa el sistema?
- **6.b)** ¿Por qué `available` suele ser mayor que `free`? Pensá en qué hace Linux con la RAM "sobrante".
- **6.c)** ¿De dónde saca `free` su información?

---

## Ejercicio 7 — ¿Quién está y quién estuvo en el sistema?

Algunos registros de acceso no son archivos de texto: se guardan en formato binario y se consultan con comandos específicos.

1. Mirá quién está conectado ahora:
   ```bash
   who
   w
   ```
2. Consultá el historial de logins (lee el archivo binario `/var/log/wtmp`):
   ```bash
   last | head -10
   ```
3. Consultá el último login de cada usuario (lee `/var/log/lastlog`):
   ```bash
   lastlog | head -10
   ```
4. Comprobá que estos archivos no se pueden leer con `cat`:
   ```bash
   file /var/log/wtmp
   ```

**Preguntas:**

- **7.a)** ¿Qué diferencia hay entre `who` y `last`?
- **7.b)** ¿Por qué `cat /var/log/wtmp` muestra caracteres ilegibles?
- **7.c)** ¿Qué comando usarías para saber cuándo fue la última vez que se conectó cada usuario del sistema?

---

## Ejercicio 8 — Rotación de logs

Los logs crecen sin parar; para que no llenen el disco se usa **logrotate**, que los archiva, comprime y elimina según una política.

1. Buscá logs rotados y comprimidos:
   ```bash
   ls /var/log/syslog*      # Debian/Ubuntu
   ls /var/log/messages*    # RHEL/Fedora
   ```
2. Mirá la configuración general de la rotación:
   ```bash
   cat /etc/logrotate.conf | head -20
   ls /etc/logrotate.d/
   ```
3. Leé un log comprimido sin descomprimirlo a disco:
   ```bash
   sudo zcat /var/log/syslog.2.gz 2>/dev/null | head -5
   ```
   (ajustá el nombre según lo que exista en tu sistema)

**Preguntas:**

- **8.a)** ¿Qué problema resuelve la rotación de logs?
- **8.b)** ¿Qué indica típicamente un sufijo como `.1` o `.2.gz` en un archivo de log?

---

<details>
<summary><strong>📖 Respuestas</strong></summary>

### Ejercicio 1

- **1.a)** La configuración global de SSH está en `/etc` (concretamente `/etc/ssh/`), porque `/etc` contiene la configuración del sistema. Los binarios de uso general están en `/usr/bin` (o `/bin`, que en muchas distribuciones modernas es un enlace simbólico a `/usr/bin`).
- **1.b)** `/bin` contiene comandos esenciales para todos los usuarios (`ls`, `cp`, `cat`); `/sbin` contiene binarios de administración del sistema (`fdisk`, `mkfs`, `reboot`), pensados para el usuario `root`.
- **1.c)** El home de `maria` sería `/home/maria`. El de `root` es una excepción: `/root`, no `/home/root`. Esto permite que root pueda iniciar sesión aunque `/home` esté en una partición separada que no montó.

### Ejercicio 2

- **2.a)** `/etc` es para configuración, que cambia poco y la edita el administrador. `/var` está pensado para **datos variables**: archivos que el sistema escribe y hace crecer constantemente (logs, colas, cachés). Separarlos permite, por ejemplo, montar `/var` en una partición aparte para que unos logs descontrolados no llenen la partición raíz.
- **2.b)** La `t` es el **sticky bit**. En un directorio con permisos de escritura para todos (como `/tmp`), hace que cada usuario solo pueda borrar o renombrar **sus propios archivos**, aunque el directorio sea escribible por cualquiera.
- **2.c)** `/tmp` puede vaciarse en cada reinicio (en muchas distribuciones es un filesystem en memoria, `tmpfs`, o se limpia automáticamente). Nunca hay que guardar ahí nada que se quiera conservar.

### Ejercicio 3

- **3.a)** Los logs pueden contener información sensible: nombres de usuario, direcciones IP, intentos de login fallidos, errores de aplicaciones. Por eso solo `root` (o miembros de grupos como `adm` o `systemd-journal`) pueden leerlos.
- **3.b)** Los logs de `/var/log` son archivos de **texto plano** que se leen con `cat`, `less` o `tail`. El *journal* de systemd es un registro **binario e indexado** que se consulta con `journalctl`, lo que permite filtrar por servicio, prioridad, fecha o arranque (`-b`, `-u`, `--since`, etc.).
- **3.c)** Dos opciones: `dmesg` (lee el *ring buffer* del kernel) y `journalctl -k` (muestra solo mensajes del kernel desde el journal). En muchos sistemas también existe el archivo `/var/log/kern.log`.

### Ejercicio 4

- **4.a)** Cero: `/proc` es un **filesystem virtual** (procfs). Sus "archivos" no existen en disco; el kernel genera el contenido en memoria en el momento en que alguien los lee.
- **4.b)** Cada directorio numérico corresponde a un **proceso en ejecución**, y su nombre es el **PID** de ese proceso. Adentro hay información como la línea de comandos (`cmdline`), el entorno (`environ`) y los archivos abiertos (`fd/`).
- **4.c)** `/proc/meminfo` — la línea `MemTotal` indica la RAM total. Comandos como `free` leen justamente ese archivo.

### Ejercicio 5

- **5.a)** El PID 1 corresponde al **init system** — en la mayoría de las distribuciones actuales, `systemd`. Es el primer proceso que lanza el kernel al arrancar y es el ancestro (directo o indirecto) de todos los demás procesos.
- **5.b)** `%CPU` es el porcentaje de tiempo de procesador que consume el proceso; `%MEM` es el porcentaje de la RAM física que ocupa.
- **5.c)** `ps` muestra una **foto estática** del momento en que se ejecuta; `top` es **interactivo y se actualiza en tiempo real**, permite ordenar por CPU o memoria y ver la evolución del sistema.

### Ejercicio 6

- **6.a)** La *swap* es espacio en disco (una partición o un archivo) que el kernel usa como extensión de la RAM: cuando la memoria física se agota, mueve allí páginas de memoria poco usadas. Es mucho más lenta que la RAM.
- **6.b)** Linux usa la RAM libre como **caché de disco** (*buffers/cache*) para acelerar el acceso a archivos. Esa memoria figura como "usada", pero se libera al instante si un programa la necesita. Por eso `available` (memoria realmente disponible para nuevos procesos) es mayor que `free` (memoria sin ningún uso).
- **6.c)** De `/proc/meminfo`, el archivo virtual donde el kernel expone las estadísticas de memoria.

### Ejercicio 7

- **7.a)** `who` muestra los usuarios conectados **en este momento**; `last` muestra el **historial** de inicios y cierres de sesión (y reinicios), leyendo `/var/log/wtmp`.
- **7.b)** Porque `wtmp` es un archivo **binario**, con registros en un formato estructurado, no texto. Se consulta con el comando `last`, no con `cat`.
- **7.c)** `lastlog`, que lee `/var/log/lastlog` y muestra el último login de cada cuenta del sistema (incluidas las que nunca iniciaron sesión).

### Ejercicio 8

- **8.a)** Evita que los logs crezcan indefinidamente y llenen el disco. `logrotate` archiva el log actual, lo comprime, mantiene una cantidad limitada de copias históricas y borra las más antiguas, según la política definida en `/etc/logrotate.conf` y `/etc/logrotate.d/`.
- **8.b)** Son generaciones anteriores del log: `.1` es la rotación más reciente y los números mayores son más antiguos; el sufijo `.gz` indica que además fueron comprimidos con gzip.

</details>

---

**Fuente consultada:** LPI Learning Materials, Lesson 4.3 "Where Data is Stored" — https://learning.lpi.org/en/learning-materials/010-160/4/4.3/