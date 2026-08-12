# LPIC-3 306 · Tema 362.2 — Acceso al almacenamiento del clúster

> **Examen 306-300 (v3.0) · Peso del objetivo: 5**
> Los candidatos deben ser capaces de conectar un nodo Linux a almacenamiento de bloques remoto y gestionar el acceso redundante a él. Alcance: conceptos de SAN, Fibre Channel / FCoE, targets e initiators iSCSI (LIO/targetcli, open-iscsi/iscsiadm) y Device-Mapper Multipath I/O (DM-MPIO). Se trata de almacenamiento compartido a *nivel de bloque* — el sustrato sobre el que más tarde se apila un sistema de archivos de clúster (GFS2/OCFS2, objetivo 362.3) o un servicio gestionado por Pacemaker.

---

## 1. El problema de producción: por qué un clúster necesita almacenamiento de bloques remoto

Un clúster de alta disponibilidad existe para mover un servicio de un nodo caído a uno sano. Eso solo funciona si el *estado* que posee el servicio — un directorio de datos de PostgreSQL, un spool de correo, una imagen de VM — es alcanzable desde **todos** los nodos que podrían ejecutarlo. Si los datos viven en un disco local (`/dev/sda`), un fallo de nodo se lleva los datos con él, y el failover no tiene nada a lo que conmutar.

Hay dos respuestas arquitectónicas, y 362.2 es la base de la segunda:

| Modelo | Ubicación del estado | Responsabilidad de la consistencia | Objetivo |
|---|---|---|---|
| **Shared-nothing (replicado)** | Cada nodo mantiene su propia copia; una capa de replicación las mantiene sincronizadas | Motor de replicación (DRBD, streaming de base de datos) | 362.1 (DRBD) |
| **Shared-disk (almacenamiento compartido)** | Un dispositivo de bloques, físicamente externo, presentado a N nodos | Los nodos cooperan mediante un FS de clúster + DLM, y el fencing impone la exclusividad | **362.2 + 362.3** |

En el modelo shared-disk, el «disco» no es local. Vive en una **SAN (Storage Area Network)** — una cabina (NetApp, Dell/EMC, Pure, o una máquina Linux ejecutando LIO) que exporta **LUNs (Logical Unit Numbers)**: dispositivos de bloques direccionados sobre un protocolo de almacenamiento. Un nodo que inicia sesión en la SAN ve el LUN como un disco SCSI ordinario (`/dev/sdb`) aunque los platos (o la NAND) estén a metros o kilómetros de distancia.

De esto se derivan dos requisitos de producción ineludibles, y definen todo el objetivo:

1. **El transporte no debe ser un único punto de fallo.** Un cable, un switch, un puerto de HBA, una NIC — cualquiera de ellos puede fallar. Si el nodo alcanza el LUN a través de exactamente una ruta, esa ruta *es* un SPOF, y no habrás hecho más que reubicar el problema de disponibilidad del disco al cable. La respuesta es el **multipath**: presentar el mismo LUN por ≥2 rutas físicas independientes y dejar que `device-mapper` las fusione en un único dispositivo lógico que sobreviva a la pérdida de cualquier ruta individual. Por eso DM-MPIO es inseparable del almacenamiento de clúster.

2. **Los escritores concurrentes deben ser arbitrados.** Un LUN en crudo presentado a dos nodos no ofrece *ninguna* protección contra que ambos monten `ext4` y se corrompan mutuamente en segundos. El almacenamiento de bloques garantiza la entrega de bloques, no la coherencia de un sistema de archivos. La coherencia se impone por encima (FS de clúster + DLM, 362.3) y la exclusividad se impone mediante **fencing** — frecuentemente fencing de *almacenamiento* vía SCSI-3 Persistent Reservations (`fence_scsi`), cubierto en §5.6, que es donde se encuentran 362.2 y 361.2.

```
   ┌───────── node1 ─────────┐        ┌───────── node2 ─────────┐
   │  service (Pacemaker)    │        │  service (Pacemaker)    │
   │  /dev/mapper/mpatha     │        │  /dev/mapper/mpatha     │
   │   ▲            ▲        │        │   ▲            ▲        │
   │  HBA0        HBA1       │        │  HBA0        HBA1       │
   └───┼────────────┼────────┘        └───┼────────────┼────────┘
       │            │                     │            │
   ┌───┴──── fabric A ───┐            ┌───┴──── fabric B ───┐   (two independent
   │  switch A           │            │  switch B           │    switches / VLANs)
   └───────┬─────────────┘            └───────┬─────────────┘
           │                                  │
       ┌───┴──────────────── SAN array (LUN 0) ─────────────┴───┐
       │        one LUN, four paths (2 nodes × 2 fabrics)       │
       └────────────────────────────────────────────────────────┘
```

El resto de este objetivo trata de cómo construir, iniciar sesión, endurecer, aplicar multipath y diagnosticar esa imagen en Linux.

---

## 2. Comparación de transportes: FC, FCoE, iSCSI, NVMe-oF

El examen nombra FC, FCoE e iSCSI explícitamente y espera que razones sobre los trade-offs. NVMe-oF no está en la lista de objetivos de 306-300, pero se incluye aquí porque es hacia donde está migrando producción y afina la comparación.

| Propiedad | **Fibre Channel (FC)** | **FCoE** | **iSCSI** | *NVMe/TCP (contexto)* |
|---|---|---|---|---|
| Encapsulado | SCSI sobre tramas FC | Tramas FC sobre Ethernet sin pérdidas | SCSI sobre TCP/IP | NVMe sobre TCP/IP |
| Capa física | HBAs FC dedicados + switches FC | NICs 10GbE+ (CNA) + switches DCB | Cualquier NIC Ethernet | Cualquier NIC Ethernet |
| ¿Requiere fabric sin pérdidas? | Sí (buffer credits, nativo) | **Sí — DCB/PFC obligatorio** | No (TCP retransmite) | No |
| Enrutable entre subredes | No (fabric de capa 2) | No | **Sí** | Sí |
| Latencia típica | La más baja | Baja | Más alta (pila TCP) | Baja |
| Dirección del nodo | WWPN (`50:01:...`) | WWPN sobre MAC | IQN (`iqn.2026-08...`) | NQN |
| CapEx | Alto (fabric SAN separado) | Medio | **Bajo (reutiliza el equipo de LAN)** | Bajo |
| Habilidad operativa | Especialista (zoning) | Especialista (tuning de DCB) | **Generalista (TCP/IP)** | Generalista |
| Pila de target en Linux | — (lado cabina) | — | **LIO / targetcli** | LIO / SPDK |
| Initiator en Linux | Driver de HBA (`lpfc`, `qla2xxx`) | `fcoe`/`libfc` + `fcoeadm` | **open-iscsi / `iscsiadm`** | `nvme-cli` |
| Estado en RHEL 9 | Soportado | **Obsoleto / eliminado** | Totalmente soportado | Soportado, en alza |

**Cómo leer la tabla para el examen y para producción:**

- **iSCSI es la opción por defecto para una SAN Linux construida por uno mismo.** Corre sobre la LAN que ya tienes, es enrutable, y ambos extremos son Linux puro (target LIO, initiator open-iscsi). Su coste es CPU/latencia de la pila TCP/IP — mitigado con jumbo frames, una VLAN de almacenamiento dedicada y NICs con offload de iSCSI.
- **FC es el fabric empresarial establecido.** La latencia más baja, aislado por hardware de la LAN, pero caro y operado por especialistas en almacenamiento. En Linux el lado del initiator es en su mayoría «el driver del HBA presenta `/dev/sdX`»; no hay un *target* Linux que configurar para FC en este objetivo.
- **FCoE fue la apuesta por la convergencia** — llevar tramas FC sobre Ethernet para colapsar dos fabrics en uno. Exige una Ethernet **sin pérdidas** construida sobre **DCB (Data Center Bridging)**: PFC (Priority Flow Control, 802.1Qbb), ETS, DCBX. Nunca desplazó al FC nativo ni al iSCSI y está **obsoleto/eliminado en RHEL 8/9**. Aprende los términos (`fcoeadm`, `lldpad`, `dcbtool`, DCB, CNA) para el examen; no lo despliegues de nuevas.

### Implementaciones de target iSCSI en Linux

| Pila de target | Ruta en el kernel | Herramienta de config | Archivo de estado | Estado |
|---|---|---|---|---|
| **LIO (target_core_mod)** | En el kernel, desde 2.6.38 | **`targetcli`** (rtslib) | `/etc/target/saveconfig.json` | **Por defecto y estándar** (RHEL, SUSE, Debian) |
| **SCST** | Módulo de kernel fuera del árbol | `scstadmin` | `/etc/scst.conf` | Alto rendimiento, de nicho |
| **tgt (scsi-target-utils)** | Espacio de usuario (`tgtd`) | `tgtadm` / `/etc/tgt/targets.conf` | `targets.conf` | Heredado, en retirada |

**LIO es el target canónico y relevante para el examen** — es el target SCSI upstream integrado en el kernel y `targetcli` es su shell. Reconoce `tgtadm`/`targets.conf` como la alternativa más antigua en espacio de usuario, pero construye con `targetcli`.

---

## 3. Configuración e infraestructura completas

### 3.1 Topología de referencia

Dos nodos initiator alcanzan un único LUN de 50 GiB exportado por un target LIO, a través de **dos** IPs de portal para redundancia.

```
target host  san0     : 192.168.178.20 (fabric A), 192.168.178.21 (fabric B)
                        backstore = /dev/sdb (50 GiB), IQN target below
initiator    node1    : 192.168.178.31 / .41
initiator    node2    : 192.168.178.32 / .42

Target IQN    : iqn.2026-08.club.cybercirujas:san0.lun0
node1 IQN     : iqn.2026-08.club.cybercirujas:node1
node2 IQN     : iqn.2026-08.club.cybercirujas:node2
CHAP          : mutual (bidirectional)
```

### 3.2 Lado del target — LIO vía `targetcli` (construcción completa)

Paquetes (Debian/Ubuntu `targetcli-fb`, RHEL/Fedora/SUSE `targetcli`):

```console
root@san0:~# apt-get install -y targetcli-fb        # Debian/Ubuntu
root@san0:~# dnf install -y targetcli               # RHEL/Fedora/SUSE
root@san0:~# systemctl enable --now target.service
```

Construcción interactiva. Cada `create` se aplica al kernel en vivo de inmediato; `saveconfig` lo persiste.

```console
root@san0:~# targetcli
targetcli shell version 2.1.58
Copyright 2011-2013 by Datera, Inc and others.
For help on commands, type 'help'.

/> cd /backstores/block
/backstores/block> create name=lun0 dev=/dev/sdb
Created block storage object lun0 using /dev/sdb.

/backstores/block> cd /iscsi
/iscsi> create iqn.2026-08.club.cybercirujas:san0.lun0
Created target iqn.2026-08.club.cybercirujas:san0.lun0.
Created TPG 1.
Global pref auto_add_default_portal=true
Created default portal listening on all IPs (0.0.0.0), port 3260.
```

Como el portal por defecto se enlaza a `0.0.0.0:3260`, elimínalo y enlaza las dos IPs de fabric explícitas para que cada una mapee a una ruta distinta:

```console
/iscsi> cd iqn.2026-08.club.cybercirujas:san0.lun0/tpg1/portals
/iscsi/iqn.20...lun0/tpg1/portals> delete 0.0.0.0 3260
Deleted network portal 0.0.0.0:3260
/iscsi/iqn.20...lun0/tpg1/portals> create 192.168.178.20
Created network portal 192.168.178.20:3260.
/iscsi/iqn.20...lun0/tpg1/portals> create 192.168.178.21
Created network portal 192.168.178.21:3260.

/iscsi/iqn.20...lun0/tpg1/portals> cd ../luns
/iscsi/iqn.20...lun0/tpg1/luns> create /backstores/block/lun0
Created LUN 0.

/iscsi/iqn.20...lun0/tpg1/luns> cd ../acls
/iscsi/iqn.20...lun0/tpg1/acls> create iqn.2026-08.club.cybercirujas:node1
Created Node ACL for iqn.2026-08.club.cybercirujas:node1
Created mapped LUN 0.
/iscsi/iqn.20...lun0/tpg1/acls> create iqn.2026-08.club.cybercirujas:node2
Created Node ACL for iqn.2026-08.club.cybercirujas:node2
Created mapped LUN 0.
```

Impón **CHAP mutuo** en el TPG, luego las credenciales por ACL (el target autentica al initiator vía `userid/password`; el initiator autentica al target vía `mutual_userid/mutual_password`):

```console
/iscsi/iqn.20...lun0/tpg1/acls> cd ..
/iscsi/iqn.20...lun0/tpg1> set attribute authentication=1 generate_node_acls=0 demo_mode_write_protect=1
Parameter authentication is now '1'.
Parameter generate_node_acls is now '0'.
Parameter demo_mode_write_protect is now '1'.

/iscsi/iqn.20...lun0/tpg1> cd acls/iqn.2026-08.club.cybercirujas:node1
/iscsi/iqn.20...:node1> set auth userid=node1 password=S3cret-node1-in
Parameter userid is now 'node1'.
Parameter password is now 'S3cret-node1-in'.
/iscsi/iqn.20...:node1> set auth mutual_userid=san0 mutual_password=S3cret-target-out
Parameter mutual_userid is now 'san0'.
Parameter mutual_password is now 'S3cret-target-out'.
```

Verifica el árbol, luego persiste:

```console
/> ls
o- / ......................................................................... [...]
  o- backstores .............................................................. [...]
  | o- block .................................................. [Storage Objects: 1]
  | | o- lun0 ................................ [/dev/sdb (50.0GiB) write-thru activated]
  | |   o- alua ................................................... [ALUA Groups: 1]
  | |     o- default_tg_pt_gp ....................... [ALUA state: Active/optimized]
  | o- fileio ................................................. [Storage Objects: 0]
  | o- pscsi .................................................. [Storage Objects: 0]
  | o- ramdisk ................................................ [Storage Objects: 0]
  o- iscsi ............................................................ [Targets: 1]
  | o- iqn.2026-08.club.cybercirujas:san0.lun0 ......................... [TPGs: 1]
  |   o- tpg1 ............................................... [gen-acls disabled, auth]
  |     o- acls .......................................................... [ACLs: 2]
  |     | o- iqn.2026-08.club.cybercirujas:node1 ................. [Mapped LUNs: 1]
  |     | | o- mapped_lun0 ........................... [lun0 block/lun0 (rw)]
  |     | o- iqn.2026-08.club.cybercirujas:node2 ................. [Mapped LUNs: 1]
  |     |   o- mapped_lun0 ........................... [lun0 block/lun0 (rw)]
  |     o- luns .......................................................... [LUNs: 1]
  |     | o- lun0 .......... [block/lun0 (/dev/sdb) (default_tg_pt_gp)]
  |     o- portals .................................................... [Portals: 2]
  |       o- 192.168.178.20:3260 ............................................ [OK]
  |       o- 192.168.178.21:3260 ............................................ [OK]
  o- loopback ......................................................... [Targets: 0]

/> saveconfig
Configuration saved to /etc/target/saveconfig.json
/> exit
Global pref auto_save_on_exit=true
```

**`/etc/target/saveconfig.json` (estado persistido — nunca se edita a mano; es propiedad de `targetcli`):**

```json
{
  "storage_objects": [
    {
      "name": "lun0",
      "plugin": "block",
      "dev": "/dev/sdb",
      "write_back": false,
      "attributes": { "emulate_3pc": 1, "emulate_tpu": 1 },
      "wwn": "b7f4d2c1-9a3e-4f52-8c0d-2e1a6b7c9d84"
    }
  ],
  "targets": [
    {
      "wwn": "iqn.2026-08.club.cybercirujas:san0.lun0",
      "fabric": "iscsi",
      "tpgs": [
        {
          "tag": 1,
          "enable": true,
          "attributes": { "authentication": 1, "generate_node_acls": 0,
                          "demo_mode_write_protect": 1 },
          "node_acls": [
            {
              "node_wwn": "iqn.2026-08.club.cybercirujas:node1",
              "mapped_luns": [ { "index": 0, "tpg_lun": 0, "write_protect": false } ],
              "chap_userid": "node1", "chap_password": "S3cret-node1-in",
              "chap_mutual_userid": "san0", "chap_mutual_password": "S3cret-target-out"
            },
            {
              "node_wwn": "iqn.2026-08.club.cybercirujas:node2",
              "mapped_luns": [ { "index": 0, "tpg_lun": 0, "write_protect": false } ],
              "chap_userid": "node2", "chap_password": "S3cret-node2-in",
              "chap_mutual_userid": "san0", "chap_mutual_password": "S3cret-target-out"
            }
          ],
          "luns": [ { "index": 0, "storage_object": "/backstores/block/lun0" } ],
          "portals": [
            { "ip_address": "192.168.178.20", "port": 3260 },
            { "ip_address": "192.168.178.21", "port": 3260 }
          ]
        }
      ]
    }
  ]
}
```

Abre el firewall (el target escucha en TCP/3260):

```console
root@san0:~# firewall-cmd --permanent --add-service=iscsi-target && firewall-cmd --reload   # RHEL/SUSE
root@san0:~# nft add rule inet filter input tcp dport 3260 accept                            # nftables
```

### 3.3 Lado del initiator — open-iscsi (`iscsiadm`)

`/etc/iscsi/initiatorname.iscsi` — la identidad del nodo, debe coincidir exactamente con la ACL del target:

```ini
InitiatorName=iqn.2026-08.club.cybercirujas:node1
```

`/etc/iscsi/iscsid.conf` — la estrofa de producción esencial (CHAP mutuo + timeouts amigables con el failover):

```ini
# --- Startup: let multipathd own login, not the config ---
node.startup = automatic
node.leading_login = No

# --- Authentication: mutual (bidirectional) CHAP ---
node.session.auth.authmethod = CHAP
node.session.auth.username   = node1
node.session.auth.password   = S3cret-node1-in
node.session.auth.username_in = san0
node.session.auth.password_in = S3cret-target-out

# Same CHAP for the discovery phase (sendtargets)
discovery.sendtargets.auth.authmethod = CHAP
discovery.sendtargets.auth.username   = node1
discovery.sendtargets.auth.password   = S3cret-node1-in
discovery.sendtargets.auth.username_in = san0
discovery.sendtargets.auth.password_in = S3cret-target-out

# --- Timeouts: with multipath, fail the PATH fast so DM reroutes ---
# Default is 120s; that stalls I/O for 2 min before multipath sees a dead path.
node.session.timeo.replacement_timeout = 5
node.conn[0].timeo.noop_out_interval = 5
node.conn[0].timeo.noop_out_timeout  = 5

# Queue depth
node.session.queue_depth = 32
```

> **Regla de producción:** en una raíz iSCSI de *ruta única* o un volumen sin multipath, mantén `replacement_timeout = 120` (aguanta un breve parpadeo de la red). En un LUN *con multipath*, ponlo en **5** y deja que `no_path_retry` en `multipath.conf` se encargue de la decisión de encolado largo. Equivocarse en esto es la causa #1 de que «toda la máquina se cuelgue durante dos minutos cuando una NIC parpadea».

Habilita los daemons:

```console
root@node1:~# systemctl enable --now iscsid.service iscsi.service
```

### 3.4 Multipath — `/etc/multipath.conf` (completo, anotado)

```conf
defaults {
    user_friendly_names     yes          # name devices mpatha, mpathb... via /etc/multipath/bindings
    find_multipaths         yes          # only multipath devices with >1 path or an explicit wwid
    path_grouping_policy    group_by_prio # group paths by ALUA priority (active/optimized vs non-opt)
    path_selector           "service-time 0"  # send I/O to the path with lowest estimated service time
    path_checker            tur          # TEST UNIT READY probe; directio for arrays that mishandle TUR
    prio                    alua         # SCSI ALUA reports which paths are optimal
    failback                followover   # fail back only if the whole preferred group is healthy again
    no_path_retry           18           # queue I/O for 18 * polling_interval before erroring
    polling_interval        5            # seconds between path checks  (18 * 5 = 90s grace)
    max_fds                 8192
    dev_loss_tmo            60
    fast_io_fail_tmo        5
}

blacklist {
    devnode "^(ram|zram|raw|loop|fd|md|dm-|sr|scd|st|nvme)[0-9]*"
    devnode "^sd[a]$"                    # local root disk /dev/sda — never multipath it
    wwid    ".*"                         # default-deny; explicitly allow real SAN LUNs below
}

blacklist_exceptions {
    wwid "36001405b7f4d2c19a3e4f528c0d2e1a6"   # our LUN0 (from /lib/udev/scsi_id -g -u /dev/sdX)
}

multipaths {
    multipath {
        wwid    "36001405b7f4d2c19a3e4f528c0d2e1a6"
        alias   mpath-lun0               # stable app-facing name: /dev/mapper/mpath-lun0
    }
}

devices {
    device {
        vendor              "LIO-ORG"
        product             ".*"
        path_grouping_policy group_by_prio
        prio                alua
        path_checker        tur
        hardware_handler    "1 alua"
        failback            followover
        no_path_retry       18
    }
}
```

Decisiones clave de `multipath.conf` y sus trade-offs:

| Parámetro | Opciones | Trade-off |
|---|---|---|
| `path_grouping_policy` | `failover` / `multibus` / `group_by_prio` / `group_by_serial` | `failover` = 1 ruta activa (seguro, sin agregación de ancho de banda). `multibus` = todas las rutas activas (máximo throughput, requiere una cabina activo/activo real). `group_by_prio` = consciente de ALUA, el valor por defecto correcto para cabinas modernas. |
| `path_selector` | `round-robin 0` / `queue-length 0` / `service-time 0` | RR es ingenuo (el reparto equitativo ignora la latencia). `queue-length`/`service-time` se adaptan a la velocidad real de la ruta — prefiérelos en rutas heterogéneas. |
| `no_path_retry` | `fail` / `queue` / *N* | `fail` da error al instante (bueno para un FS de clúster que quiere fencing rápido). `queue` bloquea para siempre (arriesga procesos en estado D imposibles de matar en una caída total). *N* = encola durante N·`polling_interval` y luego falla — el término medio seguro. |
| `failback` | `manual` / `immediate` / *N* / `followover` | `immediate` puede provocar tormentas de flapping de rutas. `followover` solo hace failback cuando el grupo de rutas preferido se restaura por completo — lo más seguro para ALUA. |
| `path_checker` | `tur` / `directio` / `readsector0` / específico de cabina | `tur` es barato y universal; algunas cabinas necesitan `directio` o un checker del fabricante (`rdac`, `emc_clariion`). |

Habilita multipath:

```console
root@node1:~# mpathconf --enable --with_multipathd y      # RHEL helper; or edit conf directly
root@node1:~# systemctl enable --now multipathd.service
```

---

## 4. Flujo de trabajo por CLI con salida de terminal real

### 4.1 Descubrimiento e inicio de sesión (initiator)

```console
root@node1:~# iscsiadm -m discovery -t sendtargets -p 192.168.178.20:3260
192.168.178.20:3260,1 iqn.2026-08.club.cybercirujas:san0.lun0
192.168.178.21:3260,1 iqn.2026-08.club.cybercirujas:san0.lun0
```

`sendtargets` (`-t st`) devolvió **ambos** portales — esto es lo que hace posible el multipath a partir de un único descubrimiento. Inicia sesión en los registros de nodo descubiertos (ambos portales):

```console
root@node1:~# iscsiadm -m node -T iqn.2026-08.club.cybercirujas:san0.lun0 --login
Logging in to [iface: default, target: iqn.2026-08.club.cybercirujas:san0.lun0, portal: 192.168.178.20,3260]
Logging in to [iface: default, target: iqn.2026-08.club.cybercirujas:san0.lun0, portal: 192.168.178.21,3260]
Login to [iface: default, target: iqn.2026-08.club.cybercirujas:san0.lun0, portal: 192.168.178.20,3260] successful.
Login to [iface: default, target: iqn.2026-08.club.cybercirujas:san0.lun0, portal: 192.168.178.21,3260] successful.
```

Dos sesiones, una por portal:

```console
root@node1:~# iscsiadm -m session
tcp: [1] 192.168.178.20:3260,1 iqn.2026-08.club.cybercirujas:san0.lun0 (non-flash)
tcp: [2] 192.168.178.21:3260,1 iqn.2026-08.club.cybercirujas:san0.lun0 (non-flash)
```

El kernel ahora muestra el *mismo* LUN dos veces — `sdb` vía la sesión 1, `sdc` vía la sesión 2:

```console
root@node1:~# lsscsi
[7:0:0:0]    disk    LIO-ORG  lun0             4.0   /dev/sdb
[8:0:0:0]    disk    LIO-ORG  lun0             4.0   /dev/sdc

root@node1:~# lsblk -o NAME,SIZE,TYPE,VENDOR,WWN
NAME             SIZE TYPE VENDOR   WWN
sda               40G disk ATA
└─sda1            40G part
sdb               50G disk LIO-ORG  0x6001405b7f4d2c19a3e4f528c0d2e1a6
sdc               50G disk LIO-ORG  0x6001405b7f4d2c19a3e4f528c0d2e1a6
```

WWN idéntico en `sdb` y `sdc` — prueba de que son dos rutas a un mismo LUN, que es exactamente en lo que se basa multipath.

### 4.2 El WWID — cómo identifica multipath «el mismo disco»

```console
root@node1:~# /lib/udev/scsi_id -g -u -d /dev/sdb
36001405b7f4d2c19a3e4f528c0d2e1a6
root@node1:~# /lib/udev/scsi_id -g -u -d /dev/sdc
36001405b7f4d2c19a3e4f528c0d2e1a6
```

El `3` inicial es el tipo de designador NAA; el resto es el identificador de dispositivo del LUN de la página VPD 0x83. WWIDs coincidentes → multipathd fusiona las rutas.

### 4.3 Verifica el dispositivo multipath

```console
root@node1:~# multipath -ll
mpath-lun0 (36001405b7f4d2c19a3e4f528c0d2e1a6) dm-3 LIO-ORG,lun0
size=50G features='1 queue_if_no_path' hwhandler='1 alua' wp=rw
|-+- policy='service-time 0' prio=50 status=active
| `- 7:0:0:0 sdb 8:16 active ready running
`-+- policy='service-time 0' prio=10 status=enabled
  `- 8:0:0:0 sdc 8:32 active ready running

root@node1:~# ls -l /dev/mapper/
total 0
crw-------. 1 root root 10, 236 Aug 12 09:14 control
lrwxrwxrwx. 1 root root       7 Aug 12 09:41 mpath-lun0 -> ../dm-3
```

Cómo leer `multipath -ll`:
- `prio=50 status=active` vs `prio=10 status=enabled` → ALUA reporta el primer grupo como **Active/Optimized** y el segundo como **Active/Non-optimized**; DM envía la E/S al grupo prio-50 y mantiene el otro en reserva.
- `hwhandler='1 alua'` → el hardware handler ALUA del kernel está cargado.
- `features='1 queue_if_no_path'` → la E/S se encola en lugar de dar error cuando *todas* las rutas mueren (gobernado por `no_path_retry`).

Particiona el dispositivo multipath y expón las particiones con `kpartx`:

```console
root@node1:~# parted -s /dev/mapper/mpath-lun0 mklabel gpt mkpart primary 0% 100%
root@node1:~# kpartx -a -v /dev/mapper/mpath-lun0
add map mpath-lun0-part1 (253:4): 0 104855552 linear 253:3 2048
root@node1:~# ls /dev/mapper/mpath-lun0*
/dev/mapper/mpath-lun0  /dev/mapper/mpath-lun0-part1
```

Ahora formateas `/dev/mapper/mpath-lun0-part1` (con un FS de *clúster* como GFS2 para escritura compartida, o ext4/xfs solo si exactamente un nodo lo monta en cada momento, impuesto por el clúster).

### 4.4 Hacer el inicio de sesión persistente y limpio

```console
# Bring these node records up automatically at boot (already node.startup=automatic in iscsid.conf):
root@node1:~# iscsiadm -m node -T iqn.2026-08.club.cybercirujas:san0.lun0 -o update -n node.startup -v automatic

# Graceful teardown (flush multipath first, then logout, then delete records):
root@node1:~# multipath -f mpath-lun0
root@node1:~# iscsiadm -m node -T iqn.2026-08.club.cybercirujas:san0.lun0 --logout
Logging out of session [sid: 1, target: iqn.2026-08...san0.lun0, portal: 192.168.178.20,3260]
Logging out of session [sid: 2, target: iqn.2026-08...san0.lun0, portal: 192.168.178.21,3260]
Logout of [sid: 1 ...] successful.
Logout of [sid: 2 ...] successful.
root@node1:~# iscsiadm -m node -T iqn.2026-08.club.cybercirujas:san0.lun0 -o delete
```

### 4.5 Inspección del initiator de Fibre Channel (sin configuración, solo descubrimiento)

En FC el fabric/zoning está del lado de la cabina y del switch; el nodo Linux solo lee su HBA:

```console
root@node1:~# systool -c fc_host -v | egrep 'Class Device|port_name|port_state|speed'
  Class Device = "host7"
    port_name           = "0x50014380023d1a71"
    port_state          = "Online"
    speed               = "16 Gbit"

root@node1:~# cat /sys/class/fc_host/host7/port_name
0x50014380023d1a71
```

Reescanea el bus FC/SCSI después de que el equipo de almacenamiento mapee un nuevo LUN (sin necesidad de reiniciar):

```console
root@node1:~# rescan-scsi-bus.sh -a         # from sg3_utils
# or, per host, the LIP/rescan wildcard:
root@node1:~# echo "- - -" > /sys/class/scsi_host/host7/scan
# rescan an existing device that grew:
root@node1:~# echo 1 > /sys/block/sdb/device/rescan
```

---

## 5. Verificación y diagnóstico de fallos

### 5.1 La escalera de verificación (cada peldaño prueba más que el anterior)

| Pregunta | Comando | Señal saludable |
|---|---|---|
| ¿Es alcanzable el target por el cable? | `nc -vz 192.168.178.20 3260` | `Connection to ... succeeded!` |
| ¿Devuelve el descubrimiento los portales? | `iscsiadm -m discovery -t st -p <ip>` | una línea por portal |
| ¿Tuvo éxito CHAP y se formaron las sesiones? | `iscsiadm -m session` | un `tcp: [n] ...` por portal |
| ¿Enumeró el kernel el LUN? | `lsscsi` / `lsblk` | `LIO-ORG lun0` en ≥2 `sdX` |
| ¿Comparten las rutas un WWID? | `scsi_id -g -u -d /dev/sdX` | cadena idéntica en todas las rutas |
| ¿Las fusionó DM? | `multipath -ll` | un mapa, todas las rutas `active ready running` |
| ¿Funciona realmente el failover? | quita una ruta, observa `multipathd show paths` | ruta caída → `failed faulty`, la E/S continúa |

### 5.2 Shell interactiva de `multipathd` — la consola de diagnóstico en vivo

```console
root@node1:~# multipathd -k
multipathd> show paths
hcil     dev dev_t  pri dm_st  chk_st  dev_st  next_check
7:0:0:0  sdb 8:16   50  active  ready   running X........ 4/20
8:0:0:0  sdc 8:32   10  active  ready   running XX....... 3/20

multipathd> show maps status
name        failback queueing paths  dm-st  write_prot
mpath-lun0  -        -        2       active rw

multipathd> show config          # dump the *effective* merged config (defaults + your overrides)
multipathd> reconfigure          # re-read /etc/multipath.conf without a restart
multipathd> exit
```

`show config` es el comando más útil cuando el comportamiento no coincide con tu archivo: imprime lo que multipathd *realmente* computó tras fusionar los valores por defecto integrados de los dispositivos con tu bloque `devices{}` — de lo contrario, los valores integrados del fabricante te sobrescriben en silencio.

### 5.3 Simulacro de fallo de ruta (demuestra la redundancia antes de confiar en ella)

```console
# Snapshot: two live paths
root@node1:~# multipath -ll | grep -E 'sd[bc]'
| `- 7:0:0:0 sdb 8:16 active ready running
  `- 8:0:0:0 sdc 8:32 active ready running

# Simulate loss of fabric B by killing that session's connectivity
root@node1:~# iptables -A OUTPUT -d 192.168.178.21 -j DROP

# Within ~replacement_timeout the path drops; I/O keeps flowing on fabric A:
root@node1:~# multipath -ll
mpath-lun0 (36001405b7f4d2c19a3e4f528c0d2e1a6) dm-3 LIO-ORG,lun0
size=50G features='1 queue_if_no_path' hwhandler='1 alua' wp=rw
|-+- policy='service-time 0' prio=50 status=active
| `- 7:0:0:0 sdb 8:16 active ready  running
`-+- policy='service-time 0' prio=0  status=enabled
  `- 8:0:0:0 sdc 8:32 failed faulty  running

root@node1:~# dmesg -T | tail -3
[Wed Aug 12 09:52:11 2026] connection2:0: detected conn error (1020)
[Wed Aug 12 09:52:16 2026] sd 8:0:0:0: rejecting I/O to offline device
[Wed Aug 12 09:52:16 2026] device-mapper: multipath: Failing path 8:32.

# Restore and confirm followover failback
root@node1:~# iptables -D OUTPUT -d 192.168.178.21 -j DROP
root@node1:~# multipathd -k'show paths' | grep sdc
8:0:0:0  sdc 8:32   10  active  ready   running X........ 1/20
```

Si la E/S se *detuvo* en lugar de reencaminarse, tu `node.session.timeo.replacement_timeout` sigue en el valor por defecto de 120 (§3.3) — la ruta permaneció «arriba» en el kernel demasiado tiempo. Este simulacro es donde esa mala configuración sale a la luz.

### 5.4 Diagnóstico de los fallos comunes

| Síntoma | Causa raíz | Solución |
|---|---|---|
| `iscsiadm ... discovery` → `Login authentication failed` | Discordancia de CHAP o la ACL no incluye el IQN del initiator | Confirma que `initiatorname.iscsi` coincide con la ACL del target; revisa `node.session.auth.*` en ambos sentidos |
| El descubrimiento funciona, el login → `iscsid: Connection ... failed (503)` | La ACL del target no tiene `mapped_lun`, o `generate_node_acls=0` sin ninguna ACL | Añade la ACL del initiator + el LUN mapeado en `targetcli` |
| `multipath -ll` muestra solo **una** ruta | La segunda sesión nunca se formó, o los WWID difieren | `iscsiadm -m session`; si hay dos sesiones pero una ruta, compara `scsi_id`; revisa `find_multipaths`/blacklist |
| El LUN no tiene multipath en absoluto | El dispositivo fue capturado por `blacklist { wwid ".*" }` sin excepción | Añade su WWID a `blacklist_exceptions` |
| Las rutas oscilan `active`↔`failed` repetidamente | `failback immediate` en una cabina ALUA; o una NIC marginal | Pon `failback followover`; revisa `dmesg` en busca de errores de conexión |
| Todo el nodo se cuelga 2 min ante un parpadeo de NIC | `replacement_timeout=120` en un LUN con multipath | Ponlo en `5`; traslada la decisión de encolado largo a `no_path_retry` |
| Procesos atascados en estado `D` tras una caída total | `no_path_retry queue` / `queue_if_no_path` nunca se rinde | Usa `no_path_retry <N>`; emergencia: `multipathd -k'disablequeueing map <name>'` |
| El nuevo LUN no es visible tras mapearlo la cabina | El bus SCSI no fue reescaneado | `rescan-scsi-bus.sh -a` o `echo "- - -" > /sys/class/scsi_host/hostX/scan` |
| Faltan las particiones `/dev/mapper/mpathaN` | No se ejecutó `kpartx` tras particionar | `kpartx -a -v /dev/mapper/<map>` |

Desbloqueo de emergencia de un mapa totalmente encolado (cuando todas las rutas han desaparecido y la E/S está atascada):

```console
root@node1:~# multipathd -k'disablequeueing map mpath-lun0'
ok
# I/O now errors out cleanly instead of hanging forever, releasing D-state processes.
```

### 5.5 Inspección en profundidad de la sesión iSCSI

```console
root@node1:~# iscsiadm -m session -P 3
Target: iqn.2026-08.club.cybercirujas:san0.lun0 (non-flash)
    Current Portal: 192.168.178.20:3260,1
    Persistent Portal: 192.168.178.20:3260,1
        **********
        Interface:
        **********
        Iface Name: default
        Iface Transport: tcp
        Iface Initiatorname: iqn.2026-08.club.cybercirujas:node1
        SID: 1
        iSCSI Connection State: LOGGED IN
        iSCSI Session State: LOGGED_IN
        Internal iscsid Session State: NO CHANGE
        ************************
        Negotiated iSCSI params:
        ************************
        HeaderDigest: None
        DataDigest: None
        MaxRecvDataSegmentLength: 262144
        FirstBurstLength: 65536
        MaxBurstLength: 262144
        ************************
        Attached SCSI devices:
        ************************
        Host Number: 7  State: running
        scsi7 Channel 00 Id 0 Lun: 0
            Attached scsi disk sdb  State: running
```

`iSCSI Session State: LOGGED_IN` en **ambos** SIDs es el listón de salud. `MaxRecvDataSegmentLength`/`FirstBurstLength` son los tamaños de PDU negociados — ajústalos con jumbo frames + `iscsid.conf` para el throughput.

### 5.6 Donde el almacenamiento se encuentra con el fencing — SCSI-3 Persistent Reservations

En un clúster shared-disk, el propio almacenamiento se convierte en el mecanismo de fencing. `fence_scsi` usa **SCSI-3 Persistent Reservations (PR)**: cada nodo registra una clave en el LUN; a un nodo que está siendo fenced se le *expropia* (preempt) su clave, tras lo cual la cabina rechaza sus escrituras — el nodo queda aislado de los datos aunque siga vivo y confundido (el escenario de split-brain).

```console
# Every node registers its unique key (integrate with Pacemaker's fence_scsi agent):
root@node1:~# sg_persist --out --register --param-sark=0x0a1b1001 /dev/mapper/mpath-lun0
root@node1:~# sg_persist --out --reserve --param-rk=0x0a1b1001 \
                --prout-type=5 /dev/mapper/mpath-lun0     # type 5 = Write Exclusive-Registrants Only

# Read who holds the reservation and which keys are registered:
root@node1:~# sg_persist --in --read-reservation /dev/mapper/mpath-lun0
  LIO-ORG   lun0              4.0
  Peripheral device type: disk
  PR generation=0x2, Reservation follows:
    Key=0x0a1b1001
    scope: LU_SCOPE,  type: Write Exclusive, registrants only

# Fence node2 by preempting its key (this is what fence_scsi does under Pacemaker):
root@node1:~# sg_persist --out --preempt-abort --param-rk=0x0a1b1001 \
                --param-sark=0x0a1b1002 --prout-type=5 /dev/mapper/mpath-lun0
```

Requisito para que esto funcione: el backstore debe anunciar soporte de PR (los backstores de bloque de LIO lo hacen). Verifica que `emulate_pr` esté activado y que el LUN exponga el VPD de PR. Esta es la razón por la que `fence_scsi` necesita un LUN *compartido* alcanzable por todos los nodos a través de multipath — que es exactamente la infraestructura que construye este objetivo.

---

## 6. Referencias

- LPI — Objetivos del Examen 306 (306-300, v3.0), Tema 362.2 Cluster Storage Access: <https://www.lpi.org/our-certifications/exam-306-objectives/>
- Documentación de Linux-IO Target (LIO) / `targetcli`: <https://linux-iscsi.org/wiki/Targetcli>
- `targetcli-fb` (fork de Datera usado por la mayoría de distribuciones): <https://github.com/open-iscsi/targetcli-fb>
- Proyecto Open-iSCSI (initiator, `iscsiadm`, `iscsid`): <https://github.com/open-iscsi/open-iscsi> · <https://www.open-iscsi.com/>
- The Linux Kernel — Documentación del target SCSI (LIO): <https://www.kernel.org/doc/html/latest/target/index.html>
- The Linux Kernel — Device Mapper multipath: <https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/dm-queue-length.html>
- multipath-tools upstream (multipathd, `multipath.conf`): <https://github.com/opensvc/multipath-tools>
- Red Hat — Configuring and Managing Storage Devices, *Using device mapper multipath*: <https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_and_managing_storage_devices/configuring-device-mapper-multipath_configuring-and-managing-storage-devices>
- Red Hat — Getting started with iSCSI (target and initiator): <https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_storage_devices/getting-started-with-iscsi_managing-storage-devices>
- SUSE Linux Enterprise — Storage Administration Guide (iSCSI, Multipath I/O): <https://documentation.suse.com/sles/html/SLES-all/cha-multipath.html>
- RFC 7143 — iSCSI (Internet Small Computer System Interface) Protocol (Consolidated): <https://www.rfc-editor.org/rfc/rfc7143>
- RFC 7144 — iSCSI SCSI Features (SAM, task management): <https://www.rfc-editor.org/rfc/rfc7144>
- `sg3_utils` (`sg_persist`, `rescan-scsi-bus.sh`) — SCSI-3 Persistent Reservations: <https://sg.danny.cz/sg/sg3_utils.html>
- Agente de fencing `fence_scsi` de Pacemaker (fence-agents): <https://github.com/ClusterLabs/fence-agents>
- Open-FCoE (`fcoeadm`, DCB — contexto/conocimiento): <https://github.com/openSUSE/open-fcoe>