# 1.2 Linux Installation and Package Management

## 1. Motivaci\u00f3n y Problema Arquitect\u00f3nico de Producci\u00f3n

En un entorno de producci\u00f3n moderno, ya no instalamos sistemas operativos manualmente usando un CD/ISO y un asistente gr\u00e1fico. Como SREs y Platform Architects, el aprovisionamiento de miles de nodos debe ser automatizado, determinista e inmutable. El particionado de discos, la configuraci\u00f3n del boot manager y, crucialmente, la gesti\u00f3n de paquetes, deben definirse como c\u00f3digo (Infrastructure as Code - IaC).

El "Dependency Hell" y los conflictos de librer\u00edas compartidas (Shared Libraries) son problemas cr\u00edticos que pueden tirar abajo un cl\u00faster entero tras una actualizaci\u00f3n. Un RPM o DEB mal empaquetado, o un post-install script fallido, puede dejar el sistema en un estado inconsistente (half-installed). Entender las entra\u00f1as de `dpkg`/`APT` y `rpm`/`YUM`/`DNF`, as\u00ed como la resoluci\u00f3n din\u00e1mica del linker (ld.so), permite al operador diagnosticar por qu\u00e9 un binario falla al iniciar con un `segmentation fault` o `library not found` despu\u00e9s de un parcheo.

## 2. Comparativas T\u00e9cnicas y Trade-offs

### Gestores de Paquetes: Debian (APT) vs. Red Hat (DNF)

| Caracter\u00edstica | Fam\u00edlia Debian (dpkg / apt) | Fam\u00edlia Red Hat (rpm / dnf / yum) |
| :--- | :--- | :--- |
| **Bajo Nivel (Backend)** | `dpkg`. Utiliza archivos `.deb` (ar archive con tarballs). | `rpm`. Utiliza archivos `.rpm` (cpio archive comprimido). |
| **Alto Nivel (Frontend)** | `apt-get`, `apt`. Resuelve dependencias y descarga. | `dnf` (sucesor de `yum`). Usa `libsolv` para resoluci\u00f3n SAT. |
| **Manejo de Metadatos** | Basado en archivos de texto plano localizados en `/var/lib/dpkg/status`. | Basado en bases de datos Berkeley DB / SQLite en `/var/lib/rpm/`. |
| **Scriptlets** | preinst, postinst, prerm, postrm. | %pre, %post, %preun, %postun. |
| **Recomendaci\u00f3n SRE** | Excelente para contenedores base (Alpine/Debian) por su ligereza en toolchain. | `dnf` tiene un solver matem\u00e1tico superior (`libsolv`) evitando deadlocks complejos. |

### Particionado: LVM vs. Particiones Est\u00e1ticas

| Arquitectura | Flexibilidad | Rendimiento | Caso de Uso en Plataforma |
| :--- | :--- | :--- | :--- |
| **Partici\u00f3n Tradicional (MBR/GPT)** | Nula. Requiere redimensionamiento de FS offline a menudo riesgoso. | Nativo. Sin overhead de abstracci\u00f3n. | Nodos ef\u00edmeros Cloud (donde la VM se destruye y recrea). |
| **LVM (Logical Volume Manager)** | Alta. Resizes online, snapshots, spanning discos m\u00faltiples. | Overhead marginal (negligible). | Servidores Bare-Metal, Bases de Datos stateful con snapshots (e.g. PostgreSQL). |

## 3. Manifiestos, Configuraci\u00f3n e Infraestructura

En automatizaci\u00f3n de cloud, utilizamos **Cloud-Init** para inyectar configuraciones de particionado y paquetes en el primer booteo, abstrayendo el proceso cl\u00e1sico de instalaci\u00f3n interactiva.

### Manifiesto Cloud-Init: `user-data.yaml`

Este YAML define un layout de disco (combinando particiones GPT y LVM) y asegura que ciertos paquetes cr\u00edticos est\u00e9n instalados (y actualizados).

```yaml
#cloud-config
# Documentaci\u00f3n: https://cloudinit.readthedocs.io/

# 1. Configuraci\u00f3n de Repositorios Custom (Apt)
apt:
  sources:
    docker.list:
      source: "deb [arch=amd64] https://download.docker.com/linux/ubuntu focal stable"
      keyid: 9DC858229FC7DD38854AE2D88D81803C0EBFCD88

# 2. Package Management: Actualizar todo e instalar toolchain SRE
package_update: true
package_upgrade: true
packages:
  - lvm2
  - curl
  - jq
  - strace
  - lsof
  - docker-ce

# 3. Storage Layout (Declarativo)
# Creaci\u00f3n de un Physical Volume, un Volume Group y un Logical Volume de 20GB
disk_setup:
  /dev/nvme1n1:
    table_type: gpt
    layout: [100]

fs_setup:
  - label: data_fs
    filesystem: ext4
    device: /dev/vg_data/lv_data

# Configuraci\u00f3n de LVM expl\u00edcita
bootcmd:
  - [ pvcreate, /dev/nvme1n1p1 ]
  - [ vgcreate, vg_data, /dev/nvme1n1p1 ]
  - [ lvcreate, -L, 20G, -n, lv_data, vg_data ]

mounts:
  - [ /dev/vg_data/lv_data, /var/lib/docker, "ext4", "defaults,noatime", "0", "2" ]
```

## 4. Comandos CLI y Salidas de Terminal Reales

### Gesti\u00f3n de Librer\u00edas Compartidas (Shared Libraries)

Para que un binario corra, el linker (`ld.so`) debe encontrar sus dependencias en runtime (`.so` files).

```bash
# Ver las librer\u00edas compartidas requeridas por un binario de sistema (ej. curl)
$ ldd /usr/bin/curl
        linux-vdso.so.1 (0x00007ffe4816c000)
        libcurl.so.4 => /lib/x86_64-linux-gnu/libcurl.so.4 (0x00007f9c8f000000)
        libz.so.1 => /lib/x86_64-linux-gnu/libz.so.1 (0x00007f9c8f352000)
        libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f9c8ec00000)

# Actualizar la cach\u00e9 del linker tras instalar una librer\u00eda manual en /usr/local/lib
# El binario ldconfig escanea los directorios en /etc/ld.so.conf
$ sudo ldconfig -v | grep -i libcurl
ldconfig: Can't stat /usr/local/lib/x86_64-linux-gnu: No such file or directory
/lib/x86_64-linux-gnu: (from /etc/ld.so.conf.d/x86_64-linux-gnu.conf:4)
        libcurl.so.4 -> libcurl.so.4.7.0
```

### Gesti\u00f3n de Paquetes Nivel DPKG / APT (Debian/Ubuntu)

```bash
# Encontrar qu\u00e9 paquete instal\u00f3 un archivo cr\u00edtico ca\u00eddo
$ dpkg -S /etc/ssh/sshd_config
openssh-server: /etc/ssh/sshd_config

# Ver informaci\u00f3n detallada y dependencias estrictas (Depends vs Recommends)
$ apt-cache show openssh-server | grep -E 'Depends:|Version:'
Version: 1:8.9p1-3ubuntu0.10
Depends: adduser (>= 3.9), dpkg (>= 1.9.0), init-system-helpers (>= 1.54~), libaudit1 (>= 1:2.2.1)
```

### Gesti\u00f3n de Paquetes Nivel RPM / YUM / DNF (RHEL/CentOS/Fedora)

```bash
# Consultar (\u201cQuery\u201d) los scripts de pre/post instalaci\u00f3n de un paquete RPM (muy \u00fatil en debug de postinst rotos)
$ rpm -q --scripts nginx
preinstall scriptlet (using /bin/sh):
getent group nginx >/dev/null || groupadd -r nginx
getent passwd nginx >/dev/null || useradd -r -g nginx -s /sbin/nologin nginx
postinstall scriptlet (using /bin/sh):
if [ $1 -eq 1 ]; then
    /usr/bin/systemctl preset nginx.service >/dev/null 2>&1 || :
fi

# Listar transacciones hist\u00f3ricas de DNF (SRE \u201cundo\u201d capability)
$ dnf history list
ID     | Command line             | Date and time    | Action(s)      | Altered
-------------------------------------------------------------------------------
    42 | install nginx            | 2023-10-15 14:02 | Install        |    1
    41 | update                   | 2023-10-14 09:30 | Upgrade        |   45

# Revertir una instalaci\u00f3n corrupta (deshacer la transacci\u00f3n 42)
$ sudo dnf history undo 42
```

## 5. Gu\u00eda de Verificaci\u00f3n y Diagn\u00f3stico de Fallas

1. **Diagn\u00f3stico de Librer\u00edas Faltantes (`cannot open shared object file`)**:
   Si un binario tira el error `error while loading shared libraries: libfoo.so: cannot open shared object file`:
   - Utiliza `ldd <binario>` para ver cu\u00e1l libreria exacta dice `not found`.
   - Busca en el repositorio qu\u00e9 paquete provee esa libreria: `apt-file search libfoo.so` o `dnf provides "*/libfoo.so"`.
   - Revisa si el path est\u00e1 incluido en `/etc/ld.so.conf` (o en `.conf` dentro de `/etc/ld.so.conf.d/`).
   - Si la librer\u00eda existe pero en otra ruta custom (ej. `/opt/custom/lib`), utiliza la variable de entorno `LD_LIBRARY_PATH` para bypassear el linker temporalmente: `LD_LIBRARY_PATH=/opt/custom/lib ./mibinario`.

2. **Reparaci\u00f3n de Paquetes Inconsistentes en APT**:
   Si una instalaci\u00f3n se corta a la mitad (por ejemplo, por un corte de red o espacio insuficiente) y `apt` arroja `dpkg was interrupted`:
   ```bash
   # Reconfigurar paquetes half-installed o unpackaged
   $ sudo dpkg --configure -a
   # Forzar resoluci\u00f3n de dependencias rotas
   $ sudo apt-get install -f
   ```

3. **Reparaci\u00f3n de la Base de Datos de RPM**:
   En entornos Red Hat, una interrupci\u00f3n brusca puede corromper la base de datos BDB/SQLite de RPM, impidiendo que `dnf` funcione, arrojando *DB_RUNRECOVERY*.
   ```bash
   $ sudo rm -f /var/lib/rpm/__db*
   $ sudo rpm --rebuilddb
   $ sudo dnf clean all
   ```

4. **Debugging de Inicializaci\u00f3n del Particionado (Initramfs/LVM)**:
   Si el sistema cae a una terminal de emergencia (`initramfs>`) porque no puede montar `/root` en un volumen LVM:
   - Verifica que el Volume Group fue ensamblado por el kernel temprano: `lvm vgscan` y `lvm vgchange -ay`.
   - Comprueba el block device subyacente con `blkid` (para comparar UUIDs definidos en `/etc/fstab` vs los reales de la partici\u00f3n LVM `/dev/mapper/vg0-root`).

## 6. Referencias

* LPIC-1 Objetivos (Topic 102): [https://www.lpi.org/our-certifications/exam-101-objectives](https://www.lpi.org/our-certifications/exam-101-objectives)
* Cloud-Init Official Docs (Disk Setup): [https://cloudinit.readthedocs.io/en/latest/reference/modules.html#disk-setup](https://cloudinit.readthedocs.io/en/latest/reference/modules.html#disk-setup)
* Debian Package Management (dpkg/apt): [https://www.debian.org/doc/manuals/debian-reference/ch02.en.html](https://www.debian.org/doc/manuals/debian-reference/ch02.en.html)
* DNF Command Reference: [https://dnf.readthedocs.io/en/latest/command_ref.html](https://dnf.readthedocs.io/en/latest/command_ref.html)
* Linux ld.so (Dynamic Linker) Man Page: [https://man7.org/linux/man-pages/man8/ld.so.8.html](https://man7.org/linux/man-pages/man8/ld.so.8.html)