# LPI-702 (Exam 702-100) Tema 713.1: Administrar cuentas de usuario y grupos

**Objetivo de certificación:** LPI BSD Specialist (Exam 702-100, Version 1.0)  
**Código del tema:** 713.1 — Manage User Accounts and Groups  
**Peso del examen:** 5  

---

## 1. Visión general de la arquitectura del sistema y mecánica técnica

En los sistemas BSD (FreeBSD, OpenBSD, NetBSD), la administración de cuentas de usuario y grupos difiere fundamentalmente de las distribuciones Linux. En lugar de utilizar el análisis sintáctico (parsing) estándar de archivos de texto plano de `/etc/passwd` y `/etc/shadow` en cada evento de autenticación del sistema, los sistemas BSD mantienen bases de datos indexadas Berkeley DB (formato `.db`) para búsquedas lineales $O(1)$ bajo alta concurrencia.

```
                  +-----------------------------------+
                  |   /etc/master.passwd (0600)       |
                  | 10 Fields (Includes Password Hash)|
                  +-----------------------------------+
                                    |
                                    |  (via vipw or pwd_mkdb)
                                    v
            +-----------------------+-----------------------+
            |                                               |
            v                                               v
+-----------------------+                       +-----------------------+
|  /etc/passwd (0644)   |                       | /etc/spwd.db (0600)   |
| Insecure (No Hashes)  |                       | Indexed DB w/ Hashes  |
+-----------------------+                       +-----------------------+
            |                                               |
            v                                               v
+-----------------------+                       +-----------------------+
|  /etc/pwd.db (0644)   |                       | /etc/login.conf       |
| Insecure Indexed DB   |                       | Resource Limits       |
+-----------------------+                       +-----------------------+
                                                            |
                                                            | (via cap_mkdb)
                                                            v
                                                +-----------------------+
                                                | /etc/login.conf.db    |
                                                +-----------------------+
```

### La estructura de 10 campos de `master.passwd`
A diferencia del archivo `/etc/passwd` de 7 campos que se encuentra en los sistemas System V y Linux, la fuente de autenticación maestra de BSD `/etc/master.passwd` contiene 10 campos separados por dos puntos:

```
name:password:uid:gid:class:change:expire:gecos:home_dir:shell
```

1. **`name`**: Nombre de login único del usuario.
2. **`password`**: Hash de contraseña cifrada (por ejemplo, Argon2, bcrypt o SHA-512). Se establece en `*` o `*LOCKED*` para evitar el login.
3. **`uid`**: Entero del User ID.
4. **`gid`**: Entero del Primary Group ID.
5. **`class`**: Login class mapeada a `/etc/login.conf` (por ejemplo, `default`, `staff`, `untrusted`).
6. **`change`**: Tiempo de cambio de contraseña en segundos desde la época Unix (0 = deshabilitado).
7. **`expire`**: Tiempo de expiración de la cuenta en segundos desde la época Unix (0 = deshabilitado).
8. **`gecos`**: Información del usuario (Nombre completo, Oficina, Teléfono de oficina, Teléfono particular).
9. **`home_dir`**: Ruta absoluta al home directory del usuario.
10. **`shell`**: Ruta absoluta a la login shell del usuario.

### Documentación de referencia oficial
* Descripción general de LPI BSD Specialist: [https://www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)
* Manual de FreeBSD `master.passwd`: [https://man.freebsd.org/cgi/man.cgi?query=master.passwd&sektion=5](https://man.freebsd.org/cgi/man.cgi?query=master.passwd&sektion=5)
* Manual de FreeBSD `pwd_mkdb`: [https://man.freebsd.org/cgi/man.cgi?query=pwd_mkdb&sektion=8](https://man.freebsd.org/cgi/man.cgi?query=pwd_mkdb&sektion=8)
* Manual de la utilidad FreeBSD `pw`: [https://man.freebsd.org/cgi/man.cgi?query=pw&sektion=8](https://man.freebsd.org/cgi/man.cgi?query=pw&sektion=8)
* Manual de FreeBSD `login.conf`: [https://man.freebsd.org/cgi/man.cgi?query=login.conf&sektion=5](https://man.freebsd.org/cgi/man.cgi?query=login.conf&sektion=5)
* Manual de OpenBSD `useradd`: [https://man.openbsd.org/useradd.8](https://man.openbsd.org/useradd.8)
* Manual de NetBSD `usermod`: [https://man.netbsd.org/usermod.8](https://man.netbsd.org/usermod.8)

---

## Ejercicio 1: Arquitectura de la base de datos de usuarios de bajo nivel e ingesta con `pwd_mkdb`

### Objetivo
Inspeccionar, modificar y reconstruir manualmente el stack de bases de datos de autenticación de usuarios de BSD (`/etc/master.passwd`, `/etc/passwd`, `/etc/pwd.db`, `/etc/spwd.db`) manteniendo los bloqueos de archivos y la validez de la sintaxis.

### Pasos guiados

1. Inspeccionar los permisos y tipos de archivo de los archivos del sistema de base de datos de contraseñas:
   ```bash
   ls -lo /etc/master.passwd /etc/passwd /etc/pwd.db /etc/spwd.db
   ```
   **Salida esperada:**
   ```text
   -rw-------  1 root  wheel  - 1482 Aug  6 18:22 /etc/master.passwd
   -rw-r--r--  1 root  wheel  - 1204 Aug  6 18:22 /etc/passwd
   -rw-r--r--  1 root  wheel  - 40960 Aug 6 18:22 /etc/pwd.db
   -rw-------  1 root  wheel  - 40960 Aug 6 18:22 /etc/spwd.db
   ```

2. Invocar `vipw` para bloquear `/etc/ptmp` y abrir `/etc/master.passwd` en una sesión de editor segura:
   ```bash
   sudo vipw
   ```

3. Agregar una nueva entrada de cuenta de servicio directamente en el búfer del editor de 10 campos al final del archivo:
   ```text
   sre_monitor:*LOCKED*:1500:1500:staff:0:0:SRE Monitoring Agent:/nonexistent:/usr/sbin/nologin
   ```
   Guardar y salir del editor. Observar la regeneración automática de las bases de datos binarias indexadas.

4. Verificar que `/etc/master.passwd` contiene el campo de contraseña mientras que `/etc/passwd` elimina el campo de contraseña para lectura no privilegiada:
   ```bash
   sudo grep '^sre_monitor' /etc/master.passwd
   grep '^sre_monitor' /etc/passwd
   ```
   **Salida esperada:**
   ```text
   sre_monitor:*LOCKED*:1500:1500:staff:0:0:SRE Monitoring Agent:/nonexistent:/usr/sbin/nologin
   sre_monitor:*:1500:1500:staff:0:0:SRE Monitoring Agent:/nonexistent:/usr/sbin/nologin
   ```

5. Forzar manualmente la reconstrucción de las bases de datos con hash a partir de `/etc/master.passwd` utilizando `pwd_mkdb`:
   ```bash
   sudo pwd_mkdb -p /etc/master.passwd
   ```

6. Inspeccionar la actualización de la marca de tiempo de la base de datos para verificar la sincronización:
   ```bash
   ls -lu /etc/pwd.db /etc/spwd.db
   ```
   **Salida esperada:**
   ```text
   -rw-r--r--  1 root  wheel  - 40960 Aug  6 20:41 /etc/pwd.db
   -rw-------  1 root  wheel  - 40960 Aug  6 20:41 /etc/spwd.db
   ```

---

### Preguntas de verificación — Ejercicio 1

**Pregunta 1.1:** ¿Por qué la modificación directa de `/etc/master.passwd` usando editores de texto estándar (como `vi` o `nano` directamente) se considera un riesgo operativo crítico en sistemas BSD?
* A) Los editores estándar modifican la propiedad del archivo a `nobody:nogroup`.
* B) La edición directa omite el bloqueo de `/etc/ptmp`, causando condiciones de carrera y fallando en la reconstrucción de `/etc/pwd.db` y `/etc/spwd.db`.
* C) `/etc/master.passwd` es un punto de montaje de sistema de archivos de solo lectura en sistemas BSD.
* D) Los editores estándar descifran automáticamente los campos de hash al guardar.

**Pregunta 1.2:** Un auditor de sistemas pregunta por qué existe `/etc/passwd` si la autenticación del sistema se basa en `/etc/spwd.db`. ¿Cuál es la justificación operativa principal para mantener `/etc/passwd` a través de `pwd_mkdb -p`?
* A) Los demonios NIS (Network Information Service) heredados exigen `/etc/passwd` para la autenticación de root.
* B) Las aplicaciones heredadas y las utilidades del sistema que no son root se basan en `/etc/passwd` para mapear UIDs a nombres de usuario sin requerir privilegios de root para acceder a los hashes.
* C) `/etc/passwd` actúa como una caché de respaldo en memoria cuando `pwd.db` sufre corrupción de bloques de disco.
* D) Almacena las membresías de grupos secundarios que no caben en los registros de Berkeley DB.

---

## Ejercicio 2: Gestión del ciclo de vida de cuentas de usuario multiplataforma (`pw` vs `useradd`/`usermod`)

### Objetivo
Dominar la creación, modificación, bloqueo y eliminación imperativa de usuarios en FreeBSD (usando la utilidad unificada `pw`) y OpenBSD/NetBSD (usando los comandos estándar `useradd`/`usermod`/`userdel`).

### Pasos guiados

1. Crear un grupo primario de ingeniería dedicado y una cuenta de usuario en FreeBSD utilizando `pw`:
   ```bash
   sudo pw groupadd devops -g 2000
   sudo pw useradd sre_lead -u 2001 -g devops -G wheel -c "Lead SRE Engineer" -m -s /usr/local/bin/zsh
   ```

2. Confirmar los parámetros de la cuenta en `/etc/master.passwd` y verificar la estructura del home directory:
   ```bash
   pw user show sre_lead
   ls -ld /home/sre_lead
   ```
   **Salida esperada:**
   ```text
   sre_lead:*:2001:2000::0:0:Lead SRE Engineer:/home/sre_lead:/usr/local/bin/zsh
   drwxr-xr-x  2 sre_lead  devops  512 Aug  6 20:45 /home/sre_lead
   ```

3. Modificar la cuenta de usuario para establecer una fecha de expiración de la cuenta y asignar una login class personalizada (`staff`):
   ```bash
   sudo pw usermod sre_lead -L staff -e 31-Dec-2026
   ```

4. Bloquear la cuenta de usuario inmediatamente para simular una política de respuesta a incidentes:
   ```bash
   sudo pw lock sre_lead
   ```

5. Inspeccionar el campo de contraseña en `/etc/master.passwd` para analizar la sintaxis exacta de bloqueo implementada por BSD:
   ```bash
   sudo grep '^sre_lead' /etc/master.passwd
   ```
   **Salida esperada:**
   ```text
   sre_lead:*LOCKED*1798761600:2001:2000:staff:0:1798761600:Lead SRE Engineer:/home/sre_lead:/usr/local/bin/zsh
   ```

6. Desbloquear la cuenta de usuario y restaurar el estado operativo:
   ```bash
   sudo pw unlock sre_lead
   ```

7. Ejecutar la creación equivalente de cuentas en OpenBSD/NetBSD usando `useradd`:
   ```bash
   sudo groupadd -g 3000 secops
   sudo useradd -u 3001 -g secops -G wheel -c "Security Analyst" -m -s /bin/ksh sec_analyst
   ```

8. Modificar la login shell en OpenBSD/NetBSD usando `usermod`:
   ```bash
   sudo usermod -s /usr/local/bin/bash sec_analyst
   ```

---

### Preguntas de verificación — Ejercicio 2

**Pregunta 2.1:** ¿Cuál es la diferencia estructural en `/etc/master.passwd` entre bloquear una cuenta de usuario con `pw lock <usuario>` en comparación con cambiar su login shell a `/usr/sbin/nologin`?
* A) `pw lock` antepone `*LOCKED*` al hash de contraseña, evitando por completo la autenticación, mientras que configurar la shell en `/usr/sbin/nologin` permite la autenticación pero deniega el acceso interactivo a la shell.
* B) `pw lock` elimina la entrada de `/etc/spwd.db`, mientras que `/usr/sbin/nologin` elimina el home directory.
* C) `pw lock` cambia el UID a `65534`, mientras que `/usr/sbin/nologin` deshabilita las marcas de tiempo de expiración de contraseña.
* D) Ambas acciones realizan modificaciones idénticas internamente al cambiar el campo de login class a `disabled`.

**Pregunta 2.2:** Al usar `pw useradd` en FreeBSD sin especificar el flag `-g`, ¿cuál es el comportamiento por defecto en la asignación del grupo primario?
* A) El usuario se asigna automáticamente al GID primario `0` (`wheel`).
* B) El usuario se asigna al grupo `nobody` (GID `65534`).
* C) `pw` crea un nuevo grupo con el mismo nombre que el usuario y asigna un par entero GID/UID idéntico.
* D) El comando falla con un error de sintaxis exigiendo un GID explícito.

---

## Ejercicio 3: Arquitectura de grupos, aislamiento de membresía y `vigr`

### Objetivo
Gestionar asignaciones de grupos secundarios, preservar la integridad de `/etc/group` utilizando `vigr` e implementar controles de acceso a directorios compartidos con semántica del bit SGID.

### Pasos guiados

1. Abrir de forma segura `/etc/group` para edición utilizando `vigr`:
   ```bash
   sudo vigr
   ```

2. Agregar un nuevo grupo secundario de ingeniería `platform` y añadir usuarios directamente en el archivo:
   ```text
   platform:*:2500:sre_lead,sec_analyst
   ```
   Guardar y cerrar el editor.

3. Verificar la membresía del grupo utilizando `id` y `pw`:
   ```bash
   id sre_lead
   ```
   **Salida esperada:**
   ```text
   uid=2001(sre_lead) gid=2000(devops) groups=2000(devops),0(wheel),2500(platform)
   ```

4. Crear un directorio de equipo compartido y asignar la propiedad del grupo a `platform`:
   ```bash
   sudo mkdir -p /var/data/platform_shared
   sudo chown root:platform /var/data/platform_shared
   ```

5. Aplicar el bit set-group-ID (SGID) y los permisos de directorio para que todos los archivos recién creados hereden automáticamente la propiedad del grupo:
   ```bash
   sudo chmod 2770 /var/data/platform_shared
   ls -ld /var/data/platform_shared
   ```
   **Salida esperada:**
   ```text
   drwxr-sr-x  2 root  platform  512 Aug  6 20:50 /var/data/platform_shared
   ```

6. Añadir un usuario a un grupo de forma imperativa en FreeBSD usando `pw groupmod`:
   ```bash
   sudo pw groupmod platform -m sre_monitor
   groups sre_monitor
   ```
   **Salida esperada:**
   ```text
   devops platform
   ```

---

### Preguntas de verificación — Ejercicio 3

**Pregunta 3.1:** ¿Qué mecanismo de bloqueo utiliza `vigr` para evitar condiciones de carrera administrativas concurrentes al modificar `/etc/group`?
* A) Adquiere un bloqueo flock POSIX en `/etc/master.passwd`.
* B) Crea un archivo de bloqueo llamado `/etc/gtmp` durante la sesión de edición.
* C) Modifica temporalmente los atributos del sistema de archivos de `/etc/group` a inmutable (`chflags uchg`).
* D) Detiene los demonios del sistema `cron` y `sshd` hasta que finalice la edición.

**Pregunta 3.2:** Si el usuario `sec_analyst` crea un archivo dentro de `/var/data/platform_shared` (que tiene permisos `2770` y propiedad `root:platform`), ¿cuál será la propiedad de grupo del archivo creado?
* A) `secops` (El grupo primario del usuario).
* B) `wheel` (El grupo root administrativo por defecto).
* C) `platform` (Heredado del directorio padre debido al bit SGID).
* D) `nobody` (Eliminado debido a ejecución no root).

---

## Ejercicio 4: Aprovisionamiento declarativo del entorno mediante plantillas Skeleton y Login Classes

### Objetivo
Personalizar los archivos skeleton de usuario por defecto en `/usr/share/skel`, configurar límites de recursos del sistema detallados en `/etc/login.conf` y compilar la base de datos binaria de capacidades usando `cap_mkdb`.

### Pasos guiados

1. Inspeccionar la estructura de directorios de plantillas skeleton por defecto en BSD:
   ```bash
   ls -la /usr/share/skel/
   ```
   **Salida esperada:**
   ```text
   drwxr-xr-x   2 root  wheel   512 Aug  6 18:00 .
   drwxr-xr-x  30 root  wheel  1024 Aug  6 18:00 ..
   -rw-r--r--   1 root  wheel   942 Aug  6 18:00 dot.cshrc
   -rw-r--r--   1 root  wheel   481 Aug  6 18:00 dot.login
   -rw-r--r--   1 root  wheel   243 Aug  6 18:00 dot.profile
   -rw-r--r--   1 root  wheel   352 Aug  6 18:00 dot.shrc
   ```

2. Crear una plantilla global personalizada de inicialización de shell para todas las cuentas recién creadas:
   ```bash
   sudo sh -c 'cat << "EOF" >> /usr/share/skel/dot.profile
   # Enterprise SRE Environment Defaults
   export HISTSIZE=10000
   export BLOCKSIZE=K
   alias ll="ls -laFo"
   EOF'
   ```

3. Abrir `/etc/login.conf` y definir una login class personalizada completa y sintácticamente válida llamada `sre_tier` con límites de recursos de producción:

```text
sre_tier:\
	:lang=en_US.UTF-8:\
	:setenv=MAIL=/var/mail/$USER,BLOCKSIZE=K:\
	:path=/sbin /bin /usr/sbin /usr/bin /usr/local/sbin /usr/local/bin:\
	:cputime=unlimited:\
	:datasize=4G:\
	:stacksize=128M:\
	:memorymax=8G:\
	:openfiles=2048:\
	:maxproc=512:\
	:coredumpsize=0:\
	:priority=0:\
	:tc=default:
```

4. Agregar el stanza de la clase `sre_tier` a `/etc/login.conf` y compilar la base de datos de capacidades de archivos usando `cap_mkdb`:
   ```bash
   sudo cap_mkdb /etc/login.conf
   ls -l /etc/login.conf.db
   ```
   **Salida esperada:**
   ```text
   -rw-r--r--  1 root  wheel  8192 Aug  6 20:55 /etc/login.conf.db
   ```

5. Asignar la nueva login class `sre_tier` al usuario `sre_lead` y verificar usando `limits`:
   ```bash
   sudo pw usermod sre_lead -L sre_tier
   sudo limits -U sre_lead
   ```
   **Salida esperada:**
   ```text
   Resource limits for user sre_lead (class sre_tier):
     cputime          infinity secs
     datasize          4194304 kB
     stacksize          131072 kB
     coredumpsize            0 kB
     memoryuse        8388608 kB
     maxproc               512
     openfiles            2048
   ```

---

### Preguntas de verificación — Ejercicio 4

**Pregunta 4.1:** ¿Por qué debe ejecutarse `cap_mkdb` inmediatamente después de hacer cambios en `/etc/login.conf`?
* A) `cap_mkdb` verifica la sintaxis de autenticación PAM y recarga el demonio del servicio `sshd`.
* B) El kernel y las API del sistema (como `getcap(3)`) leen la base de datos Hashed DB binaria compilada `/etc/login.conf.db` para mayor rendimiento en lugar de analizar texto plano.
* C) `cap_mkdb` cifra los dotfiles de skeleton copiados a los home directories de los usuarios.
* D) Convierte la sintaxis de capacidades de login de BSD al formato `/etc/security/limits.conf` de Linux.

**Pregunta 4.2:** ¿Qué parámetro en una entrada de capacidad de `/etc/login.conf` permite que una clase personalizada herede todas las configuraciones por defecto de una clase base existente mientras aplica anulaciones específicas?
* A) `:inherit=default:`
* B) `:parent=default:`
* C) `:tc=default:`
* D) `:include=/etc/login.conf.default:`

---

## Ejercicio 5: Respuesta a incidentes y reparación de base de datos de emergencia

### Objetivo
Diagnosticar y reparar un estado corrupto de la base de datos de contraseñas de BSD, recuperarse de bloqueos mutuos de archivos de bloqueo (lock files) y ejecutar una restauración de emergencia en modo monousuario (single-user).

### Pasos guiados

1. Simular un escenario donde ocurre un corte de energía repentino mientras un administrador estaba ejecutando `vipw`, dejando un archivo de bloqueo abandonado:
   ```bash
   sudo touch /etc/ptmp
   ```

2. Intentar ejecutar `vipw` o `pw` y observar el error de colisión de bloqueo:
   ```bash
   sudo vipw
   ```
   **Salida esperada:**
   ```text
   vipw: /etc/ptmp: File exists
   vipw: /etc/master.passwd: resource temporarily unavailable
   ```

3. Identificar archivos de bloqueo obsoletos y limpiar el archivo de bloqueo de forma segura:
   ```bash
   ls -l /etc/ptmp /etc/gtmp
   sudo rm -f /etc/ptmp /etc/gtmp
   ```

4. Simular la desincronización del índice de la base de datos corrompiendo `/etc/spwd.db` y verificar la salida de diagnóstico:
   ```bash
   sudo truncate -s 0 /etc/spwd.db
   id sre_lead
   ```
   *Nota: En condiciones desincronizadas, la resolución de usuario puede fallar o reportar detalles faltantes porque `getpwnam(3)` consulta el archivo DB corrupto.*

5. Ejecutar la recuperación de emergencia de la base de datos desde `/etc/master.passwd` usando `pwd_mkdb`:
   ```bash
   sudo pwd_mkdb -C /etc/master.passwd
   ```
   **Salida esperada:**
   ```text
   pwd_mkdb: /etc/master.passwd: integrity check passed
   ```

6. Reconstruir limpiamente tanto `pwd.db` como `spwd.db`:
   ```bash
   sudo pwd_mkdb -p /etc/master.passwd
   ```

---

### Preguntas de verificación — Ejercicio 5

**Pregunta 5.1:** ¿Cuál es el propósito principal del flag `pwd_mkdb -C` durante los procedimientos de diagnóstico de emergencia?
* A) Convierte hashes de contraseña MD5 en hashes SHA-512.
* B) Comprueba la sintaxis y la integridad estructural de `/etc/master.passwd` sin alterar las bases de datos `.db` existentes.
* C) Borra todas las sesiones de usuario activas y termina los demonios en segundo plano.
* D) Crea una copia de seguridad cifrada de `/etc/passwd` en `/var/backups`.

**Pregunta 5.2:** Durante una recuperación de emergencia en modo monousuario (single-user), `/etc/master.passwd` se edita manualmente usando `vi` porque `vipw` falla debido a un montaje del sistema de archivos root en modo solo lectura. ¿Qué secuencia de comandos se debe ejecutar para restaurar correctamente el acceso al sistema?
* A) `mount -uw /` seguido de `pwd_mkdb -p /etc/master.passwd`
* B) `reboot --force`
* C) `cap_mkdb /etc/passwd` seguido de `touch /etc/ptmp`
* D) `chmod 777 /etc/spwd.db`

---

<details>
<summary><strong>Haga clic para expandir las respuestas y explicaciones técnicas</strong></summary>

### Respuestas del Ejercicio 1

* **Solución a la Pregunta 1.1: B**
  * **Explicación:** La edición directa de `/etc/master.passwd` omite el bloqueo atómico de archivo (`/etc/ptmp`). Además, los editores de texto estándar no invocan automáticamente `pwd_mkdb`. Como resultado, las bases de datos indexadas (`/etc/pwd.db` y `/etc/spwd.db`) se desincronizan del archivo de texto, dejando la autenticación del sistema desactualizada o rota.
* **Solución a la Pregunta 1.2: B**
  * **Explicación:** `/etc/passwd` es un archivo heredado legible por todos (0644) generado por `pwd_mkdb -p` donde todos los campos de hash de contraseña se reemplazan con `*`. Los comandos no privilegiados (como `ls -l`, `ps` o `finger`) leen `/etc/passwd` o `/etc/pwd.db` para resolver UIDs numéricos a nombres legibles por humanos sin necesitar permisos elevados para leer los hashes de contraseñas sensibles almacenados en `/etc/spwd.db` (0600).

---

### Respuestas del Ejercicio 2

* **Solución a la Pregunta 2.1: A**
  * **Explicación:** `pw lock` altera el campo de contraseña en `/etc/master.passwd` anteponiendo la cadena `*LOCKED*`. Esto invalida la verificación del hash en la capa de PAM/autenticación, evitando todos los mecanismos de autenticación (autenticación por clave SSH, autenticación por contraseña, etc.). Cambiar la shell a `/usr/sbin/nologin` permite que la autenticación PAM sea exitosa, pero termina inmediatamente la sesión tras la ejecución de la shell.
* **Solución a la Pregunta 2.2: C**
  * **Explicación:** Por defecto, los sistemas BSD siguen el esquema User Private Group (UPG). Al crear un usuario sin especificar `-g`, `pw` crea un nuevo grupo primario que coincide con el nombre de usuario y asigna números de UID y GID idénticos.

---

### Respuestas del Ejercicio 3

* **Solución a la Pregunta 3.1: B**
  * **Explicación:** `vigr` crea un archivo de bloqueo atómico llamado `/etc/gtmp`. Si otro administrador intenta ejecutar `vigr` o `pw groupmod` simultáneamente, el proceso detecta `/etc/gtmp` y se anula para evitar la corrupción del archivo.
* **Solución a la Pregunta 3.2: C**
  * **Explicación:** Configurar el bit Set-Group-ID (SGID) (`chmod 2770` o `chmod g+s`) en un directorio fuerza a que todos los archivos y subdirectorios recién creados dentro de él hereden la propiedad de grupo del directorio padre (`platform`), en lugar del grupo primario del usuario creador (`secops`).

---

### Respuestas del Ejercicio 4

* **Solución a la Pregunta 4.1: B**
  * **Explicación:** Las funciones de la librería C de BSD (tales como `getcap(3)` y `getpwuid(3)`) utilizan archivos rápidos Berkeley DB (`.db`) para búsquedas de clave-valor. Las modificaciones a `/etc/login.conf` permanecen inactivas hasta que `cap_mkdb` compila la configuración de texto en `/etc/login.conf.db`.
* **Solución a la Pregunta 4.2: C**
  * **Explicación:** La entrada `:tc=` (template capability) permite que una login class incluya otra entrada de capacidad como plantilla base. Por ejemplo, `:tc=default:` hereda todos los límites de recursos del sistema por defecto y aplica las anulaciones especificadas para la clase.

---

### Respuestas del Ejercicio 5

* **Solución a la Pregunta 5.1: B**
  * **Explicación:** El flag `-C` le indica a `pwd_mkdb` que se ejecute en modo solo verificación (check-only). Realiza un análisis de sintaxis y validación de campos en `/etc/master.passwd` sin generar archivos de base de datos de salida ni modificar el estado del sistema.
* **Solución a la Pregunta 5.2: A**
  * **Explicación:** El modo monousuario (single-user) monta inicialmente el sistema de archivos root como solo lectura (`ro`). El administrador debe primero volver a montar root en modo lectura-escritura (`mount -uw /`). Después de editar `/etc/master.passwd`, se debe ejecutar `pwd_mkdb -p /etc/master.passwd` para generar `/etc/passwd`, `/etc/pwd.db` y `/etc/spwd.db`.

</details>