# 2.2 Describir los servicios de compute y networking de Azure

**Examen:** AZ-900 (Microsoft Azure Fundamentals), versión del temario 2026-07-20
**Peso del dominio:** 9.62 — el subtema más pesado de "Describir la arquitectura y los servicios de Azure"
**Perfil de audiencia:** SRE / Platform Architect. El examen pregunta *qué* es cada servicio; este material cubre además *por qué la plataforma está construida así*, dónde se rompe en producción y cómo lo demostrás.

---

## 1. Motivación: el problema arquitectónico detrás de "compute y networking"

Todo incidente de producción que empieza con "la app está caída" se resuelve en una de cuatro preguntas:

1. **¿El workload está corriendo?** (ciclo de vida del compute, placement, capacidad)
2. **¿El paquete puede llegar hasta él?** (routing, filtrado, resolución de nombres)
3. **¿La plataforma está mandando tráfico a una instancia sana?** (probes, plano de balanceo)
4. **¿Cambia la respuesta si falla un rack, un datacenter o una región?** (topología de fault domains)

El catálogo de compute y networking de Azure no es un menú de productos intercambiables — es un conjunto de respuestas a esas cuatro preguntas en distintos puntos de una **curva de compromiso entre control y abstracción**. En un extremo sos dueño del kernel y de la tabla de ruteo (Virtual Machines + Virtual Network); en el otro sos dueño de una imagen de contenedor y una regla de escalado (Azure Container Apps, Azure Functions). Todo lo que hay en el medio es una negociación sobre de qué modos de falla querés hacerte responsable.

### 1.1 El escenario de producción usado a lo largo del documento

Una plataforma de pagos migrando desde un datacenter on-premises. Requisitos:

| Requisito | Consecuencia |
|---|---|
| API pública de checkout, con TLS terminado, inspección WAF, global | Front Door Premium → origin en App Gateway/Container Apps |
| Batch interno de settlement, corre de 03:00 a 05:00, con picos | Escalado por eventos hasta cero (Functions o Container Apps) |
| Motor de pricing que reemplaza un AIX legacy, licenciado por core | Virtual Machines con SKUs de cores restringidos; sin autoscale |
| Ningún workload puede salir a Internet sin auditoría | NAT Gateway + UDR hacia Azure Firewall; sin IPs públicas a nivel de instancia |
| El alcance PCI debe poder aislarse a nivel de red | Segmentación por subnets + NSG/ASG + Private Endpoints para PaaS |
| RTO 15 min / RPO 0 para la capa de API | Despliegue zone-redundant dentro de una región, multi-región activo/pasivo |
| Híbrido: settlement debe llegar al mainframe on-prem por enlaces privados | ExpressRoute con failover a VPN |

Nada en este documento es una lista abstracta de features; cada servicio se ubica contra esta topología.

---

## 2. Servicios de compute de Azure

### 2.1 La escalera de compute

```
                   You manage                              Azure manages
IaaS   VM                 OS, patching, runtime, scaling  | hypervisor, host, fabric
       VM Scale Set       OS image, scale rules           | instance lifecycle, FD/UD spread
PaaS   AKS                node pools, workloads, CNI      | control plane, etcd, API server
       App Service        app code, plan sizing           | OS, runtime, patching, TLS
       Container Apps     image, scale rule, revision     | K8s, KEDA, Envoy, Dapr, nodes
FaaS   Functions          function code, trigger          | everything, incl. instance count
       ACI                image, container group          | everything, no orchestration
```

**Regla arquitectónica práctica:** bajá *un escalón* solamente cuando un requisito concreto te obligue — un módulo de kernel, un binario licenciado, un presupuesto de latencia sub-milisegundo, un protocolo que no sea HTTP, o un control de compliance que exija agentes a nivel de host. Cada escalón hacia abajo transfiere una clase de falla (patching, capacidad, salud de nodos) del equipo de SRE de Microsoft al tuyo.

### 2.2 Azure Virtual Machines (IaaS)

Una VM es un SO invitado sobre el hipervisor de Azure, compuesta por: un **recurso VM**, una o más **NICs**, **managed disks** (SO + datos), una **IP pública** opcional, y la pertenencia a un **constructo de placement** (availability set, availability zone, scale set o dedicated host).

**Familias de SKU de VM** — la letra es el contrato de workload, no marketing:

| Familia | Propósito | Uso típico en producción | Notas |
|---|---|---|---|
| B | Burstable, créditos de CPU | dev/test, agentes de bajo tráfico | agotar los créditos = throttling silencioso; nunca para una DB de prod |
| D / Dv5 / Dasv5 | Propósito general | capa web, servidores de aplicación | balanceado vCPU:RAM 1:4 |
| E / Ev5 / Easv5 | Optimizada para memoria | cachés en memoria, SQL | 1:8 |
| F / Fsv2 | Optimizada para cómputo | batch, encoding, game servers | 1:2 |
| L / Lsv3 | Optimizada para almacenamiento | NoSQL, NVMe local | disco local efímero, no durable |
| M | Memoria muy grande | SAP HANA | hasta varios TB de RAM |
| N (NC/ND/NV) | GPU | training, inference, visualización | la cuota es por familia, pedila temprano |
| H | HPC, InfiniBand | CFD, simulación | fabric RDMA |

Los **SKUs de cores restringidos** (por ejemplo `Standard_E32-8s_v5`) exponen 8 vCPUs al SO mientras retienen toda la memoria y la I/O del tamaño de 32 vCPUs. Esto existe *únicamente* para reducir el licenciamiento por core (Oracle, SQL Server) sin reducir RAM/IOPS. Es la respuesta correcta al requisito del "motor de pricing licenciado por core" de arriba.

**Tipos de disco y su consecuencia sobre el SLA:**

| Disco | IOPS máx./disco (aprox.) | Latencia | Usado para |
|---|---|---|---|
| Standard HDD | 2,000 | ms | backups, datos fríos |
| Standard SSD | 6,000 | ms bajos | dev/test, producción liviana |
| Premium SSD v1 | 20,000 | sub-ms | SO + datos de producción |
| Premium SSD v2 | 80,000, IOPS desacopladas del tamaño | sub-ms | producción, ajustable |
| Ultra Disk | 400,000 | sub-ms, configurable | bases de datos tier-1 |

La elección de disco **no** es meramente de performance — el SLA de una VM de instancia única está definido por ella (ver §2.4).

### 2.3 Placement: availability sets, availability zones, scale sets

Este es el concepto de mayor rendimiento de todo el dominio, y el que más seguido se responde mal.

**Fault Domain (FD):** un rack — energía y switch top-of-rack compartidos. Perder un FD es una falla física.
**Update Domain (UD):** un grupo de mantenimiento — Azure reinicia un UD por vez durante el mantenimiento planificado del host.

| Constructo | Protege contra | Alcance | Distribución máxima |
|---|---|---|---|
| Availability Set | falla de rack + mantenimiento planificado del host | un solo datacenter | hasta 3 FD, hasta 20 UD |
| Availability Zone | falla de datacenter (energía, refrigeración, red) | región, ≥3 zonas | 3 zonas |
| Region pair | desastre regional | ≥2 regiones | n/a |

Un availability set **no** sobrevive a una caída de datacenter. Un despliegue en availability zones sí. No podés poner una VM en un availability set y en una availability zone a la vez.

**Virtual Machine Scale Sets (VMSS)** — dos modos de orquestación:

| | Uniform | Flexible |
|---|---|---|
| Modelo de instancia | idénticas, gestionadas por el VMSS, no son `Microsoft.Compute/virtualMachines` reales | objetos VM reales, direccionables individualmente |
| SKUs mezclados / mezcla spot+regular | no | sí |
| Adjuntar una VM existente | no | sí |
| Control de fault domains | implícito | `platformFaultDomainCount` explícito |
| Semántica estilo availability set | no | sí (distribución en FD sin un set) |
| Recomendado para trabajo nuevo | legacy | **sí — el default desde 2023** |

La orquestación Flexible es la respuesta moderna: te da el autoscaling y las políticas de upgrade de los scale sets mientras cada instancia sigue siendo una VM de primera clase contra la que podés hacer `az vm run-command`, etiquetar individualmente y adjuntarle una NIC distinta.

### 2.4 Aritmética del SLA (por qué el placement es una decisión de negocio)

Microsoft publica compromisos de disponibilidad que dependen enteramente de la topología:

| Topología | Uptime mensual comprometido | Downtime aprox./mes |
|---|---|---|
| VM única, Standard HDD | 95% | ~36 h |
| VM única, Standard SSD (todos los discos) | 99.5% | ~3.6 h |
| VM única, Premium SSD / Ultra (todos los discos) | 99.9% | ~43 min |
| ≥2 VMs en un availability set | 99.95% | ~22 min |
| ≥2 VMs en ≥2 availability zones | 99.99% | ~4.4 min |

Dos consecuencias que los ingenieros suelen pasar por alto:

1. **Una sola VM con un disco de datos Standard HDD baja toda la VM al tier más bajo.** El SLA dice que *todos* los discos de SO y de datos deben cumplir con el tier. Un disco scratch HDD olvidado te cuesta dos nueves en el papel.
2. **Los SLA compuestos se multiplican.** Un camino de request de Front Door (99.99) → App Gateway (99.95) → conjunto de VMs (99.99) → SQL DB (99.99) da `0.9999 × 0.9995 × 0.9999 × 0.9999 ≈ 99.92%`. Agregar componentes *reduce* la disponibilidad salvo que cada uno sea redundante de forma independiente. Verificá siempre las cifras actuales en el documento de SLA vigente (§8) — son contractuales y cambian.

### 2.5 Contenedores

| Servicio | Abstracción | Escala a cero | Ingress | Mejor para |
|---|---|---|---|---|
| **Azure Container Instances (ACI)** | un container group (1..n contenedores que comparten ciclo de vida, red y volúmenes) | n/a (facturación por segundo, vos lo arrancás/parás) | IP pública o inyección en VNet | jobs de corta vida, runners de CI, burst de virtual nodes de AKS |
| **Azure Container Apps** | contenedores serverless sobre un Kubernetes gestionado + KEDA + Envoy + Dapr | **sí** | ingress HTTP/TCP incorporado, división de tráfico por revisión | microservicios, APIs orientadas a eventos, workers en segundo plano |
| **Azure Kubernetes Service (AKS)** | control plane de Kubernetes gestionado | no (nodos ≥1, salvo virtual nodes) | lo que instales | API completa de K8s, operators, CRDs, service mesh, plataformas multi-tenant |
| **Azure Red Hat OpenShift** | OpenShift gestionado | no | routes de OpenShift | organizaciones estandarizadas en OpenShift |

**Cuándo elegir AKS por sobre Container Apps:** cuando necesitás la API de Kubernetes en sí — CRDs, admission webhooks, operators, DaemonSets, tuning a nivel de nodo, un service mesh que vos controlás, o node pools con GPU y device plugins. Si tu lista de requisitos es "corré este contenedor, escalalo según una cola, dale HTTPS y un private endpoint", Container Apps elimina toda una clase de trabajo de guardia (upgrades de nodos, agotamiento de IPs de CNI, tuning del cluster autoscaler) a cambio de la superficie de la API de K8s.

Los **tiers de precios de AKS** importan para el SLA:

| Tier | Compromiso del control plane | Notas |
|---|---|---|
| Free | SLO de mejor esfuerzo, sin SLA financiero | solo dev/test |
| Standard | SLA respaldado financieramente (mayor con availability zones) | default de producción |
| Premium | Standard + soporte de largo plazo para minors viejos de K8s | parques regulados de movimiento lento |

### 2.6 Azure App Service

PaaS para workloads HTTP (Web Apps, API Apps, WebJobs, hosting adyacente a Logic Apps). Vos desplegás código o un contenedor; Azure es dueño del SO, el patching del runtime, la terminación TLS y el scale-out.

**Tiers de App Service Plan:**

| Tier | Scale-out | Dominio propio + TLS | Integración con VNet | Redundancia de zona | Uso |
|---|---|---|---|---|---|
| Free (F1) / Shared (D1) | ninguno | limitado | no | no | experimentos |
| Basic (B1–B3) | manual | sí | sí (regional) | no | dev/test |
| Standard (S1–S3) | autoscale | sí | sí | no | producción chica |
| Premium v3 (P0v3–P5v3) | autoscale, más RAM/CPU | sí | sí | **sí** | default de producción |
| Isolated v2 (I1v2+) | autoscale, dedicado | sí | inyectado en tu VNet | sí | PCI/regulado, solo privado |

Features clave de producción: **deployment slots** (swap con etapa de warm-up, y el swap es un cambio de ruteo, no un redeploy), **integración regional con VNet** para salida hacia recursos privados, **Private Endpoint** para entrada privada, y **Always On** (sin él, la app Free/Basic se descarga tras 20 minutos de inactividad y el primer request paga un cold start).

### 2.7 Azure Functions

Código orientado a eventos. La unidad es un *trigger* + *bindings*, no un servidor.

| Plan de hosting | Escala a cero | Cold start | Duración máx. (default/máx.) | VNet | Uso |
|---|---|---|---|---|---|
| Consumption | sí | sí | 5 min / 10 min | limitado | picos, barato, tolerante a la latencia |
| Flex Consumption | sí | reducido (instancias always-ready) | configurable | sí | default moderno para serverless |
| Premium (Elastic) | no (pre-calentado) | ninguno | 30 min / sin límite | sí | sensible a la latencia, networking privado |
| Dedicated (App Service plan) | no | ninguno | 30 min / sin límite | sí | reutilizar capacidad de un plan existente |
| Hosting en Container Apps | sí | sí | n/a | sí | Functions junto a otros contenedores |

**El muro de los 10 minutos es una restricción de arquitectura, no una perilla.** Si tu job de settlement tarda 40 minutos, Consumption es la elección equivocada: usá Durable Functions con fan-out/fan-in, un job de Container Apps o un pool de Batch. Elegir Consumption y descubrir el timeout en producción es la caída serverless clásica.

### 2.8 Azure Virtual Desktop

VDI/DaaS: Windows 10/11 **multi-session** (un SKU cliente de Windows que permite usuarios concurrentes — no disponible on-prem), host pools pooled o personales, contenedores de perfil FSLogix sobre Azure Files, y licenciamiento por usuario. Arquitectónicamente es una flota tipo VMSS de session hosts más un control plane de brokering/gateway gestionado por Microsoft; vos sos dueño de los session hosts y de la imagen dorada.

### 2.9 Tabla de decisión de compute para la plataforma de referencia

| Workload | Elección | Razón |
|---|---|---|
| API de checkout | Container Apps (workload profile Consumption) | HTTP, escala a un mínimo bajo, canary por revisiones, sin operar K8s |
| Batch de settlement (03:00–05:00) | **Job** de Container Apps (programado) o Durable Functions | supera los 10 min → no sirve Consumption puro |
| Motor de pricing (licenciado por core) | VM, cores restringidos `Standard_E32-8s_v5`, par zone-redundant | licenciamiento + sin autoscale + limitado por memoria |
| Servicios de plataforma, operators, mesh | AKS tier Standard, 3 zonas | necesita la API de Kubernetes |
| Arreglos de datos ad-hoc / agentes de CI | ACI | facturación por segundo, sin costo ocioso |

---

## 3. Servicios de networking de Azure

### 3.1 Fundamentos de Virtual Network

Una **VNet** es una red L3 aislada sin broadcast, con un espacio de direcciones privado que vos controlás. Las subnets la particionan; una NIC vive en exactamente una subnet.

**Azure reserva 5 direcciones IP en cada subnet:**

| Dirección | Propósito |
|---|---|
| `x.x.x.0` | dirección de red |
| `x.x.x.1` | gateway por defecto |
| `x.x.x.2` | mapeo de Azure DNS |
| `x.x.x.3` | mapeo de Azure DNS (reservado para el futuro) |
| `x.x.x.255` (la última) | broadcast |

Así que un `/24` da **251** direcciones utilizables, no 254. La subnet soportada más chica es `/29` (3 utilizables). Equivocate en esto al dimensionar una subnet de AKS con Azure CNI y vas a chocar contra el agotamiento de IPs en el scale-out — cada pod consume una IP de la VNet.

**Nombres de subnet reservados** (el nombre es funcional; Azure hace match sobre el string exacto):

| Nombre | Tamaño mínimo | Servicio |
|---|---|---|
| `GatewaySubnet` | `/29` (usá `/27`) | VPN Gateway / ExpressRoute Gateway |
| `AzureFirewallSubnet` | `/26` | Azure Firewall |
| `AzureBastionSubnet` | `/26` | Azure Bastion |
| `RouteServerSubnet` | `/27` | Azure Route Server |
| (dedicada, cualquier nombre) | `/24` recomendado | Application Gateway v2 |

**168.63.129.16** es la IP virtual de plataforma de Azure, alcanzable desde toda VNet. Sirve DNS, entrega leases DHCP, origina los **health probes del load balancer** y transporta el heartbeat del guest agent. Bloquearla en un NSG o en el firewall del host rompe los health probes y las extensiones del agente — y el síntoma es "el load balancer dice que mi VM sana está unhealthy". Memorizá la dirección.

### 3.2 Network Security Groups y Application Security Groups

Un **NSG** es un filtro stateful de 5-tuplas asociable a una **subnet** y/o a una **NIC**. Las reglas tienen una prioridad de 100 a 4096, gana el número más bajo, y la evaluación se detiene en la primera coincidencia. Como es stateful, el tráfico de retorno de un flujo entrante permitido se permite automáticamente — no escribís una regla saliente espejada.

**Reglas por defecto (no se pueden borrar, solo sobrescribir con números de prioridad más bajos):**

| Dirección | Prioridad | Nombre | Efecto |
|---|---|---|---|
| Inbound | 65000 | `AllowVnetInBound` | permitir VirtualNetwork → VirtualNetwork |
| Inbound | 65001 | `AllowAzureLoadBalancerInBound` | probes desde el tag `AzureLoadBalancer` |
| Inbound | 65500 | `DenyAllInBound` | denegar |
| Outbound | 65000 | `AllowVnetOutBound` | permitir |
| Outbound | 65001 | `AllowInternetOutBound` | permitir |
| Outbound | 65500 | `DenyAllOutBound` | denegar |

**Orden de evaluación cuando existen un NSG de subnet y un NSG de NIC:** el tráfico entrante pega primero contra el **NSG de la subnet, después contra el de la NIC**; el saliente es al revés (NIC, después subnet). Ambos deben permitir. Esta es la causa número uno de "agregué una regla de allow y sigue sin funcionar".

Los **service tags** (`Internet`, `VirtualNetwork`, `AzureLoadBalancer`, `Storage`, `Sql`, `AzureActiveDirectory`, `AzureCloud.<region>`) son conjuntos de prefijos mantenidos por Microsoft — usalos en vez de hardcodear CIDRs que cambian.

Los **Application Security Groups (ASG)** te permiten escribir reglas contra *roles de workload* en lugar de IPs: poné las NICs en `asg-web` y `asg-db`, y después escribí "permitir 5432 desde `asg-web` hacia `asg-db`". La regla sobrevive al recambio de IPs y al scale-out. Así es como mantenés legible un modelo de segmentación PCI.

### 3.3 Conectividad entre redes

| Opción | Capa | Transitiva | Ancho de banda | Cifrado | Uso |
|---|---|---|---|---|---|
| **VNet peering** (regional) | backbone de Azure | **no** | limitado por la NIC de la VM | no por defecto (opción disponible en SKUs soportados) | hub-spoke, spoke a servicios compartidos |
| **Global VNet peering** | backbone de Azure | no | limitado por la NIC de la VM | ídem arriba | privado entre regiones |
| **Site-to-Site VPN** | IPsec/IKEv2 sobre Internet | vía gateway transit | ~650 Mbps – 10 Gbps según SKU | sí | sucursales, respaldo de ER |
| **Point-to-Site VPN** | IPsec / OpenVPN / SSTP | n/a | por cliente | sí | desarrolladores, acceso de salto |
| **ExpressRoute** | circuito privado vía proveedor | vía ER + Global Reach | 50 Mbps – 100 Gbps | no (agregá MACsec/IPsec) | interconexión de datacenter, latencia predecible |
| **Virtual WAN** | malla de hubs gestionada | **sí (any-to-any)** | escala con el hub | por enlace | muchas sucursales/regiones |

**El peering no es transitivo.** Spoke-A ↔ Hub ↔ Spoke-B **no** te da Spoke-A ↔ Spoke-B. Obtenés spoke-a-spoke solo con (a) ruteo a través de una NVA/Azure Firewall en el hub usando UDRs, (b) peering directo spoke-a-spoke (el problema n²), o (c) Virtual WAN, que implementa el tránsito por vos.

**Gateway transit** es el flag del peering que permite a un spoke usar el gateway VPN/ExpressRoute del hub — sin él, cada spoke necesita su propio gateway (caro y lento de aprovisionar).

**Tipos de peering de ExpressRoute:** *Private peering* (tus VNets, RFC1918) y *Microsoft peering* (endpoints de Microsoft 365 / PaaS público sobre el circuito). El public peering está deprecado. **ExpressRoute Global Reach** conecta dos sitios on-prem *entre sí* a través del backbone de Microsoft.

### 3.4 Balanceo de carga: elegir el plano correcto

Cuatro servicios, distinguidos por **capa** y **alcance**:

| Servicio | Capa OSI | Alcance | Protocolos | Capacidades clave |
|---|---|---|---|---|
| **Azure Load Balancer** (Standard) | L4 | regional (zone-redundant o zonal) | TCP, UDP | latencia ultra baja, HA ports, reglas de salida, miles de flujos, sin inspección de payload |
| **Application Gateway** (v2) | L7 | regional | HTTP/S, HTTP/2, WebSocket | WAF, ruteo por path de URL y host, terminación/re-cifrado TLS, afinidad por cookie, reescritura de headers/URL, autoscaling |
| **Azure Front Door** (Std/Premium) | L7 | **global**, anycast | HTTP/S | TLS en el borde, caching/CDN, WAF en el borde, split TCP, origins con Private Link (Premium), failover global |
| **Traffic Manager** | DNS (tipo L7, sin data path) | **global** | cualquiera (solo responde DNS) | métodos de ruteo detallados abajo; el tráfico nunca lo atraviesa |

**Métodos de ruteo de Traffic Manager:** Priority (activo/pasivo), Weighted (canary/blue-green por porcentaje), Performance (menor latencia de red), Geographic (ruteo por soberanía de datos), MultiValue (devuelve varios endpoints sanos), Subnet (mapea CIDR del cliente → endpoint). Como es DNS, el failover está acotado por el **TTL**: un TTL de 300 segundos significa hasta 5 minutos de clientes resolviendo todavía al endpoint muerto. Front Door, en cambio, hace failover dentro del data path anycast en segundos — esta es la diferencia decisiva para un RTO de 15 minutos con expectativas de menos de un minuto.

**Composición canónica para la plataforma de referencia:**

```
Client
  └─ Azure Front Door Premium      (global anycast, WAF, TLS, caching, origin failover)
       ├─ origin: region primary → Application Gateway WAF_v2 (zone-redundant)
       │                              └─ backend pool: VMSS Flexible (3 zones)
       └─ origin: region secondary → App Gateway (warm standby)
Internal
  └─ Internal Standard Load Balancer (HA ports) → Azure Firewall → spokes
```

**El Standard Load Balancer es "seguro por defecto":** a diferencia del SKU Basic ya retirado, no permite tráfico entrante salvo que un NSG lo autorice explícitamente. Sumá a esto el retiro del **acceso de salida por defecto** — las VMs desplegadas en subnets nuevas ya no reciben una dirección de SNAT saliente implícita — y la regla práctica queda: **definí siempre la salida de forma explícita**, vía NAT Gateway (preferido), reglas de salida del load balancer, o una IP pública de instancia. NAT Gateway provee ~64.512 puertos SNAT por IP pública adjunta y elimina el modo de falla de agotamiento de SNAT que aqueja a la salida basada en load balancer bajo alta rotación de conexiones.

### 3.5 Acceso privado a PaaS: Service Endpoints vs Private Endpoints

| | Service Endpoint | Private Endpoint |
|---|---|---|
| Mecanismo | la identidad de la subnet se extiende al firewall del PaaS; el tráfico se queda en el backbone pero usa el endpoint **público** | una **NIC con una IP privada en tu subnet**, mapeada a un recurso PaaS específico vía Private Link |
| Requiere cambio de DNS | no | **sí** — zona DNS privada `privatelink.*` |
| Alcanzable desde on-prem (VPN/ER) | no | **sí** |
| Granularidad | todo el servicio en la región | un recurso específico (esta storage account, este sub-recurso blob) |
| Control de exfiltración de datos | débil (cualquier cuenta del servicio es alcanzable) | fuerte |
| Costo | gratis | por endpoint + por GB |

Para cualquier cosa dentro del alcance PCI, la respuesta es Private Endpoint. El modo de falla a anticipar: el private endpoint está creado pero el DNS sigue resolviendo el registro A público, así que el tráfico sale por el camino de Internet y el firewall del storage lo deniega. **Verificá el DNS, no solo el objeto endpoint.**

### 3.6 Azure DNS, Bastion, Firewall

- **Azure DNS** — hosting autoritativo para zonas públicas; las **Private DNS zones** resuelven nombres dentro de las VNets y son el acompañante obligatorio de los Private Endpoints (el auto-registro de los registros de VM es opcional por cada virtual-network link).
- **Azure Bastion** — jump host gestionado: RDP/SSH sobre TLS en el portal o vía cliente nativo, sin IP pública en la VM destino, sin VM de bastión que parchear. Requiere la `AzureBastionSubnet` (`/26`+). SKUs: Developer (compartido, sin subnet, solo dev), Basic, Standard (unidades de escala, cliente nativo, conexión basada en IP), Premium (grabación de sesiones, despliegue solo privado).
- **Azure Firewall** — NVA stateful consciente de FQDNs, con threat intelligence, DNAT/SNAT, colecciones de reglas de red y de aplicación, y un tier Premium que agrega inspección TLS e IDPS. Es el destino del tunelado forzado del hub para el requisito de "sin salida sin auditar".

---

## 4. Infraestructura y manifiestos (completos, desplegables)

### 4.1 Red hub-and-spoke — Bicep

`network-hub-spoke.bicep`:

```bicep
targetScope = 'resourceGroup'

@description('Deployment region for all networking resources.')
param location string = resourceGroup().location

@description('Environment discriminator used in resource names.')
@allowed([ 'dev', 'stg', 'prod' ])
param env string = 'prod'

param hubAddressSpace string   = '10.0.0.0/22'
param spokeAddressSpace string = '10.10.0.0/20'

var hubName   = 'vnet-hub-${env}-${location}'
var spokeName = 'vnet-app-${env}-${location}'

// ---------------------------------------------------------------- ASGs
resource asgWeb 'Microsoft.Network/applicationSecurityGroups@2023-11-01' = {
  name: 'asg-web-${env}'
  location: location
}

resource asgApp 'Microsoft.Network/applicationSecurityGroups@2023-11-01' = {
  name: 'asg-app-${env}'
  location: location
}

resource asgData 'Microsoft.Network/applicationSecurityGroups@2023-11-01' = {
  name: 'asg-data-${env}'
  location: location
}

// ---------------------------------------------------------------- NSGs
resource nsgWeb 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-web-${env}'
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow-AppGw-Management'
        properties: {
          description: 'Application Gateway v2 health/management plane. Mandatory.'
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'GatewayManager'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '65200-65535'
        }
      }
      {
        name: 'Allow-LB-Probe'
        properties: {
          description: 'Health probes originate from 168.63.129.16 (AzureLoadBalancer tag).'
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'Allow-Https-From-Internet'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationApplicationSecurityGroups: [ { id: asgWeb.id } ]
          destinationPortRange: '443'
        }
      }
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource nsgApp 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-app-${env}'
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow-Web-To-App-8080'
        properties: {
          description: 'Role-based rule: survives re-IP and scale-out.'
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceApplicationSecurityGroups: [ { id: asgWeb.id } ]
          sourcePortRange: '*'
          destinationApplicationSecurityGroups: [ { id: asgApp.id } ]
          destinationPortRange: '8080'
        }
      }
      {
        name: 'Allow-LB-Probe'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'Deny-Direct-Internet-Egress'
        properties: {
          description: 'Egress must traverse the hub firewall via UDR, never break out locally.'
          priority: 4000
          direction: 'Outbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// ---------------------------------------------------------------- Egress
resource pipNat 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: 'pip-nat-${env}'
  location: location
  sku: { name: 'Standard' }
  zones: [ '1', '2', '3' ]
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    idleTimeoutInMinutes: 4
  }
}

resource natGw 'Microsoft.Network/natGateways@2023-11-01' = {
  name: 'natgw-${env}'
  location: location
  sku: { name: 'Standard' }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [ { id: pipNat.id } ]
  }
}

// ---------------------------------------------------------------- Routing
resource rtSpoke 'Microsoft.Network/routeTables@2023-11-01' = {
  name: 'rt-spoke-${env}'
  location: location
  properties: {
    disableBgpRoutePropagation: true
    routes: [
      {
        name: 'default-via-firewall'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: '10.0.1.4'   // AzureFirewallSubnet private IP
        }
      }
      {
        name: 'onprem-via-firewall'
        properties: {
          addressPrefix: '192.168.0.0/16'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: '10.0.1.4'
        }
      }
    ]
  }
}

// ---------------------------------------------------------------- VNets
resource hub 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: hubName
  location: location
  properties: {
    addressSpace: { addressPrefixes: [ hubAddressSpace ] }
    subnets: [
      { name: 'GatewaySubnet',      properties: { addressPrefix: '10.0.0.0/27' } }
      { name: 'AzureFirewallSubnet', properties: { addressPrefix: '10.0.1.0/26' } }
      { name: 'AzureBastionSubnet',  properties: { addressPrefix: '10.0.2.0/26' } }
      {
        name: 'snet-shared'
        properties: {
          addressPrefix: '10.0.3.0/24'
          privateEndpointNetworkPolicies: 'Enabled'
        }
      }
    ]
  }
}

resource spoke 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: spokeName
  location: location
  properties: {
    addressSpace: { addressPrefixes: [ spokeAddressSpace ] }
    subnets: [
      {
        name: 'snet-appgw'
        properties: {
          addressPrefix: '10.10.0.0/24'   // dedicated, /24 recommended
          networkSecurityGroup: { id: nsgWeb.id }
        }
      }
      {
        name: 'snet-app'
        properties: {
          addressPrefix: '10.10.1.0/24'
          networkSecurityGroup: { id: nsgApp.id }
          routeTable: { id: rtSpoke.id }
          natGateway: { id: natGw.id }
        }
      }
      {
        name: 'snet-aks-nodes'
        properties: {
          addressPrefix: '10.10.8.0/21'   // sized for Azure CNI pod IPs
          routeTable: { id: rtSpoke.id }
          natGateway: { id: natGw.id }
        }
      }
      {
        name: 'snet-pep'
        properties: {
          addressPrefix: '10.10.2.0/24'
          privateEndpointNetworkPolicies: 'Enabled'
        }
      }
    ]
  }
}

// ---------------------------------------------------------------- Peering
resource hubToSpoke 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-11-01' = {
  parent: hub
  name: 'peer-hub-to-spoke'
  properties: {
    remoteVirtualNetwork: { id: spoke.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: true        // hub owns the VPN/ER gateway
    useRemoteGateways: false
  }
}

resource spokeToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-11-01' = {
  parent: spoke
  name: 'peer-spoke-to-hub'
  properties: {
    remoteVirtualNetwork: { id: hub.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: true          // consume the hub gateway; no gateway per spoke
  }
}

output hubId string   = hub.id
output spokeId string = spoke.id
output asgWebId string  = asgWeb.id
output asgAppId string  = asgApp.id
output asgDataId string = asgData.id
output natGatewayPublicIp string = pipNat.properties.ipAddress
```

### 4.2 VMSS zone-redundant detrás de un Standard Load Balancer — Terraform

`vmss-lb.tf`:

```hcl
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
  }
}

provider "azurerm" {
  features {}
}

variable "resource_group_name" { type = string  default = "rg-platform-prod" }
variable "location"            { type = string  default = "westeurope" }
variable "subnet_id"           { type = string }
variable "instance_sku"        { type = string  default = "Standard_D4as_v5" }

# ----------------------------------------------------------- Load Balancer
resource "azurerm_public_ip" "lb" {
  name                = "pip-lb-pricing-prod"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"          # Basic SKU is retired
  zones               = ["1", "2", "3"]     # zone-redundant frontend
}

resource "azurerm_lb" "pricing" {
  name                = "lb-pricing-prod"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Standard"

  frontend_ip_configuration {
    name                 = "fe-public"
    public_ip_address_id = azurerm_public_ip.lb.id
  }
}

resource "azurerm_lb_backend_address_pool" "pricing" {
  name            = "bepool-pricing"
  loadbalancer_id = azurerm_lb.pricing.id
}

resource "azurerm_lb_probe" "http" {
  name                = "probe-health-8080"
  loadbalancer_id     = azurerm_lb.pricing.id
  protocol            = "Http"
  port                = 8080
  request_path        = "/healthz"
  interval_in_seconds = 5
  number_of_probes    = 2
}

resource "azurerm_lb_rule" "https" {
  name                           = "rule-https"
  loadbalancer_id                = azurerm_lb.pricing.id
  protocol                       = "Tcp"
  frontend_port                  = 443
  backend_port                   = 8443
  frontend_ip_configuration_name = "fe-public"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.pricing.id]
  probe_id                       = azurerm_lb_probe.http.id
  idle_timeout_in_minutes        = 15
  enable_tcp_reset               = true
  disable_outbound_snat          = true   # egress handled by NAT Gateway
}

# ----------------------------------------------------------- Scale Set
resource "azurerm_linux_virtual_machine_scale_set" "pricing" {
  name                = "vmss-pricing-prod"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = var.instance_sku
  instances           = 3
  zones               = ["1", "2", "3"]
  zone_balance        = true              # refuse to converge into a single zone

  admin_username                  = "azureuser"
  disable_password_authentication = true

  admin_ssh_key {
    username   = "azureuser"
    public_key = file("~/.ssh/id_ed25519.pub")
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  os_disk {
    storage_account_type = "Premium_LRS"   # Premium on ALL disks or the SLA tier drops
    caching              = "ReadWrite"
  }

  data_disk {
    lun                  = 0
    caching              = "None"
    create_option        = "Empty"
    disk_size_gb         = 256
    storage_account_type = "Premium_LRS"
  }

  network_interface {
    name    = "nic-pricing"
    primary = true

    ip_configuration {
      name                                   = "ipconfig1"
      primary                                = true
      subnet_id                              = var.subnet_id
      load_balancer_backend_address_pool_ids = [azurerm_lb_backend_address_pool.pricing.id]
      # no public_ip_address block: instances are private-only
    }
  }

  health_probe_id = azurerm_lb_probe.http.id

  upgrade_mode = "Rolling"
  rolling_upgrade_policy {
    max_batch_instance_percent              = 20
    max_unhealthy_instance_percent          = 20
    max_unhealthy_upgraded_instance_percent = 20
    pause_time_between_batches              = "PT2M"
  }

  automatic_instance_repair {
    enabled      = true
    grace_period = "PT30M"
  }

  boot_diagnostics {}   # managed storage — required for serial console triage

  identity { type = "SystemAssigned" }

  tags = {
    workload    = "pricing-engine"
    criticality = "tier-1"
    owner       = "platform-sre"
  }
}

# ----------------------------------------------------------- Autoscale
resource "azurerm_monitor_autoscale_setting" "pricing" {
  name                = "autoscale-vmss-pricing"
  resource_group_name = var.resource_group_name
  location            = var.location
  target_resource_id  = azurerm_linux_virtual_machine_scale_set.pricing.id

  profile {
    name = "cpu-based"

    capacity {
      default = 3
      minimum = 3      # never below 3: one instance per zone
      maximum = 30
    }

    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.pricing.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT5M"
        time_aggregation   = "Average"
        operator           = "GreaterThan"
        threshold          = 70
      }
      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = "3"          # scale in multiples of 3 to stay zone-balanced
        cooldown  = "PT5M"
      }
    }

    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.pricing.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT15M"   # longer window down: avoid flapping
        time_aggregation   = "Average"
        operator           = "LessThan"
        threshold          = 30
      }
      scale_action {
        direction = "Decrease"
        type      = "ChangeCount"
        value     = "3"
        cooldown  = "PT15M"
      }
    }
  }
}

output "lb_public_ip" { value = azurerm_public_ip.lb.ip_address }
```

### 4.3 Azure Container Apps — manifiesto YAML completo

`checkout-api.containerapp.yaml`, aplicado con `az containerapp create --yaml`:

```yaml
location: westeurope
name: ca-checkout-api
resourceGroup: rg-platform-prod
type: Microsoft.App/containerApps
tags:
  workload: checkout-api
  criticality: tier-1
  owner: platform-sre
identity:
  type: SystemAssigned
properties:
  managedEnvironmentId: /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-platform-prod/providers/Microsoft.App/managedEnvironments/cae-prod-weu
  workloadProfileName: Consumption
  configuration:
    activeRevisionsMode: Multiple        # required for weighted canary
    maxInactiveRevisions: 5
    ingress:
      external: false                    # only reachable from the VNet / App Gateway
      targetPort: 8080
      exposedPort: 0
      transport: auto                    # negotiates HTTP/2 where possible
      allowInsecure: false
      clientCertificateMode: require     # mTLS from the gateway
      stickySessions:
        affinity: none
      corsPolicy:
        allowedOrigins:
          - https://checkout.example.com
        allowedMethods: [ GET, POST, OPTIONS ]
        allowCredentials: true
        maxAge: 600
      ipSecurityRestrictions:
        - name: allow-appgw-subnet
          description: Application Gateway subnet only
          ipAddressRange: 10.10.0.0/24
          action: Allow
      traffic:
        - revisionName: ca-checkout-api--v1-14-1
          weight: 90
          label: stable
        - latestRevision: true
          weight: 10
          label: canary
    registries:
      - server: acrplatprod.azurecr.io
        identity: system                 # managed identity, no admin password
    secrets:
      - name: servicebus-connection
        keyVaultUrl: https://kv-plat-prod.vault.azure.net/secrets/sb-checkout-conn
        identity: system
      - name: appinsights-connection
        keyVaultUrl: https://kv-plat-prod.vault.azure.net/secrets/ai-connstring
        identity: system
    dapr:
      enabled: true
      appId: checkout
      appPort: 8080
      appProtocol: http
      enableApiLogging: true
    maxInactiveRevisions: 5
  template:
    revisionSuffix: v1-14-2
    terminationGracePeriodSeconds: 45    # let in-flight payments drain
    containers:
      - name: checkout-api
        image: acrplatprod.azurecr.io/checkout-api:1.14.2
        resources:
          cpu: 1.0
          memory: 2Gi
        env:
          - name: ASPNETCORE_URLS
            value: http://+:8080
          - name: SERVICEBUS_CONNECTION
            secretRef: servicebus-connection
          - name: APPLICATIONINSIGHTS_CONNECTION_STRING
            secretRef: appinsights-connection
          - name: OTEL_SERVICE_NAME
            value: checkout-api
        probes:
          - type: Startup
            httpGet:
              path: /healthz/startup
              port: 8080
              scheme: HTTP
            initialDelaySeconds: 5
            periodSeconds: 5
            failureThreshold: 30        # 150 s budget for JIT + cache warm
          - type: Liveness
            httpGet:
              path: /healthz/live
              port: 8080
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 3
          - type: Readiness
            httpGet:
              path: /healthz/ready
              port: 8080
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 3
            successThreshold: 1
        volumeMounts:
          - volumeName: tmp
            mountPath: /tmp
    initContainers:
      - name: schema-check
        image: acrplatprod.azurecr.io/schema-check:1.4.0
        resources:
          cpu: 0.25
          memory: 0.5Gi
        env:
          - name: MODE
            value: verify-only
    volumes:
      - name: tmp
        storageType: EmptyDir
    scale:
      minReplicas: 2                     # no scale-to-zero on a tier-1 API
      maxReplicas: 40
      cooldownPeriod: 300
      pollingInterval: 15
      rules:
        - name: http-concurrency
          http:
            metadata:
              concurrentRequests: "50"
        - name: servicebus-backlog
          custom:
            type: azure-servicebus
            metadata:
              queueName: checkout-events
              messageCount: "20"
            auth:
              - secretRef: servicebus-connection
                triggerParameter: connection
```

### 4.4 Workload de AKS con un load balancer interno y distribución por zonas

`checkout-aks.yaml`:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  labels:
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout-api
  namespace: payments
  labels:
    app.kubernetes.io/name: checkout-api
    app.kubernetes.io/part-of: payments
spec:
  replicas: 6
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 2
      maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: checkout-api
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: checkout-api
      terminationGracePeriodSeconds: 45
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: checkout-api
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: checkout-api
      nodeSelector:
        agentpool: apps
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: checkout-api
          image: acrplatprod.azurecr.io/checkout-api:1.14.2
          ports:
            - name: http
              containerPort: 8080
          resources:
            requests:
              cpu: "500m"
              memory: "512Mi"
            limits:
              memory: "1Gi"
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: [ "ALL" ]
          startupProbe:
            httpGet: { path: /healthz/startup, port: http }
            periodSeconds: 5
            failureThreshold: 30
          livenessProbe:
            httpGet: { path: /healthz/live, port: http }
            periodSeconds: 10
            failureThreshold: 3
          readinessProbe:
            httpGet: { path: /healthz/ready, port: http }
            periodSeconds: 5
            failureThreshold: 3
          lifecycle:
            preStop:
              exec:
                command: [ "/bin/sh", "-c", "sleep 10" ]  # let endpoints drain
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: checkout-api
  namespace: payments
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-internal: "true"
    service.beta.kubernetes.io/azure-load-balancer-internal-subnet: "snet-app"
    service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path: "/healthz/ready"
    service.beta.kubernetes.io/azure-load-balancer-health-probe-interval: "5"
    service.beta.kubernetes.io/azure-load-balancer-tcp-idle-timeout: "15"
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local     # preserves client IP; probes only healthy nodes
  selector:
    app.kubernetes.io/name: checkout-api
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: checkout-api
  namespace: payments
spec:
  minAvailable: 4
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout-api
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: checkout-api-default-deny
  namespace: payments
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: checkout-api
  policyTypes: [ Ingress, Egress ]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress
      ports:
        - protocol: TCP
          port: 8080
  egress:
    - to:
        - namespaceSelector: {}
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
    - to:
        - ipBlock:
            cidr: 10.10.2.0/24     # private endpoints subnet only
      ports:
        - protocol: TCP
          port: 443
```

---

## 5. CLI: construir, inspeccionar, verificar

### 5.1 Aprovisionar la red

```console
$ az group create --name rg-platform-prod --location westeurope -o table
Location    Name
----------  ----------------
westeurope  rg-platform-prod

$ az deployment group create \
    --resource-group rg-platform-prod \
    --name net-hub-spoke-$(date +%Y%m%d%H%M) \
    --template-file network-hub-spoke.bicep \
    --parameters env=prod location=westeurope \
    --query "properties.outputs" -o jsonc
{
  "asgAppId": {
    "type": "String",
    "value": "/subscriptions/.../applicationSecurityGroups/asg-app-prod"
  },
  "asgWebId": {
    "type": "String",
    "value": "/subscriptions/.../applicationSecurityGroups/asg-web-prod"
  },
  "hubId": {
    "type": "String",
    "value": "/subscriptions/.../virtualNetworks/vnet-hub-prod-westeurope"
  },
  "natGatewayPublicIp": {
    "type": "String",
    "value": "20.61.144.87"
  },
  "spokeId": {
    "type": "String",
    "value": "/subscriptions/.../virtualNetworks/vnet-app-prod-westeurope"
  }
}
```

Confirmá la disposición de subnets y la aritmética de direcciones utilizables:

```console
$ az network vnet subnet list -g rg-platform-prod --vnet-name vnet-app-prod-westeurope \
    -o table --query "[].{Name:name, Prefix:addressPrefix, NSG:networkSecurityGroup.id, NAT:natGateway.id}"
Name           Prefix         NSG                                        NAT
-------------  -------------  -----------------------------------------  ----------------------------
snet-appgw     10.10.0.0/24   .../networkSecurityGroups/nsg-web-prod
snet-app       10.10.1.0/24   .../networkSecurityGroups/nsg-app-prod     .../natGateways/natgw-prod
snet-aks-nodes 10.10.8.0/21                                              .../natGateways/natgw-prod
snet-pep       10.10.2.0/24

$ az network vnet subnet show -g rg-platform-prod --vnet-name vnet-app-prod-westeurope \
    -n snet-app --query "{prefix:addressPrefix, available:availableIpAddressCount}" -o json
{
  "available": 251,
  "prefix": "10.10.1.0/24"
}
```

`251`, no `254` — las 5 direcciones reservadas, menos ninguna consumida todavía. Confirmar este número es la forma más rápida de demostrar que entendés la aritmética de subnets de Azure.

### 5.2 Estado del peering — la verificación que atrapa la mitad de todos los tickets de conectividad

```console
$ az network vnet peering list -g rg-platform-prod --vnet-name vnet-app-prod-westeurope \
    -o table --query "[].{Name:name, State:peeringState, Sync:peeringSyncLevel, UseRemoteGw:useRemoteGateways, Forwarded:allowForwardedTraffic}"
Name             State      Sync             UseRemoteGw    Forwarded
---------------  ---------  ---------------  -------------  -----------
peer-spoke-to-hub  Connected  FullyInSync      True           True
```

`peeringState` debe ser **`Connected` de los dos lados**. Un `Initiated` de un solo lado significa que el peering inverso nunca se creó y no fluye tráfico. `peeringSyncLevel: RemoteNotInSync` significa que se agregó un espacio de direcciones después de establecer el peering — corré `az network vnet peering sync` en ambos lados o el prefijo nuevo será invisible.

### 5.3 Compute: desplegar e inspeccionar

```console
$ terraform apply -auto-approve -var subnet_id=$(az network vnet subnet show \
    -g rg-platform-prod --vnet-name vnet-app-prod-westeurope -n snet-app --query id -o tsv)
...
Apply complete! Resources: 8 added, 0 changed, 0 destroyed.

Outputs:

lb_public_ip = "20.61.150.14"

$ az vmss list-instances -g rg-platform-prod -n vmss-pricing-prod \
    -o table --query "[].{Id:instanceId, Name:name, Zone:zones[0], State:provisioningState}"
Id    Name                 Zone    State
----  -------------------  ------  ----------
0     vmss-pricing-prod_0  1       Succeeded
1     vmss-pricing-prod_1  2       Succeeded
2     vmss-pricing-prod_2  3       Succeeded
```

Una instancia por zona — esto es lo que te gana el tier de 99.99%. Si las tres caen en la zona 1, `zone_balance` no fue configurado y tenés un despliegue de calidad availability-set con una etiqueta de availability-zone.

Verificá la salud del backend en el load balancer:

```console
$ az network lb address-pool address list -g rg-platform-prod \
    --lb-name lb-pricing-prod --pool-name bepool-pricing -o table
Name                          IpAddress    VirtualNetwork
----------------------------  -----------  --------------------------
vmss-pricing-prod_0-nic       10.10.1.4    vnet-app-prod-westeurope
vmss-pricing-prod_1-nic       10.10.1.5    vnet-app-prod-westeurope
vmss-pricing-prod_2-nic       10.10.1.6    vnet-app-prod-westeurope

$ az monitor metrics list --resource $(az network lb show -g rg-platform-prod \
    -n lb-pricing-prod --query id -o tsv) \
    --metric DipAvailability --interval PT1M --aggregation Average -o table
Timestamp            Name                        Average
-------------------  --------------------------  ---------
2026-09-04 09:41:00  Health Probe Status         100.0
2026-09-04 09:42:00  Health Probe Status         100.0
2026-09-04 09:43:00  Health Probe Status         66.67
```

`DipAvailability` por debajo de 100 significa que al menos un backend está fallando los probes. `66.67` con tres instancias = exactamente una instancia caída. Esta métrica es la mejor señal de alertado del load balancer.

### 5.4 Container Apps

```console
$ az containerapp env create \
    --name cae-prod-weu --resource-group rg-platform-prod --location westeurope \
    --infrastructure-subnet-resource-id $(az network vnet subnet show \
        -g rg-platform-prod --vnet-name vnet-app-prod-westeurope -n snet-aks-nodes --query id -o tsv) \
    --internal-only true --enable-workload-profiles true -o table
Name          Location     ResourceGroup     ProvisioningState
------------  -----------  ----------------  -------------------
cae-prod-weu  West Europe  rg-platform-prod  Succeeded

$ az containerapp create --yaml checkout-api.containerapp.yaml -o none
$ az containerapp revision list -n ca-checkout-api -g rg-platform-prod \
    -o table --query "[].{Revision:name, Active:properties.active, Replicas:properties.replicas, Traffic:properties.trafficWeight, Health:properties.healthState}"
Revision                      Active    Replicas    Traffic    Health
----------------------------  --------  ----------  ---------  ---------
ca-checkout-api--v1-14-1      True      4           90         Healthy
ca-checkout-api--v1-14-2      True      2           10         Healthy
```

Desplazá el canary después de que pase la verificación de burn-rate del SLO:

```console
$ az containerapp ingress traffic set -n ca-checkout-api -g rg-platform-prod \
    --revision-weight ca-checkout-api--v1-14-1=0 ca-checkout-api--v1-14-2=100 -o table
RevisionName                  Weight    Label
----------------------------  --------  -------
ca-checkout-api--v1-14-1      0         stable
ca-checkout-api--v1-14-2      100       canary
```

La ponderación de tráfico es un cambio de ruteo en el control plane: no se reinicia ningún pod, y el rollback es el mismo comando con los pesos invertidos. Por eso está puesto `activeRevisionsMode: Multiple` en el manifiesto.

### 5.5 Azure Container Instances — el job descartable

```console
$ az container create \
    --resource-group rg-platform-prod --name aci-reconcile-20260904 \
    --image acrplatprod.azurecr.io/reconcile:2.3.0 \
    --vnet vnet-app-prod-westeurope --subnet snet-app \
    --cpu 2 --memory 4 --restart-policy Never \
    --assign-identity --acr-identity system \
    --environment-variables RUN_DATE=2026-09-03 -o table
Name                     ResourceGroup     Status    Image                                        IP:ports    CPU/Memory        OsType
-----------------------  ----------------  --------  -------------------------------------------  ----------  ----------------  --------
aci-reconcile-20260904   rg-platform-prod  Running   acrplatprod.azurecr.io/reconcile:2.3.0                   2.0 core/4.0 gb   Linux

$ az container logs -g rg-platform-prod -n aci-reconcile-20260904 --tail 5
[2026-09-04T03:14:22Z] loaded 1,284,911 settlement rows
[2026-09-04T03:19:07Z] matched 1,284,903 (99.9994%)
[2026-09-04T03:19:07Z] unmatched 8 -> queue: reconcile-exceptions
[2026-09-04T03:19:08Z] wrote report blob: reports/2026-09-03.parquet
[2026-09-04T03:19:08Z] exit 0

$ az container show -g rg-platform-prod -n aci-reconcile-20260904 \
    --query "containers[0].instanceView.currentState" -o json
{
  "detailStatus": "Completed",
  "exitCode": 0,
  "finishTime": "2026-09-04T03:19:09.000000+00:00",
  "startTime": "2026-09-04T03:14:11.000000+00:00",
  "state": "Terminated"
}
```

Facturado por 298 segundos de 2 vCPU + 4 GB. Esta es la propuesta de valor de ACI: sin costo ocioso, sin orquestador.

### 5.6 App Service con slots

```console
$ az appservice plan create -g rg-platform-prod -n asp-portal-prod \
    --sku P1v3 --is-linux --zone-redundant --number-of-workers 3 -o table
Name             Location    Status    Sku    Workers
---------------  ----------  --------  -----  ---------
asp-portal-prod  West Europe  Ready     P1v3   3

$ az webapp create -g rg-platform-prod -p asp-portal-prod -n app-portal-prod \
    --runtime "PYTHON:3.12" -o none
$ az webapp deployment slot create -g rg-platform-prod -n app-portal-prod --slot staging -o none
$ az webapp config set -g rg-platform-prod -n app-portal-prod --always-on true -o none

$ az webapp deployment slot swap -g rg-platform-prod -n app-portal-prod \
    --slot staging --target-slot production --verbose
Command ran in 41.208 seconds.

$ az webapp show -g rg-platform-prod -n app-portal-prod \
    --query "{state:state, host:defaultHostName, https:httpsOnly, tls:siteConfig.minTlsVersion}" -o json
{
  "host": "app-portal-prod.azurewebsites.net",
  "https": true,
  "state": "Running",
  "tls": "1.2"
}
```

El swap primero calienta las instancias de staging y después da vuelta el ruteo — producción nunca sirve un worker frío. Ese calentamiento es la razón por la que un swap es más seguro que un redeploy, y por la que el rollback es un segundo swap que tarda los mismos ~40 segundos.

---

## 6. Verificación y diagnóstico de fallas

### 6.1 La escalera de triage

Trabajá de arriba hacia abajo; cada escalón elimina una capa.

| # | Pregunta | Comando | Firma de la falla |
|---|---|---|---|
| 1 | ¿El recurso está aprovisionado? | `az resource show --ids <id> --query provisioningState` | `Failed` → leé `az monitor activity-log` |
| 2 | ¿La instancia corre? | `az vmss get-instance-view` / `az containerapp replica list` | `PowerState/stopped`, `CrashLoopBackOff` |
| 3 | ¿El DNS resuelve a lo que esperás? | `nslookup <fqdn> 168.63.129.16` | IP pública donde se esperaba la IP de un private endpoint |
| 4 | ¿Qué regla de NSG decide sobre este paquete? | `az network watcher test-ip-flow` | `Deny` + el nombre de la regla que decide |
| 5 | ¿Adónde va realmente el paquete? | `az network watcher show-next-hop` | `None` (blackhole) o la NVA equivocada |
| 6 | ¿El camino funciona de punta a punta? | `az network watcher test-connectivity` | `ConnectionStatus` por salto |
| 7 | ¿El backend está sano para el LB? | `DipAvailability` / `show-backend-health` | timeouts de probe |
| 8 | ¿Qué hay en el cable? | `az network watcher packet-capture create` | SYN sin SYN-ACK = filtrado |

### 6.2 NSG: probar qué regla es la responsable

Nunca razones la precedencia de NSG desde la hoja del portal — preguntale a la plataforma.

```console
$ az network watcher test-ip-flow \
    --vm vmss-pricing-prod_0 --nic vmss-pricing-prod_0-nic \
    --resource-group rg-platform-prod \
    --direction Inbound --protocol TCP \
    --local 10.10.1.4:8080 --remote 10.10.0.7:51422 -o json
{
  "access": "Allow",
  "ruleName": "UserRule_Allow-Web-To-App-8080"
}

$ az network watcher test-ip-flow \
    --vm vmss-pricing-prod_0 --nic vmss-pricing-prod_0-nic \
    --resource-group rg-platform-prod \
    --direction Outbound --protocol TCP \
    --local 10.10.1.4:44012 --remote 13.107.42.14:443 -o json
{
  "access": "Deny",
  "ruleName": "UserRule_Deny-Direct-Internet-Egress"
}
```

El segundo resultado es intencional en este diseño — la salida debe atravesar el firewall vía UDR — pero esta es exactamente la salida que verías ante una caída accidental. Cuando una regla está denegando, volcá el conjunto de reglas **efectivo** (subnet + NIC fusionadas, en orden de evaluación):

```console
$ az network nic list-effective-nsg --name vmss-pricing-prod_0-nic -g rg-platform-prod \
    --query "value[].{NSG:networkSecurityGroup.id, Assoc:association.subnet.id}" -o table
NSG                                       Assoc
----------------------------------------  ----------------------------------------
.../networkSecurityGroups/nsg-app-prod    .../subnets/snet-app

$ az network nic list-effective-nsg --name vmss-pricing-prod_0-nic -g rg-platform-prod \
    --query "value[0].effectiveSecurityRules[?direction=='Inbound'] | \
             sort_by(@, &priority)[].{P:priority, Name:name, Access:access, Src:sourceAddressPrefix, Port:destinationPortRange}" \
    -o table
P      Name                                        Access    Src                 Port
-----  ------------------------------------------  --------  ------------------  ---------
100    UserRule_Allow-Web-To-App-8080              Allow     10.10.0.0/24        8080-8080
110    UserRule_Allow-LB-Probe                     Allow     AzureLoadBalancer   0-65535
65000  DefaultRule_AllowVnetInBound                Allow     VirtualNetwork      0-65535
65001  DefaultRule_AllowAzureLoadBalancerInBound   Allow     AzureLoadBalancer   0-65535
65500  DefaultRule_DenyAllInBound                  Deny      *                   0-65535
```

Notá que la regla con ASG se renderiza como un prefijo resuelto — así confirmás que tu membresía de ASG efectivamente surtió efecto.

### 6.3 Ruteo: encontrar el blackhole

```console
$ az network watcher show-next-hop \
    --resource-group rg-platform-prod --vm vmss-pricing-prod_0 \
    --source-ip 10.10.1.4 --dest-ip 8.8.8.8 -o json
{
  "nextHopIpAddress": "10.0.1.4",
  "nextHopType": "VirtualAppliance",
  "routeTableId": "/subscriptions/.../routeTables/rt-spoke-prod"
}

$ az network nic show-effective-route-table --name vmss-pricing-prod_0-nic \
    -g rg-platform-prod -o table
Source                 State    Address Prefix    Next Hop Type          Next Hop IP
---------------------  -------  ----------------  ---------------------  -------------
Default                Active   10.10.0.0/20      VnetLocal
Default                Active   10.0.0.0/22       VNetPeering
User                   Active   0.0.0.0/0         VirtualAppliance       10.0.1.4
User                   Active   192.168.0.0/16    VirtualAppliance       10.0.1.4
Default                Invalid  0.0.0.0/0         Internet
Default                Active   20.61.144.87/32   NatGateway
```

Leé esto con atención:

- La ruta `User` en `0.0.0.0/0` **sobrescribe** la ruta de sistema hacia Internet, que ahora está `Invalid` — el tunelado forzado está funcionando.
- `nextHopType: None` en cualquier prefijo es un **blackhole**: los paquetes se descartan silenciosamente. Las causas comunes son una UDR que apunta a una NVA que fue borrada, o un peering que se eliminó mientras sus rutas seguían referenciadas.
- Que aparezca `VNetPeering` pero no haya ruta hacia el prefijo del segundo spoke es la prueba visible de que el peering no es transitivo.

### 6.4 Conectividad de punta a punta con atribución por salto

```console
$ az network watcher test-connectivity \
    --resource-group rg-platform-prod --source-resource vmss-pricing-prod_0 \
    --dest-address checkout.internal.example.com --dest-port 443 -o jsonc
{
  "avgLatencyInMs": 3,
  "connectionStatus": "Reachable",
  "hops": [
    {
      "address": "10.10.1.4",
      "nextHopIds": [ "hop-2" ],
      "resourceId": "/subscriptions/.../networkInterfaces/vmss-pricing-prod_0-nic",
      "type": "Source",
      "issues": []
    },
    {
      "address": "10.0.1.4",
      "nextHopIds": [ "hop-3" ],
      "resourceId": "/subscriptions/.../azureFirewalls/afw-hub-prod",
      "type": "VirtualAppliance",
      "issues": []
    },
    {
      "address": "10.10.0.20",
      "nextHopIds": [],
      "resourceId": "/subscriptions/.../applicationGateways/agw-prod",
      "type": "VnetLocal",
      "issues": []
    }
  ],
  "maxLatencyInMs": 9,
  "minLatencyInMs": 2,
  "probesFailed": 0,
  "probesSent": 66
}
```

Cuando falla, el array `issues` nombra el recurso y el tipo culpable (`NetworkSecurityRule`, `UserDefinedRoute`, `DnsResolution`, `Socket`) — atribución, no adivinanza.

### 6.5 El load balancer dice "unhealthy" pero la app está arriba

La falsa alarma de networking más común en Azure. Checklist, en orden:

1. **¿`168.63.129.16` es alcanzable desde el guest?** Los probes se originan ahí, no desde la IP del frontend.
   ```console
   $ ssh azureuser@10.10.1.4 -- curl -s -o /dev/null -w '%{http_code}\n' http://168.63.129.16/
   200
   ```
2. **¿Algún NSG permite el service tag `AzureLoadBalancer` entrante?** La regla por defecto en 65001 lo hace — salvo que hayas agregado un `Deny` con una prioridad más baja. Esa es la trampa: un `Deny-All` bienintencionado en prioridad 4000 mata los probes.
3. **¿La app está escuchando en el puerto del probe sobre `0.0.0.0`, no sobre `127.0.0.1`?**
   ```console
   $ ss -tlnp | grep 8080
   LISTEN 0  4096  0.0.0.0:8080  0.0.0.0:*  users:(("pricing",pid=1412,fd=7))
   ```
   Un `127.0.0.1:8080` acá significa que todos los probes fallan mientras `curl localhost` funciona — el clásico reporte de "funciona cuando entro por SSH".
4. **¿El path del probe devuelve exactamente 200?** Los probes HTTP aceptan **únicamente** `200`. Un redirect `301` hacia HTTPS marca la instancia como caída.
   ```console
   $ curl -s -o /dev/null -w '%{http_code} %{time_total}\n' http://10.10.1.4:8080/healthz
   200 0.004
   ```
5. **¿El firewall del host está bloqueando?** `iptables`/`nftables`/`ufw` dentro del guest es invisible para Network Watcher.
   ```console
   $ sudo nft list ruleset | grep -A3 'chain input'
   chain input {
       type filter hook input priority filter; policy drop;
       iif "lo" accept
       ct state established,related accept
   }
   ```
   Policy `drop` sin una regla para `168.63.129.16` → los probes mueren en silencio.

### 6.6 Salud del backend de Application Gateway

```console
$ az network application-gateway show-backend-health \
    -g rg-platform-prod -n agw-prod \
    --query "backendAddressPools[].backendHttpSettingsCollection[].servers[].{Addr:address, Health:health, Why:healthProbeLog}" -o table
Addr        Health     Why
----------  ---------  ----------------------------------------------------------------
10.10.1.4   Healthy
10.10.1.5   Healthy
10.10.1.6   Unhealthy  Backend server certificate is not whitelisted with Application Gateway.
```

`healthProbeLog` da la causa literal. Las tres recurrentes:

| Fragmento del mensaje | Causa raíz |
|---|---|
| `certificate is not whitelisted` | TLS de punta a punta con un certificado backend autofirmado y sin root de confianza cargada |
| `Backend server timed out` | deny de NSG, puerto equivocado, o una app que tarda más que el `timeout` en responder |
| `The backend health status could not be retrieved` | a la subnet del App Gateway le falta la regla entrante de `GatewayManager` en `65200-65535` |

Ese último es el motivo por el que el Bicep de §4.1 abre `65200-65535` desde `GatewayManager` — omitilo y el gateway entra en un estado permanentemente degradado sin ningún error útil.

### 6.7 Agotamiento de puertos SNAT

La firma: fallas intermitentes de conexión saliente bajo carga, picos de latencia exactamente en el punto donde sube la tasa de conexiones, y logs de aplicación llenos de timeouts de conexión hacia un endpoint que demostrablemente está arriba.

```console
$ az monitor metrics list \
    --resource $(az network nat gateway show -g rg-platform-prod -n natgw-prod --query id -o tsv) \
    --metric SNATConnectionCount TotalConnectionCount \
    --interval PT1M --aggregation Total -o table
Timestamp            Name                        Total
-------------------  --------------------------  -------
2026-09-04 10:12:00  SNAT Connection Count       48213
2026-09-04 10:13:00  SNAT Connection Count       61904
2026-09-04 10:14:00  Total Connection Count      64498
```

Acercarse a 64.512 por IP pública es el techo. Remedios, en orden de preferencia: (1) adjuntar IPs públicas adicionales o un public IP prefix al NAT Gateway, (2) habilitar connection pooling / HTTP keep-alive en la aplicación, (3) reducir `idleTimeoutInMinutes` para que los puertos se reciclen más rápido, (4) reemplazar las llamadas a PaaS por Internet con **Private Endpoints**, que no consumen puertos SNAT en absoluto. La opción 4 es el arreglo arquitectónico; las otras compran tiempo.

### 6.8 Private Endpoint que resuelve a la dirección equivocada

```console
$ nslookup stgpaymentsprod.blob.core.windows.net 168.63.129.16
Server:   168.63.129.16
Address:  168.63.129.16#53

Non-authoritative answer:
stgpaymentsprod.blob.core.windows.net  canonical name = stgpaymentsprod.privatelink.blob.core.windows.net.
Name:    stgpaymentsprod.privatelink.blob.core.windows.net
Address: 10.10.2.7
```

Correcto: el nombre público hace CNAME a `privatelink.*`, que resuelve a una dirección **privada** en `snet-pep`. Si la dirección final es pública (por ejemplo `20.x.x.x`), a la zona DNS privada le falta su **virtual network link** hacia la VNet que consulta — el endpoint existe, pero nadie lo usa. Verificá el link, no solo el endpoint:

```console
$ az network private-dns link vnet list -g rg-platform-prod \
    -z privatelink.blob.core.windows.net -o table
Name                    ResourceGroup     RegistrationEnabled    VirtualNetwork
----------------------  ----------------  ---------------------  --------------------------
link-vnet-app-prod      rg-platform-prod  False                  vnet-app-prod-westeurope
link-vnet-hub-prod      rg-platform-prod  False                  vnet-hub-prod-westeurope
```

### 6.9 Triage del lado del compute

```console
# VM/VMSS: why is the instance not healthy?
$ az vmss get-instance-view -g rg-platform-prod -n vmss-pricing-prod --instance-id 1 \
    --query "{power:statuses[?starts_with(code,'PowerState')].displayStatus | [0], \
              prov:statuses[?starts_with(code,'ProvisioningState')].displayStatus | [0], \
              ext:extensions[].{name:name, status:statuses[0].displayStatus}}" -o jsonc
{
  "ext": [
    { "name": "ApplicationHealthLinux", "status": "Provisioning succeeded" }
  ],
  "power": "VM running",
  "prov": "Provisioning succeeded"
}

# Boot problems: read the console before opening a support case
$ az vm boot-diagnostics get-boot-log --ids $(az vmss list-instances -g rg-platform-prod \
    -n vmss-pricing-prod --query "[1].id" -o tsv) | tail -12
[   14.882431] cloud-init[891]: Cloud-init v. 24.1 finished
[   15.104220] systemd[1]: Reached target Multi-User System.
[  312.771002] pricing[1412]: FATAL: could not bind to 0.0.0.0:8080: Address already in use

# Container Apps: replicas and their container states
$ az containerapp replica list -n ca-checkout-api -g rg-platform-prod \
    --revision ca-checkout-api--v1-14-2 \
    -o table --query "[].{Replica:name, State:properties.runningState, Reason:properties.runningStateDetails}"
Replica                              State     Reason
-----------------------------------  --------  -----------------------------------------
ca-checkout-api--v1-14-2-6c9f-abcde  Running
ca-checkout-api--v1-14-2-6c9f-fghij  Running

$ az containerapp logs show -n ca-checkout-api -g rg-platform-prod --tail 3 --follow false
{"TimeStamp":"2026-09-04T10:21:03","Log":"listening on :8080"}
{"TimeStamp":"2026-09-04T10:21:04","Log":"servicebus: connected via managed identity"}
{"TimeStamp":"2026-09-04T10:21:09","Log":"readiness ok"}

# AKS: zone distribution of the actual pods
$ kubectl get pods -n payments -o custom-columns=\
'NAME:.metadata.name,NODE:.spec.nodeName,ZONE:.metadata.labels.topology\.kubernetes\.io/zone' 2>/dev/null \
  || kubectl get pods -n payments -o wide
NAME                            READY   STATUS    RESTARTS   AGE   IP           NODE
checkout-api-7d4b8c9f6-2xk9p    1/1     Running   0          12m   10.10.8.41   aks-apps-19238471-vmss000000
checkout-api-7d4b8c9f6-5tq4w    1/1     Running   0          12m   10.10.8.88   aks-apps-19238471-vmss000001
checkout-api-7d4b8c9f6-9wm2h    1/1     Running   0          12m   10.10.9.13   aks-apps-19238471-vmss000002

$ kubectl get nodes -L topology.kubernetes.io/zone
NAME                           STATUS   ROLES   AGE   VERSION   ZONE
aks-apps-19238471-vmss000000   Ready    agent   9d    v1.31.3   westeurope-1
aks-apps-19238471-vmss000001   Ready    agent   9d    v1.31.3   westeurope-2
aks-apps-19238471-vmss000002   Ready    agent   9d    v1.31.3   westeurope-3
```

### 6.10 Verificación permanente: NSG flow logs y Connection Monitor

Los comandos puntuales prueban el estado actual; los flow logs prueban qué pasó a las 03:14 del martes pasado.

```console
$ az network watcher flow-log create \
    --resource-group NetworkWatcherRG --name fl-nsg-app-prod \
    --nsg nsg-app-prod --location westeurope \
    --storage-account stgflowlogsprod --enabled true \
    --retention 90 --format JSON --log-version 2 \
    --workspace $(az monitor log-analytics workspace show -g rg-observability \
        -n law-platform-prod --query id -o tsv) \
    --interval 10 --traffic-analytics true -o table
Name             Enabled    Location     ProvisioningState    RetentionDays
---------------  ---------  -----------  -------------------  ---------------
fl-nsg-app-prod  True       West Europe  Succeeded            90
```

Después, la consulta retrospectiva en Log Analytics (KQL):

```kusto
AzureNetworkAnalytics_CL
| where TimeGenerated between (datetime(2026-09-04 03:00) .. datetime(2026-09-04 04:00))
| where FlowStatus_s == "D"                       // denied
| where DestPort_d in (443, 5432, 8080)
| summarize Denied = count() by SrcIP_s, DestIP_s, DestPort_d, NSGRule_s
| top 20 by Denied desc
```

Desplegá **Connection Monitor** para sondeo sintético continuo a lo largo de la topología (VM → PaaS, VM → on-prem, spoke → spoke) para que la degradación del camino se detecte antes de que un usuario la reporte, en vez de reconstruirla después.

---

## 7. Distinciones relevantes para el examen que conviene memorizar

| Si la pregunta dice… | La respuesta es… | Porque |
|---|---|---|
| "proteger contra la falla de un datacenter dentro de una región" | Availability Zones | los availability sets son de un solo datacenter |
| "proteger contra falla de rack y mantenimiento planificado, un datacenter" | Availability Set | distribución en FD + UD |
| "dirigir usuarios a la región más cercana, latencia mínima, a nivel DNS" | Traffic Manager (Performance) | solo responde DNS |
| "punto de entrada HTTP global con WAF y caching" | Azure Front Door | borde, anycast, L7 |
| "ruteo por path de URL y WAF dentro de una región" | Application Gateway | L7 regional |
| "balancear TCP/UDP no HTTP con latencia ultra baja" | Azure Load Balancer | L4 |
| "conectar dos VNets de forma privada, poco overhead" | VNet peering | backbone, no transitivo |
| "conectar on-prem con un circuito privado dedicado" | ExpressRoute | no pasa por Internet |
| "conectar on-prem por Internet, cifrado" | Site-to-Site VPN | IPsec |
| "notebooks individuales que se conectan a una VNet" | Point-to-Site VPN | por cliente |
| "RDP/SSH sin una IP pública en la VM" | Azure Bastion | jump host gestionado |
| "correr un contenedor por 4 minutos, pagar solo eso" | ACI | facturación por segundo |
| "correr contenedores con escalado a cero y HTTPS, sin Kubernetes que administrar" | Container Apps | contenedores serverless |
| "necesito la API de Kubernetes, operators, CRDs" | AKS | K8s gestionado |
| "correr código orientado a eventos, sin administrar servidores" | Azure Functions | FaaS |
| "hospedar una app web, Azure parchea el SO" | App Service | PaaS |
| "escritorios Windows 11 multi-session para personal remoto" | Azure Virtual Desktop | solo Azure ofrece Windows cliente multi-session |
| "reducir el licenciamiento de software por core pero conservar la RAM" | SKU de VM con cores restringidos | vCPUs enmascaradas, memoria retenida |
| "una IP privada en mi subnet para un servicio PaaS" | Private Endpoint | NIC de Private Link |
| "restringir una storage account a una subnet sin cambiar el DNS" | Service Endpoint | identidad de subnet en el firewall del PaaS |

---

## 8. Referencias

Documentación oficial de Microsoft, vigente al momento de escribir esto. Verificá las cifras de SLA y las fechas de retiro contra las páginas en vivo — son contractuales y cambian.

**Examen y guía de estudio**
- AZ-900 study guide — https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900
- Azure Fundamentals certification — https://learn.microsoft.com/en-us/credentials/certifications/azure-fundamentals/

**Compute**
- Azure Virtual Machines documentation — https://learn.microsoft.com/en-us/azure/virtual-machines/
- Sizes for virtual machines in Azure — https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/overview
- Constrained vCPU capable VM sizes — https://learn.microsoft.com/en-us/azure/virtual-machines/constrained-vcpu
- Availability options for Azure VMs — https://learn.microsoft.com/en-us/azure/virtual-machines/availability
- Availability sets overview — https://learn.microsoft.com/en-us/azure/virtual-machines/availability-set-overview
- What are Azure availability zones? — https://learn.microsoft.com/en-us/azure/reliability/availability-zones-overview
- Virtual Machine Scale Sets overview — https://learn.microsoft.com/en-us/azure/virtual-machine-scale-sets/overview
- Orchestration modes for scale sets — https://learn.microsoft.com/en-us/azure/virtual-machine-scale-sets/virtual-machine-scale-sets-orchestration-modes
- Azure managed disk types — https://learn.microsoft.com/en-us/azure/virtual-machines/disks-types
- Azure Kubernetes Service documentation — https://learn.microsoft.com/en-us/azure/aks/
- AKS pricing tiers and SLA — https://learn.microsoft.com/en-us/azure/aks/free-standard-pricing-tiers
- Azure Container Apps overview — https://learn.microsoft.com/en-us/azure/container-apps/overview
- Container Apps YAML/ARM specification — https://learn.microsoft.com/en-us/azure/container-apps/azure-resource-manager-api-spec
- Container Apps scale rules — https://learn.microsoft.com/en-us/azure/container-apps/scale-app
- Azure Container Instances overview — https://learn.microsoft.com/en-us/azure/container-instances/container-instances-overview
- Container groups in ACI — https://learn.microsoft.com/en-us/azure/container-instances/container-instances-container-groups
- Azure App Service overview — https://learn.microsoft.com/en-us/azure/app-service/overview
- App Service plan overview — https://learn.microsoft.com/en-us/azure/app-service/overview-hosting-plans
- Deployment slots — https://learn.microsoft.com/en-us/azure/app-service/deploy-staging-slots
- Azure Functions overview — https://learn.microsoft.com/en-us/azure/azure-functions/functions-overview
- Azure Functions hosting options — https://learn.microsoft.com/en-us/azure/azure-functions/functions-scale
- Azure Virtual Desktop overview — https://learn.microsoft.com/en-us/azure/virtual-desktop/overview

**Networking**
- Azure Virtual Network overview — https://learn.microsoft.com/en-us/azure/virtual-network/virtual-networks-overview
- Plan virtual networks — https://learn.microsoft.com/en-us/azure/virtual-network/virtual-network-vnet-plan-design-arm
- Network security groups — https://learn.microsoft.com/en-us/azure/virtual-network/network-security-groups-overview
- Application security groups — https://learn.microsoft.com/en-us/azure/virtual-network/application-security-groups
- Virtual network service tags — https://learn.microsoft.com/en-us/azure/virtual-network/service-tags-overview
- What is IP address 168.63.129.16? — https://learn.microsoft.com/en-us/azure/virtual-network/what-is-ip-address-168-63-129-16
- Virtual network traffic routing (UDR) — https://learn.microsoft.com/en-us/azure/virtual-network/virtual-networks-udr-overview
- Virtual network peering — https://learn.microsoft.com/en-us/azure/virtual-network/virtual-network-peering-overview
- Azure VPN Gateway — https://learn.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-about-vpngateways
- VPN Gateway SKUs — https://learn.microsoft.com/en-us/azure/vpn-gateway/about-gateway-skus
- Azure ExpressRoute overview — https://learn.microsoft.com/en-us/azure/expressroute/expressroute-introduction
- ExpressRoute circuits and peering — https://learn.microsoft.com/en-us/azure/expressroute/expressroute-circuit-peerings
- Azure Virtual WAN overview — https://learn.microsoft.com/en-us/azure/virtual-wan/virtual-wan-about
- Azure Load Balancer overview — https://learn.microsoft.com/en-us/azure/load-balancer/load-balancer-overview
- Load Balancer health probes — https://learn.microsoft.com/en-us/azure/load-balancer/load-balancer-custom-probe-overview
- Load Balancer SKU comparison — https://learn.microsoft.com/en-us/azure/load-balancer/skus
- Basic Load Balancer retirement — https://learn.microsoft.com/en-us/azure/load-balancer/load-balancer-basic-upgrade-guidance
- Default outbound access retirement — https://learn.microsoft.com/en-us/azure/virtual-network/ip-services/default-outbound-access
- Azure NAT Gateway overview — https://learn.microsoft.com/en-us/azure/nat-gateway/nat-overview
- SNAT with NAT Gateway — https://learn.microsoft.com/en-us/azure/nat-gateway/nat-gateway-resource
- Application Gateway overview — https://learn.microsoft.com/en-us/azure/application-gateway/overview
- Application Gateway infrastructure configuration — https://learn.microsoft.com/en-us/azure/application-gateway/configuration-infrastructure
- Application Gateway backend health troubleshooting — https://learn.microsoft.com/en-us/azure/application-gateway/application-gateway-backend-health-troubleshooting
- Azure Front Door overview — https://learn.microsoft.com/en-us/azure/frontdoor/front-door-overview
- Azure Traffic Manager routing methods — https://learn.microsoft.com/en-us/azure/traffic-manager/traffic-manager-routing-methods
- Load-balancing options decision guide — https://learn.microsoft.com/en-us/azure/architecture/guide/technology-choices/load-balancing-overview
- Azure DNS overview — https://learn.microsoft.com/en-us/azure/dns/dns-overview
- Azure Private DNS zones — https://learn.microsoft.com/en-us/azure/dns/private-dns-overview
- Azure Private Link / Private Endpoint — https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-overview
- Private Endpoint DNS configuration — https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-dns
- Virtual network service endpoints — https://learn.microsoft.com/en-us/azure/virtual-network/virtual-network-service-endpoints-overview
- Azure Bastion overview — https://learn.microsoft.com/en-us/azure/bastion/bastion-overview
- Azure Firewall overview — https://learn.microsoft.com/en-us/azure/firewall/overview

**Diagnóstico y confiabilidad**
- Azure Network Watcher overview — https://learn.microsoft.com/en-us/azure/network-watcher/network-watcher-overview
- IP flow verify — https://learn.microsoft.com/en-us/azure/network-watcher/ip-flow-verify-overview
- Next hop — https://learn.microsoft.com/en-us/azure/network-watcher/next-hop-overview
- Connection troubleshoot — https://learn.microsoft.com/en-us/azure/network-watcher/connection-troubleshoot-overview
- NSG flow logs — https://learn.microsoft.com/en-us/azure/network-watcher/nsg-flow-logs-overview
- Connection Monitor — https://learn.microsoft.com/en-us/azure/network-watcher/connection-monitor-overview
- Azure Load Balancer metrics and diagnostics — https://learn.microsoft.com/en-us/azure/load-balancer/load-balancer-standard-diagnostics
- Boot diagnostics — https://learn.microsoft.com/en-us/azure/virtual-machines/boot-diagnostics
- Azure reliability documentation — https://learn.microsoft.com/en-us/azure/reliability/
- Service Level Agreements for Microsoft Online Services — https://www.microsoft.com/licensing/docs/view/Service-Level-Agreements-SLA-for-Online-Services

**Referencias de herramientas**
- Azure CLI `az network` reference — https://learn.microsoft.com/en-us/cli/azure/network
- Azure CLI `az vmss` reference — https://learn.microsoft.com/en-us/cli/azure/vmss
- Azure CLI `az containerapp` reference — https://learn.microsoft.com/en-us/cli/azure/containerapp
- Bicep documentation — https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/
- Azure Resource Manager template reference (`Microsoft.Network`) — https://learn.microsoft.com/en-us/azure/templates/microsoft.network/allversions