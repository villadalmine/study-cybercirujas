# LPI-702 (Examen 702-100 v1.0) Tema 712.4: Gestión de permisos y propiedad de archivos

**Weight:** 5  
**Official References:**
* [LPI BSD Specialist Certification Overview](https://www.lpi.org/our-certifications/bsd-specialist-overview/)
* [FreeBSD Handbook: File Permissions](https://docs.freebsd.org/en/books/handbook/basics/#permissions)
* [FreeBSD Manual Pages: chmod(1)](https://man.freebsd.org/cgi/man.cgi?query=chmod&sektion=1)
* [FreeBSD Manual Pages: chflags(1)](https://man.freebsd.org/cgi/man.cgi?query=chflags&sektion=1)
* [FreeBSD Manual Pages: setfacl(1)](https://man.freebsd.org/cgi/man.cgi?query=setfacl&sektion=1)
* [FreeBSD Manual Pages: getfacl(1)](https://man.freebsd.org/cgi/man.cgi?query=getfacl&sektion=1)

---

## Exercise 1: Standard POSIX Permissions, Ownership, and Umask Mechanics

### Objetivo
Comprender los bits de modo de permiso del inodo subyacentes (`st_mode`), el mapeo de ID de usuario/grupo (`st_uid`/`st_gid`), las representaciones octales vs. simbólicas y la resta de máscara bit a bit de los procesos (`umask`) en sistemas BSD.

---

### Pasos prácticos

1. Crear un espacio de trabajo dedicado e inspeccionar el comportamiento predeterminado de `umask` durante la creación de archivos y directorios.

```bash
$ mkdir -p /tmp/permission_lab && cd /tmp/permission_lab
$ umask
0022
$ touch standard_file.txt
$ mkdir standard_dir
$ ls -ld standard_file.txt standard_dir
drwxr-xr-x  2 student  wheel  512 Aug  6 20:30 standard_dir
-rw-r--r--  1 student  wheel    0 Aug  6 20:30 standard_file.txt
```

2. Realizar mutaciones de permisos octales y simbólicos usando `chmod`, observando cómo los bits `st_mode` se mapean a Lectura (4), Escritura (2) y Ejecución (1) a lo largo de los niveles User, Group y Other.

```bash
$ chmod 0640 standard_file.txt
$ ls -l standard_file.txt
-rw-r-----  1 student  wheel  0 Aug  6 20:30 standard_file.txt

$ chmod g+w,o-r standard_file.txt
$ ls -l file_permission_check
-rw-rw----  1 student  wheel  0 Aug  6 20:30 standard_file.txt
```

3. Cambiar la propiedad de usuario y grupo usando `chown` y `chgrp`. Tenga en cuenta que en sistemas BSD, los usuarios que no son root no pueden ceder la propiedad de los archivos (`chown` está restringido por `sysctl security.bsd.see_other_uids` y las comprobaciones de seguridad del kernel VFS). Cambie a `root` o use `sudo` para reasignar la propiedad.

```bash
$ sudo chown www:www standard_file.txt
$ ls -l standard_file.txt
-rw-rw----  1 www  www  0 Aug  6 20:30 standard_file.txt

$ sudo chgrp daemon standard_file.txt
$ ls -l standard_file.txt
-rw-rw----  1 www  daemon  0 Aug  6 20:30 standard_file.txt
```

4. Modificar el `umask` del proceso dinámicamente y observar cómo el filtro de complemento bit a bit se aplica a los permisos de creación máximos (`0666` para archivos regulares, `0777` para directorios).

```bash
$ umask 0077
$ touch strict_file.txt
$ mkdir strict_dir
$ ls -ld strict_file.txt strict_dir
drx------  2 student  wheel  512 Aug  6 20:32 strict_dir
-rw-------  1 student  wheel    0 Aug  6 20:32 strict_file.txt
```

---

### Preguntas de verificación

1. **Pregunta 1.1:** Si un proceso con un `umask` de `0027` crea un directorio usando `mkdir()`, ¿cuáles son los permisos octales y simbólicos precisos asignados al inodo del directorio? Muestre el cálculo bit a bit.
2. **Pregunta 1.2:** ¿Por qué un archivo regular creado bajo `umask 0000` obtiene permisos `0666` en lugar de `0777`? ¿Qué parámetro de llamada al sistema dicta este límite?

---

## Exercise 2: Special Permission Bits (SUID, SGID, Sticky Bit) and Directory Inheritance

### Objetivo
Dominar el comportamiento operativo y las implicaciones de seguridad de los bits SUID (`4000`), SGID (`2000`) y Sticky (`1000`) en binarios ejecutables y directorios en sistemas de archivos BSD.

---

### Pasos prácticos

1. Crear una jerarquía de directorios compartidos para examinar la herencia de propiedad de grupo a través del bit SGID (`chmod 2770` o `chmod g+s`).

```bash
$ sudo mkdir -p /tmp/permission_lab/shared_project
$ sudo chown root:wheel /tmp/permission_lab/shared_project
$ sudo chmod 2770 /tmp/permission_lab/shared_project
$ ls -ld /tmp/permission_lab/shared_project
drwxrws---  2 root  wheel  512 Aug  6 20:35 /tmp/permission_lab/shared_project
```

2. Crear un archivo dentro del directorio habilitado para SGID como usuario `student` (que pertenece a un grupo no primario o grupo predeterminado) y verificar la herencia del ID de grupo.

```bash
$ cd /tmp/permission_lab/shared_project
$ touch team_doc.txt
$ ls -l team_doc.txt
-rw-r--r--  1 student  wheel  0 Aug  6 20:36 team_doc.txt
```

> **Nota de arquitectura de BSD:** En sistemas BSD, los directorios heredan la propiedad de grupo de su directorio padre por defecto tras la creación, incluso sin el bit SGID establecido. Establecer el bit SGID en un directorio garantiza adicionalmente que cualquier subdirectorio creado dentro también heredará el bit SGID.

3. Configurar un directorio de escritura pública con el Sticky Bit (`chmod 1777` o `chmod +t`) para evitar que los usuarios no privilegiados eliminen o renombren archivos propiedad de otros.

```bash
$ sudo mkdir -p /tmp/permission_lab/public_drop
$ sudo chmod 1777 /tmp/permission_lab/public_drop
$ ls -ld /tmp/permission_lab/public_drop
drwxrwxrwt  2 root  wheel  512 Aug  6 20:38 /tmp/permission_lab/public_drop
```

4. Crear un binario ficticio y examinar la aplicación del bit SUID (`chmod 4755` o `chmod u+s`). Observe cómo la `S` mayúscula indica que faltan derechos de ejecución para el propietario/grupo.

```bash
$ cp /bin/echo /tmp/permission_lab/custom_echo
$ sudo chmod 4755 /tmp/permission_lab/custom_echo
$ ls -l /tmp/permission_lab/custom_echo
-rwsr-xr-x  1 root  wheel  24128 Aug  6 20:40 /tmp/permission_lab/custom_echo

$ chmod u-x /tmp/permission_lab/custom_echo
$ ls -l /tmp/permission_lab/custom_echo
-rwSr-xr-x  1 root  wheel  24128 Aug  6 20:40 /tmp/permission_lab/custom_echo
```

---

### Preguntas de verificación

1. **Pregunta 2.1:** En un directorio configurado con `chmod 1777`, el usuario `alice` crea un archivo `data.log`. ¿Puede el usuario `bob` (quien tiene permisos completos de escritura en `data.log` a través de permisos de grupo) eliminar o renombrar `data.log`? ¿Por qué sí o por qué no?
2. **Pregunta 2.2:** ¿Cuál es el significado técnico de la `S` mayúscula frente a la `s` minúscula en la salida de `ls -l` para los campos de permisos de usuario y grupo?

---

## Exercise 3: BSD Extended File Flags (`chflags`) and Securelevel Enforcement

### Objetivo
Comprender el subsistema de flags de archivo extendidos específico de BSD (`st_flags`), incluidos los flags de usuario (`uchg`, `uappnd`) y los flags de sistema (`schg`, `sappnd`), y su interacción con `sysctl kern.securelevel`.

---

### Pasos prácticos

1. Crear un archivo de configuración crítico y listar los flags de archivo extendidos usando `ls -lo` (visualización detallada de flags específica de BSD).

```bash
$ cd /tmp/permission_lab
$ touch critical_config.conf
$ ls -lo critical_config.conf
-rw-r--r--  1 student  wheel  - 0 Aug  6 20:42 critical_config.conf
```

2. Aplicar el flag User Immutable (`uchg`) para evitar la modificación, el renombrado o la eliminación, incluso por parte del propietario del archivo o de `root` (cuando `kern.securelevel` es bajo).

```bash
$ chflags uchg critical_config.conf
$ ls -lo critical_config.conf
-rw-r--r--  1 student  wheel  uchg 0 Aug  6 20:42 critical_config.conf

$ rm critical_config.conf
rm: critical_config.conf: Operation not permitted

$ echo "malicious append" >> critical_config.conf
bash: critical_config.conf: Operation not permitted
```

3. Remover el flag User Immutable usando el prefijo `no` (`nouchg`).

```bash
$ chflags nouchg critical_config.conf
$ ls -lo critical_config.conf
-rw-r--r--  1 student  wheel  - 0 Aug  6 20:43 critical_config.conf
```

4. Aplicar el flag User Append-Only (`uappnd`) y probar las restricciones de escritura.

```bash
$ chflags uappnd critical_config.conf
$ ls -lo critical_config.conf
-rw-r--r--  1 student  wheel  uappnd 0 Aug  6 20:44 critical_config.conf

$ echo "line 1" >> critical_config.conf
$ cat critical_config.conf
line 1

$ echo "overwrite" > critical_config.conf
bash: critical_config.conf: Operation not permitted
```

5. Limpiar los flags e inspeccionar el comportamiento del flag System Immutable (`schg`) y el estado de `kern.securelevel`.

```bash
$ chflags nouappnd critical_config.conf
$ sudo chflags schg critical_config.conf
$ ls -lo critical_config.conf
-rw-r--r--  1 student  wheel  schg 7 Aug  6 20:45 critical_config.conf

$ sysctl kern.securelevel
kern.securelevel: -1
```

> **Nota de arquitectura de seguridad:** Cuando `kern.securelevel` es `-1` o `0`, `root` puede limpiar `schg` mediante `sudo chflags noschg`. Sin embargo, cuando `kern.securelevel >= 1`, los flags `schg` **no pueden** ser removidos por ningún proceso (incluido `root`), evitando el compromiso incluso si se adquieren privilegios de superusuario.

---

### Preguntas de verificación

1. **Pregunta 3.1:** ¿Cuál es la diferencia fundamental entre `uchg` (User Immutable) y `schg` (System Immutable)? ¿Quién puede establecer y desestablecer cada flag?
2. **Pregunta 3.2:** Si `sysctl kern.securelevel` devuelve `1`, ¿puede root limpiar el flag `schg` en `/sbin/init`? ¿Qué intervención administrativa se requiere para modificar un archivo bloqueado con `schg` en `securelevel 1`?

---

## Exercise 4: Granular Control with FreeBSD POSIX.1e and NFSv4 Access Control Lists (ACLs)

### Objetivo
Desplegar, auditar y remover Listas de Control de Acceso (ACLs) POSIX.1e y NFSv4 usando `getfacl` y `setfacl` en sistemas de archivos FreeBSD (UFS y ZFS).

---

### Pasos prácticos

1. Comprobar el tipo de sistema de archivos de destino y la configuración del soporte de ACL (`tunefs` para UFS o propiedades `aclmode`/`aclinherit` para ZFS).

```bash
$ zfs get aclmode,aclinherit zroot/tmp
NAME       PROPERTY    VALUE          SOURCE
zroot/tmp  aclmode     passthrough    default
zroot/tmp  aclinherit  passthrough    default
```

2. Crear un archivo para la manipulación de ACL e inspeccionar su estructura de ACL predeterminada usando `getfacl`.

```bash
$ cd /tmp/permission_lab
$ touch acl_file.txt
$ getfacl acl_file.txt
# file: acl_file.txt
# owner: student
# group: wheel
user::rw-
group::r--
other::r--
```

3. Otorgar permisos específicos de lectura y escritura a un usuario explícito (`operator`) usando `setfacl -m` (formato POSIX.1e). Observe cómo aparece el `+` al final en la salida estándar de `ls -l` cuando existen entradas de ACL.

```bash
$ setfacl -m u:operator:rw- acl_file.txt
$ getfacl acl_file.txt
# file: acl_file.txt
# owner: student
# group: wheel
user::rw-
user:operator:rw-
group::r--
mask::rw-
other::r--

$ ls -l acl_file.txt
-rw-rw-r--+ 1 student  wheel  0 Aug  6 20:50 acl_file.txt
```

4. Modificar la entrada de máscara POSIX.1e (`mask::`) para restringir los permisos máximos efectivos para usuarios y grupos nombrados.

```bash
$ setfacl -m m::r-- acl_file.txt
$ getfacl acl_file.txt
# file: acl_file.txt
# owner: student
# group: wheel
user::rw-
user:operator:rw-	#effective:r--
group::r--
mask::r--
other::r--
```

5. Remover entradas de ACL específicas (`setfacl -x`) o eliminar todas las entradas de ACL extendidas (`setfacl -b`).

```bash
$ setfacl -x u:operator acl_file.txt
$ getfacl acl_file.txt
# file: acl_file.txt
# owner: student
# group: wheel
user::rw-
group::r--
mask::r--
other::r--

$ setfacl -b acl_file.txt
$ ls -l acl_file.txt
-rw-r--r--  1 student  wheel  0 Aug  6 20:52 acl_file.txt
```

---

### Preguntas de verificación

1. **Pregunta 4.1:** ¿Cómo recalcula la entrada `mask::` de POSIX.1e los *permisos efectivos* para las entradas de ACL explícitas de usuario (`u:name:`) y grupo (`g:name:`)?
2. **Pregunta 4.2:** ¿Qué carácter en la salida de `ls -l` señala que un archivo tiene entradas de ACL extendidas en FreeBSD, y cómo difiere la salida de ACL NFSv4 de ZFS respecto a la salida POSIX.1e en `getfacl`?

---

## Solutions & Detailed Explanations

<details>
<summary>Click here to expand solutions for Exercises 1 to 4</summary>

### Soluciones del Ejercicio 1

* **Respuesta 1.1:**
  * **Octal Permissions:** `0750`
  * **Symbolic Permissions:** `drwxr-x---`
  * **Bitwise Calculation:**
    Los directorios evalúan el modo de creación base `0777` (`111 111 111` en binario).
    `umask 0027` (`000 010 111` en binario).
    Fórmula: $\text{Mode} = \text{Base} \land \neg(\text{Umask})$
    $$\text{User}: 7 \land \neg(0) = 7 \quad (rwx)$$
    $$\text{Group}: 7 \land \neg(2) = 5 \quad (r-x)$$
    $$\text{Other}: 7 \land \neg(7) = 0 \quad (---)$$
    El modo octal resultante es `0750` (`drwxr-x---`).

* **Respuesta 1.2:**
  Las llamadas al sistema POSIX (`open(2)`, `creat(2)`) especifican una máscara de creación máxima de `0666` (`rw-rw-rw-`) para archivos por defecto para evitar crear automáticamente riesgos de seguridad ejecutables. El bit de ejecución (`x`) se retiene intencionalmente a menos que el binario de la aplicación lo pase explícitamente durante la invocación. `umask` resta permisos de esta base `0666` para archivos regulares.

---

### Soluciones del Ejercicio 2

* **Respuesta 2.1:**
  **No, el usuario `bob` no puede eliminar ni renombrar `data.log`.**  
  Bajo el Sticky Bit (`+t` / `1000`) en un directorio, los permisos de escritura en el directorio por sí solos no otorgan derechos de desvinculación (eliminación) ni de renombrado de archivos. Un usuario solo puede eliminar/renombrar un archivo dentro de un directorio sticky si se cumple al menos una de las siguientes condiciones:
  1. El usuario es el propietario del archivo (coincide `st_uid`).
  2. El usuario es el propietario del directorio (coincide `st_uid` del directorio).
  3. El usuario es `root` (privilegios de superusuario).

* **Respuesta 2.2:**
  * **`s` minúscula (`rwsr-xr-x` / `rwxr-sr-x`):** Indica que el bit SUID/SGID está establecido **Y** que el bit de ejecución correspondiente del propietario/grupo (`x`) también está establecido.
  * **`S` mayúscula (`rwSr-xr-x` / `rwxr-Sr-x`):** Indica que el bit SUID/SGID está establecido **PERO** que el bit de ejecución subyacente del propietario/grupo (`x`) **NO** está establecido (lo que indica un posible descuido de configuración).

---

### Soluciones del Ejercicio 3

* **Respuesta 3.1:**
  * **`uchg` (User Immutable):** Puede ser establecido o eliminado por el propietario del archivo o por `root`. Evita la modificación, eliminación, renombrado o creación de enlaces del archivo.
  * **`schg` (System Immutable):** **Solo** puede ser establecido o eliminado por `root`. Además, su eliminación depende strictly de `sysctl kern.securelevel`.

* **Respuesta 3.2:**
  **No, root no puede limpiar `schg` mientras `kern.securelevel >= 1`.**  
  Para modificar o limpiar `schg` en `/sbin/init` cuando se ejecuta en `securelevel 1`:
  1. Editar `/etc/rc.conf` para ajustar la configuración de securelevel (o iniciar en modo monousuario).
  2. Reiniciar el sistema operativo en modo monousuario (donde `securelevel` tiene como valor predeterminado `-1` o `0`).
  3. Ejecutar `chflags noschg /sbin/init`.
  4. Realizar el mantenimiento requerido y reiniciar de nuevo a la operación multiusuario.

---

### Soluciones del Ejercicio 4

* **Respuesta 4.1:**
  En las ACLs POSIX.1e, la entrada `mask::` define el **límite máximo de permisos permitido** para todos los usuarios nombrados (`u:username:`), grupos nombrados (`g:groupname:`) y el grupo primario (`group::`). El permiso efectivo otorgado a cualquier entidad nombrada se calcula mediante una operación AND bit a bit entre la entrada de permiso de esa entidad y la entrada `mask::`:
  $$\text{Effective Permission} = \text{ACL Entry} \land \text{Mask Entry}$$
  Si `user:operator` tiene `rw-` (4+2=6) y `mask::` está establecido en `r--` (4), el permiso efectivo resultante es `r--` (4).

* **Respuesta 4.2:**
  * El **signo más (`+`)** al final de la cadena de modo en `ls -l` (por ejemplo, `-rw-rw-r--+`) indica que existen entradas de ACL extendidas en el vnode.
  * Las **ACLs POSIX.1e** (UFS) muestran los permisos en el formato estándar `user/group/mask/other`.
  * Las **ACLs NFSv4** (predeterminadas en ZFS) muestran entradas de acceso detalladas y de gran granularidad con flags de herencia explícitos y privilegios detallados (por ejemplo, `user:alice:read_data/write_data/append_data/allow`).

</details>