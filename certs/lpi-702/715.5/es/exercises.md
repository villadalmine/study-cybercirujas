# BSD Specialist (702-100) — Tema 715.5: Realizar operaciones básicas de edición de archivos

**Peso del examen:** 3.34  
**Nivel objetivo:** BSD Specialist / Production Systems Engineer  
**Referencia oficial:** [LPI BSD Specialist Overview](https://www.lpi.org/our-certifications/bsd-specialist-overview/)

---

## 1. Architectural & Technical Deep Dive: The BSD `nvi` Engine

En los sistemas operativos BSD modernos (FreeBSD, OpenBSD, NetBSD), el comando predeterminado `/usr/bin/vi` suele estar implementado por **`nvi`** (New VI), la reescritura desde cero ("clean-room") realizada por Keith Bostic del clásico Berkeley `vi`. Comprender la mecánica interna de `nvi` es crítico para los SRE que operan en entornos restringidos de arranque, recuperación y producción.

### 1.1 Memory Architecture and Buffer Recovery
`nvi` no mantiene el archivo completo en el espacio de heap del proceso activo como un simple buffer contiguo. En su lugar, utiliza una estructura de base de datos orientada a líneas respaldada por asignación dinámica de páginas y archivos temporales persistentes.

```
                    +------------------------------------+
                    |        User Terminal (TTY)         |
                    +------------------------------------+
                                      |  ^
                Input (RAW Mode)      |  | Rendering / ANSI escape
                                      v  |
                    +------------------------------------+
                    |       nvi Process Engine           |
                    |  - Command Parser                  |
                    |  - Register Bank (a-z, 1-9, ")     |
                    +------------------------------------+
                                      |
                      Page Cache / Line Pointer Map
                                      |
         +----------------------------+----------------------------+
         v                                                         v
+-------------------------------+                       +-------------------------------+
| Memory-Mapped Working Pages   |                       | Recovery Log Files            |
| (Active buffers in RAM)       |                       | /var/tmp/vi.recover/vi.XXXXXX |
+-------------------------------+                       +-------------------------------+
```

* **Buffer temporal y logs de recuperación:** Al editar un archivo (por ejemplo, `/etc/pf.conf`), `nvi` crea un archivo de recuperación en `/var/tmp/vi.recover/` (o `/tmp`). Cada modificación se escribe en esta base de datos de recuperación mediante un registro de solo anexado ("append-only") sincronizado antes de actualizar el marco visual.
* **Manejo de señales y seguridad ante fallos:** Al recibir `SIGHUP` o `SIGTERM` (por ejemplo, una sesión SSH interrumpida), `nvi` captura la señal, vuelca los cambios no confirmados a `/var/tmp/vi.recover/` y envía una notificación por correo electrónico al usuario a través de `sendmail` o mecanismos de logs del sistema. La sesión se puede reconstruir posteriormente utilizando `vi -r <filename>`.

### 1.2 Modal Execution and State Machine
`nvi` opera como una máquina de estados finitos con tres modos principales:

1. **Command Mode (Modo Normal):** Estado predeterminado al invocar. Las teclas se interpretan como comandos de edición (`d`, `y`, `p`, `u`, `h`, `j`, `k`, `l`).
2. **Insert Mode:** El texto ingresado por el usuario se escribe en el flujo de inserción activo. Se ingresa mediante `i`, `a`, `o`, `O`, `A`, `I`, `c`, `s`. Se regresa a Command Mode a través de `<ESC>`.
3. **Ex Mode / Modo Línea:** Se ingresa mediante `:` desde Command Mode. Pasa comandos orientados a líneas al motor subyacente del editor Ex (`:w`, `:q`, `:s`, `:set`).

### 1.3 Read-Only Override Mechanics (`:w!`)
Al editar archivos de solo lectura (por ejemplo, propiedad de `root` con permisos `0444`), `nvi` verifica tanto el Effective User ID (EUID) del proceso como los bits de escritura del sistema de archivos.
* Si el archivo es de solo lectura para el usuario actual pero el usuario es `root` (o posee el archivo), los comandos de escritura estándar (`:w`) fallarán con `Permission denied` o `Read-only file`.
* Ejecutar **`:w!`** fuerza a `nvi` a emitir una llamada al sistema de desvinculación/reapertura (`open(2)` con `O_WRONLY | O_CREAT | O_TRUNC`), anulando los flags de permisos del archivo en sistemas de archivos POSIX/BSD siempre que los permisos del directorio subyacente permitan operaciones de escritura `w`.

---

## 2. Production Guided Exercises

### Exercise 1: Core Editing Mechanics, Navigation, and Buffer Operations

En este ejercicio, inicializarás una configuración simulada de un sistema de producción, realizarás inserciones de texto, copiarás/pegarás (yank/put) buffers de líneas y probarás operaciones atómicas de deshacer (undo).

#### Step 1.1: Environment Setup
Inicia sesión en la shell de tu sistema BSD (`sh` o `csh`) y construye un archivo de configuración de entorno base:

```syslog
cat << 'EOF' > /tmp/syslog.conf
# /tmp/syslog.conf - Baseline BSD Logging Configuration
*.err;kern.warning;auth.notice;mail.crit        /dev/console
*.notice;authpriv.none;kern.debug;mail.crit     /var/log/messages
security.*                                      /var/log/security
auth.info;authpriv.info                         /var/log/auth.log
mail.info                                       /var/log/maillog
cron.info                                       /var/log/cron
EOF
```

Verifica el contenido de las líneas y la cantidad de líneas utilizando `wc -l`:

```console
$ wc -l /tmp/syslog.conf
       7 /tmp/syslog.conf
```

#### Step 1.2: Modal Text Insertion and Line Creation
Abre el archivo en `vi`:

```console
$ vi /tmp/syslog.conf
```

1. Asegúrate de estar en **Command Mode** presionando `<ESC>`.
2. Mueve el cursor a la parte superior del archivo presionando `1G` o `gg`.
3. Abre una nueva línea *arriba* de la línea actual presionando `O`.
4. Escribe el siguiente comentario de encabezado:
   `# PRODUCTION SRE OVERRIDE - DO NOT REMOVE`
5. Presiona `<ESC>` para regresar a Command Mode.
6. Desplázate hacia abajo hasta la línea que comienza con `security.*` usando `/security.*` seguido de `<ENTER>`.
7. Anexa texto al *final de la línea actual* presionando `A`, escribe ` # Audit Log Channel`, y presiona `<ESC>`.

#### Step 1.3: Yanking, Deleting, and Putting Lines
1. Navega hasta la línea que comienza con `cron.info`.
2. Elimina completamente la línea `cron.info` y almacénala en el registro sin nombre escribiendo `dd`.
3. Mueve el cursor a la última línea usando `G`.
4. Pega (put) la línea eliminada *debajo* de la línea actual del cursor presionando `p`.
5. Duplica (yank) la línea `auth.info` posicionando el cursor sobre ella y escribiendo `yy`.
6. Pégala *arriba* de la línea actual presionando `P`.

#### Step 1.4: Multi-Step Undo and Redo Mechanics
1. Elimina la línea que acabas de pegar usando `dd`.
2. Presiona `u` para revertir la eliminación.
3. En BSD `nvi` estándar, presionar `u` nuevamente actúa como deshacer lo deshecho (reeliminando la línea). Ejecuta `u` dos veces para observar el comportamiento de deshacer de doble estado de `nvi` en comparación con el árbol de historial lineal de Vim.
4. Guarda el archivo y sal escribiendo `:wq` seguido de `<ENTER>`.

---

#### Question Block 1
**Q1.1:** ¿Cuál es el resultado técnico de presionar `u` dos veces secuencialmente en el tradicional BSD `nvi` frente a GNU `vim`?  
**Q1.2:** ¿Qué secuencia de comandos permite a un ingeniero anexar texto al final de una línea sin mover manualmente la posición del cursor hacia la derecha usando `l` o `$`?

---

### Exercise 2: Advanced Pattern Search, Global Line Substitution, and Regex

En este ejercicio, realizarás búsquedas de alta precisión y sustituciones masivas con regex en estructuras de configuración de firewall de red (`/etc/pf.conf`).

#### Step 2.1: Prepare Firewall Manifest
Crea una configuración simulada de Packet Filter para FreeBSD:

```pf
cat << 'EOF' > /tmp/pf.conf
# /tmp/pf.conf - Web Tier Filtering
ext_if="vtnet0"
int_if="vtnet1"

table <webservers> { 192.168.1.10, 192.168.1.11, 192.168.1.12 }
table <dbservers>  { 10.0.10.5, 10.0.10.6 }

set skip on lo0
scrub in all

block all
pass out quick on $ext_if keep state
pass in quick on $ext_if proto tcp to <webservers> port 80 keep state
pass in quick on $ext_if proto tcp to <webservers> port 443 keep state
EOF
```

#### Step 2.2: Forward/Backward Search and Navigation
Abre `/tmp/pf.conf` con `vi`:

```console
$ vi /tmp/pf.conf
```

1. Busca hacia adelante la palabra `keep` escribiendo `/keep` y presionando `<ENTER>`.
2. Desplázate a la siguiente ocurrencia usando `n`.
3. Desplázate a la ocurrencia anterior usando `N`.
4. Habilita la numeración visual de líneas ingresando al modo Ex: `:set number` (o `:set nu`).
5. Observa la columna de la izquierda:

```syslog
     1  # /tmp/pf.conf - Web Tier Filtering
     2  ext_if="vtnet0"
     3  int_if="vtnet1"
     4  
     5  table <webservers> { 192.168.1.10, 192.168.1.11, 192.168.1.12 }
     ...
```

#### Step 2.3: Performing Ex Global Substitutions
1. Sustituye todas las ocurrencias de la interfaz `vtnet0` por `em0` a lo largo de todo el documento:
   Escribe `:1,$s/vtnet0/em0/g` o `:%s/vtnet0/em0/g` y presiona `<ENTER>`.
2. Cambia el esquema de direccionamiento de subred para webservers de `192.168.1.` a `172.16.10.` apuntando solo a las líneas que contengan la cadena `table <webservers>`:
   Escribe `:g/table <webservers>/s/192\.168\.1\./172\.16\.10\./g` y presiona `<ENTER>`.
3. Verifica la modificación de la línea. La línea ahora debería leerse:
   `table <webservers> { 172.16.10.10, 172.16.10.11, 172.16.10.12 }`
4. Escribe los cambios en el disco sin salir:
   Escribe `:w` y presiona `<ENTER>`. Salida esperada en la línea de estado:
   `"/tmp/pf.conf": 14 lines, 342 characters`

---

#### Question Block 2
**Q2.1:** En el comando `:%s/vtnet0/em0/g`, ¿qué funciones exactas realizan `%` y `g` en el motor de sintaxis de Ex?  
**Q2.2:** ¿Cómo puedes buscar hacia atrás desde la posición actual del cursor el término literal `block`?

---

### Exercise 3: Read-Only Files, Forced Overrides, and Recovery File Diagnostics

Este ejercicio modela un incidente operativo donde un archivo de configuración del sistema se establece como de solo lectura (`0444`), requiriendo flags de escritura forzada (`:w!`), y simula una caída inesperada de la terminal para recuperar buffers no escritos desde `/var/tmp/vi.recover`.

#### Step 3.1: Enforce Read-Only Permissions
Crea un archivo de configuración protegido que sea propiedad de tu usuario actual:

```console
$ touch /tmp/sysctl.conf
$ chmod 444 /tmp/sysctl.conf
$ echo "net.inet.ip.forwarding=0" > /tmp/sysctl.conf 2>/dev/null || chmod 644 /tmp/sysctl.conf && echo "net.inet.ip.forwarding=0" > /tmp/sysctl.conf && chmod 444 /tmp/sysctl.conf
$ ls -l /tmp/sysctl.conf
-r--r--r--  1 root  wheel  25 Aug  6 21:00 /tmp/sysctl.conf
```

#### Step 3.2: Standard Edit Attempt and Failure Analysis
Abre el archivo usando `vi`:

```console
$ vi /tmp/sysctl.conf
```

1. Observa la línea de estado inferior: `"/tmp/sysctl.conf" [Read-only] 1 line, 25 characters`.
2. Navega al final de la línea usando `$` y agrega una línea usando `o`.
3. Escribe `net.inet.tcp.blackhole=2` y presiona `<ESC>`.
4. Intenta una escritura estándar y sal: `:wq`.
5. Observa la respuesta de error de `nvi`:
   `sysctl.conf: read-only file; use w! to override` o `Permission denied`.

#### Step 3.3: Force-Write Execution (`:w!`)
1. Fuerza la escritura de vuelta en el sistema de archivos:
   Escribe `:w!` y presiona `<ENTER>`.
2. Verifica la línea de salida: `"/tmp/sysctl.conf" 2 lines, 51 characters`.
3. Sal de `vi`: `:q`.
4. Verifica el contenido del archivo desde la shell:

```console
$ cat /tmp/sysctl.conf
net.inet.ip.forwarding=0
net.inet.tcp.blackhole=2
```

#### Step 3.4: Simulating Process Termination and File Recovery
1. Abre `/tmp/sysctl.conf` nuevamente:
   `vi /tmp/sysctl.conf`
2. Agrega una nueva línea al final: `kern.maxfiles=65536`. **NO** ejecutes `:w`.
3. Simula una caída inesperada de la conexión SSH enviando `SIGHUP` a tu proceso `vi` activo desde una shell secundaria, o finaliza el proceso utilizando una búsqueda por PID:

```console
$ pkill -HUP nvi || pkill -HUP vi
```

4. Revisa el directorio de recuperación `/var/tmp/vi.recover`:

```console
$ ls -la /var/tmp/vi.recover/
total 4
drwxr-xr-x  2 root  wheel  512 Aug  6 21:05 .
drwxrwxrwt  3 root  wheel  512 Aug  6 21:05 ..
-rw-------  1 root  wheel  896 Aug  6 21:05 recover.vi.XXXXXX
```

5. Recupera la sesión de archivo perdida usando el flag `-r`:

```console
$ vi -r /tmp/sysctl.conf
```

6. Confirma que la línea no guardada `kern.maxfiles=65536` se haya restaurado en el buffer.
7. Guarda y sal limpiamente: `:wq`.

---

#### Question Block 3
**Q3.1:** ¿Qué operación a nivel de sistema de archivos realiza `:w!` internamente cuando la ejecuta el propietario del archivo en un archivo con modo `0444`?  
**Q3.2:** Si `vi -r` muestra múltiples archivos de recuperación para `/etc/rc.conf`, ¿cómo puede un ingeniero inspeccionar las instantáneas de recuperación disponibles listadas por `nvi`?

---

### Exercise 4: Customization via `.exrc` and Production Environment Overrides

En este ejercicio, configurarás parámetros persistentes del editor `vi`/`nvi` a través de manifiestos de inicialización (`~/.exrc`) y controlarás los editores predeterminados mediante variables de entorno de la shell (`EDITOR` / `VISUAL`).

#### Step 4.1: Constructing Syntactically Valid `~/.exrc`
Crea un archivo de configuración persistente para `nvi` en tu directorio personal:

```vim
cat << 'EOF' > ~/.exrc
" BSD nvi Runtime Configuration (~/.exrc)
set number
set autoindent
set shiftwidth=4
set tabstop=4
set showmatch
set ignorecase
EOF
```

Verifica los permisos. En BSD `nvi`, si `~/.exrc` tiene permisos de escritura para el grupo u otros, `nvi` **ignorará** el archivo por razones de seguridad para evitar la inyección no autorizada de macros:

```console
$ chmod 600 ~/.exrc
$ ls -l ~/.exrc
-rw-------  1 sradmin  wheel  142 Aug  6 21:10 /home/sradmin/.exrc
```

#### Step 4.2: Testing Environment Variable Overrides (`EDITOR` / `VISUAL`)
La edición de crontab (`crontab -e`), `visudo` y `git commit` dependen de las variables de entorno del proceso para invocar editores de texto.

1. Exporta `EDITOR` y `VISUAL` en tu sesión actual de la shell:

```console
$ export EDITOR=/usr/bin/vi
$ export VISUAL=/usr/bin/vi
```

2. Prueba la precedencia del entorno con una comprobación no interactiva:

```console
$ env | grep -E 'EDITOR|VISUAL'
EDITOR=/usr/bin/vi
VISUAL=/usr/bin/vi
```

3. Abre un archivo con `vi` para verificar que las funciones de `~/.exrc` (como los números de línea y la sangría de 4 espacios) se carguen automáticamente:

```console
$ vi /tmp/test_config.txt
```

---

#### Question Block 4
**Q4.1:** ¿Por qué `nvi` se negará a procesar un archivo `~/.exrc` que tenga permisos establecidos en `0666` (`-rw-rw-rw-`)?  
**Q4.2:** En herramientas de administración del sistema como `visudo` o `crontab -e`, ¿qué variable de entorno suele tener precedencia si están definidas tanto `VISUAL` como `EDITOR`?

---

<details>
<summary><b>Respuestas y explicaciones técnicas detalladas</b></summary>

### Answers for Question Block 1

* **A1.1:** En BSD `nvi` estándar, el comando deshacer `u` es alternable y de un solo nivel: presionar `u` una vez revierte el último cambio, y presionar `u` por segunda vez revierte el deshacer (reaplicando efectivamente el cambio). En Vim, `u` se desplaza hacia atrás a través de un árbol de historial lineal multinivel.
* **A1.2:** Presionar **`A`** (Shift + `a`) pasa `nvi` a Insert Mode y coloca automáticamente el cursor después del último carácter de la línea actual.

---

### Answers for Question Block 2

* **A2.1:** `%` especifica la dirección del rango de líneas que representa todas las líneas del buffer (equivalente a `1,$`). `g` es el flag de ejecución global que indica al comando reemplazar cada coincidencia en una línea en lugar de detenerse en la primera ocurrencia.
* **A2.2:** Escribe **`?block`** seguido de `<ENTER>`. El iniciador `?` realiza una búsqueda de regex en sentido inverso/hacia atrás hacia arriba desde la línea actual.

---

### Answers for Question Block 3

* **A3.1:** Debido a que el propietario del archivo tiene acceso de escritura en el directorio primario, `:w!` omite el bit de solo lectura del archivo (`0444`) invocando `open(2)` con flags de escritura/truncado o actualizando temporalmente los bits de modo del archivo durante la llamada de escritura, lo que permite al propietario (o a root) sobrescribir el contenido del archivo.
* **A3.2:** Ejecuta **`vi -r`** sin argumentos de nombre de archivo (`vi -r`). `nvi` listará todos los archivos de recuperación existentes guardados en `/var/tmp/vi.recover/` junto con sus marcas de tiempo de creación y rutas de archivo originales.

---

### Answers for Question Block 4

* **A4.1:** `nvi` verifica los permisos del archivo `~/.exrc` (y `.nexrc`). Si el archivo tiene permisos de escritura para grupo o todos (bits de escritura de `group` u `other` establecidos), `nvi` no lo cargará para evitar que usuarios locales no confiables inyecten comandos Ex maliciosos o escapes a la shell en la sesión del editor de otro usuario.
* **A4.2:** **`VISUAL`** tiene precedencia sobre `EDITOR` en las implementaciones de utilidades estándar de POSIX/BSD (incluyendo `visudo` y `crontab`). Si `VISUAL` está definida y no está vacía, se utiliza esta; `EDITOR` sirve como alternativa secundaria.

</details>

---

## 3. Official References & Citation
* **Linux Professional Institute BSD Specialist Certification:** Objetivos 702-100, Tema 715.5  
  URL: [https://www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)
* **FreeBSD Manual Pages - nvi(1):**  
  URL: [https://man.freebsd.org/cgi/man.cgi?query=nvi](https://man.freebsd.org/cgi/man.cgi?query=nvi)
* **OpenBSD Manual Pages - vi(1):**  
  URL: [https://man.openbsd.org/vi](https://man.openbsd.org/vi)