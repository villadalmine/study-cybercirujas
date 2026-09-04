# 3.2 — Definir la infraestructura global de AWS

**Certificación:** AWS Certified Cloud Practitioner (CLF-C02) · **Dominio 3:** Cloud Technology and Services · **Tarea 3.2** · **Peso del dominio:** 4.25

> **Cómo leer este módulo.** CLF-C02 evalúa esta tarea a nivel definicional — "qué es una Availability Zone", "cuándo usás una Edge location". Ese es el piso, no el techo. Este módulo enseña la topología como un Platform Architect tiene que sostenerla: como un **modelo de dominios de fallo** que determina tu radio de impacto, tu RTO/RPO, tu factura de transferencia de datos y dónde viven tus dependencias de plano de control. La sección 10 destila los hechos que el examen pregunta, si solo tenés veinte minutos.

---

## 1. El problema de producción: los dominios de fallo son una entrada de diseño, no una nota al pie

Todo sistema distribuido tiene un problema de *fallo correlacionado*. Dos réplicas solo te dan redundancia si no comparten destino — la misma alimentación eléctrica, el mismo switch de tope de rack, el mismo edificio, la misma ruta de fibra, el mismo plano de control, el mismo pipeline de despliegue. La redundancia que comparte destino no es redundancia; es un punto único de fallo más caro.

La infraestructura global de AWS existe para darte **dominios de fallo nombrados y contractuales**, de modo que puedas razonar sobre el destino compartido sin ser dueño de los edificios. Cuando AWS dice "Availability Zone", está haciendo una promesa específica sobre energía, refrigeración y separación física independientes. Cuando dice "Region", está haciendo una promesa mucho más fuerte sobre aislamiento operativo. Tu trabajo es ubicar deliberadamente los componentes de la carga de trabajo dentro de esos dominios.

Considerá tres formas reales de incidente que este módulo está diseñado para prevenir:

**Forma de incidente A — la AZ única invisible.** Un equipo corre un Auto Scaling group con `min=3`, se siente seguro y descubre durante una degradación de AZ que las tres instancias estaban en `us-east-1a` porque el ASG se creó con una sola subnet. El `DesiredCapacity` se cumplió; la disponibilidad no. El conteo de redundancia nunca fue la propiedad que importaba — lo era la *diversidad de ubicación*.

**Forma de incidente B — el nombre de AZ entre cuentas.** La cuenta A comparte una subnet en `us-east-1a` con la cuenta B mediante AWS Resource Access Manager. La cuenta B lanza su flota consumidora en *su* `us-east-1a`, esperando co-ubicación, y ahora cada petición cruza un límite de AZ — sumando latencia, sumando `$0.01/GB` en cada dirección y creando un fallo correlacionado que el diagrama de arquitectura no muestra. Los **nombres** de AZ se aleatorizan por cuenta; los **IDs** de AZ no. Este es el hecho que más comúnmente se pasa por alto en todo el dominio.

**Forma de incidente C — la dependencia del plano de control durante el failover.** Un diseño "multi-Region activo/pasivo" hace failover llamando a `CreateAutoScalingGroup` y `UpdateDistribution` en la Region en espera — durante el evento exacto en el que los planos de control están degradados. El plan de failover dependía de lo que estaba roto. La corrección es **estabilidad estática**: pre-aprovisionar la capacidad en espera y cambiar solo estado del plano de datos (un registro DNS, un traffic dial de Global Accelerator, un routing control).

Los tres son errores de topología, no errores de código. Por eso esta tarea tiene peso en un examen dirigido a gente que todavía no escribe el código.

---

## 2. La jerarquía, con precisión

```
AWS Partition                       (aws | aws-cn | aws-us-gov | isolated partitions)
 └── Region                         (us-east-1, eu-central-1, sa-east-1, …)
      ├── Availability Zone         (name: us-east-1a  |  ID: use1-az4)
      │    └── one or more discrete data centers
      │         └── redundant power, cooling, networking
      ├── Local Zone                (us-west-2-lax-1a — metro extension of the Region)
      └── Wavelength Zone           (us-east-1-wl1-bos-wlz-1 — inside a carrier 5G network)

Attached to, but not inside, a Region:
      ├── AWS Outposts              (AWS-managed rack/server on your premises, anchored to a home Region)
      └── AWS Edge network          (CloudFront PoPs, Regional Edge Caches, Global Accelerator
                                     ingress, Route 53 anycast, Direct Connect locations)
```

Leé ese árbol como un **gradiente de destino compartido**: dos centros de datos en una AZ comparten más destino que dos AZs en una Region, que comparten más destino que dos Regions, que comparten más destino que dos particiones. El costo y la complejidad suben por el mismo gradiente. La pregunta de arquitectura siempre es *¿contra qué fallo correlacionado estoy comprando seguro, y cuál es la prima?*

### 2.1 Particiones y por qué el ARN empieza con una

Una **partición** es el límite de aislamiento más grande que AWS publica. Las cuentas, los principals de IAM y el espacio de nombres global no cruzan particiones. No podés asumir un rol en `aws-us-gov` desde una cuenta en `aws`. Esto aparece sintácticamente en cada Amazon Resource Name:

```
arn:partition:service:region:account-id:resource-type/resource-id
    ^^^^^^^^^
arn:aws:s3:::static-assets-prod
arn:aws:iam::123456789012:role/PlatformDeployer
arn:aws:ec2:eu-central-1:123456789012:subnet/subnet-0a1b2c3d4e5f67890
arn:aws-cn:s3:::static-assets-prod-cn
arn:aws-us-gov:iam::123456789012:role/PlatformDeployer
```

| Partición | Regions | Modelo de cuenta | Notas |
|---|---|---|---|
| `aws` | Regions comerciales en todo el mundo | Cuenta AWS estándar | La predeterminada; todo en este módulo salvo que se indique |
| `aws-cn` | `cn-north-1` (Beijing), `cn-northwest-1` (Ningxia) | Cuenta separada, operada por Sinnet / NWCD | Consola separada, credenciales separadas, se requiere registro ICP para sitios públicos |
| `aws-us-gov` | `us-gov-west-1`, `us-gov-east-1` | Cuenta GovCloud separada, patrocinada por una cuenta comercial | Cargas de trabajo ITAR / FedRAMP High; operadores estadounidenses verificados |

**Consecuencia práctica para IaC:** cualquier política de IAM o módulo de CDK/Terraform que pretendas portable nunca debe fijar `arn:aws:` de forma rígida. Usá `arn:${AWS::Partition}:` en CloudFormation, `data.aws_partition.current.partition` en Terraform, o un comodín `arn:*:` donde la semántica de la política lo permita.

### 2.2 Regions

Una Region es un **área geográfica separada que contiene múltiples Availability Zones aisladas**. AWS diseña las Regions para que sean operativamente independientes: un evento a nivel Region no debería propagarse. Las Regions son el límite para:

- **Residencia de datos.** Tus datos se quedan en la Region donde los pusiste salvo que *vos* configures replicación. Este es el mecanismo detrás de las respuestas sobre GDPR/soberanía de datos.
- **Cuotas de servicio.** Los límites son por cuenta y por Region. Un aumento de cuota en `eu-west-1` no hace nada por `eu-west-2`.
- **Disponibilidad de servicios.** No todos los servicios existen en todas las Regions, y los servicios nuevos suelen lanzarse primero en un subconjunto.
- **Precios.** Los precios por hora y por GB difieren según la Region — a veces entre un 30 y un 60% para la misma familia de instancias.
- **La mayoría de las APIs.** Los endpoints regionales se ven como `https://ec2.eu-central-1.amazonaws.com`.

Las Regions nuevas se lanzan con **al menos tres Availability Zones**, porque tres es el mínimo para que los sistemas basados en quórum toleren una pérdida y conserven una mayoría.

**Tipos de Region según estado de activación:**

| Tipo | Ejemplos | Comportamiento |
|---|---|---|
| Habilitada por defecto | `us-east-1`, `us-west-2`, `eu-west-1`, `ap-southeast-2`, … | Utilizable de inmediato en toda cuenta |
| Opt-in | `af-south-1`, `ap-east-1`, `eu-south-1`, `me-central-1`, `il-central-1`, `ca-west-1`, … | Debe habilitarse explícitamente por cuenta; deshabilitada por defecto, así que las credenciales de IAM no son válidas allí |
| Partición separada | `cn-*`, `us-gov-*` | Requiere una cuenta completamente distinta |

Las Regions opt-in existen porque habilitar una Region expande tu radio de impacto de IAM: las credenciales que se filtran quedan utilizables en un lugar más. Mantener deshabilitadas las Regions sin uso es un control de seguridad legítimo, y es aplicable a nivel Organization con SCPs y la Account Management API.

> El conteo publicado de Regions, AZs, Local Zones y PoPs de borde cambia varias veces al año. No memorices el número — memorizá dónde se publica (ver §11) y cómo consultarlo (ver §7.1).

### 2.3 Availability Zones — la parte que realmente es sutil

Una Availability Zone es **uno o más centros de datos discretos con energía, redes y conectividad redundantes dentro de una Region**. Las propiedades de diseño publicadas por AWS:

- Las AZs están **físicamente separadas por una distancia significativa** — muchos kilómetros — y ubicadas en distintas llanuras de inundación, en distintas redes eléctricas donde es factible, con acometidas de suministro independientes y generación de respaldo.
- La separación, no obstante, está acotada (AWS documenta "dentro de 100 km / 60 millas") para que **la latencia entre AZs se mantenga lo bastante baja como para replicación síncrona**. Este es el punto entero: lo bastante lejos para no compartir un desastre, lo bastante cerca para correr un quórum síncrono.
- Todo el tráfico entre AZs dentro de una Region atraviesa **fibra propia de AWS, redundante, de alto ancho de banda y baja latencia**, y está **cifrado en tránsito a nivel de capa física**.

Ese presupuesto de latencia es la razón por la que la postura por defecto en producción es **Multi-AZ, single-Region**: obtenés aislamiento de fallos real sin dejar de poder correr commit síncrono de RDS Multi-AZ, un quórum de etcd/ZooKeeper o un clúster de Kafka con `min.insync.replicas=2` sin rediseñar la consistencia.

#### Los nombres de AZ son alias por cuenta. Los IDs de AZ son físicos.

AWS mapea los **nombres** de AZ (`us-east-1a`) a AZs físicas **de forma independiente por cuenta**, para evitar que todo el mundo se amontone en "la primera". El **AZ ID** (`use1-az4`) es el identificador estable e independiente de la cuenta para la zona física.

| Propiedad | Nombre de AZ (`us-east-1a`) | AZ ID (`use1-az4`) |
|---|---|---|
| Consistente entre cuentas | ❌ No | ✅ Sí |
| Estable en el tiempo dentro de una cuenta | ✅ Sí | ✅ Sí |
| Mostrado en la mayoría de las pantallas de la consola | ✅ Sí | A veces, entre paréntesis |
| Usado por subnets compartidas con AWS RAM | Se muestra como el nombre propio del consumidor | ✅ El campo autoritativo |
| Lo que debés usar para co-ubicación entre cuentas | ❌ | ✅ |
| Lo que debés usar para correlacionar un evento del Health Dashboard | ❌ | ✅ |
| Lo que debés usar para `arc-zonal-shift` | ❌ | ✅ |

Cada vez que dos cuentas de AWS deben coincidir sobre *dónde* está algo físicamente — subnets de VPC compartidas, ubicación de endpoints de PrivateLink, atribución de costos entre cuentas, una evacuación coordinada — el contrato es el AZ ID.

### 2.4 Extender la Region: Local Zones, Wavelength, Outposts

Estos tres existen por la misma razón: algunas cargas de trabajo no toleran la física de la distancia hasta la Region más cercana, o no pueden legalmente salir de un edificio.

| | **Local Zone** | **Wavelength Zone** | **Outposts** |
|---|---|---|---|
| Qué es | Infraestructura propia de AWS en un área metropolitana, una extensión de una Region padre | Cómputo/almacenamiento de AWS embebido dentro de la red 5G de un proveedor de telecomunicaciones | Rack (42U) o servidor (1U/2U) diseñado por AWS e instalado en *tu* centro de datos |
| Nomenclatura | `us-west-2-lax-1a` | `us-east-1-wl1-bos-wlz-1` | No es una AZ; anclado a una Region de origen + AZ |
| Objetivo de latencia | Milisegundos de un dígito hacia el área metropolitana | Milisegundos de un dígito hacia dispositivos 5G, el tráfico nunca sale de la red del operador | Latencia de LAN hacia tus sistemas on-prem |
| Se alcanza vía | Extender una VPC de la Region con una subnet en la Local Zone | Carrier gateway (`carrier-gateway`), no un IGW | Local gateway (`local-gateway`) + service link hacia la Region de origen |
| Catálogo de servicios | Subconjunto pequeño (EC2, EBS, algunos nodos de ELB/ECS/EKS) | Subconjunto muy pequeño (EC2, EBS, nodos de EKS/ECS) | Subconjunto; algunos servicios son nativos de Outpost, la mayoría no |
| Activación | Opt-in por cuenta del **grupo** de AZ | Opt-in por cuenta del grupo de AZ | Pedir el hardware; AWS lo instala y lo gestiona |
| Postura de resiliencia | **Normalmente una sola zona — no es HA de por sí.** Tratala como un único dominio de fallo | Zona única | Sitio único; sos dueño del destino de la energía/refrigeración del edificio |
| Uso típico | Renderizado de medios en tiempo real, gaming de baja latencia, co-ubicación para trading financiero, staging de migración on-prem | AR/VR en móvil, vehículos conectados, IoT industrial sobre 5G privado | Residencia de datos en un país sin Region, procesamiento on-prem regulado, sistemas legados con un acoplamiento duro de latencia |

**La compensación que hay que internalizar:** cada uno de estos compra latencia o residencia *renunciando* a la redundancia a nivel AZ y a la mayor parte del catálogo de servicios. Una Local Zone no es "una AZ extra barata". Si ponés tu única base de datos en `us-west-2-lax-1a`, construiste un sistema de zona única con una factura del tamaño de una Region.

**El plano de control siempre se queda en la Region padre.** Outposts, Local Zones y Wavelength Zones son extensiones del *plano de datos*. Si el service link de un Outpost hacia su Region de origen se corta, las instancias en ejecución siguen corriendo y el tráfico local sigue fluyendo, pero no podés lanzar, terminar ni reconfigurar. Diseñá tus runbooks sobre Outpost asumiendo que la API no está disponible.

### 2.5 La red de borde — un eje completamente distinto

Las Regions y las AZs son sobre *dónde corre tu carga de trabajo*. El borde es sobre *dónde entran tus usuarios a la red de AWS*. Es una capa separada y mucho más densa, con cientos de Points of Presence en muchas más ciudades que Regions existen.

| Componente de borde | Qué hace | El mecanismo | Cuándo recurrir a él |
|---|---|---|---|
| **CloudFront edge locations (PoPs)** | Cachean y sirven contenido HTTP(S) cerca de los usuarios; terminan TLS en el borde | Caching + ingreso por el camino más corto al backbone de AWS | Activos estáticos, video, aceleración de sitio completo, aceleración de APIs |
| **CloudFront Regional Edge Caches** | Cachés de nivel intermedio entre los PoPs y tu origen | Absorben los misses de muchos PoPs, así el origen ve muchas menos peticiones | Automático; la razón por la que una cola larga de baja popularidad igual logra buenas tasas de acierto |
| **AWS Global Accelerator** | Dos **IPs anycast estáticas** que atraen tráfico TCP/UDP al backbone de AWS en el borde más cercano | BGP anycast + endpoint groups con health checks + traffic dials | Protocolos no HTTP, gaming/UDP, requisitos de allowlist de IPs, failover multi-Region rápido |
| **Amazon Route 53** | DNS autoritativo sobre una flota anycast global | SLA de 100% de disponibilidad; enrutamiento por latencia/geolocalización/geoproximidad/failover | Cualquier direccionamiento de tráfico basado en DNS |
| **AWS Direct Connect locations** | Cross-connects físicos hacia la red de AWS | Fibra privada hacia una instalación de colocation adyacente a AWS | Ancho de banda/latencia predecibles desde on-prem; rutas de datos reguladas |
| **AWS WAF / Shield / Lambda@Edge / CloudFront Functions** | Seguridad y cómputo ejecutados en el PoP | Corre antes de que la petición llegue a tu origen | Mitigación de bots, reescritura de headers, enrutamiento A/B, autenticación en el borde |

**CloudFront vs. Global Accelerator** es la comparación que preguntan en las entrevistas y que se confunde en la práctica:

| Dimensión | CloudFront | Global Accelerator |
|---|---|---|
| Protocolos | HTTP/HTTPS (y WebSocket) | Cualquier TCP o UDP |
| Caching | Sí — ese es el valor principal | **No.** Es un optimizador de ruta de red, nunca una caché |
| Dirección de cara al cliente | Un nombre DNS de distribución (`d111111abcdef8.cloudfront.net`) | Dos direcciones IPv4 anycast estáticas (+ BYOIP opcional, dual-stack) |
| Disparador de failover | Failover de origin group ante códigos de error del origen | Health checks de endpoint; retirada anycast automática |
| Velocidad de failover | Segundos, por petición | Típicamente menos de un minuto, e **independiente de la caché DNS** — la IP no cambia |
| Control de direccionamiento multi-Region | Origin groups / Lambda@Edge | `TrafficDialPercentage` y pesos de endpoint — una llamada de API del plano de datos |
| Mejor encaje | Contenido y APIs web | Gaming, VoIP, IoT, MQTT, protocolos financieros, "nuestros clientes empresariales hacen allowlist de IPs" |

La propiedad de Global Accelerator que más importa para recuperación ante desastres: como las IPs de cara al cliente nunca cambian, **el failover no depende de los TTLs de DNS ni del comportamiento del resolver DNS del cliente**. Aplicaciones Java con caché DNS infinita de la JVM, dispositivos embebidos que resuelven una sola vez al arrancar y resolvers corporativos que ignoran los TTLs, todos hacen failover correctamente. Eso vale dinero real en un contexto regulado o de IoT.

---

## 3. Elegir una Region: una decisión de cuatro factores, en orden

El examen lo formula como "factores que influyen en la selección de Region". En producción es un registro de decisión que te van a pedir que defiendas. Evaluá en este orden, porque los dos primeros son restricciones y los dos últimos son optimizaciones:

| # | Factor | La pregunta a responder | Cómo verificarlo | ¿Duro o blando? |
|---|---|---|---|---|
| 1 | **Cumplimiento / soberanía de datos** | ¿Está legalmente permitido almacenar o procesar estos datos acá? ¿Algún regulador exige una jurisdicción específica? | Revisión legal/DPO; AWS Artifact para atestaciones; términos contractuales de residencia de datos | **Duro.** No negociable, se evalúa primero |
| 2 | **Disponibilidad de servicios** | ¿Existen en esta Region *todos* los servicios que esta carga de trabajo necesita, con el nivel de funcionalidad requerido? | Parámetros SSM de global-infrastructure (§7.1); la Regional Services List | **Duro.** Un servicio faltante puede invalidar toda la elección |
| 3 | **Latencia / proximidad a los usuarios** | ¿Cuál es el RTT p99 desde donde los usuarios realmente están? | CloudWatch Internet Monitor; medición de usuarios reales; sondas públicas de latencia | Blando, pero visible para el usuario |
| 4 | **Costo** | ¿Cuánto cuestan acá el cómputo, el almacenamiento y el *egress* frente a la alternativa? | AWS Pricing Calculator; las páginas de precios por servicio | Blando, pero acumulativo |

Dos factores secundarios que los arquitectos con experiencia agregan:

5. **Intensidad de carbono / sustentabilidad** — AWS publica la herramienta de huella de carbono del cliente, y algunas Regions funcionan con una mezcla de red eléctrica sustancialmente más limpia. Para algunas organizaciones esto ya es un requisito de reporte, no una preferencia.
6. **Madurez operativa y correlación del radio de impacto** — `us-east-1` es la Region más grande y más antigua, y aloja el plano de control de origen de varios servicios globales. La usa muchísimo todo el mundo, lo que la vuelve a la vez la Region mejor soportada y aquella cuyos eventos tienen la correlación más amplia a nivel industria. Si estás construyendo la Region de *recuperación ante desastres* de una carga de trabajo, no elegir deliberadamente `us-east-1` es defendible.

### 3.1 El pozo gravitatorio de `us-east-1` — servicios globales y dónde viven sus planos de control

Servicio "global" no significa "sin Region". Significa que el *espacio de nombres* es global mientras el plano de control tiene su casa en algún lado — casi siempre `us-east-1`. Este es un riesgo de producción de primer orden y un distractor recurrente del examen.

| Servicio | Alcance del recurso | Dónde debés llamar a la API / ubicar la dependencia |
|---|---|---|
| IAM (usuarios, roles, políticas) | Global (por partición) | `iam.amazonaws.com` → `us-east-1` |
| AWS Organizations | Global | `us-east-1` |
| Amazon Route 53 (hosted zones, registros) | Global | `us-east-1` |
| Amazon CloudFront (distribuciones) | Global | `us-east-1` |
| AWS WAF para CloudFront | Global | `--scope CLOUDFRONT --region us-east-1` |
| AWS Shield Advanced | Global | `us-east-1` |
| Certificado ACM **para CloudFront** | Debe emitirse en | **`us-east-1`, siempre** |
| Certificado ACM **para un ALB/NLB/API Gateway** | Debe emitirse en | **La misma Region que el load balancer** |
| **Nombres** de bucket de Amazon S3 | Únicos globalmente dentro de una partición | Los *datos* del bucket son regionales |
| AWS Billing / Cost Explorer | Global | `us-east-1` |
| AWS STS | Tiene endpoints global y regionales | **Preferí los regionales** — ver abajo |

**La lección de STS.** El endpoint global heredado `sts.amazonaws.com` se sirve desde `us-east-1`. Si tu carga de trabajo en `ap-southeast-2` lo llama para asumir un rol, creaste una dependencia síncrona sobre una Region en la que no corrés, agregaste ~200 ms a cada refresco de credenciales y acoplaste tu disponibilidad a un lugar que nunca elegiste. Usá endpoints regionales de STS:

```bash
export AWS_STS_REGIONAL_ENDPOINTS=regional
# or in ~/.aws/config
#   sts_regional_endpoints = regional
```
Las versiones modernas de los SDK usan `regional` por defecto, pero los SDK pineados/legados y las imágenes de contenedor viejas frecuentemente no. Auditar esto es una victoria de resiliencia barata y de alto valor.

---

## 4. Global vs Regional vs Zonal: clasificá cada recurso que tenés

Antes de poder razonar sobre el radio de impacto, tenés que conocer el alcance de cada recurso. El mal escalado de alcance es de donde vienen los incidentes de "creíamos que teníamos alta disponibilidad".

| Alcance | Significado | Ejemplos | Impacto del fallo |
|---|---|---|---|
| **Zonal** | Existe en exactamente una AZ. No se puede mover, solo recrear. | Instancia EC2, **volumen EBS**, mount target de EFS, instancia RDS (un nodo único), subnet, NAT Gateway, nodo de ElastiCache | Evento de AZ → recurso no disponible. Debe ser replicado por *vos* o por un servicio Multi-AZ |
| **Regional** | Abarca las AZs de una Region; AWS maneja la redundancia intra-Region | Bucket S3 (en un bucket Regional), tabla DynamoDB, cola SQS, función Lambda, **plano de control** de ECS/EKS, ALB/NLB (como servicio; los nodos son zonales), clúster Aurora, clave KMS | Evento de AZ → normalmente transparente. Evento de Region → no disponible |
| **Global** | Un espacio de nombres a lo largo de toda la partición | IAM, hosted zones de Route 53, distribuciones de CloudFront, Organizations, WAF (scope CloudFront) | Máxima disponibilidad; pero el *plano de control* tiene una Region de origen (§3.1) |

**El recurso zonal más trascendente es EBS.** Un volumen EBS vive en una AZ y solo puede adjuntarse a una instancia en esa misma AZ. Todo incidente de "nuestra carga de trabajo con estado no volvió en la otra AZ" se remonta a esto. Las respuestas correctas son: snapshot a S3 (Regional) y restaurar en la nueva AZ, usar EFS o FSx (Regional, mount targets multi-AZ), usar un servicio de base de datos Regional, o correr replicación a nivel de aplicación.

### 4.1 Radio de impacto, formalmente

| Alcance del fallo | Qué se ve afectado | Mitigación | Multiplicador de costo típico |
|---|---|---|---|
| Instancia / host único | Un nodo | Auto Scaling group, health checks, capacidad N+1 | ~1.1× |
| Una sola **Availability Zone** | Todo lo zonal en esa AZ | Multi-AZ: ≥3 AZs, ASG a través de subnets, RDS Multi-AZ, ELB cross-zone | ~1.3–1.5× |
| Una sola **Region** | Todo en la Region | Multi-Region: replicar datos + pre-aprovisionar cómputo + direccionamiento global de tráfico | ~1.8–2.2× |
| Despliegue malo / configuración mala | Todas las Regions simultáneamente | **Esto no es un problema de topología.** Despliegues escalonados, arquitectura celular, canaries, rollback automático | Costo de proceso |
| Compromiso de cuenta | Todo en la cuenta | Multi-cuenta (Organizations), SCPs, Regions sin uso deshabilitadas | Costo de proceso |

Esa cuarta fila es la que los arquitectos subestiman. Multi-Region te protege del mal día de AWS; no hace nada contra *tu* mal despliegue, que estadísticamente es mucho más probable. Gastar 2× en redundancia de Region mientras empujás un despliegue global sin canary es optimizar el riesgo equivocado.

---

## 5. El modelo de costos de tu topología

Las decisiones de topología aparecen en la factura como transferencia de datos. Estos son precios de lista en la partición `aws` al momento de escribir — **verificá contra las páginas de precios actuales antes de citarlos**, cambian.

| Ruta del tráfico | Cargo típico | Notas |
|---|---|---|
| Dentro de una AZ, usando direcciones IPv4 **privadas** | **Gratis** | La razón por la que los servicios charlatanes de una sola AZ son baratos |
| Dentro de una AZ, usando IPv4 **públicas** o Elastic IPs | Se cobra como cross-AZ | Silenciosamente caro; una mala configuración clásica |
| **Entre AZs** en la misma Region | ~$0.01/GB **en cada dirección** (≈$0.02/GB ida y vuelta) | El costo oculto dominante en las mallas de microservicios |
| Entre Regions | ~$0.02/GB y más, varía según la Region de origen | Replicación entre Regions, global tables, Aurora Global DB |
| Salida a internet | Escalonado desde ~$0.09/GB, con una franquicia mensual gratuita | Servir desde CloudFront normalmente sale más barato que desde un origen |
| Entrada a AWS desde internet | **Gratis** | El ingreso no se factura |
| Vía un **Gateway VPC Endpoint** (S3, DynamoDB) | **Gratis**, sin cargo por hora | Creá siempre estos |
| Vía un **Interface VPC Endpoint** (PrivateLink) | Cargo horario por ENI por AZ + por GB | Más barato que NAT para volúmenes altos, pero no gratis |
| Vía un **NAT Gateway** | Por hora por NAT + ~$0.045/GB procesado | Se apila *encima* del cargo de egress |

Tres consecuencias arquitectónicas:

1. **¿Un NAT Gateway por AZ, o uno compartido?** Un NAT compartido es más barato en la línea horaria pero convierte el egress de cada otra AZ en un flujo cross-AZ *y* hace que la AZ del NAT sea un punto único de fallo para todo el tráfico saliente. El valor por defecto correcto en producción es **un NAT Gateway por AZ**, con cada subnet privada enrutando al NAT de su propia AZ. La plantilla de §6.1 hace exactamente esto.
2. **Los gateway endpoints para S3 y DynamoDB son gratis y eliminan por completo los cargos de procesamiento de NAT para ese tráfico.** No crearlos es pura pérdida.
3. **La charla cross-AZ es el impuesto a las mallas de servicios ingenuas.** Un servicio que hace fan-out a tres réplicas, cada una en una AZ distinta, paga cross-AZ en dos de las tres llamadas. Para esto está el enrutamiento consciente de la topología (§6.3).

---

## 6. Infraestructura como código — manifiestos completos, sin abreviar

### 6.1 CloudFormation: una VPC de tres AZs anclada a **IDs** de AZ

El patrón por defecto `!Select [0, !GetAZs '']` elige el primer nombre de AZ *de tu cuenta*. Eso está bien para una sola cuenta y está mal en el momento en que una segunda cuenta tiene que co-ubicarse con vos. Esta plantilla toma **nombres** de AZ como parámetros que resolvés a partir de los AZ IDs (ver el comando resolvedor inmediatamente después de la plantilla), y registra los AZ IDs previstos en tags para que el mapeo sea auditable.

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >
  Production three-AZ VPC. Public and private subnets in three Availability Zones,
  one NAT Gateway per AZ (no cross-AZ egress, no shared failure domain), a free
  S3 gateway endpoint, and AZ-ID tagging so placement is auditable across accounts.

Parameters:
  ProjectName:
    Type: String
    Default: platform
    Description: Prefix used in Name tags and exported output names.
  VpcCidr:
    Type: String
    Default: 10.42.0.0/16
    AllowedPattern: '^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$'
  AvailabilityZoneA:
    Type: AWS::EC2::AvailabilityZone::Name
    Description: AZ NAME that maps to the AZ ID given in AzIdA.
  AvailabilityZoneB:
    Type: AWS::EC2::AvailabilityZone::Name
  AvailabilityZoneC:
    Type: AWS::EC2::AvailabilityZone::Name
  AzIdA:
    Type: String
    Description: Physical AZ ID, e.g. use1-az1. Recorded in tags for cross-account audit.
  AzIdB:
    Type: String
  AzIdC:
    Type: String

Resources:

  # ---------------------------------------------------------------- VPC core
  Vpc:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: !Ref VpcCidr
      EnableDnsSupport: true
      EnableDnsHostnames: true
      InstanceTenancy: default
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-vpc'

  InternetGateway:
    Type: AWS::EC2::InternetGateway
    Properties:
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-igw'

  InternetGatewayAttachment:
    Type: AWS::EC2::VPCGatewayAttachment
    Properties:
      VpcId: !Ref Vpc
      InternetGatewayId: !Ref InternetGateway

  # ------------------------------------------------------------ Public subnets
  PublicSubnetA:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Ref AvailabilityZoneA
      CidrBlock: !Select [0, !Cidr [!Ref VpcCidr, 16, 12]]   # 10.42.0.0/20
      MapPublicIpOnLaunch: false
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-public-${AzIdA}'
        - Key: az-id
          Value: !Ref AzIdA
        - Key: kubernetes.io/role/elb
          Value: '1'

  PublicSubnetB:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Ref AvailabilityZoneB
      CidrBlock: !Select [1, !Cidr [!Ref VpcCidr, 16, 12]]   # 10.42.16.0/20
      MapPublicIpOnLaunch: false
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-public-${AzIdB}'
        - Key: az-id
          Value: !Ref AzIdB
        - Key: kubernetes.io/role/elb
          Value: '1'

  PublicSubnetC:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Ref AvailabilityZoneC
      CidrBlock: !Select [2, !Cidr [!Ref VpcCidr, 16, 12]]   # 10.42.32.0/20
      MapPublicIpOnLaunch: false
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-public-${AzIdC}'
        - Key: az-id
          Value: !Ref AzIdC
        - Key: kubernetes.io/role/elb
          Value: '1'

  # ----------------------------------------------------------- Private subnets
  PrivateSubnetA:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Ref AvailabilityZoneA
      CidrBlock: !Select [8, !Cidr [!Ref VpcCidr, 16, 12]]   # 10.42.128.0/20
      MapPublicIpOnLaunch: false
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-private-${AzIdA}'
        - Key: az-id
          Value: !Ref AzIdA
        - Key: kubernetes.io/role/internal-elb
          Value: '1'

  PrivateSubnetB:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Ref AvailabilityZoneB
      CidrBlock: !Select [9, !Cidr [!Ref VpcCidr, 16, 12]]   # 10.42.144.0/20
      MapPublicIpOnLaunch: false
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-private-${AzIdB}'
        - Key: az-id
          Value: !Ref AzIdB
        - Key: kubernetes.io/role/internal-elb
          Value: '1'

  PrivateSubnetC:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Ref AvailabilityZoneC
      CidrBlock: !Select [10, !Cidr [!Ref VpcCidr, 16, 12]]  # 10.42.160.0/20
      MapPublicIpOnLaunch: false
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-private-${AzIdC}'
        - Key: az-id
          Value: !Ref AzIdC
        - Key: kubernetes.io/role/internal-elb
          Value: '1'

  # ------------------------------------------------- One NAT Gateway per AZ
  # Rationale: a single shared NAT would (a) make its AZ a single point of failure
  # for ALL outbound traffic and (b) turn every other AZ's egress into a billed
  # cross-AZ flow. Three NATs cost more per hour and less per incident.
  NatEipA:
    Type: AWS::EC2::EIP
    DependsOn: InternetGatewayAttachment
    Properties:
      Domain: vpc
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-nat-eip-${AzIdA}'

  NatEipB:
    Type: AWS::EC2::EIP
    DependsOn: InternetGatewayAttachment
    Properties:
      Domain: vpc
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-nat-eip-${AzIdB}'

  NatEipC:
    Type: AWS::EC2::EIP
    DependsOn: InternetGatewayAttachment
    Properties:
      Domain: vpc
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-nat-eip-${AzIdC}'

  NatGatewayA:
    Type: AWS::EC2::NatGateway
    Properties:
      AllocationId: !GetAtt NatEipA.AllocationId
      SubnetId: !Ref PublicSubnetA
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-nat-${AzIdA}'

  NatGatewayB:
    Type: AWS::EC2::NatGateway
    Properties:
      AllocationId: !GetAtt NatEipB.AllocationId
      SubnetId: !Ref PublicSubnetB
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-nat-${AzIdB}'

  NatGatewayC:
    Type: AWS::EC2::NatGateway
    Properties:
      AllocationId: !GetAtt NatEipC.AllocationId
      SubnetId: !Ref PublicSubnetC
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-nat-${AzIdC}'

  # -------------------------------------------------------------- Route tables
  PublicRouteTable:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-rtb-public'

  PublicDefaultRoute:
    Type: AWS::EC2::Route
    DependsOn: InternetGatewayAttachment
    Properties:
      RouteTableId: !Ref PublicRouteTable
      DestinationCidrBlock: 0.0.0.0/0
      GatewayId: !Ref InternetGateway

  PublicSubnetARouteAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PublicSubnetA
      RouteTableId: !Ref PublicRouteTable

  PublicSubnetBRouteAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PublicSubnetB
      RouteTableId: !Ref PublicRouteTable

  PublicSubnetCRouteAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PublicSubnetC
      RouteTableId: !Ref PublicRouteTable

  # One private route table PER AZ, each pointing at that AZ's own NAT Gateway.
  PrivateRouteTableA:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-rtb-private-${AzIdA}'
        - Key: az-id
          Value: !Ref AzIdA

  PrivateDefaultRouteA:
    Type: AWS::EC2::Route
    Properties:
      RouteTableId: !Ref PrivateRouteTableA
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId: !Ref NatGatewayA

  PrivateSubnetARouteAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PrivateSubnetA
      RouteTableId: !Ref PrivateRouteTableA

  PrivateRouteTableB:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-rtb-private-${AzIdB}'
        - Key: az-id
          Value: !Ref AzIdB

  PrivateDefaultRouteB:
    Type: AWS::EC2::Route
    Properties:
      RouteTableId: !Ref PrivateRouteTableB
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId: !Ref NatGatewayB

  PrivateSubnetBRouteAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PrivateSubnetB
      RouteTableId: !Ref PrivateRouteTableB

  PrivateRouteTableC:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-rtb-private-${AzIdC}'
        - Key: az-id
          Value: !Ref AzIdC

  PrivateDefaultRouteC:
    Type: AWS::EC2::Route
    Properties:
      RouteTableId: !Ref PrivateRouteTableC
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId: !Ref NatGatewayC

  PrivateSubnetCRouteAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PrivateSubnetC
      RouteTableId: !Ref PrivateRouteTableC

  # ---------------------------------------- Free gateway endpoints (S3, DynamoDB)
  # Keeps S3/DynamoDB traffic off the NAT Gateways: no per-GB processing charge,
  # no internet path, and it works during an internet-facing impairment.
  S3GatewayEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref Vpc
      ServiceName: !Sub 'com.amazonaws.${AWS::Region}.s3'
      VpcEndpointType: Gateway
      RouteTableIds:
        - !Ref PrivateRouteTableA
        - !Ref PrivateRouteTableB
        - !Ref PrivateRouteTableC

  DynamoDbGatewayEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref Vpc
      ServiceName: !Sub 'com.amazonaws.${AWS::Region}.dynamodb'
      VpcEndpointType: Gateway
      RouteTableIds:
        - !Ref PrivateRouteTableA
        - !Ref PrivateRouteTableB
        - !Ref PrivateRouteTableC

  # --------------------------------------------------- VPC Flow Logs (az-id v4+)
  FlowLogsGroup:
    Type: AWS::Logs::LogGroup
    Properties:
      LogGroupName: !Sub '/aws/vpc/${ProjectName}/flowlogs'
      RetentionInDays: 30

  FlowLogsRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: vpc-flow-logs.amazonaws.com
            Action: sts:AssumeRole
      Policies:
        - PolicyName: WriteFlowLogs
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - logs:CreateLogStream
                  - logs:PutLogEvents
                  - logs:DescribeLogStreams
                Resource: !GetAtt FlowLogsGroup.Arn

  VpcFlowLog:
    Type: AWS::EC2::FlowLog
    Properties:
      ResourceType: VPC
      ResourceId: !Ref Vpc
      TrafficType: ALL
      LogDestinationType: cloud-watch-logs
      LogGroupName: !Ref FlowLogsGroup
      DeliverLogsPermissionArn: !GetAtt FlowLogsRole.Arn
      MaxAggregationInterval: 60
      # az-id and region require flow log format version 4 or later. Without them
      # you cannot attribute cross-AZ data transfer charges to a physical zone.
      LogFormat: >-
        ${version} ${account-id} ${vpc-id} ${subnet-id} ${instance-id}
        ${interface-id} ${az-id} ${region} ${srcaddr} ${dstaddr}
        ${srcport} ${dstport} ${protocol} ${packets} ${bytes}
        ${start} ${end} ${action} ${log-status} ${flow-direction}
        ${pkt-src-aws-service} ${pkt-dst-aws-service} ${traffic-path}

Outputs:
  VpcId:
    Value: !Ref Vpc
    Export:
      Name: !Sub '${ProjectName}-vpc-id'
  PublicSubnetIds:
    Value: !Join [',', [!Ref PublicSubnetA, !Ref PublicSubnetB, !Ref PublicSubnetC]]
    Export:
      Name: !Sub '${ProjectName}-public-subnet-ids'
  PrivateSubnetIds:
    Value: !Join [',', [!Ref PrivateSubnetA, !Ref PrivateSubnetB, !Ref PrivateSubnetC]]
    Export:
      Name: !Sub '${ProjectName}-private-subnet-ids'
  AzIdMapping:
    Description: Physical AZ IDs backing this VPC, in subnet order A,B,C.
    Value: !Join [',', [!Ref AzIdA, !Ref AzIdB, !Ref AzIdC]]
    Export:
      Name: !Sub '${ProjectName}-az-ids'
```

**Resolver los AZ IDs a los nombres de AZ de esta cuenta, y luego desplegar:**

```bash
$ REGION=us-east-1
$ aws ec2 describe-availability-zones \
    --region "$REGION" \
    --filters Name=zone-type,Values=availability-zone \
    --query 'AvailabilityZones[?ZoneId==`use1-az1`||ZoneId==`use1-az2`||ZoneId==`use1-az4`].{Name:ZoneName,Id:ZoneId}' \
    --output table
-----------------------------
|DescribeAvailabilityZones  |
+-----------+---------------+
|    Id     |     Name      |
+-----------+---------------+
|  use1-az4 |  us-east-1a   |
|  use1-az1 |  us-east-1c   |
|  use1-az2 |  us-east-1d   |
+-----------+---------------+
```

Fijate en lo que acaba de pasar: en esta cuenta, `use1-az1` **no** es `us-east-1a`. Cualquier otra cuenta muy probablemente discrepe.

```bash
$ aws cloudformation deploy \
    --region us-east-1 \
    --stack-name platform-network \
    --template-file vpc-3az.yaml \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides \
        ProjectName=platform \
        VpcCidr=10.42.0.0/16 \
        AvailabilityZoneA=us-east-1a AzIdA=use1-az4 \
        AvailabilityZoneB=us-east-1c AzIdB=use1-az1 \
        AvailabilityZoneC=us-east-1d AzIdC=use1-az2

Waiting for changeset to be created..
Waiting for stack create/update to complete
Successfully created/updated stack - platform-network
```

### 6.2 Terraform: dos Regions detrás de un único Global Accelerator

Este es el patrón multi-Region canónico de **estabilidad estática**: ambas Regions están siempre corriendo, ambas están sanas, y el failover es un cambio del *plano de datos* (un traffic dial o una retirada automática por health check), nunca una llamada de API `Create*`.

```hcl
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

# ---------------------------------------------------------------- Providers
# Global Accelerator's control plane lives in us-west-2. This is a hard API
# requirement, exactly like CloudFront/WAF-CLOUDFRONT living in us-east-1.
provider "aws" {
  alias  = "global"
  region = "us-west-2"
}

provider "aws" {
  alias  = "primary"
  region = var.primary_region
}

provider "aws" {
  alias  = "secondary"
  region = var.secondary_region
}

variable "primary_region" {
  type    = string
  default = "us-east-1"
}

variable "secondary_region" {
  type    = string
  default = "eu-west-1"
}

variable "project" {
  type    = string
  default = "platform"
}

# ------------------------------------------------- Discover partition + AZ IDs
data "aws_partition" "current" {}

data "aws_availability_zones" "primary" {
  provider = aws.primary
  state    = "available"
  filter {
    name   = "zone-type"
    values = ["availability-zone"] # exclude Local Zones and Wavelength Zones
  }
}

data "aws_availability_zones" "secondary" {
  provider = aws.secondary
  state    = "available"
  filter {
    name   = "zone-type"
    values = ["availability-zone"]
  }
}

# A hard failure is better than silently building a 2-AZ "highly available" stack.
locals {
  primary_azs   = slice(data.aws_availability_zones.primary.names, 0, 3)
  secondary_azs = slice(data.aws_availability_zones.secondary.names, 0, 3)
}

resource "terraform_data" "az_count_guard" {
  lifecycle {
    precondition {
      condition = (
        length(data.aws_availability_zones.primary.names) >= 3 &&
        length(data.aws_availability_zones.secondary.names) >= 3
      )
      error_message = "Both Regions must expose at least 3 Availability Zones."
    }
  }
}

# ------------------------------------------------------ Per-Region VPC + ALB
module "network_primary" {
  source    = "./modules/vpc-3az"
  providers = { aws = aws.primary }

  name               = "${var.project}-${var.primary_region}"
  cidr               = "10.42.0.0/16"
  availability_zones = local.primary_azs
}

module "network_secondary" {
  source    = "./modules/vpc-3az"
  providers = { aws = aws.secondary }

  name               = "${var.project}-${var.secondary_region}"
  cidr               = "10.43.0.0/16"
  availability_zones = local.secondary_azs
}

resource "aws_lb" "primary" {
  provider = aws.primary

  name                             = "${var.project}-primary"
  load_balancer_type               = "application"
  internal                         = false
  subnets                          = module.network_primary.public_subnet_ids
  security_groups                  = [module.network_primary.alb_security_group_id]
  enable_cross_zone_load_balancing = true
  enable_deletion_protection       = true
  idle_timeout                     = 60
  drop_invalid_header_fields       = true

  tags = {
    Project = var.project
    Role    = "ingress"
  }
}

resource "aws_lb" "secondary" {
  provider = aws.secondary

  name                             = "${var.project}-secondary"
  load_balancer_type               = "application"
  internal                         = false
  subnets                          = module.network_secondary.public_subnet_ids
  security_groups                  = [module.network_secondary.alb_security_group_id]
  enable_cross_zone_load_balancing = true
  enable_deletion_protection       = true
  idle_timeout                     = 60
  drop_invalid_header_fields       = true

  tags = {
    Project = var.project
    Role    = "ingress"
  }
}

# -------------------------------------------------------- Global Accelerator
resource "aws_globalaccelerator_accelerator" "this" {
  provider = aws.global

  name            = "${var.project}-gax"
  ip_address_type = "DUAL_STACK"
  enabled         = true

  attributes {
    flow_logs_enabled   = true
    flow_logs_s3_bucket = aws_s3_bucket.gax_flow_logs.bucket
    flow_logs_s3_prefix = "gax/"
  }

  tags = {
    Project = var.project
  }
}

resource "aws_s3_bucket" "gax_flow_logs" {
  provider = aws.global
  bucket   = "${var.project}-gax-flow-logs-${data.aws_caller_identity.global.account_id}"
}

data "aws_caller_identity" "global" {
  provider = aws.global
}

resource "aws_globalaccelerator_listener" "https" {
  provider = aws.global

  accelerator_arn = aws_globalaccelerator_accelerator.this.id
  protocol        = "TCP"
  # SOURCE_IP gives client-IP affinity — required for stateful protocols.
  # Use NONE for stateless HTTP APIs to get an even spread.
  client_affinity = "NONE"

  port_range {
    from_port = 443
    to_port   = 443
  }
}

resource "aws_globalaccelerator_endpoint_group" "primary" {
  provider = aws.global

  listener_arn                  = aws_globalaccelerator_listener.https.id
  endpoint_group_region         = var.primary_region
  traffic_dial_percentage       = 100
  health_check_protocol         = "HTTPS"
  health_check_path             = "/healthz"
  health_check_port             = 443
  health_check_interval_seconds = 10
  threshold_count               = 3

  endpoint_configuration {
    endpoint_id                    = aws_lb.primary.arn
    weight                         = 128
    client_ip_preservation_enabled = true
  }
}

resource "aws_globalaccelerator_endpoint_group" "secondary" {
  provider = aws.global

  listener_arn                  = aws_globalaccelerator_listener.https.id
  endpoint_group_region         = var.secondary_region
  traffic_dial_percentage       = 100
  health_check_protocol         = "HTTPS"
  health_check_path             = "/healthz"
  health_check_port             = 443
  health_check_interval_seconds = 10
  threshold_count               = 3

  endpoint_configuration {
    endpoint_id                    = aws_lb.secondary.arn
    weight                         = 128
    client_ip_preservation_enabled = true
  }
}

# -------------------------------------------------------------------- Outputs
output "static_anycast_ips" {
  description = "Stable ingress IPs. Publish these to customers for allowlisting; they survive Region failover."
  value       = aws_globalaccelerator_accelerator.this.ip_sets[0].ip_addresses
}

output "accelerator_dns_name" {
  value = aws_globalaccelerator_accelerator.this.dns_name
}

output "primary_az_ids" {
  value = data.aws_availability_zones.primary.zone_ids
}

output "secondary_az_ids" {
  value = data.aws_availability_zones.secondary.zone_ids
}
```

```bash
$ terraform apply -auto-approve
...
Apply complete! Resources: 47 added, 0 changed, 0 destroyed.

Outputs:

accelerator_dns_name = "a1b2c3d4e5f6a7b8.awsglobalaccelerator.com"
primary_az_ids = tolist([
  "use1-az1",
  "use1-az2",
  "use1-az4",
  "use1-az5",
  "use1-az6",
])
secondary_az_ids = tolist([
  "euw1-az1",
  "euw1-az2",
  "euw1-az3",
])
static_anycast_ips = tolist([
  "75.2.83.117",
  "99.83.190.42",
])
```

**Hacer failover es ahora una sola llamada del plano de datos — sin creación de recursos, sin propagación de DNS:**

```bash
$ aws globalaccelerator update-endpoint-group \
    --region us-west-2 \
    --endpoint-group-arn "arn:aws:globalaccelerator::123456789012:accelerator/9c1b0a3e-.../listener/1f2e3d4c/endpoint-group/5a6b7c8d" \
    --traffic-dial-percentage 0 \
    --query 'EndpointGroup.{Region:EndpointGroupRegion,Dial:TrafficDialPercentage}'
{
    "Region": "us-east-1",
    "Dial": 0.0
}
```

### 6.3 Kubernetes sobre EKS: hacer explícita la topología de zonas

El plano de control de un clúster EKS es Regional y multi-AZ por diseño. **Los nodos y el almacenamiento no lo son** — esa parte es tuya. Estos cuatro manifiestos son el conjunto mínimo que hace que un Deployment sea genuinamente tolerante a fallos de AZ.

```yaml
---
# 1. StorageClass — EBS is ZONAL. WaitForFirstConsumer is not optional.
#    With Immediate binding, the volume is provisioned in a zone chosen before
#    the scheduler knows where the Pod can run, and you get the classic
#    "volume node affinity conflict" Pending loop.
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3-zonal
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Delete
parameters:
  type: gp3
  iops: "3000"
  throughput: "125"
  encrypted: "true"
  kmsKeyId: arn:aws:kms:us-east-1:123456789012:key/8f1c2d3e-4a5b-6c7d-8e9f-0a1b2c3d4e5f
---
# 2. Stateless Deployment — spread hard across zones, softly across nodes.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout-api
  namespace: commerce
  labels:
    app.kubernetes.io/name: checkout-api
spec:
  replicas: 6
  revisionHistoryLimit: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout-api
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
      maxSurge: 2
  template:
    metadata:
      labels:
        app.kubernetes.io/name: checkout-api
    spec:
      terminationGracePeriodSeconds: 45
      topologySpreadConstraints:
        # Hard constraint: never let one zone hold 2 more replicas than another.
        # DoNotSchedule means we would rather run degraded than run concentrated.
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: checkout-api
          matchLabelKeys:
            - pod-template-hash
        # Soft constraint: also prefer distinct nodes inside each zone, so a
        # single EC2 instance failure does not take a whole zone's share.
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: checkout-api
      containers:
        - name: api
          image: 123456789012.dkr.ecr.us-east-1.amazonaws.com/checkout-api:1.14.2
          ports:
            - name: http
              containerPort: 8080
          env:
            # Expose the physical zone to the app for logging and metrics.
            - name: AWS_STS_REGIONAL_ENDPOINTS
              value: regional
            - name: NODE_ZONE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.annotations['topology.kubernetes.io/zone']
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              memory: 512Mi
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            periodSeconds: 5
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 10
            failureThreshold: 5
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "sleep 15"]
---
# 3. PodDisruptionBudget — survives a full-zone drain during an AZ evacuation.
#    With 6 replicas over 3 zones, losing one zone removes 2. minAvailable: 4
#    is exactly the floor that permits that eviction and blocks a second one.
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: checkout-api
  namespace: commerce
spec:
  minAvailable: 4
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout-api
---
# 4. Service with topology-aware routing — keeps traffic inside the zone when
#    there is enough local capacity, cutting cross-AZ data transfer charges.
#    It automatically falls back to cross-zone routing when a zone is unhealthy.
apiVersion: v1
kind: Service
metadata:
  name: checkout-api
  namespace: commerce
  annotations:
    service.kubernetes.io/topology-mode: Auto
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: checkout-api
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
  trafficDistribution: PreferClose
```

```bash
$ kubectl get pods -n commerce -l app.kubernetes.io/name=checkout-api \
    -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeName,ZONE:.metadata.annotations.topology\.kubernetes\.io/zone'
NAME                            NODE                          ZONE
checkout-api-7d9f4c8b6d-2xk9p   ip-10-42-131-14.ec2.internal  us-east-1a
checkout-api-7d9f4c8b6d-4mq7t   ip-10-42-149-88.ec2.internal  us-east-1c
checkout-api-7d9f4c8b6d-8vn2j   ip-10-42-166-31.ec2.internal  us-east-1d
checkout-api-7d9f4c8b6d-h6rl4   ip-10-42-132-207.ec2.internal us-east-1a
checkout-api-7d9f4c8b6d-p3wc9   ip-10-42-151-73.ec2.internal  us-east-1c
checkout-api-7d9f4c8b6d-zt8bf   ip-10-42-168-19.ec2.internal  us-east-1d
```

Dos por zona, seis nodos, sin concentración. Ahora mapeá los *nombres* de vuelta a los *IDs*, que es lo que AWS va a usar cuando te diga que una zona está degradada:

```bash
$ kubectl get nodes -L topology.kubernetes.io/zone,topology.k8s.aws/zone-id
NAME                            STATUS   ROLES    AGE   VERSION   ZONE         ZONE-ID
ip-10-42-131-14.ec2.internal    Ready    <none>   6d    v1.30.4   us-east-1a   use1-az4
ip-10-42-132-207.ec2.internal   Ready    <none>   6d    v1.30.4   us-east-1a   use1-az4
ip-10-42-149-88.ec2.internal    Ready    <none>   6d    v1.30.4   us-east-1c   use1-az1
ip-10-42-151-73.ec2.internal    Ready    <none>   6d    v1.30.4   us-east-1c   use1-az1
ip-10-42-166-31.ec2.internal    Ready    <none>   6d    v1.30.4   us-east-1d   use1-az2
ip-10-42-168-19.ec2.internal    Ready    <none>   6d    v1.30.4   us-east-1d   use1-az2
```

### 6.4 Route 53: enrutamiento basado en latencia con failover verificado por health checks

DNS es el otro mecanismo de direccionamiento global. Este change batch crea registros de latencia en dos Regions, cada uno protegido por un health check, para que los resolvers obtengan la Region *sana* más cercana.

```bash
$ cat > /tmp/health-checks.sh <<'EOF'
set -euo pipefail
for pair in "us-east-1:api-use1.example.com" "eu-west-1:api-euw1.example.com"; do
  region="${pair%%:*}"; fqdn="${pair##*:}"
  aws route53 create-health-check \
    --caller-reference "hc-${region}-$(date +%s)" \
    --health-check-config "{
        \"Type\": \"HTTPS\",
        \"FullyQualifiedDomainName\": \"${fqdn}\",
        \"Port\": 443,
        \"ResourcePath\": \"/healthz\",
        \"RequestInterval\": 10,
        \"FailureThreshold\": 2,
        \"MeasureLatency\": true,
        \"EnableSNI\": true
      }" \
    --query 'HealthCheck.{Id:Id,Target:HealthCheckConfig.FullyQualifiedDomainName}' \
    --output text
done
EOF
$ bash /tmp/health-checks.sh
9f2c1a44-3b7e-4e1a-9c8d-2a5f6b7c8d90    api-use1.example.com
c7d3e2b5-8f1a-4d6c-b3e9-1f4a5c6d7e80    api-euw1.example.com
```

```json
{
  "Comment": "Latency-based routing with per-Region health checks for api.example.com",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "api.example.com.",
        "Type": "A",
        "SetIdentifier": "us-east-1-primary",
        "Region": "us-east-1",
        "HealthCheckId": "9f2c1a44-3b7e-4e1a-9c8d-2a5f6b7c8d90",
        "AliasTarget": {
          "HostedZoneId": "Z35SXDOTRQ7X7K",
          "DNSName": "dualstack.platform-primary-1234567890.us-east-1.elb.amazonaws.com.",
          "EvaluateTargetHealth": true
        }
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "api.example.com.",
        "Type": "A",
        "SetIdentifier": "eu-west-1-secondary",
        "Region": "eu-west-1",
        "HealthCheckId": "c7d3e2b5-8f1a-4d6c-b3e9-1f4a5c6d7e80",
        "AliasTarget": {
          "HostedZoneId": "Z32O12XQLNTSW2",
          "DNSName": "dualstack.platform-secondary-0987654321.eu-west-1.elb.amazonaws.com.",
          "EvaluateTargetHealth": true
        }
      }
    }
  ]
}
```

```bash
$ aws route53 change-resource-record-sets \
    --hosted-zone-id Z0123456789ABCDEFGHIJ \
    --change-batch file:///tmp/latency-records.json \
    --query 'ChangeInfo.{Id:Id,Status:Status}'
{
    "Id": "/change/C0987654321ZYXWVUTSRQ",
    "Status": "PENDING"
}

$ aws route53 wait resource-record-sets-changed --id /change/C0987654321ZYXWVUTSRQ && echo INSYNC
INSYNC
```

**La compensación frente a §6.2:** el enrutamiento por latencia de Route 53 es barato, funciona con cualquier protocolo y te da control geográfico — pero el failover está acotado por los TTLs de DNS y por los resolvers de cliente que los ignoran. Global Accelerator cuesta más (fijo por hora + por GB) pero hace failover sin ninguna intervención de DNS del lado del cliente. Elegí según la carga de trabajo; muchos stacks de producción usan ambos — Route 53 para la capa web de cara al humano, Global Accelerator para la capa de dispositivos/API.

---

## 7. Trabajar la infraestructura desde la CLI

### 7.1 La base de datos gratuita de disponibilidad de servicios que nadie usa

AWS publica todo el catálogo de infraestructura global como **parámetros públicos de SSM Parameter Store**. Sin permisos especiales más allá de `ssm:GetParametersByPath`, sin scrapear una página web, y es legible por máquina — lo que la vuelve la cosa correcta para poner en un gate de CI.

```bash
# Every Region code AWS publishes
$ aws ssm get-parameters-by-path \
    --path /aws/service/global-infrastructure/regions \
    --query 'Parameters[].Value' --output text | tr '\t' '\n' | sort | head -20
af-south-1
ap-east-1
ap-northeast-1
ap-northeast-2
ap-northeast-3
ap-south-1
ap-south-2
ap-southeast-1
ap-southeast-2
ap-southeast-3
ap-southeast-4
ca-central-1
ca-west-1
eu-central-1
eu-central-2
eu-north-1
eu-south-1
eu-south-2
eu-west-1
eu-west-2

# The human-readable name of a Region
$ aws ssm get-parameter \
    --name /aws/service/global-infrastructure/regions/eu-central-1/longName \
    --query 'Parameter.Value' --output text
Europe (Frankfurt)

# THE question: is this service in this Region? Gate your deployments on it.
$ aws ssm get-parameters-by-path \
    --path /aws/service/global-infrastructure/services/bedrock/regions \
    --query 'Parameters[].Value' --output text | tr '\t' '\n' | sort
ap-northeast-1
ap-south-1
ap-southeast-1
ap-southeast-2
ca-central-1
eu-central-1
eu-west-1
eu-west-2
eu-west-3
sa-east-1
us-east-1
us-east-2
us-west-2

# Inverted: everything available in a candidate Region
$ aws ssm get-parameters-by-path \
    --path /aws/service/global-infrastructure/regions/il-central-1/services \
    --query 'Parameters[].Value' --output text | tr '\t' '\n' | wc -l
147
```

Un chequeo de CI de cinco líneas que habría evitado varias de mis peores reuniones de selección de Region:

```bash
$ cat > check-region-services.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
REGION="$1"; shift
missing=()
for svc in "$@"; do
  if ! aws ssm get-parameter \
        --name "/aws/service/global-infrastructure/regions/${REGION}/services/${svc}" \
        >/dev/null 2>&1; then
    missing+=("$svc")
  fi
done
if (( ${#missing[@]} )); then
  printf 'FAIL: %s does not offer: %s\n' "$REGION" "${missing[*]}" >&2
  exit 1
fi
printf 'OK: %s offers all %d required services\n' "$REGION" "$#"
EOF
$ chmod +x check-region-services.sh
$ ./check-region-services.sh eu-south-2 lambda dynamodb eks kms secretsmanager
OK: eu-south-2 offers all 5 required services
$ ./check-region-services.sh eu-south-2 lambda bedrock outposts
FAIL: eu-south-2 does not offer: bedrock outposts
```

### 7.2 Enumerar las Regions y su estado de opt-in

```bash
$ aws ec2 describe-regions --all-regions \
    --query 'sort_by(Regions,&RegionName)[?OptInStatus!=`opt-in-not-required`].[RegionName,OptInStatus]' \
    --output table
------------------------------------
|          DescribeRegions         |
+-----------------+----------------+
|  af-south-1     |  not-opted-in  |
|  ap-east-1      |  not-opted-in  |
|  ap-south-2     |  not-opted-in  |
|  ap-southeast-3 |  opted-in      |
|  ap-southeast-4 |  not-opted-in  |
|  ca-west-1      |  not-opted-in  |
|  eu-central-2   |  not-opted-in  |
|  eu-south-1     |  opted-in      |
|  eu-south-2     |  not-opted-in  |
|  il-central-1   |  not-opted-in  |
|  me-central-1   |  not-opted-in  |
|  me-south-1     |  not-opted-in  |
+-----------------+----------------+
```

Habilitar una (esto es asíncrono y puede tardar varios minutos):

```bash
$ aws account enable-region --region-name eu-south-2
$ aws account get-region-opt-status --region-name eu-south-2
{
    "RegionName": "eu-south-2",
    "RegionOptStatus": "ENABLING"
}

# ...a few minutes later
$ aws account get-region-opt-status --region-name eu-south-2
{
    "RegionName": "eu-south-2",
    "RegionOptStatus": "ENABLED"
}

# From the Organizations management account, for a member account:
$ aws account enable-region \
    --account-id 210987654321 \
    --region-name eu-south-2
```

### 7.3 Availability Zones, Local Zones, Wavelength Zones

```bash
$ aws ec2 describe-availability-zones --region us-west-2 \
    --query 'AvailabilityZones[].[ZoneName,ZoneId,ZoneType,OptInStatus,NetworkBorderGroup]' \
    --output table
--------------------------------------------------------------------------------------------------------
|                                       DescribeAvailabilityZones                                      |
+--------------------------+-------------------+--------------------+---------------+------------------+
|  us-west-2a              |  usw2-az1         |  availability-zone |opt-in-not-required| us-west-2     |
|  us-west-2b              |  usw2-az2         |  availability-zone |opt-in-not-required| us-west-2     |
|  us-west-2c              |  usw2-az3         |  availability-zone |opt-in-not-required| us-west-2     |
|  us-west-2d              |  usw2-az4         |  availability-zone |opt-in-not-required| us-west-2     |
+--------------------------+-------------------+--------------------+---------------+------------------+
```

Las Local Zones y las Wavelength Zones quedan ocultas salvo que pidas todas las zonas:

```bash
$ aws ec2 describe-availability-zones --region us-west-2 --all-availability-zones \
    --filters Name=zone-type,Values=local-zone \
    --query 'AvailabilityZones[].[ZoneName,ZoneId,GroupName,ParentZoneName,OptInStatus]' \
    --output table
------------------------------------------------------------------------------------------
|                               DescribeAvailabilityZones                                |
+---------------------+------------------+-------------------+--------------+------------+
|  us-west-2-lax-1a   |  usw2-lax1-az1   |  us-west-2-lax-1  |  us-west-2   |not-opted-in|
|  us-west-2-lax-1b   |  usw2-lax1-az2   |  us-west-2-lax-1  |  us-west-2   |not-opted-in|
|  us-west-2-den-1a   |  usw2-den1-az1   |  us-west-2-den-1  |  us-west-2   |not-opted-in|
|  us-west-2-phx-2a   |  usw2-phx2-az1   |  us-west-2-phx-2  |  us-west-2   |not-opted-in|
+---------------------+------------------+-------------------+--------------+------------+

$ aws ec2 modify-availability-zone-group \
    --group-name us-west-2-lax-1 \
    --opt-in-status opted-in
{
    "Return": true
}

$ aws ec2 describe-availability-zones --region us-east-1 --all-availability-zones \
    --filters Name=zone-type,Values=wavelength-zone \
    --query 'AvailabilityZones[:3].[ZoneName,ZoneId,GroupName,ParentZoneName]' \
    --output table
-------------------------------------------------------------------------------------------------
|                                  DescribeAvailabilityZones                                    |
+-------------------------------+------------------+----------------------------+---------------+
|  us-east-1-wl1-bos-wlz-1      |  use1-wl1-bos-wlz1 |  us-east-1-wl1-bos-wlz-1 |  us-east-1    |
|  us-east-1-wl1-nyc-wlz-1      |  use1-wl1-nyc-wlz1 |  us-east-1-wl1-nyc-wlz-1 |  us-east-1    |
|  us-east-1-wl1-was-wlz-1      |  use1-wl1-was-wlz1 |  us-east-1-wl1-was-wlz-1 |  us-east-1    |
+-------------------------------+------------------+----------------------------+---------------+
```

### 7.4 Medir vos mismo el presupuesto de latencia entre AZs

La afirmación "la replicación síncrona es viable entre AZs" es comprobable. Dos instancias `c7g.large`, una en `use1-az1` y otra en `use1-az2`, misma VPC, IPs privadas:

```bash
# Same AZ (baseline)
$ sockperf ping-pong -i 10.42.131.14 -p 11111 -t 20 --pps=max
sockperf: === latency histogram (usec) ===
sockperf: Summary: Round trip is 84.117 usec
sockperf: Total 237914 observations
sockperf: ---> percentile 99.999 = 402.115
sockperf: ---> percentile 99.900 =  198.442
sockperf: ---> percentile 99.000 =  131.207
sockperf: ---> percentile 50.000 =   81.664

# Cross-AZ, same Region
$ sockperf ping-pong -i 10.42.149.88 -p 11111 -t 20 --pps=max
sockperf: === latency histogram (usec) ===
sockperf: Summary: Round trip is 731.408 usec
sockperf: Total 27346 observations
sockperf: ---> percentile 99.999 = 2841.330
sockperf: ---> percentile 99.900 = 1104.219
sockperf: ---> percentile 99.000 =  918.774
sockperf: ---> percentile 50.000 =  724.032

$ iperf3 -c 10.42.149.88 -t 10 -P 4 | tail -4
[SUM]   0.00-10.00  sec  11.6 GBytes  9.94 Gbits/sec  1421   sender
[SUM]   0.00-10.00  sec  11.6 GBytes  9.93 Gbits/sec         receiver
iperf Done.
```

Leé los números como un presupuesto de ingeniería, no como un benchmark. Un RTT cross-AZ por debajo del milisegundo con ~10 Gbit/s de ancho de banda significa que un commit síncrono te cuesta *cientos de microsegundos*, lo que para casi cualquier carga OLTP es invisible. Precisamente por eso AWS acota la separación entre AZs. Comparalo con cross-Region:

```bash
$ sockperf ping-pong -i 10.43.140.22 -p 11111 -t 20   # eu-west-1 target from us-east-1
sockperf: Summary: Round trip is 74812.531 usec
```

~75 ms de RTT. Cualquier diseño que ponga un quórum síncrono entre esas dos Regions acaba de hacer que cada escritura tarde 75 ms. Esta única medición es todo el argumento a favor de la replicación cross-Region **asíncrona** (Aurora Global Database, DynamoDB global tables, S3 CRR) y de aceptar un RPO distinto de cero.

### 7.5 Evacuar una AZ a propósito

El **zonal shift** de Route 53 Application Recovery Controller te permite sacar una AZ de rotación para un load balancer sin tocar tu aplicación, tu ASG ni tu DNS. Notá que el identificador de recurso es el **AZ ID**.

```bash
$ aws arc-zonal-shift list-managed-resources \
    --query 'items[].{Name:name,Arn:arn,Zones:availabilityZones}' --output json
[
    {
        "Name": "platform-primary",
        "Arn": "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/platform-primary/1234567890abcdef",
        "Zones": ["use1-az1", "use1-az2", "use1-az4"]
    }
]

$ aws arc-zonal-shift start-zonal-shift \
    --resource-identifier "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/platform-primary/1234567890abcdef" \
    --away-from use1-az2 \
    --expires-in 6h \
    --comment "INC-4471: elevated 5xx isolated to use1-az2, evacuating while we investigate"
{
    "zonalShiftId": "3f8a1c9d-6b2e-4a7f-9c1d-8e5b3a2f7c40",
    "resourceIdentifier": "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/platform-primary/1234567890abcdef",
    "awayFrom": "use1-az2",
    "expiryTime": "2026-09-04T20:14:07+00:00",
    "startTime": "2026-09-04T14:14:07+00:00",
    "status": "ACTIVE",
    "comment": "INC-4471: elevated 5xx isolated to use1-az2, evacuating while we investigate"
}

$ aws arc-zonal-shift cancel-zonal-shift --zonal-shift-id 3f8a1c9d-6b2e-4a7f-9c1d-8e5b3a2f7c40
{
    "zonalShiftId": "3f8a1c9d-6b2e-4a7f-9c1d-8e5b3a2f7c40",
    "status": "CANCELED"
}
```

**El prerrequisito que muerde:** el zonal shift solo remueve realmente la zona si el **cross-zone load balancing está deshabilitado** en el load balancer. Con cross-zone habilitado, los nodos de las zonas restantes siguen reenviando a los targets de la zona degradada y el shift no logra nada. También por eso la evacuación solo funciona si las *otras* dos zonas tienen margen pre-aprovisionado para el 100% del tráfico — estabilidad estática, de nuevo. Si tu ASG tiene que escalar hacia arriba para absorber el shift, hiciste que tu recuperación dependa del plano de control de EC2 durante un evento.

---

## 8. Patrones de resiliencia y qué compra realmente cada uno

### 8.1 Multi-AZ vs Multi-Region

| | **Multi-AZ (una sola Region)** | **Multi-Region** |
|---|---|---|
| Protege contra | Fallo a nivel centro de datos / zona: energía, refrigeración, inundación, corte de fibra, partición de red | Evento a nivel Region, cierre regulatorio regional, interrupción geográfica dirigida |
| Replicación de datos | **Síncrona** es viable (RTT sub-ms) | **Asíncrona** en la práctica (decenas de ms de RTT) |
| RPO | ~0 | Segundos a minutos |
| RTO | Segundos a un par de minutos | Minutos a horas, según la estrategia |
| Soporte de servicios gestionados | Extenso y en general una casilla de verificación: RDS Multi-AZ, ELB, ASG, EFS, DynamoDB, S3 | Requiere configuración explícita: CRR, global tables, Aurora Global DB, GA/Route 53 |
| Cambios en la aplicación | Normalmente ninguno | Frecuentemente sustanciales: idempotencia, resolución de conflictos, generación de IDs, estado de sesión |
| Costo de transferencia de datos | ~$0.01/GB en cada sentido | ~$0.02/GB+, y replicás de forma continua |
| Costo de cómputo | ~1.3–1.5× | ~1.8–2.2× para warm/activo-activo |
| Carga operativa | Baja | Alta — dos de todo para parchear, desplegar, monitorear y ensayar |
| **Cuándo es la respuesta correcta** | **El valor por defecto para prácticamente todas las cargas de producción** | Mandato regulatorio, RTO contractual que la Region no puede cumplir, o requisitos de latencia genuinamente globales |

No saltes directo a multi-Region. Un sistema Multi-AZ bien construido es la respuesta del 90%, y la mayoría de las organizaciones que "tienen multi-Region" tienen un standby sin probar que no levantaría.

### 8.2 Las cuatro estrategias de recuperación ante desastres

De la guía de recuperación ante desastres de AWS Well-Architected, ordenadas por costo:

| Estrategia | RPO | RTO | Qué corre en la segunda Region | Costo | Mecanismo de failover |
|---|---|---|---|---|---|
| **Backup & restore** | Horas | Horas (hasta 24h+) | Nada. Backups replicados (S3 CRR, copia cross-Region de AWS Backup) | $ | Desplegar el stack desde IaC, restaurar datos, reapuntar DNS |
| **Pilot light** | Minutos | Decenas de minutos | Datos replicados en vivo; infraestructura núcleo (VPC, réplica de BD) existe pero **el cómputo está apagado** | $$ | Escalar el cómputo, promover la réplica, reapuntar DNS |
| **Warm standby** | Segundos | Minutos | Una copia **reducida pero plenamente funcional** de todo el stack, sirviendo siempre nada o un hilo de tráfico | $$$ | Escalar horizontalmente, reapuntar el tráfico |
| **Multi-site activo/activo** | Casi cero | Casi cero | Una copia de tamaño completo sirviendo activamente usuarios reales | $$$$ | Retirar tráfico (dial de GA, health check de Route 53) — a menudo automático |

**La regla de decisión:** elegí la estrategia más barata cuyo RTO/RPO cumpla un número que tu negocio efectivamente haya escrito. Si nadie escribió el número, ese es el primer entregable, no la arquitectura.

**La regla que anula a todas las demás:** *un plan de DR que nunca se ejecutó no existe.* Agendá el game day. Hacé failover de verdad. Medí el RTO real, no el RTO de diseño. Toda organización que vi descubrir un plan de DR roto lo descubrió durante el incidente, y la causa casi siempre fue la misma clase de cosa — un secreto sin replicar, un string de Region hardcodeado, un certificado de ACM que solo existía en la primaria, una cuota en la Region en espera que nunca se subió porque ahí nunca había corrido nada.

### 8.3 Estabilidad estática, dicho sin vueltas

> Un sistema estáticamente estable sigue operando correctamente **sin necesitar hacer cambios en el plano de control** en respuesta a un fallo.

Los planos de control (las APIs que crean y modifican recursos) son inherentemente más complejos y menos disponibles que los planos de datos (los sistemas que sirven tu tráfico). Durante un evento grande, los planos de control se degradan primero y se recuperan último. Por lo tanto:

| Antipatrón (dinámico) | Equivalente estáticamente estable |
|---|---|
| Escalar el ASG cuando falla una AZ | Pre-aprovisionar 150% de capacidad en 3 AZs, para que 2 AZs ya carguen el 100% |
| Lanzar el stack de DR desde CloudFormation durante el evento | Mantenerlo desplegado e inactivo; cambiar solo un traffic dial |
| Actualizar un registro de Route 53 vía API durante el evento | Usar routing controls de ARC (una API de *plano de datos* de alta disponibilidad con 5 endpoints regionales independientes), o health checks de Global Accelerator |
| Traer un secreto desde la Region primaria al momento del failover | Replicar el secreto a la Region en espera de forma continua |
| Que la Region en espera asuma un rol vía el endpoint global de STS | Endpoints regionales de STS en todas partes |

El sobreaprovisionamiento no es desperdicio. Es la prima de la póliza de seguro, y sale más barato que la alternativa — un plan de recuperación que llama a una API que, en ese preciso momento, devuelve `RequestLimitExceeded`.

---

## 9. Verificación y diagnóstico de fallos

### 9.1 Una checklist de topología pre-producción

```bash
#!/usr/bin/env bash
# verify-topology.sh — run before declaring a stack "highly available"
set -euo pipefail
REGION="${1:?usage: verify-topology.sh <region> <asg-name>}"
ASG="${2:?}"
fail=0

echo "== 1. Region enabled and reachable =========================="
aws ec2 describe-regions --region-names "$REGION" \
  --query 'Regions[0].{Region:RegionName,OptIn:OptInStatus}' --output text

echo "== 2. AZ name -> AZ ID mapping (record this) ================"
aws ec2 describe-availability-zones --region "$REGION" \
  --filters Name=zone-type,Values=availability-zone \
  --query 'AvailabilityZones[].[ZoneName,ZoneId,State]' --output table

echo "== 3. ASG spans >= 3 distinct AZs ==========================="
az_count=$(aws autoscaling describe-auto-scaling-groups \
  --region "$REGION" --auto-scaling-group-names "$ASG" \
  --query 'length(AutoScalingGroups[0].AvailabilityZones)' --output text)
echo "AZs configured on $ASG: $az_count"
[ "$az_count" -ge 3 ] || { echo "  FAIL: fewer than 3 AZs"; fail=1; }

echo "== 4. Instances ACTUALLY distributed, not just configured ==="
aws autoscaling describe-auto-scaling-groups \
  --region "$REGION" --auto-scaling-group-names "$ASG" \
  --query 'AutoScalingGroups[0].Instances[].AvailabilityZone' --output text \
  | tr '\t' '\n' | sort | uniq -c

echo "== 5. Every private route table has its OWN AZ's NAT ========"
aws ec2 describe-route-tables --region "$REGION" \
  --filters "Name=tag:Name,Values=*private*" \
  --query 'RouteTables[].{RTB:RouteTableId,Nat:Routes[?DestinationCidrBlock==`0.0.0.0/0`].NatGatewayId|[0]}' \
  --output table

echo "== 6. Service quotas exist in THIS Region (they are per-Region)"
aws service-quotas get-service-quota --region "$REGION" \
  --service-code ec2 --quota-code L-1216C47A \
  --query 'Quota.{Name:QuotaName,Value:Value,Adjustable:Adjustable}' --output table

exit "$fail"
```

```bash
$ ./verify-topology.sh us-east-1 platform-api-asg
== 1. Region enabled and reachable ==========================
us-east-1       opt-in-not-required
== 2. AZ name -> AZ ID mapping (record this) ================
-----------------------------------------
|      DescribeAvailabilityZones        |
+---------------+------------+----------+
|  us-east-1a   | use1-az4   |available |
|  us-east-1b   | use1-az6   |available |
|  us-east-1c   | use1-az1   |available |
|  us-east-1d   | use1-az2   |available |
|  us-east-1e   | use1-az3   |available |
|  us-east-1f   | use1-az5   |available |
+---------------+------------+----------+
== 3. ASG spans >= 3 distinct AZs ===========================
AZs configured on platform-api-asg: 3
== 4. Instances ACTUALLY distributed, not just configured ===
      2 us-east-1a
      2 us-east-1c
      2 us-east-1d
== 5. Every private route table has its OWN AZ's NAT ========
--------------------------------------------------
|              DescribeRouteTables               |
+-------------------------+----------------------+
|          RTB            |         Nat          |
+-------------------------+----------------------+
|  rtb-0a1b2c3d4e5f60001  |  nat-0f1e2d3c4b5a001 |
|  rtb-0a1b2c3d4e5f60002  |  nat-0f1e2d3c4b5a002 |
|  rtb-0a1b2c3d4e5f60003  |  nat-0f1e2d3c4b5a003 |
+-------------------------+----------------------+
== 6. Service quotas exist in THIS Region (they are per-Region)
------------------------------------------------------------------------
|                            GetServiceQuota                           |
+--------------------------------------------------+---------+---------+
|                       Name                       |  Value  |Adjustable|
+--------------------------------------------------+---------+---------+
|  Running On-Demand Standard instances            |  512.0  |  True   |
+--------------------------------------------------+---------+---------+
```

El paso 4 es el que atrapa la forma de incidente A. El paso 3 verifica la *configuración*; el paso 4 verifica la *realidad*. Divergen más seguido de lo que te gustaría.

### 9.2 Síntoma → causa → arreglo

| Síntoma / error | Causa raíz | Diagnóstico | Arreglo |
|---|---|---|---|
| `InvalidVolume.ZoneMismatch: The volume 'vol-…' is not in the same availability zone as instance 'i-…'` | EBS es zonal; intentaste adjuntar entre AZs | `aws ec2 describe-volumes --volume-ids vol-… --query 'Volumes[0].AvailabilityZone'` | Snapshot → crear un volumen desde el snapshot **en la AZ destino**. A largo plazo: EFS/FSx, o una base de datos Regional |
| Pod atascado en `Pending` con `0/6 nodes are available: 3 node(s) had volume node affinity conflict` | El PV se aprovisionó en una zona sin nodo planificable para ese Pod | `kubectl get pv <pv> -o jsonpath='{.spec.nodeAffinity}'` | Poner `volumeBindingMode: WaitForFirstConsumer` en la StorageClass (§6.3) y recrear el PVC |
| Pod atascado en `Pending` con `didn't match pod topology spread constraints` | El spread duro `DoNotSchedule` no se puede satisfacer — una zona no tiene capacidad | `kubectl get nodes -L topology.kubernetes.io/zone` | Agregar capacidad de nodos en la zona carente, o relajar a `ScheduleAnyway` para cargas no críticas. **No lo relajes de forma generalizada** — eso reintroduce concentración |
| `AuthFailure: AWS was not able to validate the provided access credentials` en una sola Region | La Region es opt-in y no está habilitada para la cuenta | `aws account get-region-opt-status --region-name <region>` | `aws account enable-region --region-name <region>`, luego esperar a `ENABLED` |
| `Could not connect to the endpoint URL: "https://<service>.<region>.amazonaws.com/"` | El servicio no existe en esa Region (o el código de Region está mal tipeado) | `aws ssm get-parameter --name /aws/service/global-infrastructure/regions/<region>/services/<svc>` | Elegir una Region soportada, o usar un servicio alternativo soportado. Agregar el gate de CI de §7.1 |
| CloudFront rechaza un dominio personalizado: certificado no encontrado | El certificado de ACM se emitió fuera de `us-east-1` | `aws acm list-certificates --region us-east-1` | Volver a solicitar/importar el certificado **en `us-east-1`**. Para ALB es lo opuesto: la misma Region que el ALB |
| `WAFNonexistentItemException` al asociar una Web ACL con una distribución de CloudFront | La Web ACL se creó con `--scope REGIONAL` | `aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1` | Recrearla con `--scope CLOUDFRONT --region us-east-1` |
| Dos cuentas creen estar co-ubicadas pero la latencia y el costo dicen otra cosa | Se usaron **nombres** de AZ en lugar de **IDs** de AZ entre cuentas | Comparar `ZoneId` en ambas cuentas para el mismo `ZoneName` | Reubicar recursos por AZ ID. Agregar tags `az-id` (§6.1) para que esto sea auditable |
| La aplicación sigue pegándole al endpoint viejo minutos después de un failover de RDS Multi-AZ | Caché DNS del lado del cliente (clásicamente una JVM con `networkaddress.cache.ttl=-1`) | `dig +short <rds-endpoint>` desde el host vs. lo que resolvió la app | Poner `networkaddress.cache.ttl=5` (o menos); usar RDS Proxy; usar un pool de conexiones que vuelva a resolver |
| La línea de transferencia de datos creció ~40% sin aumento de tráfico | Nueva charla cross-AZ por un despliegue que distribuyó los servicios de otra forma | Cost Explorer, agrupar por *Usage Type*, filtrar `*DataTransfer-Regional-Bytes` | Confirmar con flow logs (abajo), luego aplicar enrutamiento consciente de la topología (§6.3) o co-ubicar el par charlatán |
| El failover zonal/regional de Global Accelerator no retiró el tráfico | El path del health check devuelve 200 aun con la app rota; o el peso del endpoint no se puso en cero | `aws globalaccelerator describe-endpoint-group --endpoint-group-arn …` e inspeccionar `HealthState` | Hacer que `/healthz` sea un chequeo real de dependencias. Verificar que el health check efectivamente cambie en un game day |
| El zonal shift corrió pero la AZ degradada sigue recibiendo tráfico | El cross-zone load balancing está habilitado en el ELB | `aws elbv2 describe-load-balancer-attributes --load-balancer-arn …` | Deshabilitar el cross-zone load balancing en los load balancers que pensás evacuar zonalmente |

### 9.3 Atribuir la transferencia de datos cross-AZ a una zona física

La factura te dice *cuánto*; los flow logs con `az-id` te dicen *quién*. Primero confirmá que el cargo existe:

```bash
$ aws ce get-cost-and-usage \
    --time-period Start=2026-08-01,End=2026-09-01 \
    --granularity MONTHLY \
    --metrics UnblendedCost UsageQuantity \
    --filter '{"Dimensions":{"Key":"USAGE_TYPE_GROUP","Values":["EC2: Data Transfer - Region to Region"]}}' \
    --group-by Type=DIMENSION,Key=USAGE_TYPE \
    --query 'ResultsByTime[0].Groups[].{Usage:Keys[0],GB:Metrics.UsageQuantity.Amount,USD:Metrics.UnblendedCost.Amount}' \
    --output table
--------------------------------------------------------------------------
|                          GetCostAndUsage                               |
+-------------------------------------------+-------------+--------------+
|                   Usage                   |     GB      |     USD      |
+-------------------------------------------+-------------+--------------+
|  USE1-DataTransfer-Regional-Bytes         |  41827.3341 |  418.2733    |
+-------------------------------------------+-------------+--------------+
```

Después encontrá a los que hablan, usando el campo `az-id` que habilita el formato de flow log de §6.1:

```sql
-- Athena over VPC Flow Logs partitioned by date
SELECT
  src.az_id                          AS src_az,
  dst.az_id                          AS dst_az,
  src.srcaddr,
  src.dstaddr,
  SUM(src.bytes) / 1024.0 / 1024 / 1024 AS gb
FROM   vpc_flow_logs src
JOIN   eni_az_map    dst ON src.dstaddr = dst.private_ip
WHERE  src.dt      BETWEEN '2026/08/01' AND '2026/08/31'
  AND  src.action  =  'ACCEPT'
  AND  src.az_id  <>  dst.az_id          -- the whole point: cross-AZ only
GROUP  BY src.az_id, dst.az_id, src.srcaddr, src.dstaddr
ORDER  BY gb DESC
LIMIT  15;
```

```
    src_az   |   dst_az   |   srcaddr    |   dstaddr    |    gb
-------------+------------+--------------+--------------+-----------
 use1-az4    | use1-az1   | 10.42.131.14 | 10.42.149.88 |  9214.771
 use1-az4    | use1-az2   | 10.42.131.14 | 10.42.166.31 |  8903.442
 use1-az1    | use1-az2   | 10.42.151.73 | 10.42.168.19 |  6188.019
 use1-az2    | use1-az4   | 10.42.166.31 | 10.42.132.20 |  5771.336
...
```

Tres flujos dan cuenta de ~24 TB de los 41 TB. En este caso eran una capa de caché haciendo fan-out a todas las zonas en cada lectura — resuelto con `trafficDistribution: PreferClose` (§6.3), que recortó la línea de factura en aproximadamente dos tercios sin cambiar una línea de código de aplicación.

---

## 10. Destilación enfocada en el examen

Los hechos que CLF-C02 tiene más probabilidad de evaluar en la tarea 3.2:

1. **Region** = un área geográfica con **múltiples Availability Zones aisladas** (mínimo tres para Regions nuevas). Las Regions están aisladas entre sí.
2. **Availability Zone** = uno o más **centros de datos discretos** con energía, redes y conectividad redundantes, físicamente separados por una distancia significativa (**dentro de 100 km / 60 millas**) y conectados por fibra de baja latencia de AWS.
3. **Edge location / PoP** = donde CloudFront cachea contenido y Route 53/Global Accelerator terminan tráfico cerca de los usuarios. Hay **muchas más edge locations que Regions**.
4. **Regional Edge Cache** = la caché de nivel intermedio de CloudFront entre los PoPs y el origen.
5. **Local Zone** = una extensión de una Region hacia un área metropolitana para latencia de milisegundos de un dígito.
6. **Wavelength Zone** = infraestructura de AWS dentro de una **red de operador 5G**, para aplicaciones de borde móvil.
7. **Outposts** = hardware gestionado por AWS **en tu propio centro de datos**, para necesidades on-premises y de residencia de datos.
8. **Factores de selección de Region**: **cumplimiento/gobernanza de datos**, **proximidad/latencia a los usuarios**, **disponibilidad de servicios en la Region**, **precios**. (Sustentabilidad es un quinto común.)
9. **Servicios globales**: IAM, Route 53, CloudFront, WAF (para CloudFront), Organizations, Shield.
10. **Alta disponibilidad dentro de una Region** = desplegar en **múltiples AZs**. Esa es la respuesta a "cómo sobrevivo a un fallo de centro de datos".
11. **Recuperación ante desastres entre Regions** = multi-Region, elegido entre backup&restore / pilot light / warm standby / multi-site activo-activo.
12. **AWS Global Accelerator** = IPs anycast estáticas y mejor rendimiento de red; **CloudFront** = cachear contenido en el borde. GA no cachea.

Trampas que aparecen como distractores:

- "Availability Zone" **no** es un único centro de datos; es uno *o más*.
- **Multi-AZ ≠ multi-Region.** Multi-AZ protege contra el fallo de un centro de datos; solo multi-Region protege contra un evento a nivel Region.
- Una **edge location no es una Region** y no corre tus instancias EC2.
- **Desplegar en más AZs no mejora la latencia para usuarios globales** — para eso están las edge locations, las Local Zones o una segunda Region.
- **Los datos no salen de una Region automáticamente.** La replicación entre Regions es algo que *vos* habilitás.
- **Las cuotas y los precios son por Region**, no por cuenta a nivel global.
- Una **Local Zone es generalmente una sola zona** — no es automáticamente de alta disponibilidad.

---

## 11. Referencias

**Examen y currícula**
- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- AWS Certified Cloud Practitioner certification page — https://aws.amazon.com/certification/certified-cloud-practitioner/

**Infraestructura global (autoritativa, actualizada continuamente)**
- AWS Global Infrastructure — https://aws.amazon.com/about-aws/global-infrastructure/
- Regions and Availability Zones — https://aws.amazon.com/about-aws/global-infrastructure/regions_az/
- AWS Services by Region (Regional Services List) — https://aws.amazon.com/about-aws/global-infrastructure/regional-product-services/
- AWS Local Zones — https://aws.amazon.com/about-aws/global-infrastructure/localzones/
- AWS Wavelength — https://aws.amazon.com/wavelength/
- AWS Outposts — https://aws.amazon.com/outposts/
- Amazon CloudFront global edge network — https://aws.amazon.com/cloudfront/features/
- AWS GovCloud (US) — https://aws.amazon.com/govcloud-us/
- Amazon Web Services in China — https://www.amazonaws.cn/en/about-aws/china/

**Documentación de servicios**
- Regions, Availability Zones, Local Zones and Wavelength Zones (EC2 User Guide) — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-regions-availability-zones.html
- `describe-availability-zones` (AWS CLI reference) — https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-availability-zones.html
- Specifying which Regions your account can use (Account Management) — https://docs.aws.amazon.com/accounts/latest/reference/manage-acct-regions.html
- Calling AWS Regional endpoints / AWS service endpoints — https://docs.aws.amazon.com/general/latest/gr/rande.html
- Managing AWS STS in an AWS Region (regional endpoints) — https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_temp_enable-regions.html
- Amazon Resource Names (ARNs) and AWS partitions — https://docs.aws.amazon.com/IAM/latest/UserGuide/reference-arns.html
- Calling global-infrastructure public parameters (Systems Manager) — https://docs.aws.amazon.com/systems-manager/latest/userguide/parameter-store-public-parameters-global-infrastructure.html
- VPC Flow Logs records (including `az-id`) — https://docs.aws.amazon.com/vpc/latest/userguide/flow-log-records.html
- AWS Global Accelerator Developer Guide — https://docs.aws.amazon.com/global-accelerator/latest/dg/what-is-global-accelerator.html
- Amazon Route 53 routing policies — https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/routing-policy.html
- Route 53 Application Recovery Controller — zonal shift — https://docs.aws.amazon.com/r53recovery/latest/dg/arc-zonal-shift.html
- Amazon EKS and AZ topology / EBS CSI zonal volumes — https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html
- Kubernetes Pod Topology Spread Constraints — https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/

**Guía de arquitectura**
- AWS Well-Architected Framework — Reliability Pillar — https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/welcome.html
- Disaster Recovery of Workloads on AWS: Recovery in the Cloud — https://docs.aws.amazon.com/whitepapers/latest/disaster-recovery-workloads-on-aws/disaster-recovery-workloads-on-aws.html
- Static stability using Availability Zones (Amazon Builders' Library) — https://aws.amazon.com/builders-library/static-stability-using-availability-zones/
- Avoiding overload in distributed systems by putting the smaller service in control — https://aws.amazon.com/builders-library/
- AWS Fault Isolation Boundaries (AWS Whitepaper) — https://docs.aws.amazon.com/whitepapers/latest/aws-fault-isolation-boundaries/abstract-and-introduction.html

**Precios (verificar antes de citar cualquier cifra)**
- Amazon EC2 On-Demand and data transfer pricing — https://aws.amazon.com/ec2/pricing/on-demand/
- Amazon VPC pricing (NAT Gateway, PrivateLink) — https://aws.amazon.com/vpc/pricing/
- AWS Pricing Calculator — https://calculator.aws/