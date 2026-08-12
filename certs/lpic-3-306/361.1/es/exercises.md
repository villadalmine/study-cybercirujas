# Ejercicios guiados — Tema 361.1: Conceptos y teoría de Alta Disponibilidad

**LPIC-3 306 (examen 306-300, v3.0) · Peso del objetivo: 10**

Estos ejercicios se pueden ejecutar en cualquier estación de trabajo Linux: los cálculos usan `python3`/`bc`, y los pasos de inspección del cluster muestran la salida exacta esperada para que puedas seguirlos incluso sin un laboratorio Corosync/Pacemaker en vivo. Trabajá cada bloque en orden, ejecutá cada comando y respondé las preguntas de checkpoint antes de revelar las respuestas consolidadas al final.

> Convención: a lo largo de todo el documento, **A** = disponibilidad, **MTTF** = tiempo medio hasta el fallo (mean time to failure), **MTTR** = tiempo medio de reparación/recuperación (mean time to repair/recover), **MTBF** = MTTF + MTTR. Un "nueve" es un factor de 10 en la indisponibilidad.

---

## Exercise 1 — Aritmética de disponibilidad, MTTF/MTTR y los "nueves"

La habilidad más evaluable de 361.1 es convertir métricas de campo en una cifra de disponibilidad y un presupuesto de downtime, y viceversa.

1. Calculá la disponibilidad en estado estacionario de un servidor que falla en promedio cada 90 días y tarda 4 horas en recuperarse. MTTF = 90 × 24 = 2160 h, MTTR = 4 h:

   ```bash
   python3 -c "mttf=2160; mttr=4; A=mttf/(mttf+mttr); print('A=%.6f'%A, 'downtime=%.2f h/yr'%((1-A)*8760))"
   ```

2. Ahora construí la tabla de referencia de "nueves": disponibilidad y el presupuesto anual de downtime que compra cada nivel:

   ```bash
   python3 -c "
   for n in [2,3,4,5,6]:
       A=1-10**(-n)
       mins=(1-A)*365*24*60
       print(f'{n} nines  A={A:.6f}  budget={mins:9.2f} min/yr')
   "
   ```

3. Invertí la relación. Tu objetivo de SLA es cuatro nueves. La detección + failover en tu cluster tarda 90 segundos por evento. ¿Cuántos eventos de failover por año podés permitirte antes de reventar el presupuesto?

   ```bash
   python3 -c "budget=52.56*60; per=90; print('events/yr =', budget/per)"
   ```

4. Reducí el MTTR en lugar del MTTF. Tomá el servidor del paso 1 y recortá la recuperación de 4 h a 6 min (un failover a hot-standby en lugar de una reparación manual), manteniendo el MTTF en 2160 h:

   ```bash
   python3 -c "mttf=2160; mttr=0.1; A=mttf/(mttf+mttr); print('A=%.6f'%A, 'downtime=%.2f min/yr'%((1-A)*8760*60))"
   ```

**Checkpoint 1**
1. ¿Qué disponibilidad (y cuántos nueves) alcanzó el servidor único del paso 1?
2. Cuatro nueves son ~52.56 min/año. ¿Por qué ese número, y no "99.99%", es el que un ingeniero de guardia (on-call) realmente gestiona?
3. En el paso 4 tocaste solo el MTTR, nunca el MTTF (el hardware falla con la misma frecuencia). ¿Por qué mejora igualmente la disponibilidad de forma tan drástica, y qué te dice esto sobre dónde rinde el esfuerzo de ingeniería de HA?
4. La lectura ingenua de "cinco nueves" es "el sistema casi nunca se rompe". Corregila.

---

## Exercise 2 — Serie vs. paralelo: matemática de redundancia y la trampa de la independencia

La disponibilidad se compone de forma distinta según los componentes estén en el **camino de la solicitud** (serie — todos deben funcionar) o sean **redundantes** (paralelo — basta con uno).

1. Modelá un camino de solicitud: load balancer → app server → database, cada uno con su propia disponibilidad. En serie, las disponibilidades se multiplican:

   ```bash
   python3 -c "
   comps={'load_balancer':0.9999,'app_server':0.999,'database':0.9995}
   A=1
   for k,v in comps.items(): A*=v
   print('series A=%.6f'%A, 'downtime=%.2f h/yr'%((1-A)*8760))
   "
   ```

2. Compará el total con su eslabón individual más débil (`app_server`, 0.999 = 8.76 h/año). Fijate cuál es peor.

3. Ahora agregá redundancia. Poné nodos idénticos al 99% en **paralelo**: el sistema está caído solo si fallan *todos*: A = 1 − (1 − a)ⁿ:

   ```bash
   python3 -c "
   a=0.99
   for n in [1,2,3]:
       A=1-(1-a)**n
       print(f'{n} node(s)  A=%.6f'%A, 'downtime=%.2f min/yr'%((1-A)*525600))
   "
   ```

4. Activá la trampa. Esos dos nodos "redundantes" al 99% comparten una única alimentación eléctrica (power feed) con A = 0.9995. La alimentación compartida es un término en **serie** apilado encima del par en paralelo:

   ```bash
   python3 -c "
   pair=1-(1-0.99)**2      # 0.9999
   feed=0.9995
   A=pair*feed
   print('pair alone A=%.6f'%pair)
   print('pair+shared feed A=%.6f'%A, 'downtime=%.2f h/yr'%((1-A)*8760))
   "
   ```

**Checkpoint 2**
1. En el paso 1, ¿el total en serie es mejor o peor que el peor componente individual? Enunciá en una sola oración la regla general para sistemas en serie.
2. Agregar el segundo nodo en paralelo en el paso 3 convirtió el 99% en ¿qué? ¿Aproximadamente cuántos nueves compra cada nodo adicional independiente en paralelo mientras la base es 99%?
3. En el paso 4 el par tenía cuatro nueves por sí solo. ¿Qué le hizo la alimentación compartida a esa cifra, y qué término domina el downtime residual?
4. Definí **Single Point of Failure (SPOF)** en términos del modelo serie/paralelo, y explicá por qué "tenemos dos de todo" no es por sí solo una afirmación libre de SPOF.

---

## Exercise 3 — Quórum, split brain y el problema de los dos nodos

El quórum es el mecanismo que decide *cuál* partición de un cluster fracturado tiene permiso para actuar. Si te equivocás en esto, obtenés **split brain**: dos particiones que ambas creen ser dueñas del servicio.

1. Calculá el quórum por mayoría simple y la tolerancia a fallos para un rango de tamaños de cluster (quórum = ⌊N/2⌋ + 1):

   ```bash
   python3 -c "
   for n in range(2,8):
       q=n//2+1
       print(f'nodes={n}  quorum={q}  tolerates={n-q} node failure(s)')
   "
   ```

2. Compará N=3 con N=4 en esa salida. Fijate cuántos fallos tolera cada uno.

3. Simulá una partición de red y observá cómo se comportan tres configuraciones de cluster. Guardá y ejecutá esto:

   ```bash
   python3 <<'PY'
   total=2  # a 2-node cluster splits: each side keeps 1 vote
   here=1
   def majority(): return here > total/2

   print("A) plain majority quorum")
   print("   side keeps quorum?", majority(), "-> both sides False: cluster HALTS (safe, but unavailable)")

   print("B) two_node:1 forced quorum, NO fencing")
   print("   both sides act as quorate -> both run resources -> SPLIT BRAIN / data corruption")

   print("C) two_node:1 + fencing (STONITH)")
   print("   fence race: one node shoots the other -> single survivor runs (safe AND available)")
   PY
   ```

4. Inspeccioná cómo se ve un quórum saludable de 3 nodos en un cluster Corosync real. En un cluster en vivo ejecutarías `corosync-quorumtool -s`; la salida esperada es:

   ```text
   Quorum information
   ------------------
   Quorate:          Yes

   Votequorum information
   ----------------------
   Expected votes:   3
   Total votes:      3
   Quorum:           2
   Flags:            Quorate

   Membership information
   ----------------------
       Nodeid      Votes Name
            1          1 node1 (local)
            2          1 node2
            3          1 node3
   ```

5. Para un cluster de 2 nodos inevitable, leé cómo se repara el conteo de votos sin agregar un nodo completo: un **quorum device** (`corosync-qdevice` comunicándose con un árbitro externo `corosync-qnetd`) aporta un voto extra, convirtiendo 2 votos en 3 para que un nodo todavía pueda alcanzar la mayoría cuando el enlace con el par muere. (Referencia: `votequorum(5)`, `corosync-qdevice(8)`.)

**Checkpoint 3**
1. Del paso 1/2: ¿cuántos fallos tolera un cluster de 4 nodos comparado con uno de 3 nodos? Enunciá la regla práctica que esto implica sobre el dimensionamiento de clusters.
2. En la rama **A** de la simulación, no se corrompen datos pero el servicio está caído. En la rama **B**, el servicio sigue arriba pero los datos se corrompen. ¿Qué resultado prefiere un cluster correctamente configurado, y cómo se llama el fallo de la rama B?
3. La rama **C** depende del fencing para ser *segura*. ¿Por qué exactamente un cluster con `two_node: 1` hace que el fencing sea obligatorio en lugar de opcional?
4. Definí un **quorum device** y explicá cómo le permite a un cluster de 2 nodos sobrevivir al fallo de un solo nodo sin un empate 50/50.
5. ¿Por qué generalmente se prefieren tamaños de cluster impares por sobre los pares?

---

## Exercise 4 — Fencing / STONITH: razonar sobre estado conocido

**STONITH** (Shoot The Other Node In The Head) es un fencing que fuerza a un nodo sospechoso a un estado *conocido* — normalmente apagado — antes de que el cluster recupere sus recursos.

1. Enumerá las clases de fencing y qué garantiza cada una. Completá esta tabla de razonamiento en papel mientras leés:

   | Método de fencing | Agente de ejemplo | Qué aísla |
   |---|---|---|
   | Power fencing | IPMI / iLO / DRAC, PDU gestionada | Corta la energía de todo el nodo |
   | Storage/fabric fencing | SCSI-3 PR, SAN zoning | Bloquea las escrituras del nodo al almacenamiento compartido |
   | Watchdog (auto-fencing) | SBD + hardware watchdog | El nodo se reinicia *a sí mismo* si pierde el quórum |

2. En un cluster en vivo enumerarías los agentes instalados con `stonith_admin --list-installed` y revisarías la configuración con `pcs stonith config`. Razoná sobre este escenario sin un cluster:

   - El nodo **B** deja de responder a los heartbeats de Corosync. *No* está muerto: está congelado bajo carga y se descongelará en 40 segundos, reanudando las escrituras al LUN compartido que todavía tiene montado.
   - El nodo **A** tiene quórum y quiere recuperar los recursos de B.

3. Recorré las dos líneas de tiempo y decidí cuál es segura:
   - **Sin fencing:** A importa el filesystem compartido y comienza a escribir. 40 s después, B se descongela y continúa sus propias escrituras al mismo LUN.
   - **Con power fencing:** A emite un reset STONITH de B *y espera la confirmación* antes de importar el filesystem. B queda apagado; cuando se reinicia se reincorpora como un miembro nuevo sin nada montado.

**Checkpoint 4**
1. En la línea de tiempo "sin fencing", ¿qué sale mal exactamente en el momento de los 40 segundos?
2. Se describe al fencing como poner a un nodo en un estado *conocido*. ¿Por qué "conocido" es la palabra clave — por qué no alcanza con "esperar hasta que B parezca muerto"?
3. Un colega argumenta que un cluster **shared-nothing** (cada nodo tiene sus propios discos, datos replicados) necesita fencing con menos urgencia que uno **shared-storage**. ¿Hay un núcleo defendible en esa afirmación? ¿Dónde se cae?
4. ¿Cuál es la ventaja específica del auto-fencing por watchdog/SBD sobre el power fencing cuando los nodos del cluster son VMs sin un control de energía out-of-band confiable?

---

## Exercise 5 — Failover, failback, switchover y capacidad activo/activo

El vocabulario de recuperación es crítico para el examen, y los clusters activo/activo agregan una trampa de planificación de capacidad que activo/pasivo no tiene.

1. Fijá los tres términos con precisión clasificando cada evento como **failover**, **failback** o **switchover**:
   - (a) La PSU de un nodo muere a las 03:12; el cluster mueve automáticamente su VIP y su servicio al standby.
   - (b) A las 02:00, durante una ventana de mantenimiento, un admin ejecuta `pcs node standby node1` para reubicar recursos de modo que se pueda parchear node1.
   - (c) node1 se repara y se reincorpora; según una preferencia de ubicación reclama automáticamente los recursos que originalmente ejecutaba.

2. Modelá la capacidad activo/activo. Cuatro nodos funcionan cada uno al 60% de utilización. Uno falla; los sobrevivientes deben absorber la carga:

   ```bash
   python3 -c "
   nodes=4; util=0.60
   total=nodes*util
   surv=nodes-1
   print('total load units =', round(total,2))
   print('per surviving node after 1 failure = %.1f%%'%(total/surv*100))
   "
   ```

3. Subí la utilización al 80% y volvé a ejecutar para ver la cascada:

   ```bash
   python3 -c "
   nodes=4; util=0.80
   print('per surviving node = %.1f%%'%(nodes*util/(nodes-1)*100))
   "
   ```

4. Derivá el techo seguro en estado estacionario. Para un cluster activo/activo de N nodos que debe sobrevivir la pérdida de un nodo, la utilización máxima segura es (N−1)/N:

   ```bash
   python3 -c "[print(f'N={n}  max safe util = {(n-1)/n*100:.1f}%') for n in (2,3,4,8)]"
   ```

**Checkpoint 5**
1. Emparejá (a)/(b)/(c) del paso 1 con failover / failback / switchover, y dá la distinción de dos ejes (planificado vs. no planificado, automático vs. manual) que los separa.
2. El paso 2 estaba bien al 60%; el paso 3 se sobrecargó al 80%. ¿Cómo se llama este modo de fallo, y por qué puede convertir la pérdida de un nodo en una caída de todo el cluster?
3. Del paso 4, ¿cuál es el techo de utilización segura para un cluster activo/activo de 2 nodos, y qué conclusión práctica fuerza eso sobre correr dos nodos "en caliente"?
4. El **failback automático** (evento c) puede causar una *segunda* caída que el failover no causó. Explicá el riesgo de ping-pong y una forma de prevenirlo.
5. Enunciá una ventaja y una desventaja de activo/activo frente a activo/pasivo.

---

## Exercise 6 — Shared-storage vs. shared-nothing, RTO/RPO y resiliencia de sitio

El bloque final vincula la arquitectura de almacenamiento con los objetivos de recuperación que el negocio realmente aprueba.

1. Definí los dos objetivos, luego calculá un RPO a partir de una política de replicación. Los datos se replican **de forma asíncrona** cada 5 minutos al standby:

   ```bash
   python3 -c "interval_min=5; print('worst-case RPO ~= %d min of data loss'%interval_min)"
   ```

2. Contrastá con la replicación **síncrona** (p. ej. DRBD protocolo C, donde la escritura no se confirma hasta que el par la tiene):

   ```bash
   python3 -c "print('synchronous RPO ~= 0 (no acknowledged write is lost) at the cost of added write latency')"
   ```

3. Calculá el consumo de un presupuesto de downtime. Tu SLA es de cuatro nueves *por año* (≈52.56 min). Un único incidente de split-brain sin fencing este trimestre causó 30 minutos de downtime de recuperación:

   ```bash
   python3 -c "
   annual=52.56
   used=30
   print('annual four-nines budget = %.2f min'%annual)
   print('remaining after one 30-min incident = %.2f min'%(annual-used))
   "
   ```

4. Clasificá cada arquitectura frente a su riesgo dominante:

   | Arquitectura | Cómo se comparten los datos | Riesgo dominante a considerar en el diseño |
   |---|---|---|
   | Shared-storage | Los nodos montan un SAN/LUN común | Escrituras concurrentes → necesita fencing; el array en sí es un SPOF salvo que sea redundante |
   | Shared-nothing | Cada nodo es dueño de sus discos; datos replicados | Lag de replicación → RPO distinto de cero; el failover puede perder datos en tránsito |

5. Extendé a la **resiliencia de sitio**: todo el datacenter primario es un dominio de fallo. Un stretch cluster o sitio de DR agrega latencia entre sitios (aumentando el costo de la escritura síncrona) y necesita un árbitro/testigo de quórum en un *tercer sitio* para que un corte de enlace entre los dos sitios de datos no pueda producir una división 50/50.

**Checkpoint 6**
1. Definí RTO y RPO en una oración cada uno, y decí cuál de los dos controla principalmente el *método de replicación*.
2. Del paso 3: ¿qué le hace un único incidente de 30 minutos a un presupuesto *anual* de cuatro nueves, y qué revela eso sobre el verdadero costo de saltarse el fencing?
3. Dá el trade-off central entre replicación síncrona y asíncrona (nombrá el objetivo que cada una optimiza a expensas del otro).
4. ¿Por qué un stretch cluster de dos sitios necesita específicamente un *tercer* sitio para el quórum, y de qué concepto de un solo sitio del Ejercicio 3 es esta la versión geográfica?
5. Nombrá una forma en que la virtualización/cloud a la vez *ayuda* y *complica* la HA en relación con bare metal.

---

<details>
<summary><strong>Respuestas — Ejercicios 1–6</strong></summary>

### Exercise 1
1. A = 2160/2164 = **0.998151… ≈ 99.815%**, es decir, entre dos y tres nueves (~16.19 h de downtime/año). Aproximadamente 4 fallos/año × 4 h cada uno.
2. Porque los porcentajes de disponibilidad son abstractos, pero el **presupuesto de downtime en minutos es lo que gastás**: 52.56 min/año es el tiempo total que la guardia puede perder a lo largo de *todos* los incidentes antes de que se rompa el SLA. Es un recurso finito y consumible: gestionás el presupuesto, no el porcentaje.
3. A = MTTF/(MTTF + MTTR). Recortar el MTTR de 4 h a 6 min reduce el término de *indisponibilidad* mientras los fallos siguen siendo igual de frecuentes: la disponibilidad salta a **0.99995… (~4.4 min/año, cuatro–cinco nueves)**. Lección: en HA la recompensa está abrumadoramente en la **detección rápida y la recuperación automática (MTTR pequeño)**, no en hacer que el hardware falle con menos frecuencia. La velocidad del failover es la palanca.
4. Cinco nueves son **~5.26 min de downtime por año**: *no* significa fallos raros. Un sistema puede fallar seguido y aun así alcanzar los cinco nueves si cada recuperación se mide en pocos segundos; a la inversa, un sistema que "nunca" falla pero tarda horas en recuperarse la única vez que lo hace no los alcanzará.

### Exercise 2
1. **Peor.** El total en serie 0.998401 (~14 h/año) es peor que el eslabón más débil (0.999, 8.76 h/año). Regla: **la disponibilidad en serie es siempre ≤ el componente menos disponible**; las dependencias solo restan.
2. El 99% (dos nueves) se convirtió en **0.9999 (cuatro nueves)** con dos nodos, 0.999999 (seis nueves) con tres. Cada nodo en paralelo *independiente* adicional agrega aproximadamente **dos nueves** cuando la base es 99% (eleva al cuadrado la indisponibilidad).
3. **Colapsó los cuatro nueves de vuelta hacia tres**: 0.9999 × 0.9995 = 0.99940 (~5.26 h/año). La **alimentación compartida domina** el downtime residual: el par perfectamente redundante aporta casi nada al lado de ella.
4. Un **SPOF** es cualquier componente que aparece como un **término en serie sin alternativa en paralelo**: su fallo hace fallar todo el sistema. "Dos de todo" solo está libre de SPOF si los dos están en *dominios de fallo independientes*; una alimentación, switch, array de almacenamiento o rack compartido vuelve a convertir componentes nominalmente redundantes en un único término en serie.

### Exercise 3
1. **La misma — uno.** N=3 tolera 1 fallo (quórum 2); N=4 también tolera solo 1 (quórum 3) mientras cuesta más hardware *y* agrega un riesgo de división 50/50. Regla: **pasar de un tamaño impar al siguiente tamaño par no compra tolerancia extra** — crecé en pasos impares (3→5→7).
2. Un cluster correcto prefiere **A (seguro pero caído)** por sobre **B (arriba pero corrupto)**: la disponibilidad nunca vale una corrupción silenciosa de datos. La rama B es **split brain**.
3. `two_node: 1` *fuerza* a ambos nodos a considerarse con quórum (de lo contrario un cluster de 2 nodos nunca podría alcanzar la mayoría). Eso elimina al quórum como guardia contra el split-brain, así que **el fencing es el único mecanismo que queda** para garantizar que exactamente un nodo sobreviva a la partición; de ahí que sea obligatorio. Normalmente se combina con `wait_for_all`.
4. Un **quorum device** es un árbitro externo (`corosync-qnetd` en un tercer host, alcanzado a través de `corosync-qdevice`) que aporta un voto. Un cluster de 2 nodos pasa a **3 votos**; el nodo que todavía puede alcanzar al árbitro tiene la mayoría (2/3) y sobrevive, mientras que el nodo aislado pierde el quórum — rompiendo el empate sin un punto muerto 50/50 y sin un tercer nodo de cluster completo.
5. Los tamaños impares dan una **mayoría limpia sin empate**: un cluster par puede dividirse exactamente por la mitad (N/2 vs N/2), dejando a *ninguno* de los lados con quórum — el nodo par extra agrega costo y riesgo de empate sin agregar tolerancia a fallos.

### Exercise 4
1. A los 40 s **tanto A como B escriben al mismo LUN compartido de forma concurrente** sin coordinación → **corrupción** de filesystem/datos (split-brain clásico sobre almacenamiento compartido).
2. Porque un nodo colgado es indistinguible de uno muerto a través de la red: puede reanudar la I/O en cualquier instante. El fencing **fuerza** al nodo a un estado que podés *demostrar* (apagado / con escrituras bloqueadas) antes de recuperar recursos; "parece muerto" es una suposición, y recuperar sobre una suposición es exactamente como ocurre la corrupción.
3. Núcleo defendible: shared-nothing **no tiene un único LUN que dos nodos puedan corromper simultáneamente**, así que el modo de fallo de doble escritura del shared-storage está ausente. Se cae porque un failover falso en shared-nothing igual causa **split brain en la capa de aplicación/replicación** (dos masters, datasets divergentes, actualizaciones de clientes en conflicto): igual necesitás garantizar una única autoridad, así que el fencing/quórum siguen siendo necesarios.
4. Las VMs a menudo **no tienen un control de energía out-of-band confiable** (ningún IPMI/PDU real en el que el cluster pueda confiar). El **auto-fencing por watchdog/SBD** hace que el nodo se reinicie *a sí mismo* a través de un watchdog de hardware/hipervisor cuando pierde el quórum o el heartbeat de SBD — no necesita ninguna vía de energía externa ni cooperación del SO del nodo sospechoso.

### Exercise 5
1. (a) **Failover** — no planificado + automático. (b) **Switchover** — planificado + manual (también llamado failover manual/administrativo). (c) **Failback** — retorno al nodo original/preferido tras la recuperación. Dos ejes: **planificado vs. no planificado** y **automático vs. manual**.
2. **Cascada de sobrecarga** (thundering-herd / desborde de capacidad): los sobrevivientes superan el 100%, se degradan o se caen, descargando su carga sobre los nodos restantes, que entonces también fallan — la pérdida de un nodo se convierte en colapso total.
3. El techo para N=2 es **(2−1)/2 = 50%**. Dos nodos activo/activo "en caliente" deben correr cada uno a **≤50%** para sobrevivir la pérdida del otro — lo que significa que estás pagando por dos nodos para obtener el throughput seguro de un solo nodo. Por encima del 50%, un único fallo sobrecarga al sobreviviente.
4. El **failback automático** mueve los recursos *de vuelta* en el momento en que el nodo recuperado se reincorpora — una segunda interrupción de servicio evitable; si el nodo está oscilando (flapping), los recursos hacen **ping-pong** repetidamente, causando caídas recurrentes. Prevenilo deshabilitando el failback automático (en Pacemaker, mantené `resource-stickiness` alto / evitá una preferencia de ubicación estricta) para que los recursos se queden quietos hasta que un admin los mueva deliberadamente.
5. Ventaja de activo/activo: **todos los nodos hacen trabajo útil** (mejor utilización de recursos y escalado horizontal). Desventaja: **más complejidad** (necesita apps conscientes del cluster o un load balancer, un margen de capacidad cuidadoso, y un manejo correcto del estado compartido/locking); activo/pasivo es más simple pero desperdicia la capacidad del standby.

### Exercise 6
1. **RTO** = *tiempo máximo aceptable para restaurar el servicio* tras una caída (cuánto tiempo estás caído). **RPO** = *pérdida de datos máxima aceptable*, expresada como un punto en el tiempo previo al fallo (cuántos datos recientes podés perder). **El RPO está controlado principalmente por el método de replicación.**
2. **Consume 30 de los 52.56 min del presupuesto anual de cuatro nueves en un solo evento** (~57%), dejando ~22.56 min para el resto del año. Muestra que saltarse el fencing no es un riesgo de caso extremo — una *única* recuperación de split-brain puede reventar por sí sola más de la mitad del presupuesto anual del SLA.
3. La **síncrona** optimiza el **RPO** (≈0 pérdida de datos) a costa de la **latencia/throughput de escritura**; la **asíncrona** optimiza la **latencia/throughput** a costa del **RPO** (podés perder hasta un intervalo de replicación). Intercambiás durabilidad por rendimiento.
4. Un stretch cluster de dos sitios con votos iguales puede dividirse exactamente por la mitad si se corta el enlace entre sitios — **ningún sitio tiene quórum (o, si se fuerza, ambos lo tienen → split brain entre sitios)**. Un **árbitro/testigo de quórum en un tercer sitio** provee el voto de desempate para que exactamente un sitio de datos mantenga el quórum. Es la **versión geográfica del quorum device / principio del conteo de votos impar** del Ejercicio 3.
5. **Ayuda:** la virtualización/cloud hace que la redundancia sea barata y rápida — el reinicio de VMs, la migración en vivo, los grupos de auto-scaling y el fencing/aprovisionamiento vía API reducen el MTTR. **Complica:** los nodos virtuales pueden compartir dominios de fallo ocultos (el mismo host físico, hipervisor, zona de disponibilidad o backend de almacenamiento), reintroduciendo fallos correlacionados y SPOFs que parecen redundantes pero no lo son — y el power fencing out-of-band puede no estar disponible, empujándote al auto-fencing por watchdog/SBD.

</details>

---

### Fuentes

- LPI — Objetivos del examen 306 (Objetivo 361.1): https://www.lpi.org/our-certifications/exam-306-objectives/
- ClusterLabs — *Pacemaker Explained* (quórum, fencing/STONITH, ubicación de recursos): https://clusterlabs.org/pacemaker/doc/
- Corosync — `votequorum(5)`, `corosync.conf(5)`, `corosync-qdevice(8)`, `corosync-quorumtool(8)`: https://corosync.github.io/corosync/
- Red Hat — *Configuring and managing high availability clusters* (fencing, quorum devices, clusters de dos nodos): https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/configuring_and_managing_high_availability_clusters/index