# LPIC-1 · 104.5 — Administrar permisos y propiedad de archivos

**Examen:** 101-500 / 102-500 (v5.0) · **Objetivo 104.5** · **Peso: 4.69**
**Comandos clave:** `chmod`, `umask`, `chown`, `chgrp`
**Adyacentes, relevantes para el examen:** `stat`, `namei`, `find -perm`, `install`, `getfacl`/`setfacl`, `getcap`

---

## 1. El problema en producción: la palabra de modo es el último límite de aplicación

Toda decisión de acceso que el kernel de Linux toma sobre un archivo termina en 16 bits almacenados en el inodo: `st_mode`. Las ACL del sistema de archivos, las capabilities, los LSM (SELinux/AppArmor), los namespaces y las opciones de montaje se apilan alrededor, pero ninguno de ellos *reemplaza* esos bits — solo agregan más denegaciones o exenciones acotadas. Si esos 16 bits están mal, toda capa superior es decoración.

Tres arquetipos de falla explican la mayoría de los incidentes reales:

**Arquetipo A — la apertura recursiva.** Un operador que depura un 403 ejecuta `chmod -R 777 /srv/app`. La aplicación arranca. Tres semanas después un auditor descubre que `/srv/app/config/db.yaml` es legible por todo el mundo, y que todos los directorios bajo `/srv/app` perdieron su sticky bit y ganaron escritura para todos, de modo que cualquier proceso local puede reemplazar cualquier archivo por un enlace simbólico. El arreglo no es "volverlo a poner": los modos correctos nunca quedaron registrados en ningún lado, y los archivos gestionados por el gestor de paquetes hay que recuperarlos con `rpm -Va` / `dpkg --verify`.

**Arquetipo B — la deriva de la colaboración.** Un directorio compartido `/srv/data/reports` pertenece al grupo `data`. Dos cuentas de servicio escriben ahí. Como cada proceso corre con `umask 022` y el directorio no es setgid, cada archivo aterriza como `user:user 0644`. El segundo servicio puede leer pero no sobrescribir. El pipeline funciona a medias — el peor modo de falla, porque es intermitente y depende de qué nodo produjo el archivo.

**Arquetipo C — la isla de privilegios.** Una imagen de contenedor se construye como root, los archivos `COPY`ados aterrizan como `root:root 0644`, y el runtime impone `runAsNonRoot: true` con `runAsUser: 10001`. El contenedor arranca y luego muere en la primera escritura con `EACCES`. En Kubernetes el síntoma es `CrashLoopBackOff` con un stack trace de una línea y ningún responsable evidente.

Los tres son la misma falla de ingeniería: **los permisos se trataron como un arreglo en tiempo de ejecución en lugar de como estado declarado y versionado**. El resto de este material trata la palabra de modo como infraestructura — declarada en tmpfiles.d, unidades de systemd, Ansible, Dockerfiles y securityContexts de pods, y luego verificada.

---

## 2. La palabra de modo: exactamente qué se almacena

`st_mode` es un campo de 16 bits. Los 12 bits bajos son los bits de permiso y especiales; los 4 altos codifican el tipo de archivo (`S_IFMT`), que **no** es modificable por `chmod`.

```
 bit:  15 14 13 12 | 11 10  9 |  8  7  6 |  5  4  3 |  2  1  0
       [ file type]| su sg vtx| r  w  x  | r  w  x  | r  w  x
                   |  special |   owner  |   group  |  other
octal:             |    4 2 1 |  4 2 1   |  4 2 1   |  4 2 1
```

| Símbolo | Octal | Macro C | Significado en un **archivo regular** | Significado en un **directorio** |
|---|---|---|---|---|
| `s` (user) | `4000` | `S_ISUID` | Ejecutar con el EUID del propietario del archivo | **Ignorado en Linux** |
| `s` (group) | `2000` | `S_ISGID` | Ejecutar con el EGID del grupo del archivo; si `g-x`, históricamente marcaba bloqueo obligatorio | Las entradas nuevas heredan el GID del directorio; los subdirectorios nuevos heredan el bit |
| `t` | `1000` | `S_ISVTX` | Ignorado en Linux (históricamente "save text image") | **Borrado restringido**: solo el propietario del archivo, el del directorio o `CAP_FOWNER` pueden hacer unlink/rename |
| `r` | `400/40/4` | `S_IRUSR`… | Leer el contenido del archivo | `readdir()` — listar solo los *nombres* de las entradas |
| `w` | `200/20/2` | `S_IWUSR`… | Modificar el contenido | Crear / borrar / renombrar entradas (**requiere también `x`**) |
| `x` | `100/10/1` | `S_IXUSR`… | `execve()` sobre el archivo | **Búsqueda/travesía**: resolver este componente de una ruta, hacer `stat()` sobre un nombre conocido |

### 2.1 La asimetría `r` vs `x` en directorios — memorizala

Este es el par más evaluado y peor entendido de todo el objetivo.

```console
$ sudo install -d -m 0444 -o root -g root /tmp/r-only
$ sudo touch /tmp/r-only/secret.txt
$ ls /tmp/r-only
secret.txt
$ ls -l /tmp/r-only
ls: cannot access '/tmp/r-only/secret.txt': Permission denied
total 0
-????????? ? ? ? ?            ? secret.txt
$ cat /tmp/r-only/secret.txt
cat: /tmp/r-only/secret.txt: Permission denied
```

`r` sin `x` te da el *catálogo* pero no el *estante*. Lo inverso es mucho más útil en producción:

```console
$ sudo install -d -m 0711 -o root -g root /tmp/x-only
$ sudo install -m 0644 /dev/null /tmp/x-only/known.txt
$ ls /tmp/x-only
ls: cannot open directory '/tmp/x-only': Permission denied
$ cat /tmp/x-only/known.txt        # works: name is known, traversal permitted
$ stat -c '%a %n' /tmp/x-only/known.txt
644 /tmp/x-only/known.txt
```

El modo `0711` en un directorio es el patrón clásico de **"podés entrar si sabés el nombre"** — es la razón por la que `/home` es `0755` pero un `/home/<user>` bien endurecido es `0700`, y por la que los document roots de servidores web que no deben ser listables son `0711` en lugar de `0755`.

| Modo del directorio | `readdir` | Travesía | Crear/borrar | Uso típico en producción |
|---|---|---|---|---|
| `0700` | propietario | propietario | propietario | Estado privado (`/run/<svc>`, `~/.ssh`) |
| `0711` | solo propietario | todos | propietario | Punto de depósito no listable, `/home/<user>` en hosts compartidos |
| `0750` | propietario+grupo | propietario+grupo | propietario | Datos de servicio legibles por un grupo de ops |
| `2770` | propietario+grupo | propietario+grupo | propietario+grupo | Directorio de colaboración compartido (setgid) |
| `0755` | todos | todos | propietario | Rutas de lectura pública (`/usr`, `/srv/www`) |
| `1777` | todos | todos | todos (sticky) | `/tmp`, `/var/tmp`, `/dev/shm` — **solo** con sticky |
| `0777` | todos | todos | todos | Nunca. Siempre es un bug. |

---

## 3. El algoritmo de verificación de acceso: gana la primera coincidencia, sin fallthrough

El `generic_permission()` del kernel evalúa en un orden fijo y **se detiene en la primera clase que coincide**:

1. Si `fsuid == inode.i_uid` → usa la tríada del **propietario**. Listo.
2. Si no, si el GID del inodo es el fsgid del proceso o está en sus grupos suplementarios → usa la tríada del **grupo**. Listo.
3. Si no → usa la tríada de **otros**.

No hay "acumular lo mejor de las tres". Esto produce la paradoja canónica:

```console
$ sudo install -o alice -g devs -m 0407 /dev/null /tmp/paradox
$ ls -l /tmp/paradox
-r-----rwx 1 alice devs 0 Aug 26 09:20 /tmp/paradox

$ id alice
uid=1001(alice) gid=1001(alice) groups=1001(alice),1500(devs)
$ sudo -u alice bash -c 'echo x >> /tmp/paradox'
bash: line 1: /tmp/paradox: Permission denied

$ id bob
uid=1002(bob) gid=1002(bob) groups=1002(bob)
$ sudo -u bob bash -c 'echo x >> /tmp/paradox'   # succeeds — bob falls to "other"
$ cat /tmp/paradox
x
```

El propietario es la parte **más** restringida. Por eso, cualquier regla de auditoría que marque "escribible por todos" también debe marcar "otros más permisivo que grupo o propietario" — el segundo caso es más raro y peor, porque invierte la intención.

### 3.1 Las exenciones de root son capabilities, no magia

| Capability | Qué omite |
|---|---|
| `CAP_DAC_OVERRIDE` | Todas las verificaciones de lectura/escritura/búsqueda. Para `execve()` sobre un archivo regular todavía requiere que **al menos un** bit `x` esté puesto. |
| `CAP_DAC_READ_SEARCH` | Solo verificaciones de lectura y búsqueda en directorios (sin escritura). |
| `CAP_FOWNER` | Verificaciones que normalmente requieren `fsuid == i_uid`: `chmod`, `utime`, borrado con sticky bit. |
| `CAP_CHOWN` | `chown()` arbitrario a cualquier UID/GID. |
| `CAP_FSETID` | Evita el borrado automático de setuid/setgid al escribir y al hacer `chmod` hacia un grupo ajeno. |

```console
$ sudo install -m 0000 -o root /dev/null /tmp/nomode
$ sudo cat /tmp/nomode        # fine: CAP_DAC_OVERRIDE
$ sudo /tmp/nomode
sudo: /tmp/nomode: command not found
$ sudo chmod 0100 /tmp/nomode && sudo /tmp/nomode; echo "exit=$?"
exit=0                        # one x bit is enough for root
```

En un contenedor con `capabilities: drop: ["ALL"]`, el UID 0 **no** está exento de nada. Por eso "la imagen corre como root así que los permisos no importan" es falso en cualquier plataforma moderna.

---

## 4. `chmod` — simbólico vs octal, y la trampa de la recursión

### 4.1 Dos gramáticas, garantías distintas

```
chmod [OPTION]... MODE[,MODE]... FILE...
chmod [OPTION]... OCTAL-MODE FILE...
chmod [OPTION]... --reference=RFILE FILE...

MODE := [ugoa...][[-+=][perms...]...]
perms := r w x X s t   |   u g o
```

| Aspecto | Octal (`chmod 2750`) | Simbólico (`chmod g+rwX,o-rwx`) |
|---|---|---|
| Semántica | **Absoluta** — fija los 12 bits | **Relativa** — modifica solo los bits nombrados (`=` es absoluto por clase) |
| Bits especiales | Deben declararse o se **borran** (`750` de 3 dígitos borra setuid/setgid/sticky) | Intactos salvo que se los nombre |
| Interacción con `umask` | Ninguna — `chmod` nunca consulta la umask | Ninguna, **excepto** un `+x`/`+w` desnudo sin clase, que *sí* se filtra por la umask |
| Idempotente / declarativo | Sí — seguro en gestión de configuración | No — el resultado depende del estado previo |
| Seguridad en recursión | Peligroso: el mismo modo para archivos y directorios | Seguro con `X`: `chmod -R a+rX` |
| Legibilidad en revisión | Alta para patrones estándar (`0640`, `2770`, `1777`) | Alta para deltas que expresan intención |

**Regla práctica:** declarar con octal (Ansible, tmpfiles.d, `install -m`); reparar con simbólico (`+X`, `-s`, `+t`).

La interacción del `+x` desnudo con la umask sorprende a mucha gente:

```console
$ umask
0022
$ install -m 0600 /dev/null /tmp/u1 && chmod +x /tmp/u1 && stat -c %a /tmp/u1
711
$ install -m 0600 /dev/null /tmp/u2 && chmod a+x /tmp/u2 && stat -c %a /tmp/u2
711
$ install -m 0600 /dev/null /tmp/u3 && chmod ugo+x /tmp/u3 && stat -c %a /tmp/u3
711
```

Sin letra de clase, `+x` significa "`a+x` filtrado por la umask" según POSIX — con `umask 022` igual da las tres acá porque `chmod` aplica el *complemento*; cambiá la umask y el resultado cambia:

```console
$ (umask 077; install -m 0600 /dev/null /tmp/u4; chmod +x /tmp/u4; stat -c %a /tmp/u4)
700
```

Escribí siempre la clase de forma explícita (`u+x`, `a+x`) en los scripts.

### 4.2 `X` — el único execute recursivo seguro

`X` pone `x` **solo** si el destino es un directorio, o si algún bit de ejecución ya está puesto en un archivo regular.

```console
$ sudo install -d -m 0700 /tmp/tree/bin && sudo install -m 0755 /bin/true /tmp/tree/bin/tool \
    && sudo install -m 0600 /dev/null /tmp/tree/bin/config.ini
$ sudo chmod -R 0755 /tmp/tree            # WRONG
$ find /tmp/tree -printf '%M %p\n'
drwxr-xr-x /tmp/tree
drwxr-xr-x /tmp/tree/bin
-rwxr-xr-x /tmp/tree/bin/tool
-rwxr-xr-x /tmp/tree/bin/config.ini       <-- config is now executable and world-readable

$ sudo chmod -R u=rwX,g=rX,o= /tmp/tree   # RIGHT
$ find /tmp/tree -printf '%M %p\n'
drwxr-x--- /tmp/tree
drwxr-x--- /tmp/tree/bin
-rwxr-x--- /tmp/tree/bin/tool
-rw-r----- /tmp/tree/bin/config.ini
```

El equivalente basado en `find`, para cuando necesitás modos absolutos distintos:

```console
$ sudo find /srv/app -type d -exec chmod 2750 {} +
$ sudo find /srv/app -type f -exec chmod 0640 {} +
$ sudo find /srv/app -type f -name '*.sh' -exec chmod 0750 {} +
```

`-exec ... +` agrupa los argumentos (un `chmod` cada ~2000 rutas) en lugar de un proceso por archivo — en un árbol de 400k archivos esa es la diferencia entre 6 segundos y 20 minutos.

### 4.3 `chmod` nunca alcanza el modo propio de un enlace simbólico

Los modos de los symlinks son `lrwxrwxrwx` en Linux y no se usan en ninguna decisión de acceso. `chmod` no tiene `-h`; siempre desreferencia.

```console
$ ln -s /etc/hostname /tmp/link
$ ls -l /tmp/link
lrwxrwxrwx 1 alice alice 13 Aug 26 10:02 /tmp/link -> /etc/hostname
$ chmod 600 /tmp/link
chmod: changing permissions of '/tmp/link': Operation not permitted   # target is root-owned
```

Para un `chmod -R` recursivo sobre un árbol que contiene symlinks, el `chmod` de GNU omite los symlinks encontrados durante el recorrido pero **sí sigue** los nombrados en la línea de comandos — el origen de los `chmod` accidentales sobre `/etc` a través de un enlace perdido.

### 4.4 Flags útiles

```console
$ chmod -c 0640 /srv/data/reports/q3.csv
mode of '/srv/data/reports/q3.csv' changed from 0644 (rw-r--r--) to 0640 (rw-r-----)

$ chmod -v 0640 /srv/data/reports/q3.csv
mode of '/srv/data/reports/q3.csv' retained as 0640 (rw-r-----)

$ chmod --reference=/etc/shadow /srv/secrets/token
$ stat -c '%A %a' /srv/secrets/token
-rw-r----- 640
```

`-c` (solo cambios) es la verbosidad correcta para automatización: silencioso cuando convergió, ruidoso cuando hubo deriva.

---

## 5. `chown` / `chgrp` — propiedad y sus efectos colaterales silenciosos

### 5.1 Superficie de sintaxis

```
chown [OPTION]... [OWNER][:[GROUP]] FILE...
chown [OPTION]... --reference=RFILE FILE...
chgrp [OPTION]... GROUP FILE...
```

| Forma | Efecto |
|---|---|
| `chown alice file` | Solo UID; el GID queda intacto |
| `chown alice:devs file` | UID y GID |
| `chown alice: file` | UID, y el GID pasa a ser el **grupo de login de alice** |
| `chown :devs file` | Solo GID — idéntico a `chgrp devs file` |
| `chown alice.devs file` | Separador heredado de SysV; ambiguo cuando los nombres de usuario contienen `.` — evitalo |
| `chown 1001:1500 file` | Numérico — necesario cuando el nombre no resuelve (contenedores, NFS, rescate) |
| `chown --from=root:root alice:devs file` | Condicional: cambia solo si coincide con lo actual |
| `chown -h alice link` | Cambia el **symlink mismo** (`lchown`), no el destino |
| `chown -R -h ...` | Recursivo, sin desreferenciar symlinks |
| `chown -R -L ...` | Recursivo, **siguiendo** directorios enlazados — peligroso |

```console
$ sudo chown -c --from=root:root svc-etl:data /srv/data/reports/q3.csv
changed ownership of '/srv/data/reports/q3.csv' from root:root to svc-etl:data
$ sudo chown -c --from=root:root svc-etl:data /srv/data/reports/q3.csv
$                                     # no output: already converged
```

### 5.2 Quién puede hacer chown

Un usuario sin privilegios **nunca puede regalar un archivo** (no hay `chown` hacia otro UID — Linux no tiene un interruptor para apagar `_POSIX_CHOWN_RESTRICTED`). Un usuario *sí puede* hacer `chgrp` de un archivo propio hacia cualquier grupo del que sea miembro:

```console
$ id
uid=1001(alice) gid=1001(alice) groups=1001(alice),1500(devs)
$ touch /tmp/mine
$ chgrp devs /tmp/mine ; echo "exit=$?"
exit=0
$ chgrp ops /tmp/mine
chgrp: changing group of '/tmp/mine': Operation not permitted
$ chown bob /tmp/mine
chown: changing ownership of '/tmp/mine': Operation not permitted
```

### 5.3 Las dos reglas de borrado silencioso (alto rendimiento, frecuentemente pasadas por alto)

**Regla 1 — `chown`/`chgrp` borran setuid y setgid.** Desde Linux 2.2.13 esto también aplica a root:

```console
$ sudo install -m 4755 -o root -g root /bin/true /tmp/probe
$ stat -c '%a %A %U:%G' /tmp/probe
4755 -rwsr-xr-x root:root
$ sudo chown alice /tmp/probe
$ stat -c '%a %A %U:%G' /tmp/probe
755 -rwxr-xr-x alice:root
```

**Consecuencia:** en cualquier script de aprovisionamiento, el `chown` debe ir **antes** del `chmod`, nunca después. Invertir el orden produce en silencio un binario sin setuid y un servicio que falla solo bajo carga, cuando se ejercita por primera vez el camino privilegiado.

```bash
# WRONG — chown wipes the bits chmod just set
chmod 4755 /usr/local/bin/helper
chown root:root /usr/local/bin/helper

# RIGHT
chown root:root /usr/local/bin/helper
chmod 4755 /usr/local/bin/helper

# BEST — atomic, single syscall sequence, no window
install -o root -g root -m 4755 helper /usr/local/bin/helper
```

**Regla 2 — escribir en un archivo borra setuid, y borra setgid cuando `g+x` está puesto.** (`should_remove_suid()` en el VFS; se omite con `CAP_FSETID`.)

```console
$ install -m 6777 /bin/true /tmp/probe2        # owned by alice
$ stat -c '%a %A' /tmp/probe2
6777 -rwsrwsrwx
$ dd if=/dev/zero of=/tmp/probe2 bs=1 count=1 seek=0 conv=notrunc status=none
$ stat -c '%a %A' /tmp/probe2
777 -rwxrwxrwx
```

**Regla 3 — `chmod g+s` sobre un archivo de grupo ajeno falla *en silencio*.** Sin `CAP_FSETID`, el kernel enmascara `S_ISGID` fuera del modo solicitado y devuelve éxito:

```console
$ sudo install -o alice -g ops -m 0644 /dev/null /tmp/silent
$ sudo -u alice chmod g+s /tmp/silent ; echo "exit=$?"
exit=0
$ stat -c '%a' /tmp/silent
644
```

Un estado de salida 0 no prueba que el modo se aplicó. **Siempre volvé a hacer `stat` después de un cambio de modo privilegiado en automatización.**

### 5.4 Propiedad a través de las herramientas de copia

| Herramienta | Modo | Propietario/Grupo | setuid/setgid | ACLs | xattrs |
|---|---|---|---|---|---|
| `cp src dst` | `0666`/`0777` filtrado por umask | quien copia | descartado | no | no |
| `cp -p` / `cp --preserve=mode,ownership,timestamps` | preservado | preservado **solo con privilegios** | preservado con privilegios | no | no |
| `cp -a` (`-dR --preserve=all`) | preservado | preservado con privilegios | preservado con privilegios | sí | sí |
| `mv` (mismo sistema de archivos) | sin cambios — es un `rename()` | sin cambios | sin cambios | sin cambios | sin cambios |
| `mv` (entre sistemas de archivos) | se comporta como `cp -p` + `unlink` | mejor esfuerzo | mejor esfuerzo | mejor esfuerzo | mejor esfuerzo |
| `install -m -o -g` | explícito | explícito | explícito | no | no |
| `tar -x` | filtrado por umask salvo `-p` | `--same-owner` (por defecto para root) | con `-p` | `--acls` | `--xattrs` |
| `rsync -a` | `-p` preservado | `-o -g`, solo root | preservado | `-A` | `-X` |

```console
$ sudo rsync -aAX --numeric-ids --chown=svc-etl:data /stage/reports/ /srv/data/reports/
$ sudo tar --acls --xattrs --same-owner -xpf backup.tar -C /srv
```

`--numeric-ids` es obligatorio cuando origen y destino no comparten `/etc/passwd` — si no, rsync remapea por nombre y reasigna calladamente los archivos al UID que tenga ese nombre en el destino.

---

## 6. Bits especiales en producción

### 6.1 setuid — la superficie de auditoría que hay que minimizar

```console
$ ls -l /usr/bin/passwd
-rwsr-xr-x 1 root root 68208 Mar 23  2025 /usr/bin/passwd
$ stat -c '%a %A %U:%G %n' /usr/bin/passwd
4755 -rwsr-xr-x root:root /usr/bin/passwd
```

Enumerá toda la superficie setuid/setgid de un host — esto pertenece a tu línea base:

```console
$ sudo find / -xdev \( -perm -4000 -o -perm -2000 \) -type f \
      -printf '%M %u:%g %10s %p\n' 2>/dev/null | sort -k4
-rwsr-xr-x root:root      55744 /usr/bin/chfn
-rwsr-xr-x root:root      44808 /usr/bin/chsh
-rwsr-xr-x root:root      88304 /usr/bin/gpasswd
-rwsr-xr-x root:root      72704 /usr/bin/mount
-rwsr-xr-x root:root      68208 /usr/bin/newgrp
-rwsr-xr-x root:root      68208 /usr/bin/passwd
-rwsr-xr-x root:root      52880 /usr/bin/su
-rwsr-xr-x root:root     277936 /usr/bin/sudo
-rwsr-xr-x root:root      52880 /usr/bin/umount
-rwxr-sr-x root:shadow    35200 /usr/bin/expiry
-rwxr-sr-x root:crontab   43568 /usr/bin/crontab
-rwxr-sr-x root:tty       35112 /usr/bin/wall
-rwxr-sr-x root:shadow    31376 /usr/sbin/unix_chkpwd
```

Guardala y compará las diferencias en cada arranque:

```console
$ sudo find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -printf '%M %u:%g %p\n' \
      2>/dev/null | sort > /var/lib/baseline/setuid.txt
$ diff <(sudo find / -xdev \( -perm -4000 -o -perm -2000 \) -type f \
      -printf '%M %u:%g %p\n' 2>/dev/null | sort) /var/lib/baseline/setuid.txt
> -rwsr-xr-x root:root /usr/local/bin/backup-helper
```

**setuid se ignora en scripts interpretados.** El kernel se niega a honrarlo en archivos con `#!`, por la carrera imposible de ganar entre abrir el script y que el intérprete lo vuelva a abrir:

```console
$ printf '#!/bin/bash\nid -u\n' | sudo tee /tmp/who.sh >/dev/null
$ sudo chown root:root /tmp/who.sh && sudo chmod 4755 /tmp/who.sh
$ ls -l /tmp/who.sh
-rwsr-xr-x 1 root root 21 Aug 26 10:40 /tmp/who.sh
$ /tmp/who.sh
1001
```

El reemplazo moderno correcto para binarios con privilegios acotados son las **file capabilities**, no setuid:

```console
$ getcap /usr/bin/ping
/usr/bin/ping cap_net_raw=ep
$ ls -l /usr/bin/ping
-rwxr-xr-x 1 root root 76040 Mar 23  2025 /usr/bin/ping
$ sudo setcap cap_net_bind_service=+ep /usr/local/bin/edge-proxy
$ getcap /usr/local/bin/edge-proxy
/usr/local/bin/edge-proxy cap_net_bind_service=ep
```

| Mecanismo | Privilegio otorgado | Radio de daño ante compromiso | Sobrevive a `cp` | Sobrevive a `chown` |
|---|---|---|---|---|
| setuid root | UID 0 completo | Todo el host | No | No (se borra) |
| setgid a un grupo de servicio | El acceso a archivos de ese grupo | Archivos del grupo | No | No (se borra) |
| File capability | Una capability | Solo esa capability | No (se pierde el xattr) | Sí (el xattr es independiente) |
| Regla de `sudo` | Lo que la regla permita | Auditado, declarado centralmente | n/a | n/a |
| `AmbientCapabilities=` de systemd | Una capability, sin marca en disco | Esa capability, acotada al servicio | n/a | n/a |

### 6.2 setgid en directorios — la primitiva de colaboración por grupo

Sin setgid, el grupo de un archivo nuevo es el **GID efectivo del proceso**. Con setgid, es el **GID del directorio padre**, y los subdirectorios nuevos heredan el propio bit setgid.

```console
$ sudo groupadd -g 1500 devs 2>/dev/null; sudo usermod -aG devs alice; sudo usermod -aG devs carol
$ sudo install -d -o root -g devs -m 2770 /srv/build
$ ls -ld /srv/build
drwxrws--- 2 root devs 4096 Aug 26 10:55 /srv/build

$ sudo -u alice bash -c 'touch /srv/build/artifact.tar; mkdir /srv/build/stage'
$ find /srv/build -printf '%M %u:%g %p\n'
drwxrws--- root:devs /srv/build
-rw-r--r-- alice:devs /srv/build/artifact.tar
drwxr-sr-x alice:devs /srv/build/stage
```

El grupo está bien, pero el **modo** sigue siendo `0644`/`0755` porque la umask es `022`. `carol` puede leer pero no sobrescribir. setgid arregla la *herencia de propiedad*; no arregla la *herencia de permisos*. Ese es el trabajo de la umask:

```console
$ sudo -u alice bash -c 'umask 007; touch /srv/build/artifact2.tar; mkdir /srv/build/stage2'
$ find /srv/build -newer /srv/build/artifact.tar -printf '%M %u:%g %p\n'
-rw-rw---- alice:devs /srv/build/artifact2.tar
drwxrws--- alice:devs /srv/build/stage2
```

Ahora `carol` puede sobrescribir. **setgid + umask 007/002 es la receta completa del directorio compartido.**

Tres formas de conseguir herencia de grupo, comparadas:

| Mecanismo | Alcance | ¿Controla el modo? | ¿Persiste ante `mv`? | Modo de falla |
|---|---|---|---|---|
| `chmod g+s <dir>` (setgid) | Por subárbol de directorio | No — la umask sigue mandando | El bit está en el directorio, así que sí para archivos nuevos | Silencioso: el bit lo tira un `chmod 770` posterior de 3 dígitos |
| ACL POSIX por defecto (`setfacl -d`) | Por subárbol de directorio | **Sí** — y **anula la umask** | Sí | Herramientas que ignoran ACLs (`cp` sin `-a`, `tar` sin `--acls`) la descartan |
| `mount -o grpid` (`bsdgroups`) | Todo el sistema de archivos | No | Sí | Sorprende a quien asuma los valores por defecto de Linux; debe estar en `/etc/fstab` |

Las ACL por defecto son la forma más fuerte porque derrotan la umask por completo:

```console
$ sudo setfacl -d -m u::rwx -m g::rwx -m o::--- /srv/build
$ getfacl -p /srv/build
# file: /srv/build
# owner: root
# group: devs
# flags: -s-
user::rwx
group::rwx
other::---
default:user::rwx
default:group::rwx
default:other::---

$ sudo -u alice bash -c 'umask 077; touch /srv/build/acl-test'
$ getfacl -p /srv/build/acl-test
# file: /srv/build/acl-test
# owner: alice
# group: devs
user::rw-
group::rw-
other::---
```

El proceso aplicó `umask 077`, y el archivo sigue siendo escribible por el grupo: **cuando el directorio padre lleva una ACL por defecto, `open()`/`mkdir()` ignoran la umask.** Esta es la causa número uno de "nuestra umask endurecida no está haciendo efecto".

### 6.3 Sticky bit — borrado restringido

El permiso de escritura en un directorio normalmente permite borrar *cualquier* entrada, sin importar quién sea el propietario del archivo. `S_ISVTX` restringe `unlink`/`rename` al propietario del archivo, al propietario del directorio o a `CAP_FOWNER`.

```console
$ ls -ld /tmp /var/tmp /dev/shm
drwxrwxrwt 18 root root  4096 Aug 26 11:02 /tmp
drwxrwxrwt  5 root root  4096 Aug 26 04:12 /var/tmp
drwxrwxrwt  2 root root    40 Aug 26 03:58 /dev/shm

$ sudo -u alice touch /tmp/alice.lock
$ sudo -u bob rm -f /tmp/alice.lock
rm: cannot remove '/tmp/alice.lock': Operation not permitted
$ sudo -u bob mv /tmp/alice.lock /tmp/stolen.lock
mv: cannot move '/tmp/alice.lock' to '/tmp/stolen.lock': Operation not permitted
```

Fijate en el errno: **`EPERM` (Operation not permitted)**, no `EACCES` (Permission denied). Distinguirlos es un atajo diagnóstico — ver §10.

El sticky es necesario pero no suficiente para un directorio temporal compartido. Combinalo con los sysctls de endurecimiento de symlinks/hardlinks (Linux ≥ 3.6 / ≥ 4.19):

```console
$ sysctl fs.protected_symlinks fs.protected_hardlinks fs.protected_fifos fs.protected_regular
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
fs.protected_fifos = 1
fs.protected_regular = 2
```

Estos hacen que el kernel se niegue a seguir un symlink en un directorio sticky escribible por todos cuando quien lo sigue no es el propietario del enlace — cerrando la clásica escalada de privilegios por carrera de symlinks en `/tmp` que los bits de modo por sí solos no pueden.

---

## 7. `umask` — el valor por defecto que todo hereda

### 7.1 Mecánica

`umask` es una máscara de 9 bits por proceso, heredada a través de `fork()` **y** de `execve()`. `open(2)`, `mkdir(2)`, `mknod(2)` calculan:

```
final_mode = requested_mode & ~umask
```

Solo puede **borrar** bits, nunca ponerlos, y aplica **únicamente en el momento de la creación** — `chmod` nunca se filtra por ella.

| Creador | `requested_mode` | Con `umask 022` | Con `umask 002` | Con `umask 077` | Con `umask 027` |
|---|---|---|---|---|---|
| `touch` / `open(O_CREAT)` en shells | `0666` | `0644` | `0664` | `0600` | `0640` |
| `mkdir` | `0777` | `0755` | `0775` | `0700` | `0750` |
| salida de `gcc`, `install` por defecto | `0777`/explícito | `0755` | `0775` | `0700` | `0750` |
| `ssh-keygen` (`0600` explícito) | `0600` | `0600` | `0600` | `0600` | `0600` |

```console
$ umask
0022
$ umask -S
u=rwx,g=rx,o=rx
$ touch /tmp/f && mkdir /tmp/d && stat -c '%a %n' /tmp/f /tmp/d
644 /tmp/f
755 /tmp/d

$ (umask 027; touch /tmp/f27; mkdir /tmp/d27; stat -c '%a %n' /tmp/f27 /tmp/d27)
640 /tmp/f27
750 /tmp/d27

$ umask -S u=rwx,g=rx,o=      # symbolic form SETS the mask from the desired perms
$ umask
0027
```

Notá la inversión: `umask 027` y `umask -S u=rwx,g=rx,o=` son la misma máscara expresada de dos maneras. La forma octal es lo que *sacás*; la forma simbólica es lo que *conservás*. Las preguntas de examen explotan esto.

Los bits de ejecución nunca los otorga `open()` — por eso `touch` no puede producir jamás un archivo `0755` sin importar la umask, y por eso `umask 000` da `0666`, no `0777`.

### 7.2 De dónde viene realmente la umask — precedencia, gana el de arriba

| Origen | Alcance | Archivo / directiva |
|---|---|---|
| `umask` explícito en el script/shell en ejecución | Ese proceso y sus hijos | inline |
| `UMask=` de la unidad de systemd | Ese servicio | `/etc/systemd/system/<unit>.d/*.conf` |
| Valor global por defecto de systemd | Todos los servicios (`0022`) | `/etc/systemd/system.conf` → `DefaultUMask=` |
| Archivos rc del shell | Shells interactivos/de login | `~/.bashrc`, `~/.profile`, `/etc/profile`, `/etc/bashrc`, `/etc/profile.d/*.sh` |
| `pam_umask.so` | Cualquier sesión autenticada por PAM | `/etc/pam.d/common-session`, `/etc/pam.d/login` |
| `UMASK` / `USERGROUPS_ENAB` / `HOME_MODE` | Sesiones de login y `useradd` | `/etc/login.defs` |
| Valor por defecto del PID 1 | Todo lo demás | `0022` |

```console
$ grep -E '^(UMASK|HOME_MODE|USERGROUPS_ENAB)' /etc/login.defs
UMASK           022
HOME_MODE       0700
USERGROUPS_ENAB yes

$ grep -rn pam_umask /etc/pam.d/
/etc/pam.d/common-session:26:session optional    pam_umask.so

$ grep -n '^DefaultUMask' /etc/systemd/system.conf
#DefaultUMask=0022
```

`USERGROUPS_ENAB yes` implementa el modelo de **User Private Group**: `useradd alice` crea el grupo `alice` como grupo primario, y `pam_umask` luego relaja la umask de `022` a `002` *porque* el grupo primario contiene solo al usuario. Esa combinación es lo que hace que `002` sea seguro en un host multiusuario — y lo que la vuelve peligrosa si alguna vez asignás un grupo **compartido** como grupo primario de alguien.

Verificá lo que el servicio realmente recibió, no lo que configuraste:

```console
$ systemctl show report-exporter -p UMask
UMask=0027
$ pid=$(systemctl show -p MainPID --value report-exporter)
$ grep Umask /proc/$pid/status
Umask:	0027
```

`/proc/<pid>/status` es la verdad de campo. Todo lo demás es intención.

---

## 8. Acceso basado en grupos: el campo que realmente otorga acceso

### 8.1 Las credenciales se congelan al crear el proceso

Agregar un usuario a un grupo **no** afecta a ningún proceso que ya exista. Este es el reporte de "ya lo arreglé, ¿por qué sigue roto?" más común de todos.

```console
$ id alice
uid=1001(alice) gid=1001(alice) groups=1001(alice)
$ sudo usermod -aG devs alice
$ id alice                      # queries /etc/group — shows the NEW membership
uid=1001(alice) gid=1001(alice) groups=1001(alice),1500(devs)
$ sudo -u alice id              # a fresh process — also new
uid=1001(alice) gid=1001(alice) groups=1001(alice),1500(devs)
```

Pero la sesión SSH *existente* de alice:

```console
alice@node-01:~$ id
uid=1001(alice) gid=1001(alice) groups=1001(alice)
alice@node-01:~$ touch /srv/build/x
touch: cannot touch '/srv/build/x': Permission denied
```

`id` sin argumento lee las credenciales **del proceso**; `id alice` lee **la base de datos**. Cuando no coinciden, la sesión está desactualizada. Arreglos, en orden de preferencia:

```console
alice@node-01:~$ exec sg devs "$SHELL"     # new process with devs added
alice@node-01:~$ newgrp devs               # new shell with devs as the primary GID
alice@node-01:~$ id
uid=1001(alice) gid=1500(devs) groups=1500(devs),1001(alice)
```

Para servicios: `systemctl restart <unit>` — un reload no alcanza, porque `SupplementaryGroups=` se aplica en el `execve()`.

**`usermod -G` sin `-a` reemplaza la lista suplementaria entera.** `sudo usermod -G devs alice` saca a alice de `sudo`, `docker`, `adm` y todo lo demás. Siempre `-aG`.

### 8.2 Límites de grupos que muerden a escala

| Límite | Valor | Dónde duele |
|---|---|---|
| `NGROUPS_MAX` (Linux) | 65536 | Efectivamente ilimitado en local |
| Lista de gid de RPC `AUTH_SYS` | **16** | NFSv3/NFSv4 con `sec=sys`: los grupos 17+ se descartan en silencio, dando `EACCES` intermitente por montaje |
| Costo de búsqueda de `sudo`/PAM | O(grupos) por sesión | Hosts con LDAP/SSSD y 500+ grupos: logins lentos |

El techo de 16 grupos de NFS se resuelve del lado del servidor, haciendo que el servidor resuelva los grupos por sí mismo:

```console
$ grep RPCMOUNTDOPTS /etc/default/nfs-kernel-server
RPCMOUNTDOPTS="--manage-gids"
$ sudo systemctl restart nfs-server
```

Con `--manage-gids` el servidor ignora la lista de 16 entradas del cliente y busca los grupos del usuario en su propio servicio de nombres. Sin eso, un usuario en 20 grupos obtiene acceso no determinista según el orden de la lista — una caída genuinamente brutal de diagnosticar.

### 8.3 Cómo elegir entre los modelos

| Modelo | Configuración | Escala hasta | Debilidad |
|---|---|---|---|
| Solo propietario (`0600`/`0700`) | Nada | 1 principal | Ningún tipo de compartición |
| Un único grupo compartido (`2770` + umask `007`) | `groupadd`, `usermod -aG`, directorio setgid | ~decenas de principals, una clase de acceso | Un bit de granularidad: adentro o afuera |
| Múltiples grupos por árbol (ACL POSIX) | `setfacl -m g:x:rX -m g:y:rwX` | Muchas clases superpuestas | Requiere herramientas de copia/backup conscientes de ACLs; `ls -l` solo muestra un `+` |
| Etiquetas MAC (SELinux/AppArmor) | Módulos de política | Type enforcement, acotado al proceso | Alto costo operativo; ortogonal al DAC, no un reemplazo |
| UID por servicio (`DynamicUser=` de systemd) | Una directiva en la unidad | Aislamiento perfecto por servicio | No puede compartir datos sin ACLs explícitas o `StateDirectory` |

---

## 9. Declarar los permisos como infraestructura

La lección de la §1 es que los permisos deben vivir en control de versiones, no en el historial del shell. Abajo hay artefactos completos y funcionales para un servicio — `report-exporter`, corriendo como `svc-etl:data`, escribiendo en `/srv/data/reports`, compartido en solo lectura con el grupo `analysts`.

### 9.1 `systemd-tmpfiles` — el dueño declarativo de las rutas

`/etc/tmpfiles.d/report-exporter.conf`:

```
# Type Path                       Mode UID       GID       Age Argument
#
# d = create directory if missing, then enforce mode/owner
# D = like d, but empty it on boot
# Z = recursively enforce mode/owner/SELinux label on an existing tree
# z = same as Z, non-recursive
# f = create file if missing
# x = exclude path from cleanup

d  /srv/data                      0755 root      root      -   -
d  /srv/data/reports              2770 svc-etl   data      -   -
d  /srv/data/reports/archive      2750 svc-etl   data      30d -
f  /srv/data/reports/.keep        0640 svc-etl   data      -   -
d  /var/log/report-exporter       0750 svc-etl   adm       -   -
d  /run/report-exporter           0700 svc-etl   data      -   -

# Enforce the whole tree on every boot: undoes any manual drift
Z  /srv/data/reports              -    svc-etl   data      -   -
```

```console
$ sudo systemd-tmpfiles --create --clean /etc/tmpfiles.d/report-exporter.conf
$ find /srv/data -maxdepth 2 -printf '%M %u:%g %p\n'
drwxr-xr-x root:root /srv/data
drwxrws--- svc-etl:data /srv/data/reports
drwxr-s--- svc-etl:data /srv/data/reports/archive
-rw-r----- svc-etl:data /srv/data/reports/.keep
```

La línea `Z` es la razón por la que la deriva se autorrepara: modo y propiedad se vuelven a afirmar en cada arranque, así que el `chmod 777` de emergencia de un operador tiene una vida útil acotada.

### 9.2 Unidad de systemd — umask, grupos y modos de directorio

`/etc/systemd/system/report-exporter.service`:

```ini
[Unit]
Description=Report exporter (writes CSV artefacts to /srv/data/reports)
Documentation=https://internal.example.com/runbooks/report-exporter
After=network-online.target local-fs.target
Wants=network-online.target

[Service]
Type=exec
ExecStart=/usr/local/bin/report-exporter --out /srv/data/reports

# --- Identity -------------------------------------------------------------
User=svc-etl
Group=data
SupplementaryGroups=analysts

# --- Creation defaults ----------------------------------------------------
# 0027 => files 0640, directories 0750. Group reads, other gets nothing.
UMask=0027

# --- Managed state directories (systemd creates, chowns and chmods these) --
StateDirectory=report-exporter
StateDirectoryMode=0750
RuntimeDirectory=report-exporter
RuntimeDirectoryMode=0700
LogsDirectory=report-exporter
LogsDirectoryMode=0750
ConfigurationDirectory=report-exporter
ConfigurationDirectoryMode=0750

# --- Filesystem confinement ----------------------------------------------
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=/srv/data/reports
ReadOnlyPaths=/srv/data/reference

# --- Privilege confinement ------------------------------------------------
NoNewPrivileges=yes
CapabilityBoundingSet=
AmbientCapabilities=
RestrictSUIDSGID=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallFilter=@system-service
SystemCallArchitectures=native

Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
```

`RestrictSUIDSGID=yes` hace que cualquier intento del servicio de *crear* un archivo setuid o setgid falle con `EPERM` — la defensa más barata posible contra un servicio comprometido que planta un binario de puerta trasera.

```console
$ sudo systemctl daemon-reload && sudo systemctl restart report-exporter
$ systemctl show report-exporter -p UMask -p User -p Group -p SupplementaryGroups
UMask=0027
User=svc-etl
Group=data
SupplementaryGroups=analysts
$ pid=$(systemctl show -p MainPID --value report-exporter)
$ grep -E '^(Uid|Gid|Groups|Umask|CapEff)' /proc/$pid/status
Umask:	0027
Uid:	998	998	998	998
Gid:	1500	1500	1500	1500
Groups:	1501 
CapEff:	0000000000000000
```

### 9.3 Ansible — el mismo estado, idempotente

`roles/report-exporter/tasks/permissions.yml`:

```yaml
---
- name: Ensure the service group exists
  ansible.builtin.group:
    name: data
    gid: 1500
    state: present
    system: true

- name: Ensure the read-only consumer group exists
  ansible.builtin.group:
    name: analysts
    gid: 1501
    state: present
    system: true

- name: Ensure the service account exists
  ansible.builtin.user:
    name: svc-etl
    uid: 998
    group: data
    groups: []
    append: false
    system: true
    shell: /usr/sbin/nologin
    home: /var/lib/report-exporter
    create_home: false
    state: present

- name: Ensure the data root exists
  ansible.builtin.file:
    path: /srv/data
    state: directory
    owner: root
    group: root
    # QUOTED. Unquoted 0755 is parsed by YAML as decimal 755 == 0o1363.
    mode: "0755"

- name: Ensure the shared report directory is setgid and group-writable
  ansible.builtin.file:
    path: /srv/data/reports
    state: directory
    owner: svc-etl
    group: data
    mode: "2770"

- name: Ensure the archive directory is setgid and group-read-only
  ansible.builtin.file:
    path: /srv/data/reports/archive
    state: directory
    owner: svc-etl
    group: data
    mode: "2750"

- name: Grant analysts recursive read access via POSIX ACL (existing entries)
  ansible.posix.acl:
    path: /srv/data/reports
    entity: analysts
    etype: group
    permissions: rx
    recursive: true
    state: present

- name: Grant analysts read access on future entries (default ACL)
  ansible.posix.acl:
    path: /srv/data/reports
    entity: analysts
    etype: group
    permissions: rx
    default: true
    state: present

- name: Deny 'other' on future entries (default ACL overrides the umask)
  ansible.posix.acl:
    path: /srv/data/reports
    entity: ''
    etype: other
    permissions: '0'
    default: true
    state: present

- name: Install the exporter binary with an explicit mode
  ansible.builtin.copy:
    src: report-exporter
    dest: /usr/local/bin/report-exporter
    owner: root
    group: root
    mode: "0755"

- name: Install the credentials file with a restrictive mode
  ansible.builtin.template:
    src: exporter.env.j2
    dest: /etc/report-exporter/exporter.env
    owner: root
    group: data
    mode: "0640"
  notify: Restart report-exporter

- name: Assert no world-writable file exists under the data root
  ansible.builtin.command:
    cmd: find /srv/data -xdev -perm -0002 ! -type l -print
  register: ww
  changed_when: false
  failed_when: ww.stdout | length > 0
```

**La trampa del entrecomillado es real y cuesta caídas.** `mode: 0755` sin comillas es el entero YAML `755` (decimal), que Ansible interpreta como el octal `1363` → `drwxrw--wt`. Entrecomillá siempre, o usá el simbólico `mode: u=rwx,g=rx,o=rx`.

### 9.4 Imagen de contenedor — propiedad en tiempo de construcción

`Dockerfile`:

```dockerfile
# syntax=docker/dockerfile:1.7
FROM debian:12-slim AS build

WORKDIR /src
COPY --chmod=0755 build.sh .
RUN ./build.sh && install -m 0755 /src/out/report-exporter /out/report-exporter

FROM gcr.io/distroless/base-debian12:nonroot

# distroless "nonroot" is uid/gid 65532. Declare it numerically: the
# runtime has no /etc/passwd lookup guarantee, and Kubernetes'
# runAsNonRoot check cannot resolve names.
ARG APP_UID=65532
ARG APP_GID=65532

COPY --from=build --chown=${APP_UID}:${APP_GID} --chmod=0555 \
     /out/report-exporter /usr/local/bin/report-exporter

COPY --chown=${APP_UID}:${APP_GID} --chmod=0444 \
     config/defaults.yaml /etc/report-exporter/defaults.yaml

USER ${APP_UID}:${APP_GID}
ENTRYPOINT ["/usr/local/bin/report-exporter"]
```

`--chmod=0555` (lectura+ejecución, sin escritura) sobre el binario significa que un proceso comprometido no puede reescribir su propio ejecutable ni siquiera si el sistema de archivos raíz es escribible. Verificá las capas construidas en lugar de confiar en el Dockerfile:

```console
$ docker run --rm --entrypoint /busybox/sh gcr.io/distroless/base-debian12:debug \
    -c 'ls -ln /usr/local/bin/report-exporter'
-r-xr-xr-x 1 65532 65532 14680064 Aug 26 11:30 /usr/local/bin/report-exporter
```

### 9.5 Kubernetes — `runAsUser`, `fsGroup` y modos de volumen

`deploy/report-exporter.yaml`:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: data-platform
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
---
apiVersion: v1
kind: Secret
metadata:
  name: report-exporter-credentials
  namespace: data-platform
type: Opaque
stringData:
  DB_PASSWORD: "replace-me-via-external-secrets"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: report-exporter-data
  namespace: data-platform
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: fast-ssd
  resources:
    requests:
      storage: 50Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: report-exporter
  namespace: data-platform
  labels:
    app.kubernetes.io/name: report-exporter
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: report-exporter
  template:
    metadata:
      labels:
        app.kubernetes.io/name: report-exporter
    spec:
      automountServiceAccountToken: false
      securityContext:
        # Numeric only. runAsNonRoot cannot resolve a username.
        runAsUser: 65532
        runAsGroup: 65532
        runAsNonRoot: true
        # fsGroup: the kubelet recursively chgrp's the volume to this GID
        # and sets g+rw plus the setgid bit on its directories.
        fsGroup: 20001
        # OnRootMismatch: skip the recursive walk when the volume root
        # already has the right GID and setgid bit. On a 50Gi volume with
        # millions of inodes, "Always" adds minutes to every pod start and
        # is a documented cause of readiness-probe timeouts.
        fsGroupChangePolicy: OnRootMismatch
        supplementalGroups: [20002]
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: exporter
          image: registry.example.com/report-exporter:1.14.2
          imagePullPolicy: IfNotPresent
          args: ["--out", "/data/reports"]
          securityContext:
            allowPrivilegeEscalation: false
            privileged: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          env:
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: report-exporter-credentials
                  key: DB_PASSWORD
          volumeMounts:
            - name: data
              mountPath: /data
            - name: config
              mountPath: /etc/report-exporter
              readOnly: true
            - name: credentials
              mountPath: /var/run/secrets/report-exporter
              readOnly: true
            - name: tmp
              mountPath: /tmp
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              memory: 512Mi
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 10
            periodSeconds: 20
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: report-exporter-data
        - name: config
          configMap:
            name: report-exporter-config
            # 0444 in YAML 1.1 is octal -> 292 decimal -> mode 0444. Correct.
            # Writing 444 (no leading zero) means decimal 444 -> mode 0674. Wrong.
            defaultMode: 0444
        - name: credentials
          secret:
            secretName: report-exporter-credentials
            # Owner-read only. Combined with fsGroup, the kubelet sets the
            # mount's group so the container UID can traverse it.
            defaultMode: 0400
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
```

Verificá dentro del pod en ejecución — nunca supongas que el manifiesto fue respetado:

```console
$ kubectl -n data-platform exec deploy/report-exporter -- id
uid=65532 gid=65532 groups=65532,20001,20002

$ kubectl -n data-platform exec deploy/report-exporter -- ls -ldn /data /data/reports
drwxrwsr-x 3 0     20001 4096 Aug 26 11:44 /data
drwxrwsr-x 2 65532 20001 4096 Aug 26 11:45 /data/reports

$ kubectl -n data-platform exec deploy/report-exporter -- ls -ln /var/run/secrets/report-exporter/
total 0
lrwxrwxrwx 1 0 0 15 Aug 26 11:44 DB_PASSWORD -> ..data/DB_PASSWORD

$ kubectl -n data-platform exec deploy/report-exporter -- stat -c '%a %U:%G %n' \
    /var/run/secrets/report-exporter/..data/DB_PASSWORD
400 root:20001 /var/run/secrets/report-exporter/..data/DB_PASSWORD
```

Notá que `/data` es `drwxrwsr-x` con GID `20001`: esa `s` es el bit setgid que el kubelet aplicó como parte de `fsGroup`, que es exactamente el mecanismo de la §6.2 — Kubernetes no inventó nada, automatizó `chgrp -R` + `chmod g+s`.

| Campo | Capa que manipula | Se aplica a |
|---|---|---|
| `runAsUser` / `runAsGroup` | UID/GID del proceso en el `execve()` | El proceso del contenedor |
| `fsGroup` | `chgrp` recursivo + `g+rws` sobre volúmenes | `emptyDir`, PVCs cuyo driver CSI lo soporte; **no** `hostPath` |
| `fsGroupChangePolicy` | Si el recorrido recursivo se ejecuta o no | Latencia de montaje del volumen |
| `supplementalGroups` | Lista de `setgroups()` | Acceso a GIDs preexistentes en almacenamiento compartido (NFS) |
| `defaultMode` / `items[].mode` | Modo de los archivos proyectados | `secret`, `configMap`, `downwardAPI`, `projected` |
| `readOnlyRootFilesystem` | Flag de montaje `ro` | Todo lo que esté fuera de los volúmenes declarados |

---

## 10. Verificación y diagnóstico de fallas

### 10.1 Leé primero el errno — particiona el espacio de búsqueda

| errno | Mensaje | Significado | Lo primero que hay que revisar |
|---|---|---|---|
| `EACCES` (13) | `Permission denied` | La verificación DAC (modo/ACL) o un LSM dijo que no | `namei -l`, `getfacl`, `ausearch -m AVC` |
| `EPERM` (1) | `Operation not permitted` | Denegación de clase propiedad: unlink con sticky bit, `chown` por quien no es propietario, `chattr +i`, capability faltante | `ls -ld` del padre, `lsattr`, `getpcaps` |
| `EROFS` (30) | `Read-only file system` | Flag de montaje, no permisos | `findmnt -no OPTIONS <path>` |
| `ETXTBSY` (26) | `Text file busy` | Escribir sobre un binario que se está ejecutando | `fuser -v <path>` |
| `EISDIR` / `ENOTDIR` (21/20) | | Discordancia de tipo de ruta, no de permiso | `stat` sobre los componentes |
| `ENOENT` (2) sobre un archivo existente | `No such file or directory` | Un padre carece de `x` **y** la herramienta lo enmascara, o `hidepid`/namespace de montaje | `namei -l`, `findmnt` |

### 10.2 La escalera de travesía — `namei -l` es la herramienta más rápida que tenés

Las fallas de permisos casi nunca son sobre el archivo hoja. `namei` recorre cada componente:

```console
$ sudo -u analyst-01 cat /srv/data/reports/q3.csv
cat: /srv/data/reports/q3.csv: Permission denied

$ namei -l /srv/data/reports/q3.csv
f: /srv/data/reports/q3.csv
 dr-xr-xr-x root    root    /
 drwxr-xr-x root    root    srv
 drwxr-x--- root    data    data          <-- analyst-01 is not in 'data'
 drwxrws--- svc-etl data    reports
 -rw-rw-r-- svc-etl data    q3.csv        <-- leaf is world-readable!
```

La hoja es `rw-rw-r--`; cualquiera podría leerla *si pudiera llegar hasta ella*. El bloqueo está en `/srv/data`, dos niveles más arriba. Arreglar la hoja no habría cambiado nada. Este es el hábito diagnóstico de mayor valor de todo el objetivo.

```console
$ sudo chmod o+x /srv/data          # traversal only, no listing
$ namei -l /srv/data/reports/q3.csv | sed -n '4p'
 drwxr-x--x root    data    data
$ sudo -u analyst-01 cat /srv/data/reports/q3.csv | head -1
region,revenue,quarter
```

### 10.3 Probá como el principal, no como vos mismo

```console
$ sudo -u analyst-01 test -r /srv/data/reports/q3.csv && echo READABLE || echo DENIED
READABLE
$ sudo -u analyst-01 test -w /srv/data/reports && echo WRITABLE || echo DENIED
DENIED
$ sudo -u analyst-01 test -x /srv/data && echo TRAVERSABLE || echo DENIED
TRAVERSABLE

# Exactly what the kernel would decide, including ACLs — no shell heuristics
$ sudo -u analyst-01 -- python3 -c \
  'import os,sys; print(os.access("/srv/data/reports", os.W_OK, effective_ids=True))'
False
```

Para un servicio que ya arrancó, simulá su conjunto real de credenciales:

```console
$ sudo setpriv --reuid=svc-etl --regid=data --groups=analysts --inh-caps=-all -- \
    sh -c 'id; touch /srv/data/reports/probe && echo WRITE_OK; rm -f /srv/data/reports/probe'
uid=998(svc-etl) gid=1500(data) groups=1501(analysts)
WRITE_OK
```

`setpriv` le gana a `sudo -u` acá porque reproduce la lista de grupos suplementarios y el conjunto de capabilities *exactos*, en lugar de lo que `sudo` calcule a partir de `/etc/group`.

### 10.4 Cuando los bits de modo se ven bien y aun así falla

Recorré esta lista en orden — cada paso es barato:

```console
# 1. ACLs — the '+' in ls -l is the only visible hint
$ ls -l /srv/data/reports/q3.csv
-rw-rw----+ 1 svc-etl data 481203 Aug 26 11:52 /srv/data/reports/q3.csv
$ getfacl -p /srv/data/reports/q3.csv
# file: /srv/data/reports/q3.csv
# owner: svc-etl
# group: data
user::rw-
user:analyst-01:rw-		#effective:r--
group::rw-			#effective:r--
mask::r--                       <-- THE MASK is capping everything at r--
other::---
$ sudo setfacl -m m::rw- /srv/data/reports/q3.csv     # raise the mask

# 2. Immutable / append-only attributes -> EPERM even for root
$ lsattr /srv/data/reports/q3.csv
----i---------e------- /srv/data/reports/q3.csv
$ sudo chattr -i /srv/data/reports/q3.csv

# 3. Mount options
$ findmnt -no TARGET,FSTYPE,OPTIONS /srv/data
/srv/data ext4 rw,nosuid,nodev,noexec,relatime
#                              ^^^^^^ explains "Permission denied" on execve

# 4. SELinux / AppArmor
$ getenforce
Enforcing
$ ls -Z /srv/data/reports/q3.csv
system_u:object_r:default_t:s0 /srv/data/reports/q3.csv
$ sudo ausearch -m AVC -ts recent | tail -5
type=AVC msg=audit(1756208134.881:412): avc:  denied  { read } for  pid=48122
  comm="report-exporter" name="q3.csv" dev="dm-0" ino=1180231
  scontext=system_u:system_r:etl_t:s0 tcontext=system_u:object_r:default_t:s0
  tclass=file permissive=0
$ sudo restorecon -Rv /srv/data/reports
Relabeled /srv/data/reports/q3.csv from system_u:object_r:default_t:s0
  to system_u:object_r:etl_data_t:s0

# 5. Capabilities of the failing process
$ pid=$(pgrep -f report-exporter | head -1)
$ getpcaps $pid
$pid: =
$ grep -E '^(Uid|Gid|Groups)' /proc/$pid/status
Uid:	998	998	998	998
Gid:	1500	1500	1500	1500
Groups:	1501
```

### 10.5 `strace` — la escalada hacia la verdad de campo

Cuando fallan todas las hipótesis, mirá la llamada al sistema:

```console
$ sudo strace -f -e trace=%file -y -s 200 -o /tmp/trace.log \
    setpriv --reuid=svc-etl --regid=data -- /usr/local/bin/report-exporter --out /srv/data/reports
$ grep -E 'EACCES|EPERM|EROFS' /tmp/trace.log
48311 openat(AT_FDCWD, "/srv/data/reports/q3.csv.tmp", O_WRONLY|O_CREAT|O_EXCL, 0600) = -1 EACCES (Permission denied)
48311 access("/srv/data/reference/schema.json", R_OK) = -1 EACCES (Permission denied)
```

La primera línea es la verdadera, y nombra un archivo `.tmp` que la aplicación nunca registra: escribir-y-renombrar es invisible para la depuración a nivel de logs, pero obvio en un trace.

### 10.6 Auditorías a nivel de flota

```console
# World-writable regular files (excluding symlinks, which are always lrwxrwxrwx)
$ sudo find / -xdev -type f -perm -0002 -printf '%M %u:%g %p\n' 2>/dev/null
-rw-rw-rw- root:root /var/log/app/debug.log

# World-writable directories MISSING the sticky bit -- the real risk
$ sudo find / -xdev -type d -perm -0002 ! -perm -1000 -printf '%M %u:%g %p\n' 2>/dev/null
drwxrwxrwx root:root /var/spool/uploads

# Files with no valid owner (deleted account, restored backup, container UID leak)
$ sudo find / -xdev \( -nouser -o -nogroup \) -printf '%U:%G %M %p\n' 2>/dev/null
1004:1004 -rw-r--r-- /home/former-employee/notes.md

# Group-writable files under a system path
$ sudo find /usr /etc -xdev -type f -perm -0020 -printf '%M %u:%g %p\n' 2>/dev/null

# find -perm semantics -- the three forms are NOT interchangeable
$ find /tmp -maxdepth 1 -perm 0644   -printf '%M %p\n'   # EXACTLY 0644
$ find /tmp -maxdepth 1 -perm -0644  -printf '%M %p\n'   # ALL of these bits set
$ find /tmp -maxdepth 1 -perm /0644  -printf '%M %p\n'   # ANY of these bits set
```

Reconciliá contra la base de datos de paquetes — el único registro autoritativo de qué es "correcto":

```console
$ sudo dpkg --verify | grep -v '^..5' | head
??5?????? c /etc/ssh/sshd_config
missing     /usr/share/doc/openssh-server/NEWS.Debian.gz

$ rpm -Va | awk '$1 ~ /M/ {print}'          # RHEL: M = mode differs
.M.......  g /var/log/wtmp
.M....G..    /usr/bin/ping
```

Las columnas de salida de `dpkg --verify` son `?5?????? ` donde la posición 1 es el tamaño, la 2 el modo+tipo, la 3 la suma de verificación, la 5 el usuario y la 6 el grupo. `rpm -Va` usa `SM5DLUGTP`: `M` = modo, `U` = usuario, `G` = grupo. Un `.M....G..` sobre `/usr/bin/ping` es exactamente la migración de setuid a capabilities y es esperado; una `M` sobre cualquier cosa bajo `/usr/bin` que no hayas migrado, no lo es.

### 10.7 Un script de diagnóstico reutilizable

`/usr/local/sbin/whycant`:

```bash
#!/usr/bin/env bash
# whycant USER PATH [r|w|x] -- explain why USER cannot access PATH
set -euo pipefail

user="${1:?usage: whycant USER PATH [r|w|x]}"
target="${2:?usage: whycant USER PATH [r|w|x]}"
want="${3:-r}"

echo "== identity =="
id "$user"

echo
echo "== path traversal =="
namei -l "$target" 2>&1 || true

echo
echo "== leaf metadata =="
stat -c 'mode=%a (%A)  owner=%U:%G  inode=%i  links=%h  type=%F' "$target" 2>&1 || true

echo
echo "== ACLs =="
getfacl -p "$target" 2>/dev/null || echo "(no ACL support or path unreadable)"

echo
echo "== extended attributes =="
lsattr -d "$target" 2>/dev/null || echo "(not supported on this fs)"
getfattr -d -m - "$target" 2>/dev/null || true

echo
echo "== mount =="
findmnt -no TARGET,SOURCE,FSTYPE,OPTIONS -T "$target"

echo
echo "== effective access test as $user =="
if sudo -u "$user" test "-$want" "$target"; then
  echo "RESULT: '$want' IS permitted for $user"
else
  echo "RESULT: '$want' is DENIED for $user"
fi

echo
echo "== recent LSM denials =="
if command -v ausearch >/dev/null 2>&1; then
  sudo ausearch -m AVC -ts recent 2>/dev/null | tail -20 || echo "(none)"
else
  sudo dmesg 2>/dev/null | grep -iE 'apparmor|avc: denied' | tail -10 || echo "(none)"
fi
```

```console
$ sudo install -m 0750 -o root -g root whycant /usr/local/sbin/whycant
$ sudo /usr/local/sbin/whycant analyst-01 /srv/data/reports/q3.csv r
== identity ==
uid=1600(analyst-01) gid=1600(analyst-01) groups=1600(analyst-01),1501(analysts)

== path traversal ==
f: /srv/data/reports/q3.csv
 dr-xr-xr-x root    root    /
 drwxr-xr-x root    root    srv
 drwxr-x--x root    data    data
 drwxrws--- svc-etl data    reports
 -rw-rw-r-- svc-etl data    q3.csv

== leaf metadata ==
mode=664 (-rw-rw-r--)  owner=svc-etl:data  inode=1180231  links=1  type=regular file
...
== effective access test as analyst-01 ==
RESULT: 'r' is DENIED for analyst-01
```

El bloque de travesía lo responde: `/srv/data/reports` es `drwxrws---` con grupo `data`, y `analyst-01` está en `analysts`, no en `data`. El arreglo correcto es una ACL sobre el *directorio*, no un `chmod o+r` sobre el archivo.

```console
$ sudo setfacl -m g:analysts:rx -m d:g:analysts:rx /srv/data/reports
$ sudo /usr/local/sbin/whycant analyst-01 /srv/data/reports/q3.csv r | tail -2
== effective access test as analyst-01 ==
RESULT: 'r' IS permitted for analyst-01
```

---

## 11. Catálogo de fallas — del síntoma a la causa raíz

| Síntoma | Causa raíz probable | Comando de confirmación | Arreglo |
|---|---|---|---|
| `Permission denied` sobre un archivo cuyo modo es `0666` | Un directorio padre carece de `x` para el principal | `namei -l <path>` | `chmod o+x` (o ACL) sobre el padre que bloquea |
| Un binario setuid corre sin privilegios tras el despliegue | El `chown` corrió **después** del `chmod` | `stat -c %a <bin>` muestra `755` y no `4755` | Usar `install -o -g -m`, o reordenar |
| `chmod g+s` devuelve 0 y el bit no queda puesto | Quien llama no está en el grupo del archivo, sin `CAP_FSETID` | `stat -c %a` después de la llamada | `chgrp` primero, o correr con privilegios |
| La `umask 077` endurecida no tiene efecto | El directorio padre tiene una **ACL por defecto** | `getfacl -p <dir>` muestra líneas `default:` | Corregir la ACL por defecto; la umask queda anulada por diseño |
| Los archivos nuevos en un directorio compartido tienen el grupo equivocado | El directorio no es setgid | `ls -ld` no muestra `s` en la tríada de grupo | `chmod g+s <dir>` y volver a hacer `chgrp` de los existentes |
| Los archivos nuevos en un directorio compartido tienen el grupo correcto pero `0644` | La umask es `022` | `grep Umask /proc/<pid>/status` | `UMask=0007` en la unidad / `umask 007` en el wrapper |
| Se agregó el usuario a un grupo y sigue denegado | Las credenciales de la sesión existente están congeladas | `id` y `id <user>` no coinciden | Volver a loguearse, `exec sg <grp> $SHELL`, o reiniciar el servicio |
| El acceso funciona en algunos clientes NFS y en otros no | Más de 16 grupos suplementarios, truncamiento de `AUTH_SYS` | `id <user> \| tr ',' '\n' \| wc -l` | `RPCMOUNTDOPTS="--manage-gids"` en el servidor |
| `rm` falla con `Operation not permitted` en un directorio escribible | Sticky bit, y no sos el propietario del archivo | `ls -ld <dir>` muestra `t` | Borrar como propietario del archivo, o como root |
| `Operation not permitted` estilo `chattr` incluso para root | Atributo immutable | `lsattr <file>` muestra `i` | `chattr -i <file>` |
| `Text file busy` al reemplazar un binario | El binario se está ejecutando | `fuser -v <path>` | `mv` el nuevo a su lugar (el rename es atómico), luego reiniciar |
| Pod de K8s en `CrashLoopBackOff`, `EACCES` sobre el volumen | Falta `fsGroup`, o el driver CSI lo ignora | `kubectl exec -- ls -ldn /data` | Agregar `fsGroup`, o un `initContainer` que corra `chown` |
| Picos de latencia al arrancar el pod sobre un PVC grande | Recorrido recursivo de `fsGroupChangePolicy: Always` | Tiempos de los eventos en `kubectl describe pod` | `fsGroupChangePolicy: OnRootMismatch` |
| Un archivo de secret ilegible para un contenedor no-root | `defaultMode: 400` escrito como decimal, o sin `fsGroup` | `kubectl exec -- stat -c %a <file>` muestra `620` | Escribir `0400` con el cero inicial |
| Un árbol perdió todas sus ACLs después de una restauración | `cp`/`tar`/`rsync` sin flags de ACL | `getfacl -R` en origen vs destino | `rsync -aAX`, `tar --acls --xattrs` |
| `execve` falla con `EACCES` aunque `x` esté puesto | Opción de montaje `noexec` | `findmnt -no OPTIONS -T <path>` | Remontar, o reubicar el binario |

---

## 12. Referencia rápida y ejercicios de nivel examen

### 12.1 Tabla de conversión

| Octal | Simbólico | Común en |
|---|---|---|
| `0400` | `-r--------` | Secrets de Kubernetes, claves privadas leídas una vez |
| `0600` | `-rw-------` | `~/.ssh/id_ed25519`, `/etc/shadow` (RHEL) |
| `0640` | `-rw-r-----` | `/etc/shadow` (Debian, grupo `shadow`), configuración de servicio |
| `0644` | `-rw-r--r--` | `/etc/passwd`, datos legibles en general |
| `0700` | `drwx------` | `~/.ssh`, `/root` |
| `0711` | `drwx--x--x` | No listable pero transitable |
| `0750` | `drwxr-x---` | Datos de servicio legibles por un grupo de ops |
| `0755` | `drwxr-xr-x` | `/usr/bin`, directorios estándar |
| `1777` | `drwxrwxrwt` | `/tmp`, `/var/tmp` |
| `2770` | `drwxrws---` | Directorio de grupo compartido |
| `2755` | `drwxr-sr-x` | Directorio de grupo compartido y legible por todos |
| `4755` | `-rwsr-xr-x` | `/usr/bin/passwd`, `/usr/bin/sudo` |
| `2755` (archivo) | `-rwxr-sr-x` | `/usr/bin/wall`, `/usr/bin/crontab` |
| `6755` | `-rwsr-sr-x` | `/usr/bin/at` |

### 12.2 Ejercicios — resolvelos sin shell, después verificá

1. Está vigente `umask 026`. `touch a; mkdir b`. ¿Modos?
   → `a` = `0666 & ~0026` = `0640`; `b` = `0777 & ~0026` = `0751`.
2. `/data` es `drwxrws---  root data`. `alice` (en `data`, umask `022`) ejecuta `mkdir /data/x`. ¿Propietario, grupo y modo de `x`?
   → `alice:data`, modo `2755` — el grupo se hereda **y** el bit setgid se propaga al nuevo directorio.
3. Un archivo es `-rwsr-sr-x root root`. `root` ejecuta `chown daemon file`. ¿Nuevo modo?
   → `0755`. Ambos bits especiales se borran, incluso para root, desde Linux 2.2.13.
4. `chmod 755 /shared` sobre un directorio que era `2775`. ¿Qué se rompió?
   → El bit setgid. El octal de tres dígitos es absoluto sobre los 12 bits y pone en cero la tríada especial. Usá `chmod 2755` o `chmod g+s`.
5. `-r--rw---- alice devs`. `alice` está en `devs`. ¿Puede escribir?
   → No. Coincide primero con la clase **propietario**; la tríada de grupo nunca se consulta.
6. Convertí `u=rwx,g=rx,o=` a una umask octal.
   → Conservás `750`; la umask es el complemento del valor por defecto del *archivo* en el sentido de lo que se quita: `umask 027`.
7. ¿Qué comando pone el grupo `devs` en `file` sin tocar al propietario? Nombrá dos.
   → `chgrp devs file` y `chown :devs file`.
8. `/usr/local/bin/deploy.sh` es `-rwsr-xr-x root root`. ¿Corre como root?
   → No. Linux ignora setuid en scripts con `#!`. Reescribilo como binario compilado, una regla de `sudo`, o una file capability.

### 12.3 Invariantes de una línea que vale la pena memorizar

```
umask only clears bits; chmod is never umask-filtered (except a class-less +x).
chown/chgrp clear setuid and setgid — always chown before chmod.
Three-digit octal chmod clears the special bits. Four-digit or symbolic preserves intent.
On a directory: r = list names, x = use names, w = change the list (needs x).
Access class is chosen once — owner, then group, then other. No fallthrough.
setgid on a directory fixes the GROUP of new files; the umask fixes their MODE.
Sticky restricts deletion; it does not restrict writing to existing files.
A default ACL on the parent makes the umask irrelevant.
Group membership is applied at process creation, not at usermod time.
```

---

## Referencias

- LPI — Objetivos del examen 101 (v5.0), Tema 104.5: https://www.lpi.org/our-certifications/exam-101-objectives/
- LPI — Objetivos del examen 102 (v5.0): https://www.lpi.org/our-certifications/exam-102-objectives/
- `chmod(1)` — manual de GNU coreutils: https://www.gnu.org/software/coreutils/manual/html_node/chmod-invocation.html
- `chown(1)` — manual de GNU coreutils: https://www.gnu.org/software/coreutils/manual/html_node/chown-invocation.html
- `chgrp(1)` — manual de GNU coreutils: https://www.gnu.org/software/coreutils/manual/html_node/chgrp-invocation.html
- GNU coreutils — Permisos de archivos, modos simbólicos y numéricos, umask: https://www.gnu.org/software/coreutils/manual/html_node/File-permissions.html
- `chmod(2)` — man-pages de Linux (borrado de setgid, `CAP_FSETID`): https://man7.org/linux/man-pages/man2/chmod.2.html
- `chown(2)` — man-pages de Linux (semántica de borrado de setuid/setgid): https://man7.org/linux/man-pages/man2/chown.2.html
- `umask(2)` — man-pages de Linux: https://man7.org/linux/man-pages/man2/umask.2.html
- `stat(2)` — man-pages de Linux (`st_mode`, `S_ISUID`, `S_ISGID`, `S_ISVTX`): https://man7.org/linux/man-pages/man2/stat.2.html
- `open(2)` — man-pages de Linux (interacción de modo y umask, excepción de la ACL por defecto): https://man7.org/linux/man-pages/man2/open.2.html
- `inode(7)` — man-pages de Linux (referencia de bits de modo): https://man7.org/linux/man-pages/man7/inode.7.html
- `path_resolution(7)` — man-pages de Linux (travesía y permiso de búsqueda): https://man7.org/linux/man-pages/man7/path_resolution.7.html
- `capabilities(7)` — man-pages de Linux (`CAP_DAC_OVERRIDE`, `CAP_FOWNER`, `CAP_CHOWN`, `CAP_FSETID`): https://man7.org/linux/man-pages/man7/capabilities.7.html
- `credentials(7)` — man-pages de Linux (UID/GID/grupos suplementarios): https://man7.org/linux/man-pages/man7/credentials.7.html
- `acl(5)` — man-pages de Linux (ACLs POSIX, máscara, ACLs por defecto): https://man7.org/linux/man-pages/man5/acl.5.html
- `setfacl(1)` / `getfacl(1)` — man-pages de Linux: https://man7.org/linux/man-pages/man1/setfacl.1.html
- `find(1)` — manual de GNU findutils (`-perm`, `-nouser`, `-printf`): https://www.gnu.org/software/findutils/manual/html_mono/find.html
- `namei(1)` — util-linux: https://man7.org/linux/man-pages/man1/namei.1.html
- `setpriv(1)` — util-linux: https://man7.org/linux/man-pages/man1/setpriv.1.html
- `login.defs(5)` — shadow-utils (`UMASK`, `HOME_MODE`, `USERGROUPS_ENAB`): https://man7.org/linux/man-pages/man5/login.defs.5.html
- `pam_umask(8)` — Linux-PAM: https://man7.org/linux/man-pages/man8/pam_umask.8.html
- `systemd.exec(5)` — `UMask=`, `StateDirectoryMode=`, `RestrictSUIDSGID=`: https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
- `tmpfiles.d(5)` — modos y propiedad de rutas declarativos: https://www.freedesktop.org/software/systemd/man/latest/tmpfiles.d.html
- POSIX.1-2024 — `chmod`: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/chmod.html
- POSIX.1-2024 — `umask`: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/umask.html
- Filesystem Hierarchy Standard 3.0 (modos esperados para `/tmp`, `/var/tmp`, `/srv`): https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html
- Kubernetes — Configurar un Security Context para un Pod o Contenedor (`runAsUser`, `fsGroup`, `fsGroupChangePolicy`): https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- Kubernetes — Secrets, `defaultMode` y semántica de permisos: https://kubernetes.io/docs/concepts/configuration/secret/
- Docker — Referencia del Dockerfile, `COPY --chown` / `--chmod`: https://docs.docker.com/reference/dockerfile/
- Ansible — módulo `ansible.builtin.file` (entrecomillado de mode): https://docs.ansible.com/ansible/latest/collections/ansible/builtin/file_module.html
- Ansible — módulo `ansible.posix.acl`: https://docs.ansible.com/ansible/latest/collections/ansible/posix/acl_module.html