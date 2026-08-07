# LPI BSD Specialist (Exam 702-100) — Tema 712.5: Crear y Cambiar Enlaces Rígidos y Simbólicos

## Fundamentos de Arquitectura y Mecánica Interna

Comprender la vinculación de archivos en sistemas BSD (FreeBSD, OpenBSD, NetBSD) requiere inspeccionar cómo el Virtual File System (VFS), Unix File System (UFS/FFS) y ZFS manejan la gestión de espacios de nombres, la asignación de inodes y la resolución de punteros.

```
       Directory Entry A               Directory Entry B
    +---------------------+         +---------------------+
    | Name: app.log       |         | Name: app.log.hard  |
    | Inode: 1048580      |         | Inode: 1048580      |
    +----------+----------+         +----------+----------+
               |                               |
               +---------------+---------------+
                               |
                               v
               +-------------------------------+
               | Inode 1048580 (UFS / ZFS dnode)|
               |-------------------------------|
               | Type: REGULAR FILE            |
               | Link Count (st_nlink): 2      |
               | Permissions: -rw-r--r--       |
               | Data Pointers -> [ Blk 98412 ] |
               +-------------------------------+

       Directory Entry C
    +---------------------+
    | Name: app.log.sym   |
    | Inode: 1048581      |
    +----------+----------+
               |
               v
    +------------------------------------------+
    | Inode 1048581                            |
    |------------------------------------------|
    | Type: SYMBOLIC LINK                      |
    | Link Count (st_nlink): 1                 |
    | Target Path String: "app.log"            |
    | Storage: Inode payload (Fast Symlink)    |
    |          or Data Block (Slow Symlink)    |
    +------------------------------------------+
```

### 1. Inodes y Hard Links (`st_nlink`)
- **Mapeo de Entradas de Directorio**: Un directorio en UNIX es simplemente un archivo estructurado que mapea cadenas de nombres de archivos legibles por humanos a números de inode.
- **Topología de Hard Links**: Crear un hard link crea una entrada de directorio adicional que apunta a un número de inode *existente*.
- **Conteo de Referencias**: Los metadatos del inode contienen un campo entero `st_nlink`. Cada hard link incrementa `st_nlink`. Ejecutar `rm` o `unlink(2)` elimina una entrada de directorio y decrementa `st_nlink`. Los bloques de datos físicos se liberan al pool de almacenamiento libre **únicamente** cuando `st_nlink` cae a `0` **y** ningún proceso activo mantiene un descriptor de archivo abierto (`st_refcnt == 0`) para ese inode.
- **Restricciones**:
  - **Limitación entre Puntos de Montaje**: Los hard links no pueden cruzar límites de montaje de sistemas de archivos debido a que los números de inode son estrictamente locales para una instancia/pool de sistema de archivos específico.
  - **Prohibición en Directorios**: La creación de hard links en directorios está restringida para prevenir ciclos estructurales en el grafo de directorios (los cuales rompen algoritmos de recorrido como `pwd` o la limpieza recursiva de directorios).

### 2. Symbolic Links (Soft Links)
- **Inode y Modo Separados**: Un enlace simbólico asigna un inode completamente nuevo con el modo de archivo `S_IFLNK`.
- **Almacenamiento del Objetivo**: El payload de un enlace simbólico es una cadena de ruta que apunta a otra ruta objetivo (relativa o absoluta).
  - **Fast Symlink**: Si la cadena de ruta cabe dentro del espacio del puntero de bloque directo del inode (típicamente $< 60$ bytes en UFS), la cadena de ruta se almacena en línea dentro del propio inode, eliminando una búsqueda de bloque de lectura en disco.
  - **Slow Symlink**: Si la cadena de ruta excede el tamaño del búfer en línea, se asignan bloques de datos externos en el disco.
- **Resolución y Enlaces Huérfanos**: Los symlinks son resueltos en el momento de la búsqueda de la ruta por VFS (`namei`). Si la ruta objetivo se mueve, se renombra o se elimina, el symlink permanece, dando como resultado un **enlace simbólico huérfano (roto)**.

### 3. Compromisos de Flags de BSD (`ln`)

| Flag | Descripción | Matiz de Comportamiento en BSD |
| :--- | :--- | :--- |
| `-s` | Crear un enlace simbólico en lugar de un hard link. | Asigna un nuevo inode que contiene la cadena de la ruta objetivo. |
| `-f` | Forzar la eliminación de archivos de destino existentes. | Desvincula (`unlink`) el nombre objetivo antes de crear el nuevo enlace. |
| `-h` / `-n` | No resolver el objetivo si es un enlace simbólico a un directorio. | **Comportamiento Crítico de BSD**: Al actualizar un symlink que apunta a un directorio, `-h` evita que `ln` ingrese al directorio objetivo y coloque el symlink dentro de él. |
| `-v` | Salida detallada (verbose). | Emite una confirmación `link_name -> target_name` en `stdout`. |
| `-i` | Modo interactivo. | Solicita confirmación antes de sobrescribir archivos de destino existentes. |

---

## Referencias Oficiales

- **LPI BSD Specialist (Exam 702-100)**: [LPI BSD Specialist Overview](https://www.lpi.org/our-certifications/bsd-specialist-overview/)
- **FreeBSD System Manager's Manual**: [`ln(1)` FreeBSD Manual Page](https://man.freebsd.org/cgi/man.cgi?query=ln&sektion=1)
- **FreeBSD Programmer's Manual**: [`symlink(7)` FreeBSD Manual Page](https://man.freebsd.org/cgi/man.cgi?query=symlink&sektion=7)
- **FreeBSD System Calls Manual**: [`link(2)` FreeBSD Manual Page](https://man.freebsd.org/cgi/man.cgi?query=link&sektion=2)

---

## Ejercicios Guiados

### Ejercicio 1: Topología de Inodes y Mecánica de Hard Links

En este ejercicio, investigarás la asignación de inodes, la dinámica del contador de referencias `st_nlink` y los límites de los hard links a través de diferentes sistemas de archivos.

#### Paso 1: Crear un espacio de trabajo aislado e inspeccionar el estado inicial del inode
```bash
mkdir -p /tmp/sre_link_lab && cd /tmp/sre_link_lab
echo "PRIMARY_PAYLOAD_V1" > master_config.conf
stat -f "Inode: %i | Links: %l | Access: %Sp | Size: %z bytes" master_config.conf
```
*Salida esperada:*
```text
Inode: 1402941 | Links: 1 | Access: -rw-r--r-- | Size: 19 bytes
```

#### Paso 2: Crear un hard link y verificar la identidad del inode
```bash
ln master_config.conf hard_config.conf
ls -i1 master_config.conf hard_config.conf
stat -f "File: %N | Inode: %i | Links: %l" master_config.conf hard_config.conf
```
*Salida esperada:*
```text
 1402941 master_config.conf
 1402941 hard_config.conf
File: master_config.conf | Inode: 1402941 | Links: 2
File: hard_config.conf | Inode: 1402941 | Links: 2
```

#### Paso 3: Probar la mutación de datos y la persistencia tras la eliminación
```bash
echo "APPENDED_PRODUCTION_MUTATION" >> hard_config.conf
cat master_config.conf
rm master_config.conf
stat -f "File: %N | Inode: %i | Links: %l" hard_config.conf
cat hard_config.conf
```
*Salida esperada:*
```text
PRIMARY_PAYLOAD_V1
APPENDED_PRODUCTION_MUTATION
File: hard_config.conf | Inode: 1402941 | Links: 1
PRIMARY_PAYLOAD_V1
APPENDED_PRODUCTION_MUTATION
```

#### Paso 4: Intentar la generación de un hard link entre distintos sistemas de archivos
```bash
# Attempt to create a hard link pointing to /tmp from /dev/fd or /var/run (assuming separate mounts)
ln hard_config.conf /var/run/hard_config.conf
```
*Salida esperada:*
```text
ln: /var/run/hard_config.conf: Cross-device link
```

---

#### Preguntas de Verificación — Ejercicio 1
1. ¿Por qué al agregar datos a `hard_config.conf` se modificó el contenido leído desde `master_config.conf`?
2. ¿Qué sucedió con los bloques de datos reales en el disco cuando se ejecutó `rm master_config.conf` en el Paso 3?
3. ¿Por qué `ln` falla con `Cross-device link` al enlazar archivos entre diferentes sistemas de archivos montados?

---

### Ejercicio 2: Enlaces Simbólicos, Objetivos Relativos vs Absolutos y la Mecánica del Flag `-h` en BSD

En este ejercicio, crearás enlaces simbólicos relativos y absolutos, analizarás el almacenamiento de symlinks rápidos vs. lentos, y dominarás el flag BSD `-h` (sin desreferencia) al reemplazar symlinks de directorios.

#### Paso 1: Preparar la estructura de directorios y crear enlaces simbólicos relativos vs absolutos
```bash
mkdir -p /tmp/sre_link_lab/app/v1 /tmp/sre_link_lab/app/v2
echo "ENGINE_V1" > /tmp/sre_link_lab/app/v1/engine.sh
echo "ENGINE_V2" > /tmp/sre_link_lab/app/v2/engine.sh

cd /tmp/sre_link_lab
ln -s app/v1 current_rel
ln -s /tmp/sre_link_lab/app/v1 current_abs

ls -la current_rel current_abs
```
*Salida esperada:*
```text
lrwxr-xr-x  1 root  wheel   6 Aug  6 20:30 current_rel -> app/v1
lrwxr-xr-x  1 root  wheel  23 Aug  6 20:30 current_abs -> /tmp/sre_link_lab/app/v1
```

#### Paso 2: Comparar números de Inode y modos de archivo
```bash
stat -f "Name: %N | Inode: %i | Type/Mode: %HT (%Sp) | Size: %z" app/v1 current_rel
```
*Salida esperada:*
```text
Name: app/v1 | Inode: 1402945 | Type/Mode: Directory (drwxr-xr-x) | Size: 512
Name: current_rel | Inode: 1402948 | Type/Mode: Symbolic Link (lrwxr-xr-x) | Size: 6
```

#### Paso 3: Demostrar la trampa de desreferencia de `ln -sf` en BSD (SIN `-h`)
```bash
# We want to point current_rel to app/v2 instead of app/v1.
# Watch what happens if we omit the -h flag on BSD:
ln -sf app/v2 current_rel
ls -la current_rel
ls -la app/v1
```
*Salida esperada:*
```text
lrwxr-xr-x  1 root  wheel   6 Aug  6 20:30 current_rel -> app/v1
total 2
drwxr-xr-x  2 root  wheel  512 Aug  6 20:31 .
drwxr-xr-x  4 root  wheel  512 Aug  6 20:30 ..
-rw-r--r--  1 root  wheel   10 Aug  6 20:30 engine.sh
lrwxr-xr-x  1 root  wheel    6 Aug  6 20:31 v2 -> app/v2
```

#### Paso 4: Actualizar correctamente un symlink de directorio usando `ln -sfn` o `ln -sfh` en BSD
```bash
# Clean up the nested symlink created inside app/v1 by mistake
rm app/v1/v2

# Now use the -h (no-dereference) flag
ln -sfh app/v2 current_rel
ls -la current_rel
cat current_rel/engine.sh
```
*Salida esperada:*
```text
lrwxr-xr-x  1 root  wheel   6 Aug  6 20:32 current_rel -> app/v2
ENGINE_V2
```

---

#### Preguntas de Verificación — Ejercicio 2
1. En el Paso 3, ¿por qué `ln -sf app/v2 current_rel` creó un symlink dentro de `app/v1/` en lugar de actualizar `current_rel`?
2. ¿Cuál es la función específica de la opción `-h` (o `-n`) en el comando `ln` de BSD cuando se opera sobre enlaces simbólicos?
3. Si `/tmp/sre_link_lab/current_rel` se mueve a `/var/tmp/`, ¿todavía se resolverá correctamente? ¿Y qué sucederá con `current_abs`?

---

### Ejercicio 3: Diagnóstico en Producción y Auditoría de Enlaces Rotos

En este ejercicio, practicarás técnicas avanzadas de diagnóstico SRE para detectar enlaces simbólicos rotos, identificar todos los hard links asociados a un inode crítico e inspeccionar cadenas objetivo de enlaces simbólicos mediante utilidades del sistema.

#### Paso 1: Configuración del entorno — Generando casos de borde en producción
```bash
cd /tmp/sre_link_lab
mkdir -p storage/data
touch storage/data/db.sqlite
ln storage/data/db.sqlite storage/data/db_backup.sqlite
ln -s storage/data/db.sqlite live_db.sq3
ln -s /tmp/sre_link_lab/storage/data/ghost.file broken_link.conf

# Delete the underlying primary database file
rm storage/data/db.sqlite
```

#### Paso 2: Auditar enlaces simbólicos rotos usando `find` y `readlink`
```bash
# Find all broken symbolic links under the current workspace
find -L . -type l -exec ls -la {} +
```
*Salida esperada:*
```text
lrwxr-xr-x  1 root  wheel  35 Aug  6 20:35 ./broken_link.conf -> /tmp/sre_link_lab/storage/data/ghost.file
lrwxr-xr-x  1 root  wheel  19 Aug  6 20:35 ./live_db.sq3 -> storage/data/db.sqlite
```

#### Paso 3: Inspeccionar rutas objetivo puras usando `readlink`
```bash
readlink live_db.sq3 broken_link.conf
```
*Salida esperada:*
```text
storage/data/db.sqlite
/tmp/sre_link_lab/storage/data/ghost.file
```

#### Paso 4: Localizar todos los hard links que coinciden con un inode específico
```bash
# Find inode number of surviving hard link
TARGET_INODE=$(stat -f "%i" storage/data/db_backup.sqlite)
echo "Target Inode: ${TARGET_INODE}"

# Search filesystem by Inode number
find . -inum ${TARGET_INODE} -exec ls -li {} +
```
*Salida esperada:*
```text
Target Inode: 1402952
1402952 -rw-r--r--  1 root  wheel  0 Aug  6 20:35 ./storage/data/db_backup.sqlite
```

---

#### Preguntas de Verificación — Ejercicio 3
1. ¿Por qué `live_db.sq3` aparece como un enlace roto en el Paso 2 aunque `storage/data/db_backup.sqlite` todavía existe con los datos de la base de datos originales exactos?
2. ¿Qué flag en el comando `find` de BSD lo fuerza a seguir enlaces simbólicos durante el recorrido para detectar referencias huérfanas (`-L` vs `-P`)?
3. ¿En qué se diferencia `readlink` de `cat` cuando se invoca sobre un archivo de enlace simbólico?

---

## Soluciones y Explicaciones de Diagnóstico

<details>
<summary>Hacé clic aquí para ver las soluciones y respuestas detalladas</summary>

### Respuestas al Ejercicio 1
1. **Compartición de Inodes**: `master_config.conf` y `hard_config.conf` comparten el **mismo inode exacto** (`1402941`). Un hard link no duplica datos; simplemente crea una segunda entrada de directorio que hace referencia a los mismos punteros de almacenamiento en disco. Cualquier operación de escritura en cualquiera de los nombres de archivo muta los bloques subyacentes referenciados por ese inode compartido.
2. **Contador de Referencias (`st_nlink`)**: Los bloques de datos **no** fueron eliminados. Ejecutar `rm master_config.conf` eliminó la entrada de directorio `master_config.conf` y decrementó el conteo de enlaces del inode (`st_nlink`) de `2` a `1`. Debido a que `st_nlink > 0`, VFS conservó el inode y sus bloques de datos.
3. **Limitación entre Diferentes Dispositivos**: Los índices de inode son locales a una instancia de sistema de archivos específica o dataset de ZFS. El inode `1402941` en `/tmp` (por ejemplo, un `tmpfs` respaldado por memoria o una partición UFS estándar) no tiene contexto ni significado en `/var/run` si `/var/run` está montado en un dispositivo de bloques o dataset independiente. VFS no permite crear un hard link a través de límites de montaje para evitar la corrupción del sistema de archivos y el enrutamiento ambiguo de inodes.

---

### Respuestas al Ejercicio 2
1. **Comportamiento de Desreferencia de Symlinks**: Cuando se ejecutó `ln -sf app/v2 current_rel` sin `-h`, `ln` inspeccionó `current_rel`. Dado que `current_rel` era un symlink que apuntaba a un directorio existente (`app/v1`), `ln` desreferenció `current_rel`, resolvió el directorio objetivo `app/v1` y colocó el nuevo symlink (`v2`) *dentro* de `/tmp/sre_link_lab/app/v1/`.
2. **Opción `-h` / `-n` en BSD**: La opción `-h` (sin desreferencia) le indica a `ln` que trate a la cadena de destino (`current_rel`) como un archivo de enlace simbólico simple en lugar de resolver el directorio al que apunta. Esto permite que `ln -sfh app/v2 current_rel` sobrescriba atómicamente el puntero del symlink existente.
3. **Resolución Relativa vs. Absoluta**:
   - `current_rel` apunta a `app/v1` (una ruta relativa). Si se mueve a `/var/tmp/`, intentará resolver `/var/tmp/app/v1`. Si `/var/tmp/app/v1` no existe, se romperá.
   - `current_abs` apunta a `/tmp/sre_link_lab/app/v1` (una ruta absoluta). Si se mueve a `/var/tmp/`, continuará resolviendo `/tmp/sre_link_lab/app/v1` exitosamente mientras esa ruta absoluta permanezca intacta.

---

### Respuestas al Ejercicio 3
1. **Vinculación de Symlinks Basada en Rutas**: Los enlaces simbólicos apuntan a **nombres de rutas**, no a inodes. `live_db.sq3` almacenaba la cadena `storage/data/db.sqlite`. Cuando se eliminó `storage/data/db.sqlite`, la entrada de directorio que coincidía exactamente con esa ruta en cadena desapareció. Aunque `storage/data/db_backup.sqlite` conserva el inode original y sus datos, el symlink no se puede resolver porque falta la cadena de la ruta objetivo.
2. **Lógica de Recorrido de `find` en BSD**:
   - `-L` (Lógico): Sigue los enlaces simbólicos. Cuando se combina `-type l` con `-L`, `find` evalúa el *objetivo* del enlace. Si el objetivo no existe, `find` trata el enlace como una referencia rota.
   - `-P` (Físico): No sigue los enlaces simbólicos (comportamiento predeterminado). Evalúa el archivo de enlace en sí mismo sin desreferenciar su objetivo.
3. **`readlink` vs. `cat`**:
   - `cat` intenta abrir y leer el archivo objetivo referenciado por el symlink mediante `open(2)` (desreferenciando el enlace). Si el enlace está roto, `cat` emite `No such file or directory`.
   - `readlink` ejecuta la llamada al sistema `readlink(2)` directamente sobre el inode del enlace simbólico para inspeccionar la cadena de texto objetivo almacenada en bruto sin desreferenciar ni resolver la ruta objetivo.

</details>