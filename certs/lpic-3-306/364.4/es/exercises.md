# Ejercicios guiados — Tema 364.4: Alta disponibilidad de red

> **Alcance de este laboratorio.** Estos ejercicios construyen un front-end de red de alta disponibilidad de dos nodos usando **keepalived**. Vas a configurar una VIP flotante con **VRRP**, agregar seguimiento de salud del servicio, manejar el balanceador de carga **LVS/IPVS** del kernel directamente desde keepalived y, por último, compararlo con **ldirectord**. Cada término del objetivo se ejercita al menos una vez: `keepalived`, `keepalived.conf`, `vrrp_instance`, `vrrp_script`, `virtual_server`, `real_server`, `VRRP` y `ldirectord`.
>
> **Referencia:** Objetivos del Examen LPI 306, 364.4 — https://www.lpi.org/our-certifications/exam-306-objectives/

## Topología del laboratorio

| Rol | Host | IP real | Notas |
|---|---|---|---|
| Director / balanceador de carga (primario) | `lb1` | `192.0.2.11` | keepalived MASTER |
| Director / balanceador de carga (secundario) | `lb2` | `192.0.2.12` | keepalived BACKUP |
| Real server A | `rs1` | `192.0.2.21` | Backend HTTP |
| Real server B | `rs2` | `192.0.2.22` | Backend HTTP |
| **VIP flotante** | — | `192.0.2.100` | Dirección de servicio, en poder del director que sea MASTER |

Las direcciones usan el rango de documentación `192.0.2.0/24` (RFC 5737). Ejecutá todo en VMs descartables o en network namespaces — VRRP reclama una IP real en el segmento y moverla por una LAN compartida va a interrumpir a otros hosts.

**Prerrequisitos en `lb1` y `lb2`:** un sistema Debian/Ubuntu o de la familia RHEL con root, `iproute2` y acceso saliente a paquetes. La interfaz `eth0` de abajo es la NIC de la LAN compartida — reemplazala por tu nombre predecible (`ens3`, `enp1s0`, …) en todo el documento.

---

## Ejercicio 1 — Instalar keepalived y preparar el kernel

Ejecutá cada paso en **ambos**, `lb1` y `lb2`, salvo que se indique lo contrario.

1. Instalá keepalived y la herramienta de administración de IPVS:

   ```bash
   # Debian / Ubuntu
   sudo apt-get update && sudo apt-get install -y keepalived ipvsadm

   # RHEL / Rocky / Alma
   sudo dnf install -y keepalived ipvsadm
   ```

2. Confirmá que el módulo del kernel IPVS está disponible y cargalo:

   ```bash
   sudo modprobe ip_vs
   lsmod | grep -E '^ip_vs'
   ```

   Esperado:

   ```
   ip_vs                 172032  0
   nf_conntrack          172032  1 ip_vs
   ```

3. Habilitá los sysctls de ruteo y binding que necesita el director. Creá `/etc/sysctl.d/99-lvs.conf`:

   ```ini
   net.ipv4.ip_forward = 1
   net.ipv4.ip_nonlocal_bind = 1
   ```

   Aplicá y verificá:

   ```bash
   sudo sysctl --system
   sysctl net.ipv4.ip_forward net.ipv4.ip_nonlocal_bind
   ```

   Esperado:

   ```
   net.ipv4.ip_forward = 1
   net.ipv4.ip_nonlocal_bind = 1
   ```

4. Confirmá la tabla IPVS vacía y la versión del binario de keepalived:

   ```bash
   sudo ipvsadm -Ln
   keepalived --version 2>&1 | head -n 1
   ```

   Esperado:

   ```
   IP Virtual Server version 1.2.1 (size=4096)
   Prot LocalAddress:Port Scheduler Flags
     -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
   Keepalived v2.2.8 (04/04,2023)
   ```

**Verificación de comprensión**

- **Q1.1** — keepalived agrupa tres daemons/frameworks lógicamente distintos. Nombralos y decí cuál se ejercita únicamente al poseer la VIP.
- **Q1.2** — ¿Por qué `net.ipv4.ip_nonlocal_bind = 1` es útil en un balanceador de carga aunque la VIP pueda estar ahora mismo en el *otro* nodo?
- **Q1.3** — `ip_vs` es un módulo del *kernel*, mientras que `keepalived` es un daemon de *espacio de usuario*. ¿Cuál es la división del trabajo entre ellos para un `virtual_server`?

---

## Ejercicio 2 — Una VIP flotante con VRRP (activo/pasivo)

1. En **`lb1`** escribí `/etc/keepalived/keepalived.conf`:

   ```
   global_defs {
       router_id LB1
       enable_script_security
       script_user root
   }

   vrrp_instance VI_1 {
       state MASTER
       interface eth0
       virtual_router_id 51
       priority 150
       advert_int 1

       authentication {
           auth_type PASS
           auth_pass Str0ngPass
       }

       virtual_ipaddress {
           192.0.2.100/24 dev eth0
       }
   }
   ```

2. En **`lb2`** escribí el mismo archivo, cambiando solo las tres líneas específicas del nodo:

   ```
   global_defs {
       router_id LB2
       enable_script_security
       script_user root
   }

   vrrp_instance VI_1 {
       state BACKUP
       interface eth0
       virtual_router_id 51
       priority 100
       advert_int 1

       authentication {
           auth_type PASS
           auth_pass Str0ngPass
       }

       virtual_ipaddress {
           192.0.2.100/24 dev eth0
       }
   }
   ```

3. Validá la sintaxis antes de arrancar (keepalived ≥ 2.0.7):

   ```bash
   sudo keepalived -t -f /etc/keepalived/keepalived.conf && echo "config OK"
   ```

4. Iniciá y habilitá el servicio en ambos nodos, después observá la máquina de estados en `lb1`:

   ```bash
   sudo systemctl enable --now keepalived
   sudo journalctl -u keepalived -f
   ```

   Esperado en `lb1`:

   ```
   Keepalived_vrrp[1234]: (VI_1) Entering MASTER STATE
   Keepalived_vrrp[1234]: (VI_1) setting VIPs.
   ```

   Esperado en `lb2`:

   ```
   Keepalived_vrrp[1250]: (VI_1) Entering BACKUP STATE
   ```

5. Confirmá que la VIP está presente **solo** en `lb1`:

   ```bash
   ip -brief addr show eth0
   ```

   Esperado en `lb1`:

   ```
   eth0   UP   192.0.2.11/24 192.0.2.100/24
   ```

   Esperado en `lb2` (sin VIP):

   ```
   eth0   UP   192.0.2.12/24
   ```

6. Dispará un failover deteniendo keepalived en el master:

   ```bash
   # on lb1
   sudo systemctl stop keepalived
   ```

   Dentro de ~`3 × advert_int` segundos, confirmá que `lb2` reclamó la VIP:

   ```bash
   # on lb2
   ip -brief addr show eth0
   journalctl -u keepalived -n 3 --no-pager
   ```

   Esperado en `lb2`:

   ```
   eth0   UP   192.0.2.12/24 192.0.2.100/24
   (VI_1) Entering MASTER STATE
   ```

7. Reiniciá keepalived en `lb1` y observá que hace **preempción** (recupera MASTER porque su prioridad es más alta):

   ```bash
   sudo systemctl start keepalived   # on lb1
   ```

**Verificación de comprensión**

- **Q2.1** — Dos clústeres VRRP independientes comparten un mismo segmento de LAN. ¿Qué única directiva *debe* diferir entre ellos y qué se rompe si colisiona?
- **Q2.2** — El backup declaró `priority 100` y `state BACKUP`. Si ponés `state BACKUP` en *ambos* nodos pero mantenés las prioridades 150/100, ¿el nodo correcto igualmente se convertiría en MASTER? ¿Por qué?
- **Q2.3** — ¿Aproximadamente cuánto tiempo estuvo inalcanzable la VIP durante el paso 6, y qué directiva controla esa ventana?
- **Q2.4** — En el paso 7, `lb1` recuperó la VIP automáticamente. ¿Qué comportamiento de VRRP es ese y qué directiva lo desactiva? Dá una razón por la que lo desactivarías en producción.
- **Q2.5** — La VIP se escribe `192.0.2.100/24 dev eth0`. ¿Qué envía keepalived por el cable en el instante en que se convierte en MASTER para que los switches y los peers actualicen sus tablas de reenvío?

---

## Ejercicio 3 — VRRP con seguimiento de salud usando `vrrp_script` (failover consciente del servicio)

Un director que sigue en poder de la VIP después de que su servicio de front-end se cayó es un agujero negro. Acá keepalived hace seguimiento de un servicio local y *se degrada a sí mismo* cuando el servicio está caído. Hacemos seguimiento de `haproxy` como front-end representativo (instalalo o sustituilo por cualquier servicio que puedas detener).

1. En **ambos** nodos agregá un script de seguimiento y asocialo a la instancia. Editá `/etc/keepalived/keepalived.conf`, insertando el bloque `vrrp_script` por encima de `vrrp_instance` y un bloque `track_script` dentro de él:

   ```
   vrrp_script chk_haproxy {
       script "/usr/bin/killall -0 haproxy"   # exit 0 if the process exists
       interval 2                              # run every 2 s
       timeout 3
       fall 2                                  # 2 failures ⇒ KO
       rise 2                                  # 2 successes ⇒ OK
       weight -60                              # subtract 60 from priority on KO
   }

   vrrp_instance VI_1 {
       state MASTER            # BACKUP on lb2
       interface eth0
       virtual_router_id 51
       priority 150            # 100 on lb2
       advert_int 1

       authentication {
           auth_type PASS
           auth_pass Str0ngPass
       }

       virtual_ipaddress {
           192.0.2.100/24 dev eth0
       }

       track_script {
           chk_haproxy
       }
   }
   ```

2. Recargá keepalived (no hace falta reiniciar) y confirmá que el script está registrado:

   ```bash
   sudo systemctl reload keepalived
   journalctl -u keepalived -n 5 --no-pager
   ```

   Esperado (el script arranca en el estado correcto):

   ```
   Keepalived_vrrp[1234]: (VI_1) Entering MASTER STATE
   Keepalived_vrrp[1234]: VRRP_Script(chk_haproxy) succeeded
   ```

3. En `lb1`, asegurate de que `lb1` tiene actualmente la VIP, después **matá el servicio bajo seguimiento** y observá cómo colapsa la prioridad:

   ```bash
   sudo systemctl stop haproxy        # or: sudo killall haproxy
   sudo journalctl -u keepalived -f
   ```

   Esperado en `lb1`:

   ```
   VRRP_Script(chk_haproxy) failed
   (VI_1) Changing effective priority from 150 to 90
   (VI_1) Master received advert from 192.0.2.12 with higher priority 100, ours 90
   (VI_1) Entering BACKUP STATE
   ```

4. Confirmá que la VIP migró a `lb2` aunque keepalived sigue *ejecutándose* en `lb1`:

   ```bash
   ip -brief addr show eth0   # on lb1: VIP gone; on lb2: VIP present
   ```

5. Recuperá el servicio en `lb1` y confirmá que la VIP vuelve:

   ```bash
   sudo systemctl start haproxy
   ```

   Esperado: `chk_haproxy` sube, la prioridad efectiva vuelve a 150, `lb1` hace preempción y vuelve a MASTER.

**Verificación de comprensión**

- **Q3.1** — Las prioridades base son 150 (`lb1`) y 100 (`lb2`), y la diferencia es 50. Explicá con precisión por qué un `weight` de `-60` fuerza un failover pero `weight -20` *no*.
- **Q3.2** — ¿Cuál es la diferencia de comportamiento entre `weight 0` (el valor por defecto) y un `weight` distinto de cero cuando el script falla?
- **Q3.3** — `killall -0 haproxy` solo demuestra que el *proceso existe*. Nombrá un modo de falla que este chequeo pasa por alto y describí un `script` mejor para ello.
- **Q3.4** — ¿Contra qué protegen `fall 2` / `rise 2`, y cuál es el compromiso de subirlos?
- **Q3.5** — ¿Por qué importa acá `enable_script_security`, y qué se niega a hacer keepalived si el archivo del script es escribible por el grupo o por todos?

---

## Ejercicio 4 — Manejar LVS/IPVS desde keepalived (`virtual_server` / `real_server`)

Ahora keepalived programa la tabla IPVS del kernel directamente y hace chequeos de salud de los backends. Esto reemplaza el modelo de "hacer seguimiento de un HAProxy local" por un director de Capa 4. Prepará `rs1`/`rs2` para servir HTTP en el puerto 80 (por ejemplo, `python3 -m http.server 80` detrás de un `/` que devuelve 200), después configurá los directores.

1. En **ambos** directores, agregá un bloque `virtual_server` a `/etc/keepalived/keepalived.conf`:

   ```
   virtual_server 192.0.2.100 80 {
       delay_loop 6
       lb_algo wrr
       lb_kind DR
       persistence_timeout 50
       protocol TCP

       real_server 192.0.2.21 80 {
           weight 3
           HTTP_GET {
               url {
                   path /health
                   status_code 200
               }
               connect_timeout 3
               retry 3
               delay_before_retry 3
           }
       }

       real_server 192.0.2.22 80 {
           weight 1
           TCP_CHECK {
               connect_timeout 3
               connect_port 80
           }
       }
   }
   ```

2. Recargá y confirmá que keepalived pobló la tabla IPVS **solo en el MASTER actual**:

   ```bash
   sudo systemctl reload keepalived
   sudo ipvsadm -Ln
   ```

   Esperado en el MASTER:

   ```
   IP Virtual Server version 1.2.1 (size=4096)
   Prot LocalAddress:Port Scheduler Flags
     -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
   TCP  192.0.2.100:80 wrr persistent 50
     -> 192.0.2.21:80                Route   3      0          0
     -> 192.0.2.22:80                Route   1      0          0
   ```

3. Generá tráfico desde un cliente y observá la tabla de conexiones y la planificación:

   ```bash
   for i in $(seq 1 8); do curl -s http://192.0.2.100/ >/dev/null; done
   sudo ipvsadm -Lnc          # per-connection state
   sudo ipvsadm -Ln --stats   # aggregate counters
   ```

4. Sacá de servicio un backend y confirmá que keepalived **lo expulsa de la tabla IPVS**:

   ```bash
   # on rs1
   sudo systemctl stop http-backend      # or kill the listener
   # on the director
   sudo journalctl -u keepalived -n 5 --no-pager
   sudo ipvsadm -Ln
   ```

   Esperado en el director:

   ```
   Keepalived_healthcheckers: Health check for [192.0.2.21]:80 failed. Removing from server pool.
   TCP  192.0.2.100:80 wrr persistent 50
     -> 192.0.2.22:80                Route   1      0          0
   ```

5. Volvé a levantar `rs1` y confirmá que se vuelve a agregar automáticamente una vez que el chequeo `HTTP_GET` pasa de nuevo.

**Verificación de comprensión**

- **Q4.1** — La columna `Forward` muestra `Route`. ¿Qué `lb_kind` lo produjo, y qué mostraría la columna para los otros dos métodos de reenvío?
- **Q4.2** — En el paso 2 la tabla IPVS apareció en el MASTER pero *no* en el BACKUP, aunque ambas configuraciones son idénticas. ¿Por qué? ¿Qué vincula el ciclo de vida de `virtual_server` con el estado de VRRP?
- **Q4.3** — Con `lb_algo wrr` y pesos 3/1, ¿cómo se distribuyen diez conexiones nuevas? ¿En qué se diferenciaría `lc`?
- **Q4.4** — `persistence_timeout 50` aparece como `persistent 50`. ¿Qué propiedad del cliente fija a un backend? Nombrá una aplicación que se rompe sin ella y un problema que puede causar.
- **Q4.5** — Para `lb_kind DR`, ¿qué dos cosas deben configurarse en **cada real server** para que el direct routing funcione siquiera? (Pista: la VIP y ARP.)
- **Q4.6** — Un real server estaba sano pero ahora falta en `ipvsadm -Ln`. Dá la secuencia ordenada de comandos que ejecutarías en el director *y* en el backend para distinguir "backend caído" de "chequeo de salud mal configurado".

---

## Ejercicio 5 — Scripts de notificación y observabilidad del estado

Los operadores necesitan *saber* cuándo un nodo cambia de rol. keepalived ejecuta un hook en cada transición.

1. En ambos nodos creá `/etc/keepalived/notify.sh` (modo `0750`, propiedad de root):

   ```bash
   #!/bin/bash
   # $1 = "INSTANCE"/"GROUP", $2 = name, $3 = state (MASTER|BACKUP|FAULT), $4 = priority
   TYPE=$1; NAME=$2; STATE=$3
   logger -t keepalived-notify "VRRP ${TYPE} ${NAME} -> ${STATE}"
   case "$STATE" in
       MASTER) logger -t keepalived-notify "Now MASTER: starting VIP-bound duties" ;;
       BACKUP) logger -t keepalived-notify "Now BACKUP: standing down" ;;
       FAULT)  logger -t keepalived-notify "FAULT: local checks failing" ;;
   esac
   ```

   ```bash
   sudo chown root:root /etc/keepalived/notify.sh
   sudo chmod 0750 /etc/keepalived/notify.sh
   ```

2. Referenciá los scripts dentro de `vrrp_instance VI_1` (agregá estas líneas y recargá):

   ```
       notify_master "/etc/keepalived/notify.sh INSTANCE VI_1 MASTER"
       notify_backup "/etc/keepalived/notify.sh INSTANCE VI_1 BACKUP"
       notify_fault  "/etc/keepalived/notify.sh INSTANCE VI_1 FAULT"
       notify        "/etc/keepalived/notify.sh"
   ```

3. Forzá una transición (deteniendo keepalived en el master) y leé los mensajes:

   ```bash
   sudo journalctl -t keepalived-notify -n 10 --no-pager
   ```

   Esperado en el backup promovido:

   ```
   keepalived-notify: VRRP INSTANCE VI_1 -> MASTER
   keepalived-notify: Now MASTER: starting VIP-bound duties
   ```

**Verificación de comprensión**

- **Q5.1** — Distinguí `notify_master`, `notify_backup` y `notify_fault`. ¿Cuál se dispara cuando falla un `track_script` con `weight 0`?
- **Q5.2** — Un script de notify que tarda 30 s en retornar es peligroso. ¿Cuál es el riesgo para la máquina de estados de VRRP, y cómo deberían lanzarse en su lugar las acciones de larga duración?
- **Q5.3** — Querés que el *backup* mantenga HAProxy detenido y solo lo inicie al ser promovido (activo/pasivo real para un servicio que no puede correr dos veces). Esbozá cómo `notify_master`/`notify_backup` implementan eso.

---

## Ejercicio 6 — ldirectord como chequeador de salud de real servers alternativo

Antes de que keepalived absorbiera la gestión de LVS, el clásico stack de Linux-HA emparejaba **ldirectord** (de `resource-agents`) con Heartbeat/Pacemaker para mantener la tabla IPVS. Deberías reconocer su configuración.

1. Instalá ldirectord (paquete `ldirectord` en Debian; parte de `resource-agents` en RHEL):

   ```bash
   sudo apt-get install -y ldirectord      # Debian/Ubuntu
   ```

2. Creá `/etc/ha.d/ldirectord.cf`:

   ```
   checktimeout=3
   checkinterval=5
   autoreload=yes
   quiescent=no
   logfile="/var/log/ldirectord.log"

   virtual=192.0.2.100:80
       real=192.0.2.21:80 gate 3
       real=192.0.2.22:80 gate 1
       service=http
       request="/health"
       receive="OK"
       scheduler=wrr
       protocol=tcp
       checktype=negotiate
   ```

3. Ejecutalo en primer plano para programar IPVS, después inspeccioná la tabla:

   ```bash
   sudo ldirectord -d /etc/ha.d/ldirectord.cf start
   sudo ipvsadm -Ln
   ```

   Esperado: la misma tabla `192.0.2.100:80 wrr`, donde `gate` significa direct-routing (el reenviador `Route`).

> **No ejecutes ldirectord y un `virtual_server` de keepalived contra la misma VIP al mismo tiempo** — ambos escriben la tabla IPVS y van a pelear. Detené el virtual_server de keepalived (o ejecutá esto en un nodo aislado).

**Verificación de comprensión**

- **Q6.1** — Mapeá estas palabras clave de ldirectord a sus equivalentes en keepalived: `gate`, `checktype=negotiate`, `request`/`receive`, `quiescent=yes`, `scheduler=wrr`.
- **Q6.2** — `quiescent=yes` vs `quiescent=no`: ¿qué le hace cada uno a un real server fallido en la tabla IPVS, y por qué `quiescent=yes` ayuda a las conexiones de larga duración?
- **Q6.3** — Arquitectónicamente, ¿qué *no* provee ldirectord que keepalived sí, obligando a emparejar ldirectord con Heartbeat/Pacemaker para una solución de HA completa?

---

<details>
<summary><strong>Clave de respuestas</strong></summary>

### Ejercicio 1

**A1.1** — keepalived contiene (1) un **framework VRRP** para el failover de IP, (2) un **framework de chequeo de salud** (`checkers`) que sondea los real servers y (3) una **capa de control de IPVS** que programa la tabla LVS del kernel. Poseer una VIP flotante con `vrrp_instance` ejercita únicamente el **framework VRRP** — no se necesitan chequeadores de salud ni IPVS para una VIP a secas.

**A1.2** — Con `ip_nonlocal_bind = 1`, un servicio de espacio de usuario (HAProxy, nginx) puede hacer `bind()` a la VIP incluso cuando esa dirección *no está actualmente* en ninguna interfaz local — es decir, mientras el nodo es BACKUP. Sin eso, el servicio no logra iniciar en el backup y no se puede pre-calentar, y en diseños activo/activo un nodo no podría hacer bind a una VIP que vive en su peer.

**A1.3** — El **módulo `ip_vs` del kernel hace el reenvío/planificación real de paquetes** en la Capa 4 (matchea VIP:puerto, elige un real server según el scheduler, reescribe/encapsula/rutea el paquete). **keepalived (espacio de usuario) solo gestiona la tabla**: agrega/quita entradas `virtual_server`/`real_server` y ejecuta los chequeos de salud que deciden la membresía. keepalived nunca ve los paquetes del plano de datos.

### Ejercicio 2

**A2.1** — `virtual_router_id` (el VRID) debe ser único por dominio VRRP en un segmento. Si dos clústeres comparten el mismo VRID *y* la misma interfaz, sus advertisements se interpretan mutuamente como pertenecientes a un único router virtual; los nodos equivocados participan en la misma elección, provocando split-brain o una VIP que flapea. (Que `auth_pass` difiera no alcanza — el VRRPv3 moderno ignora la autenticación.)

**A2.2** — Sí. `state` es solo el estado **inicial** que un nodo anuncia al arrancar; el MASTER en estado estable lo decide la **elección**, que gana la `priority` más alta (150) sin importar el `state` declarado. `state MASTER` simplemente permite que ese nodo asuma el rol de inmediato en vez de esperar a escuchar a un peer de menor prioridad.

**A2.3** — Aproximadamente **3 × `advert_int` ≈ 3 segundos** (el intervalo master-down: el backup declara muerto al master después de perder ~3 períodos de advertisement). Lo gobierna `advert_int` (por defecto 1 s). Bajarlo acelera el failover pero arriesga failovers falsos en una LAN congestionada.

**A2.4** — Eso es **preempción** (el comportamiento por defecto): un nodo de mayor prioridad recupera MASTER cuando vuelve. Se desactiva con `nopreempt` (y poniendo `state BACKUP` en ese nodo). Lo desactivás para evitar una **segunda interrupción innecesaria** — cuando el nodo recuperado hace preempción, la VIP se mueve de nuevo y las tablas de conexiones/persistencia se resetean, así que muchos operadores prefieren que el MASTER actual siga sirviendo.

**A2.5** — Un **ARP gratuito** (GARP) para la VIP (y NDP no solicitado para IPv6). Actualiza las tablas CAM/ARP de los switches y vecinos para que las tramas destinadas a `192.0.2.100` ahora vayan a la MAC del nuevo MASTER.

### Ejercicio 3

**A3.1** — keepalived calcula una **prioridad efectiva = prioridad base + ajuste de weight**. Un `weight` negativo se suma (es decir, se resta) **solo cuando el script está KO**. Así que al fallar, `lb1` pasa a `150 − 60 = 90`, que está **por debajo** del 100 de `lb2` → failover. Con `weight -20`, `lb1` al fallar queda en `150 − 20 = 130`, todavía **por encima** de 100 → sin failover. La magnitud del weight (negativo) debe superar la diferencia de prioridad base de 50 para cruzar al peer.

**A3.2** — Con `weight 0` (por defecto), un `track_script` que falla lleva a toda la `vrrp_instance` directamente al estado **FAULT** (cede MASTER incondicionalmente). Con un `weight` distinto de cero, la falla en cambio **ajusta la prioridad efectiva** y deja que la elección normal decida — así que una degradación solo ocurre si la prioridad ajustada efectivamente cae por debajo de un peer sano.

**A3.3** — `killall -0` solo señala que existe un proceso con ese nombre; pasa por alto un **servicio colgado/en deadlock que está escuchando pero no sirviendo** (no acepta requests, devuelve errores o contenido incorrecto). Un chequeo mejor realmente ejercita el servicio, por ejemplo `script "/usr/bin/curl -fsS -o /dev/null http://127.0.0.1/health"` (salida distinta de cero ante cualquier no-2xx/timeout).

**A3.4** — `fall`/`rise` requieren **N resultados consecutivos antes de un cambio de estado**, amortiguando el **flapping** provocado por un pico transitorio (un sondeo lento no dispara failover; un sondeo con suerte no declara recuperación). El compromiso: valores más altos agregan latencia — `fall N × interval` segundos extra antes de que un servicio genuinamente muerto dispare el failover.

**A3.5** — `enable_script_security` hace que keepalived **se niegue a ejecutar cualquier script que sea escribible por no-root** (o ubicado en una ruta escribible) cuando de otro modo correría como root, cerrando un agujero de escalada de privilegios. Si `notify.sh` / el script de chequeo es escribible por el grupo o por todos, keepalived registra un error de seguridad y **omite ejecutarlo** (o baja privilegios), porque de lo contrario un usuario de menor privilegio podría inyectar comandos que corren como root.

### Ejercicio 4

**A4.1** — `Route` lo produce **`lb_kind DR`** (direct routing). Los otros: `lb_kind NAT` → **`Masq`**, `lb_kind TUN` → **`Tunnel`** (encapsulación IP-IP).

**A4.2** — keepalived solo programa el `virtual_server` de IPVS mientras la `vrrp_instance` asociada es **MASTER**; en un nodo BACKUP retira las entradas (o nunca las instala). Esto evita que dos directores posean la misma tabla IPVS para una misma VIP. (Cuando `virtual_server` no está explícitamente asociado a una instancia, keepalived igual vincula la tabla LVS a la maestría VRRP de la VIP que sirve.)

**A4.3** — `wrr` (weighted round robin) con pesos 3:1 reparte las conexiones en una **proporción de 3 a 1** sin importar la carga — aproximadamente `rs1, rs1, rs1, rs2, rs1, rs1, rs1, rs2, …` (≈7 a `rs1`, ≈3 a `rs2` sobre diez). `lc`/`wlc` (weighted least-connections) en cambio envía cada conexión nueva al backend con la **menor cantidad de conexiones activas** (escaladas por peso), adaptándose a la carga real y a las sesiones de larga duración en lugar de a una cadencia fija.

**A4.4** — Fija por **IP de origen del cliente** (todas las conexiones de un mismo cliente van al mismo real server durante la ventana del timeout). Aplicaciones que la necesitan: cualquiera con **estado de sesión del lado del servidor no compartido entre backends** (por ejemplo, un carrito de compras con estado, algunas configuraciones de FTP-data). Contra: **anula la distribución pareja de la carga** — un NAT/proxy grande detrás de una sola IP de origen aterriza por completo en un backend, y el rebalanceo después de que un backend vuelve se demora.

**A4.5** — En cada real server: (1) la **VIP debe configurarse en una interfaz que no haga ARP** (típicamente el loopback, `lo`, como `192.0.2.100/32`) para que pueda aceptar paquetes destinados a la VIP, y (2) **supresión de ARP** para la VIP (`arp_ignore=1`, `arp_announce=2` en las interfaces relevantes) para que los real servers **no** respondan ARP por la VIP y se la roben al director.

**A4.6** — En el director: `ipvsadm -Ln` (confirmá que desapareció), después `journalctl -u keepalived | grep 192.0.2.21` (¿fue una falla del chequeo o se lo quitó por otra razón?). Reproducí el chequeo exacto de keepalived **desde el director** contra el backend — `curl -fsS http://192.0.2.21:80/health` (para `HTTP_GET`) o `nc -zv 192.0.2.21 80` (para `TCP_CHECK`). En el backend: `ss -ltnp | grep :80` (¿está escuchando?) y `curl -fsS http://127.0.0.1/health`. Si el curl local funciona pero el del director falla → red/firewall o un `path`/`status_code` incorrecto en la config del chequeo; si el curl local también falla → backend genuinamente caído.

### Ejercicio 5

**A5.1** — `notify_master` se ejecuta cuando la instancia **se convierte en MASTER**, `notify_backup` cuando **transiciona a BACKUP**, `notify_fault` cuando entra en **FAULT** (falla de chequeo local/interfaz). Un `track_script` con `weight 0` que falla lleva la instancia a **FAULT**, así que se dispara **`notify_fault`** (no `notify_backup`).

**A5.2** — keepalived ejecuta los hooks de notify de una manera que puede **estancar la máquina de estados de VRRP / demorar el procesamiento de advertisements**, así que un script de 30 s puede provocar adverts perdidos, transiciones falsas o split-brain. Las acciones de larga duración deben lanzarse **en segundo plano** (fork/`&`, `systemd-run`, o encolar un trabajo) para que el hook retorne en milisegundos.

**A5.3** — Mantené HAProxy **deshabilitado/detenido** por defecto para que los nodos BACKUP no lo ejecuten. En `notify_master`, `systemctl start haproxy`; en `notify_backup` (y `notify_fault`), `systemctl stop haproxy`. Resultado: exactamente el nodo que tiene la VIP ejecuta el servicio — activo/pasivo genuino para un servicio que no debe correr en dos lugares.

### Ejercicio 6

**A6.1** — `gate` → `lb_kind DR`; `checktype=negotiate` → un chequeo de capa de aplicación como `HTTP_GET` (obtener y validar contenido) en vez de un `TCP_CHECK` a secas (`checktype=connect`); `request`/`receive` → el `url { path … }` de keepalived más el `status_code`/`digest` esperado; `quiescent=yes` → el `inhibit_on_failure` de keepalived (poner weight 0 en vez de quitar); `scheduler=wrr` → `lb_algo wrr`.

**A6.2** — `quiescent=no` **quita** un real server fallido de la tabla IPVS (su entrada desaparece). `quiescent=yes` **mantiene la entrada pero pone su weight en 0**, de modo que no se planifican *nuevas* conexiones hacia él mientras las **conexiones establecidas existentes sobreviven** — mejor para sesiones de larga duración, que una eliminación total cortaría.

**A6.3** — ldirectord gestiona solo la **tabla IPVS y la salud de los real servers**; **no provee failover de la VIP entre directores** (no tiene VRRP/heartbeat propio). Debe emparejarse con **Heartbeat/Pacemaker** para mover la VIP e iniciar/detener ldirectord en el nodo sobreviviente. keepalived incluye esa capa VRRP por sí mismo, así que un único daemon cubre tanto el failover del director como el chequeo de salud de los backends.

</details>

**Fuentes**
- Objetivos del Examen LPI 306 (364.4 Network High Availability) — https://www.lpi.org/our-certifications/exam-306-objectives/
- keepalived — configuración y páginas de manual: https://keepalived.readthedocs.io/en/latest/ y https://www.keepalived.org/manpage.html
- Linux Virtual Server / `ipvsadm`: http://www.linuxvirtualserver.org/ (`man 8 ipvsadm`)
- VRRP v3 — RFC 5798: https://www.rfc-editor.org/rfc/rfc5798
- ldirectord — ClusterLabs `resource-agents`: https://github.com/ClusterLabs/resource-agents (`man 8 ldirectord`)