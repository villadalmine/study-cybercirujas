# LPIC-1 102.5 — Use RPM and YUM Package Management
## Ejercicios guiados

> **Peso en el examen:** 4.69 (Examen 102-500, versión 5.0)
> **Alcance cubierto acá:** `rpm`, `rpm2cpio`, `/etc/yum.conf`, `/etc/yum.repos.d/`, `yum`, `dnf`, `zypper`, integridad y firmas de paquetes, búsquedas inversas archivo↔paquete, inspección de dependencias, historial de transacciones y recuperación.

---

## Cómo usar este documento

Cada ejercicio es una secuencia numerada de comandos que tipeás en un sistema real, seguida de **Preguntas de control**. No te adelantes a las respuestas: ejecutá el bloque, mirá *tu* salida, y recién ahí respondé. Las salidas esperadas que se muestran provienen de un sistema Rocky Linux 9.3 x86_64; las cadenas de versión-release de tu máquina van a diferir, y esa diferencia es en sí misma informativa.

Los comandos con prefijo `#` requieren root. Los que llevan `$` no — y una de las lecciones recurrentes es que **toda operación de consulta en RPM y DNF funciona sin privilegios**; solo las transacciones necesitan root.

---

## Ejercicio 0 — Armar un laboratorio descartable

Nunca aprendas gestión de paquetes en una máquina que te importe. Vas a corromper archivos a propósito, forzar la instalación de paquetes rotos y revertir transacciones.

### Pasos

1. Creá el contenedor de laboratorio RPM/DNF. Acá se usa Podman; `docker` funciona igual.

   ```bash
   $ podman run -it --name lpic-rpm --hostname rpmlab \
       quay.io/rockylinux/rockylinux:9 /bin/bash
   ```

2. Dentro del contenedor, instalá las herramientas que necesitan los ejercicios y algunas víctimas inofensivas:

   ```bash
   # dnf -y install dnf-plugins-core rpm-build vim-enhanced cpio \
        which findutils procps-ng diffutils python3-dnf-plugin-versionlock
   ```

3. Confirmá la versión del stack RPM — el comportamiento difiere de forma sustancial entre RPM 4.14 (RHEL 8), 4.16 (RHEL 9) y 4.19+/5 (Fedora 40+):

   ```bash
   $ rpm --version
   RPM version 4.16.1.3

   $ dnf --version
   4.14.0
   Installed: dnf-0:4.14.0-9.el9.noarch at Thu 12 Oct 2023 07:41:02 PM UTC
   ...
   ```

4. En una **segunda terminal**, creá el laboratorio de zypper (necesario recién a partir del Ejercicio 14):

   ```bash
   $ podman run -it --name lpic-zypper --hostname zyplab \
       registry.opensuse.org/opensuse/leap:15.6 /bin/bash
   ```

5. Registrá una línea base contra la cual puedas hacer diff más adelante:

   ```bash
   # rpm -qa | sort > /root/baseline-packages.txt
   # wc -l /root/baseline-packages.txt
   243 /root/baseline-packages.txt
   ```

### Preguntas de control

- **Q0.1** — ¿Por qué `rpm -qa` funciona como usuario sin privilegios, y `rpm -i` no? Nombrá las dos ubicaciones del sistema de archivos que marcan la diferencia.
- **Q0.2** — Ejecutaste `rpm --version` y obtuviste `4.16.1.3`. ¿Qué backend de base de datos RPM usa esa release por defecto, y qué comando lo demuestra sin mirar `/var/lib/rpm`?
- **Q0.3** — Tu archivo de línea base lista cadenas NEVRA como `bash-5.1.8-6.el9_1.x86_64`. Descomponé esa cadena en sus cinco campos e indicá cuál *no* está presente.

---

## Ejercicio 1 — Dónde vive la verdad: la base de datos RPM

RPM no tiene demonio ni capa de red. Es una base de datos transaccional local más un formato de archivo. Todo lo demás — DNF, YUM, Zypper, PackageKit — es un *resolvedor de dependencias y descargador* atornillado encima.

### Pasos

1. Preguntale a RPM dónde está su base de datos, en vez de suponerlo:

   ```bash
   $ rpm -E '%{_dbpath}'
   /var/lib/rpm

   $ rpm -E '%{_db_backend}'
   sqlite
   ```

2. Mirá los archivos reales:

   ```bash
   $ ls -l /var/lib/rpm/
   total 12288
   -rw-r--r--. 1 root root 12587008 Aug 20 09:14 rpmdb.sqlite
   -rw-r--r--. 1 root root    32768 Aug 20 09:14 rpmdb.sqlite-shm
   -rw-r--r--. 1 root root  4136432 Aug 20 09:14 rpmdb.sqlite-wal
   ```

   En RHEL 8 / CentOS 8 verías en cambio `Packages`, `Name`, `Basenames`, `Providename` … — tablas Berkeley DB. En sistemas construidos con `ndb` verías `Packages.db`, `Index.db`.

3. Contá y ordená los paquetes instalados por momento de instalación — la consulta forense más útil en una máquina que no armaste vos:

   ```bash
   $ rpm -qa --last | head -5
   python3-dnf-plugin-versionlock-4.3.0-11.el9.noarch  Wed 20 Aug 2026 09:14:22 AM UTC
   vim-enhanced-8.2.2637-20.el9_1.x86_64               Wed 20 Aug 2026 09:14:21 AM UTC
   rpm-build-4.16.1.3-25.el9.x86_64                    Wed 20 Aug 2026 09:14:18 AM UTC
   cpio-2.13-16.el9.x86_64                             Wed 20 Aug 2026 09:13:57 AM UTC
   dnf-plugins-core-4.3.0-11.el9.noarch                Wed 20 Aug 2026 09:13:57 AM UTC
   ```

4. Armá un reporte a medida con `--queryformat` (`--qf`). Esta es la diferencia entre leer datos de paquetes y *scriptearlos*:

   ```bash
   $ rpm -qa --qf '%{NAME}|%{VERSION}-%{RELEASE}|%{ARCH}|%{SIZE}|%{VENDOR}\n' \
       | sort -t'|' -k4 -rn | head -3
   rpm-build|4.16.1.3-25.el9|x86_64|54280192|Rocky Enterprise Software Foundation
   vim-enhanced|8.2.2637-20.el9_1|x86_64|3320672|Rocky Enterprise Software Foundation
   glibc|2.34-60.el9|x86_64|6710092|Rocky Enterprise Software Foundation
   ```

5. Formateá correctamente un tag de timestamp — los tags crudos son segundos epoch:

   ```bash
   $ rpm -q --qf '%{NAME} %{INSTALLTIME}\n' bash
   bash 1755680037

   $ rpm -q --qf '%{NAME} %{INSTALLTIME:date}\n' bash
   bash Wed 20 Aug 2026 09:13:57 AM UTC
   ```

6. Descubrí todos los tags consultables en este sistema:

   ```bash
   $ rpm --querytags | wc -l
   276
   $ rpm --querytags | grep -i -E 'sig|size|time' | head
   ```

### Preguntas de control

- **Q1.1** — Un colega dice "la base de datos RPM está en `/var/lib/rpm`, todo el mundo lo sabe". Dá dos escenarios concretos de este curso donde esa suposición es falsa, y el flag que resuelve cada uno.
- **Q1.2** — Escribí un único comando `rpm` que imprima solo los **nombres** de los paquetes que no tienen vendor definido (`%{VENDOR}` = `(none)`). ¿Por qué esos paquetes son relevantes para la seguridad en un host de producción?
- **Q1.3** — `rpm -qa --last` ordena del más nuevo al más viejo. ¿Por qué ese orden puede ser engañoso inmediatamente después de un `dnf upgrade` de 200 paquetes, y qué usarías en cambio para reconstruir *qué operación* ocurrió?
- **Q1.4** — ¿Cuál es la diferencia entre `%{SIZE}` y el tamaño del archivo `.rpm` del que vino el paquete?

---

## Ejercicio 2 — Interrogar un paquete instalado

El modo `-q` tiene opciones de *selección* (qué paquete) y opciones de *información* (qué imprimir). Confundir las dos es la trampa clásica del examen.

### Pasos

1. Las cinco consultas que vas a usar a diario:

   ```bash
   $ rpm -qi bash        # Info: metadata header
   $ rpm -ql bash        # List: every file the package owns
   $ rpm -qc bash        # Config files only (%config)
   $ rpm -qd bash        # Documentation files only (%doc)
   $ rpm -qs bash        # State of each file (normal / not installed / replaced)
   ```

2. Leé con atención el encabezado de info — varios campos importan operativamente:

   ```bash
   $ rpm -qi bash
   Name        : bash
   Version     : 5.1.8
   Release     : 6.el9_1
   Architecture: x86_64
   Install Date: Wed 20 Aug 2026 09:13:57 AM UTC
   Group       : Unspecified
   Size        : 7739624
   License     : GPLv3+
   Signature   : RSA/SHA256, Tue 07 Feb 2023 05:07:32 PM UTC, Key ID 15af5dac6d745a60
   Source RPM  : bash-5.1.8-6.el9_1.src.rpm
   Build Date  : Tue 07 Feb 2023 05:00:24 PM UTC
   Build Host  : ...
   Packager    : releng@rockylinux.org
   Vendor      : Rocky Enterprise Software Foundation
   URL         : https://www.gnu.org/software/bash
   Summary     : The GNU Bourne Again shell
   Description :
   The GNU Bourne Again shell (Bash) is a shell or command language
   interpreter that is compatible with the Bourne shell (sh)...
   ```

3. Compará las listas de archivos. Notá que `-qc` y `-qd` son subconjuntos estrictos de `-ql`:

   ```bash
   $ rpm -ql bash | wc -l
   211
   $ rpm -qc bash
   /etc/skel/.bash_logout
   /etc/skel/.bash_profile
   /etc/skel/.bashrc
   $ rpm -qd bash | head -3
   /usr/share/doc/bash/AUTHORS
   /usr/share/doc/bash/CHANGES
   /usr/share/doc/bash/COMPAT
   ```

4. Obtené la lista de archivos *con sus atributos registrados* — la materia prima que usa la verificación de RPM:

   ```bash
   $ rpm -q --dump bash | grep '/etc/skel/.bashrc'
   /etc/skel/.bashrc 141 1675789224 40c2ac1e1f0b8...  0100644 root root 1 0 0 X
   ```

   Orden de los campos: `path size mtime digest mode owner group isconfig isdoc rdev symlink`.

5. Inspeccioná la cara de dependencias del paquete:

   ```bash
   $ rpm -q --provides bash
   bash = 5.1.8-6.el9_1
   bash(x86-64) = 5.1.8-6.el9_1
   config(bash) = 5.1.8-6.el9_1
   /bin/sh

   $ rpm -q --requires bash | head -6      # -qR is the short form
   /bin/sh
   config(bash) = 5.1.8-6.el9_1
   filesystem >= 3
   libc.so.6()(64bit)
   libc.so.6(GLIBC_2.11)(64bit)
   ...

   $ rpm -q --conflicts filesystem
   $ rpm -q --obsoletes systemd | head -3
   $ rpm -q --recommends vim-enhanced       # weak dependency, RPM >= 4.12
   ```

6. Leé los scripts del mantenedor — acá se responde "¿por qué instalar ese paquete reinició mi servicio?":

   ```bash
   $ rpm -q --scripts openssh-server | head -20
   preinstall scriptlet (using /bin/sh):
   ...
   postinstall scriptlet (using /bin/sh):
   %systemd_post sshd.service sshd.socket
   ...
   ```

7. Leé el changelog para datar una corrección sin salir de la máquina:

   ```bash
   $ rpm -q --changelog openssl | head -8
   * Tue Feb 07 2023 Dmitry Belyavskiy <dbelyavs@redhat.com> 3.0.7-6
   - Fixed CVE-2023-0286 ...
   ```

### Preguntas de control

- **Q2.1** — `rpm -qc bash` devuelve tres archivos bajo `/etc/skel/`, pero no `/etc/bashrc`. ¿Qué paquete es dueño de `/etc/bashrc`, y qué te dice eso sobre cómo las distribuciones de la familia Red Hat separan la configuración de shell?
- **Q2.2** — Distinguí con precisión estos dos comandos: `rpm -qi bash` y `rpm -qip bash-5.1.8-6.el9_1.x86_64.rpm`. ¿Cuál puede fallar con "package not installed" y por qué?
- **Q2.3** — `bash` provee `/bin/sh` y además *requiere* `/bin/sh`. Explicá cómo resuelve RPM esto sin un bucle infinito, y qué significa para `rpm -e bash`.
- **Q2.4** — Necesitás saber, en una flota de 400 hosts, cuáles de ellos vinieron con un build de `openssl` anterior a la corrección de un CVE específico. Dá un comando de una línea usando solo `rpm` que lo responda, y explicá por qué grepear `--changelog` es un método más débil que comparar version-release.
- **Q2.5** — ¿Para qué sirve `config(bash) = 5.1.8-6.el9_1`? ¿Por qué un paquete depende de un provide virtual que lleva su propio nombre?

---

## Ejercicio 3 — Búsquedas inversas: ¿qué paquete es dueño de este archivo?

### Pasos

1. La consulta inversa fundamental:

   ```bash
   $ rpm -qf /bin/ls
   coreutils-8.32-34.el9.x86_64

   $ rpm -qf /etc/passwd
   setup-2.13.7-10.el9.noarch

   $ rpm -qf /usr/bin/dnf
   dnf-4.14.0-9.el9.noarch
   ```

2. Combiná `-qf` con opciones de información — selección e información son ortogonales:

   ```bash
   $ rpm -qif /usr/sbin/sshd | head -4
   $ rpm -qlf /usr/bin/vim | wc -l
   $ rpm -qcf /usr/sbin/sshd
   /etc/pam.d/sshd
   /etc/ssh/sshd_config
   /etc/sysconfig/sshd
   ```

3. Demostrá qué significa "sin dueño":

   ```bash
   $ touch /root/notes.txt
   $ rpm -qf /root/notes.txt
   file /root/notes.txt is not owned by any package
   $ echo $?
   1
   ```

4. Resolvé una *capability* en lugar de una ruta:

   ```bash
   $ rpm -q --whatprovides /bin/sh
   bash-5.1.8-6.el9_1.x86_64

   $ rpm -q --whatprovides 'libc.so.6()(64bit)'
   glibc-2.34-60.el9.x86_64
   ```

5. Preguntá lo inverso — quién se rompería si este paquete desapareciera:

   ```bash
   $ rpm -q --whatrequires zlib | head
   dnf-data-4.14.0-9.el9.noarch
   ...
   ```

   Después compará con la respuesta del lado de DNF, que ve todo el repositorio y no solo lo instalado:

   ```bash
   $ dnf repoquery --whatrequires zlib --installed | head
   ```

6. Un patrón real de triage — encontrar todos los archivos sin dueño en un directorio del sistema (candidatos a deriva de configuración o a un intruso):

   ```bash
   # find /usr/bin -type f -print0 \
       | xargs -0 rpm -qf 2>/dev/null \
       | grep 'not owned' | head
   ```

### Preguntas de control

- **Q3.1** — `rpm -qf $(which java)` devuelve "not owned by any package" en un host donde Java claramente funciona. Enumerá tres explicaciones legítimas.
- **Q3.2** — `rpm -q --whatrequires bash` devuelve una lista corta, pero eliminar `bash` obviamente destruiría el sistema. ¿Por qué `--whatrequires` es un análisis de impacto *incompleto*, y qué capability deberías consultar en su lugar?
- **Q3.3** — ¿Cuál es el estado de salida de `rpm -qf` para un archivo sin dueño, y por qué eso importa en un script de shell que le pasa muchas rutas por pipe?
- **Q3.4** — Dos paquetes afirman ser dueños de `/usr/share/man/man1/foo.1.gz`. ¿Es posible eso en RPM? ¿Bajo qué declaración, y qué imprime `rpm -qf` entonces?

---

## Ejercicio 4 — Interrogar un *archivo* de paquete antes de confiar en él

Todo lo anterior consultó la base de datos. Agregá `-p` y las mismas opciones leen un archivo `.rpm` en disco — local o remoto, instalado o no.

### Pasos

1. Descargá un paquete sin instalarlo:

   ```bash
   # dnf download --resolve --destdir=/tmp/pkgs nginx
   ...
   nginx-1.20.1-14.el9_2.1.x86_64.rpm            1.6 MB/s | 617 kB   00:00
   nginx-core-1.20.1-14.el9_2.1.x86_64.rpm       4.1 MB/s | 566 kB   00:00
   nginx-filesystem-1.20.1-14.el9_2.1.noarch.rpm 118 kB/s | 8.5 kB   00:00
   $ ls /tmp/pkgs
   ```

2. Leelo sin tocar el sistema:

   ```bash
   $ cd /tmp/pkgs
   $ rpm -qip nginx-1.20.1-14.el9_2.1.x86_64.rpm
   $ rpm -qlp nginx-1.20.1-14.el9_2.1.x86_64.rpm | head
   $ rpm -qcp nginx-core-1.20.1-14.el9_2.1.x86_64.rpm
   /etc/logrotate.d/nginx
   /etc/nginx/fastcgi.conf
   /etc/nginx/nginx.conf
   ...
   $ rpm -qp --requires nginx-1.20.1-14.el9_2.1.x86_64.rpm
   $ rpm -qp --scripts nginx-1.20.1-14.el9_2.1.x86_64.rpm
   ```

3. Consultá un paquete directamente por la red — RPM habla HTTP/FTP de forma nativa:

   ```bash
   $ rpm -qip https://dl.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/Packages/b/bash-5.1.8-6.el9_1.x86_64.rpm
   ```

4. Compará un candidato contra lo instalado, de forma mecánica:

   ```bash
   $ rpm -qp --qf '%{VERSION}-%{RELEASE}\n' nginx-1.20.1-14.el9_2.1.x86_64.rpm
   1.20.1-14.el9_2.1
   $ rpm -q --qf '%{VERSION}-%{RELEASE}\n' nginx
   package nginx is not installed
   ```

5. Usá el comparador de versiones propio de RPM en vez de adivinar con `sort -V`:

   ```bash
   $ rpmdev-vercmp 1.20.1-14.el9_2.1 1.20.1-9.el9
   1.20.1-14.el9_2.1 > 1.20.1-9.el9
   $ echo $?
   11
   ```

   (`rpmdev-vercmp` viene en `rpm-build`/`rpmdevtools`. Salida 0 = iguales, 11 = el primero es más nuevo, 12 = el segundo es más nuevo.)

### Preguntas de control

- **Q4.1** — ¿Por qué falla `rpm -ql nginx-1.20.1-14.el9_2.1.x86_64.rpm` (sin `-p`), y qué es exactamente lo que RPM cree que le pediste?
- **Q4.2** — Tenés que auditar un RPM provisto por un proveedor en un entorno aislado (air-gapped) antes de permitirlo en la red. Enumerá cuatro invocaciones de `rpm -qp` que constituyan una revisión mínima, y decí qué busca cada una.
- **Q4.3** — `rpmdev-vercmp` dice `1.20.1-14.el9_2.1 > 1.20.1-9.el9`. Explicá por qué `14` ordena por encima de `9` acá, mientras que un `sort` lexicográfico ingenuo diría lo contrario. ¿Cuál es el rol del sufijo de release `el9_2`?
- **Q4.4** — ¿Qué le hace un `Epoch` de `1` a la comparación de versiones, y por qué se lo describe como una puerta sin retorno para quien mantiene un paquete?

---

## Ejercicio 5 — Firmas y confianza

Un RPM descargado es código ejecutable que corre como root en el momento de la instalación mediante scriptlets. La verificación de firmas no es opcional en producción.

### Pasos

1. Verificá la firma de un paquete:

   ```bash
   $ rpm -K /tmp/pkgs/nginx-1.20.1-14.el9_2.1.x86_64.rpm
   /tmp/pkgs/nginx-1.20.1-14.el9_2.1.x86_64.rpm: digests signatures OK
   ```

   `rpm -K` es un alias de `rpm --checksig`; el binario independiente `rpmkeys --checksig` hace lo mismo.

2. Mirá qué verificó realmente ese "OK":

   ```bash
   $ rpm -Kv /tmp/pkgs/nginx-1.20.1-14.el9_2.1.x86_64.rpm
   /tmp/pkgs/nginx-1.20.1-14.el9_2.1.x86_64.rpm:
       Header V4 RSA/SHA256 Signature, key ID 350d275d: OK
       Header SHA256 digest: OK
       Header SHA1 digest: OK
       Payload SHA256 digest: OK
       V4 RSA/SHA256 Signature, key ID 350d275d: OK
       MD5 digest: OK
   ```

3. Listá las claves confiables. Las claves se guardan *como pseudo-paquetes* en la base de datos RPM:

   ```bash
   $ rpm -qa gpg-pubkey\* --qf '%{NAME}-%{VERSION}-%{RELEASE} %{SUMMARY}\n'
   gpg-pubkey-350d275d-63db5ec2 Rocky Enterprise Software Foundation - Release Engineering <releng@rockylinux.org> public key
   ```

4. Inspeccioná una clave por completo:

   ```bash
   $ rpm -qi gpg-pubkey-350d275d-63db5ec2
   ```

5. Simulá el caso no confiable. Quitá la clave, volvé a verificar, y reimportala:

   ```bash
   # rpm -e gpg-pubkey-350d275d-63db5ec2
   # rpm -K /tmp/pkgs/nginx-1.20.1-14.el9_2.1.x86_64.rpm
   warning: /tmp/pkgs/nginx-...rpm: Header V4 RSA/SHA256 Signature, key ID 350d275d: NOKEY
   /tmp/pkgs/nginx-1.20.1-14.el9_2.1.x86_64.rpm: digests SIGNATURES NOT OK
   # echo $?
   1

   # rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9
   # rpm -K /tmp/pkgs/nginx-1.20.1-14.el9_2.1.x86_64.rpm
   /tmp/pkgs/nginx-1.20.1-14.el9_2.1.x86_64.rpm: digests signatures OK
   ```

6. Demostrá la detección de manipulación en el payload:

   ```bash
   # cp /tmp/pkgs/nginx-1.20.1-14.el9_2.1.x86_64.rpm /tmp/tampered.rpm
   # printf 'X' | dd of=/tmp/tampered.rpm bs=1 seek=400000 conv=notrunc 2>/dev/null
   # rpm -Kv /tmp/tampered.rpm
   /tmp/tampered.rpm:
       Header V4 RSA/SHA256 Signature, key ID 350d275d: OK
       Header SHA256 digest: OK
       Header SHA1 digest: OK
       Payload SHA256 digest: BAD (Expected 8b1e...  != 4f39...)
       V4 RSA/SHA256 Signature, key ID 350d275d: BAD
       MD5 digest: BAD (Expected 6b0d... != a2c1...)
   ```

7. Observá dónde vive la política a nivel de repositorio:

   ```bash
   $ grep -r gpgcheck /etc/dnf/dnf.conf /etc/yum.repos.d/*.repo
   /etc/dnf/dnf.conf:gpgcheck=1
   /etc/yum.repos.d/rocky.repo:gpgcheck=1
   /etc/yum.repos.d/rocky.repo:gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9
   ```

### Preguntas de control

- **Q5.1** — En el paso 6, la firma del *header* siguió en `OK` mientras el digest del payload pasó a `BAD`. Explicá el modelo de firma en dos partes de RPM y por qué una firma solo del header sigue siendo significativa.
- **Q5.2** — `rpm -K` sobre un paquete sin firmar pero íntegro imprime `digests OK` — fijate en la palabra que falta. Escribí la diferencia exacta entre esa salida y `digests signatures OK`, y decí cuál debería exigir un gate de CI.
- **Q5.3** — ¿Por qué las claves GPG se guardan como paquetes llamados `gpg-pubkey-<keyid>-<timestamp>`? ¿Qué ventaja operativa te da eso frente a un archivo de keyring?
- **Q5.4** — Un ingeniero junior arregla una instalación que falla con `dnf install --nogpgcheck`. Describí el ataque preciso que eso deshabilita, y dá la corrección adecuada para las dos causas raíz más comunes de esa falla.
- **Q5.5** — `gpgcheck=1` en `/etc/dnf/dnf.conf` frente a `gpgcheck=1` dentro de una estrofa `[repo]`: ¿cuál gana, y para qué sirve `localpkg_gpgcheck`?

---

## Ejercicio 6 — Verificación: qué cambió desde la instalación

`rpm -V` compara el sistema de archivos contra la metadata almacenada en el momento de la instalación. Es el chequeo de integridad de host más barato que ya tenés.

### Pasos

1. Verificá un paquete limpio — el silencio significa éxito:

   ```bash
   $ rpm -V bash
   $ echo $?
   0
   ```

2. Rompé cosas a propósito:

   ```bash
   # echo '# tampered' >> /etc/skel/.bashrc          # config file: content + size + mtime
   # chmod 777 /usr/bin/passwd                        # mode
   # chown nobody /usr/bin/wc                         # owner
   # rm -f /usr/share/doc/bash/AUTHORS                # missing doc file
   ```

3. Verificá de nuevo y leé la salida como un campo de flags de ancho fijo:

   ```bash
   # rpm -V bash
   S.5....T.  c /etc/skel/.bashrc
   missing     /usr/share/doc/bash/AUTHORS

   # rpm -V passwd
   .M.......    /usr/bin/passwd

   # rpm -V coreutils
   .....U...    /usr/bin/wc
   ```

   Las nueve posiciones, en orden:

   | Pos | Código | Significado |
   |---|---|---|
   | 1 | `S` | difiere el tamaño del archivo (**S**ize) |
   | 2 | `M` | difiere el modo (**M**ode: permisos + tipo) |
   | 3 | `5` | difiere el digest (MD5/SHA) |
   | 4 | `D` | discrepancia de major/minor del dispositivo (**D**evice) |
   | 5 | `L` | discrepancia en la ruta del enlace simbólico (read**L**ink) |
   | 6 | `U` | difiere la propiedad de usuario (**U**ser) |
   | 7 | `G` | difiere la propiedad de grupo (**G**roup) |
   | 8 | `T` | difiere el mtime (m**T**ime) |
   | 9 | `P` | difieren las capabilities (ca**P**abilities) |

   Un `.` significa que ese test pasó; un `?` significa que el test no pudo realizarse (normalmente, archivo ilegible). La letra que sigue a los flags es el marcador de atributo del archivo: `c` config, `d` doc, `g` ghost, `l` license, `r` readme.

4. Verificá por archivo en vez de por paquete:

   ```bash
   # rpm -Vf /usr/bin/passwd
   .M.......    /usr/bin/passwd
   ```

5. Verificá todo el sistema, filtrando el ruido esperable:

   ```bash
   # rpm -Va --nomtime --nordev 2>/dev/null | grep -v '^\.\{8\}' | head -20
   ```

6. Repará permisos y propiedad a partir de la metadata — esta es la corrección correcta, no un `chmod` de memoria:

   ```bash
   # rpm --setperms passwd
   # rpm --setugids coreutils
   # rpm -V passwd coreutils
   # echo $?
   0
   ```

7. Restaurá contenido faltante/alterado que no sea de configuración reinstalando el payload:

   ```bash
   # dnf -y reinstall bash
   # rpm -V bash
   S.5....T.  c /etc/skel/.bashrc
   ```

   Notá que el archivo de configuración quedó modificado. Eso es deliberado.

8. Confirmá qué hizo `reinstall` con tu configuración editada:

   ```bash
   # ls -l /etc/skel/.bashrc*
   ```

### Preguntas de control

- **Q6.1** — Decodificá `S.5....T.  c /etc/skel/.bashrc` flag por flag, y explicá por qué `M`, `U` y `G` son puntos.
- **Q6.2** — Después de `dnf reinstall bash`, `/usr/share/doc/bash/AUTHORS` volvió pero `/etc/skel/.bashrc` conservó tu edición. Explicá el mecanismo `%config` frente a `%config(noreplace)` y la regla de nombres `.rpmnew` / `.rpmsave` — incluyendo qué operación produce cada sufijo.
- **Q6.3** — `rpm -Va` en un host de producción de larga vida imprime cientos de líneas. Nombrá tres categorías de hallazgo que son *esperables* e inofensivas, y explicá por qué `rpm -Va` por sí solo no sustituye a AIDE ni a un HIDS con línea base firmada.
- **Q6.4** — ¿Por qué `rpm --setperms` es seguro de ejecutar pero `rpm --setugids` es ocasionalmente peligroso? Considerá un paquete cuyos archivos fueron chowneados intencionalmente a una cuenta de servicio por política del sitio.
- **Q6.5** — Un atacante con root modifica `/usr/bin/sshd` **y** la base de datos RPM. ¿Qué reporta `rpm -V`, y cuál es la lección arquitectónica sobre dónde debe vivir una línea base de integridad?

---

## Ejercicio 7 — Instalar, actualizar, refrescar y eliminar con `rpm(8)`

`rpm` no resuelve dependencias. Las reporta y se detiene. Entender esto es toda la razón de existir de DNF.

### Pasos

1. Primero, ensayo en seco. `--test` realiza el chequeo completo de la transacción y no compromete nada:

   ```bash
   # cd /tmp/pkgs
   # rpm -ivh --test nginx-1.20.1-14.el9_2.1.x86_64.rpm
   error: Failed dependencies:
           nginx-core = 1:1.20.1-14.el9_2.1 is needed by nginx-1:1.20.1-14.el9_2.1.x86_64
           nginx-filesystem = 1:1.20.1-14.el9_2.1 is needed by nginx-1:1.20.1-14.el9_2.1.x86_64
   ```

2. Satisfacé vos mismo las dependencias nombrando todos los RPM en una sola transacción:

   ```bash
   # rpm -ivh nginx-*.rpm
   Verifying...                       ################################# [100%]
   Preparing...                       ################################# [100%]
   Updating / installing...
      1:nginx-filesystem-1:1.20.1-14.el9 ################################# [ 33%]
      2:nginx-core-1:1.20.1-14.el9_2.1   ################################# [ 67%]
      3:nginx-1:1.20.1-14.el9_2.1        ################################# [100%]
   ```

   `-i` install, `-v` verbose, `-h` barra de progreso con almohadillas.

3. Entendé `-i` frente a `-U` frente a `-F` de forma empírica. Primero, bajar de versión y después actualizar:

   ```bash
   # rpm -q nginx
   nginx-1.20.1-14.el9_2.1.x86_64

   # rpm -Uvh nginx-1.20.1-14.el9_2.1.x86_64.rpm
   package nginx-1:1.20.1-14.el9_2.1.x86_64 is already installed

   # rpm -Uvh --replacepkgs nginx-1.20.1-14.el9_2.1.x86_64.rpm    # forces re-install
   ```

4. Freshen. `-F` actualiza un paquete **solo si ya hay una versión más vieja instalada**:

   ```bash
   # rpm -Fvh /tmp/pkgs/*.rpm          # silently skips anything not installed
   # rpm -q httpd
   package httpd is not installed
   # rpm -Fvh httpd-2.4.53-11.el9_2.5.x86_64.rpm   # no output, nothing installed
   ```

   Esta es la herramienta para "parchear lo que esta máquina tiene, no instalar nada nuevo".

5. Eliminación, y el muro de dependencias:

   ```bash
   # rpm -e nginx-core
   error: Failed dependencies:
           nginx-core = 1:1.20.1-14.el9_2.1 is needed by (installed) nginx-1:1.20.1-14.el9_2.1.x86_64

   # rpm -e nginx nginx-core nginx-filesystem      # correct: one transaction
   ```

6. Mirá las válvulas de escape — y por qué son el último recurso:

   ```bash
   # rpm -ivh --nodeps somepkg.rpm      # install a package whose deps are unmet
   # rpm -e  --nodeps somepkg           # remove a package others depend on
   # rpm -Uvh --oldpackage older.rpm    # deliberate downgrade
   # rpm -Uvh --force newpkg.rpm        # = --replacepkgs --replacefiles --oldpackage
   # rpm -ivh --noscripts pkg.rpm       # skip %pre/%post
   ```

7. La excepción del kernel. Los kernels son *de solo instalación*, nunca se actualizan en el lugar:

   ```bash
   $ grep -E 'installonly' /etc/dnf/dnf.conf
   installonly_limit=3
   $ rpm -q kernel                # on a real VM, expect several versions
   kernel-5.14.0-284.11.1.el9_2.x86_64
   kernel-5.14.0-284.18.1.el9_2.x86_64
   ```

8. Instalá en una raíz alternativa — la técnica detrás de la construcción de imágenes y del rescate:

   ```bash
   # mkdir -p /tmp/altroot
   # rpm -ivh --root /tmp/altroot --nodeps filesystem-3.16-2.el9.x86_64.rpm
   # rpm -qa --root /tmp/altroot
   filesystem-3.16-2.el9.x86_64
   ```

### Preguntas de control

- **Q7.1** — Enunciá el comportamiento de `-i`, `-U` y `-F` para cada uno de estos tres estados iniciales: paquete ausente, versión más vieja instalada, misma versión instalada. Se espera una tabla de 3×3 como respuesta.
- **Q7.2** — ¿Por qué `rpm -Uvh kernel-5.14.0-284.18.1.el9_2.x86_64.rpm` constituye un riesgo de caída de servicio, y qué hace de `installonlypkgs` el mecanismo correcto en lugar de la disciplina del administrador?
- **Q7.3** — `rpm -e --nodeps glibc` se va a ejecutar. Describí en qué estado queda la máquina un segundo después y por qué ningún comando `rpm` puede recuperarla.
- **Q7.4** — Instalaste tres RPM de nginx en un único `rpm -ivh nginx-*.rpm`. ¿Por qué funcionó eso cuando instalarlos de a uno en ese mismo orden también habría funcionado, pero instalar `nginx` primero no?
- **Q7.5** — `--force` está documentado como la unión de tres flags. Nombralos y dá un escenario en el que `--replacefiles` por sí solo sea la elección correcta y acotada.
- **Q7.6** — ¿Qué hace `rpm -ivh --justdb`, y nombrá un escenario de recuperación legítimo para eso.

---

## Ejercicio 8 — `rpm2cpio`: extracción sin instalación

Necesitás un solo archivo de un paquete, en un host que no debés modificar, o de un paquete de otra distribución por completo.

### Pasos

1. Listá el payload de un paquete como si fuera un archivo comprimido:

   ```bash
   $ cd /tmp/pkgs
   $ rpm2cpio nginx-core-1.20.1-14.el9_2.1.x86_64.rpm | cpio -t | head
   ./etc/logrotate.d/nginx
   ./etc/nginx/fastcgi.conf
   ./etc/nginx/fastcgi_params
   ./etc/nginx/mime.types
   ./etc/nginx/nginx.conf
   ...
   ```

   Notá el `./` inicial — las rutas del payload son **relativas**. Eso es lo que impide que la extracción sobrescriba el sistema de archivos vivo.

2. Extraé todo en un directorio de trabajo:

   ```bash
   $ mkdir -p /tmp/extract && cd /tmp/extract
   $ rpm2cpio /tmp/pkgs/nginx-core-1.20.1-14.el9_2.1.x86_64.rpm | cpio -idmv
   ./etc/logrotate.d/nginx
   ./etc/nginx/fastcgi.conf
   ...
   3204 blocks
   ```

   `-i` extraer, `-d` crear directorios, `-m` preservar mtimes, `-v` verbose.

3. Extraé un solo archivo con un patrón:

   ```bash
   $ cd /tmp/extract && rm -rf etc usr var
   $ rpm2cpio /tmp/pkgs/nginx-core-1.20.1-14.el9_2.1.x86_64.rpm \
       | cpio -idmv './etc/nginx/nginx.conf'
   ./etc/nginx/nginx.conf
   3204 blocks
   $ find . -type f
   ./etc/nginx/nginx.conf
   ```

4. El patrón de recuperación: restaurar un binario pisado sin una reinstalación completa:

   ```bash
   # rpm -qf /usr/bin/wc
   coreutils-8.32-34.el9.x86_64
   # dnf download --destdir=/tmp/pkgs coreutils
   # cd /tmp/extract && rpm2cpio /tmp/pkgs/coreutils-8.32-34.el9.x86_64.rpm \
       | cpio -idmv './usr/bin/wc'
   # install -o root -g root -m 0755 /tmp/extract/usr/bin/wc /usr/bin/wc
   # rpm -Vf /usr/bin/wc
   ```

5. La alternativa moderna, `rpm2archive` (RPM ≥ 4.14) — emite un stream tar, que maneja rutas de más de 110 caracteres y archivos grandes que los formatos cpio antiguos no pueden:

   ```bash
   $ rpm2archive - < /tmp/pkgs/coreutils-8.32-34.el9.x86_64.rpm | tar -tzf - | head -3
   ./usr/bin/[
   ./usr/bin/arch
   ./usr/bin/b2sum
   ```

6. Demostrá que la extracción evita todo lo que hace RPM:

   ```bash
   $ rpm -q --scripts /tmp/pkgs/nginx-core-1.20.1-14.el9_2.1.x86_64.rpm 2>/dev/null
   $ rpm -qp --scripts /tmp/pkgs/nginx-core-1.20.1-14.el9_2.1.x86_64.rpm | head
   ```

   Los scriptlets viven en el **header**, no en el payload. `rpm2cpio` te da solo el payload.

### Preguntas de control

- **Q8.1** — Nombrá cuatro cosas que `rpm2cpio | cpio -idmv` **no** hace y que `rpm -i` sí. ¿Cuál de ellas causa más a menudo el "lo extraje y el servicio sigue sin arrancar"?
- **Q8.2** — ¿Por qué `cpio -idmv '/etc/nginx/nginx.conf'` (con barra inicial) no extrae nada, mientras que `'./etc/nginx/nginx.conf'` funciona?
- **Q8.3** — Los paquetes de RPM 4.14+ pueden usar un compresor de payload `zstd`. ¿Sigue funcionando `rpm2cpio`? ¿Qué te dice eso sobre dónde ocurre la descompresión, y por qué `cpio` nunca necesita enterarse?
- **Q8.4** — Estás en un sistema de rescate Debian sin binario `rpm` en absoluto, y necesitás un archivo de un `.rpm`. Dá un enfoque viable.
- **Q8.5** — Después de la recuperación del paso 4, `rpm -Vf /usr/bin/wc` reporta limpio. Explicá por qué `dnf reinstall coreutils` habría sido, sin embargo, la mejor respuesta en producción.

---

## Ejercicio 9 — Configuración de repositorios: `/etc/yum.conf` y `/etc/yum.repos.d/`

### Pasos

1. Establecé qué es siquiera `yum` en un sistema moderno:

   ```bash
   $ ls -l /usr/bin/yum
   lrwxrwxrwx. 1 root root 5 Jan 11 2023 /usr/bin/yum -> dnf-3
   $ ls -l /etc/yum.conf
   lrwxrwxrwx. 1 root root 12 Jan 11 2023 /etc/yum.conf -> dnf/dnf.conf
   ```

2. Leé la configuración global:

   ```bash
   $ cat /etc/dnf/dnf.conf
   [main]
   gpgcheck=1
   installonly_limit=3
   clean_requirements_on_remove=True
   best=True
   skip_if_unavailable=False
   ```

   Cada opción está documentada en `dnf.conf(5)`. Las opciones que importan en producción:

   | Opción | Efecto |
   |---|---|
   | `gpgcheck` | política global de firmas para paquetes de repositorio |
   | `localpkg_gpgcheck` | política de firmas para `dnf install ./file.rpm` (por defecto `False`) |
   | `installonly_limit` | cuántos kernels retener |
   | `clean_requirements_on_remove` | autoeliminar dependencias huérfanas al hacer `remove` |
   | `best` | fallar en vez de instalar una versión más vieja para satisfacer una resolución |
   | `skip_if_unavailable` | continuar cuando un repo es inalcanzable (peligroso: vistas parciales silenciosas) |
   | `keepcache` | retener los RPM descargados bajo `/var/cache/dnf` |
   | `exclude` | lista negra global de paquetes |
   | `max_parallel_downloads` | 1–20, por defecto 3 |

3. Examiná las definiciones de repositorios:

   ```bash
   $ ls /etc/yum.repos.d/
   rocky-addons.repo  rocky-devel.repo  rocky-extras.repo  rocky.repo
   $ sed -n '1,12p' /etc/yum.repos.d/rocky.repo
   [baseos]
   name=Rocky Linux $releasever - BaseOS
   #baseurl=http://dl.rockylinux.org/$contentdir/$releasever/BaseOS/$basearch/os/
   mirrorlist=https://mirrors.rockylinux.org/mirrorlist?arch=$basearch&repo=BaseOS-$releasever
   gpgcheck=1
   enabled=1
   countme=1
   metadata_expire=6h
   gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9
   ```

4. Resolvé las variables:

   ```bash
   $ python3 -c "import dnf; b=dnf.Base(); print(b.conf.substitutions)"
   {'arch': 'x86_64', 'basearch': 'x86_64', 'releasever': '9', ...}
   $ ls /etc/dnf/vars/
   contentdir  releasever
   $ cat /etc/dnf/vars/contentdir
   pub/rocky
   ```

   Cualquier archivo en `/etc/dnf/vars/` se vuelve `$nombredearchivo`, usable en `baseurl`. Así es como parametrizás un mirror por centro de datos.

5. Listá e inspeccioná repositorios:

   ```bash
   $ dnf repolist
   repo id      repo name
   appstream    Rocky Linux 9 - AppStream
   baseos       Rocky Linux 9 - BaseOS
   extras       Rocky Linux 9 - Extras

   $ dnf repolist --all | head
   $ dnf repoinfo baseos
   Repo-id            : baseos
   Repo-name          : Rocky Linux 9 - BaseOS
   Repo-revision      : 1692...
   Repo-updated       : Sun 20 Aug 2026 04:11:32 AM UTC
   Repo-pkgs          : 6 289
   Repo-available-pkgs: 6 289
   Repo-size          : 7.4 G
   Repo-mirrors       : https://mirrors.rockylinux.org/mirrorlist?...
   Repo-baseurl       : http://mirror.example.net/rocky/9/BaseOS/x86_64/os/
   Repo-expire        : 21 600 second(s) (last: Wed 20 Aug 2026 09:12:00 AM UTC)
   Repo-filename      : /etc/yum.repos.d/rocky.repo
   ```

6. Agregá un repositorio a mano — el método autoritativo, y el único garantizado que esté presente:

   ```bash
   # cat > /etc/yum.repos.d/local-lab.repo <<'EOF'
   [local-lab]
   name=Local lab packages
   baseurl=file:///srv/repo/$releasever/$basearch/
   enabled=1
   gpgcheck=1
   gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-lab
   priority=10
   metadata_expire=60
   EOF
   ```

7. Construí ese repositorio local para que efectivamente resuelva:

   ```bash
   # dnf -y install createrepo_c
   # mkdir -p /srv/repo/9/x86_64 && cp /tmp/pkgs/*.rpm /srv/repo/9/x86_64/
   # createrepo_c /srv/repo/9/x86_64/
   # dnf --disablerepo='*' --enablerepo='local-lab' --nogpgcheck list available
   ```

8. Activá y desactivá repositorios de forma persistente y por invocación:

   ```bash
   # dnf config-manager --set-disabled local-lab       # writes enabled=0 into the .repo file
   # dnf config-manager --set-enabled  local-lab
   # dnf --enablerepo=devel --disablerepo=extras list available kernel   # this run only
   ```

   En Fedora 41+ / DNF 5 el equivalente es `dnf config-manager setopt local-lab.enabled=0`.

9. Gestioná la caché de metadata:

   ```bash
   # du -sh /var/cache/dnf
   # dnf clean all
   38 files removed
   # dnf makecache
   # dnf --refresh check-update      # force metadata refresh regardless of metadata_expire
   ```

### Preguntas de control

- **Q9.1** — Dado `/etc/yum.conf -> dnf/dnf.conf`, ¿una pregunta de examen sobre "editar `/etc/yum.conf`" sigue siendo correcta en RHEL 9? Explicá qué preserva el symlink y qué no (nombrá una opción de YUM 3 que DNF ignora).
- **Q9.2** — Una estrofa de repo tiene descomentados tanto `baseurl` como `mirrorlist`. ¿Cuál usa DNF? Ahora explicá la razón *operativa* por la que un archivo `.repo` viene con `baseurl` comentado.
- **Q9.3** — `skip_if_unavailable=True` está configurado globalmente en una flota. Describí el modo de falla en el que esto convierte un corte breve de red en una regresión de seguridad silenciosa.
- **Q9.4** — Tenés que apuntar 300 hosts a un mirror regional sin editar 300 archivos `.repo`. Describí el enfoque con `/etc/dnf/vars/`, incluyendo el archivo exacto que creás y el `baseurl` que escribís.
- **Q9.5** — En tu estrofa aparece `priority=10`. ¿Lo respeta DNF de fábrica? ¿Qué hay que instalar, y cuál es la diferencia entre `priority` y `cost`?
- **Q9.6** — ¿Cuál es la diferencia práctica entre `dnf clean all` y `dnf --refresh <cmd>`? ¿Cuál es seguro de ejecutar en un cron job sobre un enlace con consumo medido?

---

## Ejercicio 10 — Operaciones cotidianas de `dnf`/`yum`

### Pasos

1. Buscar e identificar:

   ```bash
   $ dnf search nginx
   $ dnf info httpd
   Available Packages
   Name         : httpd
   Version      : 2.4.53
   Release      : 11.el9_2.5
   Architecture : x86_64
   Size         : 45 k
   Source       : httpd-2.4.53-11.el9_2.5.src.rpm
   Repository   : appstream
   Summary      : Apache HTTP Server
   URL          : https://httpd.apache.org/
   License      : ASL 2.0
   ```

2. La búsqueda inversa que abarca todo el repositorio, no solo los paquetes instalados:

   ```bash
   $ dnf provides /usr/sbin/semanage
   policycoreutils-python-utils-3.5-1.el9.noarch : SELinux policy core python utilities
   Repo        : appstream
   Matched from:
   Filename    : /usr/sbin/semanage

   $ dnf provides '*/bin/htpasswd'
   httpd-tools-2.4.53-11.el9_2.5.x86_64 : Tools for use with the Apache HTTP Server
   ```

   Este es el subcomando de DNF más valioso: responde "command not found" de forma definitiva.

3. Modos de listado:

   ```bash
   $ dnf list --installed 'kernel*'
   $ dnf list --available 'nginx*'
   $ dnf list --upgrades
   $ dnf list --extras        # installed, but in no enabled repository
   $ dnf list --obsoletes
   $ dnf list --recent
   ```

4. Chequeá si hay actualizaciones, y leé el código de salida — así se integra el monitoreo:

   ```bash
   $ dnf check-update
   ...
   $ echo $?
   100
   ```

   `0` = sin actualizaciones, `100` = hay actualizaciones disponibles, `1` = error. `dnf check-update` nunca modifica nada.

5. Instalar, reinstalar, actualizar, bajar de versión, eliminar:

   ```bash
   # dnf -y install httpd
   # dnf -y reinstall httpd
   # dnf -y upgrade httpd            # upgrade, not update; 'update' is a kept alias
   # dnf -y downgrade httpd
   # dnf -y remove httpd
   ```

6. Mirá `clean_requirements_on_remove` en acción, y después buscá huérfanos reales:

   ```bash
   # dnf -y install httpd
   # dnf -y remove httpd | grep -A20 'Removing dependent\|Removing unused'
   # dnf -y autoremove
   ```

7. Controlá el solver:

   ```bash
   # dnf install --setopt=install_weak_deps=False vim-enhanced     # skip Recommends
   # dnf install --nobest nginx                                    # accept an older version
   # dnf install --allowerasing some-conflicting-pkg               # permit removals to solve
   # dnf install --downloadonly --downloaddir=/tmp/stage nginx
   # dnf install /tmp/pkgs/nginx-core-1.20.1-14.el9_2.1.x86_64.rpm  # local file, deps from repos
   ```

8. Corregí la marca "instalado por el usuario vs. traído como dependencia", que gobierna `autoremove`:

   ```bash
   # dnf mark install nginx-core     # protect from autoremove (DNF5: dnf mark user)
   # dnf mark remove nginx-core      # demote to dependency (DNF5: dnf mark dependency)
   $ dnf repoquery --userinstalled | head
   ```

9. Sincronización con la distribución — forzar cada paquete a exactamente lo que publican los repos, incluyendo bajadas de versión:

   ```bash
   # dnf distro-sync --assumeno
   ```

### Preguntas de control

- **Q10.1** — Dá la diferencia semántica precisa entre `dnf upgrade foo`, `dnf install foo` (cuando `foo` ya está instalado) y `dnf distro-sync foo`.
- **Q10.2** — `dnf check-update` sale con `100`. ¿Por qué se eligió un código distinto de cero para el caso *normal* de "hay actualizaciones", y qué rompe eso en un script ingenuo con `set -e`?
- **Q10.3** — `dnf list --extras` devuelve `zabbix-agent`. Enumerá tres formas en que un paquete puede terminar en ese estado, y decí cuál es una preocupación de cadena de suministro.
- **Q10.4** — Explicá `best=True` (el valor por defecto en RHEL 9) usando un conflicto concreto, y decí qué resigna `--nobest`.
- **Q10.5** — Después de `dnf remove httpd`, `/etc/httpd/conf/httpd.conf` desapareció pero `/etc/httpd/conf.d/myapp.conf` sobrevivió. Explicá ambos resultados a partir de las reglas de propiedad de archivos de RPM.
- **Q10.6** — ¿Por qué `dnf install ./local.rpm` es categóricamente distinto de `rpm -i ./local.rpm`, y qué opción de `dnf.conf` gobierna la verificación de firmas en ese caso?

---

## Ejercicio 11 — `repoquery`: leer el grafo de dependencias

`dnf repoquery` es `rpm -q` extendido sobre la metadata de repositorios para paquetes que no están instalados. Es de solo lectura y no requiere root.

### Pasos

1. Consultá archivos de un paquete que nunca instalaste:

   ```bash
   $ dnf repoquery -l httpd | head
   /etc/httpd
   /etc/httpd/conf
   /etc/httpd/conf.d
   /etc/httpd/conf.d/README
   /etc/httpd/conf.d/autoindex.conf
   ...
   ```

2. Recorré dependencias en ambas direcciones:

   ```bash
   $ dnf repoquery --requires httpd
   $ dnf repoquery --requires --resolve httpd | head     # capability -> package name
   apr-1.7.0-11.el9.x86_64
   apr-util-1.6.1-20.el9.x86_64
   httpd-core-2.4.53-11.el9_2.5.x86_64
   ...
   $ dnf repoquery --whatrequires httpd-tools
   $ dnf repoquery --whatprovides '/usr/sbin/httpd'
   ```

3. Calculá la clausura recursiva completa — lo que realmente aterriza en el disco:

   ```bash
   $ dnf repoquery --requires --resolve --recursive httpd | wc -l
   64
   ```

4. Consultá dependencias débiles, que explican los paquetes sorpresa:

   ```bash
   $ dnf repoquery --recommends httpd
   $ dnf repoquery --supplements '*'  | head
   ```

5. Restringí al conjunto instalado, o a un repositorio específico:

   ```bash
   $ dnf repoquery --installed --qf '%{name} %{evr} %{from_repo}\n' | head
   $ dnf repoquery --repo=appstream --qf '%{name}\n' | wc -l
   ```

6. Encontrá paquetes instalados que ya no provienen de ningún repo habilitado, y duplicados:

   ```bash
   $ dnf repoquery --extras
   $ dnf repoquery --duplicates
   $ dnf repoquery --unsatisfied
   ```

7. Rastreá un RPM fuente hasta sus binarios — esencial cuando un aviso de CVE nombra el SRPM:

   ```bash
   $ dnf repoquery --qf '%{name}-%{evr}.%{arch} <- %{sourcerpm}\n' httpd
   httpd-0:2.4.53-11.el9_2.5.x86_64 <- httpd-2.4.53-11.el9_2.5.src.rpm
   $ dnf repoquery --whatrequires 'httpd-core' --alldeps
   ```

8. Respondé una pregunta de impacto de punta a punta: *"si actualizo `openssl-libs`, ¿qué paquetes instalados enlazan contra él?"*

   ```bash
   $ dnf repoquery --installed --whatrequires 'libssl.so.3()(64bit)' | head
   ```

### Preguntas de control

- **Q11.1** — Contrastá `rpm -q --whatrequires foo` con `dnf repoquery --whatrequires foo`. ¿Cuál ve paquetes que no están instalados, y cuál ve *provides* satisfechos por un paquete con otro nombre?
- **Q11.2** — `dnf repoquery --requires httpd` lista capabilities como `libapr-1.so.0()(64bit)`. ¿Qué cambia agregar `--resolve`, y por qué la forma sin resolver sigue siendo la representación más precisa de la dependencia?
- **Q11.3** — `dnf repoquery --duplicates` devuelve dos versiones de `kernel-devel`. ¿Es un problema? Ahora supongamos que devuelve dos versiones de `glibc`: ¿*eso* es un problema, y qué lo causó?
- **Q11.4** — Un aviso de seguridad dice "corregido en `nginx-1.20.1-14.el9_2.1.src.rpm`". Dá el comando que te dice qué paquetes binarios instalados están afectados en este host.

---

## Ejercicio 12 — Historial de transacciones y rollback

DNF registra cada transacción en `/var/lib/dnf/history.sqlite`. Este es el log de auditoría y la pila de deshacer.

### Pasos

1. Leé el historial:

   ```bash
   # dnf history list | head
   ID     | Command line             | Date and time    | Action(s)      | Altered
   -------------------------------------------------------------------------------
        8 | -y install httpd         | 2026-08-20 09:31 | Install        |   12
        7 | -y remove nginx          | 2026-08-20 09:28 | Removed        |    3
        6 | -y install nginx         | 2026-08-20 09:25 | Install        |    3
   ```

2. Inspeccioná una transacción completa:

   ```bash
   # dnf history info 8
   Transaction ID : 8
   Begin time     : Wed 20 Aug 2026 09:31:02 AM UTC
   Begin rpmdb    : 243:5f2a...
   End time       : Wed 20 Aug 2026 09:31:14 AM UTC (12 seconds)
   End rpmdb      : 255:9b1c...
   User           : root <root>
   Return-Code    : Success
   Releasever     : 9
   Command Line   : -y install httpd
   Packages Altered:
       Install httpd-2.4.53-11.el9_2.5.x86_64        @appstream
       Install httpd-core-2.4.53-11.el9_2.5.x86_64   @appstream
       ...
   ```

3. Consultá el historial por paquete — "quién instaló esto y cuándo":

   ```bash
   # dnf history list httpd
   # dnf history userinstalled | head
   ```

4. Deshacer, rehacer y revertir:

   ```bash
   # dnf history undo 8          # invert transaction 8 only
   # dnf history redo 8          # repeat transaction 8
   # dnf history rollback 6      # revert everything after ID 6
   ```

5. Confirmá el efecto, y después restablecé un estado conocido:

   ```bash
   # dnf history undo last
   # rpm -qa | sort > /root/current-packages.txt
   # diff /root/baseline-packages.txt /root/current-packages.txt
   ```

6. Notá dónde `undo` no puede ayudar:

   ```bash
   # dnf history info 8 | grep -i 'Return-Code'
   ```

### Preguntas de control

- **Q12.1** — Distinguí `dnf history undo 8`, `dnf history rollback 8` y `dnf history redo 8` en un sistema que está actualmente en la transacción 12.
- **Q12.2** — `dnf history undo` de una transacción de actualización reinstala los paquetes más viejos. Nombrá tres cosas que **no** restaura, y explicá por qué "rollback" es una palabra engañosa para eso.
- **Q12.3** — ¿Para qué sirven los checksums `Begin rpmdb` y `End rpmdb`, y qué significa que `dnf history` reporte que la base de datos fue alterada fuera de DNF?
- **Q12.4** — Un `dnf history undo` se niega a ejecutarse porque los paquetes más viejos ya no están en ningún repositorio. Dá dos formas de proceder, y enunciá la opción de `dnf.conf` que habría prevenido la situación.

---

## Ejercicio 13 — Grupos, módulos y bloqueo de versiones

### Pasos

1. Grupos — un paquete-bundle definido por el repositorio, no un concepto de RPM:

   ```bash
   $ dnf group list
   Available Environment Groups:
      Server with GUI
      Minimal Install
   Available Groups:
      Container Management
      Development Tools
      ...
   $ dnf group info "Development Tools" | head -20
   # dnf -y group install "Development Tools"
   # dnf group list --installed
   # dnf -y group remove "Development Tools"
   ```

   Notá que `dnf install @"Development Tools"` es la forma abreviada equivalente.

2. Contenido modular (RHEL 8/9 AppStream) — versiones paralelas de la misma aplicación:

   ```bash
   $ dnf module list nodejs
   Name     Stream   Profiles                     Summary
   nodejs   18 [d]   common [d], development,...  Javascript runtime
   nodejs   20       common [d], development,...  Javascript runtime
   # dnf -y module enable nodejs:20
   # dnf -y module install nodejs:20/common
   $ dnf module list --enabled
   # dnf -y module reset nodejs
   ```

3. Bloqueo de versiones — fijar un paquete contra actualizaciones:

   ```bash
   # dnf versionlock add nginx
   Adding versionlock on: nginx-1:1.20.1-14.el9_2.1
   # dnf versionlock list
   nginx-1:1.20.1-14.el9_2.1.*
   $ cat /etc/dnf/plugins/versionlock.list
   # dnf upgrade nginx
   Package nginx is excluded by versionlock.
   Nothing to do.
   # dnf versionlock delete nginx
   ```

4. La alternativa contundente — exclusiones globales:

   ```bash
   # grep -n '^exclude' /etc/dnf/dnf.conf
   # dnf --disableexcludes=all upgrade kernel
   ```

### Preguntas de control

- **Q13.1** — ¿Dónde viven las definiciones de grupos? Demostrá que no se almacenan en la base de datos RPM, y explicá qué se rompe cuando se deshabilita un repositorio después de haber instalado uno de sus grupos.
- **Q13.2** — Explicá la diferencia entre `dnf module reset nodejs` y `dnf module disable nodejs`. ¿Cuál es el precursor correcto para cambiar de stream, y por qué el otro provoca una falla de resolución?
- **Q13.3** — `versionlock` frente a `exclude=` en `dnf.conf` frente a `--exclude=` en la línea de comandos: ordená los tres por alcance y persistencia, y decí cuál todavía deja pasar un parche de *seguridad*.
- **Q13.4** — Un `nginx` pineado bloquea un `dnf upgrade` de todo el sistema con un conflicto de dependencias. ¿Cuál es la falla exacta que reporta el solver, y cuál es la resolución menos dañina?

---

## Ejercicio 14 — `zypper` en openSUSE

Cambiá al contenedor `lpic-zypper`. Zypper es un front end distinto sobre el mismo back end RPM — la mitad `rpm` de este objetivo se transfiere sin cambios.

### Pasos

1. Localizá la configuración. Notá que las rutas *no* son `/etc/yum*`:

   ```bash
   $ ls /etc/zypp/
   credentials.d  locks  repos.d  services.d  systemCheck.d  zypp.conf  zypper.conf
   $ ls /etc/zypp/repos.d/
   repo-oss.repo  repo-non-oss.repo  repo-update.repo
   $ cat /etc/zypp/repos.d/repo-oss.repo
   [repo-oss]
   name=Main Repository
   enabled=1
   autorefresh=1
   baseurl=http://download.opensuse.org/distribution/leap/$releasever/repo/oss/
   type=rpm-md
   gpgcheck=1
   gpgkey=http://download.opensuse.org/distribution/leap/$releasever/repo/oss/repodata/repomd.xml.key
   ```

2. Gestión de repositorios:

   ```bash
   # zypper lr -uEP                       # list: URI, Enabled only, Priority
   #  | Alias       | Name              | Enabled | GPG Check | Refresh | Priority | URI
   # --+-------------+-------------------+---------+-----------+---------+----------+-----
   #  1| repo-oss    | Main Repository   | Yes     | (r ) Yes  | Yes     |   99     | http://...
   #
   # zypper ar -f -n "Packman" https://ftp.gwdg.de/pub/linux/misc/packman/suse/openSUSE_Leap_15.6/ packman
   # zypper mr -p 90 packman              # modify priority (lower number = higher priority)
   # zypper mr -d packman                 # disable
   # zypper mr -e packman                 # enable
   # zypper ref                           # refresh metadata
   # zypper rr packman                    # remove repository
   ```

3. Búsqueda e inspección:

   ```bash
   $ zypper se nginx                      # search
   $ zypper se -s -i bash                 # detailed, installed only
   $ zypper if bash                       # info
   $ zypper wp /bin/bash                  # what-provides
   $ zypper pa -r repo-oss | head         # packages in a repo
   ```

4. Transacciones:

   ```bash
   # zypper -n in nginx                   # -n = --non-interactive
   # zypper in -f nginx                   # force reinstall
   # zypper rm --clean-deps nginx
   # zypper up                            # upgrade installed packages, keep vendor/arch
   # zypper dup                           # distribution upgrade: allows vendor change, removals
   # zypper in --dry-run nginx
   ```

5. Parches — el concepto de SUSE sin equivalente en DNF:

   ```bash
   # zypper lp                            # list-patches
   # zypper patch-check
   # zypper patch --category security
   ```

6. Salud y bloqueos:

   ```bash
   # zypper ve                            # verify dependency consistency, offer repairs
   # zypper ps                            # processes still using deleted libraries
   # zypper al nginx                      # addlock (equivalent of versionlock)
   # zypper ll                            # list locks -> /etc/zypp/locks
   # zypper rl nginx                      # removelock
   ```

7. Leé los códigos de salida, que son más ricos que los de DNF:

   ```bash
   # zypper patch-check; echo "exit=$?"
   ```

   | Código | Significado |
   |---|---|
   | 0 | éxito / nada que hacer |
   | 100 | hay parches disponibles |
   | 101 | hay parches de seguridad disponibles |
   | 102 | se requiere reinicio |
   | 103 | zypper mismo fue actualizado — reinicialo |
   | 104 | capability no encontrada |
   | 106 | algún repositorio no pudo refrescarse |

### Preguntas de control

- **Q14.1** — Mapeá cada uno de estos comandos de DNF a su equivalente en zypper: `dnf provides`, `dnf repolist`, `dnf list --installed`, `dnf config-manager --set-disabled`, `dnf autoremove`.
- **Q14.2** — Explicá la diferencia entre `zypper up` y `zypper dup` en términos de cambios de vendor y eliminaciones de paquetes. ¿Cuál usás después de agregar Packman, y por qué el otro está mal?
- **Q14.3** — Prioridades en Zypper: un repositorio con `priority=90` frente a uno con `priority=99`. ¿Cuál gana, y en qué se diferencia esa convención del plugin `priority` de DNF? (Ojo — este es un error entre distribuciones muy común.)
- **Q14.4** — `zypper ps` reporta que `httpd` está usando archivos borrados después de una actualización. ¿Qué pasó a nivel del sistema de archivos, y por qué reiniciar el servicio es obligatorio y no cosmético?
- **Q14.5** — El código de salida 103 tiene un significado operativo específico. ¿Qué debe hacer un script de parcheo desatendido cuando lo ve?

---

## Ejercicio 15 — Diagnóstico bajo presión

Cuatro incidentes realistas. Trabajá cada uno antes de leer la respuesta.

### Incidente A — base de datos RPM corrupta

1. Reproducilo (solo en el contenedor):

   ```bash
   # cp -a /var/lib/rpm /var/lib/rpm.bak
   # dd if=/dev/urandom of=/var/lib/rpm/rpmdb.sqlite bs=1 count=512 seek=8192 conv=notrunc
   # rpm -qa | head
   error: rpmdbNextIterator: skipping h#     ...
   ```

2. Recuperá:

   ```bash
   # rm -f /var/lib/rpm/.rpm.lock
   # rpm --rebuilddb
   # rpm -qa | wc -l
   ```

3. Si `--rebuilddb` no puede ayudar, restaurá desde la copia que mantiene DNF:

   ```bash
   # ls /var/lib/rpm/  /usr/lib/sysimage/rpm/ 2>/dev/null
   # ls -d /var/lib/dnf/history.sqlite*
   ```

4. Restaurá tu copia de seguridad y seguí adelante:

   ```bash
   # rm -rf /var/lib/rpm && mv /var/lib/rpm.bak /var/lib/rpm && rpm -qa | wc -l
   ```

### Incidente B — "conflicts with file from package"

1. Reproducilo:

   ```bash
   # dnf -y install httpd
   # rpm -ivh --force --nodeps /tmp/pkgs/nginx-core-1.20.1-14.el9_2.1.x86_64.rpm
   ```

2. Diagnosticá un conflicto de archivos real:

   ```bash
   # rpm -qf /usr/share/man/man8/httpd.8.gz
   # rpm -qp --qf '[%{FILENAMES}\n]' /tmp/pkgs/nginx-core-*.rpm | sort > /tmp/new.txt
   # rpm -ql httpd | sort > /tmp/old.txt
   # comm -12 /tmp/old.txt /tmp/new.txt
   ```

### Incidente C — un paquete que no se va

1. Reproducí una divergencia entre base de datos y sistema de archivos:

   ```bash
   # rpm -q --qf '%{NAME}\n' nginx-filesystem
   # rm -f $(rpm -ql nginx-filesystem | head -1)
   # rpm -V nginx-filesystem
   ```

2. Considerá las dos reparaciones y elegí:

   ```bash
   # dnf -y reinstall nginx-filesystem      # correct
   # rpm -e --justdb nginx-filesystem       # database-only removal: leaves files orphaned
   ```

### Incidente D — disco lleno por la caché de paquetes y kernels viejos

1. Medí:

   ```bash
   # du -sh /var/cache/dnf /var/cache/PackageKit 2>/dev/null
   # rpm -q kernel | wc -l
   ```

2. Recuperá espacio:

   ```bash
   # dnf clean packages
   # dnf remove --oldinstallonly --setopt=installonly_limit=2 kernel
   # grep -n 'keepcache\|installonly_limit' /etc/dnf/dnf.conf
   ```

### Preguntas de control

- **Q15.1** — `rpm --rebuilddb` arregló el Incidente A. Explicá exactamente qué reconstruye y qué no puede recuperar. ¿Por qué es un no-op para un `Packages`/`rpmdb.sqlite` verdaderamente destruido?
- **Q15.2** — En el Incidente B, usaste `--force --nodeps` para *crear* el problema. Explicá por qué `dnf` nunca podría haber producido ese estado, y nombrá la fase de chequeo de transacción que lo habría detenido.
- **Q15.3** — Incidente C: después de `rpm -e --justdb nginx-filesystem`, ¿qué reporta `rpm -qf /etc/nginx`, y cuál es el camino más limpio de vuelta a un sistema consistente?
- **Q15.4** — Incidente D: ¿por qué `dnf remove kernel` sin calificar conlleva riesgo de caída de servicio, y qué hace que `--oldinstallonly` sea seguro? ¿Qué te protege a nivel del gestor de arranque?
- **Q15.5** — En un host donde `dnf` mismo está roto (su stack de Python quedó a medio actualizar), todavía tenés `rpm` y acceso a la red. Delineá una recuperación que use solo `rpm`, `rpm2cpio` y una URL de mirror.

---

## Limpieza

```bash
$ exit
$ podman rm -f lpic-rpm lpic-zypper
```

---

## Fuentes oficiales

- LPI — *Exam 102-500 Objectives, version 5.0* (objetivo 102.5): <https://www.lpi.org/our-certifications/exam-102-objectives/>
- LPI — *Exam 101-500 Objectives, version 5.0*: <https://www.lpi.org/our-certifications/exam-101-objectives/>
- RPM Project — *RPM Documentation* (`rpm(8)`, `rpm2cpio(8)`, `rpmkeys(8)`, formatos de consulta, flags de verificación): <https://rpm-software-management.github.io/rpm/manual/>
- RPM Project — *Package signing and verification*: <https://rpm-software-management.github.io/rpm/manual/signatures_digests.html>
- DNF Project — *DNF Command Reference*: <https://dnf.readthedocs.io/en/latest/command_ref.html>
- DNF Project — *DNF Configuration Reference (`dnf.conf(5)`)*: <https://dnf.readthedocs.io/en/latest/conf_ref.html>
- DNF Project — *DNF 5 documentation*: <https://dnf5.readthedocs.io/en/latest/>
- Red Hat — *Managing software with the DNF tool (RHEL 9)*: <https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_software_with_the_dnf_tool/index>
- openSUSE — *Managing Software with Command Line Tools* (zypper), openSUSE Leap Reference: <https://doc.opensuse.org/documentation/leap/reference/html/book-reference/cha-sw-cl.html>
- openSUSE Wiki — *SDB:Zypper usage*: <https://en.opensuse.org/SDB:Zypper_usage>
- Fedora Project — *createrepo_c*: <https://github.com/rpm-software-management/createrepo_c>

---

<details>
<summary><strong>▶ Respuestas</strong> — abrí solo después de intentar todas las preguntas de control</summary>

### Ejercicio 0

**A0.1** — Las consultas leen `/var/lib/rpm/`, que es legible por todo el mundo, así que cualquier usuario puede abrir la base de datos en modo lectura. Las transacciones necesitan acceso de escritura a `/var/lib/rpm/` (para registrar el cambio y tomar `.rpm.lock`) **y** acceso de escritura a las rutas de destino bajo `/usr`, `/etc`, `/var` — todas propiedad de root. Además, los scriptlets corren como root y RPM debe poder fijar owner/group/capabilities arbitrarios en los archivos extraídos, lo que requiere `CAP_CHOWN`/`CAP_FOWNER`/`CAP_SETFCAP`.

**A0.2** — RPM 4.16 (RHEL 9, Fedora 33+) usa por defecto el backend **sqlite**. `rpm -E '%{_db_backend}'` lo imprime — `-E` (`--eval`) expande una macro de rpm, así que reporta el valor configurado en vez de lo que vos inferís de un listado de directorio. RHEL 8 / RPM 4.14 usa `bdb` por defecto.

**A0.3** — NEVRA = **N**ame `bash`, **E**poch (ausente, por lo tanto implícitamente `0`), **V**ersion `5.1.8`, **R**elease `6.el9_1`, **A**rchitecture `x86_64`. El que falta es el Epoch: se omite en la visualización cuando es cero. Precisamente por eso la salida de `rpm -qa` no puede realimentarse a una comparación de versiones sin cuidado — usá `%{EVR}` o `%{EPOCH}:%{VERSION}-%{RELEASE}` de forma explícita.

---

### Ejercicio 1

**A1.1** — (1) Una distribución o configuración de build distinta: SUSE y Fedora 41+ ubican la base de datos en `/usr/lib/sysimage/rpm` con `/var/lib/rpm` como symlink de compatibilidad; usá `rpm -E '%{_dbpath}'` y `--dbpath <path>` para apuntar a una específica. (2) Trabajo de rescate o de imágenes de contenedor donde el sistema de archivos de destino está montado en otro lado: usá `rpm --root /mnt/sysimage -qa`, que reubica *tanto* la ruta de la base de datos como las rutas de archivos.

**A1.2** —
```bash
rpm -qa --qf '%{VENDOR}|%{NAME}\n' | awk -F'|' '$1=="(none)"{print $2}'
```
Los paquetes sin vendor típicamente fueron construidos localmente, descargados de una fuente no oficial, o producidos por `alien`/`fpm`. Quedan fuera del pipeline de firmado y seguimiento de CVE de la distribución, así que ningún equipo de seguridad los mira y ningún `dnf upgrade` los va a parchear jamás.

**A1.3** — Los 200 paquetes de una sola transacción reciben valores de `INSTALLTIME` esencialmente idénticos (con segundos de diferencia, en el orden interno de RPM, no en el orden que esperarías), así que `--last` degenera en un ordenamiento arbitrario dentro de ese bloque, y no puede distinguir "actualizado" de "recién instalado" — RPM solo almacena el momento de instalación de la versión *actual*. Usá en cambio `dnf history list` / `dnf history info <id>`: eso registra la línea de comandos, el usuario, la acción por paquete y los checksums de rpmdb de antes y después.

**A1.4** — `%{SIZE}` es el tamaño **descomprimido, instalado**: la suma de los tamaños en bytes de los archivos del payload tal como aterrizan en el disco. El archivo `.rpm` es el payload comprimido (gzip/xz/zstd) más las secciones de firma y header. Un RPM de `nginx` de 617 kB comúnmente instala 1,6 MB. Ninguna de las dos cifras contempla el redondeo a bloques del sistema de archivos, así que el consumo real de disco difiere otra vez.

---

### Ejercicio 2

**A2.1** — `/etc/bashrc` pertenece a `setup` (`rpm -qf /etc/bashrc` → `setup-2.13.7-10.el9.noarch`). Las distribuciones de la familia Red Hat separan el *binario del shell* (`bash`) del *entorno de shell del sistema* (`setup`, que además es dueño de `/etc/profile`, `/etc/passwd`, `/etc/group`, `/etc/hosts`, `/etc/shells`). La consecuencia práctica: una actualización de `bash` nunca toca `/etc/bashrc`, y la personalización del sitio del entorno de login sobrevive a las actualizaciones del shell.

**A2.2** — `rpm -qi bash` consulta la base de datos de lo **instalado** por nombre de paquete; falla con `package bash is not installed` si está ausente. `rpm -qip <file>.rpm` agrega `-p`, que lee el header directamente de un **archivo** (o URL) y nunca consulta la base de datos; falla solo si el archivo falta o es ilegible. El primero puede reportar "not installed"; el segundo no puede.

**A2.3** — No hay bucle porque RPM resuelve *capabilities*, no paquetes, y un paquete satisface sus propios requisitos. Durante el chequeo de la transacción, el `Requires: /bin/sh` de `bash` se coteja contra el conjunto de provides que existirá *después* de la transacción, que incluye el propio `Provides: /bin/sh` de `bash`. Para `rpm -e bash`, el chequeo de borrado encuentra todos los *otros* paquetes instalados que requieren `/bin/sh` — típicamente decenas de scriptlets `%post` y scripts de shell — así que la eliminación se rechaza. La autodependencia no la bloquea; la dependencia de todos los demás sí.

**A2.4** —
```bash
rpm -q --qf '%{NAME}-%{EVR}\n' openssl
```
comparado contra el EVR conocido como corregido (mecánicamente con `rpmdev-vercmp`, o `rpm --eval` sobre ambos). Version-release es autoritativo porque Red Hat y sus derivados hacen *backport* de las correcciones: el número de versión upstream no se mueve, solo cambia el release. Grepear `--changelog` buscando un identificador de CVE es más débil porque el changelog es texto libre, las entradas pueden quedar truncadas por la poda de `%changelog` en tiempo de build, y un paquete reconstruido o de terceros puede llevar la corrección sin el texto — o el texto sin la corrección.

**A2.5** — `config(bash)` es una capability virtual cuya versión sigue al EVR del propio paquete. Existe para que una **división en subpaquetes** siga siendo coherente: si más adelante los archivos de configuración se mueven a un paquete `bash-config` aparte, ese paquete provee `config(bash) = <mismo EVR>`, y la dependencia de cada consumidor sigue resolviendo a una versión coincidente. Además permite que otros paquetes dependan de "la configuración de bash en esta versión exacta" sin depender del paquete binario por nombre.

---

### Ejercicio 3

**A3.1** — (1) Se instaló desde un tarball o instalador del proveedor en `/opt` o `/usr/local`, fuera del control de RPM. (2) `which java` resolvió un symlink gestionado por `alternatives`; el symlink mismo bajo `/etc/alternatives` puede no tener dueño aunque el binario real sí lo tenga — consultá el destino resuelto con `rpm -qf $(readlink -f $(which java))`. (3) Es un Snap/Flatpak/contenedor o una instalación de un gestor de lenguaje (SDKMAN, asdf) que RPM nunca ve.

**A3.2** — `rpm -q --whatrequires bash` solo coincide con dependencias expresadas literalmente como la cadena `bash`. La mayoría de los paquetes dependen en cambio de la *capability* `/bin/sh`, que `bash` provee. Así que la consulta de impacto correcta es `rpm -q --whatrequires /bin/sh`, y en general tenés que unir los resultados sobre cada capability de `rpm -q --provides bash`. Exactamente por eso `dnf remove` — que resuelve contra el conjunto completo de provides — es la herramienta adecuada para el análisis de impacto, y `rpm -q --whatrequires` es solo un primer vistazo.

**A3.3** — `1`. En un script, eso significa que `set -e` aborta en la primera ruta sin dueño, y un ingenuo `if rpm -qf "$f"` trata "sin dueño" de forma idéntica a "rpm falló" o "no existe el archivo". Distinguí capturando stderr, o manejá el bucle con `rpm -qf "$f" >/dev/null 2>&1 || echo "unowned: $f"` para que el estado distinto de cero sea la rama esperada y no un error.

**A3.4** — Sí, cuando ambos paquetes declaran el archivo con contenido, modo, owner y group idénticos, y al menos uno no está marcado como `%config`; RPM lo permite como archivo compartido e instala una sola copia. `rpm -qf` entonces imprime **ambos** NEVRA de paquete, uno por línea. Si los contenidos difieren, la segunda instalación falla con `file ... conflicts between attempted installs` salvo que se pase `--replacefiles` — que es el mecanismo detrás del Incidente B.

---

### Ejercicio 4

**A4.1** — Sin `-p`, `rpm -ql` trata el argumento como un **nombre de paquete** para buscar en la base de datos de lo instalado. Busca un paquete llamado literalmente `nginx-1.20.1-14.el9_2.1.x86_64.rpm`, no encuentra nada, y reporta `package nginx-...rpm is not installed`. El flag `-p` es lo que cambia la fuente de selección de la base de datos al archivo.

**A4.2** — Una revisión mínima:
1. `rpm -Kv pkg.rpm` — ¿está firmado, por una clave en la que confiás, y el payload está íntegro?
2. `rpm -qp --scripts pkg.rpm` — ¿qué código corre como root en el momento de instalación/eliminación? Esta es la superficie de mayor riesgo.
3. `rpm -qlp pkg.rpm` — ¿dónde escribe? Buscá cualquier cosa bajo `/etc/cron*`, `/etc/sudoers.d`, `/usr/lib/systemd/system`, `/etc/ld.so.conf.d`, o rutas que pertenezcan a otro paquete.
4. `rpm -qp --requires pkg.rpm` y `rpm -qip pkg.rpm` — ¿arrastra dependencias inesperadas, y `Vendor`, `Packager`, `URL` y `Source RPM` son consistentes con el origen declarado?

Una quinta que vale la pena agregar: `rpm -qp --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' pkg.rpm | grep -E '^-..s' ` para detectar archivos setuid.

**A4.3** — El algoritmo de comparación de RPM divide cada cadena en corridas de dígitos y corridas de letras, y luego compara corrida por corrida; **las corridas de dígitos se comparan numéricamente**, así que `14 > 9`. El `sort` lexicográfico compara carácter por carácter, donde `'1' < '9'`, dando la respuesta equivocada. El sufijo `el9_2` marca el stream de release menor RHEL 9.2 (un build Z-stream); participa de la misma comparación segmentada, y por eso `-14.el9_2.1` ordena por encima de `-14.el9` — el segmento extra `.1` lo hace más largo y por lo tanto más nuevo cuando todos los segmentos precedentes son iguales.

**A4.4** — El Epoch se compara **primero** y domina por completo a la versión y al release: `1:1.0-1` es más nuevo que `0:9.9-9`. Existe para escapar de un error de versionado, como que upstream renumere de `2020.05` a `1.0`. Es una puerta sin retorno porque el epoch nunca puede bajarse — un paquete con `Epoch: 1` supera a todo build futuro con `Epoch: 0` para siempre, así que cada reconstrucción downstream, cada distribución derivada y cada repositorio de terceros tiene que arrastrar el epoch desde entonces. Incrementarlo es un compromiso permanente.

---

### Ejercicio 5

**A5.1** — RPM firma dos veces. La **firma del header** cubre la región del header (toda la metadata, listas de archivos, dependencias y scriptlets) más un digest del payload. La **firma/digest del payload** (`MD5 digest`, y en V4 la firma combinada header+payload) cubre el archivo comprimido. Manipular un byte del payload rompe el digest del payload y la firma header+payload, pero el header mismo queda intacto, así que su firma sigue verificando. La firma solo del header es significativa porque todo lo que decide *qué va a hacer RPM* — rutas de archivos, permisos, capabilities, scriptlets — vive en el header. Además habilita la verificación de firmas de paquetes transmitidos desde un repositorio antes de que el payload termine de descargarse.

**A5.2** — `digests OK` significa únicamente que los checksums internos son autoconsistentes: el archivo no está corrupto, y nada más. Cualquiera puede construir un paquete así. `digests signatures OK` significa que los checksums verificaron **y** que una firma criptográfica validó contra una clave ya importada en el keyring de RPM. Un gate de CI debe exigir la segunda, y además debe afirmar *qué* key ID lo firmó — una salida de `rpm -Kv` que contenga un key ID inesperado es una falla aunque diga `OK`.

**A5.3** — Guardar las claves como pseudo-paquetes `gpg-pubkey-<keyid>-<timestamp-de-creación>` hace que el keyring herede gratis todo el instrumental de RPM: `rpm -qa gpg-pubkey\*` lista la confianza, `rpm -qi` muestra la metadata completa de la clave y su expiración, `rpm -e gpg-pubkey-<id>` la revoca, y el conjunto de claves confiables forma parte de la misma base de datos transaccional donde vive todo lo demás — así que queda capturado por los backups, por los checksums de rpmdb de `dnf history`, y por la gestión de configuración que ya razona sobre paquetes instalados. Un archivo de keyring separado necesitaría su propio instrumental, su propia auditoría y su propia historia de backups.

**A5.4** — `--nogpgcheck` deshabilita la verificación de que el paquete fue firmado por una clave confiable, lo que significa que un atacante capaz de servir o modificar el RPM — un mirror comprometido, una entrada DNS secuestrada, un atacante en el camino sobre HTTP plano, un repositorio interno envenenado — puede enviar scriptlets `%pre`/`%post` arbitrarios que se ejecutan como root. Las dos causas raíz comunes y sus correcciones adecuadas: (1) la clave de firmado del repositorio no está importada → `rpm --import <URL o archivo de gpgkey>`, o corregí la línea `gpgkey=` en la estrofa `.repo`; (2) el paquete genuinamente no está firmado porque es un artefacto construido localmente → firmalo (`rpm --addsign`) con una clave interna e importá esa clave, en vez de deshabilitar el chequeo en toda la flota.

**A5.5** — La configuración por repositorio gana para los paquetes de ese repositorio; `[main]` en `dnf.conf` solo provee el valor por defecto para los repositorios que no declaran uno. `localpkg_gpgcheck` es un interruptor separado que gobierna los paquetes instalados desde una **ruta de archivo local** (`dnf install ./foo.rpm`); su valor por defecto es `False`, que es el default sorprendente y peligroso — ponelo en `True` en hosts de producción.

---

### Ejercicio 6

**A6.1** — `S` difiere el tamaño (agregaste una línea), `.` modo sin cambios, `5` difiere el digest (cambió el contenido), `.` sin discrepancia de dispositivo, `.` no es un symlink, `.` usuario sin cambios, `.` grupo sin cambios, `T` difiere el mtime (el append lo actualizó), `.` capabilities sin cambios. Después `c` lo marca como archivo `%config` y `/etc/skel/.bashrc` es la ruta. `M`, `U` y `G` son puntos porque `echo >>` cambia solo el contenido y los timestamps de metadata, nunca el modo ni la propiedad de un archivo existente.

**A6.2** — Los archivos `%config` son editables por el administrador, así que RPM no va a descartar en silencio los cambios locales. En una **actualización**: si modificaste el archivo y la versión del paquete nuevo también difiere, RPM instala la versión nueva como `<archivo>.rpmnew` y deja la tuya en su lugar — para `%config(noreplace)`. Para `%config` a secas, RPM instala el archivo nuevo y guarda el tuyo como `<archivo>.rpmsave`. Mnemotecnia: **`.rpmnew` = el archivo nuevo fue apartado** (ganó tu versión); **`.rpmsave` = tu archivo fue guardado aparte** (ganó la versión del paquete). En un **borrado**, un archivo `%config` modificado se preserva como `.rpmsave`. `dnf reinstall` restaura incondicionalmente los archivos del payload que no son de configuración, y por eso volvió `AUTHORS`, mientras que tu edición de `.bashrc` estuvo protegida por esa misma lógica de `noreplace`.

**A6.3** — Esperables e inofensivos: (1) archivos `%config` que vos o la gestión de configuración editaron legítimamente — `S.5....T.  c /etc/ssh/sshd_config`; (2) diferencias solo de mtime `.T` por backup/restore, `rsync` sin `-t`, o reconstrucciones de capas de contenedor; (3) archivos modificados deliberadamente por herramientas de post-instalación — `prelink`, `authselect`, symlinks de `alternatives`, cachés generadas por `ldconfig`, y archivos `%ghost` que se supone que están ausentes o se regeneran. `rpm -Va` no es un HIDS porque su línea base — los digests en `/var/lib/rpm` — vive en el mismo host, mutable por el mismo root que el atacante ahora tiene. AIDE almacena una línea base firmada fuera del host o en medios de solo lectura, cubre archivos sin dueño de los que RPM no sabe nada, y detecta la manipulación de la base de datos que RPM no puede.

**A6.4** — `--setperms` restaura los modos desde la metadata del paquete; los modos casi nunca se personalizan intencionalmente por sitio, y equivocarlos es en sí mismo un problema de seguridad, así que restaurarlos es el acto conservador. `--setugids` restaura owner y group, y eso *sí* se personaliza a menudo: un sitio puede chownear `/var/log/nginx` o un directorio de spool a una cuenta de servicio, o el endurecimiento puede acotar un grupo. Ejecutar `--setugids` a ciegas revierte esas decisiones y puede devolverle acceso a los archivos a un grupo más amplio, o romper un servicio que ya no es dueño de su propio estado. Además, `--setugids` sobre un paquete que contiene binarios setuid puede producir una ventana transitoria con propiedad incorrecta. Verificá la desviación intencional con `rpm -V` primero, y después corregí archivos puntuales.

**A6.5** — `rpm -V` reporta **limpio**. La verificación compara el sistema de archivos contra los digests almacenados en la misma base de datos que el atacante acaba de reescribir, así que un atacante con nivel root cierra el círculo trivialmente (y `rpm --justdb`/`rpm --rebuilddb` lo hacen fácil). La lección arquitectónica: una línea base de integridad solo es significativa si está fuera del límite de confianza de aquello que mide — firmada y almacenada fuera del host, en medios de solo lectura, o anclada en hardware (IMA/EVM con una clave sellada por TPM). `rpm -V` es un buen detector de *deriva* y un pobre detector de *intrusión*.

---

### Ejercicio 7

**A7.1** —

| | paquete ausente | versión más vieja instalada | misma versión instalada |
|---|---|---|---|
| `rpm -i` | instala | instala **en paralelo** (ambas versiones presentes; normalmente un conflicto de archivos, o dos entradas para paquetes de solo instalación) | falla: `package ... is already installed` |
| `rpm -U` | instala | actualiza, quitando la versión vieja | falla: `already installed` (salvo con `--replacepkgs`) |
| `rpm -F` | **no hace nada** | actualiza, quitando la versión vieja | no hace nada |

Las distinciones esenciales: `-U` instala cuando está ausente, `-F` no; `-i` nunca quita la versión vieja, `-U` y `-F` sí.

**A7.2** — `-U` borra la versión vieja, lo que elimina `/lib/modules/<versionvieja>/` mientras el sistema en ejecución la está usando. Toda carga posterior de módulos falla — no hay nuevo sistema de archivos, ni nuevo driver de red, ni `nvidia.ko` después de un evento de hardware — y si el kernel nuevo no arranca, no tenés entrada previa a la cual volver. `installonlypkgs` (con `installonly_limit`) es el mecanismo correcto porque hace de la seguridad una **propiedad del conjunto de paquetes impuesta por el resolvedor de dependencias**, aplicada de forma idéntica por cada administrador, cada ejecución de automatización y cada job desatendido de `dnf-automatic`. La disciplina falla la primera vez que alguien tipea `-U` a las 3 de la mañana; la configuración no.

**A7.3** — `glibc` se elimina de la base de datos y sus archivos — `/lib64/libc.so.6`, `ld-linux-x86-64.so.2`, `/lib64/libm.so.6` — se borran. Todo binario enlazado dinámicamente del sistema deja de funcionar inmediatamente: `ls`, `bash`, el propio `rpm`. Los procesos ya en ejecución sobreviven gracias a sus descriptores de archivo abiertos hasta que hagan exec. Ningún comando `rpm` puede recuperarlo porque `rpm` está enlazado dinámicamente contra la biblioteca que acaba de borrar, así que ni siquiera puede arrancar. La recuperación requiere una raíz externa: bootear medios de rescate, hacer chroot al sistema de archivos y reinstalar glibc desde ahí — o un busybox enlazado estáticamente que ya estuviera presente.

**A7.4** — RPM realiza su chequeo de dependencias sobre el **conjunto entero de la transacción**, no paquete por paquete. Nombrar los tres RPM los convierte en una sola transacción, así que el requisito de `nginx` sobre `nginx-core` queda satisfecho por otro miembro del mismo conjunto. Instalarlos de a uno funciona *solo en orden de dependencias* — `nginx-filesystem`, después `nginx-core`, después `nginx` — porque entonces cada transacción individual puede satisfacerse con lo ya instalado. Instalar `nginx` primero es una transacción de un solo paquete cuyas dependencias no están cubiertas, así que falla. Este es todo el argumento a favor de un resolvedor de dependencias: calcula ese orden, y el conjunto correcto, por vos.

**A7.5** — `--force` = `--replacepkgs` (reinstalar un paquete ya instalado) + `--replacefiles` (sobrescribir archivos que pertenecen a otro paquete) + `--oldpackage` (permitir instalar una versión más vieja sobre una más nueva). `--replacefiles` por sí solo es lo correcto cuando dos paquetes legítimamente entregan el mismo archivo y verificaste que los contenidos son idénticos o que el conflicto es un bug de empaquetado conocido — por ejemplo un archivo de documentación duplicado entre un paquete dividido y su predecesor durante un renombramiento, donde el proveedor confirmó que sobrescribir es seguro. Acotalo todavía más chequeando primero el conflicto con `comm -12` sobre las dos listas de archivos, como en el Incidente B.

**A7.6** — `--justdb` actualiza solo la base de datos RPM: registra el paquete como instalado (o eliminado) sin tocar ningún archivo del disco. Uso legítimo: restauraste un sistema de archivos desde un backup o una imagen que ya contiene los archivos de un paquete, pero la base de datos — restaurada desde otro punto en el tiempo — no sabe de él; `rpm -ivh --justdb` reconcilia ambos sin reescribir archivos que ya son correctos. También se usa al construir imágenes capa por capa. Es peligroso precisamente porque hace que la base de datos afirme algo que no verificó.

---

### Ejercicio 8

**A8.1** — La extracción **no**: (1) ejecuta los scriptlets `%pre`/`%post` — no hay creación de usuarios/grupos, ni `systemctl daemon-reload`, ni `ldconfig`, ni registro en alternatives; (2) registra nada en la base de datos RPM, así que los archivos quedan sin dueño, no verificables e invisibles a las actualizaciones; (3) aplica los contextos SELinux de archivo desde la política, ni las capabilities de archivo (`setcap`) declaradas en el header; (4) chequea dependencias ni firmas. Los scriptlets son el culpable habitual del "el servicio sigue sin arrancar" — la cuenta de servicio nunca se creó, el unit file nunca fue tomado por systemd, o la caché de bibliotecas compartidas nunca se refrescó.

**A8.2** — `cpio -i` compara su patrón contra los nombres de los miembros del archivo **exactamente como están almacenados**, y RPM los guarda de forma relativa con un prefijo `./`. `/etc/nginx/nginx.conf` nunca coincide con `./etc/nginx/nginx.conf`, así que cpio extrae cero miembros y reporta solo el conteo de bloques. La codificación relativa es deliberada: hace que la extracción aterrice bajo el directorio actual y hace imposible que un `cpio -i` descuidado sobrescriba `/etc` por accidente.

**A8.3** — Sí, `rpm2cpio` sigue funcionando. La descompresión ocurre dentro del propio `rpm2cpio`, que lee el header, descubre el tag `PAYLOADCOMPRESSOR` (`gzip`, `xz`, `zstd`, o `none`), y emite por stdout el archivo cpio descomprimido. Por lo tanto `cpio` nunca ve compresión en absoluto — recibe un stream cpio plano. El corolario es que un `rpm2cpio` de una release vieja de RPM no puede leer un payload comprimido con un algoritmo que desconoce; la solución es un paquete `rpm` más nuevo, no un `cpio` distinto.

**A8.4** — Opciones, aproximadamente por orden de preferencia: (1) `rpm2archive` si está disponible, o `bsdtar -xf pkg.rpm` — libarchive lee RPM de forma nativa, y `bsdtar` viene en `libarchive-tools` de Debian; (2) `7z x pkg.rpm` (p7zip entiende el contenedor RPM, y después el cpio interno); (3) `apt-get install rpm2cpio` — Debian empaqueta una implementación autónoma en Perl sin dependencia de la base de datos RPM; (4) manualmente, localizando el offset del payload después del lead+firma+header y canalizándolo por el descompresor correcto hacia `cpio -idmv`. `bsdtar` es la respuesta pragmática en un sistema de rescate.

**A8.5** — `rpm -Vf` reporta limpio solo porque dio la casualidad de que restauraste contenido idéntico con modo y propiedad coincidentes; no certifica que el *resto* del paquete sea coherente, y si el daño original tuvo una causa (una actualización parcial, una transacción fallida, un error de sistema de archivos) es probable que otros archivos del mismo paquete también estén afectados. `dnf reinstall coreutils` reextrae el payload completo, vuelve a ejecutar los scriptlets, reaplica los contextos SELinux y las capabilities de archivo, verifica las firmas al ingresar, y registra la operación en `dnf history` para que el cambio sea auditable. Un `install(1)` manual no hace nada de eso — y descarta silenciosamente las capabilities de archivo, lo que para binarios cercanos a setuid es una regresión real.

---

### Ejercicio 9

**A9.1** — Sí, sigue siendo correcta en el sentido de que la ruta existe y editarla edita la configuración efectiva — el symlink es un puente de compatibilidad deliberado para que la documentación, la memoria muscular y las recetas de gestión de configuración que apuntan a `/etc/yum.conf` sigan funcionando. Lo que **no** preserva es la compatibilidad de opciones: DNF ignora en silencio varias opciones de YUM 3, `alwaysprompt` y `group_package_types` entre ellas, y de forma más visible **`plugins=`, las opciones de la era `deltarpm` y `distroverpkg`** — DNF deriva `$releasever` del proveedor de `system-release` en vez de `distroverpkg`. Escribir una opción ignorada no produce ninguna advertencia, y esa es la trampa.

**A9.2** — `baseurl` y `mirrorlist`/`metalink` son mutuamente excluyentes por estrofa; cuando ambos están presentes DNF usa **`baseurl`** y desestima la lista de mirrors. Que se entregue `baseurl` comentado es deliberado: la lista de mirrors da selección geográfica de mirror, failover automático cuando uno está desactualizado o caído, y garantía de integridad vía `metalink` (que lleva el checksum esperado de `repomd.xml`). Un `baseurl` fijo es la elección correcta solo cuando corrés tu propio mirror o estás detrás de un proxy que debe ver un hostname estable.

**A9.3** — Con `skip_if_unavailable=True`, un repositorio que falla al refrescar se descarta de la transacción con una advertencia en vez de un error. Si el repositorio que falla es el de **updates/seguridad**, `dnf upgrade` reporta `Nothing to do` o aplica solo un subconjunto — y sale con `0`. La automatización lee éxito, el monitoreo lee "parcheado", y el host se queda en silencio sobre paquetes sin parchear hasta que alguien lea la línea de advertencia. Peor: si el repo que falló era el que proveía la versión *más nueva* de un paquete, el solver puede instalar una versión más vieja desde otro repo y considerar el sistema al día. Dejalo en `False` (el default de RHEL 9) y que las fallas sean ruidosas.

**A9.4** — Creá un archivo por host o por grupo de hosts vía gestión de configuración:
```bash
echo 'mirror.emea.example.net' > /etc/dnf/vars/sitemirror
```
Después entregá un único archivo `.repo`, idéntico en todos lados, que lo referencie:
```ini
baseurl=http://$sitemirror/rocky/$releasever/BaseOS/$basearch/os/
```
DNF sustituye cualquier `$nombre` desde un archivo llamado `nombre` en `/etc/dnf/vars/` (contenido = valor, primera línea, sin el salto de línea). Cambiar de región se vuelve una escritura de una línea, y los archivos `.repo` quedan uniformes y revisables.

**A9.5** — `priority=` **no** es respetado por DNF de fábrica; requiere el paquete `dnf-plugin-priorities` (`dnf-plugins-extras-priorities`, históricamente `yum-plugin-priorities`). Sin él, la línea se ignora en silencio — una sorpresa muy común en producción. La distinción: `priority` es un ordenamiento **estricto** — un paquete disponible en un repositorio de mayor prioridad (número más bajo) se usa aunque un repositorio de menor prioridad tenga una versión *más nueva*, y así es como evitás que un repo de terceros reemplace paquetes base. `cost` (por defecto 1000, respetado por DNF de fábrica) es un **desempate** usado solo cuando la misma versión de paquete existe en múltiples repositorios, expresando el costo relativo de descargarla; nunca anula la comparación de versiones. Si tu objetivo es "que Packman/EPEL nunca opaque a BaseOS", el mecanismo es `priority` más `excludepkgs`/`includepkgs`, no `cost`.

**A9.6** — `dnf clean all` **borra** la caché local — metadata y, según `keepcache`, los paquetes descargados — forzando una redescarga completa de la metadata de todos los repositorios en la próxima operación. `dnf --refresh <cmd>` solo marca la metadata existente como expirada para que se revalide, lo que para repositorios basados en `repomd.xml` significa una pequeña petición condicional que redescarga las bases de datos grandes primary/filelists **solo si cambió la revisión del repositorio**. En un enlace con consumo medido, `--refresh` es la opción segura; `clean all` en un cron es una factura de ancho de banda recurrente y solo pertenece a procedimientos de emergencia (break-glass).

---

### Ejercicio 10

**A10.1** — `dnf upgrade foo` lleva `foo` a la versión disponible más nueva y no hace nada si `foo` no está instalado. `dnf install foo` cuando `foo` ya está instalado se comporta como una actualización si existe una versión más nueva, y reporta `Package foo is already installed. Nothing to do.` en caso contrario — no baja de versión. `dnf distro-sync foo` sincroniza `foo` exactamente a la versión que los repositorios habilitados publican en este momento, lo que significa que **sí va a bajar de versión** si la versión instalada es más nueva que cualquier cosa disponible (el caso después de quitar un repo de terceros, o después de un `rpm -U` manual).

**A10.2** — `check-update` está diseñado como un *predicado* para scripts: salida `0` significa "nada que hacer", `100` significa "se requiere acción", `1` significa "no te lo puedo decir". Reservar `0` para el caso sin acción hace que `dnf check-update || run_patching` se lea con naturalidad, y permite que el monitoreo distinga "al día" de "repositorio roto" — cosa que un booleano no podría. Bajo `set -e`, el `100` termina el script justo en el momento en que hay actualizaciones, es decir, exactamente cuando querías que continuara. Protegelo explícitamente:
```bash
dnf check-update; rc=$?
case $rc in 0) ;; 100) do_upgrade ;; *) exit "$rc" ;; esac
```

**A10.3** — `--extras` significa "instalado, pero no provisto por ningún repositorio actualmente habilitado". Causas: (1) el repositorio que lo proveía fue deshabilitado o eliminado — común con repos de terceros tras una actualización de versión menor del SO; (2) el paquete fue actualizado más allá de lo que llevan los repos, o instalado desde un `.rpm` local que nunca estuvo en ningún repo; (3) la distribución retiró o renombró el paquete a lo largo de una actualización de versión mayor (restos). La preocupación de cadena de suministro es (2): un RPM instalado localmente desde una fuente no verificada aparece acá, y como ningún repositorio lo rastrea, nunca va a recibir una actualización de seguridad y ningún escáner de CVE basado en metadata de repositorio lo va a marcar. `dnf list --extras` es, por lo tanto, una auditoría barata y subutilizada.

**A10.4** — `best=True` le dice al solver: si la versión más nueva de un paquete solicitado no puede instalarse, **fallá y explicá**, en vez de instalar en silencio una más vieja. Caso concreto: ejecutás `dnf upgrade nginx`; nginx 1.22 requiere `openssl-libs >= 3.0.7`, pero `openssl-libs` está pineado por `versionlock` en 3.0.1. Con `best=True` la transacción aborta nombrando la dependencia irresoluble. Con `--nobest`, DNF instala nginx 1.20 en su lugar y sale con `0` — así que el operador cree que nginx se actualizó y que el CVE quedó corregido, cuando no fue así. `--nobest` cambia **veracidad por avance**; es la elección correcta solo cuando aceptás a sabiendas una actualización parcial y vas a verificar las versiones después.

**A10.5** — `/etc/httpd/conf/httpd.conf` pertenece al paquete `httpd`/`httpd-core` y está marcado como `%config(noreplace)`. Al borrar, RPM elimina los archivos de configuración que le pertenecen — preservando uno modificado como `httpd.conf.rpmsave`; fijate si está. `/etc/httpd/conf.d/myapp.conf` sobrevive porque **ningún paquete es su dueño**: lo creaste vos, así que queda por completo fuera del manifiesto de archivos de RPM y RPM nunca lo va a borrar. El directorio `/etc/httpd/conf.d` sí pertenece al paquete, pero RPM se niega a eliminar un directorio que todavía tiene contenido sin dueño adentro — que es exactamente la intención de diseño de los directorios drop-in.

**A10.6** — `rpm -i ./local.rpm` realiza un *chequeo* de dependencias y aborta si algo no está satisfecho; no va a descargar nada. `dnf install ./local.rpm` agrega el archivo local a la transacción como fuente de paquete y luego **resuelve sus dependencias contra los repositorios habilitados**, descargando lo que haga falta — el RPM local más una transacción completa y consistente. También registra la operación en `dnf history`, haciéndola reversible. La verificación de firma para ese archivo local está gobernada por **`localpkg_gpgcheck`** en `dnf.conf`, cuyo default es `False` — ponelo en `True`.

---

### Ejercicio 11

**A11.1** — `rpm -q --whatrequires foo` consulta solo la base de datos de lo **instalado**, y solo por dependencias expresadas como la cadena literal `foo`. `dnf repoquery --whatrequires foo` consulta la **metadata de repositorios**, así que ve paquetes que no están instalados, y — con `--alldeps` — resuelve a través de provides, encontrando paquetes que dependen de una capability que `foo` provee bajo otro nombre. Para "qué se rompería en este host", usá `dnf repoquery --installed --whatrequires --alldeps`. Para "qué se rompería en cualquier lugar de la distribución", sacá `--installed`.

**A11.2** — Sin resolver, `--requires` imprime la dependencia exactamente como la declara el paquete: una capability como `libapr-1.so.0()(64bit)` o `webserver`. `--resolve` mapea cada capability a un nombre concreto de paquete que actualmente la provee, en los repositorios habilitados, ahora mismo. La forma sin resolver es más precisa como afirmación sobre el paquete porque el mapeo no es una propiedad del paquete en absoluto — es una propiedad del conjunto de repositorios en un momento dado. Un repositorio distinto, una release distinta, o un proveedor alternativo compatible produce una resolución distinta mientras el paquete sigue igual. `--resolve` responde "qué se va a instalar"; `--requires` responde "qué necesita esto".

**A11.3** — Dos versiones de `kernel-devel` es normal y esperable: `kernel-devel` está en `installonlypkgs`, se mantiene en paralelo para que los módulos DKMS puedan compilarse contra cada kernel instalado. Dos versiones de `glibc` es un **sistema roto**: `glibc` no es de solo instalación, así que ambas versiones son dueñas de las mismas rutas de archivos, lo que significa que una transacción interrumpida, un `rpm -i` donde se quiso `-U`, o una instalación con `--force` dejó la base de datos con entradas duplicadas y el sistema de archivos con los archivos que se escribieron últimos. Diagnosticá con `dnf repoquery --duplicates` / `package-cleanup --dupes`, y reparalo con `dnf remove <NEVRA-más-vieja>` — nombrando el NEVRA completo, no el nombre pelado — o `dnf distro-sync`. Nunca lo resuelvas con `rpm -e --nodeps`.

**A11.4** —
```bash
dnf repoquery --installed --qf '%{name}-%{evr}.%{arch} %{sourcerpm}\n' \
  | grep 'nginx-1.20.1-14.el9_2.1.src.rpm'
```
Esto mapea el SRPM nombrado en el aviso a los subpaquetes binarios que efectivamente están instalados acá — que es la pregunta que importa, ya que un SRPM comúnmente produce una docena de paquetes binarios y puede que tengas solo dos de ellos. `dnf updateinfo list --cve CVE-XXXX-YYYY` es el comando complementario cuando el repositorio publica metadata de erratas.

---

### Ejercicio 12

**A12.1** — En la transacción 12: `undo 8` invierte **solo** la transacción 8 (instala lo que 8 eliminó, elimina lo que 8 instaló, baja de versión lo que 8 actualizó), dejando 9–12 en su lugar — lo que puede fallar si una transacción posterior depende del resultado de 8. `rollback 8` revierte **todo lo posterior a 8**, es decir las transacciones 9 a 12, devolviendo el conjunto de paquetes a su estado al final de la transacción 8. `redo 8` vuelve a aplicar las operaciones de la transacción 8 como una nueva transacción 13.

**A12.2** — No restaura: (1) el **contenido de los archivos de configuración** — archivos `%config(noreplace)` editados después, ni ninguna reconciliación de `.rpmnew`/`.rpmsave` que hayas hecho; (2) **datos y estado** fuera del manifiesto del paquete — esquemas de base de datos migrados por un scriptlet `%post`, archivos creados en tiempo de ejecución, estado de rotación de logs, certificados generados; (3) **estado del servicio y del sistema** — una unit que se habilitó o enmascaró, un booleano de SELinux fijado, una regla de firewall abierta, un módulo de kernel ahora cargado. Es engañoso llamarlo "rollback" porque revierte *solo el conjunto de paquetes*, tratando la transacción como reversible cuando sus efectos colaterales en general no lo son. Una aplicación bajada de versión que ya migró su base de datos hacia adelante es un ejemplo común y doloroso.

**A12.3** — Son checksums sobre el contenido de la base de datos RPM al inicio y al final de la transacción, almacenados para que DNF pueda detectar cambios hechos **fuera** de su conocimiento. Si el `Begin rpmdb` de la transacción N+1 no coincide con el `End rpmdb` de la transacción N, algo modificó el conjunto de paquetes sin pasar por DNF — un `rpm -i`/`rpm -e` directo, una herramienta de gestión de configuración manejando `rpm` directamente, una capa de imagen de contenedor, o un backup restaurado. DNF lo marca y eso degrada la confiabilidad de `undo`/`rollback`, porque la operación inversa registrada puede ya no aplicarse al estado actual.

**A12.4** — Dos formas: (1) apuntar DNF a un archivo histórico de los paquetes viejos — habilitar un repositorio de bóveda/archivo (`dnf --releasever=9.2 --enablerepo=...`, o un mirror de vault como un repo interno de snapshots) para que los NEVRA viejos vuelvan a resolver; (2) obtener los RPM directamente (desde `/var/cache/dnf` en un host par, un almacén interno de artefactos, o un mirror de vault) e instalarlos explícitamente con `dnf downgrade ./old-*.rpm`. La configuración de `dnf.conf` que lo habría prevenido es **`keepcache=1`**, que retiene los RPM descargados bajo `/var/cache/dnf` después de una transacción exitosa, así las versiones previas siguen en disco. La respuesta de producción más robusta es un **mirror interno con snapshots**, para que "la versión que corríamos el martes pasado" sea siempre resoluble.

---

### Ejercicio 13

**A13.1** — Las definiciones de grupos viven en la metadata del repositorio — el `comps.xml` (entrada `group_gz`/`comps` en `repomd.xml`), cacheado bajo `/var/cache/dnf/<repo>-<hash>/repodata/`; DNF además registra qué grupos instalaste en su propio persistor de grupos (`/var/lib/dnf/groups.json` en DNF 4). Prueba de que no están en la base de datos RPM: `rpm -q "Development Tools"` reporta `package Development Tools is not installed`, y `rpm -qa | grep -i development.tools` no devuelve nada — RPM no tiene noción de grupos más allá del tag vestigial `%{GROUP}`, que es una categoría de texto libre, no un bundle. Cuando el repositorio que lo define se deshabilita, `dnf group list` deja de mostrar el grupo y `dnf group remove` ya no puede determinar su membresía; los paquetes individuales quedan instalados y se vuelven paquetes ordinarios.

**A13.2** — `dnf module reset nodejs` limpia por completo el estado de stream habilitado, devolviendo el módulo a "sin stream seleccionado" — no elimina paquetes. `dnf module disable nodejs` marca el módulo como deshabilitado, ocultando del solver los paquetes de **todos** sus streams. `reset` es el precursor correcto para cambiar de stream (`reset` → `enable nodejs:20` → `distro-sync` o `install`). Usar `disable` en su lugar provoca una falla de resolución porque los paquetes `nodejs` actualmente instalados vienen del módulo que acabás de ocultar: el solver ve paquetes instalados provistos por ningún stream de módulo disponible, y cualquier transacción posterior que los toque no tiene resolución válida.

**A13.3** — Ordenados por alcance y persistencia:
1. **`exclude=` en `/etc/dnf/dnf.conf`** — el más amplio y persistente: aplica a todos los repositorios, todos los comandos, todos los usuarios, hasta que se edite. Bloquea también los parches de seguridad.
2. **`versionlock`** — persistente (guardado en `/etc/dnf/plugins/versionlock.list`), acotado al paquete, y fija un EVR específico. También bloquea los parches de seguridad para ese paquete, pero es explícito, listable (`dnf versionlock list`) y auditable — por eso es la herramienta adecuada cuando un pin es genuinamente necesario.
3. **`--exclude=` en la línea de comandos** — el más acotado y no persistente: solo esta invocación.

Ninguno de los tres deja pasar automáticamente un parche de seguridad — ese es el punto de un pin. Lo más cercano es `exclude=` con `--disableexcludes=all` en la corrida de parcheo, o acotar el versionlock a un prefijo de versión (`dnf versionlock add 'nginx-1.20.*'`) para que las reconstrucciones de seguridad Z-stream dentro de esa rama sigan permitidas. Esa última forma es la que conviene usar.

**A13.4** — El solver reporta una dependencia irresoluble nombrando ambos lados — típicamente `Problem: package X requires nginx >= 1.22, but none of the providers can be installed` seguido de `package nginx-1.22 is filtered out by exclude filtering` o `... is excluded by versionlock`. La resolución menos dañina, en orden: (1) determinar si el pin sigue justificado — los pins sobreviven a sus razones más a menudo de lo que uno cree; si no, `dnf versionlock delete nginx` y actualizá normalmente. (2) Si el pin debe quedarse, acotá la transacción: `dnf upgrade --exclude=<el paquete dependiente>` para que el resto del sistema se parchee, y llevá registro del paquete excluido como riesgo aceptado. (3) Solo como último recurso `--nobest`, y después verificá exactamente qué versiones quedaron. Nunca `--allowerasing` acá: va a eliminar alegremente el paquete dependiente para satisfacer la resolución.

---

### Ejercicio 14

**A14.1** —

| DNF | zypper |
|---|---|
| `dnf provides <path>` | `zypper what-provides <path>` (`zypper wp`) |
| `dnf repolist` | `zypper repos` (`zypper lr`) |
| `dnf list --installed` | `zypper search --installed-only` (`zypper se -i`), o `zypper packages -i` |
| `dnf config-manager --set-disabled <repo>` | `zypper modifyrepo -d <alias>` (`zypper mr -d`) |
| `dnf autoremove` | `zypper remove --clean-deps <pkg>` (en el momento de la eliminación); `zypper packages --unneeded` para listar huérfanos |

**A14.2** — `zypper up` actualiza los paquetes instalados a versiones más nuevas **dentro del mismo vendor y arquitectura**, y no va a eliminar paquetes ni cambiar de vendor para completar la resolución; es la operación conservadora de "parcheá lo que tengo". `zypper dup` realiza una actualización de distribución completa: sincroniza el conjunto instalado con lo que publican los repositorios habilitados, **permite cambios de vendor, bajadas de versión y eliminaciones de paquetes**, y es el mecanismo detrás del modelo rolling de openSUSE Tumbleweed y de las actualizaciones de versión de Leap. Después de agregar Packman — cuyo propósito entero es *reemplazar* los paquetes multimedia de openSUSE por otros compilados de forma distinta — necesitás `zypper dup --from packman` (o `--allow-vendor-change`) precisamente porque hace falta un cambio de vendor. `zypper up` está mal ahí: rechaza el cambio de vendor y te deja en silencio con los paquetes originales, que es el clásico reporte de "agregué Packman y no pasó nada".

**A14.3** — **Gana el número más bajo** en zypper: `priority=90` le gana a `priority=99` (el valor por defecto). La escala va de 1 (la más alta) a 200 (la más baja). Esta es la convención opuesta a la intuición de mucha gente y — de forma crítica — el plugin `priority` de DNF usa la *misma* convención de menor-es-mayor (por defecto 99), así que la trampa no es la dirección sino suponer que las prioridades funcionan siquiera: zypper respeta `priority` de forma **nativa**, mientras que DNF necesita `dnf-plugin-priorities` instalado o la configuración se ignora en silencio. Una configuración copiada conceptualmente de zypper a DNF va a parecer funcionar y no va a hacerlo.

**A14.4** — Durante la actualización, RPM reemplazó los archivos de bibliotecas compartidas en el disco. En Linux, desenlazar un archivo que un proceso mantiene abierto no lo libera: el inodo viejo persiste, y `httpd` sigue ejecutando el código **viejo, sin parchear** desde el inodo borrado mientras `/proc/<pid>/maps` muestra entradas marcadas `(deleted)`. Eso es lo que detecta `zypper ps`. Un reinicio es obligatorio, no cosmético, por dos razones: la vulnerabilidad que la actualización corrigió sigue viva en el proceso en ejecución, y el espacio en disco del inodo viejo no se recupera hasta que se cierre la última referencia. Del lado de DNF, el equivalente es `dnf needs-restarting` (`-r` para "¿necesita reiniciarse todo el sistema?").

**A14.5** — El código de salida 103 significa que zypper (o su stack libzypp) fue actualizado él mismo como parte de la transacción, así que el proceso en ejecución quedó obsoleto y la transacción está **incompleta**. Un script desatendido debe **volver a invocar zypper** para terminar el trabajo pendiente — típicamente en bucle: ejecutar el comando de parcheo, y si sale con 103, ejecutarlo de nuevo (con un límite de reintentos) hasta que devuelva 0, 100 o 102. Tratar el 103 como éxito deja parches sin aplicar; tratarlo como falla dura aborta una corrida que en realidad estaba avanzando. Manejá el 102 por separado programando un reinicio.

---

### Ejercicio 15

**A15.1** — `rpm --rebuilddb` lee los headers de paquete existentes de la base de datos y escribe un conjunto fresco de estructuras de **índice** alrededor de ellos — con el backend BDB, las tablas secundarias `Name`, `Basenames`, `Providename`, `Requirename`, `Dirnames` y relacionadas; con sqlite, reescribe y reindexa el archivo de base de datos. Repara corrupción de índices, locks obsoletos y daño del entorno BDB. No puede recuperar **datos de header** que ya no están: si `Packages` (BDB) o `rpmdb.sqlite` (sqlite) fue destruido, no queda nada que indexar — los headers *son* el almacén primario — y `--rebuilddb` produce una base de datos válida y vacía. Por eso es un no-op en el caso verdaderamente destruido, y por eso las vías reales de recuperación son un backup a nivel de sistema de archivos de `/var/lib/rpm`, un snapshot, o la reconstrucción a partir de `/var/lib/dnf/history.sqlite` más una reinstalación masiva.

**A15.2** — DNF corre un **chequeo de transacción** completo (la fase de transaction-check de `rpm`, `rpmtsCheck`, más la propia resolución de libsolv) antes de comprometer. Dos guardas lo habrían detenido: el chequeo de dependencias (que `--nodeps` esquivó) y el **chequeo de conflictos de archivos** durante la etapa de preparación de `rpmtsRun`, que detecta que dos paquetes instalados reclaman la misma ruta con contenido distinto y aborta con `file ... from install of X conflicts with file from package Y` (eso es `--replacefiles`, implicado por `--force`, siendo esquivado). DNF no expone ningún equivalente de `--force`; lo más cercano, `--allowerasing`, resuelve conflictos *eliminando* un paquete, nunca sobrescribiendo los archivos de otro. El estado que creaste es inalcanzable desde DNF por diseño.

**A15.3** — `rpm -qf /etc/nginx` reporta `file /etc/nginx is not owned by any package` — los archivos siguen en el disco pero la entrada de base de datos que los reclamaba ya no está, así que quedaron huérfanos: invisibles para `rpm -V`, no eliminados por ningún borrado futuro, y un conflicto de archivos garantizado la próxima vez que algo intente instalar un paquete dueño de esas rutas. El camino más limpio de vuelta: `dnf install nginx-filesystem` ahora va a fallar o entrar en conflicto con los archivos existentes, así que o bien (a) hacé `rpm -ivh --justdb --replacepkgs` del mismo NEVRA para restaurar la entrada de base de datos, y después `dnf reinstall nginx-filesystem` para volver a colocar los archivos como corresponde; o (b) eliminá a mano las rutas huérfanas — después de confirmar con `rpm -qlp` exactamente cuáles son y que nada más las reclama — y después `dnf install nginx-filesystem` normalmente. La opción (a) es preferible porque nunca borra nada.

**A15.4** — `dnf remove kernel` coincide con **todos los kernels instalados**, incluido el que está corriendo, y DNF los va a eliminar todos — dejando un sistema sin kernel booteable que muere en el próximo reinicio (y que pierde inmediatamente `/lib/modules/<en-ejecución>`, así que no se pueden cargar más módulos). `--oldinstallonly` selecciona solo los paquetes de solo instalación que exceden `installonly_limit`, **excluyendo explícitamente el kernel en ejecución y el más nuevo**, y por eso es seguro. A nivel del gestor de arranque, los scriptlets `%posttrans` de `dnf` regeneran la configuración de GRUB y las entradas BLS bajo `/boot/loader/entries/`, así que eliminar un kernel viejo también elimina su entrada de arranque — es decir que la protección vale tanto como la lógica de exclusión. Por las dudas, doble control: `dnf remove --oldinstallonly --setopt=installonly_limit=2 kernel` y verificá con `rpm -q kernel` y `uname -r` antes de reiniciar.

**A15.5** — Recuperación usando solo `rpm`, `rpm2cpio` y un mirror:
1. Identificá los paquetes dañados: `rpm -Va python3-dnf python3-libdnf python3-hawkey libdnf` y `rpm -q --qf '%{NEVRA}\n' dnf python3-dnf libdnf librepo libsolv rpm-libs`.
2. Traé los RPM correctos directamente de un mirror con `curl -O` (la ruta del mirror es visible en la salida de `dnf repoinfo` capturada antes, o reconstruila desde la línea `baseurl` del archivo `.repo`). Si `curl` también está roto, `rpm -qip <URL>` demuestra que el cliente HTTP propio de RPM funciona y podés manejar la descarga de otra manera.
3. Verificá antes de confiar: `rpm -Kv *.rpm` — esto todavía funciona, ya que `rpmkeys` no depende de DNF.
4. Reinstalá con RPM en **una sola transacción**: `rpm -Uvh --replacepkgs libsolv-*.rpm librepo-*.rpm libdnf-*.rpm python3-*.rpm dnf-*.rpm dnf-data-*.rpm`. Nombrarlos juntos permite que el chequeo de dependencias de RPM resuelva el conjunto internamente.
5. Si `rpm` mismo está deteriorado (un `rpm-libs` roto), usá `rpm2cpio | cpio -idmv` hacia un directorio de trabajo y copiá los `.so` necesarios en su lugar *lo justo* para que `rpm` arranque, y después rehacé inmediatamente el paso 4 como corresponde, para que la base de datos y los scriptlets queden correctos.
6. Confirmá: `dnf --version`, después `dnf check` y `rpm -Va --nomtime` sobre los paquetes afectados.

El principio de ordenamiento a lo largo de todo esto: usá la extracción solo para devolverle la vida a la herramienta, nunca como estado final.

</details>