# 1.1 — Describir la computación en la nube

**Certificación:** AZ-900 (Microsoft Azure Fundamentals), versión del examen 2026-07-20
**Dominio:** Describir conceptos de nube (25–30 % del examen) · **Peso del tema: 9.4**
**Perfil de audiencia:** Platform Architect / SRE. Este módulo trata los fundamentos como *contratos operativos*, no como vocabulario.

---

## 1. El problema de producción que este tema resuelve realmente

El material de fundamentos suele abrir con "la computación en la nube es alquilar las computadoras de otro". Ese encuadre es inútil la primera vez que estás de guardia. Este es el encuadre que sobrevive a un postmortem.

Considerá la forma de un incidente real de plataforma. Operás una API de pagos. Es un sistema de tres capas: Azure Front Door → App Service (Linux, P1v3, 3 instancias) → Azure SQL Database (Business Critical). A las 02:14 UTC, la tasa de error llega al 100 % en una región. Te llega la página. Encontrás:

1. El **data plane** está bien — las instancias de App Service están sanas, SQL acepta conexiones.
2. El **control plane** está degradado — tus reglas de autoscale no pueden agregar instancias, tu pipeline de Terraform devuelve HTTP 429, y la hoja del portal gira eternamente.
3. Tu **puente de incidente** pregunta: "¿Esto es nuestro o de Microsoft?"

Esa última pregunta es todo el contenido de este tema. Responderla correctamente, a las 02:14, bajo carga, exige haber internalizado cuatro cosas mucho antes de la página:

| Pregunta a las 02:14 | El concepto fundamental que la responde |
|---|---|
| "¿De quién es la culpa en esta capa?" | **Modelo de responsabilidad compartida** |
| "¿Puedo hacer failover a on-prem / a otra región / a otro proveedor?" | **Modelos de despliegue de nube** (pública / privada / híbrida / multicloud) |
| "La mitigación es escalar 10×. ¿Cuánto cuesta y quién lo aprueba?" | **Modelo basado en consumo** |
| "¿Esta capa debería haber sido serverless para autorrepararse?" | **Serverless** y su mecánica de escalado |

Debajo hay un segundo problema de producción, más silencioso: **el riesgo no se transfiere junto con la responsabilidad.** Cuando Microsoft se hace cargo del parcheo del hipervisor, se hace cargo de la *tarea operativa*. Tus clientes te siguen paginando *a vos* cuando falla, y tu error budget se sigue consumiendo. El modelo de responsabilidad compartida es un límite contractual, no un límite de riesgo. Los ingenieros que confunden ambas cosas construyen plataformas sin controles compensatorios en las capas que "no les pertenecen".

Todo lo que sigue está construido para volver mecánicas esas cuatro respuestas.

---

## 2. Qué es "computación en la nube", formalmente

### 2.1 La definición que quiere el examen

> **La computación en la nube es la entrega de servicios de computación a través de internet — incluyendo cómputo, almacenamiento, bases de datos, redes, software, análisis e inteligencia — sobre una base de pago por uso.**

Esa es la respuesta de AZ-900. Memorizala. Ahora, esta es la definición que usa un arquitecto.

### 2.2 NIST SP 800-145 — las cinco características esenciales, mapeadas a primitivas de Azure

La definición de Microsoft es una simplificación de marketing de NIST SP 800-145, que sigue siendo el estándar portante. Un servicio es *nube* solo si tiene **las cinco**:

| Característica NIST | Qué significa mecánicamente | Implementación en Azure | Cómo se comprueba (§10) |
|---|---|---|---|
| **Autoservicio bajo demanda** | Un consumidor puede aprovisionar capacidad unilateralmente, sin interacción humana con el proveedor | Azure Resource Manager (ARM) REST API en `management.azure.com`; sin ticket, sin un empleado de Microsoft en el camino | `az group create` completa en segundos |
| **Acceso amplio por red** | Capacidades disponibles por red mediante mecanismos estándar | Control plane HTTPS/TLS; data planes sobre protocolos estándar; Private Link para data planes privados | `curl` al endpoint de ARM desde cualquier lado |
| **Agrupación de recursos** | Modelo multi-tenant; recursos físicos/virtuales asignados dinámicamente; el consumidor no tiene control ni conocimiento de la ubicación exacta más allá de una abstracción gruesa | Azure Hypervisor sobre hosts agrupados; elegís una **región** y opcionalmente una **availability zone**, nunca un rack | `az vm list-skus` muestra capacidad por región/zona, nunca por host |
| **Elasticidad rápida** | Las capacidades pueden aprovisionarse y liberarse elásticamente, a menudo de forma automática, aparentando ser ilimitadas | Autoscale de VMSS, autoscale de App Service, scale controller de Functions, KEDA en Container Apps/AKS | Evento de scale-out visible en el Activity Log |
| **Servicio medido** | El uso de recursos se monitorea, controla y reporta, dando transparencia a ambas partes | Medidores de uso → `Microsoft.Consumption` / `Microsoft.CostManagement` | `az consumption usage list` |

**Nota del arquitecto.** "Aparentando ser ilimitadas" es la característica que falla primero en producción. La elasticidad está acotada por la *capacidad regional*, la *cuota de suscripción* y el *throughput del control plane*. Un error de capacidad (`AllocationFailed`, `ZonalAllocationFailed`) es un modo de falla real, especialmente para SKUs grandes, SKUs con GPU y Spot. La elasticidad es una promesa *estadística*, no una garantía — diseñá para la falla de asignación igual que diseñás para la falla de disco.

### 2.3 La arquitectura interna: control plane vs data plane

Este es el modelo mental más útil de Azure, y es invisible en la mayoría del material de fundamentos.

```
                       ┌──────────────────────────────────────────────┐
   az / Terraform      │        CONTROL PLANE (management.azure.com)  │
   Bicep / Portal ────▶│                                              │
   GitHub Actions      │  1. TLS terminate                            │
                       │  2. AuthN  → Microsoft Entra ID (JWT)        │
                       │  3. AuthZ  → Azure RBAC (roleAssignments)    │
                       │  4. Admission → Azure Policy (deny/modify/   │
                       │                 append/audit)                │
                       │  5. Throttle → token bucket per principal /  │
                       │                region / resource provider    │
                       │  6. Dispatch → Resource Provider (RP)        │
                       │                Microsoft.Compute, .Web, .App │
                       └───────────────────────┬──────────────────────┘
                                               │  asynchronous
                                               ▼
                       ┌──────────────────────────────────────────────┐
                       │        DATA PLANE (per-service endpoints)    │
                       │  <acct>.blob.core.windows.net                │
                       │  <server>.database.windows.net               │
                       │  <app>.azurewebsites.net                     │
                       │  <cluster-fqdn>:443 (Kubernetes API)         │
                       │                                              │
                       │  Own auth (SAS, keys, Entra tokens, mTLS)    │
                       │  Own SLA. Own throttling. Own failure modes. │
                       └──────────────────────────────────────────────┘
```

Consecuencias que tenés que poder enunciar:

- **Los dos planos fallan de manera independiente.** Una caída total de ARM no impide que una VM en ejecución siga sirviendo tráfico, ni detiene las lecturas de blob. A la inversa, un control plane sano no te dice nada sobre la salud del data plane.
- **Toda escritura de ARM es idempotente y declarativa.** Las plantillas ARM/Bicep son *estado deseado*; reenviar la misma plantilla es seguro. Por eso `what-if` tiene sentido y por eso los despliegues parciales son reanudables.
- **ARM tiene límite de tasa.** ARM devuelve encabezados `x-ms-ratelimit-remaining-subscription-reads` / `-writes` y `429 TooManyRequests` con `Retry-After` cuando el bucket se vacía. Un bucle de reconciliación agresivo (un operator mal escrito, una matriz de CI con 200 despliegues en paralelo) se va a throttlear hasta desaparecer. **Tu automatización debe respetar `Retry-After`.**
- **Los Resource Providers deben registrarse por suscripción** antes de poder crear sus recursos. Un error de "resource type not found" en una suscripción recién creada casi siempre es un RP no registrado, no un typo.

---

## 3. El modelo de responsabilidad compartida

### 3.1 La tabla canónica (la respuesta del examen)

**C = el cliente siempre la conserva · S = compartida · M = Microsoft**

| Capa de responsabilidad | On-premises | IaaS | PaaS | SaaS |
|---|:---:|:---:|:---:|:---:|
| Información y datos | C | C | C | C |
| Dispositivos (móviles y PCs) | C | C | C | C |
| Cuentas e identidades | C | C | C | C |
| Infraestructura de identidad y directorio | C | **S** | **S** | **S** |
| Aplicaciones | C | C | **S** | M |
| Controles de red | C | C | **S** | M |
| Sistema operativo | C | C | M | M |
| Hosts físicos | C | M | M | M |
| Red física | C | M | M | M |
| Datacenter físico | C | M | M | M |

**Las tres filas que nunca se mueven, en ningún modelo:** *información y datos*, *dispositivos*, *cuentas e identidades*. Si un ítem del examen pregunta "¿qué responsabilidad es siempre del cliente sin importar el modelo de servicio de nube?", la respuesta es una de esas tres.

La regla desde la que podés derivar el resto de la tabla: **cuanto más te movés hacia la derecha (IaaS → PaaS → SaaS), más absorbe Microsoft, empezando por la base del stack y subiendo.**

### 3.2 Qué significa realmente "Microsoft administra el host"

El contenido de fundamentos lo enuncia y se detiene ahí. Como SRE necesitás la mecánica, porque se filtra en tus números de disponibilidad.

**Mantenimiento del host.** Microsoft parchea el OS del host y el hipervisor de manera continua. La mayoría de las actualizaciones usan **mantenimiento con preservación de memoria** (live migration in-place / actualización con preservación de VM) con una pausa de unos pocos segundos — sin reinicio, sin ningún evento visible para el OS más allá de un salto de reloj. Las actualizaciones que *no* pueden hacerse en vivo se programan y se te informan con anticipación; podés iniciarlas vos mismo en una ventana de mantenimiento. El caso sin reinicio es el común, no el garantizado.

**Cómo te enterás.** Azure Instance Metadata Service (IMDS) expone **Scheduled Events** en la dirección link-local no ruteable `169.254.169.254`. Este es el gancho del cliente hacia una responsabilidad propiedad de Microsoft — el ejemplo más claro de que "la capa de Microsoft" igual requiere una acción tuya.

```bash
$ curl -s -H "Metadata: true" \
    "http://169.254.169.254/metadata/scheduledevents?api-version=2020-07-01" | jq .
```
```json
{
  "DocumentIncarnation": 17,
  "Events": [
    {
      "EventId": "c1a4b1f0-9e2b-4c1a-9a1f-2f7c0e9d55aa",
      "EventStatus": "Scheduled",
      "EventType": "Reboot",
      "ResourceType": "VirtualMachine",
      "Resources": [ "web-prod-vmss_7" ],
      "NotBefore": "Fri, 04 Sep 2026 03:41:12 GMT",
      "Description": "Host server is undergoing maintenance.",
      "EventSource": "Platform",
      "DurationInSeconds": 420
    }
  ]
}
```

Valores de `EventType` que tenés que reconocer: `Freeze` (pausa breve, la VM sigue corriendo), `Reboot`, `Redeploy` (movida a un host nuevo, se pierde el disco efímero), `Preempt` (**desalojo de Spot — 30 segundos de aviso**), `Terminate` (borrado programado).

El patrón de producción: un agente pequeño consulta este endpoint cada ~5–15 s, y ante un `Preempt` o `Reboot` drena el nodo (cordon+drain en Kubernetes, desregistrar del load balancer, checkpoint del trabajo en vuelo), y luego **acusa recibo** del evento para iniciarlo de inmediato en lugar de esperar a que se agote la ventana de aviso.

**Fault domains y update domains.** Dentro de una región, una unidad de escala se particiona en **fault domains** (energía/red/rack distintos — protege contra fallas de hardware *no planificadas*) y **update domains** (grupos de mantenimiento por lotes — protege contra actualizaciones *planificadas* de la plataforma). Un availability set se distribuye entre hasta 3 FDs y hasta 20 UDs *dentro de un mismo datacenter*. Las **availability zones** son la primitiva más fuerte: datacenters físicamente separados dentro de una región, cada uno con energía, refrigeración y redes independientes, conectados por fibra privada de alto throughput y baja latencia (round-trip por debajo de 2 ms). Las zonas protegen contra la pérdida de un datacenter; los availability sets no.

### 3.3 El SLA es un crédito, no una garantía — y se compone multiplicativamente

Un SLA es un **instrumento financiero**: si se incumple, Microsoft emite un crédito de servicio contra tu factura. No restaura tus ingresos y no recarga tu error budget. Tratá los SLAs publicados como *entradas a un modelo de fiabilidad*, nunca como una promesa de fiabilidad.

| Forma de despliegue (ejemplo con VMs) | SLA | Downtime máximo permitido / mes de 30 días |
|---|---:|---:|
| VM única, todo Premium SSD / Ultra Disk | 99,9 % | 43,2 min |
| Dos o más VMs en un **availability set** | 99,95 % | 21,6 min |
| Dos o más VMs en **≥2 availability zones** | 99,99 % | 4,32 min |
| "Cinco nueves" teórico | 99,999 % | 26 s |

**Composición en serie (las dependencias se multiplican):**

| Cadena | Cálculo | Compuesto | Downtime / mes |
|---|---|---:|---:|
| Front Door (99,99) → App Service (99,95) → SQL (99,99) | 0.9999 × 0.9995 × 0.9999 | **99,93 %** | 30,2 min |
| Cuatro servicios independientes de 99,99 % en serie | 0.9999⁴ | **99,96 %** | 17,3 min |

**Composición en paralelo (la redundancia independiente compone la probabilidad de *falla*):**

| Cadena | Cálculo | Compuesto | Downtime / mes |
|---|---|---:|---:|
| Dos regiones independientes de 99,9 %, activo/activo | 1 − (0.001)² | **99,9999 %** | 2,6 s |

Las dos lecciones: **cada dependencia que agregás baja tu techo**, y **la única forma de superar el SLA de un componente es la redundancia a través de un dominio de falla independiente.** Un diseño "altamente disponible" de una sola región está topeado por la región.

### 3.4 La capa indelegable: una falla resuelta paso a paso

El incidente de responsabilidad compartida más común no es exótico. Es: *una cuenta de storage pública*.

Microsoft es responsable de la durabilidad, el cifrado en reposo, la seguridad física y la disponibilidad de Azure Storage. Es 100 % responsabilidad del cliente decidir si `allowBlobPublicAccess` es `true`. Cada capa que Microsoft posee puede ser perfecta y los datos igual se filtran. La detección es gratis y toma un comando:

```bash
$ az storage account list \
    --query "[?allowBlobPublicAccess==\`true\`].{name:name, rg:resourceGroup, tls:minimumTlsVersion}" \
    -o table
```
```
Name                 Rg                Tls
-------------------  ----------------  ----------
stplatlegacyexport   rg-data-prod      TLS1_0
```

Dos fallas propiedad del cliente en una sola fila. La prevención pertenece al control plane, como política de admisión — ver §9.4.

---

## 4. Modelos de despliegue de nube

### 4.1 Definiciones

- **Nube pública** — infraestructura propiedad del proveedor y operada por él, ofrecida al público general a través de internet. Multi-tenant. Sin CapEx. No sos dueño ni controlás el hardware. *Regiones públicas de Azure.*
- **Nube privada** — infraestructura de nube aprovisionada para uso exclusivo de una sola organización. Puede estar en tus instalaciones o alojada por un tercero. **Una nube privada sigue siendo una nube** — debe tener las cinco características NIST (autoservicio, agrupación, elasticidad, medición). Un rack de hosts VMware configurados a mano con una cola de tickets *no* es una nube privada; es un datacenter. *Azure Local (antes Azure Stack HCI), Azure Stack Hub.*
- **Nube híbrida** — una composición de dos o más nubes distintas (pública + privada) que siguen siendo entidades únicas pero están unidas por tecnología que habilita la portabilidad de datos y aplicaciones. *Azure Arc, Azure Local, ExpressRoute, VPN Gateway, Azure Stack Edge.*
- **Multicloud** — usar dos o más proveedores de nube pública. Nota: multicloud **no** está en la taxonomía clásica de NIST y no es lo mismo que híbrida. Híbrida = pública + privada. Multicloud = múltiples públicas.

### 4.2 Matriz de compromisos

| Dimensión | Pública | Privada | Híbrida |
|---|---|---|---|
| **Modelo de capital** | OpEx puro; cero CapEx | Fuerte en CapEx (hardware, instalación, ciclo de renovación cada 3–5 años) | Mixto; cargás con ambas estructuras de costo |
| **Techo de elasticidad** | Efectivamente la capacidad regional; acotado por cuota | Duramente acotado por los racks que compraste. Hacer bursting requiere headroom precomprado | Elástico en la porción pública, fijo en la privada ("cloud bursting") |
| **Tiempo de aprovisionamiento** | Segundos a minutos | Semanas a meses para capacidad nueva | Segundos en pública, meses en privada |
| **Residencia / soberanía de datos** | Ligada a la región; EU Data Boundary; nubes soberanas disponibles | Absoluta — los datos nunca salen de tu edificio | Decisión de ubicación por carga de trabajo |
| **Latencia hacia sistemas on-prem** | WAN (10–80 ms típico); ExpressRoute mejora el determinismo, no la física | LAN (sub-ms) | Decisión de ubicación por componente |
| **Carga de parcheo / ciclo de vida** | Microsoft desde el hipervisor hacia abajo | **Vos poseés todo**, incluyendo firmware, BIOS, hipervisor, control plane | Dos modelos operativos que hay que dotar de personal |
| **Ajuste regulatorio** | Fuerte (amplio portafolio de cumplimiento) pero requiere evidencia de responsabilidad compartida | El más fuerte para mandatos de "no debe salir de las instalaciones" (información clasificada, parte de salud/defensa) | El mejor ajuste cuando solo *algunos* datos están restringidos |
| **Radio de impacto de una caída del proveedor** | Estás expuesto a caídas de región/servicio | Vos sos tu propio proveedor — tus caídas | Existe un destino de failover pero está limitado por capacidad |
| **Complejidad operativa** | La más baja | Alta | **La más alta** — dos planos, dos caminos de identidad, dos cadenas de herramientas |
| **Consistencia del tooling** | ARM/Bicep/Terraform nativos | Depende del stack | Azure Arc proyecta recursos on-prem/de otra nube **dentro de ARM**, dando un único control plane |

### 4.3 Casos de uso — la regla de decisión

| Elegí | Cuándo |
|---|---|
| **Pública** | Demanda variable/impredecible; productos nuevos de escala desconocida; alcance global sin datacenters globales; cualquier cosa donde domine el time-to-market; querés dejar de hacer trabajo de infraestructura no diferenciado. **Opción por defecto.** |
| **Privada** | Un mandato legal/contractual duro de que los datos no salgan de un límite físico; acoplamiento de latencia extremadamente baja con planta física (bucles de control en planta fabril, colocation de trading); un datacenter totalmente amortizado con años de vida útil restante y demanda estable y plana. |
| **Híbrida** | Migración en curso (el caso común — la híbrida suele ser una *fase*, no un destino); datos regulados anclados on-prem mientras el cómputo/analítica corre en Azure; recuperación ante desastres donde Azure es el destino de DR de la producción on-prem (**Azure como sitio de DR es uno de los patrones híbridos de mayor ROI** — pagás almacenamiento de forma continua y cómputo solo durante un failover o simulacro); sitios de borde que necesitan autonomía local con gobernanza central. |
| **Multicloud** | Demanda regulatoria genuina de diversidad de proveedores; integración por adquisición; un servicio específico que solo ofrece un proveedor. **Sé honesto:** multicloud para "evitar lock-in" típicamente convierte el riesgo de proveedor en complejidad de integración, costo de personal y arquitectura de mínimo común denominador. |

### 4.4 La tecnología híbrida que importa: Azure Arc

Azure Arc es cómo el *control plane* se vuelve híbrido. Proyecta recursos no-Azure dentro de ARM como tipos de recurso de primera clase:

| Tipo de recurso Arc | Tipo ARM | Qué ganás |
|---|---|---|
| Servidores (cualquier Windows/Linux físico/virtual, en cualquier lado) | `Microsoft.HybridCompute/machines` | Azure Policy, Update Manager, Defender for Cloud, Machine Configuration, agentes de Azure Monitor, RBAC, tags |
| Clústeres de Kubernetes (cualquier clúster conforme a CNCF) | `Microsoft.Kubernetes/connectedClusters` | Configuración GitOps (Flux), Policy for Kubernetes (Gatekeeper), Defender, Monitor, cluster connect |
| Servicios de datos | `Microsoft.AzureArcData/*` | SQL MI / PostgreSQL administrados sobre tu propio hardware |

Una vez habilitada con Arc, una máquina RHEL on-prem queda sujeta a la *misma* asignación de RBAC y a la *misma* definición de Azure Policy que una VM de Azure. Ese es el rédito operativo: **un plano de gobernanza, dos (o más) sustratos.**

---

## 5. El modelo basado en consumo

### 5.1 CapEx vs OpEx

| | **CapEx** (gasto de capital) | **OpEx** (gasto operativo) |
|---|---|---|
| Momento del efectivo | Gran desembolso inicial | Continuo, proporcional al uso |
| Contabilidad | Capitalizado, depreciado a lo largo de la vida útil (típ. 3–5 años) | Imputado al período en que se incurre |
| Camino de aprobación | Ciclo presupuestario, compras, firma del directorio | Frecuentemente dentro de un presupuesto de ingeniería |
| Costo de una estimación equivocada | Hardware varado; sos dueño de él por 5 años | Lo cambiás en la próxima hora |
| Típico de | On-premises / nube privada | Nube pública |

La consecuencia arquitectónica no es financiera, es **conductual**: CapEx te obliga a dimensionar para el pico *con años de anticipación* y a comerte el tiempo ocioso. OpEx te deja dimensionar para *ahora*. Esa inversión es la razón por la que la nube abarata la experimentación — el costo de una arquitectura equivocada baja de "una orden de compra" a "un `terraform destroy`".

La otra mitad de la honestidad: OpEx no tiene techo natural. Una regla de autoscale sin límite más una tormenta de reintentos es un incidente *financiero*. Los presupuestos y las cuotas son el control compensatorio (§9.1).

### 5.2 Cómo funciona realmente la medición

**Modelo basado en consumo ("pay-as-you-go") = pagás solo por lo que usás, cuando lo usás, sin costo inicial y sin penalidad por detenerte.**

El pipeline por debajo:

```
Resource emits usage
   │   e.g. VM heartbeat, blob GB-hours, Function GB-seconds, egress GB
   ▼
Meter record  { meterId, meterCategory, meterName, unit, quantity, resourceUri, tags }
   │   aggregated hourly per resource
   ▼
Rating engine — quantity × unit price from your price sheet
   │   price sheet varies by agreement: MCA / EA / CSP / PAYG, and by region
   ▼
Cost records (actual + amortised)
   │
   ├──▶ Microsoft.Consumption      → usage details, budgets, reservation recs
   ├──▶ Microsoft.CostManagement   → query API, exports (incl. FOCUS 1.0), alerts
   └──▶ Invoice (billing account → billing profile → invoice section)
```

Tres detalles que agarran desprevenidos a los ingenieros:

1. **Los medidores no son recursos.** Una sola VM emite varios medidores simultáneamente — horas de cómputo, managed disk (capacidad aprovisionada, facturada incluso cuando la VM está *stopped-deallocated*), transacciones de disco, IP pública, ancho de banda de egreso. "Desasigné la VM así que es gratis" es falso: el disco de OS y la IP pública estática siguen facturando.
2. **"Stopped" ≠ "Stopped (deallocated)".** `Stopped` desde adentro del guest mantiene la reserva de cómputo y sigue facturando. Solo `az vm deallocate` (el "Stop" del portal) la libera.
3. **Los datos de costo no son en tiempo real.** El uso típicamente aterriza en Cost Management dentro de horas, no de segundos. Por lo tanto, las alertas de presupuesto son un control *detectivo* con horas de latencia — nunca tu única defensa contra el gasto descontrolado. **Las cuotas y los límites duros de recursos son el control preventivo.**

### 5.3 La jerarquía de facturación

```
Microsoft Customer Agreement (MCA)              Enterprise Agreement (EA)
  Billing account                                 Billing account (Enrollment)
    └─ Billing profile   (= one invoice, one currency, one PO)
         └─ Invoice section (= cost allocation unit)
              └─ Subscription      ◀── the RBAC + quota + policy boundary
                   └─ Resource group  ◀── lifecycle + deployment boundary
                        └─ Resource   ◀── the thing that emits meters
```

**Regla de diseño:** la *suscripción* es tu límite principal de radio de impacto y de cuota; el *resource group* es tu límite de ciclo de vida (todo lo que está adentro debería crearse y borrarse junto); el *tag* es tu dimensión de asignación de costos. Si te equivocás con los tags, el chargeback es irrecuperable después del hecho — no podés retro-etiquetar registros de uso históricos.

---

## 6. Comparando modelos de precios en la nube

### 6.1 La matriz de precios de cómputo

Los precios son **precios de lista ilustrativos** para una `Standard_D4s_v5` con Linux en una región de EE. UU. y existen solo para volver concreta la aritmética. **Verificá siempre contra la Azure Pricing Calculator y tu propia hoja de precios** — los precios regionales y por acuerdo difieren de manera significativa.

| Modelo | Compromiso | Descuento ilustrativo vs PAYG | Garantía de capacidad | Flexibilidad | Mejor para |
|---|---|---:|---|---|---|
| **Pay-as-you-go** | Ninguno | 0 % (base ≈ $0.192/h ≈ $140/mes) | Ninguna (asignación best-effort) | Total | Impredecible, con picos, corta duración, dev |
| **Reservation (Reserved Instance)** 1 año | Por adelantado o mensual, 1 año | ~30–40 % | No (salvo que compres una capacity reservation aparte) | Flexibilidad de tamaño de instancia dentro de una serie; alcance modificable; intercambio/reembolso de autoservicio sujeto a política y a un tope anual de reembolso | Línea base estable de la que estás seguro por un año |
| **Reservation** 3 años | 3 años | ~55–65 % (≈ $0.073/h ≈ $53/mes) | No | Igual que arriba, con bloqueo más largo | Línea base de larga vida e inamovible |
| **Savings plan for compute** 1/3 años | Gasto fijo en **$/hora**, no una SKU específica | ~11–17 % (1 año) / ~28–65 % (3 años), menor que una RI equivalente | No | **La más alta** — se aplica automáticamente entre series de VM, regiones, App Service, Container Instances, Functions Premium | *Gasto* estable con una *forma* cambiante |
| **Spot VMs** | Ninguno | Hasta ~90 % | **Ninguna — desalojable con 30 s de aviso** | Desalojada por presión de capacidad o umbral de precio; `--max-price -1` = pagar hasta PAYG | Batch, runners de CI, renderizado, workers stateless tolerantes a fallas, entrenamiento de ML con checkpoints |
| **Azure Hybrid Benefit** | Licencias existentes + Software Assurance / suscripción | Elimina el componente de licencia de Windows Server / SQL Server / RHEL / SLES | n/a | Apilable **encima de** reservations y savings plans | Cualquiera que ya posea licencias elegibles |
| **Suscripción Dev/Test** | Beneficio de EA o MCA | Tarifas descontadas de Windows/SQL; sin cargo de licencia para uso no productivo elegible | n/a | **Solo uso no productivo** — exigido por contrato | Dev, test, QA, staging |
| **Capa gratuita** | Ninguno | 100 % dentro de la asignación | n/a | $200 de crédito por 30 días; 12 meses de servicios seleccionados; un conjunto de servicios siempre gratuitos con asignaciones mensuales | Aprendizaje, prototipos |

**Las reservations y los savings plans se apilan con Hybrid Benefit; no se apilan entre sí sobre la misma hora-recurso.** El descuento de la reservation se aplica primero; el savings plan absorbe lo que la reservation no cubrió.

### 6.2 La aritmética del punto de equilibrio que todo arquitecto debería poder hacer en un pizarrón

**Utilización de equilibrio de una reservation.** Una reservation factura cada hora del plazo, la uses o no. Entonces:

$$
\text{costo PAYG} = P_{payg} \times H \times u
\qquad
\text{costo RI} = P_{ri} \times H
$$

Igualándolos se obtiene la utilización de equilibrio:

$$
u^{*} = \frac{P_{ri}}{P_{payg}} = 1 - d
$$

donde *d* es el descuento de la reservation. Con un descuento del 62 % a tres años, $u^{*} = 0.38$.

> **Leé eso con atención: un recurso que corre solo el 38 % de las horas en tres años igual alcanza el equilibrio con una reservation a 3 años.** Por eso "solo lo corremos en horario laboral así que no lo vamos a reservar" suele ser aritmética equivocada — 40 h/semana es 24 % de utilización, que está *por debajo* del equilibrio, pero 24/5 (120 h/semana ≈ 71 %) está muy por encima.

**Equilibrio de Spot.** Spot no tiene SLA, así que el cálculo no es de precio sino de *trabajo esperado completado por dólar*:

$$
\text{costo efectivo} = \frac{P_{spot}}{1 - w}
$$

donde *w* es la fracción de trabajo perdido por desalojo (trabajo hecho desde el último checkpoint). Con un descuento del 90 %, Spot sigue siendo más barato que PAYG hasta que perdés **más del 90 % de tu trabajo** por desalojos — que es la razón por la que el único requisito real es el *checkpointing*, no la tasa de desalojo.

**Equilibrio de serverless vs siempre encendido.** Las Functions en plan de consumo facturan por **GB-segundos** (memoria observada × tiempo de ejecución) más **ejecuciones**. Dos reglas de redondeo dominan la factura y suelen pasarse por alto:

- la memoria observada se **redondea hacia arriba al múltiplo de 128 MB más cercano**, con mínimo de 128 MB;
- el tiempo de ejecución tiene un **mínimo de 100 ms**.

Ejemplo trabajado — una función de 512 MB que promedia 200 ms:

```
GB-s per execution = 0.5 GB × 0.2 s               = 0.1 GB-s
Per 1,000,000 executions:
  compute     = 100,000 GB-s × $0.000016/GB-s     = $1.60
  executions  = 1M × $0.20 per 1M                 = $0.20
  ------------------------------------------------------
  total                                            ≈ $1.80 / million
```

Contra una instancia de plan Premium siempre caliente a aproximadamente $0.20/h ≈ **$146/mes**, el consumo sigue siendo más barato hasta aproximadamente **80 millones de ejecuciones/mes** con ese perfil de duración. El cruce se derrumba rápido a medida que crece la duración: con 2 s de duración promedio la misma función cuesta ~$16.20/millón y cruza cerca de los 9M de ejecuciones.

**El corolario:** serverless es barato para trabajo *corto y con picos*, y caro para trabajo *largo y constante*. La duración, no la cantidad de requests, es la variable que da vuelta la decisión.

### 6.3 Factores de costo y palancas

| Factor | Mecanismo | Palanca |
|---|---|---|
| **Cómputo** | Por segundo o por hora según SKU, OS, región | Dimensionar correctamente; desasignar por horario; reservations/savings plans; Spot; Hybrid Benefit |
| **Almacenamiento** | Aprovisionado (managed disks — facturados por la capa *aprovisionada*, no por los bytes consumidos) vs consumido (blob GB-mes) + transacciones | Capas de acceso (Hot/Cool/Cold/Archive) + políticas de lifecycle management; borrar discos y snapshots huérfanos |
| **Redes** | **El ingreso es gratis. El egreso a internet se cobra**, con una asignación mensual gratuita. El tráfico entre regiones y entre zonas se cobra. Dentro de la misma VNet y la misma zona es gratis | Mantener juntas las capas conversadoras; usar Private Link/service endpoints; poner una CDN delante del egreso estático |
| **Región** | Los precios difieren por región para la misma SKU | Desplegar donde la latencia y la residencia permitan la región más barata |
| **Licenciamiento** | Licencia de Windows/SQL/RHEL embebida en el medidor | Azure Hybrid Benefit; Linux donde la carga de trabajo lo permita |
| **Plan de soporte** | Basic (gratis) / Developer / Standard / Professional Direct — % del gasto o monto fijo | Ajustar el plan al requisito real de tiempo de respuesta |
| **Ocioso** | Capacidad aprovisionada pero no usada | Escalar a cero (serverless), horarios de apagado automático, automatización del ciclo de vida de dev/test |

---

## 7. Serverless

### 7.1 Definición y las dos propiedades que la definen

**Serverless** significa que el proveedor de nube administra completamente la infraestructura, el aprovisionamiento y el escalado; el cliente despliega código o configuración y se le factura solo por la ejecución real. Sigue habiendo servidores — pero no los ves, no los dimensionás, no los parcheás ni pagás por los ociosos.

Dos propiedades son diagnósticas. Si a un servicio le falta alguna, es *administrado*, no serverless:

1. **Escalar a cero** — cuando no hay trabajo, no hay instancias facturables.
2. **La granularidad de facturación es igual a la granularidad de ejecución** — se te factura por invocación/segundo/request-unit, no por hora aprovisionada.

Azure App Service en un plan P1v3 es *totalmente administrado*, pero cuesta lo mismo a 0 RPS que a 500 RPS. **No es serverless.**

### 7.2 El portafolio serverless de Azure

| Servicio | Unidad de trabajo | Unidad de facturación | Escala a cero | Ejecución máxima | Notas |
|---|---|---|---|---|---|
| **Functions — Consumption** | Invocación de función | GB-s + ejecuciones | Sí | 5 min por defecto, **10 min máximo duro** (`functionTimeout` en `host.json`) | Límite de scale-out de 200 instancias (Windows) / 100 (Linux); sin integración con VNet |
| **Functions — Flex Consumption** | Invocación de función | GB-s bajo demanda + línea base always-ready + ejecuciones | Sí (con instancias always-ready opcionales) | 30 min por defecto; puede ser ilimitado | Concurrencia por instancia, integración con VNet, memoria de instancia 512 / 2048 / 4096 MB, techo de instancias más alto |
| **Functions — Premium (EPn)** | Invocación de función | vCPU-s aprovisionados + GB-s | **No** (instancias mínimas ≥ 1) | Ilimitado (`-1`) | Las instancias precalentadas eliminan el cold start; VNet; el "modelo de programación serverless sin la economía serverless" |
| **Functions — Dedicated (plan de App Service)** | Invocación de función | Horas del plan de App Service | No | Ilimitado | Reutiliza capacidad de un plan existente |
| **Azure Container Apps (Consumption)** | Request HTTP / evento | vCPU-s + GiB-s + requests | **Sí** (`minReplicas: 0`) | n/a (larga duración OK) | Scalers de KEDA, ingress con Envoy, revisiones, sidecars de Dapr |
| **Azure Container Instances** | Grupo de contenedores | vCPU-s + GB-s mientras corre | Solo borrando el grupo | n/a | La primitiva de contenedor por ráfagas más simple; sin orquestación |
| **Logic Apps (Consumption)** | Acción de workflow | Por acción ejecutada | Sí | Larga duración con checkpoints | Más de 1400 conectores; integración low-code |
| **Cosmos DB serverless** | Operación de base de datos | RUs consumidas + almacenamiento | Sí | n/a | Escritura en una sola región, ráfaga topeada (~5.000 RU/s por contenedor), tope de almacenamiento ~1 TB |
| **Azure SQL Database serverless** | Consulta | vCore-segundos + almacenamiento | Auto-pausa (retardo mínimo de 60 min de inactividad) | n/a | El almacenamiento se factura incluso en pausa; la reanudación agrega latencia a la primera consulta |
| **Event Grid / Service Bus / Event Hubs** | Mensaje | Operaciones / throughput units | Parcialmente | n/a | La columna vertebral de eventos a la que se enlaza el cómputo serverless |

### 7.3 Mecánica interna: cómo escala una Function en plan Consumption

Esta es la parte que el material de fundamentos nunca cubre, y es exactamente donde viven los incidentes de producción.

```
   Event source (queue depth, HTTP RPS, Event Hub lag, Cosmos change feed)
        │
        ▼
   ┌────────────────────────────────────────────────────────────────┐
   │  SCALE CONTROLLER  (a Microsoft-owned component, outside your  │
   │  app — you cannot see it, log into it, or configure it)        │
   │                                                                │
   │  • Polls each trigger's backlog signal on a heuristic per      │
   │    trigger type (queue length, unprocessed events, RPS)        │
   │  • Adds AT MOST 1 instance per second for HTTP triggers        │
   │  • Adds AT MOST 1 instance per 30 seconds for non-HTTP         │
   │  • Ceiling: 200 instances (Windows) / 100 (Linux)              │
   │  • Removes instances after a cooldown; scales to 0 when idle   │
   └───────────────────────────┬────────────────────────────────────┘
                               ▼
       Instance N  ── cold start ──▶  worker running
        │  1. Allocate a worker on a shared, multi-tenant pool
        │  2. Mount the app package (run-from-package / blob container)
        │  3. Start the language worker (dotnet-isolated, node, python, java)
        │  4. Load the host, index bindings, JIT / import modules
        │  5. Execute your function
        └─ Steps 1–4 are the COLD START. Steps 3–4 are the part you control.
```

**El cold start es una restricción de diseño, no un bug.** Su magnitud va desde unos pocos cientos de milisegundos hasta varios segundos según el runtime, el tamaño del paquete y el grafo de dependencias. Lo que vos controlás:

| Palanca | Efecto |
|---|---|
| Paquete de despliegue más chico; run-from-package | Recorta el tiempo de montaje + extracción |
| Podar el grafo de dependencias (la mayor ganancia en Python/Node/Java) | Recorta el tiempo de import/JIT |
| ReadyToRun / AOT (.NET) | Recorta el tiempo de JIT |
| Mover la inicialización fuera del handler hacia el ámbito de módulo/estático | Se amortiza entre invocaciones calientes sobre la misma instancia |
| **`alwaysReady` de Flex Consumption** | Mantiene *N* instancias calientes; pagás una línea base reducida por ellas |
| **Instancias precalentadas del plan Premium** | Elimina el cold start; pagás capacidad siempre encendida |

**La restricción de tasa de escalado es la trampa más filosa.** A 1 instancia nueva por segundo para HTTP, un escalón de carga de 0 a 5.000 RPS no puede satisfacerse instantáneamente. Si cada instancia maneja ~100 RPS necesitás ~50 instancias, es decir ~50 segundos de rampa durante los cuales la cola crece. Para triggers no-HTTP a 1 instancia cada 30 segundos, esa misma rampa son **25 minutos**. Diseñá en consecuencia: precalentá antes de picos conocidos, o usá Container Apps/KEDA, donde controlás el intervalo de polling y el cooldown.

### 7.4 Compromisos de serverless

| Ventaja | El costo que viene con ella |
|---|---|
| Sin gestión de infraestructura | Sin *acceso* a la infraestructura — sin SSH, sin métricas de host, sin tuning de kernel personalizado |
| Escalar a cero → facturación de consumo real | **Cold start** en el primer request tras el período ocioso |
| Elasticidad automática | *Tasa* de escalado acotada y techo duro de instancias |
| Barato para cargas con picos y bajo ciclo de trabajo | Caro para cargas constantes y de larga duración (§6.2) |
| Rápido time to first deploy | Los triggers/bindings específicos del proveedor profundizan el acoplamiento (mitigalo manteniendo la lógica de negocio en un módulo plano, libre de triggers, y haciendo del handler un adaptador delgado) |
| El escalado por función aísla las rutas calientes | La ausencia de estado es obligatoria — sin sesión en memoria, sin suposiciones de disco local; el estado durable debe externalizarse (Durable Functions, un store, una cola) |
| Orientado a eventos por construcción | Los sistemas aguas abajo deben sobrevivir al *fan-out*: 200 instancias concurrentes × una conexión cada una van a agotar el pool de conexiones de una base de datos. **El pooling de conexiones y el rate limiting aguas abajo no son opcionales.** |

Esa última fila es el incidente de producción serverless más común: la capa de funciones escala hermosamente y asesina a la base de datos que tiene detrás. La mitigación es un techo explícito de concurrencia (a nivel host `maxConcurrentRequests` / `batchSize`, o una cola con un consumidor acotado), no más capacidad de base de datos.

---

## 8. Manifiestos de infraestructura completos

Todos los manifiestos de abajo están completos y son sintácticamente válidos tal como se muestran.

### 8.1 Bicep — plataforma serverless basada en consumo con guardarraíles de costo

`main.bicep`:

```bicep
targetScope = 'resourceGroup'

@description('Base name; all resources derive from this.')
@minLength(3)
@maxLength(11)
param baseName string

@description('Azure region. Must support Flex Consumption.')
param location string = resourceGroup().location

@description('Monthly budget ceiling in the billing currency.')
param monthlyBudget int = 2500

@description('Budget window start, first day of a month, ISO-8601.')
param budgetStartDate string = '2026-09-01'

@description('Budget window end, ISO-8601.')
param budgetEndDate string = '2027-09-01'

@description('Where budget and anomaly alerts are delivered.')
param alertEmails array = [
  'sre-oncall@example.com'
]

@description('Cost-allocation tags applied to every resource.')
param costTags object = {
  'cost-center': 'PLAT-4471'
  owner: 'platform-sre'
  environment: 'prod'
  'data-classification': 'internal'
}

var suffix = uniqueString(resourceGroup().id)
var storageName = toLower('st${baseName}${substring(suffix, 0, 6)}')
var planName = 'plan-${baseName}-flex'
var functionAppName = 'func-${baseName}-${substring(suffix, 0, 4)}'
var workspaceName = 'log-${baseName}'
var insightsName = 'appi-${baseName}'
var deploymentContainer = 'app-package'

// ---------------------------------------------------------------------------
// Observability — required to make "measured service" actionable
// ---------------------------------------------------------------------------

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  tags: costTags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

resource insights 'Microsoft.Insights/components@2020-02-02' = {
  name: insightsName
  location: location
  tags: costTags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    IngestionMode: 'LogAnalytics'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// ---------------------------------------------------------------------------
// Storage — deployment package container. Identity-based access only:
// no connection strings, no account keys anywhere in configuration.
// ---------------------------------------------------------------------------

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  tags: costTags
  sku: {
    name: 'Standard_ZRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
    encryption: {
      requireInfrastructureEncryption: false
      keySource: 'Microsoft.Storage'
      services: {
        blob: {
          enabled: true
          keyType: 'Account'
        }
        file: {
          enabled: true
          keyType: 'Account'
        }
      }
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource packageContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: deploymentContainer
  properties: {
    publicAccess: 'None'
  }
}

// ---------------------------------------------------------------------------
// Flex Consumption plan (FC1) — scale to zero, per-instance concurrency
// ---------------------------------------------------------------------------

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: location
  tags: costTags
  kind: 'functionapp'
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
    size: 'FC'
    family: 'FC'
  }
  properties: {
    reserved: true
  }
}

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  tags: costTags
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}${deploymentContainer}'
          authentication: {
            type: 'SystemAssignedIdentity'
          }
        }
      }
      scaleAndConcurrency: {
        // Hard ceiling. This is the preventive cost control, and it is also
        // what protects the downstream database from a 1000-way fan-out.
        maximumInstanceCount: 100
        instanceMemoryMB: 2048
        // alwaysReady trades a small fixed cost for zero cold start on the
        // latency-critical HTTP surface. Remove it to be strictly pay-per-use.
        alwaysReady: [
          {
            name: 'http'
            instanceCount: 1
          }
        ]
        triggers: {
          http: {
            perInstanceConcurrency: 16
          }
        }
      }
      runtime: {
        name: 'python'
        version: '3.12'
      }
    }
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      http20Enabled: true
      appSettings: [
        {
          name: 'AzureWebJobsStorage__accountName'
          value: storage.name
        }
        {
          name: 'AzureWebJobsStorage__credential'
          value: 'managedidentity'
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: insights.properties.ConnectionString
        }
        {
          name: 'APPLICATIONINSIGHTS_AUTHENTICATION_STRING'
          value: 'Authorization=AAD'
        }
      ]
    }
  }
}

// ---------------------------------------------------------------------------
// RBAC — the function's managed identity needs data-plane access to storage.
// Control-plane RBAC (this assignment) and data-plane authorization are
// distinct concerns; this is the bridge between them.
// ---------------------------------------------------------------------------

var storageBlobDataOwnerRoleId = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

resource blobOwnerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, functionApp.id, storageBlobDataOwnerRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataOwnerRoleId)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource blobContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, functionApp.id, storageBlobDataContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// Consumption budget — the detective control on OpEx.
// Forecast alerts fire BEFORE the money is spent; actual alerts fire after.
// Both are needed: forecast catches trends, actual catches step changes.
// ---------------------------------------------------------------------------

resource budget 'Microsoft.Consumption/budgets@2023-05-01' = {
  name: '${baseName}-monthly'
  properties: {
    category: 'Cost'
    amount: monthlyBudget
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: budgetStartDate
      endDate: budgetEndDate
    }
    notifications: {
      Actual_GreaterThan_50: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 50
        thresholdType: 'Actual'
        contactEmails: alertEmails
        locale: 'en-us'
      }
      Actual_GreaterThan_90: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 90
        thresholdType: 'Actual'
        contactEmails: alertEmails
        locale: 'en-us'
      }
      Forecast_GreaterThan_100: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 100
        thresholdType: 'Forecasted'
        contactEmails: alertEmails
        locale: 'en-us'
      }
    }
  }
}

output functionAppName string = functionApp.name
output functionAppHostname string = functionApp.properties.defaultHostName
output functionAppPrincipalId string = functionApp.identity.principalId
output storageAccountName string = storage.name
output appInsightsConnectionString string = insights.properties.ConnectionString
output budgetId string = budget.id
```

`main.bicepparam`:

```bicep
using './main.bicep'

param baseName = 'payments'
param location = 'eastus'
param monthlyBudget = 2500
param budgetStartDate = '2026-09-01'
param budgetEndDate = '2027-09-01'
param alertEmails = [
  'sre-oncall@example.com'
  'finops@example.com'
]
param costTags = {
  'cost-center': 'PLAT-4471'
  owner: 'platform-sre'
  environment: 'prod'
  'data-classification': 'internal'
}
```

### 8.2 Terraform — los mismos controles de consumo, más una línea base elegible para reservation

`main.tf`:

```hcl
terraform {
  required_version = ">= 1.9.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
  }
}

variable "base_name" {
  description = "Base name for all resources."
  type        = string
  default     = "payments"
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "eastus"
}

variable "monthly_budget" {
  description = "Monthly budget ceiling."
  type        = number
  default     = 2500
}

variable "cost_tags" {
  description = "Cost-allocation tags applied to every resource."
  type        = map(string)
  default = {
    cost-center         = "PLAT-4471"
    owner               = "platform-sre"
    environment         = "prod"
    data-classification = "internal"
    provisioner         = "terraform"
  }
}

data "azurerm_subscription" "current" {}

resource "azurerm_resource_group" "platform" {
  name     = "rg-${var.base_name}-prod"
  location = var.location
  tags     = var.cost_tags
}

# ---------------------------------------------------------------------------
# Steady-state baseline: zone-redundant VMSS.
# This is the RESERVATION-ELIGIBLE tier. It runs 24/7, so at any discount
# above ~38% a three-year reservation beats pay-as-you-go (see 6.2).
# ---------------------------------------------------------------------------

resource "azurerm_virtual_network" "platform" {
  name                = "vnet-${var.base_name}"
  address_space       = ["10.40.0.0/16"]
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  tags                = var.cost_tags
}

resource "azurerm_subnet" "workload" {
  name                 = "snet-workload"
  resource_group_name  = azurerm_resource_group.platform.name
  virtual_network_name = azurerm_virtual_network.platform.name
  address_prefixes     = ["10.40.1.0/24"]
}

resource "azurerm_orchestrated_virtual_machine_scale_set" "baseline" {
  name                        = "vmss-${var.base_name}-baseline"
  location                    = azurerm_resource_group.platform.location
  resource_group_name         = azurerm_resource_group.platform.name
  platform_fault_domain_count = 1

  # Zone redundancy is what lifts the composite SLA from 99.95% to 99.99%.
  zones = ["1", "2", "3"]

  sku_name  = "Standard_D4s_v5"
  instances = 3

  os_profile {
    linux_configuration {
      admin_username                  = "azureuser"
      disable_password_authentication = true
      admin_ssh_key {
        username   = "azureuser"
        public_key = file("~/.ssh/id_ed25519.pub")
      }
    }
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  os_disk {
    storage_account_type = "Premium_LRS"
    caching              = "ReadWrite"
  }

  network_interface {
    name    = "nic-baseline"
    primary = true

    ip_configuration {
      name      = "ipconfig1"
      primary   = true
      subnet_id = azurerm_subnet.workload.id
    }
  }

  identity {
    type = "SystemAssigned"
  }

  tags = merge(var.cost_tags, {
    pricing-model = "reserved-3yr"
    workload-tier = "baseline"
  })
}

# ---------------------------------------------------------------------------
# Burst tier: Spot. No SLA, evictable with 30 s notice.
# Every workload placed here MUST checkpoint and MUST handle Preempt.
# ---------------------------------------------------------------------------

resource "azurerm_orchestrated_virtual_machine_scale_set" "burst" {
  name                        = "vmss-${var.base_name}-burst"
  location                    = azurerm_resource_group.platform.location
  resource_group_name         = azurerm_resource_group.platform.name
  platform_fault_domain_count = 1
  zones                       = ["1", "2", "3"]

  sku_name  = "Standard_D4s_v5"
  instances = 0

  priority        = "Spot"
  eviction_policy = "Delete"
  max_bid_price   = -1 # -1 = never evicted on price, only on capacity

  os_profile {
    linux_configuration {
      admin_username                  = "azureuser"
      disable_password_authentication = true
      admin_ssh_key {
        username   = "azureuser"
        public_key = file("~/.ssh/id_ed25519.pub")
      }
    }
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  os_disk {
    storage_account_type = "Standard_LRS"
    caching              = "ReadWrite"
  }

  network_interface {
    name    = "nic-burst"
    primary = true

    ip_configuration {
      name      = "ipconfig1"
      primary   = true
      subnet_id = azurerm_subnet.workload.id
    }
  }

  tags = merge(var.cost_tags, {
    pricing-model = "spot"
    workload-tier = "burst"
    checkpointing = "required"
  })
}

resource "azurerm_consumption_budget_resource_group" "platform" {
  name              = "${var.base_name}-monthly"
  resource_group_id = azurerm_resource_group.platform.id
  amount            = var.monthly_budget
  time_grain        = "Monthly"

  time_period {
    start_date = "2026-09-01T00:00:00Z"
    end_date   = "2027-09-01T00:00:00Z"
  }

  notification {
    enabled        = true
    threshold      = 90
    threshold_type = "Actual"
    operator       = "GreaterThan"
    contact_emails = ["sre-oncall@example.com"]
  }

  notification {
    enabled        = true
    threshold      = 100
    threshold_type = "Forecasted"
    operator       = "GreaterThan"
    contact_emails = ["sre-oncall@example.com", "finops@example.com"]
  }
}

output "resource_group" {
  value = azurerm_resource_group.platform.name
}

output "baseline_vmss_id" {
  value = azurerm_orchestrated_virtual_machine_scale_set.baseline.id
}

output "burst_vmss_id" {
  value = azurerm_orchestrated_virtual_machine_scale_set.burst.id
}
```

### 8.3 Azure Container Apps — contenedores serverless con escalado a cero

`containerapp.yaml` (consumido por `az containerapp create --yaml`):

```yaml
location: eastus
type: Microsoft.App/containerApps
tags:
  cost-center: PLAT-4471
  owner: platform-sre
  environment: prod
  pricing-model: consumption
identity:
  type: SystemAssigned
properties:
  managedEnvironmentId: /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-payments-prod/providers/Microsoft.App/managedEnvironments/cae-payments
  workloadProfileName: Consumption
  configuration:
    activeRevisionsMode: Single
    ingress:
      external: true
      targetPort: 8080
      transport: auto
      allowInsecure: false
      clientCertificateMode: ignore
      traffic:
        - latestRevision: true
          weight: 100
    dapr:
      enabled: false
    registries: []
  template:
    revisionSuffix: v1
    containers:
      - name: settlement-worker
        image: mcr.microsoft.com/k8se/quickstart:latest
        resources:
          # Consumption profile: cpu and memory must follow the allowed
          # ratio — memory (GiB) = cpu * 2. 0.5 vCPU -> 1.0Gi.
          cpu: 0.5
          memory: 1.0Gi
        env:
          - name: LOG_LEVEL
            value: info
          - name: MAX_INFLIGHT
            value: "8"
        probes:
          - type: Liveness
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
            failureThreshold: 3
          - type: Readiness
            httpGet:
              path: /readyz
              port: 8080
            initialDelaySeconds: 3
            periodSeconds: 5
            failureThreshold: 3
          - type: Startup
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 2
            periodSeconds: 3
            failureThreshold: 20
    scale:
      # minReplicas: 0 is the line that makes this SERVERLESS rather than
      # merely managed. At zero replicas the only charge is storage/registry.
      minReplicas: 0
      maxReplicas: 30
      rules:
        - name: http-concurrency
          http:
            metadata:
              concurrentRequests: "40"
        - name: queue-depth
          custom:
            type: azure-servicebus
            metadata:
              queueName: settlements
              namespace: sb-payments-prod
              messageCount: "20"
            identity: system
```

### 8.4 Azure Policy — imponiendo la asignación de costos en el control plane

El chargeback es imposible sin tags, y los tags son imposibles de rellenar retroactivamente sobre registros de uso históricos. Imponelos en el momento de la admisión. `policy-require-cost-center.json`:

```json
{
  "properties": {
    "displayName": "Require a cost-center tag on resource groups",
    "policyType": "Custom",
    "mode": "All",
    "description": "Denies creation of a resource group without a cost-center tag. Cost allocation is only possible if the dimension exists at the moment usage is metered; it cannot be applied retroactively.",
    "metadata": {
      "version": "1.0.0",
      "category": "Tags"
    },
    "parameters": {
      "tagName": {
        "type": "String",
        "metadata": {
          "displayName": "Tag name",
          "description": "Name of the tag required on the resource group."
        },
        "defaultValue": "cost-center"
      }
    },
    "policyRule": {
      "if": {
        "allOf": [
          {
            "field": "type",
            "equals": "Microsoft.Resources/subscriptions/resourceGroups"
          },
          {
            "field": "[concat('tags[', parameters('tagName'), ']')]",
            "exists": "false"
          }
        ]
      },
      "then": {
        "effect": "deny"
      }
    }
  }
}
```

### 8.5 Híbrido — KEDA con escalado a cero sobre un clúster habilitado con Arc

El mismo *comportamiento* serverless sobre tu propio hardware. Esto es lo que hace de "híbrido" una arquitectura real y no una diapositiva.

`keda-scaledobject.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: settlement
  labels:
    cost-center: PLAT-4471
    workload-tier: burst
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: settlement-worker
  namespace: settlement
  labels:
    app: settlement-worker
spec:
  replicas: 0
  selector:
    matchLabels:
      app: settlement-worker
  template:
    metadata:
      labels:
        app: settlement-worker
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: settlement-worker
      terminationGracePeriodSeconds: 60
      containers:
        - name: worker
          image: ghcr.io/example/settlement-worker:1.14.2
          imagePullPolicy: IfNotPresent
          resources:
            requests:
              cpu: "250m"
              memory: "512Mi"
            limits:
              cpu: "1000m"
              memory: "1Gi"
          env:
            - name: SERVICEBUS_NAMESPACE
              value: sb-payments-prod.servicebus.windows.net
            - name: QUEUE_NAME
              value: settlements
            - name: MAX_INFLIGHT
              value: "8"
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 10
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /readyz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 5
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "/app/drain.sh && sleep 15"]
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: settlement-worker
  namespace: settlement
  annotations:
    azure.workload.identity/client-id: 00000000-0000-0000-0000-000000000000
---
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: servicebus-auth
  namespace: settlement
spec:
  podIdentity:
    provider: azure-workload
    identityId: 00000000-0000-0000-0000-000000000000
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: settlement-worker
  namespace: settlement
spec:
  scaleTargetRef:
    name: settlement-worker
  # Unlike the Functions scale controller, every one of these knobs is yours.
  # This is the concrete trade-off of hybrid serverless: more control,
  # more to operate.
  pollingInterval: 15
  cooldownPeriod: 120
  minReplicaCount: 0
  maxReplicaCount: 30
  fallback:
    failureThreshold: 3
    replicas: 2
  advanced:
    horizontalPodAutoscalerConfig:
      behavior:
        scaleDown:
          stabilizationWindowSeconds: 180
          policies:
            - type: Percent
              value: 50
              periodSeconds: 60
        scaleUp:
          stabilizationWindowSeconds: 0
          policies:
            - type: Percent
              value: 100
              periodSeconds: 15
  triggers:
    - type: azure-servicebus
      metadata:
        queueName: settlements
        namespace: sb-payments-prod
        messageCount: "20"
      authenticationRef:
        name: servicebus-auth
```

---

## 9. CLI: aprovisionamiento y verificación

### 9.1 Establecer el contexto y demostrar el autoservicio

```bash
$ az login --use-device-code
$ az account set --subscription "plat-payments-prod"
$ az account show -o table
```
```
Name                 CloudName    SubscriptionId                        TenantId                              State    IsDefault
-------------------  -----------  ------------------------------------  ------------------------------------  -------  -----------
plat-payments-prod   AzureCloud   1f9c3b62-7a41-4d0e-9b8c-2e5a7d13f004  72f988bf-86f1-41af-91ab-2d7cd011db47  Enabled  True
```

```bash
$ time az group create --name rg-payments-prod --location eastus \
    --tags cost-center=PLAT-4471 owner=platform-sre environment=prod -o table
```
```
Location    Name
----------  ----------------
eastus      rg-payments-prod

real    0m3.412s
user    0m1.088s
sys     0m0.141s
```

Tres segundos, sin ticket, sin ningún humano en Microsoft. Eso es **autoservicio bajo demanda**, demostrado en lugar de afirmado.

### 9.2 Verificar la agrupación de recursos y los límites de elasticidad

```bash
$ az account list-locations \
    --query "[?metadata.regionType=='Physical'].{Region:name, Geo:metadata.geographyGroup, Paired:metadata.pairedRegion[0].name}" \
    -o table | head -12
```
```
Region        Geo             Paired
------------  --------------  --------------
eastus        US              westus
eastus2       US              centralus
southcentralus US             northcentralus
westus2       US              westcentralus
westus3       US              eastus
westeurope    Europe          northeurope
northeurope   Europe          westeurope
uksouth       Europe          ukwest
swedencentral Europe          swedensouth
japaneast     Asia Pacific    japanwest
australiaeast Asia Pacific    australiasoutheast
brazilsouth   Latin America   southcentralus
```

Qué zonas tienen realmente tu SKU — el techo de elasticidad hecho concreto:

```bash
$ az vm list-skus --location eastus --resource-type virtualMachines \
    --query "[?name=='Standard_D4s_v5'].{SKU:name, Zones:locationInfo[0].zones, Restrictions:restrictions[].reasonCode}" \
    -o json
```
```json
[
  {
    "SKU": "Standard_D4s_v5",
    "Zones": [ "1", "2", "3" ],
    "Restrictions": []
  }
]
```

Un arreglo `Restrictions` vacío significa que actualmente no hay ninguna restricción de capacidad a nivel de suscripción o de zona. Un `NotAvailableForSubscription` acá es la advertencia temprana de que un `AllocationFailed` te está esperando en el momento del despliegue.

Headroom de cuota actual — el techo real de elasticidad:

```bash
$ az vm list-usage --location eastus \
    --query "[?contains(localName, 'DSv5') || localName=='Total Regional vCPUs'].{Name:localName, Used:currentValue, Limit:limit}" \
    -o table
```
```
Name                          Used    Limit
----------------------------  ------  -------
Total Regional vCPUs          212     350
Standard DSv5 Family vCPUs    136     200
```

### 9.3 Desplegar, con una corrida en seco primero

`what-if` es el equivalente en el control plane de `terraform plan`. Nunca despliegues a producción sin él.

```bash
$ az deployment group what-if \
    --resource-group rg-payments-prod \
    --template-file main.bicep \
    --parameters main.bicepparam
```
```
Note: The result may contain false positive predictions (noise).

Resource and property changes are indicated with these symbols:
  + Create
  ~ Modify

The deployment will update the following scope:

Scope: /subscriptions/1f9c3b62-.../resourceGroups/rg-payments-prod

  + Microsoft.Consumption/budgets/payments-monthly
  + Microsoft.Insights/components/appi-payments
  + Microsoft.OperationalInsights/workspaces/log-payments
  + Microsoft.Storage/storageAccounts/stpaymentsk3h9x2
  + Microsoft.Storage/storageAccounts/stpaymentsk3h9x2/blobServices/default
  + Microsoft.Storage/storageAccounts/stpaymentsk3h9x2/blobServices/default/containers/app-package
  + Microsoft.Web/serverfarms/plan-payments-flex
  + Microsoft.Web/sites/func-payments-k3h9

Resource changes: 8 to create.
```

```bash
$ az deployment group create \
    --name payments-$(git rev-parse --short HEAD) \
    --resource-group rg-payments-prod \
    --template-file main.bicep \
    --parameters main.bicepparam \
    --query "properties.{state:provisioningState, duration:duration, outputs:outputs}" \
    -o jsonc
```
```jsonc
{
  "state": "Succeeded",
  "duration": "PT2M17.8841203S",
  "outputs": {
    "budgetId": {
      "type": "String",
      "value": "/subscriptions/1f9c3b62-.../resourceGroups/rg-payments-prod/providers/Microsoft.Consumption/budgets/payments-monthly"
    },
    "functionAppHostname": {
      "type": "String",
      "value": "func-payments-k3h9.azurewebsites.net"
    },
    "functionAppName": {
      "type": "String",
      "value": "func-payments-k3h9"
    },
    "functionAppPrincipalId": {
      "type": "String",
      "value": "8b41d7e2-5c93-4a1e-b7f0-3d2a9e64c118"
    },
    "storageAccountName": {
      "type": "String",
      "value": "stpaymentsk3h9x2"
    }
  }
}
```

### 9.4 Aplicar la política de asignación de costos

```bash
$ az policy definition create \
    --name require-cost-center-tag \
    --display-name "Require a cost-center tag on resource groups" \
    --mode All \
    --rules @<(jq '.properties.policyRule' policy-require-cost-center.json) \
    --params @<(jq '.properties.parameters' policy-require-cost-center.json) \
    --query "{name:name, mode:mode}" -o table
```
```
Name                     Mode
-----------------------  ------
require-cost-center-tag  All
```

```bash
$ az policy assignment create \
    --name enforce-cost-center \
    --display-name "Enforce cost-center tag" \
    --policy require-cost-center-tag \
    --scope "/subscriptions/$(az account show --query id -o tsv)" \
    --query "{name:name, enforcementMode:enforcementMode}" -o table
```
```
Name                 EnforcementMode
-------------------  -----------------
enforce-cost-center  Default
```

Demostrar que el control plane deniega, y no solo audita:

```bash
$ az group create --name rg-untagged-test --location eastus
```
```
(RequestDisallowedByPolicy) Resource 'rg-untagged-test' was disallowed by policy.
Policy identifiers: '[{"policyAssignment":{"name":"Enforce cost-center tag",
"id":"/subscriptions/1f9c3b62-.../providers/Microsoft.Authorization/policyAssignments/enforce-cost-center"},
"policyDefinition":{"name":"Require a cost-center tag on resource groups",
"id":"/subscriptions/1f9c3b62-.../providers/Microsoft.Authorization/policyDefinitions/require-cost-center-tag"}}]'
Code: RequestDisallowedByPolicy
```

### 9.5 Demostrar el "servicio medido"

Registros de uso en crudo:

```bash
$ az consumption usage list \
    --start-date 2026-09-01 --end-date 2026-09-04 \
    --query "[?contains(instanceName, 'func-payments')].{Date:usageStart, Meter:meterDetails.meterName, Qty:usageQuantity, Unit:meterDetails.unitOfMeasure, Cost:pretaxCost}" \
    -o table
```
```
Date                 Meter                        Qty        Unit             Cost
-------------------  ---------------------------  ---------  ---------------  ---------
2026-09-01T00:00:00  Standard Execution Time      41823.0    10 GB Seconds    0.0669
2026-09-01T00:00:00  Standard Total Executions    2.14       10K              0.0004
2026-09-02T00:00:00  Standard Execution Time      52190.0    10 GB Seconds    0.0835
2026-09-02T00:00:00  Standard Total Executions    2.67       10K              0.0005
2026-09-03T00:00:00  Standard Execution Time      48771.0    10 GB Seconds    0.0780
2026-09-03T00:00:00  Standard Total Executions    2.49       10K              0.0005
```

Agregado, agrupado por servicio y por tu tag de asignación de costos. `cost-query.json`:

```json
{
  "type": "ActualCost",
  "timeframe": "MonthToDate",
  "dataset": {
    "granularity": "None",
    "aggregation": {
      "totalCost": { "name": "Cost", "function": "Sum" }
    },
    "grouping": [
      { "type": "Dimension", "name": "ServiceName" },
      { "type": "TagKey", "name": "cost-center" }
    ],
    "filter": {
      "dimensions": {
        "name": "ResourceGroupName",
        "operator": "In",
        "values": [ "rg-payments-prod" ]
      }
    }
  }
}
```

```bash
$ SUB=$(az account show --query id -o tsv)
$ az rest --method post \
    --url "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.CostManagement/query?api-version=2023-11-01" \
    --headers "Content-Type=application/json" \
    --body @cost-query.json \
    --query "properties.rows" -o json
```
```json
[
  [ 812.4471, "Virtual Machines",             "cost-center", "PLAT-4471", "USD" ],
  [ 194.0233, "Azure SQL Database",           "cost-center", "PLAT-4471", "USD" ],
  [  61.8890, "Storage",                      "cost-center", "PLAT-4471", "USD" ],
  [  22.3104, "Log Analytics",                "cost-center", "PLAT-4471", "USD" ],
  [   9.7712, "Bandwidth",                    "cost-center", "PLAT-4471", "USD" ],
  [   4.9021, "Azure App Service",            "cost-center", "PLAT-4471", "USD" ]
]
```

Recomendaciones de reservation, derivadas de *tu* uso medido en lugar de una conjetura:

```bash
$ az rest --method get \
    --url "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Consumption/reservationRecommendations?api-version=2023-05-01&\$filter=properties/scope eq 'Single' and properties/lookBackPeriod eq 'Last30Days'" \
    --query "value[?properties.term=='P3Y'].{SKU:properties.skuName, Region:location, Qty:properties.recommendedQuantity, NetSavings:properties.netSavings, Term:properties.term}" \
    -o table
```
```
SKU              Region    Qty    NetSavings    Term
---------------  --------  -----  ------------  ------
Standard_D4s_v5  eastus    3      1622.41       P3Y
Standard_E8s_v5  eastus    1      1094.77       P3Y
```

Verificar que el guardarraíl de presupuesto realmente exista:

```bash
$ az consumption budget list --resource-group rg-payments-prod \
    --query "[].{Name:name, Amount:amount, Grain:timeGrain, Current:currentSpend.amount, Forecast:forecastSpend.amount}" \
    -o table
```
```
Name              Amount    Grain      Current    Forecast
----------------  --------  ---------  ---------  ----------
payments-monthly  2500.0    Monthly    1105.34    2711.06
```

El pronóstico supera el presupuesto. La notificación `Forecast_GreaterThan_100` se va a disparar — días antes de que el dinero se gaste. Ese es todo el sentido de un umbral de pronóstico.

### 9.6 Desplegar y ejercitar la capa serverless

```bash
$ func azure functionapp publish func-payments-k3h9 --python
```
```
Getting site publishing info...
[2026-09-04T11:02:18.441Z] Starting the function app deployment...
Creating archive for current directory...
Performing remote build for functions project.
Uploading 4.31 MB [######################################] 100%
Remote build succeeded!
Syncing triggers...
Functions in func-payments-k3h9:
    settle - [httpTrigger]
        Invoke url: https://func-payments-k3h9.azurewebsites.net/api/settle
    reconcile - [serviceBusTrigger]
```

Demostrar el escalado a cero, después medir el cold start:

```bash
$ az monitor metrics list \
    --resource "/subscriptions/$SUB/resourceGroups/rg-payments-prod/providers/Microsoft.Web/sites/func-payments-k3h9" \
    --metric FunctionExecutionCount \
    --interval PT1H --start-time 2026-09-04T02:00:00Z --end-time 2026-09-04T06:00:00Z \
    --aggregation Total \
    --query "value[0].timeseries[0].data[].{time:timeStamp, executions:total}" -o table
```
```
Time                        Executions
--------------------------  ------------
2026-09-04T02:00:00+00:00   0.0
2026-09-04T03:00:00+00:00   0.0
2026-09-04T04:00:00+00:00   0.0
2026-09-04T05:00:00+00:00   0.0
```

Cuatro horas, cero ejecuciones, cero cargo de cómputo bajo demanda. Compará con un App Service P1v3 en la misma ventana: 4 horas × $0.20 = **$0.80 por no hacer nada**, todas las noches, para siempre.

```bash
$ for i in 1 2 3; do
    curl -s -o /dev/null -w "attempt %{http_code}  total=%{time_total}s  ttfb=%{time_starttransfer}s\n" \
      "https://func-payments-k3h9.azurewebsites.net/api/settle?ref=probe-$i"
  done
```
```
attempt 200  total=2.874312s  ttfb=2.861044s     <-- cold start
attempt 200  total=0.081447s  ttfb=0.079902s     <-- warm
attempt 200  total=0.074219s  ttfb=0.072890s     <-- warm
```

Un cold start de ~2,8 s contra ~80 ms en caliente. **Esa brecha de 35× es el precio del escalado a cero**, y es el número que corresponde poner en tu discusión de SLO de latencia — no en una nota al pie.

### 9.7 Desplegar y verificar el camino híbrido

```bash
$ az connectedk8s connect --name onprem-edge-01 \
    --resource-group rg-payments-prod \
    --location eastus \
    --tags cost-center=PLAT-4471 environment=prod
```
```
This operation might take a while...

Step: 11:31:04: Do node validations
Step: 11:31:09: Checking if user can create ClusterRoleBindings
Step: 11:31:12: Determining the location for the connected cluster resource
Step: 11:31:41: Azure resource provisioning has begun.
Step: 11:33:02: Azure resource provisioning has finished.
Step: 11:33:04: Starting to install Azure arc agents on the Kubernetes cluster.
Step: 11:35:47: Azure Arc agents have been installed successfully.
```

```bash
$ az connectedk8s show -n onprem-edge-01 -g rg-payments-prod \
    --query "{name:name, distribution:distribution, agentVersion:agentVersion, connectivityStatus:connectivityStatus, lastConnectivityTime:lastConnectivityTime, totalNodeCount:totalNodeCount}" \
    -o jsonc
```
```jsonc
{
  "agentVersion": "1.19.4",
  "connectivityStatus": "Connected",
  "distribution": "k3s",
  "lastConnectivityTime": "2026-09-04T11:38:22.104000+00:00",
  "name": "onprem-edge-01",
  "totalNodeCount": 5
}
```

El clúster on-prem ahora es un recurso ARM. Confirmá que un único plano de gobernanza abarca ambos sustratos:

```bash
$ az resource list --resource-group rg-payments-prod \
    --query "[].{Name:name, Type:type, Location:location}" -o table
```
```
Name                  Type                                          Location
--------------------  --------------------------------------------  ----------
vmss-payments-baseline Microsoft.Compute/virtualMachineScaleSets    eastus
func-payments-k3h9    Microsoft.Web/sites                           eastus
stpaymentsk3h9x2      Microsoft.Storage/storageAccounts             eastus
onprem-edge-01        Microsoft.Kubernetes/connectedClusters         eastus
```

La última fila es un clúster en tu propio edificio, direccionable con el mismo RBAC, los mismos tags y las mismas asignaciones de Policy que las filas de arriba.

---

## 10. Verificación y diagnóstico de fallas

### 10.1 La escalera de verificación

El orden de los peldaños importa: todo lo que está por encima de un peldaño no vale nada si el peldaño de abajo está roto.

| # | Pregunta | Comando | Costo |
|---|---|---|---|
| 1 | ¿Estoy autenticado, en el tenant y la suscripción correctos? | `az account show -o table` | gratis |
| 2 | ¿Está registrado el resource provider? | `az provider show -n <NS> --query registrationState -o tsv` | gratis |
| 3 | ¿Tengo el RBAC para hacer esto? | `az role assignment list --assignee <id> --scope <scope> -o table` | gratis |
| 4 | ¿Policy va a denegar esto? | `az deployment group what-if …` | gratis |
| 5 | ¿Hay cuota y capacidad zonal? | `az vm list-usage`, `az vm list-skus … locationInfo[0].zones` | gratis |
| 6 | ¿El control plane lo aceptó? | `az deployment operation group list --query "[?properties.provisioningState!='Succeeded']"` | gratis |
| 7 | ¿El data plane realmente está sirviendo? | `curl`, `nc -vz`, sonda específica del servicio | gratis |
| 8 | ¿Está costando lo que predije? | `az consumption usage list`, consulta de Cost Management | gratis (con horas de latencia) |
| 9 | ¿Mi SLA compuesto es el que creo? | multiplicar los SLAs de los componentes a mano | gratis |

### 10.2 Catálogo de fallas

---

**Síntoma: `MissingSubscriptionRegistration`**

```
(MissingSubscriptionRegistration) The subscription is not registered to use
namespace 'Microsoft.App'. See https://aka.ms/rps-not-found for how to register
subscriptions.
Code: MissingSubscriptionRegistration
```

**Causa.** Los resource providers son opt-in *por suscripción*. Una suscripción nueva o aprovisionada por un SPN solo tiene registrado un conjunto por defecto. Este es un límite de *aprovisionamiento* de autoservicio, y es la falla de "funciona en mi suscripción" más común.

**Diagnóstico y solución:**
```bash
$ az provider show -n Microsoft.App --query registrationState -o tsv
NotRegistered

$ az provider register --namespace Microsoft.App --wait
$ az provider show -n Microsoft.App --query registrationState -o tsv
Registered
```

**Prevención.** Registrá todos los providers de los que dependés en el bootstrap de la landing zone, antes de cualquier despliegue de carga de trabajo. `az provider list --query "[?registrationState=='Registered'].namespace" -o tsv` te da la línea base a codificar.

---

**Síntoma: `429 TooManyRequests` desde ARM; la automatización se traba; las hojas del portal se cuelgan**

**Causa.** Throttling del control plane. ARM aplica un límite de token bucket por principal, por región, por resource provider. Una matriz de CI, un bucle de reconciliación sin backoff, o un script de monitoreo que consulta cada segundo van a vaciar el bucket.

**Diagnóstico:**
```bash
$ az rest --method get \
    --url "https://management.azure.com/subscriptions/$SUB/resourcegroups?api-version=2021-04-01" \
    --debug 2>&1 | grep -i 'x-ms-ratelimit'
```
```
msrest.http_logger:     'x-ms-ratelimit-remaining-subscription-reads': '11842'
msrest.http_logger:     'x-ms-ratelimit-remaining-subscription-global-reads': '3711'
```

Un valor que tiende a cero a lo largo de llamadas sucesivas es el indicador adelantado. Cuando te throttlean obtenés:

```
(TooManyRequests) The request is being throttled. Retry after 27 seconds.
Code: TooManyRequests
```

Encontrá al llamador ruidoso en el Activity Log:
```bash
$ az monitor activity-log list --offset 1h \
    --query "[?httpRequest!=null].{caller:caller, op:operationName.value, status:status.value}" \
    -o table | sort | uniq -c | sort -rn | head -5
```
```
   4127 mysvc-ci@example.com  Microsoft.Compute/virtualMachines/read  Succeeded
    118 alice@example.com     Microsoft.Web/sites/read                Succeeded
```

**Solución.** Respetá `Retry-After`. Agregá backoff exponencial con jitter. Agrupá las lecturas con Azure Resource Graph (`az graph query -q "Resources | where type =~ 'microsoft.compute/virtualmachines'"`) en lugar de hacer `GET`s por recurso — Resource Graph es un camino de lectura separado, de throughput mucho más alto, construido precisamente para esto.

**Nota crítica de incidente.** Durante el throttling de ARM, **las cargas de trabajo ya en ejecución no se ven afectadas.** No declares una caída visible para el cliente basándote solo en síntomas del control plane. Verificá el data plane de manera independiente (§10.1 peldaño 7) antes de escalar.

---

**Síntoma: `AllocationFailed` / `ZonalAllocationFailed`**

```
(ZonalAllocationFailed) Allocation failed. We do not have sufficient capacity for
the requested VM size in this zone. Read more about improving likelihood of
allocation success at http://aka.ms/allocation-guidance
Code: ZonalAllocationFailed
```

**Causa.** La "elasticidad rápida" es estadística. La capacidad regional/zonal para una familia de SKU específica es finita en ese momento. Más probable en SKUs grandes, SKUs con GPU y series recién anunciadas.

**Diagnóstico:**
```bash
$ az vm list-skus --location eastus --size Standard_ND96 --all \
    --query "[].{SKU:name, Zone:locationInfo[0].zones, Reason:restrictions[0].reasonCode}" -o table
```
```
SKU                       Zone            Reason
------------------------  --------------  -------------------------------
Standard_ND96asr_v4       ['1', '2']      NotAvailableForSubscription
```

**Solución, en orden de preferencia.** (1) Probá otra zona o una SKU adyacente de la misma familia. (2) Probá otra región. (3) Para cargas de trabajo que deben tener capacidad garantizada, comprá una **Capacity Reservation** — notá que una *reservation* (descuento de facturación) y una *capacity reservation* (asignación garantizada) son **productos distintos**; comprar una Reserved Instance **no** garantiza capacidad. (4) Reintentá con backoff; la capacidad es transitoria.

---

**Síntoma: pico de costo inexplicado; pronóstico de presupuesto excedido**

**Diagnóstico — acotá por dimensión, después por recurso:**
```bash
$ cat spike-query.json
{
  "type": "ActualCost",
  "timeframe": "Custom",
  "timePeriod": { "from": "2026-08-25T00:00:00Z", "to": "2026-09-03T23:59:59Z" },
  "dataset": {
    "granularity": "Daily",
    "aggregation": { "totalCost": { "name": "Cost", "function": "Sum" } },
    "grouping": [ { "type": "Dimension", "name": "MeterCategory" } ]
  }
}

$ az rest --method post \
    --url "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.CostManagement/query?api-version=2023-11-01" \
    --body @spike-query.json --query "properties.rows" -o tsv | sort -k2
```
```
41.2201   20260825  Bandwidth   USD
39.8817   20260826  Bandwidth   USD
40.5514   20260827  Bandwidth   USD
38.9903   20260828  Bandwidth   USD
417.6620  20260829  Bandwidth   USD
502.1188  20260830  Bandwidth   USD
498.7745  20260831  Bandwidth   USD
```

Un salto de 10× en el medidor **Bandwidth** el 2026-08-29. Bandwidth significa **egreso**. Correlacionalo con un despliegue:

```bash
$ az monitor activity-log list --offset 10d \
    --query "[?operationName.value=='Microsoft.Resources/deployments/write' && status.value=='Succeeded'].{time:eventTimestamp, rg:resourceGroupName, name:resourceId}" \
    -o table | grep '2026-08-29'
```
```
2026-08-29T09:14:02+00:00  rg-payments-prod  .../deployments/payments-a91f3c2
```

**Patrón de causa raíz.** Un despliegue movió un componente entre regiones (o se deshabilitó una caché), convirtiendo tráfico intra-región gratuito en egreso cobrado entre regiones o a internet. Esta es la sorpresa más común en una factura de Azure y es invisible en los diagramas de arquitectura — **el egreso no aparece como una caja, solo como una flecha.**

**Prevención.** Alertas de pronóstico de presupuesto (§8.1), alertas de anomalías de Cost Management, y un chequeo de CI que falle un plan que introduzca un camino de datos entre regiones.

---

**Síntoma: la latencia p99 tiene una cola larga; el p50 está bien**

**Causa.** Cold starts en una capa que escala a cero, o retraso de la rampa de scale-out.

**Diagnóstico (KQL en Application Insights / Log Analytics). Esto es una heurística — atribuye a "cold" cualquier request servido dentro de los 10 s posteriores al arranque de un host en la misma instancia de rol:**

```kusto
let window = 24h;
let coldWindow = 10s;
let hostStarts =
    traces
    | where timestamp > ago(window)
    | where message startswith "Host started"
    | project startTime = timestamp, cloud_RoleInstance;
requests
| where timestamp > ago(window)
| where cloud_RoleName == "func-payments-k3h9"
| join kind=leftouter hostStarts on cloud_RoleInstance
| extend isCold = isnotempty(startTime) and (timestamp - startTime) between (0s .. coldWindow)
| summarize
    total          = count(),
    coldCount      = countif(isCold),
    p50_warm_ms    = percentileif(duration, 50, not(isCold)),
    p95_warm_ms    = percentileif(duration, 95, not(isCold)),
    p95_cold_ms    = percentileif(duration, 95, isCold)
  by bin(timestamp, 1h)
| extend coldPct = round(100.0 * coldCount / total, 2)
| order by timestamp asc
```

| timestamp | total | coldCount | p50_warm_ms | p95_warm_ms | p95_cold_ms | coldPct |
|---|---:|---:|---:|---:|---:|---:|
| 2026-09-04T02:00 | 14 | 9 | 78 | 141 | 3104 | 64.29 |
| 2026-09-04T03:00 | 11 | 8 | 81 | 152 | 2988 | 72.73 |
| 2026-09-04T09:00 | 21411 | 37 | 74 | 138 | 2871 | 0.17 |
| 2026-09-04T10:00 | 26890 | 12 | 72 | 131 | 2790 | 0.04 |

Leelo correctamente: los cold starts son el **64–73 % de los requests en el valle nocturno** y **menos del 0,2 % durante el horario laboral**. El número absoluto de usuarios afectados es chico; la *tasa* es terrible para cualquiera que pegue a la API a las 03:00.

**Solución, ordenada por costo:**

| Solución | Costo | Efecto |
|---|---|---|
| Podar dependencias / achicar el paquete | Gratis | Reduce la magnitud del cold start entre 30–60 % en la práctica |
| Mover la inicialización al ámbito de módulo | Gratis | Se amortiza entre invocaciones calientes |
| `alwaysReady: 1` de Flex Consumption | Línea base fija pequeña | Elimina el cold start para los primeros *N* requests concurrentes |
| Plan Premium, instancias precalentadas | Costo completo de siempre encendido | Elimina el cold start por completo; **deja de ser serverless** |
| Aceptarlo | Gratis | La respuesta correcta para capas asíncronas/batch; equivocada para rutas sincrónicas de cara al usuario |

---

**Síntoma: las funciones tienen éxito bajo carga liviana, fallan con errores de conexión bajo ráfaga**

```
[Error] Function 'settle' failed: (18456) Login failed for user 'app'.
Reason: The server is not currently available for connection.
```
o
```
FATAL: remaining connection slots are reserved for non-replication superuser connections
```

**Causa.** El problema del fan-out de §7.4. El scale controller agregó instancias; cada una abrió un pool de conexiones; el agregado excedió el límite de conexiones de la base de datos.

**Diagnóstico:**
```bash
$ az monitor metrics list \
    --resource "/subscriptions/$SUB/resourceGroups/rg-payments-prod/providers/Microsoft.Sql/servers/sql-payments/databases/payments" \
    --metric connection_failed sessions_percent \
    --interval PT5M --aggregation Maximum \
    --start-time 2026-09-04T09:00:00Z --end-time 2026-09-04T10:00:00Z \
    --query "value[].{metric:name.value, max:timeseries[0].data[-1].maximum}" -o table
```
```
Metric             Max
-----------------  ------
connection_failed  418.0
sessions_percent   100.0
```

**Solución.** Topeá la concurrencia en el *origen*, no en el destino:
- Flex Consumption: bajá `maximumInstanceCount` y `perInstanceConcurrency` (ambos están en §8.1).
- Plan Consumption: seteá `functionAppScaleLimit`, y para triggers de cola reducí `batchSize` en `host.json`.
- Reutilizá un único pool de conexiones de ámbito de módulo por instancia; nunca abras una conexión dentro del handler.
- Poné una cola acotada entre la función y la base de datos, para que la contrapresión se exprese como latencia en lugar de errores.

`host.json`:

```json
{
  "version": "2.0",
  "functionTimeout": "00:05:00",
  "logging": {
    "applicationInsights": {
      "samplingSettings": {
        "isEnabled": true,
        "maxTelemetryItemsPerSecond": 20,
        "excludedTypes": "Request;Exception"
      }
    },
    "logLevel": {
      "default": "Information",
      "Host.Results": "Information",
      "Function": "Information",
      "Host.Aggregator": "Information"
    }
  },
  "extensions": {
    "http": {
      "routePrefix": "api",
      "maxConcurrentRequests": 16,
      "maxOutstandingRequests": 64,
      "dynamicThrottlesEnabled": true
    },
    "serviceBus": {
      "prefetchCount": 0,
      "messageHandlerOptions": {
        "autoComplete": false,
        "maxConcurrentCalls": 8,
        "maxAutoRenewDuration": "00:05:00"
      }
    }
  },
  "retry": {
    "strategy": "exponentialBackoff",
    "maxRetryCount": 5,
    "minimumInterval": "00:00:02",
    "maximumInterval": "00:01:00"
  }
}
```

---

**Síntoma: las instancias Spot desaparecen a mitad del trabajo; se pierde el trabajo**

**Causa.** Funciona según lo diseñado. Spot no tiene SLA y es desalojada por presión de capacidad con 30 segundos de aviso.

**Diagnóstico:**
```bash
$ az monitor activity-log list --offset 6h \
    --query "[?contains(operationName.value, 'preempt') || contains(operationName.value, 'deallocate')].{time:eventTimestamp, op:operationName.localizedValue, res:resourceId}" \
    -o table
```
```
Time                        Op                          Res
--------------------------  --------------------------  -------------------------------
2026-09-04T07:12:44+00:00   Preempt Virtual Machine     .../vmss-payments-burst_4
2026-09-04T07:12:44+00:00   Preempt Virtual Machine     .../vmss-payments-burst_7
```

**Solución.** No es "dejá de usar Spot" — la economía es demasiado buena (§6.2). En cambio:
1. Consultá Scheduled Events (§3.2) y actuá ante `Preempt` dentro de la ventana de 30 segundos: cordon+drain, checkpoint, reencolar.
2. Hacé que el trabajo sea idempotente y re-ejecutable para que una unidad perdida se reintente, no se corrompa.
3. Mezclá prioridades: una línea base de instancias regulares/reservadas más una capa de ráfaga con Spot (§8.2).
4. Nunca coloques capas con estado o críticas en latencia sobre Spot.

---

**Síntoma: híbrido — los recursos conectados con Arc aparecen como `Disconnected`**

**Causa.** El agente de Arc perdió conectividad saliente hacia Azure. Arc requiere HTTPS saliente (443) hacia un conjunto definido de endpoints; el agente late regularmente y se marca como `Disconnected` tras una interrupción sostenida.

**Diagnóstico, en la máquina:**
```bash
$ sudo azcmagent show
```
```
Resource Name          : onprem-app-07
Resource Group Name    : rg-payments-prod
Subscription ID        : 1f9c3b62-7a41-4d0e-9b8c-2e5a7d13f004
Agent Version          : 1.49.02623.1234
Agent Status           : Disconnected
Agent Last Heartbeat   : 2026-09-04T04:11:07Z
Dependent Service Status:
  Agent Service (himdsd)               : active
  GC Service (gcad)                    : active
  Extension Service (extd)             : active
```

```bash
$ sudo azcmagent check --location eastus
```
```
Checking connectivity to endpoints...

Endpoint                                         Reachable
-----------------------------------------------  ----------
https://management.azure.com                     true
https://login.microsoftonline.com                true
https://eastus.his.arc.azure.com                 false
https://gbl.his.arc.azure.com                    true
https://<GUID>.agentsvc.azure-automation.net     false

2 of 5 endpoints are not reachable.
```

**Solución.** Dos endpoints regionales están bloqueados en el firewall de egreso. Ponelos en la lista de permitidos (o usá el service tag `AzureArcInfrastructure` / el Arc gateway), y después `sudo azcmagent connect --resource-group … --tenant-id … --location eastus`.

**La lección.** El híbrido devuelve a tu órbita la responsabilidad por la *accesibilidad de red hacia el control plane*. En la nube pública pura, ese camino es de Microsoft. Este es exactamente el desplazamiento de responsabilidad compartida que el modelo predice — el híbrido no parte la diferencia en carga operativa, **agrega** una capa.

---

## 11. Resumen orientado al examen

Respuestas comprimidas. Cada una se deriva de las secciones anteriores.

| Consigna | Respuesta |
|---|---|
| Definir computación en la nube | Entrega de servicios de computación (cómputo, almacenamiento, bases de datos, redes, software, análisis, inteligencia) a través de internet, sobre una base de pago por uso |
| Cinco características NIST | Autoservicio bajo demanda · acceso amplio por red · agrupación de recursos · elasticidad rápida · servicio medido |
| ¿Qué responsabilidades son *siempre* del cliente? | Información y datos · dispositivos · cuentas e identidades |
| ¿Qué responsabilidades son *siempre* de Microsoft en cualquier modelo de nube? | Hosts físicos · red física · datacenter físico |
| ¿Quién es dueño del OS en IaaS? ¿Y en PaaS? | IaaS: **el cliente**. PaaS: **Microsoft** |
| ¿Quién es dueño de las aplicaciones en PaaS? | **Compartido** |
| Nube pública | Propiedad del proveedor, multi-tenant, sin CapEx, sin control del hardware |
| Nube privada | De una sola organización, puede ser on-prem u hospedada, control total, CapEx, vos parcheás todo |
| Nube híbrida | Pública + privada, unidas entre sí, la carga de trabajo se coloca según el requisito; habilitada por Azure Arc / Azure Local / ExpressRoute |
| Multicloud | Dos o más proveedores *públicos* — no es lo mismo que híbrida |
| CapEx vs OpEx | CapEx = capital por adelantado, depreciado; OpEx = operativo continuo, imputado al incurrirse. La nube es OpEx |
| Modelo basado en consumo | Pagás solo por lo que usás, sin costo inicial, sin penalidad por detenerte, dejás de pagar cuando dejás de usar |
| Pay-as-you-go | Sin compromiso, precio unitario más alto, máxima flexibilidad |
| Reserved instances | Compromiso de 1 o 3 años con un tipo de recurso/región específicos; el mayor descuento; te compromete con la forma |
| Savings plan | Compromiso de 1 o 3 años con un *gasto* por hora; descuento menor que una RI, mucho más flexible entre servicios y regiones |
| Spot | Capacidad sin usar con un descuento profundo, **desalojable con 30 s de aviso, sin SLA** |
| Azure Hybrid Benefit | Aplicar licencias elegibles existentes de Windows Server / SQL Server / RHEL / SLES para eliminar el cargo de licencia |
| Serverless | El proveedor administra completamente la infraestructura; escala automáticamente incluso **a cero**; se factura por ejecución, no por hora aprovisionada |
| Beneficios de serverless | Sin gestión de infraestructura, escalado automático, facturación de consumo real, rápido time to value |
| Desventajas de serverless | Cold start, límites de tiempo de ejecución, ausencia de estado requerida, tasa de escalado acotada, acoplamiento más profundo con la plataforma |
| Servicios serverless de Azure para nombrar | Azure Functions (Consumption / Flex Consumption), Azure Container Apps, Azure Logic Apps (Consumption), Azure Container Instances, Cosmos DB serverless, Azure SQL Database serverless |
| ¿Un plan Premium de App Service es serverless? | **No** — no escala a cero y factura capacidad aprovisionada |

**Las cinco frases que vale la pena llevarse a la sala de examen y a producción:**

1. Un SLA es un crédito de servicio, no una garantía, y las dependencias en serie lo multiplican hacia abajo.
2. La responsabilidad puede delegarse a Microsoft; **el riesgo no** — tus clientes te siguen paginando a vos.
3. El control plane y el data plane fallan de forma independiente; diagnosticalos de forma independiente.
4. "Elástico" significa *estadísticamente disponible*, acotado por cuota, capacidad regional y tasa de escalado.
5. Serverless intercambia latencia de cold start y costo a largo plazo por cero costo ocioso y cero trabajo de infraestructura — ese intercambio solo es correcto para cargas de trabajo cortas y con picos.

---

## Referencias

**Oficial de Microsoft — certificación y ruta de estudio**
- Guía de estudio AZ-900 (habilidades medidas, alcance autoritativo): https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900
- Microsoft Certified: Azure Fundamentals: https://learn.microsoft.com/en-us/credentials/certifications/azure-fundamentals/
- Módulo de Learn — Describe cloud computing: https://learn.microsoft.com/en-us/training/modules/describe-cloud-compute/
- Módulo de Learn — Describe the benefits of using cloud services: https://learn.microsoft.com/en-us/training/modules/describe-benefits-use-cloud-services/
- Módulo de Learn — Describe cloud service types: https://learn.microsoft.com/en-us/training/modules/describe-cloud-service-types/

**Responsabilidad compartida, fiabilidad y SLA**
- Responsabilidad compartida en la nube: https://learn.microsoft.com/en-us/azure/security/fundamentals/shared-responsibility
- Service Level Agreements (SLA) for Online Services: https://www.microsoft.com/licensing/docs/view/Service-Level-Agreements-SLA-for-Online-Services
- Gestión de continuidad del negocio en Azure: https://learn.microsoft.com/en-us/azure/reliability/business-continuity-management-program
- Availability zones y regiones: https://learn.microsoft.com/en-us/azure/reliability/availability-zones-overview
- Availability sets, fault domains y update domains: https://learn.microsoft.com/en-us/azure/virtual-machines/availability
- Mantenimiento y actualizaciones de VMs en Azure: https://learn.microsoft.com/en-us/azure/virtual-machines/maintenance-and-updates
- Scheduled Events para VMs Linux: https://learn.microsoft.com/en-us/azure/virtual-machines/linux/scheduled-events
- Azure Instance Metadata Service: https://learn.microsoft.com/en-us/azure/virtual-machines/instance-metadata-service

**Control plane, Azure Resource Manager y gobernanza**
- Descripción general de Azure Resource Manager: https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/overview
- Operaciones de control plane y data plane: https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/control-plane-and-data-plane
- Throttling de solicitudes de Resource Manager: https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/request-limits-and-throttling
- Límites, cuotas y restricciones de suscripción y servicios de Azure: https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/azure-subscription-service-limits
- Resource providers y tipos de recurso: https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/resource-providers-and-types
- Documentación de Bicep: https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/
- Operación what-if de despliegue: https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-what-if
- Descripción general de Azure Policy: https://learn.microsoft.com/en-us/azure/governance/policy/overview
- Descripción general de Azure Resource Graph: https://learn.microsoft.com/en-us/azure/governance/resource-graph/overview

**Modelos de despliegue e híbrido**
- NIST SP 800-145, *The NIST Definition of Cloud Computing*: https://csrc.nist.gov/publications/detail/sp/800-145/final
- Descripción general de Azure Arc: https://learn.microsoft.com/en-us/azure/azure-arc/overview
- Servidores habilitados para Azure Arc: https://learn.microsoft.com/en-us/azure/azure-arc/servers/overview
- Kubernetes habilitado para Azure Arc: https://learn.microsoft.com/en-us/azure/azure-arc/kubernetes/overview
- Requisitos de red para servidores habilitados para Arc: https://learn.microsoft.com/en-us/azure/azure-arc/servers/network-requirements
- Azure Local (antes Azure Stack HCI): https://learn.microsoft.com/en-us/azure/azure-local/overview
- Geografías, regiones y pares de regiones de Azure: https://learn.microsoft.com/en-us/azure/reliability/regions-overview

**Precios, consumo y gestión de costos**
- Descripción general de precios de Azure: https://azure.microsoft.com/en-us/pricing/
- Azure Pricing Calculator: https://azure.microsoft.com/en-us/pricing/calculator/
- Calculadora de Costo Total de Propiedad (TCO): https://azure.microsoft.com/en-us/pricing/tco/calculator/
- Documentación de Cost Management + Billing: https://learn.microsoft.com/en-us/azure/cost-management-billing/
- Entender el descuento de las reservations de Azure: https://learn.microsoft.com/en-us/azure/cost-management-billing/reservations/save-compute-costs-reservations
- Azure savings plan for compute: https://learn.microsoft.com/en-us/azure/cost-management-billing/savings-plan/savings-plan-compute-overview
- Azure Spot Virtual Machines: https://learn.microsoft.com/en-us/azure/virtual-machines/spot-vms
- Azure Hybrid Benefit: https://learn.microsoft.com/en-us/azure/cost-management-billing/scope-level/overview-azure-hybrid-benefit-scope
- Crear y administrar presupuestos: https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-acm-create-budgets
- Cost Management Query API: https://learn.microsoft.com/en-us/rest/api/cost-management/query/usage
- Precios de ancho de banda (transferencia de datos): https://azure.microsoft.com/en-us/pricing/details/bandwidth/
- Cuenta gratuita de Azure y servicios siempre gratuitos: https://azure.microsoft.com/en-us/free/

**Serverless**
- Serverless en Azure: https://azure.microsoft.com/en-us/solutions/serverless/
- Opciones de hosting de Azure Functions: https://learn.microsoft.com/en-us/azure/azure-functions/functions-scale
- Plan Consumption de Azure Functions: https://learn.microsoft.com/en-us/azure/azure-functions/consumption-plan
- Plan Flex Consumption de Azure Functions: https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-plan
- Escalado orientado a eventos en Azure Functions: https://learn.microsoft.com/en-us/azure/azure-functions/event-driven-scaling
- Buenas prácticas de rendimiento y fiabilidad para Azure Functions: https://learn.microsoft.com/en-us/azure/azure-functions/functions-best-practices
- Referencia de `host.json` (v2): https://learn.microsoft.com/en-us/azure/azure-functions/functions-host-json
- Descripción general de Azure Container Apps: https://learn.microsoft.com/en-us/azure/container-apps/overview
- Escalado en Azure Container Apps: https://learn.microsoft.com/en-us/azure/container-apps/scale-app
- Facturación de Azure Container Apps: https://learn.microsoft.com/en-us/azure/container-apps/billing
- Azure Cosmos DB serverless: https://learn.microsoft.com/en-us/azure/cosmos-db/serverless
- Capa serverless de Azure SQL Database: https://learn.microsoft.com/en-us/azure/azure-sql/database/serverless-tier-overview
- KEDA (Kubernetes Event-driven Autoscaling): https://keda.sh/docs/latest/concepts/

**Herramientas**
- Referencia de Azure CLI: https://learn.microsoft.com/en-us/cli/azure/reference-index
- `az consumption`: https://learn.microsoft.com/en-us/cli/azure/consumption
- `az costmanagement`: https://learn.microsoft.com/en-us/cli/azure/costmanagement
- `az connectedk8s`: https://learn.microsoft.com/en-us/cli/azure/connectedk8s
- Proveedor AzureRM de Terraform: https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs
- Referencia de Kusto Query Language: https://learn.microsoft.com/en-us/azure/data-explorer/kusto/query/