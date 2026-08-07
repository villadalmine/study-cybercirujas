# LPI-702 (Exam 702-100) Topic 711.5: BSD Kernel Parameters and System Security Level
**Peso:** 3.33  
**Audiencia Objetivo:** SREs, Arquitectos de Sistemas e Ingenieros de Seguridad que se preparan para la certificación CNCF/BSDCert BSD Specialist.  
**Referencias Oficiales:**
* LPI BSD Specialist Overview: [https://www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)
* FreeBSD `securelevel(7)` Man Page: [https://man.freebsd.org/cgi/man.cgi?query=securelevel&sektion=7](https://man.freebsd.org/cgi/man.cgi?query=securelevel&sektion=7)
* FreeBSD `sysctl(8)` Man Page: [https://man.freebsd.org/cgi/man.cgi?query=sysctl&sektion=8](https://man.freebsd.org/cgi/man.cgi?query=sysctl&sektion=8)
* OpenBSD `securelevel(7)` Man Page: [https://man.openbsd.org/securelevel.7](https://man.openbsd.org/securelevel.7)
* NetBSD `secmodel_securelevel(9)` Man Page: [https://man.netbsd.org/secmodel_securelevel.9](https://man.netbsd.org/secmodel_securelevel.9)

---

## Descripción Técnica y Arquitectura

Los sistemas operativos BSD exponen los componentes internos del kernel al userland a través de una estructura de árbol jerárquica conocida como **Management Information Base (MIB)**. La interfaz de la utilidad `sysctl(8)` permite a los administradores del sistema consultar y ajustar estas variables MIB en tiempo real. 

Complementando el ajuste de parámetros en tiempo de ejecución se encuentra el **System Security Level** de BSD (`kern.securelevel`), un mecanismo de aplicación de integridad a nivel de kernel. Una vez elevado, `kern.securelevel` establece límites de seguridad inmutables que restringen incluso al superusuario `root` (`UID 0`).

```
                              +---------------------------------------+
                              |        Userland Applications          |
                              +---------------------------------------+
                                        |                   |
                                (read / write MIB)     (chflags / disk io)
                                        |                   |
                                        v                   v
+-----------------------------------------------------------------------------------+
| FreeBSD / OpenBSD / NetBSD Kernel                                                 |
|                                                                                   |
|  +---------------------------------+     +-------------------------------------+  |
|  |     Management Info Base        |     |   kern.securelevel State Machine    |  |
|  |             (MIB)               |     |                                     |  |
|  |                                 |     |  Level -1: Permanently Insecure     |  |
|  |  kern.*  net.*  vm.*  security.*|     |  Level  0: Insecure Mode (Boot/1-user)|  |
|  |  hw.*    machdep.*  vfs.*       |     |  Level  1: Secure Mode              |  |
|  +---------------------------------+     |  Level  2: Highly Secure Mode       |  |
|                  |                       |  Level  3: Network Secure Mode      |  |
|                  |                       +-------------------------------------+  |
|                  v                                          |                     |
|       [CTLFLAG_SECURE Enforcement] <------------------------+                     |
|       Blocks tuning of sensitive MIBs when securelevel > 0                        |
+-----------------------------------------------------------------------------------+
```

### Clasificación y Ciclo de Vida de las MIB del Kernel

Los sysctls de BSD se dividen en tres categorías principales según cuándo y cómo se pueden modificar:

1. **Variables Dinámicas en Tiempo de Ejecución (`CTLFLAG_RW`):** Parámetros de lectura y escritura modificables en tiempo de ejecución a través de `sysctl -w` o `/etc/sysctl.conf` durante la inicialización del sistema.
2. **Parámetros de Solo Lectura (`CTLFLAG_RD`):** Metadatos estáticos del sistema (por ejemplo, arquitectura de CPU compilada, tamaño de página, cadena de versión del kernel) que no se pueden alterar bajo ningún nivel de seguridad.
3. **Tunables del Bootloader (`CTLFLAG_TUN`):** Asignaciones de memoria y configuraciones de controladores (drivers) que deben establecerse durante la inicialización del kernel antes de que se complete la enumeración del hardware. Administrados a través de `/boot/loader.conf` en FreeBSD.

### La Máquina de Estados Monotónica de `securelevel`

El parámetro `kern.securelevel` impone una **máquina de estados strictly monotónica**. Puede ser incrementado por un proceso privilegiado (`UID 0`) en cualquier momento, pero **nunca se puede reducir mientras el kernel se esté ejecutando en modo multiusuario (multi-user mode)**. Reducir `securelevel` requiere un reinicio completo del sistema o entrar en modo usuario único (single-user mode) a través de `/sbin/init`.

| Nivel de Seguridad | Nombre | Restricciones Clave de Integridad |
| :--- | :--- | :--- |
| **-1** | Permanente Inseguro | La verificación de seguridad del kernel está completamente deshabilitada. Init no elevará automáticamente el nivel en el arranque multiusuario. |
| **0** | Modo Inseguro | Modo de inicio del sistema. Las flags de archivos inmutables y de solo anexar (`schg`, `sappnd`) se pueden desmarcar. Se permiten escrituras en disco crudo (raw disk). |
| **1** | Modo Seguro | Bloquea la eliminación de las flags `schg`/`sappnd`. Evita la escritura en `/dev/mem` y `/dev/kmem`. Bloquea la carga/descarga de módulos del kernel (`kldload`/`kldunload`). Deshabilita la ejecución directa de operaciones de memoria/bus de I/O. |
| **2** | Modo Altamente Seguro | Extiende el Nivel 1. Bloquea el acceso de escritura directa (raw) a dispositivos de disco de bloques/caracteres montados o desmontados. Evita atrasar el reloj del sistema (wall clock) en más de 1 segundo. |
| **3** | Modo Seguro de Red | Extiende el Nivel 2. Bloquea los conjuntos de reglas de IP Packet Filter (`pf` / `ipfw`); las modificaciones de reglas del firewall de red son rechazadas completamente por el kernel. |

---

## Ejercicio de Laboratorio 1: Inspección de MIB del Kernel en Tiempo de Ejecución y Ajuste Persistente

### Escenario
Como Arquitecto de Sistemas, debes auditar los parámetros dinámicos del kernel en un clúster web edge de producción FreeBSD 14-RELEASE, ajustar los parámetros del stack de red TCP para mitigar ataques SYN flood, configurar los comportamientos de volcado de memoria (memory dump) y garantizar que todos los cambios persistan a través de los reinicios del kernel sin causar fallos de arranque.

### Pasos de Ejecución

1. Inicia sesión en tu instancia BSD como `root`. Inspecciona las categorías de nivel superior de la Management Information Base (MIB) del kernel y consulta todas las variables `net.inet.tcp`.

```bash
sysctl net.inet.tcp | head -n 15
```

**Salida Esperada:**
```text
net.inet.tcp.rfc1323: 1
net.inet.tcp.mssdflt: 536
net.inet.tcp.v6mssdflt: 1220
net.inet.tcp.somaxconn: 512
net.inet.tcp.syncache.rexmtlimit: 3
net.inet.tcp.syncache.hashsize: 512
net.inet.tcp.syncache.bucketlimit: 30
net.inet.tcp.syncache.cachelimit: 15360
net.inet.tcp.syncache.count: 0
net.inet.tcp.buffersize: 131072
net.inet.tcp.recvspace: 65536
net.inet.tcp.sendspace: 32768
net.inet.tcp.always_keepalive: 1
net.inet.tcp.delayed_ack: 1
net.inet.tcp.blackhole: 0
```

2. Inspecciona la descripción y el tipo de datos de los parámetros `net.inet.tcp.blackhole` y `kern.coredump` utilizando flags extendidas de sysctl.

```bash
sysctl -d net.inet.tcp.blackhole
sysctl -d kern.coredump
```

**Salida Esperada:**
```text
net.inet.tcp.blackhole: Do not send RST when dropping TCP packets for closed ports
kern.coredump: Enable core dumps on abnormal program termination
```

3. Incrementa el backlog de la cola del socket de escucha (`somaxconn`) del valor predeterminado a `4096` y establece `net.inet.tcp.blackhole` en `2` (descartar paquetes TCP SYN enviados a puertos cerrados sin devolver un TCP RST) de forma dinámica en tiempo de ejecución.

```bash
sysctl net.inet.tcp.somaxconn=4096
sysctl net.inet.tcp.blackhole=2
```

**Salida Esperada:**
```text
net.inet.tcp.somaxconn: 512 -> 4096
net.inet.tcp.blackhole: 0 -> 2
```

4. Intenta escribir en una MIB tunable de tiempo de arranque (por ejemplo, `kern.ipc.nmbclusters`) dinámicamente mediante `sysctl` en tiempo de ejecución para observar el manejo que hace el kernel de las variables `CTLFLAG_TUN`.

```bash
sysctl kern.ipc.nmbclusters=262144
```

**Salida Esperada:**
```text
sysctl: kern.ipc.nmbclusters: sysctl oid 'kern.ipc.nmbclusters' is read-only (or tunable only)
```

5. Configura parámetros persistentes en tiempo de ejecución en `/etc/sysctl.conf` y tunables del bootloader en `/boot/loader.conf`.

```bash
cat << 'EOF' >> /etc/sysctl.conf
# Dynamic Network & Security Tuning
net.inet.tcp.somaxconn=4096
net.inet.tcp.blackhole=2
kern.coredump=0
EOF

cat << 'EOF' >> /boot/loader.conf
# Early Bootloader Tunables
kern.ipc.nmbclusters="262144"
cc_cubic_load="YES"
EOF
```

6. Verifica que la sintaxis de `/etc/sysctl.conf` sea válida forzando una relectura de la configuración sin reiniciar.

```bash
sysctl -f /etc/sysctl.conf
```

**Salida Esperada:**
```text
net.inet.tcp.somaxconn: 4096 -> 4096
net.inet.tcp.blackhole: 2 -> 2
kern.coredump: 1 -> 0
```

---

### Preguntas de Comprensión - Bloque 1

**Pregunta 1.1:** ¿Cuál es la distinción técnica entre configurar un parámetro del kernel en `/etc/sysctl.conf` frente a `/boot/loader.conf` en FreeBSD?  
A) `/etc/sysctl.conf` es analizado por el kernel antes de la inicialización de los controladores de dispositivos, mientras que `/boot/loader.conf` es evaluado por `init(8)` durante el modo de usuario único.  
B) Los parámetros de `/boot/loader.conf` son cargados en las variables de entorno del kernel por el bootloader (`loader(8)`) antes de la ejecución del kernel; `/etc/sysctl.conf` se procesa al final de la secuencia de arranque mediante scripts de userland a través de `sysctl(8)`.  
C) Los parámetros en `/etc/sysctl.conf` pueden alterar variables `CTLFLAG_RD`, mientras que `/boot/loader.conf` solo puede establecer variables `CTLFLAG_RW`.  
D) `/boot/loader.conf` se aplica estrictamente a sistemas OpenBSD, mientras que `/etc/sysctl.conf` es exclusivo de FreeBSD.

**Pregunta 1.2:** Intentas ejecutar `sysctl -w net.inet.tcp.blackhole=2` en un sistema que opera en `kern.securelevel=1`, pero el comando falla con `Permission denied`. ¿Qué mecanismo causa este rechazo?  
A) `net.inet.tcp.blackhole` está marcado con `CTLFLAG_SECURE`, lo que impide modificaciones en el userland una vez que el securelevel es mayor a 0.  
B) Securelevel 1 fuerza a que todos los puntos de montaje del sistema de archivos que contienen `/sbin/sysctl` se vuelvan de solo lectura.  
C) `sysctl` requiere que se elimine la flag `schg` de `/etc/sysctl.conf` antes de escribir valores.  
D) Los sysctls de red solo se pueden modificar cuando `kern.securelevel` está configurado en el nivel 3 o superior.

---

## Ejercicio de Laboratorio 2: Endurecimiento de Archivos del Sistema y la Máquina de Estados de `securelevel`

### Escenario
Estás endureciendo (hardening) un host bastión SSH expuesto. Debes aplicar flags inmutables de sistema (`schg`) a los directorios de ejecución binaria (`/bin`, `/sbin`, `/usr/bin`) y flags de solo anexar (`sappnd`) a los registros de auditoría críticos. Luego elevarás `kern.securelevel` a `1` y demostrarás cómo el kernel bloquea los procesos privilegiados de root para evitar que manipulen estos binarios o carguen módulos del kernel no verificados.

### Pasos de Ejecución

1. Crea un binario de sistema ficticio `/bin/custom_monitor` y un archivo de registro inmutable `/var/log/audit.log`. Asigna la flag `schg` al binario y `sappnd` al archivo de registro utilizando `chflags(1)`.

```bash
touch /bin/custom_monitor && chmod 755 /bin/custom_monitor
touch /var/log/audit.log && chmod 600 /var/log/audit.log

chflags schg /bin/custom_monitor
chflags sappnd /var/log/audit.log
ls -lo /bin/custom_monitor /var/log/audit.log
```

**Salida Esperada:**
```text
-rwxr-xr-x  1 root  wheel  schg   0 Aug  6 20:15 /bin/custom_monitor
-rw-------  1 root  wheel  sappnd 0 Aug  6 20:15 /var/log/audit.log
```

2. Confirma que en el nivel de inicio predeterminado (`kern.securelevel=0` o `-1`), el usuario `root` puede anexar datos al registro, eliminar la flag `schg` y modificar el archivo.

```bash
sysctl kern.securelevel
echo "Audit entry 1" >> /var/log/audit.log
chflags noschg /bin/custom_monitor
echo "#!/bin/sh" > /bin/custom_monitor
chflags schg /bin/custom_monitor
```

**Salida Esperada:**
```text
kern.securelevel: -1
```
*(Los comandos se ejecutan limpiamente sin errores)*

3. Verifica la configuración actual de securelevel en `/etc/rc.conf`. Configura la infraestructura de inicio de BSD para aplicar automáticamente `securelevel=1` en el arranque.

```bash
sysrc kern_securelevel_enable="YES"
sysrc kern_securelevel="1"
grep kern_securelevel /etc/rc.conf
```

**Salida Esperada:**
```text
kern_securelevel_enable: NO -> YES
kern_securelevel: -1 -> 1
kern_securelevel_enable="YES"
kern_securelevel="1"
```

4. Eleva dinámicamente el `kern.securelevel` en tiempo de ejecución de `-1` a `1` usando `sysctl`.

```bash
sysctl kern.securelevel=1
sysctl kern.securelevel
```

**Salida Esperada:**
```text
kern.securelevel: -1 -> 1
kern.securelevel: 1
```

5. Intenta volver a bajar el `kern.securelevel` a `0` o `-1` mientras se ejecuta en modo multiusuario.

```bash
sysctl kern.securelevel=0
```

**Salida Esperada:**
```text
sysctl: kern.securelevel: Operation not permitted
```

6. Prueba el cumplimiento de las flags de archivo bajo `securelevel=1`. Intenta anexar a `/var/log/audit.log`, sobrescribir `/var/log/audit.log` y eliminar la flag `schg` de `/bin/custom_monitor`.

```bash
echo "Audit entry 2" >> /var/log/audit.log
echo "Overwriting log" > /var/log/audit.log
chflags noschg /bin/custom_monitor
```

**Salida Esperada:**
```text
bash: /var/log/audit.log: Operation not permitted
chflags: /bin/custom_monitor: Operation not permitted
```

7. Intenta cargar dinámicamente un módulo del kernel (por ejemplo, `ipfw` o `snmpmod`) en el kernel en ejecución mediante `kldload(8)` bajo `securelevel=1`.

```bash
kldload ipfw
```

**Salida Esperada:**
```text
kldload: can't load ipfw: Operation not permitted
```

---

### Preguntas de Comprensión - Bloque 2

**Pregunta 2.1:** Un atacante con acceso root compromete un servidor que opera en `kern.securelevel=1`. El atacante intenta eludir la inmutabilidad de archivos ejecutando `chflags noschg /bin/login`. ¿Cómo reacciona el kernel de BSD?  
A) El kernel permite el comando porque `UID 0` conserva el privilegio absoluto sobre las flags de archivos independientemente del securelevel.  
B) El sistema entra inmediatamente en pánico (panic) y cae en el depurador del kernel (`db>`).  
C) La syscall `chflags(2)` falla con `EPERM` (Operation not permitted) porque el kernel verifica `securelevel > 0` antes de permitir el restablecimiento de flags.  
D) La flag se modifica en memoria, pero las operaciones de sincronización de disco se posponen hasta que el securelevel baje a `0`.

**Pregunta 2.2:** ¿Por qué falla `kldload` bajo `kern.securelevel=1`?  
A) Los archivos de módulos del kernel en disco heredan automáticamente la flag `nodump` en el securelevel 1.  
B) Cargar módulos arbitrarios del kernel permitiría la ejecución de código arbitrario en ring-0, eludiendo todas las restricciones de securelevel.  
C) Los símbolos del enlazador dinámico se purgan de la memoria del kernel al entrar en estado multiusuario.  
D) Securelevel 1 restringe el acceso directo (raw) al almacenamiento de bloques, impidiendo que `kldload` lea objetos del kernel.

---

## Ejercicio de Laboratorio 3: Protección de Bloques Crudos de Almacenamiento, Integridad del Firewall y Bloqueo de Desviación de Reloj (Niveles 2 y 3)

### Escenario
En una infraestructura de comercio financiero de alta seguridad, se debe evitar que un atacante con acceso root manipule discos físicos en modo crudo (`/dev/ada0`), altere la hora del sistema NTP para oscurecer los números de secuencia del registro de auditoría o elimine (flush) los conjuntos de reglas del firewall Packet Filter (`pf`). Tienes la tarea de escalar el sistema a `securelevel=2` y `securelevel=3` para probar los límites de defensa a nivel de kernel.

### Pasos de Ejecución

1. Comprueba los sistemas de archivos montados actualmente para identificar los nodos de dispositivos crudos (raw device nodes).

```bash
mount | grep 'on / '
```

**Salida Esperada:**
```text
/dev/ada0p2 on / (ufs, local, soft-updates)
```

2. Eleva `kern.securelevel` de `1` a `2`.

```bash
sysctl kern.securelevel=2
sysctl kern.securelevel
```

**Salida Esperada:**
```text
kern.securelevel: 1 -> 2
kern.securelevel: 2
```

3. Intenta escribir datos de basura crudos (raw garbage data) directamente en el dispositivo de bloques de disco crudo subyacente (`/dev/ada0`) usando `dd(1)` como `root`.

```bash
dd if=/dev/zero of=/dev/ada0 bs=512 count=1 seek=1
```

**Salida Esperada:**
```text
dd: /dev/ada0: Operation not permitted
```

4. Prueba el cumplimiento del control de manipulación del reloj del sistema bajo `securelevel=2`. Intenta retroceder la hora del sistema en 100 segundos usando `date(1)`.

```bash
date -r $(($(date +%s) - 100))
```

**Salida Esperada:**
```text
date: settimeofday (ns): Operation not permitted
```

5. Eleva `kern.securelevel` a `3` (Modo Seguro de Red / Bloqueo de Firewall).

```bash
sysctl kern.securelevel=3
sysctl kern.securelevel
```

**Salida Esperada:**
```text
kern.securelevel: 2 -> 3
kern.securelevel: 3
```

6. Intenta alterar o vaciar (flush) el conjunto de reglas activo del filtro de paquetes `pf(4)` de OpenBSD/FreeBSD usando `pfctl(8)`.

```bash
pfctl -F rules
```

**Salida Esperada:**
```text
pfctl: DIOCXCOMMIT: Operation not permitted
```

---

### Preguntas de Comprensión - Bloque 3

**Pregunta 3.1:** ¿Qué protección distintiva añade `securelevel=2` respecto a los dispositivos de almacenamiento sobre `securelevel=1`?  
A) El Nivel 1 evita la escritura en dispositivos de bloques montados, mientras que el Nivel 2 evita la lectura desde dispositivos de caracteres crudos no montados.  
B) El Nivel 1 permite el acceso de escritura cruda a dispositivos de disco que están montados actualmente; el Nivel 2 prohíbe las escrituras en disco crudo en todos los dispositivos de bloques/caracteres, ya estén montados o desmontados.  
C) El Nivel 2 fuerza a todos los sistemas de archivos montados al modo VFS de `read-only` (solo lectura).  
D) El Nivel 2 encripta el registro de arranque maestro (MBR) y la tabla de particiones GUID (GPT) dinámicamente en memoria.

**Pregunta 3.2:** Bajo `securelevel=2`, un demonio NTP intenta corregir la desviación del reloj. ¿Qué operación de ajuste de tiempo tendrá éxito?  
A) Retroceder el reloj bruscamente en 300 segundos usando `settimeofday(2)`.  
B) Ajustes graduales (slew adjustments) realizados mediante `adjtime(2)` que ajustan incrementalmente la velocidad de los tics del reloj sin retroceder el tiempo bruscamente.  
C) Cualquier retroceso ejecutado por `UID 0` usando `date -f`.  
D) Cambios de reloj solicitados por hilos del kernel que escriben directamente en los registros RTC del sistema.

---

## Ejercicio de Laboratorio 4: Comparación de Arquitectura entre BSDs, Secmodel de NetBSD y Recuperación de Emergencia

### Escenario
Las diferentes variantes de BSD gestionan los parámetros del kernel y los niveles de seguridad mediante subsistemas únicos. NetBSD utiliza el marco modular **Secmodel** (`secmodel_securelevel(9)`), mientras que OpenBSD aplica configuraciones rígidas de nivel de seguridad a través de `/etc/sysctl.conf`. Como Líder SRE, debes documentar estas variaciones entre plataformas y realizar un procedimiento de recuperación de emergencia arrancando en modo de usuario único en un nodo bloqueado en `securelevel=2` donde un archivo de configuración inmutable requiere ediciones de emergencia.

### Matriz de Comparación de Subsistemas

```
+------------------+-----------------------------+-------------------------------+-----------------------------------+
| Feature          | FreeBSD 14-RELEASE          | OpenBSD 7.x                   | NetBSD 10.x                       |
+------------------+-----------------------------+-------------------------------+-----------------------------------+
| Runtime Tool     | sysctl(8)                   | sysctl(8)                     | sysctl(8)                         |
| Tunable Config   | /boot/loader.conf           | Bootloader boot.conf          | /boot.cfg                         |
| Persistence File | /etc/sysctl.conf            | /etc/sysctl.conf              | /etc/sysctl.conf                  |
| Securelevel Reg  | /etc/rc.conf                | /etc/rc.conf.local            | /etc/sysctl.conf                  |
| Framework Basis  | Traditional BSD Securelevel | Traditional BSD Securelevel   | kauth(9) / secmodel_securelevel(9)|
| Max Securelevel  | 3 (Network Security Mode)   | 2 (Highly Secure Mode)        | 2 (Highly Secure Mode)            |
+------------------+-----------------------------+-------------------------------+-----------------------------------+
```

### Pasos de Ejecución

1. Examina los sysctls de autorización del kernel específicos de NetBSD para comprender la capa de abstracción `secmodel`.

```bash
# On NetBSD systems:
sysctl security.models
sysctl security.securelevel.formal_name
```

**Salida Esperada:**
```text
security.models: bsd44
security.securelevel.formal_name: Traditional BSD Securelevel
```

2. **Escenario de Recuperación de Emergencia:** Un servidor bloqueado en `securelevel=2` contiene un archivo de configuración inmutable (`/etc/pf.conf` con la flag `schg` establecida) que impide el acceso SSH. Debido a que el `securelevel` no se puede reducir en modo multiusuario, debes simular el procedimiento de recuperación en modo de usuario único.

Inicia el reinicio del sistema para ir a la consola del bootloader.

```bash
reboot
```

3. En la consola del menú del bootloader de FreeBSD, interrumpe la cuenta regresiva y arranca en **Single-User Mode** (Opción 2 o el comando `boot -s`).

```text
Type '?' for a list of commands, 'help' for more detailed help.
OK boot -s
```

4. Una vez que aparezca la consola de usuario único (`/bin/sh`), observa que `kern.securelevel` se inicia en el nivel `0` o `-1`.

```bash
# In single-user shell:
sysctl kern.securelevel
```

**Salida Esperada:**
```text
kern.securelevel: -1
```

5. Monta el sistema de archivos raíz en modo lectura-escritura, elimina la flag inmutable del archivo, corrige la configuración y vuelve al arranque multiusuario.

```bash
mount -u -o rw /
chflags noschg /etc/pf.conf
echo "pass in all" > /etc/pf.conf
exit
```

**Salida Esperada:**
```text
[System transitions to multi-user mode, parsing /etc/rc.conf and elevating securelevel back to configured target]
```

---

### Preguntas de Comprensión - Bloque 4

**Pregunta 4.1:** ¿Cómo implementa NetBSD la funcionalidad `securelevel` de forma diferente a las implementaciones tradicionales de FreeBSD/OpenBSD?  
A) NetBSD compila `securelevel` directamente en el firmware del hardware a través de sondas eBPF.  
B) NetBSD implementa securelevel como un módulo conectable (pluggable) de autorización del kernel (`secmodel_securelevel(9)`) integrado en el subsistema `kauth(9)`.  
C) NetBSD permite que `root` reduzca `securelevel` si se proporcionan tokens firmados de capacidad del kernel a `sysctl`.  
D) NetBSD utiliza `/etc/loader.conf` exclusivamente para modificar los niveles de seguridad durante operaciones multiusuario.

**Pregunta 4.2:** Durante una recuperación de emergencia en modo de usuario único (`boot -s`), ¿por qué el administrador puede limpiar las flags `schg` que estaban bloqueadas en modo multiusuario?  
A) El modo de usuario único cambia automáticamente la propiedad del archivo de todos los binarios a `nobody`.  
B) `init(8)` inicia el modo de usuario único antes de ejecutar `/etc/rc`, manteniendo `kern.securelevel` en el estado `0` o `-1`.  
C) El binario `chflags` elude las llamadas al sistema del kernel cuando se ejecuta en modo de consola bruta (raw console mode).  
D) El modo de usuario único deshabilita la capa Virtual File System (VFS) por completo.

---

## <details><summary>Respuestas de los Ejercicios y Justificación Técnica</summary>

### Respuestas del Ejercicio 1

* **Pregunta 1.1:** **B**
  * **Justificación:** `/boot/loader.conf` es procesado por el bootloader de FreeBSD (`loader(8)`) antes de que el kernel se inicialice. Configura variables de entorno del kernel y tunables del bootloader (`CTLFLAG_TUN`). `/etc/sysctl.conf` se evalúa más adelante en el proceso de inicio mediante scripts de usuario en el userland (`/etc/rc.d/sysctl`) que invocan a `sysctl(8)` para configurar MIBs dinámicas en tiempo de ejecución (`CTLFLAG_RW`).
* **Pregunta 1.2:** **A**
  * **Justificación:** En los kernels BSD, los nodos de MIB sysctl se pueden declarar con la flag `CTLFLAG_SECURE`. Cuando `kern.securelevel` es mayor que 0, el subsistema `sysctl` del kernel rechaza explícitamente las solicitudes de modificación de estos parámetros específicos, devolviendo `EPERM` (Permission denied), independientemente del estado de superusuario.

### Respuestas del Ejercicio 2

* **Pregunta 2.1:** **C**
  * **Justificación:** La llamada al sistema `chflags(2)` verifica el nivel de seguridad del sistema cuando se solicita la modificación de las flags del sistema (`SF_IMMUTABLE` / `schg`, `SF_APPEND` / `sappnd`). Si `kern.securelevel > 0`, el kernel bloquea la eliminación o alteración de estas flags y devuelve `EPERM`.
* **Pregunta 2.2:** **B**
  * **Justificación:** Los módulos del kernel se ejecutan con privilegios completos de ring-0 dentro del espacio del kernel. Si se permitiera `kldload(8)` bajo `securelevel=1`, un atacante con privilegios de root podría cargar un módulo malicioso para sobrescribir las tablas de memoria del kernel, poner en cero `kern.securelevel` en RAM o desmarcar las flags de archivos. Por lo tanto, el kernel deshabilita `kldload` y `kldunload` cuando `securelevel >= 1`.

### Respuestas del Ejercicio 3

* **Pregunta 3.1:** **B**
  * **Justificación:** En `securelevel=1`, las operaciones de escritura en disco crudo están bloqueadas para los sistemas de archivos montados, pero el acceso directo a dispositivos de disco no montados aún puede representar un riesgo. `securelevel=2` prohíbe estrictamente las operaciones de escritura directa en **todos** los dispositivos de disco de bloques y caracteres, independientemente del estado de montaje, protegiendo las estructuras de disco crudo de ser sobrescritas por utilidades como `dd(1)`.
* **Pregunta 3.2:** **B**
  * **Justificación:** Bajo `securelevel=2`, los retrocesos de tiempo a través de `settimeofday(2)` o `clock_settime(2)` que superen 1 segundo están prohibidos para evitar que los atacantes invaliden archivos de registro con marca de tiempo o certificados de seguridad. Los ajustes graduales (slew adjustments) mediante `adjtime(2)` modulan la tasa de tics del reloj para corregir la desviación gradualmente sin retroceder el tiempo bruscamente, y están permitidos.

### Respuestas del Ejercicio 4

* **Pregunta 4.1:** **B**
  * **Justificación:** NetBSD refactorizó la verificación de privilegios del kernel en el marco Kernel Authorization (`kauth(9)`). Las políticas del nivel de seguridad del sistema están desacopladas en un modelo de seguridad intercambiable llamado `secmodel_securelevel(9)`, lo que permite a los desarrolladores reemplazar o aumentar los securelevels tradicionales de BSD con políticas personalizadas basadas en capacidades.
* **Pregunta 4.2:** **B**
  * **Justificación:** Al arrancar en modo de usuario único (`boot -s`), `init(8)` genera una shell root directa antes de iniciar `/etc/rc`. Debido a que los scripts de inicio no se han ejecutado para configurar `kern.securelevel` en niveles más altos, `securelevel` permanece en su valor predeterminado de inicio (`0` o `-1`), lo que permite operaciones de mantenimiento del superusuario como desmarcar las flags `schg`.

</details>