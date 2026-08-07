# CNCF / LPI-702 Study Guide: Arquitectura de System Logging en BSD e Ingeniería SRE

**Examen**: LPI BSD Specialist (Examen 702-100, Versión 1.0)  
**Tema 713.4**: System Logging  
**Peso**: 3.33  
**Referencia Oficial**: [LPI BSD Specialist Overview](https://www.lpi.org/our-certifications/bsd-specialist-overview/)

---

## 1. Análisis Arquitectónico Profundo: Mecánica de System Logging en FreeBSD/BSD

El system logging en los sistemas operativos BSD (FreeBSD, OpenBSD, NetBSD) se centra en dos demonios/utilidades desacoplados:
1. **`syslogd(8)`**: El demonio de enrutamiento de eventos en tiempo real.
2. **`newsyslog(8)`**: La utilidad de mantenimiento y rotación de archivos de log.

```
                          +-------------------------+
                          |   Kernel (/dev/klog)    |
                          +------------+------------+
                                       |
+----------------------+               v               +------------------------+
| Userland Apps / Libs |------>  /dev/log (UNIX)------>|  syslogd(8) Daemon     |
+----------------------+                               +-----------+------------+
                                                                   |
                                          +------------------------+------------------------+
                                          |                        |                        |
                                          v                        v                        v
                                  /var/log/messages        /var/log/auth.log         Remote Syslog Server
                                          |                                           (UDP/TCP 514)
                                          v
                                 +----------------+
                                 |  newsyslog(8)  |
                                 +----------------+
```

### 1.1 Canales de Entrada y Socket Binding de `syslogd(8)`
`syslogd` agrega registros de log de múltiples fuentes a través de mecanismos IPC específicos:
- **`/dev/log`**: Un socket de dominio UNIX de datagramas (`SOCK_DGRAM`) utilizado por aplicaciones estándar de userland que llaman a `syslog(3)`.
- **`/dev/klog`**: Un nodo de dispositivo de caracteres que proporciona mensajes del ring buffer del kernel en bruto (llamadas a `printf(9)` / `log(9)` en el espacio del kernel).
- **Socket UDP/TCP (Puerto 514)**: Escucha mensajes de log remotos a través de redes IP. Controlado mediante flags:
  - `-s` (*Secure Mode*): Deshabilita la escucha en el socket de red (estado por defecto en instalaciones modernas de FreeBSD). Repetir `-s -s` fuerza a `syslogd` a ignorar todos los paquetes de red incluso si está vinculado (bound).
  - `-u` (*Unsecure Mode*): Vuelve a habilitar el procesamiento de logs de red UDP entrantes.
  - `-b bind_address`: Vincula el socket de red a una interfaz IP local específica en lugar de `0.0.0.0`.
  - `-a allowed_peer`: Configura la autorización de pares (peers) de red utilizando notación CIDR o IP/máscara (`-a 192.168.1.0/24:514`).

### 1.2 Mecánica de Selectores y Parsing de Reglas en `syslog.conf(5)`
Las reglas dentro de `/etc/syslog.conf` consisten en un **campo selector** y un **campo de acción**, separados por tabuladores de espacio en blanco:

$$\text{facility.severity} \quad \text{action}$$

#### Matriz de Facilities y Severities
- **Facilities**: `auth`, `authpriv`, `cron`, `daemon`, `ftp`, `kern`, `lpr`, `mail`, `news`, `security`, `syslog`, `user`, `uucp`, `local0` a `local7`.
- **Severities** (en orden ascendente de prioridad):
  `debug` (7) $<$ `info` (6) $<$ `notice` (5) $<$ `warning` (4) $<$ `err` (3) $<$ `crit` (2) $<$ `alert` (1) $<$ `emerg` (0).

#### Operadores de Comparación de Severidad
- **Default (`facility.severity`)**: Coincide con mensajes en la severidad especificada **y superior**.
- **Exact Match (`facility.=severity`)**: Coincide **únicamente** con el nivel de severidad especificado.
- **Negation (`facility.!severity`)**: Coincide con mensajes **inferiores** a la severidad especificada.
- **Wildcard (`*`)**: Coincide con todas las facilities o severities (`*.err`, `auth.*`).
- **Ignore (`none`)**: Excluye la facility (`*.info;mail.none`).

#### Filtros Específicos de Programa y Host en BSD
El `syslog.conf` de FreeBSD soporta bloques de alcance (scoping) no POSIX para programas y hostnames:
- `!program_name`: Aplica las reglas subsiguientes **únicamente** a los mensajes generados por `program_name`.
- `!*`: Restablece el filtro de programa para que coincida con todos los ejecutables.
- `+hostname`: Aplica las reglas a las entradas de log que coincidan con `hostname`.
- `+*`: Restablece el bloque de filtro de hostname.

### 1.3 Mecánica de Mantenimiento y Propagación de Señales de `newsyslog(8)`
Los archivos de log crecen indefinidamente a menos que se gestionen. `newsyslog` se ejecuta periódicamente (a través de `cron(8)` en `/etc/crontab` o `newsyslogd`) para evaluar las políticas de rotación especificadas en `/etc/newsyslog.conf` y `/etc/newsyslog.conf.d/*.conf`.

#### Flujo de Evaluación por Archivo de Log:
1. **Verificación de tamaño (Size check)**: Se activa si el tamaño del log supera `size` (en KB).
2. **Verificación de tiempo (Time check)**: Se activa según especificaciones de tiempo en formato ISO 8601 o especificadores restringidos (por ejemplo, `$D0` para la medianoche diaria, `$W6D0` para semanal).
3. **Ejecución de la Rotación (Rotation Execution)**:
   - Renombra los archivos archivados (`.0` $\rightarrow$ `.1`, `.1` $\rightarrow$ `.2` hasta `count`).
   - Crea un nuevo archivo de log vacío con los permisos de archivo (`mode`), propietario (`owner`) y grupo (`group`) definidos.
   - Comprime los archivos según los flags especificados (`Z` para `gzip`, `J` para `xz`, `Y` para `zstd`).
   - Envía una señal de notificación al demonio (típicamente `SIGHUP` o `SIGUSR1`) utilizando un `pid_file` para instruir a la aplicación que reabra sus descriptores de archivo (file handles).

---

## 2. Manifiestos de Configuración para Entornos de Producción

### 2.1 Manifiesto Avanzado de `/etc/syslog.conf`

```ini
# ==============================================================================
# FreeBSD /etc/syslog.conf - Production Hardened Log Routing System
# ==============================================================================

# Kernel critical alerts directly to administrative console
kern.crit                                       /dev/console

# Emergency messages broadcast to all logged-in SRE engineers
*.emerg                                         *

# Standard system logging (excluding authentication, mail, and custom app facilities)
*.notice;auth.none;authpriv.none;mail.none;local0.none;local1.none    /var/log/messages

# Security and authentication logging (strict restricted access file)
auth.info;authpriv.info                         /var/log/auth.log

# Dedicated Mail subsystem logging
mail.info                                       /var/log/maillog

# Cron execution tracking
cron.info                                       /var/log/cron

# Remote Syslog Forwarding (Forward all local daemon errors to centralized collector)
# Using UDP port 514 with asynchronous output prefixing (@)
daemon.err                                      @192.168.10.254

# ------------------------------------------------------------------------------
# Program-Specific Scoping Block: Nginx Ingress Controller
# ------------------------------------------------------------------------------
!nginx
local0.info                                     /var/log/nginx/access.log
local1.err                                      /var/log/nginx/error.log
!*

# ------------------------------------------------------------------------------
# Host-Specific Scoping Block: Centralized Collector Filtering (if listening)
# ------------------------------------------------------------------------------
+db-primary.internal
*.err                                           /var/log/remote/db-errors.log
+*
```

---

### 2.2 Configuración de Rotación de Logs de Producción `/etc/newsyslog.conf.d/app.conf`

```ini
# ==============================================================================
# /etc/newsyslog.conf.d/app.conf - Rotation Policy for Custom Services
# ==============================================================================
# logfilename          [owner:group]  mode count size time flags [/pid_file] [sig_num]

# Standard System Messages (Rotated daily at midnight, compressed with ZSTD)
/var/log/messages      root:wheel     640  14    *    $D0  BCY   /var/run/syslog.d.pid 1

# Auth log (Rotated when size hits 10MB, retained 30 generations, restricted mode 600)
/var/log/auth.log      root:wheel     600  30    10240 *   CJZ   /var/run/syslog.d.pid 1

# Nginx Access Logs (Rotated every Sunday at midnight, 52 weeks retention)
/var/log/nginx/access.log www:www     644  52    *    $W6D0 Z     /var/run/nginx.pid 30

# High-volume local app log (Rotated at 50MB OR every 12 hours, uncompressed for speed)
/var/log/app/runtime.log app:app      640  7     51200 $H12 C    /var/run/app.pid 15

# Flag Legend:
# B = Binary file (do not insert rotation indicator line)
# C = Create empty file if it does not exist
# J = Compress with xz(1)
# Y = Compress with zstd(1)
# Z = Compress with gzip(1)
# N = No signal sent when rotated
```

---

## 3. Ejercicios Prácticos Guiados

### Ejercicio 1: Configuración de Enrutamiento de Facility Personalizada y Filtrado de Programas en FreeBSD

#### Objetivo de la Tarea
Configurar `syslogd(8)` para capturar eventos de `local0` que provengan strictly de un proceso de userland específico llamado `sre-agent` en `/var/log/sre-agent.log`, ignorando otras fuentes de log de `local0`.

#### Ejecución Paso a Paso

1. Crear el archivo de log de destino con los permisos administrativos adecuados:
   ```bash
   sudo touch /var/log/sre-agent.log
   sudo chmod 640 /var/log/sre-agent.log
   sudo chown root:wheel /var/log/sre-agent.log
   ```

2. Crear un snippet de configuración dedicado dentro de `/etc/syslog.d/sre-agent.conf`:
   ```bash
   sudo tee /etc/syslog.d/sre-agent.conf << 'EOF'
   !sre-agent
   local0.info                                     /var/log/sre-agent.log
   !*
   EOF
   ```

3. Validar la sintaxis de configuración de `syslogd` y recargar el demonio:
   ```bash
   sudo service syslogd reload
   ```
   *Salida de Ejecución Esperada:*
   ```text
   Reloading syslogd config files.
   ```

4. Emitir entradas de log de prueba utilizando `logger(1)` con diferentes nombres de etiquetas (tags) para probar el motor de scoping de programa:
   ```bash
   # Target program (Should be logged)
   logger -t sre-agent -p local0.info "HEALTH_CHECK_OK: Engine latency 1.2ms"

   # Non-matching program sending to same facility (Should be ignored by filter)
   logger -t random-app -p local0.info "IGNORE_ME: Unmatched entry"
   ```

5. Verificar el contenido del archivo de salida:
   ```bash
   cat /var/log/sre-agent.log
   ```
   *Salida de Ejecución Esperada:*
   ```text
   Aug  6 20:43:26 bsd-host sre-agent[41029]: HEALTH_CHECK_OK: Engine latency 1.2ms
   ```

---

#### Preguntas de Verificación (Punto de Control 1)
1. ¿Por qué el mensaje de `random-app` fue excluido de `/var/log/sre-agent.log` a pesar de especificar `local0.info`?
2. ¿Qué sucedería si la directiva `!*` se omitiera al final de `/etc/syslog.d/sre-agent.conf`?

---

### Ejercicio 2: Hardening y Habilitación del Receptor UDP de Syslog Remoto

#### Objetivo de la Tarea
Configurar el `syslogd` de FreeBSD para aceptar tráfico syslog remoto en el puerto UDP 514 desde la subred `192.168.10.0/24`, vinculado exclusivamente a la IP de la interfaz local `192.168.10.50`.

#### Ejecución Paso a Paso

1. Verificar los flags del proceso `syslogd` actuales y el estado del socket en escucha:
   ```bash
   sockstat -46 -l -p 514
   ```
   *Salida de Ejecución Esperada:*
   ```text
   USER     COMMAND    PID   FD PROTO  LOCAL ADDRESS         FOREIGN ADDRESS
   ```
   *(La ausencia de salida indica que los sockets de red están desactivados por defecto debido a `-s`).*

2. Configurar los parámetros de vinculación de red dentro de `/etc/rc.conf`:
   ```bash
   sudo sysrc syslogd_enable="YES"
   sudo sysrc syslogd_flags="-u -b 192.168.10.50 -a 192.168.10.0/24:514"
   ```

3. Reiniciar el servicio `syslogd` para instanciar los nuevos flags del socket:
   ```bash
   sudo service syslogd restart
   ```
   *Salida de Ejecución Esperada:*
   ```text
   Stopping syslogd.
   Waiting for PIDS: 1104.
   Starting syslogd.
   ```

4. Auditar el estado de vinculación del socket utilizando `sockstat(1)`:
   ```bash
   sockstat -4 -l -p 514
   ```
   *Salida de Ejecución Esperada:*
   ```text
   USER     COMMAND    PID   FD PROTO  LOCAL ADDRESS         FOREIGN ADDRESS
   root     syslogd    41882 7  udp4   192.168.10.50:514     *:*
   ```

5. Simular el ingreso de logs remotos utilizando `logger` apuntando a la interfaz de red:
   ```bash
   logger -h 192.168.10.50 -p daemon.err "REMOTE_TEST: Ingress message over UDP 514"
   ```

6. Inspeccionar `/var/log/messages` para comprobar la llegada del mensaje:
   ```bash
   tail -n 1 /var/log/messages
   ```
   *Salida de Ejecución Esperada:*
   ```text
   Aug  6 20:45:10 192.168.10.50 syslogd[41882]: REMOTE_TEST: Ingress message over UDP 514
   ```

---

#### Preguntas de Verificación (Punto de Control 2)
1. ¿Qué condición de error surge si un cliente no autorizado (por ejemplo, `172.16.0.4`) intenta transmitir paquetes de log UDP a este servidor?
2. ¿Cómo altera el comportamiento del proceso en tiempo de ejecución la combinación de `-s` y `-u` en `syslogd_flags`?

---

### Ejercicio 3: Implementación de Políticas de Rotación Automatizadas con `newsyslog`

#### Objetivo de la Tarea
Construir una entrada de rotación para `/var/log/sre-agent.log` haciendo cumplir:
- Límite de tamaño máximo de 1MB (1024KB).
- Retención de 5 copias de archivos comprimidos (`xz`).
- Creación de archivos de log faltantes con permisos `0640` (`root:wheel`).
- Transmisión de `SIGHUP` a `syslogd` al realizar la rotación.

#### Ejecución Paso a Paso

1. Crear un archivo de configuración en `/etc/newsyslog.conf.d/sre-agent.conf`:
   ```bash
   sudo tee /etc/newsyslog.conf.d/sre-agent.conf << 'EOF'
   # logfilename          [owner:group]  mode count size time flags [/pid_file] [sig_num]
   /var/log/sre-agent.log root:wheel     640  5     1024 *    CJ    /var/run/syslog.d.pid 1
   EOF
   ```

2. Ejecutar una prueba de rotación en modo dry-run detallado (verbose) usando `newsyslog(8)` para inspeccionar la lógica sin alterar el estado del sistema de archivos:
   ```bash
   newsyslog -nvv -f /etc/newsyslog.conf.d/sre-agent.conf
   ```
   *Salida de Ejecución Esperada:*
   ```text
   Processing file /etc/newsyslog.conf.d/sre-agent.conf
   /var/log/sre-agent.log <root:wheel>: mode is 0640, flags: 0x10 (CJ), count: 5, size: 1024, time: *
   /var/log/sre-agent.log: size (bytes): 62 [required 1048576] -> non-rotation condition met.
   Skipping /var/log/sre-agent.log
   ```

3. Forzar una ejecución inmediata de rotación utilizando el flag `-F`:
   ```bash
   sudo newsyslog -F -v -f /etc/newsyslog.conf.d/sre-agent.conf
   ```
   *Salida de Ejecución Esperada:*
   ```text
   Processing file /etc/newsyslog.conf.d/sre-agent.conf
   /var/log/sre-agent.log <root:wheel>: mode is 0640, flags: 0x10 (CJ), count: 5, size: 1024, time: *
   Compacting /var/log/sre-agent.log.0 to /var/log/sre-agent.log.0.xz
   Sending signal 1 to PID 41882 read from /var/run/syslog.d.pid
   ```

4. Verificar el listado del directorio para comprobar el archivo comprimido recién generado:
   ```bash
   ls -la /var/log/sre-agent.log*
   ```
   *Salida de Ejecución Esperada:*
   ```text
   -rw-r-----  1 root  wheel     0 Aug  6 20:47 /var/log/sre-agent.log
   -rw-r-----  1 root  wheel    88 Aug  6 20:47 /var/log/sre-agent.log.0.xz
   ```

---

#### Preguntas de Verificación (Punto de Control 3)
1. ¿Cuál es la importancia operativa de la señal numérica `1` especificada al final de la línea de configuración de `newsyslog`?
2. Si el flag `C` fuera omitido del archivo de política y `/var/log/sre-agent.log` no existiera durante la ejecución de la rotación, ¿cómo manejaría `newsyslog` dicho escenario?

---

## 4. Laboratorio de Diagnóstico Avanzado y Troubleshooting

### Matriz de Herramientas de Diagnóstico
| Herramienta | Propósito de Diagnóstico | Sintaxis del Comando |
| :--- | :--- | :--- |
| `logger(1)` | Inyección manual de logs en userland | `logger -p daemon.err -t MY_TAG "Test log"` |
| `sockstat(1)` | Inspección de sockets BSD en escucha | `sockstat -46 -l -p 514` |
| `newsyslog(8)` | Depurar la lógica de rotación y parsear flags | `newsyslog -nvv -f /path/to/conf` |
| `tcpdump(1)` | Captura de paquetes en la capa de red en el puerto syslog | `tcpdump -ni igb0 -X udp port 514` |

### Escenario de Producción: Depuración de Pérdida Silenciosa de Logs

#### Declaración del Problema
Una aplicación configurada para transmitir logs a `local2.err` no está generando salida en `/var/log/app-error.log`.

#### Flujo de Trabajo Real de Ejecución de Diagnóstico

1. Validar el estado del proceso de `syslogd`:
   ```bash
   pgrep -lf syslogd
   ```
   *Salida:*
   ```text
   41882 /usr/sbin/syslogd -u -b 192.168.10.50 -a 192.168.10.0/24:514
   ```

2. Rastrear los mapeos de descriptores de archivos activos para `syslogd` para garantizar que los file handles de destino estén abiertos:
   ```bash
   fstat -p 41882 | grep /var/log
   ```
   *Salida:*
   ```text
   root     syslogd    41882    4 /var      104820 -rw-r-----  wd
   root     syslogd    41882    5 /var/log/messages  104822 -rw-r-----  w
   root     syslogd    41882    6 /var/log/auth.log  104825 -rw-r-----  w
   ```
   *(Observe que `/var/log/app-error.log` falta en la lista de descriptores de archivo abiertos).*

3. Probar el parsing de configuración utilizando `logger`:
   ```bash
   logger -p local2.err -t APP "TEST_ERR_LINE"
   ```

4. Auditar el orden de las reglas de syslog en `/etc/syslog.conf`. Si un bloque catch-all o un bloque de programa (`!otherprogram`) está activo por encima de la línea sin ser restablecido (`!*`), los selectores subsiguientes fallarán al evaluarse.

---

<details>
<summary><strong>Hacé clic para expandir las Soluciones y Explicaciones Detalladas de los Puntos de Control</strong></summary>

### Respuestas de Verificación: Punto de Control 1
1. **Respuesta**: El bloque de alcance (scoping) de programa `!sre-agent` crea un contexto de filtro. Cualquier línea de log enviada con una etiqueta (`-t`) que **no** coincida con `sre-agent` es ignorada por todos los selectores contenidos dentro de ese bloque, independientemente de la coincidencia de facility (`local0.info`).
2. **Respuesta**: Si se omite `!*`, el filtro de programa `!sre-agent` permanece activo para **todas las líneas subsiguientes** en `/etc/syslog.conf` y en cualquier archivo `/etc/syslog.d/*.conf` adjunto, evitando que todas las reglas posteriores procesen logs de otras aplicaciones.

---

### Respuestas de Verificación: Punto de Control 2
1. **Respuesta**: El paquete será descartado por `syslogd` en la capa de aplicación de userland porque no supera las comprobaciones de control de acceso definidas por `-a 192.168.10.0/24:514`. No se escribirá ninguna entrada de log y, si la depuración detallada está habilitada en `syslogd`, se registrará internamente un error de "out of access list".
2. **Respuesta**: La precedencia de flags de `syslogd` evalúa `-s` sobre `-u`. Si se pasan tanto `-s` como `-u`, `-s` deshabilita la escucha de red, dejando inactivo al receptor de red.

---

### Respuestas de Verificación: Punto de Control 3
1. **Respuesta**: La señal `1` corresponde a `SIGHUP` (Hangup). Cuando `newsyslog` completa el movimiento y compresión de los archivos de log, el envío de `SIGHUP` instruye a `syslogd` a volver a leer sus archivos de configuración, cerrar los file handles antiguos y abrir el archivo de log vacío recién creado para su escritura.
2. **Respuesta**: Sin el flag `C`, `newsyslog` asume que el archivo de log ya debe existir. Emitirá un mensaje de error indicando que no se encontró el archivo y omitirá por completo la rotación para esa entrada.

</details>