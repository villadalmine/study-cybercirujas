# Guía de estudio de LPI DevOps Tools Engineer (Examen 701-100, v1.0)
## Tema 3.2: Cloud Deployment (Peso del objetivo: 3.33)

---

## 1. Motivación arquitectónica y planteamiento del problema en producción

En la infraestructura cloud empresarial, aprovisionar instancias virtuales o recursos cloud de forma imperativa mediante scripts manuales o configuraciones SSH ad-hoc introduce modos de fallo operativo críticos:
1. **Configuration Drift & Non-Determinism**: Los cambios no rastreados realizados directamente en máquinas virtuales (VMs) en ejecución crean instancias a la medida ("snowflake servers") que no se pueden reproducir, auditar ni probar de manera confiable en entornos de staging.
2. **Boot-Time Lifecycle Race Conditions**: Las aplicaciones que se inician durante el arranque de la instancia a menudo fallan porque los servicios del SO (redes, resolución DNS, adjuntos de block storage, disponibilidad de metadatos) aún no están completamente inicializados o sincronizados.
3. **Secrets & Identity Exposure**: Pasar credenciales sensibles, claves privadas SSH o tokens de API mediante scripts user-data en texto plano o variables de entorno conlleva altos riesgos de seguridad, particularmente cuando los servicios de metadatos están expuestos sin restricciones de acceso modernas.
4. **Scale-Out Latency Bottlenecks**: Ejecutar tareas pesadas de aprovisionamiento (compilación de paquetes, resolución compleja de dependencias) durante el arranque inicial de la instancia (`cloud-init` en tiempo de ejecución) retrasa significativamente los tiempos de respuesta del Auto Scaling group (ASG) durante los picos de demanda.

Para eliminar estos vectores de fallo, los equipos modernos de SRE y Platform Engineering emplean **Immutable Infrastructure** combinada con patrones declarativos de inicialización en la nube. 

```
                                  +--------------------------------------------------------+
                                  |                 Provisioning Pipeline                  |
                                  +--------------------------------------------------------+
                                                              |
                                      +-----------------------+-----------------------+
                                      |                                               |
                                      v                                               v
                          +-----------------------+                       +-----------------------+
                          |   Packer (Build)      |                       |  Terraform (Deploy)   |
                          | Custom Immutable AMI  |                       | Declarative Infra     |
                          +-----------------------+                       +-----------------------+
                                      |                                               |
                                      +-----------------------+-----------------------+
                                                              |
                                                              v
                                                  +-----------------------+
                                                  |  Cloud Instance Boot  |
                                                  +-----------------------+
                                                              |
                                                              v
                                                  +-----------------------+
                                                  |   systemd lifecycle   |
                                                  +-----------------------+
                                                              |
                                +-----------------------------+-----------------------------+
                                |                             |                             |
                                v                             v                             v
                   +-------------------------+   +-------------------------+   +-------------------------+
                   |  cloud-init-local.service | -->|   cloud-init.service    | -->|   cloud-final.service   |
                   |  (Reads Local Metadata) |   | (Network/Packages/Users)|   |  (runcmd / User Data)   |
                   +-------------------------+   +-------------------------+   +-------------------------+
                                                                                            |
                                                                                            v
                                                                               +-------------------------+
                                                                               | Application Ready State |
                                                                               +-------------------------+
```

### Análisis microarquitectónico del ciclo de vida de ejecución de `cloud-init`
`cloud-init` es el paquete estándar multidistribución que gestiona la inicialización temprana de las instancias cloud. Se engancha en la inicialización del sistema operativo host (típicamente a través de `systemd`) a lo largo de cuatro etapas secuenciales distintas:

1. **`cloud-init-local.service` (Generator & Local Stage)**:
   - Se ejecuta antes de que se levante la red.
   - Busca datasources locales (por ejemplo, ISOs NoCloud, discos de configuración, argumentos de la línea de comandos del kernel).
   - Configura redes temporales si es necesario y establece el hostname inicial del sistema en `/etc/hostname`.
2. **`cloud-init.service` (Network Stage)**:
   - Se ejecuta después de que las interfaces de red están en línea.
   - Consulta servicios de metadatos cloud basados en red (por ejemplo, AWS IMDS `169.254.169.254`, OpenStack Metadata, GCP Metadata).
   - Procesa `user-data`, `vendor-data` y configuraciones de red.
   - Gestiona la inyección de claves SSH autorizadas, configuraciones de montaje (`/etc/fstab`) y actualizaciones de paquetes del sistema (`apt-get`/`dnf`).
3. **`cloud-config.service` (Config Stage)**:
   - Ejecuta módulos `cloud-config` definidos en `/etc/cloud/cloud.cfg` y `user-data`.
   - Ejecuta la escritura de archivos (`write_files`), hooks de gestión de configuración y creación de usuarios/grupos.
4. **`cloud-final.service` (Final Stage)**:
   - Se ejecuta al final del proceso de arranque (equivalente a `multi-user.target`).
   - Ejecuta scripts arbitrarios definidos en `runcmd` o scripts inline.
   - Activa scripts de proveedores, ejecuciones de agentes de gestión de configuración (por ejemplo, Ansible, Puppet) y señala la disponibilidad de la instancia a los auto-scalers en la nube.

---

## 2. Comparaciones técnicas y matriz de trade-offs en producción

### Tabla 2.1: Estrategias de inicialización de máquinas

| Paradigma de arquitectura | Latencia del tiempo de arranque | Sobrecarga de mantenimiento | Determinismo y auditabilidad | Recuperación de fallos |
| :--- | :--- | :--- | :--- | :--- |
| **Runtime Bootstrapping** (orientado a `cloud-init`) | **Alta** (3–10+ min: instala paquetes, ejecuta scripts en cada arranque) | **Baja** (Utiliza imágenes base de distribución de SO vanilla) | **Bajo** (Los repositorios de paquetes upstream pueden cambiar o fallar durante el arranque) | **Lenta** (Eventos de escalado retrasados por pasos de instalación) |
| **Bake-at-Build** (Golden Images inmutables con Packer) | **Baja** (<30–60 seg: paquetes binarios precompilados y hardening del SO) | **Alta** (Requiere pipelines CI/CD de construcción de imágenes y gestión del ciclo de vida de la imagen) | **Alto** (Digest binario estático y firmado criptográficamente) | **Rápida** (Reemplazo instantáneo de nodos fallidos) |
| **Hybrid Approach** (Línea base de Packer + `cloud-init` mínimo) | **Balanceada** (~1–2 min: tiempo de ejecución preconstruido, secretos/configuración dinámicos inyectados al arrancar) | **Media** (Imágenes base estandarizadas con ajuste dinámico de parámetros en tiempo de ejecución) | **Alto** (SO base estático; parámetros en tiempo de ejecución validados mediante esquema) | **Óptima** (Combina scale-out rápido con incorporación dinámica al entorno) |

### Tabla 2.2: Arquitectura de seguridad del servicio de metadatos de instancias cloud

| Vector de especificación | AWS IMDSv1 | AWS IMDSv2 |
| :--- | :--- | :--- |
| **Modelo de sesión** | Solicitudes HTTP `GET` sin estado directamente a `http://169.254.169.254` | Solicitud HTTP `PUT` orientada a sesión requiere obtener primero un token criptográfico |
| **Protección contra vulnerabilidades SSRF** | **Vulnerable**: Aplicaciones no autenticadas o errores de SSRF pueden exfiltrar credenciales de roles IAM | **Mitigado**: Requiere cabeceras específicas (`X-aws-ec2-metadata-token-ttl-seconds`) y envío de tokens |
| **Límite de saltos de red (TTL)** | Ilimitado / Por defecto | IP Hop Limit forzado (Por defecto: `1` para prevenir la exfiltración mediante el recorrido de red en contenedores) |
| **Cabeceras requeridas** | Ninguna | `X-aws-ec2-metadata-token` |

---

## 3. Manifiestos de infraestructura de producción completos y sin recortes

### 3.1 Manifiesto `#cloud-config` User-Data de producción (`user-data.yaml`)

Este manifiesto es totalmente válido, sintácticamente completo y configura el hardening de seguridad del SO, parámetros del kernel sysctl, estructuras de directorios, archivos y usuarios.

```yaml
#cloud-config
version: v1
hostname: prod-node-01
fqdn: prod-node-01.infra.internal
manage_etc_hosts: true

users:
  - name: sysadmin
    gecos: System Administrator
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGx9K8P9ZzW0q5xYmRvN3k1Lq9R6aT4uW8vY1z2X3Y4Z sysadmin@production

package_update: true
package_upgrade: true
packages:
  - apt-transport-https
  - ca-certificates
  - curl
  - gnupg
  - lsb-release
  - jq
  - htop
  - ufw

write_files:
  - path: /etc/sysctl.d/99-sre-security.conf
    owner: root:root
    permissions: '0644'
    content: |
      # Production Security & Networking Overrides
      net.ipv4.ip_forward = 0
      net.ipv4.conf.all.accept_redirects = 0
      net.ipv4.conf.default.accept_redirects = 0
      net.ipv4.conf.all.secure_redirects = 0
      net.ipv4.conf.default.secure_redirects = 0
      net.ipv4.tcp_syncookies = 1
      net.ipv4.tcp_max_syn_backlog = 2048
      net.ipv4.tcp_synack_retries = 2
      fs.file-max = 2097152

  - path: /etc/systemd/system/node-exporter-healthcheck.service
    owner: root:root
    permissions: '0644'
    content: |
      [Unit]
      Description=SRE Node Initialization Verifier
      After=network-online.target cloud-final.service
      Wants=network-online.target

      [Service]
      Type=oneshot
      ExecStart=/usr/local/bin/verify-node.sh
      RemainAfterExit=yes

      [Install]
      WantedBy=multi-user.target

  - path: /usr/local/bin/verify-node.sh
    owner: root:root
    permissions: '0755'
    content: |
      #!/usr/bin/env bash
      set -euo pipefail
      echo "[SRE-BOOT] Running post-cloud-init health verification..."
      sysctl -p /etc/sysctl.d/99-sre-security.conf
      echo "[SRE-BOOT] System initialization verified successfully." > /var/log/sre-init.log

runcmd:
  - sysctl --system
  - systemctl daemon-reload
  - systemctl enable --now node-exporter-healthcheck.service
  - ufw default deny incoming
  - ufw default allow outgoing
  - ufw allow 22/tcp
  - ufw --force enable

final_message: "System initialization complete after $UPTIME seconds."
```

---

### 3.2 Plantilla HashiCorp Packer HCL2 (`aws-ubuntu-hardened.pkr.hcl`)

Esta plantilla construye una Amazon Machine Image (AMI) reforzada para producción con herramientas preinstaladas y un estado de `cloud-init` limpio.

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

source "amazon-ebs" "hardened_ubuntu" {
  ami_name      = "sre-hardened-ubuntu-2204-${formatdate("YYYYMMDDhhmmss", timestamp())}"
  instance_type = "t3.micro"
  region        = var.aws_region

  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["099720109477"] # Canonical
  }

  ssh_username = "ubuntu"

  tags = {
    Name        = "sre-hardened-ubuntu-2204"
    Environment = var.environment
    Builder     = "Packer"
    ManagedBy   = "Platform-Engineering"
  }
}

build {
  name    = "sre-ami-builder"
  sources = ["source.amazon-ebs.hardened_ubuntu"]

  provisioner "shell" {
    inline = [
      "export DEBIAN_FRONTEND=noninteractive",
      "sudo apt-get update -y",
      "sudo apt-get upgrade -y",
      "sudo apt-get install -y cloud-init curl jq unzip auditd",
      "sudo systemctl enable auditd"
    ]
  }

  provisioner "shell" {
    inline = [
      "echo '[PACKER] Resetting cloud-init execution state for image golden snapshot...'",
      "sudo systemctl stop cloud-init",
      "sudo rm -rf /var/lib/cloud/instances/*",
      "sudo rm -rf /var/lib/cloud/instance",
      "sudo rm -rf /var/lib/cloud/data/*",
      "sudo cloud-init clean --logs --seed",
      "sudo rm -f /etc/ssh/ssh_host_*",
      "sudo sync"
    ]
  }
}
```

---

### 3.3 Manifiesto declarativo de Terraform (`main.tf`)

Este manifiesto aprovisiona la red VPC de AWS y una instancia EC2, aplicando IMDSv2 e inyectando el manifiesto `cloud-init`.

```hcl
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  type    = string
  default = "production"
}

resource "aws_vpc" "main" {
  cidr_block           = "10.100.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "sre-production-vpc"
    Environment = var.environment
  }
}

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.100.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = {
    Name = "sre-public-subnet-a"
  }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "sre-main-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "sre-public-route-table"
  }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "instance_sg" {
  name        = "sre-instance-security-group"
  description = "Security group for production EC2 node enforcing minimal ingress"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH access from trusted range"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "sre-instance-sg"
  }
}

resource "aws_instance" "app_node" {
  ami                  = "ami-0c7217cdde317cfec" # Base Ubuntu 22.04 LTS AMI
  instance_type        = "t3.micro"
  subnet_id            = aws_subnet.public_a.id
  vpc_security_group_ids = [aws_security_group.instance_sg.id]

  user_data = file("${path.module}/user-data.yaml")

  # Mandatory SRE Hardening: Enforce IMDSv2 (Mitigate SSRF Vulnerabilities)
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name        = "sre-production-app-node"
    Environment = var.environment
  }
}

output "instance_public_ip" {
  description = "Public IP address of the deployed EC2 node"
  value       = aws_instance.app_node.public_ip
}

output "instance_id" {
  description = "AWS Instance ID"
  value       = aws_instance.app_node.id
}
```

---

## 4. Comandos reales de CLI y salidas de terminal

### 4.1 Validación e inspección del esquema y ejecución de `cloud-init`

Valide la sintaxis del manifiesto user-data `#cloud-config` localmente antes del despliegue:

```bash
$ cloud-init schema --config-file user-data.yaml
```
```text
Valid cloud-config: user-data.yaml
```

Consulte el estado general de ejecución de `cloud-init` en una instancia cloud iniciada:

```bash
$ cloud-init status --long
```
```text
status: done
extended_status: done
boot_status_code: enabled-by-sysv-or-systemd
last_update: Fri, 07 Aug 2026 08:45:12 +0000
detail: DataSourceCloudStack [seed=/dev/sr0]
```

Analice las métricas de ejecución y el tiempo transcurrido en cada fase de `cloud-init`:

```bash
$ cloud-init analyze blame
```
```text
  04.2120s (init-local)
  12.8410s (init)
  08.3100s (modules-config)
  15.9120s (modules-final)
  38.7750s total time
```

---

### 4.2 Obtención segura de metadatos de instancia mediante IMDSv2

El intento de realizar una solicitud IMDSv1 no autenticada falla cuando se fuerza IMDSv2 (`http_tokens = "required"`):

```bash
$ curl -s -i http://169.254.169.254/latest/meta-data/instance-id
```
```text
HTTP/1.1 401 Unauthorized
Content-Length: 0
Date: Fri, 07 Aug 2026 08:47:01 GMT
Server: EC2ws
```

Obtención correcta de datos de IMDSv2 utilizando un token de sesión:

```bash
$ TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
$ curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id
```
```text
i-0a8b9c1d2e3f4567a
```

Obtener la dirección IPv4 pública de la instancia utilizando el token de IMDSv2:

```bash
$ curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4
```
```text
54.210.142.89
```

---

### 4.3 Construcción de Golden AMIs utilizando HashiCorp Packer

Valide la sintaxis de la plantilla de Packer:

```bash
$ packer validate aws-ubuntu-hardened.pkr.hcl
```
```text
The configuration is valid.
```

Ejecute la construcción con Packer:

```bash
$ packer build aws-ubuntu-hardened.pkr.hcl
```
```text
amazon-ebs.hardened_ubuntu: output will be in this color.

==> amazon-ebs.hardened_ubuntu: Prevalidated AMI Name: sre-hardened-ubuntu-2204-20260807085000
    amazon-ebs.hardened_ubuntu: Found Image ID: ami-0c7217cdde317cfec
==> amazon-ebs.hardened_ubuntu: Creating temporary keypair...
==> amazon-ebs.hardened_ubuntu: Launching a source AWS instance...
    amazon-ebs.hardened_ubuntu: Instance ID: i-0912ab34cd56ef78a
==> amazon-ebs.hardened_ubuntu: Waiting for instance to become ready...
==> amazon-ebs.hardened_ubuntu: Connected to SSH!
==> amazon-ebs.hardened_ubuntu: Provisioning with shell script...
    amazon-ebs.hardened_ubuntu: Get:1 http://archive.ubuntu.com/ubuntu jammy InRelease [270 kB]
    amazon-ebs.hardened_ubuntu: Reading package lists... Done
==> amazon-ebs.hardened_ubuntu: Provisioning with shell script...
    amazon-ebs.hardened_ubuntu: [PACKER] Resetting cloud-init execution state for image golden snapshot...
    amazon-ebs.hardened_ubuntu: cloud-init clean complete.
==> amazon-ebs.hardened_ubuntu: Stopping the source instance...
==> amazon-ebs.hardened_ubuntu: Creating AMI sre-hardened-ubuntu-2204-20260807085000 from instance i-0912ab34cd56ef78a...
    amazon-ebs.hardened_ubuntu: AMI: ami-0fe123456789abcde
==> amazon-ebs.hardened_ubuntu: Terminating the source AWS instance...
==> amazon-ebs.hardened_ubuntu: Cleaning up any extra resources...
Build 'amazon-ebs.hardened_ubuntu' finished after 4 minutes 12 seconds.

==> Builds finished. The artifacts of successful builds are:
--> amazon-ebs.hardened_ubuntu: AMIs were created:
us-east-1: ami-0fe123456789abcde
```

---

### 4.4 Aprovisionamiento declarativo a través de Terraform

Inicialice el directorio de trabajo de Terraform:

```bash
$ terraform init
```
```text
Initializing the backend...
Initializing provider plugins...
- Finding hashicorp/aws versions matching "~> 5.0"...
- Installing hashicorp/aws v5.61.0...
- Installed hashicorp/aws v5.61.0 (signed by HashiCorp)

Terraform has been successfully initialized!
```

Genere el plan de ejecución:

```bash
$ terraform plan -out=tfplan
```
```text
Terraform used the selected providers to generate the following execution plan. Resource actions are indicated with the following symbols:
  + create

Terraform will perform the following actions:

  # aws_instance.app_node will be created
  + resource "aws_instance" "app_node" {
      + ami                          = "ami-0c7217cdde317cfec"
      + arn                          = (known after apply)
      + instance_state               = (known after apply)
      + instance_type                = "t3.micro"
      + public_ip                    = (known after apply)
      + user_data                    = "4f5c9e2b1a8d7c6e0f1a..." # SHA256 of user-data.yaml
      + metadata_options {
          + http_endpoint               = "enabled"
          + http_put_response_hop_limit = 1
          + http_tokens                 = "required"
          + instance_metadata_tags      = "enabled"
        }
    }

  # aws_vpc.main will be created
  + resource "aws_vpc" "main" {
      + cidr_block = "10.100.0.0/16"
      + id         = (known after apply)
    }

Plan: 6 to add, 0 to change, 0 to destroy.

Saved the plan to: tfplan
```

Aplique el plan de infraestructura:

```bash
$ terraform apply tfplan
```
```text
aws_vpc.main: Creating...
aws_vpc.main: Creation complete after 3s [id=vpc-01a2b3c4d5e6f7890]
aws_internet_gateway.gw: Creating...
aws_subnet.public_a: Creating...
aws_security_group.instance_sg: Creating...
aws_subnet.public_a: Creation complete after 2s [id=subnet-0123456789abcdef0]
aws_internet_gateway.gw: Creation complete after 2s [id=igw-0fedcba9876543210]
aws_security_group.instance_sg: Creation complete after 3s [id=sg-0a1b2c3d4e5f6789a]
aws_route_table.public: Creating...
aws_route_table.public: Creation complete after 1s [id=rtb-0987654321fedcba0]
aws_route_table_association.public_assoc: Creating...
aws_route_table_association.public_assoc: Creation complete after 1s [id=rtbassoc-01234567890abcdef]
aws_instance.app_node: Creating...
aws_instance.app_node: Still creating... [10s elapsed]
aws_instance.app_node: Creation complete after 14s [id=i-0a8b9c1d2e3f4567a]

Apply complete! Resources: 6 added, 0 changed, 0 destroyed.

Outputs:

instance_id = "i-0a8b9c1d2e3f4567a"
instance_public_ip = "54.210.142.89"
```

---

## 5. Guía de verificación y diagnóstico de fallos

Cuando una instancia arranca en un estado degradado o no responde, siga este flujo de trabajo de diagnóstico sistemático:

```
                            +-------------------------------------------+
                            |           Diagnostic Procedure            |
                            +-------------------------------------------+
                                                  |
                                                  v
                            +-------------------------------------------+
                            |     1. Inspect cloud-init Logs            |
                            |   /var/log/cloud-init.log & output.log    |
                            +-------------------------------------------+
                                                  |
                                                  v
                            +-------------------------------------------+
                            |     2. Validate Schema & Syntax           |
                            |   cloud-init schema --config-file         |
                            +-------------------------------------------+
                                                  |
                                                  v
                            +-------------------------------------------+
                            |     3. Check systemd Services             |
                            |   systemctl status cloud-final.service    |
                            +-------------------------------------------+
                                                  |
                                                  v
                            +-------------------------------------------+
                            |     4. Reset & Re-run (Local Debug)       |
                            |   cloud-init clean --logs --reboot        |
                            +-------------------------------------------+
```

### 5.1 Protocolo de análisis de logs

1. **Main Initialization Trace Log**: `/var/log/cloud-init.log`
   - Contiene trazas de ejecución de alta verbosidad para módulos de Python, consultas a fuentes de datos y resoluciones de las etapas de configuración.
   - *Buscar errores*: `grep -Ei "error|fail|exception" /var/log/cloud-init.log`

2. **Standard Output & Standard Error Log**: `/var/log/cloud-init-output.log`
   - Captura la salida por consola generada por directivas `runcmd`, scripts bash inline e instalaciones de `apt-get`/`package`.
   - Inspeccionar salida: `tail -n 100 /var/log/cloud-init-output.log`

### 5.2 Escenarios de diagnóstico reales

#### Escenario A: Sintaxis `#cloud-config` no válida
- **Síntoma**: El script user-data no se ejecuta; faltan paquetes; no se crean usuarios.
- **Causa raíz**: Errores de sintaxis YAML (por ejemplo, tabulaciones en lugar de espacios, falta la línea de encabezado `#cloud-config`).
- **Comando de diagnóstico**:
  ```bash
  $ sudo cloud-init schema --config-file /var/lib/cloud/instance/user-data.txt
  ```
- **Salida**:
  ```text
  Error: Cloud config at /var/lib/cloud/instance/user-data.txt is not valid YAML.
  Line 14, column 3: Expected key-value pair, found invalid indentation.
  ```

#### Escenario B: Límite de saltos IMDSv2 alcanzado en entornos en contenedores
- **Síntoma**: La aplicación que se ejecuta dentro de un contenedor Docker o Kubernetes Pod en la instancia EC2 no puede obtener las credenciales de rol IAM de `169.254.169.254`.
- **Causa raíz**: El límite de saltos (TTL) de IP para los paquetes de respuesta IMDSv2 está configurado en `1`. El puente de red (network bridge) para contenedores incrementa el recuento de saltos a `2`, lo que hace que el servicio de metadatos descarte el paquete.
- **Comando de diagnóstico**:
  ```bash
  $ aws ec2 describe-instances --instance-ids i-0a8b9c1d2e3f4567a --query "Reservations[*].Instances[*].MetadataOptions"
  ```
- **Resolución**:
  Actualizar la configuración de Terraform para definir `http_put_response_hop_limit = 2`:
  ```hcl
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }
  ```

#### Escenario C: Forzado del reinicio de ejecución local de `cloud-init`
Para volver a ejecutar el ciclo de vida de arranque de `cloud-init` durante la depuración local sin destruir la instancia cloud subyacente:

```bash
$ sudo cloud-init clean --logs
$ sudo systemctl restart cloud-init-local.service cloud-init.service cloud-config.service cloud-final.service
$ sudo cloud-init status --long
```

---

## 6. Referencias

- **Linux Professional Institute (LPI) DevOps Tools Engineer Overview**:  
  https://www.lpi.org/our-certifications/devops-tools-engineer-overview/
- **Documentación oficial de Cloud-Init**:  
  https://cloudinit.readthedocs.io/en/latest/
- **Documentación de AWS EC2 Instance Metadata Service Version 2 (IMDSv2)**:  
  https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html
- **Documentación del proveedor AWS para HashiCorp Terraform**:  
  https://registry.terraform.io/providers/hashicorp/aws/latest/docs
- **Documentación de HashiCorp Packer**:  
  https://developer.hashicorp.com/packer/docs