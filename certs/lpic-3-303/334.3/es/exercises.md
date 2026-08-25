# LPIC-3 303 — Tema 334.3: Filtrado de Paquetes
## Ejercicios Guiados (Examen 303-300, v3.0.0 — peso 8.33)

Estos ejercicios son prácticos. Cada paso está pensado para ser ejecutado, y cada comando produce
estado observable que se espera que inspecciones. El objetivo no es memorizar flags sino construir el
modelo mental que un SRE necesita a las 3 de la mañana: **qué hook se ejecutó, en qué orden, qué pensó
conntrack del paquete, y de dónde vino el veredicto.**

---

### Entorno de laboratorio

| Ítem | Requisito |
|---|---|
| Hosts | Una VM (`alpha`) con una ruta a Internet funcionando. Debian 12 (nft 1.0.6 / kernel 6.1) o RHEL 9 (nft 1.0.4 / kernel 5.14). |
| Acceso | **El acceso por consola o fuera de banda es obligatorio.** Vas a establecer `policy drop` en el hook `input`. |
| Privilegios | Todos los comandos se ejecutan como `root` (o vía `sudo`). |
| Segundo host | Opcional. Donde se necesita un par remoto, los ejercicios usan namespaces `ip netns` creados en `alpha` mismo, así que no hace falta una segunda máquina. |
| Paquetes | `nftables`, `iptables`, `conntrack`, `iproute2`, `tcpdump`, `netcat-openbsd`, más `firewalld` **o** `ufw` para el Ejercicio 9. |

> **Regla anti-bloqueo para todo el laboratorio.** Antes de cada cambio del ruleset, armá un interruptor
> de hombre muerto:
> ```bash
> systemd-run --on-active=10m --unit=fw-rollback /usr/sbin/nft flush ruleset
> ```
> Si el cambio funciona, desarmalo con `systemctl stop fw-rollback.timer`. Si no funciona, la máquina
> se vuelve a abrir en diez minutos sin necesidad de consola.

---

## Ejercicio 1 — Identificar el backend y capturar el estado actual

Las distribuciones modernas incluyen `iptables` como un **front-end de compatibilidad sobre nf_tables**.
Saber qué motor tiene realmente tus reglas es el primer paso de diagnóstico, y una pregunta frecuente de
examen.

1. Establecé las versiones del kernel y de las herramientas:

   ```bash
   uname -r
   nft --version
   iptables --version
   ip6tables --version
   ```

   Salida esperada (Debian 12):

   ```text
   6.1.0-18-amd64
   nftables v1.0.6 (Lester Gooch #5)
   iptables v1.8.9 (nf_tables)
   ip6tables v1.8.9 (nf_tables)
   ```

2. Averiguá a qué resuelve el nombre `iptables` y qué alternativas existen:

   ```bash
   ls -l /usr/sbin/iptables
   update-alternatives --display iptables 2>/dev/null | head -n 5
   ls /usr/sbin/ | grep -E 'iptables|xtables'
   ```

   Salida esperada (abreviada):

   ```text
   lrwxrwxrwx 1 root root 26 Mar  4 09:11 /usr/sbin/iptables -> /etc/alternatives/iptables
   iptables - auto mode
     link best version is /usr/sbin/iptables-nft
   iptables-legacy  iptables-nft  iptables-restore  iptables-save  xtables-monitor  xtables-nft-multi
   ```

3. Verificá qué módulos de netfilter están cargados en este momento:

   ```bash
   lsmod | grep -E '^(nf_tables|ip_tables|ip6_tables|nf_conntrack|x_tables|nft_)' 
   ```

4. Volcá ambos mundos, para saber si algo se esconde en el motor legacy:

   ```bash
   nft list ruleset
   iptables-legacy -S 2>/dev/null
   ip6tables-legacy -S 2>/dev/null
   ```

5. Tomá un snapshot restaurable antes de tocar nada:

   ```bash
   mkdir -p /root/fw-backup
   nft list ruleset            > /root/fw-backup/ruleset-$(date +%F).nft
   iptables-save               > /root/fw-backup/rules-v4-$(date +%F).iptables
   ip6tables-save              > /root/fw-backup/rules-v6-$(date +%F).ip6tables
   ls -l /root/fw-backup/
   ```

6. Convertí el snapshot de nft en un archivo que sea realmente seguro de recargar:

   ```bash
   { echo '#!/usr/sbin/nft -f'; echo 'flush ruleset'; cat /root/fw-backup/ruleset-$(date +%F).nft; } \
       > /root/fw-backup/restore.nft
   chmod 0700 /root/fw-backup/restore.nft
   nft -c -f /root/fw-backup/restore.nft && echo "syntax OK"
   ```

**Comprobá tu comprensión**

- **Q1.1** `iptables -V` imprime `(nf_tables)`. ¿Dónde terminan las reglas creadas con ese binario, y qué
  habría significado `(legacy)` en su lugar?
- **Q1.2** ¿Por qué `nft list ruleset` por sí solo es un backup incompleto en un host que corre `firewalld`?
- **Q1.3** ¿De qué te protege exactamente `flush ruleset` al principio de un archivo guardado, y por qué es
  `nft -f` sobre un archivo completo más seguro que una secuencia de comandos `nft add rule`?
- **Q1.4** Tanto `ip_tables` como `nf_tables` pueden estar cargados al mismo tiempo. ¿Qué determina el orden
  en que sus reglas ven un paquete, y por qué esa combinación se considera un riesgo operativo?
- **Q1.5** ¿Qué hace `nft -c -f archivo`, y por qué debería estar en todo procedimiento de cambio?

---

## Ejercicio 2 — Un firewall de host stateful de doble pila en la familia `inet`

La familia `inet` (kernel ≥ 3.14) permite que una sola tabla cubra IPv4 e IPv6, eliminando el clásico
incidente "endurecimos v4 y nos olvidamos de v6".

1. Escribí el ruleset. Creá `/etc/nftables.conf` con exactamente este contenido:

   ```nft
   #!/usr/sbin/nft -f
   flush ruleset

   table inet fw {
       chain inbound {
           type filter hook input priority filter; policy drop;

           iifname "lo" accept comment "loopback is trusted"

           ct state vmap { established : accept, related : accept, invalid : drop }

           meta nfproto ipv4 icmp type { echo-request, destination-unreachable, time-exceeded, parameter-problem } accept
           meta nfproto ipv6 icmpv6 type { echo-request, echo-reply, destination-unreachable, packet-too-big, time-exceeded, parameter-problem, nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit, nd-router-advert, mld-listener-query } accept

           tcp dport 22 ct state new accept comment "SSH"

           counter comment "unmatched inbound"
           limit rate 5/minute burst 5 packets log prefix "fw-input-drop " level info flags all
       }

       chain forward {
           type filter hook forward priority filter; policy drop;
       }

       chain outbound {
           type filter hook output priority filter; policy accept;
       }
   }
   ```

2. Validá, armá el rollback y cargá atómicamente:

   ```bash
   nft -c -f /etc/nftables.conf && echo "syntax OK"
   systemd-run --on-active=10m --unit=fw-rollback /usr/sbin/nft flush ruleset
   nft -f /etc/nftables.conf
   ```

3. Inspeccioná lo que el kernel realmente tiene, con handles:

   ```bash
   nft -a list table inet fw
   ```

   Salida esperada (abreviada):

   ```text
   table inet fw { # handle 12
   	chain inbound { # handle 1
   		type filter hook input priority filter; policy drop;
   		iifname "lo" accept comment "loopback is trusted" # handle 4
   		ct state vmap { established : accept, invalid : drop, related : accept } # handle 5
   		meta nfproto ipv4 icmp type { echo-request, destination-unreachable, time-exceeded, parameter-problem } accept # handle 6
   		...
   		tcp dport 22 ct state new accept comment "SSH" # handle 8
   		counter packets 0 bytes 0 comment "unmatched inbound" # handle 9
   		limit rate 5/minute burst 5 packets log prefix "fw-input-drop " level info flags all # handle 10
   	}
   ```

4. Generá tráfico que deba ser descartado y observá cómo se acumula la evidencia:

   ```bash
   nc -vz -w2 127.0.0.1 22          # allowed via loopback
   ss -lntp | head
   # from another terminal / host, hit a closed port:
   nc -vz -w2 <alpha-ip> 8080
   nft list chain inet fw inbound | grep counter
   journalctl -k -n 20 --grep 'fw-input-drop'
   ```

   Línea de log del kernel esperada:

   ```text
   kernel: fw-input-drop IN=eth0 OUT= MAC=... SRC=192.0.2.10 DST=198.51.100.5 LEN=60 TOS=0x00 PREC=0x00 TTL=63 ID=... PROTO=TCP SPT=51234 DPT=8080 WINDOW=64240 RES=0x00 SYN URGP=0
   ```

5. Agregá y después quitá una regla en tiempo de ejecución, usando handles en lugar de números de línea:

   ```bash
   nft add rule inet fw inbound tcp dport 443 ct state new counter accept
   nft -a list chain inet fw inbound | grep 443
   nft delete rule inet fw inbound handle <handle-from-above>
   ```

6. Insertá una regla *antes* de la regla de SSH en lugar de agregarla al final:

   ```bash
   nft insert rule inet fw inbound position <handle-of-ssh-rule> \
       ip saddr 203.0.113.0/24 tcp dport 22 counter drop comment "blocked net"
   nft -a list chain inet fw inbound
   ```

7. Desarmá el rollback una vez que hayas confirmado que tu sesión SSH sigue funcionando:

   ```bash
   systemctl stop fw-rollback.timer
   systemctl enable --now nftables.service
   ```

**Comprobá tu comprensión**

- **Q2.1** La cadena tiene `policy drop` *y* un par final `counter`/`log`, pero ninguna regla `drop` explícita
  al final. ¿Por qué funciona eso, y cuál es la ventaja sobre terminar con `log ... drop`?
- **Q2.2** ¿Cuál es la diferencia entre `iif "lo"` e `iifname "lo"`, y cuál se rompe cuando una interfaz se
  elimina y se vuelve a crear (un contenedor o un túnel VPN, por ejemplo)?
- **Q2.3** Otro administrador agrega una segunda cadena base en el mismo hook con
  `type filter hook input priority 10; policy accept;`. Tu cadena ya emitió `accept` para un paquete.
  ¿Se sigue evaluando la segunda cadena? ¿Y si tu cadena hubiera emitido `drop`?
- **Q2.4** ¿Por qué descartar `ct state invalid` explícitamente en lugar de dejar que caiga hasta la policy?
- **Q2.5** La regla `limit rate 5/minute burst 5 packets log prefix ...` coloca el limitador *antes* de la
  sentencia de log. ¿Qué cambiaría si se intercambiaran las dos?
- **Q2.6** ¿Por qué `ct state vmap { ... }` escala mejor que tres reglas `ct state ... accept` separadas?

---

## Ejercicio 3 — Sets nombrados, verdict maps y una blocklist que se autopobla

Los sets son búsquedas hash o de intervalos realizadas una sola vez, en lugar de N reglas evaluadas
linealmente. También son la única forma de actualizar una blocklist **sin recargar el ruleset**.

1. Declará un set de intervalos estático y un verdict map de servicios. Agregá dentro de `table inet fw` en
   `/etc/nftables.conf`:

   ```nft
       set badnets {
           type ipv4_addr
           flags interval
           comment "manually curated blocklist"
           elements = { 203.0.113.0/24, 198.51.100.64/26 }
       }

       set ssh_flood {
           type ipv4_addr
           size 65535
           flags dynamic, timeout
           timeout 1h
       }

       map svcmap {
           type inet_service : verdict
           elements = { 22 : accept, 80 : accept, 443 : accept }
       }
   ```

2. Recableá la cadena `inbound` para que los use. Reemplazá el bloque de la regla SSH con:

   ```nft
           ip saddr @badnets counter drop comment "static blocklist"
           ip saddr @ssh_flood counter drop comment "dynamic blocklist"

           tcp dport 22 ct state new \
               add @ssh_flood { ip saddr timeout 1h limit rate over 6/minute burst 6 packets } \
               log prefix "fw-ssh-brute " drop

           ct state new tcp dport vmap @svcmap
   ```

3. Recargá y verificá:

   ```bash
   nft -c -f /etc/nftables.conf && nft -f /etc/nftables.conf
   nft list set inet fw badnets
   nft list map inet fw svcmap
   ```

   Salida esperada:

   ```text
   table inet fw {
   	set badnets {
   		type ipv4_addr
   		flags interval
   		comment "manually curated blocklist"
   		elements = { 198.51.100.64/26, 203.0.113.0/24 }
   	}
   }
   table inet fw {
   	map svcmap {
   		type inet_service : verdict
   		elements = { 22 : accept, 80 : accept, 443 : accept }
   	}
   }
   ```

4. Actualizá los sets en tiempo de ejecución — sin recarga, sin pérdida de paquetes:

   ```bash
   nft add element inet fw badnets { 192.0.2.0/25 }
   nft add element inet fw svcmap { 8443 : accept }
   nft list set inet fw badnets
   nft delete element inet fw badnets { 192.0.2.0/25 }
   ```

5. Dispará el limitador de fuerza bruta desde otro host o namespace y observá cómo se llena el set dinámico:

   ```bash
   for i in $(seq 1 12); do nc -z -w1 <alpha-ip> 22; done
   nft list set inet fw ssh_flood
   ```

   Salida esperada:

   ```text
   table inet fw {
   	set ssh_flood {
   		type ipv4_addr
   		size 65535
   		flags dynamic,timeout
   		timeout 1h
   		elements = { 192.0.2.10 expires 59m54s264ms }
   	}
   }
   ```

6. Liberá al infractor manualmente y confirmá:

   ```bash
   nft delete element inet fw ssh_flood { 192.0.2.10 }
   nft list set inet fw ssh_flood
   ```

**Comprobá tu comprensión**

- **Q3.1** ¿Por qué `flags interval` es obligatorio para almacenar `203.0.113.0/24`, y qué usa el kernel
  internamente para los sets de intervalos que no usa para los sets simples?
- **Q3.2** ¿Cuál es la diferencia práctica entre `add @set { ... }` y `update @set { ... }` en una regla?
- **Q3.3** Tenés 4.000 prefijos bloqueados. Compará "4.000 reglas" contra "una regla más un set de 4.000
  elementos" en dos ejes: costo por paquete y costo de actualización.
- **Q3.4** Reiniciás el host y recargás `/etc/nftables.conf`. ¿Qué pasa con los elementos que se habían
  agregado a `ssh_flood` en tiempo de ejecución, y cómo los preservarías a través de una recarga?
- **Q3.5** En el paso 2, la regla de drop para `@ssh_flood` está colocada *arriba* de la regla que agrega a
  ese set. ¿Por qué importa el orden?
- **Q3.6** ¿Cuál es la diferencia entre un `set` de tipo `inet_service` y un `map` de tipo
  `inet_service : verdict`?

---

## Ejercicio 4 — Connection tracking: la máquina de estados detrás de `ct state`

`ct state established` no es magia: es una búsqueda en una tabla hash del kernel que es finita, ajustable y
capaz de llenarse. Esta es la causa individual más común de "el firewall descarta tráfico al azar".

1. Confirmá que conntrack está cargado y mirá el dimensionamiento:

   ```bash
   lsmod | grep nf_conntrack
   sysctl net.netfilter.nf_conntrack_count net.netfilter.nf_conntrack_max
   sysctl net.netfilter.nf_conntrack_buckets
   cat /sys/module/nf_conntrack/parameters/hashsize
   ```

   Salida esperada:

   ```text
   net.netfilter.nf_conntrack_count = 137
   net.netfilter.nf_conntrack_max = 262144
   net.netfilter.nf_conntrack_buckets = 65536
   65536
   ```

2. Leé la tabla de dos formas distintas:

   ```bash
   head -n 3 /proc/net/nf_conntrack
   conntrack -L -p tcp --dport 22
   conntrack -S | head -n 2
   ```

   Salida esperada:

   ```text
   ipv4     2 tcp      6 431997 ESTABLISHED src=192.0.2.10 dst=198.51.100.5 sport=51234 dport=22 src=198.51.100.5 dst=192.0.2.10 sport=22 dport=51234 [ASSURED] mark=0 use=1
   tcp      6 431997 ESTABLISHED src=192.0.2.10 dst=198.51.100.5 sport=51234 dport=22 src=198.51.100.5 dst=192.0.2.10 sport=22 dport=51234 [ASSURED] mark=0 use=1
   conntrack v1.4.7 (conntrack-tools): 1 flow entries have been shown.
   cpu=0   found=0 invalid=12 insert=0 insert_failed=0 drop=0 early_drop=0 error=0 search_restart=41
   ```

3. Observá la máquina de estados en vivo. En una terminal:

   ```bash
   conntrack -E -e NEW,UPDATE,DESTROY -p tcp
   ```

   En otra, abrí y cerrá una conexión:

   ```bash
   curl -s -o /dev/null http://example.com/
   ```

   Flujo de eventos esperado (abreviado):

   ```text
   [NEW] tcp      6 120 SYN_SENT src=198.51.100.5 dst=93.184.216.34 sport=44112 dport=80 [UNREPLIED] ...
   [UPDATE] tcp   6 60 SYN_RECV src=198.51.100.5 dst=93.184.216.34 sport=44112 dport=80 ...
   [UPDATE] tcp   6 432000 ESTABLISHED src=... [ASSURED] ...
   [UPDATE] tcp   6 120 FIN_WAIT src=... 
   [UPDATE] tcp   6 30 LAST_ACK src=...
   [DESTROY] tcp  6 src=198.51.100.5 dst=93.184.216.34 sport=44112 dport=80 ...
   ```

4. Probá que es el estado, y no la regla del puerto 22, lo que mantiene viva tu sesión SSH. **Hacé esto solo
   con acceso a consola.** Borrá tu propio flujo SSH de la tabla:

   ```bash
   conntrack -D -p tcp --dport 22 --src <your-client-ip>
   ```

   Resultado esperado: la sesión SSH se congela. El siguiente paquete de datos del cliente ya no es
   `established`; no es un `SYN`, así que se vuelve `invalid` y cae en tu `invalid : drop`.

5. Inspeccioná y ajustá los timeouts que deciden cuánto sobrevive un flujo inactivo:

   ```bash
   sysctl net.netfilter | grep -E 'timeout_established|udp_timeout|icmp_timeout|tcp_loose'
   ```

   Salida esperada:

   ```text
   net.netfilter.nf_conntrack_icmp_timeout = 30
   net.netfilter.nf_conntrack_tcp_loose = 1
   net.netfilter.nf_conntrack_tcp_timeout_established = 432000
   net.netfilter.nf_conntrack_udp_timeout = 30
   net.netfilter.nf_conntrack_udp_timeout_stream = 120
   ```

   Aplicá un valor sensato para producción de forma persistente:

   ```bash
   cat > /etc/sysctl.d/90-conntrack.conf <<'EOF'
   net.netfilter.nf_conntrack_max = 524288
   net.netfilter.nf_conntrack_tcp_timeout_established = 86400
   EOF
   sysctl --system | grep conntrack
   ```

6. Eximí completamente del tracking al tráfico stateless de alto volumen, usando una cadena `raw`:

   ```bash
   nft add table inet raw
   nft add chain inet raw prerouting '{ type filter hook prerouting priority raw; }'
   nft add chain inet raw output '{ type filter hook output priority raw; }'
   nft add rule inet raw prerouting udp dport 53 notrack
   nft add rule inet raw output udp sport 53 notrack
   nft list table inet raw
   ```

7. Asigná un helper de connection tracking explícitamente (la asignación automática está desactivada por
   defecto desde Linux 4.7):

   ```bash
   modprobe nf_conntrack_ftp
   sysctl net.netfilter.nf_conntrack_helper
   nft -f - <<'EOF'
   table inet helpers {
       ct helper ftp-standard {
           type "ftp" protocol tcp
       }
       chain prerouting {
           type filter hook prerouting priority filter;
           tcp dport 21 ct helper set "ftp-standard"
       }
   }
   EOF
   nft list table inet helpers
   ```

**Comprobá tu comprensión**

- **Q4.1** ¿En qué prioridad de hook corre el connection tracking, y por qué una regla `notrack` debe vivir en
  una cadena con `priority raw` en lugar de `priority filter`?
- **Q4.2** Explicá con precisión por qué `conntrack -D` congeló una sesión SSH en un firewall con
  `policy drop`, y qué tendría que hacer el cliente para recuperarse.
- **Q4.3** `dmesg` muestra `nf_conntrack: table full, dropping packet`. Dá tres remedios distintos e indicá
  cuál aplicarías primero en un gateway NAT ocupado, y por qué.
- **Q4.4** ¿Cuál es la diferencia en contenido y en requisitos entre `/proc/net/nf_conntrack` y
  `conntrack -L`?
- **Q4.5** ¿Por qué se desactivó por defecto la asignación automática de helpers de conntrack en Linux 4.7, y
  cuáles son las dos cosas que ahora tenés que hacer para que el FTP en modo activo funcione a través del
  firewall?
- **Q4.6** ¿Qué significa el flag `[ASSURED]`, y cómo interactúa con `early_drop` cuando la tabla se acerca a
  `nf_conntrack_max`?
- **Q4.7** `ct state related` acepta un paquete que no pertenece a ninguna tupla de flujo existente. Dá dos
  ejemplos concretos de paquetes que legítimamente coinciden con `related`.

---

## Ejercicio 5 — Ruteo, NAT y un camino de forward filtrado

Este ejercicio construye un router real sin una segunda VM, usando un network namespace como la "LAN".

1. Construí la topología:

   ```bash
   ip netns add lan
   ip link add veth-fw type veth peer name veth-lan
   ip link set veth-lan netns lan
   ip addr add 10.10.0.1/24 dev veth-fw
   ip link set veth-fw up

   ip netns exec lan ip link set lo up
   ip netns exec lan ip addr add 10.10.0.2/24 dev veth-lan
   ip netns exec lan ip link set veth-lan up
   ip netns exec lan ip route add default via 10.10.0.1

   ip netns exec lan ip route show
   ```

   Salida esperada:

   ```text
   default via 10.10.0.1 dev veth-lan 
   10.10.0.0/24 dev veth-lan proto kernel scope link src 10.10.0.2 
   ```

2. Confirmá que el forwarding está desactivado, y que la LAN todavía no puede alcanzar nada:

   ```bash
   sysctl net.ipv4.ip_forward
   ip netns exec lan ping -c1 -W2 1.1.1.1 ; echo "exit=$?"
   ```

3. Habilitá el forwarding — notá que es una configuración por namespace:

   ```bash
   sysctl -w net.ipv4.ip_forward=1
   echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/91-forward.conf
   ```

4. Agregá source NAT y un camino de forward filtrado. Extendé `/etc/nftables.conf`:

   ```nft
   table inet nat {
       chain prerouting {
           type nat hook prerouting priority dstnat; policy accept;
       }
       chain postrouting {
           type nat hook postrouting priority srcnat; policy accept;
           ip saddr 10.10.0.0/24 oifname "eth0" masquerade
       }
   }
   ```

   Y reemplazá la cadena `forward` en `table inet fw`:

   ```nft
       chain forward {
           type filter hook forward priority filter; policy drop;

           ct state vmap { established : accept, related : accept, invalid : drop }
           iifname "veth-fw" oifname "eth0" ct state new accept comment "LAN egress"
           counter log prefix "fw-forward-drop " level info
       }
   ```

   ```bash
   nft -c -f /etc/nftables.conf && nft -f /etc/nftables.conf
   ip netns exec lan ping -c2 1.1.1.1
   ```

5. Observá la traducción en la tabla de conntrack — las dos tuplas difieren:

   ```bash
   conntrack -L -s 10.10.0.2
   ```

   Salida esperada:

   ```text
   icmp     1 29 src=10.10.0.2 dst=1.1.1.1 type=8 code=0 id=12 src=1.1.1.1 dst=198.51.100.5 type=0 code=0 id=12 mark=0 use=1
   ```

6. Agregá destination NAT (un servicio publicado) y probá que la cadena de filtro ve la dirección
   *posterior* al DNAT. Arrancá un listener dentro del namespace LAN:

   ```bash
   ip netns exec lan nc -l -k -p 8080 &
   nft add rule inet nat prerouting iifname "eth0" tcp dport 80 dnat ip to 10.10.0.2:8080
   nft add rule inet fw forward iifname "eth0" oifname "veth-fw" ip daddr 10.10.0.2 tcp dport 8080 ct state new accept
   nft list table inet nat
   ```

7. Hacé match sobre el hecho de que un flujo fue traducido, en lugar de repetir las direcciones:

   ```bash
   nft add rule inet fw forward ct status dnat counter comment "published services"
   nft -a list chain inet fw forward | grep dnat
   ```

8. Limpiá la topología del laboratorio cuando termines:

   ```bash
   ip netns del lan
   ip link del veth-fw 2>/dev/null
   ```

**Comprobá tu comprensión**

- **Q5.1** ¿En qué orden ven un paquete las cadenas `nat prerouting` (prioridad `dstnat` = -100) y
  `filter forward` (prioridad `filter` = 0), y qué implica eso para la dirección que tenés que escribir
  en la regla de forward del paso 6?
- **Q5.2** Una cadena base `nat` solo ve el *primer* paquete de cada flujo. ¿Qué subsistema traduce el resto,
  y qué consecuencia práctica tiene esto si agregás una regla de NAT mientras ya hay flujos corriendo?
- **Q5.3** Compará `masquerade` con `snat to 198.51.100.5`: costo, corrección en un uplink DHCP/PPPoE, y qué
  pasa con las entradas de conntrack existentes cuando la interfaz WAN se cae.
- **Q5.4** `net.ipv4.ip_forward` se estableció en el host, no en el namespace `lan`. ¿Por qué es ese el lugar
  correcto, y qué habría pasado si lo hubieras establecido dentro del namespace?
- **Q5.5** Definí, con el vocabulario que usa el examen: *screened subnet (DMZ)*, *bastion host*, *dual-homed
  firewall* y *egress filtering*. ¿Qué cadena haría cumplir cada uno de los tres primeros en este host?
- **Q5.6** ¿Por qué NAT no es un control de seguridad, aunque oculte las direcciones internas?

---

## Ejercicio 6 — `iptables`/`ip6tables`: interoperabilidad, save/restore y migración

Los rulesets legacy están en todas partes. Tenés que ser capaz de leerlos, persistirlos y traducirlos.

1. Creá reglas con el front-end `iptables`, después miralas a través de `nft`:

   ```bash
   iptables -N HARDENED
   iptables -A HARDENED -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
   iptables -A HARDENED -p tcp -m multiport --dports 80,443 -m conntrack --ctstate NEW -j ACCEPT
   iptables -A HARDENED -m limit --limit 3/min -j LOG --log-prefix "legacy-drop "
   iptables -A HARDENED -j REJECT --reject-with icmp-port-unreachable
   iptables -A INPUT -i eth0 -j HARDENED

   iptables -S HARDENED
   nft list table ip filter | head -n 20
   ```

   Salida esperada (abreviada):

   ```text
   -N HARDENED
   -A HARDENED -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
   -A HARDENED -p tcp -m multiport --dports 80,443 -m conntrack --ctstate NEW -j ACCEPT
   ...
   table ip filter {
   	chain HARDENED {
   		ct state related,established counter packets 0 bytes 0 accept
   		meta l4proto tcp tcp dport { 80,443 } ct state new counter packets 0 bytes 0 accept
   		...
   ```

2. Guardá con contadores e inspeccioná el formato en disco:

   ```bash
   iptables-save -c > /root/fw-backup/rules.v4
   head -n 12 /root/fw-backup/rules.v4
   ```

   Salida esperada:

   ```text
   # Generated by iptables-save v1.8.9 on Tue Aug 25 11:02:41 2026
   *filter
   :INPUT ACCEPT [1204:98123]
   :FORWARD DROP [0:0]
   :OUTPUT ACCEPT [980:120441]
   :HARDENED - [0:0]
   [12:720] -A INPUT -i eth0 -j HARDENED
   [8:480] -A HARDENED -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
   ...
   COMMIT
   # Completed on Tue Aug 25 11:02:41 2026
   ```

3. Restaurá de dos maneras y notá la diferencia:

   ```bash
   iptables-restore   < /root/fw-backup/rules.v4    # replaces the listed tables
   iptables-restore -n < /root/fw-backup/rules.v4   # --noflush: appends instead
   iptables -S INPUT | wc -l                        # run before and after the -n variant
   ```

4. Traducí reglas individuales y archivos completos:

   ```bash
   iptables-translate -A INPUT -i eth0 -p tcp --dport 22 -m conntrack --ctstate NEW -j ACCEPT
   ip6tables-translate -A INPUT -p ipv6-icmp --icmpv6-type echo-request -j ACCEPT
   iptables-restore-translate -f /root/fw-backup/rules.v4 > /root/fw-backup/translated.nft
   head -n 15 /root/fw-backup/translated.nft
   ```

   Salida esperada:

   ```text
   nft 'add rule ip filter INPUT iifname "eth0" tcp dport 22 ct state new counter accept'
   nft 'add rule ip6 filter INPUT icmpv6 type echo-request counter accept'
   ```

5. Confirmá que IPv4 e IPv6 están genuinamente separados bajo `iptables`:

   ```bash
   ip6tables -S INPUT
   ip6tables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -j ACCEPT
   ip6tables-save > /root/fw-backup/rules.v6
   ```

6. Hacé que sobreviva a un reinicio, a la manera de la distribución:

   ```bash
   # Debian/Ubuntu
   apt-get install -y iptables-persistent      # writes /etc/iptables/rules.v4 and rules.v6
   netfilter-persistent save
   systemctl is-enabled netfilter-persistent

   # RHEL family
   # dnf install -y iptables-services && systemctl enable --now iptables ip6tables
   ```

7. Limpiá antes de continuar:

   ```bash
   iptables -F; iptables -X; iptables -P INPUT ACCEPT
   ip6tables -F; ip6tables -X
   ```

**Comprobá tu comprensión**

- **Q6.1** En la salida de `iptables-save`, ¿qué significan `*filter`, `:INPUT ACCEPT [1204:98123]` y `COMMIT`?
- **Q6.2** ¿Por qué se describe a `iptables-restore` como atómico, y qué cambia `-n`/`--noflush` respecto de
  esa garantía?
- **Q6.3** Traducí a mano:
  `iptables -t nat -A POSTROUTING -s 10.0.0.0/8 ! -o lo -j MASQUERADE`
- **Q6.4** ¿Cuál es la diferencia entre `-m state --state` y `-m conntrack --ctstate`, y cuál deberían usar las
  reglas nuevas?
- **Q6.5** Creaste la cadena `HARDENED` con `iptables-nft`, y ahora aparece en `nft list ruleset`.
  ¿Por qué de todos modos no debés editarla con `nft`?
- **Q6.6** ¿Cuál es la diferencia entre `-j DROP` y `-j REJECT --reject-with icmp-port-unreachable`
  desde el punto de vista del cliente, y cuándo es apropiado cada uno?
- **Q6.7** `iptables -X HARDENED` falla con "Too many links". ¿Qué significa eso?

---

## Ejercicio 7 — IPv6: lo que nunca debés filtrar

IPv6 no tiene ARP ni fragmentación en el camino. ICMPv6 no es opcional; es estructural.

1. Verificá que el neighbour discovery funciona antes de romperlo:

   ```bash
   ip -6 neigh show
   ip -6 addr show scope link
   ping -6 -c2 ff02::1%eth0 | head -n 5
   ```

2. Rompelo deliberadamente. Agregá una regla *arriba* de la regla de aceptación de ICMPv6:

   ```bash
   systemd-run --on-active=5m --unit=fw-rollback /usr/sbin/nft flush ruleset
   nft insert rule inet fw inbound meta nfproto ipv6 meta l4proto icmpv6 counter drop
   ip -6 neigh flush all
   ping -6 -c3 -W2 <link-local-peer>%eth0 ; echo "exit=$?"
   ip -6 neigh show
   ```

   Resultado esperado: las entradas de vecinos quedan en `INCOMPLETE` o `FAILED`; la conectividad IPv6 al
   host muere aunque ninguna regla TCP haya cambiado.

3. Quitá la regla y confirmá la recuperación:

   ```bash
   nft -a list chain inet fw inbound | grep icmpv6
   nft delete rule inet fw inbound handle <handle>
   systemctl stop fw-rollback.timer
   ip -6 neigh show
   ```

4. Demostrá la dependencia de PMTUD con un camino de MTU más chica (verificación conceptual en el enlace del
   laboratorio):

   ```bash
   ip link set dev veth-fw mtu 1400
   ping -6 -c1 -M do -s 1452 <peer-v6>       # expect "Packet too big" feedback
   ```

5. Escribí la política ICMPv6 mínima correcta, siguiendo la lista de "no debe ser descartado" de la RFC 4890:

   ```nft
           meta nfproto ipv6 icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem } accept
           meta nfproto ipv6 icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert } ip6 hoplimit 255 accept
           meta nfproto ipv6 icmpv6 type { nd-router-solicit, nd-router-advert } ip6 hoplimit 255 accept
           meta nfproto ipv6 icmpv6 type { mld-listener-query, mld-listener-report, mld-listener-done } ip6 saddr fe80::/10 accept
           meta nfproto ipv6 icmpv6 type echo-request limit rate 10/second accept
           meta nfproto ipv6 udp sport 547 udp dport 546 ip6 saddr fe80::/10 accept comment "DHCPv6 replies"
   ```

6. Confirmá la dependencia implícita de familia dentro de una tabla `inet`:

   ```bash
   nft add rule inet fw inbound ip saddr 10.0.0.0/8 counter accept
   nft -a list chain inet fw inbound | grep '10.0.0.0/8'
   ```

   La salida esperada muestra que nft insertó el test de familia por vos:

   ```text
   		ip saddr 10.0.0.0/8 counter packets 0 bytes 0 accept # handle 31
   ```

**Comprobá tu comprensión**

- **Q7.1** Nombrá cuatro tipos ICMPv6 que nunca deben descartarse en una política inbound, e indicá qué se
  rompe en cada caso.
- **Q7.2** ¿Qué modo de falla específico aparece cuando se filtra `packet-too-big`, y por qué se reporta
  habitualmente como "las páginas chicas cargan, las descargas grandes se cuelgan"?
- **Q7.3** ¿Por qué las reglas de NDP del paso 5 incluyen `ip6 hoplimit 255`?
- **Q7.4** En una tabla `inet`, ¿por qué `ip saddr 10.0.0.0/8 accept` no acepta accidentalmente tráfico IPv6?
- **Q7.5** Tu host usa SLAAC. ¿Qué dos tipos ICMPv6 deben aceptarse para que el direccionamiento funcione
  siquiera, y cuál es el compromiso de seguridad de aceptar `nd-router-advert` desde cualquier origen
  link-local?

---

## Ejercicio 8 — Tracing: probar qué regla tomó la decisión

Los contadores te dicen *cuántos*. El tracing te dice *qué regla, en qué cadena, en qué orden*.

1. Creá una tabla de trace dedicada, enganchada antes que todo lo demás:

   ```bash
   nft add table inet trace
   nft add chain inet trace prerouting '{ type filter hook prerouting priority -301; }'
   nft add chain inet trace output     '{ type filter hook output     priority -301; }'
   nft add rule inet trace prerouting ip saddr 192.0.2.10 meta nftrace set 1
   nft add rule inet trace output     ip daddr 192.0.2.10 meta nftrace set 1
   ```

2. Observá al paquete recorrer el ruleset:

   ```bash
   nft monitor trace
   ```

   Desde el origen trazado, pegale a un puerto que esté siendo descartado. Salida esperada (abreviada):

   ```text
   trace id 7a3c1f04 inet trace prerouting packet: iif "eth0" ether saddr aa:bb:cc:dd:ee:01 ip saddr 192.0.2.10 ip daddr 198.51.100.5 ip protocol tcp tcp sport 51422 tcp dport 8080 tcp flags == syn
   trace id 7a3c1f04 inet trace prerouting rule ip saddr 192.0.2.10 meta nftrace set 1 (verdict continue)
   trace id 7a3c1f04 inet fw inbound rule ct state vmap { established : accept, invalid : drop, related : accept } (verdict continue)
   trace id 7a3c1f04 inet fw inbound rule counter packets 41 bytes 2460 comment "unmatched inbound" (verdict continue)
   trace id 7a3c1f04 inet fw inbound verdict continue
   trace id 7a3c1f04 inet fw inbound policy drop
   ```

3. Leé los contadores como una segunda señal, más barata:

   ```bash
   nft list chain inet fw inbound | grep -n counter
   nft reset counters table inet fw
   nft list chain inet fw inbound | grep -n counter
   ```

4. Diferenciá dos rulesets sin el ruido de los contadores:

   ```bash
   nft -s list ruleset > /tmp/before.nft
   nft add rule inet fw inbound tcp dport 9090 accept
   nft -s list ruleset > /tmp/after.nft
   diff -u /tmp/before.nft /tmp/after.nft
   ```

5. Hacé lo mismo con el front-end legacy, para comparar:

   ```bash
   iptables -t raw -A PREROUTING -p tcp --dport 8080 -j TRACE
   xtables-monitor --trace &
   # generate traffic, then:
   iptables -t raw -D PREROUTING -p tcp --dport 8080 -j TRACE
   ```

6. Quitá siempre el tracing cuando termines — es caro bajo carga:

   ```bash
   nft delete table inet trace
   nft list ruleset | grep -c nftrace
   ```

7. Agregá la salida JSON a tu caja de herramientas para chequeos automatizados:

   ```bash
   nft -j list ruleset | head -c 400
   nft -j list ruleset | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["nftables"]))'
   ```

**Comprobá tu comprensión**

- **Q8.1** ¿Por qué se le da a la cadena de trace la prioridad `-301` en lugar de `0`?
- **Q8.2** El trace termina en `verdict continue` seguido de `policy drop`. ¿Qué te dice eso sobre tu ruleset,
  y qué es lo próximo que verificarías?
- **Q8.3** ¿Se trazan todos los paquetes de un flujo, o solo algunos? Explicá en términos de dónde se evalúa
  `meta nftrace set 1`.
- **Q8.4** ¿Cuándo es preferible `nft -s list ruleset` a `nft list ruleset`, y qué hace `nft reset
  counters` que `-s` no hace?
- **Q8.5** ¿Por qué nunca hay que dejar `nftrace` habilitado en un firewall de producción?
- **Q8.6** El contador de una regla se está incrementando pero el servicio sigue inalcanzable. Nombrá dos
  causas que *no* sean el firewall.

---

## Ejercicio 9 — Front-ends y herramientas adyacentes: firewalld, ufw, ebtables, conntrackd

El examen espera que las conozcas, y producción espera que no pelees con ellas.

1. **firewalld** (familia RHEL). Inspeccioná el modelo:

   ```bash
   systemctl is-active firewalld
   firewall-cmd --state
   firewall-cmd --get-default-zone
   firewall-cmd --get-active-zones
   firewall-cmd --zone=public --list-all
   grep -E '^FirewallBackend' /etc/firewalld/firewalld.conf
   ```

   Salida esperada:

   ```text
   running
   public
   public
     interfaces: eth0
   public (active)
     target: default
     services: dhcpv6-client ssh
     ports: 
     ...
   FirewallBackend=nftables
   ```

2. Mostrá la separación runtime/permanent — la trampa operativa número uno de firewalld:

   ```bash
   firewall-cmd --zone=public --add-service=https
   firewall-cmd --zone=public --list-services
   firewall-cmd --reload
   firewall-cmd --zone=public --list-services      # https is gone
   firewall-cmd --permanent --zone=public --add-service=https
   firewall-cmd --reload
   firewall-cmd --zone=public --list-services      # https persists
   ```

3. Mirá lo que firewalld realmente programa en el kernel:

   ```bash
   nft list tables
   nft list chain inet firewalld filter_INPUT
   ```

   Salida esperada:

   ```text
   table inet firewalld
   table ip firewalld
   table ip6 firewalld
   ```

4. Usá una rich rule y un port forward, después promové el runtime a permanent:

   ```bash
   firewall-cmd --zone=public --add-rich-rule='rule family="ipv4" source address="192.0.2.0/24" service name="ssh" log prefix="rich-ssh " level="info" limit value="3/m" accept'
   firewall-cmd --zone=public --add-forward-port=port=8080:proto=tcp:toport=80:toaddr=10.10.0.2
   firewall-cmd --runtime-to-permanent
   firewall-cmd --permanent --zone=public --list-rich-rules
   ```

5. **ufw** (Debian/Ubuntu). Solo en un host donde firewalld *no* esté corriendo:

   ```bash
   ufw status verbose
   ufw default deny incoming
   ufw default allow outgoing
   ufw allow from 192.0.2.0/24 to any port 22 proto tcp comment 'admin net'
   ufw limit 22/tcp
   ufw logging medium
   ufw enable
   ufw status numbered
   ```

   Salida esperada:

   ```text
   Status: active
        To                         Action      From
        --                         ------      ----
   [ 1] 22/tcp                     ALLOW IN    192.0.2.0/24               # admin net
   [ 2] 22/tcp                     LIMIT IN    Anywhere
   ```

   ```bash
   ufw delete 2
   grep -n 'ufw-before-input' /etc/ufw/before.rules | head -n 3
   ```

6. **ebtables / familia bridge** — filtrado en capa 2:

   ```bash
   ip link add br0 type bridge && ip link set br0 up
   ebtables -t filter -L 2>/dev/null || echo "ebtables not installed"
   sysctl net.bridge.bridge-nf-call-iptables 2>/dev/null
   nft add table bridge fw
   nft add chain bridge fw forward '{ type filter hook forward priority filter; policy accept; }'
   nft add rule bridge fw forward ether type arp arp operation reply arp saddr ip 10.10.0.2 accept
   nft list table bridge fw
   ip link del br0
   ```

7. **conntrackd** — sincronización de estado para un par de firewalls (solo inspección):

   ```bash
   ls /etc/conntrackd/conntrackd.conf 2>/dev/null && grep -E '^\s*(Mode|IPv4_address|Interface)' /etc/conntrackd/conntrackd.conf
   conntrackd -s 2>/dev/null | head -n 10 || echo "conntrackd not running"
   ```

**Comprobá tu comprensión**

- **Q9.1** En el paso 2, `https` desapareció después de `--reload`. Explicá el modelo runtime/permanent y dá
  las dos formas de hacer durable un cambio de runtime.
- **Q9.2** firewalld es dueño de `inet firewalld`. ¿Qué pasa con las reglas escritas a mano que agregues a esa
  tabla, y dónde deberían ir tus propias reglas en cambio?
- **Q9.3** ¿Qué hace cumplir realmente `ufw limit 22/tcp`, y cuál es su equivalente nativo en nftables?
- **Q9.4** Dá un escenario que `ebtables`/la familia `bridge` de nftables pueda resolver pero `iptables`/la
  familia `ip` no. ¿Qué cambia `net.bridge.bridge-nf-call-iptables=1` respecto de esa frontera?
- **Q9.5** Dos firewalls corren VRRP con `keepalived`. Sin `conntrackd`, ¿qué pasa exactamente con las
  sesiones TCP establecidas en un failover, y por qué?
- **Q9.6** ¿Por qué firewalld y ufw nunca deberían estar ambos habilitados en el mismo host?
- **Q9.7** ¿Qué hace `firewall-cmd --panic-on`, y cuándo lo usarías?

---

## Respuestas

<details>
<summary><strong>Hacé clic para revelar todas las respuestas</strong></summary>

### Ejercicio 1

**A1.1** `(nf_tables)` significa que el binario es `xtables-nft-multi`: habla la sintaxis de iptables pero
escribe las reglas en el subsistema del kernel **nf_tables**, en tablas llamadas `ip filter`, `ip nat`, etc.,
marcadas con un flag de compatibilidad. `(legacy)` habría significado `xtables-multi`, escribiendo en el
subsistema más viejo `ip_tables`/`x_tables`, que es un camino del kernel completamente separado con sus
propios registros de hooks. Misma sintaxis, distinto almacenamiento — por eso `nft list ruleset` muestra el
primero y no el segundo.

**A1.2** `nft list ruleset` captura únicamente el ruleset de *runtime* de firewalld. firewalld regenera ese
ruleset a partir de su propia configuración XML (`/etc/firewalld/`, `/usr/lib/firewalld/`) en cada `--reload`
y al arrancar el servicio, así que restaurar el volcado de nft te da reglas que serán sobrescritas
silenciosamente. Un backup completo de un host con firewalld es `/etc/firewalld/` más, opcionalmente, el
volcado de nft como registro forense.

**A1.3** `nft -f` es **aditivo**: sin `flush ruleset`, el contenido del archivo se agrega a lo que ya está
cargado, duplicando reglas y, peor aún, dejando reglas obsoletas que ya no aparecen en tu archivo fuente. Una
carga de archivo completo también es **atómica** — el archivo entero es una sola transacción netlink,
confirmada o rechazada como unidad, así que el host nunca queda brevemente a medio configurar. Una secuencia
de comandos `nft add rule` es una secuencia de transacciones independientes, y una falla en el medio deja un
firewall parcial, posiblemente abierto.

**A1.4** El orden de evaluación es por **prioridad de hook**, no por herramienta: en un hook dado, todos los
handlers registrados corren en orden ascendente de prioridad, sin importar si fueron registrados por
`ip_tables` o por `nf_tables`. El riesgo es que ninguna herramienta puede ver las reglas de la otra:
`iptables-legacy -L` no muestra nada sobre las reglas nft y `nft list ruleset` no muestra nada sobre las
reglas legacy, así que un operador depurando un drop puede estar mirando un ruleset que no es el que toma la
decisión. Elegí un solo motor por host.

**A1.5** `-c`/`--check` parsea y valida el archivo (sintaxis, tablas/cadenas/sets referenciados, corrección de
tipos) **sin confirmar nada en el kernel**. Convierte toda una clase de caídas — un typo en la línea 80 de un
archivo de 120 líneas cargado después de `flush ruleset` — en un mensaje de error de la shell.

### Ejercicio 2

**A2.1** En nftables la **policy de la cadena se aplica solo después de que todas las reglas fueron evaluadas
sin un veredicto terminal**. Así que un paquete que llega al final de `inbound` igual cae en `policy drop`.
Separar "log" de "drop" hace que la regla de log sea una sentencia no terminal común: podés agregarla,
quitarla o limitarle la tasa sin arriesgar nunca el comportamiento de drop, y el `counter` final te da una
métrica barata y siempre activa del tráfico no coincidente. Terminar con `log ... drop` acopla las dos cosas.

**A2.2** `iif` hace match sobre el **índice** de la interfaz (`ifindex`), resuelto una sola vez al cargar la
regla; `iifname` hace match sobre el **nombre** de la interfaz, evaluado por paquete. `iif` es más rápido pero
se rompe cuando la interfaz se elimina y se vuelve a crear (contenedores, `wg0`, `ppp0`, taps de VM) porque el
índice cambia mientras el nombre no. `iifname` además te permite escribir reglas para interfaces que todavía
no existen. Regla práctica: `iif lo` para el loopback, `iifname` para cualquier cosa dinámica.

**A2.3** Sí, la segunda cadena se sigue evaluando. En nftables, `accept` es un veredicto para la **cadena
actual**: la evaluación de esa cadena se detiene, pero las otras cadenas base registradas en el mismo hook
siguen siendo evaluadas en orden de prioridad, y cualquiera de ellas todavía puede descartar el paquete.
`drop` es distinto — es inmediato y final: el paquete se descarta y ninguna otra cadena de ese hook corre.
Esta asimetría es la trampa clásica de nftables para administradores que vienen de iptables.

**A2.4** `invalid` significa que conntrack no pudo asociar el paquete con ningún flujo conocido — segmentos TCP
fuera de ventana, un RST tardío, errores ICMP que referencian una conexión no rastreada, o tráfico que estaba
vivo cuando se vació la tabla de conntrack. Estos paquetes no coinciden ni con `established` ni con `new`, así
que caerían a través de toda tu cadena de política. Descartarlos explícitamente y temprano es más barato y más
claro que depender de la policy, y evita rarezas como que segmentos fuera de ventana sean entregados a las
reglas de servicio del estado `new`.

**A2.5** Las sentencias dentro de una regla se ejecutan **de izquierda a derecha**. Con `limit` primero, el
limitador actúa como compuerta: solo 5 paquetes por minuto (más una ráfaga de 5) llegan alguna vez a la
sentencia `log`, así que el ring buffer del kernel queda protegido durante una inundación. Intercambiados,
cada paquete sería logueado y recién después limitado en tasa — el limitador estaría midiendo algo que ya no
controla, y una inundación SYN llenaría `/var/log`.

**A2.6** Un verdict map es una **única búsqueda hash** que produce un veredicto, mientras que tres reglas son
tres evaluaciones de match secuenciales. La diferencia es invisible con tres estados y decisiva con cientos de
entradas; además es actualizable atómicamente, ya que podés agregar y quitar elementos del map sin tocar la
regla.

### Ejercicio 3

**A3.1** Los sets simples son sets hash: solo pueden responder "¿está presente este valor exacto?". Un prefijo
como `203.0.113.0/24` es un **rango** de valores, así que nftables almacena los sets de intervalos en un
backend distinto (una implementación ordenada/árbol rojo-negro o `pipapo`) que soporta búsqueda por rango.
`flags interval` es lo que selecciona ese backend; sin eso, el elemento se rechaza al cargar. El costo es una
búsqueda algo más cara que un hash puro; el beneficio es que un elemento cubre 256 direcciones.

**A3.2** `add` inserta el elemento solo si no está ya presente — un elemento existente conserva su expiración
original, así que la entrada de un atacante persistente vence en el plazo original. `update` inserta si no
está y **refresca el timeout** si está, así que la entrada sobrevive mientras el tráfico continúe. Usá
`update` para "mantenelos bloqueados mientras sigan golpeando", `add` para "bloquear exactamente una hora
desde la primera infracción".

**A3.3** Costo por paquete: 4.000 reglas se evalúan linealmente, así que un paquete que no coincide con nada
paga 4.000 comparaciones; la versión con set paga una búsqueda, efectivamente en tiempo constante. Costo de
actualización: agregar un prefijo a la versión basada en reglas requiere modificar el ruleset (una transacción
que debe re-verificar la cadena afectada), mientras que `nft add element` cambia solo el contenido del set,
atómicamente, sin recarga del ruleset y sin interrupción para los paquetes en vuelo.

**A3.4** Se pierden. Los elementos agregados desde el camino del paquete viven solo en memoria del kernel;
`flush ruleset` destruye el set junto con su contenido. `nft list ruleset` *sí* vuelca los elementos dinámicos
actuales (con sus valores `expires` restantes), así que hacer `nft list ruleset > archivo` antes del apagado, y
recargar ese archivo, preserva un snapshot puntual. Para cualquier cosa que realmente deba sobrevivir,
persistí a los infractores en disco desde el espacio de usuario (por ejemplo, `fail2ban` o un script chico que
consuma el prefijo del log) en lugar de depender del set.

**A3.5** Porque las reglas se evalúan en orden y la regla `add` termina en `drop` solo para los paquetes que
exceden la tasa. Una dirección que ya está en `@ssh_flood` debe ser descartada **antes** de llegar a la regla
de limitación de tasa; de lo contrario sus paquetes seguirían siendo medidos por el limitador y, mientras
estén por debajo de la tasa, caerían hasta la regla de accept — el bloqueo nunca tendría efecto real.

**A3.6** Un `set` responde una pregunta de pertenencia y la regla provee el veredicto (`tcp dport @ports
accept`). Un `map` de tipo `inet_service : verdict` *es* la decisión: `tcp dport vmap @svcmap` busca el
puerto y ejecuta el veredicto almacenado, que puede diferir por elemento (`22 : accept, 25 : drop, 8080 :
jump webchain`). Los maps te permiten cambiar la política por clave sin agregar reglas.

### Ejercicio 4

**A4.1** El connection tracking se registra en la prioridad **-200** (`NF_IP_PRI_CONNTRACK`) en `prerouting` y
`output`. Una cadena `raw` tiene prioridad **-300**, es decir, corre *antes* de conntrack, que es el único
punto en el que todavía podés decir "no rastrees este paquete en absoluto". Una sentencia `notrack` en
`priority filter` (0) se ejecutaría después de que la conexión ya hubiera sido creada y no tendría sentido.

**A4.2** El `accept` de tu sesión SSH vino de `ct state established`, no de la regla del puerto 22 — esa regla
solo hace match con `ct state new`, es decir, un `SYN`. Borrar la entrada de conntrack significa que el
siguiente segmento de datos del cliente (un `ACK` con payload) no coincide con ningún flujo y se clasifica
como `invalid`, así que es descartado; las respuestas del servidor tampoco coinciden en la dirección de
salida. La sesión se cuelga hasta que TCP se rinde. La recuperación requiere una conexión *nueva*: el cliente
debe reconectarse para que un `SYN` fresco haga match con la regla de `new`.

**A4.3** (1) Subir `net.netfilter.nf_conntrack_max` (y el tamaño de la hash, vía
`/sys/module/nf_conntrack/parameters/hashsize`, para mantener cortas las cadenas de buckets). (2) Bajar los
timeouts que están acaparando entradas — `nf_conntrack_tcp_timeout_established` viene por defecto en 432000 s
(5 días), lo que en un gateway ocupado mantiene vivos cientos de miles de flujos muertos;
`nf_conntrack_udp_timeout` importa para DNS y VoIP. (3) Dejar de rastrear tráfico que no necesita estado, con
`notrack` en una cadena `raw`. En un gateway NAT ocupado, hacé (1) primero — es instantáneo, seguro, y detiene
la pérdida de paquetes; después arreglá los timeouts, porque subir `max` sin arreglar un timeout de 5 días
solo pospone la misma caída. Notá que las entradas que pertenecen a flujos con NAT nunca pueden llevar
`notrack`, ya que NAT requiere estado.

**A4.4** `/proc/net/nf_conntrack` es la exportación cruda del kernel: requiere el módulo `nf_conntrack` (y, en
algunos kernels, soporte de `nf_conntrack_procfs` / `CONFIG_NF_CONNTRACK_PROCFS`), imprime una línea por
entrada incluyendo la familia L3 y los números de protocolo, y no ofrece filtrado. `conntrack -L` (del paquete
`conntrack-tools`) habla con el kernel a través de la interfaz **netlink** `ctnetlink`, que es la API
soportada: puede filtrar (`-p`, `--src`, `--dport`, `--state`), borrar (`-D`), vaciar (`-F`), actualizar
(`-U`) y transmitir eventos (`-E`). Los scripts deberían usar `conntrack`; `/proc` es para una mirada rápida.

**A4.5** Los helpers parsean payloads de aplicación y abren expectativas para flujos `related` (una conexión de
datos FTP, por ejemplo). La asignación automática significaba que *cualquier* tráfico que llegara al puerto
bien conocido del helper era parseado, así que un atacante que pudiera hacer llegar tráfico al puerto 21 podía
hacer que el firewall abriera agujeros arbitrarios. Desde Linux 4.7, `net.netfilter.nf_conntrack_helper` está
en 0 por defecto y la asignación debe ser explícita. Para que FTP funcione tenés que: (1) cargar el módulo del
helper (`modprobe nf_conntrack_ftp`), y (2) asignarlo explícitamente al tráfico previsto — en nftables,
declarar un objeto `ct helper` y aplicarlo con `tcp dport 21 ct helper set "ftp-standard"`; en iptables,
`-t raw -A PREROUTING -p tcp --dport 21 -j CT --helper ftp`. Tu cadena de filtro debe entonces aceptar
`ct state related` para la conexión de datos.

**A4.6** `[ASSURED]` marca un flujo que ha visto tráfico en **ambas direcciones** y completó la semántica de su
handshake — el kernel lo considera una conexión real y viva. Cuando la tabla está llena, el kernel intenta
`early_drop`: expulsa una entrada **no assured** del mismo bucket de hash para hacer lugar a la nueva. Las
entradas assured están protegidas de esa expulsión, y por eso una tabla llena de entradas assured produce
`table full, dropping packet` en lugar de reciclar silenciosamente.

**A4.7** (1) Un error ICMP (destination-unreachable, time-exceeded) cuyo encabezado embebido refiere a un flujo
rastreado — así es como PMTUD y traceroute sobreviven a un firewall stateful. (2) Una conexión de datos FTP
abierta como una *expectativa* por el helper de conntrack de FTP, o el equivalente para los helpers de
SIP/TFTP/PPTP.

### Ejercicio 5

**A5.1** `nat prerouting` (prioridad -100) corre **antes** que `filter forward` (prioridad 0). Para cuando el
paquete llega a la cadena forward, su destino ya fue reescrito, así que la regla de forward debe hacer match
con la dirección **interna, posterior al DNAT** `10.10.0.2:8080` — no con la dirección y el puerto públicos
que usó el cliente. Escribir ahí la dirección previa al NAT es uno de los bugs más comunes de "el port
forward no funciona".

**A5.2** Solo el primer paquete de un flujo atraviesa las cadenas `nat`; la traducción resultante se almacena
en la entrada de conntrack, y es **conntrack** quien la aplica a cada paquete subsiguiente en ambas
direcciones. La consecuencia es que agregar, cambiar o quitar una regla de NAT **no tiene efecto sobre los
flujos que ya existen** — siguen usando la traducción registrada al momento de su creación. Después de
cambiar reglas de NAT tenés que vaciar las entradas de conntrack afectadas (`conntrack -D ...`) si necesitás
que el cambio se aplique de inmediato.

**A5.3** `snat to <dirección>` es una reescritura estática: la más barata, y sobrevive a las caídas de la
interfaz. `masquerade` busca la dirección primaria de la **interfaz de salida** para cada flujo nuevo, así que
cuesta una búsqueda extra por conexión nueva, pero es correcto en uplinks cuya dirección cambia (DHCP, PPPoE)
donde un `snat` hardcodeado se rompería en cada renovación de lease. `masquerade` además registra un notifier
de dispositivo: cuando la interfaz se cae, las entradas de conntrack asociadas se vacían, de modo que no se
conservan traducciones obsoletas hacia una dirección que ya no existe. Usá `snat` en uplinks estáticos,
`masquerade` en los dinámicos.

**A5.4** El forwarding debe habilitarse en el namespace que realiza el **ruteo entre las dos interfaces** —
acá, el namespace raíz, que es dueño de `veth-fw` y `eth0`. `net.ipv4.ip_forward` está namespaceado, así que
establecerlo dentro de `lan` habría habilitado el forwarding para un namespace que tiene una sola interfaz y
no rutea nada; los paquetes igual habrían sido descartados por el namespace raíz.

**A5.5** *Screened subnet (DMZ)*: un segmento de red separado que aloja servicios públicamente alcanzables,
ubicado entre dos fronteras de filtrado de modo que un servicio público comprometido todavía enfrente un
firewall antes de la red interna — se hace cumplir con la cadena `forward`. *Bastion host*: un host
deliberadamente mínimo y endurecido que es el único sistema expuesto a una red no confiable y el único punto
de entrada permitido para administración — su propia exposición se hace cumplir con la cadena `input`.
*Dual-homed firewall*: un host con interfaces en dos redes y el forwarding controlado de modo que ningún
tráfico pase sin una regla explícita — cadena `forward`, `policy drop`. *Egress filtering*: restringir qué
puede salir de la red, para contener la exfiltración de datos y las llamadas de comando y control; en este
host sería la cadena `output` para el tráfico propio del firewall y la cadena `forward` para el de la LAN.

**A5.6** Porque el efecto colateral de filtrado del NAT es incidental, no política: descarta conexiones
entrantes solo porque no hay una entrada de traducción para ellas, y cualquier regla DNAT, demonio UPnP,
expectativa de helper o flujo iniciado hacia afuera lo atraviesa de lleno. Tampoco brinda ninguna protección
para el tráfico que sí tiene permitido atravesarlo, ni logging, ni política de estado, ni nada para IPv6,
donde el NAT típicamente está ausente. Ocultar direcciones es oscuridad; el filtro de paquetes es el control.

### Ejercicio 6

**A6.1** `*filter` selecciona la tabla a la que pertenecen las líneas siguientes. `:INPUT ACCEPT [1204:98123]`
declara la cadena incorporada `INPUT` con política por defecto `ACCEPT` y, porque se usó `-c`, sus contadores
actuales de paquetes y bytes. `COMMIT` termina el bloque de la tabla y es lo que hace que `iptables-restore`
aplique el contenido de esa tabla como una única transacción — sin eso, el bloque no se aplica en absoluto.

**A6.2** `iptables-restore` carga todas las reglas de una tabla y las confirma en una sola operación, así que
el kernel pasa del ruleset viejo al nuevo sin un estado intermedio en el que el host quede desprotegido.
`-n`/`--noflush` mantiene esa atomicidad pero cambia la semántica de *reemplazar* a *agregar*: las reglas
existentes en esas tablas se preservan y las del archivo se suman a ellas. Correr el mismo archivo dos veces
con `-n` duplica, por lo tanto, cada regla.

**A6.3** `nft add rule ip nat POSTROUTING ip saddr 10.0.0.0/8 oifname != "lo" counter masquerade`
(esto es exactamente lo que emite `iptables-translate`; notá que `!` se convierte en `!=` y el `counter`
implícito que las reglas de iptables siempre llevan).

**A6.4** `-m state` es el match obsoleto `xt_state`, que solo conoce los estados básicos. `-m conntrack`
(`xt_conntrack`) lo reemplaza y expone mucho más: `--ctstate` incluyendo `DNAT`/`SNAT`, más `--ctstatus`,
`--ctproto`, `--ctorigsrc`/`--ctorigdst`, `--ctdir` y `--ctexpire`. `-m state` está implementado como un alias
por compatibilidad hacia atrás. Las reglas nuevas deberían usar siempre `-m conntrack --ctstate`.

**A6.5** Porque las reglas llevan metadatos de compatibilidad de los que depende el front-end `iptables-nft`
para reconstruir su propia vista del ruleset. Editarlas con `nft` — reordenar, insertar una expresión nativa
de nft, o renombrar — produce una tabla que `iptables -L`/`iptables-save` ya no puede interpretar,
típicamente fallando con errores u omitiendo reglas silenciosamente. La regla es: una tabla, una herramienta.

**A6.6** `DROP` descarta el paquete sin respuesta, así que el cliente espera su timeout TCP — el puerto aparece
como *filtered*. `REJECT --reject-with icmp-port-unreachable` envía un error ICMP, así que el cliente falla de
inmediato — el puerto aparece como *closed*. Usá `REJECT` en redes internas donde la falla rápida es una
característica de usabilidad (evita cuelgues de aplicación de 30 segundos), y `DROP` en interfaces expuestas a
Internet donde no querés confirmar que el host existe ni gastar ancho de banda respondiendo escaneos. Notá
que para TCP, `--reject-with tcp-reset` es lo más parecido a "no hay nada escuchando".

**A6.7** Una cadena definida por el usuario solo puede eliminarse cuando está **vacía y sin referencias**.
"Too many links" significa que al menos una regla todavía salta a `HARDENED` (acá, la regla
`-A INPUT -i eth0 -j HARDENED`). Borrá primero las reglas que la referencian, después vaciá la cadena
(`-F HARDENED`), y recién ahí eliminala (`-X HARDENED`).

### Ejercicio 7

**A7.1** (1) `nd-neighbor-solicit` / `nd-neighbor-advert` — Neighbour Discovery reemplaza a ARP; bloquearlo
significa que el host no puede resolver direcciones de capa de enlace y toda la conectividad IPv6 en el enlace
falla. (2) `packet-too-big` — los routers IPv6 no fragmentan, así que el Path MTU Discovery depende
enteramente de este mensaje; bloquearlo produce conexiones agujero negro. (3) `destination-unreachable` — sin
él, las fallas se vuelven timeouts en lugar de errores inmediatos, y algunos protocolos se cuelgan. (4)
`time-exceeded` — traceroute y la detección de bucles dejan de funcionar. `parameter-problem` y, en redes
SLAAC, `nd-router-advert`/`nd-router-solicit` pertenecen a la misma lista. Esta es la guía de la RFC 4890.

**A7.2** Un agujero negro de PMTU. El handshake TCP y los pedidos chicos entran dentro de la MTU mínima y
tienen éxito, así que la conexión parece funcionar. Apenas el par envía segmentos de tamaño completo que
exceden la MTU de algún enlace del camino, el router que no puede reenviarlos envía `packet-too-big` — que tu
filtro descarta — así que el emisor nunca aprende a reducir su tamaño de segmento y sigue retransmitiendo
paquetes que nunca pueden llegar. El usuario ve "la página empieza a cargar y después se traba", o SSH que
conecta pero se congela en la primera salida grande.

**A7.3** Los mensajes NDP son link-local por definición. La RFC 4861 exige que los emisores establezcan el hop
limit en 255 y que los receptores lo verifiquen, porque un hop limit de 255 llegando a tu interfaz prueba que
el paquete no fue ruteado — cualquier router que lo hubiera reenviado habría decrementado el valor. La
verificación hace imposible el spoofing de NDP fuera del enlace, así que filtrar por `ip6 hoplimit 255` hace
cumplir esa garantía en el firewall.

**A7.4** Porque nft genera automáticamente una **dependencia** sobre el protocolo de capa de red: escribir
`ip saddr` en una tabla `inet` hace que nft anteponga un test implícito `meta nfproto ipv4`, así que la regla
solo puede coincidir con paquetes IPv4. Lo mismo aplica a `ip6 saddr` e IPv6. Podés ver la dependencia
generada en `nft --debug=netlink list ruleset`.

**A7.5** `nd-router-solicit` (el host pregunta) y `nd-router-advert` (el router responde con el prefijo y la
ruta por defecto); sin ellos SLAAC no produce dirección global ni ruta por defecto. El compromiso es que
aceptar router advertisements desde cualquier origen link-local es exactamente el ataque de *rogue RA* — un
host malicioso en el segmento puede anunciarse como el router por defecto e interceptar tráfico. Las
mitigaciones son RA Guard a nivel de switch, filtrar los RA hacia direcciones de router conocidas, o
`net.ipv6.conf.<if>.accept_ra=0` con configuración estática en routers y servidores.

### Ejercicio 8

**A8.1** La prioridad -301 es menor que `raw` (-300) y por lo tanto menor que conntrack (-200) y que todo lo
demás, así que `meta nftrace set 1` se aplica antes de que ninguna otra cadena haya tenido oportunidad de
actuar sobre el paquete. Trazar desde la prioridad 0 se perdería toda decisión tomada en `raw`, en conntrack,
y en cualquier cadena con prioridad negativa — incluida, con frecuencia, la regla misma que está descartando
el paquete.

**A8.2** Te dice que el paquete no coincidió con **ninguna regla terminal** en `inbound`: se cayó del final de
la cadena y fue descartado por la policy de la cadena. Así que esto no es un bug de "coincidió la regla
equivocada", es un bug de "falta una regla". La verificación siguiente es el encabezado del paquete impreso en
la primera línea del trace — compará su `iif`, direcciones y `dport` contra la regla que esperabas que
coincidiera; los culpables habituales son un nombre de interfaz que no coincide (`iifname "eth0"` frente a un
nombre predecible como `enp1s0`), un desajuste de familia de direcciones, o una regla ubicada después de un
veredicto terminal.

**A8.3** Solo algunos. `meta nftrace set 1` es un flag por paquete establecido cuando esa regla se evalúa, así
que marca exactamente los paquetes que atraviesan la cadena que lo contiene y coinciden con sus condiciones.
Si la regla de trace está en `prerouting`, las respuestas generadas localmente (que toman `output`) no se
trazan — por eso el ejercicio agrega una regla en ambos hooks. El tracing no es por flujo: para un flujo
ocupado, cada paquete que coincide genera eventos de trace, que es precisamente por qué es caro.

**A8.4** `-s`/`--stateless` omite los contadores y otro estado de runtime de la salida, lo que hace que dos
volcados sean comparables con diff — de lo contrario cada línea difiere porque los conteos de paquetes se
movieron. `nft reset counters` realmente **pone en cero** los contadores en el kernel (e imprime sus valores
previos al reset), que es lo que querés antes de una prueba de reproducción para que "¿le pegó algo a esta
regla?" tenga una respuesta inequívoca.

**A8.5** Cada paquete trazado genera un evento netlink que describe el camino completo que tomó a través del
ruleset. Bajo carga esto es una gran cantidad de trabajo por paquete y de tráfico de eventos, y va a
perjudicar el throughput y la CPU mucho antes de llenar ningún buffer. El tracing es un diagnóstico para
habilitar, acotar lo más estrechamente posible (una única dirección de origen), y quitar.

**A8.6** (1) No hay nada escuchando: verificalo con `ss -lntup | grep <port>` — el contador se incrementa en una
regla que acepta el paquete, y el kernel después responde con RST o ICMP port unreachable. (2) El camino de
retorno está roto: ruteo asimétrico, una ruta faltante de vuelta al cliente, o SELinux/AppArmor bloqueando que
el servicio haga bind. También vale la pena verificar: un firewall o security group aguas arriba, y el
servicio bindeado a `127.0.0.1` en lugar de `0.0.0.0`.

### Ejercicio 9

**A9.1** firewalld mantiene dos configuraciones: el ruleset de **runtime**, que es lo que está actualmente en
el kernel, y la configuración **permanent**, almacenada como XML bajo `/etc/firewalld/`. Los comandos sin
`--permanent` cambian solo el runtime y son descartados por un `--reload`, un reinicio del servicio o un
reboot; los comandos con `--permanent` cambian solo el XML y requieren `--reload` para tomar efecto. Las dos
formas de hacer durable un cambio de runtime son repetirlo con `--permanent` (y después `--reload`), o correr
`firewall-cmd --runtime-to-permanent`, que escribe todo el estado de runtime actual en la configuración
permanente. La separación existe a propósito: te da una prueba que se auto-revierte — si un cambio de runtime
te deja afuera, un reboot restaura el acceso.

**A9.2** Se destruyen en el siguiente `firewall-cmd --reload` o reinicio de firewalld, porque firewalld vacía y
regenera las tablas de las que es dueño a partir de su configuración XML. Tus propias reglas pertenecen o bien
al vocabulario propio de firewalld (services, ports, rich rules y reglas de passthrough `--direct`, todas las
cuales firewalld regenerará por vos) o bien a una **tabla separada tuya** — nftables permite múltiples cadenas
base en el mismo hook, así que `table inet mycompany` con su propia cadena `input` coexiste con
`inet firewalld` y sobrevive a las recargas de firewalld. Acordate de A2.3: `drop` en cualquiera de las dos
cadenas es final, mientras que `accept` en una no detiene a la otra.

**A9.3** `ufw limit 22/tcp` deniega a una dirección de origen que haya iniciado **6 o más conexiones dentro de
30 segundos**, permitiéndola en caso contrario — un amortiguador de fuerza bruta SSH rudimentario pero
efectivo (implementado con el match `recent` en el backend legacy). El equivalente nativo en nftables es el
idiom de set dinámico del Ejercicio 3: `tcp dport 22 ct state new add @ssh_flood { ip saddr timeout 1h limit
rate over 6/minute } drop`, combinado con un `ip saddr @ssh_flood drop` precedente.

**A9.4** Filtrar **entre puertos del mismo bridge de Linux** — por ejemplo, aislar entre sí dos VMs o
contenedores conectados a `br0`, o filtrar ARP y EtherTypes no IP. Ese tráfico se conmuta en capa 2 y nunca
entra al camino de ruteo IP, así que las cadenas de la familia `ip` nunca lo ven; solo `ebtables` o la familia
`bridge` de nftables (hooks `prerouting`/`forward`/`postrouting` en capa 2) pueden actuar sobre él.
Establecer `net.bridge.bridge-nf-call-iptables=1` (con el módulo `br_netfilter`) hace que el tráfico IP
puenteado *también* atraviese la cadena `forward` de la familia IP — útil para reutilizar política IP en un
bridge, y una fuente notoria de sorpresas cuando un host puenteado queda de repente filtrado por reglas que
fueron escritas para un router.

**A9.5** Se rompen. Todas las sesiones TCP establecidas estaban rastreadas únicamente en el nodo previamente
activo; el nodo recién activo tiene una tabla de conntrack vacía, así que el primer paquete de cada sesión
sobreviviente no coincide con ningún flujo, se clasifica como `invalid` (no es un `SYN`) y es descartado por la
política stateful. Cada cliente debe reconectarse. `conntrackd` arregla esto replicando continuamente las
entradas de conntrack entre los dos nodos (típicamente en modo FTFW sobre un enlace dedicado), de modo que el
nodo en espera tenga una tabla sombra actualizada y pueda confirmarla (`conntrackd -c`) en el failover,
permitiendo que los flujos establecidos continúen.

**A9.6** Ambos son front-ends que asumen que son dueños del ruleset del host, y ambos lo vacían y regeneran al
arrancar y al recargar. Correrlos juntos produce una carrera en la que gana el último que recarga, una
política efectiva que no coincide con la salida de estado de ninguna de las dos herramientas, y un firewall
cuyo estado después de un reboot depende del orden de las units de systemd. Elegí uno, y hacé
`systemctl disable --now` al otro.

**A9.7** El modo pánico descarta **todos** los paquetes entrantes y salientes — es un interruptor de
emergencia que corta la conectividad de red del host, incluida tu propia sesión SSH, y no es persistente a
través de un reinicio de firewalld. Usalo desde la consola cuando creas que un host está activamente
comprometido y querés detener de inmediato la exfiltración o el movimiento lateral mientras preservás la
máquina para forense. Deshacelo con `firewall-cmd --panic-off`, y verificalo con `firewall-cmd --query-panic`.

</details>

---

## Fuentes de referencia

- LPI — Objetivos del Examen 303 (303-300, v3.0.0): <https://www.lpi.org/our-certifications/exam-303-objectives/>
- Proyecto netfilter/nftables: <https://netfilter.org/projects/nftables/index.html>
- Wiki de nftables — página principal y referencia rápida: <https://wiki.nftables.org/wiki-nftables/index.php/Main_Page>
- Wiki de nftables — configurar cadenas, hooks y prioridades: <https://wiki.nftables.org/wiki-nftables/index.php/Configuring_chains>
- Wiki de nftables — sets y sets dinámicos: <https://wiki.nftables.org/wiki-nftables/index.php/Sets>
- Wiki de nftables — NAT: <https://wiki.nftables.org/wiki-nftables/index.php/Performing_Network_Address_Translation_(NAT)>
- Wiki de nftables — migrar de iptables a nftables: <https://wiki.nftables.org/wiki-nftables/index.php/Moving_from_iptables_to_nftables>
- Wiki de nftables — debug y tracing del ruleset: <https://wiki.nftables.org/wiki-nftables/index.php/Ruleset_debug/tracing>
- netfilter — página del proyecto iptables/ip6tables: <https://netfilter.org/projects/iptables/index.html>
- netfilter — conntrack-tools (`conntrack`, `conntrackd`): <https://netfilter.org/projects/conntrack-tools/index.html>
- netfilter — página del proyecto ebtables: <https://netfilter.org/projects/ebtables/index.html>
- Documentación del kernel de Linux — sysctls de connection tracking: <https://www.kernel.org/doc/html/latest/networking/nf_conntrack-sysctl.html>
- Documentación de firewalld: <https://firewalld.org/documentation/>
- Página de manual de ufw: <https://manpages.ubuntu.com/manpages/noble/en/man8/ufw.8.html>
- RFC 4890 — Recomendaciones para Filtrar Mensajes ICMPv6 en Firewalls: <https://www.rfc-editor.org/rfc/rfc4890>
- RFC 4861 — Neighbor Discovery para IP versión 6: <https://www.rfc-editor.org/rfc/rfc4861>
- Shorewall (para conocimiento general): <https://shorewall.org/>