# 1.2 — Identificar los principios de diseño de la nube de AWS

> **Contexto de examen (CLF-C02).** El dominio 1 "Cloud Concepts" representa el 24% del examen; la task statement 1.2 tiene un peso relativo de **6.0** en este temario. La guía del examen acota esta tarea a *"identify design principles of the AWS Cloud"* — en la práctica, el **AWS Well-Architected Framework**: sus seis pilares, los principios de diseño dentro de cada pilar, los principios de diseño generales y el mecanismo de revisión (la AWS Well-Architected Tool). Este material trata los principios como los tiene que tratar un Platform Architect: como **restricciones de ingeniería falsables y con costos medibles**, no como un póster colgado en la pared.

---

## 1. El problema de producción que estos principios existen para resolver

### 1.1 Una narrativa de falla que ya viste antes

Una API de pagos se migra desde un datacenter de colocation a AWS. La migración es "exitosa": misma topología de tres capas, mismo monolito Java, mismo MySQL, corriendo sobre EC2 en lugar de hardware Dell. Seis semanas después:

```
02:14 UTC  us-east-1 AZ use1-az4 experiences degraded EBS I/O
02:14 UTC  app-01, app-02, app-03 (all in use1-az4) stop responding
02:15 UTC  ALB health checks fail -> 0 healthy targets -> HTTP 503 to all clients
02:15 UTC  RDS primary (single-AZ, use1-az4) unreachable
02:41 UTC  On-call finds the runbook is a Confluence page last edited 14 months ago
03:58 UTC  Manual restore from a 24h-old snapshot into use1-az1 begins
07:20 UTC  Service restored. RPO ~19 h of transactions. RTO 5 h 06 m.
```

Nada de esto es un defecto de AWS. Cada uno de estos modos de falla fue **diseñado adentro** al importar supuestos de on-premises a un entorno donde esos supuestos son falsos. El Well-Architected Framework es, en el fondo, el catálogo de esos supuestos invalidados.

### 1.2 Los supuestos que la nube invalida

| Supuesto on-premises | Por qué valía on-prem | Por qué es falso en AWS | Principio que lo reemplaza |
|---|---|---|---|
| El hardware es escaso y lento de conseguir → **comprá para el pico, con 3 años de anticipación** | 8–16 semanas de lead time, ciclo de capex | Capacidad aprovisionada por API en segundos; pagás lo que usás | *Stop guessing your capacity needs* |
| Los servidores son mascotas: con nombre, parcheados en el lugar, longevos | Reconstruir significaba una visita al rack | Las instancias son ganado: una AMI + un launch template reconstruyen una en 90 s | *Automatically recover from failure*; *make frequent, small, reversible changes* |
| Los entornos de test son más chicos que producción | Un segundo datacenter completo es impagable | Un clon a escala de producción cuesta horas de runtime, y después se destruye | *Test systems at production scale* |
| El plan de DR es un documento | Probar el failover ponía en riesgo el único datacenter | Game days sobre infraestructura real con AWS FIS | *Test recovery procedures*; *improve through game days* |
| El escalado vertical es la historia del escalado | Una caja grande salía más barato que muchas chicas | El escalado horizontal elimina el dominio de falla único y el techo | *Scale horizontally to increase aggregate workload availability* |
| Un datacenter = un dominio de falla, y punto | Tenías un solo edificio | Múltiples AZ aisladas por Region, a ≤ ~1 ms de distancia, están a un parámetro de API | *Design for failure*; multi-AZ como default |
| La arquitectura se decide una vez, al principio | Cambiar significaba volver a comprar | La infraestructura como código convierte la arquitectura en un experimento | *Allow for evolutionary architectures*; *automate to make architectural experimentation easier* |
| El costo es una línea fija que le pertenece a Finanzas | Capex, amortizado, invisible para los ingenieros | El `terraform apply` de cada ingeniero mueve la factura | *Implement Cloud Financial Management*; *analyze and attribute expenditure* |

**La conclusión del arquitecto:** un lift-and-shift no es un acto neutral. Preserva la topología *y* los modos de falla, mientras le suma el modelo de costos de la nube. Los principios de diseño existen para forzar que la segunda mitad de la migración — el rediseño — efectivamente ocurra.

---

## 2. El AWS Well-Architected Framework: estructura y mecánica

### 2.1 El modelo de objetos

El Framework no es prosa; es un modelo de datos consultable, y por eso se puede manejar desde la CLI e integrar en CI.

```
Workload                      (the thing you review — an app + its infra + its people)
 └─ Lens                      (a question set: "wellarchitected" core, or serverless/SaaS/ML/…)
     └─ Pillar   × 6          (operationalExcellence, security, reliability,
     │                         performance, costOptimization, sustainability)
         └─ Question × ~58    (core lens; e.g. REL 11 "How do you design your workload
             │                 to withstand component failures?")
             └─ Best practice (choices you mark as implemented / not applicable)
                 └─ Risk      HIGH (HRI) | MEDIUM (MRI) | NONE | UNANSWERED
                             └─ Improvement Plan (links to prescriptive guidance)
Milestone                     (an immutable snapshot of all answers at a point in time)
```

**Por qué el milestone importa operativamente:** una revisión Well-Architected sin milestone es una opinión. Un milestone tomado antes y después de un trimestre de remediación es una **medición** — la cantidad de HRI pasó de 14 a 3, y podés demostrar qué preguntas se movieron.

### 2.2 Los seis pilares

| Pilar | Pregunta central que responde | Métrica principal que le pertenece a un SRE | Servicios AWS característicos |
|---|---|---|---|
| **Operational Excellence** | ¿Podemos operar y evolucionar esto de forma segura y aprender de ello? | Change failure rate, MTTR, frecuencia de despliegue | CloudFormation, CDK, Systems Manager, CloudWatch, X-Ray, CodePipeline |
| **Security** | ¿Podemos proteger datos, sistemas y activos mientras entregamos valor? | % de acciones privilegiadas hechas por humanos, tiempo medio hasta revocar, cobertura de cifrado | IAM, IAM Identity Center, KMS, GuardDuty, Security Hub, CloudTrail, Config |
| **Reliability** | ¿Hace lo que se supone que tiene que hacer, correcta y consistentemente, y se recupera? | Disponibilidad (SLO), RTO, RPO, consumo del error budget | Multi-AZ, Auto Scaling, Route 53, ELB, Backup, FIS, Resilience Hub |
| **Performance Efficiency** | ¿Usamos los recursos de cómputo eficientemente a medida que cambian la demanda y la tecnología? | Latencia p99, utilización, throughput por vCPU | Graviton, Lambda, CloudFront, ElastiCache, Compute Optimizer, Aurora |
| **Cost Optimization** | ¿Estamos corriendo al menor precio posible para el resultado requerido? | Costo unitario ($ por 1 000 transacciones), cobertura de compromisos, % de desperdicio | Cost Explorer, Budgets, Savings Plans, Spot, S3 Intelligent-Tiering |
| **Sustainability** | ¿Estamos minimizando el impacto ambiental del workload? | Utilización, recursos aprovisionados por unidad de trabajo | Graviton, Auto Scaling, Customer Carbon Footprint Tool, ciclo de vida de S3 |

> **Nota histórica para el examen:** Sustainability se agregó en **diciembre de 2021** como sexto pilar. Las preguntas escritas contra material más viejo a veces dicen "cinco pilares" — CLF-C02 usa seis.

### 2.3 Los seis principios de diseño *generales*

Están por encima de los pilares y aplican a todo el Framework.

| # | Principio | Qué significa mecánicamente | Antipatrón que elimina |
|---|---|---|---|
| 1 | **Stop guessing your capacity needs** | Auto Scaling manejado por una señal real de demanda; escalar hacia adentro tanto como hacia afuera | La flota dimensionada para el pico a 3 años, al 8% de utilización |
| 2 | **Test systems at production scale** | Levantar un clon a tamaño real, correr la prueba de carga, destruirlo | "Funcionaba en staging, que es 1/10 del tamaño" |
| 3 | **Automate to make architectural experimentation easier** | IaC + pipelines, para que probar una variante cueste una hora, no un trimestre | Entornos snowflake construidos a mano |
| 4 | **Allow for evolutionary architectures** | Acoplamiento débil y contratos, para que un componente se pueda reemplazar | El diseño de 2019 congelado porque nadie se anima a tocarlo |
| 5 | **Drive architectures using data** | Deciden CloudWatch/X-Ray/Cost Explorer, no la antigüedad | "Usamos r5 porque siempre lo hicimos" |
| 6 | **Improve through game days** | Inyección de fallas programada y controlada contra infraestructura real | El runbook de DR nunca probado |

**Lectura SRE:** #2 y #6 son los dos que las organizaciones se saltean, y son los dos que deciden si los otros cuatro son reales. Una arquitectura "confiable" a la que nunca le sacaron una AZ de abajo es una *hipótesis sin probar*.

---

## 3. Los pilares, principio por principio

### 3.1 Operational Excellence

**Principios de diseño**

1. **Organize teams around business outcomes** — el equipo que es dueño del resultado es dueño del pager.
2. **Implement observability for actionable insights** — métricas, logs y trazas que respondan *"¿está afectado el cliente, y dónde?"*, no solamente *"¿está alta la CPU?"*.
3. **Safely automate where possible** — automatización con guardrails, límites de blast radius y un botón de parada.
4. **Make frequent, small, reversible changes** — los diffs chicos fallan más chico y revierten limpio.
5. **Refine operations procedures frequently** — los runbooks son código, revisados y ejercitados.
6. **Anticipate failure** — pre-mortems y FMEA antes del incidente.
7. **Learn from all operational events and metrics** — revisión post-incidente sin culpables; la salida es un cambio de código, no un documento.
8. **Use managed services** — reducir la superficie que operás.

**Trade-off: tamaño del cambio vs. riesgo del cambio**

| Estrategia de despliegue | Blast radius | Tiempo de rollback | Costo extra de infra | A qué principio se ajusta |
|---|---|---|---|---|
| In-place, todo de una | 100% de la flota | Redespliegue completo (minutos–horas) | 0 | ninguno — antipatrón |
| Rolling (`AutoScalingRollingUpdate`, `MaxBatchSize: 1`) | 1 instancia | Rolling update inverso | 0 | cambios chicos y reversibles |
| Blue/green (dos target groups) | 0% hasta el cutover, después 100% | Cambio de listener, segundos | +100% durante el cutover | cambios reversibles |
| Canary (target groups ponderados / alias de Lambda) | 5–10% del tráfico | Cambio de peso, segundos | +5–10% | chicos **y** reversibles |

**Costo de la observabilidad (orden de magnitud, precios de lista de us-east-1 — siempre volvé a chequear las páginas de pricing):** métricas custom de CloudWatch ≈ **$0.30 / métrica / mes** para las primeras 10 000; logs ingeridos ≈ **$0.50 / GB**; trazas de X-Ray ≈ **$5.00 / millón registradas**. Una flota de 40 instancias emitiendo 30 dimensiones custom innecesarias por instancia son $360/mes de métricas sobre las que nadie alarma. *La observabilidad también es una decisión de Cost Optimization* — ver §4.

---

### 3.2 Security

**Principios de diseño**

1. **Implement a strong identity foundation** — mínimo privilegio, identidad centralizada, eliminar credenciales de larga vida.
2. **Maintain traceability** — registrar y auditar cada acción, en tiempo real, en un lugar que el actor no pueda borrar.
3. **Apply security at all layers** — defensa en profundidad: edge, VPC, subnet, instancia, SO, aplicación, datos.
4. **Automate security best practices** — controles como código (reglas de Config, SCPs, conformance packs), no checklists.
5. **Protect data in transit and at rest** — cifrado, tokenización, clasificación.
6. **Keep people away from data** — nada de SSH humano a producción; usar SSM Session Manager y automatización.
7. **Prepare for security events** — runbooks de respuesta a incidentes, simulacros, herramental forense listo de antemano.

**Trade-offs del modelo de credenciales**

| Mecanismo de identidad | Vida de la credencial | Carga de rotación | Blast radius de una filtración | Veredicto |
|---|---|---|---|---|
| IAM user + access key de larga vida | Hasta rotarla manualmente | Humana | Catastrófico; las claves aparecen en el historial de git | **No usar** para workloads |
| Instance profile de EC2 (IMDSv2) | ~6 h, rotación automática | Ninguna | Requiere SSRF **y** saltear `HttpTokens: required` | Default para EC2 |
| IAM role para service accounts / Pod Identity (EKS) | Minutos | Ninguna | Acotado a una service account | Default para contenedores |
| IAM Roles Anywhere / federación OIDC (CI) | Minutos | Ninguna | Acotado a un claim de repo/branch | Default para pipelines |
| IAM Identity Center + SSO para humanos | Acotada a la sesión | Ninguna | Se revoca centralizadamente | Default para personas |

**"Keep people away from data" en la práctica:** `HttpTokens: required` (IMDSv2) más `HttpPutResponseHopLimit: 1` cierra el camino clásico de SSRF a robo de credenciales, porque un salto de red de contenedor o un pedido proxeado no puede llegar al metadata service. Son dos líneas en un launch template, y están en la implementación de referencia de más abajo.

---

### 3.3 Reliability

**Principios de diseño**

1. **Automatically recover from failure** — los KPI disparan automatización, no humanos.
2. **Test recovery procedures** — inyectá la falla; no pruebes solamente el camino feliz.
3. **Scale horizontally to increase aggregate workload availability** — muchos dominios de falla chicos le ganan a uno grande.
4. **Stop guessing capacity** — monitoreá la demanda y automatizá la oferta.
5. **Manage change through automation** — los cambios de infraestructura pasan por el mismo pipeline que el código.

**La aritmética detrás de "scale horizontally"**

Si una instancia sola tiene disponibilidad *a*, y hay *N* instancias independientes detrás de un load balancer que necesita *k* sanas para servir el pico:

| Topología | Disponibilidad por nodo | Necesita | Disponibilidad resultante | Downtime anual |
|---|---|---|---|---|
| 1 × m7g.4xlarge, 1 AZ | 0.99 | 1 de 1 | 0.99 | ~3 d 15 h |
| 2 × m7g.2xlarge, 1 AZ | 0.99 | 1 de 2 | 0.9999 | ~53 min |
| 2 × m7g.2xlarge, 2 AZ | 0.99 | 1 de 2 | 0.9999 **y sobrevive a un evento de AZ** | ~53 min |
| 4 × m7g.xlarge, 2 AZ (N+2) | 0.99 | 2 de 4 | 0.999999 | ~31 s |

La opción vertical cuesta lo mismo que la horizontal y compra dos órdenes de magnitud menos de disponibilidad. Ese es todo el argumento, y por eso "scale horizontally" es un principio de *reliability*, no de performance.

**Trade-offs de objetivos de recuperación (una tabla que vas a usar en revisiones de diseño reales)**

| Estrategia | RTO | RPO | Costo en régimen vs. el primario | Cuándo es la respuesta correcta |
|---|---|---|---|---|
| Backup & restore | Horas | Horas | ~5% (solo almacenamiento) | Apps internas de tier-3 |
| Pilot light | Decenas de minutos | Minutos | ~15% (datos replicados, cómputo apagado) | Tier-2, sensible al costo |
| Warm standby | Minutos | Segundos | ~50% (copia viva reducida) | DR regional de tier-1 |
| Multi-site active/active | Casi cero | Casi cero | ~200% | Regulado / crítico para los ingresos |

**No te saltees esto:** cada fila de arriba no vale nada hasta que el principio #2 (*test recovery procedures*) se haya ejecutado contra ella. §6.3 muestra el game day.

---

### 3.4 Performance Efficiency

**Principios de diseño**

1. **Democratize advanced technologies** — consumí ML, transcodificación de medios y bases de datos como servicios administrados en lugar de construir experiencia que no necesitás.
2. **Go global in minutes** — desplegá en Regions/edge locations adicionales para bajar la latencia.
3. **Use serverless architectures** — eliminá por completo la capa de administración de servidores.
4. **Experiment more often** — los tests A/B comparativos sobre tipos de instancia, clases de almacenamiento y configuraciones son baratos.
5. **Consider mechanical sympathy** — elegí la tecnología que coincide con el patrón de acceso.

**Mechanical sympathy: selección de almacenamiento**

| Patrón de acceso | Elección incorrecta (y por qué duele) | Elección correcta | Notas |
|---|---|---|---|
| Lecturas aleatorias de 4 KB, 20k IOPS, baja latencia | S3 (latencia por objeto de ~decenas de ms) | io2 Block Express / gp3 con IOPS aprovisionadas | gp3 base 3 000 IOPS, ajustable hasta 16 000 independientemente del tamaño |
| Lecturas secuenciales de objetos grandes, volumen ilimitado | EBS (techo de capacidad, por AZ) | S3 | 11 nueves de durabilidad, ilimitado |
| POSIX compartido entre muchas instancias/AZ | EBS Multi-Attach (solo io1/io2, misma AZ, requiere FS de cluster) | EFS | Multi-AZ, elástico |
| Clave/valor con ms de un dígito, escala enorme | RDS con un índice sobre una clave caliente | DynamoDB | Cuidá la cardinalidad de la partition key |
| Lecturas repetidas del mismo objeto en menos de un ms | Cualquier base de datos | ElastiCache | Cache-aside, con TTL y una protección contra estampidas |

**Selección de cómputo bajo "experiment more often"**

| Opción | Precio de lista on-demand en us-east-1 ($/h) | Precio/rendimiento relativo en workloads web típicos | Costo de migración |
|---|---|---|---|
| `m7i.large` (x86, Intel) | ~0.1008 | línea base | ninguno |
| `m7a.large` (x86, AMD) | ~0.1159 | ~1.0–1.2× | ninguno |
| `m7g.large` (Graviton3, arm64) | ~0.0816 | ~1.2–1.4× | recompilar / imagen multi-arch |
| Lambda (arm64) | $0.0000133334 / GB-s | n/a — pagás por request | re-arquitecturar |

Graviton es ~19% más barato *y* más rápido en la mayoría de los workloads de servidor interpretados/compilados. La barrera es un build arm64, que es un cambio de una línea en un CI moderno. Esta es una decisión de **Performance Efficiency, Cost Optimization y Sustainability** al mismo tiempo — uno de los pocos lugares donde los pilares no entran en conflicto.

---

### 3.5 Cost Optimization

**Principios de diseño**

1. **Implement Cloud Financial Management** — una función real con responsables, presupuestos y una cadencia (FinOps).
2. **Adopt a consumption model** — pagá por lo que usás; apagá lo que no.
3. **Measure overall efficiency** — seguí el **costo unitario** (costo por resultado de negocio), no solo el gasto total.
4. **Stop spending money on undifferentiated heavy lifting** — dejá que AWS opere los racks, el parcheo, el failover de la base.
5. **Analyze and attribute expenditure** — tagging + Cost Explorer, para que cada dólar tenga un dueño.

**Trade-offs de las opciones de compra**

| Opción | Descuento vs on-demand | Compromiso | Riesgo de interrupción | Workload adecuado |
|---|---|---|---|---|
| On-Demand | 0% | ninguno | ninguno | Con picos, impredecible, corto |
| Savings Plans (Compute, 1a, sin pago adelantado) | ~hasta 27% | 1 a $/h | ninguno | Base estable, flexible entre EC2/Fargate/Lambda |
| Savings Plans (Compute, 3a, todo adelantado) | ~hasta 66% | 3 a $/h | ninguno | Base longeva ya comprobada |
| Reserved Instances (Standard, 3a) | ~hasta 72% | 3 a, familia de instancia/Region | ninguno | Muy estable, atado a la familia (p. ej. RDS) |
| Spot Instances | ~hasta 90% | ninguno | Aviso de interrupción de 2 minutos | Sin estado, tolerante a fallas, con checkpoints, batch |

**El costo unitario es la métrica que sobrevive al crecimiento.** Un gasto total que sube 40% mientras el costo unitario baja 15% es un negocio *sano*. Un gasto total plano mientras el costo unitario sube es un workload que se está pudriendo. Por eso el principio #3 está redactado como "overall efficiency" y por eso la plantilla de referencia taggea todo.

---

### 3.6 Sustainability

**Principios de diseño**

1. **Understand your impact** — medilo (Customer Carbon Footprint Tool) y establecé una línea base.
2. **Establish sustainability goals** — fijá objetivos por unidad de trabajo, y esperá que dirijan el diseño.
3. **Maximize utilization** — una instancia al 10% de CPU desperdicia ~la misma energía incorporada y ociosa que una al 90%.
4. **Anticipate and adopt new, more efficient hardware and software offerings** — Graviton, generaciones de instancia más nuevas, runtimes más eficientes.
5. **Use managed services** — la infraestructura compartida y de alta utilización le gana a tu flota ociosa.
6. **Reduce the downstream impact of your cloud workloads** — payloads más chicos, menos reintentos, menos cómputo en el cliente, vidas más largas de los dispositivos.

**Sustainability y Cost Optimization son ~80% las mismas acciones** (right-size, escalar hacia adentro, borrar datos fríos, usar Graviton, usar serverless). Donde divergen: sustainability además se preocupa por la **gravedad y la retención de los datos** — un bucket S3 de 400 TB de logs que nadie consulta es a la vez una factura y una huella, y las políticas de ciclo de vida arreglan las dos cosas.

---

## 4. Dónde los pilares tiran uno contra otro

El valor real del Framework es que hace los trade-offs **explícitos y con dueño**, en lugar de accidentales. No hay ninguna configuración que maximice los seis.

| Tensión | El pilar A quiere | El pilar B quiere | Cómo resolverlo |
|---|---|---|---|
| NAT Gateways multi-AZ | **Reliability**: un NAT por AZ (la falla de una AZ no debe matar la salida de la otra AZ) | **Cost**: un solo NAT (~$32/mes + datos cada uno) | Multi-NAT en prod, un solo NAT en dev; codificalo con una Condition de CFN sobre `Environment` |
| Trazado de fidelidad total | **Operational Excellence**: 100% de muestreo para poder depurar | **Cost**: $5/M de trazas + ingesta de logs | Muestreo adaptativo: 100% de errores y requests lentos, 5% de base |
| Cifrado en todos lados con CMKs | **Security**: claves KMS gestionadas por el cliente, aislamiento por workload | **Cost / Performance**: $1/clave/mes + $0.03 por cada 10 000 requests, más la latencia de KMS | Claves gestionadas por AWS para datos de baja sensibilidad, CMK donde una key policy o un límite de auditoría sean genuinamente necesarios |
| Escalado hacia adentro agresivo | **Cost / Sustainability**: recortar capacidad rápido cuando cae la demanda | **Reliability / Performance**: thrashing, cachés frías, picos de latencia | Política asimétrica: scale-out rápido, scale-in lento con un cooldown largo |
| Spot para toda la flota | **Cost**: hasta −90% | **Reliability**: interrupciones correlacionadas | Mixed instances policy: base on-demand para el piso del SLO, Spot para el pico |
| Llamadas sincrónicas y fuertemente consistentes | **Reliability** (algunas lecturas): simple, sin lag | **Reliability** (disponibilidad) / **Performance**: falla acoplada y latencia | Encolá la escritura (SQS), confirmá rápido, reconciliá asincrónicamente |

**Ejemplo trabajado — el precio de un nueve.** Para el workload de referencia de §5 (2 AZ, 4 × m7g.large, ALB, Aurora):

| Objetivo | Delta de topología | Delta mensual aproximado | Presupuesto de downtime |
|---|---|---|---|
| 99.9% | 2 AZ, base de datos single-AZ, backups | línea base | 43 m 50 s / mes |
| 99.95% | + base de datos Multi-AZ | +100% del costo de la instancia de DB | 21 m 55 s / mes |
| 99.99% | + 3ra AZ, capacidad N+2, cluster Multi-AZ con reader | +~60% del total | 4 m 23 s / mes |
| 99.999% | + segunda Region activo/activo, global database, Route 53 ARC | +~130% del total | 26 s / mes |

Llevale esa tabla al product owner **antes** de comprometerte con un SLO. "Design for failure" no significa "diseñá para toda falla a cualquier precio"; significa *elegí qué fallas vas a sobrevivir, y demostralo*.

---

## 5. Implementación de referencia — completa y desplegable

La siguiente plantilla de CloudFormation es una implementación en un solo archivo de los principios de diseño de arriba. Está anotada para que cada recurso se pueda rastrear hasta un principio. Es completa: sin elisiones, sin placeholders `# ...`.

**Qué demuestra**

| Principio | Dónde |
|---|---|
| Scale horizontally / stop guessing capacity | ASG sobre 2 AZ + política de target tracking |
| Automatically recover from failure | `HealthCheckType: ELB`, reemplazo por el ASG, NAT por AZ |
| Manage change through automation | Todo el stack es IaC; `UpdatePolicy` con rolling update |
| Make frequent, small, reversible changes | `MaxBatchSize: 1`, `MinSuccessfulInstancesPercent` |
| Protect data in transit and at rest | gp3 cifrado, SSE de SQS, cifrado de S3, listener HTTPS opcional con redirección HTTP→HTTPS |
| Keep people away from data | Solo SSM Session Manager; **sin clave SSH, sin puerto 22** |
| Implement a strong identity foundation | Instance profile, IMDSv2 requerido, hop limit 1 |
| Maintain traceability | VPC Flow Logs a CloudWatch Logs |
| Apply security at all layers | Encadenamiento de SG (ALB→app únicamente), subnets privadas, bloqueo de acceso público en S3 |
| Anticipate failure | SQS + DLQ, alarmas sobre 5xx / hosts no sanos / profundidad de la DLQ |
| Analyze and attribute expenditure | Tags obligatorios propagados en el lanzamiento + un Budget filtrado por tag |
| Maximize utilization / adopt efficient hardware | Instancias Graviton (`arm64`), target tracking al 55% de CPU |
| Reduce downstream impact / consumption model | Ciclo de vida de S3 hacia Intelligent-Tiering, expiración de versiones no actuales, S3 Gateway Endpoint (elimina los cargos de datos por NAT) |

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >-
  Well-Architected reference workload for AWS CLF-C02 task 1.2.
  Two-AZ, horizontally scaled, self-healing, loosely coupled, tagged and
  budgeted. Every resource is annotated with the design principle it implements.

Metadata:
  AWS::CloudFormation::Interface:
    ParameterGroups:
      - Label: {default: Workload identity (Cost Optimization - attribute expenditure)}
        Parameters: [WorkloadName, Environment, CostCenter, OperatorEmail]
      - Label: {default: Network (Reliability - multiple fault domains)}
        Parameters: [VpcCidr]
      - Label: {default: Compute (Performance Efficiency / Sustainability)}
        Parameters: [InstanceType, LatestAmiId, MinSize, MaxSize, TargetCpuUtilization]
      - Label: {default: Edge (Security - protect data in transit)}
        Parameters: [CertificateArn, IngressCidr]
      - Label: {default: Cost guardrails}
        Parameters: [MonthlyBudgetUSD]

Parameters:

  WorkloadName:
    Type: String
    Default: wa-reference
    AllowedPattern: '^[a-z][a-z0-9-]{2,28}$'
    Description: Lowercase workload identifier; becomes the cost-allocation tag value.

  Environment:
    Type: String
    Default: prod
    AllowedValues: [dev, stage, prod]
    Description: >-
      Drives the Reliability/Cost trade-off: prod gets one NAT Gateway per AZ,
      dev/stage share a single NAT Gateway.

  CostCenter:
    Type: String
    Default: platform-engineering
    Description: Cost-allocation tag value. Must be activated in Billing to filter on it.

  OperatorEmail:
    Type: String
    AllowedPattern: '^[^@\s]+@[^@\s]+\.[^@\s]+$'
    Description: Destination for alarm and budget notifications.

  VpcCidr:
    Type: String
    Default: 10.42.0.0/16
    AllowedPattern: '^(\d{1,3}\.){3}\d{1,3}/(1[6-9]|2[0-4])$'

  InstanceType:
    Type: String
    Default: m7g.large
    AllowedValues: [t4g.small, t4g.medium, m7g.medium, m7g.large, m7g.xlarge, c7g.large]
    Description: Graviton (arm64) only - Performance Efficiency + Sustainability.

  LatestAmiId:
    Type: AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>
    Default: /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64
    Description: >-
      Resolved from the SSM Public Parameter Store at deploy time, so a stack
      update always picks up the current patched AMI (Operational Excellence).

  MinSize:
    Type: Number
    Default: 2
    MinValue: 2
    Description: Never below 2 - one instance is a single point of failure.

  MaxSize:
    Type: Number
    Default: 12

  TargetCpuUtilization:
    Type: Number
    Default: 55
    MinValue: 20
    MaxValue: 90
    Description: Sustainability - maximize utilization without starving headroom.

  CertificateArn:
    Type: String
    Default: ''
    Description: >-
      Optional ACM certificate ARN. If supplied, :80 redirects to :443 and TLS
      terminates at the ALB (Security - protect data in transit).

  IngressCidr:
    Type: String
    Default: 0.0.0.0/0
    Description: Narrow this for internal workloads (Security - least privilege at the edge).

  MonthlyBudgetUSD:
    Type: Number
    Default: 250
    MinValue: 10

Conditions:

  HasTlsCertificate: !Not [!Equals [!Ref CertificateArn, '']]
  IsProduction:      !Equals [!Ref Environment, prod]

Resources:

  # ------------------------------------------------------------------
  # NETWORK - Reliability: two independent Availability Zones.
  # An AZ is a distinct set of datacenters with independent power,
  # cooling and networking. Spanning two of them is the cheapest
  # reliability improvement available in the cloud.
  # ------------------------------------------------------------------

  Vpc:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: !Ref VpcCidr
      EnableDnsSupport: true
      EnableDnsHostnames: true
      Tags:
        - {Key: Name,       Value: !Sub '${WorkloadName}-${Environment}-vpc'}
        - {Key: workload,   Value: !Ref WorkloadName}
        - {Key: environment, Value: !Ref Environment}
        - {Key: costcenter, Value: !Ref CostCenter}

  InternetGateway:
    Type: AWS::EC2::InternetGateway
    Properties:
      Tags:
        - {Key: Name, Value: !Sub '${WorkloadName}-${Environment}-igw'}

  InternetGatewayAttachment:
    Type: AWS::EC2::VPCGatewayAttachment
    Properties:
      VpcId: !Ref Vpc
      InternetGatewayId: !Ref InternetGateway

  PublicSubnetA:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Select [0, !GetAZs '']
      CidrBlock: !Select [0, !Cidr [!Ref VpcCidr, 8, 8]]
      MapPublicIpOnLaunch: true
      Tags:
        - {Key: Name, Value: !Sub '${WorkloadName}-${Environment}-public-a'}
        - {Key: tier, Value: public}

  PublicSubnetB:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Select [1, !GetAZs '']
      CidrBlock: !Select [1, !Cidr [!Ref VpcCidr, 8, 8]]
      MapPublicIpOnLaunch: true
      Tags:
        - {Key: Name, Value: !Sub '${WorkloadName}-${Environment}-public-b'}
        - {Key: tier, Value: public}

  PrivateSubnetA:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Select [0, !GetAZs '']
      CidrBlock: !Select [2, !Cidr [!Ref VpcCidr, 8, 8]]
      MapPublicIpOnLaunch: false
      Tags:
        - {Key: Name, Value: !Sub '${WorkloadName}-${Environment}-private-a'}
        - {Key: tier, Value: private}

  PrivateSubnetB:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Select [1, !GetAZs '']
      CidrBlock: !Select [3, !Cidr [!Ref VpcCidr, 8, 8]]
      MapPublicIpOnLaunch: false
      Tags:
        - {Key: Name, Value: !Sub '${WorkloadName}-${Environment}-private-b'}
        - {Key: tier, Value: private}

  # NAT Gateways. In prod there is one per AZ so that losing AZ-a does not
  # sever egress for the instances still running in AZ-b. In dev the second
  # NAT is not created - an explicit, documented Cost/Reliability trade-off.

  NatEipA:
    Type: AWS::EC2::EIP
    DependsOn: InternetGatewayAttachment
    Properties:
      Domain: vpc
      Tags:
        - {Key: Name, Value: !Sub '${WorkloadName}-${Environment}-nat-eip-a'}

  NatEipB:
    Type: AWS::EC2::EIP
    Condition: IsProduction
    DependsOn: InternetGatewayAttachment
    Properties:
      Domain: vpc
      Tags:
        - {Key: Name, Value: !Sub '${WorkloadName}-${Environment}-nat-eip-b'}

  NatGatewayA:
    Type: AWS::EC2::NatGateway
    Properties:
      AllocationId: !GetAtt NatEipA.AllocationId
      SubnetId: !Ref PublicSubnetA
      Tags:
        - {Key: Name, Value: !Sub '${WorkloadName}-${Environment}-nat-a'}

  NatGatewayB:
    Type: AWS::EC2::NatGateway
    Condition: IsProduction
    Properties:
      AllocationId: !GetAtt NatEipB.AllocationId
      SubnetId: !Ref PublicSubnetB
      Tags:
        - {Key: Name, Value: !Sub '${WorkloadName}-${Environment}-nat-b'}

  PublicRouteTable:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - {Key: Name, Value: !Sub '${WorkloadName}-${Environment}-rtb-public'}

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

  PrivateRouteTableA:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - {Key: Name, Value: !Sub '${WorkloadName}-${Environment}-rtb-private-a'}

  PrivateRouteTableB:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - {Key: Name, Value: !Sub '${WorkloadName}-${Environment}-rtb-private-b'}

  PrivateDefaultRouteA:
    Type: AWS::EC2::Route
    Properties:
      RouteTableId: !Ref PrivateRouteTableA
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId: !Ref NatGatewayA

  PrivateDefaultRouteB:
    Type: AWS::EC2::Route
    Properties:
      RouteTableId: !Ref PrivateRouteTableB
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId: !If [IsProduction, !Ref NatGatewayB, !Ref NatGatewayA]

  PrivateSubnetARouteAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PrivateSubnetA
      RouteTableId: !Ref PrivateRouteTableA

  PrivateSubnetBRouteAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PrivateSubnetB
      RouteTableId: !Ref PrivateRouteTableB

  # S3 Gateway Endpoint: S3 traffic leaves via the VPC route table instead of
  # the NAT Gateway. Cost (no $0.045/GB NAT processing), Security (traffic
  # never touches the public internet) and Performance at once. It is free.

  S3GatewayEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref Vpc
      ServiceName: !Sub 'com.amazonaws.${AWS::Region}.s3'
      VpcEndpointType: Gateway
      RouteTableIds:
        - !Ref PrivateRouteTableA
        - !Ref PrivateRouteTableB

  # ------------------------------------------------------------------
  # TRACEABILITY - Security: "maintain traceability".
  # Flow Logs capture accepted and rejected traffic metadata for forensics.
  # ------------------------------------------------------------------

  FlowLogGroup:
    Type: AWS::Logs::LogGroup
    Properties:
      LogGroupName: !Sub '/aws/vpc/${WorkloadName}-${Environment}/flowlogs'
      RetentionInDays: 90

  FlowLogRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal: {Service: vpc-flow-logs.amazonaws.com}
            Action: sts:AssumeRole
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
      LogDestinationType: cloud-watch-logs
      LogGroupName: !Ref FlowLogGroup
      DeliverLogsPermissionArn: !GetAtt FlowLogRole.Arn
      MaxAggregationInterval: 60

  # ------------------------------------------------------------------
  # EDGE - Security: apply security at all layers (SG chaining).
  # ------------------------------------------------------------------

  AlbSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: !Sub 'Public ingress for ${WorkloadName}-${Environment} ALB'
      VpcId: !Ref Vpc
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 80
          ToPort: 80
          CidrIp: !Ref IngressCidr
          Description: HTTP (redirected to HTTPS when a certificate is present)
        - IpProtocol: tcp
          FromPort: 443
          ToPort: 443
          CidrIp: !Ref IngressCidr
          Description: HTTPS
      SecurityGroupEgress:
        - IpProtocol: tcp
          FromPort: 8080
          ToPort: 8080
          CidrIp: !Ref VpcCidr
          Description: Forward only to the application tier inside the VPC
      Tags:
        - {Key: Name, Value: !Sub '${WorkloadName}-${Environment}-alb-sg'}

  # No port 22 anywhere. Human access is SSM Session Manager only
  # (Security - "keep people away from data").
  AppSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: !Sub 'Application tier for ${WorkloadName}-${Environment}'
      VpcId: !Ref Vpc
      SecurityGroupEgress:
        - IpProtocol: -1
          CidrIp: 0.0.0.0/0
          Description: Outbound for package updates, SSM and AWS APIs
      Tags:
        - {Key: Name, Value: !Sub '${WorkloadName}-${Environment}-app-sg'}

  AppIngressFromAlb:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !Ref AppSecurityGroup
      IpProtocol: tcp
      FromPort: 8080
      ToPort: 8080
      SourceSecurityGroupId: !Ref AlbSecurityGroup
      Description: Only the ALB may reach the application port

  LoadBalancer:
    Type: AWS::ElasticLoadBalancingV2::LoadBalancer
    Properties:
      Name: !Sub '${WorkloadName}-${Environment}-alb'
      Type: application
      Scheme: internet-facing
      IpAddressType: ipv4
      SecurityGroups: [!Ref AlbSecurityGroup]
      Subnets:
        - !Ref PublicSubnetA
        - !Ref PublicSubnetB
      LoadBalancerAttributes:
        - {Key: idle_timeout.timeout_seconds, Value: '60'}
        - {Key: routing.http.drop_invalid_header_fields.enabled, Value: 'true'}
        - {Key: routing.http2.enabled, Value: 'true'}
        - {Key: deletion_protection.enabled, Value: 'false'}
      Tags:
        - {Key: workload,    Value: !Ref WorkloadName}
        - {Key: environment, Value: !Ref Environment}
        - {Key: costcenter,  Value: !Ref CostCenter}

  TargetGroup:
    Type: AWS::ElasticLoadBalancingV2::TargetGroup
    Properties:
      Name: !Sub '${WorkloadName}-${Environment}-tg'
      VpcId: !Ref Vpc
      Protocol: HTTP
      Port: 8080
      TargetType: instance
      # Reliability: an unhealthy target is removed from rotation in 30 s
      # (2 checks x 15 s) and the ASG then replaces the instance entirely.
      HealthCheckEnabled: true
      HealthCheckProtocol: HTTP
      HealthCheckPath: /healthz
      HealthCheckIntervalSeconds: 15
      HealthCheckTimeoutSeconds: 5
      HealthyThresholdCount: 2
      UnhealthyThresholdCount: 2
      Matcher: {HttpCode: '200'}
      TargetGroupAttributes:
        - {Key: deregistration_delay.timeout_seconds, Value: '30'}
        - {Key: stickiness.enabled, Value: 'false'}
        - {Key: load_balancing.algorithm.type, Value: least_outstanding_requests}

  HttpListener:
    Type: AWS::ElasticLoadBalancingV2::Listener
    Properties:
      LoadBalancerArn: !Ref LoadBalancer
      Protocol: HTTP
      Port: 80
      DefaultActions:
        - !If
          - HasTlsCertificate
          - Type: redirect
            RedirectConfig:
              Protocol: HTTPS
              Port: '443'
              StatusCode: HTTP_301
          - Type: forward
            TargetGroupArn: !Ref TargetGroup

  HttpsListener:
    Type: AWS::ElasticLoadBalancingV2::Listener
    Condition: HasTlsCertificate
    Properties:
      LoadBalancerArn: !Ref LoadBalancer
      Protocol: HTTPS
      Port: 443
      SslPolicy: ELBSecurityPolicy-TLS13-1-2-2021-06
      Certificates:
        - CertificateArn: !Ref CertificateArn
      DefaultActions:
        - Type: forward
          TargetGroupArn: !Ref TargetGroup

  # ------------------------------------------------------------------
  # LOOSE COUPLING - Reliability + evolutionary architecture.
  # The API accepts work and enqueues it; the worker fails independently.
  # The DLQ is the "anticipate failure" mechanism: poison messages are
  # quarantined after 5 attempts instead of blocking the queue forever.
  # ------------------------------------------------------------------

  JobDeadLetterQueue:
    Type: AWS::SQS::Queue
    Properties:
      QueueName: !Sub '${WorkloadName}-${Environment}-jobs-dlq'
      MessageRetentionPeriod: 1209600   # 14 days - maximum, for forensics
      SqsManagedSseEnabled: true        # encryption at rest

  JobQueue:
    Type: AWS::SQS::Queue
    Properties:
      QueueName: !Sub '${WorkloadName}-${Environment}-jobs'
      VisibilityTimeout: 120
      MessageRetentionPeriod: 345600    # 4 days
      SqsManagedSseEnabled: true
      RedrivePolicy:
        deadLetterTargetArn: !GetAtt JobDeadLetterQueue.Arn
        maxReceiveCount: 5

  # ------------------------------------------------------------------
  # DATA - Cost Optimization + Sustainability + Security.
  # ------------------------------------------------------------------

  ArtifactBucket:
    Type: AWS::S3::Bucket
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      BucketName: !Sub '${WorkloadName}-${Environment}-artifacts-${AWS::AccountId}-${AWS::Region}'
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        BlockPublicPolicy: true
        IgnorePublicAcls: true
        RestrictPublicBuckets: true
      BucketEncryption:
        ServerSideEncryptionConfiguration:
          - ServerSideEncryptionByDefault: {SSEAlgorithm: AES256}
            BucketKeyEnabled: true
      VersioningConfiguration: {Status: Enabled}
      OwnershipControls:
        Rules:
          - ObjectOwnership: BucketOwnerEnforced
      LifecycleConfiguration:
        Rules:
          - Id: tier-cold-objects
            Status: Enabled
            Transitions:
              - {StorageClass: INTELLIGENT_TIERING, TransitionInDays: 0}
          - Id: expire-old-versions
            Status: Enabled
            NoncurrentVersionExpiration: {NoncurrentDays: 30}
          - Id: abort-incomplete-uploads
            Status: Enabled
            AbortIncompleteMultipartUpload: {DaysAfterInitiation: 7}
      Tags:
        - {Key: workload,    Value: !Ref WorkloadName}
        - {Key: environment, Value: !Ref Environment}
        - {Key: costcenter,  Value: !Ref CostCenter}

  # ------------------------------------------------------------------
  # IDENTITY - Security: strong identity foundation, no static credentials.
  # ------------------------------------------------------------------

  InstanceRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal: {Service: ec2.amazonaws.com}
            Action: sts:AssumeRole
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
        - arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy
      Policies:
        - PolicyName: workload-least-privilege
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Sid: ConsumeJobQueue
                Effect: Allow
                Action:
                  - sqs:ReceiveMessage
                  - sqs:DeleteMessage
                  - sqs:GetQueueAttributes
                  - sqs:ChangeMessageVisibility
                Resource: !GetAtt JobQueue.Arn
              - Sid: ReadWriteOwnArtifactsOnly
                Effect: Allow
                Action:
                  - s3:GetObject
                  - s3:PutObject
                Resource: !Sub '${ArtifactBucket.Arn}/*'
              - Sid: ListOwnBucketOnly
                Effect: Allow
                Action: s3:ListBucket
                Resource: !GetAtt ArtifactBucket.Arn
      Tags:
        - {Key: workload, Value: !Ref WorkloadName}

  InstanceProfile:
    Type: AWS::IAM::InstanceProfile
    Properties:
      Roles: [!Ref InstanceRole]

  # ------------------------------------------------------------------
  # COMPUTE - Reliability (horizontal, multi-AZ, self-healing)
  #           Performance Efficiency / Sustainability (Graviton, utilization)
  # ------------------------------------------------------------------

  LaunchTemplate:
    Type: AWS::EC2::LaunchTemplate
    Properties:
      LaunchTemplateName: !Sub '${WorkloadName}-${Environment}-lt'
      LaunchTemplateData:
        ImageId: !Ref LatestAmiId
        InstanceType: !Ref InstanceType
        IamInstanceProfile: {Arn: !GetAtt InstanceProfile.Arn}
        SecurityGroupIds: [!Ref AppSecurityGroup]
        # IMDSv2 required + hop limit 1: closes the classic SSRF-to-credential
        # theft path (Security - keep people and processes away from creds).
        MetadataOptions:
          HttpTokens: required
          HttpPutResponseHopLimit: 1
          HttpEndpoint: enabled
          InstanceMetadataTags: enabled
        Monitoring: {Enabled: true}     # 1-minute metrics: drive decisions with data
        BlockDeviceMappings:
          - DeviceName: /dev/xvda
            Ebs:
              VolumeSize: 20
              VolumeType: gp3
              Iops: 3000
              Throughput: 125
              Encrypted: true           # Security - protect data at rest
              DeleteOnTermination: true
        TagSpecifications:
          - ResourceType: instance
            Tags:
              - {Key: Name,        Value: !Sub '${WorkloadName}-${Environment}'}
              - {Key: workload,    Value: !Ref WorkloadName}
              - {Key: environment, Value: !Ref Environment}
              - {Key: costcenter,  Value: !Ref CostCenter}
          - ResourceType: volume
            Tags:
              - {Key: workload,    Value: !Ref WorkloadName}
              - {Key: environment, Value: !Ref Environment}
              - {Key: costcenter,  Value: !Ref CostCenter}
        UserData:
          Fn::Base64: !Sub |
            #!/bin/bash
            set -euo pipefail
            dnf -y update
            dnf -y install nginx amazon-cloudwatch-agent

            AZ=$(TOKEN=$(curl -sX PUT http://169.254.169.254/latest/api/token \
                  -H "X-aws-ec2-metadata-token-ttl-seconds: 60") && \
                 curl -s -H "X-aws-ec2-metadata-token: ${!TOKEN}" \
                  http://169.254.169.254/latest/meta-data/placement/availability-zone)
            IID=$(TOKEN=$(curl -sX PUT http://169.254.169.254/latest/api/token \
                  -H "X-aws-ec2-metadata-token-ttl-seconds: 60") && \
                 curl -s -H "X-aws-ec2-metadata-token: ${!TOKEN}" \
                  http://169.254.169.254/latest/meta-data/instance-id)

            cat >/etc/nginx/conf.d/app.conf <<NGINX
            server {
              listen 8080 default_server;
              # Shallow health check: proves the process is up and can serve.
              # Deep checks that call the database turn one DB blip into a
              # fleet-wide termination storm - deliberately avoided.
              location = /healthz {
                access_log off;
                add_header Content-Type text/plain;
                return 200 "ok\n";
              }
              location / {
                add_header Content-Type text/plain;
                return 200 "workload=${WorkloadName} env=${Environment} az=${!AZ} id=${!IID}\n";
              }
            }
            NGINX

            rm -f /etc/nginx/conf.d/default.conf || true
            systemctl enable --now nginx
            systemctl enable --now amazon-ssm-agent

  AutoScalingGroup:
    Type: AWS::AutoScaling::AutoScalingGroup
    Properties:
      AutoScalingGroupName: !Sub '${WorkloadName}-${Environment}-asg'
      MinSize: !Ref MinSize
      MaxSize: !Ref MaxSize
      DesiredCapacity: !Ref MinSize
      # Two subnets in two AZs. The ASG rebalances automatically, so an AZ
      # event is absorbed by launching replacements in the surviving AZ.
      VPCZoneIdentifier:
        - !Ref PrivateSubnetA
        - !Ref PrivateSubnetB
      LaunchTemplate:
        LaunchTemplateId: !Ref LaunchTemplate
        Version: !GetAtt LaunchTemplate.LatestVersionNumber
      TargetGroupARNs: [!Ref TargetGroup]
      # ELB health checks, not EC2: an instance whose process is wedged but
      # whose hypervisor is fine must still be replaced.
      HealthCheckType: ELB
      HealthCheckGracePeriod: 180
      DefaultInstanceWarmup: 120
      MetricsCollection:
        - Granularity: 1Minute
      Tags:
        - {Key: Name,        Value: !Sub '${WorkloadName}-${Environment}', PropagateAtLaunch: true}
        - {Key: workload,    Value: !Ref WorkloadName,  PropagateAtLaunch: true}
        - {Key: environment, Value: !Ref Environment,   PropagateAtLaunch: true}
        - {Key: costcenter,  Value: !Ref CostCenter,    PropagateAtLaunch: true}
    # Operational Excellence: frequent, small, REVERSIBLE changes.
    # One instance at a time; if the batch does not come back healthy the
    # stack update fails and CloudFormation rolls the change back.
    UpdatePolicy:
      AutoScalingRollingUpdate:
        MaxBatchSize: 1
        MinInstancesInService: !Ref MinSize
        MinSuccessfulInstancesPercent: 100
        PauseTime: PT5M
        WaitOnResourceSignals: false
        SuspendProcesses:
          - HealthCheck
          - ReplaceUnhealthy
          - AZRebalance
          - AlarmNotification
          - ScheduledActions

  # "Stop guessing capacity": supply follows demand automatically.
  # Target tracking is preferred over step scaling because it needs one
  # number (the target) rather than a hand-tuned ladder of thresholds.
  CpuTargetTrackingPolicy:
    Type: AWS::AutoScaling::ScalingPolicy
    Properties:
      AutoScalingGroupName: !Ref AutoScalingGroup
      PolicyType: TargetTrackingScaling
      EstimatedInstanceWarmup: 120
      TargetTrackingConfiguration:
        PredefinedMetricSpecification:
          PredefinedMetricType: ASGAverageCPUUtilization
        TargetValue: !Ref TargetCpuUtilization
        DisableScaleIn: false

  # ------------------------------------------------------------------
  # OBSERVABILITY AND ALARMS - Operational Excellence: actionable insight.
  # Each alarm below corresponds to a customer-visible symptom, not to a
  # resource statistic that nobody can act on.
  # ------------------------------------------------------------------

  AlarmTopic:
    Type: AWS::SNS::Topic
    Properties:
      TopicName: !Sub '${WorkloadName}-${Environment}-alarms'
      DisplayName: !Sub '${WorkloadName} ${Environment} alarms'

  AlarmTopicSubscription:
    Type: AWS::SNS::Subscription
    Properties:
      TopicArn: !Ref AlarmTopic
      Protocol: email
      Endpoint: !Ref OperatorEmail

  UnhealthyHostsAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub '${WorkloadName}-${Environment}-unhealthy-hosts'
      AlarmDescription: >-
        One or more targets are failing health checks. Expected briefly during
        a rolling update; sustained means the ASG cannot bring capacity back.
      Namespace: AWS/ApplicationELB
      MetricName: UnHealthyHostCount
      Dimensions:
        - {Name: TargetGroup,  Value: !GetAtt TargetGroup.TargetGroupFullName}
        - {Name: LoadBalancer, Value: !GetAtt LoadBalancer.LoadBalancerFullName}
      Statistic: Maximum
      Period: 60
      EvaluationPeriods: 5
      Threshold: 0
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: notBreaching
      AlarmActions: [!Ref AlarmTopic]
      OKActions: [!Ref AlarmTopic]

  Elb5xxAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub '${WorkloadName}-${Environment}-elb-5xx'
      AlarmDescription: >-
        The load balancer itself returned 5xx - typically zero healthy targets.
        This is the customer-visible outage signal.
      Namespace: AWS/ApplicationELB
      MetricName: HTTPCode_ELB_5XX_Count
      Dimensions:
        - {Name: LoadBalancer, Value: !GetAtt LoadBalancer.LoadBalancerFullName}
      Statistic: Sum
      Period: 60
      EvaluationPeriods: 2
      Threshold: 5
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: notBreaching
      AlarmActions: [!Ref AlarmTopic]

  LatencyP99Alarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub '${WorkloadName}-${Environment}-p99-latency'
      AlarmDescription: p99 target response time above the 1.5 s SLO.
      Namespace: AWS/ApplicationELB
      MetricName: TargetResponseTime
      Dimensions:
        - {Name: TargetGroup,  Value: !GetAtt TargetGroup.TargetGroupFullName}
        - {Name: LoadBalancer, Value: !GetAtt LoadBalancer.LoadBalancerFullName}
      ExtendedStatistic: p99
      Period: 60
      EvaluationPeriods: 5
      Threshold: 1.5
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: notBreaching
      AlarmActions: [!Ref AlarmTopic]

  DeadLetterQueueAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub '${WorkloadName}-${Environment}-dlq-not-empty'
      AlarmDescription: >-
        Messages reached the dead-letter queue: work is being silently dropped.
        A DLQ with no alarm on it is a data-loss mechanism, not a safety net.
      Namespace: AWS/SQS
      MetricName: ApproximateNumberOfMessagesVisible
      Dimensions:
        - {Name: QueueName, Value: !GetAtt JobDeadLetterQueue.QueueName}
      Statistic: Maximum
      Period: 300
      EvaluationPeriods: 1
      Threshold: 0
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: notBreaching
      AlarmActions: [!Ref AlarmTopic]

  SingleAzCapacityAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub '${WorkloadName}-${Environment}-az-capacity-floor'
      AlarmDescription: >-
        In-service capacity has dropped to the minimum. The workload is one
        instance failure away from an outage.
      Namespace: AWS/AutoScaling
      MetricName: GroupInServiceInstances
      Dimensions:
        - {Name: AutoScalingGroupName, Value: !Ref AutoScalingGroup}
      Statistic: Minimum
      Period: 60
      EvaluationPeriods: 3
      Threshold: !Ref MinSize
      ComparisonOperator: LessThanThreshold
      TreatMissingData: breaching
      AlarmActions: [!Ref AlarmTopic]

  # ------------------------------------------------------------------
  # COST GUARDRAIL - Cost Optimization: Cloud Financial Management.
  # FORECASTED, not ACTUAL: an alert that fires after the money is spent
  # is a receipt, not a control.
  # ------------------------------------------------------------------

  WorkloadBudget:
    Type: AWS::Budgets::Budget
    Properties:
      Budget:
        BudgetName: !Sub '${WorkloadName}-${Environment}-monthly'
        BudgetType: COST
        TimeUnit: MONTHLY
        BudgetLimit:
          Amount: !Ref MonthlyBudgetUSD
          Unit: USD
        CostFilters:
          TagKeyValue:
            - !Join ['', ['user:workload$', !Ref WorkloadName]]
      NotificationsWithSubscribers:
        - Notification:
            NotificationType: FORECASTED
            ComparisonOperator: GREATER_THAN
            Threshold: 100
            ThresholdType: PERCENTAGE
          Subscribers:
            - {SubscriptionType: EMAIL, Address: !Ref OperatorEmail}
        - Notification:
            NotificationType: ACTUAL
            ComparisonOperator: GREATER_THAN
            Threshold: 80
            ThresholdType: PERCENTAGE
          Subscribers:
            - {SubscriptionType: EMAIL, Address: !Ref OperatorEmail}

Outputs:

  ServiceUrl:
    Description: Public entry point for the workload.
    Value: !If
      - HasTlsCertificate
      - !Sub 'https://${LoadBalancer.DNSName}'
      - !Sub 'http://${LoadBalancer.DNSName}'
    Export:
      Name: !Sub '${AWS::StackName}-ServiceUrl'

  AutoScalingGroupName:
    Description: ASG name - use it as the FIS target and in verification commands.
    Value: !Ref AutoScalingGroup
    Export:
      Name: !Sub '${AWS::StackName}-AsgName'

  TargetGroupArn:
    Description: Target group ARN for describe-target-health.
    Value: !Ref TargetGroup
    Export:
      Name: !Sub '${AWS::StackName}-TargetGroupArn'

  JobQueueUrl:
    Description: SQS queue that decouples the API from the worker.
    Value: !Ref JobQueue

  DeadLetterQueueUrl:
    Description: Quarantine for poison messages.
    Value: !Ref JobDeadLetterQueue

  ArtifactBucketName:
    Description: Versioned, encrypted, lifecycle-managed artifact store.
    Value: !Ref ArtifactBucket

  AvailabilityZones:
    Description: The two fault domains this workload spans.
    Value: !Join [', ', [!GetAtt PublicSubnetA.AvailabilityZone, !GetAtt PublicSubnetB.AvailabilityZone]]
```

### 5.1 Despliegue

```console
$ aws --version
aws-cli/2.17.42 Python/3.11.9 linux/6.5.0 exe/x86_64.fedora.41

$ aws sts get-caller-identity
{
    "UserId": "AROA4KJH2XQ7ZLPMN3EXAMPLE:platform-architect",
    "Account": "123456789012",
    "Arn": "arn:aws:sts::123456789012:assumed-role/PlatformAdmin/platform-architect"
}

$ aws cloudformation validate-template \
    --template-body file://wa-reference.yaml \
    --query 'Parameters[].ParameterKey' --output text
WorkloadName    Environment     CostCenter      OperatorEmail   VpcCidr
InstanceType    LatestAmiId     MinSize MaxSize TargetCpuUtilization
CertificateArn  IngressCidr     MonthlyBudgetUSD

$ aws cloudformation deploy \
    --stack-name wa-reference-prod \
    --template-file wa-reference.yaml \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides \
        WorkloadName=wa-reference \
        Environment=prod \
        CostCenter=platform-engineering \
        OperatorEmail=sre-oncall@example.com \
        MonthlyBudgetUSD=250 \
    --tags workload=wa-reference environment=prod costcenter=platform-engineering

Waiting for changeset to be created..
Waiting for stack create/update to complete
Successfully created/updated stack - wa-reference-prod

$ aws cloudformation describe-stacks --stack-name wa-reference-prod \
    --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output table
------------------------------------------------------------------------------------------
|                                     DescribeStacks                                     |
+-----------------------+----------------------------------------------------------------+
|  ServiceUrl           |  http://wa-reference-prod-alb-1042783661.us-east-1.elb.amazonaws.com |
|  AutoScalingGroupName |  wa-reference-prod-asg                                         |
|  TargetGroupArn       |  arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/wa-reference-prod-tg/6d0ecf831eec9f09 |
|  JobQueueUrl          |  https://sqs.us-east-1.amazonaws.com/123456789012/wa-reference-prod-jobs |
|  DeadLetterQueueUrl   |  https://sqs.us-east-1.amazonaws.com/123456789012/wa-reference-prod-jobs-dlq |
|  ArtifactBucketName   |  wa-reference-prod-artifacts-123456789012-us-east-1            |
|  AvailabilityZones    |  us-east-1a, us-east-1b                                        |
+-----------------------+----------------------------------------------------------------+
```

---

## 6. Verificación: probar que los principios realmente se cumplen

Un principio que no verificaste es una creencia. Cada chequeo de abajo produce una respuesta legible por máquina que podés poner en CI.

### 6.1 Reliability — ¿está la capacidad genuinamente repartida entre dominios de falla?

```console
$ ALB=$(aws cloudformation describe-stacks --stack-name wa-reference-prod \
        --query "Stacks[0].Outputs[?OutputKey=='ServiceUrl'].OutputValue" --output text)

$ aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names wa-reference-prod-asg \
    --query 'AutoScalingGroups[0].Instances[].[InstanceId,AvailabilityZone,LifecycleState,HealthStatus]' \
    --output table
--------------------------------------------------------------------
|                    DescribeAutoScalingGroups                     |
+----------------------+-------------+------------+----------------+
|  i-0a3f9c17d2b884e51 |  us-east-1a |  InService |  Healthy       |
|  i-04c81ae59f7b6d033 |  us-east-1b |  InService |  Healthy       |
+----------------------+-------------+------------+----------------+

# The one-line assertion you put in CI: capacity must span >= 2 AZs.
$ aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names wa-reference-prod-asg \
    --query 'length(AutoScalingGroups[0].Instances[?LifecycleState==`InService`].AvailabilityZone | sort(@) | [])' \
    --output text
2
```

Si ese número es `1`, no tenés un workload multi-AZ — tenés dos subnets y las instancias de una sola AZ. Este es el falso positivo más común en las afirmaciones de "somos multi-AZ".

```console
$ TG=$(aws cloudformation describe-stacks --stack-name wa-reference-prod \
       --query "Stacks[0].Outputs[?OutputKey=='TargetGroupArn'].OutputValue" --output text)

$ aws elbv2 describe-target-health --target-group-arn "$TG" \
    --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason]' \
    --output table
--------------------------------------------------------
|                 DescribeTargetHealth                 |
+----------------------+----------+--------------------+
|  i-0a3f9c17d2b884e51 |  healthy |  None              |
|  i-04c81ae59f7b6d033 |  healthy |  None              |
+----------------------+----------+--------------------+

$ for i in 1 2 3 4; do curl -s "$ALB/"; done
workload=wa-reference env=prod az=us-east-1a id=i-0a3f9c17d2b884e51
workload=wa-reference env=prod az=us-east-1b id=i-04c81ae59f7b6d033
workload=wa-reference env=prod az=us-east-1a id=i-0a3f9c17d2b884e51
workload=wa-reference env=prod az=us-east-1b id=i-04c81ae59f7b6d033
```

### 6.2 Security — ¿están aplicados los principios de identidad y cifrado?

```console
# IMDSv2 required on every instance ("keep people away from data").
$ aws ec2 describe-instances \
    --filters "Name=tag:workload,Values=wa-reference" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].[InstanceId,MetadataOptions.HttpTokens,MetadataOptions.HttpPutResponseHopLimit]' \
    --output text
i-0a3f9c17d2b884e51     required        1
i-04c81ae59f7b6d033     required        1

# No long-lived credentials on the instances - only the assumed role.
$ aws ec2 describe-instances \
    --filters "Name=tag:workload,Values=wa-reference" \
    --query 'Reservations[].Instances[].IamInstanceProfile.Arn' --output text
arn:aws:iam::123456789012:instance-profile/wa-reference-prod-InstanceProfile-1QY8XKZ4LMN2P
arn:aws:iam::123456789012:instance-profile/wa-reference-prod-InstanceProfile-1QY8XKZ4LMN2P

# Every attached volume encrypted at rest.
$ aws ec2 describe-volumes \
    --filters "Name=tag:workload,Values=wa-reference" \
    --query 'Volumes[].[VolumeId,Encrypted,VolumeType,Size]' --output text
vol-0f14b8a92c7d3e650    True    gp3     20
vol-09e2c7d41ba8f3d17    True    gp3     20

# No ingress on 22 anywhere in the workload's security groups.
$ aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$(aws ec2 describe-vpcs \
        --filters 'Name=tag:workload,Values=wa-reference' --query 'Vpcs[0].VpcId' --output text)" \
    --query 'SecurityGroups[].IpPermissions[?FromPort==`22`]' --output text
# (empty - correct)

# Human access path is Session Manager, audited in CloudTrail.
$ aws ssm start-session --target i-0a3f9c17d2b884e51
Starting session with SessionId: platform-architect-0d9b41c7a2f6e5830
sh-5.2$ exit
Exiting session with sessionId: platform-architect-0d9b41c7a2f6e5830.
```

### 6.3 Game day — *test recovery procedures* con AWS Fault Injection Service

Este es el paso que convierte "somos resilientes" de una afirmación en evidencia. Guardalo como `az-failure-experiment.json`:

```json
{
  "description": "Game day: simulate the loss of all workload capacity in one AZ",
  "roleArn": "arn:aws:iam::123456789012:role/FISExperimentRole",
  "tags": {
    "workload": "wa-reference",
    "environment": "prod",
    "purpose": "well-architected-reliability-REL12"
  },
  "stopConditions": [
    {
      "source": "aws:cloudwatch:alarm",
      "value": "arn:aws:cloudwatch:us-east-1:123456789012:alarm:wa-reference-prod-elb-5xx"
    }
  ],
  "targets": {
    "instancesInOneAz": {
      "resourceType": "aws:ec2:instance",
      "resourceTags": {
        "workload": "wa-reference",
        "environment": "prod"
      },
      "filters": [
        {
          "path": "State.Name",
          "values": ["running"]
        },
        {
          "path": "Placement.AvailabilityZone",
          "values": ["us-east-1a"]
        }
      ],
      "selectionMode": "ALL"
    }
  },
  "actions": {
    "stopAzA": {
      "actionId": "aws:ec2:stop-instances",
      "description": "Stop every workload instance in us-east-1a",
      "parameters": {
        "startInstancesAfterDuration": "PT10M"
      },
      "targets": {
        "Instances": "instancesInOneAz"
      }
    }
  },
  "experimentOptions": {
    "accountTargeting": "single-account",
    "emptyTargetResolutionMode": "fail"
  }
}
```

> El bloque `stopConditions` es el principio *"safely automate where possible"* hecho concreto: si el experimento causa 5xx reales visibles para el cliente, FIS lo detiene automáticamente. Un game day sin condición de parada es una caída que programaste.
> Para una simulación de AZ más fuerte que además corte caminos de red en lugar de detener instancias, usá la acción `aws:network:disrupt-connectivity` acotada a las subnets de la AZ objetivo.

```console
$ aws fis create-experiment-template --cli-input-json file://az-failure-experiment.json \
    --query 'experimentTemplate.[id,description]' --output text
EXTa7Kd93mQ2LpZv    Game day: simulate the loss of all workload capacity in one AZ

$ aws fis start-experiment --experiment-template-id EXTa7Kd93mQ2LpZv \
    --query 'experiment.[id,state.status]' --output text
EXPb2Nf81rW4TgYc    initiating

# Watch what the customer sees while the AZ is "gone".
$ while true; do
>   printf '%s ' "$(date -u +%H:%M:%S)"
>   curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' "$ALB/"
>   sleep 5
> done
14:02:10 200 0.041s
14:02:15 200 0.038s
14:02:20 200 0.043s     <-- experiment starts, us-east-1a instances stopping
14:02:25 200 0.040s
14:02:30 200 0.039s     <-- ALB has already drained the failing target
14:02:35 200 0.042s
14:03:40 200 0.044s     <-- ASG launching a replacement in us-east-1b
14:05:15 200 0.037s

$ aws elbv2 describe-target-health --target-group-arn "$TG" \
    --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason]' --output table
------------------------------------------------------------------------------
|                            DescribeTargetHealth                            |
+----------------------+-----------+-------------------------------------------+
|  i-0a3f9c17d2b884e51 |  unused   |  Target.NotInUse                          |
|  i-04c81ae59f7b6d033 |  healthy  |  None                                     |
|  i-07b5e0d3a91cf2846 |  initial  |  Elb.RegistrationInProgress               |
+----------------------+-----------+-------------------------------------------+

$ aws fis get-experiment --id EXPb2Nf81rW4TgYc \
    --query 'experiment.[state.status,state.reason]' --output text
completed       Experiment completed.
```

**El informe del game day — el entregable de verdad:**

| Observación | Valor | Veredicto |
|---|---|---|
| 5xx visibles para el cliente durante el evento | 0 | Pasa |
| Delta de latencia p99 | +6 ms | Pasa |
| Tiempo hasta sacar el target fallido de la rotación | ~30 s (2 × 15 s de health checks) | Pasa |
| Tiempo hasta restaurar la capacidad completa | 3 m 25 s | Pasa |
| Alarma que se disparó primero | `wa-reference-prod-az-capacity-floor` | Pasa — la correcta |
| Exactitud del runbook | El paso 4 referenciaba un dashboard borrado | **Falla → fix commiteado** |

Esa última fila es el valor del ejercicio. La documentación se pudre en silencio; solo un ejercicio la encuentra.

### 6.4 Cost Optimization y Sustainability — ¿la atribución es real?

```console
# Cost-allocation tags must be ACTIVATED in Billing or the Budget filter matches nothing.
$ aws ce list-cost-allocation-tags --status Active \
    --query 'CostAllocationTags[].[TagKey,Type,Status]' --output table
------------------------------------------------
|          ListCostAllocationTags              |
+---------------+------------+-----------------+
|  workload     |  UserDefined |  Active       |
|  environment  |  UserDefined |  Active       |
|  costcenter   |  UserDefined |  Active       |
+---------------+------------+-----------------+

$ aws ce get-cost-and-usage \
    --time-period Start=2026-08-01,End=2026-09-01 \
    --granularity MONTHLY \
    --metrics UnblendedCost \
    --group-by Type=TAG,Key=workload \
    --query 'ResultsByTime[0].Groups[].[Keys[0],Metrics.UnblendedCost.Amount]' --output table
------------------------------------------------
|              GetCostAndUsage                 |
+----------------------------+-----------------+
|  workload$wa-reference     |  187.4400000000 |
|  workload$                 |  41.2900000000  |   <-- untagged: attribution gap
+----------------------------+-----------------+
```

**Interpretación:** una fila `workload$` (valor vacío) no vacía significa recursos que se escapan de la atribución — normalmente creados por consola o desde un módulo que se olvidó del `PropagateAtLaunch`. El principio *"analyze and attribute expenditure"* está violado hasta que esa fila sea cero.

```console
# "Anticipate and adopt more efficient offerings" + right-sizing, from data.
$ aws compute-optimizer get-ec2-instance-recommendations \
    --filters name=Finding,values=Overprovisioned \
    --query 'instanceRecommendations[].[instanceName,currentInstanceType,finding,recommendationOptions[0].instanceType,recommendationOptions[0].savingsOpportunity.estimatedMonthlySavings.value]' \
    --output table
-------------------------------------------------------------------------------------
|                    GetEC2InstanceRecommendations                                  |
+-------------------+---------------+-----------------+-------------+---------------+
|  legacy-batch-01  |  m5.4xlarge   |  OVER_PROVISIONED |  m7g.xlarge |  312.55      |
|  legacy-batch-02  |  m5.4xlarge   |  OVER_PROVISIONED |  m7g.xlarge |  312.55      |
+-------------------+---------------+-----------------+-------------+---------------+
```

### 6.5 La revisión en sí — manejar la Well-Architected Tool desde la CLI

```console
$ aws wellarchitected list-lenses --lens-type AWS_OFFICIAL \
    --query 'LensSummaries[].[LensAlias,LensName]' --output table
-----------------------------------------------------------------
|                          ListLenses                           |
+---------------------------+-----------------------------------+
|  wellarchitected          |  AWS Well-Architected Framework   |
|  serverless               |  Serverless Lens                  |
|  softwareasaservice       |  SaaS Lens                        |
|  foundationaltechnicalreview |  FTR Lens                      |
+---------------------------+-----------------------------------+

$ aws wellarchitected create-workload \
    --workload-name wa-reference-prod \
    --description "Payments API reference workload - CLF task 1.2" \
    --environment PRODUCTION \
    --aws-regions us-east-1 \
    --lenses wellarchitected \
    --review-owner sre-oncall@example.com \
    --query '[WorkloadId,WorkloadArn]' --output text
9c1f4a7be0d2358af61b0c4d5e7a9382    arn:aws:wellarchitected:us-east-1:123456789012:workload/9c1f4a7be0d2358af61b0c4d5e7a9382

$ WID=9c1f4a7be0d2358af61b0c4d5e7a9382

$ aws wellarchitected get-lens-review --workload-id "$WID" --lens-alias wellarchitected \
    --query 'LensReview.PillarReviewSummaries[].[PillarName,RiskCounts.HIGH,RiskCounts.MEDIUM,RiskCounts.NONE,RiskCounts.UNANSWERED]' \
    --output table
---------------------------------------------------------------------
|                          GetLensReview                            |
+--------------------------+------+--------+-------+----------------+
|  Operational Excellence  |  0   |   0    |   0   |      11        |
|  Security                |  0   |   0    |   0   |      11        |
|  Reliability             |  0   |   0    |   0   |      12        |
|  Performance Efficiency  |  0   |   0    |   0   |       8        |
|  Cost Optimization       |  0   |   0    |   0   |      11        |
|  Sustainability          |  0   |   0    |   0   |       6        |
+--------------------------+------+--------+-------+----------------+

# After the team answers the questions:
$ aws wellarchitected list-lens-review-improvements \
    --workload-id "$WID" --lens-alias wellarchitected \
    --query 'ImprovementSummaries[?Risk==`HIGH`].[PillarId,QuestionId,Risk,QuestionTitle]' \
    --output table
--------------------------------------------------------------------------------------------------
|                              ListLensReviewImprovements                                        |
+--------------------+-----------------+--------+------------------------------------------------+
|  reliability       |  REL_13         |  HIGH  |  How do you plan for disaster recovery (DR)?   |
|  security          |  SEC_10         |  HIGH  |  How do you anticipate, respond to, and        |
|                    |                 |        |  recover from incidents?                       |
|  costOptimization  |  COST_02        |  HIGH  |  How do you govern usage?                      |
+--------------------+-----------------+--------+------------------------------------------------+

# The milestone is what makes the next review a MEASUREMENT rather than an opinion.
$ aws wellarchitected create-milestone \
    --workload-id "$WID" --milestone-name "2026-Q3 baseline" \
    --query '[WorkloadId,MilestoneNumber]' --output text
9c1f4a7be0d2358af61b0c4d5e7a9382    1
```

---

## 7. Manual de diagnóstico de fallas

### 7.1 Síntoma → causa → comando

| Síntoma | Causa más probable | Comando de diagnóstico | Solución |
|---|---|---|---|
| El ALB devuelve `503 Service Unavailable`, sin IDs de target en el log | Cero targets sanos en el target group | `aws elbv2 describe-target-health --target-group-arn "$TG"` | Ver §7.2 |
| El ALB devuelve `502 Bad Gateway` | El target aceptó la conexión TCP y después mandó una respuesta malformada/vacía, o la app se cayó a mitad del request | `aws logs tail /aws/vpc/... --follow`; revisá los logs de la app | Arreglar la app; asegurar que el idle timeout de keep-alive sea > los 60 s del ALB |
| El ASG lanza instancias que terminan inmediatamente (loop) | `HealthCheckGracePeriod` más corto que el boot + arranque de la app | `aws autoscaling describe-scaling-activities --auto-scaling-group-name ... --max-items 10` | Subir el grace period; hacer el health check superficial |
| El escalado nunca se dispara bajo carga | Monitoreo detallado apagado (métricas de 5 min), o la métrica elegida no es el cuello de botella | `aws cloudwatch get-metric-statistics --namespace AWS/AutoScaling ...` | Habilitar métricas de 1 minuto; hacer target tracking sobre `ALBRequestCountPerTarget` si el límite es la latencia, no CPU |
| La flota hace thrashing (escala afuera/adentro cada pocos minutos) | Política simétrica y demasiado agresiva; sin warmup | `describe-scaling-activities` muestra Launch/Terminate alternados | Configurar `DefaultInstanceWarmup`; hacer el scale-in lento |
| Las instancias no tienen internet, `dnf` se cuelga | Subnet privada ruteada a un NAT en una AZ caída, o falta la ruta | `aws ec2 describe-route-tables --filters Name=association.subnet-id,Values=...` | Restaurar el NAT por AZ (el camino de prod en la plantilla) |
| La app recibe `AccessDenied` al llamar a las APIs de AWS | IMDSv2 requerido pero el SDK/agente es muy viejo, o el hop limit bloquea a un contenedor | `curl` a IMDS con y sin token desde la instancia | Actualizar el SDK; para contenedores usar task roles, no IMDS |
| La alerta de presupuesto nunca se dispara | Los cost allocation tags nunca se activaron en Billing | `aws ce list-cost-allocation-tags --status Active` | Activar el tag; esperar hasta 24 h por el backfill |
| La DLQ se llena en silencio | Se alcanzó `maxReceiveCount`; mensaje envenenado o una caída aguas abajo | `aws sqs get-queue-attributes --attribute-names ApproximateNumberOfMessages` | Alarmar sobre la DLQ (la plantilla lo hace), después redrive |
| La actualización del stack se cuelga en `UPDATE_IN_PROGRESS` sobre el ASG | El rolling update espera instancias que nunca se ponen sanas | `describe-scaling-activities` + `describe-target-health` | El vencimiento de `PauseTime` dispara el rollback; arreglá la AMI/app |

### 7.2 En profundidad: `503` con cero targets sanos

```console
$ curl -s -o /dev/null -w '%{http_code}\n' "$ALB/"
503

$ aws elbv2 describe-target-health --target-group-arn "$TG" --output json
{
    "TargetHealthDescriptions": [
        {
            "Target": {"Id": "i-0a3f9c17d2b884e51", "Port": 8080},
            "HealthCheckPort": "8080",
            "TargetHealth": {
                "State": "unhealthy",
                "Reason": "Target.Timeout",
                "Description": "Request timed out"
            }
        },
        {
            "Target": {"Id": "i-04c81ae59f7b6d033", "Port": 8080},
            "HealthCheckPort": "8080",
            "TargetHealth": {
                "State": "unhealthy",
                "Reason": "Target.Timeout",
                "Description": "Request timed out"
            }
        }
    ]
}
```

Árbol de decisión, guiado por `TargetHealth.Reason`:

| Reason | Significado | Dónde está la falla |
|---|---|---|
| `Target.Timeout` | Sin respuesta TCP/HTTP antes del timeout del health check | El security group no permite ALB→8080, **o** el proceso no está escuchando, **o** es demasiado lento (bloqueado en una dependencia) |
| `Target.FailedHealthChecks` | Respondió, pero no con un código dentro de `Matcher` | `HealthCheckPath` incorrecto, o la app devuelve 302/404 ahí |
| `Target.ResponseCodeMismatch` | Respondió con un estado que no coincide | Alineá `Matcher.HttpCode` con la realidad |
| `Target.NotRegistered` | La instancia no está en el target group | Falta `TargetGroupARNs` en el ASG, o la instancia fue desasociada |
| `Target.NotInUse` / `unused` | No está en servicio (detenida, o el estado del ASG no es `InService`) | Mirá el ASG, no el ALB |
| `Elb.InternalError` | Problema del lado del ALB | Revisá el Health Dashboard; raro |

Confirmá que el camino del SG no es la causa:

```console
$ aws ec2 describe-security-groups --group-ids sg-0b7c14e829d3f6a05 \
    --query 'SecurityGroups[0].IpPermissions[].[FromPort,ToPort,UserIdGroupPairs[0].GroupId]' --output text
8080    8080    sg-0e93a1f7c25b8d640

$ aws ec2 describe-instances --instance-ids i-0a3f9c17d2b884e51 \
    --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' --output text
sg-0b7c14e829d3f6a05
```

La cadena es correcta, así que la falla está en la instancia. Entrá por Session Manager — **no por SSH**:

```console
$ aws ssm start-session --target i-0a3f9c17d2b884e51
Starting session with SessionId: platform-architect-4b8e0f1c96d5a2371

sh-5.2$ sudo ss -lntp | grep 8080
sh-5.2$ sudo systemctl status nginx --no-pager
× nginx.service - The nginx HTTP and reverse proxy server
     Loaded: loaded (/usr/lib/systemd/system/nginx.service; enabled)
     Active: failed (Result: exit-code) since Wed 2026-09-02 22:11:04 UTC; 18min ago
    Process: 1471 ExecStartPre=/usr/sbin/nginx -t (code=exited, status=1/FAILURE)

sh-5.2$ sudo nginx -t
nginx: [emerg] duplicate default server for 0.0.0.0:8080 in /etc/nginx/conf.d/app.conf:2
nginx: configuration file /etc/nginx/nginx.conf test failed
```

**Causa raíz:** una actualización de la AMI reintrodujo un bloque de default server que choca con el del workload. **Lo que dice el Framework que hay que hacer al respecto:**

- *Learn from all operational events* → la corrección es un cambio de código (sacar el conf viejo en el UserData / hornearlo en la AMI), no un `rm` manual en dos instancias.
- *Make frequent, small, reversible changes* → si esto se hubiera desplegado como canary en lugar de una rotación completa de AMI, habría fallado una instancia y el target group todavía habría tenido capacidad sana.
- *Anticipate failure* → el `MinSuccessfulInstancesPercent: 100` en el `UpdatePolicy` es exactamente el guardrail que convierte esto en una **actualización de stack fallida y revertida** en lugar de una caída. Verificá que efectivamente esté activo:

```console
$ aws cloudformation describe-stack-events --stack-name wa-reference-prod \
    --query 'StackEvents[0:4].[Timestamp,LogicalResourceId,ResourceStatus,ResourceStatusReason]' \
    --output text
2026-09-02T22:29:41Z  wa-reference-prod  UPDATE_ROLLBACK_COMPLETE  None
2026-09-02T22:24:18Z  AutoScalingGroup   UPDATE_FAILED  Received 0 SUCCESS signal(s) out of 1. Rolling back.
2026-09-02T22:19:02Z  AutoScalingGroup   UPDATE_IN_PROGRESS  Rolling update initiated
2026-09-02T22:18:55Z  wa-reference-prod  UPDATE_IN_PROGRESS  User Initiated
```

### 7.3 La falla que los chequeos gratuitos no pueden atrapar

Todo lo de arriba verifica *estructura*. Nada de eso verifica que el workload sea **correcto** — una flota puede ser perfectamente multi-AZ, auto-reparable, cifrada, taggeada y presupuestada mientras calcula la respuesta equivocada. Por eso *"drive architectures using data"* se combina con métricas de nivel de negocio (órdenes completadas, pagos liquidados) y no solo con métricas de infraestructura. Un SLO sobre `HTTPCode_Target_2XX_Count` lo satisface un servicio que devuelve `200 OK` con el cuerpo vacío.

---

## 8. Resumen orientado al examen

### 8.1 Mapeo principio → pilar (la asociación más evaluada)

| Si la pregunta menciona… | El pilar es |
|---|---|
| Runbooks, despliegues, IaC, cambios chicos y reversibles, revisión post-incidente | Operational Excellence |
| Mínimo privilegio, cifrado, trazabilidad, defensa en profundidad, IAM | Security |
| Multi-AZ, Auto Scaling para disponibilidad, backups, RTO/RPO, probar la recuperación | Reliability |
| Right-sizing, serverless, alcance global, caching, elegir el tipo de recurso correcto | Performance Efficiency |
| Savings Plans, Spot, tagging para chargeback, costo unitario, apagar cosas | Cost Optimization |
| Huella de carbono, utilización, hardware eficiente, minimizar recursos aprovisionados | Sustainability |

### 8.2 Principios que se confunden fácil

| Par que suena parecido | La distinción |
|---|---|
| *Stop guessing capacity* (Reliability) vs *Adopt a consumption model* (Cost) | Reliability se preocupa por tener **muy poca** capacidad en el pico; Cost se preocupa por tener **demasiada** en el valle. Auto Scaling sirve a los dos. |
| *Use managed services* (Operational Excellence, Sustainability) vs *Stop spending on undifferentiated heavy lifting* (Cost) | La misma acción, tres motivos: menos para operar, mayor utilización compartida, menos plata en montar racks. |
| *Automatically recover from failure* (Reliability) vs *Anticipate failure* (Operational Excellence) | Reliability es la **respuesta automatizada**; Operational Excellence es el **pre-mortem y el ejercicio** que hicieron que esa respuesta existiera. |
| *Test systems at production scale* (general) vs *Test recovery procedures* (Reliability) | El primero prueba el camino feliz a tamaño real; el segundo inyecta la falla. |
| Well-Architected **Framework** vs Well-Architected **Tool** vs **Trusted Advisor** | Framework = la guía. Tool = la revisión autogestionada y gratuita que produce HRIs y milestones. Trusted Advisor = chequeos automáticos contra tu cuenta viva (el set completo de chequeos con soporte Business/Enterprise). |
| Well-Architected **lens** vs **pillar** | Un pilar es una dimensión de calidad; un lens es un conjunto de preguntas específico de dominio (Serverless, SaaS, ML) montado encima. |

### 8.3 Distractores que usa el examen

- **"El Well-Architected Framework garantiza que tu workload sea seguro/altamente disponible."** No. Es una guía y un mecanismo de revisión; produce hallazgos de riesgo, no garantías.
- **"La Well-Architected Tool cuesta plata."** No — la Tool es gratuita. Lo que cuesta plata es remediar lo que encuentra, y (por separado) el set completo de chequeos de Trusted Advisor requiere un plan de soporte Business/Enterprise.
- **"Design for failure significa comprar hardware más confiable."** No — significa asumir que los componentes van a fallar y arquitecturar de forma que su falla no sea la falla del workload.
- **"Hay cinco pilares."** Seis, desde diciembre de 2021.
- **"Escalar verticalmente es el enfoque de la nube para escalar."** El principio es explícitamente *scale horizontally*; el escalado vertical conserva un punto único de falla y choca contra un techo.
- **"Loose coupling significa microservicios."** El acoplamiento débil se trata de aislar fallas y cambios (colas, load balancers, interfaces bien definidas). Un monolito bien diseñado detrás de un ALB está más débilmente acoplado a sus clientes que una malla de microservicios charlatana y encadenada sincrónicamente.

### 8.4 Autoevaluación de diez líneas

1. Nombrá los seis pilares, en cualquier orden.
2. Enumerá los seis principios de diseño generales.
3. ¿A qué pilar le pertenece "keep people away from data"?
4. ¿A qué pilar le pertenece "consider mechanical sympathy"?
5. ¿Cuál es la diferencia entre un HRI y un MRI en la Well-Architected Tool?
6. ¿Por qué importa un milestone?
7. Dá un mecanismo concreto de AWS para "improve through game days".
8. Nombrá dos pilares que tiran uno contra otro respecto a la cantidad de NAT Gateways, y decí cómo lo resolverías.
9. ¿Por qué `HealthCheckType: ELB` está más alineado con "automatically recover from failure" que `EC2`?
10. ¿Qué principio viola un recurso sin tags, y qué rompe aguas abajo?

---

## 9. Referencias

**Alcance de la certificación y del examen**
- AWS Certified Cloud Practitioner (CLF-C02) — Guía del examen: https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- AWS Certified Cloud Practitioner — página de la certificación: https://aws.amazon.com/certification/certified-cloud-practitioner/

**AWS Well-Architected Framework**
- Descripción general del Framework: https://aws.amazon.com/architecture/well-architected/
- Documentación del Framework (welcome): https://docs.aws.amazon.com/wellarchitected/latest/framework/welcome.html
- Principios de diseño generales: https://docs.aws.amazon.com/wellarchitected/latest/framework/general-design-principles.html
- Pilar Operational Excellence: https://docs.aws.amazon.com/wellarchitected/latest/operational-excellence-pillar/welcome.html
- Pilar Security: https://docs.aws.amazon.com/wellarchitected/latest/security-pillar/welcome.html
- Pilar Reliability: https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/welcome.html
- Pilar Performance Efficiency: https://docs.aws.amazon.com/wellarchitected/latest/performance-efficiency-pillar/welcome.html
- Pilar Cost Optimization: https://docs.aws.amazon.com/wellarchitected/latest/cost-optimization-pillar/welcome.html
- Pilar Sustainability: https://docs.aws.amazon.com/wellarchitected/latest/sustainability-pillar/welcome.html
- Guía de usuario de la AWS Well-Architected Tool: https://docs.aws.amazon.com/wellarchitected/latest/userguide/intro.html
- Lenses: https://docs.aws.amazon.com/wellarchitected/latest/userguide/lenses.html
- Referencia de la CLI `aws wellarchitected`: https://docs.aws.amazon.com/cli/latest/reference/wellarchitected/

**Mecánica de reliability y resiliencia**
- Regions y Availability Zones: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-regions-availability-zones.html
- Infraestructura global: https://aws.amazon.com/about-aws/global-infrastructure/
- Guía de usuario de Amazon EC2 Auto Scaling: https://docs.aws.amazon.com/autoscaling/ec2/userguide/what-is-amazon-ec2-auto-scaling.html
- Políticas de target tracking scaling: https://docs.aws.amazon.com/autoscaling/ec2/userguide/as-scaling-target-tracking.html
- Health checks del Application Load Balancer: https://docs.aws.amazon.com/elasticloadbalancing/latest/application/target-group-health-checks.html
- AWS Fault Injection Service: https://docs.aws.amazon.com/fis/latest/userguide/what-is.html
- AWS Resilience Hub: https://docs.aws.amazon.com/resilience-hub/latest/userguide/what-is.html
- Opciones de disaster recovery en la nube: https://docs.aws.amazon.com/whitepapers/latest/disaster-recovery-workloads-on-aws/disaster-recovery-options-in-the-cloud.html

**Mecánica de security**
- Modelo de responsabilidad compartida: https://aws.amazon.com/compliance/shared-responsibility-model/
- Buenas prácticas de IAM: https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html
- Instance metadata service (IMDSv2): https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html
- AWS Systems Manager Session Manager: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html
- VPC Flow Logs: https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs.html

**Operational Excellence e infraestructura como código**
- Guía de usuario de AWS CloudFormation: https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/Welcome.html
- Atributo `UpdatePolicy`: https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-attribute-updatepolicy.html
- Funciones intrínsecas de CloudFormation: https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/intrinsic-function-reference.html
- Guía de usuario de Amazon CloudWatch: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/WhatIsCloudWatch.html
- AWS Trusted Advisor: https://docs.aws.amazon.com/awssupport/latest/user/trusted-advisor.html

**Mecánica de Cost Optimization y Sustainability**
- AWS Cost Explorer: https://docs.aws.amazon.com/cost-management/latest/userguide/ce-what-is.html
- AWS Budgets: https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html
- Cost allocation tags: https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/cost-alloc-tags.html
- Savings Plans: https://docs.aws.amazon.com/savingsplans/latest/userguide/what-is-savings-plans.html
- Amazon EC2 Spot Instances: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-spot-instances.html
- AWS Compute Optimizer: https://docs.aws.amazon.com/compute-optimizer/latest/ug/what-is-compute-optimizer.html
- Configuración de ciclo de vida de S3: https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lifecycle-mgmt.html
- AWS Graviton: https://aws.amazon.com/ec2/graviton/
- Customer Carbon Footprint Tool: https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/ccft-overview.html

**Precios (verificá las cifras actuales antes de citarlas)**
- Precios de Amazon EC2: https://aws.amazon.com/ec2/pricing/
- Precios de Elastic Load Balancing: https://aws.amazon.com/elasticloadbalancing/pricing/
- Precios de Amazon VPC (NAT Gateway): https://aws.amazon.com/vpc/pricing/
- Precios de Amazon CloudWatch: https://aws.amazon.com/cloudwatch/pricing/
- AWS Pricing Calculator: https://calculator.aws/