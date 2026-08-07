# LPI BSD Specialist (702-100) — Tema 711.1: Instalación del sistema operativo BSD

## Documentación oficial de referencia
* **LPI BSD Specialist Overview**: [https://www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)
* **FreeBSD Handbook - Installing FreeBSD**: [https://docs.freebsd.org/en/books/handbook/bsdinstall/](https://docs.freebsd.org/en/books/handbook/bsdinstall/)
* **FreeBSD Manual - bsdinstall(8)**: [https://man.freebsd.org/cgi/man.cgi?query=bsdinstall](https://man.freebsd.org/cgi/man.cgi?query=bsdinstall)
* **FreeBSD Manual - freebsd-update(8)**: [https://man.freebsd.org/cgi/man.cgi?query=freebsd-update](https://man.freebsd.org/cgi/man.cgi?query=freebsd-update)
* **OpenBSD FAQ - Installation Guide**: [https://www.openbsd.org/faq/faq4.html](https://www.openbsd.org/faq/faq4.html)
* **OpenBSD Manual - autoinstall(8)**: [https://man.openbsd.org/autoinstall.8](https://man.openbsd.org/autoinstall.8)
* **OpenBSD Manual - sysupgrade(8)**: [https://man.openbsd.org/sysupgrade.8](https://man.openbsd.org/sysupgrade.8)
* **NetBSD Guide - Installing NetBSD**: [https://www.netbsd.org/docs/guide/en/chap-install.html](https://www.netbsd.org/docs/guide/en/chap-install.html)
* **NetBSD Manual - sysinst(8)**: [https://man.netbsd.org/sysinst.8](https://man.netbsd.org/sysinst.8)

---

## Ejercicio 1: Arquitectura de instalación automatizada y mecánica de particionamiento de disco en FreeBSD

### Escenario y contexto técnico
En entornos de producción empresariales, la navegación manual del instalador mediante diálogos ncurses no escala. Los Administradores de Sistemas y los Ingenieros de Confiabilidad del Sitio (Site Reliability Engineers / SREs) automatizan los despliegues de FreeBSD utilizando `bsdinstall` con archivos de configuración mediante scripts pasados a través de PXE o medios locales. Comprender cómo `bsdinstall` particiona los discos utilizando `gpart` y configura pools de almacenamiento ZFS de forma no interactiva es crucial para la automatización de la infraestructura.

---

### Ejecución guiada paso a paso

#### Paso 1.1: Inspeccionar la identificación del sistema y las topologías de disco existentes
Antes de activar un script de instalación automatizada, inspeccione la arquitectura del kernel del sistema, las propiedades de hardware y el esquema de almacenamiento existente utilizando herramientas de reporte del sistema.

Ejecute los siguientes comandos en la shell:

```bash
uname -a
sysctl hw.model hw.ncpu hw.physmem
gpart show
```

**Salida esperada:**
```text
FreeBSD bsd-node-01.internal.net 14.0-RELEASE FreeBSD 14.0-RELEASE p5 releng/14.0-n265808-f7db8178822 GENERIC amd64
hw.model: AMD EPYC 7763 64-Core Processor
hw.ncpu: 4
hw.physmem: 8589934592
=>       40  104857520  ada0  GPT  (50G)
         40       1024     1  freebsd-boot  (512K)
       1064        984        - free -  (492K)
       2048    4194304     2  freebsd-swap  (2.0G)
    4196352  100661208     3  freebsd-zfs  (48G)
```

#### Paso 1.2: Construir un script de configuración automatizado para `bsdinstall`
Cree un script de instalación no interactivo `/tmp/bsdinstall-script` que configure los parámetros de red, cuentas de usuario, hostname de destino, esquema ZFS y conjuntos de distribución binaria (Distribution Sets).

Ejecute el siguiente comando de shell para escribir el manifiesto de instalación:

```bash
cat << 'EOF' > /tmp/bsdinstall-script
#!/bin/sh

# Environment variables governing bsdinstall behavior
export HISTSIZE=1000
export PATH=/sbin:/bin:/usr/sbin:/usr/bin

# Set installation target parameters
HOSTNAME="freebsd-prod-01.infra.local"
KEYMAP="us.iso.acc.kbd"
DISTRIBUTIONS="base.txz kernel.txz src.txz"

# Automated ZFS disk layout configuration (Mirror setup on ada0 and ada1)
export ZFSBOOT_VDEV_TYPE="mirror"
export ZFSBOOT_DISKS="ada0 ada1"
export ZFSBOOT_CONFIRM_ZPOOL="YES"
export ZFSBOOT_POOL_NAME="zroot"
export ZFSBOOT_SWAP_SIZE="4g"
export ZFSBOOT_SWAP_ENCRYPTION="YES"

# Execute ZFS partitioning subsystem non-interactively
bsdinstall zfsboot

# Configure post-installation OS parameters inside target chroot
bsdinstall config

# Apply post-install customizations to target system
cat << 'CHROOT_EOF' >> /mnt/etc/rc.conf
hostname="freebsd-prod-01.infra.local"
ifconfig_vtnet0="DHCP"
sshd_enable="YES"
ntpdate_enable="YES"
zfs_enable="YES"
CHROOT_EOF

cat << 'CHROOT_EOF' >> /mnt/etc/sysctl.conf
security.bsd.see_other_uids=0
security.bsd.see_other_gids=0
CHROOT_EOF

echo "Installation complete."
EOF
chmod +x /tmp/bsdinstall-script
```

#### Paso 1.3: Validar la sintaxis del script y simular la ejecución automatizada de bsdinstall
Valide la estructura del script y ejecute `bsdinstall` en modo de script contra un directorio raíz de destino.

Ejecute:

```bash
bsdinstall script /tmp/bsdinstall-script
```

**Salida esperada:**
```text
----------------------------------------------------------------------
bsdinstall: Running script /tmp/bsdinstall-script
Formatting ZFS pool 'zroot' on mirrors: ada0 ada1...
Creating ZFS datasets (zroot/ROOT/default, zroot/tmp, zroot/usr/home)...
Extracting base.txz...
Extracting kernel.txz...
Extracting src.txz...
Writing /etc/rc.conf to target environment...
Installation complete.
----------------------------------------------------------------------
```

#### Paso 1.4: Verificar la identidad del sistema y los metadatos de compilación posteriores a la instalación
Verifique la versión de release del kernel, la arquitectura del sistema, las fechas de compilación y los parámetros de ajuste (tuning) del sistema.

Ejecute:

```bash
uname -s -r -m -i -p -v
```

**Salida esperada:**
```text
FreeBSD 14.0-RELEASE amd64 GENERIC amd64 FreeBSD 14.0-RELEASE p5 releng/14.0-n265808-f7db8178822 GENERIC
```

---

### Preguntas de verificación — Ejercicio 1

#### Pregunta 1.1
¿Cuál es la diferencia mecánica precisa entre `uname -m` y `uname -p` en sistemas FreeBSD que se ejecutan en hardware x86 de 64 bits moderno?

#### Pregunta 1.2
Al invocar `bsdinstall script <script-path>`, ¿qué variable de entorno o directiva de configuración determina qué tarballs de distribución (como `base.txz`, `kernel.txz` o `ports.txz`) se obtienen y extraen en la raíz de la partición de destino?

#### Pregunta 1.3
¿Por qué un SRE empresarial prefiere crear una partición de swap dedicada (`ZFSBOOT_SWAP_SIZE="4g"`) formateada fuera de los datasets del pool ZFS, y qué riesgo está asociado con colocar un archivo de swap directamente en un pool del sistema de archivos ZFS durante situaciones de alta presión de memoria?

---

## Ejercicio 2: Live Patching y actualizaciones in-situ de versiones Major Release en FreeBSD (`freebsd-update`)

### Escenario y contexto técnico
Mantener el tiempo de actividad en producción requiere que los SRE apliquen parches de seguridad binarios y realicen actualizaciones de versiones major del sistema operativo en los hosts de FreeBSD sin reconstruir desde el código fuente. `freebsd-update` maneja las actualizaciones de distribución binaria, rastreando el estado del kernel, las fusiones de configuración en `/etc` y la sincronización de librerías del userland.

---

### Ejecución guiada paso a paso

#### Paso 2.1: Auditar la configuración de actualización del sistema y comprobar el estado de la versión actual
Inspeccione `/etc/freebsd-update.conf` para entender qué componentes (Kernel, Userland, Librerías) están incluidos en las comprobaciones de actualización.

Ejecute los siguientes comandos en la shell:

```bash
freebsd-update updatesready
uname -K -U
cat /etc/freebsd-update.conf | grep -E "^(Components|IgnorePaths|StrictComponents)"
```

**Salida esperada:**
```text
1400097 1400097
Components src world kernel
IgnorePaths
StrictComponents false
```

> [!NOTE]
> `uname -K` muestra la revisión del sistema operativo del kernel FreeBSD en ejecución, mientras que `uname -U` muestra la versión binaria del userland. Cuando los parches de seguridad se aplican únicamente al userland, `uname -U` se incrementa (por ejemplo, `1400097`), proporcionando una separación diagnóstica precisa entre los estados de compilación del kernel y del userland.

#### Paso 2.2: Realizar la obtención e instalación no interactiva de parches de seguridad
Obtenga conjuntos de parches binarios firmados desde los mirrors de distribución oficiales de FreeBSD y aplíquelos al kernel en vivo y al userland.

Ejecute:

```bash
freebsd-update fetch
freebsd-update install
```

**Salida esperada:**
```text
src component not installed, skipped
Looking up update.FreeBSD.org mirrors... 3 mirrors found.
Fetching public key from update1.freebsd.org... done.
Fetching metadata signature for 14.0-RELEASE from update1.freebsd.org... done.
Fetching metadata index... done.
Inspecting system... done.
Preparing to download files... done.

The following files will be updated as part of updating to 14.0-RELEASE-p6:
/boot/kernel/kernel
/usr/sbin/sshd
/lib/libc.so.7

Downloading files... done.
Installing updates... done.
```

#### Paso 2.3: Ejecutar una actualización de versión major release a FreeBSD 14.1-RELEASE
Realice una actualización de versión major release de FreeBSD utilizando `freebsd-update upgrade`.

Ejecute:

```bash
freebsd-update -r 14.1-RELEASE upgrade
```

**Salida esperada:**
```text
Looking up update.FreeBSD.org mirrors... 3 mirrors found.
Fetching metadata signature for 14.1-RELEASE from update1.freebsd.org... done.
Fetching metadata index... done.
Inspecting system... done.

The following components will be updated as part of updating to 14.1-RELEASE:
world kernel src

Does this look reasonable (y/n)? y

Fetching 12402 files... done.
Attempting to automatically merge changes in files from /etc... done.
File merge status:
  /etc/master.passwd: merged automatically
  /etc/group: merged automatically
  /etc/ssh/sshd_config: conflict detected, opening editor...

To install the downloaded updates, run "/usr/sbin/freebsd-update install".
```

#### Paso 2.4: Ejecutar la secuencia de instalación binaria multietapa
Aplicar actualizaciones major con `freebsd-update` requiere una secuencia obligatoria de 3 pasos intercalados con reinicios del sistema para mantener la compatibilidad ABI entre el kernel y las librerías del userland.

Ejecute la Etapa 1 (Instalación del kernel):

```bash
freebsd-update install
```

**Salida esperada:**
```text
Installing updates...
Kernel updates installed successfully.
Please reboot the system and run '/usr/sbin/freebsd-update install' again to install userland components.
```

Ejecute la Etapa 2 (Instalación de userland posterior al reinicio):

```bash
# Executed after rebooting into the new kernel:
freebsd-update install
```

**Salida esperada:**
```text
Installing userland updates...
Removing old shared libraries...
Complete. Re-run pkg-static upgrade to update installed packages.
```

---

### Preguntas de verificación — Ejercicio 2

#### Pregunta 2.1
¿Por qué `freebsd-update install` requiere ejecutarse **dos veces** (separadas por un reinicio del sistema) al realizar una actualización de versión major desde `14.0-RELEASE` a `14.1-RELEASE`?

#### Pregunta 2.2
Si un administrador modifica `/etc/ntp.conf` localmente y se proporciona una versión actualizada de `/etc/ntp.conf` en la nueva release de FreeBSD, ¿cómo maneja `freebsd-update` la fusión y qué sucede si se produce un conflicto de fusión de tres vías (three-way merge conflict)?

#### Pregunta 2.3
¿Qué comando puede ejecutar un SRE para revertir (rollback) inmediatamente un paso de `freebsd-update install` si un kernel recién instalado no logra arrancar correctamente?

---

## Ejercicio 3: Mecánica de instalación automatizada en OpenBSD (`bsd.rd` y `autoinstall`)

### Escenario y contexto técnico
Las instalaciones de OpenBSD aprovechan un kernel instalador monolítico en disco RAM llamado `bsd.rd` (RAM Disk kernel). Para el aprovisionamiento bare-metal desatendido (zero-touch), OpenBSD proporciona la infraestructura del daemon `autoinstall(8)`. Cuando `bsd.rd` arranca, consulta a DHCP por la opción 114 (URL) u busca obtener un archivo de respuestas llamado `install.conf` vía HTTP/TFTP basándose en la dirección IP o MAC del sistema.

---

### Ejecución guiada paso a paso

#### Paso 3.1: Inspeccionar el entorno ramdisk `bsd.rd` de OpenBSD
Arranque un nodo de OpenBSD en `bsd.rd` o inspeccione directamente el archivo ramdisk del instalador del sistema en vivo.

Ejecute los siguientes comandos en la shell:

```bash
ls -lh /bsd.rd
uname -a
sysctl kern.version
```

**Salida esperada:**
```text
-rwxr-xr-x  1 root  wheel   11.4M Aug  1 12:00 /bsd.rd
OpenBSD openbsd-node-01.infra.net 7.5 GENERIC.MP#82 amd64
kern.version=OpenBSD 7.5 (GENERIC.MP) #82: Thu Mar 21 10:14:22 MDT 2024
    deraadt@amd64.openbsd.org:/usr/src/sys/arch/amd64/compile/GENERIC.MP
```

#### Paso 3.2: Construir un manifiesto de instalación automatizada `install.conf` para OpenBSD
Cree un archivo de respuestas `install.conf` sintácticamente válido para automatizar una instalación de OpenBSD de forma no interactiva a través de HTTP.

Ejecute:

```bash
cat << 'EOF' > /var/www/htdocs/install.conf
System hostname = openbsd-node-02
Password for root = $6$sOmESaLt$v.8Jp7dM1aW7oK... (or plain text secret)
Change the default console font = no
Setup a user = SREAdmin
Full name for user SREAdmin = Lead SRE
Password for user SREAdmin = SecretSREPass123!
Public ssh key for user SREAdmin = ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... sre@infra
Which speed should com0 use = 115200
Setup network interface = vio0
IPv4 address for vio0 = dhcp
IPv6 address for vio0 = none
Which device is the root disk = sd0
URL to receive file = http://cdn.openbsd.org/pub/OpenBSD/7.5/amd64/
Set name(s) = +* -game* -x*
Location of sets = HTTP
HTTP proxy = none
Use autoinstall response file = yes
EOF
```

#### Paso 3.3: Configurar las opciones del servidor DHCP para transmitir la carga útil de autoinstall de OpenBSD
Para indicar al entorno de arranque `bsd.rd` de OpenBSD que ejecute una instalación automatizada, configure el servidor DHCP de OpenBSD (`/etc/dhcpd.conf`) para servir la URL HTTP de `install.conf`.

Ejecute:

```bash
cat << 'EOF' >> /etc/dhcpd.conf
subnet 192.168.1.0 netmask 255.255.255.0 {
    option routers 192.168.1.1;
    option domain-name-servers 192.168.1.1;
    range 192.168.1.100 192.168.1.200;

    host openbsd-target {
        hardware ethernet 52:54:00:ab:cd:ef;
        fixed-address 192.168.1.150;
        filename "pxeboot";
        option vendor-encapsulated-options "http://192.168.1.10/install.conf";
    }
}
EOF
```

#### Paso 3.4: Verificar el estado de instalación del sistema mediante firmas criptográficas signify
Durante las instalaciones automatizadas de OpenBSD, la integridad de los archivos y la autenticidad de los conjuntos de distribución se verifican strictly utilizando `signify(1)`. Inspeccione la clave pública asociada con la release de instalación.

Ejecute:

```bash
ls -l /etc/signify/openbsd-*-base.pub
signify -V -p /etc/signify/openbsd-75-base.pub -e -m /etc/motd
```

**Salida esperada:**
```text
-rw-r--r--  1 root  wheel  101 Mar 21  2024 /etc/signify/openbsd-75-base.pub
Signature Verified
```

---

### Preguntas de verificación — Ejercicio 3

#### Pregunta 3.1
En la arquitectura autoinstall de OpenBSD, ¿qué es `bsd.rd`, dónde reside en memoria durante la ejecución de la instalación y cómo difiere mecánicamente del kernel de producción `/bsd`?

#### Pregunta 3.2
Si una máquina OpenBSD arranca `bsd.rd` con `autoinstall` habilitado, ¿qué secuencia de URLs/nombres de archivo intentará obtener el sistema desde el servidor HTTP si no se especifica la opción DHCP 114?

#### Pregunta 3.3
¿Qué sintaxis se utiliza en `install.conf` para incluir explícitamente todos los conjuntos de instalación base estándar omitiendo los juegos (`game75.tgz`) y los paquetes gráficos de X11 (`xbase75.tgz`, `xfont75.tgz`, etc.)?

---

## Ejercicio 4: Actualizaciones in-situ no interactivas en OpenBSD a través de `sysupgrade`

### Escenario y contexto técnico
Antes de OpenBSD 6.6, actualizar OpenBSD requería arrancar manualmente en `bsd.rd`, seleccionar `(U)pgrade` y avanzar a través de las opciones de confirmación. Las operaciones modernas de SRE se basan en `sysupgrade(8)`, una utilidad que automatiza la obtención de binarios de release, la verificación de firmas `signify`, la preparación de `bsd.rd` como `/bsd.upgrade` y el inicio de un reinicio de actualización desatendido del sistema.

---

### Ejecución guiada paso a paso

#### Paso 4.1: Auditar la versión actual del sistema y el estado de los parches
Compruebe la versión de release y los detalles de arquitectura de OpenBSD en ejecución antes de ejecutar `sysupgrade`.

Ejecute:

```bash
uname -a
sysctl syspatch
```

**Salida esperada:**
```text
OpenBSD openbsd-prod-01.infra.net 7.4 GENERIC.MP#0 amd64
010_syspatch 011_ports 012_kernel
```

#### Paso 4.2: Ejecutar `sysupgrade` desatendido para obtener los conjuntos de actualización y preparar el kernel de actualización
Ejecute `sysupgrade` para obtener los binarios de actualización de OpenBSD 7.5 de forma no interactiva.

Ejecute:

```bash
sysupgrade -n
```

**Salida esperada:**
```text
Fetching release candidate binaries from https://cdn.openbsd.org/pub/OpenBSD/7.5/amd64/
Verifying SHA256.sig with /etc/signify/openbsd-75-base.pub... Signature Verified!
Downloading bsd... 100%
Downloading bsd.rd... 100%
Downloading base75.tgz... 100%
Downloading comp75.tgz... 100%
Downloading man75.tgz... 100%
Extracting bsd.rd to /bsd.upgrade... done.
System staged for upgrade on reboot. (-n flag: skipping automatic reboot)
```

#### Paso 4.3: Inspeccionar el entorno de arranque preparado e iniciar el reinicio
Inspeccione `/bsd.upgrade` y `/auto_upgrade.conf` creados por `sysupgrade` en el sistema de archivos raíz.

Ejecute:

```bash
ls -la /bsd.upgrade /auto_upgrade.conf
cat /auto_upgrade.conf
```

**Salida esperada:**
```text
-rwxr-xr-x  1 root  wheel  11956224 Aug  6 14:22 /bsd.upgrade
-rw-------  1 root  wheel        86 Aug  6 14:22 /auto_upgrade.conf

Location of sets = /home/_sysupgrade
Root filesystem has changed = yes
Force upgrade = yes
```

#### Paso 4.4: Sincronizar paquetes de terceros posteriormente a la actualización
Después de reiniciar en la release actualizada del sistema operativo OpenBSD, sincronice todos los puertos/paquetes de terceros instalados para que coincidan con la nueva versión de ABI.

Ejecute:

```bash
pkg_add -u
```

**Salida esperada:**
```text
quirks-7.5 signed on 2024-03-21T11:00:00Z
python-3.11.8 -> python-3.11.9: ok
nginx-1.24.0p0 -> nginx-1.26.0: ok
Finished updates.
```

---

### Preguntas de verificación — Ejercicio 4

#### Pregunta 4.1
Cuando se ejecuta `sysupgrade`, coloca el kernel del instalador en `/bsd.upgrade`. ¿Cómo sabe el gestor de arranque (bootloader) de OpenBSD (`boot(8)`) que debe ejecutar `/bsd.upgrade` en lugar del kernel `/bsd` predeterminado en el reinicio posterior del sistema?

#### Pregunta 4.2
¿Cuál es la función de `/etc/signify/openbsd-XX-base.pub` durante una ejecución de `sysupgrade`, y qué sucede si la validación de la firma falla durante la descarga del conjunto?

---

## Ejercicio 5: Instalación automatizada (`sysinst`) y actualizaciones binarias en NetBSD

### Escenario y contexto técnico
NetBSD utiliza `sysinst(8)` como su utilidad principal de instalación guiada por menús. Para despliegues automatizados, `sysinst` admite instalaciones desatendidas impulsadas por archivos de configuración mediante flags de línea de comandos (`sysinst -f configfile`). Además, el mantenimiento de las instalaciones de NetBSD implica descargar conjuntos base (tarballs `.tar.xz` o `.tgz`) y desempaquetarlos sobre la raíz del sistema mientras se utiliza `etcupdate(8)` para reconciliar los cambios de configuración en `/etc`.

---

### Ejecución guiada paso a paso

#### Paso 5.1: Consultar la arquitectura del sistema y los parámetros de release de NetBSD
Determine la arquitectura del sistema, el tipo de máquina y la versión de release utilizando `uname` y `sysctl`.

Ejecute:

```bash
uname -a
uname -m
uname -p
sysctl hw.model
```

**Salida esperada:**
```text
NetBSD netbsd-node-01.internal 10.0 NetBSD 10.0 (GENERIC) #0: Thu Mar 28 08:31:37 UTC 2024  build@netbsd.org:/usr/obj/sys/arch/amd64/compile/GENERIC amd64
amd64
x86_64
hw.model = Intel(R) Xeon(R) Gold 6248R CPU @ 3.00GHz
```

#### Paso 5.2: Crear un manifiesto de configuración automatizado para `sysinst`
Cree un archivo de configuración no interactivo de `sysinst` en `/tmp/sysinst.conf` para el aprovisionamiento automatizado de NetBSD.

Ejecute:

```bash
cat << 'EOF' > /tmp/sysinst.conf
# NetBSD sysinst automated installation configuration file
install
{
    disk = wd0;
    partition_type = gpt;
    logging = yes;
    net_media = dhcp;
    
    # Disk Partition layout specification
    partition = swap, size = 2048M;
    partition = /, size = rest, type = ffs, version = 2, cgd = no;

    # Fetch locations for NetBSD sets
    fetch_method = http;
    http_host = "cdn.netbsd.org";
    http_dir = "pub/NetBSD/NetBSD-10.0/amd64/binary/sets";

    # Distribution sets selection
    sets = base, comp, etc, games, kern-GENERIC, man, modules, text;
}
EOF
```

#### Paso 5.3: Invocar `sysinst` en modo desatendido
Ejecute `sysinst` pasando el manifiesto de configuración no interactivo.

Ejecute:

```bash
sysinst -f /tmp/sysinst.conf
```

**Salida esperada:**
```text
Parsing /tmp/sysinst.conf...
Configuring disk wd0 (GPT layout)...
Formatting wd0a (FFSv2 with logging)...
Fetching base.tar.xz from cdn.netbsd.org... 100%
Fetching comp.tar.xz from cdn.netbsd.org... 100%
Fetching etc.tar.xz from cdn.netbsd.org... 100%
Extracting sets into target root... done.
Executing post-install configuration... done.
NetBSD-10.0 installation complete.
```

#### Paso 5.4: Ejecutar la reconciliación de configuración in-situ utilizando `etcupdate`
Al actualizar los conjuntos binarios de NetBSD, los binarios del sistema se desempaquetan, pero los archivos de configuración en `/etc` deben fusionarse de forma segura mediante `etcupdate(8)` para evitar sobrescribir las personalizaciones locales.

Ejecute:

```bash
etcupdate -s /usr/usr-sets/etc.tar.xz
```

**Salida esperada:**
```text
*** Installing new files, updating existing files ***
/etc/group: merged automatically
/etc/rc.conf: user modified, skipping (merge required)
  [c] compare, [m] merge, [s] skip, [i] install new version: m
*** Starting 3-way merge using diff3 ***
Merge successful. New file written to /etc/rc.conf.
```

---

### Preguntas de verificación — Ejercicio 5

#### Pregunta 5.1
En la administración de sistemas NetBSD, ¿cuál es el rol operativo preciso de `sysinst` y cómo altera la marca (flag) `-f` su flujo de trabajo de ejecución?

#### Pregunta 5.2
¿Por qué es obligatorio utilizar `etcupdate(8)` o `postinstall(8)` al realizar actualizaciones binarias manuales de NetBSD desempaquetando los archivos actualizados de los conjuntos `base.tar.xz` y `etc.tar.xz` sobre la raíz del sistema?

---

<details>
<summary>Respuestas y explicaciones</summary>

### Soluciones del Ejercicio 1

#### Solución 1.1
* `uname -m` imprime la **implementación de hardware/arquitectura de la máquina** reportada por el kernel del sistema (por ejemplo, `amd64`, `i386`, `sparc64`).
* `uname -p` imprime la **arquitectura del procesador/arquitectura del conjunto de instrucciones (ISA)** (por ejemplo, `x86_64`, `aarch64`).
* En sistemas FreeBSD x86 de 64 bits, `uname -m` muestra `amd64` (el identificador de plataforma objetivo de FreeBSD), mientras que `uname -p` muestra `amd64` o `x86_64` dependiendo de los alias de destino del compilador. En familias de arquitecturas como ARM, `uname -m` podría devolver `arm` mientras que `uname -p` especifica la arquitectura de instrucciones precisa como `armv7` o `aarch64`.

#### Solución 1.2
La variable de entorno `DISTRIBUTIONS` dentro del script de `bsdinstall` define la lista de tarballs obtenidos y extraídos durante la instalación automatizada (por ejemplo, `DISTRIBUTIONS="base.txz kernel.txz src.txz"`).

#### Solución 1.3
* Colocar un espacio de swap activo dentro de un dataset de pool de almacenamiento ZFS (`zroot/swap`) introduce una condición potencial de **bloqueo mutuo (deadlock)** durante situaciones extremas de memoria baja (OOM). Para escribir páginas de memoria intercambiadas en un dataset ZFS, ZFS debe asignar buffers sucios (dirty buffers) y memoria del kernel para cálculos de metadatos copy-on-write (COW), checksums y compresión. Si la memoria libre se agota por completo, ZFS no puede asignar memoria para procesar la escritura, lo que provoca que la ruta de I/O se bloquee indefinidamente y genere un panic en el kernel.
* Asignar particiones de swap GPT brutas dedicadas (`freebsd-swap` formateadas fuera de ZFS) o habilitar el cifrado de swap GELI (`ZFSBOOT_SWAP_ENCRYPTION="YES"`) evita la sobrecarga de asignación de ZFS durante la paginación de memoria.

---

### Soluciones del Ejercicio 2

#### Solución 2.1
* Las actualizaciones de versión major implican cambios disruptivos en las ABI binarias (Application Binary Interfaces), números de llamadas al sistema (syscalls) y librerías compartidas del sistema (`libc.so`, `libcrypto.so`).
* **Primer `freebsd-update install`**: Actualiza solo el kernel (`/boot/kernel/kernel`) y los módulos del kernel. Luego se debe reiniciar el sistema para que el nuevo kernel (que mantiene compatibilidad con versiones anteriores de binarios de userland más antiguos) esté en ejecución activa.
* **Segundo `freebsd-update install`**: Actualiza los binarios del userland (`world`), las librerías del sistema y los archivos de cabecera (headers) mientras el sistema es respaldado por el nuevo kernel en ejecución. Ejecutar las actualizaciones del userland antes de arrancar el kernel compatible provocaría que los binarios activos del sistema fallen (crash) al enfrentarse a llamadas al sistema del kernel incompatibles.

#### Solución 2.2
`freebsd-update` realiza una fusión de tres vías (three-way merge) utilizando `diff3(1)` entre la configuración base inicial de la release original, las modificaciones locales del usuario en `/etc` y los nuevos valores predeterminados de la release entrante. Si los cambios se superponen en las mismas líneas de un archivo, `freebsd-update` activa una solicitud de fusión interactiva (o marca un estado de conflicto en modo por script), lo que permite al administrador resolver los marcadores de conflicto antes de finalizar la instalación.

#### Solución 2.3
Un SRE puede ejecutar `freebsd-update rollback`. Este comando restaura el kernel y los binarios de userland al estado inmediatamente anterior a la última ejecución de `freebsd-update install` intercambiando los archivos restaurados desde `/var/db/freebsd-update/`.

---

### Soluciones del Ejercicio 3

#### Solución 3.1
* `bsd.rd` es una imagen de kernel de OpenBSD independiente que contiene una imagen de disco RAM comprimida (`rd`) incrustada dentro de su estructura binaria.
* Durante el arranque, el sistema carga `bsd.rd` en la memoria física, monta el sistema de archivos raíz completamente en RAM (utilizando un disco de memoria `rd0`) y ejecuta el script de instalación `/install`.
* A diferencia del kernel multiprocesador de producción `/bsd` (o `/bsd.mp`), `bsd.rd` ejecuta un kernel de un solo procesador reducido que contiene controladores de dispositivos mínimos y herramientas de instalación (como `disklabel`, `newfs`, `bioctl` y `fetch`) necesarias para formatear discos e instalar paquetes base.

#### Solución 3.2
Si no se proporciona la opción 114 de DHCP (o la cadena de opción del vendedor), `autoinstall` envía solicitudes HTTP al gateway predeterminado o al servidor HTTP buscando archivos de respuesta nombrados en el siguiente orden:
1. `http://<boot-server>/<MAC_address>-install.conf` (por ejemplo, `52:54:00:ab:cd:ef-install.conf`)
2. `http://<boot-server>/<IP_address>-install.conf` (por ejemplo, `192.168.1.150-install.conf`)
3. `http://<boot-server>/install.conf`

#### Solución 3.3
La sintaxis `Set name(s) = +* -game* -x*` utiliza la coincidencia de patrones glob donde `+*` habilita todos los conjuntos estándar (`base75.tgz`, `comp75.tgz`, `man75.tgz`, etc.), `-game*` excluye explícitamente el conjunto de juegos (`game75.tgz`) y `-x*` excluye todos los conjuntos gráficos de X11 (`xbase75.tgz`, `xfont75.tgz`, `xserv75.tgz`, `xshare75.tgz`).

---

### Soluciones del Ejercicio 4

#### Solución 4.1
Cuando `sysupgrade` extrae `bsd.rd` en `/bsd.upgrade`, crea o actualiza el archivo de directivas de arranque del kernel `/boot.conf` o establece la variable de entorno del gestor de arranque indicando a `boot(8)` que cargue `/bsd.upgrade` en el siguiente reinicio. Una vez que `bsd.upgrade` arranca, detecta la presencia de `/auto_upgrade.conf`, activa una actualización automatizada sin interacción de red utilizando archivos de conjuntos pre-almacenados en `/home/_sysupgrade`, reemplaza `/bsd.upgrade` con el nuevo `/bsd`, elimina `/auto_upgrade.conf` y reinicia en el kernel de producción actualizado.

#### Solución 4.2
`/etc/signify/openbsd-XX-base.pub` contiene la clave criptográfica pública utilizada por `signify(1)` para verificar el archivo de firma digital (`SHA256.sig`) que acompaña a los tarballs de release de OpenBSD. Si la validación de la firma falla (debido a descargas corruptas, binarios alterados o mirrors no confiables), `sysupgrade` se aborta inmediatamente con un error de firma, evitando que código no autenticado o corrupto se prepare como `/bsd.upgrade`.

---

### Soluciones del Ejercicio 5

#### Solución 5.1
* `sysinst` es el programa oficial de instalación del sistema de NetBSD. Abstrae el particionamiento de disco (MBR/GPT), el formateo de disco (FFSv1/FFSv2), la configuración de la interfaz de red, la obtención de conjuntos (vía HTTP, FTP, NFS o medios locales) y la extracción base.
* Pasar `-f <config-file>` ejecuta `sysinst` de forma no interactiva. El archivo de configuración pre-pobla todas las respuestas de instalación (discos, selección de conjuntos, contraseñas, parámetros de red), suprimiendo los avisos interactivos de curses y habilitando pipelines de despliegue automatizados.

#### Solución 5.2
Desempaquetar archivos binarios como `base.tar.xz` directamente sobre un sistema de archivos raíz de NetBSD en vivo reemplaza los binarios del sistema (`/bin`, `/sbin`, `/usr/bin`), pero omitir `etcupdate(8)` deja los archivos de configuración (`/etc/master.passwd`, `/etc/rc.conf`, `/etc/defaults/rc.conf`) desincronizados con los nuevos requerimientos del daemon o estructuras del sistema. `etcupdate` reconcilia las diferencias de los archivos de configuración sin sobrescribir los parámetros de configuración local personalizados, mientras que `postinstall(8)` comprueba si hay archivos obsoletos, nodos de dispositivos rotos en `/dev` y usuarios del sistema faltantes.

</details>