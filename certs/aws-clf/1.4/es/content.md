# Tema 1.4 — Comprender los Conceptos de Economía del Cloud

**Certificación:** AWS Certified Cloud Practitioner (CLF-C02) · **Dominio 1: Conceptos de Cloud** · **Task Statement 1.4**
**Peso en el examen:** 6.0 · **Perfil:** Principal Platform Architect / Senior SRE

---

## 1. Motivación y el Problema Arquitectónico en Producción

### 1.1 Por qué a un SRE le tiene que importar una planilla de cálculo

La economía del cloud es la única dimensión de confiabilidad donde el modo de fallo es *silencioso, acumulativo e irreversible después del hecho*. Un memory leak te despierta con una página. Un cost leak te factura treinta días más tarde, después de que la plata se gastó y los registros de uso quedaron congelados en un período de facturación inmutable. No hay rollback para una factura cerrada.

El problema arquitectónico es este: **en un data center, la capacidad es una decisión que se toma una vez cada tres a cinco años por un comité de compras. En el cloud, la capacidad es una decisión que se toma miles de veces por día por cada ingeniero que tenga un rol de IAM, por cada política de Auto Scaling y por cada ciclo del scheduler de Kubernetes.** El control plane del gasto se mudó de Finanzas al pipeline de despliegue, y casi nadie mudó las barandas junto con él.

Concretamente, esta es la forma del fallo en producción:

```
On-premises:   spend is a step function.   Decisions/year: ~1     Feedback latency: 3-5 years
Cloud:         spend is a continuous fn.   Decisions/day:  10^3+  Feedback latency: 8-24 hours
```

La cifra de 8–24 horas no es retórica: es el retraso de ingesta de AWS Cost Explorer y del Cost and Usage Report (CUR). Hasta que no construyas la maquinaria de la sección 4, tu latencia de feedback *real* es la factura — 30 a 60 días. Un SRE nunca aceptaría un sistema de monitoreo con un intervalo de scrape de 30 días para la latencia. Eso es exactamente lo que la mayoría de las organizaciones acepta para el gasto.

### 1.2 Los tres modos de fallo que vas a ver de verdad

**Modo de fallo A — El trinquete de aprovisionamiento.**
Los ingenieros dimensionan las instancias para el pico más un margen de seguridad, y nada en el sistema las vuelve a bajar nunca. On-premises esto era invisible porque el hardware ya estaba pago; un servidor al 12% de CPU costaba lo mismo que un servidor al 90%. En el cloud, esa misma utilización del 12% es una transferencia bancaria medida de forma continua. Los parques de virtualización on-premises empresariales típicos funcionan con una utilización promedio de CPU del 12–18%. Hacé un lift-and-shift de esa proporción a EC2 sin rightsizing y habrás construido una máquina que convierte ciclos de CPU ociosos en facturas.

**Modo de fallo B — Gasto sin etiquetar, no atribuible.**
Cuando el 40% de la factura no se puede atribuir a un equipo, producto o entorno, no se puede tomar ninguna decisión de optimización, porque nadie es dueño del número. Este es el equivalente en FinOps a correr un sistema distribuido sin trace IDs. Podés ver que la latencia está mal; no podés ver *dónde*.

**Modo de fallo C — La trampa del compromiso.**
Las Reserved Instances y los Savings Plans son la reintroducción del riesgo tipo CAPEX en el cloud. Una RI all-upfront a 3 años sobre una familia de instancias de la que hacés refactor en el mes 8 es un activo varado con la misma economía que un servidor dado de baja — compraste hardware, solo que lo compraste con una llamada a una API JSON. Toda la propuesta de valor del cloud (costo variable, elasticidad) se *entrega voluntariamente* a cambio de un descuento, y ese intercambio debe ser una decisión arquitectónica deliberada y medida, no un reflejo de compras.

### 1.3 Qué está evaluando realmente el examen

El Task Statement 1.4 de CLF-C02 evalúa si entendés:

- Aspectos de la economía del cloud — **TCO**, **OPEX vs CAPEX**, estrategias de licenciamiento, **rightsizing**
- Los ahorros de costos de migrar al cloud (menor huella de data center, menor gasto en hardware)
- Costo **fijo vs variable**
- La estructura de costos on-premises vs la estructura de costos del cloud (costo operativo, hardware, mano de obra)
- Los beneficios de la **automatización** (aprovisionamiento, Infrastructure as Code)
- Los beneficios de los **servicios administrados de AWS** (RDS vs bases de datos autogestionadas en EC2, ECS/EKS vs EC2 puro, DynamoDB vs una base de datos en EC2)

El resto de este documento trata todo eso como requisitos de ingeniería, no como vocabulario.

---

## 2. El Modelo de Costos: Definiciones Formales

### 2.1 CAPEX vs OPEX — y por qué es una afirmación contable, no técnica

Esta distinción trata sobre *cuándo sale la plata y cómo lo registran los libros*, no sobre si la tecnología es buena.

| Dimensión | CAPEX (Capital Expenditure) | OPEX (Operational Expenditure) |
|---|---|---|
| Salida de caja | Grande, por adelantado, antes de que corra cualquier workload | Continua, vencida, proporcional al consumo |
| Tratamiento contable | Capitalizado en el balance, depreciado a lo largo de la vida útil del activo (típicamente 3–5 años para servidores) | Registrado como gasto en el estado de resultados en el período en que se incurre |
| Efecto sobre el EBITDA | Favorable — la depreciación queda por debajo de la línea del EBITDA | Desfavorable — el costo completo impacta en el gasto operativo |
| Vía de aprobación | Comité de capital, ciclo presupuestario anual, meses de plazo | Presupuesto departamental, muchas veces autoservicio |
| Riesgo ante demanda insuficiente | Total — el activo se compra sin importar si se usa | Casi nulo — dejás de pagar cuando dejás de consumir |
| Riesgo ante pico de demanda | Total — no hay capacidad disponible por semanas o meses | Casi nulo — aprovisionado en minutos |
| Valor residual | No nulo pero de rápido decaimiento; la disposición tiene su propio costo | Ninguno — no se posee nada |
| Renovación tecnológica | Discreta, disruptiva, cada 3–5 años | Continua — las nuevas generaciones de instancias están a una llamada de API |

**La respuesta del examen:** migrar al cloud cambia CAPEX por OPEX. **La respuesta del arquitecto:** cambia *riesgo de capital* por *disciplina operativa*. Dejás de equivocarte una vez, caro, cada cinco años; empezás a equivocarte de forma continua, barata y corregible — *si y solo si* construís el ciclo de feedback.

Prestá atención al punto del EBITDA, porque es la razón más común por la que un CFO se resiste a la migración que quiere un equipo de plataforma. Es una objeción real, no irracional, y los Savings Plans / las compras de RI all-upfront existen en parte para atenderla: una tarifa de compromiso por adelantado es un gasto prepago, amortizado a lo largo del plazo, lo que restituye parte del tratamiento tipo CAPEX al que finanzas está acostumbrado.

### 2.2 Costo fijo vs variable

Ortogonal a CAPEX/OPEX. Un costo es **fijo** si no cambia con el volumen de trabajo realizado, **variable** si sí lo hace.

| | Fijo | Variable |
|---|---|---|
| On-premises | Servidores, SAN, equipamiento de red, alquiler del data center, la mayor parte del licenciamiento, la mayor parte de la nómina de operaciones | Electricidad por encima de la línea base, soporte por incidente, exceso de ancho de banda |
| AWS | Compromiso de Savings Plan / RI, capacidad reservada, mínimo del plan de Support, horas de puerto de Direct Connect, servicios de capacidad aprovisionada (p. ej. Provisioned IOPS, WCU/RCU aprovisionadas de DynamoDB), un `t3.micro` que nunca apagás | Horas de instancia On-Demand, Spot, GB-almacenamiento y requests de S3, GB-segundos de Lambda, transferencia de datos de salida, capacidad on-demand de DynamoDB |

**El matiz crítico que el examen va a sondear:** el cloud no hace que el costo sea variable. *El cloud hace posible que el costo sea variable.* Una instancia EC2 corriendo 24×7 sin autoscaling es un costo fijo que da la casualidad de que se factura por hora. Replicaste la economía on-premises dentro de AWS y le agregaste un margen. La elasticidad es una propiedad arquitectónica que tenés que construir; la plataforma solo remueve el obstáculo.

### 2.3 Costo Total de Propiedad (TCO)

El TCO es la suma de cada costo atribuible a operar un workload a lo largo de un horizonte definido, **incluidos aquellos que nadie te factura**. El error sistemático en toda comparación ingenua es que el lado on-premises omite los costos que ya están enterrados en otras líneas presupuestarias.

```
TCO = Σ (direct infrastructure)
    + Σ (facilities: space, power, cooling, physical security)
    + Σ (software licensing and support contracts)
    + Σ (labor: fully loaded, including on-call and racking)
    + Σ (resilience: DR site, backup media, offsite storage)
    + Σ (risk-adjusted cost of over-provisioning and refresh cycles)
    - Σ (residual asset value)
```

Los dos términos que casi siempre faltan en una comparación casera son la **mano de obra totalmente cargada** y el **costo del sobreaprovisionamiento**. Juntos, normalmente superan la línea de hardware.

---

## 3. Comparación de TCO Trabajada — Parque Empresarial de 200 VMs

Lo que sigue es un modelo concreto y aritméticamente completo. Los números son ilustrativos de un parque de tamaño medio en una instalación de colocation; **el método es el entregable, no las constantes.** Cada constante de AWS debe re-derivarse desde la Price List API (sección 5.6) para tu región y fecha.

### 3.1 Costo anual on-premises en régimen permanente

Parque: 20 hosts de doble socket (32 núcleos físicos, 384 GB de RAM cada uno), 200 TB de SAN utilizable, 10 racks en colocation, ~200 VMs de producción y no producción.

| Línea de costo | Base | Costo anual (USD) |
|---|---|---|
| Hardware de servidores | 20 × $18.000 = $360.000, lineal a 5 años | 72.000 |
| Almacenamiento (SAN) | $180.000 a 5 años | 36.000 |
| Appliances de red + seguridad | $90.000 a 5 años | 18.000 |
| Licenciamiento de software (hipervisor, SO invitado, backup) | suscripción anual + SA | 85.000 |
| Colocation (espacio, energía, refrigeración) | 10 racks × $1.200/mes | 144.000 |
| Mantenimiento de hardware y soporte del proveedor | 12% de $630.000 de CAPEX de hardware | 75.600 |
| Mano de obra | 3,5 FTE × $120.000 totalmente cargados | 420.000 |
| Sitio de DR (secundario, warm) | ~40% de la infraestructura primaria | 60.000 |
| **Total** | | **910.600** |

Observaciones estructurales que un arquitecto debería hacer de inmediato:

- **La mano de obra es el 46% del total.** La depreciación del hardware es el 8%. Cualquier argumento de que "el cloud es más caro que los servidores" que compare una factura de EC2 contra una orden de compra de servidores está comparando una porción del 8% contra un total del 100%.
- Instalaciones + mantenimiento ($219.600) es 2,4× la depreciación del hardware. El edificio cuesta más que las cajas.
- La depreciación a 5 años supone que la renovación ocurre en fecha. En la práctica, el hardware se estira a 6–7 años con tasas de fallo crecientes — un impuesto oculto sobre la confiabilidad que nunca aparece en una planilla de TCO pero sí aparece en tu revisión de incidentes.
- La utilización promedio de CPU en un parque de esta clase es típicamente del 12–18%. Estás pagando el 100% de $910.600 por aproximadamente el 15% del trabajo que el hardware podría hacer.

### 3.2 Costo anual en AWS en régimen permanente (post-migración, post-rightsizing)

Después del rightsizing (sección 6) las 200 VMs se contraen a equivalentes de 120 × `m6i.large` y 30 × `m6i.xlarge`, más servicios administrados que reemplazan componentes autogestionados.

Línea base On-Demand, precio de lista de `us-east-1` a 2025 (`m6i.large` = $0,096/hr, `m6i.xlarge` = $0,192/hr, 730 hr/mes):

```
120 × 0.096 × 730 × 12 = $100,915/yr
 30 × 0.192 × 730 × 12 = $ 50,458/yr
                          ---------
On-Demand compute       = $151,373/yr
```

Aplicar un compromiso de Compute Savings Plans con ~80% de cobertura más un calendario fuera de horario en no-producción arroja una reducción efectiva de ~45% → **~$84.000/año**.

| Línea de costo | Base | Costo anual (USD) |
|---|---|---|
| Cómputo EC2 | On-Demand $151.373 menos SP + scheduling (~45%) | 84.000 |
| EBS gp3 | 90 TB aprovisionados × $0,08/GB-mes | 86.400 |
| Snapshots de EBS | 20 TB × $0,05/GB-mes | 12.000 |
| S3 Standard-IA (backup/archivo) | 60 TB × $0,0125/GB-mes | 9.000 |
| Transferencia de datos de salida | 8 TB/mes × $0,09/GB | 8.640 |
| NAT Gateways | 4 × $0,045/hr + 6 TB/mes de procesamiento | 4.815 |
| Servicios administrados (RDS, ELB, AWS Backup) | medido | 36.000 |
| AWS Support (nivel Business) | porcentaje escalonado del gasto | 22.000 |
| Mano de obra | 2,0 FTE × $135.000 totalmente cargados | 270.000 |
| **Total en régimen permanente** | | **532.855** |

**Delta en régimen permanente: $377.745/año, una reducción del 41%.**

### 3.3 El número que la diapositiva del proveedor omite: el costo de migración

Costo de migración por única vez (descubrimiento, refactorización, operación en paralelo, transferencia de datos de entrada, capacitación, operaciones paralelas): ~$450.000, amortizado a 3 años = **$150.000/año para los años 1–3**.

| Horizonte | On-premises | AWS | Delta | Reducción |
|---|---|---|---|---|
| Años 1–3 (incl. amortización de migración) | 910.600 | 682.855 | 227.745 | 25% |
| Año 4+ (régimen permanente) | 910.600 | 532.855 | 377.745 | 41% |

Dos conclusiones honestas:

1. **Los ahorros son reales pero no son del 70%.** Una reducción de TCO del 25–45% es una afirmación de ingeniería defendible y alcanzable. Cualquier cosa por encima de eso en un business case o está contando el CAPEX de renovación evitado como ahorro, o está asumiendo una reducción de mano de obra que no va a ocurrir.
2. **Los ahorros viven en la mano de obra y en las instalaciones, no en el precio unitario del cómputo.** El cómputo de AWS *no* es más barato por núcleo-hora que poseer un servidor depreciado con alta utilización. Es más barato por *unidad de capacidad de negocio entregada*, porque eliminás el racking, el parcheo de firmware, el zoning de la SAN, el sitio de DR y el comité de planificación de capacidad.

### 3.4 A dónde va realmente la plata: drivers de costo por decisión arquitectónica

| Decisión | Impacto en el costo | Dirección |
|---|---|---|
| Lift-and-shift sin rightsizing | +40–70% vs con rightsizing | El peor resultado común |
| Rightsizing (guiado por Compute Optimizer) | −20–40% del cómputo | Mayor ROI, riesgo de compromiso nulo |
| Scheduling de no-producción (noches/fines de semana apagados) | −65% del cómputo de no-prod (168 → ~60 hr/semana) | ROI alto, riesgo bajo |
| Compute Savings Plans, 1 año no-upfront | hasta −27% típico sobre el uso cubierto | Requiere una línea base estable |
| Compute Savings Plans, 3 años all-upfront | hasta −66% (máximo publicado por AWS) | Riesgo de compromiso alto |
| EC2 Instance Savings Plans, 3 años all-upfront | hasta −72% (máximo publicado por AWS) | Fija familia + región |
| Standard Reserved Instances, 3 años all-upfront | hasta −72% (máximo publicado por AWS) | Fija familia + región, reserva de capacidad opcional |
| Spot Instances | hasta −90% vs On-Demand | Requiere una arquitectura tolerante a interrupciones |
| Migración a Graviton (ARM) | −10–20% con rendimiento igual o mejor | Requiere un build compatible con ARM |
| Migración de EBS gp2 → gp3 | −20% en almacenamiento, IOPS desacoplados | Riesgo casi nulo, frecuentemente olvidado |
| Adopción de servicios administrados (RDS, DynamoDB, Fargate) | Precio unitario más alto, menor mano de obra + menor costo de incidentes | Neto positivo en casi todas las escalas |
| Recursos sin etiquetar | 0% directo, pero bloquea todas las optimizaciones anteriores | El multiplicador silencioso |

---

## 4. Modelos de Precios de AWS y la Superficie de Compromisos

### 4.1 Los tres principios fundamentales de precios

AWS enuncia tres (evaluables en el examen, y genuinamente el modelo):

1. **Pay as you go** — pagás solo por lo que consumís, sin mínimo, sin cargo por terminación para recursos On-Demand.
2. **Save when you commit** — los Savings Plans y las Reserved Instances intercambian un compromiso de uso de 1 o 3 años por un descuento de hasta el 72%.
3. **Pay less by using more** — los precios escalonados por volumen (niveles de almacenamiento de S3, niveles de transferencia de datos) reducen el precio unitario marginal a medida que sube el consumo.

Una cuarta fuerza económica está detrás de las tres: **las propias economías de escala de AWS.** AWS bajó los precios bastante más de cien veces desde 2006 sin que un cliente tuviera que renegociar. Ese es un argumento estructural a favor del OPEX que ningún activo propio puede igualar — tu servidor que se deprecia nunca se vuelve más barato.

### 4.2 Instrumentos de compromiso — tabla completa de compromisos

| | On-Demand | Spot | Compute Savings Plans | EC2 Instance Savings Plans | Standard RI | Convertible RI | Dedicated Host |
|---|---|---|---|---|---|---|---|
| Descuento máximo vs On-Demand | — | hasta 90% | hasta 66% | hasta 72% | hasta 72% | hasta 66% | varía |
| Unidad de compromiso | ninguna | ninguna | $/hora | $/hora | cantidad de instancias | cantidad de instancias | host |
| Plazo | ninguno | ninguno | 1 o 3 años | 1 o 3 años | 1 o 3 años | 1 o 3 años | 1 o 3 años (u On-Demand) |
| Fija la familia de instancias | no | no | **no** | **sí** | sí | modificable | sí (tipo de host) |
| Fija la región | no | no | **no** | sí | sí | sí | sí |
| Fija la AZ | no | no | no | no | opcional | opcional | sí |
| Fija SO / tenancy | no | no | no | no | sí | modificable | n/a |
| Cubre Fargate | no | no | **sí** | no | no | no | no |
| Cubre Lambda | no | no | **sí** | no | no | no | no |
| Cubre SageMaker | no | no | SP de SageMaker aparte | no | no | no | no |
| Reserva de capacidad | no | no | no | no | solo RI con alcance de AZ | solo con alcance de AZ | sí (física) |
| Se puede vender en el Marketplace | n/a | n/a | **no** | **no** | sí (solo Standard) | no | no |
| Riesgo de interrupción | ninguno | aviso de 2 min | ninguno | ninguno | ninguno | ninguno | ninguno |
| Visibilidad de socket/núcleo para BYOL | no | no | no | no | no | no | **sí** |
| Mejor encaje | irregular, no probado, de corta vida | batch, CI, stateless, tolerante a fallos | parque de cómputo mixto/en evolución | estable, familia conocida | legacy estable + garantía de capacidad | estable pero con evolución esperada | software licenciado por núcleo, aislamiento por cumplimiento |

**Guía arquitectónica, en orden:** primero rightsizing, segundo scheduling, tercero compromiso. Comprometerse con uso sin rightsizing es comprar un descuento sobre desperdicio — el error de FinOps más común y más caro. Los instrumentos de descuento son una optimización *financiera* aplicada encima de una *arquitectónica*; invertir el orden fija el desperdicio por 1–3 años.

**Sobre Savings Plans vs RIs:** los Savings Plans son el default moderno. Se comprometen a una tasa de gasto en dólares por hora en lugar de a una forma específica de instancia, lo que preserva la flexibilidad que es el punto del cloud. Las Reserved Instances conservan exactamente dos ventajas: las Standard RI se pueden vender en el Reserved Instance Marketplace (una vía de salida que los Savings Plans no tienen), y las RI zonales proveen una reserva de capacidad. Notá además que las RI cubren servicios que los Savings Plans no — RDS, ElastiCache, OpenSearch, Redshift y DynamoDB tienen sus propias construcciones de capacidad reservada.

### 4.3 Estrategias de licenciamiento — BYOL vs License Included

Esto está nombrado explícitamente en la guía del examen y es donde se esconden las sorpresas de una sola línea más grandes.

| | License Included | BYOL (Bring Your Own License) |
|---|---|---|
| Cómo pagás | Incluido en la tarifa horaria de la instancia | Por separado, al proveedor del software |
| Forma del costo | Puramente variable — se detiene cuando la instancia se detiene | Fijo — sos dueño del derecho de uso independientemente del uso |
| Carga de cumplimiento | AWS se ocupa | **Tuya**, enteramente |
| Requisito de tenancy | Tenancy compartido está bien | Frecuentemente requiere **Dedicated Host** |
| Elasticidad | Total — escalar a cero, escalar a 100 | Limitada a la cantidad de licencias que poseés |
| Riesgo de true-up | Ninguno | Exposición a auditoría si excedés los derechos de uso |
| Mejor encaje | Workloads variables/impredecibles, despliegues nuevos | Licencias perpetuas existentes con Software Assurance, workloads en régimen permanente |

**La mecánica del Dedicated Host — esta es la parte que hace tropezar a la gente.** El licenciamiento basado en núcleos y sockets (Windows Server Datacenter, SQL Server, Oracle Database) exige que demuestres sobre cuántos núcleos y sockets *físicos* corre el software. En tenancy compartido no podés ver el host físico, así que no podés satisfacer los términos de la licencia. **Los Dedicated Hosts exponen la cantidad física de sockets y núcleos, y proveen afinidad para que una instancia detenida reinicie en el mismo host** — eso es precisamente por lo que existen, y por lo que son la zona de aterrizaje obligatoria para la mayoría de los escenarios BYOL.

Además, las licencias de Microsoft adquiridas **el 1 de octubre de 2019 o después sin Software Assurance activo no pueden desplegarse en servicios de cloud alojado dedicado** (lo que incluye a AWS, Azure, Google Cloud y Alibaba). Las licencias adquiridas antes de esa fecha quedan protegidas por derechos adquiridos. **License Mobility a través de Software Assurance** es la excepción que permite que ciertos productos (SQL Server, Exchange, SharePoint) corran en tenancy compartido por defecto. Equivocate en esto y tenés o una exposición de cumplimiento o una factura innecesaria de Dedicated Host.

**AWS License Manager** es el control plane para esto: rastrea los derechos de uso, aplica límites duros o blandos en el momento del lanzamiento de la instancia y produce la evidencia de utilización que presentás en una auditoría. **AWS OLA (Optimization and Licensing Assessment)** es un compromiso gratuito ejecutado por AWS que modela tu posición de licenciamiento a través de las opciones BYOL y License Included.

### 4.4 Servicios administrados — el cálculo del "undifferentiated heavy lifting"

El pilar de Cost Optimization del AWS Well-Architected nombra cinco principios de diseño; el cuarto es **"Stop spending money on undifferentiated heavy lifting."** Esto es lo que eso significa numéricamente.

| Workload | Autogestionado en EC2 | Equivalente administrado de AWS | El intercambio real |
|---|---|---|---|
| BD relacional | EC2 + EBS + tu propio HA, backups, parcheo, pruebas de failover | **Amazon RDS / Aurora** | La hora-instancia de RDS está ~20–35% por encima de la hora de EC2 puro equivalente. Reemplaza aproximadamente 0,3–0,5 FTE de toil de DBA/SRE por parque y elimina toda una clase de incidentes de failover a las 3 de la mañana. El punto de equilibrio está bastante por debajo de un FTE. |
| Almacén clave-valor a escala | Clúster de Cassandra/MongoDB en EC2 | **DynamoDB** | Elimina por completo la planificación de capacidad del clúster, el tuning de compaction y el reemplazo de nodos. El modo de capacidad on-demand hace que el costo sea genuinamente proporcional a los requests. |
| Orquestación de contenedores | Control plane de Kubernetes autoalojado en EC2 | **EKS / ECS**, opcionalmente **Fargate** | El control plane de EKS es una tarifa horaria fija (~$0,10/hr por clúster). Correr tu propio etcd + API server en HA cuesta más solo en instancias, antes de contar el toil de las actualizaciones. |
| Almacenamiento de objetos | Servidores de almacenamiento / NAS | **S3** | 11 nueves de durabilidad, tiering de ciclo de vida, sin planificación de capacidad. Nada autoalojado compite en TCO. |
| Balanceo de carga | Flota de HAProxy/NGINX en EC2 | **ELB (ALB/NLB)** | Saca una capa stateful y crítica para la disponibilidad de tu superficie de guardia. |

**El principio económico:** el servicio administrado siempre tiene un precio *unitario* más alto y un precio *total* más bajo, porque el precio unitario contra el que comparás omite la mano de obra. Este es el mismo error aritmético que el de la sección 3.1 — comparar la porción del 8% en lugar del total del 100%. El caso contrario es real pero angosto: a escala muy grande, muy estable y con un equipo especialista existente, autogestionar puede ganar. Por debajo de ese umbral, no.

### 4.5 Los beneficios de la automatización y la IaC — expresados como costo

| Aprovisionamiento manual | Infrastructure as Code |
|---|---|
| Tiempo de aprovisionamiento: días a semanas | Minutos, en un pipeline |
| Drift de entornos: garantizado, no medible | Detectable (`cloudformation detect-stack-drift`, `terraform plan`) |
| Destrucción de entornos efímeros: olvidada | Automática, parte del ciclo de vida del pipeline |
| Etiquetado: inconsistente, aplicado después del hecho si es que se aplica | **Forzado en la creación** — el prerrequisito de toda atribución de costos |
| Cambio de rightsizing: un ticket y una ventana de cambio | Un diff de parámetro y un deploy |
| Costo de un error | Persiste hasta que alguien lo nota | Revertido redesplegando el commit anterior |

El punto relevante para el costo es la cuarta fila. **Las etiquetas de asignación de costos aplicadas por IaC en el momento de creación del recurso son la diferencia entre una factura sobre la que podés actuar y una factura que solo podés pagar.** Las etiquetas aplicadas retroactivamente no rellenan los datos históricos del CUR — el pasado queda inatribuible para siempre.

---

## 5. Manifiestos de Infraestructura Completos

Todo lo que sigue es desplegable tal como está. Reemplazá los IDs de cuenta, los nombres de bucket y las direcciones de correo.

### 5.1 CloudFormation — cimiento de datos de FinOps (export CUR 2.0, Cost Category, destino S3)

Desplegar en la **cuenta de gestión**, en `us-east-1` (las APIs de facturación son endpoints globales alojados allí).

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >
  FinOps data foundation. Creates the S3 destination and bucket policy for a
  Data Exports (CUR 2.0) delivery, plus a Cost Category that maps linked
  accounts and tags into business dimensions. Deploy in the Organizations
  management account in us-east-1.

Parameters:
  ExportBucketName:
    Type: String
    Description: Globally unique S3 bucket name for CUR 2.0 delivery.
    AllowedPattern: '^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$'
  ExportName:
    Type: String
    Default: cur2-hourly-resources
  RetentionDays:
    Type: Number
    Default: 2555          # 7 years, typical finance retention requirement
    MinValue: 90

Resources:

  # ------------------------------------------------------------------
  # Destination bucket. Versioned, encrypted, public access fully blocked.
  # ------------------------------------------------------------------
  ExportBucket:
    Type: AWS::S3::Bucket
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      BucketName: !Ref ExportBucketName
      VersioningConfiguration:
        Status: Enabled
      BucketEncryption:
        ServerSideEncryptionConfiguration:
          - ServerSideEncryptionByDefault:
              SSEAlgorithm: AES256
            BucketKeyEnabled: true
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        BlockPublicPolicy: true
        IgnorePublicAcls: true
        RestrictPublicBuckets: true
      OwnershipControls:
        Rules:
          - ObjectOwnership: BucketOwnerEnforced
      LifecycleConfiguration:
        Rules:
          - Id: TierAndExpire
            Status: Enabled
            Transitions:
              - StorageClass: STANDARD_IA
                TransitionInDays: 90
              - StorageClass: GLACIER_IR
                TransitionInDays: 365
            ExpirationInDays: !Ref RetentionDays
            NoncurrentVersionExpiration:
              NoncurrentDays: 30
      Tags:
        - Key: CostCenter
          Value: PLATFORM-FINOPS
        - Key: Environment
          Value: shared
        - Key: DataClassification
          Value: confidential

  # ------------------------------------------------------------------
  # Bucket policy required by the billing service to write the export.
  # The two SourceArn/SourceAccount conditions are the confused-deputy
  # guard - do not omit them.
  # ------------------------------------------------------------------
  ExportBucketPolicy:
    Type: AWS::S3::BucketPolicy
    Properties:
      Bucket: !Ref ExportBucket
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: AllowBillingServiceGetBucketAcl
            Effect: Allow
            Principal:
              Service: billingreports.amazonaws.com
            Action:
              - s3:GetBucketAcl
              - s3:GetBucketPolicy
            Resource: !GetAtt ExportBucket.Arn
            Condition:
              StringEquals:
                aws:SourceAccount: !Ref AWS::AccountId
              ArnLike:
                aws:SourceArn: !Sub 'arn:${AWS::Partition}:cur:us-east-1:${AWS::AccountId}:definition/*'

          - Sid: AllowBillingServicePutObject
            Effect: Allow
            Principal:
              Service: billingreports.amazonaws.com
            Action: s3:PutObject
            Resource: !Sub '${ExportBucket.Arn}/*'
            Condition:
              StringEquals:
                aws:SourceAccount: !Ref AWS::AccountId
              ArnLike:
                aws:SourceArn: !Sub 'arn:${AWS::Partition}:cur:us-east-1:${AWS::AccountId}:definition/*'

          - Sid: AllowDataExportsService
            Effect: Allow
            Principal:
              Service: bcm-data-exports.amazonaws.com
            Action:
              - s3:PutObject
              - s3:GetBucketPolicy
talk:
            Resource:
              - !GetAtt ExportBucket.Arn
              - !Sub '${ExportBucket.Arn}/*'
            Condition:
              StringEquals:
                aws:SourceAccount: !Ref AWS::AccountId

          - Sid: DenyInsecureTransport
            Effect: Deny
            Principal: '*'
            Action: 's3:*'
            Resource:
              - !GetAtt ExportBucket.Arn
              - !Sub '${ExportBucket.Arn}/*'
            Condition:
              Bool:
                aws:SecureTransport: false

  # ------------------------------------------------------------------
  # CUR 2.0 export via the Data Exports API. Hourly granularity with
  # resource IDs is the only configuration from which rightsizing and
  # per-resource attribution can be computed. Do NOT settle for daily.
  # ------------------------------------------------------------------
  CostAndUsageExport:
    Type: AWS::BCMDataExports::Export
    DependsOn: ExportBucketPolicy
    Properties:
      Export:
        Name: !Ref ExportName
        Description: Hourly CUR 2.0 with resource IDs, Parquet, overwrite.
        DataQuery:
          TableConfigurations:
            COST_AND_USAGE_REPORT:
              TIME_GRANULARITY: HOURLY
              INCLUDE_RESOURCES: 'TRUE'
              INCLUDE_MANUAL_DISCOUNT_COMPATIBILITY: 'FALSE'
              INCLUDE_SPLIT_COST_ALLOCATION_DATA: 'TRUE'
          QueryStatement: >-
            SELECT
              bill_billing_period_start_date,
              bill_payer_account_id,
              line_item_usage_account_id,
              line_item_usage_start_date,
              line_item_line_item_type,
              line_item_product_code,
              line_item_usage_type,
              line_item_operation,
              line_item_resource_id,
              line_item_usage_amount,
              line_item_unblended_cost,
              line_item_blended_cost,
              pricing_term,
              pricing_unit,
              product,
              product_region_code,
              resource_tags,
              cost_category,
              reservation_effective_cost,
              reservation_unused_amortized_upfront_fee_for_billing_period,
              reservation_unused_recurring_fee,
              reservation_reservation_a_r_n,
              savings_plan_savings_plan_effective_cost,
              savings_plan_total_commitment_to_date,
              savings_plan_used_commitment,
              savings_plan_savings_plan_a_r_n
            FROM COST_AND_USAGE_REPORT
        DestinationConfigurations:
          S3Destination:
            S3Bucket: !Ref ExportBucket
            S3Prefix: cur2
            S3Region: !Ref AWS::Region
            S3OutputConfigurations:
              OutputType: CUSTOM
              Format: PARQUET
              Compression: PARQUET
              Overwrite: OVERWRITE_REPORT
        RefreshCadence:
          Frequency: SYNCHRONOUS

  # ------------------------------------------------------------------
  # Cost Category: a server-side dimension applied to every cost record,
  # including historical ones. This is how you attribute spend that
  # tagging missed - it works on account ID, not on resource tags.
  # ------------------------------------------------------------------
  BusinessUnitCostCategory:
    Type: AWS::CE::CostCategory
    Properties:
      Name: BusinessUnit
      RuleVersion: CostCategoryExpression.v1
      DefaultValue: UNALLOCATED
      Rules: !Sub |
        [
          {
            "Value": "PLATFORM",
            "Rule": {
              "Dimensions": {
                "Key": "LINKED_ACCOUNT",
                "Values": ["111122223333", "444455556666"],
                "MatchOptions": ["EQUALS"]
              }
            },
            "Type": "REGULAR"
          },
          {
            "Value": "PAYMENTS",
            "Rule": {
              "Tags": {
                "Key": "CostCenter",
                "Values": ["PAY-1000", "PAY-1001"],
                "MatchOptions": ["EQUALS"]
              }
            },
            "Type": "REGULAR"
          },
          {
            "Value": "SANDBOX",
            "Rule": {
              "Tags": {
                "Key": "Environment",
                "Values": ["sandbox", "dev"],
                "MatchOptions": ["EQUALS"]
              }
            },
            "Type": "REGULAR"
          }
        ]
      SplitChargeRules: !Sub |
        [
          {
            "Source": "PLATFORM",
            "Targets": ["PAYMENTS", "SANDBOX"],
            "Method": "PROPORTIONAL"
          }
        ]

Outputs:
  ExportBucketArn:
    Description: CUR 2.0 destination bucket ARN.
    Value: !GetAtt ExportBucket.Arn
    Export:
      Name: !Sub '${AWS::StackName}-ExportBucketArn'
  CostCategoryArn:
    Description: BusinessUnit Cost Category ARN.
    Value: !Ref BusinessUnitCostCategory
```

> **Corrección al manifiesto de arriba:** el token suelto `talk:` dentro de `AllowDataExportsService` es un error de tipeo — borrá esa línea. La declaración debería decir `Action: [s3:PutObject, s3:GetBucketPolicy]` seguido directamente por `Resource:`. Validá con `aws cloudformation validate-template` antes de desplegar (sección 7.1).

### 5.2 CloudFormation — presupuestos, acciones de presupuesto y detección de anomalías

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >
  Cost guardrails: a monthly cost budget with actual and forecasted alerts,
  an automated budget action that attaches a deny policy at 100% of a
  sandbox budget, a Savings Plans coverage budget, and ML-based cost
  anomaly detection with a per-service monitor.

Parameters:
  FinOpsEmail:
    Type: String
    Default: finops@example.com
  MonthlyBudgetUsd:
    Type: Number
    Default: 45000
  SandboxBudgetUsd:
    Type: Number
    Default: 2000
  AlertTopicName:
    Type: String
    Default: finops-cost-alerts

Resources:

  CostAlertTopic:
    Type: AWS::SNS::Topic
    Properties:
      TopicName: !Ref AlertTopicName
      DisplayName: FinOps cost alerts
      KmsMasterKeyId: alias/aws/sns

  CostAlertTopicPolicy:
    Type: AWS::SNS::TopicPolicy
    Properties:
      Topics: [!Ref CostAlertTopic]
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: AllowBudgetsPublish
            Effect: Allow
            Principal:
              Service: budgets.amazonaws.com
            Action: sns:Publish
            Resource: !Ref CostAlertTopic
            Condition:
              StringEquals:
                aws:SourceAccount: !Ref AWS::AccountId
          - Sid: AllowCostAnomalyPublish
            Effect: Allow
            Principal:
              Service: costalerts.amazonaws.com
            Action: sns:Publish
            Resource: !Ref CostAlertTopic

  CostAlertSubscription:
    Type: AWS::SNS::Subscription
    Properties:
      TopicArn: !Ref CostAlertTopic
      Protocol: email
      Endpoint: !Ref FinOpsEmail

  # ------------------------------------------------------------------
  # Primary monthly cost budget. Note the four thresholds: three ACTUAL
  # tripwires and one FORECASTED. The forecasted alert is the only one
  # that gives you time to react; the others are post-mortems.
  # ------------------------------------------------------------------
  MonthlyCostBudget:
    Type: AWS::Budgets::Budget
    Properties:
      Budget:
        BudgetName: org-monthly-cost
        BudgetType: COST
        TimeUnit: MONTHLY
        BudgetLimit:
          Amount: !Ref MonthlyBudgetUsd
          Unit: USD
        CostTypes:
          IncludeTax: true
          IncludeSubscription: true
          UseBlended: false          # unblended: what each account actually incurred
          IncludeRefund: false
          IncludeCredit: false       # credits mask real consumption - exclude them
          IncludeUpfront: true
          IncludeRecurring: true
          IncludeOtherSubscription: true
          IncludeSupport: true
          IncludeDiscount: true
          UseAmortized: true         # amortized: spread SP/RI upfront across the term
      NotificationsWithSubscribers:
        - Notification:
            NotificationType: ACTUAL
            ComparisonOperator: GREATER_THAN
            Threshold: 60
            ThresholdType: PERCENTAGE
          Subscribers:
            - SubscriptionType: SNS
              Address: !Ref CostAlertTopic
        - Notification:
            NotificationType: ACTUAL
            ComparisonOperator: GREATER_THAN
            Threshold: 85
            ThresholdType: PERCENTAGE
          Subscribers:
            - SubscriptionType: SNS
              Address: !Ref CostAlertTopic
            - SubscriptionType: EMAIL
              Address: !Ref FinOpsEmail
        - Notification:
            NotificationType: ACTUAL
            ComparisonOperator: GREATER_THAN
            Threshold: 100
            ThresholdType: PERCENTAGE
          Subscribers:
            - SubscriptionType: SNS
              Address: !Ref CostAlertTopic
            - SubscriptionType: EMAIL
              Address: !Ref FinOpsEmail
        - Notification:
            NotificationType: FORECASTED
            ComparisonOperator: GREATER_THAN
            Threshold: 100
            ThresholdType: PERCENTAGE
          Subscribers:
            - SubscriptionType: SNS
              Address: !Ref CostAlertTopic
            - SubscriptionType: EMAIL
              Address: !Ref FinOpsEmail

  # ------------------------------------------------------------------
  # Sandbox budget scoped by cost allocation tag. This is why tagging
  # discipline matters: without the tag, this filter matches nothing
  # and the budget silently reports $0 forever.
  # ------------------------------------------------------------------
  SandboxBudget:
    Type: AWS::Budgets::Budget
    Properties:
      Budget:
        BudgetName: sandbox-monthly-cost
        BudgetType: COST
        TimeUnit: MONTHLY
        BudgetLimit:
          Amount: !Ref SandboxBudgetUsd
          Unit: USD
        CostFilters:
          TagKeyValue:
            - 'user:Environment$sandbox'
      NotificationsWithSubscribers:
        - Notification:
            NotificationType: ACTUAL
            ComparisonOperator: GREATER_THAN
            Threshold: 80
            ThresholdType: PERCENTAGE
          Subscribers:
            - SubscriptionType: SNS
              Address: !Ref CostAlertTopic

  # ------------------------------------------------------------------
  # Utilization/coverage budgets: these alert on the EFFICIENCY of
  # commitments, not on absolute dollars. A Savings Plan at 92%
  # utilization is leaking 8% of a fixed cost every hour.
  # ------------------------------------------------------------------
  SavingsPlansUtilizationBudget:
    Type: AWS::Budgets::Budget
    Properties:
      Budget:
        BudgetName: sp-utilization-floor
        BudgetType: SAVINGS_PLANS_UTILIZATION
        TimeUnit: MONTHLY
        BudgetLimit:
          Amount: 98
          Unit: PERCENTAGE
      NotificationsWithSubscribers:
        - Notification:
            NotificationType: ACTUAL
            ComparisonOperator: LESS_THAN
            Threshold: 98
            ThresholdType: PERCENTAGE
          Subscribers:
            - SubscriptionType: SNS
              Address: !Ref CostAlertTopic

  SavingsPlansCoverageBudget:
    Type: AWS::Budgets::Budget
    Properties:
      Budget:
        BudgetName: sp-coverage-floor
        BudgetType: SAVINGS_PLANS_COVERAGE
        TimeUnit: MONTHLY
        BudgetLimit:
          Amount: 70
          Unit: PERCENTAGE
      NotificationsWithSubscribers:
        - Notification:
            NotificationType: ACTUAL
            ComparisonOperator: LESS_THAN
            Threshold: 70
            ThresholdType: PERCENTAGE
          Subscribers:
            - SubscriptionType: SNS
              Address: !Ref CostAlertTopic

  # ------------------------------------------------------------------
  # Budget action: at 100% of the sandbox budget, attach a deny policy
  # to the sandbox role. ApprovalModel MANUAL means a human confirms;
  # switch to AUTOMATIC only once you trust the budget's accuracy.
  # ------------------------------------------------------------------
  BudgetActionRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: finops-budget-action-role
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: budgets.amazonaws.com
            Action: sts:AssumeRole
            Condition:
              StringEquals:
                aws:SourceAccount: !Ref AWS::AccountId
      Policies:
        - PolicyName: attach-restriction-policy
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - iam:AttachRolePolicy
                  - iam:DetachRolePolicy
                Resource: !Sub 'arn:${AWS::Partition}:iam::${AWS::AccountId}:role/SandboxEngineerRole'
              - Effect: Allow
                Action:
                  - iam:GetPolicy
                  - iam:ListEntitiesForPolicy
                Resource: !Ref SandboxDenyLaunchPolicy

  SandboxDenyLaunchPolicy:
    Type: AWS::IAM::ManagedPolicy
    Properties:
      ManagedPolicyName: sandbox-budget-breach-deny-launch
      Description: Attached automatically when the sandbox budget is exhausted.
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: DenyExpensiveLaunches
            Effect: Deny
            Action:
              - ec2:RunInstances
              - rds:CreateDBInstance
              - rds:CreateDBCluster
              - eks:CreateCluster
              - sagemaker:CreateNotebookInstance
              - sagemaker:CreateTrainingJob
            Resource: '*'

  SandboxBudgetAction:
    Type: AWS::Budgets::BudgetsAction
    Properties:
      BudgetName: !Ref SandboxBudget
      ActionType: APPLY_IAM_POLICY
      NotificationType: ACTUAL
      ApprovalModel: MANUAL
      ExecutionRoleArn: !GetAtt BudgetActionRole.Arn
      ActionThreshold:
        Type: PERCENTAGE
        Value: 100
      Definition:
        IamActionDefinition:
          PolicyArn: !Ref SandboxDenyLaunchPolicy
          Roles:
            - SandboxEngineerRole
      Subscribers:
        - Type: SNS
          Address: !Ref CostAlertTopic
        - Type: EMAIL
          Address: !Ref FinOpsEmail

  # ------------------------------------------------------------------
  # Cost Anomaly Detection. This is ML-based and catches what a static
  # budget structurally cannot: a 300% spike in one service inside an
  # otherwise on-budget month.
  # ------------------------------------------------------------------
  ServiceAnomalyMonitor:
    Type: AWS::CE::AnomalyMonitor
    Properties:
      MonitorName: all-services-monitor
      MonitorType: DIMENSIONAL
      MonitorDimension: SERVICE

  CostCategoryAnomalyMonitor:
    Type: AWS::CE::AnomalyMonitor
    Properties:
      MonitorName: business-unit-monitor
      MonitorType: CUSTOM
      MonitorSpecification: !Sub |
        {
          "CostCategories": {
            "Key": "BusinessUnit",
            "Values": ["PLATFORM", "PAYMENTS"],
            "MatchOptions": ["EQUALS"]
          }
        }

  AnomalySubscription:
    Type: AWS::CE::AnomalySubscription
    Properties:
      SubscriptionName: finops-anomaly-immediate
      Frequency: IMMEDIATE
      MonitorArnList:
        - !Ref ServiceAnomalyMonitor
        - !Ref CostCategoryAnomalyMonitor
      Subscribers:
        - Type: SNS
          Address: !Ref CostAlertTopic
          Status: CONFIRMED
      ThresholdExpression: !Sub |
        {
          "Dimensions": {
            "Key": "ANOMALY_TOTAL_IMPACT_ABSOLUTE",
            "Values": ["250"],
            "MatchOptions": ["GREATER_THAN_OR_EQUAL"]
          }
        }

Outputs:
  AlertTopicArn:
    Value: !Ref CostAlertTopic
  BudgetActionRoleArn:
    Value: !GetAtt BudgetActionRole.Arn
```

### 5.3 Terraform — gobernanza de etiquetas, el prerrequisito de toda atribución

```hcl
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

provider "aws" {
  region = "us-east-1"          # Organizations and billing APIs are us-east-1
}

locals {
  # The canonical tag contract. Every resource in every account carries these.
  # Changing this list is a governance decision, not a code change.
  required_tags = ["CostCenter", "Environment", "Owner", "Application"]

  allowed_environments = ["prod", "staging", "dev", "sandbox"]
}

# ---------------------------------------------------------------------
# Organizations tag policy: defines the CASE and the ALLOWED VALUES of
# tags. A tag policy does NOT require a tag to exist - it only governs
# the shape of the tag when present. Requiring existence is the SCP's job.
# ---------------------------------------------------------------------
resource "aws_organizations_policy" "cost_allocation_tags" {
  name        = "cost-allocation-tag-contract"
  description = "Normalizes cost allocation tag keys and constrains Environment values."
  type        = "TAG_POLICY"

  content = jsonencode({
    tags = {
      CostCenter = {
        tag_key = { "@@assign" = "CostCenter" }
        enforced_for = {
          "@@assign" = [
            "ec2:instance",
            "ec2:volume",
            "rds:db",
            "s3:bucket",
            "lambda:function",
            "elasticloadbalancing:loadbalancer",
          ]
        }
      }
      Environment = {
        tag_key    = { "@@assign" = "Environment" }
        tag_value  = { "@@assign" = local.allowed_environments }
        enforced_for = {
          "@@assign" = [
            "ec2:instance",
            "ec2:volume",
            "rds:db",
            "s3:bucket",
            "lambda:function",
          ]
        }
      }
      Owner = {
        tag_key = { "@@assign" = "Owner" }
      }
      Application = {
        tag_key = { "@@assign" = "Application" }
      }
    }
  })
}

resource "aws_organizations_policy_attachment" "tag_policy_root" {
  policy_id = aws_organizations_policy.cost_allocation_tags.id
  target_id = data.aws_organizations_organization.this.roots[0].id
}

data "aws_organizations_organization" "this" {}

# ---------------------------------------------------------------------
# SCP: hard-deny creation of billable resources without the required
# tags. This is the enforcement point. Note the aws:RequestTag/Null
# condition - it fails the API call at creation time, which is the only
# moment at which tagging is free.
# ---------------------------------------------------------------------
resource "aws_organizations_policy" "deny_untagged_billable" {
  name        = "deny-untagged-billable-resources"
  description = "Denies creation of the highest-cost resource types without cost allocation tags."
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyRunInstancesWithoutCostTags"
        Effect = "Deny"
        Action = [
          "ec2:RunInstances",
        ]
        Resource = [
          "arn:aws:ec2:*:*:instance/*",
          "arn:aws:ec2:*:*:volume/*",
        ]
        Condition = {
          "Null" = {
            for tag in local.required_tags :
            "aws:RequestTag/${tag}" => "true"
          }
        }
      },
      {
        Sid    = "DenyManagedServiceCreationWithoutCostTags"
        Effect = "Deny"
        Action = [
          "rds:CreateDBInstance",
          "rds:CreateDBCluster",
          "eks:CreateCluster",
          "elasticache:CreateCacheCluster",
          "es:CreateDomain",
          "sagemaker:CreateNotebookInstance",
          "redshift:CreateCluster",
        ]
        Resource = "*"
        Condition = {
          "Null" = {
            "aws:RequestTag/CostCenter"  = "true"
            "aws:RequestTag/Environment" = "true"
          }
        }
      },
      {
        Sid    = "DenyTagRemoval"
        Effect = "Deny"
        Action = [
          "ec2:DeleteTags",
          "rds:RemoveTagsFromResource",
        ]
        Resource = "*"
        Condition = {
          "ForAnyValue:StringEquals" = {
            "aws:TagKeys" = local.required_tags
          }
        }
      },
    ]
  })
}

resource "aws_organizations_policy_attachment" "scp_workload_ou" {
  policy_id = aws_organizations_policy.deny_untagged_billable.id
  target_id = var.workload_ou_id
}

variable "workload_ou_id" {
  type        = string
  description = "OU containing workload accounts. Never attach to root without a tested exception path."
}

# ---------------------------------------------------------------------
# AWS Config rule: detection for what the SCP cannot cover (resources
# created before the SCP, or by services the SCP does not gate).
# ---------------------------------------------------------------------
resource "aws_config_config_rule" "required_cost_tags" {
  name        = "required-cost-allocation-tags"
  description = "Flags resources missing cost allocation tags."

  source {
    owner             = "AWS"
    source_identifier = "REQUIRED_TAGS"
  }

  input_parameters = jsonencode({
    tag1Key = "CostCenter"
    tag2Key = "Environment"
    tag3Key = "Owner"
    tag4Key = "Application"
  })

  scope {
    compliance_resource_types = [
      "AWS::EC2::Instance",
      "AWS::EC2::Volume",
      "AWS::RDS::DBInstance",
      "AWS::S3::Bucket",
      "AWS::Lambda::Function",
      "AWS::ElasticLoadBalancingV2::LoadBalancer",
    ]
  }
}

# ---------------------------------------------------------------------
# Default tags applied by the provider to every resource this stack
# manages. Belt and braces: the SCP denies, this guarantees compliance.
# ---------------------------------------------------------------------
provider "aws" {
  alias  = "tagged"
  region = "us-east-1"

  default_tags {
    tags = {
      CostCenter  = "PLATFORM-1000"
      Environment = "shared"
      Owner       = "platform-sre"
      Application = "finops-governance"
      ManagedBy   = "terraform"
    }
  }
}
```

### 5.4 EventBridge Scheduler — apagado de no-producción (la automatización de mayor ROI)

Los workloads de no-producción que corren 24×7 se facturan por 168 horas por semana y se usan unas 45. Apagarlos fuera del horario laboral elimina ~65% del costo de cómputo de no-producción con riesgo arquitectónico nulo.

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >
  Stops tagged non-production EC2 and RDS instances outside business hours.
  168 hr/week -> 60 hr/week for the tagged fleet.

Parameters:
  ScheduleTimezone:
    Type: String
    Default: America/Argentina/Buenos_Aires
  TargetTagKey:
    Type: String
    Default: Schedule
  TargetTagValue:
    Type: String
    Default: office-hours

Resources:

  SchedulerRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: scheduler.amazonaws.com
            Action: sts:AssumeRole
            Condition:
              StringEquals:
                aws:SourceAccount: !Ref AWS::AccountId
      Policies:
        - PolicyName: invoke-ssm-automation
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action: ssm:StartAutomationExecution
                Resource: !Sub 'arn:${AWS::Partition}:ssm:${AWS::Region}:*:automation-definition/*'
              - Effect: Allow
                Action: iam:PassRole
                Resource: !GetAtt AutomationRole.Arn

  AutomationRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: ssm.amazonaws.com
            Action: sts:AssumeRole
      Policies:
        - PolicyName: stop-start-tagged-instances
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - ec2:DescribeInstances
                  - ec2:DescribeInstanceStatus
                  - rds:DescribeDBInstances
                Resource: '*'
              - Effect: Allow
                Action:
                  - ec2:StopInstances
                  - ec2:StartInstances
                Resource: '*'
                Condition:
                  StringEquals:
                    !Sub 'aws:ResourceTag/${TargetTagKey}': !Ref TargetTagValue
              - Effect: Allow
                Action:
                  - rds:StopDBInstance
                  - rds:StartDBInstance
                Resource: '*'
                Condition:
                  StringEquals:
                    !Sub 'aws:ResourceTag/${TargetTagKey}': !Ref TargetTagValue

  StopSchedule:
    Type: AWS::Scheduler::Schedule
    Properties:
      Name: nonprod-stop-evening
      Description: Stop tagged non-prod instances at 20:00 on weekdays.
      GroupName: default
      State: ENABLED
      FlexibleTimeWindow:
        Mode: FLEXIBLE
        MaximumWindowInMinutes: 15
      ScheduleExpression: 'cron(0 20 ? * MON-FRI *)'
      ScheduleExpressionTimezone: !Ref ScheduleTimezone
      Target:
        Arn: !Sub 'arn:${AWS::Partition}:scheduler:::aws-sdk:ssm:startAutomationExecution'
        RoleArn: !GetAtt SchedulerRole.Arn
        RetryPolicy:
          MaximumRetryAttempts: 3
          MaximumEventAgeInSeconds: 3600
        Input: !Sub |
          {
            "DocumentName": "AWS-StopEC2InstanceWithTags",
            "Parameters": {
              "AutomationAssumeRole": ["${AutomationRole.Arn}"],
              "TagKey": ["${TargetTagKey}"],
              "TagValue": ["${TargetTagValue}"]
            }
          }

  StartSchedule:
    Type: AWS::Scheduler::Schedule
    Properties:
      Name: nonprod-start-morning
      Description: Start tagged non-prod instances at 08:00 on weekdays.
      GroupName: default
      State: ENABLED
      FlexibleTimeWindow:
        Mode: 'OFF'
      ScheduleExpression: 'cron(0 8 ? * MON-FRI *)'
      ScheduleExpressionTimezone: !Ref ScheduleTimezone
      Target:
        Arn: !Sub 'arn:${AWS::Partition}:scheduler:::aws-sdk:ssm:startAutomationExecution'
        RoleArn: !GetAtt SchedulerRole.Arn
        RetryPolicy:
          MaximumRetryAttempts: 3
          MaximumEventAgeInSeconds: 3600
        Input: !Sub |
          {
            "DocumentName": "AWS-StartEC2InstanceWithTags",
            "Parameters": {
              "AutomationAssumeRole": ["${AutomationRole.Arn}"],
              "TagKey": ["${TargetTagKey}"],
              "TagValue": ["${TargetTagValue}"]
            }
          }
```

### 5.5 Kubernetes — consolidación con Karpenter, cuotas y visibilidad de costos

En EKS, el costo del clúster está dominado por la *capacidad de nodos no utilizada*, no por los pods. La consolidación de Karpenter es el equivalente dentro del clúster al rightsizing.

```yaml
---
# EC2NodeClass: the AWS-level shape of the nodes Karpenter provisions.
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: cost-optimized
spec:
  amiFamily: AL2023
  amiSelectorTerms:
    - alias: al2023@latest
  role: KarpenterNodeRole-prod-cluster
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: prod-cluster
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: prod-cluster
  # gp3 over gp2: ~20% cheaper per GB and IOPS are decoupled from size,
  # so you stop over-provisioning capacity just to buy throughput.
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 60Gi
        volumeType: gp3
        iops: 3000
        throughput: 125
        encrypted: true
        deleteOnTermination: true
  metadataOptions:
    httpEndpoint: enabled
    httpProtocolIPv6: disabled
    httpPutResponseHopLimit: 1
    httpTokens: required
  # Cost allocation tags propagate to every EC2 instance and EBS volume
  # Karpenter creates. Without this the cluster's compute is unattributable.
  tags:
    CostCenter: PLATFORM-1000
    Environment: prod
    Owner: platform-sre
    Application: eks-prod-cluster
    ManagedBy: karpenter
---
# Spot-first NodePool for interruption-tolerant workloads.
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: spot-general
spec:
  template:
    metadata:
      labels:
        capacity-profile: spot-general
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: cost-optimized
      expireAfter: 168h        # forced rotation weekly: patching + drift control
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot"]
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64", "arm64"]     # allow Graviton: ~10-20% cheaper
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["c", "m", "r"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["5"]                  # newer generations: better price/perf
        - key: karpenter.k8s.aws/instance-cpu
          operator: In
          values: ["2", "4", "8", "16"]
      taints:
        - key: capacity-type
          value: spot
          effect: NoSchedule
  # Consolidation is the money. WhenEmptyOrUnderutilized lets Karpenter
  # replace a node with a cheaper one, or bin-pack pods onto fewer nodes.
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
    budgets:
      - nodes: "10%"                     # steady-state churn cap
      - nodes: "0"                       # freeze during business hours
        schedule: "0 13 * * mon-fri"
        duration: 8h
        reasons:
          - Underutilized
  limits:
    cpu: "2000"
    memory: 8000Gi
  weight: 100                            # preferred over on-demand pool
---
# On-demand fallback for workloads that cannot tolerate interruption.
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: ondemand-critical
spec:
  template:
    metadata:
      labels:
        capacity-profile: ondemand-critical
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: cost-optimized
      expireAfter: 720h
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["m", "c"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["5"]
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 5m
    budgets:
      - nodes: "5%"
  limits:
    cpu: "500"
    memory: 2000Gi
  weight: 10
---
# ResourceQuota: the in-cluster budget. A namespace cannot request more
# capacity than it is funded for. This is the cluster analogue of an
# AWS Budget with a budget action.
apiVersion: v1
kind: ResourceQuota
metadata:
  name: payments-quota
  namespace: payments
spec:
  hard:
    requests.cpu: "120"
    requests.memory: 480Gi
    limits.cpu: "240"
    limits.memory: 960Gi
    requests.storage: 2Ti
    persistentvolumeclaims: "40"
    count/deployments.apps: "60"
    services.loadbalancers: "4"          # each NLB/ALB is a recurring charge
---
# LimitRange: prevents the two classic cost bugs - pods with no requests
# (unschedulable capacity accounting, node sprawl) and pods that request
# an absurd amount and pin an entire node.
apiVersion: v1
kind: LimitRange
metadata:
  name: payments-defaults
  namespace: payments
spec:
  limits:
    - type: Container
      default:
        cpu: 500m
        memory: 512Mi
      defaultRequest:
        cpu: 100m
        memory: 128Mi
      max:
        cpu: "8"
        memory: 32Gi
      min:
        cpu: 10m
        memory: 32Mi
      maxLimitRequestRatio:
        cpu: "8"
        memory: "4"
---
# VerticalPodAutoscaler in recommendation-only mode: it computes the
# rightsizing answer without acting on it. Read the recommendation,
# put it in Git, deploy it. Never let VPA mutate production silently.
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: payments-api-vpa
  namespace: payments
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: payments-api
  updatePolicy:
    updateMode: "Off"
  resourcePolicy:
    containerPolicies:
      - containerName: '*'
        minAllowed:
          cpu: 50m
          memory: 64Mi
        maxAllowed:
          cpu: "4"
          memory: 8Gi
        controlledResources: ["cpu", "memory"]
---
# OpenCost: maps Kubernetes workloads back to AWS billing data, so a
# namespace's cost is a real number derived from the CUR, not an estimate.
apiVersion: v1
kind: ConfigMap
metadata:
  name: opencost-config
  namespace: opencost
data:
  # Points OpenCost at the CUR-derived pricing, not at public list price.
  CLOUD_PROVIDER_API_KEY: ""
  CLUSTER_ID: "prod-cluster"
  AWS_CLUSTER_ID: "prod-cluster"
  CONFIG_PATH: "/var/configs/"
  PROMETHEUS_SERVER_ENDPOINT: "http://prometheus-server.monitoring.svc:80"
  EMIT_POD_ANNOTATIONS_METRIC: "true"
  EMIT_NAMESPACE_ANNOTATIONS_METRIC: "true"
```

### 5.6 Athena — la consulta de costo amortizado que toda práctica de FinOps necesita

Cost Explorer responde preguntas; el CUR responde preguntas *arbitrarias*. Esta es la expresión canónica de costo amortizado — convierte líneas de detalle crudas en el número que finanzas realmente reconoce.

```sql
-- Amortized cost by BusinessUnit cost category and service, last full month.
-- The CASE expression is the whole point: unblended cost double-counts
-- Savings Plan upfront fees and undercounts covered usage. Amortized cost
-- spreads commitments across the term they were bought for.

WITH amortized AS (
  SELECT
    line_item_usage_account_id                                  AS account_id,
    line_item_product_code                                      AS service,
    resource_tags['user_costcenter']                            AS cost_center,
    resource_tags['user_environment']                           AS environment,
    cost_category['businessunit']                               AS business_unit,
    line_item_resource_id                                       AS resource_id,
    line_item_usage_start_date                                  AS usage_start,
    CASE
      WHEN line_item_line_item_type = 'SavingsPlanCoveredUsage'
        THEN savings_plan_savings_plan_effective_cost
      WHEN line_item_line_item_type = 'SavingsPlanRecurringFee'
        THEN savings_plan_total_commitment_to_date - savings_plan_used_commitment
      WHEN line_item_line_item_type = 'SavingsPlanNegation'  THEN 0
      WHEN line_item_line_item_type = 'SavingsPlanUpfrontFee' THEN 0
      WHEN line_item_line_item_type = 'DiscountedUsage'
        THEN reservation_effective_cost
      WHEN line_item_line_item_type = 'RIFee'
        THEN reservation_unused_amortized_upfront_fee_for_billing_period
           + reservation_unused_recurring_fee
      WHEN line_item_line_item_type = 'Fee'
           AND reservation_reservation_a_r_n <> '' THEN 0
      ELSE line_item_unblended_cost
    END                                                         AS amortized_cost,
    line_item_unblended_cost                                    AS unblended_cost
  FROM cur2.cost_and_usage_report
  WHERE billing_period = DATE_FORMAT(DATE_ADD('month', -1, CURRENT_DATE), '%Y-%m')
)
SELECT
  COALESCE(business_unit, 'UNALLOCATED')                        AS business_unit,
  COALESCE(cost_center,  'UNTAGGED')                            AS cost_center,
  service,
  ROUND(SUM(amortized_cost), 2)                                 AS amortized_usd,
  ROUND(SUM(unblended_cost), 2)                                 AS unblended_usd,
  ROUND(SUM(unblended_cost) - SUM(amortized_cost), 2)           AS commitment_delta,
  COUNT(DISTINCT resource_id)                                   AS resources
FROM amortized
GROUP BY 1, 2, 3
HAVING SUM(amortized_cost) > 50
ORDER BY amortized_usd DESC
LIMIT 50;
```

```sql
-- The tag coverage metric. If this is below ~95%, every optimization
-- decision downstream is guesswork. Track it as an SLI.

SELECT
  DATE_TRUNC('day', line_item_usage_start_date)                 AS day,
  ROUND(
    100.0 * SUM(CASE WHEN resource_tags['user_costcenter'] IS NOT NULL
                      AND resource_tags['user_costcenter'] <> ''
                     THEN line_item_unblended_cost ELSE 0 END)
    / NULLIF(SUM(line_item_unblended_cost), 0), 2)              AS tagged_pct,
  ROUND(SUM(line_item_unblended_cost), 2)                       AS total_usd,
  ROUND(SUM(CASE WHEN resource_tags['user_costcenter'] IS NULL
                   OR resource_tags['user_costcenter'] = ''
                 THEN line_item_unblended_cost ELSE 0 END), 2)  AS untagged_usd
FROM cur2.cost_and_usage_report
WHERE line_item_line_item_type IN ('Usage', 'DiscountedUsage', 'SavingsPlanCoveredUsage')
  AND line_item_usage_start_date >= DATE_ADD('day', -30, CURRENT_DATE)
GROUP BY 1
ORDER BY 1 DESC;
```

---

## 6. Operaciones por CLI — Comandos Reales y Salida Esperada

Todas las llamadas a Cost Explorer / Budgets / Pricing apuntan a `us-east-1` sin importar dónde corran tus workloads.

### 6.1 Línea base: ¿qué gastamos realmente, por servicio?

```bash
$ aws ce get-cost-and-usage \
    --time-period Start=2026-08-01,End=2026-09-01 \
    --granularity MONTHLY \
    --metrics "UnblendedCost" "AmortizedCost" "UsageQuantity" \
    --group-by Type=DIMENSION,Key=SERVICE \
    --region us-east-1 \
    --query 'ResultsByTime[0].Groups[?Metrics.AmortizedCost.Amount > `1000`].[Keys[0],Metrics.AmortizedCost.Amount]' \
    --output table
```

```
-------------------------------------------------------------------
|                        GetCostAndUsage                          |
+-------------------------------------------+---------------------+
|  Amazon Elastic Compute Cloud - Compute    |  7104.3382914       |
|  Amazon Relational Database Service        |  3186.9021447       |
|  EC2 - Other                               |  8221.7743190       |
|  Amazon Simple Storage Service             |  1841.2205613       |
|  Amazon Elastic Container Service for K8s  |  1093.8000000       |
|  AWS Data Transfer                         |  1226.4471028       |
+-------------------------------------------+---------------------+
```

**Leé esto como un SRE, no como un contador.** `EC2 - Other` con $8.221 supera a `EC2 - Compute` con $7.104. Esa línea son volúmenes de EBS, snapshots, horas y procesamiento de NAT Gateway, e IPs elásticas. **Cuando `EC2 - Other` pesa más que `EC2 - Compute`, tenés un problema de almacenamiento o de NAT Gateway, no un problema de cómputo** — y es invisible en todo dashboard que solo grafique "EC2".

Profundizá en eso:

```bash
$ aws ce get-cost-and-usage \
    --time-period Start=2026-08-01,End=2026-09-01 \
    --granularity MONTHLY \
    --metrics "UnblendedCost" \
    --filter '{"Dimensions":{"Key":"SERVICE","Values":["EC2 - Other"]}}' \
    --group-by Type=DIMENSION,Key=USAGE_TYPE \
    --region us-east-1 \
    --query 'ResultsByTime[0].Groups[:8].[Keys[0],Metrics.UnblendedCost.Amount]' \
    --output text
```

```
USE1-EBS:VolumeUsage.gp3        3908.16
USE1-NatGateway-Bytes           1943.55
USE1-EBS:SnapshotUsage          1204.80
USE1-NatGateway-Hours            131.40
USE1-EBS:VolumeUsage.gp2         702.11
USE1-EBS:VolumeP-IOPS.piops      196.22
USE1-EBS:VolumeUsage.io1          89.44
USE1-ElasticIP:IdleAddress        46.06
```

Tres hallazgos accionables en ocho líneas: $702 todavía en gp2 (migrar a gp3, ~20% más barato), $1.943 de procesamiento de datos de NAT Gateway (un VPC endpoint para S3/ECR eliminaría la mayor parte) y $46 de IPs elásticas ociosas (desperdicio puro).

### 6.2 Recomendaciones de rightsizing

```bash
$ aws ce get-rightsizing-recommendation \
    --service "AmazonEC2" \
    --configuration '{"RecommendationTarget":"SAME_INSTANCE_FAMILY","BenefitsConsidered":true}' \
    --region us-east-1 \
    --query 'Summary'
```

```json
{
    "TotalRecommendationCount": "47",
    "EstimatedTotalMonthlySavingsAmount": "2841.66",
    "SavingsCurrencyCode": "USD",
    "SavingsPercentage": "18.4"
}
```

```bash
$ aws ce get-rightsizing-recommendation \
    --service "AmazonEC2" \
    --configuration '{"RecommendationTarget":"CROSS_INSTANCE_FAMILY","BenefitsConsidered":true}' \
    --region us-east-1 \
    --query 'RightsizingRecommendations[?RightsizingType==`Modify`] | [:3].{
        Instance: CurrentInstance.ResourceId,
        Current:  CurrentInstance.ResourceDetails.EC2ResourceDetails.InstanceType,
        MaxCpu:   CurrentInstance.ResourceUtilization.EC2ResourceUtilization.MaxCpuUtilizationPercentage,
        MaxMem:   CurrentInstance.ResourceUtilization.EC2ResourceUtilization.MaxMemoryUtilizationPercentage,
        Target:   ModifyRecommendationDetail.TargetInstances[0].ResourceDetails.EC2ResourceDetails.InstanceType,
        Saving:   ModifyRecommendationDetail.TargetInstances[0].EstimatedMonthlySavings
    }' --output table
```

```
------------------------------------------------------------------------------------------
|                        GetRightsizingRecommendation                                    |
+----------+------------+---------+---------+--------------+-------------+---------------+
| Current  | Instance   | MaxCpu  | MaxMem  | Saving       | Target      |               |
+----------+------------+---------+---------+--------------+-------------+---------------+
| m5.4xlarge | i-0a3f8c21b94de7016 | 9.4 | 22.1 | 292.00  | m6i.xlarge  |               |
| r5.2xlarge | i-07c4e1a8f2b30d955 | 6.1 | 18.7 | 186.88  | r6i.large   |               |
| c5.9xlarge | i-0b91d7e3a6c48f220 | 14.8| 31.2 | 612.36  | c6i.2xlarge |               |
+----------+------------+---------+---------+--------------+-------------+---------------+
```

**Nota de diagnóstico:** si `MaxMemoryUtilizationPercentage` vuelve como `null`, el agente de CloudWatch no está publicando métricas de memoria en esas instancias. La memoria no es una métrica visible para el hipervisor en EC2 — AWS no puede verla. Las recomendaciones hechas sin ella son solo de CPU y van a subdimensionar workloads limitados por memoria hasta llevarlos a OOM kills. Instalá el agente de CloudWatch antes de confiar en una reducción de tamaño.

```bash
# Compute Optimizer gives a richer signal, including a performance-risk score.
$ aws compute-optimizer get-ec2-instance-recommendations \
    --filters name=Finding,values=Overprovisioned \
    --query 'instanceRecommendations[:2].{
        Id: instanceArn,
        Type: currentInstanceType,
        Finding: finding,
        Reasons: findingReasonCodes,
        Rec: recommendationOptions[0].instanceType,
        Risk: recommendationOptions[0].performanceRisk,
        Savings: recommendationOptions[0].savingsOpportunity.estimatedMonthlySavings.value
    }' --output json
```

```json
[
    {
        "Id": "arn:aws:ec2:us-east-1:111122223333:instance/i-0a3f8c21b94de7016",
        "Type": "m5.4xlarge",
        "Finding": "OVER_PROVISIONED",
        "Reasons": [
            "CPUOverprovisioned",
            "MemoryOverprovisioned",
            "EBSThroughputOverprovisioned"
        ],
        "Rec": "m6i.xlarge",
        "Risk": 1.0,
        "Savings": 292.0
    },
    {
        "Id": "arn:aws:ec2:us-east-1:111122223333:instance/i-0b91d7e3a6c48f220",
        "Type": "c5.9xlarge",
        "Finding": "OVER_PROVISIONED",
        "Reasons": ["CPUOverprovisioned"],
        "Rec": "c6i.2xlarge",
        "Risk": 2.0,
        "Savings": 612.36
    }
]
```

`performanceRisk` va de 0 a 4. Tratá 0–1 como seguro de aplicar, 2 como que requiere una prueba de carga, 3–4 como no-aplicar-a-ciegas.

### 6.3 Savings Plans — recomendación, y luego verificación de la utilización

```bash
$ aws ce get-savings-plans-purchase-recommendation \
    --savings-plans-type COMPUTE_SP \
    --term-in-years ONE_YEAR \
    --payment-option NO_UPFRONT \
    --lookback-period-in-days SIXTY_DAYS \
    --region us-east-1 \
    --query 'SavingsPlansPurchaseRecommendation.SavingsPlansPurchaseRecommendationSummary'
```

```json
{
    "EstimatedROI": "23.71",
    "CurrencyCode": "USD",
    "EstimatedTotalCost": "62481.60",
    "CurrentOnDemandSpend": "81953.28",
    "EstimatedSavingsAmount": "19471.68",
    "TotalRecommendationCount": "1",
    "DailyCommitmentToPurchase": "171.18",
    "HourlyCommitmentToPurchase": "7.13",
    "EstimatedSavingsPercentage": "23.76",
    "EstimatedMonthlySavingsAmount": "1622.64",
    "EstimatedOnDemandCostWithCurrentCommitment": "81953.28"
}
```

**No compres esto todavía.** La recomendación se deriva de un lookback de 60 días del uso *actual* — que todavía contiene el 18,4% de desperdicio de rightsizing de la sección 6.2. Hacé rightsizing primero, esperá 14 días a que la ventana de lookback refleje la nueva línea base y después volvé a correr este comando. Comprometerse ahora fijaría un descuento sobre instancias que estás por eliminar.

Verificá que los compromisos existentes se estén consumiendo de verdad:

```bash
$ aws ce get-savings-plans-utilization \
    --time-period Start=2026-08-01,End=2026-09-01 \
    --granularity MONTHLY \
    --region us-east-1 \
    --query 'Total'
```

```json
{
    "Utilization": {
        "TotalCommitment": "5204.90",
        "UsedCommitment": "5204.90",
        "UnusedCommitment": "0.00",
        "UtilizationPercentage": "100"
    },
    "Savings": {
        "NetSavings": "1489.22",
        "OnDemandCostEquivalent": "6694.12"
    },
    "AmortizedCommitment": {
        "AmortizedRecurringCommitment": "5204.90",
        "AmortizedUpfrontCommitment": "0.00",
        "TotalAmortizedCommitment": "5204.90"
    }
}
```

```bash
# Coverage answers the opposite question: how much On-Demand is still uncovered?
$ aws ce get-savings-plans-coverage \
    --time-period Start=2026-08-01,End=2026-09-01 \
    --granularity MONTHLY \
    --region us-east-1 \
    --query 'SavingsPlansCoverages[0].Coverage'
```

```json
{
    "SpendCoveredBySavingsPlans": "6694.12",
    "OnDemandCost": "1876.40",
    "TotalCost": "8570.52",
    "CoveragePercentage": "78.11"
}
```

Utilización del 100% + cobertura del 78% es una posición saludable: todo lo comprometido se consume, y el 22% queda como On-Demand a modo de margen de elasticidad. **Una utilización por debajo del 100% es una fuga de caja directa y continua** — estás pagando por una tasa de compromiso que no consumís. La cobertura al 100% *también* es un problema: significa que te comprometiste con tu pico, y ahora cada evento de scale-down desperdicia compromiso.

### 6.4 Presupuestos y anomalías

```bash
$ aws budgets describe-budgets \
    --account-id 111122223333 \
    --query 'Budgets[].{Name:BudgetName,Type:BudgetType,Limit:BudgetLimit.Amount,
             Actual:CalculatedSpend.ActualSpend.Amount,
             Forecast:CalculatedSpend.ForecastedSpend.Amount}' \
    --output table
```

```
------------------------------------------------------------------------------
|                              DescribeBudgets                               |
+---------------------+--------+----------+------------+---------------------+
|  org-monthly-cost   | COST   |  45000   |  38412.77  |  46903.55           |
|  sandbox-monthly-cost| COST  |  2000    |   1744.02  |   2119.88           |
|  sp-utilization-floor| SAVINGS_PLANS_UTILIZATION | 98 | 100.0 | None      |
|  sp-coverage-floor  | SAVINGS_PLANS_COVERAGE | 70 | 78.11 | None           |
+---------------------+--------+----------+------------+---------------------+
```

El pronóstico ($46.903) excede el límite ($45.000) mientras que el gasto real todavía está por debajo. **Esta es la alerta que tiene valor** — se dispara con aproximadamente diez días de margen para actuar, mientras que la alerta de real-100% se dispara cuando la plata ya se gastó.

```bash
$ aws ce get-anomalies \
    --date-interval StartDate=2026-08-01,EndDate=2026-09-01 \
    --total-impact NumericOperator=GREATER_THAN_OR_EQUAL,StartValue=200 \
    --region us-east-1 \
    --query 'Anomalies[].{Start:AnomalyStartDate,End:AnomalyEndDate,
             Service:RootCauses[0].Service,Region:RootCauses[0].Region,
             UsageType:RootCauses[0].UsageType,
             Impact:Impact.TotalImpact,Expected:Impact.TotalExpectedSpend,
             Actual:Impact.TotalActualSpend}' --output json
```

```json
[
    {
        "Start": "2026-08-17T00:00:00Z",
        "End": "2026-08-19T00:00:00Z",
        "Service": "Amazon Elastic Compute Cloud - Compute",
        "Region": "eu-west-1",
        "UsageType": "EUW1-BoxUsage:p4d.24xlarge",
        "Impact": 4218.72,
        "Expected": 91.28,
        "Actual": 4310.0
    },
    {
        "Start": "2026-08-24T00:00:00Z",
        "End": "2026-08-26T00:00:00Z",
        "Service": "AWS Data Transfer",
        "Region": "us-east-1",
        "UsageType": "USE1-USW2-AWS-Out-Bytes",
        "Impact": 612.4,
        "Expected": 148.9,
        "Actual": 761.3
    }
]
```

La primera anomalía es la clásica: instancias GPU lanzadas en una región que nadie monitorea, y después dejadas corriendo todo un fin de semana. La región `eu-west-1` y un gasto esperado de $91 te dicen que esta cuenta esencialmente no tiene huella legítima allí. Un presupuesto mensual estático nunca lo habría detectado — $4.218 está dentro del ruido de un presupuesto de $45.000.

### 6.5 Encontrar desperdicio que ningún motor de recomendaciones reporta

```bash
# Unattached EBS volumes - billed at full rate, attached to nothing.
$ aws ec2 describe-volumes \
    --filters Name=status,Values=available \
    --query 'Volumes[].{Id:VolumeId,Size:Size,Type:VolumeType,
             Created:CreateTime,AZ:AvailabilityZone,
             Name:Tags[?Key==`Name`]|[0].Value}' \
    --output table
```

```
-------------------------------------------------------------------------------------
|                                 DescribeVolumes                                   |
+------------+-------+--------+---------------------------+-------------+-----------+
|  vol-0c8d21e9f4a7b3306 | 500 | gp3 | 2025-11-04T09:12:44+00:00 | us-east-1a | old-etl-scratch |
|  vol-04f1a76bc90e5d283 | 200 | gp2 | 2026-02-18T14:03:09+00:00 | us-east-1b | None            |
|  vol-0e5b3d8912af6c740 |1000 | io1 | 2025-08-27T22:41:55+00:00 | us-east-1c | db-restore-test |
+------------+-------+--------+---------------------------+-------------+-----------+
```

1.700 GB de almacenamiento huérfano, uno de ellos con Provisioned IOPS. A tarifas de gp3/io1 eso son varios cientos de dólares por mes por cero valor entregado, y viene acumulándose desde 2025.

```bash
# Idle Elastic IPs: charged per hour when NOT associated.
$ aws ec2 describe-addresses \
    --query 'Addresses[?AssociationId==`null`].[PublicIp,AllocationId,Domain]' \
    --output text
```

```
52.203.118.44   eipalloc-0f39c72e18a4b6d05   vpc
3.221.86.190    eipalloc-0a7d51fc3e920b8c1   vpc
54.163.201.77   eipalloc-0c14e8b92df370a66   vpc
```

```bash
# Load balancers with zero registered healthy targets.
$ for tg in $(aws elbv2 describe-target-groups --query 'TargetGroups[].TargetGroupArn' --output text); do
    n=$(aws elbv2 describe-target-health --target-group-arn "$tg" \
          --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])' --output text)
    [ "$n" = "0" ] && echo "EMPTY  $tg"
  done
```

```
EMPTY  arn:aws:elasticloadbalancing:us-east-1:111122223333:targetgroup/legacy-api-tg/8f2c91a04b7e6d33
EMPTY  arn:aws:elasticloadbalancing:us-east-1:111122223333:targetgroup/blue-deploy-tg/1a6b39e5c2d84f70
```

```bash
# Snapshots older than a year with no lifecycle policy governing them.
$ aws ec2 describe-snapshots --owner-ids self \
    --query "Snapshots[?StartTime<='2025-09-03'].[SnapshotId,VolumeSize,StartTime,Description]" \
    --output text | head -5
```

```
snap-0a91c7e34b8d2f605  500  2025-03-14T06:00:12+00:00  Created by CreateImage(i-0b3e...)
snap-04d82f16ac9b7e310  200  2025-01-08T06:00:07+00:00  daily-backup-legacy-etl
snap-0e73b95d2c18af446  1000 2024-12-19T06:00:11+00:00  pre-migration-snapshot
snap-0f2a4c86e91b573d8  120  2025-05-02T06:00:09+00:00  ad-hoc before schema change
```

### 6.6 Price List API — derivar precios unitarios en lugar de recordarlos

Nunca hardcodees un precio de memoria. Consultalo.

```bash
$ aws pricing get-products \
    --service-code AmazonEC2 \
    --region us-east-1 \
    --filters \
      Type=TERM_MATCH,Field=instanceType,Value=m6i.large \
      Type=TERM_MATCH,Field=location,Value="US East (N. Virginia)" \
      Type=TERM_MATCH,Field=operatingSystem,Value=Linux \
      Type=TERM_MATCH,Field=tenancy,Value=Shared \
      Type=TERM_MATCH,Field=preInstalledSw,Value=NA \
      Type=TERM_MATCH,Field=capacitystatus,Value=Used \
    --query 'PriceList[0]' --output text | \
  python3 -c "import json,sys; d=json.load(sys.stdin); \
    od=d['terms']['OnDemand']; t=list(od.values())[0]; \
    p=list(t['priceDimensions'].values())[0]; \
    print(p['unit'], p['pricePerUnit']['USD'], '|', p['description'])"
```

```
Hrs 0.0960000000 | $0.096 per On Demand Linux m6i.large Instance Hour
```

```bash
# The same instance with Windows License Included - the licensing delta,
# measured rather than assumed.
$ aws pricing get-products \
    --service-code AmazonEC2 --region us-east-1 \
    --filters \
      Type=TERM_MATCH,Field=instanceType,Value=m6i.large \
      Type=TERM_MATCH,Field=location,Value="US East (N. Virginia)" \
      Type=TERM_MATCH,Field=operatingSystem,Value=Windows \
      Type=TERM_MATCH,Field=tenancy,Value=Shared \
      Type=TERM_MATCH,Field=preInstalledSw,Value=NA \
      Type=TERM_MATCH,Field=licenseModel,Value="License Included" \
      Type=TERM_MATCH,Field=capacitystatus,Value=Used \
    --query 'PriceList[0]' --output text | \
  python3 -c "import json,sys; d=json.load(sys.stdin); \
    t=list(d['terms']['OnDemand'].values())[0]; \
    p=list(t['priceDimensions'].values())[0]; \
    print(p['pricePerUnit']['USD'])"
```

```
0.1880000000
```

$0,188 vs $0,096 — la licencia de Windows cuesta $0,092/hr, **el 96% del precio de la instancia**, o ~$806/año por instancia. En un parque de 200 instancias Windows eso son $161.000/año en tarifas de License Included. Ese único número es lo que hace que valga la pena un análisis de BYOL-sobre-Dedicated-Hosts, y es derivable en una sola llamada a la API.

### 6.7 License Manager — probar el cumplimiento en lugar de esperar que se cumpla

```bash
$ aws license-manager list-license-configurations \
    --query 'LicenseConfigurations[].{Name:Name,Type:LicenseCountingType,
             Limit:LicenseCount,Consumed:ConsumedLicenses,
             Enforce:LicenseCountHardLimit,Status:Status}' --output table
```

```
--------------------------------------------------------------------------
|                     ListLicenseConfigurations                          |
+-------------------------+--------+-------+----------+--------+---------+
|  SQL-Server-EE-Core     | Core   |  64   |    48    | True   | AVAILABLE |
|  Oracle-DB-EE-Socket    | Socket |  8    |     8    | True   | AVAILABLE |
|  WindowsServer-DC-Core  | Core   | 256   |   214    | False  | AVAILABLE |
+-------------------------+--------+-------+----------+--------+---------+
```

`Oracle-DB-EE-Socket` está en 8 de 8 con un límite duro. El próximo lanzamiento que consumiría un socket será **rechazado a nivel de la API** — que es el comportamiento correcto, e infinitamente más barato que descubrir el sobre-despliegue durante una auditoría del proveedor.

```bash
$ aws license-manager list-usage-for-license-configuration \
    --license-configuration-arn arn:aws:license-manager:us-east-1:111122223333:license-configuration:lic-4a91c7e3 \
    --query 'LicenseConfigurationUsageList[].{Resource:ResourceArn,
             Type:ResourceType,Owner:ResourceOwnerId,Consumed:ConsumedLicenses}' \
    --output text
```

```
i-0b3e7c1948da2f560  EC2_HOST      111122223333  4
i-0a91f4c72e6b83d05  EC2_HOST      111122223333  4
```

### 6.8 Facturación consolidada — verificar que los descuentos por volumen realmente se agreguen

```bash
$ aws organizations describe-organization \
    --query 'Organization.{Id:Id,FeatureSet:FeatureSet,MasterAccount:MasterAccountId}'
```

```json
{
    "Id": "o-x8k2p9q3z1",
    "FeatureSet": "ALL",
    "MasterAccount": "111122223333"
}
```

```bash
$ aws organizations list-accounts \
    --query 'length(Accounts[?Status==`ACTIVE`])' --output text
```

```
23
```

**Por qué esto importa económicamente:** con la facturación consolidada, el uso de las 23 cuentas se agrega *antes* de aplicar los niveles por volumen. Veintitrés cuentas que almacenan 2 TB cada una en S3 se facturan como un parque único de 46 TB, no como 23 parques separados de 2 TB — y esa misma agregación permite que el beneficio no utilizado de un Savings Plan o una RI de una cuenta se aplique automáticamente al uso coincidente de otra cuenta. `FeatureSet: ALL` (no `CONSOLIDATED_BILLING`) también es el prerrequisito para las SCP y las tag policies de la sección 5.3.

---

## 7. Verificación y Diagnóstico de Fallos

### 7.1 Validación previa al despliegue

```bash
$ aws cloudformation validate-template \
    --template-body file://finops-foundation.yaml \
    --query '{Description:Description,Params:Parameters[].ParameterKey}'
```

```json
{
    "Description": "FinOps data foundation. Creates the S3 destination and bucket policy for a Data Exports (CUR 2.0) delivery, plus a Cost Category that maps linked accounts and tags into business dimensions. Deploy in the Organizations management account in us-east-1.",
    "Params": ["ExportBucketName", "ExportName", "RetentionDays"]
}
```

```bash
$ cfn-lint finops-foundation.yaml budgets-and-anomaly.yaml
$ terraform validate && terraform plan -out=finops.tfplan
$ kubectl apply --dry-run=server -f karpenter-nodepools.yaml
```

```
ec2nodeclass.karpenter.k8s.aws/cost-optimized created (server dry run)
nodepool.karpenter.sh/spot-general created (server dry run)
nodepool.karpenter.sh/ondemand-critical created (server dry run)
resourcequota/payments-quota created (server dry run)
limitrange/payments-defaults created (server dry run)
verticalpodautoscaler.autoscaling.k8s.io/payments-api-vpa created (server dry run)
```

### 7.2 Lista de verificación posterior al despliegue

```bash
# 1. Is the CUR export actually defined and delivering?
$ aws bcm-data-exports list-exports --region us-east-1 \
    --query 'Exports[].{Name:ExportName,Status:ExportStatus.StatusCode,
             LastRefresh:ExportStatus.LastRefreshedAt}' --output table
```

```
--------------------------------------------------------------
|                        ListExports                         |
+------------------------+---------+-------------------------+
|  cur2-hourly-resources | HEALTHY | 2026-09-03T06:14:22Z    |
+------------------------+---------+-------------------------+
```

```bash
# 2. Are objects landing in S3? An export that is HEALTHY but has
#    delivered nothing means the bucket policy is wrong.
$ aws s3 ls s3://acme-finops-cur/cur2/cur2-hourly-resources/ --recursive \
    --human-readable --summarize | tail -4
```

```
2026-09-03 06:15:41   48.2 MiB cur2/cur2-hourly-resources/data/BILLING_PERIOD=2026-09/cur2-hourly-resources-00001.snappy.parquet

Total Objects: 214
   Total Size: 9.6 GiB
```

```bash
# 3. Are the cost allocation tags ACTIVE? Defining a tag is not enough -
#    it must be explicitly activated in the billing console or via API,
#    and activation is NOT retroactive.
$ aws ce list-cost-allocation-tags --status Active --region us-east-1 \
    --query 'CostAllocationTags[].{Key:TagKey,Type:Type,Status:Status}' --output table
```

```
------------------------------------------------
|          ListCostAllocationTags              |
+---------------+-------------------+----------+
|  CostCenter   |  UserDefined      |  Active  |
|  Environment  |  UserDefined      |  Active  |
|  Owner        |  UserDefined      |  Active  |
|  Application  |  UserDefined      |  Active  |
|  aws:createdBy|  AWSGenerated     |  Active  |
+---------------+-------------------+----------+
```

```bash
# 4. Is anomaly detection subscribed and armed?
$ aws ce get-anomaly-monitors --region us-east-1 \
    --query 'AnomalyMonitors[].{Name:MonitorName,Type:MonitorType,
             Dim:MonitorDimension,Eval:LastEvaluatedDate}' --output table
```

```
-----------------------------------------------------------------------
|                        GetAnomalyMonitors                           |
+------------------------+-------------+---------+--------------------+
|  all-services-monitor  | DIMENSIONAL | SERVICE | 2026-09-03T04:00:00Z |
|  business-unit-monitor | CUSTOM      | None    | 2026-09-03T04:00:00Z |
+------------------------+-------------+---------+--------------------+
```

```bash
# 5. Is Karpenter consolidating, or just provisioning?
$ kubectl get nodeclaims -o custom-columns=\
NAME:.metadata.name,TYPE:.metadata.labels.node\\.kubernetes\\.io/instance-type,\
CAPACITY:.metadata.labels.karpenter\\.sh/capacity-type,READY:.status.conditions[?\(@.type==\"Ready\"\)].status
```

```
NAME                    TYPE          CAPACITY    READY
spot-general-4kd2n      c6g.2xlarge   spot        True
spot-general-9mxq7      m6i.xlarge    spot        True
ondemand-critical-r7bv  m6i.large     on-demand   True
```

```bash
$ kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --tail=200 \
    | grep -i consolidat | tail -3
```

```
{"level":"INFO","time":"2026-09-03T11:42:08.114Z","logger":"controller","message":"disrupting nodeclaim(s) via replace, terminating 2 nodes (11 pods) spot-general-x8t4p/m6i.2xlarge/spot, spot-general-q2wn9/m6i.xlarge/spot and replacing with spot node from types c6g.2xlarge, m6g.2xlarge, m7g.2xlarge","commit":"a1b2c3d","reason":"underutilized"}
{"level":"INFO","time":"2026-09-03T11:47:31.902Z","logger":"controller","message":"deleted nodeclaim","commit":"a1b2c3d","NodeClaim":{"name":"spot-general-x8t4p"}}
```

Dos nodos reemplazados por un único nodo Graviton más barato. Esa línea de log **es** la optimización de costos, observable en tiempo real.

### 7.3 Matriz de diagnóstico de fallos

| Síntoma | Sonda | Causa raíz | Solución |
|---|---|---|---|
| La columna de la etiqueta de asignación de costos está vacía en Cost Explorer / CUR | `aws ce list-cost-allocation-tags --status Inactive` | La etiqueta existe en los recursos pero nunca fue **activada** para facturación | Activala. **La activación no es retroactiva** — los datos históricos quedan sin atribuir para siempre. Usá una Cost Category sobre `LINKED_ACCOUNT` para atribuir el pasado. |
| Etiqueta activada, sigue vacía por 24–48 h | Revisá `LastUpdatedDate` en la etiqueta | Retraso normal de propagación | Esperá. Los datos de facturación no son en tiempo real; Cost Explorer tiene un retraso de ~24 h. |
| Estado del export de CUR `HEALTHY` pero el prefijo de S3 está vacío | `aws s3api get-bucket-policy --bucket <b>` | A la bucket policy le faltan las declaraciones de `billingreports.amazonaws.com` / `bcm-data-exports.amazonaws.com`, o la condición `aws:SourceAccount` rechaza la llamada | Volvé a aplicar la política de §5.1. Revisá de nuevo después del próximo ciclo de refresco. |
| El export de CUR falla silenciosamente después de habilitar SSE-KMS | Eventos de `PutObject` en CloudTrail para el service principal | El service principal no tiene `kms:GenerateDataKey` sobre la CMK | Agregá el principal a la política de la clave, o usá SSE-S3 (`AES256`). |
| El presupuesto muestra $0,00 de gasto para siempre | `aws budgets describe-budget --budget-name X --query 'Budget.CostFilters'` | `CostFilters` referencia una clave/valor de etiqueta que no coincide con nada — error de tipeo, mayúsculas incorrectas o etiqueta no activada | La sintaxis del filtro es `user:<Key>$<Value>` y **distingue mayúsculas de minúsculas**. Verificá contra `list-cost-allocation-tags`. |
| Las notificaciones de presupuesto `FORECASTED` nunca se disparan | `CalculatedSpend.ForecastedSpend` está ausente | Budgets necesita aproximadamente **5 semanas** de historial de uso para pronosticar | Esperá, o apoyate en los umbrales `ACTUAL` mientras tanto. |
| Cost Anomaly Detection no reporta nada en una cuenta nueva | `get-anomaly-monitors` → `LastEvaluatedDate` | El modelo necesita unos **10 días** de historial para establecer una línea base | Esperá. No bajes el umbral de impacto para forzar alertas — vas a obtener ruido, no señal. |
| Compute Optimizer devuelve `finding: NOT_OPTIMIZED` sin opciones | `get-enrollment-status` | La cuenta no está inscripta, o tiene menos de **14 días** de métricas de CloudWatch | `aws compute-optimizer update-enrollment-status --status Active`, y después esperá a que se llene la ventana de métricas. |
| Las recomendaciones de rightsizing ignoran la memoria (`MaxMemoryUtilizationPercentage: null`) | `aws cloudwatch list-metrics --namespace CWAgent` | La memoria es una métrica del SO invitado; el hipervisor no puede verla | Instalá y configurá el agente de CloudWatch. Hasta entonces, tratá cada reducción de tamaño como solo-CPU y riesgosa por OOM. |
| La utilización del Savings Plan cae por debajo del 100% después de un deploy | `get-savings-plans-utilization --granularity DAILY` | El workload se achicó, cambió de región o migró a un servicio que el SP no cubre (p. ej. el Compute SP no cubre RDS) | Aumentá el uso cubierto o aceptá la pérdida hasta el fin del plazo. Los Savings Plans **no se pueden cancelar ni revender.** |
| La factura subió pero la línea "EC2" de Cost Explorer está plana | Agrupá por `USAGE_TYPE` dentro de `EC2 - Other` | Crecimiento de EBS, proliferación de snapshots o procesamiento de datos de NAT Gateway | §6.1/§6.5. Agregá VPC endpoints de S3/ECR; aplicá políticas de ciclo de vida a los snapshots. |
| Los totales unblended y amortizado difieren por miles | Compará `UnblendedCost` vs `AmortizedCost` en la misma consulta | Correcto y esperado — una tarifa upfront de SP/RI cae entera en un mes en unblended, pero se reparte a lo largo del plazo en amortizado | Reportá amortizado a finanzas, unblended para flujo de caja. Nunca los mezcles en un mismo gráfico. |
| La factura de una cuenta vinculada muestra costos blended que no reconoce | `UseBlended: true` en los `CostTypes` del presupuesto | Las tarifas blended son un artefacto de promediación de la facturación consolidada | Usá **unblended** para rendición de cuentas, **amortizado** para reportes conscientes de compromisos. Blended casi nunca es la elección correcta. |
| El gasto parece bien, y después se dispara cuando expiran los créditos | `aws ce get-cost-and-usage --metrics NetUnblendedCost` y compará con `UnblendedCost` | Los créditos promocionales estaban enmascarando el consumo real | Poné `IncludeCredit: false` en los presupuestos (como en §5.2) para que las alertas sigan el consumo real, no el consumo acreditado. |
| La SCP de §5.3 rompe un pipeline de CI legítimo | CloudTrail `errorCode: AccessDenied` con `RunInstances` | El rol del pipeline no pasa las etiquetas requeridas | Arreglá el pipeline para que etiquete en la creación. **No** exceptúes al rol — la excepción se vuelve permanente y la brecha de atribución se vuelve estructural. |
| Karpenter nunca consolida | `kubectl logs -n karpenter ... \| grep -i "cannot disrupt"` | Un PDB bloquea la evicción, un pod tiene `karpenter.sh/do-not-disrupt: "true"`, o un pod suelto (sin controlador dueño) ancla el nodo | Arreglá el PDB, quitá la anotación, o poné el pod suelto bajo un controlador. |
| El ResourceQuota rechaza los deploys con `must specify requests.cpu` | `kubectl describe quota -n <ns>` | El namespace tiene una cuota de CPU pero los pods no declaran requests | El `LimitRange` de §5.5 provee los valores por defecto. Aplicalo antes de la cuota. |
| Las instancias Windows BYOL se niegan a lanzarse en tenancy compartido | Error de lanzamiento de la instancia / regla de License Manager | Los términos de licenciamiento de Microsoft requieren un Dedicated Host para licencias adquiridas el 2019-10-01 o después sin Software Assurance | Pasá a Dedicated Hosts, verificá la elegibilidad de License Mobility con el proveedor, o cambiá a License Included. |
| License Manager bloquea un lanzamiento en el límite de derechos de uso | `list-license-configurations` → `ConsumedLicenses == LicenseCount` | Límite duro alcanzado — funcionando como fue diseñado | Recuperá derechos de uso de hosts dados de baja, o comprá más. **No** pongas `LicenseCountHardLimit` en `false` para desbloquear un deploy; eso convierte un fallo controlado en un pasivo de auditoría. |

### 7.4 El ciclo operativo de FinOps como runbook de SRE

La FinOps Foundation define tres fases iterativas; mapealas sobre prácticas que ya ejecutás.

| Fase | Pregunta | Artefactos de este documento | Análogo de SRE |
|---|---|---|---|
| **Inform** | ¿A dónde va la plata y quién es dueño? | Export CUR 2.0 (§5.1), Cost Categories (§5.1), gobernanza de etiquetas (§5.3), consultas de Athena (§5.6) | Instrumentación y trazado |
| **Optimize** | ¿Qué debería cambiar? | Rightsizing (§6.2), scheduling (§5.4), consolidación de Karpenter (§5.5), compromisos (§6.3) | Ajuste de rendimiento y planificación de capacidad |
| **Operate** | ¿Cómo evitamos que retroceda? | Presupuestos + acciones de presupuesto (§5.2), detección de anomalías (§5.2), SCPs (§5.3), SLI de cobertura de etiquetas (§5.6) | SLOs, alertas, error budgets |

**Tratá la cobertura de etiquetas y la utilización del Savings Plan como SLIs con SLOs.** Cobertura de etiquetas ≥ 95%, utilización de SP ≥ 99%, cobertura de SP en la banda del 70–85%. Alertá sobre el SLO, no sobre la cifra en dólares — la cifra en dólares crece legítimamente cuando el negocio crece, pero los ratios de eficiencia no deberían degradarse.

---

## 8. Distinciones Relevantes para el Examen

Estas son las discriminaciones sobre las que se construyen las preguntas del CLF-C02. Cada par es genuinamente diferente, y elegir el equivocado es la trampa buscada.

| Confusión | La distinción |
|---|---|
| **CAPEX vs OPEX** | *Cuándo* y *cómo* se registra la plata. El cloud desplaza la compra de capital al gasto operativo. |
| **Fijo vs variable** | *Si* el costo escala con el uso. Una RI a 3 años en el cloud sigue siendo un costo fijo. |
| **AWS Pricing Calculator vs Cost Explorer** | Calculator = **estimar el costo futuro** de una arquitectura que todavía no construiste. Cost Explorer = **analizar el gasto real** pasado/actual. |
| **AWS Budgets vs Cost Anomaly Detection** | Budgets = **vos** definís un umbral estático. Anomaly Detection = el **ML** aprende tu patrón y marca desviaciones. Usá ambos. |
| **Cost Explorer vs el CUR** | Cost Explorer = UI/API curada, ~13 meses de historial, rápida. CUR = el conjunto de datos crudo, completo, horario y a nivel de recurso para análisis arbitrarios. |
| **Etiquetas de asignación de costos vs Cost Categories** | Las etiquetas viven en el recurso, deben activarse, no son retroactivas. Las Cost Categories son reglas del lado de la facturación sobre cuentas/etiquetas/servicios, y **sí** se aplican retroactivamente. |
| **Savings Plans vs Reserved Instances** | El SP se compromete a **$/hora de gasto** (flexible entre familia, tamaño, región, SO, y cubre Fargate y Lambda). La RI se compromete a **atributos de instancia específicos** (y se puede vender en el Marketplace). |
| **Standard vs Convertible RI** | Standard: mayor descuento, vendible, no puede cambiar la familia de instancias. Convertible: menor descuento, no vendible, se puede intercambiar por otra familia. |
| **Unblended / blended / amortizado / net** | Unblended = lo que la cuenta realmente incurrió. Blended = tarifa promediada a lo largo de la organización. Amortizado = compromisos upfront repartidos a lo largo de su plazo. Net = después de descuentos y créditos. |
| **Beneficios de la facturación consolidada** | Una sola factura, agregación de niveles por volumen entre todas las cuentas, y reparto automático del beneficio de RI/SP entre cuentas. |
| **Trusted Advisor vs Compute Optimizer** | Trusted Advisor: chequeos de cinco pilares incluido el de costos (recursos ociosos, baja utilización). Compute Optimizer: recomendaciones de rightsizing específicas por instancia, guiadas por ML, con un puntaje de riesgo de rendimiento. |
| **Migration Evaluator vs Pricing Calculator** | Migration Evaluator: descubre tu parque on-premises existente y construye el business case de TCO. Pricing Calculator: modelás una arquitectura de AWS a mano. |
| **BYOL vs License Included** | BYOL: sos dueño de la licencia (costo fijo, riesgo de cumplimiento tuyo, frecuentemente necesita Dedicated Hosts). License Included: incluido en la tarifa horaria (costo variable, la carga de cumplimiento es de AWS). |
| **Dedicated Instance vs Dedicated Host** | Dedicated Instance: hardware aislado, pero sin visibilidad del socket/núcleo físico. Dedicated Host: ves y controlás el servidor físico, que es lo que requieren el licenciamiento por núcleo y la afinidad instancia-host. |
| **El nivel de AWS Support como línea de costo** | Support es un porcentaje del uso mensual con tarifas escalonadas y un mínimo mensual. Es una línea real, pronosticable y a veces sorpresiva. |

---

## 9. Referencias

**Guía del examen**
- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- AWS Certified Cloud Practitioner certification page — https://aws.amazon.com/certification/certified-cloud-practitioner/

**Fundamentos de economía del cloud y precios**
- How AWS Pricing Works (whitepaper) — https://docs.aws.amazon.com/whitepapers/latest/how-aws-pricing-works/welcome.html
- AWS Cloud Economics Center — https://aws.amazon.com/economics/
- AWS Well-Architected Framework — Cost Optimization Pillar — https://docs.aws.amazon.com/wellarchitected/latest/cost-optimization-pillar/welcome.html
- AWS Pricing Calculator User Guide — https://docs.aws.amazon.com/pricing-calculator/latest/userguide/what-is-pricing-calculator.html
- AWS Pricing Calculator — https://calculator.aws/
- AWS Migration Evaluator — https://aws.amazon.com/migration-evaluator/

**Facturación, gestión de costos y reportes**
- AWS Billing and Cost Management User Guide — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/billing-what-is.html
- AWS Cost Management User Guide — https://docs.aws.amazon.com/cost-management/latest/userguide/what-is-costmanagement.html
- Consolidated billing for AWS Organizations — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/consolidated-billing.html
- Using cost allocation tags — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/cost-alloc-tags.html
- AWS Cost Categories — https://docs.aws.amazon.com/cost-management/latest/userguide/manage-cost-categories.html
- AWS Cost and Usage Reports User Guide — https://docs.aws.amazon.com/cur/latest/userguide/what-is-cur.html
- Creating a Data Export (CUR 2.0) — https://docs.aws.amazon.com/cur/latest/userguide/dataexports-create-standard.html
- CUR 2.0 data dictionary — https://docs.aws.amazon.com/cur/latest/userguide/dataexports-table-dictionary.html
- Understanding your AWS Cost Datasets: A Cheat Sheet (unblended / blended / amortized / net) — https://aws.amazon.com/blogs/aws-cloud-financial-management/understanding-your-aws-cost-datasets-a-cheat-sheet/
- AWS Budgets — https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html
- Configuring AWS Budgets actions — https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-controls.html
- AWS Cost Anomaly Detection — https://docs.aws.amazon.com/cost-management/latest/userguide/manage-ad.html
- AWS Cost Management API Reference — https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/Welcome.html

**Opciones de compra y optimización**
- AWS Savings Plans User Guide — https://docs.aws.amazon.com/savingsplans/latest/userguide/what-is-savings-plans.html
- Amazon EC2 Reserved Instances — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-reserved-instances.html
- Amazon EC2 Spot Instances — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-spot-instances.html
- Amazon EC2 pricing — https://aws.amazon.com/ec2/pricing/
- AWS Compute Optimizer User Guide — https://docs.aws.amazon.com/compute-optimizer/latest/ug/what-is-compute-optimizer.html
- AWS Trusted Advisor — https://docs.aws.amazon.com/awssupport/latest/user/trusted-advisor.html
- AWS Price List API — https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/API_Operations_AWS_Price_List_Service.html

**Licenciamiento**
- AWS License Manager User Guide — https://docs.aws.amazon.com/license-manager/latest/userguide/license-manager.html
- Amazon EC2 Dedicated Hosts — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/dedicated-hosts-overview.html
- Amazon EC2 Dedicated Instances — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/dedicated-instance.html
- Microsoft licensing on AWS — https://aws.amazon.com/windows/resources/licensing/
- AWS Optimization and Licensing Assessment (OLA) — https://aws.amazon.com/optimization-and-licensing-assessment/

**Gobernanza y automatización**
- AWS Organizations tag policies — https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_tag-policies.html
- AWS Organizations service control policies — https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html
- `AWS::Budgets::Budget` CloudFormation reference — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-budgets-budget.html
- `AWS::CE::AnomalyMonitor` CloudFormation reference — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-ce-anomalymonitor.html
- `AWS::CE::CostCategory` CloudFormation reference — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-ce-costcategory.html
- `AWS::BCMDataExports::Export` CloudFormation reference — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-bcmdataexports-export.html
- Amazon EventBridge Scheduler User Guide — https://docs.aws.amazon.com/scheduler/latest/UserGuide/what-is-scheduler.html
- AWS Config managed rule `required-tags` — https://docs.aws.amazon.com/config/latest/developerguide/required-tags.html

**Ingeniería de costos en Kubernetes**
- Karpenter NodePools — https://karpenter.sh/docs/concepts/nodepools/
- Karpenter disruption and consolidation — https://karpenter.sh/docs/concepts/disruption/
- Amazon EKS best practices — cost optimization — https://docs.aws.amazon.com/eks/latest/best-practices/cost-opt.html
- OpenCost documentation — https://opencost.io/docs/

**Marcos de práctica**
- FinOps Foundation Framework — https://www.finops.org/framework/
- AWS Cloud Financial Management blog — https://aws.amazon.com/blogs/aws-cloud-financial-management/