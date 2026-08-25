# 333.1 — Control de Acceso Discrecional

**LPIC-3 303 (Examen 303-300, v3.0.0) — Tema 333: Control de Acceso**
Perfil: Principal Platform Architect / Senior SRE. Peso: 5.0.

---

## 1. El problema arquitectónico

Cualquier otra capa de control de acceso que despliegues — SELinux, AppArmor, seccomp, Kubernetes PSA, OPA/Gatekeeper — es *condicional*. Puede deshabilitarse con un flag de arranque, estar ausente de una imagen de contenedor, no estar soportada por un filesystem, o simplemente no haber sido compilada. DAC es la única capa que está **siempre presente, en cada objeto del VFS, en cada kernel, dentro de cada contenedor, a través de cada bind mount y de cada export NFS**. Es el sustrato. Si tu modelo DAC está mal, el resto es decoración sobre un agujero.

DAC es además la capa que falla *silenciosa y asimétricamente*:

- **Demasiado restrictivo** y obtenés un `EACCES` ruidoso e inmediato, una guardia despertada, y un arreglo en minutos.
- **Demasiado permisivo** y no obtenés nada. Ninguna línea de log, ninguna alerta, ningún request fallido. La exposición vive hasta que una auditoría, una brecha o un escaneo de compliance la encuentra — típicamente años después.

Esa asimetría es la razón por la que el DAC en producción deriva monótonamente hacia `777`. El ingeniero de guardia a las 03:00 tiene un deploy roto, un `Permission denied`, y un fuerte incentivo para hacer desaparecer el error. `chmod -R 777` siempre funciona. Es la causa raíz más común detrás de los post-mortems del tipo "el artifact store era escribible por todo el mundo".

### 1.1 El escenario canónico de producción usado a lo largo de este tema

Un host multi-tenant de build y artefactos, `build-01`, con cuatro principals que deben compartir el filesystem sin confiar entre sí:

| Principal | Identidad | Debe poder | **No** debe poder |
|---|---|---|---|
| CI runner | `ci` (uid 1500), grupo `ci-runners` (gid 1500) | Crear directorios de build, escribir artefactos | Leer los insumos de build de otro tenant; modificar artefactos publicados |
| Release bot | `release` (uid 1501), grupo `deployers` (gid 1200) | Leer todo artefacto, publicar los firmados | Borrar la evidencia de un build completado |
| Log shipper | `promtail` (uid 1502) | Leer `/var/log/app/*.log`, propiedad de otros servicios | Escribir cualquier cosa bajo `/var/log` |
| Auditores | grupo `sec-audit` (gid 1300) | Leer todo, para siempre | Escribir, borrar u ocultar cualquier cosa |

Notá la forma del problema: **tres observadores de solo lectura con alcances distintos, un escritor, y un requisito de inmutabilidad.** La tríada clásica de Unix (`owner`, `group`, `other`) te da *exactamente un* grupo nombrado. No puede expresar esto. Necesitás ACLs, y necesitás entender con precisión cómo interactúan las ACLs con los bits de modo, porque esa interacción es donde los sistemas de producción se rompen.

### 1.2 El límite definicional de DAC

"Discrecional" es una afirmación técnica precisa, no un adjetivo de marketing: **el dueño de un objeto tiene la discreción de otorgar acceso a él.** Las consecuencias se siguen directamente:

- Un usuario que puede leer un secreto puede copiarlo a una ubicación legible por todo el mundo. DAC no puede detener el flujo de información, solo el acceso inicial.
- `chmod` es un derecho de la propiedad. El administrador del sistema no puede prohibirle centralmente a un dueño que afloje sus propios archivos — solo detectarlo después.
- Esta es la brecha del **confused deputy** y del **flujo de información** que el Control de Acceso Obligatorio (tema 333.2) existe para cerrar. MAC no es un reemplazo de DAC; es una *segunda* verificación aplicada *después* de que DAC pasa. **Ambos deben permitir.** Un archivo denegado por los bits de modo está denegado sin importar una política SELinux permisiva, y viceversa.

---

## 2. Dónde ocurre DAC realmente: el camino de decisión del kernel

No podés depurar permisos solo con `ls -l`. Necesitás el algoritmo.

### 2.1 El `st_mode` del inode

Cada objeto del VFS lleva un `st_mode` de 16 bits en su inode:

```
 15 14 13 12 | 11 10  9 | 8  7  6 | 5  4  3 | 2  1  0
 [file type] | su sg st | r  w  x | r  w  x | r  w  x
             |          |  owner  |  group  |  other
```

- Bits 15–12: tipo de archivo (`S_IFREG`, `S_IFDIR`, `S_IFLNK`, `S_IFCHR`, `S_IFBLK`, `S_IFIFO`, `S_IFSOCK`). **No modificable** después de la creación.
- Bits 11–9: `S_ISUID` (04000), `S_ISGID` (02000), `S_ISVTX` (01000) — los bits "especiales" o "sticky/set-id".
- Bits 8–0: los nueve bits de permiso familiares.

Por eso `chmod 755` y `chmod 0755` son idénticos, y por eso `chmod 4755` activa setuid — el dígito inicial son los bits 11–9.

```
$ stat -c '%n  type=%F  mode=%a (%A)  uid=%u(%U)  gid=%g(%G)' /usr/bin/passwd /tmp /etc/shadow
/usr/bin/passwd  type=regular file  mode=4755 (-rwsr-xr-x)  uid=0(root)  gid=0(root)
/tmp  type=directory  mode=1777 (drwxrwxrwt)  uid=0(root)  gid=0(root)
/etc/shadow  type=regular file  mode=640 (-rw-r-----)  uid=0(root)  gid=42(shadow)
```

### 2.2 El algoritmo: gana la primera coincidencia, y **no** acumula

Este es el mecanismo peor entendido de los permisos Unix. El kernel (`fs/namei.c:generic_permission()` → `fs/posix_acl.c:posix_acl_permission()`) evalúa las clases **en orden estricto y se detiene en la primera aplicable**:

```
1. if (fsuid == inode.i_uid)                     → use OWNER bits.        STOP.
2. if (an ACL_USER entry matches fsuid)          → use that entry & mask. STOP.
3. if (fsgid or any supplementary gid matches
       the owning group, or an ACL_GROUP entry)  → use the union of all
                                                    matching group-class
                                                    entries, & mask.      STOP.
4. otherwise                                     → use OTHER bits.        STOP.
```

Solo el paso 3 une múltiples entradas. Los pasos 1, 2 y 4 son terminales y exclusivos.

**Demostración — el archivo "paradoja".** El dueño está denegado mientras todos los demás están permitidos:

```
$ id
uid=1000(sre) gid=1000(sre) groups=1000(sre),27(sudo)

$ touch /tmp/paradox && chmod 0067 /tmp/paradox
$ ls -l /tmp/paradox
----rw-rwx 1 sre sre 0 Aug 24 09:41 /tmp/paradox

$ cat /tmp/paradox
cat: /tmp/paradox: Permission denied

$ sudo -u nobody cat /tmp/paradox     # 'nobody' is not sre, not in group sre → OTHER = rwx
$ echo $?
0
```

El dueño coincidió en el paso 1, obtuvo `---`, y la evaluación se detuvo. El `rw-` del grupo y el `rwx` de other nunca fueron consultados. Cualquier herramienta de monitoreo o compliance que calcule el "acceso efectivo" haciendo OR de las tres tríadas reporta este archivo como legible por `sre`. No lo es.

**Corolario para el examen y para producción:** endurecer `other` nunca endurece el acceso para el dueño o el grupo; aflojar `other` nunca afloja el acceso para el dueño. El modo `0640` y el modo `0644` son idénticos *para el dueño*.

### 2.3 Los bypasses por capabilities

Root no es especial; las **capabilities** lo son. En un kernel con file capabilities y user namespaces, "root" es la forma abreviada de "posee la capability relevante en el user namespace actual, y el dueño del inode está mapeado dentro de él" (`capable_wrt_inode_uidgid()`).

| Capability | Evade |
|---|---|
| `CAP_DAC_OVERRIDE` | Todas las verificaciones de lectura/escritura/ejecución — **excepto** ejecución sobre un archivo regular *sin* ningún bit de ejecución activado |
| `CAP_DAC_READ_SEARCH` | Lectura en archivos, lectura+búsqueda en directorios. Sin bypass de escritura |
| `CAP_FOWNER` | Verificaciones que requieren `fsuid == i_uid`: `chmod`, `utimes`, borrado en directorio sticky, escribir xattrs `user.*` en el archivo de otro |
| `CAP_FSETID` | Evita que el kernel limpie setuid/setgid en `write()` y `chown()` |
| `CAP_CHOWN` | `chown`/`chgrp` arbitrarios |
| `CAP_LINUX_IMMUTABLE` | Poner/quitar los atributos `i` (immutable) y `a` (append-only) |

La excepción de `CAP_DAC_OVERRIDE` es real y agarra desprevenida a la gente:

```
# chmod 000 /usr/local/bin/healthcheck
# ls -l /usr/local/bin/healthcheck
---------- 1 root root 812 Aug 24 09:52 /usr/local/bin/healthcheck

# cat /usr/local/bin/healthcheck          # read: allowed, CAP_DAC_OVERRIDE applies
#!/bin/sh
...

# /usr/local/bin/healthcheck              # execute: DENIED even for root
-bash: /usr/local/bin/healthcheck: Permission denied

# chmod 100 /usr/local/bin/healthcheck    # one x bit anywhere is enough for root
# /usr/local/bin/healthcheck
ok
```

La regla del kernel: `CAP_DAC_OVERRIDE` otorga `MAY_EXEC` sobre un archivo regular solo si `i_mode & S_IXUGO` es distinto de cero. Los directorios siempre son atravesables con la capability.

### 2.4 `EACCES` vs `EPERM` — la señal de triage más rápida que tenés

Estos dos errnos se imprimen ambos como "Permission denied" / "Operation not permitted" legibles por humanos, y significan **cosas completamente distintas**:

| errno | `strerror` | Significado | Causa típica |
|---|---|---|---|
| `EACCES` (13) | Permission denied | Los **bits de modo / la ACL** de este inode o de un componente del path denegaron la operación | Modo incorrecto, grupo incorrecto, falta `x` en un directorio padre |
| `EPERM` (1) | Operation not permitted | La operación es **privilegiada** o está estructuralmente prohibida, sin importar el modo | `chown` por un no-dueño, archivo con `chattr +i`, capability faltante, montaje `nosuid`, denegación de un LSM |

`chmod 777` arregla `EACCES`. Nunca arregla `EPERM`. Si ves `EPERM`, dejá de mirar permisos y empezá a mirar atributos, capabilities, opciones de montaje y política MAC.

```
$ strace -f -e trace=openat,write,chown -o /tmp/t.log ./app ; grep -E 'EACCES|EPERM' /tmp/t.log
openat(AT_FDCWD, "/srv/deploy/artifacts/build-4711/manifest.json", O_WRONLY|O_CREAT|O_TRUNC, 0666) = -1 EACCES (Permission denied)
chown("/srv/deploy/artifacts/build-4711", 1501, 1200) = -1 EPERM (Operation not permitted)
```

Dos fallas, dos causas raíz completamente distintas, en un solo trace.

---

## 3. Propiedad: `chown`, `chgrp`, y los bits que se esfuman

### 3.1 Semántica

```
$ chown release:deployers /srv/deploy/artifacts/manifest.json   # user and group
$ chown release: /srv/deploy/artifacts/manifest.json            # user, group→user's login group
$ chown :deployers /srv/deploy/artifacts/manifest.json          # group only (== chgrp)
$ chown --reference=/srv/deploy/.template /srv/deploy/new       # copy ownership from another inode
$ chown -R --from=1500:1500 1501:1200 /srv/deploy/artifacts     # conditional: only change matching inodes
```

`--from=OLDUSER:OLDGROUP` es el idioma recursivo seguro durante una migración de uid: es idempotente y no tocará inodes que ya lleven la propiedad destino o que pertenezcan a un tercero.

**Symlinks.** `chown` desreferencia por defecto. `-h` / `--no-dereference` actúa sobre el enlace mismo. Con `-R`, el default es `-P` (no atravesar symlinks); `-L` sigue cada symlink encontrado (peligroso — un symlink a `/` reescribirá tu sistema), `-H` sigue solo los argumentos de la línea de comandos. No existe `lchmod(2)` en Linux: **los modos de los symlinks son siempre `lrwxrwxrwx` y carecen de sentido**; la travesía está gobernada enteramente por el destino y por los directorios del path.

### 3.2 Quién puede hacer `chown`

En Linux, **solo `CAP_CHOWN` puede cambiar el dueño de un archivo** — no existe el "give-away chown" como en algunos Unixes tradicionales. Un usuario sin privilegios puede cambiar el *grupo* a cualquier grupo del que sea miembro, siempre que sea dueño del archivo.

```
$ id -Gn
sre sudo deployers

$ chgrp deployers /home/sre/report.txt         # member of deployers → OK
$ chgrp sec-audit /home/sre/report.txt         # not a member
chgrp: changing group of '/home/sre/report.txt': Operation not permitted   ← EPERM
```

### 3.3 Los bits set-id se limpian a tus espaldas

Esto es una característica de seguridad y una fuente frecuente de incidentes del tipo "ayer funcionaba":

- **`chown`/`chgrp` limpia `S_ISUID` y `S_ISGID`** cuando lo ejecuta un proceso sin `CAP_FSETID`. Desde Linux 2.2.13, **root es tratado igual que todos los demás en esto** — un `chown` desde root también los limpia. Excepción: si el archivo *no* es ejecutable por el grupo, `S_ISGID` tenía un significado histórico distinto (mandatory locking) y no se limpia.
- **`write(2)` sobre un archivo set-id los limpia**, de nuevo salvo que el escritor posea `CAP_FSETID`.
- **`chmod g+s` por un usuario sin privilegios se descarta silenciosamente** si el grupo del archivo no está en el conjunto de grupos del llamante.

```
# ls -l /usr/local/bin/spool-flush
-rwsr-xr-x 1 root root 22160 Aug 24 10:01 /usr/local/bin/spool-flush

# chown root:opsteam /usr/local/bin/spool-flush
# ls -l /usr/local/bin/spool-flush
-rwxr-xr-x 1 root opsteam 22160 Aug 24 10:01 /usr/local/bin/spool-flush   ← the 's' is gone
```

**Regla operativa:** en cualquier paso de empaquetado, Ansible o Dockerfile, el `chown` debe ir **antes** del `chmod`, nunca después. La mitad de los tickets de "el helper setuid dejó de funcionar después de la corrida de gestión de configuración" son este bug de ordenamiento.

---

## 4. Los nueve bits, con la semántica de directorios enunciada exactamente

Para **archivos regulares** los significados son obvios. Para **directorios** no lo son, y la semántica de directorios es donde viven los diseños reales de control de acceso.

| Bit | En un archivo regular | En un **directorio** |
|---|---|---|
| `r` | Leer el contenido | **Listar los nombres** que contiene (`ls`, `readdir`) — solo nombres, sin metadatos |
| `w` | Modificar el contenido | **Crear, borrar y renombrar entradas** — *requiere también `x`*. Este es un permiso sobre el *directorio*, no sobre los archivos que contiene |
| `x` | Ejecutar (`execve`) | **Atravesar / resolver** un nombre dentro de él (`stat`, `open`, `cd`). Requerido en **cada** componente de un path |

Cuatro consecuencias que guían el diseño en producción:

1. **`w` sobre un directorio te permite borrar un archivo que no podés leer y que no te pertenece.** Los permisos del archivo son irrelevantes para `unlink()`. Esto es exactamente lo que el bit sticky existe para restringir.
2. **`--x` (modo `0111`, o `0711` para el dueño) es el patrón "acceso si conocés el nombre".** No podés enumerar, pero podés atravesar. Así debería configurarse `/home` en un host compartido, y así se expone una raíz de artefactos por tenant a un lector compartido sin filtrar la lista de tenants.
3. **`r--` sin `x` es casi inútil.** Obtenés nombres y nada más — `ls -l` devuelve `?` en cada campo:

```
$ ls -ld /srv/deploy/incoming
dr--r--r-- 2 ci ci-runners 4096 Aug 24 10:07 /srv/deploy/incoming

$ ls -l /srv/deploy/incoming
ls: cannot access '/srv/deploy/incoming/build-4711.tar.zst': Permission denied
total 0
-????????? ? ? ? ?            ? build-4711.tar.zst
```

4. **La falta de `x` en un directorio *padre* deniega todo lo que está debajo, por permisiva que sea la hoja.** Esta es la causa número uno de los tickets "¡pero el archivo es 0644!", y la razón por la que `namei -mo` (§12.1) es el primer comando que deberías ejecutar.

### 4.1 Modo simbólico, y el único operador que deberías estar usando

```
$ chmod u=rwX,g=rX,o= -R /srv/deploy/artifacts
```

`X` (mayúscula) significa "activar ejecución **solo si** el destino es un directorio, o ya tiene ejecución activada para al menos una clase". Este es el idioma recursivo correcto: pone `x` en los directorios para que sigan siendo atravesables, sin marcar cada `.json` y `.tar.zst` como ejecutable. `chmod -R 755` es casi siempre un bug por la misma razón.

La alternativa, cuando necesitás modos distintos para archivos y directorios:

```
$ find /srv/deploy/artifacts -type d -exec chmod 2750 {} +
$ find /srv/deploy/artifacts -type f -exec chmod 0640 {} +
```

Otras formas simbólicas que vale la pena conocer: `chmod a-w`, `chmod g=u` (copiar los bits del dueño al grupo), `chmod --reference=template file`, `chmod =rwx,g+s`.

---

## 5. Los tres bits especiales

### 5.1 `S_ISUID` (4000) — setuid

Sobre un **archivo regular ejecutable**: `execve()` fija el UID *efectivo* y el *saved-set* del nuevo proceso al del dueño del archivo. Este es el único mecanismo del Unix clásico por el cual un usuario sin privilegios gana privilegio, y es la razón por la que `/usr/bin/passwd` puede escribir `/etc/shadow`.

Hechos críticos:

- **Setuid se ignora en shell scripts en Linux.** El kernel se niega a honrar los bits set-id en archivos manejados por un intérprete `#!`, porque la ventana entre `execve()` y la apertura del script por el intérprete es explotable. Un archivo `#!/bin/sh` con modo `4755` corre con tu propio UID, siempre. Esto no es configurable.
- **Setuid no tiene sentido en directorios en Linux.** (Algunos Unixes tradicionales lo usaban para herencia de propiedad; Linux no.)
- **La opción de montaje `nosuid` lo mata.** Un binario setuid en un filesystem `nosuid` se ejecuta sin cambio de privilegio y, para un montaje `nosuid`, `execve` de un archivo set-id descarta silenciosamente los bits.
- **`no_new_privs` lo mata.** `prctl(PR_SET_NO_NEW_PRIVS, 1)` es irreversible y se hereda a través de `execve`. Cada bit `setuid` y cada file capability queda neutralizada para ese árbol de procesos. Esto es exactamente lo que fija `allowPrivilegeEscalation: false` en un `securityContext` de Kubernetes, y lo que fija `NoNewPrivileges=yes` en una unit de systemd.

Visualización: `s` en la posición de ejecución del dueño; **`S` si el bit `x` subyacente está ausente** — un archivo setuid que no es ejecutable, lo cual siempre es un error.

```
$ ls -l /usr/bin/sudo /usr/bin/chsh
-rwsr-xr-x 1 root root 277936 Jun 11 12:19 /usr/bin/sudo
-rwsr-xr-x 1 root root  72040 Mar 23  2025 /usr/bin/chsh
```

### 5.2 `S_ISGID` (2000) — setgid

Dos significados completamente inconexos, distinguidos por el tipo de archivo:

**Sobre un archivo ejecutable:** `execve()` fija el GID efectivo al grupo del archivo. Aplican las mismas salvedades de `nosuid`/`no_new_privs`.

**Sobre un directorio — este es el importante.** Cambia el directorio de la semántica de herencia de grupo de System V a la **semántica BSD**:

- Un archivo nuevo creado dentro hereda el grupo **del directorio**, no el GID efectivo del creador.
- Un **subdirectorio** nuevo hereda el grupo **y el propio bit setgid**, así que la propiedad se propaga automáticamente por todo el árbol.

Esta es la base de todo diseño de workspace compartido en Unix:

```
# groupadd -g 1200 deployers
# install -d -o root -g deployers -m 2775 /srv/deploy/artifacts
# ls -ld /srv/deploy/artifacts
drwxrwsr-x 2 root deployers 4096 Aug 24 10:14 /srv/deploy/artifacts

# sudo -u ci sh -c 'umask 002; mkdir /srv/deploy/artifacts/build-4711; \
                    touch /srv/deploy/artifacts/build-4711/manifest.json'

# ls -lR /srv/deploy/artifacts
/srv/deploy/artifacts:
total 4
drwxrwsr-x 2 ci deployers 4096 Aug 24 10:15 build-4711     ← group inherited, s propagated

/srv/deploy/artifacts/build-4711:
total 0
-rw-rw-r-- 1 ci deployers 0 Aug 24 10:15 manifest.json      ← group inherited
```

Sin el bit setgid, `manifest.json` habría sido `ci:ci-runners` y el release bot en `deployers` no habría podido leerlo.

**Notá con cuidado lo que setgid *no* hace:** controla el **grupo**, no el **modo**. El `rw-rw-r--` de arriba vino del `umask 002` del proceso creador, no del directorio. Si `ci` corre con `umask 022`, el archivo es `rw-r--r--` y el grupo pierde el acceso de escritura pese a la configuración setgid perfecta. **Setgid y un umask acorde son un par; desplegar uno sin el otro es la configuración de directorio compartido a medio hacer más común.** La única forma de hacer que la herencia sea independiente del umask del escritor es una **default ACL** (§7.3).

Visualización: `s` en la ejecución de grupo; `S` si falta la `x` de grupo. Sobre un *archivo*, `-rw-r-Sr--` señalaba históricamente **mandatory locking** — una funcionalidad removida del kernel en Linux 5.15. En un kernel moderno es inerte, pero `chown` sigue absteniéndose de limpiarlo en esa configuración.

### 5.3 `S_ISVTX` (1000) — el bit sticky / flag de borrado restringido

Sobre un **directorio**, restringe `unlink()` y `rename()` de las entradas: un usuario puede eliminar o renombrar una entrada solo si es dueño de la entrada, dueño del directorio, o posee `CAP_FOWNER` — *incluso cuando tiene permiso de escritura sobre el directorio*. Sobre un **archivo** es el vestigial bit "save text image" y **no tiene efecto en Linux**.

```
$ ls -ld /tmp /var/tmp /dev/shm
drwxrwxrwt 18 root root  520 Aug 24 10:20 /tmp
drwxrwxrwt  6 root root 4096 Aug 24 04:02 /var/tmp
drwxrwxrwt  2 root root   40 Aug 24 03:58 /dev/shm

$ sudo -u ci touch /tmp/ci-scratch
$ sudo -u release rm /tmp/ci-scratch
rm: cannot remove '/tmp/ci-scratch': Operation not permitted     ← EPERM, not EACCES
```

Visualización: `t` en la posición de ejecución de other; `T` si falta la `x` de other.

**El bit sticky por sí solo no es hardening suficiente para un directorio escribible por todo el mundo.** Detiene el borrado, no las clásicas carreras de symlink/hardlink. Cuatro sysctls cierran esas, y pertenecen a todo build endurecido:

```
# /etc/sysctl.d/60-fs-hardening.conf
# Do not follow symlinks in world-writable sticky dirs when the symlink owner
# differs from the directory owner and the following process.
fs.protected_symlinks = 1
# Do not allow hardlinks to files the linking user does not own and cannot read+write.
fs.protected_hardlinks = 1
# Do not allow O_CREAT open of a FIFO/regular file in a world-writable sticky dir
# owned by someone else, unless the opener owns it.
fs.protected_fifos = 2
fs.protected_regular = 2
# Restrict access to kernel pointers and dmesg while we are here.
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
```

```
# sysctl --system
* Applying /etc/sysctl.d/60-fs-hardening.conf ...
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
```

Los intentos bloqueados aterrizan en el log del kernel, lo que los hace alertables:

```
$ dmesg -T | grep -i protected
[Sun Aug 24 10:26:03 2026] non-matching-uid symlink following attempted in a sticky world-writable directory by cat (fsuid 1500 != 1502)
```

---

## 6. Modo en tiempo de creación: `umask` y de dónde viene realmente

Ni `open(2)` ni `mkdir(2)` fijan el modo que pediste. El kernel calcula:

```
final_mode = requested_mode & ~umask
```

`umask` es un **atributo por proceso**, heredado a través de `fork` y `execve`, expresado como los bits a *remover*. Se aplica solo en la creación; **no tiene efecto sobre `chmod`**, ni efecto sobre archivos que ya existen.

| `umask` | Archivos (`0666` pedido) | Directorios (`0777` pedido) | Caso de uso |
|---|---|---|---|
| `022` | `644` `-rw-r--r--` | `755` `drwxr-xr-x` | Default histórico; legible por todo el mundo |
| `002` | `664` `-rw-rw-r--` | `775` `drwxrwxr-x` | Grupos privados por usuario (UPG); escritura de grupo compartida |
| `027` | `640` `-rw-r-----` | `750` `drwxr-x---` | **La línea base correcta para un servidor.** Legible por el grupo, ciego para el mundo |
| `007` | `660` `-rw-rw----` | `770` `drwxrwx---` | UPG + grupo compartido, ciego para el mundo |
| `077` | `600` `-rw-------` | `700` `drwx------` | Secretos, material de claves, estado por usuario |

Notá que los archivos nunca obtienen `x` del umask: el userland pide `0666` para archivos de datos, así que `umask 022` da `644`, no `755`. Los compiladores e `install` piden explícitamente `0777`, y por eso los binarios salen ejecutables.

```
$ umask
0022
$ umask -S
u=rwx,g=rx,o=rx

$ ( umask 027; mkdir -p /tmp/u027/sub; : > /tmp/u027/sub/data.json ) \
    && ls -ld /tmp/u027 /tmp/u027/sub /tmp/u027/sub/data.json
drwxr-x--- 3 sre sre 4096 Aug 24 10:33 /tmp/u027
drwxr-x--- 2 sre sre 4096 Aug 24 10:33 /tmp/u027/sub
-rw-r----- 1 sre sre    0 Aug 24 10:33 /tmp/u027/sub/data.json
```

### 6.1 De dónde viene realmente el umask de un daemon

Depurar "mi servicio escribe archivos legibles por todo el mundo" requiere conocer la fuente de verdad. En orden de especificidad:

| Capa | Mecanismo | Aplica a |
|---|---|---|
| Default del kernel | `0022` en PID 1 | Todo lo no sobrescrito |
| Gestor de sistema systemd | `DefaultUMask=` en `/etc/systemd/system.conf` (default `0022`) | Todos los servicios del sistema |
| Unit de systemd | `UMask=` en `[Service]` | Solo esa unit — **autoritativo, usá esto** |
| PAM | `pam_umask.so` + `UMASK` en `/etc/login.defs` + `USERGROUPS_ENAB` | Logins interactivos, `su`, `sshd` |
| Shell | `umask` en `/etc/profile`, `~/.bashrc` | Solo shells interactivas/de login |
| Por usuario | Campo `UMASK=` en `/etc/default/useradd`, `pam_umask` basado en GECOS | Por cuenta |

**Un `umask` en `/etc/profile` no tiene absolutamente ningún efecto sobre un servicio de systemd.** Los servicios no ejecutan los scripts de profile. Este es el diagnóstico erróneo más común en esta área.

Verificá lo que un proceso *en ejecución* realmente tiene — la verdad está en `/proc`:

```
$ grep -i umask /proc/$(pidof payments-api)/status
Umask:	0027
```

`USERGROUPS_ENAB yes` en `/etc/login.defs` hace que `pam_umask` relaje un umask `022` a `002` cuando el nombre del grupo primario del usuario es igual a su nombre de usuario (User Private Groups). Por eso el mismo comando produce `664` en Debian/Ubuntu y `644` en un sistema sin UPG.

---

## 7. ACLs POSIX

### 7.1 Por qué existen, y el modelo

Los bits de modo expresan exactamente tres sujetos. Nuestro escenario de §1.1 necesita cinco. Las ACLs de POSIX 1003.1e draft 17 (el draft fue retirado; la implementación es universal en Linux) extienden el modelo con usuarios y grupos nombrados.

Una **access ACL** es un conjunto ordenado de entradas:

| Entrada | Sintaxis | Cardinalidad | Relación con los bits de modo |
|---|---|---|---|
| Dueño | `user::rwx` | Exactamente 1, obligatoria | **Es** la tríada del dueño |
| Usuario nombrado | `user:NAME:rwx` | 0..n | Adicional; sujeta a la mask |
| Grupo propietario | `group::rwx` | Exactamente 1, obligatoria | Sujeta a la mask |
| Grupo nombrado | `group:NAME:rwx` | 0..n | Adicional; sujeta a la mask |
| **Mask** | `mask::rwx` | 1 si existe alguna entrada nombrada | **Es** la tríada de grupo en `ls -l` |
| Other | `other::rwx` | Exactamente 1, obligatoria | **Es** la tríada de other |

Una ACL que contiene solo las tres entradas obligatorias es una **ACL mínima** y es exactamente equivalente a los bits de modo — no consume almacenamiento extra y `ls -l` no muestra `+`.

**La mask es todo el diseño.** Es una cota superior aplicada a *cada* entrada de la clase de grupo: todos los usuarios nombrados, todos los grupos nombrados y el grupo propietario. Permiso efectivo = entrada ∩ mask. Las entradas de dueño y de other nunca se enmascaran.

`setfacl` recalcula la mask automáticamente en cada `-m`/`-x` como la unión de la clase de grupo, salvo que pases `-n` (`--no-mask`) o especifiques una entrada `mask::` explícitamente en el mismo comando.

### 7.2 Trabajando con ACLs — el conjunto completo de comandos

```
$ getfacl /srv/deploy/artifacts
getfacl: Removing leading '/' from absolute path names
# file: srv/deploy/artifacts
# owner: root
# group: deployers
# flags: -s-
user::rwx
group::rwx
other::r-x
```

La línea `# flags:` es `setuid/setgid/sticky` — aquí `-s-` refleja el modo `2775` de §5.2.

Ahora otorgá a los cuatro principals de §1.1 lo que realmente necesitan:

```
# setfacl -m u:ci:rwx \
          -m g:deployers:r-x \
          -m u:promtail:--- \
          -m g:sec-audit:r-x \
          -m o::--- \
          /srv/deploy/artifacts

# getfacl /srv/deploy/artifacts
getfacl: Removing leading '/' from absolute path names
# file: srv/deploy/artifacts
# owner: root
# group: deployers
# flags: -s-
user::rwx
user:ci:rwx
group::rwx
group:deployers:r-x
group:sec-audit:r-x
mask::rwx
other::---

# ls -ld /srv/deploy/artifacts
drwxrws---+ 3 root deployers 4096 Aug 24 10:41 /srv/deploy/artifacts
```

El **`+`** final es la única señal que `ls -l` da de que existe una ACL. Cualquier herramienta de auditoría que parsee la salida de `ls -l` e ignore el `+` está reportando ficción.

Referencia completa de operadores:

| Comando | Efecto |
|---|---|
| `setfacl -m u:NAME:rwx F` | Modificar/agregar una entrada de usuario nombrado |
| `setfacl -m g:NAME:rX F` | Grupo nombrado; `X` = ejecución solo si es directorio o ya es ejecutable |
| `setfacl -x u:NAME F` | Remover una entrada (sin campo de permisos) |
| `setfacl -b F` | Remover **todas** las entradas extendidas → volver a una ACL mínima |
| `setfacl -k F` | Remover solo la ACL **default** |
| `setfacl -n -m ... F` | No recalcular la mask |
| `setfacl -d -m u:NAME:rX D` | Operar sobre la ACL **default** de un directorio |
| `setfacl -R -m ... D` | Recursivo |
| `setfacl --set 'u::rw,g::r,o::-' F` | Reemplazar la ACL entera (se requieren las entradas obligatorias) |
| `setfacl -M spec.acl F` | Leer las modificaciones desde un archivo (`-` para stdin) |
| `setfacl --restore=backup.acl` | Restaurar ACLs **más dueño, grupo y modo** desde un volcado de `getfacl -R` |
| `getfacl -R --absolute-names D` | Volcado recursivo apto para `--restore` |
| `getfacl -c F` | Omitir el encabezado `# file/owner/group` |
| `getfacl -e F` | Imprimir siempre el comentario `#effective:` |
| `getfacl -s F` | Saltear archivos que solo tienen una ACL mínima |
| `getfacl -t F` | Salida tabular |
| `getfacl -n F` | UIDs/GIDs numéricos — **usá esto en los backups**, los nombres no son portables |

Backup y restore, la operación que todos olvidan hasta que un restore falla:

```
# getfacl -R -n --absolute-names /srv/deploy > /var/backups/srv-deploy-2026-08-24.acl
# head -12 /var/backups/srv-deploy-2026-08-24.acl
# file: /srv/deploy
# owner: 0
# group: 0
user::rwx
group::r-x
other::r-x

# file: /srv/deploy/artifacts
# owner: 0
# group: 1200
# flags: -s-

# setfacl --restore=/var/backups/srv-deploy-2026-08-24.acl
```

### 7.3 ACLs default: herencia real, y sobrescriben el umask

Una **ACL default** existe solo en directorios, nunca se usa para decisiones de acceso, y sirve puramente como plantilla para los hijos recién creados:

- Un **archivo** nuevo obtiene una access ACL derivada de la ACL default del padre.
- Un **subdirectorio** nuevo obtiene tanto una access ACL **como una copia de la ACL default**, de modo que la política se propaga automáticamente por el árbol.

El hecho crucial, enunciado en `acl(5)` y constantemente pasado por alto: **si el directorio padre tiene una ACL default, el umask del proceso se ignora por completo.** En cambio, el argumento de modo pasado a `open(2)`/`mkdir(2)` recorta las entradas de dueño, mask y other de la ACL resultante.

```
# setfacl -d -m u::rwx,g::r-x,o::---,u:ci:rwx,g:deployers:r-x,g:sec-audit:r-x \
          /srv/deploy/artifacts

# getfacl /srv/deploy/artifacts
getfacl: Removing leading '/' from absolute path names
# file: srv/deploy/artifacts
# owner: root
# group: deployers
# flags: -s-
user::rwx
user:ci:rwx
group::rwx
group:deployers:r-x
group:sec-audit:r-x
mask::rwx
other::---
default:user::rwx
default:user:ci:rwx
default:group::r-x
default:group:deployers:r-x
default:group:sec-audit:r-x
default:mask::rwx
default:other::---

# sudo -u ci sh -c 'umask 077; mkdir /srv/deploy/artifacts/build-4712; \
                    touch /srv/deploy/artifacts/build-4712/manifest.json'

# getfacl /srv/deploy/artifacts/build-4712/manifest.json
getfacl: Removing leading '/' from absolute path names
# file: srv/deploy/artifacts/build-4712/manifest.json
# owner: ci
# group: deployers
user::rw-
user:ci:rwx			#effective:rw-
group::r-x			#effective:r--
group:deployers:r-x		#effective:r--
group:sec-audit:r-x		#effective:r--
mask::rw-
other::---
```

Leé esa salida con cuidado — es el modelo entero en una pantalla:

- El `umask 077` del escritor fue **completamente ignorado**. Bajo bits de modo solamente, el archivo habría sido `-rw-------` y todos los lectores habrían quedado rotos.
- `touch` llama a `open(..., 0666)`. El `0666` recortó la mask de `rwx` a `rw-`, y por eso cada entrada de la clase de grupo muestra `#effective:r--` — sin `x` en un archivo de datos, correctamente.
- La `x` en `default:group:deployers:r-x` no se desperdició: en un *subdirectorio*, `mkdir` pide `0777`, la mask queda en `rwx`, y los directorios siguen siendo atravesables. Eso es precisamente lo que te compra `r-x`/`rwx` en una ACL default, y por qué deberías escribir `rX` al usar `setfacl` interactivamente.

**Las ACLs default son estrictamente más fuertes que los directorios setgid** para workspaces compartidos: setgid controla solo el *grupo*, y sigue siendo rehén del umask del escritor. Una ACL default controla *el conjunto entero de permisos*, es inmune al umask, y puede expresar más de un grupo nombrado. En la práctica desplegás **ambos**: setgid para consistencia de la propiedad de grupo (de la que dependen algunas herramientas y sistemas de cuota), y una ACL default para el modo.

### 7.4 La trampa de `chmod` — el modo de falla de ACL de mayor severidad en producción

**Cuando un archivo tiene una ACL extendida, la tríada de grupo que muestra `ls -l` es la mask, no `group::`.** Por lo tanto `chmod g-w` no modifica la entrada del grupo propietario — **baja la mask, recortando silenciosamente a cada usuario nombrado y cada grupo nombrado de un saque.**

```
$ getfacl -c /var/log/app/app.log
user::rw-
user:promtail:r--
group::r--
mask::r--
other::---

$ ls -l /var/log/app/app.log
-rw-r-----+ 1 appsvc appsvc 918273 Aug 24 10:52 /var/log/app/app.log
#     ^^^ this 'r' is mask::r--, NOT group::r--

$ sudo chmod 600 /var/log/app/app.log     # "hardening": remove group read

$ getfacl -c /var/log/app/app.log
user::rw-
user:promtail:r--		#effective:---
group::r--			#effective:---
mask::---
other::---
```

El log shipper ahora está silenciosamente ciego. No se borró nada, `getfacl` sigue mostrando `promtail:r--`, y cualquier verificación basada en grep (`getfacl file | grep promtail`) sigue pasando. Solo el comentario `#effective:` revela la caída.

**Mitigaciones, en orden de preferencia:**

1. Cualquier paso de gestión de configuración o de hardening que ejecute `chmod` sobre un path debe primero verificar que el path tenga una ACL mínima. Tratá "`chmod` sobre un archivo con ACL" como una violación de política.
2. Reparar restaurando la mask explícitamente: `setfacl -m m::rw- FILE`, o dejar que `setfacl` la recalcule reaplicando cualquier `-m`.
3. Auditar continuamente con `getfacl -R -e`, alertando ante cualquier línea `#effective:` cuyo valor difiera de la entrada.

```
# find /srv /var/log -type f -exec getfacl -c -e --skip-base {} + 2>/dev/null \
  | awk '/^# file:/{f=$3} /#effective:/{print f": "$0}'
/var/log/app/app.log: user:promtail:r--		#effective:---
/var/log/app/app.log: group::r--		#effective:---
```

### 7.5 Almacenamiento, límites, y las herramientas que destruyen ACLs silenciosamente

Las ACLs se almacenan en dos atributos extendidos del namespace `system`:

```
$ getfattr -m '^system\.' -d /srv/deploy/artifacts
getfattr: Removing leading '/' from absolute path names
# file: srv/deploy/artifacts
system.posix_acl_access=0sAgAAAAEABwD/////AgAHANwFAAAEAAcA/////wgABQCwBAAACAAFABQFAAAQAAcA/////yAAAAD/////
system.posix_acl_default=0sAgAAAAEABwD/////AgAHANwFAAAEAAUA/////wgABQCwBAAACAAFABQFAAAQAAcA/////yAAAAD/////
```

Nunca editás esto directamente — el valor es una estructura binaria empaquetada (`struct posix_acl_xattr_header` + entradas de 8 bytes). Su existencia importa por tres razones:

**Límite de almacenamiento.** La ACL entera debe caber en un único atributo extendido. En ext4 eso significa el espacio de xattr dentro del inode (solo con inodes de 256 bytes o más) más como máximo un bloque del filesystem. El techo práctico es del orden de unos pocos cientos de entradas con un tamaño de bloque de 4 KiB. Medilo en tu propio filesystem en lugar de confiar en un número:

```
$ f=$(mktemp -p /srv/deploy) ; n=0
$ while setfacl -m "u:#$((10000+n)):r--" "$f" 2>/dev/null; do n=$((n+1)); done
$ echo "max named entries on this filesystem: $n"
max named entries on this filesystem: 507
$ setfacl -m u:#20000:r-- "$f"
setfacl: /srv/deploy/tmp.9kZq1: No space left on device      ← ENOSPC, not EACCES
$ rm -f "$f"
```

**Implicancia de diseño: nunca enumeres usuarios en una ACL.** Otorgá a grupos. Una ACL con 400 usuarios nombrados es inauditable, choca contra el techo del filesystem, y debe reescribirse en cada alta/baja. Una ACL con cuatro grupos nombrados es una política de una línea y delega la membresía a tu sistema de identidad.

**Opciones de montaje.** ext2/3/4 requieren la opción `acl` (compilada y por defecto desde Linux 2.6.39 / e2fsprogs; `noacl` la deshabilita). XFS y Btrfs siempre soportan ACLs. Verificá, nunca supongas:

```
$ findmnt -no SOURCE,FSTYPE,OPTIONS /srv
/dev/mapper/vg0-srv ext4 rw,relatime,seclabel,nosuid,nodev,acl,data=ordered

$ findmnt -no TARGET,OPTIONS -t ext4,xfs,btrfs | grep -E 'noacl|nouser_xattr'
/mnt/legacy rw,relatime,noacl,nouser_xattr        ← ACLs will fail here with EOPNOTSUPP
```

**Herramientas que preservan, y herramientas que destruyen.** Esta tabla vale la pena memorizarla; la columna derecha es una lista de incidentes reales.

| Operación | Modo | Dueño | ACL POSIX | xattr `user.*` | Etiqueta SELinux |
|---|---|---|---|---|---|
| `cp file dst` | ✗ (umask) | ✗ | ✗ | ✗ | ✗ (transición de tipo) |
| `cp -p` | ✓ | ✓ (root) | ✗ | ✗ | ✗ |
| `cp -a` / `cp --preserve=all` | ✓ | ✓ | ✓ | ✓ | ✓ |
| `mv` (mismo filesystem) | ✓ | ✓ | ✓ | ✓ | ✓ (`rename(2)` puro) |
| `mv` (entre filesystems) | ✓ | ✓ | ✓ con el mejor esfuerzo | ✓ con el mejor esfuerzo | ✓ con el mejor esfuerzo |
| `rsync -a` | ✓ | ✓ | **✗** | **✗** | ✗ |
| `rsync -aAX --numeric-ids` | ✓ | ✓ | ✓ | ✓ | ✓ (con `-X`) |
| `tar -cf` | ✓ | ✓ | **✗** | **✗** | ✗ |
| `tar --acls --xattrs --selinux` | ✓ | ✓ | ✓ | ✓ | ✓ |
| `install -m` | fijado explícitamente | fijado explícitamente | **✗** | **✗** | ✗ |
| `> file` (truncar) | ✓ | ✓ | ✓ | ✓ | ✓ (mismo inode) |
| **`sed -i`** | ✓ copiado | ✓ (root) | **✗** | **✗** | **✗** |
| **Editor con escribir-y-renombrar** (`vim` por defecto, `emacs`) | ✓ copiado | varía | **✗** | **✗** | **✗** |
| `dd`, `cat >` hacia un archivo nuevo | ✗ | ✗ | ✗ | ✗ | ✗ |

Las últimas dos filas son las que muerden. `sed -i` **no** edita in situ: escribe un archivo temporal y le hace `rename(2)` sobre el destino. El resultado es un **inode nuevo** con permisos frescos — cada ACL, cada atributo extendido y la etiqueta SELinux desaparecieron. Un "inofensivo" `sed -i 's/debug/info/' /var/log/app/logrotate.conf` sobre un archivo con ACL le quita el acceso al log shipper.

```
$ getfacl -c /etc/app/app.conf | grep promtail
user:promtail:r--
$ stat -c %i /etc/app/app.conf
1443122
$ sudo sed -i 's/^level=.*/level=info/' /etc/app/app.conf
$ stat -c %i /etc/app/app.conf
1443198                                       ← different inode
$ getfacl -c /etc/app/app.conf | grep promtail
$ ls -l /etc/app/app.conf
-rw-r--r-- 1 root root 412 Aug 24 11:04 /etc/app/app.conf     ← no '+', ACL destroyed
```

**Regla:** después de cualquier edición in situ de un archivo que lleva una ACL, reaplicala desde una especificación almacenada y ejecutá `restorecon`. La gestión de configuración, no `sed`, debería ser dueña de esos archivos.

### 7.6 ACLs POSIX vs ACLs NFSv4

Existen dos modelos de ACL incompatibles en el ecosistema Linux. Saber en cuál estás determina qué cadena de herramientas funciona.

| | ACL draft POSIX | ACL NFSv4 / NFSv4.1 |
|---|---|---|
| Modelo | Solo-permitir, ordenado por clase | **ACEs ordenadas, ALLOW *y* DENY** |
| Evaluación | Primera *clase* coincidente, mask aplicada | Escaneo secuencial de ACEs; primera coincidencia decisiva; el orden es semántico |
| Granularidad de permisos | 3 bits (`rwx`) | ~14 bits: `read_data`, `write_data`, `append_data`, `read_attributes`, `write_acl`, `delete`, `delete_child`, `write_owner`, … |
| Herencia | ACL `default:` en un directorio | Flags por ACE: `fi` (file_inherit), `di` (dir_inherit), `ni` (no_propagate), `oi` (inherit_only) |
| Concepto de mask | Sí — el origen de la trampa de §7.4 | Sin mask |
| Soporte nativo en Linux | ext2/3/4, XFS, Btrfs, tmpfs, JFS, ReiserFS, OpenZFS (`acltype=posix`) | OpenZFS (`acltype=nfsv4`), montajes NFSv4. `richacl` nunca se integró en mainline |
| Herramientas | `getfacl` / `setfacl` (paquete `acl`) | `nfs4_getfacl` / `nfs4_setfacl` (`nfs4-acl-tools`) |
| Fidelidad con Windows/SMB | Con pérdida | Alta — mapea de cerca a las DACLs de NTFS |

En un servidor NFSv4 Linux que exporta ext4/XFS, `nfsd` **traduce** las ACLs POSIX a ACLs NFSv4 en el cable. La traducción tiene pérdida en ambas direcciones; una ACE `DENY` fijada desde un cliente Windows no puede representarse en la ACL POSIX del servidor. Los síntomas de este desajuste — permisos que "se resetean" o "no se quedan" — son un artefacto de la traducción, no un bug.

El NFSv3 legado usa un programa RPC lateral separado, `NFSACL`; `mount -o noacl` lo deshabilita en el cliente. Y `root_squash` (el default de los exports) mapea el uid 0 del cliente a `nobody`, así que `chown`, `chmod` sobre archivos que no te pertenecen, y `chattr +i` fallan todos con `EPERM` desde un cliente NFS sin importar el privilegio local.

---

## 8. Atributos extendidos

Las ACLs son un consumidor de un mecanismo general: pares `name=value` arbitrarios adosados a un inode, particionados en cuatro namespaces con reglas de acceso distintas.

| Namespace | Quién puede **leer** | Quién puede **escribir** | Propósito | Preservado por |
|---|---|---|---|---|
| `user.*` | Cualquiera con `r` sobre el archivo | Cualquiera con `w` sobre el archivo; requiere un archivo regular o directorio (**no** symlinks ni nodos de dispositivo); en un directorio sticky, solo el dueño o `CAP_FOWNER` | Metadatos de aplicación: tipo MIME, checksums, procedencia, IDs de build | `cp -a`, `rsync -X`, `tar --xattrs` |
| `trusted.*` | Solo `CAP_SYS_ADMIN` — **invisible** para procesos sin privilegios, incluso para el dueño del archivo | `CAP_SYS_ADMIN` | Subsistemas del kernel: `trusted.overlay.*` para overlayfs; procedencia fuera de banda que una aplicación no debe poder falsificar | Solo al copiar como root con `--xattrs` |
| `system.*` | Gobernado por el subsistema del kernel dueño | Igual | `system.posix_acl_access`, `system.posix_acl_default`, `system.nfs4_acl` | Vía los flags que reconocen ACLs |
| `security.*` | Gobernado por el LSM / IMA | Gobernado por el LSM | `security.selinux`, `security.SMACK64`, `security.capability` (file capabilities), `security.ima`, `security.evm` | `tar --selinux`, `rsync -X`, `cp -a` |

La restricción de `user.*` sobre symlinks y nodos de dispositivo es deliberada: los bits de permiso de esos inodes no son controles de acceso significativos, así que permitir xattrs de usuario en ellos sería un canal de almacenamiento ilimitado y sin contabilizar.

```
$ setfattr -n user.build.commit -v 9f3a17d2c /srv/deploy/artifacts/build-4712/manifest.json
$ setfattr -n user.build.pipeline -v 'gitlab/platform#4712' /srv/deploy/artifacts/build-4712/manifest.json
$ setfattr -n user.build.sbom.sha256 \
           -v 4f1a...c9 /srv/deploy/artifacts/build-4712/manifest.json

$ getfattr -d /srv/deploy/artifacts/build-4712/manifest.json
getfattr: Removing leading '/' from absolute path names
# file: srv/deploy/artifacts/build-4712/manifest.json
user.build.commit="9f3a17d2c"
user.build.pipeline="gitlab/platform#4712"
user.build.sbom.sha256="4f1a...c9"
```

`getfattr` usa por defecto `-m '^user\.'`. Para ver todo tenés que pedirlo, y tenés que ser root:

```
# getfattr -d -m - /srv/deploy/artifacts/build-4712/manifest.json
getfattr: Removing leading '/' from absolute path names
# file: srv/deploy/artifacts/build-4712/manifest.json
security.selinux="system_u:object_r:var_t:s0"
system.posix_acl_access=0sAgAAAAEABgD/////BAAEAP////8QAAQA/////yAAAAD/////
user.build.commit="9f3a17d2c"
user.build.pipeline="gitlab/platform#4712"
user.build.sbom.sha256="4f1a...c9"
```

Codificación y remoción:

```
$ getfattr -n user.build.commit -e hex FILE     # -e text|hex|base64 (base64 is the default for binary)
$ setfattr -x user.build.pipeline FILE          # remove one
$ setfattr -h -n user.foo -v bar SYMLINK        # act on the symlink itself (will fail: EPERM)
setfattr: SYMLINK: Operation not permitted
```

### 8.1 `security.capability` — el reemplazo moderno de setuid

Las file capabilities viven en el namespace `security.*` y son la forma correcta de otorgarle a un binario un privilegio específico en lugar de todos.

```
# getcap -r /usr/bin /usr/sbin 2>/dev/null
/usr/bin/ping cap_net_raw=ep
/usr/bin/newgidmap cap_setgid=ep
/usr/bin/newuidmap cap_setuid=ep
/usr/bin/mtr-packet cap_net_raw=ep

# setcap 'cap_net_bind_service=+ep' /usr/local/bin/edge-proxy
# getcap /usr/local/bin/edge-proxy
/usr/local/bin/edge-proxy cap_net_bind_service=ep

# getfattr -n security.capability -e hex /usr/local/bin/edge-proxy
getfattr: Removing leading '/' from absolute path names
# file: usr/local/bin/edge-proxy
security.capability=0x01000002000004000000000000000400000000000000000000000000

# ls -l /usr/local/bin/edge-proxy
-rwxr-xr-x 1 root root 8412160 Aug 24 11:18 /usr/local/bin/edge-proxy
```

Notá la última línea: **`ls -l` no muestra nada.** Un binario con `cap_sys_admin=ep` — efectivamente equivalente a root — es indistinguible de un ejecutable ordinario en un listado de directorio. Cualquier auditoría de hardening que haga grep de `find / -perm -4000` y se detenga ahí tiene un punto ciego del tamaño de todo el sistema de capabilities. Ambos barridos son obligatorios (§13).

Las letras del sufijo son los conjuntos de capabilities: `e` = effective (elevada automáticamente en exec), `p` = permitted (puede ser elevada por el propio programa), `i` = inheritable. `cap_x=ep` es "siempre encendida"; `cap_x=p` requiere un programa consciente de capabilities que la eleve deliberadamente y la suelte después de usarla — estrictamente mejor, y lo que `edge-proxy` debería hacer alrededor de su `bind()`.

`security.capability`, igual que setuid, es derrotada por montajes `nosuid` y por `no_new_privs`.

### 8.2 Matriz de soporte de atributos extendidos

| Filesystem | Bits de modo | ACL POSIX | `user.*` | `trusted.*`/`security.*` | Notas |
|---|---|---|---|---|---|
| ext4 | ✓ | ✓ (`acl`, por defecto) | ✓ (`user_xattr`, por defecto) | ✓ | En línea en inode ≥256 B, si no un bloque |
| XFS | ✓ | ✓ siempre | ✓ siempre | ✓ | Attribute fork; capacidad mucho mayor |
| Btrfs | ✓ | ✓ | ✓ | ✓ | Por subvolumen; los snapshots preservan |
| OpenZFS | ✓ | `acltype=posix` o `nfsv4` | ✓ (`xattr=sa` recomendado) | ✓ | `xattr=dir` es lento — un directorio oculto por archivo |
| tmpfs | ✓ | ✓ | ✓ **solo en Linux ≥ 6.6** | ✓ | Los kernels más viejos soportan solo `trusted.`/`security.` |
| overlayfs | ✓ | ✓ | ✓ | ✓ | Usa `trusted.overlay.*` internamente (`user.overlay.*` cuando no es privilegiado) |
| vfat / exfat | ✗ | ✗ | ✗ | ✗ | Propiedad sintetizada al montar: `uid=`, `gid=`, `umask=`, `fmask=`, `dmask=` |
| NTFS3 | parcial | ✗ | ✓ | parcial | Vía `system.ntfs_*`; mapeo `uid=`/`gid=` típico |
| NFSv3 | ✓ | ✓ (sideband NFSACL) | ✗ | ✗ | `noacl` para deshabilitar |
| NFSv4 | ✓ | traducida ↔ ACL NFSv4 | ✗ | limitado | Ver §7.6 |
| virtiofs | ✓ | ✓ | ✓ (con `-o xattr`) | ✓ | Depende de la configuración del daemon |
| 9p | ✓ | limitado | limitado | ✗ | Evitalo para cargas sensibles a permisos |

La fila de `vfat` explica una clase recurrente de incidentes: **un pendrive o una partición EFI no puede guardar propiedad Unix.** Cada archivo aparece como `root:root 0755` (o lo que digan las opciones de montaje). Copiar una clave privada a uno y de vuelta destruye su `0600`. Las opciones de montaje son el único control que tenés:

```
# mount -o uid=1000,gid=1000,fmask=0177,dmask=0077,noexec,nosuid,nodev \
        /dev/sdb1 /mnt/transfer
$ ls -l /mnt/transfer
-rw------- 1 sre sre 3243 Aug 24 11:26 id_ed25519
```

Notá que `fmask`/`dmask` son umasks, no modos: `fmask=0177` produce archivos `0600`, `dmask=0077` produce directorios `0700`.

---

## 9. Atributos de archivo: `chattr` / `lsattr`

Los atributos extendidos son datos *acerca de* un inode. Los atributos de archivo son flags que cambian cómo el **filesystem mismo** trata al inode. Son aplicados por el kernel *antes* de la verificación DAC, y por eso son la única forma de restringir a root sin una política MAC.

```
$ lsattr /etc/passwd /etc/shadow /var/log/audit/audit.log
--------------e------- /etc/passwd
----i---------e------- /etc/shadow
-----a--------e------- /var/log/audit/audit.log

$ lsattr -d /srv/deploy/artifacts       # -d: the directory itself, not its contents
--------------e------- /srv/deploy/artifacts
```

| Flag | Nombre | Semántica | Requiere | Filesystems |
|---|---|---|---|---|
| `i` | Immutable | Sin escritura, sin rename, sin unlink, sin nuevo hardlink, sin cambio de metadatos — **incluso por root** | `CAP_LINUX_IMMUTABLE` | ext2/3/4, XFS, Btrfs, F2FS |
| `a` | Append-only | `open()` permitido solo con `O_APPEND`; sin truncate, sin unlink | `CAP_LINUX_IMMUTABLE` | ext2/3/4, XFS, Btrfs |
| `A` | Sin atime | Suprime las actualizaciones de atime para este inode | dueño | ext2/3/4, XFS, Btrfs |
| `d` | Sin dump | Salteado por `dump(8)` | dueño | ext2/3/4, Btrfs |
| `S` | Escrituras síncronas | Datos escritos sincrónicamente, como si fuera `O_SYNC` | dueño | ext2/3/4 |
| `D` | Directorios síncronos | Cambios de directorio escritos sincrónicamente | dueño | ext2/3/4, Btrfs |
| `j` | Journalling de datos | Journal de los datos además de los metadatos | `CAP_SYS_RESOURCE` | ext3/4 (`data=ordered`/`writeback`) |
| `t` | Sin tail-merge | Deshabilita el tail packing | dueño | ext4 (`bigalloc`), ReiserFS |
| `u` | Undeletable | Preserva el contenido al borrar, para recuperación | dueño | no implementado en mainline |
| `c` | Comprimido | Compresión transparente | dueño | Btrfs (**no** ext4 — ext4 lo rechaza) |
| `C` | Sin copy-on-write | Deshabilita CoW — **solo fijable en un archivo de longitud cero o un directorio vacío** | dueño | Btrfs |
| `P` | Jerarquía de proyecto | Propaga el project ID a los hijos (cuota) | dueño | ext4, XFS |
| `V` | Verity | fs-verity habilitado — indicador de solo lectura | — | ext4, F2FS, Btrfs |
| `e` | Extents | Usa mapeo por extents — **solo lectura**, no se puede poner ni quitar | — | ext4 |
| `E` / `I` / `N` | Encriptado / Directorio indexado / Datos en línea | Indicadores de estado de solo lectura | — | ext4 |

### 9.1 `+i` y `+a` en producción: qué te compran realmente, y cuánto cuestan

```
# chattr +i /etc/shadow
# lsattr /etc/shadow
----i---------e------- /etc/shadow

# echo x >> /etc/shadow
-bash: /etc/shadow: Operation not permitted            ← EPERM, as root

# rm -f /etc/shadow
rm: cannot remove '/etc/shadow': Operation not permitted

# chattr -i /etc/shadow && echo x >> /etc/shadow && chattr +i /etc/shadow
```

**El valor:** un tripwire aplicado por el kernel. Un atacante que logró root pero no `CAP_LINUX_IMMUTABLE` (un contenedor sin ella, un proceso confinado por MAC, un servicio con `no_new_privs`) no puede modificar el archivo. Incluso con la capability, el `chattr -i` requerido es una syscall distintiva y barata de auditar (`ioctl(FS_IOC_SETFLAGS)`) que casi ningún proceso legítimo realiza.

**El costo, y es real:**

| Compromiso | Detalle |
|---|---|
| Las actualizaciones de paquetes se rompen | `rpm`/`dpkg` escriben archivos de configuración y fallan con `EPERM` a mitad de la transacción, dejando un sistema a medio actualizar |
| `passwd`, `usermod`, `useradd` se rompen | `+i` en `/etc/shadow` hace que los cambios de contraseña fallen |
| La gestión de configuración se rompe | Ansible/Puppet reportan una falla que no pueden remediar |
| Los backups pueden fallar al restaurar | Restaurar sobre un archivo inmutable falla; el flag mismo solo se preserva con builds de `tar` con soporte de atributos, o debe ser reaplicado por la gestión de configuración |
| No se preserva al copiar | `cp` no copia atributos; `rsync` tampoco. El flag debe ser parte de tu configuración, no de tus datos |
| Derrotado por `CAP_LINUX_IMMUTABLE` | Es un lomo de burro y una señal de detección, **no un límite de contención** |

**Patrón de uso correcto:** aplicá `+i` a un conjunto pequeño y explícitamente enumerado de archivos que legítimamente nunca cambian entre ventanas de mantenimiento, y hacé que su remoción/reaplicación sea un paso explícito y auditado de tu runbook de parcheo — no algo que un ingeniero descubre a las 03:00.

`+a` (append-only) encaja mejor con los logs, porque permite la única operación que un log necesita mientras prohíbe truncar y borrar — exactamente las dos cosas que un intruso quiere:

```
# chattr +a /var/log/audit/audit.log
# : > /var/log/audit/audit.log
-bash: /var/log/audit/audit.log: Operation not permitted
# echo 'test entry' >> /var/log/audit/audit.log
# echo $?
0
```

Notá que esto entra en conflicto con la rotación: `logrotate` debe configurarse con `copytruncate` deshabilitado y un par `prerotate`/`postrotate` que quite y reaplique el flag, o la rotación fallará todas las noches.

La recursión tiene una asimetría importante: `chattr -R +i /dir` pone el flag en el directorio **y** en cada archivo debajo. Un *directorio* inmutable impide crear, borrar o renombrar entradas pero no impide modificar el contenido de los archivos existentes.

---

## 10. Análisis consolidado de compromisos

### 10.1 Elegir un mecanismo para un directorio compartido

| Mecanismo | Expresa | Independiente del umask | Multi-grupo | Hereda a subdirectorios | Portable | Costo |
|---|---|---|---|---|---|---|
| Solo bits de modo | 1 grupo | ✗ | ✗ | ✗ | Universal | Cero |
| Directorio setgid | 1 grupo (solo propiedad) | ✗ — el modo sigue viniendo del umask | ✗ | ✓ (el bit se propaga) | Universal | Cero |
| setgid + `UMask=` forzado en la unit | 1 grupo | ✓ por servicio | ✗ | ✓ | Universal | Cero; frágil si existe cualquier otro escritor |
| **ACL default** | n grupos + n usuarios, modo completo | **✓** | **✓** | **✓** | Linux/Unix con soporte de ACL | 1 bloque de xattr |
| **setgid + ACL default** | n grupos, propiedad consistente | ✓ | ✓ | ✓ | Linux | 1 bloque de xattr |
| Tipo SELinux + transición | Basado en tipos, ortogonal a la identidad | ✓ | n/a | ✓ | Solo SELinux | Autoría de política |

**Recomendación para §1.1: setgid + ACL default.** Es la única combinación que sobrevive al umask de un escritor arbitrario, expresa más de un grupo lector, y se propaga automáticamente a directorios de build creados meses después.

### 10.2 Otorgar una capability privilegiada a un programa

| Mecanismo | Granularidad | Auditable vía `ls -l` | Sobrevive a `nosuid` | Sobrevive a `no_new_privs` | Registrado | Revocación |
|---|---|---|---|---|---|---|
| Binario setuid root | **Todos** los privilegios | ✓ (`s`) | ✗ | ✗ | ✗ | `chmod u-s` |
| File capability (`security.capability`) | Una capability | **✗ (invisible)** | ✗ | ✗ | ✗ | `setcap -r` |
| Regla de `sudo` | Una línea de comando, por usuario | n/a | n/a | n/a | **✓ (syslog)** | Editar sudoers |
| Unit de systemd + `AmbientCapabilities=` | Una capability, un servicio | n/a | n/a | ✓ (fijado por el gestor) | ✓ (journal) | Editar la unit |
| Helper privilegiado sobre un socket UNIX (Polkit/D-Bus) | Arbitraria, definida por la aplicación | n/a | n/a | ✓ | ✓ | Archivo de política |

**Ranking para trabajo nuevo:** `AmbientCapabilities=` de systemd > helper privilegiado > `sudo` > file capability > setuid. Setuid root debería tratarse como legado; cada uno en tu sistema es una primitiva de escalada de privilegios sin auditar que estás eligiendo conservar.

### 10.3 El panorama por capas

| Capa | Tipo | Granularidad | Sobrescribible por el dueño | Sobrevive a un movimiento entre filesystems | Evadida por |
|---|---|---|---|---|---|
| Bits de modo | DAC | 3 sujetos × 3 operaciones | **Sí** | ✓ | `CAP_DAC_OVERRIDE` |
| ACL POSIX | DAC | n sujetos × 3 operaciones | **Sí** | Solo con `cp -a`/`rsync -A` | `CAP_DAC_OVERRIDE` |
| Atributos de archivo (`+i`) | Ninguno — a nivel fs | Por inode | No | ✗ (no se copia) | `CAP_LINUX_IMMUTABLE` |
| Capabilities | Modelo de privilegios | Por capability | No | Solo con `--xattrs` | `nosuid`, `no_new_privs` |
| SELinux / AppArmor | **MAC** | Tipo/etiqueta × operación | **No** | Reetiquetado al mover | Modo permissive, `setenforce 0` |
| Namespaces / seccomp | Aislamiento | Por syscall / por recurso | No | n/a | Bug del kernel |

Las filas se componen con **AND**: cada una debe permitir. La consecuencia para la depuración es que "revisá los permisos" nunca es una respuesta completa — un `EACCES` de DAC y un `EACCES` de SELinux se ven idénticos para la aplicación. La §12 muestra cómo distinguirlos en un solo comando.

---

## 11. Infraestructura de producción

Todo lo que sigue está completo y es desplegable, no son extractos.

### 11.1 `systemd-tmpfiles` — la fuente de verdad declarativa e idempotente

Este es el lugar correcto para expresar la política de acceso al filesystem en un host con systemd. Corre en el arranque, a demanda, y es completamente idempotente.

```
# /etc/tmpfiles.d/50-build-artifacts.conf
#
# Discretionary access control for the build/artifact host.
# Type  Path                          Mode UID   GID        Age  Argument
#
# 'd'  create directory (and adjust mode/ownership if it exists)
# 'a+' merge POSIX ACL entries; 'd:' prefix = default (inherited) ACL
# 'A+' same as a+ but applied recursively to existing contents
# 'h'  set file attributes (chattr)
# 'z'  restore SELinux/SMACK label on the path itself
# 'Z'  restore label recursively

# --- Artifact root: setgid so group ownership is consistent, --------------
# --- default ACL so the mode is independent of every writer's umask. ------
d     /srv/deploy                     0755 root  root       -    -
d     /srv/deploy/artifacts           2770 root  deployers  -    -
a+    /srv/deploy/artifacts           -    -     -          -    user:ci:rwx,group:deployers:rwx,group:sec-audit:r-x
a+    /srv/deploy/artifacts           -    -     -          -    d:user::rwx,d:group::rwx,d:other::---,d:user:ci:rwx,d:group:deployers:rwx,d:group:sec-audit:r-X

# --- Published artifacts: writable only by the release bot, ---------------
# --- readable by everything that deploys. ---------------------------------
d     /srv/deploy/published           2750 release deployers -   -
a+    /srv/deploy/published           -    -     -          -    group:sec-audit:r-x,d:group:sec-audit:r-X,d:user::rwx,d:group::r-x,d:other::---

# --- Build scratch: sticky so tenants cannot delete each other's work. ----
d     /srv/deploy/scratch             1770 root  ci-runners 3d   -

# --- Incoming drop box: --wx, write-only. Uploaders can deposit but -------
# --- cannot enumerate or read back what is already there. -----------------
d     /srv/deploy/incoming            1733 root  root       7d   -

# --- Application logs: the shipper reads, nobody else sees them. ----------
d     /var/log/app                    2750 appsvc appsvc    -    -
a+    /var/log/app                    -    -     -          -    user:promtail:r-x,d:user:promtail:r--,d:user::rw-,d:group::r--,d:other::---

# --- Secrets: no group, no other, no inheritance surprises. ---------------
d     /etc/app/secrets                0700 appsvc appsvc    -    -
z     /etc/app/secrets/*              0400 appsvc appsvc    -    -

# --- Audit log: append-only at the filesystem level. ----------------------
h     /var/log/audit/audit.log        -    -     -          -    +a

# --- Relabel everything we just created (no-op on non-SELinux systems). ---
Z     /srv/deploy                     -    -     -          -    -
Z     /var/log/app                    -    -     -          -    -
```

Aplicar y verificar:

```
# systemd-tmpfiles --create /etc/tmpfiles.d/50-build-artifacts.conf
# systemd-tmpfiles --create --dry-run /etc/tmpfiles.d/50-build-artifacts.conf   # idempotency check
# echo $?
0

# getfacl -c /srv/deploy/artifacts
user::rwx
user:ci:rwx
group::rwx
group:deployers:rwx
group:sec-audit:r-x
mask::rwx
other::---
default:user::rwx
default:user:ci:rwx
default:group::rwx
default:group:deployers:rwx
default:group:sec-audit:r-x
default:mask::rwx
default:other::---
```

El `1733` en `/srv/deploy/incoming` (`drwx-wx-wt`) merece atención: **buzón de escritura solamente**. Los que suben pueden crear archivos pero no pueden hacer `readdir` (sin `r`), no pueden releer lo que escribieron, y no pueden borrar nada (sticky). Es el modo correcto para un path de ingesta que no debe funcionar también como canal de exfiltración.

### 11.2 Unit de systemd — DAC aplicado por el gestor de servicios

```ini
# /etc/systemd/system/payments-api.service
[Unit]
Description=Payments API
Documentation=https://internal.example.com/runbooks/payments-api
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/payments-api --config /etc/payments-api/config.yaml

# ---- Identity --------------------------------------------------------------
User=payments
Group=payments
# Read the shared TLS bundle and write to the shared artifact group.
SupplementaryGroups=tls-readers deployers

# ---- Creation-time mode ----------------------------------------------------
# Authoritative for this service. /etc/profile is NOT consulted by systemd.
UMask=0027

# ---- Managed directories: systemd creates, chowns and chmods these ---------
# and removes them on 'systemctl clean'. Paths are relative to /var/lib,
# /var/log, /run and /var/cache respectively.
StateDirectory=payments-api
StateDirectoryMode=0750
LogsDirectory=payments-api
LogsDirectoryMode=0750
RuntimeDirectory=payments-api
RuntimeDirectoryMode=0750
CacheDirectory=payments-api
CacheDirectoryMode=0700
ConfigurationDirectory=payments-api
ConfigurationDirectoryMode=0750

# ---- Privilege boundary ----------------------------------------------------
# NoNewPrivileges sets PR_SET_NO_NEW_PRIVS: every setuid bit and every
# file capability below this process is permanently neutralised.
NoNewPrivileges=yes
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
RestrictSUIDSGID=yes
RemoveIPC=yes

# ---- Filesystem namespace --------------------------------------------------
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectProc=invisible
ProcSubset=pid
ReadOnlyPaths=/etc/payments-api /etc/ssl/private
ReadWritePaths=/srv/deploy/artifacts
InaccessiblePaths=/srv/deploy/published /etc/app/secrets

# ---- Syscall and network surface ------------------------------------------
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources @obsolete @mount
SystemCallArchitectures=native
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes

[Install]
WantedBy=multi-user.target
```

`RestrictSUIDSGID=yes` es el complemento de `NoNewPrivileges`: el primero impide que el servicio *cree* un binario set-id, el segundo impide que *gane* privilegio a través de uno. Juntos cierran ambas direcciones.

Verificá contra el proceso en ejecución, no contra el archivo:

```
# systemctl daemon-reload && systemctl restart payments-api
# systemd-analyze security payments-api | head -14
  NAME                                                        DESCRIPTION                             EXPOSURE
✓ PrivateNetwork=                                             Service has access to the host's netw…       0.5
✓ User=/DynamicUser=                                          Service runs under a static non-root …       0.0
✓ CapabilityBoundingSet=~CAP_SET(UID|GID|PCAP)                Service cannot change UID/GID identit…       0.0
✓ CapabilityBoundingSet=~CAP_SYS_ADMIN                        Service has no administrator privileg…       0.0
✓ RestrictSUIDSGID=                                           SUID/SGID file creation is not restri…       0.0
✓ NoNewPrivileges=                                            Service processes cannot acquire new …       0.0

→ Overall exposure level for payments-api.service: 1.9 OK 🙂

# P=$(systemctl show -p MainPID --value payments-api)
# grep -E 'Umask|Uid|Gid|Groups|NoNewPrivs|CapEff' /proc/$P/status
Umask:	0027
Uid:	997	997	997	997
Gid:	997	997	997	997
Groups:	1200 1401
NoNewPrivs:	1
CapEff:	0000000000000400
# capsh --decode=0000000000000400
0x0000000000000400=cap_net_bind_service
```

### 11.3 Ansible — DAC reproducible e idempotente

```yaml
---
# roles/build-host-dac/tasks/main.yml
# Discretionary access control baseline for the build/artifact host.
# Requires: acl, attr, e2fsprogs on the target; `setfacl` for the acl module.

- name: Ensure DAC tooling is present
  ansible.builtin.package:
    name:
      - acl
      - attr
      - e2fsprogs
      - libcap
    state: present

- name: Assert the target filesystem supports ACLs
  ansible.builtin.command:
    cmd: findmnt -no OPTIONS --target /srv
  register: srv_mount_opts
  changed_when: false

- name: Fail loudly if ACLs are disabled on /srv
  ansible.builtin.assert:
    that:
      - "'noacl' not in srv_mount_opts.stdout"
      - "'nouser_xattr' not in srv_mount_opts.stdout"
    fail_msg: >-
      /srv is mounted with noacl and/or nouser_xattr ({{ srv_mount_opts.stdout }}).
      Every setfacl below would fail with EOPNOTSUPP. Fix /etc/fstab and remount
      before continuing.

- name: Create service groups
  ansible.builtin.group:
    name: "{{ item.name }}"
    gid: "{{ item.gid }}"
    system: true
    state: present
  loop:
    - { name: deployers,   gid: 1200 }
    - { name: sec-audit,   gid: 1300 }
    - { name: ci-runners,  gid: 1500 }

- name: Create service accounts
  ansible.builtin.user:
    name: "{{ item.name }}"
    uid: "{{ item.uid }}"
    group: "{{ item.group }}"
    groups: "{{ item.extra | default(omit) }}"
    shell: /usr/sbin/nologin
    home: "{{ item.home }}"
    create_home: true
    system: true
    state: present
  loop:
    - { name: ci,       uid: 1500, group: ci-runners, home: /var/lib/ci }
    - { name: release,  uid: 1501, group: deployers,  home: /var/lib/release }
    - { name: promtail, uid: 1502, group: promtail,   home: /var/lib/promtail }

# --- Ordering matters: owner/group FIRST, then mode. A chown after a chmod
# --- silently strips setuid/setgid. See chown(2).
- name: Create the artifact tree with ownership and setgid
  ansible.builtin.file:
    path: "{{ item.path }}"
    state: directory
    owner: "{{ item.owner }}"
    group: "{{ item.group }}"
    mode: "{{ item.mode }}"
  loop:
    - { path: /srv/deploy,            owner: root,    group: root,       mode: "0755" }
    - { path: /srv/deploy/artifacts,  owner: root,    group: deployers,  mode: "2770" }
    - { path: /srv/deploy/published,  owner: release, group: deployers,  mode: "2750" }
    - { path: /srv/deploy/scratch,    owner: root,    group: ci-runners, mode: "1770" }
    - { path: /srv/deploy/incoming,   owner: root,    group: root,       mode: "1733" }
    - { path: /var/log/app,           owner: appsvc,  group: appsvc,     mode: "2750" }

- name: Apply access ACLs on the artifact root
  ansible.posix.acl:
    path: /srv/deploy/artifacts
    entity: "{{ item.entity }}"
    etype: "{{ item.etype }}"
    permissions: "{{ item.perms }}"
    default: false
    state: present
  loop:
    - { entity: ci,        etype: user,  perms: rwx }
    - { entity: deployers, etype: group, perms: rwx }
    - { entity: sec-audit, etype: group, perms: rx  }

# --- Default ACLs make the resulting mode independent of the writer's umask.
# --- Without these, a runner with `umask 077` produces unreadable artifacts.
- name: Apply default (inherited) ACLs on the artifact root
  ansible.posix.acl:
    path: /srv/deploy/artifacts
    entity: "{{ item.entity | default(omit) }}"
    etype: "{{ item.etype }}"
    permissions: "{{ item.perms }}"
    default: true
    state: present
  loop:
    - { etype: user,                     perms: rwx }   # default:user::
    - { etype: group,                    perms: rwx }   # default:group::
    - { etype: other,                    perms: "-"  }  # default:other::
    - { etype: user,  entity: ci,        perms: rwx }
    - { etype: group, entity: deployers, perms: rwx }
    - { etype: group, entity: sec-audit, perms: rx  }

- name: Log shipper reads application logs, writes nothing
  ansible.posix.acl:
    path: "{{ item.path }}"
    entity: promtail
    etype: user
    permissions: "{{ item.perms }}"
    default: "{{ item.default }}"
    state: present
  loop:
    - { path: /var/log/app, perms: rx, default: false }
    - { path: /var/log/app, perms: r,  default: true  }

- name: Record build provenance in user extended attributes
  ansible.builtin.command:
    cmd: >-
      setfattr -n user.dac.policy_version -v "{{ dac_policy_version }}"
      /srv/deploy/artifacts
  changed_when: true

- name: Filesystem hardening sysctls
  ansible.posix.sysctl:
    name: "{{ item.key }}"
    value: "{{ item.value }}"
    sysctl_file: /etc/sysctl.d/60-fs-hardening.conf
    state: present
    reload: true
  loop:
    - { key: fs.protected_symlinks,  value: "1" }
    - { key: fs.protected_hardlinks, value: "1" }
    - { key: fs.protected_fifos,     value: "2" }
    - { key: fs.protected_regular,   value: "2" }

- name: Make the audit log append-only
  ansible.builtin.command:
    cmd: chattr +a /var/log/audit/audit.log
  register: chattr_a
  changed_when: chattr_a.rc == 0
  failed_when:
    - chattr_a.rc != 0
    - "'Operation not supported' not in chattr_a.stderr"

# --- Verification is part of the play, not a separate manual step. ----------
- name: Verify no unexpected setuid/setgid binaries exist
  ansible.builtin.shell:
    cmd: >-
      set -o pipefail;
      find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -print 2>/dev/null | sort
  args:
    executable: /bin/bash
  register: setid_found
  changed_when: false

- name: Report drift from the approved set-id baseline
  ansible.builtin.assert:
    that:
      - (setid_found.stdout_lines | difference(approved_setid_binaries)) | length == 0
    fail_msg: >-
      Unapproved set-id binaries present:
      {{ setid_found.stdout_lines | difference(approved_setid_binaries) | join(', ') }}
    success_msg: "Set-id baseline clean ({{ setid_found.stdout_lines | length }} approved entries)."
```

```yaml
# roles/build-host-dac/defaults/main.yml
dac_policy_version: "2026.08.24"

# The approved setuid/setgid baseline. Anything not on this list is drift and
# must be justified or removed. Regenerate deliberately, never automatically.
approved_setid_binaries:
  - /usr/bin/chage
  - /usr/bin/chfn
  - /usr/bin/chsh
  - /usr/bin/crontab
  - /usr/bin/expiry
  - /usr/bin/gpasswd
  - /usr/bin/mount
  - /usr/bin/newgrp
  - /usr/bin/passwd
  - /usr/bin/su
  - /usr/bin/sudo
  - /usr/bin/umount
  - /usr/bin/wall
  - /usr/bin/write
  - /usr/libexec/openssh/ssh-keysign
  - /usr/sbin/pam_timestamp_check
  - /usr/sbin/unix_chkpwd
```

### 11.4 Kubernetes — cómo llega DAC hasta adentro de un pod

Los permisos del filesystem del contenedor siguen siendo DAC; la única diferencia es que los UIDs son números sin entrada en `/etc/passwd`, y los volúmenes llegan con la propiedad que les haya dado la capa de almacenamiento.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: platform-build
  labels:
    # Pod Security Admission blocks privileged containers, privilege
    # escalation, and non-root violations at admission time — a policy layer
    # ABOVE the DAC we configure inside the pod, not a replacement for it.
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: artifact-store
  namespace: platform-build
spec:
  accessModes: ["ReadWriteMany"]
  storageClassName: nfs-csi
  resources:
    requests:
      storage: 200Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: artifact-writer
  namespace: platform-build
  labels:
    app.kubernetes.io/name: artifact-writer
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: artifact-writer
  template:
    metadata:
      labels:
        app.kubernetes.io/name: artifact-writer
    spec:
      automountServiceAccountToken: false

      securityContext:
        # ---- Process identity: DAC subject ---------------------------------
        runAsNonRoot: true
        runAsUser: 1500          # ci
        runAsGroup: 1500         # ci-runners
        # Supplementary GIDs. These are the group-class entries the kernel
        # will match against POSIX ACLs on the mounted volume.
        supplementalGroups: [1200, 1300]   # deployers, sec-audit

        # ---- Volume ownership: DAC object ----------------------------------
        # fsGroup makes the kubelet chgrp the volume to 1200 and set g+s on
        # its root, so every file the container creates inherits gid 1200.
        # This is exactly the setgid-directory mechanism from section 5.2,
        # applied by the kubelet at mount time.
        fsGroup: 1200
        # OnRootMismatch skips the recursive chown when the volume root
        # already has the right gid+setgid. On a 200Gi volume with millions
        # of inodes, "Always" adds minutes to every pod start. This is the
        # single most impactful DAC-related startup-latency setting in K8s.
        fsGroupChangePolicy: OnRootMismatch

        seccompProfile:
          type: RuntimeDefault

      containers:
        - name: writer
          image: registry.internal.example.com/platform/artifact-writer:1.14.2
          imagePullPolicy: IfNotPresent

          securityContext:
            # PR_SET_NO_NEW_PRIVS. Neutralises every setuid bit and every
            # file capability inside the image, permanently and irreversibly.
            allowPrivilegeEscalation: false
            # The image's root filesystem is immutable. Anything that needs
            # to be writable is an explicit emptyDir below.
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
            runAsUser: 1500
            runAsGroup: 1500
            runAsNonRoot: true

          env:
            # The process umask. There is no Kubernetes field for this; the
            # entrypoint must apply it, or the image must be built with it.
            - name: WRITER_UMASK
              value: "0007"

          command: ["/bin/sh", "-c"]
          args:
            - |
              set -eu
              umask "${WRITER_UMASK}"
              exec /usr/local/bin/artifact-writer --root /srv/artifacts

          volumeMounts:
            - name: artifacts
              mountPath: /srv/artifacts
            - name: tmp
              mountPath: /tmp
            - name: run
              mountPath: /run/artifact-writer

          resources:
            requests: { cpu: 200m, memory: 256Mi }
            limits:   { cpu: "2",  memory: 1Gi }

        # ---- Sidecar: reads what the writer produces, writes nothing -------
        - name: shipper
          image: registry.internal.example.com/platform/promtail:3.4.1
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
            runAsUser: 1502        # promtail
            runAsGroup: 1502
            runAsNonRoot: true
          volumeMounts:
            - name: artifacts
              mountPath: /srv/artifacts
              # Kubernetes-level read-only mount (MS_RDONLY on the bind).
              # This is a SECOND, independent control: even if the on-disk
              # ACL granted write, the mount would return EROFS.
              # Defence in depth — the ACL is still required, because a
              # read-only mount does not grant read access.
              readOnly: true
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits:   { cpu: 500m, memory: 256Mi }

      volumes:
        - name: artifacts
          persistentVolumeClaim:
            claimName: artifact-store
        # readOnlyRootFilesystem forces every writable path to be explicit.
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
        - name: run
          emptyDir:
            medium: Memory
            sizeLimit: 8Mi
```

Verificá dentro del pod en ejecución — los números deben coincidir con el manifiesto:

```
$ kubectl -n platform-build exec deploy/artifact-writer -c writer -- id
uid=1500 gid=1500 groups=1500,1200,1300

$ kubectl -n platform-build exec deploy/artifact-writer -c writer -- \
    sh -c 'ls -ld /srv/artifacts; grep Umask /proc/self/status'
drwxrwsr-x 4 root 1200 4096 Aug 24 11:47 /srv/artifacts
Umask:	0007

$ kubectl -n platform-build exec deploy/artifact-writer -c writer -- \
    sh -c 'touch /srv/artifacts/probe && ls -l /srv/artifacts/probe'
-rw-rw---- 1 1500 1200 0 Aug 24 11:48 /srv/artifacts/probe

$ kubectl -n platform-build exec deploy/artifact-writer -c writer -- touch /etc/probe
touch: /etc/probe: Read-only file system
command terminated with exit code 1

$ kubectl -n platform-build exec deploy/artifact-writer -c shipper -- \
    touch /srv/artifacts/evil
touch: /srv/artifacts/evil: Read-only file system
command terminated with exit code 1
```

Notá el `drwxrwsr-x` en la raíz del volumen — la `s` la puso el kubelet como consecuencia directa de `fsGroup: 1200`. `fsGroup` es la herencia de directorio setgid con nombre de campo YAML.

**Tres modos de falla de DAC específicos de Kubernetes:**

1. **`fsGroup` es ignorado por la mayoría de los filesystems de red.** Los drivers CSI de NFS y CIFS no pueden hacer `chown` en el servidor (`root_squash`). `fsGroup` silenciosamente no hace nada, el pod arranca, y cada escritura falla con `EACCES`. La propiedad debe fijarse del lado del servidor, y la ACL de §11.1 es lo que hace que funcione.
2. **`fsGroupChangePolicy: Always` en un volumen grande** hace `chown` recursivo a cada inode en cada arranque de pod. En un PVC de millones de inodes esto agrega minutos al arranque y puede empujar al pod más allá de su liveness probe hacia un crash loop. `OnRootMismatch` es casi siempre lo que querés.
3. **`runAsUser` con un UID ausente del `/etc/passwd` de la imagen** hace fallar a `getpwuid()`. Los programas que llaman a `os.UserHomeDir()`, expansión de `$HOME`, o `getlogin()` se rompen de formas confusas. Agregá la cuenta a la imagen, o fijá `HOME` explícitamente.

### 11.5 auditd — detectar cambios de DAC

DAC no te da logging. auditd es donde lo conseguís.

```
# /etc/audit/rules.d/50-dac.rules
#
# Discretionary access control change detection.
# -F auid>=1000 -F auid!=unset limits to human-initiated changes; drop those
# two predicates to also catch daemons (higher volume, higher fidelity).

# --- Permission changes -----------------------------------------------------
-a always,exit -F arch=b64 -S chmod,fchmod,fchmodat -F auid>=1000 -F auid!=unset -k dac_perm
-a always,exit -F arch=b32 -S chmod,fchmod,fchmodat -F auid>=1000 -F auid!=unset -k dac_perm

# --- Ownership changes ------------------------------------------------------
-a always,exit -F arch=b64 -S chown,fchown,lchown,fchownat -F auid>=1000 -F auid!=unset -k dac_own
-a always,exit -F arch=b32 -S chown,fchown,lchown,fchownat -F auid>=1000 -F auid!=unset -k dac_own

# --- ACL, xattr and file-capability changes ---------------------------------
-a always,exit -F arch=b64 -S setxattr,lsetxattr,fsetxattr,removexattr,lremovexattr,fremovexattr -F auid>=1000 -F auid!=unset -k dac_xattr
-a always,exit -F arch=b32 -S setxattr,lsetxattr,fsetxattr,removexattr,lremovexattr,fremovexattr -F auid>=1000 -F auid!=unset -k dac_xattr

# --- Every use of a privileged set-id binary --------------------------------
-a always,exit -F path=/usr/bin/sudo   -F perm=x -F auid!=unset -k dac_privcmd
-a always,exit -F path=/usr/bin/su     -F perm=x -F auid!=unset -k dac_privcmd
-a always,exit -F path=/usr/bin/passwd -F perm=x -F auid!=unset -k dac_privcmd
-a always,exit -F path=/usr/bin/newgrp -F perm=x -F auid!=unset -k dac_privcmd

# --- Attribute manipulation (chattr uses ioctl, not a dedicated syscall) ----
-a always,exit -F arch=b64 -S ioctl -F auid>=1000 -F auid!=unset -F dir=/etc -k dac_attr

# --- Unauthorised access attempts -------------------------------------------
-a always,exit -F arch=b64 -S open,openat,openat2,truncate,ftruncate,creat -F exit=-EACCES -F auid>=1000 -F auid!=unset -k dac_denied
-a always,exit -F arch=b64 -S open,openat,openat2,truncate,ftruncate,creat -F exit=-EPERM  -F auid>=1000 -F auid!=unset -k dac_denied

# --- Watch the identity database itself -------------------------------------
-w /etc/passwd  -p wa -k identity
-w /etc/shadow  -p wa -k identity
-w /etc/group   -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/sudoers -p wa -k identity
-w /etc/sudoers.d/ -p wa -k identity

# --- Make the ruleset immutable until reboot. MUST be the last line. --------
-e 2
```

```
# augenrules --load
# auditctl -s
enabled 2
failure 1
pid 1184
rate_limit 0
backlog_limit 8192
lost 0
backlog 0
backlog_wait_time 60000
loginuid_immutable 1 locked

# ausearch -k dac_perm -ts today -i | tail -8
type=PROCTITLE msg=audit(08/24/2026 11:52:17.443:8812) : proctitle=chmod 777 /srv/deploy/published
type=PATH msg=audit(08/24/2026 11:52:17.443:8812) : item=0 name=/srv/deploy/published inode=1443301 dev=fd:00 mode=dir,sgid,750 ouid=release ogid=deployers rdev=00:00 nametype=NORMAL
type=CWD msg=audit(08/24/2026 11:52:17.443:8812) : cwd=/home/sre
type=SYSCALL msg=audit(08/24/2026 11:52:17.443:8812) : arch=x86_64 syscall=fchmodat success=yes exit=0 a0=0xffffff9c a1=0x7ffd2c1b3a41 a2=0x1ff a3=0x0 items=1 ppid=4412 pid=4419 auid=sre uid=root gid=root euid=root suid=root fsuid=root egid=root sgid=root fsgid=root tty=pts0 ses=41 comm=chmod exe=/usr/bin/chmod key=dac_perm
```

`a2=0x1ff` es `0777` — el modo exacto solicitado, recuperable del evento crudo. `auid=sre` sobrevive a `sudo`, y por eso el humano responsable es identificable aunque `uid=root`.

---

## 12. Verificación y diagnóstico de fallas

### 12.1 `namei` — siempre tu primer comando

El 99% de los tickets "el archivo es 0644 pero recibo Permission denied" son una `x` faltante en un directorio padre. `namei -mo` (`-m` modo, `-o` dueño) resuelve el path completo e imprime cada componente:

```
$ sudo -u promtail namei -mo /srv/deploy/artifacts/build-4712/manifest.json
f: /srv/deploy/artifacts/build-4712/manifest.json
 drwxr-xr-x root  root      /
 drwxr-xr-x root  root      srv
 drwxr-x--- root  deploy    deploy         ← promtail is neither root nor in 'deploy'
 drwxrws--- root  deployers artifacts
 drwxrws--- ci    deployers build-4712
 -rw-rw---- ci    deployers manifest.json
```

La hoja es irrelevante. `promtail` no puede atravesar `/srv/deploy`, así que nada debajo es alcanzable. Otorgá `--x` en el directorio intermedio (o una entrada de ACL `u:promtail:--x`) y el problema desaparece.

`namei -l` da un formato largo ligeramente distinto; `namei -x` marca el componente que falla. Ambos están en `util-linux` y presentes en toda distribución.

### 12.2 Probá como el principal real — nunca como root

```
# The definitive test: run the check as the failing identity.
$ sudo -u promtail -- test -r /var/log/app/app.log && echo READABLE || echo DENIED
DENIED

# Batch-test a whole permission matrix.
$ for u in ci release promtail; do
    for op in "-r:read" "-w:write" "-x:exec"; do
      flag=${op%%:*}; name=${op##*:}
      if sudo -u "$u" -- test "$flag" /srv/deploy/artifacts; then r=ALLOW; else r=DENY; fi
      printf '%-10s %-6s %s\n' "$u" "$name" "$r"
    done
  done
ci         read   ALLOW
ci         write  ALLOW
ci         exec   ALLOW
release    read   ALLOW
release    write  ALLOW
release    exec   ALLOW
promtail   read   DENY
promtail   write  DENY
promtail   exec   DENY
```

Salvedad: `test -r` usa `access(2)`, que verifica contra el UID **real** e, históricamente, honra `CAP_DAC_OVERRIDE` — así que como root reporta éxito para todo. `sudo -u` lo arregla cambiando efectivamente de identidad. Esta es también la razón por la que `access(2)` nunca debe usarse para decisiones de seguridad en código de aplicación (TOCTOU + desajuste entre UID real y efectivo); el patrón correcto es hacer `open()` y manejar el error.

### 12.3 `strace` — la verdad de base

Cuando el mensaje de error de la aplicación es inútil, la syscall no lo es:

```
$ sudo -u promtail strace -f -y -e trace=%file -o /tmp/pt.log promtail -config.file=/etc/promtail/config.yaml
$ grep -E 'EACCES|EPERM|ENOENT' /tmp/pt.log | head
openat(AT_FDCWD, "/var/log/app", O_RDONLY|O_CLOEXEC|O_DIRECTORY) = -1 EACCES (Permission denied)
```

`-y` imprime el path resuelto de cada descriptor de archivo, lo que convierte líneas opacas de `read(7, ...)` en líneas legibles. `-e trace=%file` cubre cada syscall que toma un argumento de path.

### 12.4 Distinguir una denegación DAC de una denegación MAC

Ambas se manifiestan como `EACCES`. El log de auditoría las distingue en un solo comando:

```
# ausearch -m AVC -ts recent
<no matches>
```

Sin AVC → SELinux no está involucrado; la denegación es DAC. Confirmá al revés:

```
# ausearch -m AVC -ts recent | audit2why
type=AVC msg=audit(1756029841.117:9021): avc:  denied  { read } for  pid=5581 comm="promtail" name="app.log" dev="dm-0" ino=1443377 scontext=system_u:system_r:promtail_t:s0 tcontext=system_u:object_r:httpd_log_t:s0 tclass=file permissive=0

	Was caused by:
	Missing type enforcement (TE) allow rule.

	You can use audit2allow to generate a loadable module to allow this access.
```

Aquí los bits de modo y la ACL son correctos y la denegación es enteramente de SELinux — `chmod` habría sido el arreglo equivocado. Notá también que una **etiqueta SELinux incorrecta** es la secuela estándar del problema de `sed -i` de §7.5, y `restorecon -Rv PATH` es el arreglo.

La prueba decisiva: si `setenforce 0` hace desaparecer el problema, era MAC. Volvelo atrás inmediatamente (`setenforce 1`) y arreglá la etiqueta o la política — nunca dejes un host en permissive.

### 12.5 El árbol de decisión diagnóstico completo

```
"Permission denied"
│
├─ Is the errno EPERM (not EACCES)?  →  strace -e trace=%file
│    ├─ chattr -i / +a on the target?          →  lsattr FILE
│    ├─ Mount is read-only or nosuid?          →  findmnt -no OPTIONS --target FILE
│    ├─ Sticky directory, not the owner?       →  ls -ld DIR
│    ├─ NFS root_squash?                       →  findmnt -t nfs4; exportfs -v on the server
│    └─ Missing capability?                    →  grep CapEff /proc/PID/status; capsh --decode=...
│
├─ EACCES, and an AVC exists?  →  ausearch -m AVC -ts recent
│    └─ Fix the SELinux label or policy. restorecon -Rv PATH. NOT chmod.
│
└─ EACCES, no AVC → it is genuine DAC:
     │
     ├─ 1. Path traversal:      namei -mo /full/path
     │        Missing x on ANY component ⇒ everything below is unreachable.
     │
     ├─ 2. Identity:            id USER        (is the group actually present?)
     │        Group added but the process not restarted ⇒ stale credentials.
     │        Confirm with: grep Groups /proc/PID/status
     │
     ├─ 3. First-match-wins:    ls -l FILE
     │        Owner with '---' is denied even if other is 'rwx'. See 2.2.
     │
     ├─ 4. ACL present ('+')?   getfacl -e FILE
     │        Look for '#effective:' lines: the mask is clipping. See 7.4.
     │        Fix: setfacl -m m::rwx FILE   (NOT chmod)
     │
     ├─ 5. Filesystem support:  findmnt -no FSTYPE,OPTIONS --target FILE
     │        noacl / nouser_xattr / vfat ⇒ ACLs do not exist here.
     │
     └─ 6. Creation-time issue (files appear with the wrong mode):
              grep Umask /proc/PID/status        ← the truth
              getfacl DIR | grep '^default:'     ← overrides umask entirely
              ls -ld DIR                          ← setgid for group inheritance
```

### 12.6 Un script de auditoría reutilizable

```bash
#!/usr/bin/env bash
# /usr/local/sbin/dac-audit — report the effective DAC posture of a path tree.
# Exits non-zero if any world-writable non-sticky object or masked ACL is found.
set -euo pipefail

TARGET="${1:?usage: dac-audit PATH}"
rc=0

printf '=== Mount and filesystem capability ===\n'
findmnt -no SOURCE,TARGET,FSTYPE,OPTIONS --target "$TARGET"
if findmnt -no OPTIONS --target "$TARGET" | grep -qE '\bnoacl\b|\bnouser_xattr\b'; then
    printf 'WARN: ACLs or user xattrs are DISABLED on this mount.\n'
    rc=1
fi

printf '\n=== World-writable objects without the sticky bit ===\n'
if find "$TARGET" -xdev \( -type f -o -type d \) -perm -0002 \
        ! \( -type d -perm -1000 \) -printf '%M %u:%g %p\n' | grep . ; then
    rc=1
else
    printf 'none\n'
fi

printf '\n=== set-uid / set-gid files ===\n'
find "$TARGET" -xdev -type f \( -perm -4000 -o -perm -2000 \) \
     -printf '%M %u:%g %p\n' | sort || printf 'none\n'

printf '\n=== File capabilities (invisible to ls -l) ===\n'
getcap -r "$TARGET" 2>/dev/null || printf 'none\n'

printf '\n=== Unowned objects (orphaned uid/gid) ===\n'
find "$TARGET" -xdev \( -nouser -o -nogroup \) -printf '%M %U:%G %p\n' || printf 'none\n'

printf '\n=== ACL entries neutralised by the mask ===\n'
if find "$TARGET" -xdev -exec getfacl -c -e --skip-base {} + 2>/dev/null \
     | awk '/^# file:/{f=$3} /#effective:/{print f": "$0; found=1} END{exit !found}'; then
    printf 'ABOVE ENTRIES ARE INEFFECTIVE — a chmod has clipped the mask.\n'
    rc=1
else
    printf 'none\n'
fi

printf '\n=== Immutable / append-only objects ===\n'
find "$TARGET" -xdev -type f -exec lsattr {} + 2>/dev/null \
  | grep -E '^[^ ]*[ia]' || printf 'none\n'

printf '\n=== Directories missing the sticky bit but group/world writable ===\n'
find "$TARGET" -xdev -type d -perm -0020 ! -perm -1000 \
     -printf '%M %u:%g %p\n' || printf 'none\n'

exit "$rc"
```

```
# /usr/local/sbin/dac-audit /srv/deploy
=== Mount and filesystem capability ===
SOURCE              TARGET FSTYPE OPTIONS
/dev/mapper/vg0-srv /srv   ext4   rw,nosuid,nodev,relatime,seclabel

=== World-writable objects without the sticky bit ===
none

=== set-uid / set-gid files ===
none

=== File capabilities (invisible to ls -l) ===
none

=== Unowned objects (orphaned uid/gid) ===
none

=== ACL entries neutralised by the mask ===
/srv/deploy/published/manifest-4701.json: user:sec-audit:r--		#effective:---
ABOVE ENTRIES ARE INEFFECTIVE — a chmod has clipped the mask.

=== Immutable / append-only objects ===
none

=== Directories missing the sticky bit but group/world writable ===
none

# echo $?
1
```

---

## 13. Barridos de hardening

Dos búsquedas, ambas obligatorias, porque ninguna encuentra lo que encuentra la otra.

```
# --- Every set-id binary on local filesystems ---
# -xdev keeps the scan off NFS/procfs/sysfs and out of a 40-minute stall.
# -perm -4000 means "these bits at minimum"; -perm /4000 means "any of these".
# ! -type l excludes symlinks, whose modes are meaningless.
# -exec ... + batches rather than forking per file.
# find / -xdev -type f \( -perm -4000 -o -perm -2000 \) -exec ls -lb {} +

# find / -xdev -type f \( -perm -4000 -o -perm -2000 \) -printf '%M %u %g %p\n' | sort -k4
-rwsr-xr-x root root /usr/bin/chage
-rwsr-xr-x root root /usr/bin/chfn
-rwsr-xr-x root root /usr/bin/chsh
-rwxr-sr-x root tty  /usr/bin/wall
-rwsr-xr-x root root /usr/bin/gpasswd
-rwsr-xr-x root root /usr/bin/mount
-rwsr-xr-x root root /usr/bin/newgrp
-rwsr-xr-x root root /usr/bin/passwd
-rwsr-xr-x root root /usr/bin/su
-rwsr-xr-x root root /usr/bin/sudo
-rwsr-xr-x root root /usr/bin/umount
-rwxr-sr-x root shadow /usr/sbin/unix_chkpwd

# --- Every file capability. NOT covered by the search above. ---
# find / -xdev -type f -exec getcap {} + 2>/dev/null
/usr/bin/ping cap_net_raw=ep
/usr/bin/newgidmap cap_setgid=ep
/usr/bin/newuidmap cap_setuid=ep

# --- World-writable objects that are not sticky directories ---
# find / -xdev \( -type f -o -type d \) -perm -0002 ! \( -type d -perm -1000 \) -ls
(no output — good)

# --- Files with no valid owner (a uid/gid removed while files remained) ---
# find / -xdev \( -nouser -o -nogroup \) -printf '%U:%G %p\n'
(no output — good)

# --- Home directories readable by the world ---
# find /home -maxdepth 1 -type d -perm /0007 -printf '%M %u %p\n'

# --- Filesystems that should never carry set-id binaries or devices ---
# findmnt -no TARGET,OPTIONS /tmp /var/tmp /dev/shm /home
/tmp     rw,nosuid,nodev,noexec,relatime
/var/tmp rw,nosuid,nodev,noexec,relatime
/dev/shm rw,nosuid,nodev,noexec,relatime
/home    rw,nosuid,nodev,relatime
```

El `/etc/fstab` correspondiente — `nosuid,nodev` en cada filesystem que contenga datos controlados por el usuario es la mitigación más barata y duradera para toda la clase de ataques de setuid:

```
# /etc/fstab
# <device>                <mount>   <fs>  <options>                                     <dump> <pass>
UUID=8f2a...              /         ext4  defaults                                       0 1
UUID=b71c...              /srv      ext4  defaults,nosuid,nodev,acl                      0 2
UUID=c93d...              /home     ext4  defaults,nosuid,nodev,acl                      0 2
UUID=d15e...              /var      ext4  defaults,nosuid,nodev                          0 2
UUID=e02f...              /var/log  ext4  defaults,nosuid,nodev,noexec                   0 2
UUID=f338...              /var/tmp  ext4  defaults,nosuid,nodev,noexec                   0 2
tmpfs                     /tmp      tmpfs defaults,nosuid,nodev,noexec,mode=1777,size=4G 0 0
tmpfs                     /dev/shm  tmpfs defaults,nosuid,nodev,noexec,size=2G           0 0
```

Notá el `mode=1777` en el tmpfs de `/tmp` — el bit sticky ahí es una opción de montaje, no algo que le hacés `chmod` después (un `chmod` se perdería en el próximo arranque).

---

## 14. Trampas de examen y trampas de producción que se superponen

1. **Gana la primera coincidencia.** Un dueño con `---` queda denegado sin importar los bits de grupo y other. Los permisos no se acumulan entre clases.
2. **`w` sobre un directorio permite borrar archivos que no podés leer.** Los permisos del archivo son irrelevantes para `unlink()`; solo importan el `w`+`x` del directorio y el bit sticky.
3. **`x` es requerido en cada componente del path.** Un archivo `0644` dentro de un directorio `0700` es inalcanzable.
4. **Setuid se ignora en shell scripts y en directorios en Linux.**
5. **Setgid en un directorio controla el *grupo*, no el *modo*.** El modo sigue viniendo del umask del creador — salvo que exista una ACL default.
6. **Una ACL default vuelve irrelevante al umask.** Esta es la interacción más digna de examen del tema.
7. **La tríada de grupo en `ls -l` es la mask de la ACL cuando hay un `+`.** Por lo tanto `chmod g-w` recorta cada entrada nombrada.
8. **`chown` limpia setuid y setgid**, también para root, desde Linux 2.2.13. Siempre `chown` antes de `chmod`.
9. **`EACCES` ≠ `EPERM`.** `chmod` nunca arregla `EPERM`.
10. **Root no puede ejecutar un archivo con modo `000`** — el único agujero de `CAP_DAC_OVERRIDE`.
11. **`chattr +i` bloquea a root** y se aplica antes de la verificación DAC; solo `CAP_LINUX_IMMUTABLE` puede quitarlo.
12. **Los atributos extendidos `trusted.*` son invisibles** para cualquier proceso sin `CAP_SYS_ADMIN` — incluido el dueño del archivo.
13. **`getfattr` usa por defecto `-m '^user\.'`.** Sin `-m -` no verás ACLs, etiquetas SELinux ni capabilities.
14. **`rsync -a` no copia ACLs ni xattrs.** Necesitás `-aAX`. `tar` necesita `--acls --xattrs`. `cp -a` sí las copia.
15. **`sed -i` y la mayoría de los editores reemplazan el inode**, destruyendo ACLs, xattrs y etiquetas SELinux.
16. **`chmod -R 755` marca cada archivo de datos como ejecutable.** Usá `chmod -R u=rwX,g=rX,o=`.
17. **Las file capabilities son invisibles para `ls -l`.** Un barrido `find -perm -4000` por sí solo es una auditoría incompleta.
18. **`umask` en `/etc/profile` no afecta a los servicios de systemd.** Usá `UMask=` en la unit; verificá en `/proc/PID/status`.
19. **Los permisos de los symlinks (`lrwxrwxrwx`) siempre carecen de sentido en Linux.** No existe `lchmod(2)`.
20. **El bit sticky sobre un archivo no hace nada en Linux.** Solo sobre directorios.

---

## 15. Referencias

**Oficial de LPI**

- Objetivos del Examen LPIC-3 303 (303-300) — https://www.lpi.org/our-certifications/exam-303-objectives/
- Panorama de la certificación LPIC-3 Security — https://www.lpi.org/our-certifications/lpic-3-security-overview/

**Interfaces del kernel y POSIX (proyecto man-pages)**

- `acl(5)` — modelo de ACL POSIX, semántica de la mask, ACLs default e interacción con el umask — https://man7.org/linux/man-pages/man5/acl.5.html
- `xattr(7)` — namespaces de atributos extendidos y sus reglas de acceso — https://man7.org/linux/man-pages/man7/xattr.7.html
- `capabilities(7)` — `CAP_DAC_OVERRIDE`, `CAP_FOWNER`, `CAP_FSETID`, `CAP_LINUX_IMMUTABLE`, file capabilities — https://man7.org/linux/man-pages/man7/capabilities.7.html
- `path_resolution(7)` — por qué se requiere `x` en cada componente del path — https://man7.org/linux/man-pages/man7/path_resolution.7.html
- `inode(7)` — disposición de `st_mode` y bits de tipo de archivo — https://man7.org/linux/man-pages/man7/inode.7.html
- `chmod(2)` — reglas de limpieza de set-id y `CAP_FSETID` — https://man7.org/linux/man-pages/man2/chmod.2.html
- `chown(2)` — limpieza de set-id al cambiar la propiedad — https://man7.org/linux/man-pages/man2/chown.2.html
- `umask(2)` — https://man7.org/linux/man-pages/man2/umask.2.html
- `open(2)` — argumento de modo, `O_TMPFILE`, `O_NOFOLLOW` — https://man7.org/linux/man-pages/man2/open.2.html
- `access(2)` — UID real vs efectivo y la advertencia de TOCTOU — https://man7.org/linux/man-pages/man2/access.2.html
- `setfacl(1)` — https://man7.org/linux/man-pages/man1/setfacl.1.html
- `getfacl(1)` — https://man7.org/linux/man-pages/man1/getfacl.1.html
- `setfattr(1)` — https://man7.org/linux/man-pages/man1/setfattr.1.html
- `getfattr(1)` — https://man7.org/linux/man-pages/man1/getfattr.1.html
- `chattr(1)` — https://man7.org/linux/man-pages/man1/chattr.1.html
- `lsattr(1)` — https://man7.org/linux/man-pages/man1/lsattr.1.html
- `setcap(8)` / `getcap(8)` — https://man7.org/linux/man-pages/man8/setcap.8.html
- `namei(1)` — https://man7.org/linux/man-pages/man1/namei.1.html

**Documentación del kernel**

- Sysctls de protección a nivel de filesystem (`fs.protected_symlinks`, `protected_hardlinks`, `protected_fifos`, `protected_regular`) — https://www.kernel.org/doc/html/latest/admin-guide/sysctl/fs.html
- Documentación del filesystem ext4, incluyendo el almacenamiento de xattr y ACL — https://www.kernel.org/doc/html/latest/filesystems/ext4/
- Idmapped mounts — https://www.kernel.org/doc/html/latest/filesystems/idmappings.html
- overlayfs y `trusted.overlay.*` — https://www.kernel.org/doc/html/latest/filesystems/overlayfs.html
- `no_new_privs` — https://www.kernel.org/doc/html/latest/userspace-api/no_new_privs.html

**Proyectos de filesystems**

- Documentación de XFS — https://xfs.wiki.kernel.org/
- Btrfs — características y atributos del filesystem — https://btrfs.readthedocs.io/en/latest/
- Propiedades `acltype`, `aclmode`, `aclinherit` de OpenZFS — https://openzfs.github.io/openzfs-docs/man/master/7/zfsprops.7.html

**systemd**

- `tmpfiles.d(5)` — modos, ACLs y atributos de archivo declarativos — https://www.freedesktop.org/software/systemd/man/latest/tmpfiles.d.html
- `systemd.exec(5)` — `UMask=`, `StateDirectory=`, `NoNewPrivileges=`, `RestrictSUIDSGID=` — https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
- `systemd-analyze(1)` — el verbo `security` — https://www.freedesktop.org/software/systemd/man/latest/systemd-analyze.html

**Kubernetes**

- Configurar un Security Context para un Pod o Container (`runAsUser`, `fsGroup`, `fsGroupChangePolicy`, `supplementalGroups`) — https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/

**Estándares, benchmarks y herramientas**

- Módulo `ansible.posix.acl` de Ansible — https://docs.ansible.com/ansible/latest/collections/ansible/posix/acl_module.html
- Módulo `ansible.builtin.file` de Ansible — https://docs.ansible.com/ansible/latest/collections/ansible/builtin/file_module.html
- `auditd` / `audit.rules(7)` — https://man7.org/linux/man-pages/man7/audit.rules.7.html
- CIS Benchmarks (controles de permisos de filesystem en Linux) — https://www.cisecurity.org/cis-benchmarks
- NIST SP 800-53 Rev. 5, AC-3 Access Enforcement — https://csrc.nist.gov/pubs/sp/800/53/r5/upd1/final
- `acl` y `attr` upstream (userspace de ACL/xattr de Linux) — https://savannah.nongnu.org/projects/acl/
- RFC 8881 — NFS versión 4 minor version 1, §6 (ACLs) — https://www.rfc-editor.org/rfc/rfc8881.html