# Examen LPIC-3 305-300 (v3.0) — Tema 1.3: VM Deployment and Provisioning

**Peso:** 33.34% (Sub-peso del Tema 1)  
**Audiencia Objetivo:** SREs Senior, Ingenieros de Infraestructura Cloud, Arquitectos de Sistemas  

---

## 1. Architectural Overview & Internal Mechanics

El despliegue y aprovisionamiento de VMs en entornos empresariales modernos se basa en la gestión desacoplada de imágenes, la inyección de metadatos, los orquestadores de hipervisores y la gestión declarativa de la configuración.

```
+-----------------------------------------------------------------------------------+
|                                 BUILD PHASE                                       |
|  +-------------------+      +------------------+      +------------------------+  |
|  | Base OS ISO/Img   | ---> | Packer / QEMU    | ---> | virt-sysprep           |  |
|  +-------------------+      +------------------+      +------------------------+  |
|                                                                   |               |
|                                                          Golden QCOW2 Image       |
+-------------------------------------------------------------------|---------------+
                                                                    v
+-----------------------------------------------------------------------------------+
|                              PROVISIONING PHASE                                   |
|  +-------------------+      +------------------+      +------------------------+  |
|  | cloud-config      | ---> | cloud-localds    | ---> | seed.iso (NoCloud)     |  |
|  | (user/vendor-data)|      +------------------+      +------------------------+  |
|  +-------------------+                                            |               |
+-------------------------------------------------------------------|---------------+
                                                                    v
+-----------------------------------------------------------------------------------+
|                                RUNTIME PHASE                                      |
|  +-----------------------------------------------------------------------------+  |
|  | virt-install --disk golden.qcow2 --disk seed.iso,device=cdrom               |  |
|  +-----------------------------------------------------------------------------+  |
|                                       |                                           |
|                                       v                                           |
|  +-----------------------------------------------------------------------------+  |
|  | Target VM Boot (libvirt / QEMU-KVM)                                         |  |
|  |  1. Kernel boots, cloud-init stage 'generator' identifies NoCloud ISO         |  |
|  |  2. Stage 'local' mounts ISO, parses meta-data & user-data                    |  |
|  |  3. Stage 'network' applies networking configuration                        |  |
|  |  4. Stage 'config' runs modules (users, ssh-keys, write_files)               |  |
|  |  5. Stage 'final' executes runcmd scripts & package installations           |  |
|  +-----------------------------------------------------------------------------+  |
+-----------------------------------------------------------------------------------+
```

### 1.1 `libguestfs` Mechanics
Las herramientas de `libguestfs` (`virt-builder`, `virt-customize`, `virt-sysprep`, `guestfish`) no operan directamente a través de llamadas a sistemas de archivos estándar abiertos sobre archivos montados en el host. En su lugar, `libguestfs` inicia un *appliance* temporal y mínimo de QEMU/KVM (un pequeño kernel Linux e initrd ejecutándose dentro de un proceso QEMU dedicado en segundo plano). Este appliance adjunta la imagen de disco del guest de destino en formato raw o QCOW2, lo que evita riesgos de kernel panic en el host o corrupción del sistema de archivos asociados con montar en bucle (loop-mount) los sistemas de archivos del guest directamente en el host del hipervisor.

### 1.2 `cloud-init` Data Source Mechanics
`cloud-init` se activa durante el proceso de arranque del guest a lo largo de cuatro targets/etapas distintas de systemd:
1. **`cloud-init-local.service`**: Detecta las fuentes de datos (datasources) disponibles (por ejemplo, NoCloud ISO, ConfigDrive, OpenStack Metadata API en `169.254.169.254`). Lee los metadatos de red y aplica la configuración de red temprana antes de levantar las interfaces de red.
2. **`cloud-init.service`**: Obtiene `user-data` y `vendor-data`. Procesa hostnames, claves SSH autorizadas y puntos de montaje.
3. **`cloud-config.service`**: Ejecuta módulos de configuración tales como `write_files`, creación de usuarios y actualizaciones de paquetes.
4. **`cloud-final.service`**: Ejecuta scripts de etapa tardía especificados en `runcmd`, Ansible pulls o comandos de inicialización personalizados.

---

## 2. Guided Hands-On Exercises

---

### Exercise 1: Image Building and Sysprepping with `libguestfs` Tools

#### Objective
Comprender cómo construir imágenes de disco base de VM dinámicamente, inyectar paquetes sin arrancar el guest y sanitizar plantillas maestras para clonación en producción utilizando `virt-builder`, `virt-customize`, `virt-sysprep` y `guestfish`.

#### Step 1: Build a clean base image using `virt-builder`
Ejecutá `virt-builder` para generar una imagen de disco QCOW2 de Ubuntu 22.04, configurando la contraseña de root e incrustando una clave pública SSH del administrador SRE directamente en el sistema de archivos offline.

```bash
virt-builder ubuntu-22.04 \
  --format qcow2 \
  --output /var/lib/libvirt/images/ubuntu-golden-base.qcow2 \
  --size 20G \
  --root-password password:ArchEnterprise2026! \
  --ssh-inject root:file:$HOME/.ssh/id_rsa.pub \
  --hostname golden-tpl-01
```

**Expected Output:**
```text
[   1.2] Downloading: http://builder.libguestfs.org/ubuntu-22.04.xz
[   4.5] Planning how to build image
[   4.5] Extracting template
[  12.1] Formatting /dev/sda1 as ext4
[  14.3] Setting root password
[  15.0] Injecting SSH key for root
[  15.2] Setting hostname: golden-tpl-01
[  16.1] Finishing off
Output file: /var/lib/libvirt/images/ubuntu-golden-base.qcow2
```

#### Step 2: Inject system configurations using `virt-customize`
Personalizá la imagen de disco offline instalando paquetes de monitoreo obligatorios, habilitando el `qemu-guest-agent` y configurando los parámetros de zona horaria.

```bash
virt-customize -a /var/lib/libvirt/images/ubuntu-golden-base.qcow2 \
  --install qemu-guest-agent,curl,htop,net-tools \
  --timezone "UTC" \
  --run-command 'systemctl enable qemu-guest-agent'
```

**Expected Output:**
```text
[   0.0] Starting virt-customize
[   1.5] Examining the guest ...
[   6.2] Running apt-get update
[  18.4] Installing packages: qemu-guest-agent curl htop net-tools
[  24.1] Setting timezone to UTC
[  24.3] Running command: systemctl enable qemu-guest-agent
[  25.0] Finishing off
```

#### Step 3: Sanitize the template using `virt-sysprep` and inspect via `guestfish`
Prepará la imagen para la clonación de plantillas de producción eliminando direcciones MAC persistentes, machine-ids, artefactos de cloud-init y claves de host SSH. Posteriormente, usá `guestfish` para inspeccionar `/etc/machine-id`.

```bash
virt-sysprep -a /var/lib/libvirt/images/ubuntu-golden-base.qcow2 \
  --enable machine-id,ssh-hostkeys,udev-persistent-net,logfiles,cloud-init

guestfish --ro -a /var/lib/libvirt/images/ubuntu-golden-base.qcow2 -m /dev/sda1 cat /etc/machine-id
```

**Expected Output:**
```text
[   0.0] Examining the guest ...
[   2.1] Performing operations: machine-id * ssh-hostkeys * udev-persistent-net * logfiles * cloud-init *
[   2.1] Clearing /etc/machine-id ...
[   2.2] Removing SSH host keys ...
[   2.4] Purging udev persistent net rules ...
[   2.7] Removing log files ...
[   3.0] Resetting cloud-init state ...
```
*(La salida de `guestfish` mostrará una cadena vacía o una nueva línea, confirmando que `/etc/machine-id` ha sido reiniciado).*

---

#### Concept Verification Questions — Exercise 1

1. **¿Por qué es crítico purgar `/etc/machine-id` y las claves de host SSH usando `virt-sysprep` antes de desplegar múltiples VMs clonadas a partir de una imagen QCOW2 maestra?**
2. **¿Qué ocurre internamente si ejecutás `virt-customize` o `guestfish` en una imagen QCOW2 que actualmente está adjunta a una máquina virtual libvirt KVM activa y en ejecución?**

---

### Exercise 2: Declarative Provisioning with `cloud-init` and `cloud-localds`

#### Objective
Dominar el aprovisionamiento local de imágenes con cloud-init creando manifiestos estándar de `user-data` y `meta-data`, compilando una unidad seed NoCloud ISO, aprovisionando a través de `virt-install` y solucionando problemas en los logs de despliegue.

#### Step 1: Draft the syntactically valid `#cloud-config` manifest
Creá un archivo llamado `user-data.yaml`. Este manifiesto aprovisiona un usuario `sre-admin`, configura privilegios de sudo, inyecta una clave SSH, crea un archivo de configuración y ejecuta comandos de inicialización.

```yaml
#cloud-config
version: v1
hostname: prod-node-01
fqdn: prod-node-01.infra.internal
manage_etc_hosts: true

users:
  - name: sre-admin
    gecos: SRE Engineer
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: [sudo, docker]
    shell: /bin/bash
    ssh_authorized_keys:
      - ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC5qP... sre-key@infrastructure

packages:
  - nginx
  - jq

write_files:
  - path: /etc/sysctl.d/99-kubernetes-cri.conf
    permissions: '0644'
    owner: root:root
    content: |
      net.bridge.bridge-nf-call-iptables  = 1
      net.ipv4.ip_forward                 = 1
      net.bridge.bridge-nf-call-ip6tables = 1

runcmd:
  - [ sysctl, --system ]
  - [ systemctl, enable, --now, nginx ]
  - echo "VM Provisioned Successfully on $(date)" > /var/log/provisioning.log
```

Creá un archivo `meta-data.yaml` coincidente:
```yaml
instance-id: i-prod-node-01-2026
local-hostname: prod-node-01
```

#### Step 2: Generate the NoCloud ISO seed drive using `cloud-localds`
Compilá `user-data.yaml` y `meta-data.yaml` en una imagen seed con formato VFAT/ISO9660 compatible con la fuente de datos NoCloud de `cloud-init`.

```bash
cloud-localds -v /var/lib/libvirt/images/seed-prod-node-01.iso user-data.yaml meta-data.yaml
```

**Expected Output:**
```text
cloud-localds: outputting to /var/lib/libvirt/images/seed-prod-node-01.iso
cloud-localds: user-data file: user-data.yaml
cloud-localds: meta-data file: meta-data.yaml
```

#### Step 3: Instantiate the VM using `virt-install`
Adjuntá el disco base golden creado en el Ejercicio 1 junto con la unidad `seed-prod-node-01.iso`.

```bash
virt-install \
  --name prod-node-01 \
  --ram 2048 \
  --vcpus 2 \
  --os-variant ubuntu22.04 \
  --disk path=/var/lib/libvirt/images/prod-node-01.qcow2,size=20,backing_store=/var/lib/libvirt/images/ubuntu-golden-base.qcow2 \
  --disk path=/var/lib/libvirt/images/seed-prod-node-01.iso,device=cdrom \
  --network network=default,model=virtio \
  --graphics none \
  --console pty,target_type=serial \
  --noautoconsole
```

**Expected Output:**
```text
Starting install...
Allocating 'prod-node-01.qcow2'                                      |  20 GB  00:00:01 
Creating domain...                                                   |    0 B  00:00:00 
Domain creation completed.
```

#### Step 4: Validate cloud-init runtime execution and diagnostics
Accedé a la VM o inspeccioná los logs para rastrear las etapas de ejecución, verificar el estado y analizar la latencia de los módulos.

```bash
# Connect to guest serial console
virsh console prod-node-01

# Inside the guest, run cloud-init diagnostic suite:
cloud-init status --wait --long
cloud-init analyze show
cloud-init query metadata.instance_id
```

**Expected Output:**
```text
# cloud-init status --wait --long
status: done
extended_status: done
boot_status_code: enabled
detail: finished at Thu, 06 Aug 2026 17:15:32 +0000. Datasource DataSourceNoCloud [seed=/dev/sr0][msrc=/dev/sr0]. Up 42.12 seconds

# cloud-init analyze show
-- Boot Record 01 --
stage: init-local
  start: 17:14:50.120000
  finish: 17:14:51.450000
  duration: 1.33s
stage: init
  start: 17:14:53.100000
  finish: 17:14:58.200000
  duration: 5.10s
stage: modules-config
  start: 17:15:01.000000
  finish: 17:15:15.800000
  duration: 14.80s
stage: modules-final
  start: 17:15:16.000000
  finish: 17:15:32.000000
  duration: 16.00s

# cloud-init query metadata.instance_id
i-prod-node-01-2026
```

---

#### Concept Verification Questions — Exercise 2

1. **¿Cuál es la diferencia estructural en la información de depuración que se encuentra en `/var/log/cloud-init.log` frente a `/var/log/cloud-init-output.log`?**
2. **Si `cloud-init status` reporta `status: error`, ¿qué opciones de línea de comandos le permiten a un SRE reiniciar el estado de `cloud-init` por completo y forzar la reejecución de todos los módulos de arranque sin reconstruir la VM?**

---

### Exercise 3: Automated KVM Image Pipelines with HashiCorp Packer

#### Objective
Construir imágenes de guest personalizadas para producción de forma completamente desatendida a través de HashiCorp Packer utilizando el plugin `qemu`, definiendo builders y provisioners en HCL2.

#### Step 1: Author a Packer HCL2 Template
Guardá el siguiente manifiesto como `ubuntu-kvm.pkr.hcl`.

```hcl
packer {
  required_plugins {
    qemu = {
      version = ">= 1.0.9"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

variable "iso_checksum" {
  type    = string
  default = "sha256:5e38b0a3da12ee021556980743b678a739197a102b82503cadb12778abe2bb12"
}

variable "iso_url" {
  type    = string
  default = "https://releases.ubuntu.com/22.04/ubuntu-22.04.4-live-server-amd64.iso"
}

source "qemu" "ubuntu_amd64" {
  iso_url          = var.iso_url
  iso_checksum     = var.iso_checksum
  output_directory = "output-ubuntu-qemu"
  shutdown_command = "echo 'packer' | sudo -S shutdown -P now"
  disk_size        = "15000M"
  format           = "qcow2"
  accelerator      = "kvm"
  http_directory   = "http"
  ssh_username     = "packer"
  ssh_password     = "UbuntuPacker2026!"
  ssh_timeout      = "20m"
  vm_name          = "ubuntu-2204-hardened.qcow2"
  net_device       = "virtio-net"
  disk_interface   = "virtio"
  boot_wait        = "5s"
  boot_command     = [
    "<wait>e<wait>",
    "<down><down><down><end>",
    " autoinstall ds=nocloud-net\\;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/",
    "<F10>"
  ]
}

build {
  sources = ["source.qemu.ubuntu_amd64"]

  provisioner "shell" {
    inline = [
      "sudo apt-get update",
      "sudo apt-get install -y auditd fail2ban",
      "sudo systemctl enable auditd",
      "sudo rm -f /etc/ssh/ssh_host_*",
      "sudo truncate -s 0 /etc/machine-id"
    ]
  }
}
```

#### Step 2: Validate and execute the build pipeline
Prepará el espacio de trabajo de build, validá la sintaxis HCL y ejecutá Packer para producir la imagen QCOW2 de destino.

```bash
mkdir -p http
touch http/user-data http/meta-data

packer init ubuntu-kvm.pkr.hcl
packer validate ubuntu-kvm.pkr.hcl
packer build ubuntu-kvm.pkr.hcl
```

**Expected Output:**
```text
qemu.ubuntu_amd64: output will be in directory: output-ubuntu-qemu
==> qemu.ubuntu_amd64: Downloading ISO...
==> qemu.ubuntu_amd64: Starting HTTP server on port 8123
==> qemu.ubuntu_amd64: Starting VM, formatting disk image...
==> qemu.ubuntu_amd64: Typing the boot command...
==> qemu.ubuntu_amd64: Waiting for SSH to become available...
==> qemu.ubuntu_amd64: Connected to SSH!
==> qemu.ubuntu_amd64: Provisioning with shell script...
    qemu.ubuntu_amd64: Setting up auditd...
==> qemu.ubuntu_amd64: Gracefully halting virtual machine...
==> qemu.ubuntu_amd64: Deleting unnecessary files...
Build 'qemu.ubuntu_amd64' finished after 7 minutes 12 seconds.

==> Builds finished. The artifacts of successful builds are:
--> qemu.ubuntu_amd64: VM files in directory: output-ubuntu-qemu
```

---

#### Concept Verification Questions — Exercise 3

1. **¿Qué función cumplen el parámetro `http_directory` y la construcción `{{ .HTTPIP }}:{{ .HTTPPort }}` durante la generación automatizada de imágenes de VM con Packer?**
2. **En pipelines de imágenes de CI/CD empresariales, ¿por qué se debe configurar la opción `accelerator = "kvm"` y qué problema de fallback ocurre si las extensiones de virtualización por hardware de KVM (`/dev/kvm`) no están expuestas en el entorno del worker de build?**

---

### Exercise 4: Multi-Node Orchestration with Vagrant and `vagrant-libvirt`

#### Objective
Configurar una infraestructura multinodo gestionada declarativamente utilizando HashiCorp Vagrant orientada a un backend de hipervisor `libvirt` nativo de Linux.

#### Step 1: Write a production-grade multi-node `Vagrantfile`
Creá un `Vagrantfile` que soporte dos nodos (Control Plane y nodo Worker) con red privada, asignación de memoria personalizada y provisioners inline.

```ruby
# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|
  config.vagrant.plugins = "vagrant-libvirt"
  config.vm.box = "generic/ubuntu2204"

  # Global Provider Settings for KVM/libvirt
  config.vm.provider :libvirt do |lv|
    lv.driver = "kvm"
    lv.connect_via_ssh = false
    lv.storage_pool_name = "default"
  end

  # Node 1: Control Plane
  config.vm.define "k8s-control" do |control|
    control.vm.hostname = "control-plane.infra.internal"
    control.vm.network "private_network", ip: "192.168.50.10"
    
    control.vm.provider :libvirt do |v|
      v.memory = 4096
      v.cpus = 2
      v.nested = true
    end

    control.vm.provision "shell", inline: <<-SHELL
      apt-get update && apt-get install -y curl transport-https ca-certificates
      echo "Control Plane Prepared"
    SHELL
  end

  # Node 2: Worker Node
  config.vm.define "k8s-worker" do |worker|
    worker.vm.hostname = "worker-01.infra.internal"
    worker.vm.network "private_network", ip: "192.168.50.11"

    worker.vm.provider :libvirt do |v|
      v.memory = 2048
      v.cpus = 2
    end

    worker.vm.provision "shell", inline: <<-SHELL
      apt-get update && apt-get install -y curl
      echo "Worker Node Prepared"
    SHELL
  end
end
```

#### Step 2: Bring up machines and verify network interfaces
Iniciá el entorno utilizando específicamente el proveedor `libvirt` y verificá los estados de los dominios con `virsh`.

```bash
vagrant up --provider=libvirt
vagrant status
virsh -c qemu:///system list --all
```

**Expected Output:**
```text
Bringing machine 'k8s-control' up with 'libvirt' provider...
Bringing machine 'k8s-worker' up with 'libvirt' provider...
==> k8s-control: Creating image (mapping backend box image...)
==> k8s-control: Creating domain with the following settings...
==> k8s-control:  -- Name:              vagrantfile_k8s-control
==> k8s-control:  -- Memory:            4096 MB
==> k8s-control:  -- CPUs:              2
==> k8s-control: Starting domain.
==> k8s-control: Waiting for domain to get an IP address...
==> k8s-control: Running provisioner: shell...
==> k8s-worker: Creating domain with the following settings...
==> k8s-worker: Starting domain.

Current machine states:

k8s-control               running (libvirt)
k8s-worker                running (libvirt)

 virsh -c qemu:///system list --all
 Id   Name                      State
-----------------------------------------
 1    vagrantfile_k8s-control   running
 2    vagrantfile_k8s-worker    running
```

---

#### Concept Verification Questions — Exercise 4

1. **¿Cómo maneja `vagrant-libvirt` las carpetas sincronizadas por defecto frente a cuando se configura explícitamente `config.vm.synced_folder ".", "/vagrant", type: "nfs"`?**
2. **¿Qué subcomando destruye todos los volúmenes de almacenamiento de dominio KVM subyacentes y las vinculaciones de red de libvirt gestionados por Vagrant sin dejar archivos QCOW2 huérfanos en el storage pool?**

---

## 3. Official References

- **Objetivos Detallados del Examen LPIC-3 305-300**: [https://www.lpi.org/our-certifications/lpic-3-305-overview/](https://www.lpi.org/our-certifications/lpic-3-305-overview/)
- **Documentación de Comandos y Herramientas Libguestfs**: [https://libguestfs.org/](https://libguestfs.org/)
- **Referencia de Fuentes de Datos y Configuración de Cloud-init**: [https://cloudinit.readthedocs.io/](https://cloudinit.readthedocs.io/)
- **Documentación de HashiCorp Packer QEMU Builder**: [https://developer.hashicorp.com/packer/integrations/hashicorp/qemu/latest/components/builder/qemu](https://developer.hashicorp.com/packer/integrations/hashicorp/qemu/latest/components/builder/qemu)
- **Especificación del Proveedor Vagrant Libvirt**: [https://github.com/vagrant-libvirt/vagrant-libvirt](https://github.com/vagrant-libvirt/vagrant-libvirt)

---

## 4. Verification Solutions

<details>
<summary>Hacé clic para desplegar Soluciones y Explicaciones Detalladas</summary>

### Exercise 1 Solutions

1. **Purga de Machine-IDs y Claves de Host:**  
   Las instancias del sistema operativo generan identificadores únicos (`/etc/machine-id` en sistemas Linux basados en systemd, y claves de host OpenSSH bajo `/etc/ssh/ssh_host_*`) para garantizar identidades criptográficas únicas a través de las topologías de red. Si múltiples máquinas virtuales clonadas conservan machine-ids idénticos:
   - Systemd-journald y los agregadores de logs remotos (por ejemplo, Fluentd, Loki) colapsan los logs en un único flujo de host.
   - Los clientes DHCP que aprovechan DUID (DHCP Unique Identifier) basado en `/etc/machine-id` recibirán direcciones IP duplicadas por parte de los servidores DHCP de la red.
   - Las claves de host SSH idénticas exponen el tráfico del host a ataques de tipo Man-In-The-Middle (MITM) y desencadenan fallos en la verificación de claves de host.

2. **Modificación de Imágenes Activas (Riesgos de Concurrencia):**  
   Ejecutar `virt-customize`, `virt-sysprep` o `guestfish` en modo escritura contra un disco de SO guest activo y en ejecución provoca la corrupción instantánea del sistema de archivos. El appliance temporal QEMU de `libguestfs` en el host monta las estructuras de bloques subyacentes sin coordinar con el page cache o el estado del journal del kernel de la VM activa. Esto modifica de forma concurrente las tablas de asignación de bloques, lo que resulta en inodos corruptos, errores irrecuperables de ext4/xfs y kernel panics en el guest. `libguestfs` bloquea los archivos de disco mediante `virt-locking` o `flock` cuando se integra con libvirt para evitar el acoplamiento concurrente.

---

### Exercise 2 Solutions

1. **Diagnóstico de Archivos de Log (`cloud-init.log` frente a `cloud-init-output.log`):**  
   - `/var/log/cloud-init.log`: Contiene tracebacks internos detallados de Python, líneas de tiempo de ejecución de módulos, pasos de resolución de fuentes de datos, árboles de decisión de estado y logs de análisis de configuración generados directamente por el framework `cloud-init`.
   - `/var/log/cloud-init-output.log`: Captura los flujos de stdout y stderr emitidos por los subprocesos iniciados *por* cloud-init durante la ejecución (por ejemplo, salidas en bruto de scripts de shell bajo `runcmd`, salidas de paquetes de `apt`/`yum` y salidas de hooks de `write_files`).

2. **Reinicio del Estado de Cloud-init:**  
   Para purgar los metadatos en caché y forzar a cloud-init a ejecutarse nuevamente desde cero en el próximo reinicio del sistema, ejecutá:
   ```bash
   cloud-init clean --logs --reboot
   ```
   Para limpiar el estado local sin un reinicio inmediato y volver a ejecutar los módulos manualmente:
   ```bash
   cloud-init clean
   cloud-init init --local
   cloud-init init
   cloud-init modules --mode=config
   cloud-init modules --mode=final
   ```

---

### Exercise 3 Solutions

1. **Mecánica del Directorio HTTP de Packer:**  
   Durante la instalación desatendida (headless) de un SO (por ejemplo, Ubuntu Subiquity / Red Hat Kickstart), el instalador requiere acceso a archivos de respuesta (`user-data`, `ks.cfg`). El parámetro `http_directory` le indica a Packer que inicie un servidor HTTP temporal vinculado a un puerto efímero del host. Las variables de plantilla `{{ .HTTPIP }}` y `{{ .HTTPPort }}` inyectan dinámicamente la dirección IP del host y el puerto seleccionado automáticamente en el comando de arranque de la VM, lo que permite al instalador del kernel del guest descargar archivos preseed directamente a través de la red virtual.

2. **Aceleración por Hardware KVM frente a Emulación:**  
   La directiva `accelerator = "kvm"` le indica a QEMU que pase las instrucciones de virtualización de la CPU directamente a los flags de hardware de la CPU física (`/dev/kvm` a través de VT-x o AMD-V). Si faltan las extensiones de KVM (por ejemplo, al ejecutarse dentro de un worker en una VM anidada sin virtualización anidada habilitada), QEMU recurre a instrucciones de CPU emuladas por software (modo `TCG`). Esto hace que el tiempo de ejecución del build de la imagen empeore drásticamente (tomando hasta 10-15 veces más tiempo), activando con frecuencia timeouts en los pasos de la fase de handshake de SSH.

---

### Exercise 4 Solutions

1. **Tipos de Carpetas Sincronizadas en Vagrant:**  
   Por defecto, `vagrant-libvirt` utiliza `rsync` para la sincronización de carpetas, lo que realiza una copia unidireccional de archivos desde el host hacia el guest al invocar `vagrant up` o `vagrant reload` (sincronización solo de host a guest, no en tiempo real). Cuando se configura explícitamente `type: "nfs"`, Vagrant configura daemons de kernel NFS a nivel de host (`nfs-kernel-server`), creando un montaje bidireccional en tiempo real a través del bridge de la red privada con un rendimiento (throughput) de E/S de disco significativamente mayor.

2. **Destrucción Limpia del Entorno:**  
   Para purgar completamente las instancias de VM junto con sus volúmenes de almacenamiento, interfaces de red y metadatos efímeros, ejecutá:
   ```bash
   vagrant destroy -f
   ```
   Para purgar manualmente los storage pools remanentes a nivel del hipervisor:
   ```bash
   virsh volume-wipe --pool default <volume-name>.qcow2
   virsh volume-delete --pool default <volume-name>.qcow2
   ```

</details>