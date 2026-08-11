# Ejercicios guiados — Tema 351.4: Libvirt Virtual Machine Management

> **Certificación:** LPIC-3 305 (examen 305-300, versión 3.0) · **Peso:** 15
> **Entorno de laboratorio asumido:** un host Linux con extensiones de virtualización habilitadas en firmware (Intel VT-x / AMD-V), paquetes `libvirt`, `qemu-kvm`, `virtinst` y `libvirt-clients` instalados, y tu usuario en el grupo `libvirt`. Salvo indicación, todo se ejecuta contra `qemu:///system`.
>
> Verificá el prerrequisito de hardware antes de empezar:
> ```bash
> LC_ALL=C grep -Ec '(vmx|svm)' /proc/cpuinfo   # >0 = CPU con soporte de virtualización
> lsmod | grep -E 'kvm_(intel|amd)'             # módulo KVM cargado
> virt-host-validate qemu                        # diagnóstico integral de aptitud del host
> ```
> Salida esperada de la última línea (extracto):
> ```
>   QEMU: Checking for hardware virtualization                                 : PASS
>   QEMU: Checking if device /dev/kvm exists                                   : PASS
>   QEMU: Checking if device /dev/kvm is accessible                            : PASS
>   QEMU: Checking for cgroup 'cpu' controller support                         : PASS
> ```

---

## Ejercicio 1 — Arquitectura de libvirt, daemons modulares y conexión con `virsh`

**Objetivo:** distinguir el daemon monolítico (`libvirtd`) de los daemons modulares, entender los *connection URIs* y sondear las capacidades del host y del hypervisor.

### Bloque A — Identificar el modelo de daemon en tu host

1. Determiná si tu distribución usa el daemon monolítico o los daemons modulares:
   ```bash
   systemctl list-unit-files --type=service | grep -E 'libvirtd|virtqemud|virtnetworkd|virtstoraged'
   ```
   En un host moderno (libvirt ≥ 7.x en Debian 12, RHEL 9, etc.) verás los daemons *split*:
   ```
   libvirtd.service         masked
   virtqemud.service        enabled
   virtnetworkd.service     enabled
   virtstoraged.service     enabled
   virtnodedevd.service     enabled
   ```
2. Observá que libvirt usa **socket activation**. El daemon puede estar inactivo y arrancar bajo demanda cuando `virsh` toca su socket:
   ```bash
   systemctl status virtqemud.socket virtqemud.service
   ```
   Salida típica: el `.socket` aparece `active (listening)` y el `.service` `inactive (dead)` hasta la primera conexión.
3. Listá los sockets de admin, RO y RW del sub-daemon de QEMU:
   ```bash
   ls -l /run/libvirt/virtqemud-sock*
   ```
   ```
   srw-rw---- 1 root libvirt 0 ... /run/libvirt/virtqemud-sock
   srw-rw-r-- 1 root root    0 ... /run/libvirt/virtqemud-sock-ro
   srwxr-x--- 1 root root    0 ... /run/libvirt/virtqemud-admin-sock
   ```

> **Preguntas — Bloque A**
> 1. ¿Qué ventaja operativa concreta aporta el modelo de daemons modulares frente al monolítico `libvirtd` en términos de superficie de fallo y arranque?
> 2. Si `virtqemud.service` está `inactive` pero `virtqemud.socket` está `active (listening)`, ¿el host puede gestionar VMs? ¿Por qué?
> 3. ¿Qué grupo del sistema controla el acceso de escritura al socket `virtqemud-sock` según los permisos mostrados?

### Bloque B — Connection URIs y el shell interactivo

4. Consultá la URI a la que te conecta `virsh` por defecto y compará las dos vistas del sistema:
   ```bash
   virsh uri                                   # depende de LIBVIRT_DEFAULT_URI / usuario
   virsh -c qemu:///system uri
   virsh -c qemu:///session uri
   ```
5. Fijá la URI de sistema para toda la sesión de shell y verificá:
   ```bash
   export LIBVIRT_DEFAULT_URI='qemu:///system'
   virsh uri
   ```
   ```
   qemu:///system
   ```
6. Entrá al shell interactivo de `virsh` y ejecutá un par de subcomandos sin volver a teclear `virsh`:
   ```bash
   virsh
   ```
   ```
   Welcome to virsh, the virtualization interactive terminal.
   virsh # list --all
   virsh # nodeinfo
   virsh # quit
   ```

> **Preguntas — Bloque B**
> 1. ¿Cuál es la diferencia semántica entre `qemu:///system` y `qemu:///session`, y por qué las VMs creadas en una no aparecen en la otra?
> 2. Escribí la URI que usarías para administrar libvirt en un host remoto llamado `hv02` mediante un túnel SSH.
> 3. ¿En qué orden resuelve `virsh` la URI por defecto cuando no pasás `-c`?

### Bloque C — Capacidades del host y del driver

7. Inspeccioná las capacidades del **host** (topología de CPU, NUMA, tipos de invitado soportados):
   ```bash
   virsh capabilities | head -n 40
   virsh nodeinfo
   ```
   `virsh nodeinfo` (ejemplo):
   ```
   CPU model:           x86_64
   CPU(s):              8
   CPU frequency:       3200 MHz
   CPU socket(s):       1
   Core(s) per socket:  4
   Thread(s) per core:  2
   NUMA cell(s):        1
   Memory size:         16289792 KiB
   ```
8. Consultá las capacidades del **driver** para un tipo concreto de dominio — esto es lo que valida qué máquina, firmware y CPU podés pedir:
   ```bash
   virsh domcapabilities --virttype kvm --arch x86_64 --machine q35 | grep -A3 '<os>'
   ```
9. Verificá que estás usando aceleración KVM y no emulación pura por software (TCG):
   ```bash
   virsh domcapabilities | grep -o "domain='[a-z]*'"
   ```
   Con KVM disponible verás `domain='kvm'`; si sólo aparece `domain='qemu'`, estás en emulación sin aceleración.

> **Preguntas — Bloque C**
> 1. ¿Qué diferencia hay entre `virsh capabilities` y `virsh domcapabilities`, y para qué decisión de diseño usarías cada uno?
> 2. Del `nodeinfo` de ejemplo, ¿cuántas vCPUs físicas tiene el host y cómo se descompone ese número entre sockets/cores/threads?
> 3. Si `virsh domcapabilities` sólo reporta `domain='qemu'` en un host con `vmx` en `/proc/cpuinfo`, nombrá dos causas probables.

---

## Ejercicio 2 — Ciclo de vida completo de un *domain*

**Objetivo:** crear una VM con `virt-install`, y recorrer todo su ciclo de vida con `virsh` distinguiendo estado transitorio vs persistente.

### Bloque A — Provisionar con `virt-install`

1. Descargá (o ubicá) una ISO de instalación en un directorio accesible por libvirt, por ejemplo `/var/lib/libvirt/iso/debian-12.iso`.
2. Creá la VM. Este comando define **y** arranca el dominio de forma persistente:
   ```bash
   virt-install \
     --name vm-lab \
     --memory 2048 \
     --vcpus 2 \
     --cpu host-passthrough \
     --disk path=/var/lib/libvirt/images/vm-lab.qcow2,size=10,format=qcow2,bus=virtio \
     --cdrom /var/lib/libvirt/iso/debian-12.iso \
     --os-variant debian12 \
     --network network=default,model=virtio \
     --graphics vnc,listen=127.0.0.1 \
     --noautoconsole
   ```
   Salida esperada:
   ```
   Starting install...
   Allocating 'vm-lab.qcow2'                          |  10 GB  00:00:00
   Domain is still running. Installation may progress remotely.
   ```
3. Si no conocés el identificador exacto de `--os-variant`, listalo:
   ```bash
   virt-install --osinfo list | grep -i debian12
   ```

> **Preguntas — Bloque A**
> 1. ¿Qué hace exactamente `--os-variant debian12` a nivel de XML generado? Nombrá al menos dos ajustes que optimiza.
> 2. ¿Por qué `bus=virtio` y `model=virtio` son la elección de producción frente a `sata`/`e1000`?
> 3. ¿Qué implica `--noautoconsole` y en qué se diferencia de omitir la opción?

### Bloque B — Estados y transiciones

4. Observá el dominio y su estado:
   ```bash
   virsh list --all
   virsh domstate vm-lab
   virsh dominfo vm-lab
   ```
   `virsh list --all`:
   ```
    Id   Name     State
   -----------------------
    3    vm-lab   running
   ```
5. Recorré las transiciones y observá el estado tras cada una:
   ```bash
   virsh suspend  vm-lab   && virsh domstate vm-lab   # paused
   virsh resume   vm-lab   && virsh domstate vm-lab   # running
   virsh shutdown vm-lab                              # ACPI: apagado ordenado
   virsh domstate vm-lab                              # shut off (tras unos segundos)
   virsh start    vm-lab
   virsh reboot   vm-lab
   virsh destroy  vm-lab                              # corte forzado (NO borra la definición)
   virsh domstate vm-lab                              # shut off
   ```

> **Preguntas — Bloque B**
> 1. Diferenciá `virsh shutdown` de `virsh destroy`: ¿qué le llega al guest en cada caso y por qué `shutdown` puede "no hacer nada"?
> 2. Un dominio quedó en estado `paused`. ¿Consume CPU? ¿Sigue reservando su RAM? ¿Con qué comando lo reactivás?
> 3. ¿En qué se diferencia `virsh destroy` de `virsh undefine`?

### Bloque C — Persistencia, autostart y guardado de estado

6. Configurá el arranque automático del dominio con el host y verificá:
   ```bash
   virsh autostart vm-lab
   virsh dominfo vm-lab | grep Autostart
   ls -l /etc/libvirt/qemu/autostart/
   ```
   ```
   Autostart:      enable
   lrwxrwxrwx 1 root root ... vm-lab.xml -> /etc/libvirt/qemu/vm-lab.xml
   ```
7. Guardá el estado en vivo a disco (hibernación gestionada por libvirt) y restauralo:
   ```bash
   virsh managedsave vm-lab          # vuelca RAM+estado y apaga el dominio
   virsh list --all                  # aparece 'saved' / 'shut off'
   virsh start vm-lab                # restaura desde el managed save
   ```
8. Transformá un dominio persistente en transitorio y viceversa, observando el efecto de `undefine`:
   ```bash
   virsh start vm-lab
   virsh undefine vm-lab             # el dominio EN EJECUCIÓN sigue vivo pero ahora es transitorio
   virsh list --all                  # sin '--all' seguiría; ya no tiene XML persistente
   virsh dumpxml vm-lab > /tmp/vm-lab.xml   # rescatá la definición antes de que se apague
   virsh define /tmp/vm-lab.xml      # lo volvés persistente
   ```

> **Preguntas — Bloque C**
> 1. ¿Dónde vive físicamente la definición XML persistente de un dominio, y por qué **no** se debe editar ese archivo con `vi` directamente?
> 2. Un dominio con `autostart` habilitado no arranca al bootear el host. ¿Qué unit/daemon es responsable de arrancarlo y cómo lo verificarías?
> 3. Si hacés `virsh undefine` sobre un dominio que está *running*, ¿qué le pasa a la VM en ese instante y qué pasa cuando después la apagás?

---

## Ejercicio 3 — Redes virtuales: NAT, aislada y bridged

**Objetivo:** inspeccionar la red `default` (NAT + `virbr0` + dnsmasq), crear una red aislada y una routed, y entender cómo libvirt programa el firewall.

### Bloque A — Anatomía de la red `default`

1. Listá las redes y volcá la definición de `default`:
   ```bash
   virsh net-list --all
   virsh net-dumpxml default
   ```
   ```
    Name      State    Autostart   Persistent
   ----------------------------------------------
    default   active   yes         yes
   ```
   ```xml
   <network>
     <name>default</name>
     <uuid>9a05da11-e96b-47f3-8253-73e9a6e12e01</uuid>
     <forward mode='nat'>
       <nat>
         <port start='1024' end='65535'/>
       </nat>
     </forward>
     <bridge name='virbr0' stp='on' delay='0'/>
     <mac address='52:54:00:8f:2a:11'/>
     <ip address='192.168.122.1' netmask='255.255.255.0'>
       <dhcp>
         <range start='192.168.122.2' end='192.168.122.254'/>
       </dhcp>
     </ip>
   </network>
   ```
2. Observá el bridge y el proceso `dnsmasq` que libvirt levanta *por red* para DHCP/DNS:
   ```bash
   ip -br addr show virbr0
   ps aux | grep -E "dnsmasq.*virbr0" | grep -v grep
   ```
   ```
   virbr0  UNKNOWN  192.168.122.1/24
   ```
   Notá el flag `--conf-file=/var/lib/libvirt/dnsmasq/default.conf` en la línea de dnsmasq.
3. Con la VM del Ejercicio 2 encendida y conectada a `default`, consultá sus leases DHCP:
   ```bash
   virsh net-dhcp-leases default
   ```
   ```
    Expiry Time           MAC address         Protocol   IP address           Hostname   Client ID
   -----------------------------------------------------------------------------------------------------
    2026-08-11 18:44:02   52:54:00:a3:1c:9d   ipv4       192.168.122.87/24    vm-lab     ...
   ```

> **Preguntas — Bloque A**
> 1. ¿Qué rol cumple `virbr0` y por qué el tráfico de las VMs "sale" al exterior con la IP del host en modo `nat`?
> 2. ¿Por qué libvirt levanta un `dnsmasq` dedicado por red en lugar de usar el resolver del host?
> 3. En `<forward mode='nat'>`, ¿pueden las VMs de esa red recibir conexiones **entrantes** iniciadas desde la LAN física sin configuración extra? Justificá.

### Bloque B — Firewall y forward modes

4. Observá las reglas que libvirt inyecta. En hosts con backend nftables:
   ```bash
   nft list table ip libvirt 2>/dev/null | grep -A6 'chain forward'
   # En hosts con backend iptables clásico:
   iptables -t nat -S | grep 192.168.122
   ```
   Verás una regla MASQUERADE para el rango `192.168.122.0/24` hacia el resto.
5. Compará conceptualmente los `forward mode` disponibles editando (sin guardar) una red de prueba:
   - `nat` → SNAT/MASQUERADE, salida sí, entrada no.
   - `route` → enrutado sin NAT (la LAN debe conocer la ruta de vuelta).
   - `open` → como `route` pero libvirt **no** añade reglas de firewall.
   - `bridge` → la VM se conecta a un bridge del host ya existente; libvirt no gestiona IP ni DHCP.
   - sin `<forward>` → red **aislada** (guest-to-guest y guest-to-host solamente).

> **Preguntas — Bloque B**
> 1. ¿Qué diferencia práctica de seguridad hay entre `mode='route'` y `mode='open'`?
> 2. En `mode='route'`, una VM tiene salida pero desde la LAN no le llega el tráfico de vuelta. ¿Dónde está el problema y cómo se resuelve?
> 3. ¿Por qué en `mode='bridge'` libvirt no ofrece DHCP para esa red?

### Bloque C — Crear una red aislada y activarla

6. Escribí la definición de una red **aislada** (sin `<forward>`), con su propio bridge y DHCP:
   ```bash
   cat > /tmp/net-isolated.xml <<'EOF'
   <network>
     <name>isolated</name>
     <bridge name='virbr10' stp='on' delay='0'/>
     <ip address='10.10.10.1' netmask='255.255.255.0'>
       <dhcp>
         <range start='10.10.10.10' end='10.10.10.100'/>
       </dhcp>
     </ip>
   </network>
   EOF
   ```
7. Definila de forma persistente, activala y hacela autostart:
   ```bash
   virsh net-define    /tmp/net-isolated.xml
   virsh net-start     isolated
   virsh net-autostart isolated
   virsh net-list --all
   ```
   ```
    Name       State    Autostart   Persistent
   -----------------------------------------------
    default    active   yes         yes
    isolated   active   yes         yes
   ```
8. Modificá el rango DHCP en caliente sin recrear la red, con `net-update`:
   ```bash
   virsh net-update isolated add ip-dhcp-host \
     "<host mac='52:54:00:aa:bb:cc' name='db01' ip='10.10.10.50'/>" \
     --live --config
   ```
9. Conectá una interfaz de la VM a esta red y comprobá:
   ```bash
   virsh attach-interface vm-lab network isolated --model virtio --live --config
   virsh domiflist vm-lab
   ```

> **Preguntas — Bloque C**
> 1. Diferenciá `virsh net-define` de `virsh net-create`. ¿Cuál sobrevive a un reinicio del host?
> 2. ¿Para qué sirven los flags `--live --config` en `net-update` y `attach-interface`, y qué pasa si omitís `--config`?
> 3. Una VM en la red `isolated` no obtiene IP por DHCP aunque la red está `active`. Nombrá dos causas de diagnóstico a revisar.

---

## Ejercicio 4 — Storage pools y volumes

**Objetivo:** distinguir *pool* de *volume*, crear un pool de tipo `dir`, provisionar volúmenes qcow2 (incluyendo *backing store*/overlay) y adjuntarlos a un dominio.

### Bloque A — Inventario de pools

1. Listá los pools y su tipo/estado:
   ```bash
   virsh pool-list --all --details
   ```
   ```
    Name      State    Autostart   Persistent   Capacity     Allocation   Available
   -------------------------------------------------------------------------------------
    default   running  yes         yes          457.66 GiB   112.30 GiB   345.36 GiB
   ```
2. Volcá la definición del pool `default` y observá su `<target><path>`:
   ```bash
   virsh pool-dumpxml default
   ```
   ```xml
   <pool type='dir'>
     <name>default</name>
     <target>
       <path>/var/lib/libvirt/images</path>
       <permissions><mode>0711</mode><owner>0</owner><group>0</group></permissions>
     </target>
   </pool>
   ```
3. Listá los volúmenes del pool:
   ```bash
   virsh vol-list default --details
   ```

> **Preguntas — Bloque A**
> 1. Definí con tus palabras la relación entre *pool* y *volume*. ¿Un volume puede existir fuera de un pool desde la óptica de libvirt?
> 2. Nombrá tres tipos de pool distintos de `dir` que soporta libvirt y un caso de uso para cada uno.
> 3. ¿Qué significan `Capacity`, `Allocation` y `Available` cuando el pool aloja qcow2 *thin-provisioned*?

### Bloque B — Crear un pool de directorio

4. Creá el directorio de respaldo y definí el pool:
   ```bash
   mkdir -p /srv/vmstore
   virsh pool-define-as guest_images dir --target /srv/vmstore
   ```
5. Construí, arrancá y habilitá autostart:
   ```bash
   virsh pool-build     guest_images
   virsh pool-start     guest_images
   virsh pool-autostart guest_images
   virsh pool-info      guest_images
   ```
   ```
   Name:           guest_images
   UUID:           7c1e...
   State:          running
   Persistent:     yes
   Autostart:      yes
   Capacity:       915.32 GiB
   Allocation:     0.00 B
   Available:      915.32 GiB
   ```

> **Preguntas — Bloque B**
> 1. Para un pool `dir`, ¿qué hace realmente `pool-build`? ¿Y para un pool `logical` (LVM) o `fs`?
> 2. Diferenciá `pool-define-as` de `pool-create-as`. ¿Cuál necesitás para que el pool exista tras reboot?
> 3. ¿Por qué `pool-start` puede fallar con un pool `dir` cuyo `target` apunta a un `mountpoint` que aún no está montado?

### Bloque C — Volúmenes, backing store y attach

6. Creá un volumen base qcow2 y, sobre él, un overlay *copy-on-write*:
   ```bash
   virsh vol-create-as guest_images base.qcow2 10G --format qcow2

   virsh vol-create-as guest_images overlay-01.qcow2 10G \
     --format qcow2 \
     --backing-vol base.qcow2 \
     --backing-vol-format qcow2

   virsh vol-list guest_images
   ```
7. Inspeccioná el encadenamiento del backing store:
   ```bash
   virsh vol-info --pool guest_images overlay-01.qcow2
   qemu-img info --backing-chain /srv/vmstore/overlay-01.qcow2
   ```
   Salida (extracto):
   ```
   image: /srv/vmstore/overlay-01.qcow2
   file format: qcow2
   virtual size: 10 GiB
   backing file: /srv/vmstore/base.qcow2
   backing file format: qcow2
   ```
8. Adjuntá el overlay como segundo disco al dominio, de forma persistente:
   ```bash
   virsh attach-disk vm-lab \
     --source /srv/vmstore/overlay-01.qcow2 \
     --target vdb \
     --subdriver qcow2 \
     --targetbus virtio \
     --persistent
   virsh domblklist vm-lab
   ```
   ```
    Target   Source
   ----------------------------------------------
    vda      /var/lib/libvirt/images/vm-lab.qcow2
    vdb      /srv/vmstore/overlay-01.qcow2
   ```
9. Limpieza controlada de un volumen (borra datos de forma segura):
   ```bash
   virsh detach-disk vm-lab vdb --persistent
   virsh vol-wipe   --pool guest_images overlay-01.qcow2
   virsh vol-delete --pool guest_images overlay-01.qcow2
   ```

> **Preguntas — Bloque C**
> 1. ¿Qué ganás y qué riesgo asumís al usar un overlay con `--backing-vol` en lugar de un qcow2 independiente?
> 2. Si borrás `base.qcow2` mientras `overlay-01.qcow2` sigue en uso, ¿qué le pasa a la VM? ¿Por qué?
> 3. Diferenciá `vol-delete` de `vol-wipe`. ¿Cuál usarías antes de dar de baja un disco que contuvo datos sensibles?

---

## Ejercicio 5 — Modificar recursos en caliente, editar el XML y gestionar snapshots

**Objetivo:** ajustar vCPU/RAM en vivo respetando los máximos, editar el XML con validación, aplicar *pinning*/*tuning*, y crear/revertir snapshots (internos vs externos).

### Bloque A — vCPU y memoria: live vs config, y el rol del máximo

1. Con `vm-lab` **encendida**, mirá los límites actuales:
   ```bash
   virsh vcpucount vm-lab
   virsh dominfo   vm-lab | grep -E 'CPU|memory'
   ```
   ```
   maximum      config         4
   maximum      live           4
   current      config         2
   current      live           2
   ```
2. Subí las vCPUs activas en vivo (no podés exceder el `maximum`):
   ```bash
   virsh setvcpus vm-lab 4 --live
   virsh vcpucount vm-lab --live --active
   ```
3. Intentá subir la RAM viva por encima del `maxMemory` — y observá que falla:
   ```bash
   virsh setmem vm-lab 8G --live
   ```
   ```
   error: invalid argument: cannot set memory higher than max memory
   ```
   Para elevar el techo hay que hacerlo con el dominio **apagado** (`setmaxmem` es sólo `--config`):
   ```bash
   virsh shutdown  vm-lab
   virsh setmaxmem vm-lab 8G --config
   virsh start     vm-lab
   virsh setmem    vm-lab 6G --live
   ```

> **Preguntas — Bloque A**
> 1. ¿Por qué `--live` afecta al dominio en ejecución pero se pierde al reiniciarlo, y cuándo combinarías `--live --config`?
> 2. ¿Por qué no se puede aumentar `maxMemory` (`setmaxmem`) con el dominio encendido, pero sí `currentMemory` (`setmem`)?
> 3. ¿Qué dispositivo del guest hace posible reducir la RAM *asignada* por debajo del máximo sin reiniciar, y qué requisito tiene dentro del guest?

### Bloque B — Editar el XML con validación y aplicar tuning

4. Editá el XML persistente del dominio con validación de esquema RNG integrada:
   ```bash
   virsh edit vm-lab
   ```
   Si introducís un error de sintaxis, `virsh edit` lo rechaza y te reofrece el editor:
   ```
   error: XML document failed to validate against schema: ...
   Failed. Try again? [y,n,i,f,?]:
   ```
5. Aplicá *CPU pinning* de vCPUs a cores físicos y *pinning* del hilo emulador, en vivo y persistente:
   ```bash
   virsh vcpupin    vm-lab 0 2 --live --config
   virsh vcpupin    vm-lab 1 3 --live --config
   virsh emulatorpin vm-lab 0-1 --live --config
   virsh vcpupin    vm-lab
   ```
6. Aplicá *throttling* de I/O de disco y de red (útil para aislar ruido en multi-tenant):
   ```bash
   virsh blkdeviotune vm-lab vda --total-bytes-sec 52428800 --live --config
   virsh domiftune    vm-lab vnet0 --inbound 10240 --outbound 10240 --live --config
   ```
7. Adjuntá memoria/CPU/dispositivos definidos por XML con `attach-device` (patrón general de hotplug):
   ```bash
   cat > /tmp/newdisk.xml <<'EOF'
   <disk type='file' device='disk'>
     <driver name='qemu' type='qcow2'/>
     <source file='/srv/vmstore/data.qcow2'/>
     <target dev='vdc' bus='virtio'/>
   </disk>
   EOF
   virsh attach-device vm-lab /tmp/newdisk.xml --live --config
   ```

> **Preguntas — Bloque B**
> 1. ¿Qué garantía te da `virsh edit` que **no** tenés si editás `/etc/libvirt/qemu/vm-lab.xml` a mano y hacés `systemctl reload`?
> 2. ¿Para qué sirve `emulatorpin` además de `vcpupin`, y por qué en cargas latency-sensitive conviene fijar el hilo emulador aparte de las vCPUs?
> 3. `attach-device --live --config` frente a `attach-device --config` a secas: ¿en qué momento "ve" el guest el nuevo disco en cada caso?

### Bloque C — Snapshots internos y externos

8. Creá un snapshot **interno** (estado + disco dentro del propio qcow2) del dominio encendido:
   ```bash
   virsh snapshot-create-as vm-lab \
     --name snap-pre-upgrade \
     --description "antes de actualizar kernel"
   virsh snapshot-list vm-lab
   ```
   ```
    Name               Creation Time               State
   ------------------------------------------------------------
    snap-pre-upgrade   2026-08-11 18:59:41 -0300   running
   ```
9. Creá un snapshot **externo** sólo de disco (crea un overlay nuevo y deja el original como backing, base de backups en caliente):
   ```bash
   virsh snapshot-create-as vm-lab \
     --name snap-ext-01 \
     --disk-only \
     --atomic \
     --diskspec vda,snapshot=external
   virsh domblklist vm-lab      # notá que vda ahora apunta a un overlay .snap-ext-01
   ```
10. Revisá metadatos y revertí al snapshot interno; luego eliminá metadatos:
    ```bash
    virsh snapshot-info    vm-lab snap-pre-upgrade
    virsh snapshot-revert  vm-lab snap-pre-upgrade
    virsh snapshot-delete  vm-lab snap-pre-upgrade
    ```

> **Preguntas — Bloque C**
> 1. Diferenciá snapshot **interno** de **externo**: ¿dónde vive el delta en cada caso y por qué los externos son la vía para *backups en caliente*?
> 2. ¿Por qué un snapshot con estado de RAM (`running`/`--live` sin `--disk-only`) requiere más que sólo el disco para restaurar consistentemente?
> 3. `virsh snapshot-delete --metadata` borra sólo los metadatos de libvirt: ¿qué queda "huérfano" y qué herramienta necesitás para consolidar (block-commit) la cadena de overlays?

---

## Diagnóstico avanzado (transversal a todo el tema)

- **Logs por dominio:** `/var/log/libvirt/qemu/<dominio>.log` contiene la línea `qemu` real y errores de arranque.
- **Eventos en vivo:** `virsh event --domain vm-lab --loop --all` muestra transiciones de estado en tiempo real (útil para depurar apagados inesperados).
- **Métricas:** `virsh domstats vm-lab` y `virsh domstats --list-active` exponen CPU, memoria, block e interfaces en un solo vistazo.
- **Traza del daemon:** subí verbosidad con `virt-admin -c virtqemud:///system daemon-log-filters "3:qemu 3:conf"` o `LIBVIRT_DEBUG=1 virsh ...` para el cliente.
- **Definición efectiva vs inactiva:** `virsh dumpxml --inactive vm-lab` muestra el XML persistente; sin `--inactive`, el estado *live* (que puede diferir tras hotplug con sólo `--live`).

---

## Fuentes oficiales

- LPI — Exam 305 Objectives (351.4): <https://www.lpi.org/our-certifications/exam-305-objectives/>
- libvirt — Daemons y modelo modular: <https://libvirt.org/daemons.html>
- libvirt — Connection URIs: <https://libvirt.org/uri.html>
- libvirt — `virsh` manpage: <https://libvirt.org/manpages/virsh.html>
- libvirt — Domain XML format: <https://libvirt.org/formatdomain.html>
- libvirt — Network XML format: <https://libvirt.org/formatnetwork.html>
- libvirt — Storage pools & volumes: <https://libvirt.org/formatstorage.html> · <https://libvirt.org/storage.html>
- libvirt — Snapshots: <https://libvirt.org/formatsnapshot.html>
- `virt-install(1)` / `virt-manager`: <https://virt-manager.org/>

---

<details>
<summary><strong>Respuestas — verificación de comprensión</strong></summary>

### Ejercicio 1

**Bloque A**
1. Con daemons modulares (`virtqemud`, `virtnetworkd`, `virtstoraged`, `virtnodedevd`, …) cada subsistema corre en su propio proceso: un fallo o reinicio de, por ejemplo, el daemon de storage no tumba la gestión de QEMU ni de red. Además arrancan **on-demand** vía socket activation, reduciendo footprint y superficie de ataque, y permiten reiniciar/actualizar un componente sin cortar todos los demás. El monolítico `libvirtd` concentra todo en un proceso (un fallo lo afecta todo).
2. Sí. Con socket activation, el `.socket` escuchando basta: al primer contacto de `virsh`, systemd arranca `virtqemud.service` automáticamente. El `.service` en `inactive` no significa "sin capacidad", sino "aún no despertado".
3. El grupo `libvirt` (el socket RW `virtqemud-sock` es `srw-rw---- root libvirt`). Por eso se agrega al usuario a ese grupo para operar sin `sudo`.

**Bloque B**
1. `qemu:///system` habla con el daemon privilegiado del sistema: las VMs corren como servicio del host (típicamente bajo el usuario `qemu`/`libvirt-qemu`), con acceso a `/var/lib/libvirt/images`, redes NAT/bridge del host, etc. `qemu:///session` es una instancia por-usuario sin privilegios: las VMs corren con tu UID, en tu sesión, con storage/red propios y limitados (por ejemplo, red por usermode/SLIRP o passt). Son *namespaces* de gestión separados; cada daemon sólo conoce sus propios dominios, por eso no se ven entre sí.
2. `qemu+ssh://usuario@hv02/system` (túnel SSH al daemon de sistema del host remoto).
3. Orden habitual: (1) la opción `-c/--connect`; (2) la variable de entorno `LIBVIRT_DEFAULT_URI`; (3) el archivo de configuración del cliente (`uri_default` en `libvirt.conf`); (4) autodetección del hypervisor disponible en el host.

**Bloque C**
1. `virsh capabilities` describe el **host**: arquitecturas soportadas, topología física de CPU/NUMA, features, tipos de invitado que el hypervisor puede correr. `virsh domcapabilities` describe lo que un **driver/tipo de dominio** concreto acepta (máquinas `q35`/`i440fx`, firmware BIOS/UEFI, modelos de CPU, buses de disco…). Usás `capabilities` para saber qué puede el host; `domcapabilities` para validar que un XML concreto (esa máquina, esa CPU, ese firmware) es realizable antes de definir el dominio.
2. 8 vCPUs físicas = 1 socket × 4 cores × 2 threads.
3. Causas probables: (a) `/dev/kvm` ausente o sin permisos (módulo `kvm_intel`/`kvm_amd` no cargado, o virtualización deshabilitada en BIOS aunque el flag aparezca), (b) virtualización anidada/hypervisor que no expone KVM, o (c) el paquete/daemon de QEMU está sin la integración KVM habilitada.

### Ejercicio 2

**Bloque A**
1. `--os-variant` consulta la base de datos de `libosinfo` y ajusta el XML a lo que ese SO soporta bien: por ejemplo, elige buses/drivers `virtio` (disco y red), el modelo de reloj/timers correcto, tamaño de RAM y features de CPU razonables, y activa dispositivos que el guest reconoce sin instalar drivers manualmente. Mejora rendimiento y compatibilidad "out of the box".
2. `virtio` es paravirtualizado: el guest usa drivers conscientes del hypervisor, evitando emular hardware real (como `e1000`/`sata`). Resultado: menos overhead de CPU, mayor throughput de I/O de disco y red, y menor latencia. Es el estándar de producción para guests que soportan virtio (Linux moderno, Windows con drivers virtio instalados).
3. `--noautoconsole` no abre automáticamente la consola gráfica/serie tras crear la VM; el comando retorna y la instalación sigue en background (la seguís por VNC/`virsh console`). Sin la opción, `virt-install` intenta abrir una consola interactiva y bloquea la terminal hasta cerrarla.

**Bloque B**
1. `shutdown` envía una señal ACPI de apagado al guest, que decide apagarse ordenadamente (flush de disco, cierre de servicios). Si el guest no atiende ACPI (sin daemon acpid, colgado, o SO que lo ignora), "no pasa nada". `destroy` corta la VM de inmediato a nivel de host (equivale a tirar del cable), sin avisar al guest: puede corromper datos no sincronizados.
2. En `paused` la vCPU está congelada (no consume ciclos de CPU del host para ejecutar el guest), pero **sí** mantiene reservada su RAM y su estado de dispositivos en memoria. Se reactiva con `virsh resume`.
3. `destroy` cambia el **estado de ejecución** (apaga la instancia) pero conserva la definición persistente (el XML sigue). `undefine` elimina la **definición persistente** (el XML), no necesariamente la ejecución: si la VM corría, pasa a ser transitoria y desaparece al apagarse.

**Bloque C**
1. En `/etc/libvirt/qemu/<dominio>.xml`. No se edita a mano porque libvirt mantiene ese archivo y puede reescribirlo; los cambios manuales pueden perderse o quedar inconsistentes con el estado en memoria del daemon. La vía correcta es `virsh edit` (valida contra el esquema y notifica al daemon) o `virsh define`.
2. El daemon que arranca los autostart de QEMU es `virtqemud` (o `libvirtd` en el modelo monolítico); los autostart son symlinks en `/etc/libvirt/qemu/autostart/`. Verificarías `systemctl is-enabled virtqemud.service`/`virtqemud.socket`, que el symlink exista, los logs de arranque del host y el `.log` del dominio.
3. Al `undefine` de una VM *running*, la VM sigue viva pero ahora es **transitoria** (sin XML persistente). Cuando después la apagás, desaparece por completo (no queda definición para volver a arrancarla). Por eso conviene `virsh dumpxml` antes, para poder `virsh define` de nuevo.

### Ejercicio 3

**Bloque A**
1. `virbr0` es el bridge/switch virtual del host al que se conectan las interfaces `vnetX` de las VMs de esa red. En modo `nat`, el host enmascara (MASQUERADE/SNAT) el tráfico saliente de `192.168.122.0/24`, así las VMs salen a Internet con la IP del host y su red privada no es visible en la LAN.
2. Un `dnsmasq` por red le da a cada red su propio DHCP (rango, reservas) y DNS local aislado, sin tocar la resolución del host ni chocar con otras redes virtuales. Escucha atado a la IP del bridge de esa red (p. ej. `192.168.122.1`).
3. No sin configuración extra. En `nat`, el tráfico entrante iniciado desde la LAN no tiene ruta ni DNAT hacia la red privada. Para exponer un servicio hay que hacer *port-forwarding* (hook de red/`iptables`/nftables) o usar `mode='route'`/`bridge`.

**Bloque B**
1. En `route` libvirt **añade** reglas de firewall (forward, anti-spoofing, etc.) para el subnet; en `open` **no toca** el firewall: asume que vos gestionás las reglas. `open` es más flexible pero deja la seguridad enteramente en tus manos.
2. En `route` no hay NAT: la LAN física recibe paquetes con la IP privada de la VM como origen, pero no sabe cómo devolverle el tráfico. Falta una **ruta estática** en el gateway/router de la LAN hacia ese subnet apuntando al host libvirt (o el subnet debe ser ruteable en la red).
3. Porque en `bridge` la VM se enchufa a un bridge del host ya existente que pertenece a la red física/externa; el direccionamiento y DHCP los provee esa red externa (el router de la LAN), no libvirt. libvirt sólo conecta la interfaz.

**Bloque C**
1. `net-define` crea una red **persistente** (con XML en `/etc/libvirt/qemu/networks/`), que sobrevive al reboot y puede hacerse `autostart`. `net-create` crea una red **transitoria** que existe sólo hasta detenerla o reiniciar el host. Persiste `net-define`.
2. `--live` aplica el cambio a la instancia en ejecución (efecto inmediato); `--config` lo persiste en el XML para el próximo arranque. Con ambos, cambia ahora y queda guardado. Si omitís `--config`, el cambio se pierde al reiniciar la red/host (sólo fue *live*).
3. Posibles causas: (a) el `dnsmasq` de esa red no está corriendo o no escucha en el bridge (revisar `ps`/logs, `net-info`); (b) la interfaz de la VM no está realmente conectada a `isolated` (verificar `domiflist`), o el guest tiene el link down / firewall interno bloqueando DHCP; también un rango DHCP mal definido o agotado.

### Ejercicio 4

**Bloque A**
1. Un *pool* es un repositorio de almacenamiento gestionado por libvirt (un directorio, un VG LVM, un target iSCSI, un pool RBD/Gluster, etc.); un *volume* es una unidad de almacenamiento **dentro** de un pool (un archivo qcow2/raw, un LV, una LUN). Desde libvirt, un volume siempre pertenece a un pool; podés usar discos "fuera de pool" apuntando por ruta directa en el XML del dominio, pero entonces no los gestiona el subsistema de storage.
2. Ejemplos: `logical` (LVM: volúmenes como LVs, útil para performance y snapshots LVM), `netfs` (NFS montado: storage compartido entre hosts para migración), `iscsi` (LUNs de una SAN), `rbd` (Ceph, storage distribuido para clusters), `disk` (particiones de un disco físico), `fs` (una partición/filesystem dedicado). Cada uno encaja según si necesitás compartición, escala o rendimiento.
3. `Capacity` es el tamaño **virtual** (lógico) máximo; `Allocation` es el espacio **realmente ocupado** en el respaldo (thin: crece con el uso); `Available` es el espacio libre del pool. En qcow2 thin, `Allocation` ≪ `Capacity` hasta que se escriben datos.

**Bloque B**
1. Para `dir`, `pool-build` crea el directorio target (mkdir) si no existe. Para `logical` (LVM), inicializa/crea el Volume Group (`vgcreate`) sobre los PVs indicados. Para `fs`, puede preparar/formatear el filesystem del dispositivo respaldo. En pools ya provistos (p. ej. `netfs` ya montable) suele no ser necesario.
2. `pool-define-as` crea el pool **persistente** (XML guardado); `pool-create-as` lo crea **transitorio**. Para que exista tras reboot necesitás `define` (y opcionalmente `pool-autostart`).
3. Porque el pool `dir` sólo comprueba/usa el path; si el `target` es un mountpoint aún no montado, libvirt operaría sobre el directorio vacío del filesystem raíz (o falla la validación de montaje). Hay que garantizar el montaje antes de `pool-start` (o usar un pool `fs`/`netfs` que libvirt monte).

**Bloque C**
1. Ganás: aprovisionamiento instantáneo y ahorro de espacio (el overlay sólo guarda los deltas sobre el base común, ideal para clonar N VMs desde una imagen dorada). Riesgo: **dependencia** del base — si el base se corrompe, borra o cambia, todos los overlays quedan inservibles; además cadenas largas degradan rendimiento.
2. La VM falla: qcow2 necesita el backing file para resolver los bloques no escritos en el overlay. Al faltar `base.qcow2`, las lecturas de esos bloques no se pueden resolver y el disco queda inconsistente/ilegible.
3. `vol-delete` elimina el volumen (desasigna/borra el archivo) pero no garantiza sobrescritura del contenido; `vol-wipe` **sobrescribe** los datos (patrones/ceros) antes de liberar, para que no sean recuperables. Antes de dar de baja un disco con datos sensibles: `vol-wipe` y luego `vol-delete`.

### Ejercicio 5

**Bloque A**
1. `--live` modifica el dominio en ejecución (QEMU en memoria), por eso el cambio desaparece al reiniciar: el arranque relee el XML persistente, que no lo incluye. `--config` escribe en el XML persistente (efecto en el próximo boot). Combinás `--live --config` cuando querés el cambio **ahora y para siempre** (que persista al reiniciar).
2. `maxMemory` define el **techo** de RAM que QEMU reservó/planificó al arrancar (slots de memoria, direccionamiento); cambiarlo requiere reconstruir la topología de memoria del dominio, lo que sólo es seguro con la VM apagada. `currentMemory` (`setmem`) mueve la asignación **dentro** de ese techo ya existente, algo que sí se puede hacer en vivo.
3. El **balloon driver** (`virtio-balloon`) permite "inflarse" para devolver RAM al host y reducir la asignada por debajo del máximo sin reiniciar. Requiere que el driver esté presente y activo **dentro del guest** (kernel con virtio-balloon); si el guest no coopera, el globo no puede reclamar memoria.

**Bloque B**
1. `virsh edit` valida el XML contra el **esquema RNG** de libvirt y, si es válido, lo aplica atómicamente y notifica al daemon, evitando dejar el dominio con una definición malformada. Editar el archivo a mano puede introducir XML inválido o inconsistente con el estado en memoria; `reload` del servicio no garantiza validación equivalente ni sincronía segura.
2. `emulatorpin` fija el/los hilos del proceso emulador de QEMU (I/O, tareas no-vCPU) a CPUs concretas, aparte de las vCPUs (`vcpupin`). En cargas *latency-sensitive*, separar el hilo emulador de los cores donde corren las vCPUs evita que el trabajo de I/O del emulador introduzca jitter/robo de CPU en los cores de cómputo del guest.
3. Con `--live --config`, el guest ve el disco **de inmediato** (hotplug) y además queda en el XML persistente para el próximo arranque. Con `--config` a secas, el cambio **sólo** se aplica al XML: el guest en ejecución **no** lo ve hasta reiniciarse.

**Bloque C**
1. Interno: el delta y (opcionalmente) el estado se guardan **dentro del propio qcow2** (una imagen con varios puntos). Externo: libvirt crea un **archivo overlay nuevo** y deja la imagen previa como backing de sólo lectura; el delta va al overlay. Los externos habilitan backups en caliente porque podés copiar/consolidar la imagen base congelada mientras la VM sigue escribiendo en el overlay.
2. Un snapshot con RAM captura además el estado de memoria y de dispositivos (registros de CPU, buffers) del momento; para restaurar consistentemente hay que reponer ese estado volátil junto con el disco. Si sólo guardás disco (`--disk-only`), el snapshot es *crash-consistent* pero no restaura una VM "en marcha" al instante exacto.
3. `--metadata` borra el registro del snapshot en libvirt pero **no** toca los archivos de disco: quedan huérfanos los overlays/backing en el filesystem. Para reconsolidar la cadena y colapsar overlays al base se usa `virsh blockcommit` (block-commit) —o `blockpull`— y/o `qemu-img commit`.

</details>