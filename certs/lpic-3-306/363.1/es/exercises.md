# Ejercicios guiados — 363.1 GlusterFS Storage Clusters

> **Certificación:** LPIC-3 306 (examen 306-300, v3.0) · **Tema 363.1** · Peso 8.33
> **Fuente oficial de objetivos:** <https://www.lpi.org/our-certifications/exam-306-objectives/>
> **Documentación de referencia:** <https://docs.gluster.org/en/latest/>

Estos ejercicios asumen un laboratorio de **cuatro máquinas virtuales** con Linux (RHEL/Rocky/Alma 9 o Debian 12), resolución de nombres funcional (`/etc/hosts` o DNS) y un disco secundario dedicado por nodo servidor:

| Host | Rol | IP | Disco para bricks |
|------|-----|----|----|
| `node1` | Peer / server | 10.0.0.11 | `/dev/sdb` |
| `node2` | Peer / server | 10.0.0.12 | `/dev/sdb` |
| `node3` | Peer / server | 10.0.0.13 | `/dev/sdb` |
| `client1` | Cliente FUSE | 10.0.0.20 | — |

Todos los comandos `gluster` se ejecutan **como root** (o con `sudo`) y, salvo que se indique lo contrario, desde **`node1`**. La CLI de GlusterFS es un frontend del daemon de management `glusterd`, que replica la configuración del *trusted storage pool* a todos los peers: no importa desde qué nodo administres.

---

## Ejercicio 0 — Preparación del entorno y de los bricks

Un **brick** es la unidad de almacenamiento fundamental de GlusterFS: un directorio exportado sobre un filesystem POSIX de un servidor, identificado por `hostname:/ruta`. GlusterFS almacena metadatos propios como *extended attributes* (`trusted.gfid`, `trusted.afr.*`, `trusted.glusterfs.dht`), de modo que el filesystem subyacente debe soportar `xattr` sin límites estrechos. La recomendación oficial es **XFS con inodos de 512 bytes**.

**Pasos (ejecutar en `node1`, `node2` y `node3`):**

1. Comprobá la resolución de nombres cruzada entre los tres nodos:

   ```bash
   for h in node1 node2 node3 client1; do getent hosts $h; done
   ```

   ```
   10.0.0.11       node1
   10.0.0.12       node2
   10.0.0.13       node3
   10.0.0.20       client1
   ```

2. Instalá el servidor GlusterFS. En RHEL/Rocky/Alma:

   ```bash
   dnf install -y centos-release-gluster   # habilita el repo CentOS Storage SIG
   dnf install -y glusterfs-server
   ```

   En Debian/Ubuntu: `apt install -y glusterfs-server`.

3. Habilitá y arrancá el daemon de management `glusterd`:

   ```bash
   systemctl enable --now glusterd
   systemctl status glusterd --no-pager
   ```

   ```
   ● glusterd.service - GlusterFS, a clustered file-system server
        Loaded: loaded (/usr/lib/systemd/system/glusterd.service; enabled)
        Active: active (running) since Wed 2026-08-12 10:04:22 UTC; 3s ago
      Main PID: 1187 (glusterd)
   ```

4. Preparbackup el brick: particioná, formateá con XFS (`-i size=512`) y montá el filesystem, no en la raíz del brick sino con el brick en un **subdirectorio** del punto de montaje:

   ```bash
   mkfs.xfs -i size=512 -L brick1 /dev/sdb
   mkdir -p /data/brick1
   echo 'LABEL=brick1  /data/brick1  xfs  defaults  0 0' >> /etc/fstab
   mount -a
   mkdir -p /data/brick1/gv0
   ```

5. Verificá el tamaño de inodo del XFS montado:

   ```bash
   xfs_info /data/brick1 | grep isize
   ```

   ```
   meta-data=/dev/sdb  isize=512    agcount=4, agsize=...
   ```

6. Abrí el firewall para GlusterFS (glusterd escucha en 24007/tcp; cada brick usa un puerto dinámico desde 49152/tcp):

   ```bash
   firewall-cmd --permanent --add-service=glusterfs
   firewall-cmd --reload
   ```

**Preguntas de comprensión:**

- **P0.1** ¿Por qué se recomienda XFS con `isize=512` en lugar del inodo por defecto de 256 bytes? ¿Qué falla si el filesystem no soporta `xattr` extendidos?
- **P0.2** La guía oficial insiste en usar un **subdirectorio** (`/data/brick1/gv0`) como brick, y no el punto de montaje raíz (`/data/brick1`). ¿Qué desastre operativo previene esta convención cuando el disco no llega a montarse en el boot?
- **P0.3** ¿Qué proceso escucha en 24007/tcp y qué escucha en 49152/tcp? ¿Cuántos puertos de brick necesitás abrir en un nodo que hospeda tres bricks?

---

## Ejercicio 1 — Trusted Storage Pool (peers)

Antes de crear volúmenes hay que federar los nodos en un *trusted storage pool*. `glusterd` en cada peer mantiene una copia sincronizada del estado del cluster bajo `/var/lib/glusterd/`.

**Pasos (desde `node1`):**

1. Sondeá a `node2` y `node3` para incorporarlos al pool:

   ```bash
   gluster peer probe node2
   gluster peer probe node3
   ```

   ```
   peer probe: success
   peer probe: success
   ```

2. Verificá el estado de los peers:

   ```bash
   gluster peer status
   ```

   ```
   Number of Peers: 2

   Hostname: node2
   Uuid: 7f3c1e2a-8b90-4d11-9a2e-1c5f6d7e8a90
   State: Peer in Cluster (Connected)

   Hostname: node3
   Uuid: b2d4c6e8-1a3f-4c5d-8e9f-0a1b2c3d4e5f
   State: Peer in Cluster (Connected)
   ```

3. Listá el pool completo, que **sí incluye al nodo local**:

   ```bash
   gluster pool list
   ```

   ```
   UUID                                    Hostname        State
   7f3c1e2a-8b90-4d11-9a2e-1c5f6d7e8a90    node2           Connected
   b2d4c6e8-1a3f-4c5d-8e9f-0a1b2c3d4e5f    node3           Connected
   a1b2c3d4-5e6f-7a8b-9c0d-1e2f3a4b5c6d    localhost       Connected
   ```

4. Verificá desde `node2` que ve a `node1` con su hostname (no como IP):

   ```bash
   ssh node2 gluster peer status
   ```

**Preguntas de comprensión:**

- **P1.1** ¿Por qué `gluster peer status` muestra `Number of Peers: 2` mientras `gluster pool list` muestra tres entradas?
- **P1.2** Si hacés `peer probe node2` desde `node1` cuando `node1` no está en `/etc/hosts` de `node2`, la primera entrada de peer en `node2` aparecerá como la **IP** de `node1`. ¿Por qué es un problema y cómo se corrige de forma canónica?
- **P1.3** ¿Dónde persiste `glusterd` la información del pool y de los volúmenes, y por qué eso hace que la CLI sea utilizable desde cualquier peer indistintamente?

---

## Ejercicio 2 — Crear un volumen replicated (replica 3)

Un volumen **replicated** escribe cada archivo en todos los bricks del *replica set*, aportando alta disponibilidad: mientras sobreviva una copia, los datos están accesibles. El translator responsable es **AFR** (Automatic File Replication).

**Pasos (desde `node1`):**

1. Creá un volumen `gv0` con réplica 3 usando un brick de cada nodo:

   ```bash
   gluster volume create gv0 replica 3 \
     node1:/data/brick1/gv0 \
     node2:/data/brick1/gv0 \
     node3:/data/brick1/gv0
   ```

   ```
   volume create: gv0: success: please start the volume to access data
   ```

2. Arrancá el volumen:

   ```bash
   gluster volume start gv0
   ```

3. Inspeccioná la topología:

   ```bash
   gluster volume info gv0
   ```

   ```
   Volume Name: gv0
   Type: Replicate
   Volume ID: 4d5e6f7a-8b9c-0d1e-2f3a-4b5c6d7e8f90
   Status: Started
   Snapshot Count: 0
   Number of Bricks: 1 x 3 = 3
   Transport-type: tcp
   Bricks:
   Brick1: node1:/data/brick1/gv0
   Brick2: node2:/data/brick1/gv0
   Brick3: node3:/data/brick1/gv0
   Options Reconfigured:
   cluster.granular-entry-heal: on
   storage.fips-mode-rchecksum: on
   transport.address-family: inet
   nfs.disable: on
   ```

4. Verificá que los procesos de brick (`glusterfsd`) y el self-heal daemon están online:

   ```bash
   gluster volume status gv0
   ```

   ```
   Status of volume: gv0
   Gluster process                          TCP Port  RDMA Port  Online  Pid
   ------------------------------------------------------------------------------
   Brick node1:/data/brick1/gv0             49152     0          Y       2043
   Brick node2:/data/brick1/gv0             49152     0          Y       2011
   Brick node3:/data/brick1/gv0             49152     0          Y       1998
   Self-heal Daemon on localhost            N/A       N/A        Y       2061
   Self-heal Daemon on node2                N/A       N/A        Y       2029
   Self-heal Daemon on node3                N/A       N/A        Y       2016
   ```

**Preguntas de comprensión:**

- **P2.1** Interpretá la línea `Number of Bricks: 1 x 3 = 3`. ¿Qué significaría `2 x 3 = 6`?
- **P2.2** ¿Qué es el **Self-heal Daemon** (`glustershd`) y por qué aparece uno por nodo aunque el volumen tenga un solo replica set?
- **P2.3** Con réplica 3 y *client-side quorum* automático, si cae **un** brick el volumen sigue aceptando escrituras; si caen **dos**, no. Explicá por qué esa política existe y qué previene.
- **P2.4** ¿Por qué la opción `nfs.disable: on` aparece por defecto en las versiones modernas de GlusterFS? ¿Qué reemplazó al NFS interno gnfs para exportar por NFS?

---

## Ejercicio 3 — Montar y usar el volumen (cliente FUSE y fstab)

El acceso nativo es vía el cliente **FUSE** (`mount -t glusterfs`), que conecta a un nodo solo para descargar el *volfile* (la topología del volumen) y luego habla **directamente con todos los bricks** — el nodo del `mount` no es un cuello de botella ni un SPOF una vez montado.

**Pasos (desde `client1`):**

1. Instalá el paquete de cliente:

   ```bash
   dnf install -y glusterfs-fuse    # Debian: apt install -y glusterfs-client
   ```

2. Montá el volumen manualmente:

   ```bash
   mkdir -p /mnt/gv0
   mount -t glusterfs node1:/gv0 /mnt/gv0
   ```

3. Confirmá el tipo de montaje y escribí datos de prueba:

   ```bash
   mount | grep gv0
   for i in $(seq 1 20); do echo "archivo $i" > /mnt/gv0/file-$i.txt; done
   ls /mnt/gv0 | wc -l
   ```

   ```
   node1:/gv0 on /mnt/gv0 type fuse.glusterfs (rw,relatime,user_id=0,...)
   20
   ```

4. Verificá que **cada** brick tiene las 20 copias (replicación total). En cualquier server:

   ```bash
   ssh node2 'ls /data/brick1/gv0 | wc -l'
   ```

   ```
   20
   ```

5. Persistí el montaje en `/etc/fstab` con failover del *volfile server*:

   ```bash
   echo 'node1:/gv0  /mnt/gv0  glusterfs  defaults,_netdev,backup-volfile-servers=node2:node3  0 0' >> /etc/fstab
   umount /mnt/gv0 && mount -a && mount | grep gv0
   ```

**Preguntas de comprensión:**

- **P3.1** ¿Por qué es imprescindible la opción `_netdev` en el `/etc/fstab` de un montaje GlusterFS?
- **P3.2** El montaje FUSE apunta a `node1:/gv0`. Si `node1` está caído **en el momento del boot** del cliente, ¿el montaje falla? ¿Qué hace exactamente `backup-volfile-servers=node2:node3`?
- **P3.3** Una vez montado apuntando a `node1`, ¿qué pasa con las lecturas/escrituras si `node1` cae más tarde? Justificá con la arquitectura del cliente FUSE.
- **P3.4** ¿En qué se diferencia leer directamente en `/data/brick1/gv0` (el brick) de leer en `/mnt/gv0` (el punto FUSE)? ¿Por qué **nunca** debés escribir directamente en un brick?

---

## Ejercicio 4 — Alta disponibilidad, self-heal y split-brain

Ahora se prueba la resiliencia real: derribar un brick, seguir escribiendo, restaurarlo y observar la cicatrización automática. AFR marca la divergencia con *changelog xattrs* `trusted.afr.gv0-client-N` (contadores de tipo data/metadata/entry) en los bricks que sí recibieron la escritura.

**Pasos:**

1. En `node3`, matá el proceso del brick (simulando una falla de disco/servidor). Averiguá el PID con `gluster volume status gv0` y luego:

   ```bash
   ssh node3 'kill -9 <PID-del-brick-node3>'
   gluster volume status gv0 | grep node3
   ```

   ```
   Brick node3:/data/brick1/gv0             N/A       N/A        N       N/A
   ```

2. Desde `client1`, escribí datos nuevos mientras `node3` está caído:

   ```bash
   for i in $(seq 21 40); do echo "durante caida $i" > /mnt/gv0/file-$i.txt; done
   ```

3. Consultá los archivos pendientes de heal (los que divergieron):

   ```bash
   gluster volume heal gv0 info
   ```

   ```
   Brick node1:/data/brick1/gv0
   /file-21.txt
   ...
   /file-40.txt
   Status: Connected
   Number of entries: 20

   Brick node3:/data/brick1/gv0
   Status: Connected
   Number of entries: 0
   ```

4. Restaurá el brick de `node3` y observá el heal proactivo:

   ```bash
   gluster volume start gv0 force        # relanza el glusterfsd caído
   gluster volume heal gv0               # dispara el heal manual (además del automático)
   sleep 10
   gluster volume heal gv0 info
   ```

   ```
   Brick node1:/data/brick1/gv0
   Status: Connected
   Number of entries: 0
   ...
   ```

5. Confirmá que `node3` recuperó las 40 copias:

   ```bash
   ssh node3 'ls /data/brick1/gv0 | wc -l'
   ```

   ```
   40
   ```

6. Consultá si hubo **split-brain** (no debería haberlo con réplica 3 y quorum):

   ```bash
   gluster volume heal gv0 info split-brain
   ```

   ```
   Brick node1:/data/brick1/gv0
   Status: Connected
   Number of entries in split-brain: 0
   ...
   ```

7. Revisá las políticas de quorum activas:

   ```bash
   gluster volume get gv0 cluster.quorum-type
   gluster volume get gv0 cluster.server-quorum-type
   ```

**Preguntas de comprensión:**

- **P4.1** En el paso 3, ¿por qué los archivos aparecen listados bajo el brick de `node1` (y `node2`) pero **no** bajo el de `node3`? ¿Qué representa esa lista exactamente?
- **P4.2** ¿Qué es un **split-brain** en AFR y bajo qué condiciones aparece? ¿Por qué una réplica 3 con `cluster.quorum-type auto` lo hace prácticamente imposible, mientras que una réplica 2 sin arbiter es vulnerable?
- **P4.3** Diferenciá **client-side quorum** (`cluster.quorum-type`) de **server-side quorum** (`cluster.server-quorum-type`). ¿Cuál pone el replica set en solo-lectura y cuál apaga bricks en la partición minoritaria del pool?
- **P4.4** ¿Qué ventaja tiene `cluster.granular-entry-heal: on` frente al heal de directorio completo en un volumen con millones de archivos?

---

## Ejercicio 5 — Volúmenes distributed y dispersed (erasure coding)

GlusterFS combina translators para distintos objetivos. Un volumen **distributed** reparte archivos entre bricks vía DHT (hash sobre el nombre) sin redundancia — capacidad, no HA. Un volumen **dispersed** aplica *erasure coding* (como RAID6 en red): tolera fallas con menos overhead de espacio que la replicación.

**Pasos:**

1. Preparación previa: creá un segundo brick por nodo (`/data/brick2/gv-ec`) repitiendo el patrón del Ejercicio 0 sobre un tercer disco o un directorio adicional (con `force` si va sobre la raíz). Luego creá un volumen **dispersed** `disperse 3 redundancy 1`:

   ```bash
   gluster volume create gv-ec disperse 3 redundancy 1 \
     node1:/data/brick2/gv-ec \
     node2:/data/brick2/gv-ec \
     node3:/data/brick2/gv-ec force
   gluster volume start gv-ec
   gluster volume info gv-ec
   ```

   ```
   Volume Name: gv-ec
   Type: Disperse
   Number of Bricks: 1 x (2 + 1) = 3
   Transport-type: tcp
   Bricks:
   Brick1: node1:/data/brick2/gv-ec
   Brick2: node2:/data/brick2/gv-ec
   Brick3: node3:/data/brick2/gv-ec
   ```

2. Interpretá `1 x (2 + 1) = 3`: 2 bricks de datos + 1 de redundancia. Compará el espacio útil frente a réplica 3:

   ```bash
   # Capacidad útil dispersed 3/redundancy 1: (3-1)/3 ≈ 66% del total
   # Capacidad útil replica 3:                 1/3    ≈ 33% del total
   df -h
   ```

3. (Opcional) Creá un **distributed-replicated** para ver DHT + AFR juntos. Con réplica 2 y cuatro bricks se forman dos replica sets:

   ```bash
   gluster volume create gv-dr replica 2 \
     node1:/data/brick3/a node2:/data/brick3/a \
     node1:/data/brick3/b node3:/data/brick3/b force
   gluster volume info gv-dr | grep 'Number of Bricks'
   ```

   ```
   Number of Bricks: 2 x 2 = 4
   ```

**Preguntas de comprensión:**

- **P5.1** ¿Qué translator decide en qué brick cae cada archivo de un volumen distributed, y sobre qué calcula el hash? ¿Qué pasa con un archivo si su único brick DHT muere en un volumen puramente distributed?
- **P5.2** Con `disperse 3 redundancy 1`, ¿cuántos bricks podés perder sin perder datos, y cuál es el % de espacio útil? Explicá el trade-off frente a réplica 3 en términos de espacio, CPU y latencia.
- **P5.3** En un volumen `2 x 2 = 4`, ¿la caída de un solo brick deja indisponible **todo** el volumen o solo una parte de los archivos? Justificá.
- **P5.4** ¿Por qué GlusterFS advierte contra `replica 2` sin **arbiter** para cargas de escritura críticas, y cómo cambia el cálculo un `replica 3 arbiter 1`?

---

## Ejercicio 6 — Escalado en caliente: add-brick, rebalance, replace/remove-brick

Un cluster GlusterFS crece y se mantiene sin downtime. Al agregar bricks a un volumen distributed hay que **rebalancear** para redistribuir el layout DHT y migrar datos existentes.

**Pasos (sobre `gv0`, que hoy es `1 x 3`):**

1. Convertí `gv0` de replicated puro a distributed-replicated agregando un segundo replica set (tres bricks nuevos). Preparalos primero y luego:

   ```bash
   gluster volume add-brick gv0 \
     node1:/data/brick4/gv0 \
     node2:/data/brick4/gv0 \
     node3:/data/brick4/gv0
   gluster volume info gv0 | grep 'Number of Bricks'
   ```

   ```
   Number of Bricks: 2 x 3 = 6
   ```

2. Corregí el layout y migrá datos hacia el nuevo replica set:

   ```bash
   gluster volume rebalance gv0 start
   gluster volume rebalance gv0 status
   ```

   ```
   Node     Rebalanced-files  size  scanned  failures  skipped  status  run time
   -------  ----------------  ----  -------  --------  -------  ------  --------
   node1                  18   72B       40         0        0  completed  1s
   ...
   ```

3. Reemplazá un brick fallado por uno nuevo (por ejemplo el brick de `node3` del primer set migra a `/data/brick5`):

   ```bash
   gluster volume replace-brick gv0 \
     node3:/data/brick1/gv0 node3:/data/brick5/gv0 commit force
   gluster volume heal gv0     # el nuevo brick se rellena por self-heal
   ```

4. Reducí capacidad quitando el segundo replica set de forma segura (con migración de datos, **no** con `force`):

   ```bash
   gluster volume remove-brick gv0 \
     node1:/data/brick4/gv0 node2:/data/brick4/gv0 node3:/data/brick4/gv0 start
   gluster volume remove-brick gv0 \
     node1:/data/brick4/gv0 node2:/data/brick4/gv0 node3:/data/brick4/gv0 status
   gluster volume remove-brick gv0 \
     node1:/data/brick4/gv0 node2:/data/brick4/gv0 node3:/data/brick4/gv0 commit
   ```

**Preguntas de comprensión:**

- **P6.1** ¿Por qué al hacer `add-brick` a un volumen distributed es obligatorio ejecutar un `rebalance` después? ¿Qué diferencia hay entre `rebalance ... fix-layout start` y `rebalance ... start` a secas?
- **P6.2** ¿Por qué `remove-brick ... start` (con fase de migración) es seguro y `remove-brick ... force` es peligroso? ¿Qué se pierde con `force`?
- **P6.3** En `replace-brick ... commit force`, ¿cómo se puebla de datos el brick nuevo si está vacío? ¿Qué componente hace el trabajo?
- **P6.4** Al agregar bricks a un volumen con réplica, ¿por qué deben añadirse **en múltiplos del replica count**? ¿Qué pasa si intentás agregar un solo brick a un `replica 3`?

---

## Ejercicio 7 — Awareness de Geo-Replication

**Geo-Replication** provee replicación **asíncrona** master → slave sobre WAN (SSH + rsync/tar+ssh), pensada para disaster recovery entre sitios geográficos. A diferencia de AFR (síncrona, dentro del cluster), tolera latencia alta y no bloquea las escrituras del master.

**Pasos (esquema conceptual — el slave es otro pool/volumen remoto):**

1. En el slave, creá un volumen destino `gv-slave` y en el master establecé confianza SSH (push-pem):

   ```bash
   # master (node1):
   gluster volume geo-replication gv0 slavenode::gv-slave create push-pem
   gluster volume geo-replication gv0 slavenode::gv-slave start
   ```

2. Consultá el estado de la sesión:

   ```bash
   gluster volume geo-replication gv0 slavenode::gv-slave status
   ```

   ```
   MASTER NODE  MASTER VOL  SLAVE                  STATUS     CRAWL STATUS       LAST_SYNCED
   node1        gv0         slavenode::gv-slave    Active     Changelog Crawl    2026-08-12 10:40:01
   node2        gv0         slavenode::gv-slave    Passive    N/A                N/A
   ```

**Preguntas de comprensión:**

- **P7.1** ¿Cuál es la diferencia esencial entre la replicación **AFR** (Ejercicio 4) y **Geo-Replication**? ¿Cuándo elegís cada una?
- **P7.2** En el `status`, un nodo aparece `Active` y otro `Passive`. ¿Por qué solo un nodo por replica set sincroniza, y qué pasa si el `Active` cae?
- **P7.3** ¿Qué es el **Changelog Crawl** y por qué es más eficiente que un `Hybrid/History Crawl` inicial?

---

## Ejercicio 8 — Diagnóstico avanzado y observabilidad

Cuando algo falla en producción, los logs y las herramientas de introspección son el primer recurso. GlusterFS registra todo bajo **`/var/log/glusterfs/`**.

**Pasos:**

1. Recorré los logs clave y correlacioná cada uno con su componente:

   ```bash
   ls -1 /var/log/glusterfs/
   ```

   ```
   glusterd.log                 # daemon de management
   glustershd.log               # self-heal daemon
   cli.log                      # comandos gluster ...
   bricks/data-brick1-gv0.log   # proceso glusterfsd de cada brick
   mnt-gv0.log                  # log del montaje FUSE (en el cliente)
   ```

2. Perfilá la carga de I/O del volumen en vivo:

   ```bash
   gluster volume profile gv0 start
   # ... generá tráfico desde el cliente ...
   gluster volume profile gv0 info | head -40
   gluster volume profile gv0 stop
   ```

3. Identificá los archivos y directorios más activos:

   ```bash
   gluster volume top gv0 read      | head
   gluster volume top gv0 write     | head
   gluster volume top gv0 open      | head
   ```

4. Volcá el estado interno de un brick (memoria, locks, inodos) para análisis profundo:

   ```bash
   gluster volume statedump gv0
   ls /var/run/gluster/*.dump.*   # o /var/log/glusterfs según versión
   ```

5. Obtené un snapshot completo de la configuración del nodo (útil para tickets y auditoría):

   ```bash
   gluster get-state
   cat /var/run/gluster/glusterd_state_*
   ```

6. Ante un problema de conectividad de peer, revisá el estado y reintentá:

   ```bash
   gluster peer status                  # ¿algún peer en 'Disconnected'?
   systemctl status glusterd            # ¿glusterd arriba en el peer afectado?
   tail -50 /var/log/glusterfs/glusterd.log
   ```

**Preguntas de comprensión:**

- **P8.1** Mapeá cada log a su proceso: `glusterd.log`, `glustershd.log`, `bricks/*.log`, `mnt-*.log`. ¿En qué máquina vive el log del montaje FUSE?
- **P8.2** ¿Para qué sirve `gluster volume profile` y qué tipo de problema de rendimiento detectás mirando la latencia por *fop* (file operation)?
- **P8.3** ¿Qué información expone un `statedump` que no ves en `volume status`, y en qué caso de soporte lo pedirían?
- **P8.4** Un peer aparece `Disconnected` en `gluster peer status` pero `ping` y SSH funcionan. Enumerá tres causas probables y cómo las verificás.

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 0

**P0.1** GlusterFS guarda sus metadatos (`trusted.gfid` — el GFID único de 128 bits de cada archivo/directorio, `trusted.afr.*` — los changelog counters de replicación, `trusted.glusterfs.dht` — el rango de hash del brick) como **extended attributes** en el namespace `trusted.`. Un inodo XFS de 256 bytes puede quedarse sin espacio inline para todos esos xattrs, forzando bloques extra y penalizando rendimiento; `isize=512` da holgura para almacenarlos inline. Si el filesystem subyacente no soporta xattrs en el namespace `trusted.` (o los limita), GlusterFS **no puede funcionar**: no puede identificar archivos por GFID ni llevar el registro de replicación. Por eso XFS (o ext4 con xattr) es obligatorio y FAT/exFAT quedan descartados.

**P0.2** Si el brick fuera el punto de montaje raíz (`/data/brick1`) y el disco **no monta** en el boot (label cambiado, disco muerto), `glusterfsd` arrancaría escribiendo en el **directorio de la raíz del sistema** que quedó debajo del montaje ausente, llenando `/` y creando un brick "fantasma" sin los xattrs correctos. Al usar un **subdirectorio** (`/data/brick1/gv0`), ese subdirectorio **no existe** si el disco no está montado, y `glusterfsd` se niega a arrancar el brick (falla ruidosamente) en lugar de corromper datos silenciosamente. Es la razón exacta por la que la doc oficial lo exige.

**P0.3** En 24007/tcp escucha **`glusterd`**, el daemon de management (además usa 24008 para RDMA management). En 49152/tcp y siguientes escucha **`glusterfsd`**, el proceso servidor de cada brick — GlusterFS asigna puertos dinámicamente desde 49152. Un nodo con **tres bricks** necesita **tres** puertos de brick (49152, 49153, 49154) abiertos, más el 24007 de management. El service `glusterfs` de firewalld abre el rango apropiado automáticamente.

### Ejercicio 1

**P1.1** `peer status` cuenta los peers **remotos** desde la perspectiva del nodo local: dos (node2 y node3), sin contarse a sí mismo. `pool list` incluye **al nodo local** (como `localhost`), por eso muestra los tres miembros del pool. Es la misma federación vista con dos convenciones distintas.

**P1.2** GlusterFS resuelve peers por hostname; si `node2` conoció a `node1` como una **IP** (porque no lo tenía en `/etc/hosts`), esa IP queda grabada en el estado del pool y cualquier cambio de IP o un brick definido con hostname vs. IP causará inconsistencias ("Peer Rejected", bricks que no matchean). La corrección canónica es hacer un `peer probe` **de vuelta hacia node1 por su hostname** desde node2 (`gluster peer probe node1`), lo que actualiza la entrada para usar el nombre. La prevención real es tener resolución de nombres consistente **antes** de sondear.

**P1.3** `glusterd` persiste todo bajo **`/var/lib/glusterd/`** (`peers/`, `vols/<volname>/`, `glusterd.info` con el UUID del nodo). Como cada `glusterd` replica esta configuración al resto del pool en cada cambio, **todos los peers tienen la misma vista** del cluster; por eso la CLI —que solo habla con el `glusterd` local— produce el mismo resultado desde cualquier nodo, y administrar desde node1 o node3 es equivalente.

### Ejercicio 2

**P2.1** `1 x 3 = 3` significa **1 distribute subvolume** (replica set), compuesto de **3 bricks** replicados entre sí, para un total de 3 bricks. `2 x 3 = 6` sería un **distributed-replicated**: 2 replica sets de 3 bricks cada uno, donde DHT reparte archivos entre los dos sets y AFR los replica dentro de cada set (6 bricks, tolerancia a 2 fallas simultáneas siempre que no sean del mismo set completo).

**P2.2** El **`glustershd`** (self-heal daemon) es un proceso por nodo que monta internamente el volumen y **cicatriza proactivamente** los archivos divergentes de los replica sets sin esperar a que un cliente los acceda. Aparece uno por nodo porque cada nodo hospeda bricks y participa del heal; su trabajo es recorrer el índice de heal (`.glusterfs/indices/xattrop`) y reconciliar réplicas usando los changelog xattrs de AFR.

**P2.3** Con `cluster.quorum-type auto` en réplica 3, las escrituras se permiten solo si **la mayoría** del replica set (≥2 de 3) está disponible. Si cae 1 brick, quedan 2 (mayoría) → se escribe. Si caen 2, queda 1 (minoría) → el volumen pasa a **solo-lectura** en ese replica set. Esto **previene split-brain**: dos particiones de red no pueden ambas aceptar escrituras divergentes porque ninguna minoría puede escribir; solo el lado con mayoría avanza.

**P2.4** `nfs.disable: on` deshabilita el servidor NFSv3 **interno** de GlusterFS (gnfs), que quedó deprecado. Para exportar un volumen por NFS hoy se usa **NFS-Ganesha** (servidor NFS en user-space con soporte NFSv3/v4 y el FSAL_GLUSTER), que se integra con GlusterFS y ofrece HA vía el cluster. El acceso nativo recomendado sigue siendo FUSE o libgfapi.

### Ejercicio 3

**P3.1** `_netdev` le indica a systemd/`mount` que el filesystem **depende de la red**: retrasa el montaje hasta que la red esté arriba en el boot y lo desmonta antes de bajar la red en el shutdown. Sin `_netdev`, el sistema intentaría montar el volumen GlusterFS antes de tener red, fallando el boot o dejando el montaje sin realizar.

**P3.2** El montaje FUSE contacta a `node1` **solo para descargar el volfile** (la definición del volumen). Si `node1` está caído al bootear, `mount -t glusterfs node1:/gv0` fallaría… salvo por `backup-volfile-servers=node2:node3`, que le da al cliente **servidores alternativos** de donde bajar el volfile: si node1 no responde, prueba node2, luego node3. Es puramente para la **fase de obtención del volfile**; una vez que el cliente tiene la topología, se conecta a los bricks por su cuenta.

**P3.3** Nada se interrumpe de forma fatal. Tras montar, el cliente FUSE mantiene conexiones **directas con todos los bricks**. Si `node1` cae después, el cliente sigue leyendo/escribiendo contra los bricks de `node2` y `node3` (réplica 3), y AFR marca a `node1` como divergente para healear cuando vuelva. El nodo del `mount` **no es un SPOF post-montaje**: fue solo el proveedor inicial del volfile.

**P3.4** El brick (`/data/brick1/gv0`) es el almacenamiento **crudo** de un solo servidor: ves solo la porción de ese nodo, con los archivos `.glusterfs/` internos y sin la vista unificada. El punto FUSE (`/mnt/gv0`) es el **volumen ensamblado** por los translators (DHT+AFR): vista global, coherente, con heal y quorum activos. Escribir directo en un brick corrompe el estado: crea archivos sin GFID ni xattrs de replicación, invisibles o inconsistentes para el resto del cluster, y puede inducir split-brain. **Los bricks son solo-lectura para humanos.**

### Ejercicio 4

**P4.1** `heal info` lista, por brick, los archivos que **ese brick considera que necesitan heal** — es decir, los que él tiene "buenos" y sabe que otra réplica tiene desactualizados (leyendo su índice `.glusterfs/indices/xattrop` y los changelog xattrs `trusted.afr.*`). Como node1 y node2 recibieron las escrituras 21–40 y node3 no, **ellos** marcan esos archivos como pendientes de propagar hacia node3; node3, que estaba caído, no registró nada, por eso su lista está vacía. La lista es "lo que hay que copiar **hacia** las réplicas atrasadas", no "lo que le falta a este brick".

**P4.2** Un **split-brain** ocurre cuando dos (o más) copias de un archivo en un replica set divergen y **ninguna** puede designarse automáticamente como la buena (cada brick cree que la otra copia es la desactualizada — changelog xattrs que se acusan mutuamente). Aparece cuando distintos subconjuntos de réplicas aceptaron escrituras conflictivas en particiones separadas. Réplica 2 sin arbiter es vulnerable: en una partición 1+1, si el quorum no lo impide, ambos lados pueden escribir y divergir. Réplica 3 con `quorum-type auto` lo evita porque **solo la mayoría (2/3) puede escribir**; el lado minoritario queda solo-lectura y no puede generar una versión conflictiva.

**P4.3** **Client-side quorum** (`cluster.quorum-type`, valores `none`/`auto`/`fixed`) actúa en el **cliente/AFR**: si el replica set no alcanza quorum, el cliente pone ese subvolumen en **solo-lectura** para no divergir. **Server-side quorum** (`cluster.server-quorum-type server` + `cluster.server-quorum-ratio`) actúa a nivel de **`glusterd`/pool**: si un nodo queda en la **partición minoritaria** del trusted pool, `glusterd` **apaga sus bricks** (glusterfsd) para que no sirvan datos aislados. El primero controla escrituras por replica set; el segundo mata bricks en la minoría del cluster.

**P4.4** `cluster.granular-entry-heal: on` mantiene un índice **granular** de qué **entradas específicas** de un directorio cambiaron durante la caída, en lugar de marcar el directorio entero como "necesita heal". Con millones de archivos, evita que el self-heal tenga que **recorrer y comparar directorios completos** (costosísimo); healea exactamente las entradas afectadas, reduciendo drásticamente tiempo de cicatrización y carga tras una falla.

### Ejercicio 5

**P5.1** El translator **DHT** (Distributed Hash Table) decide la ubicación: calcula un hash sobre el **nombre del archivo** y lo mapea al rango de hash asignado a cada brick (guardado en el xattr `trusted.glusterfs.dht` del directorio). En un volumen **puramente distributed** (sin réplica), si el brick que aloja un archivo muere, **ese archivo específico** queda inaccesible hasta que el brick vuelva — el resto del volumen sigue funcionando. Distributed = capacidad y throughput, **no** HA.

**P5.2** Con `disperse 3 redundancy 1` podés perder **1** brick sin perder datos (como RAID5). Espacio útil = (n − redundancy)/n = (3−1)/3 ≈ **66%**. Trade-off vs. réplica 3: dispersed usa **mucho menos espacio** (66% útil vs. 33%), pero paga con **más CPU** (cómputo de erasure coding en cada lectura/escritura) y **mayor latencia** (hay que contactar varios bricks y reconstruir); réplica 3 es más rápida y simple pero triplica el almacenamiento. Dispersed brilla en datos grandes, "cold/warm", donde el espacio importa más que la latencia.

**P5.3** Solo una parte. En `2 x 2 = 4` hay dos replica sets; la caída de **un** brick deja a su replica set operando con la copia superviviente (los archivos de ese set siguen disponibles y con quorum si aplica), y el **otro** replica set no se ve afectado. El volumen completo se pierde solo si **ambos** bricks de un mismo replica set caen simultáneamente.

**P5.4** `replica 2` sin arbiter es propenso a **split-brain** y, con `quorum-type auto`, un solo brick caído (1 de 2 no es mayoría) deja el set en solo-lectura → mala disponibilidad de escritura. `replica 3 arbiter 1` agrega un **tercer brick "arbiter"** que guarda **solo nombres y metadatos** (no los datos), a costo de espacio casi nulo. Ese arbiter **rompe empates** de quorum (2 de 3 votos) y provee la tercera opinión que impide split-brain, dando la seguridad de réplica 3 con el costo de espacio de réplica 2.

### Ejercicio 6

**P6.1** Al agregar bricks, DHT reparte el **espacio de hash** entre más bricks, pero los archivos **ya existentes** siguen mapeados según el layout viejo (y físicamente en los bricks originales). El `rebalance` **reasigna los rangos de hash** (fix-layout) y **migra los datos** a su nuevo brick de destino. `rebalance ... fix-layout start` **solo** actualiza el layout de directorios (los **nuevos** archivos usan los bricks nuevos, los viejos quedan donde están) — rápido y sin mover datos. `rebalance ... start` hace fix-layout **y además migra** los archivos existentes para equilibrar el uso — más lento pero balancea de verdad.

**P6.2** `remove-brick ... start` inicia una fase de **migración**: los datos que viven en los bricks a quitar se **evacúan** hacia los bricks que quedan; recién con `... commit` (tras verificar `status: completed`) se retiran. `remove-brick ... force` **elimina los bricks inmediatamente sin migrar**: todos los archivos que solo vivían allí **se pierden** del volumen. `force` solo es aceptable cuando ya sabés que no hay datos valiosos exclusivos en esos bricks.

**P6.3** El brick nuevo entra **vacío**; el **self-heal daemon (glustershd)** de AFR detecta que la réplica está atrasada respecto de las copias supervivientes del replica set y **copia todos los datos** hacia el brick nuevo (full heal). Por eso tras `replace-brick ... commit force` conviene lanzar `gluster volume heal <vol>` y monitorear `heal info` hasta que llegue a 0 entradas.

**P6.4** En un volumen con réplica, los bricks se organizan en grupos del tamaño del **replica count** (cada grupo es un replica set completo). Agregar bricks debe **completar replica sets enteros**: para `replica 3` hay que sumar bricks de a **3** (un nuevo replica set). Intentar agregar **un solo** brick a un `replica 3` es rechazado (`number of bricks is not a multiple of replica count`) porque dejaría un replica set incompleto; la alternativa es **aumentar el replica count** (p. ej. de replica 2 a 3, agregando un brick por set existente).

### Ejercicio 7

**P7.1** **AFR** es replicación **síncrona** dentro del cluster/LAN: cada escritura del cliente va a **todas** las réplicas antes de confirmarse → consistencia fuerte, tolerancia a fallas de nodo, pero sensible a latencia (no sirve sobre WAN). **Geo-Replication** es **asíncrona** master→slave sobre SSH: el master confirma la escritura localmente y **luego** propaga los cambios al slave remoto → tolera alta latencia y desconexiones, ideal para **DR entre datacenters/regiones**, a costa de un **lag** (el slave está algo atrasado, RPO > 0). Usás AFR para HA local; Geo-Rep para copia remota de contingencia.

**P7.2** Por cada replica set del master, **un solo nodo** hace de `Active` (sincroniza los cambios) mientras los otros están `Passive`, para **no duplicar el envío** de los mismos datos al slave (todos tienen las mismas copias). Si el nodo `Active` cae, uno de los `Passive` del mismo replica set **promociona a Active** automáticamente y continúa la sincronización — la sesión de geo-replicación sobrevive a la falla del nodo.

**P7.3** El **Changelog Crawl** consume el **changelog** que GlusterFS lleva de las operaciones (fops) del volumen y sincroniza **solo lo que cambió** desde el último punto sincronizado → muy eficiente en régimen estable. El **Hybrid/History (o Xsync) Crawl** se usa en el **arranque inicial** o cuando no hay changelog disponible: recorre el filesystem completo para establecer la línea base, lo cual es caro. Una vez alcanzado el estado corriente, la sesión pasa a Changelog Crawl.

### Ejercicio 8

**P8.1** `glusterd.log` → daemon de management (peers, volúmenes, quorum de servidor). `glustershd.log` → self-heal daemon (progreso y errores de heal). `bricks/<ruta>.log` → el proceso `glusterfsd` de **cada brick** (I/O, xattrs, fallas de disco). `mnt-<punto>.log` → el proceso **cliente FUSE** del montaje, y por lo tanto vive **en la máquina cliente** (`client1`), no en los servers. Todos bajo `/var/log/glusterfs/`.

**P8.2** `gluster volume profile` mide, por brick, **cuántas veces** y con **qué latencia** se ejecuta cada **fop** (LOOKUP, READ, WRITE, FSTAT, etc.), además de bytes leídos/escritos. Mirando la latencia por fop detectás **cuellos de botella**: p. ej. LOOKUP con latencia altísima delata metadata pesada / demasiados `stat` (típico de listar directorios enormes), o un brick con latencia muy superior a los demás señala un **disco/servidor degradado**. Es la herramienta de primera línea para tuning de rendimiento.

**P8.3** Un `statedump` vuelca el **estado interno de memoria** de un proceso brick: **locks** activos (inode/entry locks — útil para diagnosticar cuelgues por locks huérfanos), tablas de **inodos** abiertos, uso de **memoria por translator/mempool**, buffers, y estado de conexiones. `volume status` solo dice si el brick está online y su puerto/PID. El soporte de GlusterFS/Red Hat pide un statedump para investigar **hangs, leaks de memoria o locks colgados** que `status` no revela.

**P8.4** Peer `Disconnected` pese a que ping/SSH andan sugiere que el problema es **específico de GlusterFS**, no de red base. Tres causas y sus checks: (1) **`glusterd` caído o reiniciado** en el peer — `systemctl status glusterd` en el nodo afectado y revisar `glusterd.log`. (2) **Firewall bloqueando 24007/tcp** (management) — ping/SSH usan otros puertos; verificá con `firewall-cmd --list-services` o un `nc -vz node2 24007`. (3) **Peer en estado "Rejected"** por inconsistencia de configuración/UUID (checksum de volumen distinto, hostnames que no matchean) — se ve en `peer status` como `Peer Rejected` y se resuelve resincronizando `/var/lib/glusterd/` desde un peer sano y reiniciando `glusterd`. (También: reloj muy desfasado entre nodos rompiendo el handshake.)

</details>