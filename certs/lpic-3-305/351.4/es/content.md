# Tema 351.4: Libvirt Virtual Machine Management

> **Certificación:** LPIC-3 305-300 — Virtualization and Containerization · **Peso:** 15.0
> **Nivel:** Producción / SRE · Platform Architect
> **Alcance:** Arquitectura de libvirt, gestión de conexiones y nodos, dominios QEMU/Xen y snapshots, análisis de consumo de recursos, storage pools y volúmenes, redes virtuales, `libvirt-guests`, gestión de secrets y noción de oVirt.

---

## 1. Motivación y el problema arquitectónico de producción

### 1.1 El problema que resuelve libvirt

Un host de virtualización moderno rara vez ejecuta un único hypervisor de forma aislada. En un datacenter real conviven KVM/QEMU (el estándar de facto en Linux), a veces Xen (por razones de aislamiento o legacy), contenedores de sistema (LXC), y necesidades de storage y red heterogéneas (LVM, iSCSI, Ceph RBD, bridges, VLANs, SR-IOV). Cada uno de esos subsistemas expone su propia CLI, su propio formato de configuración y su propio ciclo de vida.

Sin una capa de abstracción, el resultado es lo que en SRE llamamos **acoplamiento al plano de control**: los playbooks de automatización, los sistemas de provisioning y el tooling de operación se escriben contra `qemu-system-x86_64` con 60 flags de línea de comando, contra `xl` para Xen, contra `lvcreate`/`iscsiadm` para el storage, y contra `ip`/`brctl` para la red. Migrar de un hypervisor a otro, o simplemente actualizar QEMU, rompe todo lo construido encima.

**libvirt** es la respuesta a ese problema. No es un hypervisor: es una **API de gestión estable, un daemon y un conjunto de drivers** que abstraen el hypervisor subyacente detrás de un modelo de objetos común (dominios, redes, storage pools, volúmenes, node devices, secrets, network filters). El contrato central de libvirt es su **estabilidad de API/ABI**: código escrito contra libvirt 1.0 sigue compilando y funcionando contra libvirt 10.x. Esa promesa es exactamente lo que un plano de control necesita para no reescribirse cada release.

```
   virt-install   virt-manager   virsh   terraform-provider-libvirt   Ansible
   OpenStack Nova   oVirt/RHV   KubeVirt (virt-launcher)   cockpit-machines
         │              │           │              │                    │
         └──────────────┴───────────┴──────────────┴────────────────────┘
                                     │
                        libvirt API (C, con bindings
                        Python/Go/Perl/Java/Rust)  ── ABI estable ──►
                                     │
                     ┌───────────────┴────────────────┐
                     │        libvirt daemons          │
                     │  (libvirtd monolítico  ó        │
                     │   virtqemud/virtnetworkd/...     │
                     │   modulares)                     │
                     └───────────────┬────────────────┘
        ┌────────────┬───────────────┼───────────────┬──────────────┐
     hypervisor    storage         network         nodedev        secret
   qemu/xen/lxc  dir/lvm/iscsi/  bridge/nat/     PCI/USB/SCSI     ceph/vtpm/
                 rbd/gluster    route/sriov                       luks/tls
```

### 1.2 Por qué le importa a un SRE / Platform Architect

- **Reproducibilidad y estado declarativo.** Cada dominio, red y pool es un documento XML versionable. `virsh dumpxml` → git → `virsh define`. El estado de un host se reconstruye desde texto, no desde la memoria de quien lo configuró.
- **Superficie de automatización única.** Terraform (`dmacvicar/libvirt`), Ansible (`community.libvirt`), OpenStack Nova, oVirt y KubeVirt hablan todos con la misma API. El conocimiento de `virsh` es transferible a todos ellos.
- **Separación de privilegios y auditoría.** libvirt integra polkit, SASL y TLS, registra a través de `virtlogd`/`auditd`, y aísla cada QEMU con SELinux/AppArmor (`svirt`). Es un punto de política, no solo un lanzador de procesos.
- **Observabilidad de recursos.** `virsh domstats` expone CPU, memoria, block I/O y red por dominio en un formato estable y scrapeable — el equivalente a `/metrics` para el fleet de VMs.

---

## 2. Arquitectura de libvirt en profundidad

### 2.1 Componentes

libvirt se descompone en tres piezas:

1. **La librería (`libvirt.so`)** con la que se enlaza cualquier cliente (`virsh`, bindings). Contiene los **drivers de cliente** que hablan por RPC con el daemon o, en el caso `session`, directamente con QEMU.
2. **El/los daemon(s)** que ejecutan la lógica privilegiada: crear el proceso QEMU, montar el storage, configurar el bridge, aplicar el label SELinux.
3. **Los drivers de servidor**, divididos en:
   - **Hypervisor drivers (primarios):** `qemu`, `xen` (via libxl), `lxc`, `vbox`, `bhyve`, `esx`, `vmware`.
   - **Drivers secundarios (compartidos):** `storage`, `network`, `nodedev`, `interface`, `secret`, `nwfilter`.

### 2.2 Transición de daemon monolítico a daemons modulares

Históricamente todo corría en un único `libvirtd`. Desde libvirt 5.6 y **por defecto en libvirt ≥ 7.x** (RHEL 9, Debian 12, Ubuntu 22.04+), el modelo es **modular**: un daemon por driver, cada uno activado por socket vía systemd. Esto reduce la superficie de fallo (un crash del driver de red no tumba los dominios en ejecución), mejora el arranque bajo demanda y permite políticas de seguridad más finas.

| Daemon monolítico | Daemon modular equivalente | Rol |
|---|---|---|
| `libvirtd` (qemu driver) | `virtqemud` | Dominios QEMU/KVM |
| `libvirtd` (xen driver) | `virtxend` | Dominios Xen (libxl) |
| `libvirtd` (lxc driver) | `virtlxcd` | Contenedores LXC |
| `libvirtd` (network) | `virtnetworkd` | Redes virtuales, bridges, NAT |
| `libvirtd` (storage) | `virtstoraged` | Storage pools y volúmenes |
| `libvirtd` (nodedev) | `virtnodedevd` | Dispositivos del host (PCI/USB) |
| `libvirtd` (secret) | `virtsecretd` | Secrets (Ceph, LUKS, vTPM) |
| `libvirtd` (nwfilter) | `virtnwfilterd` | Network filters |
| `libvirtd` (interface) | `virtinterfaced` | Interfaces físicas del host |
| `virtproxyd` | `virtproxyd` | Dispatcher de conexiones **remotas** al socket local correcto |
| `virtlogd` | `virtlogd` | Serie/consola de los guests, logs de QEMU |
| `virtlockd` | `virtlockd` | Lock manager de imágenes de disco |

**Punto de examen y de operación:** el monolítico y el modular son mutuamente excluyentes por driver. Migrar es:

```console
$ sudo systemctl stop libvirtd.service libvirtd{,-ro,-admin,-tcp,-tls}.socket
$ for drv in virtqemud virtnetworkd virtstoraged virtnodedevd virtsecretd virtnwfilterd; do
    sudo systemctl unmask ${drv}.socket ${drv}-ro.socket ${drv}-admin.socket
    sudo systemctl enable --now ${drv}.socket ${drv}-ro.socket ${drv}-admin.socket
  done
$ sudo systemctl disable --now libvirtd.service
```

`virtproxyd` es la clave del acceso remoto en el modelo modular: cuando un cliente se conecta por `qemu+ssh://` o `qemu+tls://`, `virtproxyd` recibe la conexión y la reenvía al socket Unix del daemon modular apropiado.

### 2.3 URIs de conexión: el direccionamiento de libvirt

Todo cliente libvirt apunta a un **URI de conexión** que codifica: driver + transporte + host + ruta.

```
driver[+transport]://[user@][host][:port]/[path][?extra]
```

| URI | Significado | Uso típico |
|---|---|---|
| `qemu:///system` | QEMU, daemon privilegiado del sistema, socket Unix local | **Producción.** VMs de sistema, con root/qemu, red bridged, storage en LVM/Ceph |
| `qemu:///session` | QEMU sin privilegios, por-usuario, sin daemon root | Desarrollo, desktop; red limitada (`slirp`/passt), storage en `$HOME` |
| `qemu+ssh://root@host/system` | Sistema remoto, RPC tunelizado por SSH | Gestión ad-hoc, sin abrir puertos |
| `qemu+tls://host/system` | Sistema remoto, RPC sobre TLS mutuo (puerto 16514) | Automatización, oVirt, migración en vivo |
| `qemu+tcp://host/system` | RPC sobre TCP plano (puerto 16509), auth SASL | Solo con SASL/Kerberos en red confiable |
| `xen:///system` | Dominios Xen locales | Hosts Xen |
| `lxc:///system` | Contenedores LXC de libvirt | Contenedores de sistema |
| `test:///default` | Driver mock in-memory | Testing de tooling sin hypervisor |

La variable `LIBVIRT_DEFAULT_URI` (o `uri_default` en `/etc/libvirt/libvirt.conf`) fija el destino por defecto y evita el error clásico de operar contra `qemu:///session` cuando se creía estar en `system`.

```console
$ export LIBVIRT_DEFAULT_URI=qemu:///system
$ virsh uri
qemu:///system
$ virsh -c qemu+ssh://root@hv-02.leloir.lan/system list --all
 Id   Name          State
------------------------------
 3    db-prod-01    running
 -    db-prod-02    shut off
```

### 2.4 Autenticación y autorización

- **Socket Unix + polkit (`qemu:///system`):** por defecto el acceso al socket read-write está gobernado por polkit. La regla estándar concede acceso al grupo `libvirt`. Sin pertenecer a él, se obtiene un prompt de polkit o `permission denied`.
- **SASL:** para `qemu+tcp`/`qemu+tls`, `sasldb` o GSSAPI (Kerberos). Se gestiona con `saslpasswd2 -a libvirt`.
- **TLS mutuo:** CA propia; `cacert.pem`, `servercert.pem`/`serverkey.pem` en el host, `clientcert.pem`/`clientkey.pem` en el cliente, bajo `/etc/pki/libvirt*/` y `/etc/pki/CA/`.

`/etc/libvirt/` es el árbol de configuración canónico:

```
/etc/libvirt/
├── libvirtd.conf            # daemon monolítico (o virtqemud.conf, virtnetworkd.conf, ...)
├── qemu.conf                # driver QEMU: usuario/grupo, security_driver, cgroups, hugepages
├── libvirt.conf             # cliente: aliases de URI, uri_default
├── qemu/                    # XML persistente de dominios (¡no editar a mano!)
│   ├── web-prod-01.xml
│   ├── autostart/           # symlinks de dominios con autostart
│   └── networks/
├── storage/                 # XML persistente de storage pools
├── secrets/                 # metadatos de secrets (el valor va aparte)
└── nwfilter/                # network filters
```

**Regla de oro:** nunca se editan los XML bajo `/etc/libvirt/qemu/` directamente. Se usa `virsh edit <dom>`, que valida contra el schema RNG y recarga en caliente. Editar el archivo a mano y no hacer `virsh define` deja el estado en disco divergente del estado en memoria del daemon.

---

## 3. Comparativas técnicas y trade-offs

### 3.1 `qemu:///system` vs `qemu:///session`

| Dimensión | `qemu:///system` | `qemu:///session` |
|---|---|---|
| Daemon | Privilegiado (root), compartido | Por-usuario, sin root |
| Proceso QEMU corre como | Usuario `qemu`/`libvirt-qemu` (via `qemu.conf`) | El usuario invocante |
| Red | Bridges, NAT (`default`), macvtap, SR-IOV | `passt`/`slirp` (user-mode) o red preconfigurada |
| Storage | `/var/lib/libvirt/images`, LVM, iSCSI, Ceph | `~/.local/share/libvirt/images` |
| Autostart en boot | Sí (`libvirt-guests`) | No (ligado a la sesión) |
| Aislamiento sVirt | SELinux/AppArmor completo | Limitado |
| Caso de uso | **Producción, servidores** | Desktop, dev, CI sin privilegios |

### 3.2 Transportes de conexión remota

| Transporte | Puerto | Cifrado | Auth | Latencia RPC | Recomendación |
|---|---|---|---|---|---|
| `unix` | — (socket) | N/A (local) | polkit | Mínima | Local siempre |
| `ssh` | 22 | Sí (SSH) | Claves SSH | Media (túnel) | Ad-hoc, ops manuales |
| `tls` | 16514 | Sí (x509 mutuo) | Certificados | Baja | **Automatización, migración** |
| `tcp` | 16509 | **No** | SASL/GSSAPI | Baja | Solo red aislada + SASL |
| `libssh2`/`libssh` | 22 | Sí | Claves | Media | Igual que ssh, sin binario `ssh` |

### 3.3 Tipos de storage pool

| Tipo (`pool type`) | Backend | Thin/Snapshot | Live migration | Caso de uso |
|---|---|---|---|---|
| `dir` | Directorio + archivos qcow2/raw | qcow2: sí | Requiere FS compartido | Dev, single-host |
| `fs` | FS sobre un block device | Igual que dir | No | Aislamiento de un LUN |
| `netfs` | NFS/CIFS montado | qcow2: sí | **Sí** (FS compartido) | Cluster pequeño |
| `logical` | LVM Volume Group | LVM snapshots | No (local) | Rendimiento raw local |
| `disk` | Particiones de un disco | No | No | Legacy |
| `iscsi` / `iscsi-direct` | Target iSCSI | En el array | **Sí** | SAN clásica |
| `scsi` | HBA SCSI/FC | En el array | Sí | Fibre Channel |
| `mpath` | Multipath devices | En el array | Sí | SAN con MPIO |
| `rbd` | **Ceph RBD** | RBD snap/clone | **Sí** | **Cloud/HCI a escala** |
| `gluster` | GlusterFS | qcow2/gluster | Sí | Almacenamiento distribuido |
| `zfs` | ZFS zvol | ZFS snapshots | No | Local con snapshots baratos |

### 3.4 Modos de forwarding de red virtual

| `forward mode` | Conectividad | L2 con host físico | Rendimiento | Caso de uso |
|---|---|---|---|---|
| (ninguno) — *isolated* | Solo guest↔guest | No | Alto | Redes internas, backend privado |
| `nat` (default) | Guests → exterior via NAT | No (IP privada) | Medio | Labs, dev, salida sin IP pública |
| `route` | Ruteo sin NAT | Sí (routing) | Alto | IPs enrutables, sin masquerade |
| `open` | Como route, sin reglas firewall auto | Sí | Alto | Firewall gestionado externamente |
| `bridge` (a `virbrX`/`br0` existente) | L2 plano con la LAN | **Sí** | Alto | **Producción, VMs como hosts LAN** |
| `hostdev` (SR-IOV VF) | PCI passthrough de VF | Sí | **Máximo** (near-native) | NFV, baja latencia, 25/100G |
| macvtap `private/vepa/bridge/passthrough` | Sobre NIC física | Depende del modo | Alto | Sin bridge software |

---

## 4. Manifiestos completos (Domain XML e infraestructura)

> El formato nativo de libvirt es **XML validado contra RNG**, no YAML. Al final de la sección se incluyen los equivalentes declarativos en YAML (Ansible) y HCL (Terraform) que se usan en producción para envolver estos manifiestos.

### 4.1 Dominio KVM de producción — completo

VM de producción con Q35 + UEFI, `host-passthrough`, hugepages, pinning de vCPU a NUMA, disco sobre **Ceph RBD** con auth por secret, virtio-scsi, guest agent y RNG.

```xml
<domain type='kvm'>
  <name>web-prod-01</name>
  <uuid>4c1e2f60-8a3d-4b21-9f0c-2b7e5d3a91aa</uuid>
  <title>Frontend Nginx - prod cluster A</title>
  <metadata>
    <libosinfo:libosinfo xmlns:libosinfo="http://libosinfo.org/xmlns/libvirt/domain/1.0">
      <libosinfo:os id="http://debian.org/debian/12"/>
    </libosinfo:libosinfo>
  </metadata>

  <memory unit='KiB'>8388608</memory>
  <currentMemory unit='KiB'>8388608</currentMemory>
  <memoryBacking>
    <hugepages>
      <page size='2048' unit='KiB'/>
    </hugepages>
    <source type='memfd'/>
    <access mode='shared'/>
    <allocation mode='immediate'/>
  </memoryBacking>

  <vcpu placement='static'>4</vcpu>
  <cputune>
    <vcpupin vcpu='0' cpuset='2'/>
    <vcpupin vcpu='1' cpuset='3'/>
    <vcpupin vcpu='2' cpuset='4'/>
    <vcpupin vcpu='3' cpuset='5'/>
    <emulatorpin cpuset='0-1'/>
    <iothreadpin iothread='1' cpuset='0-1'/>
  </cputune>
  <iothreads>1</iothreads>

  <os firmware='efi'>
    <type arch='x86_64' machine='pc-q35-8.2'>hvm</type>
    <firmware>
      <feature enabled='yes' name='enrolled-keys'/>
      <feature enabled='yes' name='secure-boot'/>
    </firmware>
    <loader readonly='yes' secure='yes' type='pflash'>/usr/share/OVMF/OVMF_CODE_4M.secboot.fd</loader>
    <nvram template='/usr/share/OVMF/OVMF_VARS_4M.fd'>/var/lib/libvirt/qemu/nvram/web-prod-01_VARS.fd</nvram>
    <boot dev='hd'/>
    <bootmenu enable='no'/>
  </os>

  <features>
    <acpi/>
    <apic/>
    <smm state='on'/>
    <vmport state='off'/>
  </features>

  <cpu mode='host-passthrough' check='none' migratable='on'>
    <topology sockets='1' dies='1' cores='4' threads='1'/>
    <feature policy='require' name='tsc-deadline'/>
    <feature policy='disable' name='rdrand'/>
    <numa>
      <cell id='0' cpus='0-3' memory='8388608' unit='KiB' memAccess='shared'/>
    </numa>
  </cpu>

  <clock offset='utc'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
  </clock>

  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>restart</on_crash>

  <pm>
    <suspend-to-mem enabled='no'/>
    <suspend-to-disk enabled='no'/>
  </pm>

  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>

    <!-- Disco raíz sobre Ceph RBD, auth por secret -->
    <disk type='network' device='disk'>
      <driver name='qemu' type='raw' cache='none' io='native' discard='unmap' iothread='1'/>
      <source protocol='rbd' name='libvirt-pool/web-prod-01.root'>
        <host name='10.20.0.10' port='6789'/>
        <host name='10.20.0.11' port='6789'/>
        <host name='10.20.0.12' port='6789'/>
      </source>
      <auth username='libvirt'>
        <secret type='ceph' uuid='2f9c8b1a-5d4e-4c3b-8a7f-1e0d9c8b7a6f'/>
      </auth>
      <target dev='sda' bus='scsi'/>
      <blockio logical_block_size='512' physical_block_size='4096'/>
      <address type='drive' controller='0' bus='0' target='0' unit='0'/>
    </disk>

    <controller type='scsi' index='0' model='virtio-scsi'>
      <driver queues='4' iothread='1'/>
      <address type='pci' domain='0x0000' bus='0x03' slot='0x00' function='0x0'/>
    </controller>
    <controller type='usb' index='0' model='qemu-xhci' ports='8'/>
    <controller type='pci' index='0' model='pcie-root'/>
    <controller type='pci' index='1' model='pcie-root-port'/>

    <!-- Interfaz virtio con multiqueue en el bridge de producción -->
    <interface type='network'>
      <mac address='52:54:00:6c:3a:1f'/>
      <source network='prod-br'/>
      <model type='virtio'/>
      <driver name='vhost' queues='4'/>
      <mtu size='9000'/>
      <address type='pci' domain='0x0000' bus='0x01' slot='0x00' function='0x0'/>
    </interface>

    <!-- Canal para el QEMU guest agent -->
    <channel type='unix'>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
      <address type='virtio-serial' controller='0' bus='0' port='1'/>
    </channel>

    <serial type='pty'>
      <target type='isa-serial' port='0'>
        <model name='isa-serial'/>
      </target>
    </serial>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>

    <memballoon model='virtio'>
      <stats period='10'/>
      <address type='pci' domain='0x0000' bus='0x04' slot='0x00' function='0x0'/>
    </memballoon>

    <rng model='virtio'>
      <backend model='random'>/dev/urandom</backend>
      <address type='pci' domain='0x0000' bus='0x05' slot='0x00' function='0x0'/>
    </rng>

    <watchdog model='itco' action='reset'/>

    <graphics type='vnc' port='-1' autoport='yes' listen='127.0.0.1'>
      <listen type='address' address='127.0.0.1'/>
    </graphics>
    <video>
      <model type='virtio' heads='1' primary='yes'/>
    </video>
  </devices>

  <!-- sVirt: label SELinux dinámico por dominio -->
  <seclabel type='dynamic' model='selinux' relabel='yes'/>
</domain>
```

### 4.2 Storage pool — Ceph RBD

```xml
<pool type='rbd'>
  <name>libvirt-pool</name>
  <uuid>7b3d0a11-9c2e-4f88-b6a1-0d5e4c3b2a19</uuid>
  <source>
    <name>libvirt-pool</name>
    <host name='10.20.0.10' port='6789'/>
    <host name='10.20.0.11' port='6789'/>
    <host name='10.20.0.12' port='6789'/>
    <auth username='libvirt' type='ceph'>
      <secret uuid='2f9c8b1a-5d4e-4c3b-8a7f-1e0d9c8b7a6f'/>
    </auth>
  </source>
</pool>
```

### 4.3 Storage pool — LVM (logical)

```xml
<pool type='logical'>
  <name>vg-vms</name>
  <source>
    <name>vg_vms</name>
    <format type='lvm2'/>
  </source>
  <target>
    <path>/dev/vg_vms</path>
  </target>
</pool>
```

### 4.4 Volume XML (qcow2 con backing file — thin clone)

```xml
<volume type='file'>
  <name>db-prod-02.qcow2</name>
  <capacity unit='GiB'>100</capacity>
  <allocation unit='GiB'>0</allocation>
  <target>
    <path>/var/lib/libvirt/images/db-prod-02.qcow2</path>
    <format type='qcow2'/>
    <permissions>
      <mode>0600</mode>
      <owner>64055</owner>
      <group>64055</group>
    </permissions>
  </target>
  <backingStore>
    <path>/var/lib/libvirt/images/debian12-golden.qcow2</path>
    <format type='qcow2'/>
  </backingStore>
</volume>
```

### 4.5 Red virtual — bridge de producción con VLAN y port isolation

```xml
<network>
  <name>prod-br</name>
  <uuid>9e1f2a3b-4c5d-6e7f-8a9b-0c1d2e3f4a5b</uuid>
  <forward mode='bridge'/>
  <bridge name='br0'/>
  <vlan>
    <tag id='100'/>
  </vlan>
  <portgroup name='trunk-storage'>
    <vlan trunk='yes'>
      <tag id='200'/>
      <tag id='201'/>
    </vlan>
  </portgroup>
</network>
```

### 4.6 Red virtual — NAT con reserva DHCP estática (default endurecida)

```xml
<network>
  <name>mgmt-nat</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='virbr10' stp='on' delay='0'/>
  <mac address='52:54:00:aa:bb:cc'/>
  <domain name='mgmt.leloir.lan' localOnly='yes'/>
  <dns>
    <host ip='192.168.50.10'>
      <hostname>gateway.mgmt.leloir.lan</hostname>
    </host>
  </dns>
  <ip address='192.168.50.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.50.100' end='192.168.50.200'/>
      <host mac='52:54:00:6c:3a:1f' name='web-prod-01' ip='192.168.50.11'/>
    </dhcp>
  </ip>
</network>
```

### 4.7 Red — pool SR-IOV (hostdev con VFs)

```xml
<network>
  <name>sriov-net</name>
  <forward mode='hostdev' managed='yes'>
    <pf dev='enp3s0f0'/>
  </forward>
</network>
```

### 4.8 Secret — autenticación Ceph

```xml
<secret ephemeral='no' private='yes'>
  <uuid>2f9c8b1a-5d4e-4c3b-8a7f-1e0d9c8b7a6f</uuid>
  <usage type='ceph'>
    <name>client.libvirt secret</name>
  </usage>
</secret>
```

### 4.9 Envoltorio IaC — Ansible (`community.libvirt`, YAML)

```yaml
---
- name: Provisionar VM de producción con libvirt
  hosts: hypervisors
  become: true
  vars:
    domain_name: web-prod-01
    libvirt_uri: qemu:///system
  tasks:
    - name: Asegurar el storage pool RBD definido y activo
      community.libvirt.virt_pool:
        name: libvirt-pool
        state: active
        autostart: true
        uri: "{{ libvirt_uri }}"

    - name: Asegurar la red de producción activa
      community.libvirt.virt_net:
        name: prod-br
        state: active
        autostart: true
        uri: "{{ libvirt_uri }}"

    - name: Renderizar el domain XML desde plantilla
      ansible.builtin.template:
        src: templates/web-prod-01.xml.j2
        dest: "/tmp/{{ domain_name }}.xml"
        mode: "0600"

    - name: Definir (persistir) el dominio
      community.libvirt.virt:
        command: define
        xml: "{{ lookup('file', '/tmp/' + domain_name + '.xml') }}"
        uri: "{{ libvirt_uri }}"

    - name: Arrancar y habilitar autostart
      community.libvirt.virt:
        name: "{{ domain_name }}"
        state: running
        autostart: true
        uri: "{{ libvirt_uri }}"

    - name: Verificar estado del dominio
      community.libvirt.virt:
        command: status
        name: "{{ domain_name }}"
        uri: "{{ libvirt_uri }}"
      register: dom_status

    - name: Assert running
      ansible.builtin.assert:
        that:
          - dom_status.status == "running"
        fail_msg: "El dominio {{ domain_name }} no arrancó."
```

### 4.10 Envoltorio IaC — Terraform (`dmacvicar/libvirt`, HCL)

```hcl
terraform {
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.8"
    }
  }
}

provider "libvirt" {
  uri = "qemu+ssh://root@hv-02.leloir.lan/system"
}

resource "libvirt_volume" "root" {
  name           = "web-prod-01.root.qcow2"
  pool           = "default"
  base_volume_id = libvirt_volume.golden.id
  size           = 32 * 1024 * 1024 * 1024
  format         = "qcow2"
}

resource "libvirt_volume" "golden" {
  name   = "debian12-golden.qcow2"
  pool   = "default"
  source = "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
  format = "qcow2"
}

resource "libvirt_cloudinit_disk" "ci" {
  name      = "web-prod-01-cloudinit.iso"
  pool      = "default"
  user_data = file("${path.module}/cloud-init/user-data.yaml")
}

resource "libvirt_domain" "web" {
  name       = "web-prod-01"
  memory     = 8192
  vcpu       = 4
  cloudinit  = libvirt_cloudinit_disk.ci.id
  autostart  = true
  qemu_agent = true

  cpu { mode = "host-passthrough" }

  disk { volume_id = libvirt_volume.root.id }

  network_interface {
    network_name   = "prod-br"
    wait_for_lease = true
  }

  console {
    type        = "pty"
    target_port = "0"
  }

  graphics {
    type        = "vnc"
    listen_type = "address"
    listen_address = "127.0.0.1"
  }
}
```

---

## 5. Comandos CLI y salidas de terminal reales

### 5.1 Conexión, inventario y capacidades del nodo

```console
$ virsh -c qemu:///system nodeinfo
CPU model:           x86_64
CPU(s):              16
CPU frequency:       2200 MHz
CPU socket(s):       1
Core(s) per socket:  8
Thread(s) per core:  2
NUMA cell(s):        1
Memory size:         65536000 KiB

$ virsh list --all
 Id   Name          State
------------------------------
 3    web-prod-01   running
 4    db-prod-01    running
 -    db-prod-02    shut off
 -    cache-01      shut off

$ virsh domcapabilities --virttype kvm | head -n 20
<domainCapabilities>
  <path>/usr/bin/qemu-system-x86_64</path>
  <domain>kvm</domain>
  <machine>pc-q35-8.2</machine>
  <arch>x86_64</arch>
  <vcpu max='1024'/>
  <iothreads supported='yes'/>
  <os supported='yes'>
    <enum name='firmware'>
      <value>bios</value>
      <value>efi</value>
    </enum>
  ...
```

`virsh capabilities` (host) vs `virsh domcapabilities` (lo que este QEMU puede crear) es una distinción clave: la primera describe el host y NUMA; la segunda, el conjunto de features disponibles para un guest — se usa para decidir `host-passthrough` vs `host-model` y para descubrir CPU models soportados.

### 5.2 Ciclo de vida de dominios

```console
$ virsh define /srv/xml/db-prod-02.xml
Domain 'db-prod-02' defined from /srv/xml/db-prod-02.xml

$ virsh start db-prod-02
Domain 'db-prod-02' started

$ virsh dominfo db-prod-02
Id:             5
Name:           db-prod-02
UUID:           a1b2c3d4-e5f6-7890-abcd-ef1234567890
OS Type:        hvm
State:          running
CPU(s):         4
CPU time:       12.7s
Max memory:     8388608 KiB
Used memory:    8388608 KiB
Persistent:     yes
Autostart:      disable
Managed save:   no
Security model: selinux
Security DOI:   0
Security label: system_u:system_r:svirt_t:s0:c412,c718 (enforcing)

$ virsh autostart db-prod-02
Domain 'db-prod-02' marked as autostarted

$ virsh shutdown db-prod-02        # ACPI, "graceful" — requiere guest agent/ACPI
Domain 'db-prod-02' is being shutdown

$ virsh destroy db-prod-02         # equivalente a tirar del cable — forzado
Domain 'db-prod-02' destroyed

$ virsh undefine db-prod-02 --nvram --remove-all-storage
Domain 'db-prod-02' has been undefined
Volume 'sda'(/var/lib/libvirt/images/db-prod-02.qcow2) removed.
```

**Distinción crítica de examen:** `create` (transitorio, desde XML, no persiste) vs `define` (persiste el XML) + `start`. `destroy` NO borra el dominio: lo apaga a la fuerza; sigue definido. `undefine` borra la definición persistente.

### 5.3 Edición en caliente y volcado de XML

```console
$ virsh dumpxml web-prod-01 > /srv/backup/web-prod-01.xml   # snapshot declarativo → git

$ virsh edit web-prod-01
# abre $EDITOR con el XML activo; al guardar valida contra RNG y re-define
Domain 'web-prod-01' XML configuration edited.

# Cambios en dispositivos sin reiniciar:
$ virsh attach-interface web-prod-01 --type network --source mgmt-nat \
        --model virtio --config --live
Interface attached successfully

$ virsh detach-disk web-prod-01 sdb --config --live
Disk detached successfully
```

Los flags `--config` (persistente), `--live` (dominio corriendo) y `--current` gobiernan **dónde** se aplica el cambio. Un cambio `--live` sin `--config` se pierde al reiniciar; uno `--config` sin `--live` recién aplica tras el próximo boot.

### 5.4 Snapshots (internos vs externos)

```console
# Snapshot interno (todo dentro del qcow2) — con la VM apagada o disk-only
$ virsh snapshot-create-as db-prod-01 \
        --name pre-upgrade --description "Antes de PostgreSQL 16" \
        --atomic
Domain snapshot pre-upgrade created

$ virsh snapshot-list db-prod-01
 Name          Creation Time               State
-----------------------------------------------------------
 pre-upgrade   2026-08-11 14:22:07 -0300   running

# Snapshot EXTERNO de disco con quiesce del guest (consistente en FS)
$ virsh snapshot-create-as db-prod-01 \
        --name snap-ext-01 --disk-only --atomic --quiesce \
        --diskspec sda,snapshot=external,file=/var/lib/libvirt/images/db-prod-01.snap-ext-01.qcow2
Domain snapshot snap-ext-01 created

$ virsh snapshot-revert db-prod-01 pre-upgrade
$ virsh snapshot-delete db-prod-01 pre-upgrade
Domain snapshot pre-upgrade deleted
```

| | Snapshot interno | Snapshot externo |
|---|---|---|
| Almacenamiento | Dentro del mismo qcow2 | Nuevo qcow2 con backing = original |
| Formatos | Solo qcow2 | qcow2/raw base + overlay qcow2 |
| Con VM viva + memoria | Limitado | Sí (`--live`, con o sin memoria) |
| `--quiesce` (FS consistente) | — | Sí (requiere guest agent) |
| Borrado/merge | `snapshot-delete` | `blockcommit`/`blockpull` (blockjobs) |
| Rendimiento | Degrada con muchos snaps | Cadena de backing files |
| Recomendado en prod | No para VMs grandes | **Sí** (con blockcommit) |

Consolidación de un snapshot externo (merge del overlay al base) sin downtime:

```console
$ virsh blockcommit db-prod-01 sda --active --pivot --verbose
Block commit: [100 %]
Successfully pivoted
```

### 5.5 Análisis de consumo de recursos

```console
# Estadísticas agregadas (formato estable, scrapeable)
$ virsh domstats --list-active
Domain: 'web-prod-01'
  state.state=1
  cpu.time=48239511000
  cpu.user=12100000000
  cpu.system=8300000000
  balloon.current=8388608
  balloon.rss=6221004
  vcpu.current=4
  vcpu.0.time=12010000000
  net.0.rx.bytes=104857600
  net.0.tx.bytes=52428800
  block.0.rd.reqs=88213
  block.0.wr.reqs=41022
  block.0.rd.bytes=3221225472
  block.0.wr.bytes=1610612736

$ virsh cpu-stats web-prod-01 --total
Total:
  cpu_time     48.239511000 seconds
  user_time    12.100000000 seconds
  system_time   8.300000000 seconds

$ virsh dommemstat web-prod-01
actual 8388608
swap_in 0
swap_out 0
rss 6221004
available 8290304
unused 2069300
usable 5100032

# Ajuste dinámico de recursos
$ virsh setvcpus web-prod-01 6 --live          # requiere maxvcpus >= 6
$ virsh setmem web-prod-01 6291456 --live      # balloon a 6 GiB (KiB)
$ virsh memtune web-prod-01 --hard-limit 9437184 --config
$ virsh blkdeviotune web-prod-01 sda --total-iops-sec 5000 --config --live
$ virsh schedinfo web-prod-01 --set vcpu_quota=50000 --set vcpu_period=100000 --live
```

`virsh domstats` es la fuente canónica para exporters (p. ej. `libvirt_exporter` de Prometheus lee estos mismos campos vía API). En SRE, este comando es el equivalente a un `/metrics` por dominio.

### 5.6 Storage pools y volúmenes

```console
$ virsh pool-list --all --details
 Name           State    Autostart   Persistent   Capacity     Allocation   Available
-------------------------------------------------------------------------------------
 default        running  yes         yes          1.82 TiB     412.00 GiB   1.42 TiB
 libvirt-pool   running  yes         yes          40.00 TiB    8.10 TiB     31.90 TiB
 vg-vms         running  yes         yes          931.51 GiB   200.00 GiB   731.51 GiB

$ virsh pool-define /srv/xml/pool-rbd.xml && virsh pool-start libvirt-pool
$ virsh pool-autostart libvirt-pool

$ virsh vol-create-as default db-prod-02.qcow2 100G \
        --format qcow2 --backing-vol debian12-golden.qcow2 --backing-vol-format qcow2
Vol db-prod-02.qcow2 created

$ virsh vol-list --pool default --details
 Name                       Path                                              Type   Capacity    Allocation
-----------------------------------------------------------------------------------------------------------
 debian12-golden.qcow2      /var/lib/libvirt/images/debian12-golden.qcow2     file   2.00 GiB    1.60 GiB
 db-prod-02.qcow2           /var/lib/libvirt/images/db-prod-02.qcow2          file   100.00 GiB  196.00 KiB

$ virsh vol-info db-prod-02.qcow2 --pool default
Name:           db-prod-02.qcow2
Type:           file
Capacity:       100.00 GiB
Allocation:     196.00 KiB
```

### 5.7 Redes virtuales

```console
$ virsh net-list --all
 Name       State    Autostart   Persistent
---------------------------------------------
 default    active   yes         yes
 prod-br    active   yes         yes
 mgmt-nat   active   yes         yes

$ virsh net-define /srv/xml/mgmt-nat.xml && virsh net-start mgmt-nat && virsh net-autostart mgmt-nat
Network mgmt-nat defined from /srv/xml/mgmt-nat.xml
Network mgmt-nat started
Network mgmt-nat marked as autostarted

$ virsh net-dhcp-leases mgmt-nat
 Expiry Time           MAC address         Protocol   IP address           Hostname      Client ID
--------------------------------------------------------------------------------------------------------
 2026-08-11 15:40:22   52:54:00:6c:3a:1f   ipv4       192.168.50.11/24     web-prod-01   -

$ virsh net-dumpxml default
<network>
  <name>default</name>
  <uuid>...</uuid>
  <forward mode='nat'>
    <nat><port start='1024' end='65535'/></nat>
  </forward>
  <bridge name='virbr0' stp='on' delay='0'/>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
    <dhcp><range start='192.168.122.2' end='192.168.122.254'/></dhcp>
  </ip>
</network>
```

### 5.8 Secrets

```console
$ virsh secret-define /srv/xml/secret-ceph.xml
Secret 2f9c8b1a-5d4e-4c3b-8a7f-1e0d9c8b7a6f created

# El VALOR se inyecta aparte y no se persiste en claro en el XML
$ CEPHKEY=$(ceph auth get-key client.libvirt)
$ virsh secret-set-value --secret 2f9c8b1a-5d4e-4c3b-8a7f-1e0d9c8b7a6f \
        --base64 "$CEPHKEY"
Secret value set

$ virsh secret-list
 UUID                                   Usage
-------------------------------------------------------------
 2f9c8b1a-5d4e-4c3b-8a7f-1e0d9c8b7a6f   ceph client.libvirt secret

$ virsh secret-get-value 2f9c8b1a-5d4e-4c3b-8a7f-1e0d9c8b7a6f
QVFC... (base64)
```

**Modelo de secrets:** el XML del secret (bajo `/etc/libvirt/secrets/`) contiene solo metadatos y `usage`; el valor se almacena por separado y, con `private='yes'`, no se puede leer de vuelta. Tipos soportados: `ceph`, `volume` (LUKS), `iscsi` (CHAP), `tls`, `vtpm`. Esto desacopla la referencia (que sí va en el domain XML versionable) del material sensible.

### 5.9 `libvirt-guests`: apagado/arranque ordenado del fleet

Servicio systemd que, al **apagar el host**, suspende (`managedsave`) o apaga los dominios en ejecución, y al **arrancar**, los restaura/inicia. Es la pieza que evita `destroy` masivo (corrupción de FS de guests) en un reboot del hypervisor.

```console
$ cat /etc/default/libvirt-guests    # Debian/Ubuntu ( /etc/sysconfig/libvirt-guests en RHEL )
URIS=default
ON_BOOT=start
ON_SHUTDOWN=managedsave           # managedsave | shutdown | suspend
PARALLEL_SHUTDOWN=4
SHUTDOWN_TIMEOUT=300
START_DELAY=0
BYPASS_CACHE=0

$ sudo systemctl enable --now libvirt-guests.service

$ virsh managedsave-list --help    # estado guardado por dominio
$ virsh dominfo web-prod-01 | grep -i managed
Managed save:   yes
```

`ON_SHUTDOWN=managedsave` vuelca el estado de RAM a disco (`/var/lib/libvirt/qemu/save/`) y restaura la VM exactamente donde estaba — a diferencia de `shutdown`, que apaga limpio pero pierde el estado en memoria.

---

## 6. Guía de verificación y diagnóstico de fallas

### 6.1 Validación proactiva

```console
# ¿El host está listo para virtualización acelerada?
$ virt-host-validate qemu
  QEMU: Checking for hardware virtualization                : PASS
  QEMU: Checking if device /dev/kvm exists                  : PASS
  QEMU: Checking if device /dev/kvm is accessible           : PASS
  QEMU: Checking if device /dev/vhost-net exists            : PASS
  QEMU: Checking for cgroup 'cpu' controller support        : PASS
  QEMU: Checking for cgroup 'memory' controller support     : PASS
  QEMU: Checking for secure guest support                   : WARN (Unknown if this platform has Secure Guest support)

# ¿El XML es válido antes de definir?
$ virt-xml-validate /srv/xml/web-prod-01.xml domain
/srv/xml/web-prod-01.xml validates

# ¿Está KVM cargado y con aceleración?
$ lsmod | grep kvm
kvm_intel             487424  6
kvm                  1409024  1 kvm_intel
$ virsh domcapabilities | grep -i 'domain='
  <domain>kvm</domain>          # si dijera 'qemu' → emulación, sin /dev/kvm
```

### 6.2 Estado del daemon y logging

```console
$ systemctl status virtqemud.service
● virtqemud.service - Virtualization qemu daemon
     Active: active (running) since Mon 2026-08-11 09:03:11 -0300
   Main PID: 1421 (virtqemud)
     Tasks: 19 (limit: 32768)

# Ver por qué falló un arranque
$ journalctl -u virtqemud -b --no-pager | tail -n 40
$ journalctl -u virtlogd -b            # errores de consola/serial de guests

# Log de QEMU específico del dominio (lo escribe virtlogd)
$ sudo tail -n 50 /var/log/libvirt/qemu/web-prod-01.log
```

Debug fino del daemon — editar `/etc/libvirt/virtqemud.conf` (o `libvirtd.conf`):

```
log_filters="3:remote 4:event 3:util.json 3:rpc 1:qemu"
log_outputs="1:file:/var/log/libvirt/virtqemud.log"
```

```console
$ sudo systemctl restart virtqemud
```

Sintaxis de `log_filters`: `nivel:categoría` (1=DEBUG, 2=INFO, 3=WARN, 4=ERROR). Bajar `qemu` a `1` genera trazas exhaustivas del driver — se activa para diagnosticar y se revierte, porque el volumen es alto.

### 6.3 Fallas comunes y su resolución

| Síntoma / error | Causa raíz | Diagnóstico | Fix |
|---|---|---|---|
| `Failed to connect socket ... Permission denied` en `qemu:///system` | Usuario fuera del grupo `libvirt`; polkit deniega | `id`, `journalctl -u polkit` | `usermod -aG libvirt $USER` + re-login |
| `error: Network not found: no network with matching name 'default'` | Red `default` no definida/activa | `virsh net-list --all` | `virsh net-start default; virsh net-autostart default` |
| VM no arranca: `Cannot access storage file ... Permission denied` | Label SELinux/ownership incorrecto en la imagen | `ls -Z`, `ausearch -m avc -ts recent` | `virsh` relabel (dynamic seclabel) o `chown 64055:64055`; revisar `security_driver` en `qemu.conf` |
| `unsupported configuration: CPU mode 'host-passthrough' ... not migratable` | Migración con passthrough sin `migratable='on'` | `virsh dumpxml \| grep cpu` | añadir `migratable='on'` o usar `host-model` |
| Guest sin red pese a interfaz `virtio` | Bridge inexistente / firewalld bloquea `virbrX` | `virsh domiflist`, `bridge link`, `nft list ruleset` | crear bridge; `firewall-cmd --zone=libvirt` |
| `virsh shutdown` no apaga | Sin ACPI ni guest agent | `virsh qemu-agent-command <dom> '{"execute":"guest-ping"}'` | instalar `qemu-guest-agent` en el guest; o `virsh destroy` |
| Pool RBD `inactive`: `failed to connect to the RADOS monitor` | Secret Ceph ausente/errado o mons inalcanzables | `virsh secret-list`, `ceph -s` | `virsh secret-set-value` correcto; verificar `10.20.0.0/24` |
| `Failed to start domain ... Device 'kvm' not found` | `/dev/kvm` ausente (nested/VT-x off) | `virt-host-validate`, BIOS | habilitar VT-x/AMD-V; `modprobe kvm_intel` |
| `Timed out during operation: cannot acquire state change lock` | `virtlockd` o job colgado en el dominio | `virsh domjobinfo <dom>` | `virsh domjobabort <dom>`; revisar `virtlockd` |
| Snapshot externo: espacio explota | Cadena de overlays sin consolidar | `qemu-img info --backing-chain` | `virsh blockcommit ... --pivot` |

### 6.4 Checklist de verificación post-provisioning

```console
$ virsh dominfo web-prod-01 | grep -E 'State|Autostart|Security'   # running, autostart, svirt_t
$ virsh domiflist web-prod-01                                       # interfaz en bridge correcto
$ virsh domblklist web-prod-01                                      # discos y rutas esperadas
$ virsh net-dhcp-leases mgmt-nat | grep web-prod-01                 # IP asignada
$ virsh qemu-agent-command web-prod-01 '{"execute":"guest-ping"}'   # {"return":{}}  → agent vivo
$ virsh domstats web-prod-01 --cpu-total --balloon --interface --block   # métricas fluyendo
```

---

## 7. Nota sobre oVirt (awareness) y KubeVirt

El objetivo pide **conciencia de oVirt**: es el *management engine* de nivel superior (el upstream de Red Hat Virtualization/RHV) que orquesta **múltiples hosts libvirt** como un cluster —con VDSM (el agente por host que habla libvirt), storage domains compartidos, live migration, high availability y un portal web/API REST. Donde `virsh` gobierna un host, oVirt gobierna un datacenter de hosts. En el ecosistema cloud-native, **KubeVirt** cumple un rol análogo sobre Kubernetes: cada VM corre en un pod `virt-launcher` que, internamente, define y arranca el dominio vía **libvirt**. En ambos casos libvirt es la capa de ejecución por-nodo; el trade-off es el mismo de siempre: `virsh`/host único (control total, sin orquestación) vs. oVirt/KubeVirt (scheduling, HA y multi-host a cambio de una capa de complejidad).

---

## 8. Referencias

- LPI — Exam 305-300 Objectives (Objective 351.4): https://www.lpi.org/our-certifications/exam-305-objectives/
- libvirt — Deployment / architecture and drivers: https://libvirt.org/drivers.html
- libvirt — Modular daemons (`virtqemud`, `virtnetworkd`, …): https://libvirt.org/daemons.html
- libvirt — Connection URIs and remote support: https://libvirt.org/uri.html
- libvirt — Domain XML format: https://libvirt.org/formatdomain.html
- libvirt — Storage pool & volume XML: https://libvirt.org/formatstorage.html
- libvirt — Storage backend drivers (RBD, LVM, iSCSI): https://libvirt.org/storage.html
- libvirt — Virtual network XML format: https://libvirt.org/formatnetwork.html
- libvirt — Secret XML format and management: https://libvirt.org/formatsecret.html
- libvirt — Snapshot XML and block jobs: https://libvirt.org/formatsnapshot.html
- libvirt — TLS/x509 and SASL authentication: https://libvirt.org/tlscerts.html · https://libvirt.org/auth.html
- libvirt — `virsh` command reference (man page): https://libvirt.org/manpages/virsh.html
- libvirt — `libvirt-guests` service: https://libvirt.org/manpages/libvirt-guests.html
- libvirt — sVirt (SELinux/AppArmor confinement): https://libvirt.org/drvqemu.html#security
- oVirt — Documentation and architecture: https://www.ovirt.org/documentation/
- KubeVirt — Architecture (uses libvirt in `virt-launcher`): https://kubevirt.io/user-guide/architecture/
- QEMU guest agent protocol reference: https://qemu.org/docs/master/interop/qemu-ga.html