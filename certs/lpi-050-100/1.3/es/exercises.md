# Production SRE & Platform Architecture Guide: LPI 050-100 Tema 1.3

## Tema 1.3: On-Premises y Cloud Computing
**Peso del examen:** 2.5  
**Audiencia objetivo:** SREs, Platform Engineers, System Administrators  
**Material de referencia y fuentes oficiales:**
- [LPI Open Source Essentials Overview](https://www.lpi.org/our-certifications/open-source-essentials-overview/)
- [NIST Special Publication 800-145: Definition of Cloud Computing](https://csrc.nist.gov/publications/detail/sp/800-145/final)
- [CNCF Cloud Native Definition](https://github.com/cncf/toc/blob/main/DEFINITION.md)

---

## Contexto arquitectónico y base técnica

La transición de la **Infraestructura On-Premises** tradicional al **Cloud Computing** (público, privado e híbrido) altera las primitivas operacionales fundamentales, los modelos financieros y las suposiciones sobre dominios de falla de los sistemas empresariales.

```
+-----------------------------------------------------------------------------------+
|                            SHARED RESPONSIBILITY MODEL                            |
+----------------------+--------------------+--------------------+------------------+
| Component Layer      | On-Premises        | IaaS (Cloud)       | PaaS (Cloud)     |
+----------------------+--------------------+--------------------+------------------+
| Application Code     | Customer           | Customer           | Customer         |
| Data & Schema        | Customer           | Customer           | Customer         |
| Runtime & OS         | Customer           | Customer           | Provider Managed |
| Virtualization/KVM   | Customer           | Provider Managed   | Provider Managed |
| Physical Hardware    | Customer           | Provider Managed   | Provider Managed |
| Datacenter Facilities| Customer           | Provider Managed   | Provider Managed |
+----------------------+--------------------+--------------------+------------------+
```

### Diferencias clave: On-Premises vs. Cloud

1. **Hardware Abstraction & Hypervisor Isolation**:
   - **On-Premises**: Acceso directo al hardware físico, topologías de acceso no uniforme a memoria (NUMA), interfaces de red del host (NICs) y controladores RAID por hardware. Las actualizaciones requieren adquisición de hardware, procedimientos de rackeo y montaje (rack-and-stack) y ventanas de mantenimiento físico.
   - **Cloud (IaaS)**: Los recursos de hardware se abstraen en primitivas definidas por software (Compute Instance, Block Storage Volume, Software-Defined Network) mediadas por hipervisores bare-metal (por ejemplo, AWS Nitro, KVM, microVMs Firecracker). El aprovisionamiento se realiza de forma programática a través de REST APIs.

2. **Financial Dynamics**:
   - **CapEx (Capital Expenditure)**: Alta inversión inicial en servidores, switches, SANs, unidades de rack, infraestructura de energía/refrigeración y alquileres de datacenter. Amortizado en calendarios de depreciación de 3 a 5 años.
   - **OpEx (Operational Expenditure)**: Modelo de consumo basado en uso (pay-as-you-go). Involucra etiquetado de recursos (resource tagging), métricas de facturación (core-hours, GB/s de salida de red, IOPS) y estrategias de optimización de costos (Reserved Instances, Spot Instances, Auto-scaling).

3. **Elasticity & Resource Pooling (NIST SP 800-145)**:
   - **On-Premises**: La capacidad máxima está estrictamente limitada por la capacidad física estática. El aprovisionamiento toma semanas/meses. El sobreaprovisionamiento es obligatorio para manejar picos de tráfico.
   - **Cloud**: Fondo común de recursos multitenant (resource pooling) a través de Availability Zones (AZs) regionales. Incluye **Rapid Elasticity** programática que permite escalado en menos de un minuto en respuesta a métricas como utilización de CPU o profundidad de cola personalizada (queue depth).

---

## Ejercicios guiados prácticos

---

### Ejercicio 1: Auditoría de hardware de bajo nivel vs. abstracción Cloud e introspección de metadatos vía API

En este ejercicio, ejecutarás herramientas de diagnóstico del sistema de bajo nivel para auditar la topología del hardware del host (nodos NUMA, hyperthreading, sockets de memoria) en un host físico/virtual on-premises, y la contrastarás con la introspección de metadatos de instancias cloud mediante llamadas a APIs link-local.

#### Paso 1.1: Auditar la arquitectura de CPU y la topología del controlador de memoria locales en On-Premises
Ejecutá los siguientes comandos en un host Linux local para inspeccionar la disposición NUMA (Non-Uniform Memory Access) y las primitivas de abstracción de hardware:

```bash
lscpu | grep -E "(Architecture|CPU\(s\)|Thread|Core|Socket|NUMA)"
```

**Expected Terminal Output:**
```text
Architecture:            x86_64
CPU(s):                  32
Thread(s) per core:      2
Core(s) per socket:      8
Socket(s):               2
NUMA node(s):            2
NUMA node0 CPU(s):       0-7,16-23
NUMA node1 CPU(s):       8-15,24-31
```

A continuación, inspeccioná la distribución de memoria NUMA a través de los nodos usando `numactl`:

```bash
numactl --hardware
```

**Expected Terminal Output:**
```text
available: 2 nodes (0-1)
node 0 cpus: 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
node 0 size: 64320 MB
node 0 free: 41200 MB
node 1 cpus: 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31
node 1 size: 64480 MB
node 1 free: 38900 MB
node distances:
node   0   1
  0:  10  21
  1:  21  10
```

#### Paso 1.2: Inspeccionar la identidad del hipervisor Cloud mediante el Instance Metadata Service (IMDSv2)
En un entorno de cloud computing (por ejemplo, AWS EC2, GCP Compute Engine, Azure VM), la disposición del hardware está enmascarada por un hipervisor. El sistema operativo se comunica con un endpoint de metadatos local en la dirección IPv4 link-local no enrutable `169.254.169.254`.

Simulá o ejecutá una consulta de metadatos IMDSv2 (basada en Session Token) para descubrir la identidad de la instancia, la región, el tipo de instancia y las credenciales de IAM:

```bash
# 1. Generate an IMDSv2 Session Token (valid for 21600 seconds)
TOKEN=$(curl -s -S -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

# 2. Fetch Instance Type, Availability Zone, and Hypervisor MAC Address
echo "Instance Type: $(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)"
echo "Availability Zone: $(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)"
echo "Local IPv4: $(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)"
```

**Expected Terminal Output:**
```text
Instance Type: c6i.2xlarge
Availability Zone: us-east-1a
Local IPv4: 10.0.1.42
```

#### Paso 1.3: Aprovisionar infraestructura declarativa mediante Terraform
Compará el aprovisionamiento manual de servidores con el despliegue programático mediante Infrastructure-as-Code (IaC). Revisá e inspeccioná el siguiente manifiesto HashiCorp HCL (`main.tf`) completo y sintácticamente válido que despliega una red cloud aislada y un servidor virtual:

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
  region = "us-east-1"
}

resource "aws_vpc" "production_vpc" {
  cidr_block           = "10.100.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "prod-cloud-vpc"
    Environment = "production"
  }
}

resource "aws_subnet" "public_subnet_a" {
  vpc_id                  = aws_vpc.production_vpc.id
  cidr_block              = "10.100.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true

  tags = {
    Name = "prod-public-subnet-1a"
  }
}

resource "aws_instance" "app_server" {
  ami           = "ami-0c7217cdde317cfec" # Canonical Ubuntu 22.04 LTS x86_64
  instance_type = "t3.medium"
  subnet_id     = aws_subnet.public_subnet_a.id

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # Enforce IMDSv2
    http_put_response_hop_limit = 1
  }

  user_data = <<-EOF
              #!/bin/bash
              apt-get update -y
              apt-get install -y nginx
              systemctl enable --now nginx
              EOF

  tags = {
    Name = "web-app-node-01"
  }
}

output "instance_public_ip" {
  description = "Public IP address of the provisioned cloud instance"
  value       = aws_instance.app_server.public_ip
}
```

Verificá la validez sintáctica usando la CLI de Terraform:

```bash
terraform fmt -check
terraform validate
```

**Expected Terminal Output:**
```text
Success! The configuration is valid.
```

---

#### Control de comprensión: Ejercicio 1

1. **¿Por qué un SRE necesita hacer cumplir `http_tokens = "required"` (IMDSv2) en instancias de cómputo cloud en lugar del legado IMDSv1? ¿Qué riesgo de seguridad mitiga?**
2. **Contrastá cómo la distancia de memoria entre nodos NUMA afecta la latencia en un servidor de base de datos bare-metal físico on-premises frente a una instancia de cómputo cloud con vCPU-pinned.**
3. **Si un script que se ejecuta dentro de un Pod en un cluster de Kubernetes realiza una solicitud HTTP GET a `http://169.254.169.254/latest/meta-data/`, ¿qué componente responde y por qué esto podría plantear una preocupación de seguridad en una plataforma multi-tenant?**

---

### Ejercicio 2: Simulación de elasticidad y fondo común de recursos con Linux Control Groups (cgroups v2)

Los proveedores de cloud logran el **Fondo común de recursos** (Resource Pooling) y la **Elasticidad rápida** (Rapid Elasticity) utilizando mecanismos de contenerización del kernel del SO (cgroups y namespaces) o hipervisores microVM livianos. En este ejercicio, crearás una jerarquía personalizada de cgroups v2 para aplicar límites de CPU y memoria en un proceso, simulando la limitación (throttling) de recursos de un tenant cloud.

#### Paso 2.1: Verificar el montaje del sistema de archivos cgroups v2
Ejecutá `stat` en `/sys/fs/cgroup` para confirmar que tu kernel está ejecutando cgroups v2:

```bash
stat -fc %T /sys/fs/cgroup
```

**Expected Terminal Output:**
```text
cgroup2fs
```

#### Paso 2.2: Crear un Control Group para el fondo común de recursos del tenant
Creá un nodo cgroup llamado `tenant_cloud_pool` e inspeccioná los controladores habilitados:

```bash
sudo mkdir -p /sys/fs/cgroup/tenant_cloud_pool
cat /sys/fs/cgroup/cgroup.subtree_control
```

**Expected Terminal Output:**
```text
cpuset cpu io memory pids
```

Habilitá los controladores de `cpu` y `memory` para los grupos de hijos:

```bash
echo "+cpu +memory" | sudo tee /sys/fs/cgroup/cgroup.subtree_control
```

#### Paso 2.3: Establecer límites strictly para memoria (OOM Killer) y cuota de CPU
Configurá un límite estricto de memoria de 256MB (`memory.max`) y restringí el consumo de CPU a 1.5 núcleos (`cpu.max` configurado en 150000 microsegundos por cada período de 100000 microsegundos):

```bash
# Set hard limit of 268435456 bytes (256 MB)
echo "268435456" | sudo tee /sys/fs/cgroup/tenant_cloud_pool/memory.max

# Set CPU limit: quota=150000, period=100000 (150% of 1 CPU core)
echo "150000 100000" | sudo tee /sys/fs/cgroup/tenant_cloud_pool/cpu.max
```

Verificá los límites configurados:

```bash
cat /sys/fs/cgroup/tenant_cloud_pool/memory.max
cat /sys/fs/cgroup/tenant_cloud_pool/cpu.max
```

**Expected Terminal Output:**
```text
268435456
150000 100000
```

#### Paso 2.4: Adjuntar un proceso y probar los límites de elasticidad de recursos
Iniciá un proceso de prueba de esfuerzo (stress process) en segundo plano usando `stress-ng` adjunto al cgroup `tenant_cloud_pool`:

```bash
# Attach current shell PID to cgroup
echo $$ | sudo tee /sys/fs/cgroup/tenant_cloud_pool/cgroup.procs

# Run stress testing tool allocating 512MB RAM (exceeding 256MB hard limit)
stress-ng --vm 1 --vm-bytes 512M --timeout 10s
```

**Expected Terminal Output:**
```text
stress-ng: info:  [12845] dispatching stressor processes
stress-ng: fail:  [12845] stress-ng-vm: terminated by SIGKILL (OOM killed)
stress-ng: info:  [12845] unsuccessful run completed in 0.42s
```

Verificá el contador de eventos Out-Of-Memory (OOM) del kernel para el cgroup:

```bash
cat /sys/fs/cgroup/tenant_cloud_pool/memory.events
```

**Expected Terminal Output:**
```text
low 0
high 0
max 4
oom 1
oom_kill 1
oom_group_kill 0
```

---

#### Control de comprensión: Ejercicio 2

1. **¿Cómo se alinea la limitación de memoria en cgroups v2 (`memory.max` vs `memory.high`) con la definición de "Servicio medido" (Measured Service) de NIST SP 800-145 y la contención de recursos multi-tenant?**
2. **En un entorno cloud, ¿cuál es la diferencia principal entre "Escalado vertical" (Scale Up) y "Escalado horizontal" (Scale Out), y cuál se beneficia más del micro-bin-packing basado en cgroups?**
3. **Un equipo de aplicación exige núcleos de hardware 100% dedicados sin ningún overcommit de hipervisor de vecinos ruidosos (noisy-neighbor). ¿Qué modelo de aprovisionamiento en la nube (Bare Metal Instances vs Dedicated Hosts vs Shared Multi-tenant Instances) debe seleccionarse y cuáles son las implicaciones de CapEx/OpEx?**

---

### Ejercicio 3: Configuración de conectividad híbrida y diagnóstico de latencia/rendimiento de red

Una arquitectura de **Cloud híbrido** (Hybrid Cloud) conecta los centros de datos on-premises con Virtual Private Clouds (VPC) de la nube pública a través de túneles cifrados seguros (IPsec/WireGuard) o líneas privadas dedicadas (AWS Direct Connect / GCP Cloud Interconnect).

En este ejercicio, inspeccionarás una configuración de túnel overlay WireGuard sintácticamente completa y ejecutarás diagnósticos de red (`mtr`, `iperf3`, `tcpdump`) para evaluar la latencia del enlace híbrido y los cuellos de botella en el rendimiento (throughput).

#### Paso 3.1: Inspeccionar la configuración del túnel overlay de On-Premises a Cloud
Revisá el siguiente archivo de configuración de interfaz WireGuard completo (`/etc/wireguard/wg0.conf`) que representa un router On-Premises conectado a un Cloud Gateway:

```ini
[Interface]
# On-Premises Router Local Configuration
PrivateKey = uK3x8N4...[REDATED_PRIVATE_KEY]...8wA=
Address = 192.168.250.1/30
ListenPort = 51820
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

[Peer]
# Cloud Gateway Endpoint Configuration
PublicKey = 7bT9y...[REDATED_PUBLIC_KEY]...0xM=
Endpoint = 203.0.113.45:51820
AllowedIPs = 10.100.0.0/16, 192.168.250.2/32
PersistentKeepalive = 25
```

Verificá el estado de la interfaz del túnel usando `wg`:

```bash
sudo wg show wg0
```

**Expected Terminal Output:**
```text
interface: wg0
  public key: 4xK9p...[KEY]...9qA=
  listening port: 51820

peer: 7bT9y...[REDATED_PUBLIC_KEY]...0xM=
  endpoint: 203.0.113.45:51820
  allowed ips: 10.100.0.0/16, 192.168.250.2/32
  latest handshake: 12 seconds ago
  transfer: 1.42 MiB received, 4.88 MiB sent
  persistent keepalive: every 25 seconds
```

#### Paso 3.2: Realizar rastreo de rutas de red y análisis de jitter mediante MTR
Ejecutá `mtr` (My TraceRoute) en modo reporte para diagnosticar la pérdida de paquetes y la variación de latencia a través del enlace de red híbrido hacia el cloud gateway (`10.100.1.42`):

```bash
mtr --report --report-cycles=10 --no-dns 10.100.1.42
```

**Expected Terminal Output:**
```text
Start: 2026-08-06T19:00:00+0000
HOST: on-prem-gw01                Loss%   Snt   Last   Avg  Best  Wrst StDev
  1.|-- 192.168.1.1                0.0%    10    0.3   0.4   0.3   0.6   0.1
  2.|-- 192.168.250.2 (wg0)        0.0%    10   12.4  12.8  12.1  14.2   0.7
  3.|-- 10.100.1.42                0.0%    10   13.1  13.2  12.8  15.0   0.6
```

#### Paso 3.3: Realizar benchmarking del ancho de banda del túnel híbrido con iperf3
Ejecutá el cliente `iperf3` contra el servidor objetivo en la instancia cloud (`10.100.1.42`) sobre 4 flujos TCP paralelos:

```bash
iperf3 -c 10.100.1.42 -P 4 -t 10
```

**Expected Terminal Output:**
```text
Connecting to host 10.100.1.42, port 5201
[SUM]   0.00-10.00  sec  1.08 GBytes   930 Mbits/sec    0   sender
[SUM]   0.00-10.00  sec  1.07 GBytes   921 Mbits/sec        receiver
```

---

#### Control de comprensión: Ejercicio 3

1. **¿Por qué es crítico `PersistentKeepalive = 25` en las configuraciones de WireGuard cuando se conecta una red on-premises detrás de un firewall NAT a un gateway de nube pública?**
2. **¿Cuáles son las principales ventajas y desventajas (trade-offs) operativas entre atravesar la red de internet pública a través de una VPN IPsec/WireGuard versus desplegar una conexión dedicada como AWS Direct Connect / GCP Cloud Interconnect?**
3. **Si la latencia de red aumenta significativamente solo durante las pruebas de saturación de ancho de banda con `iperf3` sobre un enlace híbrido, ¿qué fenómeno de red (por ejemplo, Bufferbloat, MTU Path Disjointness, TCP Window Scaling) es más probable que esté ocurriendo y cómo puede ayudar el ajuste de MTU (`mss-clamping`)?**

---

## <details><summary>Respuestas y explicaciones</summary>

### Soluciones del Ejercicio 1

1. **Aplicación de seguridad en IMDSv2 vs IMDSv1**:
   - **IMDSv1** utiliza solicitudes HTTP `GET` simples y no autenticadas (`curl http://169.254.169.254/...`), lo que lo hace vulnerable a fallas de **Server-Side Request Forgery (SSRF)** en aplicaciones web. Si un atacante explota una vulnerabilidad SSRF, puede leer los endpoints de IMDSv1 y robar credenciales temporales de roles de IAM asignadas a la instancia.
   - **IMDSv2** impone un mecanismo de token HTTP orientado a sesión que requiere una solicitud `PUT` con un encabezado personalizado (`X-aws-ec2-metadata-token-ttl-seconds`) para generar un token secreto antes de consultar metadatos. La mayoría de los vectores de SSRF no pueden ejecutar llamadas HTTP `PUT` ni adjuntar encabezados personalizados, mitigando el robo de credenciales.

2. **Latencia de memoria NUMA: On-Premises vs. Cloud**:
   - **On-Premises Bare Metal**: Un servidor físico con múltiples sockets de CPU tiene controladores de memoria distintos adjuntos a cada socket (nodos NUMA). Acceder a la memoria local adjunta al Socket 0 toma ~10ns, mientras que acceder a la memoria remota adjunta al Socket 1 a través de Ultra Path Interconnect (UPI) incurre en una penalización de latencia del ~30%-50%. Los SREs deben usar `numactl --membind` para fijar (pin) la memoria a los nodos NUMA locales en bases de datos de alto rendimiento.
   - **Instancias Cloud**: Las instancias de máquinas virtuales pequeñas/medianas se ejecutan dentro de un solo nodo NUMA gestionado por el hipervisor. Sin embargo, las instancias grandes bare-metal o multi-socket (por ejemplo, `u-12tb1.metal`) exponen la topología NUMA directamente al SO huésped (guest OS), lo que requiere que los SREs apliquen reglas de ajuste (tuning) de NUMA idénticas a las de los entornos on-premises.

3. **Exposición de metadatos en Kubernetes**:
   - Por defecto, los Pods comparten el namespace de red del host o enrutan el tráfico de salida a través de las interfaces del host. Un contenedor de aplicación sin privilegios dentro de un Pod puede consultar `169.254.169.254` y recibir las credenciales de instancia IAM del nodo trabajador de Kubernetes subyacente.
   - **Mitigación**: Los SREs deben implementar NetworkPolicies que bloqueen el tráfico de salida hacia `169.254.169.254/32` o utilizar herramientas de seguridad de metadatos (como AWS IRSA / EKS Pod Identities o Azure Workload Identity) que restringen el acceso e inyectan tokens de IAM de grano fino directamente en los Pods en lugar de compartir credenciales de IAM a nivel de nodo.

---

### Soluciones del Ejercicio 2

1. **cgroups v2 y el Servicio medido de NIST**:
   - El NIST define el **Servicio medido** (Measured Service) como sistemas cloud que controlan y optimizan automáticamente el uso de recursos aprovechando las capacidades de medición a un nivel de abstracción apropiado para el tipo de servicio (por ejemplo, almacenamiento, procesamiento, ancho de banda).
   - En cgroups v2, `memory.high` actúa como un límite de restricción (throttling boundary) donde los procesos que superan el umbral se ralentizan y se ven obligados a reclamar memoria sin fallar inmediatamente. `memory.max` impone un límite estricto que activa el OOM Killer del kernel si se infringe. Esto garantiza límites de recursos predecibles, aislamiento multi-tenant y medición precisa del servicio sin inestabilidad del host.

2. **Escalado vertical vs. horizontal**:
   - **Escalado vertical (Scale Up)**: Agregar más núcleos de CPU o RAM a un nodo existente. Limitado por la capacidad física máxima del hardware y requiere reiniciar las instancias (a menos que admita hot-plugging).
   - **Escalado horizontal (Scale Out)**: Agregar más nodos/instancias de cómputo discretos a un cluster distribuido (por ejemplo, nodos trabajadores de Kubernetes, Auto Scaling Groups).
   - **Micro-bin-packing**: El escalado horizontal se beneficia exponencialmente del micro-bin-packing basado en cgroups, ya que los SREs pueden empaquetar de manera segura docenas de microservicios contenerizados pequeños en menos instancias cloud grandes, optimizando la utilización de recursos y reduciendo los costos totales de OpEx.

3. **Modelos de aislamiento de hardware**:
   - **Bare Metal Instances**: Ofrece acceso directo al hardware físico sin un hipervisor. Modelo de mayor costo; incurre en OpEx facturado por hora/mes.
   - **Dedicated Hosts**: Servidores físicos dedicados exclusivamente a un solo cliente, lo que permite el cumplimiento de políticas de conformidad y el control sobre la ubicación de sockets/núcleos.
   - **Shared Multi-Tenant Instances**: Instancias cloud estándar que se ejecutan en hipervisores compartidos junto con las VMs de otros clientes.
   - **Compromiso financiero/operativo (Trade-off)**: Bare Metal y Dedicated Hosts eliminan los problemas de vecinos ruidosos (noisy-neighbor) y la varianza de NUMA, pero aumentan drásticamente los costos por hora y reducen la eficiencia del fondo común de recursos (resource pooling) en comparación con las VMs multi-tenant compartidas.

---

### Soluciones del Ejercicio 3

1. **Necesidad de PersistentKeepalive en WireGuard**:
   - Los routers y firewalls NAT con estado (stateful) eliminan las entradas de seguimiento de conexiones inactivas después de un período de inactividad (típicamente entre 30 y 60 segundos).
   - Debido a que WireGuard permanece silencioso cuando no hay tráfico (no envía reconocimientos de paquetes), un router NAT limpiará el mapeo. `PersistentKeepalive = 25` obliga a WireGuard a enviar un ping cifrado cada 25 segundos, manteniendo abierto el mapeo NAT para que el cloud gateway pueda iniciar conexiones salientes de regreso a la subred on-premises en cualquier momento.

2. **VPN sobre internet pública vs. Cloud Interconnect dedicado**:
   - **IPsec/WireGuard sobre internet pública**: Implementación rápida, bajo costo (utiliza líneas de internet existentes), pero sujeto a jitter de enrutamiento de internet, pérdida de paquetes, SLA no garantizado y latencia variable.
   - **AWS Direct Connect / GCP Cloud Interconnect**: Enlace de fibra física directo al Punto de Presencia (PoP) del proveedor de cloud. Proporciona latencia determinista de un solo dígito de milisegundos, SLA garantizado, alto ancho de banda (1Gbps–100Gbps) y precios de salida de datos (egress) más bajos, pero requiere meses de aprovisionamiento de circuitos y altos costos fijos mensuales.

3. **Bufferbloat y MTU MSS Clamping**:
   - **Bufferbloat**: Ocurre cuando el equipo de red intermedio almacena en búfer colas de paquetes excesivamente grandes, lo que provoca que la latencia se dispare drásticamente durante la saturación de alto rendimiento (`iperf3`).
   - **MTU & MSS Clamping**: Los protocolos de encapsulamiento (como WireGuard o IPsec) agregan encabezados (típicamente de 20 a 60 bytes), reduciendo la MTU efectiva de 1500 bytes a 1420 bytes. Si los paquetes TCP no tienen en cuenta la sobrecarga de encabezado, los routers fragmentan los paquetes, degradando el rendimiento.
   - **Solución**: Configurar `iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu` en el router para reducir dinámicamente el Maximum Segment Size (MSS), evitando la fragmentación de paquetes a través del túnel híbrido.

</details>