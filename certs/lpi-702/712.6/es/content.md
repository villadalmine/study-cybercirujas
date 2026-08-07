# LPI BSD Specialist (702-100) | Topic 712.6: Find Files and BSD Directory Layout

**Exam Topic:** 712.6: Find Files and BSD Directory Layout  
**Weight:** 3.33  
**Target Role:** Senior SRE / Principal Platform Architect  

---

## 1. Motivación Arquitectónica y Contexto de Producción

En entornos UNIX empresariales que ejecutan FreeBSD, OpenBSD o NetBSD, la organización de archivos se rige estrictamente por `hier(7)`. A diferencia de las convenciones de las distribuciones Linux reguladas por el Filesystem Hierarchy Standard (FHS 3.0), la arquitectura BSD impone una separación inmutable entre el **Sistema Operativo Base** y los **Paquetes de Terceros** (`/usr/local`).

```
                              BSD ROOT HIERARCHY (hier(7))
                                           │
         ┌─────────────────────────────────┼─────────────────────────────────┐
         │                                 │                                 │
     / (Root FS)                        /usr                              /var
 ┌───────┴───────┐             ┌───────────┴───────────┐             ┌───────┴───────┐
/bin   /sbin   /etc         /usr/bin    /usr/sbin  /usr/local    /var/db  /var/log /var/tmp
(Base system essential)     (Base system binaries) (Packages)    (pkg db, locate)
```

### Desafíos Arquitectónicos en Producción

1. **Aislamiento del OS Base vs. Paquetes Userland**  
   En FreeBSD y OpenBSD, las utilidades del sistema base (`/bin`, `/sbin`, `/usr/bin`, `/usr/sbin`) se mantienen como un árbol de código fuente unificado (`/usr/src`). Todo el software de terceros (instalado mediante `pkg(8)` o BSD Ports) se restringe a `/usr/local`. Ubicar incorrectamente archivos de configuración (por ejemplo, colocar `nginx.conf` en `/etc/nginx/` en lugar de `/usr/local/etc/nginx/`) rompe las rutas de actualización durante las actualizaciones del OS base (`freebsd-update`, `sysupgrade`).

2. **Límites de Datasets ZFS y Recorrido de Archivos de Alto IOPS**  
   Las implementaciones de BSD en producción aprovechan ZFS con datasets dedicados por rama de directorio (`zroot/var/log`, `zroot/usr/home`, `zroot/jails`). Ejecutar recorridos del sistema de archivos (`find /`) sin restricciones de mountpoint cruza los límites de los snapshots de ZFS y desencadena picos masivos de IOPS en datasets con alto nivel de modificación (churn). Los SREs deben usar flags de límite (`-xdev` / `-mount`) para delimitar el alcance de los motores de búsqueda durante incidentes en vivo.

3. **Atributos Extendidos de Archivos y Flags de Archivo de BSD (`chflags`)**  
   Los sistemas de archivos BSD admiten flags específicos de BSD (por ejemplo, `schg` [sistema inmutable], `sappnd` [sistema de solo anexar], `nodump`). Las rutinas habituales de solución de problemas en Linux no logran identificar por qué `rm -rf` falla en procesos de `root` cuando estos flags están establecidos. Encontrar archivos con flags en almacenamiento de alta densidad requiere un conocimiento profundo de los flags predicado de `find(1)` en BSD (`-flags`).

4. **Sobrecarga de Indexación en Segundo Plano vs. Diagnósticos en Tiempo Real**  
   El motor `locate(1)` de BSD se basa en una base de datos preconstruida generada por `/usr/libexec/locate.updatedb` (activada mediante `/etc/periodic/weekly/310.locate`). En servidores de almacenamiento empresarial que albergan decenas de millones de inodos, las tareas de `locate.updatedb` mal ajustadas agotan la memoria o el ancho de banda del disco. Los SREs deben equilibrar el recorrido de inodos en tiempo real (`find`) frente a las búsquedas indexadas en bases de datos (`locate`).

---

## 2. Comparaciones Técnicas y Tablas de Trade-offs

### 2.1 Jerarquía BSD (`hier(7)`) vs. Linux FHS 3.0

| Directorio | Estándar BSD (`hier(7)`) | Estándar Linux (FHS 3.0) | Impacto Arquitectónico e Implicaciones para SRE |
| :--- | :--- | :--- | :--- |
| **`/usr/local`** | Prefijo obligatorio para **todos** los ports/paquetes de terceros (binarios, configuraciones en `/usr/local/etc`, librerías). | Ubicación opcional para software instalado localmente por el administrador del sistema. | BSD impone un aislamiento total. Actualizar el OS base nunca sobrescribe archivos de paquetes en `/usr/local/etc`. |
| **`/etc` vs `/usr/local/etc`** | `/etc` está estrictamente reservado para el OS Base. Las configuraciones de paquetes **deben** residir en `/usr/local/etc`. | `/etc` alberga la configuración tanto para paquetes de la distribución como para servicios del sistema. | La gestión de configuración centralizada (Ansible/Puppet) debe apuntar a rutas separadas en BSD según los orígenes de los binarios. |
| **`/usr/src` & `/usr/obj`** | Contiene el código fuente canónico del OS Base y los archivos objeto compilados. | Rara vez utilizado; los headers del kernel residen en `/usr/src/kernels/`. | Las actualizaciones del sistema BSD pueden compilar el world y el kernel directamente desde `/usr/src` hacia `/usr/obj`. |
| **`/libexec` / `/usr/libexec`** | Demonios del sistema y binarios internos ejecutados por otros programas (por ejemplo, `locate.updatedb`). | Helpers internos a menudo dispersos bajo `/usr/lib/` o `/usr/libexec/`. | Los scripts del sistema dependen de ubicaciones estables en `/usr/libexec/` para la ejecución interna del sistema base. |
| **`/dev`** | Gestionado dinámicamente por `devfs(5)` (FreeBSD) o abstracciones de `devfs`. | Gestionado por `udev` / `sysfs` (`/sys`). | `devfs` en BSD admite conjuntos de reglas por Jail para restringir la visibilidad de dispositivos. |

### 2.2 Utilidades de Búsqueda de Archivos: Trade-offs Operativos

| Herramienta | Mecanismo de Búsqueda | Requisito de Índice | Sobrecarga de IOPS | Mejor Caso de Uso | Riesgo / Modo de Falla |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`find(1)`** | Recorrido en vivo del árbol del sistema de archivos | Ninguno (Tiempo real) | **Alto** (Escala con la cantidad de inodos) | Solución de problemas en tiempo real, filtros booleanos complejos, ejecución de acciones en archivos coincidentes. | Puede degradar el rendimiento de lectura del pool ZFS; puede cruzar límites de datasets/puntos de montaje NFS sin `-xdev`. |
| **`locate(1)`** | Consulta una base de datos binaria rápida (`/var/db/locate.database`) | Requiere `/usr/libexec/locate.updatedb` | **Insignificante** | Búsqueda instantánea de archivos estáticos, librerías y plantillas de configuración. | Resultados desactualizados; devuelve archivos eliminados u omite archivos recién creados hasta que se ejecute el índice. |
| **`whereis(1)`** | Busca en rutas estándar de binarios, manuales y fuentes | Ninguno (Escanea rutas fijas del sistema) | **Muy Bajo** | Encontrar rutas ejecutables, páginas de manual y árboles de código fuente para utilidades estándar. | Falla si se utilizan rutas no estándar; capacidad de filtrado limitada. |
| **`which(1)`** | Evalúa la variable de entorno `$PATH` del usuario | Ninguno | **Insignificante** | Identificar el binario exacto ejecutado por el entorno del shell actual. | Depende del `$PATH` del usuario; los aliases o built-ins del shell pueden ocultar la ubicación del binario. |

### 2.3 Mecanismos de Ejecución de `find`: `-exec` vs `-execdir` vs `xargs -0`

| Sintaxis de Ejecución | Creación de Procesos | Contexto de Ruta | Perfil de Seguridad y Condiciones de Carrera | Rendimiento |
| :--- | :--- | :--- | :--- | :--- |
| **`find ... -exec cmd {} \;`** | 1 proceso por archivo coincidente | Evalúa desde la raíz de invocación | Vulnerable a condiciones de carrera por recorrido de directorios (`TOCTOU`). | **Deficiente** (Alta sobrecarga de `fork()`) |
| **`find ... -exec cmd {} +`** | Lista de argumentos por lotes (como `xargs`) | Evalúa desde la raíz de invocación | Vulnerable si los directorios de destino son escribibles por usuarios sin privilegios. | **Alto** |
| **`find ... -execdir cmd {} \;`** | 1 proceso por archivo | Se ejecuta dentro del directorio padre del archivo de destino (`./file`) | **Seguro**: Previene condiciones de carrera `TOCTOU` por symlinks. | **Medio** |
| **`find ... -print0 \| xargs -0`** | Lista de argumentos por lotes | Evalúa desde la raíz de invocación | **Seguro contra espacios/saltos de línea**; altamente robusto para limpiezas a gran escala. | **Óptimo** |

---

## 3. Infraestructura de Producción y Configuraciones de Manifiestos

El siguiente playbook de Ansible proporciona una especificación de despliegue completa para nodos de producción FreeBSD. Aplica las convenciones estándar de directorios BSD, crea datasets ZFS optimizados para alta rotación de logs, configura rutinas semanales automatizadas de `locate.updatedb` con exclusiones personalizadas y despliega scripts de monitoreo del sistema.

```yaml
---
- name: Enforce BSD Directory Layout & Search Infrastructure
  hosts: bsd_servers
  gather_facts: true
  vars:
    base_etc_dir: "/etc"
    pkg_etc_dir: "/usr/local/etc"
    locate_db_path: "/var/db/locate.database"
    locate_exclude_paths: "/tmp /var/tmp /usr/obj /zroot/jails/containers/*/root/tmp"

  tasks:
    - name: Ensure ZFS datasets adhere to BSD hier(7) layout
      community.general.zfs:
        name: "{{ item.name }}"
        state: present
        properties:
          mountpoint: "{{ item.mountpoint }}"
          atime: "off"
          compression: "lz4"
      loop:
        - { name: 'zroot/var/log', mountpoint: '/var/log' }
        - { name: 'zroot/var/tmp', mountpoint: '/var/tmp' }
        - { name: 'zroot/usr/obj', mountpoint: '/usr/obj' }
        - { name: 'zroot/usr/local', mountpoint: '/usr/local' }

    - name: Create package configuration subdirectories under /usr/local/etc
      ansible.builtin.file:
        path: "{{ item }}"
        state: directory
        owner: root
        group: wheel
        mode: '0755'
      loop:
        - "{{ pkg_etc_dir }}/nginx"
        - "{{ pkg_etc_dir }}/syslog-ng"
        - "{{ pkg_etc_dir }}/monitoring"

    - name: Configure periodic locate database rebuild parameters in /etc/periodic.conf
      ansible.builtin.blockinfile:
        path: /etc/periodic.conf
        create: true
        owner: root
        group: wheel
        mode: '0644'
        block: |
          # Enable weekly locate db update and set enterprise ZFS path exclusions
          weekly_locate_enable="YES"
          weekly_locate_flags="-e '{{ locate_exclude_paths }}'"
          weekly_locate_profile="nobody"

    - name: Deploy automated security file flag scanner script
      ansible.builtin.copy:
        dest: /usr/local/bin/bsd_flag_audit.sh
        owner: root
        group: wheel
        mode: '0750'
        content: |
          #!/bin/sh
          # Production SRE Script: Audit System Immutable (schg) and User Immutable (uchg) flags
          set -eu

          LOG_FILE="/var/log/sys_flag_audit.log"
          TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

          echo "[${TIMESTAMP}] Starting BSD File Flag Audit..." > "${LOG_FILE}"

          echo "=== System Immutable Files (schg) ===" >> "${LOG_FILE}"
          find -x / -flags +schg -ls >> "${LOG_FILE}" 2>&1

          echo "=== User Immutable Files (uchg) ===" >> "${LOG_FILE}"
          find -x / -flags +uchg -ls >> "${LOG_FILE}" 2>&1

          echo "=== Non-dumpable Files (nodump) ===" >> "${LOG_FILE}"
          find -x /var /usr/local -flags +nodump -ls >> "${LOG_FILE}" 2>&1

          echo "[${TIMESTAMP}] Audit complete. Output written to ${LOG_FILE}"

    - name: Schedule cron job for locate database manually updated off-peak
      ansible.builtin.cron:
        name: "Update BSD locate database"
        minute: "30"
        hour: "02"
        day: "*"
        month: "*"
        weekday: "0"
        user: root
        job: "/usr/libexec/locate.updatedb >/dev/null 2>&1"
```

---

## 4. Ejecución en Terminal y Ejemplos de Salida de Comandos

### 4.1 Localizando Binarios, Manuales y Fuentes (`which`, `whereis`)

Evaluando las ubicaciones de ejecución de binarios y verificando el mapeo del código fuente del OS base:

```bash
$ which nginx pkg bsdconfig
/usr/local/sbin/nginx
/usr/sbin/pkg
/usr/sbin/bsdconfig

$ whereis -b -m -s nginx
nginx: /usr/local/sbin/nginx /usr/local/man/man8/nginx.8.gz

$ whereis -b -m -s pfctl
pfctl: /sbin/pfctl /usr/share/man/man8/pfctl.8.gz /usr/src/sbin/pfctl
```

### 4.2 Recorrido Avanzado con `find(1)` en BSD

#### Escenario A: Buscando a través de límites ZFS mientras se consultan flags de archivo BSD

Localizar todos los archivos que tienen establecido el flag de sistema inmutable (`schg`) dentro del sistema de archivos raíz, asegurando que `find` no se desplace hacia datasets ZFS separados (`/var`, `/usr/home`):

```bash
$ find -x / -flags +schg -exec ls -lo {} +
-r-xr-xr-x  1 root  wheel  schg 437648 Jan 12 04:15 /bin/rcp
-r-xr-xr-x  1 root  wheel  schg 387120 Jan 12 04:15 /sbin/init
-r-xr-xr-x  2 root  wheel  schg  54820 Jan 12 04:15 /usr/bin/login
```

#### Escenario B: Encontrar archivos de log modificados en las últimas 24 horas que superen los 50MB, ejecutados de forma segura mediante `-execdir`

```bash
$ find /var/log -type f -mtime -1 -size +50M -execdir ls -lh {} \;
-rw-r-----  1 root  wheel    84M Aug  6 18:45 nginx-access.log
-rw-r--r--  1 root  wheel    112M Aug  6 20:10 daemon.log
```

#### Escenario C: Encontrar archivos sin propietario (UID/GID ausentes en `/etc/passwd` o `/etc/group`) para endurecimiento de seguridad

```bash
$ find /usr/local -nouser -o -nogroup -ls
348912   4 -rw-r--r--   1 1005   1005       1024 Aug  5 11:20 /usr/local/www/orphaned.tmp
```

#### Escenario D: Combinando evaluación de tiempo (`-newer`) y coincidencia de permisos

```bash
$ find /usr/local/etc -type f -perm -0022 -newer /etc/motd -ls
812044   4 -rw-rw-r--   1 root  wheel        512 Aug  6 14:02 /usr/local/etc/nginx/nginx.conf
```

### 4.3 Construyendo y Consultando la Base de Datos de `locate(1)`

#### Escenario A: Activación manual de `/usr/libexec/locate.updatedb`

```bash
$ su -m nobody -c "/usr/libexec/locate.updatedb"
$ ls -lh /var/db/locate.database
-rw-r--r--  1 nobody  wheel   8.4M Aug  6 20:30 /var/db/locate.database
```

#### Escenario B: Consultando `locate` con patrones insensibles a mayúsculas/minúsculas y contando coincidencias

```bash
$ locate -i "pf.conf"
/etc/pf.conf
/usr/share/examples/pf/pf.conf
/usr/local/share/doc/haproxy/pf.conf

$ locate -c -i "*.conf"
4128
```

---

## 5. Verificación en Producción y Guía de Solución de Problemas

```
                        TROUBLESHOOTING FILE SEARCH & LAYOUT FAILURES
                                             │
               ┌─────────────────────────────┴─────────────────────────────┐
               ▼                                                           ▼
    [File Deletion / Edit Failed]                               [Locate Return Outdated]
               │                                                           │
     Check BSD Flags (ls -lo)                                 Verify /var/db/locate.database
               │                                                           │
   ┌───────────┴───────────┐                                   ┌───────────┴───────────┐
   ▼                       ▼                                   ▼                       ▼
Flag = schg/uchg     No Flag Set                           DB Stale (> 7 Days)     Permission Denied
   │                       │                                   │                       │
chflags 0 <file>     Check ZFS RO                              Run updatedb        Verify read mode (0644)
                     zfs get readonly                         as 'nobody'          for /var/db/locate.database
```

### 5.1 Flujo de Trabajo de Diagnóstico: Investigando "Operation Not Permitted" en Root (`EPERM`)

#### Paso 1: Reproducir el error como `root`

```bash
$ id
uid=0(root) gid=0(wheel) groups=0(wheel)

$ rm -f /usr/bin/custom_daemon
rm: /usr/bin/custom_daemon: Operation not permitted
```

#### Paso 2: Inspeccionar flags extendidos de archivo usando `ls -lo` o `stat -f` en BSD

El comando estándar `ls -l` **no** expone los flags de archivo de BSD.

```bash
$ ls -lo /usr/bin/custom_daemon
-rwxr-xr-x  1 root  wheel  schg,nodump 1048576 Aug  6 10:00 /usr/bin/custom_daemon

$ stat -f "File: %N | Flags: %f | Hex Flags: 0x%X" /usr/bin/custom_daemon
File: /usr/bin/custom_daemon | Flags: schg,nodump | Hex Flags: 0x20020
```

#### Paso 3: Eliminar el flag inmutable usando `chflags(1)` y completar la operación

```bash
$ chflags noschg /usr/bin/custom_daemon
$ ls -lo /usr/bin/custom_daemon
-rwxr-xr-x  1 root  wheel  nodump 1048576 Aug  6 10:00 /usr/bin/custom_daemon

$ rm -f /usr/bin/custom_daemon
$ echo $?
0
```

> [!IMPORTANT]
> Si securelevel (`sysctl kern.securelevel`) está establecido en `1` o `2`, los flags de sistema inmutable (`schg`) **no** pueden ser eliminados ni siquiera por `root` mientras se ejecute en modo multiusuario. Debe pasar al modo monousuario para eliminar los flags `schg` cuando `kern.securelevel > 0`.

### 5.2 Flujo de Trabajo de Diagnóstico: Depurando IOPS Altos / Comandos `find` Bloqueados

#### Paso 1: Detectar cuellos de botella por recorrido entre datasets

Si `find /` se bloquea, verifique los procesos en ejecución y los puntos de montaje para confirmar si `find` ingresó en montajes NFS remotos o snapshots de ZFS con alto nivel de modificación.

```bash
$ ps aux | grep find
root  4512  89.4  0.2  14280  8192  0  R+   20:41   2:14.15 find / -name *.log

$ procstat -f 4512
  PID COMM                FD AT TR DB V NAME
 4512 find                 text r  -  -  - /usr/bin/find
 4512 find                 cwd  r  -  -  - /zroot/jails/build-jail/root/usr/obj
```

#### Paso 2: Remediar restringiendo los límites de recorrido

Pase siempre `-x` (o `-xdev`) para evitar que `find` realice recorridos a través de puntos de montaje:

```bash
$ find -x / -name "*.log" -print
```

### 5.3 Lista de Verificación de Diagnóstico para Fallas en la Base de Datos de `locate`

1. **Verificar existencia y tamaño de la base de datos**:
   ```bash
   ls -lh /var/db/locate.database
   ```
   *Si el archivo no existe o tiene 0 bytes, ejecute `/usr/libexec/locate.updatedb`.*

2. **Verificar permisos**:
   La base de datos de `locate` debe ser legible globalmente (`0644`) y pertenecer a `nobody:wheel`.
   ```bash
   chown nobody:wheel /var/db/locate.database
   chmod 0644 /var/db/locate.database
   ```

3. **Verificar la configuración periódica**:
   Asegúrese de que `/etc/periodic.conf` o `/etc/defaults/periodic.conf` contenga `weekly_locate_enable="YES"`.

---

## 6. Referencias

- **FreeBSD `hier(7)` Manual Page:**  
  https://man.freebsd.org/cgi/man.cgi?query=hier&sektion=7  
- **FreeBSD `find(1)` Manual Page:**  
  https://man.freebsd.org/cgi/man.cgi?query=find&sektion=1  
- **FreeBSD `chflags(1)` Manual Page:**  
  https://man.freebsd.org/cgi/man.cgi?query=chflags&sektion=1  
- **OpenBSD `hier(7)` Specification:**  
  https://man.openbsd.org/hier.7  
- **NetBSD File System Hierarchy Overview:**  
  https://man.netbsd.org/hier.7  
- **LPI BSD Specialist Certification Overview:**  
  https://www.lpi.org/our-certifications/bsd-specialist-overview/  
- **LPI BSD Specialist Objectives (702-100):**  
  https://wiki.lpi.org/wiki/BSD_Specialist_Objectives_702