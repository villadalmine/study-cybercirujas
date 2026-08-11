# Tema 353.1 — Herramientas de gestión de la nube

**Certificación:** LPIC-3 305 · **Examen:** 305-300 (v3.0) · **Peso del objetivo:** 3.33
**Perfil:** SRE / Arquitecto de Plataforma · **Idioma:** Español

> **Alcance del objetivo (LPI 353.1).** Comprender las ofertas comunes en las nubes públicas; conocimiento básico de las funcionalidades de **OpenStack** y **Terraform**; nociones sobre **CloudStack**, **Eucalyptus** y **OpenNebula**. Términos: IaaS/PaaS/SaaS, nube pública/privada/híbrida, OpenStack, Terraform, CloudStack, Eucalyptus, OpenNebula.

---

## 1. El problema en producción: qué gestiona realmente la «gestión de la nube»

Un SRE hereda una flota, no un único host. En cuanto tenés más de un puñado de máquinas virtuales, los modos de fallo operativos dejan de ser *«la VM está caída»* y pasan a ser:

- **Deriva de configuración (configuration drift).** La VM n.º 47 se parcheó a mano a las 03:00 durante un incidente y ahora es el único host de la flota que sigue arrancando. Nadie sabe por qué es diferente y nadie puede reconstruirlo.
- **Infraestructura copo de nieve (snowflake).** Cada entorno (dev, staging, prod) se creó a golpe de clic en una consola web por distintas personas en distintos momentos. *Se supone* que son idénticos. No lo son, y la divergencia solo sale a la luz durante un failover.
- **Sin reproducibilidad / sin rollback.** No hay ningún artefacto que diga «esto es lo que es prod». No podés hacerle un diff, revisarlo ni recrearlo en otra región tras la pérdida de un datacenter.
- **Radio de impacto (blast radius) indefinido.** Un cambio en una red compartida o en un security group se aplica en vivo, a mano, sin plan y sin una vista previa de qué va a tocar.

Las herramientas de gestión de la nube existen para convertir la infraestructura de un *sistema operado manualmente* en un *sistema definido de forma declarativa, versionado y reconciliado por máquina*. Se dividen limpiamente en **dos capas arquitectónicas**, y confundirlas es el error conceptual más común que castiga el examen (y la producción):

| Capa | Pregunta que responde | Miembros del objetivo 353.1 |
|---|---|---|
| **Plataforma de nube (el plano de control / el propio IaaS)** | «¿De dónde *provienen* el cómputo, la red y el almacenamiento?» **Es** la nube: corre sobre tu hardware, expone una API y reparte VMs, redes y volúmenes. | **OpenStack, CloudStack, OpenNebula, Eucalyptus** |
| **Herramienta de aprovisionamiento / IaC (el cliente)** | «¿Cómo *describo y manejo* recursos sobre una API de nube, de forma declarativa, reproducible y revisable?» No posee hardware; habla con la API de una nube. | **Terraform** |

OpenStack **es una nube**. Terraform **maneja** una nube. Ejecutás Terraform *contra* OpenStack (o AWS, o Azure). No ejecutás OpenStack contra Terraform. Tené presente esta asimetría en cada comparación que sigue.

---

## 2. Modelos de servicio y de despliegue (IaaS / PaaS / SaaS · pública / privada / híbrida)

### 2.1 Modelos de servicio — la estratificación del NIST

El modelo de servicio define **dónde se sitúa la frontera de gestión**, es decir, qué opera el proveedor y qué operás vos. Es la línea de «responsabilidad compartida».

| Capa que consumís | Modelo | El proveedor opera | Vos operás | Ejemplos canónicos |
|---|---|---|---|---|
| Hardware virtual (cómputo, almacenamiento de bloque/objeto, redes virtuales) | **IaaS** | DC físico, hipervisor, red del host, backend de almacenamiento | SO, parcheo, runtime, app, datos, reglas de firewall | OpenStack (Nova), AWS EC2, GCP Compute Engine |
| Runtime / plataforma gestionada | **PaaS** | Todo hasta el SO + runtime + autoescalado incluidos | Código de la app, config, datos | Cloud Foundry, OpenShift (como plataforma), Heroku, App Engine |
| Aplicación terminada | **SaaS** | Todo el stack | Solo tus datos y la configuración de usuario | Gmail, Salesforce, Nextcloud (alojado) |

```
     control moves DOWN ▼                            responsibility moves UP ▲
  ┌───────────┬───────────┬───────────┐
  │   IaaS    │   PaaS    │   SaaS    │
  ├───────────┼───────────┼───────────┤
  │ Data      │ Data      │ Data      │   ← you
  │ App       │ App       │ ░App░     │
  │ Runtime   │ ░Runtime░ │ ░Runtime░ │
  │ OS        │ ░OS░      │ ░OS░      │
  │ Virt.     │ ░Virt.░   │ ░Virt.░   │   ░ = provider-operated
  │ HW/Net    │ ░HW/Net░  │ ░HW/Net░  │
  └───────────┴───────────┴───────────┘
```

**Por qué le importa a un SRE:** el modelo determina tu superficie de guardia. En IaaS, un CVE del kernel es *tu* aviso a las 2 de la madrugada; en PaaS es el del proveedor. LPIC-3 305 vive casi por completo en la capa **IaaS**, porque es la capa que implementan OpenStack/CloudStack/OpenNebula/Eucalyptus.

### 2.2 Modelos de despliegue

| Modelo | Dónde corre | Tenencia | Motivación principal | Compromiso para el SRE |
|---|---|---|---|---|
| **Nube pública** | DC del proveedor | Multi-inquilino | Capacidad elástica, opex, sin CapEx | Residencia de datos, coste de egreso, vecino ruidoso (noisy-neighbor), dependencia del proveedor (vendor lock-in) |
| **Nube privada** | Tu DC (o dedicado) | Una sola organización | Soberanía de datos, regulación, coste predecible a escala | Sos responsable del uptime del plano de control: OpenStack se convierte en *tu* pager |
| **Nube híbrida** | Ambas, integradas | Mixta | Burst a la pública, DR, migración gradual | Complejidad de red + federación de identidad; dos dominios de fallo |
| **Multinube** | ≥2 proveedores públicos | Mixta | Evitar el lock-in, lo mejor de cada proveedor | Abstracciones de mínimo común denominador; esta es la propuesta de valor central de Terraform |

El eje privada/híbrida es precisamente *por qué existe OpenStack*: es la forma de construir una **API IaaS al estilo de la nube pública sobre hardware propio**, para que el mismo instrumental (Terraform, Heat, cloud-init) funcione tanto on-prem como en una nube pública.

---

## 3. OpenStack — el IaaS privado open source de referencia

OpenStack es **conocimiento básico de funcionalidades** en el examen, pero como Arquitecto de Plataforma debés entender la descomposición de su plano de control, porque cada fallo operativo se corresponde con un componente.

### 3.1 Arquitectura: un conjunto de servicios cooperantes tras una identidad y un bus de mensajes

OpenStack no es un único programa; es una **colección de servicios independientes**, cada uno exponiendo una API REST, coordinados a través de una **cola de mensajes** compartida (AMQP — RabbitMQ por defecto) y una **base de datos SQL** compartida (MariaDB/Galera en producción para HA). Cada llamada a la API la autentica **Keystone**.

```
                         ┌──────────────────────────────────────────┐
        openstack CLI /  │              Horizon (Dashboard)          │
        Terraform / Heat └───────────────────┬──────────────────────┘
                    │                         │  (all REST, token-authed)
                    ▼                         ▼
          ┌───────────────┐  auth token  ┌─────────────────────────────────┐
          │   Keystone    │◄────────────►│  Nova  Neutron  Glance  Cinder   │
          │  (Identity,   │              │  Swift  Placement  Heat  Octavia │
          │  catalog,     │              │  Ironic  Designate  Barbican ... │
          │  tokens)      │              └───────────────┬─────────────────┘
          └───────────────┘                              │
                    ▲                                     │ RPC over AMQP
                    │                                     ▼
          ┌─────────┴───────────────────────────────────────────────────┐
          │   RabbitMQ (message bus)      MariaDB/Galera (state)          │
          └───────────────────────────────────────────────────────────────┘
                                       │
        ┌──────────────────┬───────────┴──────────┬──────────────────┐
        ▼                  ▼                       ▼                  ▼
   nova-compute       neutron agents          cinder-volume      compute nodes
   (libvirt/KVM)      (OVS/OVN, L3, DHCP)     (LVM/Ceph)         (hypervisors)
```

### 3.2 Los servicios centrales que debés saber nombrar y ubicar

| Servicio | Nombre del proyecto | Función (primitiva IaaS que provee) | Servicio análogo de AWS |
|---|---|---|---|
| Identidad | **Keystone** | AuthN/AuthZ, catálogo de servicios, emisión de tokens, proyectos/dominios | IAM + STS |
| Cómputo | **Nova** | Ciclo de vida de las instancias VM, planificación (scheduling) sobre hipervisores (libvirt/KVM) | EC2 |
| Placement | **Placement** | Rastrea el inventario/uso de recursos; el scheduler de Nova lo consulta | (interno) |
| Red | **Neutron** | Redes virtuales, subredes, routers, puertos, SGs, floating IPs (OVS/OVN) | VPC |
| Imagen | **Glance** | Almacena/sirve imágenes base de VM (qcow2, raw) | registro de AMI |
| Almacenamiento de bloque | **Cinder** | Volúmenes de bloque persistentes conectables a instancias | EBS |
| Almacenamiento de objetos | **Swift** | Almacén de objetos con consistencia eventual (tipo S3) | S3 |
| Orquestación | **Heat** | Stacks declarativos vía plantillas HOT; IaC nativo | CloudFormation |
| Dashboard | **Horizon** | Interfaz web sobre las APIs | Consola |
| Balanceo de carga | **Octavia** | LBaaS (Amphora VMs / OVN) | ELB/ALB |
| Bare metal | **Ironic** | Aprovisiona máquinas físicas a través de la API de Nova | — |
| DNS | **Designate** | DNSaaS | Route 53 |
| Gestión de claves | **Barbican** | Secretos/claves, cifrado de volúmenes | KMS |
| Telemetría | **Ceilometer/Gnocchi/Aodh** | Medición, series temporales, alarmas (impulsa el autoescalado) | CloudWatch |

**Cadencia de releases (contexto para el versionado).** OpenStack publica cada 6 meses con un nombre en clave alfabético, y luego basado en fecha: … *Wallaby, Xena, Yoga, Zed*, y después el cambio al esquema por fecha — *2023.1 Antelope, 2023.2 Bobcat, 2024.1 Caracal, 2024.2 Dalmatian, …*. Las releases alternas son objetivos **SLURP** («Skip-Level Upgrade Release Process»), que permiten a los operadores actualizar una vez al año a través de dos releases en lugar de cada seis meses — una preocupación real de producción para las ventanas de mantenimiento del plano de control.

### 3.3 Autenticación y el cliente unificado `openstack`

Todo empieza por cargar (source) las credenciales. El mecanismo canónico es un **archivo RC** (o `clouds.yaml`) que rellena las variables de entorno `OS_*` que consumen la CLI y el provider de Terraform.

```bash
$ cat admin-openrc.sh
export OS_AUTH_URL=https://keystone.cloud.example.net:5000/v3
export OS_IDENTITY_API_VERSION=3
export OS_PROJECT_NAME=admin
export OS_PROJECT_DOMAIN_NAME=Default
export OS_USERNAME=admin
export OS_USER_DOMAIN_NAME=Default
export OS_PASSWORD=REDACTED
export OS_REGION_NAME=RegionOne

$ source admin-openrc.sh
$ openstack token issue
+------------+------------------------------------------------------------+
| Field      | Value                                                      |
+------------+------------------------------------------------------------+
| expires    | 2026-08-11T14:07:52+0000                                   |
| id         | gAAAAABm...q7Xk                                            |
| project_id | 4e2c1f0a9b7d4c6e8a1b2c3d4e5f6a7b                           |
| user_id    | 9f8e7d6c5b4a39281706f5e4d3c2b1a0                           |
+------------+------------------------------------------------------------+
```

Descubrir el despliegue — los dos comandos que ejecutás primero en cualquier OpenStack desconocido:

```bash
$ openstack service list
+----------------------------------+-----------+----------------+
| ID                               | Name      | Type           |
+----------------------------------+-----------+----------------+
| 1b0f...                          | keystone  | identity       |
| 2c1a...                          | nova      | compute        |
| 3d2b...                          | placement | placement      |
| 4e3c...                          | neutron   | network        |
| 5f4d...                          | glance    | image          |
| 6a5e...                          | cinder    | block-storage  |
| 7b6f...                          | swift     | object-store   |
| 8c70...                          | heat      | orchestration  |
+----------------------------------+-----------+----------------+

$ openstack endpoint list --service compute
+--------+-----------+--------------+--------------+---------+-----------+-------------------------------------------+
| ID     | Region    | Service Name | Service Type | Enabled | Interface | URL                                       |
+--------+-----------+--------------+--------------+---------+-----------+-------------------------------------------+
| a1b2.. | RegionOne | nova         | compute      | True    | public    | https://nova.cloud.example.net:8774/v2.1  |
| c3d4.. | RegionOne | nova         | compute      | True    | internal  | http://10.0.0.11:8774/v2.1                |
| e5f6.. | RegionOne | nova         | compute      | True    | admin     | http://10.0.0.11:8774/v2.1                |
+--------+-----------+--------------+--------------+---------+-----------+-------------------------------------------+
```

Inspeccionar la capacidad de cómputo (la primera comprobación de salud de un Arquitecto de Plataforma):

```bash
$ openstack hypervisor list
+----+---------------------+-----------------+--------------+-------+
| ID | Hypervisor Hostname | Hypervisor Type | Host IP      | State |
+----+---------------------+-----------------+--------------+-------+
|  1 | cmp01.cloud.local   | QEMU            | 10.0.0.21    | up    |
|  2 | cmp02.cloud.local   | QEMU            | 10.0.0.22    | up    |
|  3 | cmp03.cloud.local   | QEMU            | 10.0.0.23    | down  |
+----+---------------------+-----------------+--------------+-------+

$ openstack flavor list
+----+-----------+-------+------+-----------+-------+-----------+
| ID | Name      |   RAM | Disk | Ephemeral | VCPUs | Is Public |
+----+-----------+-------+------+-----------+-------+-----------+
| 1  | m1.small  |  2048 |   20 |         0 |     1 | True      |
| 2  | m1.medium |  4096 |   40 |         0 |     2 | True      |
| 3  | m1.large  |  8192 |   80 |         0 |     4 | True      |
+----+-----------+-------+------+-----------+-------+-----------+
```

Lanzar una instancia de forma imperativa (lo que reemplaza el IaC):

```bash
$ openstack server create \
    --image ubuntu-22.04 \
    --flavor m1.small \
    --network private-net \
    --key-name sre-key \
    --security-group web-sg \
    --user-data cloud-init.yaml \
    web01
+-------------------------------------+-----------------------------------------------+
| Field                               | Value                                         |
+-------------------------------------+-----------------------------------------------+
| OS-DCF:diskConfig                   | MANUAL                                         |
| OS-EXT-STS:power_state              | NOSTATE                                        |
| OS-EXT-STS:vm_state                 | building                                      |
| id                                  | 7c9e6679-7425-40de-944b-e07fc1f90ae7          |
| name                                | web01                                         |
| status                              | BUILD                                         |
+-------------------------------------+-----------------------------------------------+

$ openstack server list
+--------+-------+--------+----------------------------------+--------------+----------+
| ID     | Name  | Status | Networks                         | Image        | Flavor   |
+--------+-------+--------+----------------------------------+--------------+----------+
| 7c9e.. | web01 | ACTIVE | private-net=192.168.100.14       | ubuntu-22.04 | m1.small |
+--------+-------+--------+----------------------------------+--------------+----------+
```

### 3.4 Heat — el IaC *nativo* de OpenStack (una plantilla HOT completa y válida)

Heat consume YAML **HOT** (Heat Orchestration Template) y lo materializa como un **stack**. A diferencia de Terraform, Heat es un *servicio dentro de la nube* — el estado vive del lado del servidor en la BD de Heat, y Heat puede conectar el autoescalado mediante alarmas de Aodh. La plantilla de abajo es completa y sintácticamente válida: construye una red de tenant aislada, un router hacia la red externa, un security group y un servidor con una floating IP.

```yaml
heat_template_version: 2018-08-31

description: >
  Reference web tier: private network + router to the external network,
  a security group allowing SSH/HTTP/HTTPS, one Nova instance and a
  floating IP for external reachability. Demonstrates parameters,
  intrinsic functions (get_param / get_resource / get_attr) and outputs.

parameters:
  image:
    type: string
    label: Base image
    description: Name or UUID of a Glance image
    default: ubuntu-22.04
  flavor:
    type: string
    default: m1.small
    constraints:
      - custom_constraint: nova.flavor
  key_name:
    type: string
    description: Existing Nova keypair for SSH
    default: sre-key
  public_net:
    type: string
    description: Name/UUID of the external (provider) network for floating IPs
    default: public
  private_cidr:
    type: string
    default: 192.168.100.0/24

resources:

  private_net:
    type: OS::Neutron::Net
    properties:
      name: heat-private-net

  private_subnet:
    type: OS::Neutron::Subnet
    properties:
      name: heat-private-subnet
      network_id: { get_resource: private_net }
      cidr: { get_param: private_cidr }
      ip_version: 4
      dns_nameservers: [ "1.1.1.1", "9.9.9.9" ]
      enable_dhcp: true

  router:
    type: OS::Neutron::Router
    properties:
      name: heat-router
      external_gateway_info:
        network: { get_param: public_net }

  router_interface:
    type: OS::Neutron::RouterInterface
    properties:
      router_id: { get_resource: router }
      subnet_id: { get_resource: private_subnet }

  web_secgroup:
    type: OS::Neutron::SecurityGroup
    properties:
      name: heat-web-sg
      rules:
        - { protocol: tcp, port_range_min: 22,  port_range_max: 22,  remote_ip_prefix: 0.0.0.0/0 }
        - { protocol: tcp, port_range_min: 80,  port_range_max: 80,  remote_ip_prefix: 0.0.0.0/0 }
        - { protocol: tcp, port_range_min: 443, port_range_max: 443, remote_ip_prefix: 0.0.0.0/0 }
        - { protocol: icmp, remote_ip_prefix: 0.0.0.0/0 }

  web_port:
    type: OS::Neutron::Port
    properties:
      network_id: { get_resource: private_net }
      security_groups: [ { get_resource: web_secgroup } ]
      fixed_ips:
        - subnet_id: { get_resource: private_subnet }

  web_server:
    type: OS::Nova::Server
    properties:
      name: heat-web01
      image: { get_param: image }
      flavor: { get_param: flavor }
      key_name: { get_param: key_name }
      networks:
        - port: { get_resource: web_port }
      user_data_format: RAW
      user_data: |
        #cloud-config
        package_update: true
        packages:
          - nginx
        runcmd:
          - systemctl enable --now nginx

  web_floating_ip:
    type: OS::Neutron::FloatingIP
    properties:
      floating_network: { get_param: public_net }

  web_floating_ip_assoc:
    type: OS::Neutron::FloatingIPAssociation
    properties:
      floatingip_id: { get_resource: web_floating_ip }
      port_id: { get_resource: web_port }

outputs:
  instance_name:
    description: Nova instance name
    value: { get_attr: [ web_server, name ] }
  private_ip:
    description: Fixed IP on the tenant network
    value: { get_attr: [ web_port, fixed_ips, 0, ip_address ] }
  public_ip:
    description: Floating IP reachable from outside
    value: { get_attr: [ web_floating_ip, floating_ip_address ] }
```

Manejándolo:

```bash
$ openstack stack create -t web-tier.yaml \
    --parameter public_net=public web-tier
+---------------------+--------------------------------------+
| Field               | Value                                |
+---------------------+--------------------------------------+
| id                  | 0e1f2a3b-4c5d-6e7f-8a9b-0c1d2e3f4a5b |
| stack_name          | web-tier                             |
| stack_status        | CREATE_IN_PROGRESS                   |
| creation_time       | 2026-08-11T13:40:02Z                 |
+---------------------+--------------------------------------+

$ openstack stack list
+--------+------------+-----------------+----------------------+
| ID     | Stack Name | Stack Status    | Creation Time        |
+--------+------------+-----------------+----------------------+
| 0e1f.. | web-tier   | CREATE_COMPLETE | 2026-08-11T13:40:02Z |
+--------+------------+-----------------+----------------------+

$ openstack stack output show web-tier public_ip
+--------------+----------------------------------+
| Field        | Value                            |
+--------------+----------------------------------+
| description  | Floating IP reachable from outside|
| output_key   | public_ip                        |
| output_value | 203.0.113.42                     |
+--------------+----------------------------------+
```

---

## 4. Terraform — infraestructura como código declarativa y agnóstica del proveedor

Terraform es el segundo ítem de **conocimiento básico de funcionalidades** del examen y el aprovisionador de IaC estándar de la industria. Su arquitectura es lo que lo diferencia de Heat: Terraform es un **binario del lado del cliente** que reconcilia un **estado deseado declarado (HCL)** contra un **estado real registrado (el archivo de estado)** llamando a **plugins de provider** que traducen los recursos a la API de una nube destino.

### 4.1 Arquitectura y conceptos centrales

```
   *.tf (HCL)  ── desired state ──┐
                                  ▼
                        ┌──────────────────┐    provider plugin (gRPC)
   terraform state ────►│  Terraform Core  │───────────────►  OpenStack / AWS / ...
   (actual state)       │  (graph + diff)  │◄───────────────  cloud REST API
                        └──────────────────┘   refresh (read live state)
                                  │
                                  ▼
                     plan  =  desired  Δ  (actual ∪ live)
```

| Concepto | Qué es | Por qué importa operativamente |
|---|---|---|
| **Provider** | Plugin que implementa el CRUD para los recursos de una nube (`openstack`, `aws`, `google`…) | Una herramienta, muchas nubes — la propuesta de valor multinube |
| **Resource** | Un objeto gestionado declarado (`openstack_compute_instance_v2`) | La unidad que Terraform crea/actualiza/destruye |
| **Data source** | Consulta de solo lectura de objetos preexistentes | Referenciar infraestructura que no gestionás |
| **State (estado)** | JSON que mapea direcciones HCL → IDs de recursos reales | **La fuente de verdad de lo que Terraform cree que existe.** Pérdida/corrupción = recursos huérfanos |
| **Backend** | Dónde vive el estado (archivo local, Swift, S3, Consul, TFE) | Remoto + **bloqueo (locking)** es obligatorio para un equipo; el estado local sufre condiciones de carrera |
| **Plan** | Diff calculado antes de cualquier cambio | El artefacto revisable, que acota el radio de impacto, del que carecen Heat/la consola |
| **Module** | Grupo de recursos parametrizado y reutilizable | DRY entre entornos |

### 4.2 Una configuración completa de Terraform para el provider de OpenStack

Infraestructura equivalente al stack de Heat anterior, expresada como HCL revisable con un **backend de estado remoto y bloqueado** (Swift), variables y outputs.

```hcl
# versions.tf — pin the core and provider; never float in production
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 2.1"
    }
  }

  # Remote, lock-capable state in OpenStack Swift.
  backend "swift" {
    container         = "terraform-state"
    state_name        = "web-tier/terraform.tfstate"
    lock              = true
    # auth comes from the standard OS_* env vars (same as the CLI)
  }
}

provider "openstack" {
  # Reads OS_AUTH_URL / OS_USERNAME / OS_PASSWORD / OS_PROJECT_NAME /
  # OS_*_DOMAIN_NAME / OS_REGION_NAME from the sourced RC file.
}
```

```hcl
# variables.tf
variable "image_name" {
  type    = string
  default = "ubuntu-22.04"
}

variable "flavor_name" {
  type    = string
  default = "m1.small"
}

variable "key_pair" {
  type    = string
  default = "sre-key"
}

variable "public_network" {
  type    = string
  default = "public"
}

variable "private_cidr" {
  type    = string
  default = "192.168.100.0/24"
}
```

```hcl
# main.tf
# --- Look up objects we do NOT manage ---------------------------------------
data "openstack_images_image_v2" "base" {
  name        = var.image_name
  most_recent = true
}

data "openstack_networking_network_v2" "public" {
  name = var.public_network
}

# --- Tenant network + subnet ------------------------------------------------
resource "openstack_networking_network_v2" "private" {
  name           = "tf-private-net"
  admin_state_up = true
}

resource "openstack_networking_subnet_v2" "private" {
  name            = "tf-private-subnet"
  network_id      = openstack_networking_network_v2.private.id
  cidr            = var.private_cidr
  ip_version      = 4
  dns_nameservers = ["1.1.1.1", "9.9.9.9"]
}

# --- Router to the external network ----------------------------------------
resource "openstack_networking_router_v2" "router" {
  name                = "tf-router"
  admin_state_up      = true
  external_network_id = data.openstack_networking_network_v2.public.id
}

resource "openstack_networking_router_interface_v2" "router_iface" {
  router_id = openstack_networking_router_v2.router.id
  subnet_id = openstack_networking_subnet_v2.private.id
}

# --- Security group ---------------------------------------------------------
resource "openstack_networking_secgroup_v2" "web" {
  name        = "tf-web-sg"
  description = "SSH/HTTP/HTTPS ingress"
}

locals {
  ingress_ports = [22, 80, 443]
}

resource "openstack_networking_secgroup_rule_v2" "web_ingress" {
  for_each          = toset([for p in local.ingress_ports : tostring(p)])
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = tonumber(each.value)
  port_range_max    = tonumber(each.value)
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.web.id
}

# --- Port + instance --------------------------------------------------------
resource "openstack_networking_port_v2" "web" {
  name               = "tf-web-port"
  network_id         = openstack_networking_network_v2.private.id
  admin_state_up     = true
  security_group_ids = [openstack_networking_secgroup_v2.web.id]

  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.private.id
  }
}

resource "openstack_compute_instance_v2" "web" {
  name        = "tf-web01"
  image_id    = data.openstack_images_image_v2.base.id
  flavor_name = var.flavor_name
  key_pair    = var.key_pair

  network {
    port = openstack_networking_port_v2.web.id
  }

  user_data = <<-EOT
    #cloud-config
    package_update: true
    packages: [nginx]
    runcmd:
      - systemctl enable --now nginx
  EOT
}

# --- Floating IP ------------------------------------------------------------
resource "openstack_networking_floatingip_v2" "web" {
  pool = var.public_network
}

resource "openstack_networking_floatingip_associate_v2" "web" {
  floating_ip = openstack_networking_floatingip_v2.web.address
  port_id     = openstack_networking_port_v2.web.id
}
```

```hcl
# outputs.tf
output "private_ip" {
  value = openstack_networking_port_v2.web.all_fixed_ips[0]
}

output "public_ip" {
  description = "Floating IP reachable from outside"
  value       = openstack_networking_floatingip_v2.web.address
}
```

### 4.3 El flujo de trabajo plan/apply con salida de terminal real

```bash
$ terraform init
Initializing the backend...
Successfully configured the backend "swift"! Terraform will automatically
use this backend unless the backend configuration changes.

Initializing provider plugins...
- Finding terraform-provider-openstack/openstack versions matching "~> 2.1"...
- Installing terraform-provider-openstack/openstack v2.1.0...
- Installed terraform-provider-openstack/openstack v2.1.0 (signed)

Terraform has been successfully initialized!
```

```bash
$ terraform plan
data.openstack_networking_network_v2.public: Reading...
data.openstack_images_image_v2.base: Reading...
data.openstack_images_image_v2.base: Read complete after 1s [id=b7c2...]
data.openstack_networking_network_v2.public: Read complete after 1s [id=9a1f...]

Terraform used the selected providers to generate the following execution
plan. Resource actions are indicated with the following symbols:
  + create

Terraform will perform the following actions:

  # openstack_compute_instance_v2.web will be created
  + resource "openstack_compute_instance_v2" "web" {
      + access_ip_v4        = (known after apply)
      + flavor_name         = "m1.small"
      + id                  = (known after apply)
      + image_id            = "b7c2f0e1-..."
      + name                = "tf-web01"
      + key_pair            = "sre-key"
      + user_data           = "8f3c...==" # sensitive value hashed
      + network {
          + port = (known after apply)
        }
    }

  # ... (network, subnet, router, secgroup, port, floating IP elided) ...

Plan: 11 to add, 0 to change, 0 to destroy.

Changes to Outputs:
  + private_ip = (known after apply)
  + public_ip  = (known after apply)
```

```bash
$ terraform apply -auto-approve
openstack_networking_network_v2.private: Creating...
openstack_networking_secgroup_v2.web: Creating...
openstack_networking_network_v2.private: Creation complete after 3s [id=1c2d...]
openstack_networking_subnet_v2.private: Creating...
openstack_networking_subnet_v2.private: Creation complete after 2s [id=3e4f...]
openstack_compute_instance_v2.web: Creating...
openstack_compute_instance_v2.web: Still creating... [10s elapsed]
openstack_compute_instance_v2.web: Creation complete after 24s [id=7c9e6679-...]
openstack_networking_floatingip_associate_v2.web: Creation complete after 2s

Apply complete! Resources: 11 added, 0 changed, 0 destroyed.

Outputs:

private_ip = "192.168.100.14"
public_ip  = "203.0.113.42"
```

### 4.4 State, drift y operaciones quirúrgicas

El state es el meollo de las operaciones con Terraform. Los comandos de abajo son los que usás durante un incidente.

```bash
# What does Terraform believe exists?
$ terraform state list
data.openstack_images_image_v2.base
data.openstack_networking_network_v2.public
openstack_compute_instance_v2.web
openstack_networking_floatingip_associate_v2.web
openstack_networking_floatingip_v2.web
openstack_networking_network_v2.private
openstack_networking_port_v2.web
openstack_networking_router_interface_v2.router_iface
openstack_networking_router_v2.router
openstack_networking_secgroup_rule_v2.web_ingress["22"]
openstack_networking_secgroup_v2.web
openstack_networking_subnet_v2.private

# Detect drift: someone changed the SG by hand in Horizon
$ terraform plan
openstack_networking_secgroup_v2.web: Refreshing state... [id=5a6b...]
  ...
  # openstack_networking_secgroup_rule_v2.web_ingress["443"] has been deleted
  #   (out-of-band change)
Plan: 1 to add, 0 to change, 0 to destroy.   # Terraform will re-add it

# Adopt an already-existing resource into state (no re-create)
$ terraform import openstack_compute_instance_v2.legacy 7c9e6679-7425-40de-944b-e07fc1f90ae7
Import successful!

# Force replacement of one resource (modern replacement for `terraform taint`)
$ terraform apply -replace="openstack_compute_instance_v2.web"

# Destroy the whole stack
$ terraform destroy -auto-approve
Destroy complete! Resources: 11 destroyed.
```

> **Nota al pie sobre licencias (una decisión real de producción/arquitectura).** En agosto de 2023 HashiCorp relicenció Terraform de MPL 2.0 a la licencia business-source **BUSL 1.1**. La Linux Foundation bifurcó (fork) la última versión MPL como **OpenTofu** (CLI `tofu`), un sucesor open source compatible como reemplazo directo. Para cualquier organización con restricciones de política sobre licencias no OSI, OpenTofu es el reemplazo compatible a nivel de estado; el HCL, los providers y el flujo de trabajo mostrados arriba son idénticos.

---

## 5. CloudStack — nociones (IaaS integrado, «con las pilas incluidas»)

Apache CloudStack es un IaaS **llave en mano**: donde OpenStack es un kit de ~25 servicios desplegados de forma independiente, CloudStack se entrega como un **único Management Server** (Java) más agentes, presentando un producto coherente. Es la opción cuando querés un *appliance* de nube en lugar de una plataforma que ensamblás.

**Jerarquía física/lógica (conocé este vocabulario):**

```
Region  ─┬─ Zone        (≈ a datacenter; has its own secondary storage)
         │    └─ Pod    (≈ a rack; an L2 broadcast/management domain)
         │         └─ Cluster  (hosts sharing a hypervisor type + primary storage)
         │              └─ Host (a physical hypervisor: KVM / XenServer / VMware / Hyper-V)
         └─ Primary storage (per-cluster, VM disks) · Secondary storage (per-zone, templates/ISOs/snapshots)
```

Características clave: una **interfaz web nativa + una query API tipo REST** (peticiones de URL firmadas), soporte multihipervisor de fábrica, routers virtuales para red/DHCP/NAT por tenant, y una fachada «CloudBridge» compatible con EC2/S3 de AWS.

```bash
# CloudStack's API is a signed query API; cloudmonkey is the official CLI
$ cmk list zones filter=name,allocationstate
{
  "count": 1,
  "zone": [ { "name": "zone-cordoba", "allocationstate": "Enabled" } ]
}
$ cmk list hosts type=Routing filter=name,state,hypervisor
{
  "count": 2,
  "host": [
    { "name": "kvm01", "state": "Up", "hypervisor": "KVM" },
    { "name": "kvm02", "state": "Up", "hypervisor": "KVM" }
  ]
}
```

---

## 6. Eucalyptus y OpenNebula — nociones

### 6.1 Eucalyptus — la nube privada compatible con la API de AWS

El diferenciador de Eucalyptus es la **compatibilidad con la API de AWS bug por bug**: reimplementa las APIs de **EC2, S3, EBS, IAM, Auto Scaling, ELB y CloudFormation** sobre tu propio hardware, de modo que el instrumental escrito para AWS (las CLIs `aws`/`euca2ools`, los SDKs, las plantillas de CloudFormation) funciona sin cambios on-prem. Históricamente su propósito fue el **burst híbrido** — dev/test on-prem contra la misma superficie de API que la producción de AWS. Su vocabulario de componentes: **CLC** (Cloud Controller), **CC** (Cluster Controller), **NC** (Node Controller), **SC** (Storage Controller), **Walrus** (almacén de objetos compatible con S3). Su trayectoria comercial terminó (adquisición por HPE y luego el cierre del proyecto), así que para el examen tratalo como **«la nube privada compatible con AWS»** y entendé que «la compatibilidad de API con la nube pública dominante» es la idea arquitectónica.

```bash
$ euca-describe-instances
RESERVATION  r-a1b2c3d4  000123456789  default
INSTANCE     i-0abc1234  emi-5f6e7d8c  10.0.0.31  euca-web01  running  sre-key  0  m1.small
```

### 6.2 OpenNebula — el gestor de nube ligero y con criterio propio

OpenNebula apunta a la **simplicidad y una huella operativa pequeña**: un único nodo **front-end** (el daemon `oned` + la interfaz web Sunstone/FireEdge + el scheduler) maneja un conjunto de **hosts** de virtualización (KVM, contenedores de sistema LXC o microVMs Firecracker) sobre SSH plano — sin un bus de mensajes pesado ni un clúster SQL que operar. Es la opción pragmática para el edge y las nubes privadas de tamaño mediano, y su **federación de datacenters** y sus drivers híbridos permiten que un solo plano de control abarque varios sitios y haga burst a proveedores públicos.

```bash
$ onehost list
  ID NAME              CLUSTER    TVM      ALLOCATED_CPU      ALLOCATED_MEM STAT
   0 kvm-node01        default      3   300 / 800 (37%)   6G / 32G (18%)   on
   1 kvm-node02        default      2   200 / 800 (25%)   4G / 32G (12%)   on
$ onevm list
  ID USER     GROUP    NAME            STAT  CPU     MEM        HOST             TIME
  12 oneadmin oneadmin web01           runn    1    2G   kvm-node01     0d 04h11
```

---

## 7. Análisis comparativo de compromisos

### 7.1 Las cuatro *plataformas* de nube (los planos de control IaaS)

| Dimensión | **OpenStack** | **CloudStack** | **OpenNebula** | **Eucalyptus** |
|---|---|---|---|---|
| Gobernanza | OpenInfra Foundation | Apache Software Foundation | OpenNebula Systems (OSI: Apache 2.0) | Histórica; efectivamente EOL |
| Arquitectura | ~25 servicios débilmente acoplados (ensámblalo tú mismo) | Un único Management Server + agentes (integrado) | Front-end + hosts sobre SSH (mínimo) | CLC/CC/NC/SC + Walrus |
| Complejidad operativa | **Alta** (RabbitMQ + Galera + muchos agentes) | Media | **Baja** | Media |
| Hipervisores | KVM (principal), Xen, VMware, Hyper-V, bare metal con Ironic | KVM, XenServer, VMware, Hyper-V, Ovm | KVM, LXC, Firecracker, VMware | KVM, Xen |
| IaC nativo | **Heat** (HOT) | ninguno nativo (usar Terraform) | plantillas + OneFlow | compatible con CloudFormation |
| Estilo de API | REST nativo de OpenStack (+ compat. EC2) | Query API firmada + fachada EC2/S3 | XML-RPC + REST (Sunstone) | **EC2/S3/IAM nativo de AWS** |
| Provider de Terraform | `openstack` (maduro) | `cloudstack` | `opennebula` | provider de AWS vía API EC2 |
| Punto óptimo | Nube privada/telco multi-inquilino grande, paridad con la nube pública | Nube privada llave en mano para empresa/hosting | Edge, pymes, nube privada de bajas operaciones | Burst híbrido con AWS (legado) |
| Riesgo principal | Carga operativa de día 2 del plano de control | Ecosistema más pequeño que el de OpenStack | Menos integraciones avanzadas de red/almacenamiento | El proyecto está inactivo |

### 7.2 Herramienta de aprovisionamiento: Terraform vs Heat vs nativo de nube (CloudFormation)

| Dimensión | **Terraform / OpenTofu** | **OpenStack Heat** | **AWS CloudFormation** |
|---|---|---|---|
| Alcance | Multinube, agnóstico del proveedor | Solo OpenStack | Solo AWS |
| Dónde vive el estado | Archivo de estado **del lado del cliente** (backend de tu elección) | **Del lado del servidor** en la BD de Heat (el stack) | Del lado del servidor (gestionado por AWS) |
| Lenguaje | HCL (+ JSON) | HOT (YAML) | YAML/JSON |
| Vista previa de cambios | `terraform plan` (explícito, con diff) | `stack update --dry-run` (limitado) | Change Sets |
| Manejo de drift | `plan`/`refresh` detectan; re-apply reconcilia | Limitado; centrado en el stack | API de detección de drift |
| Primitivas de autoescalado | Vía recursos del provider | **Nativas** (alarmas de Aodh + AutoScalingGroup) | Nativas |
| Mejor cuando | Necesitás un único flujo de trabajo sobre OpenStack **y** nubes públicas, con planes revisables y estado remoto bloqueado | Sos 100% OpenStack y querés que la orquestación viva dentro de la nube (stacks autoreparables, propiedad del tenant) | Sos 100% AWS |

**Regla general del arquitecto:** si el parque es OpenStack de una sola nube y querés stacks con alcance de tenant, autoreparables y con autoescalado, **Heat** mantiene la orquestación dentro de la plataforma. Si tenés (o vas a tener) más de una nube, o querés la revisabilidad de un `plan` explícito y un estado que controlás, **Terraform/OpenTofu** es el estándar. Coexisten: Terraform puede incluso gestionar un `openstack_orchestration_stack_v1` (un stack de Heat) como uno de sus recursos.

---

## 8. Guía de verificación y diagnóstico de fallos

### 8.1 Triaje del plano de control de OpenStack

Los fallos casi siempre se rastrean hasta uno de los tres sustratos compartidos — **Keystone (auth)**, **RabbitMQ (RPC)**, **Galera/BD (estado)** — o hasta un agente caído.

```bash
# 1) Is auth working at all? (401/403 → Keystone or RC file wrong)
$ openstack token issue
# HTTP 401 Unauthorized  ->  bad OS_PASSWORD / expired / clock skew

# 2) Are all API services registered and reachable?
$ openstack endpoint list          # missing interface => catalog misconfig

# 3) Nova control services (a 'down' agent explains 'No valid host was found')
$ openstack compute service list
+----+----------------+-------------------+----------+---------+-------+
| ID | Binary         | Host              | Zone     | Status  | State |
+----+----------------+-------------------+----------+---------+-------+
|  1 | nova-conductor | ctl01             | internal | enabled | up    |
|  2 | nova-scheduler | ctl01             | internal | enabled | up    |
|  3 | nova-compute   | cmp01.cloud.local | nova     | enabled | up    |
|  4 | nova-compute   | cmp03.cloud.local | nova     | enabled | down  |   ← agent down
+----+----------------+-------------------+----------+---------+-------+

# 4) Neutron agents (a 'down' L3/DHCP/OVS agent breaks tenant networking)
$ openstack network agent list
+--------+--------------------+-------------------+-------+-------+
| ID     | Agent Type         | Host              | Alive | State |
+--------+--------------------+-------------------+-------+-------+
| a1..   | Open vSwitch agent | cmp01.cloud.local | :-)   | UP    |
| b2..   | L3 agent           | ctl01             | :-)   | UP    |
| c3..   | DHCP agent         | ctl01             | XXX   | DOWN  |   ← no leases
+--------+--------------------+-------------------+-------+-------+

# 5) Why did THIS instance fail? fault + scheduling reason
$ openstack server show web01 -c status -c fault
+--------+---------------------------------------------------------------+
| Field  | Value                                                         |
+--------+---------------------------------------------------------------+
| status | ERROR                                                         |
| fault  | {'code': 500, 'message': 'No valid host was found. There are  |
|        |  not enough hosts available.'}                               |
+--------+---------------------------------------------------------------+
```

| Síntoma | Causa más probable | Dónde mirar |
|---|---|---|
| `401 Unauthorized` en cada llamada | Credenciales incorrectas / desfase de reloj / token expirado | Archivo RC, log de Keystone, NTP en los nodos |
| Instancias atascadas en `BUILD` | Partición de RabbitMQ; el conductor no puede alcanzar al compute | `rabbitmqctl cluster_status`, log de `nova-conductor` |
| `No valid host was found` | Sin capacidad / host aggregate / `nova-compute` caído | `openstack compute service list`, inventario de Placement |
| Instancia `ACTIVE` pero inalcanzable | Agente DHCP/L3 caído, falta la asociación de floating IP o una regla de SG | `openstack network agent list`, reglas de SG, gateway del router |
| 500s intermitentes de la API | Nodo Galera fuera de sincronía / deadlocks de BD | `SHOW STATUS LIKE 'wsrep_%'`, logs de BD del servicio |

### 8.2 Verificación y recuperación de Terraform

```bash
# Static + provider-schema validation before any API call (CI gate)
$ terraform fmt -check -recursive
$ terraform validate
Success! The configuration is valid.

# Reconcile state to reality WITHOUT changing infra (drift report)
$ terraform plan -refresh-only

# State is locked by a crashed run — inspect, then force-unlock (surgically!)
$ terraform force-unlock 9db4f3a1-...   # only after confirming no run is live

# A resource exists but Terraform forgot it → import instead of re-create
$ terraform import openstack_compute_instance_v2.web <uuid>

# Corrupt/partial state after an interrupted apply → pull, inspect, backup
$ terraform state pull > backup.tfstate
$ terraform state rm openstack_networking_floatingip_associate_v2.web  # detach a bad entry
```

| Síntoma | Causa | Solución |
|---|---|---|
| `Error acquiring the state lock` | Una ejecución previa se cayó reteniendo el bloqueo | Confirmá que no hay ejecución activa, luego `terraform force-unlock <ID>` |
| El plan quiere destruir+recrear todo | Estado perdido / backend incorrecto / workspace incorrecto | Verificá `terraform workspace show`, restaurá/apuntá el backend, `import` |
| «Resource already exists» (409) al hacer apply | Objeto creado fuera de banda; no está en el estado | Hacele `terraform import`, luego re-plan |
| Diff perpetuo en un atributo sin cambios | El provider/la API normaliza un valor; ilusión de drift | lifecycle `ignore_changes` o corregí el literal para que coincida con la forma canónica de la API |
| Error de autenticación del provider | Variables `OS_*` sin definir / región incorrecta | `source openrc`, verificá primero con `openstack token issue` |

---

## 9. Referencias

- LPI — Objetivos del examen 305-300 (LPIC-3 Virtualization and Containerization, v3.0): https://www.lpi.org/our-certifications/exam-305-objectives/
- NIST SP 800-145, *The NIST Definition of Cloud Computing* (IaaS/PaaS/SaaS, modelos de despliegue): https://csrc.nist.gov/publications/detail/sp/800-145/final
- Documentación de OpenStack (visión general del proyecto, lista de servicios, releases): https://docs.openstack.org/
- OpenStack — Especificación de Heat Orchestration Template (HOT): https://docs.openstack.org/heat/latest/template_guide/hot_spec.html
- Referencia de comandos de OpenStackClient (`openstack`): https://docs.openstack.org/python-openstackclient/latest/
- Releases de OpenStack y cadencia SLURP: https://releases.openstack.org/
- Documentación de Terraform (flujo de trabajo, estado, backends): https://developer.hashicorp.com/terraform/docs
- Provider de OpenStack para Terraform: https://registry.terraform.io/providers/terraform-provider-openstack/openstack/latest/docs
- OpenTofu (fork de Terraform con licencia MPL): https://opentofu.org/docs/
- Documentación de Apache CloudStack (zones/pods/clusters/hosts): https://docs.cloudstack.apache.org/
- Documentación de OpenNebula (arquitectura front-end/hosts): https://docs.opennebula.io/
- Eucalyptus (componentes compatibles con AWS — archivado): https://github.com/eucalyptus/eucalyptus/wiki
- cloud-init (consumido como `user_data` por todos los anteriores): https://cloudinit.readthedocs.io/