# LPIC-3 Exam 305: Virtualization and Containerization (Version 3.0)
## Topic 353 / 1.3: VM Deployment and Provisioning (Weight: 33.34%)

---

## 1. Production Architectural Motivation & Problem Statement

En las plataformas empresariales cloud-native modernas, la gestión de máquinas virtuales ha evolucionado desde el aprovisionamiento imperativo y manual de hipervisores ("snowflake servers") hacia **pipelines de infraestructura declarativa, automatizada e inmutable**. A gran escala, la gestión de cargas de trabajo virtualizadas requiere aprovisionamiento zero-touch, una ejecución predecible de máquinas de estado y una alineación estricta con los principios de Site Reliability Engineering (SRE), tales como infraestructura como código (IaC), GitOps y entornos efímeros.

### The Enterprise Architectural Challenge
Considere una plataforma financiera que requiere miles de nodos de cómputo ejecutando máquinas virtuales respaldadas por hipervisores a través de proveedores de nube privada (OpenStack/KVM) y nube pública (AWS/GCP/Azure). Aprovisionar máquinas virtuales manualmente, conectarse por SSH a instalaciones de SO sin ajustar y ejecutar scripts de configuración imperativos introduce:
1. **Configuration Drift**: Divergencia entre el estado en ejecución y la arquitectura objetivo debido a hotfixes manuales, parches de SO no rastreados y scripts no idempotentes.
2. **Slow Bootstrapping and Boot Latency**: Ejecutar agentes pesados de gestión de configuración (ej. Ansible, Puppet, Chef) tras el arranque en imágenes de SO vanilla toma de 15 a 45 minutos por nodo, bloqueando eventos de auto-scaling durante picos de tráfico.
3. **Provider Lock-In**: Formatos de imagen inconsistentes (`qcow2`, `vhd`, `vmdk`, `raw`, AMI) que impiden un despliegue unificado en nube híbrida.
4. **Flaky Boot Sequences & Race Conditions**: Servicios de Systemd que inician antes de que las interfaces de red o los servicios de metadatos de la nube estén completamente poblados por el plano de control del hipervisor.

### The Unified Immutable Provisioning Pipeline
Para eliminar estos anti-patrones, los SREs senior y arquitectos de plataformas implementan una arquitectura de aprovisionamiento de múltiples niveles:

```
+-----------------------------------------------------------------------------------+
| 1. IMAGE BAKING PHASE (HashiCorp Packer)                                         |
|    Base OS ISO + Security Hardening + Base Packages ===> Hardened Golden Image   |
+-----------------------------------------------------------------------------------+
                                        |
                                        v
+-----------------------------------------------------------------------------------+
| 2. ORCHESTRATION & FABRIC LAYERING (Terraform / OpenStack / Vagrant)              |
|    Hypervisor API Call -> Allocate vCPU/RAM/Storage/NIC -> Inject Metadata         |
+-----------------------------------------------------------------------------------+
                                        |
                                        v
+-----------------------------------------------------------------------------------+
| 3. INSTANCE BOOTSTRAP PHASE (cloud-init)                                          |
|    Kernel Boot -> Local Datasource Detection -> Metadata Injection -> Final State |
+-----------------------------------------------------------------------------------+
```

---

## 2. Technical Deep Dives & Trade-Off Matrix

### 2.1 Cloud Management Platforms & IaaS Orchestrators (Objective 353.1)

Las Cloud Management Platforms (CMPs) proporcionan capas de abstracción de API unificadas, multatenencia, virtualización de red (SDN) y orquestación de almacenamiento (SDS) sobre hipervisores como KVM y Xen.

*   **OpenStack**: El estándar empresarial de código abierto para nubes privadas. Los microservicios núcleo interactúan mediante APIs REST:
    *   **Nova**: Controlador de cómputo que interactúa con libvirt/KVM.
    *   **Glance**: Almacén de imágenes (`qcow2`, `raw`).
    *   **Neutron**: Controlador SDN que gestiona puentes OVS/OVN, túneles VXLAN/Geneve e IPs flotantes.
    *   **Cinder**: Proveedor de almacenamiento de bloques (Ceph, iSCSI).
    *   **Keystone**: Servicio de autenticación, autorización y tokens RBAC.
    *   **Heat**: Motor de orquestación declarativo que utiliza HOT (Heat Orchestration Templates).
*   **Terraform**: Una herramienta de infraestructura como código (IaC) declarativa de código abierto que utiliza grafos acíclicos dirigidos (DAG) para evaluar dependencias de recursos. Interactúa directamente con las APIs de la nube (OpenStack, AWS, vSphere, Libvirt) sin requerir un demonio del lado del servidor.
*   **CloudStack / OpenNebula / Eucalyptus**: Soluciones IaaS llave en mano que ofrecen alternativas en los balances del plano de control. CloudStack enfatiza arquitecturas llave en mano orientadas a appliances; OpenNebula se enfoca en edge computing y gestión ligera de hipervisores; Eucalyptus proporciona capas de API compatibles con AWS.

### 2.2 Golden Image Baking: HashiCorp Packer Mechanics (Objective 353.2)

Packer automatiza la generación de imágenes de máquinas virtuales idénticas a través de múltiples plataformas (QEMU/KVM, VirtualBox, VMware, AWS EBS) utilizando plantillas declarativas en HCL2 (HashiCorp Configuration Language).

#### Packer Internal Architecture
1. **Matrix Builders**: Instancia una máquina virtual aislada (ej. demonio QEMU KVM) conectada a un servidor HTTP local que aloja un seed de instalación automatizada (ej. Kickstart, Ubuntu autoinstall).
2. **Boot Command Execution**: Envía pulsaciones de teclas VNC puras para pasar argumentos al kernel (`ds=nocloud-net;s=http://...`) para arrancar el instalador.
3. **Provisioners**: Espera conectividad SSH/WinRM, luego ejecuta scripts, comandos de shell o ejecuciones de gestión de configuración dentro de la VM transitoria.
4. **Cleanup & Compaction**: Llena de ceros el espacio libre (`dd if=/dev/zero of=/EMPTY bs=1M`), trunca el machine-id (`/etc/machine-id`), elimina el estado de cloud-init y apaga la VM.
5. **Post-Processors**: Convierte, comprime y registra el artefacto de salida (`qcow2`, AMI, Vagrant `.box`).

### 2.3 Cloud Instance Bootstrapping: cloud-init Internal Mechanics (Objective 353.3)

`cloud-init` es el sistema estándar multi-distribución para la inicialización temprana del arranque. Se ejecuta durante las fases de inicio de systemd para transformar una imagen golden genérica en un nodo de producción completamente configurado.

#### Execution Phases & Systemd Integration
`cloud-init` se ejecuta en cuatro fases secuenciales distintas de systemd:

```
Phase 1: Generator -> Phase 2: init-local -> Phase 3: init -> Phase 4: modules (config/final)
```

1. **`cloud-init-local.service` (Generator & Local Phase)**:
   * **Goal**: Bloquear la inicialización de la red hasta que se descubran los metadatos locales.
   * **Datasources**: Busca adjuntos locales (ej. unidades ISO/vfat `NoCloud`, `ConfigDrive`). Si los encuentra, aplica la configuración de red temprana (`/etc/netplan/` o systemd-networkd) antes de que la red principal levante las interfaces.
2. **`cloud-init.service` (Network Phase)**:
   * **Goal**: Obtener metadatos remotos sobre HTTP (ej. OpenStack/AWS IMDS en `http://169.254.169.254/`).
   * **Actions**: Analiza `user-data`, establece el hostname del sistema, procesa claves públicas SSH, escribe `/etc/hosts`.
3. **`cloud-config.service` (Config Phase)**:
   * **Goal**: Ejecutar módulos de configuración estructural.
   * **Actions**: Crea usuarios locales (`users`), configura montajes de disco (`mounts`), redimensiona la partición raíz (`growpart`), escribe archivos estáticos (`write_files`).
4. **`cloud-final.service` (Final Phase)**:
   * **Goal**: Ejecutar scripts de carga útil del usuario al final de la secuencia de arranque.
   * **Actions**: Ejecuta `runcmd`, ejecuta scripts en `/var/lib/cloud/scripts/per-boot/` y `per-once/`, emite señales de finalización (`phone_home`).

#### Critical Filesystem Paths
* `/etc/cloud/cloud.cfg`: Configuración principal del proveedor y listas de ejecución de módulos.
* `/etc/cloud/cloud.cfg.d/*.cfg`: Anulaciones y fragmentos de configuración local.
* `/var/lib/cloud/instance/`: Enlace simbólico al estado actual de metadatos de la instancia (`user-data.txt`, `meta-data.json`, `vendor-data.txt`).
* `/var/log/cloud-init.log`: Registro detallado de depuración de módulos de python internos.
* `/var/log/cloud-init-output.log`: stdout/stderr capturado de scripts de usuario y ejecuciones de `runcmd`.

### 2.4 Local Orchestration & Virtual Environments: HashiCorp Vagrant (Objective 353.4)

Vagrant proporciona un aprovisionamiento declarativo y reproducible de entornos de desarrollo envolviendo hipervisores subyacentes (Providers) y herramientas de configuración (Provisioners).

*   **Providers**: Capa de abstracción orientada a hipervisores (`libvirt` a través de KVM, `virtualbox`, `hyperv`, `docker`).
*   **Box Architecture**: Archivos de imagen de VM preempaquetados que contienen un SO base, metadatos específicos del proveedor (`metadata.json`) y archivos de disco (`box.img`, `vmdk`).
*   **Networking Abstractions**:
    *   `forwarded_port`: Mapea un puerto del host a un puerto del guest.
    *   `private_network`: Crea un puente host-only o una subred interna aislada con IP estática/DHCP.
    *   `public_network`: Conecta la NIC del host directamente en puente a la LAN externa.
*   **Synced Folders**: Monta directorios del host dentro del sistema de archivos del guest a través de 9P, NFS, RSync o VirtualBox Guest Additions.

### 2.5 Multi-Dimensional Architectural Trade-Off Matrix

| Dimension | Immutable Pre-Baking (Packer) | Early-Boot Injection (cloud-init) | Development Orchestration (Vagrant) | Enterprise Control Plane (OpenStack/Terraform) |
| :--- | :--- | :--- | :--- | :--- |
| **Primary Scope** | Creación de artefactos de imagen | Configuración en tiempo de ejecución de instancia única | Emulación local de sandbox multi-VM | Gestión IaaS multitenant global |
| **Execution Point** | Pipeline de build (CI/CD) | Primera fase de arranque del kernel guest | CLI de estación de trabajo de desarrollo | Reconciliación continua de estado |
| **State Management** | Ninguno (Artefacto de salida sin estado) | Efímero (`/var/lib/cloud/sem/`) | Estado local (`.vagrant/`) | Estado centralizado (`terraform.tfstate` / DB) |
| **Boot Latency Impact** | Sin penalización de arranque (preinstalado) | Agrega 5s – 120s al arranque inicial | N/A (demora de inicio local) | Rápido (orquesta la asignación de bloques) |
| **Idempotency** | N/A (Crea un binario inmutable) | Manejado por flags de systemd/cloud-init | Manejado por los provisioners subyacentes | Nativo mediante motor de estado de dependencias DAG |
| **Failure Domain** | Falla en el nodo de build de CI/CD | Congelamiento de arranque de VM individual / crash de cloud-init | Error de virtualización en la estación de trabajo del desarrollador | Interrupción del plano de control / límite de tasa de API |

---

## 3. Production-Grade Complete Manifests

### 3.1 Packer HCL2 Template: Hardened Ubuntu 22.04 QCOW2 Image

File: `ubuntu-2204-hardened.pkr.hcl`

```hcl
packer {
  required_version = ">= 1.9.0"
  required_plugins {
    qemu = {
      version = ">= 1.0.9"
      source  = "github.com/hashicorp/qemu"
    }
    ansible = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/ansible"
    }
  }
}

variable "iso_url" {
  type    = string
  default = "https://releases.ubuntu.com/22.04.4/ubuntu-22.04.4-live-server-amd64.iso"
}

variable "iso_checksum" {
  type    = string
  default = "sha256:45feac10bea4ea22740d8c586716c804e9543f63cf906d9b7780a388db65d456"
}

variable "output_dir" {
  type    = string
  default = "builds/ubuntu-2204-hardened"
}

source "qemu" "ubuntu_base" {
  iso_url          = var.iso_url
  iso_checksum     = var.iso_checksum
  output_directory = var.output_dir
  shutdown_command = "echo 'packer' | sudo -S shutdown -P now"
  disk_size        = "20480M"
  format           = "qcow2"
  accelerator      = "kvm"
  http_directory   = "http"
  ssh_username     = "cloudadmin"
  ssh_password     = "V3ryStr0ngP@ssw0rd!"
  ssh_timeout      = "20m"
  cpus             = 4
  memory           = 4096
  net_device       = "virtio-net-pci"
  disk_interface   = "virtio"
  headless         = true

  boot_wait = "5s"
  boot_command = [
    "<esc><wait>",
    "c<wait>",
    "linux /casper/vmlinuz --- autoinstall ds=nocloud-net;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ ",
    "<enter>",
    "initrd /casper/initrd",
    "<enter>",
    "boot",
    "<enter>"
  ]
}

build {
  name = "production-ubuntu-baker"
  sources = [
    "source.qemu.ubuntu_base"
  ]

  provisioner "shell" {
    inline = [
      "echo '==> Waiting for cloud-init to complete autoinstallation'",
      "sudo cloud-init status --wait",
      "echo '==> System update and package installation'",
      "sudo apt-get update && sudo apt-get install -y auditd libpam-pwquality curl htop",
      "echo '==> Cleaning SSH host keys'",
      "sudo rm -f /etc/ssh/ssh_host_*_key*",
      "echo '==> Purging cloud-init logs and runtime state'",
      "sudo cloud-init clean --logs --seed"
    ]
  }

  provisioner "file" {
    source      = "config/sysctl-security.conf"
    destination = "/tmp/99-security.conf"
  }

  provisioner "shell" {
    inline = [
      "sudo mv /tmp/99-security.conf /etc/sysctl.d/99-security.conf",
      "sudo chown root:root /etc/sysctl.d/99-security.conf",
      "sudo chmod 0644 /etc/sysctl.d/99-security.conf",
      "sudo sysctl -p /etc/sysctl.d/99-security.conf"
    ]
  }

  post-processor "compress" {
    output = "${var.output_dir}/ubuntu-2204-hardened.qcow2.tar.gz"
  }
}
```

---

### 3.2 Production cloud-init User-Data Configuration

File: `user-data`

```yaml
#cloud-config
autoinstall:
  version: 1
users:
  - name: sre-operator
    gecos: SRE Engine Admin
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: [sudo, docker]
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHxN9W8V3pP4YmL0q7xZ8K9nQ2rS1vT6wE3uI0oP5aR7 sre-deployer@enterprise.internal

package_update: true
package_upgrade: true
packages:
  - apt-transport-https
  - ca-certificates
  - curl
  - gnupg
  - lsb-release
  - iptables-persistent
  - net-tools

write_files:
  - path: /etc/sysctl.d/99-kubernetes-cri.conf
    permissions: '0644'
    owner: root:root
    content: |
      net.bridge.bridge-nf-call-iptables  = 1
      net.ipv4.ip_forward                 = 1
      net.bridge.bridge-nf-call-ip6tables = 1

  - path: /etc/modules-load.d/containerd.conf
    permissions: '0644'
    owner: root:root
    content: |
      overlay
      br_netfilter

  - path: /usr/local/bin/node-health-check.sh
    permissions: '0755'
    owner: root:root
    content: |
      #!/usr/bin/env bash
      set -euo pipefail
      echo "[HEALTH CHECK] Verifying node readiness at $(date -u)"
      ping -c 2 1.1.1.1 > /dev/null 2>&1 && echo "Network: UP" || echo "Network: DOWN"

runcmd:
  - [ modprobe, overlay ]
  - [ modprobe, br_netfilter ]
  - [ sysctl, --system ]
  - [ systemctl, daemon-reload ]
  - [ /usr/local/bin/node-health-check.sh ]

phone_home:
  url: https://telemetry.internal.infra/api/v1/boot-events
  post:
    - instance_id
    - hostname
    - pub_key_rsa
  tries: 5

final_message: "System initialization complete via cloud-init. Uptime: $uptime seconds"
```

---

### 3.3 Multi-Node Production Vagrant Environment (Libvirt Provider)

File: `Vagrantfile`

```ruby
# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|
  config.vagrant.plugins = ["vagrant-libvirt", "vagrant-env"]
  
  # Global Box Settings
  config.vm.box = "generic/ubuntu2204"
  config.vm.box_version = "4.3.12"

  # Disable default synced folder for performance & isolation
  config.vm.synced_folder ".", "/vagrant", disabled: true

  # ---------------------------------------------------------------------------
  # Control Plane Node
  # ---------------------------------------------------------------------------
  config.vm.define "k8s-control-01" do |node|
    node.vm.hostname = "k8s-control-01.infra.internal"
    
    node.vm.network "private_network",
      ip: "192.168.122.10",
      libvirt__network_name: "k8s-mgmt-net",
      libvirt__dhcp_enabled: false

    node.vm.synced_folder "./shared", "/mnt/shared",
      type: "nfs",
      nfs_version: 4,
      nfs_udp: false

    node.vm.provider :libvirt do |lv|
      lv.driver = "kvm"
      lv.memory = 4096
      lv.cpus = 4
      lv.machine_type = "q35"
      lv.cpu_mode = "host-passthrough"
      lv.nested = true
      lv.storage :file, size: "30G", type: "qcow2", bus: "virtio"
    end

    node.vm.provision "shell", inline: <<-SHELL
      set -euo pipefail
      echo "==> Configuring Control Plane Node Parameters"
      hostnamectl set-hostname k8s-control-01.infra.internal
      echo "192.168.122.10 k8s-control-01.infra.internal" >> /etc/hosts
      sysctl -w net.ipv4.ip_forward=1
    SHELL
  end

  # ---------------------------------------------------------------------------
  # Worker Node 01
  # ---------------------------------------------------------------------------
  config.vm.define "k8s-worker-01" do |node|
    node.vm.hostname = "k8s-worker-01.infra.internal"
    
    node.vm.network "private_network",
      ip: "192.168.122.21",
      libvirt__network_name: "k8s-mgmt-net",
      libvirt__dhcp_enabled: false

    node.vm.provider :libvirt do |lv|
      lv.driver = "kvm"
      lv.memory = 8192
      lv.cpus = 4
      lv.machine_type = "q35"
      lv.cpu_mode = "host-passthrough"
      lv.storage :file, size: "50G", type: "qcow2", bus: "virtio"
    end

    node.vm.provision "shell", path: "scripts/bootstrap-worker.sh"
  end
end
```

---

### 3.4 OpenStack Infrastructure Provisioning via Terraform

File: `main.tf`

```hcl
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 1.52.0"
    }
  }
}

provider "openstack" {
  cloud = "openstack-prod-datacenter"
}

variable "instance_count" {
  type    = number
  default = 2
}

resource "openstack_compute_keypair_v2" "sre_key" {
  name       = "sre-ops-key"
  public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHxN9W8V3pP4YmL0q7xZ8K9nQ2rS1vT6wE3uI0oP5aR7 sre-deployer@enterprise.internal"
}

resource "openstack_networking_network_v2" "internal_net" {
  name           = "production-internal-net"
  admin_state_up = true
}

resource "openstack_networking_subnet_v2" "internal_subnet" {
  name            = "production-internal-subnet"
  network_id      = openstack_networking_network_v2.internal_net.id
  cidr            = "10.240.0.0/24"
  ip_version      = 4
  dns_nameservers = ["10.240.0.2", "1.1.1.1"]
}

resource "openstack_compute_instance_v2" "app_node" {
  count           = var.instance_count
  name            = "prod-app-server-0${count.index + 1}"
  image_name      = "ubuntu-2204-hardened-golden"
  flavor_name     = "m1.large"
  key_pair        = openstack_compute_keypair_v2.sre_key.name
  security_groups = ["default", "secgroup-web-prod"]

  user_data = file("${path.module}/user-data")

  network {
    uuid = openstack_networking_network_v2.internal_net.id
  }

  metadata = {
    environment = "production"
    managed_by  = "terraform"
    owner       = "platform-sre"
  }
}

output "instance_ips" {
  description = "Internal IPv4 addresses of spawned instances"
  value       = openstack_compute_instance_v2.app_node[*].access_ip_v4
}
```

---

## 4. Real-World Terminal Sessions & CLI Operations ($)

### 4.1 HashiCorp Packer Operations

Validar la sintaxis de la plantilla, la integridad de las variables y el formato HCL:

```bash
$ packer fmt ubuntu-2204-hardened.pkr.hcl
ubuntu-2204-hardened.pkr.hcl

$ packer validate -var "iso_checksum=sha256:45feac10bea4ea22740d8c586716c804e9543f63cf906d9b7780a388db65d456" ubuntu-2204-hardened.pkr.hcl
The configuration is valid.
```

Ejecutar el pipeline de construcción de imagen utilizando QEMU/KVM:

```bash
$ packer build ubuntu-2204-hardened.pkr.hcl
qemu.ubuntu_base: output will be in this directory: builds/ubuntu-2204-hardened
==> qemu.ubuntu_base: Downloading ISO...
    qemu.ubuntu_base: Downloading ISO: https://releases.ubuntu.com/22.04.4/ubuntu-22.04.4-live-server-amd64.iso
==> qemu.ubuntu_base: Starting HTTP server on port 8542
==> qemu.ubuntu_base: Found port for VNC: 5912
==> qemu.ubuntu_base: Launching VM via QEMU...
    qemu.ubuntu_base: QEMU command: qemu-system-x86_64 -machine type=pc,accel=kvm -name packer-ubuntu_base -m 4096M -smp 4 -drive file=builds/ubuntu-2204-hardened/packer-ubuntu_base,if=virtio,cache=writeback,discard=ignore,format=qcow2 -boot once=d -cdrom /home/sre/.cache/packer/45feac10bea4ea22740d8c586716c804e9543f63cf906d9b7780a388db65d456.iso -netdev user,id=user.0,hostfwd=tcp::2222-:22 -device virtio-net-pci,netdev=user.0
==> qemu.ubuntu_base: Waiting 5s for boot...
==> qemu.ubuntu_base: Typing the boot command over VNC...
==> qemu.ubuntu_base: Waiting for SSH to become available...
    qemu.ubuntu_base: Connected to SSH!
==> qemu.ubuntu_base: Provisioning with shell script...
    qemu.ubuntu_base: ==> Waiting for cloud-init to complete autoinstallation
    qemu.ubuntu_base: status: done
    qemu.ubuntu_base: ==> System update and package installation
    qemu.ubuntu_base: Reading package lists... Done
    qemu.ubuntu_base: Building dependency tree... Done
    qemu.ubuntu_base: ==> Cleaning SSH host keys
    qemu.ubuntu_base: ==> Purging cloud-init logs and runtime state
==> qemu.ubuntu_base: Running post-processor: compress
    qemu.ubuntu_base (compress): Archiving builds/ubuntu-2204-hardened/packer-ubuntu_base with factor 9 to builds/ubuntu-2204-hardened/ubuntu-2204-hardened.qcow2.tar.gz
Build 'qemu.ubuntu_base' finished after 7 minutes 34 seconds.

==> Builds finished. The artifacts of successful builds are:
--> qemu.ubuntu_base: VM files in directory: builds/ubuntu-2204-hardened
```

---

### 4.2 cloud-init Runtime Inspection & Lifecycle Debugging

Verificar el estado y los detalles de ejecución en una instancia de nube en ejecución:

```bash
$ cloud-init status --long
status: done
extended_status: done
boot_status_code: enabled-by-generator
detail: DataSourceNoCloud [seed=/dev/sr0][boot=live/boot]
recovered: null
```

Analizar métricas de rendimiento de la etapa de arranque para detectar módulos de aprovisionamiento lentos:

```bash
$ cloud-init analyze show
-- Boot Record 01 --
stage: init-local
  start: 16:50:01.102341
  end:   16:50:02.405112
  total: 1.302771 s
stage: init
  start: 16:50:02.410190
  end:   16:50:04.912401
  total: 2.502211 s
stage: modules-config
  start: 16:50:05.100192
  end:   16:50:07.892019
  total: 2.791827 s
stage: modules-final
  start: 16:50:08.102911
  end:   16:50:18.510921
  total: 10.408010 s
Total Time: 17.004819 s
```

Identificar las tareas de cloud-init más lentas mediante la herramienta blamer:

```bash
$ cloud-init analyze blamer
10.120s (modules-final) runcmd
 2.105s (modules-config) package_config
 1.250s (init) ssh-import-id
 0.850s (modules-config) write_files
 0.410s (init-local) net-config
```

Ejecutar un solo módulo de cloud-init de forma aislada para depuración específica:

```bash
$ sudo cloud-init single --name write_files --frequency always
Cloud-init v. 23.4.2-0ubuntu1~22.04.1 running 'single' at Thu, 06 Aug 2026 16:52:10 +0000. Up 120.45 seconds.
[CLOUD-INIT] Stage Single: write_files module executed successfully.
```

---

### 4.3 HashiCorp Vagrant Lifecycle Operations

Listar los plugins instalados e inicializar la arquitectura libvirt multinodo:

```bash
$ vagrant plugin list
vagrant-env (0.0.5, global)
vagrant-libvirt (0.12.2, global)

$ vagrant up --provider=libvirt
Bringing machine 'k8s-control-01' up with 'libvirt' provider...
Bringing machine 'k8s-worker-01' up with 'libvirt' provider...
==> k8s-control-01: Creating image (snapshot of base box)...
==> k8s-control-01: Creating domain with the following settings...
==> k8s-control-01:  -- Name:              infra_k8s-control-01
==> k8s-control-01:  -- Domain type:       kvm
==> k8s-control-01:  -- Cpus:              4
==> k8s-control-01:  -- Memory:            4096MB
==> k8s-control-01:  -- Architecture:      x86_64
==> k8s-control-01:  -- Machine type:       q35
==> k8s-control-01:  -- CPU Mode:          host-passthrough
==> k8s-control-01:  -- Storage:           30G (qcow2)
==> k8s-control-01: Starting domain.
==> k8s-control-01: Waiting for domain to get an IP address...
==> k8s-control-01: Waiting for SSH to become available...
    k8s-control-01: SSH address: 192.168.122.10:22
    k8s-control-01: SSH username: vagrant
    k8s-control-01: SSH key insertion: enabled
==> k8s-control-01: Setting hostname...
==> k8s-control-01: Configuring and enabling network interfaces...
==> k8s-control-01: Exporting NFS shared folders...
==> k8s-control-01: Mounting NFS shared folders...
==> k8s-control-01: Running provisioner: shell...
    k8s-control-01: ==> Configuring Control Plane Node Parameters
```

Consultar el estado actual de las VMs en el entorno de Vagrant:

```bash
$ vagrant status
Current machine states:

k8s-control-01            running (libvirt)
k8s-worker-01             running (libvirt)

This environment represents multiple VMs. The VMs are all running.
To shut down a VM, run `vagrant halt <name>`.
```

Inspeccionar la ejecución en el guest a través de SSH sin asignación de TTY interactiva:

```bash
$ vagrant ssh k8s-control-01 -c "ip -4 a show dev eth1"
3: eth1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP group default qlen 1000
    inet 192.168.122.10/24 brd 192.168.122.255 scope global eth1
       valid_lft forever preferred_lft forever
```

---

### 4.4 Cloud Control Plane Verification (Terraform & OpenStack CLI)

Aplicar el plan de ejecución de Terraform contra el fabric de la nube OpenStack:

```bash
$ terraform plan -out=tfplan.binary
OpenStack Provider: Authenticating to Keystone at https://identity.cloud.internal:5000/v3
openstack_networking_network_v2.internal_net: Refreshing state...

Terraform will perform the following actions:

  # openstack_compute_instance_v2.app_node[0] will be created
  + resource "openstack_compute_instance_v2" "app_node" {
      + access_ip_v4    = (known after apply)
      + flavor_name     = "m1.large"
      + id              = (known after apply)
      + image_name      = "ubuntu-2204-hardened-golden"
      + key_pair        = "sre-ops-key"
      + name            = "prod-app-server-01"
      + security_groups = [
          + "default",
          + "secgroup-web-prod",
        ]
      + user_data       = "83f628c6e26210fdf48074d284a1e944b2049e29"
    }

Plan: 3 to add, 0 to change, 0 to destroy.

$ terraform apply "tfplan.binary"
openstack_networking_network_v2.internal_net: Creating...
openstack_networking_network_v2.internal_net: Creation complete after 2s [id=3e89fa12-8812-4c22-b912-812049a81234]
openstack_compute_instance_v2.app_node[0]: Creating...
openstack_compute_instance_v2.app_node[0]: Still creating... [10s elapsed]
openstack_compute_instance_v2.app_node[0]: Creation complete after 14s [id=a980b123-512a-4112-9c12-001294812491]

Apply complete! Resources: 2 added, 0 changed, 0 destroyed.

Outputs:

instance_ips = [
  "10.240.0.14",
  "10.240.0.15",
]
```

Inspeccionar instancias de cómputo directamente utilizando la CLI de OpenStack:

```bash
$ openstack server list --long -c Name -c Status -c Task\ State -c Power\ State -c Networks
+-------------------+--------+------------+-------------+-------------------------+
| Name              | Status | Task State | Power State | Networks                |
+-------------------+--------+------------+-------------+-------------------------+
| prod-app-server-01| ACTIVE | None       | Running     | production-net=10.240.0.14 |
| prod-app-server-02| ACTIVE | None       | Running     | production-net=10.240.0.15 |
+-------------------+--------+------------+-------------+-------------------------+
```

---

## 5. Verification and Failure Diagnostics Guide

### 5.1 Diagnostic Scenario A: cloud-init Silent Failure & Invalid User-Data YAML

#### Failure Symptom
Una máquina virtual arranca, pero faltan los usuarios personalizados, los paquetes especificados en `user-data` no se instalan y la clave pública SSH del SRE es rechazada.

#### Root Cause Analysis Workflow
1. Iniciar sesión en la VM guest mediante la consola serie de emergencia o credenciales de respaldo del hipervisor (`virsh console` o VNC).
2. Verificar el estado de error de `cloud-init`:

```bash
$ sudo cloud-init status --long
status: error
extended_status: error
detail: YAMLError: while parsing a block mapping in "<string>", line 12, column 3
```

3. Localizar e inspeccionar la caché de user-data recibida por el guest:

```bash
$ cat /var/lib/cloud/instance/user-data.txt
```

4. Validar la sintaxis contra el analizador de esquemas:

```bash
$ sudo cloud-init schema --config-file /var/lib/cloud/instance/user-data.txt
Validating /var/lib/cloud/instance/user-data.txt
Cloud config schema errors: line 12, column 3: key 'packages' expected list, got string.
FAIL: Invalid cloud-config schema
```

5. Leer los registros de ejecución principales para identificar el traceback de Python con errores:

```bash
$ grep -E "(ERROR|WARNING|Traceback)" /var/log/cloud-init.log
2026-08-06 16:55:01,120 - cc_write_files.py[ERROR]: Failed writing file to /etc/sysctl.d/99-custom.conf: IOError(13, 'Permission denied')
2026-08-06 16:55:02,401 - util.py[WARNING]: Failed running /var/lib/cloud/instance/scripts/runcmd-1 [-127]
```

#### Remediation Protocol
Corregir el error de sintaxis YAML en el repositorio de origen. Para volver a activar la ejecución de `cloud-init` en una VM existente sin destruirla:

```bash
$ sudo cloud-init clean --logs --reboot
```

---

### 5.2 Diagnostic Scenario B: Packer QEMU VNC Boot Command Timeout

#### Failure Symptom
La construcción de Packer se cuelga indefinidamente en `Waiting for SSH to become available...` y eventualmente termina con un error de tiempo de espera de conexión SSH.

```
==> qemu.ubuntu_base: Waiting for SSH to become available...
==> qemu.ubuntu_base: Timeout waiting for SSH.
==> qemu.ubuntu_base: Deleting output directory...
Build 'qemu.ubuntu_base' errored: Timeout waiting for SSH.
```

#### Root Cause Analysis Workflow
1. Desactivar temporalmente `headless = true` en `ubuntu-2204-hardened.pkr.hcl` o conectar un cliente VNC para inspeccionar la pantalla del instalador:

```bash
$ vncviewer 127.0.0.1:5912
```

2. Observar el estado del instalador: El menú de GRUB se cuelga en `Booting 'Install Ubuntu Server'`. La cadena de `boot_command` fue escrita prematuramente antes de que GRUB aceptara la entrada.
3. Verificar la salida del registro del servidor HTTP local de Packer. Asegurarse de que el firewall del host (iptables/ufw) no esté bloqueando a QEMU para alcanzar `http://{{ .HTTPIP }}:{{ .HTTPPort }}`.

```bash
$ sudo iptables -L INPUT -v -n | grep 8542
# If missing, traffic from virtio-net adapter to host is dropped.
```

#### Remediation Protocol
* Ajustar `boot_wait` en la plantilla de Packer de `5s` a `10s` o agregar etiquetas `<wait10>` antes de arrancar las opciones del kernel.
* Permitir el tráfico local en el puente de construcción de packer:

```bash
$ sudo iptables -A INPUT -i virbr0 -p tcp --dport 8500:9000 -j ACCEPT
```

---

### 5.3 Diagnostic Scenario C: Vagrant Libvirt Bridge Driver Collision & Permission Failure

#### Failure Symptom
Ejecutar `vagrant up --provider=libvirt` falla durante la inicialización del dominio con un error del pool de almacenamiento o del Network Filter Driver.

```
Call to virDomainCreateWithFlags failed: Storage pool not found: no storage pool with matching name 'default'
```
OR:
```
libvirt: Network Filter Driver Error: virError(Code=38, Domain=18, message='Building filter rules failed')
```

#### Root Cause Analysis Workflow
1. Verificar el estado del demonio de systemd `libvirtd` y la conectividad del socket:

```bash
$ systemctl status libvirtd
$ virsh pool-list --all
 Name                 State      Autostart
-------------------------------------------
 (no storage pools defined)
```

2. Verificar si el usuario actual pertenece a los grupos de sistema `libvirt` y `kvm`:

```bash
$ id -nG | grep -E "(libvirt|kvm)"
# If blank, permission is denied to access /dev/kvm and /var/run/libvirt/libvirt-sock
```

3. Inspeccionar los eventos de denegación de AppArmor / SELinux:

```bash
$ sudo ausearch -m avc -ts recent | grep virt
type=AVC msg=audit(1722963490.102:412): apparmor="DENIED" operation="open" profile="virt-aa-helper" name="/home/sre/builds/box.img" comm="virt-aa-helper" requested_mask="r" denied_mask="r"
```

#### Remediation Protocol
1. Agregar el operador a los grupos de gestión de hipervisores requeridos:

```bash
$ sudo usermod -aG libvirt,kvm $USER
$ newgrp libvirt
```

2. Definir y activar el pool de almacenamiento predeterminado de libvirt:

```bash
$ virsh pool-define-as default dir --target /var/lib/libvirt/images
Pool default defined

$ virsh pool-start default
Pool default started

$ virsh pool-autostart default
Pool default marked as autostarted
```

3. Verificar que la aceleración de hardware KVM esté disponible:

```bash
$ kvm-ok
INFO: /dev/kvm exists
KVM acceleration can be used
```

---

## 6. References

*   **LPI Official LPIC-3 305 Overview & Objectives**: [https://www.lpi.org/our-certifications/lpic-3-305-overview/](https://www.lpi.org/our-certifications/lpic-3-305-overview/)
*   **Canonical cloud-init Official Documentation**: [https://cloudinit.readthedocs.io/en/latest/](https://cloudinit.readthedocs.io/en/latest/)
*   **HashiCorp Packer QEMU Builder Specification**: [https://developer.hashicorp.com/packer/integrations/hashicorp/qemu](https://developer.hashicorp.com/packer/integrations/hashicorp/qemu)
*   **HashiCorp Vagrant Libvirt Provider Documentation**: [https://vagrant-libvirt.github.io/vagrant-libvirt/](https://vagrant-libvirt.github.io/vagrant-libvirt/)
*   **OpenStack Compute (Nova) Architecture Documentation**: [https://docs.openstack.org/nova/latest/](https://docs.openstack.org/nova/latest/)
*   **Terraform OpenStack Provider Reference**: [https://registry.terraform.io/providers/terraform-provider-openstack/openstack/latest/docs](https://registry.terraform.io/providers/terraform-provider-openstack/openstack/latest/docs)
*   **Linux Foundation / CNCF Infrastructure Automation Practices**: [https://www.cncf.io/reports/](https://www.cncf.io/reports/)