# AWS Certified Cloud Practitioner (CLF-C02)
## Domain 3, Task Statement 3.5 — Identify AWS network services
**Peso en el examen: 4.25 · Perfil de profundidad: SRE / Platform Architect · Idioma: Español**

---

## 1. The production problem this task statement actually encodes

La guía del examen enuncia 3.5 como "identify AWS network services". Ese verbo — *identify* — está haciendo mucho trabajo en silencio. El modo de fallo contra el que protege no es la ignorancia de qué es una VPC. Es el modo de fallo mucho más caro de **elegir la primitiva de red equivocada en tiempo de diseño y descubrirlo a escala**, cuando el costo del cambio es una migración y no una edición.

Concretamente, acá hay cuatro incidentes que se remontan todos a una decisión de nivel 3.5:

**Incidente A — el /24 que se comió el roadmap.** Un equipo lanza su primera VPC de producción con `10.0.0.0/24` porque "solo necesitamos unas pocas instancias". Dos años después necesitan EKS con el VPC CNI, donde **cada pod consume una dirección IP de la VPC desde la subnet**. Un `t3.large` soporta 35 pods; 12 nodos agotan el espacio de direcciones. No podés reducir el CIDR de una VPC ni renumerar una subnet — solo podés *agregar* bloques CIDR secundarios, y únicamente si no colisionan con el espacio peered/on-prem que ya anunciaste. El plan de asignación RFC1918 es la decisión más irreversible de todo este task statement.

**Incidente B — la factura de NAT de $9.400.** Una flota de analítica en subnets privadas baja 60 TB/mes desde Amazon S3. El tráfico sale por un NAT gateway hacia el endpoint público de S3. A aproximadamente $0,045/GB de procesamiento de datos en NAT eso son unos **$2.700/mes solo en cargos de NAT**, más el cargo por hora, por tráfico que nunca necesitó salir de la red de AWS. Un **gateway VPC endpoint para S3 cuesta $0,00** y elimina el cargo por completo. La brecha de conocimiento es una fila en una route table.

**Incidente C — el security group que no era el problema.** Un servicio no puede alcanzar su base de datos. Tres ingenieros pasan dos horas ensanchando security groups. La causa real es una **network ACL** en la subnet de datos que permite el ingreso por `5432` pero no tiene regla de salida para el **rango de puertos efímeros**, porque las NACL son stateless y los security groups no. Este es el diagnóstico erróneo de conectividad de VPC más común en producción, y es consecuencia directa de una distinción stateful/stateless que 3.5 espera que tengas presente.

**Incidente D — CloudFront donde correspondía Global Accelerator.** Un equipo pone CloudFront delante de un servidor de juego UDP en tiempo real, descubre que CloudFront es una caché HTTP/HTTPS, y reconstruye sobre **AWS Global Accelerator** — IPs estáticas anycast sobre el backbone de AWS, agnóstico al protocolo. Ambos son "edge networking". Resuelven problemas distintos.

El contenido de ingeniería de 3.5 es, por lo tanto, una **tabla de decisión**, no un glosario. Todo lo que sigue está organizado de modo que cada servicio se presente con la pregunta que responde, las alternativas con las que compite, y la señal observable que te dice que la elección fue equivocada.

---

## 2. The mental model: five nested scopes

Cada servicio de red de AWS vive en exactamente uno de cinco ámbitos. Ubicar un servicio correctamente en esta escalera responde la mayoría de las preguntas de examen y la mayoría de las preguntas de diseño.

```
┌──────────────────────────────────────────────────────────────────────┐
│ GLOBAL / EDGE   Route 53 · CloudFront · Global Accelerator · Shield  │
│                 WAF (on CF/ALB/API GW) · 600+ PoPs, anycast          │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │ REGION       Direct Connect location · Transit Gateway ·       │  │
│  │              Site-to-Site VPN · Cloud WAN · PrivateLink svc    │  │
│  │  ┌──────────────────────────────────────────────────────────┐  │  │
│  │  │ VPC       CIDR blocks · IGW · Egress-only IGW · DHCP opts │  │  │
│  │  │           Route 53 Resolver (.2) · Peering · Flow Logs    │  │  │
│  │  │  ┌────────────────────────────────────────────────────┐  │  │  │
│  │  │  │ SUBNET (= one AZ)  Route table · NACL · NAT GW ·   │  │  │  │
│  │  │  │                    gateway endpoint association     │  │  │  │
│  │  │  │  ┌──────────────────────────────────────────────┐  │  │  │  │
│  │  │  │  │ ENI  Security group(s) · private IP(s) ·     │  │  │  │  │
│  │  │  │  │      EIP · source/dest check · interface EP  │  │  │  │  │
│  │  │  │  └──────────────────────────────────────────────┘  │  │  │  │
│  │  │  └────────────────────────────────────────────────────┘  │  │  │
│  │  └──────────────────────────────────────────────────────────┘  │  │
│  └────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
```

Dos consecuencias que vale la pena internalizar:

- **Una subnet nunca abarca más de una Availability Zone.** Por lo tanto, cualquier construcción asociada a una subnet (NAT gateway, ENI de interface endpoint, nodo de NLB) es un dominio de fallo por AZ, y la redundancia por AZ es algo que *vos* comprás, no algo que te viene dado.
- **Un security group se asocia a una ENI, no a una subnet.** Dos instancias en la misma subnet con security groups distintos tienen alcanzabilidad completamente diferente. Por eso "está en la misma subnet, así que tiene que funcionar" es una afirmación falsa.

---

## 3. Amazon VPC: the addressing and routing substrate

### 3.1 CIDR mechanics you are expected to know exactly

| Propiedad | Regla | Consecuencia práctica |
|---|---|---|
| Tamaño del CIDR IPv4 de la VPC | `/16` … `/28` | `/16` = 65.536 direcciones es el valor por defecto sensato para una VPC de producción |
| CIDR secundarios | Hasta 5 en total (ajustable a pedido) | El único remedio para una subasignación; no pueden solaparse con rutas existentes |
| CIDR primario | **Inmutable** | No se puede cambiar ni achicar después de la creación |
| IPs reservadas por subnet | **5** | `.0` red, `.1` router de la VPC, `.2` Route 53 Resolver, `.3` reservada, última = broadcast |
| Subnet ↔ AZ | 1 : 1 | La redundancia de AZ requiere ≥ 2 subnets por capa |
| IPv6 | `/56` por VPC (provisto por AWS o BYOIP), `/64` por subnet | IPv6 siempre es públicamente ruteable; la privacidad viene del egress-only IGW |

Ejemplo resuelto sobre la plantilla de más abajo, `10.42.0.0/16` dividido en `/20`:

```
10.42.0.0/20   → 4096 total − 5 reserved = 4091 usable
                 10.42.0.0   network
                 10.42.0.1   VPC router (default gateway)
                 10.42.0.2   Route 53 Resolver (VPC base + 2)
                 10.42.0.3   reserved for future AWS use
                 10.42.15.255 broadcast (reserved; VPC has no broadcast)
```

La dirección `.2` del resolver importa operativamente: es el *único* servidor DNS alcanzable por defecto desde una subnet privada, está limitado a **1024 paquetes por segundo por ENI**, y ese límite es un techo real de producción para cargas de service-discovery habladoras. No hay métrica de CloudWatch para eso — el síntoma son `SERVFAIL`/timeouts intermitentes bajo carga, y la solución es un resolver cacheador local o Route 53 Resolver endpoints.

### 3.2 Gateways and their exact semantics

| Componente | Dirección | Familia IP | Cobrado | Propósito |
|---|---|---|---|---|
| **Internet gateway (IGW)** | Bidireccional | IPv4 + IPv6 | Gratis (aplica transferencia de datos) | Escalado horizontal, redundante, sin restricción de ancho de banda; hace NAT 1:1 para direcciones públicas IPv4 |
| **NAT gateway** | **Solo egreso** | Solo IPv4 | ~$0,045/hr + ~$0,045/GB | Gestionado, ráfagas de 45 Gbps, alcance de AZ, necesita una EIP y una subnet pública |
| **Egress-only IGW (EIGW)** | **Solo egreso** | **Solo IPv6** | **Gratis** | Egreso IPv6 stateful; el análogo IPv6 de un NAT gateway, a costo cero |
| **Virtual private gateway (VGW)** | Bidireccional | IPv4 + IPv6 | Gratis (aplican cargos de VPN/DX) | Terminador del lado VPC para Site-to-Site VPN / private VIF |
| **Transit gateway (TGW)** | Bidireccional | IPv4 + IPv6 | ~$0,05/attachment-hr + ~$0,02/GB | Router regional; reemplazo hub-and-spoke del peering en malla |

> **Definición de "subnet pública":** una subnet cuya route table asociada contiene una ruta hacia un internet gateway. Nada más. Ni un tag, ni un nombre, ni la presencia de una IP pública.

### 3.3 NAT gateway vs. NAT instance vs. no NAT at all

| Dimensión | NAT gateway | NAT instance (EC2 autogestionada) | VPC endpoints (sin NAT) |
|---|---|---|---|
| Disponibilidad | Gestionado, redundante *dentro de una AZ* | La construís vos (ASG + failover de rutas) | Gestionado, multi-AZ si desplegás por AZ |
| Ancho de banda | 5 Gbps → 45 Gbps automático | Limitado por el tipo de instancia | Gateway: sin límite. Interface: 10 Gbps/ENI, ráfagas a 40 |
| Costo @ 60 TB/mes | ~$2.700 de datos + ~$33 por hora | Instancia + EBS + transferencia de datos saliente | **$0** (gateway de S3/DynamoDB) |
| Security groups | **No se puede** asociar uno | Sí | Sí (interface endpoints) |
| Port forwarding / bastión | No | Sí | No |
| IPv6 | No soportado (usar EIGW) | Posible manualmente | Soportado en muchos endpoints |
| Carga operativa | Cero | Parcheo, monitoreo, scripts de failover | Cero |

**Regla del arquitecto:** los NAT gateways son para el tráfico que genuinamente debe llegar a la internet pública (mirrors de paquetes del SO, APIs SaaS de terceros). Cada byte de tráfico hacia servicios de AWS debería estar sobre un endpoint antes de que dimensiones el NAT. Desplegá **un NAT gateway por AZ** y ruteá la subnet privada de cada AZ a su NAT local — un único NAT compartido es a la vez un cargo de transferencia de datos cross-AZ y un radio de explosión ante la falla de una AZ.

### 3.4 Security groups vs. network ACLs — the stateful/stateless split

Esta es la comparación de mayor rendimiento de todo el task statement.

| | **Security group** | **Network ACL** |
|---|---|---|
| Se asocia a | **ENI** (instancia, endpoint, nodo de ALB, RDS) | **Subnet** |
| Estado | **Stateful** — el tráfico de retorno se permite automáticamente | **Stateless** — el tráfico de retorno necesita su propia regla |
| Tipos de regla | **Solo allow** | **Allow y deny** |
| Evaluación | Se evalúan todas las reglas; unión de los allow | **Número de regla más bajo primero**, gana la primera coincidencia, se detiene |
| Por defecto (creado a medida) | **Deny all inbound**, allow all outbound | **Deny all** de entrada y de salida |
| Por defecto (recurso default de la VPC) | Allow desde el mismo SG, allow all outbound | **Allow all** de entrada y de salida |
| Puede referenciar | Otro SG ID, una prefix list, un CIDR | Solo CIDR |
| Cuota (por defecto) | 5 SG/ENI, 60 reglas in + 60 out | 20 reglas por dirección (40 máx.) |
| Puertos efímeros | Nunca hacen falta | **Siempre hacen falta** para el tráfico de retorno |
| Uso típico | Control primario; identidad por workload | **Deny** grueso a nivel de subnet (blocklists, aislamiento de capas) |

**Rangos de puertos efímeros que importan al escribir NACLs:**

| Cliente | Rango |
|---|---|
| Kernel Linux (`net.ipv4.ip_local_port_range`) | 32768–60999 |
| Windows Server 2008+ | 49152–65535 |
| NAT gateway | **1024–65535** |
| AWS Lambda / nodos de ELB | 1024–65535 |

Como un NAT gateway origina desde 1024–65535, cualquier NACL que proteja una subnet que recibe tráfico de retorno traducido por NAT debe permitir **1024–65535 de entrada**. Estrecharlo a 32768–60999 "porque los clientes son Linux" se rompe en el momento en que el tráfico transita por NAT. Esta es una caída real y repetible.

**La referencia entre security groups es la funcionalidad que realmente hay que usar.** En vez de `10.42.4.0/22`, escribí "allow TCP 8080 from `sg-app`". La regla entonces sigue a la identidad del workload en lugar del espacio de direcciones, sobrevive a un re-subneteo, y no puede ser satisfecha por una instancia no relacionada que casualmente caiga en el CIDR correcto.

### 3.5 VPC endpoints — gateway vs. interface (PrivateLink)

| | **Gateway endpoint** | **Interface endpoint (PrivateLink)** |
|---|---|---|
| Implementación | **Entrada en la route table** hacia una prefix list gestionada | **ENI con una IP privada** en tu subnet |
| Servicios | **Solo Amazon S3 y DynamoDB** | Más de 100 servicios de AWS, Marketplace, tus propios servicios |
| Costo | **Gratis** | ~$0,01/hr por AZ por endpoint + ~$0,01/GB |
| Security group | No aplica | **Sí** — el control primario |
| Política | Endpoint policy | Endpoint policy |
| DNS | Usa el nombre DNS público del servicio, la ruta desvía | **Private DNS** sobrescribe el nombre público dentro de la VPC |
| Cross-Region | No | No (usar endpoints locales a la Región) |
| Alcanzable desde on-prem vía DX/VPN | **No** | **Sí** |
| Alcanzable a través de peering | **No** | **Sí** |

La fila "alcanzable desde on-prem" es la razón por la que muchas organizaciones corren *ambos*: un gateway endpoint de S3 gratuito (para tráfico dentro de la VPC) y un interface endpoint de S3 pago (para tráfico por Direct Connect). Coexisten; el private DNS del interface endpoint decide cuál gana para los clientes dentro de la VPC, así que si querés que gane el camino gratuito, dejá el private DNS **deshabilitado** en el interface endpoint de S3 y usá desde on-prem su nombre DNS regional específico del endpoint.

**PrivateLink para tu propio servicio** es el patrón para exponer un servicio a otra VPC u otra cuenta de AWS sin peering, sin problemas de CIDR solapados, y con un modelo de confianza unidireccional: ponés un NLB (o GWLB) delante de tu servicio, lo publicás como *VPC endpoint service*, y los consumidores crean interface endpoints. El consumidor puede alcanzarte a vos; vos no podés alcanzar al consumidor. Los CIDR pueden solaparse libremente, porque no se rutea nada — el tráfico se NATea en el endpoint.

### 3.6 Connecting VPCs and networks

| Opción | Topología | ¿Transitiva? | ¿CIDR solapados OK? | Ancho de banda | Driver de costo típico |
|---|---|---|---|---|---|
| **VPC peering** | Malla 1:1 | **No** | **No** | Sin límite impuesto por AWS | Transferencia de datos cross-AZ (intra-AZ es gratis) |
| **Transit gateway** | Hub-and-spoke | **Sí** (controlado por route table) | No | Ráfagas de 50 Gbps por VPC attachment | Attachment-hours + por GB |
| **PrivateLink** | Servicio-a-consumidor | N/A | **Sí** | Según límites de NLB/ENI | Endpoint-hours + por GB |
| **Site-to-Site VPN** | On-prem ↔ AWS por internet | Vía VGW o TGW | No | **~1,25 Gbps por túnel** | Por hora de conexión VPN + datos salientes |
| **Direct Connect** | On-prem ↔ AWS, fibra dedicada | Vía VGW/DX GW/TGW | No | 1 / 10 / 100 Gbps dedicados; 50 Mbps–25 Gbps hosted | Port-hours + tarifa DTO reducida |
| **AWS Cloud WAN** | Backbone global gestionado | Sí, dirigida por políticas | No | Depende del segmento | Core network edge-hours + por GB |

Tres puntos que se toman en el examen y que hacen fallar diseños:

1. **El peering es no transitivo por diseño.** Si A↔B y B↔C están peered, A no puede alcanzar a C. Una malla completa de *n* VPCs necesita *n(n−1)/2* conexiones y *n−1* rutas por route table. Esto se vuelve inmanejable en algún punto alrededor de 6–8 VPCs; ese es el punto de inflexión del Transit Gateway.
2. **Una conexión Site-to-Site VPN siempre son dos túneles**, terminando en dos endpoints de AWS distintos en AZ diferentes, para redundancia del lado de AWS. Un solo túnel no es un diseño HA, y el techo de ~1,25 Gbps es **por túnel** — agregar más allá de eso requiere múltiples conexiones VPN con ECMP sobre un Transit Gateway.
3. **Direct Connect no está cifrado por defecto.** Un private VIF sobre DX transporta texto plano. Si tu postura de cumplimiento exige cifrado en tránsito sobre la WAN, corrés **IPsec VPN sobre Direct Connect** (public VIF o endpoint público de DX), o **MACsec** en conexiones dedicadas soportadas. Además: una *única* conexión DX no es resiliente — los patrones resilientes estándar son dos conexiones en dos ubicaciones DX, y la rampa de entrada estándar es DX + VPN de respaldo.

---

## 4. Load balancing: the Elastic Load Balancing family

| | **ALB** | **NLB** | **GWLB** | **CLB** (legacy) |
|---|---|---|---|---|
| Capa OSI | 7 | 4 | 3 (+GENEVE) | 4 / 7 |
| Protocolos | HTTP, HTTPS, gRPC, WebSockets | TCP, UDP, TLS, TCP_UDP | IP (GENEVE **UDP 6081**) | TCP, SSL, HTTP, HTTPS |
| Rutea por | Host, path, header, método, query, IP de origen | Hash de flujo (5-tuple, o 3-tuple para UDP) | Stickiness de flujo por 5-tuple | Solo puerto |
| IP estática | No (usar nombre DNS) | **Sí — una EIP por AZ** | No (vía endpoint) | No |
| Preserva la IP del cliente | Vía header `X-Forwarded-For` | **Sí, nativamente** (targets instance/ip) | Sí (encapsulada) | `X-Forwarded-For` en HTTP |
| Tipos de target | instance, **ip**, **Lambda** | instance, ip, **ALB** | instance, ip (appliances) | instance |
| Terminación TLS | Sí (+ SNI, múltiples certificados) | Sí (listener TLS) | No (transparente) | Sí |
| Integración con WAF | **Sí** | No | No | No |
| Latencia agregada | ~ms | **~100 µs** | Depende del appliance | ~ms |
| Escala | Muy alta | **Millones de rps**, sin pre-warm | Depende del appliance | Necesita pre-warming |
| Security groups | Sí | **Sí** (desde agosto de 2023) | Sí | Sí |
| Front-end de servicio PrivateLink | No | **Sí** | Sí | No |
| Unidad de precio | LCU-hours | NLCU-hours | GLCU-hours | Por hora + GB |

**Reglas de decisión:**
- Necesitás ruteo por path/host, autenticación OIDC, targets Lambda o WAF → **ALB**.
- Necesitás una IP estática, un protocolo no HTTP, throughput extremo, IP de origen real sin headers, o una puerta de entrada PrivateLink → **NLB**.
- Necesitás insertar un firewall/IDS de terceros de forma transparente en el camino de los paquetes → **GWLB**.
- Necesitás funcionalidades L7 *y* una IP estática → **NLB con un ALB como target**, o **Global Accelerator delante de un ALB**.
- **CLB** aparece únicamente en escenarios de migración. No diseñes sistemas nuevos sobre él.

---

## 5. DNS: Amazon Route 53

Route 53 es un servicio **global** que cumple tres funciones distintas: registro de dominios, hosting DNS autoritativo y health checking. Su SLA de ~100% de disponibilidad es único en el portafolio de AWS.

### 5.1 Routing policies

| Política | Base de selección | Requiere health check | Uso canónico |
|---|---|---|---|
| **Simple** | Un solo registro; múltiples valores devueltos en orden aleatorio | No | Mapeo estático |
| **Weighted** | Proporción de pesos enteros | Opcional | Canary / blue-green / split A-B |
| **Latency-based** | Menor latencia de red medida hacia la Región | Opcional | Caminos de lectura multi-Región |
| **Failover** | Primario hasta que no esté sano, luego secundario | **Sí** | DR activo-pasivo |
| **Geolocation** | País/continente/estado del resolver | Opcional | Residencia de datos, localización, licenciamiento |
| **Geoproximity** | Distancia geográfica ± un valor de **bias** | Opcional | Traslado gradual de tráfico entre Regiones |
| **Multivalue answer** | Hasta 8 registros sanos, aleatorizados | **Sí** | Reparto de carga barato del lado del cliente (no es un load balancer) |
| **IP-based** | Bloques CIDR del resolver | Opcional | Direccionamiento por ISP / carrier |

**Latency-based no es geolocation.** El ruteo por latencia responde "qué Región es la más rápida desde este resolver"; geolocation responde "dónde está este resolver". Divergen constantemente — un usuario en Canadá puede tener menor latencia hacia `us-east-1` que hacia `ca-central-1`. Elegir geolocation para un objetivo de rendimiento es un error de diseño; elegir ruteo por latencia para un objetivo de cumplimiento es una violación de cumplimiento.

### 5.2 Alias vs. CNAME

| | **Alias (extensión de Route 53)** | **CNAME (DNS estándar)** |
|---|---|---|
| Ápice de zona (`example.com`) | **Sí** | **No** — prohibido por el RFC 1034 |
| Costo por consulta | **Gratis** hacia targets de AWS | Cobrado |
| Target | ELB, CloudFront, sitio web de S3, API GW, Global Accelerator, VPC endpoint, otro registro en la misma zona | Cualquier nombre DNS |
| Salud | Puede evaluar la salud del target de forma nativa | No |
| TTL | Heredado del target | Lo definís vos |

### 5.3 Hosted zones and hybrid resolution

- **Public hosted zone** — autoritativa en internet.
- **Private hosted zone** — resoluble solo desde las VPC asociadas; requiere `enableDnsSupport` **y** `enableDnsHostnames` en la VPC.
- **Route 53 Resolver endpoints** — el puente de DNS híbrido:
  - **Inbound endpoint** → los resolvers on-premises consultan zonas alojadas en AWS.
  - **Outbound endpoint + forwarding rules** → los workloads de la VPC consultan zonas on-premises.

---

## 6. Edge and content delivery

### 6.1 Amazon CloudFront

Una CDN distribuida globalmente con más de 600 puntos de presencia y regional edge caches. Más allá del caching provee terminación TLS en el edge, origin shielding, **Origin Access Control (OAC)** para orígenes S3 privados (OAC reemplaza al antiguo OAI, y es obligatorio para orígenes con SSE-KMS), signed URLs y signed cookies, cifrado a nivel de campo, e integración nativa con AWS Shield Standard + AWS WAF.

| | **CloudFront Functions** | **Lambda@Edge** |
|---|---|---|
| Se ejecuta en | Más de 600 edge locations | Regional edge caches |
| Runtime | JavaScript (estilo ECMAScript 5.1) | Node.js, Python |
| Duración máxima | **< 1 ms** | 5 s (viewer), 30 s (origin) |
| Memoria | 2 MB | 128 MB–10 GB |
| Triggers | solo viewer request/response | los cuatro (viewer + origin, req/resp) |
| Acceso a red | **No** | Sí |
| Acceso al body | No | Sí |
| Costo | ~1/6 de Lambda@Edge | Mayor |
| Usar para | Manipulación de headers, reescritura de URL, cookie A/B, chequeo de token | Autenticación contra una API, transformación de imágenes, inspección del body |

### 6.2 CloudFront vs. Global Accelerator

| | **CloudFront** | **Global Accelerator** |
|---|---|---|
| Protocolos | HTTP/HTTPS (+WebSockets) | **TCP y UDP**, cualquier puerto |
| Caching | **Sí** — el valor central | **No** — proxy/ruteo puro |
| Entrada del cliente | Edge PoP por DNS | **2 IPs anycast estáticas** por BGP |
| Velocidad de failover | Failover de DNS/origen, segundos–minutos | **Menos de 30 segundos**, basado en salud, sin dependencia de DNS |
| Preservación de la IP del cliente | `X-Forwarded-For` | Sí, hacia endpoints ALB/EC2 |
| Endpoints | S3, ALB, EC2, cualquier origen HTTP | ALB, NLB, EC2, Elastic IP |
| Ideal para | Contenido web estático + dinámico, media | Gaming, VoIP, IoT/MQTT, APIs no HTTP, allowlisting por IP |
| Por qué importan las IPs estáticas | — | Los firewalls empresariales/de partners hacen allowlist de IPs, no de nombres DNS |

Ambos viajan por el backbone global de AWS desde el edge hasta el origen, así que ambos mejoran el tráfico dinámico (no cacheable). También son componibles: Global Accelerator puede estar delante de un ALB que a su vez sirve como origen de CloudFront.

### 6.3 Protection services attached to the network path

| Servicio | Capa | Alcance | Modelo de costo |
|---|---|---|---|
| **AWS Shield Standard** | DDoS L3/L4 | Automático, todos los clientes | **Gratis** |
| **AWS Shield Advanced** | DDoS L3/L4/L7 | Opt-in por recurso | Suscripción mensual + protección de costos por DDoS + acceso al SRT |
| **AWS WAF** | L7 | CloudFront, ALB, API Gateway, AppSync, Cognito, App Runner, Verified Access | Por web ACL, por regla, por millón de requests |
| **AWS Network Firewall** | L3–L7, stateful | A nivel de VPC, reglas compatibles con Suricata | Endpoint-hours + por GB |
| **AWS Firewall Manager** | Política | Políticas de WAF/Shield/SG/Network Firewall a nivel de organización | Por política |

Notá la asimetría que el examen sondea: **WAF no puede asociarse a un NLB ni directamente a una instancia EC2.** Si un escenario requiere filtrado L7 delante de un servicio TCP, la respuesta es poner primero un ALB (o CloudFront) en el camino.

---

## 7. Complete infrastructure — a production three-tier VPC

Esta plantilla de CloudFormation está completa y es desplegable tal como está escrita. Construye una VPC dual-stack de tres capas a través de dos AZ con NAT por AZ, un egress-only IGW para IPv6, un gateway endpoint de S3 gratuito, los interface endpoints necesarios para acceso vía SSM sin ningún SSH entrante, una NACL stateless protegiendo la capa de datos, VPC Flow Logs con el conjunto extendido de campos, y un ALB de cara a internet con redirección HTTP→HTTPS.

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >
  Production three-tier dual-stack VPC (2 AZ): public / app / data subnets,
  per-AZ NAT gateway, egress-only IGW for IPv6, S3 gateway endpoint,
  SSM+ECR+Logs interface endpoints, data-tier NACL, extended flow logs, ALB.

Parameters:
  EnvName:
    Type: String
    Default: prod
    AllowedPattern: '^[a-z0-9-]{2,16}$'
    Description: Environment name used as a tag and resource-name prefix.

  VpcCidr:
    Type: String
    Default: 10.42.0.0/16
    AllowedPattern: '^(\d{1,3}\.){3}\d{1,3}/(1[6-9]|2[0-8])$'
    Description: Primary IPv4 CIDR. Must not overlap on-prem or peered space.

  CertificateArn:
    Type: String
    Description: ACM certificate ARN in this Region for the HTTPS listener.

  AllowedIngressCidr:
    Type: String
    Default: 0.0.0.0/0
    Description: Client CIDR permitted to reach the ALB on 80/443.

  FlowLogRetentionDays:
    Type: Number
    Default: 30
    AllowedValues: [1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365]

Resources:

  # ------------------------------------------------------------------ VPC ---
  Vpc:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: !Ref VpcCidr
      EnableDnsSupport: true        # required for the .2 resolver
      EnableDnsHostnames: true      # required for private hosted zones + PrivateLink private DNS
      InstanceTenancy: default
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-vpc'

  Ipv6Cidr:
    Type: AWS::EC2::VPCCidrBlock
    Properties:
      VpcId: !Ref Vpc
      AmazonProvidedIpv6CidrBlock: true   # allocates a /56

  # -------------------------------------------------------------- Gateways ---
  InternetGateway:
    Type: AWS::EC2::InternetGateway
    Properties:
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-igw'

  IgwAttachment:
    Type: AWS::EC2::VPCGatewayAttachment
    Properties:
      VpcId: !Ref Vpc
      InternetGatewayId: !Ref InternetGateway

  EgressOnlyIgw:
    Type: AWS::EC2::EgressOnlyInternetGateway
    Properties:
      VpcId: !Ref Vpc

  # --------------------------------------------------------------- Subnets ---
  # IPv4: !Cidr [VpcCidr, 16, 12] carves the /16 into sixteen /20 blocks.
  # IPv6: !Cidr [<vpc /56>, 6, 64] carves six /64 blocks (64 is mandatory for IPv6).

  PublicSubnetA:
    Type: AWS::EC2::Subnet
    DependsOn: Ipv6Cidr
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Select [0, !GetAZs '']
      CidrBlock: !Select [0, !Cidr [!Ref VpcCidr, 16, 12]]
      Ipv6CidrBlock: !Select [0, !Cidr [!Select [0, !GetAtt Vpc.Ipv6CidrBlocks], 6, 64]]
      MapPublicIpOnLaunch: true
      AssignIpv6AddressOnCreation: true
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-public-a'
        - Key: kubernetes.io/role/elb
          Value: '1'

  PublicSubnetB:
    Type: AWS::EC2::Subnet
    DependsOn: Ipv6Cidr
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Select [1, !GetAZs '']
      CidrBlock: !Select [1, !Cidr [!Ref VpcCidr, 16, 12]]
      Ipv6CidrBlock: !Select [1, !Cidr [!Select [0, !GetAtt Vpc.Ipv6CidrBlocks], 6, 64]]
      MapPublicIpOnLaunch: true
      AssignIpv6AddressOnCreation: true
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-public-b'
        - Key: kubernetes.io/role/elb
          Value: '1'

  AppSubnetA:
    Type: AWS::EC2::Subnet
    DependsOn: Ipv6Cidr
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Select [0, !GetAZs '']
      CidrBlock: !Select [4, !Cidr [!Ref VpcCidr, 16, 12]]
      Ipv6CidrBlock: !Select [2, !Cidr [!Select [0, !GetAtt Vpc.Ipv6CidrBlocks], 6, 64]]
      MapPublicIpOnLaunch: false
      AssignIpv6AddressOnCreation: true
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-app-a'
        - Key: kubernetes.io/role/internal-elb
          Value: '1'

  AppSubnetB:
    Type: AWS::EC2::Subnet
    DependsOn: Ipv6Cidr
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Select [1, !GetAZs '']
      CidrBlock: !Select [5, !Cidr [!Ref VpcCidr, 16, 12]]
      Ipv6CidrBlock: !Select [3, !Cidr [!Select [0, !GetAtt Vpc.Ipv6CidrBlocks], 6, 64]]
      MapPublicIpOnLaunch: false
      AssignIpv6AddressOnCreation: true
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-app-b'
        - Key: kubernetes.io/role/internal-elb
          Value: '1'

  DataSubnetA:
    Type: AWS::EC2::Subnet
    DependsOn: Ipv6Cidr
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Select [0, !GetAZs '']
      CidrBlock: !Select [8, !Cidr [!Ref VpcCidr, 16, 12]]
      Ipv6CidrBlock: !Select [4, !Cidr [!Select [0, !GetAtt Vpc.Ipv6CidrBlocks], 6, 64]]
      MapPublicIpOnLaunch: false
      AssignIpv6AddressOnCreation: false
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-data-a'

  DataSubnetB:
    Type: AWS::EC2::Subnet
    DependsOn: Ipv6Cidr
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Select [1, !GetAZs '']
      CidrBlock: !Select [9, !Cidr [!Ref VpcCidr, 16, 12]]
      Ipv6CidrBlock: !Select [5, !Cidr [!Select [0, !GetAtt Vpc.Ipv6CidrBlocks], 6, 64]]
      MapPublicIpOnLaunch: false
      AssignIpv6AddressOnCreation: false
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-data-b'

  # ------------------------------------------------------------ NAT (per AZ) ---
  NatEipA:
    Type: AWS::EC2::EIP
    DependsOn: IgwAttachment
    Properties:
      Domain: vpc
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-nat-eip-a'

  NatEipB:
    Type: AWS::EC2::EIP
    DependsOn: IgwAttachment
    Properties:
      Domain: vpc
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-nat-eip-b'

  NatGatewayA:
    Type: AWS::EC2::NatGateway
    Properties:
      AllocationId: !GetAtt NatEipA.AllocationId
      SubnetId: !Ref PublicSubnetA        # MUST live in a public subnet
      ConnectivityType: public
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-nat-a'

  NatGatewayB:
    Type: AWS::EC2::NatGateway
    Properties:
      AllocationId: !GetAtt NatEipB.AllocationId
      SubnetId: !Ref PublicSubnetB
      ConnectivityType: public
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-nat-b'

  # ---------------------------------------------------------- Route tables ---
  PublicRouteTable:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-rt-public'

  PublicDefaultRouteV4:
    Type: AWS::EC2::Route
    DependsOn: IgwAttachment
    Properties:
      RouteTableId: !Ref PublicRouteTable
      DestinationCidrBlock: 0.0.0.0/0
      GatewayId: !Ref InternetGateway

  PublicDefaultRouteV6:
    Type: AWS::EC2::Route
    DependsOn: IgwAttachment
    Properties:
      RouteTableId: !Ref PublicRouteTable
      DestinationIpv6CidrBlock: ::/0
      GatewayId: !Ref InternetGateway

  PublicRtAssocA:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PublicSubnetA
      RouteTableId: !Ref PublicRouteTable

  PublicRtAssocB:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PublicSubnetB
      RouteTableId: !Ref PublicRouteTable

  AppRouteTableA:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-rt-app-a'

  AppDefaultRouteV4A:
    Type: AWS::EC2::Route
    Properties:
      RouteTableId: !Ref AppRouteTableA
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId: !Ref NatGatewayA     # AZ-local NAT: no cross-AZ transfer, no shared blast radius

  AppDefaultRouteV6A:
    Type: AWS::EC2::Route
    Properties:
      RouteTableId: !Ref AppRouteTableA
      DestinationIpv6CidrBlock: ::/0
      EgressOnlyInternetGatewayId: !Ref EgressOnlyIgw

  AppRtAssocA:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref AppSubnetA
      RouteTableId: !Ref AppRouteTableA

  AppRouteTableB:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-rt-app-b'

  AppDefaultRouteV4B:
    Type: AWS::EC2::Route
    Properties:
      RouteTableId: !Ref AppRouteTableB
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId: !Ref NatGatewayB

  AppDefaultRouteV6B:
    Type: AWS::EC2::Route
    Properties:
      RouteTableId: !Ref AppRouteTableB
      DestinationIpv6CidrBlock: ::/0
      EgressOnlyInternetGatewayId: !Ref EgressOnlyIgw

  AppRtAssocB:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref AppSubnetB
      RouteTableId: !Ref AppRouteTableB

  # Data tier: NO default route at all. Egress happens only via VPC endpoints.
  DataRouteTable:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-rt-data'

  DataRtAssocA:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref DataSubnetA
      RouteTableId: !Ref DataRouteTable

  DataRtAssocB:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref DataSubnetB
      RouteTableId: !Ref DataRouteTable

  # ------------------------------------------------------- VPC endpoints ---
  S3GatewayEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref Vpc
      ServiceName: !Sub 'com.amazonaws.${AWS::Region}.s3'
      VpcEndpointType: Gateway
      RouteTableIds:
        - !Ref AppRouteTableA
        - !Ref AppRouteTableB
        - !Ref DataRouteTable
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: AllowAllWithinAccount
            Effect: Allow
            Principal: '*'
            Action: 's3:*'
            Resource: '*'
            Condition:
              StringEquals:
                'aws:PrincipalAccount': !Ref 'AWS::AccountId'

  DynamoDbGatewayEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref Vpc
      ServiceName: !Sub 'com.amazonaws.${AWS::Region}.dynamodb'
      VpcEndpointType: Gateway
      RouteTableIds:
        - !Ref AppRouteTableA
        - !Ref AppRouteTableB
        - !Ref DataRouteTable

  EndpointSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Interface VPC endpoint ENIs - HTTPS from inside the VPC only
      VpcId: !Ref Vpc
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 443
          ToPort: 443
          CidrIp: !Ref VpcCidr
          Description: HTTPS from any workload in this VPC
      SecurityGroupEgress:
        - IpProtocol: '-1'
          CidrIp: 127.0.0.1/32
          Description: Endpoint ENIs never initiate outbound traffic
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-sg-vpce'

  SsmEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref Vpc
      ServiceName: !Sub 'com.amazonaws.${AWS::Region}.ssm'
      VpcEndpointType: Interface
      PrivateDnsEnabled: true
      SubnetIds: [!Ref AppSubnetA, !Ref AppSubnetB]
      SecurityGroupIds: [!Ref EndpointSecurityGroup]

  SsmMessagesEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref Vpc
      ServiceName: !Sub 'com.amazonaws.${AWS::Region}.ssmmessages'
      VpcEndpointType: Interface
      PrivateDnsEnabled: true
      SubnetIds: [!Ref AppSubnetA, !Ref AppSubnetB]
      SecurityGroupIds: [!Ref EndpointSecurityGroup]

  Ec2MessagesEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref Vpc
      ServiceName: !Sub 'com.amazonaws.${AWS::Region}.ec2messages'
      VpcEndpointType: Interface
      PrivateDnsEnabled: true
      SubnetIds: [!Ref AppSubnetA, !Ref AppSubnetB]
      SecurityGroupIds: [!Ref EndpointSecurityGroup]

  EcrApiEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref Vpc
      ServiceName: !Sub 'com.amazonaws.${AWS::Region}.ecr.api'
      VpcEndpointType: Interface
      PrivateDnsEnabled: true
      SubnetIds: [!Ref AppSubnetA, !Ref AppSubnetB]
      SecurityGroupIds: [!Ref EndpointSecurityGroup]

  EcrDkrEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref Vpc
      ServiceName: !Sub 'com.amazonaws.${AWS::Region}.ecr.dkr'
      VpcEndpointType: Interface
      PrivateDnsEnabled: true
      SubnetIds: [!Ref AppSubnetA, !Ref AppSubnetB]
      SecurityGroupIds: [!Ref EndpointSecurityGroup]

  LogsEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref Vpc
      ServiceName: !Sub 'com.amazonaws.${AWS::Region}.logs'
      VpcEndpointType: Interface
      PrivateDnsEnabled: true
      SubnetIds: [!Ref AppSubnetA, !Ref AppSubnetB]
      SecurityGroupIds: [!Ref EndpointSecurityGroup]

  # --------------------------------------------------- Security groups ---
  AlbSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Internet-facing ALB
      VpcId: !Ref Vpc
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 80
          ToPort: 80
          CidrIp: !Ref AllowedIngressCidr
          Description: HTTP (redirected to HTTPS at the listener)
        - IpProtocol: tcp
          FromPort: 443
          ToPort: 443
          CidrIp: !Ref AllowedIngressCidr
          Description: HTTPS
      SecurityGroupEgress:
        - IpProtocol: tcp
          FromPort: 8080
          ToPort: 8080
          CidrIp: !Ref VpcCidr
          Description: To application targets only
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-sg-alb'

  AppSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Application tier
      VpcId: !Ref Vpc
      SecurityGroupEgress:
        - IpProtocol: tcp
          FromPort: 443
          ToPort: 443
          CidrIp: 0.0.0.0/0
          Description: HTTPS to AWS endpoints and external APIs
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-sg-app'

  # Declared separately to allow SG-to-SG references without a circular dependency.
  AppIngressFromAlb:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !Ref AppSecurityGroup
      IpProtocol: tcp
      FromPort: 8080
      ToPort: 8080
      SourceSecurityGroupId: !Ref AlbSecurityGroup
      Description: Only the ALB may reach the app port

  AppEgressToData:
    Type: AWS::EC2::SecurityGroupEgress
    Properties:
      GroupId: !Ref AppSecurityGroup
      IpProtocol: tcp
      FromPort: 5432
      ToPort: 5432
      DestinationSecurityGroupId: !Ref DataSecurityGroup
      Description: PostgreSQL to the data tier

  DataSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Data tier - PostgreSQL from the app tier only
      VpcId: !Ref Vpc
      SecurityGroupEgress:
        - IpProtocol: tcp
          FromPort: 443
          ToPort: 443
          CidrIp: !Ref VpcCidr
          Description: HTTPS to VPC endpoints (backups to S3, logs)
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-sg-data'

  DataIngressFromApp:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !Ref DataSecurityGroup
      IpProtocol: tcp
      FromPort: 5432
      ToPort: 5432
      SourceSecurityGroupId: !Ref AppSecurityGroup
      Description: PostgreSQL from the application tier

  # ------------------------------------- Data-tier NACL (stateless!) ---
  DataNacl:
    Type: AWS::EC2::NetworkAcl
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-nacl-data'

  DataNaclInAppA:
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref DataNacl
      RuleNumber: 100
      Protocol: 6
      RuleAction: allow
      Egress: false
      CidrBlock: !Select [4, !Cidr [!Ref VpcCidr, 16, 12]]
      PortRange: {From: 5432, To: 5432}

  DataNaclInAppB:
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref DataNacl
      RuleNumber: 110
      Protocol: 6
      RuleAction: allow
      Egress: false
      CidrBlock: !Select [5, !Cidr [!Ref VpcCidr, 16, 12]]
      PortRange: {From: 5432, To: 5432}

  # Return traffic from the S3 gateway endpoint and interface endpoints arrives
  # on an ephemeral port. Omitting this rule is THE classic NACL outage.
  DataNaclInEphemeral:
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref DataNacl
      RuleNumber: 200
      Protocol: 6
      RuleAction: allow
      Egress: false
      CidrBlock: 0.0.0.0/0
      PortRange: {From: 1024, To: 65535}

  DataNaclOutAppA:
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref DataNacl
      RuleNumber: 100
      Protocol: 6
      RuleAction: allow
      Egress: true
      CidrBlock: !Select [4, !Cidr [!Ref VpcCidr, 16, 12]]
      PortRange: {From: 1024, To: 65535}

  DataNaclOutAppB:
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref DataNacl
      RuleNumber: 110
      Protocol: 6
      RuleAction: allow
      Egress: true
      CidrBlock: !Select [5, !Cidr [!Ref VpcCidr, 16, 12]]
      PortRange: {From: 1024, To: 65535}

  DataNaclOutHttps:
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref DataNacl
      RuleNumber: 200
      Protocol: 6
      RuleAction: allow
      Egress: true
      CidrBlock: 0.0.0.0/0
      PortRange: {From: 443, To: 443}

  DataNaclAssocA:
    Type: AWS::EC2::SubnetNetworkAclAssociation
    Properties:
      SubnetId: !Ref DataSubnetA
      NetworkAclId: !Ref DataNacl

  DataNaclAssocB:
    Type: AWS::EC2::SubnetNetworkAclAssociation
    Properties:
      SubnetId: !Ref DataSubnetB
      NetworkAclId: !Ref DataNacl

  # ------------------------------------------------------- Flow logs ---
  FlowLogGroup:
    Type: AWS::Logs::LogGroup
    Properties:
      LogGroupName: !Sub '/aws/vpc/flowlogs/${EnvName}'
      RetentionInDays: !Ref FlowLogRetentionDays

  FlowLogRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: vpc-flow-logs.amazonaws.com
            Action: sts:AssumeRole
            Condition:
              StringEquals:
                'aws:SourceAccount': !Ref 'AWS::AccountId'
      Policies:
        - PolicyName: publish-flow-logs
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - logs:CreateLogStream
                  - logs:PutLogEvents
                  - logs:DescribeLogStreams
                Resource: !GetAtt FlowLogGroup.Arn

  VpcFlowLog:
    Type: AWS::EC2::FlowLog
    Properties:
      ResourceId: !Ref Vpc
      ResourceType: VPC
      TrafficType: ALL
      MaxAggregationInterval: 60
      LogDestinationType: cloud-watch-logs
      LogGroupName: !Ref FlowLogGroup
      DeliverLogsPermissionArn: !GetAtt FlowLogRole.Arn
      # pkt-srcaddr / pkt-dstaddr expose the real endpoints behind NAT and load
      # balancers; flow-direction and traffic-path make egress paths auditable.
      LogFormat: >-
        ${version} ${account-id} ${interface-id} ${srcaddr} ${dstaddr}
        ${srcport} ${dstport} ${protocol} ${packets} ${bytes} ${start} ${end}
        ${action} ${log-status} ${vpc-id} ${subnet-id} ${instance-id}
        ${tcp-flags} ${type} ${pkt-srcaddr} ${pkt-dstaddr}
        ${pkt-src-aws-service} ${pkt-dst-aws-service}
        ${flow-direction} ${traffic-path}

  # ------------------------------------------------------------- ALB ---
  Alb:
    Type: AWS::ElasticLoadBalancingV2::LoadBalancer
    Properties:
      Name: !Sub '${EnvName}-alb'
      Type: application
      Scheme: internet-facing
      IpAddressType: dualstack
      Subnets: [!Ref PublicSubnetA, !Ref PublicSubnetB]
      SecurityGroups: [!Ref AlbSecurityGroup]
      LoadBalancerAttributes:
        - Key: routing.http.drop_invalid_header_fields.enabled
          Value: 'true'
        - Key: routing.http2.enabled
          Value: 'true'
        - Key: idle_timeout.timeout_seconds
          Value: '60'
        - Key: deletion_protection.enabled
          Value: 'true'

  AppTargetGroup:
    Type: AWS::ElasticLoadBalancingV2::TargetGroup
    Properties:
      Name: !Sub '${EnvName}-tg-app'
      VpcId: !Ref Vpc
      TargetType: ip
      Protocol: HTTP
      Port: 8080
      HealthCheckProtocol: HTTP
      HealthCheckPath: /healthz
      HealthCheckIntervalSeconds: 10
      HealthCheckTimeoutSeconds: 5
      HealthyThresholdCount: 2
      UnhealthyThresholdCount: 3
      Matcher:
        HttpCode: '200'
      TargetGroupAttributes:
        - Key: deregistration_delay.timeout_seconds
          Value: '30'
        - Key: stickiness.enabled
          Value: 'false'

  HttpsListener:
    Type: AWS::ElasticLoadBalancingV2::Listener
    Properties:
      LoadBalancerArn: !Ref Alb
      Protocol: HTTPS
      Port: 443
      SslPolicy: ELBSecurityPolicy-TLS13-1-2-2021-06
      Certificates:
        - CertificateArn: !Ref CertificateArn
      DefaultActions:
        - Type: forward
          TargetGroupArn: !Ref AppTargetGroup

  HttpRedirectListener:
    Type: AWS::ElasticLoadBalancingV2::Listener
    Properties:
      LoadBalancerArn: !Ref Alb
      Protocol: HTTP
      Port: 80
      DefaultActions:
        - Type: redirect
          RedirectConfig:
            Protocol: HTTPS
            Port: '443'
            StatusCode: HTTP_301

Outputs:
  VpcId:
    Value: !Ref Vpc
    Export:
      Name: !Sub '${EnvName}-vpc-id'
  VpcIpv6Cidr:
    Value: !Select [0, !GetAtt Vpc.Ipv6CidrBlocks]
  AppSubnetIds:
    Value: !Join [',', [!Ref AppSubnetA, !Ref AppSubnetB]]
    Export:
      Name: !Sub '${EnvName}-app-subnets'
  DataSubnetIds:
    Value: !Join [',', [!Ref DataSubnetA, !Ref DataSubnetB]]
  AlbDnsName:
    Value: !GetAtt Alb.DNSName
  AlbHostedZoneId:
    Description: Use with a Route 53 alias record at the zone apex
    Value: !GetAtt Alb.CanonicalHostedZoneID
  NatPublicIps:
    Description: Egress IPs to give partners for allowlisting
    Value: !Join [',', [!Ref NatEipA, !Ref NatEipB]]
```

> **Nota sobre escalado:** los seis interface endpoints están escritos explícitamente por claridad. En un entorno real, agregá `Transform: 'AWS::LanguageExtensions'` y generalos con `Fn::ForEach` sobre una lista de nombres de servicio para evitar la deriva por copiar y pegar que termina dejando un endpoint en una sola AZ.

### 7.1 Route 53 records for this stack

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: Public DNS for the ALB, with a latency-based multi-Region shape.

Parameters:
  HostedZoneId:
    Type: AWS::Route53::HostedZone::Id
  DomainName:
    Type: String
    Default: app.example.com
  AlbDnsName:
    Type: String
  AlbHostedZoneId:
    Type: String

Resources:
  # Alias at the zone apex - a CNAME is illegal here, and alias queries are free.
  ApexAlias:
    Type: AWS::Route53::RecordSet
    Properties:
      HostedZoneId: !Ref HostedZoneId
      Name: !Ref DomainName
      Type: A
      AliasTarget:
        DNSName: !Ref AlbDnsName
        HostedZoneId: !Ref AlbHostedZoneId
        EvaluateTargetHealth: true

  ApexAliasV6:
    Type: AWS::Route53::RecordSet
    Properties:
      HostedZoneId: !Ref HostedZoneId
      Name: !Ref DomainName
      Type: AAAA
      AliasTarget:
        DNSName: !Ref AlbDnsName
        HostedZoneId: !Ref AlbHostedZoneId
        EvaluateTargetHealth: true

  # Latency policy: one record per Region, same name, distinct SetIdentifier.
  LatencyPrimaryRegion:
    Type: AWS::Route53::RecordSet
    Properties:
      HostedZoneId: !Ref HostedZoneId
      Name: !Sub 'api.${DomainName}'
      Type: A
      SetIdentifier: !Sub 'latency-${AWS::Region}'
      Region: !Ref 'AWS::Region'
      AliasTarget:
        DNSName: !Ref AlbDnsName
        HostedZoneId: !Ref AlbHostedZoneId
        EvaluateTargetHealth: true

  # Weighted canary: 5% of traffic to the new stack, 95% to the current one.
  CanaryHealthCheck:
    Type: AWS::Route53::HealthCheck
    Properties:
      HealthCheckConfig:
        Type: HTTPS
        FullyQualifiedDomainName: !Ref AlbDnsName
        ResourcePath: /healthz
        Port: 443
        RequestInterval: 10
        FailureThreshold: 2
        MeasureLatency: true
      HealthCheckTags:
        - Key: Name
          Value: canary-healthcheck
```

---

## 8. Command line: real invocations and expected output

### 8.1 Inventory the topology

```
$ aws ec2 describe-vpcs --filters Name=tag:Name,Values=prod-vpc \
    --query 'Vpcs[].{Id:VpcId,Cidr:CidrBlock,V6:Ipv6CidrBlockAssociationSet[0].Ipv6CidrBlock,Default:IsDefault}' \
    --output table
------------------------------------------------------------------------------
|                                DescribeVpcs                                |
+---------+----------------+-----------------------+-------------------------+
| Default |     Cidr       |          Id           |           V6            |
+---------+----------------+-----------------------+-------------------------+
|  False  |  10.42.0.0/16  |  vpc-0a3f9c2e7b1d4508a|  2600:1f18:2c4a:e600::/56|
+---------+----------------+-----------------------+-------------------------+
```

```
$ aws ec2 describe-subnets --filters Name=vpc-id,Values=vpc-0a3f9c2e7b1d4508a \
    --query 'sort_by(Subnets,&CidrBlock)[].{Name:Tags[?Key==`Name`]|[0].Value,Id:SubnetId,AZ:AvailabilityZone,Cidr:CidrBlock,Free:AvailableIpAddressCount,PubIP:MapPublicIpOnLaunch}' \
    --output table
---------------------------------------------------------------------------------------------
|                                      DescribeSubnets                                      |
+--------------+--------+----------------+-------+----------------+---------------+---------+
|      AZ      |  Cidr  |      Free      | Name  |      Id        |     PubIP     |         |
+--------------+--------+----------------+-------+----------------+---------------+---------+
|  us-east-1a  | 10.42.0.0/20  | 4088  | prod-public-a | subnet-01c8...  | True  |
|  us-east-1b  | 10.42.16.0/20 | 4090  | prod-public-b | subnet-0f22...  | True  |
|  us-east-1a  | 10.42.64.0/20 | 3612  | prod-app-a    | subnet-09ab...  | False |
|  us-east-1b  | 10.42.80.0/20 | 3644  | prod-app-b    | subnet-0d71...  | False |
|  us-east-1a  | 10.42.128.0/20| 4089  | prod-data-a   | subnet-0e40...  | False |
|  us-east-1b  | 10.42.144.0/20| 4089  | prod-data-b   | subnet-0b93...  | False |
+--------------+--------+----------------+-------+----------------+---------------+---------+
```

`AvailableIpAddressCount` es la métrica sobre la que hay que alarmar para cualquier cluster de EKS: `4096 − 5 reservadas − asignadas`. Una subnet que tiende a cero produce `InsufficientFreeAddressesInSubnet` y pods trabados en `ContainerCreating`, sin ningún mensaje en ninguna parte que mencione el agotamiento de IPs de manera directa.

### 8.2 Prove which subnets are public

```
$ aws ec2 describe-route-tables --filters Name=vpc-id,Values=vpc-0a3f9c2e7b1d4508a \
    --query 'RouteTables[].{RT:RouteTableId,Name:Tags[?Key==`Name`]|[0].Value,Routes:Routes[].[DestinationCidrBlock||DestinationIpv6CidrBlock||DestinationPrefixListId,GatewayId||NatGatewayId||EgressOnlyInternetGatewayId]}' \
    --output json
[
  {
    "RT": "rtb-05e1a7c9d3b6f2401",
    "Name": "prod-rt-public",
    "Routes": [
      ["10.42.0.0/16", "local"],
      ["2600:1f18:2c4a:e600::/56", "local"],
      ["0.0.0.0/0", "igw-0c94b1f7e2a83d5b6"],
      ["::/0", "igw-0c94b1f7e2a83d5b6"]
    ]
  },
  {
    "RT": "rtb-0b74f3d18ea9c25de",
    "Name": "prod-rt-app-a",
    "Routes": [
      ["10.42.0.0/16", "local"],
      ["0.0.0.0/0", "nat-0918c4e7b2f3d6a51"],
      ["::/0", "eigw-0aa41c9d7e5b83f20"],
      ["pl-63a5400a", null]
    ]
  },
  {
    "RT": "rtb-0f2c9e84a1b7d3506",
    "Name": "prod-rt-data",
    "Routes": [
      ["10.42.0.0/16", "local"],
      ["pl-63a5400a", null],
      ["pl-02cd2c6b", null]
    ]
  }
]
```

Leé esto con atención — es toda la arquitectura en una sola salida:
- `prod-rt-public` tiene `0.0.0.0/0 → igw-…`. **Eso, y solamente eso, hace que una subnet sea pública.**
- `prod-rt-app-a` egresa IPv4 por NAT e IPv6 por el egress-only IGW a costo cero.
- `prod-rt-data` **no tiene ninguna ruta por defecto**. `pl-63a5400a` (S3) y `pl-02cd2c6b` (DynamoDB) son las prefix lists de los gateway endpoints. La capa de datos puede alcanzar S3 y DynamoDB y *nada más* — un control en la capa de ruteo que ningún security group mal configurado puede deshacer.
- La ruta `local` es implícita, no puede borrarse, y siempre gana porque el ruteo de la VPC es longest-prefix-match con `local` tratada como la más específica.

### 8.3 NAT gateway state and cost signal

```
$ aws ec2 describe-nat-gateways --filter Name=vpc-id,Values=vpc-0a3f9c2e7b1d4508a \
    --query 'NatGateways[].{Id:NatGatewayId,AZ:SubnetId,State:State,Public:NatGatewayAddresses[0].PublicIp,Private:NatGatewayAddresses[0].PrivateIp}' \
    --output table
-------------------------------------------------------------------------------------
|                              DescribeNatGateways                                  |
+---------------------+---------------------------+-----------+---------------------+
|         AZ          |            Id             |  Private  |       Public        |
+---------------------+---------------------------+-----------+---------------------+
|  subnet-01c8...     |  nat-0918c4e7b2f3d6a51    | 10.42.3.71| 54.221.18.203       |
|  subnet-0f22...     |  nat-0a52d7f1c8b394e07    | 10.42.19.8| 3.219.44.87         |
+---------------------+---------------------------+-----------+---------------------+
```

```
$ aws cloudwatch get-metric-statistics \
    --namespace AWS/NATGateway --metric-name BytesOutToDestination \
    --dimensions Name=NatGatewayId,Value=nat-0918c4e7b2f3d6a51 \
    --start-time 2026-09-01T00:00:00Z --end-time 2026-09-04T00:00:00Z \
    --period 86400 --statistics Sum --output table
------------------------------------------------
|            GetMetricStatistics               |
+---------------------+------------------+-----+
|      Timestamp      |       Sum        |Unit |
+---------------------+------------------+-----+
| 2026-09-01T00:00:00Z|  482913774592.0  |Bytes|
| 2026-09-02T00:00:00Z|  511208441856.0  |Bytes|
| 2026-09-03T00:00:00Z|  497660219392.0  |Bytes|
+---------------------+------------------+-----+
```

Unos 483 GB/día saliendo de un solo NAT gateway. A ~$0,045/GB procesado eso es aproximadamente **$22/día por gateway** solo en cargos de NAT, antes de la transferencia de datos saliente a internet. La pregunta siguiente es siempre: *¿cuánto de eso es tráfico hacia servicios de AWS que debería estar en un endpoint?* Respondela con `pkt-dst-aws-service` en los flow logs (§8.6).

### 8.4 Verify security groups actually reference each other

```
$ aws ec2 describe-security-groups --group-ids sg-0d41e9c72b8a35f60 \
    --query 'SecurityGroups[0].IpPermissions[].{Proto:IpProtocol,From:FromPort,To:ToPort,Cidrs:IpRanges[].CidrIp,SGs:UserIdGroupPairs[].GroupId}' \
    --output json
[
  {
    "Proto": "tcp",
    "From": 5432,
    "To": 5432,
    "Cidrs": [],
    "SGs": ["sg-07b2f9d4e1c86a305"]
  }
]
```

`Cidrs` vacío y `SGs` poblado es la forma que querés ver en una auditoría: alcanzabilidad atada a la identidad del workload, no al espacio de direcciones.

### 8.5 Interface endpoints and DNS override

```
$ aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=vpc-0a3f9c2e7b1d4508a \
    --query 'VpcEndpoints[].{Service:ServiceName,Type:VpcEndpointType,State:State,PrivDNS:PrivateDnsEnabled,AZs:length(SubnetIds)}' \
    --output table
-----------------------------------------------------------------------------------
|                             DescribeVpcEndpoints                                |
+-----+---------+-----------------------------------------+-----------+-----------+
| AZs | PrivDNS |                 Service                 |   State   |   Type    |
+-----+---------+-----------------------------------------+-----------+-----------+
|  0  |  None   |  com.amazonaws.us-east-1.s3             | available |  Gateway  |
|  0  |  None   |  com.amazonaws.us-east-1.dynamodb       | available |  Gateway  |
|  2  |  True   |  com.amazonaws.us-east-1.ssm            | available | Interface |
|  2  |  True   |  com.amazonaws.us-east-1.ssmmessages    | available | Interface |
|  2  |  True   |  com.amazonaws.us-east-1.ec2messages    | available | Interface |
|  2  |  True   |  com.amazonaws.us-east-1.ecr.api        | available | Interface |
|  2  |  True   |  com.amazonaws.us-east-1.ecr.dkr        | available | Interface |
|  2  |  True   |  com.amazonaws.us-east-1.logs           | available | Interface |
+-----+---------+-----------------------------------------+-----------+-----------+
```

Desde una instancia dentro de la VPC, el private DNS es lo que hace transparente al endpoint:

```
$ dig +short ssm.us-east-1.amazonaws.com
10.42.68.204
10.42.85.117
```

Respuestas RFC1918 para el nombre de un endpoint público de AWS prueban que el private DNS está funcionando y que el SDK va a pegarle a la ENI. Si en cambio ves una dirección pública:

```
$ dig +short ssm.us-east-1.amazonaws.com
52.46.132.19
```

entonces o bien `enableDnsHostnames` está apagado en la VPC, o `PrivateDnsEnabled` es false en el endpoint, o la instancia está usando un servidor DNS distinto del resolver `.2`. Las tres son configuraciones erróneas silenciosas que "funcionan" a través del NAT mientras cuestan plata calladamente y dejan el camino privado sin verificar.

Los gateway endpoints se comportan distinto — el DNS sigue devolviendo una dirección pública de S3, y es la *route table* la que desvía el paquete:

```
$ dig +short s3.us-east-1.amazonaws.com
52.216.221.8

$ curl -s -o /dev/null -w '%{http_code} %{remote_ip} %{time_total}s\n' \
    https://prod-artifacts.s3.us-east-1.amazonaws.com/healthcheck.txt
200 52.216.221.8 0.031s
```

La IP pública es esperada y correcta. Confirmá el camino con flow logs (`traffic-path` / `pkt-dst-aws-service`), no con `dig`.

### 8.6 Flow logs: find the traffic that should not be on NAT

```
$ aws logs start-query \
    --log-group-name /aws/vpc/flowlogs/prod \
    --start-time $(date -d '24 hours ago' +%s) --end-time $(date +%s) \
    --query-string 'fields @timestamp, srcaddr, pkt_dst_aws_service, bytes
      | filter traffic_path = 4 and pkt_dst_aws_service != "-"
      | stats sum(bytes)/1024/1024/1024 as gb by pkt_dst_aws_service
      | sort gb desc | limit 10'
{
    "queryId": "9f4c1a2e-70bd-4a55-b2f1-6d83e0c47915"
}

$ aws logs get-query-results --query-id 9f4c1a2e-70bd-4a55-b2f1-6d83e0c47915 \
    --query 'results[].[field,value]' --output text
pkt_dst_aws_service     S3
gb                      1183.44
pkt_dst_aws_service     DYNAMODB
gb                      212.07
pkt_dst_aws_service     ECR
gb                      88.61
pkt_dst_aws_service     CLOUDWATCH
gb                      19.30
```

`traffic_path = 4` significa "a través de un NAT gateway". 1.183 GB/día de tráfico a S3 por ese camino son aproximadamente **$53/día** de desperdicio puro que un gateway endpoint gratuito elimina. Los volúmenes de ECR y CloudWatch justifican sus interface endpoints solo por costo ($0,01/GB le gana a $0,045/GB, más el DTO a internet que dejás de pagar).

Valores de `traffic-path` que vale la pena memorizar: `1` dentro de la VPC, `2` internet gateway o gateway VPC endpoint, `3` virtual private gateway, `4` **NAT gateway**, `5` VPC peering, `6` transit gateway, `7` Local Gateway, `8` gateway de Local Zone, `9` peering inter-Región.

Tráfico rechazado, la primera consulta en cualquier incidente de conectividad:

```
$ aws logs start-query --log-group-name /aws/vpc/flowlogs/prod \
    --start-time $(date -d '30 minutes ago' +%s) --end-time $(date +%s) \
    --query-string 'fields @timestamp, srcaddr, dstaddr, dstport, protocol, action
      | filter action = "REJECT" and dstport = 5432
      | sort @timestamp desc | limit 20'
```

```
@timestamp                srcaddr      dstaddr       dstport  protocol  action
2026-09-04 14:02:11.000   10.42.68.31  10.42.131.14  5432     6         REJECT
2026-09-04 14:02:10.000   10.42.68.31  10.42.131.14  5432     6         REJECT
```

`REJECT` en la dirección **inbound** en la ENI de destino significa que un security group o una NACL lo descartó. **La ausencia de cualquier registro para el flujo de retorno** — ves el `ACCEPT` entrante pero nunca la respuesta — apunta en cambio a una regla de egreso faltante en la NACL, porque el SG habría permitido el retorno de forma stateful.

### 8.7 Load balancer target health

```
$ aws elbv2 describe-target-health --target-group-arn \
    arn:aws:elasticloadbalancing:us-east-1:111122223333:targetgroup/prod-tg-app/6d21a4f0b8c93e57 \
    --query 'TargetHealthDescriptions[].{Target:Target.Id,Port:Target.Port,AZ:Target.AvailabilityZone,State:TargetHealth.State,Reason:TargetHealth.Reason,Desc:TargetHealth.Description}' \
    --output table
-----------------------------------------------------------------------------------------------------------
|                                        DescribeTargetHealth                                             |
+------------+---------------------------+------+----------------------------------------+----------------+
|     AZ     |          Reason           | Port |                 Desc                   |     State      |
+------------+---------------------------+------+----------------------------------------+----------------+
| us-east-1a |  None                     | 8080 |  None                                  |  healthy       |
| us-east-1a |  None                     | 8080 |  None                                  |  healthy       |
| us-east-1b |  Target.Timeout           | 8080 |  Request timed out                     |  unhealthy     |
| us-east-1b |  Target.FailedHealthChecks|  8080|  Health checks failed with these codes:| unhealthy      |
|            |                           |      |  [404]                                 |                |
+------------+---------------------------+------+----------------------------------------+----------------+
```

Las dos razones significan cosas opuestas y se confunden constantemente:

| Razón | Significado | Dónde está la falla |
|---|---|---|
| `Target.Timeout` | El paquete nunca volvió | **Red**: el SG del target no permite al SG del ALB en el puerto del health check, o una NACL lo bloquea |
| `Target.FailedHealthChecks` + código HTTP | El target respondió | **Aplicación**: path equivocado, matcher equivocado, la app devuelve 404/503 |
| `Target.NotInUse` | El target group no está asociado a un listener | Configuración |
| `Elb.RegistrationInProgress` | Todavía registrándose | Esperar |
| `Target.ResponseCodeMismatch` | Respondió fuera del rango del matcher | Configuración del matcher |

Un timeout es un problema de red; un código de estado es un problema de aplicación. Esa sola distinción deriva el incidente al equipo correcto en segundos.

### 8.8 Reachability Analyzer — proving a path without sending a packet

Esta es la herramienta que termina la mayoría de las discusiones sobre conectividad de VPC, porque evalúa route tables, security groups, NACLs y gateways como configuración en lugar de sondear.

```
$ aws ec2 create-network-insights-path \
    --source i-0af31c7e9b2d5406a \
    --destination i-04e7b2c1f9a83d650 \
    --destination-port 5432 --protocol tcp \
    --query 'NetworkInsightsPath.NetworkInsightsPathId' --output text
nip-0c93b7f2a184e6d05

$ aws ec2 start-network-insights-analysis \
    --network-insights-path-id nip-0c93b7f2a184e6d05 \
    --query 'NetworkInsightsAnalysis.NetworkInsightsAnalysisId' --output text
nia-0b71e4d style8c26f39a

$ aws ec2 describe-network-insights-analyses \
    --network-insights-analysis-ids nia-0b71e4d8c26f39a \
    --query 'NetworkInsightsAnalyses[0].{Status:Status,Reachable:NetworkPathFound,Explanations:Explanations[].[ExplanationCode,Acl.Id,SecurityGroup.Id]}' \
    --output json
{
    "Status": "succeeded",
    "Reachable": false,
    "Explanations": [
        [
            "ENI_SG_RULES_MISMATCH",
            null,
            "sg-0d41e9c72b8a35f60"
        ]
    ]
}
```

Valores comunes de `ExplanationCode` y su significado:

| Código | Significado |
|---|---|
| `ENI_SG_RULES_MISMATCH` | Ninguna regla de security group permite este flujo |
| `ACL_RULES_MISMATCH` | Una entrada de NACL lo deniega (revisá **ambas** direcciones) |
| `NO_ROUTE_TO_DESTINATION` | La route table no tiene una ruta coincidente |
| `MISSING_INTERNET_GATEWAY` | Se intentó un camino público sin ruta al IGW |
| `NO_PUBLIC_IP` / `ELASTIC_NETWORK_INTERFACE_NO_PUBLIC_IP` | La instancia no tiene IP pública/elástica |
| `SUBNET_HAS_NO_ROUTE_TABLE_ASSOCIATION` | La subnet cayó de vuelta a la route table principal |

Reachability Analyzer cuesta unos centavos por análisis y es el primer paso correcto para cualquier ticket de "no puedo conectarme" — más barato que una hora de ingeniero por tres órdenes de magnitud.

### 8.9 Hybrid connectivity status

```
$ aws directconnect describe-connections \
    --query 'connections[].{Id:connectionId,Name:connectionName,State:connectionState,Bw:bandwidth,Loc:location,Vlan:vlan,Macsec:macSecCapable,Encr:encryptionMode}' \
    --output table
------------------------------------------------------------------------------------------
|                                  DescribeConnections                                   |
+---------+--------+-------------------+------+---------+----------+---------+-----------+
|   Bw    |  Encr  |        Id         | Loc  | Macsec  |   Name   |  State  |   Vlan    |
+---------+--------+-------------------+------+---------+----------+---------+-----------+
| 10Gbps  |should_encrypt| dxcon-fh2k9x1p | EqDC2 | True | dc-primary | available | 4093 |
| 10Gbps  |no_encrypt    | dxcon-fg7m4b3q | CS1  | False| dc-backup  | available | 4094 |
+---------+--------+-------------------+------+---------+----------+---------+-----------+
```

```
$ aws ec2 describe-vpn-connections \
    --query 'VpnConnections[].{Id:VpnConnectionId,State:State,Tunnels:VgwTelemetry[].[OutsideIpAddress,Status,AcceptedRouteCount]}' \
    --output json
[
  {
    "Id": "vpn-0e83c1a7b2f94d605",
    "State": "available",
    "Tunnels": [
      ["34.201.77.14",  "UP",   42],
      ["52.90.163.201", "DOWN",  0]
    ]
  }
]
```

Un túnel `UP` es un estado **degradado**, no uno sano. Los dos túneles deberían estar `UP` y ambos deberían mostrar un `AcceptedRouteCount` distinto de cero; un túnel que está `UP` con cero rutas aceptadas es una sesión BGP que se estableció pero no anuncia nada — el tráfico no lo va a usar durante el failover, y eso lo vas a descubrir durante el failover.

### 8.10 Path and MTU diagnostics from inside an instance

```
$ ip -br addr show dev ens5
ens5  UP  10.42.68.31/20 metric 1024 2600:1f18:2c4a:e602:8c1f:...

$ ip route get 10.42.131.14
10.42.131.14 via 10.42.64.1 dev ens5 src 10.42.68.31 uid 1000

$ curl -s -o /dev/null -w 'dns=%{time_namelookup} tcp=%{time_connect} tls=%{time_appconnect} ttfb=%{time_starttransfer} total=%{time_total}\n' \
    https://api.example.com/healthz
dns=0.004 tcp=0.009 tls=0.041 ttfb=0.058 total=0.059
```

Leer los tiempos de curl es en sí mismo un diagnóstico: un `time_namelookup` grande implica al resolver `.2`, un `time_connect` grande implica al camino de red o a un SYN descartado, un `time_appconnect` grande implica el manejo de TLS/certificados, y una brecha grande entre `appconnect` y `starttransfer` es la aplicación.

Verificación de MTU — la falla que parece "los requests grandes se cuelgan":

```
$ ping -M do -s 8972 10.42.131.14 -c 2
PING 10.42.131.14 (10.42.131.14) 8972(9000) bytes of data.
8980 bytes from 10.42.131.14: icmp_seq=1 ttl=255 time=0.412 ms
8980 bytes from 10.42.131.14: icmp_seq=2 ttl=255 time=0.389 ms

$ ping -M do -s 1472 -c 2 example.com
PING example.com (93.184.216.34) 1472(1500) bytes of data.
1480 bytes from 93.184.216.34: icmp_seq=1 ttl=52 time=11.7 ms

$ ping -M do -s 8972 -c 2 203.0.113.40   # over Site-to-Site VPN
PING 203.0.113.40 (203.0.113.40) 8972(9000) bytes of data.
ping: local error: message too long, mtu=1500
```

| Camino | MTU |
|---|---|
| Dentro de una VPC, misma AZ o entre AZ | **9001** (jumbo frames) |
| A través de un internet gateway hacia internet | **1500** |
| Sobre una Site-to-Site VPN | **1500** menos el overhead de IPsec (≈1436 utilizables; clampear el MSS a 1379) |
| Direct Connect private / transit VIF | 9001 / 8500 |
| A través de una conexión de VPC peering (misma Región) | 9001 |
| VPC peering inter-Región | 1500 |

Cuando el ICMP "fragmentation needed" es bloqueado por una NACL o un firewall on-prem, el Path MTU Discovery se rompe en silencio: el handshake TCP tiene éxito (paquetes chicos), y después el primer segmento de datos de tamaño completo se pierde en un agujero negro. El síntoma es "conexión establecida, después se cuelga" — y la solución es clampeo de MSS, no un cambio de security group.

---

## 9. Verification and failure-diagnosis guide

### 9.1 The connectivity ladder — always run it in this order

Cada escalón es más barato que el siguiente. No te los saltees.

**1. ¿El DNS resuelve, y a la dirección que esperás?**
```
$ dig +short api.internal.example.com
10.42.68.204
```
Una respuesta pública donde corresponde una privada → revisá `enableDnsHostnames`, la asociación de la VPC a la private hosted zone, `PrivateDnsEnabled`. `NXDOMAIN` desde una subnet privada → la instancia no está usando el resolver `.2` (revisá el DHCP option set).

**2. ¿El destino está en la VPC local, o necesita una ruta?**
```
$ aws ec2 describe-route-tables --filters Name=association.subnet-id,Values=subnet-09ab... \
    --query 'RouteTables[0].Routes[].[DestinationCidrBlock,GatewayId,NatGatewayId,State]' --output text
10.42.0.0/16   local   None   active
0.0.0.0/0      None    nat-0918c4e7b2f3d6a51   active
```
Ninguna salida en absoluto → **la subnet no tiene asociación explícita y heredó silenciosamente la route table principal**. Esta es una de las tres causas principales de "mi subnet nueva no tiene internet".
`State: blackhole` → el target de la ruta (NAT gateway, ENI, conexión de peering) fue borrado. La ruta sobrevive a su target; nada te alerta.

**3. Para alcanzabilidad pública, ¿hay una IP pública *y* una ruta al IGW?** Ambas son necesarias. Una instancia con IP pública en una subnet sin ruta al IGW es inalcanzable; una instancia en una subnet pública sin IP pública es igualmente inalcanzable. Una IP privada con una ruta a NAT te da solo salida.

**4. Security group, lado de egreso (origen).** Los SG por defecto permiten todo el egreso; los endurecidos frecuentemente no.

**5. Security group, lado de ingreso (destino).** Verificá con el SG ID, no leyendo nombres.

**6. NACL, ambas direcciones, ambas subnets.** Cuatro chequeos: egreso en la subnet de origen, ingreso en la subnet de destino, egreso en la subnet de destino (**efímeros**), ingreso en la subnet de origen (**efímeros**). Acordate de que las reglas se evalúan de menor número a mayor y se detienen en la primera coincidencia — un `DENY` en la regla 90 vuelve inalcanzable a un `ALLOW` en la regla 100.

**7. ¿El proceso está realmente escuchando, en la dirección correcta?**
```
$ ss -lntp
State   Recv-Q  Send-Q  Local Address:Port   Peer Address:Port  Process
LISTEN  0       4096        127.0.0.1:8080         0.0.0.0:*      users:(("app",pid=1841,fd=7))
```
Ligado a `127.0.0.1` — ninguna cantidad de configuración de VPC va a arreglar esto. Tiene que ser `0.0.0.0:8080` o `[::]:8080`.

**8. MTU / PMTUD.** Ver §8.10. Llegá a este escalón solo cuando el handshake tiene éxito y la transferencia masiva se estanca.

### 9.2 Symptom → cause lookup table

| Síntoma | Causa más probable | Comando de verificación |
|---|---|---|
| `Connection timed out` en una instancia nueva | Falta el ingreso en el security group | `aws ec2 describe-security-groups` |
| Handshake OK, la transferencia se cuelga con payloads grandes | Agujero negro de PMTUD | `ping -M do -s 1472` |
| Funciona en un sentido, falla en el otro | Falta la regla de puertos efímeros en la NACL | `aws ec2 describe-network-acls` |
| La instancia pierde internet después de un cambio | La ruta ahora está en `blackhole` (NAT borrado) | `describe-route-tables` → `State` |
| Pods trabados en `ContainerCreating` | Agotamiento de IPs en la subnet | `describe-subnets` → `AvailableIpAddressCount` |
| S3 funciona, DynamoDB no, desde la capa de datos | El gateway endpoint no está asociado a esa route table | `describe-vpc-endpoints` → `RouteTableIds` |
| Llamadas del SDK lentas, `SERVFAIL` ocasional | Límite de 1024 pps del resolver `.2` | Resolver cacheador local; Route 53 Resolver endpoint |
| Targets del ALB `unhealthy`, razón `Target.Timeout` | El SG del target no permite el SG del ALB | `describe-target-health` |
| ALB `503 Service Unavailable` | Cero targets sanos en el grupo | `describe-target-health` |
| ALB `502 Bad Gateway` | El target cerró la conexión / respuesta inválida / desajuste de TLS | Logs de la aplicación del target + access logs del ALB |
| ALB `504 Gateway Timeout` | El target es más lento que el idle timeout | Métrica `TargetResponseTime` del ALB |
| Latencia cross-AZ intermitente después de un cambio de NAT | Subnet privada ruteada a un NAT en otra AZ | `describe-route-tables` por AZ |
| La VPN se cae cada ~8 horas | Desajuste de rekey de IKE / sin DPD | `describe-vpn-connections` → `VgwTelemetry` |
| VPC peered inalcanzable más allá de un salto | El peering es no transitivo | Usar Transit Gateway |
| CloudFront sirve contenido viejo | TTL de caché / sin invalidación | `aws cloudfront create-invalidation` |
| CloudFront `403` desde un origen S3 | OAC mal configurado o falta la bucket policy | Bucket policy + comportamiento de firma del OAC |

### 9.3 Continuous verification, not point-in-time checks

| Herramienta | Pregunta que responde | Costo |
|---|---|---|
| **VPC Reachability Analyzer** | ¿*Puede* A alcanzar a B, según la configuración? | Por análisis (centavos) |
| **Network Access Analyzer** | ¿Existe *algún* camino no intencionado hacia internet? | Por análisis |
| **VPC Flow Logs** | ¿Qué tráfico ocurrió realmente, aceptado y rechazado? | Ingesta + almacenamiento |
| **CloudWatch Internet Monitor** | ¿La degradación es nuestra o del ISP del cliente? | Por city-network monitoreada |
| **CloudWatch Network Monitor** | ¿Se está degradando el camino híbrido (DX/VPN)? | Por sonda |
| Reglas de **AWS Config** | ¿Hay un security group abierto a `0.0.0.0/0` en el puerto 22? | Por evaluación |
| **Route 53 health checks** | ¿El endpoint está sano desde múltiples puntos de observación globales? | Por health check/mes |

Recomendación de base para cualquier VPC de producción: flow logs activados con el formato extendido, un scope de Network Access Analyzer para caminos no intencionados hacia internet evaluado de forma programada, reglas de Config para security groups abiertos, y alarmas de CloudWatch sobre `AvailableIpAddressCount`, `ErrorPortAllocation` del NAT y `HealthyHostCount` del ALB.

---

## 10. Cost model — the network line items that actually appear on the bill

*Precios de lista aproximados de `us-east-1`, solo para razonar en órdenes de magnitud. Confirmá siempre contra las páginas de precios en vivo.*

| Ítem | Cargo aproximado | Notas |
|---|---|---|
| Transferencia de datos **entrante** desde internet | **$0,00** | El ingreso es gratis |
| Transferencia de datos **saliente** hacia internet | ~$0,09/GB (escalonado, 100 GB/mes gratis) | El ítem dominante a escala |
| Transferencia de datos **saliente vía CloudFront** | ~$0,085/GB | Más barato que el DTO de EC2; **origen→CloudFront es gratis** |
| Cross-AZ, misma Región | ~$0,01/GB **en cada dirección** | Se cobra de ambos lados |
| Cross-Región | $0,02–$0,15/GB | Depende del par de Regiones |
| Misma AZ, IPv4 privada | **$0,00** | Usá IPs privadas; las públicas se re-rutean por el IGW y se cobran |
| **Dirección IPv4 pública** | **~$0,005/hr cada una** (~$3,65/mes) | Desde el 2024-02-01 se cobra **esté asociada o no** |
| NAT gateway | ~$0,045/hr + ~$0,045/GB | Se aplican ambos cargos; los endpoints eliminan el segundo |
| Gateway VPC endpoint | **$0,00** | S3 y DynamoDB |
| Interface VPC endpoint | ~$0,01/hr/AZ + ~$0,01/GB | 2 AZ ≈ $14,60/mes por endpoint |
| Transit Gateway | ~$0,05/attachment-hr + ~$0,02/GB | La cantidad de attachments dirige el costo base |
| VPC peering (intra-AZ) | **$0,00** | Cross-AZ se factura a tarifas estándar |
| Site-to-Site VPN | ~$0,05/hr por conexión + DTO | Por conexión, no por túnel |
| Direct Connect | Port-hours + DTO reducido (~$0,02/GB) | Se equilibra contra el DTO de internet a volumen sostenido |
| ALB / NLB | Por hora + LCU/NLCU-hours | LCU = máximo entre conexiones nuevas, conexiones activas, ancho de banda y evaluaciones de reglas |
| Hosted zone de Route 53 | ~$0,50/zona/mes | Consultas ~$0,40/millón; **el alias hacia targets de AWS es gratis** |
| Global Accelerator | ~$0,025/hr por accelerator + premium de transferencia de datos | Costo horario fijo sin importar el tráfico |

**Las tres acciones de costo de mayor apalancamiento**, en orden: (1) poner el tráfico de S3/DynamoDB en gateway endpoints gratuitos; (2) liberar las Elastic IP no asociadas — ahora cuestan plata mientras están ociosas; (3) mantener el tráfico servicio-a-servicio hablador dentro de la misma AZ, ya que el cross-AZ se factura en ambas direcciones y calladamente se duplica.

---

## 11. Exam-discrimination table

CLF-C02 evalúa reconocimiento bajo el encuadre de escenarios. Estos son los pares que separan un aprobado de un fallo.

| Palabra clave del escenario | Servicio correcto | Respuesta equivocada común |
|---|---|---|
| "Red virtual aislada, mi propio rango de IPs" | **Amazon VPC** | Direct Connect |
| "Conexión física privada dedicada hacia on-prem" | **AWS Direct Connect** | Site-to-Site VPN |
| "Conexión cifrada hacia on-prem, rápida de configurar, por internet" | **AWS Site-to-Site VPN** | Direct Connect |
| "Empleados remotos individuales se conectan de forma segura a la VPC" | **AWS Client VPN** | Site-to-Site VPN |
| "Conectar cientos de VPCs y on-prem a través de un único hub" | **AWS Transit Gateway** | VPC peering |
| "Dos VPCs, tráfico privado, simple" | **VPC peering** | Transit Gateway |
| "Alcanzar un servicio de AWS de forma privada, sin internet gateway" | **VPC endpoint / AWS PrivateLink** | NAT gateway |
| "Acceso privado gratuito a S3 desde una subnet privada" | **Gateway endpoint** | Interface endpoint |
| "Exponer mi propio servicio a otra VPC/cuenta de forma privada" | **AWS PrivateLink** | VPC peering |
| "DNS, registro de dominios, failover por health check" | **Amazon Route 53** | CloudFront |
| "Cachear contenido estático y dinámico cerca de los usuarios" | **Amazon CloudFront** | Global Accelerator |
| "Direcciones IP estáticas, UDP/TCP, failover regional rápido" | **AWS Global Accelerator** | CloudFront |
| "Rutear requests HTTP por path de URL hacia microservicios" | **Application Load Balancer** | Network Load Balancer |
| "Millones de conexiones TCP, IP estática, latencia ultrabaja" | **Network Load Balancer** | ALB |
| "Insertar appliances de firewall de terceros de forma transparente" | **Gateway Load Balancer** | Network Firewall |
| "Bloquear inyección SQL y cross-site scripting" | **AWS WAF** | Security groups |
| "Protección DDoS, automática y gratuita" | **AWS Shield Standard** | Shield Advanced |
| "IDS/IPS gestionado filtrando a nivel de VPC" | **AWS Network Firewall** | WAF |
| "Registrar metadatos del tráfico IP aceptado y rechazado" | **VPC Flow Logs** | CloudTrail |
| "Firewall a nivel de instancia, stateful" | **Security group** | Network ACL |
| "Firewall a nivel de subnet, permite DENY explícito" | **Network ACL** | Security group |
| "Mover 100 TB donde la red es impracticable" | **AWS Snowball Edge** | Direct Connect |
| "Llevar físicamente infraestructura de AWS a mi centro de datos" | **AWS Outposts** | Local Zones |
| "Latencia de un solo dígito de milisegundos hacia un área metropolitana específica" | **AWS Local Zones** | Edge locations |
| "Cómputo en el edge 5G dentro de una red de carrier" | **AWS Wavelength** | Local Zones |

---

## 12. Referencias

**Material oficial del examen**
- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- Página de la certificación AWS Certified Cloud Practitioner — https://aws.amazon.com/certification/certified-cloud-practitioner/

**Amazon VPC**
- Amazon VPC User Guide — https://docs.aws.amazon.com/vpc/latest/userguide/what-is-amazon-vpc.html
- Bloques CIDR de la VPC y dimensionamiento de subnets — https://docs.aws.amazon.com/vpc/latest/userguide/vpc-cidr-blocks.html
- Subnets y direcciones IP reservadas — https://docs.aws.amazon.com/vpc/latest/userguide/subnet-sizing.html
- Route tables — https://docs.aws.amazon.com/vpc/latest/userguide/VPC_Route_Tables.html
- Internet gateways — https://docs.aws.amazon.com/vpc/latest/userguide/VPC_Internet_Gateway.html
- NAT gateways — https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-gateway.html
- Egress-only internet gateways — https://docs.aws.amazon.com/vpc/latest/userguide/egress-only-internet-gateway.html
- Security groups — https://docs.aws.amazon.com/vpc/latest/userguide/vpc-security-groups.html
- Network ACLs (incluyendo puertos efímeros) — https://docs.aws.amazon.com/vpc/latest/userguide/vpc-network-acls.html
- VPC Flow Logs y campos de registro — https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs-records-examples.html
- MTU de red para instancias EC2 — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/network_mtu.html
- Cuotas de Amazon VPC — https://docs.aws.amazon.com/vpc/latest/userguide/amazon-vpc-limits.html

**Endpoints, peering e híbrido**
- AWS PrivateLink y VPC endpoints — https://docs.aws.amazon.com/vpc/latest/privatelink/what-is-privatelink.html
- Gateway endpoints — https://docs.aws.amazon.com/vpc/latest/privatelink/gateway-endpoints.html
- VPC peering — https://docs.aws.amazon.com/vpc/latest/peering/what-is-vpc-peering.html
- AWS Transit Gateway — https://docs.aws.amazon.com/vpc/latest/tgw/what-is-transit-gateway.html
- AWS Site-to-Site VPN — https://docs.aws.amazon.com/vpn/latest/s2svpn/VPC_VPN.html
- AWS Client VPN — https://docs.aws.amazon.com/vpn/latest/clientvpn-admin/what-is.html
- AWS Direct Connect — https://docs.aws.amazon.com/directconnect/latest/UserGuide/Welcome.html
- Recomendaciones de resiliencia de Direct Connect — https://docs.aws.amazon.com/directconnect/latest/UserGuide/high_resiliency_selection.html
- AWS Cloud WAN — https://docs.aws.amazon.com/network-manager/latest/cloudwan/what-is-cloudwan.html

**Balanceo de carga**
- Comparación de funcionalidades de Elastic Load Balancing — https://aws.amazon.com/elasticloadbalancing/features/
- Application Load Balancer — https://docs.aws.amazon.com/elasticloadbalancing/latest/application/introduction.html
- Network Load Balancer — https://docs.aws.amazon.com/elasticloadbalancing/latest/network/introduction.html
- Gateway Load Balancer — https://docs.aws.amazon.com/elasticloadbalancing/latest/gateway/introduction.html
- Razones de estado de salud de targets del ALB — https://docs.aws.amazon.com/elasticloadbalancing/latest/application/target-group-health-checks.html

**DNS y edge**
- Amazon Route 53 Developer Guide — https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/Welcome.html
- Políticas de ruteo de Route 53 — https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/routing-policy.html
- Elegir entre registros alias y no alias — https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/resource-record-sets-choosing-alias-non-alias.html
- Route 53 Resolver para DNS híbrido — https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/resolver.html
- Amazon CloudFront Developer Guide — https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/Introduction.html
- Origin Access Control para orígenes S3 — https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-restricting-access-to-s3.html
- CloudFront Functions vs. Lambda@Edge — https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/edge-functions-choosing.html
- AWS Global Accelerator Developer Guide — https://docs.aws.amazon.com/global-accelerator/latest/dg/what-is-global-accelerator.html

**Seguridad de red y observabilidad**
- AWS WAF Developer Guide — https://docs.aws.amazon.com/waf/latest/developerguide/waf-chapter.html
- AWS Shield Standard y Advanced — https://docs.aws.amazon.com/waf/latest/developerguide/shield-chapter.html
- AWS Network Firewall — https://docs.aws.amazon.com/network-firewall/latest/developerguide/what-is-aws-network-firewall.html
- VPC Reachability Analyzer — https://docs.aws.amazon.com/vpc/latest/reachability/what-is-reachability-analyzer.html
- Network Access Analyzer — https://docs.aws.amazon.com/vpc/latest/network-access-analyzer/what-is-network-access-analyzer.html
- Amazon CloudWatch Internet Monitor — https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-InternetMonitor.html

**Precios y costos**
- Precios de Amazon VPC (NAT gateway, endpoints, IPv4) — https://aws.amazon.com/vpc/pricing/
- Precios de transferencia de datos de EC2 — https://aws.amazon.com/ec2/pricing/on-demand/#Data_Transfer
- Cargo por dirección IPv4 pública — https://aws.amazon.com/blogs/aws/new-aws-public-ipv4-address-charge-public-ip-insights/
- Precios de Elastic Load Balancing — https://aws.amazon.com/elasticloadbalancing/pricing/
- Precios de Amazon Route 53 — https://aws.amazon.com/route53/pricing/
- Precios de Amazon CloudFront — https://aws.amazon.com/cloudfront/pricing/
- Precios de AWS Direct Connect — https://aws.amazon.com/directconnect/pricing/

**Arquitecturas de referencia**
- AWS Well-Architected Framework — https://docs.aws.amazon.com/wellarchitected/latest/framework/welcome.html
- AWS Architecture Center — networking — https://aws.amazon.com/architecture/networking-content-delivery/
- AWS Whitepaper: Building a Scalable and Secure Multi-VPC AWS Network Infrastructure — https://docs.aws.amazon.com/whitepapers/latest/building-scalable-secure-multi-vpc-network-infrastructure/welcome.html
- Referencia del recurso `AWS::EC2::VPC` de CloudFormation — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-ec2-vpc.html
- Función intrínseca `Fn::Cidr` de CloudFormation — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/intrinsic-function-reference-cidr.html