# Guía de Estudio para la Certificación: LPI BSD Specialist (Examen 702-100, v1.0)
## Tema 711.3: Configuración del Inicio del Sistema BSD
**Peso del Examen:** 5  
**Audiencia Objetivo:** SREs Principales, Arquitectos de Sistemas e Ingenieros de Infraestructura de Producción  
**Documentación de Referencia Oficial:**
- [LPI BSD Specialist Overview & Objectives](https://www.lpi.org/our-certifications/bsd-specialist-overview/)
- [FreeBSD Handbook: Practical rc.d scripting](https://docs.freebsd.org/en/books/handbook/configd-boot/)
- [FreeBSD Manual Pages: rc.subr(8)](https://man.freebsd.org/cgi/man.cgi?query=rc.subr&sektion=8)
- [FreeBSD Manual Pages: rcorder(8)](https://man.freebsd.org/cgi/man.cgi?query=rcorder&sektion=8)
- [OpenBSD Manual Pages: rcctl(8)](https://man.openbsd.org/rcctl.8)
- [OpenBSD Manual Pages: rc.subr(8)](https://man.openbsd.org/rc.subr.8)
- [NetBSD Manual Pages: rc.conf(5)](https://man.netbsd.org/rc.conf.5)

---

## Análisis Arquitectónico Profundo y Mecánica

### 1. Trayectoria de Boot y el Motor de Inicialización `rc`
El proceso de inicialización de BSD está diseñado alrededor de la modularidad, el ordenamiento estricto de dependencias y la gestión del estado declarativo predecible. A diferencia de los sistemas de init monolíticos (como systemd) o los runlevels históricos de SysVinit, los sistemas BSD ejecutan la inicialización en userland a través de scripts de shell gobernados por `/etc/rc` y `rc.subr(8)`.

#### La Trayectoria desde el Kernel hasta los Servicios de Userland:
1. **Bootloader (`loader(8)` / `boot(8)`):** Carga el kernel y los módulos en memoria; pasa flags de boot (`-s` para single-user, `-v` para verbose).
2. **Inicialización del Kernel:** Inicializa los controladores de dispositivos (device drivers), monta el sistema de archivos raíz (`/`) en modo lectura sola, e inicia el ID de proceso 1 (`/sbin/init`).
3. **Ejecución de `init(8)`:**
   - En un boot multi-usuario, `/sbin/init` ejecuta `/etc/rc` a través de `/bin/sh`.
4. **Procesamiento de `/etc/rc`:**
   - Monta los pseudo-sistemas de archivos esenciales (`/proc`, `/dev`, `/tmp`).
   - Analiza (parsea) las plantillas de configuración predeterminadas (`/etc/defaults/rc.conf`) seguidas por las anulaciones (overrides) específicas del sistema (`/etc/rc.conf`, `/etc/rc.conf.local`, `/etc/rc.conf.d/*`).
   - Invoca a `rcorder(8)` para analizar los encabezados de dependencia a través de `/etc/rc.d/` y los directorios de proveedores (`/usr/local/etc/rc.d/` en FreeBSD o `/usr/pkg/etc/rc.d/` en NetBSD).
   - Ejecuta los scripts ordenados con el argumento `faststart` o `start`.

---

### 2. Matriz de Configuración y Precedencia entre Distintos BSD

| Componente del Subsistema | FreeBSD | OpenBSD | NetBSD |
| :--- | :--- | :--- | :--- |
| **Valores Predeterminados del Sistema** | `/etc/defaults/rc.conf` | `/etc/rc.conf` | `/etc/defaults/rc.conf` |
| **Anulaciones de Usuario** | `/etc/rc.conf`, `/etc/rc.conf.d/*` | `/etc/rc.conf.local` | `/etc/rc.conf`, `/etc/rc.conf.d/*` |
| **Scripts de Init del Sistema** | `/etc/rc.d/` | `/etc/rc.d/` | `/etc/rc.d/` |
| **Scripts de Init de Paquetes** | `/usr/local/etc/rc.d/` | `/etc/rc.d/` (Los paquetes usan `/etc/rc.d`) | `/usr/pkg/etc/rc.d/` |
| **Administrador de Estado de CLI** | `sysrc(8)` & `service(8)` | `rcctl(8)` | `service(8)` |
| **Motor de Dependencias** | `rcorder(8)` | Secuencial/Orden de flags de `rcctl` | `rcorder(8)` |

#### Mecánica de Precedencia de Configuración:
- **FreeBSD / NetBSD:** `/etc/defaults/rc.conf` $\rightarrow$ `/etc/rc.conf` $\rightarrow$ `/etc/rc.conf.local` $\rightarrow$ `/etc/rc.conf.d/<service_name>`
- **OpenBSD:** `/etc/rc.conf` (Valores predeterminados del sistema actualizados por las actualizaciones del SO) $\rightarrow$ `/etc/rc.conf.local` (Anulaciones del administrador local).

---

### 3. Algoritmo de Ordenamiento Topológico de `rcorder(8)`
`rcorder(8)` analiza encabezados de comentarios de bloque especiales insertados al inicio de cada script para construir un Grafo Acíclico Dirigido (DAG) para el ordenamiento de la ejecución:
- `# PROVIDE: <name>`: Nombra el subsistema o característica provista por este script.
- `# REQUIRE: <name1> <name2>`: Enumera los prerrequisitos que **deben** ejecutarse antes de este script.
- `# BEFORE: <name1>`: Fuerza a este script a ejecutarse **antes** de los servicios especificados.
- `# KEYWORD: [nostart | shutdown | firstboot | ...]`: Etiquetas especiales utilizadas por las opciones de `rcorder` (por ejemplo, `shutdown` ordena la ejecución inversa durante la detención del sistema a través de `/etc/rc.shutdown`).

---

## Ejercicios Guiados de Producción

### Ejercicio 1: Resolución de Dependencias y Análisis del Orden de Boot con `rcorder(8)`

#### Escenario y Objetivo
Como SRE, debés diagnosticar problemas en la secuencia de inicio de los servicios. Necesitás inspeccionar cómo el motor de boot de BSD calcula el orden de inicio de los daemons y verificar si un daemon de base de datos recién instalado se iniciará después de la inicialización de la red (`NETWORKING`) y los montajes de sistemas de archivos (`mountcritlocal`), pero antes de los daemons de aplicaciones (`LOGIN`).

#### Procedimiento de Ejecución Paso a Paso

1. Consultar el orden de boot de todos los scripts del sistema base y de paquetes en FreeBSD/NetBSD:
   ```bash
   rcorder /etc/rc.d/* /usr/local/etc/rc.d/* 2>/dev/null | head -n 25
   ```
   **Salida Esperada del CLI:**
   ```text
   /etc/rc.d/NETWORKING
   /etc/rc.d/mountcritlocal
   /etc/rc.d/var
   /etc/rc.d/cleanvar
   /etc/rc.d/dmesg
   /etc/rc.d/sysctl
   /etc/rc.d/hostname
   /etc/rc.d/ipfw
   /etc/rc.d/routing
   /etc/rc.d/NETWORKING
   /etc/rc.d/mountcritremote
   /etc/rc.d/syslogd
   /etc/rc.d/SERVERS
   /etc/rc.d/DAEMON
   /etc/rc.d/LOGIN
   ```

2. Inspeccionar el encabezado del bloque de dependencias de `/etc/rc.d/syslogd` para analizar sus parámetros de ejecución:
   ```bash
   head -n 15 /etc/rc.d/syslogd
   ```
   **Salida Esperada del CLI:**
   ```sh
   #!/bin/sh
   #
   # $FreeBSD$
   #

   # PROVIDE: syslogd
   # REQUIRE: mountcritremote cleanvar newsyslog
   # BEFORE:  SERVERS
   # KEYWORD: shutdown
   ```

3. Evaluar el orden de ejecución inverso utilizado durante el apagado del sistema (simulación de ejecución de `rc.shutdown`):
   ```bash
   rcorder -k shutdown /etc/rc.d/* /usr/local/etc/rc.d/* 2>/dev/null | tail -n 15
   ```
   **Salida Esperada del CLI:**
   ```text
   /etc/rc.d/syslogd
   /etc/rc.d/mountcritremote
   /etc/rc.d/NETWORKING
   /etc/rc.d/routing
   /etc/rc.d/mountcritlocal
   /etc/rc.d/var
   ```

---

#### Preguntas de Verificación (Ejercicio 1)

1. **P1.1:** Si un script de servicio personalizado define `# REQUIRE: DAEMON` y `# BEFORE: LOGIN`, ¿en qué parte del ciclo de vida de inicialización ubicará `rcorder` este script en relación con la disponibilidad de la red y los servicios de login de usuario?
2. **P1.2:** ¿Qué ocurre si dos scripts crean un bucle de dependencia circular (por ejemplo, el Script A requiere el Script B y el Script B requiere el Script A)? ¿Cómo maneja `rcorder(8)` este estado?

---

### Ejercicio 2: Creación y Despliegue de un Script Daemon `rc.subr` de Nivel de Producción

#### Escenario y Objetivo
Estás desplegando un daemon de telemetría interno personalizado llamado `node_exporter_custom` en FreeBSD. Debés crear un script wrapper de `/etc/rc.subr` sintácticamente válido, ubicarlo en `/usr/local/etc/rc.d/node_exporter_custom`, garantizar los privilegios de ejecución adecuados, configurar la ejecución sin privilegios (`daemon_user`), el seguimiento de PID y verificar los controles en tiempo de ejecución a través de `service(8)`.

#### Procedimiento de Ejecución Paso a Paso

1. Crear el usuario del daemon dedicado y la estructura de directorios:
   ```bash
   pw useradd -n telemetry -d /nonexistent -s /usr/sbin/nologin -c "Telemetry Daemon User"
   mkdir -p /usr/local/etc/rc.d /var/run/node_exporter_custom
   chown -R telemetry:telemetry /var/run/node_exporter_custom
   ```

2. Crear el script wrapper `rc.subr` completo y sintácticamente válido en `/usr/local/etc/rc.d/node_exporter_custom`:
   ```sh
   cat << 'EOF' > /usr/local/etc/rc.d/node_exporter_custom
   #!/bin/sh
   #
   # PROVIDE: node_exporter_custom
   # REQUIRE: LOGIN
   # KEYWORD: shutdown
   #
   # Add the following lines to /etc/rc.conf to enable node_exporter_custom:
   # node_exporter_custom_enable="YES"
   # node_exporter_custom_flags="--listen-addr=:9100"
   #

   . /etc/rc.subr

   name="node_exporter_custom"
   rcvar="node_exporter_custom_enable"

   load_rc_config $name

   : ${node_exporter_custom_enable:="NO"}
   : ${node_exporter_custom_user:="telemetry"}
   : ${node_exporter_custom_group:="telemetry"}
   : ${node_exporter_custom_flags:="--port=9100"}

   command="/usr/sbin/daemon"
   pidfile="/var/run/${name}/${name}.pid"
   procname="/usr/bin/nc"

   # Use daemon(8) helper to manage background execution and PID creation
   command_args="-f -p ${pidfile} -u ${node_exporter_custom_user} /usr/bin/nc -l 127.0.0.1 9100"

   run_rc_command "$1"
   EOF
   ```

3. Establecer permisos estrictos de producción en el script:
   ```bash
   chmod 0755 /usr/local/etc/rc.d/node_exporter_custom
   chown root:wheel /usr/local/etc/rc.d/node_exporter_custom
   ```

4. Habilitar el servicio de forma no destructiva usando `sysrc(8)`:
   ```bash
   sysrc node_exporter_custom_enable="YES"
   sysrc node_exporter_custom_flags="--port=9100"
   ```
   **Salida Esperada del CLI:**
   ```text
   node_exporter_custom_enable: NO -> YES
   node_exporter_custom_flags:  -> --port=9100
   ```

5. Validar la carga de la configuración e iniciar el servicio a través de `service(8)`:
   ```bash
   service node_exporter_custom status
   service node_exporter_custom start
   service node_exporter_custom status
   ```
   **Salida Esperada del CLI:**
   ```text
   node_exporter_custom is not running.
   Starting node_exporter_custom.
   node_exporter_custom is running as pid 48291.
   ```

6. Inspeccionar los detalles del proceso en ejecución para verificar la revocación de privilegios hacia `telemetry`:
   ```bash
   ps -aux -U telemetry
   ```
   **Salida Esperada del CLI:**
   ```text
   USER       PID %CPU %MEM   VSZ  RSS TT  STAT STARTED      TIME COMMAND
   telemetry 48291  0.0  0.1 12740 2412  -  I    20:15     0:00.01 /usr/bin/nc -l 127.0.0.1 9100
   ```

---

#### Preguntas de Verificación (Ejercicio 2)

1. **P2.1:** ¿Cuál es el propósito específico de la llamada a la función `load_rc_config $name` dentro de un script `rc.subr` y qué ocurre si se omite?
2. **P2.2:** ¿Por qué se utiliza la sintaxis de sustitución de parámetros `: ${node_exporter_custom_enable:="NO"}` en lugar de la asignación directa `node_exporter_custom_enable="NO"` dentro del cuerpo del script?

---

### Ejercicio 3: Gestión del Ciclo de Vida de Servicios entre Distintos BSD (`sysrc` vs `rcctl`)

#### Escenario y Objetivo
En un entorno BSD heterogéneo, un SRE debe administrar los daemons del sistema utilizando herramientas nativas del proveedor. Realizarás la gestión del estado (consulta, habilitación, modificación de flags, verificaciones de estado) en **FreeBSD/NetBSD** usando `sysrc(8)` / `service(8)` y en **OpenBSD** usando `rcctl(8)`.

#### Procedimiento de Ejecución Paso a Paso

##### Parte A: Ejecución en FreeBSD / NetBSD (`sysrc` & `service`)

1. Consultar todos los servicios actualmente habilitados en el sistema:
   ```bash
   service -e
   ```
   **Salida Esperada del CLI:**
   ```text
   /etc/rc.d/hostid
   /etc/rc.d/zfs
   /etc/rc.d/cleanvar
   /etc/rc.d/newsyslog
   /etc/rc.d/syslogd
   /etc/rc.d/sshd
   /etc/rc.d/cron
   ```

2. Inspeccionar las variables de configuración del servicio de forma no destructiva:
   ```bash
   sysrc -a | grep sshd
   ```
   **Salida Esperada del CLI:**
   ```text
   sshd_enable: YES
   sshd_flags: -4
   ```

3. Modificar los flags del servicio en tiempo de ejecución y verificar las actualizaciones atómicas en `/etc/rc.conf`:
   ```bash
   sysrc sshd_flags="-4 -o LogLevel=VERBOSE"
   cat /etc/rc.conf | grep sshd
   ```
   **Salida Esperada del CLI:**
   ```text
   sshd_flags: -4 -> -4 -o LogLevel=VERBOSE
   sshd_enable="YES"
   sshd_flags="-4 -o LogLevel=VERBOSE"
   ```

4. Consultar la ruta completa del script que implementa el servicio `sshd`:
   ```bash
   service -j * sshd rcvar
   ```
   o
   ```bash
   service sshd details
   ```
   **Salida Esperada del CLI:**
   ```text
   # sshd
   #
   sshd_enable="YES"
   # (default: "")
   ```

---

##### Parte B: Ejecución en OpenBSD (`rcctl`)

1. Habilitar el daemon `nginx` y configurar flags locales usando `rcctl(8)`:
   ```bash
   rcctl enable nginx
   rcctl set nginx flags "-T"
   rcctl set nginx status on
   ```

2. Consultar el estado del servicio y las anulaciones de configuración local en `/etc/rc.conf.local`:
   ```bash
   rcctl get nginx
   ```
   **Salida Esperada del CLI:**
   ```text
   nginx_class=daemon
   nginx_flags=-T
   nginx_logger=
   nginx_rtable=0
   nginx_timeout=30
   nginx_user=root
   nginx_status=on
   ```

3. Inspeccionar el estado de verificación de daemons a través de todos los daemons de OpenBSD habilitados:
   ```bash
   rcctl ls check
   ```
   **Salida Esperada del CLI:**
   ```text
   pf(failed)
   sshd(ok)
   ntpd(ok)
   nginx(failed)
   ```

4. Mostrar los servicios deshabilitados en la base pero anulados en `/etc/rc.conf.local`:
   ```bash
   rcctl ls local
   ```
   **Salida Esperada del CLI:**
   ```text
   nginx
   ```

---

#### Preguntas de Verificación (Ejercicio 3)

1. **P3.1:** En OpenBSD, ¿qué archivo se actualiza directamente al ejecutar `rcctl set daemon flags "-v"`, y por qué los administradores nunca deberían editar `/etc/rc.conf` directamente en OpenBSD?
2. **P3.2:** ¿Cuál es la diferencia técnica entre ejecutar `service nginx start` y `service nginx one-start` en FreeBSD?

---

### Ejercicio 4: Diagnóstico Avanzado de Boot y Resolución de Problemas de Inits Detenidos

#### Escenario y Objetivo
Un nodo de FreeBSD de producción falló durante el boot debido a un error de sintaxis en un script `rc.d` personalizado que provocó el fallo de ejecución de `rcorder`, congelando la trayectoria de boot antes de la inicialización de `sshd`. Debés iniciar en Modo Single-User, aislar el fallo utilizando flags de boot y `rc_debug`, corregir el problema y reanudar la ejecución.

#### Procedimiento de Ejecución Paso a Paso

1. **Simular el Ingreso por Fallo de Boot:**
   Iniciar en Modo Single-User en el prompt del loader (prompt `OK`):
   ```text
   OK boot -s
   ```
   *Alternativa:* Seleccionar la opción `2` (Single User Mode) en el menú de boot de FreeBSD.

2. **Montar Sistemas de Archivos en Modo Lectura-Escritura:**
   Cuando se solicite la ruta del shell (`/bin/sh`), presionar Enter. Montar el directorio raíz y `/usr` en modo lectura-escritura:
   ```bash
   mount -u -w /
   mount -a -t ufs,zfs
   ```
   **Salida Esperada del CLI:**
   ```text
   Root filesystem has been re-mounted read-write.
   ```

3. **Rastrear la Ejecución del Script de Inicio con Diagnósticos de Boot Habilitados:**
   Ejecutar `/etc/rc` manualmente con el rastreo de boot del kernel y las anulaciones de `rc_debug` habilitadas:
   ```bash
   export rc_debug="YES"
   export rc_info="YES"
   sh -x /etc/rc 2>&1 | tee /tmp/boot_debug.log | grep -E "WARNING|ERROR|run_rc_command"
   ```
   **Salida Esperada del CLI:**
   ```text
   + run_rc_command start
   /etc/rc: WARNING: /usr/local/etc/rc.d/broken_script has invalid dependency headers.
   rcorder: circular dependency in script /usr/local/etc/rc.d/broken_script.
   ```

4. **Aislar y Poner en Cuarentena el Script Defectuoso:**
   Consultar `rcorder` directamente contra el directorio de paquetes para precisar la sintaxis del archivo ofensivo:
   ```bash
   rcorder /etc/rc.d/* /usr/local/etc/rc.d/* > /dev/null
   ```
   **Salida Esperada del CLI:**
   ```text
   rcorder: circular dependency: /usr/local/etc/rc.d/broken_script
   rcorder: requirement `broken_script' in /usr/local/etc/rc.d/broken_script forms a loop.
   ```

5. **Deshabilitar y Poner en Cuarentena el Script Ofensivo:**
   ```bash
   mv /usr/local/etc/rc.d/broken_script /usr/local/etc/rc.d/broken_script.disabled
   ```

6. **Verificar la Restauración del Orden de Boot y la Transición a Multi-Usuario:**
   ```bash
   rcorder /etc/rc.d/* /usr/local/etc/rc.d/* | grep -E "sshd|LOGIN"
   exit
   ```
   *(Salir del shell de single-user hace que init continúe el proceso de boot hacia el modo multi-usuario).*

---

#### Preguntas de Verificación (Ejercicio 4)

1. **P4.1:** ¿Cómo altera la configuración de `rc_debug="YES"` en `/etc/rc.conf` el comportamiento de la ejecución de comandos de `rc.subr` durante el boot del sistema?
2. **P4.2:** ¿Qué flag de boot del kernel fuerza al kernel de FreeBSD a emitir sondeos detallados de controladores y registros detallados de invocación de `init(8)` durante el inicio temprano?

---

## Soluciones y Clave de Respuestas

<details>
<summary><b>Hacé clic para desplegar Respuestas Detalladas y Explicaciones Técnicas</b></summary>

### Soluciones del Ejercicio 1

- **R1.1:** `rcorder(8)` ubicará el script después de todos los scripts que proporcionan la palabra clave `DAEMON` (que incluye daemons básicos del sistema como syslogd y rpcbind) y estrictamente antes de los scripts que proporcionan la palabra clave `LOGIN` (que controlan el establecimiento de sesiones de usuario y seudoterminales). Por lo tanto, el script se ejecuta durante la fase tardía de servicios del sistema, después de las redes/daemons principales pero antes de los inicios de sesión de los usuarios.
- **R1.2:** `rcorder(8)` detecta ciclos en el grafo dirigido durante su fase de ordenamiento topológico. Emite una advertencia de diagnóstico a stderr (`rcorder: circular dependency in script...`), rompe el ciclo arbitrariamente para evitar un bloqueo por bucle infinito y continúa ordenando los scripts restantes. Esta advertencia puede detener los inicios no interactivos si `rc_fast=NO` o conducir a un orden de ejecución de dependencias impredecible.

---

### Soluciones del Ejercicio 2

- **R2.1:** `load_rc_config $name` lee `/etc/defaults/rc.conf`, `/etc/rc.conf`, `/etc/rc.conf.local` y `/etc/rc.conf.d/$name` para poblar las variables definidas para `$name` (tales como `${name}_enable`, `${name}_flags`, `${name}_user`). Si se omite, el script no logra heredar las anulaciones del sistema configuradas a través de `sysrc` o `/etc/rc.conf`, volviendo estrictamente a los valores predeterminados codificados internamente en el script o fallando en las aserciones de verificación de variables en `run_rc_command`.
- **R2.2:** La construcción `: ${var:="value"}` es la sintaxis estándar de shell POSIX para *asignación de variable predeterminada si no está definida o es nula*. Si `load_rc_config` importó un ajuste desde `/etc/rc.conf` (por ejemplo, `node_exporter_custom_enable="YES"`), la expresión `: ${...}` conserva el ajuste configurado por el usuario. La asignación directa (`node_exporter_custom_enable="NO"`) sobrescribiría incondicionalmente los ajustes del usuario especificados en `/etc/rc.conf`.

---

### Soluciones del Ejercicio 3

- **R3.1:** Ejecutar `rcctl set daemon flags "-v"` actualiza `/etc/rc.conf.local` en OpenBSD. Los administradores nunca deben editar `/etc/rc.conf` directamente en OpenBSD porque `/etc/rc.conf` contiene los valores predeterminados del sistema base que se sobrescriben por completo durante las actualizaciones del sistema (`sysmerge(8)` / `sysupgrade(8)`). Todas las modificaciones del administrador se aislan estrictamente en `/etc/rc.conf.local`.
- **R3.2:** `service nginx start` verifica el valor de `nginx_enable` en `/etc/rc.conf`. Si está configurado en `"NO"`, la ejecución finaliza sin iniciar el daemon. `service nginx one-start` anula la verificación de habilitación de `rcvar`, ejecutando la rutina de inicio una vez sin importar si `nginx_enable` está configurado en `"YES"` o `"NO"`.

---

### Soluciones del Ejercicio 4

- **R4.1:** Configurar `rc_debug="YES"` hace que las rutinas auxiliares de `rc.subr` impriman información detallada de depuración del shell para cada llamada a función. Muestra los valores exactos de las variables (`$command`, `$command_args`, `$pidfile`), imprime las anulaciones ambientales y muestra la cadena de comando final exacta del shell evaluada por `eval` antes de la ejecución del daemon.
- **R4.2:** El flag `-v` (Verbose Boot). Pasar `-v` en el prompt del bootloader (`boot -v` o configurar `boot_verbose="YES"` en `/boot/loader.conf`) hace que el kernel emita mensajes de diagnóstico adicionales con respecto a la enumeración de hardware, la vinculación de controladores de dispositivos y el procesamiento del inicio de `init(8)`.

</details>

---

### Enlaces de Referencia Oficiales y Citas
- [FreeBSD rc.subr Manual Page](https://man.freebsd.org/cgi/man.cgi?query=rc.subr&sektion=8)
- [FreeBSD rcorder Manual Page](https://man.freebsd.org/cgi/man.cgi?query=rcorder&sektion=8)
- [OpenBSD rcctl Manual Page](https://man.openbsd.org/rcctl.8)
- [OpenBSD rc.subr Manual Page](https://man.openbsd.org/rc.subr.8)
- [NetBSD rc.conf Manual Page](https://man.netbsd.org/rc.conf.5)
- [LPI BSD Specialist Certification Page](https://www.lpi.org/our-certifications/bsd-specialist-overview/)