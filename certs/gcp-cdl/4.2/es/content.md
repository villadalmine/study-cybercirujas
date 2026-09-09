# 4.2 — Ofertas de infraestructura de Google Cloud: funcionalidad, casos de uso de negocio y valor de negocio

**Certificación:** Google Cloud Digital Leader (guía de examen versión 2026-08-12)
**Sección 4:** Modernizar la infraestructura y las aplicaciones con Google Cloud
**Peso en el examen:** 6.0 — este es un objetivo de *amplitud* con consecuencias de *profundidad*. El examen te pide relacionar un escenario de negocio con una oferta de infraestructura; la producción te pide defender esa elección en un design review. Este material enseña lo segundo, que engloba lo primero.

---

## 1. Motivación: el problema arquitectónico de producción

### 1.1 La decisión que realmente se toma

Ninguna organización real pregunta "¿deberíamos usar la nube?". Preguntan algo mucho más acotado y mucho más difícil, normalmente contra un deadline:

> *Tenemos 1.400 VMs en dos datacenters alquilados. El contrato de colo vence en 19 meses. El 60% de esas VMs corre un monolito Java y sus satélites, el 15% corre Oracle sobre bare metal con un acuerdo de licenciamiento que no podemos renegociar, el 10% es un estate VMware que nadie documenta desde 2019, y el resto son batch y agentes de build. Tenemos 6 ingenieros de plataforma. ¿Dónde aterriza cada workload, cuánto cuesta y qué se rompe?*

Esa pregunta se descompone exactamente en las tres cosas que nombra este objetivo:

| Vocabulario del examen | Traducción del arquitecto | Modo de falla cuando se ignora |
|---|---|---|
| **Funcionalidad** | ¿Qué nivel de abstracción expone la oferta, y qué te quita? | Elegís Cloud Run para un workload que necesita disco local persistente y requests de 6 horas. |
| **Caso de uso de negocio** | ¿Qué forma de workload mapea a esto *sin un rewrite*? | "Modernizás" un cluster Oracle RAC a GKE, quemás 14 meses y perdés la salida del colo. |
| **Valor de negocio** | TCO, time-to-market, transferencia de riesgo y SLA — medidos, no afirmados. | Migrás 1:1 a precio on-demand y tu factura de nube es 2,4× la del colo. |

### 1.2 La presión arquitectónica: el trade-off abstracción/control no es gratis

Cada oferta de infraestructura se ubica sobre un eje — **cuánto de la superficie operativa absorbe Google** — y moverse a lo largo de ese eje nunca es neutral. Cambiás control por elasticidad y headcount, y pagás el cambio en *restricciones de portabilidad* y *lock-in de supuestos operativos*.

```
 More control                                                    More managed
 More ops burden                                                 Less ops burden
 ├──────────────┬─────────────┬──────────┬────────────┬──────────┬────────────┤
 Bare Metal     Compute       GKE        GKE          Cloud Run  Cloud Run
 Solution /     Engine        Standard   Autopilot               functions
 VMware Engine  (IaaS)        (CaaS)     (CaaS-managed) (serverless containers)
                                                                 App Engine std

 You patch OS  ──────────────►│ Google patches nodes ──────────►│ No node concept
 You size VMs  ──────────────────────────►│ Google sizes to Pod ►│ Scales to zero
 You own HA    ──────────►│ k8s owns Pod HA │────────────────────►│ Fully managed
```

El **antipatrón que este objetivo existe para prevenir** es el "lift-and-shift al tier equivocado" — en cualquiera de las dos direcciones:

- **Demasiado a la izquierda:** todo en Compute Engine. Recreaste el datacenter, más una factura de egress. Sin beneficio de elasticidad, sin reducción de ops, y ahora pagás un premium por el hardware de otro.
- **Demasiado a la derecha:** todo en Cloud Run/serverless. Workloads con estado, jobs de larga duración, pipelines de GPU y appliances licenciados quedan forzados a entrar; terminás construyendo maquinaria compensatoria (almacenes de estado externos, checkpointing, orquestación) que cuesta más que las VMs que evitaste.

### 1.3 La segunda presión: los dominios de falla son una propiedad *comprada*

En un colo, la disponibilidad es algo que construís. En Google Cloud, la disponibilidad es en gran medida algo que **seleccionás** — vía la ubicación a lo largo de zonas y regiones — y luego *no invalidás* con un mal diseño. El incidente de producción más común en un estate migrado es:

> Un servicio "cloud" que es arquitectónicamente single-zone, corriendo sobre infraestructura que ofrece 99,99% solo si la distribuís, entregando disponibilidad de calidad colo a precios de calidad cloud.

Las secciones 2 y 10 hacen explícita esa aritmética.

---

## 2. El sustrato: qué estás comprando realmente

No podés razonar sobre las ofertas sin el modelo físico que hay debajo. Esta es la parte que el examen enuncia en una oración y que la producción pone a prueba todas las semanas.

### 2.1 Jerarquía de ubicaciones

| Constructo | Definición | Significado como dominio de falla | Productos con este alcance |
|---|---|---|---|
| **Multi-region** | Un área geográfica grande (p. ej. `US`, `EU`, `ASIA`) que contiene múltiples regiones | Sobrevive la pérdida de una región entera | Buckets multi-region de Cloud Storage, Spanner multi-region, datasets multi-region de BigQuery |
| **Región** | Un área geográfica independiente (p. ej. `us-central1`, `europe-west1`, `southamerica-east1`) que contiene ≥3 zonas | Sobrevive la pérdida de una zona; es en sí misma una unidad de falla correlacionada ante un evento a nivel región | Subnets de VPC, MIGs regionales, control planes regionales de GKE, servicios de Cloud Run, Cloud Storage regional |
| **Zona** | Un área de despliegue aislada dentro de una región; energía, refrigeración y networking independientes. Un nombre de zona como `us-central1-a` tiene **alcance de proyecto** — tu `-a` no es necesariamente el `-a` de otro proyecto | El blast radius primario alrededor del cual diseñás | Instancias de VM, Persistent Disks zonales, Local SSD, control planes zonales de GKE, MIGs zonales |
| **Edge PoP / network edge location** | Más de 180 network edge locations con peering hacia ISPs | No es una ubicación de cómputo; es donde el tráfico *entra* al backbone de Google | Cloud CDN, Media CDN, Cloud Armor, front ends de balanceo de carga global |

> **Verificá, no memorices.** Los conteos de regiones/zonas cambian trimestralmente. La lista autoritativa es `gcloud compute regions list` y la página de locations (§12). Al momento del snapshot de este syllabus la flota es de 40+ regiones y 120+ zonas; tratá las preguntas del examen como una evaluación del *concepto*, no del conteo.

### 2.2 Los tres sistemas internos cuyo comportamiento se filtra a tu diseño

Nunca vas a aprovisionar estos directamente, pero cada oferta de este objetivo es una interfaz hacia alguno de ellos. Conocerlos explica límites de producto que de otro modo parecen arbitrarios.

| Sistema interno | Qué es | Dónde aflora en el producto |
|---|---|---|
| **Borg** | El cluster manager de Google; el ancestro directo de Kubernetes | Por qué GKE Autopilot puede hacer bin-packing de tus Pods sin visibilidad de nodos; por qué los cold starts de Cloud Run se miden en cientos de ms, no en minutos |
| **Colossus** | El filesystem distribuido a nivel cluster (sucesor de GFS) | Por qué Cloud Storage no tiene capacidad aprovisionada ni IOPS que dimensionar; por qué Persistent Disk está adjuntado por red y sobrevive a la eliminación de la instancia |
| **Jupiter / Andromeda** | El fabric del datacenter (ancho de banda de bisección a escala petabit) y el stack de virtualización de red | Por qué las VPCs son objetos **globales** mientras que las subnets son regionales; por qué un internal passthrough load balancer no tiene VMs proxy; por qué el throughput de egress de una VM escala con la cantidad de vCPU |

**Consecuencia de diseño que vas a usar de inmediato:** como la VPC es un constructo global definido por software, una VM en `us-central1` y una VM en `asia-southeast1` en la misma VPC se hablan por direcciones RFC 1918 **sin VPN, sin peering, sin gateway**. En términos de AWS/Azure esto colapsa un diseño entero de red de tránsito en una decisión de ruteo. Este es un diferenciador genuino y una respuesta frecuente en el examen.

---

## 3. Ofertas de cómputo

Para cada oferta: **Funcionalidad → Caso de uso de negocio → Valor de negocio**, y luego la tabla consolidada de trade-offs.

### 3.1 Compute Engine (IaaS)

**Funcionalidad.** Máquinas virtuales sobre la infraestructura de Google. Elegís familia de máquina, vCPU/memoria, imagen de disco de arranque y ubicación. Obtenés: custom machine types (vCPU/memoria arbitrarios dentro de los ratios de la familia), live migration (mantenimiento de host sin reiniciar la VM — un diferenciador genuino frente al mantenimiento basado en reboot), facturación por segundo tras un mínimo de 1 minuto, y Managed Instance Groups (MIGs) para autohealing, autoscaling y rolling updates.

**Caso de uso de negocio.** Lift-and-shift de VMs existentes; software comercial con requisitos de instalación a nivel de SO; workloads con kernels especializados, agentes licenciados o attachment de GPU/TPU; cualquier cosa donde la matriz de soporte del proveedor nombre un sistema operativo.

**Valor de negocio.** El camino más rápido para salir de un contrato de datacenter con el menor riesgo de rewrite. Convierte capex + ciclos de refresh en opex, y habilita los instrumentos de descuento (§10) que hacen defendible ese opex.

**Selección de familia de máquina** — acá es donde en realidad se toman la mayoría de las decisiones de costo:

| Familia | Series (ejemplos) | Punto de diseño | Usar cuando |
|---|---|---|---|
| General purpose | `E2`, `N2`, `N2D`, `N4`, `C4`, `T2D` | Precio/rendimiento balanceado | Capas web, servidores de aplicación, dev/test. `E2` es el piso de costo (sin SUD, opciones shared-core); `T2D`/`N2D` son basadas en AMD y suelen dar el mejor $/rendimiento para scale-out |
| Compute optimized | `C2`, `C2D`, `C3`, `C4` | El rendimiento por core más consistente y alto | Game servers, HPC, ad serving, aplicaciones limitadas por latencia single-threaded |
| Memory optimized | `M1`, `M2`, `M3`, `M4` | Hasta varios TB de RAM | SAP HANA, bases de datos in-memory grandes, cachés de analítica |
| Storage optimized | `Z3` | Densidad muy alta de SSD local | Bases de datos scale-out, analítica de datos calientes que necesita NVMe local |
| Accelerator optimized | `A2`, `A3`, `A4`, `G2` | GPU NVIDIA adjuntada | Entrenamiento e inferencia de lotes grandes (`A*`), inferencia/gráficos (`G2`) |

**Modelos de aprovisionamiento** — la segunda palanca de costo:

| Modelo | Descuento vs on-demand | Interrupción | Runtime máximo | Workload correcto |
|---|---|---|---|---|
| On-demand | línea base | ninguna | ilimitado | Estable, crítico en latencia, licenciado |
| **Spot VMs** | ~60–91% | Sí, aviso `ACPI G2 Soft Off` de 30 segundos | ilimitado (a diferencia del tope de 24 h de las Preemptible legacy) | Batch, CI, render farms, map/reduce tolerante a fallas, scale-out stateless con capacidad de surge |
| Sole-tenant nodes | premium (+) | ninguna | ilimitado | BYOL con licenciamiento por core físico, compliance que exige aislamiento físico |
| Reservations | ninguno (garantiza capacidad) | ninguna | ilimitado | Garantizar capacidad a prueba de stockout para DR o eventos pico; se combina con CUDs |

### 3.2 Google Kubernetes Engine (GKE)

**Funcionalidad.** Kubernetes gestionado: Google corre el control plane (etcd, API server, scheduler, controller manager) con un SLA, y gestiona el ciclo de vida de los nodos en el grado que elijas.

| | **GKE Standard** | **GKE Autopilot** |
|---|---|---|
| Unidad de facturación | VMs de nodo (lo que aprovisiones, estén ociosas o no) | Resource requests de los Pods (vCPU/mem/almacenamiento) |
| Gestión de nodos | Vos dimensionás, ventanas de upgrade, node pools, taints | Google aprovisiona, dimensiona, parchea y escala los nodos |
| Acceso a nodos | SSH disponible, DaemonSets, Pods privilegiados, hostPath | Sin SSH; privileged/hostPath restringidos; DaemonSets permitidos con restricciones |
| Riesgo de bin-packing | Tuyo (la capacidad de nodo no asignada es tu factura) | De Google |
| Mejor para | Kernels/drivers custom, tuning de GPU, agentes a nivel de nodo, control de costo con alta utilización sostenida | Elección por defecto para workloads nuevos; equipos sin una función SRE de k8s dedicada |
| SLA del control plane | Regional 99,95% / zonal 99,5% | Regional 99,95% |

**Caso de uso de negocio.** Plataformas de microservicios; plataformas internas multi-tenant; workloads ya containerizados; híbrido/multicloud donde Kubernetes es el contrato de portabilidad (GKE Enterprise / Anthos extiende el control plane a on-prem y a otras nubes).

**Valor de negocio.** Google escribió Kubernetes; GKE es la implementación de referencia. Autopilot convierte una factura de nodos variable y difícil de atribuir en una factura por Pod que mapea 1:1 al chargeback por equipo — un argumento *financiero* subestimado que gana conversaciones de presupuesto.

### 3.3 Cloud Run (contenedores serverless)

**Funcionalidad.** Corre cualquier contenedor stateless que escuche en `$PORT`, escalando 0→N según el volumen de requests o eventos. Concurrencia de hasta 1000 requests por instancia (esta es la diferencia económica clave frente al FaaS por request). Dos formas de workload: **Services** (dirigidos por requests) y **Jobs** (run-to-completion, paralelos por array). Direct VPC egress o conectores de Serverless VPC Access alcanzan recursos privados.

**Caso de uso de negocio.** APIs y front ends web con tráfico picudo o impredecible; consumidores de eventos (Pub/Sub push, Eventarc); ETL programado como Jobs; herramientas internas que están ociosas 22 horas al día.

**Valor de negocio.** El scale-to-zero elimina el costo del ocio. Un estate de dev/test de 40 aplicaciones internas sobre VMs cuesta ~$X/mes independientemente del uso; en Cloud Run ese mismo estate cuesta casi cero de noche y los fines de semana. La superficie de despliegue se reduce a `gcloud run deploy`, lo que elimina una clase entera de trabajo de ops.

### 3.4 Cloud Run functions

**Funcionalidad.** Function-as-a-Service, dirigido por eventos, construido sobre la infraestructura de Cloud Run (esto es lo que antes se llamaba Cloud Functions 2nd gen). Triggers: HTTP, Pub/Sub, eventos de objetos de Cloud Storage, Firestore, Eventarc (más de 90 fuentes).

**Caso de uso de negocio.** Código pegamento — generación de thumbnails al subir un archivo, receptores de webhooks, transformaciones pequeñas, ruteo de alertas.

**Valor de negocio.** El menor time-to-first-deploy posible para una pieza discreta de lógica de negocio. El caso de valor son minutos de desarrollador, no centavos de cómputo.

### 3.5 App Engine

**Funcionalidad.** El PaaS original de Google. **Standard environment**: runtimes en sandbox, escala a cero, arranque de instancia sub-segundo, restricciones estrictas de lenguaje/versión. **Flexible environment**: tu contenedor sobre VMs gestionadas de Compute Engine, sin scale-to-zero, más libertad.

**Caso de uso de negocio.** Estates existentes de App Engine; aplicaciones web clásicas request/response donde el runtime del lenguaje está soportado y el tráfico es a ráfagas. **Para builds nuevos, Cloud Run es el default moderno** — decilo en voz alta en un design review.

**Valor de negocio.** Cero gestión de infraestructura con versionado y traffic splitting incorporados.

### 3.6 Bare Metal Solution

**Funcionalidad.** Hardware físico certificado y single-tenant en una instalación gestionada por Google **adyacente a** una región de Google Cloud, conectado por un enlace de baja latencia (típicamente sub-2 ms) y alto ancho de banda hacia tu VPC vía Partner Interconnect. Conservás root y tus licencias existentes.

**Caso de uso de negocio.** Exactamente uno, en esencia: **Oracle y otros workloads legacy con restricciones de hardware/licenciamiento que bloquean la virtualización**, donde igual querés el *resto* del estate en Google Cloud con conectividad privada y rápida.

**Valor de negocio.** Elimina el bloqueante "no podemos movernos por Oracle" sin un proyecto de migración de base de datos. Permite que el contrato de colo venza.

### 3.7 Google Cloud VMware Engine (GCVE)

**Funcionalidad.** Un stack dedicado de VMware Cloud Foundation gestionado por Google — vSphere, vCenter, vSAN, NSX — corriendo sobre bare metal de Google Cloud. Obtenés tu vCenter familiar con tus VMs, herramientas y runbooks existentes. HCX maneja la migración masiva y en vivo.

**Caso de uso de negocio.** Estates VMware grandes y sin documentar contra un deadline duro. Salida de datacenter donde re-plataformar 800 VMs no es factible en la ventana disponible. DR basado en VMware hacia la nube.

**Valor de negocio.** *Tiempo.* Esta es la salida de datacenter de mayor velocidad disponible: sin conversión de SO, sin re-testing de aplicaciones, sin reentrenar al equipo de virtualización. Es deliberadamente una zona de aterrizaje **transitoria** — modernizás *después* de que el contrato terminó, workload por workload, en lugar de bajo presión.

### 3.8 Tabla consolidada de trade-offs de cómputo

| Dimensión | Bare Metal Solution | VMware Engine | Compute Engine | GKE Standard | GKE Autopilot | Cloud Run | Cloud Run functions | App Engine Std |
|---|---|---|---|---|---|---|---|---|
| Unidad de despliegue | Servidor físico | VM (vSphere) | VM | Contenedor/nodo | Contenedor/Pod | Contenedor | Función | Bundle de código |
| Escala a cero | No | No | No | No (nodos) | No (min nodes) | **Sí** | **Sí** | **Sí** |
| Granularidad de facturación | Mensual/plazo | Node-hour (plazo) | Por segundo | Node-second | **Pod-second** | ~100 ms request/instancia | ~100 ms | Instance-hour |
| Parcheo del SO | Vos | Vos (guest) | Vos (guest) | Google (nodos, auto-upgrade) | Google | Google | Google | Google |
| Duración máxima de request/ejecución | n/a | n/a | n/a | n/a | n/a | 60 min (services) / 24 h (jobs) | 60 min | 10 min (auto scaling) |
| Estado local persistente | Sí | Sí | Sí (PD/Local SSD) | Sí (PV) | Sí (PV) | No (efímero, FS en memoria) | No | No |
| Soporte de GPU | Sí | Limitado | Sí | Sí | Sí | Sí (L4) | No | No |
| Esfuerzo típico de migración desde VM on-prem | Ninguno | **Ninguno** | Bajo (import de imagen) | Medio (containerizar) | Medio | Alto (requiere statelessness) | Alto (descomponer) | Alto |
| Lock-in del modelo operativo | El más bajo | El más bajo | Bajo | Bajo (k8s portable) | Medio | Medio (compatible con Knative) | Alto | Alto |

### 3.9 Procedimiento de decisión (usá este, en orden)

```
1. Does a vendor/licensing constraint forbid virtualization or require physical cores?
      → Bare Metal Solution (or sole-tenant nodes if virtualization is allowed)
2. Is it a large VMware estate under a hard datacenter-exit deadline?
      → Google Cloud VMware Engine (modernize later, not now)
3. Does it need OS-level control, a custom kernel, or an unsupported runtime?
      → Compute Engine  (+ MIG for HA/autoscaling, + Spot for fault-tolerant tiers)
4. Is it already containerized, or does the org run a platform for many teams?
      → GKE   → Autopilot unless you need node-level control → then Standard
5. Is it a stateless HTTP service or event consumer with variable traffic?
      → Cloud Run  (Jobs for run-to-completion batch)
6. Is it a single event-triggered snippet of glue logic?
      → Cloud Run functions
```

---

## 4. Ofertas de almacenamiento

**La regla arquitectónica:** clasificá por *patrón de acceso y tiempo de vida*, nunca por tamaño.

### 4.1 Almacenamiento de objetos — Cloud Storage

**Funcionalidad.** Almacén de objetos globalmente consistente sobre Colossus. Sin aprovisionamiento: capacidad, throughput e IOPS son elásticos. El tipo de ubicación (region / dual-region / multi-region) fija el envelope de durabilidad y disponibilidad; **la storage class fija el trade-off precio/recuperación**. La durabilidad es de 11 nueves en todas las clases — las clases difieren en *disponibilidad y costo de acceso*, no en durabilidad.

| Clase | Duración mínima de almacenamiento | Costo de almacenamiento | Costo de recuperación | Diseñada para |
|---|---|---|---|---|
| **Standard** | ninguna | el más alto | ninguno | Datos calientes, assets de sitios web, analítica activa, staging de dataflow |
| **Nearline** | 30 días | más bajo | bajo | Backups y contenido accedido ~mensualmente |
| **Coldline** | 90 días | aún más bajo | más alto | Acceso trimestral, copias de DR |
| **Archive** | 365 días | el más bajo | el más alto | Retención por compliance, reemplazo de cinta; **latencia de primer byte en milisegundos, no en horas** |

Funcionalidades clave que un arquitecto debe conocer: **Object Lifecycle Management** (transiciones y borrado basados en edad/versión), **Autoclass** (transiciones automáticas de clase por objeto sin cargos de recuperación en la transición — el default correcto cuando los patrones de acceso son desconocidos), **Object Versioning**, **Retention Policies con Bucket Lock** (WORM, para compliance regulatorio), **Customer-Managed Encryption Keys (CMEK)** vía Cloud KMS, y **Requester Pays**.

**Valor de negocio.** Reemplaza librerías de cintas, capas NAS y contratos de archivado por una sola API y una política de ciclo de vida. Que la clase Archive entregue recuperación en milisegundos mata de raíz el clásico problema de DR de "restaurar toma 12 horas".

### 4.2 Almacenamiento de bloques

| Producto | Modelo de attachment | Alcance de durabilidad | Modelo de rendimiento | Usar cuando |
|---|---|---|---|---|
| **Persistent Disk** (`pd-standard`, `pd-balanced`, `pd-ssd`, `pd-extreme`) | Adjuntado por red; sobrevive a la eliminación de la VM; soporta múltiples lectores | Zonal, o **Regional PD** (replicación síncrona entre dos zonas de una región) | IOPS/throughput escalan con el tamaño **y** con la cantidad de vCPU de la VM | Discos de arranque, bases de datos generales, cualquier cosa que necesite snapshots |
| **Hyperdisk** (`Balanced`, `Extreme`, `Throughput`, `ML`) | Adjuntado por red, de próxima generación | Zonal (variante Balanced HA disponible) | Capacidad, IOPS y throughput **aprovisionados de forma independiente** — desacoplados del tamaño del disco y del tamaño de la VM | Bases de datos de alto IOPS; cuando PD te obliga a sobreaprovisionar capacidad para comprar IOPS. Requerido en familias más nuevas (p. ej. `N4`) |
| **Local SSD** | NVMe adjuntado físicamente, 375 GiB por dispositivo | **Efímero** — los datos se pierden al detener/terminar/reiniciar por live-migrate | El IOPS más alto, la latencia más baja | Espacio scratch, cachés, shuffle/spill, DBs scale-out replicadas que se reconstruyen desde sus pares |

> **Trampa de producción:** ingenieros que migran desde on-prem dimensionan un `pd-balanced` en 100 GB, obtienen el techo de IOPS que viene con 100 GB, y abren un bug de rendimiento. En PD, **el IOPS se compra con capacidad**; en Hyperdisk se compra directamente. Vale la pena entender esta única distinción tanto para el examen ("¿qué oferta permite escalar IOPS independientemente del tamaño?") como para el aviso de las 3 de la mañana.

### 4.3 Almacenamiento de archivos

| Producto | Protocolo | Caso de uso |
|---|---|---|
| **Filestore** (Basic / Zonal / Regional / Enterprise) | NFSv3 | Aplicaciones lift-and-shift que esperan un mount compartido POSIX; volúmenes `ReadWriteMany` de GKE; pipelines de medios/render; filesystems compartidos de SAP |
| **NetApp Volumes** | NFS + SMB, con snapshots/replicación | Estates de archivos empresariales que necesitan funcionalidades de NetApp y SMB para workloads Windows |
| **Parallelstore** | FS paralelo basado en DAOS | HPC y entrenamiento de IA que requieren throughput agregado extremo a baja latencia |

### 4.4 Tabla de decisión de almacenamiento

| Si el workload... | Usar | No |
|---|---|---|
| Lee/escribe objetos completos sobre HTTP | Cloud Storage | Filestore (pagar por POSIX que no usás) |
| Es una base de datos que necesita un dispositivo de bloques con snapshots | PD Balanced / Hyperdisk Balanced | Local SSD (efímero) |
| Necesita >100k IOPS sobre un dataset modesto | **Hyperdisk Extreme** | pd-ssd inflado a 3 TB para comprar IOPS |
| Necesita un mount compartido desde muchas VMs/Pods simultáneamente | Filestore / NetApp Volumes | PD (multi-writer es un caso especial acotado) |
| Es espacio scratch/shuffle que se puede reconstruir | Local SSD | Hyperdisk (pagar por durabilidad que descartás) |
| Debe retenerse 7 años para auditoría, se lee rara vez | Cloud Storage **Archive** + Bucket Lock | Nearline (desajuste de duración mínima y precio) |
| Tiene patrones de acceso desconocidos o cambiantes | Cloud Storage + **Autoclass** | Reglas de ciclo de vida escritas a mano que te vas a olvidar de actualizar |

---

## 5. Ofertas de networking

### 5.1 VPC — la propiedad que cambia los diseños

Una **red VPC es un recurso global**; **las subnets son regionales**. Consecuencias:

- Una VPC puede abarcar todas las regiones del planeta sin un gateway inter-región.
- Las rutas y las reglas de firewall son objetos globales; las reglas de firewall son stateful y apuntan a instancias por network tag o service account.
- **Shared VPC** permite que un host project sea dueño de la red mientras los service projects enganchan sus workloads — el patrón empresarial estándar que separa la autoridad del equipo de red de la autonomía de los equipos de aplicación.
- **VPC Network Peering** conecta VPCs (incluso entre organizaciones) con conectividad privada RFC 1918, de forma no transitiva.
- **Private Service Connect** expone servicios gestionados y de terceros sobre una IP privada dentro de tu VPC, eliminando los caminos por IP pública hacia servicios como Cloud SQL o SaaS de partners.

### 5.2 Network Service Tiers

| | **Premium Tier** (default) | **Standard Tier** |
|---|---|---|
| Camino | El tráfico entra/sale por el edge PoP más cercano al usuario, y luego viaja por el **backbone privado de Google** (ruteo "cold potato") | El tráfico viaja por la internet pública, entrando/saliendo cerca de la *región* ("hot potato") |
| Latencia/jitter | La más baja, la más consistente | Depende de internet |
| Balanceo de carga | Soporta balanceo de carga externo **global** con una única IP anycast | Solo balanceo de carga regional |
| Costo | Precio de egress más alto | Precio de egress más bajo |
| Usar para | Tráfico de producción de cara al cliente | Transferencias masivas, dev/test, workloads regionales sensibles al costo |

Esta es una palanca de costo real, medible y de un solo flag, y un ítem recurrente del examen.

### 5.3 Cloud Load Balancing

Los balanceadores de carga de Google son **definidos por software, no basados en VMs** — no hay nada que precalentar ni nada que escalar. Un Application Load Balancer externo global presenta **una única dirección anycast IPv4/IPv6 a nivel mundial**.

| Balanceador de carga | Alcance | Capa | Uso típico |
|---|---|---|---|
| Application LB externo global | Global (Premium Tier) | L7 HTTP(S) | Puerta de entrada web/API pública; integra Cloud CDN, Cloud Armor, IAP, certificados TLS |
| Application LB externo regional | Regional | L7 | Requisitos regionales de residencia de datos; Standard Tier |
| Application LB interno cross-region / regional | Interno | L7 | Ruteo este-oeste entre microservicios dentro de la VPC |
| Network LB proxy externo | Global/regional | L4 proxy (TCP/SSL) | TCP no HTTP con offload de TLS |
| Network LB **passthrough** externo | Regional | L4 passthrough | Preserva la IP del cliente; UDP, protocolos no TCP, workloads a nivel de protocolo IP |
| Network LB passthrough interno | Regional | L4 passthrough | VIPs de servicios internos, next-hops de appliances HA |

Servicios acompañantes: **Cloud CDN** (cachea en edge PoPs detrás del LB global), **Cloud Armor** (WAF, DDoS L3–L7, reglas geo/rate, rulesets OWASP preconfigurados), **Cloud DNS** (SLA de 100% de disponibilidad, anycast, zonas públicas y privadas), **Cloud NAT** (NAT de egress gestionado sin VMs de NAT gateway), **Network Connectivity Center** (tránsito hub-and-spoke entre VPCs, Interconnects, VPNs y SD-WAN).

### 5.4 Conectividad híbrida

| Opción | Ancho de banda | ¿RFC 1918 privado? | SLA | Usar cuando |
|---|---|---|---|---|
| **Cloud VPN — HA VPN** | Hasta ~3 Gbps por túnel; escala con túneles | Sí (IPsec sobre internet) | **99,99%** (dos interfaces, topología correcta) | Rápido de levantar; throughput moderado; camino de DR |
| Cloud VPN — Classic VPN | ~1,5–3 Gbps/túnel | Sí | 99,9% | Legacy; siendo reemplazado por HA VPN |
| **Dedicated Interconnect** | Circuitos de 10 Gbps o 100 Gbps, agrupables | Sí | 99,9% (redundancia de una sola región) / **99,99%** (multi-zona, topología de 4 enlaces) | Volumen alto y sostenido; latencia predecible; tarifa de egress reducida |
| **Partner Interconnect** | 50 Mbps – 50 Gbps | Sí | 99,9% / 99,99% según topología | No estás en un colo con un PoP de Google; incrementos más chicos |
| **Cross-Cloud Interconnect** | 10/100 Gbps | Sí | 99,9% / 99,99% | Enlace privado directo hacia otra nube pública |
| Direct / Carrier Peering | Varía | **No** — solo IPs públicas | Sin SLA | Alcanzar las APIs públicas de Google con menor costo de egress |

> **Encuadre de valor de negocio para el examen:** Interconnect reduce el *costo de egress* y da *latencia determinística*; HA VPN da *velocidad de entrega* y *menor costo fijo*. Los estates reales corren ambos — Interconnect como primario, HA VPN como camino de respaldo.

---

## 6. Caminos de migración y modernización

| Herramienta de Google | Etapa | Qué hace |
|---|---|---|
| **Migration Center** | Assess | Descubre el inventario on-prem, agrupa workloads, produce dimensionamiento y un **reporte de TCO** — este es el artefacto que consigue la aprobación del presupuesto |
| **Migrate to Virtual Machines** | Rehost | Transmite VMs on-prem/de otra nube hacia Compute Engine con downtime mínimo |
| **VMware Engine + HCX** | Rehost (nativo VMware) | Migración masiva y en vivo de VMs de vSphere, sin cambios |
| **Migrate to Containers** | Replatform | Convierte workloads de VM en artefactos de contenedor y manifiestos de GKE/Cloud Run |
| **Database Migration Service** | Rehost/replatform de DBs | Replicación continua hacia Cloud SQL / AlloyDB con downtime de cutover mínimo |
| **Storage Transfer Service** | Datos | Transferencia online desde S3, Azure Blob, HTTP, POSIX on-prem hacia Cloud Storage |
| **Transfer Appliance** | Datos | Appliance físico enviable por correo (TA40 ≈ 40 TB, TA300 ≈ 300 TB) cuando las cuentas de la WAN no cierran |

**Las cuentas de la WAN, porque alguien va a preguntar:** transferir 300 TB por un enlace saturado de 1 Gbps ≈ 300 × 10¹² × 8 / 10⁹ s ≈ 2,4 M s ≈ **27,8 días al 100% de utilización** — realistamente 45–60 días. Ese es el caso de negocio completo de Transfer Appliance en una sola línea.

**Secuenciación de modernización que realmente funciona:**

```
Exit the datacenter first (rehost)  →  stabilize  →  modernize per workload (replatform/refactor)
```

Intentar el refactor *durante* la salida es la forma más confiable de perder el deadline del contrato. Decí esto en el design review; también es el razonamiento que premia el examen.

---

## 7. Código de infraestructura completo

### 7.1 Terraform — landing zone, red, GKE Autopilot, y MIG detrás de un ALB global

Completo y aplicable. Reemplazá el default de `project_id`.

```hcl
# main.tf — Google Cloud infrastructure baseline
# Provides: VPC + subnet (with GKE secondary ranges), Cloud NAT, GKE Autopilot
# regional cluster, a Spot-backed regional MIG, and a global external
# Application Load Balancer with Cloud CDN and Cloud Armor.

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
  backend "gcs" {
    bucket = "tf-state-teachplat-prod"
    prefix = "infra/core"
  }
}

variable "project_id" {
  type        = string
  description = "Target Google Cloud project."
  default     = "teachplat-prod-001"
}

variable "region" {
  type    = string
  default = "us-central1"
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ---------------------------------------------------------------------------
# Enable the APIs the rest of this configuration depends on.
# ---------------------------------------------------------------------------
resource "google_project_service" "required" {
  for_each = toset([
    "compute.googleapis.com",
    "container.googleapis.com",
    "run.googleapis.com",
    "artifactregistry.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

# ---------------------------------------------------------------------------
# Network. The VPC is global; the subnet is regional. Secondary ranges back
# GKE Pods and Services (VPC-native / alias IP).
# ---------------------------------------------------------------------------
resource "google_compute_network" "core" {
  name                            = "core-vpc"
  auto_create_subnetworks         = false
  routing_mode                    = "GLOBAL"
  delete_default_routes_on_create = false
  depends_on                      = [google_project_service.required]
}

resource "google_compute_subnetwork" "workloads" {
  name                     = "workloads-${var.region}"
  ip_cidr_range            = "10.10.0.0/20" # 4096 node/VM addresses
  region                   = var.region
  network                  = google_compute_network.core.id
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.20.0.0/14" # 262144 Pod addresses — size this generously
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.24.0.0/20"
  }

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# Egress for private nodes/VMs without public IPs.
resource "google_compute_router" "nat_router" {
  name    = "core-nat-router"
  region  = var.region
  network = google_compute_network.core.id
}

resource "google_compute_router_nat" "nat" {
  name                                = "core-nat"
  router                              = google_compute_router.nat_router.name
  region                              = var.region
  nat_ip_allocate_option              = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat  = "ALL_SUBNETWORKS_ALL_IP_RANGES"
  enable_endpoint_independent_mapping = false
  min_ports_per_vm                    = 128
  enable_dynamic_port_allocation      = true
  max_ports_per_vm                    = 8192

  log_config {
    enable = true
    filter = "ERRORS_ONLY" # surfaces port-exhaustion drops
  }
}

# ---------------------------------------------------------------------------
# Firewall: health checks and IAP SSH. These two source ranges are the ones
# people forget, and both failures look like "the app is down".
# ---------------------------------------------------------------------------
resource "google_compute_firewall" "allow_health_checks" {
  name          = "allow-gcp-health-checks"
  network       = google_compute_network.core.name
  direction     = "INGRESS"
  priority      = 1000
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  target_tags   = ["lb-backend"]

  allow {
    protocol = "tcp"
    ports    = ["80", "443", "8080"]
  }
}

resource "google_compute_firewall" "allow_iap_ssh" {
  name          = "allow-iap-ssh"
  network       = google_compute_network.core.name
  direction     = "INGRESS"
  priority      = 1000
  source_ranges = ["35.235.240.0/20"] # IAP TCP forwarding
  target_tags   = ["lb-backend"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# ---------------------------------------------------------------------------
# GKE Autopilot, regional (99.95% control-plane SLA).
# ---------------------------------------------------------------------------
resource "google_container_cluster" "platform" {
  name             = "platform-autopilot"
  location         = var.region # region, not zone -> regional cluster
  enable_autopilot = true

  network    = google_compute_network.core.id
  subnetwork = google_compute_subnetwork.workloads.id

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  release_channel {
    channel = "REGULAR"
  }

  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = "10.10.0.0/20"
      display_name = "workloads-subnet"
    }
  }

  deletion_protection = true
}

# ---------------------------------------------------------------------------
# Compute Engine: regional MIG on Spot VMs, autohealed and autoscaled.
# The classic "cheap, fault-tolerant scale-out tier".
# ---------------------------------------------------------------------------
resource "google_service_account" "mig" {
  account_id   = "mig-workload"
  display_name = "Regional MIG workload identity"
}

resource "google_compute_instance_template" "web" {
  name_prefix  = "web-tpl-"
  machine_type = "n2d-standard-4"
  region       = var.region
  tags         = ["lb-backend"]

  scheduling {
    provisioning_model  = "SPOT"
    preemptible         = true
    automatic_restart   = false
    on_host_maintenance = "TERMINATE"

    instance_termination_action = "STOP"
  }

  disk {
    source_image = "projects/debian-cloud/global/images/family/debian-12"
    auto_delete  = true
    boot         = true
    disk_type    = "pd-balanced"
    disk_size_gb = 50
  }

  network_interface {
    network    = google_compute_network.core.id
    subnetwork = google_compute_subnetwork.workloads.id
    # No access_config block -> no external IP; egress via Cloud NAT.
  }

  service_account {
    email  = google_service_account.mig.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  metadata = {
    enable-oslogin = "TRUE"
    startup-script = <<-EOT
      #!/bin/bash
      set -euo pipefail
      apt-get update -qq
      apt-get install -y -qq nginx
      HOSTNAME_SELF="$(curl -s -H 'Metadata-Flavor: Google' \
        http://metadata.google.internal/computeMetadata/v1/instance/hostname)"
      ZONE_SELF="$(curl -s -H 'Metadata-Flavor: Google' \
        http://metadata.google.internal/computeMetadata/v1/instance/zone | awk -F/ '{print $NF}')"
      cat >/var/www/html/index.html <<HTML
      <!doctype html><html><body>
      <h1>ok</h1><p>host: $${HOSTNAME_SELF}</p><p>zone: $${ZONE_SELF}</p>
      </body></html>
HTML
      cat >/etc/nginx/sites-available/health <<'NGINX'
      server {
        listen 8080;
        location /healthz { return 200 'healthy\n'; add_header Content-Type text/plain; }
      }
NGINX
      ln -sf /etc/nginx/sites-available/health /etc/nginx/sites-enabled/health
      systemctl restart nginx
      systemctl enable nginx
    EOT
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_health_check" "web" {
  name                = "web-hc"
  check_interval_sec  = 5
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3

  http_health_check {
    port         = 8080
    request_path = "/healthz"
  }
}

resource "google_compute_region_instance_group_manager" "web" {
  name                      = "web-mig"
  region                    = var.region
  base_instance_name        = "web"
  distribution_policy_zones = ["us-central1-a", "us-central1-b", "us-central1-f"]

  version {
    instance_template = google_compute_instance_template.web.id
  }

  named_port {
    name = "http"
    port = 80
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.web.id
    initial_delay_sec = 120
  }

  update_policy {
    type                         = "PROACTIVE"
    instance_redistribution_type = "PROACTIVE"
    minimal_action               = "REPLACE"
    max_surge_fixed              = 3
    max_unavailable_fixed        = 0
  }
}

resource "google_compute_region_autoscaler" "web" {
  name   = "web-autoscaler"
  region = var.region
  target = google_compute_region_instance_group_manager.web.id

  autoscaling_policy {
    min_replicas    = 3
    max_replicas    = 30
    cooldown_period = 60

    cpu_utilization {
      target = 0.6
    }
  }
}

# ---------------------------------------------------------------------------
# Global external Application Load Balancer + Cloud CDN + Cloud Armor.
# ---------------------------------------------------------------------------
resource "google_compute_security_policy" "edge" {
  name = "edge-armor-policy"

  rule {
    action   = "allow"
    priority = 2147483647
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "default allow"
  }

  rule {
    action   = "rate_based_ban"
    priority = 1000
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"
      rate_limit_threshold {
        count        = 600
        interval_sec = 60
      }
      ban_duration_sec = 300
    }
    description = "per-IP rate limit"
  }
}

resource "google_compute_backend_service" "web" {
  name                  = "web-backend"
  protocol              = "HTTP"
  port_name             = "http"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  timeout_sec           = 30
  health_checks         = [google_compute_health_check.web.id]
  security_policy       = google_compute_security_policy.edge.id
  enable_cdn            = true

  cdn_policy {
    cache_mode        = "CACHE_ALL_STATIC"
    default_ttl       = 3600
    client_ttl        = 3600
    max_ttl           = 86400
    negative_caching  = true
    serve_while_stale = 86400
  }

  log_config {
    enable      = true
    sample_rate = 1.0
  }

  backend {
    group           = google_compute_region_instance_group_manager.web.instance_group
    balancing_mode  = "UTILIZATION"
    max_utilization = 0.8
    capacity_scaler = 1.0
  }
}

resource "google_compute_url_map" "web" {
  name            = "web-urlmap"
  default_service = google_compute_backend_service.web.id
}

resource "google_compute_global_address" "web" {
  name       = "web-anycast-ip"
  ip_version = "IPV4"
}

resource "google_compute_managed_ssl_certificate" "web" {
  name = "web-cert"
  managed {
    domains = ["study.example.com"]
  }
}

resource "google_compute_target_https_proxy" "web" {
  name             = "web-https-proxy"
  url_map          = google_compute_url_map.web.id
  ssl_certificates = [google_compute_managed_ssl_certificate.web.id]
}

resource "google_compute_global_forwarding_rule" "web" {
  name                  = "web-fr-https"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.web.address
  port_range            = "443"
  target                = google_compute_target_https_proxy.web.id
}

# ---------------------------------------------------------------------------
# Cloud Storage with tiering. Autoclass is preferred when access patterns
# are unknown; the explicit lifecycle rules below show the manual equivalent.
# ---------------------------------------------------------------------------
resource "google_storage_bucket" "artifacts" {
  name                        = "${var.project_id}-artifacts"
  location                    = "US" # multi-region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  force_destroy               = false

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }

  lifecycle_rule {
    condition {
      age = 90
    }
    action {
      type          = "SetStorageClass"
      storage_class = "COLDLINE"
    }
  }

  lifecycle_rule {
    condition {
      age = 365
    }
    action {
      type          = "SetStorageClass"
      storage_class = "ARCHIVE"
    }
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 5
      with_state         = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }
}

output "load_balancer_ip" {
  value       = google_compute_global_address.web.address
  description = "Anycast IPv4 for the global external Application Load Balancer."
}

output "gke_endpoint" {
  value       = google_container_cluster.platform.endpoint
  description = "GKE Autopilot control-plane endpoint."
  sensitive   = true
}
```

### 7.2 Manifiestos de Kubernetes — workload de calidad productiva sobre GKE Autopilot

```yaml
# workload.yaml — deploy with: kubectl apply -f workload.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: courseware
  labels:
    app.kubernetes.io/part-of: teach-plat
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: courseware-api
  namespace: courseware
  annotations:
    # Workload Identity: bind this KSA to a Google service account.
    iam.gke.io/gcp-service-account: courseware-api@teachplat-prod-001.iam.gserviceaccount.com
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: courseware-api
  namespace: courseware
  labels:
    app: courseware-api
spec:
  replicas: 3
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app: courseware-api
  template:
    metadata:
      labels:
        app: courseware-api
    spec:
      serviceAccountName: courseware-api
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      # Spread Pods across zones so a zonal outage cannot take the service down.
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: courseware-api
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app: courseware-api
      containers:
        - name: api
          image: us-central1-docker.pkg.dev/teachplat-prod-001/apps/courseware-api:1.14.2
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          env:
            - name: PORT
              value: "8080"
            - name: GOMEMLIMIT
              value: "900MiB"
          # On Autopilot the *requests* are the bill. Set them deliberately.
          resources:
            requests:
              cpu: "500m"
              memory: "1Gi"
              ephemeral-storage: "1Gi"
            limits:
              cpu: "1000m"
              memory: "1Gi"
              ephemeral-storage: "1Gi"
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          startupProbe:
            httpGet:
              path: /healthz
              port: http
            failureThreshold: 30
            periodSeconds: 5
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 20
            timeoutSeconds: 3
            failureThreshold: 3
          volumeMounts:
            - name: tmp
              mountPath: /tmp
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "sleep 10"]
      terminationGracePeriodSeconds: 60
      volumes:
        - name: tmp
          emptyDir:
            sizeLimit: 512Mi
---
apiVersion: v1
kind: Service
metadata:
  name: courseware-api
  namespace: courseware
  annotations:
    # Container-native load balancing: the LB targets Pod IPs directly (NEGs),
    # removing the kube-proxy hop and giving accurate health and load data.
    cloud.google.com/neg: '{"ingress": true}'
    cloud.google.com/backend-config: '{"default": "courseware-api-backendconfig"}'
spec:
  type: ClusterIP
  selector:
    app: courseware-api
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
---
apiVersion: cloud.google.com/v1
kind: BackendConfig
metadata:
  name: courseware-api-backendconfig
  namespace: courseware
spec:
  timeoutSec: 30
  connectionDraining:
    drainingTimeoutSec: 60
  healthCheck:
    checkIntervalSec: 5
    timeoutSec: 5
    healthyThreshold: 1
    unhealthyThreshold: 3
    type: HTTP
    requestPath: /readyz
    port: 8080
  logging:
    enable: true
    sampleRate: 1.0
  cdn:
    enabled: false
  securityPolicy:
    name: edge-armor-policy
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: courseware-api
  namespace: courseware
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: courseware-api
  minReplicas: 3
  maxReplicas: 40
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 65
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
        - type: Percent
          value: 100
          periodSeconds: 30
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Percent
          value: 20
          periodSeconds: 60
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: courseware-api
  namespace: courseware
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: courseware-api
```

**Puerta de entrada con Gateway API** (el reemplazo moderno de `Ingress` en GKE):

```yaml
# gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: external-gateway
  namespace: courseware
spec:
  gatewayClassName: gke-l7-global-external-managed   # global anycast, Premium Tier
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      tls:
        mode: Terminate
        options:
          networking.gke.io/pre-shared-certs: web-cert
      allowedRoutes:
        namespaces:
          from: Same
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: courseware-route
  namespace: courseware
spec:
  parentRefs:
    - name: external-gateway
  hostnames:
    - "study.example.com"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /api
      backendRefs:
        - name: courseware-api
          port: 80
      timeouts:
        request: 30s
---
apiVersion: networking.gke.io/v1
kind: GCPBackendPolicy
metadata:
  name: courseware-api-policy
  namespace: courseware
spec:
  default:
    timeoutSec: 30
    connectionDraining:
      drainingTimeoutSec: 60
    securityPolicy: edge-armor-policy
    logging:
      enabled: true
      sampleRate: 1000000
  targetRef:
    group: ""
    kind: Service
    name: courseware-api
---
apiVersion: networking.gke.io/v1
kind: HealthCheckPolicy
metadata:
  name: courseware-api-hc
  namespace: courseware
spec:
  default:
    checkIntervalSec: 5
    timeoutSec: 5
    healthyThreshold: 1
    unhealthyThreshold: 3
    config:
      type: HTTP
      httpHealthCheck:
        port: 8080
        requestPath: /readyz
  targetRef:
    group: ""
    kind: Service
    name: courseware-api
```

### 7.3 Servicio de Cloud Run — YAML declarativo

```yaml
# service.yaml — deploy with:
#   gcloud run services replace service.yaml --region us-central1
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: courseware-web
  labels:
    cloud.googleapis.com/location: us-central1
  annotations:
    run.googleapis.com/ingress: all           # or internal-and-cloud-load-balancing
    run.googleapis.com/launch-stage: GA
spec:
  template:
    metadata:
      annotations:
        autoscaling.knative.dev/minScale: "1"    # 1 warm instance kills cold starts
        autoscaling.knative.dev/maxScale: "100"  # hard cost ceiling
        run.googleapis.com/execution-environment: gen2
        run.googleapis.com/cpu-throttling: "false"  # CPU always allocated
        run.googleapis.com/startup-cpu-boost: "true"
        # Direct VPC egress: reach private resources with no connector VMs.
        run.googleapis.com/network-interfaces: >-
          [{"network":"core-vpc","subnetwork":"workloads-us-central1"}]
        run.googleapis.com/vpc-access-egress: private-ranges-only
    spec:
      containerConcurrency: 80
      timeoutSeconds: 300
      serviceAccountName: courseware-web@teachplat-prod-001.iam.gserviceaccount.com
      containers:
        - image: us-central1-docker.pkg.dev/teachplat-prod-001/apps/courseware-web:2.3.0
          ports:
            - name: http1
              containerPort: 8080
          env:
            - name: API_BASE
              value: "https://study.example.com/api"
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: courseware-db-password
                  key: latest
          resources:
            limits:
              cpu: "2"
              memory: 1Gi
          startupProbe:
            httpGet:
              path: /healthz
            failureThreshold: 10
            periodSeconds: 3
          livenessProbe:
            httpGet:
              path: /healthz
            periodSeconds: 30
  traffic:
    - percent: 100
      latestRevision: true
```

---

## 8. Sesiones de CLI con salida real

### 8.1 Inventario: ¿qué estoy comprando, y dónde?

```console
$ gcloud config set project teachplat-prod-001
Updated property [core/project].

$ gcloud compute regions list --filter="name~us-central1 OR name~southamerica-east1" \
    --format="table(name, quotas[0].metric, quotas[0].limit, status)"
NAME                 METRIC  LIMIT   STATUS
southamerica-east1   CPUS    72.0    UP
us-central1          CPUS    2400.0  UP

$ gcloud compute zones list --filter="region:us-central1" --format="value(name,status)"
us-central1-a	UP
us-central1-b	UP
us-central1-c	UP
us-central1-f	UP

$ gcloud compute machine-types describe n2-standard-8 --zone us-central1-a \
    --format="yaml(name,guestCpus,memoryMb,maximumPersistentDisks)"
guestCpus: 8
maximumPersistentDisks: 128
memoryMb: 32768
name: n2-standard-8
```

### 8.2 Compute Engine: una Spot VM, y cómo se ve una preemption

```console
$ gcloud compute instances create batch-worker-01 \
    --zone=us-central1-a \
    --machine-type=n2d-standard-16 \
    --provisioning-model=SPOT \
    --instance-termination-action=DELETE \
    --image-family=debian-12 --image-project=debian-cloud \
    --boot-disk-type=pd-balanced --boot-disk-size=100GB \
    --subnet=workloads-us-central1 --no-address \
    --service-account=mig-workload@teachplat-prod-001.iam.gserviceaccount.com \
    --scopes=cloud-platform \
    --metadata=enable-oslogin=TRUE
Created [https://www.googleapis.com/compute/v1/projects/teachplat-prod-001/zones/us-central1-a/instances/batch-worker-01].
NAME             ZONE           MACHINE_TYPE     PREEMPTIBLE  INTERNAL_IP  EXTERNAL_IP  STATUS
batch-worker-01  us-central1-a  n2d-standard-16  true         10.10.0.14                RUNNING

$ gcloud compute instances describe batch-worker-01 --zone us-central1-a \
    --format="yaml(scheduling)"
scheduling:
  automaticRestart: false
  instanceTerminationAction: DELETE
  onHostMaintenance: TERMINATE
  preemptible: true
  provisioningModel: SPOT

# 41 minutes later the capacity is reclaimed. This is the audit trail:
$ gcloud compute operations list --filter="targetLink~batch-worker-01" \
    --format="table(name, operationType, status, statusMessage)"
NAME                                  OPERATION_TYPE  STATUS  STATUS_MESSAGE
systemevent-1757310488291-62f0a...    compute.instances.preempted  DONE  Instance was preempted.

$ gcloud logging read \
    'resource.type="gce_instance" AND protoPayload.methodName="compute.instances.preempted"' \
    --limit=1 --format="value(timestamp, protoPayload.resourceName)"
2026-09-08T11:48:08.291Z	projects/teachplat-prod-001/zones/us-central1-a/instances/batch-worker-01
```

> **Lección de diseño:** una Spot VM que se elimina a mitad de un job te cuesta el job entero, salvo que el job haga checkpoints. Spot es 60–91% más barato **solo si el workload es reiniciable**. Si no, el costo efectivo es infinito.

### 8.3 GKE Autopilot: crear, desplegar, observar la economía por Pod

```console
$ gcloud container clusters create-auto platform-autopilot \
    --region=us-central1 \
    --network=core-vpc --subnetwork=workloads-us-central1 \
    --cluster-secondary-range-name=pods \
    --services-secondary-range-name=services \
    --release-channel=regular \
    --enable-private-nodes --master-ipv4-cidr=172.16.0.0/28
Note: The Kubelet readonly port (10255) is now deprecated.
Creating cluster platform-autopilot in us-central1... Cluster is being health-checked...working.
Created [https://container.googleapis.com/v1/projects/teachplat-prod-001/zones/us-central1/clusters/platform-autopilot].
NAME                LOCATION     MASTER_VERSION      MASTER_IP      MACHINE_TYPE  NODE_VERSION        NUM_NODES  STATUS
platform-autopilot  us-central1  1.32.4-gke.1106006  34.72.118.204  e2-medium     1.32.4-gke.1106006  3          RUNNING

$ gcloud container clusters get-credentials platform-autopilot --region us-central1
Fetching cluster endpoint and auth data.
kubeconfig entry generated for platform-autopilot.

$ kubectl apply -f workload.yaml
namespace/courseware created
serviceaccount/courseware-api created
deployment.apps/courseware-api created
service/courseware-api created
backendconfig.cloud.google.com/courseware-api-backendconfig created
horizontalpodautoscaler.autoscaling/courseware-api created
poddisruptionbudget.policy/courseware-api created

$ kubectl -n courseware get pods -o wide
NAME                              READY   STATUS    RESTARTS   AGE   IP           NODE                                    NOMINATED NODE
courseware-api-6b8d4c9f77-4kv2p   1/1     Running   0          92s   10.20.1.37   gk3-platform-autopilot-nap-1f3k...-a   <none>
courseware-api-6b8d4c9f77-h9xqd   1/1     Running   0          92s   10.20.3.12   gk3-platform-autopilot-nap-8dj2...-b   <none>
courseware-api-6b8d4c9f77-t2mrb   1/1     Running   0          92s   10.20.5.61   gk3-platform-autopilot-nap-p0xw...-f   <none>

# Confirm the zonal spread the topologySpreadConstraints asked for:
$ kubectl -n courseware get pods -o json | \
    jq -r '.items[] | .spec.nodeName' | \
    xargs -I{} kubectl get node {} -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}' | sort | uniq -c
      1 us-central1-a
      1 us-central1-b
      1 us-central1-f

# Autopilot bills the requests, so read them back explicitly:
$ kubectl -n courseware get pods -o custom-columns=\
NAME:.metadata.name,CPU_REQ:.spec.containers[0].resources.requests.cpu,MEM_REQ:.spec.containers[0].resources.requests.memory
NAME                              CPU_REQ   MEM_REQ
courseware-api-6b8d4c9f77-4kv2p   500m      1Gi
courseware-api-6b8d4c9f77-h9xqd   500m      1Gi
courseware-api-6b8d4c9f77-t2mrb   500m      1Gi
```

### 8.4 Cloud Run: deploy, scale-to-zero, la realidad del cold start

```console
$ gcloud run deploy courseware-web \
    --source=. \
    --region=us-central1 \
    --allow-unauthenticated \
    --min-instances=0 --max-instances=100 \
    --concurrency=80 --cpu=2 --memory=1Gi \
    --execution-environment=gen2
Building using Buildpacks and deploying container to Cloud Run service [courseware-web] in project [teachplat-prod-001] region [us-central1]
✓ Building and deploying... Done.
  ✓ Uploading sources...
  ✓ Building Container... Logs are available at [https://console.cloud.google.com/cloud-build/builds/9f1c...].
  ✓ Creating Revision...
  ✓ Routing traffic...
  ✓ Setting IAM Policy...
Done.
Service [courseware-web] revision [courseware-web-00007-x4t] has been deployed
and is serving 100 percent of traffic.
Service URL: https://courseware-web-3n7qk2wjya-uc.a.run.app

# Cold start, zero instances running:
$ curl -o /dev/null -s -w 'connect=%{time_connect}s ttfb=%{time_starttransfer}s total=%{time_total}s\n' \
    https://courseware-web-3n7qk2wjya-uc.a.run.app/
connect=0.031s ttfb=1.842s total=1.849s

# Warm:
$ curl -o /dev/null -s -w 'connect=%{time_connect}s ttfb=%{time_starttransfer}s total=%{time_total}s\n' \
    https://courseware-web-3n7qk2wjya-uc.a.run.app/
connect=0.028s ttfb=0.061s total=0.064s

# Buy away the cold start with one warm instance — this is the cost/latency dial:
$ gcloud run services update courseware-web --region us-central1 --min-instances=1
OK Deploying... Done.
Service [courseware-web] revision [courseware-web-00008-b2m] is serving 100 percent of traffic.
```

### 8.5 Almacenamiento: clases, ciclo de vida, y qué hizo realmente el tiering

```console
$ gcloud storage buckets create gs://teachplat-prod-001-artifacts \
    --location=US --uniform-bucket-level-access --default-storage-class=STANDARD
Creating gs://teachplat-prod-001-artifacts/...

$ gcloud storage buckets update gs://teachplat-prod-001-artifacts --enable-autoclass
Updating gs://teachplat-prod-001-artifacts/...
  Completed 1

$ gcloud storage buckets describe gs://teachplat-prod-001-artifacts \
    --format="yaml(name,location,locationType,storageClass,autoclass)"
autoclass:
  enabled: true
  terminalStorageClass: ARCHIVE
  toggleTime: '2026-09-08T12:03:41.907000+00:00'
location: US
locationType: multi-region
name: teachplat-prod-001-artifacts
storageClass: STANDARD

$ gcloud storage cp ./course-bundle-2026Q3.tar.zst gs://teachplat-prod-001-artifacts/
Copying file://./course-bundle-2026Q3.tar.zst to gs://teachplat-prod-001-artifacts/course-bundle-2026Q3.tar.zst
  Completed files 1/1 | 4.1GiB/4.1GiB | 118.6MiB/s

$ gcloud storage ls -L gs://teachplat-prod-001-artifacts/course-bundle-2026Q3.tar.zst | \
    grep -E 'Storage class|Content-Length|Time created'
    Content-Length:          4402341888
    Storage class:           STANDARD
    Time created:            Tue, 08 Sep 2026 12:07:55 GMT
```

### 8.6 Load balancer: ¿está sirviendo de verdad?

```console
$ gcloud compute backend-services get-health web-backend --global \
    --format="value(status.healthStatus[].instance.basename(), status.healthStatus[].healthState)"
web-4kv2	HEALTHY
web-h9xq	HEALTHY
web-t2mr	HEALTHY

$ gcloud compute forwarding-rules list --global \
    --format="table(name, IPAddress, portRange, target.basename())"
NAME          IP_ADDRESS      PORT_RANGE  TARGET
web-fr-https  34.117.204.61   443-443     web-https-proxy

$ gcloud compute ssl-certificates describe web-cert --global \
    --format="value(managed.status, managed.domainStatus)"
ACTIVE	{'study.example.com': 'ACTIVE'}

$ curl -sI https://study.example.com/ | head -n 6
HTTP/2 200
content-type: text/html
via: 1.1 google
age: 42
cache-control: public, max-age=3600
alt-svc: h3=":443"; ma=2592000
```

`age: 42` y `via: 1.1 google` juntos son la prueba de que Cloud CDN sirvió esto desde un caché de edge — ese es el ahorro de costo de egress hecho visible.

### 8.7 Las palancas de costo, desde la CLI

```console
$ gcloud recommender recommendations list \
    --project=teachplat-prod-001 \
    --location=us-central1-a \
    --recommender=google.compute.instance.MachineTypeRecommender \
    --format="table(description, primaryImpact.costProjection.cost.units)"
DESCRIPTION                                                          UNITS
Save cost by changing machine type from n2-standard-8 to n2-standard-4.  -117

$ gcloud compute commitments create prod-cud-3y \
    --region=us-central1 \
    --plan=THIRTY_SIX_MONTH \
    --resources=vcpu=200,memory=800GB \
    --type=GENERAL_PURPOSE_N2
Created [https://www.googleapis.com/compute/v1/projects/teachplat-prod-001/regions/us-central1/commitments/prod-cud-3y].

$ gcloud compute commitments list --format="table(name, region, plan, status, resources[].amount)"
NAME          REGION       PLAN              STATUS  AMOUNT
prod-cud-3y   us-central1  THIRTY_SIX_MONTH  ACTIVE  ['200', '819200']

$ gcloud compute project-info describe --format="value(quotas.filter(metric:CPUS).extract(metric,usage,limit))"
CPUS	412.0	2400.0
```

---

## 9. Verificación y diagnóstico de fallas

### 9.1 Checklist de verificación — ejecutalo antes de declarar una landing zone "lista"

```console
# 1. Are the workloads actually spread across zones? (the #1 silent SLA killer)
$ gcloud compute instances list --format="value(zone.basename())" | sort | uniq -c
     10 us-central1-a
     10 us-central1-b
     10 us-central1-f

# 2. Is the cluster regional, not zonal?
$ gcloud container clusters list --format="table(name, location, locationType, status)"
NAME                LOCATION     LOCATION_TYPE  STATUS
platform-autopilot  us-central1  REGION         RUNNING

# 3. Are all LB backends healthy, from the LB's own view (not curl)?
$ gcloud compute backend-services get-health web-backend --global | grep -c 'HEALTHY'
3

# 4. Do any VMs have public IPs they should not have?
$ gcloud compute instances list \
    --format="value(name, networkInterfaces[0].accessConfigs[0].natIP)" | grep -v '^\S*\s*$'
(no output — correct)

# 5. Is private egress working through Cloud NAT?
$ gcloud compute routers get-nat-mapping-info core-nat-router \
    --region us-central1 --format="value(instanceName, natIpPortRanges)" | head -3
web-4kv2	['34.72.9.14:1024-1151']
web-h9xq	['34.72.9.14:1152-1279']
web-t2mr	['34.72.9.14:1280-1407']

# 6. Is anything running that nobody claims? (cost hygiene)
$ gcloud compute disks list --filter="-users:*" --format="table(name, zone.basename(), sizeGb, type.basename())"
NAME                  ZONE           SIZE_GB  TYPE
orphan-data-2025      us-central1-b  2048     pd-ssd
```

Ese último — un `pd-ssd` de 2 TB sin adjuntar — se factura a precio completo para siempre. Discos huérfanos, IPs estáticas sin usar y balanceadores de carga ociosos son los tres ítems más comunes en un post-mortem de "por qué la factura es más alta que el datacenter".

### 9.2 Catálogo de fallas

| Síntoma / cadena de error | Causa raíz | Diagnóstico | Solución |
|---|---|---|---|
| `ZONE_RESOURCE_POOL_EXHAUSTED` al crear una instancia | Google se quedó sin ese machine type en esa zona ahora mismo | `gcloud compute instances create ... --zone` falla; una zona hermana funciona | Usar un **MIG regional** con múltiples `distribution_policy_zones`; para capacidad garantizada, comprar una **reservation**; considerar otra familia de máquina |
| `QUOTA_EXCEEDED` / `Quota 'CPUS' exceeded. Limit: 24.0` | Cuota del proyecto, no capacidad | `gcloud compute project-info describe`, o Consola → IAM → Quotas | Solicitar un aumento de cuota; la cuota es por proyecto **y** por región |
| VM `RUNNING`, app inalcanzable, el LB muestra `UNHEALTHY` | Rangos de origen del health check bloqueados | `gcloud compute backend-services get-health ...`; revisar el firewall | Permitir **35.191.0.0/16** y **130.211.0.0/22** hacia el puerto del backend |
| El LB devuelve `502` con `failed_to_pick_backend` en los logs | No hay backend saludable, o el mapeo de `port_name` es incorrecto | `gcloud logging read 'resource.type="http_load_balancer" AND jsonPayload.statusDetails!=""'` | Corregir el path/puerto del health check; verificar que el `named_port` del MIG coincida con el `port_name` del backend service |
| El LB devuelve `502` con `backend_connection_closed_before_data_sent_to_client` | El keepalive del backend es más corto que el del LB | Comparar el keepalive del servidor de aplicación con el del LB (`timeoutSec`) | Poner el keepalive del backend en **> 620 s**, o bajar el timeout del LB en consecuencia |
| Pods de GKE en `Pending`, evento `IP_SPACE_EXHAUSTED` | El rango secundario de Pods es demasiado chico para nodos × max-pods-per-node | `kubectl describe pod`; `gcloud compute networks subnets describe` | Agregar un CIDR de Pods discontiguo, o bajar `--max-pods-per-node`. **Dimensioná los rangos de Pods en el build — esto es doloroso de cambiar después** |
| Las Spot VMs desaparecen en oleadas | Capacidad regional reclamada | Operaciones `compute.instances.preempted` (§8.2) | Hacer checkpoint del workload; mezclar Spot con una base on-demand; distribuir entre zonas y familias de máquina |
| Cloud NAT: fallas de conexión intermitentes, `nat_allocation_failed` | Agotamiento de puertos de NAT | `gcloud logging read 'resource.type="nat_gateway" AND jsonPayload.allocation_status="DROPPED"'` | Habilitar **dynamic port allocation**, subir `max_ports_per_vm`, agregar IPs de NAT |
| Cloud Run: `503` bajo un pico de tráfico | Techo de `maxScale` alcanzado, o límite de conexiones del backend (p. ej. Cloud SQL) | Métricas de Cloud Run: la cantidad de instancias clavada en el máximo; revisar `container_instance_count` | Subir `maxScale`; agregar connection pooling; subir `containerConcurrency` si la app es limitada por I/O |
| Cloud Run: picos de latencia p99 cada pocos minutos | Cold starts por el scale-to-zero | Comparar TTFB en frío vs. en caliente (§8.4) | `--min-instances=1..N`, `--startup-cpu-boost`, achicar la imagen |
| Autopilot rechaza un Pod: `pods ... is forbidden: violates PodSecurity` / hostPath denegado | Restricciones de seguridad de nodos de Autopilot | `kubectl describe replicaset` para ver el mensaje de admisión | Eliminar los requisitos de privileged/hostPath, o mover ese workload a **GKE Standard** |
| Camino de Interconnect/VPN: los paquetes grandes se cuelgan, los chicos funcionan | Desajuste de MTU / blackhole de PMTUD | `ping -M do -s 1400 <peer>` funciona, `-s 1500` falla | Alinear la MTU de la VPC con la del peer (1460 por defecto; hasta 8896 soportado); asegurar que ICMP tipo 3 código 4 esté permitido |
| DB limitada por disco, CPU ociosa, `await` alto | Techo de IOPS de PD atado al tamaño del disco / cantidad de vCPU de la VM | `iostat -x 1`; comparar contra la tabla documentada de rendimiento de PD | Agrandar el disco, cambiar a `pd-ssd`, o pasar a **Hyperdisk** y aprovisionar IOPS de forma independiente |
| "La nube es más cara que el datacenter" | Precio on-demand, sin CUD/SUD, dimensionamiento 1:1 sobreaprovisionado, recursos huérfanos | `gcloud recommender recommendations list`; export de billing → BigQuery | Rightsizing (§8.7), comprometerse (CUDs), poner en Spot la capa batch, borrar huérfanos, configurar alertas de presupuesto |

### 9.3 La única consulta de diagnóstico para memorizar

```console
$ gcloud logging read \
    'resource.type="http_load_balancer"
     AND httpRequest.status>=500
     AND timestamp>="2026-09-08T00:00:00Z"' \
    --limit=5 \
    --format="table(timestamp, httpRequest.status, jsonPayload.statusDetails, httpRequest.requestUrl)"
TIMESTAMP                       STATUS  STATUS_DETAILS               REQUEST_URL
2026-09-08T13:41:02.118Z        502     failed_to_pick_backend       https://study.example.com/api/topics
2026-09-08T13:41:02.402Z        502     failed_to_pick_backend       https://study.example.com/api/topics
2026-09-08T13:40:58.771Z        503     backend_connection_closed... https://study.example.com/api/render
```

`jsonPayload.statusDetails` es el campo que convierte "el sitio está tirando 502" en una causa raíz específica y accionable. Es el campo de mayor valor en el logging de load balancers de Google Cloud.

---

## 10. Valor de negocio, calculado

### 10.1 Ejemplo trabajado de TCO

**Escenario:** 100 × `n2-standard-8` (8 vCPU / 32 GB) en `us-central1`, corriendo 24×7. Precio on-demand ilustrativo ≈ **$0,3885/hora** (8 × $0,031611 vCPU-hr + 32 × $0,004237 GB-hr). Siempre volvé a derivarlo con la Pricing Calculator; los precios cambian.

| Estrategia | $/hr efectivo por VM | 100 VMs / mes (730 h) | Anual | Δ vs on-demand |
|---|---|---|---|---|
| On-demand, sin descuento | 0,3885 | $28.361 | $340.332 | — |
| On-demand + sustained use discount (ilustrativo ~20% para N2 al 100% del mes) | 0,3108 | $22.688 | $272.256 | −20% |
| CUD basado en recursos a 1 año (~37%) | 0,2448 | $17.870 | $214.440 | −37% |
| **CUD basado en recursos a 3 años (~55%)** | 0,1748 | $12.760 | $153.120 | **−55%** |
| 60 VMs con CUD a 3 años + 40 VMs en Spot (~70% de descuento) | mixto | $10.057 | $120.684 | **−65%** |
| Rightsizing a `n2-standard-4` para el 40% de la flota que está sobreaprovisionada, y luego CUD a 3 años | mixto | $10.208 | $122.496 | −64% |

**La lección que el examen quiere y que la producción impone:** la migración en sí no ahorra dinero. **Rightsizing + compromiso + modelo de aprovisionamiento** ahorran dinero, y esos son tres actos deliberados y separados. Un lift-and-shift 1:1 a precios on-demand es el resultado *más caro* posible, y es el resultado por defecto.

**Referencia de instrumentos de descuento:**

| Instrumento | ¿Se aplica automáticamente? | Plazo | Alcance | Trade-off |
|---|---|---|---|---|
| Sustained use discount (SUD) | Sí | ninguno | Familias elegibles (N1 históricamente hasta ~30%; N2/N2D/C2/C2D hasta ~20%); las familias más nuevas suelen estar excluidas — verificar en la página de precios | Ninguno; gratis |
| CUD basado en recursos | No — lo comprás | 1 o 3 años | vCPU/memoria específicos en una región y familia | Pagás lo uses o no |
| CUD basado en gasto / flexible | No — lo comprás | 1 o 3 años | Un compromiso de gasto en $/hora, flexible entre familias/regiones | Descuento menor que el basado en recursos, mucha más flexibilidad |
| Spot VMs | No — es un modelo de aprovisionamiento | ninguno | Cualquier VM elegible | Preemption; requiere workloads reiniciables |
| Reservations | No | ninguno (o con CUD) | Zona/machine type específicos | Pagás la capacidad reservada incluso cuando está ociosa; garantiza disponibilidad |

### 10.2 Aritmética de disponibilidad — por qué la ubicación *es* el SLA

Las dependencias en serie se multiplican. Un stack de tres capas, todo en una zona:

```
A_total = A_compute × A_database × A_storage
        = 0.999 × 0.999 × 0.999
        = 0.997002  →  ~99.70%  →  ~2.6 hours of downtime per month
```

El mismo stack distribuido entre zonas dentro de una región, con un LB global al frente:

```
A_total = A_LB × A_compute(multi-zone) × A_database(HA) × A_storage(regional)
        = 0.9999 × 0.9999 × 0.9995 × 0.999
        = 0.998301  →  ~99.83%
```

…y ahora el término dominante es el *componente con el SLA más bajo*, no la capa de cómputo. Esa es la conclusión de ingeniería correcta: **una vez que distribuís el cómputo, tu techo de disponibilidad lo fija tu dependencia gestionada más débil**, así que la próxima inversión va ahí — no en más redundancia de cómputo.

**SLAs representativos** (confirmalos siempre en la página de SLA de §12, son contractuales y versionados):

| Servicio | SLA |
|---|---|
| Compute Engine, instancia única | 99,9% |
| Compute Engine, multi-zona (LB entre ≥2 zonas) | 99,99% |
| GKE control plane regional / control plane zonal | 99,95% / 99,5% |
| Cloud Run | 99,95% |
| Cloud Load Balancing | 99,99% |
| Cloud DNS | 100% |
| Cloud Storage — Standard multi-region / Standard regional | 99,95% / 99,9% |
| Cloud SQL, configuración HA | 99,95% |
| HA VPN (dos interfaces) / Dedicated Interconnect (topología 99,99%) | 99,99% / 99,99% |

> **Un SLA es un contrato de reembolso, no una promesa de uptime.** Los créditos no compensan un trimestre de ingresos perdido. Diseñá para el SLO que realmente necesitás; usá el SLA para elegir el *tier de arquitectura* que hace alcanzable ese SLO.

### 10.3 Valor de negocio no financiero (enunciá esto explícitamente en un design review)

| Valor | Mecanismo | Cómo medirlo |
|---|---|---|
| **Time to market** | `gcloud run deploy` reemplaza un ciclo de compras | Lead time for change (DORA) |
| **Elasticidad** | El autoscaling absorbe picos que antes requerían 12 meses de capex dimensionado al pico | Ratio de capacidad pico:valle; costo por evento pico |
| **Transferencia de riesgo** | Google es dueño de la falla de hardware, la seguridad física y (en los tiers gestionados) el parcheo | Reducción de horas de ops no planificadas |
| **Alcance** | Una IP anycast global pone tu servicio sobre el backbone en todas las regiones a la vez | Latencia p95 por geografía, antes/después |
| **Sostenibilidad** | Google iguala su consumo anual de electricidad con compras de energía renovable y publica datos de carbono por región; Active Assist expone opciones de región de bajo carbono | Huella de carbono bruta reportada; CFE% de la región |
| **Foco** | Los ingenieros dejan de rackear, parchear y planificar capacidad | % del tiempo de ingeniería en producto vs. ops indiferenciado |

---

## 11. Mapeo orientado al examen y trampas

### 11.1 Escenario → respuesta

| Escenario en la pregunta | Oferta correcta | Por qué |
|---|---|---|
| "Migrar nuestro datacenter VMware en 12 meses con cambios mínimos" | **Google Cloud VMware Engine** | Mismo hipervisor, mismas herramientas, sin re-plataformar |
| "Corremos Oracle sobre hardware que no podemos virtualizar por licenciamiento" | **Bare Metal Solution** | Físico, certificado, adyacente a la región |
| "Nuestro rendering batch tolera interrupciones y lo queremos barato" | Compute Engine con **Spot VMs** | 60–91% de descuento, workload reiniciable |
| "VMs de producción predecibles 24×7 por los próximos 3 años" | Compute Engine + **committed use discount a 3 años** | El estado estable es exactamente lo que los CUDs tarifan |
| "Una plataforma de microservicios containerizada para muchos equipos, con poco personal de ops" | **GKE Autopilot** | Google gestiona los nodos; la facturación por Pod habilita el chargeback |
| "API web picuda, ociosa de noche, no queremos gestionar servidores" | **Cloud Run** | Escala a cero, facturación por request |
| "Redimensionar una imagen cada vez que un archivo aterriza en un bucket" | **Cloud Run functions** | Dirigido por eventos, propósito único |
| "Guardar 7 años de registros de compliance, accedidos una vez al año" | **Cloud Storage Archive** + Bucket Lock | El precio de almacenamiento más bajo, retención inmutable |
| "Servir a una audiencia global desde una IP con protección DDoS" | Application LB externo global + **Cloud CDN** + **Cloud Armor** sobre Premium Tier | Anycast + caché en el edge + WAF |
| "500 TB para mover y un enlace de 1 Gbps" | **Transfer Appliance** | Las cuentas de la WAN no cierran |
| "10 Gbps privados y dedicados hacia nuestro colo con latencia predecible" | **Dedicated Interconnect** | Circuito físico; tarifas de egress más bajas |
| "Conectividad privada en días, no meses, ancho de banda moderado" | **HA VPN** | IPsec sobre internet, SLA de 99,99% |
| "¿Qué región tiene el menor carbono y cumple con la residencia de datos en la UE?" | Selección de región usando los datos publicados de energía libre de carbono + regiones de la UE | La elección de región es una decisión de diseño de primer orden |

### 11.2 Trampas que atrapan a ingenieros con experiencia

1. **"Multi-region" ≠ "multi-zona".** Un bucket regional de Cloud Storage sobrevive la pérdida de una zona; no sobrevive la pérdida de una región. Leé el tipo de ubicación, no el nombre de la región.
2. **Las letras de zona son por proyecto.** `us-central1-a` en tu proyecto no es necesariamente la misma zona física que en otro proyecto. Nunca coordines un diseño entre proyectos alrededor de letras de zona.
3. **Archive no es cinta.** La latencia de primer byte es de milisegundos. Las preguntas que implican "horas para restaurar" están describiendo el producto de un competidor o un modelo mental viejo.
4. **La VPC es global.** Cualquier respuesta que requiera un gateway/VPN para dos regiones *dentro de la misma VPC* es incorrecta.
5. **El balanceo de carga global requiere Premium Tier.** Si el escenario dice "el egress más barato" *y* "una única IP global", esos están en tensión — leé cuál de los dos prioriza realmente la pregunta.
6. **Preemptible ≠ Spot.** Spot es el modelo actual, sin tope de 24 horas. Las Preemptible VMs legacy tenían uno.
7. **Autopilot no es "GKE pero más barato".** Es más barato para workloads picudos y bien dimensionados, y puede ser *más* caro para flotas densas y muy utilizadas donde ya hacías buen bin-packing.
8. **Local SSD es efímero.** Cualquier pregunta que empareje "local SSD" con "debe sobrevivir un reinicio" es un distractor.
9. **El SLA está condicionado a tu arquitectura.** El 99,99% en Compute Engine requiere instancias en **dos o más zonas** detrás de un balanceador de carga. Una VM única nunca obtiene 99,99%, sin importar el machine type.
10. **El IOPS de PD escala con el tamaño *y* con la cantidad de vCPU.** "Hacé el disco más rápido y ya" no es una respuesta válida en PD — sí lo es en Hyperdisk.

---

## 12. Referencias

**Guía de examen**
- Cloud Digital Leader exam guide (PDF): https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
- Página de certificación: https://cloud.google.com/learn/certification/cloud-digital-leader

**Infraestructura global**
- Ubicaciones globales — regiones y zonas: https://cloud.google.com/about/locations
- Concepto de geografía y regiones: https://cloud.google.com/docs/geography-and-regions
- Regiones y zonas (Compute Engine): https://cloud.google.com/compute/docs/regions-zones
- Energía libre de carbono para las regiones de Google Cloud: https://cloud.google.com/sustainability/region-carbon

**Cómputo**
- Documentación de Compute Engine: https://cloud.google.com/compute/docs
- Guía de recursos y comparación de familias de máquina: https://cloud.google.com/compute/docs/machine-resource
- Spot VMs: https://cloud.google.com/compute/docs/instances/spot
- Managed instance groups: https://cloud.google.com/compute/docs/instance-groups
- Sole-tenant nodes: https://cloud.google.com/compute/docs/nodes/sole-tenant-nodes
- Documentación de Google Kubernetes Engine: https://cloud.google.com/kubernetes-engine/docs
- Descripción general de GKE Autopilot: https://cloud.google.com/kubernetes-engine/docs/concepts/autopilot-overview
- Comparación Autopilot vs Standard: https://cloud.google.com/kubernetes-engine/docs/resources/autopilot-standard-feature-comparison
- Documentación de Cloud Run: https://cloud.google.com/run/docs
- Cloud Run functions: https://cloud.google.com/functions/docs
- Documentación de App Engine: https://cloud.google.com/appengine/docs
- Bare Metal Solution: https://cloud.google.com/bare-metal/docs
- Google Cloud VMware Engine: https://cloud.google.com/vmware-engine/docs

**Almacenamiento**
- Documentación de Cloud Storage: https://cloud.google.com/storage/docs
- Storage classes: https://cloud.google.com/storage/docs/storage-classes
- Object Lifecycle Management: https://cloud.google.com/storage/docs/lifecycle
- Autoclass: https://cloud.google.com/storage/docs/autoclass
- Persistent Disk e Hyperdisk (opciones de almacenamiento): https://cloud.google.com/compute/docs/disks
- Hyperdisk: https://cloud.google.com/compute/docs/disks/hyperdisks
- Local SSD: https://cloud.google.com/compute/docs/disks/local-ssd
- Filestore: https://cloud.google.com/filestore/docs
- Google Cloud NetApp Volumes: https://cloud.google.com/netapp/volumes/docs

**Networking**
- Descripción general de VPC: https://cloud.google.com/vpc/docs/vpc
- Shared VPC: https://cloud.google.com/vpc/docs/shared-vpc
- Network Service Tiers: https://cloud.google.com/network-tiers/docs/overview
- Descripción general de Cloud Load Balancing: https://cloud.google.com/load-balancing/docs/load-balancing-overview
- Elegir un balanceador de carga: https://cloud.google.com/load-balancing/docs/choosing-load-balancer
- Cloud CDN: https://cloud.google.com/cdn/docs
- Cloud Armor: https://cloud.google.com/armor/docs
- Cloud DNS: https://cloud.google.com/dns/docs
- Cloud NAT: https://cloud.google.com/nat/docs/overview
- Cloud Interconnect: https://cloud.google.com/network-connectivity/docs/interconnect
- Cloud VPN (HA VPN): https://cloud.google.com/network-connectivity/docs/vpn/concepts/overview
- Private Service Connect: https://cloud.google.com/vpc/docs/private-service-connect
- Network Connectivity Center: https://cloud.google.com/network-connectivity/docs/network-connectivity-center

**Migración**
- Migration Center: https://cloud.google.com/migration-center/docs
- Migrate to Virtual Machines: https://cloud.google.com/migrate/virtual-machines/docs
- Migrate to Containers: https://cloud.google.com/migrate/containers/docs
- Database Migration Service: https://cloud.google.com/database-migration/docs
- Storage Transfer Service: https://cloud.google.com/storage-transfer/docs
- Transfer Appliance: https://cloud.google.com/transfer-appliance/docs

**Costo y confiabilidad**
- Google Cloud Pricing Calculator: https://cloud.google.com/products/calculator
- Committed use discounts: https://cloud.google.com/docs/cus-discounts
- Sustained use discounts: https://cloud.google.com/compute/docs/sustained-use-discounts
- Precios de Compute Engine: https://cloud.google.com/compute/all-pricing
- Acuerdos de nivel de servicio de Google Cloud: https://cloud.google.com/terms/sla
- Architecture Framework — confiabilidad: https://cloud.google.com/architecture/framework/reliability
- Architecture Framework — optimización de costos: https://cloud.google.com/architecture/framework/cost-optimization
- Active Assist / Recommender: https://cloud.google.com/recommender/docs

**Arquitecturas de referencia usadas en los manifiestos**
- Balanceo de carga container-native en GKE (NEGs): https://cloud.google.com/kubernetes-engine/docs/concepts/container-native-load-balancing
- GKE Gateway API: https://cloud.google.com/kubernetes-engine/docs/concepts/gateway-api
- Referencia YAML de Cloud Run: https://cloud.google.com/run/docs/reference/yaml/v1
- Terraform Google provider: https://registry.terraform.io/providers/hashicorp/google/latest/docs