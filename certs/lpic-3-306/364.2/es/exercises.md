# 364.2 RAID avanzado — Ejercicios guiados

> **Alcance.** Estos ejercicios van más allá de la creación de arrays (364.1) hacia las operaciones que mantienen el almacenamiento de un único nodo con alta disponibilidad: write-intent bitmaps, reshaping en línea, migración de nivel RAID, mirrors write-behind, el write hole de RAID5 y sus mitigaciones (PPL / write-journal), reemplazo de dispositivos en caliente, spare groups y monitoreo. Todo se maneja con `mdadm(8)` y el driver `md` del kernel.
>
> **Seguridad.** Cada paso opera sobre **dispositivos loopback respaldados por archivos de imagen**, nunca sobre discos reales. Puede ejecutar todo dentro de una VM o contenedor descartable con `root`. El reshape y el resync son destructivos para todo lo que tocan — no apunte estos comandos a un `/dev/sdX` que le importe.
>
> **Una nota sobre las salidas.** Los conteos de bloques, los data offsets, las velocidades de resync y los tamaños de chunk del bitmap varían según la versión de `mdadm`, el kernel y la geometría del dispositivo. Los listados de abajo son representativos; verifique la *forma* de la salida en su sistema, no los dígitos exactos.

---

## Lab environment setup

**1.** Cree un directorio de trabajo y seis archivos de respaldo de 512 MiB:

```bash
mkdir -p /root/raidlab && cd /root/raidlab
for i in 0 1 2 3 4 5; do truncate -s 512M disk$i.img; done
ls -lh disk*.img
```

**2.** Adjunte cada imagen a un dispositivo loop y confirme:

```bash
for i in 0 1 2 3 4 5; do losetup --find --show disk$i.img; done
```

```
/dev/loop0
/dev/loop1
/dev/loop2
/dev/loop3
/dev/loop4
/dev/loop5
```

```bash
losetup -a | sort
```

**3.** Confirme las personalities de `md` que el kernel puede cargar y que todavía no existe ningún array:

```bash
cat /proc/mdstat
```

```
Personalities : [raid6] [raid5] [raid4] [raid1] [raid10]
unused devices: <none>
```

> Si falta una personality que necesita, `modprobe raid456` / `raid1` / `raid10` la carga. `mdadm --create` normalmente lo dispara automáticamente.

**Verificación de comprensión**

- **Q1.** ¿Por qué los dispositivos loop son un sustituto legítimo de `/dev/sdX` al practicar con `mdadm`, y qué clase de comportamiento del mundo real *no* reproducen fielmente?
- **Q2.** La línea `Personalities` lista `[raid6] [raid5] [raid4]` juntas. ¿Qué le dice esa agrupación sobre cómo el kernel implementa esos tres niveles?

---

## Exercise 1 — Write-intent bitmaps

Un write-intent bitmap registra qué regiones del array *pueden* estar fuera de sincronía. Tras un apagado sucio o una caída transitoria de un dispositivo, `md` solo resincroniza las regiones sucias en lugar de todo el array — convirtiendo un resync completo de varias horas en segundos.

**1.** Cree un RAID5 de 3 dispositivos con un bitmap **interno**:

```bash
mdadm --create /dev/md0 --level=5 --raid-devices=3 \
      --bitmap=internal --assume-clean \
      /dev/loop0 /dev/loop1 /dev/loop2
```

> `--assume-clean` omite el resync de paridad inicial. Es legítimo aquí porque los dispositivos están vacíos; **nunca** lo use sobre dispositivos con datos reales que pretenda conservar, porque la paridad quedaría incorrecta.

**2.** Inspeccione el array y localice el bitmap:

```bash
cat /proc/mdstat
```

```
Personalities : [raid6] [raid5] [raid4]
md0 : active raid5 loop2[2] loop1[1] loop0[0]
      1044480 blocks super 1.2 level 5, 512k chunk, algorithm 2 [3/3] [UUU]
      bitmap: 0/1 pages [0KB], 65536KB chunk

unused devices: <none>
```

```bash
mdadm --detail /dev/md0 | grep -Ei 'bitmap|state|consistency'
```

**3.** Simule una falla transitoria y observe la recuperación acelerada por bitmap. Falle y quite una pata, luego vuelva a agregar el *mismo* dispositivo:

```bash
mdadm /dev/md0 --fail /dev/loop2 --remove /dev/loop2
mdadm /dev/md0 --re-add /dev/loop2
cat /proc/mdstat
```

```
md0 : active raid5 loop2[2] loop1[1] loop0[0]
      1044480 blocks super 1.2 level 5, 512k chunk, algorithm 2 [3/2] [UU_]
      [============>........]  recovery = 61.2% (...) finish=0.0min speed=...
      bitmap: 1/1 pages [4KB], 65536KB chunk
```

Como el bitmap estaba limpio (no hubo escrituras mientras la pata estuvo afuera), la recuperación se completa casi instantáneamente.

**4.** Convierta el bitmap de interno a **externo** (un archivo en otro filesystem — útil cuando las actualizaciones del bitmap competirían de otro modo con la I/O del array):

```bash
mdadm --grow /dev/md0 --bitmap=none
mdadm --grow /dev/md0 --bitmap=/root/raidlab/md0-bitmap
mdadm --detail /dev/md0 | grep -i bitmap
```

> El archivo de bitmap externo **no** debe residir en el array que protege. Colóquelo en almacenamiento independiente y confiable.

**Verificación de comprensión**

- **Q3.** ¿Cuál es el compromiso operativo de un write-intent bitmap, y cómo el **tamaño de chunk del bitmap** (p. ej. `65536KB chunk`) se sitúa en el centro de ese compromiso?
- **Q4.** Tras la falla transitoria del paso 3, ¿por qué `--re-add` fue casi instantáneo mientras que un `--add` de un dispositivo totalmente nuevo dispararía una reconstrucción completa?
- **Q5.** Dé un escenario concreto donde un bitmap **externo** sea preferible a uno interno — y una restricción estricta sobre dónde puede residir ese archivo externo.

---

## Exercise 2 — Growing an array (reshape by adding devices)

**1.** Ponga un filesystem sobre el array y móntelo para poder probar que los datos sobreviven al reshape:

```bash
mkfs.ext4 -q /dev/md0
mkdir -p /mnt/md0 && mount /dev/md0 /mnt/md0
echo "before reshape $(date -u +%s)" > /mnt/md0/marker.txt
df -h /mnt/md0
```

**2.** Agregue un cuarto dispositivo y haga crecer el array de 3 a 4 miembros. Un reshape reescribe cada stripe, así que provea un **backup file** en almacenamiento separado para proteger la región crítica durante la operación:

```bash
mdadm --add /dev/md0 /dev/loop3
mdadm --grow /dev/md0 --raid-devices=4 \
      --backup-file=/root/raidlab/reshape.bak
```

**3.** Observe el progreso del reshape:

```bash
cat /proc/mdstat
```

```
md0 : active raid5 loop3[3] loop2[2] loop1[1] loop0[0]
      1044480 blocks super 1.2 level 5, 512k chunk, algorithm 2 [4/4] [UUUU]
      [=====>...............]  reshape = 27.8% (145280/522240) finish=0.4min speed=...
      bitmap: 0/1 pages [0KB], 65536KB chunk
```

Puede limitar (throttle) el reshape para proteger la I/O de primer plano:

```bash
echo 20000 > /proc/sys/dev/raid/speed_limit_max   # KiB/s ceiling per device
```

**4.** Cuando el reshape termina, el *array* es más grande pero el *filesystem* no. Haga crecer el filesystem en línea:

```bash
mdadm --wait /dev/md0
mdadm --detail /dev/md0 | grep -i 'array size'
resize2fs /dev/md0
df -h /mnt/md0
cat /mnt/md0/marker.txt
```

**Verificación de comprensión**

- **Q6.** Un reshape debe retener temporalmente datos que se están reubicando entre el layout de stripe viejo y el nuevo. ¿Para qué sirve el `--backup-file`, cuándo es *crítico* (en qué fase del reshape) y dónde **no** debe colocarse?
- **Q7.** Agrandar el array no agrandó el `ext4` montado. ¿Por qué son dos pasos independientes, y cuál es la restricción de orden entre ellos (hacer crecer primero el array vs. el filesystem)?
- **Q8.** ¿Cuál es la diferencia entre `dev/raid/speed_limit_min` y `speed_limit_max`, y por qué podría *subir* el mínimo durante una reconstrucción en estado degradado pero *bajar* el máximo durante un reshape de rutina?

---

## Exercise 3 — RAID-level migration (RAID5 → RAID6)

El reshaping puede cambiar el nivel de redundancia, no solo la cantidad de dispositivos. Migrar de RAID5 a RAID6 agrega un segundo bloque de paridad por stripe, así que requiere un miembro adicional.

**1.** Agregue un quinto dispositivo y migre el nivel en un solo comando:

```bash
mdadm --add /dev/md0 /dev/loop4
mdadm --grow /dev/md0 --level=6 --raid-devices=5 \
      --backup-file=/root/raidlab/reshape.bak
cat /proc/mdstat
```

```
md0 : active raid6 loop4[4] loop3[3] loop2[2] loop1[1] loop0[0]
      1566720 blocks super 1.2 level 6, 512k chunk, algorithm 2 [5/5] [UUUUU]
      [==>..................]  reshape = 12.1% (...) finish=... speed=...
      bitmap: 0/1 pages [0KB], 65536KB chunk
```

**2.** Confirme el nuevo layout y que los datos están intactos:

```bash
mdadm --wait /dev/md0
mdadm --detail /dev/md0 | grep -Ei 'raid level|layout|raid devices'
md5sum /mnt/md0/marker.txt
```

**3.** Observe el layout de RAID6 / algoritmo de rotación de paridad que reporta `mdadm`:

```bash
mdadm --detail /dev/md0 | grep -i layout
```

> El `layout` por defecto de RAID6 es `left-symmetric` (`algorithm 2`). El layout determina cómo rotan los bloques de paridad P y Q a través de los dispositivos; es metadata que rara vez cambia, pero `mdadm --grow --layout=...` puede reshapearla.

**Verificación de comprensión**

- **Q9.** ¿Por qué migrar de RAID5 → RAID6 requiere agregar un dispositivo, mientras que RAID5 → RAID5-con-más-discos también agrega un dispositivo pero por una razón *diferente*? Distinga "más capacidad" de "más redundancia".
- **Q10.** RAID6 tolera dos fallas simultáneas de dispositivos donde RAID5 tolera una. Más allá de "pueden morir dos discos", nombre el modo de falla específico en *modo degradado* contra el que RAID6 protege y que lo convierte en la opción por defecto para arrays SATA grandes. (Pista: ¿qué le puede pasar a un segundo disco *durante* una reconstrucción de RAID5?)
- **Q11.** RAID1 → RAID5 también es una migración soportada (`mdadm --grow --level=5`). Esboce cómo un RAID1 de 2 dispositivos puede convertirse en un RAID5 sin una reescritura completa de datos de los dos primeros miembros.

---

## Exercise 4 — Write-mostly legs and write-behind (RAID1)

Para un mirror asimétrico — p. ej. un disco local rápido espejado hacia un dispositivo lento o de alta latencia (un network block device, un SSD espejado hacia un HDD) — puede marcar la pata lenta como `write-mostly` para que las lecturas la eviten, y habilitar `write-behind` para que las escrituras hacia ella se confirmen de forma asincrónica. `write-behind` **requiere** un bitmap.

**1.** Construya un RAID1 de 2 dispositivos con un bitmap interno, marcando el sustituto de `/dev/loop6` como la pata lenta. (Reutilice `loop5` como la pata lenta aquí.)

```bash
mdadm --create /dev/md1 --level=1 --raid-devices=2 \
      --bitmap=internal --assume-clean \
      /dev/loop0 --write-mostly /dev/loop5
```

> En el mundo real `loop0` ya está en `md0`; para este ejercicio aislado, primero detenga `md0` (`umount /mnt/md0 && mdadm --stop /dev/md0`) o sustituya por dos dispositivos loop libres. Lo importante son los flags, no los miembros específicos.

**2.** Habilite write-behind con una cola acotada de escrituras pendientes:

```bash
mdadm --grow /dev/md1 --write-behind=256
mdadm --detail /dev/md1 | grep -Ei 'state|write'
```

**3.** Verifique los flags en el miembro lento:

```bash
mdadm --examine /dev/loop5 | grep -Ei 'flags|state'
cat /proc/mdstat
```

```
md1 : active raid1 loop5[1](W) loop0[0]
      523264 blocks super 1.2 [2/2] [UU]
      bitmap: 0/1 pages [0KB], 65536KB chunk
```

El marcador `(W)` junto a `loop5[1]` denota un miembro `write-mostly`.

**Verificación de comprensión**

- **Q12.** Explique el comportamiento del camino de lectura y el camino de escritura de una pata de mirror `write-mostly`. ¿Qué gana el array, y qué salvedad de durabilidad introduce `write-behind`?
- **Q13.** ¿Por qué un write-intent bitmap es un prerrequisito estricto para `write-behind`? (Piense en qué debe rastrearse mientras una escritura a la pata lenta sigue pendiente.)
- **Q14.** ¿Qué acota el `256` en `--write-behind=256`, y cuál es el riesgo de fijarlo demasiado alto en una pata genuinamente lenta?

---

## Exercise 5 — The RAID5/6 write hole: PPL and write-journal

Una pérdida de energía durante la escritura de un stripe puede dejar los datos y la paridad inconsistentes (el "write hole"): el array luce limpio al reiniciar pero una falla posterior de un solo disco reconstruye datos corruptos. `md` ofrece dos mitigaciones.

- **PPL (Partial Parity Log)** — reside en la metadata, sin dispositivo extra, con un pequeño costo en throughput de escritura. Disponible por defecto para RAID5.
- **Write-journal** — un dispositivo de journal dedicado (idealmente con protección contra pérdida de energía) que cierra el agujero por completo, a mayor costo.

**1.** Reconstruya un RAID5 y fije su consistency policy en `ppl`:

```bash
mdadm --stop /dev/md1 2>/dev/null
mdadm --create /dev/md0 --level=5 --raid-devices=3 \
      --consistency-policy=ppl --assume-clean \
      /dev/loop0 /dev/loop1 /dev/loop2
mdadm --detail /dev/md0 | grep -i 'consistency policy'
```

```
   Consistency Policy : ppl
```

**2.** Cambie la policy en tiempo de ejecución (PPL ⇄ resync):

```bash
mdadm --grow /dev/md0 --consistency-policy=resync
mdadm --grow /dev/md0 --consistency-policy=ppl
```

**3.** (Referencia) Crear un array con journal usa un dispositivo dedicado — no puede agregar un journal a un array existente, solo en la creación:

```bash
# Illustrative — needs a spare device dedicated to the journal:
mdadm --create /dev/md2 --level=5 --raid-devices=3 \
      --write-journal /dev/loop5 \
      /dev/loop3 /dev/loop4 /dev/loop0
mdadm --detail /dev/md2 | grep -Ei 'journal|consistency'
```

**Verificación de comprensión**

- **Q15.** Con sus propias palabras, describa el write hole de RAID5: qué queda inconsistente tras un crash, por qué el array *no* lo nota al reiniciar, y cuándo la inconsistencia efectivamente golpea al usuario.
- **Q16.** Compare PPL y un write-journal en tres ejes: hardware extra, costo de rendimiento y completitud del cierre del write hole. ¿Cuándo elegiría cada uno?
- **Q17.** ¿Por qué un bitmap *no* resuelve el write hole, aunque también rastrea las escrituras en vuelo?

---

## Exercise 6 — Hot replacement (`--replace`) and spare groups

**1.** Reemplace proactivamente un miembro que está arrojando errores *sin* caer primero a un estado degradado. `--replace` construye el miembro nuevo mientras el viejo sigue participando, preservando la redundancia en todo momento:

```bash
mdadm /dev/md0 --add /dev/loop4              # provide the incoming device as a spare
mdadm /dev/md0 --replace /dev/loop2 --with /dev/loop4
cat /proc/mdstat
```

```
md0 : active raid5 loop4[3](R) loop2[2] loop1[1] loop0[0]
      1044480 blocks super 1.2 level 5, 512k chunk, algorithm 2 [3/3] [UUU]
      [=======>.............]  recovery = 38.0% (...) finish=... speed=...
```

El `(R)` marca el objetivo del reemplazo. Cuando termina, `loop2` se descarta automáticamente.

**2.** Defina **spare groups** para que `mdadm --monitor` pueda mover un spare de un array a otro que haya perdido redundancia. Escriba `/etc/mdadm/mdadm.conf` (la ruta es `/etc/mdadm.conf` en algunas distros):

```bash
mdadm --detail --scan >> /etc/mdadm/mdadm.conf
```

Luego edite cada línea `ARRAY` para agregar un `spare-group` compartido y fijar la dirección de alerta:

```
MAILADDR root@localhost
ARRAY /dev/md0 metadata=1.2 spare-group=lab UUID=...
ARRAY /dev/md2 metadata=1.2 spare-group=lab UUID=...
```

**3.** Verifique que la config se parsea y que los arrays se ensamblan a partir de ella:

```bash
mdadm --assemble --scan --config=/etc/mdadm/mdadm.conf --verbose 2>&1 | tail
```

**Verificación de comprensión**

- **Q18.** Contraste `--replace` con la secuencia clásica `--fail` → `--remove` → `--add`. ¿Durante qué ventana es vulnerable el array en cada enfoque, y por qué `--replace` es la jugada preferida en producción para una falla *predicha* (p. ej. un conteo creciente de sectores reasignados en SMART)?
- **Q19.** Para que un spare compartido migre entre dos arrays vía `spare-group`, deben cumplirse dos condiciones. Nombre ambas — una sobre el daemon, otra sobre el tamaño del spare.
- **Q20.** ¿Por qué es importante que `mdadm.conf` fije los arrays por **UUID** en lugar de por el nombre de dispositivo del kernel (`/dev/md0`)?

---

## Exercise 7 — Monitoring and alerting

`mdadm --monitor` sondea el estado del array y dispara eventos (`Fail`, `FailSpare`, `DegradedArray`, `SpareActive`, `RebuildFinished`, `MoveSpare`, …) hacia email, syslog y un programa opcional.

**1.** Ejecute una prueba one-shot que genera un `TestMessage` sintético para cada array (prueba la entrega de correo sin romper nada):

```bash
mdadm --monitor --scan --oneshot --test
```

**2.** Inicie el monitor como daemon (en producción esto es el `mdmonitor.service` empaquetado):

```bash
mdadm --monitor --scan --daemonise --syslog \
      --mail=root@localhost --delay=300
```

**3.** Dispare un evento real `Fail`/`DegradedArray` y léalo de vuelta desde syslog:

```bash
mdadm /dev/md0 --fail /dev/loop1
journalctl -t mdadm --since "5 min ago" | tail
mdadm /dev/md0 --remove /dev/loop1 --re-add /dev/loop1
```

**4.** (Referencia) Enrute los eventos hacia un handler personalizado con `--program` / `PROGRAM` en `mdadm.conf`; el script recibe el evento, el dispositivo md y el componente relacionado como `$1 $2 $3`.

**Verificación de comprensión**

- **Q21.** ¿Qué evento trata `mdadm --monitor` como *urgente* (enviado por correo de inmediato sin importar `--delay`), y por qué esa clase es especial?
- **Q22.** `mdmonitor.service` normalmente es consciente de socket/`ONLYDEGRADED` y lo inicia el empaquetado, no a mano. ¿Cuál es el riesgo de correr *dos* daemons `mdadm --monitor` contra los mismos arrays?
- **Q23.** Configuró `MAILADDR` pero no recibe correo ante una falla, y `--oneshot --test` tampoco produjo nada. Antes de culpar a `mdadm`, ¿cuál es el culpable más probable y cómo lo aislaría?

---

## Exercise 8 — Bad-block log and inspection

`md` mantiene un **bad block log** por dispositivo: los sectores que fallaron se registran para que el array deje de confiar en ellos, reconstruyendo esos datos desde la paridad/mirror en lugar de expulsar el disco entero ante un solo error de sector.

**1.** Inspeccione la metadata y cualquier bad block registrado:

```bash
mdadm --examine /dev/loop0 | grep -Ei 'bad block|feature|data offset'
mdadm --examine-badblocks /dev/loop0
```

**2.** Vea el feature bitmap que muestra si las características de bad-block-log y bitmap están habilitadas:

```bash
mdadm --examine /dev/loop0 | sed -n '/Feature Map/,/Array UUID/p'
```

**Verificación de comprensión**

- **Q24.** ¿Cómo mejora la disponibilidad el bad-block log comparado con el comportamiento antiguo de fallar un disco entero ante el primer sector ilegible — y cuál es el peligro si la lista de bad blocks crece mucho en un array *degradado*?

---

## Teardown

```bash
umount /mnt/md0 2>/dev/null
for m in /dev/md0 /dev/md1 /dev/md2; do mdadm --stop $m 2>/dev/null; done
mdadm --zero-superblock /dev/loop{0..5} 2>/dev/null
losetup -D
rm -f /root/raidlab/*.img /root/raidlab/*.bak /root/raidlab/md0-bitmap
```

> Poner en cero el superblock antes de desconectar evita que una firma `md` obsoleta ensamble automáticamente un array fantasma en el próximo arranque.

---

## Sources

- LPI — *Exam 306 Objectives* (306-300, v3.0), objetivo 364.2: <https://www.lpi.org/our-certifications/exam-306-objectives/>
- `mdadm(8)` — creación, `--grow`, `--replace`, `--monitor`, consistency policy, bitmaps: <https://man7.org/linux/man-pages/man8/mdadm.8.html>
- `md(4)` — driver software-RAID del kernel, write-intent bitmap, write-behind, bad-block log: <https://man7.org/linux/man-pages/man4/md.4.html>
- Linux Kernel — guía de administración *RAID (md)* (write hole, PPL, journal, reshape): <https://docs.kernel.org/admin-guide/md.html>
- Linux RAID Wiki (kernel.org) — reshaping, crecimiento, procedimientos de recuperación: <https://raid.wiki.kernel.org/>

---

<details>
<summary><strong>Respuestas</strong></summary>

**Q1.** Los dispositivos loop exponen la misma interfaz de dispositivo de bloques que consume `md`, así que cada comando `mdadm`, formato de superblock, reshape y resync se comporta de forma idéntica — ideal para aprender el plano de control de forma segura. Lo que *no* reproducen: la asimetría real de latencia/throughput de un disco, la semántica de fallas mecánicas/SMART, los errores de lectura a nivel de sector y los defectos de medio, las fallas de controladora/cableado, y el costo real de una reconstrucción. Están respaldados por un único archivo/filesystem subyacente, así que la "falla independiente de spindles independientes" es una ficción aquí.

**Q2.** RAID4, RAID5 y RAID6 comparten un mismo módulo del kernel (`raid456`) porque son el mismo motor de paridad con distinta ubicación de la paridad: RAID4 = disco de paridad dedicado, RAID5 = una única paridad rotativa, RAID6 = paridad rotativa dual (P y Q, la segunda calculada con matemática de Reed–Solomon/campos de Galois). La agrupación en `Personalities` refleja esa implementación compartida, que es también la razón por la que migrar entre ellos es un *reshape* y no una reconstrucción desde cero.

**Q3.** Compromiso: un bitmap agrega una escritura a la metadata del bitmap antes/alrededor de las escrituras del array, costando algo de throughput e IOPS, a cambio de convertir un resync de todo el array en un resync solo de las regiones sucias tras un evento sucio. El **chunk del bitmap** es la granularidad: un chunk *grande* (p. ej. 64 MiB) significa menos actualizaciones del bitmap (menos overhead) pero cada bit sucio cubre una región grande, así que la recuperación resincroniza más de lo estrictamente necesario; un chunk *chico* significa una recuperación más fina y rápida pero más overhead de actualización del bitmap. Se ajusta el tamaño del chunk para situarse entre "barato de mantener" y "barato de recuperar".

**Q4.** `--re-add` reinserta el *mismo* miembro cuyo contador de eventos y bitmap el array todavía reconoce. Solo se copian las regiones marcadas como sucias en el bitmap desde la caída, así que si no se escribió nada mientras estuvo afuera, la recuperación es casi instantánea. Un `--add` de un dispositivo nuevo/ajeno no tiene historia compartida — `md` no puede asumir que ninguna región esté sincronizada, así que realiza una reconstrucción completa.

**Q5.** El bitmap externo es preferible cuando la I/O de actualización del bitmap compite con la I/O del array en los mismos spindles, o cuando los propios dispositivos del array son el cuello de botella — poner el bitmap en un dispositivo separado, rápido y confiable elimina esa contención (también útil para arrays muy grandes donde se quiere el bitmap en almacenamiento independiente). Restricción estricta: el archivo de bitmap externo **no** debe residir en el array que protege (e idealmente en ningún dispositivo que falle junto con él), o una falla podría llevarse tanto los datos como la metadata de recuperación de forma simultánea.

**Q6.** Durante el reshape, los stripes se leen en el layout viejo y se escriben en el layout nuevo; hay una "sección crítica" (típicamente el comienzo del array) donde las regiones de datos vieja y nueva se solapan, así que una interrupción a mitad de la escritura podría corromper datos que no tienen otra copia. El `--backup-file` retiene esa región crítica para que la operación sea reiniciable/segura ante un rollback a través de un crash o reinicio. Es crítico principalmente al **comienzo** del reshape (y siempre que las regiones vieja/nueva se solapen). **No** debe residir en el array que se está reshapeando — colóquelo en almacenamiento independiente.

**Q7.** `md` y el filesystem son capas separadas: hacer crecer el array agranda el dispositivo de bloques, pero el filesystem solo usa el tamaño con el que fue creado/redimensionado por última vez. Restricción de orden: primero debe **hacer crecer el array**, y luego hacer crecer el filesystem hacia el nuevo espacio (`resize2fs`, `xfs_growfs`, etc.). Hacerlo al revés no tiene sentido — no se puede hacer crecer un filesystem más allá del dispositivo en el que reside.

**Q8.** `speed_limit_min` es el piso que `md` intenta garantizar para resync/reconstrucción/reshape incluso bajo carga de primer plano; `speed_limit_max` es el techo que no excederá cuando el array está por lo demás ocioso (ambos en KiB/s, por dispositivo). Suba el **min** durante una reconstrucción en estado *degradado* para achicar la ventana vulnerable (vuelva a la redundancia más rápido, aceptando la ralentización del primer plano). Baje el **max** durante un reshape de rutina en un sistema en vivo para proteger la latencia de la aplicación, ya que no hay un riesgo urgente de redundancia.

**Q9.** Agregar un dispositivo para aumentar la cantidad de dispositivos de un RAID5 compra **capacidad** — más discos de datos, la misma redundancia de paridad única. Migrar de RAID5 → RAID6 también agrega un dispositivo pero para comprar **redundancia** — el miembro extra guarda la segunda paridad (Q), tolerando una segunda falla. La misma acción (`--add` y luego `--grow`), distinta intención: una ensancha la porción de datos del stripe, la otra ensancha su porción de paridad.

**Q10.** RAID6 protege contra la **segunda falla durante una reconstrucción de RAID5**: cuando muere un disco, una reconstrucción de RAID5 lee *cada* sector de *cada* disco sobreviviente para reconstruir la paridad — exactamente la carga de trabajo con más probabilidad de sacar a la luz un error de lectura irrecuperable (URE) latente en un segundo disco. En arrays SATA grandes la probabilidad de toparse con un URE a lo largo de una lectura de todo el array no es trivial, así que las reconstrucciones de RAID5 pueden fallar. La segunda paridad de RAID6 sobrevive a esa segunda falla, por lo que es la opción por defecto para arrays grandes.

**Q11.** Un RAID1 de 2 dispositivos ya contiene dos copias completas. Convertirlo a RAID5 reinterpreta los dos miembros como un RAID5 degenerado de 2 discos (un dato + una paridad, donde la paridad de un único bloque de datos es igual al dato mismo), así que no se requiere ninguna reescritura de datos del contenido existente para el cambio de nivel. Luego se hace `--add` de más miembros y `--grow --raid-devices=N`, y *ese* paso reshapea para distribuir datos y paridad a través de todos los discos.

**Q12.** Una pata `write-mostly` se evita para las **lecturas** (el array sirve las lecturas desde la pata rápida siempre que sea posible) pero igual recibe todas las **escrituras** para seguir siendo un mirror válido. Ganancia: la latencia/throughput de lectura no se ve arrastrada hacia abajo por la pata lenta. Salvedad de `write-behind`: las escrituras a la pata lenta se confirman a la capa superior *antes* de haber aterrizado allí de forma durable, así que un crash puede dejar la pata lenta momentáneamente atrasada — el bitmap es lo que permite al array recuperar la consistencia, pero la pata lenta por sí sola no está garantizada como actual en el instante de la confirmación.

**Q13.** `write-behind` confirma una escritura una vez que la pata rápida la tiene, mientras la copia de la pata lenta sigue en vuelo. Algo debe recordar que la pata lenta tiene regiones pendientes, aún no durables, para poder resincronizarlas tras un crash — ese es exactamente el trabajo del write-intent bitmap. Sin un bitmap no habría registro de qué regiones adeuda todavía la pata lenta, así que las escrituras asincrónicas no podrían volverse seguras.

**Q14.** `256` acota la cantidad máxima de solicitudes write-behind pendientes encoladas hacia la pata lenta. Un valor demasiado alto en una pata genuinamente lenta permite que se acumule un backlog grande de escrituras no confirmadas en la pata lenta, lo que agranda la ventana de pérdida de datos si la pata rápida muere antes de que el backlog se drene, y puede consumir memoria significativa. Es una perilla de profundidad/latencia frente a seguridad.

**Q15.** En la escritura de un stripe de RAID5, el/los bloque(s) de datos y el bloque de paridad deben actualizarse juntos. Un crash entre esas escrituras deja una paridad que ya no coincide con los datos (el "hueco"). Al reiniciar, el array se marca como limpio y luce bien — nada lee la paridad durante la operación normal, así que la discrepancia es invisible. Golpea más tarde: cuando un disco falla y `md` reconstruye el bloque perdido a partir de la paridad *obsoleta/incorrecta*, devuelve datos silenciosamente corruptos.

**Q16.** 
- **Hardware extra:** PPL no necesita ninguno (vive en la metadata del array); un write-journal necesita un dispositivo dedicado (idealmente con protección contra pérdida de energía, p. ej. NVRAM/SSD).
- **Costo de rendimiento:** PPL agrega un costo de escritura modesto; un journal agrega una escritura extra completa de los datos registrados en el journal (mayor costo, mitigado por un dispositivo de journal rápido).
- **Completitud:** PPL cierra el agujero para el caso de consistencia de paridad pero es un log de paridad *parcial* (no registra completamente los datos en el journal); un write-journal cierra el agujero por completo al registrar el stripe antes de confirmarlo.
Elija PPL cuando quiera protección contra el write hole sin dispositivo extra y con bajo overhead; elija un write-journal cuando necesite la garantía más fuerte y pueda dedicar un dispositivo de journal rápido y seguro ante pérdida de energía.

**Q17.** Un bitmap solo registra *qué regiones pueden estar sucias* para poder resincronizarlas más rápido — **no** almacena el contenido correcto de datos ni de paridad. Tras un crash puede indicarle a `md` "resincronizar este stripe", pero resincronizar recalcula la paridad a partir de los datos que ahora están en el disco, que ya pueden ser el estado inconsistente a medio escribir. Acelera la recuperación de datos *que se saben consistentes*; no puede reconstruir la atomicidad que se perdió a mitad de la escritura.

**Q18.** El clásico `--fail`/`--remove`/`--add` cae el array a **degradado** en el momento en que falla el disco y lo mantiene degradado durante toda la reconstrucción sobre el disco nuevo — una ventana larga con tolerancia a fallas reducida (o nula a partir de ahí). `--replace` mantiene el disco saliente en servicio y sincroniza el entrante *en paralelo* con él, así que la redundancia se preserva en todo momento; recién cuando el reemplazo está completamente sincronizado se descarta el disco viejo. Para una falla *predicha* (sectores reasignados/pendientes de SMART en aumento, pero el disco todavía lee) `--replace` es preferible porque nunca se renuncia voluntariamente a la redundancia.

**Q19.** (1) `mdadm --monitor` debe estar corriendo como daemon — es el componente que efectivamente mueve los spares; el kernel no hace esto por sí solo. (2) El spare debe ser **al menos tan grande** como el miembro fallado del array de destino (y ambos arrays deben compartir el mismo nombre de `spare-group` en `mdadm.conf`).

**Q20.** Los nombres de dispositivo del kernel (`/dev/md0`, y los subyacentes `/dev/sdX`) no son estables — dependen del orden de sondeo, del hotplug y de las controladoras agregadas/quitadas, así que el `md0` de hoy puede ser hardware distinto mañana. Fijar por **UUID** ata la config a la identidad real del array/miembro en el superblock, así que el ensamblado es determinista y nunca se ensamblan por accidente los discos equivocados en el array equivocado.

**Q21.** `Fail` (y por extensión una falla de dispositivo que degrada o destruye el array) se trata como urgente y se envía por correo de inmediato, saltándose el agrupamiento del `--delay`. Es especial porque un dispositivo fallado es crítico en el tiempo: cada minuto de demora en alertar es un minuto en que el operador no está reemplazando hardware mientras el array corre sin su redundancia normal.

**Q22.** Dos monitores sondeando los mismos arrays pueden producir **alertas duplicadas** y, peor, **competir en la migración de spares** — ambos pueden intentar mover el mismo spare o mover spares entre arrays de forma inconsistente, y ambos pueden actuar sobre eventos `MoveSpare`/de reconstrucción simultáneamente. Los sistemas de producción corren exactamente una instancia (el `mdmonitor.service` empaquetado); iniciar una segunda a mano invita a acciones conflictivas.

**Q23.** El culpable más probable es la **entrega de correo**, no `mdadm`: `--test`/`--oneshot` genera el evento y se lo entrega al MTA local (sendmail/`/usr/sbin/sendmail`), así que si no hay un MTA instalado/configurado o los alias no resuelven `root`, no llega nada. Aíslelo enviando un correo de prueba directamente (`echo test | mail -s x root@localhost`), revisando los logs del MTA y confirmando que `MAILADDR`/`--mail` esté configurado — o agregue un handler `--program`/`PROGRAM` para probar que `mdadm` está disparando eventos independientemente del correo.

**Q24.** Con un bad-block log, un único sector ilegible se registra y los datos de ese sector se sirven/reconstruyen desde el mirror o la paridad, manteniendo el disco entero en servicio en lugar de expulsarlo ante el primer error — esto evita degradación innecesaria y reconstrucciones en cascada. El peligro en un array *degradado*: no queda una segunda copia/margen de paridad para reconstruir un bad block recién registrado, así que los bad blocks que se acumulan en los miembros *sobrevivientes* durante una reconstrucción pueden convertirse en pérdida de datos irrecuperable — que es exactamente el riesgo de URE-en-reconstrucción-de-RAID5 y el argumento a favor de RAID6 / `--replace` proactivo.

</details>