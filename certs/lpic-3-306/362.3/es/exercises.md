# Sistemas de Archivos en Clúster (GFS2 y OCFS2) — Ejercicios Guiados

> **Objetivo 362.3 — Clustered File Systems** (Examen 306-300, v3.0)
> Configurar y mantener sistemas de archivos GFS2 y OCFS2 sobre almacenamiento compartido, incluyendo el Distributed Lock Manager (DLM) subyacente y la integración con el cluster-stack.

Estos ejercicios asumen un **clúster Pacemaker/Corosync de dos nodos** (`node1`, `node2`) que ya está **con quórum y con fencing** (STONITH habilitado). El almacenamiento en bloque compartido se expone de forma idéntica a ambos nodos como `/dev/sdb` (por ejemplo, vía iSCSI, FC, o un disco compartido de hypervisor). Ejecutá cada comando como `root`. Cuando un paso deba ejecutarse en *ambos* nodos, se etiqueta como `[all nodes]`; de lo contrario, ejecutalo en `node1`.

> ⚠️ **El fencing no es opcional acá.** Un sistema de archivos en clúster permite que múltiples kernels escriban los mismos bloques de forma concurrente, coordinados únicamente por el DLM. Si un nodo deja de responder pero su I/O sigue en vuelo, la *única* recuperación segura es cortarlo físicamente (fence/STONITH). Sin un fencing funcional, el DLM bloqueará la recuperación para siempre — el sistema de archivos se cuelga a propósito en vez de corromper tus datos.

---

## Ejercicio 1 — Principios de los sistemas de archivos en clúster y el DLM

**Objetivo:** observar por qué un sistema de archivos de disco compartido necesita bloqueo distribuido, e inspeccionar el DLM que lo provee.

1. Confirmá que el clúster está sano y con quórum antes de tocar el almacenamiento:

   ```bash
   pcs status --full | head -n 20
   corosync-quorumtool -s
   ```

   Esperado (abreviado):

   ```
   Quorum information
   ------------------
   Date:             Wed Aug 12 10:14:02 2026
   Quorum provider:  corosync_votequorum
   Nodes:            2
   Node ID:          1
   Ring ID:          1.2a
   Quorate:          Yes

   Votequorum information
   ----------------------
   Expected votes:   2
   Highest expected: 2
   Total votes:      2
   Quorum:           1
   Flags:            2Node Quorate WaitForAll
   ```

2. Verificá que STONITH está habilitado — el DLM se niega a recuperar un nodo fallido sin él:

   ```bash
   pcs property show stonith-enabled
   pcs stonith status
   ```

3. Cargá e inspeccioná el módulo de kernel del DLM `[all nodes]`:

   ```bash
   modprobe dlm
   lsmod | grep -E '^dlm'
   ```

4. Observá con qué se diferencia fundamentalmente un sistema de archivos de disco compartido. Contrastá un sistema de archivos *de red* (NFS: un solo servidor es dueño de los metadatos) con un sistema de archivos *de clúster de disco compartido* (cada nodo lee/escribe los mismos bloques directamente). Fijate qué capa arbitra el acceso concurrente en cada modelo.

**Preguntas de comprensión (1):**

- **1a.** En un sistema de archivos de clúster de disco compartido como GFS2 u OCFS2, ¿qué componente impide que dos nodos modifiquen los mismos metadatos en disco simultáneamente, y qué significa la sigla DLM?
- **1b.** ¿Por qué debe configurarse STONITH/fencing *antes* de que un sistema de archivos en clúster pueda recuperarse de forma segura de una falla de nodo? ¿Qué le pasa al I/O del sistema de archivos en el nodo sobreviviente si un nodo fallido no puede ser fenced?
- **1c.** Da una razón arquitectónica por la cual un sistema de archivos en clúster **no** escala de la misma forma que un sistema de archivos scale-out/paralelo (p. ej. por qué no desplegarías GFS2 en 100 nodos).

---

## Ejercicio 2 — Construyendo la pila DLM + LVM en clúster en Pacemaker

**Objetivo:** crear los recursos ordenados/clonados que deben existir en cada nodo antes de cualquier montaje de GFS2. El protocolo `lock_dlm` de GFS2 habla con `dlm_controld`; el VG compartido es coordinado por `lvmlockd`.

1. Creá el clon `dlm`. `ocf:pacemaker:controld` inicia `dlm_controld`. `on-fail=fence` es obligatorio — una falla del DLM debe escalar a fencing:

   ```bash
   pcs resource create dlm ocf:pacemaker:controld \
       op monitor interval=30s on-fail=fence \
       clone interleave=true ordered=true
   ```

2. Habilitá el bloqueo de VG compartido `[all nodes]`, luego creá el clon `lvmlockd`:

   ```bash
   # [all nodes] enable the lock daemon in lvm.conf
   lvmconfig --type full global/use_lvmlockd
   sed -i 's/^\(\s*\)use_lvmlockd = 0/\1use_lvmlockd = 1/' /etc/lvm/lvm.conf

   pcs resource create lvmlockd ocf:heartbeat:lvmlockd \
       op monitor interval=30s on-fail=fence \
       clone interleave=true ordered=true
   ```

3. Ordená la pila para que `lvmlockd` inicie *después* de `dlm`, y colocalos juntos para que corran en el mismo nodo:

   ```bash
   pcs constraint order start dlm-clone then lvmlockd-clone
   pcs constraint colocation add lvmlockd-clone with dlm-clone
   ```

4. Creá un grupo de volúmenes **compartido** y un volumen lógico en el disco compartido:

   ```bash
   vgcreate --shared vg_cluster /dev/sdb        # run once, on node1
   ```

   ```bash
   # [all nodes] each node must start the lockspace for the shared VG
   vgchange --lock-start vg_cluster
   ```

   ```bash
   lvcreate --activate sy -L 20G -n lv_gfs2 vg_cluster   # 'sy' = shared active
   ```

5. Confirmá que el DLM ahora conoce el clúster y verificá los lockspaces:

   ```bash
   dlm_tool status
   dlm_tool ls
   ```

   `dlm_tool status` esperado (abreviado):

   ```
   cluster nodeid 1 quorate 1 ring seq 42 42
   daemon now 1837 fence_pid 0
   node 1 M add 4 rem 0 fail 0 fence 0 at 0 0
   node 2 M add 5 rem 0 fail 0 fence 0 at 0 0
   ```

**Preguntas de comprensión (2):**

- **2a.** ¿Por qué se despliegan `dlm` y `lvmlockd` como recursos **clonados** con `interleave=true`, en lugar de como recursos ordinarios de instancia única?
- **2b.** ¿Cuál es el efecto práctico de `lvcreate --activate sy` (activación compartida) frente a la activación exclusiva por defecto, y por qué un sistema de archivos como GFS2 requiere el modo compartido en todos los nodos?
- **2c.** El recurso `dlm` usa `op monitor ... on-fail=fence`. Explicá por qué `on-fail=fence` (en vez de `restart` o `stop`) es la política correcta específicamente para el DLM.

---

## Ejercicio 3 — Creando y montando un sistema de archivos GFS2

**Objetivo:** formatear el LV compartido con `lock_dlm`, montarlo en ambos nodos mediante un recurso `Filesystem` clonado de Pacemaker, y verificar el acceso concurrente.

1. Inspeccioná el nombre del clúster de corosync — la **lock table** de GFS2 debe usarlo exactamente:

   ```bash
   pcs property show cluster-name
   # or:
   grep cluster_name /etc/corosync/corosync.conf
   ```

   Asumí que el clúster se llama `alpha`.

2. Creá el sistema de archivos GFS2. La lock table es `<cluster_name>:<fs_name>`, `-p lock_dlm` selecciona el protocolo de bloqueo distribuido, y `-j 3` preasigna **tres journals** (uno por nodo que montará de forma concurrente, más uno de reserva):

   ```bash
   mkfs.gfs2 -p lock_dlm -t alpha:web -j 3 -J 128 /dev/vg_cluster/lv_gfs2
   ```

   Salida esperada:

   ```
   /dev/vg_cluster/lv_gfs2 is a symbolic link to /dev/dm-3
   This will destroy any data on /dev/dm-3
   Are you sure you want to proceed? [y/n] y
   Device:                    /dev/vg_cluster/lv_gfs2
   Block size:                4096
   Device size:               20.00 GB (5242880 blocks)
   Filesystem size:           20.00 GB (5242878 blocks)
   Journals:                  3
   Journal size:              128MB
   Resource groups:           80
   Locking protocol:          "lock_dlm"
   Lock table:                "alpha:web"
   UUID:                      9b1a2c3d-4e5f-6789-abcd-ef0123456789
   ```

3. Registrá el montaje como un recurso **clonado** de Pacemaker para que se monte en cada nodo, ordenado después de `lvmlockd`:

   ```bash
   pcs resource create web_fs ocf:heartbeat:Filesystem \
       device="/dev/vg_cluster/lv_gfs2" directory="/mnt/web" fstype="gfs2" \
       options="noatime,nodiratime" \
       op monitor interval=10s on-fail=fence \
       clone interleave=true

   pcs constraint order start lvmlockd-clone then web_fs-clone
   pcs constraint colocation add web_fs-clone with lvmlockd-clone
   ```

4. Verificá que está montado en ambos nodos y que el DLM creó un lockspace con el nombre del sistema de archivos:

   ```bash
   mount | grep gfs2
   dlm_tool ls
   cat /proc/mounts | grep /mnt/web
   ```

   `dlm_tool ls` esperado (abreviado):

   ```
   dlm lockspaces
   name          web
   id            0x7e5c3f2a
   flags         0x00000008 fs_reg
   change        member 2 joined 1 remove 0 failed 0 seq 2,2
   members       1 2
   ```

5. Probá la concurrencia: escribí desde `node1`, leé al instante desde `node2`:

   ```bash
   # node1
   echo "written from $(hostname) at $(date)" > /mnt/web/handshake.txt
   ```

   ```bash
   # node2
   cat /mnt/web/handshake.txt
   ```

6. Inspeccioná los tunables en tiempo de ejecución de GFS2 y el estado por montaje bajo sysfs:

   ```bash
   ls /sys/fs/gfs2/alpha:web/
   cat /sys/fs/gfs2/alpha:web/tune/statfs_slow 2>/dev/null
   ```

**Preguntas de comprensión (3):**

- **3a.** La lock table se dio como `alpha:web`. ¿Cuáles son los dos componentes separados por los dos puntos, y qué se rompe — y con qué síntoma — si el primer componente no coincide con el `cluster_name` de Corosync?
- **3b.** Creaste el sistema de archivos con `-j 3` pero el clúster tiene dos nodos. ¿Por qué asignarías deliberadamente más journals que los nodos actuales, y qué comando usarías *más adelante* para agregar un journal sin reformatear?
- **3c.** ¿Por qué se crea el recurso `Filesystem` como un **clon** en vez de un recurso normal, y qué saldría mal si montaras un sistema de archivos GFS2 con `lock_dlm` en un nodo cuyos clones `dlm`/`lvmlockd` no estuvieran corriendo?

---

## Ejercicio 4 — Mantenimiento de GFS2: journals, crecimiento, tuning y reparación

**Objetivo:** hacer crecer el sistema de archivos en línea, agregar un journal para un tercer nodo, ajustar metadatos con `tunegfs2`, y comprender la reparación offline con `fsck.gfs2`.

1. Extendé el LV subyacente, luego hacé crecer GFS2 **en línea** (ejecutá en cualquier nodo único que lo tenga montado):

   ```bash
   lvextend -L +10G /dev/vg_cluster/lv_gfs2
   gfs2_grow /mnt/web
   df -h /mnt/web
   ```

   Salida esperada de `gfs2_grow`:

   ```
   FS: Mount point:             /mnt/web
   FS: Device:                  /dev/dm-3
   FS: Size:                    5242878 (0x4ffffe)
   DEV: Length:                 7864320 (0x780000)
   The file system grew by 10240MB.
   gfs2_grow complete.
   ```

2. Agregá un cuarto journal para que un `node3` recién unido pueda montar (ejecutá en un nodo montado):

   ```bash
   gfs2_jadd -j 1 /mnt/web
   ```

   Esperado:

   ```
   Filesystem: /mnt/web
   Old journals: 3
   New journals: 4
   ```

3. Inspeccioná y modificá campos persistentes del superblock con `tunegfs2` (antes parte de `gfs2_tool`). Listar es seguro en línea; **cambiar** el protocolo/tabla de bloqueo requiere el sistema de archivos **desmontado en todos los nodos**:

   ```bash
   tunegfs2 -l /dev/vg_cluster/lv_gfs2
   ```

   Esperado:

   ```
   tunegfs2 (device /dev/vg_cluster/lv_gfs2)
   File system volume name: alpha:web
   File system UUID: 9b1a2c3d-4e5f-6789-abcd-ef0123456789
   File system magic number: 0x1161970
   Block size: 4096
   Block shift: 12
   Root inode: 65627
   Lock protocol: lock_dlm
   Lock table: alpha:web
   ```

   Para renombrar el sistema de archivos a `alpha:webnew` (solo offline):

   ```bash
   pcs resource disable web_fs        # unmount on all nodes
   tunegfs2 -o locktable=alpha:webnew /dev/vg_cluster/lv_gfs2
   pcs resource enable web_fs
   ```

4. Comprendé la reparación offline. `fsck.gfs2` debe ejecutarse con el sistema de archivos **desmontado en todas partes** — nunca en un volumen montado o medio montado:

   ```bash
   pcs resource disable web_fs                 # unmount on all nodes first
   fsck.gfs2 -y /dev/vg_cluster/lv_gfs2
   pcs resource enable web_fs
   ```

5. Examiná los metadatos en disco para depuración forense con `gfs2_edit` (inspección de solo lectura acá):

   ```bash
   gfs2_edit -p sb /dev/vg_cluster/lv_gfs2        # print the superblock
   gfs2_edit -p journals /dev/vg_cluster/lv_gfs2  # list journal locations
   ```

**Preguntas de comprensión (4):**

- **4a.** Ejecutaste `lvextend` y luego `gfs2_grow`. ¿Por qué son dos pasos en vez de uno, y puede `gfs2_grow` *encoger* un sistema de archivos GFS2? ¿Cuál es el orden correcto de los dos comandos y por qué?
- **4b.** `gfs2_jadd -j 1` se ejecutó mientras el sistema de archivos estaba montado. ¿Por qué agregar un journal es una operación **en línea**, mientras que `fsck.gfs2` debe ejecutarse completamente **offline** en cada nodo?
- **4c.** Un colega ejecutó `fsck.gfs2` en un dispositivo que todavía estaba montado en `node2`. ¿Qué clase de daño arriesga esto, y qué verificación única debería preceder siempre a `fsck.gfs2` en un clúster?

---

## Ejercicio 5 — OCFS2 con la pila de clúster o2cb

**Objetivo:** levantar OCFS2 usando su pila nativa `o2cb` (independiente de Pacemaker), formatearlo y montarlo, luego gestionar los slots de nodos e inspeccionarlo con la familia de herramientas OCFS2.

1. Instalá y cargá las herramientas/módulo de OCFS2 `[all nodes]`:

   ```bash
   modprobe ocfs2
   which mkfs.ocfs2 o2cb o2info mounted.ocfs2 tunefs.ocfs2 debugfs.ocfs2 fsck.ocfs2
   ```

2. Creá `/etc/ocfs2/cluster.conf` **de forma idéntica en ambos nodos** `[all nodes]`. El `name` del nodo debe coincidir con `uname -n`; los valores de `number` deben ser únicos y estables:

   ```ini
   cluster:
           heartbeat_mode = local
           node_count = 2
           name = ocfs2cluster

   node:
           number = 0
           cluster = ocfs2cluster
           ip_port = 7777
           ip_address = 10.0.0.1
           name = node1

   node:
           number = 1
           cluster = ocfs2cluster
           ip_port = 7777
           ip_address = 10.0.0.2
           name = node2
   ```

   > La indentación en `cluster.conf` usa **tabs**, y cada estrofa se termina con una línea en blanco. Un tab o una línea en blanco faltantes hacen que `o2cb` ignore silenciosamente el nodo.

3. Poné en línea la pila o2cb `[all nodes]`:

   ```bash
   o2cb register-cluster ocfs2cluster
   o2cb start-heartbeat ocfs2cluster
   service o2cb online ocfs2cluster        # or: systemctl start o2cb
   o2cb cluster-status
   ```

4. Formateá el dispositivo compartido para OCFS2. `-N 4` preasigna **4 slots de nodos**, `-L` establece la etiqueta, y `-T mail` ajusta para muchos archivos pequeños (alternativas: `datafiles`, `vmstore`):

   ```bash
   mkfs.ocfs2 -N 4 -L web-ocfs2 --cluster-stack=o2cb \
       --cluster-name=ocfs2cluster --fs-features=backup-super,xattr /dev/sdc1
   ```

   Esperado (abreviado):

   ```
   mkfs.ocfs2 1.8.7
   Cluster stack: o2cb
   Cluster name: ocfs2cluster
   Label: web-ocfs2
   Block size: 4096 (12 bits)
   Cluster size: 4096 (12 bits)
   Node slots: 4
   Creating bitmaps: done
   Writing superblock: done
   mkfs.ocfs2 successful
   ```

5. Montá en ambos nodos `[all nodes]` y confirmá el volumen y sus miembros:

   ```bash
   mkdir -p /srv/ocfs2 && mount -t ocfs2 /dev/sdc1 /srv/ocfs2

   mounted.ocfs2 -d          # detect OCFS2 volumes on the system
   mounted.ocfs2 -f          # full: which nodes have it mounted
   ```

   `mounted.ocfs2 -f` esperado:

   ```
   Device                FS     Nodes
   /dev/sdc1             ocfs2  node1, node2
   ```

6. Consultá el volumen con `o2info`:

   ```bash
   o2info --volinfo /dev/sdc1
   o2info --fs-features /dev/sdc1
   o2info --freeinode /dev/sdc1
   ```

   `--volinfo` esperado:

   ```
           Label: web-ocfs2
            UUID: 1A2B3C4D5E6F70819A2B3C4D5E6F7081
      Block Size: 4096
    Cluster Size: 4096
     Node Slots: 4
        Features: backup-super strict-journal-super sparse extended-slotmap
        Features: inline-data xattr indexed-dirs refcount discontig-bg
   ```

**Preguntas de comprensión (5):**

- **5a.** OCFS2 se configuró con la pila nativa `o2cb` y su propio `cluster.conf`, mientras que GFS2 se apoyó en Pacemaker + DLM. ¿Cuáles son las dos pilas de clúster que OCFS2 puede usar, y qué cambia `--cluster-stack=pcmk` respecto del despliegue?
- **5b.** En `cluster.conf`, ¿por qué el `name` del nodo debe ser igual a `uname -n` exactamente, y por qué el archivo debe ser idéntico byte a byte (mismos números de nodo) en cada nodo?
- **5c.** `mkfs.ocfs2 -N 4` estableció cuatro slots de nodos. ¿Qué es un "node slot" en OCFS2, qué posee cada slot, y qué pasa si intentás montar en más nodos que la cantidad de slots?

---

## Ejercicio 6 — Tuning, diagnóstico y manejo de fallas en OCFS2

**Objetivo:** aumentar en línea la cantidad de slots de nodos, inspeccionar metadatos con `debugfs.ocfs2`, y comprender la reparación offline y la recuperación dirigida por el DLM.

1. Aumentá los slots de nodos de 4 a 6 en línea con `tunefs.ocfs2` (necesario antes de que un 5.º/6.º nodo pueda montar):

   ```bash
   tunefs.ocfs2 -N 6 /dev/sdc1
   o2info --volinfo /dev/sdc1 | grep 'Node Slots'
   ```

2. Reetiquetá y alterná una feature (las features pueden requerir el volumen desmontado):

   ```bash
   tunefs.ocfs2 -L web-shared /dev/sdc1
   tunefs.ocfs2 --fs-features=usrquota,grpquota /dev/sdc1
   ```

3. Inspeccioná las estructuras internas de forma interactiva con `debugfs.ocfs2` — el análogo de `debugfs` en OCFS2:

   ```bash
   debugfs.ocfs2 -R "stats" /dev/sdc1 | head -n 20
   debugfs.ocfs2 -R "slotmap" /dev/sdc1
   debugfs.ocfs2 -R "ls -l //" /dev/sdc1        # the system directory
   ```

   `slotmap` esperado:

   ```
       Slot#   Node#
           0       0
           1       1
   ```

4. Capturá los metadatos completos para análisis offline con `o2image` (no toca los bloques de datos):

   ```bash
   o2image /dev/sdc1 /root/web-ocfs2.o2img
   ls -lh /root/web-ocfs2.o2img
   ```

5. Comprendé la reparación offline. `fsck.ocfs2` debe ejecutarse con el volumen **desmontado en todos los nodos**; `-f` fuerza una verificación completa, `-y` responde "sí" automáticamente:

   ```bash
   umount /srv/ocfs2                  # [all nodes] — must be unmounted everywhere
   fsck.ocfs2 -fy /dev/sdc1
   ```

   Esperado (abreviado):

   ```
   fsck.ocfs2 1.8.7
   Checking OCFS2 filesystem in /dev/sdc1:
     Label:              web-shared
     UUID:               1A2B3C4D5E6F70819A2B3C4D5E6F7081
     Number of blocks:   2621440
     Bytes per block:    4096
     Number of clusters: 2621440
     Number of slots:    6
   /dev/sdc1 was run with -f, check forced.
   Pass 0a: Checking cluster allocation chains
   Pass 1: Checking inodes and blocks.
   ...
   All passes succeeded.
   ```

6. Simulá una falla de nodo para observar la recuperación. Fenceá/reiniciá `node2` mientras hay una escritura en progreso en `node1`, luego observá cómo la recuperación de journal de OCFS2 reproduce el slot de `node2`:

   ```bash
   # node1 — start a continuous write
   dd if=/dev/zero of=/srv/ocfs2/bigfile bs=1M count=2048 &

   # from another host, hard-power-cycle node2 (or: pcs stonith fence node2)

   # node1 — observe recovery in the kernel log
   dmesg -w | grep -iE 'ocfs2|recover'
   ```

   Mensajes de kernel esperados:

   ```
   ocfs2: Begin replay journal (node 1, slot 1) on device (8,33)
   ocfs2: End replay journal (node 1, slot 1) on device (8,33)
   ocfs2: Beginning quota recovery on device (8,33) for slot 1
   ocfs2: Finishing quota recovery on device (8,33) for slot 1
   ```

**Preguntas de comprensión (6):**

- **6a.** `tunefs.ocfs2 -N 6` aumentó los slots de nodos en línea. ¿Por qué puede OCFS2 agregar slots sin desmontar, y por qué la cantidad de slots solo puede **aumentarse**, nunca disminuirse fácilmente en el lugar?
- **6b.** Cuando `node2` fue fenced, `node1` registró "replay journal (slot 1)". Con tus propias palabras, describí qué recupera la reproducción del journal y por qué el nodo *sobreviviente* la realiza en lugar del muerto.
- **6c.** Emparejá cada herramienta de diagnóstico con lo que inspecciona: `o2info`, `mounted.ocfs2`, `debugfs.ocfs2`, `o2image`, `fsck.ocfs2`. ¿Cuáles de estas son seguras en un volumen montado y cuáles exigen que esté desmontado?

---

## Respuestas

<details>
<summary>Hacé clic para revelar las respuestas a todas las preguntas de comprensión</summary>

### Ejercicio 1

**1a.** El **Distributed Lock Manager (DLM)** arbitra el acceso concurrente. En esta pila corre en el kernel y es coordinado en espacio de usuario por `dlm_controld` (iniciado por el recurso `ocf:pacemaker:controld`). Cada bloqueo de metadatos o de datos que un nodo quiere (un "glock" en términos de GFS2, un lock resource en OCFS2) es otorgado a nivel de clúster por el DLM, de modo que dos nodos nunca pueden sostener bloqueos de escritura en conflicto sobre el mismo objeto. **DLM = Distributed Lock Manager.**

**1b.** Un sistema de archivos en clúster permite que *cada* nodo escriba directamente en los bloques compartidos. Si un nodo se cae o se cuelga con I/O sucio pendiente, el DLM no puede saber si las escrituras en vuelo de ese nodo se completaron, por lo que **no puede liberar de forma segura los bloqueos del nodo muerto**. STONITH/fencing resuelve esto apagando por la fuerza (o aislando) el nodo fallido — una vez que el fencing confirma que el nodo está muerto, el DLM libera sus bloqueos y la recuperación/reproducción de journal procede. Sin un fencing funcional, el I/O del nodo sobreviviente **se bloquea indefinidamente** (el montaje parece colgado) porque liberar los bloqueos prematuramente podría corromper el sistema de archivos. Por eso el recurso `dlm` usa `on-fail=fence`.

**1c.** Un sistema de archivos de clúster de disco compartido usa un diseño *simétrico* donde cada nodo participa en un único dominio de bloqueo distribuido sobre un dispositivo compartido. Cada adquisición/liberación de bloqueo genera tráfico DLM entre nodos, y el costo de coordinación de bloqueos/recuperación crece con la cantidad de nodos, por lo que el rendimiento sobre metadatos "calientes" se degrada a medida que se agregan nodos. Está diseñado para una **cantidad pequeña de nodos** (típicamente ≤16–32) compartiendo un LUN de almacenamiento, no para cientos de nodos — ese es el dominio de los sistemas de archivos scale-out/paralelos o distribuidos por objetos (Ceph, GlusterFS, Lustre) que particionan datos y metadatos entre servidores en lugar de compartir un único dispositivo de bloques.

### Ejercicio 2

**2a.** El DLM y la gestión de bloqueos deben estar **corriendo en cada nodo** que participa en el sistema de archivos, y deben recuperarse en sincronía con los cambios de membresía del clúster. Un **clon** corre una instancia del recurso en cada nodo; `interleave=true` significa que la relación ordenada de inicio/detención se evalúa **por nodo** en lugar de esperar a *todas* las copias de la dependencia en todo el clúster. Eso permite que un nodo individual levante su cadena `dlm → lvmlockd → Filesystem` de forma independiente, lo cual es esencial para un comportamiento limpio de join/leave y evita que un nodo lento estanque todo el conjunto de clones.

**2b.** `--activate sy` (activación compartida) activa el LV en **modo compartido** para que pueda estar activo simultáneamente en múltiples nodos — que es exactamente lo que un sistema de archivos en clúster necesita, ya que todos los nodos montan el mismo LV a la vez. El valor por defecto (exclusivo, `-ay`/`ey`) permite la activación en solo **un** nodo a la vez y es correcto para un sistema de archivos no en clúster como ext4/XFS sobre almacenamiento compartido (activo-pasivo). GFS2/OCFS2 requieren activación compartida porque el montaje concurrente en múltiples nodos es toda la idea; la activación exclusiva impediría que el segundo nodo active el LV.

**2c.** El DLM es el árbitro que garantiza la integridad de los datos. Si `dlm_controld` falla en un nodo, ese nodo ya no puede participar de forma segura en el dominio de bloqueo, pero aún puede tener el sistema de archivos montado y I/O sucio en vuelo. **Reiniciar** el daemon localmente no resuelve la incertidumbre del I/O pendiente para el resto del clúster, y simplemente **detener** el recurso deja al nodo en un estado ambiguo. La única resolución segura es **fencear** el nodo — removerlo por completo para que los nodos restantes puedan recuperar sus bloqueos y journals de forma determinista. De ahí `on-fail=fence`.

### Ejercicio 3

**3a.** La lock table `alpha:web` es `<cluster_name>:<filesystem_name>`. El primer campo (`alpha`) **debe coincidir con el `cluster_name` de Corosync**; le dice a `lock_dlm`/`dlm_controld` a qué dominio de bloqueo de qué clúster unirse. El segundo campo (`web`) es el nombre único del sistema de archivos (y se convierte en el nombre del lockspace del DLM / directorio de sysfs). Si el primer campo **no** coincide con el nombre del clúster de Corosync, el montaje **falla** — el kernel no puede unirse a un lockspace de un clúster del que no es miembro, y obtenés un error de montaje como `error mounting lockproto lock_dlm` / "gfs_controld join connect error" en `dmesg`.

**3b.** Cada nodo que monta un sistema de archivos GFS2 **consume un journal**; GFS2 no puede crear journals dinámicamente sobre la marcha en el momento del montaje. Preasignar journals extra (`-j 3` en un clúster de 2 nodos) deja margen para que un tercer nodo pueda unirse y montar **sin** reformatear. Para agregar un journal más adelante, ejecutá **`gfs2_jadd -j <n> <mountpoint>`** en un nodo donde el sistema de archivos está montado (y después de extender el dispositivo si no hay espacio libre).

**3c.** El recurso `Filesystem` es un **clon** porque el sistema de archivos debe montarse **de forma concurrente en todos los nodos** — esa es la definición de un sistema de archivos en clúster en uso activo-activo; un recurso simple lo montaría en un solo nodo. Si intentaras montar un GFS2 con `lock_dlm` sin `dlm`/`lvmlockd` corriendo, el montaje **fallaría o se colgaría**: `lock_dlm` no puede alcanzar a `dlm_controld` para unirse al lockspace, por lo que el kernel no tiene forma de adquirir bloqueos. Por eso las restricciones de orden fuerzan `dlm → lvmlockd → Filesystem`.

### Ejercicio 4

**4a.** `lvextend` hace crecer el **dispositivo de bloques** (el LV); `gfs2_grow` luego hace crecer el **sistema de archivos** para llenar el espacio recién disponible. Son separados porque el gestor de volúmenes y el sistema de archivos son capas separadas. El orden correcto es **`lvextend` primero, luego `gfs2_grow`** — debés tener el espacio de bloques extra presente antes de que el sistema de archivos pueda expandirse hacia él. **`gfs2_grow` solo puede crecer, nunca encoger** un sistema de archivos GFS2; no hay un shrink soportado en línea (ni offline) para GFS2, por lo que reducir el tamaño requiere backup, reformateo y restauración.

**4b.** Agregar un journal (`gfs2_jadd`) asigna nuevos metadatos en espacio libre y los registra mientras el sistema de archivos está en vivo y el DLM protege la operación — no requiere acceso exclusivo/offline, por lo que es **en línea**. `fsck.gfs2`, en cambio, debe tener acceso **exclusivo** para verificar y reescribir metadatos arbitrarios de forma consistente; si algún nodo tuviera el sistema de archivos montado, ese nodo podría modificar bloques por debajo del verificador, por lo que `fsck.gfs2` requiere el sistema de archivos **desmontado en cada nodo**.

**4c.** Ejecutar `fsck.gfs2` en un dispositivo que todavía está montado en otro lado arriesga **corrupción catastrófica de metadatos**: el verificador y el kernel en vivo ambos escriben metadatos sin coordinación (fsck no pasa por el DLM), produciendo inodos entrelazados, bloques perdidos, o un sistema de archivos que no se puede montar. La verificación previa obligatoria es **confirmar que el sistema de archivos está desmontado en todos los nodos** (p. ej. `pcs resource disable` el clon, luego verificar con `mount`/`mounted`/`dlm_tool ls` en cada nodo) antes de invocar `fsck.gfs2`.

### Ejercicio 5

**5a.** OCFS2 soporta dos pilas de clúster: la pila nativa **`o2cb`** (su propio `cluster.conf`, servicio `o2cb` y heartbeat, independiente de Pacemaker) y la pila **`pcmk`**, que integra OCFS2 con **Pacemaker + el DLM del kernel** (`ocf:pacemaker:controld`), la misma infraestructura que usa GFS2. `--cluster-stack=pcmk` (con `--cluster-name` = el clúster de Pacemaker) hace que OCFS2 use Pacemaker para la membresía/fencing y el DLM para el bloqueo en lugar del heartbeat autónomo de `o2cb` — preferido cuando ya corrés un clúster Pacemaker para unificar fencing y membresía.

**5b.** La pila `o2cb` de OCFS2 identifica cada nodo por su `name`, que resuelve contra el hostname local; si `name` ≠ `uname -n`, el nodo no puede reconocerse a sí mismo en `cluster.conf` y **falla al unirse** al clúster. El archivo debe ser **idéntico byte a byte (mismos números de nodo, IPs, puertos) en cada nodo** porque cada nodo usa el mismo mapa para identificar a sus pares e indexar el heartbeat de disco/slot map; números de nodo o membresía discrepantes entre nodos causan inconsistencias tipo split-brain y fallas de montaje/heartbeat.

**5c.** Un **node slot** es una reserva por nodo dentro del volumen OCFS2 — cada slot posee su **propio journal** (y área de recuperación de cuota). Un nodo reclama un slot libre cuando monta y reproduce el journal de ese slot durante la recuperación si el dueño muere. `mkfs.ocfs2 -N 4` creó cuatro slots, así que hasta cuatro nodos pueden montar de forma concurrente. Si intentás montar en **más nodos que la cantidad de slots**, el montaje extra **falla** ("no free slots") hasta que agregues slots con `tunefs.ocfs2 -N`.

### Ejercicio 6

**6a.** Aumentar los slots solo **asigna journals y entradas del slot-map adicionales en espacio libre** y actualiza el conteo del superblock — no perturba los slots existentes ni los montajes en vivo, por lo que es seguro **en línea**. La cantidad de slots solo puede aumentarse porque disminuirla requeriría **remover journals que podrían contener datos de recuperación sin reproducir** y reubicar/validar metadatos ligados a esos slots, lo cual es inseguro mientras algún nodo pudiera necesitarlos; OCFS2 por lo tanto trata el crecimiento de slots como unidireccional (reducir slots no es una operación en línea ordinaria).

**6b.** Cada nodo escribe transacciones de metadatos en **su propio journal** (su slot). Cuando un nodo muere, sus últimas transacciones pueden estar committeadas en el journal pero aún no completamente escritas de vuelta a sus ubicaciones finales en disco, dejando el sistema de archivos inconsistente. La **reproducción del journal** lee el journal del nodo muerto y completa (o descarta) esas transacciones pendientes, restaurando la consistencia. Un nodo **sobreviviente** la realiza precisamente porque el nodo muerto no puede — un nodo sano reclama/lee el journal del slot fallido y lo reproduce (después de que el nodo se confirma muerto vía heartbeat/fencing), que es por lo que viste `replay journal (slot 1)` registrado en `node1`.

**6c.**
- `o2info` — reporta info de volumen/features/espacio libre; **seguro montado**.
- `mounted.ocfs2` — detecta volúmenes OCFS2 y qué nodos los montan; **seguro montado** (escaneo de solo lectura).
- `debugfs.ocfs2` — inspector interactivo de metadatos; **seguro de solo lectura en un volumen montado** (usá los comandos de escritura/debug con muchísimo cuidado).
- `o2image` — copia metadatos a un archivo de imagen para análisis offline; **seguro montado** (lee solo metadatos).
- `fsck.ocfs2` — verificación/reparación de consistencia; **requiere el volumen desmontado en todos los nodos** (escribe/repara metadatos y no puede coordinarse con montajes en vivo).

</details>

---

### Fuentes

- LPI — Exam 306-300 Objectives (Topic 362.3): <https://www.lpi.org/our-certifications/exam-306-objectives/>
- Linux kernel documentation — GFS2: <https://www.kernel.org/doc/html/latest/filesystems/gfs2.html>
- Linux kernel documentation — OCFS2: <https://www.kernel.org/doc/html/latest/filesystems/ocfs2.html>
- Red Hat — *Configuring GFS2 File Systems* (RHEL 9): <https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/configuring_gfs2_file_systems/index>
- SUSE — *Administration Guide: OCFS2* (SLE HA): <https://documentation.suse.com/sle-ha/15-SP6/html/SLE-HA-all/cha-ha-ocfs2.html>
- The DLM man pages: `dlm_tool(8)`, `dlm_controld(8)`; GFS2 tools: `mkfs.gfs2(8)`, `gfs2_jadd(8)`, `gfs2_grow(8)`, `tunegfs2(8)`, `fsck.gfs2(8)`, `gfs2_edit(8)`; OCFS2 tools: `mkfs.ocfs2(8)`, `o2cb(7)`, `o2info(8)`, `mounted.ocfs2(8)`, `tunefs.ocfs2(8)`, `debugfs.ocfs2(8)`, `fsck.ocfs2(8)`, `o2image(8)`