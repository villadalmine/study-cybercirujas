# 333.1 — Control de Acceso Discrecional: Ejercicios Guiados

**Examen:** LPIC-3 303-300 (Security), v3.0.0 · **Peso del tema:** 5
**Utilidades en alcance:** `chmod`, `umask`, `chown`, `chgrp`, `getfacl`, `setfacl`, `getfattr`, `setfattr`
**Fuente del objetivo:** <https://www.lpi.org/our-certifications/exam-303-objectives/>

> **Ejecutá esto en una VM o contenedor descartable.** Los ejercicios crean usuarios y grupos locales, establecen binarios SUID y montan sistemas de archivos. Nada de lo que hay acá debería ejecutarse en una máquina que te importe. Todo está confinado a una imagen ext4 montada por loop, de modo que el paso de limpieza es un solo `umount` más un `rm`.
>
> **¿Por qué una imagen loop y no `/tmp`?** `/tmp` es `tmpfs` en la mayoría de las distribuciones modernas, y `tmpfs` recién ganó soporte de atributos extendidos `user.*` en Linux 6.6. Además se monta con frecuencia como `nosuid,nodev`. Ambos hechos rompen silenciosamente la mitad de este tema. Un sistema de archivos ext4 respaldado por disco, con opciones de montaje conocidas, es el único sustrato reproducible para los ejercicios de DAC.

---

## Ejercicio 0 — Construir el sistema de archivos del laboratorio

### Pasos

1. Creá dos imágenes ext4: una con los valores por defecto de ACL/xattr, otra deliberadamente mutilada.

```console
# dd if=/dev/zero of=/var/tmp/dac-lab.img  bs=1M count=256 status=none
# dd if=/dev/zero of=/var/tmp/dac-plain.img bs=1M count=64  status=none
# mkfs.ext4 -q -F /var/tmp/dac-lab.img
# mkfs.ext4 -q -F /var/tmp/dac-plain.img
```

2. Inspeccioná las opciones de montaje por defecto *a nivel de sistema de archivos* registradas en el superbloque.

```console
# tune2fs -l /var/tmp/dac-lab.img | grep -E 'Default mount options|Filesystem features'
Default mount options:    user_xattr acl
Filesystem features:      has_journal ext_attr resize_inode dir_index filetype extent 64bit flex_bg sparse_super large_file huge_file dir_nlink extra_isize metadata_csum
```

3. Montá ambas.

```console
# mkdir -p /srv/dac-lab /srv/dac-plain
# mount -o loop                      /var/tmp/dac-lab.img   /srv/dac-lab
# mount -o loop,noacl,nouser_xattr   /var/tmp/dac-plain.img /srv/dac-plain
```

4. Preguntale al kernel qué aplicó realmente.

```console
# findmnt -no SOURCE,FSTYPE,OPTIONS /srv/dac-lab
/dev/loop0 ext4 rw,relatime,seclabel

# findmnt -no SOURCE,FSTYPE,OPTIONS /srv/dac-plain
/dev/loop1 ext4 rw,relatime,seclabel,noacl,nouser_xattr
```

5. Creá las identidades que se usan a lo largo de todo el material.

```console
# groupadd devops
# groupadd payroll
# useradd -m -G devops  alice
# useradd -m -G devops  bob
# useradd -m            carol
# id alice; id bob; id carol
uid=1001(alice) gid=1001(alice) groups=1001(alice),1004(devops)
uid=1002(bob) gid=1002(bob) groups=1002(bob),1004(devops)
uid=1003(carol) gid=1003(carol) groups=1003(carol)
```

> Los UID en tu sistema van a ser distintos. Donde aparezca un ID numérico más abajo, sustituilo por la salida de `id -u <user>`.

### Verificación de comprensión

- **Q0.1** `findmnt` muestra `noacl,nouser_xattr` para `/srv/dac-plain` pero no muestra ni `acl` ni `user_xattr` para `/srv/dac-lab`. ¿Significa eso que las ACL están deshabilitadas en `/srv/dac-lab`? Explicá la regla general sobre cómo leer `/proc/self/mounts`.
- **Q0.2** ¿Cuál es la diferencia entre la entrada `ext_attr` en `Filesystem features` y la entrada `user_xattr` en `Default mount options`?
- **Q0.3** Un colega reporta que `setfacl` falla con `Operation not supported` en un volumen de producción. Nombrá las tres capas distintas que revisarías, en orden, antes de concluir que la herramienta está rota.

---

## Ejercicio 1 — Propiedad, la palabra de modo, y qué está imprimiendo realmente `ls -l`

### Pasos

1. Creá un árbol de trabajo y mirá el modo en crudo.

```console
# mkdir -p /srv/dac-lab/project
# cd /srv/dac-lab/project
# echo 'quarterly figures' > report.txt
# ls -l report.txt
-rw-r--r--. 1 root root 18 Aug 24 10:11 report.txt
# stat -c 'mode=%A  octal=%a  raw=%f  uid=%u(%U)  gid=%g(%G)  %n' report.txt
mode=-rw-r--r--  octal=644  raw=81a4  uid=0(root)  gid=0(root)  report.txt
```

2. Cambiá propietario y grupo, y después confirmá que lo único que cambió fue la identidad.

```console
# chown alice report.txt
# chgrp devops report.txt
# chown alice:devops report.txt          # equivalent single call
# ls -l report.txt
-rw-r--r--. 1 alice devops 18 Aug 24 10:11 report.txt
```

3. Compará `chmod` simbólico y numérico. Notá que el modo simbólico es un *delta*, y el modo numérico es una *asignación absoluta*.

```console
# chmod 640 report.txt      ; stat -c %a report.txt
640
# chmod g+w  report.txt     ; stat -c %a report.txt
660
# chmod o=r  report.txt     ; stat -c %a report.txt
664
# chmod u=rw,g=r,o= report.txt ; stat -c %a report.txt
640
```

4. Demostrá que *borrar* un archivo es una operación sobre el directorio, no sobre el archivo.

```console
# mkdir /srv/dac-lab/project/locked
# echo secret > /srv/dac-lab/project/locked/data.txt
# chmod 000 /srv/dac-lab/project/locked/data.txt
# chmod 777 /srv/dac-lab/project/locked
# sudo -u carol cat /srv/dac-lab/project/locked/data.txt
cat: /srv/dac-lab/project/locked/data.txt: Permission denied
# sudo -u carol rm -f /srv/dac-lab/project/locked/data.txt
# ls /srv/dac-lab/project/locked
```

5. Mostrá que `chmod` sobre un enlace simbólico no hace nada en Linux, y que `chown` necesita `-h`.

```console
# ln -s report.txt report.lnk
# ls -l report.lnk
lrwxrwxrwx. 1 root root 10 Aug 24 10:14 report.lnk -> report.txt
# chmod 600 report.lnk
# ls -l report.lnk report.txt
lrwxrwxrwx. 1 root  root   10 Aug 24 10:14 report.lnk -> report.txt
-rw-------. 1 alice devops 18 Aug 24 10:11 report.txt
# chown -h carol report.lnk
# ls -l report.lnk
lrwxrwxrwx. 1 carol root 10 Aug 24 10:14 report.lnk -> report.txt
```

### Verificación de comprensión

- **Q1.1** `stat` reportó `raw=81a4`. Descomponé ese valor de 16 bits. ¿Qué parte es el tipo de archivo y qué parte es la palabra de permisos?
- **Q1.2** En el paso 3, ¿por qué `chmod g+w` produjo `660` mientras que `chmod o=r` produjo `664`? Enunciá la regla que distingue `+`/`-` de `=`.
- **Q1.3** En el paso 4, `carol` no pudo leer un archivo pero sí pudo borrarlo. ¿Qué bit de permiso, sobre qué inodo, autorizó el borrado?
- **Q1.4** `chmod 600 report.lnk` no cambió nada, silenciosamente. ¿Qué modificó en realidad, y qué llamada al sistema habría hecho falta para cambiar el modo propio del enlace simbólico?
- **Q1.5** Un archivo es `-rw-rw-rw-` y pertenece a `alice:devops`. `alice` es miembro de `devops`. ¿Qué tríada evalúa el kernel para `alice`, y qué pasa si la tríada del propietario es `---` mientras la del grupo es `rw-`?

---

## Ejercicio 2 — Resolución de rutas: la `x` en directorios no es "ejecutar"

### Pasos

1. Construí una ruta de tres niveles y quitale el bit de *lectura* al directorio del medio, manteniendo el de *ejecución*.

```console
# mkdir -p /srv/dac-lab/a/b/c
# echo payload > /srv/dac-lab/a/b/c/file.txt
# chmod 711 /srv/dac-lab/a/b        # --x for group/other: traversable, not listable
# chmod 755 /srv/dac-lab/a /srv/dac-lab/a/b/c
# chmod 644 /srv/dac-lab/a/b/c/file.txt
```

2. Hacé que un usuario sin privilegios intente listar contra atravesar.

```console
# sudo -u carol ls /srv/dac-lab/a/b
ls: cannot open directory '/srv/dac-lab/a/b': Permission denied
# sudo -u carol cat /srv/dac-lab/a/b/c/file.txt
payload
```

3. Ahora invertilo: bit de lectura presente, bit de ejecución ausente.

```console
# chmod 744 /srv/dac-lab/a/b
# sudo -u carol ls /srv/dac-lab/a/b
c
# sudo -u carol ls -l /srv/dac-lab/a/b
ls: cannot access '/srv/dac-lab/a/b/c': Permission denied
total 0
d????????? ? ? ? ?            ? c
# sudo -u carol cat /srv/dac-lab/a/b/c/file.txt
cat: /srv/dac-lab/a/b/c/file.txt: Permission denied
```

4. Restaurá.

```console
# chmod 755 /srv/dac-lab/a/b
```

### Verificación de comprensión

- **Q2.1** Enunciá con precisión qué otorga `r` y qué otorga `x` sobre el inodo de un directorio.
- **Q2.2** ¿Por qué el paso 3 imprime `d?????????` en lugar de un listado largo normal?
- **Q2.3** El modo `711` sobre un directorio home (`/home/alice`) es un patrón de endurecimiento habitual. ¿Qué permite y qué impide? ¿Por qué a veces se prefiere `750`?
- **Q2.4** Un servidor web devuelve 403 para `/srv/app/public/index.html` aunque el archivo es `-rw-r--r-- root root` y el servidor corre como `nginx`. `namei -om /srv/app/public/index.html` es la herramienta de diagnóstico. ¿Qué está chequeando que `ls -l index.html` no puede?

---

## Ejercicio 3 — `umask`: los bits que un proceso tiene prohibido crear

### Pasos

1. Leé la máscara actual en ambas notaciones.

```console
# umask
0022
# umask -S
u=rwx,g=rx,o=rx
```

2. Observá los dos *modos de creación* distintos que piden los programas, y cómo la máscara los resta.

```console
# cd /srv/dac-lab/project
# umask 022
# touch f022 ; mkdir d022
# umask 077
# touch f077 ; mkdir d077
# umask 002
# touch f002 ; mkdir d002
# ls -ld f022 d022 f077 d077 f002 d002
drwxr-xr-x. 2 root root 4096 Aug 24 10:22 d022
drwxrwx---. 2 root root 4096 Aug 24 10:22 d002
drwx------. 2 root root 4096 Aug 24 10:22 d077
-rw-r--r--. 1 root root    0 Aug 24 10:22 f022
-rw-rw----. 1 root root    0 Aug 24 10:22 f002
-rw-------. 1 root root    0 Aug 24 10:22 f077
```

3. Demostrá que la máscara es un atributo *por proceso*, heredado a través de `fork`/`exec`, y no un atributo del sistema de archivos ni del usuario.

```console
# umask 027
# bash -c 'umask; touch /srv/dac-lab/project/inherited; stat -c %a /srv/dac-lab/project/inherited'
0027
640
```

4. Mostrá una máscara que quita bits que el modo de creación nunca tuvo.

```console
# umask 777
# touch f777 ; mkdir d777
# ls -ld f777 d777
d---------. 2 root root 4096 Aug 24 10:24 d777
----------. 1 root root    0 Aug 24 10:24 f777
# umask 022
```

5. Mirá de dónde viene la máscara de login en un sistema real.

```console
# grep -E '^\s*(UMASK|HOME_MODE|USERGROUPS_ENAB)' /etc/login.defs
UMASK 022
HOME_MODE 0700
USERGROUPS_ENAB yes
# grep -rn pam_umask /etc/pam.d/ | head -3
/etc/pam.d/postlogin:session  optional  pam_umask.so silent
```

### Verificación de comprensión

- **Q3.1** Con `umask 077`, un archivo regular se creó como `600` y un directorio como `700`. ¿Por qué el directorio no es `600`?
- **Q3.2** ¿`umask` es una resta o una operación a nivel de bits? Escribí la expresión exacta que aplica el kernel dentro de `open(2)`/`mkdir(2)`.
- **Q3.3** Con `umask 022`, `gcc` produce un ejecutable que es `755`, pero `touch` produce `644`. No difieren ni la umask ni el sistema de archivos. Explicá.
- **Q3.4** Un trabajo de cron escribe archivos como `0644` aunque el shell interactivo del operador tiene `umask 007`. Dá dos razones independientes y la solución para cada una.
- **Q3.5** `USERGROUPS_ENAB yes` combinado con `pam_umask` normalmente produce una umask efectiva de `002` para los usuarios comunes en lugar de `022`. ¿Cuál es el supuesto de seguridad que hace aceptable `002` ahí, y cuándo falla ese supuesto?

---

## Ejercicio 4 — SUID, SGID y el bit sticky

### Pasos

1. Creá un binario SUID sin necesidad de compilador, copiando `id` y estableciendo el bit.

```console
# cp /usr/bin/id /srv/dac-lab/project/idcopy
# chmod 4755 /srv/dac-lab/project/idcopy
# ls -l /srv/dac-lab/project/idcopy
-rwsr-xr-x. 1 root root 39784 Aug 24 10:30 /srv/dac-lab/project/idcopy
# sudo -u carol /srv/dac-lab/project/idcopy
uid=1003(carol) gid=1003(carol) euid=0(root) groups=1003(carol)
```

2. Observá la forma con `S` mayúscula: el bit especial puesto *sin* el bit de ejecución subyacente.

```console
# chmod 4644 /srv/dac-lab/project/idcopy
# ls -l /srv/dac-lab/project/idcopy
-rwSr--r--. 1 root root 39784 Aug 24 10:30 /srv/dac-lab/project/idcopy
# chmod 4755 /srv/dac-lab/project/idcopy
```

3. Mostrá que `chown` destruye el bit SUID.

```console
# chown alice /srv/dac-lab/project/idcopy
# ls -l /srv/dac-lab/project/idcopy
-rwxr-xr-x. 1 alice root 39784 Aug 24 10:30 /srv/dac-lab/project/idcopy
```

4. Demostrá que SUID se ignora en scripts interpretados.

```console
# printf '#!/bin/bash\nid\n' > /srv/dac-lab/project/whoami.sh
# chmod 4755 /srv/dac-lab/project/whoami.sh
# sudo -u carol /srv/dac-lab/project/whoami.sh
uid=1003(carol) gid=1003(carol) groups=1003(carol)
```

5. Construí el directorio colaborativo SGID canónico.

```console
# mkdir /srv/dac-lab/shared
# chgrp devops /srv/dac-lab/shared
# chmod 2770  /srv/dac-lab/shared
# ls -ld /srv/dac-lab/shared
drwxrws---. 2 root devops 4096 Aug 24 10:34 /srv/dac-lab/shared
# sudo -u alice touch /srv/dac-lab/shared/from-alice
# sudo -u bob   mkdir /srv/dac-lab/shared/subdir
# ls -ld /srv/dac-lab/shared/from-alice /srv/dac-lab/shared/subdir
-rw-r--r--. 1 alice devops    0 Aug 24 10:35 /srv/dac-lab/shared/from-alice
drwxr-sr-x. 2 bob   devops 4096 Aug 24 10:35 /srv/dac-lab/shared/subdir
```

6. Construí un buzón sticky e intentá borrar el archivo de otra persona.

```console
# mkdir /srv/dac-lab/dropbox
# chmod 1777 /srv/dac-lab/dropbox
# ls -ld /srv/dac-lab/dropbox
drwxrwxrwt. 2 root root 4096 Aug 24 10:38 /srv/dac-lab/dropbox
# sudo -u alice touch /srv/dac-lab/dropbox/alice.tmp
# sudo -u bob rm /srv/dac-lab/dropbox/alice.tmp
rm: cannot remove '/srv/dac-lab/dropbox/alice.tmp': Operation not permitted
# sudo -u bob mv /srv/dac-lab/dropbox/alice.tmp /srv/dac-lab/dropbox/hijacked
mv: cannot move '/srv/dac-lab/dropbox/alice.tmp' to '/srv/dac-lab/dropbox/hijacked': Operation not permitted
# sudo -u bob truncate -s 0 /srv/dac-lab/dropbox/alice.tmp
# ls -l /srv/dac-lab/dropbox/alice.tmp
-rw-r--r--. 1 alice alice 0 Aug 24 10:39 /srv/dac-lab/dropbox/alice.tmp
```

7. Auditá el sistema en ejecución como lo harías en un engagement.

```console
# find /usr /bin /sbin -xdev -type f -perm -4000 -printf '%M %u %g %p\n' 2>/dev/null | head
-rwsr-xr-x root root /usr/bin/su
-rwsr-xr-x root root /usr/bin/mount
-rwsr-xr-x root root /usr/bin/passwd
...
# find / -xdev -type f -perm /6000 2>/dev/null | wc -l
22
# find / -xdev -type d -perm -0002 ! -perm -1000 2>/dev/null
```

### Verificación de comprensión

- **Q4.1** Distinguí `-rwsr-xr-x` de `-rwSr-xr-x`, y `drwxrwxrwt` de `drwxrwxrwT`. ¿Qué codifica la distinción minúscula/mayúscula en cada caso?
- **Q4.2** En el paso 3 el bit SUID desapareció después de `chown`, ejecutado *como root*. ¿Por qué hace esto el kernel, y por qué nunca hay que confiar en que el caso privilegiado se comporte de una manera u otra?
- **Q4.3** El paso 4 no produjo escalada de privilegios. ¿Cuál es la razón a nivel de kernel, y qué mecanismos alternativos existen para otorgarle derechos elevados a un script?
- **Q4.4** En el paso 5, `from-alice` tiene grupo `devops` en lugar de grupo `alice`. ¿Qué bit produjo eso, y qué heredó `subdir` adicionalmente que `from-alice` no pudo heredar?
- **Q4.5** En el paso 6, `bob` no pudo desenlazar ni renombrar `alice.tmp` pero *sí* pudo truncarlo a cero bytes. Explicá exactamente qué protege el bit sticky y qué no.
- **Q4.6** `find / -perm -4000` y `find / -perm /6000` devuelven conjuntos distintos. Enunciá la semántica de `-`, de `/` y de un argumento octal pelado en `find -perm`.
- **Q4.7** Un helper SUID-root deja de funcionar después de que el equipo de operaciones agrega `nosuid` a las opciones de montaje del volumen. ¿Dónde más, además de `mount`, se puede neutralizar SUID a nivel de todo el sistema?

---

## Ejercicio 5 — ACL POSIX y la mask

### Pasos

1. Leé la ACL de un archivo que no tiene ACL extendida. Notá las tres entradas *base* que se corresponden con la palabra de modo clásica.

```console
# cd /srv/dac-lab/project
# chown root:devops report.txt ; chmod 640 report.txt
# getfacl report.txt
getfacl: Removing leading '/' from absolute path names
# file: report.txt
# owner: root
# group: devops
user::rw-
group::r--
other::---
```

2. Otorgale acceso a un usuario nombrado. Mirá cómo aparece una entrada `mask` y cómo se le adosa el marcador `+` al listado.

```console
# setfacl -m u:carol:rw- report.txt
# ls -l report.txt
-rw-rw----+ 1 root devops 18 Aug 24 10:11 report.txt
# getfacl report.txt
# file: report.txt
# owner: root
# group: devops
user::rw-
user:carol:rw-
group::r--
mask::rw-
other::---
# sudo -u carol sh -c 'echo appended >> report.txt' && echo OK
OK
```

3. **La trampa.** `ls -l` ahora muestra `rw-` en el campo de grupo. Verificá que eso *no* es el permiso del grupo propietario.

```console
# stat -c %a report.txt
660
# getfacl -c report.txt | grep '^group::'
group::r--
# sudo -u bob sh -c 'echo bob-was-here >> report.txt'
sh: line 1: report.txt: Permission denied
```

4. Ahora achicá la mask con `chmod` y mirá cómo todas las entradas nombradas pierden derechos de golpe.

```console
# chmod g=r report.txt
# getfacl report.txt
# file: report.txt
# owner: root
# group: devops
user::rw-
user:carol:rw-			#effective:r--
group::r--
mask::r--
other::---
# sudo -u carol sh -c 'echo again >> report.txt'
sh: line 1: report.txt: Permission denied
```

5. Restaurá la mask explícitamente, sin tocar ningún otorgamiento.

```console
# setfacl -m m::rw- report.txt
# getfacl -c report.txt
user::rw-
user:carol:rw-
group::r--
mask::rw-
other::---
```

6. Mostrá el recálculo automático de la mask y cómo suprimirlo.

```console
# setfacl -m g:payroll:rwx report.txt
# getfacl -c report.txt | grep mask
mask::rwx
# setfacl -n -m g:payroll:rwx report.txt      # -n: leave the mask alone
```

7. Eliminá entradas de forma selectiva y masiva.

```console
# setfacl -x g:payroll report.txt
# getfacl -c report.txt | grep payroll || echo 'entry gone'
entry gone
# setfacl -b report.txt
# ls -l report.txt
-rw-r-----. 1 root devops 30 Aug 24 10:48 report.txt
```

8. Guardá y restaurá ACL como un flujo de texto — el mecanismo detrás del backup de ACL.

```console
# setfacl -m u:carol:rw,g:payroll:r report.txt
# getfacl -R --absolute-names /srv/dac-lab/project > /var/tmp/project.acl
# setfacl -b report.txt
# setfacl --restore=/var/tmp/project.acl
# getfacl -c report.txt | grep -E 'carol|payroll'
user:carol:rw-
group:payroll:r--
```

9. Encontrá todos los archivos del volumen que llevan una ACL extendida.

```console
# getfacl -R -s -p /srv/dac-lab 2>/dev/null | grep '^# file:' 
# file: /srv/dac-lab/project
# file: /srv/dac-lab/project/report.txt
```

### Verificación de comprensión

- **Q5.1** Enumerá los seis tipos de entrada de ACL e indicá cuáles *debe* contener obligatoriamente una ACL para ser válida.
- **Q5.2** ¿Exactamente qué clases de entradas limita la `mask`, y cuáles dos son inmunes a ella?
- **Q5.3** En el paso 3, `ls -l` mostró `-rw-rw----+` y sin embargo a `bob` — miembro del grupo propietario `devops` — se le denegó la escritura. Reconciliá estos dos hechos en una sola oración.
- **Q5.4** En el paso 4 un simple `chmod g=r` revocó silenciosamente el acceso de escritura de `carol` aunque `carol` no está en `devops`. Enunciá la regla que sigue `chmod` sobre un archivo con ACL extendida, y nombrá el riesgo operativo que esto crea para las herramientas de gestión de configuración.
- **Q5.5** ¿Qué significa `#effective:` en la salida de `getfacl`, y por qué nunca aparece junto a `user::`?
- **Q5.6** Contrastá `setfacl -x`, `setfacl -b` y `setfacl -k`.
- **Q5.7** `setfacl -m u:carol:rwx dir` tiene éxito pero `carol` sigue sin poder crear archivos en `dir`. Dá las dos causas más probables.
- **Q5.8** ¿Por qué `getfacl -R -s` es una mejor auditoría de volumen que `find ... -perm`?

---

## Ejercicio 6 — ACL por defecto, herencia, y la anulación de la umask

### Pasos

1. Adosá una ACL por defecto a un directorio. Solo los directorios pueden llevar una.

```console
# mkdir /srv/dac-lab/inbox
# chown root:devops /srv/dac-lab/inbox
# chmod 750 /srv/dac-lab/inbox
# setfacl -d -m u:carol:rwx,g:payroll:r-x /srv/dac-lab/inbox
# getfacl /srv/dac-lab/inbox
# file: srv/dac-lab/inbox
# owner: root
# group: devops
user::rwx
group::r-x
other::---
default:user::rwx
default:user:carol:rwx
default:group::r-x
default:group:payroll:r-x
default:mask::rwx
default:other::---
# setfacl -d -m u:carol:rwx /srv/dac-lab/project/report.txt
setfacl: report.txt: Only directories can have default ACLs
```

2. Establecé una umask hostil, y después creá un archivo dentro del directorio.

```console
# ( umask 077 && touch /srv/dac-lab/inbox/inherited.txt )
# ls -l /srv/dac-lab/inbox/inherited.txt
-rw-rw----+ 1 root root 0 Aug 24 11:02 /srv/dac-lab/inbox/inherited.txt
# getfacl -c /srv/dac-lab/inbox/inherited.txt
user::rw-
user:carol:rwx			#effective:rw-
group::r-x			#effective:r--
group:payroll:r-x		#effective:r--
mask::rw-
other::---
```

3. Creá un subdirectorio y observá la herencia en dos direcciones.

```console
# ( umask 077 && mkdir /srv/dac-lab/inbox/sub )
# getfacl -c /srv/dac-lab/inbox/sub
user::rwx
user:carol:rwx
group::r-x
group:payroll:r-x
mask::rwx
other::---
default:user::rwx
default:user:carol:rwx
default:group::r-x
default:group:payroll:r-x
default:mask::rwx
default:other::---
```

4. Confirmá que la herencia se aplica solo en el momento de creación — no es un vínculo vivo.

```console
# setfacl -d -x u:carol /srv/dac-lab/inbox
# getfacl -c /srv/dac-lab/inbox/inherited.txt | grep carol
user:carol:rwx			#effective:rw-
```

5. Aplicá una ACL a un árbol existente, distinguiendo entradas de acceso de entradas por defecto en una sola pasada.

```console
# setfacl -R -m u:carol:rX /srv/dac-lab/inbox
# setfacl -R -d -m u:carol:rX /srv/dac-lab/inbox
# getfacl -c /srv/dac-lab/inbox/inherited.txt | grep carol
user:carol:r--
# getfacl -c /srv/dac-lab/inbox/sub | grep carol
user:carol:r-x
default:user:carol:r-x
```

6. Quitá la ACL por defecto sin tocar la ACL de acceso.

```console
# setfacl -k /srv/dac-lab/inbox
# getfacl -c /srv/dac-lab/inbox | grep -c default
0
```

### Verificación de comprensión

- **Q6.1** En el paso 2, la umask era `077` y sin embargo el archivo salió `-rw-rw----`. Enunciá la regla de `acl(5)` que gobierna esto, y explicá por qué es una fuente frecuente de incidentes del tipo "nuestra línea base de endurecimiento no se está aplicando".
- **Q6.2** La ACL por defecto le otorgó a `carol` `rwx`, pero el archivo creado muestra `#effective:rw-`. ¿A dónde se fue la `x`? ¿Qué parámetro, provisto por qué llamada al sistema, lo limitó?
- **Q6.3** `inherited.txt` es un archivo y obtuvo solo una ACL de acceso; `sub` es un directorio y obtuvo tanto una ACL de acceso como una ACL por defecto. ¿Por qué la asimetría?
- **Q6.4** En el paso 4, revocar la entrada por defecto en el padre no tuvo efecto sobre el hijo existente. ¿Qué te dice esto sobre el orden correcto de operaciones al desplegar un cambio de permisos sobre un directorio de datos en vivo?
- **Q6.5** En el paso 5 se usó `rX` (X mayúscula) en lugar de `rx`. ¿Cuál es la diferencia, y por qué importa en una aplicación recursiva sobre un árbol que contiene tanto archivos como directorios?
- **Q6.6** Tenés que garantizar que *todo* lo que cualquier proceso escriba en `/srv/data` sea legible por el grupo `devops`. Compará el enfoque de directorio SGID con el de ACL por defecto: ¿qué garantiza realmente cada uno, y qué no garantiza cada uno?

---

## Ejercicio 7 — Atributos extendidos y espacios de nombres de atributos

### Pasos

1. Establecé y leé un atributo `user.*`.

```console
# cd /srv/dac-lab/project
# setfattr -n user.owner_team -v 'payments-sre' report.txt
# setfattr -n user.retention  -v '2555d'        report.txt
# getfattr -d report.txt
getfattr: Removing leading '/' from absolute path names
# file: report.txt
user.owner_team="payments-sre"
user.retention="2555d"
# getfattr -n user.owner_team --only-values report.txt; echo
payments-sre
```

2. Notá que `getfattr` por defecto solo mira el espacio de nombres `user.`. Ampliá el patrón.

```console
# getfattr -d -m '.*' report.txt
# file: report.txt
security.selinux="unconfined_u:object_r:unlabeled_t:s0"
user.owner_team="payments-sre"
user.retention="2555d"
```

3. Explorá los cuatro espacios de nombres y sus reglas de acceso.

```console
# setfattr -n trusted.audit_tag -v 'pci-dss' report.txt
# sudo -u carol setfattr -n trusted.audit_tag -v 'tampered' report.txt
setfattr: report.txt: Operation not permitted
# sudo -u carol getfattr -d -m '.*' report.txt
# file: report.txt
security.selinux="unconfined_u:object_r:unlabeled_t:s0"
user.owner_team="payments-sre"
user.retention="2555d"
# getfattr -d -m '.*' report.txt | grep trusted
trusted.audit_tag="pci-dss"
```

4. Leé la ACL a través de su almacén de respaldo `system.*`, y decodificala a mano.

```console
# setfacl -b report.txt
# chmod 640 report.txt
# setfacl -m u:carol:rw- report.txt
# id -u carol
1003
# getfattr -n system.posix_acl_access -e hex report.txt
# file: report.txt
system.posix_acl_access=0x0200000001000600ffffffff02000600eb03000004000400ffffffff10000600ffffffff20000000ffffffff
```

Decodificá, en little-endian, un encabezado de 4 bytes (`0x00000002` = `POSIX_ACL_XATTR_VERSION`) seguido de registros de 8 bytes con la forma `{u16 tag, u16 perm, u32 id}`:

| Bytes | Tag | Constante | Perm | id | Significado |
|---|---|---|---|---|---|
| `0100 0600 ffffffff` | `0x0001` | `ACL_USER_OBJ` | `6` = `rw-` | indefinido | `user::rw-` |
| `0200 0600 eb030000` | `0x0002` | `ACL_USER` | `6` = `rw-` | `0x3eb` = 1003 | `user:carol:rw-` |
| `0400 0400 ffffffff` | `0x0004` | `ACL_GROUP_OBJ` | `4` = `r--` | indefinido | `group::r--` |
| `1000 0600 ffffffff` | `0x0010` | `ACL_MASK` | `6` = `rw-` | indefinido | `mask::rw-` |
| `2000 0000 ffffffff` | `0x0020` | `ACL_OTHER` | `0` = `---` | indefinido | `other::---` |

> Tus bytes de `id` van a ser distintos. En algunas combinaciones de kernel y sistema de archivos, `system.posix_acl_access` no aparece en un listado con comodín `getfattr -m` pero sigue siendo legible por nombre explícito, como arriba.

5. Intentá escribir un atributo `user.*` donde el espacio de nombres está deshabilitado.

```console
# cp report.txt /srv/dac-plain/report.txt
# setfattr -n user.owner_team -v 'payments-sre' /srv/dac-plain/report.txt
setfattr: /srv/dac-plain/report.txt: Operation not supported
# setfacl -m u:carol:rw- /srv/dac-plain/report.txt
setfacl: /srv/dac-plain/report.txt: Operation not supported
```

6. Chocá contra el techo de tamaño de atributos de ext4. El error es la parte interesante.

```console
# setfattr -n user.blob -v "$(head -c 3000 /dev/zero | tr '\0' A)" report.txt && echo 'accepted'
accepted
# setfattr -n user.blob2 -v "$(head -c 8000 /dev/zero | tr '\0' B)" report.txt
setfattr: report.txt: No space left on device
# df -h /srv/dac-lab | tail -1
/dev/loop0  241M  2.1M  222M   1% /srv/dac-lab
# setfattr -x user.blob report.txt
```

7. Eliminá atributos y volcá/restaurá un árbol completo.

```console
# getfattr -R -d -m '.*' --absolute-names /srv/dac-lab/project > /var/tmp/project.xattr
# setfattr -x user.owner_team report.txt
# setfattr -x user.retention  report.txt
# getfattr -d report.txt
# setfattr --restore=/var/tmp/project.xattr
# getfattr -d report.txt
# file: report.txt
user.owner_team="payments-sre"
user.retention="2555d"
```

### Verificación de comprensión

- **Q7.1** Nombrá los cuatro espacios de nombres de atributos extendidos e indicá, para cada uno, quién puede leer y quién puede escribir.
- **Q7.2** ¿Por qué un `getfattr file` pelado no muestra nada en un archivo que demostrablemente tiene una etiqueta de SELinux?
- **Q7.3** En el paso 3, `carol` ni siquiera pudo *ver* `trusted.audit_tag`. Contrastá esto con `security.selinux`, que sí pudo ver. ¿Qué propiedad de diseño del espacio de nombres `trusted` ilustra esto, y nombrá un subsistema real que dependa de ella?
- **Q7.4** Las ACL POSIX se almacenan en `system.posix_acl_access`. ¿Por qué ese espacio de nombres no es escribible con `setfattr` ni siquiera como root en la mayoría de los kernels, y qué saldría mal si fuera libremente escribible?
- **Q7.5** En el paso 6, `df` reportó 222 MiB libres y el kernel igual devolvió `ENOSPC`. Explicá la restricción real en ext4 y nombrá la característica del sistema de archivos que la levanta.
- **Q7.6** Los atributos `user.*` no se pueden establecer sobre enlaces simbólicos ni sobre directorios que pertenecen a otro usuario cuando está puesto el bit sticky. ¿Cuál es el razonamiento detrás de cada restricción?
- **Q7.7** ¿Cuál de estos *no* se almacena como atributo extendido: capacidades de archivo, contexto de SELinux, ACL POSIX, el bit SUID, medición IMA?

---

## Ejercicio 8 — Preservar metadatos DAC a través de copia, archivado y migración

### Pasos

1. Construí un archivo de referencia que lleve todo: modo, ACL y xattrs.

```console
# cd /srv/dac-lab/project
# chown root:devops report.txt ; chmod 640 report.txt
# setfacl -m u:carol:rw-,g:payroll:r-- report.txt
# setfattr -n user.owner_team -v 'payments-sre' report.txt
# ls -l report.txt
-rw-rw----+ 1 root devops 3030 Aug 24 11:31 report.txt
```

2. Copiá con tres conjuntos de flags distintos y compará qué sobrevive.

```console
# mkdir -p /srv/dac-lab/copies
# cp                  report.txt /srv/dac-lab/copies/plain.txt
# cp -p               report.txt /srv/dac-lab/copies/preserve-p.txt
# cp --preserve=all   report.txt /srv/dac-lab/copies/preserve-all.txt

# for f in /srv/dac-lab/copies/*; do
>   printf '=== %s\n' "$f"
>   getfacl -c "$f" 2>/dev/null | grep -E 'carol|payroll' || echo '  (no extended ACL)'
>   getfattr --only-values -n user.owner_team "$f" 2>/dev/null && echo || echo '  (no user xattr)'
> done
=== /srv/dac-lab/copies/plain.txt
  (no extended ACL)
  (no user xattr)
=== /srv/dac-lab/copies/preserve-all.txt
user:carol:rw-
group:payroll:r--
payments-sre
=== /srv/dac-lab/copies/preserve-p.txt
user:carol:rw-
group:payroll:r--
  (no user xattr)
```

3. Copiá al sistema de archivos mutilado y leé los diagnósticos.

```console
# cp --preserve=all report.txt /srv/dac-plain/report2.txt
cp: preserving permissions for '/srv/dac-plain/report2.txt': Operation not supported
cp: setting attribute 'user.owner_team' for '/srv/dac-plain/report2.txt': Operation not supported
# cp -a report.txt /srv/dac-plain/report3.txt
# ls -l /srv/dac-plain/report3.txt
-rw-r-----. 1 root devops 3030 Aug 24 11:31 /srv/dac-plain/report3.txt
```

4. Archivá con `tar` y confirmá que los flags no son opcionales.

```console
# tar -cf /var/tmp/naive.tar   -C /srv/dac-lab project
# tar --acls --xattrs --xattrs-include='*' -cf /var/tmp/full.tar -C /srv/dac-lab project
# mkdir -p /srv/dac-lab/restore-naive /srv/dac-lab/restore-full
# tar -xf /var/tmp/naive.tar -C /srv/dac-lab/restore-naive
# tar --acls --xattrs --xattrs-include='*' -xf /var/tmp/full.tar -C /srv/dac-lab/restore-full
# getfacl -c /srv/dac-lab/restore-naive/project/report.txt | grep -c carol
0
# getfacl -c /srv/dac-lab/restore-full/project/report.txt | grep -c carol
1
# getfattr --only-values -n user.owner_team /srv/dac-lab/restore-full/project/report.txt; echo
payments-sre
```

5. La misma prueba con `rsync`.

```console
# rsync -a   /srv/dac-lab/project/ /srv/dac-lab/rsync-a/
# rsync -aAX /srv/dac-lab/project/ /srv/dac-lab/rsync-aAX/
# getfacl -c /srv/dac-lab/rsync-a/report.txt   | grep -c carol
0
# getfacl -c /srv/dac-lab/rsync-aAX/report.txt | grep -c carol
1
```

6. Confirmá que `mv` dentro de un mismo sistema de archivos preserva todo, porque es un `rename(2)`.

```console
# mv report.txt report-renamed.txt
# getfacl -c report-renamed.txt | grep -c -E 'carol|payroll'
2
# getfattr --only-values -n user.owner_team report-renamed.txt; echo
payments-sre
# mv report-renamed.txt report.txt
```

### Verificación de comprensión

- **Q8.1** `cp -p` mantuvo la ACL pero descartó el atributo `user.*`. ¿Qué clases de atributos cubre `--preserve=mode`, y qué flag hace falta para el resto?
- **Q8.2** En el paso 3, `cp --preserve=all` imprimió dos errores mientras que `cp -a` no imprimió ninguno, y ambos produjeron el mismo archivo degradado. ¿Por qué el flag más cómodo oculta la falla, y cuál es la consecuencia operativa durante una migración de datos?
- **Q8.3** Un script de migración usa `tar -cf` sobre un volumen de origen donde la autorización depende de ACL. La restauración parece completa — misma cantidad de archivos, mismos conteos de bytes, `md5sum` coincide. ¿Qué se perdió silenciosamente, y qué único paso de verificación lo habría detectado?
- **Q8.4** `rsync -a` *no* implica `-A -X`. Dá la razón por la que ese es el valor por defecto correcto desde el punto de vista de rsync, y enunciá el conjunto de flags que estandarizarías para una migración de servidor Linux a Linux.
- **Q8.5** `mv` preservó todos los atributos en el paso 6 sin ningún flag. ¿Seguiría siendo cierto si el destino fuera `/srv/dac-plain`? Explicá qué hace `mv` cuando `rename(2)` devuelve `EXDEV`.
- **Q8.6** ¿Cuáles de `install -m 0640`, `cp -a`, `git checkout` y `rpm -i` reproducirán la ACL de un archivo en el host destino? Justificá cada respuesta.

---

## Ejercicio 9 — Diagnóstico: cuatro fallas que se ven idénticas

Cada escenario de abajo reproduce un "Permission denied" real con una causa raíz distinta. Reproducilo, diagnosticalo con herramientas, y después arreglalo.

### Pasos

1. **Membresía de grupo obsoleta.** Agregá `carol` a `devops` y mostrá que una sesión existente no se ve afectada.

```console
# usermod -aG devops carol
# id carol
uid=1003(carol) gid=1003(carol) groups=1003(carol),1004(devops)
# sudo -u carol id -nG            # fresh process: sees the new group
carol devops
```

Simulá una sesión de larga vida anterior al cambio:

```console
# setsid --fork sleep 600 &
# grep Groups /proc/$(pgrep -n sleep)/status
Groups: 0
```

2. **La mask, no el grupo.** Reconstruí la trampa de la mask y diagnosticala correctamente.

```console
# cd /srv/dac-lab/project
# setfacl -b report.txt ; chmod 640 report.txt
# setfacl -m u:carol:rw- report.txt ; chmod g=r report.txt
# ls -l report.txt
-rw-r-----+ 1 root devops 3030 Aug 24 11:52 report.txt
# sudo -u carol sh -c 'echo x >> report.txt'
sh: line 1: report.txt: Permission denied
# getfacl -c report.txt
user::rw-
user:carol:rw-			#effective:r--
group::r--
mask::r--
other::---
# setfacl -m m::rw- report.txt
# sudo -u carol sh -c 'echo x >> report.txt' && echo FIXED
FIXED
```

3. **Un directorio padre en la ruta.** Rompé el atravesamiento tres niveles más arriba.

```console
# chmod 750 /srv/dac-lab
# sudo -u carol cat /srv/dac-lab/project/report.txt
cat: /srv/dac-lab/project/report.txt: Permission denied
# namei -om /srv/dac-lab/project/report.txt
f: /srv/dac-lab/project/report.txt
 drwxr-xr-x root root /
 drwxr-xr-x root root srv
 drwxr-x--- root root dac-lab
 drwxr-xr-x root root project
 -rw-rw----+ root devops report.txt
# chmod 755 /srv/dac-lab
# sudo -u carol cat /srv/dac-lab/project/report.txt >/dev/null && echo FIXED
FIXED
```

4. **Una opción de montaje, no un permiso.** Mostrá que el modo es irrelevante cuando el sistema de archivos se niega.

```console
# mount -o remount,nosuid /srv/dac-lab
# ls -l /srv/dac-lab/project/idcopy
-rwxr-xr-x. 1 alice root 39784 Aug 24 10:30 /srv/dac-lab/project/idcopy
# chown root:root /srv/dac-lab/project/idcopy ; chmod 4755 /srv/dac-lab/project/idcopy
# sudo -u carol /srv/dac-lab/project/idcopy
uid=1003(carol) gid=1003(carol) groups=1003(carol),1004(devops)
# mount -o remount,suid /srv/dac-lab
# sudo -u carol /srv/dac-lab/project/idcopy
uid=1003(carol) gid=1003(carol) euid=0(root) groups=1003(carol),1004(devops)
```

5. **La escalera de escalamiento genérica.** Corré esta lista de control contra cualquier denegación de DAC.

```console
# ls -l   <file>                  # mode, owner, group, and the '+' / '.' marker
# getfacl <file>                  # extended entries and #effective:
# namei -om <path>                # every component of the path
# findmnt -no OPTIONS -T <path>   # ro, nosuid, noexec, noacl, nouser_xattr
# id <user>                       # groups as currently defined
# grep Groups /proc/<pid>/status  # groups as the running process sees them
# ausearch -m AVC -ts recent      # if the answer is "SELinux", not DAC
```

### Verificación de comprensión

- **Q9.1** En el paso 1, `id carol` y `/proc/<pid>/status` no coinciden. ¿Cuál describe lo que el kernel va a aplicar para ese proceso, y por qué? Nombrá dos maneras de obtener el grupo nuevo sin un logout completo.
- **Q9.2** En el paso 2, ¿cuál única línea de la salida de `getfacl` es el diagnóstico? ¿Por qué `ls -l` es activamente engañoso acá?
- **Q9.3** `namei -om` en el paso 3 mostró que la falla estaba dos directorios por encima del objetivo. Escribí la regla, en una oración, sobre cómo el kernel recorre una ruta.
- **Q9.4** En el paso 4 el bit SUID estaba presente y el binario pertenecía a root, y sin embargo no hubo escalada. ¿Qué capa anuló a DAC, y dónde mirarías primero si un `sudo` de producción dejara de elevar de golpe?
- **Q9.5** Una denegación persiste aunque `ls -l`, `getfacl`, `namei` y `findmnt` están todos limpios, y el proceso corre como `root`. Nombrá tres mecanismos fuera de DAC que igual pueden denegar la operación, y el comando que identifica a cada uno.

---

## Limpieza

```console
# umount /srv/dac-lab /srv/dac-plain
# rmdir  /srv/dac-lab /srv/dac-plain
# rm -f  /var/tmp/dac-lab.img /var/tmp/dac-plain.img
# rm -f  /var/tmp/project.acl /var/tmp/project.xattr /var/tmp/naive.tar /var/tmp/full.tar
# userdel -r alice ; userdel -r bob ; userdel -r carol
# groupdel devops  ; groupdel payroll
```

---

## Referencias

- LPI, *Exam 303 Objectives (303-300)* — <https://www.lpi.org/our-certifications/exam-303-objectives/>
- `acl(5)` — semántica de ACL POSIX, mask, herencia de ACL por defecto, interacción con la umask — <https://man7.org/linux/man-pages/man5/acl.5.html>
- `setfacl(1)` — <https://man7.org/linux/man-pages/man1/setfacl.1.html> · `getfacl(1)` — <https://man7.org/linux/man-pages/man1/getfacl.1.html>
- `xattr(7)` — espacios de nombres y sus reglas de acceso — <https://man7.org/linux/man-pages/man7/xattr.7.html>
- `setfattr(1)` — <https://man7.org/linux/man-pages/man1/setfattr.1.html> · `getfattr(1)` — <https://man7.org/linux/man-pages/man1/getfattr.1.html>
- `inode(7)` — disposición de la palabra de modo, semántica de SUID/SGID/sticky — <https://man7.org/linux/man-pages/man7/inode.7.html>
- `path_resolution(7)` — reglas de atravesamiento de directorios — <https://man7.org/linux/man-pages/man7/path_resolution.7.html>
- `umask(2)` — <https://man7.org/linux/man-pages/man2/umask.2.html> · `open(2)` — <https://man7.org/linux/man-pages/man2/open.2.html>
- `chown(2)` — limpieza de SUID/SGID y capacidades al cambiar la propiedad — <https://man7.org/linux/man-pages/man2/chown.2.html>
- `chmod(1)` — <https://man7.org/linux/man-pages/man1/chmod.1.html>
- `ext4(5)` — opciones de montaje `acl`/`noacl`, `user_xattr`/`nouser_xattr` — <https://man7.org/linux/man-pages/man5/ext4.5.html>
- Documentación del kernel Linux, *ext4 Data Structures and Algorithms* (atributos extendidos, `ea_inode`) — <https://www.kernel.org/doc/html/latest/filesystems/ext4/index.html>
- Manual de GNU coreutils, invocación de `cp` (`--preserve`, diagnósticos reducidos de `-a`) — <https://www.gnu.org/software/coreutils/manual/html_node/cp-invocation.html>
- `capabilities(7)` — capacidades de archivo como alternativa a SUID — <https://man7.org/linux/man-pages/man7/capabilities.7.html>
- `mount(8)` — `nosuid`, `noexec`, `ro` — <https://man7.org/linux/man-pages/man8/mount.8.html>

---

<details>
<summary><strong>Clave de respuestas — clic para desplegar</strong></summary>

### Ejercicio 0 — Entorno de laboratorio

**Q0.1** No. Las ACL están habilitadas. `/proc/self/mounts` y `findmnt` imprimen únicamente las opciones que *difieren del valor por defecto del kernel* para ese sistema de archivos, más las opciones que el VFS rastrea de forma genérica. Para ext4 en los kernels actuales, `acl` y `user_xattr` son los valores por defecto compilados, así que son invisibles; `noacl` y `nouser_xattr` son desviaciones y por lo tanto se imprimen. **Regla general: la ausencia de una opción en la lista de montaje significa "por defecto", no "apagado".** Para conocer el estado real hay que conocer los valores por defecto del sistema de archivos, o probarlo empíricamente (`setfacl` sobre un archivo descartable).

**Q0.2** Viven en capas distintas. `ext_attr` en `Filesystem features` es una **bandera de formato en disco** en el superbloque: la disposición de metadatos del sistema de archivos es capaz de almacenar atributos extendidos, en absoluto. `Default mount options` es un campo del superbloque escrito por `mkfs`/`tune2fs -o` que provee opciones *de tiempo de montaje* por defecto, que el kernel fusiona con lo que sea que especifique `mount -o`. Un sistema de archivos puede tener `ext_attr` en disco y aun así estar montado como `nouser_xattr` — la capacidad existe, la política la niega.

**Q0.3** En orden:
1. **Tipo y formato del sistema de archivos** — ¿soporta ACL, en absoluto? (`tune2fs -l`, o el propio tipo de fs: FAT/exFAT/NTFS-3G sin opciones especiales, y `tmpfs` antiguo, no lo hacen.)
2. **Opciones de montaje** — `findmnt -no OPTIONS -T <path>`, buscando `noacl` y `ro`.
3. **Compilación del kernel** — `CONFIG_EXT4_FS_POSIX_ACL` / `CONFIG_FS_POSIX_ACL`, vía `zgrep POSIX_ACL /proc/config.gz` o `grep POSIX_ACL /boot/config-$(uname -r)`.
Recién después de las tres se vuelve plausible "la herramienta está rota". Un cuarto candidato, no-DAC: la operación está siendo bloqueada por SELinux/AppArmor, que reporta valores de errno distintos pero suele malinterpretarse.

### Ejercicio 1 — Propiedad y la palabra de modo

**Q1.1** `0x81a4` = `0o100644`. Los bits superiores `0o100000` (`S_IFREG`) son el **tipo de archivo**, tomados con la máscara `S_IFMT` `0o170000`. Los 12 bits inferiores `0o0644` son la **palabra de permisos**: 3 bits especiales (SUID `04000`, SGID `02000`, sticky `01000`) más las tres tríadas rwx. `%A` renderiza el tipo como el carácter inicial de `-rw-r--r--`; `%a` imprime solo los 12 bits bajos.

**Q1.2** `+` y `-` son operadores **relativos**: agregan o quitan los bits nombrados y dejan intacto todo lo demás en esa tríada — `g+w` sobre `640` puso solo el bit de escritura de grupo, dando `660`. `=` es una **asignación absoluta** para las tríadas que nombra: `o=r` puso la tríada *entera* de otros en `r--`, lo que agregó `r` y habría limpiado cualquier `w`/`x` que hubiera ahí. Consecuencia en la práctica: `chmod g+w` es seguro en un script que no debe perturbar el estado existente; `chmod g=w` es una revocación silenciosa de lectura y ejecución para el grupo.

**Q1.3** El **bit de escritura sobre el directorio** `locked`, combinado con su bit de ejecución (`chmod 777`). `unlink(2)` modifica la lista de nombres del directorio; nunca toca los permisos del inodo objetivo. Por esto existe el bit sticky (Ejercicio 4) y por esto "el archivo está en `chmod 000`" no es una defensa contra el borrado.

**Q1.4** Cambió el modo del **objetivo** (`report.txt`), porque `chmod(2)` sigue los enlaces simbólicos y `chmod(1)` no tiene `-h`. En Linux, los bits de modo de los enlaces simbólicos se almacenan pero **nunca se consultan** — siempre se muestran como `lrwxrwxrwx` y carecen de significado; el permiso sobre un enlace simbólico lo deciden el directorio que lo contiene y el objetivo. Por esta razón no hay `lchmod(2)` en glibc en Linux (algunos otros Unix la tienen y sí honran los modos de los enlaces). `chown` *sí* tiene `-h` porque la propiedad de un enlace simbólico sí es significativa: la revisa la regla del bit sticky al desenlazar.

**Q1.5** El kernel evalúa **exactamente una tríada** y se detiene. El orden es: si el UID efectivo coincide con el propietario → se usa la tríada del propietario, definitivo. Si no, si el GID efectivo o cualquier grupo suplementario coincide con el grupo del archivo → se usa la tríada del grupo, definitivo. Si no → otros. Como `alice` es la propietaria, le toca la tríada del propietario. Si la tríada del propietario es `---` y la del grupo es `rw-`, a `alice` se le **deniega**, pese a estar en `devops` — la tríada de grupo nunca se consulta para ella. Los no-propietarios que estén en `devops` obtienen `rw-`. Esta regla de "gana la primera coincidencia, no hay acumulación" es el error conceptual más común sobre los permisos Unix.

### Ejercicio 2 — Resolución de rutas

**Q2.1** Sobre un directorio: `r` otorga el derecho a **enumerar los nombres** que contiene (`readdir`, es decir `ls`). `x` — el bit de *búsqueda* — otorga el derecho a **resolver un nombre a través de él** (`stat`, `open`, `cd`, y usarlo como componente de cualquier ruta más larga). Son independientes. `r` sin `x` te da nombres que no podés usar; `x` sin `r` te da un directorio donde tenés que conocer de antemano el nombre para llegar al archivo.

**Q2.2** Con `r` pero sin `x`, `ls` puede llamar a `getdents` para obtener los nombres pero no puede hacer `stat` de cada entrada — cada `stat` necesita permiso de búsqueda sobre el directorio contenedor. `ls -l` por lo tanto imprime el nombre que conoce y `?` para cada campo que habría venido del inodo, usando `d` solamente porque `getdents` devuelve un tipo de archivo grueso desde la propia entrada de directorio (`d_type`).

**Q2.3** `711` sobre un directorio home permite que cualquier usuario **lo atraviese** — así que `/home/alice/public_html/index.html` sigue funcionando para el servidor web o para una búsqueda de `~alice/.ssh/authorized_keys` — mientras impide que nadie **liste** su contenido. No es confidencialidad: un atacante que adivine o fuerce por fuerza bruta un nombre de archivo lo obtiene. `750` (legible por el grupo, nada para el mundo) se prefiere cuando ningún servicio necesita atravesamiento a ciegas, porque elimina incluso el canal de adivinanza; el valor por defecto moderno estándar (`HOME_MODE 0700` en `/etc/login.defs`) elimina también el acceso de grupo.

**Q2.4** `ls -l index.html` muestra los permisos de un solo inodo. `namei -om` recorre e imprime el modo, propietario y grupo de **cada componente de la ruta** — `/`, `srv`, `app`, `public`, `index.html` — más la resolución de enlaces simbólicos y los puntos de montaje. El 403 casi siempre viene de una `x` faltante en un directorio intermedio (frecuentemente `/srv/app` creado como `750 root:root`), lo cual ninguna inspección del archivo hoja va a revelar.

### Ejercicio 3 — umask

**Q3.1** Porque la máscara no elige los permisos — solo *quita* bits de lo que pide el programa que crea. `open(2)` con `O_CREAT` pide por convención el modo `0666` (nunca ejecución) y `mkdir(2)` pide `0777` (la ejecución hace falta para atravesar). `0666 & ~0077 = 0600`; `0777 & ~0077 = 0700`.

**Q3.2** A nivel de bits, no aritmética: `mode & ~umask`. La distinción importa porque la resta da respuestas incorrectas cada vez que la máscara quita un bit que el modo nunca tuvo. Ejemplo: modo `0666`, umask `0033`. A nivel de bits: `0666 & ~0033 = 0644`. La resta aritmética daría `0633`.

**Q3.3** Porque la umask restringe el modo solicitado, y distintos programas solicitan modos distintos. `touch` llama a `open(..., 0666)` → `0644`. Un enlazador/compilador llama a `open(..., 0777)` para una salida que pretende que sea ejecutable → `0755`. La umask es idéntica en ambos casos; lo que difiere es la *solicitud*. Por la misma razón `install -m 0755` y `mkdir` producen resultados ejecutables mientras que la redirección con `>` nunca lo hace.

**Q3.4** (a) **cron no ejecuta el profile de tu shell de login.** `crond` arranca trabajos desde un entorno mínimo; `~/.bashrc`/`~/.profile` — donde suele vivir un `umask 007` interactivo — no se carga, así que el trabajo hereda la umask de `crond`, típicamente `022`. Solución: establecer la umask explícitamente dentro del trabajo o del script (`umask 007` como primera línea), o usar un timer de systemd con `UMask=0007` en la unidad de servicio. (b) **La umask está establecida en una ruta solo-interactiva.** Muchas distribuciones protegen `~/.bashrc` con un `case $- in *i*) ;; *) return;; esac` temprano, así que los shells no interactivos se saltean todo lo que viene después. Solución: poner la llamada a `umask` antes de esa guarda, o mejor, establecerla declarativamente en la unidad/crontab en lugar de en un archivo rc de shell. Una tercera causa, menos común: una ACL por defecto en el directorio destino que anula la umask por completo (Ejercicio 6).

**Q3.5** El supuesto es el esquema de **grupo privado de usuario**: cada usuario tiene un grupo primario que contiene solo a sí mismo (`alice:alice`), así que los bits de grupo no le otorgan acceso a nadie más que al usuario. Bajo ese supuesto `002` no cuesta nada y hace que los directorios colaborativos SGID funcionen naturalmente. Falla en el momento en que el grupo primario de un usuario es un grupo **compartido** — un grupo `users` heredado, un grupo primario proveniente de LDAP/AD como `Domain Users`, o una cuenta de servicio puesta deliberadamente en un grupo compartido. Entonces `umask 002` hace que cada archivo que ese usuario cree sea escribible por todo el grupo, en todo el sistema. Verificalo con `awk -F: '$4 < 1000 || $3 != $4' /etc/passwd` y revisando el mapeo de grupo primario del servicio de directorio antes de habilitar `USERGROUPS_ENAB`.

### Ejercicio 4 — SUID, SGID, sticky

**Q4.1** El bit especial se muestra **en la posición del bit de ejecución correspondiente**, y su caso reporta si ese bit de ejecución también está puesto:

| Visualización | Bit especial | Bit de ejecución | Significado |
|---|---|---|---|
| `-rws------` | SUID | puesto | funciona: se ejecuta con el UID del propietario |
| `-rwS------` | SUID | sin poner | puesto pero inerte — no hay nada que ejecutar |
| `----rws---` | SGID | puesto | se ejecuta con el grupo del archivo |
| `----rwS---` | SGID (en un archivo) | sin poner | en un *archivo*: inerte. En un *directorio*: normal y significativo — herencia de grupo, sin búsqueda de grupo |
| `drwxrwxrwt` | sticky | `o+x` puesto | borrado restringido, atravesable por todos |
| `drwxrwxrwT` | sticky | `o+x` sin poner | borrado restringido, los otros no pueden atravesar |

Minúscula = bit especial **y** bit de ejecución. Mayúscula = bit especial **sin** bit de ejecución. El caso no obvio importante es `drwxr-S---` en un directorio, que es perfectamente normal: SGID en directorios no tiene nada que ver con la ejecución.

**Q4.2** Para un llamante sin privilegios, `chown(2)` debe limpiar SUID/SGID o la llamada sería una escalada trivial: crear un archivo, hacerlo SUID, y después dárselo a root. `notify_change()` de Linux aplica `ATTR_KILL_SUID`/`ATTR_KILL_SGID` al cambiar la propiedad de un archivo regular (SGID solo cuando el bit de ejecución de grupo está puesto, para que la codificación de bloqueo obligatorio `-rw-r-Sr--` sobreviva). POSIX deja explícitamente el caso **privilegiado** como definido por la implementación, y el comportamiento de Linux ha variado entre versiones. Por lo tanto: **nunca trates a `chown` como preservador de atributos.** Reaplicá siempre el modo después. Por esto RPM `%attr(4755,root,root)` e `install -m 4755 -o root` establecen propiedad y modo como una única operación especificada en lugar de depender del orden. El mismo evento también limpia `security.capability` — para *cualquier* llamante, root incluido — así que las capacidades de archivo se pierden con `chown` y con cualquier escritura al archivo.

**Q4.3** La ruta de `execve` del kernel maneja `#!` en `fs/binfmt_script.c`: reapunta la ejecución al **intérprete** y pasa el script como argumento. El bit SUID pertenece al inodo del script, no al del intérprete, y honrarlo significaría entregarle a un intérprete privilegiado una lista de argumentos, un entorno y una ventana de carrera de `/dev/fd` controlados por el atacante. Linux por lo tanto ignora SUID/SGID en scripts incondicionalmente. Alternativas, la mejor primero: (1) `sudo` con una entrada precisa de `Cmnd_Alias` y `NOPASSWD`, que es auditable y da política por comando; (2) una **capacidad de archivo** sobre un helper compilado pequeño (`setcap cap_net_bind_service+ep`), otorgando un privilegio en lugar de todo root; (3) una unidad de `systemd` con el privilegio y un disparador por socket o D-Bus; (4) un **wrapper SUID en C** mínimo que sanitice `PATH`/`IFS`/entorno y haga `execve` de una ruta absoluta — la respuesta tradicional, y la más fácil de hacer mal.

**Q4.4** El **bit SGID sobre el directorio** (el `2` en `chmod 2770`). Hace que las entradas nuevas hereden el grupo del directorio en lugar del grupo primario del creador — esto es lo que hace que los directorios de proyecto compartidos funcionen sin que cada usuario tenga que hacer `newgrp`. `subdir` heredó adicionalmente el **propio bit SGID** (`drwxr-s`), de modo que el comportamiento se propaga recursivamente hacia abajo en los subárboles nuevos. Los archivos regulares no heredan el bit, solo el grupo. Notá lo que SGID *no* hace: no toca los bits de permiso, así que `from-alice` salió `644` (por la umask `022`) — el grupo `devops` obtiene lectura pero no escritura. Garantizar la *escritura* de grupo requiere o bien una umask `002` o bien una ACL por defecto.

**Q4.5** El bit sticky sobre un directorio restringe **`unlink(2)`, `rmdir(2)` y `rename(2)`** de las entradas que contiene a: el propietario del archivo, el propietario del directorio, o un proceso con `CAP_FOWNER`. Eso es todo. No dice nada sobre el contenido del propio archivo: `bob` tenía `w` sobre `alice.tmp` vía la tríada de otros (`644`), así que `open(O_TRUNC)` y escribir estaban permitidos por el DAC ordinario. El bit sticky protege el **espacio de nombres**, no los **datos**. Consecuencia práctica: un directorio sticky escribible por todos igual permite la destrucción de contenido; si eso importa, arreglá los modos de los archivos o la umask, no el bit del directorio.

**Q4.6** Para `find -perm`:
- `-perm 4755` — coincidencia **exacta** de toda la palabra de permisos de 12 bits. `-rwsr-sr-x` no coincidiría.
- `-perm -4000` — **todos** los bits listados están puestos (AND). `-perm -6000` significa SUID **y** SGID juntos.
- `-perm /6000` — **cualquiera** de los bits listados está puesto (OR). Esta es la forma correcta para "encontrar todo lo que sea SUID o SGID". (La sintaxis obsoleta `+` significaba lo mismo y se eliminó en GNU findutils 4.5.12.)
Usá además `-xdev` para quedarte en un solo sistema de archivos, y recordá que `-perm -4000` por sí solo va a coincidir con directorios y enlaces simbólicos — agregá `-type f` para una auditoría SUID con sentido.

**Q4.7** Más allá de `mount -o nosuid` (por sistema de archivos — revisá `findmnt -no OPTIONS -T <path>` y `/etc/fstab`):
- **Namespaces/contenedores** — los archivos en un namespace de usuario mapeado sin el privilegio correspondiente, y todo montaje dentro de un namespace de usuario sin privilegios, son implícitamente `nosuid`.
- **`no_root_squash`/`root_squash` en NFS**, más la opción de exportación `nosuid` del lado del servidor.
- **Política MAC** — SELinux puede denegar la transición `execute_no_trans`/de dominio incluso donde DAC la permite; el síntoma es idéntico.
- **Que el bit haya sido despojado** por un `chown` previo o por una corrida de paquetes o de gestión de configuración (Q4.2).
- Los sysctls **`fs.suid_dumpable` / `fs.protected_*`** no deshabilitan SUID pero cambian comportamientos adyacentes y vale la pena revisarlos durante el triage.

### Ejercicio 5 — ACL POSIX y la mask

**Q5.1** Seis tipos:

| Entrada | Forma textual | Notas |
|---|---|---|
| `ACL_USER_OBJ` | `user::rwx` | el propietario. **Obligatoria.** |
| `ACL_USER` | `user:name:rwx` | un usuario nombrado. Cero o más. |
| `ACL_GROUP_OBJ` | `group::rwx` | el grupo propietario. **Obligatoria.** |
| `ACL_GROUP` | `group:name:rwx` | un grupo nombrado. Cero o más. |
| `ACL_MASK` | `mask::rwx` | **Obligatoria** si existe alguna entrada nombrada. |
| `ACL_OTHER` | `other::rwx` | todos los demás. **Obligatoria.** |

Una ACL *mínima* es exactamente `user::`, `group::`, `other::` — precisamente la palabra de modo clásica, y por eso todo archivo tiene una ACL incluso cuando `ls -l` no muestra ningún `+`. Una ACL que contiene al menos una entrada nombrada (o una mask) es una ACL *extendida* y recibe el marcador `+`.

**Q5.2** La mask es una cota superior sobre **todos los usuarios nombrados (`ACL_USER`), todos los grupos nombrados (`ACL_GROUP`) y el grupo propietario (`ACL_GROUP_OBJ`)** — colectivamente, la "clase de grupo". Permiso efectivo = entrada ∧ mask. Inmunes: **`user::` (el propietario)** y **`other::`**. Por esto no podés dejar al propietario afuera con una mask, y por esto apretar la mask nunca afecta el acceso del mundo.

**Q5.3** El campo de grupo de `ls -l` muestra la **mask**, no `group::`, siempre que haya una ACL extendida presente — así que `rw-` era el techo de la clase de grupo, mientras que `group::` en sí seguía siendo `r--`, y a `bob` solo se lo evalúa contra `group::`. En una oración: *en un archivo con `+`, la tríada del medio de `ls -l` es la mask, así que muestra el máximo que podría tener cualquier entrada de la clase de grupo, no lo que el grupo propietario realmente tiene.*

**Q5.4** En un archivo con ACL extendida, `chmod` establece `user::` a partir del dígito del propietario, **`mask::` a partir del dígito del grupo**, y `other::` a partir del dígito de otros; `group::` queda intacto. Como la mask acota cada entrada nombrada, un solo `chmod` puede revocar acceso a usuarios que no están mencionados en ninguna parte del comando `chmod`. El riesgo operativo: **cualquier herramienta que imponga un modo de forma idempotente — Ansible `file: mode=0640`, Puppet `file { mode => }`, un `chmod -R` en un script de despliegue, `rpm --setperms`, playbooks de endurecimiento adyacentes a `restorecon` — va a despojar silenciosamente los otorgamientos de ACL en cada corrida**, produciendo una interrupción intermitente que reaparece en cada convergencia. Detección: `getfacl -R -s` antes y después, o estar atento a la aparición de líneas `#effective:`.

**Q5.5** `#effective:` se imprime cuando los permisos **otorgados** de una entrada exceden lo que la mask permite; muestra la intersección que efectivamente se aplica. Nunca aparece en `user::` porque `ACL_USER_OBJ` no está en la clase de grupo y no está sujeta a la mask (lo mismo para `other::`). Regla de lectura: si ves `#effective:` en algún lado, tu problema es la mask, no el otorgamiento individual.

**Q5.6**
- `setfacl -x u:carol file` — elimina **una entrada específica**; el resto de la ACL, incluidas otras entradas nombradas y la mask, sobrevive (la mask se recalcula).
- `setfacl -b file` (`--remove-all`) — elimina **todas las entradas de acceso extendidas**, dejando solo las tres entradas base. El archivo pierde su `+`. Las ACL por defecto se *conservan*.
- `setfacl -k dir` (`--remove-default`) — elimina **solo la ACL por defecto**. La ACL de acceso queda intacta. Carece de sentido en objetos que no son directorios.
Combinalos con `-R` para recursión; `setfacl -R -b -k` es el reseteo completo de un árbol.

**Q5.7** (a) La **mask** es más restrictiva que el otorgamiento — buscá `#effective:` en `getfacl`. (b) Crear un archivo necesita **`w` *y* `x` sobre el directorio** (`x` para resolver nombres dentro de él); una ACL de `rw-` otorga escritura pero no búsqueda, así que `open(O_CREAT)` falla. Otorgá `rwx`. Dos candidatos adicionales dignos de revisar: una `x` faltante en un directorio ancestro (`namei -om`), y un montaje de solo lectura o `noacl`.

**Q5.8** `find -perm` solo puede evaluar la **palabra de modo**, y en un archivo con ACL el campo de grupo de la palabra de modo es la *mask* — así que `find -perm -g+w` a la vez se pierde otorgamientos que existen solo como entradas nombradas y produce falsos positivos por una mask permisiva. `getfacl -R -s` (`--skip-base`) recorre el árbol y emite salida **solo para objetos con una ACL no trivial**, que es exactamente el conjunto que una auditoría basada en modo no puede ver. Notá que GNU `find` no tiene un predicado `-acl` (ese es el `find` de FreeBSD); `getfacl -R -s -p` es el idioma portable en Linux.

### Ejercicio 6 — ACL por defecto y herencia

**Q6.1** De `acl(5)`: *si un directorio tiene asociada una ACL por defecto, el parámetro de modo pasado por la llamada de creación y la ACL por defecto del directorio determinan la ACL del objeto nuevo — la máscara de creación de archivos del proceso **no** se usa.* Si no existe una ACL por defecto, la umask se aplica como siempre. Así que una ACL por defecto **anula completamente la umask** para ese directorio. Este es el mecanismo detrás de los incidentes donde se despliega una línea base de endurecimiento `umask 077` en toda la flota y las auditorías igual encuentran archivos legibles por el grupo: algún directorio de datos lleva una ACL por defecto, y ninguna política de umask va a afectarlo. Detectalo con `getfacl -R -s | grep default`.

**Q6.2** `touch` llama a `open(..., O_CREAT, 0666)`. El paso 2 del algoritmo de herencia interseca **las entradas correspondientes a las tríadas de la palabra de modo** — `user::`, `mask::` (que hace las veces de la tríada de grupo porque existe una mask) y `other::` — con ese modo. La tríada de grupo de `0666` es `rw-`, así que `mask::` quedó en `rw-`, y el otorgamiento `rwx` de `carol` queda acotado a `#effective:rw-`. La entrada nombrada en sí sigue registrando `rwx`; solo se reduce su valor efectivo. Notá que el otorgamiento *no* se reescribe: subir la mask después (`setfacl -m m::rwx`) restaura la `x` sin volver a otorgarla.

**Q6.3** Una ACL por defecto es metadato de *plantilla* de herencia, y solo los directorios pueden tener hijos. Los archivos llevan solo una ACL de acceso. Cuando se crea un directorio dentro de un directorio con ACL por defecto, recibe **dos** ACL: una ACL de acceso (derivada de la del padre por defecto, intersecada con el `0777` de `mkdir`) y una copia de la ACL por defecto del padre, para que la regla siga propagándose. Un archivo recibe solo la ACL de acceso derivada, y la propagación se detiene ahí. `setfacl -d` sobre un archivo regular es un error, como muestra el paso 1.

**Q6.4** Las ACL por defecto se evalúan **una sola vez, en el momento de creación**. Son una plantilla, no un vínculo de herencia vivo — nada parecido a un ACE heredado de Windows que se reevalúa. Orden de despliegue correcto para un directorio de datos en vivo: **(1)** actualizar la ACL por defecto para que los objetos futuros sean correctos, y después **(2)** aplicar la ACL de acceso equivalente de forma recursiva (`setfacl -R -m`) para arreglar todo lo que ya existe. Hacer solo (1) deja un conjunto de archivos heredados que se achica siempre pero nunca desaparece; hacer solo (2) significa que el próximo archivo creado reintroduce el problema. Ambos son necesarios, y lo mismo vale para la revocación.

**Q6.5** `X` (mayúscula) otorga ejecución/búsqueda **solo si el objeto es un directorio, o ya tiene al menos un bit de ejecución puesto para alguna clase de usuario**. `x` (minúscula) lo otorga incondicionalmente. Sobre un árbol mixto, `setfacl -R -m u:carol:rx` haría ejecutable a cada archivo de datos — ruido en el mejor de los casos, y un problema real para cualquier cosa que escanee buscando ejecutables o para una política adyacente a `noexec`. `rX` les da a los directorios el bit de búsqueda que necesitan mientras deja los archivos de datos planos como no ejecutables, y preserva correctamente el bit de ejecución en los archivos que legítimamente lo tienen. `chmod` tiene la misma semántica de `X`, por la misma razón.

**Q6.6**

| | Directorio SGID | ACL por defecto |
|---|---|---|
| Garantiza | los objetos nuevos obtienen **grupo = `devops`** | los objetos nuevos obtienen las **entradas de permiso especificadas**, para cualquier cantidad de usuarios y grupos |
| No garantiza | ningún *bit* de permiso en particular — esos siguen viniendo de la umask, así que un proceso con `077` produce `-rw------- alice devops`, ilegible para el grupo | la **propiedad** de grupo; esa sigue viniendo del grupo primario del creador salvo que también esté puesto SGID |
| Alcance | un solo grupo (el del directorio) | arbitrariamente muchos usuarios y grupos nombrados |
| Anula la umask | no | sí |

Ninguno solo es suficiente. El patrón de producción son **los dos**: `chgrp devops dir && chmod 2770 dir && setfacl -m g:devops:rwx -d -m g:devops:rwx dir`. SGID arregla la propiedad y se propaga a sí mismo; la ACL por defecto arregla los bits sin importar la umask de ningún proceso.

### Ejercicio 7 — Atributos extendidos

**Q7.1**

| Espacio de nombres | Lectura | Escritura | Propósito |
|---|---|---|---|
| `user.*` | cualquiera con `r` sobre el archivo | cualquiera con `w` sobre el archivo | metadatos de aplicación de forma libre. No se permiten en enlaces simbólicos ni archivos especiales; en un directorio sticky, solo el propietario puede establecerlos. |
| `trusted.*` | requiere `CAP_SYS_ADMIN` | requiere `CAP_SYS_ADMIN` | metadatos privilegiados que deben ser **invisibles** para procesos sin privilegios |
| `system.*` | mediada por el subsistema del kernel dueño del atributo | ídem — no es escribible en general vía `setfattr` | gestionados por el kernel: `system.posix_acl_access`, `system.posix_acl_default` |
| `security.*` | típicamente legible por todos | requiere el permiso del LSM dueño | `security.selinux`, `security.capability`, `security.ima`/`evm` |

La asimetría de lectura entre `trusted` y `security` es deliberada y es todo el motivo de que existan ambos.

**Q7.2** El patrón `-m` de `getfattr` por defecto es `^user\.`, así que una invocación pelada lista solo el espacio de nombres `user`. Ampliá con `-m '.*'` (una expresión regular explícita que coincide con todo) o con el atajo convencional `-m -`; agregá `-d` para volcar valores. Corolario para scripting: **nunca concluyas "este archivo no tiene xattrs" a partir de un `getfattr` pelado.**

**Q7.3** `trusted.*` está diseñado para que los procesos sin privilegios ni siquiera puedan enterarse de su existencia — `listxattr` filtra el espacio de nombres por completo para los llamantes sin `CAP_SYS_ADMIN`, y `getxattr` devuelve `EPERM`/`ENODATA`. `security.selinux` es legible por todos por diseño, porque los contextos no son secretos y las herramientas de espacio de usuario (`ls -Z`, `ps -Z`) tienen que mostrarlos. El subsistema real que depende de `trusted`: **overlayfs**, que almacena whiteouts, marcadores de directorio opaco y redirecciones en `trusted.overlay.*` — si un proceso sin privilegios en la capa superior pudiera verlos o falsificarlos, podría manipular la vista fusionada. (Históricamente también lo usaron Samba/`winbind` y algunos productos HSM/de backup.)

**Q7.4** Porque la ACL no está meramente almacenada ahí — está **cacheada en el inodo en memoria** y se consulta en cada chequeo de permisos, y debe satisfacer invariantes estructurales (una mask siempre que existan entradas nombradas, exactamente una de cada entrada obligatoria, entradas ordenadas, un encabezado de versión válido). El kernel expone `system.posix_acl_access` a través de un *manejador* de xattr dedicado que parsea, valida e instala la ACL, y simultáneamente actualiza la palabra de modo para que `ls -l` siga siendo consistente. `setfattr` no puede saltear ese manejador. Si se permitieran escrituras crudas, un blob malformado o bien desincronizaría la palabra de modo respecto de la ACL — produciendo un archivo cuyos permisos mostrados no guardan relación con lo que se aplica — o bien sería rechazado como imparseable en el momento del chequeo, con comportamiento de respaldo indefinido. Usá `setfacl`, que habla la misma interfaz correctamente.

**Q7.5** En ext4 sin la característica `ea_inode`, **todos** los atributos extendidos de un inodo tienen que entrar o bien en el espacio sobrante del inodo (`extra_isize`) o bien en un **único bloque del sistema de archivos** — 4 KiB por defecto. El límite es por inodo y por bloque, no por volumen, así que el espacio libre en el dispositivo es irrelevante y el kernel reporta `ENOSPC` igual. Habilitá `ea_inode` (`tune2fs -O ea_inode`, o `mkfs.ext4 -O ea_inode`) para dejar que los valores grandes se derramen en inodos dedicados, elevando el techo por valor a 64 KiB. XFS tiene una disposición distinta y soporta valores de 64 KiB de forma nativa. Regla práctica: **los atributos extendidos son para etiquetas y metadatos chicos, no para carga útil.** Un producto de backup que guarde manifiestos de varios kilobytes en xattrs va a fallar de forma intermitente en ext4 según cuántos otros atributos (etiqueta de SELinux, ACL, capacidades) ya estén presentes.

**Q7.6** *Enlaces simbólicos y archivos especiales:* el kernel rechaza `user.*` ahí porque esos inodos no tienen bits de permiso propios con significado — un enlace simbólico siempre es `lrwxrwxrwx` — así que la regla de acceso "podés escribir `user.*` si podés escribir el archivo" degeneraría en "cualquiera puede escribir". *Directorios sticky:* un directorio escribible por todos, estilo `/tmp`, si no dejaría que cualquier usuario adosara datos de atributos sin límite a los directorios de *otros usuarios*, lo que es a la vez un problema de cuota de disco y de integridad de metadatos. Restringirlo al propietario del directorio refleja exactamente el razonamiento detrás del propio bit sticky.

**Q7.7** El **bit SUID**. Es parte de la palabra de modo del inodo (`i_mode`), un campo de primera clase del inodo, no un atributo extendido. Los otros cuatro son todos xattrs: capacidades de archivo → `security.capability`; contexto de SELinux → `security.selinux`; ACL POSIX → `system.posix_acl_access` / `system.posix_acl_default`; medición IMA → `security.ima` (con `security.evm` para el HMAC). Esta distinción es exactamente por la que `cp` necesita `--preserve=xattr` para capacidades y ACL pero obtiene el bit SUID de `--preserve=mode`.

### Ejercicio 8 — Preservar metadatos DAC

**Q8.1** `--preserve=mode` cubre los **bits de permiso (incluidos SUID/SGID/sticky) y las listas de control de acceso** — coreutils trata la ACL como parte del "modo", lo cual es coherente porque la ACL y la palabra de modo son dos vistas de una misma cosa. **No** cubre los atributos extendidos en general. `cp -p` es `--preserve=mode,ownership,timestamps`, de ahí que ACL sí, `user.*` no. Para todo lo demás necesitás `--preserve=xattr`, o `--preserve=all` / `-a`, que adicionalmente cubre enlaces y el contexto de SELinux.

**Q8.2** `cp -a` está documentado como *"equivalente a `-dR --preserve=all` con diagnósticos reducidos"* — suprime deliberadamente las fallas de preservación de xattr/ACL, bajo la teoría de que `-a` se usa para espejado informal donde un destino que no puede guardar los metadatos no es un error que amerite abortar. `--preserve=all` (y `--preserve=xattr` en particular) sí reporta la falla. **Consecuencia operativa:** una migración hecha con `cp -a` hacia un destino que carece de soporte de ACL o xattr termina con **estado de salida 0 y sin ninguna salida**, y la pérdida se descubre después, como un incidente de autorización. Para migraciones, usá `cp -dR --preserve=all` (o `rsync -aAX --info=progress2`) para que las fallas sean ruidosas, y verificá después en lugar de confiar en el código de salida.

**Q8.3** Todas las **ACL** y todos los **atributos extendidos** — otorgamientos de usuario y grupo nombrados, ACL por defecto en directorios, contextos de SELinux, capacidades de archivo. Contenido idéntico byte a byte con el modelo de autorización amputado: después del cutover, los usuarios que tenían acceso otorgado por entradas de ACL nombradas quedan denegados, y — peor en la otra dirección — los archivos cuya ACL estaba *restringiendo* un modo por lo demás permisivo pasan a ser **más** accesibles que antes. `md5sum` y los conteos de archivos no pueden ver nada de eso, porque nada de eso es contenido del archivo. La verificación única que abarca todo: correr `getfacl -R --absolute-names` y `getfattr -R -d -m '.*' --absolute-names` sobre origen y destino y hacer `diff` de los dos volcados. Esa sola comparación cubre ACL, valores por defecto, y todos los espacios de nombres de xattr que el llamante pueda leer. (Corré la parte de `trusted.*` como root, o va a comparar silenciosamente nada.)

**Q8.4** Los valores por defecto de rsync son conservadores porque las ACL y los xattrs **no son portables entre plataformas ni sistemas de archivos**: la misma invocación `-a` se usa rutinariamente macOS↔Linux, Linux↔BSD, y hacia destinos FAT/SMB/respaldados por S3, donde intentar transferirlos fallaría o produciría basura. Hacerlos opcionales mantiene funcionando el caso común. Para una migración de servidor Linux a Linux, estandarizá en **`rsync -aAX --numeric-ids --hard-links --sparse`**: `-A` ACL, `-X` xattrs (esto es lo que lleva los contextos de SELinux y las capacidades de archivo), y `--numeric-ids` para que los UID no se remapeen a través de un `/etc/passwd` que puede diferir entre los dos hosts — un remapeo de ID reescribe silenciosamente cada propiedad *y* cada entrada de ACL nombrada. Agregá `-H` cuando el origen tenga enlaces duros, o vas a inflar el conjunto de datos y romper los supuestos de compartición de inodos.

**Q8.5** No. Dentro de un mismo sistema de archivos, `mv` es un único `rename(2)` — el inodo nunca se mueve, así que modo, propiedad, ACL, xattrs, marcas de tiempo y conteo de enlaces se preservan por construcción, sin flags y sin oportunidad de pérdida. Entre sistemas de archivos, `rename(2)` falla con **`EXDEV`**, y `mv` recae en **copiar-y-después-desenlazar**, usando el equivalente de `--preserve=all`. En ese punto queda sujeto exactamente a las mismas limitaciones del destino que `cp`: hacia `/srv/dac-plain` la ACL y los atributos `user.*` no se pueden escribir. `mv` sí emite un diagnóstico por la preservación fallida, pero el archivo de origen igual se elimina después — **la copia degradada es todo lo que queda.** Verificá los metadatos antes, no después, de un `mv` entre sistemas de archivos.

**Q8.6**
- **`install -m 0640`** — no. `install` crea un archivo nuevo y establece exactamente el modo especificado; las ACL y los xattrs no se llevan (existe `-Z`/`--preserve-context` para SELinux, pero nada para ACL POSIX). Esto es una característica: `install` existe para producir permisos determinísticos.
- **`cp -a`** — sí, cuando el sistema de archivos destino soporta ACL; y silenciosamente no, cuando no las soporta (Q8.2).
- **`git checkout`** — no. Git almacena exactamente **un** bit de permiso por archivo: si es ejecutable o no (modo `100644` vs `100755`), más enlaces simbólicos y gitlinks. Ni propietario, ni grupo, ni ACL, ni xattr. Los permisos de los archivos extraídos vienen de la umask. Cualquier cosa relevante para la seguridad tiene que ser reafirmada por el paso de despliegue (`install`, un `chmod` en la unidad, Ansible, `%attr` en un archivo spec), nunca asumida desde el repositorio.
- **`rpm -i`** — sí para modo y propiedad, a partir de las directivas `%attr`/`%defattr` registradas en el encabezado del paquete, y RPM además restaura los contextos de SELinux y las capacidades de archivo. **No** lleva ACL POSIX: no forman parte del formato de información de archivos de RPM, así que un paquete no puede distribuir una entrada de ACL de usuario nombrado. Eso hay que aplicarlo post-instalación (scriptlet `%post` o gestión de configuración).

### Ejercicio 9 — Diagnóstico

**Q9.1** `/proc/<pid>/status` describe lo que se va a aplicar. Los grupos suplementarios son parte de las **credenciales** de un proceso, establecidas en el momento de `setgroups(2)` — normalmente por `login`/`sshd`/`sudo` vía `initgroups(3)` — y luego heredadas a través de `fork` y `exec`. `usermod -aG` edita `/etc/group`, una *base de datos*; no puede meterse dentro de procesos que ya están corriendo. `id carol` muestra la vista de la base de datos porque `id` es un proceso nuevo que lee la base directamente. Para obtener el grupo nuevo sin un logout completo: **(a)** `newgrp devops` o `sg devops -c '<cmd>'`, que arrancan un shell/comando nuevo con credenciales reinicializadas (`newgrp` es SUID root precisamente para esto); **(b)** cualquier sesión recién autenticada — `sudo -u carol -i`, un login `ssh` nuevo, una sesión de escritorio nueva, o `systemctl restart` para un servicio. Para servicios, reiniciar la unidad es la única solución confiable — recargar normalmente no alcanza, ya que las credenciales se establecen en el momento del fork.

**Q9.2** La línea `user:carol:rw-` **`#effective:r--`**, corroborada por `mask::r--`. Esa sola anotación dice: el otorgamiento existe, y la mask lo está destruyendo. `ls -l` es activamente engañoso porque renderiza `-rw-r-----+` — un listado cuyo campo de grupo (`r--`) es la *mask*, y que no muestra absolutamente nada sobre `carol`. Leyendo solo `ls -l`, la conclusión natural es "carol no tiene entrada, agreguemos una" — y `setfacl -m u:carol:rw-` va a parecer exitoso sin cambiar nada, porque vuelve a otorgar un permiso que ya está otorgado y después recalcula la mask… lo cual en este caso *sí* lo arreglaría, oscureciendo la lección real. El carácter `+` es la señal para dejar de leer `ls` y empezar a leer `getfacl`.

**Q9.3** El kernel resuelve una ruta **un componente por vez, de izquierda a derecha, requiriendo permiso de búsqueda (`x`) en cada directorio por el que pasa**; los permisos propios de la hoja se chequean solo si cada componente previo era atravesable. Una denegación puede por lo tanto originarse en cualquier punto de la ruta, y el error es indistinguible de una denegación sobre el propio objetivo — que es exactamente lo que `namei -om` existe para desambiguar.

**Q9.4** Las **opciones de montaje** — `nosuid` en el sistema de archivos — anularon a DAC por completo. El kernel descarta los bits SUID/SGID en el momento de `execve` para cualquier binario en un montaje `nosuid`, y no hay mensaje de error: el programa simplemente corre sin privilegios, así que el síntoma es "la herramienta dice permission denied" en lugar de "la herramienta se negó a arrancar". Para un `sudo` que dejó de elevar, revisá en este orden: **(1)** `findmnt -no OPTIONS -T /usr/bin/sudo` buscando `nosuid`; **(2)** `ls -l /usr/bin/sudo` — el bit SUID es `-rwsr-xr-x root root`, y lo destruye rutinariamente un `chown`, un `chmod -R` mal hecho, o una restauración desde un archivo tomado sin `--preserve=all`; **(3)** `getcap /usr/bin/sudo` si la distribución usa capacidades en su lugar; **(4)** denegaciones de SELinux vía `ausearch -m AVC -ts recent`. Notá que el sudo moderno también puede compilarse para usar `CAP_SETUID` en lugar de SUID, en cuyo caso un `chown` o una escritura al binario limpia silenciosamente `security.capability` con el mismo resultado.

**Q9.5** Tres mecanismos fuera de DAC, con el comando que identifica a cada uno:

| Mecanismo | Síntoma | Diagnóstico |
|---|---|---|
| **MAC — SELinux / AppArmor** | `EACCES` con todo lo demás limpio; root no está exento | `ausearch -m AVC -ts recent`, `dmesg \| grep -i denied`, `getenforce`, `aa-status`. Confirmalo probando con `setenforce 0` (nunca lo dejes así). |
| **Atributos de archivo inmutable / solo-anexar** | `EPERM` al escribir o desenlazar, incluso como root | `lsattr <file>` → `----i--------` (inmutable) o `-----a-------` (solo-anexar). Limpialo con `chattr -i`; requiere `CAP_LINUX_IMMUTABLE`. Distinto de las ACL y los xattrs — estas son banderas de inodo gestionadas por `ioctl`. |
| **Montaje de solo lectura, o un dispositivo/snapshot de solo lectura** | `EROFS` — "Read-only file system" | `findmnt -no OPTIONS -T <path>` buscando `ro`; `dmesg` por si el sistema de archivos fue remontado como solo lectura tras un error de E/S o de journal. |

Otros candidatos que vale la pena conocer: **agotamiento de cuota del sistema de archivos** (`EDQUOT`, `quota -s -u <user>`, `repquota`); **seccomp o una directiva de sandbox de systemd** — `ProtectSystem=strict`, `ReadOnlyPaths=`, `ProtectHome=`, `PrivateTmp=` — que son invisibles desde afuera de la unidad (`systemctl show <unit> -p ProtectSystem,ReadOnlyPaths,ProtectHome`); **propagación de montajes entre namespaces**, donde el proceso ve un árbol de sistema de archivos distinto del que ve tu shell (`cat /proc/<pid>/mountinfo`); y **`root_squash` de NFS**, donde root se remapea a `nobody` en el servidor (`exportfs -v` en el servidor). La lección unificadora: DAC es la *primera* puerta, no la única, y `EACCES`/`EPERM` son compartidos por todas ellas.

</details>