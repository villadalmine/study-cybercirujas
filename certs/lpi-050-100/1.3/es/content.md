# Tema 1.3: On-Premises y Cloud Computing

**Examen**: LPI Open Source Essentials (050-100)  
**Peso del tema**: 2.5  
**Audiencia objetivo**: Arquitectos Principales de Plataforma, SREs Senior, Ingenieros de Sistemas  

---

## 1. Motivación Arquitectónica y Declaración del Problema de Producción

Las plataformas empresariales modernas operan en la intersección del control de infraestructura, las demandas de escalado dinámico, los mandatos de cumplimiento y modelos financieros estrictos (CapEx vs. OpEx). Diseñar entornos de cómputo requiere navegar compromisos (trade-offs) entre hardware físico bare-metal (On-Premises), infraestructura de nube virtualizada (IaaS), entornos de ejecución administrados para desarrolladores (PaaS) y aplicaciones de nube llave en mano (SaaS).

### Dilema de Producción: El Desafío de la Migración Híbrida y a la Nube
Considere una aplicación de servicios financieros que procesa miles de transacciones por segundo. 
- **Arquitectura Legacy**: Los despliegues bare-metal en instalaciones de coinserción (colocation facilities) garantizan un rendimiento I/O determinista, cumplimiento normativo y cero problemas de noisy-neighbor multinquilino (multi-tenant). Sin embargo, los tiempos de entrega para la compra, montaje en rack y aprovisionamiento de servidores físicos toman semanas, bloqueando el escalado rápido durante eventos de alto tráfico.
- **Arquitectura Nube-Nativa (Cloud-Native)**: Infrastructure-as-a-Service (IaaS) y Platform-as-a-Service (PaaS) ofrecen elasticidad, aprovisionamiento automatizado impulsado por APIs y una huella distribuida globalmente. Sin embargo, las topologías de salida (egress) desconfiguradas, el uso no controlado de APIs o el bloqueo de proveedor (vendor lock-in) crean riesgos operacionales y picos de facturación impredecibles.

### Escenarios Operacionales a través de Modelos de Servicio
1. **On-Premises / Private Cloud (Bare-Metal / OpenStack / VMware)**:
   - *Caso de Uso*: Cargas de trabajo de kernel bypass de ultra baja latencia (por ejemplo, motores de trading eBPF/DPDK), regulaciones estrictas de soberanía de datos (GDPR, HIPAA, PCI-DSS) y alta carga base donde el CapEx a largo plazo es más económico que las instancias de cómputo en la nube de alta densidad.
   - *Impacto en SRE*: Alto trabajo operativo (operational toil). La gestión del ciclo de vida del hardware, las actualizaciones de firmware, el mantenimiento del entramado de red (BGP/spine-leaf), el aprovisionamiento de almacenamiento SAN/NAS y la gestión del runtime de hipervisores/contenedores recaen enteramente en los equipos internos de plataforma.
2. **Infrastructure as a Service (IaaS - ej., OpenStack, AWS EC2, GCP Compute Engine)**:
   - *Caso de Uso*: Cargas de trabajo de propósito general que requieren control total sobre el kernel del sistema operativo, topología de red (VPC/VNets), volúmenes de almacenamiento en bloque y filtrado de security groups.
   - *Impacto en SRE*: Modelo de responsabilidad compartida. El proveedor administra el hardware físico y los hipervisores; los SREs administran el parcheo del sistema operativo, enrutamiento de red, cortafuegos (firewalling), escalado de instancias y recuperación ante desastres (disaster recovery).
3. **Platform as a Service (PaaS - ej., OpenShift, Heroku, AWS Elastic Beanstalk)**:
   - *Caso de Uso*: Entrega rápida de aplicaciones donde los desarrolladores se enfocan únicamente en artefactos de código, pipelines de despliegue y configuración del entorno, mientras que la gestión del entorno de ejecución se abstrae.
   - *Impacto en SRE*: Control reducido sobre primitivas de kernel de bajo nivel, sysctls personalizados e interfaces de red físicas a cambio de integración CI/CD integrada, runtimes con auto-scaling y monitoreo de salud administrado.
4. **Software as a Service (SaaS - ej., GitHub Enterprise Cloud, Salesforce, Microsoft 365)**:
   - *Caso de Uso*: Servicios de aplicación listos para usar sin gestión de huella operacional.
   - *Impacto en SRE*: Control de infraestructura nulo. El enfoque operacional se desplaza hacia la gobernanza de identidad (OAuth2/SAML SSO), registros de auditoría (audit logging), gestión de cuotas de API y monitoreo del cumplimiento de SLAs.

---

## 2. Comparación Técnica Detallada y Matriz de Compromisos (Trade-Offs)

| Dimensión | On-Premises / Bare-Metal | Nube Privada (IaaS) | Nube Pública (IaaS) | Platform as a Service (PaaS) | Software as a Service (SaaS) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Control y Personalización** | Control completo sobre el hardware, BIOS/UEFI, CPU flags y módulos del kernel. | Alto control sobre la asignación de hipervisores, virtualización de red (Geneve/VXLAN) y backends de almacenamiento (Ceph). | Acceso completo al OS/Kernel del huésped (Guest Kernel); cero acceso a hardware/hipervisor. | Restringido al runtime de la aplicación, variables de entorno y límites de contenedores. | Solo configuración (SSO, webhooks, reglas RBAC). |
| **Sobrecarga Operativa** | Extremadamente Alta (Mantenimiento de hardware, energía/refrigeración, SAN/NAS, cableado). | Alta (Gestión de la Plataforma de Gestión de Nube como OpenStack, hipervisores, clusters de almacenamiento). | Moderada (Parcheo de OS, reglas de red, unidades systemd, stack de observabilidad). | Baja (Ejecución de código, ajuste de runtime, monitoreo de aplicaciones). | Despreciable (Aprovisionamiento de usuarios, verificación de backups). |
| **Modelo Financiero** | CapEx elevado (Arrays de servidores, equipos de switches, arrays de almacenamiento amortizados a 3-5 años). | CapEx elevado inicialmente + OpEx para el mantenimiento de la nube privada. | OpEx puro (Pay-as-you-go, Reserved Instances, Savings Plans). | OpEx puro (Facturado por hora de instancia, duración de ejecución o consumo de memoria). | OpEx basado en suscripción / por usuario (Per-Seat) / por consumo (Utility-based). |
| **Elasticidad y Velocidad de Aprovisionamiento** | Baja (Días a semanas para la adquisición de hardware y aprovisionamiento). | Moderada-Alta (Minutos; limitada por la capacidad física del rack). | Ultra-Alta (Segundos a minutos mediante llamadas a APIs de la nube). | Ultra-Alta (Escalado automático basado en disparadores, ej., KEDA, Knative). | Instantánea (Aprovisionamiento de cuentas de software). |
| **Latencia y Rendimiento** | Latencia determinista sub-milisegundo; fibra dedicada y velocidad de bus bare-metal. | Baja latencia; agregaciones de hosts aislados dentro de datacenters locales. | Variable (Dependiente del enrutamiento inter-AZ, colas del hipervisor, noisy neighbors). | Control abreviado sobre el stack de red; dependiente de la capa de enrutamiento de Ingress. | Dependiente del tránsito de internet y del rendimiento de la CDN del proveedor. |
| **Radio de Impacto (Blast Radius) y Multinquilino** | Aislamiento air-gapped por chasis/VLAN. | Aislado mediante hipervisores virtualizados por hardware (KVM, ESXi) y redes superpuestas (overlay). | Aislamiento de hipervisor multinquilino; límite de seguridad definido por la arquitectura de IAM & VPC. | Aislamiento de contenedores en runtime multinquilino (namespaces, cgroups, seccomp). | Capa multinquilino del proveedor; aislamiento de inquilinos administrado a través de la lógica de la aplicación. |

---

## 3. Manifiestos de Infraestructura y Despliegue

A continuación se presentan manifiestos completos de grado de producción que demuestran el aislamiento de cargas de trabajo y las configuraciones de despliegue para entornos de cómputo híbridos.

### 3.1 Infrastructure-as-a-Service: Configuración de Terraform para Gateways Híbridos Privados/Públicos
Este manifiesto de Terraform define un puente de red en la nube que conecta un entorno On-Premises a una Virtual Private Cloud (VPC) en la nube a través de un túnel VPN IPsec con controles de enrutamiento estrictos.

```hcl
# main.tf - Production Cloud Gateway Setup for On-Premises Interconnect
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

variable "onprem_gateway_ip" {
  type        = string
  description = "Public IP address of the on-premises edge router"
  default     = "198.51.100.1"
}

variable "onprem_cidr_block" {
  type        = string
  description = "CIDR block for the on-premises datacenter network"
  default     = "10.100.0.0/16"
}

resource "aws_vpc" "hybrid_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name        = "vpc-hybrid-production"
    Environment = "production"
    ManagedBy   = "Terraform"
  }
}

resource "aws_subnet" "private_compute" {
  vpc_id            = aws_vpc.hybrid_vpc.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-1a"

  tags = {
    Name = "subnet-private-us-east-1a"
  }
}

resource "aws_customer_gateway" "onprem_cgw" {
  bgp_asn    = 65000
  ip_address = variable.onprem_gateway_ip
  type       = "ipsec.1"

  tags = {
    Name = "cgw-datacenter-east"
  }
}

resource "aws_vpn_gateway" "vpg" {
  vpc_id = aws_vpc.hybrid_vpc.id

  tags = {
    Name = "vpg-hybrid-production"
  }
}

resource "aws_vpn_connection" "onprem_ipsec" {
  vpn_gateway_id      = aws_vpn_gateway.vpg.id
  customer_gateway_id = aws_customer_gateway.onprem_cgw.id
  type                = "ipsec.1"
  static_routes_only  = true

  tags = {
    Name = "vpn-onprem-ipsec-primary"
  }
}

resource "aws_vpn_connection_route" "onprem_route" {
  destination_cidr_block = variable.onprem_cidr_block
  vpn_connection_id      = aws_vpn_connection.onprem_ipsec.id
}

resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.hybrid_vpc.id

  route {
    cidr_block     = variable.onprem_cidr_block
    gateway_id     = aws_vpn_gateway.vpg.id
  }

  tags = {
    Name = "rt-private-hybrid"
  }
}

resource "aws_route_table_association" "private_assoc" {
  subnet_id      = aws_subnet.private_compute.id
  route_table_id = aws_route_table.private_rt.id
}
```

---

### 3.2 Carga de Trabajo de Contenedores en Platform-as-a-Service: Despliegue de Kubernetes en Producción
Un manifiesto de Deployment de Kubernetes que aplica las directrices de preparación para producción de SRE: requests/limits de recursos de cómputo, liveness/readiness probes, restricciones de distribución de topología de pods (pod topology spread constraints) y contextos de seguridad (security contexts).

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-processor-service
  namespace: production
  labels:
    app.kubernetes.io/name: payment-processor
    app.kubernetes.io/part-of: financial-platform
    app.kubernetes.io/managed-by: argocd
spec:
  replicas: 3
  selector:
    matchLabels:
      app: payment-processor
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 25%
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: payment-processor
        tier: backend
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchExpressions:
                    - key: app
                      operator: In
                      values:
                        - payment-processor
                topologyKey: kubernetes.io/hostname
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: payment-processor
      containers:
        - name: payment-api
          image: registry.internal.net/finance/payment-api:v2.4.1
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          ports:
            - name: http-metrics
              containerPort: 8080
              protocol: TCP
          resources:
            requests:
              cpu: "500m"
              memory: "512Mi"
            limits:
              cpu: "2000m"
              memory: "2Gi"
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 15
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /ready
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 2
            successThreshold: 1
            failureThreshold: 2
          env:
            - name: ENVIRONMENT
              value: "production"
            - name: POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
```

---

## 4. Flujos de Trabajo de Ejecución en CLI Real y Salidas Esperadas

### 4.1 Diagnósticos de Recursos de Hipervisor y Virtualización (KVM/QEMU On-Premises)
Inspección de la topología de cómputo del hipervisor, estados de máquinas virtuales y asignaciones de recursos de dominio a través de `virsh` y `numactl`.

```bash
$ virsh list --all
 Id   Name                   State
--------------------------------------
 1    kvm-prod-db-01         running
 2    kvm-prod-k8s-node-01   running
 3    kvm-prod-k8s-node-02   running
 -    kvm-stage-app-01       shut off

$ virsh vcpuinfo kvm-prod-db-01
VCPU:           0
CPU:            3
State:          running
CPU time:       14325.2s
CPU Affinity:   y---

VCPU:           1
CPU:            4
State:          running
CPU time:       13980.8s
CPU Affinity:   -y--

$ numactl --hardware
available: 2 nodes (0-1)
node 0 cpus: 0 1 2 3 4 5 6 7
node 0 size: 64280 MB
node 0 free: 12430 MB
node 1 cpus: 8 9 10 11 12 13 14 15
node 1 size: 64490 MB
node 1 free: 18910 MB
node distances:
node   0   1
  0:  10  21
  1:  21  10
```

### 4.2 Diagnósticos de API de Cómputo en Nube (Nube Privada IaaS OpenStack)
Interacción con las APIs de OpenStack Compute (Nova) y Network (Neutron) para verificar la cuota de inquilinos, la topología de red y el estado de los servidores.

```bash
$ openstack server list --flavor m1.large --status ACTIVE
+--------------------------------------+--------------------+--------+-----------------------------------+-------------------+----------------+
| ID                                   | Name               | Status | Networks                          | Image             | Flavor         |
+--------------------------------------+--------------------+--------+-----------------------------------+-------------------+----------------+
| a3b7c8d9-1234-5678-90ab-cdef12345678 | edge-router-prod-0 | ACTIVE | selfservice-net=10.20.0.14, 192.. | Ubuntu-22.04-LTS  | m1.large       |
| d9e8f7c6-4321-8765-ba09-fedc87654321 | k8s-worker-p-01    | ACTIVE | selfservice-net=10.20.0.22        | Rocky-Linux-9     | m1.large       |
+--------------------------------------+--------------------+--------+-----------------------------------+-------------------+----------------+

$ openstack quota show --usage tenant-production
+----------------------+--------+--------+-------+
| Resource             | In Use | Reserved| Limit |
+----------------------+--------+--------+-------+
| cores                |     48 |      0 |   100 |
| instances            |     12 |      0 |    20 |
| ram (MB)             |  98304 |      0 |204800 |
| floating-ips         |      4 |      0 |    10 |
| security-groups      |      8 |      0 |    25 |
+----------------------+--------+--------+-------+
```

### 4.3 Operaciones del Motor de Contenedores en Runtime (Podman/Docker On-Premises e IaaS)
Análisis de la conectividad de sockets de contenedores, límites de recursos de cgroup v2 y namespaces de runtime en una instancia de IaaS o host bare-metal.

```bash
$ podman ps --format "table {{.ID}} {{.Names}} {{.Status}} {{.Ports}}"
CONTAINER ID  NAMES                 STATUS                 PORTS
e7d8f9a0b1c2  ingress-envoy-proxy   Up 4 days ago          0.0.0.0:80->8080/tcp, 0.0.0.0:443->8443/tcp
f1e2d3c4b5a6  redis-cache-local     Up 2 days ago          127.0.0.1:6379->6379/tcp

$ podman inspect e7d8f9a0b1c2 --format '{{.HostConfig.CgroupMode}} | Memory: {{.HostConfig.Memory}} | NanoCpus: {{.HostConfig.NanoCpus}}'
unified | Memory: 1073741824 | NanoCpus: 2000000000

$ cat /sys/fs/cgroup/system.slice/libpod-e7d8f9a0b1c2.scope/memory.current
429512704
```

---

## 5. Guía de Verificación en Producción y Diagnóstico de Fallas

Al resolver problemas (troubleshooting) en infraestructura de nube y on-premises, los SREs deben aislar sistemáticamente los problemas a través de capas físicas, hipervisores, redes superpuestas (overlays) y runtimes de contenedores.

```
                  +-------------------------------------------------+
                  |      Failure Reported: Workload Degradation      |
                  +-------------------------------------------------+
                                           |
                                           v
                  +-------------------------------------------------+
                  | Layer 1: Is it a Physical / Host Level Issue?   |
                  | (dmesg, journalctl, ip link, lscpu, SMART)      |
                  +-------------------------------------------------+
                                           |
                           +---------------+---------------+
                           |                               |
                        [ YES ]                         [ NO ]
                           |                               |
                           v                               v
         +----------------------------------+    +----------------------------------+
         | Hardware Fault / Host OOM        |    | Layer 2: Hypervisor / Quota Issue|
         | Action: Drain Host, Re-provision |    | (virsh, openstack quota, dmesg)  |
         +----------------------------------+    +----------------------------------+
                                                           |
                                           +---------------+---------------+
                                           |                               |
                                        [ YES ]                         [ NO ]
                                           |                               |
                                           v                               v
                         +-------------------+           +----------------------------------+
                         | Steal Time / Cap  |           | Layer 3: Network / Overlay Issue |
                         | Action: Rebalance |           | (ping, traceroute, tc, ip route) |
                         +-------------------+           +----------------------------------+
                                                                           |
                                                           +---------------+---------------+
                                                           |                               |
                                                        [ YES ]                         [ NO ]
                                                           |                               |
                                                           v                               v
                                         +-------------------+           +----------------------------------+
                                         | MTU / Drop / BGP  |           | Layer 4: Container / App Level   |
                                         | Action: Fix VXLAN |           | (kubectl, cgroups, strace)       |
                                         +-------------------+           +----------------------------------+
```

### 5.1 Escenario 1: Alto CPU Steal Time (`%st`) en Instancias IaaS
- **Síntoma**: Las latencias de respuesta de la aplicación se disparan intermitentemente en una máquina virtual IaaS. Las métricas muestran un alto uso de CPU a pesar del bajo tráfico de la aplicación.
- **Causa Raíz**: Sobreasignación (overcommit) de CPU en el host hipervisor físico subyacente (efecto "noisy neighbor").
- **Flujo de Trabajo de Diagnóstico**:
  1. Inspeccionar el estado de ejecución de CPU usando `top` o `mpstat`:
     ```bash
     $ mpstat -P ALL 1 3
     Linux 5.15.0-101-generic (node-01)    08/06/2026      _x86_64_        (4 CPU)

     06:12:01 PM  CPU    %usr   %nice    %sys %iowait   %irq  %soft  %steal  %guest  %idle
     06:12:02 PM  all    8.50    0.00    2.10    0.00   0.00   0.40   42.00    0.00  47.00
     06:12:02 PM    0    7.00    0.00    1.00    0.00   0.00   0.00   45.00    0.00  47.00
     ```
  2. Notar que `%steal` está en **42.00%**. Esto indica que el planificador (scheduler) del hipervisor está reteniendo ciclos de CPU de esta instancia huésped para atender a otras VMs en el host físico.
  3. **Remediación**:
     - Migrar la instancia a un host aggregate dedicado / nodo de cómputo fijado (pinned).
     - Aumentar el tamaño (upsize) a tipos de instancia optimizados para cómputo con fijación (pinning) de hilos de CPU físicos a virtuales 1:1 (`vcpu_pin`).

---

### 5.2 Escenario 2: Blackhole de Path MTU Discovery (PMTUD) en Red Superpuesta (Network Overlay) en Túnel Híbrido
- **Síntoma**: Paquetes pequeños (ICMP ping, TCP handshake) tienen éxito entre nodos On-Premises y de Nube Pública sobre túneles IPsec/VXLAN, pero los contenidos grandes (HTTP GET, transferencias de archivos) se cuelgan indefinidamente.
- **Causa Raíz**: Las encapsulaciones de la red superpuesta externa (IPsec/Geneve/VXLAN) agregan 50–80 bytes de sobrecarga de encabezado (header overhead). Si el bit `DF` (Don't Fragment) está activado y los paquetes ICMP "Fragmentation Needed" son bloqueados por cortafuegos, los paquetes se descartan silenciosamente (silently dropped).
- **Flujo de Trabajo de Diagnóstico**:
  1. Probar el path MTU usando `ping` con tamaño de paquete y el bit DF habilitado:
     ```bash
     $ ping -c 2 -M do -s 1472 10.0.1.15
     PING 10.0.1.15 (10.0.1.15) 1472(1500) bytes of data.
     From 10.100.0.1 icmp_seq=1 Frag needed and DF set (mtu = 1420)
     ```
  2. Verificar la configuración de la interfaz de red en el host:
     ```bash
     $ ip link show eth0
     2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP group default qlen 1000
         link/ether 52:54:00:12:34:56 brd ff:ff:ff:ff:ff:ff
     ```
  3. **Remediación**:
     - Ajustar la fijación (clamping) de TCP Maximum Segment Size (MSS) en los routers de borde (edge routers):
       ```bash
       $ sudo iptables -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
       ```
     - O actualizar el MTU de la interfaz para contemplar los encabezados de overlay (por ejemplo, establecer el MTU en `1420` o habilitar jumbo frames `9000` a lo largo de la ruta física).

---

### 5.3 Escenario 3: Inanición (Starvation) de I/O de Almacenamiento de Contenedores en Subsistemas de Disco Compartidos
- **Síntoma**: Pods ejecutándose en un cluster administrado de Kubernetes registran tiempos de espera agotados (write timeouts) en escritura de disco. El estado del nodo muestra `DiskPressure`.
- **Causa Raíz**: Cargas de trabajo de contenedores coinsercionadas/co-localizadas que exceden la capacidad de IOPS del almacenamiento en bloque compartido.
- **Flujo de Trabajo de Diagnóstico**:
  1. Comprobar la latencia de I/O de disco y la profundidad de la cola (queue depth) usando `iostat`:
     ```bash
     $ iostat -xz 1 3
     Linux 5.15.0-101-generic (k8s-node-02) 

     Device:            r/s     w/s     rkB/s     wkB/s  rrqm/s  wrqm/s  %util astat  await
     vda               2.00  850.00     16.00  10485.00    0.00  120.00  99.80  4.50  145.20
     ```
  2. Notar que `%util` es **99.80%** y `await` (tiempo de cola + servicio) es **145.20 ms** (línea base saludable < 10ms).
  3. Identificar procesos acaparando IOPS usando `iotop`:
     ```bash
     $ sudo iotop -o -b -n 1
     TID  PRIO  USER     DISK READ  DISK WRITE  SWAPIN     IO>    COMMAND
     14205 be/4 10001       0.00 B/s   10.2 M/s  0.00 %  88.40 %  app-unthrottled-logger
     ```
  4. **Remediación**:
     - Aplicar límites de IOPS de StorageClass o mover cargas de trabajo de registro (logging) intensivas en escritura a buffers de red desacoplados (por ejemplo, buffers de disco de Fluentbit con límites o Kafka).
     - Aplicar requests/limits de `ephemeral-storage` en las especificaciones de pods de Kubernetes para evitar el acaparamiento de disco por parte de un solo pod.

---

## 6. Referencias

- Linux Professional Institute Open Source Essentials Certification:  
  [https://www.lpi.org/our-certifications/open-source-essentials-overview/](https://www.lpi.org/our-certifications/open-source-essentials-overview/)
- NIST Special Publication 800-145 (The NIST Definition of Cloud Computing):  
  [https://csrc.nist.gov/publications/detail/sp/800-145/final](https://csrc.nist.gov/publications/detail/sp/800-145/final)
- CNCF Cloud Native Definition:  
  [https://github.com/cncf/toc/blob/main/DEFINITION.md](https://github.com/cncf/toc/blob/main/DEFINITION.md)
- Kubernetes Production Workload Documentation:  
  [https://kubernetes.io/docs/concepts/workloads/controllers/deployment/](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/)
- Terraform AWS Provider Documentation:  
  [https://registry.terraform.io/providers/hashicorp/aws/latest/docs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- Red Hat Enterprise Linux Virtualization Administration Guide (KVM/virsh):  
  [https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/configuring_and_managing_virtualization/index](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/configuring_and_managing_virtualization/index)