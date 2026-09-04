# 4.3 — Identificar recursos técnicos de AWS y opciones de AWS Support

**Certificación:** AWS Certified Cloud Practitioner (CLF-C02) · **Dominio 4:** Facturación, precios y soporte · **Tarea 4.3** · Peso en el examen: 4.0

> Los IDs de cuenta, IDs de caso, ARNs e IDs de evento en las transcripciones de terminal que siguen son sintéticos. Las formas de los comandos, los nombres de campo, los códigos de error y la semántica de las APIs son reales y reproducibles contra una cuenta viva.

---

## 1. El problema en producción: el soporte es un plano de control, no un número de teléfono

La forma en que suele enseñarse este enunciado de tarea — "memorizá los cinco planes de soporte" — se pierde lo que realmente decide en producción. Del plan de soporte que comprás cuelgan tres consecuencias arquitectónicas concretas, y ninguna es recuperable a las 03:00:

**1. Acceso programático a tus propios datos de fallas.** La AWS Health API (`DescribeEvents`, `DescribeAffectedEntities`) y la AWS Support API (`CreateCase`, `DescribeCases`) están **restringidas a Business Support o superior**. Si tu automatización de respuesta a incidentes llama a `health:DescribeEvents` para correlacionar un pico de latencia con un problema a nivel de AZ, ese camino de código no existe en un plan Developer — lanza `SubscriptionRequiredException`. No podés escribir el runbook primero y comprar el plan después; el runbook no va a correr.

**2. El tiempo hasta un humano es un componente de tu presupuesto de MTTR.** Si publicás un SLO de 99.95% de disponibilidad mensual, tenés **21.6 minutos** de error budget por mes. El objetivo de respuesta de 15 minutos para casos business-critical de Enterprise Support consume el 69% de ese presupuesto antes de que un ingeniero de AWS escriba una palabra. El objetivo de 1 hora de Business Support para "production system down" consume el **278%** — o sea que, para cualquier incidente cuya resolución requiera genuinamente a AWS, un SLO de 99.95% no es defendible sobre Business Support. Esto es una restricción de diseño, no una preferencia de compras.

**3. El agotamiento de cuotas es la interrupción autoinfligida más común, y las cuotas son un artefacto de soporte.** Un failover regional que intenta lanzar 400 vCPU en una región aprovisionada para 64 va a fallar con `VcpuLimitExceeded`, y el remedio — un aumento de cuota — es un *ticket de soporte* con una latencia a escala humana. El check de Service Limits de Trusted Advisor y la integración de Service Quotas con CloudWatch son las únicas maneras de enterarte *antes* del failover.

El resto de este documento trata a AWS Support por lo que es para un equipo de plataforma: un conjunto de APIs, fuentes de eventos y SLAs que cableás dentro de tu plano operativo, con un modelo de costos que podés calcular.

---

## 2. Taxonomía de la superficie de recursos de AWS

Cuatro niveles, distinguidos por costo, latencia y si hay un humano responsable.

| Nivel | Ejemplos | Costo | Latencia | Responsabilidad |
|---|---|---|---|---|
| **Autoservicio (gratis)** | Documentación, whitepapers, Architecture Center, Prescriptive Guidance, Solutions Library, Well-Architected Tool, Security Bulletins, Skill Builder (capa gratuita) | $0 | Inmediata | Ninguna |
| **Comunidad (gratis)** | AWS re:Post, re:Post Knowledge Center, AWS Blogs, AWS Open Source | $0 | Horas–días, best-effort | Ninguna |
| **AWS Support (suscripción)** | Casos de soporte, Trusted Advisor, Support API, TAM, Concierge, Countdown, IDR | Según el plan | *Objetivo* contractual de respuesta | AWS |
| **Profesional / Partner (por contratación)** | AWS Professional Services, AWS Managed Services (AMS), AWS Partner Network, AWS IQ, AWS Marketplace | Statement of work | Contractual | AWS o Partner |

La distinción crítica tanto para el examen como para producción: **los tiempos de respuesta de AWS Support son objetivos para una *primera respuesta*, no SLAs de resolución, y no están respaldados por créditos de servicio.** Solo los SLAs de servicios individuales (EC2, S3, RDS…) llevan créditos, y esos se reclaman mediante un caso de soporte — que a su vez solo se puede abrir en Developer y superior.

---

## 3. Planes de AWS Support — la comparación completa

### 3.1 Matriz de capacidades

| Capacidad | Basic | Developer | Business | Enterprise On-Ramp | Enterprise |
|---|---|---|---|---|---|
| Documentación, whitepapers, re:Post | ✅ | ✅ | ✅ | ✅ | ✅ |
| AWS Health Dashboard — *Service health* (público) | ✅ | ✅ | ✅ | ✅ | ✅ |
| AWS Health Dashboard — *Your account health* | ✅ | ✅ | ✅ | ✅ | ✅ |
| **AWS Health API** (`DescribeEvents`, vista de organización) | ❌ | ❌ | ✅ | ✅ | ✅ |
| Trusted Advisor — **solo checks core** | ✅ | ✅ | — | — | — |
| Trusted Advisor — **conjunto completo de checks** (6 categorías) | ❌ | ❌ | ✅ | ✅ | ✅ |
| **Trusted Advisor API** (`trustedadvisor:*`) | ❌ | ❌ | ✅ | ✅ | ✅ |
| **Trusted Advisor Priority** (curado por el TAM) | ❌ | ❌ | ❌ | ❌ | ✅ |
| Atención al cliente (facturación/cuenta), 24×7 | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Casos de soporte técnico** | ❌ | ✅ (email, horario laboral) | ✅ (24×7 email/chat/teléfono) | ✅ | ✅ |
| **AWS Support API** (`support:CreateCase`) | ❌ | ❌ | ✅ | ✅ | ✅ |
| AWS Support App en Slack / Microsoft Teams | ❌ | ❌ | ✅ | ✅ | ✅ |
| Contactos que pueden abrir casos | — | **1** | Ilimitados (controlado por IAM) | Ilimitados | Ilimitados |
| Soporte de software de terceros (SO, stacks) | ❌ | ❌ | ✅ | ✅ | ✅ |
| Runbooks de automatización SSM `AWSPremiumSupport-*` | ❌ | ❌ | ✅ | ✅ | ✅ |
| **Technical Account Manager (TAM)** | ❌ | ❌ | ❌ | **Pool de TAMs** | **TAM designado** |
| Equipo **Concierge** (expertos en facturación) | ❌ | ❌ | ❌ | ✅ | ✅ |
| Well-Architected Framework Reviews (guiadas) | ❌ | ❌ | ❌ | ✅ (consultiva) | ✅ (proactiva, continua) |
| Revisiones operativas, game days, créditos de capacitación | ❌ | ❌ | ❌ | Limitado | ✅ |
| **AWS Countdown** (ex Infrastructure Event Mgmt) | ❌ | ❌ | Comprable | ✅ | ✅ |
| **AWS Incident Detection and Response** (add-on) | ❌ | ❌ | ❌ | ❌ | ✅ (add-on pago) |
| AWS re:Post Private | ❌ | ❌ | ❌ | ✅ | ✅ |

Los **checks core de Trusted Advisor en Basic** (el conjunto que toda cuenta recibe gratis) son los que mapean a postura de seguridad y capacidad:

| Check | ID | Categoría |
|---|---|---|
| Service Limits | `eW7HH0l7J9` | Service Limits |
| Security Groups – Specific Ports Unrestricted | `HCP4007jGY` | Security |
| IAM Use | `zXCkfM1nI3` | Security |
| MFA on Root Account | `7DAFEmoDos` | Security |
| Amazon S3 Bucket Permissions | `Pfx0RwqBli` | Security |
| Amazon EBS Public Snapshots | `ePs02jT06w` | Security |
| Amazon RDS Public Snapshots | `rSs93HQwa1` | Security |

Nunca hardcodees estos IDs desde un documento — enumeralos con `describe-trusted-advisor-checks` (§10.3). Son estables, pero el *conjunto disponible para vos* es función de tu plan.

### 3.2 Objetivos de tiempo de respuesta por severidad

La Support API expone las severidades como códigos opacos; estos son los valores que pasás a `--severity-code`.

| Código de API | Nombre en consola | Developer | Business | Enterprise On-Ramp | Enterprise |
|---|---|---|---|---|---|
| `low` | General guidance | < 24 h **hábiles** | < 24 h | < 24 h | < 24 h |
| `normal` | System impaired | < 12 h **hábiles** | < 12 h | < 12 h | < 12 h |
| `high` | Production system impaired | ❌ no disponible | < 4 h | < 4 h | < 4 h |
| `urgent` | Production system down | ❌ no disponible | < 1 h | < 1 h | < 1 h |
| `critical` | Business-critical system down | ❌ no disponible | ❌ no disponible | **< 30 min** | **< 15 min** |

Dos trampas que muerden en producción:

- **"Horario laboral" en Developer significa el calendario del país del cliente, 08:00–18:00 hora local, días de semana.** Un caso de severidad `normal` un sábado en Developer no tiene un objetivo de respuesta significativo hasta el lunes. Cualquier equipo que sostenga una rotación de guardia de fin de semana sobre Developer Support la está sosteniendo solo.
- **`critical` es la única severidad restringida por plan en el camino de *escritura*.** Intentarla en Business no la degrada silenciosamente; `describe-severity-levels` simplemente no la va a listar, y `create-case` la rechaza. Tu automatización debe descubrir el conjunto de severidades en tiempo de ejecución, no asumirlo.

### 3.3 El modelo de costos, y el cruce no obvio

El precio es *el mayor entre* un mínimo mensual o un porcentaje de los cargos mensuales de uso de AWS. Business y Enterprise usan porcentajes **marginales por tramos**; Enterprise On-Ramp usa un **10% plano**.

| Plan | Mínimo mensual | Porcentaje de los cargos mensuales de AWS |
|---|---|---|
| Basic | $0 | — |
| Developer | $29 | 3% (plano) |
| Business | $100 | 10% de $0–10K · 7% de $10K–80K · 5% de $80K–250K · 3% por encima de $250K |
| Enterprise On-Ramp | $5,500 | **10% (plano, sin tramos)** |
| Enterprise | $15,000 | 10% de $0–150K · 7% de $150K–500K · 5% de $500K–1M · 3% por encima de $1M |

Evaluar esas funciones por tramos da una tabla que cambia decisiones de compra:

| Gasto mensual en AWS | Developer | Business | Enterprise On-Ramp | Enterprise |
|---:|---:|---:|---:|---:|
| $5,000 | $150 | $500 | $5,500 | $15,000 |
| $10,000 | $300 | $1,000 | $5,500 | $15,000 |
| $50,000 | $1,500 | $3,800 | $5,500 | $15,000 |
| $100,000 | $3,000 | $6,900 | $10,000 | $15,000 |
| **$150,000** | $4,500 | $9,400 | **$15,000** | **$15,000** |
| $250,000 | $7,500 | $14,400 | $25,000 | $22,000 |
| $500,000 | $15,000 | $21,900 | $50,000 | $39,500 |
| $1,000,000 | $30,000 | $36,900 | $100,000 | $64,500 |

**El cruce está exactamente en $150,000/mes de cargos de AWS.** Por debajo, On-Ramp es la manera más barata de conseguir un TAM y un objetivo business-critical de menos de una hora. En exactamente $150K ambos cuestan $15,000. **Por encima de $150K/mes, Enterprise Support es estrictamente más barato que Enterprise On-Ramp** — y además es estrictamente mejor (15 min vs 30 min, TAM designado vs pool, Trusted Advisor Priority, elegibilidad para IDR). Derivación: para `S > 150,000`, On-Ramp `= 0.10·S` y Enterprise `= 15,000 + 0.07·(S − 150,000) = 4,500 + 0.07·S`; la diferencia es `0.03·(S − 150,000)`, positiva y creciente. No existe un nivel de gasto por encima de $150K en el que On-Ramp sea racional.

Los precios cambian. Volvé a derivar esto contra la página de precios viva antes de actuar en consecuencia; el *método* es la parte duradera.

### 3.4 Planes de soporte bajo AWS Organizations

El soporte se factura por cuenta pero se evalúa contra el uso **consolidado**. Bajo una cuenta pagadora con facturación consolidada, el plan de soporte se aplica a toda la organización — no podés poner económicamente una cuenta miembro en Enterprise y dejar el resto en Basic, y AWS toma el gasto agregado como base para el tramo porcentual. Consecuencias prácticas:

- Una cuenta sandbox dentro de una organización Enterprise hereda Enterprise Support y por lo tanto hereda la Support API. Tu tooling puede asumirlo uniformemente.
- Los **casos de soporte son por cuenta y no son visibles a través de la organización por defecto.** No existe una vista de `DescribeCases` a nivel de organización. El reporte centralizado de casos requiere asumir un rol en cada cuenta miembro (§9.2).
- AWS Health *sí* tiene una vista organizacional, habilitada una sola vez desde la cuenta de administración (§5.2). Esta asimetría — Health conoce la organización, los casos de Support no — es lo que impulsa la arquitectura de §9.

---

## 4. AWS Trusted Advisor

### 4.1 Qué es en realidad

Un motor de reglas gestionado y evaluado continuamente sobre la configuración de los recursos de tu cuenta, sus métricas de utilización y el consumo de cuotas de servicio. Seis categorías:

| Categoría | Checks representativos | Fuente de datos |
|---|---|---|
| **Cost Optimization** | EC2 de baja utilización, load balancers ociosos, Elastic IPs sin asociar, volúmenes EBS subutilizados, instancias RDS ociosas, cobertura de Reserved Instance/Savings Plans | Métricas de CloudWatch (ventana de 14 días), Cost Explorer |
| **Performance** | Instancias sobreutilizadas, distribuciones CloudFront de alta latencia, desajuste de EBS throughput-optimised, reglas excesivas en security groups | CloudWatch, configuración |
| **Security** | MFA en root, snapshots públicos, puertos abiertos en security groups, ACLs de buckets S3, rotación de access keys de IAM, logging de CloudTrail, access keys expuestas | Configuración, IAM, CloudTrail |
| **Fault Tolerance** | ASGs de una sola AZ, antigüedad de snapshots EBS, RDS Multi-AZ, cross-zone en ELB, health checks de Route 53, versionado de S3 | Configuración |
| **Service Limits** | Uso ≥ 80% de la cuota para ~40 cuotas en EC2, VPC, EBS, ELB, IAM, RDS, SES, DynamoDB, Auto Scaling, CloudFormation, Kinesis | Service Quotas + uso |
| **Operational Excellence** | Cobertura de alarmas de CloudWatch, retención de log groups no configurada, recursos sin tags | Configuración |

Trusted Advisor ve tus recursos a través del service-linked role **`AWSServiceRoleForTrustedAdvisor`** (`trustedadvisor.amazonaws.com`). Si un equipo lo borra "para limpiar IAM", todos los checks degradan silenciosamente a `not_available` — una falla real y poco diagnosticada (§11.4).

### 4.2 Semántica de refresco — la parte que rompe la automatización

Los checks **no** son en vivo. Cada check lleva su propio intervalo de refresco, y un refresco manual está limitado por tasa por check.

| Concepto | Comportamiento |
|---|---|
| Refresco automático | Semanal para la mayoría de los checks mientras la consola no está abierta; más frecuente para Service Limits |
| Refresco disparado por consola | Refresca al cargar la página, sujeto al cooldown por check |
| `RefreshTrustedAdvisorCheck` | Encola un refresco; devuelve `status` ∈ `none` \| `enqueued` \| `processing` \| `success` \| `abandoned` |
| Descubrimiento del cooldown | `DescribeTrustedAdvisorCheckRefreshStatuses` devuelve `millisUntilNextRefreshable` — **la única manera correcta de marcar el ritmo de un loop de refresco** |
| Vejez del resultado | `DescribeTrustedAdvisorCheckResult` devuelve `timestamp`; tratá los resultados más viejos que el intervalo del check como meramente indicativos |

Refrescar con un schedule fijo de `rate(1 hour)` sin leer `millisUntilNextRefreshable` produce un flujo de refrescos no-op y una métrica que parece fresca pero no lo está. El Lambda programado de §9.1 hace esto correctamente.

### 4.3 Trusted Advisor Priority vs. el servicio estándar

| | Trusted Advisor (Business+) | Trusted Advisor Priority (solo Enterprise) |
|---|---|---|
| Fuente de recomendaciones | Checks automatizados | Checks automatizados **+ riesgos específicos de la cuenta curados por el TAM** |
| Priorización | Lista plana, rojo/amarillo/verde | Ordenada por el TAM según tu arquitectura y tu roadmap |
| Ciclo de vida | Sin estado — un hallazgo es rojo o no lo es | Con estado: `pending_response` → `in_progress` → `dismissed`/`resolved` |
| API | `trustedadvisor:ListRecommendations` | `+ UpdateRecommendationLifecycle`, `ListOrganizationRecommendations` |
| Agregación en organización | Por cuenta | Consolidado a nivel de organización |

El estado de ciclo de vida de Priority es lo que lo hace usable como backlog de gobernanza: una recomendación cuyo riesgo aceptás deliberadamente puede quedar `dismissed` con un motivo, y deja de reaparecer. El Trusted Advisor estándar **no tiene mecanismo de supresión** — tenés que mantener vos mismo la lista de exclusiones, que es la razón por la que el Lambda de §9.1 lleva una allow-list explícita.

---

## 5. AWS Health

Tres cosas distintas comparten el nombre. Confundirlas es el error más común en este enunciado de tarea.

### 5.1 Las tres superficies

| Superficie | URL / API | Autenticación | Alcance | Requisito de plan |
|---|---|---|---|---|
| **AWS Health Dashboard — Service health** | `health.aws.amazon.com/health/status` | **Ninguna** (pública) | Todas las regiones/servicios de AWS, agregado para todos los clientes | Cualquiera (incl. sin cuenta) |
| **AWS Health Dashboard — Your account health** | Consola, `health.aws.amazon.com/health/home` | Inicio de sesión en la consola | **Tus** recursos: cambios programados, problemas que te afectan, notificaciones de cuenta | **Cualquier plan, incluido Basic** |
| **AWS Health API** | `global.health.amazonaws.com` | SigV4 | Programático, a nivel de organización con trusted access | **Business, Enterprise On-Ramp, Enterprise** |

La frase relevante para el examen: la información de salud *personalizada* es gratis (dashboard); el acceso *programático* a ella no lo es (API). La entrega de eventos `aws.health` por EventBridge está disponible para todas las cuentas, que es el resquicio que hace posible la automatización orientada a eventos por debajo de Business — pero solo recibís eventos empujados, sin capacidad de consultar el historial.

### 5.2 Taxonomía de eventos

| `eventTypeCategory` | Significado | `eventTypeCode` típico |
|---|---|---|
| `issue` | Degradación no planificada del lado de AWS | `AWS_EC2_OPERATIONAL_ISSUE`, `AWS_RDS_OPERATIONAL_ISSUE` |
| `scheduledChange` | Mantenimiento planificado que afecta a tus recursos | `AWS_RDS_PLANNED_LIFECYCLE_EVENT`, `AWS_EC2_PERSISTENT_INSTANCE_RETIREMENT_SCHEDULED` |
| `accountNotification` | Aviso de cuenta/facturación/seguridad | `AWS_RISK_CREDENTIALS_EXPOSED`, `AWS_ELASTICLOADBALANCING_API_ISSUE` |
| `investigation` | AWS está investigando un posible problema | Específico del servicio |

`AWS_RISK_CREDENTIALS_EXPOSED` merece una mención especial: AWS escanea hosts públicos de Git buscando access keys filtradas y levanta este evento *además* de aplicar la política `AWSCompromisedKeyQuarantineV3` al principal. Cablear este tipo de evento a un pager es la automatización de Health de mayor valor que podés construir, y funciona en todos los planes a través de EventBridge.

### 5.3 Arquitectura de endpoints y la trampa del failover

La Health API es un **servicio global con un modelo de failover regional**:

- Endpoint primario: `global.health.amazonaws.com`, firmado para **`us-east-1`**.
- Si la región activa se mueve (AWS puede hacer failover del control plane a `us-east-2`), el *mismo* hostname resuelve a la nueva región pero **debe firmarse para esa región**.
- `DescribeEventDetails` y compañía requieren por lo tanto que tu cliente maneje un cambio de región de firma. Los SDKs de AWS lo manejan; los clientes SigV4 hechos a mano y algunas versiones viejas del CLI, no.

La llamada de descubrimiento correcta es `aws health describe-event-details` haciendo failover mediante la búsqueda documentada del endpoint activo; en la práctica, usá un SDK/CLI actual y no fijes la región de firma en tu propio código.

---

## 6. Service Quotas — la mitad operativa de Trusted Advisor

Trusted Advisor te dice que una cuota está al 80%. Service Quotas es donde la *ves* y la *cambiás*.

| Operación | CLI | Notas |
|---|---|---|
| Listar cuotas de un servicio | `aws service-quotas list-service-quotas --service-code ec2` | Valores aplicados (específicos de la cuenta) |
| Listar los valores por defecto de AWS | `aws service-quotas list-aws-default-service-quotas --service-code ec2` | Comparar para detectar aumentos previos |
| Leer una cuota | `aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A` | `Adjustable: true/false` es el campo clave |
| Solicitar un aumento | `aws service-quotas request-service-quota-increase ...` | Falla con `NoSuchResourceException` si no es ajustable por acá |
| Plantilla a nivel de organización | `aws service-quotas put-service-quota-increase-request-into-template ...` | Se aplica automáticamente a las **nuevas** cuentas de la organización |
| Alarma de CloudWatch | Namespace `AWS/Usage` + metric math `SERVICE_QUOTA()` | El único mecanismo de alarma de cuota en *tiempo real* |

Códigos de cuota necesarios con frecuencia:

| Cuota | Servicio | Código |
|---|---|---|
| Running On-Demand Standard (A,C,D,H,I,M,R,T,Z) instances (vCPU) | `ec2` | `L-1216C47A` |
| EC2-VPC Elastic IPs | `ec2` | `L-0263D0A3` |
| VPCs per Region | `vpc` | `L-F678F1CE` |
| Lambda concurrent executions | `lambda` | `L-B99A9384` |
| Rules per Network ACL | `vpc` | `L-2AEEBF1A` |

**No toda cuota es ajustable a través de Service Quotas.** Los límites duros y algunas cuotas propiedad del equipo del servicio deben ir por un *caso de soporte* con `issueType=service-limit-increase` — lo que te devuelve al reloj de respuesta dependiente del plan. Este es el vínculo mecánico entre §3 y §6, y es exactamente el escenario que sondea el examen.

---

## 7. Programas proactivos y humanos

| Programa | Plan | Qué es | Cuándo se gana su costo |
|---|---|---|---|
| **Technical Account Manager (TAM)** | On-Ramp (pool) / Enterprise (designado) | Ingeniero de AWS con nombre y apellido que conoce tu arquitectura; conduce revisiones Well-Architected, escala casos, da guía de roadmap bajo NDA | Plataformas multicuenta con lanzamientos recurrentes; el camino de escalamiento acorta la latencia de cola en los casos difíciles |
| **Concierge** | On-Ramp, Enterprise | Especialistas en facturación y cuenta (no técnicos) | Facturación consolidada, gestión de cartera de RI/SP, disputas de pago/impuestos |
| **AWS Incident Detection and Response (IDR)** | Enterprise, **add-on pago** | Las cargas de trabajo se onboardean y AWS las monitorea; AWS se involucra en **5 minutos** ante un incidente crítico detectado, con un runbook acordado de antemano | Cargas Tier-0 donde la latencia de detección domina el MTTR |
| **AWS Countdown** (ex Infrastructure Event Management) | On-Ramp, Enterprise (comprable en Business) | Soporte de ingeniería para un evento acotado: migración, lanzamiento, Black Friday. Planificación de capacidad, pre-aprovisionamiento de cuotas, personal de AWS de guardia durante la ventana | Cualquier cosa con fecha dura y un pico |
| **Well-Architected Framework Review** | On-Ramp, Enterprise (conducida por el TAM); la herramienta es gratis para todos | Revisión estructurada contra los seis pilares, que produce un plan de mejora priorizado | Antes, no después, de un freeze de plataforma |
| **AWS re:Post Private** | On-Ramp, Enterprise | Comunidad de conocimiento privada y curada para tu organización, sembrada con tu contenido de AWS | Organizaciones grandes donde el conocimiento tribal es el cuello de botella |
| **AWS Managed Services (AMS)** | Requiere Enterprise Support | AWS opera tu infraestructura según prácticas ITIL — parcheo, monitoreo, gestión de incidentes y cambios. AMS Accelerate (traés tus propias cuentas) / AMS Advanced (landing zone construida por AWS) | Necesitás operaciones ejecutadas por AWS, no asesoradas por AWS |
| **AWS Professional Services** | Cualquiera (SOW pago) | La consultora propia de AWS, orientada a la entrega | Migraciones, construcciones de plataforma greenfield |
| **AWS Partner Network (APN)** | Cualquiera | Caminos de Software, Servicios, Hardware, Capacitación y Distribución; tiers Select / Advanced / Premier; Competencies y designaciones Service Delivery | Experiencia regional o vertical que AWS misma no tiene en plantilla |
| **AWS IQ** | Cualquiera (EE.UU.) | Mercado de contrataciones cortas con freelancers AWS Certified, facturado a través de tu cuenta de AWS | Tareas expertas pequeñas y acotadas |
| **AWS Marketplace** | Cualquiera | Software de terceros curado con facturación consolidada; Private Offers, Private Marketplace, estandarización de EULA | Velocidad de compras; el gasto cuenta para compromisos EDP |

**Un trade-off que vale decir sin vueltas:** AMS, ProServe, Partners e IQ son todos "otro hace el trabajo". Se diferencian en *quién es responsable* y en *cómo está formado el contrato* — AMS es un servicio operativo continuo con SLAs, ProServe y Partners son proyectos, IQ es un mercado de tareas. En el examen, "queremos que AWS opere nuestra infraestructura día a día" → AMS; "necesitamos ayuda para diseñar una migración" → ProServe o un Partner; "necesitamos un experto certificado por una semana" → IQ.

---

## 8. Recursos técnicos gratuitos que se espera que puedas nombrar

| Recurso | URL | Para qué sirve |
|---|---|---|
| AWS Documentation | `docs.aws.amazon.com` | Guías de servicio, referencias de API, referencia del CLI |
| AWS Whitepapers & Guides | `aws.amazon.com/whitepapers/` | Documentos técnicos extensos (Well-Architected, Overview of AWS, Security Pillar) |
| AWS Architecture Center | `aws.amazon.com/architecture/` | Arquitecturas de referencia, diagramas, guías de decisión |
| AWS Prescriptive Guidance | `aws.amazon.com/prescriptive-guidance/` | Patrones, estrategias y playbooks de migración de los equipos de campo de AWS |
| AWS Solutions Library | `aws.amazon.com/solutions/` | Soluciones desplegables basadas en CloudFormation |
| AWS Well-Architected Tool | Consola (gratis) | Revisión autoservicio de la carga de trabajo contra seis pilares + lentes |
| AWS re:Post | `repost.aws` | Preguntas y respuestas de la comunidad; reemplazó a los AWS Forums |
| AWS Knowledge Center | `repost.aws/knowledge-center` | Respuestas curadas a las consultas de soporte más comunes |
| AWS Blogs | `aws.amazon.com/blogs/` | Detalles de lanzamientos y análisis profundos, por servicio y por disciplina |
| AWS Skill Builder | `skillbuilder.aws` | Capacitación, labs, preparación para el examen |
| AWS Artifact | Consola | Informes de cumplimiento a demanda (SOC, PCI, ISO) y acuerdos |
| AWS Security Bulletins | `aws.amazon.com/security/security-bulletins/` | CVEs y avisos de seguridad que afectan a servicios de AWS |
| AWS Trust & Safety (abuso) | `support.aws.amazon.com/#/contacts/report-abuse` | Reportar abuso **originado en** recursos de AWS |
| Página de estado de AWS Service Health | `health.aws.amazon.com/health/status` | Estado regional público, sin autenticación |

**Los seis pilares de Well-Architected** (se pregunta directamente): Operational Excellence, Security, Reliability, Performance Efficiency, Cost Optimization, Sustainability.

---

## 9. Infraestructura: cablear el plano de soporte dentro de tus operaciones

### 9.1 CloudFormation — automatización de casos disparada por Health, métricas de Trusted Advisor y alarmas de cuota

Desplegar en `us-east-1`. Las APIs de Support y Trusted Advisor solo se sirven desde `us-east-1`; la Health API es global pero se firma ahí.

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >
  Support control plane: AWS Health -> EventBridge -> auto Support case,
  Trusted Advisor red-check metric emission, and service quota alarms.
  MUST be deployed in us-east-1 (support/trustedadvisor endpoints are us-east-1 only).

Parameters:
  NotificationEmail:
    Type: String
    Description: Address subscribed to the support-events SNS topic.
    AllowedPattern: '^[^@\s]+@[^@\s]+\.[^@\s]+$'

  AutoCaseSeverity:
    Type: String
    Description: Severity used for auto-opened cases. 'critical' requires Enterprise/On-Ramp.
    Default: high
    AllowedValues: [low, normal, high, urgent, critical]

  TrustedAdvisorCheckIds:
    Type: CommaDelimitedList
    Description: Trusted Advisor check IDs to refresh and publish as metrics.
    Default: 'eW7HH0l7J9,HCP4007jGY,7DAFEmoDos,Pfx0RwqBli'

  MonitoredHealthServices:
    Type: CommaDelimitedList
    Description: AWS Health 'service' values that justify an automatic case.
    Default: 'EC2,RDS,ELASTICLOADBALANCING,EKS,LAMBDA,DYNAMODB'

Conditions:
  # Guard: refuse to build the case-opening path outside us-east-1.
  IsSupportRegion: !Equals [!Ref 'AWS::Region', 'us-east-1']

Resources:

  ############################################################
  # Notification fan-out
  ############################################################
  SupportEventsTopic:
    Type: AWS::SNS::Topic
    Properties:
      TopicName: support-control-plane-events
      DisplayName: AWS Support & Health events
      KmsMasterKeyId: alias/aws/sns

  SupportEventsTopicPolicy:
    Type: AWS::SNS::TopicPolicy
    Properties:
      Topics:
        - !Ref SupportEventsTopic
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: AllowEventBridgePublish
            Effect: Allow
            Principal:
              Service: events.amazonaws.com
            Action: 'sns:Publish'
            Resource: !Ref SupportEventsTopic
            Condition:
              StringEquals:
                'aws:SourceAccount': !Ref 'AWS::AccountId'

  SupportEventsSubscription:
    Type: AWS::SNS::Subscription
    Properties:
      TopicArn: !Ref SupportEventsTopic
      Protocol: email
      Endpoint: !Ref NotificationEmail

  ############################################################
  # 1. Every AWS Health event -> SNS (audit trail, all plans)
  ############################################################
  HealthAllEventsRule:
    Type: AWS::Events::Rule
    Properties:
      Name: aws-health-all-events
      Description: Fan out every AWS Health event for the account.
      EventPattern:
        source:
          - aws.health
      State: ENABLED
      Targets:
        - Id: sns
          Arn: !Ref SupportEventsTopic
          InputTransformer:
            InputPathsMap:
              service: '$.detail.service'
              category: '$.detail.eventTypeCategory'
              code: '$.detail.eventTypeCode'
              region: '$.detail.eventRegion'
              time: '$.time'
            InputTemplate: |
              "[AWS Health] <service> / <category>"
              "code:   <code>"
              "region: <region>"
              "time:   <time>"

  ############################################################
  # 2. Credential exposure -> immediate, unconditional page
  ############################################################
  HealthCredentialsExposedRule:
    Type: AWS::Events::Rule
    Properties:
      Name: aws-health-credentials-exposed
      Description: AWS detected exposed credentials for this account.
      EventPattern:
        source:
          - aws.health
        detail-type:
          - 'AWS Health Event'
        detail:
          eventTypeCode:
            - AWS_RISK_CREDENTIALS_EXPOSED
            - AWS_RISK_CREDENTIALS_COMPROMISED
      State: ENABLED
      Targets:
        - Id: sns
          Arn: !Ref SupportEventsTopic

  ############################################################
  # 3. Operational issues on monitored services -> Support case
  ############################################################
  AutoCaseFunctionRole:
    Type: AWS::IAM::Role
    Condition: IsSupportRegion
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: lambda.amazonaws.com
            Action: 'sts:AssumeRole'
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
      Policies:
        - PolicyName: support-write
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              # The AWS Support API does NOT support resource-level
              # permissions. Resource must be '*'; scope with conditions
              # on the calling principal instead.
              - Effect: Allow
                Action:
                  - 'support:CreateCase'
                  - 'support:AddCommunicationToCase'
                  - 'support:DescribeCases'
                  - 'support:DescribeSeverityLevels'
                  - 'support:DescribeServices'
                Resource: '*'
              - Effect: Allow
                Action: 'sns:Publish'
                Resource: !Ref SupportEventsTopic

  AutoCaseFunction:
    Type: AWS::Lambda::Function
    Condition: IsSupportRegion
    Properties:
      FunctionName: health-event-to-support-case
      Runtime: python3.12
      Handler: index.handler
      Timeout: 60
      MemorySize: 256
      Role: !GetAtt AutoCaseFunctionRole.Arn
      Environment:
        Variables:
          SEVERITY: !Ref AutoCaseSeverity
          TOPIC_ARN: !Ref SupportEventsTopic
          MONITORED: !Join [',', !Ref MonitoredHealthServices]
      Code:
        # NOTE: inline ZipFile is capped at 4096 characters by CloudFormation.
        ZipFile: |
          import json, os, boto3

          # support/trustedadvisor are served ONLY from us-east-1.
          support = boto3.client("support", region_name="us-east-1")
          sns = boto3.client("sns")

          MONITORED = {s.strip().upper() for s in os.environ["MONITORED"].split(",")}
          SEVERITY = os.environ["SEVERITY"]
          TOPIC = os.environ["TOPIC_ARN"]

          def allowed_severity(requested):
              """Never assume a severity exists; the plan decides."""
              levels = [l["code"] for l in
                        support.describe_severity_levels(language="en")["severityLevels"]]
              if requested in levels:
                  return requested
              for fallback in ("urgent", "high", "normal", "low"):
                  if fallback in levels:
                      return fallback
              raise RuntimeError("no usable severity level: %s" % levels)

          def handler(event, context):
              d = event.get("detail", {})
              service = (d.get("service") or "").upper()
              category = d.get("eventTypeCategory")

              if category != "issue" or service not in MONITORED:
                  return {"skipped": True, "service": service, "category": category}

              desc = "\n".join(
                  x.get("latestDescription", "")
                  for x in d.get("eventDescription", [])
              )
              entities = d.get("affectedEntities", [])
              body = (
                  "Automatically opened from an AWS Health event.\n\n"
                  f"eventTypeCode: {d.get('eventTypeCode')}\n"
                  f"eventRegion:   {d.get('eventRegion')}\n"
                  f"startTime:     {d.get('startTime')}\n"
                  f"affected:      {len(entities)} entities\n\n"
                  f"{desc}\n"
              )

              case = support.create_case(
                  subject=f"[auto] {service} issue: {d.get('eventTypeCode')}",
                  serviceCode="general-info",
                  categoryCode="using-aws",
                  severityCode=allowed_severity(SEVERITY),
                  communicationBody=body[:8000],
                  language="en",
                  issueType="technical",
              )
              sns.publish(
                  TopicArn=TOPIC,
                  Subject=f"Support case opened: {service}",
                  Message=json.dumps({"caseId": case["caseId"], "detail": d}, default=str),
              )
              return case

  HealthIssueRule:
    Type: AWS::Events::Rule
    Condition: IsSupportRegion
    Properties:
      Name: aws-health-issue-to-case
      Description: Open a Support case for AWS-side operational issues.
      EventPattern:
        source:
          - aws.health
        detail:
          eventTypeCategory:
            - issue
      State: ENABLED
      Targets:
        - Id: lambda
          Arn: !GetAtt AutoCaseFunction.Arn

  HealthIssueRulePermission:
    Type: AWS::Lambda::Permission
    Condition: IsSupportRegion
    Properties:
      FunctionName: !GetAtt AutoCaseFunction.Arn
      Action: 'lambda:InvokeFunction'
      Principal: events.amazonaws.com
      SourceArn: !GetAtt HealthIssueRule.Arn

  ############################################################
  # 4. Trusted Advisor: refresh respecting cooldown, emit metrics
  ############################################################
  TrustedAdvisorFunctionRole:
    Type: AWS::IAM::Role
    Condition: IsSupportRegion
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: lambda.amazonaws.com
            Action: 'sts:AssumeRole'
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
      Policies:
        - PolicyName: trusted-advisor-read
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - 'support:DescribeTrustedAdvisorChecks'
                  - 'support:DescribeTrustedAdvisorCheckResult'
                  - 'support:DescribeTrustedAdvisorCheckRefreshStatuses'
                  - 'support:RefreshTrustedAdvisorCheck'
                Resource: '*'
              - Effect: Allow
                Action: 'cloudwatch:PutMetricData'
                Resource: '*'
                Condition:
                  StringEquals:
                    'cloudwatch:namespace': 'Custom/TrustedAdvisor'

  TrustedAdvisorFunction:
    Type: AWS::Lambda::Function
    Condition: IsSupportRegion
    Properties:
      FunctionName: trusted-advisor-metrics
      Runtime: python3.12
      Handler: index.handler
      Timeout: 300
      MemorySize: 256
      Role: !GetAtt TrustedAdvisorFunctionRole.Arn
      Environment:
        Variables:
          CHECK_IDS: !Join [',', !Ref TrustedAdvisorCheckIds]
      Code:
        ZipFile: |
          import os, boto3

          support = boto3.client("support", region_name="us-east-1")
          cw = boto3.client("cloudwatch")

          CHECKS = [c.strip() for c in os.environ["CHECK_IDS"].split(",") if c.strip()]

          def handler(event, context):
              # Only refresh checks that are actually off cooldown.
              statuses = support.describe_trusted_advisor_check_refresh_statuses(
                  checkIds=CHECKS)["statuses"]
              cooldown = {s["checkId"]: s["millisUntilNextRefreshable"] for s in statuses}

              refreshed = []
              for cid in CHECKS:
                  if cooldown.get(cid, 0) == 0:
                      support.refresh_trusted_advisor_check(checkId=cid)
                      refreshed.append(cid)

              metrics, report = [], {}
              for cid in CHECKS:
                  r = support.describe_trusted_advisor_check_result(
                      checkId=cid, language="en")["result"]
                  summary = r["resourcesSummary"]
                  report[cid] = {
                      "status": r["status"],
                      "flagged": summary["resourcesFlagged"],
                      "timestamp": r["timestamp"],
                  }
                  for name, value in (
                      ("FlaggedResources", summary["resourcesFlagged"]),
                      ("SuppressedResources", summary["resourcesSuppressed"]),
                      ("IsRed", 1 if r["status"] == "error" else 0),
                      ("IsYellow", 1 if r["status"] == "warning" else 0),
                  ):
                      metrics.append({
                          "MetricName": name,
                          "Dimensions": [{"Name": "CheckId", "Value": cid}],
                          "Value": float(value),
                          "Unit": "Count",
                      })

              for i in range(0, len(metrics), 20):
                  cw.put_metric_data(Namespace="Custom/TrustedAdvisor",
                                     MetricData=metrics[i:i + 20])

              return {"refreshed": refreshed, "cooldown_ms": cooldown, "results": report}

  TrustedAdvisorSchedule:
    Type: AWS::Events::Rule
    Condition: IsSupportRegion
    Properties:
      Name: trusted-advisor-metrics-schedule
      Description: Refresh (when permitted) and publish Trusted Advisor metrics.
      ScheduleExpression: 'rate(6 hours)'
      State: ENABLED
      Targets:
        - Id: lambda
          Arn: !GetAtt TrustedAdvisorFunction.Arn

  TrustedAdvisorSchedulePermission:
    Type: AWS::Lambda::Permission
    Condition: IsSupportRegion
    Properties:
      FunctionName: !GetAtt TrustedAdvisorFunction.Arn
      Action: 'lambda:InvokeFunction'
      Principal: events.amazonaws.com
      SourceArn: !GetAtt TrustedAdvisorSchedule.Arn

  TrustedAdvisorRedAlarm:
    Type: AWS::CloudWatch::Alarm
    Condition: IsSupportRegion
    Properties:
      AlarmName: trusted-advisor-service-limits-red
      AlarmDescription: Service Limits check is red (a quota is at or over 80%).
      Namespace: Custom/TrustedAdvisor
      MetricName: IsRed
      Dimensions:
        - Name: CheckId
          Value: eW7HH0l7J9
      Statistic: Maximum
      Period: 21600
      EvaluationPeriods: 1
      Threshold: 0
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: breaching
      AlarmActions:
        - !Ref SupportEventsTopic
      OKActions:
        - !Ref SupportEventsTopic

  ############################################################
  # 5. Real-time quota alarm via SERVICE_QUOTA() metric math
  ############################################################
  Ec2VcpuQuotaAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: ec2-standard-vcpu-quota-80pct
      AlarmDescription: >
        On-Demand Standard vCPU usage is above 80% of the account quota.
        Uses AWS/Usage + SERVICE_QUOTA() so it does not depend on
        Trusted Advisor's refresh interval.
      ComparisonOperator: GreaterThanThreshold
      EvaluationPeriods: 1
      Threshold: 80
      TreatMissingData: notBreaching
      AlarmActions:
        - !Ref SupportEventsTopic
      Metrics:
        - Id: usage
          ReturnData: false
          MetricStat:
            Metric:
              Namespace: AWS/Usage
              MetricName: ResourceCount
              Dimensions:
                - Name: Service
                  Value: EC2
                - Name: Class
                  Value: Standard/OnDemand
                - Name: Type
                  Value: Resource
                - Name: Resource
                  Value: vCPU
            Period: 300
            Stat: Maximum
        - Id: quota
          ReturnData: false
          Expression: 'SERVICE_QUOTA(usage)'
        - Id: pct
          ReturnData: true
          Label: vCPU quota utilisation (%)
          Expression: '(usage / quota) * 100'

Outputs:
  TopicArn:
    Description: SNS topic carrying all support-plane events.
    Value: !Ref SupportEventsTopic
    Export:
      Name: !Sub '${AWS::StackName}-topic-arn'

  AutoCaseFunctionName:
    Condition: IsSupportRegion
    Description: Lambda that opens Support cases from AWS Health issues.
    Value: !Ref AutoCaseFunction

  SupportApiNote:
    Description: Reminder about plan gating.
    Value: >-
      support:* and health:Describe* require Business, Enterprise On-Ramp or
      Enterprise Support. On Basic/Developer these calls fail with
      SubscriptionRequiredException and the case-opening path is inert.
```

### 9.2 Terraform — agregación de health a nivel de organización y plantillas de cuota

Se aplica desde la **cuenta de administración**. Establece el trusted access, un bus de eventos central al que las cuentas miembro reenvían eventos de Health, y una plantilla de aumento de cuota que pre-aprovisiona cada cuenta futura.

```hcl
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40"
    }
  }
}

# Support, Trusted Advisor and Health signing all live in us-east-1.
provider "aws" {
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}
data "aws_organizations_organization" "this" {}

############################################################
# 1. Trusted access: enables the organizational view of
#    AWS Health and org-wide Trusted Advisor recommendations.
############################################################
resource "aws_organizations_organization" "this" {
  feature_set = "ALL"

  aws_service_access_principals = [
    "health.amazonaws.com",          # AWS Health organizational view
    "reporting.trustedadvisor.amazonaws.com", # Trusted Advisor org reporting
    "servicequotas.amazonaws.com",   # Service Quotas request templates
    "cloudtrail.amazonaws.com",
    "config.amazonaws.com",
  ]

  enabled_policy_types = ["SERVICE_CONTROL_POLICY"]

  lifecycle {
    # The org already exists; never let Terraform try to recreate it.
    prevent_destroy = true
  }
}

############################################################
# 2. Central event bus for AWS Health events from members.
############################################################
resource "aws_cloudwatch_event_bus" "support" {
  name = "org-support-plane"
}

resource "aws_cloudwatch_event_bus_policy" "support" {
  event_bus_name = aws_cloudwatch_event_bus.support.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowOrgMembersToPutHealthEvents"
        Effect    = "Allow"
        Principal = "*"
        Action    = "events:PutEvents"
        Resource  = aws_cloudwatch_event_bus.support.arn
        Condition = {
          StringEquals = {
            "aws:PrincipalOrgID" = data.aws_organizations_organization.this.id
          }
        }
      }
    ]
  })
}

resource "aws_cloudwatch_event_rule" "org_health" {
  name           = "org-health-issues"
  description    = "AWS Health issue and scheduledChange events from all member accounts."
  event_bus_name = aws_cloudwatch_event_bus.support.name

  event_pattern = jsonencode({
    source = ["aws.health"]
    detail = {
      eventTypeCategory = ["issue", "scheduledChange", "accountNotification"]
    }
  })
}

resource "aws_sns_topic" "org_health" {
  name              = "org-health-events"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_policy" "org_health" {
  arn = aws_sns_topic.org_health.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowEventBridgePublish"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.org_health.arn
        Condition = {
          StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        }
      }
    ]
  })
}

resource "aws_cloudwatch_event_target" "org_health_sns" {
  rule           = aws_cloudwatch_event_rule.org_health.name
  event_bus_name = aws_cloudwatch_event_bus.support.name
  target_id      = "sns"
  arn            = aws_sns_topic.org_health.arn

  input_transformer {
    input_paths = {
      account = "$.account"
      service = "$.detail.service"
      code    = "$.detail.eventTypeCode"
      region  = "$.detail.eventRegion"
    }
    input_template = <<-EOT
      "[org-health] account=<account> service=<service>"
      "code=<code> region=<region>"
    EOT
  }
}

############################################################
# 3. Quota increase template — applied to NEW org accounts.
############################################################
resource "aws_servicequotas_template_association" "org" {
  depends_on = [aws_organizations_organization.this]
}

locals {
  quota_template = {
    ec2_standard_vcpu = {
      service_code = "ec2"
      quota_code   = "L-1216C47A" # Running On-Demand Standard instances (vCPU)
      value        = 512
    }
    vpcs_per_region = {
      service_code = "vpc"
      quota_code   = "L-F678F1CE" # VPCs per Region
      value        = 20
    }
    elastic_ips = {
      service_code = "ec2"
      quota_code   = "L-0263D0A3" # EC2-VPC Elastic IPs
      value        = 20
    }
    lambda_concurrency = {
      service_code = "lambda"
      quota_code   = "L-B99A9384" # Concurrent executions
      value        = 3000
    }
  }
}

resource "aws_servicequotas_template" "defaults" {
  for_each = local.quota_template

  region       = "us-east-1"
  service_code = each.value.service_code
  quota_code   = each.value.quota_code
  value        = each.value.value
}

############################################################
# 4. Explicit, adjustable quota in THIS account (not a template).
############################################################
resource "aws_servicequotas_service_quota" "ec2_vcpu" {
  service_code = "ec2"
  quota_code   = "L-1216C47A"
  value        = 512
}

############################################################
# 5. Read-only support role for on-call engineers.
############################################################
resource "aws_iam_role" "oncall_support" {
  name = "oncall-support-reader"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "sts:AssumeRole"
        Condition = {
          Bool = { "aws:MultiFactorAuthPresent" = "true" }
        }
      }
    ]
  })
}

# AWSSupportAccess is the AWS-managed policy that grants full Support API
# access. It cannot be scoped by resource -- the Support API has no
# resource-level permissions. Scope by principal and MFA instead.
resource "aws_iam_role_policy_attachment" "oncall_support" {
  role       = aws_iam_role.oncall_support.name
  policy_arn = "arn:aws:iam::aws:policy/AWSSupportAccess"
}

resource "aws_iam_role_policy" "oncall_health_ta" {
  name = "health-and-trusted-advisor-read"
  role = aws_iam_role.oncall_support.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "health:DescribeEvents",
          "health:DescribeEventDetails",
          "health:DescribeAffectedEntities",
          "health:DescribeEventAggregates",
          "health:DescribeEventTypes",
          "health:DescribeEventsForOrganization",
          "health:DescribeAffectedAccountsForOrganization",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "trustedadvisor:ListChecks",
          "trustedadvisor:ListRecommendations",
          "trustedadvisor:GetRecommendation",
          "trustedadvisor:ListRecommendationResources",
          "trustedadvisor:ListOrganizationRecommendations",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "servicequotas:GetServiceQuota",
          "servicequotas:ListServiceQuotas",
          "servicequotas:ListAWSDefaultServiceQuotas",
          "servicequotas:ListRequestedServiceQuotaChangeHistory",
        ]
        Resource = "*"
      }
    ]
  })
}

output "org_health_topic_arn" {
  value       = aws_sns_topic.org_health.arn
  description = "SNS topic carrying org-wide AWS Health events."
}

output "support_plan_prerequisite" {
  value = join(" ", [
    "health:Describe* and support:* require Business, Enterprise On-Ramp",
    "or Enterprise Support. On Basic/Developer these policies are valid but",
    "every call returns SubscriptionRequiredException.",
  ])
}
```

### 9.3 Política de escalamiento declarativa (artefacto operativo)

El mapeo de tu severidad interna a un código de severidad de AWS debería ser un artefacto revisado, no un valor que alguien tipea en la consola a las 03:00.

```yaml
# ops/aws-support-escalation.yaml
# Maps internal incident severity to AWS Support case parameters.
# Validated in CI against `aws support describe-severity-levels`.
apiVersion: ops.internal/v1
kind: SupportEscalationPolicy
metadata:
  name: production-escalation
  supportPlan: enterprise           # basic | developer | business | enterprise-onramp | enterprise
  supportApiRegion: us-east-1       # non-negotiable: only endpoint that exists

spec:
  # AWS response-time targets for THIS plan. CI asserts these still match
  # describe-severity-levels output; drift means the plan changed.
  severities:
    - internal: SEV1
      awsSeverityCode: critical
      awsSeverityName: Business-critical system down
      targetFirstResponse: 15m
      criteria: >-
        Customer-facing revenue path is fully unavailable in all regions,
        or data loss is in progress.
      requiredBefore:
        - Incident commander assigned
        - Status page updated
        - TAM paged out of band via the Enterprise escalation number
      openVia: [console, support-api, support-app-slack, phone]

    - internal: SEV2
      awsSeverityCode: urgent
      awsSeverityName: Production system down
      targetFirstResponse: 1h
      criteria: Production workload down in one region; failover available.
      openVia: [console, support-api, support-app-slack]

    - internal: SEV3
      awsSeverityCode: high
      awsSeverityName: Production system impaired
      targetFirstResponse: 4h
      criteria: Production degraded; SLO burn rate above 2x.
      openVia: [console, support-api]

    - internal: SEV4
      awsSeverityCode: normal
      awsSeverityName: System impaired
      targetFirstResponse: 12h
      criteria: Non-production impaired, or production with a workaround.
      openVia: [console, support-api]

    - internal: SEV5
      awsSeverityCode: low
      awsSeverityName: General guidance
      targetFirstResponse: 24h
      criteria: Questions, quota increases, architectural guidance.
      openVia: [console, support-api]

  # Quota increases follow a different path than incidents.
  quotaIncrease:
    preferredPath: service-quotas-api
    fallbackPath: support-case
    fallbackCaseParams:
      issueType: service-limit-increase
      severityCode: low
      leadTimeAssumption: 48h        # NEVER assume same-day
    preflight:
      - aws service-quotas get-service-quota --service-code {svc} --quota-code {code}
      - assert .Quota.Adjustable == true

  proactive:
    trustedAdvisorReviewCadence: weekly
    wellArchitectedReviewCadence: quarterly
    countdownRequestLeadTime: 6w     # AWS Countdown needs advance notice
    idrOnboardedWorkloads:
      - checkout-api
      - payments-ledger
```

---

## 10. Recorrido por el CLI con formas de salida reales

### 10.1 Establecer en qué plan estás realmente

No existe una API `aws support get-plan`. La sonda que sostiene el peso es `describe-severity-levels`: solo tiene éxito en Business y superior, y las severidades que devuelve identifican el nivel.

```console
$ aws support describe-severity-levels --language en --region us-east-1
{
    "severityLevels": [
        {
            "code": "low",
            "name": "General guidance"
        },
        {
            "code": "normal",
            "name": "System impaired"
        },
        {
            "code": "high",
            "name": "Production system impaired"
        },
        {
            "code": "urgent",
            "name": "Production system down"
        },
        {
            "code": "critical",
            "name": "Business-critical system down"
        }
    ]
}
```

`critical` presente ⇒ Enterprise On-Ramp o Enterprise. Ausente pero `urgent` presente ⇒ Business. Toda la llamada falla ⇒ Basic o Developer:

```console
$ aws support describe-severity-levels --language en --region us-east-1

An error occurred (SubscriptionRequiredException) when calling the
DescribeSeverityLevels operation: Amazon Web Services Premium Support
Subscription is required to use this service.
```

Un one-liner que clasifica la cuenta:

```console
$ aws support describe-severity-levels --region us-east-1 --language en \
    --query 'severityLevels[].code' --output text 2>/dev/null \
  | awk '{ if ($0 ~ /critical/) print "enterprise-or-onramp";
           else if ($0 ~ /urgent/) print "business";
           else print "unknown" }' \
  || echo "basic-or-developer"
enterprise-or-onramp
```

### 10.2 Abrir, inspeccionar y resolver un caso

```console
$ aws support describe-services --language en --region us-east-1 \
    --query 'services[?contains(name, `Elastic Compute`)]'
[
    {
        "code": "amazon-elastic-compute-cloud-linux",
        "name": "Amazon Elastic Compute Cloud (Linux)",
        "categories": [
            { "code": "apis",              "name": "APIs" },
            { "code": "instance-issue",    "name": "Instance Issue" },
            { "code": "networking",        "name": "Networking" },
            { "code": "performance",       "name": "Performance" },
            { "code": "using-aws",         "name": "General Guidance" }
        ]
    }
]
```

```console
$ aws support create-case \
    --region us-east-1 \
    --subject "us-east-1a: 12 m6i instances stuck in 'pending' since 14:02 UTC" \
    --service-code amazon-elastic-compute-cloud-linux \
    --category-code instance-issue \
    --severity-code urgent \
    --issue-type technical \
    --language en \
    --cc-email-addresses platform-oncall@example.com \
    --communication-body "$(cat <<'EOF'
Impact: checkout-api autoscaling cannot add capacity in us-east-1.
Started: 2026-09-04T14:02Z. Ongoing.

Symptom: RunInstances succeeds, instances remain in 'pending' > 15 min,
then transition to 'terminated' with StateReason
"Server.InternalError: Internal error on launch".

Scope: us-east-1a only. us-east-1b and us-east-1c launch normally.
Instance type: m6i.2xlarge. AMI: ami-0abcdef1234567890.
Subnet: subnet-0123456789abcdef0 (172.31.16.0/20, 3891 free IPs).
Quota check: 412/512 vCPU used, not quota-bound.

Sample instance IDs:
i-0aa11bb22cc33dd44, i-0ee55ff66aa77bb88, i-0cc99dd00ee11ff22

Requested: confirm whether there is an AZ-level capacity or control-plane
issue in use-east-1a, and whether we should shift the ASG to 1b/1c.
EOF
)"
{
    "caseId": "case-111122223333-muen-2026-9c1a4f7b2d3e8a05"
}
```

```console
$ aws support describe-cases --region us-east-1 \
    --case-id-list case-111122223333-muen-2026-9c1a4f7b2d3e8a05 \
    --include-communications \
    --query 'cases[0].{id:displayId,status:status,sev:severityCode,svc:serviceCode,submitted:timeCreated,msgs:length(recentCommunications.communications)}'
{
    "id": "9876543210",
    "status": "work-in-progress",
    "sev": "urgent",
    "svc": "amazon-elastic-compute-cloud-linux",
    "submitted": "2026-09-04T14:19:07.000Z",
    "msgs": 3
}
```

```console
$ aws support add-communication-to-case --region us-east-1 \
    --case-id case-111122223333-muen-2026-9c1a4f7b2d3e8a05 \
    --communication-body "Mitigated by draining us-east-1a from the ASG at 14:41Z.
Leaving the case open to confirm root cause before we re-enable the AZ."
{
    "result": true
}
```

```console
$ aws support resolve-case --region us-east-1 \
    --case-id case-111122223333-muen-2026-9c1a4f7b2d3e8a05
{
    "initialCaseStatus": "work-in-progress",
    "finalCaseStatus": "resolved"
}
```

Los adjuntos (logs, salida de `describe-instances`) van a través de un attachment set, que **expira una hora después de su creación**, admite como máximo 3 archivos, de 5 MB cada uno:

```console
$ aws support add-attachments-to-set --region us-east-1 \
    --attachments fileName=ec2-describe.json,data=fileb://ec2-describe.json
{
    "attachmentSetId": "as-2f3g4h5j6k7l8m9n0p1q2r3s",
    "expiryTime": "2026-09-04T15:31:44.000Z"
}
```

### 10.3 Trusted Advisor desde el CLI

```console
$ aws support describe-trusted-advisor-checks --language en --region us-east-1 \
    --query 'checks[?category==`service_limits`].{id:id,name:name}' --output table
------------------------------------------------
|         DescribeTrustedAdvisorChecks          |
+--------------+-------------------------------+
|      id      |             name              |
+--------------+-------------------------------+
|  eW7HH0l7J9  |  Service Limits               |
+--------------+-------------------------------+
```

```console
$ aws support describe-trusted-advisor-checks --language en --region us-east-1 \
    --query 'length(checks)'
234
```

En Basic/Developer esa misma llamada devuelve solo el subconjunto core — el conteo es la manera más rápida de saber si tenés el conjunto completo de checks.

```console
$ aws support describe-trusted-advisor-check-refresh-statuses \
    --region us-east-1 --check-ids eW7HH0l7J9 HCP4007jGY
{
    "statuses": [
        {
            "checkId": "eW7HH0l7J9",
            "status": "none",
            "millisUntilNextRefreshable": 0
        },
        {
            "checkId": "HCP4007jGY",
            "status": "success",
            "millisUntilNextRefreshable": 2843117
        }
    ]
}
```

`millisUntilNextRefreshable: 2843117` ≈ 47 minutos. Llamar a `refresh-trusted-advisor-check` antes de que transcurran es aceptado pero no hace nada.

```console
$ aws support refresh-trusted-advisor-check --region us-east-1 --check-id eW7HH0l7J9
{
    "status": {
        "checkId": "eW7HH0l7J9",
        "status": "enqueued",
        "millisUntilNextRefreshable": 3600000
    }
}
```

```console
$ aws support describe-trusted-advisor-check-result \
    --region us-east-1 --check-id eW7HH0l7J9 --language en \
    --query 'result.{status:status,ts:timestamp,summary:resourcesSummary}'
{
    "status": "warning",
    "ts": "2026-09-04T14:52:11Z",
    "summary": {
        "resourcesProcessed": 187,
        "resourcesFlagged": 3,
        "resourcesIgnored": 0,
        "resourcesSuppressed": 1
    }
}
```

```console
$ aws support describe-trusted-advisor-check-result \
    --region us-east-1 --check-id eW7HH0l7J9 --language en \
    --query 'result.flaggedResources[?status!=`ok`].metadata' --output table
------------------------------------------------------------------------------------
|                      DescribeTrustedAdvisorCheckResult                            |
+-------------+--------+-----------------------------+---------+---------+----------+
|  us-east-1  |  EC2   |  Running On-Demand Standard |  512    |  438    |  Yellow  |
|  us-east-1  |  VPC   |  VPCs                       |  5      |  5      |  Red     |
|  eu-west-1  |  EC2   |  EC2-VPC Elastic IPs        |  5      |  4      |  Yellow  |
+-------------+--------+-----------------------------+---------+---------+----------+
```

El array de metadata es posicional: `[Region, Service, Limit Name, Limit Amount, Current Usage, Status]`. Amarillo a partir del 80%, rojo al 100%.

La API más nueva de Trusted Advisor (Business+) devuelve los mismos datos en una forma moderna y paginada:

```console
$ aws trustedadvisor list-recommendations --region us-east-1 \
    --pillar security --status error \
    --query 'recommendationSummaries[].{name:name,status:status,src:source,resources:resourcesAggregates.errorCount}'
[
    {
        "name": "MFA on Root Account",
        "status": "error",
        "src": "ta_check",
        "resources": 1
    },
    {
        "name": "Amazon S3 Bucket Permissions",
        "status": "error",
        "src": "ta_check",
        "resources": 2
    }
]
```

### 10.4 AWS Health

```console
$ aws health describe-events --region us-east-1 \
    --filter 'eventTypeCategories=issue,eventStatusCodes=open,startTimes=[{from=2026-09-01T00:00:00Z}]' \
    --query 'events[].{svc:service,code:eventTypeCode,region:region,status:statusCode,start:startTime}'
[
    {
        "svc": "EC2",
        "code": "AWS_EC2_OPERATIONAL_ISSUE",
        "region": "us-east-1",
        "status": "open",
        "start": "2026-09-04T14:05:00-00:00"
    }
]
```

```console
$ aws health describe-affected-entities --region us-east-1 \
    --filter 'eventArns=arn:aws:health:us-east-1::event/EC2/AWS_EC2_OPERATIONAL_ISSUE/AWS_EC2_OPERATIONAL_ISSUE_7F3A9C2E' \
    --query 'entities[].{id:entityValue,status:statusCode}' --output table
-------------------------------------------------
|          DescribeAffectedEntities              |
+--------------------------+---------------------+
|            id            |       status        |
+--------------------------+---------------------+
|  i-0aa11bb22cc33dd44     |  IMPAIRED           |
|  i-0ee55ff66aa77bb88     |  IMPAIRED           |
|  i-0cc99dd00ee11ff22     |  IMPAIRED           |
+--------------------------+---------------------+
```

Vista organizacional, desde la cuenta de administración después de habilitar el trusted access:

```console
$ aws health enable-health-service-access-for-organization --region us-east-1

$ aws health describe-health-service-status-for-organization --region us-east-1
{
    "healthServiceAccessStatusForOrganization": "ENABLED"
}

$ aws health describe-events-for-organization --region us-east-1 \
    --filter 'eventTypeCategories=scheduledChange' \
    --query 'events[].{code:eventTypeCode,svc:service,end:endTime}' --output table
--------------------------------------------------------------------------------
|                        DescribeEventsForOrganization                          |
+------------------------------------------------+---------+-------------------+
|                      code                      |   svc   |        end        |
+------------------------------------------------+---------+-------------------+
|  AWS_RDS_PLANNED_LIFECYCLE_EVENT               |  RDS    |  2026-10-15T06:00Z|
|  AWS_EC2_PERSISTENT_INSTANCE_RETIREMENT_...    |  EC2    |  2026-09-22T04:00Z|
+------------------------------------------------+---------+-------------------+

$ aws health describe-affected-accounts-for-organization --region us-east-1 \
    --event-arn arn:aws:health:global::event/RDS/AWS_RDS_PLANNED_LIFECYCLE_EVENT/AWS_RDS_PLANNED_LIFECYCLE_EVENT_B2C4D6E8
{
    "affectedAccounts": [
        "111122223333",
        "444455556666",
        "777788889999"
    ],
    "eventScopeCode": "ACCOUNT_SPECIFIC"
}
```

### 10.5 Service Quotas

```console
$ aws service-quotas get-service-quota \
    --service-code ec2 --quota-code L-1216C47A --region us-east-1
{
    "Quota": {
        "ServiceCode": "ec2",
        "ServiceName": "Amazon Elastic Compute Cloud (Amazon EC2)",
        "QuotaArn": "arn:aws:servicequotas:us-east-1:111122223333:ec2/L-1216C47A",
        "QuotaCode": "L-1216C47A",
        "QuotaName": "Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances",
        "Value": 512.0,
        "Unit": "None",
        "Adjustable": true,
        "GlobalQuota": false,
        "UsageMetric": {
            "MetricNamespace": "AWS/Usage",
            "MetricName": "ResourceCount",
            "MetricDimensions": {
                "Class": "Standard/OnDemand",
                "Resource": "vCPU",
                "Service": "EC2",
                "Type": "Resource"
            },
            "MetricStatisticRecommendation": "Maximum"
        }
    }
}
```

`Adjustable: true` es el punto de bifurcación. Si fuera `false`, el aumento debe ir por un caso de soporte.

```console
$ aws service-quotas request-service-quota-increase \
    --service-code ec2 --quota-code L-1216C47A --desired-value 1024 --region us-east-1
{
    "RequestedQuota": {
        "Id": "a1b2c3d4e5f67890a1b2c3d4e5f67890",
        "CaseId": "9876543211",
        "ServiceCode": "ec2",
        "QuotaCode": "L-1216C47A",
        "DesiredValue": 1024.0,
        "Status": "PENDING",
        "Created": "2026-09-04T15:10:22.481000-03:00",
        "Requester": "{\"accountId\":\"111122223333\",\"callerArn\":\"arn:aws:sts::111122223333:assumed-role/platform-admin/dalmine\"}",
        "QuotaArn": "arn:aws:servicequotas:us-east-1:111122223333:ec2/L-1216C47A"
    }
}
```

Fijate en `CaseId` — Service Quotas abre un caso de soporte en tu nombre. La solicitud hereda los tiempos de respuesta de tu plan.

```console
$ aws service-quotas list-requested-service-quota-change-history \
    --service-code ec2 --region us-east-1 \
    --query 'RequestedQuotas[].{q:QuotaName,want:DesiredValue,status:Status,case:CaseId}' --output table
---------------------------------------------------------------------------------
|              ListRequestedServiceQuotaChangeHistory                            |
+-----------------------------------------+---------+-----------+----------------+
|                    q                    |  want   |  status   |     case       |
+-----------------------------------------+---------+-----------+----------------+
|  Running On-Demand Standard instances   |  1024.0 |  PENDING  |  9876543211    |
|  VPCs per Region                        |  20.0   |  APPROVED |  9876543190    |
+-----------------------------------------+---------+-----------+----------------+
```

### 10.6 Support Automation Workflows (runbooks de SSM)

Business+ desbloquea la familia de documentos `AWSPremiumSupport-*`. Son los propios runbooks de diagnóstico de AWS Support, ejecutables por vos.

```console
$ aws ssm list-documents \
    --filters Key=Owner,Values=Amazon Key=Name,Values=AWSPremiumSupport \
    --query 'DocumentIdentifiers[].Name' --output text | tr '\t' '\n' | head -8
AWSPremiumSupport-DDoSResiliencyAssessment
AWSPremiumSupport-DiagnoseEC2Connectivity
AWSPremiumSupport-ManageRDSPerformanceInsights
AWSPremiumSupport-TroubleshootEKSCluster
AWSPremiumSupport-TroubleshootRDSIOPS
AWSPremiumSupport-TroubleshootS3PublicRead
```

```console
$ aws ssm start-automation-execution \
    --document-name AWSSupport-TroubleshootConnectivityToRDS \
    --parameters 'SourceType=EC2Instance,SourceIdentifier=i-0aa11bb22cc33dd44,DestinationIdentifier=prod-ledger-db'
{
    "AutomationExecutionId": "5f8e2a11-9b3c-4d7e-8a01-2c4b6d8e0f13"
}

$ aws ssm get-automation-execution \
    --automation-execution-id 5f8e2a11-9b3c-4d7e-8a01-2c4b6d8e0f13 \
    --query 'AutomationExecution.{status:AutomationExecutionStatus,out:Outputs}'
{
    "status": "Success",
    "out": {
        "evaluateSecurityGroups.Result": [
            "FAIL: sg-0f1e2d3c4b5a69788 attached to prod-ledger-db does not allow inbound tcp/5432 from sg-0987654321fedcba0"
        ]
    }
}
```

---

## 11. Verificación y diagnóstico de fallas

### 11.1 Tabla de decisión para los errores comunes

| Síntoma | Causa raíz | Verificación | Solución |
|---|---|---|---|
| `SubscriptionRequiredException` en cualquier llamada `support:*` o `health:Describe*` | La cuenta está en Basic o Developer | `aws support describe-services --region us-east-1` — el mismo error | Actualizar a Business+; no hay workaround por IAM |
| `Could not connect to the endpoint URL: "https://support.sa-east-1.amazonaws.com/"` | La Support API es **solo us-east-1** | `aws support describe-services` con y sin `--region us-east-1` | Pasar siempre `--region us-east-1`, o definir `AWS_REGION=us-east-1` para el tooling de soporte |
| `AccessDeniedException: User ... is not authorized to perform: support:CreateCase on resource: *` | La política de IAM acotó el recurso | `aws iam simulate-principal-policy --action-names support:CreateCase` | Support **no tiene permisos a nivel de recurso** — `Resource: "*"` es obligatorio; restringí con condiciones/principal en su lugar |
| `InvalidParameterValueException` en `--severity-code critical` | `critical` requiere Enterprise/On-Ramp | `aws support describe-severity-levels` | Descubrí las severidades en tiempo de ejecución; nunca las hardcodees |
| Todos los checks de Trusted Advisor en `not_available` | El SLR `AWSServiceRoleForTrustedAdvisor` fue borrado o está denegado por una SCP | `aws iam get-role --role-name AWSServiceRoleForTrustedAdvisor` | Recrear el SLR; auditar las SCPs por denegaciones de `iam:CreateServiceLinkedRole` |
| El timestamp del resultado de Trusted Advisor tiene días a pesar de refrescar | No se respetó el cooldown de refresco | `describe-trusted-advisor-check-refresh-statuses` → `millisUntilNextRefreshable > 0` | Condicionar los refrescos al valor del cooldown (ver §9.1) |
| `NoSuchResourceException` en `request-service-quota-increase` | La cuota no es ajustable mediante Service Quotas | `get-service-quota` → `"Adjustable": false` | Abrir un caso de soporte con `issueType=service-limit-increase` |
| `describe-cases` no devuelve nada para un caso que sabés que existe | La ventana por defecto es de **30 días**, y los casos resueltos quedan excluidos | Agregar `--include-resolved --after-time 2026-01-01T00:00:00Z` | Pasar siempre un `--after-time` explícito en los trabajos de reporte |
| La alarma de `SERVICE_QUOTA()` muestra `INSUFFICIENT_DATA` | La cuota no tiene `UsageMetric`, o el uso es genuinamente cero | `get-service-quota --query 'Quota.UsageMetric'` devuelve `null` | No todas las cuotas publican en `AWS/Usage`; caé de nuevo al check de Service Limits de Trusted Advisor |
| `describe-events-for-organization` a nivel de organización devuelve vacío | El trusted access no está habilitado, o se llamó desde una cuenta miembro | `aws health describe-health-service-status-for-organization` | `enable-health-service-access-for-organization` **desde la cuenta de administración**; dar tiempo de propagación |
| CloudFormation: `Template format error: ... ZipFile ... exceeds 4096 characters` | Fuente de Lambda inline demasiado largo | `wc -c` sobre el bloque de código extraído | Mover a un `Code.S3Bucket`/`S3Key` respaldado por S3 o a una imagen de contenedor |
| Los eventos de Health llegan a EventBridge pero el bus de la organización está vacío | Las cuentas miembro no tienen regla de reenvío al bus central | Buscar una regla con el bus central como target en la cuenta miembro | Desplegar la regla de reenvío vía StackSets a todas las cuentas miembro |

### 11.2 Un script de preflight

Corré esto antes de confiar en cualquier automatización de soporte. Falla ruidosamente en lugar de degradarse en silencio.

```bash
#!/usr/bin/env bash
# preflight-support-plane.sh — verify the support control plane is usable.
set -euo pipefail

export AWS_REGION=us-east-1
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
echo "account: ${ACCOUNT}"

fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. Support API reachable and plan sufficient.
if ! SEV=$(aws support describe-severity-levels --language en \
             --query 'severityLevels[].code' --output text 2>/dev/null); then
  fail "support API unavailable — account is on Basic or Developer"
fi
echo "severities: ${SEV}"
case "${SEV}" in
  *critical*) PLAN="enterprise|enterprise-onramp" ;;
  *urgent*)   PLAN="business" ;;
  *)          fail "unexpected severity set: ${SEV}" ;;
esac
echo "plan: ${PLAN}"

# 2. Health API reachable.
aws health describe-event-aggregates \
    --aggregate-field eventTypeCategory \
    --query 'eventAggregates' --output json >/dev/null \
  || fail "health API unavailable"
echo "health API: ok"

# 3. Full Trusted Advisor check set present.
N=$(aws support describe-trusted-advisor-checks --language en \
      --query 'length(checks)' --output text)
[ "${N}" -gt 50 ] || fail "only ${N} Trusted Advisor checks visible — core set only"
echo "trusted advisor checks: ${N}"

# 4. Service Limits check is not red.
ST=$(aws support describe-trusted-advisor-check-result \
       --check-id eW7HH0l7J9 --language en \
       --query 'result.status' --output text)
echo "service limits check: ${ST}"
[ "${ST}" != "error" ] || echo "WARN: a service quota is at 100%"

# 5. Service-linked roles present.
for ROLE in AWSServiceRoleForTrustedAdvisor AWSServiceRoleForSupport; do
  aws iam get-role --role-name "${ROLE}" >/dev/null 2>&1 \
    || fail "missing service-linked role ${ROLE}"
  echo "SLR ${ROLE}: ok"
done

echo "PASS: support control plane is operational"
```

```console
$ ./preflight-support-plane.sh
account: 111122223333
severities: low     normal  high    urgent  critical
plan: enterprise|enterprise-onramp
health API: ok
trusted advisor checks: 234
service limits check: warning
SLR AWSServiceRoleForTrustedAdvisor: ok
SLR AWSServiceRoleForSupport: ok
PASS: support control plane is operational
```

En una cuenta con plan Developer:

```console
$ ./preflight-support-plane.sh
account: 555566667777
FAIL: support API unavailable — account is on Basic or Developer
```

### 11.3 Verificar el camino de EventBridge sin esperar a una interrupción real

Los eventos de Health no se pueden inyectar — `aws.health` es una fuente bloqueada de AWS. Probá la mitad *aguas abajo* publicando un evento sintético en una fuente personalizada y ampliando temporalmente el patrón de la regla:

```console
$ aws events put-events --entries '[{
    "Source": "test.health",
    "DetailType": "AWS Health Event",
    "Detail": "{\"service\":\"EC2\",\"eventTypeCategory\":\"issue\",\"eventTypeCode\":\"SYNTHETIC_TEST\",\"eventRegion\":\"us-east-1\",\"eventDescription\":[{\"latestDescription\":\"synthetic drill\"}],\"affectedEntities\":[]}"
  }]'
{
    "FailedEntryCount": 0,
    "Entries": [
        { "EventId": "d3b07384-d9a0-4c9b-9c1e-7a5f2e8b4c06" }
    ]
}
```

Después confirmá que el target realmente se disparó, en lugar de confiar en el `FailedEntryCount`:

```console
$ aws cloudwatch get-metric-statistics \
    --namespace AWS/Events --metric-name TriggeredRules \
    --dimensions Name=RuleName,Value=aws-health-issue-to-case \
    --start-time "$(date -u -d '15 minutes ago' +%FT%TZ)" \
    --end-time "$(date -u +%FT%TZ)" \
    --period 300 --statistics Sum \
    --query 'Datapoints[].Sum'
[
    1.0
]
```

`FailedEntryCount: 0` significa que EventBridge aceptó el evento, **no** que alguna regla lo haya matcheado. `TriggeredRules` y los `Invocations`/`FailedInvocations` del target son la evidencia real. Restaurá el patrón de eventos de producción inmediatamente después del simulacro.

### 11.4 Las fallas silenciosas que vale la pena alarmar

| Falla | Por qué es silenciosa | Detección |
|---|---|---|
| SLR de Trusted Advisor borrado | Los checks reportan `not_available`, los dashboards muestran un vacío verdoso | Alarmar sobre la *ausencia* de la métrica `Custom/TrustedAdvisor` (`TreatMissingData: breaching`, como en §9.1) |
| Plan de soporte degradado en la renovación | La automatización empieza a lanzar `SubscriptionRequiredException` a logs que nadie lee | Correr el preflight de §11.2 de forma programada; alarmar sobre `Errors` del Lambda |
| Regla de EventBridge deshabilitada durante un trabajo no relacionado | Sin eventos, sin errores | Alarmar sobre `TriggeredRules` `Sum < 1` durante un período largo, o usar una regla de AWS Config para el estado de la regla |
| Plantilla de cuota no aplicada silenciosamente a una cuenta nueva | La cuenta arranca y golpea la cuota por defecto bajo carga | Verificar las cuotas aplicadas contra `list-aws-default-service-quotas` en el CI de baseline de cuentas |
| Caso auto-abierto con la severidad equivocada | La respuesta llega 4 horas tarde en vez de en 15 minutos | Loguear la severidad resuelta por `allowed_severity()` y alarmar cuando difiera de la solicitada |

---

## 12. Distinciones de cara al examen

Estos son los pares que usan quienes redactan los ítems de CLF-C02.

| Confusión | Resolución |
|---|---|
| AWS Health Dashboard vs AWS Health API | El dashboard (ambas vistas) es gratis en todos los planes; la **API** requiere Business+ |
| *Service health* vs *Your account health* | Service health es público y global; account health está personalizado a tus recursos |
| Checks core vs checks completos de Trusted Advisor | Basic/Developer reciben los core (service limits + un subconjunto de seguridad); Business+ recibe las seis categorías |
| Trusted Advisor vs Trusted Advisor Priority | Priority agrega recomendaciones curadas por el TAM, ordenadas y con ciclo de vida rastreado, y es **solo Enterprise** |
| Trusted Advisor vs AWS Config | Trusted Advisor = checks de buenas prácticas escritos por AWS; Config = tus propias reglas + historial de configuración |
| Trusted Advisor vs Well-Architected Tool | Trusted Advisor es automatizado y continuo; la WA Tool es una autoevaluación humana que produce un plan de mejora |
| Concierge vs TAM | Concierge = expertos en **facturación/cuenta**; TAM = asesor **técnico**. Ambos arrancan en Enterprise On-Ramp |
| Enterprise On-Ramp vs Enterprise | 30 min vs **15 min** para business-critical; **pool de TAMs** vs **TAM designado**; Priority e IDR son solo Enterprise |
| AWS Support vs AWS Managed Services | Support asesora; AMS **opera** tu infraestructura y requiere Enterprise Support |
| AWS ProServe vs Partner de APN vs AWS IQ | Los consultores propios de AWS vs una empresa partner vs un freelancer certificado individual (EE.UU.) |
| AWS Countdown vs IDR | Countdown = soporte de ingeniería para un **evento planificado**; IDR = monitoreo continuo con involucramiento en 5 minutos ante incidentes críticos **no planificados** |
| Service Quotas vs Service Limits de Trusted Advisor | Service Quotas es el sistema de registro y el mecanismo de cambio; Trusted Advisor es la *advertencia* del 80% construida encima |
| re:Post vs caso de soporte | re:Post es Q&A comunitario gratuito sin SLA; un caso es un objetivo de respuesta contratado |
| Equipo de abuso vs Support | Reportá el abuso **originado en AWS** a Trust & Safety, no mediante un caso de soporte técnico |
| Contactos en el plan Developer | Exactamente **un** contacto principal puede abrir casos; Business+ es ilimitado y gobernado por IAM |

Dos números que vale la pena memorizar de plano: **Business = 1 hora** para "production system down"; **Enterprise = 15 minutos** para "business-critical system down". Todo lo demás se puede derivar de la tabla de §3.2.

---

## Referencias

**Examen y certificación**
- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- AWS Certified Cloud Practitioner — https://aws.amazon.com/certification/certified-cloud-practitioner/
- AWS Skill Builder — https://skillbuilder.aws/

**AWS Support**
- Comparación de planes de AWS Support — https://aws.amazon.com/premiumsupport/plans/
- Precios de AWS Support — https://aws.amazon.com/premiumsupport/pricing/
- Guía de usuario de AWS Support — https://docs.aws.amazon.com/awssupport/latest/user/what-is-aws-support.html
- Severidad de casos y tiempos de respuesta — https://docs.aws.amazon.com/awssupport/latest/user/case-management.html#choosing-severity
- Referencia de la AWS Support API — https://docs.aws.amazon.com/awssupport/latest/APIReference/Welcome.html
- Referencia del CLI `aws support` — https://docs.aws.amazon.com/cli/latest/reference/support/
- AWS Support App en Slack — https://docs.aws.amazon.com/awssupport/latest/user/aws-support-app-for-slack.html
- Support Automation Workflows (runbooks de SSM) — https://docs.aws.amazon.com/systems-manager-automation-runbooks/latest/userguide/automation-awssupport.html

**Trusted Advisor**
- AWS Trusted Advisor — https://aws.amazon.com/premiumsupport/technology/trusted-advisor/
- Referencia de checks de Trusted Advisor — https://docs.aws.amazon.com/awssupport/latest/user/trusted-advisor-check-reference.html
- Trusted Advisor Priority — https://docs.aws.amazon.com/awssupport/latest/user/trustedadvisor-priority.html
- Referencia de la Trusted Advisor API — https://docs.aws.amazon.com/trustedadvisor/latest/APIReference/Welcome.html

**AWS Health**
- Guía de usuario de AWS Health — https://docs.aws.amazon.com/health/latest/ug/what-is-aws-health.html
- AWS Health Dashboard (service health público) — https://health.aws.amazon.com/health/status
- Referencia de la AWS Health API — https://docs.aws.amazon.com/health/latest/APIReference/Welcome.html
- Monitoreo de eventos de AWS Health con EventBridge — https://docs.aws.amazon.com/health/latest/ug/cloudwatch-events-health.html
- Agregación de AWS Health en una organización — https://docs.aws.amazon.com/health/latest/ug/aggregate-events.html

**Service Quotas**
- Guía de usuario de Service Quotas — https://docs.aws.amazon.com/servicequotas/latest/userguide/intro.html
- Cuotas de servicio de AWS (referencia por servicio) — https://docs.aws.amazon.com/general/latest/gr/aws_service_limits.html
- Plantillas de solicitud de cuota para Organizations — https://docs.aws.amazon.com/servicequotas/latest/userguide/organization-templates.html
- Metric math `SERVICE_QUOTA()` de CloudWatch — https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/using-metric-math.html

**Programas proactivos y profesionales**
- AWS Incident Detection and Response — https://docs.aws.amazon.com/awssupport/latest/user/incident-detection-and-response.html
- AWS Countdown — https://docs.aws.amazon.com/awssupport/latest/user/aws-countdown.html
- AWS Managed Services (AMS) — https://docs.aws.amazon.com/managedservices/latest/userguide/what-is-ams.html
- AWS Professional Services — https://aws.amazon.com/professional-services/
- AWS Partner Network — https://aws.amazon.com/partners/
- AWS IQ — https://aws.amazon.com/iq/
- AWS Marketplace — https://aws.amazon.com/marketplace/

**Recursos técnicos**
- Documentación de AWS — https://docs.aws.amazon.com/
- AWS Whitepapers & Guides — https://aws.amazon.com/whitepapers/
- AWS Architecture Center — https://aws.amazon.com/architecture/
- AWS Prescriptive Guidance — https://aws.amazon.com/prescriptive-guidance/
- AWS Solutions Library — https://aws.amazon.com/solutions/
- AWS Well-Architected Framework — https://docs.aws.amazon.com/wellarchitected/latest/framework/welcome.html
- AWS Well-Architected Tool — https://docs.aws.amazon.com/wellarchitected/latest/userguide/intro.html
- AWS re:Post — https://repost.aws/
- AWS re:Post Knowledge Center — https://repost.aws/knowledge-center
- AWS Blogs — https://aws.amazon.com/blogs/
- AWS Artifact — https://docs.aws.amazon.com/artifact/latest/ug/what-is-aws-artifact.html
- AWS Security Bulletins — https://aws.amazon.com/security/security-bulletins/
- Reportar abuso en AWS — https://support.aws.amazon.com/#/contacts/report-abuse