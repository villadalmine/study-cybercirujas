# LPI 702: Guía de estudio para la certificación BSD Specialist
## Tema 715.5: Realizar operaciones básicas de edición de archivos (Examen 702-100, Versión 1.0)
**Peso:** 3.34  
**Contexto del rol:** Principal Platform Architect & Senior SRE Level

---

### 1. Motivación en producción y problema arquitectónico

#### 1.1 Mantenimiento fuera de banda y operaciones en Single-User Mode
En entornos de producción BSD empresariales (FreeBSD, OpenBSD, NetBSD), los Site Reliability Engineers (SREs) y Platform Architects se encuentran frecuentemente con escenarios donde los hipervisores, nodos de almacenamiento que ejecutan ZFS y dispositivos de seguridad (como firewalls pfSense o HardenedBSD) pierden conectividad de red, sufren fallos durante el arranque debido a errores de sintaxis en archivos de configuración, o sufren corrupción en el sistema de archivos.

En estos escenarios de emergencia, la cadena de herramientas de gestión remota estándar (Ansible, SSH, puppet-agent) no está disponible. Los ingenieros deben conectarse a través de consolas serie fuera de banda (IPMI, iDRAC, consola serie de AWS o KVM) en **Single-User Mode**. 

```
+-------------------------------------------------------------------------+
|                       Out-of-Band Maintenance                           |
|                                                                         |
|  +------------------+    Serial / Console     +----------------------+  |
|  | SRE Workstation  |------------------------>| BSD System (Single   |  |
|  |                  |    (vt100 / ansi)       | User / Rescue ISO)   |  |
|  +------------------+                         +----------------------+  |
|                                                          |              |
|                                                          v              |
|                                               +----------------------+  |
|                                               | Minimal Base System  |  |
|                                               |  - Dynamic libs min. |  |
|                                               |  - /var/tmp mounted  |  |
|                                               |  - POSIX / BSD vi    |  |
|                                               +----------------------+  |
+-------------------------------------------------------------------------+
```

El Single-User Mode monta el sistema de archivos raíz (root filesystem), a menudo inicialmente en modo de solo lectura, con un entorno mínimo:
* Es posible que los paquetes de terceros (ubicados en `/usr/local/bin`, incluidos `vim`, `emacs` o `nano`) no estén montados o accesibles.
* Las capacidades de la terminal (`$TERM`) se establecen por defecto en especificaciones de respaldo como `vt100`, `ansi` o `dumb`.
* Es posible que las bibliotecas dinámicas compartidas fuera de `/lib` y `/usr/lib` no estén disponibles.

Bajo estas condiciones, las herramientas de edición de archivos estándar nativas del sistema base de BSD—principalmente BSD `vi` (tradicionalmente `nvi`, el reemplazo de new vi escrito por Keith Bostic)—se convierten en la herramienta principal para restaurar la funcionalidad del sistema.

#### 1.2 Mecánica del sistema: arquitectura de `nvi`, señales, TTY y recuperación de Swap
BSD `vi` (`nvi`) está diseñado como un editor pequeño, robusto y compatible con POSIX.2 integrado dentro de la distribución base. Comprender su funcionamiento de bajo nivel es esencial para prevenir la corrupción de estado durante cortes críticos:

1. **Modelo de ejecución modal:**
   * **Command Mode:** El modo operativo predeterminado. Las pulsaciones de teclas se interpretan como comandos de manipulación (movimiento del cursor, eliminación, yank/paste, cambio de modo).
   * **Insert Mode:** Las pulsaciones de teclas mutan directamente el buffer de la línea activa. Se ingresa mediante `i`, `a`, `o`, `I`, `A`, `O`, `R`, `c` o `s`. Se sale mediante `<ESC>`.
   * **Ex / Line Mode:** Se invoca con `:`, `/` o `?`. Interactúa directamente con el motor del editor de líneas subyacente (`ex`) para sustituciones globales, búsqueda por regex, comandos del sistema y operaciones de E/S de archivos.

2. **Mecánica del buffer y del archivo de Swap:**
   * Al abrir un archivo (`vi /etc/rc.conf`), `nvi` crea un archivo de recuperación temporal cifrado o plano en `/var/tmp/vi.recover/` (o directamente como un archivo oculto `.filename.swp` dependiendo del sabor de BSD).
   * El editor lee el archivo objetivo línea por línea en una estructura db(3) o B-tree en memoria. Las modificaciones se confirman en el buffer de recuperación antes de mostrarse en pantalla.
   * Si la sesión SSH se interrumpe o se recibe una señal de terminal (`SIGHUP`, `SIGTERM`), `nvi` captura la señal, sincroniza la base de datos de líneas en memoria a `/var/tmp/vi.recover/` y envía un correo electrónico de notificación a través de `sendmail` (si está configurado), permitiendo la restauración de la sesión mediante `vi -r`.

3. **TTY, señales y dimensionamiento de la terminal:**
   * **`SIGWINCH` (Window Size Change):** `nvi` escucha las señales de cambio de tamaño de ventana de la pseudoterminal (pty). En consolas serie limitadas donde `SIGWINCH` no se propaga, puede aparecer corrupción de texto en pantalla. Ejecutar `:redraw!` (o `Ctrl+L`) fuerza al renderizador de la terminal a limpiar y redibujar las líneas de la pantalla según las configuraciones actuales de termcap.
   * **`SIGINT` (Ctrl+C):** Aborta la entrada actual o comandos multilínea sin cerrar la sesión ni corromper el buffer de líneas.

4. **Bloqueo de archivos y anulación de Read-Only:**
   * Permisos de archivo (`-r--r--r--`) o el flag `uchg` (user immutable) en sistemas BSD bloquean las llamadas al sistema (syscalls) de escritura de archivos estándar (`open(2)` con `O_WRONLY`).
   * Al modificar un archivo de solo lectura perteneciente a root, `vi` bloquea `:w` con `Read-only file system` o `Permission denied`. Si el archivo es de solo lectura debido a los bits de modo de archivo estándar de UNIX (y el usuario es `root`), forzar la escritura mediante `:w!` anula los bits de modo de archivo alterando temporalmente los flags internos de E/S o forzando sincronizaciones en disco. Sin embargo, si el sistema de archivos subyacente está montado en `ro` (Read-Only), `:w!` falla en la capa VFS del kernel.

---

### 2. Comparaciones técnicas y matriz de balance (Trade-Off Matrix)

La siguiente tabla evalúa los editores de texto y las utilidades de edición de líneas disponibles de forma nativa o comúnmente utilizadas en sistemas BSD en arquitectura empresarial.

| Característica / Métrica | `nvi` (BSD vi Estándar) | `ee` (FreeBSD Easy Editor) | `vim` (Vi IMproved - Ports/Pkg) | `ed` / `ex` (Editor de líneas) | `sed` (Editor de flujo) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Inclusión en el sistema base** | Sí (FreeBSD, OpenBSD, NetBSD) | Sí (Solo FreeBSD) | No (Requiere `pkg install vim`) | Sí (Base POSIX BSD estándar) | Sí (Base POSIX BSD estándar) |
| **Huella del binario** | ~350 KB | ~80 KB | >30 MB (con libs compartidas) | ~60 KB | ~90 KB |
| **Requisito de dependencias** | Mínimo (`libc`, `libncurses`/`libtermlib`) | Mínimo (`libc`, `libncurses`) | Pesado (`libgettext`, `libiconv`, etc.) | `libc` vinculada estática/mínimamente | `libc` vinculada mínimamente |
| **Dependencia de TTY / `$TERM`** | Requiere termcap válido (`vt100`, `xterm`) | Requiere termcap básico | Requiere terminfo complejo | **Cero dependencia de TTY** (Pipe/stream puro) | **Cero dependencia de TTY** (Stream puro) |
| **Edición modal** | Sí (Command, Insert, Ex) | No (Sin modos, guiado por menús de diálogo) | Sí (Command, Insert, Visual, Ex) | Modal basado en líneas | No interactivo guiado por comandos |
| **Mecanismo de recuperación** | Del sistema `/var/tmp/vi.recover` (`vi -r`) | Ninguno (Guardado directo o prompt) | Archivos swap `.swp` (`vim -r`) | Archivos de respaldo (`.bak` si se pasa manualmente por pipe) | Edición *in-place* (`sed -i ''`) |
| **Macros y capacidad de scripting** | Scripts Ex (`vi -s script.ex`) | Baja / Solo interactivo | Alta (Vimscript, Lua, Python) | Alta (Scriptable por Shell / STDIN) | Alta (Reemplazo por flujo con Regex) |
| **Huella de memoria** | Baja (< 2 MB RSS) | Baja (< 1.5 MB RSS) | Media-Alta (> 15 MB RSS) | Ultra baja (< 500 KB RSS) | Ultra baja (< 500 KB RSS) |
| **Adecuación para rescate en Single-User** | **Óptima** (Herramienta principal) | Buena (Arreglos básicos en FreeBSD) | Deficiente (Puede fallar verificación de bibliotecas) | **Respaldos críticos** (TTY/arranque roto) | **Reparaciones automatizadas** |

---

### 3. Manifiestos completos de infraestructura y configuración

A continuación se presentan manifiestos de configuración e infraestructura sintácticamente válidos y completamente funcionales utilizados para estandarizar el entorno del editor `vi`, asegurar el acceso operativo de emergencia y gestionar configuraciones de rescate en plataformas BSD.

#### 3.1 Playbook de infraestructura de Ansible: Configuración del entorno estándar BSD para SRE
Este playbook configura los editores predeterminados a nivel de sistema (`/etc/profile`, `/root/.cshrc`) y despliega configuraciones explícitas `.nexrc` / `.exrc` para los usuarios root y SRE en nodos FreeBSD y OpenBSD.

```yaml
---
- name: Standardize BSD Base System Editor Environment & Session Recovery
  hosts: bsd_servers
  gather_facts: true
  become: true

  tasks:
    - name: Ensure /var/tmp/vi.recover directory exists with secure permissions
      ansible.builtin.file:
        path: /var/tmp/vi.recover
        state: directory
        owner: root
        group: wheel
        mode: '1777'

    - name: Configure system-wide default editor in /etc/profile
      ansible.builtin.blockinfile:
        path: /etc/profile
        create: true
        owner: root
        group: wheel
        mode: '0644'
        marker: "# {mark} ANSIBLE MANAGED BLOCK - SRE EDITOR CONFIG"
        block: |
          EDITOR=/usr/bin/vi
          VISUAL=/usr/bin/vi
          EXINIT="set autoindent number report=1 showmode"
          export EDITOR VISUAL EXINIT

    - name: Configure root shell environment for FreeBSD csh (/root/.cshrc)
      ansible.builtin.blockinfile:
        path: /root/.cshrc
        create: true
        owner: root
        group: wheel
        mode: '0600'
        marker: "# {mark} ANSIBLE MANAGED BLOCK - SRE CSH EDITOR CONFIG"
        block: |
          setenv EDITOR /usr/bin/vi
          setenv VISUAL /usr/bin/vi
          setenv EXINIT "set autoindent number report=1 showmode"

    - name: Deploy hardened /root/.nexrc for BSD nvi editor
      ansible.builtin.copy:
        dest: /root/.nexrc
        owner: root
        group: wheel
        mode: '0600'
        content: |
          " BSD nvi runtime configuration - SRE Hardened Setup
          set autoindent
          set number
          set report=1
          set showmode
          set lines=24
          set columns=80
          set flash
```

#### 3.2 Fragmentos completos de configuración del sistema (`/etc/rc.conf` y `/etc/pf.conf`)
Los siguientes manifiestos operativos de FreeBSD con sintaxis válida demuestran archivos de configuración de producción modificados con frecuencia durante cortes de emergencia utilizando `vi`.

##### `/etc/rc.conf` (Configuración de daemons del sistema base de FreeBSD)
```sh
# System Hostname and Core Networking
hostname="bsd-edge-node-01.production.internal"
ifconfig_vtnet0="inet 192.168.1.50 netmask 255.255.255.0"
defaultrouter="192.168.1.1"

# Security & Access Control
sshd_enable="YES"
syslogd_flags="-s -s"

# Firewall and Packet Filter Integration
pf_enable="YES"
pf_rules="/etc/pf.conf"
pflog_enable="YES"

# ZFS System Storage Daemon
zfs_enable="YES"

# Dump directory for kernel crash diagnostics
dumpdev="AUTO"
```

##### `/etc/pf.conf` (Conjunto de reglas de Packet Filter para OpenBSD / FreeBSD)
```pf
# Network Interface Definitions
ext_if = "vtnet0"

# Tables for Dynamic IP Filtering
table <bruteforce> persist

# Global Filtering Options
set skip on lo0
set block-policy drop

# Firewall Normalization Rules
scrub in on $ext_if all fragment reassemble

# Default Access Control Policies
block all
pass out quick on $ext_if keep state

# Inbound Management Access Rules
pass in quick on $ext_if proto tcp from 10.240.0.0/16 to $ext_if port 22 flags S/SA keep state \
    (max-src-conn 10, max-src-conn-rate 5/60, overload <bruteforce> flush global)
```

---

### 4. Comandos reales de CLI y registros de salida de terminal

Esta sección proporciona flujos de trabajo operativos reales paso a paso utilizando `vi` y utilidades de línea de bajo nivel durante escenarios de mantenimiento y recuperación del sistema en FreeBSD/OpenBSD.

#### 4.1 Ciclo de vida básico de edición de archivos y transiciones de modo en `vi`

```console
$ export TERM=vt100
$ vi /etc/rc.conf
```

Dentro de `vi`, los números de línea y el indicador de modo son visibles debido a la configuración de `number` y `showmode`:

```text
  1 hostname="bsd-edge-node-01.production.internal"
  2 ifconfig_vtnet0="inet 192.168.1.50 netmask 255.255.255.0"
  3 defaultrouter="192.168.1.1"
  4 sshd_enable="YES"
  5 pf_enable="NO"
~
~
~
"/etc/rc.conf": 5 lines, 168 characters
```

##### Secuencias de comandos operativos ejecutadas en Command Mode:
1. **Navegar a la línea 5:** Escriba `5G` o `:5<CR>`
2. **Cambiar el contenido de la línea:** Escriba `cw` sobre `"NO"` para cambiar la palabra, escriba `"YES"`, luego presione `<ESC>`.
3. **Añadir una línea al final del archivo:** Presione `G` para saltar a la última línea, luego presione `o` (abrir una nueva línea abajo):
   ```sh
   zfs_enable="YES"
   ```
   Presione `<ESC>` para volver a Command Mode.
4. **Guardar y salir:** Escriba `:wq` o presione `ZZ`.

```console
$ tail -n 2 /etc/rc.conf
pf_enable="YES"
zfs_enable="YES"
```

---

#### 4.2 Anulación de permisos en archivos de solo lectura (`:w!`)

Al intentar editar un archivo de solo lectura (por ejemplo, un archivo de configuración del sistema con modo de archivo `0444` perteneciente a root):

```console
# ls -l /etc/master.passwd
-r--r--r--  1 root  wheel  1420 Aug  6 18:22 /etc/master.passwd
# vi /etc/master.passwd
```

Dentro de `vi`, modificar una línea y emitir `:w` resulta en un error de escritura:

```text
:w
/etc/master.passwd: read-only file: file modification permission denied
```

##### Flujo de trabajo de resolución:
Para forzar a `vi` a anular el bit de modo de archivo de solo lectura (asumiendo que el usuario que ejecuta es `root` en un sistema de archivos de lectura y escritura):

```text
:w!
```

Respuesta del estado del terminal:
```text
/etc/master.passwd: 34 lines, 1452 characters written
```

Para salir después de guardar:
```text
:q
```

---

#### 4.3 Salir sin guardar cambios (`:q!`)

Cuando los cambios realizados en un archivo rompen la sintaxis o no son deseados, impida el guardado y fuerce la salida:

```console
# vi /etc/pf.conf
```

Modificaciones realizadas durante la sesión corrompen la estructura de reglas. Para descartar todas las ediciones de la memoria del buffer sin escribir en el disco:

```text
:q!
```

La salida de la terminal regresa limpiamente al prompt del shell:
```console
# echo $?
0
```

---

#### 4.4 Recuperación de sesión de emergencia mediante `vi -r` (Manejo de desconexiones inesperadas de la terminal)

Si una consola SSH se interrumpe inesperadamente mientras se edita un buffer sin guardar, o si el proceso recibe `SIGHUP`:

```console
# pkill -9 -f "vi /etc/pf.conf"
```

El sistema conserva el estado de edición pendiente en el directorio de recuperación.

##### Ejecución de comandos de diagnóstico y recuperación:

```console
# ls -la /var/tmp/vi.recover/
total 12
drwxrwxrwt  2 root  wheel  512 Aug  6 19:40 .
drwxrwxrwt  4 root  wheel  512 Aug  6 19:40 ..
-rw-------  1 root  wheel  2048 Aug  6 19:40 recover.vi.A01948

# vi -r
On Tuesday, Aug  6, 2026, at 19:40:12 EDT the user root was editing
the file /etc/pf.conf on host bsd-edge-node-01.production.internal.
There are saved modifications for this file.

# vi -r /etc/pf.conf
```

`nvi` abre el buffer de recuperación guardado desde `/var/tmp/vi.recover/`.

Dentro de `vi`:
1. Verifique los cambios recuperados.
2. Guarde explícitamente para escribir el buffer de regreso al destino real del sistema de archivos:
   ```text
   :w!
   ```
3. Salga de `vi`:
   ```text
   :q
   ```
4. Elimine el archivo de recuperación obsoleto:
   ```console
   # rm /var/tmp/vi.recover/recover.vi.A01948
   ```

---

#### 4.5 Edición de líneas fuera de banda de emergencia mediante `ed` (Rescate no interactivo / TTY roto)

Si `$TERM` no es válido (`dumb`) o el controlador de la terminal está roto durante el arranque en Single-User, los editores orientados a pantalla (`vi`, `ee`) se negarán a ejecutarse:

```console
# export TERM=dumb
# vi /etc/rc.conf
vi: Screen line length too small
```

##### Rescate automatizado / en modo de línea utilizando POSIX `ed`:

```console
# ed /etc/rc.conf
174
1,$p
hostname="bsd-edge-node-01.production.internal"
ifconfig_vtnet0="inet 192.168.1.50 netmask 255.255.255.0"
defaultrouter="192.168.1.1"
sshd_enable="YES"
pf_enable="NO"
/pf_enable/
pf_enable="NO"
s/NO/YES/
p
pf_enable="YES"
w
175
q
# grep pf_enable /etc/rc.conf
pf_enable="YES"
```

---

### 5. Guía de verificación y diagnóstico de fallos

#### 5.1 Diagramas de flujo de diagnóstico: Solución de problemas en fallos del editor en BSD

```
                            [ File Editing Failure ]
                                       |
                                       v
                       Is the TTY correctly initialized?
                                       |
                  +--------------------+--------------------+
                  | YES                                     | NO
                  v                                         v
       Check Terminal Definition                    Fix Environment Variables:
       $TERM value valid in termcap?                $ export TERM=vt100
                  |                                 $ stty rows 24 cols 80
        +---------+---------+                               |
        | YES               | NO                            v
        v                   v                       Does editor launch?
Check File Status    Set TERM=ansi or vt100          +------+------+
                                                     | YES         | NO
                                                     v             v
                                                 Use `vi`    Fallback to `ed`
```

```
                        [ Disk Write Failure (:w / :w!) ]
                                       |
                                       v
                        Is Filesystem Mounted Read-Only?
                                       |
                  +--------------------+--------------------+
                  | YES                                     | NO
                  v                                         v
       Check mount status:                          Check File Permission/Flags:
       $ mount -p | grep ' / '                       $ ls -lo <filename>
                  |                                         |
                  v                                 +-------+-------+
       Remount root read-write:                     |               |
       # mount -u -w /                              v               v
                  |                         `uchg` flag set?    Mode 0444?
                  v                         $ chflags nouchg       |
          Retry `:w` in `vi`                        |              v
                                                    v          Use `:w!`
                                                Use `:w`       to override
```

---

#### 5.2 Errores comunes en producción y protocolos de remediación

##### Problema 1: `vi: Unknown terminal type` o corrupción en la visualización de la terminal
* **Síntoma:** El posicionamiento del cursor falla, las teclas de flecha muestran caracteres no válidos (`^[[A`), o `vi` se anula al iniciar.
* **Causa raíz:** La entrada de la base de datos para `$TERM` no existe en `/usr/share/misc/termcap` (FreeBSD) o `/usr/share/misc/terminfo` (OpenBSD).
* **Protocolo de remediación:**
  ```console
  # export TERM=vt100
  # stty sane
  # stty rows 24 columns 80
  # vi /etc/rc.conf
  ```

##### Problema 2: Error `Read-only file system` al intentar escribir
* **Síntoma:** `vi` devuelve `Operation not permitted` o `Read-only file system` incluso al usar `:w!`.
* **Causa raíz:** El VFS del kernel ha montado el sistema de archivos de destino como solo lectura (`ro`), algo estándar durante el arranque en Single-User Mode de FreeBSD o un fallo al importar el pool de ZFS.
* **Protocolo de remediación:**
  1. Verifique el estado del montaje:
     ```console
     # mount -u -w /
     ```
  2. Para sistemas de archivos raíz ZFS:
     ```console
     # zfs set readonly=off zroot/ROOT/default
     ```
  3. Reanude la operación de edición en `vi` y ejecute `:w`.

##### Problema 3: Archivo bloqueado por flags de archivo de BSD (`uchg` / `schg`)
* **Síntoma:** Ejecutar `:w!` como `root` produce `Operation not permitted`.
* **Causa raíz:** El archivo tiene habilitado el flag de inmutabilidad del sistema o de usuario (`schg` o `uchg`).
* **Protocolo de remediación:**
  1. Inspeccione los flags:
     ```console
     # ls -lo /etc/rc.conf
     -rw-r--r--  1 root  wheel  uchg 175 Aug  6 19:00 /etc/rc.conf
     ```
  2. Borre el flag de inmutabilidad:
     ```console
     # chflags nouchg /etc/rc.conf
     ```
  3. Edite el archivo con `vi`, guarde (`:wq`) y vuelva a aplicar el flag si la política de seguridad lo requiere:
     ```console
     # chflags uchg /etc/rc.conf
     ```

---

### 6. Referencias

* **Linux Professional Institute BSD Specialist Overview & Objectives (Exam 702-100):**  
  [https://www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)

* **FreeBSD Manual Pages - `nvi` (Text Editor):**  
  [https://man.freebsd.org/cgi/man.cgi?query=nvi](https://man.freebsd.org/cgi/man.cgi?query=nvi)

* **FreeBSD Manual Pages - `ee` (Easy Editor):**  
  [https://man.freebsd.org/cgi/man.cgi?query=ee](https://man.freebsd.org/cgi/man.cgi?query=ee)

* **OpenBSD Manual Pages - `vi` / `ex` System Editor:**  
  [https://man.openbsd.org/vi](https://man.openbsd.org/vi)

* **NetBSD Manual Pages - `ed` (Line-Oriented Text Editor):**  
  [https://man.netbsd.org/ed.1](https://man.netbsd.org/ed.1)

* **IEEE Std 1003.1 POSIX.1-2017 Specification - `vi` Utility:**  
  [https://pubs.opengroup.org/onlinepubs/9699919799/utilities/vi.html](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/vi.html)