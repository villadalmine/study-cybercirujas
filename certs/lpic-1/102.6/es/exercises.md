# LPIC-1 102.6 — Linux como invitado de virtualización
## Ejercicios guiados (Examen 102-500, versión 5.0 del temario — peso 1)

> **Alcance del objetivo.** Máquinas virtuales frente a contenedores; elementos de IaaS (instancias de cómputo, almacenamiento en bloque, redes); propiedades que deben hacerse únicas cuando un sistema se clona o se usa como plantilla; imágenes de sistema; extensiones de integración del invitado (guest drivers); `cloud-init`.
> Texto oficial del objetivo: <https://www.lpi.org/our-certifications/exam-102-objectives/> (102.6). Objetivos del examen 101, para el examen complementario: <https://www.lpi.org/our-certifications/exam-101-objectives/>

---

### Entorno de laboratorio

| Requisito | Notas |
|---|---|
| Un invitado Linux **descartable** con `systemd` ≥ 245 | Cualquier hipervisor: KVM/QEMU (libvirt), VMware, VirtualBox, Hyper-V, o una instancia de nube pública. Varios pasos destruyen la identidad de la máquina — nunca los ejecutes en un sistema que te importe. |
| `root` / `sudo` | Requerido a partir del Ejercicio 2. |
| Paquetes | `systemd`, `util-linux`, `pciutils`, `dmidecode`, `kmod`, `cloud-init`, `cloud-image-utils` o `genisoimage`/`xorriso`, `jq`, `podman` (o `docker`), `libcap-ng-utils` (`capsh`), `cloud-guest-utils` (`growpart`). |
| Opcional pero recomendado | Acceso de shell al **host hipervisor** (libvirt) para los bloques de hot-plug y de seed ISO. Donde el acceso al host sea imposible, se ofrece una alternativa solo de inspección. |

Tomá un snapshot antes del Ejercicio 3:

```bash
# on the KVM host
virsh snapshot-create-as --domain lab-guest pre-102-6 --atomic
```

---

## Ejercicio 1 — Identificar la plataforma desde dentro del invitado

**Objetivo:** determinar, solo desde el invitado, *si* estás virtualizado, *por qué* y *cómo* (virtualización completa, paravirtualización, contenedor). Esto es lo primero que hacés en cualquier host que no construiste vos.

### Bloque 1.A — Los one-liners de `systemd`

1. Preguntale a `systemd` sobre qué cree que se está ejecutando, e inspeccioná el estado de salida:

   ```bash
   systemd-detect-virt; echo "exit=$?"
   ```

   Esperado en un invitado KVM:

   ```
   kvm
   exit=0
   ```

   Esperado en hardware físico:

   ```
   none
   exit=1
   ```

2. Separá las dos preguntas — *¿estoy en una VM?* y *¿estoy en un contenedor?*

   ```bash
   systemd-detect-virt --vm
   systemd-detect-virt --container
   systemd-detect-virt --chroot; echo "chroot exit=$?"
   ```

   En un invitado KVM que **no** está en un contenedor:

   ```
   kvm
   none
   chroot exit=1
   ```

3. Obtené la misma información más el tipo de chasis declarado por el firmware:

   ```bash
   hostnamectl
   ```

   ```
    Static hostname: lab-guest
          Icon name: computer-vm
            Chassis: vm 🖴
         Machine ID: 4f1a2c9e6b0d4a1f8e2c7b5d3a9f0e11
            Boot ID: 9c0b1d2e3f4a5b6c7d8e9f0a1b2c3d4e
     Virtualization: kvm
   Operating System: Debian GNU/Linux 12 (bookworm)
             Kernel: Linux 6.1.0-18-amd64
       Architecture: x86-64
   ```

4. Escribí una cláusula de guarda reutilizable en scripts de aprovisionamiento:

   ```bash
   if systemd-detect-virt --quiet --container; then
       echo "container: skip kernel tuning, skip NTP, skip firmware updates"
   elif systemd-detect-virt --quiet --vm; then
       echo "VM: install guest agent, enable virtio, disable host-only services"
   else
       echo "bare metal: enable IPMI/BMC monitoring, firmware update policy applies"
   fi
   ```

> **Q1.** `systemd-detect-virt` devolvió `none` y salió con `1`. Dá dos escenarios distintos en los que esta salida sea *incorrecta* — el sistema está de hecho virtualizado.
> **Q2.** ¿Por qué `systemd-detect-virt` expone deliberadamente la respuesta de VM y la de contenedor mediante flags separados en lugar de un único valor? ¿Qué escenario de anidamiento lo hace necesario?
> **Q3.** ¿Cuál de los tres códigos de salida/valores usarías en un módulo de gestión de configuración, y por qué parsear `hostnamectl` es una peor idea?

### Bloque 1.B — Evidencia del firmware (SMBIOS/DMI)

5. Leé las tablas DMI que expone el firmware virtual del hipervisor:

   ```bash
   sudo dmidecode -s system-manufacturer
   sudo dmidecode -s system-product-name
   sudo dmidecode -s system-uuid
   sudo dmidecode -s bios-vendor
   ```

   Valores representativos:

   | Plataforma | `system-manufacturer` | `system-product-name` |
   |---|---|---|
   | QEMU/KVM (libvirt) | `QEMU` o `Red Hat` | `Standard PC (Q35 + ICH9, 2009)` / `KVM` |
   | VMware ESXi | `VMware, Inc.` | `VMware Virtual Platform` / `VMware20,1` |
   | VirtualBox | `innotek GmbH` | `VirtualBox` |
   | Hyper-V | `Microsoft Corporation` | `Virtual Machine` |
   | Amazon EC2 (Nitro) | `Amazon EC2` | `m5.large` |

6. Leé los mismos datos sin `root` y sin `dmidecode`, directamente desde sysfs:

   ```bash
   cat /sys/class/dmi/id/sys_vendor
   cat /sys/class/dmi/id/product_name
   cat /sys/class/dmi/id/bios_vendor
   ls -l /sys/class/dmi/id/product_uuid
   ```

   ```
   QEMU
   Standard PC (Q35 + ICH9, 2009)
   SeaBIOS
   -r-------- 1 root root 4096 Aug 26 09:12 /sys/class/dmi/id/product_uuid
   ```

7. Compará el `system-uuid` del invitado con el UUID de dominio que asignó el hipervisor:

   ```bash
   # in the guest
   sudo dmidecode -s system-uuid
   # on the KVM host
   virsh domuuid lab-guest
   ```

> **Q4.** `product_name` es legible por todo el mundo pero `product_uuid` tiene modo `0400`. ¿Cuál es el razonamiento de seguridad, y qué clase de herramientas de nube dependen de ese UUID?
> **Q5.** Ejecutás `dmidecode` y obtenés `# No SMBIOS nor DMI entry point found`. Nombrá dos escenarios legítimos de virtualización que produzcan esto, y decí cómo identificarías la plataforma en cada uno.

### Bloque 1.C — Evidencia de CPU, clocksource y anillo del kernel

8. Buscá el bit de hipervisor presente en CPUID y la hoja de vendor:

   ```bash
   grep -o ' hypervisor' /proc/cpuinfo | head -1
   lscpu | grep -Ei 'hypervisor|virtualization|model name'
   ```

   ```
    hypervisor
   Model name:            Intel(R) Xeon(R) Gold 6248R CPU @ 3.00GHz
   Virtualization:        VT-x
   Hypervisor vendor:     KVM
   Virtualization type:   full
   ```

9. Revisá el clocksource — un reloj paravirtualizado es prueba de enlightenment del lado del invitado:

   ```bash
   cat /sys/devices/system/clocksource/clocksource0/current_clocksource
   cat /sys/devices/system/clocksource/clocksource0/available_clocksource
   ```

   ```
   kvm-clock
   kvm-clock tsc acpi_pm
   ```

10. Leé lo que decidió el kernel durante el arranque temprano:

    ```bash
    sudo dmesg | grep -Ei 'hypervisor|kvm|vmware|xen|hyper-v|virtio' | head -20
    ```

    ```
    [    0.000000] Hypervisor detected: KVM
    [    0.000005] kvm-clock: Using msrs 4b564d01 and 4b564d00
    [    0.000009] kvm-clock: using sched offset of 1443789 cycles
    [    0.360121] virtio_blk virtio2: [vda] 41943040 512-byte logical blocks (21.5 GB/20.0 GiB)
    ```

11. Atendé el caso especial de Xen (un invitado Xen PV no tiene DMI en absoluto):

    ```bash
    cat /sys/hypervisor/type      2>/dev/null   # -> xen
    cat /sys/hypervisor/uuid      2>/dev/null
    cat /proc/xen/capabilities    2>/dev/null   # -> control_d only on dom0
    ```

> **Q6.** `lscpu` informa `Virtualization: VT-x` **y** `Hypervisor vendor: KVM` en la misma máquina. Explicá ambas líneas — no son contradictorias. ¿Qué te dice cada una sobre lo que podés hacer en este host?

---

## Ejercicio 2 — Guest drivers: dispositivos paravirtualizados y servicios de integración

**Objetivo:** inventariar la pila de drivers que hace a un invitado Linux rápido y administrable, y reproducir la caída de migración de imágenes más común: un initramfs sin `virtio`.

### Bloque 2.A — Inventario de virtio

1. Listá los dispositivos virtio en el bus PCI virtual:

   ```bash
   lspci -nn | grep -i -e virtio -e 'red hat'
   ```

   ```
   00:02.0 SCSI storage controller [0100]: Red Hat, Inc. Virtio block device [1af4:1001]
   00:03.0 Ethernet controller [0200]: Red Hat, Inc. Virtio network device [1af4:1000]
   00:05.0 Unclassified device [00ff]: Red Hat, Inc. Virtio memory balloon [1af4:1002]
   00:06.0 Unclassified device [00ff]: Red Hat, Inc. Virtio RNG [1af4:1005]
   00:07.0 Communication controller [0780]: Red Hat, Inc. Virtio console [1af4:1003]
   ```

2. Mapeá dispositivos a módulos cargados:

   ```bash
   lsmod | grep -E '^virtio|^vmw|^hv_|^vbox'
   lspci -k -s 00:03.0
   ```

   ```
   virtio_net             57344  0
   virtio_blk             20480  3
   virtio_balloon         24576  0
   virtio_rng             16384  0
   virtio_pci             28672  0
   virtio_ring            32768  5 virtio_blk,virtio_net,virtio_pci,virtio_balloon,virtio_rng
   virtio                 16384  5 virtio_blk,virtio_net,virtio_pci,virtio_balloon,virtio_rng

   00:03.0 Ethernet controller: Red Hat, Inc. Virtio network device
           Subsystem: Red Hat, Inc. Device 0001
           Kernel driver in use: virtio-pci
           Kernel modules: virtio_pci
   ```

3. Confirmá las consecuencias de nomenclatura de dispositivos del driver de almacenamiento en uso:

   ```bash
   lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL
   ls -l /dev/disk/by-id/ | head
   ```

   ```
   NAME   SIZE TYPE FSTYPE MOUNTPOINTS MODEL
   vda     20G disk
   ├─vda1  19G part ext4   /
   ├─vda2   1K part
   └─vda5  976M part swap  [SWAP]
   ```

4. Verificá la fuente de entropía y el balloon:

   ```bash
   cat /sys/devices/virtual/misc/hw_random/rng_available
   cat /sys/devices/virtual/misc/hw_random/rng_current
   grep -E 'MemTotal|MemAvailable' /proc/meminfo
   ```

> **Q7.** El listado muestra `/dev/vda`, no `/dev/sda`. ¿Qué dispositivo de almacenamiento virtio está en uso, y qué dos capacidades resignás al elegirlo en lugar de la alternativa?
> **Q8.** `virtio_balloon` está cargado. Describí qué puede hacerle el host a este invitado a través de él, y el modo de fallo que debés prever en un clúster con sobrecompromiso de memoria.
> **Q9.** ¿Por qué la ausencia de `virtio_rng` importa específicamente en el *primer arranque* de una imagen recién desplegada?

### Bloque 2.B — La trampa del initramfs (hacé esto antes de convertir una imagen)

5. Inspeccioná qué drivers de almacenamiento/red están realmente dentro de tu initramfs:

   ```bash
   # Debian/Ubuntu
   lsinitramfs /boot/initrd.img-$(uname -r) | grep -E 'virtio|vmw_pvscsi|hv_storvsc' | sort

   # RHEL/Fedora/SUSE (dracut)
   sudo lsinitrd /boot/initramfs-$(uname -r).img | grep -E 'virtio|vmw_pvscsi|hv_storvsc'
   ```

   ```
   usr/lib/modules/6.1.0-18-amd64/kernel/drivers/block/virtio_blk.ko
   usr/lib/modules/6.1.0-18-amd64/kernel/drivers/net/virtio_net.ko
   usr/lib/modules/6.1.0-18-amd64/kernel/drivers/virtio/virtio_pci.ko
   ```

6. Forzá dentro de la imagen los drivers de *cada* hipervisor en el que podrías terminar:

   ```bash
   # Debian/Ubuntu
   printf '%s\n' virtio_pci virtio_blk virtio_scsi virtio_net vmw_pvscsi vmxnet3 hv_storvsc hv_netvsc \
     | sudo tee -a /etc/initramfs-tools/modules
   sudo update-initramfs -u -k all

   # RHEL/Fedora (host-only mode is the default and is the trap)
   sudo dracut --force --no-hostonly \
     --add-drivers "virtio_pci virtio_blk virtio_scsi virtio_net vmw_pvscsi vmxnet3 hv_storvsc hv_netvsc" \
     /boot/initramfs-$(uname -r).img $(uname -r)
   ```

7. Volvé a verificar, y luego confirmá que el dispositivo raíz se referencia por UUID y no por nombre de kernel:

   ```bash
   sudo lsinitrd /boot/initramfs-$(uname -r).img | grep -c virtio
   grep -E '^\s*[^#]' /etc/fstab
   sudo grep -o 'root=[^ ]*' /proc/cmdline
   ```

   ```
   UUID=6d1b0a7c-...  /      ext4  errors=remount-ro 0 1
   root=UUID=6d1b0a7c-9f2e-4a11-8b30-1c7d5e2f8a44
   ```

> **Q10.** Una imagen de VM construida en VMware arranca en ESXi pero entra en pánico con `VFS: Unable to mount root fs on unknown-block(0,0)` tras importarla a KVM. Dá la causa precisa y el arreglo de dos comandos (asumí que podés montar la imagen con `guestmount` o arrancar una ISO de rescate).
> **Q11.** ¿Por qué `root=/dev/sda1` en `/etc/fstab` y en la línea de comandos del kernel vuelve a una imagen no portable entre hipervisores, mientras que `root=UUID=…` sobrevive?

### Bloque 2.C — Servicios de integración / agentes de invitado

8. Identificá e iniciá el agente que corresponde a tu plataforma:

   ```bash
   # KVM/QEMU
   sudo systemctl enable --now qemu-guest-agent
   systemctl is-active qemu-guest-agent
   ls -l /dev/virtio-ports/
   ```

   ```
   active
   lrwxrwxrwx 1 root root 11 Aug 26 09:20 org.qemu.guest_agent.0 -> ../vport1p1
   ```

   ```bash
   # VMware
   sudo systemctl status vmtoolsd
   vmware-toolbox-cmd -v
   vmware-toolbox-cmd stat balloon

   # Hyper-V
   systemctl status hv-kvp-daemon hv-vss-daemon hv-fcopy-daemon
   lsmod | grep hv_

   # VirtualBox
   systemctl status vboxadd vboxadd-service; lsmod | grep vbox
   ```

9. Desde el **host**, ejercitá el agente de KVM y comprobá que funciona sin red en el invitado:

   ```bash
   virsh qemu-agent-command lab-guest '{"execute":"guest-info"}' | jq -r '.return.version'
   virsh domifaddr lab-guest --source agent
   virsh domfsfreeze lab-guest && virsh domfsthaw lab-guest
   ```

10. Restringí qué puede pedirle el host al agente:

    ```bash
    # RHEL-family: /etc/sysconfig/qemu-ga
    BLOCK_RPCS=guest-exec,guest-exec-status,guest-file-open,guest-file-read,guest-file-write
    # equivalently, on the command line:
    # /usr/bin/qemu-ga --block-rpcs=guest-exec,guest-file-open
    sudo systemctl restart qemu-guest-agent
    ```

> **Q12.** `qemu-guest-agent` se comunica por un puerto virtio-serial, no por la red. Enunciá una ventaja operativa y una consecuencia de seguridad de ese diseño, y nombrá la operación de backup específica que solo es correcta cuando el agente está instalado.

---

## Ejercicio 3 — Convertir un sistema en ejecución en una plantilla (el problema de la unicidad)

**Objetivo:** enumerar y neutralizar todo lo que no debe ser idéntico entre clones. Este es el corazón del objetivo 102.6.

> ⚠️ Estos pasos destruyen deliberadamente la identidad de esta máquina. Tomá un snapshot primero. Después del Bloque 3.A tu sesión SSH actual puede sobrevivir, pero se requiere un reinicio para la regeneración.

### Bloque 3.A — `/etc/machine-id` y el machine ID de D-Bus

1. Registrá la identidad actual:

   ```bash
   cat /etc/machine-id
   ls -l /var/lib/dbus/machine-id
   systemd-id128 machine-id
   ls -d /var/log/journal/*/
   ```

   ```
   4f1a2c9e6b0d4a1f8e2c7b5d3a9f0e11
   lrwxrwxrwx 1 root root 15 Jun  4 12:00 /var/lib/dbus/machine-id -> /etc/machine-id
   4f1a2c9e6b0d4a1f8e2c7b5d3a9f0e11
   /var/log/journal/4f1a2c9e6b0d4a1f8e2c7b5d3a9f0e11/
   ```

2. Comprobá si la identidad del cliente DHCP deriva de él (systemd-networkd):

   ```bash
   networkctl status 2>/dev/null | grep -Ei 'duid|client'
   grep -rE 'ClientIdentifier|DUIDType' /etc/systemd/network/ /usr/lib/systemd/network/ 2>/dev/null
   ```

3. Reseteálo de la manera documentada — **truncá, no borres**:

   ```bash
   sudo truncate -s 0 /etc/machine-id
   sudo rm -f /var/lib/dbus/machine-id
   sudo ln -sf /etc/machine-id /var/lib/dbus/machine-id
   ls -l /etc/machine-id
   ```

   ```
   -rw-r--r-- 1 root root 0 Aug 26 09:31 /etc/machine-id
   ```

4. (Opcional, para ver la regeneración sin reiniciar la plantilla) En un *clon*, tras el primer arranque:

   ```bash
   cat /etc/machine-id      # a new 32-hex-digit value
   systemd-analyze | head -1
   systemctl status systemd-firstboot.service
   ```

> **Q13.** ¿Por qué se prefiere `truncate -s 0 /etc/machine-id` a `rm /etc/machine-id`? Dá las dos razones distintas — una sobre la semántica de `systemd` y otra sobre imágenes con `/etc` de solo lectura.
> **Q14.** Dos clones de la misma plantilla arrancan en el mismo segmento L2 y se roban repetidamente la dirección IP entre sí, aunque sus direcciones MAC difieren. Explicá el mecanismo y nombrá el archivo responsable.
> **Q15.** ¿Cuál es la relación entre `/etc/machine-id` y `/var/lib/dbus/machine-id`, y qué se rompe si ambos contienen valores *distintos*?

### Bloque 3.B — Claves de host SSH

5. Registrá las huellas de las claves de host antes de borrarlas:

   ```bash
   for k in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$k"; done
   ```

   ```
   256 SHA256:8Kj2s9dQ... root@lab-guest (ED25519)
   3072 SHA256:pQ0z4Xn... root@lab-guest (RSA)
   256 SHA256:vT7m1Lc... root@lab-guest (ECDSA)
   ```

6. Eliminálas y confirmá el comportamiento de regeneración:

   ```bash
   sudo rm -f /etc/ssh/ssh_host_*
   systemctl list-unit-files | grep -E 'ssh.*keygen|sshd-keygen'
   ```

   ```
   sshd-keygen@.service          static
   ssh-host-keys-migration.service enabled
   ```

7. Forzá la regeneración ahora (lo que el primer arranque del clon hará por vos):

   ```bash
   sudo ssh-keygen -A
   for k in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$k"; done
   ```

8. Hacé que `cloud-init` se encargue de esto, si la imagen está gestionada en la nube:

   ```bash
   sudo tee /etc/cloud/cloud.cfg.d/99-hostkeys.cfg >/dev/null <<'EOF'
   ssh_deletekeys: true
   ssh_genkeytypes: [ed25519, rsa]
   EOF
   ```

> **Q16.** Un equipo clona una plantilla con las claves de host incorporadas. Describí el ataque concreto que esto habilita, y por qué `StrictHostKeyChecking` *no* avisará a los usuarios.
> **Q17.** `ssh-keygen -A` y el `ssh_deletekeys` de `cloud-init` resuelven ambos este problema. ¿Cuándo es cada uno la herramienta correcta?

### Bloque 3.C — El resto de la superficie de identidad

9. Barré el estado por máquina que haya quedado:

   ```bash
   # network identity
   sudo grep -rIl -e HWADDR -e 'mac-address' /etc/sysconfig/network-scripts/ \
        /etc/NetworkManager/system-connections/ 2>/dev/null
   ls -l /etc/udev/rules.d/70-persistent-net.rules 2>/dev/null
   sudo ls -l /var/lib/NetworkManager/*.lease /var/lib/dhcp/*.leases 2>/dev/null

   # entropy and credentials
   sudo ls -l /var/lib/systemd/random-seed /var/lib/systemd/credential.secret

   # storage identity (fatal when two clones attach to one host)
   sudo blkid
   cat /etc/iscsi/initiatorname.iscsi 2>/dev/null

   # agent/CM identity
   ls /etc/salt/minion_id /var/lib/puppet/ssl 2>/dev/null
   ```

10. Cambiá los UUID de sistema de archivos duplicados en un disco clonado (ejecutar desde un entorno de rescate, con el sistema de archivos **desmontado**):

    ```bash
    # ext4
    sudo tune2fs -U random /dev/vdb1
    # XFS (log must be clean)
    sudo xfs_admin -U generate /dev/vdb1
    # swap
    sudo mkswap -U random /dev/vdb5
    # then fix the references
    sudo blkid /dev/vdb1
    # update /etc/fstab and the kernel cmdline / GRUB accordingly
    ```

11. Limpiá historiales y logs que la plantilla no debería llevar:

    ```bash
    sudo rm -rf /var/log/journal/*      # journald recreates per new machine-id
    sudo truncate -s 0 /var/log/wtmp /var/log/lastlog /var/log/btmp
    sudo rm -f /root/.bash_history /home/*/.bash_history
    sudo rm -rf /var/lib/cloud/instances /var/lib/cloud/instance
    ```

> **Q18.** Dos clones de la misma imagen de disco se conectan al mismo host hipervisor. `mount UUID=6d1b0a7c-… /mnt` monta el *equivocado*. Explicá cuáles son realmente las garantías de unicidad de UUID, y por qué `PARTUUID=` tampoco te salva acá.
> **Q19.** Nombrá tres elementos del barrido anterior que *no* estén cubiertos por `cloud-init clean` y deban tratarse explícitamente.

### Bloque 3.D — Automatizar el barrido completo

12. Inspeccioná qué considera "identidad" una herramienta específica — esta lista es en sí misma material de estudio:

    ```bash
    virt-sysprep --list-operations | head -40
    ```

    ```
    abrt-data * Remove the crash data generated by ABRT
    bash-history * Remove the bash history in the guest
    ...
    dhcp-client-state * Remove DHCP client leases
    machine-id * Remove the local machine ID
    ssh-hostkeys * Remove the SSH host keys in the guest
    ssh-userdir * Remove ".ssh" directories in the guest
    udev-persistent-net * Remove udev persistent net rules
    ...
    ```

13. Ejecutála contra un dominio **apagado**:

    ```bash
    virsh shutdown lab-guest
    sudo virt-sysprep -d lab-guest \
      --enable machine-id,ssh-hostkeys,dhcp-client-state,udev-persistent-net,logfiles,bash-history \
      --hostname template
    ```

14. O, para una imagen de nube, el equivalente de `cloud-init`:

    ```bash
    sudo cloud-init clean --logs --seed --machine-id
    sudo shutdown -h now
    ```

---

## Ejercicio 4 — `cloud-init`: el contrato estándar de primer arranque

**Objetivo:** leer el estado de aprovisionamiento de una instancia, escribir e inyectar un datasource `NoCloud`, validarlo antes de que te cueste un arranque, y volver a ejecutarlo de forma determinista.

Referencia: <https://docs.cloud-init.io/en/latest/>

### Bloque 4.A — Inspeccionar el estado de una instancia aprovisionada

1. Estado general y tiempos por etapa:

   ```bash
   cloud-init status --long
   cloud-init analyze blame | head -10
   ```

   ```
   status: done
   extended_status: done
   boot_status_code: enabled-by-generator
   last_update: Tue, 26 Aug 2026 09:12:41 +0000
   detail: DataSourceNoCloud [seed=/dev/sr0][dsmode=net]

   -- Boot Record 01 --
        00.84300s (init-network/config-growpart)
        00.51100s (modules-config/config-apt-configure)
        00.19200s (init-network/config-ssh)
   ```

2. ¿Qué datasource ganó, y qué proveyó?

   ```bash
   cloud-init query --all | jq '{ds: .v1.platform, id: .v1.instance_id, region: .v1.region, hostname: .v1.local_hostname}'
   cloud-init query ds.meta_data 2>/dev/null | head
   sudo grep -E 'Datasource|datasource' /var/log/cloud-init.log | tail -5
   sudo cat /run/cloud-init/ds-identify.log | tail -20
   ```

3. Recorré la máquina de estados en disco:

   ```bash
   ls -l /var/lib/cloud/
   ls -l /var/lib/cloud/instance          # symlink -> instances/<instance-id>
   ls /var/lib/cloud/instance/sem/        # per-instance semaphores
   ls /var/lib/cloud/sem/                 # per-once semaphores
   cat /var/lib/cloud/instance/user-data.txt
   ```

   ```
   /var/lib/cloud/instance -> /var/lib/cloud/instances/iid-lab-102-6-0001
   config_scripts_users_groups.once
   config_ssh.once
   config_growpart.once
   ```

4. Mapeá etapas a units (notá el renombrado en 24.3+):

   ```bash
   systemctl list-units --all 'cloud-*'
   systemd-analyze critical-chain cloud-final.service | head -12
   ```

   ```
   cloud-init-local.service     Local stage   (datasource discovery, network config)
   cloud-init-network.service   Network stage (formerly cloud-init.service: disks, mounts, users, ssh)
   cloud-config.service         Config stage  (packages, apt, timezone, ntp)
   cloud-final.service          Final stage   (runcmd, user scripts, phone-home)
   ```

> **Q20.** Ordená las cuatro etapas y decí, para cada una, la única cosa que *no* debés intentar hacer en ella. ¿Por qué `runcmd` puede alcanzar la red pero no se puede asumir lo mismo de `bootcmd`?
> **Q21.** `/var/lib/cloud/instance` es un symlink cuyo destino lleva el nombre del `instance-id`. Derivá solo de ese hecho el mecanismo por el cual `cloud-init` decide volver a ejecutar los módulos por instancia.

### Bloque 4.B — Escribir e inyectar un datasource `NoCloud`

5. Escribí `meta-data`:

   ```yaml
   # meta-data
   instance-id: iid-lab-102-6-0001
   local-hostname: guest-lab
   ```

6. Escribí `user-data` (nota: la línea `#cloud-config` es obligatoria y debe ser la línea 1):

   ```yaml
   #cloud-config
   hostname: guest-lab
   fqdn: guest-lab.lab.internal
   prefer_fqdn_over_hostname: true

   users:
     - name: sre
       gecos: Lab operator
       # Debian/Ubuntu: sudo | RHEL/Fedora/SUSE: wheel
       groups: [sudo, adm]
       sudo: "ALL=(ALL) NOPASSWD:ALL"
       shell: /bin/bash
       lock_passwd: true
       ssh_authorized_keys:
         - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyReplaceMe sre@bastion

   ssh_pwauth: false
   ssh_deletekeys: true
   ssh_genkeytypes: [ed25519, rsa]

   write_files:
     - path: /etc/sysctl.d/60-lab.conf
       owner: root:root
       permissions: "0644"
       content: |
         vm.swappiness = 10
         net.ipv4.tcp_slow_start_after_idle = 0

   growpart:
     mode: auto
     devices: ["/"]
     ignore_growroot_disabled: false
   resize_rootfs: true

   package_update: true
   packages:
     - qemu-guest-agent
     - jq

   bootcmd:
     - [ cloud-init-per, once, mkdir-data, mkdir, -p, /srv/data ]

   runcmd:
     - [ systemctl, enable, --now, qemu-guest-agent ]
     - [ sysctl, --system ]

   final_message: "cloud-init $version finished at $timestamp, after $UPTIME seconds; datasource $datasource"
   ```

7. Validá **antes** de gastar un arranque en ello:

   ```bash
   cloud-init schema --config-file user-data --annotate
   ```

   ```
   Valid schema user-data
   ```

   Ahora rompelo a propósito y observá el diagnóstico:

   ```bash
   sed -i 's/^packages:/package:/' user-data
   cloud-init schema --config-file user-data --annotate
   ```

   ```
   #cloud-config
   ...
   package:		# E1
   ...
   # E1: Additional properties are not allowed ('package' was unexpected)
   ```

   Restauralo: `sed -i 's/^package:/packages:/' user-data`

8. Construí el medio de seed (la etiqueta del sistema de archivos **debe ser `CIDATA`**):

   ```bash
   # simplest, if cloud-image-utils is installed
   cloud-localds seed.iso user-data meta-data

   # explicit equivalent
   genisoimage -output seed.iso -volid CIDATA -joliet -rock user-data meta-data
   # or
   xorriso -as mkisofs -o seed.iso -V CIDATA -J -r user-data meta-data

   blkid seed.iso
   ```

   ```
   seed.iso: UUID="2026-08-26-09-40-00-00" LABEL="CIDATA" TYPE="iso9660"
   ```

9. Adjuntálo y arrancá:

   ```bash
   virt-install --name lab-guest2 --memory 2048 --vcpus 2 \
     --disk /var/lib/libvirt/images/lab-guest2.qcow2,bus=virtio \
     --disk /var/lib/libvirt/images/seed.iso,device=cdrom \
     --import --os-variant debian12 --network network=default,model=virtio --noautoconsole
   ```

   *¿No tenés host hipervisor?* En su lugar, sembrá directamente el sistema en ejecución:

   ```bash
   sudo mkdir -p /var/lib/cloud/seed/nocloud-net
   sudo cp user-data meta-data /var/lib/cloud/seed/nocloud-net/
   sudo cloud-init clean --logs
   sudo reboot
   ```

> **Q22.** ¿Por qué `#cloud-config` debe ser la *primera* línea, y qué pasa si el archivo empieza con `---`?
> **Q23.** ¿Cuál es la diferencia entre las variantes `NoCloud` y `NoCloudNet` (`nocloud-net`), y qué parámetro de la línea de comandos del kernel selecciona esta última?
> **Q24.** Ponés `groups: [sudo]` en una plantilla usada tanto en Debian como en RHEL. ¿Cuál es el fallo observable en RHEL, y cómo escribís esto de forma portable?

### Bloque 4.C — Reejecutar, depurar, restringir

10. Reejecutá un módulo sin reiniciar:

    ```bash
    sudo cloud-init single --name cc_write_files --frequency always
    sudo cloud-init single --name cc_runcmd --frequency always
    ```

11. Forzá un reaprovisionamiento completo:

    ```bash
    sudo cloud-init clean --logs --seed
    sudo cloud-init init --local && sudo cloud-init init
    sudo cloud-init modules --mode=config && sudo cloud-init modules --mode=final
    cloud-init status --long
    ```

12. Deshabilitá `cloud-init` de forma permanente en una imagen dorada que *no* esté gestionada en la nube:

    ```bash
    sudo touch /etc/cloud/cloud-init.disabled
    # or, at the kernel command line: cloud-init=disabled
    ```

13. Impedí que `cloud-init` reescriba tu configuración de red:

    ```bash
    sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg >/dev/null <<'EOF'
    network: {config: disabled}
    EOF
    ```

14. Fijá el datasource para que `ds-identify` no sondee (ahorra segundos de arranque y elimina una clase de sorpresas):

    ```bash
    sudo tee /etc/cloud/cloud.cfg.d/90-datasource.cfg >/dev/null <<'EOF'
    datasource_list: [ NoCloud, None ]
    EOF
    ```

> **Q25.** `cloud-init clean` sin `--seed` deja la instancia reejecutable pero siendo la *misma* instancia. Explicá qué elimina `--seed` y por qué omitirlo suele ser lo correcto en una instancia de nube real.
> **Q26.** Un módulo que agregaste a `cloud_final_modules` nunca se ejecuta, y `cloud-init status` dice `done`. Enumerá las tres comprobaciones que hacés, en orden.

---

## Ejercicio 5 — Máquinas virtuales frente a contenedores, demostrado

**Objetivo:** mostrar empíricamente que un contenedor comparte el kernel del host mientras que una VM no, y distinguir un contenedor de *aplicación* de un contenedor de *sistema*.

### Bloque 5.A — Detección desde dentro

1. Iniciá un contenedor de aplicación e interrogálo:

   ```bash
   podman run --rm -it --name probe registry.access.redhat.com/ubi9/ubi:latest bash
   ```

   Dentro:

   ```bash
   systemd-detect-virt --container ; echo "exit=$?"
   cat /proc/1/cgroup
   tr '\0' '\n' < /proc/1/environ | grep -i '^container='
   ls -la /run/.containerenv /.dockerenv 2>/dev/null
   uname -r
   ```

   ```
   podman
   exit=0
   0::/
   container=podman
   -rw-r--r-- 1 root root 0 Aug 26 09:50 /run/.containerenv
   6.1.0-18-amd64
   ```

2. Salí y comprobá contra el host:

   ```bash
   uname -r
   systemd-detect-virt --container
   ```

   ```
   6.1.0-18-amd64
   none
   ```

> **Q27.** La cadena de versión del kernel es idéntica byte a byte dentro y fuera del contenedor. Enunciá el único hecho arquitectónico que esto demuestra, y derivá de él dos cosas que un contenedor **no puede** hacer y una VM sí.
> **Q28.** `systemd-detect-virt` dentro de un contenedor que corre sobre un invitado KVM imprime `podman` para `--container` y `kvm` para `--vm`. ¿Cuál es el nombre práctico de esta disposición, y en cuál de las dos respuestas debería confiar un script del tipo "¿debería ajustar `vm.swappiness`?".

### Bloque 5.B — Construir el aislamiento a mano

3. Mirá los namespaces que el kernel mantiene actualmente:

   ```bash
   lsns -o NS,TYPE,NPROCS,PID,COMMAND | head
   ls -l /proc/self/ns/
   ```

   ```
   4026531835 cgroup     241     1 /sbin/init
   4026531836 pid        241     1 /sbin/init
   4026531837 user       241     1 /sbin/init
   4026531840 net        241     1 /sbin/init
   4026532191 mnt          2  1842 /usr/lib/systemd/systemd-udevd
   ```

4. Creá un "contenedor" no privilegiado con nada más que `util-linux`:

   ```bash
   unshare --user --map-root-user --mount --pid --fork --uts --ipc --mount-proc bash
   ```

   Dentro:

   ```bash
   id
   hostname mini-container && hostname
   ps -ef
   readlink /proc/self/ns/pid
   cat /proc/self/status | grep -E 'CapEff|Seccomp|NoNewPrivs'
   ```

   ```
   uid=0(root) gid=0(root) groups=0(root),65534(nogroup)
   mini-container
   UID  PID  PPID  C STIME TTY  TIME     CMD
   root   1     0  0 09:55 pts/0 00:00:00 bash
   root   9     1  0 09:55 pts/0 00:00:00 ps -ef
   pid:[4026532285]
   CapEff: 000001ffffffffff
   NoNewPrivs: 1
   ```

5. Demostrá que ese "root" no es el root del host:

   ```bash
   touch /etc/proof-of-root      # -> Permission denied
   exit
   grep -E '^(uid|gid) ' /proc/self/uid_map 2>/dev/null
   ```

6. Inspeccioná la mitad de recursos de la historia (cgroups v2):

   ```bash
   cat /sys/fs/cgroup/cgroup.controllers
   systemd-run --scope -p MemoryMax=64M -p CPUQuota=20% --user bash -c 'cat /sys/fs/cgroup/$(awk -F: "{print \$3}" /proc/self/cgroup)/memory.max'
   ```

> **Q29.** Namespaces y cgroups resuelven dos problemas distintos. Nombrá cada problema, y decí a cuál de los dos manipula un flag `--memory=512m`.
> **Q30.** Dentro de la sesión `unshare`, `CapEff` muestra un conjunto completo de capacidades, pero `touch /etc/proof-of-root` falla. Explicá esta aparente contradicción con precisión.

### Bloque 5.C — Contenedor de aplicación frente a contenedor de sistema

7. Ejecutá un contenedor de **sistema** — un init completo dentro de un namespace:

   ```bash
   sudo systemd-nspawn --directory=/var/lib/machines/deb12 --boot --network-veth
   # from the host:
   machinectl list
   machinectl shell deb12
   ```

   ```
   MACHINE CLASS     SERVICE        OS     VERSION ADDRESSES
   deb12   container systemd-nspawn debian 12      169.254.31.7…
   ```

8. Contrastá los árboles de procesos:

   ```bash
   # application container
   podman run --rm registry.access.redhat.com/ubi9/ubi:latest ps -ef
   # system container
   machinectl shell deb12 /bin/ps -ef | head
   ```

> **Q31.** Definí *contenedor de aplicación* y *contenedor de sistema* en una oración cada uno, y dá la pregunta decisiva que hacés para elegir entre un contenedor de sistema y una VM completa.

---

## Ejercicio 6 — Bloques constructivos de IaaS: instancia de cómputo, almacenamiento en bloque, redes

**Objetivo:** operar las tres primitivas que expone toda plataforma IaaS, desde el lado del invitado.

### Bloque 6.A — El servicio de metadatos de la instancia

1. Consultá el endpoint de metadatos link-local. **EC2 (IMDSv2, requiere token):**

   ```bash
   TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
             -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
   curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
        http://169.254.169.254/latest/meta-data/instance-id
   curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
        http://169.254.169.254/latest/meta-data/placement/availability-zone
   ```

   **OpenStack / compatible con config-drive:**

   ```bash
   curl -s http://169.254.169.254/openstack/latest/meta_data.json | jq '{uuid, name, availability_zone}'
   ```

2. Si no hay servicio de metadatos (KVM privado, `NoCloud`), leé las mismas abstracciones localmente:

   ```bash
   jq '.v1' /run/cloud-init/instance-data.json
   cloud-init query v1.instance_id v1.platform v1.subplatform
   ```

3. Confirmá la ruta que hace alcanzable a `169.254.169.254`:

   ```bash
   ip route get 169.254.169.254
   ```

   ```
   169.254.169.254 via 10.0.0.1 dev enp1s0 src 10.0.0.42 uid 1000
   ```

> **Q32.** IMDSv2 exige un `PUT` para obtener un token e impone un TTL de IP bajo en la respuesta. ¿Qué clase específica de vulnerabilidad derrota eso, y por qué IMDSv1 no lo hacía?
> **Q33.** ¿Por qué `169.254.169.254` es una dirección link-local y no una enrutable, y qué implica eso para un invitado que corre su propio NAT o un overlay de contenedores?

### Bloque 6.B — Almacenamiento en bloque: adjuntar, descubrir, crecer

4. Establecé la línea base de la capa de bloques:

   ```bash
   lsblk -o NAME,MAJ:MIN,SIZE,TYPE,FSTYPE,UUID,MOUNTPOINTS,SERIAL
   df -hT /
   ```

5. Adjuntá en caliente un volumen desde el **host**:

   ```bash
   qemu-img create -f qcow2 /var/lib/libvirt/images/data.qcow2 10G
   virsh attach-disk lab-guest /var/lib/libvirt/images/data.qcow2 vdb \
     --subdriver qcow2 --targetbus virtio --persistent
   ```

6. Observá el descubrimiento en el invitado — con `virtio-blk` no hace falta reescanear:

   ```bash
   sudo dmesg | tail -5
   lsblk /dev/vdb
   ```

   ```
   [ 8123.441] virtio_blk virtio4: [vdb] 20971520 512-byte logical blocks (10.7 GB/10.0 GiB)
   NAME SIZE TYPE MOUNTPOINTS
   vdb   10G disk
   ```

   Para un backend `virtio-scsi` o `pvscsi` de VMware, el descubrimiento es manual:

   ```bash
   ls /sys/class/scsi_host/
   echo "- - -" | sudo tee /sys/class/scsi_host/host2/scan
   lsblk
   ```

7. Formateá, etiquetá y montá de forma persistente por UUID:

   ```bash
   sudo mkfs.xfs -L data /dev/vdb
   sudo blkid /dev/vdb
   echo "UUID=$(sudo blkid -s UUID -o value /dev/vdb) /srv/data xfs defaults,nofail,x-systemd.device-timeout=10s 0 2" \
     | sudo tee -a /etc/fstab
   sudo systemctl daemon-reload && sudo mkdir -p /srv/data && sudo mount -a
   findmnt /srv/data
   ```

8. Hacé crecer el volumen **raíz** en línea — la secuencia exacta que ejecuta una instancia de nube al redimensionar:

   ```bash
   # host: enlarge the backing device
   virsh blockresize lab-guest vda 40G

   # guest: 1) re-read the size (virtio-scsi/SCSI only; virtio-blk is automatic)
   echo 1 | sudo tee /sys/class/block/sda/device/rescan

   # guest: 2) grow the partition (moves the GPT backup header, updates the table)
   sudo growpart /dev/vda 1
   sudo partx -u /dev/vda

   # guest: 3) grow the filesystem
   sudo xfs_growfs /            # XFS: online only, cannot shrink
   # sudo resize2fs /dev/vda1   # ext4
   df -hT /
   ```

9. Confirmá que `cloud-init` habría hecho los pasos 2–3 por vos:

   ```bash
   grep -n -A4 'growpart' /etc/cloud/cloud.cfg
   ls /var/lib/cloud/instance/sem/ | grep -i growpart
   ```

> **Q34.** ¿Por qué `nofail` es innegociable en la entrada de `/etc/fstab` de un volumen de nube *desmontable*? Describí el fallo de arranque exacto que previene.
> **Q35.** Distinguí "volumen de almacenamiento en bloque" de "instance store / disco efímero" en una plataforma IaaS, y nombrá una carga de trabajo que corresponda a cada uno.
> **Q36.** Agrandaste el disco y ejecutaste `xfs_growfs /`, pero `df` sigue mostrando el tamaño viejo. ¿Cuál de los tres pasos se salteó, y cómo lo confirmás solo con la salida de `lsblk`?

### Bloque 6.C — Redes

10. Inspeccioná la interfaz tal como la presenta la plataforma:

    ```bash
    ip -br link show
    ip -br addr show
    ip route show default
    cat /sys/class/net/enp1s0/address
    ethtool -i enp1s0 | head -3
    ip link show enp1s0 | grep -o 'mtu [0-9]*'
    ```

    ```
    enp1s0  UP  52:54:00:9a:3f:12 <BROADCAST,MULTICAST,UP,LOWER_UP>
    enp1s0  UP  10.0.0.42/24 fe80::5054:ff:fe9a:3f12/64
    default via 10.0.0.1 dev enp1s0 proto dhcp src 10.0.0.42 metric 100
    driver: virtio_net
    mtu 1450
    ```

11. Fijá el nombre de la interfaz a la MAC para que un cambio de topología PCI no pueda renombrarla:

    ```bash
    sudo tee /etc/systemd/network/10-uplink.link >/dev/null <<'EOF'
    [Match]
    MACAddress=52:54:00:9a:3f:12

    [Link]
    Name=uplink0
    EOF
    sudo update-initramfs -u   # or: dracut --force
    ```

12. O lo contrario, para una imagen portable — deshabilitá por completo los nombres predecibles:

    ```bash
    # append to the kernel command line
    net.ifnames=0 biosdevname=0
    ```

> **Q37.** La MAC empieza con `52:54:00`. ¿Qué te dice ese prefijo, y por qué una plantilla que fija una MAC en un perfil de conexión de NetworkManager falla en el primer clon?

---

<details>
<summary><strong>Respuestas</strong> — expandir solo después de intentar los ejercicios</summary>

### Ejercicio 1

**Q1.** Dos modos de fallo independientes:
1. **Virtualización anidada o "invisible" con enlightenments ocultos.** Un hipervisor puede configurarse para esconderse: con libvirt/QEMU, `<feature policy='disable' name='hypervisor'/>` (o `-cpu host,-hypervisor`) limpia el bit de hipervisor presente de CPUID, y las cadenas DMI pueden sobrescribirse con `<sysinfo type='smbios'>` para hacerse pasar por un servidor Dell o HP. La antidetección es una configuración soportada (usada para passthrough de GPU y software con licencia atada), así que `none` no es prueba de hardware físico.
2. **Una plataforma paravirtualizada sin DMI y sin hoja de CPUID** — clásicamente un invitado Xen PV, y en otras arquitecturas un invitado KVM sin SMBIOS. La detección ahí requiere `/sys/hypervisor/type` o el device-tree. Históricamente también relevante: correr dentro de un `chroot` en un host virtualizado, donde `--vm` puede seguir respondiendo correctamente pero las herramientas que solo comprueban un eje quedan engañadas.

La conclusión operativa: usá la detección para *optimizar*, nunca para imponer un límite de seguridad.

**Q2.** Porque las dos son ortogonales y se apilan rutinariamente. Un contenedor sobre un invitado KVM sobre hardware físico es la disposición estándar en la nube (Kubernetes gestionado = pods en contenedores, sobre VMs, sobre hosts físicos). Un único valor escalar tendría que elegir una respuesta y mentiría sobre la otra. `--vm` responde "¿hay un hipervisor debajo de mi kernel?"; `--container` responde "¿es mi PID 1 el PID 1 del kernel?" — preguntas distintas con consecuencias distintas. `systemd-detect-virt` sin flag reporta preferentemente la respuesta de **contenedor** cuando aplican ambas, precisamente porque el límite del contenedor es el más restrictivo para el código que pregunta.

**Q3.** Usá el **estado de salida** con `--quiet`: `systemd-detect-virt --quiet --container`. Es un contrato estable y documentado (0 = detectado, 1 = no detectado), no necesita parseo, y no cambia con el locale ni con la versión de `systemd`. La salida de `hostnamectl` está orientada a humanos: las etiquetas de campo son traducibles, el orden no está garantizado, el glifo del icono varía, y la línea `Virtualization:` simplemente se omite en hardware físico — así que un `grep`/`awk` ingenuo produce silenciosamente una cadena vacía en lugar de una respuesta definida.

**Q4.** `product_uuid` es el System UUID de SMBIOS — en un hipervisor equivale al UUID del dominio/instancia, y en muchas plataformas es el valor usado como (o derivado hacia) la **identidad de instancia** en la que confían los servicios de entitlement, licenciamiento y metadatos. Filtrarlo a procesos locales sin privilegios les entrega un token identificador de la máquina; en EC2 basado en Xen, el `DataSourceEc2` de `cloud-init` deriva el ID de instancia de `/sys/hypervisor/uuid`, y los gestores de licencias se apoyan en el UUID de DMI. `product_name` es meramente una cadena de modelo, así que permanece legible por todos. Las herramientas dependientes: descubrimiento de metadatos/datasource en la nube, gestores de suscripción y licencia, y agentes de inventario/CMDB.

**Q5.** Dos casos legítimos:
1. **Invitado Xen PV** — no hay firmware emulado en absoluto, así que no existe un punto de entrada SMBIOS. Identificalo con `cat /sys/hypervisor/type` (`xen`), `/sys/hypervisor/uuid`, y la presencia de `xen_blkfront`/`xen_netfront` en `lsmod`. `/proc/xen/capabilities` conteniendo `control_d` significa que estás en **dom0**, no en un invitado.
2. **Arquitectura no x86 (aarch64, ppc64le, s390x)** o un contenedor. En ARM/POWER la plataforma se describe mediante un **device tree**: `cat /proc/device-tree/hypervisor/compatible`, `cat /proc/device-tree/model`. En s390x usá `/proc/sysinfo` (`read_values -s`). Dentro de un contenedor, `/sys/class/dmi` típicamente ni siquiera está montado — identificá con `systemd-detect-virt --container` y `/proc/1/environ`.

**Q6.** Describen dos capas distintas:
- `Virtualization: VT-x` es una **característica de CPU expuesta a vos**: el flag `vmx` está presente en tu CPU virtual, lo que significa que este invitado puede a su vez correr un hipervisor — es decir, el padre habilitó la **virtualización anidada**. Podrías correr KVM, VirtualBox o una carga KubeVirt de Kubernetes *dentro* de esta VM.
- `Hypervisor vendor: KVM` / `Virtualization type: full` es la **capa por encima tuyo**: la hoja de hipervisor de CPUID identifica a KVM como tu padre, y `full` (a diferencia de `para`) dice que la plataforma presenta una máquina emulada completa en lugar de requerir una ruta de entrada de kernel consciente de PV.

Consecuencia práctica: podés construir VMs acá (anidadas), pero esperá una penalización de rendimiento medible en el segundo nivel, y verificá que el padre haya puesto `kvm_intel.nested=1`.

### Ejercicio 2

**Q7.** `/dev/vda` significa **`virtio-blk`** (cada disco es su propio dispositivo PCI virtio, manejado por `virtio_blk`). Elegirlo en lugar de **`virtio-scsi`** te cuesta:
1. **Passthrough de comandos SCSI** — sin `sg`/`SG_IO`, así que sin reservas persistentes (un requisito duro para clústeres de disco compartido), sin pass-through directo de la semántica SCSI de una LUN física, y sin dispositivos de cinta/cambiador.
2. **Densidad de dispositivos y economía del hot-plug** — `virtio-blk` consume una ranura PCI por disco (aproximadamente 25–30 discos antes de agotar el bus y necesitar puertos raíz PCIe adicionales), mientras que un solo HBA `virtio-scsi` direcciona miles de LUNs. También perdés el conjunto de características más rico de `virtio-scsi` (multiqueue por LUN con `UNMAP`/discard maduro y reporte de WWN, y visibilidad del serial en `/dev/disk/by-id`).

`virtio-blk` se elige por la ruta de E/S más corta y la menor latencia por petición — es el valor por defecto correcto para un único disco raíz.

**Q8.** A través de `virtio_balloon` el host puede **inflar el balloon**: le pide al kernel del invitado que reserve páginas y devuelva sus marcos físicos al host, que luego los reutiliza para otros invitados. Desinflarlo los devuelve. Así es como un hipervisor sobrecompromete memoria sin hacer swap a nivel del host, y así es como `virsh setmem --live` reduce un invitado en ejecución.

El modo de fallo a prever: **OOM del lado del invitado bajo presión de memoria del host.** El `MemTotal` propio del invitado no se reduce reflejando la memoria cedida por el balloon de la manera que las aplicaciones esperan — una JVM dimensionada a partir de `MemTotal` al arrancar, o cualquier proceso que ya haya tocado su heap, será empujado a reclamación y luego al OOM killer mientras el host cree que "liberó" memoria. Mitigaciones: habilitar `deflate-on-oom` (`<memballoon model='virtio'><... />` con la propiedad `deflate-on-oom=on` de QEMU) para que el balloon se contraiga antes de que dispare el OOM killer; fijar un piso duro de `<memory>` por invitado; no sobrecomprometer en absoluto los niveles sensibles a la latencia; y monitorear con `virsh dommemstat` (que requiere fijar el período de sondeo de estadísticas del balloon: `virsh dommemstat <dom> --period 5`).

**Q9.** En el primer arranque la imagen realiza exactamente las operaciones que más entropía consumen y que no pueden diferirse: **generar claves de host SSH** (`ssh-keygen -A`), generar un `machine-id`, sembrar material TLS/PKI, e inicializar el CRNG del kernel antes de que `getrandom(2)` devuelva. En una imagen recién clonada `/var/lib/systemd/random-seed` fue (correctamente) eliminado, y una VM casi no tiene fuentes de entropía — ni tiempos reales de búsqueda en disco, ni teclado, ni jitter genuino de interrupciones. Sin `virtio_rng` alimentando la entropía del host, el arranque puede **bloquearse durante minutos** en el paso de generación de claves y — históricamente peor — implementaciones que caían a fuentes débiles producían **claves predecibles en toda una flota de clones**. `virtio_rng` (más `rngd` atado a `/dev/hwrng`) elimina ambos problemas.

**Q10.** **Causa:** el initramfs de la imagen se construyó en el modo **host-only** por defecto de `dracut` sobre VMware, así que contiene solo `vmw_pvscsi`/`mptspi` y no `virtio_blk`/`virtio_pci`. Arrancada en KVM, el kernel llega al punto de montar la raíz real, no tiene driver para el controlador de bloques virtio, no encuentra dispositivo para el UUID raíz, y entra en pánico con `unknown-block(0,0)`.

**Arreglo** (desde un arranque de rescate o `guestmount`, con chroot dentro de la imagen):

```bash
dracut --force --no-hostonly --add-drivers "virtio_pci virtio_blk virtio_scsi virtio_net" \
  /boot/initramfs-$(uname -r).img $(uname -r)
grub2-mkconfig -o /boot/grub2/grub.cfg     # Debian/Ubuntu: update-initramfs -u -k all && update-grub
```

La prevención duradera es construir imágenes doradas con `--no-hostonly` (o `hostonly=no` en `/etc/dracut.conf.d/`), y en Debian `MODULES=most` en `/etc/initramfs-tools/initramfs.conf`.

**Q11.** Los nombres de dispositivo del kernel son **artefactos del orden de asignación de la pila de drivers**, no propiedades del almacenamiento. El mismo disco es `/dev/sda` detrás de un controlador IDE/SATA o SCSI emulado, `/dev/vda` detrás de `virtio-blk`, `/dev/xvda` detrás del `blkfront` de Xen, y `/dev/nvme0n1` detrás de un controlador NVMe — e incluso dentro de un mismo driver la letra depende del orden de sondeo, que cambia cuando agregás o reordenás controladores. Mover la imagen a otro hipervisor cambia el driver, y por tanto el nombre, y la referencia queda colgando.

Un **UUID de sistema de archivos** está escrito *dentro del superbloque*, así que viaja con los datos sin importar qué driver presenta el dispositivo de bloques. `udev` construye `/dev/disk/by-uuid/<uuid>` a partir del contenido del superbloque tras sondear los dispositivos que existan, así que el mapeo se re-deriva correctamente en cada arranque en cada plataforma. (`LABEL=` tiene la misma propiedad pero no es único por construcción; `PARTUUID=` vive en la GPT y sobrevive a un reformateo pero no a un reparticionado.)

**Q12.** *Ventaja:* el canal es **fuera de banda** — un puerto virtio-serial entre QEMU y el invitado. Funciona cuando el invitado no tiene dirección IP, cuando la configuración de red está rota, cuando una regla de firewall te dejó afuera, y durante el arranque temprano y el apagado. Tampoco necesita un puerto en escucha, así que no agrega superficie de ataque de red y funciona igual en una red aislada.

*Consecuencia de seguridad:* el canal está autenticado únicamente por "sos el hipervisor". Cualquiera con acceso a libvirt/QEMU en el host posee una **ruta de ejecución no autenticada equivalente a root dentro del invitado** — `guest-exec` ejecuta comandos arbitrarios, `guest-file-read`/`guest-file-write` leen y escriben archivos arbitrarios, `guest-set-user-password` restablece credenciales. No hay consentimiento del lado del invitado, ni registro que vos controles, ni forma de exigir una clave. De ahí el paso 10: bloqueá los RPC peligrosos (`--block-rpcs=guest-exec,guest-file-read,…`) en cualquier invitado cuyos administradores de host no estén ya dentro de su límite de confianza. Es también por esto que un hipervisor comprometido es el fin del juego para todos los invitados que aloja.

*La operación de backup:* **snapshots consistentes a nivel de aplicación (quiesced).** Sin el agente, un snapshot es *consistente ante caída* — captura lo que hubiera en disco a mitad de una escritura, y una base de datos restaurada desde él debe ejecutar recuperación y puede perder transacciones en vuelo. Con el agente, `virsh domfsfreeze` invoca `FIFREEZE` en cada sistema de archivos montado (vaciando la page cache y pausando las escrituras) — y, vía `/etc/qemu/fsfreeze-hook`, te permite aquietar la propia base de datos — de modo que el snapshot se toma en un punto consistente y `domfsthaw` reanuda la E/S. El equivalente de VMware es la ruta del driver VSS/sync de `open-vm-tools`; en Hyper-V es `hv_vss_daemon`.

### Ejercicio 3

**Q13.** Dos razones, ambas documentadas en `machine-id(5)`:
1. **Semántica de `systemd`.** Un `/etc/machine-id` vacío es un estado definido que significa "no inicializado" — `systemd` provisiona un ID nuevo en él durante el arranque temprano y, crucialmente, trata el arranque como un **primer arranque** (`ConditionFirstBoot=yes`), de modo que `systemd-firstboot.service`, la aplicación de presets y las units de primer arranque se ejecutan como se pretende para una instancia recién desplegada. Un archivo eliminado produce en su mayoría el mismo resultado en `systemd` moderno, pero el archivo vacío es el estado sobre el que las herramientas y la página de manual establecen el contrato.
2. **`/etc` de solo lectura.** Si `/etc` es de solo lectura (imágenes inmutables/doradas, `ostree`, construcciones de appliance), `systemd` no puede *crear* un archivo — pero **sí puede hacer bind-mount** de un `/run/machine-id` transitorio sobre un archivo existente de longitud cero. Mantener el archivo vacío presente es por lo tanto la única forma en que el mecanismo funciona en absoluto sobre una raíz de solo lectura. Borrá el archivo y un sistema así arranca sin machine ID, rompiendo `journald`, D-Bus y todo lo que llame a `sd_id128_get_machine()`.

**Q14.** El identificador de cliente DHCP por defecto de `systemd-networkd` es un **DUID derivado de `/etc/machine-id`** según RFC 4361 (`ClientIdentifier=duid`, `DUIDType=vendor`). El servidor DHCP indexa su base de datos de leases por el **identificador de cliente (opción 61)** con preferencia sobre la dirección MAC cuando la opción 61 está presente. Dos clones que salieron con el *mismo* `/etc/machine-id` presentan por tanto el *mismo* ID de cliente con MACs distintas — el servidor ve un único cliente que parece haber cambiado de hardware, entrega a ambas máquinas el mismo lease, y la dirección va y viene entre ellas a medida que cada una renueva.

El archivo responsable es **`/etc/machine-id`**. Los arreglos: truncarlo en la plantilla (Bloque 3.A), o poner `ClientIdentifier=mac` en la sección `[DHCPv4]` del archivo `.network`. Notá que esto es un valor por defecto de `systemd-networkd`; el `dhclient` de ISC y NetworkManager pueden indexar por la MAC en su lugar, que es por lo que el síntoma aparece en algunas distribuciones y no en otras a partir de una imagen idéntica.

**Q15.** `/var/lib/dbus/machine-id` es el identificador de máquina histórico de D-Bus, anterior a `systemd`. En las distribuciones modernas es un **symlink a `/etc/machine-id`** para que ambos subsistemas coincidan en un único valor — `dbus-uuidgen --ensure` y `systemd-machine-id-setup` mantienen ambos el mismo ID de 32 dígitos hexadecimales.

Si contienen valores distintos, obtenés una identidad partida: `sd_id128_get_machine()` y `dbus_get_local_machine_id()` devuelven respuestas diferentes, así que cualquier aplicación que indexe estado por máquina, activación de licencia o direccionamiento de sesión de D-Bus a partir de "el machine ID" ve dos máquinas en un solo host. Los síntomas van desde configuración por máquina duplicada (estado de GNOME/keyring, deduplicación de telemetría) hasta fallos de autolaunch de D-Bus. Es exactamente por esto que el procedimiento de plantilla elimina el archivo y recrea el **symlink** en lugar de truncar ambos de forma independiente.

**Q16.** El ataque es un **man-in-the-middle sobre SSH a escala de toda la flota**. Cada clon presenta la misma clave de host idéntica, de modo que la clave privada está presente en cada VM construida desde esa plantilla. Cualquiera que obtenga root en *un* clon — o que simplemente descargue la plantilla/AMI si alguna vez se publicó — posee la clave privada que autentica a *todos* ellos, y puede levantar un servidor falso (o hacer spoofing de ARP/DNS de una dirección existente) que los clientes aceptan como genuino, capturando contraseñas, credenciales reenviadas por el agente y contenido de sesión.

`StrictHostKeyChecking` no avisa porque está funcionando correctamente y no hay nada anómalo que reportar: en el primer contacto con cada host nuevo el cliente ve una clave que no tiene registrada y, con el valor por defecto `ask`, pregunta una vez — una pregunta que los operadores aprueban rutinariamente. Donde la huella ya está en `known_hosts` a partir de un clon hermano bajo un nombre o IP compartidos, la clave *coincide*, así que no es posible advertencia alguna. La comprobación verifica continuidad de clave, no unicidad ni secreto de clave — y una clave filtrada satisface la continuidad perfectamente.

**Q17.**
- **`ssh-keygen -A`** es el arreglo imperativo e inmediato: generar cualquier tipo de clave de host faltante, ahora, en esta máquina. Usalo cuando estés preparando un sistema a mano, reparando un clon que ya arrancó con claves duplicadas, o escribiendo un script de primer arranque para un sistema sin `cloud-init` (un paso de construcción de imagen, una unit oneshot de `systemd` con `ExitType`/`ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key`, un provisioner de Packer).
- **`ssh_deletekeys: true` / `ssh_genkeytypes:`** es la política declarativa por instancia para imágenes gestionadas en la nube: el módulo `cc_ssh` de `cloud-init` elimina cualquier clave presente en la imagen y las regenera en cada *nueva instancia*, y luego opcionalmente reporta las huellas a la consola y al datasource (`phone_home`, salida de consola de EC2) para que el operador pueda verificarlas fuera de banda en el primer inicio de sesión — lo que cierra la brecha de confianza-en-el-primer-uso que `ssh-keygen -A` por sí solo deja abierta.

Usá `cloud-init` cuando la plataforma provee un datasource; usá `ssh-keygen -A` cuando no lo hace; y usá `virt-sysprep --enable ssh-hostkeys` al sanear una imagen de disco detenida sin conexión.

**Q18.** Un UUID de sistema de archivos garantiza unicidad solo **por convención de generación** — `mkfs` extrae un UUID aleatorio (v4) con probabilidad de colisión despreciable — no por imposición. Nada en el kernel, `udev` o `blkid` impide que dos dispositivos de bloques lleven UUIDs de superbloque idénticos, y **clonar una imagen de disco copia el superbloque literalmente**, así que el identificador "único" queda duplicado por construcción.

Cuando dos dispositivos comparten un UUID, `udev` crea un único symlink `/dev/disk/by-uuid/<uuid>` y **gana el último dispositivo sondeado** — el orden de sondeo varía con los tiempos del hot-plug, así que el ganador no es estable entre arranques. `mount UUID=…` resuelve a través de ese symlink y monta el dispositivo que haya ganado la carrera. Siguen modos de fallo peores: una colisión de UUID de PV de LVM en espejo, un `fsck` ejecutado contra el dispositivo equivocado, o un sistema de archivos raíz que se monta desde el disco del *otro* clon.

`PARTUUID=` no ayuda porque está almacenado en la **entrada de partición GPT**, que un clon a nivel de bloque copia con la misma fidelidad que el superbloque. Lo mismo aplica a `PARTLABEL=`, `LABEL=`, los UUIDs de PV/VG de LVM, y los UUIDs de array de mdadm. Los únicos arreglos son re-estampar los identificadores en el clon (`tune2fs -U random`, `xfs_admin -U generate`, `mkswap -U random`, `pvchange -u`, `xfs_admin`/`sgdisk -G` para el GUID de disco GPT) y actualizar cada referencia (`/etc/fstab`, `/etc/crypttab`, la línea de comandos del kernel, GRUB), o directamente evitar conectar dos clones a un mismo host.

**Q19.** `cloud-init clean` elimina `/var/lib/cloud` (estado de instancia, semáforos, datasource cacheado) y, con flags, los logs, el seed y el machine-id. **No** toca:
1. **Claves de host SSH** en `/etc/ssh/` — la regeneración es un *módulo de tiempo de arranque* (`cc_ssh` con `ssh_deletekeys`), no parte de `clean`. Si la imagen nunca arranca con `cloud-init` habilitado, las claves viajan con ella.
2. **UUIDs de sistema de archivos / partición / LVM** — `tune2fs -U`, `xfs_admin -U`, `mkswap -U`, `pvchange -u`. `cloud-init` no tiene noción de colisiones de identidad de almacenamiento.
3. **La semilla aleatoria y el secreto de credenciales de `systemd`** — `/var/lib/systemd/random-seed`, `/var/lib/systemd/credential.secret`.

También fuera de su alcance: historiales de shell y `~/.ssh/authorized_keys` dejados por quien construyó la imagen; `/etc/iscsi/initiatorname.iscsi`; identidades de gestión de configuración (`/etc/salt/minion_id`, `/var/lib/puppet/ssl`, `client.pem` de Chef); identificadores de host de agentes de monitoreo (Zabbix, Datadog, Wazuh); `/etc/udev/rules.d/70-persistent-net.rules`; perfiles de NetworkManager con una `mac-address` fijada; keytabs de Kerberos; secretos sellados por TPM y cabeceras LUKS; certificados de subscription-manager/entitlement; y `/var/log/*` en general. `virt-sysprep --list-operations` es lo más cercano a una checklist canónica — leéla como tal.

### Ejercicio 4

**Q20.** En orden:

| Etapa | Unit | Ejecuta | **No** debe |
|---|---|---|---|
| **Local** | `cloud-init-local.service` (`Before=network-pre.target`) | Descubrimiento del datasource desde medios locales (`ds-identify`), escribe la configuración de red | Asumir que existe **red alguna** — se ejecuta precisamente para que la red pueda configurarse. Sin instalación de paquetes, sin HTTP. |
| **Network** | `cloud-init-network.service` (llamada `cloud-init.service` antes de 24.3) | Obtiene user-data remoto, configuración de discos, particionado, `growpart`, montajes, usuarios, grupos, claves SSH | Asumir que los **metadatos del gestor de paquetes** están actualizados o que los repositorios están configurados — eso es la etapa siguiente. |
| **Config** | `cloud-config.service` | Configuración de `apt`/`yum`, instalación de paquetes, zona horaria, NTP, locale, bootstrap de Puppet/Chef/Ansible | Asumir que los **scripts de usuario** ya se ejecutaron, o que los servicios declarados por los paquetes instalados ya están iniciados. |
| **Final** | `cloud-final.service` (semántica `After=multi-user.target`) | `runcmd`, `scripts-user`, `phone_home`, `final_message`, `power_state` | Asumir que es temprano — el sistema está esencialmente arriba, así que cualquier cosa que necesite preceder al inicio de un servicio ya llega tarde. |

`runcmd` se ejecuta en la etapa **Final**, mucho después de que la etapa Network levantara las interfaces y la etapa Config configurara los repositorios — así que DNS, rutas y repos de paquetes están todos disponibles. `bootcmd` se ejecuta muy temprano en la etapa **Network** (y en *cada* arranque, no una sola vez), antes de los montajes y, en algunos datasources, antes de que la red esté garantizadamente usable; existe para cosas como arreglos de tabla de particiones y one-shots protegidos por `cloud-init-per`, no para llamadas de red.

**Q21.** `cloud-init` compara el `instance-id` que lee del datasource en este arranque contra el registrado en el directorio de estado al que apunta `/var/lib/cloud/instance`.
- **Mismo `instance-id`** → el destino del symlink ya existe y su directorio `sem/` ya contiene semáforos `config_<module>.once` → todo módulo con la frecuencia por defecto `per-instance` se saltea. Esto es lo que hace que un reinicio normal sea barato e idempotente.
- **`instance-id` distinto** (lanzamiento nuevo, o cambiaste `meta-data`) → no existe tal directorio, así que `cloud-init` crea `instances/<new-id>/`, reapunta el symlink, y encuentra un `sem/` vacío → todos los módulos `per-instance` vuelven a ejecutarse.

De ahí las dos formas de forzar un reaprovisionamiento: cambiar el `instance-id` en `meta-data`, o borrar el estado con `cloud-init clean`. Los módulos `per-always`/`per-boot` ignoran `sem/` por completo; los módulos `per-once` registran en `/var/lib/cloud/sem/` (fuera del directorio de instancia) y por lo tanto sobreviven a un cambio de instance-id.

**Q22.** `cloud-init` acepta varios formatos de user-data por el *mismo* canal — YAML cloud-config, scripts de shell con `#!`, listas de URLs `#include`, `#cloud-boothook`, cargas comprimidas con gzip, y MIME multiparte. Los distingue olfateando la **primera línea** (o el `Content-Type` MIME para multiparte), exactamente como el kernel despacha según un shebang. `#cloud-config` es ese marcador mágico, y debe ser la primera línea literal — sin línea en blanco delante, sin BOM, sin comentario encima.

Si el archivo empieza con `---`, `cloud-init` no encuentra ningún marcador reconocido. Clasifica la carga como `text/x-not-multipart` y **la ignora silenciosamente**: el arranque tiene éxito, `cloud-init status` informa `done`, y nada de tu configuración se aplica. `/var/log/cloud-init.log` registra algo como `Unhandled non-multipart (text/x-not-multipart) userdata`. Esta es la causa más común de "mi user-data no hizo nada" — y la razón por la que el `cloud-init schema --config-file` del paso 7 vale los diez segundos que toma.

**Q23.** Ambos son el datasource `NoCloud`; difieren en de dónde proviene el seed y, en consecuencia, en qué etapa pueden completarse:
- **`NoCloud`** lee el seed de **medios locales**: un sistema de archivos etiquetado `CIDATA`/`cidata` (la ISO del paso 8, o una partición en un pendrive vFAT), o el directorio local `/var/lib/cloud/seed/nocloud/`. Se resuelve enteramente en la etapa **Local**, antes de la red — que es por lo que puede suministrar la propia configuración de red.
- **`NoCloudNet`** (`nocloud-net`) obtiene `user-data`/`meta-data` por **HTTP(S)** desde una URL que vos suministrás, así que necesariamente requiere la red arriba primero y se completa en la etapa **Network**. Su directorio de seed local es `/var/lib/cloud/seed/nocloud-net/`.

La línea de comandos del kernel lo selecciona con el parámetro `ds=`:

```
ds=nocloud-net;s=http://10.0.0.5/seed/
ds=nocloud;s=/dev/sr0          # local variant, for comparison
```

(La clave `seedfrom` en `meta-data`, y `-smbios type=1,serial=ds=nocloud-net;s=http://…` en la línea de comandos de QEMU, son rutas de inyección equivalentes.)

**Q24.** En RHEL/CentOS/Fedora no existe un grupo `sudo` — el grupo administrativo es `wheel`, habilitado a través de la regla `%wheel` de `/etc/sudoers`. `cc_users_groups` intenta agregar el usuario a un grupo que no existe: el usuario **se crea** pero la asignación de grupo falla, así que `sre` existe, puede iniciar sesión con su clave SSH, y **no tiene acceso sudo en absoluto**. El fallo queda registrado en `/var/log/cloud-init.log` y no aborta el arranque, así que `cloud-init status` sigue informando `done` — una instancia silenciosamente aprovisionada a medias.

Formas portables, en robustez creciente:
1. Apoyarte en la abstracción incorporada y otorgar sudo explícitamente, dejando que el grupo por defecto de la distro venga del `default_user` de `/etc/cloud/cloud.cfg`:
   ```yaml
   users:
     - default
     - name: sre
       sudo: "ALL=(ALL) NOPASSWD:ALL"
       ssh_authorized_keys: [ "ssh-ed25519 AAAA… sre@bastion" ]
   ```
   La clave `sudo:` escribe `/etc/sudoers.d/90-cloud-init-users` directamente y no depende de que exista ningún grupo.
2. Crear el grupo primero, de modo que la pertenencia esté garantizada:
   ```yaml
   groups: [ sre-admins ]
   users:
     - name: sre
       primary_group: sre
       groups: [ sre-admins ]
       sudo: "ALL=(ALL) NOPASSWD:ALL"
   ```
3. Mantener un user-data por familia de distro, o plantillarlo — pero nunca fijar a mano `sudo`/`wheel` en una imagen que se declara portable.

**Q25.** `cloud-init clean` elimina `/var/lib/cloud` — el directorio de estado de la instancia, los semáforos, y el **datasource cacheado** — de modo que el próximo arranque re-detecta su datasource y re-ejecuta cada módulo. `--logs` elimina adicionalmente `/var/log/cloud-init.log` y `/var/log/cloud-init-output.log`. `--seed` elimina adicionalmente `/var/lib/cloud/seed`, es decir, **los propios datos de seed inyectados localmente** (directorios `nocloud`/`nocloud-net`).

Omitir `--seed` suele ser correcto en una instancia de nube real porque no hay seed local que eliminar: el user-data vive en el servicio de metadatos de la plataforma, y `cloud-init` volverá a obtenerlo en el próximo arranque. Eliminar `/var/lib/cloud/seed` allí es, en el mejor de los casos, una operación sin efecto. Incluí `--seed` cuando estés **construyendo una plantilla a partir de una VM de laboratorio sembrada** — de lo contrario tu imagen dorada lleva el user-data de la instancia anterior (incluidas sus claves SSH autorizadas y cualquier credencial que hayas escrito allí) y cada clon futuro lo reaplica silenciosamente. Por la misma razón, `--machine-id` (en versiones más nuevas) es un flag de construcción de plantillas, no de operación.

**Q26.** En orden, del más barato al más caro:
1. **¿Está el módulo *listado*, en la lista correcta, y escrito con su nombre de módulo?** `grep -n cc_yourmodule /etc/cloud/cloud.cfg /etc/cloud/cloud.cfg.d/*.cfg`. Un drop-in en `/etc/cloud/cloud.cfg.d/` que redefine `cloud_final_modules` **reemplaza** la lista en lugar de agregarse a ella — la causa más común. Confirmá la configuración efectiva ya fusionada con `cloud-init query --all` y leyendo las líneas de ejecución `config-…` del log, en lugar de confiar en el archivo que editaste.
2. **¿Ya existía su semáforo?** `ls /var/lib/cloud/instance/sem/ | grep yourmodule`. Un módulo `per-instance` que se ejecutó en un arranque anterior del *mismo* instance-id se saltea por diseño y no reporta nada. Forzálo con `cloud-init single --name cc_yourmodule --frequency always`, o poné `frequency: always` en la entrada de lista del módulo (`[cc_yourmodule, always]`).
3. **¿Se ejecutó la etapa en absoluto, y el módulo lanzó una excepción?** `grep -iE 'cc_yourmodule|Traceback|WARNING|ERROR' /var/log/cloud-init.log` y `cloud-init analyze show | grep -A2 yourmodule`. Notá que `cloud-init status` informando `done` dice que las *etapas* se completaron — las excepciones de módulos individuales se registran como advertencias y **no** cambian el estado de nivel superior a menos que sean fatales. `cloud-init status --long` expone los errores registrados en versiones más nuevas; `/var/log/cloud-init-output.log` contiene el stdout/stderr del propio módulo.

Si las tres pasan y el módulo sigue sin hacer nada, verificá que el user-data haya llegado realmente a la instancia (`cat /var/lib/cloud/instance/user-data.txt`) y que su primera línea sea `#cloud-config` — ver Q22.

### Ejercicio 5

**Q27.** Demuestra que **el contenedor comparte el kernel del host** — hay exactamente un kernel, y el contenedor es un conjunto de procesos con namespaces y limitados por cgroups corriendo sobre él, no una máquina separada. Una VM arranca su propio kernel, así que `uname -r` dentro de ella es independiente del del host.

Dos consecuencias, es decir, cosas que un contenedor no puede hacer:
1. **Correr un kernel distinto, o una versión de kernel/familia de SO distinta.** No podés correr un contenedor de Windows sobre un kernel Linux, no podés correr una carga de kernel 6.6 sobre un host 4.18, y no podés usar una característica de kernel (un controlador de cgroup, un opcode de `io_uring`, un tipo de programa eBPF, un sistema de archivos) que le falte al kernel del host — la ilusión de "el userspace es CentOS 7" no se extiende a la ABI del kernel.
2. **Cargar módulos de kernel, o modificar estado global del kernel, de forma independiente.** `insmod`/`modprobe` afecta al *host*; los `sysctl` no aislados por namespace (`vm.*`, la mayoría de `kernel.*`) son globales; `/dev/mem`, `kexec`, el reloj del sistema (`CLOCK_REALTIME` no tiene namespace) y el búfer de log del kernel son de alcance host. De ahí la cláusula de guarda del Ejercicio 1: saltear el tuning de kernel y NTP dentro de contenedores, porque intentarlos o bien falla o bien afecta silenciosamente a todos los demás inquilinos del host.

El corolario es el de seguridad: una vulnerabilidad de kernel es un escape de contenedor pero no, por sí sola, un escape de VM — el límite de la VM lo impone la virtualización por hardware más el hipervisor, una superficie de ataque mucho menor y de forma distinta a la interfaz de llamadas al sistema de Linux, con sus ~400 syscalls.

**Q28.** La disposición es **aislamiento anidado** — coloquialmente "contenedores sobre VMs", la topología estándar de todo servicio de Kubernetes gestionado (pods dentro de contenedores, dentro de nodos worker que son VMs de nube, dentro de la flota física del proveedor).

Un script sobre `vm.swappiness` debe confiar en la respuesta de **contenedor**. `vm.swappiness` es un ajuste de kernel **sin namespace**: escribirlo dentro del contenedor o bien falla con `EPERM` (`/proc/sys` de solo lectura en un contenedor normal) o bien, en un contenedor `--privileged`, tiene éxito y lo cambia **para el kernel del host y para todos los demás contenedores de ese nodo** — un efecto colateral entre inquilinos. El comportamiento correcto es exactamente el orden de ramas del paso 4 del Ejercicio 1: probar `--container` primero y salir, y llegar a la rama de VM solo cuando PID 1 sea el del kernel.

La regla general: el límite **más interno** determina lo que podés hacer, así que la lógica de detección debe comprobar primero el más interno.

**Q29.**
- **Los namespaces resuelven *visibilidad / nombrado*.** Particionan los espacios de identificadores globales del kernel de modo que un proceso vea solo su porción: PID, mount, network, UTS (hostname/domainname), IPC, user (mapeo de UID/GID), cgroup, y time namespaces. Un proceso con namespace no puede *ver* ni *nombrar* recursos fuera de su namespace — no puede señalizar un PID que no puede ver, no puede acceder a un montaje que no tiene, no puede alcanzar una interfaz de red en otro netns.
- **Los cgroups resuelven *cantidad / contabilidad*.** Acotan y contabilizan cuánto de un recurso compartido puede consumir un conjunto de procesos: memoria, tiempo y peso de CPU, ancho de banda e IOPS de E/S de bloque, PIDs y dispositivos. Un cgroup no oculta nada — limita y estrangula.

`--memory=512m` manipula un **cgroup** — específicamente `memory.max` (cgroup v2) o `memory.limit_in_bytes` (v1) en el cgroup del contenedor, como muestra el `systemd-run -p MemoryMax=64M` del paso 6.

El par es el punto: namespaces sin cgroups te da una vista aislada sin protección de recursos (un contenedor puede dejar sin memoria al nodo); cgroups sin namespaces te da equidad de recursos con visibilidad mutua completa. Un contenedor es la conjunción, más el descarte de capacidades, seccomp y política de LSM.

**Q30.** `CapEff: 000001ffffffffff` es genuino — dentro de un **user namespace** poseés el conjunto completo de capacidades, pero esas capacidades están **acotadas a ese namespace**. Una capacidad solo tiene sentido frente a un recurso en cuyo user namespace propietario tengas *esa* capacidad.

`/etc` está en un sistema de archivos montado en — y propiedad de — el user namespace **inicial**, y su inodo pertenece al UID 0 *real, del host*. Tu "root" es el UID 1000 del host mapeado a 0 adentro (`/proc/self/uid_map` muestra `0 1000 1`). Cuando el kernel comprueba el permiso para escribir en `/etc`, pregunta: ¿tiene este proceso `CAP_DAC_OVERRIDE` *en el user namespace que posee el superbloque de este sistema de archivos*? No lo tiene — sus capacidades existen solo en el namespace hijo — así que la comprobación cae de vuelta al DAC ordinario contra la identidad mapeada, y `touch /etc/proof-of-root` devuelve `EPERM`.

Dentro de recursos propiedad del namespace las capacidades son reales: *podés* fijar el hostname (el UTS namespace es propiedad de tu user namespace), montar un `tmpfs`, crear interfaces de red en un netns nuevo, y hacer chown de archivos cuya propiedad caiga dentro de tu mapa de IDs. Este es precisamente el mecanismo que hace a los **contenedores rootless** (`podman` como usuario no root) seguros y útiles — y es por eso que `CapEff` por sí solo nunca es respuesta suficiente a "¿soy privilegiado?"; la pregunta siempre es "privilegiado *respecto de qué namespace*?".

**Q31.**
- **Contenedor de aplicación:** un contenedor cuya carga es un **único árbol de procesos de aplicación sin sistema de init**, empaquetado con apenas sus dependencias de ejecución en una imagen OCI por capas, diseñado para ser inmutable, descartable y replicado horizontalmente — PID 1 es la propia aplicación (nginx, una JVM, un binario Go), el ciclo de vida es `ejecutar hasta salir`, y los logs van a stdout/stderr. Este es el modelo de Docker/Podman/Kubernetes.
- **Contenedor de sistema:** un contenedor que arranca un **sistema de init completo (`systemd`, `openrc`) y un userland completo**, comportándose como una máquina liviana y de larga vida en la que podés iniciar sesión, correr múltiples servicios y administrar con herramientas de sistema normales — LXC/LXD, `systemd-nspawn`, OpenVZ. `machinectl list` en el paso 7 existe precisamente porque estas son "máquinas" para el host.

**La pregunta decisiva entre un contenedor de sistema y una VM:** *¿esta carga de trabajo requiere un kernel propio?* Concretamente — ¿necesita una versión de kernel distinta o un SO no Linux; carga módulos de kernel o usa características del kernel sin namespace; necesita un límite de seguridad duro frente a un inquilino hostil (donde una LPE de kernel no debe convertirse en un escape); necesita tuning de kernel independiente, su propia disciplina de reloj, migración en vivo, o passthrough de hardware? Si la respuesta es **sí** a alguna, necesita una VM. Si es **no** — querés la densidad, el tiempo de arranque ~0 y la page cache compartida — un contenedor de sistema es la respuesta correcta más barata. (El punto medio también existe: Kata Containers, microVMs Firecracker y gVisor dan una interfaz compatible con OCI sobre un kernel por carga de trabajo, comprando el límite de VM con la ergonomía de un contenedor.)

### Ejercicio 6

**Q32.** IMDSv2 derrota el **SSRF (Server-Side Request Forgery)** y, por extensión, las variantes de proxy-reflejado/open-redirect del mismo.

Bajo IMDSv1 el servicio de metadatos respondía a un simple `GET http://169.254.169.254/…` sin autenticación. Cualquier aplicación en la instancia a la que se pudiera inducir a buscar una URL suministrada por el atacante — un webhook, un generador de miniaturas, un renderizador de PDF, un proxy inverso mal configurado, una función de vista previa de URL — traería el endpoint de metadatos en nombre del atacante y devolvería el cuerpo, incluidas las **credenciales del rol IAM** de la instancia en `/latest/meta-data/iam/security-credentials/<role>`. Esa forma de un solo GET es lo que lo hacía explotable, y es el mecanismo detrás de varias grandes brechas en la nube.

IMDSv2 lo rompe con dos cambios:
1. **Se requiere un `PUT`** para obtener el token de sesión, y el token debe luego reenviarse en una cabecera `X-aws-ec2-metadata-token`. Casi todo primitivo de SSRF solo puede emitir un `GET` (y en general no puede fijar cabeceras arbitrarias), así que el atacante ni siquiera puede adquirir un token.
2. **La respuesta del token lleva TTL de IP = 1** (y el servicio rechaza peticiones que traen `X-Forwarded-For`). Un paquete con TTL 1 no puede cruzar un router — así que si un *proxy o NAT de contenedor* reenvía la petición hacia afuera, la respuesta muere en tránsito. Esto mata específicamente las variantes "proxy inverso en la instancia que retransmite al servicio de metadatos" y "escape de contenedor vía el enrutamiento del host".

Operativamente: forzá `HttpTokens=required` en cada instancia (`aws ec2 modify-instance-metadata-options`), y fijá `HttpPutResponseHopLimit=1` en hosts donde los contenedores no necesiten alcanzar el IMDS — o `2` cuando sí lo necesiten, deliberadamente.

**Q33.** `169.254.0.0/16` es el rango IPv4 **link-local** (RFC 3927). Por definición, los paquetes hacia un destino link-local nunca son reenviados por un router — solo son válidos en el segmento L2 directamente adjunto. El servicio de metadatos lo usa por tres razones: necesita una **dirección fija y bien conocida utilizable antes de que la instancia sepa nada sobre su propia red**; debe ser idéntica en cada VPC, subred e inquilino sin colisionar con el espacio de direcciones de ningún cliente (cualquier elección RFC 1918 colisionaría con alguien); y su no enrutabilidad es en sí misma la propiedad de seguridad — el endpoint es intrínsecamente inalcanzable desde fuera del host, y el "servidor" es de hecho el hipervisor o el switch virtual local interceptando el paquete, no un host real en el cable.

Implicaciones para un invitado que corre su propio NAT u overlay:
- **A los contenedores y VMs anidadas hay que darles una ruta explícita.** Un contenedor en su propio netns detrás de un bridge/NAT no tiene ruta link-local hacia `169.254.169.254`; o bien se la proveés deliberadamente (el bridge por defecto de Docker sí la reenvía — que es exactamente la exposición que el hop limit de IMDSv2 aborda) o la bloqueás. El valor de seguridad por defecto debería ser **bloquear el acceso de contenedores al IMDS** (`iptables -I FORWARD -d 169.254.169.254 -j DROP`, o una política de red de CNI) e inyectar credenciales correctamente en su lugar — IRSA/Workload Identity, o un proxy de credenciales que imponga identidad por pod.
- **No hagas SNAT ni proxy sobre él.** Tráfico hacia una dirección link-local que atraviesa un NAT o un proxy inverso en el host es precisamente el patrón de retransmisión de SSRF de la Q32, y el hop limit de IMDSv2 lo descartará de todos modos.
- **No asumas que la ruta existe.** En instancias multi-homed o con tablas de enrutamiento personalizadas, verificá con `ip route get 169.254.169.254`; si falta, la búsqueda del datasource falla y `cloud-init` cae a `DataSourceNone` con un timeout largo.

**Q34.** Sin `nofail`, el montaje se trata como **requerido para el arranque**. Si el volumen está desconectado (deliberadamente, o porque la plataforma no logró reconectarlo, o porque se movió a otra instancia), la unit `srv-data.mount` generada por `systemd` tiene un `Requires=` sobre una unit de dispositivo que nunca aparece; la unit falla tras el timeout del dispositivo, `local-fs.target` falla, y el sistema **cae a modo de emergencia exigiendo la contraseña de root en la consola** — en una instancia de nube headless sin contraseña de consola configurada, eso es una máquina imposible de arrancar, alcanzable solo conectando el disco raíz a una instancia de rescate. Esta es la caída autoinfligida más común en la nube a partir de `/etc/fstab`.

`nofail` marca el montaje como no esencial: `local-fs.target` deja de depender de él, el arranque continúa, y el sistema de archivos se monta si y cuando el dispositivo aparezca. `x-systemd.device-timeout=10s` acota la espera adicional (el valor por defecto es 90 s por dispositivo, que de otro modo agrega 90 s a cada arranque cuando el volumen está ausente). Para un volumen que legítimamente llega tarde, agregá `x-systemd.automount` para que el montaje se dispare en el primer acceso en lugar de en el arranque. La regla corolaria: **solo el sistema de archivos raíz y, discutiblemente, `/var` pertenecen a `fstab` sin `nofail` en una instancia de nube.**

**Q35.**
- **Volumen de almacenamiento en bloque** (EBS, Cinder, Persistent Disk, Azure Managed Disk): un dispositivo de bloques virtual **conectado por red y con ciclo de vida independiente**. Sobrevive al stop/start de la instancia y a su terminación (sujeto a `DeleteOnTermination`), puede desconectarse y reconectarse a otra instancia, puede fotografiarse en snapshots y restaurarse, típicamente está replicado por durabilidad, y su rendimiento está provisionado (niveles de IOPS/throughput) y acotado por la ruta de red. La latencia es más alta y más variable que la de un medio local.
- **Instance store / disco efímero**: NVMe/SSD **físicamente local** conectado al host donde corre la instancia. Ofrece la latencia más baja y el mayor throughput crudo disponible, no cuesta nada extra, y se **destruye** cuando la instancia se detiene, hiberna, termina, o es migrada en vivo/recuperada sobre hardware distinto. No hay snapshot, no hay reconexión y — importante — un *stop/start*, no solo una terminación, lo pierde.

Ubicación de cargas:
- **Volumen de bloque:** un **directorio de datos de PostgreSQL/MySQL** — cualquier cosa donde la durabilidad a través del ciclo de vida de la instancia, los snapshots a punto en el tiempo, y la capacidad de reconectar a una instancia de reemplazo sean los requisitos.
- **Instance store:** un **directorio de datos de Kafka/Elasticsearch/Cassandra en un clúster replicado**, una caché de build o espacio de scratch de CI, `/tmp`, el área temporal/de derrame de una base de datos, o un nivel de caché (Varnish, Redis con réplicas) — cargas que ya replican en la capa de aplicación y valoran la latencia por encima de la durabilidad por nodo. También correcto para `swap`.

**Q36.** El paso salteado es el **(2), hacer crecer la partición** — `growpart /dev/vda 1` más `partx -u`. El disco se agrandó, pero la partición 1 sigue terminando donde terminaba, así que el sistema de archivos ya está al tamaño de su contenedor y `xfs_growfs` legítimamente informa que no hay nada que hacer (`data blocks changed from X to X`, o simplemente ningún cambio).

Confirmándolo solo con `lsblk`: el **`SIZE` de la fila del disco excede la suma de las filas de sus particiones**, dejando espacio sin asignar al final.

```
NAME   SIZE TYPE MOUNTPOINTS
vda     40G disk          <-- the device grew
└─vda1  20G part /        <-- the partition did not
```

Tras `growpart /dev/vda 1; partx -u /dev/vda` la fila de la partición lee `40G` mientras que `df` sigue mostrando 20 G — ese es el estado en el que `xfs_growfs /` (o `resize2fs /dev/vda1`) por fin tiene sentido.

Dos trampas relacionadas que vale la pena conocer: en un disco GPT la **cabecera de respaldo está al final viejo del dispositivo** y debe reubicarse (`growpart` y `sgdisk -e` hacen esto; una tabla de particiones editada a mano hará que el kernel se queje de una GPT corrupta), y si la partición no es la última del disco no hay espacio libre adyacente en absoluto — debés agregar una partición nueva y extender vía LVM. Notá también la asimetría: **XFS crece en línea y nunca se encoge**; ext4 crece en línea y se encoge solo cuando está desmontado.

**Q37.** `52:54:00` es el OUI **que QEMU/KVM asigna por defecto a las NICs virtio (y emuladas)** — libvirt genera direcciones en `52:54:00:xx:xx:xx` con los últimos tres octetos aleatorios. Verlo te dice de inmediato: esto es un invitado QEMU/KVM, y la dirección es **administrada localmente y asignada por el hipervisor**, no grabada en hardware. (Compará `00:50:56` / `00:0c:29` para VMware, `08:00:27` para VirtualBox, `00:15:5d` para Hyper-V, `02:…` para ENIs de AWS — el OUI es una huella rápida de plataforma por derecho propio, complementaria al Ejercicio 1.)

Una plantilla que fija la MAC en un perfil de NetworkManager falla en el primer clon porque **el hipervisor asigna a cada clon una MAC nueva y aleatoria** (debe hacerlo — dos invitados con la misma MAC en un segmento L2 rompen la conmutación directamente). El `[ethernet] mac-address=52:54:00:9a:3f:12` del perfil es una **condición de coincidencia**: NetworkManager activa esa conexión solo en una interfaz cuya dirección permanente sea igual. En el clon ninguna interfaz coincide, el perfil nunca se activa, y la instancia arranca **sin dirección IP y sin ruta por defecto** — inalcanzable, con la consola del hipervisor como única vía de diagnóstico. La misma trampa existe en archivos `ifcfg-*` con `HWADDR=`, en `/etc/udev/rules.d/70-persistent-net.rules`, y en un archivo `.link` cuyo `[Match] MACAddress=` ya no coincide.

Las formas seguras para plantillas:
- Quitá `mac-address` del perfil por completo y hacé coincidir por el **nombre de interfaz** o por nada en absoluto (`connection.multi-connect`, o un `[match] interface-name=en*` que abarque todo).
- Eliminá `/etc/udev/rules.d/70-persistent-net.rules` — `virt-sysprep --enable udev-persistent-net` hace exactamente esto.
- Si querés un *nombre estable* a través de cambios de hardware, fijalo por nombre a partir de una propiedad que sobreviva a la clonación (la ruta PCI) en lugar de por MAC, o deshabilitá los nombres predecibles por completo con `net.ifnames=0 biosdevname=0` y aceptá `eth0`.
- Dejá que `cloud-init` escriba la configuración de red en el primer arranque a partir del datasource, que es consciente de la MAC *en tiempo de ejecución* y por lo tanto siempre correcta — y deshabilitalo (`network: {config: disabled}`) solo cuando hayas asumido esa responsabilidad deliberadamente.

Notá la tensión con el paso 11 del ejercicio: fijar `Name=uplink0` por `MACAddress=` es la respuesta correcta para una **VM de larga vida, administrada individualmente**, cuya topología PCI puede cambiar, y la respuesta *equivocada* para una **plantilla**. Sabé qué artefacto estás construyendo.

</details>

---

## Fuentes

- LPI — LPIC-1 Exam 102-500 Objectives, v5.0, objetivo 102.6: <https://www.lpi.org/our-certifications/exam-102-objectives/>
- LPI — LPIC-1 Exam 101-500 Objectives, v5.0: <https://www.lpi.org/our-certifications/exam-101-objectives/>
- `systemd` — `machine-id(5)`: <https://www.freedesktop.org/software/systemd/man/latest/machine-id.html>
- `systemd` — `systemd-machine-id-setup(1)`: <https://www.freedesktop.org/software/systemd/man/latest/systemd-machine-id-setup.html>
- `systemd` — `systemd-detect-virt(1)`: <https://www.freedesktop.org/software/systemd/man/latest/systemd-detect-virt.html>
- `systemd` — `systemd.link(5)` y `systemd.network(5)` (`ClientIdentifier=`, `DUIDType=`): <https://www.freedesktop.org/software/systemd/man/latest/systemd.network.html>
- `systemd` — `systemd-nspawn(1)` y `machinectl(1)`: <https://www.freedesktop.org/software/systemd/man/latest/systemd-nspawn.html>
- Documentación de cloud-init (Canonical) — datasources, etapas de arranque, módulos, `NoCloud`: <https://docs.cloud-init.io/en/latest/>
- cloud-init — referencia de módulos (`cc_ssh`, `cc_growpart`, `cc_users_groups`, `cc_runcmd`): <https://docs.cloud-init.io/en/latest/reference/modules.html>
- libvirt — Formato del XML de dominio (memballoon, dispositivos virtio, `sysinfo`): <https://libvirt.org/formatdomain.html>
- libvirt — `virt-sysprep(1)`, herramientas guestfs: <https://libguestfs.org/virt-sysprep.1.html>
- QEMU — Referencia del protocolo del Guest Agent: <https://www.qemu.org/docs/master/interop/qemu-ga.html>
- OASIS — Virtual I/O Device (VIRTIO) Specification v1.2: <https://docs.oasis-open.org/virtio/virtio/v1.2/virtio-v1.2.html>
- Documentación del kernel de Linux — panorama de namespaces (`namespaces(7)`), `user_namespaces(7)`, `capabilities(7)`: <https://man7.org/linux/man-pages/man7/namespaces.7.html>
- Documentación del kernel de Linux — Control Group v2: <https://docs.kernel.org/admin-guide/cgroup-v2.html>
- Documentación del kernel de Linux — drivers de invitado de Hyper-V: <https://docs.kernel.org/virt/hyperv/overview.html>
- `open-vm-tools` (VMware/Broadcom, código abierto): <https://github.com/vmware/open-vm-tools>
- Documentación de `dracut` (modo host-only, `--add-drivers`): <https://man7.org/linux/man-pages/man8/dracut.8.html>
- IETF RFC 3927 — Dynamic Configuration of IPv4 Link-Local Addresses: <https://www.rfc-editor.org/rfc/rfc3927>
- IETF RFC 4361 — Node-specific Client Identifiers for DHCPv4: <https://www.rfc-editor.org/rfc/rfc4361>
- AWS — Instance Metadata Service Version 2 (IMDSv2): <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html>
- OpenStack — Servicio de metadatos: <https://docs.openstack.org/nova/latest/admin/metadata-service.html>