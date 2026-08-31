# LPIC-1 · Tema 104.2 — Mantener la integridad de los sistemas de archivos

**Examen:** 101-500 (LPIC-1 v5.0) · **Peso:** 3.12
**Superficie de comandos:** `du`, `df`, `fsck`, `e2fsck`, `mke2fs`, `tune2fs`, `dumpe2fs`, `debugfs`, `badblocks`, `xfs_info`, `xfs_repair`, `xfs_db`, `xfs_fsr`, `xfs_admin`

---

## Prerrequisitos del laboratorio y contrato de seguridad

Todos los comandos que siguen se ejecutan contra **dispositivos loop respaldados por archivos sparse**. Nada de este laboratorio toca un dispositivo de bloques real. Leé esto una vez y después no te desvíes nunca: `e2fsck -y`, `debugfs -w`, `badblocks -w` y `xfs_repair -L` son todos capaces de destruir un sistema de archivos de producción en menos de un segundo, y ninguno pregunta dos veces.

```bash
# Debian/Ubuntu
sudo apt-get install -y e2fsprogs xfsprogs util-linux lsof

# RHEL/Fedora/openSUSE
sudo dnf install -y e2fsprogs xfsprogs util-linux lsof
```

Necesitás `root` (todos los ejemplos asumen que sos `root`, o bien antepone `sudo`).

**La única regla que gobierna todo este objetivo:**

> Un verificador de sistema de archivos requiere acceso exclusivo al dispositivo de bloques. Ejecutar `e2fsck` o `xfs_repair` sobre un sistema de archivos **montado y escribible** lo corrompe, porque el kernel mantiene metadatos cacheados que el verificador no puede ver y va a sobrescribir alegremente. La única excepción es un sistema de archivos montado en solo lectura inspeccionado con `e2fsck -n`, y aun eso es un diagnóstico, no una reparación.

---

## Ejercicio 1 — Construir el laboratorio descartable, y la primera trampa de `du`/`df`

### Pasos

1. Creá un directorio de trabajo y dos archivos sparse de respaldo:

   ```bash
   mkdir -p /lab && cd /lab
   truncate -s 512M ext4.img
   truncate -s 1G   xfs.img
   ls -lh /lab
   ```

2. Compará lo que declara la entrada de directorio contra lo que está realmente asignado:

   ```bash
   du -h ext4.img
   du -h --apparent-size ext4.img
   du -h --block-size=1 ext4.img
   ```

   Esperado:

   ```
   0       ext4.img
   512M    ext4.img
   0       ext4.img
   ```

3. Asociá ambas imágenes a dispositivos loop y confirmalo:

   ```bash
   losetup -fP --show /lab/ext4.img     # -> /dev/loop0
   losetup -fP --show /lab/xfs.img      # -> /dev/loop1
   losetup -a
   ```

   > Si tus números de dispositivo difieren, sustituilos en todo lo que sigue. Exportalos para que el resto del laboratorio sea seguro de copiar y pegar:
   > ```bash
   > export EXT4DEV=/dev/loop0 XFSDEV=/dev/loop1
   > ```

4. Creá los sistemas de archivos. El tamaño de bloque se fuerza en ext4 **a propósito** — leé la pregunta después:

   ```bash
   mkfs.ext4 -b 4096 -L LAB-EXT4 $EXT4DEV
   mkfs.xfs  -f -L LAB-XFS $XFSDEV
   ```

5. Montalos:

   ```bash
   mkdir -p /mnt/ext4 /mnt/xfs
   mount $EXT4DEV /mnt/ext4
   mount $XFSDEV  /mnt/xfs
   findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS /mnt/ext4 /mnt/xfs
   lsblk -f /dev/loop0 /dev/loop1
   ```

6. Mirá el mismo sistema de archivos a través de tres lentes distintas:

   ```bash
   df -hT /mnt/ext4
   df -i  /mnt/ext4
   df --output=source,fstype,size,used,avail,pcent,iused,ipcent,target /mnt/ext4
   ```

   Esperado (los números varían según la versión de `e2fsprogs`):

   ```
   Filesystem     Type  Size  Used Avail Use% Mounted on
   /dev/loop0     ext4  486M   24K  452M   1% /mnt/ext4

   Filesystem      Inodes IUsed  IFree IUse% Mounted on
   /dev/loop0       32768    11  32757    1% /mnt/ext4
   ```

7. Volvé a revisar la asignación en el host del archivo de respaldo ahora que existe un sistema de archivos sobre él:

   ```bash
   du -h /lab/ext4.img
   ```

### Preguntas de comprensión — Bloque 1

- **Q1.1** — `truncate -s 512M` produjo un archivo que `du` reporta como `0` pero que `ls -lh` reporta como `512M`. Explicá el mecanismo, e indicá cuál de los dos, `du` o `ls`, te está hablando del *almacenamiento consumido*.
- **Q1.2** — El dispositivo tiene 512 MiB, pero `df -h` reporta un tamaño total de `486M`. ¿A dónde se fueron los ~26 MiB faltantes? Nombrá **dos** consumidores distintos.
- **Q1.3** — `df -h` dice `Avail 452M` mientras que `Size 486M` y `Used 24K`. `486 - 452 ≠ 0.024`. Justificá la diferencia con precisión.
- **Q1.4** — Creaste el sistema de archivos ext4 con `-b 4096`. Si lo hubieras omitido, `mke2fs` habría elegido bloques de 1024 bytes para un dispositivo de 512 MiB. Nombrá una operación posterior en este laboratorio que se rompería si asumieras 4096 y el sistema de archivos usara en realidad 1024.
- **Q1.5** — ¿Cuál de estos tres es seguro ejecutar contra un sistema de archivos montado y en escritura activa: `df -i`, `e2fsck -n`, `xfs_repair -n`?

---

## Ejercicio 2 — Contabilidad del espacio libre: `df` vs `du`, y por qué no coinciden

Este es el incidente de producción más común de todo el objetivo: *"el disco está lleno pero no hay nada"*. Hay cuatro causas raíz distintas. Vas a fabricar tres de ellas.

### Pasos — Causa A: archivos borrados pero todavía abiertos

1. Llená el sistema de archivos ext4 de forma sustancial:

   ```bash
   dd if=/dev/urandom of=/mnt/ext4/payload.bin bs=1M count=300 status=progress
   sync
   df -h /mnt/ext4
   du -sh /mnt/ext4
   ```

   Ambos deberían coincidir en aproximadamente 300 MiB.

2. Hacé que un proceso mantenga el archivo abierto, y después desenlazalo. La propia shell será el proceso infractor:

   ```bash
   exec 9< /mnt/ext4/payload.bin     # fd 9 now references the inode
   rm /mnt/ext4/payload.bin
   ```

3. Preguntale de nuevo a las dos herramientas:

   ```bash
   df -h  /mnt/ext4
   du -sh /mnt/ext4
   ls -la /mnt/ext4
   ```

   Esperado: `df` todavía reporta ~300 MiB usados; `du` reporta ~16 KiB; `ls` no muestra nada.

4. Encontrá al culpable sin adivinar:

   ```bash
   lsof +L1 /mnt/ext4
   lsof -n /mnt/ext4 | grep -i deleted
   ls -l /proc/$$/fd/9
   ```

   Salida esperada de `lsof`:

   ```
   COMMAND  PID USER  FD  TYPE DEVICE  SIZE/OFF NLINK    NODE NAME
   bash    4711 root   9r  REG    7,0 314572800     0      12 /mnt/ext4/payload.bin (deleted)
   ```

5. Liberá el descriptor y observá cómo el espacio vuelve **al instante** — sin reinicio, sin remontaje:

   ```bash
   exec 9<&-
   df -h /mnt/ext4
   ```

### Pasos — Causa B: un punto de montaje que oculta datos debajo

6. Desmontá, plantá un archivo en el punto de montaje vacío y volvé a montar encima:

   ```bash
   umount /mnt/ext4
   dd if=/dev/zero of=/mnt/ext4/hidden-50m.bin bs=1M count=50
   du -sh /mnt/ext4                      # 50M — this is on the ROOT filesystem
   mount $EXT4DEV /mnt/ext4
   du -sh /mnt/ext4                      # ~16K — the 50M is now unreachable
   df -h /               # the 50M is still charged to /
   ```

7. Revelá los datos ensombrecidos sin desmontar nada:

   ```bash
   mkdir -p /mnt/rootview
   mount --bind / /mnt/rootview
   ls -lh /mnt/rootview/mnt/ext4/
   du -sh /mnt/rootview/mnt/ext4/
   ```

8. Limpiá esa causa:

   ```bash
   rm -f /mnt/rootview/mnt/ext4/hidden-50m.bin
   umount /mnt/rootview && rmdir /mnt/rootview
   ```

### Pasos — Causa C: bloques reservados para el superusuario

9. Inspeccioná y después cambiá la reserva:

   ```bash
   tune2fs -l $EXT4DEV | grep -Ei 'block count|reserved block'
   df -h /mnt/ext4
   tune2fs -m 0 $EXT4DEV
   df -h /mnt/ext4                       # Avail jumps by ~24 MiB
   tune2fs -m 5 $EXT4DEV                 # restore the default
   ```

### Pasos — Causa D (solo medición): cruzar límites de sistemas de archivos

10. Contrastá un recorrido que cruza límites contra uno contenido:

    ```bash
    du -sh  /mnt        # descends into /mnt/ext4 and /mnt/xfs
    du -shx /mnt        # stays on the filesystem holding /mnt
    du -h --max-depth=1 /mnt
    ```

11. Un one-liner realista de "quién se comió el disco":

    ```bash
    du -xh --max-depth=1 / 2>/dev/null | sort -rh | head -15
    ```

### Preguntas de comprensión — Bloque 2

- **Q2.1** — En el paso 3, `df` y `du` discreparon en 300 MiB. Explicá *arquitectónicamente* por qué cada herramienta da la respuesta que da. ¿Qué estructura de datos consulta cada una?
- **Q2.2** — En la salida de `lsof +L1` la columna `NLINK` muestra `0`. ¿Qué significa esa columna, y qué selecciona exactamente `+L1`?
- **Q2.3** — Un ingeniero junior propone reiniciar el servidor para recuperar el espacio de un log de 40 GB borrado pero abierto. Dá una alternativa correcta y no disruptiva, y explicá qué le hace al proceso en ejecución.
- **Q2.4** — Después del paso 6, ¿el archivo oculto de 50 MiB consume espacio en el sistema de archivos ext4, en el sistema de archivos raíz, o en ninguno? ¿Qué línea de `df` cambia cuando lo borrás?
- **Q2.5** — `df` muestra `Use% 100%` pero `Avail` no es `0` y las escrituras de usuarios no privilegiados fallan con `ENOSPC`, mientras que root todavía puede escribir. Diagnosticá, y dá el comando que a la vez lo explica y lo arregla.
- **Q2.6** — ¿Por qué `du -x` es obligatorio en un script de monitoreo que recorre `/`, y qué pasaría sin él en un host con un montaje NFS y un volumen de datos de 2 TB?

---

## Ejercicio 3 — Agotamiento de inodos: sistema de archivos lleno con 99 % de espacio libre

### Pasos

1. Construí un sistema de archivos deliberadamente escaso en inodos sobre una segunda partición de la misma imagen. Más simple: creá una imagen chica dedicada.

   ```bash
   truncate -s 64M /lab/inodes.img
   INODEDEV=$(losetup -fP --show /lab/inodes.img)
   echo $INODEDEV
   mkfs.ext4 -b 1024 -i 65536 -F $INODEDEV
   mkdir -p /mnt/inodes && mount $INODEDEV /mnt/inodes
   ```

   `-i 65536` significa *un inodo por cada 65536 bytes de sistema de archivos*, o sea 64 MiB / 64 KiB = **1024 inodos**.

2. Confirmá el presupuesto de inodos antes de hacer nada:

   ```bash
   df -i /mnt/inodes
   tune2fs -l $INODEDEV | grep -Ei 'inode count|free inodes|inode size|blocks per group|inodes per group'
   ```

3. Consumí los inodos con archivos de cero bytes:

   ```bash
   for i in $(seq 1 2000); do : > /mnt/inodes/f$i 2>/dev/null || { echo "FAILED at $i: $(: > /mnt/inodes/f$i 2>&1)"; break; }; done
   ```

   O, para ver el texto real del error:

   ```bash
   touch /mnt/inodes/one-more
   # touch: cannot touch '/mnt/inodes/one-more': No space left on device
   ```

4. Mirá las dos dimensiones lado a lado — esta es la firma diagnóstica:

   ```bash
   df -h /mnt/inodes
   df -i /mnt/inodes
   ```

   Esperado:

   ```
   Filesystem      Size  Used Avail Use% Mounted on
   /dev/loop2       58M  1.1M   53M   2% /mnt/inodes      <-- 2% blocks used

   Filesystem     Inodes IUsed IFree IUse% Mounted on
   /dev/loop2       1024  1024     0  100% /mnt/inodes      <-- 100% inodes used
   ```

5. Localizá los directorios responsables, como lo harías en producción:

   ```bash
   du -a --inodes /mnt/inodes 2>/dev/null | sort -rn | head
   # portable fallback, no --inodes support:
   find /mnt/inodes -xdev -printf '%h\n' | sort | uniq -c | sort -rn | head
   ```

6. Fijate en lo único que **no** podés hacer:

   ```bash
   # There is no "grow the inode table" for a mounted ext4 filesystem.
   # resize2fs changes block count, never inode count.
   resize2fs $INODEDEV 60000        # observe: inode count is unchanged
   df -i /mnt/inodes
   ```

7. Recuperá y desarmá este laboratorio:

   ```bash
   rm -f /mnt/inodes/f*
   df -i /mnt/inodes
   umount /mnt/inodes && losetup -d $INODEDEV && rm -f /lab/inodes.img && rmdir /mnt/inodes
   ```

### Preguntas de comprensión — Bloque 3

- **Q3.1** — `write(2)` devolvió `ENOSPC` mientras `df -h` mostraba 2 % de uso de bloques. Explicá por qué el mismo errno cubre dos condiciones de agotamiento estructuralmente distintas.
- **Q3.2** — La cantidad de inodos de ext4 queda fijada en el momento de `mke2fs`. Indicá las dos opciones de `mke2fs` que la controlan y la diferencia entre ellas.
- **Q3.3** — Tu host de spool de correo se queda sin inodos cada trimestre. `resize2fs` no puede ayudar. Enumerá las dos remediaciones reales, e indicá cuál requiere un ciclo de backup/restore.
- **Q3.4** — ¿XFS tiene este modo de falla? Justificá tu respuesta en términos de cómo XFS asigna inodos, y nombrá la perilla de `mkfs.xfs`/`mount` que todavía puede provocar un `ENOSPC` relacionado con inodos.
- **Q3.5** — ¿Por qué `find /mnt -printf '%h\n' | sort | uniq -c | sort -rn` es una mejor primera jugada que `du -sh` cuando sospechás agotamiento de inodos?

---

## Ejercicio 4 — Leer los metadatos de un sistema de archivos ext: `dumpe2fs` y `tune2fs`

### Pasos

1. Volcá solo el superbloque (nunca vuelques los descriptores de grupo de un sistema de archivos grande sin un paginador):

   ```bash
   dumpe2fs -h $EXT4DEV
   ```

   Salida esperada abreviada:

   ```
   dumpe2fs 1.47.0 (5-Feb-2023)
   Filesystem volume name:   LAB-EXT4
   Last mounted on:          /mnt/ext4
   Filesystem UUID:          6b1f0c9a-...-...
   Filesystem magic number:  0xEF53
   Filesystem revision #:    1 (dynamic)
   Filesystem features:      has_journal ext_attr resize_inode dir_index filetype
                             extent 64bit flex_bg sparse_super large_file huge_file
                             dir_nlink extra_isize metadata_csum
   Filesystem state:         clean
   Errors behavior:          Continue
   Inode count:              32768
   Block count:              131072
   Reserved block count:     6553
   Free blocks:              120184
   Free inodes:              32757
   First block:              0
   Block size:               4096
   Blocks per group:         32768
   Inodes per group:         8192
   Inode size:               256
   Mount count:              3
   Maximum mount count:      -1
   Last checked:             Tue Aug 25 10:11:12 2026
   Check interval:           0 (<none>)
   Journal inode:            8
   Checksum type:            crc32c
   ```

2. Obtené el mismo superbloque con la otra herramienta y compará ambas vistas con `diff`:

   ```bash
   tune2fs -l $EXT4DEV | head -40
   diff <(dumpe2fs -h $EXT4DEV 2>/dev/null) <(tune2fs -l $EXT4DEV 2>/dev/null)
   ```

3. Ahora volcá la disposición de los grupos de bloques, que `tune2fs` no te puede mostrar:

   ```bash
   dumpe2fs $EXT4DEV | grep -E '^Group|Backup superblock|Block bitmap|Inode table' | head -30
   ```

   Esperado:

   ```
   Group 0: (Blocks 0-32767) csum 0x1a2b [ITABLE_ZEROED]
     Primary superblock at 0, Group descriptors at 1-1
     Block bitmap at 65 (+65)
     Inode table at 69-580 (+69)
   Group 1: (Blocks 32768-65535) csum 0x3c4d [INODE_UNINIT, ...]
     Backup superblock at 32768, Group descriptors at 32769-32769
   ...
   Group 3: (Blocks 98304-131071) csum 0x5e6f [...]
     Backup superblock at 98304, Group descriptors at 98305-98305
   ```

4. Preguntale a `mke2fs` dónde *estarían* los respaldos, sin escribir nada. Memorizá este truco — es la forma más rápida de recuperar un superbloque destruido:

   ```bash
   mke2fs -n -b 4096 $EXT4DEV
   ```

   ```
   Creating filesystem with 131072 4k blocks and 32768 inodes
   Superblock backups stored on blocks:
           32768, 98304
   ```

5. Cambiá los parámetros ajustables y observá cada uno en `dumpe2fs -h`:

   ```bash
   tune2fs -L PROD-DATA          $EXT4DEV
   tune2fs -c 25 -i 1m           $EXT4DEV      # 25 mounts OR 1 month
   tune2fs -e remount-ro         $EXT4DEV      # panic | remount-ro | continue
   tune2fs -m 1                  $EXT4DEV
   dumpe2fs -h $EXT4DEV | grep -Ei 'volume name|maximum mount|check interval|errors behavior|reserved block count'
   ```

6. Simulá una verificación vencida sin esperar un mes:

   ```bash
   tune2fs -C 26 $EXT4DEV                      # set the mount counter past the max
   dumpe2fs -h $EXT4DEV | grep -i 'mount count'
   umount /mnt/ext4
   fsck -a $EXT4DEV ; echo "exit=$?"
   ```

   Esperado:

   ```
   fsck from util-linux 2.38.1
   PROD-DATA has gone 26 mounts without being checked, check forced.
   PROD-DATA: 11/32768 files (0.0% non-contiguous), 12345/131072 blocks
   exit=0
   ```

7. Restaurá el comportamiento por defecto de la distribución y volvé a montar:

   ```bash
   tune2fs -c -1 -i 0 -C 0 -T now -e continue -m 5 -L LAB-EXT4 $EXT4DEV
   dumpe2fs -h $EXT4DEV | grep -Ei 'maximum mount|check interval|last checked|state'
   mount $EXT4DEV /mnt/ext4
   ```

### Preguntas de comprensión — Bloque 4

- **Q4.1** — `dumpe2fs -h` y `tune2fs -l` imprimen una salida casi idéntica. Indicá la diferencia de diseño entre los dos comandos y la única cosa que `dumpe2fs` muestra y `tune2fs` nunca va a mostrar.
- **Q4.2** — Los superbloques de respaldo aparecen en los bloques 32768 y 98304, no en 32768 / 65536 / 98304 / 131072. ¿Qué característica del sistema de archivos causa eso, y cuál es el compromiso que compra?
- **Q4.3** — Convertí "superbloque de respaldo en el bloque 32768" en un desplazamiento en bytes para un sistema de archivos con bloques de 4096 bytes, y después para uno con bloques de 1024 bytes. ¿Por qué le importa esta aritmética a `e2fsck`?
- **Q4.4** — La mayoría de las distribuciones empresariales vienen con `Maximum mount count: -1` y `Check interval: 0`. Argumentá ambos lados: ¿qué riesgo deshabilita eso, y qué problema operativo previene?
- **Q4.5** — `Errors behavior` está en `remount-ro`. Describí qué hace el kernel al detectar corrupción de metadatos bajo esa configuración, y por qué `panic` a veces es la elección correcta para un nodo en clúster.
- **Q4.6** — `tune2fs -C 26` forzó una verificación en el siguiente `fsck -a`. ¿Qué campos del superbloque restablece un `e2fsck` exitoso cuando termina limpiamente?

---

## Ejercicio 5 — `fsck` y `e2fsck`: verificar, reparar, códigos de salida

### Pasos — el frontend contra el backend

1. Establecé quién hace realmente el trabajo:

   ```bash
   umount /mnt/ext4
   fsck -N $EXT4DEV
   ```

   Esperado — fijate en que no se ejecuta nada:

   ```
   fsck from util-linux 2.38.1
   [/usr/sbin/fsck.ext4 (1) -- /dev/loop0] fsck.ext4 /dev/loop0
   ```

   ```bash
   ls -l /usr/sbin/fsck.ext4 /usr/sbin/e2fsck
   ```

2. Ejecutá una verificación genuina y forzada sobre un sistema de archivos limpio y capturá el código de salida:

   ```bash
   e2fsck -f -v $EXT4DEV ; echo "exit=$?"
   ```

   Esperado:

   ```
   Pass 1: Checking inodes, blocks, and sizes
   Pass 2: Checking directory structure
   Pass 3: Checking directory connectivity
   Pass 4: Checking reference counts
   Pass 5: Checking group summary information

            11 inodes used (0.03%, out of 32768)
             0 non-contiguous files (0.0%)
             ...
   exit=0
   ```

3. Demostrá que el verificador rechaza (o debería rechazar) un objetivo montado:

   ```bash
   mount $EXT4DEV /mnt/ext4
   e2fsck -f $EXT4DEV ; echo "exit=$?"
   ```

   Esperado:

   ```
   /dev/loop0 is mounted.
   e2fsck: Cannot continue, aborting.
   exit=8
   ```

4. La única inspección de un sistema de archivos montado que es defendible:

   ```bash
   mount -o remount,ro /mnt/ext4
   e2fsck -fn $EXT4DEV ; echo "exit=$?"
   mount -o remount,rw /mnt/ext4
   ```

### Pasos — fabricar y reparar corrupción real

5. Creá contenido identificable, después desmontá:

   ```bash
   mkdir -p /mnt/ext4/docs
   dd if=/dev/urandom of=/mnt/ext4/docs/report.bin bs=1M count=8
   echo "quarterly numbers" > /mnt/ext4/docs/notes.txt
   ls -i /mnt/ext4/docs/report.bin /mnt/ext4/docs/notes.txt
   sync && umount /mnt/ext4
   ```

   Anotá los números de inodo impresos por `ls -i` (ejemplo: `13` y `14`).

6. **Corrupción A — inodo desvinculado.** Eliminá la entrada de directorio pero dejá el inodo asignado:

   ```bash
   debugfs -w -R "unlink /docs/report.bin" $EXT4DEV
   e2fsck -fn $EXT4DEV ; echo "exit=$?"
   ```

   Esperado:

   ```
   Pass 4: Checking reference counts
   Unattached inode 13
   Connect to /lost+found? no

   Inode 13 ref count is 1, should be 0.  Fix? no
   /dev/loop0: ********** WARNING: Filesystem still has errors **********
   exit=4
   ```

7. Reparalo e inspeccioná el resultado:

   ```bash
   e2fsck -fy $EXT4DEV ; echo "exit=$?"
   mount $EXT4DEV /mnt/ext4
   ls -li /mnt/ext4/lost+found/
   ls -lh /mnt/ext4/lost+found/
   file /mnt/ext4/lost+found/*
   ```

   Esperado: un archivo llamado `#13` de exactamente 8 MiB — los datos sobrevivieron, el *nombre* no.

8. **Corrupción B — divergencia del bitmap de inodos.** Marcá como libre un inodo vivo:

   ```bash
   NOTES_INO=$(ls -i /mnt/ext4/docs/notes.txt | awk '{print $1}')
   echo "notes.txt inode = $NOTES_INO"
   umount /mnt/ext4
   debugfs -w -R "freei <$NOTES_INO>" $EXT4DEV
   e2fsck -fn $EXT4DEV ; echo "exit=$?"
   ```

   Esperado:

   ```
   Pass 5: Checking group summary information
   Inode bitmap differences:  +14
   Fix? no
   exit=4
   ```

   ```bash
   e2fsck -fy $EXT4DEV ; echo "exit=$?"
   e2fsck -f  $EXT4DEV ; echo "exit=$?"      # second run must be silent, exit=0
   ```

9. **Corrupción C — contador de enlaces incorrecto.** Mentí sobre cuántos nombres apuntan a un inodo:

   ```bash
   debugfs -w -R "sif /docs/notes.txt links_count 7" $EXT4DEV
   e2fsck -fy $EXT4DEV ; echo "exit=$?"
   ```

   Esperado:

   ```
   Pass 4: Checking reference counts
   Inode 14 ref count is 7, should be 1.  Fix? yes
   exit=1
   ```

10. Memorizá la máscara de bits de los códigos de salida — se pregunta directamente en el examen y es sobre lo que ramifican los sistemas de init:

    ```bash
    man 8 fsck | sed -n '/EXIT CODE/,/AUTHOR/p'
    ```

    | Valor | Significado |
    |---|---|
    | `0` | Sin errores |
    | `1` | Errores del sistema de archivos corregidos |
    | `2` | Errores corregidos, **el sistema debería reiniciarse** |
    | `4` | Errores del sistema de archivos dejados **sin corregir** |
    | `8` | Error operativo |
    | `16` | Error de uso o de sintaxis |
    | `32` | Verificación cancelada a pedido del usuario |
    | `128`| Error de biblioteca compartida |

    Los valores se **suman** cuando `fsck` verifica varios sistemas de archivos, por ejemplo `5 = 1 + 4`.

### Preguntas de comprensión — Bloque 5

- **Q5.1** — Distinguí `fsck -N` de `e2fsck -n`. Los dos "no cambian nada" — ¿cuál es la diferencia real en lo que hace cada uno?
- **Q5.2** — `e2fsck -fn` devolvió `4` y `e2fsck -fy` devolvió `1`. Interpretá ambos, e indicá cuál debería tratar un script de automatización como un incidente que despierta a alguien.
- **Q5.3** — Un `fsck` en el arranque devuelve `5`. Descomponelo y describí la acción requerida del operador.
- **Q5.4** — ¿Por qué `e2fsck` necesita `-f` sobre un sistema de archivos marcado como `clean`, y qué afirma realmente "clean" sobre los datos en disco?
- **Q5.5** — En el paso 7 el archivo recuperado apareció como `/lost+found/#13`. Explicá, en términos de la separación inodo/dentry, por qué el contenido sobrevivió pero el nombre de archivo no — y por qué `lost+found` debe preasignarse en el momento de `mke2fs`.
- **Q5.6** — `-p` (preen) es lo que usan los sistemas de init, no `-y`. Indicá la diferencia de comportamiento y por qué `-y` en el arranque se considera peligroso.
- **Q5.7** — En el paso 8, a `e2fsck -fy` le siguió inmediatamente un segundo `e2fsck -f`. ¿Por qué esa segunda pasada no es opcional después de cualquier reparación?

---

## Ejercicio 6 — Destrucción del superbloque y recuperación desde un respaldo

Este es el ejercicio de mayor valor del objetivo. Hacelo despacio.

### Pasos

1. Registrá el estado actual para poder verificar la recuperación objetivamente:

   ```bash
   mount $EXT4DEV /mnt/ext4
   mkdir -p /mnt/ext4/critical
   echo "do not lose this" > /mnt/ext4/critical/canary.txt
   md5sum /mnt/ext4/critical/canary.txt
   sync && umount /mnt/ext4
   dumpe2fs -h $EXT4DEV | grep -Ei 'uuid|block size|inode count'
   ```

2. Destruí el superbloque primario. Vive en el **desplazamiento de byte 1024**, mide 1024 bytes y es independiente del tamaño de bloque del sistema de archivos:

   ```bash
   dd if=/dev/zero of=$EXT4DEV bs=1024 seek=1 count=1 conv=notrunc
   sync
   ```

3. Observá la falla exactamente como la reportaría un usuario:

   ```bash
   mount $EXT4DEV /mnt/ext4
   ```

   ```
   mount: /mnt/ext4: wrong fs type, bad option, bad superblock on /dev/loop0,
          missing codepage or helper program, or other error.
   ```

   ```bash
   dmesg | tail -5
   blkid $EXT4DEV        # returns nothing — the identifying magic is gone
   file -s $EXT4DEV
   ```

4. Confirmá que el lector de metadatos está igual de ciego:

   ```bash
   dumpe2fs -h $EXT4DEV ; echo "exit=$?"
   ```

   ```
   dumpe2fs: Bad magic number in super-block while trying to open /dev/loop0
   Couldn't find valid filesystem superblock.
   ```

5. Encontrá las ubicaciones del superbloque de respaldo. El dispositivo es ilegible, así que `dumpe2fs` no te lo puede decir — usá el truco de ejecución en seco del Ejercicio 4:

   ```bash
   mke2fs -n -b 4096 $EXT4DEV
   ```

   > **Crítico:** `-b` debe coincidir con el tamaño de bloque original. Si adivinás mal, `mke2fs -n` imprime las ubicaciones de respaldo equivocadas. Si no lo sabés, probá primero 4096 y después 1024 (`mke2fs -n -b 1024` → respaldos en 8193, 24577, 40961, 57345, 73729).

6. Inspeccioná en solo lectura a través del respaldo **antes** de escribir nada:

   ```bash
   e2fsck -fn -b 32768 -B 4096 $EXT4DEV ; echo "exit=$?"
   ```

   Esperado — un muro de diferencias que se niega a arreglar, terminando en:

   ```
   /dev/loop0: ********** WARNING: Filesystem still has errors **********
   exit=4
   ```

7. Reparalo usando el respaldo. `e2fsck` escribe el superbloque reparado de vuelta en la ubicación primaria automáticamente:

   ```bash
   e2fsck -fy -b 32768 -B 4096 $EXT4DEV ; echo "exit=$?"
   ```

   Esperado:

   ```
   e2fsck 1.47.0 (5-Feb-2023)
   /dev/loop0 was not cleanly unmounted, check forced.
   Pass 1: Checking inodes, blocks, and sizes
   Pass 2: Checking directory structure
   Pass 3: Checking directory connectivity
   Pass 4: Checking reference counts
   Pass 5: Checking group summary information
   Free blocks count wrong for group #0 (...). Fix? yes
   ...
   /dev/loop0: ***** FILE SYSTEM WAS MODIFIED *****
   exit=1
   ```

8. Verificá la reparación de forma objetiva — tres confirmaciones independientes:

   ```bash
   e2fsck -f $EXT4DEV ; echo "exit=$?"          # must be 0
   dumpe2fs -h $EXT4DEV | grep -Ei 'state|uuid'
   blkid $EXT4DEV
   mount $EXT4DEV /mnt/ext4
   md5sum /mnt/ext4/critical/canary.txt         # must match step 1
   ls -l /mnt/ext4/lost+found/
   ```

9. Fijate en la omisión que no es tal: `e2fsck` **no** necesitó `-b` en la segunda corrida, porque el superbloque primario vuelve a ser válido.

### Preguntas de comprensión — Bloque 6

- **Q6.1** — ¿Por qué el superbloque primario está en el desplazamiento de byte 1024 y no en el desplazamiento 0, en todo sistema de archivos ext2/3/4 sin importar el tamaño de bloque?
- **Q6.2** — Te entregan un dispositivo fallado y no conocés su tamaño de bloque. Describí un procedimiento de decisión que use solo `mke2fs -n` y `e2fsck -n` para encontrar un superbloque de respaldo utilizable sin arriesgar más daño.
- **Q6.3** — ¿Qué hace `-B 4096` que `-b 32768` no hace, y cuándo es `-B` genuinamente necesario?
- **Q6.4** — Después de recuperar desde un superbloque de respaldo, `e2fsck` reportó contadores de bloques libres incorrectos para varios grupos. Explicá por qué eso es esperable en lugar de alarmante.
- **Q6.5** — En el paso 6 corriste `-fn` antes de `-fy`. En un incidente real sin respaldos, nombrá un paso adicional que deberías dar entre esos dos, y dá el comando.
- **Q6.6** — `blkid` no devolvió nada en el paso 3 pero funciona en el paso 8. ¿Qué campo está leyendo `blkid`, y qué implica su ausencia para las entradas de `/etc/fstab` escritas como `UUID=...`?

---

## Ejercicio 7 — XFS: un modelo de reparación completamente distinto

### Pasos

1. Leé la geometría. Este es el equivalente XFS de `dumpe2fs -h`:

   ```bash
   xfs_info /mnt/xfs
   ```

   Esperado:

   ```
   meta-data=/dev/loop1             isize=512    agcount=4, agsize=65536 blks
            =                       sectsz=512   attr=2, projid32bit=1
            =                       crc=1        finobt=1, sparse=1, rmapbt=0
            =                       reflink=1    bigtime=1 inobtcount=1
   data     =                       bsize=4096   blocks=262144, imaxpct=25
            =                       sunit=0      swidth=0 blks
   naming   =version 2              bsize=4096   ascii-ci=0, ftype=1
   log      =internal log           bsize=4096   blocks=2560, version=2
            =                       sectsz=512   sunit=0 blks, lazy-count=1
   realtime =none                   extsz=4096   blocks=0, rtextents=0
   ```

2. Descubrí la diferencia cultural más importante de este objetivo:

   ```bash
   ls -l /usr/sbin/fsck.xfs
   file /usr/sbin/fsck.xfs
   cat /usr/sbin/fsck.xfs
   fsck.xfs $XFSDEV ; echo "exit=$?"
   ```

   `fsck.xfs` es un **script de shell que no hace nada y sale con 0**.

3. Intentá reparar un sistema de archivos XFS montado y leé la negativa con atención:

   ```bash
   xfs_repair $XFSDEV ; echo "exit=$?"
   ```

   ```
   xfs_repair: /dev/loop1 contains a mounted filesystem
   xfs_repair: /dev/loop1 contains a mounted and writable filesystem

   fatal error -- couldn't initialize XFS library
   exit=1
   ```

4. Poblalo, y después verificalo como corresponde — offline:

   ```bash
   mkdir -p /mnt/xfs/data
   dd if=/dev/urandom of=/mnt/xfs/data/blob.bin bs=1M count=64
   echo "xfs canary" > /mnt/xfs/data/canary.txt
   md5sum /mnt/xfs/data/canary.txt
   sync && umount /mnt/xfs

   xfs_repair -n $XFSDEV ; echo "exit=$?"
   ```

   Esperado — siete fases con nombre, terminando en:

   ```
   Phase 1 - find and verify superblock...
   Phase 2 - using internal log
           - zero log...
           - scan filesystem freespace and inode maps...
           - found root inode chunk
   Phase 3 - for each AG...
           - scan (but don't clear) agi unlinked lists...
           - process known inodes and perform inode discovery...
   Phase 4 - check for duplicate blocks...
   Phase 5 - No modify flag set, skipping phase.
   Phase 6 - check inode connectivity...
   Phase 7 - verify link counts...
   No modify flag set, skipping filesystem flush and exiting.
   exit=0
   ```

5. Leé el superbloque en disco directamente:

   ```bash
   xfs_db -r -c "sb 0" -c "print" $XFSDEV | head -25
   xfs_db -r -c "sb 0" -c "print magicnum blocksize dblocks agcount agblocks rootino uuid" $XFSDEV
   xfs_db -r -c "sb 1" -c "print magicnum agcount" $XFSDEV     # a secondary superblock
   ```

   El número mágico de XFS es `0x58465342` — ASCII `XFSB`.

6. **Destruí el superbloque primario** (XFS lo pone en el desplazamiento 0, a diferencia de ext4):

   ```bash
   dd if=/dev/zero of=$XFSDEV bs=512 count=1 conv=notrunc
   sync
   mount $XFSDEV /mnt/xfs        # fails
   dmesg | tail -3
   blkid $XFSDEV
   ```

7. Recuperá. `xfs_repair` recorre los grupos de asignación buscando un superbloque secundario, completamente por su cuenta — no hace falta ningún equivalente de `-b`:

   ```bash
   xfs_repair $XFSDEV ; echo "exit=$?"
   ```

   Esperado:

   ```
   Phase 1 - find and verify superblock...
   bad primary superblock - bad magic number !!!

   attempting to find secondary superblock...
   ...found candidate secondary superblock...
   verified secondary superblock...
   writing modified primary superblock
   Phase 2 - using internal log
   ...
   Phase 7 - verify link counts...
   done
   exit=0
   ```

8. Verificá:

   ```bash
   xfs_repair -n $XFSDEV ; echo "exit=$?"
   mount $XFSDEV /mnt/xfs
   md5sum /mnt/xfs/data/canary.txt
   ls -l /mnt/xfs/lost+found 2>/dev/null || echo "no lost+found — XFS creates it only when needed"
   ```

9. Etiquetas y UUID — `xfs_admin` requiere el sistema de archivos **desmontado**:

   ```bash
   umount /mnt/xfs
   xfs_admin -l $XFSDEV            # print label
   xfs_admin -u $XFSDEV            # print UUID
   xfs_admin -L PROD-XFS $XFSDEV
   xfs_admin -U generate $XFSDEV   # new UUID — required after a block-level clone
   xfs_admin -l -u $XFSDEV
   mount $XFSDEV /mnt/xfs
   ```

10. Fragmentación: medí, después reorganizá. `xfs_fsr` es lo opuesto a `xfs_repair` — requiere el sistema de archivos **montado**:

    ```bash
    # Manufacture fragmentation: many interleaved appends
    for i in $(seq 1 40); do
      for f in a b c d; do dd if=/dev/zero of=/mnt/xfs/frag_$f bs=64k count=1 \
        seek=$i conv=notrunc oflag=append status=none 2>/dev/null; done
    done
    sync

    xfs_bmap -vp /mnt/xfs/frag_a          # per-file extent map
    umount /mnt/xfs
    xfs_db -r -c "frag" $XFSDEV
    mount $XFSDEV /mnt/xfs
    xfs_fsr -v /mnt/xfs
    xfs_bmap -vp /mnt/xfs/frag_a          # fewer extents
    ```

    Salida de `xfs_db -c frag` — prestá atención a la última línea, que la herramienta imprime textualmente:

    ```
    actual 187, ideal 44, fragmentation factor 76.47%
    Note, this number is largely meaningless.
    Files on this filesystem average 4.25 extents per file
    ```

11. Dos comandos que vale la pena saber que existen, y uno al que hay que temerle:

    ```bash
    xfs_freeze -f /mnt/xfs        # quiesce for a consistent snapshot
    xfs_freeze -u /mnt/xfs        # thaw — ALWAYS pair these

    umount /mnt/xfs
    xfs_metadump -o $XFSDEV /lab/xfs-meta.dump    # metadata-only image for support
    ls -lh /lab/xfs-meta.dump

    # xfs_repair -L  <-- ZEROES THE JOURNAL. Unreplayed transactions are lost
    #                    forever. Last resort only, after xfs_metadump, and only
    #                    when mount+umount cannot replay the log.
    mount $XFSDEV /mnt/xfs
    ```

12. Compará los dos ecosistemas lado a lado:

    ```bash
    xfs_growfs /mnt/xfs -D 300000   # XFS grows online...
    # ...and can never shrink. There is no xfs_shrinkfs.
    resize2fs $EXT4DEV 100000       # ext4 shrinks — but only when unmounted
    ```

### Preguntas de comprensión — Bloque 7

- **Q7.1** — `fsck.xfs` sale con 0 sin hacer nada. Dado eso, ¿qué valor debe tener el sexto campo (`fs_passno`) de una entrada XFS en `/etc/fstab`, y en qué se apoya el diseño de XFS en lugar de una verificación en el arranque?
- **Q7.2** — `xfs_repair` rechaza un sistema de archivos montado, mientras que `xfs_fsr` requiere uno montado. Explicá por qué cada restricción es el diseño correcto para esa herramienta.
- **Q7.3** — XFS se recuperó de un superbloque borrado sin ningún argumento del estilo `-b`, pero ext4 necesitó `-b 32768 -B 4096`. ¿Qué propiedad estructural de XFS hace que la búsqueda sea automática?
- **Q7.4** — Tu sistema de archivos XFS no monta y `dmesg` reporta un log corrupto. Dá el **procedimiento ordenado correcto**, e indicá con precisión en qué paso `xfs_repair -L` se vuelve aceptable.
- **Q7.5** — `xfs_db -c frag` imprime "Note, this number is largely meaningless." ¿Por qué dicen eso los desarrolladores de XFS, y qué deberías medir en su lugar antes de decidir ejecutar `xfs_fsr`?
- **Q7.6** — Clonaste con `dd` un volumen XFS a un segundo LUN y ambos son visibles para el mismo host. Nombrá la falla con la que te vas a encontrar y el comando exacto que la previene.
- **Q7.7** — Contrastá `xfs_growfs` y `resize2fs` en: online vs offline, crecer vs reducir. ¿Cuál de las cuatro combinaciones es imposible?

---

## Ejercicio 8 — Verificación en el arranque, `/etc/fstab` y `badblocks`

### Pasos — el campo `fs_passno`

1. Leé la política actual del sistema en ejecución:

   ```bash
   findmnt --fstab -o SOURCE,TARGET,FSTYPE,OPTIONS,PASSNO
   awk '!/^#/ && NF {printf "%-28s %-16s %-8s pass=%s\n", $1, $2, $3, $6}' /etc/fstab
   ```

2. Agregá los dispositivos del laboratorio a `/etc/fstab` con `noauto` para que un error no pueda romper tu arranque:

   ```bash
   cp /etc/fstab /etc/fstab.bak.$(date +%s)
   cat >> /etc/fstab <<'EOF'
   # --- LPIC-1 104.2 lab (remove after the exercise) ---
   /dev/loop0  /mnt/ext4  ext4  defaults,noauto  0 2
   /dev/loop1  /mnt/xfs   xfs   defaults,noauto  0 0
   EOF
   findmnt --verify --verbose
   ```

3. Mirá el orden que usaría `fsck -A`, sin ejecutar nada:

   ```bash
   fsck -A -N
   fsck -A -N -t ext4
   ```

4. Inspeccioná la maquinaria de systemd que reemplazó al viejo archivo `/forcefsck`:

   ```bash
   systemctl list-units 'systemd-fsck*' --all
   systemctl cat systemd-fsck-root.service | head -25
   cat /proc/cmdline
   ```

   Los parámetros relevantes de la línea de comandos del kernel:

   | Parámetro | Efecto |
   |---|---|
   | `fsck.mode=auto` | Por defecto: verificar según la política del superbloque/passno |
   | `fsck.mode=force` | Forzar una verificación completa de cada sistema de archivos |
   | `fsck.mode=skip` | Omitir toda verificación |
   | `fsck.repair=preen` | Por defecto: `-a`, corregir solo errores inequívocos |
   | `fsck.repair=yes` | `-y`, responder que sí a todo |
   | `fsck.repair=no` | `-n`, solo reportar |

5. Quitá las entradas del laboratorio cuando termines:

   ```bash
   sed -i '/LPIC-1 104.2 lab/,+2d' /etc/fstab
   findmnt --verify
   ```

### Pasos — `badblocks`

6. Ejecutá el escaneo de superficie **seguro, de solo lectura**:

   ```bash
   badblocks -sv -b 4096 $EXT4DEV
   ```

   ```
   Checking blocks 0 to 131071
   Checking for bad blocks (read-only test): done
   Pass completed, 0 bad blocks found. (0/0/0 errors)
   ```

7. La prueba de lectura-escritura no destructiva — requiere el sistema de archivos **desmontado**:

   ```bash
   umount /mnt/ext4
   badblocks -nsv -b 4096 -o /lab/badblocks.txt $EXT4DEV
   wc -l /lab/badblocks.txt
   ```

8. Alimentá una lista de bloques defectuosos al inodo de bloques defectuosos del sistema de archivos, y después dejá que `e2fsck` lo haga por vos:

   ```bash
   e2fsck -l /lab/badblocks.txt $EXT4DEV      # ADD the list
   # e2fsck -L /lab/badblocks.txt $EXT4DEV    # REPLACE the list
   e2fsck -cc $EXT4DEV                        # run badblocks -n internally, then record
   dumpe2fs -b $EXT4DEV                       # print the recorded bad blocks
   mount $EXT4DEV /mnt/ext4
   ```

9. La forma destructiva — **nunca** sobre un dispositivo que contenga datos:

   ```bash
   # badblocks -wsv /dev/sdX      <-- writes patterns over EVERY block. Data is gone.
   ```

10. El contraargumento moderno. Fijate qué piensa el propio disco:

    ```bash
    smartctl -a /dev/sda 2>/dev/null | grep -Ei 'reallocated|pending|uncorrectable|media_wearout|health'
    ```

### Preguntas de comprensión — Bloque 8

- **Q8.1** — Dá el significado de `0`, `1` y `2` en el sexto campo de `fstab`, e indicá cuántos sistemas de archivos de un host deberían llevar `1`.
- **Q8.2** — Dos volúmenes de datos ext4 en **discos físicos separados** llevan ambos `pass=2`. ¿Qué hace `fsck -A` con ellos, y qué cambia si están en el mismo disco?
- **Q8.3** — Alguien pone `fsck.repair=yes fsck.mode=force` de forma permanente en GRUB "por las dudas". Dá dos razones concretas por las que esa es una mala configuración permanente.
- **Q8.4** — Compará `badblocks -n` y `badblocks -w`: qué hace cada uno, cuál destruye datos y cuál requiere el sistema de archivos desmontado.
- **Q8.5** — Ejecutaste `badblocks -b 1024` y le pasaste la salida a `e2fsck -l` sobre un sistema de archivos con bloques de 4096 bytes. ¿Cuál es la consecuencia?
- **Q8.6** — Explicá por qué `badblocks` está en gran medida obsoleto en SSD modernos y en discos SAS/SATA empresariales, y nombrá qué lo reemplazó como señal principal de salud del medio.
- **Q8.7** — Distinguí `e2fsck -l` de `e2fsck -L`. ¿Cuál usarías para limpiar una lista de bloques defectuosos obsoleta heredada de un disco anterior?

---

## Desmontaje y limpieza

```bash
umount /mnt/ext4 /mnt/xfs 2>/dev/null
losetup -d /dev/loop0 /dev/loop1 2>/dev/null
losetup -a
rm -f /lab/ext4.img /lab/xfs.img /lab/badblocks.txt /lab/xfs-meta.dump
rmdir /mnt/ext4 /mnt/xfs /lab 2>/dev/null
grep -n 'LPIC-1 104.2 lab' /etc/fstab   # must return nothing
```

---

<details>
<summary><strong>Respuestas — clic para desplegar</strong></summary>

### Bloque 1 — Construcción del laboratorio y archivos sparse

**A1.1** — `truncate` fija el atributo de *tamaño* del inodo sin asignar ningún bloque de datos; el archivo es **sparse**. `ls -l` imprime `i_size` (el fin lógico del archivo, lo que vería un lector). `du` imprime `st_blocks × 512` (los bloques realmente asignados). **`du` es la herramienta que reporta el almacenamiento consumido.** `du --apparent-size` cambia `du` a la semántica de `ls`, que es por lo que imprimió 512M. Las lecturas de un rango no asignado devuelven ceros desde el kernel sin tocar el disco.

**A1.2** — Al menos dos consumidores, ambos asignados por `mke2fs` antes de que exista dato alguno de usuario:
1. **Metadatos estáticos**: la tabla de inodos (32768 inodos × 256 bytes ≈ 8 MiB), los bitmaps de bloques e inodos, los descriptores de grupo, y el superbloque más sus respaldos.
2. **El journal**: `has_journal` asigna un inodo de journal dedicado, típicamente de 4 a 128 MiB según el tamaño del sistema de archivos (en este sistema de archivos de 512 MiB, aproximadamente 16 MiB).
Además, la característica `resize_inode` reserva bloques de descriptores de grupo para crecimiento online futuro.

**A1.3** — `Size − Used − Avail = 486 − 452 − 0.024 ≈ 34 MiB`, pero `Size` ya excluye los metadatos de A1.2. La brecha restante es el **conteo de bloques reservados**: el 5 % del conteo de bloques (6553 bloques × 4 KiB ≈ 25,6 MiB) está reservado para el UID 0 y se resta de `Avail` pero no de `Size`. `df` reporta deliberadamente `Avail` desde el punto de vista *no privilegiado*.

**A1.4** — La recuperación desde un superbloque de respaldo. `e2fsck -b 32768` solo es correcto para un sistema de archivos con bloques de 4096 bytes. Con bloques de 1024 bytes el primer respaldo está en el bloque **8193**, y pasar 32768 falla directamente o — peor — aterriza sobre datos no relacionados. `mke2fs -n -b <tamaño>` debe ejecutarse con el tamaño de bloque *real* para enumerar los respaldos correctos.

**A1.5** — Solo **`df -i`** es incondicionalmente seguro; es una llamada `statfs(2)` servida por el kernel desde el superbloque en memoria. `e2fsck -n` abre el dispositivo crudo en solo lectura y va a reportar inconsistencias espurias sobre un sistema de archivos montado y en escritura activa, porque los metadatos sucios del kernel todavía no están en disco — es seguro en el sentido de que no escribe, pero su salida no es confiable a menos que el montaje sea de solo lectura. `xfs_repair -n` **se niega a ejecutarse** sobre un sistema de archivos montado, directamente.

---

### Bloque 2 — `df` vs `du`

**A2.1** — Consultan estructuras distintas.
- `df` llama a `statfs(2)`. El kernel responde desde los **contadores de espacio libre del superbloque / grupos de asignación** — la contabilidad autoritativa que el propio sistema de archivos lleva de los bloques asignados.
- `du` recorre el **árbol de directorios**, haciendo `stat(2)` sobre cada entrada alcanzable y sumando `st_blocks`.
Un inodo con `i_links_count == 0` pero con un conteo de referencias de descriptores abiertos distinto de cero sigue estando asignado (así que `df` lo cuenta) pero no es alcanzable desde ninguna entrada de directorio (así que `du` no puede verlo). Los bloques se liberan solo cuando se cierra el último descriptor y el conteo de referencias del inodo llega a cero.

**A2.2** — `NLINK` es el conteo de enlaces duros del inodo, `i_links_count`. `0` significa que ninguna entrada de directorio en todo el sistema de archivos apunta a ese inodo; sobrevive únicamente porque un proceso lo mantiene abierto. `lsof +L1` selecciona **archivos abiertos cuyo conteo de enlaces es menor que 1**, es decir, exactamente el conjunto de borrados-pero-abiertos. Ese es el diagnóstico canónico de un solo comando.

**A2.3** — Cerrá el descriptor sin matar el proceso. Identificalo con `lsof +L1 /ruta`, anotá el PID y el FD, y después:
- **Truncá a través de `/proc`** (el espacio se recupera inmediatamente y el proceso sigue corriendo): `: > /proc/<PID>/fd/<N>` o `truncate -s 0 /proc/<PID>/fd/<N>`.
- O señalá al proceso para que reabra sus logs: `kill -HUP <PID>`, o `systemctl reload <unit>`.
Truncar a través de `/proc/<PID>/fd/N` escribe sobre la misma descripción de archivo abierta, así que los bloques de datos del inodo se liberan mientras el fd sigue siendo válido. Un proceso que agrega con `O_APPEND` continúa correctamente; uno que lleva su propio offset producirá después un archivo sparse — inofensivo. Reiniciar nunca es necesario.

**A2.4** — Consume espacio en el **sistema de archivos raíz**. El archivo se escribió en el directorio `/mnt/ext4` de `/` mientras no había nada montado ahí; montar el dispositivo loop sobre ese directorio oculta la entrada pero no la mueve ni la libera. `df -h /` es la línea que cambia cuando lo borrás — y solo podés borrarlo después de desmontar o vía un bind mount de `/` en otro lado. Por esto el monitoreo basado en `df` sobre `/` puede subir sin causa visible.

**A2.5** — **Bloques reservados.** `df` calcula `Use%` como `used / (used + avail)`, y `avail` excluye la reserva de root — así que el porcentaje se satura en 100 % mientras `Avail` sigue mostrando un valor dentro del rango reservado y solo el UID 0 puede asignar.
Diagnosticá y arreglá con la misma herramienta:
```bash
tune2fs -l /dev/sdaN | grep -Ei 'block count|reserved block count'
tune2fs -m 1 /dev/sdaN        # or: tune2fs -r <blocks>
```
En un volumen de datos dedicado, 1 % (o 0) es apropiado; en `/` y `/var` mantené un par de puntos porcentuales para que root todavía pueda iniciar sesión y syslog todavía pueda escribir durante un incidente.

**A2.6** — `du -x` (`--one-file-system`) detiene el recorrido en los límites de montaje. Sin él, un recorrido de `/` desciende a cada sistema de archivos montado: el volumen de datos de 2 TB se suma al total (haciendo la salida inútil para encontrar qué llenó `/`), y el montaje NFS se recorre por la red — lo que se cuelga indefinidamente si el servidor es inalcanzable, deja el script de monitoreo en sueño ininterrumpible, y puede generar un tráfico enorme de metadatos NFS.

---

### Bloque 3 — Agotamiento de inodos

**A3.1** — `ENOSPC` significa "el asignador no pudo satisfacer el pedido", y un archivo ext4 necesita **dos** recursos independientes: una entrada libre en la tabla de inodos, y bloques de datos libres. `mke2fs` fija el tamaño de la tabla de inodos de forma permanente en el momento del formateo; los dos pozos se agotan de forma independiente. Una carga de trabajo de millones de archivos diminutos (colas de correo, cachés de sesión, almacenes de objetos de Git, capas de contenedores) agota los inodos mucho antes que los bloques. `ENOSPC` no los distingue — solo `df -i` lo hace. **La regla: cada vez que veas `ENOSPC`, ejecutá tanto `df -h` como `df -i`.**

**A3.2** —
- `-N <cantidad>`: fija explícitamente el número absoluto de inodos.
- `-i <bytes-por-inodo>`: fija la *proporción*; `mke2fs` calcula `inode_count = fs_size / bytes_per_inode`. Un `-i` **más chico** produce **más** inodos.
`-i` es la elección habitual porque escala con el dispositivo; `-N` se usa cuando conocés la cantidad exacta de archivos. Ambos son permanentes — la tabla de inodos es un arreglo estático depositado en el momento del formateo, y su tamaño queda horneado en los descriptores de grupo.

**A3.3** —
1. **Reformatear** con una proporción de bytes-por-inodo menor (`mkfs.ext4 -i 8192` o `-N`). Esto **requiere un ciclo de backup/restore** — el sistema de archivos se destruye.
2. **Migrar a XFS** (o mover la carga de trabajo a un sistema de archivos con asignación dinámica de inodos), lo que también requiere backup/restore para el volumen en sí, pero elimina la clase de falla de forma permanente.
Una tercera opción parcial que evita la caída del servicio: reubicar la carga de archivos chicos en un volumen separado y formateado adecuadamente, y montarlo con bind o enlazarlo simbólicamente en su lugar. `resize2fs` *no* es una remediación — cambia solo el conteo de bloques.

**A3.4** — **No, no de esta forma.** XFS asigna inodos **dinámicamente** desde el espacio libre en los grupos de asignación a medida que se crean los archivos, así que no hay una tabla de inodos fija que agotar; la capacidad de inodos está acotada solo por el espacio libre. La perilla que todavía te puede morder es **`imaxpct`** (visible en `xfs_info` como `imaxpct=25`), que limita el porcentaje del sistema de archivos que los inodos pueden ocupar — si lo excedés, la asignación de inodos falla mientras quedan bloques libres. Es ajustable en línea con `xfs_growfs -m <pct>`. Históricamente, los números de inodo de 32 bits en sistemas de archivos muy grandes causaban un `ENOSPC` relacionado cuando los inodos no podían ubicarse por debajo de 1 TiB; la opción de montaje `inode64` (por defecto desde Linux 3.7) resolvió eso.

**A3.5** — `du -sh` suma **bytes**, que es precisamente la dimensión que *no* está agotada — el directorio infractor puede totalizar unos pocos megabytes repartidos en un millón de archivos y quedar último en un `du -sh | sort -rh`. Contar entradas de directorio con `find -printf '%h\n' | sort | uniq -c | sort -rn` (o `du --inodes` donde esté soportado) mide la dimensión que realmente se agotó y apunta directo al directorio infractor.

---

### Bloque 4 — `dumpe2fs` y `tune2fs`

**A4.1** — `dumpe2fs` es una herramienta de **reporte de solo lectura**: vuelca los metadatos del superbloque *y* de los grupos de bloques, y nunca modifica el sistema de archivos. `tune2fs` es una herramienta de **modificación** cuya bandera `-l` casualmente imprime el superbloque como conveniencia. Lo que solo `dumpe2fs` muestra es la **disposición por grupo de bloques** — para cada grupo: rango de bloques, checksum, ubicaciones del superbloque de respaldo y de los descriptores de grupo, bitmap de bloques, bitmap de inodos, extensión de la tabla de inodos, conteos de bloques/inodos libres, y cantidad de directorios. `tune2fs -l` nunca desciende por debajo del superbloque. (Además `dumpe2fs -b` imprime la lista de bloques defectuosos, y `dumpe2fs -f` fuerza la visualización a pesar de banderas de características que no reconoce.)

**A4.2** — La característica **`sparse_super`**. Sin ella, cada grupo de bloques lleva una copia del superbloque y de los descriptores de grupo. Con ella, los respaldos se guardan solo en el grupo 0 y en los grupos que son potencia de 3, 5 o 7 (1, 3, 5, 7, 9, 25, 27, 49, 81, 125, 343, …). El compromiso: **menos copias redundantes** (resiliencia marginalmente menor si se pierden muchos grupos) a cambio de **sustancialmente más espacio utilizable** — en un sistema de archivos de varios terabytes la tabla de descriptores de grupo sola pesa megabytes por grupo, y replicarla en miles de grupos desperdiciaría gigabytes. Está habilitada por defecto en todo sistema de archivos ext2/3/4 moderno.

**A4.3** —
- Bloques de 4096 bytes: `32768 × 4096 = 134.217.728` → desplazamiento de byte **128 MiB**.
- Bloques de 1024 bytes: `8193 × 1024 = 8.389.632` → desplazamiento de byte **~8,0 MiB**.
Importa porque `e2fsck -b <n>` interpreta `<n>` como un **número de bloque**, y el tamaño de bloque que asume viene o del superbloque primario (ahora destruido) o de `-B`. Si `e2fsck` adivina 1024 mientras el sistema de archivos es de 4096, el bloque 32768 resuelve al desplazamiento de byte 32 MiB — datos de archivo arbitrarios, no un superbloque. Equivocar este par es la forma clásica de convertir un sistema de archivos recuperable en uno irrecuperable, que es exactamente por lo que corrés `-n` primero.

**A4.4** —
- **El riesgo que deshabilita:** verificación completa periódica e incondicional. La corrupción silenciosa de metadatos por bugs de firmware, fallas de controladora, RAM defectuosa o bitflips por rayos cósmicos se acumula sin detectarse hasta volverse catastrófica. El journaling protege la **consistencia ante caídas**, no la **corrección** — un journal reproduce un conjunto consistente de transacciones pero no puede notar que un bloque se escribió en el LBA equivocado.
- **El problema que previene:** un `fsck` completo impredecible y de duración no acotada en el arranque sobre un sistema de archivos que se montó limpiamente. En un sistema de archivos de varios terabytes esto puede agregar decenas de minutos a un arranque, y se dispara en el peor momento posible — durante el reinicio de emergencia que todo el mundo ya está mirando. En una flota, las verificaciones basadas en conteo de montajes también causan una "estampida" cuando máquinas construidas desde la misma imagen cruzan el umbral juntas.
La postura moderna: deshabilitar los disparadores por tiempo/conteo, y obtener la garantía desde metadatos con checksum (`metadata_csum`), verificación de extremo a extremo en una capa superior, scrubs de RAID y datos SMART monitoreados.

**A4.5** — Con `remount-ro`, al detectar una inconsistencia de metadatos el kernel llama a `ext4_error()`, registra en `dmesg`, activa el bit `EXT2_ERROR_FS` en el superbloque (de modo que el siguiente arranque fuerce un `fsck`), incrementa `s_error_count` / registra los detalles del primer y último error, y **remonta el sistema de archivos en solo lectura en el lugar**. Los procesos en ejecución reciben `EROFS` en las escrituras; las lecturas continúan. Esto contiene el daño manteniendo la máquina alcanzable para el diagnóstico.
`panic` es correcto para un **nodo en clúster** porque convierte una falla parcial y ambigua en una inequívoca. Un nodo cuyo almacenamiento quedó en solo lectura todavía puede sostener locks del clúster, responder health checks y servir lecturas viejas — un riesgo de *split-brain*. Entrar en pánico hace que el nodo esté instantánea y visiblemente muerto, que es exactamente para lo que están construidas las lógicas de fencing y failover. El mismo razonamiento sustenta `kernel.panic_on_oops` y los watchdogs de hardware en clústeres de alta disponibilidad.

**A4.6** — Una corrida limpia de `e2fsck` restablece:
- `s_lastcheck` → la hora actual (esto es lo que `tune2fs -T now` fija manualmente)
- `s_mnt_count` → `0` (equivalentemente `tune2fs -C 0`)
- `s_state` → `EXT2_VALID_FS`, limpiando el bit `EXT2_ERROR_FS`
- `s_last_orphan` → limpiado, una vez procesada la lista de inodos huérfanos
También reescribe los contadores de bloques/inodos libres y los bitmaps de bloques/inodos para que coincidan con la realidad, y actualiza los superbloques de respaldo.

---

### Bloque 5 — `fsck` / `e2fsck`

**A5.1** —
- **`fsck -N`** (`--dry-run`) es una bandera del *frontend*. `fsck` hace su análisis y ordenamiento de `/etc/fstab`, y después **imprime las líneas de comando de los verificadores que ejecutaría y sale**. Nunca se inicia ningún proceso verificador; el dispositivo nunca se abre.
- **`e2fsck -n`** efectivamente **ejecuta la verificación**, abriendo el dispositivo en solo lectura y respondiendo "no" a cada prompt de reparación. Lee el sistema de archivos completo y produce un informe de daños completo.
Los dos son no destructivos, pero solo `-n` te dice la condición del sistema de archivos. Usá `fsck -N` para auditar la política de arranque; usá `e2fsck -fn` para evaluar el daño.

**A5.2** —
- `4` = "errores del sistema de archivos dejados sin corregir" — esperable de `-n`, que rechaza toda corrección por diseño.
- `1` = "errores del sistema de archivos corregidos" — la reparación tuvo éxito y el sistema de archivos fue modificado.
**`4` es el incidente que despierta a alguien.** Significa que un sistema de archivos está actualmente inconsistente y nada lo arregló — el sistema puede estar corriendo sobre un montaje dañado o en solo lectura. `1` amerita un ticket y una investigación de causa raíz (la corrupción no debería ocurrir), pero la condición inmediata está resuelta. Notá que ninguno es `0`, así que un script escrito como `if fsck ...; then` trata a ambos como falla — compará siempre contra la máscara de bits.

**A5.3** — `5 = 1 + 4`. Del conjunto de sistemas de archivos verificados, **al menos uno se reparó con éxito** y **al menos uno todavía tiene errores sin corregir**. El operador no debe continuar con un arranque normal: identificá qué dispositivo falló (desde el log de arranque o volviendo a correr `e2fsck -fn` por dispositivo), y después ejecutá `e2fsck -f` **de forma interactiva** sobre ese dispositivo con el sistema de archivos desmontado — desde una shell de emergencia o un medio de rescate si se trata del sistema de archivos raíz. Tomá primero una imagen a nivel de bloque (`dd`/`ddrescue`) si los datos son irremplazables. Recién después de que un `e2fsck -f` posterior devuelva `0` debería el sistema volver a servicio.

**A5.4** — `-f` **fuerza** la verificación. Sin él, `e2fsck` ve el bit `EXT2_VALID_FS` en `s_state`, concluye que no hay nada que hacer, y sale con `0` de inmediato.
"Clean" afirma exactamente una cosa: **el sistema de archivos se desmontó de manera ordenada, así que el journal no contiene transacciones sin reproducir.** No dice absolutamente nada sobre si los metadatos son *correctos*. Un sistema de archivos con un bitmap de inodos corrupto, un bloque cruzado o un conteo de enlaces equivocado sigue marcado como "clean" si se desmontó correctamente. Cada corrupción que inyectaste en este ejercicio dejó la bandera limpia — que es por lo que una auditoría o una verificación posterior a un incidente siempre debe pasar `-f`.

**A5.5** — Unix separa el **nombre** del **contenido**. Una entrada de directorio (dentry) es un par `(nombre → número de inodo)` guardado en los bloques de datos del directorio padre; el **inodo** contiene los metadatos y los punteros/extents a los bloques de datos, y **no tiene ningún puntero de vuelta a ningún nombre**. `debugfs unlink` borró solo la dentry. La pasada 4 de `e2fsck` encontró entonces un inodo con conteo de enlaces positivo que ningún directorio referencia — un "inodo desvinculado" — y lo reconectó. Como el nombre existía únicamente en la dentry destruida, `e2fsck` no tiene nada de donde restaurarlo y sintetiza `#<número-de-inodo>`.
`lost+found` debe ser preasignado por `mke2fs` porque `e2fsck` corre contra un sistema de archivos que ya sabe **inconsistente**: crear un directorio requeriría asignar un inodo y bloques y actualizar bitmaps que son de por sí sospechosos. Tener el directorio (y sus bloques de datos) ya presente le permite a `e2fsck` reconectar inodos escribiendo entradas de directorio en un espacio que sabe válido. Por esto también `lost+found` nunca debería borrarse, y por esto se requiere herramental de recuperación (`file`, `md5sum`, `strings`, identificación a nivel de aplicación) para descifrar qué son en realidad los archivos `#N`.

**A5.6** —
- **`-p` (preen)** repara solo errores que pueden arreglarse **sin ninguna posible pérdida de datos y sin juicio del operador** — discrepancias en contadores de espacio libre, divergencia de bitmaps, procesamiento de la lista de inodos huérfanos. Al encontrar cualquier cosa ambigua (inodos desvinculados, bloques cruzados, bloques duplicados) **se detiene de inmediato y sale con 4**, cediendo a un humano.
- **`-y`** responde que sí a **cada** prompt, incluidos los destructivos: limpiar inodos, truncar archivos, borrar entradas de directorio, reconstruir el directorio raíz.
`-y` en el arranque es peligroso porque es desatendido e ilimitado. Un sistema de archivos dañado por un **disco fallando o una controladora inestable** se presenta como basura arbitraria; `-y` lo va a "reparar" limpiando miles de inodos, y descubrís el alcance de la pérdida de datos después del hecho, sin ninguna oportunidad de haber imageneado el dispositivo antes. El trabajo de preen es precisamente trazar la línea entre "seguro de automatizar" y "despertá a alguien".

**A5.7** — Porque `e2fsck` hace **múltiples pasadas sobre estructuras interdependientes**, y una reparación en una pasada tardía puede invalidar una suposición de una anterior. Reconectar un inodo a `lost+found` en la pasada 4, por ejemplo, asigna una entrada de directorio y cambia conteos de enlaces contra los que se computaron la contabilidad de bloques de la pasada 1 y el resumen de bitmaps de la pasada 5. El propio `e2fsck` imprime `***** FILE SYSTEM WAS MODIFIED *****` y, cuando lo considera necesario, `***** REBOOT SYSTEM *****`. **El criterio de finalización no es "la reparación se ejecutó" — es "un `e2fsck -f` posterior no encuentra nada y sale con 0".** Una segunda corrida que todavía reporta errores significa o bien que el daño va más allá de una sola pasada, o bien que el dispositivo subyacente está fallando activamente.

---

### Bloque 6 — Recuperación del superbloque

**A6.1** — Los primeros 1024 bytes del dispositivo están reservados para el **sector de arranque / MBR** (tabla de particiones, código de arranque). Poner el superbloque en el desplazamiento 1024 permite que un sistema de archivos ocupe un dispositivo crudo entero o una partición cuyo inicio coincide con un registro de arranque sin que ambos se sobrescriban. El desplazamiento es una **constante fija en bytes**, independiente del tamaño de bloque — con bloques de 1024 bytes el superbloque es el bloque 1; con bloques de 4096 bytes vive *dentro* del bloque 0, en el byte 1024 de ese bloque. Por esto `dd bs=1024 seek=1 count=1` destruye el superbloque sin tocar los descriptores de grupo (que arrancan en el bloque 1 = desplazamiento 4096 en un sistema de archivos de 4 KiB).

**A6.2** — Un procedimiento seguro, enteramente de solo lectura hasta el último paso:
1. Reuní evidencia primero: `file -s /dev/sdX`, `dmesg`, cualquier salida histórica de `dumpe2fs -h`, y `/etc/fstab` (que puede registrar el tipo). Si existe una tabla de particiones, `blkid`/`lsblk -f` todavía pueden identificar a los vecinos.
2. Enumerá candidatos para el tamaño más probable: `mke2fs -n -b 4096 /dev/sdX` → respaldos en 32768, 98304, …
3. **Probá en solo lectura**: `e2fsck -fn -b 32768 -B 4096 /dev/sdX`. Si el tamaño de bloque es incorrecto, `e2fsck` reporta otro número mágico inválido o una geometría sin sentido; si es correcto, obtenés un informe de daños coherente con conteos de inodos/bloques plausibles.
4. Si falla, repetí con `-b 1024`: `mke2fs -n -b 1024 /dev/sdX` → 8193, 24577, 40961, 57345, 73729; después `e2fsck -fn -b 8193 -B 1024`.
5. Probá respaldos sucesivos (`98304`, después `24577`, …) si el primer candidato está a su vez dañado.
6. Solo una vez que una corrida con `-n` produzca un informe coherente ejecutás el mismo comando con `-y`.
Como cada paso hasta el 5 es de solo lectura, una suposición equivocada no cuesta más que tiempo. En un dispositivo que no podés darte el lujo de perder, imageneálo primero (`ddrescue`) y trabajá sobre la copia.

**A6.3** — `-b <n>` nombra el **número de bloque** del superbloque a usar. `-B <tamaño>` declara el **tamaño de bloque en bytes** que `e2fsck` debe asumir al convertir ese número de bloque en un desplazamiento en bytes.
`-B` es necesario cuando `e2fsck` **no puede inferir el tamaño de bloque**, que es exactamente el caso cuando el superbloque primario — la estructura que lo registra — fue destruido. Sin `-B`, `e2fsck` tantea tamaños plausibles, y una inferencia equivocada hace que `-b 32768` apunte a datos no relacionados. Suministrar ambos elimina la adivinanza. En un sistema de archivos con el superbloque primario intacto, ninguna de las dos banderas hace falta.

**A6.4** — Los **contadores de bloques e inodos libres, y los bitmaps, no son parte de la identidad crítica del superbloque** — son campos de contabilidad actualizados con frecuencia, y el superbloque de respaldo es una foto tomada en el momento de `mke2fs` que nunca se refrescó desde entonces. Toda asignación y liberación posterior al formateo está ausente en él. Así que después de adoptar el respaldo, `e2fsck` encuentra que sus conteos de libres discrepan salvajemente con lo que la pasada 1 calculó recorriendo realmente los inodos y extents. La pasada 5 después reescribe los resúmenes a partir del recorrido autoritativo. Esto es normal y es precisamente para lo que sirve la verificación. Lo que sí sería alarmante es la clase opuesta de mensaje — bloques cruzados, "inode has illegal block", o miles de inodos limpiados — que indica daño bastante más allá del superbloque.

**A6.5** — **Tomá una imagen a nivel de bloque antes de escribir nada.** Una reparación es irreversible; si `e2fsck -y` toma la decisión equivocada no lo podés deshacer, y las herramientas de recuperación forense funcionan muchísimo mejor sobre el estado previo a la reparación.
```bash
ddrescue -f -n /dev/sdX /mnt/rescue/sdX.img /mnt/rescue/sdX.map   # preferred: tolerates read errors
# or, when the device reads cleanly:
dd if=/dev/sdX of=/mnt/rescue/sdX.img bs=4M conv=noerror,sync status=progress
```
Después ejecutá la reparación contra la imagen (asociala con `losetup`) o, si tenés que reparar en el lugar, conservá la imagen como plan B. `e2fsck` también ofrece un archivo de deshacer: `e2fsck -z /mnt/rescue/undo.e2undo -fy /dev/sdX`, reproducible con `e2undo` — más barato que una imagen completa pero cubre solo las escrituras del propio `e2fsck`.

**A6.6** — `blkid` lee el **número mágico del sistema de archivos y los campos identificatorios del superbloque** (UUID, LABEL, TYPE, y para ext4 también `BLOCK_SIZE` y `UUID_SUB`). Tantea un conjunto de desplazamientos conocidos — el desplazamiento 1024 para ext2/3/4 (`0xEF53`), el desplazamiento 0 para XFS (`XFSB`) — y con el superbloque en ceros no hay número mágico, así que no reporta nada.
La implicación es severa: una entrada de `/etc/fstab` escrita como `UUID=...` **no se puede resolver**, porque `/dev/disk/by-uuid/<uuid>` es un enlace simbólico de udev creado exactamente a partir de ese tanteo. En el arranque el nodo de dispositivo simplemente no existe, la unidad `.mount` generada por systemd espera un dispositivo que nunca aparece, y el arranque cae a modo de emergencia después del timeout — con un error sobre el *UUID*, no sobre un superbloque defectuoso, lo que manda a la gente a buscar en el lugar equivocado. Lo mismo aplica a `LABEL=` y a `/dev/disk/by-label/`. También explica por qué `xfs_admin -U generate` importa después de clonar: dos dispositivos exponiendo el mismo UUID hacen ambiguo el enlace `by-uuid`.

---

### Bloque 7 — XFS

**A7.1** — El campo `fs_passno` debe ser **`0`** para XFS. (Un valor distinto de cero simplemente invoca el `fsck.xfs` que no hace nada, así que es inofensivo pero engañoso — ponelo en `0` para que el fstab documente la política real.)
En lugar de un escaneo de consistencia en el arranque, XFS se apoya en **journaling de metadatos con reproducción del log en el momento del montaje**: el kernel reproduce el log interno durante `mount(2)`, restaurando la consistencia transaccional en un tiempo acotado proporcional al tamaño del log en vez de al tamaño del sistema de archivos. Esa propiedad — **tiempo de montaje independiente del tamaño del sistema de archivos** — es un objetivo central del diseño de XFS y la razón por la que se lo elige para volúmenes de varios petabytes, donde una verificación completa al estilo ext tardaría días. `xfs_repair` existe para el daño que el log no puede arreglar, y es una acción explícita, offline, invocada por el operador, nunca automática.

**A7.2** —
- **`xfs_repair` debe estar offline** porque reconstruye metadatos leyendo y escribiendo directamente sobre el dispositivo crudo. Un sistema de archivos montado tiene metadatos sucios en la caché de páginas y transacciones en vuelo en el log que `xfs_repair` no puede ver; repararía una imagen en disco desactualizada, y el kernel después volcaría sus metadatos cacheados (ahora divergentes) por encima de las reparaciones. Ambas vistas son autoconsistentes y mutuamente incompatibles — corrupción garantizada. También necesita un log en reposo para interpretarlo.
- **`xfs_fsr` debe estar online** porque no es una herramienta de reparación en absoluto: desfragmenta asignando un inodo temporal nuevo y contiguo, copiando los extents, y luego realizando un **intercambio atómico de extents** vía el ioctl `XFS_IOC_SWAPEXT`. Ese ioctl es un servicio del kernel — necesita el sistema de archivos vivo para garantizar atomicidad frente a escritores concurrentes, mantener la identidad del archivo (número de inodo, enlaces, descriptores abiertos) y registrar el intercambio en el journal. No hay forma de hacer eso desde el espacio de usuario contra un dispositivo crudo.

**A7.3** — XFS divide el dispositivo en **grupos de asignación** (`agcount=4`, `agblocks=65536` acá), y **cada AG comienza con una copia completa del superbloque** — no un subconjunto disperso como en ext4, y no en ubicaciones que dependen de un tamaño de bloque que ya no podés leer. El superbloque del AG 0 es el primario; los AG 1..n-1 contienen los secundarios. Como cada superbloque secundario **registra la geometría** (blocksize, agblocks, agcount, dblocks, UUID), `xfs_repair` puede escanear el dispositivo buscando el número mágico `XFSB`, validar un candidato contra sus propios campos autodescriptivos y las cabeceras de AG circundantes, y reconstruirlo todo — incluyendo el tamaño de bloque — sin intervención del operador. Los superbloques de respaldo de ext4 también son autodescriptivos, pero primero tenés que *encontrar* uno, y sus ubicaciones son función del tamaño de bloque que registraba el superbloque destruido. De ahí `-b`/`-B`.

**A7.4** — Procedimiento ordenado:
1. **Dejá de escribirle.** No reintentes el montaje repetidamente; revisá `dmesg` en busca del error real y confirmá que el camino de hardware esté sano (`smartctl`, estado de multipath, logs de la controladora). Reparar sobre un dispositivo que falla destruye datos.
2. **Tomá un respaldo de metadatos**, y una imagen completa si los datos son irremplazables:
   ```bash
   xfs_metadump -o /dev/sdX /rescue/sdX.metadump      # small, for analysis and for vendor support
   ddrescue -f -n /dev/sdX /rescue/sdX.img /rescue/sdX.map   # full image, if you can afford the space
   ```
3. **Intentá una reproducción normal del log** — este es el paso que la gente se saltea. Montar y desmontar limpiamente reproduce el log y es el *único* mecanismo que preserva las transacciones que contiene:
   ```bash
   mount /dev/sdX /mnt/x && umount /mnt/x
   ```
   Si monta, desmontá y andá al paso 5.
4. **Diagnosticá en solo lectura**: `xfs_repair -n /dev/sdX`. Si completa con solo inconsistencias ordinarias, andá al paso 5.
5. **Reparación**: `xfs_repair /dev/sdX`, y después verificá con `xfs_repair -n` (debe salir limpio) antes de volver a montar.
6. **`xfs_repair -L` se vuelve aceptable solo acá**: después de que los pasos 1–3 hayan fallado — el sistema de archivos no monta, y el propio `xfs_repair` se niega a continuar y te dice explícitamente que el log está corrupto y no se puede reproducir — y solo una vez que existen los respaldos del paso 2. `-L` **pone el log en ceros**, descartando permanentemente cada transacción que contenía: archivos escritos recientemente, renombramientos y actualizaciones de metadatos se pierden, y los archivos pueden quedar truncados o con contenido viejo. Después de `-L` tenés que ejecutar `xfs_repair` de nuevo, y luego auditar el sistema de archivos (y `lost+found`) contra las expectativas de tu aplicación. Nunca eches mano de `-L` primero porque "la reparación no funcionó".

**A7.5** — El número es una relación entre los **extents reales y el ideal teórico (un extent por archivo)**, y ese ideal carece de sentido para la mayoría de las cargas de trabajo reales. Los archivos que son genuinamente sparse, preasignados con `fallocate`, escritos por bases de datos en trozos de tamaño fijo, o sujetos a compartición `reflink`/CoW, legítimamente tienen muchos extents — y la asignación diferida y el asignador basado en extents de XFS ya producen extents grandes y bien ubicados. Un "factor de fragmentación" alto en semejante sistema de archivos no indica nada sobre el rendimiento, que es por lo que `xfs_db` imprime el descargo por sí solo.
Qué medir en su lugar, antes de decidir ejecutar `xfs_fsr`:
- **Comportamiento real de E/S**: latencia e IOPS desde `iostat -x`, `blktrace`/`blkparse`, o latencia p99 a nivel de aplicación. La fragmentación solo importa si está causando búsquedas que duelen.
- **Conteo de extents por archivo para los archivos que importan**: `xfs_bmap -vp <archivo>`, o `filefrag -v <archivo>`. Un archivo de base de datos de 200 GB en 4 extents está bien; el mismo archivo en 400.000 extents no.
- **Fragmentación del espacio libre**, que es el verdadero motor de la fragmentación futura: `xfs_db -r -c "freesp -s" /dev/sdX`.
Y prestá atención al medio: en **SSD y NVMe no hay penalización por búsqueda**, así que `xfs_fsr` mayormente compra amplificación de escritura y desgaste sin ninguna ganancia. Rara vez vale la pena ejecutarlo en almacenamiento moderno.

**A7.6** — **UUID duplicados.** XFS se niega a montar un sistema de archivos cuyo UUID coincide con uno ya montado, fallando con `wrong fs type, bad option, bad superblock` y una línea de `dmesg` que dice más o menos *"Filesystem has duplicate UUID … can't mount"*. Más allá de la falla de montaje, `/dev/disk/by-uuid/<uuid>` se vuelve ambiguo — udev crea un solo enlace simbólico para dos dispositivos — así que las entradas de `fstab` basadas en `UUID=` pueden montar silenciosamente el volumen *equivocado* entre reinicios. El arreglo, sobre el clon, desmontado:
```bash
xfs_admin -U generate /dev/sdY     # assign a fresh UUID
```
(`-U nil` lo borra, útil para un sistema de archivos que debe poder montarse junto a su original con `-o nouuid` como medida temporal; `mount -o nouuid` saltea la verificación pero **no** arregla la ambigüedad de `by-uuid`, así que tratalo como opción de rescate solamente.) La misma clase de problema aplica a LVM (`vgimportclone`) y a ext4 (`tune2fs -U random`).

**A7.7** —

| | Crecer | Reducir |
|---|---|---|
| **XFS** (`xfs_growfs`) | **Solo online** — el sistema de archivos *debe* estar montado | **Imposible** |
| **ext4** (`resize2fs`) | **Online** (montado) u offline | **Solo offline** — debe estar desmontado |

La combinación imposible es **reducir XFS** — no existe `xfs_shrinkfs` ni existió nunca; la única forma de reducir un volumen XFS es respaldar, `mkfs.xfs` con el tamaño menor, y restaurar. Esta es una decisión de diseño deliberada (reubicar datos fuera de los grupos de asignación altos y reescribir las estructuras de AG es complejo y riesgoso para un sistema de archivos cuyo caso de uso primario son volúmenes muy grandes), y es una consideración genuina al elegir un sistema de archivos para un volumen que podría necesitar reducirse. Notá la asimetría en la fila de "crecer": `xfs_growfs` opera sobre un **punto de montaje** y requiere el sistema de archivos montado, mientras que `resize2fs` opera sobre un **dispositivo** y funciona de cualquiera de las dos formas — una trampa común de examen.

---

### Bloque 8 — Verificación en el arranque y `badblocks`

**A8.1** —
- **`0`** — no verificar este sistema de archivos en el arranque. Correcto para XFS, btrfs, ZFS, swap, sistemas de archivos de red, `tmpfs`, y cualquier sistema de archivos cuyo verificador no tenga sentido en el arranque.
- **`1`** — verificar **primero**, antes de que se monte cualquier otra cosa. Reservado para el **sistema de archivos raíz**.
- **`2`** — verificar después de todos los sistemas de archivos de pasada 1, en una segunda fase.
**Exactamente un sistema de archivos por host debería llevar `1`** — el sistema de archivos raíz. Asignar `1` a más de uno los serializa innecesariamente y tergiversa el ordenamiento del arranque.

**A8.2** — `fsck -A` verifica primero todas las entradas de pasada 1, y después procesa las de pasada 2. Dentro del mismo número de pasada, **paraleliza entre dispositivos físicos distintos** — inspecciona las rutas de dispositivo y corre un verificador por husillo de forma concurrente (este es el comportamiento `-P`/paralelo; `fsck` deliberadamente no corre dos verificadores sobre el mismo disco a la vez). Así que dos volúmenes en **discos separados** se verifican **simultáneamente**, reduciendo aproximadamente a la mitad el tiempo de reloj.
Si están en el **mismo disco** (dos particiones de un dispositivo), `fsck` los **serializa**. Eso es intencional: dos escaneos completos de metadatos compitiendo por un mismo juego de cabezales producen una agitación patológica de búsquedas y son más lentos que ejecutarlos uno detrás del otro. En SSD la penalización desaparece en gran medida, pero `fsck` conserva el comportamiento conservador. (`fsck -s` fuerza la serialización en todos lados; útil cuando los verificadores son interactivos, para que sus prompts no se intercalen.)

**A8.3** — Dos razones concretas:
1. **`fsck.mode=force` vuelve el tiempo de arranque ilimitado e impredecible.** Cada sistema de archivos recibe un escaneo completo de metadatos en cada arranque, sin importar si se desmontó limpiamente. En un host con volúmenes ext4 de varios terabytes esto convierte un arranque de 40 segundos en decenas de minutos — durante una caída, cuando el objetivo de tiempo de recuperación es lo que todo el mundo está midiendo. También anula el propósito entero del journaling, cuya propuesta de valor es precisamente que un journal limpio hace innecesario el escaneo.
2. **`fsck.repair=yes` saca al humano de las decisiones destructivas, permanentemente.** Es `-y`: cada prompt respondido que sí, incluyendo "limpiar este inodo", "truncar este archivo", "borrar esta entrada de directorio". Cuando la causa subyacente es un **disco fallando o una controladora inestable** en lugar de una caída limpia, el sistema de archivos se presenta como basura arbitraria y `-y` va a destruir silenciosamente grandes cantidades de datos recuperables antes de que nadie vea una consola. Y entonces no hay imagen previa a la reparación a la cual volver. El valor por defecto `fsck.repair=preen` existe exactamente para detenerse en el punto donde se requiere juicio.
Ambas banderas son legítimas como intervenciones **de una sola vez** — editá la entrada de GRUB con `e` para un único arranque, o usá `fsck.mode=force` de systemd una vez después de sospechar corrupción. Como configuración permanente, cambian un costo real y frecuente por un beneficio raro e hipotético.

**A8.4** —

| | `badblocks -n` | `badblocks -w` |
|---|---|---|
| Nombre | prueba de lectura-escritura no destructiva | prueba en modo escritura destructiva |
| Método | para cada bloque: leer el original → escribir un patrón → releer y comparar → **volver a escribir los datos originales** | escribe los patrones `0xaa`, `0x55`, `0xff`, `0x00` sobre cada bloque y relee cada uno |
| Datos | **preservados** (salvo una caída a mitad de la prueba) | **destruidos, entera e irrecuperablemente** |
| Montaje | **debe estar desmontado** | debe estar desmontado |
| Velocidad | lenta (4 E/S por bloque) | todavía más lenta (4 pasadas completas) |

`-w` destruye datos. Ambos requieren el sistema de archivos desmontado, porque ambos escriben sobre el dispositivo crudo a espaldas del kernel — `badblocks` se niega por defecto si detecta que el dispositivo está montado, y `-f` anula esa verificación (no uses `-f` sobre un sistema de archivos montado). El modo por defecto de solo lectura (`badblocks` sin `-n`/`-w`) es el único seguro sobre un sistema de archivos montado, y aun así compite por E/S.

**A8.5** — La salida de `badblocks` es una lista de **números de bloque en la unidad que se haya especificado con `-b`**. `e2fsck -l` interpreta esa lista en el tamaño de bloque **del sistema de archivos**. Con una salida de `-b 1024` alimentada a un sistema de archivos con bloques de 4096 bytes, cada número está desfasado por un factor de cuatro: el bloque 8192 en la lista significa el desplazamiento de byte 8 MiB, pero `e2fsck` lo registra como bloque 8192 del sistema de archivos = desplazamiento de byte 32 MiB.
La consecuencia es doblemente errónea: los **sectores realmente defectuosos quedan en servicio** (así que el sistema de archivos va a seguir chocando con errores de E/S sobre ellos), y **cuatro veces más espacio perfectamente bueno se marca como inutilizable** en los desplazamientos equivocados — y si esos desplazamientos contienen actualmente datos vivos, `e2fsck` va a reportar los bloques como en-uso-y-defectuosos y va a ofrecer clonar o limpiar los inodos afectados, es decir, pérdida de datos. Por esto la página del manual insiste en que el `-b` que se le pasa a `badblocks` coincida con el tamaño de bloque del sistema de archivos, y por esto `e2fsck -c` (que invoca `badblocks` por sí mismo con los parámetros correctos) es la ruta más segura.

**A8.6** — Los discos modernos — SSD/NVMe, y también los HDD SAS/SATA empresariales — **remapean los sectores defectuosos interna y transparentemente**. El disco mantiene un pozo de reserva; al detectar una falla de escritura o una lectura irrecuperable, su firmware retira el sector físico y redirige ese LBA a otro lado. Para cuando un LBA devuelve un error al host, el disco ya agotó su propia recuperación. En consecuencia:
- Una lista de `badblocks` es una foto de **LBA**, no del medio físico, y queda obsoleta en el instante en que el disco remapea cualquier cosa.
- En SSD, el FTL implica que un LBA no tiene ninguna ubicación física fija; el mapeo cambia con cada escritura. Marcar LBA como defectuosos carece de sentido.
- Registrar bloques defectuosos en el inodo de bloques defectuosos del sistema de archivos tapa un síntoma mientras el disco sigue degradándose — y en SSD, `badblocks -w` quema un ciclo completo de programado/borrado en todo el dispositivo sin ganancia diagnóstica alguna.

Qué lo reemplazó: **los atributos SMART y los autotests**, leídos vía `smartctl` (smartmontools) y monitoreados por `smartd`. Las señales que importan:
- `Reallocated_Sector_Ct` / `Reallocated_Event_Count` — sectores ya retirados
- `Current_Pending_Sector` — sectores que fallaron al leerse y esperan reasignación; el predictor individual más fuerte de una falla inminente
- `Offline_Uncorrectable` / `Reported_Uncorrect`
- Específicos de SSD: `Media_Wearout_Indicator`, `Percentage_Used`, `Available_Spare` (NVMe), `Wear_Leveling_Count`
- `smartctl -t long /dev/sdX` para un autotest completo de superficie realizado **por el propio disco**, más `smartctl -l selftest` y `-l error` para el historial.
Junto a SMART, las respuestas modernas a la integridad del medio son los **metadatos con checksum** (`metadata_csum` en ext4, CRC en XFS), los sistemas de archivos con **checksum de datos completos** (btrfs, ZFS), y los **scrubs de RAID** — todos los cuales detectan corrupción que un escaneo de errores de lectura no puede, porque atrapan datos que vuelven *exitosamente pero mal*.

**A8.7** —
- **`e2fsck -l <archivo>`** — **agrega** los bloques listados en `<archivo>` al inodo de bloques defectuosos existente del sistema de archivos (inodo 1). La lista vieja se preserva y las entradas nuevas se fusionan.
- **`e2fsck -L <archivo>`** — **reemplaza** la lista de bloques defectuosos por completo con el contenido de `<archivo>`. La lista previa se descarta.
Para limpiar una **lista de bloques defectuosos obsoleta heredada de un disco anterior** (por ejemplo después de restaurar una imagen sobre hardware nuevo, o después de reemplazar una controladora), usá **`-L` con un archivo vacío**:
```bash
: > /tmp/empty
e2fsck -L /tmp/empty /dev/sdX
dumpe2fs -b /dev/sdX          # verify: the list is now empty
```
Dejar una lista obsoleta en su lugar retiene permanentemente esos bloques fuera del asignador sobre un medio donde son perfectamente buenos — una pérdida de capacidad pequeña pero real, y una fuente de confusión para cualquiera que después diagnostique el volumen. Regla mnemotécnica: **`-l` minúscula = agregar a la lista, `-L` mayúscula = "Lay down" una lista nueva.**

</details>

---

## Fuentes oficiales

- LPI — Objetivos del examen 101-500, Tema 104.2: <https://www.lpi.org/our-certifications/exam-101-objectives/>
- Kernel de Linux — documentación del sistema de archivos ext4: <https://www.kernel.org/doc/html/latest/filesystems/ext4/index.html>
- Kernel de Linux — guía de administración de ext4: <https://docs.kernel.org/admin-guide/ext4.html>
- Kernel de Linux — documentación del sistema de archivos XFS: <https://www.kernel.org/doc/html/latest/admin-guide/xfs.html>
- `e2fsck(8)`: <https://man7.org/linux/man-pages/man8/e2fsck.8.html>
- `fsck(8)`: <https://man7.org/linux/man-pages/man8/fsck.8.html>
- `mke2fs(8)`: <https://man7.org/linux/man-pages/man8/mke2fs.8.html>
- `tune2fs(8)`: <https://man7.org/linux/man-pages/man8/tune2fs.8.html>
- `dumpe2fs(8)`: <https://man7.org/linux/man-pages/man8/dumpe2fs.8.html>
- `debugfs(8)`: <https://man7.org/linux/man-pages/man8/debugfs.8.html>
- `badblocks(8)`: <https://man7.org/linux/man-pages/man8/badblocks.8.html>
- `df(1)`: <https://man7.org/linux/man-pages/man1/df.1.html>
- `du(1)`: <https://man7.org/linux/man-pages/man1/du.1.html>
- `fstab(5)`: <https://man7.org/linux/man-pages/man5/fstab.5.html>
- `systemd-fsck@.service(8)`: <https://man7.org/linux/man-pages/man8/systemd-fsck@.service.8.html>
- `xfs(5)`: <https://man7.org/linux/man-pages/man5/xfs.5.html>
- `mkfs.xfs(8)`: <https://man7.org/linux/man-pages/man8/mkfs.xfs.8.html>
- `xfs_repair(8)`: <https://man7.org/linux/man-pages/man8/xfs_repair.8.html>
- `xfs_db(8)`: <https://man7.org/linux/man-pages/man8/xfs_db.8.html>
- `xfs_info(8)`: <https://man7.org/linux/man-pages/man8/xfs_info.8.html>
- `xfs_admin(8)`: <https://man7.org/linux/man-pages/man8/xfs_admin.8.html>
- `xfs_fsr(8)`: <https://man7.org/linux/man-pages/man8/xfs_fsr.8.html>
- `xfs_freeze(8)`: <https://man7.org/linux/man-pages/man8/xfs_freeze.8.html>
- Proyecto e2fsprogs: <https://e2fsprogs.sourceforge.net/>
- Proyecto smartmontools: <https://www.smartmontools.org/>