# LPIC-1 · Tema 104.7 — Encontrar archivos del sistema y ubicar archivos en el lugar correcto

**Examen:** 101-500 · **Peso:** 3.12 · **Versión:** 5.0
**Archivos, términos y utilidades clave:** `find`, `locate`, `updatedb`, `whereis`, `which`, `type`, `/etc/updatedb.conf`
**Perfil de profundidad:** Principal Platform Architect / SRE — diseño del contrato del sistema de archivos, rendimiento del plano de búsqueda, forense a escala de flota.

---

## 1. El problema de producción: un sistema de archivos es una API, no un árbol de carpetas

Toda automatización que tenés a cargo — gestores de paquetes, gestión de configuración, construcción de imágenes de contenedor, selectores de backup, políticas de SELinux, sandboxing de systemd, agentes de envío de logs, escáneres de cumplimiento — codifica supuestos sobre *dónde viven las cosas*. Cuando esos supuestos divergen de la realidad, la falla nunca es un crash limpio. Es una clase de incidentes lenta y silenciosa:

| Modo de falla | Disparador del mundo real | Radio de impacto |
|---|---|---|
| El backup restaura una aplicación vacía | El proveedor instaló el estado bajo `/opt/app/data`; la política de backup selecciona `/var` y `/home` | Pérdida total de datos, descubierta al momento de restaurar |
| `/` se llena a las 03:00 | La aplicación escribe logs en `/var/lib/app/` en vez de `/var/log/app/`; logrotate nunca hace match | Nodo `NotReady`, tormenta de desalojos del kubelet |
| Configuración borrada por una actualización | El paquete entrega valores por defecto en `/usr/share/app/config.yaml` y el operador editó *ese* archivo en lugar de `/etc/app/config.yaml` | Regresión silenciosa a los valores por defecto en toda la flota |
| Un despliegue con `/usr` de solo lectura rompe un demonio | El demonio escribe un socket de runtime en `/usr/lib/app/run.sock` | Los hosts inmutables/OSTree rechazan la carga de trabajo |
| Escalada de privilegios | Un binario SUID depositado en `/usr/local/bin` por una instalación ad-hoc; nadie sabe que existe | Hallazgo de nivel CVE en la auditoría |
| `which` dice que el binario está bien, la shell ejecuta otro | La caché de hash de comandos de bash conserva la ruta previa a la actualización | "Funciona en mi terminal, falla en el archivo de unidad" |
| `locate` devuelve rutas que ya no existen | Timer de `updatedb` deshabilitado en imágenes endurecidas | El equipo de guardia persigue fantasmas durante el triage |

El **Filesystem Hierarchy Standard (FHS)** es el contrato que vuelve seguro sostener esos supuestos. `find`, `locate`, `whereis`, `which` y `type` son el plano de consulta sobre ese contrato — y cada uno consulta una *fuente de datos distinta*, con distinta frescura, costo y modelo de confianza. Confundir las fuentes de datos es donde los ingenieros pierden horas.

El modelo mental más importante de este tema:

```
type / command -v  →  asks the *shell's own* execution logic       (authoritative for "what will run")
which              →  asks $PATH via an *external program*         (blind to aliases, functions, builtins)
whereis            →  asks compiled-in path lists + $PATH/$MANPATH (binaries, sources, man pages)
locate             →  asks a *precomputed database* on disk        (fast, stale, whole-filesystem)
find               →  asks the *live filesystem*                   (slow, exact, arbitrarily expressive)
```

Respondé la pregunta con la herramienta más barata que siga siendo *correcta para la pregunta formulada*. Esa frase es todo el tema.

---

## 2. FHS 3.0 — el contrato

FHS 3.0 se publicó el 2015-06-03 y lo mantiene la Linux Foundation. Es normativo para las distribuciones (tanto la Debian Policy como las Fedora Packaging Guidelines se atan a él), que es exactamente por lo que vale la pena memorizarlo: es la razón por la que tu tooling puede hardcodear rutas.

### 2.1 Los dos ejes ortogonales

FHS clasifica cada directorio a lo largo de dos ejes. Esta es la parte que preguntan los exámenes y la parte que los arquitectos usan de verdad al diseñar la distribución de montajes.

* **Compartible vs no compartible** — ¿se puede montar este dato en solo lectura desde un servidor central y consumirlo desde varios hosts, o está atado a una máquina específica?
* **Estático vs variable** — ¿cambia solo cuando un administrador instala o actualiza software, o cambia durante la operación normal?

| | **Compartible** | **No compartible** |
|---|---|---|
| **Estático** | `/usr`, `/opt` | `/etc`, `/boot` |
| **Variable** | `/var/mail`, `/var/spool/news` | `/var/log`, `/var/lock`, `/var/run` (hoy `/run`) |

Consecuencias de diseño que deberías poder enunciar bajo interrogatorio:

* `/usr` estático + compartible ⇒ puede montarse en **solo lectura**, incluirse en snapshots junto con la imagen del SO y entregarse como un commit de OSTree/`composefs`. Cualquier cosa que escriba en `/usr` en tiempo de ejecución es un bug.
* `/etc` estático + no compartible ⇒ es la identidad del host. Es lo que posee la gestión de configuración, lo que auditan `rpm -Va` / `debsums`, y lo que **nunca** debe contener binarios (FHS es explícito: *"No binaries may be located under /etc"*).
* `/var` variable ⇒ es el único lugar donde un demonio bien comportado persiste estado mutable, y por eso recibe su propio sistema de archivos en todo build serio de nodo.

### 2.2 Referencia de la jerarquía raíz

| Ruta | Estado en FHS | Contenido | ¿Debe estar en `/` al arrancar? | Notas para producción |
|---|---|---|---|---|
| `/bin` | requerido | Binarios de comandos de usuario esenciales | Sí | Fusionado en `/usr/bin` en distros modernas |
| `/boot` | requerido | Kernel, initramfs, bootloader | Partición propia, montada temprano | Suele ser chica; la rotación de kernels la llena |
| `/dev` | requerido | Nodos de dispositivo | Sí (`devtmpfs`) | Poblado por el kernel + udev |
| `/etc` | requerido | Configuración estática específica del host | Sí | **Sin binarios.** No se impone ningún subdirectorio salvo `/etc/opt`, `/etc/X11`, `/etc/sgml`, `/etc/xml` |
| `/home` | opcional | Directorios personales de usuarios | No | Frecuentemente NFS/autofs; podalo de `updatedb` |
| `/lib`, `/lib64` | requerido | Bibliotecas compartidas esenciales + módulos del kernel | Sí | `/lib/modules/$(uname -r)` |
| `/media` | requerido | Puntos de montaje para medios **removibles** | No | udisks/GNOME crean acá directorios por dispositivo |
| `/mnt` | requerido | Punto de montaje temporal para el **administrador** | No | Nunca usado por paquetes |
| `/opt` | requerido | Paquetes de software **de terceros** | No | Un subárbol por proveedor/paquete |
| `/root` | opcional | Directorio personal de `root` | Sí (recomendado) | Debe estar en `/` para que funcione el modo monousuario |
| `/run` | requerido (FHS 3.0) | Datos variables de runtime, limpiados en el arranque | `tmpfs`, montado temprano | Reemplaza a `/var/run` y `/var/lock` |
| `/sbin` | requerido | Binarios **de sistema** esenciales | Sí | Fusionado en `/usr/sbin` en distros modernas |
| `/srv` | requerido | Datos **servidos por este sistema** | No | p. ej. `/srv/www`, `/srv/ftp`, `/srv/git` |
| `/tmp` | requerido | Archivos temporales | Sí | **Puede limpiarse al reiniciar** — normalmente `tmpfs` |
| `/usr` | requerido | Segunda jerarquía — compartible, solo lectura | Montable más tarde | Ver §2.3 |
| `/var` | requerido | Datos variables | Sí (o temprano) | Sistema de archivos propio en nodos de producción |
| `/proc` | anexo Linux | FS virtual de procesos/kernel | Sí | `procfs` |
| `/sys` | anexo Linux | FS virtual de objetos del kernel | Sí | `sysfs` |

**Dentro de `/usr`:**

| Ruta | Contenido |
|---|---|
| `/usr/bin` | La ubicación principal de los comandos de usuario |
| `/usr/sbin` | Binarios de administración del sistema no esenciales |
| `/usr/lib`, `/usr/lib64`, `/usr/lib/<arch-triplet>` | Bibliotecas y binarios internos no pensados para invocación directa |
| `/usr/libexec` | Binarios auxiliares internos (FHS 3.0 lo permite formalmente) |
| `/usr/share` | Datos **independientes de la arquitectura**: páginas de manual, documentación, iconos, locale, `zoneinfo` |
| `/usr/include` | Archivos de cabecera de C |
| `/usr/src` | Código fuente (p. ej. cabeceras del kernel) |
| `/usr/local` | Jerarquía terciaria para software **compilado/instalado localmente** |

**Dentro de `/var`:**

| Ruta | Semántica | ¿Sobrevive al reinicio? | ¿Seguro de borrar? |
|---|---|---|---|
| `/var/log` | Archivos de log | Sí | Solo vía rotación |
| `/var/lib` | **Estado persistente de aplicación** (bases de datos, BD de dpkg/rpm) | Sí | **No — estos son tus datos** |
| `/var/cache` | Datos cacheados regenerables | Sí | **Sí** — deben ser reconstruibles |
| `/var/spool` | Trabajo encolado a la espera de procesamiento (`cron`, `cups`, `mail`) | Sí | No — se pierde el trabajo pendiente |
| `/var/tmp` | Archivos temporales **preservados entre reinicios** | Sí | Con política por antigüedad |
| `/var/opt` | Datos variables de paquetes de `/opt` | Sí | No |
| `/var/local` | Datos variables de programas de `/usr/local` | Sí | No |
| `/var/lock` | Archivos de bloqueo (ahora un enlace simbólico a `/run/lock`) | No | N/A |
| `/var/run` | Datos de runtime (ahora un enlace simbólico a `/run`) | No | N/A |

La distinción entre `/var/cache` y `/var/lib` es una decisión real de producción: todo lo que esté bajo `/var/cache` debería poder borrarse con `rm -rf` sin riesgo durante un incidente de disco lleno. Si tu aplicación no sobrevive a eso, no pertenece ahí.

### 2.3 El merge de `/usr` — por qué `/bin` ahora es un enlace simbólico

Fedora ejecutó `UsrMove` en Fedora 17 (2012); Debian completó la transición en Debian 12 "bookworm" (solo merged-`/usr`). En un sistema fusionado:

```
$ ls -ld /bin /sbin /lib /lib64 /usr/bin
lrwxrwxrwx.  1 root root    7 Jan 15  2026 /bin -> usr/bin
lrwxrwxrwx.  1 root root    9 Jan 15  2026 /lib -> usr/lib
lrwxrwxrwx.  1 root root   11 Jan 15  2026 /lib64 -> usr/lib64
lrwxrwxrwx.  1 root root    8 Jan 15  2026 /sbin -> usr/sbin
dr-xr-xr-x. 2 root root 61440 Aug 21 09:12 /usr/bin
```

Ganancia arquitectónica: el sistema operativo *entero* se vuelve un único subárbol (`/usr`) que es estático, compartible y, por lo tanto, intercambiable atómicamente, verificable por hash y montable en solo lectura. Ese es el sustrato de `rpm-ostree`, Flatcar, Bottlerocket y todo SO de nodo inmutable del ecosistema CNCF.

Consecuencias operativas que tenés que manejar:

* `find / -name foo` reportará **ambos** `/bin/foo` y `/usr/bin/foo` a menos que manejes el enlace simbólico — en realidad reportará solo `/usr/bin/foo`, porque `find` **no** sigue enlaces simbólicos por defecto y `/bin` es un enlace simbólico, no un directorio. `find /bin -name foo` no devuelve nada sin `-H` o `-L`. Esto hace tropezar a la gente constantemente.
* Distinguir `/bin` de `/usr/bin` en empaquetado ya no tiene sentido; distinguir `/usr` de `/usr/local` y `/opt` importa más que nunca.

```
$ find /bin -maxdepth 1 -name 'ls'
$ find -H /bin -maxdepth 1 -name 'ls'
/bin/ls
$ find -L /bin -maxdepth 1 -name 'ls'
/bin/ls
```

`-H` sigue enlaces simbólicos **solo para los argumentos de la línea de comandos**; `-L` los sigue en todos lados; `-P` (el valor por defecto) nunca los sigue.

### 2.4 ¿Dónde pongo *yo* el software? `/usr` vs `/usr/local` vs `/opt` vs `/srv`

Esta es la decisión que un arquitecto toma una vez por plataforma y luego hace cumplir en CI. Equivocarse significa que las actualizaciones de paquetes pisotean tus archivos o que tu gestión de configuración pelea con el gestor de paquetes para siempre.

| Destino | Dueño | Ubicación de la configuración | Datos variables | Comportamiento ante actualización | Usalo cuando |
|---|---|---|---|---|---|
| `/usr/bin`, `/usr/lib` | **Solo el gestor de paquetes de la distribución** | `/etc/<pkg>` | `/var/lib/<pkg>` | Sobrescrito por `dnf`/`apt` | Estás construyendo un paquete de distribución |
| `/usr/local/{bin,lib,share,etc}` | **Administrador local**, destino por defecto de `make install` | `/usr/local/etc` (FHS) o `/etc` por convención | `/var/local` | Nunca tocado por la distro | Software compilado desde fuente en este host |
| `/opt/<vendor-or-package>` | **Proveedor externo**, autocontenido | `/etc/opt/<pkg>` | `/var/opt/<pkg>` | Instalador propio del proveedor | Bundles de binarios entregados, agentes comerciales |
| `/srv/<service>` | **Datos del sitio servidos hacia afuera** | n/a | n/a | n/a | Raíces web, repositorios git, árboles FTP |

La precedencia en `$PATH` es lo que hace funcionar a `/usr/local`: en prácticamente toda distro `/usr/local/bin` precede a `/usr/bin`, así que un binario instalado localmente ensombrece al empaquetado **sin** tocarlo. Eso es una funcionalidad y un peligro — ver §3.4.

FHS es explícito sobre `/opt`: un paquete `foo` usa `/opt/foo` para archivos estáticos, `/etc/opt/foo` para configuración y `/var/opt/foo` para datos variables. Los proveedores que desparraman en `/opt/foo/etc` y `/opt/foo/logs` no cumplen, y lo vas a pagar la primera vez que montes `/opt` en solo lectura.

### 2.5 `/tmp`, `/var/tmp`, y por qué ninguno es tu espacio de trabajo

| | `/tmp` | `/var/tmp` | `/run` | `$XDG_RUNTIME_DIR` |
|---|---|---|---|---|
| Almacenamiento subyacente | normalmente `tmpfs` (RAM) | disco | `tmpfs` | `tmpfs` (`/run/user/<uid>`) |
| Sobrevive al reinicio | **No** | **Sí** | No | No |
| Limpiado por | `systemd-tmpfiles`, arranque | política de `tmpfiles` por antigüedad | arranque | cierre de sesión |
| Límite de tamaño | a menudo 50% de la RAM | tamaño del sistema de archivos | 10% de la RAM | 10% de la RAM |
| Uso correcto | corta vida, pequeño | intermedios grandes, trabajo reanudable | sockets, archivos PID | sockets por usuario |

Escribir un intermedio de 40 GiB en un `/tmp` respaldado por `tmpfs` es un incidente de falta de memoria, no de espacio en disco. Verificá antes de suponer:

```
$ findmnt -no FSTYPE,SIZE,USE% /tmp /var/tmp
tmpfs  7.8G  3%
ext4   196G 41%
```

La **XDG Base Directory Specification** es el complemento en espacio de usuario del FHS; las aplicaciones modernas deberían honrarla en vez de volcar dotfiles en `$HOME`:

| Variable | Valor por defecto | Análogo en FHS |
|---|---|---|
| `XDG_CONFIG_HOME` | `~/.config` | `/etc` |
| `XDG_DATA_HOME` | `~/.local/share` | `/var/lib` + `/usr/share` |
| `XDG_STATE_HOME` | `~/.local/state` | `/var/lib` |
| `XDG_CACHE_HOME` | `~/.cache` | `/var/cache` |
| `XDG_RUNTIME_DIR` | `/run/user/$UID` | `/run` |

### 2.6 Hacer cumplir FHS mecánicamente con systemd

No confíes en que el demonio se porte bien. Declará los directorios en la unidad y dejá que systemd los cree con el dueño, modo y etiqueta SELinux correctos — y, críticamente, dejá que `ProtectSystem=strict` haga que toda *otra* ruta sea de solo lectura, para que un proceso que se porta mal falle ruidosamente en vez de escribir silenciosamente en `/usr`.

**`/etc/systemd/system/telemetry-agent.service`**

```ini
[Unit]
Description=Telemetry Agent (FHS-compliant layout)
Documentation=https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=telemetry
Group=telemetry
ExecStart=/opt/telemetry-agent/bin/agent --config /etc/opt/telemetry-agent/agent.yaml

# --- FHS-mapped directories, created and labelled by systemd ---
# /etc/telemetry-agent          0750 telemetry:telemetry
ConfigurationDirectory=telemetry-agent
ConfigurationDirectoryMode=0750
# /var/lib/telemetry-agent      persistent state, survives restarts and reboots
StateDirectory=telemetry-agent
StateDirectoryMode=0700
# /var/cache/telemetry-agent    regenerable; safe to purge under disk pressure
CacheDirectory=telemetry-agent
CacheDirectoryMode=0750
# /var/log/telemetry-agent      only if the daemon insists on its own files
LogsDirectory=telemetry-agent
LogsDirectoryMode=0750
# /run/telemetry-agent          sockets and PID file; cleared at boot
RuntimeDirectory=telemetry-agent
RuntimeDirectoryMode=0755
RuntimeDirectoryPreserve=no

# --- Everything else becomes read-only or invisible ---
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
ProtectProc=invisible
ProcSubset=pid
RestrictSUIDSGID=yes
NoNewPrivileges=yes
RestrictNamespaces=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
CapabilityBoundingSet=
AmbientCapabilities=

Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
```

Verificá que el sandbox efectivamente se sostenga — este es el chequeo que convierte una afirmación en un hecho:

```
$ sudo systemd-analyze security telemetry-agent.service | tail -5
  ✓ RestrictNamespaces=~CLONE_NEWNET                                          0.1
  ✓ RestrictSUIDSGID=                                                         0.2
  ✓ SystemCallFilter=~@privileged                                             0.2

→ Overall exposure level for telemetry-agent.service: 1.4 SAFE 😀
```

```
$ sudo -u telemetry touch /usr/lib/telemetry-agent/probe
touch: cannot touch '/usr/lib/telemetry-agent/probe': Read-only file system
```

**`/usr/lib/tmpfiles.d/telemetry-agent.conf`** — para rutas que las directivas por unidad de systemd no pueden expresar (spools compartidos, limpieza por antigüedad):

```
#Type Path                              Mode UID        GID        Age  Argument
d     /var/spool/telemetry-agent        0770 telemetry  telemetry  -    -
d     /var/spool/telemetry-agent/inbox  0770 telemetry  telemetry  30d  -
d     /var/tmp/telemetry-agent          0700 telemetry  telemetry  7d   -
L     /var/opt/telemetry-agent/state    -    -          -          -    /var/lib/telemetry-agent
z     /etc/opt/telemetry-agent/agent.yaml 0640 root     telemetry  -    -
```

```
$ sudo systemd-tmpfiles --create /usr/lib/tmpfiles.d/telemetry-agent.conf
$ ls -ld /var/spool/telemetry-agent /var/spool/telemetry-agent/inbox
drwxrws---. 2 telemetry telemetry 4096 Aug 26 11:02 /var/spool/telemetry-agent
drwxrws---. 2 telemetry telemetry 4096 Aug 26 11:02 /var/spool/telemetry-agent/inbox
```

`systemd-path` te permite consultar la jerarquía resuelta programáticamente en vez de hardcodear:

```
$ systemd-path | head -12
temporary: /tmp
temporary-large: /var/tmp
system-binaries: /usr/bin
system-configuration: /etc
system-runtime: /run
system-state-cache: /var/cache
system-state-logs: /var/log
system-state-private: /var/lib
system-state-spool: /var/spool
system-shared: /usr/share
user-runtime: /run/user/1000
user-configuration: /home/sre/.config
```

### 2.7 Ansible: desplegar un bundle de proveedor de forma correcta según FHS

**`roles/telemetry_agent/tasks/main.yml`**

```yaml
---
- name: Ensure the service account exists
  ansible.builtin.user:
    name: telemetry
    system: true
    shell: /usr/sbin/nologin
    home: /var/lib/telemetry-agent
    create_home: false
    comment: "Telemetry agent service account"

- name: Create the FHS-compliant directory layout
  ansible.builtin.file:
    path: "{{ item.path }}"
    state: directory
    owner: "{{ item.owner | default('root') }}"
    group: "{{ item.group | default('root') }}"
    mode: "{{ item.mode }}"
    setype: "{{ item.setype | default(omit) }}"
  loop:
    # Static, shareable, read-only at runtime: the program itself.
    - { path: /opt/telemetry-agent,         mode: "0755" }
    - { path: /opt/telemetry-agent/bin,     mode: "0755" }
    - { path: /opt/telemetry-agent/lib,     mode: "0755" }
    # Static, unshareable: host-specific configuration.
    - { path: /etc/opt/telemetry-agent,     mode: "0750", group: telemetry, setype: etc_t }
    # Variable, unshareable: state that must survive an upgrade.
    - { path: /var/opt/telemetry-agent,     mode: "0700", owner: telemetry, group: telemetry, setype: var_lib_t }
    # Variable, regenerable: safe to purge under disk pressure.
    - { path: /var/cache/telemetry-agent,   mode: "0750", owner: telemetry, group: telemetry, setype: var_t }
    # Variable: logs, rotated externally.
    - { path: /var/log/telemetry-agent,     mode: "0750", owner: telemetry, group: telemetry, setype: var_log_t }

- name: Unpack the vendor bundle into /opt
  ansible.builtin.unarchive:
    src: "telemetry-agent-{{ agent_version }}.tar.gz"
    dest: /opt/telemetry-agent
    owner: root
    group: root
    extra_opts: ["--strip-components=1", "--no-same-owner"]
    creates: "/opt/telemetry-agent/bin/agent"
  notify: restart telemetry-agent

- name: Expose the entry point on $PATH without polluting /usr/bin
  ansible.builtin.file:
    src: /opt/telemetry-agent/bin/agent
    dest: /usr/local/bin/telemetry-agent
    state: link
    force: true

- name: Render host-specific configuration under /etc/opt
  ansible.builtin.template:
    src: agent.yaml.j2
    dest: /etc/opt/telemetry-agent/agent.yaml
    owner: root
    group: telemetry
    mode: "0640"
    validate: "/opt/telemetry-agent/bin/agent --config %s --check-config"
  notify: restart telemetry-agent

- name: Install the hardened unit file
  ansible.builtin.copy:
    src: telemetry-agent.service
    dest: /etc/systemd/system/telemetry-agent.service
    owner: root
    group: root
    mode: "0644"
  notify:
    - reload systemd
    - restart telemetry-agent

- name: Install log rotation policy
  ansible.builtin.copy:
    dest: /etc/logrotate.d/telemetry-agent
    owner: root
    group: root
    mode: "0644"
    content: |
      /var/log/telemetry-agent/*.log {
          daily
          rotate 14
          compress
          delaycompress
          missingok
          notifempty
          create 0640 telemetry telemetry
          sharedscripts
          postrotate
              /usr/bin/systemctl kill -s HUP telemetry-agent.service 2>/dev/null || true
          endscript
      }

- name: Exclude the agent cache from the locate database
  ansible.builtin.lineinfile:
    path: /etc/updatedb.conf
    regexp: '^PRUNEPATHS\s*='
    line: 'PRUNEPATHS = "/afs /media /mnt /net /sfs /tmp /udev /var/cache/telemetry-agent /var/spool/cups /var/spool/squid /var/tmp"'
    backup: true

- name: Assert nothing was written outside the declared layout
  ansible.builtin.command:
    argv:
      - find
      - /opt/telemetry-agent
      - -xdev
      - -newer
      - /etc/opt/telemetry-agent/agent.yaml
      - -type
      - f
      - -print
  register: fhs_drift
  changed_when: false
  failed_when: fhs_drift.stdout | length > 0
```

**`roles/telemetry_agent/handlers/main.yml`**

```yaml
---
- name: reload systemd
  ansible.builtin.systemd_service:
    daemon_reload: true

- name: restart telemetry-agent
  ansible.builtin.systemd_service:
    name: telemetry-agent.service
    state: restarted
    enabled: true
```

---

## 3. Localizar ejecutables: `type`, `command -v`, `which`, `whereis`, `hash`

### 3.1 Cómo resuelve bash realmente un nombre de comando

Orden de resolución (este es el orden que reporta `type -a`, y la razón por la que `which` puede mentir):

1. **Alias** — expandidos antes del parseo, solo en shells interactivas salvo `shopt -s expand_aliases`
2. **Palabras reservadas de la shell** — `if`, `for`, `while`, `function`, `[[`, `time`, `!`
3. **Funciones de shell**
4. **Builtins de la shell** — `cd`, `echo`, `test`, `kill`, `pwd`, `type`, `hash`
5. **Búsqueda en `$PATH`**, memoizada en la **tabla de hash** de la shell

```
$ type -a echo
echo is a shell builtin
echo is /usr/bin/echo

$ type -a ls
ls is aliased to `ls --color=auto'
ls is /usr/bin/ls

$ type -a [
[ is a shell builtin
[ is /usr/bin/[

$ type -a if
if is a shell keyword

$ type -t if
keyword
$ type -t ls
alias
$ type -t cd
builtin
$ type -t find
file

$ type -P ls        # force the PATH lookup, ignore alias/builtin/function
/usr/bin/ls
```

`-t` imprime una única palabra parseable por máquina (`alias`, `keyword`, `function`, `builtin`, `file`) y es lo correcto sobre lo que ramificar en un script.

### 3.2 La tabla comparativa que tenés que poder reproducir

| Herramienta | Tipo | Ve alias | Ve funciones | Ve builtins | Ve keywords | Busca en | POSIX | Código de salida confiable |
|---|---|---|---|---|---|---|---|---|
| `type` | builtin de bash | ✅ | ✅ | ✅ | ✅ | `$PATH` + hash | `type` sí, `-a/-t/-P` son de bash | ✅ |
| `command -v` | builtin POSIX | ✅ | ✅ | ✅ | ✅ | `$PATH` | ✅ | ✅ |
| `which` | **binario externo** | ❌ (salvo que esté envuelto) | ❌ | ❌ | ❌ | solo `$PATH` | ❌ (no está en POSIX) | depende de la distro |
| `whereis` | binario externo | ❌ | ❌ | ❌ | ❌ | directorios compilados + `$PATH`/`$MANPATH` | ❌ | ✅ |
| `hash` | builtin de bash | ❌ | ❌ | ❌ | ❌ | muestra la caché | `hash` sí | ✅ |

**Regla para scripts: usá `command -v`.** Es POSIX, es un builtin (sin `fork`), respeta el propio orden de resolución de la shell y su estado de salida está definido.

```sh
#!/bin/sh
# Correct portable dependency check.
for dep in jq curl find; do
    command -v "$dep" >/dev/null 2>&1 || {
        printf 'fatal: required command not found: %s\n' "$dep" >&2
        exit 127
    }
done
```

La versión de ese chequeo con `which` está rota de tres maneras: hace fork de un proceso por dependencia, su estado de salida no es portable (algunas implementaciones devuelven 0 incluso al fallar), y no puede ver una función de shell que legítimamente provee el comando.

### 3.3 `which` — importa cuál es en tu distro

`which` no es un solo programa. Sabé cuál tenés:

```
$ ls -l /usr/bin/which
-rwxr-xr-x. 1 root root 30536 Jul  9 14:31 /usr/bin/which

$ which --version | head -1
GNU which v2.21, Copyright (C) 1999 - 2008 Carlo Wood.
```

* **GNU which** (RHEL/Fedora históricamente): soporta `-a` (todas las coincidencias), `--read-alias`, `--read-functions`, `--skip-dot`, `--skip-tilde`. Fedora solía entregar `/etc/profile.d/which2.sh` definiendo un alias que canalizaba `alias; declare -f` hacia él para que *pareciera* conocer los alias; ese wrapper fue eliminado en versiones recientes.
* **`which` de debianutils** (Debian/Ubuntu): un script de shell POSIX. Desde debianutils 5.x emite un aviso de obsolescencia, y Debian lo movió a un costado como `which.debianutils`:

```
$ which python3
which: this version of `which' is deprecated; use `command -v' in scripts instead.
/usr/bin/python3
```

* **`which` de busybox** (Alpine, contenedores minimalistas): sin `-a`, sin soporte de alias.

`-a` es la opción que importa operativamente, porque expone el ensombrecimiento:

```
$ which -a python3
/usr/local/bin/python3
/usr/bin/python3
```

### 3.4 El incidente: `which` y la shell no coinciden

Bash cachea las rutas completas de los comandos ejecutados en una tabla de hash. Después de una actualización in situ que mueve un binario, la caché queda obsoleta y la shell sigue invocando la ruta vieja — que puede ya no existir.

```
$ hash
hits	command
   3	/usr/bin/find
  14	/usr/local/bin/kubectl
   2	/usr/bin/systemctl

$ sudo dnf -y remove kubectl-local && sudo dnf -y install kubernetes-client
...
Complete!

$ which kubectl
/usr/bin/kubectl

$ kubectl version --client
bash: /usr/local/bin/kubectl: No such file or directory
```

`which` consultó `$PATH` y respondió correctamente. La **shell** respondió desde su tabla de hash. `type` te dice la verdad, porque `type` es la shell:

```
$ type kubectl
kubectl is hashed (/usr/local/bin/kubectl)

$ hash -r          # flush the entire table
$ type kubectl
kubectl is /usr/bin/kubectl

$ hash -d kubectl  # flush a single entry
$ set +h           # disable hashing entirely (debugging only — measurable slowdown)
```

**Regla de diagnóstico:** si un comando se comporta distinto en tu shell interactiva que en una unidad de systemd o un trabajo de `cron`, chequeá tres cosas en este orden — `type -a <cmd>`, el `$PATH` efectivo (`systemctl show -p Environment <unit>`) y la tabla de hash.

```
$ systemctl show -p Environment telemetry-agent.service
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin

$ sudo systemctl show-environment
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
LANG=en_US.UTF-8
```

Fijate en lo que está *ausente*: `~/.local/bin`, `/opt/*/bin`, cualquier cosa que agregue tu `.bashrc`. Una unidad que "funciona cuando la corro a mano" y falla como servicio casi siempre es esto.

### 3.5 `whereis` — binarios, fuentes y manuales de una sola vez

`whereis` busca en una **lista compilada** de directorios estándar, más `$PATH` y `$MANPATH`, y quita extensiones conocidas antes de comparar. Es la forma más rápida de responder "¿está esto instalado, y dónde está su documentación?"

```
$ whereis find
find: /usr/bin/find /usr/share/man/man1/find.1.gz /usr/share/info/find.info-1.gz /usr/share/info/find.info.gz

$ whereis -b find          # binaries only
find: /usr/bin/find

$ whereis -m find          # manual pages only
find: /usr/share/man/man1/find.1.gz /usr/share/info/find.info-1.gz /usr/share/info/find.info.gz

$ whereis -s bash          # sources only
bash:

$ whereis -l | head -8     # print the directories whereis actually searches
bin: /usr/bin
bin: /usr/sbin
bin: /usr/lib
bin: /usr/lib64
bin: /etc
bin: /usr/games
man: /usr/share/man
man: /usr/local/man
```

Referencia de opciones:

| Opción | Efecto |
|---|---|
| `-b` | Buscar solo **b**inarios |
| `-m` | Buscar solo páginas de **m**anual |
| `-s` | Buscar solo fuentes (**s**ources) |
| `-B <dirs> -f` | Sobrescribir la ruta de búsqueda de binarios (`-f` termina la lista de directorios) |
| `-M <dirs> -f` | Sobrescribir la ruta de búsqueda de manuales |
| `-S <dirs> -f` | Sobrescribir la ruta de búsqueda de fuentes |
| `-u` | Reportar solo entradas **inusuales** — ítems a los que les falta una de las tres categorías |
| `-l` | Listar las rutas de búsqueda efectivas y salir |

`-u` es la subestimada. Es una auditoría de un solo comando para binarios entregados sin documentación, lo que en una imagen endurecida normalmente significa "instalado fuera del gestor de paquetes":

```
$ cd /usr/bin && whereis -u -m *
kube-bench: 
custom-backup.sh:
node_exporter:
```

Tres binarios en `/usr/bin` sin página de manual. En una flota, ese es tu detector de instalaciones ad-hoc.

**Limitación que hay que enunciar claramente:** `whereis` no va a encontrar nada fuera de su lista hardcodeada. Un binario en `/opt/vendor/bin` le es invisible. Para eso están `find` y `locate`.

---

## 4. `find` — la respuesta exacta, cara y completa

### 4.1 Gramática

```
find [-H | -L | -P] [-D debugopts] [-Olevel] [starting-point...] [expression]
```

La expresión se compone de cuatro clases de términos:

| Clase | Ejemplos | Semántica |
|---|---|---|
| **Opciones globales** | `-maxdepth`, `-mindepth`, `-depth`, `-xdev`, `-mount`, `-files0-from` | Afectan todo el recorrido sin importar su posición; deben aparecer antes de otros tests para evitar una advertencia |
| **Tests** | `-name`, `-type`, `-mtime`, `-size`, `-perm`, `-user`, `-empty` | Devuelven verdadero/falso por archivo |
| **Acciones** | `-print`, `-print0`, `-printf`, `-exec`, `-execdir`, `-delete`, `-ls`, `-quit` | Tienen un efecto colateral; también devuelven verdadero/falso |
| **Operadores** | `( )`, `!` / `-not`, `-a` / `-and`, `-o` / `-or`, `,` | Combinan términos |

**Precedencia, de mayor a menor:** `( )` → `!` → `-a` (implícito entre términos adyacentes) → `-o` → `,`

**Si la expresión no contiene ninguna acción, se agrega implícitamente `-print` a toda la expresión.** Si contiene alguna acción, no se agrega nada. Esta única regla explica la mayor parte del comportamiento sorprendente de `find`:

```
$ find /var/log -name '*.gz' -o -name '*.1'
/var/log/dnf.librepo.log.1
/var/log/messages-20260819.gz
```

Bien. Ahora agregá una acción a una rama y el `-print` implícito desaparece de la otra:

```
$ find /var/log -name '*.gz' -o -name '*.1' -print
/var/log/dnf.librepo.log.1
```

Los archivos `.gz` desaparecieron, porque la expresión se parseó como `( -name '*.gz' ) -o ( -name '*.1' -a -print )`. El arreglo es siempre el agrupamiento explícito:

```
$ find /var/log \( -name '*.gz' -o -name '*.1' \) -print
/var/log/dnf.librepo.log.1
/var/log/messages-20260819.gz
```

**La versión peligrosa de este bug:**

```bash
# WRONG — deletes every *.tmp AND every *.bak?  No: deletes only *.bak.
find /srv -name '*.tmp' -o -name '*.bak' -delete

# WRONG — deletes EVERYTHING under /srv, because -delete runs first and always
# succeeds, so -name is never reached in a short-circuit sense... and -delete
# implies -depth, reordering the traversal.
find /srv -delete -name '*.tmp'

# CORRECT
find /srv -type f \( -name '*.tmp' -o -name '*.bak' \) -delete
```

Siempre probá en seco las expresiones destructivas cambiando primero `-delete` por `-print`. Siempre.

### 4.2 Tests de nombre y ruta

| Test | Compara contra | Mayúsculas | Notas |
|---|---|---|---|
| `-name PATTERN` | nombre base | sensible | Glob de shell, **no** regex. Entrecomillalo o la shell lo expande primero |
| `-iname PATTERN` | nombre base | insensible | |
| `-path PATTERN` | ruta completa | sensible | `*` **sí** cruza `/` — a diferencia del globbing de la shell |
| `-ipath PATTERN` | ruta completa | insensible | |
| `-wholename` | ruta completa | sensible | Sinónimo GNU de `-path` |
| `-regex PATTERN` | ruta completa | sensible | Debe coincidir con la ruta **entera**; el dialecto por defecto es regex de Emacs |
| `-iregex PATTERN` | ruta completa | insensible | |
| `-regextype TYPE` | — | — | `posix-basic`, `posix-extended`, `egrep`, `emacs`, `findutils-default` |
| `-lname` / `-ilname` | destino del enlace simbólico | | |

```
$ find /etc -regextype posix-extended -regex '.*/(ssh|sshd)_config$' 2>/dev/null
/etc/ssh/ssh_config
/etc/ssh/sshd_config
```

La falla clásica de entrecomillado:

```
$ cd /var/log && find . -name *.log
find: paths must precede expression: `audit.log'
find: possible unquoted pattern after predicate `-name'?
```

La shell expandió `*.log` contra el directorio actual antes de que `find` siquiera lo viera. **Entrecomillá siempre los patrones con comillas simples.**

### 4.3 Tests de tipo, propiedad y permisos

| Test | Significado |
|---|---|
| `-type f` | archivo regular |
| `-type d` | directorio |
| `-type l` | enlace simbólico |
| `-type b` / `-type c` | dispositivo de bloque / de carácter |
| `-type p` / `-type s` | FIFO (tubería con nombre) / socket |
| `-xtype l` | enlace simbólico cuyo destino es un enlace simbólico — con `-L`, hace match con enlaces **rotos** |
| `-user NAME` / `-uid N` | propietario |
| `-group NAME` / `-gid N` | grupo |
| `-nouser` / `-nogroup` | el propietario/grupo no tiene entrada en `/etc/passwd` o `/etc/group` — **archivos huérfanos** |
| `-readable`, `-writable`, `-executable` | probado con `access(2)` como el usuario *invocante* |

La comparación de permisos tiene tres modos distintos y confundirlos produce auditorías silenciosamente incorrectas:

| Sintaxis | Semántica | Ejemplo | Hace match con |
|---|---|---|---|
| `-perm MODE` | **Exactamente** estos bits | `-perm 644` | el modo es precisamente `0644` |
| `-perm -MODE` | **Todos** estos bits activos (puede haber otros) | `-perm -0644` | `0644`, `0664`, `0755`, `4755` |
| `-perm /MODE` | **Cualquiera** de estos bits activo | `-perm /022` | escribible por grupo **o** por todos |

(`+MODE` fue eliminado en findutils 4.5.12; usá `/MODE`.)

```
$ sudo find /usr -xdev -type f -perm -4000 -printf '%M %u %g %8s %p\n' | head
-rwsr-xr-x root root    72040 /usr/bin/chage
-rwsr-xr-x root root    64232 /usr/bin/chfn
-rwsr-xr-x root root    39760 /usr/bin/chsh
-rwsr-xr-x root root    75304 /usr/bin/gpasswd
-rwsr-xr-x root root    56904 /usr/bin/mount
-rwsr-xr-x root root    39144 /usr/bin/newgrp
-rwsr-xr-x root root    32040 /usr/bin/passwd
-rwsr-xr-x root root    44880 /usr/bin/su
-rwsr-xr-x root root   187152 /usr/bin/sudo
-rwsr-xr-x root root    35128 /usr/bin/umount
```

### 4.4 Tests de tiempo — la regla de truncamiento

`find` calcula `(ahora − timestamp)` en segundos, lo divide por la unidad (86400 para `-*time`, 60 para `-*min`) y **descarta la parte fraccionaria**. Entonces:

| Argumento | Significado tras el truncamiento |
|---|---|
| `-mtime n` | exactamente `n` — es decir, entre `n` y `n+1` unidades de antigüedad |
| `-mtime +n` | estrictamente mayor que `n` — es decir, **al menos `n+1` unidades de antigüedad** |
| `-mtime -n` | estrictamente menor que `n` |

Así que `-mtime +1` requiere que un archivo tenga **al menos dos días**, y `-mtime 0` significa "modificado en las últimas 24 horas".

| Test | Timestamp | Unidad |
|---|---|---|
| `-atime` / `-amin` | último **acceso** | días / minutos |
| `-mtime` / `-mmin` | última **modificación de contenido** | días / minutos |
| `-ctime` / `-cmin` | último **cambio de inodo** (permisos, propiedad, cantidad de enlaces, *y* contenido) | días / minutos |
| `-newer FILE` | mtime más reciente que el mtime de `FILE` | — |
| `-anewer` / `-cnewer FILE` | atime / ctime más reciente que el mtime de `FILE` | — |
| `-newerXY REF` | `X`,`Y` ∈ `a`,`c`,`m`,`B`(nacimiento),`t`(hora literal) | GNU |
| `-used n` | accedido `n` días después de que su estado cambió por última vez | — |

`-newermt` es la opción que elimina toda la adivinanza aritmética — preferila siempre que tu `find` sea GNU:

```
$ find /var/log -xdev -type f -newermt '2026-08-25 00:00:00' ! -newermt '2026-08-26 00:00:00' -printf '%TY-%Tm-%Td %TH:%TM %10s %p\n'
2026-08-25 04:02      12288 /var/log/audit/audit.log.2
2026-08-25 09:31    2097152 /var/log/messages-20260825
2026-08-25 22:14      88121 /var/log/dnf.rpm.log
```

Una advertencia crucial para `-atime`: la mayoría de los sistemas de archivos de producción se montan con `relatime` o `noatime`, así que los tiempos de acceso son poco confiables o están congelados. Verificá antes de construir una política de limpieza sobre ellos:

```
$ findmnt -no OPTIONS /var
rw,relatime,seclabel,attr2,inode64,logbufs=8,logbsize=32k,noquota
```

Con `relatime`, el atime se actualiza solo si el atime anterior es más viejo que mtime/ctime o más viejo que 24 h. Una política de "borrar archivos no accedidos en 90 días" sobre un montaje `noatime` borra archivos que se leen activamente cada segundo.

### 4.5 Tests de tamaño — la regla de redondeo hacia arriba

`-size n[suffix]`, donde el sufijo es:

| Sufijo | Unidad |
|---|---|
| `b` | bloques de 512 bytes (**por defecto si se omite**) |
| `c` | bytes |
| `w` | palabras de 2 bytes |
| `k` | KiB (1024) |
| `M` | MiB |
| `G` | GiB |

**Los tamaños se redondean hacia arriba a la siguiente unidad entera antes de comparar.** Por lo tanto `-size -1M` hace match solo con archivos de tamaño 0, porque un archivo de 1 byte se redondea a 1 unidad M, que no es menor que 1. Usá `c` cuando quieras decir bytes:

```
$ find /var/log -xdev -type f -size +100M -printf '%s\t%p\n' | sort -rn | head -5
2147483648	/var/log/journal/9f2a.../system@0005.journal
1073741824	/var/log/audit/audit.log
 419430400	/var/log/telemetry-agent/agent.log

$ find /tmp -type f -size -1M          # matches ONLY empty files
/tmp/.X0-lock

$ find /tmp -type f -size -1048576c    # what you actually meant
/tmp/.X0-lock
/tmp/systemd-private-.../tmp/session.sock
```

`-empty` es el test correcto para archivos de longitud cero **y** directorios vacíos: `find /var/log -type f -empty`.

Notá que `%s` es el tamaño aparente y `%k`/`%b` son los bloques asignados. Para archivos dispersos (sparse) divergen enormemente:

```
$ find /var/lib/libvirt/images -name '*.qcow2' -printf '%s apparent, %k KiB allocated: %p\n'
53687091200 apparent, 8421376 KiB allocated: /var/lib/libvirt/images/node01.qcow2
```

### 4.6 Control del recorrido — `-maxdepth`, `-prune`, `-xdev`, `-depth`

Estas son las que hacen que `find /` termine en segundos en vez de minutos.

**`-xdev` / `-mount`** — no descender a otros sistemas de archivos. Obligatorio en cualquier `find /` en producción; de lo contrario recorrés montajes NFS, cada overlay de contenedor bajo `/var/lib/containers`, y `/proc`:

```
$ time sudo find / -type f -name '*.conf' | wc -l
178432

real	2m41.883s
user	0m4.201s
sys	0m21.774s

$ time sudo find / -xdev -type f -name '*.conf' | wc -l
9214

real	0m3.117s
user	0m0.612s
sys	0m1.883s
```

**`-prune`** — no descender a un directorio que hizo match. `-prune` siempre devuelve verdadero y carece de sentido con `-depth`. El modismo canónico es `-path X -prune -o <expresión real> -print`:

```
$ sudo find / -xdev \( -path /var/lib/containers -o -path /var/lib/docker -o -path /proc -o -path /sys \) -prune -o -type f -perm -4000 -print
/usr/bin/chage
/usr/bin/chfn
/usr/bin/gpasswd
/usr/bin/mount
/usr/bin/passwd
/usr/bin/su
/usr/bin/sudo
/usr/bin/umount
/usr/libexec/openssh/ssh-keysign
/usr/sbin/pam_timestamp_check
/usr/sbin/unix_chkpwd
```

Leelo así: *"si la ruta es una de estas, podala (y el `-o` cortocircuita, así que `-print` nunca se ejecuta); si no, si es un archivo regular SUID, imprimila."* El `-print` al final es obligatorio — el `-print` implícito se adosaría solo al último término.

**`-maxdepth n` / `-mindepth n`** — acotar la profundidad. La profundidad 0 es el punto de partida en sí.

```
$ find /etc -maxdepth 1 -type d | head -5
/etc
/etc/ssh
/etc/systemd
/etc/pki
/etc/security

$ find /etc -mindepth 1 -maxdepth 1 -type l -printf '%p -> %l\n' | head -3
/etc/localtime -> ../usr/share/zoneinfo/Europe/Madrid
/etc/mtab -> ../proc/self/mounts
/etc/system-release -> fedora-release
```

**`-depth`** — procesar el contenido de un directorio *antes* que el directorio mismo (post-orden). Requerido para `-delete` (e implícito en él), y requerido cuando renombrás directorios durante el recorrido.

### 4.7 Acciones: `-exec` vs `-exec +` vs `xargs`

| Forma | Invocaciones | Posición de `{}` | Nombres con espacios/saltos de línea | Estado de salida propagado | Velocidad |
|---|---|---|---|---|---|
| `-exec cmd {} \;` | **una por archivo** | en cualquier lugar, varias veces | seguro | no (se usa solo como test) | la más lenta |
| `-exec cmd {} +` | por lotes hasta `ARG_MAX` | debe ir última, una vez | seguro | **sí** | la más rápida |
| `-execdir cmd {} \;` | una por archivo, `cwd` = directorio del archivo | en cualquier lugar | seguro | no | lenta, **la más segura** |
| `-execdir cmd {} +` | por lotes, por directorio | última | seguro | sí | rápida + segura |
| `-print0 \| xargs -0 cmd` | por lotes | vía `-I` o anexado | seguro **solo con `-0`** | vía código de salida de `xargs` | la más rápida, paralelizable |
| `-print \| xargs cmd` | por lotes | anexado | **ROTO** | — | — |

```
$ getconf ARG_MAX
2097152
```

Diferencia medida sobre 20 000 archivos:

```
$ time find /usr/share/doc -type f -name '*.gz' -exec gzip -t {} \; 2>/dev/null

real	0m47.219s
user	0m11.043s
sys	0m28.887s

$ time find /usr/share/doc -type f -name '*.gz' -exec gzip -t {} + 2>/dev/null

real	0m4.802s
user	0m3.911s
sys	0m0.744s
```

Diez veces más rápido para el mismo trabajo, porque `{} +` amortiza `fork`/`exec` a lo largo de miles de argumentos.

Cuando necesitás `{}` en el medio de un comando, `+` no puede ayudarte directamente — envolvelo:

```
$ find /etc -name '*.conf' -exec sh -c 'for f; do printf "%s: %d lines\n" "$f" "$(wc -l < "$f")"; done' _ {} + | head -3
/etc/dnf/dnf.conf: 4 lines
/etc/sysctl.conf: 1 lines
/etc/nsswitch.conf: 21 lines
```

El `_` es el marcador de posición de `$0`; sin él, el primer nombre de archivo se consume como `$0` y se saltea silenciosamente.

**`xargs` con paralelismo** — el patrón para barridos grandes en nodos multinúcleo:

```
$ find /srv/media -type f -name '*.png' -print0 \
    | xargs -0 -r -P "$(nproc)" -n 32 optipng -quiet -o2
```

| Flag de `xargs` | Propósito |
|---|---|
| `-0` | La entrada está separada por NUL (se combina con `-print0`) |
| `-r`, `--no-run-if-empty` | No ejecutar el comando en absoluto si la entrada está vacía — **sin esto, `xargs rm` sin entrada ejecuta `rm` y da error, y `xargs ls` lista `$PWD`** |
| `-n N` | A lo sumo `N` argumentos por invocación |
| `-P N` | Ejecutar hasta `N` invocaciones en paralelo |
| `-I {}` | Modo de cadena de reemplazo; implica `-n 1` y `-L 1` (mata el rendimiento) |
| `-t` | Mostrar cada comando antes de ejecutarlo |

**`-execdir` y el problema TOCTOU.** Con `-exec`, `find` pasa una ruta completa que el proceso hijo resuelve *después* del recorrido. Entre que `find` decide que la ruta es segura y que el hijo la abre, un atacante con acceso de escritura a un directorio intermedio puede cambiar un componente por un enlace simbólico. `-execdir` hace chdir al directorio contenedor y pasa `./basename`, cerrando la ventana. GNU `find` además rechaza `-execdir` si `$PATH` contiene un elemento relativo o vacío:

```
$ PATH="$PATH:." find /tmp -type f -execdir file {} +
find: The relative path `.' is included in the PATH environment variable, which is insecure in combination with the -execdir action of find.  Please remove that entry from $PATH
```

Usá `-execdir` para cualquier cosa que corra como root sobre directorios en los que usuarios no-root pueden escribir.

**`-ok` / `-okdir`** preguntan antes de cada ejecución — útil para limpieza interactiva, inútil en automatización:

```
$ find /var/tmp -maxdepth 1 -type f -mtime +90 -ok rm -f {} \;
< rm ... /var/tmp/core.12841 > ? y
< rm ... /var/tmp/build-cache.tar > ? n
```

**`-delete`** es más rápido que `-exec rm {} +` (usa `unlinkat(2)` directamente, sin generar procesos) e implica `-depth` para poder eliminar directorios de abajo hacia arriba. Se niega a eliminar `.` y directorios no vacíos.

**`-quit`** detiene el recorrido en la primera coincidencia — la consulta barata de "¿existe esto en algún lado?":

```
$ find /usr -name 'libssl.so.3' -print -quit
/usr/lib64/libssl.so.3
```

### 4.8 `-printf` — salida estructurada sin un segundo proceso

`-ls` está orientado a humanos y es inestable. `-printf` es tu interfaz de máquina.

| Directiva | Valor |
|---|---|
| `%p` | ruta completa |
| `%f` | nombre base |
| `%h` | nombre de directorio |
| `%P` | ruta con el prefijo del punto de partida eliminado |
| `%s` | tamaño en bytes |
| `%k` / `%b` | tamaño en bloques de 1 KiB / de 512 bytes (asignados) |
| `%m` / `%M` | bits de permiso en octal / simbólico estilo `ls` |
| `%u` / `%U` | nombre del propietario / uid |
| `%g` / `%G` | nombre del grupo / gid |
| `%i` | número de inodo |
| `%n` | cantidad de enlaces duros |
| `%d` | profundidad bajo el punto de partida |
| `%y` / `%Y` | letra de tipo / tipo tras seguir enlaces simbólicos (`f d l b c p s`; `N` roto, `L` bucle) |
| `%l` | destino del enlace simbólico |
| `%D` | número de dispositivo del sistema de archivos contenedor |
| `%T@` | mtime como `segundos.nanosegundos` desde epoch |
| `%TY-%Tm-%Td %TH:%TM:%TS` | mtime formateado (`%A…` atime, `%C…` ctime, `%B…` nacimiento) |
| `%Z` | contexto SELinux |
| `\n \t \\ \0` | salto de línea, tabulación, barra invertida, NUL |

```
$ find /var/log -xdev -type f -printf '%T@ %10s %M %u:%g %p\n' | sort -rn | head -5
1756193472.0000000000  524288000 -rw-r----- root:systemd-journal /var/log/journal/9f2a/system.journal
1756193401.0000000000   14680064 -rw------- root:root /var/log/audit/audit.log
1756192088.0000000000    2097152 -rw-r----- telemetry:telemetry /var/log/telemetry-agent/agent.log
1756191002.0000000000     327680 -rw-r--r-- root:root /var/log/dnf.log
1756190455.0000000000      65536 -rw-r--r-- root:root /var/log/firewalld
```

Ordenar numéricamente por `%T@` es la consulta confiable de "qué cambió más recientemente en todo este subárbol" — muchísimo mejor que `ls -lt` porque recursa y no depende de fechas formateadas según la localización.

### 4.9 Rendimiento: el optimizador, y cómo ayudarlo

GNU `find` reordena los tests según el costo estimado. Niveles:

| Nivel | Comportamiento |
|---|---|
| `-O0` | Igual que `-O1` |
| `-O1` | **Por defecto.** Los tests de nombre de archivo (`-name`, `-regex`) se evalúan antes que cualquier cosa que requiera `stat(2)` |
| `-O2` | Primero los tests de nombre, luego `-type`/`-xtype` (satisfacibles desde `readdir` en sistemas de archivos que soportan `d_type`), luego los tests que requieren `stat` |
| `-O3` | Reordenamiento completo basado en costos usando probabilidades de éxito medidas |

```
$ find --version | tail -1
Features enabled: D_TYPE O_NOFOLLOW(enabled) LEAF_OPTIMISATION FTS(FTS_CWDFD) CBO(level=2)

$ find /usr -D rates -name '*.so' -type f 2>&1 | tail -6
Predicate success rates after completion:
[type=f] [est success rate 0.5] [name=*.so] [est success rate 0.1] -a [ -print ]
                                            ^ actual: 0.0193
                       ^ actual: 0.7712
```

Reglas prácticas que le ganan al optimizador siempre:

1. **`-xdev` primero.** Nada más ahorra tanto.
2. **`-prune` de los subárboles conocidamente enormes** (`/var/lib/containers`, `/var/lib/docker`, `/proc`, `/sys`, montajes NFS, cachés de compilación).
3. **`-maxdepth`** cuando conocés la profundidad.
4. **Tests baratos antes que caros** si deshabilitaste el optimizador o estás en un `find` POSIX: `-name` (comparación de cadena sobre el resultado de `readdir`) → `-type` (`d_type`, sin llamada al sistema) → `-size`/`-perm`/`-*time` (necesita `stat`) → `-exec` (necesita `fork`).
5. **`-quit`** para chequeos de existencia.
6. **`ionice`/`nice`** en nodos de producción — un `find` sobre todo el árbol es una tormenta de E/S:

```
$ sudo ionice -c3 nice -n19 find / -xdev -type f -size +1G -printf '%s %p\n' | sort -rn
```

`-c3` es la clase de E/S ociosa: el barrido cede el paso a cualquier otro lector del nodo.

### 4.10 Lista de verificación de seguridad y corrección para `find` en automatización

```bash
#!/usr/bin/env bash
set -euo pipefail

# 1. Anchor to an absolute starting point that you validated exists.
readonly ROOT=/var/cache/telemetry-agent
[[ -d $ROOT ]] || { printf 'fatal: %s is not a directory\n' "$ROOT" >&2; exit 1; }

# 2. Never let a variable be the whole expression; never build find args by
#    string concatenation. Use an array.
readonly -a PRUNE=(
  -path "$ROOT/.keep" -prune -o
)

# 3. Dry-run mode is not optional for anything that deletes.
DRY_RUN=${DRY_RUN:-1}
if (( DRY_RUN )); then
    action=(-print)
else
    action=(-delete)
fi

# 4. -xdev, explicit -type, explicit grouping, NUL-safe if piping.
find "$ROOT" -xdev "${PRUNE[@]}" \
     -type f \
     -mtime +7 \
     \( -name '*.tmp' -o -name '*.partial' \) \
     "${action[@]}"

# 5. find's exit status: 0 = clean, >0 = at least one error (permission denied,
#    unreadable directory). set -e catches it. Do NOT hide it with 2>/dev/null
#    unless you have already decided that unreadable directories are acceptable.
```

Peligros adicionales:

* **Nunca canalices un barrido de `find` a través de `tee`** y chequees `$?` — el estado de salida de la tubería es el de `tee`. Usá `set -o pipefail` o `PIPESTATUS`.
* `find ... | while read -r f` se rompe con nombres de archivo que contienen saltos de línea. Usá `find -print0 | while IFS= read -r -d '' f`.
* `find` sobre un directorio que se modifica concurrentemente puede omitir o duplicar entradas; no es un snapshot consistente.
* Los puntos de partida relativos combinados con `-execdir` y `cd` dentro de `-exec sh -c` producen bugs de resolución de rutas. Usá rutas absolutas.

---

## 5. `locate` y `updatedb` — el plano de búsqueda indexado

### 5.1 Arquitectura

`locate` no toca el árbol del sistema de archivos. Lee una **base de datos preconstruida** producida por `updatedb`, típicamente una vez por día.

```
updatedb (root, via systemd timer)
   │  walks the filesystem, honouring /etc/updatedb.conf
   ▼
/var/lib/plocate/plocate.db      (plocate; mode 0640 root:plocate)
/var/lib/mlocate/mlocate.db      (mlocate; mode 0640 root:mlocate)
   ▲
   │  read by a setgid binary that filters results per calling user
locate (any user)
```

**El modelo de seguridad importa y suele malinterpretarse.** Un índice ingenuo filtra la existencia de cada archivo del sistema a todo usuario, incluyendo los directorios personales de otros usuarios. Tanto `mlocate` como `plocate` resuelven esto así:

1. Almacenando la base de datos con modo `0640`, propiedad de `root` y de un grupo dedicado.
2. Instalando el binario `locate` con **setgid** a ese grupo, de modo que él — y solo él — pueda leer la base de datos.
3. Registrando metadatos de directorios en el índice y, al momento de la consulta, verificando si el usuario que llama puede efectivamente atravesar los directorios padre de cada candidato. Las entradas que no pasan la verificación se descartan silenciosamente.

```
$ ls -l /usr/bin/plocate
-rwxr-sr-x. 1 root plocate 92104 Jul 22 08:11 /usr/bin/plocate

$ ls -l /var/lib/plocate/plocate.db
-rw-r-----. 1 root plocate 38914560 Aug 26 04:12 /var/lib/plocate/plocate.db

$ id -Gn
sre wheel

$ head -c 16 /var/lib/plocate/plocate.db
head: cannot open '/var/lib/plocate/plocate.db' for reading: Permission denied
```

El usuario no puede leer la base de datos, pero `locate` sí, y filtra en su nombre. Consecuencia para los exámenes y para el razonamiento: **la salida de `locate` difiere entre usuarios en la misma máquina en el mismo instante.**

### 5.2 `mlocate` vs `plocate`

`plocate` (de Steinar H. Gunderslev) reemplazó a `mlocate` como opción por defecto en Debian 12 y Fedora 36+. Usa un índice de listas de posteo con io_uring, dando consultas de menos de un milisegundo en bases de datos de millones de archivos.

| | `mlocate` | `plocate` |
|---|---|---|
| Base de datos | `/var/lib/mlocate/mlocate.db` | `/var/lib/plocate/plocate.db` |
| Grupo | `mlocate` | `plocate` |
| Estructura del índice | Lista de rutas ordenada, escaneo lineal | Listas de posteo de trigramas (comprimidas) |
| Consulta sobre ~10 M rutas | ~1–2 s | ~1–10 ms |
| Tamaño de la base de datos | mayor | ~30–50 % menor |
| Actualización incremental | Sí (compara mtimes de directorios) | Sí (`updatedb --prune-bind-mounts`, puede leer una base de mlocate) |
| Archivo de configuración | `/etc/updatedb.conf` | **`/etc/updatedb.conf`** (mismo formato) |
| Programación | `/etc/cron.daily/mlocate` o `mlocate-updatedb.timer` | `plocate-updatedb.timer` |
| Coincidencia de subcadena sin `-r` | Sí | Sí, pero requiere ≥3 caracteres para el índice de trigramas (los patrones más cortos caen a un escaneo) |

Ambos son compatibles como reemplazo directo a nivel CLI para las opciones que cubre el examen, y ambos leen el **mismo** `/etc/updatedb.conf`.

### 5.3 Uso de `locate`

Semántica de los patrones — la regla que atrapa a todo el mundo:

> Si el patrón **no** contiene caracteres de globbing (`*`, `?`, `[`), `locate` lo compara como `*PATTERN*` — una subcadena de la ruta completa.
> Si **sí** contiene caracteres de globbing, el patrón se compara contra la **ruta entera**, y tenés que proveer vos mismo los `*` iniciales/finales.

```
$ locate sshd_config
/etc/ssh/sshd_config
/usr/share/man/man5/sshd_config.5.gz
/usr/share/vim/vim91/syntax/sshdconfig.vim

$ locate '*sshd_config'          # anchored at the end
/etc/ssh/sshd_config

$ locate 'sshd_config*'          # nothing: no path STARTS with sshd_config
$ echo $?
1
```

Referencia de opciones:

| Opción | Efecto |
|---|---|
| `-i`, `--ignore-case` | Insensible a mayúsculas |
| `-b`, `--basename` | Comparar solo contra el nombre base, no la ruta completa |
| `-w`, `--wholename` | Comparar la ruta completa (por defecto) |
| `-r`, `--regexp REGEX` | Regex básica POSIX en vez de glob |
| `--regex` | Tratar todos los *patrones* como regex extendidas POSIX |
| `-e`, `--existing` | **Imprimir solo entradas que todavía existen** — paga un `stat(2)` por coincidencia |
| `-c`, `--count` | Imprimir la cantidad de coincidencias en lugar de las coincidencias |
| `-l N`, `--limit N` | Detenerse después de `N` resultados |
| `-0`, `--null` | Separar la salida con NUL (canalizar a `xargs -0`) |
| `-d DB`, `--database DB` | Usar una base de datos alternativa (lista separada por `:`) |
| `-S`, `--statistics` | Imprimir estadísticas de la base de datos y salir |
| `-A`, `--all` | Imprimir entradas que coincidan con **todos** los patrones, no con cualquiera |
| `-q`, `--quiet` | Suprimir mensajes de error |

```
$ locate -c '*.service'
2841

$ locate -i -b -l 5 'NGINX.CONF'
/etc/nginx/nginx.conf
/usr/share/doc/nginx/nginx.conf.default

$ locate -0 -b '*.crt' | xargs -0 -r openssl x509 -noout -enddate -in 2>/dev/null | head -3
notAfter=Nov 12 08:30:00 2026 GMT

$ locate -S
Database /var/lib/mlocate/mlocate.db:
	 24,811 directories
	312,904 files
	16,842,003 bytes in file names
	 7,109,884 bytes used to store database
```

### 5.4 La trampa de la obsolescencia — y `-e`

Esta es la falla de `locate` más común en un incidente:

```
$ sudo rm -f /etc/opt/telemetry-agent/agent.yaml.bak
$ locate agent.yaml.bak
/etc/opt/telemetry-agent/agent.yaml.bak

$ locate -e agent.yaml.bak
$ echo $?
1
```

El índice es un snapshot de la última corrida de `updatedb`. Reporta archivos que fueron eliminados y omite archivos creados desde entonces. Durante el triage, o pasás `-e`, o refrescás:

```
$ stat -c '%y %n' /var/lib/plocate/plocate.db
2026-08-26 04:12:07.331884012 +0200 /var/lib/plocate/plocate.db

$ sudo systemctl list-timers plocate-updatedb.timer
NEXT                        LEFT       LAST                        PASSED   UNIT                    ACTIVATES
Thu 2026-08-27 04:12:00 CEST 17h left   Wed 2026-08-26 04:12:00 CEST 7h ago   plocate-updatedb.timer  plocate-updatedb.service

$ time sudo updatedb
real	0m38.442s
user	0m2.117s
sys	0m11.006s
```

**Regla:** `locate` es para exploración y para preguntas donde una respuesta de hace un día es aceptable. Usá `find` para cualquier cosa de la que dependa una decisión, y siempre para cualquier cosa creada en las últimas 24 horas.

### 5.5 `/etc/updatedb.conf` — anotado, completo

El archivo es una lista estilo shell de `KEY = "value"`. Listas separadas por espacios; los valores se comparan de forma insensible a mayúsculas para `PRUNEFS`.

```sh
# /etc/updatedb.conf — configuration for updatedb(8) (mlocate/plocate format).
# See updatedb.conf(5). Every entry here directly determines what locate(1)
# can find, and how long the nightly index build takes.

# --------------------------------------------------------------------------
# PRUNE_BIND_MOUNTS
#   "yes" -> skip bind mounts. Essential on container hosts and on any node
#   using systemd's BindPaths=/ProtectSystem= sandboxing, where the same inode
#   is visible under dozens of paths. Without it, updatedb indexes the same
#   tree once per bind mount and the database explodes.
# --------------------------------------------------------------------------
PRUNE_BIND_MOUNTS = "yes"

# --------------------------------------------------------------------------
# PRUNEFS
#   Filesystem TYPES (as reported in /proc/mounts) never to descend into.
#   Matched case-insensitively. Two categories matter operationally:
#     - Network filesystems: indexing them turns a local cron job into a
#       fleet-wide I/O storm against the NFS/CIFS server every night.
#     - Virtual/pseudo filesystems: infinite or meaningless to index.
# --------------------------------------------------------------------------
PRUNEFS = "9p afs anon_inodefs auto autofs bdev binfmt_misc cgroup cgroup2 cifs
coda configfs cpuset curlftpfs debugfs devpts devtmpfs ecryptfs exofs ftpfs
fuse fuse.ceph fuse.glusterfs fuse.gvfsd-fuse fuse.rclone fuse.s3fs fuse.sshfs
fusectl fuse.portal gfs gfs2 gpfs hugetlbfs inotifyfs iso9660 jffs2 lustre
mfs mqueue ncpfs nfs nfs4 nfsd nnpfs ocfs ocfs2 overlay pipefs proc pstore
ramfs rpc_pipefs securityfs selinuxfs sfs smbfs sockfs squashfs sysfs tmpfs
tracefs ubifs udf usbfs vboxsf"

# --------------------------------------------------------------------------
# PRUNENAMES
#   Directory BASENAMES to skip anywhere in the tree. Note: names only, never
#   paths, and wildcards are NOT supported. This is how you exclude VCS
#   metadata, which otherwise contributes millions of useless entries on a
#   developer workstation or a CI runner.
# --------------------------------------------------------------------------
PRUNENAMES = ".git .hg .svn .bzr .arch-ids {arch} CVS .terraform node_modules
.cache __pycache__ .venv target"

# --------------------------------------------------------------------------
# PRUNEPATHS
#   Absolute directory PATHS to skip, exactly as locate would report them:
#   no trailing slash, no wildcards, no symlinks. Two reasons to add a path:
#     1. Cost      - huge, churning trees (container layers, build caches).
#     2. Secrecy   - trees whose mere filenames leak information. Remember
#                    that locate's per-user filtering already hides
#                    unreadable paths, so this is defence in depth, not the
#                    primary control.
# --------------------------------------------------------------------------
PRUNEPATHS = "/afs /media /mnt /net /sfs /tmp /udev /var/tmp
/var/cache/ccache /var/cache/telemetry-agent
/var/lib/ceph /var/lib/containers /var/lib/docker /var/lib/kubelet
/var/lib/machines /var/lib/os-prober /var/lib/schroot
/var/spool/cups /var/spool/squid
/home/.ecryptfs"
```

Verificá que un cambio efectivamente haya surtido efecto. Editar el archivo no prueba nada:

```
$ sudo updatedb -v 2>&1 | head -3
updatedb: reading config file `/etc/updatedb.conf'
updatedb: skipping `/var/lib/containers' (PRUNEPATHS)
updatedb: skipping `/proc' (PRUNEFS: proc)

$ locate -c '/var/lib/containers'
0
$ locate -c '/var/lib/docker'
0
$ locate -c 'node_modules'
0
```

Sobrescrituras de `updatedb` por línea de comandos (tienen precedencia sobre el archivo de configuración):

| Opción | Efecto |
|---|---|
| `-U DIR`, `--database-root DIR` | Indexar solo este subárbol |
| `-o FILE`, `--output FILE` | Escribir en una base de datos alternativa |
| `-l 0`, `--require-visibility no` | Construir una base de datos **legible por todos** sin filtrado por usuario — solo para una base que vayas a entregar a consumidores sin privilegios, y solo si no contiene nada sensible |
| `-e DIRS`, `--prune-paths DIRS` | Rutas adicionales a omitir |
| `-f FSTYPES`, `--prune-fs FSTYPES` | Tipos de sistema de archivos adicionales a omitir |
| `-n NAMES`, `--prune-names NAMES` | Nombres base adicionales a omitir |
| `-v`, `--verbose` | Imprimir cada ruta a medida que se indexa |

Un patrón útil — un índice privado por proyecto que no requiere root y no contamina la base de datos del sistema:

```
$ updatedb -l 0 -U /srv/media -o "$HOME/.cache/media.db"
$ locate -d "$HOME/.cache/media.db" -i -b '*.flac' | wc -l
18422
$ locate -d "$HOME/.cache/media.db":/var/lib/plocate/plocate.db 'concert'
/srv/media/audio/2026-concert-master.flac
/usr/share/backgrounds/concert.jpg
```

### 5.6 Controlar el costo de `updatedb` en nodos de producción

Un `updatedb` sin restricciones en un nodo con un montaje NFS de 40 TiB saturará la red de almacenamiento a las 04:00 todos los días. Limitalo con un drop-in:

**`/etc/systemd/system/plocate-updatedb.service.d/10-throttle.conf`**

```ini
[Service]
# Yield to every other consumer of the disk.
IOSchedulingClass=idle
IOSchedulingPriority=7
Nice=19
CPUSchedulingPolicy=idle

# Hard ceilings, so a runaway index build cannot page out the workload.
MemoryMax=512M
MemoryHigh=256M
IOReadIOPSMax=/dev/nvme0n1 2000

# Fail loudly rather than run for hours.
TimeoutStartSec=20min
```

**`/etc/systemd/system/plocate-updatedb.timer.d/10-schedule.conf`**

```ini
[Timer]
# Fixed daily slot, spread across the fleet so N nodes do not hit shared
# storage simultaneously.
OnCalendar=
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=3600
Persistent=true
AccuracySec=1min
```

```
$ sudo systemctl daemon-reload
$ sudo systemctl restart plocate-updatedb.timer
$ systemctl cat plocate-updatedb.timer | tail -6
# /etc/systemd/system/plocate-updatedb.timer.d/10-schedule.conf
[Timer]
OnCalendar=
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=3600
Persistent=true
AccuracySec=1min

$ systemd-analyze calendar '*-*-* 03:00:00'
  Original form: *-*-* 03:00:00
Normalized form: *-*-* 03:00:00
    Next elapse: Thu 2026-08-27 03:00:00 CEST
       From now: 15h left
```

En imágenes inmutables/minimalistas (Bottlerocket, Flatcar, contenedores distroless) `locate` normalmente está ausente por completo. No construyas un runbook que dependa de él sin verificar:

```
$ command -v locate || echo "locate is not available on this image"
locate is not available on this image
```

### 5.7 `find` vs `locate` — la tabla de decisión

| Dimensión | `find` | `locate` |
|---|---|---|
| Fuente de datos | Sistema de archivos en vivo | Base de datos nocturna |
| Frescura | Exacta, ahora | Hasta 24 h de retraso |
| Latencia sobre 10 M archivos | 30 s – 10 min | 1 ms – 2 s |
| Costo de E/S | Alto — recorre cada inodo | Casi nulo |
| Privilegios | Ve lo que el usuario invocante puede atravesar; con `sudo` ve todo | Filtrado por usuario mediante el helper setgid |
| Expresividad | Tamaño, tiempo, permisos, propietario, tipo, enlaces, `-exec` | Solo subcadena de ruta/nombre o regex |
| Puede actuar sobre los resultados | Sí (`-exec`, `-delete`) | No — hay que canalizar a `xargs` |
| Funciona en un contenedor | Sí | Normalmente no está instalado |
| Correcto para | "¿Qué archivos cambiaron en la última hora?", "¿Cuáles son SUID?", "Borrá estos" | "¿Dónde estaba `nginx.conf`?" |

**El modismo compuesto** — usá `locate` para acotar gratis el conjunto de candidatos, y después `find` para responder con exactitud:

```
$ locate -0 -b 'nginx.conf' | xargs -0 -r find -maxdepth 0 -newermt '-1 day' -printf '%TF %TT %p\n'
2026-08-26 09:41:12.114 /etc/nginx/nginx.conf
```

---

## 6. Runbooks de producción

### 6.1 Runbook: `/` está 100 % llena a las 03:00

```
$ df -h / /var
Filesystem              Size  Used Avail Use% Mounted on
/dev/mapper/vg0-root     50G   50G     0 100% /
/dev/mapper/vg0-var     200G  118G   73G  62% /var
```

Paso 1 — encontrar a los culpables **sin salir del sistema de archivos**:

```
$ sudo find / -xdev -type f -size +200M -printf '%10s  %TF %TT  %p\n' 2>/dev/null | sort -rn | head
9663676416  2026-08-26 02:58:01  /var/lib/telemetry-agent/spool.db
2147483648  2026-08-26 01:12:44  /opt/telemetry-agent/logs/agent.log
1073741824  2026-08-25 23:40:02  /root/core.28841
```

`/opt/telemetry-agent/logs/agent.log` es la prueba irrefutable: un proveedor escribiendo logs dentro de `/opt` — una jerarquía **estática** — de modo que los patrones `/var/log/*` de logrotate nunca hicieron match, y creció hasta llenar `/`. Eso es una violación de FHS causando una caída de producción, que es precisamente por lo que existe este tema.

Paso 2 — cuantificar por directorio:

```
$ sudo find / -xdev -type f -printf '%h %s\n' 2>/dev/null \
    | awk '{ sz[$1] += $2 } END { for (d in sz) printf "%12d  %s\n", sz[d], d }' \
    | sort -rn | head -8
  2147495936  /opt/telemetry-agent/logs
  1073745920  /root
   402653184  /usr/lib/modules/6.11.4-200.fc44.x86_64
   201326592  /usr/lib64
```

Paso 3 — buscar archivos **eliminados pero abiertos**. `find` no puede verlos, y este es el caso en que `df` y `du` no coinciden:

```
$ df -h / | tail -1
/dev/mapper/vg0-root  50G   50G     0 100% /
$ sudo du -shx / 2>/dev/null
19G	/

$ sudo lsof -nP +L1 / | head -5
COMMAND    PID      USER   FD   TYPE DEVICE   SIZE/OFF NLINK     NODE NAME
agent    28841 telemetry    5w   REG  253,0 32212254720     0  1180742 /opt/telemetry-agent/logs/agent.log (deleted)

$ sudo find /proc/*/fd -ls 2>/dev/null | grep '(deleted)' | head -3
1180742 0 lrwx------ 1 telemetry telemetry 64 Aug 26 03:04 /proc/28841/fd/5 -> /opt/telemetry-agent/logs/agent.log (deleted)
```

31 GiB retenidos por un proceso cuyo archivo de log ya fue borrado con `rm`. Truncá vía `/proc` en lugar de reiniciar el servicio:

```
$ sudo truncate -s 0 /proc/28841/fd/5
$ df -h / | tail -1
/dev/mapper/vg0-root   50G   19G   29G  40% /
```

Paso 4 — arreglo permanente: mover los logs a `/var/log`, agregar `LogsDirectory=` a la unidad, instalar una política de `logrotate` y agregar un chequeo de CI (§6.5) para que la regresión de layout no pueda repetirse.

### 6.2 Runbook: agotamiento de inodos

Espacio libre, escrituras fallando con `ENOSPC`:

```
$ df -h /var | tail -1
/dev/mapper/vg0-var   200G   61G  130G  33% /var

$ df -i /var | tail -1
Filesystem             Inodes   IUsed IFree IUse% Mounted on
/dev/mapper/vg0-var  13107200 13107200     0  100% /var
```

Localizá el directorio que contiene millones de archivos diminutos:

```
$ sudo find /var -xdev -printf '%h\n' 2>/dev/null | sort | uniq -c | sort -rn | head -5
9184422 /var/spool/postfix/maildrop
 481003 /var/lib/telemetry-agent/queue
  91204 /var/cache/dnf
   4211 /var/log/journal/9f2ab8c1

$ sudo find /var/spool/postfix/maildrop -xdev -type f -mtime +2 -printf '%TF %p\n' | head -3
2026-08-19 /var/spool/postfix/maildrop/AF31C2A0B4
2026-08-19 /var/spool/postfix/maildrop/AF31C2A0B7
2026-08-19 /var/spool/postfix/maildrop/AF31C2A0BA
```

Borrá por lotes, con prioridad de E/S ociosa, para que la limpieza misma no cause un segundo incidente:

```
$ sudo ionice -c3 find /var/spool/postfix/maildrop -xdev -type f -mtime +2 -delete
$ df -i /var | tail -1
/dev/mapper/vg0-var  13107200 3922778 9184422  30% /var
```

Notá `-delete` en vez de `-exec rm {} \;`: nueve millones de pares `fork`/`exec` llevarían horas.

### 6.3 Runbook: auditoría de SUID/SGID y escribibles por todos a escala de flota

**`k8s/fhs-audit.yaml`** — un `DaemonSet` que corre el barrido en cada nodo, más un `CronJob` para una pasada completa programada.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: node-audit
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: fhs-audit
  namespace: node-audit
automountServiceAccountToken: false
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: fhs-audit-script
  namespace: node-audit
data:
  audit.sh: |
    #!/usr/bin/env bash
    # FHS and search-plane audit. Runs against the node root bind-mounted
    # read-only at /host. Emits newline-delimited JSON to stdout so a log
    # shipper can index it directly.
    set -uo pipefail

    NODE="${NODE_NAME:-unknown}"
    TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    emit() {  # emit <check> <severity> <detail...>
        local check=$1 sev=$2; shift 2
        printf '{"ts":"%s","node":"%s","check":"%s","severity":"%s","detail":"%s"}\n' \
            "$TS" "$NODE" "$check" "$sev" "${*//\"/\\\"}"
    }

    # Subtrees that are either pseudo-filesystems or container storage. -xdev
    # already excludes other mounts; these are belt-and-braces for bind mounts.
    PRUNE=(
        -path /host/proc -o
        -path /host/sys  -o
        -path /host/var/lib/containers -o
        -path /host/var/lib/docker     -o
        -path /host/var/lib/kubelet
    )

    # --- 1. SUID / SGID binaries outside the distribution baseline -----------
    find /host -xdev \( "${PRUNE[@]}" \) -prune -o \
         -type f \( -perm -4000 -o -perm -2000 \) \
         -printf '%m|%u|%g|%s|%p\n' 2>/dev/null \
    | while IFS='|' read -r mode owner group size path; do
        case "${path#/host}" in
            /usr/bin/*|/usr/sbin/*|/usr/libexec/*) sev=info  ;;
            /usr/local/*|/opt/*)                   sev=high  ;;
            *)                                     sev=critical ;;
        esac
        emit suid_sgid "$sev" "mode=$mode owner=$owner group=$group size=$size path=${path#/host}"
    done

    # --- 2. World-writable directories without the sticky bit ---------------
    find /host -xdev \( "${PRUNE[@]}" \) -prune -o \
         -type d -perm -0002 ! -perm -1000 \
         -printf '%m|%u|%p\n' 2>/dev/null \
    | while IFS='|' read -r mode owner path; do
        emit world_writable_dir high "mode=$mode owner=$owner path=${path#/host}"
    done

    # --- 3. Files owned by no known user or group (orphans) -----------------
    find /host -xdev \( "${PRUNE[@]}" \) -prune -o \
         \( -nouser -o -nogroup \) \
         -printf '%U|%G|%p\n' 2>/dev/null \
    | head -200 \
    | while IFS='|' read -r uid gid path; do
        emit orphaned_file medium "uid=$uid gid=$gid path=${path#/host}"
    done

    # --- 4. FHS violations: writable content inside static hierarchies -------
    find /host/usr /host/opt -xdev -type f -newermt '-24 hours' \
         ! -path '/host/usr/local/*' \
         -printf '%TF %TT|%p\n' 2>/dev/null \
    | while IFS='|' read -r mtime path; do
        emit static_hierarchy_mutation high "mtime=$mtime path=${path#/host}"
    done

    # --- 5. Executables shipped without a man page (ad-hoc installs) --------
    find /host/usr/bin /host/usr/sbin /host/usr/local/bin -maxdepth 1 -type f \
         -perm -u+x -printf '%f\n' 2>/dev/null \
    | while read -r bin; do
        if ! compgen -G "/host/usr/share/man/man*/${bin}.*" >/dev/null 2>&1; then
            emit undocumented_binary low "name=$bin"
        fi
    done

    # --- 6. locate index freshness ------------------------------------------
    for db in /host/var/lib/plocate/plocate.db /host/var/lib/mlocate/mlocate.db; do
        [[ -e $db ]] || continue
        age_h=$(( ( $(date +%s) - $(stat -c %Y "$db") ) / 3600 ))
        if (( age_h > 48 )); then
            emit locate_db_stale medium "db=${db#/host} age_hours=$age_h"
        else
            emit locate_db_fresh info "db=${db#/host} age_hours=$age_h"
        fi
    done

    emit audit_complete info "finished"
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: fhs-audit
  namespace: node-audit
  labels:
    app.kubernetes.io/name: fhs-audit
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: fhs-audit
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 25%
  template:
    metadata:
      labels:
        app.kubernetes.io/name: fhs-audit
    spec:
      serviceAccountName: fhs-audit
      automountServiceAccountToken: false
      hostPID: false
      hostNetwork: false
      priorityClassName: system-node-critical
      tolerations:
        - operator: Exists
      terminationGracePeriodSeconds: 30
      containers:
        - name: audit
          image: registry.access.redhat.com/ubi9/ubi-minimal:9.4
          command: ["/bin/bash", "-c"]
          args:
            - |
              microdnf install -y findutils bash coreutils >/dev/null 2>&1 || true
              while true; do
                  /scripts/audit.sh
                  sleep "${AUDIT_INTERVAL_SECONDS:-21600}"
              done
          env:
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: AUDIT_INTERVAL_SECONDS
              value: "21600"
          securityContext:
            # Traversing the whole node root requires uid 0 and DAC_READ_SEARCH.
            runAsUser: 0
            runAsGroup: 0
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: false
            privileged: false
            capabilities:
              drop: ["ALL"]
              add: ["DAC_READ_SEARCH"]
            seccompProfile:
              type: RuntimeDefault
          resources:
            requests:
              cpu: 20m
              memory: 64Mi
            limits:
              cpu: 500m
              memory: 256Mi
          volumeMounts:
            - name: host-root
              mountPath: /host
              readOnly: true
              mountPropagation: HostToContainer
            - name: scripts
              mountPath: /scripts
              readOnly: true
      volumes:
        - name: host-root
          hostPath:
            path: /
            type: Directory
        - name: scripts
          configMap:
            name: fhs-audit-script
            defaultMode: 0555
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: fhs-audit-nightly
  namespace: node-audit
spec:
  schedule: "17 3 * * *"
  timeZone: "Etc/UTC"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 5
  startingDeadlineSeconds: 900
  jobTemplate:
    spec:
      backoffLimit: 1
      activeDeadlineSeconds: 3600
      ttlSecondsAfterFinished: 86400
      template:
        spec:
          restartPolicy: Never
          serviceAccountName: fhs-audit
          automountServiceAccountToken: false
          nodeSelector:
            node-role.kubernetes.io/control-plane: ""
          tolerations:
            - key: node-role.kubernetes.io/control-plane
              operator: Exists
              effect: NoSchedule
          containers:
            - name: audit
              image: registry.access.redhat.com/ubi9/ubi-minimal:9.4
              command: ["/bin/bash", "/scripts/audit.sh"]
              env:
                - name: NODE_NAME
                  valueFrom:
                    fieldRef:
                      fieldPath: spec.nodeName
              securityContext:
                runAsUser: 0
                allowPrivilegeEscalation: false
                capabilities:
                  drop: ["ALL"]
                  add: ["DAC_READ_SEARCH"]
                seccompProfile:
                  type: RuntimeDefault
              resources:
                requests: {cpu: 50m, memory: 64Mi}
                limits:   {cpu: "1",  memory: 256Mi}
              volumeMounts:
                - name: host-root
                  mountPath: /host
                  readOnly: true
                - name: scripts
                  mountPath: /scripts
                  readOnly: true
          volumes:
            - name: host-root
              hostPath: {path: /, type: Directory}
            - name: scripts
              configMap: {name: fhs-audit-script, defaultMode: 0555}
```

```
$ kubectl apply -f k8s/fhs-audit.yaml
namespace/node-audit created
serviceaccount/fhs-audit created
configmap/fhs-audit-script created
daemonset.apps/fhs-audit created
cronjob.batch/fhs-audit-nightly created

$ kubectl -n node-audit logs ds/fhs-audit --tail=6 | jq -c 'select(.severity=="high" or .severity=="critical")'
{"ts":"2026-08-26T11:04:12Z","node":"worker-03","check":"suid_sgid","severity":"high","detail":"mode=4755 owner=root group=root size=1284120 path=/usr/local/bin/nsenter-helper"}
{"ts":"2026-08-26T11:04:19Z","node":"worker-03","check":"world_writable_dir","severity":"high","detail":"mode=777 owner=root path=/srv/uploads"}
{"ts":"2026-08-26T11:04:31Z","node":"worker-03","check":"static_hierarchy_mutation","severity":"high","detail":"mtime=2026-08-26 02:11:04 path=/opt/telemetry-agent/logs/agent.log"}
```

### 6.4 Runbook: deriva de configuración y archivos extraviados

Cruzá el manifiesto propio del gestor de paquetes contra el árbol en vivo. Este es el chequeo de mayor señal en cualquier host de larga vida.

**Basados en RPM:**

```
$ sudo rpm -Va --nomtime --nordev 2>/dev/null | head -8
S.5....T.  c /etc/ssh/sshd_config
.M.......    /var/log/telemetry-agent
missing      /usr/share/man/man1/agent.1.gz
S.5....T.    /usr/bin/kubectl
```

Leyenda de las banderas de verificación: `S` tamaño, `M` modo, `5` digest MD5, `D` dispositivo, `L` destino del enlace simbólico, `U` usuario, `G` grupo, `T` mtime, `P` capacidades; `c` marca un archivo de configuración (se espera que difiera), y `missing` significa que el archivo desapareció por completo. Que `/usr/bin/kubectl` difiera **sin** la bandera `c` significa que alguien sobrescribió un binario empaquetado in situ — una bandera roja de cadena de suministro.

**Basados en Debian:**

```
$ sudo debsums -c 2>/dev/null
/usr/bin/kubectl
/etc/nginx/nginx.conf
```

**Archivos presentes pero que no pertenecen a ningún paquete** — la verdadera consulta de "quién puso esto acá":

```
$ sudo find /usr/bin /usr/sbin /usr/local/bin -maxdepth 1 -type f -print0 2>/dev/null \
    | xargs -0 -r rpm -qf --qf '%{NAME}\n' 2>&1 \
    | grep 'is not owned by any package'
file /usr/local/bin/nsenter-helper is not owned by any package
file /usr/bin/custom-backup.sh is not owned by any package
```

Equivalente en Debian:

```
$ sudo find /usr/bin -maxdepth 1 -type f -print0 \
    | xargs -0 -r -n50 dpkg -S 2>&1 \
    | grep 'no path found'
dpkg-query: no path found matching pattern /usr/bin/custom-backup.sh
```

### 6.5 Compuerta de CI: rechazar violaciones de FHS antes de que se publiquen

**`.gitlab-ci.yml`** (equivalentemente un job de GitHub Actions) que hace fallar la compilación si un paquete escribiría fuera de su layout declarado.

```yaml
stages:
  - build
  - policy

variables:
  PKG_NAME: "telemetry-agent"

build:package:
  stage: build
  image: fedora:44
  script:
    - dnf -y install rpm-build rpmdevtools findutils
    - rpmbuild -bb --define "_topdir ${CI_PROJECT_DIR}/rpmbuild" packaging/${PKG_NAME}.spec
  artifacts:
    paths: ["rpmbuild/RPMS/"]
    expire_in: 1 day

policy:fhs:
  stage: policy
  image: fedora:44
  needs: ["build:package"]
  script:
    - dnf -y install rpm findutils
    - |
      set -euo pipefail
      RPM=$(find rpmbuild/RPMS -name "${PKG_NAME}-*.rpm" -type f -print -quit)
      echo "Auditing payload of ${RPM}"
      rpm -qlp "$RPM" > /tmp/payload.txt

      fail=0
      check() {  # check <regex> <message>
        if grep -qE "$1" /tmp/payload.txt; then
          printf 'FHS VIOLATION: %s\n' "$2" >&2
          grep -E "$1" /tmp/payload.txt | sed 's/^/    /' >&2
          fail=1
        fi
      }

      check '^/etc/.*/(bin|sbin)/'          '/etc must not contain binaries (FHS 3.0 §3.7)'
      check '^/usr/(var|etc)/'              'no /usr/var or /usr/etc; use /var and /etc'
      check '^/opt/[^/]+/(etc|var|log)/'    '/opt packages must use /etc/opt and /var/opt (FHS 3.0 §3.13)'
      check '^/(bin|sbin|lib|lib64)/'       'install into /usr/* — the root dirs are symlinks on merged-/usr systems'
      check '^/usr/local/'                  '/usr/local is reserved for the local administrator, not for packages (FHS 3.0 §4.9)'
      check '^/(tmp|var/tmp|run)/'          'packages must not ship files into volatile directories; use tmpfiles.d'
      check '^/srv/'                        '/srv is site-specific; packages must not claim paths there'

      # SUID/SGID must be explicitly allow-listed.
      rpm -qplv "$RPM" | awk '$1 ~ /^-..[sS]/ || $1 ~ /^-.....[sS]/ { print $NF }' > /tmp/suid.txt
      if [ -s /tmp/suid.txt ]; then
        while read -r p; do
          grep -qxF "$p" packaging/allowed-suid.txt || {
            printf 'FHS VIOLATION: unapproved SUID/SGID file: %s\n' "$p" >&2
            fail=1
          }
        done < /tmp/suid.txt
      fi

      # Every shipped executable must have a man page.
      rpm -qlp "$RPM" | grep -E '^/usr/(bin|sbin)/' | while read -r bin; do
        base=$(basename "$bin")
        rpm -qlp "$RPM" | grep -qE "^/usr/share/man/man[0-9]/${base}\.[0-9]" \
          || printf 'WARNING: %s ships without a man page\n' "$base" >&2
      done

      exit "$fail"
```

```
$ gitlab-runner exec docker policy:fhs
Auditing payload of rpmbuild/RPMS/x86_64/telemetry-agent-2.4.1-1.fc44.x86_64.rpm
FHS VIOLATION: /opt packages must use /etc/opt and /var/opt (FHS 3.0 §3.13)
    /opt/telemetry-agent/etc/agent.yaml
    /opt/telemetry-agent/log
ERROR: Job failed: exit code 1
```

La caída de la §6.1 ahora es imposible de reintroducir.

---

## 7. Verificación y diagnóstico de fallas

### 7.1 Síntoma → causa → comando

| Síntoma | Causa más probable | Comando de diagnóstico |
|---|---|---|
| `find: paths must precede expression` | Glob sin entrecomillar expandido por la shell | Entrecomillá el patrón: `find . -name '*.log'` |
| `find` no devuelve nada bajo un directorio raíz con merged-`/usr` | `/bin` es un enlace simbólico; `find` no lo sigue por defecto | `find -H /bin ...` o usá `/usr/bin` |
| `find /` tarda minutos y machaca la SAN | Descendiendo a almacenamiento NFS/de contenedores | Agregá `-xdev` y `-prune` de los árboles conocidos |
| `-delete` eliminó más de lo previsto | Faltan `\( ... \)` alrededor de una cadena `-o`, o `-delete` colocado primero | Reejecutá con `-print` en lugar de `-delete` |
| `xargs: argument line too long` | No se usa `-print0`/`-n` | `find ... -print0 \| xargs -0 -n 100 ...` |
| `xargs` ejecuta el comando una vez sin entrada | Falta `-r` | Agregá `-r` / `--no-run-if-empty` |
| Nombres con espacios se parten en pedazos | `find \| xargs` sin `-print0`/`-0` | `find -print0 \| xargs -0` |
| `locate` imprime un archivo que no existe | Base de datos obsoleta | `locate -e PATTERN`; `stat -c %y /var/lib/plocate/plocate.db`; `sudo updatedb` |
| `locate` no encuentra un archivo que acabás de crear | La base de datos es anterior al archivo | Usá `find`, o `sudo updatedb` primero |
| `locate` no encuentra nada en ningún lado | Base de datos ausente o timer deshabilitado | `systemctl list-timers '*updatedb*'`; `sudo updatedb` |
| Dos usuarios obtienen resultados distintos de `locate` | Comportamiento correcto — filtrado de visibilidad por usuario | `sudo locate PATTERN` para ver todo |
| `locate` omite `/home` por completo | `/home` en `PRUNEPATHS`, o sobre un tipo en `PRUNEFS` | `grep -E 'PRUNE' /etc/updatedb.conf`; `findmnt -no FSTYPE /home` |
| `which` lo encuentra, ejecutarlo falla con `No such file` | Entrada obsoleta en el hash de bash | `type CMD`; `hash -r` |
| El comando funciona interactivamente, falla en `cron`/systemd | `$PATH` distinto; alias o función solo en `.bashrc` | `type -a CMD`; `systemctl show -p Environment UNIT` |
| `which` no devuelve nada para `cd`, `echo`, `[` | Son builtins de la shell; `which` no puede ver builtins | `type -a cd` |
| El chequeo con `which` del script pasa pero el comando se comporta mal | Un alias/función ensombrece al binario en la shell que llama | Usá `command -v` y `command CMD` |
| `whereis` no encuentra un binario en `/opt` | `whereis` busca solo en directorios compilados + `$PATH` | `whereis -l`; recurrí a `find`/`locate` |
| `find: '-execdir': ... insecure ... $PATH` | `$PATH` contiene `.` o un elemento vacío | `printf '%s\n' "$PATH" \| tr ':' '\n' \| grep -n '^\.\?$'` |
| El demonio no arranca en un host con `/usr` de solo lectura | Escribiendo en una jerarquía estática | `sudo find /usr -xdev -newermt '-1 hour'`; agregá `StateDirectory=` |
| `df` dice lleno, `du` dice medio vacío | Archivos eliminados todavía abiertos | `sudo lsof -nP +L1 /` |
| `ENOSPC` con espacio libre a la vista | Agotamiento de inodos | `df -i`; `find <fs> -xdev -printf '%h\n' \| sort \| uniq -c \| sort -rn` |
| La limpieza por `-atime` borra archivos calientes | El montaje es `noatime`/`relatime` | `findmnt -no OPTIONS <mount>`; cambiá a `-mtime` |
| `find -mtime +1` omite los archivos de ayer | Truncamiento: `+1` significa ≥ 2 días | Usá `-newermt '-1 day'` |
| `find -size -1M` solo hace match con archivos vacíos | Los tamaños se redondean **hacia arriba** | Usá `-size -1048576c` |

### 7.2 La escalera de verificación

Nunca afirmes que una ruta existe — probalo, y sabé en qué escalón de la escalera se apoya tu prueba.

| Pregunta | Comando | Costo | Qué prueba |
|---|---|---|---|
| ¿Este nombre de comando se va a ejecutar? | `type -a CMD` | gratis, sin fork | Exactamente lo que la shell resuelve |
| ¿Hay un binario con este nombre en `$PATH`? | `command -v CMD` | gratis | Chequeo de existencia portable |
| ¿Dónde está su documentación? | `whereis -m CMD` | ~ms | Ubicación de la página de manual/info |
| ¿Podría existir en algún lugar del disco? | `locate -e -b CMD` | ~ms | Existía en el último `updatedb`, y aún existe |
| ¿Existe ahora mismo, cumpliendo estos criterios? | `find / -xdev ... -print -quit` | segundos–minutos | Verdad fundamental |
| ¿Es el archivo que entregó el paquete? | `rpm -Vf PATH` / `debsums -c` | segundos | Integridad contra el manifiesto del proveedor |
| ¿La ruta es lo que dice ser tras los enlaces simbólicos? | `readlink -f PATH` / `realpath PATH` | gratis | Ruta canónica |
| ¿Qué es exactamente este archivo? | `stat PATH`, `file PATH` | gratis | Metadatos del inodo, tipo de contenido |

```
$ readlink -f /bin/sh
/usr/bin/bash

$ stat /etc/opt/telemetry-agent/agent.yaml
  File: /etc/opt/telemetry-agent/agent.yaml
  Size: 2417      	Blocks: 8          IO Block: 4096   regular file
Device: 253,0	Inode: 1182904     Links: 1
Access: (0640/-rw-r-----)  Uid: (    0/    root)   Gid: (  982/telemetry)
Context: system_u:object_r:etc_t:s0
Access: 2026-08-26 09:41:03.114882014 +0200
Modify: 2026-08-26 09:41:02.998881901 +0200
Change: 2026-08-26 09:41:03.002881905 +0200
 Birth: 2026-08-26 09:41:02.998881901 +0200

$ rpm -Vf /usr/bin/kubectl
S.5....T.    /usr/bin/kubectl
```

Esa última línea es un hallazgo, no una formalidad: el `kubectl` en disco no coincide con lo que instaló el paquete.

### 7.3 Trampas de examen que vale la pena ensayar

1. `-mtime +1` significa **al menos dos días** de antigüedad, no "más que ayer".
2. `-size -1M` hace match **solo con archivos vacíos**, porque los tamaños se redondean hacia arriba.
3. Sin `-print0`/`-0`, `find | xargs` se rompe con espacios.
4. `-o` liga más débilmente que el `-a` implícito; el `-print` implícito se adosa a la **expresión completa solo si no hay ninguna acción presente**.
5. `which` es un programa externo: no puede ver alias, funciones, builtins ni keywords.
6. `type` y `command -v` son builtins de la shell y *sí* son autoritativos.
7. `locate` lee una base de datos, no el sistema de archivos; `-e` filtra las entradas que ya no existen.
8. `updatedb` lee `/etc/updatedb.conf`; tanto `mlocate` como `plocate` usan ese mismo archivo.
9. `PRUNEPATHS` toma rutas absolutas, `PRUNENAMES` toma nombres base, `PRUNEFS` toma **tipos** de sistema de archivos — y ninguno acepta comodines.
10. `/etc` nunca debe contener binarios; `/var/lib` guarda estado que debés respaldar, `/var/cache` guarda datos que podés borrar.
11. `/tmp` puede limpiarse al reiniciar; `/var/tmp` debe sobrevivirlo.
12. `/run` reemplazó a `/var/run` y `/var/lock` en FHS 3.0.
13. `/media` es para medios removibles; `/mnt` es el punto de montaje temporal del administrador.
14. `/opt/<pkg>` se empareja con `/etc/opt/<pkg>` y `/var/opt/<pkg>`.
15. `-prune` carece de sentido con `-depth`, y `-delete` implica `-depth`.
16. `whereis -u` lista entradas a las que les falta un binario, una fuente o una página de manual.

---

## 8. Referencias

**Objetivos de certificación**
- LPI, *Exam 101-500 Objectives (Version 5.0)* — Tema 104.7: <https://www.lpi.org/our-certifications/exam-101-objectives/>
- LPI, *LPIC-1 Certification Overview*: <https://www.lpi.org/our-certifications/lpic-1-overview/>

**Filesystem Hierarchy Standard**
- Linux Foundation, *Filesystem Hierarchy Standard 3.0* (2015-06-03): <https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html>
- Índice de la especificación FHS y versiones previas: <https://refspecs.linuxfoundation.org/fhs.shtml>
- freedesktop.org, `file-hierarchy(7)` — la visión compatible con FHS de systemd: <https://www.freedesktop.org/software/systemd/man/latest/file-hierarchy.html>
- freedesktop.org, *XDG Base Directory Specification*: <https://specifications.freedesktop.org/basedir-spec/latest/>
- Debian Policy Manual, Capítulo 9 — *The Operating System*: <https://www.debian.org/doc/debian-policy/ch-opersys.html>
- Fedora Packaging Guidelines — *File and Directory Ownership*: <https://docs.fedoraproject.org/en-US/packaging-guidelines/>
- Fedora Project, *UsrMove feature*: <https://fedoraproject.org/wiki/Features/UsrMove>
- Debian Wiki, *UsrMerge*: <https://wiki.debian.org/UsrMerge>

**`find`, `xargs` y findutils**
- GNU, *Finding Files: GNU findutils manual*: <https://www.gnu.org/software/findutils/manual/html_mono/find.html>
- `find(1)` — proyecto Linux man-pages: <https://man7.org/linux/man-pages/man1/find.1.html>
- `xargs(1)`: <https://man7.org/linux/man-pages/man1/xargs.1.html>
- The Open Group, POSIX.1-2017 `find`: <https://pubs.opengroup.org/onlinepubs/9699919799/utilities/find.html>
- The Open Group, POSIX.1-2017 `xargs`: <https://pubs.opengroup.org/onlinepubs/9699919799/utilities/xargs.html>

**`locate` / `updatedb`**
- Proyecto upstream `plocate`: <https://plocate.sesse.net/>
- Proyecto upstream `mlocate`: <https://pagure.io/mlocate>
- `locate(1)`: <https://man7.org/linux/man-pages/man1/locate.1.html>
- `updatedb(8)`: <https://man7.org/linux/man-pages/man8/updatedb.8.html>
- `updatedb.conf(5)`: <https://man7.org/linux/man-pages/man5/updatedb.conf.5.html>

**Búsqueda de comandos y la shell**
- GNU, *Bash Reference Manual* — Command Search and Execution: <https://www.gnu.org/software/bash/manual/bash.html#Command-Search-and-Execution>
- GNU, *Bash Reference Manual* — Bourne Shell Builtins (`hash`, `type`, `command`): <https://www.gnu.org/software/bash/manual/bash.html#Bourne-Shell-Builtins>
- The Open Group, POSIX.1-2017 `type`: <https://pubs.opengroup.org/onlinepubs/9699919799/utilities/type.html>
- The Open Group, POSIX.1-2017 `command`: <https://pubs.opengroup.org/onlinepubs/9699919799/utilities/command.html>
- `which(1)`: <https://man7.org/linux/man-pages/man1/which.1.html>
- `whereis(1)` — util-linux: <https://man7.org/linux/man-pages/man1/whereis.1.html>
- Documentación upstream de util-linux: <https://github.com/util-linux/util-linux/blob/master/Documentation/>

**Directivas de rutas y sandboxing de systemd**
- `systemd.exec(5)` — `StateDirectory=`, `CacheDirectory=`, `LogsDirectory=`, `ConfigurationDirectory=`, `RuntimeDirectory=`, `ProtectSystem=`: <https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html>
- `tmpfiles.d(5)`: <https://www.freedesktop.org/software/systemd/man/latest/tmpfiles.d.html>
- `systemd-path(1)`: <https://www.freedesktop.org/software/systemd/man/latest/systemd-path.html>
- `systemd-analyze(1)` — verbos `security` y `calendar`: <https://www.freedesktop.org/software/systemd/man/latest/systemd-analyze.html>
- `systemd.timer(5)`: <https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html>

**Referencias de Kubernetes e infraestructura**
- Kubernetes, *DaemonSet*: <https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/>
- Kubernetes, *CronJob*: <https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/>
- Kubernetes, *Pod Security Standards*: <https://kubernetes.io/docs/concepts/security/pod-security-standards/>
- Ansible, módulo `ansible.builtin.file`: <https://docs.ansible.com/ansible/latest/collections/ansible/builtin/file_module.html>
- Ansible, módulo `ansible.builtin.systemd_service`: <https://docs.ansible.com/ansible/latest/collections/ansible/builtin/systemd_service_module.html>

**Verificación de paquetes**
- `rpm(8)` — modo verify: <https://man7.org/linux/man-pages/man8/rpm.8.html>
- `debsums(1)`: <https://manpages.debian.org/stable/debsums/debsums.1.en.html>
- `dpkg-query(1)`: <https://man7.org/linux/man-pages/man1/dpkg-query.1.html>