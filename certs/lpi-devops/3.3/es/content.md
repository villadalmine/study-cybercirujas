# LPI DevOps Tools Engineer (Exam 701-100) | Topic 3.3: Creación de Imágenes de Sistema

## 1. Motivación y Problema Arquitectónico en Producción

### 1.1 El Anti-Patrón Empresarial: Configuration Drift y Aprovisionamiento en Tiempo de Arranque
En entornos empresariales cloud-native de alta disponibilidad, la dependencia en infraestructura mutable y la gestión de configuración en tiempo de arranque (por ejemplo, ejecutando scripts de shell sin procesar o roles pesados de gestión de configuración dentro de `cloud-init` al lanzar la instancia) introduce tres modos de falla críticos:

1. **Latencia de Autoscaling y Violaciones de SLA:** Ejecutar la instalación dinámica de paquetes (`apt-get update && apt-get install`), resolución de dependencias, compilación y hardening de seguridad en una máquina virtual (VM) o instancia Cloud recién lanzada puede tomar entre 8 y 15 minutos. Durante picos repentinos de tráfico, un Elastic Load Balancer (ELB) o Autoscaling Group (ASG) no logrará escalar horizontalmente a tiempo para absorber la carga, lo que lleva a una latencia elevada, saturación de colas y HTTP 504 Gateway Timeouts.
2. **Builds No Deterministas y Vulnerabilidades en la Cadena de Suministro:** Depender de repositorios de paquetes externos, mirrors de distribución u hosts de artefactos de terceros durante la inicialización de la instancia crea entornos de ejecución no deterministas. Si un repositorio upstream actualiza una versión menor de un paquete, altera una clave de firma GPG o sufre una interrupción, las instancias recién lanzadas divergirán de los nodos existentes de la flota (Configuration Drift) o fallarán al arrancar por completo, rompiendo la homogeneidad de la flota.
3. **Radio de Impacto (Blast Radius) Elevado Durante Interrupciones:** Cuando un ASG reemplaza nodos no saludables durante un incidente, cualquier particionamiento de red transitorio o limitación de tasa (rate-limiting) de un mirror de terceros evita la finalización del arranque, convirtiendo una degradación localizada del nodo en una falla de servicio catastrófica.

```
Mutable Boot-Time Provisioning (Anti-Pattern):
[ ASG Trigger ] ──► [ Launch Raw Instance ] ──► [ Cloud-Init ] ──► [ Apt Update/Install ] ──► [ Run Ansible ] ──► [ Ready (8-15 min) ]
                                                                             │                       │
                                                                             ▼                       ▼
                                                                     [ Mirror Outage ]       [ Dependency Drift ]
                                                                       (Boot Failure)         (Inconsistent Fleet)

Immutable Golden Image Architecture (Production Target):
[ ASG Trigger ] ──► [ Launch Pre-Baked AMI ] ──► [ Mount Storage / Runtime Secrets ] ──► [ Ready (< 45 sec) ]
```

### 1.2 El Paradigma de Infraestructura Inmutable
Para resolver estos cuellos de botella arquitectónicos, los equipos de SRE y Platform Engineering adoptan el paradigma de **Infraestructura Inmutable** utilizando herramientas de pre-baking de imágenes de sistema como **HashiCorp Packer**. 

En un flujo de trabajo inmutable:
- Las imágenes de sistema (AMIs, archivos QCOW2, VHDs, imágenes de contenedor) se construyen, aprovisionan completamente, parchean, escanean en busca de vulnerabilidades y se hornean (bake) fuera de línea dentro de un pipeline de CI/CD antes del despliegue.
- Las instancias desplegadas se tratan como artefactos efímeros. Las actualizaciones de configuración, parches de kernel o despliegues de código de aplicación no se ejecutan modificando las instancias en ejecución in-place, sino instanciando nuevas instancias de máquinas virtuales a partir de Golden Images actualizadas y terminando los nodos antiguos de forma gradual (gracefully).

### 1.3 Mecánica Interna de la Creación Automatizada de Imágenes de Sistema
Herramientas como HashiCorp Packer abstraen los hipervisores y controladores de virtualización de los proveedores de nube para generar imágenes de sistema idénticas en múltiples plataformas de destino (AWS EBS, QEMU/KVM, VMware vSphere, VirtualBox, Docker).

La mecánica de bajo nivel de una build de imagen automatizada involucra cinco fases discretas:

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│                                PACKER ENGINE EXECUTOR                                    │
└──────────────────────────────────────────────────────────────────────────────────────────┘
           │
           ├── 1. INFRASTRUCTURE PROVISIONING (Builder)
           │      └── Provision temporary hypervisor resource (EC2 Instance / QEMU VM / Docker Container)
           │      └── Create ephemeral SSH/WinRM key pairs & security rules
           │
           ├── 2. TRANSPORT INTEGRATION
           │      └── Establish secure remote control tunnel (SSH / WinRM / Docker Exec)
           │
           ├── 3. PROVISIONING EXECUTION
           │      └── Inject files, execute shell scripts, configuration management (Ansible/Chef)
           │      └── Apply OS hardening, CIS benchmarks, and artifact cleanup
           │
           ├── 4. HYPERVISOR SNAPSHOTTING & RATIONING
           │      └── Stop provisioning target cleanly
           │      └── Issue hypervisor block-level snapshot call (e.g., EBS CreateSnapshot)
           │      └── Register target machine image (AMI / QCOW2 registration)
           │
           └── 5. RESOURCE SANITIZATION
                  └── Terminate ephemeral instance, security groups, and temporary key pairs
```

---

## 2. Comparaciones Técnicas y Matrices de Trade-offs

### 2.1 Matriz de Trade-offs Arquitectónicos de Estrategias de Imágenes

| Métrica / Dimensión | Golden Image (Pre-Baked) | Aprovisionamiento Dinámico (Solo Cloud-Init) | Híbrido (Base Horneada + Config de App en Arranque) |
| :--- | :--- | :--- | :--- |
| **Tiempo de Boot-to-Ready** | Extremadamente Bajo (< 45 segundos) | Alto (8–15 minutos) | Moderado (1–3 minutos) |
| **Homogeneidad de la Flota** | 100% Determinista | Baja (Vulnerable al drift de mirrors de paquetes) | Alta para el SO, Moderada para la capa de App |
| **Complejidad del Pipeline CI/CD** | Alta (Requiere pipelines automatizados de build de imágenes) | Baja (Solo requiere despliegue de cloud-config) | Moderada |
| **Velocidad de Parcheo de Vulnerabilidades** | Requiere horneado completo de imagen y reemplazo gradual | Aplicado instantáneamente en el lanzamiento de nuevas instancias | SO base pre-horneado; App parcheada al arrancar |
| **Costo de Almacenamiento y Registro** | Más alto (Se almacenan múltiples snapshots de imágenes grandes) | Mínimo (Se usan imágenes de distribución base) | Moderado |
| **Perfil de Riesgo en Producción** | Bajo (Vulnerabilidades detectadas durante el escaneo de la imagen) | Alto (Fallas de arranque durante la recuperación de incidentes) | Bajo-Moderado |

### 2.2 Comparación de Controladores Builder de HashiCorp Packer

| Controlador Builder | Hipervisor / API Subyacente | Artefacto de Salida Destino | Caso de Uso de Producción Destino | Rendimiento / Overhead de Build |
| :--- | :--- | :--- | :--- | :--- |
| `amazon-ebs` | API de AWS EC2 y Motor de Snapshots EBS | Amazon Machine Image (AMI) | Cargas de trabajo Cloud Native en AWS (ASG, Nodos EKS) | Limitado por red de API Cloud (~5-10 min) |
| `qemu` | Emulación de Hardware KVM / QEMU | Imagen de Bloque QCOW2 / RAW | OpenStack, Proxmox, Virtualización Bare-Metal | Limitado por CPU/Disk IO en el host de build |
| `virtualbox-iso` | Hipervisor VirtualBox | Paquete OVA / OVF | Entorno de Desarrollador Local (Vagrant Boxes) | Alto overhead local de CPU/RAM |
| `docker` | Motor Docker / Containerd | Manifiesto de Imagen de Contenedor | Microservicios Contenedorizados y Kubernetes | Extremadamente rápido (Soporta almacenamiento en caché de capas) |

### 2.3 Comparación de Estrategias de Ejecución de Provisioners

| Tipo de Provisioner | Mecánica Interna | Prerrequisitos de Dependencias | Caso de Uso Ideal | Impacto en Seguridad |
| :--- | :--- | :--- | :--- | :--- |
| `shell` | Transporta scripts inline o archivos bash a través del stream SSH/WinRM | Ninguno (POSIX shell estándar) | Bootstrap del SO, creación de directorios, limpieza final de artefactos | Baja superficie de ataque; requiere disciplina de idempotencia en shell |
| `ansible-local` | Carga Ansible Playbooks y ejecuta `ansible-playbook` en el destino | Python y Ansible instalados en la VM builder temporal | Reutilización de gestión de configuración empresarial | Requiere instalación temporal de Ansible (debe purgarse durante la limpieza) |
| `file` | Carga artefactos binarios locales o configuraciones mediante SFTP/SCP | Conexión SSH/WinRM válida | Inyección de binarios precompilados, unidades de systemd, certificados | Rápido; sin overhead de ejecución en la máquina destino |

---

## 3. Infraestructura y Manifiestos de Producción

### 3.1 Plantilla HCL2 de HashiCorp Packer para Producción (`ubuntu-hardened.pkr.hcl`)
Esta plantilla HCL2 completa y sintácticamente válida aprovisiona una AMI de AWS cifrada y con hardening de seguridad basada en Ubuntu 22.04 LTS. Integra el builder de AWS EBS, cargadores de archivos locales, provisioners de ejecución de shell y un post-procesador de manifiesto de artefactos.

```hcl
packer {
  required_version = ">= 1.9.0"
  required_plugins {
    amazon = {
      version = ">= 1.2.8"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  type    = string
  default = "production"
}

variable "app_version" {
  type    = string
  default = "1.0.0"
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

source "amazon-ebs" "ubuntu-hardened" {
  ami_name                    = "golden-ubuntu-22.04-amd64-${var.app_version}-build-${formatdate("YYYYMMDDhhmmss", timestamp())}"
  instance_type               = var.instance_type
  region                      = var.aws_region
  encrypt_boot                = true
  kms_key_id                  = "alias/aws/ebs"
  associate_public_ip_address = true

  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["099720109477"] # Canonical Official AWS Account ID
  }

  ssh_username = "ubuntu"
  ssh_timeout  = "10m"

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 20
    volume_type           = "gp3"
    iops                  = 3000
    throughput            = 125
    delete_on_termination = true
    encrypted             = true
  }

  tags = {
    Name          = "Golden-Ubuntu-22.04-AMI"
    Environment   = var.environment
    AppVersion    = var.app_version
    ManagedBy     = "Packer"
    BaseOS        = "Ubuntu-22.04"
    CreationDate  = formatdate("YYYY-MM-DD", timestamp())
  }
}

build {
  name = "production-ami-builder"
  sources = [
    "source.amazon-ebs.ubuntu-hardened"
  ]

  # Provisioner 1: Stage production configuration files
  provisioner "file" {
    source      = "files/limits.conf"
    destination = "/tmp/limits.conf"
  }

  # Provisioner 2: Base System Setup and Security Hardening
  provisioner "shell" {
    inline = [
      "echo '==> Waiting for cloud-init to complete process lock...'",
      "cloud-init status --wait",
      "echo '==> Applying OS updates...'",
      "sudo apt-get update -y",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y auditd fail2ban curl jq unzip systemd-journal-remote",
      "sudo mv /tmp/limits.conf /etc/security/limits.d/99-realtime-limits.conf",
      "sudo chown root:root /etc/security/limits.d/99-realtime-limits.conf",
      "sudo chmod 0644 /etc/security/limits.d/99-realtime-limits.conf"
    ]
  }

  # Provisioner 3: Execute Production Hardening & Machine Sanitization Script
  provisioner "shell" {
    script          = "scripts/cleanup.sh"
    execute_command = "sudo -S sh -c '{{ .Vars }} {{ .Path }}'"
  }

  # Post-Processor: Output Build Metadata for CI/CD Pipeline Consumption
  post-processor "manifest" {
    output     = "packer-manifest.json"
    strip_path = true
    custom_data = {
      build_environment = var.environment
      application_ver   = var.app_version
    }
  }
}
```

---

### 3.2 Script de Sanitización del Sistema y Hardening de Imagen para Producción (`scripts/cleanup.sh`)
Este script de shell se ejecuta como el paso final del provisioner. Elimina las firmas de identidad de la instancia (claves de host, `/etc/machine-id`, estado de cloud-init) y llena con ceros los sectores de disco vacíos para permitir la compresión de volúmenes dispersos (sparse volumes) y prevenir fugas de identidad de seguridad en las instancias clonadas a partir de la imagen.

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "========================================================="
echo " STARTING PRODUCTION IMAGE HARDENING & SANITIZATION"
echo "========================================================="

# 1. Stop Logging and Monitoring Services
echo "==> Stopping syslog and audit daemons..."
systemctl stop auditd || true
systemctl stop rsyslog || true

# 2. Remove Ephemeral SSH Host Keys (Must be regenerated on first boot by cloud-init)
echo "==> Purging existing SSH host key pairs..."
rm -f /etc/ssh/ssh_host_*

# 3. Reset Machine-ID (Crucial to prevent DHCP IP collision & duplicate journald IDs)
echo "==> Resetting /etc/machine-id..."
truncate -s 0 /etc/machine-id
if [ -f /var/lib/dbus/machine-id ]; then
    rm -f /var/lib/dbus/machine-id
    ln -s /etc/machine-id /var/lib/dbus/machine-id
fi

# 4. Clean Cloud-Init Execution State & Artifact Logs
echo "==> Cleaning cloud-init cache and log artifacts..."
cloud-init clean --logs --seed

# 5. Purge Package Manager Cache and Temporary Files
echo "==> Cleaning APT package manager cache..."
apt-get autoremove --purge -y
apt-get clean -y
rm -rf /var/lib/apt/lists/*
rm -rf /tmp/* /var/tmp/*

# 6. Purge Shell History & User Logs
echo "==> Clearing system logs and user history files..."
find /var/log -type f -exec truncate -s 0 {} \;
rm -f /root/.bash_history
rm -f /home/ubuntu/.bash_history
rm -rf /root/.ssh/authorized_keys
rm -rf /home/ubuntu/.ssh/authorized_keys

# 7. Fill Free Storage Sectors with Zeroes to Maximize EBS Compression
echo "==> Zeroing out empty disk sectors..."
dd if=/dev/zero of=/EMPTY bs=1M status=progress || true
sync
rm -f /EMPTY
sync

echo "========================================================="
echo " SANITIZATION COMPLETE - IMAGE READY FOR SNAPSHOT"
echo "========================================================="
```

---

### 3.3 Manifiesto User-Data de Cloud-Init para Producción (`cloud-config.yaml`)
Al lanzar una instancia de VM desde la Golden Image horneada, cloud-init procesa este manifiesto declarativo de user-data `#cloud-config` para establecer parámetros específicos de la instancia (hostname, claves SSH, configuración dinámica de systemd) sin modificar los binarios del sistema.

```yaml
#cloud-config
version: v1
hostname: node-prod-app-01
fqdn: node-prod-app-01.internal.net
manage_etc_hosts: true

users:
  - name: sysadmin
    gecos: System Administrator
    groups: sudo, systemd-journal
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCz7x71a2B... sysadmin@ops

package_update: false
package_upgrade: false

write_files:
  - path: /etc/sysctl.d/99-production-tuning.conf
    permissions: '0644'
    owner: root:root
    content: |
      net.core.somaxconn = 65535
      net.ipv4.tcp_max_syn_backlog = 8192
      vm.max_map_count = 262144

  - path: /etc/systemd/system/app-exporter.service
    permissions: '0644'
    owner: root:root
    content: |
      [Unit]
      Description=Production Node Exporter
      After=network.target

      [Service]
      Type=simple
      ExecStart=/usr/local/bin/node_exporter
      Restart=always
      RestartSec=5s

      [Install]
      WantedBy=multi-user.target

runcmd:
  - sysctl --system
  - systemctl daemon-reload
  - systemctl enable --now app-exporter.service
  - [ ssh-keygen, -A ]  # Regenerate SSH Host Keys on First Boot
  - systemctl restart ssh
```

---

## 4. Comandos de CLI Reales y Salidas Esperadas de Terminal

### 4.1 Paso 1: Inicializar Plugins y Validar la Sintaxis de Packer
Ejecute `packer init` para descargar los plugins de proveedor requeridos, seguido de `packer fmt` y `packer validate` para verificar la sintaxis HCL y las credenciales de la API del proveedor de nube.

```bash
$ packer init ubuntu-hardened.pkr.hcl
Installed plugin github.com/hashicorp/amazon v1.2.8 in "/home/sre-user/.packer.d/plugins/github.com/hashicorp/amazon/packer-plugin-amazon_v1.2.8_x5.0_linux_amd64"

$ packer fmt -check ubuntu-hardened.pkr.hcl
ubuntu-hardened.pkr.hcl

$ packer validate -var="app_version=2.4.1" -var="aws_region=us-east-1" ubuntu-hardened.pkr.hcl
The configuration is valid.
```

---

### 4.2 Paso 2: Ejecutar el Pipeline de Build de Packer
Ejecute el proceso de construcción de la imagen. Packer muestra en vivo los pasos de ejecución, incluyendo la creación de la instancia, el aprovisionamiento sobre SSH, la creación de snapshots, el registro y la limpieza.

```bash
$ packer build -var="app_version=2.4.1" -var="aws_region=us-east-1" ubuntu-hardened.pkr.hcl
amazon-ebs.ubuntu-hardened: output will be in this color.

==> amazon-ebs.ubuntu-hardened: Prevalidated AMI Name: golden-ubuntu-22.04-amd64-2.4.1-build-20260807123000
    amazon-ebs.ubuntu-hardened: Found AMI: ami-0c7217cdde317cfec
==> amazon-ebs.ubuntu-hardened: Creating temporary keypair: packer_66b36488-82a1-039c-502a-9f5b24479e0f
==> amazon-ebs.ubuntu-hardened: Creating temporary security group for packer...
==> amazon-ebs.ubuntu-hardened: Authorizing access to port 22 the temporary security group...
==> amazon-ebs.ubuntu-hardened: Launching a source AWS instance...
    amazon-ebs.ubuntu-hardened: Instance ID: i-0a91f4e8bc12a45d0
==> amazon-ebs.ubuntu-hardened: Waiting for instance (i-0a91f4e8bc12a45d0) to become ready...
==> amazon-ebs.ubuntu-hardened: Using SSH communicator to connect: 54.210.12.84
==> amazon-ebs.ubuntu-hardened: Waiting for SSH to become available...
==> amazon-ebs.ubuntu-hardened: Connected to SSH!
==> amazon-ebs.ubuntu-hardened: Uploading files/limits.conf -> /tmp/limits.conf
files/limits.conf 48B / 48B [========================================================================================================================] 100.00% 0s
==> amazon-ebs.ubuntu-hardened: Provisioning with shell script: inline commands
    amazon-ebs.ubuntu-hardened: ==> Waiting for cloud-init to complete process lock...
    amazon-ebs.ubuntu-hardened: status: done
    amazon-ebs.ubuntu-hardened: ==> Applying OS updates...
    amazon-ebs.ubuntu-hardened: Hit:1 http://archive.ubuntu.com/ubuntu jammy Insecure
    amazon-ebs.ubuntu-hardened: Reading package lists... Done
    amazon-ebs.ubuntu-hardened: Building dependency tree... Done
    amazon-ebs.ubuntu-hardened: Upgrading packages... Done
==> amazon-ebs.ubuntu-hardened: Provisioning with shell script: scripts/cleanup.sh
    amazon-ebs.ubuntu-hardened: =========================================================
    amazon-ebs.ubuntu-hardened:  STARTING PRODUCTION IMAGE HARDENING & SANITIZATION
    amazon-ebs.ubuntu-hardened: =========================================================
    amazon-ebs.ubuntu-hardened: ==> Stopping syslog and audit daemons...
    amazon-ebs.ubuntu-hardened: ==> Purging existing SSH host key pairs...
    amazon-ebs.ubuntu-hardened: ==> Resetting /etc/machine-id...
    amazon-ebs.ubuntu-hardened: ==> Cleaning cloud-init cache and log artifacts...
    amazon-ebs.ubuntu-hardened: ==> Cleaning APT package manager cache...
    amazon-ebs.ubuntu-hardened: ==> Clearing system logs and user history files...
    amazon-ebs.ubuntu-hardened: ==> Zeroing out empty disk sectors...
    amazon-ebs.ubuntu-hardened: 20971520000 bytes (21 GB, 20 GiB) copied, 18.23 s, 1.2 GB/s
    amazon-ebs.ubuntu-hardened: dd: error writing '/EMPTY': No space left on device
    amazon-ebs.ubuntu-hardened: =========================================================
    amazon-ebs.ubuntu-hardened:  SANITIZATION COMPLETE - IMAGE READY FOR SNAPSHOT
    amazon-ebs.ubuntu-hardened: =========================================================
==> amazon-ebs.ubuntu-hardened: Stopping the source instance...
    amazon-ebs.ubuntu-hardened: Stopping instance
==> amazon-ebs.ubuntu-hardened: Waiting for the instance to stop...
==> amazon-ebs.ubuntu-hardened: Creating AMI golden-ubuntu-22.04-amd64-2.4.1-build-20260807123000 from instance i-0a91f4e8bc12a45d0
    amazon-ebs.ubuntu-hardened: AMI: ami-05e8391bc47a9e10f
==> amazon-ebs.ubuntu-hardened: Waiting for AMI to become ready...
==> amazon-ebs.ubuntu-hardened: Adding tags to AMI (ami-05e8391bc47a9e10f)...
==> amazon-ebs.ubuntu-hardened: Terminating the source AWS instance...
    amazon-ebs.ubuntu-hardened: Terminating instance
==> amazon-ebs.ubuntu-hardened: Cleaning up any extra volumes...
==> amazon-ebs.ubuntu-hardened: Destroying temporary keypair...
==> amazon-ebs.ubuntu-hardened: Destroying temporary security group...
==> amazon-ebs.ubuntu-hardened: Running post-processor: manifest
Build 'amazon-ebs.ubuntu-hardened' finished after 6 minutes 42 seconds.

==> Builds finished. The artifacts of successful builds are:
--> amazon-ebs.ubuntu-hardened: AMIs were created:
us-east-1: ami-05e8391bc47a9e10f
```

---

### 4.3 Paso 3: Inspeccionar los Metadatos del Artefacto Generado vía AWS CLI
Verifique el estado, el mapeo de dispositivos de bloque, el estado de cifrado y las etiquetas (tags) de la imagen de salida utilizando la AWS CLI.

```bash
$ aws ec2 describe-images --image-ids ami-05e8391bc47a9e10f --output json
{
    "Images": [
        {
            "Architecture": "x86_64",
            "CreationDate": "2026-08-07T12:36:42.000Z",
            "ImageId": "ami-05e8391bc47a9e10f",
            "ImagePath": "",
            "ImageLocation": "123456789012/golden-ubuntu-22.04-amd64-2.4.1-build-20260807123000",
            "State": "available",
            "BlockDeviceMappings": [
                {
                    "DeviceName": "/dev/sda1",
                    "Ebs": {
                        "DeleteOnTermination": true,
                        "SnapshotId": "snap-08cf92bdf11a4e21",
                        "VolumeSize": 20,
                        "VolumeType": "gp3",
                        "Encrypted": true,
                        "Iops": 3000,
                        "Throughput": 125
                    }
                }
            ],
            "EnaSupport": true,
            "Hypervisor": "xen",
            "Name": "golden-ubuntu-22.04-amd64-2.4.1-build-20260807123000",
            "RootDeviceName": "/dev/sda1",
            "RootDeviceType": "ebs",
            "VirtualizationType": "hvm",
            "Tags": [
                {
                    "Key": "AppVersion",
                    "Value": "2.4.1"
                },
                {
                    "Key": "Environment",
                    "Value": "production"
                },
                {
                    "Key": "ManagedBy",
                    "Value": "Packer"
                }
            ]
        }
    ]
}
```

---

## 5. Guía de Verificación, Solución de Problemas y Diagnóstico de Fallas

### 5.1 Matriz de Fallas y Procedimientos de Diagnóstico de Causa Raíz

```
                       [ PACKER BUILD / RUNTIME FAILURE ]
                                       │
        ┌──────────────────────────────┼──────────────────────────────┐
        ▼                              ▼                              ▼
 [ SSH Timeout Failure ]     [ Machine-ID Collision ]       [ Cloud-Init Lockout ]
        │                              │                              │
        ├── Check Security Group       ├── Inspect /etc/machine-id    ├── Run cloud-init status
        ├── Check Public IP assignment ├── Verify DHCP logs           ├── Inspect /var/log/cloud-init.log
        └── Verify ssh_username        └── Ensure sanitization run    └── Check systemd dependencies
```

#### Escenario de Diagnóstico A: Tiempo de Espera Agotado (Timeout) del Transporte SSH Efímero Durante la Build
* **Síntoma:** `packer build` se congela en `Waiting for SSH to become available...` y eventualmente agota el tiempo de espera (timeout).
* **Causa Raíz 1:** La VPC/Subred de destino seleccionada por Packer carece de un Internet Gateway (IGW) adjunto o `associate_public_ip_address` está configurado en `false`.
* **Causa Raíz 2:** El `ssh_username` predeterminado de la AMI no coincide con el valor predeterminado de la imagen base (por ejemplo, especificar `root` o `admin` en lugar de `ubuntu` o `ec2-user`).
* **Comando de Diagnóstico:**
  ```bash
  PACKER_LOG=1 PACKER_LOG_PATH="packer-debug.log" packer build -on-error=ask ubuntu-hardened.pkr.hcl
  ```
  *(Nota: `-on-error=ask` detiene la ejecución al ocurrir un error sin terminar inmediatamente la instancia EC2 temporal, lo que permite una inspección directa por SSH).*

#### Escenario de Diagnóstico B: Machine-ID Duplicado Causando Colisiones de Red/DHCP
* **Síntoma:** Las instancias lanzadas desde la AMI horneada reciben direcciones IP privadas idénticas del servidor DHCP de la red o sobrescriben los streams de registro central de cada una en `systemd-journald`.
* **Causa Raíz:** `/etc/machine-id` no fue truncado durante el proceso de build de la imagen. Cada instancia clonada a partir del snapshot hereda exactamente el mismo identificador único de máquina de 128 bits.
* **Comando de Verificación en una Instancia en Ejecución:**
  ```bash
  $ cat /etc/machine-id
  # If the string returned matches across multiple instances, sanitization failed.
  ```
* **Remediación:** Asegúrese de que `truncate -s 0 /etc/machine-id` esté presente en el provisioner final de shell de limpieza.

#### Escenario de Diagnóstico C: Condición de Carrera en el Bloqueo de Paquetes Apt
* **Síntoma:** El provisioner de shell falla con `E: Could not get lock /var/lib/dpkg/lock-frontend - open (11: Resource temporarily unavailable)`.
* **Causa Raíz:** Las imágenes base de Canonical ejecutan actualizaciones automáticas de `apt-daily.service` y `cloud-init` en segundo plano al arrancar. Si Packer ejecuta `apt-get` concurrentemente, los bloqueos de paquetes fallan.
* **Remediación:** Imponga una barrera de finalización de cloud-init en el primer provisioner de shell:
  ```bash
  cloud-init status --wait
  ```

---

### 5.2 Flujo de Trabajo de Solución de Problemas de Bajo Nivel a Profundidad

Al depurar fallas de ejecución de cloud-init en Golden Images recién instanciadas, los SREs deben navegar por las cuatro etapas de ejecución de cloud-init (`generator`, `local`, `init`, `modules:config`, `modules:final`).

```bash
# 1. Query Consolidated Cloud-Init Status
$ cloud-init status --long
status: error
extended_status: error
boot_status_code: enabled-error
detail: DataSourceNotFound - No supported datasource found

# 2. Inspect Cloud-Init Log Streams for Exception Tracebacks
$ grep -E "(ERROR|WARNING)" /var/log/cloud-init.log
2026-08-07 12:40:15,123 - cc_final.py[ERROR]: Failed executing module final
Traceback (most recent call last):
  File "/usr/lib/python3/dist-packages/cloudinit/config/cc_final.py", line 85, in handle
    subp.subp(req)
ProcessExecutionError: Unexpected error while running command: systemctl restart app-exporter.service

# 3. Analyze Systemd Unit Dependency Trees & Failures
$ journalctl -u cloud-final.service -u app-exporter.service --no-pager -n 50
Aug 07 12:40:15 node-prod-app-01 systemd[1]: Failed to start Production Node Exporter.
Aug 07 12:40:15 node-prod-app-01 systemd[1]: app-exporter.service: Main process exited, code=exited, status=203/EXEC
```

---

## 6. Referencias

- **Linux Professional Institute (LPI) DevOps Tools Engineer Overview:**  
  [https://www.lpi.org/our-certifications/devops-tools-engineer-overview/](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
- **LPI Wiki - Objective 703.3 System Image Creation:**  
  [https://wiki.lpi.org/wiki/DevOps_Tools_Engineer_Objectives_V1.0#703.3_System_Image_Creation](https://wiki.lpi.org/wiki/DevOps_Tools_Engineer_Objectives_V1.0#703.3_System_Image_Creation)
- **HashiCorp Packer Official Documentation:**  
  [https://developer.hashicorp.com/packer/docs](https://developer.hashicorp.com/packer/docs)
- **HashiCorp Packer Amazon EBS Builder Plugin:**  
  [https://developer.hashicorp.com/packer/integrations/hashicorp/amazon/latest/components/builder/ebs](https://developer.hashicorp.com/packer/integrations/hashicorp/amazon/latest/components/builder/ebs)
- **Cloud-Init Official Documentation:**  
  [https://cloudinit.readthedocs.io/en/latest/](https://cloudinit.readthedocs.io/en/latest/)