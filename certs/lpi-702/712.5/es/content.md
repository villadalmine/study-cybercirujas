# LPI-702 (Exam 702-100) Topic 712.5: Create and Change Hard and Symbolic Links

**Exam Topic**: 712.5 Create and Change Hard and Symbolic Links  
**Weight**: 1.67  
**Target Certification**: LPI BSD Specialist (Exam 702-100, Version 1.0)  

---

## 1. Production Architectural Motivation & Core Mechanics

En la infraestructura empresarial de Unix y BSD (FreeBSD, OpenBSD, NetBSD), las abstracciones de punteros del filesystem dictan cómo los binarios, librerías, árboles de configuración, despliegues dinámicos y backends de almacenamiento de contenedores interactúan con las capas del Virtual File System (VFS).

```
       Directory Entry (dirent)              Inode (UFS2 / znode)           Storage Blocks
+------------------------------------+    +------------------------+    +--------------------+
| Filename: app.conf                 |--->| Inode Number: 1048578  |--->| [ Block Data ]     |
| Pointer:  1048578                  |    | st_nlink: 2            |    | "server_name: ..." |
+------------------------------------+    | st_mode:  -rw-r--r--   |    +--------------------+
                                          +------------------------+              ^
                                                      ^                           |
       Directory Entry (dirent)                       |                           |
+------------------------------------+                |                           |
| Filename: app.conf.hardlink        |----------------+                           |
| Pointer:  1048578                  |                                            |
+------------------------------------+                                            |
                                                                                  |
       Directory Entry (dirent)              Inode (UFS2 / znode)                 |
+------------------------------------+    +------------------------+              |
| Filename: app.conf.symlink         |--->| Inode Number: 2097152  |              |
| Pointer:  2097152                  |    | st_nlink: 1            |              |
+------------------------------------+    | st_mode:  lrwxrwxrwx   |              |
                                          | Target: "app.conf"     |--------------+
                                          +------------------------+ (Fast Symlink / Direct inline string)
```

### 1.1 Inodes vs. Directory Entries (dirents)
Un archivo en un filesystem de Unix/BSD (como UFS2 o ZFS) consta de dos componentes distintos:
1. **Metadata Index Node (Inode / znode)**: Contiene metadatos incluyendo permisos (`st_mode`), propietario (`st_uid`), grupo (`st_gid`), tamaño (`st_size`), array de timestamps (`st_atim`, `st_mtim`, `st_ctim`), contador de hard links (`st_nlink`) y punteros a bloques de datos. De manera crucial, el inode **no** contiene el filename.
2. **Directory Entry (`dirent`)**: Un mapeo simple almacenado dentro de un bloque de datos de directorio que empareja una cadena de filename legible por humanos con un número entero de inode.

### 1.2 Hard Links Engine (`link(2)`)
Un hard link crea una nueva directory entry (`dirent`) que apunta a un **número de inode ya existente** en la misma instancia de filesystem.
* **Metadata Impact**: Ejecutar `link(2)` incrementa el contador `st_nlink` del inode en 1.
* **Deletion Mechanics**: Llamar a `unlink(2)` sobre un filename con hard link elimina la directory entry especificada y decrementa `st_nlink`. Los bloques de almacenamiento subyacentes y la estructura del inode son liberados por el subsistema de gestión de memoria del VFS del kernel **únicamente cuando `st_nlink` llega a 0** y todos los file descriptors abiertos (`open(2)`) que apuntan al inode están cerrados.
* **Constraint**: Los hard links no pueden cruzar límites de filesystem porque los números de inode son estrictamente locales para un identificador de montaje VFS (`fsid`) específico. No pueden apuntar a directorios (salvo raras excepciones a nivel de sistema) para prevenir ciclos en la jerarquía del grafo de directorios que rompan los motores de resolución de rutas (`namei(9)`).

### 1.3 Symbolic Links Engine (`symlink(2)`)
Un symbolic link (symlink o soft link) es un objeto de archivo independiente y distinto asignado con su **propio número de inode único** y una máscara de bits de modo de archivo especial (`S_IFLNK`).
* **Content**: El payload de datos almacenado en un symlink es simplemente una cadena de texto de ruta que apunta a un destino target relativo o absoluto.
* **Fast Symlink vs. Slow Symlink Optimization**:
  * **Fast Symlink (Inline)**: Si la longitud de la cadena de texto de la ruta de destino es menor que el espacio del array de punteros a datos internos del inode (por ejemplo, $< 60$ bytes en UFS2), el kernel almacena la cadena de texto de la ruta directamente dentro de la propia estructura del inode (`i_shortlink`). Esto evita asignar bloques de datos de disco adicionales, lo que resulta en `st_blocks == 0`.
  * **Slow Symlink (Allocated)**: Si la ruta de destino excede el límite inline, se asignan uno o más bloques de datos dedicados para contener la cadena de texto de destino, incrementando `st_blocks > 0`.
* **Path Resolution**: Cuando el `namei(9)` del kernel encuentra un objeto `S_IFLNK` durante la búsqueda de ruta, lee la cadena de texto de la ruta almacenada, reemplaza el componente del enlace y reinicia la resolución de ruta hasta un límite de recursión definido por el sistema (`MAXSYMLINKS`, típicamente 32 en FreeBSD).

### 1.4 Production Use Cases: Atomic Blue/Green Deployments
En clusters web empresariales de FreeBSD / SRE, los symbolic links permiten **despliegues de aplicaciones sin tiempo de inactividad (zero-downtime)**. Al apuntar el symlink del document root de un servidor web estático (`/var/www/current`) a un nuevo directorio de release de build (`/var/www/releases/20260806_v2`), los microservicios se pueden actualizar atómicamente utilizando una llamada al sistema atómica `rename(2)` sobre los symlinks, evitando completamente condiciones de lectura parcial de archivos durante el tráfico HTTP en curso.

---

## 2. Technical Comparison & Trade-off Matrix

| Metric / Dimension | Hard Link (`ln target link`) | Relative Symlink (`ln -s target link`) | Absolute Symlink (`ln -s /path/target link`) | Nullfs / Mount Bind (`mount_nullfs`) |
| :--- | :--- | :--- | :--- | :--- |
| **Inode Allocation** | Comparte el inode de destino | Asigna un nuevo inode único | Asigna un nuevo inode único | Reutiliza el nodo VFS de destino a través de la entrada de la tabla de montajes |
| **Cross-Filesystem Support** | **No** (Falla con `EXDEV`) | **Sí** | **Sí** | **Sí** (Monta a través de dispositivos) |
| **Target Type Support** | Solo archivos | Archivos y Directorios | Archivos y Directorios | Directorios y Filesystems |
| **Target Deletion Impact** | Datos retenidos (accesibles vía link) | El link se rompe (Dangling link, `ENOENT`) | El link se rompe (Dangling link, `ENOENT`) | El destino original permanece accesible |
| **Path Relocation Safety** | **Alto**: Mover el link o archivo conserva el mapeo | **Alto**: Portable si el link y el destino se mueven juntos | **Bajo**: Se rompe si la estructura de directorio de nivel superior cambia | **Alto**: La tabla de montajes del kernel maneja el mapeo |
| **Kernel Lookup Overhead (`namei`)** | Resolución directa de inode ($O(1)$) | Reevalúa la ruta de texto ($O(N)$ búsquedas) | Reevalúa la ruta de texto raíz ($O(N)$ búsquedas) | Nodo VFS traducido mediante operaciones de capa |
| **Atomic Replacement Flag** | `ln -f` | `ln -sfn` / `ln -shf` | `ln -sfn` / `ln -shf` | Requiere la secuencia `umount` + `mount` |

---

## 3. Infrastructure & Deployment Manifests

### 3.1 FreeBSD Zero-Downtime Blue/Green Release Engine
El siguiente script de shell para producción demuestra actualizaciones robustas y atómicas de symbolic links en POSIX/BSD, previniendo errores de directorios anidados al reemplazar symlinks que apuntan a directorios.

```sh
#!/bin/sh
# /usr/local/bin/deploy-app.sh
# Production FreeBSD Atomic Symlink Deployment Script
set -eu

APP_ROOT="/var/www/apps/myapp"
RELEASES_DIR="${APP_ROOT}/releases"
CURRENT_LINK="${APP_ROOT}/current"
NEW_RELEASE_ID="$(date -u +'%Y%m%d_%H%M%S')"
TARGET_DIR="${RELEASES_DIR}/${NEW_RELEASE_ID}"
TMP_LINK="${APP_ROOT}/current.tmp.${NEW_RELEASE_ID}"

echo "[INFO] Initializing deployment payload: ${NEW_RELEASE_ID}"
mkdir -p "${TARGET_DIR}"

# Populate new application artifacts
cat << 'EOF' > "${TARGET_DIR}/index.html"
<!DOCTYPE html>
<html>
<head><title>Production Deployment</title></head>
<body><h1>Application Release Active</h1></body>
</html>
EOF

# Ensure target permissions match web server worker context (www:www)
chown -R www:www "${TARGET_DIR}"

echo "[INFO] Creating temporary atomic symlink: ${TMP_LINK} -> ${TARGET_DIR}"
# POSIX / FreeBSD symlink creation targeting directory
ln -s "${TARGET_DIR}" "${TMP_LINK}"

echo "[INFO] Performing atomic link swap via rename(2)"
# BSD rename(2) atomicity guarantees that readers never encounter a missing target
mv -f -h "${TMP_LINK}" "${CURRENT_LINK}"

echo "[SUCCESS] Active deployment link pointing to: $(readlink "${CURRENT_LINK}")"
```

### 3.2 Kubernetes Local Persistent Volume HostPath Manifest
Al montar filesystems locales que contienen symlinks dentro de entornos de ejecución de contenedores, comprender la resolución de symlinks y la aplicación de límites de rutas es vital.

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: bsd-local-storage-pv
  labels:
    type: local
    environment: production
spec:
  capacity:
    storage: 50Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  local:
    path: /mnt/zfs_data/app_storage
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - bsd-node-01.prod.internal
---
apiVersion: v1
kind: Pod
metadata:
  name: nginx-symlink-service
  namespace: production
spec:
  containers:
    - name: nginx-web
      image: nginx:1.25-alpine
      ports:
        - containerPort: 80
      volumeMounts:
        - name: app-volume
          mountPath: /usr/share/nginx/html
          # Note: Symlinks inside the mounted directory pointing outside /usr/share/nginx/html
          # will be rejected by standard web server security controls unless FollowSymLinks is set.
  volumes:
    - name: app-volume
      persistentVolumeClaim:
        claimName: bsd-local-storage-pvc
```

---

## 4. Real CLI Commands & Terminal Outputs ($)

La siguiente sesión de terminal ilustra una ejecución completa del mundo real en un sistema FreeBSD 14.x ejecutando utilidades BSD estándar (`ln`, `ls`, `stat`, `readlink`, `sysctl`, `truss`).

### 4.1 Creating and Inspecting Hard Links

```syslog
$ cd /tmp
$ mkdir -p link_demo && cd link_demo
$ echo "Production Database Secret Payload" > secret.key

$ ls -li secret.key
 1048712 -rw-r--r--  1 root  wheel  35 Aug  6 20:30 secret.key

$ ln secret.key secret.key.hardlink

$ ls -li secret.key*
 1048712 -rw-r--r--  2 root  wheel  35 Aug  6 20:30 secret.key
 1048712 -rw-r--r--  2 root  wheel  35 Aug  6 20:30 secret.key.hardlink

$ stat -f "Inode: %i | HardLinks: %l | Size: %z bytes" secret.key
Inode: 1048712 | HardLinks: 2 | Size: 35 bytes
```

### 4.2 Demonstrating Inline Fast Symlinks vs. Slow Symlinks

```syslog
$ ln -s secret.key short_sym.link
$ ln -s /var/db/system/production/cluster/nodes/node01/data/storage/configuration/very_long_path_target.key long_sym.link

$ ls -li *_sym.link
 1048713 lrwxr-xr-x  1 root  wheel  10 Aug  6 20:32 short_sym.link -> secret.key
 1048714 lrwxr-xr-x  1 root  wheel  86 Aug  6 20:32 long_sym.link -> /var/db/system/production/cluster/nodes/node01/data/storage/configuration/very_long_path_target.key

$ stat -f "Name: %N | Inode: %i | Size: %z | Allocated Blocks: %b" short_sym.link
Name: short_sym.link | Inode: 1048713 | Size: 10 | Allocated Blocks: 0

$ stat -f "Name: %N | Inode: %i | Size: %z | Allocated Blocks: %b" long_sym.link
Name: long_sym.link | Inode: 1048714 | Size: 86 | Allocated Blocks: 2
```

### 4.3 Attempting Cross-Filesystem Hard Link (Handling `EXDEV`)

```syslog
$ df -h /tmp /dev
Filesystem     Size    Used   Avail Capacity  Mounted on
zroot/tmp      100G    1.2M    100G     0%    /tmp
devfs          1.0K    1.0K      0B   100%    /dev

$ ln /tmp/link_demo/secret.key /dev/secret.key.hardlink
ln: /dev/secret.key.hardlink: Cross-device link

$ echo $?
1
```

### 4.4 FreeBSD Directory Symlink Replacement: The `-n` / `-h` Flag Requirement

Al reemplazar un symlink que apunta a un directorio, un `ln -sf` estándar desreferenciará el symlink y colocará un nuevo enlace *dentro* del directorio de destino a menos que se proporcione `-n` (o `-h` en BSD).

```syslog
$ mkdir -p v1_dir v2_dir
$ echo "Version 1" > v1_dir/app.txt
$ echo "Version 2" > v2_dir/app.txt

$ ln -s v1_dir active_dir
$ readlink active_dir
v1_dir

# Incorrect replacement without -n / -h flag:
$ ln -sf v2_dir active_dir
$ ls -la v1_dir/
total 12
drwxr-xr-x  2 root  wheel  3 Aug  6 20:35 .
drwxr-xr-x  5 root  wheel  6 Aug  6 20:35 ..
-rw-r--r--  1 root  wheel 10 Aug  6 20:35 app.txt
lrwxr-xr-x  1 root  wheel  6 Aug  6 20:35 v2_dir -> v2_dir

# Correct replacement using BSD -shf (or -sfn):
$ rm -rf v1_dir/v2_dir
$ ln -shf v2_dir active_dir
$ readlink active_dir
v2_dir
```

### 4.5 Tracing System Calls via `truss` (FreeBSD)

```syslog
$ truss -t symlink,link,unlink,rename ln -shf v1_dir active_dir
symlink("v1_dir","active_dir")                  ERR#17 'File exists'
unlink("active_dir")                            = 0 (0x0)
symlink("v1_dir","active_dir")                  = 0 (0x0)
process exit status=0
```

---

## 5. Verification, Hardening & Failure Diagnostics

### 5.1 System Security: Kernel Symlink & Hardlink Protection Controls
En las plataformas modernas de BSD y Linux, el recorrido de enlaces simbólicos y la creación de enlaces duros en directorios con sticky bit y escritura para todos (`/tmp`, `/var/tmp`) son vectores de ataque comunes para la Escalada de Privilegios y Vulnerabilidades de Symlink (condiciones de carrera TOCTOU / Time-of-Check to Time-of-Use).

```syslog
# Inspecting FreeBSD Security Kernel Constraints via sysctl
$ sysctl security.bsd.hardlink_check_uid security.bsd.hardlink_check_gid
security.bsd.hardlink_check_uid: 1
security.bsd.hardlink_check_gid: 1

# Enabling stricter link protection rules
$ sysctl security.bsd.hardlink_check_uid=1
$ sysctl security.bsd.see_other_uids=0
```

* **`security.bsd.hardlink_check_uid = 1`**: Evita que los usuarios no privilegiados creen hard links a archivos que no poseen, deteniendo ataques dirigidos a binarios del sistema o archivos de registro restringidos.
* **`security.bsd.hardlink_check_gid = 1`**: Restringe la creación de hard links basándose en la coincidencia de propiedad del grupo.

### 5.2 Diagnostic Matrix & Troubleshooting Recipes

#### Issue 1: Dangling / Broken Symbolic Links
* **Symptom**: Las aplicaciones arrojan `ENOENT` (No such file or directory) a pesar de que `ls active.conf` lista el archivo.
* **Root Cause**: El symlink existe, pero su cadena de texto de ruta de destino apunta a un archivo eliminado o inexistente.
* **Diagnostic Command**:
  ```syslog
  $ find -L /var/www/apps -type l
  /var/www/apps/myapp/current.conf -> /var/www/apps/releases/old_build/app.conf
  ```
  *(El flag `-L` le indica a `find` que siga los symbolic links; si falta un destino de enlace, `find -L` evalúa el symlink como roto).*

#### Issue 2: Inode Exhaustion despite Available Disk Space
* **Symptom**: `write failed: No space left on device` (Error `ENOSPC`), pero `df -h` muestra muchos gigabytes disponibles.
* **Root Cause**: Una abundancia de microarchivos o un seguimiento inadecuado de hard links ha agotado los inodes totales disponibles del filesystem.
* **Diagnostic Command**:
  ```syslog
  $ df -i /var
  Filesystem  1K-blocks  Used   Avail Capacity iused IFree %iused Mounted on
  zroot/var    52428800 12400 52416400     0% 327680     0  100%  /var
  ```
* **Resolution**: Localizar directorios que consumen recuentos anormalmente altos de inodes:
  ```syslog
  $ find /var -xdev -type f | awk -F/ '{print $1"/"$2"/"$3}' | sort | uniq -c | sort -nr | head -n 10
  ```

#### Issue 3: `EXDEV` (Cross-device link error)
* **Symptom**: `ln: /mnt/data/file.txt /var/data/file.txt: Cross-device link`.
* **Root Cause**: `ln` intentó crear un hard link que abarca dos montajes VFS o datasets ZFS separados.
* **Resolution**: Reemplazar el comando de hard link por un symbolic link (`ln -s`) o usar un montaje nullfs de BSD (`mount_nullfs`).

---

## 6. References

* **LPI Official BSD Specialist Overview**:  
  https://www.lpi.org/our-certifications/bsd-specialist-overview/
* **FreeBSD Manual Page — `ln(1)` Utility**:  
  https://man.freebsd.org/cgi/man.cgi?query=ln&sektion=1
* **FreeBSD Manual Page — `symlink(7)` Concepts**:  
  https://man.freebsd.org/cgi/man.cgi?query=symlink&sektion=7
* **FreeBSD Manual Page — `link(2)` System Call**:  
  https://man.freebsd.org/cgi/man.cgi?query=link&sektion=2
* **FreeBSD Manual Page — `namei(9)` Path Resolution**:  
  https://man.freebsd.org/cgi/man.cgi?query=namei&sektion=9
* **POSIX IEEE Std 1003.1 — `ln` Specification**:  
  https://pubs.opengroup.org/onlinepubs/9699919799/utilities/ln.html