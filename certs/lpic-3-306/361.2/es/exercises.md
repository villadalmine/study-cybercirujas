# Clústeres con balanceo de carga — Ejercicios guiados (LPIC-3 306, Tema 361.2)

> **Objetivo de examen 361.2 — Peso 13.34.** Estos labs cubren los dos stacks de balanceo de carga que el examen evalúa directamente: **LVS/IPVS** (balanceador L4 del kernel manejado por `ipvsadm`, `keepalived` y `ldirectord`) y **HAProxy** (balanceador L4/L7 en espacio de usuario). Vas a construir cada método de reenvío (NAT, Direct Routing, Tunneling), manejar a mano el scheduler de conexiones, cablear el failover con health checks mediante VRRP, y leer el estado en runtime como lo hace un SRE de guardia.
>
> **Referencia:** LPI Exam 306 Objectives — https://www.lpi.org/our-certifications/exam-306-objectives/

## Topología del lab

Todos los ejercicios asumen esta disposición de tres nodos en una red de laboratorio. Ajustá las direcciones a tu entorno, pero mantené los roles.

```
                         client 192.168.10.50
                                  │
                                  ▼
                        VIP 192.168.10.100
                     ┌────────────────────────┐
                     │  director / lb1         │  eth0 192.168.10.10  (public)
                     │  (LVS or HAProxy)       │  eth1 10.0.0.1/24    (backend)
                     └────────────────────────┘
                          │                 │
              ┌───────────┘                 └───────────┐
              ▼                                          ▼
     rs1 10.0.0.11/24                          rs2 10.0.0.12/24
     nginx/apache :80                          nginx/apache :80
```

- **director / lb1** — el balanceador de carga. El segundo nodo `lb2` (misma subred pública) se introduce en el Ejercicio 4 para el failover.
- **rs1 / rs2** — real servers, cada uno corriendo un servidor HTTP que devuelve un body distinguible. Preparalos una vez:

```bash
# On rs1 and rs2 (Debian/Ubuntu):
apt-get install -y nginx
echo "Served by $(hostname) — $(hostname -I | awk '{print $1}')" > /var/www/html/index.html
printf 'OK' > /var/www/html/healthz
systemctl enable --now nginx
```

Ejecutá cada paso como `root` (o con `sudo`). Los comandos son para una distro systemd moderna; la sintaxis de `ipvsadm`/`keepalived`/`haproxy` es independiente de la distribución.

---

## Ejercicio 1 — LVS-NAT con `ipvsadm`

**Objetivo:** construir a mano un servicio virtual de capa 4, reenviar con **NAT (masquerading)**, y leer la tabla de runtime de IPVS.

1. Instalá la herramienta de administración de IPVS y confirmá que el módulo del kernel se puede cargar:

   ```bash
   apt-get install -y ipvsadm      # or: dnf install ipvsadm
   modprobe ip_vs
   lsmod | grep ip_vs
   ```

   Esperado (los módulos del scheduler se cargan bajo demanda):

   ```
   ip_vs                 176128  0
   nf_conntrack          172032  1 ip_vs
   ```

2. IPVS es un *router*: con NAT el director reescribe el destino a la entrada y el origen a la salida, así que el kernel debe reenviar paquetes entre interfaces. Habilitalo:

   ```bash
   sysctl -w net.ipv4.ip_forward=1
   ```

3. Creá el **virtual service** en la VIP con el scheduler round-robin, luego adjuntá ambos real servers en modo **masquerading**:

   ```bash
   ipvsadm -A -t 192.168.10.100:80 -s rr
   ipvsadm -a -t 192.168.10.100:80 -r 10.0.0.11:80 -m -w 1
   ipvsadm -a -t 192.168.10.100:80 -r 10.0.0.12:80 -m -w 1
   ```

   Decodificación: `-A` agrega virtual service · `-t` servicio TCP `VIP:port` · `-s rr` scheduler · `-a` agrega real server · `-r` real server `IP:port` · `-m` masquerading (NAT) · `-w` weight.

4. Inspeccioná la tabla:

   ```bash
   ipvsadm -L -n
   ```

   Esperado:

   ```
   IP Virtual Server version 1.2.1 (size=4096)
   Prot LocalAddress:Port Scheduler Flags
     -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
   TCP  192.168.10.100:80 rr
     -> 10.0.0.11:80                 Masq    1      0          0
     -> 10.0.0.12:80                 Masq    1      0          0
   ```

5. El camino de retorno es la parte sutil de NAT. Como el director reescribió la dirección de origen del paquete entrante, la respuesta de un real server debe volver *a través del director* para que se le deshaga el NAT. **En cada real server, configurá la IP de backend del director como gateway por defecto:**

   ```bash
   # On rs1 and rs2:
   ip route replace default via 10.0.0.1
   ```

6. Desde el cliente, generá tráfico y observá cómo alterna:

   ```bash
   # On the client:
   for i in $(seq 1 6); do curl -s http://192.168.10.100/; done
   ```

   Esperado:

   ```
   Served by rs1 — 10.0.0.11
   Served by rs2 — 10.0.0.12
   Served by rs1 — 10.0.0.11
   Served by rs2 — 10.0.0.12
   Served by rs1 — 10.0.0.11
   Served by rs2 — 10.0.0.12
   ```

7. Leé los contadores y la tabla de conexiones en vivo:

   ```bash
   ipvsadm -L -n --stats
   ipvsadm -L -n --rate
   ipvsadm -L -n -c            # active connection entries with TCP state
   ```

   `--stats` muestra los acumulados `Conns / InPkts / OutPkts / InBytes / OutBytes`; `--rate` muestra los valores por segundo `CPS / InPPS / OutPPS / InBPS / OutBPS`. `-c` lista las entradas individuales, p. ej.:

   ```
   TCP 00:57  FIN_WAIT     192.168.10.50:41522 192.168.10.100:80  10.0.0.11:80
   ```

**Checkpoint 1**

- **Q1.1** ¿Por qué `net.ipv4.ip_forward` debe ser `1` para LVS-NAT pero conceptualmente *no* es requerido para LVS-DR (Ejercicio 2)?
- **Q1.2** En el paso 5, ¿qué se rompe si un real server mantiene su propio router como gateway por defecto en lugar de `10.0.0.1`? Rastreá el origen/destino del paquete a lo largo del camino de retorno.
- **Q1.3** En `ipvsadm -L -n`, ¿cuál es la diferencia entre `ActiveConn` e `InActConn`, y en cuál caería una conexión en `FIN_WAIT`?

---

## Ejercicio 2 — LVS Direct Routing (LVS-DR) y el problema de ARP

**Objetivo:** cambiar el mismo servicio a **Direct Routing**, donde el director reescribe solo la MAC de destino y los real servers le responden al cliente directamente. Este es el método LVS de mayor throughput y el que tiene la famosa trampa de ARP.

1. Reconstruí el servicio en modo gatewaying. `-C` limpia todo primero:

   ```bash
   ipvsadm -C
   ipvsadm -A -t 192.168.10.100:80 -s wrr
   ipvsadm -a -t 192.168.10.100:80 -r 10.0.0.11:80 -g -w 3
   ipvsadm -a -t 192.168.10.100:80 -r 10.0.0.12:80 -g -w 1
   ```

   `-g` = gatewaying (Direct Routing). Notá que la columna `Forward` ahora dice `Route`:

   ```bash
   ipvsadm -L -n
   ```

   ```
   TCP  192.168.10.100:80 wrr
     -> 10.0.0.11:80                 Route   3      0          0
     -> 10.0.0.12:80                 Route   1      0          0
   ```

2. En DR el paquete que llega a un real server todavía tiene **IP de destino = VIP** (solo se reescribió la MAC). Por lo tanto el real server debe *poseer* la VIP para aceptar el paquete — pero **nunca debe hacer ARP por ella**, o le disputará al director la propiedad en la LAN. Configurá la VIP en el loopback y endurecé el comportamiento de ARP **en cada real server**:

   ```bash
   # On rs1 and rs2:
   ip addr add 192.168.10.100/32 dev lo
   sysctl -w net.ipv4.conf.all.arp_ignore=1
   sysctl -w net.ipv4.conf.all.arp_announce=2
   sysctl -w net.ipv4.conf.lo.arp_ignore=1
   sysctl -w net.ipv4.conf.lo.arp_announce=2
   ```

   - `arp_ignore=1` — responder a una petición ARP solo si la IP objetivo está configurada en la interfaz por la que llegó la petición. La VIP vive en `lo`, así que la interfaz real permanece en silencio sobre ella.
   - `arp_announce=2` — originar siempre los anuncios ARP desde la mejor dirección de interfaz *real*, nunca desde la VIP del loopback.

3. Como los real servers ahora le responden al cliente directamente (esquivando al director en la salida), necesitan una ruta normal hacia el cliente — el director **no** está en el camino de retorno:

   ```bash
   # On rs1 and rs2, ensure the public/client network is reachable directly:
   ip route get 192.168.10.50
   ```

4. Generá tráfico y confirmá el reparto ponderado 3:1:

   ```bash
   # On the client:
   for i in $(seq 1 8); do curl -s http://192.168.10.100/; done | sort | uniq -c
   ```

   Esperado (rs1 obtiene ~3× la parte de rs2):

   ```
         6 Served by rs1 — 10.0.0.11
         2 Served by rs2 — 10.0.0.12
   ```

5. Comprobá que el tráfico de retorno saltea al director. En el director, observá que los bytes salientes se mantienen cerca de cero incluso bajo carga:

   ```bash
   ipvsadm -L -n --stats
   ```

   `OutPkts` / `OutBytes` permanecen en 0 (o diminutos) porque las respuestas nunca atraviesan el director en modo DR.

**Checkpoint 2**

- **Q2.1** Explicá con precisión qué reescribe el director en un paquete DR vs. un paquete NAT.
- **Q2.2** Te olvidaste de `arp_ignore`/`arp_announce` en los real servers. Describí el síntoma de falla que ve el cliente, y por qué suele ser *intermitente*.
- **Q2.3** ¿Por qué DR requiere que los real servers estén en el **mismo segmento físico / dominio L2** que el director, mientras que Tunneling (`-i`, IPIP) no?
- **Q2.4** ¿Por qué `OutBytes` en el director es ~0 en DR pero grande en NAT?

---

## Ejercicio 3 — Algoritmos de scheduling de conexiones

**Objetivo:** percibir la diferencia entre los schedulers que el examen menciona, y cambiarlos sin desarmar el servicio.

1. Listá los schedulers que soporta tu kernel (cada uno es un módulo `ip_vs_<algo>`):

   ```bash
   ls /lib/modules/$(uname -r)/kernel/net/netfilter/ipvs/ | grep ip_vs_
   ```

   Lo esperado incluye: `ip_vs_rr` (round-robin), `ip_vs_wrr` (weighted RR), `ip_vs_lc` (least-connection), `ip_vs_wlc` (weighted LC), `ip_vs_sh` (source hashing), `ip_vs_dh`, `ip_vs_sed`, `ip_vs_nq`.

2. Cambiá el scheduler **en el lugar** con `-E` (editar virtual service) — las conexiones ya rastreadas se preservan:

   ```bash
   ipvsadm -E -t 192.168.10.100:80 -s lc      # least-connection
   ipvsadm -L -n | head -5
   ```

3. Compará la distribución bajo una carga lenta y concurrente para que los conteos de conexiones realmente difieran. Dale a rs1 un retardo deliberado para simular un nodo más lento, luego alterná entre `rr` y `lc`:

   ```bash
   # On the client, 20 concurrent slow requests:
   ipvsadm -E -t 192.168.10.100:80 -s rr
   seq 1 20 | xargs -P20 -I{} curl -s -m 5 http://192.168.10.100/ >/dev/null &
   watch -n1 'ipvsadm -L -n'      # observe ActiveConn per real server
   ```

   Con `rr` los dos servidores reciben un *conteo* igual de conexiones sin importar qué tan ocupado esté cada uno. Repetí con `-s lc` y notá que las nuevas conexiones se dirigen hacia el servidor que en ese momento tenga menos `ActiveConn`.

4. Activá **source hashing** para fijar un cliente a un servidor (un mecanismo de persistencia que no necesita tabla de estado):

   ```bash
   ipvsadm -E -t 192.168.10.100:80 -s sh
   # On the client, every request now hits the SAME real server:
   for i in $(seq 1 5); do curl -s http://192.168.10.100/; done
   ```

5. Alternativamente, mantené un scheduler con estado pero agregá **persistencia** para que un cliente quede pegado durante una ventana de timeout:

   ```bash
   ipvsadm -E -t 192.168.10.100:80 -s wlc -p 600
   ipvsadm -L -n            # note the "persistent 600" flag on the service line
   ```

**Checkpoint 3**

- **Q3.1** Con weights idénticos, ¿cuándo se comportan `lc` y `wlc` de forma idéntica, y cuándo divergen?
- **Q3.2** Un backend tiene un nodo de 32 cores y un nodo de 8 cores. ¿Qué scheduler + parámetro expresa eso, y cómo?
- **Q3.3** Contrastá dos formas de hacer que un cliente siempre llegue al mismo real server: el scheduler `sh` vs. la persistencia `-p <timeout>`. ¿Qué le pasa a cada una cuando se elimina un real server?
- **Q3.4** `sed` (shortest expected delay) y `nq` (never queue) ambos existen. En una oración cada uno, ¿cuándo los preferirías sobre `wlc`?

---

## Ejercicio 4 — Failover con health checks usando `keepalived` (VRRP + IPVS)

**Objetivo:** reemplazar la tabla IPVS construida a mano con una configuración declarativa que keepalived **programa en IPVS por vos**, agrega **health checks** que sacan automáticamente a los real servers muertos, y flota la VIP entre dos directores con **VRRP**.

1. Instalá keepalived en **ambos** `lb1` y `lb2`:

   ```bash
   apt-get install -y keepalived ipvsadm
   ```

2. En **lb1 (MASTER)**, escribí `/etc/keepalived/keepalived.conf`:

   ```conf
   global_defs {
       router_id LB1
       enable_script_security
   }

   # ---- VRRP: floats the VIP between lb1 and lb2 ----
   vrrp_instance VI_1 {
       state MASTER
       interface eth0
       virtual_router_id 51
       priority 150
       advert_int 1
       authentication {
           auth_type PASS
           auth_pass s3cr3tvr
       }
       virtual_ipaddress {
           192.168.10.100/24 dev eth0
       }
   }

   # ---- IPVS: keepalived programs this into the kernel ----
   virtual_server 192.168.10.100 80 {
       delay_loop 6
       lb_algo wrr
       lb_kind NAT
       protocol TCP

       real_server 10.0.0.11 80 {
           weight 3
           HTTP_GET {
               url {
                   path /healthz
                   status_code 200
               }
               connect_timeout 3
               retry 3
               delay_before_retry 3
           }
       }

       real_server 10.0.0.12 80 {
           weight 1
           TCP_CHECK {
               connect_timeout 3
               connect_port 80
           }
       }
   }
   ```

3. En **lb2 (BACKUP)**, usá el *mismo* archivo pero cambiá tres líneas — todo lo demás debe coincidir:

   ```conf
   global_defs { router_id LB2 }
   vrrp_instance VI_1 {
       state BACKUP
       priority 100
       # interface, virtual_router_id, auth_pass, virtual_ipaddress IDENTICAL to lb1
       ...
   }
   ```

4. Iniciá keepalived en ambos y confirmá que la VIP aterriza en el MASTER:

   ```bash
   systemctl enable --now keepalived
   # On lb1:
   ip -brief addr show eth0 | grep 192.168.10.100      # VIP present
   journalctl -u keepalived -n 20 --no-pager           # "Entering MASTER STATE"
   # On lb2:
   ip -brief addr show eth0 | grep 192.168.10.100      # VIP ABSENT (backup)
   ```

5. Confirmá que keepalived pobló IPVS **sin que vos tocaras `ipvsadm`**:

   ```bash
   # On lb1:
   ipvsadm -L -n
   ```

   ```
   TCP  192.168.10.100:80 wrr
     -> 10.0.0.11:80                 Masq    3      0          0
     -> 10.0.0.12:80                 Masq    1      0          0
   ```

6. **Dispará una expulsión por health check.** Rompé el endpoint de salud de rs1 y observá cómo keepalived lo saca del pool:

   ```bash
   # On rs1:
   mv /var/www/html/healthz /var/www/html/healthz.bak     # /healthz now 404
   ```

   ```bash
   # On lb1, within ~delay_loop*retry seconds:
   journalctl -u keepalived -f
   # ... "Health check failed ... Removing service 10.0.0.11:80"
   ipvsadm -L -n        # rs1 is GONE; all traffic now to rs2
   ```

   Restauralo y observá cómo rs1 vuelve automáticamente:

   ```bash
   # On rs1:
   mv /var/www/html/healthz.bak /var/www/html/healthz
   # On lb1: "Health check succeeded ... Adding service 10.0.0.11:80"
   ```

7. **Dispará un failover de director.** Detené keepalived en lb1 y confirmá que lb2 se apodera de la VIP:

   ```bash
   # On lb1:
   systemctl stop keepalived
   # On lb2, within ~3× advert_int:
   ip -brief addr show eth0 | grep 192.168.10.100      # VIP now HERE
   journalctl -u keepalived -n 10 --no-pager           # "Entering MASTER STATE"
   ```

   El `curl http://192.168.10.100/` del cliente sigue funcionando durante el failover.

8. (Referencia) Para el antiguo matcher de **digest** `HTTP_GET`/`SSL_GET`, keepalived compara un MD5 de la página obtenida producido por `genhash`:

   ```bash
   genhash -s 10.0.0.11 -p 80 -u /healthz
   # MD5SUM = 0a4d55a8d778e5022fab701977c5d840   (paste into a `digest` line under url {})
   ```

**Checkpoint 4**

- **Q4.1** `virtual_router_id`, `auth_pass`, y la `virtual_ipaddress` deben ser idénticos en ambos nodos, pero `priority` y `state` difieren. ¿Por qué cada uno?
- **Q4.2** Con `priority 150` (lb1) vs `100` (lb2) y preemption por defecto, ¿qué le pasa a la VIP cuando lb1 se recupera después de un failover? ¿Cómo lo cambia agregar `nopreempt`, y por qué querrías eso?
- **Q4.3** Dos directores declaran ambos `state MASTER` para el mismo `virtual_router_id` pero con un **firewall descartando el multicast de VRRP (224.0.0.18)** entre ellos. ¿Cómo se llama el modo de falla resultante, y qué observa el cliente?
- **Q4.4** Compará `TCP_CHECK` y `HTTP_GET` para un backend web: ¿qué falla real detecta `HTTP_GET path /healthz status_code 200` que `TCP_CHECK` deja pasar silenciosamente?
- **Q4.5** keepalived programó IPVS enteramente desde la configuración. ¿Qué te dio eso por sobre la tabla `ipvsadm` construida a mano en los Ejercicios 1–3?

---

## Ejercicio 5 — HAProxy: balanceo de carga L4 y L7

**Objetivo:** levantar el balanceador en espacio de usuario que el examen empareja con LVS. Obtenés routing L7, health checks conscientes de la aplicación, persistencia por cookie, una página de stats, y reloads sin cortes — a costa de terminar la conexión en el proxy.

1. Instalá HAProxy en lb1 (detené primero el servicio IPVS de keepalived para liberar el puerto 80 / la VIP, o vinculá HAProxy a una dirección distinta):

   ```bash
   apt-get install -y haproxy socat
   haproxy -v      # confirm 2.x+
   ```

2. Escribí `/etc/haproxy/haproxy.cfg`:

   ```conf
   global
       log /dev/log local0
       maxconn 20000
       user  haproxy
       group haproxy
       daemon
       stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners

   defaults
       mode    http
       log     global
       option  httplog
       option  dontlognull
       timeout connect 5s
       timeout client  50s
       timeout server  50s
       retries 3

   frontend web_front
       bind *:80
       default_backend web_back

   backend web_back
       balance roundrobin
       option httpchk GET /healthz
       http-check expect status 200
       cookie SRVID insert indirect nocache
       server web1 10.0.0.11:80 check cookie web1 weight 3
       server web2 10.0.0.12:80 check cookie web2 weight 1

   listen stats
       bind *:8404
       stats enable
       stats uri /stats
       stats refresh 10s
       stats admin if TRUE
   ```

3. **Validá la configuración antes de cargarla** — un error de sintaxis acá tira abajo el proxy:

   ```bash
   haproxy -c -f /etc/haproxy/haproxy.cfg
   ```

   Esperado:

   ```
   Configuration file is valid
   ```

4. Iniciá y generá tráfico:

   ```bash
   systemctl enable --now haproxy
   for i in $(seq 1 8); do curl -s http://192.168.10.10/; done | sort | uniq -c
   ```

   Ponderado 3:1 como se configuró:

   ```
         6 Served by rs1 — 10.0.0.11
         2 Served by rs2 — 10.0.0.12
   ```

5. **Persistencia por cookie.** Con `cookie SRVID insert`, HAProxy estampa el servidor elegido en una cookie para que el navegador quede pegado. Observalo y comprobá la adherencia con `-c cookies.txt`:

   ```bash
   curl -sI http://192.168.10.10/ | grep -i set-cookie
   # Set-Cookie: SRVID=web1; path=/
   for i in 1 2 3; do curl -s -b "SRVID=web2" http://192.168.10.10/; done
   # All three land on rs2, overriding the roundrobin balance.
   ```

6. **Leé el estado en runtime** de dos maneras — la página HTML de stats y el admin socket:

   ```bash
   curl -s "http://192.168.10.10:8404/stats;csv" | cut -d, -f1,2,18 | column -s, -t | head
   echo "show stat" | socat stdio /run/haproxy/admin.sock | cut -d, -f1,2,18 | head
   ```

   La columna 18 es `status` (`UP`/`DOWN`). También podés drenar un servidor en vivo sin editar la configuración:

   ```bash
   echo "set server web_back/web1 state drain" | socat stdio /run/haproxy/admin.sock
   echo "set server web_back/web1 state ready" | socat stdio /run/haproxy/admin.sock
   ```

7. **Dispará el health check de capa de aplicación.** Rompé el `/healthz` de rs1 y observá cómo HAProxy lo marca `DOWN`:

   ```bash
   # On rs1:
   mv /var/www/html/healthz /var/www/html/healthz.bak
   # On lb1:
   watch -n1 'echo "show stat" | socat stdio /run/haproxy/admin.sock | grep web1'
   journalctl -u haproxy -n 5 --no-pager     # "Server web_back/web1 is DOWN"
   ```

8. **Reload sin cortes.** Cambiá `balance roundrobin` por `balance leastconn`, validá, luego recargá — las conexiones establecidas *no* se cortan:

   ```bash
   sed -i 's/balance roundrobin/balance leastconn/' /etc/haproxy/haproxy.cfg
   haproxy -c -f /etc/haproxy/haproxy.cfg && systemctl reload haproxy
   journalctl -u haproxy -n 5 --no-pager     # new worker takes over listeners
   ```

9. (Modo L4) Para correr HAProxy como un balanceador TCP puro — p. ej. para una base de datos o un protocolo no HTTP — cambiá un bloque listen a `mode tcp`:

   ```conf
   listen pgsql
       bind *:5432
       mode tcp
       balance leastconn
       option tcp-check
       server db1 10.0.0.21:5432 check
       server db2 10.0.0.22:5432 check backup
   ```

**Checkpoint 5**

- **Q5.1** Arquitectónicamente, ¿en qué difiere el data path de HAProxy del de LVS-DR? Nombrá una cosa que HAProxy puede hacer *porque* termina la conexión, y un costo de esa terminación.
- **Q5.2** Con `cookie SRVID insert indirect nocache`, explicá qué aporta cada uno de `insert`, `indirect`, y `nocache`.
- **Q5.3** `option httpchk GET /healthz` + `http-check expect status 200` vs. un `check` L4 simple: ¿qué clase de falla detecta el health check HTTP que el check L4 se pierde? (Misma idea que Q4.4 — planteala en términos de HAProxy.)
- **Q5.4** ¿Por qué `haproxy -c -f ...` es un paso obligatorio antes de `systemctl reload`, y qué es específicamente lo que hace que el reload sea «sin cortes»?
- **Q5.5** ¿Cuándo elegirías `balance source` en lugar de `leastconn`, y cuál es el modo de falla de `balance source` cuando cambia el tamaño del pool de servidores?

---

## Ejercicio 6 — `ldirectord`: el clásico health-checker de LVS

**Objetivo:** reconocer la herramienta que el examen todavía lista — `ldirectord` monitorea los real servers y edita la tabla IPVS, históricamente manejado por Heartbeat/Pacemaker. keepalived es el equivalente moderno; conocé la forma de su configuración.

1. Instalá y escribí `/etc/ldirectord.cf`:

   ```bash
   apt-get install -y ldirectord ipvsadm
   ```

   ```conf
   checktimeout=3
   checkinterval=5
   autoreload=yes
   quiescent=yes
   logfile="/var/log/ldirectord.log"

   virtual=192.168.10.100:80
       real=10.0.0.11:80 masq 3
       real=10.0.0.12:80 masq 1
       service=http
       request="/healthz"
       receive="OK"
       scheduler=wrr
       protocol=tcp
       checktype=negotiate
   ```

2. Inicialo y confirmá que programó IPVS:

   ```bash
   systemctl enable --now ldirectord
   ipvsadm -L -n
   ```

3. Rompé el `/healthz` de rs1 (para que el body ya no sea `OK`) y observá la diferencia que hace `quiescent`:

   ```bash
   # On rs1:
   echo "MAINTENANCE" > /var/www/html/healthz
   # On lb1, with quiescent=yes the server's WEIGHT drops to 0 (kept in table);
   # with quiescent=no it would be REMOVED entirely.
   ipvsadm -L -n
   ```

**Checkpoint 6**

- **Q6.1** Con `checktype=negotiate`, ¿qué dos cosas deben ser ambas verdaderas para que rs1 cuente como sano, dados `request="/healthz"` y `receive="OK"`?
- **Q6.2** Contrastá `quiescent=yes` vs `quiescent=no` cuando un real server falla. ¿Cuál evita resetear el estado de persistencia/conexión de los servidores *sanos*, y por qué importa eso bajo carga?
- **Q6.3** En una oración, ¿cuál es el solapamiento funcional entre `ldirectord` y el bloque `virtual_server` de keepalived?

---

## Respuestas

<details>
<summary>Hacé clic para revelar las respuestas</summary>

**Checkpoint 1 — LVS-NAT**

- **A1.1** En NAT el director recibe un paquete en la interfaz pública y debe emitirlo (después de reescribir el destino) en la interfaz de backend — eso es *routing entre interfaces*, que el kernel rechaza a menos que `ip_forward=1`. En DR el director reescribe solo la MAC de destino y reemite la trama en el **mismo** segmento L2; es bridging/redirección en L2 en lugar de routing entre subredes IP, así que `ip_forward` no es la barrera (aunque habilitarlo es inofensivo y a menudo igual se configura).
- **A1.2** El paquete entrante que llega al real server tiene `src = client 192.168.10.50`, `dst = rs 10.0.0.11` (el destino fue DNATeado por el director; el origen queda intacto). La respuesta es `src = 10.0.0.11`, `dst = 192.168.10.50`. Si el real server envía esa respuesta por algún otro router, el director nunca la ve y nunca reescribe el origen de vuelta a la VIP. El cliente entonces recibe una respuesta desde `10.0.0.11:80` para una conexión que abrió hacia `192.168.10.100:80`, así que su kernel la descarta como un paquete fuera de conexión — la conexión se cuelga y expira. Forzar el gateway por defecto a `10.0.0.1` (el director) hace que la respuesta vuelva a pasar por IPVS, que deshace el NAT del origen dejándolo en la VIP.
- **A1.3** `ActiveConn` cuenta las conexiones en estado ESTABLISHED (pasando datos activamente); `InActConn` cuenta las conexiones que IPVS todavía rastrea pero que no están establecidas — SYN_RECV, y los distintos estados de cierre como FIN_WAIT/TIME_WAIT. Una conexión en `FIN_WAIT` se cuenta bajo **InActConn**.

**Checkpoint 2 — LVS-DR**

- **A2.1** NAT reescribe la **IP de destino** del paquete en el ingreso (VIP → IP del real server) y la **IP de origen** en la salida (IP del real server → VIP); el paquete se modifica en L3 en ambas direcciones y debe atravesar el director en ambos sentidos. DR reescribe solo la **dirección MAC de destino** (MAC del director → MAC del real server); el header L3, incluyendo `dst = VIP`, queda intacto, y la respuesta nunca vuelve a pasar por el director.
- **A2.2** Sin `arp_ignore`/`arp_announce`, cada real server responde por ARP por la VIP que tiene en `lo`. La caché ARP del cliente/switch se convierte entonces en una carrera: a veces la VIP resuelve a la MAC del director (funciona), a veces a la MAC de un real server (el tráfico esquiva el balanceador o se rompe). El síntoma es intermitente — algunas conexiones se balancean correctamente, otras van directo a un nodo o fallan — y cambia cada vez que una entrada ARP expira y se vuelve a resolver.
- **A2.3** DR entrega paquetes reescribiendo la MAC de destino L2, lo que solo funciona si el director puede direccionar la MAC del real server directamente — es decir, comparten un dominio de broadcast/L2. Tunneling (`-i`, IPIP) en cambio **encapsula** el paquete original dentro de un nuevo paquete IP dirigido a la IP ruteable del real server, así que el real server puede estar en cualquier lugar alcanzable por IP (subred distinta, sitio distinto); desencapsula y, como DR, le responde directamente al cliente.
- **A2.4** En DR los real servers le responden al cliente directamente, así que el tráfico de retorno — que es la mayor parte de los bytes en respuestas web típicas — nunca pasa por el director; `OutBytes` se mantiene en ~0. En NAT cada respuesta es des-NATeada por el director, así que todos los bytes de respuesta lo atraviesan y `OutBytes` crece con el payload, convirtiendo al director en un cuello de botella de ancho de banda.

**Checkpoint 3 — Schedulers**

- **A3.1** Con weights idénticos en todos los real servers, `wlc` se reduce exactamente a `lc` — ambos eligen el servidor con menos conexiones activas y el término de weight es un multiplicador constante. Divergen solo cuando los weights difieren: `wlc` elige el servidor que minimiza `active_conns / weight`, así que a un servidor con mayor weight se le permiten proporcionalmente más conexiones antes de ser salteado.
- **A3.2** Schedulers ponderados con una relación de weight 4:1, p. ej. `ipvsadm -a ... -r <32core> -w 4` y `-w 1` en el nodo de 8 cores (`wrr` o `wlc`). `wrr` distribuye las nuevas conexiones en esa relación sin importar la carga; `wlc` apunta a la misma relación mientras además reacciona a los conteos actuales de conexiones activas.
- **A3.3** `sh` (source hashing) mapea `hash(client IP)` a un servidor de forma determinística — sin estado por conexión, y sobrevive al failover del director porque es cálculo puro, pero cuando se agrega/elimina un real server el bucketing del hash se desplaza y muchos clientes son **rehasheados a un servidor distinto** (la adherencia se rompe para una fracción grande). La persistencia `-p <timeout>` mantiene una entrada de plantilla por cliente en el estado de IPVS para que el cliente quede pegado durante la ventana de timeout a través de *distintos* puertos/conexiones; al eliminar el servidor de ese cliente la entrada de persistencia se invalida y el cliente es reprogramado, afectando solo a los clientes fijados al nodo caído. Resumen: `sh` es sin estado pero disruptivo ante cambios en el pool; `-p` es con estado, de grano más fino, pero cuesta una tabla de estado y no sobrevive a un failover de director salvo que se sincronice.
- **A3.4** `sed` (shortest expected delay) minimiza `(active+1)/weight`, así que nunca asigna la primera conexión a un servidor ocioso pero de menor weight como podría hacer `wlc` — preferilo cuando querés que las nuevas conexiones se inclinen hacia el nodo más rápido incluso con carga baja. `nq` (never queue) envía una conexión inmediatamente a cualquier servidor con cero conexiones activas antes de aplicar la lógica de `sed` — preferilo para evitar dejar alguna vez a un servidor ocioso sin usar mientras otro encola.

**Checkpoint 4 — keepalived / VRRP**

- **A4.1** `virtual_router_id`, `auth_pass`, y la `virtual_ipaddress` definen el grupo VRRP compartido y el recurso que protege — ambos routers deben coincidir en ellos o formarán grupos separados / rechazarán los adverts del otro / flotarán direcciones distintas. `priority` y `state` son pistas de rol *por nodo*: el nodo con mayor `priority` se convierte en MASTER y posee la VIP; `state MASTER`/`BACKUP` solo fija el rol inicial al arranque — la elección por prioridad es lo que realmente decide la propiedad.
- **A4.2** Con preemption por defecto, cuando lb1 (priority 150) se recupera envía adverts, supera en prioridad a lb2 (100), y **recupera la VIP** — causando un segundo failover evitable (un breve parpadeo) solo porque el nodo de mayor prioridad volvió. `nopreempt` (configurado en el nodo de mayor prioridad, que debe arrancar en `state BACKUP`) le indica que *no* reclame la VIP mientras un MASTER sano ya la tiene; la VIP permanece en lb2 hasta que lb2 mismo falle. Querés esto para evitar una segunda interrupción innecesaria cada vez que un director se reinicia.
- **A4.3** Con ambos lados viendo `state MASTER` para el mismo VRID pero con los adverts de VRRP bloqueados entre ellos, cada uno cree que el par está muerto y ambos reclaman la VIP → **split brain**. Dos hosts responden por ARP por la VIP; el tráfico del cliente se entrega de forma inconsistente (IP duplicada, MAC oscilante), produciendo conectividad intermitente, conexiones reseteadas, y paquetes duplicados.
- **A4.4** `TCP_CHECK` solo abre una conexión TCP al puerto 80 y la cierra — pasa mientras el servidor web *acepte sockets*, incluso si cada request devuelve 500, sirve una página de error obsoleta, o la app detrás está en deadlock. `HTTP_GET` con `path /healthz status_code 200` efectivamente emite un request y exige un 200, así que detecta una aplicación que acepta conexiones pero ya no puede servir respuestas válidas.
- **A4.5** keepalived brindó una gestión declarativa y autorreparable: programa toda la tabla IPVS desde la configuración (sin `ipvsadm` manual), hace health check continuamente a cada real server y lo agrega/elimina automáticamente, y flota la VIP entre dos directores vía VRRP — convirtiendo la tabla estática construida a mano en un servicio HA y autorreparable.

**Checkpoint 5 — HAProxy**

- **A5.1** LVS-DR es un balanceador de *paquetes*: reenvía paquetes L3/L4 reescribiendo la MAC y nunca termina la conexión TCP, así que no puede ver ni actuar sobre L7. HAProxy **termina** la conexión TCP del cliente y abre la suya propia hacia el backend (proxy). Como termina, puede hacer trabajo de L7 — rutear por Host/path, inyectar/inspeccionar cookies y headers, hacer health checks HTTP, reintentos, terminación de TLS. El costo: cada byte fluye a través de HAProxy en ambas direcciones (está en el camino de retorno, a diferencia de DR), agregando un cuello de botella de CPU/latencia/throughput y una segunda conexión que gestionar.
- **A5.2** `insert` — HAProxy genera y agrega su propio `Set-Cookie` nombrando el servidor elegido (en lugar de aprender una cookie de la app). `indirect` — quita esa cookie de servidor del request antes de reenviarlo al backend, así que la aplicación nunca ve la cookie de contabilidad de HAProxy. `nocache` — agrega `Cache-control: private` / evita que una caché compartida almacene el `Set-Cookie` personalizado, que de otro modo fijaría a *todos* los usuarios de la caché a un solo servidor.
- **A5.3** Un `check` L4 simple solo confirma que el puerto TCP acepta una conexión; pasa incluso si la app devuelve 5xx o una página rota. `option httpchk GET /healthz` + `http-check expect status 200` emite un request HTTP real y exige un 200, detectando una aplicación que está escuchando pero no sana (en deadlock, con una dependencia caída, sirviendo errores). Misma clase de falla que Q4.4, expresada en la sintaxis de check de HAProxy.
- **A5.4** `haproxy -c -f` parsea y valida la configuración completa; un error de sintaxis o semántico detectado acá es un no-op seguro, mientras que el mismo error descubierto *durante* un reload puede dejar al proxy sin poder arrancar y cortar el servicio. El reload es «sin cortes» porque HAProxy inicia un **nuevo worker** que toma control de los sockets de escucha (vía el stats socket compartido / `expose-fd listeners` / SO_REUSEPORT), mientras el worker viejo sigue sirviendo sus conexiones establecidas hasta que se drenan — así que ninguna conexión en curso se resetea.
- **A5.5** Elegí `balance source` (hash de la IP del cliente) cuando necesitás adherencia de sesión para un protocolo/app que **no tiene cookie** y no podés insertar una (p. ej. TCP plano, o clientes que ignoran las cookies). Su modo de falla: el hash se computa sobre el conteo actual de servidores, así que agregar o quitar un servidor **rehashea una fracción grande de clientes** a servidores distintos, rompiendo la adherencia para muchas sesiones a la vez (mitigable con `hash-type consistent`).

**Checkpoint 6 — ldirectord**

- **A6.1** Con `checktype=negotiate`, ldirectord realiza un request de protocolo real: debe (1) obtener con éxito la URL de `request` (`/healthz`) — conexión + respuesta — y (2) encontrar la cadena de `receive` (`OK`) en el body devuelto. Tanto la obtención exitosa **como** la coincidencia de contenido son requeridas; un 200 con el body equivocado falla.
- **A6.2** Con `quiescent=no`, un real server caído es **eliminado** de la tabla IPVS; eliminar/re-agregar entradas puede perturbar el scheduler y descartar el estado que IPVS mantiene. Con `quiescent=yes`, el servidor caído en cambio se pone en **weight 0** — se mantiene en la tabla pero no se le asignan nuevas conexiones — así que las plantillas de persistencia existentes y el estado de conexión de los servidores *sanos* quedan intactos, y la recuperación es solo un ajuste de weight. Bajo carga, `quiescent=yes` evita el churn y preserva la adherencia para los clientes fijados a los nodos que siguen sanos.
- **A6.3** Ambos hacen health check continuamente a los real servers y programan/podan la tabla IPVS del kernel en consecuencia (`request`/`receive`/`checktype` en ldirectord ≈ `HTTP_GET`/`TCP_CHECK` dentro del bloque `virtual_server` de keepalived); keepalived adicionalmente incluye el failover de la VIP basado en VRRP, mientras que ldirectord depende de Heartbeat/Pacemaker para eso.

</details>