# LPI-702 (Examen 702-100) Tema 712.6: Búsqueda de archivos y estructura de directorios de BSD
**Peso:** 2 (Versión del examen 1.0)

---

## 1. Arquitectura técnica y mecánica interna

### Arquitectura de la jerarquía de directorios de BSD (`hier(7)`)
A diferencia de las distribuciones de Linux, que a menudo desdibujan los límites entre el sistema operativo base y el software instalado por el usuario, los sistemas operativos BSD imponen una separación estricta gobernada por la especificación de diseño [`hier(7)`](https://man.freebsd.org/cgi/man.cgi?query=hier&sektion=7).

```
/
├── bin/          # Fundamental binaries required for single-user recovery
├── sbin/         # System administration binaries required for single-user recovery
├── etc/          # Base system configuration files
│   └── defaults/ # Default base system configurations (DO NOT EDIT DIRECTLY)
├── lib/          # Shared libraries essential for binaries in /bin and /sbin
├── libexec/      # System daemons and internal helpers targeted by execution scripts
├── dev/          # Device nodes (DEVFS dynamic filesystem)
├── boot/         # Kernel (/boot/kernel/kernel), loader, and boot modules
├── var/          # Multi-purpose variable dynamic data (logs, spools, databases)
│   └── db/       # System databases (pkg, locate.database)
└── usr/          # Subdirectory hierarchy for static, read-only system files
    ├── bin/      # Standard user utility binaries
    ├── sbin/     # System management binaries for multi-user operation
    ├── lib/      # Libraries for user binaries
    ├── libexec/  # System daemons executed by system services
    ├── share/    # Architecture-independent data (doc, zoneinfo, man)
    │   └── man/  # Manual page repository
    ├── src/      # Base system OS source code tree
    ├── ports/    # FreeBSD Ports Collection tree (or /usr/pkgsrc in NetBSD)
    └── local/    # THIRD-PARTY SOFTWARE PREFIX (bin, etc, lib, man, share)
```

#### Restricciones estructurales clave y compromisos de diseño:
1. **Aislamiento del sistema base frente a software de terceros (`/usr/local` vs `/usr`):**
   - La distribución base del sistema operativo reside bajo `/`, `/bin`, `/usr/bin`, `/sbin` y `/etc`. 
   - Los paquetes que no son de la base instalados mediante `pkg(8)` o la FreeBSD Ports Collection **deben** estar contenidos dentro de `/usr/local` (o `/usr/pkg` en NetBSD `pkgsrc`). Los archivos de configuración para los ports residen en `/usr/local/etc`, evitando la contaminación de `/etc`.
2. **Configuración base inmutable (`/etc/defaults`):**
   - Los valores por defecto del sistema residen en `/etc/defaults/rc.conf`. Los administradores de sistemas sobrescriben los parámetros en `/etc/rc.conf`. La actualización del sistema operativo reemplaza `/etc/defaults/rc.conf` de forma segura sin sobrescribir las modificaciones del administrador.
3. **Límites de particionamiento y montaje:**
   - En configuraciones tradicionales de UFS2/ZFS, `/var` y `/usr` son sistemas de archivos aislados. Quedarse sin espacio en disco en `/var` (por ejemplo, debido a un desbordamiento de logs) no corrompe ni detiene las operaciones del sistema de archivos raíz.

---

### Comparación de utilidades: Mecanismos de descubrimiento de archivos y comandos

| Característica / Utilidad | `which(1)` | `whereis(1)` | `locate(1)` | `find(1)` |
| :--- | :--- | :--- | :--- | :--- |
| **Mecanismo de búsqueda** | Escanea la variable de entorno `$PATH` actual | Escanea directorios estándar del sistema para binarios, manuales y código fuente | Consulta una base de datos preconstruida (`/var/db/locate.database`) | Realiza un recorrido dinámico en tiempo real del árbol de directorios VFS |
| **Objetivo de búsqueda** | Ejecutables en `$PATH` | Binarios estándar, archivos fuente y páginas de manual | Coincidencia de patrones de nombres de archivo en la BD indexada | Atributos arbitrarios de inode (metadatos, flags, tamaño, tiempo) |
| **Velocidad** | Instantánea ($O(k)$ donde $k$ es la longitud de `$PATH`) | Instantánea (búsqueda en arreglo fijo de rutas $O(m)$) | Extremadamente rápida (búsqueda binaria indexada $O(\log N)$) | Lenta (escaneo de I/O del sistema de archivos en vivo $O(N)$) |
| **Precisión en tiempo real** | Sí | Sí | No (Desactualizada entre ejecuciones de `updatedb`) | Sí |
| **Filtro de permisos** | Filtra por bit de ejecución (`+x`) para el usuario | Busca en una lista de rutas predefinida sin filtro de permisos | Aplica permisos de usuario durante la lectura si está configurado | Evalúa contra POSIX ACL completo / flags de BSD |

#### Mecánica de `locate` y `locate.updatedb(8)`
- `locate` se basa en una base de datos rápida y comprimida creada por `/usr/libexec/locate.updatedb`.
- En FreeBSD, `locate.updatedb` se ejecuta automáticamente a través del marco de trabajo de mantenimiento periódico (`/etc/periodic/weekly/310.locate`).
- **Aislamiento de seguridad:** `locate.updatedb` descuenta privilegios de `root` al usuario `nobody` (o `_locate` en OpenBSD) durante el escaneo del sistema de archivos. Los archivos dentro de directorios restringidos (por ejemplo, `0700` propiedad de `root`) se omiten de la base de datos para evitar que usuarios sin privilegios descubran nombres de rutas sensibles.

#### Mecánica de `find(1)` en BSD y BSD File Flags
BSD `find` recorre los árboles de directorios usando funciones `fts(3)` y evalúa los metadatos de archivos a través de `stat(2)`. A diferencia de GNU `find`, BSD `find` incluye soporte nativo para BSD File Flags (`chflags(2)`):
- Los flags incluyen: `uchg` (inmutable por el usuario), `schg` (inmutable por el sistema), `uappnd` (solo añadir por el usuario), `sappnd` (solo añadir por el sistema), `nodump` (flag para omitir en la utilidad dump).
- BSD `find` evalúa los flags usando la primaria `-flags` (por ejemplo, `find / -flags uchg`).

---

### Referencias de documentación oficial
- [Página de manual de `hier(7)` de FreeBSD](https://man.freebsd.org/cgi/man.cgi?query=hier&sektion=7)
- [Página de manual de `find(1)` de FreeBSD](https://man.freebsd.org/cgi/man.cgi?query=find&sektion=1)
- [Página de manual de `locate(1)` de FreeBSD](https://man.freebsd.org/cgi/man.cgi?query=locate&sektion=1)
- [Página de manual de `locate.updatedb(8)` de FreeBSD](https://man.freebsd.org/cgi/man.cgi?query=locate.updatedb&sektion=8)
- [Manual de la llamada al sistema `chflags(2)` de FreeBSD](https://man.freebsd.org/cgi/man.cgi?query=chflags&sektion=2)

---

## 2. Ejercicios guiados prácticos

### Ejercicio 1: Exploración del diseño de directorios de BSD y auditoría estructural

**Objetivo:** Auditar un sistema de archivos BSD en vivo para verificar el cumplimiento de los estándares de `hier(7)`, identificando las ubicaciones del sistema base frente a las ubicaciones de paquetes de terceros.

#### Paso 1.1: Verificar la jerarquía del manual del sistema
Leer la página del manual de `hier(7)` para inspeccionar los roles de directorios estándar:
```bash
man 7 hier | head -n 30
```
*Expected Output Snippet:*
```text
HIER(7)                 FreeBSD Manual Pages Statement              HIER(7)

NAME
     hier -- layout of file systems

DESCRIPTION
     A sketch of the file system hierarchy.

     /        root directory of the file system
     /bin/    user utilities fundamental to both single-user and multi-user
              environments
```

#### Paso 1.2: Diferenciar configuraciones base frente a sobrescrituras por defecto
Inspeccionar `/etc/defaults/rc.conf` y verificar su regla de inmutabilidad:
```bash
head -n 12 /etc/defaults/rc.conf
```
*Expected Output Snippet:*
```text
# This is rc.conf - a file full of utility variable settings that you
# might maintain to change the default configuration of your system.
#
# DO NOT EDIT THIS FILE DIRECTLY. IT IS A MASTER FILE FOR ALL DEFAULTS.
# Make your changes to /etc/rc.conf instead.
```

#### Paso 1.3: Auditar directorios de binarios de terceros frente al sistema base
Comprobar dónde almacena el sistema base las herramientas de gestión del sistema frente a los servicios instalados por terceros (por ejemplo, Nginx o PostgreSQL instalados a través de `pkg`):
```bash
ls -ld /sbin/ifconfig /usr/sbin/sshd /usr/local/sbin 2>/dev/null
```
*Expected Output Snippet:*
```text
-r-xr-xr-x  1 root  wheel  387496 Aug  1 12:00 /sbin/ifconfig
-r-xr-xr-x  1 root  wheel  845120 Aug  1 12:00 /usr/sbin/sshd
drwxr-xr-x  2 root  wheel     512 Aug  2 14:10 /usr/local/sbin
```

---

#### Preguntas de verificación (Ejercicio 1)

1. Un administrador júnior instala un paquete de demonio de terceros mediante `pkg` en FreeBSD e intenta editar manualmente `/etc/daemon.conf`. Siguiendo los estándares de `hier(7)`, ¿dónde debería ubicarse realmente este archivo de configuración y por qué BSD impone esta ubicación?
2. ¿Por qué BSD separa los binarios entre `/bin` y `/sbin` y `/usr/bin` y `/usr/sbin`? ¿Qué escenario depende de que existan binarios dentro de `/bin` en lugar de `/usr/bin`?

---

### Ejercicio 2: Descubrimiento de comandos y administración de la base de datos `locate`

**Objetivo:** Utilizar `which`, `whereis` y configurar/generar manualmente la base de datos indexada de `locate` como administrador del sistema.

#### Paso 2.1: Comparar la resolución de comandos (`which` vs `whereis`)
Buscar la utilidad `reboot` usando ambas herramientas:
```bash
which reboot
whereis reboot
```
*Expected Output:*
```text
/sbin/reboot
reboot: /sbin/reboot /usr/share/man/man8/reboot.8.gz
```

#### Paso 2.2: Probar el fallo de `locate` en una base de datos ausente
Intentar buscar `rc.conf` utilizando `locate`:
```bash
locate rc.conf
```
*Expected Output (If database is absent or uninitialized):*
```text
locate: warning: database /var/db/locate.database is small or missing
locate: run /usr/libexec/locate.updatedb or wait for periodic maintenance
```

#### Paso 2.3: Actualizar manualmente la base de datos de `locate`
Ejecutar `/usr/libexec/locate.updatedb` para indexar el sistema de archivos:
```bash
su -m root -c "/usr/libexec/locate.updatedb"
```
Verificar los metadatos de la base de datos generada:
```bash
ls -lh /var/db/locate.database
```
*Expected Output:*
```text
-rw-r--r--  1 nobody  wheel   1.2M Aug  6 20:40 /var/db/locate.database
```

#### Paso 2.4: Ejecutar una búsqueda indexada
Consultar `locate` para encontrar páginas de manual del sistema relacionadas con `zfs`:
```bash
locate -i "/man8/zfs" | head -n 5
```
*Expected Output:*
```text
/usr/share/man/man8/zfs-create.8.gz
/usr/share/man/man8/zfs-destroy.8.gz
/usr/share/man/man8/zfs-mount.8.gz
/usr/share/man/man8/zfs-receive.8.gz
/usr/share/man/man8/zfs-rollback.8.gz
```

---

#### Preguntas de verificación (Ejercicio 2)

1. Al ejecutar `/usr/libexec/locate.updatedb`, el archivo resultante `/var/db/locate.database` pertenece al usuario `nobody`. ¿Por qué el script `locate.updatedb` cambia al usuario `nobody` durante el proceso de indexación en lugar de ejecutarse directamente como `root`?
2. Si un administrador crea un nuevo archivo `/etc/secret_audit.conf` a las 10:00 AM, ¿por qué `locate secret_audit.conf` no devuelve resultados a las 10:05 AM, mientras que `find /etc -name secret_audit.conf` sí lo hace con éxito?

---

### Ejercicio 3: Consultas avanzadas de archivos y BSD File Flags con `find(1)`

**Objetivo:** Construir consultas precisas con `find` utilizando flags de archivos específicos de BSD, primitivas de tiempo, modos de permisos y filtros de tamaño.

#### Paso 3.1: Crear espacio de trabajo de prueba y establecer BSD File Flags
Crear un entorno de prueba dedicado y establecer flags de archivos BSD usando `chflags(1)`:
```bash
mkdir -p /tmp/bsd_find_lab/restricted
touch /tmp/bsd_find_lab/app.log
touch /tmp/bsd_find_lab/critical.conf
touch /tmp/bsd_find_lab/restricted/key.pem

# Apply user immutable flag (uchg) to critical.conf
chflags uchg /tmp/bsd_find_lab/critical.conf

# Set permission 0600 on key.pem
chmod 0600 /tmp/bsd_find_lab/restricted/key.pem
```

#### Paso 3.2: Verificar flags de BSD usando `ls -lo`
Inspeccionar los flags del sistema usando las opciones específicas de BSD para `ls`:
```bash
ls -lo /tmp/bsd_find_lab/
```
*Expected Output:*
```text
total 0
-rw-r--r--  1 root  wheel  -    Aug  6 20:42 app.log
-rw-r--r--  1 root  wheel  uchg Aug  6 20:42 critical.conf
drwxr-xr-x  2 root  wheel  -    Aug  6 20:42 restricted
```

#### Paso 3.3: Consultar archivos por BSD File Flag (`-flags`)
Usar `find` en BSD para aislar archivos marcados explícitamente con el flag `uchg` (inmutable por el usuario):
```bash
find /tmp/bsd_find_lab -flags uchg
```
*Expected Output:*
```text
/tmp/bsd_find_lab/critical.conf
```

#### Paso 3.4: Filtro multicriterio (Modo, Usuario, Tipo)
Encontrar todos los archivos regulares (`-type f`) bajo `/tmp/bsd_find_lab` con permisos exactos `0600` cuya propiedad pertenezca a `root`:
```bash
find /tmp/bsd_find_lab -type f -user root -perm 0600
```
*Expected Output:*
```text
/tmp/bsd_find_lab/restricted/key.pem
```

#### Paso 3.5: Primitivas basadas en tiempo (`-mtime`, `-atime`, `-ctime`, `-mmin`)
Encontrar archivos modificados en los últimos 15 minutos (`-mmin -15`):
```bash
find /tmp/bsd_find_lab -type f -mmin -15
```
*Expected Output:*
```text
/tmp/bsd_find_lab/app.log
/tmp/bsd_find_lab/critical.conf
/tmp/bsd_find_lab/restricted/key.pem
```

---

#### Preguntas de verificación (Ejercicio 3)

1. ¿Cuál es la diferencia operativa entre las primitivas `-ctime` y `-mtime` en `find`? ¿Cuál de estas cambia cuando se actualiza el flag BSD de un archivo (`chflags uchg file`) sin alterar el contenido del archivo?
2. Intentas eliminar un archivo encontrado a través de `find /tmp -name "old.log" -exec rm {} \;`, pero el comando falla con `rm: old.log: Operation not permitted`, a pesar de haber iniciado sesión como `root`. ¿Qué atributo específico de BSD causa esto y cómo se puede usar `find` para identificar todos esos archivos?

---

### Ejercicio 4: Pipelines de diagnóstico en producción y ejecución por lotes segura

**Objetivo:** Manejar de forma segura operaciones de archivos por lotes usando `find`, `-print0`, `xargs -0` y comparar con la primitiva nativa `-delete` de BSD.

#### Paso 4.1: Construir nombres de archivos con espacios y caracteres de espacio en blanco
Crear archivos de ejemplo que contengan caracteres problemáticos de espacio en blanco:
```bash
mkdir -p /tmp/bsd_find_lab/space_test
touch "/tmp/bsd_find_lab/space_test/audit log 2026.log"
touch "/tmp/bsd_find_lab/space_test/error log 2026.log"
```

#### Paso 4.2: Demostrar el fallo de la pipeline con `xargs` (Pipeline estándar no segura)
Observar cómo las pipelines estándar con delimitadores de nueva línea/espacio fallan cuando los nombres de archivos contienen espacios:
```bash
find /tmp/bsd_find_lab/space_test -type f | xargs ls -l
```
*Expected Output (Truncated Error):*
```text
ls: /tmp/bsd_find_lab/space_test/audit: No such file or directory
ls: log: No such file or directory
ls: 2026.log: No such file or directory
ls: /tmp/bsd_find_lab/space_test/error: No such file or directory
ls: log: No such file or directory
ls: 2026.log: No such file or directory
```

#### Paso 4.3: Ejecutar una pipeline segura usando delimitadores NUL (`-print0` y `xargs -0`)
Corregir la pipeline inyectando separadores con el carácter ASCII NUL (`\0`):
```bash
find /tmp/bsd_find_lab/space_test -type f -print0 | xargs -0 ls -l
```
*Expected Output:*
```text
-rw-r--r--  1 root  wheel  0 Aug  6 20:45 /tmp/bsd_find_lab/space_test/audit log 2026.log
-rw-r--r--  1 root  wheel  0 Aug  6 20:45 /tmp/bsd_find_lab/space_test/error log 2026.log
```

#### Paso 4.4: Eliminación interactiva por lotes (`-ok`)
Demostrar una confirmación interactiva segura previa a la ejecución:
```bash
find /tmp/bsd_find_lab/space_test -type f -name "*error*" -ok rm {} \;
```
*Expected Output:*
```text
"< rm /tmp/bsd_find_lab/space_test/error log 2026.log >? " y
```

#### Paso 4.5: Limpieza usando eliminación rápida de BSD (`-delete`)
Limpiar el espacio de trabajo restante utilizando la primitiva nativa `-delete` de `find` en BSD:
```bash
# Clean up test flags prior to directory removal
chflags 0 /tmp/bsd_find_lab/critical.conf

# Execute depth-first direct deletion without invoking external processes
find /tmp/bsd_find_lab -delete
```

---

#### Preguntas de verificación (Ejercicio 4)

1. ¿Qué ventaja arquitectónica de rendimiento ofrece `find /path -type f -delete` sobre `find /path -type f -exec rm {} \;` en directorios de alta densidad que contienen millones de archivos?
2. ¿Qué riesgo de seguridad ocurre si se coloca `-delete` al principio de una expresión `find` (por ejemplo, `find /tmp -delete -name "*.tmp"`) en comparación con colocarlo al final?

---

## 3. Soluciones y respuestas de verificación

<details>
<summary>Haz clic aquí para desplegar las soluciones de todas las preguntas de verificación</summary>

### Respuestas para el Ejercicio 1: Exploración del diseño de directorios de BSD

1. **Respuesta:**
   - **Ruta correcta:** `/usr/local/etc/daemon.conf`
   - **Justificación arquitectónica:** La especificación `hier(7)` de BSD impone un límite estricto entre la distribución base del sistema operativo y los paquetes de terceros instalados a través de ports/pkg. Todos los binarios, bibliotecas, páginas de manual y archivos de configuración de terceros deben residir bajo `/usr/local` (o `/usr/pkg` en NetBSD). Este diseño garantiza que las actualizaciones del sistema operativo base (vía `freebsd-update` o compilación desde fuentes) nunca sobrescriban, entren en conflicto ni dejen archivos de configuración huérfanos dentro de `/etc`.

2. **Respuesta:**
   - **Justificación arquitectónica:** `/bin` y `/sbin` residen en la partición del sistema de archivos raíz (`/`) y contienen el conjunto mínimo absoluto de binarios requeridos para arrancar el sistema en modo de recuperación monousuario (single-user), reparar sistemas de archivos (`fsck`) o montar particiones auxiliares.
   - **Escenario de fallo:** `/usr` con frecuencia se almacena en una partición de sistema de archivos separada, en un montaje de red (NFS) o en un pool de almacenamiento complejo (ZFS). Si `/usr` no se logra montar o sufre corrupción en el pool de almacenamiento durante el arranque, los binarios ubicados en `/usr/bin` o `/usr/sbin` quedan inaccesibles. Tener las utilidades de recuperación de emergencia (`sh`, `cp`, `fsck`, `ifconfig`, `mount`) dentro de `/bin` y `/sbin` garantiza la capacidad de depuración del sistema en modo monousuario.

---

### Respuestas para el Ejercicio 2: Descubrimiento de comandos y administración de la base de datos `locate`

1. **Respuesta:**
   - **Mecánica de seguridad:** Eliminar privilegios a `nobody` evita que el proceso de indexación registre rutas de archivos ubicadas dentro de directorios restringidos (como directorios personales `0700` o subdirectorios privados de `/var`). Si `locate.updatedb` se ejecutara como `root`, registraría todos los nombres de archivos sensibles del sistema en `/var/db/locate.database`. Dado que `/var/db/locate.database` tiene permisos de lectura pública (`0644`), usuarios sin privilegios podrían consultar `locate` para realizar reconocimientos no autorizados sobre rutas privadas, copias de seguridad del sistema o archivos secretos.

2. **Respuesta:**
   - **Mecánica de ejecución:** `locate` no escanea la estructura de directorios VFS en vivo; consulta la base de datos estática precompilada `/var/db/locate.database`. Los archivos creados después de la última ejecución de `/usr/libexec/locate.updatedb` no existirán en el índice de la base de datos. Por el contrario, `find` ejecuta llamadas al sistema de recorrido de directorios en tiempo real (`opendir(3)`, `readdir(3)`, `stat(2)`), proporcionando datos en tiempo real directamente desde la caché del kernel del sistema de archivos y los bloques del disco.

---

### Respuestas para el Ejercicio 3: Consultas avanzadas de archivos y BSD File Flags

1. **Respuesta:**
   - **Diferencia operativa:** 
     - `-mtime` (Modification Time) refleja cambios en el **contenido** real del archivo (por ejemplo, escribir datos en disco vía `write(2)`).
     - `-ctime` (Change Time) refleja cambios de metadatos en el propio inode (por ejemplo, permisos, propiedad, recuento de enlaces o flags de archivos).
   - **Efecto de modificación de flags:** Modificar un flag de archivo BSD utilizando `chflags uchg file` desencadena una actualización de metadatos de inode (`utimes(2)` / escritura de inode), actualizando `-ctime`. No altera el contenido del archivo, por lo que `-mtime` permanece intacto.

2. **Respuesta:**
   - **Atributo de BSD:** El archivo tiene establecido el flag de archivo BSD Inmutable por el Sistema (`schg`) o Inmutable por el Usuario (`uchg`) (`chflags`). Ni siquiera el superusuario `root` puede eliminar, renombrar, sobrescribir o truncar un archivo protegido por flags inmutables sin quitar primero el flag.
   - **Comando principal de `find`:**
     ```bash
     find /tmp -flags uchg,schg
     ```
     Para quitar el flag automáticamente en todos los archivos coincidentes a través de `find`:
     ```bash
     find /tmp -flags uchg,schg -exec chflags 0 {} +
     ```

---

### Respuestas para el Ejercicio 4: Pipelines de diagnóstico en producción y ejecución por lotes segura

1. **Respuesta:**
   - **Ventaja de rendimiento:** El uso de `-exec rm {} \;` hace que `find` ejecute una secuencia de llamadas al sistema `fork(2)` y `execve(2)` para **cada archivo coincidente**, creando miles de procesos hijo y destruyendo la eficiencia del pipeline del CPU.
   - **Mecánica de `-delete`:** La primitiva nativa `-delete` de BSD ejecuta llamadas al sistema del kernel internas `unlinkat(2)` o `rmdir(2)` directamente dentro del contexto del proceso `find` en ejecución. Elimina por completo la sobrecarga de creación de procesos, ejecutándose órdenes de magnitud más rápido en sistemas de archivos masivos.

2. **Respuesta:**
   - **Riesgo de seguridad:** `find` evalúa los argumentos de las expresiones secuencialmente de izquierda a derecha. Si se especifica `-delete` antes de las primitivas condicionales (por ejemplo, `find /tmp -delete -name "*.tmp"`), `find` evaluará `-delete` **primero** en cada archivo encontrado bajo `/tmp`, borrando todo el árbol de directorios independientemente de si el archivo coincide con `-name "*.tmp"`.
   - **Regla:** Las primitivas de acción operativa (`-delete`, `-exec`, `-print`) siempre deben colocarse al final de la cadena de argumentos después de todos los predicados de filtrado (`-type`, `-name`, `-mtime`).

</details>