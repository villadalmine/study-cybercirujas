# 3.4 Describir las herramientas de monitorización en Azure

**Certificación:** AZ-900 — Microsoft Azure Fundamentals (versión de examen 2026-07-20)
**Dominio:** 3 — Describir la administración y el gobierno de Azure
**Peso del objetivo:** 8.33
**Perfil:** Principal Platform Architect / Senior SRE
**Idioma de autoría:** inglés

---

## 0. Lo que pide el examen frente a lo que exige la producción

La guía de estudio de AZ-900 enuncia este objetivo en tres puntos:

| Punto del examen | Respuesta mínima de examen | Lo que un Platform Architect debe ser realmente capaz de diseñar |
|---|---|---|
| Describir el propósito de Azure Advisor | «Recomendaciones personalizadas de buenas prácticas» | El Advisor Score como entrada de un SLO; automatizar las recomendaciones de Reliability convirtiéndolas en ítems de backlog mediante alertas de Activity Log sobre `Category=Recommendation` |
| Describir Azure Service Health | «La salud de los servicios de Azure y de tus recursos» | La división en tres niveles (Azure Status / Service Health / Resource Health), alertas de Activity Log acotadas, y por qué Resource Health es el único nivel específico de *tu recurso* |
| Describir Azure Monitor, incluidos Log Analytics, las alertas de Azure Monitor y Application Insights | «Recopila y analiza telemetría» | Un pipeline de telemetría completo: rutas de ingesta, planes de tabla, niveles de retención, cardinalidad y control de costes, correlación, máquinas de estado de alertas y un manual de diagnóstico para cuando la telemetría se detiene en silencio |

El examen evalúa reconocimiento. La producción evalúa **si la telemetría sobrevive al incidente que la necesita**. Este material está escrito para la segunda vara; la tabla de correspondencia con el examen en §14 lo colapsa de vuelta a la primera.

---

## 1. El problema arquitectónico

### 1.1 El modo de fallo que motiva todo lo demás

Un equipo de plataforma opera 140 microservicios sobre tres clústeres AKS, 60 VM scale sets, Azure SQL, Service Bus y un Application Gateway. A las 03:14 el flujo de checkout empieza a devolver HTTP 502 para el 8% de las peticiones. Quien está de guardia abre el portal y encuentra:

- Las **métricas de Application Gateway** muestran `FailedRequests` en aumento — pero las métricas no tienen identidad de petición, así que no pueden decir *qué* backend, *qué* tenant ni *qué* ruta de código.
- Los **logs de contenedor de AKS** están ahí — pero el workspace alcanzó su tope diario a las 02:50 y la ingesta se detuvo. Hay un hueco exactamente sobre el incidente.
- **Application Insights** muestra los fallos — pero el sampling adaptativo descartó el 94% de la telemetría bajo carga, y los elementos supervivientes no tienen los spans de dependencias.
- **Service Health** no muestra nada, porque la alerta estaba acotada a la suscripción equivocada.
- Se dispararon seis alertas a la vez, todas apuntando a la misma causa raíz, todas paginando a las mismas tres personas.

Cada uno de esos puntos es un fallo de **diseño**, no de herramientas. Azure Monitor dio la respuesta correcta a la pregunta que estaba configurado para responder.

### 1.2 Las cuatro preguntas que una plataforma de monitorización debe responder

| # | Pregunta | Clase de señal | Superficie en Azure | Presupuesto de latencia |
|---|---|---|---|---|
| 1 | *¿Está rota la plataforma en sí?* | Salud del proveedor | **Azure Service Health** + **Resource Health** | segundos–minutos (lo marca el proveedor) |
| 2 | *¿Mi recurso está incumpliendo un umbral numérico ahora mismo?* | Métricas (series temporales) | **Azure Monitor Metrics**, **Managed Prometheus** | ~30–120 s extremo a extremo |
| 3 | *¿Qué pasó exactamente, a qué petición, en qué orden?* | Logs + trazas (eventos) | **Log Analytics**, **Application Insights** | ~1–5 min de latencia de ingesta típica |
| 4 | *¿Estoy mal configurado de una forma que me va a doler más adelante?* | Postura / consejo | **Azure Advisor**, Defender for Cloud, Azure Policy | horas–días |

Un diseño que no puede responder las cuatro no es observable, apenas está instrumentado. Fijate en la asimetría: **las preguntas 1 y 4 las responde Azure sobre Azure**; las preguntas 2 y 3 las responde *tu* pipeline sobre *tu* carga de trabajo, y solo si lo construiste.

### 1.3 Telemetría del plano de control frente al plano de datos

Esta distinción es la fuente individual más común del «los logs no están» en Azure, y no resulta evidente desde el portal.

```
                         ┌───────────────────────────────────────────┐
   ARM operations        │            CONTROL PLANE                  │
   (create/delete/       │  Activity Log  — subscription-scoped      │
    scale/RBAC/policy)   │  ON BY DEFAULT, 90 days free              │
                         │  Categories: Administrative, ServiceHealth,│
                         │  ResourceHealth, Alert, Autoscale,        │
                         │  Recommendation, Policy, Security         │
                         └───────────────────────────────────────────┘
                                          ║
                                          ║  diagnostic setting (subscription level)
                                          ▼
   ┌──────────────────────────────────────────────────────────────────────┐
   │                          DATA PLANE                                  │
   │                                                                      │
   │  Platform metrics      → ON by default, 93-day retention, free       │
   │  Resource logs         → OFF by default. Nothing is stored until you │
   │                          create a diagnostic setting on the resource │
   │  Guest OS perf/logs    → OFF. Requires Azure Monitor Agent + a DCR   │
   │  Application telemetry → OFF. Requires SDK / OTel / auto-instrument  │
   │  Custom app data       → Logs Ingestion API + DCR + custom table     │
   └──────────────────────────────────────────────────────────────────────┘
```

> **Regla para interiorizar:** *las métricas de plataforma son opt-out. Todo lo demás es opt-in.* Una suscripción recién creada con 200 recursos y cero diagnostic settings tiene exactamente una fuente de logs útil: el Activity Log.

### 1.4 Arquitectura de referencia

```
 ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌──────────────┐  ┌───────────┐
 │ Azure PaaS  │  │  VMs / VMSS │  │ AKS cluster │  │ Applications │  │ Non-Azure │
 │ (SQL, SB,   │  │  Arc servers│  │             │  │ (.NET/Java/  │  │ (on-prem, │
 │  AppGW, KV) │  │             │  │             │  │  Py/Node/Go) │  │  other    │
 └──────┬──────┘  └──────┬──────┘  └──────┬──────┘  └──────┬───────┘  │  clouds)  │
        │                │                │                │          └─────┬─────┘
        │ diagnostic     │ Azure Monitor  │ ama-logs DS    │ App Insights   │ Azure Arc
        │ setting        │ Agent (AMA)    │ ama-metrics    │ SDK / OTel     │ + AMA
        │                │  + DCR/DCE     │  + DCR         │ Distro         │
        ▼                ▼                ▼                ▼                ▼
 ╔══════════════════════════════════════════════════════════════════════════════════╗
 ║                        A Z U R E   M O N I T O R                                 ║
 ║                                                                                  ║
 ║  ┌───────────────────────┐   ┌────────────────────────┐  ┌────────────────────┐  ║
 ║  │  Metrics store        │   │  Log Analytics         │  │ Azure Monitor      │  ║
 ║  │  (time series DB)     │   │  workspace             │  │ workspace          │  ║
 ║  │  93-day, 1-min grain  │   │  (Azure Data Explorer  │  │ (Prometheus TSDB,  │  ║
 ║  │  dimensioned          │   │   engine, KQL)         │  │  PromQL, 18 months)│  ║
 ║  │                       │   │  Analytics / Basic /   │  │                    │  ║
 ║  │                       │   │  Auxiliary table plans │  │                    │  ║
 ║  └───────────┬───────────┘   └───────────┬────────────┘  └─────────┬──────────┘  ║
 ║              │                           │                         │             ║
 ║              └───────────┬───────────────┴─────────────┬───────────┘             ║
 ║                          ▼                             ▼                         ║
 ║              ┌───────────────────────┐     ┌──────────────────────────┐          ║
 ║              │  Alerts               │     │  Visualization           │          ║
 ║              │  metric / log /       │     │  Workbooks, Dashboards,  │          ║
 ║              │  activity log /       │     │  Managed Grafana,        │          ║
 ║              │  Prometheus / health  │     │  Power BI                │          ║
 ║              └───────────┬───────────┘     └──────────────────────────┘          ║
 ╚══════════════════════════╪═══════════════════════════════════════════════════════╝
                            ▼
              ┌──────────────────────────────┐
              │  Action groups               │
              │  email / SMS / push / voice  │
              │  webhook / secure webhook    │
              │  Logic App / Function /      │
              │  Automation runbook / ITSM / │
              │  Event Hub                   │
              └──────────────────────────────┘
                            │
              ┌─────────────┴──────────────┐
              │ Alert processing rules     │  ← suppression windows, action override
              └────────────────────────────┘

 ── Out-of-band, provider-driven ──────────────────────────────────────────────────
   Azure Status (public)  →  Service Health (subscription)  →  Resource Health (resource)
   Azure Advisor (posture: Reliability / Security / Performance / Cost / OpEx)
```

---

## 2. El modelo de datos de Azure Monitor

### 2.1 Métricas frente a logs — la decisión que determina coste y capacidad

| Dimensión | **Métricas** | **Logs (Log Analytics)** |
|---|---|---|
| Forma | Serie temporal numérica: `(timestamp, value, dimensions[])` | Filas tipadas, columnas arbitrarias, incluidos texto y JSON dinámico |
| Almacén | TSDB de propósito específico | Motor de Azure Data Explorer |
| Lenguaje de consulta | Metrics Explorer / REST / PromQL (Managed Prometheus) | **KQL** |
| Latencia de ingesta | ~30–120 s típico | ~1–5 min típico, puede superarse bajo carga |
| Retención | 93 días (métricas de plataforma), fija | 30 días por defecto → 730 días interactivos; hasta 12 años a largo plazo |
| Coste | Métricas de plataforma gratis; métricas custom facturadas por serie temporal | Facturado por GB ingerido + retención más allá de la ventana gratuita |
| Tolerancia a la cardinalidad | **Baja.** Las dimensiones están acotadas; la alta cardinalidad (por ID de petición) destruye el modelo | **Alta.** La cardinalidad es un asunto de consulta, no de almacenamiento |
| Agregación | Preagregada en escritura (Avg/Min/Max/Sum/Count) | Agregada en consulta, así que podés cambiar la pregunta después |
| Mejor para | Umbrales, autoscale, dashboards, numeradores/denominadores de SLI | Causa raíz, forense, correlación, auditoría, cumplimiento |
| Latencia de alerta | La mejor — casi en tiempo real, granularidad de 1 minuto | Peor — limitada por la latencia de ingesta + la frecuencia de evaluación |
| Modo de fallo | No podés hacer una pregunta que no dimensionaste de antemano | Pagás por preguntas que nunca hacés |

**Regla arquitectónica:** *alertá sobre métricas, diagnosticá sobre logs.* Paginar con una alerta de búsqueda en logs por un síntoma que tiene equivalente en métricas añade 2–6 minutos de latencia de ingesta a tu MTTA sin ningún beneficio.

### 2.2 Planes de tabla de Log Analytics

Elegir el plan tabla por tabla es la palanca de coste de mayor apalancamiento de toda la plataforma.

| | **Analytics** | **Basic** | **Auxiliary** |
|---|---|---|---|
| Coste de ingesta | Base (1.0×) | ~0.25× la base | ~0.02× la base |
| Coste de consulta | Incluido | **Facturado por GB escaneado** | **Facturado por GB escaneado** |
| Retención interactiva | 30 días por defecto (configurable 4–730; 90 gratis para tablas de App Insights y Sentinel) | 30 días, fija | 30 días, fija |
| Retención a largo plazo | Hasta 12 años | Hasta 12 años | Hasta 12 años |
| Superficie de KQL | Lenguaje completo | Subconjunto restringido (sin `join` entre tablas, operadores limitados) | Subconjunto restringido |
| Rendimiento de consulta | Optimizado, indexado | Más lento | El más lento (sin índices) |
| Alertas de búsqueda en logs | ✅ Soportadas | ❌ No soportadas | ❌ No soportadas |
| Microsoft Sentinel | ✅ | Parcial | Solo ingesta |
| Uso correcto | Señales sobre las que alertás, hacés join o construís dashboards | Verbosas pero necesarias de vez en cuando: logs de flujo de firewall, logs de acceso de IIS/NGINX, el ruido de `ContainerLogV2` | Archivos solo para cumplimiento: logs de CDN, volcados de auditoría que debés conservar pero consultarás dos veces al año |

> **Trampa:** cambiar una tabla a Basic rompe en silencio todas las alertas de búsqueda en logs sobre ella, sin ningún error en el momento del cambio. Auditá las reglas de alerta **antes** de replanificar una tabla.

### 2.3 Destinos de los diagnostic settings

Cada recurso admite hasta **5 diagnostic settings**, cada uno con su propio conjunto de destinos.

| Destino | Superficie de consulta | Modelo de retención | Perfil de coste típico | Usalo cuando |
|---|---|---|---|---|
| **Log Analytics workspace** | KQL, alertas, workbooks, Sentinel | Plan y retención por tabla | El más alto por GB | Realmente lo vas a consultar |
| **Storage account** | Ninguna de forma nativa (descarga de blob, o external table de ADX) | Política de lifecycle management | El más bajo por GB | Retenciones largas de cumplimiento, archivo barato |
| **Event Hub** | Consumidor en streaming | Retención 1–7 días (hasta 90 en Premium/Dedicated) | Basado en unidades de throughput | SIEM fuera de Azure (Splunk, QRadar), fan-out en tiempo real |
| **Partner solution** | La del proveedor | La del proveedor | El del proveedor | Integración nativa con Datadog / Elastic / Dynatrace |

Un patrón de producción habitual son **dos settings sobre el mismo recurso**: uno a Log Analytics solo con las categorías sobre las que alertás, y otro a Storage con `allLogs` para el archivo de cumplimiento, a ~2% del coste.

### 2.4 `AzureDiagnostics` frente al modo específico de recurso

Los tipos de recurso más antiguos escriben en la única tabla ancha `AzureDiagnostics`, que tiene un límite duro de ~500 columnas y aplica sufijos (`_s`, `_d`, `_b`) para desambiguar tipos entre proveedores de recursos. El **modo específico de recurso** escribe en tablas dedicadas (`AGWAccessLogs`, `AZFWNetworkRule`, `AKSAuditAdmin`, …).

| | `AzureDiagnostics` | Específico de recurso |
|---|---|---|
| Esquema | Una única tabla ancha compartida | Una tabla por categoría de log |
| Riesgo de límite de columnas | Real (~500 columnas, y después descarta) | Ninguno en la práctica |
| Plan por tabla (Basic/Auxiliary) | ❌ No se puede establecer | ✅ Se puede establecer |
| Coste de consulta | Escanea todo | Escanea solo la tabla relevante |
| Migración | — | Unidireccional por recurso; las filas históricas se quedan en la tabla antigua |

**Elegí siempre el modo específico de recurso** para despliegues nuevos. Al ser unidireccional, una migración deja los datos repartidos entre ambas tablas — escribí tus consultas con un `union` durante la ventana de solapamiento.

---

## 3. Rutas de ingesta en detalle

### 3.1 Azure Monitor Agent (AMA) y Data Collection Rules

El agente heredado de Log Analytics (MMA/OMS) llegó al fin de soporte el **31 de agosto de 2024**. AMA es el único agente invitado soportado. Su cambio arquitectónico definitorio es que la configuración se movió *fuera* del workspace y *dentro* de un recurso ARM separado: la **Data Collection Rule (DCR)**.

```
   ┌──────────────┐      ┌───────────────────────────┐      ┌──────────────────┐
   │ VM / VMSS /  │─────▶│ Data Collection Rule      │─────▶│ Log Analytics    │
   │ Arc server / │ DCRA │  dataSources[]            │      │ workspace        │
   │ AKS node     │      │  streams[]                │      │ (or Storage,     │
   └──────┬───────┘      │  transformKql             │      │  Event Hub, AMW) │
          │              │  destinations[]           │      └──────────────────┘
          │              │  dataFlows[]              │
          │              └───────────┬───────────────┘
          │                          │
          │              ┌───────────▼───────────────┐
          └─────────────▶│ Data Collection Endpoint  │  ← required for private link,
                  config │ (DCE)                     │    Logs Ingestion API, and
                         └───────────────────────────┘    custom text/JSON logs
```

Por qué importa operativamente:

- **Un agente, muchas reglas.** Una VM puede asociarse con N DCRs. La DCR de eventos de seguridad de Windows es propiedad del equipo de seguridad; la DCR de rendimiento de la aplicación, del equipo de la app. Ninguna puede romper a la otra.
- **Transformaciones en la ingesta.** `transformKql` se ejecuta *antes* de la facturación. Descartar una columna ruidosa o filtrar `Severity == "Debug"` en la DCR es el control de coste más barato posible — no se te factura lo que la transformación descarta (con la salvedad de que una transformación que solo *filtra* filas es gratuita, mientras que una que añade columnas puede incurrir en cargos de procesamiento en algunos niveles).
- **La asociación es un recurso.** `Microsoft.Insights/dataCollectionRuleAssociations` — si falta, el agente está sano, reporta heartbeat y no recoge nada. Este es el modo de fallo n.º 2 de §12.

### 3.2 Application Insights

Solo Application Insights basado en workspace; el tipo de recurso clásico (sin workspace) se retiró el **29 de febrero de 2024**, y la **ingesta basada en instrumentation key se retiró el 31 de marzo de 2025** — usá connection strings.

Tipos de telemetría y sus tablas de KQL:

| Tipo de telemetría | Tabla | Emitido por |
|---|---|---|
| Petición HTTP entrante | `requests` | SDK de servidor / span de OTel (kind=SERVER) |
| Llamada saliente (HTTP, SQL, cola, blob) | `dependencies` | Autorecogido / span de OTel (kind=CLIENT) |
| Excepciones no controladas + rastreadas | `exceptions` | SDK, con stack trace |
| Líneas de log de la aplicación | `traces` | ILogger, log4j, puentes del módulo logging |
| Eventos de dominio | `customEvents` | `TrackEvent` / OTel |
| Métricas definidas por la app | `customMetrics` | `TrackMetric` / meters de OTel |
| Cargas de página del navegador | `pageViews`, `browserTimings` | SDK de JS |
| Resultados de sondas sintéticas | `availabilityResults` | Standard availability tests |

**Modelo de correlación.** Azure Monitor usa W3C Trace Context (`traceparent`). Cada elemento de telemetría lleva `operation_Id` (la traza) y `operation_ParentId` (el span padre), que es lo que hace posibles la vista de transacción extremo a extremo y el Application Map. Si un salto pierde la cabecera — un proxy que elimina cabeceras desconocidas, un consumidor de cola que no restaura el contexto — la traza se parte en fragmentos huérfanos. Eso es un bug de *sistemas distribuidos* que se presenta como un bug de *monitorización*.

**Sampling** — tres mecanismos, y tenés que saber cuál está activo:

| Tipo de sampling | Dónde se ejecuta | Se ajusta bajo carga | Preserva la correlación | Reduce el coste de ingesta | ¿Por defecto? |
|---|---|---|---|---|---|
| **Adaptativo** | SDK, en proceso | ✅ Sí, dinámicamente | ✅ Sí (por operación) | ✅ Sí | ✅ SDK de ASP.NET / ASP.NET Core |
| **Tasa fija** | SDK, en proceso | ❌ % fijo que fijás vos | ✅ Sí | ✅ Sí | Opt-in (por defecto en OTel Distro, `1.0`) |
| **En ingesta** | Servicio de Azure, tras la transmisión | ❌ % fijo que fijás vos | ✅ Sí | ❌ **No** — ya pagaste por enviarlo | Desactivado |

Las métricas siguen siendo exactas bajo sampling porque el SDK escribe un `itemCount` en cada elemento retenido; por lo tanto KQL debe usar `sum(itemCount)`, no `count()`, o tus números se desviarán por el factor de muestreo.

### 3.3 Managed Prometheus y Managed Grafana

Para Kubernetes, Azure ofrece una ruta compatible con Prometheus totalmente gestionada:

- **Azure Monitor workspace** (`Microsoft.Monitor/accounts`) — el TSDB de Prometheus, 18 meses de retención, endpoint de consulta PromQL.
- Los pods **`ama-metrics`** en el clúster hacen scrape de los targets y remote-write hacia él. La configuración es vía ConfigMaps en `kube-system`, más los CRDs `PodMonitor`/`ServiceMonitor` del grupo de API `azmonitoring.coreos.com/v1`.
- Los **Prometheus rule groups** (`Microsoft.AlertsManagement/prometheusRuleGroups`) evalúan reglas de recording y de alerting *del lado del servidor*, en Azure, no en el clúster — así que las reglas sobreviven a la pérdida del clúster.
- **Azure Managed Grafana** para visualización, con un data source de identidad gestionada hacia el Azure Monitor workspace.

| | Azure Monitor Metrics | Managed Prometheus | Container Insights (logs) |
|---|---|---|---|
| Lenguaje de consulta | Metrics Explorer / REST | **PromQL** | **KQL** |
| Almacén | TSDB de plataforma | Azure Monitor workspace | Log Analytics workspace |
| Retención | 93 días | 18 meses | Según el plan de tabla, hasta 12 años |
| Cardinalidad | Baja | Alta (modelo de labels de Prometheus) | Muy alta |
| Nativo de Kubernetes | ❌ | ✅ CRDs, exporters, dashboards | Parcial |
| Impulsor del coste | Series temporales de métricas custom | Muestras ingeridas + consultas | GB ingeridos |
| Alerting | Metric alerts | Prometheus rule groups | Alertas de búsqueda en logs |

El patrón de producción en AKS es **los tres**: métricas de plataforma para el recurso clúster en sí, Managed Prometheus para los SLIs de las cargas de trabajo y `kube-state-metrics`, y Container Insights (`ContainerLogV2`, `KubeEvents`) para el forense — con `ContainerLogV2` en el plan **Basic** para mantener la factura razonable.

---

## 4. Arquitectura de alertas

### 4.1 Tipos de señal

| Tipo de alerta | Fuente | Frecuencia mín. | Con estado | Dimensiones | Uso típico |
|---|---|---|---|---|---|
| **Metric alert** | Almacén de métricas | 1 min | ✅ Fired → Resolved | ✅ Multidimensional, se divide en una alerta por combinación | Latencia, tasa de error, CPU, profundidad de cola |
| **Metric alert (umbral dinámico)** | Almacén de métricas + ML | 1 min | ✅ | ✅ | Cargas estacionales donde un número estático está mal a las 03:00 y bien a las 13:00 |
| **Alerta de búsqueda en logs** | Log Analytics / App Insights | 1 min (se recomiendan 5 min) | Opcional (`autoMitigate`) | ✅ vía `dimensions[]` | Cualquier cosa sin equivalente en métricas; patrones de texto; joins entre tablas |
| **Activity log alert** | Activity Log | Dirigida por eventos | ✅ | Basada en condiciones | Alguien borró una regla de NSG de producción |
| **Service Health alert** | Activity Log, `category=ServiceHealth` | Dirigida por eventos | ✅ | Filtros de servicio + región | Caída de Azure en tu región |
| **Resource Health alert** | Activity Log, `category=ResourceHealth` | Dirigida por eventos | ✅ | Transiciones de estado de salud | *Esta VM concreta* está Unavailable |
| **Prometheus alert rule** | Azure Monitor workspace | Según el `interval` del grupo | ✅ (duración `for:`) | Labels de PromQL | SLOs de cargas de trabajo en Kubernetes |
| **Smart detection** (App Insights) | ML sobre App Insights | Automática | ✅ | — | Tasa de fallos anómala / degradación de latencia |

### 4.2 El ciclo de vida de una alerta con estado

```
   condition true for N of M periods
              │
              ▼
   ┌──────────────────┐   user ack     ┌──────────────────┐
   │   New / Fired    ├───────────────▶│  Acknowledged    │
   └────────┬─────────┘                └────────┬─────────┘
            │ condition clears &                │
            │ autoMitigate = true               │
            ▼                                   ▼
   ┌────────────────────────────────────────────────────────┐
   │                       Closed                           │
   └────────────────────────────────────────────────────────┘
```

`autoMitigate: true` es lo que impide una tormenta de alertas provocada por un recurso que oscila. Con `numberOfEvaluationPeriods: 4` y `minFailingPeriodsToAlert: 3`, la regla solo se dispara cuando fallaron 3 de las últimas 4 evaluaciones — la cura estándar para el ruido de un único punto de datos.

### 4.3 Action groups — límites que muerden en producción

| Acción | Límite de tasa (por action group) | Notas |
|---|---|---|
| Email | No más de 100 correos por hora a una dirección dada | El exceso se descarta por throttling, no se encola |
| SMS | No más de 1 SMS cada 5 minutos por número de teléfono | Disponibilidad según el país |
| Voz | No más de 1 llamada cada 5 minutos por número | |
| Webhook | No más de 1500 por hora | Un no-2xx se reintenta con backoff y después se descarta |
| Push (app móvil de Azure) | No más de 1 cada 5 minutos por usuario de Entra | |

El **secure webhook** usa autenticación con Microsoft Entra ID en lugar de un secreto compartido en la URL — la opción correcta para cualquier cosa que mute estado aguas abajo (PagerDuty, ServiceNow, una Function interna de autorremediación).

Las **alert processing rules** (`Microsoft.AlertsManagement/actionRules`) se sitúan *entre* la alerta y el action group. Implementan dos cosas de forma declarativa: la supresión durante una ventana de mantenimiento, y aplicar un action group a toda una suscripción o grupo de recursos de una vez en lugar de editar 300 reglas.

---

## 5. Azure Advisor

Advisor es un **motor de postura gratuito y siempre activo** que lee la configuración y la telemetría de tus recursos y produce recomendaciones en cinco pilares, alineados con el Microsoft Azure Well-Architected Framework.

| Pilar | Ejemplos de recomendaciones | Señal que usa Advisor |
|---|---|---|
| **Reliability** | Habilitar redundancia de zona; configurar georreplicación; añadir una segunda AZ a un VMSS | Configuración + topología del servicio |
| **Security** | Delegado en Microsoft Defender for Cloud | Evaluaciones de Defender |
| **Performance** | Pasar a Premium SSD; aumentar el número de instancias de App Service; añadir índices en SQL | Histórico de métricas |
| **Cost** | Redimensionar o apagar VMs ociosas; comprar Reservations / Savings Plan; borrar discos no adjuntos e IPs públicas ociosas | Utilización de 7–60 días |
| **Operational Excellence** | Habilitar logging de diagnóstico; configurar alertas de Service Health; usar Azure Policy | Configuración + Activity Log |

El **Advisor Score** es un agregado de 0–100, ponderado por los recursos que afecta cada recomendación. Es el número para seguir en una revisión trimestral de salud de la plataforma; el valor absoluto es menos significativo que su pendiente.

**Integración en producción:** Advisor escribe eventos de recomendación en el Activity Log bajo `category=Recommendation`, así que las nuevas recomendaciones pueden canalizarse hacia un action group → Logic App → ítem de trabajo. Eso cierra el bucle entre «Azure nos avisó» y «alguien es responsable».

> **Nota de alcance:** las recomendaciones de Advisor se filtran por rol. Un usuario con Reader sobre un grupo de recursos solo ve las recomendaciones de ese grupo. El pilar Cost requiere además acceso al ámbito de facturación para ver el consejo de compra de Reservations.

---

## 6. Azure Service Health — los tres niveles

Aquí es donde quienes se presentan al AZ-900 pierden puntos con más frecuencia, porque tres productos distintos llevan nombres parecidos.

| | **Azure Status** | **Service Health** | **Resource Health** |
|---|---|---|---|
| Alcance | Global, todas las regiones, todos los clientes | **Tus** suscripciones, servicios, regiones | **Un único recurso** que poseés |
| Autenticación | Página pública, sin inicio de sesión | Portal, requiere inicio de sesión | Portal, requiere inicio de sesión |
| Responde | «¿Está caído Azure Storage en West Europe para alguien?» | «¿Me afecta *a mí* el incidente actual?» | «¿Está sana *esta* VM ahora mismo?» |
| Tipos de evento | Solo caídas generalizadas | Incidencias de servicio, mantenimiento planificado, avisos de salud, avisos de seguridad | Available / Unavailable / Degraded / Unknown |
| Atribución de causa | — | Iniciada por la plataforma | Distingue **PlatformInitiated** de **UserInitiated** (vos paraste la VM) |
| Alertable | ❌ | ✅ Activity Log alert, `category=ServiceHealth` | ✅ Activity Log alert, `category=ResourceHealth` |
| Histórico en el portal | Reciente | Historial de eventos conservado durante una ventana móvil (actualmente hasta 90 días para incidencias; más para algunas categorías) | 30 días |
| URL | `https://status.azure.com` | Portal → Service Health | Portal → recurso → Resource health |

**Semántica de los estados de Resource Health:**

| Estado | Significado | Acción de guardia |
|---|---|---|
| `Available` | No hay eventos de plataforma que afecten a este recurso | — |
| `Unavailable` | La plataforma detectó que el recurso no está funcionando como se espera | Comprobá si la causa es `PlatformInitiated` o `UserInitiated` antes de hacer failover |
| `Degraded` | Rendimiento reducido / funcionalidad parcial | Correlacioná con tus propias métricas de SLI |
| `Unknown` | La plataforma no recibe señales de salud desde hace >10 minutos | A menudo es un problema de ruta de red, **no** prueba de que el recurso esté caído |

> **`Unknown` es el peligroso.** Se malinterpreta con frecuencia como «sano» en un dashboard. Tratá `Unknown` como `Degraded` en cualquier decisión automatizada.

---

## 7. Infraestructura completa — Bicep

Lo siguiente es un único archivo Bicep desplegable que aprovisiona toda la pila de observabilidad descrita arriba: workspace, DCE, DCR, Application Insights, Azure Monitor workspace, action groups y todas las clases de alerta.

### `monitoring-stack.bicep`

```bicep
targetScope = 'resourceGroup'

// ─────────────────────────────────────────────────────────────────────────────
// Parameters
// ─────────────────────────────────────────────────────────────────────────────

@description('Short workload identifier used to name every resource.')
@minLength(3)
@maxLength(12)
param workload string = 'checkout'

@description('Deployment environment.')
@allowed([ 'dev', 'stg', 'prd' ])
param env string = 'prd'

@description('Primary Azure region for all regional resources.')
param location string = resourceGroup().location

@description('Interactive retention for the Analytics plan tables, in days.')
@minValue(30)
@maxValue(730)
param retentionInDays int = 90

@description('Hard ceiling on daily ingestion, in GB. -1 disables the cap.')
param dailyQuotaGb int = 50

@description('Distribution list that receives Sev0/Sev1 pages.')
param pagerEmail string = 'sre-oncall@example.com'

@description('Secure webhook endpoint of the incident management platform.')
param incidentWebhookUri string = 'https://events.pagerduty.com/integration/EXAMPLE/enqueue'

@description('Resource ID of the AKS cluster to attach Container Insights to.')
param aksClusterId string

@description('Azure service names to watch in Service Health alerts.')
param watchedServices array = [
  'Azure Kubernetes Service (AKS)'
  'Virtual Machines'
  'Azure Database for PostgreSQL'
  'Application Gateway'
]

@description('Regions to watch in Service Health alerts.')
param watchedRegions array = [
  'West Europe'
  'North Europe'
]

var suffix = '${workload}-${env}'
var tags = {
  workload: workload
  environment: env
  costCenter: 'platform-engineering'
  managedBy: 'bicep'
}

// ─────────────────────────────────────────────────────────────────────────────
// 1. Log Analytics workspace — the logs backbone
// ─────────────────────────────────────────────────────────────────────────────

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${suffix}'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
    workspaceCapping: {
      dailyQuotaGb: dailyQuotaGb
    }
    features: {
      // Resource-context RBAC: a user with read access on a VM can query that
      // VM's rows without being granted read access on the whole workspace.
      enableLogAccessUsingOnlyResourcePermissions: true
      immediatePurgeDataOn30Days: false
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// Per-table plan overrides. ContainerLogV2 is high-volume and rarely joined,
// so it goes to Basic: ~4x cheaper to ingest, billed per GB scanned on query.
resource containerLogPlan 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = {
  parent: law
  name: 'ContainerLogV2'
  properties: {
    plan: 'Basic'
    totalRetentionInDays: 365
  }
}

// Application Insights request telemetry stays on Analytics: it backs alerts,
// the Application Map, and cross-table joins against dependencies.
resource requestsPlan 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = {
  parent: law
  name: 'AppRequests'
  properties: {
    plan: 'Analytics'
    retentionInDays: retentionInDays
    totalRetentionInDays: 730
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. Data Collection Endpoint — required for custom logs and private link
// ─────────────────────────────────────────────────────────────────────────────

resource dce 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name: 'dce-${suffix}'
  location: location
  tags: tags
  kind: 'Linux'
  properties: {
    description: 'Ingestion endpoint for AMA and the Logs Ingestion API'
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. Data Collection Rule — Linux guest OS performance + syslog
// ─────────────────────────────────────────────────────────────────────────────

resource dcrLinuxHost 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: 'dcr-linux-host-${suffix}'
  location: location
  tags: tags
  kind: 'Linux'
  properties: {
    description: 'Guest OS performance counters and syslog for Linux fleet'
    dataCollectionEndpointId: dce.id
    dataSources: {
      performanceCounters: [
        {
          name: 'hostPerfCounters'
          streams: [
            'Microsoft-Perf'
          ]
          samplingFrequencyInSeconds: 60
          counterSpecifiers: [
            'Processor(*)\\% Processor Time'
            'Processor(*)\\% Idle Time'
            'Memory(*)\\% Used Memory'
            'Memory(*)\\Available MBytes Memory'
            'Logical Disk(*)\\% Used Space'
            'Logical Disk(*)\\Disk Read Bytes/sec'
            'Logical Disk(*)\\Disk Write Bytes/sec'
            'Logical Disk(*)\\Disk Transfers/sec'
            'Network(*)\\Total Bytes Transmitted'
            'Network(*)\\Total Bytes Received'
          ]
        }
      ]
      syslog: [
        {
          name: 'criticalSyslog'
          streams: [
            'Microsoft-Syslog'
          ]
          facilityNames: [
            'auth'
            'authpriv'
            'cron'
            'daemon'
            'kern'
            'syslog'
          ]
          logLevels: [
            'Warning'
            'Error'
            'Critical'
            'Alert'
            'Emergency'
          ]
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: law.id
          name: 'primaryWorkspace'
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          'Microsoft-Perf'
        ]
        destinations: [
          'primaryWorkspace'
        ]
      }
      {
        streams: [
          'Microsoft-Syslog'
        ]
        destinations: [
          'primaryWorkspace'
        ]
        // Ingest-time transformation: drop the CRON spam that no one reads,
        // and normalise the hostname. Runs BEFORE billing.
        transformKql: 'source | where not(SyslogMessage has_cs "CRON" and SeverityLevel == "warning") | extend Computer = tolower(Computer)'
      }
    ]
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. Data Collection Rule — Container Insights for AKS
// ─────────────────────────────────────────────────────────────────────────────

resource dcrContainerInsights 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: 'MSCI-${location}-${suffix}'
  location: location
  tags: tags
  kind: 'Linux'
  properties: {
    description: 'Container Insights collection for the AKS cluster'
    dataSources: {
      extensions: [
        {
          name: 'ContainerInsightsExtension'
          extensionName: 'ContainerInsights'
          streams: [
            'Microsoft-ContainerLogV2'
            'Microsoft-KubeEvents'
            'Microsoft-KubePodInventory'
            'Microsoft-KubeNodeInventory'
            'Microsoft-KubePVInventory'
            'Microsoft-KubeServices'
            'Microsoft-InsightsMetrics'
          ]
          extensionSettings: {
            dataCollectionSettings: {
              interval: '1m'
              namespaceFilteringMode: 'Exclude'
              namespaces: [
                'kube-system'
                'gatekeeper-system'
                'azure-arc'
              ]
              enableContainerLogV2: true
            }
          }
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: law.id
          name: 'primaryWorkspace'
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          'Microsoft-ContainerLogV2'
        ]
        destinations: [
          'primaryWorkspace'
        ]
        // Drop health-probe noise before it is billed. This single line
        // routinely removes 30-50% of a cluster's log volume.
        transformKql: 'source | where LogMessage !has "/healthz" and LogMessage !has "/readyz" and LogMessage !has "kube-probe"'
      }
      {
        streams: [
          'Microsoft-KubeEvents'
          'Microsoft-KubePodInventory'
          'Microsoft-KubeNodeInventory'
          'Microsoft-KubePVInventory'
          'Microsoft-KubeServices'
          'Microsoft-InsightsMetrics'
        ]
        destinations: [
          'primaryWorkspace'
        ]
      }
    ]
  }
}

resource dcraAks 'Microsoft.Insights/dataCollectionRuleAssociations@2022-06-01' = {
  name: 'ContainerInsightsExtension'
  scope: aks
  properties: {
    description: 'Associates the AKS cluster with the Container Insights DCR'
    dataCollectionRuleId: dcrContainerInsights.id
  }
}

resource aks 'Microsoft.ContainerService/managedClusters@2024-05-01' existing = {
  name: last(split(aksClusterId, '/'))
}

// ─────────────────────────────────────────────────────────────────────────────
// 5. Custom table + DCR for the Logs Ingestion API
// ─────────────────────────────────────────────────────────────────────────────

resource auditTable 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = {
  parent: law
  name: 'CheckoutAudit_CL'
  properties: {
    plan: 'Analytics'
    retentionInDays: 730
    totalRetentionInDays: 2555
    schema: {
      name: 'CheckoutAudit_CL'
      columns: [
        { name: 'TimeGenerated',  type: 'datetime' }
        { name: 'OrderId',        type: 'string'   }
        { name: 'TenantId',       type: 'string'   }
        { name: 'Action',         type: 'string'   }
        { name: 'ActorUpn',       type: 'string'   }
        { name: 'AmountMinor',    type: 'long'     }
        { name: 'Currency',       type: 'string'   }
        { name: 'Result',         type: 'string'   }
        { name: 'CorrelationId',  type: 'string'   }
        { name: 'SourceIp',       type: 'string'   }
      ]
    }
  }
}

resource dcrAudit 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: 'dcr-audit-${suffix}'
  location: location
  tags: tags
  kind: 'Direct'
  dependsOn: [
    auditTable
  ]
  properties: {
    description: 'Logs Ingestion API endpoint for the checkout audit trail'
    dataCollectionEndpointId: dce.id
    streamDeclarations: {
      'Custom-CheckoutAudit': {
        columns: [
          { name: 'time',          type: 'datetime' }
          { name: 'orderId',       type: 'string'   }
          { name: 'tenantId',      type: 'string'   }
          { name: 'action',        type: 'string'   }
          { name: 'actor',         type: 'string'   }
          { name: 'amountMinor',   type: 'long'     }
          { name: 'currency',      type: 'string'   }
          { name: 'result',        type: 'string'   }
          { name: 'correlationId', type: 'string'   }
          { name: 'sourceIp',      type: 'string'   }
        ]
      }
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: law.id
          name: 'primaryWorkspace'
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          'Custom-CheckoutAudit'
        ]
        destinations: [
          'primaryWorkspace'
        ]
        outputStream: 'Custom-CheckoutAudit_CL'
        transformKql: 'source | project TimeGenerated = time, OrderId = orderId, TenantId = tenantId, Action = action, ActorUpn = actor, AmountMinor = amountMinor, Currency = currency, Result = result, CorrelationId = correlationId, SourceIp = sourceIp'
      }
    ]
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 6. Application Insights — workspace-based
// ─────────────────────────────────────────────────────────────────────────────

resource appi 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${suffix}'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: law.id
    IngestionMode: 'LogAnalytics'
    Flow_Type: 'Bluefield'
    Request_Source: 'rest'
    RetentionInDays: retentionInDays
    SamplingPercentage: json('100')
    DisableIpMasking: false
    DisableLocalAuth: true
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// Standard availability test: a real HTTPS probe from five Azure regions.
resource availabilityTest 'Microsoft.Insights/webtests@2022-06-15' = {
  name: 'wt-${suffix}-checkout-health'
  location: location
  tags: union(tags, {
    // This tag is mandatory: it is how the portal links the test to the
    // Application Insights component. Deployment succeeds without it and the
    // test then never appears in the UI.
    'hidden-link:${appi.id}': 'Resource'
  })
  kind: 'standard'
  properties: {
    Name: 'checkout-health'
    SyntheticMonitorId: 'wt-${suffix}-checkout-health'
    Enabled: true
    Frequency: 300
    Timeout: 30
    Kind: 'standard'
    RetryEnabled: true
    Locations: [
      { Id: 'emea-nl-ams-azr' }
      { Id: 'emea-gb-db3-azr' }
      { Id: 'emea-fr-pra-edge' }
      { Id: 'us-va-ash-azr' }
      { Id: 'apac-sg-sin-azr' }
    ]
    Request: {
      RequestUrl: 'https://checkout.example.com/health/ready'
      HttpVerb: 'GET'
      ParseDependentRequests: false
      FollowRedirects: false
      Headers: [
        {
          key: 'X-Synthetic-Probe'
          value: 'azure-availability-test'
        }
      ]
    }
    ValidationRules: {
      ExpectedHttpStatusCode: 200
      SSLCheck: true
      SSLCertRemainingLifetimeCheck: 14
      ContentValidation: {
        ContentMatch: '"status":"ok"'
        IgnoreCase: true
        PassIfTextFound: true
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 7. Azure Monitor workspace — Managed Prometheus TSDB
// ─────────────────────────────────────────────────────────────────────────────

resource amw 'Microsoft.Monitor/accounts@2023-04-03' = {
  name: 'amw-${suffix}'
  location: location
  tags: tags
  properties: {
    publicNetworkAccess: 'Enabled'
  }
}

resource grafana 'Microsoft.Dashboard/grafana@2023-09-01' = {
  name: 'graf-${suffix}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    apiKey: 'Disabled'
    deterministicOutboundIP: 'Enabled'
    publicNetworkAccess: 'Enabled'
    zoneRedundancy: 'Enabled'
    grafanaIntegrations: {
      azureMonitorWorkspaceIntegrations: [
        {
          azureMonitorWorkspaceResourceId: amw.id
        }
      ]
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 8. Action groups — two severities, two escalation paths
// ─────────────────────────────────────────────────────────────────────────────

resource agPage 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-${suffix}-page'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'page'
    enabled: true
    emailReceivers: [
      {
        name: 'sre-oncall-email'
        emailAddress: pagerEmail
        useCommonAlertSchema: true
      }
    ]
    webhookReceivers: [
      {
        name: 'incident-platform'
        serviceUri: incidentWebhookUri
        useCommonAlertSchema: true
        useAadAuth: false
      }
    ]
    azureAppPushReceivers: [
      {
        name: 'oncall-mobile'
        emailAddress: pagerEmail
      }
    ]
  }
}

resource agTicket 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-${suffix}-ticket'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'ticket'
    enabled: true
    emailReceivers: [
      {
        name: 'platform-team-email'
        emailAddress: 'platform-team@example.com'
        useCommonAlertSchema: true
      }
    ]
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 9. Metric alerts
// ─────────────────────────────────────────────────────────────────────────────

// Static threshold, multi-dimensional, on Application Insights server response time.
resource alertLatency 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-${suffix}-p95-latency'
  location: 'global'
  tags: tags
  properties: {
    description: 'Server response time above 1500 ms averaged over 5 minutes'
    severity: 2
    enabled: true
    scopes: [
      appi.id
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    autoMitigate: true
    targetResourceType: 'Microsoft.Insights/components'
    targetResourceRegion: location
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.MultipleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'ServerResponseTime'
          metricName: 'requests/duration'
          metricNamespace: 'microsoft.insights/components'
          operator: 'GreaterThan'
          threshold: 1500
          timeAggregation: 'Average'
          skipMetricValidation: false
          dimensions: [
            {
              name: 'request/performanceBucket'
              operator: 'Exclude'
              values: [
                '<250ms'
              ]
            }
          ]
        }
      ]
    }
    actions: [
      {
        actionGroupId: agPage.id
        webHookProperties: {
          runbookTag: 'latency'
        }
      }
    ]
  }
}

// Dynamic threshold: the ML model learns the daily and weekly seasonality
// instead of forcing one number that is wrong twice a day.
resource alertFailedRequests 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-${suffix}-failed-requests-anomaly'
  location: 'global'
  tags: tags
  properties: {
    description: 'Failed request count deviates from the learned baseline'
    severity: 1
    enabled: true
    scopes: [
      appi.id
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    autoMitigate: true
    targetResourceType: 'Microsoft.Insights/components'
    targetResourceRegion: location
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.MultipleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'DynamicThresholdCriterion'
          name: 'FailedRequestsAnomaly'
          metricName: 'requests/failed'
          metricNamespace: 'microsoft.insights/components'
          operator: 'GreaterThan'
          alertSensitivity: 'Medium'
          timeAggregation: 'Count'
          failingPeriods: {
            numberOfEvaluationPeriods: 4
            minFailingPeriodsToAlert: 3
          }
          skipMetricValidation: false
        }
      ]
    }
    actions: [
      {
        actionGroupId: agPage.id
      }
    ]
  }
}

// Availability test failure alert — the canonical "is the site up" signal.
resource alertAvailability 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-${suffix}-availability'
  location: 'global'
  tags: tags
  properties: {
    description: 'Standard availability test failing from 2 or more locations'
    severity: 0
    enabled: true
    scopes: [
      appi.id
      availabilityTest.id
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.WebtestLocationAvailabilityCriteria'
      webTestId: availabilityTest.id
      componentId: appi.id
      failedLocationCount: 2
    }
    actions: [
      {
        actionGroupId: agPage.id
      }
    ]
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 10. Log search alert (scheduled query rule)
// ─────────────────────────────────────────────────────────────────────────────

resource alertPodCrashLoop 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: 'alert-${suffix}-pod-crashloop'
  location: location
  tags: tags
  kind: 'LogAlert'
  properties: {
    displayName: 'Pods entering CrashLoopBackOff'
    description: 'Fires when any workload namespace produces BackOff events'
    severity: 2
    enabled: true
    scopes: [
      law.id
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    autoMitigate: true
    checkWorkspaceAlertsStorageConfigured: false
    skipQueryValidation: false
    criteria: {
      allOf: [
        {
          query: '''
KubeEvents
| where TimeGenerated > ago(15m)
| where Reason in ("BackOff", "Failed", "FailedCreatePodSandBox")
| where Namespace !in ("kube-system", "gatekeeper-system")
| summarize EventCount = count() by Namespace, Name, Reason, ClusterName
| where EventCount >= 3
'''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          resourceIdColumn: '_ResourceId'
          dimensions: [
            {
              name: 'Namespace'
              operator: 'Include'
              values: [ '*' ]
            }
            {
              name: 'Name'
              operator: 'Include'
              values: [ '*' ]
            }
          ]
          failingPeriods: {
            numberOfEvaluationPeriods: 2
            minFailingPeriodsToAlert: 2
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        agTicket.id
      ]
      customProperties: {
        runbook: 'https://wiki.example.com/runbooks/crashloop'
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 11. Prometheus rule group — evaluated server-side, survives cluster loss
// ─────────────────────────────────────────────────────────────────────────────

resource promRules 'Microsoft.AlertsManagement/prometheusRuleGroups@2023-03-01' = {
  name: 'prg-${suffix}-slo'
  location: location
  tags: tags
  properties: {
    description: 'SLO recording and alerting rules for the checkout workload'
    enabled: true
    clusterName: last(split(aksClusterId, '/'))
    scopes: [
      amw.id
      aksClusterId
    ]
    interval: 'PT1M'
    rules: [
      {
        record: 'checkout:http_request_error_ratio:rate5m'
        expression: 'sum(rate(http_requests_total{job="checkout",code=~"5.."}[5m])) / sum(rate(http_requests_total{job="checkout"}[5m]))'
        enabled: true
        labels: {
          workload: 'checkout'
        }
      }
      {
        alert: 'CheckoutErrorBudgetBurnFast'
        expression: 'checkout:http_request_error_ratio:rate5m > (14.4 * 0.001)'
        for: 'PT2M'
        enabled: true
        severity: 1
        labels: {
          workload: 'checkout'
          burnrate: 'fast'
        }
        annotations: {
          summary: 'Checkout is burning its 99.9% error budget 14.4x faster than sustainable'
          runbook_url: 'https://wiki.example.com/runbooks/checkout-error-budget'
        }
        resolveConfiguration: {
          autoResolved: true
          timeToResolve: 'PT10M'
        }
        actions: [
          {
            actionGroupId: agPage.id
          }
        ]
      }
      {
        alert: 'CheckoutErrorBudgetBurnSlow'
        expression: 'checkout:http_request_error_ratio:rate5m > (6 * 0.001)'
        for: 'PT15M'
        enabled: true
        severity: 3
        labels: {
          workload: 'checkout'
          burnrate: 'slow'
        }
        annotations: {
          summary: 'Sustained elevated error rate on checkout'
        }
        resolveConfiguration: {
          autoResolved: true
          timeToResolve: 'PT30M'
        }
        actions: [
          {
            actionGroupId: agTicket.id
          }
        ]
      }
    ]
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 12. Alert processing rule — suppress everything during the maintenance window
// ─────────────────────────────────────────────────────────────────────────────

resource maintenanceSuppression 'Microsoft.AlertsManagement/actionRules@2021-08-08' = {
  name: 'apr-${suffix}-maintenance-window'
  location: 'Global'
  tags: tags
  properties: {
    description: 'Suppress non-Sev0 alerts during the weekly patch window'
    enabled: true
    scopes: [
      resourceGroup().id
    ]
    conditions: [
      {
        field: 'Severity'
        operator: 'NotEquals'
        values: [
          'Sev0'
        ]
      }
    ]
    actions: [
      {
        actionType: 'RemoveAllActionGroups'
      }
    ]
    schedule: {
      timeZone: 'W. Europe Standard Time'
      effectiveFrom: '2026-09-06T00:00:00'
      recurrences: [
        {
          recurrenceType: 'Weekly'
          startTime: '02:00:00'
          endTime: '04:00:00'
          daysOfWeek: [
            'Sunday'
          ]
        }
      ]
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 13. Diagnostic settings — Activity Log at subscription scope is in a separate
//     module because it targets a different ARM scope. See activity-log.bicep.
// ─────────────────────────────────────────────────────────────────────────────

resource aksDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-to-law'
  scope: aks
  properties: {
    workspaceId: law.id
    logAnalyticsDestinationType: 'Dedicated' // resource-specific tables
    logs: [
      { category: 'kube-apiserver',          enabled: true }
      { category: 'kube-audit-admin',        enabled: true }
      { category: 'kube-controller-manager', enabled: true }
      { category: 'kube-scheduler',          enabled: false }
      { category: 'cluster-autoscaler',      enabled: true }
      { category: 'guard',                   enabled: true }
      // 'kube-audit' (full) is deliberately OFF: it is typically the single
      // largest log source on any AKS cluster. kube-audit-admin keeps the
      // mutating operations, which is what forensics actually needs.
      { category: 'kube-audit',              enabled: false }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Outputs
// ─────────────────────────────────────────────────────────────────────────────

output workspaceId string = law.id
output workspaceCustomerId string = law.properties.customerId
output dceLogsIngestionEndpoint string = dce.properties.logsIngestion.endpoint
output auditDcrImmutableId string = dcrAudit.properties.immutableId
output appInsightsConnectionString string = appi.properties.ConnectionString
output azureMonitorWorkspaceId string = amw.id
output grafanaEndpoint string = grafana.properties.endpoint
```

### Módulo con ámbito de suscripción — `activity-log.bicep`

Las alertas de Service Health, Resource Health y Advisor viven todas en el ámbito de suscripción, porque el Activity Log es un recurso a nivel de suscripción.

```bicep
targetScope = 'subscription'

@description('Resource ID of the action group that receives platform-health events.')
param actionGroupId string

@description('Resource ID of the Log Analytics workspace receiving the Activity Log.')
param workspaceId string

param watchedServices array = [
  'Azure Kubernetes Service (AKS)'
  'Virtual Machines'
  'Application Gateway'
]

param watchedRegions array = [
  'West Europe'
  'North Europe'
  'Global'
]

// Ship the Activity Log into Log Analytics so it is queryable with KQL and
// joinable against resource logs. Without this, it is only visible in the
// portal blade and expires after 90 days.
resource activityLogToLaw 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'activitylog-to-law'
  properties: {
    workspaceId: workspaceId
    logs: [
      { category: 'Administrative',     enabled: true }
      { category: 'Security',           enabled: true }
      { category: 'ServiceHealth',      enabled: true }
      { category: 'Alert',              enabled: true }
      { category: 'Recommendation',     enabled: true }
      { category: 'Policy',             enabled: true }
      { category: 'Autoscale',          enabled: true }
      { category: 'ResourceHealth',     enabled: true }
    ]
  }
}

// ── Service Health: platform incidents that affect MY services in MY regions ──
resource serviceHealthAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = {
  name: 'alert-service-health'
  location: 'Global'
  properties: {
    description: 'Azure platform incidents, maintenance and advisories in scope'
    enabled: true
    scopes: [
      subscription().id
    ]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'ServiceHealth'
        }
        {
          anyOf: [
            { field: 'properties.incidentType', equals: 'Incident'         }
            { field: 'properties.incidentType', equals: 'Maintenance'      }
            { field: 'properties.incidentType', equals: 'Security'         }
            { field: 'properties.incidentType', equals: 'Informational'    }
          ]
        }
        {
          field: 'properties.impactedServices[*].ServiceName'
          containsAny: watchedServices
        }
        {
          field: 'properties.impactedServices[*].ImpactedRegions[*].RegionName'
          containsAny: watchedRegions
        }
      ]
    }
    actions: {
      actionGroups: [
        {
          actionGroupId: actionGroupId
        }
      ]
    }
  }
}

// ── Resource Health: THIS resource became unavailable, platform-initiated ──
resource resourceHealthAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = {
  name: 'alert-resource-health-unavailable'
  location: 'Global'
  properties: {
    description: 'A resource transitioned to Unavailable or Degraded'
    enabled: true
    scopes: [
      subscription().id
    ]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'ResourceHealth'
        }
        {
          anyOf: [
            { field: 'properties.currentHealthStatus', equals: 'Unavailable' }
            { field: 'properties.currentHealthStatus', equals: 'Degraded'    }
          ]
        }
        {
          field: 'properties.previousHealthStatus'
          equals: 'Available'
        }
        {
          // Exclude self-inflicted transitions: you stopped the VM, that is
          // not an incident. This filter removes the majority of the noise.
          field: 'properties.cause'
          equals: 'PlatformInitiated'
        }
      ]
    }
    actions: {
      actionGroups: [
        {
          actionGroupId: actionGroupId
        }
      ]
    }
  }
}

// ── Advisor: new High-impact Reliability or Cost recommendations ──
resource advisorAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = {
  name: 'alert-advisor-high-impact'
  location: 'Global'
  properties: {
    description: 'New high-impact Advisor recommendation raised'
    enabled: true
    scopes: [
      subscription().id
    ]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'Recommendation'
        }
        {
          field: 'properties.recommendationImpact'
          equals: 'High'
        }
        {
          anyOf: [
            { field: 'properties.recommendationCategory', equals: 'HighAvailability' }
            { field: 'properties.recommendationCategory', equals: 'Cost'             }
            { field: 'properties.recommendationCategory', equals: 'Performance'      }
          ]
        }
      ]
    }
    actions: {
      actionGroups: [
        {
          actionGroupId: actionGroupId
        }
      ]
    }
  }
}

// ── Administrative: someone deleted a production network resource ──
resource destructiveOpAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = {
  name: 'alert-destructive-network-op'
  location: 'Global'
  properties: {
    description: 'Delete operation on a network security or routing resource'
    enabled: true
    scopes: [
      subscription().id
    ]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'Administrative'
        }
        {
          field: 'status'
          equals: 'Succeeded'
        }
        {
          anyOf: [
            { field: 'operationName', equals: 'Microsoft.Network/networkSecurityGroups/delete'             }
            { field: 'operationName', equals: 'Microsoft.Network/networkSecurityGroups/securityRules/delete' }
            { field: 'operationName', equals: 'Microsoft.Network/routeTables/delete'                       }
            { field: 'operationName', equals: 'Microsoft.Network/azureFirewalls/delete'                    }
          ]
        }
      ]
    }
    actions: {
      actionGroups: [
        {
          actionGroupId: actionGroupId
        }
      ]
    }
  }
}
```

### Equivalente en Terraform — `monitoring.tf`

```hcl
terraform {
  required_version = ">= 1.9.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.14"
    }
  }
}

provider "azurerm" {
  features {
    log_analytics_workspace {
      permanently_delete_on_destroy = false
    }
  }
}

locals {
  workload = "checkout"
  env      = "prd"
  suffix   = "${local.workload}-${local.env}"
  location = "westeurope"

  tags = {
    workload    = local.workload
    environment = local.env
    managedBy   = "terraform"
  }
}

resource "azurerm_resource_group" "obs" {
  name     = "rg-observability-${local.suffix}"
  location = local.location
  tags     = local.tags
}

resource "azurerm_log_analytics_workspace" "law" {
  name                       = "log-${local.suffix}"
  location                   = azurerm_resource_group.obs.location
  resource_group_name        = azurerm_resource_group.obs.name
  sku                        = "PerGB2018"
  retention_in_days          = 90
  daily_quota_gb             = 50
  internet_ingestion_enabled = true
  internet_query_enabled     = true
  tags                       = local.tags
}

resource "azurerm_application_insights" "appi" {
  name                       = "appi-${local.suffix}"
  location                   = azurerm_resource_group.obs.location
  resource_group_name        = azurerm_resource_group.obs.name
  workspace_id               = azurerm_log_analytics_workspace.law.id
  application_type           = "web"
  retention_in_days          = 90
  sampling_percentage        = 100
  local_authentication_disabled = true
  tags                       = local.tags
}

resource "azurerm_monitor_action_group" "page" {
  name                = "ag-${local.suffix}-page"
  resource_group_name = azurerm_resource_group.obs.name
  short_name          = "page"
  tags                = local.tags

  email_receiver {
    name                    = "sre-oncall-email"
    email_address           = "sre-oncall@example.com"
    use_common_alert_schema = true
  }

  webhook_receiver {
    name                    = "incident-platform"
    service_uri             = var.incident_webhook_uri
    use_common_alert_schema = true
  }
}

resource "azurerm_monitor_metric_alert" "latency" {
  name                = "alert-${local.suffix}-p95-latency"
  resource_group_name = azurerm_resource_group.obs.name
  scopes              = [azurerm_application_insights.appi.id]
  description         = "Server response time above 1500 ms over 5 minutes"
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"
  auto_mitigate       = true
  tags                = local.tags

  criteria {
    metric_namespace = "microsoft.insights/components"
    metric_name      = "requests/duration"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 1500
  }

  action {
    action_group_id = azurerm_monitor_action_group.page.id
  }
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "crashloop" {
  name                = "alert-${local.suffix}-pod-crashloop"
  resource_group_name = azurerm_resource_group.obs.name
  location            = azurerm_resource_group.obs.location
  description         = "Pods entering CrashLoopBackOff"
  severity            = 2
  enabled             = true
  scopes              = [azurerm_log_analytics_workspace.law.id]
  evaluation_frequency = "PT5M"
  window_duration      = "PT15M"
  auto_mitigation_enabled = true
  tags                 = local.tags

  criteria {
    query = <<-KQL
      KubeEvents
      | where Reason in ("BackOff", "Failed", "FailedCreatePodSandBox")
      | where Namespace !in ("kube-system", "gatekeeper-system")
      | summarize EventCount = count() by Namespace, Name, Reason
      | where EventCount >= 3
    KQL

    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"

    dimension {
      name     = "Namespace"
      operator = "Include"
      values   = ["*"]
    }

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 2
      number_of_evaluation_periods             = 2
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.page.id]
  }
}

resource "azurerm_monitor_activity_log_alert" "service_health" {
  name                = "alert-service-health"
  resource_group_name = azurerm_resource_group.obs.name
  location            = "global"
  scopes              = [data.azurerm_subscription.current.id]
  description         = "Azure platform incidents affecting our services"
  tags                = local.tags

  criteria {
    category = "ServiceHealth"

    service_health {
      events    = ["Incident", "Maintenance", "Security"]
      locations = ["West Europe", "North Europe", "Global"]
      services  = ["Azure Kubernetes Service (AKS)", "Virtual Machines", "Application Gateway"]
    }
  }

  action {
    action_group_id = azurerm_monitor_action_group.page.id
  }
}

data "azurerm_subscription" "current" {}

variable "incident_webhook_uri" {
  type        = string
  description = "Secure webhook endpoint of the incident management platform"
  sensitive   = true
}

output "app_insights_connection_string" {
  value     = azurerm_application_insights.appi.connection_string
  sensitive = true
}
```

---

## 8. Manifiestos de Kubernetes

### 8.1 Configuración del agente de Container Insights — `container-azm-ms-agentconfig.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: container-azm-ms-agentconfig
  namespace: kube-system
  labels:
    app.kubernetes.io/name: ama-logs
    app.kubernetes.io/component: log-collection
data:
  schema-version: v1
  config-version: "prod-2026-09"

  log-data-collection-settings: |-
    [log_collection_settings]
       [log_collection_settings.stdout]
          enabled = true
          # Namespaces whose stdout is NOT collected. Control-plane chatter is
          # the largest avoidable cost on almost every cluster.
          exclude_namespaces = ["kube-system", "gatekeeper-system", "azure-arc", "kube-node-lease"]

       [log_collection_settings.stderr]
          enabled = true
          # stderr is kept for kube-system: that is where crashes surface.
          exclude_namespaces = ["gatekeeper-system", "kube-node-lease"]

       [log_collection_settings.env_var]
          # Environment variables per container. Frequently leaks secrets into
          # the workspace. Default to false and turn on per-investigation.
          enabled = false

       [log_collection_settings.enrich_container_logs]
          # Adds Name/Image to every log row. Costs bytes; buys joins.
          enabled = true

       [log_collection_settings.collect_all_kube_events]
          # false = only non-Normal events. true multiplies KubeEvents volume.
          enabled = false

       [log_collection_settings.schema]
          # ContainerLogV2 supports the Basic table plan and multi-line logs.
          # ContainerLog (v1) does not. Always v2 for new clusters.
          containerlog_schema_version = "v2"

       [log_collection_settings.enable_multiline_logs]
          enabled = true
          stacktrace_languages = ["java", "python", "go", "dotnet"]

       [log_collection_settings.metadata_collection]
          enabled = true
          include_fields = ["podLabels", "podAnnotations", "podUid", "image", "imageID", "imageRepo", "imageTag"]

  prometheus-data-collection-settings: |-
    [prometheus_data_collection_settings.cluster]
       interval = "1m"
       fieldpass = ["kube_pod_status_phase", "kube_deployment_status_replicas_unavailable"]
       monitor_kubernetes_pods = false

    [prometheus_data_collection_settings.node]
       interval = "1m"
       urls = ["http://$NODE_IP:9100/metrics"]
       fieldpass = ["node_filesystem_avail_bytes", "node_filesystem_size_bytes", "node_memory_MemAvailable_bytes"]

  metric_collection_settings: |-
    [metric_collection_settings.collect_kube_system_pv_metrics]
       enabled = true

  alertable-metrics-configuration-settings: |-
    [alertable_metrics_configuration_settings.container_resource_utilization_thresholds]
       container_cpu_threshold_percentage = 90.0
       container_memory_rss_threshold_percentage = 90.0
       container_memory_working_set_threshold_percentage = 90.0

    [alertable_metrics_configuration_settings.pv_utilization_thresholds]
       pv_usage_threshold_percentage = 80.0

    [alertable_metrics_configuration_settings.job_completion_time]
       job_completion_time_threshold_minutes = 360

  agent-settings: |-
    [agent_settings.fbit_config]
       log_flush_interval_secs = "1"
       tail_mem_buf_limit_megabytes = "10"
       tail_buf_chunksize_megabytes = "1"
       tail_buf_maxsize_megabytes = "1"

    [agent_settings.high_log_scale]
       # Raises the per-node throughput ceiling above ~10 MB/s. Requires
       # ContainerLogV2 and additional node resources.
       enabled = false
```

### 8.2 Configuración de scrape de Managed Prometheus — `ama-metrics-settings-configmap.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: ama-metrics-settings-configmap
  namespace: kube-system
data:
  schema-version: v1
  config-version: "prod-2026-09"

  # Which built-in targets the managed collector scrapes.
  default-scrape-settings-enabled: |-
    kubelet = true
    coredns = true
    cadvisor = true
    kubeproxy = false
    apiserver = true
    kubestate = true
    nodeexporter = true
    windowsexporter = false
    windowskubeproxy = false
    kappiebasic = true
    networkobservabilityRetina = true
    networkobservabilityHubble = false
    networkobservabilityCilium = false
    prometheuscollectorhealth = true
    controlplane-apiserver = true
    controlplane-cluster-autoscaler = true
    controlplane-kube-scheduler = false
    controlplane-kube-controller-manager = false
    controlplane-etcd = true
    acstor-capacity-provisioner = false
    acstor-metrics-exporter = false

  # Keep-lists are the primary cost and cardinality control. Without them a
  # medium cluster ingests millions of unused series per minute.
  default-targets-metrics-keep-list: |-
    kubelet = "kubelet_volume_stats_used_bytes|kubelet_volume_stats_capacity_bytes|kubelet_node_name|kubelet_running_pods|kubelet_running_containers|kubelet_pod_start_duration_seconds.*|kubelet_runtime_operations_errors_total"
    coredns = "coredns_dns_request_duration_seconds.*|coredns_dns_responses_total|coredns_panics_total|coredns_forward_healthcheck_broken_total"
    cadvisor = "container_cpu_usage_seconds_total|container_memory_working_set_bytes|container_memory_rss|container_network_receive_bytes_total|container_network_transmit_bytes_total|container_fs_usage_bytes|container_fs_limit_bytes"
    kubeproxy = ""
    apiserver = "apiserver_request_total|apiserver_request_duration_seconds.*|apiserver_current_inflight_requests|etcd_request_duration_seconds.*"
    kubestate = "kube_pod_status_phase|kube_pod_status_ready|kube_pod_container_status_restarts_total|kube_pod_container_status_waiting_reason|kube_deployment_status_replicas.*|kube_deployment_spec_replicas|kube_node_status_condition|kube_node_status_allocatable|kube_job_status_failed|kube_horizontalpodautoscaler_status_.*|kube_persistentvolumeclaim_status_phase"
    nodeexporter = "node_cpu_seconds_total|node_memory_MemAvailable_bytes|node_memory_MemTotal_bytes|node_filesystem_avail_bytes|node_filesystem_size_bytes|node_filesystem_readonly|node_load1|node_load5|node_load15|node_network_receive_bytes_total|node_network_transmit_bytes_total|node_vmstat_pgmajfault|node_disk_io_time_seconds_total"
    windowsexporter = ""
    windowskubeproxy = ""
    podannotations = ""
    kappiebasic = ""
    networkobservabilityRetina = "networkobservability.*"
    controlplane-apiserver = "apiserver_request_total|apiserver_request_duration_seconds.*|apiserver_storage_objects"
    controlplane-cluster-autoscaler = "cluster_autoscaler_unschedulable_pods_count|cluster_autoscaler_failed_scale_ups_total|cluster_autoscaler_scale_down_in_cooldown"
    controlplane-etcd = "etcd_server_has_leader|etcd_mvcc_db_total_size_in_bytes|etcd_server_proposals_failed_total|etcd_disk_wal_fsync_duration_seconds.*"
    minimalingestionprofile = "true"

  # Restricts annotation-based auto-discovery to labelled namespaces, so a
  # single misconfigured pod cannot flood the TSDB cluster-wide.
  pod-annotation-based-scraping: |-
    podannotationnamespaceregex = "checkout|payments|orders"

  prometheus-collector-settings: |-
    cluster_alias = "aks-checkout-prd-weu"
    default_metric_account_name = "amw-checkout-prd"

  debug-mode: |-
    enabled = false
```

### 8.3 Target de scrape personalizado — CRD `PodMonitor`

```yaml
---
apiVersion: azmonitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: checkout-api-podmonitor
  namespace: kube-system   # Managed Prometheus CRs live in kube-system
  labels:
    app.kubernetes.io/part-of: checkout
spec:
  jobLabel: checkout-api
  namespaceSelector:
    matchNames:
      - checkout
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout-api
      app.kubernetes.io/component: http
  podMetricsEndpoints:
    - port: metrics
      path: /metrics
      scheme: http
      interval: 30s
      scrapeTimeout: 25s
      honorLabels: false
      relabelings:
        # Promote pod labels to series labels so PromQL can group by tenant.
        - sourceLabels: [__meta_kubernetes_pod_label_tenant]
          targetLabel: tenant
          action: replace
        - sourceLabels: [__meta_kubernetes_pod_node_name]
          targetLabel: node
          action: replace
        - sourceLabels: [__meta_kubernetes_namespace]
          targetLabel: namespace
          action: replace
      metricRelabelings:
        # Drop Go runtime internals: high volume, near-zero operational value.
        - sourceLabels: [__name__]
          regex: 'go_(gc|memstats|sched)_.*'
          action: drop
        # Drop per-request-id histograms: unbounded cardinality kills the TSDB.
        - sourceLabels: [request_id]
          regex: '.+'
          action: labeldrop
---
apiVersion: azmonitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: checkout-worker-servicemonitor
  namespace: kube-system
spec:
  namespaceSelector:
    matchNames:
      - checkout
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout-worker
  endpoints:
    - port: http-metrics
      path: /metrics
      interval: 30s
      scrapeTimeout: 25s
```

### 8.4 Instrumentación de la aplicación — OpenTelemetry con el exporter de Azure Monitor

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: appinsights-connection
  namespace: checkout
type: Opaque
stringData:
  # Connection string, NOT an instrumentation key: ikey-only ingestion was
  # retired on 2025-03-31.
  APPLICATIONINSIGHTS_CONNECTION_STRING: >-
    InstrumentationKey=00000000-0000-0000-0000-000000000000;IngestionEndpoint=https://westeurope-5.in.applicationinsights.azure.com/;LiveEndpoint=https://westeurope.livediagnostics.monitor.azure.com/;ApplicationId=11111111-1111-1111-1111-111111111111
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout-api
  namespace: checkout
  labels:
    app.kubernetes.io/name: checkout-api
spec:
  replicas: 6
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: checkout-api
        app.kubernetes.io/component: http
        tenant: shared
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9090"
        prometheus.io/path: "/metrics"
    spec:
      serviceAccountName: checkout-api
      containers:
        - name: api
          image: registry.example.com/checkout/api:2026.09.1
          ports:
            - name: http
              containerPort: 8080
            - name: metrics
              containerPort: 9090
          env:
            - name: APPLICATIONINSIGHTS_CONNECTION_STRING
              valueFrom:
                secretKeyRef:
                  name: appinsights-connection
                  key: APPLICATIONINSIGHTS_CONNECTION_STRING

            # cloud_RoleName / cloud_RoleInstance: these two drive the
            # Application Map topology. Without them every service collapses
            # into one unnamed node and the map is useless.
            - name: OTEL_SERVICE_NAME
              value: checkout-api
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: "service.namespace=checkout,deployment.environment=prd"
            - name: OTEL_SERVICE_INSTANCE_ID
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name

            # Head-based sampling at the SDK. 1.0 = keep everything; lower it
            # only after measuring ingestion, and always in a trace-consistent
            # sampler so spans of the same trace share the decision.
            - name: OTEL_TRACES_SAMPLER
              value: parentbased_traceidratio
            - name: OTEL_TRACES_SAMPLER_ARG
              value: "1.0"

            - name: OTEL_PROPAGATORS
              value: tracecontext,baggage
            - name: OTEL_METRICS_EXPORTER
              value: none        # metrics go to Managed Prometheus, not App Insights
            - name: OTEL_LOGS_EXPORTER
              value: azuremonitor
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              memory: 1Gi
          readinessProbe:
            httpGet:
              path: /health/ready
              port: http
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /health/live
              port: http
            periodSeconds: 10
```

---

## 9. Recorrido por la CLI

### 9.1 Aprovisionar y verificar el workspace

```console
$ az extension add --name log-analytics --upgrade --only-show-errors
$ az extension add --name monitor-control-service --upgrade --only-show-errors

$ az group create --name rg-observability-checkout-prd --location westeurope -o table
Location    Name
----------  -----------------------------
westeurope  rg-observability-checkout-prd

$ az deployment group create \
    --resource-group rg-observability-checkout-prd \
    --name obs-stack-2026-09-05 \
    --template-file monitoring-stack.bicep \
    --parameters workload=checkout env=prd \
                 aksClusterId=/subscriptions/8f3a.../resourceGroups/rg-aks-prd/providers/Microsoft.ContainerService/managedClusters/aks-checkout-prd-weu \
    --query "properties.provisioningState" -o tsv
Succeeded

$ az monitor log-analytics workspace show \
    --resource-group rg-observability-checkout-prd \
    --workspace-name log-checkout-prd \
    --query "{name:name, customerId:customerId, sku:sku.name, retention:retentionInDays, dailyCapGb:workspaceCapping.dailyQuotaGb, capState:workspaceCapping.dataIngestionStatus}" -o jsonc
{
  "capState": "RespectQuota",
  "customerId": "5b1f2c9e-4d7a-4a2f-9e11-c0a3f6d8b742",
  "dailyCapGb": 50.0,
  "name": "log-checkout-prd",
  "retention": 90,
  "sku": "PerGB2018"
}
```

> `dataIngestionStatus` es el campo que hay que mirar primero cuando los logs se detienen. `RespectQuota` significa que la ingesta es normal; `ForceOff` significa que se alcanzó el tope diario y **los datos se están descartando, no encolando**.

### 9.2 Inspeccionar los planes de tabla

```console
$ az monitor log-analytics workspace table list \
    --resource-group rg-observability-checkout-prd \
    --workspace-name log-checkout-prd \
    --query "[?plan!=null].{Table:name, Plan:plan, Interactive:retentionInDays, Total:totalRetentionInDays}" \
    -o table
Table                      Plan       Interactive    Total
-------------------------  ---------  -------------  -------
AppRequests                Analytics  90             730
AppDependencies            Analytics  90             90
AppExceptions              Analytics  90             90
AppTraces                  Analytics  90             90
ContainerLogV2             Basic      30             365
KubeEvents                 Analytics  90             90
KubePodInventory           Analytics  90             90
Heartbeat                  Analytics  90             90
Perf                       Analytics  90             90
Syslog                     Analytics  90             90
AzureActivity              Analytics  90             90
CheckoutAudit_CL           Analytics  730            2555

$ az monitor log-analytics workspace table update \
    --resource-group rg-observability-checkout-prd \
    --workspace-name log-checkout-prd \
    --name AppDependencies \
    --plan Basic \
    --total-retention-time 365 \
    --query "{table:name, plan:plan}" -o jsonc
{
  "plan": "Basic",
  "table": "AppDependencies"
}
```

### 9.3 Data collection rules y sus asociaciones

```console
$ az monitor data-collection rule list \
    --resource-group rg-observability-checkout-prd \
    --query "[].{Name:name, Kind:kind, Endpoint:dataCollectionEndpointId!=null, Flows:length(dataFlows)}" -o table
Name                             Kind    Endpoint    Flows
-------------------------------  ------  ----------  -------
dcr-linux-host-checkout-prd      Linux   True        2
MSCI-westeurope-checkout-prd     Linux   False       2
dcr-audit-checkout-prd           Direct  True        1

$ az monitor data-collection rule association list \
    --resource /subscriptions/8f3a.../resourceGroups/rg-app-prd/providers/Microsoft.Compute/virtualMachines/vm-worker-01 \
    --query "[].{Association:name, Rule:dataCollectionRuleId}" -o table
Association                  Rule
---------------------------  --------------------------------------------------------------------------------
dcra-linux-host              /subscriptions/8f3a.../dataCollectionRules/dcr-linux-host-checkout-prd

$ az vm extension show \
    --resource-group rg-app-prd \
    --vm-name vm-worker-01 \
    --name AzureMonitorLinuxAgent \
    --query "{name:name, version:typeHandlerVersion, autoUpgrade:enableAutomaticUpgrade, state:provisioningState}" -o jsonc
{
  "autoUpgrade": true,
  "name": "AzureMonitorLinuxAgent",
  "provisioningState": "Succeeded",
  "state": "Succeeded",
  "version": "1.33"
}
```

### 9.4 Consultar logs desde la CLI

```console
$ WS=$(az monitor log-analytics workspace show -g rg-observability-checkout-prd \
        -n log-checkout-prd --query customerId -o tsv)

$ az monitor log-analytics query --workspace "$WS" --analytics-query '
Heartbeat
| where TimeGenerated > ago(30m)
| summarize LastSeen = max(TimeGenerated), Agent = any(Version) by Computer
| extend MinutesStale = datetime_diff("minute", now(), LastSeen)
| where MinutesStale > 5
| project Computer, Agent, LastSeen, MinutesStale
| order by MinutesStale desc
' -o table
Computer          Agent    LastSeen                       MinutesStale
----------------  -------  -----------------------------  --------------
vm-worker-07      1.33.0   2026-09-05T09:41:12.4130000Z   23
vm-worker-11      1.31.4   2026-09-05T09:47:03.9820000Z   17
arc-onprem-db02   1.29.5   2026-09-05T08:12:55.1010000Z   112

$ az monitor log-analytics query --workspace "$WS" --analytics-query '
Usage
| where TimeGenerated > ago(7d)
| where IsBillable == true
| summarize BillableGB = round(sum(Quantity) / 1000, 2) by DataType
| order by BillableGB desc
| take 10
' -o table
DataType             BillableGB
-------------------  ------------
ContainerLogV2       412.87
AppDependencies      188.34
AzureDiagnostics     97.51
AppTraces            64.02
Perf                 41.19
AppRequests          33.66
KubePodInventory     22.90
Syslog               14.75
KubeEvents           6.31
AzureActivity        1.08
```

### 9.5 Métricas desde la CLI

```console
$ az monitor metrics list-definitions \
    --resource /subscriptions/8f3a.../providers/Microsoft.Insights/components/appi-checkout-prd \
    --query "[?contains(name.value,'requests')].{Metric:name.value, Unit:unit, Aggs:join(',',supportedAggregationTypes)}" -o table
Metric                      Unit            Aggs
--------------------------  --------------  ----------------------------
requests/count              Count           None,Count
requests/duration           MilliSeconds    None,Average,Minimum,Maximum
requests/failed             Count           None,Count
requests/rate               CountPerSecond  None,Average

$ az monitor metrics list \
    --resource /subscriptions/8f3a.../providers/Microsoft.Insights/components/appi-checkout-prd \
    --metric "requests/duration" \
    --aggregation Average Maximum \
    --interval PT5M \
    --start-time 2026-09-05T08:00:00Z \
    --end-time   2026-09-05T09:00:00Z \
    --query "value[0].timeseries[0].data[].{Time:timeStamp, AvgMs:average, MaxMs:maximum}" -o table
Time                        AvgMs      MaxMs
--------------------------  ---------  ---------
2026-09-05T08:00:00Z        184.21     1102.40
2026-09-05T08:05:00Z        191.88     1340.77
2026-09-05T08:10:00Z        203.14      987.65
2026-09-05T08:15:00Z       1471.09    14882.31
2026-09-05T08:20:00Z       1688.53    18204.66
2026-09-05T08:25:00Z       1702.77    17993.02
2026-09-05T08:30:00Z        412.66     3011.90
2026-09-05T08:35:00Z        197.02     1188.44
```

### 9.6 Estado de las alertas

```console
$ az monitor metrics alert list \
    --resource-group rg-observability-checkout-prd \
    --query "[].{Name:name, Sev:severity, Enabled:enabled, Freq:evaluationFrequency, Window:windowSize}" -o table
Name                                       Sev    Enabled    Freq    Window
-----------------------------------------  -----  ---------  ------  --------
alert-checkout-prd-p95-latency             2      True       PT1M    PT5M
alert-checkout-prd-failed-requests-anomaly 1      True       PT5M    PT15M
alert-checkout-prd-availability            0      True       PT1M    PT5M

$ az monitor activity-log alert list \
    --query "[].{Name:name, Enabled:enabled, Category:condition.allOf[0].equals}" -o table
Name                                Enabled    Category
----------------------------------  ---------  ---------------
alert-service-health                True       ServiceHealth
alert-resource-health-unavailable   True       ResourceHealth
alert-advisor-high-impact           True       Recommendation
alert-destructive-network-op        True       Administrative

$ az rest --method get \
    --url "https://management.azure.com/subscriptions/8f3a.../providers/Microsoft.AlertsManagement/alerts?api-version=2019-03-01&timeRange=1d&alertState=New" \
    --query "value[].{Name:properties.essentials.alertRule, Sev:properties.essentials.severity, State:properties.essentials.monitorCondition, Fired:properties.essentials.startDateTime}" -o table
Name                                       Sev    State    Fired
-----------------------------------------  -----  -------  ----------------------------
alert-checkout-prd-p95-latency             Sev2   Fired    2026-09-05T08:18:44.1220000Z
alert-checkout-prd-failed-requests-anomaly Sev1   Fired    2026-09-05T08:21:10.6650000Z
alert-service-health                       Sev1   Fired    2026-09-05T08:16:02.0000000Z
```

### 9.7 Service Health y Resource Health desde la CLI

```console
$ az monitor activity-log list \
    --offset 24h \
    --query "[?category.value=='ServiceHealth'].{Service:properties.impactedServices, Type:properties.incidentType, Stage:properties.stage, Title:properties.title, Time:eventTimestamp}" \
    -o json | head -40
[
  {
    "Service": "[{\"ServiceName\":\"Application Gateway\",\"ImpactedRegions\":[{\"RegionName\":\"West Europe\"}]}]",
    "Stage": "Active",
    "Time": "2026-09-05T08:16:02.0000000Z",
    "Title": "Application Gateway - West Europe - Investigating",
    "Type": "Incident"
  }
]

$ az rest --method get \
    --url "https://management.azure.com/subscriptions/8f3a.../resourceGroups/rg-app-prd/providers/Microsoft.Compute/virtualMachines/vm-worker-07/providers/Microsoft.ResourceHealth/availabilityStatuses/current?api-version=2023-07-01-preview" \
    --query "properties.{Status:availabilityState, Summary:summary, Cause:reasonType, Since:occuredTime, Reported:reportedTime}" -o jsonc
{
  "Cause": "Unplanned",
  "Reported": "2026-09-05T09:52:07.8814523Z",
  "Since": "2026-09-05T09:38:44.0000000Z",
  "Status": "Unavailable",
  "Summary": "We're sorry, your virtual machine isn't available because of an unexpected host failure. Azure has begun the auto-recovery process."
}
```

### 9.8 Advisor desde la CLI

```console
$ az advisor recommendation list \
    --category HighAvailability \
    --query "[].{Impact:impact, Resource:impactedValue, Problem:shortDescription.problem}" -o table
Impact    Resource                 Problem
--------  -----------------------  ---------------------------------------------------------------
High      aks-checkout-prd-weu     Enable Autoscaling for your system node pool
High      psql-checkout-prd        Enable geo-redundant backup for the flexible server
Medium    st-checkout-artifacts    Use zone-redundant storage for critical data
Medium    vmss-worker-prd          Add instances to your Virtual Machine Scale Set

$ az advisor recommendation list --category Cost \
    --query "[].{Impact:impact, Resource:impactedValue, Savings:extendedProperties.savingsAmount, Currency:extendedProperties.savingsCurrency, Problem:shortDescription.problem}" -o table
Impact    Resource                 Savings    Currency    Problem
--------  -----------------------  ---------  ----------  -----------------------------------------
High      subscription             4127.64    EUR         Buy virtual machine reserved instances
Medium    vm-batch-04              218.90     EUR         Right-size or shut down underutilized VM
Medium    disk-orphan-091          64.22      EUR         Delete unattached Premium SSD disks
Low       pip-legacy-lb            11.06      EUR         Delete idle public IP addresses

$ az rest --method get \
    --url "https://management.azure.com/subscriptions/8f3a.../providers/Microsoft.Advisor/advisorScore?api-version=2023-01-01" \
    --query "value[].{Category:name, Score:properties.lastRefreshedScore.score, Potential:properties.lastRefreshedScore.potentialScoreIncrease}" -o table
Category            Score    Potential
------------------  -------  -----------
Advisor             71.40    28.60
Cost                88.12    11.88
HighAvailability    62.05    37.95
OperationalExcellence 79.33  20.67
Performance         84.77    15.23
Security            58.90    41.10
```

### 9.9 Managed Prometheus en el clúster

```console
$ kubectl get pods -n kube-system -l rsName=ama-metrics -o wide
NAME                           READY   STATUS    RESTARTS   AGE   IP             NODE
ama-metrics-6b7d9f4c88-2xq7k   2/2     Running   0          6d    10.244.3.117   aks-sys-31882043-vmss000001
ama-metrics-6b7d9f4c88-r4mzp   2/2     Running   0          6d    10.244.1.204   aks-sys-31882043-vmss000000

$ kubectl get ds -n kube-system ama-metrics-node ama-logs
NAME               DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   AGE
ama-metrics-node   9         9         9       9            9           6d
ama-logs           9         9         9       9            9           6d

$ kubectl exec -n kube-system ama-metrics-6b7d9f4c88-2xq7k -c prometheus-collector -- \
    curl -s http://localhost:9090/api/v1/targets | jq -r '
      .data.activeTargets[] | "\(.labels.job)\t\(.health)\t\(.lastError)"' | sort | uniq -c | sort -rn
     18 kubernetes-pods	up	
      9 node	up	
      2 kube-state-metrics	up	
      2 coredns	up	
      1 kube-apiserver	up	
      1 checkout-api	down	server returned HTTP status 503 Service Unavailable

$ kubectl logs -n kube-system ama-metrics-6b7d9f4c88-2xq7k -c prometheus-collector --tail=6
2026-09-05T09:55:12.104Z	info	Scrape config loaded: 6 jobs, 33 targets
2026-09-05T09:55:12.219Z	info	Remote write endpoint: https://amw-checkout-prd-xy4z.westeurope.prometheus.monitor.azure.com/dataCollectionRules/dcr-abc.../streams/Microsoft-PrometheusMetrics/api/v1/write
2026-09-05T09:55:42.881Z	info	remote_write: sent batch	series=48211	duration=182ms	status=200
2026-09-05T09:56:12.903Z	info	remote_write: sent batch	series=48355	duration=176ms	status=200
2026-09-05T09:56:22.117Z	warn	scrape_pool=checkout-api target=10.244.5.31:9090 msg="Scrape failed" err="server returned HTTP status 503 Service Unavailable"
2026-09-05T09:56:42.874Z	info	remote_write: sent batch	series=48190	duration=190ms	status=200
```

---

## 10. KQL para diagnóstico

### 10.1 Reconstrucción de la transacción extremo a extremo

```kusto
// Reconstruct the full call tree for the slowest checkout requests in the
// incident window, including every downstream dependency and exception.
let window = datetime(2026-09-05 08:15:00) .. datetime(2026-09-05 08:35:00);
let slowOps =
    AppRequests
    | where TimeGenerated between (window)
    | where AppRoleName == "checkout-api"
    | where Name == "POST /api/v2/orders"
    | where DurationMs > 5000
    | top 25 by DurationMs desc
    | project OperationId, RootDuration = DurationMs, ResultCode, ClientIP;
slowOps
| join kind=leftouter (
    AppDependencies
    | where TimeGenerated between (window)
    | project OperationId, DepTarget = Target, DepType = DependencyType,
              DepName = Name, DepMs = DurationMs, DepSuccess = Success
  ) on OperationId
| join kind=leftouter (
    AppExceptions
    | where TimeGenerated between (window)
    | summarize Exceptions = make_set(ExceptionType, 5) by OperationId
  ) on OperationId
| project OperationId, RootDuration, ResultCode, DepType, DepTarget, DepName,
          DepMs, DepSuccess, Exceptions
| order by RootDuration desc, DepMs desc
```

```
OperationId                       RootDuration  ResultCode  DepType     DepTarget                  DepName                    DepMs    DepSuccess  Exceptions
--------------------------------  ------------  ----------  ----------  -------------------------  -------------------------  -------  ----------  -----------------------------
a41f9c0b7e2d4f118a3c6e5b9d02f713  18204         502         SQL         psql-checkout-prd          SELECT orders.reserve      17886    false       ["Npgsql.NpgsqlException"]
a41f9c0b7e2d4f118a3c6e5b9d02f713  18204         502         HTTP        payments.internal          POST /v1/authorize            41    true        ["Npgsql.NpgsqlException"]
c8b2e5417a9d40f3b6c1d8e2f5a70941  17993         502         SQL         psql-checkout-prd          SELECT orders.reserve      17640    false       ["Npgsql.NpgsqlException"]
3e7d1a80f5c94b22ae6f0c9d4b81e625  14882         500         SQL         psql-checkout-prd          UPDATE inventory.hold      14522    false       ["Npgsql.NpgsqlException"]
```

Las filas de dependencias localizan el problema en PostgreSQL en ~15 segundos de tiempo de consulta. Eso es lo que significa concretamente «los logs responden la pregunta 3».

### 10.2 Tasas correctas bajo sampling

```kusto
// WRONG under sampling: count() ignores itemCount and undercounts by the
// sampling factor. RIGHT: sum(itemCount) reconstructs the true population.
AppRequests
| where TimeGenerated > ago(6h)
| where AppRoleName == "checkout-api"
| summarize
    SampledRows   = count(),
    TrueRequests  = sum(ItemCount),
    TrueFailures  = sumif(ItemCount, Success == false),
    SamplingRatio = round(todouble(count()) / todouble(sum(ItemCount)), 4)
    by bin(TimeGenerated, 15m)
| extend ErrorRatePct = round(100.0 * TrueFailures / TrueRequests, 3)
| order by TimeGenerated asc
```

```
TimeGenerated          SampledRows  TrueRequests  TrueFailures  SamplingRatio  ErrorRatePct
---------------------  -----------  ------------  ------------  -------------  ------------
2026-09-05 04:00:00    22140        22140         14            1.0000         0.063
2026-09-05 04:15:00    21987        21987         11            1.0000         0.050
2026-09-05 08:15:00     9812        188406        13977         0.0521         7.419
2026-09-05 08:30:00     9744        174022         9218         0.0560         5.297
2026-09-05 08:45:00    23110         23110           31         1.0000         0.134
```

Que `SamplingRatio` se desplome de 1.0 a 0.05 es el sampling adaptativo reaccionando a la carga — comportamiento esperado, y la razón por la que `count()` habría reportado una *caída* de tráfico durante un *pico* de tráfico.

### 10.3 Latencia de ingesta

```kusto
// ingestion_time() is a system function returning when the row landed in the
// workspace, as opposed to TimeGenerated (when the event happened).
// The delta is the true observability latency of your pipeline.
union withsource=SourceTable
    AppRequests, ContainerLogV2, Syslog, Perf, AzureActivity, Heartbeat
| where TimeGenerated > ago(2h)
| extend LatencySec = datetime_diff("second", ingestion_time(), TimeGenerated)
| summarize
    p50 = percentile(LatencySec, 50),
    p95 = percentile(LatencySec, 95),
    p99 = percentile(LatencySec, 99),
    max = max(LatencySec),
    rows = count()
    by SourceTable
| order by p95 desc
```

```
SourceTable       p50   p95    p99     max     rows
----------------  ----  -----  ------  ------  ---------
ContainerLogV2    94    412    1103    3877    18442190
Syslog            61    188     406    1244      882014
AzureActivity     58    170     311     622        4118
Perf              47    121     240     498     1204776
AppRequests       38     97     185     402     2210945
Heartbeat         31     72     140     288      129600
```

> Cualquier alerta de búsqueda en logs con un `evaluationFrequency` más corto que la latencia de ingesta p95 de su tabla de origen evaluará contra datos incompletos y producirá falsos negativos.

### 10.4 Atribución de costes

```kusto
// Bill the workspace back to the teams that fill it. Requires
// enrich_container_logs = true so PodNamespace is present.
ContainerLogV2
| where TimeGenerated > ago(7d)
| summarize
    Rows  = count(),
    Bytes = sum(estimate_data_size(LogMessage) + estimate_data_size(ContainerName))
    by PodNamespace
| extend GB = round(Bytes / 1024.0 / 1024.0 / 1024.0, 2)
| extend PctOfTotal = round(100.0 * GB / toscalar(
        ContainerLogV2
        | where TimeGenerated > ago(7d)
        | summarize sum(estimate_data_size(LogMessage)) / 1024.0 / 1024.0 / 1024.0), 1)
| project PodNamespace, Rows, GB, PctOfTotal
| order by GB desc
| take 10
```

```
PodNamespace     Rows        GB       PctOfTotal
---------------  ----------  -------  -----------
checkout         6218440     141.22   34.2
payments         4901112      98.77   23.9
orders           3117092      71.03   17.2
search           1884201      44.16   10.7
notifications     980417      22.90    5.5
identity          611330      18.04    4.4
istio-system      408119      11.67    2.8
```

### 10.5 Salud del workspace y datos descartados

```kusto
// _LogOperation surfaces workspace-level problems the portal does not
// prominently show: ingestion throttling, daily cap hits, invalid data.
_LogOperation
| where TimeGenerated > ago(7d)
| summarize Occurrences = count(), LastSeen = max(TimeGenerated), Sample = any(Detail)
    by Category, Operation, Level
| order by Occurrences desc
```

```
Category    Operation                Level    Occurrences  LastSeen                 Sample
----------  -----------------------  -------  -----------  -----------------------  -----------------------------------------------------
Ingestion   Data collection          Warning  412          2026-09-05 02:51:33      Data collection stopped due to daily limit of 50 GB
Ingestion   Ingestion rate           Warning  88           2026-09-04 21:14:02      Ingestion rate exceeded 6 GB/min; data was throttled
Solution    Data collection          Error    12           2026-09-03 11:07:41      Invalid custom log format for stream Custom-CheckoutAudit
```

La primera fila es el incidente de §1.1: el workspace dejó de ingerir a las 02:51 por el tope diario, así que la caída de las 03:14 no tiene logs. `_LogOperation` lo habría dicho en cinco segundos.

---

## 11. Manual de verificación y diagnóstico de fallos

### 11.1 La escalera de verificación — ejecutala en este orden

| Peldaño | Pregunta | Comando / consulta | Condición de aprobado |
|---|---|---|---|
| 0 | ¿Existe el recurso? | `az resource show --ids <id>` | `provisioningState: Succeeded` |
| 1 | ¿Hay telemetría configurada siquiera? | `az monitor diagnostic-settings list --resource <id>` | Al menos un setting, con el destino correcto |
| 2 | ¿Está vivo el agente? | `Heartbeat \| where Computer == "x" \| top 1 by TimeGenerated` | Fila dentro de los últimos 5 minutos |
| 3 | ¿Tiene el agente *trabajo asignado*? | `az monitor data-collection rule association list --resource <id>` | Al menos una asociación |
| 4 | ¿Están llegando datos? | `<Table> \| where TimeGenerated > ago(15m) \| count` | Distinto de cero |
| 5 | ¿Está ingiriendo el workspace? | `_LogOperation \| where Level != "Info"` | Sin filas de `daily limit` / `throttled` |
| 6 | ¿Se está evaluando la regla de alerta? | Portal → regla → **History**, o `az monitor scheduled-query show` | Evaluaciones recientes, sin `Failed` |
| 7 | ¿Es alcanzable el action group? | Portal → action group → **Test**, o revisar `AlertHistory` | Entrega `Succeeded` |

Diagnosticar de arriba abajo es un error: «la alerta no se disparó» es el peldaño 6, pero la causa está casi siempre en el peldaño 3 o el 5.

### 11.2 Catálogo de modos de fallo

#### FM-1 — El diagnostic setting existe, la tabla está vacía

**Síntoma:** `az monitor diagnostic-settings list` muestra un setting; la tabla de KQL devuelve 0 filas.

**Causas, por orden de frecuencia:**

1. **Categoría habilitada pero el recurso no emite nada.** Muchas categorías solo producen filas cuando hay actividad. Un Application Gateway sin tráfico no escribe `AGWAccessLogs`.
2. **Desajuste de `logAnalyticsDestinationType`.** Con `Dedicated` las filas van a `AGWAccessLogs`; sin él, a `AzureDiagnostics`. Consultá ambas:
   ```kusto
   union isfuzzy=true AzureDiagnostics, AGWAccessLogs
   | where TimeGenerated > ago(1h)
   | summarize count() by $table, Category = column_ifexists("Category", "n/a")
   ```
3. **Workspace equivocado.** Dos workspaces con nombres parecidos; el setting apunta al otro.
   ```console
   $ az monitor diagnostic-settings list --resource "$RID" \
       --query "value[].{Setting:name, Workspace:workspaceId}" -o table
   ```
4. **Latencia de primera escritura.** Una categoría recién creada puede tardar hasta ~15 minutos en aparecer, y la tabla en sí no existe en el esquema hasta que llega la primera fila — una consulta contra una tabla nunca poblada falla con `Failed to resolve table or column expression`, que *no* es lo mismo que devolver cero filas. Usá `union isfuzzy=true` para distinguirlo.

#### FM-2 — Heartbeat de AMA presente, sin datos de Perf/Syslog

Este es el fallo de asociación de DCR, y es el problema más común de AMA porque el agente parece perfectamente sano.

```console
$ az monitor data-collection rule association list --resource "$VMID" -o table
# Empty output → the agent has no instructions. It will heartbeat forever.

$ az monitor data-collection rule association create \
    --name dcra-linux-host \
    --rule-id /subscriptions/8f3a.../dataCollectionRules/dcr-linux-host-checkout-prd \
    --resource "$VMID" \
    --query "{name:name, state:provisioningState}" -o jsonc
{
  "name": "dcra-linux-host",
  "state": "Succeeded"
}
```

En la propia VM:

```console
$ sudo systemctl status azuremonitoragent --no-pager
● azuremonitoragent.service - Azure Monitor Agent
     Loaded: loaded (/lib/systemd/system/azuremonitoragent.service; enabled)
     Active: active (running) since Sat 2026-08-30 04:12:07 UTC; 6 days ago
   Main PID: 1187 (agentlauncher)
      Tasks: 62 (limit: 19093)
     Memory: 214.8M

$ sudo tail -n 8 /var/opt/microsoft/azuremonitoragent/log/mdsd.err
2026-09-05T09:12:44.1821Z ERR  Failed to fetch configuration from
  https://global.handler.control.monitor.azure.com/agentConfigurations
  : Connection timed out after 30000 ms
2026-09-05T09:13:14.9903Z WARN Retrying config fetch (attempt 4/10)

$ curl -sS -o /dev/null -w '%{http_code}\n' \
    https://global.handler.control.monitor.azure.com/ping
000
```

**Causa raíz:** firewall de salida / NSG / UDR bloqueando los endpoints de control e ingesta de AMA. FQDNs de salida requeridos:

| Propósito | Patrón de FQDN | Puerto |
|---|---|---|
| Configuración del agente (control) | `global.handler.control.monitor.azure.com`, `<region>.handler.control.monitor.azure.com` | 443 |
| Ingesta de logs | `<workspace-id>.ods.opinsights.azure.com` | 443 |
| Ingesta del DCE | `<dce>-<hash>.<region>.ingest.monitor.azure.com` | 443 |
| Entra ID (token de identidad gestionada) | `login.microsoftonline.com` | 443 |
| Ingesta de métricas | `<region>.monitoring.azure.com` | 443 |

Dos requisitos adicionales que fallan en silencio: la VM debe tener una **identidad gestionada** (asignada por el sistema o por el usuario), y el transporte debe negociar **TLS 1.2 o superior**.

#### FM-3 — Telemetría de Application Insights ausente o adelgazada

Árbol de decisión:

```
No telemetry at all?
├── Connection string set?                        → check APPLICATIONINSIGHTS_CONNECTION_STRING
│   └── Using only an instrumentation key?        → ikey ingestion retired 2025-03-31. Migrate.
├── Egress to <region>.in.applicationinsights.azure.com allowed on 443?
├── DisableLocalAuth = true and no Entra token?   → MonitoringMetricsPublisher role required
└── Daily cap hit?                                → check below

Some telemetry, incomplete traces?
├── Adaptive sampling engaged?                    → sum(itemCount), check SamplingRatio
├── traceparent stripped by a proxy/gateway?      → orphan operation_Id fragments
└── Queue/async hop losing context?               → manual context propagation needed
```

```console
$ az monitor app-insights component show \
    -g rg-observability-checkout-prd -a appi-checkout-prd \
    --query "{ingestion:IngestionMode, workspace:WorkspaceResourceId, sampling:SamplingPercentage, localAuth:DisableLocalAuth}" -o jsonc
{
  "ingestion": "LogAnalytics",
  "localAuth": true,
  "sampling": 100.0,
  "workspace": "/subscriptions/8f3a.../workspaces/log-checkout-prd"
}

$ az monitor app-insights component billing show \
    -g rg-observability-checkout-prd -a appi-checkout-prd -o jsonc
{
  "currentBillingFeatures": [ "Basic" ],
  "dataVolumeCap": {
    "cap": 30.0,
    "maxHistoryCap": 100.0,
    "resetTime": 24,
    "stopSendNotificationWhenHitCap": true,
    "warningThreshold": 90
  }
}
```

> `dataVolumeCap.cap: 30.0` en un componente basado en workspace es un tope diario por componente **además del** tope del workspace. Alcanzar cualquiera de los dos detiene la ingesta. Dos topes independientes, dos formas independientes de perder los datos de tu incidente.

Verificá el sampling en efecto ahora mismo:

```kusto
AppRequests
| where TimeGenerated > ago(1h)
| summarize Retained = count(), Actual = sum(ItemCount)
| extend EffectiveSamplingPct = round(100.0 * Retained / Actual, 2)
```

#### FM-4 — La alerta de búsqueda en logs nunca se dispara

| Comprobación | Cómo | Por qué falla |
|---|---|---|
| La consulta devuelve filas siquiera | Ejecutala en Logs con exactamente el `windowSize` como rango temporal | La consulta está bien, la ventana es demasiado corta para la latencia de ingesta |
| Conflicto de filtro temporal | Quitá cualquier `ago()` dentro de la consulta | La regla aplica `windowSize` *y* tu `ago()`; la intersección puede quedar vacía |
| `resourceIdColumn` presente | `| project _ResourceId, ...` debe sobrevivir al summarize | Sin `_ResourceId` la alerta no puede acotar, y la división por dimensiones no devuelve nada en silencio |
| Dirección del umbral | `operator: GreaterThan`, `threshold: 0` | `GreaterThanOrEqual 0` se dispara permanentemente |
| `failingPeriods` | `minFailingPeriodsToAlert` ≤ `numberOfEvaluationPeriods` | Mal configurado, nunca puede satisfacerse |
| Salud de la regla | Portal → regla → pestaña **History** | Los fallos de coste/timeout de consulta aparecen ahí y en ningún otro sitio |
| Alert processing rule | `az rest` sobre `Microsoft.AlertsManagement/actionRules` | Una ventana de supresión olvidada la está silenciando |

```console
$ az monitor scheduled-query show \
    -g rg-observability-checkout-prd -n alert-checkout-prd-pod-crashloop \
    --query "{enabled:enabled, freq:evaluationFrequency, window:windowSize, autoMitigate:autoMitigate, actions:actions.actionGroups}" -o jsonc
{
  "actions": [
    "/subscriptions/8f3a.../actionGroups/ag-checkout-prd-ticket"
  ],
  "autoMitigate": true,
  "enabled": true,
  "freq": "PT5M",
  "window": "PT15M"
}
```

#### FM-5 — La alerta se dispara, no se notifica a nadie

```console
$ az monitor action-group test-notifications create \
    --action-group-name ag-checkout-prd-page \
    --resource-group rg-observability-checkout-prd \
    --alert-type servicehealth \
    --notification-type Email Name=sre-oncall-email EmailAddress=sre-oncall@example.com \
    -o jsonc
{
  "actionDetails": [
    {
      "MechanismType": "Email",
      "Name": "sre-oncall-email",
      "SendTime": "2026-09-05T10:04:11.7729Z",
      "Status": "Succeeded"
    }
  ],
  "completedTime": "2026-09-05T10:04:14.1102Z",
  "context": { "notificationSource": "Microsoft.Insights/TestNotification" }
}
```

Causas de fallo, ordenadas: webhook devolviendo un no-2xx (reintentado y luego descartado); límite de tasa de email superado (>100/h a una dirección); filtrado del operador de SMS; el receptor de la app móvil de Azure vinculado a un usuario de Entra que ya no está; una alert processing rule con `RemoveAllActionGroups` todavía en efecto tras una ventana de mantenimiento.

#### FM-6 — Falta un target de Managed Prometheus

```console
$ kubectl get configmap ama-metrics-settings-configmap -n kube-system -o yaml | \
    grep -A2 'podannotationnamespaceregex'
    podannotationnamespaceregex = "checkout|payments|orders"

$ kubectl port-forward -n kube-system ama-metrics-6b7d9f4c88-2xq7k 9090:9090 >/dev/null 2>&1 &
$ curl -s localhost:9090/api/v1/targets | jq -r '
    .data.droppedTargets[]? | .discoveredLabels["__meta_kubernetes_pod_name"]' | head
checkout-worker-7d9b4f6c5-hkq22
checkout-worker-7d9b4f6c5-p2v8n
```

Causas ordenadas: (1) la métrica queda filtrada por la regex de `default-targets-metrics-keep-list`; (2) el namespace del pod no está en `podannotationnamespaceregex`; (3) el CR `PodMonitor` se creó en el namespace de la carga de trabajo en lugar de `kube-system`; (4) la identidad del clúster AKS carece de **Monitoring Metrics Publisher** sobre la DCR del Azure Monitor workspace — el remote-write devuelve entonces 403 y el collector lo registra una vez por lote.

#### FM-7 — Pico de coste de ingesta

```kusto
// Week-over-week volume delta per table, to find what changed.
let thisWeek = Usage | where TimeGenerated between (ago(7d) .. now())
    | where IsBillable | summarize GB_now = sum(Quantity)/1000 by DataType;
let lastWeek = Usage | where TimeGenerated between (ago(14d) .. ago(7d))
    | where IsBillable | summarize GB_prev = sum(Quantity)/1000 by DataType;
thisWeek
| join kind=fullouter lastWeek on DataType
| extend DataType = coalesce(DataType, DataType1)
| extend GB_now = coalesce(GB_now, 0.0), GB_prev = coalesce(GB_prev, 0.0)
| extend DeltaGB = round(GB_now - GB_prev, 2),
         DeltaPct = iff(GB_prev == 0, 999.0, round(100.0*(GB_now-GB_prev)/GB_prev, 1))
| where abs(DeltaGB) > 1
| project DataType, GB_prev = round(GB_prev,2), GB_now = round(GB_now,2), DeltaGB, DeltaPct
| order by DeltaGB desc
```

```
DataType          GB_prev   GB_now    DeltaGB   DeltaPct
----------------  --------  --------  --------  ---------
AppDependencies    41.20     188.34    147.14     357.1
ContainerLogV2    398.11     412.87     14.76       3.7
AzureDiagnostics   62.04      97.51     35.47      57.2
Perf               40.88      41.19      0.31       0.8
```

Un salto del 357% en `AppDependencies` en una semana es un deploy que activó el seguimiento verboso de dependencias, o un bucle de reintentos. Mitigaciones por orden de preferencia: **filtro `transformKql` en la DCR** (gratis, descarta antes de facturar) → **cambio de plan de tabla a Basic** → **sampling en el SDK** → **tope diario** (último recurso: descarta *todo*, incluida la telemetría que necesitás).

### 11.3 Palancas de control de coste, ordenadas

| Palanca | ¿Reduce la ingesta? | ¿Pierde datos? | Esfuerzo | Notas |
|---|---|---|---|---|
| Filtro `transformKql` en la DCR | ✅ Antes de facturar | Solo lo que filtraste | Bajo | La mejor relación del producto |
| `exclude_namespaces` de Container Insights | ✅ | El stdout de ese namespace | Bajo | Matá primero el ruido de `kube-system` |
| Keep-lists de Managed Prometheus | ✅ | Las series no listadas | Bajo | La cardinalidad es el verdadero impulsor del coste |
| `kube-audit` apagado, `kube-audit-admin` encendido | ✅ Masivamente | Las operaciones de lectura en el rastro de auditoría | Bajo | Suele ser el mayor log de AKS |
| Plan de tabla → Basic | ✅ ~75% del coste de ingesta | Alerting + KQL completo en esa tabla | Medio | Auditá las reglas de alerta primero |
| Plan de tabla → Auxiliary | ✅ ~98% | Alerting, joins, rendimiento | Medio | Solo archivos de cumplimiento |
| Sampling en el SDK | ✅ | Elementos individuales (las tasas siguen siendo correctas vía `itemCount`) | Medio | El adaptativo está activado por defecto en .NET |
| Commitment tier | ❌ | ❌ | Bajo | Descuento puro por encima de ~100 GB/día |
| Diagnostic setting → Storage en lugar de LAW | ✅ | Capacidad de consulta | Bajo | Datos solo de cumplimiento |
| Tope diario | ✅ | **Todo lo posterior al tope** | Bajo | Red de seguridad, nunca una estrategia |

---

## 12. Superficies de visualización

| Superficie | Fuentes de datos | Compartición / RBAC | Parametrización | Mejor para |
|---|---|---|---|---|
| **Metrics Explorer** | Solo métricas | RBAC del portal | Mínima | Investigación ad hoc de métricas |
| **Vista de consulta de Log Analytics** | Logs | RBAC de workspace/recurso | Ninguna | KQL ad hoc |
| **Azure Dashboard** | Métricas, logs, tiles de recursos | Compartido como recurso ARM | Ninguna | Pantalla NOC de vistazo |
| **Workbook** | Logs, métricas, ARG, Alerts, endpoints custom | Recurso ARM, RBAC | ✅ Parámetros ricos, secciones condicionales, pestañas | Runbook-como-documento, informes de coste, informes multifuente |
| **Azure Managed Grafana** | Azure Monitor, Managed Prometheus, fuentes fuera de Azure | RBAC de Grafana + Entra | ✅ Variables de plantilla | Dashboards SRE de Kubernetes, multinube |
| **Power BI** | Exportación de Log Analytics | Licenciamiento de Power BI | ✅ | Informes ejecutivos/de negocio |

La división práctica: **Grafana para operaciones en tiempo real** (PromQL, por clúster, por pod, refrescado cada 30 s), **Workbooks para cualquier cosa que combine logs, métricas y Azure Resource Graph** (Grafana no puede unir fácilmente `AppRequests` con un join de KQL y con una consulta de ARG), **Dashboards para la pantalla de pared**.

---

## 13. Resumen comparativo de toda la cadena de herramientas

| Herramienta | Responde | Alcance | Horizonte de datos | Coste | Configuración requerida |
|---|---|---|---|---|---|
| **Azure Status** | ¿Está roto Azure, globalmente? | Público | En vivo + reciente | Gratis | Ninguna |
| **Service Health** | ¿Me afecta el incidente? | Suscripción | Ventana de historial de eventos | Gratis | Regla de alerta para ser notificado |
| **Resource Health** | ¿Está sano *este* recurso? | Recurso | 30 días | Gratis | Regla de alerta para ser notificado |
| **Azure Advisor** | ¿Estoy mal configurado? | Sub / RG / recurso | Móvil (utilización de 7–60 días) | Gratis | Ninguna; alertas opcionales |
| **Azure Monitor Metrics** | ¿Hay un número fuera de rango? | Recurso | 93 días | Métricas de plataforma gratis | Ninguna para métricas de plataforma |
| **Log Analytics** | ¿Qué pasó exactamente? | Workspace | 30 d → 12 a | Por GB + retención | Diagnostic settings, DCRs |
| **Application Insights** | ¿Qué petición, qué dependencia, qué excepción? | Aplicación | Según la retención del workspace | Por GB (vía workspace) | SDK / OTel / autoinstrumentación |
| **Managed Prometheus** | SLIs de Kubernetes/carga de trabajo en PromQL | Azure Monitor workspace | 18 meses | Por muestra + consultas | Add-on de AKS + ConfigMaps/CRDs |
| **Alertas de Azure Monitor** | Avisame cuándo | Cualquiera de las anteriores | — | Por regla / por serie temporal | Reglas + action groups |
| **Managed Grafana** | Mostrame | Multifuente | — | Por instancia | Data source + dashboards |

### Guía de decisión

```
Need to know about an Azure platform problem?
├── Affects everyone, no sign-in?                → Azure Status
├── Affects my subscription's services/regions?  → Service Health  (+ Activity Log alert)
└── Affects one specific resource I own?         → Resource Health (+ Activity Log alert)

Need to know about MY workload?
├── A number crossing a threshold, fast?         → Metric alert
│   └── Threshold varies by time of day?         → Dynamic threshold
├── Kubernetes workload SLI in PromQL?           → Managed Prometheus + prometheusRuleGroups
├── A text pattern / cross-table correlation?    → Log search alert (accept ingestion latency)
├── Which request failed and why?                → Application Insights transaction search
└── Is the site reachable from outside?          → Standard availability test + webtest alert

Need to know what I should improve?
└── Azure Advisor  (Reliability / Security / Performance / Cost / Operational Excellence)
```

---

## 14. Correspondencia con el examen AZ-900

| Enunciado del examen | Respuesta de una línea para memorizar |
|---|---|
| Propósito de **Azure Advisor** | Recomendaciones gratuitas y personalizadas en **Reliability, Security, Performance, Cost, Operational Excellence**, basadas en el Well-Architected Framework. |
| Propósito de **Azure Service Health** | Vista personalizada de la salud de **los servicios y regiones de Azure que usás** — incidencias de servicio, mantenimiento planificado, avisos de salud, avisos de seguridad. Alertable vía Activity Log. |
| **Azure Status** frente a Service Health frente a Resource Health | Status = público/global. Service Health = tu suscripción. Resource Health = un recurso concreto. |
| Propósito de **Azure Monitor** | La plataforma full-stack que **recopila, analiza y actúa sobre telemetría** de Azure, otras nubes y on-premises. |
| **Log Analytics** | La herramienta/workspace para **escribir y ejecutar consultas KQL sobre datos de logs**. |
| **Alertas de Azure Monitor** | Notificación/automatización proactiva cuando se cumple una condición; la entrega va vía **action groups**. |
| **Application Insights** | La funcionalidad de **APM** de Azure Monitor: disponibilidad, rendimiento, fallos y uso de una aplicación web en vivo. |
| ¿Se recopilan los logs por defecto? | **No.** Las métricas de plataforma y el Activity Log están activados por defecto; los resource logs, los datos del SO invitado y la telemetría de aplicación requieren configuración explícita. |
| ¿Dónde almacena los datos Application Insights? | En un **Log Analytics workspace** (basado en workspace; el clásico se retiró el 2024-02-29). |

---

## 15. Referencias

**Examen y certificación**
- Guía de estudio de AZ-900: https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900
- Microsoft Certified: Azure Fundamentals: https://learn.microsoft.com/en-us/credentials/certifications/azure-fundamentals/

**Azure Monitor — plataforma**
- Visión general de Azure Monitor: https://learn.microsoft.com/en-us/azure/azure-monitor/overview
- Plataforma de datos (métricas, logs, trazas, cambios): https://learn.microsoft.com/en-us/azure/azure-monitor/data-platform
- Fuentes de datos de monitorización: https://learn.microsoft.com/en-us/azure/azure-monitor/data-sources
- Buenas prácticas para Azure Monitor: https://learn.microsoft.com/en-us/azure/azure-monitor/best-practices
- Optimización de costes y Azure Monitor: https://learn.microsoft.com/en-us/azure/azure-monitor/best-practices-cost
- Límites de servicio de Azure Monitor: https://learn.microsoft.com/en-us/azure/azure-monitor/service-limits

**Logs y Log Analytics**
- Visión general del Log Analytics workspace: https://learn.microsoft.com/en-us/azure/azure-monitor/logs/log-analytics-workspace-overview
- Diseñar una arquitectura de Log Analytics workspace: https://learn.microsoft.com/en-us/azure/azure-monitor/logs/workspace-design
- Planes de tabla (Analytics, Basic, Auxiliary): https://learn.microsoft.com/en-us/azure/azure-monitor/logs/data-platform-logs
- Gestionar la retención de datos: https://learn.microsoft.com/en-us/azure/azure-monitor/logs/data-retention-configure
- Gestionar los planes de tabla: https://learn.microsoft.com/en-us/azure/azure-monitor/logs/logs-table-plans
- Establecer el tope diario: https://learn.microsoft.com/en-us/azure/azure-monitor/logs/daily-cap
- Analizar el uso en un Log Analytics workspace: https://learn.microsoft.com/en-us/azure/azure-monitor/logs/analyze-usage
- Salud del Log Analytics workspace / `_LogOperation`: https://learn.microsoft.com/en-us/azure/azure-monitor/logs/monitor-workspace
- Tiempo de ingesta de datos: https://learn.microsoft.com/en-us/azure/azure-monitor/logs/data-ingestion-time
- Gestionar el acceso a los datos de logs: https://learn.microsoft.com/en-us/azure/azure-monitor/logs/manage-access

**KQL**
- Visión general del Kusto Query Language: https://learn.microsoft.com/en-us/kusto/query/
- Consultas de logs en Azure Monitor: https://learn.microsoft.com/en-us/azure/azure-monitor/logs/log-query-overview
- Referencia de tablas de Azure Monitor Logs: https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables-index

**Métricas**
- Visión general de Azure Monitor Metrics: https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/data-platform-metrics
- Referencia de métricas soportadas: https://learn.microsoft.com/en-us/azure/azure-monitor/reference/supported-metrics/metrics-index
- Metrics Explorer: https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/analyze-metrics

**Diagnostic settings, Activity Log, DCRs**
- Diagnostic settings: https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/diagnostic-settings
- Resource logs de Azure Monitor: https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/resource-logs
- Azure Activity Log: https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/activity-log
- Visión general de las data collection rules: https://learn.microsoft.com/en-us/azure/azure-monitor/data-collection/data-collection-rule-overview
- Estructura de una data collection rule: https://learn.microsoft.com/en-us/azure/azure-monitor/data-collection/data-collection-rule-structure
- Transformaciones de recopilación de datos: https://learn.microsoft.com/en-us/azure/azure-monitor/data-collection/data-collection-transformations
- Data collection endpoints: https://learn.microsoft.com/en-us/azure/azure-monitor/data-collection/data-collection-endpoint-overview
- Logs Ingestion API: https://learn.microsoft.com/en-us/azure/azure-monitor/logs/logs-ingestion-api-overview

**Azure Monitor Agent**
- Visión general del Azure Monitor Agent: https://learn.microsoft.com/en-us/azure/azure-monitor/agents/azure-monitor-agent-overview
- Migrar desde el agente de Log Analytics: https://learn.microsoft.com/en-us/azure/azure-monitor/agents/azure-monitor-agent-migration
- Configuración de red y endpoints de AMA: https://learn.microsoft.com/en-us/azure/azure-monitor/agents/azure-monitor-agent-network-configuration
- Solucionar problemas del Azure Monitor Agent en Linux: https://learn.microsoft.com/en-us/azure/azure-monitor/agents/azure-monitor-agent-troubleshoot-linux-vm

**Application Insights**
- Visión general de Application Insights: https://learn.microsoft.com/en-us/azure/azure-monitor/app/app-insights-overview
- Application Insights basado en workspace: https://learn.microsoft.com/en-us/azure/azure-monitor/app/create-workspace-resource
- Connection strings: https://learn.microsoft.com/en-us/azure/azure-monitor/app/connection-strings
- Sampling de telemetría: https://learn.microsoft.com/en-us/azure/azure-monitor/app/sampling
- Correlación de telemetría: https://learn.microsoft.com/en-us/azure/azure-monitor/app/distributed-trace-data
- Azure Monitor OpenTelemetry Distro: https://learn.microsoft.com/en-us/azure/azure-monitor/app/opentelemetry-enable
- Application Map: https://learn.microsoft.com/en-us/azure/azure-monitor/app/app-map
- Live Metrics: https://learn.microsoft.com/en-us/azure/azure-monitor/app/live-stream
- Availability tests: https://learn.microsoft.com/en-us/azure/azure-monitor/app/availability
- Modelo de datos de Application Insights: https://learn.microsoft.com/en-us/azure/azure-monitor/app/data-model-complete

**Alertas**
- Visión general de las alertas de Azure Monitor: https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-overview
- Metric alerts: https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-types
- Umbrales dinámicos: https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-dynamic-thresholds
- Alertas de búsqueda en logs: https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-create-log-alert-rule
- Activity Log alerts: https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-activity-log
- Action groups: https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/action-groups
- Alert processing rules: https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-processing-rules
- Common alert schema: https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-common-schema
- Solucionar problemas de reglas de alerta de búsqueda en logs: https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-troubleshoot-log
- Azure Monitor Baseline Alerts (AMBA): https://azure.github.io/azure-monitor-baseline-alerts/

**Contenedores y Prometheus**
- Visión general de Container insights: https://learn.microsoft.com/en-us/azure/azure-monitor/containers/container-insights-overview
- Configurar la recopilación de datos del agente de Container insights: https://learn.microsoft.com/en-us/azure/azure-monitor/containers/container-insights-data-collection-configmap
- Esquema de logs de Container insights (ContainerLogV2): https://learn.microsoft.com/en-us/azure/azure-monitor/containers/container-insights-logs-schema
- Azure Monitor managed service for Prometheus: https://learn.microsoft.com/en-us/azure/azure-monitor/metrics/prometheus-metrics-overview
- Personalizar el scraping de métricas de Prometheus: https://learn.microsoft.com/en-us/azure/azure-monitor/metrics/prometheus-metrics-scrape-configuration
- Alertas y rule groups de Prometheus: https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/prometheus-alerts
- Azure Monitor workspace: https://learn.microsoft.com/en-us/azure/azure-monitor/metrics/azure-monitor-workspace-overview

**Advisor**
- Visión general de Azure Advisor: https://learn.microsoft.com/en-us/azure/advisor/advisor-overview
- Advisor Score: https://learn.microsoft.com/en-us/azure/advisor/azure-advisor-score
- Recomendaciones de fiabilidad: https://learn.microsoft.com/en-us/azure/advisor/advisor-reference-reliability-recommendations
- Recomendaciones de coste: https://learn.microsoft.com/en-us/azure/advisor/advisor-reference-cost-recommendations
- Alertas sobre recomendaciones de Advisor: https://learn.microsoft.com/en-us/azure/advisor/advisor-alerts-portal

**Service Health y Resource Health**
- Visión general de Azure Service Health: https://learn.microsoft.com/en-us/azure/service-health/overview
- Experiencia de Service Health en el portal: https://learn.microsoft.com/en-us/azure/service-health/service-health-overview
- Crear alertas de Service Health: https://learn.microsoft.com/en-us/azure/service-health/alerts-activity-log-service-notifications-portal
- Visión general de Resource Health: https://learn.microsoft.com/en-us/azure/service-health/resource-health-overview
- Tipos de recurso y comprobaciones de salud: https://learn.microsoft.com/en-us/azure/service-health/resource-health-checks-resource-types
- Azure Status: https://azure.status.microsoft/en-us/status

**Visualización**
- Azure Workbooks: https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-overview
- Azure Managed Grafana: https://learn.microsoft.com/en-us/azure/managed-grafana/overview
- Visualizar datos en Azure Monitor: https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/visualize-overview

**Referencia y herramientas**
- Referencia de recursos Bicep — `Microsoft.Insights`: https://learn.microsoft.com/en-us/azure/templates/microsoft.insights/
- Referencia de recursos Bicep — `Microsoft.OperationalInsights/workspaces`: https://learn.microsoft.com/en-us/azure/templates/microsoft.operationalinsights/workspaces
- Referencia de la CLI `az monitor`: https://learn.microsoft.com/en-us/cli/azure/monitor
- Proveedor AzureRM de Terraform — recursos de monitor: https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs
- Precios de Azure Monitor: https://azure.microsoft.com/en-us/pricing/details/monitor/
- Well-Architected Framework — Operational Excellence: https://learn.microsoft.com/en-us/azure/well-architected/operational-excellence/