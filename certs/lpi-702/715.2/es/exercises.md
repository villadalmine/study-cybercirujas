# LPI BSD Specialist (Examen 702-100) — Tema 715.2: Realizar la gestión básica de archivos

**Objetivo del examen:** 715.2 Realizar la gestión básica de archivos  
**Ponderación del tema:** 5  
**Certificación objetivo:** LPI BSD Specialist (702-100, Versión 1.0)  
**Referencia oficial:** [LPI BSD Specialist Overview & Objectives](https://www.lpi.org/our-certifications/bsd-specialist-overview/) | [FreeBSD Handbook: File Permissions](https://docs.freebsd.org/en/books/handbook/basics/#permissions) | [FreeBSD `chflags(1)` Manual](https://man.freebsd.org/cgi/man.cgi?query=chflags&sektion=1)

---

## 1. Visión general de la arquitectura y mecánica del sistema

### 1.1 Mecánica de Inodes, Directory Entries y Link Count
En sistemas de archivos BSD (tales como UFS2 y la capa POSIX de ZFS), un archivo consta de dos componentes distintos:
1. **Directory Entry (dentry):** Un mapeo entre un nombre legible por humanos y un número de inode dentro de un archivo de directorio.
2. **Inode:** La estructura de metadatos que almacena la propiedad del archivo (`uid`, `gid`), permisos (`mode`), listas de control de acceso (ACLs), file flags (`chflags`), marcas de tiempo (`atime`, `mtime`, `ctime`, `birthtime`), punteros a bloques de carga útil (payload) y el **link count (`nlink`)**.

```
 Directory Entry                 Inode Structure (UFS2 / ZFS)
+------------------+             +----------------------------------+
| Name: "app.log"  | ------------> Inode: 1048580                   |
| Inode: 1048580   |             |  - Owner: 1001 (www)             |
+------------------+             |  - Group: 1001 (www)             |
                                 |  - Mode: 0640 (-rw-r-----)        |
 Directory Entry                 |  - Link Count (nlink): 2         |
+------------------+             |  - Flags: uchg (User Immutable)  |
| Name: "hard.log" | ------------>  - Data Pointers -> Disk Blocks  |
| Inode: 1048580   |             +----------------------------------+
+------------------+
```

* **Hard Links (`ln target link`):** Crean una entrada de directorio (directory entry) adicional que apunta al *mismo* número de inode. Los hard links no pueden cruzar límites entre sistemas de archivos (ya que los números de inode son únicos para cada sistema de archivos) ni pueden apuntar a directorios (para evitar ciclos en el árbol VFS).
* **Symbolic Links (`ln -s target link`):** Crean un inode distinto de tipo `S_IFLNK` que contiene la cadena de la ruta (path string) del archivo objetivo. Los enlaces simbólicos pueden extenderse a través de diferentes sistemas de archivos y apuntar a directorios.
* **Semántica de Unlink (`rm` / `unlink`):** Ejecutar `rm` invoca `unlink(2)`. Esto decrementa el `nlink` en el inode y elimina la entrada de directorio. Los bloques del disco se liberan solo cuando `nlink == 0` **y** ningún proceso activo mantenga un file descriptor abierto apuntando al inode.

---

### 1.2 BSD File Flags (`chflags`)
Los sistemas BSD extienden los bits de modo POSIX tradicionales (`chmod`) con file flags impuestos por el kernel y configurados a través de `chflags(1)`. Estos flags proporcionan inmutabilidad a prueba de manipulaciones y restricciones de solo anexar (append-only), incluso frente a `root` cuando se ejecuta en securelevels elevados (`kern.securelevel > 0`).

| Nombre del Flag | Nombre corto | Descripción | Caso de uso en SRE / Producción |
| :--- | :--- | :--- | :--- |
| `uchg` / `nouchg` | `user immutable` | El archivo no puede ser modificado, renombrado, eliminado ni vinculado mediante hard-link por el propietario regular ni por root. | Protección de artefactos estáticos de despliegue y credenciales. |
| `schg` / `noschg` | `system immutable` | El archivo no puede ser modificado ni eliminado. Solo puede ser limpiado por root cuando `securelevel <= 0`. | Habilitación de hardening para cargas útiles binarias y configuraciones de arranque (`/sbin/init`). |
| `uappnd` / `nuappnd` | `user append-only` | El archivo solo se puede abrir en modo de anexo (`O_APPEND`). No se puede truncar ni sobrescribir. | Prevenir el truncamiento de archivos de registro (log) de aplicaciones. |
| `sappnd` / `nsappnd` | `system append-only` | Restricción de solo anexar a nivel de sistema. | Registros de auditoría a prueba de manipulaciones (`/var/log/security`). |
| `nodump` / `dump` | `nodump` | La utilidad de respaldo `dump(8)` omite el archivo. | Excluir archivos de caché o sockets efímeros de los respaldos. |

---

### 1.3 Mecánica de File Mode en BSD y `umask`
Los permisos de archivos en BSD se representan mediante un campo de modo de 12 bits:
* **Bits especiales (3 bits):** SUID (`4000`), SGID (`2000`), Sticky Bit (`1000`).
* **Bits del propietario (3 bits):** `r` (`4`), `w` (`2`), `x` (`1`).
* **Bits del grupo (3 bits):** `r` (`4`), `w` (`2`), `x` (`1`).
* **Bits de otros (3 bits):** `r` (`4`), `w` (`2`), `x` (`1`).

**Evaluación de Umask:** Al crear archivos (`open(..., O_CREAT)` por defecto `0666`) o directorios (`mkdir`, por defecto `0777`), el sistema aplica la `umask` del proceso mediante una operación a nivel de bits (bitwise):
$$\text{Modo Final} = \text{Modo por Defecto} \land \neg(\text{umask})$$

---

## 2. Ejercicios prácticos guiados

### Configuración del entorno de laboratorio
Inicie sesión en un sistema FreeBSD como un usuario con privilegios `sudo`. Abra una sesión de shell (`tcsh` o `sh`) y cree un directorio sandbox limpio:

```bash
mkdir -p /tmp/bsd_file_mgmt_lab && cd /tmp/bsd_file_mgmt_lab
```

---

### Ejercicio 1: Creación de árbol de directorios, expansión de comodines y eliminación segura

#### Paso 1.1: Crear una jerarquía anidada en una sola invocación atómica
Ejecute `mkdir` con el flag de creación recursiva de directorios:

```bash
mkdir -p prod_cluster/nodes/{node01,node02}/etc/sysctl.d
```

Salida esperada (sin salida en caso de éxito):
```bash
# Silent execution indicates success
```

Verifique la estructura del directorio usando `ls -R`:

```bash
ls -R prod_cluster
```

Salida esperada:
```
prod_cluster:
nodes

prod_cluster/nodes:
node01  node02

prod_cluster/nodes/node01:
etc

prod_cluster/nodes/node01/etc:
sysctl.d

prod_cluster/nodes/node01/etc/sysctl.d:

prod_cluster/nodes/node02:
etc

prod_cluster/nodes/node02/etc:
sysctl.d

prod_cluster/nodes/node02/etc/sysctl.d:
```

#### Paso 1.2: Poblar archivos y ejecutar operaciones de copia y movimiento en lote
Cree múltiples archivos de configuración usando expansión de llaves (bracket expansion):

```bash
touch prod_cluster/nodes/node01/etc/sysctl.d/{10-network.conf,20-security.conf,30-storage.conf}
ls -la prod_cluster/nodes/node01/etc/sysctl.d/
```

Salida esperada:
```
total 8
drwxr-xr-x  2 root  wheel  512 Aug  6 21:00 .
drwxr-xr-x  3 root  wheel  512 Aug  6 21:00 ..
-rw-r--r--  1 root  wheel    0 Aug  6 21:00 10-network.conf
-rw-r--r--  1 root  wheel    0 Aug  6 21:00 20-security.conf
-rw-r--r--  1 root  wheel    0 Aug  6 21:00 30-storage.conf
```

Copie todos los archivos de configuración de `node01` a `node02` usando `cp(1)` con el flag para preservar metadatos (`-p`):

```bash
cp -p prod_cluster/nodes/node01/etc/sysctl.d/*.conf prod_cluster/nodes/node02/etc/sysctl.d/
ls -la prod_cluster/nodes/node02/etc/sysctl.d/
```

Salida esperada:
```
total 8
drwxr-xr-x  2 root  wheel  512 Aug  6 21:00 .
drwxr-xr-x  3 root  wheel  512 Aug  6 21:00 ..
-rw-r--r--  1 root  wheel    0 Aug  6 21:00 10-network.conf
-rw-r--r--  1 root  wheel    0 Aug  6 21:00 20-security.conf
-rw-r--r--  1 root  wheel    0 Aug  6 21:00 30-storage.conf
```

Renombre `20-security.conf` a `20-hardening.conf` dentro de `node02` usando `mv(1)` con el flag para evitar sobrescrituras (`-n`):

```bash
mv -n prod_cluster/nodes/node02/etc/sysctl.d/20-security.conf prod_cluster/nodes/node02/etc/sysctl.d/20-hardening.conf
ls -1 prod_cluster/nodes/node02/etc/sysctl.d/
```

Salida esperada:
```
10-network.conf
20-hardening.conf
30-storage.conf
```

#### Paso 1.3: Limpiar directorios de forma segura
Intente eliminar un directorio no vacío con `rmdir(1)` frente a `rm -r`:

```bash
rmdir prod_cluster/nodes/node01/etc/sysctl.d
```

Salida esperada:
```
rmdir: prod_cluster/nodes/node01/etc/sysctl.d: Directory not empty
```

Ahora elimine el directorio limpiamente usando `rm -rf`:

```bash
rm -rf prod_cluster/nodes/node01
ls -1 prod_cluster/nodes/
```

Salida esperada:
```
node02
```

---

#### Preguntas de verificación — Ejercicio 1
1. **Pregunta 1.1:** ¿Cuál es la principal diferencia de comportamiento entre `cp -a` (o `cp -p`) y `cp` estándar con respecto a los metadatos de los archivos durante despliegues automatizados?
2. **Pregunta 1.2:** ¿Por qué falla `rmdir` en directorios no vacíos en la capa VFS y cómo resguarda esto los pipelines de producción en comparación con `rm -rf`?

---

### Ejercicio 2: Hard Links, Soft Links y análisis del conteo de referencias de Inodes

#### Paso 2.1: Crear archivo de origen e inspeccionar el estado inicial del inode
Cree un archivo llamado `app_v1.bin` e inspeccione su número de inode y su link count usando `ls -i -l`:

```bash
echo "binary_v1.0_payload" > app_v1.bin
ls -i -l app_v1.bin
```

Salida esperada (el número de inode variará):
```
1048600 -rw-r--r--  1 root  wheel  20 Aug  6 21:00 app_v1.bin
```
*(Observe que el link count es `1` en la columna 3).*

#### Paso 2.2: Crear un hard link y verificar el inode compartido
Cree un hard link llamado `app_current.bin` que apunte a `app_v1.bin`:

```bash
ln app_v1.bin app_current.bin
ls -i -l app_v1.bin app_current.bin
```

Salida esperada:
```
1048600 -rw-r--r--  2 root  wheel  20 Aug  6 21:00 app_current.bin
1048600 -rw-r--r--  2 root  wheel  20 Aug  6 21:00 app_v1.bin
```
*(Observe que ambos archivos comparten el inode `1048600`, y que el link count aumentó a `2`).*

#### Paso 2.3: Crear un enlace simbólico e inspeccionar la estructura de la entrada
Cree un enlace simbólico llamado `app_symlink.bin` que apunte a `app_v1.bin`:

```bash
ln -s app_v1.bin app_symlink.bin
ls -i -l app_v1.bin app_symlink.bin
```

Salida esperada:
```
1048600 -rw-r--r--  2 root  wheel  20 Aug  6 21:00 app_v1.bin
1048601 lrwxr-xr-x  1 root  wheel  10 Aug  6 21:00 app_symlink.bin -> app_v1.bin
```
*(Observe que `app_symlink.bin` tiene un nuevo inode `1048601`, tipo de archivo `l`, y un tamaño de 10 coincidiendo con la longitud de la cadena del objetivo `"app_v1.bin"`).*

#### Paso 2.4: Probar el comportamiento de unlink eliminando el archivo objetivo
Elimine el archivo original `app_v1.bin`:

```bash
rm app_v1.bin
ls -i -l app_current.bin app_symlink.bin
```

Salida esperada:
```
1048600 -rw-r--r--  1 root  wheel  20 Aug  6 21:00 app_current.bin
1048601 lrwxr-xr-x  1 root  wheel  10 Aug  6 21:00 app_symlink.bin -> app_v1.bin
```

Pruebe leer los datos a través de ambos enlaces:

```bash
cat app_current.bin
```
Salida esperada:
```
binary_v1.0_payload
```

```bash
cat app_symlink.bin
```
Salida esperada:
```
cat: app_symlink.bin: No such file or directory
```

---

#### Preguntas de verificación — Ejercicio 2
1. **Pregunta 2.1:** ¿Por qué `cat app_current.bin` tiene éxito después de eliminar `app_v1.bin`, mientras que `cat app_symlink.bin` falla con `No such file or directory`?
2. **Pregunta 2.2:** Si un proceso tiene `app_v1.bin` abierto para lectura y usted ejecuta `rm app_v1.bin` y `rm app_current.bin`, ¿cuándo reclama el kernel los bloques de disco subyacentes?

---

### Ejercicio 3: BSD File Flags avanzados (`chflags`), propiedad y hardening de inmutabilidad

#### Paso 3.1: Configurar propiedad y permisos
Cree un archivo llamado `audit_vault.key`:

```bash
touch audit_vault.key
chmod 0600 audit_vault.key
chown root:wheel audit_vault.key
ls -l audit_vault.key
```

Salida esperada:
```
-rw-------  1 root  wheel  0 Aug  6 21:00 audit_vault.key
```

#### Paso 3.2: Aplicar inmutabilidad de usuario (`uchg`) y probar restricciones de escritura
Aplique el flag `uchg` a `audit_vault.key` usando `chflags(1)`:

```bash
chflags uchg audit_vault.key
```

Verifique el estado del flag usando `ls -lo`:

```bash
ls -lo audit_vault.key
```

Salida esperada:
```
-rw-------  1 root  wheel  uchg 0 Aug  6 21:00 audit_vault.key
```

Intente anexar datos, renombrar o eliminar el archivo (incluso como `root`):

```bash
echo "secret" >> audit_vault.key
```
Salida esperada:
```
sh: audit_vault.key: Operation not permitted
```

```bash
rm audit_vault.key
```
Salida esperada:
```
override r-------- root/wheel uchg for audit_vault.key? y
rm: audit_vault.key: Operation not permitted
```

#### Paso 3.3: Remover flags y aplicar protección de solo anexar (`uappnd`)
Limpie el flag inmutable y establezca el flag de solo anexar (append-only):

```bash
chflags nouchg audit_vault.key
chflags uappnd audit_vault.key
ls -lo audit_vault.key
```

Salida esperada:
```
-rw-------  1 root  wheel  uappnd 0 Aug  6 21:00 audit_vault.key
```

Pruebe operaciones de anexo (append) frente a sobrescritura (overwrite):

```bash
# Valid: Appending data
echo "audit_log_entry_1" >> audit_vault.key
cat audit_vault.key
```
Salida esperada:
```
audit_log_entry_1
```

```bash
# Invalid: Overwriting/truncating data
echo "overwrite_attempt" > audit_vault.key
```
Salida esperada:
```
sh: audit_vault.key: Operation not permitted
```

Limpie el flag para desmontar/eliminar el laboratorio:

```bash
chflags nuappnd audit_vault.key
rm audit_vault.key
```

---

#### Preguntas de verificación — Ejercicio 3
1. **Pregunta 3.1:** ¿Cuál es la diferencia entre los flags `uchg` y `schg` en sistemas BSD que operan con `kern.securelevel = 1`?
2. **Pregunta 3.2:** ¿Qué opción de flag se debe pasar a `ls(1)` en sistemas BSD para inspeccionar los file flags como `uchg`, `schg` y `nodump`?

---

### Ejercicio 4: Dinámica de Umask, bits de permisos especiales (SUID/SGID/Sticky) e invalidación de directorios

#### Paso 4.1: Calcular y verificar las máscaras bitwise de `umask`
Verifique la `umask` actual:

```bash
umask
```
Salida esperada:
```
0022
```

Establezca umask en `0027` y cree archivos y directorios de prueba:

```bash
umask 0027
touch secure_file.txt
mkdir secure_dir
ls -ld secure_file.txt secure_dir
```

Salida esperada:
```
drwxr-x---  2 root  wheel  512 Aug  6 21:00 secure_dir
-rw-r-----  1 root  wheel    0 Aug  6 21:00 secure_file.txt
```

#### Paso 4.2: Aplicar el sticky bit y probar el aislamiento de directorios compartidos
Cree un directorio compartido y establezca el sticky bit (`1000` / `t`):

```bash
mkdir shared_dropzone
chmod 1777 shared_dropzone
ls -ld shared_dropzone
```

Salida esperada:
```
drwxrwxrwt  2 root  wheel  512 Aug  6 21:00 shared_dropzone
```

#### Paso 4.3: Aplicar el bit SGID en un directorio para la herencia automática de grupo
Cree un directorio con el bit SGID (`2000` / `g+s`):

```bash
mkdir shared_team
chmod 2775 shared_team
ls -ld shared_team
```

Salida esperada:
```
drwxrwsr-x  2 root  wheel  512 Aug  6 21:00 shared_team
```

Restablezca la `umask` al valor estándar `0022`:

```bash
umask 0022
```

---

#### Preguntas de verificación — Ejercicio 4
1. **Pregunta 4.1:** ¿Por qué `touch secure_file.txt` produjo permisos `-rw-r-----` (`0640`) cuando se creó bajo `umask 0027`?
2. **Pregunta 4.2:** En un entorno de producción multitenant en FreeBSD, ¿qué riesgo de seguridad mitiga la configuración del Sticky Bit (`chmod +t`) en directorios públicos con permisos de escritura como `/tmp`?

---

<details>
<summary><strong>3. Respuestas exhaustivas y explicaciones detalladas para SRE</strong></summary>

### Soluciones del Ejercicio 1 y explicaciones mecánicas
* **Respuesta 1.1:** `cp -p` preserva explícitamente las marcas de tiempo (`atime`, `mtime`), el `uid` del propietario, el `gid` del grupo, los permisos de archivo (`mode`), atributos extendidos y file flags (`chflags`). La orden `cp` estándar crea nuevos archivos de destino utilizando las credenciales del proceso actual (`uid`/`gid`) y evalúa los permisos frente a la `umask` activa. En pipelines de producción (por ejemplo, despliegues de software), los metadatos no preservados provocan errores de permiso denegado o trazas de auditoría inconsistentes.
* **Respuesta 1.2:** En la capa VFS, `rmdir(2)` comprueba si el link count del directorio objetivo es mayor a 2 (`.` y `..`) o si los bloques del directorio contienen entradas distintas de `.` y `..`. Si existen entradas, retorna `ENOTEMPTY` (`Directory not empty`). Esto evita la destrucción recursiva accidental de subárboles de directorios. `rm -rf` elude esto realizando un recorrido post-orden (post-order traversal) para invocar `unlink(2)` en todos los archivos hijos y `rmdir(2)` en los directorios hijos vacíos secuencialmente.

---

### Soluciones del Ejercicio 2 y explicaciones mecánicas
* **Respuesta 2.1:** `app_current.bin` es un hard link que apunta directamente al Inode `1048600`. Eliminar `app_v1.bin` invoca `unlink("app_v1.bin")`, removiendo la entrada de directorio (directory entry) de `app_v1.bin` y decrementando el link count del inode de `2` a `1`. El inode `1048600` permanece intacto, por lo que `cat app_current.bin` accede directamente a los bloques de datos. Por el contrario, `app_symlink.bin` es un enlace simbólico que contiene la cadena con la ruta `"app_v1.bin"`. Cuando se elimina `app_v1.bin`, la ruta objetivo ya no se resuelve durante la búsqueda en VFS (path lookup), convirtiendo a `app_symlink.bin` en un enlace roto o huérfano (dangling link, `ENOENT`).
* **Respuesta 2.2:** El kernel reclama los bloques de disco únicamente cuando se cumplen **ambas** condiciones:
  1. El link count (`nlink`) del inode cae a cero.
  2. El conteo de referencias de file descriptors mantenido por los procesos activos en la tabla de procesos del kernel cae a cero.  
  Mientras un proceso mantenga un file descriptor abierto (`open(2)`), el kernel mantiene el inode y los bloques de datos asignados en el sistema de archivos, incluso si `rm` ha desvinculado todas las entradas de directorio del disco. Cuando el proceso termina o invoca `close(2)`, el sistema de archivos libera los bloques.

---

### Soluciones del Ejercicio 3 y explicaciones mecánicas
* **Respuesta 3.1:** 
  * `uchg` (User Immutable): Puede ser establecido o limpiado por el propietario del archivo o por `root` en cualquier securelevel.
  * `schg` (System Immutable): Solo puede ser modificado por `root`. Además, si el nivel de seguridad del sistema (`sysctl kern.securelevel`) es mayor que `0` (por ejemplo, en modo de hardening en producción), incluso a `root` se le prohíbe limpiar `schg`. El sistema debe reiniciarse en modo monousuario (single-user mode) para reducir el securelevel antes de que se pueda remover `schg`.
* **Respuesta 3.2:** El flag de opción `-o` (`ls -lo`). En FreeBSD, `ls -lo` muestra la columna de file flags (por ejemplo, `uchg`, `uappnd`, `schg`, `nodump`, o `-` si no hay flags establecidos).

---

### Soluciones del Ejercicio 4 y explicaciones mecánicas
* **Respuesta 4.1:** Los archivos se crean por defecto con una máscara base `0666` (lectura + escritura para propietario, grupo y otros; el bit ejecutable `x` se omite por seguridad al crear archivos no ejecutables).
  Aplicando `umask 0027`:
  $$\text{Modo Base} = 0666_2 = 110\,110\,110_2$$
  $$\text{Umask} = 0027_2 = 000\,010\,111_2$$
  $$\text{Cálculo Bitwise de la Máscara} = 0666 \land \neg(0027) = 0640 \quad (\text{-rw-r-----})$$
  * Propietario (Owner): `rw-` (`6`)
  * Grupo: `r--` (`4`)
  * Otros: `---` (`0`)
* **Respuesta 4.2:** En directorios compartidos con permisos `0777`, cualquier usuario con permiso de escritura puede eliminar o renombrar archivos creados por otros usuarios. Configurar el **Sticky Bit** (`1000` / `t` en el directorio) impone una comprobación a nivel de kernel durante `unlink(2)` y `rename(2)`: un usuario solo puede eliminar o renombrar archivos dentro del directorio si es el **propietario del archivo**, el **propietario del directorio** o `root`. Esto evita que usuarios no privilegiados sobrescriban o eliminen los archivos temporales o sockets de otros usuarios en `/tmp` y `/var/tmp`.

</details>

---

## 4. Hoja de referencia (Cheatsheet) de verificación y diagnóstico en producción

### Comandos de diagnóstico para la gestión de archivos en BSD

```bash
# Display inode numbers, human-readable size, and file flags in a single view
ls -liho /path/to/target

# Locate all files with the 'uchg' or 'schg' immutable flag set under /var
find /var -flags +uchg,schg -ls

# View files with open file descriptors that have been unlinked from disk (FreeBSD fstat)
fstat | grep -E "vnode.*unlinked| Mount"

# Recursively change ownership only if current owner matches user 'www'
chown -h -R --from=www nginx:nginx /var/www/data

# Display file system information and free inodes (UFS/ZFS)
df -ih
```

---

## Resumen del trabajo completado
- **Material del curso**: Se produjo una guía de nivel de producción para LPI-702 (Examen 702-100) Tema 715.2 (Realizar la gestión básica de archivos).
- **Cobertura técnica**: Se cubrió la mecánica de inodes, link count (`nlink`), enlaces duros (hard links) frente a simbólicos, semántica de desvinculación (unlinking) en VFS, BSD file flags (`chflags`), enmascaramiento bitwise de permisos con `umask` y bits especiales (`SUID`/`SGID`/`Sticky`).
- **Ejercicios prácticos**: Se incluyeron 4 laboratorios detallados y guiados paso a paso con salidas de shell y preguntas de verificación.
- **Clave de respuestas**: Se proporcionaron explicaciones técnicas profundas y demostraciones matemáticas de permisos dentro de un bloque desplegable `<details>`.