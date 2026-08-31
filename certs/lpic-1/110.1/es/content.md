# LPIC-1 · Tema 110.1 — Realizar tareas de administración de seguridad

**Examen:** 102-500 · **Objetivo:** 110.1 · **Versión:** 5.0

**Áreas de conocimiento clave:** auditar un sistema para encontrar archivos con el bit SUID/SGID activado · establecer o cambiar contraseñas de usuario e información de envejecimiento de contraseñas · saber usar `nmap` y `netstat` para descubrir puertos abiertos en un sistema · configurar límites sobre inicios de sesión, procesos y uso de memoria de los usuarios · determinar qué usuarios han iniciado sesión en el sistema o están conectados actualmente · configuración y uso básicos de sudo.

**Términos y utilidades:** `find`, `passwd`, `fuser`, `lsof`, `nmap`, `chage`, `netstat`, `sudo`, `/etc/sudoers`, `su`, `usermod`, `ulimit`, `who`, `w`, `last`

---

## 1. Motivación: el problema arquitectónico

Todos los objetivos de 110.1 son facetas de una misma pregunta: **en una máquina que operás, ¿quién puede convertirse en root, y cómo lo averiguás después del hecho?**

En una laptop suelta esa pregunta es trivial. En una flota — 400 nodos, 12 equipos, una rotación de guardia, un auditor de cumplimiento pidiendo evidencia — se convierte en un problema de arquitectura con tres propiedades que lo vuelven difícil:

1. **El privilegio en Linux es ambiental, no acotado.** Un proceso que alcanza UID 0 no obtiene "permiso para reiniciar nginx". Obtiene la máquina entera: todos los namespaces, todos los archivos, el keyring del kernel, `/dev/mem` si no está bloqueado, y la capacidad de reescribir el rastro de auditoría que habría registrado lo que hizo. No hay radio de impacto intermedio salvo que lo construyas.
2. **Los caminos hacia UID 0 son numerosos y en su mayoría invisibles.** `sudo` es el que aprovisionás. Los binarios SUID, las capabilities de archivo, las membresías de grupo (`docker`, `disk`, `wheel`), los directorios de unidades systemd con permiso de escritura y una entrada `NOPASSWD` que alguien agregó durante un incidente hace tres trimestres son los que heredás. El conjunto de caminos crece en cada `apt upgrade` y se reduce solo cuando alguien lo mide.
3. **El privilegio ambiental es invisible en un diff.** Tu repositorio de infraestructura como código muestra lo que *pretendías*. No muestra el `chmod u+s` que dejó una sesión de depuración a las 03:40, ni el hecho de que un RPM de un proveedor incluye un helper SUID. La brecha entre intención y realidad es exactamente donde vive la forense post-incidente.

La postura de producción que se deriva de esto no es "endurecer el host una vez". Es un **bucle de control**:

```
      declare baseline           observe reality            reconcile / alert
   ┌──────────────────────┐   ┌────────────────────────┐   ┌──────────────────┐
   │ sudoers.d/*          │   │ find -perm -4000       │   │ drift metric     │
   │ limits.d/*.conf      │──▶│ getcap -r /            │──▶│ Prometheus alert │
   │ login.defs, faillock │   │ ss -tulpn / nmap       │   │ Ansible --check  │
   │ systemd unit hardening│   │ last / lastb / journal │   │ auditd -k events │
   └──────────────────────┘   └────────────────────────┘   └──────────────────┘
             ▲                                                       │
             └───────────────────────────────────────────────────────┘
```

El objetivo de LPIC-1 enumera las herramientas de observación. Este documento las trata como la mitad de instrumentación de ese bucle y muestra la mitad de declaración junto a ellas, porque un comando `find` cuya salida nadie compara contra una línea base es un comando de shell, no un control.

Una nota sobre el alcance: el examen evalúa `netstat`, `ulimit` y `/etc/security/limits.conf`. La producción en 2026 usa `ss`, directivas de unidad systemd y cgroup v2. Ambos están cubiertos, y cada sección dice claramente cuál es cuál — esa divergencia es en sí misma una de las cosas más útiles para interiorizar, porque una entrada en `limits.conf` que silenciosamente no hace nada sobre un servicio systemd es una de las fallas de falsa confianza más comunes en Linux moderno.

---

## 2. La superficie de privilegio: SUID, SGID y capabilities de archivo

### 2.1 Mecánica

Cuando el kernel ejecuta un archivo (`execve(2)`), normalmente conserva las credenciales del llamador. Dos bits de modo cambian eso:

| Bit | Octal | Simbólico | Efecto en un archivo regular | Efecto en un directorio |
|---|---|---|---|---|
| SUID | `4000` | `s` en la posición de ejecución de usuario | El **UID efectivo** del nuevo proceso pasa a ser el propietario del archivo | *(sin efecto sobre la ejecución)* |
| SGID | `2000` | `s` en la posición de ejecución de grupo | El **GID efectivo** del nuevo proceso pasa a ser el grupo del archivo | Las entradas nuevas heredan el grupo del directorio (semántica BSD) |
| Sticky | `1000` | `t` en la posición de ejecución de otros | *(sin efecto en Linux moderno)* | Solo el propietario de un archivo (o del directorio, o root) puede desenlazarlo — esto es lo que hace seguro a `/tmp` |

Dos detalles que hacen tropezar a la gente:

- **El bit se muestra como `S` (mayúscula) cuando falta el bit de ejecución correspondiente.** `-rwSr--r--` es un archivo SUID que nadie puede ejecutar — casi siempre un error, y digno de señalar en una auditoría.
- **SUID se ignora en sistemas de archivos montados con `nosuid`.** Este es un interruptor de corte a nivel de montaje, no por archivo, y es el endurecimiento correcto para `/tmp`, `/var/tmp`, `/home` y cualquier sistema de archivos que contenga datos escribibles por usuarios.

```
$ ls -l /usr/bin/passwd /usr/bin/wall /usr/bin/mount
-rwsr-xr-x. 1 root root  32712 Jul 18 2026 /usr/bin/passwd
-rwxr-sr-x. 1 root tty   35048 Jun 02 2026 /usr/bin/wall
-rwsr-xr-x. 1 root root  59976 Jun 27 2026 /usr/bin/mount
```

`passwd` es SUID root porque debe escribir `/etc/shadow` (modo `0000`, propietario root). `wall` es SGID `tty` porque debe escribir en los dispositivos de terminal de otros usuarios. Ninguno es gratuito; ambos son también, históricamente, fuentes de escalada local de privilegios. Ese es el compromiso en una línea: **SUID convierte un problema de permisos de archivo en un problema de corrección de código.**

### 2.2 Capabilities de archivo — la alternativa moderna y de grano más fino

Desde Linux 2.6.24, un binario puede llevar un subconjunto de los poderes de root en lugar de todos ellos, almacenado en el atributo extendido `security.capability`:

```
$ getcap -r / 2>/dev/null
/usr/bin/ping cap_net_raw=ep
/usr/bin/newgidmap cap_setgid=ep
/usr/bin/newuidmap cap_setuid=ep
/usr/sbin/arping cap_net_raw=ep
/usr/bin/mtr-packet cap_net_raw=ep
```

`ping` solía ser SUID root. Ahora lleva únicamente `CAP_NET_RAW` (`e`ffective + `p`ermitted), así que un bug en `ping` da la capacidad de fabricar paquetes crudos, no la máquina. Este es el mismo razonamiento que produce `CapabilityBoundingSet=` en unidades systemd y `securityContext.capabilities.drop: [ALL]` en una especificación de Pod — el argumento escala sin cambios desde un solo binario hasta un runtime de contenedores.

> **Implicación para la auditoría:** `find -perm -4000` **no** encuentra binarios con capabilities. Una auditoría que solo busca SUID tiene un punto ciego exactamente del tamaño del esfuerzo de modernización de tu distribución. Ejecutá siempre ambos.

### 2.3 Auditar la superficie

El comando en forma canónica de examen, y el comando en forma de producción:

```bash
# Exam form — SUID files anywhere on the root filesystem
$ sudo find / -perm -4000 -type f

# SUID or SGID, staying on one filesystem, with useful columns
$ sudo find / -xdev \( -perm -4000 -o -perm -2000 \) -type f \
      -printf '%M %6m %-8u %-8g %10s %p\n' | sort -k6
```

```
-rwxr-sr-x   2755 root     shadow        38912 /usr/bin/chage
-rwsr-xr-x   4755 root     root          72056 /usr/bin/chfn
-rwsr-xr-x   4755 root     root          44808 /usr/bin/chsh
-rwsr-xr-x   4755 root     root          88304 /usr/bin/gpasswd
-rwsr-xr-x   4755 root     root          55672 /usr/bin/mount
-rwsr-xr-x   4755 root     root          68208 /usr/bin/newgrp
-rwsr-xr-x   4755 root     root          32712 /usr/bin/passwd
-rwsr-xr-x   4755 root     root          72056 /usr/bin/su
-rwsr-xr-x   4755 root     root          39144 /usr/bin/umount
-rwsr-xr-x   4755 root     root         166056 /usr/bin/sudo
-rwxr-sr-x   2755 root     tty           35048 /usr/bin/wall
-rwsr-xr-x   4755 root     root          85064 /usr/lib/openssh/ssh-keysign
-rwxr-sr-x   2755 root     ssh          362640 /usr/bin/ssh-agent
```

Anatomía de los predicados de `find` — esto es crítico para el examen y la fuente de la mayoría de las respuestas equivocadas:

| Predicado | Significado |
|---|---|
| `-perm 4000` | El modo es **exactamente** `4000` — sin lectura, sin escritura, sin bits de ejecución. Casi nunca es lo que querés. |
| `-perm -4000` | **Todos** los bits de `4000` están activados; los demás bits se ignoran. **Esta es la forma de auditoría SUID.** |
| `-perm /4000` | **Cualquiera** de los bits de `4000` está activado. Idéntico a `-4000` para un solo bit; difiere para máscaras como `/6000`. |
| `-perm -u+s` | Equivalente simbólico de `-perm -4000`. |
| `-perm /6000` | SUID **o** SGID — una sola pasada en lugar de un grupo con `-o`. |

Flags operativos que importan a escala de flota:

| Flag | Por qué lo necesitás |
|---|---|
| `-xdev` | No descender a otros sistemas de archivos. Sin él recorrés montajes NFS, `/proc`, capas overlay de contenedores y volúmenes bind-montados — lento, ruidoso, y puede colgarse en un servidor NFS muerto. |
| `-type f` | Excluir directorios, para que los directorios SGID (legítimos, p. ej. `/var/mail`) no contaminen el informe de SUID. |
| `2>/dev/null` | Suprimir `Permission denied` al ejecutar sin privilegios — pero notá que un escaneo sin privilegios es **incompleto** y no debe usarse como auditoría de registro. |
| `-newer /var/lib/suid.stamp` | Escaneo incremental: solo archivos cuyo inodo cambió desde la última línea base. |

Verificación cruzada con el gestor de paquetes — este es el paso que convierte "una lista de archivos SUID" en "una lista de archivos SUID *inesperados*":

```
$ rpm -Va 2>/dev/null | awk '$1 ~ /M/ {print}'
.M.......  /usr/bin/find
```
```
$ dpkg --verify 2>/dev/null | grep '^..5\|^.M'
??5?????? c /etc/sudoers.d/90-cloud-init-users
```

`M` significa que el modo difiere del que declaró el paquete. Un binario SUID que el gestor de paquetes **no** distribuyó con el bit SUID es el hallazgo de mayor señal que puede producir una auditoría.

### 2.4 Compromisos: mecanismos para delegar privilegio

| Mecanismo | Granularidad | Quién se autentica | Rastro de auditoría | Radio de impacto ante compromiso | Revocación | Relevancia en el examen |
|---|---|---|---|---|---|---|
| **Binario SUID root** | Binario completo; todo root | Nadie (implícito) | Ninguno (el binario debe registrarse a sí mismo) | Root completo | `chmod u-s`, requiere tocar cada nodo | **Alta** — `find -perm -4000` |
| **Capabilities de archivo** | Una o más `CAP_*` | Nadie | Ninguno | Solo el alcance de esa capability | `setcap -r` | Baja (LPIC-2/3) |
| **`su`** | Todo el usuario destino | Contraseña de la cuenta destino | `/var/log/secure`, `journalctl -u ...`; el propio historial del shell no se registra | Usuario destino completo; la contraseña es conocimiento compartido | Cambiar la contraseña compartida en todos lados | **Alta** |
| **`sudo`** | Por comando, por host, por usuario destino | La contraseña propia del usuario **invocante** | `journald`/syslog por invocación, log de E/S completo opcional | Acotado por la regla de sudoers — *si la regla está bien escrita* | Borrar una línea en `sudoers.d/`, gestionado por configuración | **Alta** |
| **polkit** | Por acción D-Bus | Usuario invocante, según política | `journalctl -u polkit` | Acotado por la acción | Archivo de regla | Baja |
| **Unidad systemd + concesión de socket/`systemctl`** | Una operación de servicio | Manejado por sudo/polkit en el límite | journald | Acotado por el servicio | Cambio de unidad o de sudoers | Media |
| **`command=` de SSH en `authorized_keys`** | Un comando, por clave | Clave SSH | Log de `sshd` | Acotado por el comando forzado | Quitar la línea de la clave | Media |

**La regla de diseño que codifica esta tabla:** preferí el mecanismo cuyo modo de falla sea el más pequeño y cuya concesión sea una línea en un archivo que podés diferenciar. Eso es `sudo` para humanos interactivos y comandos forzados o capabilities para máquinas. SUID es un legado de un diseño anterior a todos estos; tratá cada binario SUID fuera de la línea base de la distribución como deuda.

### 2.5 Quitar un bit SUID de forma segura

```
$ sudo chmod u-s /usr/bin/legacy-helper
$ ls -l /usr/bin/legacy-helper
-rwxr-xr-x. 1 root root 24576 Aug 14 2026 /usr/bin/legacy-helper
```

**No** quites en bloque el conjunto SUID de la distribución. Quitar `su` no rompe nada en un host solo-sudo; quitar `mount` rompe las entradas `user` de `/etc/fstab`; quitar `pkexec` rompe la autenticación de escritorio; quitar `ssh-keysign` rompe la autenticación SSH basada en host. El flujo correcto es: enumerar → restar la línea base del proveedor → justificar o quitar cada resto → registrar la decisión → alertar sobre desviaciones respecto de la nueva línea base. Las secciones 8 y 9 implementan exactamente eso.

El interruptor de corte a nivel de sistema, para cargas de trabajo que nunca lo necesitan:

```ini
# /etc/systemd/system/myapp.service.d/10-hardening.conf
[Service]
NoNewPrivileges=yes      # execve() can never gain privileges — SUID becomes inert
RestrictSUIDSGID=yes     # the process cannot even create SUID/SGID files (implies NoNewPrivileges)
```

---

## 3. `sudo`: privilegio delegado, autenticado y auditado

### 3.1 `su` frente a `sudo`

```
$ su -
Password:
# whoami
root
```

```
$ sudo -i
[sudo] password for alice:
# whoami
root
```

Se ven equivalentes desde la terminal y son arquitectónicamente opuestos:

| Dimensión | `su -` | `sudo` |
|---|---|---|
| Credencial presentada | La contraseña de **root** | La contraseña del **usuario invocante** |
| ¿Secreto compartido? | Sí — todos los que tienen acceso root conocen la misma cadena | No |
| Desvinculación de un ingeniero | Rotar la contraseña de root en cada host, notificar a todos | Borrar su concesión de sudoers / deshabilitar su cuenta |
| Alcance de la concesión | Todo root, indefinidamente | Por comando, por host, por usuario destino, por regla |
| Registro por acción | Una línea de "session opened"; los comandos individuales no se registran | Una línea por invocación, con el argv exacto |
| Grabación de sesión | No | `Defaults log_output` → `sudoreplay` |
| MFA / política por usuario | Solo la pila PAM de root | Pila PAM por usuario, `pam_u2f`, `pam_sss`, etc. |
| Valor predeterminado correcto en producción | Contraseña de root bloqueada (`!` en shadow), sin login directo de root | El único camino a UID 0 |

Variantes de `su` que conviene conocer con precisión, porque la diferencia se examina:

| Comando | UID | Entorno | Directorio de trabajo |
|---|---|---|---|
| `su` | root | **Hereda** el entorno del llamador (excepto `PATH`/`IFS` según PAM) | Sin cambios |
| `su -` / `su -l` / `su --login` | root | **Shell de login**: reinicio completo, lee el `~/.bash_profile` de root, establece el `PATH` de root | `/root` |
| `su - alice` | alice | Shell de login como alice | `/home/alice` |
| `su -c 'cmd' alice` | alice | No login | Sin cambios |
| `sudo -s` | root | Ejecuta `$SHELL` como root, **no** login (sujeto a `env_reset`) | Sin cambios |
| `sudo -i` | root | **Login inicial** simulado: entorno y `PATH` de root, ejecuta el perfil de root | `/root` |
| `sudo -u www-data cmd` | www-data | Se aplica `env_reset` | Sin cambios |

El síntoma operativo clásico: un script funciona bajo `su -` y falla bajo `su`, porque `su` conservó el `PATH` del llamador y `/usr/sbin` no está en él. Usá siempre `su -` (o `sudo -i`) cuando querés el entorno de root.

### 3.2 La gramática de sudoers

`/etc/sudoers` lo analiza el plugin de políticas de `sudo`. La línea de regla tiene una forma fija:

```
who      where = (as-whom : as-which-group)   TAGS: what
alice    ALL   = (root)                       NOPASSWD: /bin/systemctl restart nginx.service
```

| Campo | Significado | Valores de ejemplo |
|---|---|---|
| `who` | Usuario, `%grupo`, `#uid`, `%#gid`, `+netgroup`, o un `User_Alias` | `alice`, `%wheel`, `%sudo`, `#1001` |
| `where` | Host donde aplica la regla, o un `Host_Alias` | `ALL`, `web01`, `10.20.4.0/24` |
| `(runas)` | Usuario destino, opcionalmente `:grupo` | `(root)`, `(ALL:ALL)`, `(postgres)` |
| `TAGS` | `NOPASSWD:`, `PASSWD:`, `NOEXEC:`, `SETENV:`, `LOG_INPUT:`, `LOG_OUTPUT:` | |
| `what` | Ruta(s) absoluta(s) de comando con argumentos opcionales, o un `Cmnd_Alias` | `ALL`, `/usr/bin/systemctl status *` |

Los alias le dan estructura al archivo:

```sudoers
User_Alias   SRE          = alice, bob, carol
User_Alias   DBA          = dave, erin
Runas_Alias  APPUSERS     = www-data, appsvc
Host_Alias   WEBTIER      = web01, web02, web03
Cmnd_Alias   SVC_READ     = /usr/bin/systemctl status *, \
                            /usr/bin/systemctl is-active *, \
                            /usr/bin/journalctl
Cmnd_Alias   SVC_RESTART  = /usr/bin/systemctl restart nginx.service, \
                            /usr/bin/systemctl reload nginx.service
```

**El orden importa: gana la última regla que coincide.** Esto es lo opuesto al primer-match de un firewall y es una fuente frecuente de concesiones accidentales.

```sudoers
alice ALL = (ALL) ALL
alice ALL = (ALL) /bin/ls        # alice can now ONLY run /bin/ls — the second line wins
```

### 3.3 Una disposición de sudoers completa y de nivel productivo

Nunca edites `/etc/sudoers` para políticas. Distribuí archivos drop-in en `/etc/sudoers.d/`; el archivo principal incluye el directorio:

```sudoers
# /etc/sudoers  — vendor file, edited only via `visudo`
Defaults   env_reset
Defaults   mail_badpass
Defaults   secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

root       ALL=(ALL:ALL) ALL
%sudo      ALL=(ALL:ALL) ALL

@includedir /etc/sudoers.d
```

> `@includedir` es la sintaxis desde sudo 1.9.1 en adelante. `#includedir` es la grafía histórica y sigue siendo aceptada — notá que, a pesar de empezar con `#`, **no** es un comentario. Los archivos del directorio se omiten si contienen un `.` o terminan en `~`, que es la razón por la que `foo.bak` deja de aplicarse silenciosamente.

```sudoers
# /etc/sudoers.d/00-defaults        mode 0440, root:root
#
# Hardening defaults applied before any grant. Numeric prefix fixes ordering:
# sudo reads sudoers.d entries in lexical order and the last match wins.

Defaults    env_reset
Defaults    secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Defaults    env_keep += "LANG LC_* http_proxy https_proxy no_proxy"

# Credential caching: per-TTY, 5 minutes. `tty` prevents one terminal's
# authentication from silently authorising a command in another.
Defaults    timestamp_type=tty
Defaults    timestamp_timeout=5
Defaults    passwd_timeout=1

# Allocate a pty for the command. Without this, a backgrounded child of a sudo
# command keeps running on the caller's terminal after sudo exits and can inject
# input into it (TIOCSTI-class attacks). Default since sudo 1.9.14; assert it.
Defaults    use_pty

# Structured logging to journald in addition to syslog.
Defaults    syslog=authpriv
Defaults    log_year, log_host
Defaults    logfile="/var/log/sudo.log"

# Lockout hygiene: three tries, then a distinctive message that greps well.
Defaults    passwd_tries=3
Defaults    badpass_message="Authentication failure — this attempt has been logged."

# Do not let sudo hang for 5–30 s resolving an unqualified hostname.
Defaults    !fqdn
```

```sudoers
# /etc/sudoers.d/20-sre-oncall      mode 0440, root:root
#
# On-call SRE grant. Scoped to service lifecycle operations on the web tier.
# Deliberately NOT `(ALL) ALL`: see the escape-hatch analysis in 3.6.

User_Alias   SRE_ONCALL  = alice, bob, carol
Host_Alias   WEBTIER     = web01, web02, web03, web04

Cmnd_Alias   SVC_READ    = /usr/bin/systemctl status *,       \
                           /usr/bin/systemctl is-active *,    \
                           /usr/bin/systemctl is-enabled *,   \
                           /usr/bin/systemctl list-units *,   \
                           /usr/bin/journalctl

Cmnd_Alias   SVC_WRITE   = /usr/bin/systemctl start nginx.service,   \
                           /usr/bin/systemctl stop nginx.service,    \
                           /usr/bin/systemctl restart nginx.service, \
                           /usr/bin/systemctl reload nginx.service

Cmnd_Alias   DIAG        = /usr/bin/ss, /usr/sbin/ss,               \
                           /usr/bin/lsof, /usr/bin/dmesg,           \
                           /usr/bin/tcpdump -i * -w /var/tmp/*.pcap

# Read-only diagnostics: no password, so a pager alert can be triaged in seconds.
SRE_ONCALL   WEBTIER = (root) NOPASSWD: SVC_READ, DIAG

# State-changing operations: password required, full I/O session recorded.
SRE_ONCALL   WEBTIER = (root) PASSWD: LOG_INPUT: LOG_OUTPUT: SVC_WRITE

# Application-user shell for debugging, recorded. NOEXEC blocks the LD_PRELOAD
# exec() shim that lets a permitted program spawn an unpermitted child.
SRE_ONCALL   WEBTIER = (www-data) NOEXEC: /usr/bin/php -r *

Defaults:SRE_ONCALL  iolog_dir=/var/log/sudo-io/%{user}
Defaults:SRE_ONCALL  iolog_file=%{seq}
```

```sudoers
# /etc/sudoers.d/30-deploy-automation   mode 0440, root:root
#
# Machine identity used by the deployment agent. No TTY (it runs from a systemd
# unit), so requiretty must be off for this user; the grant is a single exact
# command with no wildcard in a position that could be abused.

Defaults:deploy    !requiretty
Defaults:deploy    !syslog          # this unit already logs to journald under its own name
Defaults:deploy    log_output

deploy  ALL = (root) NOPASSWD: /usr/local/sbin/deploy-release.sh
deploy  ALL = (root) NOPASSWD: /usr/bin/systemctl daemon-reload
```

### 3.4 Editar de forma segura

**Nunca abras `/etc/sudoers` en un editor común.** Un error de sintaxis hace que `sudo` se niegue a ejecutarse *por completo*, y en un host sin contraseña de root y sin consola quedaste afuera.

```
$ sudo visudo
```

`visudo` toma un lock, abre `$SUDO_EDITOR`/`$VISUAL`/`$EDITOR`, y se niega a instalar un archivo que no pase el analizador:

```
>>> /etc/sudoers: syntax error near line 22 <<<
What now?
Options are:
  (e)dit sudoers file again
  e(x)it without saving changes to sudoers file
  (Q)uit and save changes to sudoers file (DANGER!)

What now? e
```

Para drop-ins y para CI:

```
$ sudo visudo -cf /etc/sudoers.d/20-sre-oncall
/etc/sudoers.d/20-sre-oncall: parsed OK

$ sudo visudo -f /etc/sudoers.d/20-sre-oncall     # edit a specific file, locked and validated

$ sudo visudo -c                                   # validate the whole tree
/etc/sudoers: parsed OK
/etc/sudoers.d/00-defaults: parsed OK
/etc/sudoers.d/20-sre-oncall: parsed OK
/etc/sudoers.d/30-deploy-automation: parsed OK
```

Los permisos los aplica el propio sudo — `0440`, propietario `root:root`. Un archivo de sudoers escribible por todos se rechaza:

```
$ sudo -l
sudo: /etc/sudoers.d/20-sre-oncall is mode 0640, should be 0440
sudo: no valid sudoers sources found, quitting
```

### 3.5 Usar e inspeccionar sudo

```
$ sudo -l
Matching Defaults entries for alice on web01:
    env_reset, secure_path=/usr/local/sbin\:/usr/local/bin\:/usr/sbin\:/usr/bin\:/sbin\:/bin,
    timestamp_type=tty, timestamp_timeout=5, use_pty, !fqdn,
    iolog_dir=/var/log/sudo-io/alice

User alice may run the following commands on web01:
    (root) NOPASSWD: /usr/bin/systemctl status *, /usr/bin/systemctl is-active *,
        /usr/bin/journalctl, /usr/bin/ss, /usr/bin/lsof, /usr/bin/dmesg
    (root) LOG_INPUT: LOG_OUTPUT: /usr/bin/systemctl start nginx.service,
        /usr/bin/systemctl stop nginx.service, /usr/bin/systemctl restart nginx.service
    (www-data) NOEXEC: /usr/bin/php -r *
```

```
$ sudo -l -U bob            # what may *bob* do? (requires privilege yourself)
$ sudo -ll                  # long form, one rule per stanza with source file
$ sudo -v                   # refresh the credential cache without running anything
$ sudo -k                   # invalidate the cache (next sudo will prompt)
$ sudo -K                   # remove the timestamp record entirely
$ sudo -u postgres psql     # run as another user
$ sudo -g docker id         # run with another primary group
$ sudo -H -u www-data env | grep HOME
HOME=/var/www
$ sudo -b /usr/local/sbin/long-job.sh    # detach into the background
$ sudoedit /etc/nginx/nginx.conf         # edit as root with YOUR editor, safely (see 3.6)
```

Una denegación, y lo que escribe:

```
$ sudo systemctl restart postgresql
[sudo] password for alice:
Sorry, user alice is not allowed to execute '/usr/bin/systemctl restart postgresql'
as root on web01.
```

```
$ sudo journalctl -t sudo -n 3 -o cat
alice : TTY=pts/1 ; PWD=/home/alice ; USER=root ; COMMAND=/usr/bin/systemctl restart nginx.service
alice : command not allowed ; TTY=pts/1 ; PWD=/home/alice ; USER=root ;
    COMMAND=/usr/bin/systemctl restart postgresql
alice : 3 incorrect password attempts ; TTY=pts/1 ; PWD=/home/alice ; USER=root ;
    COMMAND=/bin/bash
```

Reproducción de sesión, cuando `log_output` está activado:

```
$ sudo sudoreplay -l user alice
Aug 31 12:04:11 2026 : alice : TTY=/dev/pts/1 ; CWD=/home/alice ; USER=root ;
    TSID=000004 ; COMMAND=/usr/bin/systemctl restart nginx.service

$ sudo sudoreplay -s 4 000004      # replay at 4x speed
```

### 3.6 Los modos de falla que importan

**Escotillas de escape.** Una regla de sudoers concede un *programa*, pero muchos programas conceden un *shell*. Cada entrada de abajo es un shell root completo para un usuario al que solo se le dio un comando:

| Comando concedido | Escape |
|---|---|
| `/usr/bin/vi`, `vim`, `less`, `more`, `man` | `:!/bin/sh` o `!/bin/sh` desde el paginador |
| `/usr/bin/find` | `sudo find . -exec /bin/sh \; -quit` |
| `/usr/bin/tar` | `sudo tar -cf /dev/null /dev/null --checkpoint=1 --checkpoint-action=exec=/bin/sh` |
| `/usr/bin/awk`, `perl`, `python3`, `ruby` | `system("/bin/sh")` |
| `/usr/bin/systemctl` (sin restricciones) | Escribir una unidad con `ExecStart=/bin/sh`, `systemctl link` + `start` |
| `/usr/bin/journalctl` sin reinicio del entorno del paginador | escape del paginador (`!sh`) — mitigar con `SYSTEMD_PAGER=cat` o `--no-pager` |
| `/bin/cp`, `/usr/bin/dd`, `/usr/bin/tee` | Sobrescribir `/etc/shadow` o `/etc/sudoers` |

Catálogo: **GTFOBins** (`https://gtfobins.github.io/`) es la referencia; tratalo como la copia que tiene el adversario de tu archivo sudoers. Las mitigaciones son `NOEXEC:` (bloquea `exec()` desde el programa permitido mediante un shim `LD_PRELOAD` — efectivo solo para binarios enlazados dinámicamente), `sudoedit` en lugar de conceder un editor, y preferir scripts envoltorio hechos a medida por sobre herramientas de propósito general.

**Los comodines no hacen lo que parecen hacer.** La coincidencia de comandos de `sudo` usa globs al estilo `fnmatch(3)` donde `*` también coincide con `/`:

```sudoers
# BROKEN — intends "restart any service"
alice ALL = (root) NOPASSWD: /usr/bin/systemctl restart *
```
```
$ sudo systemctl restart ../../../home/alice/evil.service   # matched by `*`
```

```sudoers
# BROKEN — intends "edit files under /etc/nginx"
alice ALL = (root) NOPASSWD: /usr/bin/vim /etc/nginx/*
```
```
$ sudo vim /etc/nginx/../../etc/shadow                       # matched
```

Enumerá comandos exactos, o validá los argumentos dentro de un script envoltorio propiedad de root que el usuario no pueda modificar. Si tenés que usar globs, mantené el comodín fuera de cualquier posición donde `..` o `/` cambien el destino.

**Un envoltorio escribible es un shell root.** Si a `deploy-release.sh` se le concede `NOPASSWD` y es escribible por el usuario `deploy`, la concesión es `(root) ALL`. Los scripts envoltorio deben ser `root:root 0755` y vivir fuera de cualquier directorio escribible por usuarios.

**`Defaults targetpw` / `runaspw` invierte el modelo de credenciales** — hace que sudo pida la contraseña del usuario *destino*. Combinado con `%users ALL=(ALL) ALL`, así emulaban históricamente algunas distribuciones a `su`. Sabé que existe; rara vez es lo que querés, porque reintroduce el secreto compartido.

**CVEs de sudo conocidos de alta severidad** (todos corregidos; la lección es que sudo es código privilegiado de análisis sintáctico y debe parchearse rápido):

| CVE | Clase | Efecto |
|---|---|---|
| CVE-2019-14287 | Análisis del UID de runas | Con una regla `(ALL, !root)`, `sudo -u#-1 <cmd>` se ejecutaba igual como UID 0 |
| CVE-2021-3156 ("Baron Samedit") | Desbordamiento de heap en el desescapado de argv de `sudoedit` | Root local **para cualquier usuario local**, sin necesidad de entrada en sudoers. Afectó a 1.8.2–1.8.31p2 y 1.9.0–1.9.5p1 |
| CVE-2023-22809 | Manejo de `EDITOR` en `sudoedit` | `EDITOR='vi -- /etc/sudoers'` escribía en un archivo arbitrario; corregido en 1.9.12p2 |

```
$ sudo --version | head -1
Sudo version 1.9.15p5
```

Seguí los avisos en `https://www.sudo.ws/security/advisories/`. Fijá una versión mínima en tu línea base de cumplimiento y alertá sobre los nodos por debajo de ella.

---

## 4. Ciclo de vida de cuentas y contraseñas

### 4.1 `/etc/shadow` — el registro detrás de cada comando de esta sección

`/etc/passwd` es legible por todos y no contiene ningún secreto (el campo 2 es `x`). `/etc/shadow` tiene modo `0000` o `0640 root:shadow` y contiene nueve campos separados por dos puntos:

```
$ sudo getent shadow alice
alice:$y$j9T$Xn2cW1qL8vB4mR7pKdZ0e.$Qv3...:20678:1:90:14:14::
```

| # | Campo | Valor de arriba | Significado | Flag de `chage` | Flag de `passwd` |
|---|---|---|---|---|---|
| 1 | Nombre de login | `alice` | — | — | — |
| 2 | Hash | `$y$...` | `$y$` yescrypt, `$6$` sha512crypt, `$2b$` bcrypt. Prefijo `!`/`!!` = bloqueada, `*` = nunca login por contraseña, vacío = **no requiere contraseña** | — | `-l` / `-u` |
| 3 | Último cambio | `20678` | Días desde 1970-01-01. `0` = debe cambiarla en el próximo login | `-d` | `-e` (expirar ahora) |
| 4 | MIN | `1` | Días antes de que la contraseña *pueda* cambiarse de nuevo — impide que un usuario vuelva enseguida a la anterior | `-m` | `-n` |
| 5 | MAX | `90` | Días tras los cuales la contraseña *debe* cambiarse | `-M` | `-x` |
| 6 | WARN | `14` | Días de aviso antes de la expiración | `-W` | `-w` |
| 7 | INACTIVE | `14` | Días de gracia tras la expiración durante los cuales el login todavía funciona pero fuerza un cambio; después la cuenta se deshabilita | `-I` | `-i` |
| 8 | EXPIRE | *(vacío)* | Expiración absoluta de la cuenta, días desde epoch. Independiente de la contraseña | `-E` | — |
| 9 | Reservado | *(vacío)* | Sin uso | — | — |

Conversión de fechas, que vas a necesitar al leer una entrada cruda de shadow:

```
$ date -d "1970-01-01 + 20678 days" +%F
2026-08-12
$ echo $(( ($(date +%s) / 86400) ))
20693
```

### 4.2 Establecer y cambiar contraseñas

```
$ passwd                                   # change your own
Changing password for user alice.
Current password:
New password:
Retype new password:
passwd: all authentication tokens updated successfully.

$ sudo passwd bob                          # change another user's (root only)
$ sudo passwd -S bob                       # status
bob P 08/12/2026 1 90 14 14

$ sudo passwd -Sa | column -t              # every account
root    L  01/15/2026  0  99999  7  -1
daemon  L  01/15/2026  0  99999  7  -1
alice   P  08/12/2026  1  90     14 14
bob     P  08/12/2026  1  90     14 14
svc_app NP 07/03/2026  0  99999  7  -1
deploy  L  07/03/2026  0  99999  7  -1
```

La columna de estado: `P` = contraseña utilizable, `L` = bloqueada, `NP` = **sin contraseña alguna**. Un `NP` en cualquier cuenta es un hallazgo — esa cuenta inicia sesión con una cadena vacía.

Operaciones del ciclo de vida:

```
$ sudo passwd -l bob          # lock: prepend '!' to the hash
$ sudo passwd -u bob          # unlock
$ sudo passwd -e bob          # force a change at next login (sets field 3 to 0)
$ sudo passwd -d bob          # DELETE the password — leaves an empty field. Never do this.
$ sudo usermod -L bob         # equivalent lock
$ sudo usermod -U bob         # equivalent unlock
```

Configuración no interactiva, para aprovisionamiento:

```
$ echo 'bob:S0me-Long-Passphrase' | sudo chpasswd

# Preferred: never let a cleartext password reach a command line or a log.
$ HASH=$(openssl passwd -6 -stdin <<< 'S0me-Long-Passphrase')
$ echo "bob:${HASH}" | sudo chpasswd -e

$ mkpasswd --method=yescrypt        # from the whois/debian package; prompts, no argv leak
Password:
$y$j9T$K1sT9pQ.../...
```

> **El detalle más trascendente de este objetivo:** `passwd -l` y `usermod -L` deshabilitan **solo** la autenticación por contraseña. Un usuario con una clave pública SSH en `~/.ssh/authorized_keys` sigue iniciando sesión. Para deshabilitar realmente una cuenta:
>
> ```
> $ sudo usermod -L bob                                    # lock the password
> $ sudo chage -E "$(date -d yesterday +%F)" bob           # expire the account (PAM account phase)
> $ sudo usermod -s /usr/sbin/nologin bob                  # no shell
> $ sudo pkill -KILL -u bob                                # terminate live sessions
> ```
>
> Usá una fecha pasada explícita con `-E`; el valor literal `0` es ambiguo entre versiones de shadow-utils (puede leerse como "sin establecer"). `chage -E -1` significa *nunca expirar*.

### 4.3 `chage` — envejecimiento de contraseñas

```
$ sudo chage -l alice
Last password change                                    : Aug 12, 2026
Password expires                                        : Nov 10, 2026
Password inactive                                       : Nov 24, 2026
Account expires                                         : never
Minimum number of days between password change          : 1
Maximum number of days between password change          : 90
Number of days of warning before password expires       : 14
```

```
$ sudo chage -m 1 -M 90 -W 14 -I 14 alice          # the standard policy, non-interactively
$ sudo chage -E 2027-03-31 contractor              # hard account expiry for a fixed-term account
$ sudo chage -d 0 newhire                          # force a password change at first login
$ sudo chage -M -1 svc_app                         # disable aging (service account; see below)
$ sudo chage alice                                 # interactive form
Changing the aging information for alice
Enter the new value, or press ENTER for the default
        Minimum Password Age [1]:
        Maximum Password Age [90]:
        Last Password Change (YYYY-MM-DD) [2026-08-12]:
        Password Expiration Warning [14]:
        Password Inactive [14]:
        Account Expiration Date (YYYY-MM-DD) [-1]:
```

**La política de envejecimiento para cuentas de servicio es un compromiso real de producción:**

| Enfoque | Consecuencia |
|---|---|
| Aplicar la política humana (`-M 90`) a cuentas de servicio | Los trabajos por lotes fallan silenciosamente el día 91 sin ningún prompt interactivo al que responder. El clásico aviso de las 03:00. |
| `chage -M -1` (sin envejecimiento) en cuentas de servicio | Correcto — **siempre que** la cuenta no tenga contraseña alguna (`!` en shadow) y se autentique por clave o se ejecute como un `User=` de systemd sin ruta de login. |
| Poner el shell en `/usr/sbin/nologin` y bloquear la contraseña | Correcto y estándar: la cuenta no puede iniciar sesión, así que el envejecimiento carece de sentido. |

La comprobación declarativa es: *¿tiene esta cuenta una ruta de login interactiva?* Si sí, envejecela. Si no, bloqueala y deshabilitá el envejecimiento.

### 4.4 Valores predeterminados para cuentas nuevas: `/etc/login.defs` y `/etc/default/useradd`

```ini
# /etc/login.defs  (excerpt — applies at useradd/passwd time)
PASS_MAX_DAYS   90
PASS_MIN_DAYS   1
PASS_WARN_AGE   14

UID_MIN         1000
UID_MAX         60000
SYS_UID_MIN     201
SYS_UID_MAX     999

CREATE_HOME     yes
UMASK           027           # 0750 dirs / 0640 files — not the permissive 022 default
USERGROUPS_ENAB yes

ENCRYPT_METHOD  YESCRYPT
YESCRYPT_COST_FACTOR 7
# For SHA512 systems instead:
# ENCRYPT_METHOD SHA512
# SHA_CRYPT_MIN_ROUNDS 640000

LOGIN_RETRIES   3
LOGIN_TIMEOUT   60
FAILLOG_ENAB    yes
LOG_UNKFAIL_ENAB no          # do NOT log unknown usernames: mistyped passwords land in the log
```

```
$ useradd -D
GROUP=100
HOME=/home
INACTIVE=14
EXPIRE=
SHELL=/bin/bash
SKEL=/etc/skel
CREATE_MAIL_SPOOL=no

$ sudo useradd -D -f 14                    # set the default INACTIVE for new accounts
```

> **Detalle:** los valores de `login.defs` aplican **solo** a las cuentas creadas después del cambio. Editar `PASS_MAX_DAYS` no hace nada sobre los usuarios existentes. Remediar una flota existente requiere un barrido explícito con `chage` — la tarea de Ansible de §8 hace exactamente eso.

### 4.5 Calidad de contraseñas y bloqueo (PAM) — más allá del examen, obligatorio en producción

`chage` controla *cuándo* debe cambiar una contraseña. No dice nada sobre *qué* puede ser la nueva contraseña, ni nada sobre fuerza bruta. Ambas cosas viven en PAM.

```ini
# /etc/security/pwquality.conf
minlen      = 14
minclass    = 3
maxrepeat   = 3
maxsequence = 4
dictcheck   = 1
usercheck   = 1
enforcing   = 1
retry       = 3
# Credit-based scoring is legacy; minclass expresses the intent more clearly.
dcredit     = 0
ucredit     = 0
lcredit     = 0
ocredit     = 0
```

```ini
# /etc/security/faillock.conf   (pam_faillock — replaces the removed pam_tally2)
deny             = 5
fail_interval    = 900
unlock_time      = 900
even_deny_root
root_unlock_time = 60
audit
silent
```

```
$ faillock --user alice
alice:
When                Type  Source                                           Valid
2026-08-31 12:11:04 RHOST 10.20.4.9                                            V
2026-08-31 12:11:09 RHOST 10.20.4.9                                            V

$ sudo faillock --user alice --reset
```

No edites a mano la pila PAM; usá la herramienta de la distribución, o el cambio será revertido en la próxima ejecución de `authselect`/`pam-auth-update`:

```
$ sudo authselect select sssd with-faillock with-pwquality --force   # RHEL/Fedora
$ sudo pam-auth-update                                                # Debian/Ubuntu
```

---

## 5. Límites sobre inicios de sesión, procesos y memoria

### 5.1 Las tres capas de aplicación

Esta es la sección donde el modelo del examen y la realidad de producción divergen con más nitidez.

| Capa | Se configura en | La aplica | Se aplica a | Granularidad | Sobrevive al reinicio |
|---|---|---|---|---|---|
| **`ulimit` (shell)** | `ulimit -n 4096` en un shell o script de perfil | `setrlimit(2)`, heredado por los hijos | Solo el shell actual y sus descendientes | Por proceso | No |
| **`/etc/security/limits.conf`, `limits.d/*.conf`** | Archivo declarativo | `pam_limits.so` en la pila de sesión de PAM | Cualquier proceso iniciado a través de una **sesión PAM** (login, sshd, su, sudo, cron con `pam_limits`) | Por usuario / por grupo / por proceso | Sí |
| **Directivas de unidad systemd** | `LimitNOFILE=`, `TasksMax=`, `MemoryMax=` | systemd, vía `setrlimit` + cgroup v2 | El cgroup del servicio, todos sus procesos en conjunto | Por unidad / por slice | Sí |
| **cgroup v2 directamente** | `/sys/fs/cgroup/.../memory.max` | Kernel | El cgroup | Por cgroup, agregado | No (salvo vía systemd) |

> **La falla que le cuesta una noche a la gente:** `limits.conf` **no tiene absolutamente ningún efecto sobre un servicio systemd**. `pam_limits` corre durante una sesión PAM; `systemd` arranca servicios sin ninguna. Subir `nofile` en `limits.conf` y reiniciar PostgreSQL no cambia nada. El servicio necesita `LimitNOFILE=` en su unidad. Cada ticket de "subí el límite y no se aplicó" es esto.

### 5.2 `ulimit`

`ulimit` es un **builtin del shell** (`help ulimit`, no `man ulimit` — la página de manual que obtenés es la de `setrlimit(2)`/`bash`). Cada recurso tiene un límite **blando** (el valor aplicado, elevable por el usuario hasta el límite duro) y un límite **duro** (el techo; **un proceso sin privilegios solo puede bajarlo, nunca subirlo — de forma irreversible para ese árbol de procesos**).

```
$ ulimit -a
real-time non-blocking time  (microseconds, -R) unlimited
core file size              (blocks, -c) 0
data seg size               (kbytes, -d) unlimited
scheduling priority                 (-e) 0
file size                   (blocks, -f) unlimited
pending signals                     (-i) 63256
max locked memory           (kbytes, -l) 8192
max memory size             (kbytes, -m) unlimited
open files                          (-n) 1024
pipe size                (512 bytes, -p) 8
POSIX message queues         (bytes, -q) 819200
real-time priority                  (-r) 0
stack size                  (kbytes, -s) 8192
cpu time                   (seconds, -t) unlimited
max user processes                  (-u) 63256
virtual memory              (kbytes, -v) unlimited
file locks                          (-x) unlimited
```

```
$ ulimit -Hn          # hard limit for open files
524288
$ ulimit -Sn          # soft limit
1024
$ ulimit -n 8192      # raise the SOFT limit (allowed: 8192 <= 524288)
$ ulimit -n
8192
$ ulimit -Hn 4096     # lower the HARD limit
$ ulimit -Hn 8192     # try to raise it back
bash: ulimit: open files: cannot modify limit: Operation not permitted
```

| Flag | Recurso | Ítem de `limits.conf` | Uso típico en producción |
|---|---|---|---|
| `-n` | Máximo de descriptores de archivo abiertos | `nofile` | El que más vas a cambiar; los sockets cuentan como fds |
| `-u` | Máximo de procesos de usuario (por **UID real**, a nivel de sistema) | `nproc` | Contención de fork bombs |
| `-v` | Máximo espacio de direcciones virtual (KiB) | `as` | Tope de memoria burdo; hostil con JVMs y con cualquier cosa que use grandes reservas `mmap` |
| `-m` | Máximo RSS (KiB) | `rss` | **No se aplica en Linux moderno** — usá cgroups |
| `-s` | Tamaño máximo de pila (KiB) | `stack` | Recursión profunda; demasiado grande perjudica a procesos con muchos hilos |
| `-c` | Tamaño máximo de volcado de núcleo (bloques) | `core` | `0` para impedir que los secretos lleguen al disco; distinto de cero cuando necesitás el volcado |
| `-f` | Tamaño máximo de archivo que un proceso puede crear (bloques) | `fsize` | Contención de logs desbocados |
| `-l` | Máxima memoria bloqueada en RAM (KiB) | `memlock` | Requerido por bases de datos que usan `mlock`, y por RDMA |
| `-t` | Máximo de segundos de CPU | `cpu` | Guardia de trabajos por lotes; envía `SIGXCPU` |
| `-i` | Señales pendientes | `sigpending` | Rara vez se ajusta |
| `-x` | Bloqueos de archivo | `locks` | Rara vez se ajusta |
| `-H` / `-S` | Operar sobre duro / blando | — | El predeterminado al *establecer* es ambos; al *leer*, el blando |

### 5.3 `/etc/security/limits.conf`

Cuatro campos separados por espacios en blanco:

```
<domain>    <type>    <item>    <value>
```

| Campo | Valores aceptados |
|---|---|
| `domain` | `username`, `@groupname`, `*` (predeterminado para todos los que **no** coincidan de otro modo), `%group` (maxlogins por grupo), `uid`, `@gid`, rango de uid como `1000:2000` |
| `type` | `soft`, `hard`, `-` (ambos) |
| `item` | `core fsize data stack rss nofile nproc as maxlogins maxsyslogins priority locks sigpending msgqueue nice rtprio memlock` |
| `value` | Un número, o `unlimited` / `infinity` / `-1` |

```ini
# /etc/security/limits.d/50-baseline.conf
#
# Matching is NOT last-wins and NOT first-wins uniformly: pam_limits applies the
# most specific matching domain. An explicit username beats @group, which beats *.
# Files in limits.d are read in lexical order AFTER limits.conf.

# Fleet default: contain a fork bomb, keep core dumps off disk.
*               soft    nproc           2048
*               hard    nproc           4096
*               soft    nofile          4096
*               hard    nofile          16384
*               -       core            0
*               hard    maxlogins       10

# Interactive engineers need headroom for tooling.
@sre            soft    nofile          16384
@sre            hard    nofile          65536
@sre            soft    nproc           8192
@sre            hard    nproc           16384

# Database service account: file descriptors and locked memory.
postgres        soft    nofile          65536
postgres        hard    nofile          131072
postgres        -       memlock         unlimited
postgres        -       nproc           unlimited

# Untrusted batch tenants: hard aggregate ceilings.
@batch          hard    nproc           256
@batch          hard    nofile          2048
@batch          hard    cpu             60
@batch          hard    as              4194304
@batch          -       maxlogins       2

# Shared shell host: one session per contractor, no lingering.
@contractors    -       maxlogins       1
```

La aplicación requiere `pam_limits.so` en la pila de sesión:

```
$ grep -r pam_limits /etc/pam.d/
/etc/pam.d/system-auth:session     required      pam_limits.so
/etc/pam.d/password-auth:session   required      pam_limits.so
/etc/pam.d/su:session              required      pam_limits.so
/etc/pam.d/runuser:session         required      pam_limits.so
```

Si falta `pam_limits.so` en la pila que usa una ruta de entrada determinada, esa ruta no recibe límites. `sshd` usa `password-auth`/`common-session`; `login` usa `system-auth`; `cron` usa `/etc/pam.d/crond`. Verificá por ruta, no globalmente.

> **`nproc` cuenta por UID real en todo el sistema,** no por sesión. Un usuario con `nproc 256` que ya ejecuta 250 procesos en otra sesión SSH verá fallar el próximo `fork()` en *esta*. Esa asimetría es la razón por la que `TasksMax=` (un límite del controlador pids de cgroup, acotado a la unidad) es la mejor herramienta para servicios.

### 5.4 systemd — la capa que realmente gobierna los servicios

```ini
# /etc/systemd/system/api.service
[Unit]
Description=Public API
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=apiuser
Group=apiuser
ExecStart=/usr/local/bin/api --config /etc/api/config.yaml
Restart=on-failure
RestartSec=5s

# --- rlimits: the systemd equivalent of limits.conf, and the ONLY one that
#     applies to this process, because systemd does not open a PAM session.
LimitNOFILE=65536
LimitNPROC=4096
LimitCORE=0
LimitMEMLOCK=64M
LimitSTACK=8M

# --- cgroup v2 controls: aggregate, hierarchical, and observable.
TasksMax=512
MemoryHigh=1.5G          # soft: reclaim pressure begins here
MemoryMax=2G             # hard: the cgroup OOM killer fires here
MemorySwapMax=0
CPUQuota=200%            # two cores' worth
CPUWeight=100
IOWeight=100

# --- privilege containment: this is the SUID discussion from §2, per service.
NoNewPrivileges=yes
RestrictSUIDSGID=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
ProtectProc=invisible
RestrictNamespaces=yes
RestrictRealtime=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
ReadWritePaths=/var/lib/api /var/log/api
StateDirectory=api
LogsDirectory=api

[Install]
WantedBy=multi-user.target
```

Verificación y medición:

```
$ systemctl show api.service -p LimitNOFILE -p TasksMax -p MemoryMax
LimitNOFILE=65536
TasksMax=512
MemoryMax=2147483648

$ systemctl status api.service | head -12
● api.service - Public API
     Loaded: loaded (/etc/systemd/system/api.service; enabled; preset: disabled)
     Active: active (running) since Sun 2026-08-30 04:11:52 -03; 1 day 8h ago
   Main PID: 1841 (api)
      Tasks: 37 (limit: 512)
     Memory: 812.4M (high: 1.5G, max: 2.0G available: 1.2G)
        CPU: 4h 21min 8.114s
     CGroup: /system.slice/api.service
             └─1841 /usr/local/bin/api --config /etc/api/config.yaml

$ cat /proc/1841/limits | grep -E 'Max open|Max processes'
Max open files            65536                65536                files
Max processes             4096                 4096                 processes

$ systemd-cgtop -1 /system.slice/api.service
CGroup                    Tasks   %CPU   Memory  Input/s Output/s
/system.slice/api.service    37    12.4   812.4M        -        -

$ systemd-analyze security api.service | tail -3
→ Overall exposure level for api.service: 1.9 OK 🙂
```

Valores predeterminados a nivel de flota, para fijar la política una vez en lugar de por unidad:

```ini
# /etc/systemd/system.conf.d/10-limits.conf
[Manager]
DefaultLimitNOFILE=8192:524288      # soft:hard
DefaultLimitNPROC=4096:16384
DefaultLimitCORE=0
DefaultTasksMax=4096
```

```ini
# /etc/systemd/user.conf.d/10-limits.conf   — applies to user@UID.service sessions
[Manager]
DefaultLimitNOFILE=4096:65536
DefaultTasksMax=1024
```

```ini
# /etc/systemd/system/user-.slice.d/50-batch-tenant.conf
# Caps ALL processes of ANY logged-in user, aggregate, in one place.
[Slice]
TasksMax=1024
MemoryMax=8G
CPUQuota=400%
```

Techos del kernel que acotan todo lo anterior — no podés poner `nofile` más alto que `fs.nr_open`:

```ini
# /etc/sysctl.d/60-limits.conf
fs.file-max = 2097152
fs.nr_open  = 1048576
kernel.pid_max = 4194304
kernel.threads-max = 512000
```

```
$ sudo sysctl --system
$ sysctl fs.nr_open fs.file-max
fs.nr_open = 1048576
fs.file-max = 2097152
$ cat /proc/sys/fs/file-nr
14208	0	2097152
```

### 5.5 Limitar los inicios de sesión en sí

```ini
# /etc/security/limits.d/60-logins.conf
@contractors    -    maxlogins       1      # concurrent sessions for one user
*               -    maxsyslogins    50     # concurrent logins on the whole system
```

```ini
# /etc/security/access.conf  — pam_access: WHO may log in, from WHERE
+ : root : LOCAL
+ : @sre : 10.20.0.0/16
+ : deploy : 10.20.9.14
- : ALL : ALL
```

```
# /etc/nologin — while this file exists, pam_nologin blocks all non-root logins
$ echo "Maintenance window until 04:00 UTC. Contact #sre-oncall." | sudo tee /etc/nologin
$ sudo rm /etc/nologin
```

```
$ sudo loginctl enable-linger alice     # allow alice's user services to persist after logout
$ sudo loginctl disable-linger alice    # and to be killed on logout (the hardened default)
```

---

## 6. Descubrir puertos abiertos y exposición de red

### 6.1 Local frente a remoto: dos preguntas distintas

Dos preguntas que la gente confunde, con herramientas distintas y respuestas distintas:

- **"¿En qué está escuchando este host?"** — se responde *en* el host, con autoridad, desde el kernel: `ss`, `netstat`, `lsof`, `fuser`. Te da el proceso, el usuario y la dirección de enlace.
- **"¿Qué es alcanzable desde allá?"** — se responde *desde* la red: `nmap`. Esto es lo que ve un atacante, y difiere de la primera respuesta exactamente en tu firewall, tu security group y tu NAT.

Un servicio enlazado a `0.0.0.0:9100` que `nmap` informa como `filtered` desde otra subred está correctamente protegido por firewall. Un servicio enlazado a `127.0.0.1:9100` que `nmap` informa como `open` desde otra subred significa que algo lo está haciendo proxy y no lo sabías. **Necesitás ambas lecturas para tener una afirmación de exposición.**

### 6.2 Enumeración local

`netstat` (paquete `net-tools`) está obsoleto y a menudo ausente en una instalación mínima; analiza `/proc/net/*` como texto. `ss` (paquete `iproute2`) consulta al kernel por la interfaz netlink `sock_diag` — órdenes de magnitud más rápido en un host con 100k sockets, y expone internos de TCP que `netstat` no puede ver.

| Herramienta | Fuente | Muestra PID | Velocidad con 100k sockets | Notas |
|---|---|---|---|---|
| `netstat -tulpn` | texto de `/proc/net/*` | Sí (como root) | Lento; análisis de texto O(n) por socket para el mapa inodo→PID | **Requerido por el examen.** Obsoleto upstream |
| `ss -tulpn` | netlink `sock_diag` | Sí (como root) | Rápido | Predeterminado en producción. Soporta filtros de estado y expresiones estilo BPF |
| `lsof -i` | recorrido de `/proc/*/fd` | Sí | Lento; abre la tabla de fd de cada proceso | Mejor cuando querés *archivos y sockets juntos* para un proceso |
| `fuser -n tcp 443` | `/proc` | Sí | Rápido para un puerto | Responde "quién tiene este puerto" y puede matarlos con `-k` |
| `nmap localhost` | La pila de red | No | — | Solo ve lo que permite el camino de loopback; no es una herramienta de inventario |

```
$ sudo ss -tulpn
Netid State  Recv-Q Send-Q      Local Address:Port    Peer Address:Port  Process
udp   UNCONN 0      0           127.0.0.53%lo:53           0.0.0.0:*      users:(("systemd-resolve",pid=612,fd=13))
udp   UNCONN 0      0                 0.0.0.0:68           0.0.0.0:*      users:(("dhclient",pid=744,fd=6))
tcp   LISTEN 0      4096        127.0.0.53%lo:53           0.0.0.0:*      users:(("systemd-resolve",pid=612,fd=14))
tcp   LISTEN 0      128               0.0.0.0:22           0.0.0.0:*      users:(("sshd",pid=812,fd=3))
tcp   LISTEN 0      511               0.0.0.0:80           0.0.0.0:*      users:(("nginx",pid=1102,fd=6),("nginx",pid=1101,fd=6))
tcp   LISTEN 0      511               0.0.0.0:443          0.0.0.0:*      users:(("nginx",pid=1102,fd=7),("nginx",pid=1101,fd=7))
tcp   LISTEN 0      244             127.0.0.1:5432         0.0.0.0:*      users:(("postgres",pid=1330,fd=5))
tcp   LISTEN 0      4096              0.0.0.0:9100         0.0.0.0:*      users:(("node_exporter",pid=1455,fd=3))
tcp   LISTEN 0      128                  [::]:22              [::]:*      users:(("sshd",pid=812,fd=4))
```

```
$ sudo netstat -tulpn        # exam form, identical intent
Active Internet connections (only servers)
Proto Recv-Q Send-Q Local Address       Foreign Address   State    PID/Program name
tcp        0      0 0.0.0.0:22          0.0.0.0:*         LISTEN   812/sshd: /usr/sbin
tcp        0      0 0.0.0.0:80          0.0.0.0:*         LISTEN   1101/nginx: master
tcp        0      0 127.0.0.1:5432      0.0.0.0:*         LISTEN   1330/postgres
tcp6       0      0 :::22               :::*              LISTEN   812/sshd: /usr/sbin
udp        0      0 127.0.0.53:53       0.0.0.0:*                  612/systemd-resolve
```

Las letras de los flags — memorizalas, se preguntan directamente:

| Flag | `netstat` | `ss` | Significado |
|---|---|---|---|
| `-t` | ✓ | ✓ | TCP |
| `-u` | ✓ | ✓ | UDP |
| `-x` | ✓ | ✓ | Sockets de dominio UNIX |
| `-l` | ✓ | ✓ | Solo sockets en escucha |
| `-a` | ✓ | ✓ | Todos los sockets (en escucha **y** establecidos) |
| `-p` | ✓ | ✓ | Mostrar el proceso propietario (necesita root para sockets de otros usuarios) |
| `-n` | ✓ | ✓ | Numérico — sin resolución DNS ni de `/etc/services`. **Usalo siempre**; un timeout de DNS inverso cuelga el comando |
| `-r` | ✓ | — | Tabla de rutas (`ss` no tiene equivalente; usá `ip route`) |
| `-i` | ✓ | — | Estadísticas de interfaz (usá `ip -s link`) |
| `-s` | ✓ | ✓ | Estadísticas resumidas |
| `-c` | ✓ | — | Refresco continuo |

Capacidades de `ss` sin equivalente en `netstat`:

```
$ ss -tan state established '( dport = :443 or sport = :443 )'
$ ss -tn dst 10.20.4.0/24
$ ss -ti sport = :443 | head -4          # per-socket TCP internals: cwnd, rtt, retrans
$ ss -tlpn 'sport = :80'
$ ss -s
Total: 284
TCP:   47 (estab 21, closed 13, orphaned 0, timewait 12)

Transport Total     IP        IPv6
RAW       1         0         1
UDP       6         4         2
TCP       34        28        6
INET      41        32        9
FRAG      0         0         0
```

`lsof` y `fuser`, para la pregunta de "quién está reteniendo este puerto":

```
$ sudo lsof -nP -i TCP -sTCP:LISTEN
COMMAND       PID          USER  FD  TYPE DEVICE SIZE/OFF NODE NAME
systemd-r     612 systemd-resolve  14u IPv4  22104      0t0  TCP 127.0.0.53:53 (LISTEN)
sshd          812          root   3u IPv4  23117      0t0  TCP *:22 (LISTEN)
nginx        1101          root   6u IPv4  27441      0t0  TCP *:80 (LISTEN)
nginx        1102      www-data   6u IPv4  27441      0t0  TCP *:80 (LISTEN)
postgres     1330      postgres   5u IPv4  29005      0t0  TCP 127.0.0.1:5432 (LISTEN)

$ sudo lsof -nP -i :8080
COMMAND   PID   USER  FD  TYPE DEVICE SIZE/OFF NODE NAME
java     3311 tomcat  42u IPv6  51882      0t0  TCP *:8080 (LISTEN)
java     3311 tomcat  63u IPv6  93117      0t0  TCP 10.20.4.11:8080->10.20.4.9:51244 (ESTABLISHED)

$ sudo lsof -u alice          # every file alice has open
$ sudo lsof +D /var/log       # everything open under a directory (slow but definitive)
$ sudo lsof /dev/sdb1         # who is preventing this unmount

$ sudo fuser -v -n tcp 8080
                     USER        PID ACCESS COMMAND
8080/tcp:            tomcat     3311 F.... java

$ sudo fuser -k -n tcp 8080   # SIGKILL whatever holds it — destructive, confirm first
$ sudo fuser -k -TERM -n tcp 8080     # SIGTERM instead, the humane form
$ sudo fuser -vm /var/lib/data        # who is using this MOUNT POINT (before umount)
```

Leer correctamente una dirección de enlace es donde se aciertan o se pierden los juicios de exposición:

| Dirección local | Alcanzable desde |
|---|---|
| `127.0.0.1:5432` | Solo este host (loopback) |
| `0.0.0.0:80` | Todas las direcciones IPv4 en todas las interfaces |
| `[::]:22` | Todas las direcciones IPv6; **también IPv4** si `net.ipv6.bindv6only=0` (el valor predeterminado) |
| `10.20.4.11:9100` | Solo a través de esa dirección de interfaz específica |
| `*:8080` (lsof) | Todas las direcciones, ambas familias |

### 6.3 `nmap` — la vista externa

> **Autorización.** Escanear los puertos de un host que no operás es, en muchas jurisdicciones, acceso no autorizado. Escaneá solo activos que te pertenezcan o para los que tengas autorización escrita de prueba, y dejá registro de esa autorización. En una flota interna, la lista de objetivos del escaneo debería provenir del mismo inventario que impulsa tu gestión de configuración, para que el alcance sea auditable.

```
$ sudo nmap -sS -p- -T4 --open -oA scans/web01-$(date +%F) 10.20.4.11
Starting Nmap 7.94 ( https://nmap.org ) at 2026-08-31 12:04 -03
Nmap scan report for web01.internal (10.20.4.11)
Host is up (0.00042s latency).
Not shown: 65530 closed tcp ports (reset)

PORT     STATE SERVICE
22/tcp   open  ssh
80/tcp   open  http
443/tcp  open  https
9100/tcp open  jetdirect
9200/tcp open  wap-wsp

Nmap done: 1 IP address (1 host up) scanned in 4.71 seconds
```

Esa salida es un hallazgo, no un informe. `9100` es `node_exporter` (nmap adivinó "jetdirect" a partir de `/usr/share/nmap/nmap-services`, que mapea números de puerto a nombres *convencionales* y se equivoca con frecuencia). `9200` es un Elasticsearch que nadie sabía que estaba escuchando en una dirección enrutable. Confirmalo con detección de versión:

```
$ sudo nmap -sV -p 9100,9200 --version-intensity 5 10.20.4.11
PORT     STATE SERVICE VERSION
9100/tcp open  http    Prometheus node_exporter
9200/tcp open  http    Elasticsearch REST API 8.13.2 (name: web01; cluster: logs-prod)

Service detection performed. Please report any incorrect results at https://nmap.org/submit/ .
```

**Tipos de escaneo y para qué sirve cada uno:**

| Flag | Nombre | Privilegio | Mecanismo | Cuándo usarlo |
|---|---|---|---|---|
| `-sS` | SYN / semiabierto | **root** (raw sockets) | SYN → SYN/ACK → RST; nunca completa el handshake | Predeterminado para un escaneo privilegiado. Rápido, y no aparece en el log de conexiones de la aplicación |
| `-sT` | TCP connect | cualquier usuario | Handshake `connect(2)` completo | La única opción sin privilegios. Más lento, registrado por la aplicación destino |
| `-sU` | UDP | **root** | Datagrama vacío o carga útil de protocolo; infiere a partir del ICMP port-unreachable | Lento y ambiguo (`open\|filtered`) pero es la única forma de ver DNS, NTP, SNMP, syslog |
| `-sN` `-sF` `-sX` | Null / FIN / Xmas | **root** | Combinaciones de flags malformadas; el RFC 793 dice que los puertos cerrados deben responder RST | Inferencia de reglas de firewall. Inútil contra Windows y muchas pilas |
| `-sA` | ACK | **root** | Mapea el filtrado del firewall, no el estado del puerto | Distinguir filtrado con estado de filtrado sin estado |
| `-sn` | Ping scan | cualquiera | Solo descubrimiento de hosts, **sin escaneo de puertos** | Barrido de inventario de una subred |
| `-Pn` | *(modificador)* | cualquiera | Omite el descubrimiento de hosts, asume que está activo | Hosts que descartan ICMP — si no, nmap informa "host down" y no escanea nada |
| `-sV` | Detección de versión | cualquiera | Sondas y coincidencia de firmas de banners | Convertir un número de puerto en una identidad de servicio real |
| `-O` | Detección de SO | **root** | Fingerprinting de la pila TCP/IP | Reconciliación de inventario |
| `-A` | Agresivo | **root** | `-sV -O -sC --traceroute` | Investigación interactiva. **Nunca** de forma programada contra producción |

**Estados de puerto — la distinción que importa tanto en el examen como en producción:**

| Estado | Observado | Significa |
|---|---|---|
| `open` | Se recibió SYN/ACK | Algo está escuchando y aceptando |
| `closed` | Se recibió RST | Host alcanzable, nada escuchando. **El host respondió** — así que no está filtrado por firewall |
| `filtered` | Sin respuesta, o ICMP unreachable | Un firewall descartó la sonda. No se puede saber si algo escucha |
| `unfiltered` | Alcanzable pero estado indeterminado (solo `-sA`) | Pasa el filtro; estado de escucha desconocido |
| `open\|filtered` | Sin respuesta (`-sU`, `-sN/-sF/-sX`) | O bien abierto y silencioso, o bien descartado |
| `closed\|filtered` | Solo en idle scan | Ambiguo |

La distinción entre `closed` y `filtered` es el punto central de la revisión de un escaneo: `Not shown: 65530 closed tcp ports (reset)` significa que tu host está respondiendo con RST en 65530 puertos — el firewall no está descartando, simplemente no hay nada escuchando. Un host correctamente protegido por firewall informa `filtered`, y un escaneo suyo se ve así:

```
$ sudo nmap -sS -p 22,80,443,5432,9200 10.20.4.12
Nmap scan report for db01.internal (10.20.4.12)
Host is up (0.00061s latency).

PORT     STATE    SERVICE
22/tcp   open     ssh
80/tcp   filtered http
443/tcp  filtered https
5432/tcp open     postgresql
9200/tcp filtered wap-wsp
```

Invocaciones prácticas:

```
$ nmap -sn 10.20.4.0/24                          # who is alive on this subnet
$ nmap --top-ports 1000 -T4 10.20.4.11           # the default: 1000 most common
$ sudo nmap -sU --top-ports 50 10.20.4.11        # UDP is slow: bound the port set
$ nmap -p 22,80,443 -iL targets.txt -oG - | grep '/open/'
$ sudo nmap -sS -p- --exclude-ports 9100 -oX scan.xml 10.20.4.0/24
$ nmap --script ssl-enum-ciphers -p 443 web01    # NSE: TLS configuration audit
$ nmap --script vuln -p 443 web01                # NSE vuln category — noisy, authorize first
$ ndiff scans/web01-2026-08-24.xml scans/web01-2026-08-31.xml   # DIFF two scans
```

`ndiff` es la pieza que convierte el escaneo en un control:

```
$ ndiff scans/web01-2026-08-24.xml scans/web01-2026-08-31.xml
-web01.internal (10.20.4.11):
+web01.internal (10.20.4.11):
 Host is up.
 Not shown: 65531 closed ports
 PORT     STATE SERVICE VERSION
 22/tcp   open  ssh     OpenSSH 9.6p1
 80/tcp   open  http    nginx 1.26.0
 443/tcp  open  http    nginx 1.26.0
+9200/tcp open  http    Elasticsearch REST API 8.13.2
```

Formatos de salida: `-oN` normal, `-oX` XML (legible por máquina, lo que consume `ndiff`), `-oG` greppable (obsoleto pero cómodo en una tubería de shell), `-oA <base>` escribe los tres a la vez. Usá siempre `-oA` en escaneos programados — el XML es tu evidencia.

---

## 7. Quién está conectado y quién se conectó

### 7.1 Los archivos de registro

Cuatro bases de datos binarias, históricamente toda la historia:

| Archivo | Escrito por | Leído por | Contenido |
|---|---|---|---|
| `/run/utmp` (`/var/run/utmp`) | `login`, `sshd`, `systemd-logind`, emuladores de terminal | `who`, `w`, `users`, `pinky` | Sesiones **actualmente** abiertas. Volátil — se limpia al reiniciar |
| `/var/log/wtmp` | Los mismos, más `shutdown`/`reboot` | `last` | Inicios y cierres de sesión **históricos**, más registros de arranque |
| `/var/log/btmp` | `login`, `sshd` | `lastb` (**solo root**) | Intentos de login **fallidos** |
| `/var/lib/lastlog/lastlog` o `/var/log/lastlog` | PAM (`pam_lastlog`) | `lastlog` | El login **más reciente** por usuario, un registro de tamaño fijo indexado por UID |

> **Estos no son autoritativos y nunca lo fueron.** Son archivos comunes escritos por procesos de espacio de usuario; un intruso con root los edita. Además están **siendo desaprobados**: systemd 254+ y util-linux 2.40+ pasan a `systemd-logind` más `wtmpdb`/`lastlog2` (SQLite), y varias distribuciones ya vienen con `utmp` deshabilitado. En un host así, `last` no imprime nada y la respuesta vive en el journal. Tratá estos archivos como una conveniencia operativa y a un **sumidero remoto de logs o el subsistema de auditoría** como el registro de verdad.

### 7.2 Conectados actualmente

```
$ who
alice    pts/0        2026-08-31 11:58 (10.20.4.9)
bob      pts/1        2026-08-31 12:03 (10.20.4.22)
root     tty1         2026-08-30 09:14

$ who -a
           system boot  2026-08-10 08:52
           run-level 5  2026-08-10 08:52
LOGIN      tty1         2026-08-10 08:52              621 id=tty1
alice    + pts/0        2026-08-31 11:58   .          3401 (10.20.4.9)
bob      + pts/1        2026-08-31 12:03  00:03       3512 (10.20.4.22)

$ who -b                      # last boot
         system boot  2026-08-10 08:52
$ who -r                      # runlevel
         run-level 5  2026-08-10 08:52
$ who -H -u                   # header + idle time + PID
$ who am i
alice    pts/0        2026-08-31 11:58 (10.20.4.9)

$ users
alice bob root

$ w
 12:41:03 up 21 days,  3:49,  3 users,  load average: 0.42, 0.31, 0.28
USER     TTY      FROM             LOGIN@   IDLE   JCPU   PCPU WHAT
alice    pts/0    10.20.4.9        11:58    0.00s  0.31s  0.02s w
bob      pts/1    10.20.4.22       12:03    3:41   0.09s  0.09s -bash
root     tty1     -                30Aug26  1days  0.04s  0.04s -bash

$ w -h alice                  # no header, one user
$ w -s                        # short: drop JCPU/PCPU
```

Cómo leer `w`: `IDLE` es el tiempo desde que la terminal vio entrada — los `3:41` de bob son una sesión abandonada. `JCPU` es el tiempo de CPU de todos los procesos asociados a ese TTY; `PCPU` es el tiempo de CPU del proceso en `WHAT`. Una sesión con un `JCPU` grande y una terminal inactiva está ejecutando algo desacoplado.

Los comandos están relacionados pero son distintos: `who` lee `utmp` e informa sesiones; `w` lee `utmp` **y** `/proc` e informa sesiones más lo que están haciendo más la carga del sistema; `id` informa las credenciales *del proceso actual*, no sesiones:

```
$ id
uid=1001(alice) gid=1001(alice) groups=1001(alice),10(wheel),992(docker) context=unconfined_u:...
$ id -u; id -g; id -nG
1001
1001
alice wheel docker
$ whoami          # effective username only
alice
$ logname         # the ORIGINAL login name, unchanged by su/sudo
alice
```

`logname` frente a `whoami` es la pregunta de auditoría en miniatura: después de `sudo -i`, `whoami` dice `root` y `logname` dice `alice`. Dentro de un comando invocado por sudo, `$SUDO_USER` lleva la misma información.

La vista nativa de systemd, que funciona cuando `utmp` no:

```
$ loginctl list-sessions
SESSION  UID USER  SEAT  TTY
      3 1001 alice       pts/0
      7 1002 bob         pts/1
      1    0 root  seat0 tty1

3 sessions listed.

$ loginctl session-status 3
3 - alice (1001)
           Since: Sun 2026-08-31 11:58:12 -03; 42min ago
          Leader: 3401 (sshd-session)
          Remote: 10.20.4.9
         Service: sshd; type tty; class user
           State: active
            Unit: session-3.scope
                  ├─3401 "sshd-session: alice [priv]"
                  ├─3409 -bash
                  └─3702 w

$ loginctl list-users
 UID USER  LINGER STATE
1001 alice no     active
1002 bob   no     active

$ sudo loginctl terminate-session 7      # end bob's session
$ sudo loginctl kill-user bob            # end everything bob is running
```

### 7.3 Inicios de sesión históricos

```
$ last -n 8
bob      pts/1        10.20.4.22       Sun Aug 31 12:03   still logged in
alice    pts/0        10.20.4.9        Sun Aug 31 11:58   still logged in
alice    pts/0        10.20.4.9        Sun Aug 31 09:12 - 10:44  (01:32)
deploy   pts/2        10.20.9.14       Sat Aug 30 22:00 - 22:01  (00:00)
root     tty1                          Sat Aug 30 09:14   still logged in
reboot   system boot  6.9.7-200.fc40   Mon Aug 10 08:52   still running
carol    pts/0        10.20.4.31       Sun Aug  9 17:40 - down   (00:22)
shutdown system down  6.9.7-200.fc40   Sun Aug  9 18:02 - 08:52  (14:50)

wtmp begins Sat Aug  1 00:00:01 2026
```

```
$ last -F alice                    # full timestamps with seconds and year
$ last -a                          # hostname in the LAST column (not truncated)
$ last -i                          # numeric IP instead of hostname
$ last -d                          # resolve stored IPs back to names
$ last -x                          # include runlevel and shutdown entries
$ last reboot                      # boot history only
$ last -s yesterday -t today       # time-bounded
$ last -s '2026-08-30 00:00' -t '2026-08-31 00:00' -F
$ last -p 2026-08-30               # who was logged in AT that moment
$ last -f /var/log/wtmp.1          # read a rotated file
$ last pts/0                       # by terminal
```

Intentos fallidos — solo root, porque el archivo filtra contraseñas mal tipeadas ingresadas en el campo de nombre de usuario:

```
$ sudo lastb -n 6 -F -a
admin    ssh:notty    Sun Aug 31 03:14:02 2026 - Sun Aug 31 03:14:02 2026  (00:00)   203.0.113.44
root     ssh:notty    Sun Aug 31 03:14:01 2026 - Sun Aug 31 03:14:01 2026  (00:00)   203.0.113.44
oracle   ssh:notty    Sun Aug 31 03:13:59 2026 - Sun Aug 31 03:13:59 2026  (00:00)   203.0.113.44
alice    pts/1        Sat Aug 30 17:22:10 2026 - Sat Aug 30 17:22:10 2026  (00:00)   10.20.4.9
ubuntu   ssh:notty    Sat Aug 30 02:01:44 2026 - Sat Aug 30 02:01:44 2026  (00:00)   198.51.100.7

btmp begins Sat Aug  1 00:00:03 2026

$ sudo lastb -i | awk '{print $NF}' | sort | uniq -c | sort -rn | head -5
   4471 203.0.113.44
    881 198.51.100.7
     12 10.20.4.9
```

Detección de cuentas obsoletas — el uso de mayor valor de `lastlog`:

```
$ lastlog
Username         Port     From             Latest
root             tty1                      Sat Aug 30 09:14:22 -0300 2026
alice            pts/0    10.20.4.9        Sun Aug 31 11:58:12 -0300 2026
bob              pts/1    10.20.4.22       Sun Aug 31 12:03:41 -0300 2026
carol            pts/0    10.20.4.31       Sun Aug  9 17:40:03 -0300 2026
dave                                       **Never logged in**
svc_backup                                 **Never logged in**

$ lastlog -t 7                     # logged in within the last 7 days
$ lastlog -b 90                    # NOT logged in for 90+ days — the offboarding candidates
$ lastlog -u alice
```

> `lastlog` es un archivo **disperso** indexado por UID. `ls -l` muestra un tamaño aparente enorme; `du` muestra el real. Nunca lo pases por `cat`, y nunca lo copies sin `--sparse=always`.

En un host moderno sin utmp, las mismas preguntas respondidas desde el journal y las nuevas bases de datos:

```
$ journalctl _COMM=sshd --since "24 hours ago" | grep -E 'Accepted|Failed' | tail -5
Aug 31 11:58:12 web01 sshd[3401]: Accepted publickey for alice from 10.20.4.9 port 51244 ssh2: ED25519 SHA256:8Ky...
Aug 31 03:14:02 web01 sshd[2988]: Failed password for invalid user admin from 203.0.113.44 port 39114 ssh2

$ journalctl -u systemd-logind --since today -o cat
New session 3 of user alice.
New session 7 of user bob.
Removed session 5.

$ wtmpdb last -n 5              # util-linux 2.40+ replacement for `last`
$ lastlog2 -b 90                # replacement for `lastlog -b`
```

### 7.4 El rastro autoritativo: auditd

`who`/`last` responden "quién tuvo una sesión". No responden "quién ejecutó qué". `auditd` sí, a nivel de llamada al sistema, y sus registros los escribe un demonio alimentado por el kernel, no el proceso que inicia sesión.

```
# /etc/audit/rules.d/50-privilege.rules
## Every privileged (SUID/SGID) execution — the runtime counterpart of §2's find
-a always,exit -F arch=b64 -S execve -C uid!=euid -F euid=0 -k suid_exec
-a always,exit -F arch=b32 -S execve -C uid!=euid -F euid=0 -k suid_exec
-a always,exit -F arch=b64 -S execve -C gid!=egid -k sgid_exec

## Changes to the privilege configuration itself
-w /etc/sudoers    -p wa -k scope
-w /etc/sudoers.d/ -p wa -k scope
-w /etc/passwd     -p wa -k identity
-w /etc/shadow     -p wa -k identity
-w /etc/group      -p wa -k identity
-w /etc/gshadow    -p wa -k identity
-w /etc/security/limits.conf   -p wa -k limits
-w /etc/security/limits.d/     -p wa -k limits

## Privilege-changing syscalls
-a always,exit -F arch=b64 -S setuid,setgid,setreuid,setregid -F auid>=1000 -F auid!=unset -k privchange

## The login records themselves
-w /var/log/wtmp  -p wa -k session
-w /var/log/btmp  -p wa -k session
-w /run/utmp      -p wa -k session

## Make the ruleset immutable until reboot. Put this LAST.
-e 2
```

```
$ sudo augenrules --load
$ sudo auditctl -s
enabled 2
failure 1
pid 1044
rate_limit 0
backlog_limit 8192
lost 0
backlog 0

$ sudo ausearch -k scope -ts today -i | tail -6
type=CONFIG_CHANGE msg=audit(08/31/2026 10:22:41.117:8891) : op=updated_rules ...
type=SYSCALL msg=audit(08/31/2026 10:22:41.117:8892) : arch=x86_64 syscall=openat
    success=yes exit=3 a0=0xffffff9c ... uid=root auid=alice ses=3 comm=vi
    exe=/usr/bin/vi key=scope

$ sudo aureport --auth --summary -ts this-week
Authentication Report
=====================================
total  acct
=====================================
4471   admin
881    root
14     alice
```

El campo `auid` (UID de login de auditoría) es la razón por la que este es el registro autoritativo: se establece al iniciar sesión, es inmutable para el árbol de procesos (con `--loginuid-immutable`) y **sobrevive a `su` y `sudo`**. `uid=root auid=alice` es la frase "alice hizo esto como root", y ninguna cantidad de `su` intermedio la borra.

---

## 8. Manifiestos de infraestructura completos

### 8.1 Rol de Ansible — la mitad declarativa del bucle de control

```yaml
# roles/host_security/defaults/main.yml
---
sec_password_max_days: 90
sec_password_min_days: 1
sec_password_warn_age: 14
sec_password_inactive: 14
sec_umask: "027"
sec_encrypt_method: "YESCRYPT"

sec_pwquality:
  minlen: 14
  minclass: 3
  maxrepeat: 3
  dictcheck: 1
  usercheck: 1
  enforcing: 1
  retry: 3

sec_faillock:
  deny: 5
  fail_interval: 900
  unlock_time: 900
  even_deny_root: true
  root_unlock_time: 60

sec_limits:
  - { domain: "*",     type: "soft", item: "nproc",     value: "2048" }
  - { domain: "*",     type: "hard", item: "nproc",     value: "4096" }
  - { domain: "*",     type: "soft", item: "nofile",    value: "4096" }
  - { domain: "*",     type: "hard", item: "nofile",    value: "16384" }
  - { domain: "*",     type: "-",    item: "core",      value: "0" }
  - { domain: "*",     type: "hard", item: "maxlogins", value: "10" }
  - { domain: "@sre",  type: "soft", item: "nofile",    value: "16384" }
  - { domain: "@sre",  type: "hard", item: "nofile",    value: "65536" }
  - { domain: "@sre",  type: "soft", item: "nproc",     value: "8192" }
  - { domain: "@sre",  type: "hard", item: "nproc",     value: "16384" }

sec_systemd_default_limits:
  DefaultLimitNOFILE: "8192:524288"
  DefaultLimitNPROC: "4096:16384"
  DefaultLimitCORE: "0"
  DefaultTasksMax: "4096"

# Vendor-approved SUID/SGID set. Anything on the host and not in this list is drift.
sec_suid_baseline:
  - /usr/bin/chage
  - /usr/bin/chfn
  - /usr/bin/chsh
  - /usr/bin/gpasswd
  - /usr/bin/mount
  - /usr/bin/newgrp
  - /usr/bin/passwd
  - /usr/bin/su
  - /usr/bin/sudo
  - /usr/bin/umount
  - /usr/bin/wall
  - /usr/bin/write
  - /usr/bin/ssh-agent
  - /usr/lib/openssh/ssh-keysign
  - /usr/libexec/openssh/ssh-keysign
  - /usr/bin/pkexec
  - /usr/bin/crontab
  - /usr/bin/at

sec_suid_remove: []          # explicit removals, reviewed and approved
sec_scan_schedule: "*-*-* 03:17:00"
```

```yaml
# roles/host_security/tasks/main.yml
---
- name: Gather package facts for provenance checks
  ansible.builtin.package_facts:
    manager: auto
  tags: [always]

# ---------------------------------------------------------------- password policy
- name: Enforce password aging defaults for NEW accounts (login.defs)
  ansible.builtin.lineinfile:
    path: /etc/login.defs
    regexp: "^\\s*#?\\s*{{ item.key }}\\s+"
    line: "{{ item.key }}\t{{ item.value }}"
    state: present
    owner: root
    group: root
    mode: "0644"
  loop:
    - { key: "PASS_MAX_DAYS",  value: "{{ sec_password_max_days }}" }
    - { key: "PASS_MIN_DAYS",  value: "{{ sec_password_min_days }}" }
    - { key: "PASS_WARN_AGE",  value: "{{ sec_password_warn_age }}" }
    - { key: "UMASK",          value: "{{ sec_umask }}" }
    - { key: "ENCRYPT_METHOD", value: "{{ sec_encrypt_method }}" }
    - { key: "LOG_UNKFAIL_ENAB", value: "no" }
  tags: [passwords]

- name: Set the default INACTIVE period for new accounts
  ansible.builtin.command:
    cmd: "useradd -D -f {{ sec_password_inactive }}"
  register: sec_useradd_d
  changed_when: sec_useradd_d.rc == 0
  check_mode: false
  tags: [passwords]

# login.defs does NOT retroactively age existing accounts. Sweep them explicitly,
# skipping system accounts and any account with no usable password.
- name: Enumerate human accounts with an interactive shell
  ansible.builtin.shell:
    cmd: >-
      set -o pipefail;
      awk -F: -v min="{{ sec_uid_min | default(1000) }}"
        '$3 >= min && $3 < 65534 && $7 !~ /(nologin|false|sync)$/ {print $1}'
        /etc/passwd
    executable: /bin/bash
  register: sec_human_accounts
  changed_when: false
  check_mode: false
  tags: [passwords]

- name: Apply password aging to existing human accounts
  ansible.builtin.user:
    name: "{{ item }}"
    password_expire_max: "{{ sec_password_max_days }}"
    password_expire_min: "{{ sec_password_min_days }}"
    password_expire_warn: "{{ sec_password_warn_age }}"
  loop: "{{ sec_human_accounts.stdout_lines }}"
  tags: [passwords]

- name: Report accounts with an EMPTY password (finding, not auto-remediated)
  ansible.builtin.shell:
    cmd: "awk -F: '($2 == \"\") {print $1}' /etc/shadow"
    executable: /bin/bash
  register: sec_empty_passwords
  changed_when: false
  check_mode: false
  become: true
  tags: [passwords, audit]

- name: Fail when any account has an empty password
  ansible.builtin.assert:
    that: sec_empty_passwords.stdout_lines | length == 0
    fail_msg: >-
      Accounts with EMPTY passwords on {{ inventory_hostname }}:
      {{ sec_empty_passwords.stdout_lines | join(', ') }}
    success_msg: "No accounts with empty passwords."
  tags: [passwords, audit]

- name: Report non-root accounts with UID 0 (finding)
  ansible.builtin.shell:
    cmd: "awk -F: '($3 == 0 && $1 != \"root\") {print $1}' /etc/passwd"
    executable: /bin/bash
  register: sec_uid0
  changed_when: false
  check_mode: false
  tags: [passwords, audit]

- name: Fail when a non-root UID 0 account exists
  ansible.builtin.assert:
    that: sec_uid0.stdout_lines | length == 0
    fail_msg: "UID 0 aliases found: {{ sec_uid0.stdout_lines | join(', ') }}"
  tags: [passwords, audit]

- name: Deploy password quality policy
  ansible.builtin.template:
    src: pwquality.conf.j2
    dest: /etc/security/pwquality.conf
    owner: root
    group: root
    mode: "0644"
  tags: [passwords]

- name: Deploy account lockout policy
  ansible.builtin.template:
    src: faillock.conf.j2
    dest: /etc/security/faillock.conf
    owner: root
    group: root
    mode: "0644"
  tags: [passwords]

# ---------------------------------------------------------------- resource limits
- name: Deploy PAM resource limits
  ansible.builtin.template:
    src: limits.conf.j2
    dest: /etc/security/limits.d/50-baseline.conf
    owner: root
    group: root
    mode: "0644"
  tags: [limits]

- name: Ensure pam_limits is present in the session stacks that matter
  ansible.builtin.lineinfile:
    path: "{{ item }}"
    regexp: '^session\s+required\s+pam_limits\.so'
    line: "session     required      pam_limits.so"
    state: present
  loop: "{{ sec_pam_session_files }}"
  when: sec_pam_session_files is defined
  tags: [limits]

- name: Deploy systemd manager default limits (services do NOT read limits.conf)
  ansible.builtin.copy:
    dest: /etc/systemd/system.conf.d/10-limits.conf
    owner: root
    group: root
    mode: "0644"
    content: |
      # Managed by Ansible - roles/host_security
      # systemd starts services without a PAM session, so /etc/security/limits.conf
      # has no effect on them. These are the limits that actually apply.
      [Manager]
      {% for k, v in sec_systemd_default_limits.items() %}
      {{ k }}={{ v }}
      {% endfor %}
  notify: reexec systemd
  tags: [limits]

- name: Deploy kernel-level ceilings
  ansible.posix.sysctl:
    name: "{{ item.key }}"
    value: "{{ item.value }}"
    sysctl_file: /etc/sysctl.d/60-limits.conf
    sysctl_set: true
    reload: true
  loop:
    - { key: "fs.file-max",        value: "2097152" }
    - { key: "fs.nr_open",         value: "1048576" }
    - { key: "kernel.pid_max",     value: "4194304" }
    - { key: "fs.suid_dumpable",   value: "0" }
    - { key: "kernel.dmesg_restrict", value: "1" }
  tags: [limits]

# ---------------------------------------------------------------- sudo
- name: Install sudo
  ansible.builtin.package:
    name: sudo
    state: present
  tags: [sudo]

- name: Deploy sudoers drop-ins (validated BEFORE installation)
  ansible.builtin.template:
    src: "sudoers/{{ item }}.j2"
    dest: "/etc/sudoers.d/{{ item }}"
    owner: root
    group: root
    mode: "0440"
    validate: "/usr/sbin/visudo -cf %s"
  loop:
    - 00-defaults
    - 20-sre-oncall
    - 30-deploy-automation
  tags: [sudo]

- name: Remove sudoers drop-ins that are no longer declared
  ansible.builtin.file:
    path: "/etc/sudoers.d/{{ item }}"
    state: absent
  loop: "{{ sec_sudoers_absent | default([]) }}"
  tags: [sudo]

- name: Create the sudo I/O log directory
  ansible.builtin.file:
    path: /var/log/sudo-io
    state: directory
    owner: root
    group: root
    mode: "0700"
  tags: [sudo]

- name: Validate the ENTIRE sudoers tree after any change
  ansible.builtin.command:
    cmd: /usr/sbin/visudo -c
  register: sec_visudo
  changed_when: false
  failed_when: sec_visudo.rc != 0
  tags: [sudo]

# ---------------------------------------------------------------- SUID/SGID drift
- name: Scan for SUID and SGID files
  ansible.builtin.shell:
    cmd: >-
      find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -print 2>/dev/null | sort
    executable: /bin/bash
  register: sec_suid_found
  changed_when: false
  check_mode: false
  tags: [suid, audit]

- name: Compute SUID/SGID drift against the approved baseline
  ansible.builtin.set_fact:
    sec_suid_drift: "{{ sec_suid_found.stdout_lines | difference(sec_suid_baseline) }}"
    sec_suid_missing: "{{ sec_suid_baseline | difference(sec_suid_found.stdout_lines) }}"
  tags: [suid, audit]

- name: Report SUID/SGID drift
  ansible.builtin.debug:
    msg:
      - "UNEXPECTED SUID/SGID on {{ inventory_hostname }}: {{ sec_suid_drift | default([]) }}"
      - "Baseline entries ABSENT (may be fine, distro-dependent): {{ sec_suid_missing | default([]) }}"
  when: sec_suid_drift | length > 0 or sec_suid_missing | length > 0
  tags: [suid, audit]

- name: Remove explicitly approved SUID bits
  ansible.builtin.file:
    path: "{{ item }}"
    mode: "u-s"
  loop: "{{ sec_suid_remove }}"
  when: item in sec_suid_found.stdout_lines
  tags: [suid]

- name: Scan for file capabilities (invisible to find -perm)
  ansible.builtin.command:
    cmd: getcap -r /
  register: sec_caps
  changed_when: false
  failed_when: false
  check_mode: false
  tags: [suid, audit]

- name: Report file capabilities
  ansible.builtin.debug:
    var: sec_caps.stdout_lines
  tags: [suid, audit]

# ---------------------------------------------------------------- scheduled scan
- name: Install the drift scanner
  ansible.builtin.template:
    src: suid-scan.sh.j2
    dest: /usr/local/sbin/suid-scan.sh
    owner: root
    group: root
    mode: "0755"
  tags: [suid]

- name: Install the drift scanner unit and timer
  ansible.builtin.template:
    src: "{{ item }}.j2"
    dest: "/etc/systemd/system/{{ item }}"
    owner: root
    group: root
    mode: "0644"
  loop:
    - suid-scan.service
    - suid-scan.timer
  notify: reload systemd
  tags: [suid]

- name: Enable the drift scanner timer
  ansible.builtin.systemd_service:
    name: suid-scan.timer
    enabled: true
    state: started
    daemon_reload: true
  tags: [suid]

# ---------------------------------------------------------------- audit trail
- name: Install auditd
  ansible.builtin.package:
    name: "{{ sec_auditd_package | default('audit') }}"
    state: present
  tags: [audit]

- name: Deploy audit rules
  ansible.builtin.copy:
    src: 50-privilege.rules
    dest: /etc/audit/rules.d/50-privilege.rules
    owner: root
    group: root
    mode: "0640"
  notify: reload audit rules
  tags: [audit]

- name: Enable auditd
  ansible.builtin.systemd_service:
    name: auditd
    enabled: true
    state: started
  tags: [audit]
```

```yaml
# roles/host_security/handlers/main.yml
---
- name: reload systemd
  ansible.builtin.systemd_service:
    daemon_reload: true

- name: reexec systemd
  ansible.builtin.command:
    cmd: systemctl daemon-reexec
  changed_when: true

- name: reload audit rules
  ansible.builtin.command:
    cmd: augenrules --load
  changed_when: true
```

```jinja
{# roles/host_security/templates/limits.conf.j2 #}
# Managed by Ansible - roles/host_security. Local edits will be overwritten.
#
# NOTE: pam_limits applies these ONLY to processes started through a PAM session
# (login, sshd, su, sudo, cron-with-pam). systemd services are NOT covered — see
# /etc/systemd/system.conf.d/10-limits.conf and per-unit Limit*= directives.
#
#<domain>      <type>  <item>          <value>
{% for l in sec_limits %}
{{ '%-14s' | format(l.domain) }}{{ '%-8s' | format(l.type) }}{{ '%-16s' | format(l.item) }}{{ l.value }}
{% endfor %}
```

```jinja
{# roles/host_security/templates/suid-scan.sh.j2 #}
#!/usr/bin/env bash
# Managed by Ansible. Emits SUID/SGID drift as node_exporter textfile metrics.
set -Eeuo pipefail

BASELINE=/var/lib/host-security/suid.baseline
TEXTFILE_DIR=/var/lib/node_exporter/textfile_collector
OUT="${TEXTFILE_DIR}/suid_drift.prom"
TMP="$(mktemp "${OUT}.XXXXXX")"
trap 'rm -f "${TMP}"' EXIT

install -d -m 0755 "$(dirname "${BASELINE}")" "${TEXTFILE_DIR}"

CURRENT="$(mktemp)"; trap 'rm -f "${TMP}" "${CURRENT}"' EXIT
find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -print 2>/dev/null | sort > "${CURRENT}"

if [[ ! -f "${BASELINE}" ]]; then
    cp "${CURRENT}" "${BASELINE}"
    logger -t suid-scan "baseline created with $(wc -l < "${BASELINE}") entries"
fi

added=$(comm -13 "${BASELINE}" "${CURRENT}" | wc -l)
removed=$(comm -23 "${BASELINE}" "${CURRENT}" | wc -l)
total=$(wc -l < "${CURRENT}")
caps=$(getcap -r / 2>/dev/null | wc -l)

comm -13 "${BASELINE}" "${CURRENT}" | while read -r f; do
    logger -t suid-scan -p auth.warning "UNEXPECTED setuid/setgid file: ${f}"
done

cat > "${TMP}" <<EOF
# HELP node_suid_files_total Number of SUID/SGID files on local filesystems.
# TYPE node_suid_files_total gauge
node_suid_files_total ${total}
# HELP node_suid_files_added Files with SUID/SGID not present in the baseline.
# TYPE node_suid_files_added gauge
node_suid_files_added ${added}
# HELP node_suid_files_removed Baseline SUID/SGID files no longer present.
# TYPE node_suid_files_removed gauge
node_suid_files_removed ${removed}
# HELP node_file_capabilities_total Binaries carrying file capabilities.
# TYPE node_file_capabilities_total gauge
node_file_capabilities_total ${caps}
EOF

chmod 0644 "${TMP}"
mv "${TMP}" "${OUT}"     # atomic: node_exporter never reads a partial file
```

```ini
# roles/host_security/templates/suid-scan.service.j2
[Unit]
Description=SUID/SGID drift scan
Documentation=man:find(1) man:getcap(8)
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/suid-scan.sh
Nice=19
IOSchedulingClass=idle
CPUSchedulingPolicy=idle
TimeoutStartSec=15min

# The scan must read the whole filesystem, so ProtectSystem=strict is wrong here;
# it is still confined to no new privileges and a read-only view except the output.
NoNewPrivileges=yes
ProtectHome=read-only
ProtectSystem=full
ReadWritePaths=/var/lib/host-security /var/lib/node_exporter/textfile_collector
PrivateTmp=yes
CapabilityBoundingSet=CAP_DAC_READ_SEARCH CAP_SYS_ADMIN
```

```ini
# roles/host_security/templates/suid-scan.timer.j2
[Unit]
Description=Nightly SUID/SGID drift scan

[Timer]
OnCalendar={{ sec_scan_schedule }}
RandomizedDelaySec=30min      # do not stampede the fleet's I/O at the same second
Persistent=true               # run on boot if the host was down at the scheduled time
AccuracySec=1min

[Install]
WantedBy=timers.target
```

### 8.2 Reglas de alerta de Prometheus

```yaml
# prometheus/rules/host-security.yml
---
groups:
  - name: host-security
    interval: 60s
    rules:
      - alert: SuidBinaryDrift
        expr: node_suid_files_added > 0
        for: 10m
        labels:
          severity: critical
          category: privilege-escalation
        annotations:
          summary: "Unapproved SUID/SGID binary on {{ $labels.instance }}"
          description: >-
            {{ $value }} setuid/setgid file(s) present that are not in the approved
            baseline. Each is a potential unaudited path to root.
          runbook_url: "https://runbooks.internal/security/suid-drift"
          query: 'journalctl -t suid-scan -p warning --since "24 hours ago"'

      - alert: SuidScanStale
        expr: time() - node_textfile_mtime_seconds{file="suid_drift.prom"} > 172800
        for: 30m
        labels:
          severity: warning
        annotations:
          summary: "SUID drift scan has not run for 48h on {{ $labels.instance }}"
          description: "The control is silent, which is indistinguishable from clean."

      - alert: UnexpectedListeningPort
        expr: |
          count by (instance) (
            node_network_listening_port_info
            unless on (instance, port) approved_listening_port
          ) > 0
        for: 15m
        labels:
          severity: warning
          category: exposure
        annotations:
          summary: "Unapproved listening port on {{ $labels.instance }}"
          query: 'ss -tulpn'

      - alert: FileDescriptorExhaustionImminent
        expr: |
          process_open_fds / process_max_fds > 0.85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.job }} on {{ $labels.instance }} at {{ $value | humanizePercentage }} of its fd limit"
          description: >-
            Raise LimitNOFILE= in the unit — /etc/security/limits.conf does NOT
            apply to systemd services.

      - alert: CgroupTasksNearLimit
        expr: |
          node_systemd_unit_tasks_current / node_systemd_unit_tasks_max > 0.9
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.name }} approaching TasksMax on {{ $labels.instance }}"

      - alert: BruteForceLoginAttempts
        expr: rate(node_failed_logins_total[15m]) * 900 > 50
        for: 5m
        labels:
          severity: warning
          category: authentication
        annotations:
          summary: "{{ $value | printf \"%.0f\" }} failed logins in 15m on {{ $labels.instance }}"
          query: 'lastb -i | awk "{print \$NF}" | sort | uniq -c | sort -rn | head'

      - alert: AccountWithEmptyPassword
        expr: node_accounts_empty_password > 0
        labels:
          severity: critical
        annotations:
          summary: "Account with an empty password on {{ $labels.instance }}"
```

### 8.3 Pipeline de CI: validar la política antes de enviarla, escanear después de que aterrice

```yaml
# .gitlab-ci.yml
---
stages: [validate, dry-run, deploy, verify]

variables:
  ANSIBLE_FORCE_COLOR: "1"
  ANSIBLE_HOST_KEY_CHECKING: "False"

# ---- Every sudoers template must parse. A syntax error here locks out a fleet.
sudoers:syntax:
  stage: validate
  image: alpine:3.20
  before_script:
    - apk add --no-cache sudo python3 py3-jinja2
  script:
    - |
      rc=0
      for tpl in roles/host_security/templates/sudoers/*.j2; do
        out="/tmp/$(basename "${tpl}" .j2)"
        python3 ci/render_template.py "${tpl}" > "${out}"
        chown root:root "${out}"; chmod 0440 "${out}"
        if visudo -cf "${out}"; then
          echo "OK   ${tpl}"
        else
          echo "FAIL ${tpl}"; rc=1
        fi
      done
      exit "${rc}"

# ---- Reject grants that are shell escapes in disguise.
sudoers:dangerous-grants:
  stage: validate
  image: alpine:3.20
  script:
    - |
      set -euo pipefail
      DANGEROUS='/(vi|vim|nano|emacs|less|more|man|find|tar|awk|perl|python[0-9.]*|ruby|nmap|ed|env|nice|xargs)([[:space:]]|$)'
      if grep -nEH "NOPASSWD.*${DANGEROUS}" roles/host_security/templates/sudoers/*.j2; then
        echo "ERROR: NOPASSWD grant on a program with a documented shell escape."
        echo "See https://gtfobins.github.io/ — use a root-owned wrapper instead."
        exit 1
      fi
      if grep -nEH '=\s*\(ALL(:ALL)?\)\s*NOPASSWD:\s*ALL' roles/host_security/templates/sudoers/*.j2; then
        echo "ERROR: unrestricted NOPASSWD: ALL grant."
        exit 1
      fi
      if grep -nEH '^[^#]*\*/\.\.' roles/host_security/templates/sudoers/*.j2; then
        echo "ERROR: path traversal reachable through a wildcard."
        exit 1
      fi
      echo "No dangerous grant patterns found."

ansible:lint:
  stage: validate
  image: python:3.12-slim
  script:
    - pip install --no-cache-dir ansible-lint ansible-core
    - ansible-lint roles/host_security/
    - ansible-playbook --syntax-check site.yml

ansible:check:
  stage: dry-run
  image: python:3.12-slim
  script:
    - pip install --no-cache-dir ansible-core
    - ansible-playbook -i inventories/prod site.yml --check --diff --limit canary
  artifacts:
    paths: [ansible-check.log]
    expire_in: 1 week

ansible:apply:
  stage: deploy
  image: python:3.12-slim
  when: manual
  environment:
    name: production
  script:
    - pip install --no-cache-dir ansible-core
    - ansible-playbook -i inventories/prod site.yml --limit canary
    - ansible-playbook -i inventories/prod site.yml --limit '!canary' --forks 20

# ---- The external view. Runs from a host on the same L3 segment as production,
#      against an inventory-derived target list. Compares to last week's scan.
nmap:exposure-diff:
  stage: verify
  image: instrumentisto/nmap:7.94
  rules:
    - if: $CI_PIPELINE_SOURCE == "schedule"
    - if: $CI_COMMIT_BRANCH == "main"
      when: manual
  script:
    - mkdir -p scans
    - nmap -sS -Pn -p- -T4 --open -oA "scans/current" -iL inventories/prod/scan-targets.txt
    - |
      if [ -f baseline/exposure.xml ]; then
        ndiff baseline/exposure.xml scans/current.xml > scans/diff.txt || true
        if [ -s scans/diff.txt ]; then
          echo "=== EXPOSURE CHANGED ==="
          cat scans/diff.txt
          exit 1
        fi
        echo "No exposure change since the approved baseline."
      else
        echo "No baseline yet; promoting the current scan after review."
      fi
  artifacts:
    when: always
    paths: [scans/]
    expire_in: 90 days
```

---

## 9. Verificación y diagnóstico de fallas

### 9.1 La pasada de verificación

Ejecutá esto después de cualquier cambio en este dominio. Cada línea es una pregunta con una respuesta definida.

```bash
#!/usr/bin/env bash
# verify-security-baseline.sh — read-only. Exit non-zero on any finding.
set -uo pipefail
fail=0
chk() { if eval "$2"; then printf 'PASS  %s\n' "$1"; else printf 'FAIL  %s\n' "$1"; fail=1; fi; }

echo "== sudo =="
chk "sudoers tree parses"            'visudo -c >/dev/null 2>&1'
chk "sudoers is mode 0440"           '[ "$(stat -c %a /etc/sudoers)" = 440 ]'
chk "no NOPASSWD: ALL grant"         '! grep -rhE "NOPASSWD:\s*ALL" /etc/sudoers /etc/sudoers.d/ 2>/dev/null | grep -qv "^#"'
chk "env_reset is set"               'grep -rqE "^Defaults[[:space:]]+.*env_reset" /etc/sudoers /etc/sudoers.d/'
chk "secure_path is set"             'grep -rqE "^Defaults[[:space:]]+.*secure_path" /etc/sudoers /etc/sudoers.d/'

echo "== accounts =="
chk "root password is locked"        '[ "$(passwd -S root | awk "{print \$2}")" = "L" ]'
chk "no empty passwords"             '[ -z "$(awk -F: "\$2==\"\"{print \$1}" /etc/shadow)" ]'
chk "no non-root UID 0"              '[ -z "$(awk -F: "\$3==0 && \$1!=\"root\"{print \$1}" /etc/passwd)" ]'
chk "PASS_MAX_DAYS <= 90"            '[ "$(awk "/^PASS_MAX_DAYS/{print \$2}" /etc/login.defs)" -le 90 ]'
chk "shadow is not world-readable"   '[ "$(stat -c %a /etc/shadow)" -le 640 ]'

echo "== limits =="
chk "pam_limits in system-auth"      'grep -rqE "^session.*pam_limits\.so" /etc/pam.d/'
chk "systemd default limits present" '[ -f /etc/systemd/system.conf.d/10-limits.conf ]'
chk "core dumps disabled"            '[ "$(sysctl -n fs.suid_dumpable)" = 0 ]'

echo "== privilege surface =="
chk "no SUID drift"                  'diff -q <(find / -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null | sort) /var/lib/host-security/suid.baseline >/dev/null'
chk "no SUID on user-writable fs"    '[ -z "$(find /home /tmp /var/tmp -xdev -perm /6000 -type f 2>/dev/null)" ]'
chk "/tmp mounted nosuid"            'findmnt -no OPTIONS /tmp 2>/dev/null | grep -q nosuid || ! findmnt -no TARGET /tmp >/dev/null 2>&1'

echo "== audit =="
chk "auditd running"                 'systemctl is-active --quiet auditd'
chk "audit rules loaded"             '[ "$(auditctl -l 2>/dev/null | wc -l)" -gt 5 ]'
chk "btmp exists and is 0600"        '[ "$(stat -c %a /var/log/btmp 2>/dev/null)" = 600 ]'

exit "${fail}"
```

```
$ sudo ./verify-security-baseline.sh
== sudo ==
PASS  sudoers tree parses
PASS  sudoers is mode 0440
PASS  no NOPASSWD: ALL grant
PASS  env_reset is set
PASS  secure_path is set
== accounts ==
PASS  root password is locked
PASS  no empty passwords
PASS  no non-root UID 0
PASS  PASS_MAX_DAYS <= 90
PASS  shadow is not world-readable
== limits ==
PASS  pam_limits in system-auth
PASS  systemd default limits present
PASS  core dumps disabled
== privilege surface ==
FAIL  no SUID drift
PASS  no SUID on user-writable fs
PASS  /tmp mounted nosuid
== audit ==
PASS  auditd running
PASS  audit rules loaded
PASS  btmp exists and is 0600
$ echo $?
1
```

### 9.2 Catálogo de fallas

**"Subí `nofile` en `limits.conf` pero el servicio sigue topando en 1024."**

```
$ grep nofile /etc/security/limits.d/50-baseline.conf
*    hard    nofile    16384
$ cat /proc/$(pgrep -f api)/limits | grep 'Max open'
Max open files            1024                 4096                 files
```
Causa: `pam_limits` corre durante una sesión PAM; systemd arranca servicios sin ninguna. Corregilo en la unidad, no en PAM:
```
$ sudo systemctl edit api.service
### add: [Service] / LimitNOFILE=65536
$ sudo systemctl daemon-reload && sudo systemctl restart api.service
$ systemctl show api.service -p LimitNOFILE
LimitNOFILE=65536
```
Lo mismo aplica para un shell interactivo donde el límite no tomó efecto: verificá que `pam_limits.so` esté en la pila que realmente usa tu ruta de entrada (`/etc/pam.d/sshd` → `password-auth`/`common-session`), y que hayas vuelto a iniciar sesión — el límite se establece en la creación de la sesión, no se lee en vivo.

**"`ulimit -n` dice `Operation not permitted` y ni siquiera estoy cerca del techo."**
```
$ ulimit -Hn
4096
$ ulimit -n 65536
bash: ulimit: open files: cannot modify limit: Operation not permitted
```
Un proceso sin privilegios solo puede *bajar* un límite duro, y el cambio es irreversible para ese árbol de procesos. Algo anterior en la cadena (un script de perfil, un envoltorio, un runtime de contenedores) lo bajó. Subí el límite duro en `limits.conf`/la unidad e iniciá una sesión **nueva**. Verificá también el techo del kernel: `nofile` no puede exceder `fs.nr_open`.

**"Bloqueé la cuenta pero el usuario sigue iniciando sesión."**
```
$ sudo passwd -S bob
bob L 08/12/2026 1 90 14 14
$ sudo journalctl -u sshd | tail -1
Accepted publickey for bob from 10.20.4.22 port 51992 ssh2: ED25519 SHA256:1Kx...
```
`passwd -l` deshabilita la *contraseña*. La autenticación por clave pública no la consulta. Deshabilitación completa: `usermod -L bob && chage -E "$(date -d yesterday +%F)" bob && usermod -s /usr/sbin/nologin bob && pkill -KILL -u bob`, y eliminá o renombrá `~bob/.ssh/authorized_keys`.

**"`sudo` tarda 10 segundos antes de pedir la contraseña."**
```
$ time sudo -n true
sudo: a password is required
real    0m10.021s
```
`sudo` está resolviendo el nombre local del host y se le agota el tiempo. Confirmá que el propio nombre del host esté en `/etc/hosts` en la línea de `127.0.0.1`, y establecé `Defaults !fqdn`. El mismo síntoma con `ss`/`netstat`/`last` viene del DNS inverso — usá `-n` / `-i`.

**"`sudo` funciona pero mi script no encuentra sus binarios."**
```
$ sudo /opt/tool/run.sh
/opt/tool/run.sh: line 4: kubectl: command not found
$ sudo env | grep -E '^(PATH|HOME)'
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
HOME=/root
```
`Defaults secure_path` reemplaza `PATH` y `env_reset` descarta el entorno del llamador. O bien usá rutas absolutas en el script (lo correcto), o agregá el directorio a `secure_path`, o permití una variable con `Defaults env_keep += "VAR"`. **No** deshabilites `env_reset`; existe para frenar ataques de clase `LD_PRELOAD`.

**"Rompí `/etc/sudoers` y no hay contraseña de root."**
```
$ sudo -l
sudo: /etc/sudoers:22:14: syntax error
sudo: no valid sudoers sources found, quitting
```
Recuperación, en orden de preferencia: (1) otro shell root ya abierto en la máquina — usalo de inmediato, no lo cierres; (2) `pkexec visudo` si polkit está configurado; (3) una clave SSH de cuenta de máquina con un comando forzado; (4) acceso por consola y arrancar con `systemd.debug-shell=1` o `rd.break`/`init=/bin/bash` y remontar `/` en lectura-escritura. El control preventivo es la compuerta `visudo -cf` de CI en §8.3, más nunca editar sudoers fuera de `visudo`.

**"`nmap` dice que el host está caído pero puedo entrar por SSH."**
```
$ nmap -p 22 10.20.4.11
Note: Host seems down. If it is really up, but blocking our ping probes, try -Pn
```
El descubrimiento de hosts (ICMP echo + TCP ACK al 80 + TCP SYN al 443 + ICMP timestamp) fue filtrado. Agregá `-Pn`. Notá el costo: con `-Pn`, nmap escanea cada dirección del rango haya o no algo allí, lo que hace que un barrido de un `/16` sea muy lento.

**"`ss -tulpn` no muestra nombres de procesos."**
```
$ ss -tulpn | head -2
Netid State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
tcp   LISTEN 0      128          0.0.0.0:22        0.0.0.0:*
```
No sos root. Leer el mapeo socket→PID de otro usuario requiere `CAP_NET_ADMIN`/root. Reejecutalo con `sudo`.

**"`last` no imprime nada en una versión nueva de la distribución."**
```
$ last
wtmp begins Sun Aug 31 00:00:01 2026
$ ls -l /var/log/wtmp
-rw-rw-r--. 1 root utmp 0 Aug 31 00:00 /var/log/wtmp
```
El soporte de `utmp` fue deshabilitado en favor de `systemd-logind` + `wtmpdb`. Usá `wtmpdb last`, `lastlog2`, o `journalctl -u systemd-logind` / `journalctl _COMM=sshd`. Actualizá tus consultas de recolección de logs en consecuencia — esto es una brecha silenciosa de monitoreo, no un historial vacío.

**"Un usuario no puede iniciar ningún proceso nuevo."**
```
$ ssh alice@web01
alice@web01:~$ ls
-bash: fork: retry: Resource temporarily unavailable
```
`nproc` está agotado. Cuenta por **UID real en todo el sistema**, así que otra sesión o un demonio con fugas propiedad del mismo UID lo está consumiendo:
```
$ ps -eo user= | sort | uniq -c | sort -rn | head -3
    247 alice
     92 root
     14 www-data
$ ulimit -u
256
```
Subí el límite o, mejor, mové la carga de trabajo bajo una unidad systemd con `TasksMax=` para que la contención sea por servicio en lugar de por UID.

**"Apareció un puerto inesperado y necesito saber quién lo abrió, ya mismo."**
```
$ sudo ss -tulpn 'sport = :9200'
tcp LISTEN 0 4096 0.0.0.0:9200 0.0.0.0:* users:(("java",pid=4188,fd=412))
$ sudo lsof -nP -p 4188 | head -3
COMMAND  PID          USER   FD   TYPE DEVICE SIZE/OFF     NODE NAME
java    4188 elasticsearch  cwd    DIR  253,1     4096  1179842 /usr/share/elasticsearch
java    4188 elasticsearch  txt    REG  253,1 12583744  1180991 /usr/share/elasticsearch/jdk/bin/java
$ ps -o pid,ppid,user,lstart,cmd -p 4188 --no-headers
4188  1 elasticsearch Sat Aug 30 22:01:14 2026 /usr/share/elasticsearch/jdk/bin/java -Xms2g ...
$ systemctl status 4188 | head -3
● elasticsearch.service - Elasticsearch
     Loaded: loaded (/usr/lib/systemd/system/elasticsearch.service; enabled)
     Active: active (running) since Sat 2026-08-30 22:01:14 -03; 14h ago
$ sudo ausearch -ts recent -k scope -i | grep -i elastic | tail -2
$ sudo last -F -s '2026-08-30 21:00' -t '2026-08-30 23:00'
deploy   pts/2  10.20.9.14  Sat Aug 30 22:00:02 2026 - Sat Aug 30 22:01:47 2026  (00:01)
```
La cadena es: puerto → PID → usuario → unidad → quién estaba conectado cuando arrancó. Ese último paso es la razón por la que existe §7.

---

## 10. Resumen de comandos para el examen

```bash
# --- SUID / SGID audit
find / -perm -4000 -type f                       # SUID files
find / -perm -2000 -type f                       # SGID files
find / -perm /6000 -type f                       # either
find / -xdev -perm -u+s -type f 2>/dev/null      # symbolic, one filesystem, quiet
chmod u-s FILE ; chmod g-s FILE                  # remove the bits
getcap -r / 2>/dev/null                          # file capabilities (the blind spot)

# --- passwords and aging
passwd [USER]            # change a password
passwd -S USER           # status: P / L / NP
passwd -Sa               # all accounts
passwd -l / -u USER      # lock / unlock
passwd -e USER           # force a change at next login
passwd -n 1 -x 90 -w 14 -i 14 USER    # min / max / warn / inactive
chage -l USER            # list aging
chage -M 90 -m 1 -W 14 -I 14 USER
chage -E 2027-03-31 USER # account expiry date
chage -d 0 USER          # force a change at next login
usermod -L / -U USER     # lock / unlock
usermod -e 2027-03-31 USER
usermod -s /usr/sbin/nologin USER

# --- limits
ulimit -a                # all current limits
ulimit -Hn / -Sn         # hard / soft open files
ulimit -n 8192           # set the soft limit
ulimit -u 512            # max user processes
ulimit -v 2097152        # virtual memory, KiB
cat /proc/PID/limits     # what a RUNNING process actually has
# /etc/security/limits.conf:  <domain> <type> <item> <value>

# --- open ports
netstat -tulpn           # TCP/UDP listening, numeric, with PID  [exam]
netstat -an              # every socket, numeric
ss -tulpn                # the modern equivalent           [production]
lsof -i :80              # who owns port 80
lsof -i TCP -sTCP:LISTEN
fuser -v -n tcp 80       # who is on the port
fuser -k -n tcp 80       # kill them
nmap -sT HOST            # connect scan, no root required
nmap -sS -p- HOST        # SYN scan, all 65535 ports, root
nmap -sU --top-ports 50 HOST
nmap -sV -p 22,80 HOST   # service versions
nmap -sn 10.0.0.0/24     # host discovery only

# --- who is / was logged in
who ; who -a ; who -b ; who am i
w ; w -h USER
users
last ; last -F ; last -a ; last -n 10 ; last reboot ; last USER
lastb                    # failed attempts (root)
lastlog ; lastlog -b 90 ; lastlog -u USER
loginctl list-sessions ; loginctl session-status N

# --- sudo / su
visudo                   # ALWAYS edit sudoers this way
visudo -c                # validate the tree
visudo -cf FILE          # validate one drop-in
sudo -l                  # what may I run?
sudo -l -U USER          # what may they run?
sudo -u USER CMD         # run as another user
sudo -i                  # root login shell
sudo -s                  # root shell, non-login
sudo -k / -K             # invalidate / remove the credential cache
sudo -v                  # refresh it
sudoedit FILE            # edit as root, safely
su - ; su - USER ; su -c 'CMD' USER
id ; whoami ; logname ; groups
```

**Datos de mayor rendimiento, condensados:**

- `-perm -4000` (todos los bits listados activados) es la forma de auditoría SUID; `-perm 4000` (coincidencia exacta) casi siempre está mal.
- Orden de campos de `/etc/shadow`: `nombre : hash : últimocambio : min : max : warn : inactive : expire : reservado`. Los campos 4–8 son `chage -m -M -W -I -E`.
- `passwd -l` bloquea la contraseña, **no la cuenta**; el SSH por clave sigue funcionando.
- `limits.conf` lo aplica `pam_limits.so` y por lo tanto **no** aplica a servicios systemd.
- Un límite duro solo puede bajarlo un proceso sin privilegios, y nunca volver a subirlo.
- Solo root lee `/var/log/btmp` (`lastb`).
- `utmp` = ahora, `wtmp` = historial, `btmp` = fallos, `lastlog` = último login por usuario.
- `nmap -sS` necesita root; `-sT` no. `closed` significa que el host respondió; `filtered` significa que un firewall descartó la sonda.
- En sudoers gana la **última regla que coincide**, y `#includedir` es una directiva, no un comentario.
- `visudo` es el único editor seguro para sudoers; `visudo -c` es la única comprobación previa segura.

---

## 11. Referencias

**Objetivos de certificación**
- LPI Exam 101-500 Objectives — https://www.lpi.org/our-certifications/exam-101-objectives/
- LPI Exam 102-500 Objectives (Topic 110, Security) — https://www.lpi.org/our-certifications/exam-102-objectives/
- LPIC-1 Certification Overview — https://www.lpi.org/our-certifications/lpic-1-overview/

**Páginas de manual y herramientas centrales**
- `find(1)` — https://man7.org/linux/man-pages/man1/find.1.html
- `chmod(1)` y `chmod(2)` — https://man7.org/linux/man-pages/man1/chmod.1.html · https://man7.org/linux/man-pages/man2/chmod.2.html
- `passwd(1)`, `passwd(5)`, `shadow(5)` — https://man7.org/linux/man-pages/man1/passwd.1.html · https://man7.org/linux/man-pages/man5/shadow.5.html
- `chage(1)` — https://man7.org/linux/man-pages/man1/chage.1.html
- `usermod(8)`, `useradd(8)` — https://man7.org/linux/man-pages/man8/usermod.8.html · https://man7.org/linux/man-pages/man8/useradd.8.html
- `login.defs(5)` — https://man7.org/linux/man-pages/man5/login.defs.5.html
- `su(1)` — https://man7.org/linux/man-pages/man1/su.1.html
- `who(1)`, `w(1)`, `last(1)`, `lastlog(8)` — https://man7.org/linux/man-pages/man1/who.1.html · https://man7.org/linux/man-pages/man1/w.1.html · https://man7.org/linux/man-pages/man1/last.1.html · https://man7.org/linux/man-pages/man8/lastlog.8.html
- `utmp(5)` — https://man7.org/linux/man-pages/man5/utmp.5.html
- `lsof(8)` — https://man7.org/linux/man-pages/man8/lsof.8.html
- `fuser(1)` — https://man7.org/linux/man-pages/man1/fuser.1.html
- `netstat(8)`, `ss(8)` — https://man7.org/linux/man-pages/man8/netstat.8.html · https://man7.org/linux/man-pages/man8/ss.8.html
- `getrlimit(2)` / `setrlimit(2)` — https://man7.org/linux/man-pages/man2/getrlimit.2.html
- `credentials(7)` y `capabilities(7)` — https://man7.org/linux/man-pages/man7/credentials.7.html · https://man7.org/linux/man-pages/man7/capabilities.7.html
- `getcap(8)` / `setcap(8)` — https://man7.org/linux/man-pages/man8/setcap.8.html
- `execve(2)` (semántica de set-user-ID) — https://man7.org/linux/man-pages/man2/execve.2.html

**sudo**
- Sitio del proyecto Sudo — https://www.sudo.ws/
- Manual de `sudoers(5)` — https://www.sudo.ws/docs/man/sudoers.man/
- Manual de `sudo(8)` — https://www.sudo.ws/docs/man/sudo.man/
- Manual de `visudo(8)` — https://www.sudo.ws/docs/man/visudo.man/
- Manual de `sudoreplay(8)` — https://www.sudo.ws/docs/man/sudoreplay.man/
- Avisos de seguridad de Sudo — https://www.sudo.ws/security/advisories/
- CVE-2021-3156 (desbordamiento de heap en `sudoedit`) — https://www.sudo.ws/security/advisories/unescape_overflow/
- CVE-2019-14287 (bypass de UID `-1` en runas) — https://www.sudo.ws/security/advisories/minus_1_uid/
- CVE-2023-22809 (escritura de archivo arbitrario en `sudoedit`) — https://www.sudo.ws/security/advisories/sudoedit_any/

**PAM, límites y política de cuentas**
- Documentación de Linux-PAM — https://github.com/linux-pam/linux-pam/blob/master/doc/adg/Linux-PAM_ADG.xml
- `pam_limits(8)` — https://man7.org/linux/man-pages/man8/pam_limits.8.html
- `limits.conf(5)` — https://man7.org/linux/man-pages/man5/limits.conf.5.html
- `pam_faillock(8)` — https://man7.org/linux/man-pages/man8/pam_faillock.8.html
- `pam_pwquality(8)` y `pwquality.conf(5)` — https://man7.org/linux/man-pages/man8/pam_pwquality.8.html
- `pam_access(8)` y `access.conf(5)` — https://man7.org/linux/man-pages/man5/access.conf.5.html
- Proyecto shadow-utils — https://github.com/shadow-maint/shadow

**systemd, cgroups y control de recursos**
- `systemd.exec(5)` — sandboxing y directivas de rlimit — https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
- `systemd.resource-control(5)` — https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html
- `systemd-system.conf(5)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-system.conf.html
- `loginctl(1)` y `systemd-logind.service(8)` — https://www.freedesktop.org/software/systemd/man/latest/loginctl.html
- `systemd-analyze(1)` (verbo `security`) — https://www.freedesktop.org/software/systemd/man/latest/systemd-analyze.html
- Documentación de cgroup v2 del kernel — https://docs.kernel.org/admin-guide/cgroup-v2.html
- Referencia de sysctl de sistemas de archivos del kernel (`fs.nr_open`, `fs.file-max`) — https://docs.kernel.org/admin-guide/sysctl/fs.html

**Descubrimiento de red**
- Nmap Reference Guide — https://nmap.org/book/man.html
- Técnicas de escaneo de puertos de Nmap — https://nmap.org/book/man-port-scanning-techniques.html
- Estados de puerto de Nmap explicados — https://nmap.org/book/man-port-scanning-basics.html
- Cuestiones legales de Nmap — https://nmap.org/book/legal-issues.html
- `ndiff(1)` — https://nmap.org/ndiff/
- Proyecto iproute2 — https://wiki.linuxfoundation.org/networking/iproute2

**Auditoría y líneas base de endurecimiento**
- Proyecto Linux Audit (`auditd`) — https://github.com/linux-audit/audit-userspace
- `auditctl(8)` y `audit.rules(7)` — https://man7.org/linux/man-pages/man8/auditctl.8.html
- CIS Benchmarks (Linux) — https://www.cisecurity.org/cis-benchmarks
- DISA STIGs — https://public.cyber.mil/stigs/
- NIST SP 800-63B, Digital Identity Guidelines (política de autenticadores y contraseñas) — https://pages.nist.gov/800-63-3/sp800-63b.html
- GTFOBins (catálogo de escapes de sudo) — https://gtfobins.github.io/

**Ansible y monitoreo**
- `ansible.builtin.template` (`validate:`) — https://docs.ansible.com/ansible/latest/collections/ansible/builtin/template_module.html
- Módulo `ansible.builtin.user` — https://docs.ansible.com/ansible/latest/collections/ansible/builtin/user_module.html
- Colector de archivos de texto de node_exporter de Prometheus — https://github.com/prometheus/node_exporter#textfile-collector
- Reglas de alerta de Prometheus — https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/