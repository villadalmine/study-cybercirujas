# Ejercicios guiados — Tema 5.1: Basic Security and Identifying User Types

**Certificación:** LPI Linux Essentials (010-160, versión 1.6) · **Peso:** 2

Estos ejercicios se realizan en una terminal de cualquier distribución Linux. No necesitás permisos de administrador salvo donde se indique. Anotá tus respuestas antes de mirar la sección de soluciones al final.

---

## Ejercicio 1 — ¿Quién soy? Identificando tu propia cuenta

Todo proceso en Linux corre en nombre de un usuario, y cada usuario se identifica internamente por un número: el **UID (User ID)**. En este ejercicio vas a descubrir tu identidad ante el sistema.

**Pasos:**

1. Abrí una terminal y ejecutá:
   ```bash
   whoami
   ```
2. Ahora obtené la información completa de tu identidad:
   ```bash
   id
   ```
3. Observá la salida. Vas a ver algo similar a:
   ```
   uid=1000(carla) gid=1000(carla) groups=1000(carla),10(wheel),981(docker)
   ```
4. Pedí solo el número de UID:
   ```bash
   id -u
   ```
5. Pedí solo los nombres de tus grupos:
   ```bash
   id -Gn
   ```

**Preguntas:**

- **1.a)** En la salida de `id`, ¿qué diferencia hay entre `gid` y `groups`?
- **1.b)** Si `id -u` devuelve `1000`, ¿tu cuenta es de usuario regular, de sistema o de administrador? ¿Cómo lo sabés?
- **1.c)** ¿Qué UID tiene siempre la cuenta `root`, sin importar la distribución?

---

## Ejercicio 2 — Tipos de usuario en `/etc/passwd`

El archivo `/etc/passwd` es la base de datos local de cuentas. Es legible por todos los usuarios y cada línea tiene 7 campos separados por `:`

```
nombre:contraseña:UID:GID:comentario(GECOS):directorio_home:shell
```

**Pasos:**

1. Mirá la primera línea del archivo, que corresponde al superusuario:
   ```bash
   head -n 1 /etc/passwd
   ```
2. Buscá tu propia cuenta:
   ```bash
   grep "^$(whoami):" /etc/passwd
   ```
3. Listá algunas cuentas de sistema (system accounts / daemon users):
   ```bash
   grep -E "^(daemon|bin|nobody|sshd|systemd)" /etc/passwd
   ```
4. Observá el último campo (el shell) de esas cuentas de sistema. En muchas vas a ver `/usr/sbin/nologin`, `/sbin/nologin` o `/bin/false`.
5. Contá cuántas cuentas existen en total en el sistema:
   ```bash
   wc -l /etc/passwd
   ```

**Preguntas:**

- **2.a)** En la línea de `root`, el segundo campo es una `x`. ¿Significa que root no tiene contraseña? ¿Dónde está guardada realmente?
- **2.b)** ¿Para qué existen las cuentas de sistema como `daemon` o `sshd` si nadie inicia sesión con ellas?
- **2.c)** ¿Qué efecto de seguridad tiene que el shell de una cuenta sea `/usr/sbin/nologin`?
- **2.d)** En muchas distribuciones, los UID de las cuentas de sistema están por debajo de 1000 y los de usuarios regulares empiezan en 1000. ¿Es esto una regla del kernel o una convención de la distribución?

---

## Ejercicio 3 — Contraseñas y el archivo `/etc/shadow`

Las contraseñas cifradas (en realidad, *hashed*) no se guardan en `/etc/passwd` sino en `/etc/shadow`, que tiene permisos mucho más restrictivos.

**Pasos:**

1. Compará los permisos de ambos archivos:
   ```bash
   ls -l /etc/passwd /etc/shadow
   ```
2. Intentá leer `/etc/shadow` como usuario regular:
   ```bash
   cat /etc/shadow
   ```
   Deberías recibir `Permission denied`.
3. Si tenés permisos de administrador, miralo con `sudo` (si no, solo leé el ejemplo):
   ```bash
   sudo head -n 3 /etc/shadow
   ```
4. Observá el segundo campo de cada línea: puede contener un hash largo (empieza con `$`), un `*` o un `!`.

**Preguntas:**

- **3.a)** ¿Por qué las contraseñas se movieron históricamente de `/etc/passwd` a `/etc/shadow`?
- **3.b)** ¿Qué indica un `*` o un `!` en el campo de contraseña de `/etc/shadow`?
- **3.c)** ¿Qué características debería tener una buena contraseña según las prácticas básicas de seguridad?

---

## Ejercicio 4 — Convertirse en otro usuario: `su`

El comando `su` (*switch user*) permite iniciar una sesión como otro usuario, típicamente `root`, pidiendo la contraseña **del usuario destino**.

**Pasos:**

1. Verificá quién sos:
   ```bash
   whoami
   ```
2. Cambiá a root con un *login shell* completo (necesitás conocer la contraseña de root; en distribuciones como Ubuntu la cuenta root viene bloqueada y este paso fallará — es esperado):
   ```bash
   su -
   ```
3. Si el cambio funcionó, verificá tu nueva identidad y tu directorio actual:
   ```bash
   whoami
   pwd
   ```
4. Volvé a tu usuario original:
   ```bash
   exit
   ```
5. Probá la variante sin guion y compará el directorio de trabajo y las variables de entorno:
   ```bash
   su
   pwd
   echo $PATH
   exit
   ```

**Preguntas:**

- **4.a)** ¿Qué contraseña pide `su -`: la tuya o la del usuario al que querés cambiar?
- **4.b)** ¿Qué diferencia práctica hay entre `su` y `su -`?
- **4.c)** ¿Por qué se considera mala práctica trabajar todo el día con una sesión de root abierta?

---

## Ejercicio 5 — Privilegios puntuales: `sudo`

`sudo` ejecuta **un solo comando** con privilegios de otro usuario (por defecto root), pidiendo **tu propia contraseña** y dejando registro de lo que se hizo. Es el mecanismo recomendado para tareas administrativas.

**Pasos:**

1. Ejecutá un comando que como usuario regular falla:
   ```bash
   cat /etc/shadow
   ```
2. Repetilo con `sudo`:
   ```bash
   sudo cat /etc/shadow | head -n 2
   ```
3. Verificá qué identidad ve el sistema cuando usás sudo:
   ```bash
   sudo whoami
   ```
4. Listá qué comandos tenés permitido ejecutar con sudo:
   ```bash
   sudo -l
   ```
5. La configuración de sudo vive en `/etc/sudoers`. Miralo (solo lectura, **nunca lo edites directamente**; para eso existe `visudo`):
   ```bash
   sudo cat /etc/sudoers
   ```
6. Buscá en la salida una línea similar a `%wheel ALL=(ALL) ALL` o `%sudo ALL=(ALL:ALL) ALL`.

**Preguntas:**

- **5.a)** ¿Qué contraseña pide `sudo`: la tuya o la de root? ¿Por qué es una ventaja de seguridad frente a `su`?
- **5.b)** ¿Qué significa el `%` delante de `wheel` o `sudo` en `/etc/sudoers`?
- **5.c)** ¿Qué grupo suele dar acceso a sudo en Debian/Ubuntu, y cuál en Fedora/CentOS?
- **5.d)** Nombrá dos ventajas de `sudo` sobre `su -` para administrar un servidor compartido entre varios administradores.

---

## Ejercicio 6 — Auditando quién está y quién estuvo en el sistema

Parte de la seguridad básica es saber quién está conectado ahora y quién se conectó antes. Para eso existen `who`, `w` y `last`.

**Pasos:**

1. Mirá quién tiene sesiones abiertas ahora:
   ```bash
   who
   ```
2. Obtené la misma información pero con detalle de actividad (carga del sistema, qué está ejecutando cada uno):
   ```bash
   w
   ```
3. Consultá el historial de inicios de sesión:
   ```bash
   last
   ```
4. Mirá específicamente los reinicios del sistema:
   ```bash
   last reboot
   ```
5. Si tu distribución lo incluye, consultá los intentos de login **fallidos** (requiere root):
   ```bash
   sudo lastb
   ```

**Preguntas:**

- **6.a)** ¿Qué información muestra `w` que no muestra `who`?
- **6.b)** ¿De qué archivo binario lee `last` su información? ¿Y `lastb`?
- **6.c)** Si en `sudo lastb` ves cientos de intentos fallidos del usuario `admin` desde una IP desconocida, ¿qué está ocurriendo probablemente?

---

## Ejercicio 7 — Grupos y pertenencia

Los grupos permiten otorgar permisos a conjuntos de usuarios. Cada usuario tiene un **grupo primario** (el GID de `/etc/passwd`) y puede pertenecer a varios **grupos suplementarios**.

**Pasos:**

1. Mirá tus grupos:
   ```bash
   groups
   ```
2. Consultá los grupos de otro usuario (por ejemplo root):
   ```bash
   groups root
   ```
3. Inspeccioná la base de datos de grupos:
   ```bash
   head /etc/group
   ```
   Cada línea tiene el formato `nombre:contraseña:GID:miembros`.
4. Buscá qué usuarios son miembros del grupo de administración de tu distro:
   ```bash
   grep -E "^(sudo|wheel):" /etc/group
   ```

**Preguntas:**

- **7.a)** ¿Dónde se define el grupo **primario** de un usuario y dónde los grupos **suplementarios**?
- **7.b)** ¿Por qué agregar un usuario al grupo `wheel` o `sudo` equivale, en la práctica, a darle poder de administrador?

---

## Ejercicio 8 — Repaso integrador (escenario)

Sin ejecutar comandos, analizá este escenario y respondé:

Un servidor tiene estas líneas en `/etc/passwd`:

```
root:x:0:0:root:/root:/bin/bash
sshd:x:74:74:Privilege-separated SSH:/usr/share/empty.sshd:/sbin/nologin
mariana:x:1001:1001:Mariana Paz:/home/mariana:/bin/bash
backup2:x:0:0:cuenta de respaldo:/home/backup2:/bin/bash
```

**Preguntas:**

- **8.a)** Clasificá cada cuenta como superusuario, cuenta de sistema o usuario regular.
- **8.b)** Hay una señal de alarma de seguridad grave en una de estas líneas. ¿Cuál es y por qué?
- **8.c)** ¿Qué comando usarías para verificar rápidamente si `mariana` puede ejecutar comandos administrativos con sudo?

---

<details>
<summary><strong>✅ Respuestas</strong></summary>

### Ejercicio 1

- **1.a)** `gid` es el **grupo primario** del usuario (el que se asigna por defecto a los archivos que crea), mientras que `groups` lista **todos** los grupos a los que pertenece: el primario más los suplementarios.
- **1.b)** Es un **usuario regular**. Por convención, la mayoría de las distribuciones asignan UID a partir de 1000 (en algunas más viejas, 500) a los usuarios humanos; los UID menores se reservan para root (0) y cuentas de sistema.
- **1.c)** `root` siempre tiene **UID 0**. Lo que otorga los privilegios de superusuario es el UID 0, no el nombre "root".

### Ejercicio 2

- **2.a)** No: la `x` indica que la contraseña está almacenada (en forma de hash) en `/etc/shadow`, un archivo que solo root puede leer.
- **2.b)** Las cuentas de sistema existen para que los servicios (daemons) corran con **privilegios mínimos y aislados**. Si el servicio `sshd` es comprometido, el atacante obtiene los permisos limitados de esa cuenta, no los de root ni los de un usuario humano.
- **2.c)** Impide el inicio de sesión interactivo: aunque alguien conozca o establezca una contraseña para esa cuenta, al autenticarse el "shell" `nologin` termina inmediatamente la sesión. Reduce la superficie de ataque.
- **2.d)** Es una **convención de la distribución** (definida en `/etc/login.defs`, parámetros `UID_MIN`/`SYS_UID_MAX`). Para el kernel, el único UID especial es 0.

### Ejercicio 3

- **3.a)** Porque `/etc/passwd` debe ser legible por todos (muchas herramientas lo consultan para mapear UID ↔ nombre). Tener los hashes de contraseñas en un archivo legible por todos permitía ataques de fuerza bruta offline. Por eso se movieron a `/etc/shadow`, legible solo por root.
- **3.b)** Que la cuenta **no puede autenticarse con contraseña**: `*` suele indicar que nunca se estableció una (típico de cuentas de sistema) y `!` que la contraseña está **bloqueada** (por ejemplo con `passwd -l`). En Ubuntu, la cuenta root viene con `!` — por eso `su -` falla y se usa `sudo`.
- **3.c)** Larga, única (no reutilizada en otros servicios), difícil de adivinar (sin palabras de diccionario ni datos personales), idealmente una *passphrase* o generada por un gestor de contraseñas, y cambiada si se sospecha compromiso.

### Ejercicio 4

- **4.a)** La del **usuario destino**. `su -` (hacia root) pide la contraseña de root.
- **4.b)** `su -` (equivalente a `su -l` o `su --login`) inicia un **login shell**: carga el entorno completo del usuario destino (su `PATH`, sus variables) y te ubica en su directorio home. `su` a secas conserva gran parte del entorno y el directorio actual del usuario original, lo que puede causar comportamientos inesperados en tareas administrativas. Para administrar, se recomienda `su -`.
- **4.c)** Porque root no tiene restricciones: cualquier error de tipeo (un `rm` mal dirigido) o cualquier programa malicioso ejecutado en esa sesión tiene poder total sobre el sistema. El principio de **least privilege** dice que se deben usar privilegios elevados solo el tiempo mínimo necesario.

### Ejercicio 5

- **5.a)** Pide **tu propia contraseña**. Ventajas: no hace falta compartir ni siquiera conocer la contraseña de root (que puede incluso estar bloqueada), y cada acción queda asociada a la identidad real de quien la ejecutó.
- **5.b)** El `%` indica que la entrada se refiere a un **grupo**, no a un usuario individual. `%wheel ALL=(ALL) ALL` autoriza a todos los miembros del grupo `wheel`.
- **5.c)** En Debian/Ubuntu, el grupo `sudo`; en Fedora/CentOS/RHEL (y otras derivadas de Red Hat), el grupo `wheel`.
- **5.d)** Cualquiera dos de: (1) **auditoría** — cada comando queda registrado en el log del sistema con el usuario que lo ejecutó; (2) **no se comparte la contraseña de root** entre administradores; (3) **granularidad** — se puede autorizar solo comandos específicos a cada usuario o grupo; (4) el privilegio dura un solo comando, minimizando el tiempo con permisos elevados.

### Ejercicio 6

- **6.a)** `w` agrega el tiempo de actividad e inactividad (idle) de cada sesión, el comando que cada usuario está ejecutando en ese momento, el uptime y el promedio de carga (load average) del sistema.
- **6.b)** `last` lee de `/var/log/wtmp` (historial de logins, logouts y reinicios). `lastb` lee de `/var/log/btmp` (intentos de login **fallidos**). Ambos son archivos binarios, no se leen con `cat`.
- **6.c)** Muy probablemente un ataque de **fuerza bruta** (brute force) contra el servicio SSH: alguien prueba contraseñas automáticamente contra nombres de cuenta comunes como `admin`. Medidas típicas: deshabilitar el login por contraseña en favor de claves SSH, usar herramientas como fail2ban, o restringir el acceso por firewall.

### Ejercicio 7

- **7.a)** El grupo primario se define en el **cuarto campo de `/etc/passwd`** (el GID). Los grupos suplementarios se definen por la aparición del nombre del usuario en el **último campo de las líneas de `/etc/group`**.
- **7.b)** Porque esos grupos suelen estar autorizados en `/etc/sudoers` a ejecutar cualquier comando como root. Pertenecer al grupo equivale a poder obtener privilegios de superusuario con la propia contraseña.

### Ejercicio 8

- **8.a)**
  - `root` → superusuario (UID 0).
  - `sshd` → cuenta de sistema (UID bajo, shell `nologin`).
  - `mariana` → usuario regular (UID ≥ 1000, shell interactivo, home en `/home`).
  - `backup2` → **aparenta** ser una cuenta de servicio, pero tiene UID 0: técnicamente es otro superusuario.
- **8.b)** La línea de `backup2`: tiene **UID 0 y GID 0**, o sea privilegios totales de root, con un nombre inocente y shell interactivo. Es un patrón clásico de **puerta trasera (backdoor)**: cualquier login con esa cuenta es, para el kernel, un login de root. Debe investigarse y eliminarse de inmediato.
- **8.c)** `sudo -l -U mariana` (ejecutado como root o con sudo) lista qué comandos tiene autorizados; alternativamente, `groups mariana` para ver si pertenece a `sudo` o `wheel`.

</details>

---

**Fuente de referencia:**
- LPI Learning Materials, Lesson 5.1 — Basic Security and Identifying User Types: https://learning.lpi.org/en/learning-materials/010-160/5/5.1/