# 362.2 Cluster Storage Access — Ejercicios guiados

Estos ejercicios construyen desde cero una pila completa de almacenamiento de bloques compartido: un **iSCSI target** que exporta LUNs (LIO/`targetcli`), uno o más **initiators** que los conectan (`open-iscsi`/`iscsiadm`), identificación estable de dispositivos (**WWID**, `scsi_id`, `/dev/disk/by-*`), acceso redundante con **DM-Multipath** y, finalmente, una pasada de reconocimiento sobre **Fibre Channel / FCoE**. Esta es exactamente la capa que se ubica *por debajo* de un sistema de archivos de clúster compartido (GFS2/OCFS2) — si te equivocás en la capa de bloques, el sistema de archivos que va encima se corrompe silenciosamente.

> Referencia oficial del objetivo: LPI Exam 306 Objectives, tema 362.2 — <https://www.lpi.org/our-certifications/exam-306-objectives/>

## Topología del laboratorio

Necesitás dos hosts Linux (las VMs sirven). Nombres y direcciones usados a lo largo del ejercicio:

| Rol | Hostname | IP primaria | IP secundaria (para multipath) |
|------|----------|-----------|------------------------------|
| SAN / iSCSI target | `sanbox` | `192.168.50.10` | `192.168.60.10` |
| Nodo de clúster / initiator | `node1` | `192.168.50.21` | `192.168.60.21` |

En `sanbox`, conectá un dispositivo de bloques de repuesto de 1 GiB (`/dev/vdb`) que se convertirá en el LUN exportado. Las IPs secundarias viven en una segunda NIC/subred y solo se necesitan para el Ejercicio 4.

Los nombres de los paquetes difieren según la distribución; se muestran ambas familias donde corresponde (`dnf` = RHEL/Fedora/Alma/Rocky, `apt` = Debian/Ubuntu). Ejecutá cada comando como `root` (o con `sudo`).

---

## Ejercicio 1 — Exportar un LUN desde un iSCSI target con `targetcli` (LIO)

El target **LIO** integrado en el kernel se maneja con el shell `targetcli`. Vas a crear un *backstore*, envolverlo en un *target* iSCSI (IQN), exponerlo como un *LUN* dentro de un *TPG*, publicar un *portal* y protegerlo con una *ACL*.

**En `sanbox`:**

1. Instalá y habilitá el servicio de target:

   ```bash
   # RHEL family
   dnf install -y targetcli
   systemctl enable --now target
   # Debian family
   apt install -y targetcli-fb
   systemctl enable --now rtslib-fb-targetctl
   ```

2. Creá un **block backstore** a partir del disco de repuesto (los block backstores pasan los comandos SCSI directamente y son lo que querés para LUNs de producción; `fileio` es la alternativa basada en archivo de imagen):

   ```bash
   targetcli /backstores/block create name=lun0 dev=/dev/vdb
   ```

   Salida esperada:

   ```
   Created block storage object lun0 using /dev/vdb.
   ```

3. Creá el **iSCSI target** con un IQN explícito (nunca dejes que se autogenere en un laboratorio sobre el que tenés que razonar):

   ```bash
   targetcli /iscsi create iqn.2020-01.club.cybercirujas:sanbox.target0
   ```

   Salida esperada:

   ```
   Created target iqn.2020-01.club.cybercirujas:sanbox.target0.
   Created TPG 1.
   Created default portal listening on all IPs (0.0.0.0), port 3260.
   ```

4. Mapeá el backstore dentro del TPG del target como **LUN 0**:

   ```bash
   targetcli /iscsi/iqn.2020-01.club.cybercirujas:sanbox.target0/tpg1/luns \
       create /backstores/block/lun0
   ```

5. Reemplazá el portal por defecto abierto de par en par por uno explícito en la subred de almacenamiento:

   ```bash
   TPG=/iscsi/iqn.2020-01.club.cybercirujas:sanbox.target0/tpg1
   targetcli $TPG/portals delete 0.0.0.0 3260
   targetcli $TPG/portals create 192.168.50.10 3260
   ```

6. Agregá una **ACL** para que solo el IQN del initiator de `node1` pueda hacer login (el valor por defecto `generate_node_acls` está desactivado, lo que significa que el acceso se deniega salvo que se conceda explícitamente):

   ```bash
   targetcli $TPG/acls create iqn.2020-01.club.cybercirujas:node1
   ```

7. Persistí la configuración e inspeccioná el árbol:

   ```bash
   targetcli saveconfig
   targetcli ls
   ```

   Salida esperada (abreviada):

   ```
   o- iscsi ........................................................ [Targets: 1]
   | o- iqn.2020-01.club.cybercirujas:sanbox.target0 ................ [TPGs: 1]
   |   o- tpg1 ........................................... [no-gen-acls, no-auth]
   |     o- acls ...................................................... [ACLs: 1]
   |     | o- iqn.2020-01.club.cybercirujas:node1 ............... [Mapped LUNs: 1]
   |     o- luns ...................................................... [LUNs: 1]
   |     | o- lun0 ......... [block/lun0 (/dev/vdb) (default_tg_pt_gp)]
   |     o- portals ................................................ [Portals: 1]
   |       o- 192.168.50.10:3260 ........................................... [OK]
   ```

8. Abrí el firewall para iSCSI:

   ```bash
   firewall-cmd --add-port=3260/tcp --permanent && firewall-cmd --reload   # firewalld
   # or: ufw allow 3260/tcp
   ```

> Fuentes: LIO / `targetcli-fb` — <https://github.com/open-iscsi/targetcli-fb> · Red Hat, *Configuring and managing storage devices → Getting started with iSCSI* — <https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_storage_devices/getting-started-with-iscsi_managing-storage-devices>

**Verificación de comprensión:**

- **1a.** Descomponé el IQN `iqn.2020-01.club.cybercirujas:sanbox.target0` en sus cuatro campos. ¿Qué hecho del mundo real afirma la porción `2020-01`, y por qué es una fecha y no una versión?
- **1b.** En la terminología de LIO, ¿cuál es la diferencia entre un *backstore*, un *LUN* y un *TPG*? ¿Cuál de ellos realmente contiene datos?
- **1c.** Creaste una ACL pero nunca configuraste una contraseña. ¿Es el target alcanzable por un initiator con un IQN distinto? ¿Qué único atributo del TPG cambiarías para aceptar *cualquier* initiator, y por qué es peligroso fuera de un laboratorio?
- **1d.** ¿Dónde escribió `saveconfig` la configuración persistente, y qué les pasa a los LUNs exportados después de un reinicio si te *olvidás* de ejecutarlo?

---

## Ejercicio 2 — Conectar el LUN desde el initiator con `open-iscsi`

Ahora consumí el LUN desde `node1`. El lado del initiator es la herramienta de administración `iscsiadm` más el demonio `iscsid`.

**En `node1`:**

1. Instalá las utilidades del initiator:

   ```bash
   dnf install -y iscsi-initiator-utils     # RHEL family
   apt install -y open-iscsi                # Debian family
   ```

2. Establecé el IQN del initiator para que coincida con la ACL que creaste en el Ejercicio 1 — esta es la identidad contra la que el target autentica:

   ```bash
   echo 'InitiatorName=iqn.2020-01.club.cybercirujas:node1' > /etc/iscsi/initiatorname.iscsi
   systemctl enable --now iscsid
   systemctl restart iscsid          # re-read the new InitiatorName
   ```

3. Configurá la persistencia del login en `/etc/iscsi/iscsid.conf` para que los nodos descubiertos se reconecten después de un reinicio:

   ```ini
   node.startup = automatic
   ```

4. Ejecutá el **descubrimiento SendTargets** contra el portal. Esto consulta al portal y registra cada target anunciado en la base de datos persistente de nodos bajo `/var/lib/iscsi/`:

   ```bash
   iscsiadm -m discovery -t sendtargets -p 192.168.50.10:3260
   ```

   Salida esperada:

   ```
   192.168.50.10:3260,1 iqn.2020-01.club.cybercirujas:sanbox.target0
   ```

5. Hacé **login** al target descubierto (es en este momento cuando aparece el dispositivo SCSI):

   ```bash
   iscsiadm -m node -T iqn.2020-01.club.cybercirujas:sanbox.target0 \
       -p 192.168.50.10:3260 --login
   ```

   Salida esperada:

   ```
   Logging in to [iface: default, target: iqn.2020-01...:sanbox.target0, portal: 192.168.50.10,3260]
   Login to [iface: default, target: iqn.2020-01...:sanbox.target0, portal: 192.168.50.10,3260] successful.
   ```

6. Confirmá el nuevo dispositivo de bloques y su ruta de transporte:

   ```bash
   lsblk --scsi
   ls -l /dev/disk/by-path/ | grep iscsi
   ```

   Salida esperada (abreviada):

   ```
   NAME HCTL       TYPE VENDOR   MODEL       TRAN
   sda  3:0:0:0    disk LIO-ORG  lun0        iscsi
   ...
   ip-192.168.50.10:3260-iscsi-iqn.2020-01.club.cybercirujas:sanbox.target0-lun-0 -> ../../sda
   ```

7. Inspeccioná la sesión activa con todo detalle:

   ```bash
   iscsiadm -m session -P 3
   ```

   Buscá `iSCSI Session State: LOGGED_IN`, los `HeaderDigest`/`DataDigest` negociados y el disco SCSI conectado.

8. Cerrá sesión limpiamente y observá cómo desaparece el dispositivo:

   ```bash
   iscsiadm -m node -T iqn.2020-01.club.cybercirujas:sanbox.target0 \
       -p 192.168.50.10:3260 --logout
   lsblk --scsi        # sda is gone
   ```

   Después volvé a hacer login (`--login`) — vas a necesitar el LUN conectado para los siguientes ejercicios.

> Fuentes: proyecto `open-iscsi` — <https://github.com/open-iscsi/open-iscsi> · Debian Wiki, *SAN/iSCSI* — <https://wiki.debian.org/SAN/iSCSI/open-iscsi>

**Verificación de comprensión:**

- **2a.** ¿Cuál es la diferencia práctica entre el *discovery* y el *login* de iSCSI? Después del discovery pero antes del login, ¿existe un dispositivo de bloques bajo `/dev`?
- **2b.** Cambiaste `/etc/iscsi/initiatorname.iscsi` y luego reiniciaste `iscsid`. ¿Por qué es obligatorio el reinicio, y qué error de login devolvería el target si este archivo no coincidiera con la ACL del Ejercicio 1?
- **2c.** `node.startup = automatic` vive en `iscsid.conf`, pero el discovery también estampó un valor por nodo en la base de datos de nodos. Si más tarde editás solo `iscsid.conf`, ¿cambia su comportamiento de arranque un nodo *ya descubierto*? ¿Cómo lo actualizás para un nodo existente con `iscsiadm`?
- **2d.** ¿Por qué es `/dev/disk/by-path/ip-192.168.50.10:3260-iscsi-...-lun-0` una referencia más segura en `/etc/fstab` que `/dev/sda`? ¿De qué depende `/dev/sda` que lo hace inestable entre reinicios?

---

## Ejercicio 3 — Identidad estable: WWID, `scsi_id` y `/dev/disk/by-id`

Antes de montar multipath encima, entendé *cómo se reconoce el mismo LUN físico a través de cada ruta y cada reinicio*. La clave es el **WWID** — el identificador SCSI persistente leído de la página VPD `0x83`, independiente de la letra `sdX`.

**En `node1` (con el LUN logueado):**

1. Extraé el WWID directamente del dispositivo:

   ```bash
   /usr/lib/udev/scsi_id --whitelisted --device=/dev/sda
   # equivalent short form:
   /usr/lib/udev/scsi_id -g -u -d /dev/sda
   ```

   Salida esperada (un prefijo `3` significa "NAA registered, page 0x83 designator"):

   ```
   36001405d9f8a1b2c3d4e5f60718293a4
   ```

2. Contrastá los enlaces simbólicos poblados por udev — el WWID aparece como un alias `scsi-` / `wwn-`:

   ```bash
   ls -l /dev/disk/by-id/ | grep -Ei 'sda$'
   ```

   Salida esperada:

   ```
   scsi-36001405d9f8a1b2c3d4e5f60718293a4 -> ../../sda
   wwn-0x6001405d9f8a1b2c3d4e5f60718293a4 -> ../../sda
   ```

3. Contrastá los tres espacios de nombres de identificadores que mantiene udev y observá *sobre qué se basa cada uno*:

   ```bash
   ls /dev/disk/by-id/     # content identity  → WWID / serial
   ls /dev/disk/by-path/   # topology          → transport + portal + LUN
   ls /dev/disk/by-uuid/   # filesystem        → mkfs-assigned UUID (only after a filesystem exists)
   ```

> Fuentes: nombrado persistente de dispositivos de `systemd`/`udev` — <https://www.freedesktop.org/software/systemd/man/latest/systemd.link.html> · página de manual `scsi_id(8)`.

**Verificación de comprensión:**

- **3a.** La salida de `scsi_id` empieza con `3`, y el enlace simbólico `wwn-` empieza con `0x6`. Explicá qué designa el `3` inicial y por qué las dos cadenas comparten por lo demás el mismo cuerpo hexadecimal.
- **3b.** Un LUN alcanzable por dos rutas aparece como `/dev/sda` y `/dev/sdb`. ¿Qué devuelve `scsi_id` para cada uno, y por qué es ese resultado el eje que permite a DM-Multipath *saber que son el mismo disco*?
- **3c.** Distinguí **WWID** de **WWN/WWNN/WWPN**. ¿Cuál de estos es un concepto de iSCSI, cuál es un concepto de Fibre Channel, y sobre cuál basa multipath su dispositivo?
- **3d.** ¿Por qué `/dev/disk/by-uuid/` para un LUN nuevo no devuelve nada, mientras que `/dev/disk/by-id/` ya tiene una entrada?

---

## Ejercicio 4 — Acceso redundante con DM-Multipath

Una sola ruta es un único punto de falla. Presentá el *mismo* LUN sobre *dos* portales (dos subredes) y dejá que **DM-Multipath** fusione los dos dispositivos `sdX` en un único `/dev/mapper/mpathX` que sobreviva a la pérdida de una ruta.

**En `sanbox`** — agregá el segundo portal para que el LUN sea alcanzable en ambas subredes:

1. ```bash
   TPG=/iscsi/iqn.2020-01.club.cybercirujas:sanbox.target0/tpg1
   targetcli $TPG/portals create 192.168.60.10 3260
   targetcli saveconfig
   ```

**En `node1`** — descubrí y logueá sobre *ambos* portales, luego habilitá multipath:

2. Descubrí y logueá también en la segunda ruta:

   ```bash
   iscsiadm -m discovery -t sendtargets -p 192.168.60.10:3260
   iscsiadm -m node -T iqn.2020-01.club.cybercirujas:sanbox.target0 \
       -p 192.168.60.10:3260 --login
   lsblk --scsi        # now BOTH sda and sdb, same LIO-ORG lun0
   ```

3. Instalá y habilitá multipath:

   ```bash
   # RHEL family
   dnf install -y device-mapper-multipath
   mpathconf --enable --with_multipathd y
   # Debian family
   apt install -y multipath-tools     # ships an active default /etc/multipath.conf
   systemctl enable --now multipathd
   ```

4. Mirá el mapa multipath ensamblado:

   ```bash
   multipath -ll
   ```

   Salida esperada:

   ```
   mpatha (36001405d9f8a1b2c3d4e5f60718293a4) dm-2 LIO-ORG,lun0
   size=1.0G features='0' hwhandler='1 alua' wp=rw
   `-+- policy='service-time 0' prio=50 status=active
     |- 3:0:0:0 sda 8:0  active ready running
     `- 4:0:0:0 sdb 8:16 active ready running
   ```

   Ambas rutas están en **un** grupo de prioridad → esto es del estilo `multibus`, ambas activas.

5. Fijá un alias estable y una política de **failover** editando `/etc/multipath.conf`. Vinculá sobre el WWID del Ejercicio 3, no sobre ningún nombre `sdX`:

   ```conf
   defaults {
       user_friendly_names   yes
       find_multipaths       yes
   }

   multipaths {
       multipath {
           wwid                    36001405d9f8a1b2c3d4e5f60718293a4
           alias                   cluster-data
           path_grouping_policy    failover
           path_selector           "service-time 0"
           no_path_retry           12
       }
   }
   ```

   Recargá y volvé a inspeccionar:

   ```bash
   systemctl reload multipathd     # or: multipathd reconfigure
   multipath -ll
   ```

   Salida esperada — ahora **dos** grupos de prioridad, solo uno activo (verdadero failover activo/en espera):

   ```
   cluster-data (36001405d9f8a1b2c3d4e5f60718293a4) dm-2 LIO-ORG,lun0
   size=1.0G features='1 queue_if_no_path' hwhandler='1 alua' wp=rw
   |-+- policy='service-time 0' prio=50 status=active
   | `- 3:0:0:0 sda 8:0  active ready running
   `-+- policy='service-time 0' prio=10 status=enabled
     `- 4:0:0:0 sdb 8:16 active ready running
   ```

6. Usá el dispositivo multipath — particionalo y expone las particiones con `kpartx`:

   ```bash
   parted -s /dev/mapper/cluster-data mklabel gpt mkpart data ext4 1MiB 100%
   kpartx -a -v /dev/mapper/cluster-data
   ls /dev/mapper/cluster-data*
   ```

   Salida esperada:

   ```
   /dev/mapper/cluster-data   /dev/mapper/cluster-data1
   ```

7. Manejá el demonio de forma interactiva para diagnósticos en vivo:

   ```bash
   multipathd -k
   multipathd> show topology
   multipathd> show paths
   multipathd> show config
   multipathd> quit
   ```

8. **Probá el failover.** Simulá la pérdida de una ruta haciendo logout de una ruta, y observá cómo el mapa se degrada pero sigue utilizable:

   ```bash
   iscsiadm -m node -T iqn.2020-01.club.cybercirujas:sanbox.target0 \
       -p 192.168.60.10:3260 --logout
   multipath -ll        # sdb now 'failed faulty'; sda still active → I/O continues
   ```

   Después restaurá la ruta (`--login`) y confirmá que vuelve a `active ready running`.

> Fuentes: Red Hat, *Configuring device mapper multipath* — <https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_device_mapper_multipath/index> · documentación del Device Mapper del kernel — <https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/> · `multipath.conf(5)`.

**Verificación de comprensión:**

- **4a.** En el paso 4 ambas rutas estaban en un grupo de prioridad; en el paso 5 se dividieron en dos. ¿Qué valor de `path_grouping_policy` produce cada disposición, y cuál es la diferencia operativa entre `multibus` y `failover` en cuanto a rendimiento vs. redundancia?
- **4b.** La sección `multipaths {}` vincula sobre `wwid`, nunca sobre `sda`/`sdb`. ¿Por qué vincular sobre la letra del dispositivo es un bug latente de corrupción de datos en un clúster?
- **4c.** Después de la configuración del alias, `features` ganó `queue_if_no_path` y estableciste `no_path_retry 12`. Describí con precisión qué le pasa al I/O en vuelo cuando fallan *todas* las rutas — ¿da error de inmediato, se encola para siempre, o algo intermedio? ¿Cuál es el riesgo de `queue_if_no_path` combinado con una suposición de desmontaje-limpio?
- **4d.** ¿Por qué se necesita `kpartx` para las particiones en `/dev/mapper/cluster-data` cuando un disco local corriente obtiene su `sda1` automáticamente? ¿Qué capa está sustituyendo `kpartx`?
- **4e.** Durante el failover del paso 8, `multipath -ll` seguía reportando el mapa como utilizable mientras una ruta estaba `faulty`. ¿Qué componente decidió seguir sirviendo I/O sobre la ruta sobreviviente, y dónde mirarías para confirmar que ningún error de I/O llegó al sistema de archivos?

---

## Ejercicio 5 — Reconocimiento: Fibre Channel y FCoE

El examen espera *reconocimiento* de FC/FCoE, incluso sin hardware dedicado. Inspeccioná las interfaces de sysfs que expone la clase de transporte FC (presentes siempre que un HBA FC o FCoE esté siendo gobernado; en un laboratorio puramente iSCSI estos directorios simplemente estarán vacíos — leé los comandos y la salida esperada).

**En un host con un HBA FC/FCoE:**

1. Enumerá los hosts FC y leé sus direcciones:

   ```bash
   ls /sys/class/fc_host/
   cat /sys/class/fc_host/host5/node_name    # WWNN — identifies the HBA/node
   cat /sys/class/fc_host/host5/port_name    # WWPN — identifies the individual port
   cat /sys/class/fc_host/host5/port_state   # e.g. Online
   ```

   Salida esperada:

   ```
   host5
   0x2000000e1e1a2b3c
   0x2100000e1e1a2b3c
   Online
   ```

2. Los mismos datos vía `sysfsutils`:

   ```bash
   systool -c fc_host -v
   ```

3. Listá todos los dispositivos SCSI y su transporte (los LUNs conectados por FC aparecen como discos SCSI corrientes):

   ```bash
   lsscsi --transport
   ```

4. Para **FCoE** específicamente, inspeccioná las interfaces de FCoE-sobre-Ethernet:

   ```bash
   fcoeadm -i        # interface info
   fcoeadm -t        # discovered targets
   ```

> Fuentes: LPI Exam 306 Objectives 362.2 — <https://www.lpi.org/our-certifications/exam-306-objectives/> · Red Hat, *Using Fibre Channel devices* — <https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_storage_devices/using-fibre-channel-devices_managing-storage-devices>

**Verificación de comprensión:**

- **5a.** Distinguí **WWNN** de **WWPN**. ¿Cuántos de cada uno tiene un HBA de doble puerto? ¿Con cuál coincide típicamente el zoning de SAN en el switch de la fabric?
- **5b.** FCoE transporta tramas de Fibre Channel sobre Ethernet. ¿Qué característica de Ethernet deben soportar los switches para que FCoE sea sin pérdidas, y por qué no podés correr FCoE sobre un segmento Ethernet de mejor esfuerzo arbitrario?
- **5c.** Tanto un LUN FC como un LUN iSCSI aparecen como un disco SCSI `/dev/sdX` corriente. Desde la perspectiva de DM-Multipath y el sistema de archivos por encima, ¿importa el transporte (FC vs. FCoE vs. iSCSI)? ¿Qué único identificador permite a multipath tratarlos a todos de manera uniforme?

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1
- **1a.** Campos: `iqn` (el tipo de nombrado), `2020-01` (año-mes), `club.cybercirujas` (autoridad de nombrado en DNS inverso) y `:sanbox.target0` (una cadena única opcional asignada por la autoridad). Según el RFC 3720, la fecha es el *primer mes en que la autoridad de nombrado fue dueña del nombre de dominio* usado en la porción de DNS inverso — garantiza unicidad global aunque el dominio cambie de manos más tarde. Deliberadamente **no** es una versión: ancla la propiedad, no el estado de release.
- **1b.** El **backstore** (`block/lun0` → `/dev/vdb`) es el objeto de almacenamiento real que contiene los datos. El **LUN** es un mapeo numerado que expone un backstore dentro de un target para que un initiator pueda direccionarlo. El **TPG** (Target Portal Group) es el contenedor que vincula portales, LUNs, ACLs y autenticación para un target. Solo el backstore contiene datos.
- **1c.** No — con `generate_node_acls` desactivado (el valor por defecto, mostrado como `no-gen-acls`) y una ACL explícita, solo `iqn.2020-01.club.cybercirujas:node1` puede hacer login; cualquier otro initiator es rechazado. Establecer el atributo del TPG `generate_node_acls=1` (a menudo junto con `authentication=0`, "demo mode") hace que el target acepte *cualquier* initiator sin ACL — conveniente en un laboratorio, catastrófico en producción porque cualquier host en la SAN puede montar y corromper el LUN.
- **1d.** `saveconfig` escribe `/etc/target/saveconfig.json`, que el servicio `target`/`rtslib-fb-targetctl` restaura al arrancar. Si te lo olvidás, la configuración en ejecución (en el kernel) se pierde en el reinicio — los LUNs, el target y los portales desaparecen silenciosamente y los initiators no logran hacer login.

### Ejercicio 2
- **2a.** El *discovery* (SendTargets) le pregunta a un portal qué targets anuncia y los registra en la base de datos de nodos (`/var/lib/iscsi/`) — no se crea ningún dispositivo. El *login* abre una sesión iSCSI real; solo entonces el kernel conecta el LUN como un disco SCSI `/dev/sdX`. Después del discovery pero antes del login, no existe ningún dispositivo de bloques.
- **2b.** `iscsid` lee `initiatorname.iscsi` al arrancar; sin un reinicio conserva el IQN viejo y la coincidencia de ACL del target falla. Un desajuste produce una falla de login como `iSCSI login failed due to authorization failure` (initiator no permitido) — la ACL se basa en el IQN del initiator.
- **2c.** No — cambiar `iscsid.conf` solo afecta a *futuros* descubrimientos. Un nodo ya descubierto conserva el valor de `node.startup` estampado en su registro por nodo en la base de datos. Actualizalo con:
  `iscsiadm -m node -T <iqn> -p <ip:port> -o update -n node.startup -v automatic`.
- **2d.** `/dev/sda` se asigna en orden de sondeo y puede apuntar a un disco distinto después de un reinicio o cuando cambia la cantidad de rutas; `/dev/disk/by-path/...` codifica el transporte, el portal y el LUN, así que siempre resuelve al mismo LUN independientemente del orden de enumeración. (`by-id`/WWID es aún más robusto — es independiente de la topología.)

### Ejercicio 3
- **3a.** El `3` inicial es el **código de tipo de designador/asociación SCSI** que `scsi_id` antepone (identificador NAA de la página VPD 0x83). El enlace simbólico `wwn-0x6...` es el valor NAA en crudo; el cuerpo hexadecimal compartido (`6001405…`) es el mismo identificador registrado, solo con prefijos distintos para las dos representaciones.
- **3b.** `scsi_id` devuelve el **WWID idéntico** para `/dev/sda` y `/dev/sdb`, porque el identificador proviene del propio LUN (VPD 0x83), no de la ruta. Esa identidad es precisamente lo que usa DM-Multipath para concluir que los dos dispositivos SCSI son dos rutas a un mismo disco y fusionarlos en un único dispositivo `dm-`.
- **3c.** El **WWID** es un identificador único SCSI genérico e independiente del transporte (funciona para iSCSI, FC, SAS, …) y es sobre lo que multipath basa su dispositivo. **WWN/WWNN/WWPN** son constructos de Fibre Channel — WWNN nombra el nodo/HBA, WWPN nombra un puerto FC individual. iSCSI usa IQNs, no WWNs.
- **3d.** `by-uuid` se puebla a partir de un UUID de *sistema de archivos* asignado por `mkfs`; un LUN en crudo todavía no tiene sistema de archivos, así que no hay entrada. `by-id`/WWID proviene de los propios datos de inquiry SCSI del dispositivo, que existen en el momento en que el LUN se conecta.

### Ejercicio 4
- **4a.** Un grupo de prioridad con ambas rutas activas = `path_grouping_policy multibus` (todas las rutas balanceadas simultáneamente — maximiza el rendimiento). Dos grupos con uno activo y uno en espera = `path_grouping_policy failover` (activo/en espera — maximiza el determinismo de la redundancia, una ruta a la vez). Compromiso: `multibus` usa el ancho de banda agregado pero envía I/O por cada ruta; `failover` mantiene una reserva caliente y solo conmuta ante una pérdida.
- **4b.** Los nombres `sdX` se asignan por orden de sondeo/enumeración y pueden reutilizarse para un LUN *distinto* después de un reinicio o cambio de ruta. Vincular multipath (o un montaje) a `sda` puede por lo tanto conectar silenciosamente el disco equivocado — en un clúster compartido eso significa escribir en los datos de otro nodo u otro LUN. El WWID es intrínseco al LUN y nunca se desplaza.
- **4c.** `queue_if_no_path` más `no_path_retry 12` significa: ante la pérdida total de rutas, el I/O en vuelo y el nuevo se **encolan** (no dan error) mientras multipath reintenta; el número `12` acota los intentos de reintento (aproximadamente `12 × polling_interval` segundos) antes de que el I/O finalmente falle de vuelta hacia el sistema de archivos. Así que no es ni un error inmediato ni un cuelgue infinito por defecto — es una cola acotada. El peligro de un `queue_if_no_path` *sin límite* (por ejemplo `no_path_retry queue`) es que los procesos se bloqueen en estado D ininterrumpible indefinidamente y el nodo no pueda desmontar ni hacer fencing limpiamente, que es exactamente lo que rompe un failover ordenado de clúster.
- **4d.** La tabla de particiones de un disco local la lee la capa de bloques del kernel, que autocrea `sda1`. Un dispositivo DM/multipath es un target virtual del device-mapper; el kernel no escanea automáticamente su tabla de particiones en nodos de dispositivo separados. `kpartx` lee la tabla de particiones y crea los mapeos del device-mapper `-partN` (`cluster-data1`) que reemplazan a las particiones que faltan generadas por el kernel.
- **4e.** `multipathd` (con el target `dm-multipath` del kernel) detectó la falla de ruta mediante su verificador de rutas, marcó `sdb` como faulty y siguió enrutando el I/O por la ruta activa sobreviviente — la falla nunca llega al sistema de archivos. Confirmá que el sistema de archivos no vio errores revisando `dmesg`/`journalctl -k` en busca de errores de I/O en el dispositivo `dm-` (debería haber mensajes de ruta caída pero ningún error de I/O a nivel del sistema de archivos) y `multipath -ll` mostrando la ruta sobreviviente todavía en `active ready running`.

### Ejercicio 5
- **5a.** El **WWNN** nombra el nodo (el HBA/adaptador completo); el **WWPN** nombra un puerto individual. Un HBA de doble puerto presenta típicamente **un WWNN y dos WWPNs** (uno por puerto). El zoning del switch SAN normalmente se hace por **WWPN**, porque el zoning controla qué puertos específicos pueden hablar en la fabric.
- **5b.** FCoE requiere **Ethernet sin pérdidas** — Data Center Bridging (DCB), específicamente Priority-based Flow Control (PFC, 802.1Qbb) — porque Fibre Channel asume un transporte sin descartes. La Ethernet corriente de mejor esfuerzo descarta tramas bajo congestión, algo que FC no tolera, así que FCoE no puede correr de forma fiable sobre un segmento de switch que carezca de DCB/PFC.
- **5c.** No — una vez que el LUN está conectado, el transporte es transparente para DM-Multipath y el sistema de archivos; todos se presentan como dispositivos SCSI `/dev/sdX`. El **WWID** (de la página VPD 0x83 de SCSI) es el único identificador que permite a multipath tratar de manera uniforme las rutas FC, FCoE e iSCSI hacia el mismo LUN.

</details>