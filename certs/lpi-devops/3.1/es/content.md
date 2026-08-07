# Guía de Estudio LPI DevOps Tools Engineer (701-100)
## Tema 3.1: Despliegue de Máquinas Virtuales (Peso: 6.67)

---

## 1. Motivación y Problema Arquitectónico de Producción

### 1.1 Contexto y Declaración del Problema de Producción
Los equipos modernos de SRE y Platform Engineering enfrentan una tensión arquitectónica fundamental: **Infraestructura Inmutable vs. Gestión del Ciclo de Vida Mutable**. En entornos virtualizados empresariales e híbridos en la nube, desplegar Máquinas Virtuales (VMs) puramente a través de instalaciones base manuales o scripts de shell imperativos conduce a graves riesgos operacionales:

1. **Configuración Desplazada (Configuration Drift)**: Con el tiempo, las VMs desplegadas a partir de ISOs genéricas divergen en niveles de parches, parámetros del kernel y bibliotecas del sistema.
2. **Latencia de Inicio en Frío (Cold-Boot Latency)**: La instalación dinámica de actualizaciones de seguridad, dependencias del runtime y agentes de monitoreo durante el inicio inicial prolonga las ventanas de despliegue de segundos a decenas de minutos.
3. **Bloqueo de Hipervisor y Entorno (Hypervisor & Environment Lock-in)**: Los desarrolladores que ejecutan hipervisores de escritorio (ej., Oracle VirtualBox) a menudo encuentran fallos del tipo "funciona en mi máquina" cuando la infraestructura de staging y producción se ejecuta en hipervisores Tipo-1 (ej., KVM/QEMU gestionado por `libvirt`) o instancias de AWS EC2.

### 1.2 Solución Arquitectónica: El Pipeline de Entrega de VMs de 3 Capas
Para resolver estos desafíos a escala, la arquitectura de producción desacopla la creación de VMs en tres fases distintas y deterministas del ciclo de vida:

```
+------------------+      +-------------------+      +----------------------+
| 1. BUILD PHASE   |      | 2. PACKAGING      |      | 3. PROVISION PHASE   |
| (Packer)         | ---> | (Vagrant / AMI)   | ---> | (Cloud-init)         |
| Bake static image|      | Artifact Registry |      | Dynamic boot config  |
+------------------+      +-------------------+      +----------------------+
```

1. **Fase de Creación (Packer)**: Automatiza la creación de "Golden Images" idénticas y pre-endurecidas a través de múltiples formatos de hipervisor objetivo (`qemu/kvm`, `virtualbox`, `amazon-ebs`) directamente desde ISOs oficiales.
2. **Fase de Distribución y Orquestación Local (Vagrant)**: Proporciona instancias de VM declarativas y reproducibles para desarrollo local, entornos de prueba y pipelines de CI/CD, abstrayendo configuraciones específicas del hipervisor mediante proveedores.
3. **Fase de Inicialización (Cloud-init)**: Estandariza la configuración en runtime al inicio temprano (hostname, interfaces de red, claves SSH, creación de usuarios, obtención dinámica de secretos) sin requerir la reconstrucción de la imagen.

---

## 2. Comparaciones Técnicas y Tablas de Sopeso (Trade-Offs)

### 2.1 Herramientas de Aprovisionamiento y Ciclo de Vida de Máquinas Virtuales

| Criterio | HashiCorp Packer | Vagrant | Cloud-init | Terraform / Ansible |
| :--- | :--- | :--- | :--- | :--- |
| **Alcance Principal** | Creación de Golden Images Estáticas | Orquestación de VMs Locales/Efímeras | Inicialización del Motor del Sistema Operativo en Runtime | Gestión de Infraestructura / Configuración |
| **Fase del Ciclo de Vida** | Pre-despliegue (Build) | Desarrollo Local / Ejecución de Pruebas de CI | Ejecución en el Primer Inicio | Infraestructura Día-1 y Configuración Día-2 |
| **Punto de Ejecución** | Servidor de Build / Pipeline | Estación de Trabajo Local / Runner de CI | Inicio del Kernel del SO Invitado (`systemd`) | Plano de Control Maestro / SSH sin Agente |
| **Artefacto de Salida** | QCOW2, VMDK, AMI, Box | Instancias de VM en Ejecución | Sistema Operativo Invitado Mutado | Recursos de Nube/Infraestructura Aprovisionados |
| **Rastreo de Estado** | Sin Estado (Build y Destrucción) | Estado Local (`.vagrant/`) | Estado Local (`/var/lib/cloud/`) | Archivo de Estado (`terraform.tfstate`) |

### 2.2 Hipervisores y Abstracciones de Gestión

| Característica / Métrica | KVM / QEMU (`libvirt`) | Oracle VirtualBox (`VBoxManage`) | AWS EC2 (Nitro Hypervisor) |
| :--- | :--- | :--- | :--- |
| **Tipo de Hipervisor** | Tipo-1 (Integrado en el Kernel) | Tipo-2 (Hospedado) | Tipo-1 (ASIC Bare-Metal Personalizado) |
| **Carga de Trabajo Objetivo** | Linux de Producción / Nube Privada | Desarrollo Local en Escritorio | Infraestructura de Nube Pública |
| **Interfaz de Gestión**| `virsh`, `libvirtd`, C API | `VBoxManage`, GUI | AWS CLI, EC2 API |
| **Proveedor de Vagrant** | `vagrant-libvirt` (Plugin) | `virtualbox` (Integrado) | `vagrant-aws` (Plugin) |
| **Builder de Packer** | `qemu` | `virtualbox-iso` / `virtualbox-ovf` | `amazon-ebs` / `amazon-chroot` |
| **Formatos de Imagen de Disco** | QCOW2, RAW | VDI, VMDK | Volúmenes EBS, AMI |

### 2.3 Etapas de Ejecución de Cloud-init vs. Aprovisionamiento con Ansible

| Etapa / Herramienta | Momento de Inicio | Casos de Uso Típicos | Manejo de Fallos |
| :--- | :--- | :--- | :--- |
| **`bootcmd`** | Inicio temprano (antes de la red) | Formateo de almacenamiento, configuración de rutas de red | Ejecución bloqueante; los errores detienen init |
| **`write_files`** | Inicio medio (disco montado) | Inyección de configuración de `/etc/`, unidades de systemd | Sobrescribe archivos existentes si está configurado |
| **`runcmd`** | Inicio tardío (después de la red) | Actualizaciones de paquetes, inicio de servicios de systemd | Códigos de salida de shell registrados en archivo de salida |
| **Ansible Provisioner**| Inicialización posterior a SSH | Orquestación compleja, idempotencia de estado | Reversión a nivel de tarea o detención de ejecución |

---

## 3. Manifiestos de Infraestructura de Producción

### 3.1 Plantilla de Golden Image HCL2 de HashiCorp Packer
Este manifiesto (`ubuntu-2204-golden.pkr.hcl`) crea una imagen QCOW2 de Ubuntu 22.04 LTS para KVM/QEMU, asegura el SO, instala agentes de producción y genera un box de Vagrant.

```hcl
packer {
  required_version = ">= 1.8.0"
  required_plugins {
    qemu = {
      version = ">= 1.0.9"
      source  = "github.com/hashicorp/qemu"
    }
    vagrant = {
      version = ">= 1.0.2"
      source  = "github.com/hashicorp/vagrant"
    }
  }
}

variable "iso_checksum" {
  type    = string
  default = "file:https://releases.ubuntu.com/22.04/SHA256SUMS"
}

variable "iso_url" {
  type    = string
  default = "https://releases.ubuntu.com/22.04/ubuntu-22.04.4-live-server-amd64.iso"
}

source "qemu" "ubuntu_core" {
  iso_url          = var.iso_url
  iso_checksum     = var.iso_checksum
  output_directory = "build-ubuntu-2204"
  shutdown_command = "echo 'vagrant' | sudo -S shutdown -P now"
  disk_size        = "20480M"
  format           = "qcow2"
  accelerator      = "kvm"
  http_directory   = "http"
  ssh_username     = "vagrant"
  ssh_password     = "vagrant"
  ssh_timeout      = "20m"
  cpus             = 2
  memory           = 2048
  boot_wait        = "5s"
  boot_command     = [
    "<wait>e<wait><down><down><down><end>",
    " autoinstall ds=nocloud-net;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/",
    "<F10>"
  ]
}

build {
  name = "production-ubuntu-golden-image"
  sources = ["source.qemu.ubuntu_core"]

  provisioner "shell" {
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive"
    ]
    inline = [
      "sudo apt-get update -y",
      "sudo apt-get upgrade -y",
      "sudo apt-get install -y cloud-init qemu-guest-agent curl htop net-tools",
      "sudo systemctl enable qemu-guest-agent",
      "sudo rm -f /etc/udev/rules.d/70-persistent-net.rules",
      "sudo cloud-init clean --logs --seed"
    ]
  }

  post-processor "vagrant" {
    keep_input_artifact = false
    output              = "output/ubuntu-2204-golden.box"
  }
}
```

---

### 3.2 Manifiesto Declarativo Vagrantfile
Este `Vagrantfile` de nivel de producción configura una topología de doble máquina (`web` y `db`) utilizando anulaciones de proveedor de hipervisor (Libvirt y VirtualBox), interfaces de red personalizadas, carpetas sincronizadas e inyección de user-data de Cloud-init.

```ruby
# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|
  config.vagrant.plugins = ["vagrant-libvirt"]

  # Global Box Settings
  config.vm.box = "ubuntu/jammy64"
  config.vm.box_check_update = true

  # Synced Folders Configuration (NFS for Libvirt, standard for VirtualBox)
  config.vm.synced_folder "./app", "/var/www/html", Type: "nfs",
    nfs_version: 4,
    nfs_udp: false

  # =========================================================================
  # Database Server Instance Definition
  # =========================================================================
  config.vm.define "db" do |db|
    db.vm.hostname = "db-01.internal.net"
    db.vm.network "private_network", ip: "192.168.56.10"

    # Libvirt (KVM/QEMU) Provider Settings
    db.vm.provider :libvirt do |lv, override|
      lv.memory = "2048"
      lv.cpus = 2
      lv.driver = "kvm"
      lv.storage :file, size: "10G", type: "qcow2"
    end

    # VirtualBox Fallback Provider Settings
    db.vm.provider :virtualbox do |vbox, override|
      vbox.name = "prod-db-01"
      vbox.memory = "2048"
      vbox.cpus = 2
      vbox.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
    end

    # Provisioner: Inline Shell script for initial database setup
    db.vm.provision "shell", inline: <<-SHELL
      set -euo pipefail
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y postgresql postgresql-contrib
      systemctl enable --now postgresql
    SHELL
  end

  # =========================================================================
  # Web Application Server Instance Definition
  # =========================================================================
  config.vm.define "web" do |web|
    web.vm.hostname = "web-01.internal.net"
    web.vm.network "private_network", ip: "192.168.56.11"
    web.vm.network "forwarded_port", guest: 80, host: 8080, auto_correct: true

    # Injecting Cloud-init User Data during provisioning
    web.vm.provision "shell", inline: <<-SHELL
      cat <<'EOF' > /etc/cloud/cloud.cfg.d/99-custom-user-data.cfg
#cloud-config
packages:
  - nginx
runcmd:
  - systemctl enable --now nginx
EOF
      cloud-init clean --logs
      cloud-init init
      cloud-init modules --mode final
    SHELL
  end
end
```

---

### 3.3 Manifiesto `user-data` de Cloud-init de Producción (`#cloud-config`)
Este documento `#cloud-config` proporciona un arranque determinista del sistema: configuración de parámetros de host, gestión de usuarios y acceso SSH, creación de servicios systemd personalizados, instalación de paquetes y ejecución de pasos de verificación posteriores al inicio.

```yaml
#cloud-config
hostname: node-01
fqdn: node-01.production.internal
manage_etc_hosts: true

users:
  - default
  - name: sysadmin
    gecos: System Administrator
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: [users, wheel, docker]
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCz7VpW... sysadmin@infrastructure.local

package_update: true
package_upgrade: true
packages:
  - curl
  - wget
  - git
  - apt-transport-https
  - ca-certificates
  - gnupg
  - lsb-release

write_files:
  - path: /etc/sysctl.d/99-kubernetes-cri.conf
    permissions: '0644'
    owner: root:root
    content: |
      net.bridge.bridge-nf-call-iptables  = 1
      net.ipv4.ip_forward                 = 1
      net.bridge.bridge-nf-call-ip6tables = 1

  - path: /etc/systemd/system/healthcheck.service
    permissions: '0644'
    owner: root:root
    content: |
      [Unit]
      Description=Production Node Healthcheck Service
      After=network.target

      [Service]
      Type=oneshot
      ExecStart=/usr/bin/curl -s -f http://localhost/healthz || exit 1
      RemainAfterExit=yes

      [Install]
      WantedBy=multi-user.target

bootcmd:
  - [ modprobe, overlay ]
  - [ modprobe, br_netfilter ]

runcmd:
  - sysctl --system
  - systemctl daemon-reload
  - systemctl enable --now healthcheck.service
  - echo "Bootstrap completed successfully at $(date)" > /var/log/bootstrap.log

final_message: "System initialization complete via cloud-init after $UPTIME seconds."
```

---

## 4. Comandos de CLI Reales y Salida de Terminal Esperada

### 4.1 Operaciones con HashiCorp Packer

#### Validar la Sintaxis del Manifiesto de Packer
```bash
$ packer validate ubuntu-2204-golden.pkr.hcl
```
**Salida:**
```text
The configuration is valid.
```

#### Ejecutar la Construcción de la Golden Image
```bash
$ packer build ubuntu-2204-golden.pkr.hcl
```
**Salida:**
```text
production-ubuntu-golden-image.qemu.ubuntu_core: output will be in this color.

==> production-ubuntu-golden-image.qemu.ubuntu_core: Downloading ISO...
    production-ubuntu-golden-image.qemu.ubuntu_core: ISO: https://releases.ubuntu.com/22.04/ubuntu-22.04.4-live-server-amd64.iso
==> production-ubuntu-golden-image.qemu.ubuntu_core: Starting HTTP server on port 8543
==> production-ubuntu-golden-image.qemu.ubuntu_core: Starting VM, waiting for boot sequence...
==> production-ubuntu-golden-image.qemu.ubuntu_core: Waiting 5s for boot...
==> production-ubuntu-golden-image.qemu.ubuntu_core: Typing the boot command over VNC...
==> production-ubuntu-golden-image.qemu.ubuntu_core: Using ssh communicator to connect: 127.0.0.1
==> production-ubuntu-golden-image.qemu.ubuntu_core: Waiting for SSH to become available...
==> production-ubuntu-golden-image.qemu.ubuntu_core: Connected to SSH!
==> production-ubuntu-golden-image.qemu.ubuntu_core: Provisioning with shell script...
    production-ubuntu-golden-image.qemu.ubuntu_core: Get:1 http://archive.ubuntu.com/ubuntu jammy InRelease [270 kB]
    production-ubuntu-golden-image.qemu.ubuntu_core: Reading package lists... Done
    production-ubuntu-golden-image.qemu.ubuntu_core: qemu-guest-agent is already the newest version.
==> production-ubuntu-golden-image.qemu.ubuntu_core: Gracefully halting virtual machine...
==> production-ubuntu-golden-image.qemu.ubuntu_core: Running post-processor: vagrant
    production-ubuntu-golden-image.qemu.ubuntu_core (vagrant): Creating Vagrant box for 'qemu' provider
    production-ubuntu-golden-image.qemu.ubuntu_core (vagrant): Author: Vagrant
    production-ubuntu-golden-image.qemu.ubuntu_core (vagrant): Compression level: 6
    production-ubuntu-golden-image.qemu.ubuntu_core (vagrant): Creating box: output/ubuntu-2204-golden.box
Build 'production-ubuntu-golden-image.qemu.ubuntu_core' finished after 7 minutes 34 seconds.

==> Builds finished. The artifacts of successful builds are:
--> production-ubuntu-golden-image.qemu.ubuntu_core: VM files in directory: build-ubuntu-2204
--> production-ubuntu-golden-image.qemu.ubuntu_core: 'vagrant' provider box: output/ubuntu-2204-golden.box
```

---

### 4.2 Operaciones y Ciclo de Vida de Vagrant

#### Gestión de Boxes de Vagrant
```bash
$ vagrant box add production/ubuntu-2204 output/ubuntu-2204-golden.box
```
**Salida:**
```text
==> box: Box file allocated successfully.
==> box: Adding box 'production/ubuntu-2204' (v0) for provider: qemu
    box: Downloading: file:///home/deploy/output/ubuntu-2204-golden.box
==> box: Successfully added box 'production/ubuntu-2204' (v0) for 'qemu'!
```

#### Levantar Topología Multi-VM (Apuntando a Libvirt)
```bash
$ vagrant up --provider=libvirt
```
**Salida:**
```text
Bring machine 'db' up with 'libvirt' provider...
Bring machine 'web' up with 'libvirt' provider...
==> db: Registering domain in libvirt's QEMU control panel...
==> db: Creating storage pool volume...
==> db: Creating domain if not exists...
==> db: Starting domain.
==> db: Waiting for domain to get an IP address...
==> db: Waiting for SSH to become available...
    db: SSH address: 192.168.121.144:22
    db: SSH username: vagrant
    db: SSH key inserted: /home/user/.vagrant.d/insecure_private_key
==> db: Forwarding ports...
==> db: Setting hostname...
==> db: Configuring and enabling network interfaces...
==> db: Running provisioner: shell...
    db: Running inline script
==> web: Registering domain in libvirt's QEMU control panel...
==> web: Starting domain.
==> web: Waiting for SSH to become available...
==> web: Forwarding ports...
    web: 80 (guest) => 8080 (host) (adapter eth0)
```

#### Inspeccionar Entornos Activos de Vagrant
```bash
$ vagrant status
```
**Salida:**
```text
Current machine states:

db                        running (libvirt)
web                       running (libvirt)

This environment represents multiple VMs. The VMs are all listed
above along with their current state. To control a specific machine,
pass its name as an argument to `vagrant`. e.g. `vagrant up web`
```

#### Consultar Puertos de Red Reenviados Activos
```bash
$ vagrant port
```
**Salida:**
```text
The forwarded ports for this environment are listed below. For
details on specific machines, please run `vagrant port <machine-name>`.

web:
  80 (guest) => 8080 (host)
```

---

### 4.3 Comandos de Inspección del Hipervisor

#### Consultar Dominios KVM de `libvirt`
```bash
$ virsh list --all
```
**Salida:**
```text
 Id   Name                   State
--------------------------------------
 1    vagrant_db             running
 2    vagrant_web            running
 -    template_ubuntu_2204   shut off
```

#### Consultar Metadatos de Arquitectura de un Dominio KVM Específico
```bash
$ virsh dominfo vagrant_web
```
**Salida:**
```text
Id:             2
Name:           vagrant_web
UUID:           a8f34bc1-829d-4e92-b2d9-11c5e408d3e2
OS Type:        hvm
State:          running
CPU(s):         2
CPU time:       14.2s
Max memory:     2097152 KiB
Used memory:    2097152 KiB
Persistent:     yes
Autostart:      disable
Managed save:   no
Security model: apparmor
Security DOI:   0
```

#### Consultar VMs de Oracle VirtualBox (`VBoxManage`)
```bash
$ VBoxManage list vms
```
**Salida:**
```text
"prod-db-01" {5a9632eb-0c7f-4b08-9b88-df092b13c2f9}
"prod-web-01" {c2184e49-8d76-4318-971c-43f11059f13e}
```

---

## 5. Guía de Verificación y Diagnóstico de Fallos

### 5.1 Marco de Diagnóstico de Cloud-init

#### Verificar el Estado de Ejecución y las Etapas de Inicio
```bash
$ cloud-init status --long
```
**Salida:**
```text
status: done
extended_status: done
boot_status_code: enabled-by-sysv-init
last_update: Fri, 07 Aug 2026 08:30:12 +0000
detail:
DataSourceNoCloud [seed=/var/lib/cloud/seed/nocloud-net][token=nocloud]
```

#### Trazar Marcas de Tiempo de Ejecución a través de los Módulos de Inicio
```bash
$ cloud-init analyze boot
```
**Salida:**
```text
-- Boot Record 01 --
1. 00.12000s (kernel) init initialized
2. 01.45000s (user-data) unconfigured
3. 02.11000s (init-network) bring up network interfaces
4. 04.89000s (modules-config) write_files completed
5. 08.34000s (modules-final) runcmd executed successfully
Finished stage: (final) in 09.21000s
```

#### Inspección de Archivos de Log
Ubicaciones principales de logs para la resolución de problemas:
- Log principal de traza detallada: `/var/log/cloud-init.log`
- Log de salida de STDOUT/STDERR de consola: `/var/log/cloud-init-output.log`

```bash
$ grep -i "error" /var/log/cloud-init.log
```
**Salida:**
```text
2026-08-07 08:30:05,112 - util.py[WARNING]: Failed running /var/lib/cloud/instance/scripts/runcmd-1 [1]
2026-08-07 08:30:05,115 - cc_runcmd.py[ERROR]: Script failed with return code 1
```

#### Forzar Reejecución de Cloud-init (Depuración)
Para volver a ejecutar `cloud-init` sin volver a crear la instancia de VM:
```bash
# 1. Clear state metadata and logs
$ sudo cloud-init clean --logs --seed

# 2. Re-trigger stage execution
$ sudo cloud-init init
$ sudo cloud-init modules --mode=config
$ sudo cloud-init modules --mode=final
```

---

### 5.2 Matriz de Decisión de Diagnóstico de Fallos para SRE

```
                      +---------------------------------+
                      | VM Failed Boot / Provisioning   |
                      +---------------------------------+
                                       |
           +---------------------------+---------------------------+
           |                                                       |
 [Vagrant / Hypervisor Level]                             [OS / Cloud-init Level]
           |                                                       |
+--------------------------+                             +--------------------------+
| Symptom:                 |                             | Symptom:                 |
| - SSH Timeout            |                             | - Stuck at Boot          |
| - Driver Mismatch        |                             | - Missing Services       |
| - Provider Error         |                             | - User Key Rejection     |
+--------------------------+                             +--------------------------+
           |                                                       |
           v                                                       v
+--------------------------+                             +--------------------------+
| Action:                  |                             | Action:                  |
| VAGRANT_LOG=debug        |                             | Check /var/log/          |
| virsh console <domain>   |                             | cloud-init-output.log    |
| VBoxManage showvminfo    |                             | Verify #cloud-config YAML|
+--------------------------+                             +--------------------------+
```

#### Modos de Fallo Comunes y Remediación

##### Modo de Fallo 1: Timeout de SSH en Vagrant al ejecutar `vagrant up`
* **Causa Raíz**: La configuración de la interfaz de red dentro del box perdió su asignación de cliente DHCP, o el bridge de red del hipervisor está caído.
* **Comando de Diagnóstico**:
  ```bash
  $ VAGRANT_LOG=debug vagrant up
  ```
* **Acceso de Emergencia por Consola KVM**:
  ```bash
  $ virsh console vagrant_web
  ```
  *(Presione `Enter` para acceder a la consola TTY serie y revisar la salida de dmesg del kernel)*.

##### Modo de Fallo 2: Sintaxis YAML Inválida en Cloud-init
* **Causa Raíz**: Falta el encabezado `#cloud-config` en la línea 1, o indentación de espacios inadecuada.
* **Comando de Diagnóstico**:
  ```bash
  $ cloud-init schema --config-file /etc/cloud/cloud.cfg.d/99-custom-user-data.cfg
  ```
* **Salida Esperada en Caso de Error**:
  ```text
  Error: Cloud-config schema errors: line 12: key 'user' is not valid under 'users'
  ```

##### Modo de Fallo 3: Timeout del Provisioner Shell de Packer
* **Causa Raíz**: Prompts interactivos de APT bloqueando la ejecución indefinidamente (ej., `debconf` pidiendo configuración de teclado).
* **Remediación**: Pasar flags no interactivas explícitas dentro del bloque shell de Packer:
  ```hcl
  environment_vars = [
    "DEBIAN_FRONTEND=noninteractive",
    "NEEDRESTART_MODE=a"
  ]
  ```

---

## 6. Referencias

- [LPI DevOps Tools Engineer Official Overview](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
- [LPI 701-100 Detailed Exam Objectives](https://wiki.lpi.org/wiki/LPIC-OT_Topic_701)
- [HashiCorp Packer Documentation](https://developer.hashicorp.com/packer/docs)
- [HashiCorp Vagrant Documentation](https://developer.hashicorp.com/vagrant/docs)
- [Cloud-init Official Documentation](https://cloudinit.readthedocs.io/en/latest/)
- [Libvirt KVM Virtualization Management Architecture](https://libvirt.org/documentation.html)