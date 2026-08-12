# 361.1 Conceptos y teoría de Alta Disponibilidad

> **Peso: 10** · Examen 306-300 v3.0 · Objetivo 361 *High Availability Cluster Management*
> Perfil del autor: Principal Platform Architect / Senior SRE. Esta es la teoría sobre la que se construye cada objetivo posterior (Pacemaker, Corosync, LVS, DRBD, GFS2). Si el quórum, el fencing y la aritmética de la disponibilidad no se interiorizan aquí, cada tema práctico posterior se convierte en cargo-culting.

---

## 1. El problema de producción: la disponibilidad no es una propiedad que se compra, es una que se diseña

Un único servidor tiene un techo de disponibilidad fijado por su componente menos fiable. Un servidor commodity con piezas de calidad falla unas pocas veces por década; una fuente de alimentación, un disco, un kernel panic, un `dnf update` mal hecho, el disparo de una PDU del centro de datos, o un descuidado `systemctl stop` colapsan ese número al instante. Con n=1 nodos la pregunta nunca es *«¿fallará?»* sino *«¿qué le pasa al servicio cuando falle?»*

La Alta Disponibilidad es la disciplina de eliminar los **puntos únicos de fallo (SPOF)** para que el fallo de cualquier componente se sobreviva automáticamente, dentro de un tiempo acotado, sin intervención humana y sin corrupción de datos. Tres restricciones son estructurales y luchan entre sí:

1. **Detección** — el clúster debe *saber* que un nodo/recurso falló. Una detección demasiado rápida provoca failovers falsos (flapping); demasiado lenta infla el downtime.
2. **Recuperación** — el servicio debe reiniciarse en otro lugar. La recuperación exige que el nodo fallido *demostrablemente* ya no esté escribiendo en el estado compartido — por esto existe el **fencing**.
3. **Consistencia** — ante una partición de red, como mucho un lado puede actuar. Por esto existe el **quórum**.

El modelo mental ingenuo — «agregá un segundo servidor y una IP flotante» — es exactamente cómo se construye un **split-brain**: dos nodos que creen cada uno ser el superviviente, ambos montando el mismo filesystem, ambos respondiendo la VIP, corrompiendo datos silenciosamente. La teoría de HA es en gran medida el conjunto de mecanismos que hacen eso imposible.

### 1.1 SPOF y dominios de fallo

Un **dominio de fallo** es el radio de impacto de un único fallo: un disco, una NIC, un host, un rack, una PDU, un switch top-of-rack, una zona de disponibilidad, una región. La HA solo tiene sentido *en relación con un dominio de fallo declarado*. Dos nodos Pacemaker en el mismo rack sobreviven al fallo de un nodo pero no al fallo de la PDU del rack — el rack sigue siendo un SPOF. Un diseño genuinamente tolerante a fallos empuja la redundancia *hacia arriba en la jerarquía de dominios de fallo* hasta que el SPOF residual sea aceptable para el SLA.

```
Component  →  Host  →  Rack  →  Row/PDU  →  AZ/Room  →  Region  →  Provider
   RAID       cluster    2 racks   dual PDU   multi-AZ   DR site   multi-cloud
```

Cada peldaño que se sube en la escalera multiplica el costo y la latencia y complica la consistencia. El trabajo del arquitecto es comprar el *peldaño más barato que cumpla el SLA*, no el más alto.

---

## 2. La aritmética de la disponibilidad

### 2.1 La identidad fundamental

$$A = \frac{\text{MTBF}}{\text{MTBF} + \text{MTTR}} = \frac{\text{MTTF}}{\text{MTTF} + \text{MTTR}}, \qquad \text{MTBF} = \text{MTTF} + \text{MTTR}$$

| Símbolo | Nombre | Significado |
|---|---|---|
| **MTTF** | Mean Time To Failure | Intervalo promedio de *uptime* — cuánto corre una unidad funcionando antes de romperse (marco no reparable). |
| **MTTR** | Mean Time To Repair/Recovery | Intervalo promedio de *downtime* — detectar + decidir + actuar + verificar. En un clúster es el tiempo de failover, no el tiempo de reparación humana. |
| **MTBF** | Mean Time Between Failures | Ciclo completo = MTTF + MTTR (marco reparable). |
| **MTBSI** | Mean Time Between System Incidents | Ciclo que incluye incidentes de *servicio*, no solo de hardware. |

**La idea estructural para los SREs:** la disponibilidad está dominada por el término que realmente podés mover. Casi nunca mejorás el MTTF (el hardware es lo que es); aplastás el **MTTR**. Pasar de un failover humano de 30 minutos a uno automatizado de 30 segundos mejora la disponibilidad en tres órdenes de magnitud *sin tocar el hardware*. El clustering de HA es fundamentalmente una tecnología de reducción del MTTR.

### 2.2 Los «nueves» — el número en el que está escrito todo SLA

$$\text{Downtime}_{\text{año}} = (1 - A)\times 365.25\ \text{días}$$

| Disponibilidad | «Nueves» | Downtime / año | / mes | / semana | Nivel típico |
|---|---|---|---|---|---|
| 90 % | un nueve | 36.5 días | 73 h | 16.8 h | juguete / dev |
| 99 % | dos nueves | 3.65 días | 7.30 h | 1.68 h | herramientas internas |
| 99.9 % | tres nueves | 8.77 h | 43.8 min | 10.1 min | SaaS estándar |
| 99.95 % | — | 4.38 h | 21.9 min | 5.04 min | nivel empresarial |
| 99.99 % | cuatro nueves | 52.6 min | 4.38 min | 1.01 min | objetivo de clúster HA |
| 99.999 % | cinco nueves | 5.26 min | 26.3 s | 6.05 s | telco / carrier |
| 99.9999 % | seis nueves | 31.6 s | 2.63 s | 0.61 s | exótico / rara vez real |

**Leer la tabla como un arquitecto:** cada nueve cuesta aproximadamente un orden de magnitud más que el anterior para una ganancia lineal a los ojos del cliente. Cinco nueves (5.26 min/año) significa que tu *presupuesto anual completo de downtime* — incluyendo el mantenimiento planificado, el parcheo del kernel y los eventos de failover — es más chico que un solo reboot. Por eso los sistemas de cinco nueves hacen rolling upgrades y nunca bajan el clúster entero. La curva de rendimientos decrecientes es el hecho económico central de la HA: **sabé qué nueve está pagando el negocio, y pará ahí.**

### 2.3 Composición: dependencias en serie vs redundancia en paralelo

Un servicio es un *grafo* de componentes. Cómo se combinan sus disponibilidades depende de la topología.

**Serie (cadena de dependencias)** — la petición necesita *todos*; el fallo de cualquiera hace fallar el conjunto:

$$A_{\text{serie}} = A_1 \times A_2 \times \dots \times A_n$$

La composición en serie es corrosiva: encadenar componentes *siempre baja* la disponibilidad por debajo del eslabón más débil. Diez componentes independientes de 99.9 % en serie = $0.999^{10} \approx 99.0\,\%$ — perdiste un nueve completo solo por tener una cadena. Por esto los fan-outs de microservicios y las cadenas de dependencias largas son un pasivo para la disponibilidad.

**Paralelo (redundante)** — el servicio necesita que *cualquiera* sobreviva; falla solo si fallan *todos*:

$$A_{\text{paralelo}} = 1 - \prod_{i=1}^{n}(1 - A_i)$$

La redundancia es multiplicativa en la dirección *correcta*. Dos nodos de 99 % en paralelo:

$$A = 1 - (1 - 0.99)^2 = 1 - 0.0001 = 99.99\,\%$$

Dos nueves de hardware → cuatro nueves de servicio, puramente por un segundo nodo. **Esta única ecuación es la justificación matemática de todo el objetivo.** Agregá un tercer nodo: $1-(0.01)^3 = 99.9999\,\%$.

**La trampa que esconde la ecuación:** la fórmula asume fallos *independientes*. Una PDU compartida, un switch compartido, un servidor NFS compartido, un control plane compartido, bugs de software correlacionados, o un mismo deploy de configuración defectuosa hacen que los fallos estén *correlacionados*, y los fallos correlacionados destruyen el producto. La matemática real de la redundancia vale tanto como la independencia de tus dominios de fallo. Esta es la versión cuantitativa de §1.1.

### 2.4 Ejemplo resuelto (nivel entrevista)

Una capa web stateless: 3 nodos de aplicación (99.5 % cada uno) detrás de un load balancer (99.95 %), hablando con un par de bases de datos HA (99.9 % cada una, activo/pasivo).

- Capa de aplicación (paralelo, necesita ≥1): $1-(1-0.995)^3 = 1 - 1.25\times10^{-7} \approx 99.99999\%$
- Par de BD (paralelo): $1-(1-0.999)^2 = 99.9999\%$
- Extremo a extremo (serie: LB × capa-app × BD): $0.9995 \times 0.9999999 \times 0.999999 \approx 99.949\%$

El **load balancer ahora es el SPOF** — domina el producto en serie. La lección se generaliza: después de que armás clúster con todo, la disponibilidad queda topada por aquello que *no* hiciste redundante. Un solo LB te topa en 99.95 % sin importar cuántos nodos de aplicación agregues. Solución: LBs redundantes (VRRP/keepalived), que es exactamente por lo que existe §9.

### 2.5 SLA / SLO / SLI / error budget

| Término | Definición | Responsable |
|---|---|---|
| **SLI** | Service Level *Indicator* — el número medido (p. ej. ratio de peticiones exitosas, latencia p99). | medido |
| **SLO** | Service Level *Objective* — objetivo interno que el SLI debe cumplir (p. ej. 99.95 % en 28 días). | ingeniería |
| **SLA** | Service Level *Agreement* — promesa contractual con penalización financiera; siempre **más laxa** que el SLO. | negocio/legal |
| **Error budget** | $1 - \text{SLO}$ — la indisponibilidad *permitida*. Se gasta en releases, mantenimiento e incidentes. | SRE |

El error budget reformula la disponibilidad de «nunca falles» a «no falles más que X». Un SLO de 99.9 % otorga 43.8 min/mes de presupuesto; un rollout riesgoso o una actualización planificada de Corosync lo *gasta* deliberadamente. Los clústeres de HA existen para mantener el gasto no planificado cerca de cero, de modo que el presupuesto financie el *cambio*.

---

## 3. Modelos de redundancia

| Modelo | Significado | Costo de reserva | Sobrevive | Uso típico |
|---|---|---|---|---|
| **N** | Sin redundancia — N unidades cargan la carga, todas necesarias. | 0 % | nada | dev |
| **N+1** | Una reserva además de las N necesarias. | ~1/N | cualquier fallo *único* | la mayoría de los clústeres HA |
| **N+M** | M reservas. | M/N | hasta M simultáneos | flotas grandes |
| **2N** | Duplicado completo de todo el sistema. | 100 % | todo el conjunto primario | DR activo/pasivo |
| **2N+1** | Duplicado completo más uno. | >100 % | conjunto primario + 1 | telco de cinco nueves |
| **Geo / 3 sitios** | Copias entre regiones. | 200 %+ | pérdida de región/AZ | DR, tolerancia a desastres |

N+1 es el punto óptimo para la mayoría de los clústeres Pacemaker: un clúster de 3 nodos es «2 trabajando + 1 de reserva», sobrevive a cualquier nodo único y mantiene el quórum (ver §5). 2N es el modelo detrás de los pares de bases de datos activo/pasivo y del DR entre sitios.

---

## 4. Taxonomías de clúster

### 4.1 Tres propósitos de clúster (no los confundas)

| Tipo de clúster | Objetivo | Qué optimiza | ¿Reparte carga? | Stack de ejemplo |
|---|---|---|---|---|
| **High Availability (failover)** | Mantener un servicio *arriba* pese a la pérdida de un nodo. | MTTR / continuidad | normalmente no | Pacemaker + Corosync |
| **Load Balancing** | Distribuir la carga de peticiones entre muchos backends; escala + disponibilidad. | throughput + disponibilidad | sí | LVS/IPVS, HAProxy, keepalived |
| **High Performance Computing (HPC)** | Paralelizar un cálculo grande. | wall-clock de un trabajo | paralelismo de trabajos | Slurm, MPI, Beowulf |

El examen evalúa que *diferencies* estos. HA ≠ balanceo de carga: un clúster HA de failover puede correr enteramente activo/pasivo con el standby ocioso (nada de reparto de carga), mientras que un clúster de balanceo reparte carga pero uno ingenuo no tiene failover del *balanceador en sí*. Los sistemas de producción los componen: clúster de LB al frente, clúster HA para los backends con estado.

### 4.2 Activo/Pasivo vs Activo/Activo

| Dimensión | Activo/Pasivo (failover) | Activo/Activo (reparto de carga) |
|---|---|---|
| Utilización del standby | Ocioso o «hot standby» — capacidad desperdiciada | Todos los nodos sirven — utilización plena |
| Capacidad tras 1 fallo | 100 % (la reserva toma toda la carga) | **Degradada** — los nodos supervivientes absorben la parte del nodo caído |
| Requisito de la aplicación | Cualquier app; no necesita coordinación | La app debe ser *cluster-aware* (acceso concurrente seguro) |
| Estado compartido | Un único dueño a la vez (seguro) | Escritores concurrentes → necesita FS de clúster (GFS2/OCFS2) + DLM, o sharding shared-nothing |
| Visibilidad del failover | Breve corte durante la toma de control | Casi transparente (los nodos supervivientes ya están activos) |
| Complejidad | Menor | Mayor (locking distribuido, mayor riesgo de split-brain) |
| Eficiencia de costo | Pobre (pagás por lo ocioso) | Buena (todo el fierro trabaja) |
| Uso típico | Bases de datos, servicios stateful de un solo escritor | Capas web, réplicas de lectura, servicios stateless, FS en clúster |

**Trampa de planificación de capacidad:** activo/activo parece más barato porque ningún nodo está ocioso — pero si corrés cada nodo al 90 % y uno muere, los supervivientes deben absorber su carga y se sobrecargan de inmediato. Un activo/activo seguro se dimensiona para que **N nodos supervivientes puedan cargar la carga de N+1** — es decir, *igual* mantenés un margen equivalente a la reserva pasiva. El argumento de «sin capacidad desperdiciada» solo es cierto si de todos modos sobreaprovisionás. En la práctica, activo/activo compra *failover transparente y escala horizontal*, no capacidad gratis.

### 4.3 Temperaturas del standby

| Standby | Estado de la reserva | Tiempo de failover | Costo |
|---|---|---|---|
| **Frío (Cold)** | Apagado / no aprovisionado | minutos–horas | el más bajo |
| **Tibio (Warm)** | Encendido, servicio detenido, datos sincronizando | segundos–minutos | medio |
| **Caliente (Hot)** | Encendido, servicio cargado, estado actualizado | sub-segundo–segundos | el más alto |

---

## 5. Quórum — el mecanismo que decide *quién tiene permitido actuar*

### 5.1 El problema que resuelve

Cuando el interconnect del clúster se particiona, cada lado sigue viéndose a sí mismo y (falsamente) concluye que el otro lado está muerto. Si entonces ambos lados inician el servicio y toman el almacenamiento compartido, obtenés **split-brain** y corrupción de datos. El quórum es la regla de que **como mucho una partición tiene permitido correr recursos** — la partición que tiene la *mayoría* de los votos.

$$\text{Con quórum} \iff \text{votos}_{\text{partición}} \ge \left\lfloor \frac{\text{expected\_votes}}{2} \right\rfloor + 1$$

Un clúster de 5 nodos (expected_votes=5) necesita ≥3 para tener quórum. Una partición 3–2 → el lado de 3 corre, el lado de 2 *se autoinhibe* (por defecto en Pacemaker `no-quorum-policy=stop`). Solo un lado puede tener jamás la mayoría, así que el split-brain es aritméticamente imposible **mientras el fencing garantice que el lado perdedor realmente se detiene** (quórum y fencing son un par, nunca uno solo — ver §6).

### 5.2 El problema de dos nodos

Dos nodos, un voto cada uno, expected_votes=2 → la mayoría necesita 2. Cualquier fallo único deja 1 voto → **ninguna partición tiene jamás quórum**, así que un superviviente sano se negaría a correr. Inútil. Tres soluciones canónicas:

| Solución | Mecanismo | Compromiso |
|---|---|---|
| **`two_node: 1`** (Corosync) | Fija el quórum en 1 y fuerza `wait_for_all`; depende **enteramente del fencing** para prevenir el split-brain. | Ambos lados creen tener quórum en una partición → *deben* hacer fencing, o corrompés datos. |
| **Quorum device (qdevice/qnetd)** | Un árbitro externo liviano emite un voto de desempate. | Agrega un tercer host (pero no un nodo de clúster completo). La respuesta más limpia para 2 nodos. |
| **SBD + watchdog** | Píldora envenenada en el almacenamiento compartido + watchdog de hardware que autofencea al perdedor. | Necesita un dispositivo de bloque compartido o un watchdog fiable. |

### 5.3 Ajustes de votequorum de Corosync (sabelos al dedillo)

| Opción | Efecto |
|---|---|
| `two_node: 1` | Modo dos nodos; quorum=1; habilita automáticamente `wait_for_all`. |
| `wait_for_all: 1` | En un arranque en frío el clúster está *sin quórum* hasta que **cada** nodo haya sido visto una vez. Evita que un nodo que arranca haga fencing a un par que tarda en bootear. |
| `last_man_standing: 1` | Recalcula dinámicamente `expected_votes` a medida que los nodos salen limpiamente, para que un clúster que se encoge pueda mantener el quórum hasta el último nodo. |
| `last_man_standing_window` | Tiempo de asentamiento (ms) antes de que LMS recalcule. |
| `auto_tie_breaker: 1` | Ante una división exacta 50/50, la partición que contiene el nodo con el nodeid más bajo (por defecto) mantiene el quórum. |
| `expected_votes` | Total de votos en un clúster sano. |
| `quorum_gain / device votes` | Votos extra aportados por un qdevice. |

**Advertencia sobre LMS:** `last_man_standing` dejará tranquilamente que un clúster se encoja hasta un único nodo superviviente con quórum — potente, pero solo seguro cuando el fencing es sólido como una roca; de lo contrario es un generador de split-brain. Además es incompatible con un qdevice en el mismo clúster.

---

## 6. Fencing / STONITH — *«el único clúster en el que podés confiar es aquel donde el perdedor está demostrablemente muerto»*

### 6.1 Por qué el quórum no alcanza

El quórum le dice al lado *perdedor* que se detenga — pero un nodo colgado, un kernel congelado, una ruta de I/O trabada, o un nodo que perdió su interconnect pero no su almacenamiento pueden **no obedecer**. Podría seguir escribiendo en la SAN o respondiendo la VIP. El **fencing** (a.k.a. **STONITH — Shoot The Other Node In The Head**) elimina *a la fuerza* al nodo sospechoso de los recursos compartidos para que el superviviente pueda tomar el control *de forma segura*. Sin fencing, Pacemaker se negará (correctamente) a recuperar recursos — un clúster con `stonith-enabled=false` es una demo, nunca producción.

### 6.2 Métodos de fencing

| Método | Mecanismo | Ejemplos de agentes | Notas |
|---|---|---|---|
| **Fencing de energía / de nodo** | Cortar/ciclar la energía de la máquina. | `fence_ipmilan`, `fence_ilo`, `fence_idrac`, `fence_apc` (PDU), `fence_vmware`, `fence_aws` | El más fiable — un nodo apagado no escribe nada. Necesita acceso out-of-band (IPMI/BMC). |
| **Fencing de almacenamiento / de fabric** | Revocar el acceso del nodo al almacenamiento compartido. | SCSI-3 PR (`fence_scsi`), `fence_mpath`, zoning de fabric | El nodo sigue arriba pero no puede tocar los datos. |
| **SBD (Storage-Based Death)** | Píldora envenenada escrita en un «slot» de bloque compartido + un **watchdog de hardware** que autoreinicia el nodo. | `sbd` + `fence_sbd` | Funciona sin BMC; ideal para VMs / sin IPMI. El watchdog es el ejecutor de última instancia. |
| **Fencing de fabric / de switch** | Deshabilitar el puerto de switch del nodo. | `fence_ifmib`, agentes de switch gestionado | Aísla el acceso de red. |

### 6.3 Patologías del fencing

- **Carrera de fencing / bucle de fencing:** en una partición cada lado intenta hacer fencing al otro; gana el BMC más rápido. Una carrera 50/50 puede dejar a *ambos* muertos o en reboot ping-pong. Mitigaciones: `fencing delay` (`pcmk_delay_base` / `pcmk_delay_max`), fencing condicionado al quórum (solo el lado con quórum hace fencing), o un número impar de nodos / qdevice para romper la simetría.
- **`fence_ipmilan` con energía compartida de la placa:** si el IPMI comparte el riel de energía de la mainboard, un nodo realmente muerto no puede responder a su propio BMC → el fencing «falla» → el clúster se bloquea. Usá un agente basado en PDU *separado* o SBD como topología de fencing de respaldo.
- **Fallback de topología:** Pacemaker soporta *niveles* de fencing — probar IPMI primero, caer a PDU — para que un único fallo de BMC no atasque la recuperación.

---

## 7. Split-brain y particionamiento de red

**Split-brain** = dos (o más) particiones que deciden independientemente cada una ser la autoritativa, ambas corriendo el recurso, ambas mutando el estado compartido → **corrupción irreversible**. Es el modo de fallo que la teoría de HA existe para prevenir, y se previene por la *combinación*:

```
Network partition  →  Quorum says "only the majority may act"
                   →  Fencing guarantees the minority is actually stopped
                   →  ∴ at most one active writer  ⇒ no corruption
```

Quitá *cualquiera* de las dos patas y la garantía se derrumba: el quórum sin fencing confía en que un nodo posiblemente colgado obedezca; el fencing sin quórum deja que una minoría haga fencing a la mayoría (una partición de 1 nodo asesinando a los 2 sanos). El examen quiere que declares que **el quórum decide, el fencing hace cumplir, y el split-brain es lo que ambos juntos previenen.**

**Conciencia del particionamiento de red:** las particiones surgen de fallos de switch, discordancias de MTU/jumbo-frame, tormentas de convergencia de spanning-tree, interconnects saturados (pérdida de token de Corosync), descartes del firewall en los puertos del ring (UDP 5404/5405), o ruteo asimétrico. Buena práctica: **interconnects de clúster redundantes y dedicados** (Corosync ring0/ring1 en NICs/switches separados, transporte `knet` con redundancia de enlace) para que un único fallo de red no parezca la muerte de un nodo.

---

## 8. Recursos de clúster y tipos de recursos

Un **recurso** es cualquier cosa que el gestor de clúster (Pacemaker) inicia, detiene, monitorea y recupera — una VIP, un montaje de filesystem, una base de datos, una instancia de apache. Los recursos son manejados por **Resource Agents (RA)** que implementan un contrato `start / stop / monitor / (promote/demote)`.

### 8.1 Clases de resource-agent

| Clase | Estándar | Ejemplo |
|---|---|---|
| **OCF** | Open Cluster Framework — el más rico (parámetros, scoring de salud). | `ocf:heartbeat:IPaddr2`, `ocf:heartbeat:Filesystem`, `ocf:pacemaker:ping` |
| **systemd** | Envuelve una unidad `.service`. | `systemd:nginx` |
| **LSB** | Scripts heredados de `/etc/init.d`. | `lsb:myapp` |
| **service** | Autodetecta systemd/LSB. | `service:httpd` |
| **STONITH** | Agentes de fencing. | `stonith:fence_ipmilan` |

### 8.2 Primitivas de composición de recursos

| Construcción | Significado |
|---|---|
| **Primitive** | Una única instancia de recurso (una VIP, un FS). |
| **Group** | Conjunto ordenado y colocado — inicia de izquierda→derecha, detiene de derecha→izquierda, todos caen en el mismo nodo. El clásico stack «VIP → filesystem → servicio». |
| **Clone** | El mismo recurso corriendo en *muchos* nodos a la vez (activo/activo), p. ej. un FS en clúster o un monitor `ping`. |
| **Promotable clone** (antes master/slave) | Un clone con **roles** — Promoted/Unpromoted (Primario/Secundario). Respalda DRBD, Galera, replicación de PostgreSQL. |

### 8.3 Constraints — cómo se ubican los recursos

| Constraint | Controla | Ejemplo |
|---|---|---|
| **Location** | *Dónde* puede/no puede correr un recurso (preferencia de nodo / scoring, `INFINITY`). | «preferir node1», «nunca node3». |
| **Colocation** | Recursos que deben (o no deben) compartir un nodo. | VIP colocada con el primario de la BD. |
| **Order** | Secuenciación de inicio/detención. | Montar el FS *antes* de iniciar la BD. |

Los scores de `-INFINITY` a `+INFINITY` resuelven conflictos; `INFINITY` significa obligatorio, los scores finitos son preferencias que el policy engine suma.

---

## 9. Balanceo de carga (el clúster de «disponibilidad + escala»)

### 9.1 L4 vs L7

| Capa | Opera sobre | Ve | Pros | Contras | Herramientas |
|---|---|---|---|---|---|
| **L4 (transporte)** | IP:puerto, TCP/UDP | tupla de conexión | muy rápido, agnóstico al protocolo, alto throughput | sin conciencia de la app, sin ruteo por contenido | LVS/IPVS, `keepalived` |
| **L7 (aplicación)** | HTTP, headers, URL, TLS | petición completa | ruteo por contenido, terminación TLS, reintentos, salud de la app | más CPU, específico del protocolo | HAProxy, nginx, Envoy |

### 9.2 Algoritmos de scheduling

| Algoritmo | Regla | Mejor para |
|---|---|---|
| **Round Robin (rr)** | Siguiente backend en la rotación. | homogéneo, stateless |
| **Weighted RR (wrr)** | RR sesgado por peso de capacidad. | hardware heterogéneo |
| **Least Connections (lc)** | Menos conexiones activas. | sesiones largas / desparejas |
| **Weighted LC (wlc)** | LC sesgado por peso. | capacidad mixta + sesiones largas |
| **Source Hash (sh)** | Hash de la IP del cliente → backend fijo. | afinidad de sesión sin cookies |
| **Destination Hash (dh)** | Hash sobre el destino. | capas de cache/proxy |

### 9.3 Modos de forwarding de LVS

| Modo | Cómo | Ruta de retorno | Escala | Restricción |
|---|---|---|---|---|
| **NAT** | El director reescribe la IP de destino. | de vuelta *a través del* director | limitada (el director es el cuello de botella) | el más simple |
| **DR (Direct Routing)** | El director reescribe solo la MAC; VIP en todos los reales (lo). | reales → cliente **directamente** | la más alta | mismo segmento L2 |
| **TUN (IP tunneling)** | Encapsula hacia el servidor real. | reales → cliente directamente | alta, entre subredes | los reales deben soportar IPIP |

La **IP Virtual (VIP)** es la dirección de servicio compartida que flota hacia cualquier nodo/director que esté vivo — movida vía `IPaddr2` (Pacemaker, ARP gratuito) o **VRRP** (keepalived). Un par de LB redundante sobre VRRP es la solución para el SPOF de §2.4.

---

## 10. Almacenamiento: compartido vs replicado

| Propiedad | Almacenamiento compartido (SAN/iSCSI/NFS) | Almacenamiento replicado (DRBD) |
|---|---|---|
| Modelo | Un array externo, muchos nodos se conectan. | Dispositivo de bloque espejado de nodo→nodo por red. |
| SPOF | El array/servidor NFS (a menos que sea HA en sí mismo). | Ninguno inherente — sin caja compartida. |
| Costo | Array + fabric caros. | Discos locales commodity. |
| Escritura concurrente | Necesita FS de clúster (GFS2/OCFS2) + **DLM** para evitar corrupción. | Protocolo C = síncrono; primario/secundario o dual-primary (con FS de clúster). |
| Distancia | Limitada por el fabric. | LAN síncrono; WAN asíncrono (DRBD Proxy). |
| Acoplamiento con fencing | fence_scsi / mpath se integran. | debe hacer fencing para evitar réplicas divergentes. |

**Nota sobre el filesystem de clúster:** ext4/xfs son de *montaje único* — montarlos en dos nodos a la vez los corrompe. El acceso compartido activo/activo requiere **GFS2 u OCFS2** más el **DLM (Distributed Lock Manager)**, que a su vez es un recurso Pacemaker clonado. Esta es la mitad de almacenamiento del objetivo 362.

---

## 11. El stack de referencia de HA (Linux)

```
┌─────────────────────────────────────────────────────────┐
│  Resources:  IPaddr2 · Filesystem · systemd:pgsql · ...  │  ← Resource Agents (OCF/systemd/LSB/STONITH)
├─────────────────────────────────────────────────────────┤
│  Pacemaker  (CRM)                                         │  ← Cluster Resource Manager: policy engine (pengine),
│    pacemaker-controld / -schedulerd / -based (CIB)       │     placement, monitoring, recovery, fencing (fenced)
├─────────────────────────────────────────────────────────┤
│  Corosync   (messaging + membership + votequorum)        │  ← totem/knet ring, closed process group, quorum
├─────────────────────────────────────────────────────────┤
│  Kernel · NICs (redundant rings) · SBD/watchdog · BMC    │
└─────────────────────────────────────────────────────────┘
```

- **Corosync** = la capa de *mensajería y membresía*: heartbeats sobre el token ring (transporte knet, UDP 5405), decide quién está en el clúster, corre **votequorum**.
- **Pacemaker** = el *cerebro*: mantiene el estado del clúster en la **CIB** (Cluster Information Base, XML replicado), computa la ubicación deseada, maneja los resource agents, orquesta el fencing.
- **pcs / crmsh** = las CLIs de administración por encima.

---

## 12. Configuraciones completas y sintácticamente válidas

### 12.1 `/etc/corosync/corosync.conf` — clúster de 3 nodos, rings knet redundantes, votequorum

```conf
totem {
    version:            2
    cluster_name:       ha-prod
    transport:          knet
    crypto_cipher:      aes256
    crypto_hash:        sha256
    token:              3000
    token_retransmits_before_loss_const: 10
    join:               50
    consensus:          3600
}

nodelist {
    node {
        ring0_addr:     10.10.0.11
        ring1_addr:     10.20.0.11
        name:           node1
        nodeid:         1
    }
    node {
        ring0_addr:     10.10.0.12
        ring1_addr:     10.20.0.12
        name:           node2
        nodeid:         2
    }
    node {
        ring0_addr:     10.10.0.13
        ring1_addr:     10.20.0.13
        name:           node3
        nodeid:         3
    }
}

quorum {
    provider:               corosync_votequorum
    expected_votes:         3
    wait_for_all:           1
    last_man_standing:      1
    last_man_standing_window: 10000
}

logging {
    to_logfile:     yes
    logfile:        /var/log/cluster/corosync.log
    to_syslog:      yes
    timestamp:      on
}
```

> Dos rings (`ring0_addr` en 10.10.0.0/24, `ring1_addr` en 10.20.0.0/24) hacen que un único fallo de switch/NIC degrade pero no particione el clúster — la respuesta práctica a §7.

### 12.2 Clúster de dos nodos con un **quorum device** externo

Bloque quorum de `corosync.conf`:

```conf
quorum {
    provider:       corosync_votequorum
    two_node:       0            # disabled: the qdevice supplies the tie-breaker instead
    device {
        model:      net
        votes:      1
        net {
            tls:            on
            host:           qnetd-arbiter.example.net
            algorithm:      ffsplit      # fifty-fifty split resolver
        }
    }
}
```

El árbitro (un tercer host pequeño, *no* un nodo de clúster) corre `corosync-qnetd`; ambos nodos del clúster corren `corosync-qdevice`. Ahora una partición 1–1 se rompe por el voto del árbitro → exactamente un lado tiene quórum.

### 12.3 STONITH — fencing de energía IPMI por nodo, con un nivel de respaldo SBD

```bash
# Primary fencing: IPMI/BMC power fencing, one device per victim node
pcs stonith create fence-node1 fence_ipmilan \
    pcmk_host_list="node1" ip="10.30.0.11" lanplus=1 \
    username="fenceadmin" password="REDACTED" \
    pcmk_delay_base="5s" \
    op monitor interval=60s

pcs stonith create fence-node2 fence_ipmilan \
    pcmk_host_list="node2" ip="10.30.0.12" lanplus=1 \
    username="fenceadmin" password="REDACTED" \
    pcmk_delay_base="0s" \
    op monitor interval=60s

# Keep each fence device off the node it kills
pcs constraint location fence-node1 avoids node1=INFINITY
pcs constraint location fence-node2 avoids node2=INFINITY

# Fallback: SBD as fencing level 2 (used if IPMI is unreachable)
pcs stonith create fence-sbd fence_sbd devices="/dev/disk/by-id/wwn-0xSHARED" \
    op monitor interval=120s
pcs stonith level add 1 node1 fence-node1
pcs stonith level add 2 node1 fence-sbd
pcs stonith level add 1 node2 fence-node2
pcs stonith level add 2 node2 fence-sbd

pcs property set stonith-enabled=true
```

> El `pcmk_delay_base` asimétrico (5 s vs 0 s) rompe determinísticamente la carrera de fencing de §6.3: el dispositivo de node2 dispara primero, así que en una partición simétrica de 2 nodos node1 pierde.

### 12.4 Configuración del daemon SBD `/etc/sysconfig/sbd`

```bash
SBD_DEVICE="/dev/disk/by-id/wwn-0xSHARED"
SBD_WATCHDOG_DEV="/dev/watchdog"
SBD_WATCHDOG_TIMEOUT="5"
SBD_STARTMODE="always"
SBD_PACEMAKER="yes"
SBD_DELAY_START="no"
```

```bash
# Format the shared block device with SBD slots (msgwait ≈ 2× watchdog):
$ sbd -d /dev/disk/by-id/wwn-0xSHARED -4 20 -1 10 create
Initializing device /dev/disk/by-id/wwn-0xSHARED
Creating version 2.1 header on device 3 (uuid: 8f3c...)
Initializing 255 slots on device 3
Device /dev/disk/by-id/wwn-0xSHARED is initialized.
```

### 12.5 Un clásico **group** de recursos activo/pasivo (VIP → filesystem → servicio)

```bash
pcs resource create webvip ocf:heartbeat:IPaddr2 \
    ip=10.10.0.100 cidr_netmask=24 nic=eth0 \
    op monitor interval=10s timeout=20s

pcs resource create webfs ocf:heartbeat:Filesystem \
    device="/dev/drbd0" directory="/srv/www" fstype="xfs" \
    op monitor interval=20s timeout=40s

pcs resource create webserver systemd:nginx \
    op monitor interval=15s timeout=30s

# Group = ordered + colocated. Start VIP→FS→nginx; stop reverse; all on one node.
pcs resource group add webstack webvip webfs webserver

# Prefer node1, but fail over automatically
pcs constraint location webstack prefers node1=100

# Don't ping-pong: require 2 failures in 5 min before migrating away
pcs resource meta webserver migration-threshold=2 failure-timeout=300s
```

### 12.6 Dispositivo de bloque replicado DRBD `/etc/drbd.d/r0.res` + promotable clone

```conf
resource r0 {
    protocol C;                 # synchronous: ack only after remote disk write
    device      /dev/drbd0;
    disk        /dev/vg0/lv_data;
    meta-disk   internal;

    net {
        cram-hmac-alg   sha256;
        shared-secret   "REDACTED";
        after-sb-0pri   discard-zero-changes;
        after-sb-1pri   discard-secondary;
        after-sb-2pri   disconnect;      # never auto-resolve a real split-brain
    }
    on node1 { address 10.20.0.11:7788; node-id 0; }
    on node2 { address 10.20.0.12:7788; node-id 1; }
}
```

```bash
# Pacemaker promotable clone: exactly one Primary, follows resources
pcs resource create drbd-r0 ocf:linbit:drbd drbd_resource=r0 \
    op monitor interval=29s role=Promoted \
    op monitor interval=31s role=Unpromoted
pcs resource promotable drbd-r0 promoted-max=1 promoted-node-max=1 \
    clone-max=2 clone-node-max=1 notify=true
pcs constraint order promote drbd-r0-clone then start webfs
pcs constraint colocation add webfs with Promoted drbd-r0-clone INFINITY
```

### 12.7 VIP de load-balancer redundante con `keepalived` (VRRP) — soluciona §2.4

```conf
# /etc/keepalived/keepalived.conf  — MASTER (backup node uses state BACKUP, lower priority)
vrrp_script chk_haproxy {
    script "/usr/bin/killall -0 haproxy"
    interval 2
    weight   -20            # drop priority if HAProxy dies → failover
}

vrrp_instance VI_1 {
    state           MASTER
    interface       eth0
    virtual_router_id 51
    priority        150
    advert_int      1
    authentication { auth_type PASS; auth_pass REDACTED }
    virtual_ipaddress { 10.10.0.200/24 dev eth0 }
    track_script    { chk_haproxy }
}
```

### 12.8 Balanceador L7 `/etc/haproxy/haproxy.cfg`

```conf
global
    maxconn 20000
    log /dev/log local0

defaults
    mode    http
    timeout connect 5s
    timeout client  30s
    timeout server  30s
    option  httpchk GET /healthz

frontend web_in
    bind 10.10.0.200:80
    default_backend app_pool

backend app_pool
    balance leastconn
    option  redispatch
    server app1 10.10.0.11:8080 check inter 2s fall 3 rise 2
    server app2 10.10.0.12:8080 check inter 2s fall 3 rise 2
    server app3 10.10.0.13:8080 check inter 2s fall 3 rise 2
```

---

## 13. Playbook de verificación y diagnóstico de fallos

### 13.1 ¿Está sano el clúster? (`pcs status`)

```console
$ pcs status
Cluster name: ha-prod
Cluster Summary:
  * Stack: corosync (Pacemaker is running)
  * Current DC: node1 (version 2.1.7) - partition WITH quorum
  * Last updated: Wed Aug 12 14:03:11 2026
  * 3 nodes configured
  * 6 resource instances configured

Node List:
  * Online: [ node1 node2 node3 ]

Full List of Resources:
  * fence-node1  (stonith:fence_ipmilan):  Started node2
  * fence-node2  (stonith:fence_ipmilan):  Started node1
  * Resource Group: webstack:
    * webvip     (ocf:heartbeat:IPaddr2):  Started node1
    * webfs      (ocf:heartbeat:Filesystem): Started node1
    * webserver  (systemd:nginx):          Started node1

Daemon Status:
  corosync: active/enabled
  pacemaker: active/enabled
  pcsd: active/enabled
```

Leelo de arriba hacia abajo: **`partition WITH quorum`** (con quórum), todos los nodos **Online**, y cada recurso **Started** — incluyendo los dispositivos STONITH, que nunca deben estar en el nodo que fencean.

### 13.2 Estado del quórum (`corosync-quorumtool`)

```console
$ corosync-quorumtool -s
Quorum information
------------------
Date:             Wed Aug 12 14:04:02 2026
Quorum provider:  corosync_votequorum
Nodes:            3
Node ID:          1
Ring ID:          1.1a3
Quorate:          Yes

Votequorum information
----------------------
Expected votes:   3
Highest expected: 3
Total votes:      3
Quorum:           2
Flags:            Quorate WaitForAll LastManStanding

Membership information
----------------------
    Nodeid      Votes  Name
         1          1  node1 (local)
         2          1  node2
         3          1  node3
```

`Quorum: 2`, `Total votes: 3`, `Quorate: Yes`. Si una partición bajara `Total votes` por debajo de `Quorum`, esto cambia a `Quorate: No` y Pacemaker detiene los recursos en ese lado (por defecto `no-quorum-policy=stop`).

### 13.3 Salud del ring / interconnect (`corosync-cfgtool`)

```console
$ corosync-cfgtool -s
Local node ID 1, transport knet
LINK ID 0 udp
        addr    = 10.10.0.11
        status  = 1 1 1        # all 3 peers connected on ring0
LINK ID 1 udp
        addr    = 10.20.0.11
        status  = 1 1 1        # all 3 peers connected on ring1
```

Un `0` en el vector de estado = ese par inalcanzable en ese ring. Si ring0 muestra `0` pero ring1 muestra `1`, el ring redundante te salvó de una partición falsa — investigá el switch de ring0, no hagas un failover por pánico.

### 13.4 Validá la config *antes* de que te muerda (`crm_verify`)

```console
$ crm_verify -LV
   error: unpack_resources:  Resource start-up disabled since no STONITH resources have been defined
   error: unpack_resources:  Either configure some or disable STONITH with the stonith-enabled option
   error: unpack_resources:  NOTE: Clusters with shared data need STONITH to ensure data integrity
Errors found during check: config not valid
```

Este es el error de producción más común de todos — **`stonith-enabled=false` en un clúster con datos compartidos**. `crm_verify` lo atrapa antes de que el failover lo demuestre por las malas.

### 13.5 Verificación del fencing (`stonith_admin`)

```console
$ stonith_admin --list-registered
 fence-node1
 fence-node2
2 devices found

$ stonith_admin --history=node2
node2 was reset by node1 (fence-node2) at Wed Aug 12 13:41:57 2026: OK

# Dry-run a fence device without actually killing a node:
$ pcs stonith fence node2 --off        # DANGEROUS: really powers node2 off
Node: node2 fenced
```

### 13.6 Diagnóstico de los cuatro modos de fallo canónicos

| Síntoma | Causa probable | Confirmar con | Solución |
|---|---|---|---|
| Recursos **detenidos en todos lados**, `partition WITHOUT quorum` | quórum perdido (demasiados nodos/rings caídos) | `corosync-quorumtool -s` → `Quorate: No` | restaurar nodos/interconnect; qdevice; revisar `expected_votes` |
| Nodo `UNCLEAN (offline)`, los recursos no se mueven | fencing fallido/pendiente — el clúster se niega a recuperar un nodo sin fencear | `pcs status` muestra `UNCLEAN`; `crm_mon -1` | arreglar credenciales/alcance del BMC (`fence_ipmilan -o status`); agregar nivel de respaldo SBD |
| Ambos nodos se reinician mutuamente sin parar | **bucle / carrera de fencing** | `stonith_admin --history=*` ping-pong | agregar asimetría de `pcmk_delay_base`; condicionar el fencing al quórum; agregar qdevice |
| DRBD ambos `Primary/StandAlone`, datos divergidos | **split-brain de DRBD** | `drbdadm status` → `StandAlone`, `split-brain detected` | elegir un superviviente, descartar la víctima (`drbdadm secondary`/`connect --discard-my-data`); arreglar el fencing para que no se repita |

```console
$ drbdadm status r0
r0 role:Primary
  disk:UpToDate
  node2 connection:StandAlone       # <-- split-brain: peers refuse to talk
  peer-disk:DUnknown
```

```console
# Live event stream while you fail a node in a maintenance window:
$ crm_mon -rfANL
Node node1: online
Node node2: OFFLINE (standby)         # you put it in standby
  webvip    (ocf:heartbeat:IPaddr2):  Started node1
Migration Summary:
  * Node node1:
      webserver: migration-threshold=2 fail-count=0
```

### 13.7 Simulá antes de romper prod (`crm_simulate`)

```console
$ crm_simulate -L -S            # "what would the policy engine do right now?"
Current cluster status:
  Online: [ node1 node2 node3 ]
Transition Summary:
  * No actions need to be taken            # cluster is at its desired state
```

`crm_simulate` corre el scheduler contra la CIB viva *sin actuar* — la forma más segura de predecir el comportamiento de un failover antes de dispararlo, y la respuesta del SRE a «¿qué pasa si node1 muere ahora mismo?».

---

## 14. Referencias

- LPI — Objetivos del Examen 306 (306-300, v3.0): https://www.lpi.org/our-certifications/exam-306-objectives/
- LPI — Resumen de la certificación LPIC-3 High Availability and Storage Clusters: https://www.lpi.org/our-certifications/lpic-3-306/
- ClusterLabs — Documentación de Pacemaker (Clusters from Scratch, Pacemaker Explained): https://clusterlabs.org/pacemaker/doc/
- ClusterLabs — *Pacemaker Explained* (fencing, quórum, constraints): https://clusterlabs.org/pacemaker/doc/2.1/Pacemaker_Explained/html/
- Corosync — `votequorum(5)` y documentación del proyecto: https://corosync.github.io/corosync/
- ClusterLabs — quorum device / `corosync-qdevice(8)`, `corosync-qnetd(8)`: https://github.com/corosync/corosync-qdevice
- ClusterLabs — fencing SBD (Storage-Based Death): https://github.com/ClusterLabs/sbd
- LINBIT — Guía del usuario de DRBD 9: https://linbit.com/drbd-user-guide/drbd-guide-9_0-en/
- The Linux Virtual Server Project (LVS/IPVS): http://www.linuxvirtualserver.org/
- Keepalived — documentación oficial (VRRP, healthchecks): https://www.keepalived.org/documentation.html
- HAProxy — Manual de configuración: https://docs.haproxy.org/
- Red Hat — Configuring and Managing High Availability Clusters (RHEL 9): https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/configuring_and_managing_high_availability_clusters/index
- SUSE — Linux Enterprise High Availability Extension Administration Guide: https://documentation.suse.com/sle-ha/
- Google SRE Book — *Service Level Objectives* y *Embracing Risk* (error budgets, matemática de disponibilidad): https://sre.google/sre-book/service-level-objectives/