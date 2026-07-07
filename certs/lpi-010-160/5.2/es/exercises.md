# Ejercicios guiados — Tema 5.2: Creating Users and Groups
**Certificación:** LPI Linux Essentials (010-160, versión 1.6) · **Peso:** 2

> **Requisitos:** una máquina Linux (ideal: una VM descartable) con acceso a `root` mediante `sudo`. Los comandos que modifican el sistema están marcados con ⚠️.

---

## Ejercicio 1 — ¿Quién soy? Identidad del usuario actual

Antes de crear usuarios, hay que entender cómo el sistema identifica al usuario que ya está conectado.

1. Abrí una terminal y ejecutá:
   ```bash
   whoami
   ```
2. Ahora pedí la información completa de identidad:
   ```bash
   id
   ```
   Observá los tres bloques de la salida: `uid=...`, `gid=...` y `groups=...`.
3. Consultá la identidad de otro usuario sin ser ese usuario:
   ```bash
   id root
   ```
4. Verificá quién está conectado al sistema en este momento:
   ```bash
   who
   ```
5. Ampliá esa información con:
   ```bash
   w
   ```
6. Consultá el historial de logins recientes:
   ```bash
   last
   ```

**Preguntas de verificación:**

- **1.1** En la salida de `id`, ¿qué diferencia hay entre `gid=` y `groups=`?
- **1.2** ¿Qué UID tiene siempre el usuario `root`, y por qué es importante ese número más que el nombre?
- **1.3** ¿Qué muestra `w` que no muestra `who`?
- **1.4** ¿De qué archivo saca `last` su información?

---

## Ejercicio 2 — Los archivos de la base de datos de usuarios

Linux guarda las cuentas en archivos de texto plano. Vamos a leerlos.

1. Mostrá el archivo de cuentas de usuario:
   ```bash
   cat /etc/passwd
   ```
2. Filtrá la línea de tu propio usuario (reemplazá `TU_USUARIO`):
   ```bash
   grep TU_USUARIO /etc/passwd
   ```
   Identificá los **7 campos** separados por `:` — nombre, contraseña (`x`), UID, GID, comentario/GECOS, directorio home, shell.
3. Mostrá el archivo de grupos:
   ```bash
   cat /etc/group
   ```
   Identificá los **4 campos**: nombre del grupo, contraseña (`x`), GID, lista de miembros.
4. Intentá leer el archivo de contraseñas cifradas **sin** privilegios:
   ```bash
   cat /etc/shadow
   ```
   Anotá el error que recibís.
5. ⚠️ Ahora leelo con privilegios:
   ```bash
   sudo cat /etc/shadow
   ```
6. Compará los permisos de ambos archivos:
   ```bash
   ls -l /etc/passwd /etc/shadow
   ```
7. Buscá en `/etc/passwd` algún usuario de sistema, por ejemplo:
   ```bash
   grep -E '^(daemon|nobody|www-data|sshd)' /etc/passwd
   ```
   Fijate en sus UID y en su shell.

**Preguntas de verificación:**

- **2.1** ¿Por qué el segundo campo de `/etc/passwd` contiene una `x` en vez de la contraseña?
- **2.2** ¿Por qué `/etc/passwd` es legible por todos los usuarios pero `/etc/shadow` no?
- **2.3** Un usuario de sistema como `daemon` suele tener como shell `/usr/sbin/nologin` o `/bin/false`. ¿Qué efecto tiene eso y para qué sirve?
- **2.4** En una instalación típica, ¿en qué rango arrancan los UID de los usuarios regulares (los que crean los administradores), a diferencia de los usuarios de sistema?

---

## Ejercicio 3 — Convertirse en root: `su` y `sudo`

1. Ejecutá un comando puntual con privilegios elevados:
   ```bash
   sudo ls /root
   ```
2. Verificá qué usuario "sos" cuando corrés algo con `sudo`:
   ```bash
   sudo whoami
   ```
3. ⚠️ Abrí una shell de root completa (si tu distro lo permite):
   ```bash
   sudo -i
   ```
   Observá cómo cambia el prompt (de `$` a `#`). Ejecutá `id` y después salí con `exit`.
4. Probá la alternativa clásica (funciona solo si la cuenta root tiene contraseña propia, cosa que Ubuntu por defecto no configura):
   ```bash
   su -
   ```
   Salí con `exit` si entraste.

**Preguntas de verificación:**

- **3.1** ¿Qué contraseña pide `su -` y qué contraseña pide `sudo`? Esa diferencia es clave en el examen.
- **3.2** ¿Por qué se considera mejor práctica trabajar como usuario regular y usar `sudo` solo cuando hace falta, en vez de estar logueado como root todo el tiempo?
- **3.3** ¿Qué archivo define qué usuarios pueden usar `sudo` y qué comando se usa para editarlo de forma segura?

---

## Ejercicio 4 — Crear un grupo y un usuario nuevo ⚠️

Vamos a crear un grupo `alumnos` y un usuario `ana` que pertenezca a él.

1. Creá el grupo:
   ```bash
   sudo groupadd alumnos
   ```
2. Verificá que el grupo existe y anotá su GID:
   ```bash
   grep alumnos /etc/group
   ```
3. Creá el usuario `ana`, con directorio home, shell Bash, y `alumnos` como grupo secundario:
   ```bash
   sudo useradd -m -s /bin/bash -G alumnos -c "Ana Perez" ana
   ```
4. Verificá el resultado en la base de datos de usuarios:
   ```bash
   grep ana /etc/passwd
   id ana
   ```
5. Confirmá que se creó el directorio home:
   ```bash
   ls -ld /home/ana
   ls -la /home/ana
   ```
   Los archivos ocultos que ves (`.bashrc`, `.profile`, etc.) fueron copiados desde una plantilla.
6. Asignale una contraseña para que pueda iniciar sesión:
   ```bash
   sudo passwd ana
   ```
7. Comprobá que la cuenta funciona cambiando a ella:
   ```bash
   su - ana
   whoami
   id
   exit
   ```

**Preguntas de verificación:**

- **4.1** ¿Qué hace la opción `-m` de `useradd` y qué pasa si la omitís en muchas distribuciones?
- **4.2** ¿Cuál es la diferencia entre el grupo primario de `ana` y sus grupos secundarios (o suplementarios)? ¿Con qué opción de `useradd` se indica cada uno?
- **4.3** ¿De qué directorio se copian los archivos como `.bashrc` al crear el home de un usuario nuevo?
- **4.4** Recién creado el usuario con `useradd` y **antes** de ejecutar `passwd`, ¿puede `ana` iniciar sesión con contraseña? ¿Por qué?
- **4.5** ¿En qué archivo quedó guardado el hash de la contraseña de `ana`?

---

## Ejercicio 5 — Modificar membresías de grupos ⚠️

1. Creá un segundo grupo:
   ```bash
   sudo groupadd proyecto
   ```
2. Agregá a `ana` al grupo `proyecto` **sin perder** sus grupos actuales:
   ```bash
   sudo usermod -aG proyecto ana
   ```
3. Verificá el cambio:
   ```bash
   id ana
   grep proyecto /etc/group
   ```
4. Observá también el efecto en la sesión: abrí una shell como `ana` y comprobá sus grupos activos:
   ```bash
   su - ana
   groups
   exit
   ```

**Preguntas de verificación:**

- **5.1** En `usermod -aG`, ¿qué pasaría si usaras `-G proyecto` sin la `-a`? Este es un error clásico.
- **5.2** Si `ana` ya tuviera una sesión abierta al momento de agregarla al grupo, ¿vería el grupo nuevo de inmediato en esa sesión? ¿Qué tendría que hacer?

---

## Ejercicio 6 — Limpieza: eliminar usuario y grupos ⚠️

1. Eliminá al usuario `ana` junto con su directorio home:
   ```bash
   sudo userdel -r ana
   ```
2. Verificá que ya no existe:
   ```bash
   id ana
   grep ana /etc/passwd
   ls -ld /home/ana
   ```
3. Eliminá los grupos creados:
   ```bash
   sudo groupdel alumnos
   sudo groupdel proyecto
   ```
4. Confirmá la limpieza:
   ```bash
   grep -E 'alumnos|proyecto' /etc/group
   ```

**Preguntas de verificación:**

- **6.1** ¿Qué hace la opción `-r` de `userdel` y qué quedaría en el sistema si no la usás?
- **6.2** ¿Por qué no fue necesario eliminar a `ana` de los grupos antes de borrar la cuenta?

---

## Preguntas integradoras de repaso

- **R.1** Uní cada archivo con su contenido: `/etc/passwd`, `/etc/shadow`, `/etc/group` ↔ (a) hashes de contraseñas y política de expiración, (b) definición de grupos y sus miembros, (c) cuentas de usuario con UID, home y shell.
- **R.2** Un administrador ejecuta `sudo useradd -m carlos` y luego `carlos` no puede loguearse. ¿Cuál es la causa más probable y cómo se resuelve?
- **R.3** ¿Qué tipo de cuenta es `www-data` (o `apache`): root, usuario regular o usuario de sistema? ¿Cómo lo reconocés mirando `/etc/passwd`?

---

<details>
<summary><strong>📖 Respuestas</strong></summary>

### Ejercicio 1

- **1.1** `gid=` es el **grupo primario** del usuario (el que queda como grupo propietario de los archivos que crea por defecto). `groups=` lista **todos** los grupos a los que pertenece: el primario más los secundarios/suplementarios.
- **1.2** `root` siempre tiene **UID 0**. El kernel otorga los privilegios de superusuario según el UID, no según el nombre: cualquier cuenta con UID 0 es, a efectos prácticos, root.
- **1.3** `w` muestra, además de quién está conectado, **qué está haciendo cada uno** (el proceso/comando actual), más datos como tiempo de inactividad y la carga del sistema (load average).
- **1.4** De `/var/log/wtmp`, un archivo binario que registra logins, logouts y reinicios (por eso no se lee con `cat`, sino con el comando `last`).

### Ejercicio 2

- **2.1** Históricamente la contraseña cifrada estaba ahí, pero `/etc/passwd` debe ser legible por todos (muchos programas lo consultan para mapear UID ↔ nombre). Para no exponer los hashes, se movieron a `/etc/shadow` y en `passwd` quedó la `x` como marcador de que la contraseña está en shadow.
- **2.2** `/etc/passwd` no contiene secretos y muchos procesos sin privilegios necesitan leerlo. `/etc/shadow` contiene los hashes de contraseñas: si un atacante los leyera podría intentar romperlos offline (fuerza bruta / diccionario), por eso solo root (y el grupo `shadow` en algunas distros) puede leerlo.
- **2.3** Un shell como `/usr/sbin/nologin` o `/bin/false` **impide el login interactivo**: la cuenta existe para que un servicio corra con sus permisos (privilegios mínimos), pero nadie puede iniciar sesión con ella.
- **2.4** Los usuarios regulares suelen empezar en **UID 1000** (en algunas distros más viejas, 500). Los usuarios de sistema ocupan UIDs bajos (típicamente 1–999), y root es 0.

### Ejercicio 3

- **3.1** `su -` pide la contraseña del usuario **destino** (root). `sudo` pide la contraseña del **propio usuario** que lo ejecuta. Por eso en Ubuntu, donde root no tiene contraseña asignada, `su -` falla pero `sudo` funciona.
- **3.2** Principio de **mínimo privilegio**: como root, cualquier error tipográfico o comando descuidado puede dañar todo el sistema. Con `sudo`, la elevación es puntual, consciente y además queda **registrada en los logs** (auditoría de quién hizo qué).
- **3.3** El archivo `/etc/sudoers`, que se edita con `visudo` — este valida la sintaxis antes de guardar, evitando dejar el archivo roto y quedarse sin acceso a sudo. (En muchas distros alcanza con pertenecer al grupo `sudo` o `wheel`.)

### Ejercicio 4

- **4.1** `-m` crea el **directorio home** del usuario. Sin ella, en muchas distribuciones (Debian/Ubuntu) la cuenta se crea sin home, y el usuario tendrá problemas al iniciar sesión (sin `.bashrc`, sin lugar donde escribir).
- **4.2** El grupo **primario** (opción `-g`) es el que figura en el campo GID de `/etc/passwd` y se asigna a los archivos nuevos del usuario; si no se indica, la mayoría de las distros crea un grupo privado con el mismo nombre del usuario. Los grupos **secundarios** (opción `-G`) son membresías adicionales listadas en `/etc/group`, que otorgan permisos extra.
- **4.3** De `/etc/skel` (skeleton): todo lo que esté ahí se copia al home del usuario nuevo.
- **4.4** No. Hasta que se ejecuta `passwd`, la cuenta queda **bloqueada** (en `/etc/shadow` aparece `!` o `*` en el campo de contraseña), así que el login por contraseña es imposible.
- **4.5** En `/etc/shadow`, en el segundo campo de la línea de `ana` (como hash, nunca en texto plano).

### Ejercicio 5

- **5.1** Sin `-a` (append), `-G` **reemplaza** la lista completa de grupos secundarios: `ana` quedaría solo en `proyecto` y perdería su membresía en `alumnos`. Con `-aG`, el grupo se **agrega** a los existentes.
- **5.2** No: las membresías de grupo se cargan **al iniciar sesión**. Tendría que cerrar sesión y volver a entrar (o iniciar una nueva sesión de login, p. ej. con `su - ana` o `newgrp`) para que el grupo nuevo aparezca en `id`/`groups`.

### Ejercicio 6

- **6.1** `-r` elimina también el **directorio home** y el spool de correo del usuario. Sin `-r`, la cuenta desaparece pero `/home/ana` queda huérfano, ocupando espacio y con archivos cuyo propietario se muestra como un UID numérico sin nombre.
- **6.2** Porque `userdel` quita automáticamente al usuario de todos los grupos en `/etc/group` al borrar la cuenta. Los grupos en sí siguen existiendo (por eso después usamos `groupdel`).

### Preguntas integradoras

- **R.1** `/etc/passwd` → (c) cuentas con UID, home y shell · `/etc/shadow` → (a) hashes y expiración · `/etc/group` → (b) grupos y miembros.
- **R.2** Nunca se le asignó contraseña: `useradd` crea la cuenta **bloqueada**. Solución: `sudo passwd carlos` para establecer una contraseña. (Si tampoco se indicó shell y la distro asigna `/bin/sh` u otro por defecto, puede ajustarse con `usermod -s /bin/bash carlos`, pero la causa del login fallido es la contraseña.)
- **R.3** Es un **usuario de sistema**: se reconoce por su UID bajo (menor a 1000), su shell no interactivo (`/usr/sbin/nologin`) y porque existe para ejecutar un servicio (el servidor web), no para que una persona inicie sesión.

</details>

---

**Fuente de referencia:** LPI Learning Materials, Lesson 5.2 — Creating Users and Groups: https://learning.lpi.org/en/learning-materials/010-160/5/5.2/