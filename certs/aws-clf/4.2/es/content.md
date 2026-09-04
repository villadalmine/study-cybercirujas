# 4.2 — Comprender los recursos para facturación, presupuesto y gestión de costos

**Certificación:** AWS Certified Cloud Practitioner (CLF-C02, v1.0)
**Dominio 4:** Facturación, precios y soporte — **Tarea 4.2** — Peso en el examen: **4.0**
**Nivel:** Principal Platform Architect / SRE — profundidad de producción

---

## 1. El problema de producción: la factura es una traza distribuida de tu arquitectura

Cada línea de costo en una factura de AWS es la sombra de una decisión arquitectónica que alguien tomó hace meses. Un cargo `NatGateway-Bytes` de $9.400/mes no es un problema de finanzas — es un problema de *topología*: los pods en subredes privadas están llegando a S3 por el NAT gateway porque nadie creó un Gateway VPC endpoint. Un pico de `CloudWatch-DataProcessing-Bytes` no es una anomalía de facturación — es una biblioteca de logging que empezó a emitir DEBUG en producción.

Por eso la gestión de costos le pertenece al equipo de plataforma y no solo a finanzas. El modo de falla que este dominio existe para prevenir es específico y recurrente:

> Una organización de ingeniería descubre un aumento de costos del 40% mes contra mes **el día 5 del mes siguiente**, cuando la factura se cierra. Para entonces la anomalía lleva 35 días corriendo, nadie puede atribuirla a un equipo porque los recursos no tienen tags, y la única remediación disponible es una búsqueda manual del tesoro por la consola.

Tratá el costo como una señal de primera clase, con la misma disciplina que aplicás a la latencia:

| Concepto de SRE | Equivalente en costos | Recurso de AWS que lo implementa |
|---|---|---|
| Emisión de métricas | Uso medido → ítems de línea tarifados | Pipeline de facturación → **Cost and Usage Report (CUR)** |
| Almacenamiento y consulta de series temporales | API de consulta de costos agregados | **AWS Cost Explorer** (`ce:GetCostAndUsage`) |
| Dashboard | Dashboards de costos | Reportes de Cost Explorer, QuickSight sobre CUR, **CUDOS** |
| Alerta por umbral (basada en síntomas) | Superación del umbral de presupuesto | **AWS Budgets** (actual + forecasted) |
| Detección de anomalías (línea base con ML) | Desviación inesperada del gasto | **AWS Cost Anomaly Detection** |
| Auto-remediación / circuit breaker | Adjuntar una política restrictiva al superarse | **AWS Budgets Actions** |
| Labels / dimensiones de cardinalidad | Dimensiones de costo | **Cost allocation tags**, **Cost Categories** |
| Planificación de capacidad | Compra de compromiso | **Savings Plans / Reserved Instances**, **Cost Optimization Hub** |
| Modelo de carga preproductivo | Estimación previa al despliegue | **AWS Pricing Calculator** |
| Contabilidad multi-tenant | Chargeback / showback | Facturación consolidada de **AWS Organizations**, **AWS Billing Conductor** |

El resto de este documento recorre el pipeline de abajo hacia arriba, porque *la herramienta que deberías usar está determinada por la etapa del pipeline en la que vive tu pregunta.*

---

## 2. El plano de datos de facturación: de dónde salen realmente los números

Entender el camino interno es lo que separa "hice clic en Cost Explorer" de "sé por qué Cost Explorer y mi CUR difieren en $312".

```
┌──────────────────────────────────────────────────────────────────────────┐
│  1. METERING  — every service emits usage records                        │
│     (EC2 instance-seconds, S3 GB-months, Lambda GB-seconds, GB egress)   │
│     Emission is asynchronous and per-service. Latency: minutes → hours.  │
└───────────────────────────────┬──────────────────────────────────────────┘
                                │  usage records (UsageType, Operation,
                                │  Region, ResourceId, AccountId, hour)
                                ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  2. RATING  — apply public price list, then commitment/discount layers   │
│     On-Demand rate → RI/SP coverage → tiering → EDP / private pricing    │
│     → credits → tax. Produces *line items* with a line_item_type.        │
└───────────────────────────────┬──────────────────────────────────────────┘
                                │
        ┌───────────────────────┼───────────────────────────┐
        ▼                       ▼                           ▼
┌────────────────┐   ┌────────────────────────┐   ┌──────────────────────┐
│ 3a. CUR / Data │   │ 3b. Cost Explorer store│   │ 3c. Budgets engine   │
│  Exports → S3  │   │  (aggregated, indexed) │   │  (evaluates ~3×/day) │
│  hourly rows,  │   │  13 months history,    │   │  actual + forecast   │
│  resource-level│   │  12 months forecast    │   │                      │
│  ~3 refresh/day│   │  ~24 h freshness       │   │  → SNS / email /     │
│  Parquet/CSV   │   │  $0.01 per API request │   │    Chatbot / Actions │
└───────┬────────┘   └───────────┬────────────┘   └──────────┬───────────┘
        │                        │                            │
        ▼                        ▼                            ▼
   Athena / Redshift      Console, ce API,            Circuit breakers,
   QuickSight, CUDOS      Cost Anomaly Detection      IAM/SCP attachment
```

### Frescura y retención — los números que causan confusión en la guardia

| Superficie | Frescura | Granularidad | Retención | Costo |
|---|---|---|---|---|
| Cost Explorer (consola/API) | ~24 h de atraso | Mensual / Diaria; **por hora y a nivel de recurso, opt-in** | 13 meses de historia (actual + 12), 12 meses de forecast; **datos por hora, 14 días** | Consola gratis; **API $0.01 por request paginado**; granularidad horaria/por recurso medida cada 1.000 registros de uso |
| CUR / Data Exports | Hasta **3 refrescos/día**, primera entrega hasta 24 h | **Por hora**, a nivel de recurso, con columnas de tags | Ilimitada (tu bucket de S3) | Solo almacenamiento en S3 + costo de escaneo de Athena/Glue |
| AWS Budgets | Evaluado **~3×/día** | Por período del presupuesto | Rolling | Los primeros 2 presupuestos gratis por cuenta, después se mide por presupuesto por día |
| Cost Anomaly Detection | Evaluación diaria, alerta dentro de ~24 h de la detección | Servicio / cuenta / tag / cost category | 90 días de anomalías vía API | **Gratis** |
| Página de Bills / factura | Se cierra en los primeros días del mes siguiente | Mensual | Historia por cuenta | Gratis |

**Consecuencia operativa:** nunca construyas un kill-switch en tiempo real sobre datos de facturación. El lazo de realimentación más ajustado que ofrece AWS es de aproximadamente 8–12 horas (Budgets) o ~24 horas (Anomaly Detection). Si necesitás protección a nivel de segundos — por ejemplo, poner un tope a un fan-out descontrolado de Lambda — tenés que construirla sobre **métricas de CloudWatch y service quotas**, no sobre facturación.

---

## 3. Semántica de las métricas de costo: los cinco números que son todos "el costo"

Esta es la fuente individual más común de tickets del tipo "el dashboard está mal". Cost Explorer, Budgets y CUR pueden reportar *valores distintos para la misma hora* porque están reportando métricas distintas.

| Métrica | Definición | Cuándo es la respuesta correcta | Trampa |
|---|---|---|---|
| **UnblendedCost** | La tarifa efectivamente aplicada a ese ítem de línea específico en esa cuenta específica. Las cuotas anticipadas (upfront) de RI/SP aterrizan como una suma global en el mes en que se pagaron. | "¿Cuánto nos cobró AWS este mes?" — coincide con la factura. **Valor por defecto para Budgets y Cost Explorer.** | La compra de un RI All Upfront a 3 años hace que una cuenta parezca gastar $180k en una hora. |
| **BlendedCost** | Uso tarifado a la tarifa *promedio* de toda la organización para ese usage type, mezclando horas cubiertas por RI/SP y horas on-demand. | Showback interno donde no querés que la cuenta que casualmente posee el RI parezca artificialmente barata. | **Nunca coincide con la factura.** Es una construcción de asignación. No alertes sobre ella. |
| **AmortizedCost** | Las cuotas anticipadas de compromiso repartidas parejo entre las horas que cubren; el uso cubierto por RI/SP tarifado a la tarifa efectiva. | Unit economics, análisis de tendencia, "¿cuál es nuestro run-rate real?" | La suma de un mes ≠ la factura de ese mes. |
| **NetUnblendedCost** | Unblended, **después** de precios privados / EDP / descuentos promocionales. | Acuerdos empresariales — la única cifra que coincide con una factura con descuento. | Vale cero si no tenés programa de descuentos; algunas herramientas hacen fallback silencioso. |
| **NetAmortizedCost** | Amortizado, después de descuentos. | Unit economics de empresas con descuento. | Requiere manejo de `MANUAL_DISCOUNT_COMPATIBILITY` en el CUR. |
| **UsageQuantity / NormalizedUsageAmount** | Unidades crudas; las unidades normalizadas expresan tamaños de instancia en una unidad común (p. ej. `nano` = 0,25 NU) para RIs con flexibilidad de tamaño. | Cálculo de cobertura, planificación de capacidad. | Sumar `UsageQuantity` a través de usage types heterogéneos no significa nada. |

**Regla para equipos de plataforma:** alertá sobre **unblended** (es lo que pagás), analizá sobre **amortized** (es lo que consumís), y nunca expongas **blended** a los ingenieros.

---

## 4. Topología de cuentas: AWS Organizations y facturación consolidada

La gestión de costos es una capacidad *organizacional* antes que una capacidad de herramientas. La unidad de facturación es la **cuenta de administración (payer)**; las cuentas miembro son la unidad de atribución.

```
                       ┌───────────────────────────────────┐
                       │  Management (payer) account       │
                       │  • single invoice                 │
                       │  • owns CUR, Budgets, Cost Explorer│
                       │  • owns RI/SP inventory & sharing │
                       │  • activates cost allocation tags │
                       └────────────┬──────────────────────┘
                                    │  Service Control Policies
                                    │  Tag Policies
              ┌─────────────────────┼─────────────────────┐
              ▼                     ▼                     ▼
     ┌────────────────┐   ┌────────────────┐   ┌────────────────┐
     │ OU: Production │   │ OU: NonProd    │   │ OU: Sandbox    │
     │  prod-platform │   │  dev-platform  │   │  eng-sandbox   │
     │  prod-data     │   │  staging       │   │                │
     └────────────────┘   └────────────────┘   └────────────────┘
```

### Qué te da realmente la facturación consolidada

| Beneficio | Mecanismo | Modo de falla si se malinterpreta |
|---|---|---|
| Una factura, un método de pago | El payer agrega todos los cargos de los miembros | Las cuentas miembro no pueden pagar por separado; salir de la organización a mitad de mes parte la factura |
| **Agregación por tramos de volumen** | El uso de todas las cuentas se suma *antes* de aplicar los precios escalonados (p. ej. tramos de almacenamiento de S3, tramos de transferencia de datos) | Dividir cargas de trabajo entre muchas cuentas para "aislar el costo" no pierde el descuento — pero salir de la organización sí |
| **Compartición de RI / Savings Plans** | El compromiso no usado en una cuenta cubre automáticamente el uso equivalente en cualquier otra cuenta de la familia | Habilitado por defecto. Si un equipo "pierde" su descuento de RI, alguien más lo consumió primero (prioridad por hora de facturación: gana la cuenta que posee el RI, después las demás) |
| Gobernanza centralizada | SCPs, tag policies, backup policies | Las SCPs nunca otorgan permisos; solo fijan el máximo |
| Reportes de tarifa blended | Tarifas promediadas en toda la familia | Confunde a los ingenieros que comparan contra unblended |

**La compartición de RI/SP es opt-out, por cuenta, desde el payer:**

```console
$ aws organizations list-accounts --query 'Accounts[].[Id,Name,Status]' --output table
------------------------------------------------------
|                    ListAccounts                     |
+--------------+----------------------+---------------+
|  111122223333|  org-management      |  ACTIVE       |
|  222233334444|  prod-platform       |  ACTIVE       |
|  333344445555|  prod-data           |  ACTIVE       |
|  444455556666|  staging             |  ACTIVE       |
|  555566667777|  eng-sandbox         |  ACTIVE       |
+--------------+----------------------+---------------+

$ aws ce get-cost-and-usage \
    --time-period Start=2026-08-01,End=2026-09-01 \
    --granularity MONTHLY \
    --metrics UnblendedCost AmortizedCost \
    --group-by Type=DIMENSION,Key=LINKED_ACCOUNT \
    --output json
{
    "GroupDefinitions": [
        {
            "Type": "DIMENSION",
            "Key": "LINKED_ACCOUNT"
        }
    ],
    "ResultsByTime": [
        {
            "TimePeriod": {
                "Start": "2026-08-01",
                "End": "2026-09-01"
            },
            "Total": {},
            "Groups": [
                {
                    "Keys": ["222233334444"],
                    "Metrics": {
                        "UnblendedCost": {"Amount": "28431.9920114", "Unit": "USD"},
                        "AmortizedCost": {"Amount": "33902.4471003", "Unit": "USD"}
                    }
                },
                {
                    "Keys": ["333344445555"],
                    "Metrics": {
                        "UnblendedCost": {"Amount": "11204.7733901", "Unit": "USD"},
                        "AmortizedCost": {"Amount": "11204.7733901", "Unit": "USD"}
                    }
                },
                {
                    "Keys": ["444455556666"],
                    "Metrics": {
                        "UnblendedCost": {"Amount": "3980.1120445", "Unit": "USD"},
                        "AmortizedCost": {"Amount": "3980.1120445", "Unit": "USD"}
                    }
                },
                {
                    "Keys": ["555566667777"],
                    "Metrics": {
                        "UnblendedCost": {"Amount": "912.4408820", "Unit": "USD"},
                        "AmortizedCost": {"Amount": "912.4408820", "Unit": "USD"}
                    }
                }
            ],
            "Estimated": true
        }
    ],
    "DimensionValueAttributes": [
        {"Value": "222233334444", "Attributes": {"description": "prod-platform"}},
        {"Value": "333344445555", "Attributes": {"description": "prod-data"}},
        {"Value": "444455556666", "Attributes": {"description": "staging"}},
        {"Value": "555566667777", "Attributes": {"description": "eng-sandbox"}}
    ]
}
```

Leé el diagnóstico en esa salida: `prod-platform` muestra amortizado **por encima** de unblended ($33,9k vs $28,4k). Eso significa que la cuenta está *consumiendo* capacidad de compromiso que no pagó este mes — la cuota anticipada se pagó en un mes anterior, o los RIs/SPs son propiedad del payer y están compartidos hacia ella. `"Estimated": true` significa que el mes no está cerrado; el número se va a mover.

### AWS Billing Conductor — cuando la facturación consolidada no alcanza

La facturación consolidada produce una factura verdadera. Los proveedores de servicios administrados, los equipos internos de plataforma que revenden capacidad y las organizaciones que necesitan ocultar las tarifas reales de AWS a las unidades de negocio necesitan una factura **pro forma**: el mismo uso, tarifado con *tu* tarifario.

**AWS Billing Conductor** construye esa segunda vista no autoritativa: billing groups, custom line items (agregar un markup del equipo de plataforma, acreditar a una unidad de negocio) y pricing rules (descontar/marcar un servicio o un tramo global). Nunca cambia lo que AWS te cobra — produce un dataset paralelo y un CUR pro forma.

Usalo cuando: el chargeback necesita tarifas distintas a las de AWS. No lo uses cuando: solo necesitás showback — Cost Categories más tags es gratis y más simple.

---

## 5. Matriz de herramientas: elegir el instrumento correcto

| Herramienta | Pregunta que responde | Granularidad | Latencia | Costo | Programable | Limitación principal |
|---|---|---|---|---|---|---|
| **Página de Bills** (consola de Billing) | "¿Qué hay en la factura de este mes?" | Servicio, cuenta, región | Diaria → cierre mensual | Gratis | Sin API | Sin análisis de tendencia |
| **AWS Cost Explorer** | "¿Cómo se movió el costo en el tiempo, y por qué dimensión?" | Mensual/diaria; por hora y a nivel de recurso, opt-in | ~24 h | Consola gratis; **$0.01/request de API** | `ce:*` | 13 meses; agregado (no por recurso salvo opt-in) |
| **CUR / Data Exports (CUR 2.0)** | "Mostrame cada ítem de línea, unido a mis propios metadatos" | **Por hora, por recurso, por tag** | ≤ 24 h primera entrega, ~3×/día | S3 + motor de consulta | `cur:*`, `bcm-data-exports:*` | Necesita Athena/Glue/QuickSight para ser útil; escala de TB en organizaciones grandes |
| **AWS Budgets** | "Avisame antes de que supere un umbral" | Costo, uso, utilización y cobertura de RI/SP | ~3×/día | 2 gratis por cuenta, después medición diaria | `budgets:*`, CFN, Terraform | No es en tiempo real; el forecast necesita ~5 semanas de historia |
| **AWS Budgets Actions** | "Frená la hemorragia automáticamente" | Política de IAM / SCP / detener EC2-RDS | Igual que Budgets | Medido junto con el presupuesto | `budgets:*` | Instrumento tosco; necesita un rol de ejecución |
| **Cost Anomaly Detection** | "¿Cambió algo que yo no planeé?" | Monitores por servicio / cuenta / tag / cost category | ~24 h | **Gratis** | `ce:*AnomalyMonitor*` | Necesita ~10 días para aprender una línea base; ruidoso en cargas con picos |
| **Cost Optimization Hub** | "¿Cuáles son todas mis oportunidades de ahorro, deduplicadas y rankeadas?" | Por recomendación, a nivel de organización | Refresco diario | Gratis (opt-in vía Organizations) | `cost-optimization-hub:*` | Solo recomendaciones; sin aplicación forzada |
| **AWS Compute Optimizer** | "¿Esta instancia/volumen/función tiene el tamaño correcto?" | Por recurso, a partir de métricas de CloudWatch | Requiere ≥ 30 h de métricas | Gratis (tier pago para métricas mejoradas / lookback de 3 meses) | `compute-optimizer:*` | Ciego a la memoria salvo que esté instalado el agente de CW |
| **AWS Trusted Advisor** | "¿Qué buenas prácticas estoy violando, incluidas las de costo?" | Por check | Refrescado periódicamente | Checks core para todos; **los checks de costo completos necesitan Business/Enterprise Support** | `support:*` | La amplitud de los checks está atada al plan de soporte |
| **AWS Pricing Calculator** | "¿Cuánto va a costar esto antes de construirlo?" | Por servicio configurado | N/A (modelo) | Gratis | Lista pública de precios vía `pricing:GetProducts` | Basura entra, basura sale — tenés que modelar la transferencia de datos |
| **AWS Billing Conductor** | "¿Qué dice *mi* tarifario que debe este equipo?" | Billing group | Mensual | Medido por billing group | `billingconductor:*` | Solo pro forma; no es la factura de AWS |
| **AWS Cost Categories** | "Agrupar el costo por *mi* organigrama, no el de AWS" | Dimensión virtual basada en reglas | Aplicado en el próximo refresco | Gratis | `ce:*CostCategory*` | Las reglas se evalúan en orden; gana la primera coincidencia |

> **Nota sobre servicio discontinuado:** *AWS Application Cost Profiler* fue discontinuado por AWS. Todavía aparece en bancos de preguntas viejos — no es una respuesta válida en el examen actual.

---

## 6. Asignación de costos: hacer que la factura responda "¿quién?"

Una cuenta de AWS sin tags produce una factura que solo puede cortarse por las dimensiones propias de AWS (servicio, región, usage type). La asignación de costos convierte eso en *tus* dimensiones.

### 6.1 Las tres capas de tags

| Capa | Ejemplos | Quién la crea | Backfill |
|---|---|---|---|
| **Generados por AWS** | `aws:createdBy`, `aws:cloudformation:stack-name`, `aws:eks:namespace`, `aws:eks:workload-name` | AWS, automáticamente | Se activan por separado; hacia adelante |
| **Definidos por el usuario** | `team`, `environment`, `cost-center`, `service` | Vos, sobre el recurso | **Hacia adelante por defecto** — ver abajo |
| **Cost Categories** | `BusinessUnit = Payments` derivado de IDs de cuenta + tags + servicios | Motor de reglas en la consola de Billing | Aplicado en el refresco; puede retrotraerse al inicio del mes |

**La mecánica crítica:** crear un tag sobre un recurso *no* lo convierte en una dimensión de costo. La clave del tag debe ser **activada como cost allocation tag en la cuenta de administración**, tarda hasta 24 horas en aparecer y — históricamente — la activación solo aplicaba al uso a partir de ese momento. AWS ahora ofrece un **backfill de cost allocation tags** para aplicar retroactivamente una clave activada a períodos anteriores:

```console
$ aws ce list-cost-allocation-tags --status Inactive --output table
-------------------------------------------------------------
|                 ListCostAllocationTags                     |
+---------------+----------------+---------------------------+
|    TagKey     |     Type       |          Status           |
+---------------+----------------+---------------------------+
|  cost-center  |  UserDefined   |  Inactive                 |
|  service      |  UserDefined   |  Inactive                 |
+---------------+----------------+---------------------------+

$ aws ce update-cost-allocation-tags-status \
    --cost-allocation-tags-status \
      TagKey=cost-center,Status=Active TagKey=service,Status=Active
{
    "Errors": []
}

$ aws ce start-cost-allocation-tag-backfill --backfill-from 2026-06-01T00:00:00Z
{
    "BackfillRequest": {
        "Status": "PROCESSING",
        "RequestedAt": "2026-09-04T09:12:44.201000+00:00",
        "BackfillFrom": "2026-06-01T00:00:00+00:00"
    }
}

$ aws ce list-cost-allocation-tag-backfill-history --query 'BackfillRequests[0]'
{
    "BackfillFrom": "2026-06-01T00:00:00+00:00",
    "RequestedAt": "2026-09-04T09:12:44.201000+00:00",
    "Status": "PROCESSING"
}
```

### 6.2 Forzar los tags antes de que el recurso exista

La detección llega demasiado tarde. Aplicá la restricción en el plano de control con una SCP, y estandarizá los *valores* con una tag policy de Organizations.

**SCP — denegar la creación de EC2/RDS sin un tag `cost-center`** (adjuntala a las OUs de cargas de trabajo, nunca a la raíz sin probar):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyRunInstancesWithoutCostCenter",
      "Effect": "Deny",
      "Action": [
        "ec2:RunInstances",
        "rds:CreateDBInstance",
        "rds:CreateDBCluster"
      ],
      "Resource": [
        "arn:aws:ec2:*:*:instance/*",
        "arn:aws:ec2:*:*:volume/*",
        "arn:aws:rds:*:*:db:*",
        "arn:aws:rds:*:*:cluster:*"
      ],
      "Condition": {
        "Null": {
          "aws:RequestTag/cost-center": "true"
        }
      }
    },
    {
      "Sid": "DenyRemovalOfCostAllocationTags",
      "Effect": "Deny",
      "Action": [
        "ec2:DeleteTags",
        "rds:RemoveTagsFromResource"
      ],
      "Resource": "*",
      "Condition": {
        "ForAnyValue:StringEquals": {
          "aws:TagKeys": ["cost-center", "team", "environment"]
        }
      }
    },
    {
      "Sid": "ProtectBillingGuardrails",
      "Effect": "Deny",
      "Action": [
        "budgets:DeleteBudget",
        "budgets:DeleteBudgetAction",
        "ce:DeleteAnomalyMonitor",
        "ce:DeleteAnomalySubscription",
        "cur:DeleteReportDefinition",
        "bcm-data-exports:DeleteExport"
      ],
      "Resource": "*",
      "Condition": {
        "ArnNotLike": {
          "aws:PrincipalArn": "arn:aws:iam::*:role/PlatformFinOpsAdmin"
        }
      }
    }
  ]
}
```

**Tag policy de Organizations — restringir los valores permitidos y la capitalización:**

```json
{
  "tags": {
    "cost-center": {
      "tag_key": {
        "@@assign": "cost-center",
        "@@operators_allowed_for_child_policies": ["@@none"]
      },
      "tag_value": {
        "@@assign": ["CC-1001", "CC-1002", "CC-2100", "CC-3300"]
      },
      "enforced_for": {
        "@@assign": [
          "ec2:instance",
          "ec2:volume",
          "rds:db",
          "s3:bucket",
          "lambda:function",
          "eks:cluster"
        ]
      }
    },
    "environment": {
      "tag_key": {
        "@@assign": "environment"
      },
      "tag_value": {
        "@@assign": ["production", "staging", "development", "sandbox"]
      },
      "enforced_for": {
        "@@assign": ["ec2:instance", "rds:db", "eks:cluster"]
      }
    }
  }
}
```

> Las tag policies imponen **el casing de las claves y los conjuntos de valores**; no hacen que un tag sea obligatorio. La obligatoriedad viene de la SCP. Necesitás las dos.

### 6.3 Cost Categories: el organigrama que AWS no conoce

Los tags describen recursos. Las Cost Categories describen *el negocio*, y pueden construirse a partir de cuentas, servicios, regiones, tags y otras cost categories. Se convierten en una dimensión de primera clase en Cost Explorer, Budgets y CUR.

```json
{
  "Name": "BusinessUnit",
  "RuleVersion": "CostCategoryExpression.v1",
  "DefaultValue": "Unallocated-Shared",
  "Rules": [
    {
      "Value": "Payments",
      "Rule": {
        "Or": [
          { "Dimensions": { "Key": "LINKED_ACCOUNT", "Values": ["222233334444"] } },
          { "Tags": { "Key": "cost-center", "Values": ["CC-1001", "CC-1002"] } }
        ]
      },
      "Type": "REGULAR"
    },
    {
      "Value": "DataPlatform",
      "Rule": {
        "And": [
          { "Dimensions": { "Key": "LINKED_ACCOUNT", "Values": ["333344445555"] } },
          { "Not": { "Tags": { "Key": "environment", "Values": ["sandbox"] } } }
        ]
      },
      "Type": "REGULAR"
    },
    {
      "Value": "PlatformSharedServices",
      "Rule": {
        "Dimensions": {
          "Key": "SERVICE",
          "Values": [
            "AWS Key Management Service",
            "Amazon Route 53",
            "AWS CloudTrail",
            "Amazon CloudWatch"
          ]
        }
      },
      "Type": "REGULAR"
    }
  ],
  "SplitChargeRules": [
    {
      "Source": "PlatformSharedServices",
      "Targets": ["Payments", "DataPlatform"],
      "Method": "PROPORTIONAL"
    }
  ]
}
```

`SplitChargeRules` es la pieza que la mayoría de los equipos pasa por alto: redistribuye el costo de servicios compartidos (KMS, Route 53, el stack de observabilidad) sobre las unidades consumidoras de forma **proporcional**, **pareja** o por porcentajes **fijos** — convirtiendo "Unallocated" de un 30% de la factura en algo defendible.

```console
$ aws ce create-cost-category-definition --cli-input-json file://business-unit-category.json
{
    "CostCategoryArn": "arn:aws:ce::111122223333:costcategory/6f1f0e2a-8d4c-4c2f-9a55-2b1f7cbb9e10",
    "EffectiveStart": "2026-09-01T00:00:00Z"
}
```

Fijate en `EffectiveStart`: las cost categories aplican desde el **inicio del mes en curso**, no desde el momento en que las creaste. Las reglas se evalúan **de arriba hacia abajo, gana la primera coincidencia** — ordenalas de más específica a más general.

---

## 7. AWS Budgets: la capa de alertado

### 7.1 Tipos de presupuesto y para qué sirven realmente

| Tipo de presupuesto | Qué sigue | Uso correcto | Antipatrón |
|---|---|---|---|
| **Cost** | Gasto contra un límite en dólares | Guardrails por equipo/cuenta/entorno | Un único presupuesto para toda la organización — no te dice nada accionable |
| **Usage** | Unidades (GB, horas, requests) | Protección del Free Tier, techos de transferencia de datos | Mezclar usage types con unidades incompatibles |
| **RI utilization** | % de horas de RI compradas efectivamente usadas | Detectar compromiso varado después de una migración | Alertar al 100% — poné el piso alrededor de 90–95% |
| **RI coverage** | % del uso elegible cubierto por RIs | Detectar sub-compromiso | Ignorar la flexibilidad de tamaño (usá unidades normalizadas) |
| **Savings Plans utilization** | % del compromiso horario consumido | Igual que la utilización de RI, pero para SPs | Confundirla con la cobertura |
| **Savings Plans coverage** | % del gasto elegible cubierto por SPs | Decidir cuándo comprar más compromiso | Perseguir el 100% de cobertura — perdés la capacidad de escalar hacia abajo |

Cada presupuesto soporta **hasta 5 alertas**, cada alerta con **hasta 10 suscriptores de email** más topics de SNS (y AWS Chatbot para Slack/Teams). Las alertas se disparan sobre gasto **ACTUAL** o **FORECASTED**, con un umbral expresado como **porcentaje del límite** o como **valor absoluto**.

### 7.2 Stack completo de CloudFormation: budgets + actions + SNS

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >
  FinOps guardrails: monthly cost budget with tiered alerting, a Savings Plans
  utilization budget, a per-team tag-scoped budget, and a budget action that
  attaches a deny-expensive-instances policy to the sandbox role at 100% actual.

Parameters:
  NotificationEmail:
    Type: String
    Description: Distribution list that receives budget notifications.
    AllowedPattern: '^[^@\s]+@[^@\s]+\.[^@\s]+$'
  MonthlyCostLimitUsd:
    Type: Number
    Default: 42000
    MinValue: 1
  SandboxAccountId:
    Type: String
    AllowedPattern: '^[0-9]{12}$'
  CostCenterTagValue:
    Type: String
    Default: CC-1001

Resources:

  ############################################################################
  # Notification fan-out. The topic policy MUST allow budgets.amazonaws.com,
  # otherwise the budget is created successfully and silently never publishes.
  ############################################################################
  BudgetAlertTopic:
    Type: AWS::SNS::Topic
    Properties:
      TopicName: finops-budget-alerts
      DisplayName: FinOps Budget Alerts
      Tags:
        - Key: cost-center
          Value: !Ref CostCenterTagValue
        - Key: environment
          Value: production

  BudgetAlertTopicPolicy:
    Type: AWS::SNS::TopicPolicy
    Properties:
      Topics:
        - !Ref BudgetAlertTopic
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: AllowBudgetsToPublish
            Effect: Allow
            Principal:
              Service: budgets.amazonaws.com
            Action: 'SNS:Publish'
            Resource: !Ref BudgetAlertTopic
            Condition:
              StringEquals:
                'aws:SourceAccount': !Ref 'AWS::AccountId'
              ArnLike:
                'aws:SourceArn': !Sub 'arn:${AWS::Partition}:budgets::${AWS::AccountId}:budget/*'
          - Sid: AllowCostAnomalyDetectionToPublish
            Effect: Allow
            Principal:
              Service: costalerts.amazonaws.com
            Action: 'SNS:Publish'
            Resource: !Ref BudgetAlertTopic

  BudgetAlertSubscription:
    Type: AWS::SNS::Subscription
    Properties:
      Protocol: email
      Endpoint: !Ref NotificationEmail
      TopicArn: !Ref BudgetAlertTopic

  ############################################################################
  # 1. Organization-wide monthly cost budget, tiered 50 / 80 / 100 actual
  #    plus a forecast alert. CostTypes is set EXPLICITLY: never rely on
  #    defaults, they differ between the console wizard and the API.
  ############################################################################
  MonthlyCostBudget:
    Type: AWS::Budgets::Budget
    Properties:
      Budget:
        BudgetName: org-monthly-unblended-cost
        BudgetType: COST
        TimeUnit: MONTHLY
        BudgetLimit:
          Amount: !Ref MonthlyCostLimitUsd
          Unit: USD
        CostTypes:
          IncludeCredit: false
          IncludeDiscount: true
          IncludeOtherSubscription: true
          IncludeRecurring: true
          IncludeRefund: false
          IncludeSubscription: true
          IncludeSupport: true
          IncludeTax: true
          IncludeUpfront: true
          UseAmortized: false
          UseBlended: false
      NotificationsWithSubscribers:
        - Notification:
            NotificationType: ACTUAL
            ComparisonOperator: GREATER_THAN
            Threshold: 50
            ThresholdType: PERCENTAGE
          Subscribers:
            - SubscriptionType: SNS
              Address: !Ref BudgetAlertTopic
        - Notification:
            NotificationType: ACTUAL
            ComparisonOperator: GREATER_THAN
            Threshold: 80
            ThresholdType: PERCENTAGE
          Subscribers:
            - SubscriptionType: SNS
              Address: !Ref BudgetAlertTopic
            - SubscriptionType: EMAIL
              Address: !Ref NotificationEmail
        - Notification:
            NotificationType: ACTUAL
            ComparisonOperator: GREATER_THAN
            Threshold: 100
            ThresholdType: PERCENTAGE
          Subscribers:
            - SubscriptionType: SNS
              Address: !Ref BudgetAlertTopic
            - SubscriptionType: EMAIL
              Address: !Ref NotificationEmail
        - Notification:
            NotificationType: FORECASTED
            ComparisonOperator: GREATER_THAN
            Threshold: 100
            ThresholdType: PERCENTAGE
          Subscribers:
            - SubscriptionType: SNS
              Address: !Ref BudgetAlertTopic

  ############################################################################
  # 2. Savings Plans utilization floor. If utilization drops below 95% we are
  #    paying for commitment we are not consuming.
  ############################################################################
  SavingsPlansUtilizationBudget:
    Type: AWS::Budgets::Budget
    Properties:
      Budget:
        BudgetName: savings-plans-utilization-floor
        BudgetType: SAVINGS_PLANS_UTILIZATION
        TimeUnit: MONTHLY
        BudgetLimit:
          Amount: 95
          Unit: PERCENTAGE
      NotificationsWithSubscribers:
        - Notification:
            NotificationType: ACTUAL
            ComparisonOperator: LESS_THAN
            Threshold: 95
            ThresholdType: PERCENTAGE
          Subscribers:
            - SubscriptionType: SNS
              Address: !Ref BudgetAlertTopic

  ############################################################################
  # 3. Per-team budget scoped by cost allocation tag. The tag key MUST already
  #    be ACTIVE in the management account or CostFilters silently matches
  #    nothing and the budget reports $0 forever.
  ############################################################################
  TeamScopedBudget:
    Type: AWS::Budgets::Budget
    Properties:
      Budget:
        BudgetName: !Sub 'team-${CostCenterTagValue}-monthly'
        BudgetType: COST
        TimeUnit: MONTHLY
        BudgetLimit:
          Amount: 8000
          Unit: USD
        CostFilters:
          TagKeyValue:
            - !Sub 'user:cost-center$${CostCenterTagValue}'
        CostTypes:
          IncludeCredit: false
          IncludeRefund: false
          IncludeSupport: false
          IncludeTax: false
          UseAmortized: true
          UseBlended: false
      NotificationsWithSubscribers:
        - Notification:
            NotificationType: ACTUAL
            ComparisonOperator: GREATER_THAN
            Threshold: 85
            ThresholdType: PERCENTAGE
          Subscribers:
            - SubscriptionType: SNS
              Address: !Ref BudgetAlertTopic

  ############################################################################
  # 4. Sandbox circuit breaker: a cost budget whose breach ATTACHES a deny
  #    policy. This is the only "auto-remediation" primitive in AWS Budgets.
  ############################################################################
  SandboxGuardrailPolicy:
    Type: AWS::IAM::ManagedPolicy
    Properties:
      ManagedPolicyName: SandboxBudgetBreachDenyExpensiveCompute
      Description: Attached by AWS Budgets when the sandbox budget is exceeded.
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: DenyLargeInstanceLaunch
            Effect: Deny
            Action:
              - 'ec2:RunInstances'
              - 'rds:CreateDBInstance'
              - 'sagemaker:CreateTrainingJob'
              - 'sagemaker:CreateEndpoint'
            Resource: '*'
          - Sid: DenyNewSpend
            Effect: Deny
            Action:
              - 'eks:CreateCluster'
              - 'emr:RunJobFlow'
              - 'redshift:CreateCluster'
            Resource: '*'

  BudgetActionExecutionRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: AWSBudgetsActionExecutionRole
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: budgets.amazonaws.com
            Action: 'sts:AssumeRole'
            Condition:
              StringEquals:
                'aws:SourceAccount': !Ref 'AWS::AccountId'
              ArnLike:
                'aws:SourceArn': !Sub 'arn:${AWS::Partition}:budgets::${AWS::AccountId}:budget/*'
      Policies:
        - PolicyName: AllowPolicyAttachment
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - 'iam:AttachRolePolicy'
                  - 'iam:DetachRolePolicy'
                  - 'iam:AttachUserPolicy'
                  - 'iam:DetachUserPolicy'
                  - 'iam:AttachGroupPolicy'
                  - 'iam:DetachGroupPolicy'
                Resource: '*'
                Condition:
                  ArnEquals:
                    'iam:PolicyARN': !Ref SandboxGuardrailPolicy

  SandboxBudget:
    Type: AWS::Budgets::Budget
    Properties:
      Budget:
        BudgetName: sandbox-hard-stop
        BudgetType: COST
        TimeUnit: MONTHLY
        BudgetLimit:
          Amount: 1500
          Unit: USD
        CostFilters:
          LinkedAccount:
            - !Ref SandboxAccountId
        CostTypes:
          IncludeCredit: false
          IncludeRefund: false
          UseAmortized: false
          UseBlended: false
      NotificationsWithSubscribers:
        - Notification:
            NotificationType: ACTUAL
            ComparisonOperator: GREATER_THAN
            Threshold: 90
            ThresholdType: PERCENTAGE
          Subscribers:
            - SubscriptionType: SNS
              Address: !Ref BudgetAlertTopic

  SandboxBudgetAction:
    Type: AWS::Budgets::BudgetsAction
    Properties:
      BudgetName: !Ref SandboxBudget
      NotificationType: ACTUAL
      ActionType: APPLY_IAM_POLICY
      # AUTOMATIC applies without human intervention. Use MANUAL in production
      # until you have watched it not fire for a full billing cycle.
      ApprovalModel: AUTOMATIC
      ExecutionRoleArn: !GetAtt BudgetActionExecutionRole.Arn
      ActionThreshold:
        Type: ABSOLUTE_VALUE
        Value: 1500
      Definition:
        IamActionDefinition:
          PolicyArn: !Ref SandboxGuardrailPolicy
          Roles:
            - EngineerSandboxRole
      Subscribers:
        - Type: SNS
          Address: !Ref BudgetAlertTopic
        - Type: EMAIL
          Address: !Ref NotificationEmail

Outputs:
  BudgetAlertTopicArn:
    Description: SNS topic used by all budget notifications and anomaly subscriptions.
    Value: !Ref BudgetAlertTopic
    Export:
      Name: !Sub '${AWS::StackName}-BudgetAlertTopicArn'
  SandboxGuardrailPolicyArn:
    Description: Deny policy attached automatically on sandbox budget breach.
    Value: !Ref SandboxGuardrailPolicy
  BudgetActionExecutionRoleArn:
    Value: !GetAtt BudgetActionExecutionRole.Arn
```

Dos detalles de esa plantilla son la diferencia entre un guardrail que funciona y uno decorativo:

1. **`BudgetAlertTopicPolicy`** — un presupuesto con un suscriptor SNS se crea correctamente incluso cuando el topic rechaza a `budgets.amazonaws.com`. No hay error; las alertas simplemente se descartan.
2. **Condiciones `aws:SourceArn` / `aws:SourceAccount`** tanto en la política del topic como en la política de confianza del rol — estas cierran el agujero de confused deputy que abre un principal `Service: budgets.amazonaws.com` sin condiciones.

### 7.3 Los mismos guardrails en Terraform

```hcl
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.60"
    }
  }
}

variable "notification_email" {
  type = string
}

variable "monthly_cost_limit_usd" {
  type    = number
  default = 42000
}

variable "team_budgets" {
  description = "Per-team monthly ceilings, keyed by cost-center tag value."
  type        = map(number)
  default = {
    "CC-1001" = 8000
    "CC-1002" = 5500
    "CC-2100" = 12000
    "CC-3300" = 3000
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

resource "aws_sns_topic" "budget_alerts" {
  name = "finops-budget-alerts"

  tags = {
    cost-center = "CC-1001"
    environment = "production"
  }
}

data "aws_iam_policy_document" "budget_alerts_topic" {
  statement {
    sid     = "AllowBudgetsToPublish"
    effect  = "Allow"
    actions = ["SNS:Publish"]
    resources = [aws_sns_topic.budget_alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:budgets::${data.aws_caller_identity.current.account_id}:budget/*"]
    }
  }

  statement {
    sid     = "AllowCostAnomalyDetectionToPublish"
    effect  = "Allow"
    actions = ["SNS:Publish"]
    resources = [aws_sns_topic.budget_alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["costalerts.amazonaws.com"]
    }
  }
}

resource "aws_sns_topic_policy" "budget_alerts" {
  arn    = aws_sns_topic.budget_alerts.arn
  policy = data.aws_iam_policy_document.budget_alerts_topic.json
}

resource "aws_sns_topic_subscription" "budget_email" {
  topic_arn = aws_sns_topic.budget_alerts.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

resource "aws_budgets_budget" "org_monthly" {
  name              = "org-monthly-unblended-cost"
  budget_type       = "COST"
  limit_amount      = var.monthly_cost_limit_usd
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  time_period_start = "2026-01-01_00:00"

  cost_types {
    include_credit             = false
    include_discount           = true
    include_other_subscription = true
    include_recurring          = true
    include_refund             = false
    include_subscription       = true
    include_support            = true
    include_tax                = true
    include_upfront            = true
    use_amortized              = false
    use_blended                = false
  }

  dynamic "notification" {
    for_each = [50, 80, 100]
    content {
      comparison_operator       = "GREATER_THAN"
      threshold                 = notification.value
      threshold_type            = "PERCENTAGE"
      notification_type         = "ACTUAL"
      subscriber_sns_topic_arns = [aws_sns_topic.budget_alerts.arn]
    }
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [aws_sns_topic.budget_alerts.arn]
  }
}

resource "aws_budgets_budget" "per_team" {
  for_each = var.team_budgets

  name              = "team-${each.key}-monthly"
  budget_type       = "COST"
  limit_amount      = each.value
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  time_period_start = "2026-01-01_00:00"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:cost-center$${each.key}"]
  }

  cost_types {
    include_credit  = false
    include_refund  = false
    include_support = false
    include_tax     = false
    use_amortized   = true
    use_blended     = false
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 85
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.budget_alerts.arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [aws_sns_topic.budget_alerts.arn]
  }
}

resource "aws_budgets_budget" "sp_utilization" {
  name         = "savings-plans-utilization-floor"
  budget_type  = "SAVINGS_PLANS_UTILIZATION"
  limit_amount = 95
  limit_unit   = "PERCENTAGE"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator       = "LESS_THAN"
    threshold                 = 95
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.budget_alerts.arn]
  }
}

output "budget_alert_topic_arn" {
  value = aws_sns_topic.budget_alerts.arn
}
```

---

## 8. Cost and Usage Report: el único dataset completo

Cost Explorer es una superficie de consulta sobre una agregación. El **CUR** es el libro mayor crudo: una fila por recurso, por usage type, por hora, con tus columnas de tags unidas. Todo lo que hace una práctica seria de FinOps — unit economics, análisis del radio de impacto de una compra de compromiso, chargeback que sobrevive a una auditoría — se construye acá.

**CUR 2.0 (entregado a través de AWS Data Exports)** es la generación actual. Normaliza el esquema, usa columnas de tipo `map` en lugar de cientos de columnas dispersas, y soporta selección de columnas basada en SQL al momento de exportar.

### 8.1 CloudFormation completo: bucket de S3 + política + export CUR 2.0 + Athena

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >
  CUR 2.0 data export via AWS Data Exports, delivered to a hardened S3 bucket,
  catalogued in Glue and queryable from Athena. Deploy in us-east-1 in the
  management (payer) account.

Parameters:
  ReportBucketName:
    Type: String
    Description: Globally unique bucket name for CUR delivery.
  ExportName:
    Type: String
    Default: org-cur2-hourly
  GlueDatabaseName:
    Type: String
    Default: cur_analytics

Conditions:
  IsUsEast1: !Equals [!Ref 'AWS::Region', 'us-east-1']

Resources:

  ############################################################################
  # Delivery bucket. NOTE: default encryption is SSE-S3 (AES256) on purpose.
  # A bucket whose default encryption is SSE-KMS is the single most common
  # cause of a CUR that is created successfully and never delivers a file.
  ############################################################################
  ReportBucket:
    Type: AWS::S3::Bucket
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      BucketName: !Ref ReportBucketName
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
      VersioningConfiguration:
        Status: Enabled
      OwnershipControls:
        Rules:
          - ObjectOwnership: BucketOwnerEnforced
      LifecycleConfiguration:
        Rules:
          - Id: TransitionOldPartitionsToIA
            Status: Enabled
            Prefix: cur2/
            Transitions:
              - StorageClass: STANDARD_IA
                TransitionInDays: 90
              - StorageClass: GLACIER_IR
                TransitionInDays: 365
          - Id: ExpireNoncurrentVersions
            Status: Enabled
            NoncurrentVersionExpiration:
              NoncurrentDays: 30
      Tags:
        - Key: cost-center
          Value: CC-1001
        - Key: environment
          Value: production

  ############################################################################
  # Both service principals are required for Data Exports: the legacy billing
  # reports principal AND the BCM data exports principal.
  ############################################################################
  ReportBucketPolicy:
    Type: AWS::S3::BucketPolicy
    Properties:
      Bucket: !Ref ReportBucket
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: AllowBillingReportsRead
            Effect: Allow
            Principal:
              Service: billingreports.amazonaws.com
            Action:
              - 's3:GetBucketAcl'
              - 's3:GetBucketPolicy'
            Resource: !GetAtt ReportBucket.Arn
            Condition:
              StringEquals:
                'aws:SourceAccount': !Ref 'AWS::AccountId'
              ArnLike:
                'aws:SourceArn': !Sub 'arn:${AWS::Partition}:cur:us-east-1:${AWS::AccountId}:definition/*'
          - Sid: AllowBillingReportsWrite
            Effect: Allow
            Principal:
              Service: billingreports.amazonaws.com
            Action: 's3:PutObject'
            Resource: !Sub '${ReportBucket.Arn}/*'
            Condition:
              StringEquals:
                'aws:SourceAccount': !Ref 'AWS::AccountId'
              ArnLike:
                'aws:SourceArn': !Sub 'arn:${AWS::Partition}:cur:us-east-1:${AWS::AccountId}:definition/*'
          - Sid: AllowDataExportsRead
            Effect: Allow
            Principal:
              Service: bcm-data-exports.amazonaws.com
            Action:
              - 's3:GetBucketAcl'
              - 's3:GetBucketPolicy'
            Resource: !GetAtt ReportBucket.Arn
            Condition:
              StringEquals:
                'aws:SourceAccount': !Ref 'AWS::AccountId'
              ArnLike:
                'aws:SourceArn': !Sub 'arn:${AWS::Partition}:bcm-data-exports:us-east-1:${AWS::AccountId}:export/*'
          - Sid: AllowDataExportsWrite
            Effect: Allow
            Principal:
              Service: bcm-data-exports.amazonaws.com
            Action: 's3:PutObject'
            Resource: !Sub '${ReportBucket.Arn}/*'
            Condition:
              StringEquals:
                'aws:SourceAccount': !Ref 'AWS::AccountId'
              ArnLike:
                'aws:SourceArn': !Sub 'arn:${AWS::Partition}:bcm-data-exports:us-east-1:${AWS::AccountId}:export/*'
          - Sid: DenyInsecureTransport
            Effect: Deny
            Principal: '*'
            Action: 's3:*'
            Resource:
              - !GetAtt ReportBucket.Arn
              - !Sub '${ReportBucket.Arn}/*'
            Condition:
              Bool:
                'aws:SecureTransport': 'false'

  ############################################################################
  # Legacy CUR definition, retained because Split Cost Allocation Data for EKS
  # and the RESOURCES schema element are configured here. AdditionalSchemaElements
  # is where the expensive-but-essential columns are switched on.
  ############################################################################
  LegacyCurDefinition:
    Type: AWS::CUR::ReportDefinition
    Condition: IsUsEast1
    DependsOn: ReportBucketPolicy
    Properties:
      ReportName: org-legacy-cur-hourly
      TimeUnit: HOURLY
      Format: Parquet
      Compression: Parquet
      AdditionalSchemaElements:
        - RESOURCES
        - SPLIT_COST_ALLOCATION_DATA
        - MANUAL_DISCOUNT_COMPATIBILITY
      S3Bucket: !Ref ReportBucket
      S3Prefix: legacy-cur/
      S3Region: us-east-1
      AdditionalArtifacts:
        - ATHENA
      RefreshClosedReports: true
      ReportVersioning: OVERWRITE_REPORT

  ############################################################################
  # Glue catalog for Athena. In production the partition projection below
  # avoids running a crawler on every refresh.
  ############################################################################
  CurGlueDatabase:
    Type: AWS::Glue::Database
    Properties:
      CatalogId: !Ref 'AWS::AccountId'
      DatabaseInput:
        Name: !Ref GlueDatabaseName
        Description: Cost and Usage Report analytics database.

  AthenaResultsBucket:
    Type: AWS::S3::Bucket
    Properties:
      BucketEncryption:
        ServerSideEncryptionConfiguration:
          - ServerSideEncryptionByDefault:
              SSEAlgorithm: AES256
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        BlockPublicPolicy: true
        IgnorePublicAcls: true
        RestrictPublicBuckets: true
      LifecycleConfiguration:
        Rules:
          - Id: ExpireQueryResults
            Status: Enabled
            ExpirationInDays: 14

  CurAthenaWorkGroup:
    Type: AWS::Athena::WorkGroup
    Properties:
      Name: finops-cur
      State: ENABLED
      WorkGroupConfiguration:
        EnforceWorkGroupConfiguration: true
        PublishCloudWatchMetricsEnabled: true
        # Hard ceiling: a single unpartitioned SELECT * over a year of CUR
        # can scan multiple TB. This caps the blast radius at ~100 GB.
        BytesScannedCutoffPerQuery: 107374182400
        ResultConfiguration:
          OutputLocation: !Sub 's3://${AthenaResultsBucket}/query-results/'
          EncryptionConfiguration:
            EncryptionOption: SSE_S3

Outputs:
  ReportBucketArn:
    Value: !GetAtt ReportBucket.Arn
  GlueDatabase:
    Value: !Ref CurGlueDatabase
  AthenaWorkGroup:
    Value: !Ref CurAthenaWorkGroup
```

### 8.2 Crear el export CUR 2.0 desde la CLI

Los exports de CUR 2.0 se definen con una selección de columnas tipo SQL. Esta es la llamada de creación y su respuesta:

```console
$ cat cur2-export.json
{
  "Export": {
    "Name": "org-cur2-hourly",
    "Description": "Hourly CUR 2.0 with resource IDs and split cost allocation.",
    "DataQuery": {
      "QueryStatement": "SELECT bill_billing_period_start_date, bill_payer_account_id, line_item_usage_account_id, line_item_usage_start_date, line_item_line_item_type, line_item_product_code, line_item_usage_type, line_item_operation, line_item_resource_id, line_item_usage_amount, line_item_unblended_cost, line_item_net_unblended_cost, product, product_servicecode, product_region_code, pricing_term, pricing_unit, reservation_effective_cost, reservation_unused_amortized_upfront_fee_for_billing_period, reservation_unused_recurring_fee, savings_plan_savings_plan_effective_cost, savings_plan_total_commitment_to_date, savings_plan_used_commitment, resource_tags, cost_category, split_line_item_parent_resource_id, split_line_item_split_cost, split_line_item_unused_cost FROM COST_AND_USAGE_REPORT",
      "TableConfigurations": {
        "COST_AND_USAGE_REPORT": {
          "TIME_GRANULARITY": "HOURLY",
          "INCLUDE_RESOURCES": "TRUE",
          "INCLUDE_SPLIT_COST_ALLOCATION_DATA": "TRUE",
          "INCLUDE_MANUAL_DISCOUNT_COMPATIBILITY": "FALSE"
        }
      }
    },
    "DestinationConfigurations": {
      "S3Destination": {
        "S3Bucket": "acme-finops-cur-111122223333",
        "S3Prefix": "cur2",
        "S3Region": "us-east-1",
        "S3OutputConfigurations": {
          "OutputType": "CUSTOM",
          "Format": "PARQUET",
          "Compression": "PARQUET",
          "Overwrite": "OVERWRITE_REPORT"
        }
      }
    },
    "RefreshCadence": {
      "Frequency": "SYNCHRONOUS"
    }
  }
}

$ aws bcm-data-exports create-export --region us-east-1 --cli-input-json file://cur2-export.json
{
    "ExportArn": "arn:aws:bcm-data-exports:us-east-1:111122223333:export/org-cur2-hourly-9d3a1f5c"
}

$ aws bcm-data-exports list-exports --region us-east-1
{
    "Exports": [
        {
            "ExportArn": "arn:aws:bcm-data-exports:us-east-1:111122223333:export/org-cur2-hourly-9d3a1f5c",
            "ExportName": "org-cur2-hourly",
            "ExportStatus": {
                "StatusCode": "HEALTHY",
                "CreatedAt": "2026-09-02T14:03:11.442000+00:00",
                "LastUpdatedAt": "2026-09-04T06:11:52.008000+00:00",
                "LastRefreshedAt": "2026-09-04T06:11:52.008000+00:00"
            }
        }
    ]
}
```

`"StatusCode": "HEALTHY"` con un `LastRefreshedAt` reciente es la única prueba de que el pipeline funciona. Un estado `UNHEALTHY` casi siempre apunta a la política del bucket.

### 8.3 Athena: las consultas que importan

**Costo amortizado, la fórmula canónica.** Cost Explorer lo calcula por vos; en el CUR tenés que expresarlo, y todo dashboard de FinOps que se equivoca con la amortización se equivoca acá:

```sql
CREATE OR REPLACE VIEW cur_analytics.v_amortized AS
SELECT
    bill_billing_period_start_date                       AS billing_period,
    line_item_usage_start_date                           AS usage_hour,
    line_item_usage_account_id                           AS account_id,
    product_servicecode                                  AS service,
    product_region_code                                  AS region,
    line_item_resource_id                                AS resource_id,
    line_item_line_item_type                             AS line_item_type,
    resource_tags['cost_center']                         AS cost_center,
    resource_tags['team']                                AS team,
    resource_tags['environment']                         AS environment,
    cost_category['BusinessUnit']                        AS business_unit,
    line_item_unblended_cost                             AS unblended_cost,
    CASE
        WHEN line_item_line_item_type = 'SavingsPlanCoveredUsage'
             THEN savings_plan_savings_plan_effective_cost
        WHEN line_item_line_item_type = 'SavingsPlanRecurringFee'
             THEN savings_plan_total_commitment_to_date - savings_plan_used_commitment
        WHEN line_item_line_item_type = 'SavingsPlanNegation'   THEN 0
        WHEN line_item_line_item_type = 'SavingsPlanUpfrontFee' THEN 0
        WHEN line_item_line_item_type = 'DiscountedUsage'
             THEN reservation_effective_cost
        WHEN line_item_line_item_type = 'RIFee'
             THEN reservation_unused_amortized_upfront_fee_for_billing_period
                  + reservation_unused_recurring_fee
        WHEN line_item_line_item_type = 'Fee'
             AND reservation_reservation_arn <> '' THEN 0
        ELSE line_item_unblended_cost
    END                                                  AS amortized_cost
FROM cur_analytics.org_cur2_hourly
WHERE line_item_line_item_type NOT IN ('Tax', 'Refund', 'Credit');
```

**Gasto sin tags — el número que justifica todo el programa de tagging:**

```sql
SELECT
    product_servicecode                                   AS service,
    line_item_usage_account_id                            AS account_id,
    SUM(line_item_unblended_cost)                         AS untagged_usd
FROM cur_analytics.org_cur2_hourly
WHERE bill_billing_period_start_date = DATE '2026-08-01'
  AND line_item_line_item_type = 'Usage'
  AND (resource_tags['cost_center'] IS NULL OR resource_tags['cost_center'] = '')
GROUP BY 1, 2
HAVING SUM(line_item_unblended_cost) > 100
ORDER BY untagged_usd DESC
LIMIT 25;
```

```console
$ aws athena start-query-execution \
    --work-group finops-cur \
    --query-string "$(cat untagged.sql)" \
    --query-execution-context Database=cur_analytics
{
    "QueryExecutionId": "b7c1f4de-2a08-4c3d-9f21-6e0a7b5c2d19"
}

$ aws athena get-query-results --query-execution-id b7c1f4de-2a08-4c3d-9f21-6e0a7b5c2d19 \
    --query 'ResultSet.Rows[1:6].Data[*].VarCharValue' --output text
AmazonEC2       222233334444    9142.7712
AWSDataTransfer 222233334444    4877.1093
AmazonS3        333344445555    3011.9820
AmazonRDS       444455556666    1204.5511
AWSLambda       222233334444     388.2077
```

**Costo por pod en EKS, vía split cost allocation data.** Habilitar `SPLIT_COST_ALLOCATION_DATA` hace que AWS atribuya el costo de EC2/Fargate de un nodo hasta el nivel de pods individuales, usando la relación entre CPU y memoria solicitadas y usadas, y expone los tags generados por AWS `aws:eks:namespace`, `aws:eks:workload-name`, `aws:eks:workload-type` y `aws:eks:node`:

```sql
SELECT
    resource_tags['aws_eks_cluster_name']                 AS cluster,
    resource_tags['aws_eks_namespace']                    AS namespace,
    resource_tags['aws_eks_workload_type']                AS workload_type,
    resource_tags['aws_eks_workload_name']                AS workload,
    SUM(split_line_item_split_cost)                       AS attributed_usd,
    SUM(split_line_item_unused_cost)                      AS unused_capacity_usd,
    SUM(split_line_item_split_cost)
      / NULLIF(SUM(split_line_item_split_cost)
               + SUM(split_line_item_unused_cost), 0)     AS packing_efficiency
FROM cur_analytics.org_cur2_hourly
WHERE bill_billing_period_start_date = DATE '2026-08-01'
  AND split_line_item_parent_resource_id IS NOT NULL
GROUP BY 1, 2, 3, 4
ORDER BY attributed_usd DESC
LIMIT 20;
```

Un `packing_efficiency` por debajo de ~0,5 significa que estás pagando por una flota que está a mitad de camino ociosa — normalmente porque los `requests` de los pods están seteados muy por encima del consumo real. Eso es un defecto de scheduling de Kubernetes que sale a la luz por el pipeline de facturación.

Para atribución sub-horaria dentro del clúster, los datos nativos de AWS son demasiado gruesos; combinalos con **OpenCost** corriendo en el clúster:

```yaml
# values-opencost.yaml — OpenCost on EKS, reconciling in-cluster allocation
# against the authoritative AWS CUR so that showback matches the invoice.
apiVersion: v1
kind: ConfigMap
metadata:
  name: opencost-cur-config
  namespace: opencost
data:
  athenaBucketName: "s3://acme-finops-cur-111122223333"
  athenaRegion: "us-east-1"
  athenaDatabase: "cur_analytics"
  athenaTable: "org_cur2_hourly"
  athenaWorkgroup: "finops-cur"
  projectID: "111122223333"
---
opencost:
  exporter:
    defaultClusterId: prod-eks-euw1
    extraEnv:
      CLOUD_PROVIDER_API_KEY: ""
      CLUSTER_PROFILE: production
      # Reconcile in-cluster estimates with real CUR line items nightly.
      ETL_ENABLED: "true"
      CLOUD_COST_ENABLED: "true"
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        memory: 1Gi
  cloudIntegrationSecret: opencost-cloud-integration
  prometheus:
    internal:
      enabled: false
    external:
      enabled: true
      url: "http://prometheus-server.monitoring.svc.cluster.local:80"
  serviceAccount:
    create: true
    annotations:
      eks.amazonaws.com/role-arn: arn:aws:iam::111122223333:role/OpenCostCurReader
```

El rol IRSA `OpenCostCurReader` necesita solamente `athena:StartQueryExecution`, `athena:GetQueryResults`, `glue:GetTable`, `s3:GetObject` sobre el prefijo del CUR y `s3:PutObject` sobre el prefijo de resultados de Athena. **Nada dentro del clúster debería tener nunca `ce:*` — la API de Cost Explorer factura por request y un pod en crash-loop va a generar miles con toda alegría.**

---

## 9. Cost Anomaly Detection: la capa de ML

Budgets responde "¿estoy por encima de una línea que dibujé?". Anomaly Detection responde "¿cambió la forma de mi gasto?" — que atrapa las fallas alrededor de las cuales no se te ocurrió dibujar una línea. Es **gratis**, aprende una línea base por monitor y evalúa a diario.

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: Cost Anomaly Detection monitors and subscriptions.

Parameters:
  AlertTopicArn:
    Type: String
  FinOpsEmail:
    Type: String

Resources:

  # Monitor 1: every AWS service, dimension-based. The broadest useful net.
  ServiceMonitor:
    Type: AWS::CE::AnomalyMonitor
    Properties:
      MonitorName: all-services
      MonitorType: DIMENSIONAL
      MonitorDimension: SERVICE

  # Monitor 2: per business unit, driven by the cost category built earlier.
  BusinessUnitMonitor:
    Type: AWS::CE::AnomalyMonitor
    Properties:
      MonitorName: by-business-unit
      MonitorType: CUSTOM
      MonitorSpecification: >-
        {
          "CostCategories": {
            "Key": "BusinessUnit",
            "Values": ["Payments", "DataPlatform", "PlatformSharedServices"]
          }
        }

  # Monitor 3: the sandbox account, where surprises are most likely.
  SandboxMonitor:
    Type: AWS::CE::AnomalyMonitor
    Properties:
      MonitorName: sandbox-account
      MonitorType: CUSTOM
      MonitorSpecification: >-
        {
          "Dimensions": {
            "Key": "LINKED_ACCOUNT",
            "Values": ["555566667777"]
          }
        }

  # High-signal subscription: page immediately when total impact > $500.
  ImmediateHighImpactSubscription:
    Type: AWS::CE::AnomalySubscription
    Properties:
      SubscriptionName: high-impact-immediate
      Frequency: IMMEDIATE
      MonitorArnList:
        - !Ref ServiceMonitor
        - !Ref BusinessUnitMonitor
        - !Ref SandboxMonitor
      Subscribers:
        - Type: SNS
          Address: !Ref AlertTopicArn
      # ThresholdExpression replaces the deprecated scalar Threshold and lets
      # you combine absolute impact with a percentage deviation.
      ThresholdExpression: >-
        {
          "And": [
            {
              "Dimensions": {
                "Key": "ANOMALY_TOTAL_IMPACT_ABSOLUTE",
                "MatchOptions": ["GREATER_THAN_OR_EQUAL"],
                "Values": ["500"]
              }
            },
            {
              "Dimensions": {
                "Key": "ANOMALY_TOTAL_IMPACT_PERCENTAGE",
                "MatchOptions": ["GREATER_THAN_OR_EQUAL"],
                "Values": ["30"]
              }
            }
          ]
        }

  # Low-signal digest: everything else, once a day, to a mailbox not a pager.
  DailyDigestSubscription:
    Type: AWS::CE::AnomalySubscription
    Properties:
      SubscriptionName: daily-digest
      Frequency: DAILY
      MonitorArnList:
        - !Ref ServiceMonitor
      Subscribers:
        - Type: EMAIL
          Address: !Ref FinOpsEmail
      ThresholdExpression: >-
        {
          "Dimensions": {
            "Key": "ANOMALY_TOTAL_IMPACT_ABSOLUTE",
            "MatchOptions": ["GREATER_THAN_OR_EQUAL"],
            "Values": ["100"]
          }
        }

Outputs:
  ServiceMonitorArn:
    Value: !Ref ServiceMonitor
  BusinessUnitMonitorArn:
    Value: !Ref BusinessUnitMonitor
```

El `And` de dólares absolutos **y** desviación porcentual es la solución a la fatiga de alertas: una anomalía de $600 sobre una factura mensual de $2M es ruido; una anomalía de $600 que es el 300% de la línea base de ese servicio es un bug.

Leer una anomalía como un incidente:

```console
$ aws ce get-anomalies \
    --date-interval StartDate=2026-08-25,EndDate=2026-09-04 \
    --total-impact NumericOperator=GREATER_THAN,StartValue=500 \
    --output json
{
    "Anomalies": [
        {
            "AnomalyId": "a1d9f77c-3b52-4b8e-9f01-27c4d5b6e8a3",
            "AnomalyStartDate": "2026-08-28T00:00:00Z",
            "AnomalyEndDate": "2026-08-31T00:00:00Z",
            "DimensionValue": "AmazonCloudWatch",
            "RootCauses": [
                {
                    "Service": "AmazonCloudWatch",
                    "Region": "eu-west-1",
                    "LinkedAccount": "222233334444",
                    "LinkedAccountName": "prod-platform",
                    "UsageType": "EUW1-DataProcessing-Bytes"
                }
            ],
            "AnomalyScore": {
                "MaxScore": 0.87,
                "CurrentScore": 0.71
            },
            "Impact": {
                "MaxImpact": 1842.31,
                "TotalImpact": 4120.55,
                "TotalActualSpend": 5980.12,
                "TotalExpectedSpend": 1859.57,
                "TotalImpactPercentage": 221.59
            },
            "MonitorArn": "arn:aws:ce::111122223333:anomalymonitor/3f1c8e22-9a7d-4c11-b0e6-51ab2d7f9c40",
            "Feedback": "YES"
        }
    ],
    "NextPageToken": null
}
```

`UsageType: EUW1-DataProcessing-Bytes` en CloudWatch nombra la causa con precisión: volumen de ingesta de logs, en Irlanda, en `prod-platform`. Esperado $1.859 → real $5.980. El próximo paso es `aws logs describe-log-groups --query 'logGroups | sort_by(@, &storedBytes) | reverse(@)[:5]'`, no una conversación con finanzas.

Enviá siempre `put-anomaly-feedback` — el modelo lo usa:

```console
$ aws ce provide-anomaly-feedback \
    --anomaly-id a1d9f77c-3b52-4b8e-9f01-27c4d5b6e8a3 \
    --feedback YES
{
    "AnomalyId": "a1d9f77c-3b52-4b8e-9f01-27c4d5b6e8a3"
}
```

---

## 10. Opciones de compra e instrumentos de compromiso

La gestión de costos no es solo observación; la palanca más grande es *cómo* comprás cómputo. El examen evalúa el reconocimiento de estas opciones y sus compensaciones.

| Opción | Descuento vs On-Demand | Compromiso | Flexibilidad | Riesgo de interrupción | Ideal para |
|---|---|---|---|---|---|
| **On-Demand** | línea base | ninguno | total | ninguno | Cargas con picos, impredecibles, de vida corta |
| **Spot Instances** | hasta ~90% | ninguno | cualquier tipo de instancia | **aviso de interrupción de 2 minutos** | Batch tolerante a fallos, CI, workers sin estado, big-data |
| **Compute Savings Plans** | hasta ~66% | $/hora por 1 o 3 años | **Cualquier región, familia, tamaño, SO, tenancy; EC2 + Fargate + Lambda** | ninguno | Opción por defecto para la mayoría de las organizaciones |
| **EC2 Instance Savings Plans** | hasta ~72% | $/hora, 1 o 3 años, **atado a una familia en una región** | Flexible en tamaño/SO/tenancy dentro de esa familia | ninguno | Flotas estables y bien conocidas en estado estacionario |
| **SageMaker Savings Plans** | hasta ~64% | $/hora, 1 o 3 años | Familias/regiones de instancias de SageMaker | ninguno | Plataformas de ML |
| **Standard Reserved Instances** | hasta ~72% | Atributos de instancia, 1 o 3 años | Flexible en tamaño dentro de la familia (Linux/shared); **vendibles en el RI Marketplace** | ninguno | Cargas estables donde importa la salida por marketplace |
| **Convertible RIs** | hasta ~54% | 1 o 3 años | Intercambiables por otra familia/SO/tenancy | ninguno | Horizonte largo, mezcla de instancias incierta |
| **Capacity Reservations** | **sin descuento** | ninguno (se factura como On-Demand mientras esté activa) | Reserva capacidad en una AZ específica | ninguno | Capacidad garantizada para DR/failover; combinar con un SP para el descuento |
| **Dedicated Hosts** | varía; soporta BYOL | On-Demand o reservado | Servidor físico, sockets/cores visibles | ninguno | Cumplimiento de licencias (Windows Server, Oracle, SQL Server) |
| **Dedicated Instances** | premium | On-Demand o reservado | Hardware aislado, sin visibilidad de sockets | ninguno | Aislamiento regulatorio sin necesidades de licencia |

**Opciones de pago** (RIs y Savings Plans): **All Upfront** (mayor descuento) > **Partial Upfront** > **No Upfront** (menor descuento, sin desembolso de capital).

Dos errores para internalizar:

1. **Una Capacity Reservation no es un descuento.** Reserva capacidad y factura tarifas On-Demand corras o no instancias en ella. Combinala con un Savings Plan si querés ambas garantías.
2. **Los Savings Plans y los RIs son construcciones de facturación, no garantías de capacidad.** Comprar un SP no reserva nada; solo una RI zonal o una Capacity Reservation lo hace.

Obtener una recomendación antes de comprometerse:

```console
$ aws ce get-savings-plans-purchase-recommendation \
    --savings-plans-type COMPUTE_SP \
    --term-in-years ONE_YEAR \
    --payment-option NO_UPFRONT \
    --lookback-period-in-days SIXTY_DAYS \
    --query 'SavingsPlansPurchaseRecommendation.SavingsPlansPurchaseRecommendationSummary'
{
    "EstimatedROI": "38.42",
    "CurrencyCode": "USD",
    "EstimatedTotalCost": "412880.11",
    "CurrentOnDemandSpend": "596441.72",
    "EstimatedSavingsAmount": "183561.61",
    "TotalRecommendationCount": "1",
    "DailyCommitmentToPurchase": "1131.18",
    "HourlyCommitmentToPurchase": "47.13",
    "EstimatedSavingsPercentage": "30.77",
    "EstimatedMonthlySavingsAmount": "15296.80",
    "EstimatedOnDemandCostWithCurrentCommitment": "596441.72"
}

$ aws ce get-savings-plans-utilization \
    --time-period Start=2026-08-01,End=2026-09-01 \
    --granularity MONTHLY
{
    "SavingsPlansUtilizationsByTime": [
        {
            "TimePeriod": {"Start": "2026-08-01", "End": "2026-09-01"},
            "Utilization": {
                "TotalCommitment": "35064.72",
                "UsedCommitment": "34210.09",
                "UnusedCommitment": "854.63",
                "UtilizationPercentage": "97.56"
            },
            "Savings": {
                "NetSavings": "11842.30",
                "OnDemandCostEquivalent": "46052.39"
            },
            "AmortizedCommitment": {
                "AmortizedRecurringCommitment": "35064.72",
                "AmortizedUpfrontCommitment": "0",
                "TotalAmortizedCommitment": "35064.72"
            }
        }
    ],
    "Total": { "...": "..." }
}
```

`UtilizationPercentage: 97.56` es saludable. Cualquier valor sostenido por debajo de ~90% significa que sobre-comprometiste y estás quemando plata en compromiso no usado — exactamente la condición que el presupuesto `SAVINGS_PLANS_UTILIZATION` de la §7.2 fue construido para atrapar.

**Cost Optimization Hub** agrega y deduplica recomendaciones de Compute Optimizer, Cost Explorer y detección de recursos ociosos en una única lista rankeada, expresada en *tus* términos ajustados por descuento:

```console
$ aws cost-optimization-hub list-recommendations \
    --filter '{"actionTypes":["Rightsize","Stop","Delete"]}' \
    --order-by '{"dimension":"EstimatedMonthlySavings","order":"Desc"}' \
    --max-results 4
{
    "items": [
        {
            "recommendationId": "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d",
            "accountId": "222233334444",
            "region": "eu-west-1",
            "resourceId": "i-0fa71c8e2b9d43a10",
            "resourceArn": "arn:aws:ec2:eu-west-1:222233334444:instance/i-0fa71c8e2b9d43a10",
            "currentResourceType": "Ec2Instance",
            "recommendedResourceType": "Ec2Instance",
            "estimatedMonthlySavings": 1284.40,
            "estimatedSavingsPercentage": 62.0,
            "estimatedMonthlyCost": 2071.61,
            "currencyCode": "USD",
            "implementationEffort": "Medium",
            "restartNeeded": true,
            "actionType": "Rightsize",
            "rollbackPossible": true,
            "source": "ComputeOptimizer",
            "lastRefreshTimestamp": "2026-09-04T03:22:10+00:00",
            "tags": [{"key": "cost-center", "value": "CC-1001"}]
        },
        {
            "recommendationId": "2b3c4d5e-6f7a-4b8c-9d0e-1f2a3b4c5d6e",
            "accountId": "333344445555",
            "region": "eu-west-1",
            "resourceId": "vol-08c1d92f3ba74e6f1",
            "currentResourceType": "EbsVolume",
            "recommendedResourceType": "EbsVolume",
            "estimatedMonthlySavings": 612.09,
            "estimatedSavingsPercentage": 44.0,
            "implementationEffort": "VeryLow",
            "restartNeeded": false,
            "actionType": "Rightsize",
            "rollbackPossible": true,
            "source": "ComputeOptimizer",
            "lastRefreshTimestamp": "2026-09-04T03:22:10+00:00"
        },
        {
            "recommendationId": "3c4d5e6f-7a8b-4c9d-0e1f-2a3b4c5d6e7f",
            "accountId": "555566667777",
            "region": "us-east-1",
            "resourceId": "i-0b2c9e7f1a4d83b62",
            "currentResourceType": "Ec2Instance",
            "estimatedMonthlySavings": 498.22,
            "estimatedSavingsPercentage": 100.0,
            "implementationEffort": "VeryLow",
            "restartNeeded": false,
            "actionType": "Stop",
            "rollbackPossible": true,
            "source": "CostExplorer",
            "lastRefreshTimestamp": "2026-09-04T03:22:10+00:00"
        },
        {
            "recommendationId": "4d5e6f7a-8b9c-4d0e-1f2a-3b4c5d6e7f80",
            "accountId": "222233334444",
            "region": "eu-west-1",
            "resourceId": "eipalloc-0d41f8b7c9e2a6503",
            "currentResourceType": "Ec2AutoScalingGroup",
            "estimatedMonthlySavings": 87.60,
            "estimatedSavingsPercentage": 100.0,
            "implementationEffort": "VeryLow",
            "restartNeeded": false,
            "actionType": "Delete",
            "rollbackPossible": false,
            "source": "CostExplorer",
            "lastRefreshTimestamp": "2026-09-04T03:22:10+00:00"
        }
    ]
}
```

Priorizá por `estimatedMonthlySavings / implementationEffort`, y tratá `restartNeeded: true` como un cambio que necesita una ventana de mantenimiento — el número de "$1.284/mes" solo es real si el cambio efectivamente se despliega.

---

## 11. IAM y control de acceso para datos de facturación

Los permisos de facturación son una superficie distinta con dos compuertas que atrapan a todo equipo alguna vez.

**Compuerta 1 — el interruptor a nivel de cuenta.** En la cuenta de administración, el usuario root debe habilitar *IAM user and role access to Billing information*. Hasta que eso esté activado, **ninguna** política de IAM otorga acceso a la consola de Billing, por más permisiva que sea.

**Compuerta 2 — la política de IAM.** AWS reemplazó las acciones legacy gruesas `aws-portal:*` por servicios de grano fino. Las políticas escritas contra las acciones viejas ya no funcionan.

| Aspecto | Acciones de grano fino (actuales) | Legacy (deprecadas) |
|---|---|---|
| Ver facturas y consola de facturación | `billing:GetBillingData`, `billing:GetBillingDetails`, `billing:GetBillingNotifications` | `aws-portal:ViewBilling` |
| Cost Explorer | `ce:GetCostAndUsage`, `ce:GetCostForecast`, `ce:GetDimensionValues`, `ce:GetTags` | — |
| Budgets | `budgets:ViewBudget`, `budgets:ModifyBudget`, `budgets:DescribeBudgetAction` | `aws-portal:ViewBudget` |
| CUR / Data Exports | `cur:DescribeReportDefinitions`, `bcm-data-exports:GetExport` | — |
| Métodos de pago | `payments:ListPaymentMethods`, `payments:UpdatePaymentMethods` | `aws-portal:ViewPaymentMethods` |
| Configuración de la cuenta | `account:GetAccountInformation`, `account:GetContactInformation` | `aws-portal:ViewAccount` |
| Configuración impositiva | `tax:GetTaxRegistration`, `tax:UpdateTaxRegistration` | — |
| Uso del Free Tier | `freetier:GetFreeTierUsage` | — |
| Facturación consolidada | `consolidatedbilling:GetAccountBillingRole`, `consolidatedbilling:ListLinkedAccounts` | — |
| Facturas | `invoicing:GetInvoicePDF`, `invoicing:ListInvoiceSummaries` | — |

Un rol de FinOps de solo lectura — notá la *ausencia* de un deny explícito sobre las llamadas medidas de Cost Explorer, y en su lugar un límite de permisos que deberías combinar con rate limiting en la capa de aplicación:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "BillingConsoleReadOnly",
      "Effect": "Allow",
      "Action": [
        "billing:Get*",
        "billing:List*",
        "consolidatedbilling:Get*",
        "consolidatedbilling:List*",
        "invoicing:Get*",
        "invoicing:List*",
        "account:GetAccountInformation",
        "account:GetContactInformation",
        "freetier:Get*",
        "tax:Get*",
        "tax:List*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CostExplorerReadOnly",
      "Effect": "Allow",
      "Action": [
        "ce:Describe*",
        "ce:Get*",
        "ce:List*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "BudgetsAndReportsReadOnly",
      "Effect": "Allow",
      "Action": [
        "budgets:Describe*",
        "budgets:View*",
        "cur:DescribeReportDefinitions",
        "bcm-data-exports:GetExport",
        "bcm-data-exports:ListExports",
        "cost-optimization-hub:GetRecommendation",
        "cost-optimization-hub:ListRecommendations",
        "cost-optimization-hub:ListRecommendationSummaries",
        "compute-optimizer:Get*",
        "compute-optimizer:Describe*",
        "pricing:GetProducts",
        "pricing:DescribeServices",
        "pricing:GetAttributeValues"
      ],
      "Resource": "*"
    },
    {
      "Sid": "DenyAnyMutation",
      "Effect": "Deny",
      "Action": [
        "budgets:ModifyBudget",
        "budgets:DeleteBudget",
        "ce:CreateCostCategoryDefinition",
        "ce:UpdateCostCategoryDefinition",
        "ce:DeleteCostCategoryDefinition",
        "ce:UpdateCostAllocationTagsStatus",
        "cur:PutReportDefinition",
        "cur:DeleteReportDefinition",
        "bcm-data-exports:CreateExport",
        "bcm-data-exports:DeleteExport",
        "payments:*",
        "billingconductor:Create*",
        "billingconductor:Update*",
        "billingconductor:Delete*"
      ],
      "Resource": "*"
    }
  ]
}
```

**La visibilidad de la cuenta miembro** es una tercera compuerta: por defecto una cuenta miembro no puede abrir Cost Explorer para sus propios datos. El payer debe habilitar *linked account access to Cost Explorer* en las preferencias de Cost Management de la cuenta de administración. Habilitarlo expone los costos propios del miembro, no los de la organización.

---

## 12. Recetario de CLI

```console
# --- Where is the money going, by service, last 30 days ---------------------
$ aws ce get-cost-and-usage \
    --time-period Start=2026-08-05,End=2026-09-04 \
    --granularity MONTHLY \
    --metrics AmortizedCost \
    --group-by Type=DIMENSION,Key=SERVICE \
    --query 'ResultsByTime[0].Groups[?to_number(Metrics.AmortizedCost.Amount)>`1000`].[Keys[0],Metrics.AmortizedCost.Amount]' \
    --output table
--------------------------------------------------------------------
|                        GetCostAndUsage                           |
+---------------------------------------------+--------------------+
|  Amazon Elastic Compute Cloud - Compute      |  18422.7310394     |
|  Amazon Relational Database Service          |   9104.2280110     |
|  AWS Data Transfer                           |   6877.1093004     |
|  Amazon Simple Storage Service               |   4011.9820773     |
|  Amazon Elastic Container Service for Kube.. |   2190.0000000     |
|  AmazonCloudWatch                            |   5980.1200041     |
|  Amazon Virtual Private Cloud                |   3402.8811009     |
+---------------------------------------------+--------------------+

# --- Same period, but split by the cost category we defined -----------------
$ aws ce get-cost-and-usage \
    --time-period Start=2026-08-01,End=2026-09-01 \
    --granularity MONTHLY \
    --metrics UnblendedCost \
    --group-by Type=COST_CATEGORY,Key=BusinessUnit \
    --query 'ResultsByTime[0].Groups[].[Keys[0],Metrics.UnblendedCost.Amount]' \
    --output text
BusinessUnit$DataPlatform             14882.331200
BusinessUnit$Payments                 21044.770100
BusinessUnit$PlatformSharedServices    7104.209800
BusinessUnit$Unallocated-Shared        1497.128900

# --- Forecast the rest of the month, with a confidence interval -------------
$ aws ce get-cost-forecast \
    --time-period Start=2026-09-05,End=2026-10-01 \
    --metric UNBLENDED_COST \
    --granularity MONTHLY \
    --prediction-interval-level 80
{
    "Total": {
        "Amount": "38104.5521",
        "Unit": "USD"
    },
    "ForecastResultsByTime": [
        {
            "TimePeriod": {"Start": "2026-09-05", "End": "2026-10-01"},
            "MeanValue": "38104.5521",
            "PredictionIntervalLowerBound": "35218.7710",
            "PredictionIntervalUpperBound": "41302.9944"
        }
    ]
}

# --- Which dimension values exist? (avoid guessing filter strings) ----------
$ aws ce get-dimension-values \
    --time-period Start=2026-08-01,End=2026-09-01 \
    --dimension PURCHASE_TYPE \
    --query 'DimensionValues[].Value' --output text
Credit  On Demand Instances     Savings Plans   Spot Instances  Standard Reserved Instances

# --- Budget state right now -------------------------------------------------
$ aws budgets describe-budgets --account-id 111122223333 \
    --query 'Budgets[].[BudgetName,BudgetLimit.Amount,CalculatedSpend.ActualSpend.Amount,CalculatedSpend.ForecastedSpend.Amount]' \
    --output table
---------------------------------------------------------------------------------
|                                DescribeBudgets                                |
+--------------------------------+-----------+--------------+------------------+
|  org-monthly-unblended-cost    |  42000.0  |  31877.42    |  44012.09        |
|  savings-plans-utilization-floor| 95.0     |  97.56       |  None            |
|  team-CC-1001-monthly          |  8000.0   |   6720.11    |   9104.88        |
|  sandbox-hard-stop             |  1500.0   |    912.44    |   1288.03        |
+--------------------------------+-----------+--------------+------------------+

# --- Did any budget action fire? -------------------------------------------
$ aws budgets describe-budget-actions-for-budget \
    --account-id 111122223333 --budget-name sandbox-hard-stop \
    --query 'Actions[].[ActionId,ActionType,Status,ApprovalModel]' --output text
1f0a4b2c-...  APPLY_IAM_POLICY  STANDBY  AUTOMATIC

$ aws budgets describe-budget-action-histories \
    --account-id 111122223333 --budget-name sandbox-hard-stop \
    --action-id 1f0a4b2c-8e33-4c71-9a02-6b7d5e4f1a99 \
    --query 'ActionHistories[0]'
{
    "Timestamp": "2026-08-29T18:07:44.112000+00:00",
    "Status": "EXECUTION_SUCCESS",
    "EventType": "SYSTEM",
    "ActionHistoryDetails": {
        "Message": "Budget action executed: policy attached to role EngineerSandboxRole.",
        "Action": {
            "ActionId": "1f0a4b2c-8e33-4c71-9a02-6b7d5e4f1a99",
            "BudgetName": "sandbox-hard-stop",
            "ActionType": "APPLY_IAM_POLICY",
            "Status": "EXECUTION_SUCCESS"
        }
    }
}

# --- Free Tier consumption (endpoint is us-east-1 only) --------------------
$ aws freetier get-free-tier-usage --region us-east-1 \
    --query 'freeTierUsages[?forecastedUsageAmount>limit].[service,usageType,actualUsageAmount,forecastedUsageAmount,limit,unit]' \
    --output table
------------------------------------------------------------------------------------
|                              GetFreeTierUsage                                    |
+-------------+----------------------------+-------+--------+--------+-------------+
|  AWSLambda  |  Global-Request            | 812441| 1204880| 1000000|  Requests   |
|  AmazonEC2  |  BoxUsage:t3.micro         |  612.0|   784.0|   750.0|  Hrs        |
+-------------+----------------------------+-------+--------+--------+-------------+

# --- Public price list: what does an m6i.2xlarge cost on-demand in eu-west-1?
$ aws pricing get-products --region us-east-1 \
    --service-code AmazonEC2 \
    --filters \
      Type=TERM_MATCH,Field=instanceType,Value=m6i.2xlarge \
      Type=TERM_MATCH,Field=regionCode,Value=eu-west-1 \
      Type=TERM_MATCH,Field=operatingSystem,Value=Linux \
      Type=TERM_MATCH,Field=tenancy,Value=Shared \
      Type=TERM_MATCH,Field=preInstalledSw,Value=NA \
      Type=TERM_MATCH,Field=capacitystatus,Value=Used \
    --query 'PriceList[0]' --output text | \
  jq -r '.terms.OnDemand | to_entries[0].value.priceDimensions | to_entries[0].value | "\(.pricePerUnit.USD) USD per \(.unit) — \(.description)"'
0.4280000000 USD per Hrs — $0.428 per On Demand Linux m6i.2xlarge Instance Hour

# --- Cost allocation tag status ------------------------------------------
$ aws ce list-cost-allocation-tags --status Active \
    --query 'CostAllocationTags[].[TagKey,Type,Status]' --output text
cost-center     UserDefined     Active
environment     UserDefined     Active
team            UserDefined     Active
aws:createdBy   AWSGenerated    Active

# --- Organization-wide RI/SP sharing check --------------------------------
$ aws organizations describe-organization --query 'Organization.[Id,FeatureSet,MasterAccountId]' --output text
o-a1b2c3d4e5    ALL     111122223333
```

---

## 13. Verificación y diagnóstico de fallas

### 13.1 Checklist de verificación posterior al despliegue

Ejecutá esto después de construir los guardrails; cada paso prueba un eslabón de la cadena.

```console
# 1. The CUR/Data Export is actually delivering.
$ aws bcm-data-exports list-exports --region us-east-1 \
    --query 'Exports[].[ExportName,ExportStatus.StatusCode,ExportStatus.LastRefreshedAt]' --output text
org-cur2-hourly HEALTHY 2026-09-04T06:11:52+00:00

# 2. Objects exist in the bucket for the current billing period.
$ aws s3 ls s3://acme-finops-cur-111122223333/cur2/org-cur2-hourly/ --recursive \
    | tail -3
2026-09-04 06:14:02   48213991 cur2/org-cur2-hourly/data/BILLING_PERIOD=2026-09/org-cur2-hourly-00001.snappy.parquet
2026-09-04 06:14:07       2044 cur2/org-cur2-hourly/metadata/BILLING_PERIOD=2026-09/org-cur2-hourly-Manifest.json
2026-09-04 06:14:07        918 cur2/org-cur2-hourly/metadata/BILLING_PERIOD=2026-09/org-cur2-hourly-Metadata.json

# 3. Athena can read it and the totals are non-zero.
$ aws athena start-query-execution --work-group finops-cur \
    --query-execution-context Database=cur_analytics \
    --query-string "SELECT count(*) rows, round(sum(line_item_unblended_cost),2) usd FROM org_cur2_hourly WHERE bill_billing_period_start_date = DATE '2026-08-01'" \
    --query QueryExecutionId --output text
c9e2a1b4-77d0-4e18-9b3a-2f5c8d1e6a04

$ aws athena get-query-results --query-execution-id c9e2a1b4-77d0-4e18-9b3a-2f5c8d1e6a04 \
    --query 'ResultSet.Rows[1].Data[*].VarCharValue' --output text
41882913        45528.44

# 4. The CUR total reconciles with Cost Explorer within rounding.
$ aws ce get-cost-and-usage --time-period Start=2026-08-01,End=2026-09-01 \
    --granularity MONTHLY --metrics UnblendedCost \
    --query 'ResultsByTime[0].Total.UnblendedCost.Amount' --output text
45528.4412210

# 5. The SNS topic accepts a publish from the Budgets principal.
$ aws sns get-topic-attributes --topic-arn arn:aws:sns:eu-west-1:111122223333:finops-budget-alerts \
    --query 'Attributes.Policy' --output text | jq -r '.Statement[].Principal.Service'
budgets.amazonaws.com
costalerts.amazonaws.com

# 6. End-to-end alert test: publish to the topic directly.
$ aws sns publish --topic-arn arn:aws:sns:eu-west-1:111122223333:finops-budget-alerts \
    --subject "FinOps pipeline test" --message "verification $(date -u +%FT%TZ)"
{
    "MessageId": "8f1c2d4e-9a0b-4c3d-8e7f-1a2b3c4d5e6f"
}

# 7. Anomaly monitors exist and are attached to a subscription.
$ aws ce get-anomaly-monitors --query 'AnomalyMonitors[].[MonitorName,MonitorType,DimensionalValueCount]' --output text
all-services            DIMENSIONAL     412
by-business-unit        CUSTOM          None
sandbox-account         CUSTOM          None

$ aws ce get-anomaly-subscriptions --query 'AnomalySubscriptions[].[SubscriptionName,Frequency,length(MonitorArnList)]' --output text
high-impact-immediate   IMMEDIATE       3
daily-digest            DAILY           1
```

El paso 4 es el que más importa: **si el total del CUR y el total de Cost Explorer no reconcilian, todos los dashboards aguas abajo están mintiendo.** Una brecha acá casi siempre es una discrepancia de métrica (§3) o un `line_item_line_item_type` excluido.

### 13.2 Tabla de diagnóstico de fallas

| Síntoma | Causa probable | Diagnóstico | Solución |
|---|---|---|---|
| CUR creado, **nunca aparece ningún archivo** en S3 | La política del bucket omite `billingreports.amazonaws.com` / `bcm-data-exports.amazonaws.com`, o el **cifrado por defecto del bucket es SSE-KMS** | `aws s3api get-bucket-policy --bucket X`; `aws s3api get-bucket-encryption --bucket X` | Aplicá la política de la §8.1; poné el cifrado por defecto en `AES256` (SSE-S3) |
| Los archivos del CUR aparecen ~24 h tarde en la primera configuración | Normal — la primera entrega puede tardar hasta 24 horas | `ExportStatus.LastRefreshedAt` | Esperá un ciclo antes de escalar |
| Política del bucket correcta, pero sigue `UNHEALTHY` | El CUR/Data Export fue creado fuera de `us-east-1`, o el bucket fue borrado/renombrado | `aws bcm-data-exports get-export --export-arn ...` | Recreá el export en `us-east-1` |
| La columna del cost allocation tag está **vacía para meses pasados** | La activación de tags aplica hacia adelante | `aws ce list-cost-allocation-tags` — revisá `Status` y la fecha de activación | `aws ce start-cost-allocation-tag-backfill --backfill-from <date>` |
| El tag existe en el recurso pero nunca aparece en Cost Explorer | La clave nunca fue **activada** en la cuenta de administración, o la activación tiene <24 h, o la clave usa el prefijo reservado `aws:` | `aws ce list-cost-allocation-tags --status Inactive` | Activá la clave; esperá 24 h; renombrá las claves que colisionen con `aws:` |
| El **presupuesto filtrado por tag siempre reporta $0** | `CostFilters.TagKeyValue` referencia una clave de tag inactiva, o la sintaxis `user:key$value` está mal | `aws budgets describe-budget --budget-name X --query 'Budget.CostFilters'` | Activá la clave; usá exactamente `user:<key>$<value>` |
| **El presupuesto nunca envía una alerta** | La política del topic SNS rechaza `budgets.amazonaws.com`; o la suscripción de email nunca fue confirmada; o la evaluación todavía no corrió (~3×/día) | Publicá al topic manualmente (paso de verificación 6); `aws sns list-subscriptions-by-topic` — buscá `PendingConfirmation` | Agregá el statement a la política del topic; confirmá la suscripción de email |
| **Las alertas de forecast nunca se disparan**, las de actual sí | Historia insuficiente — el forecasting necesita aproximadamente cinco semanas de datos de uso | `CalculatedSpend.ForecastedSpend` está ausente/`None` en `describe-budgets` | Esperá a que se acumule historia; mientras tanto apoyate en umbrales ACTUAL |
| **La budget action no se ejecutó** | `ApprovalModel: MANUAL` (esperando aprobación); o la política de confianza del rol de ejecución omite `budgets.amazonaws.com`; o el rol carece de `iam:AttachRolePolicy` para ese ARN de política | `describe-budget-action-histories` → buscá `EXECUTION_FAILURE` o `PENDING` | Cambiá a `AUTOMATIC` después de probar; arreglá la política de confianza y la condición `iam:PolicyARN` |
| La cuenta miembro ve **"You do not have permission to access billing"** | El "IAM user and role access to Billing information" a nivel root está apagado; o el payer no habilitó el acceso de cuentas vinculadas a Cost Explorer | Iniciá sesión como root → Account settings; cuenta de administración → preferencias de Cost Management | Habilitá ambos interruptores; después adjuntá la política de IAM de grano fino (§11) |
| Una política de IAM con `aws-portal:ViewBilling` ya no funciona | Las acciones legacy fueron reemplazadas por acciones de grano fino `billing:`/`ce:`/`payments:`/`account:` | IAM Access Analyzer / eventos `AccessDenied` en CloudTrail | Reescribí las políticas contra las acciones de grano fino |
| **Cargos inesperados de Cost Explorer** en la factura | `ce:GetCostAndUsage` se factura por request paginado; un dashboard que consulta cada minuto genera miles | CUR: filtrá `line_item_usage_type LIKE '%CostExplorer%'` | Cacheá los resultados; mové la analítica recurrente a CUR + Athena; nunca otorgues `ce:*` a cargas de trabajo dentro del clúster |
| Total de Cost Explorer ≠ total del CUR | Métrica distinta (blended vs unblended vs amortized); el CUR incluye tipos de ítem de línea `Tax`/`Credit`/`Refund` que filtraste; la zona horaria es UTC en ambos pero tu cláusula `WHERE` es local | Volvé a correr ambos con `UnblendedCost` y sin filtro de tipo de ítem de línea | Alineá la métrica y el filtro de tipo de ítem de línea explícitamente |
| Los datos horarios de Cost Explorer **desaparecen después de dos semanas** | La granularidad horaria tiene una ventana de retención de 14 días | — | Usá el CUR para cualquier cosa más vieja que 14 días |
| Anomaly Detection está **en silencio** durante un pico real | El alcance del monitor excluye la cuenta/servicio; `ThresholdExpression` demasiado alto; el monitor fue creado hace <10 días (sin línea base) | `aws ce get-anomaly-monitors`; `get-anomaly-subscriptions` → inspeccioná `ThresholdExpression` | Ampliá el monitor; bajá el umbral absoluto; esperá a la línea base |
| Anomaly Detection es **demasiado ruidoso** | Un único umbral absoluto sobre una carga con picos | Igual | Combiná absoluto **y** porcentaje en una expresión `And` (§9); enviá `provide-anomaly-feedback NO` |
| La Cost Category muestra todo como `Unallocated` | Las reglas nunca coincidieron (el orden importa, gana la primera coincidencia), o la categoría fue creada después de que los recursos se facturaran | `aws ce describe-cost-category-definition --cost-category-arn ...` | Reordená las reglas de más específica a menos; revisá `EffectiveStart` |
| Savings Plan comprado, **descuento no aplicado** a algunas cuentas | La compartición de RI/SP está deshabilitada para esa cuenta miembro, o la cuenta salió de la organización | Cuenta de administración → Billing preferences → configuración de compartición | Volvé a habilitar la compartición para la cuenta |
| `UtilizationPercentage` cayó después de una migración | El gasto comprometido ahora excede la carga de trabajo (compromiso varado) | `aws ce get-savings-plans-utilization` | No se puede cancelar un SP; volvé a traer cargas elegibles al alcance, o dejalo vencer y dimensioná mejor la próxima compra |
| Compute Optimizer dice "insufficient data" | Menos de ~30 horas de métricas de CloudWatch, o la instancia es demasiado nueva | `aws compute-optimizer get-ec2-instance-recommendations --instance-arns ...` → `finding: NotOptimized` vs ausente | Esperá la ventana de métricas; instalá el agente de CloudWatch para recomendaciones que consideren la memoria |
| Una consulta de Athena sobre el CUR es catastróficamente cara | `SELECT *` sobre una tabla no particionada escanea toda la historia | Consola de Athena → *Data scanned* | Filtrá siempre por `bill_billing_period_start_date`; almacená en Parquet; seteá `BytesScannedCutoffPerQuery` en el workgroup (§8.1) |
| Las columnas de split cost de EKS son todas `NULL` | `SPLIT_COST_ALLOCATION_DATA` no está habilitado en la definición del reporte | `aws cur describe-report-definitions --query 'ReportDefinitions[].AdditionalSchemaElements'` | Agregá el elemento de esquema; los datos aplican hacia adelante desde ese punto |

### 13.3 Un diagnóstico trabajado: "el presupuesto se disparó pero no se adjuntó nada"

```console
$ aws budgets describe-budget-action-histories \
    --account-id 111122223333 --budget-name sandbox-hard-stop \
    --action-id 1f0a4b2c-8e33-4c71-9a02-6b7d5e4f1a99 \
    --query 'ActionHistories[0].[Timestamp,Status,ActionHistoryDetails.Message]' --output text
2026-08-29T18:07:44.112000+00:00  EXECUTION_FAILURE  User: arn:aws:sts::111122223333:assumed-role/AWSBudgetsActionExecutionRole/BudgetsActionExecution is not authorized to perform: iam:AttachRolePolicy on resource: role EngineerSandboxRole

$ aws iam get-role --role-name AWSBudgetsActionExecutionRole \
    --query 'Role.AssumeRolePolicyDocument.Statement[0].Principal'
{
    "Service": "budgets.amazonaws.com"
}
```

La confianza está bien — la falla está del lado de los permisos. La política inline de la §7.2 restringe `iam:AttachRolePolicy` con una condición sobre `iam:PolicyARN`, lo cual es correcto, pero el *recurso* es `*`. El error dice que la acción en sí está denegada sobre el rol destino, lo que significa que una SCP o un permissions boundary en la cuenta está bloqueando `iam:AttachRolePolicy`:

```console
$ aws organizations list-policies-for-target --target-id 555566667777 \
    --filter SERVICE_CONTROL_POLICY --query 'Policies[].[Name,Id]' --output text
SandboxRestrictions     p-9f3a1c2e

$ aws organizations describe-policy --policy-id p-9f3a1c2e \
    --query 'Policy.Content' --output text | jq '.Statement[] | select(.Action | tostring | test("iam:"))'
{
  "Sid": "DenyIamMutation",
  "Effect": "Deny",
  "Action": ["iam:Attach*", "iam:Put*", "iam:Create*"],
  "Resource": "*"
}
```

Ahí está. La SCP que endurece el sandbox también bloquea la remediación propia de la budget action. La solución es una excepción en la SCP para el rol de ejecución del presupuesto — la misma forma usada en la §6.2:

```json
{
  "Sid": "DenyIamMutation",
  "Effect": "Deny",
  "Action": ["iam:Attach*", "iam:Put*", "iam:Create*"],
  "Resource": "*",
  "Condition": {
    "ArnNotLike": {
      "aws:PrincipalArn": "arn:aws:iam::*:role/AWSBudgetsActionExecutionRole"
    }
  }
}
```

La lección general: **un guardrail que puede ser bloqueado por otro guardrail no es un guardrail hasta que lo viste ejecutarse con éxito al menos una vez.** Probá las budget actions seteando temporalmente un umbral absurdamente bajo, confirmando `EXECUTION_SUCCESS`, y después restaurando el valor real.

---

## 14. Planes de soporte, brevemente (donde se cruzan con el costo)

Los checks de optimización de costos de Trusted Advisor están gatillados por el nivel de soporte, y por eso aparecen en preguntas de gestión de costos:

| Plan | Checks de Trusted Advisor | Capacidad relevante para costos |
|---|---|---|
| **Basic** | Checks core (service quotas + seguridad seleccionada) | Alertas de Free Tier, consola de Billing, Budgets, Cost Explorer |
| **Developer** | Checks core | Todo lo de Basic |
| **Business** | **Todos los checks**, incluida la categoría completa de optimización de costos | Recomendaciones completas de costos de Trusted Advisor, acceso por API a Trusted Advisor |
| **Enterprise On-Ramp** | Todos los checks | Agrega un pool de Technical Account Managers, revisiones de optimización de costos |
| **Enterprise** | Todos los checks | TAM designado, guía proactiva de costos/arquitectura, Concierge Support (facturación) |

**Concierge Support** (Enterprise) es el específico de facturación: un equipo dedicado a consultas de facturación y de cuenta.

---

## 15. Destilado para el examen — Tarea 4.2

Los patrones de reconocimiento que más probablemente se evalúen:

| Escenario en el enunciado de la pregunta | Servicio correcto |
|---|---|
| "Estimar el costo de una arquitectura propuesta **antes** de construirla" | **AWS Pricing Calculator** |
| "Ser notificado cuando el gasto supera / se pronostica que superará un umbral" | **AWS Budgets** |
| "Visualizar y analizar tendencias de costo del último año, filtrando por servicio/tag" | **AWS Cost Explorer** |
| "Los datos más detallados, a nivel de ítem de línea, por hora, para análisis personalizado en Athena/Redshift" | **AWS Cost and Usage Report / Data Exports** |
| "Detectar automáticamente gastos inusuales usando machine learning" | **AWS Cost Anomaly Detection** |
| "Combinar múltiples cuentas en una factura y obtener descuentos por volumen" | **Facturación consolidada de AWS Organizations** |
| "Etiquetar recursos para que el costo pueda atribuirse a equipos/proyectos" | **Cost allocation tags** (activados en la cuenta de administración) |
| "Agrupar costos por unidad de negocio usando reglas sobre cuentas, servicios y tags" | **AWS Cost Categories** |
| "Recomendaciones para dimensionar correctamente EC2/EBS/Lambda según la utilización" | **AWS Compute Optimizer** |
| "Una única lista rankeada de todas las oportunidades de ahorro de la organización" | **Cost Optimization Hub** |
| "Checks de buenas prácticas incluida la optimización de costos (necesita Business/Enterprise Support)" | **AWS Trusted Advisor** |
| "Facturar a equipos internos con tarifas personalizadas / actuar como revendedor" | **AWS Billing Conductor** |
| "Aplicar automáticamente una política de IAM restrictiva o detener instancias cuando se excede un presupuesto" | **AWS Budgets Actions** |
| "Seguir el uso del Free Tier y ser alertado antes de excederlo" | **Alertas de uso del Free Tier / presupuesto de tipo usage de AWS Budgets** |
| "Consultar programáticamente los precios públicos actuales de AWS" | **AWS Price List API** (`pricing:GetProducts`) |
| "Dar a un equipo de finanzas acceso de solo lectura a la facturación sin ser admin de la consola" | **Política de IAM con acciones de grano fino `billing:`/`ce:`/`budgets:`** + interruptor de acceso a facturación a nivel root |
| "Ver facturas, métodos de pago, créditos, configuración impositiva" | **Consola de AWS Billing and Cost Management** |

Datos que vale la pena memorizar textualmente para el examen:

- Cost Explorer: **13 meses** de historia (actual + 12), **12 meses** de forecast; consola gratis, **la API cuesta $0.01 por request**.
- AWS Budgets: **los primeros dos presupuestos son gratis por cuenta**; los presupuestos se evalúan **aproximadamente tres veces por día**; hasta **5 alertas por presupuesto**, **10 suscriptores de email por alerta**; alertas sobre **actual o forecasted**.
- Cost Anomaly Detection: **gratis**.
- CUR: entregado a **S3**, puede ser **horario/diario/mensual**, hasta **tres refrescos por día**, se integra con **Athena, Redshift, QuickSight**.
- Los cost allocation tags deben ser **activados en la cuenta de administración (payer)** y pueden tardar **hasta 24 horas** en aparecer.
- La facturación consolidada da **una factura**, **agregación por tramos de volumen** y **compartición de RI/Savings Plans** en toda la organización.
- Los Savings Plans comprometen un monto en **$/hora** por **1 o 3 años**; las Reserved Instances comprometen **atributos de instancia**.
- Los **Compute Savings Plans** son los más flexibles (cualquier región, familia, tamaño, SO, tenancy; EC2 + Fargate + Lambda); los **EC2 Instance Savings Plans** dan el descuento más profundo pero atan la familia y la región.
- Una **Capacity Reservation** garantiza capacidad pero no provee **ningún descuento**.
- El set **completo** de checks de Trusted Advisor, incluida la optimización de costos, requiere soporte **Business** o **Enterprise**.

---

## 16. Referencias

**Guía del examen**
- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf

**Billing and Cost Management**
- AWS Billing and Cost Management User Guide — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/billing-what-is.html
- AWS Cost Management User Guide — https://docs.aws.amazon.com/cost-management/latest/userguide/what-is-costmanagement.html
- Billing and Cost Management permissions reference — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/billing-permissions-ref.html
- Migrating from `aws-portal` to fine-grained billing actions — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/migrate-granularaccess-iam-mapping-reference.html

**Cost Explorer**
- Analyzing your costs with AWS Cost Explorer — https://docs.aws.amazon.com/cost-management/latest/userguide/ce-what-is.html
- Understanding cost metrics (unblended, blended, amortized, net) — https://docs.aws.amazon.com/cost-management/latest/userguide/ce-advanced.html
- Cost Explorer API reference — https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/API_Operations_AWS_Cost_Explorer_Service.html

**AWS Budgets**
- Managing your costs with AWS Budgets — https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html
- Configuring AWS Budgets actions — https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-controls.html
- `AWS::Budgets::Budget` CloudFormation reference — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-budgets-budget.html
- `AWS::Budgets::BudgetsAction` CloudFormation reference — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-budgets-budgetsaction.html

**Cost and Usage Reports / Data Exports**
- What are AWS Cost and Usage Reports — https://docs.aws.amazon.com/cur/latest/userguide/what-is-cur.html
- AWS Data Exports (CUR 2.0) — https://docs.aws.amazon.com/cur/latest/userguide/what-is-data-exports.html
- CUR data dictionary — https://docs.aws.amazon.com/cur/latest/userguide/data-dictionary.html
- Split cost allocation data for Amazon EKS — https://docs.aws.amazon.com/cur/latest/userguide/split-cost-allocation-data.html
- Setting up an S3 bucket for CUR delivery — https://docs.aws.amazon.com/cur/latest/userguide/cur-s3.html
- Querying Cost and Usage Reports with Amazon Athena — https://docs.aws.amazon.com/cur/latest/userguide/cur-query-athena.html

**Cost allocation and categorization**
- Using cost allocation tags — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/cost-alloc-tags.html
- Activating user-defined cost allocation tags — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/activating-tags.html
- Cost allocation tag backfill — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/enable-cost-allocation-tag-backfill.html
- AWS Cost Categories — https://docs.aws.amazon.com/cost-management/latest/userguide/manage-cost-categories.html
- Split charge rules for cost categories — https://docs.aws.amazon.com/cost-management/latest/userguide/split-charge-rules.html
- Tagging best practices (AWS Whitepaper) — https://docs.aws.amazon.com/whitepapers/latest/tagging-best-practices/tagging-best-practices.html

**Cost Anomaly Detection**
- Detecting unusual spend with AWS Cost Anomaly Detection — https://docs.aws.amazon.com/cost-management/latest/userguide/manage-ad.html
- `AWS::CE::AnomalyMonitor` CloudFormation reference — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-ce-anomalymonitor.html
- `AWS::CE::AnomalySubscription` CloudFormation reference — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-ce-anomalysubscription.html

**Organizations, consolidated billing and Billing Conductor**
- Consolidated billing for AWS Organizations — https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_accounts_consolidated-billing.html
- Service control policies (SCPs) — https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html
- Tag policies — https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_tag-policies.html
- Turning off Reserved Instance and Savings Plans discount sharing — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/ri-turn-off.html
- What is AWS Billing Conductor — https://docs.aws.amazon.com/billingconductor/latest/userguide/what-is-billingconductor.html

**Pricing, commitments and optimization**
- AWS Pricing Calculator — https://calculator.aws/
- AWS Price List API — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/price-changes.html
- What are Savings Plans — https://docs.aws.amazon.com/savingsplans/latest/userguide/what-is-savings-plans.html
- Amazon EC2 Reserved Instances — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-reserved-instances.html
- Amazon EC2 Spot Instances — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-spot-instances.html
- On-Demand Capacity Reservations — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-capacity-reservations.html
- AWS Compute Optimizer — https://docs.aws.amazon.com/compute-optimizer/latest/ug/what-is-compute-optimizer.html
- Cost Optimization Hub — https://docs.aws.amazon.com/cost-management/latest/userguide/cost-optimization-hub.html
- AWS Trusted Advisor — https://docs.aws.amazon.com/awssupport/latest/user/trusted-advisor.html
- AWS Well-Architected Framework — Cost Optimization Pillar — https://docs.aws.amazon.com/wellarchitected/latest/cost-optimization-pillar/welcome.html

**Free Tier**
- Using the AWS Free Tier — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/billing-free-tier.html
- AWS Free Tier — https://aws.amazon.com/free/

**Pricing de las propias herramientas de gestión de costos**
- AWS Cost Management pricing — https://aws.amazon.com/aws-cost-management/pricing/