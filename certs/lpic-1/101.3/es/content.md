# 101.3 — Cambiar runlevels / boot targets y apagar o reiniciar el sistema

**LPIC-1 · Examen 101-500 · Versión 5.0 · Peso 4.69**

> **Áreas de conocimiento clave:** establecer el runlevel o boot target por defecto · cambiar entre runlevels / boot targets, incluido el modo single user · apagar y reiniciar desde la línea de comandos · alertar a los usuarios antes de cambiar de runlevel / boot target u otros eventos importantes del sistema · terminar procesos correctamente.
>
> **Términos y utilidades:** `/etc/inittab` · `shutdown` · `init` · `/etc/init.d/` · `telinit` · `systemd` · `systemctl` · `/etc/systemd/` · `/usr/lib/systemd/` · `wall` · `acpid`

---

## 1. Motivación: el problema arquitectónico en producción

Un reinicio es la operación rutinaria más peligrosa que realiza un SRE. Todo lo demás — un deploy, un cambio de configuración, una actualización de paquetes — se puede revertir mientras la máquina sigue sirviendo. Un reinicio no: durante una ventana de 30 segundos a 15 minutos el nodo no es un nodo. Es una caja que puede o no volver, a un estado que puede o no haber sido especificado correctamente.

Los problemas que este objetivo resuelve realmente en una flota de producción:

**1. La máquina de estados de un sistema en ejecución es explícita y configurable.** "Multi-user con red y sin display manager" no es una sensación — es `multi-user.target`, un punto de sincronización con nombre y un grafo de dependencias que se puede consultar. Un nodo que arranca en `graphical.target` sobre un worker de Kubernetes bare-metal desperdicia 400 MB de RAM y abre una superficie de ataque X11 sin ninguna razón. Un nodo cuyo `default.target` apunta silenciosamente a `rescue.target` porque un operador olvidó ejecutar `set-default` nunca volverá a unirse al cluster después del próximo parche de kernel, y fallará sin ningún error en la consola del proveedor cloud — solo un prompt de `sulogin` en una consola serie que nadie está mirando.

**2. La recuperación tiene que funcionar cuando el plano de control normal no funciona.** `rescue.target`, `emergency.target` e `init=/bin/bash` son los tres peldaños descendentes de una escalera de recuperación: filesystems locales + sin red, filesystem raíz de solo lectura + nada más, y nada de init en absoluto. A qué peldaño podés llegar depende de decisiones tomadas *antes* del incidente — ¿está la contraseña de root definida y desbloqueada? ¿Es `sulogin` alcanzable en la consola serie? ¿Se muestra el menú de GRUB el tiempo suficiente para editar una entrada? Una imagen endurecida con `GRUB_TIMEOUT=0`, una cuenta root bloqueada y sin consola serie es una máquina que no se puede recuperar sin desmontar el disco.

**3. El apagado es un problema de sistemas distribuidos en miniatura.** Cuando escribís `reboot`, PID 1 computa una *transacción*: un conjunto de stop jobs, ordenados en sentido inverso al orden de arranque, cada uno con un timeout. Si una sola unit se bloquea — un montaje NFS cuyo servidor ya no está, una base de datos que ignora `SIGTERM` mientras hace checkpoint, un container runtime esperando un `umount` atascado — el nodo entero se queda en `A stop job is running for … (1min 30s / 1min 30s)`. Multiplicá 90 segundos por unas pocas units atascadas y un "rolling reboot de 5 minutos" de 200 nodos se convierte en una ventana de mantenimiento de seis horas. Peor: las units que *sí* pararon ya no están, así que el nodo no está sirviendo *y* tampoco está reiniciando.

**4. El trabajo en vuelo debe descargarse antes de la transición de estado, no durante ella.** En un worker de Kubernetes esto significa: cordon → drain → *después* parar el kubelet. En un nodo de base de datos significa: hacer step down del primario → esperar a que la replicación se ponga al día → después parar. El mecanismo de Linux que hace esto componible es el **inhibitor lock de systemd** (`systemd-inhibit`, el `InhibitDelayMaxSec` de logind), que es exactamente cómo funciona la característica de Graceful Node Shutdown del kubelet. Entender 101.3 es lo que te permite razonar sobre por qué `shutdownGracePeriod` e `InhibitDelayMaxSec` deben ajustarse en conjunto.

**5. Todavía hay humanos conectados.** `wall`, el broadcast automático que hace `shutdown`, `/run/nologin` y el dry-run `-k` existen porque siempre hay alguien a mitad de un `vim` en un bastión compartido. Matar su sesión en silencio es un fallo operativo aunque ningún servicio se haya degradado.

Este objetivo es donde aprendés la maquinaria para los cinco.

---

## 2. Arquitectura: dos sistemas de init, un contrato

### 2.1 El contrato de PID 1

El kernel monta el filesystem raíz (o pivota fuera de un initramfs) y ejecuta un proceso con PID 1. Ese proceso:

- es el **ancestro de todo proceso de userspace**;
- **cosecha huérfanos** — cuando cualquier proceso muere, sus hijos son re-emparentados a PID 1, que debe hacer `wait()` sobre ellos o la tabla de procesos se llena de zombis;
- **no puede ser matado** — las señales sin un handler instalado se ignoran para PID 1, así que `kill -9 1` no hace nada;
- si termina, el kernel entra en pánico: `Kernel panic - not syncing: Attempted to kill init!`

Qué binario es PID 1 lo elige el parámetro `init=` de la línea de comandos del kernel, con un valor por defecto que busca `/sbin/init`, `/etc/init`, `/bin/init`, `/bin/sh`. En distribuciones con systemd, `/sbin/init` es un symlink:

```console
$ ls -l /sbin/init
lrwxrwxrwx. 1 root root 22 Jul 14 03:11 /sbin/init -> ../lib/systemd/systemd

$ readlink -f /sbin/init
/usr/lib/systemd/systemd

$ ps -p 1 -o pid,comm,args
    PID COMMAND         COMMAND
      1 systemd         /usr/lib/systemd/systemd --switched-root --system --deserialize 31
```

### 2.2 SysV init: runlevels

El `init` clásico (el paquete `sysvinit`) es una máquina de estados **secuencial, dirigida por scripts**. Toda su configuración es un solo archivo.

#### Formato de `/etc/inittab`

Cada línea tiene cuatro campos separados por dos puntos:

```
id:runlevels:action:process
```

| Campo | Significado |
|---|---|
| `id` | Etiqueta única de 1–4 caracteres |
| `runlevels` | Los runlevels en los que aplica la entrada (concatenados, p. ej. `2345`) |
| `action` | Cuándo/cómo ejecutar el proceso (ver tabla abajo) |
| `process` | El comando a ejecutar |

Un `/etc/inittab` representativo de un sistema Debian con `sysvinit`:

```
# The default runlevel.
id:3:initdefault:

# Boot-time system configuration/initialization script.
si::sysinit:/etc/init.d/rcS

# What to do in single-user mode.
~~:S:wait:/sbin/sulogin

# /etc/init.d executes the S and K scripts upon change of runlevel.
l0:0:wait:/etc/init.d/rc 0
l1:1:wait:/etc/init.d/rc 1
l2:2:wait:/etc/init.d/rc 2
l3:3:wait:/etc/init.d/rc 3
l4:4:wait:/etc/init.d/rc 4
l5:5:wait:/etc/init.d/rc 5
l6:6:wait:/etc/init.d/rc 6

# What to do when CTRL-ALT-DEL is pressed.
ca:12345:ctrlaltdel:/sbin/shutdown -t1 -a -r now

# Action on special keypress (ALT-UpArrow).
kb::kbrequest:/bin/echo "Keyboard Request -- edit /etc/inittab to let this work."

# What to do when the power fails/returns.
pf::powerwait:/etc/init.d/powerfail start
pn::powerfailnow:/etc/init.d/powerfail now
po::powerokwait:/etc/init.d/powerfail stop

# /sbin/getty invocations for the runlevels.
1:2345:respawn:/sbin/getty --noclear 38400 tty1
2:23:respawn:/sbin/getty 38400 tty2
3:23:respawn:/sbin/getty 38400 tty3
4:23:respawn:/sbin/getty 38400 tty4
5:23:respawn:/sbin/getty 38400 tty5
6:23:respawn:/sbin/getty 38400 tty6
```

#### Valores de `action` que debés reconocer

| Action | Semántica |
|---|---|
| `initdefault` | El runlevel al que se entra en el arranque. El campo `process` se ignora. **Nunca `0` ni `6`** — la máquina se apagaría o reiniciaría para siempre. |
| `sysinit` | Se ejecuta una vez en el arranque, antes de cualquier entrada `boot` o `bootwait`, sin importar el runlevel. |
| `boot` / `bootwait` | Se ejecuta en el arranque; `bootwait` bloquea hasta que termina. |
| `wait` | Arranca el proceso al entrar en los runlevels listados y **espera** a que termine. |
| `once` | Arranca una vez al entrar en el runlevel; no espera, no reinicia. |
| `respawn` | Reinicia el proceso cada vez que termina (así es como `getty` sobrevive al logout). |
| `ondemand` | Para los runlevels `a`, `b`, `c` — se ejecuta sin cambiar el runlevel actual. |
| `ctrlaltdel` | Se ejecuta cuando init recibe `SIGINT` (el kernel la envía con Ctrl+Alt+Del). |
| `kbrequest` | Se ejecuta ante una combinación especial de teclas. |
| `powerwait` / `powerfail` / `powerokwait` / `powerfailnow` | Integración con UPS vía `SIGPWR`. |

#### Los runlevels en sí

| Runlevel | Familia Red Hat | Familia Debian | Target de systemd |
|---|---|---|---|
| `0` | Halt / apagado | Halt / apagado | `poweroff.target` |
| `1` | Single user, sin red, sin daemons | Single user | `rescue.target` |
| `2` | Multi-user **sin NFS/red** | Multi-user completo con red | `multi-user.target` |
| `3` | Multi-user completo, consola de texto | idéntico a 2 | `multi-user.target` |
| `4` | Sin usar / definido por el sitio | idéntico a 2 | `multi-user.target` |
| `5` | Multi-user + login gráfico (X11) | idéntico a 2 (+ DM si está instalado) | `graphical.target` |
| `6` | Reboot | Reboot | `reboot.target` |
| `S` / `s` | Single user (Red Hat: alias de 1) | Ejecuta los scripts de `/etc/init.d/rcS` | `rescue.target` |

> **Trampa de examen:** los runlevels 2, 3 y 4 son distintos *solamente* en sistemas derivados de Red Hat. En Debian son idénticos por convención. Esto es una política de distribución, no una propiedad del kernel ni del init.

#### `/etc/init.d/` y la granja de symlinks `rcN.d`

`/etc/init.d/rc N` recorre `/etc/rcN.d/`, que contiene symlinks de vuelta a `/etc/init.d/`:

```console
# ls -l /etc/rc3.d/
lrwxrwxrwx 1 root root 17 Aug 12 11:02 K01apache2 -> ../init.d/apache2
lrwxrwxrwx 1 root root 15 Aug 12 11:02 K02rsync -> ../init.d/rsync
lrwxrwxrwx 1 root root 17 Aug 12 11:02 S01rsyslog -> ../init.d/rsyslog
lrwxrwxrwx 1 root root 13 Aug 12 11:02 S02cron -> ../init.d/cron
lrwxrwxrwx 1 root root 13 Aug 12 11:02 S03ssh -> ../init.d/ssh
```

- Los enlaces `K*` se invocan con `stop`, los `S*` con `start`.
- El número de dos dígitos es el **orden de ordenamiento**, procesado en orden ASCII. Este es todo el sistema de dependencias: ordenar por enteros asignados a mano, estrictamente secuencial, sin paralelismo y sin expresión real de dependencias.
- Gestionar esos symlinks es lo que hacen `chkconfig` (Red Hat) y `update-rc.d` (Debian):

```console
# chkconfig --level 35 httpd on          # Red Hat: enable in runlevels 3 and 5
# chkconfig --list sshd
sshd            0:off  1:off  2:on   3:on   4:on   5:on   6:off

# update-rc.d apache2 defaults           # Debian: create S/K links per LSB header
# update-rc.d -f apache2 remove
```

Los metadatos de orden de un script de init viven en su **cabecera LSB**:

```bash
#!/bin/sh
### BEGIN INIT INFO
# Provides:          apache2
# Required-Start:    $local_fs $remote_fs $network $syslog $named
# Required-Stop:     $local_fs $remote_fs $network $syslog $named
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Apache2 web server
### END INIT INFO
```

En un sistema con systemd estos scripts siguen funcionando: **`systemd-sysv-generator`** los parsea en el arranque y sintetiza units `.service` bajo `/run/systemd/generator.late/`.

```console
$ ls /run/systemd/generator.late/
graphical.target.wants  multi-user.target.wants  ossec.service

$ systemctl cat ossec.service | head -12
# /run/systemd/generator.late/ossec.service
# Automatically generated by systemd-sysv-generator

[Unit]
Documentation=man:systemd-sysv-generator(8)
SourcePath=/etc/init.d/ossec
Description=LSB: OSSEC HIDS
Before=multi-user.target
After=network-online.target remote-fs.target
```

### 2.3 systemd: targets

systemd reemplaza el runlevel lineal por un **grafo de dependencias de units**. Una unit `.target` no contiene ninguna lógica ejecutable — es un nodo con nombre usado como punto de sincronización y como asidero para arrastrar otras units.

```console
$ systemctl cat multi-user.target
# /usr/lib/systemd/system/multi-user.target
#  SPDX-License-Identifier: LGPL-2.1-or-later
#
#  This file is part of systemd.
#
#  systemd is free software; you can redistribute it and/or modify it
#  under the terms of the GNU Lesser General Public License as published by
#  the Free Software Foundation; either version 2.1 of the License, or
#  (at your option) any later version.

[Unit]
Description=Multi-User System
Documentation=man:systemd.special(7)
Requires=basic.target
Conflicts=rescue.service rescue.target
After=basic.target rescue.service rescue.target
AllowIsolate=yes
```

Tres campos cargan con todo el modelo:

- **`Requires=basic.target`** — la arista de dependencia dura que hace que alcanzar `multi-user.target` implique que el sistema básico está arriba.
- **`Conflicts=` / `After=`** — exclusión mutua con el modo rescue, más el ordenamiento.
- **`AllowIsolate=yes`** — este target puede usarse como argumento de `systemctl isolate`. Sin él, `isolate` se niega.

Las units se arrastran mediante directorios `.wants`/`.requires`, que son simplemente granjas de symlinks — el descendiente conceptual directo de `rcN.d`, pero con directivas reales de dependencia y ordenamiento en lugar de números de orden:

```console
$ ls /etc/systemd/system/multi-user.target.wants/
chronyd.service  crond.service  irqbalance.service  kubelet.service
NetworkManager.service  rsyslog.service  sshd.service  tuned.service
```

#### La ruta de búsqueda de units — la precedencia importa

| Ruta | Dueño | Precedencia | Propósito |
|---|---|---|---|
| `/etc/systemd/system/` | **Admin local** | **La más alta** | Tus overrides, drop-ins, symlinks de enable |
| `/run/systemd/system/` | Runtime | Media | Generadores, units transitorias (`systemd-run`) |
| `/usr/lib/systemd/system/` | **Gestor de paquetes** | La más baja | Units del vendor — **nunca editar estas** |

`/lib/systemd/system` es un symlink a `/usr/lib/systemd/system` en distribuciones con `/usr` fusionado. Un archivo de unit colocado en `/etc/systemd/system/foo.service` **enmascara completamente** al del vendor. Para *modificar* en lugar de reemplazar, usá un directorio drop-in `foo.service.d/*.conf` (ver §4.5).

`/etc/systemd/` también alberga la configuración del propio manager: `system.conf`, `user.conf`, `logind.conf`, `journald.conf`, `sleep.conf`, más sus directorios drop-in `.d/`.

#### Targets de compatibilidad con runlevels

```console
$ ls -l /usr/lib/systemd/system/runlevel?.target
lrwxrwxrwx. 1 root root 15 Jul 14 03:11 /usr/lib/systemd/system/runlevel0.target -> poweroff.target
lrwxrwxrwx. 1 root root 13 Jul 14 03:11 /usr/lib/systemd/system/runlevel1.target -> rescue.target
lrwxrwxrwx. 1 root root 17 Jul 14 03:11 /usr/lib/systemd/system/runlevel2.target -> multi-user.target
lrwxrwxrwx. 1 root root 17 Jul 14 03:11 /usr/lib/systemd/system/runlevel3.target -> multi-user.target
lrwxrwxrwx. 1 root root 17 Jul 14 03:11 /usr/lib/systemd/system/runlevel4.target -> multi-user.target
lrwxrwxrwx. 1 root root 16 Jul 14 03:11 /usr/lib/systemd/system/runlevel5.target -> graphical.target
lrwxrwxrwx. 1 root root 13 Jul 14 03:11 /usr/lib/systemd/system/runlevel6.target -> reboot.target
```

Notá la asimetría: tres runlevels colapsan en `multi-user.target`, así que el mapeo **target → runlevel es con pérdida**. `runlevel` en un sistema con systemd reporta un número de mejor esfuerzo derivado de `/run/utmp`, no de ningún estado real de runlevel.

#### `/etc/inittab` bajo systemd

systemd **no lee `/etc/inittab` en absoluto**. Red Hat distribuye el archivo solo como lápida:

```console
$ cat /etc/inittab
# inittab is no longer used.
#
# ADDING CONFIGURATION HERE WILL HAVE NO EFFECT ON YOUR SYSTEM.
#
# Ctrl-Alt-Delete is handled by /usr/lib/systemd/system/ctrl-alt-del.target
#
# systemd uses 'targets' instead of runlevels. By default, there are two main targets:
#
# multi-user.target: analogous to runlevel 3
# graphical.target: analogous to runlevel 5
#
# To view current default target, run:
# systemctl get-default
#
# To set a default target, run:
# systemctl set-default TARGET.target
```

### 2.4 Comparación de compromisos

| Dimensión | SysV init | systemd |
|---|---|---|
| Configuración | Un archivo (`/etc/inittab`) + scripts de shell | Archivos de unit declarativos, en capas `/usr/lib` → `/run` → `/etc` |
| Modelo de dependencias | Implícito, vía orden numérico de dos dígitos en `rcN.d` | Explícito: `Requires=`, `Wants=`, `After=`, `Before=`, `Conflicts=`, `BindsTo=` |
| Paralelismo | Ninguno — estrictamente secuencial | Total; la activación por socket/D-Bus/path/device elimina restricciones de orden |
| Tiempo de arranque (servidor típico) | 45–120 s | 3–20 s |
| Granularidad de estados | 7 runlevels enteros | Cantidad arbitraria de targets con nombre; los targets propios son triviales |
| Supervisión de servicios | `respawn` solo para entradas de `inittab` | Cada servicio: `Restart=`, `RestartSec=`, `StartLimitBurst=`, watchdogs |
| Seguimiento de procesos | Archivos PID (con carreras, falsificables, obsoletos) | cgroups — los procesos de un servicio no pueden escapar |
| Matar un servicio | `kill $(cat /var/run/x.pid)`; los hijos con doble fork sobreviven | Todo el cgroup recibe `SIGTERM`, luego `SIGKILL`. Nada sobrevive |
| Control de recursos | `ulimit` en el script de init | cgroup v2 completo: `MemoryMax=`, `CPUQuota=`, `IOWeight=` |
| Logging | Lo que el script redirija, más `syslog` | Journal estructurado, indexado por unit/boot/prioridad |
| Orden de apagado | Inverso a los números `S`, con mejor esfuerzo | Transacción inversa computada con timeouts por unit |
| Depurabilidad | `sh -x /etc/init.d/foo start` | `systemd-analyze critical-chain`, `blame`, `plot`, `dump` |
| Costo de aprendizaje | Bajo — es todo shell | Alto — superficie grande, muchas directivas |
| Portabilidad | Shell POSIX, corre en cualquier lado | Solo Linux (cgroups, `epoll`, `signalfd`, `fanotify`) |
| Modo de fallo cuando algo está mal | El script se cuelga en el arranque, en silencio, sin timeout | El job se cuelga, pero expira y reporta la unit culpable por nombre |

> **Recuadro — Upstart.** Entre los dos, Ubuntu (6.10–14.10) y RHEL 6 distribuyeron Upstart: dirigido por eventos, con jobs en `/etc/init/*.conf`, controlado con `initctl list`, `start`, `stop`, `status`. Está fuera del alcance de 101.3 en la v5.0 pero aparece en 101.2. Leía `/etc/inittab` solo para `initdefault`.

---

## 3. Establecer el runlevel / boot target por defecto

### 3.1 systemd — el ajuste persistente

`default.target` es un **symlink en `/etc/systemd/system/`**. Ese es todo el mecanismo.

```console
$ systemctl get-default
graphical.target

$ ls -l /etc/systemd/system/default.target
lrwxrwxrwx. 1 root root 40 Jul 14 03:22 /etc/systemd/system/default.target -> /usr/lib/systemd/system/graphical.target

# systemctl set-default multi-user.target
Removed "/etc/systemd/system/default.target".
Created symlink '/etc/systemd/system/default.target' → '/usr/lib/systemd/system/multi-user.target'.

$ systemctl get-default
multi-user.target
```

La operación manual equivalente — vale la pena conocerla porque es lo que hacés desde una shell de rescate donde `systemctl` no puede hablar con un manager en ejecución:

```console
# ln -sf /usr/lib/systemd/system/multi-user.target /etc/systemd/system/default.target
```

`systemctl set-default` **no cambia el estado en ejecución**. La máquina sigue gráfica hasta que reinicies o hagas `isolate`. Esta división — persistente vs. transitorio — es la distinción más útil de este objetivo:

| Intención | Comando | ¿Persiste al reiniciar? | ¿Cambia el estado actual? |
|---|---|---|---|
| Cambiar en qué arranca el sistema | `systemctl set-default X` | **Sí** | No |
| Cambiar el estado actual ahora | `systemctl isolate X` | No | **Sí** |
| Cambiar solo este arranque | GRUB: `systemd.unit=X` | No (un arranque) | n/a — aplica en el arranque |
| Ambos | `set-default X && isolate X` | Sí | Sí |

### 3.2 SysV — el ajuste persistente

Editá la línea `initdefault`:

```console
# grep initdefault /etc/inittab
id:5:initdefault:

# sed -i 's/^id:5:initdefault:/id:3:initdefault:/' /etc/inittab
# telinit q          # re-read /etc/inittab without rebooting
```

`telinit q` (o `Q`) hace que `init` reexamine `/etc/inittab`. **No** cambia el runlevel actual — la misma división persistente/transitorio que en systemd. `telinit u` (o `U`) hace que init se re-ejecute a sí mismo preservando el estado, que es el análogo SysV de `systemctl daemon-reexec`.

### 3.3 Leer el estado actual

```console
$ runlevel
N 5
```

Dos campos: runlevel **anterior** y runlevel **actual**. `N` significa "None" — no ha ocurrido ninguna transición desde el arranque.

```console
$ who -r
         run-level 5  2026-08-25 09:14

$ systemctl is-system-running
running
```

`systemctl is-system-running` es el estado que querés en los health checks. Sus valores:

| Valor | Significado |
|---|---|
| `initializing` | Arranque temprano, antes de `basic.target` |
| `starting` | Todavía arrancando; `default.target` aún no alcanzado |
| `running` | Totalmente operativo, **sin units fallidas** |
| `degraded` | Operativo, pero **una o más units fallaron** — revisá `systemctl --failed` |
| `maintenance` | En `rescue.target` o `emergency.target` |
| `stopping` | Apagándose |
| `offline` / `unknown` | systemd no está corriendo / estado no determinable |

El estado de salida es `0` solo para `running`, lo que lo hace directamente utilizable en una compuerta de readiness:

```console
$ systemctl is-system-running --quiet && echo "node healthy" || echo "node degraded"
degraded

$ systemctl --failed
  UNIT                    LOAD   ACTIVE SUB    DESCRIPTION
● nfs-idmapd.service      loaded failed failed NFSv4 ID-name mapping service
● systemd-timesyncd.service loaded failed failed Network Time Synchronization

2 loaded units listed.
```

---

## 4. Cambiar entre targets en tiempo de ejecución

### 4.1 `systemctl isolate`

`isolate` arranca la unit indicada **y detiene todo lo que no sea requerido por ella**. Es el equivalente en systemd de `init N`.

```console
# systemctl isolate multi-user.target
```

Mirá lo que pasa realmente — esta es una máquina gráfica bajando a modo texto:

```console
# systemctl list-units --type=service --state=running | wc -l
44
# systemctl isolate multi-user.target
# systemctl list-units --type=service --state=running | wc -l
27
# systemctl is-active gdm.service
inactive
# systemctl is-active graphical.target
inactive
# systemctl is-active multi-user.target
active
```

Si el target no es aislable:

```console
# systemctl isolate network-online.target
Failed to isolate network-online.target: Operation refused, unit network-online.target may
be requested by dependency only (it is configured to refuse manual start/stop).
See system logs and 'systemctl status network-online.target' for details.
```

Targets aislables en un sistema estándar:

```console
$ grep -l 'AllowIsolate=yes' /usr/lib/systemd/system/*.target | xargs -n1 basename
default.target
emergency.target
graphical.target
multi-user.target
rescue.target
```

Más `poweroff.target`, `reboot.target`, `halt.target`, `kexec.target`, `exit.target`, que también permiten el aislamiento y son la forma en que los verbos de apagado están implementados internamente.

### 4.2 Compatibilidad con `telinit` / `init`

En un sistema con systemd, `telinit` e `init` son symlinks a `systemctl`:

```console
$ ls -l /sbin/telinit /sbin/init /sbin/runlevel
lrwxrwxrwx. 1 root root 16 Jul 14 03:11 /sbin/init -> ../lib/systemd/systemd
lrwxrwxrwx. 1 root root 16 Jul 14 03:11 /sbin/runlevel -> ../bin/systemctl
lrwxrwxrwx. 1 root root 16 Jul 14 03:11 /sbin/telinit -> ../bin/systemctl
```

La traducción que se realiza:

| Comando legacy | Equivalente en systemd |
|---|---|
| `init 0` / `telinit 0` | `systemctl isolate poweroff.target` → `systemctl poweroff` |
| `init 1` / `telinit 1` | `systemctl isolate rescue.target` |
| `init 2` `3` `4` | `systemctl isolate multi-user.target` |
| `init 5` | `systemctl isolate graphical.target` |
| `init 6` | `systemctl isolate reboot.target` → `systemctl reboot` |
| `init s` / `init S` | `systemctl isolate rescue.target` |
| `telinit q` | *(no-op; usá `systemctl daemon-reload`)* |
| `telinit u` | `systemctl daemon-reexec` |

Comportamiento real, incluido el aviso de obsolescencia:

```console
# init 3
# journalctl -b -u systemd --since "1 min ago" | tail -3
Aug 25 10:41:02 node07 systemd[1]: Stopped target Graphical Interface.
Aug 25 10:41:02 node07 systemd[1]: Stopping GNOME Display Manager...
Aug 25 10:41:03 node07 systemd[1]: Reached target Multi-User System.
```

```console
# telinit 3
telinit: Deprecated 'runlevel' command called. Use 'systemctl isolate' instead.
```

> **Regla de producción:** usá `systemctl isolate <target>` en los scripts. `init N` es para la memoria muscular y para el examen; oculta a qué target llegaste realmente en distribuciones donde 2/3/4 colapsan.

### 4.3 Single user, rescue y emergency

Son tres peldaños distintos, y confundirlos cuesta tiempo real de recuperación.

| | `rescue.target` (runlevel 1 / `single`) | `emergency.target` |
|---|---|---|
| `sysinit.target` alcanzado | **Sí** | **No** |
| Filesystems locales | Montados (`local-fs.target`) | Solo `/`, y de **solo lectura** |
| Swap | Activada | No activada |
| Red | No | No |
| Servicios | Casi ninguno | Ninguno en absoluto |
| Shell | `sulogin` en consola vía `rescue.service` | `sulogin` en consola vía `emergency.service` |
| Contraseña de root requerida | Sí | Sí |
| Usar cuando | El filesystem está bien, un servicio está roto | `/etc/fstab` está roto, el FS raíz necesita `fsck` |

```console
# systemctl rescue
Broadcast message from root@node07 (Mon 2026-08-25 10:47:11 UTC):

The system will now be rebooted into rescue mode!
```

Usá `--no-wall` para suprimir ese broadcast. En la consola:

```
[  OK  ] Stopped target Multi-User System.
         Starting Rescue Shell...
You are in rescue mode. After logging in, type "journalctl -xb" to view
system logs, "systemctl reboot" to reboot, or "exit" to continue bootup.
Give root password for maintenance
(or press Control-D to continue):
```

Modo emergency, y lo primero que siempre tenés que hacer ahí:

```console
# systemctl emergency
```
```
Give root password for maintenance
(or press Control-D to continue): 
[root@node07 ~]# mount | head -1
/dev/mapper/vg0-root on / type xfs (ro,relatime,attr2,inode64,logbufs=8,logbsize=32k,noquota)
[root@node07 ~]# mount -o remount,rw /
[root@node07 ~]# vi /etc/fstab
[root@node07 ~]# systemctl daemon-reload
[root@node07 ~]# systemctl default
```

`systemctl default` aísla `default.target` — la salida de rescue/emergency sin reiniciar.

### 4.4 Seleccionar un target en el arranque

Interrumpí GRUB, presioná `e` sobre la entrada, agregá al final de la línea `linux`, después `Ctrl-X` / `F10` para arrancar. Son de un solo uso: no se escribe nada en disco.

| Parámetro del kernel | Efecto |
|---|---|
| `systemd.unit=multi-user.target` | Arrancar en un target arbitrario (forma canónica) |
| `systemd.unit=rescue.target` | Modo rescue |
| `1`, `s`, `S`, `single` | Alias legacy → `rescue.target` |
| `emergency` o `-b` | → `emergency.target` |
| `rd.break` | Parar en el **initramfs**, antes del switch-root (raíz en `/sysroot`) |
| `init=/bin/bash` | Reemplazar PID 1 por completo — sin systemd, sin servicios, raíz de solo lectura |
| `systemd.debug_shell=1` | Shell de root en tty9, **sin contraseña** (ver la advertencia abajo) |
| `systemd.log_level=debug` | Logging verboso de PID 1 |
| `systemd.mask=foo.service` | Enmascarar una unit solo para este arranque |
| `systemd.setenv=NAME=value` | Definir una variable de entorno para PID 1 y sus hijos |
| `systemd.confirm_spawn=1` | Confirmar interactivamente cada proceso que systemd lanza |

La opción nuclear, cuando la contraseña de root es desconocida o `sulogin` no arranca:

```
linux ($root)/vmlinuz-6.9.7-200.fc40.x86_64 root=/dev/mapper/vg0-root ro rd.lvm.lv=vg0/root init=/bin/bash
```
```console
bash-5.2# mount -o remount,rw /
bash-5.2# passwd root
New password:
Retype new password:
passwd: all authentication tokens updated successfully.
bash-5.2# touch /.autorelabel        # MANDATORY on SELinux systems
bash-5.2# exec /usr/lib/systemd/systemd
```

Olvidarse de `/.autorelabel` en un sistema SELinux en modo enforcing deja `/etc/shadow` con la etiqueta equivocada y la nueva contraseña inutilizable — la máquina arranca y rechaza la contraseña que acabás de poner. `exec /usr/lib/systemd/systemd` entrega el PID 1 a systemd en lugar de reiniciar; si falla, `mount -o remount,ro / && reboot -f`.

> **Nota de endurecimiento:** `systemd.debug_shell=1` da una shell de root sin autenticación. Cualquier cosa que pueda editar la línea de comandos del kernel ya tiene root, así que esto no es un agujero nuevo *si* GRUB está protegido con contraseña (`grub2-setpassword`) y el acceso físico/por consola está controlado. En una instancia cloud con una consola serie expuesta a la cuenta, sí lo es. Tratá a GRUB como parte del límite de autenticación.

### 4.5 Targets propios — el patrón de producción

Las flotas reales necesitan estados que no son ni "multi-user" ni "graphical": un estado de *mantenimiento* donde el nodo está arriba, accesible por SSH y monitoreado, pero sin servir nada.

`/etc/systemd/system/maintenance.target`:

```ini
[Unit]
Description=Maintenance Mode (SSH + monitoring only, no workloads)
Documentation=https://runbooks.example.com/maintenance-target
Requires=multi-user.target
After=multi-user.target
Conflicts=workload.target
AllowIsolate=yes
```

`/etc/systemd/system/workload.target`:

```ini
[Unit]
Description=Production Workload
Documentation=https://runbooks.example.com/workload-target
Requires=multi-user.target
After=multi-user.target network-online.target
AllowIsolate=yes

[Install]
WantedBy=multi-user.target
```

Atá los servicios de workload a él:

```console
# mkdir -p /etc/systemd/system/kubelet.service.d
# cat > /etc/systemd/system/kubelet.service.d/10-workload-target.conf <<'EOF'
[Unit]
PartOf=workload.target

[Install]
WantedBy=workload.target
EOF
# systemctl daemon-reload
# systemctl disable kubelet.service
# systemctl enable kubelet.service
Created symlink '/etc/systemd/system/workload.target.wants/kubelet.service' → '/usr/lib/systemd/system/kubelet.service'.
```

`PartOf=` es la directiva que hace que `systemctl stop workload.target` también detenga `kubelet.service` — una relación `Wants=`/`WantedBy=` por sí sola no lo haría.

```console
# systemctl isolate maintenance.target
# systemctl is-active kubelet.service sshd.service node_exporter.service
inactive
active
active
```

---

## 5. Apagado y reinicio

### 5.1 `shutdown` — el que deberías usar con humanos presentes

```
shutdown [OPTIONS...] [TIME] [WALL...]
```

| Opción | Efecto |
|---|---|
| `-P`, `--poweroff` | Apagar la máquina. **Este es el valor por defecto.** |
| `-H`, `--halt` | Halt: detener la CPU, dejar la máquina con energía |
| `-r`, `--reboot` | Reiniciar |
| `-h` | Equivalente a `--poweroff`, salvo que también se pase `--halt` |
| `-k` | **No apagar** — solo enviar el mensaje wall (dry run / aviso) |
| `-c` | **Cancelar** un apagado programado pendiente |
| `--no-wall` | No enviar mensaje wall |
| `-t SEC`, `-a`, `-n`, `-q`, `-D` | Aceptados por compatibilidad con SysV, **ignorados** por systemd |

Formatos de `TIME`: `now`, `+m` (minutos desde ahora), `hh:mm` (próxima ocurrencia de esa hora de reloj). Si se omite `TIME`, se asume `+1`.

```console
# shutdown -r +15 "Kernel patch CHG-4417. Node reboots at 11:20 UTC. Save your work."
Shutdown scheduled for Mon 2026-08-25 11:20:44 UTC, use 'shutdown -c' to cancel.
```

Cada terminal con sesión iniciada recibe:

```
Broadcast message from root@bastion01 (Mon 2026-08-25 11:05:44 UTC):

Kernel patch CHG-4417. Node reboots at 11:20 UTC. Save your work.

The system will reboot at Mon 2026-08-25 11:20:44 UTC!
```

El apagado programado lo lleva **`systemd-logind`**, no un job en el manager, y por eso `systemctl list-jobs` no muestra nada:

```console
# cat /run/systemd/shutdown/scheduled
USEC=1787660444000000
WARN_WALL=1
MODE=reboot

# busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
        org.freedesktop.login1.Manager ScheduledShutdown
(st) "reboot" 1787660444000000
```

Cinco minutos antes del plazo, logind crea `/run/nologin`, y el `pam_nologin` de PAM empieza a rechazar los logins que no sean de root:

```console
$ ssh deploy@node07
Kernel patch CHG-4417. Node reboots at 11:20 UTC. Save your work.
The system is going down for reboot at Mon 2026-08-25 11:20:44 UTC!
Connection closed by 10.20.4.7 port 22
```

Cancelar:

```console
# shutdown -c
```
```
Broadcast message from root@bastion01 (Mon 2026-08-25 11:12:03 UTC):

The system shutdown has been cancelled
```

El dry run, para anunciar una ventana sin armar nada:

```console
# shutdown -k +30 "DRILL ONLY - no shutdown will occur. Verifying broadcast reaches all sessions."
```

> **Trampa de examen:** `-h` en el `shutdown` de systemd es *apagar*, coincidiendo con la práctica universal; el `shutdown -h` histórico de SysV significaba *halt* y dejaba la máquina con energía salvo que el kernel soportara apagado por APM/ACPI. `-H` es la bandera inequívoca de "halt, seguir con energía" en systemd.

### 5.2 Verbos de `systemctl` y los alias legacy

```console
$ ls -l /sbin/reboot /sbin/poweroff /sbin/halt /sbin/shutdown
lrwxrwxrwx. 1 root root 16 Jul 14 03:11 /sbin/halt -> ../bin/systemctl
lrwxrwxrwx. 1 root root 16 Jul 14 03:11 /sbin/poweroff -> ../bin/systemctl
lrwxrwxrwx. 1 root root 16 Jul 14 03:11 /sbin/reboot -> ../bin/systemctl
lrwxrwxrwx. 1 root root 16 Jul 14 03:11 /sbin/shutdown -> ../bin/systemctl
```

| Comando | Target aislado | Notas |
|---|---|---|
| `systemctl poweroff` / `poweroff` | `poweroff.target` | Parada limpia de todas las units, después apagado por ACPI |
| `systemctl halt` / `halt` | `halt.target` | Parada limpia, CPU detenida, **sigue con energía** |
| `halt -p` | — | Halt y después apagar (equivalente a `poweroff`) |
| `systemctl reboot` / `reboot` | `reboot.target` | Parada limpia, después `reboot(2)` |
| `systemctl kexec` | `kexec.target` | Arrancar un kernel precargado, **salteando el POST del firmware** |
| `systemctl soft-reboot` | `soft-reboot.target` | systemd ≥ 254: reiniciar solo el userspace, kernel y hardware siguen arriba |
| `systemctl suspend` / `hibernate` / `hybrid-sleep` / `suspend-then-hibernate` | — | Gestión de energía, manejada por logind |
| `systemctl exit` | `exit.target` | Solo tiene sentido para un manager de usuario o el PID 1 de un contenedor |

Modificadores útiles:

```console
# systemctl reboot --message="CHG-4417 kernel 6.9.7 -> 6.9.11"
# systemctl reboot --boot-loader-entry=fedora-40-rescue.conf   # one-shot alternate entry
# systemctl reboot --boot-loader-menu=30                       # show GRUB menu 30 s next boot
# systemctl reboot --firmware-setup                            # reboot into UEFI setup
# systemctl poweroff -i                                        # ignore inhibitor locks
```

### 5.3 `--force`: qué saltea realmente cada nivel

De `systemctl(1)`, y esto es relevante para el examen *y* para la carrera:

| Invocación | Units detenidas limpiamente | Procesos matados | Filesystems desmontados/remontados `ro` | Manager contactado |
|---|---|---|---|---|
| `systemctl reboot` | **Sí** | vía la ruta de parada normal | Sí | Sí |
| `systemctl reboot -f` | **No** | Sí, a la fuerza | Sí | Sí |
| `systemctl reboot -ff` | No | **No** | **No, y sin `sync()`** | **No** |

`-ff` llama a `reboot(2)` directamente desde `systemctl`. Funciona incluso cuando PID 1 se colgó, que es exactamente cuando lo necesitás — y es el último recurso antes de un reset por hardware, porque la page cache sin volcar se pierde.

```console
# systemctl reboot -ff
```
No imprime nada. La máquina ya no está.

El equivalente a nivel de kernel, para cuando ni siquiera eso está disponible — Magic SysRq:

```console
# echo 1 > /proc/sys/kernel/sysrq
# echo s > /proc/sysrq-trigger    # Sync
# echo u > /proc/sysrq-trigger    # Unmount / remount read-only
# echo b > /proc/sysrq-trigger    # Reboot immediately, no sync
```

El orden mnemotécnico es **R-E-I-S-U-B** ("Reboot Even If System Utterly Broken") con unos segundos entre letras.

### 5.4 Compromisos: qué mecanismo de reinicio

| Mecanismo | Downtime | POST de firmware | Kernel reemplazado | Re-inicialización de hardware | Riesgo de pérdida de datos | Usar cuando |
|---|---|---|---|---|---|---|
| `shutdown -r +N` | N min + arranque completo | Sí | Sí | Sí | Ninguno | Mantenimiento anunciado con humanos conectados |
| `systemctl reboot` | Arranque completo (30 s–5 min en bare metal) | Sí | Sí | Sí | Ninguno | Automatización, después del drain |
| `systemctl kexec` | ~10–20 s | **No** | Sí | Parcial | Bajo | Bare metal con POST de BIOS/RAID de 3 minutos; flotas grandes |
| `systemctl soft-reboot` | ~2–5 s | No | **No** | No | Bajo | Solo actualización de userspace/imagen del SO, kernel sin cambios (systemd ≥ 254) |
| `systemctl reboot -f` | ~5 s | Sí | Sí | Sí | Moderado | Una unit está trabada y el nodo tiene que volver ya |
| `systemctl reboot -ff` | ~1 s | Sí | Sí | Sí | **Alto** | El propio PID 1 está colgado |
| SysRq `b` | ~1 s | Sí | Sí | Sí | **Muy alto** | Solo por consola, kernel parcialmente vivo |
| Ciclo de energía fuera de banda (IPMI/Redfish) | Arranque completo | Sí | Sí | Sí | **Muy alto** | No responde absolutamente nada |

`kexec` en la práctica — la razón por la que vale la pena configurarlo en bare metal:

```console
# kexec -l /boot/vmlinuz-6.9.11-200.fc40.x86_64 \
        --initrd=/boot/initramfs-6.9.11-200.fc40.x86_64.img \
        --reuse-cmdline
# kexec -e            # or, to stop units cleanly first:
# systemctl kexec
```

`--reuse-cmdline` copia `/proc/cmdline`, que es lo que mantiene correctos `root=`, `rd.lvm.lv=` y las banderas de SELinux. Equivocarse ahí produce un kernel panic sin ninguna pantalla de firmware que mirar — siempre probá `kexec` en un nodo con consola serie antes de adoptarlo en toda la flota.

### 5.5 Qué hace `systemd-shutdown` después de que se detiene la última unit

Una vez alcanzado el target de apagado, PID 1 hace `exec` de `/usr/lib/systemd/systemd-shutdown`, que se convierte en el nuevo PID 1 y realiza el desmantelamiento que las units no pudieron:

```
[  OK  ] Reached target System Power Off.
[  184.221871] systemd-shutdown[1]: Syncing filesystems and block devices.
[  184.243109] systemd-shutdown[1]: Sending SIGTERM to remaining processes...
[  184.271488] systemd-journald[712]: Received SIGTERM from PID 1 (systemd-shutdow).
[  184.398214] systemd-shutdown[1]: Sending SIGKILL to remaining processes...
[  184.401552] systemd-shutdown[1]: Sending SIGKILL to PID 1841 (containerd-shim).
[  184.420031] systemd-shutdown[1]: Unmounting file systems.
[  184.427716] [1892]: Remounting '/var' read-only with options 'seclabel,attr2,inode64'.
[  184.451209] [1893]: Unmounting '/var'.
[  184.470884] systemd-shutdown[1]: All filesystems unmounted.
[  184.471102] systemd-shutdown[1]: Deactivating swaps.
[  184.472441] systemd-shutdown[1]: All swaps deactivated.
[  184.472660] systemd-shutdown[1]: Detaching loop devices.
[  184.481003] systemd-shutdown[1]: All loop devices detached.
[  184.481219] systemd-shutdown[1]: Stopping MD devices.
[  184.482771] systemd-shutdown[1]: All MD devices stopped.
[  184.482991] systemd-shutdown[1]: Detaching DM devices.
[  184.494128] systemd-shutdown[1]: All DM devices detached.
[  184.502217] systemd-shutdown[1]: Powering off.
[  184.510337] ACPI: PM: Preparing to enter system sleep state S5
[  184.518899] reboot: Power down
```

Dos cosas importan operativamente:

1. **`Sending SIGKILL to PID 1841 (containerd-shim)`** es un síntoma, no un bug en `systemd-shutdown` — significa que una unit no logró limpiar sus propios hijos. Rastrealos; se correlacionan con estado de contenedores corrupto después del reinicio.
2. Si `Unmounting file systems` nunca completa, el nodo se cuelga para siempre sin salida por consola. Ese es el caso de `RebootWatchdogSec` (§7.5).

### 5.6 Ctrl+Alt+Del y `acpid` — transiciones disparadas por hardware

**Ctrl+Alt+Del.** El driver de consola del kernel o bien señaliza a PID 1 o bien resetea la máquina directamente, controlado por `/proc/sys/kernel/ctrl-alt-del`:

```console
$ cat /proc/sys/kernel/ctrl-alt-del
0
```

- `0` — enviar `SIGINT` a PID 1 (elegante; systemd arranca `ctrl-alt-del.target`).
- `1` — reset duro inmediato, sin sync. Se define con `# sysctl -w kernel.ctrl-alt-del=1`.

Bajo systemd, `ctrl-alt-del.target` es un symlink a `reboot.target`:

```console
$ ls -l /usr/lib/systemd/system/ctrl-alt-del.target
lrwxrwxrwx. 1 root root 13 Jul 14 03:11 /usr/lib/systemd/system/ctrl-alt-del.target -> reboot.target
```

Para deshabilitarlo en un servidor con consola accesible:

```console
# systemctl mask ctrl-alt-del.target
Created symlink '/etc/systemd/system/ctrl-alt-del.target' → '/dev/null'.
# systemctl daemon-reload
```

Notá que systemd tiene una protección contra ráfagas independiente de ese target: 7 pulsaciones en 2 segundos disparan un reinicio duro inmediato, asumiendo que el operador está desesperado.

El equivalente SysV es la línea `ctrlaltdel` en `/etc/inittab`:

```
ca:12345:ctrlaltdel:/sbin/shutdown -t1 -a -r now
```

Quitar esa línea, o apuntarla a `/bin/true`, deshabilita la combinación de teclas.

**`acpid`.** El daemon de eventos ACPI lee eventos de hardware (botón de encendido, interruptor de tapa, térmicos, adaptador de CA) del socket netlink ACPI del kernel y ejecuta handlers de shell.

```console
$ systemctl status acpid
● acpid.service - ACPI event daemon
     Loaded: loaded (/usr/lib/systemd/system/acpid.service; disabled; preset: disabled)
     Active: active (running) since Mon 2026-08-25 09:14:31 UTC; 1h 41min ago
TriggeredBy: ● acpid.socket
       Docs: man:acpid(8)
   Main PID: 998 (acpid)
      Tasks: 1 (limit: 38304)
     Memory: 400.0K
        CPU: 12ms
     CGroup: /system.slice/acpid.service
             └─998 /usr/sbin/acpid

$ cat /etc/acpi/events/powerbtn
event=button/power.*
action=/etc/acpi/actions/powerbtn.sh
```

```bash
#!/bin/sh
# /etc/acpi/actions/powerbtn.sh
/usr/bin/logger -t acpid "ACPI power button pressed; initiating graceful poweroff"
/usr/bin/wall "Power button pressed. System will power off in 60 seconds. Run 'shutdown -c' to abort."
/usr/sbin/shutdown -P +1 "ACPI power button"
```

Mirá los eventos en vivo mientras probás:

```console
# acpi_listen
button/power PBTN 00000080 00000000
button/lid LID close
ac_adapter ACAD 00000080 00000000
```

**El conflicto que tenés que conocer:** en una máquina con systemd, `systemd-logind` también maneja el botón de encendido — toma un agarre exclusivo sobre el dispositivo de entrada del botón ACPI vía evdev. Si `acpid` también está instalado, podés tener doble manejo o, más comúnmente, que el handler de `acpid` nunca se dispare en silencio. Decidí quién es dueño del botón:

`/etc/systemd/logind.conf.d/10-power-button.conf`:

```ini
[Login]
# poweroff | reboot | halt | kexec | suspend | hibernate | hybrid-sleep | lock | ignore
HandlePowerKey=poweroff
HandlePowerKeyLongPress=poweroff
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
# Never let a non-root desktop session block a maintenance shutdown
InhibitorsMax=8192
InhibitDelayMaxSec=180
```

```console
# systemctl restart systemd-logind
# loginctl show-session --property=IdleHint --property=Active c1
```

Poné `HandlePowerKey=ignore` si querés que `acpid` sea el dueño; dejalo en `poweroff` y deshabilitá `acpid` en servidores, que es la opción más simple.

### 5.7 Inhibitor locks — la forma correcta de decir "ahora no"

Un inhibitor lock es un descriptor de archivo mantenido por un proceso que le pide a logind **bloquear** o **retrasar** una transición de apagado/suspensión/inactividad.

```console
# systemd-inhibit --list
WHO                          UID  USER  PID   COMM            WHAT                                                          WHY                                    MODE
NetworkManager               0    root  1024  NetworkManager  sleep                                                         NetworkManager needs to turn off ...   delay
kubelet                      0    root  2141  kubelet         shutdown                                                      Kubelet needs time to handle node ...  delay
UPower                       0    root  1180  upowerd         sleep                                                         Pause device polling                   delay
Session c1 of user operator  1000 oper  3401  systemd-logind  handle-power-key:handle-suspend-key:handle-hibernate-key:...  Session is being idle                  block

4 inhibitors listed.
```

| Modo | Comportamiento | ¿Anulable? |
|---|---|---|
| `delay` | La transición espera, hasta `InhibitDelayMaxSec` (por defecto **5 s**), después sigue de todas formas | Acotado por configuración |
| `block` | La transición se rechaza por completo | Sí, por root con `-i` / `--check-inhibitors=no` |

Lo que se puede inhibir: `shutdown`, `sleep`, `idle`, `handle-power-key`, `handle-suspend-key`, `handle-hibernate-key`, `handle-lid-switch`, `handle-reboot-key`.

Envolvé cualquier operación que no deba interrumpirse:

```console
# systemd-inhibit --what=shutdown:idle \
                  --who="pg_basebackup" \
                  --why="Full base backup of cluster prod-pg-01 in progress" \
                  --mode=block \
                  -- /usr/local/sbin/nightly-basebackup.sh
```

Mientras eso corre:

```console
$ systemctl poweroff
Operation inhibited by "pg_basebackup" (PID 8823 "systemd-inhibit", user root),
reason is "Full base backup of cluster prod-pg-01 in progress".
Please retry operation after closing inhibitors and logging out other users.
Alternatively, ignore inhibitors and users with 'systemctl poweroff -i'.
```

---

## 6. Alertar a los usuarios y terminar procesos correctamente

### 6.1 `wall` — broadcast a todas las terminales

```console
# wall "Maintenance window CHG-4417 opens in 10 minutes. Commit and push."
```

Cada terminal con recepción de mensajes habilitada ve:

```
Broadcast message from root@bastion01 (pts/3) (Mon Aug 25 11:05:12 2026):

Maintenance window CHG-4417 opens in 10 minutes. Commit and push.
```

| Forma | Efecto |
|---|---|
| `wall "text"` | Transmitir la cadena literal |
| `wall /path/to/file` | Transmitir el contenido del archivo |
| `some_cmd \| wall` | Transmitir desde stdin |
| `wall -n` / `--nobanner` | Suprimir el banner "Broadcast message from…" (**solo root**) |
| `wall -t SEC` | Timeout de escritura por terminal (por defecto 300 s), evita bloquearse en una tty atascada |
| `wall -g GROUP` | Solo a los miembros de `GROUP` (util-linux ≥ 2.32) |

La recepción se controla por terminal con `mesg`:

```console
$ mesg
is y
$ mesg n
$ mesg
is n
```

Un usuario con `mesg n` igualmente recibe los mensajes enviados por **root** — no podés optar por no recibir un broadcast de root, y ese es el punto.

Para una sola persona, usá `write`:

```console
# who
operator pts/0  2026-08-25 09:40 (10.20.9.14)
deploy   pts/2  2026-08-25 10:58 (10.20.9.31)

# write deploy pts/2
Your rsync to /srv/artifacts is holding the mount. Please stop it — reboot at 11:20.
^D
```

### 6.2 La escalera de escalamiento para los anuncios

| Antelación | Canal | Comando |
|---|---|---|
| Días | Ticket de cambio, calendario, `/etc/motd` | `echo "..." >> /etc/motd.d/maintenance` |
| 1 hora | `wall` + chat | `wall -t 5 "..."` |
| 15 min | `shutdown -r +15 "..."` — se repite automáticamente a medida que se acerca el plazo | logind vuelve a transmitir a intervalos decrecientes |
| 5 min | `/run/nologin` (automático) — se rechazan los nuevos logins que no sean de root | creado por logind |
| 0 | Transición | — |

Bloquear los logins temprano, a mano, antes de un mantenimiento largo:

```console
# echo "Node under maintenance CHG-4417 until 13:00 UTC. Contact #sre-oncall." > /etc/nologin
```

`/etc/nologin` lo gestiona el admin y persiste al reiniciar — **borralo después** o el nodo vuelve rechazando todos los logins. `/run/nologin` es el gestionado por systemd en tmpfs y desaparece al reiniciar. Ambos son respetados por `pam_nologin`, y ambos exceptúan al UID 0.

### 6.3 Terminar procesos correctamente

#### Señales

| Señal | Número | Acción por defecto | ¿Capturable? | Uso |
|---|---|---|---|---|
| `SIGHUP` | 1 | Terminar | Sí | Históricamente "la terminal colgó"; por convención, los daemons recargan la configuración |
| `SIGINT` | 2 | Terminar | Sí | Ctrl+C |
| `SIGQUIT` | 3 | Terminar + core | Sí | Ctrl+\; algunos daemons (nginx) lo tratan como apagado *elegante* |
| `SIGKILL` | **9** | Terminar | **No** | No puede capturarse, bloquearse ni ignorarse. Último recurso |
| `SIGTERM` | **15** | Terminar | Sí | **El default educado.** Lo que `kill` envía sin argumentos |
| `SIGSTOP` | 19 | Detener | **No** | Congelar un proceso |
| `SIGCONT` | 18 | Continuar | Sí | Reanudar |
| `SIGPWR` | 30 | Terminar | Sí | Fallo de energía; acciones `powerfail` de inittab |

```console
$ kill -l | head -4
 1) SIGHUP       2) SIGINT       3) SIGQUIT      4) SIGILL       5) SIGTRAP
 6) SIGABRT      7) SIGBUS       8) SIGFPE       9) SIGKILL     10) SIGUSR1
11) SIGSEGV     12) SIGUSR2     13) SIGPIPE     14) SIGALRM     15) SIGTERM
16) SIGSTKFLT   17) SIGCHLD     18) SIGCONT     19) SIGSTOP     20) SIGTSTP
```

**La secuencia correcta es siempre TERM → esperar → KILL.** `SIGKILL` no le da al proceso ninguna oportunidad de vaciar buffers, hacer checkpoint, liberar locks, darse de baja del service discovery o eliminar archivos PID. Un `kill -9` sobre una base de datos es la forma de obtener 20 minutos de recuperación de fallos en el próximo arranque.

Dos casos donde ni siquiera `SIGKILL` hace algo:

- **Sueño ininterrumpible (estado `D`)** — el proceso está bloqueado en el kernel, típicamente en E/S hacia un servidor NFS muerto o un disco que falla. La señal se encola y se entrega solo cuando la syscall retorna. Esta es la causa número uno de un apagado colgado.
- **Zombis (estado `Z`)** — ya muertos, solo una entrada en la tabla de procesos esperando un `wait()` del padre. No podés matar un zombi; matá o arreglá al *padre*.

```console
$ ps -eo pid,ppid,stat,wchan:24,comm | awk '$3 ~ /^[DZ]/'
   PID   PPID STAT WCHAN                    COMMAND
  4471   4463 D    nfs_wait_bit_killable    rsync
  4620   1201 Z    -                        collect-metrics
```

#### Herramientas

```console
# kill 4471                       # SIGTERM (default) to one PID
# kill -TERM 4471                 # explicit, preferred in scripts
# kill -15 4471                   # numeric equivalent
# kill -9 4471                    # SIGKILL
# kill -0 4471                    # send nothing; test existence + permission
# kill -- -2841                   # negative PID = whole process GROUP

# killall -TERM nginx             # by exact command name
# killall -u deploy               # everything owned by a user
# killall -e -TERM very-long-process-name-over-15-chars

# pkill -TERM -f 'python.*worker\.py --queue=bulk'    # match full cmdline (regex)
# pkill -TERM -u deploy -t pts/2                       # by user AND terminal
# pgrep -a -f 'worker\.py'                             # list first — ALWAYS list first
2841 /usr/bin/python3 /srv/app/worker.py --queue=bulk
2842 /usr/bin/python3 /srv/app/worker.py --queue=bulk
```

> `pkill -f` compara la línea de comandos completa como una expresión regular. `pkill -f python` en un host ocupado mata todos los procesos Python de la máquina, incluido el agente a través del cual estás conectado por SSH. **Ejecutá `pgrep` con las mismas banderas primero, siempre.**

Encontrar qué retiene un filesystem — el montaje que va a bloquear tu apagado:

```console
# umount /srv/artifacts
umount: /srv/artifacts: target is busy.

# fuser -vm /srv/artifacts
                     USER        PID ACCESS COMMAND
/srv/artifacts:      root     kernel mount /srv/artifacts
                     deploy     4471 ..c-- rsync
                     deploy     4808 F.c-- java

# lsof +D /srv/artifacts | head
COMMAND  PID   USER   FD   TYPE DEVICE  SIZE/OFF     NODE NAME
rsync   4471 deploy  cwd    DIR  253,4      4096  1179649 /srv/artifacts
java    4808 deploy    7w   REG  253,4 104857600  1179721 /srv/artifacts/build.log

# fuser -km /srv/artifacts        # SIGKILL everything using it — destructive
# fuser -TERM -km /srv/artifacts  # SIGTERM first — do this instead
# umount /srv/artifacts
```

`umount -l` (lazy) desprende el montaje del namespace de inmediato y limpia cuando se cierra la última referencia — útil para desbloquear un apagado cuando el servidor de respaldo es inalcanzable, al costo de ocultar el problema real.

#### Cómo termina systemd un servicio

Este es el mecanismo que el examen llama "terminar procesos correctamente", implementado correctamente:

1. Ejecutar `ExecStop=` si está definido, y esperarlo (acotado por `TimeoutStopSec=`).
2. Enviar `KillSignal=` (por defecto `SIGTERM`) según `KillMode=`.
3. Opcionalmente enviar también `SIGHUP` si `SendSIGHUP=yes`.
4. Esperar `TimeoutStopSec=` (default compilado 90 s, definido por `DefaultTimeoutStopSec=` en `/etc/systemd/system.conf`).
5. Si algo en el cgroup sigue vivo y `SendSIGKILL=yes` (por defecto), enviar `FinalKillSignal=` (por defecto `SIGKILL`) a todo el cgroup.
6. Si *todavía* existen procesos (estado D), la unit entra en `failed` con `Result=timeout`.

| `KillMode=` | El paso 2 envía `SIGTERM` a | El paso 5 envía `SIGKILL` a |
|---|---|---|
| `control-group` (**por defecto**) | **Todos** los procesos del cgroup | Todos los procesos del cgroup |
| `mixed` | **Solo el proceso principal** | Todos los procesos del cgroup |
| `process` | Solo el proceso principal | Solo el proceso principal |
| `none` | Nada (solo corre `ExecStop=`) | Nada — **obsoleto, filtra procesos** |

`mixed` es la elección correcta cuando el proceso principal es un supervisor que debe orquestar el apagado de sus propios hijos (`nginx`, `php-fpm`, `containerd`) — querés que él reciba `SIGTERM` y gestione los workers, no que systemd les mande `SIGTERM` a sus espaldas.

Un drop-in para un servicio que legítimamente necesita un drenaje largo:

`/etc/systemd/system/payment-api.service.d/10-graceful-stop.conf`:

```ini
[Service]
# Give the process manager a chance to orchestrate its own workers.
KillMode=mixed
KillSignal=SIGTERM

# Let in-flight HTTP requests complete. Must exceed the app's own drain timeout.
TimeoutStopSec=120s

# If it is still alive after 120s, it is wedged. Kill it.
SendSIGKILL=yes
FinalKillSignal=SIGKILL

# Deregister from service discovery BEFORE the process is signalled.
ExecStop=/usr/local/sbin/consul-deregister.sh payment-api
```

```console
# systemctl daemon-reload
# systemctl show payment-api.service -p KillMode -p TimeoutStopUSec -p SendSIGKILL
KillMode=mixed
TimeoutStopUSec=2min
SendSIGKILL=yes
```

---

## 7. Manifiestos completos e infraestructura

### 7.1 Graceful node shutdown en un worker de Kubernetes (el contrato del inhibitor lock)

El Graceful Node Shutdown del kubelet toma un inhibitor lock de tipo **delay** de logind. Cuando comienza un apagado, logind lo retrasa y el kubelet desaloja pods en orden de prioridad. El contrato que debe cumplirse:

> `InhibitDelayMaxSec` ≥ `shutdownGracePeriod` ≥ `shutdownGracePeriodCriticalPods`

Si `InhibitDelayMaxSec` se deja en su valor por defecto de 5 segundos, logind sigue adelante después de 5 segundos y el kubelet muere a mitad del desalojo — los pods nunca se terminan de forma elegante y el API server espera todo el timeout de desalojo de pods.

`/etc/systemd/logind.conf.d/20-kubelet-graceful-shutdown.conf`:

```ini
[Login]
# Must be >= kubelet shutdownGracePeriod (300s) plus headroom for
# container-runtime teardown. logind's default of 5s silently breaks
# graceful node shutdown.
InhibitDelayMaxSec=360

# Servers have no lid and no desktop sessions; never let one block maintenance.
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
HandlePowerKey=poweroff
HandleRebootKey=ignore
InhibitorsMax=8192
```

`/var/lib/kubelet/config.yaml` (KubeletConfiguration):

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
address: 0.0.0.0
port: 10250
readOnlyPort: 0
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
    cacheTTL: 2m0s
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt
authorization:
  mode: Webhook
  webhook:
    cacheAuthorizedTTL: 5m0s
    cacheUnauthorizedTTL: 30s
clusterDomain: cluster.local
clusterDNS:
  - 10.96.0.10
cgroupDriver: systemd
containerRuntimeEndpoint: unix:///run/containerd/containerd.sock
rotateCertificates: true
serverTLSBootstrap: true

# --- Graceful Node Shutdown -------------------------------------------------
# Total window kubelet negotiates with systemd-logind via an inhibitor lock.
shutdownGracePeriod: 300s
# Of that window, the tail reserved for critical (system-cluster/node-critical) pods.
shutdownGracePeriodCriticalPods: 60s
# Optional finer control: eviction order by PriorityClass value.
shutdownGracePeriodByPodPriority:
  - priority: 0
    shutdownGracePeriodSeconds: 120
  - priority: 1000
    shutdownGracePeriodSeconds: 180
  - priority: 2000000000
    shutdownGracePeriodSeconds: 300
# ---------------------------------------------------------------------------

evictionHard:
  memory.available: "200Mi"
  nodefs.available: "10%"
  imagefs.available: "15%"
systemReserved:
  cpu: "500m"
  memory: "1Gi"
kubeReserved:
  cpu: "500m"
  memory: "1Gi"
```

Aplicar y verificar el contrato de punta a punta:

```console
# systemctl restart systemd-logind
# systemctl restart kubelet
# systemd-inhibit --list | grep -i kubelet
kubelet   0  root  2141  kubelet  shutdown  Kubelet needs time to handle node shutdown  delay

# systemctl show systemd-logind -p InhibitDelayMaxUSec
InhibitDelayMaxUSec=6min

# journalctl -u kubelet -g "graceful" -b --no-pager | tail -3
Aug 25 09:14:52 node07 kubelet[2141]: I0825 09:14:52.118 2141 nodeshutdown_manager_linux.go:139] "Creating node shutdown manager" shutdownGracePeriodRequested="5m0s" shutdownGracePeriodCriticalPods="1m0s" shutdownGracePeriodByPodPriority=[{0 120} {1000 180} {2000000000 300}]
Aug 25 09:14:52 node07 kubelet[2141]: I0825 09:14:52.119 2141 nodeshutdown_manager_linux.go:279] "Watching for node shutdown events"
```

### 7.2 Cinturón y tiradores: una unit de drain que corre al detenerse

El graceful shutdown nativo maneja los pods; **no** hace cordon del nodo en el API server. Esta unit sí, y demuestra el patrón general de "ejecutar algo en el apagado".

`/etc/systemd/system/node-cordon-drain.service`:

```ini
[Unit]
Description=Cordon and drain this node before shutdown
Documentation=https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/
# Ordering is REVERSED on stop: because this unit starts AFTER the network and
# kubelet, it is STOPPED BEFORE them — so ExecStop still has API connectivity.
After=network-online.target kubelet.service
Wants=network-online.target
Requisite=kubelet.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/kubectl --kubeconfig=/etc/kubernetes/admin.conf uncordon %H
ExecStop=/usr/local/sbin/node-drain.sh
# Must exceed the worst-case drain; the default 90s is far too short.
TimeoutStopSec=600
Environment=KUBECONFIG=/etc/kubernetes/admin.conf

[Install]
WantedBy=multi-user.target
```

`/usr/local/sbin/node-drain.sh`:

```bash
#!/usr/bin/env bash
# Cordon and drain this node. Invoked as ExecStop= of node-cordon-drain.service.
set -euo pipefail

NODE="$(hostname -s)"
KUBECTL="/usr/bin/kubectl --kubeconfig=${KUBECONFIG:-/etc/kubernetes/admin.conf}"
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-540s}"

log() { /usr/bin/logger -t node-drain -p daemon.notice -- "$*"; echo "$*" >&2; }

if ! $KUBECTL get node "$NODE" >/dev/null 2>&1; then
    log "API server unreachable or node ${NODE} unknown; skipping drain"
    exit 0
fi

log "Cordoning ${NODE}"
$KUBECTL cordon "$NODE"

/usr/bin/wall "Node ${NODE} is draining for maintenance. Workloads are being rescheduled."

log "Draining ${NODE} (timeout ${DRAIN_TIMEOUT})"
if $KUBECTL drain "$NODE" \
        --ignore-daemonsets \
        --delete-emptydir-data \
        --disable-eviction=false \
        --grace-period=30 \
        --timeout="$DRAIN_TIMEOUT"; then
    log "Drain of ${NODE} completed cleanly"
else
    log "Drain of ${NODE} did NOT complete within ${DRAIN_TIMEOUT}; proceeding with shutdown"
fi
exit 0
```

```console
# install -m 0755 /usr/local/sbin/node-drain.sh /usr/local/sbin/node-drain.sh
# systemctl daemon-reload
# systemctl enable --now node-cordon-drain.service
Created symlink '/etc/systemd/system/multi-user.target.wants/node-cordon-drain.service' → '/etc/systemd/system/node-cordon-drain.service'.

# systemctl status node-cordon-drain.service
● node-cordon-drain.service - Cordon and drain this node before shutdown
     Loaded: loaded (/etc/systemd/system/node-cordon-drain.service; enabled; preset: disabled)
     Active: active (exited) since Mon 2026-08-25 11:31:07 UTC; 4s ago
    Process: 9912 ExecStart=/usr/bin/kubectl --kubeconfig=/etc/kubernetes/admin.conf uncordon node07 (code=exited, status=0/SUCCESS)
   Main PID: 9912 (code=exited, status=0/SUCCESS)
```

Verificá la ruta de parada **sin reiniciar** — hacé siempre esto antes de confiar en ella:

```console
# systemctl stop node-cordon-drain.service
# journalctl -t node-drain -n 5 --no-pager
Aug 25 11:33:41 node07 node-drain[9988]: Cordoning node07
Aug 25 11:33:42 node07 node-drain[9988]: Draining node07 (timeout 540s)
Aug 25 11:34:19 node07 node-drain[9988]: Drain of node07 completed cleanly
# kubectl get node node07
NAME     STATUS                     ROLES    AGE    VERSION
node07   Ready,SchedulingDisabled   <none>   214d   v1.31.4
# systemctl start node-cordon-drain.service     # uncordons again
```

### 7.3 Línea base de flota vía cloud-init

```yaml
#cloud-config
# Baseline boot-target and shutdown policy for a bare-metal / VM worker.
# Applies on first boot; idempotent.

hostname: node07
fqdn: node07.prod.example.com
timezone: UTC

write_files:
  # ---- Manager-wide timeouts -------------------------------------------------
  - path: /etc/systemd/system.conf.d/10-shutdown-policy.conf
    owner: root:root
    permissions: '0644'
    content: |
      [Manager]
      # A unit that has not stopped in 45s is wedged; do not burn 90s per unit
      # across a 200-node rolling reboot.
      DefaultTimeoutStopSec=45s
      DefaultTimeoutStartSec=90s
      # Hardware watchdog: if the shutdown itself hangs past this, reset the box.
      RuntimeWatchdogSec=60s
      RebootWatchdogSec=10min
      # Never let a runaway unit fork the machine to death.
      DefaultTasksMax=8192
      DefaultLimitNOFILE=65536:524288

  # ---- logind ---------------------------------------------------------------
  - path: /etc/systemd/logind.conf.d/20-server-policy.conf
    owner: root:root
    permissions: '0644'
    content: |
      [Login]
      InhibitDelayMaxSec=360
      HandlePowerKey=poweroff
      HandleRebootKey=reboot
      HandleSuspendKey=ignore
      HandleHibernateKey=ignore
      HandleLidSwitch=ignore
      HandleLidSwitchExternalPower=ignore
      HandleLidSwitchDocked=ignore
      IdleAction=ignore
      InhibitorsMax=8192
      KillUserProcesses=no

  # ---- journal must survive the reboot we are debugging ---------------------
  - path: /etc/systemd/journald.conf.d/10-persistent.conf
    owner: root:root
    permissions: '0644'
    content: |
      [Journal]
      Storage=persistent
      SystemMaxUse=2G
      SystemMaxFileSize=128M
      MaxRetentionSec=1month
      ForwardToSyslog=no

  # ---- post-shutdown forensics ----------------------------------------------
  - path: /usr/lib/systemd/system-shutdown/debug.sh
    owner: root:root
    permissions: '0755'
    content: |
      #!/bin/sh
      # Executed by systemd-shutdown as the very last userspace step, with
      # $1 in {halt, poweroff, reboot, kexec}. Captures the tail of the kernel
      # ring buffer, which is otherwise lost forever on a hung shutdown.
      mount -o remount,rw /var 2>/dev/null || mount -o remount,rw / 2>/dev/null
      mkdir -p /var/log/shutdown
      dmesg > "/var/log/shutdown/dmesg-$1.txt" 2>/dev/null
      sync
      mount -o remount,ro /var 2>/dev/null || mount -o remount,ro / 2>/dev/null

runcmd:
  - [ systemctl, daemon-reload ]
  - [ systemctl, restart, systemd-journald ]
  - [ systemctl, restart, systemd-logind ]
  # Headless server: never boot a display manager.
  - [ systemctl, set-default, multi-user.target ]
  - [ systemctl, mask, ctrl-alt-del.target ]
  - [ systemctl, disable, --now, acpid.service ]
  - [ sh, -c, "systemctl get-default | grep -qx multi-user.target || exit 1" ]

power_state:
  mode: reboot
  message: "cloud-init baseline applied; rebooting into multi-user.target"
  timeout: 120
  condition: true
```

### 7.4 Playbook de rolling reboot (Ansible)

```yaml
---
- name: Rolling kernel-patch reboot of Kubernetes worker nodes
  hosts: k8s_workers
  become: true
  gather_facts: true
  serial: 1
  any_errors_fatal: true
  max_fail_percentage: 0

  vars:
    wall_lead_minutes: 5
    drain_timeout: 540
    reboot_timeout: 900
    post_reboot_settle: 60
    kubectl_host: "{{ groups['k8s_control_plane'][0] }}"

  pre_tasks:
    - name: Fail fast if the cluster is already degraded
      ansible.builtin.command:
        argv: [/usr/bin/kubectl, get, nodes, -o, "jsonpath={.items[?(@.status.conditions[-1].status!='True')].metadata.name}"]
      delegate_to: "{{ kubectl_host }}"
      run_once: true
      register: unhealthy_nodes
      changed_when: false
      failed_when: unhealthy_nodes.stdout | trim | length > 0

  tasks:
    - name: Determine whether a reboot is actually required
      ansible.builtin.stat:
        path: /var/run/reboot-required
      register: reboot_marker

    - name: Query the newest installed kernel (RPM family)
      ansible.builtin.shell: >
        set -o pipefail;
        rpm -q --last kernel | head -n1 | awk '{print $1}' | sed 's/^kernel-//'
      args:
        executable: /bin/bash
      register: newest_kernel
      changed_when: false
      when: ansible_facts['os_family'] == 'RedHat'

    - name: Decide
      ansible.builtin.set_fact:
        needs_reboot: >-
          {{ reboot_marker.stat.exists
             or (ansible_facts['os_family'] == 'RedHat'
                 and newest_kernel.stdout != ansible_facts['kernel']) }}

    - name: Skip hosts that are already running the newest kernel
      ansible.builtin.meta: end_host
      when: not needs_reboot

    - name: Verify the persistent boot target before touching anything
      ansible.builtin.command: systemctl get-default
      register: default_target
      changed_when: false
      failed_when: default_target.stdout | trim != 'multi-user.target'

    - name: Broadcast the maintenance warning to logged-in operators
      ansible.builtin.command:
        argv:
          - /usr/bin/wall
          - "-t"
          - "5"
          - "NOTICE: {{ inventory_hostname }} reboots in {{ wall_lead_minutes }} min (kernel patch CHG-4417). Save your work."
      changed_when: false
      failed_when: false

    - name: Cordon the node
      ansible.builtin.command:
        argv: [/usr/bin/kubectl, cordon, "{{ inventory_hostname }}"]
      delegate_to: "{{ kubectl_host }}"
      changed_when: true

    - name: Drain the node
      ansible.builtin.command:
        argv:
          - /usr/bin/kubectl
          - drain
          - "{{ inventory_hostname }}"
          - --ignore-daemonsets
          - --delete-emptydir-data
          - --grace-period=30
          - "--timeout={{ drain_timeout }}s"
      delegate_to: "{{ kubectl_host }}"
      register: drain_result
      changed_when: true
      retries: 2
      delay: 30
      until: drain_result.rc == 0

    - name: Confirm no blocking inhibitor locks remain
      ansible.builtin.command: systemd-inhibit --list --mode=block
      register: block_inhibitors
      changed_when: false
      failed_when: >-
        block_inhibitors.stdout_lines
        | select('search', 'block')
        | reject('search', 'systemd-logind')
        | list | length > 0

    - name: Reboot and wait for the node to come back
      ansible.builtin.reboot:
        msg: "Kernel patch CHG-4417 (Ansible rolling reboot)"
        pre_reboot_delay: "{{ wall_lead_minutes * 60 }}"
        post_reboot_delay: 15
        reboot_timeout: "{{ reboot_timeout }}"
        connect_timeout: 20
        test_command: "systemctl is-system-running --wait || true"

    - name: Refresh facts after the reboot
      ansible.builtin.setup:

    - name: Assert the running kernel actually changed (RPM family)
      ansible.builtin.assert:
        that:
          - ansible_facts['kernel'] == newest_kernel.stdout
        fail_msg: >-
          Reboot completed but the running kernel is {{ ansible_facts['kernel'] }},
          not the expected {{ newest_kernel.stdout }}. GRUB default entry is wrong.
      when: ansible_facts['os_family'] == 'RedHat'

    - name: Assert systemd reached a healthy state
      ansible.builtin.command: systemctl is-system-running
      register: system_state
      changed_when: false
      retries: 12
      delay: 10
      until: system_state.stdout | trim in ['running', 'degraded']
      failed_when: system_state.stdout | trim != 'running'

    - name: Collect failed units for the report if degraded
      ansible.builtin.command: systemctl --failed --no-legend --no-pager
      register: failed_units
      changed_when: false
      when: system_state.stdout | trim == 'degraded'

    - name: Wait for the kubelet to register the node as Ready
      ansible.builtin.command:
        argv: [/usr/bin/kubectl, wait, "node/{{ inventory_hostname }}", --for=condition=Ready, "--timeout={{ post_reboot_settle }}s"]
      delegate_to: "{{ kubectl_host }}"
      changed_when: false

    - name: Uncordon the node
      ansible.builtin.command:
        argv: [/usr/bin/kubectl, uncordon, "{{ inventory_hostname }}"]
      delegate_to: "{{ kubectl_host }}"
      changed_when: true

  post_tasks:
    - name: Announce completion
      ansible.builtin.command:
        argv: [/usr/bin/wall, "{{ inventory_hostname }} is back on kernel {{ ansible_facts['kernel'] }} and schedulable."]
      changed_when: false
      failed_when: false
```

### 7.5 Referencia de política a nivel del manager

`/etc/systemd/system.conf.d/10-shutdown-policy.conf`, anotado:

```ini
[Manager]
# Applied to any unit that does not set TimeoutStopSec= itself.
# Compiled-in default is 90s. On a fleet, 90s x N stuck units is the
# difference between a 20-minute and a 4-hour maintenance window.
DefaultTimeoutStopSec=45s
DefaultTimeoutStartSec=90s
DefaultTimeoutAbortSec=45s
DefaultRestartSec=5s

# Hardware watchdog (/dev/watchdog) pinged by PID 1 while healthy.
RuntimeWatchdogSec=60s
# If the SHUTDOWN itself hangs longer than this, the watchdog resets the box.
# This is what saves a node stuck on 'Unmounting file systems' forever.
RebootWatchdogSec=10min
KExecWatchdogSec=3min

DefaultTasksMax=8192
DefaultLimitNOFILE=65536:524288
DefaultLimitCORE=0
```

```console
# systemctl daemon-reexec
# systemctl show -p DefaultTimeoutStopUSec -p RebootWatchdogUSec -p RuntimeWatchdogUSec
DefaultTimeoutStopUSec=45s
RuntimeWatchdogUSec=1min
RebootWatchdogUSec=10min
```

`daemon-reload` **no** alcanza para `system.conf` — necesitás `daemon-reexec`, que re-ejecuta PID 1 en el lugar (serializando y restaurando todo el estado de las units) para que se lea la nueva configuración del manager.

---

## 8. Verificación y diagnóstico de fallos

### 8.1 Lista de verificación

```console
# --- What will this machine boot into? -------------------------------------
$ systemctl get-default
multi-user.target
$ readlink -f /etc/systemd/system/default.target
/usr/lib/systemd/system/multi-user.target

# --- What is it in right now? ----------------------------------------------
$ systemctl is-system-running
running
$ systemctl list-units --type=target --state=active --no-pager --no-legend | wc -l
19
$ runlevel
N 3
$ who -r
         run-level 3  2026-08-25 09:14

# --- Anything broken? -------------------------------------------------------
$ systemctl --failed
0 loaded units listed.
$ systemctl list-jobs
No jobs running.

# --- Is a shutdown pending? -------------------------------------------------
$ test -e /run/systemd/shutdown/scheduled && cat /run/systemd/shutdown/scheduled || echo "none scheduled"
none scheduled
$ ls -l /run/nologin /etc/nologin 2>/dev/null || echo "logins permitted"
logins permitted

# --- Anything blocking a transition? ----------------------------------------
$ systemd-inhibit --list --mode=block
0 inhibitors listed.

# --- Boot health ------------------------------------------------------------
$ systemd-analyze
Startup finished in 3.412s (firmware) + 2.109s (loader) + 1.884s (kernel) + 6.771s (initrd) + 11.203s (userspace) = 25.381s
multi-user.target reached after 11.190s in userspace.
```

### 8.2 Rendimiento del arranque

```console
$ systemd-analyze blame | head -12
6.418s kdump.service
4.011s NetworkManager-wait-online.service
2.884s dracut-initqueue.service
1.702s systemd-udev-settle.service
1.219s kubelet.service
 987ms containerd.service
 771ms lvm2-monitor.service
 640ms sssd.service
 512ms systemd-udev-trigger.service
 398ms chronyd.service
 351ms auditd.service
 244ms polkit.service
```

`blame` muestra el tiempo de inicialización individual de cada unit — pero una unit lenta no necesariamente retrasa el arranque, porque las units corren en paralelo. La **cadena crítica** es lo que realmente determina el tiempo total:

```console
$ systemd-analyze critical-chain
The time when unit became active or started is printed after the "@" character.
The time the unit took to start is printed after the "+" character.

multi-user.target @11.190s
└─kubelet.service @9.968s +1.219s
  └─containerd.service @8.978s +987ms
    └─network-online.target @8.972s
      └─NetworkManager-wait-online.service @4.958s +4.011s
        └─NetworkManager.service @4.641s +311ms
          └─dbus-broker.service @4.520s +117ms
            └─basic.target @4.502s
              └─sockets.target @4.501s
                └─dbus.socket @4.499s
                  └─sysinit.target @4.488s
                    └─systemd-update-utmp.service @4.471s +15ms
                      └─auditd.service @4.117s +351ms
                        └─systemd-tmpfiles-setup.service @4.001s +109ms
                          └─local-fs.target @3.988s
```

Acá `kdump.service` tarda 6,4 s pero no está en la cadena — optimizarlo no ahorra nada. `NetworkManager-wait-online.service` con 4 s **sí** está en la cadena, y es el candidato clásico para eliminar en un nodo con direccionamiento estático.

```console
$ systemd-analyze critical-chain kubelet.service
$ systemd-analyze plot > /tmp/boot-node07.svg
$ systemd-analyze dump | grep -A5 '^-> Unit multi-user.target'
$ systemd-analyze verify /etc/systemd/system/node-cordon-drain.service
```

### 8.3 Leer arranques anteriores

```console
$ journalctl --list-boots
IDX BOOT ID                          FIRST ENTRY                 LAST ENTRY
 -3 a1c9f4e5b2d84a7f9e0c3b6d5a8f1e27 Sat 2026-08-22 06:11:03 UTC Sun 2026-08-23 04:02:41 UTC
 -2 7f2e8b1c4d6a49f38b5c0e7d2a9f6b31 Sun 2026-08-23 04:03:12 UTC Mon 2026-08-24 22:47:55 UTC
 -1 3d5a9c8e1b7f42e6a0d4c2b8f6e3a915 Mon 2026-08-24 22:48:19 UTC Tue 2026-08-25 09:12:44 UTC
  0 9b4f2a7c6e1d48b3a5f0c9e2d7b6a483 Tue 2026-08-25 09:14:31 UTC Tue 2026-08-25 11:41:02 UTC

$ journalctl -b -1 -p err --no-pager | tail
$ journalctl -b -1 -e                      # the tail of the PREVIOUS boot = why it died
$ journalctl -b -1 -u kubelet --no-pager
$ journalctl -b -1 -k | grep -i -E 'panic|oops|hardware error|mce'
```

**`journalctl -b -1` solo funciona si el journal es persistente.** En una instalación por defecto de Debian/Ubuntu es volátil y todos los arranques anteriores se pierden exactamente en el momento en que los necesitás:

```console
$ ls /var/log/journal 2>/dev/null || echo "VOLATILE — previous boots are NOT retained"
VOLATILE — previous boots are NOT retained

# mkdir -p /var/log/journal
# systemd-tmpfiles --create --prefix /var/log/journal
# systemctl restart systemd-journald
```

¿El último reinicio fue limpio o un crash? La vista `utmp`/`wtmp`:

```console
$ last -x reboot shutdown runlevel | head
runlevel (to lvl 3)   6.9.11-200.fc40. Tue Aug 25 09:14   still running
reboot   system boot  6.9.11-200.fc40. Tue Aug 25 09:14   still running
shutdown system down  6.9.7-200.fc40.x Tue Aug 25 09:12 - 09:14  (00:01)
runlevel (to lvl 3)   6.9.7-200.fc40.x Mon Aug 24 22:48 - 09:12  (10:24)
reboot   system boot  6.9.7-200.fc40.x Mon Aug 24 22:48 - 09:12  (10:24)
```

Una línea `reboot system boot` **sin** una línea `shutdown system down` precedente significa que la máquina se cayó de forma sucia — panic, watchdog, corte de energía, o `reboot -ff`.

```console
$ uptime -s
2026-08-25 09:14:31
$ who -b
         system boot  2026-08-25 09:14
```

### 8.4 Manual de fallos

| Síntoma | Causa más probable | Diagnóstico | Solución |
|---|---|---|---|
| `A stop job is running for <unit> (1min 30s / 1min 30s)` | La unit ignora `SIGTERM` o tiene hijos en estado D | `systemctl list-jobs`; en otra tty `ps -eo pid,stat,wchan,comm \| awk '$2~/D/'` | Drop-in con `TimeoutStopSec=` menor, `KillMode=mixed`; arreglar el manejador de señales de la app |
| El apagado se cuelga en `Unmounting file systems`, sin más salida | Filesystem de red cuyo servidor ya no está; un proceso reteniendo un montaje | Consola serie; captura con `/usr/lib/systemd/system-shutdown/debug.sh` | `_netdev` + `x-systemd.requires=network-online.target` en `fstab`; `RebootWatchdogSec` como red de contención |
| El nodo arranca en `emergency.target` | `/etc/fstab` referencia un dispositivo que no existe | `journalctl -b -p err`; `systemctl list-units --state=failed --type=mount` | Agregar `nofail` a las entradas no esenciales; usar UUID/LABEL en vez de `/dev/sdX` |
| `Failed to isolate X: Operation refused` | Al target le falta `AllowIsolate=yes` | `systemctl cat X \| grep AllowIsolate` | Aislar un target real, o agregar la directiva a tu target propio |
| `set-default` no tuvo efecto después de reiniciar | El `systemd.unit=` de la cmdline del kernel en GRUB lo anula | `cat /proc/cmdline` | Quitarlo de `GRUB_CMDLINE_LINUX`, `grub2-mkconfig -o /boot/grub2/grub.cfg` |
| Arranca con el kernel viejo tras `reboot` | Entrada por defecto de GRUB / saved-entry de `grubby` | `grubby --default-kernel`; `grub2-editenv list` | `grubby --set-default=/boot/vmlinuz-<new>` |
| `Give root password for maintenance` y después la contraseña es rechazada | Root bloqueado (`!` en `/etc/shadow`), o falta el relabel de SELinux tras un reseteo de contraseña | Arrancar con `init=/bin/bash` | `passwd root`; `touch /.autorelabel` |
| El prompt de rescue nunca aparece; la consola se cuelga | `sulogin` no puede abrir la consola; `console=` equivocado para el puerto serie | Verificar `console=ttyS0,115200n8` en la cmdline | Agregar el parámetro de consola serie; habilitar `serial-getty@ttyS0.service` |
| `poweroff` rechazado con "Operation inhibited by …" | Un inhibitor lock en modo `block` | `systemd-inhibit --list` | Resolver al que lo retiene; si es genuinamente seguro, `systemctl poweroff -i` |
| `shutdown -c` dice que no hay nada programado pero los usuarios siguen recibiendo avisos | `wall` enviado por un job de cron / el `shutdown` de otro admin en un namespace de contenedor | `busctl get-property … ScheduledShutdown`; `journalctl -u systemd-logind` | Encontrar la fuente real; los apagados programados viven en logind, no en `atd` |
| El sistema queda `degraded` después de cada arranque | Una unit falla en el arranque pero el target se alcanza igual | `systemctl --failed`; `systemctl status <unit>` | Arreglar o `systemctl disable`/`mask` |
| Todo se cuelga, sin respuesta por consola, sin SSH | Deadlock del kernel o PID 1 colgado | Consola serie + SysRq | R-E-I-S-U-B; después ciclo de energía por IPMI/Redfish |

### 8.5 Depurar un arranque en el que no podés loguearte

Agregá a la línea de comandos del kernel en GRUB:

```
systemd.log_level=debug systemd.log_target=kmsg log_buf_len=8M printk.devkmsg=on rd.udev.log_level=debug
```

Obtené una shell de root sin autenticación en tty9 (ver la nota de endurecimiento en §4.4):

```console
# systemctl enable debug-shell.service      # persistent — REMEMBER TO DISABLE IT
Created symlink '/etc/systemd/system/sysinit.target.wants/debug-shell.service' → '/usr/lib/systemd/system/debug-shell.service'.
```
o, para un solo arranque, agregá `systemd.debug_shell=1` a la cmdline, después `Ctrl+Alt+F9`.

Desde esa shell, mientras el arranque sigue trabado:

```console
# systemctl list-jobs
JOB UNIT                          TYPE  STATE
183 network-online.target         start waiting
 12 multi-user.target             start waiting
187 NetworkManager-wait-online.service start running
  1 graphical.target              start waiting

4 jobs listed.
```

`STATE=running` en exactamente un job dentro de una cadena en `waiting` nombra al culpable de inmediato.

Capturar el apagado que se cuelga — `systemd-shutdown` ejecuta todos los ejecutables de `/usr/lib/systemd/system-shutdown/` como acto final, con el verbo (`halt`/`poweroff`/`reboot`/`kexec`) como `$1`:

```bash
#!/bin/sh
# /usr/lib/systemd/system-shutdown/debug.sh   (mode 0755)
mount -o remount,rw /
dmesg > /var/log/shutdown-dmesg-"$1".txt
sync
mount -o remount,ro /
```

### 8.6 Matriz de referencia de comandos

| Tarea | systemd | SysV |
|---|---|---|
| Mostrar el estado de arranque por defecto | `systemctl get-default` | `grep initdefault /etc/inittab` |
| Establecer el estado de arranque por defecto | `systemctl set-default X.target` | editar `initdefault`, `telinit q` |
| Cambiar el estado ahora | `systemctl isolate X.target` | `init N` / `telinit N` |
| Mostrar el estado actual | `systemctl is-system-running`, `systemctl list-units --type=target` | `runlevel`, `who -r` |
| Single user | `systemctl rescue` | `init 1` / `telinit 1` |
| Recuperación mínima | `systemctl emergency` | *(sin equivalente)* |
| Volver a la normalidad | `systemctl default` | `init 3` / `init 5` |
| Reiniciar | `systemctl reboot` / `reboot` | `shutdown -r now` / `init 6` |
| Apagar | `systemctl poweroff` / `poweroff` | `shutdown -h now` / `init 0` |
| Halt (mantener energía) | `systemctl halt` / `halt` | `halt` |
| Programar | `shutdown -r +15 "msg"` | `shutdown -r +15 "msg"` |
| Cancelar lo programado | `shutdown -c` | `shutdown -c` |
| Solo avisar | `shutdown -k +15 "msg"` | `shutdown -k +15 "msg"` |
| Broadcast | `wall "msg"` | `wall "msg"` |
| Recargar la configuración de init | `systemctl daemon-reload` | `telinit q` |
| Re-ejecutar init | `systemctl daemon-reexec` | `telinit u` |
| Habilitar en el arranque | `systemctl enable foo` | `chkconfig foo on` / `update-rc.d foo defaults` |

---

## 9. Trampas de examen

1. **`systemctl set-default` no cambia el estado en ejecución; `systemctl isolate` no persiste.** Casi todas las preguntas en esta área giran sobre esa distinción.
2. **`init 1`, `single`, `s`, `S` y `rescue.target` son todos lo mismo**; `emergency.target` es estrictamente más bajo y no tiene equivalente en runlevels.
3. **Nunca definas `initdefault` como `0` ni `6`.**
4. **`runlevel` imprime dos campos**: anterior, después actual. `N` significa que no hubo transición previa.
5. **Los runlevels 2, 3 y 4 solo difieren en sistemas de la familia Red Hat.**
6. **systemd ignora `/etc/inittab` por completo.** Editarlo en un host con systemd no cambia nada.
7. **`shutdown -h` bajo systemd apaga**; `-H` hace halt y deja la máquina con energía.
8. **`shutdown -k` envía el aviso y no apaga.** `shutdown -c` cancela uno pendiente.
9. **`-t SEC` es aceptado e ignorado** por el `shutdown` de systemd.
10. **`SIGTERM` es 15 y es el default de `kill`; `SIGKILL` es 9 y no puede capturarse.**
11. **`/etc/nologin` sobrevive al reinicio; `/run/nologin` no.** Root entra igual.
12. **Un usuario con `mesg n` igualmente recibe `wall` de root.**
13. **`telinit q` relee `/etc/inittab`; no cambia el runlevel.**
14. **La precedencia de units es `/etc/systemd/system` > `/run/systemd/system` > `/usr/lib/systemd/system`.** Nunca edites archivos en `/usr/lib/systemd/system`.
15. **`systemctl daemon-reload` relee los archivos de unit; `systemctl daemon-reexec` relee `/etc/systemd/system.conf`.**

---

## 10. Referencias

**LPI**
- LPIC-1 Exam 101-500 Objectives (v5.0) — https://www.lpi.org/our-certifications/exam-101-objectives/
- LPIC-1 certification overview — https://www.lpi.org/our-certifications/lpic-1-overview/

**systemd — freedesktop.org / páginas de manual**
- `systemd(1)` — línea de comandos del kernel, comportamiento de PID 1 — https://www.freedesktop.org/software/systemd/man/latest/systemd.html
- `systemctl(1)` — verbos, semántica de `--force`, `isolate`, `set-default` — https://www.freedesktop.org/software/systemd/man/latest/systemctl.html
- `systemd.special(7)` — `default.target`, `rescue.target`, `emergency.target`, `runlevelN.target` — https://www.freedesktop.org/software/systemd/man/latest/systemd.special.html
- `systemd.target(5)` — https://www.freedesktop.org/software/systemd/man/latest/systemd.target.html
- `systemd.unit(5)` — rutas de búsqueda, `Requires=`, `Conflicts=`, `PartOf=`, `AllowIsolate=` — https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html
- `systemd.service(5)` — `KillMode=`, `TimeoutStopSec=`, `ExecStop=` — https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html
- `systemd.kill(5)` — `KillSignal=`, `SendSIGKILL=`, `FinalKillSignal=` — https://www.freedesktop.org/software/systemd/man/latest/systemd.kill.html
- `systemd-system.conf(5)` — `DefaultTimeoutStopSec=`, `RebootWatchdogSec=` — https://www.freedesktop.org/software/systemd/man/latest/systemd-system.conf.html
- `shutdown(8)` — https://www.freedesktop.org/software/systemd/man/latest/shutdown.html
- `halt(8)`, `poweroff(8)`, `reboot(8)` — https://www.freedesktop.org/software/systemd/man/latest/halt.html
- `telinit(8)` — https://www.freedesktop.org/software/systemd/man/latest/telinit.html
- `runlevel(8)` — https://www.freedesktop.org/software/systemd/man/latest/runlevel.html
- `systemd-shutdown(8)` — desmantelamiento final, hooks de `system-shutdown/` — https://www.freedesktop.org/software/systemd/man/latest/systemd-shutdown.html
- `logind.conf(5)` — `HandlePowerKey=`, `InhibitDelayMaxSec=` — https://www.freedesktop.org/software/systemd/man/latest/logind.conf.html
- `systemd-inhibit(1)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-inhibit.html
- Documentación para desarrolladores de Inhibitor Locks — https://systemd.io/INHIBITOR_LOCKS/
- `systemd-sysv-generator(8)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-sysv-generator.html
- `systemd-analyze(1)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-analyze.html
- `journalctl(1)` — https://www.freedesktop.org/software/systemd/man/latest/journalctl.html
- `systemd-debug-generator(8)` — `systemd.debug_shell=`, `systemd.mask=` — https://www.freedesktop.org/software/systemd/man/latest/systemd-debug-generator.html
- Depurar problemas de systemd (wiki oficial) — https://freedesktop.org/wiki/Software/systemd/Debugging/

**util-linux / SysV / kernel**
- `wall(1)` — https://man7.org/linux/man-pages/man1/wall.1.html
- `write(1)` — https://man7.org/linux/man-pages/man1/write.1.html
- `mesg(1)` — https://man7.org/linux/man-pages/man1/mesg.1.html
- `inittab(5)` — https://man7.org/linux/man-pages/man5/inittab.5.html
- `init(8)` (sysvinit) — https://man7.org/linux/man-pages/man8/init.8.html
- `kill(1)` — https://man7.org/linux/man-pages/man1/kill.1.html
- `killall(1)` — https://man7.org/linux/man-pages/man1/killall.1.html
- `pkill(1)` / `pgrep(1)` — https://man7.org/linux/man-pages/man1/pgrep.1.html
- `fuser(1)` — https://man7.org/linux/man-pages/man1/fuser.1.html
- `signal(7)` — https://man7.org/linux/man-pages/man7/signal.7.html
- `reboot(2)` — https://man7.org/linux/man-pages/man2/reboot.2.html
- `nologin(5)` — https://man7.org/linux/man-pages/man5/nologin.5.html
- `pam_nologin(8)` — https://man7.org/linux/man-pages/man8/pam_nologin.8.html
- `last(1)` / `wtmp(5)` — https://man7.org/linux/man-pages/man5/utmp.5.html
- Linux Magic System Request Key Hacks — https://docs.kernel.org/admin-guide/sysrq.html
- `kexec(8)` — https://man7.org/linux/man-pages/man8/kexec.8.html
- Acciones y cabeceras de scripts de init LSB — https://refspecs.linuxfoundation.org/LSB_5.0.0/LSB-Core-generic/LSB-Core-generic/iniscrptact.html

**ACPI**
- `acpid(8)` — https://man7.org/linux/man-pages/man8/acpid.8.html
- `acpi_listen(8)` — https://man7.org/linux/man-pages/man8/acpi_listen.8.html
- proyecto acpid — https://sourceforge.net/projects/acpid2/

**Documentación de distribuciones**
- Red Hat Enterprise Linux — Managing services with systemd — https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_basic_system_settings/managing-services-with-systemd_configuring-basic-system-settings
- Red Hat Enterprise Linux — Working with systemd targets — https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_basic_system_settings/working-with-systemd-targets_configuring-basic-system-settings
- Debian Wiki — systemd — https://wiki.debian.org/systemd
- Documentación de Ubuntu Server — https://documentation.ubuntu.com/server/

**Kubernetes (graceful node shutdown)**
- Graceful Node Shutdown — https://kubernetes.io/docs/concepts/cluster-administration/node-shutdown/
- Referencia de configuración del kubelet (v1beta1) — https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
- Safely Drain a Node — https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/