# LPI DevOps Tools Engineer (Examen 701-100) — Tema 3.2: Cloud Deployment

## 1. Análisis Arquitectónico Profundo y Mecánica Interna

### 1.1 Modelos de Cloud Deployment y Abstracciones de Servicios

La arquitectura cloud moderna se basa en distintas capas de abstracción. Como SRE o Platform Architect, la elección del modelo correcto dicta el límite de la responsabilidad operacional, la sobrecarga de aislamiento multi-tenant y la gestión del dominio de fallas.

```
+-------------------------------------------------------------------------+
|                              SaaS Layer                                 |
| (Software-as-a-Service: Gmail, Salesforce, Auth0)                      |
| Managed: Application, Data, Runtime, Middleware, OS, Virtualization, Hardware |
+-------------------------------------------------------------------------+
|                              PaaS Layer                                 |
| (Platform-as-a-Service: AWS Elastic Beanstalk, Heroku, Cloud Foundry)   |
| Managed by User: Application, Data                                      |
| Managed by Cloud: Runtime, Middleware, OS, Virtualization, Hardware     |
+-------------------------------------------------------------------------+
|                              FaaS / Serverless                          |
| (Function-as-a-Service: AWS Lambda, Google Cloud Functions)             |
| Managed by User: Ephemeral Function Logic, Trigger Bindings             |
| Managed by Cloud: Event Bus, Runtime Container, Scaling, Infrastructure |
+-------------------------------------------------------------------------+
|                              IaaS Layer                                 |
| (Infrastructure-as-a-Service: AWS EC2, OpenStack Nova, GCP Compute)    |
| Managed by User: OS Config, App Code, Storage Volumes, Network Topology |
| Managed by Cloud: Hypervisor (KVM/Nitro), Physical Hardware, Datacenter |
+-------------------------------------------------------------------------+
```

#### Trade-offs Arquitectónicos y Consideraciones de Producción

| Métrica / Dimensión | IaaS (por ejemplo, OpenStack, AWS EC2) | PaaS (por ejemplo, Heroku, Beanstalk) | FaaS (por ejemplo, AWS Lambda) |
| :--- | :--- | :--- | :--- |
| **Operational Overhead** | Alto (parcheo de OS, instalación de agentes, tuning de kernel) | Bajo (Enfoque en empaquetado de aplicaciones) | Mínimo (Sin gestión de OS, escalado automático) |
| **Customization & Control** | Máximo (kernels personalizados, módulos de kernel, sysctl) | Restringido (runtimes/buildpacks limitados) | Altamente Restringido (Stateless, corta duración) |
| **Cold Start Latency** | Minutos (boot completo de OS + ejecución de cloud-init) | Segundos (instanciación de contenedores) | Milisegundos a Segundos (fase de Init / compilación JIT) |
| **Blast Radius Isolation** | Nivel de Hardware/Hypervisor (KVM, Nitro, Xen) | Namespace de Proceso / Contenedor | MicroVM / Sandbox (Firecracker, gVisor) |
| **Vendor Lock-in Risk** | Bajo (Portable mediante OpenStack/Terraform) | Medio (Buildpack o especificaciones específicas de la plataforma) | Alto (Esquemas de triggers de eventos, SDKs del proveedor) |

---

### 1.2 Motor de Bootstrapping de Instancias: Arquitectura de `cloud-init`

`cloud-init` es el motor multidistribución canónico para la inicialización en etapas tempranas de instancias cloud. Tiende un puente entre los aprovisionadores de imágenes de máquina puras (como OpenStack Glance o AWS AMI) y los motores de gestión de configuración (Ansible, Puppet, Chef).

#### Secuencia de Ejecución de Boot e Integración con Systemd

`cloud-init` se ejecuta a través de **cuatro etapas de boot deterministas** coordinadas mediante targets de systemd:

```
[System Power On / Kernel Boot]
              │
              ▼
┌────────────────────────────────────────────────────────┐
│ 1. Generator Stage (cloud-init-generator)              │
│    Inspects kernel command line & enables cloud-init   │
└─────────────────────────────┬──────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────┐
│ 2. Local Stage (cloud-init-local.service)              │
│    Reads local metadata (ConfigDrive, NoCloud).        │
│    Brings up loopback; blocks network initialization.  │
└─────────────────────────────┬──────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────┐
│ 3. Network Stage (cloud-init.service)                  │
│    Fetches remote metadata/user-data (IMDS / 169.254...).│
│    Applies network config (netplan/eni). Runs bootcmd. │
└─────────────────────────────┬──────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────┐
│ 4. Config Stage (cloud-config.service)                │
│    Executes modules: disk setup, user creation,        │
│    write_files, SSH host keys generation.             │
└─────────────────────────────┬──────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────┐
│ 5. Final Stage (cloud-final.service)                  │
│    Executes runcmd, scripts-per-boot, package installs,│
│    Chef/Puppet hooks. Writes /var/lib/cloud/data/result.│
└────────────────────────────────────────────────────────┘
```

1. **Generator (`cloud-init-generator`)**: Se ejecuta dentro del contexto temprano de initrd/systemd para determinar si `cloud-init` debe ser habilitado en la imagen iniciada.
2. **Local (`cloud-init-local.service`)**: Busca fuentes de datos locales (por ejemplo, ISOs de ConfigDrive adjuntas, volúmenes NoCloud). Configura el fallback de red local y bloquea la configuración de red hasta que se parsee la configuración.
3. **Network (`cloud-init.service`)**: Consulta los Instance Metadata Services remotos (IMDS en `169.254.169.254`), parsea vendor-data y user-data, y escribe las configuraciones finales de red del OS (por ejemplo, Netplan o systemd-networkd). Ejecuta los módulos tempranos de `bootcmd`.
4. **Config (`cloud-config.service`)**: Procesa directivas estructurales de configuración como `users`, `ssh_authorized_keys`, `write_files` y opciones de particionamiento de disco (`disk_setup`, `fs_setup`).
5. **Final (`cloud-final.service`)**: Ejecuta acciones en la fase tardía del boot incluyendo `packages`, `package_upgrade`, `runcmd` y scripts de usuario personalizados. Emite el archivo de estado del sistema (`/var/lib/cloud/data/status.json`).

#### User-Data vs. Metadata vs. Vendor-Data

* **Metadata**: Proporcionado por la plataforma cloud (por ejemplo, OpenStack Keystone/Nova o AWS EC2). Contiene atributos no sensibles de la instancia: `instance-id`, `hostname`, `local-ipv4`, `public-keys`, `ami-id`.
* **User-Data**: Proporcionado por el operador al lanzar la instancia. Contiene scripts personalizados o esquemas YAML de `cloud-config` ejecutados en el primer boot.
* **Vendor-Data**: Proporcionado por el proveedor cloud o creador de la imagen (imagebuilder) para aplicar imágenes base de seguridad, agentes de telemetría o cuentas administrativas por defecto sin sobrescribir el `user-data` suministrado por el usuario.

---

### 1.3 Infrastructure as Code y Mecánica de Orquestación: Terraform y APIs Cloud

La orquestación cloud automatiza la gestión de recursos mediante APIs RESTful (OpenStack Compute/Nova, Networking/Neutron, AWS EC2, VPC). Herramientas como HashiCorp Terraform implementan un motor de traducción de imperativo a declarativo.

```
┌─────────────────────────────────────────────────────────┐
│               Terraform Code (.tf files)                │
└────────────────────────────┬────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────┐
│        Terraform Core (Graph Builder Engine)            │
│  Calculates Directed Acyclic Graph (DAG) of dependency   │
└────────────────────────────┬────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────┐
│       Provider Plugin (e.g., terraform-provider-aws)    │
│  Translates HCL state delta to OpenAPI / AWS Query API   │
└────────────────────────────┬────────────────────────────┘
                             │ gRPC
                             ▼
┌─────────────────────────────────────────────────────────┐
│          Cloud Control Plane (AWS API / OpenStack)      │
│  Provisions Security Groups, Subnets, Instances, Disks  │
└────────────────────────────┬────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────┐
│              Target Cloud Infrastructure                │
└─────────────────────────────────────────────────────────┘
```

#### Estado de Terraform y Mecánica del Ciclo de Vida

* **Gestión de Estado (`terraform.tfstate`)**: Actúa como un registro privado que mapea identificadores HCL declarados con IDs Únicos reales del cloud (por ejemplo, AWS `i-0a12b34c56def7890` o UUIDs de OpenStack).
* **State Locking**: Previene condiciones de carrera por ejecución concurrente adquiriendo bloqueos explícitos en backends remotos (AWS S3 + DynamoDB, HashiCorp Consul o OpenStack Swift).
* **Drift Detection**: Durante `terraform plan`, Terraform consulta las APIs cloud en vivo mediante operaciones `Read()`, compara los atributos reales con el estado guardado y formula un árbol de diff estructural.
* **Evaluación del Grafo (DAG)**: Construye el orden de ejecución automáticamente basándose en referencias de recursos (por ejemplo, una Subnet depende de un VPC ID; una EC2 Instance depende de un Subnet ID).

---

## 2. Manifiestos de Producción y Código de Blueprint

### Blueprint 2.1: Manifiesto Multi-Parte de Cloud-Init en Producción (`cloud-config.yaml`)

Este manifiesto YAML sintácticamente válido configura el aprovisionamiento de usuarios del OS, la estructuración de directorios, el bastionado (hardening) del sistema, la configuración del entorno, el despliegue de paquetes y scripts de inicialización personalizados.

```yaml
#cloud-config
# ==============================================================================
# LPI 701-100 Production Cloud-Init Blueprint
# Objectives: 3.2 Cloud Deployment - System Initialization
# ==============================================================================

version: v1

# 1. User Account Provisioning & System Access Hardening
users:
  - default
  - name: sysadmin
    gecos: System Administrator
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: [sudo, docker, wheel]
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOm7Zp8q9rStuVwXyZ0123456789abcdefghijklmn sadmin@infra.company.internal

# 2. Package Repository & System Package Management
package_update: true
package_upgrade: true
packages:
  - apt-transport-https
  - ca-certificates
  - curl
  - gnupg
  - lsb-release
  - htop
  - net-tools
  - ufw

# 3. File System Creation & Custom File Injection
write_files:
  - path: /etc/sysctl.d/99-kubernetes-cri.conf
    permissions: '0644'
    owner: root:root
    content: |
      net.bridge.bridge-nf-call-iptables  = 1
      net.ipv4.ip_forward                 = 1
      net.bridge.bridge-nf-call-ip6tables = 1

  - path: /opt/app/bin/healthcheck.sh
    permissions: '0755'
    owner: sysadmin:sysadmin
    content: |
      #!/usr/bin/env bash
      set -euo pipefail
      echo "[HEALTHCHECK] Verifying node boot initialization..."
      curl -f http://localhost:8080/health || exit 1
      echo "[HEALTHCHECK] Node is healthy."

  - path: /etc/systemd/system/node-exporter.service
    permissions: '0644'
    owner: root:root
    content: |
      [Unit]
      Description=Node Exporter Agent
      After=network.target

      [Service]
      Type=simple
      User=nobody
      ExecStart=/usr/local/bin/node_exporter

      [Install]
      WantedBy=multi-user.target

# 4. Command Execution Pipeline (Run in cloud-final.service stage)
runcmd:
  - [ sysctl, --system ]
  - [ systemctl, daemon-reload ]
  - [ ufw, allow, "22/tcp" ]
  - [ ufw, allow, "80/tcp" ]
  - [ ufw, allow, "443/tcp" ]
  - [ ufw, --force, enable ]
  - echo "Cloud-Init execution completed on $(date -u)" > /var/log/cloud-init-bootstrap-complete.log

# 5. Output Management & Telemetry Logging
output:
  all: '| tee -a /var/log/cloud-init-output.log'
```

---

### Blueprint 2.2: Módulo Terraform de Infrastructure-as-Code para Producción

Este blueprint de Terraform de múltiples archivos construye una VPC aislada, subnet, gateway, tabla de ruteo, security group y una instancia de cómputo IaaS con el payload de `cloud-config` user-data inyectado.

#### `variables.tf`
```hcl
variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = "Target AWS Region for deployment."
}

variable "environment" {
  type        = string
  default     = "production"
  description = "Deployment lifecycle stage identifier."
}

variable "vpc_cidr" {
  type        = string
  default     = "10.100.0.0/16"
  description = "Base CIDR block for the Virtual Private Cloud."
}

variable "public_subnet_cidr" {
  type        = string
  default     = "10.100.1.0/24"
  description = "CIDR block for the public network subnet."
}

variable "instance_type" {
  type        = string
  default     = "t3.micro"
  description = "Compute instance hardware profile."
}
```

#### `main.tf`
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
  default_tags {
    tags = {
      Environment = var.environment
      ManagedBy   = "Terraform"
      Certification = "LPI-701-100"
    }
  }
}

# Fetch latest Ubuntu 22.04 LTS AMI from canonical
data "aws_ami" "ubuntu_lts" {
  most_recent = true
  owners      = ["099720109477"] # Canonical ID

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# 1. Network Topology Definition
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.environment}-vpc"
  }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.environment}-igw"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  map_public_ip_on_launch = true
  availability_zone       = "${var.aws_region}a"

  tags = {
    Name = "${var.environment}-public-subnet"
  }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "${var.environment}-public-rt"
  }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public_rt.id
}

# 2. Firewall / Security Group Definition
resource "aws_security_group" "web_sg" {
  name        = "${var.environment}-web-sg"
  description = "Control ingress/egress traffic for cloud instances."
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Allow SSH from trusted management sources"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow HTTP inbound"
    from_port   = 80
    to_port     = 80
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
    Name = "${var.environment}-web-sg"
  }
}

# 3. Compute Instance Provisioning with Cloud-Init Payload
resource "aws_instance" "web_server" {
  ami                   = data.aws_ami.ubuntu_lts.id
  instance_type         = var.instance_type
  subnet_id             = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.web_sg.id]

  user_data = file("${path.module}/cloud-config.yaml")

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    encrypted             = true
    delete_on_termination = true
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${var.environment}-web-server"
  }
}
```

#### `outputs.tf`
```hcl
output "instance_id" {
  value       = aws_instance.web_server.id
  description = "AWS EC2 Unique Instance Identifier."
}

output "public_ip" {
  value       = aws_instance.web_server.public_ip
  description = "Assigned IPv4 Public Address."
}

output "vpc_id" {
  value       = aws_vpc.main.id
  description = "Provisioned Virtual Private Cloud Identifier."
}
```

---

## 3. Ejercicios Prácticos Guiados de Laboratorio

---

### Laboratorio 3.2.1: Diagnóstico Avanzado del Motor Cloud-Init y Perfilado de Etapas de Boot

#### Objetivo
Comprender el funcionamiento interno de ejecución de `cloud-init`, analizar los cuellos de botella en la línea de tiempo del boot, inspeccionar los estados de la caché local, consultar el servicio de metadatos (IMDSv2) y forzar una reejecución limpia y controlada de etapas en un servidor Linux cloud en ejecución.

#### Secuencia de Ejecución Paso a Paso

1. **Verificar el estado general de ejecución de `cloud-init` y el estado detallado del sistema.**
   Consultar el archivo de estado emitido por `cloud-final.service`.
   ```bash
   sudo cloud-init status --long
   ```
   *Expected Execution Output:*
   ```text
   status: done
   extended_status: done
   boot_status_code: enabled-by-generator
   detail:
   DataSourceCloudInitLocal: DataSourceNoCloud [seed=/var/lib/cloud/seed/nocloud][token=/var/lib/cloud/seed/nocloud]
   ```

2. **Analizar las métricas de rendimiento de cada etapa y los cuellos de botella del boot.**
   Usar el subcomando de diagnóstico `cloud-init analyze` para generar un desglose de rendimiento de alta precisión de cada etapa de boot.
   ```bash
   cloud-init analyze show
   ```
   *Expected Execution Output:*
   ```text
   -- Boot Record 01 --
   The total time elapsed since boot is 18.412s
   ------------------------------------------------------------
   01.002s (init-local)       : starting module init-local
   03.451s (init-network)     : starting search for data-sources
   04.810s (init-network)     : found data-source DataSourceNoCloud
   08.120s (config-modules)   : starting module write_files
   12.304s (config-modules)   : starting module package_update
   18.390s (final-modules)    : starting module runcmd
   ------------------------------------------------------------
   ```

3. **Inspeccionar los logs de bajo nivel subyacentes para rastrear errores de ejecución o detalles de los pasos.**
   Localizar las salidas de los módulos y los streams de stdout/stderr del sistema.
   ```bash
   tail -n 25 /var/log/cloud-init.log
   ```
   *Expected Execution Output:*
   ```text
   2026-08-07 04:55:01,102 - handlers.py[DEBUG]: finish: init-network/config-write_files: SUCCESS: config-write_files ran successfully
   2026-08-07 04:55:02,410 - cc_package_update.py[DEBUG]: Running package update pipeline...
   2026-08-07 04:55:08,771 - cc_runcmd.py[DEBUG]: Running command ['sysctl', '--system']
   2026-08-07 04:55:09,004 - util.py[DEBUG]: Cloud-init v. 23.2.2-0ubuntu1~22.04.1 finished at Fri, 07 Aug 2026 04:55:09 +0000. Datasource DataSourceNoCloud. Up 18.41 seconds
   ```

4. **Consultar el servicio local de metadatos (IMDSv2) mediante endpoints REST HTTP.**
   Obtener un token de sesión IMDSv2 y consultar los metadatos de la instancia.
   ```bash
   TOKEN=$(curl -s -S -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
   curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id
   echo ""
   curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4
   echo ""
   ```
   *Expected Execution Output:*
   ```text
   i-03f41a8799b6c4e01
   10.100.1.45
   ```

5. **Realizar una purga controlada de `cloud-init` y forzar la reejecución en el próximo reinicio.**
   Limpiar los metadatos en caché, eliminar los logs de ejecución y purgar los artefactos de estado de la instancia ubicados en `/var/lib/cloud/`.
   ```bash
   sudo cloud-init clean --logs
   ls -la /var/lib/cloud/instance
   ```
   *Expected Execution Output:*
   ```text
   ls: cannot access '/var/lib/cloud/instance': No such file or directory
   ```

---

#### Preguntas de Verificación — Laboratorio 3.2.1

**Pregunta 1:** ¿Durante qué etapa específica de boot de `cloud-init` se ejecutan módulos como `disk_setup`, `fs_setup` y `users` personalizados, y qué servicio de systemd gestiona esta etapa?
* A) Etapa Local (`cloud-init-local.service`)
* B) Etapa Network (`cloud-init.service`)
* C) Etapa Config (`cloud-config.service`)
* D) Etapa Final (`cloud-final.service`)

**Pregunta 2:** Un SRE nota que un script dentro de la directiva `runcmd` no logró completarse exitosamente durante el primer boot. ¿Qué archivo de log contiene la salida estándar (stdout) y el error estándar (stderr) combinados de los scripts ejecutados por `runcmd`?
* A) `/var/log/cloud-init.log`
* B) `/var/log/cloud-init-output.log`
* C) `/var/log/syslog`
* D) `/var/lib/cloud/data/status.json`

**Pregunta 3:** ¿Cuál es la función técnica del comando `sudo cloud-init clean --logs`?
* A) Desinstala el paquete python de `cloud-init` y purga todos los archivos de configuración de `/etc/cloud/`.
* B) Elimina los datos en caché de tiempo de ejecución en `/var/lib/cloud/` y los archivos de log en `/var/log/cloud-init*`, permitiendo que `cloud-init` se vuelva a ejecutar en un boot posterior.
* C) Parsea `cloud-config.yaml` en busca de errores de sintaxis sin ejecutar ningún comando.
* D) Restablece el hostname de la instancia por defecto y libera la concesión de IP de DHCP.

---

### Laboratorio 3.2.2: Gestión Declarativa de Infraestructura con Terraform y Remediación de Drift

#### Objetivo
Inicializar un directorio de Terraform de producción, planificar y aprovisionar recursos cloud, inspeccionar las dinámicas del grafo de estado, simular drift de estado fuera de banda y reconciliar los recursos reales utilizando planes de ejecución HCL declarativos.

#### Secuencia de Ejecución Paso a Paso

1. **Inicializar el directorio de trabajo y cargar los binarios de los proveedores.**
   Descargar los plugins de proveedores definidos en `main.tf`.
   ```bash
   terraform init
   ```
   *Expected Execution Output:*
   ```text
   Initializing the backend...

   Initializing provider plugins...
   - Finding hashicorp/aws versions matching "~> 5.0"...
   - Installing hashicorp/aws v5.35.0...
   - Installed hashicorp/aws v5.35.0 (signed by HashiCorp)

   Terraform has been successfully initialized!
   ```

2. **Generar e inspeccionar un plan de ejecución.**
   Ejecutar `terraform plan` para construir el Grafo Acíclico Dirigido (DAG) y enviar el plan de creación de recursos a un archivo binario (`tfplan`).
   ```bash
   terraform plan -out=tfplan
   ```
   *Expected Execution Output:*
   ```text
   Terraform will perform the following actions:

     # aws_instance.web_server will be created
     + resource "aws_instance" "web_server" {
         + ami                          = "ami-0c7217cdde317cfec"
         + instance_type                = "t3.micro"
         + user_data                    = "a4b1c2..." # hash calculated
         + root_block_device {
             + delete_on_termination = true
             + encrypted             = true
             + volume_size           = 20
             + volume_type           = "gp3"
           }
       }

     # aws_vpc.main will be created
     + resource "aws_vpc" "main" {
         + cidr_block           = "10.100.0.0/16"
         + enable_dns_hostnames = true
       }

   Plan: 6 to add, 0 to change, 0 to destroy.
   ------------------------------------------------------------------------
   Saved the plan to: tfplan
   ```

3. **Aplicar el plan de ejecución para aprovisionar recursos.**
   Aplicar el plan binario compilado `tfplan`.
   ```bash
   terraform apply "tfplan"
   ```
   *Expected Execution Output:*
   ```text
   aws_vpc.main: Creating...
   aws_vpc.main: Creation complete after 3s [id=vpc-08f3214abc]
   aws_internet_gateway.gw: Creating...
   aws_subnet.public: Creating...
   aws_internet_gateway.gw: Creation complete after 2s [id=igw-09912a]
   aws_subnet.public: Creation complete after 3s [id=subnet-01123bc]
   aws_security_group.web_sg: Creating...
   aws_security_group.web_sg: Creation complete after 2s [id=sg-0a887ff]
   aws_instance.web_server: Creating...
   aws_instance.web_server: Still creating... [10s elapsed]
   aws_instance.web_server: Creation complete after 14s [id=i-03f41a8799b6c4e01]

   Apply complete! Resources: 6 added, 0 changed, 0 destroyed.

   Outputs:
   instance_id = "i-03f41a8799b6c4e01"
   public_ip = "54.210.12.88"
   vpc_id = "vpc-08f3214abc"
   ```

4. **Inspeccionar el mapeo de estado de los recursos.**
   Verificar cómo se correlacionan los nombres lógicos de recursos HCL con los IDs reales de la infraestructura Cloud dentro de `terraform.tfstate`.
   ```bash
   terraform state list
   terraform state show aws_instance.web_server
   ```
   *Expected Execution Output:*
   ```text
   aws_internet_gateway.gw
   aws_instance.web_server
   aws_route_table.public_rt
   aws_route_table_association.public_assoc
   aws_security_group.web_sg
   aws_subnet.public
   aws_vpc.main

   # aws_instance.web_server:
   resource "aws_instance" "web_server" {
       ami                          = "ami-0c7217cdde317cfec"
       arn                          = "arn:aws:ec2:us-east-1:123456789012:instance/i-03f41a8799b6c4e01"
       id                           = "i-03f41a8799b6c4e01"
       instance_state               = "running"
       instance_type                = "t3.micro"
       public_ip                    = "54.210.12.88"
       subnet_id                    = "subnet-01123bc"
       vpc_security_group_ids       = [
           "sg-0a887ff",
       ]
   }
   ```

5. **Simular drift de infraestructura y realizar remediación automatizada.**
   Simular una modificación manual fuera de banda (por ejemplo, modificar las etiquetas del security group o agregar una regla fuera de banda mediante la AWS CLI). Luego ejecutar `terraform plan` para verificar el motor de detección de drift de Terraform.
   ```bash
   # Simulate out-of-band manual modification using AWS CLI
   aws ec2 create-tags --resources sg-0a887ff --tags Key=Environment,Value=staging-manual-drift

   # Execute drift analysis
   terraform plan
   ```
   *Expected Execution Output:*
   ```text
   Note: Objects have changed outside of Terraform

   Terraform detected the following changes made outside of Terraform since the last "terraform apply":

     # aws_security_group.web_sg has changed
   ~ resource "aws_security_group" "web_sg" {
         id                     = "sg-0a887ff"
       ~ tags                   = {
           ~ "Environment" = "staging-manual-drift" -> "production"
             # (2 unchanged elements hidden)
         }
         # (7 unchanged attributes hidden)
     }

   Unless you have made equivalent changes to your configuration, your plan contents are targeted to
   restore the configured values.

   Plan: 0 to add, 1 to change, 0 to destroy.
   ```

---

#### Preguntas de Verificación — Laboratorio 3.2.2

**Pregunta 4:** ¿Qué comando permite a un SRE inspeccionar los atributos actuales de un recurso gestionado almacenado dentro del archivo de estado sin abrir manualmente el archivo JSON crudo `terraform.tfstate`?
* A) `terraform inspect aws_instance.web_server`
* B) `terraform state show aws_instance.web_server`
* C) `terraform get aws_instance.web_server`
* D) `terraform show -json`

**Pregunta 5:** ¿Qué ocurre durante `terraform plan` cuando el estado real de la infraestructura difiere de la configuración definida en los archivos `.tf` y almacenada en `.tfstate`?
* A) Terraform arroja una excepción irrecuperable y aborta la ejecución.
* B) Terraform actualiza los archivos de código HCL locales automáticamente para coincidir con el estado real del proveedor cloud.
* C) Terraform realiza una operación de refresco contra las APIs del proveedor, detecta el drift de estado e imprime un plan de ejecución para volver a alinear la infraestructura real con las declaraciones HCL.
* D) Terraform elimina el archivo de estado y realiza una reimportación completa de todos los recursos.

**Pregunta 6:** Un arquitecto establece `create_before_destroy = true` dentro del bloque `lifecycle` de un recurso `aws_instance` en HCL. ¿Cuál es el efecto operacional cuando una modificación requiere reemplazar la instancia de cómputo?
* A) Terraform destruye la instancia existente primero, espera 5 minutos y luego lanza la instancia de reemplazo.
* B) Terraform aprovisiona la nueva instancia de reemplazo primero, y solo destruye la instancia antigua después de que la nueva haya sido creada, minimizando el tiempo de inactividad del servicio.
* C) Terraform evita que la instancia sea eliminada o modificada bajo cualquier circunstancia.
* D) Terraform crea un respaldo de snapshot del volumen EBS raíz adjunto antes de destruir la instancia.

---

## 4. Respuestas de Verificación y Explicaciones

<details>
<summary>Hacé clic para desplegar las Respuestas y Explicaciones Arquitectónicas Detalladas</summary>

### Respuesta 1: C
**Explicación:**
`cloud-init` se ejecuta en cuatro etapas principales de boot secuenciales gestionadas por servicios de systemd distintos:
1. `cloud-init-local.service` (Etapa Local): Localiza metadatos locales/ConfigDrive sin dependencias completas de red.
2. `cloud-init.service` (Etapa Network): Obtiene metadatos remotos a través de HTTP (`169.254.169.254`), escribe configuraciones de red del OS (Netplan/eni) y ejecuta `bootcmd` temprano.
3. `cloud-config.service` (Etapa Config): Ejecuta módulos de configuración estructurales incluyendo `disk_setup`, `fs_setup`, `mounts`, `users`, `groups` y `write_files`.
4. `cloud-final.service` (Etapa Final): Ejecuta acciones de aprovisionamiento en etapa tardía como `packages`, `package_upgrade` y scripts `runcmd`.

*Ref: LPI DevOps Tools Engineer Objetivos 3.2 — Bootstrapping de instancias con cloud-init.*

---

### Respuesta 2: B
**Explicación:**
* `/var/log/cloud-init-output.log` captura los streams de salida estándar (`stdout`) y error estándar (`stderr`) crudos generados por subcomandos, scripts y módulos ejecutados durante la fase de inicialización (incluyendo entradas de `runcmd` y scripts de shell de user-data).
* `/var/log/cloud-init.log` contiene registros detallados de depuración (debug trace) producidos internamente por los handlers del motor Python de `cloud-init`, mostrando transiciones de estado internas de cada etapa con marcas de tiempo.

*Ref: LPI DevOps Tools Engineer Objetivos 3.2 — Depuración de logs de cloud-init.*

---

### Respuesta 3: B
**Explicación:**
El comando `cloud-init clean` limpia los metadatos en caché específicos de la instancia almacenados bajo `/var/lib/cloud/` (tales como `/var/lib/cloud/instance`, `/var/lib/cloud/instances/` y cachés de datos seed). Al pasar `--logs` también se purgan los logs de ejecución históricos de `/var/log/cloud-init.log` y `/var/log/cloud-init-output.log`. En el siguiente boot del sistema, `cloud-init` detecta la ausencia de marcadores de estado y vuelve a activar el bootstrapping completo de la instancia como si fuera una VM recién lanzada.

*Ref: LPI DevOps Tools Engineer Objetivos 3.2 — Re-bootstrapping y pruebas de inicialización de instancias.*

---

### Respuesta 4: B
**Explicación:**
El subcomando `terraform state show <DIRECCION_DE_RECURSO>` lee la entrada de estado registrada desde el backend de estado para un identificador de recurso específico y muestra sus atributos de metadatos clave-valor en un formato legible. `terraform state list` enumera todas las direcciones de recursos rastreados, mientras que `terraform state show` muestra desgloses detallados de atributos.

*Ref: LPI DevOps Tools Engineer Objetivos 3.2 — Gestión de estado de Terraform.*

---

### Respuesta 5: C
**Explicación:**
Terraform sigue un modelo de diseño declarativo. Durante `terraform plan`:
1. Consulta las APIs del proveedor (operaciones `Read()`) para leer el estado actual de la infraestructura.
2. Compara el estado en vivo contra el estado deseado definido en los archivos HCL `.tf` y almacenado en `.tfstate`.
3. Construye un grafo de ejecución que contiene el delta estructural (drift) y muestra las acciones específicas de creación (`+`), actualización (`~`) o destrucción (`-`) requeridas para reconciliar la infraestructura real con la configuración declarada.

*Ref: LPI DevOps Tools Engineer Objetivos 3.2 — Ciclo de vida de estado y detección de drift en Infrastructure as Code.*

---

### Respuesta 6: B
**Explicación:**
Por defecto, cuando una modificación de atributos de un recurso requiere el reemplazo del recurso (como cambiar una AMI ID o VPC subnet en ciertos recursos cloud), Terraform destruye el recurso existente primero y luego aprovisiona el nuevo reemplazo (`destroy-before-create`). Establecer `lifecycle { create_before_destroy = true }` invierte este orden: Terraform aprovisiona primero el recurso de reemplazo, actualiza las referencias dependientes y posteriormente elimina el recurso legado, reduciendo el tiempo de inactividad operativo.

*Ref: LPI DevOps Tools Engineer Objetivos 3.2 — Aprovisionamiento avanzado de IaC y restricciones del ciclo de vida.*

</details>

---

## 5. Referencias Oficiales y Enlaces de Documentación

* [LPI DevOps Tools Engineer Exam 701-100 Objectives](https://wiki.lpi.org/wiki/DevOps_Tools_Engineer_Objectives_V1.0)
* [Linux Professional Institute Official Overview](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
* [Official Cloud-Init Documentation & Boot Stages](https://cloudinit.readthedocs.io/en/latest/explanation/boot.html)
* [HashiCorp Terraform AWS Provider Documentation](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
* [OpenStack Compute (Nova) Command-Line Documentation](https://docs.openstack.org/nova/latest/)
* [AWS EC2 Instance Metadata Service (IMDSv2) Guide](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html)