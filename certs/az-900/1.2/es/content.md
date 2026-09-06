# 1.2 Describir los beneficios del uso de servicios en la nube

**Certificación:** Microsoft Azure Fundamentals (AZ-900) — versión del temario 2026-07-20
**Dominio:** 1 — Describir conceptos de nube
**Peso en el examen:** 9.4

La guía de estudio oficial divide este objetivo en cuatro puntos:

- Describir los beneficios de la **alta disponibilidad** y la **escalabilidad** en la nube
- Describir los beneficios de la **confiabilidad** y la **previsibilidad** en la nube
- Describir los beneficios de la **seguridad** y la **gobernanza** en la nube
- Describir los beneficios de la **administrabilidad** en la nube

Esas cuatro palabras son la superficie del examen. Este documento las trata como lo que realmente son en producción: cuatro controles de ingeniería distintos, con salidas medibles, compromisos duros y modos de falla específicos. Toda afirmación de aquí en adelante es expresable como un comando que devuelve un número.

---

## 1. El problema de producción: por qué "beneficios" es una pregunta de arquitectura, no de marketing

Consideremos un sistema concreto: una API HTTP de cara al público que sirve 4.000 solicitudes/segundo en el pico, respaldada por una base de datos relacional, con un requisito de negocio de **99,99% de disponibilidad mensual** y un **RPO contractual de 15 minutos**.

Construido on-premises, el conjunto de restricciones se ve así:

- **La capacidad es una orden de compra.** Agregar cómputo significa un ciclo de aprovisionamiento de 6 a 14 semanas. Por lo tanto, dimensionás para *el pico más margen más crecimiento*, y pagás por ese silicio 24/7. La utilización medida en centros de datos empresariales tradicionales suele ubicarse bastante por debajo del 30%: compraste el 100% de la capacidad para usar un tercio.
- **La redundancia es un segundo edificio.** 99,99% significa sobrevivir a la pérdida de una alimentación eléctrica, un switch top-of-rack, una UPS y un circuito de refrigeración. Lograrlo on-prem significa una segunda instalación, un segundo camino de red, un segundo juego de licencias y un equipo capaz de ensayar la conmutación por error.
- **El dominio de falla es invisible.** No sabés, sin una auditoría física, si los dos hipervisores "redundantes" están en la misma PDU.
- **El costo es CapEx.** El dinero se gasta antes de servir la primera solicitud, se amortiza en 3–5 años y es irrecuperable si el producto fracasa.

La nube no elimina ninguno de estos problemas. Los **reexpresa como primitivas direccionables por API con un número contractual adjunto**. Ese es todo el conjunto de beneficios:

| Problema on-prem | Primitiva de nube | El número que te compra |
|---|---|---|
| Flota dimensionada al pico, ociosa el 70% del tiempo | Autoescalado / facturación por consumo | El costo sigue la carga, no el pronóstico |
| Segundo edificio para redundancia | Zonas de disponibilidad | SLA de 99,99% para VM, desplegado con un comando `az` |
| Dominios de falla invisibles | Zonas y dominios de falla como metadatos declarados | Podés *afirmar* el aislamiento en un manifiesto |
| Plazo de aprovisionamiento | Capacidad elástica | Minutos, limitados por la cuota — no semanas |
| CapEx hundido antes de los ingresos | OpEx / reservas / spot | El fracaso cuesta la tasa de gasto corriente, no el balance |
| Deriva de configuración entre centros de datos | ARM/Bicep/Terraform + Azure Policy | La deriva es detectable y denegable en el plano de control |
| "¿Estamos en cumplimiento?" respondido con una planilla | Estado de cumplimiento de políticas, Defender for Cloud | Un porcentaje consultable |

**El modelo mental crítico para el examen y para producción:** la nube provee *la capacidad* de alta disponibilidad, no la alta disponibilidad en sí. Una sola VM en Azure es menos disponible que un par HA on-prem bien administrado. El beneficio solo se materializa cuando desplegás a través de los dominios de falla que la plataforma expone. Esta distinción — capacidad versus resultado — es donde viven tanto las caídas reales como los distractores del examen.

---

## 2. Alta disponibilidad: la aritmética

### 2.1 Lo que un número de SLA realmente te cuesta en minutos

La disponibilidad es un porcentaje de un mes de facturación. Traducilo antes de aceptarlo.

| SLA | Caída / mes (30 d) | Caída / año | Lo que implica operativamente |
|---|---|---|---|
| 99% ("dos nueves") | 7 h 12 min | 3,65 días | Una sola instancia, recuperación manual, guardia en horario laboral |
| 99,5% | 3 h 36 min | 1,83 días | Territorio de VM única con HDD Estándar |
| 99,9% ("tres nueves") | 43,2 min | 8,76 h | Una instancia, pero recuperación automatizada rápida. Ningún humano llega a esto de forma confiable a las 03:00 |
| 99,95% | 21,6 min | 4,38 h | Redundancia dentro de un solo centro de datos (conjunto de disponibilidad) |
| 99,99% ("cuatro nueves") | 4,32 min | 52,6 min | La redundancia de zona es **obligatoria**. La detección sola debe ser < 60 s |
| 99,999% ("cinco nueves") | 25,9 s | 5,26 min | Multi-región activo/activo. Ningún humano en el camino de recuperación |

Leé la fila del 99,99% con atención: **4,32 minutos por mes es menos tiempo del que le lleva a una persona leer un aviso y abrir la laptop.** Cualquier valor por encima de 99,95% es una afirmación sobre automatización, no sobre hardware.

### 2.2 La escalera del SLA de VM de Azure

El SLA de cómputo de Azure no es un número único — está escalonado según los dominios de falla en los que desplegás. Esta tabla es el dato de mayor rendimiento de este objetivo.

| Topología de despliegue | SLA mensual | Dominio de falla soportado | Multiplicador de costo |
|---|---|---|---|
| VM única, discos Standard HDD | 95% | Nada significativo | 1× |
| VM única, discos Standard SSD | 99,5% | Nada (reinicio del host = caída) | 1× |
| VM única, **todos** los discos de SO+datos Premium SSD / Premium SSD v2 / Ultra | 99,9% | Nada (el mantenimiento planificado del host igual te afecta) | ~1,1× |
| 2+ VM en un **conjunto de disponibilidad** (dominios de falla + actualización) | 99,95% | Rack/PDU/switch ToR, oleadas de actualización del host | 2× |
| 2+ VM en 2+ **zonas de disponibilidad** | **99,99%** | Centro de datos completo: energía, refrigeración, red | 2–3× (más latencia entre zonas) |

**Mecánica que importa:**

- Un **conjunto de disponibilidad** distribuye las VM entre *dominios de actualización* (parcheados en oleadas, de modo que Azure nunca reinicia todas tus instancias a la vez) y *dominios de falla* (rack, energía y red distintos). Protege contra fallas de nivel rack y de mantenimiento. **No** protege contra un centro de datos que pierde energía, porque todos los dominios de falla están en el mismo edificio.
- Una **zona de disponibilidad** es una ubicación físicamente separada dentro de una región, con energía, refrigeración y red independientes. Las regiones habilitadas en Azure tienen un mínimo de tres zonas, lo bastante cerca como para que la replicación síncrona sea viable (la latencia de ida y vuelta está diseñada para mantenerse en el rango de milisegundos de un solo dígito) y lo bastante lejos como para ser dominios de falla independientes.
- **Zonal vs redundante de zona** es una distinción sobre la que los servicios de Azure se dividen:
  - *Zonal* — el recurso está anclado a una zona (una VM, un disco administrado, un NAT Gateway). Obtenés aislamiento, pero tenés que desplegar N de ellos vos mismo.
  - *Redundante de zona* — el servicio replica entre zonas internamente y presenta un único punto de conexión (almacenamiento ZRS, Application Gateway v2 redundante de zona, frontends de Standard Load Balancer, Azure SQL Database redundante de zona). Obtenés resiliencia sin ser dueño de la lógica de distribución.

- **Trampa avanzada — las zonas lógicas son por suscripción.** "Zona 1" no es un lugar físico. Azure mapea los identificadores lógicos de zona a zonas físicas *de forma distinta para cada suscripción*, precisamente para evitar que todos los inquilinos se apilen en la zona física 1. Dos suscripciones que despliegan en `eastus` zona 1 pueden terminar en edificios diferentes. Si estás correlacionando una caída entre suscripciones, o colocando deliberadamente cargas sensibles a la latencia pertenecientes a suscripciones distintas, tenés que resolver el mapeo físico (comando en §6.2).

### 2.3 SLA compuesto: la disponibilidad es multiplicativa en serie

El SLA de un sistema no es el SLA de su mejor componente. Las dependencias en serie se multiplican.

Un camino de solicitud típico de tres capas:

```
Application Gateway v2 (zone-redundant, 99.95%)
        │
        ▼
App Service Plan, Premium v3 (99.95%)
        │
        ▼
Azure SQL Database, zone-redundant Business Critical (99.99%)
```

$$\text{SLA}_{\text{composite}} = 0.9995 \times 0.9995 \times 0.9999 = 0.99890$$

**99,89%** — aproximadamente **47,5 minutos de caída permitida por mes**. Cada componente cumplió su SLA; el sistema no alcanzó el 99,9%. Por eso "usamos solo servicios de cuatro nueves" no es un argumento de disponibilidad.

Agregar un camino redundante en **paralelo** invierte la matemática — multiplicás las probabilidades de *falla*:

$$\text{SLA}_{\text{parallel}} = 1 - (1 - 0.99890)^2 = 0.99999879$$

Pero esa pila paralela debe estar precedida por un enrutador global de tráfico, que vuelve a entrar en la serie:

$$\text{SLA}_{\text{total}} = 0.9999 \times 0.99999879 \approx 0.99989$$

**Conclusión:** una segunda región te llevó de 99,89% a 99,989% — una reducción de 10× en el tiempo de caída esperado — y el techo ahora lo fija enteramente el propio 99,99% de Azure Front Door. Duplicar el gasto en infraestructura compró exactamente un nueve, y ninguna arquitectura adicional superará la puerta de entrada. Esa es la tabla de compromisos que llevás al negocio:

| Arquitectura | SLA compuesto | Caída/mes | Costo relativo de infra | Complejidad operativa |
|---|---|---|---|---|
| VM única, discos Premium, una zona | 99,9% (solo cómputo) | 43,2 min | 1× | Baja |
| Conjunto de disponibilidad, una zona | 99,95% | 21,6 min | 2× | Baja |
| Redundante de zona, una región, 3 capas | 99,89% (compuesto) | 47,5 min | 2,5× | Media |
| Redundante de zona + réplica de lectura, activo/pasivo 2 regiones | ~99,95% (domina el tiempo de failover) | ~22 min | 3,5× | Alta — el failover debe ensayarse |
| Activo/activo 2 regiones detrás de Front Door | ~99,989% | ~4,8 min | 5× | Muy alta — la consistencia de datos pasa a ser el problema difícil |

La fila que atrapa a los equipos es la cuarta: **una región activo/pasivo no entrega su SLA teórico salvo que el failover sea automático y esté probado.** Una región de DR sin probar es un centro de costos, no un control de disponibilidad.

### 2.4 Opciones de distribución global de tráfico

| Servicio | Capa OSI | Alcance | Mecanismo de failover | Granularidad del health-check | Usalo para |
|---|---|---|---|---|---|
| Azure Load Balancer (Standard) | L4 (TCP/UDP) | Regional | Sondeo del backend pool | Por endpoint TCP/HTTP | Distribución de VM/VMSS intra-región, frontend redundante de zona |
| Application Gateway v2 | L7 (HTTP) | Regional | Sondeo de salud del backend + WAF | Por ruta / por backend pool | Enrutamiento L7 regional, terminación TLS, WAF |
| Azure Front Door | L7 (HTTP, borde anycast) | Global | Sondeos de salud en el borde + retiro de anycast | Por origen, por ruta | Punto de entrada HTTP global, caché en el borde, WAF global |
| Traffic Manager | DNS | Global | Cambio de registro DNS | Por endpoint | Protocolos no HTTP, o enrutamiento global donde la latencia del TTL de DNS es aceptable |

**Compromiso a internalizar:** Traffic Manager conmuta cambiando las respuestas DNS, así que el tiempo de recuperación tiene como cota inferior el cacheo del TTL de DNS en el cliente — y muchos resolvers y JVM ignoran los TTL. Front Door conmuta dentro del borde anycast, así que el cacheo del lado del cliente es irrelevante. Si tu RTO se mide en segundos, Traffic Manager es la herramienta equivocada para HTTP.

---

## 3. Escalabilidad y elasticidad

### 3.1 Las tres palabras que el examen separa

- **Escalabilidad** — la capacidad de agregar recursos para manejar una carga mayor.
- **Elasticidad** — la capacidad de agregarlos *y quitarlos* automáticamente a medida que cambia la carga. La elasticidad es escalabilidad más un lazo de control más granularidad de facturación.
- **Agilidad** — la velocidad a la que podés aprovisionar cualquier cosa. Es una propiedad de plazo de entrega, no de capacidad.

Un clúster VMware on-prem es escalable (podés agregar hosts) pero no elástico (no podés des-comprarlos a las 03:00 cuando cae el tráfico).

### 3.2 Vertical vs horizontal

| Dimensión | Vertical (escalar hacia arriba) | Horizontal (escalar hacia afuera) |
|---|---|---|
| Mecanismo | Redimensionar la instancia: `Standard_D2s_v5 → Standard_D16s_v5` | Agregar instancias detrás de un balanceador de carga |
| Tiempo de caída | Sí — ciclo de desasignación/reasignación de la VM (típicamente 1–5 min) | No |
| Requisito de la aplicación | Ninguno; funciona para monolitos con estado | Ausencia de estado, o estado de sesión externalizado |
| Cota superior | El SKU más grande disponible en esa región/zona (muro duro) | Cuota de la suscripción + límites del backend pool (blando, ampliable) |
| Efecto sobre la disponibilidad | **Negativo** — punto único de falla más grande | **Positivo** — la pérdida de una instancia se absorbe |
| Granularidad del costo | Gruesa — los tamaños de SKU aproximadamente se duplican | Fina — una instancia por vez |
| Recuperación ante falla | Toda la carga de trabajo caída | Capacidad N−1, degradada |
| Uso típico | Bases de datos, software atado a licencias, monolitos heredados | Capas web, API, workers sin estado, contenedores |

**Regla de producción:** escalá hacia arriba hasta que la máquina sea eficiente, escalá hacia afuera para disponibilidad. Una carga de trabajo que solo puede escalar verticalmente tiene un techo duro de disponibilidad sin importar qué SLA ofrezca la plataforma.

### 3.3 Mecánica del autoescalado de Azure — y por qué el autoescalado silenciosamente no hace nada

El autoescalado de Azure Monitor evalúa una regla con una cadencia fija. Cada campo de abajo es una causa real de "el autoescalado está habilitado pero la flota nunca creció":

| Parámetro | Significado | Mala configuración común |
|---|---|---|
| `timeGrain` | Intervalo de muestreo de la métrica de origen (`PT1M`) | Configurado más fino de lo que la métrica realmente publica → sin datos → sin evaluación |
| `timeWindow` | Ventana de retrospección agregada para la decisión (`PT5M`, mín. 5 min) | Configurada en 5 min para una carga con picos → promedia y borra el pico |
| `timeAggregation` | Cómo se combinan las muestras en la ventana (`Average`, `Max`) | `Average` oculta un subconjunto de instancias saturadas |
| `statistic` | Cómo se combinan las instancias (`Average`, `Max`, `Min`) | `Average` entre 10 instancias donde 2 están al tope = sin escalado hacia afuera |
| `cooldown` | Período de supresión tras una acción de escalado | Escalado hacia afuera `PT5M` con 4 min de arranque → oscilación; escalado hacia adentro `PT10M`+ es la asimetría segura |
| capacidad `maximum` | Techo duro | Ya en el máximo → el autoescalado evalúa, decide escalar, y falla |
| Cuota de vCPU de la suscripción | Límite regional por familia | La falla dura más común. Ver §6.5 |

**Regla de diseño — umbrales asimétricos.** Escalá hacia afuera con CPU > 70% y un cooldown corto; escalá hacia adentro con CPU < 30% y un cooldown largo. Si los dos umbrales están cerca (afuera en 70, adentro en 60), una flota que escala hacia afuera cae inmediatamente por debajo del umbral de escalado hacia adentro *porque escaló hacia afuera*, y obtenés un lazo de oscilación que cuesta dinero y desestabiliza los pools de conexiones. La brecha entre umbrales debe superar el delta de carga-por-instancia que produce un paso de escalado.

### 3.4 Capas de escalado en Kubernetes/AKS — tres lazos de control distintos

| Capa | Componente | Escala | Reacciona a | Latencia típica |
|---|---|---|---|---|
| Pod (métrica) | HorizontalPodAutoscaler | Cantidad de réplicas | Métricas de CPU/memoria/personalizadas | 15–60 s |
| Pod (evento) | KEDA | Cantidad de réplicas, incl. escalado a cero | Profundidad de cola, retraso de la fuente de eventos | 5–30 s |
| Nodo | Cluster Autoscaler | Cantidad de nodos en un node pool | **Pods no programables** | 1–4 min (aprovisionamiento de VM) |
| Nodo (vertical) | VerticalPodAutoscaler | Requests de recursos del Pod | Uso histórico | Minutos–horas |

El modo de falla que nadie predice: **el Cluster Autoscaler se dispara por pods pendientes, no por utilización.** Si tus pods no declaran `requests` de recursos, el planificador cree que el nodo tiene espacio infinito, los pods nunca quedan en `Pending`, y el Cluster Autoscaler nunca agrega un nodo — mientras los nodos existentes se destrozan hasta OOM. Los requests de recursos son la señal de entrada al autoescalado de nodos; omitirlos lo deshabilita.

---

## 4. Confiabilidad y previsibilidad

### 4.1 Confiabilidad ≠ disponibilidad

- **Disponibilidad** — ¿está respondiendo *ahora*?
- **Confiabilidad** — ¿seguirá comportándose correctamente en el tiempo, incluso a través de la falla y la recuperación?

La confiabilidad es lo que cubre el pilar de Confiabilidad del Azure Well-Architected Framework: diseñar para la falla, la redundancia y la recuperación. Se mide con dos números que deben escribirse en el diseño, no descubrirse durante un incidente:

| Métrica | Definición | La pregunta que responde | Qué la determina |
|---|---|---|---|
| **RTO** (Recovery Time Objective) | Tiempo máximo tolerable para restaurar el servicio | "¿Cuánto podemos estar caídos?" | Automatización del failover, DNS/anycast, standby tibio |
| **RPO** (Recovery Point Objective) | Pérdida de datos máxima tolerable, medida en tiempo | "¿Cuántos datos podemos perder?" | Modo de replicación: sync = 0, async = retraso de replicación |

**El compromiso duro:** RPO = 0 requiere replicación síncrona, lo que significa que cada escritura espera el acuse de recibo remoto. Entre zonas de disponibilidad (ms de un solo dígito) eso suele ser aceptable. Entre regiones (decenas a centenas de ms) normalmente no lo es — por eso la replicación entre regiones es asíncrona, y el RPO entre regiones *nunca* es cero. **No podés comprar RPO=0 entre regiones; solo podés achicar la ventana.**

### 4.2 Redundancia de almacenamiento — la matriz durabilidad/disponibilidad/costo

| Opción | Copias | Ubicación | Durabilidad anual | SLA de lectura | Sobrevive pérdida de zona | Sobrevive pérdida de región | Costo relativo |
|---|---|---|---|---|---|---|---|
| **LRS** | 3 | Un centro de datos | 11 nueves | 99,9% (hot) | ✗ | ✗ | 1× |
| **ZRS** | 3 | Tres AZ, una región | 12 nueves | 99,9% (hot) | ✓ | ✗ | ~1,25× |
| **GRS** | 6 | 3 locales + 3 en la región emparejada (async) | 16 nueves | 99,9% (hot) | ✗ | ✓ (failover) | ~2× |
| **GZRS** | 6 | 3 zonas + 3 en la región emparejada (async) | 16 nueves | 99,9% (hot) | ✓ | ✓ (failover) | ~2,5× |
| **RA-GRS / RA-GZRS** | 6 | Como arriba + endpoint secundario legible | 16 nueves | **99,99%** lectura | como arriba | ✓ + lecturas inmediatas | ~2,2× / ~2,7× |

Dos consecuencias que los ingenieros pasan por alto de forma rutinaria:

1. **La geo-replicación es asíncrona.** La región secundaria va con retraso. Si la región primaria se pierde antes de que la replicación se complete, ese delta desaparece. GRS te da un RPO pequeño y distinto de cero — no cero.
2. **Las variantes `-RA-` existen porque el failover no es instantáneo.** Sin acceso de lectura, el secundario es invisible hasta que se completa un failover. Con RA-GRS, tu aplicación puede leer inmediatamente datos desactualizados-pero-disponibles desde el endpoint secundario (`<account>-secondary.blob.core.windows.net`) mientras la primaria está degradada. Esa es la diferencia entre un modo degradado de solo lectura y una caída total.

### 4.3 Regiones, pares de regiones y soberanía

- Una **región** es un conjunto de centros de datos dentro de un perímetro definido por latencia.
- Un **par de regiones** es una segunda región en la misma geografía (usualmente a ≥ 300 millas de distancia) usada para geo-replicación y actualizaciones escalonadas de la plataforma — Azure no despliega una actualización a ambas mitades de un par simultáneamente.
- **No trates el emparejamiento como universal.** Las regiones más nuevas se lanzan sin un par tradicional, algunos emparejamientos no son simétricos, y Azure viene moviéndose hacia la resiliencia basada en zonas de disponibilidad como modelo principal. Verificá el emparejamiento por región contra la documentación actual en lugar de asumirlo.
- Las **nubes soberanas** (Azure Government, Azure China operada por 21Vianet) son instancias física y lógicamente separadas de Azure, con sus propios planos de control y endpoints — un beneficio de residencia de datos y cumplimiento, no meramente una región.

### 4.4 Previsibilidad: la segunda mitad del punto

El examen divide la previsibilidad en dos:

**Previsibilidad de rendimiento** — el autoescalado, el balanceo de carga y el pilar de Eficiencia del Rendimiento del Well-Architected significan que la capacidad sigue a la demanda en lugar de degradarse bajo ella.

**Previsibilidad de costos** — el costo sigue al consumo y es *pronosticable*, monitoreable y exigible mediante presupuestos. Acá es donde el cambio CapEx→OpEx se vuelve concreto:

| Modelo | Compromiso | Descuento típico vs pago por uso | Flexibilidad | Adecuado para |
|---|---|---|---|---|
| **Pago por uso** | Ninguno | línea base | Total | Cargas con picos, no probadas o de corta vida |
| **Instancias reservadas** | 1 o 3 años, serie de VM + región específicas | hasta ~72% | Flexibilidad de tamaño de instancia dentro de la serie; aplican políticas de intercambio/reembolso | Línea base de estado estable de la que estás seguro |
| **Plan de ahorro para cómputo** | 1 o 3 años, compromiso de $ por hora | hasta ~65% | Se aplica entre series, regiones y algunos servicios de cómputo | Gasto estable con forma incierta |
| **VM Spot** | Ninguno | hasta ~90% | **Desalojables con 30 s de aviso** | Batch, CI, renderizado, workers tolerantes a fallas |
| **Azure Hybrid Benefit** | Licencias existentes de Windows Server / SQL Server con Software Assurance | Grande; se acumula con reservas | Atado a licencias | Migrar parques licenciados existentes |
| **Precios Dev/Test** | Tipos de suscripción elegibles | Tarifas reducidas, sin cargo por licencia de Windows | Solo no producción | Entornos inferiores |

**Compromiso:** las reservas dan el descuento más profundo y la menor flexibilidad; los planes de ahorro cambian ~7 puntos de descuento por la libertad de cambiar de familia de VM y de región. Ambos son una apuesta a una *línea base*. El patrón correcto es: reservá el piso, pagá por uso la banda variable, spot la banda interrumpible.

**El cambio de capital, dicho con precisión:** el CapEx se gasta antes de los ingresos y se amortiza; el OpEx se gasta a medida que se consume el servicio y es un costo operativo deducible en el período en que se incurre. El beneficio estratégico no es que la nube sea más barata — frecuentemente no lo es en estado estable — es que **el costo de equivocarse está acotado por la tasa de gasto corriente en lugar de por un cronograma de amortización.**

---

## 5. Seguridad, gobernanza y administrabilidad

### 5.1 Responsabilidad compartida — la tabla que decide a quién llaman

| Responsabilidad | On-premises | IaaS | PaaS | SaaS |
|---|---|---|---|---|
| Información y datos | Cliente | Cliente | Cliente | Cliente |
| Dispositivos (móviles, endpoints) | Cliente | Cliente | Cliente | Cliente |
| Cuentas e identidades | Cliente | Cliente | Cliente | Cliente |
| Infraestructura de identidad y directorio | Cliente | **Compartida** | **Compartida** | Microsoft |
| Aplicaciones | Cliente | Cliente | **Compartida** | Microsoft |
| Controles de red | Cliente | Cliente | **Compartida** | Microsoft |
| Sistema operativo | Cliente | **Cliente** | Microsoft | Microsoft |
| Hosts físicos | Cliente | Microsoft | Microsoft | Microsoft |
| Red física | Cliente | Microsoft | Microsoft | Microsoft |
| Centro de datos físico | Cliente | Microsoft | Microsoft | Microsoft |

Dos filas son absolutas y son material garantizado de examen:

- **Las tres de abajo son siempre de Microsoft**, en todos los modelos de servicio.
- **Las tres de arriba son siempre tuyas**, en todos los modelos de servicio — incluido SaaS. Nadie más va a clasificar tus datos ni a desaprovisionar la cuenta de alguien que se fue.

Las filas del medio son las que se mueven, y la dirección del movimiento *es* el gradiente IaaS→PaaS→SaaS. Pasar de IaaS a PaaS transfiere el parcheo del SO a Microsoft — eso es una reducción real de superficie operativa, y también es una reducción real de control. No podés instalar un módulo de kernel en App Service.

### 5.2 Gobernanza: la jerarquía del plano de control

```
Management group  ──► Policy, RBAC inherit downward
      │
      ├── Management group (e.g. "Production")
      │        │
      │        └── Subscription  ──► billing + quota boundary
      │                 │
      │                 └── Resource group  ──► lifecycle + lock boundary
      │                          │
      │                          └── Resource
```

| Control | Aplica sobre | Efectos / modos | Dónde se dispara |
|---|---|---|---|
| **Azure Policy** | *Configuración* de recursos | `Deny`, `Audit`, `Modify`, `Append`, `DeployIfNotExists`, `AuditIfNotExists` | Plano de control, al momento del despliegue y de forma continua |
| **Azure RBAC** | *Quién* puede realizar *qué* operación sobre *qué* ámbito | Asignaciones de rol (integradas o personalizadas) | Cada solicitud ARM |
| **Bloqueos de recursos** | Eliminación/modificación accidental | `CanNotDelete`, `ReadOnly` | Plano de control, por encima de RBAC — un Owner igual queda bloqueado |
| **Etiquetas** | Metadatos para asignación de costos y propiedad | Pares nombre/valor; **no se heredan por defecto** — usá una política `Modify` para heredar del RG | Metadatos, consultados por Cost Management |
| **Deployment Stacks** | Ciclo de vida de un conjunto de recursos administrado, con configuración de denegación | `denySettingsMode: denyDelete / denyWriteAndDelete` | Plano de control (sucesor de Azure Blueprints, retirado el 11 de julio de 2026) |
| **Microsoft Defender for Cloud** | Puntaje de postura de seguridad, protección de cargas de trabajo | Recomendaciones, paneles de cumplimiento normativo | Evaluación continua |
| **Presupuestos de Cost Management** | Umbrales de gasto | Alertas, grupos de acción, disparadores de automatización | Datos de facturación (latencia de horas) |
| **Azure Resource Graph** | Nada — *responde* | KQL sobre todo el parque | Inventario de solo lectura a escala |

**El beneficio de gobernanza dicho con precisión:** on-prem, "todo el almacenamiento de producción debe ser redundante de zona" es un documento. En Azure es una política `Deny` asignada en un management group, y un despliegue no conforme **falla con un HTTP 403 en el plano de control antes de que el recurso exista**. Policy es el mecanismo que convierte un estándar en un invariante.

**RBAC vs Policy — una distinción garantizada de examen:** RBAC controla *quién* puede actuar. Policy controla *cómo* puede verse el recurso resultante. Un Owner con plenos derechos RBAC igual es denegado por una política que prohíbe el acceso público a blobs. Son ortogonales, y ambos se evalúan.

### 5.3 Beneficios de seguridad que son estructurales, no configurables

- **Defensa en profundidad** — físico → identidad → perímetro → red → cómputo → aplicación → datos. Cada capa asume que la de afuera falló.
- **Zero Trust** — verificar explícitamente, usar acceso de mínimo privilegio, asumir la brecha. En Azure esto es Microsoft Entra ID + Acceso Condicional + Privileged Identity Management (elevación de rol justo a tiempo) + identidades administradas.
- **Las identidades administradas eliminan una clase de credencial.** Una carga de trabajo con una identidad administrada asignada por el sistema obtiene tokens del endpoint de metadatos de la instancia. No hay secreto en el archivo de configuración, ni secreto en el pipeline, ni secreto que rotar, ni secreto que filtrar. Este es un beneficio de seguridad sin equivalente on-prem.
- **Azure Key Vault / Managed HSM** — almacenamiento centralizado de secretos, claves y certificados con claves respaldadas por hardware, políticas de acceso o RBAC, y registro de auditoría completo.
- **DDoS Protection** — la red de Azure absorbe ataques volumétricos a una escala que ningún inquilino individual podría aprovisionar. El nivel Basic es siempre activo y gratuito; los niveles Network/IP Protection agregan mitigación ajustada por recurso, telemetría y garantías de protección de costos.
- **Herencia de cumplimiento** — las certificaciones de Microsoft (ISO 27001, SOC 1/2/3, PCI DSS, FedRAMP, HIPAA y marcos regionales) aplican a la capa de plataforma. Heredás los controles auditados para las capas física y de hipervisor, y sos auditado solo sobre tus propias capas. Esa es una reducción genuina del alcance de auditoría — no una exención.

### 5.4 Administrabilidad: dos frases que el examen separa

**Administración *de* la nube** — cómo se administran a sí mismos los recursos de nube:
- Escalado automático en respuesta a la demanda
- Reparación automática de instancias y autorreparación (`automaticRepairsPolicy`)
- Desplegar desde plantillas para que un entorno se recree de forma idéntica
- Monitoreo, alertas y remediación automatizada de la plataforma (políticas `DeployIfNotExists`)

**Administración *en* la nube** — cómo *vos* interactuás con ella:
- Portal de Azure (GUI)
- Azure CLI (`az`) y Azure PowerShell (módulo `Az`)
- Azure Cloud Shell (alojado en el navegador, preautenticado)
- API REST y SDK de lenguajes
- Plantillas ARM / Bicep / Terraform — infraestructura como código declarativa

**El beneficio de IaC es la idempotencia, y la idempotencia es lo que hace real la DR.** Una plantilla declarativa aplicada dos veces produce el mismo resultado. Esa propiedad es lo que permite que "reconstruir el entorno en la región emparejada" sea una ejecución de pipeline en lugar de una reconstrucción de dos semanas a partir de la memoria tribal.

---

## 6. Manifiestos de infraestructura completos

### 6.1 Bicep — capa web redundante de zona, autorreparable y con autoescalado

Despliega: espacio de trabajo de Log Analytics, VNet, Standard Load Balancer redundante de zona con sondeo de salud y regla de salida explícita, VMSS en orquestación **Flexible** distribuido entre las zonas 1/2/3, extensión de salud de aplicación, reparación automática de instancias, autoescalado asimétrico y diagnósticos de autoescalado enviados a Log Analytics.

```bicep
// ha-webtier.bicep
// Zone-redundant web tier: 99.99% compute SLA topology.
targetScope = 'resourceGroup'

@description('Azure region. Must be an availability-zone-enabled region.')
param location string = resourceGroup().location

@description('Prefix for all resource names.')
@minLength(3)
@maxLength(12)
param namePrefix string = 'hawt'

@description('VM size. Must be available in all three target zones.')
param vmSize string = 'Standard_D2as_v5'

@description('Local admin username for the scale set instances.')
param adminUsername string = 'azureuser'

@description('SSH public key for the admin user.')
@secure()
param sshPublicKey string

@description('Instance count boundaries for autoscale.')
param minCapacity int = 3
param maxCapacity int = 12
param defaultCapacity int = 3

var zones = ['1', '2', '3']
var lbName = '${namePrefix}-lb'
var vmssName = '${namePrefix}-vmss'

// cloud-init: nginx plus a dedicated /healthz endpoint distinct from '/'.
// The probe MUST NOT hit the application root: a root that returns 200 from a
// cached page will keep a broken instance in rotation.
var cloudInit = '''#cloud-config
package_update: true
packages:
  - nginx
write_files:
  - path: /var/www/html/healthz
    permissions: '0644'
    content: |
      ok
  - path: /etc/nginx/sites-available/default
    permissions: '0644'
    content: |
      server {
        listen 80 default_server;
        root /var/www/html;
        location /healthz {
          access_log off;
          try_files /healthz =503;
        }
        location / {
          try_files $uri $uri/ =404;
        }
      }
runcmd:
  - [ systemctl, enable, --now, nginx ]
  - [ systemctl, reload, nginx ]
'''

// ---------------------------------------------------------------- observability
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${namePrefix}-law'
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
    features: { enableLogAccessUsingOnlyResourcePermissions: true }
  }
}

// ---------------------------------------------------------------- network
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: '${namePrefix}-vnet'
  location: location
  properties: {
    addressSpace: { addressPrefixes: ['10.42.0.0/16'] }
    subnets: [
      {
        name: 'web'
        properties: {
          addressPrefix: '10.42.1.0/24'
          networkSecurityGroup: { id: nsg.id }
        }
      }
    ]
  }
}

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${namePrefix}-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'allow-http-from-lb'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '80'
        }
      }
      {
        name: 'allow-http-from-internet'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '80'
        }
      }
    ]
  }
}

// Standard SKU public IP with all three zones listed = zone-redundant frontend.
// Omitting `zones` on a Standard public IP in an AZ region yields a NON-zonal
// (regional) IP; listing a single zone pins it and makes it a SPOF.
resource pip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: '${namePrefix}-pip'
  location: location
  sku: { name: 'Standard', tier: 'Regional' }
  zones: zones
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    idleTimeoutInMinutes: 4
  }
}

resource lb 'Microsoft.Network/loadBalancers@2024-05-01' = {
  name: lbName
  location: location
  sku: { name: 'Standard', tier: 'Regional' }
  properties: {
    frontendIPConfigurations: [
      {
        name: 'fe-public'
        properties: {
          publicIPAddress: { id: pip.id }
        }
      }
    ]
    backendAddressPools: [
      { name: 'be-web' }
    ]
    probes: [
      {
        name: 'probe-healthz'
        properties: {
          protocol: 'Http'
          port: 80
          requestPath: '/healthz'
          intervalInSeconds: 5
          numberOfProbes: 2
        }
      }
    ]
    loadBalancingRules: [
      {
        name: 'rule-http'
        properties: {
          protocol: 'Tcp'
          frontendPort: 80
          backendPort: 80
          idleTimeoutInMinutes: 4
          enableFloatingIP: false
          enableTcpReset: true
          // Outbound SNAT is handled by an explicit outbound rule below, which
          // gives deterministic port allocation instead of implicit exhaustion.
          disableOutboundSnat: true
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', lbName, 'fe-public')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, 'be-web')
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', lbName, 'probe-healthz')
          }
        }
      }
    ]
    outboundRules: [
      {
        name: 'ob-web'
        properties: {
          protocol: 'All'
          // 0 = automatic allocation based on backend pool size. Pin an explicit
          // value if you know your per-instance concurrent-flow requirement.
          allocatedOutboundPorts: 0
          idleTimeoutInMinutes: 4
          enableTcpReset: true
          frontendIPConfigurations: [
            {
              id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', lbName, 'fe-public')
            }
          ]
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, 'be-web')
          }
        }
      }
    ]
  }
}

// ---------------------------------------------------------------- compute
resource vmss 'Microsoft.Compute/virtualMachineScaleSets@2024-07-01' = {
  name: vmssName
  location: location
  // Listing three zones spreads instances round-robin across them.
  // This is the line that turns a 99.9% deployment into a 99.99% one.
  zones: zones
  sku: {
    name: vmSize
    capacity: defaultCapacity
  }
  properties: {
    orchestrationMode: 'Flexible'
    // Flexible orchestration requires singlePlacementGroup=false and, when
    // spanning availability zones, platformFaultDomainCount=1 (the zone IS the
    // fault domain; fault domains are not subdivided further).
    singlePlacementGroup: false
    platformFaultDomainCount: 1
    automaticRepairsPolicy: {
      enabled: true
      // Grace period must exceed worst-case boot + application warm-up, or the
      // platform will repair instances that were merely still starting.
      gracePeriod: 'PT30M'
      repairAction: 'Replace'
    }
    virtualMachineProfile: {
      osProfile: {
        computerNamePrefix: namePrefix
        adminUsername: adminUsername
        customData: base64(cloudInit)
        linuxConfiguration: {
          disablePasswordAuthentication: true
          provisionVMAgent: true
          patchSettings: {
            patchMode: 'AutomaticByPlatform'
            assessmentMode: 'AutomaticByPlatform'
          }
          ssh: {
            publicKeys: [
              {
                path: '/home/${adminUsername}/.ssh/authorized_keys'
                keyData: sshPublicKey
              }
            ]
          }
        }
      }
      storageProfile: {
        imageReference: {
          publisher: 'Canonical'
          offer: '0001-com-ubuntu-server-jammy'
          sku: '22_04-lts-gen2'
          version: 'latest'
        }
        osDisk: {
          createOption: 'FromImage'
          caching: 'ReadWrite'
          // Premium SSD is a prerequisite for the 99.9% single-instance SLA and
          // the baseline for predictable IOPS.
          managedDisk: { storageAccountType: 'Premium_LRS' }
          deleteOption: 'Delete'
        }
      }
      networkProfile: {
        // Mandatory for Flexible orchestration.
        networkApiVersion: '2020-11-01'
        networkInterfaceConfigurations: [
          {
            name: '${namePrefix}-nic'
            properties: {
              primary: true
              enableAcceleratedNetworking: true
              deleteOption: 'Delete'
              ipConfigurations: [
                {
                  name: '${namePrefix}-ipcfg'
                  properties: {
                    primary: true
                    subnet: { id: vnet.properties.subnets[0].id }
                    loadBalancerBackendAddressPools: [
                      {
                        id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, 'be-web')
                      }
                    ]
                  }
                }
              ]
            }
          }
        ]
      }
      extensionProfile: {
        extensions: [
          {
            name: 'AppHealth'
            properties: {
              publisher: 'Microsoft.ManagedServices'
              type: 'ApplicationHealthLinux'
              typeHandlerVersion: '2.0'
              autoUpgradeMinorVersion: true
              settings: {
                protocol: 'http'
                port: 80
                requestPath: '/healthz'
                intervalInSeconds: 5
                numberOfProbes: 3
              }
            }
          }
        ]
      }
    }
  }
  dependsOn: [ lb ]
}

// ---------------------------------------------------------------- elasticity
resource autoscale 'Microsoft.Insights/autoscaleSettings@2022-10-01' = {
  name: '${namePrefix}-autoscale'
  location: location
  properties: {
    enabled: true
    targetResourceUri: vmss.id
    profiles: [
      {
        name: 'cpu-reactive'
        capacity: {
          minimum: string(minCapacity)
          maximum: string(maxCapacity)
          default: string(defaultCapacity)
        }
        rules: [
          {
            metricTrigger: {
              metricName: 'Percentage CPU'
              metricResourceUri: vmss.id
              timeGrain: 'PT1M'
              statistic: 'Average'
              timeWindow: 'PT5M'
              timeAggregation: 'Average'
              operator: 'GreaterThan'
              threshold: 70
              dividePerInstance: false
            }
            scaleAction: {
              direction: 'Increase'
              type: 'ChangeCount'
              value: '2'
              // Short cooldown out: reacting late costs availability.
              cooldown: 'PT5M'
            }
          }
          {
            metricTrigger: {
              metricName: 'Percentage CPU'
              metricResourceUri: vmss.id
              timeGrain: 'PT1M'
              statistic: 'Average'
              timeWindow: 'PT10M'
              timeAggregation: 'Average'
              operator: 'LessThan'
              // 40-point gap from the scale-out threshold. Narrower gaps
              // produce oscillation: the fleet scales out, drops below the
              // scale-in threshold BECAUSE it scaled out, and scales back in.
              threshold: 30
            }
            scaleAction: {
              direction: 'Decrease'
              type: 'ChangeCount'
              value: '1'
              // Long cooldown in: scaling in late costs money; scaling in
              // early costs availability. Asymmetry is deliberate.
              cooldown: 'PT10M'
            }
          }
        ]
      }
    ]
    notifications: [
      {
        operation: 'Scale'
        email: {
          sendToSubscriptionAdministrator: true
          sendToSubscriptionCoAdministrators: false
          customEmails: []
        }
      }
    ]
  }
}

// Autoscale decisions are invisible without this. AutoscaleEvaluations records
// every evaluation including the ones that decided NOT to act — which is
// exactly what you need when "autoscale did nothing".
resource autoscaleDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'autoscale-to-law'
  scope: autoscale
  properties: {
    workspaceId: law.id
    logs: [
      { category: 'AutoscaleEvaluations', enabled: true }
      { category: 'AutoscaleScaleActions', enabled: true }
    ]
  }
}

output publicIp string = pip.properties.ipAddress
output vmssResourceId string = vmss.id
output workspaceId string = law.id
output deployedZones array = zones
```

### 6.2 Azure Policy — convertir "producción debe ser redundante de zona" en un invariante

```json
{
  "properties": {
    "displayName": "Production storage accounts must be zone-redundant",
    "policyType": "Custom",
    "mode": "Indexed",
    "description": "Denies creation or update of storage accounts in scopes tagged env=prod unless the SKU replicates across availability zones (ZRS, GZRS, or RA-GZRS).",
    "metadata": {
      "version": "1.0.0",
      "category": "Storage"
    },
    "parameters": {
      "allowedSkus": {
        "type": "Array",
        "metadata": {
          "displayName": "Allowed zone-redundant SKUs",
          "description": "Storage SKUs considered zone-resilient."
        },
        "defaultValue": [
          "Standard_ZRS",
          "Standard_GZRS",
          "Standard_RAGZRS",
          "Premium_ZRS"
        ]
      },
      "effect": {
        "type": "String",
        "allowedValues": [ "Audit", "Deny", "Disabled" ],
        "defaultValue": "Deny",
        "metadata": {
          "displayName": "Effect",
          "description": "Start at Audit, measure the non-compliance count, then flip to Deny."
        }
      }
    },
    "policyRule": {
      "if": {
        "allOf": [
          {
            "field": "type",
            "equals": "Microsoft.Storage/storageAccounts"
          },
          {
            "field": "tags['env']",
            "equals": "prod"
          },
          {
            "not": {
              "field": "Microsoft.Storage/storageAccounts/sku.name",
              "in": "[parameters('allowedSkus')]"
            }
          }
        ]
      },
      "then": {
        "effect": "[parameters('effect')]"
      }
    }
  }
}
```

Asignala en un management group para que la hereden todas las suscripciones presentes y futuras:

```bash
$ az policy definition create \
    --name require-zrs-prod-storage \
    --display-name "Production storage accounts must be zone-redundant" \
    --management-group "mg-corp-production" \
    --rules @policy-rule.json \
    --params @policy-params.json \
    --mode Indexed
```

```bash
$ az policy assignment create \
    --name enforce-zrs-prod \
    --display-name "Enforce ZRS on production storage" \
    --scope "/providers/Microsoft.Management/managementGroups/mg-corp-production" \
    --policy require-zrs-prod-storage \
    --params '{"effect":{"value":"Audit"}}' \
    --enforcement-mode Default
```

> **Disciplina operativa:** nunca asignes una política `Deny` directamente. Asignala como `Audit`, esperá un ciclo completo de evaluación de cumplimiento (hasta ~24 h, o forzá uno con `az policy state trigger-scan`), leé la cantidad de no conformes, remediá, y recién entonces cambiá el parámetro a `Deny`. Un `Deny` asignado a ciegas rompe despliegues en curso de todos los equipos bajo ese ámbito.

### 6.3 Kubernetes en AKS — distribución por zonas, presupuesto de interrupción y escalado horizontal

Los mismos principios de disponibilidad expresados en la capa de la carga de trabajo. `topologySpreadConstraints` es el equivalente en Kubernetes de `zones: ['1','2','3']`.

```yaml
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: business-critical
value: 1000000
globalDefault: false
description: "Evicted last under node pressure; preempts best-effort workloads."
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout-api
  namespace: payments
  labels:
    app.kubernetes.io/name: checkout-api
    app.kubernetes.io/component: api
spec:
  replicas: 6
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0        # never dip below the declared replica count
      maxSurge: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: checkout-api
        app.kubernetes.io/component: api
    spec:
      priorityClassName: business-critical
      terminationGracePeriodSeconds: 60
      # Zone spreading: no zone may hold more than one pod above the minimum.
      # DoNotSchedule makes this a hard constraint - a pod stays Pending rather
      # than concentrating the fleet in a single zone. That Pending pod is also
      # the signal that drives the Cluster Autoscaler.
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: checkout-api
        # Node spreading is best-effort: preferring node diversity is valuable,
        # but blocking a schedule on it would trade availability for tidiness.
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: checkout-api
      containers:
        - name: api
          image: ghcr.io/example/checkout-api:1.14.2
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          # Requests are NOT a suggestion: they are the scheduler's input and
          # therefore the Cluster Autoscaler's trigger. Omit them and node
          # autoscaling silently never fires.
          resources:
            requests:
              cpu: "250m"
              memory: "256Mi"
            limits:
              memory: "512Mi"        # no CPU limit: avoids CFS throttling
          startupProbe:
            httpGet: { path: /healthz/startup, port: http }
            failureThreshold: 30
            periodSeconds: 2
          readinessProbe:
            httpGet: { path: /healthz/ready, port: http }
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 3
          livenessProbe:
            httpGet: { path: /healthz/live, port: http }
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 6      # deliberately slacker than readiness:
                                     # withdraw traffic before killing a process
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "sleep 15"]  # drain endpoints first
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 10001
            capabilities:
              drop: ["ALL"]
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: checkout-api
  namespace: payments
spec:
  # Bounds VOLUNTARY disruption only: node drains, cluster upgrades, autoscaler
  # consolidation. It does not protect against a zone failure - nothing does
  # except having replicas in the other zones.
  minAvailable: 4
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout-api
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: checkout-api
  namespace: payments
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: checkout-api
  minReplicas: 6          # >= 3 so every zone keeps a replica after scale-in
  maxReplicas: 60
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 65
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0      # react immediately to load
      policies:
        - type: Percent
          value: 100
          periodSeconds: 30
        - type: Pods
          value: 4
          periodSeconds: 30
      selectPolicy: Max
    scaleDown:
      stabilizationWindowSeconds: 300    # asymmetric, same reasoning as VMSS
      policies:
        - type: Percent
          value: 25
          periodSeconds: 60
      selectPolicy: Min
---
apiVersion: v1
kind: Service
metadata:
  name: checkout-api
  namespace: payments
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path: /healthz/ready
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: checkout-api
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
```

### 6.4 Terraform — almacenamiento redundante de zona con las perillas de confiabilidad configuradas

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
  features {}
}

resource "azurerm_storage_account" "app_data" {
  name                     = "stappdataprodeus01"
  resource_group_name      = azurerm_resource_group.prod.name
  location                 = azurerm_resource_group.prod.location
  account_tier             = "Standard"

  # GZRS: three synchronous copies across availability zones in the primary
  # region, plus asynchronous replication to the paired region.
  # Zone loss  -> transparent, RPO = 0.
  # Region loss -> customer-managed failover, RPO = replication lag (non-zero).
  account_replication_type = "GZRS"
  account_kind             = "StorageV2"
  access_tier              = "Hot"

  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false   # force Entra ID auth

  blob_properties {
    versioning_enabled  = true
    change_feed_enabled = true

    delete_retention_policy {
      days = 30
    }
    container_delete_retention_policy {
      days = 30
    }
    # Point-in-time restore requires versioning + change feed + soft delete.
    # This is the RPO control for logical corruption, which geo-replication
    # does NOT protect against: replication faithfully copies your mistakes.
    restore_policy {
      days = 29
    }
  }

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }

  tags = {
    env        = "prod"
    owner      = "platform-sre"
    costcenter = "CC-4417"
    rpo        = "15m"
    rto        = "60m"
  }
}
```

> **Notá la distinción codificada arriba:** GZRS defiende contra fallas de *infraestructura*. El versionado, el borrado suave y la restauración a un punto en el tiempo defienden contra fallas *lógicas* — un despliegue malo, una migración mala, ransomware. La replicación no es respaldo: copia la eliminación a la misma velocidad con la que copia los datos.

---

## 7. CLI y salida de terminal esperada

### 7.1 Establecer el contexto y confirmar la disponibilidad de zonas

```bash
$ az login --use-device-code
To sign in, use a web browser to open the page https://microsoft.com/devicelogin
and enter the code F7QK3M9RD to authenticate.

$ az account set --subscription "sub-platform-prod"
$ az account show --output table
EnvironmentName    IsDefault    Name                 State    TenantId
-----------------  -----------  -------------------  -------  ------------------------------------
AzureCloud         True         sub-platform-prod    Enabled  9c5f2a71-4d0e-4b3c-8a6f-1e2d3c4b5a60
```

No todas las regiones tienen zonas de disponibilidad, y esto determina si un SLA de 99,99% es siquiera alcanzable:

```bash
$ az account list-locations \
    --query "[?metadata.regionType=='Physical'].{Region:name, Geo:metadata.geographyGroup, Paired:metadata.pairedRegion[0].name}" \
    --output table | head -12
Region              Geo             Paired
------------------  --------------  ------------------
eastus              US              westus
eastus2             US              centralus
westus2             US              westcentralus
westus3             US              eastus
northeurope         Europe          westeurope
westeurope          Europe          northeurope
uksouth             Europe          ukwest
brazilsouth         South America   southcentralus
```

### 7.2 Resolver el mapeo lógico→físico de zonas (la permutación por suscripción)

```bash
$ SUB=$(az account show --query id -o tsv)
$ az rest --method get \
    --url "https://management.azure.com/subscriptions/$SUB/locations?api-version=2022-12-01" \
    --query "value[?name=='eastus'].availabilityZoneMappings[]" \
    --output table
LogicalZone    PhysicalZone
-------------  --------------
1              eastus-az3
2              eastus-az1
3              eastus-az2
```

**Leé esa salida.** La zona lógica 1 en esta suscripción es la zona física `eastus-az3`. Una suscripción distinta producirá una permutación distinta. Si un aviso de Azure Service Health nombra una zona física, este comando es la forma de determinar si es *tu* zona 1.

### 7.3 Verificar que el SKU existe en las tres zonas *antes* de desplegar

```bash
$ az vm list-skus \
    --location eastus \
    --size Standard_D2as_v5 \
    --resource-type virtualMachines \
    --query "[].{Name:name, Zones:locationInfo[0].zones, Restrictions:restrictions[].reasonCode}" \
    --output table
Name              Zones      Restrictions
----------------  ---------  --------------
Standard_D2as_v5  ['1','2','3']
```

Una columna `Zones` vacía, o un valor de `Restrictions` de `NotAvailableForSubscription`, significa que el despliegue va a fallar en la zona que no podés ver. Verificá esto primero — es una consulta de 200 ms que evita un despliegue fallido de 20 minutos.

### 7.4 Verificar la cuota antes de que el autoescalado la necesite

```bash
$ az vm list-usage --location eastus \
    --query "[?contains(localName, 'DAv5') || contains(localName,'Total Regional')].{Name:localName, Used:currentValue, Limit:limit}" \
    --output table
Name                                  Used    Limit
------------------------------------  ------  -------
Total Regional vCPUs                  38      50
Standard DAv5 Family vCPUs            24      32
```

Con `maxCapacity: 12` en `Standard_D2as_v5` (2 vCPU cada una), un escalado hacia afuera completo necesita 24 vCPU en la familia DAv5. Actualmente hay 24 de 32 en uso. **La flota va a chocar contra el muro de cuota en la instancia 4 del escalado hacia afuera y el autoescalado va a registrar una falla, no a emitir una alerta.** Ampliá la cuota antes del evento de carga, no durante.

### 7.5 Desplegar y verificar la distribución por zonas

```bash
$ az deployment group create \
    --resource-group rg-hawt-prod-eus \
    --name hawt-$(git rev-parse --short HEAD) \
    --template-file ha-webtier.bicep \
    --parameters namePrefix=hawt sshPublicKey="$(cat ~/.ssh/id_ed25519.pub)" \
    --query "properties.{state:provisioningState, duration:duration, ip:outputs.publicIp.value}" \
    --output json
{
  "state": "Succeeded",
  "duration": "PT4M11.8836142S",
  "ip": "20.119.44.86"
}
```

La verificación que importa no es "¿se desplegó?" sino "¿está realmente distribuido?":

```bash
$ az vm list \
    --resource-group rg-hawt-prod-eus \
    --show-details \
    --query "[].{Name:name, Zone:zones[0], PowerState:powerState, PrivateIP:privateIps}" \
    --output table
Name           Zone    PowerState      PrivateIP
-------------  ------  --------------  -----------
hawt-vmss_0    1       VM running      10.42.1.4
hawt-vmss_1    2       VM running      10.42.1.5
hawt-vmss_2    3       VM running      10.42.1.6
```

Una instancia por zona. **Este es el comando que prueba la topología de 99,99%.** Si las tres reportan la misma zona, pagaste por redundancia de zona y no recibiste ninguna.

### 7.6 Verificar la salud y el estado del balanceador de carga

```bash
$ az vmss get-instance-view \
    --resource-group rg-hawt-prod-eus \
    --name hawt-vmss \
    --query "{repairs:orchestrationServices[0].serviceState, service:orchestrationServices[0].serviceName}" \
    --output table
Repairs    Service
---------  -----------------------
Running    AutomaticRepairs
```

```bash
$ for i in $(seq 1 6); do curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" http://20.119.44.86/healthz; done
200 0.041s
200 0.038s
200 0.044s
200 0.037s
200 0.039s
200 0.043s
```

### 7.7 Confirmar que la regla de autoescalado está armada

```bash
$ az monitor autoscale show \
    --resource-group rg-hawt-prod-eus \
    --name hawt-autoscale \
    --query "{enabled:enabled, min:profiles[0].capacity.minimum, max:profiles[0].capacity.maximum, rules:profiles[0].rules[].{metric:metricTrigger.metricName, op:metricTrigger.operator, th:metricTrigger.threshold, dir:scaleAction.direction, cool:scaleAction.cooldown}}" \
    --output json
{
  "enabled": true,
  "max": "12",
  "min": "3",
  "rules": [
    {
      "cool": "0:05:00",
      "dir": "Increase",
      "metric": "Percentage CPU",
      "op": "GreaterThan",
      "th": 70.0
    },
    {
      "cool": "0:10:00",
      "dir": "Decrease",
      "metric": "Percentage CPU",
      "op": "LessThan",
      "th": 30.0
    }
  ]
}
```

### 7.8 Verificación de zonas del lado de Kubernetes

```bash
$ kubectl get nodes -L topology.kubernetes.io/zone,agentpool
NAME                              STATUS   ROLES   AGE   VERSION   ZONE          AGENTPOOL
aks-workload-14882730-vmss000000  Ready    agent   9d    v1.31.4   eastus-1      workload
aks-workload-14882730-vmss000001  Ready    agent   9d    v1.31.4   eastus-2      workload
aks-workload-14882730-vmss000002  Ready    agent   9d    v1.31.4   eastus-3      workload
aks-workload-14882730-vmss000003  Ready    agent   2d    v1.31.4   eastus-1      workload
aks-workload-14882730-vmss000004  Ready    agent   2d    v1.31.4   eastus-2      workload
aks-workload-14882730-vmss000005  Ready    agent   2d    v1.31.4   eastus-3      workload
```

```bash
$ kubectl -n payments get pods -o custom-columns=\
'NAME:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase' --no-headers \
| while read n node s; do
    z=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')
    printf '%-34s %-12s %s\n' "$n" "$z" "$s"
  done | sort -k2
checkout-api-7d9c5f8b64-2xkqp      eastus-1     Running
checkout-api-7d9c5f8b64-mv7rt      eastus-1     Running
checkout-api-7d9c5f8b64-9wz4l      eastus-2     Running
checkout-api-7d9c5f8b64-hq8dn      eastus-2     Running
checkout-api-7d9c5f8b64-4jf6s      eastus-3     Running
checkout-api-7d9c5f8b64-pk3vc      eastus-3     Running
```

Dos pods por zona, seis en total, `minAvailable: 4`. Perder una zona entera deja 4 pods — exactamente el piso del PDB. Ese es el diseño funcionando.

### 7.9 Verificación de gobernanza y costos

```bash
$ az policy state summarize \
    --management-group mg-corp-production \
    --query "value[0].results.{NonCompliant:nonCompliantResources, Policies:nonCompliantPolicies}" \
    --output table
NonCompliant    Policies
--------------  ----------
7               2
```

```bash
$ az graph query -q "
Resources
| where type =~ 'microsoft.storage/storageAccounts'
| where tags['env'] =~ 'prod'
| where sku.name !in ('Standard_ZRS','Standard_GZRS','Standard_RAGZRS','Premium_ZRS')
| project name, resourceGroup, location, sku=sku.name
| order by resourceGroup asc
" --output table
Name                  ResourceGroup        Location   Sku
--------------------  -------------------  ---------  -------------
stlegacyexports01     rg-data-prod-eus     eastus     Standard_LRS
stmediacache02        rg-web-prod-eus      eastus     Standard_LRS
```

Dos cuentas de almacenamiento de producción están en un solo centro de datos. Ninguna sobreviviría a la pérdida de una zona. Esta consulta — gratuita, instantánea, sobre todo el parque — es el beneficio de administrabilidad hecho concreto: on-prem, la respuesta equivalente requiere una auditoría.

```bash
$ az consumption usage list \
    --start-date 2026-08-01 --end-date 2026-08-31 \
    --query "[?contains(instanceName,'hawt')].{Date:usageStart, Meter:meterDetails.meterName, Qty:usageQuantity, Cost:pretaxCost}" \
    --output table | head -6
Date                 Meter                  Qty        Cost
-------------------  ---------------------  ---------  --------
2026-08-01T00:00:00  D2as v5 Vcpu Duration  72.000000  6.912000
2026-08-02T00:00:00  D2as v5 Vcpu Duration  96.000000  9.216000
2026-08-03T00:00:00  D2as v5 Vcpu Duration  72.000000  6.912000
2026-08-04T00:00:00  D2as v5 Vcpu Duration  144.00000  13.82400
2026-08-05T00:00:00  D2as v5 Vcpu Duration  72.000000  6.912000
```

Fijate en el 2026-08-04: la cantidad se duplicó. Eso es el autoescalado respondiendo a un evento de carga, y es visible como una línea de la factura. **La elasticidad que no podés ver en la factura no es elasticidad — es una suposición.**

---

## 8. Verificación y diagnóstico de fallas

### 8.1 Runbook de diagnóstico

| Síntoma | Primer comando | Causa más probable | Solución |
|---|---|---|---|
| El despliegue tuvo éxito pero todas las instancias están en una zona | `az vm list -d --query "[].zones"` | `zones` omitido en el VMSS, o la región no soporta AZ | Agregar `zones: ['1','2','3']`; verificar la región con `az account list-locations` |
| `SkuNotAvailable` al desplegar | `az vm list-skus -l <r> --size <sku> --query "[].restrictions"` | SKU ausente o restringido en la zona / suscripción destino | Cambiar el SKU o el conjunto de zonas; solicitar capacidad vía soporte |
| El autoescalado nunca escala hacia afuera | KQL de `AutoscaleEvaluationsLog` (§8.2) | Métrica equivocada, ventana demasiado larga, ya en `maximum`, o cuota | Corregir la regla; `az vm list-usage` para la cuota |
| Se intentó escalar hacia afuera y falló | `AutoscaleScaleActionsLog` + Activity Log | Cuota regional / de familia de vCPU agotada | Ampliar la cuota **antes** del evento; agregar una segunda familia |
| La flota oscila cada 10 min | Comparar umbrales en `az monitor autoscale show` | Umbrales demasiado cercanos; cooldowns simétricos | Ampliar la brecha (≥ 30 puntos); alargar el cooldown de escalado hacia adentro |
| Instancias en `Running` pero el LB devuelve 502 | `az network lb probe show`, luego `curl` a la ruta del sondeo sobre una IP privada | La ruta del sondeo devuelve algo distinto de 200, o el NSG bloquea la etiqueta `AzureLoadBalancer` | Corregir la ruta del sondeo; agregar la regla de NSG de §6.1 |
| Instancias reparadas en bucle | `az vmss get-instance-view` + configuración de la extensión de salud | `gracePeriod` más corto que el tiempo de arranque+calentamiento | Aumentar `gracePeriod`; agregar un retardo equivalente a un `startupProbe` |
| Pods en `Pending`, cantidad de nodos sin cambios | `kubectl describe pod` → Events | Sin `requests` de recursos (el autoescalador está ciego), o restricción de zona insatisfacible | Agregar `requests`; verificar que existe un node pool en cada zona |
| Fallas intermitentes de conexión saliente con carga alta | Métricas del LB `SNAT Connection Count` / `Allocated SNAT Ports` | Agotamiento de puertos SNAT | Regla de salida explícita con `allocatedOutboundPorts` fijado, o NAT Gateway |
| Las lecturas de almacenamiento fallan durante un evento regional | `az storage account show --query "statusOfPrimary"` | Región primaria degradada | Leer desde el endpoint `-secondary` (requiere RA-GRS/RA-GZRS) |
| Salto de costo inexplicado | `az costmanagement query` agrupado por ResourceId | El escalado hacia adentro nunca se disparó; discos huérfanos; egreso | Verificar la regla de escalado hacia adentro; `az disk list --query "[?diskState=='Unattached']"` |
| "¿Esta caída es nuestra o de Azure?" | API de Resource Health (§8.3) | — | `Unavailable` + `PlatformInitiated` = Azure; si no, es tuya |

### 8.2 KQL: probar qué decidió el autoescalado, incluidas las no-decisiones

```kusto
// Every autoscale evaluation in the last 24 h, including "no action".
// This is the table that answers "autoscale is enabled but nothing happened".
AutoscaleEvaluationsLog
| where TimeGenerated > ago(24h)
| where ResourceId has "hawt-vmss"
| project TimeGenerated,
          MetricName = Metric,
          Observed   = ObservedValue,
          Threshold,
          Operator,
          Direction  = ScaleDirection,
          Fired      = EvaluationResult,
          Reason     = ProfileEvaluationReason
| order by TimeGenerated desc
| take 100
```

```kusto
// Attempted scale actions and their outcomes. A "Failed" row here with a
// quota message is the single most common cause of a capacity incident.
AutoscaleScaleActionsLog
| where TimeGenerated > ago(7d)
| project TimeGenerated, ResourceId, ScaleDirection,
          OldCapacity = OldInstancesCount,
          NewCapacity = NewInstancesCount,
          ResultType, ResultDescription
| where ResultType != "Succeeded"
| order by TimeGenerated desc
```

```kusto
// Zone balance over time: did the fleet drift into a single zone after a
// repair cycle? Flexible orchestration does not automatically rebalance.
Heartbeat
| where TimeGenerated > ago(1h)
| where Computer startswith "hawt"
| summarize arg_max(TimeGenerated, *) by Computer
| extend Zone = tostring(split(ResourceId, "/")[-1])
| summarize Instances = count() by Computer
```

```kusto
// Platform-initiated maintenance and health transitions - the audit trail you
// need when claiming an SLA credit.
AzureActivity
| where TimeGenerated > ago(30d)
| where CategoryValue in ("ResourceHealth", "ServiceHealth")
| project TimeGenerated, OperationNameValue, ActivityStatusValue,
          Level, Properties
| order by TimeGenerated desc
```

### 8.3 Atribuir la caída: Resource Health

```bash
$ az rest --method get \
    --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/rg-hawt-prod-eus/providers/Microsoft.Compute/virtualMachines/hawt-vmss_1/providers/Microsoft.ResourceHealth/availabilityStatuses/current?api-version=2022-10-01" \
    --query "properties.{status:availabilityState, reason:reasonType, summary:summary, since:occuredTime}" \
    --output json
{
  "reason": "Unplanned",
  "since": "2026-09-03T02:14:07.000Z",
  "status": "Unavailable",
  "summary": "We're sorry, your virtual machine isn't available because of an unexpected host failure. Azure has begun auto-recovery and the VM will be available shortly."
}
```

**Este es el campo que zanja la discusión.** `availabilityState: Unavailable` con `reasonType: Unplanned` es una falla del lado de la plataforma — cuenta contra el SLA de Azure y es la evidencia para un reclamo de crédito de servicio. `reasonType: UserInitiated` significa que alguien de tu equipo la desasignó, y no aplica ningún crédito. Consultá Resource Health *antes* de escribir el informe del incidente, no después.

### 8.4 Validar el diseño, no solo el despliegue

Las verificaciones que realmente confirman que los beneficios se materializaron:

```bash
# 1. Zone distribution is real (not just requested)
$ az vm list -g rg-hawt-prod-eus -d --query "[].zones[0]" -o tsv | sort | uniq -c
      1 1
      1 2
      1 3

# 2. Automatic repair is armed
$ az vmss get-instance-view -g rg-hawt-prod-eus -n hawt-vmss \
    --query "orchestrationServices[?serviceName=='AutomaticRepairs'].serviceState" -o tsv
Running

# 3. Autoscale ceiling fits inside quota (the check nobody runs)
$ MAX=$(az monitor autoscale show -g rg-hawt-prod-eus -n hawt-autoscale \
        --query "profiles[0].capacity.maximum" -o tsv)
$ echo "max instances: $MAX -> needs $((MAX * 2)) vCPU in the DAv5 family"
max instances: 12 -> needs 24 vCPU in the DAv5 family

# 4. Every production resource is tagged for cost allocation and ownership
$ az graph query -q "Resources | where isnull(tags['owner']) | summarize count() by type" -o table
Count_    Type
--------  ----------------------------------------
0

# 5. Governance is enforcing, not merely assigned
$ az policy assignment list --scope "/providers/Microsoft.Management/managementGroups/mg-corp-production" \
    --query "[].{name:displayName, mode:enforcementMode}" -o table
Name                                     Mode
---------------------------------------  ---------
Enforce ZRS on production storage         Default
Require owner and costcenter tags         Default
```

Un modo de aplicación `DoNotEnforce` en la verificación 5 significa que la política evalúa e informa pero **no deniega**. Es el equivalente en gobernanza de una alarma deshabilitada, y es la razón más común por la que un parque "en cumplimiento" no lo está.

---

## 9. Mapeo al examen y las distinciones que se evalúan

| Redacción del examen | La respuesta precisa | El distractor contra el que se evalúa |
|---|---|---|
| Beneficio de la **alta disponibilidad** | Desplegar entre zonas de disponibilidad para que la falla de un centro de datos no tire abajo el servicio | Confundirla con escalabilidad, o con recuperación ante desastres |
| Beneficio de la **escalabilidad** | Agregar recursos para satisfacer la demanda; vertical = más grande, horizontal = más cantidad | Confundir escalabilidad (capacidad) con elasticidad (automática, bidireccional) |
| Beneficio de la **elasticidad** | Escalado automático **hacia afuera y hacia adentro** a medida que cambia la demanda, con facturación acorde | Usar "elasticidad" como sinónimo de escalabilidad |
| Beneficio de la **agilidad** | Aprovisionamiento rápido — desplegar en minutos, no en semanas de compras | Confundirla con elasticidad |
| Beneficio de la **confiabilidad** | Diseño distribuido que sigue funcionando a través de la falla y se recupera | Confundirla con disponibilidad (una propiedad puntual en el tiempo) |
| Beneficio de la **previsibilidad** | Tanto rendimiento (autoescalado, pilares del WAF) **como** costo (facturación por consumo, presupuestos, calculadora de TCO) | Responder solo la mitad del costo |
| Beneficio de la **seguridad** | Elección del nivel de control (IaaS = mayor control) más el cumplimiento heredado de la plataforma | Creer que SaaS significa que no tenés responsabilidad de seguridad |
| Beneficio de la **gobernanza** | Plantillas, Policy, RBAC y auditoría de cumplimiento mantienen el parque consistente y conforme a los estándares | Confundir Policy (cómo puede ser un recurso) con RBAC (quién puede actuar) |
| Beneficio de la **administrabilidad** | Administración **de** la nube (autoescalado, autorreparación, plantillas) vs administración **en** la nube (portal, CLI, PowerShell, API) | Mezclar las dos listas |
| **Zona de disponibilidad** | Ubicación físicamente separada *dentro* de una región; energía/refrigeración/red independientes | Confundirla con una región, o con un dominio de falla |
| **Par de regiones** | Segunda región en la misma geografía para geo-replicación y actualizaciones escalonadas | Suponer que toda región tiene uno, o que el emparejamiento lo elige el usuario |
| **CapEx vs OpEx** | CapEx = capital inicial, amortizado; OpEx = costo de consumo en el período en que se incurre | Creer que la nube siempre es más barata — es más *flexible*, no automáticamente menos costosa |

**El punto conceptual de mayor rendimiento:** la nube te da *acceso* a alta disponibilidad, escalabilidad, confiabilidad, seguridad, gobernanza y administrabilidad. Cada uno de ellos es una decisión arquitectónica deliberada que tenés que tomar y luego verificar con un comando. Un despliegue por defecto — una VM, una zona, almacenamiento LRS, sin políticas, sin etiquetas — no tiene ninguno de estos beneficios mientras corre sobre infraestructura plenamente capaz de todos ellos.

---

## Referencias

- AZ-900 Microsoft Azure Fundamentals — guía de estudio oficial: https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900
- Página de la certificación Microsoft Azure Fundamentals: https://learn.microsoft.com/en-us/credentials/certifications/azure-fundamentals/
- Beneficios de la alta disponibilidad y la escalabilidad en la nube (módulo de Learn): https://learn.microsoft.com/en-us/training/modules/describe-cloud-service-types/
- Regiones, zonas de disponibilidad y pares de regiones de Azure: https://learn.microsoft.com/en-us/azure/reliability/availability-zones-overview
- Zonas de disponibilidad de Azure — soporte por región: https://learn.microsoft.com/en-us/azure/reliability/availability-zones-region-support
- Pares de regiones de Azure y regiones no emparejadas: https://learn.microsoft.com/en-us/azure/reliability/regions-paired
- Conjuntos de disponibilidad, dominios de falla y dominios de actualización: https://learn.microsoft.com/en-us/azure/virtual-machines/availability
- Acuerdos de Nivel de Servicio (SLA) para Servicios en Línea de Microsoft: https://www.microsoft.com/licensing/docs/view/Service-Level-Agreements-SLA-for-Online-Services
- Portal de SLA de Azure: https://azure.microsoft.com/en-us/support/legal/sla/
- Azure Well-Architected Framework — pilar de Confiabilidad: https://learn.microsoft.com/en-us/azure/well-architected/reliability/
- Recomendaciones para definir objetivos de confiabilidad (RTO/RPO): https://learn.microsoft.com/en-us/azure/well-architected/reliability/metrics
- Redundancia de Azure Storage (LRS/ZRS/GRS/GZRS): https://learn.microsoft.com/en-us/azure/storage/common/storage-redundancy
- Recuperación ante desastres y failover de cuentas de almacenamiento: https://learn.microsoft.com/en-us/azure/storage/common/storage-disaster-recovery-guidance
- Virtual Machine Scale Sets — modos de orquestación: https://learn.microsoft.com/en-us/azure/virtual-machine-scale-sets/virtual-machine-scale-sets-orchestration-modes
- Reparaciones automáticas de instancias para scale sets: https://learn.microsoft.com/en-us/azure/virtual-machine-scale-sets/virtual-machine-scale-sets-automatic-instance-repairs
- Extensión Application Health: https://learn.microsoft.com/en-us/azure/virtual-machine-scale-sets/virtual-machine-scale-sets-health-extension
- Introducción al autoescalado de Azure Monitor: https://learn.microsoft.com/en-us/azure/azure-monitor/autoscale/autoscale-overview
- Solución de problemas del autoescalado de Azure: https://learn.microsoft.com/en-us/azure/azure-monitor/autoscale/autoscale-troubleshoot
- Mejores prácticas para el autoescalado de Azure Monitor: https://learn.microsoft.com/en-us/azure/azure-monitor/autoscale/autoscale-best-practices
- Azure Load Balancer — SKU Standard y zonas de disponibilidad: https://learn.microsoft.com/en-us/azure/load-balancer/load-balancer-standard-availability-zones
- Reglas de salida y SNAT de Load Balancer: https://learn.microsoft.com/en-us/azure/load-balancer/outbound-rules
- Introducción a Azure Front Door: https://learn.microsoft.com/en-us/azure/frontdoor/front-door-overview
- Métodos de enrutamiento de Traffic Manager: https://learn.microsoft.com/en-us/azure/traffic-manager/traffic-manager-routing-methods
- Responsabilidad compartida en la nube: https://learn.microsoft.com/en-us/azure/security/fundamentals/shared-responsibility
- Centro de orientación de Zero Trust: https://learn.microsoft.com/en-us/security/zero-trust/
- Introducción a Azure Policy: https://learn.microsoft.com/en-us/azure/governance/policy/overview
- Estructura y efectos de las definiciones de Azure Policy: https://learn.microsoft.com/en-us/azure/governance/policy/concepts/effect-basics
- Introducción a Azure RBAC: https://learn.microsoft.com/en-us/azure/role-based-access-control/overview
- Bloquear recursos para prevenir cambios inesperados: https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/lock-resources
- Azure Deployment Stacks (sucesor de Azure Blueprints): https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deployment-stacks
- Aviso de obsolescencia de Azure Blueprints: https://learn.microsoft.com/en-us/azure/governance/blueprints/overview
- Lenguaje de consulta de Azure Resource Graph: https://learn.microsoft.com/en-us/azure/governance/resource-graph/overview
- Documentación de Bicep: https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/
- Introducción a Azure Resource Health: https://learn.microsoft.com/en-us/azure/service-health/resource-health-overview
- Azure Service Health: https://learn.microsoft.com/en-us/azure/service-health/service-health-overview
- Azure Reservations: https://learn.microsoft.com/en-us/azure/cost-management-billing/reservations/save-compute-costs-reservations
- Plan de ahorro de Azure para cómputo: https://learn.microsoft.com/en-us/azure/cost-management-billing/savings-plan/savings-plan-compute-overview
- Azure Spot Virtual Machines: https://learn.microsoft.com/en-us/azure/virtual-machines/spot-vms
- Azure Hybrid Benefit: https://learn.microsoft.com/en-us/azure/cost-management-billing/scope-level/
- Microsoft Cost Management y Facturación: https://learn.microsoft.com/en-us/azure/cost-management-billing/
- Ofertas de cumplimiento de Azure: https://learn.microsoft.com/en-us/azure/compliance/
- Microsoft Defender for Cloud: https://learn.microsoft.com/en-us/azure/defender-for-cloud/defender-for-cloud-introduction
- Conceptos básicos de Azure Key Vault: https://learn.microsoft.com/en-us/azure/key-vault/general/basic-concepts
- Identidades administradas para recursos de Azure: https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/overview
- Introducción a Azure DDoS Protection: https://learn.microsoft.com/en-us/azure/ddos-protection/ddos-protection-overview
- Zonas de disponibilidad en AKS: https://learn.microsoft.com/en-us/azure/aks/availability-zones-overview
- Cluster autoscaler de AKS: https://learn.microsoft.com/en-us/azure/aks/cluster-autoscaler-overview
- KEDA en AKS: https://learn.microsoft.com/en-us/azure/aks/keda-about
- Restricciones de distribución de topología de pods en Kubernetes: https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/
- Pod Disruption Budgets de Kubernetes: https://kubernetes.io/docs/concepts/workloads/pods/disruptions/
- Horizontal Pod Autoscaler de Kubernetes: https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/
- Referencia de Azure CLI: https://learn.microsoft.com/en-us/cli/azure/reference-index