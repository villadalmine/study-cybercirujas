# 334.3 — Filtrado de paquetes

**LPIC-3 303 (Security), examen 303-300 v3.0.0 — Tema 334: Seguridad de red**
**Peso: 8.33** — uno de los objetivos individuales más pesados del examen, y el que tiene la mayor distancia entre "aprobar el examen" y "sobrevivir en producción".

---

## 0. Mapa de alcance: qué exige realmente el objetivo

| Área de conocimiento (LPI) | Dónde se cubre acá | Lo que está en juego en producción |
|---|---|---|
| Arquitecturas de firewall comunes, incl. DMZ | §10 | Contención del radio de impacto |
| netfilter, iptables, ip6tables — módulos, matches, targets | §2, §3 | El núcleo del examen |
| Filtrado de paquetes para IPv4 **e** IPv6 | §3.6 | Los errores con ICMPv6 rompen la red de forma silenciosa |
| Seguimiento de conexiones (connection tracking) y NAT | §4, §5 | La causa #1 de caídas de firewall |
| Definir IP sets y usarlos en reglas de netfilter | §6 | Evaluación de reglas O(1) vs O(N) |
| Conocimiento básico de nftables y `nft` | §7 | Ya es el valor por defecto en RHEL 9+/Debian 11+ |
| Conocimiento básico de `ebtables` | §8 | El plano de bridge de KVM/libvirt/Docker |
| Nociones de `conntrackd` | §9 | Failover con estado (HA) |

**Términos y utilidades:** `iptables`, `ip6tables`, `iptables-save`, `iptables-restore`, `ip6tables-save`, `ip6tables-restore`, `ipset`, `nft`, `ebtables`.

---

## 1. El problema arquitectónico

Un filtro de paquetes no es "una lista de reglas allow/deny". En una plataforma de producción es un **plano de control con estado, distribuido y de punto único de falla, que está en el datapath de cada byte que mueve tu negocio**. Chocan tres propiedades:

1. **Está en el camino caliente.** Cada regla que agregás cuesta ciclos de CPU por paquete. Una cadena lineal de 3 000 reglas a 1 Mpps no es un problema de política, es un problema de capacidad.
2. **Guarda estado.** El seguimiento de conexiones implica que el firewall *no* es idempotente entre reinicios, y *no* es sin estado a través de un failover de HA. Una tabla de conntrack vaciada tira abajo todas las conexiones establecidas de la máquina.
3. **Lo edita más de un dueño.** En un nodo moderno el ruleset está co-escrito por vos, `firewalld`, `dockerd`, `kube-proxy`, `cilium`, `fail2ban` y tu herramienta de gestión de configuración. Todos escriben sobre el mismo objeto del kernel.

Los modos de falla que realmente despiertan a un SRE a las 03:00 casi nunca son "se dejó abierto el puerto equivocado". Son:

| Modo de falla | Síntoma | Causa raíz |
|---|---|---|
| Tabla de conntrack llena | Resets de conexión aleatorios, `nf_conntrack: table full, dropping packet` en `dmesg` | `nf_conntrack_max` dimensionado para 2 GB de RAM en una máquina de 128 GB |
| Ruteo asimétrico + drop de `INVALID` | Los flujos TCP de larga duración mueren a los pocos segundos, los cortos funcionan | El camino de vuelta esquiva el firewall; conntrack ve solo la mitad del stream |
| Drop indiscriminado de ICMPv6 | IPv6 "funciona" y después se cuelga en transferencias grandes | Agujero negro de PMTUD (`packet-too-big` filtrado), NDP roto |
| Agotamiento de puertos de SNAT | `insert_failed` en aumento, timeouts de conexión intermitentes | Una sola IP origen de SNAT, techo de ~64 k tuplas por destino |
| Recarga de reglas no atómica | Ventana de 200 ms donde la política es `DROP` sin ninguna regla `ACCEPT` | `iptables -F` seguido de un bucle de `iptables -A` |
| Ruleset pisado por un agente | La política se revierte tras reiniciar un contenedor | Reglas escritas en `FORWARD` en vez de `DOCKER-USER` |

Todo lo que sigue está organizado alrededor de prevenir esos seis.

---

## 2. Arquitectura de netfilter: el camino del paquete

### 2.1 Los cinco hooks

Netfilter es un conjunto de **puntos de enganche (hooks)** en la pila L3 del kernel. Cada framework — `iptables`, `nftables`, `ipvs`, `conntrack`, `ebtables` — es un consumidor que registra callbacks en estos hooks con una **prioridad** numérica (el más bajo corre primero).

```
                         ┌──────────────────┐
   NIC ──▶ [netdev/ingress] ──▶ PREROUTING ──▶│ routing decision │
                                              └────────┬─────────┘
                                       ┌───────────────┴───────────────┐
                                       ▼                               ▼
                                 (for this host)                 (for elsewhere)
                                    INPUT                          FORWARD
                                       │                               │
                                       ▼                               │
                                 local process                         │
                                       │                               │
                                       ▼                               │
                                    OUTPUT                             │
                                       │                               │
                                       └──────────┬────────────────────┘
                                                  ▼
                                            POSTROUTING ──▶ [netdev/egress] ──▶ NIC
```

### 2.2 Prioridades de tablas — el orden de recorrido que tenés que poder recitar

| Prioridad | Nombre simbólico | Tabla de iptables | Nombre en nftables | Hooks |
|---:|---|---|---|---|
| −400 | `NF_IP_PRI_RAW_BEFORE_DEFRAG` | — | `raw -300 -100` | — |
| −400 | — | — | — | acá corre la desfragmentación |
| −300 | `NF_IP_PRI_RAW` | `raw` | `raw` | PREROUTING, OUTPUT |
| −200 | `NF_IP_PRI_CONNTRACK` | *(conntrack)* | — | PREROUTING, OUTPUT |
| −150 | `NF_IP_PRI_MANGLE` | `mangle` | `mangle` | los cinco |
| −100 | `NF_IP_PRI_NAT_DST` | `nat` (DNAT) | `dstnat` | PREROUTING, OUTPUT |
| 0 | `NF_IP_PRI_FILTER` | `filter` | `filter` | INPUT, FORWARD, OUTPUT |
| 50 | `NF_IP_PRI_SECURITY` | `security` | `security` | INPUT, FORWARD, OUTPUT |
| 100 | `NF_IP_PRI_NAT_SRC` | `nat` (SNAT) | `srcnat` | POSTROUTING, INPUT |
| `INT_MAX`−1 | `NF_IP_PRI_CONNTRACK_CONFIRM` | *(conntrack)* | — | POSTROUTING, INPUT |

Cuatro consecuencias que evalúan tanto el examen como la producción:

1. **`raw` es el único lugar donde podés actuar antes de conntrack.** Por eso `NOTRACK` y `CT --helper` viven ahí.
2. **DNAT ocurre antes de la decisión de ruteo** (PREROUTING, −100 < ruteo), así que un paquete con DNAT se rutea hacia su *nuevo* destino. **SNAT ocurre después** (POSTROUTING), así que `filter/FORWARD` sigue viendo el origen original.
3. **NAT se evalúa solo en el primer paquete de un flujo** (`ctstate NEW`). Cada paquete posterior es transformado por conntrack a partir de la tupla almacenada. Agregar una regla de NAT *no* afecta a los flujos ya establecidos.
4. **Conntrack "confirma" la entrada al final del todo.** Una entrada de conntrack creada en PREROUTING no es visible para `conntrack -L` hasta que el paquete sobrevive hasta POSTROUTING/INPUT.

### 2.3 Dónde escucha `tcpdump` — y por qué te miente

`AF_PACKET` (tcpdump) se engancha en la **capa de dispositivo**:

* **Ingreso:** después del driver, **antes** de todos los hooks L3 de netfilter (pero después del ingress de `tc`/`netdev`).
* **Egreso:** después de POSTROUTING, inmediatamente antes del driver.

Por lo tanto: **un paquete descartado en `INPUT` igual aparece en `tcpdump -i eth0`.** Ver llegar el SYN prueba que el cable está bien y no prueba nada sobre tu ruleset. A la inversa, un `tcpdump` de egreso mostrando la dirección post-SNAT es lo esperado.

```console
$ tcpdump -ni eth0 -c 4 'tcp port 22 and host 198.51.100.7'
tcpdump: verbose output suppressed, use -v[v]... for full protocol decode
listening on eth0, link-type EN10MB (Ethernet), snapshot length 262144 bytes
14:22:03.114512 IP 198.51.100.7.41234 > 203.0.113.10.22: Flags [S], seq 2847193021, win 64240, options [mss 1460,sackOK,TS val 91827364 ecr 0,nop,wscale 7], length 0
14:22:04.118903 IP 198.51.100.7.41234 > 203.0.113.10.22: Flags [S], seq 2847193021, win 64240, options [mss 1460,sackOK,TS val 91828368 ecr 0,nop,wscale 7], length 0
14:22:06.134201 IP 198.51.100.7.41234 > 203.0.113.10.22: Flags [S], seq 2847193021, win 64240, options [mss 1460,sackOK,TS val 91830384 ecr 0,nop,wscale 7], length 0
14:22:10.166437 IP 198.51.100.7.41234 > 203.0.113.10.22: Flags [S], seq 2847193021, win 64240, options [mss 1460,sackOK,TS val 91834416 ecr 0,nop,wscale 7], length 0
4 packets captured
```

SYN retransmitido sin RST y sin SYN-ACK = **DROP silencioso**, sea por tu filtro o aguas arriba. Un RST significaría `REJECT --reject-with tcp-reset` o un puerto cerrado. Esta distinción es la primera bifurcación del árbol de diagnóstico de §13.

---

## 3. `iptables` / `ip6tables`

### 3.1 Los dos backends — verificá esto primero, siempre

Desde iptables 1.8, el binario `iptables` que tipeás puede ser el frontend legacy `x_tables` o `iptables-nft`, que traduce a la API de nftables del kernel. Escriben en **objetos del kernel diferentes que no se ven entre sí**.

```console
$ iptables --version
iptables v1.8.10 (nf_tables)

$ update-alternatives --display iptables
iptables - auto mode
  link best version is /usr/sbin/iptables-nft
  link currently points to /usr/sbin/iptables-nft
  link iptables is /usr/sbin/iptables
/usr/sbin/iptables-legacy - priority 10
/usr/sbin/iptables-nft - priority 20

$ iptables-legacy -S | head -3
-P INPUT ACCEPT
-P FORWARD ACCEPT
-P OUTPUT ACCEPT
```

**Peligro en producción:** un nodo con reglas en *ambos* backends evalúa los dos, con los hooks legacy y los hooks nft en la misma prioridad — la política efectiva es la intersección de los ACCEPT. Si `iptables -S` parece vacío pero el tráfico está bloqueado, revisá `iptables-legacy -S` y `nft list ruleset`.

### 3.2 Anatomía de una regla

```
iptables [-t table] {-A|-I|-D|-R|-C} CHAIN [rule-spec] -j TARGET
                    │
                    └─ -A append, -I insert (default position 1), -D delete,
                       -R replace, -C check (exit 0 if present — use in scripts)
```

Selectores principales:

| Selector | Significado | Nota |
|---|---|---|
| `-p tcp\|udp\|icmp\|icmpv6\|esp\|ah\|58\|all` | Protocolo L4 | también vale el protocolo numérico |
| `-s` / `-d` | CIDR origen / destino | `!` niega |
| `-i` / `-o` | interfaz de entrada / salida | comodín `+`: `eth+`; `-o` no es válido en INPUT/PREROUTING |
| `-f` | segundo fragmento IPv4 y siguientes | rara vez matchea — conntrack desfragmenta primero |
| `-m <module>` | carga una extensión de match | ver abajo |
| `-j` / `-g` | salto a target/cadena / goto (sin retorno) | |

### 3.3 Extensiones de match que vale la pena memorizar

| Módulo | Opciones clave | Uso en producción |
|---|---|---|
| `conntrack` | `--ctstate NEW,ESTABLISHED,RELATED,INVALID,UNTRACKED,SNAT,DNAT`, `--ctdir`, `--ctstatus`, `--ctproto` | Reemplaza al obsoleto `-m state` |
| `multiport` | `--dports 80,443,8080:8090` | Hasta 15 puertos/rangos en una sola regla |
| `limit` | `--limit 5/min --limit-burst 10` | Token bucket, **global a la regla** — para logging |
| `hashlimit` | `--hashlimit-mode srcip --hashlimit-above 20/sec --hashlimit-burst 40 --hashlimit-name ssh` | Rate limiting por origen — la herramienta correcta contra DoS |
| `recent` | `--set`, `--update --seconds 60 --hitcount 4 --name SSH --rsource` | Listas de bloqueo con estado sin ipset |
| `connlimit` | `--connlimit-above 50 --connlimit-mask 32` | Tope de conexiones concurrentes por cliente |
| `set` | `--match-set NAME src[,dst]` | Búsqueda en ipset, O(1) |
| `mark` / `connmark` | `--mark 0x10/0xff` | Ruteo por política, clasificación de QoS |
| `tcp` | `--syn`, `--tcp-flags SYN,ACK,FIN,RST SYN`, `--tcp-option` | `--syn` ≡ `--tcp-flags FIN,SYN,RST,ACK SYN` |
| `addrtype` | `--dst-type LOCAL,BROADCAST,MULTICAST` | Detectar tráfico hacia una dirección local |
| `rpfilter` | `--validate-mark`, `--loose`, `--invert` | Anti-spoofing que funciona para IPv6 |
| `policy` | `--dir in --pol ipsec --proto esp` | "Aceptar solo si salió de la SA de IPsec" |
| `physdev` | `--physdev-in vnet0`, `--physdev-is-bridged` | Tráfico bridgeado/virtualizado en `FORWARD` |
| `comment` | `--comment "JIRA-4471 payments egress"` | **Obligatorio en producción.** Las reglas sin procedencia no se borran nunca |
| `owner` | `--uid-owner`, `--gid-owner`, `--cgroup` | Solo cadena OUTPUT — política de egreso por cuenta de servicio |
| `tcpmss` | `--mss 1400:1536` | Diagnóstico de agujeros negros de PMTUD |

### 3.4 Targets

| Target | ¿Termina? | Notas |
|---|---|---|
| `ACCEPT` | sí (esta tabla/hook) | No saltea tablas posteriores de mayor prioridad |
| `DROP` | sí | Silencioso — le cuesta al cliente un timeout TCP completo |
| `REJECT --reject-with icmp-admin-prohibited\|tcp-reset\|icmp6-adm-prohibited` | sí | Usalo en segmentos internos; fallar rápido es mejor que colgarse |
| `RETURN` | para la cadena actual | Vuelve a la siguiente regla / política de la cadena llamadora |
| `LOG --log-prefix "FW-DROP-IN: " --log-level 4 --log-uid` | no | Va al ring buffer del kernel — **siempre limitale la tasa** |
| `NFLOG --nflog-group 1 --nflog-prefix ...` | no | Netlink hacia `ulogd2`; estructurado, no inunda `dmesg` |
| `NFQUEUE --queue-num 0 --queue-bypass` | sí | Entrega a espacio de usuario (IDS/IPS); `--queue-bypass` = fail-open |
| `SNAT`, `DNAT`, `MASQUERADE`, `REDIRECT`, `NETMAP` | sí | Solo tabla `nat`, solo paquetes `NEW` |
| `MARK`, `CONNMARK`, `SECMARK`, `CONNSECMARK` | no | Tabla `mangle` |
| `TCPMSS --clamp-mss-to-pmtu` | no | `mangle/FORWARD`, sobre `--tcp-flags SYN,RST SYN` |
| `CT --notrack \| --helper ftp \| --zone N` | no | Solo tabla `raw` |
| `SYNPROXY --sack-perm --timestamp --wscale 7 --mss 1460` | sí | Proxy de SYN cookies del lado del kernel para flujos reenviados/locales |
| `TRACE` | no | Tabla `raw`; habilita el trazado regla por regla |
| `AUDIT --type drop` | no | Emite a `auditd` — evidencia de cumplimiento |

### 3.5 Un ruleset IPv4 de borde completo y defendible

```bash
#!/usr/bin/env bash
# /usr/local/sbin/fw-build-v4.sh — builds the ruleset into a restore file.
# NEVER apply rules with a loop of `iptables -A`; build a file and restore it atomically.
set -euo pipefail

WAN=eth0; LAN=eth1; DMZ=eth2
LAN_NET=10.20.0.0/16
DMZ_NET=192.0.2.0/24
VIP=203.0.113.10
WEB=192.0.2.20
MTA=192.0.2.30

cat <<'EOF'
*raw
:PREROUTING ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
# Do not track loopback or the conntrack sync link: pure overhead, and tracking
# the sync link creates a feedback loop with conntrackd.
-A PREROUTING -i lo -j CT --notrack
-A OUTPUT -o lo -j CT --notrack
-A PREROUTING -i eth3 -j CT --notrack
-A OUTPUT -o eth3 -j CT --notrack
# Automatic helper assignment is OFF kernel-wide (nf_conntrack_helper=0).
# Enable the FTP helper ONLY for the one server that needs it.
-A PREROUTING -i eth0 -p tcp -d 192.0.2.40 --dport 21 -j CT --helper ftp
COMMIT

*mangle
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
# Clamp MSS on forwarded SYNs. Without this, any downstream tunnel (IPsec,
# WireGuard, PPPoE) turns into a PMTUD blackhole for clients behind broken
# ICMP filters.
-A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
COMMIT

*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
EOF

cat <<EOF
# --- DNAT: published services on the VIP -------------------------------------
-A PREROUTING -i ${WAN} -d ${VIP}/32 -p tcp --dport 443 -j DNAT --to-destination ${WEB}:443
-A PREROUTING -i ${WAN} -d ${VIP}/32 -p tcp --dport 80  -j DNAT --to-destination ${WEB}:80
-A PREROUTING -i ${WAN} -d ${VIP}/32 -p tcp --dport 25  -j DNAT --to-destination ${MTA}:25

# --- Hairpin / NAT-loopback ---------------------------------------------------
# A LAN client resolving the public name reaches the VIP, gets DNAT'd to the DMZ
# host, which would answer directly to the LAN client with the DMZ source IP ->
# the client drops it as an unsolicited packet. Masquerade the LAN side so the
# reply comes back through us.
-A PREROUTING -i ${LAN} -d ${VIP}/32 -p tcp --dport 443 -j DNAT --to-destination ${WEB}:443
-A POSTROUTING -s ${LAN_NET} -d ${WEB}/32 -p tcp --dport 443 -j SNAT --to-source 192.0.2.1

# --- Egress SNAT --------------------------------------------------------------
# --random-fully randomises source-port selection. Without it, the kernel walks
# ports sequentially and collides under load: insert_failed climbs and
# connections fail intermittently for no visible reason.
-A POSTROUTING -s ${LAN_NET} -o ${WAN} -j SNAT --to-source ${VIP} --random-fully
-A POSTROUTING -s ${DMZ_NET} -o ${WAN} -j SNAT --to-source 203.0.113.11 --random-fully
COMMIT
EOF

cat <<EOF
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]
:LOGDROP - [0:0]
:INBOUND_WAN - [0:0]
:LAN_TO_DMZ - [0:0]
:LAN_TO_WAN - [0:0]

# --- Fast path: one conntrack lookup short-circuits the whole ruleset ---------
# This MUST be rule #1 in every chain. Everything below it is evaluated only for
# the first packet of a connection, i.e. a few hundred pps, not a few Mpps.
-A INPUT   -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A OUTPUT  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# --- Drop INVALID early -------------------------------------------------------
# INVALID = conntrack cannot associate this packet with any flow (out-of-window
# TCP, ICMP error for an unknown tuple, asymmetric routing). Never ACCEPT it:
# INVALID packets bypass NAT and can be used to inject into an existing flow.
-A INPUT   -m conntrack --ctstate INVALID -j LOGDROP
-A FORWARD -m conntrack --ctstate INVALID -j LOGDROP

-A INPUT -i lo -j ACCEPT
-A OUTPUT -o lo -j ACCEPT

# --- Anti-spoofing ------------------------------------------------------------
# -m rpfilter is stateless and honours policy routing marks; net.ipv4.conf.*.rp_filter=1
# is strict RPF and WILL break asymmetric multi-homed designs. Prefer this.
-A INPUT   -m rpfilter --validate-mark --invert -j LOGDROP
-A FORWARD -i ${WAN} -s ${LAN_NET} -j LOGDROP
-A FORWARD -i ${WAN} -s ${DMZ_NET} -j LOGDROP
-A INPUT   -i ${WAN} -m set --match-set bogons4 src -j DROP

# --- Threat feed / fail2ban (ipset, O(1)) ------------------------------------
-A INPUT   -m set --match-set blocklist4 src -j DROP
-A FORWARD -m set --match-set blocklist4 src -j DROP

# --- ICMP: required for a working IPv4 network, rate-limited -----------------
-A INPUT -p icmp --icmp-type echo-request -m hashlimit --hashlimit-mode srcip \\
    --hashlimit-above 5/sec --hashlimit-burst 10 --hashlimit-name icmp4 -j DROP
-A INPUT -p icmp --icmp-type echo-request -j ACCEPT
-A INPUT -p icmp --icmp-type destination-unreachable -j ACCEPT
-A INPUT -p icmp --icmp-type time-exceeded -j ACCEPT
-A INPUT -p icmp --icmp-type parameter-problem -j ACCEPT

# --- Dispatch -----------------------------------------------------------------
-A INPUT -i ${WAN} -j INBOUND_WAN
-A INPUT -i ${LAN} -p tcp --dport 22 -m set --match-set mgmt_bastions src -j ACCEPT
-A INPUT -i eth3 -p udp --dport 3780 -s 10.99.0.0/30 -j ACCEPT
-A INPUT -i ${LAN} -p vrrp -j ACCEPT
-A INPUT -j LOGDROP

-A INBOUND_WAN -p tcp --dport 22 -m set --match-set mgmt_bastions src \\
    -m hashlimit --hashlimit-mode srcip --hashlimit-above 4/min \\
    --hashlimit-burst 4 --hashlimit-name sshbf -j LOGDROP
-A INBOUND_WAN -p tcp --dport 22 -m set --match-set mgmt_bastions src -j ACCEPT
-A INBOUND_WAN -j RETURN

-A FORWARD -i ${LAN} -o ${DMZ} -j LAN_TO_DMZ
-A FORWARD -i ${LAN} -o ${WAN} -j LAN_TO_WAN
-A FORWARD -i ${WAN} -o ${DMZ} -m conntrack --ctstate DNAT -j ACCEPT
# The DMZ is assumed compromised. It initiates NOTHING except explicit egress.
-A FORWARD -i ${DMZ} -o ${WAN} -p tcp -m multiport --dports 80,443 -j ACCEPT
-A FORWARD -i ${DMZ} -o ${WAN} -p udp --dport 123 -j ACCEPT
-A FORWARD -i ${DMZ} -o ${LAN} -j LOGDROP
-A FORWARD -j LOGDROP

-A LAN_TO_DMZ -p tcp -m multiport --dports 80,443,22 -m comment --comment "JIRA-4471 ops access" -j ACCEPT
-A LAN_TO_DMZ -j RETURN
-A LAN_TO_WAN -p tcp -m multiport --dports 80,443,587,993 -j ACCEPT
-A LAN_TO_WAN -p udp -m multiport --dports 53,123,443 -j ACCEPT
-A LAN_TO_WAN -j RETURN

# --- Terminal logging chain ---------------------------------------------------
# -m limit here is deliberate and non-negotiable: an unlimited LOG target is a
# self-inflicted DoS (kernel ring buffer + journald + disk I/O in the datapath).
-A LOGDROP -m limit --limit 6/min --limit-burst 12 -j LOG --log-prefix "FW4-DROP: " --log-level 4
-A LOGDROP -j DROP
COMMIT
EOF
```

Aplicalo — **atómicamente**:

```console
$ /usr/local/sbin/fw-build-v4.sh > /etc/iptables/rules.v4.new
$ iptables-restore --test < /etc/iptables/rules.v4.new && echo "syntax OK"
syntax OK
$ mv /etc/iptables/rules.v4.new /etc/iptables/rules.v4
$ iptables-restore -w 10 < /etc/iptables/rules.v4
$ echo $?
0
```

Tres flags que importan:

* `--test` (`-t`) parsea y valida sin aplicar. Ponelo en CI.
* `-w 10` toma el lock de `xtables` con un timeout de 10 s. Sin él, una escritura concurrente de `fail2ban` o `dockerd` falla con `Another app is currently holding the xtables lock`.
* **Sin `-n`** → el restore *reemplaza* cada tabla por completo, atómicamente, por cada `COMMIT`. Con `-n` (noflush) agrega al final. `iptables -F` + un bucle de shell deja una ventana con política `DROP` y cero reglas de aceptación; en una máquina remota esa ventana te deja afuera.

### 3.6 IPv6: `ip6tables` y el problema de ICMPv6

Para un firewall, IPv6 no es "IPv4 con direcciones más largas". **ICMPv6 es estructural.** Descartarlo en bloque rompe la resolución de direcciones (NDP reemplaza a ARP), el descubrimiento de routers, la pertenencia a grupos multicast y el Path MTU Discovery — y los routers IPv6 **no** fragmentan, así que un `packet-too-big` filtrado es un agujero negro duro para cualquier transferencia por encima del MTU de enlace más chico.

El RFC 4890 especifica qué debe pasar. El conjunto mínimo:

```bash
cat <<'EOF' > /etc/iptables/rules.v6
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]
:ICMPV6 - [0:0]
:LOGDROP6 - [0:0]

-A INPUT   -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A INPUT   -m conntrack --ctstate INVALID -j LOGDROP6
-A FORWARD -m conntrack --ctstate INVALID -j LOGDROP6
-A INPUT -i lo -j ACCEPT

-A INPUT   -p ipv6-icmp -j ICMPV6
-A FORWARD -p ipv6-icmp -j ICMPV6

# --- MUST NOT be filtered: error messages (RFC 4890 §4.3.1) -------------------
-A ICMPV6 -p ipv6-icmp --icmpv6-type destination-unreachable -j ACCEPT
-A ICMPV6 -p ipv6-icmp --icmpv6-type packet-too-big          -j ACCEPT
-A ICMPV6 -p ipv6-icmp --icmpv6-type time-exceeded           -j ACCEPT
-A ICMPV6 -p ipv6-icmp --icmpv6-type parameter-problem       -j ACCEPT

# --- NDP. Hop limit 255 is the link-local security check: a packet that
# --- crossed a router cannot have HL=255, so this blocks off-link spoofing.
-A ICMPV6 -p ipv6-icmp --icmpv6-type router-solicitation     -m hl --hl-eq 255 -j ACCEPT
-A ICMPV6 -p ipv6-icmp --icmpv6-type router-advertisement    -m hl --hl-eq 255 -j ACCEPT
-A ICMPV6 -p ipv6-icmp --icmpv6-type neighbour-solicitation  -m hl --hl-eq 255 -j ACCEPT
-A ICMPV6 -p ipv6-icmp --icmpv6-type neighbour-advertisement -m hl --hl-eq 255 -j ACCEPT
-A ICMPV6 -p ipv6-icmp --icmpv6-type redirect                -m hl --hl-eq 255 -j ACCEPT

# --- MLD: link-local scope only ----------------------------------------------
-A ICMPV6 -p ipv6-icmp -s fe80::/10 --icmpv6-type 130 -j ACCEPT
-A ICMPV6 -p ipv6-icmp -s fe80::/10 --icmpv6-type 131 -j ACCEPT
-A ICMPV6 -p ipv6-icmp -s fe80::/10 --icmpv6-type 132 -j ACCEPT
-A ICMPV6 -p ipv6-icmp -s fe80::/10 --icmpv6-type 143 -j ACCEPT

-A ICMPV6 -p ipv6-icmp --icmpv6-type echo-request -m hashlimit --hashlimit-mode srcip \
    --hashlimit-above 5/sec --hashlimit-burst 10 --hashlimit-name icmp6 -j DROP
-A ICMPV6 -p ipv6-icmp --icmpv6-type echo-request -j ACCEPT
-A ICMPV6 -p ipv6-icmp --icmpv6-type echo-reply   -j ACCEPT
-A ICMPV6 -j LOGDROP6

# --- DHCPv6 client ------------------------------------------------------------
-A INPUT -p udp --dport 546 -d fe80::/10 -j ACCEPT

# --- Routing Header type 0 is deprecated and an amplification vector ----------
-A INPUT   -m rt --rt-type 0 -j DROP
-A FORWARD -m rt --rt-type 0 -j DROP

# --- IPv6 has no NAT to hide behind: every host is globally addressable. -----
-A FORWARD -d 2001:db8:2::/64 -p tcp -m multiport --dports 80,443 -j ACCEPT
-A FORWARD -i eth2 -o eth1 -j LOGDROP6
-A FORWARD -j LOGDROP6

-A LOGDROP6 -m limit --limit 6/min --limit-burst 12 -j LOG --log-prefix "FW6-DROP: " --log-level 4
-A LOGDROP6 -j DROP
COMMIT
EOF

ip6tables-restore --test < /etc/iptables/rules.v6 && ip6tables-restore -w 10 < /etc/iptables/rules.v6
```

| Construcción IPv4 | Equivalente IPv6 | Trampa |
|---|---|---|
| `-p icmp --icmp-type` | `-p ipv6-icmp --icmpv6-type` (`-m icmp6`) | `-p icmp` en `ip6tables` es un error |
| `-m ttl --ttl-eq` | `-m hl --hl-eq` | Nombre de módulo distinto |
| `-f` (fragmento) | `-m frag --fragfirst/--fragmore/--fragid` | Los fragmentos IPv6 son una cabecera de extensión |
| ARP | NDP = ICMPv6 133–137 | Filtrarlo mata la alcanzabilidad L2 |
| RFC1918 + NAT | GUA + solo firewall | No hay "privado por accidente" |
| — | `-m rt --rt-type 0` | Hay que descartarlo explícitamente |
| MASQUERADE | `MASQUERADE` existe (NAT66, ≥ 3.7) | Disponible pero casi nunca correcto |

**Regla de doble pila:** cualquier cambio en `rules.v4` que no se refleje en `rules.v6` es un bug. Imponelo en CI (§11.3).

---

## 4. Seguimiento de conexiones

### 4.1 Qué almacena conntrack

Una entrada por **flujo**, indexada por dos tuplas (original y respuesta). `~320 bytes` cada una, más el bucket de hash.

```console
$ conntrack -L -p tcp --dport 443 2>/dev/null | head -3
tcp      6 431987 ESTABLISHED src=10.20.4.51 dst=93.184.216.34 sport=51244 dport=443 src=93.184.216.34 dst=203.0.113.10 sport=443 dport=51244 [ASSURED] mark=0 use=1
tcp      6 119 TIME_WAIT src=10.20.4.51 dst=140.82.121.4 sport=49882 dport=443 src=140.82.121.4 dst=203.0.113.10 sport=443 dport=49882 [ASSURED] mark=0 use=1
tcp      6 59 SYN_SENT src=10.20.9.7 dst=203.0.113.99 sport=44120 dport=443 [UNREPLIED] src=203.0.113.99 dst=203.0.113.10 sport=443 dport=44120 mark=0 use=1
conntrack v1.4.7 (conntrack-tools): 3 flow entries have been shown.
```

Cómo leer los campos:

* `tcp 6` — nombre y número del protocolo.
* `431987` — segundos restantes en el temporizador de la entrada.
* `ESTABLISHED` — el estado **de la máquina de estados de TCP**, *no* el `ctstate` que matchean tus reglas.
* Primera tupla = dirección original; segunda = dirección de respuesta. **La tupla de respuesta muestra la traducción de NAT**: acá `src=93.184.216.34 dst=203.0.113.10` prueba que se aplicó SNAT a `203.0.113.10`.
* `[UNREPLIED]` — todavía no volvió nada. Una tabla llena de `SYN_SENT [UNREPLIED]` = te están escaneando, o tu egreso está roto.
* `[ASSURED]` — el flujo completó un intercambio bidireccional. **Solo las entradas que no son `ASSURED` son desalojadas por early-drop cuando la tabla se llena.** Por eso un SYN flood de entradas sin respuesta igual puede expulsar conexiones reales una vez que llena la tabla.

### 4.2 `ctstate` vs estado TCP — la confusión clásica

| `--ctstate` | Significa |
|---|---|
| `NEW` | Primer paquete que netfilter ve para esta tupla. **No necesariamente un SYN** — con `nf_conntrack_tcp_loose=1` (por defecto), un ACK en medio del stream también crea una entrada `NEW`, así que el firewall puede retomar flujos después de un reinicio |
| `ESTABLISHED` | Un paquete perteneciente a un flujo que vio tráfico en ambas direcciones |
| `RELATED` | Un flujo *nuevo* que un helper o el manejo de errores ICMP asoció con uno existente (canal de datos de FTP, `dest-unreachable` ICMP para un flujo trackeado) |
| `INVALID` | No se puede clasificar. Descartalo |
| `UNTRACKED` | Se aplicó `NOTRACK` en la tabla `raw` |
| `SNAT` / `DNAT` | Estados virtuales: la tupla de respuesta/original fue traducida |

**Nota de hardening:** `-p tcp -m conntrack --ctstate NEW ! --syn -j DROP` cierra el agujero de `tcp_loose`, al costo de romper la recuperación de flujos tras un vaciado de conntrack. En un par HA con `conntrackd` querés esta regla; en una máquina standalone probablemente no.

### 4.3 Dimensionamiento y tuning — la caída que podés prevenir con tres sysctls

```console
$ sysctl net.netfilter.nf_conntrack_max net.netfilter.nf_conntrack_count
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_count = 194883

$ cat /sys/module/nf_conntrack/parameters/hashsize
65536

$ conntrack -S
cpu=0   found=0 invalid=1204 insert=0 insert_failed=118 drop=118 early_drop=0 error=0 search_restart=9214 clash_resolve=41 chaintoolong=0
cpu=1   found=0 invalid=987  insert=0 insert_failed=96  drop=96  early_drop=0 error=0 search_restart=8877 clash_resolve=38 chaintoolong=0
```

`insert_failed` creciendo en una máquina con NAT es **agotamiento de tuplas de SNAT**, no agotamiento de la tabla. Se arregla con `--random-fully` y más direcciones de origen, no con una tabla más grande.

```ini
# /etc/sysctl.d/80-conntrack.conf
#
# Sizing: entries × ~320 B. 1 048 576 entries ≈ 336 MB resident.
# Rule of thumb for a NAT gateway: nf_conntrack_max = 4 × nf_conntrack_buckets,
# and buckets sized so the average chain length stays ≈ 4.
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_expect_max = 8192

# Default established timeout is 432000 s = 5 DAYS. On a busy NAT box this is
# the single biggest cause of table growth: dead flows squat for five days.
# 24 h still outlives any sane keepalive; pair it with TCP keepalives on hosts.
net.netfilter.nf_conntrack_tcp_timeout_established = 86400
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_syn_sent = 30
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 120
net.netfilter.nf_conntrack_icmp_timeout = 15
net.netfilter.nf_conntrack_generic_timeout = 120

# Strict window tracking. Set to 1 ONLY if you have documented asymmetric
# routing you cannot fix; it disables the out-of-window check and weakens
# sequence-number validation.
net.netfilter.nf_conntrack_tcp_be_liberal = 0

# Do not pick up mid-stream flows. Requires conntrackd for HA failover.
net.netfilter.nf_conntrack_tcp_loose = 0

# Automatic helper assignment is a known attack surface: an attacker who can
# reach a port a helper attaches to can open RELATED pinholes. Kernels >= 4.7
# default this to 0. Assign helpers explicitly with -j CT --helper.
net.netfilter.nf_conntrack_helper = 0

net.netfilter.nf_conntrack_log_invalid = 0
net.netfilter.nf_conntrack_acct = 1
net.netfilter.nf_conntrack_timestamp = 1

net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
# accept_ra=2 keeps SLAAC working on an interface that also forwards.
net.ipv6.conf.eth0.accept_ra = 2
net.ipv4.conf.all.log_martians = 1
net.ipv4.tcp_syncookies = 1
```

La cantidad de buckets de hash es un **parámetro de módulo**, no un sysctl, y debe fijarse en el momento de la carga:

```console
$ echo 'options nf_conntrack hashsize=262144' > /etc/modprobe.d/nf_conntrack.conf
$ sysctl --system >/dev/null && systemctl restart systemd-modules-load
$ cat /sys/module/nf_conntrack/parameters/hashsize
262144
```

`hashsize` también se puede escribir en caliente (`echo 262144 > /sys/module/nf_conntrack/parameters/hashsize`) — esto rehashea toda la tabla y frena brevemente el datapath. Hacelo en una ventana de mantenimiento.

### 4.4 Alertas

No alertes sobre el valor absoluto de `nf_conntrack_count`. Alertá sobre el **ratio de utilización** y sobre los deltas de `insert_failed`/`drop`:

```console
$ awk -v c="$(cat /proc/sys/net/netfilter/nf_conntrack_count)" \
      -v m="$(cat /proc/sys/net/netfilter/nf_conntrack_max)" \
      'BEGIN{printf "conntrack utilisation: %.1f%% (%d/%d)\n", c/m*100, c, m}'
conntrack utilisation: 74.3% (194883/262144)
```

Alertá al 80 %. El kernel empieza a hacer early-drop de las entradas no `ASSURED` antes de empezar a loguear `table full`, así que para cuando `dmesg` se queja ya venís descartando conexiones nuevas en silencio.

### 4.5 Bypass selectivo con `NOTRACK`

Para una clase de flujo donde genuinamente no necesitás estado — un servidor DNS autoritativo a 500 kpps, una capa de balanceo L3 sin estado — conntrack es puro costo.

```bash
iptables -t raw -A PREROUTING -i eth0 -p udp --dport 53 -d 203.0.113.53 -j CT --notrack
iptables -t raw -A OUTPUT     -o eth0 -p udp --sport 53 -s 203.0.113.53 -j CT --notrack
# UNTRACKED packets never match ESTABLISHED, so the fast-path rule will not
# accept them: you MUST write explicit stateless accepts for both directions.
iptables -A INPUT  -p udp --dport 53 -d 203.0.113.53 -m conntrack --ctstate UNTRACKED -j ACCEPT
iptables -A OUTPUT -p udp --sport 53 -s 203.0.113.53 -m conntrack --ctstate UNTRACKED -j ACCEPT
```

---

## 5. NAT

### 5.1 Elección del target

| Target | Tabla/cadena | Reescribe | Usalo cuando |
|---|---|---|---|
| `SNAT --to-source A[:p1-p2]` | `nat`/POSTROUTING | origen | La IP de egreso es **estática** — más barato, sobrevive a un flap del enlace |
| `MASQUERADE` | `nat`/POSTROUTING | origen = IP primaria de la interfaz de salida | La IP de egreso es **dinámica** (DHCP/PPPoE). Vacía conntrack cuando cae el enlace |
| `DNAT --to-destination B[:port]` | `nat`/PREROUTING, OUTPUT | destino | Publicar un servicio |
| `REDIRECT --to-ports N` | `nat`/PREROUTING, OUTPUT | destino = la máquina local | Proxy transparente en el mismo host |
| `NETMAP --to CIDR` | `nat`/ambas | prefijo de red 1:1 | Interconexión de subredes solapadas, peering de VPN |
| `TPROXY --on-port N --tproxy-mark` | `mangle`/PREROUTING | nada (redirección a socket) | Proxy transparente preservando el destino original |

`MASQUERADE` recalcula la dirección de origen por paquete y registra un notificador para descartar entradas de conntrack cuando la interfaz cae. `SNAT` no hace ninguna de las dos. En una máquina con dirección WAN estática, `SNAT` es medible­mente más barato y no derriba flujos ante un evento de una interfaz no relacionada.

### 5.2 Las reglas que no son obvias

1. **NAT es solo para el primer paquete.** Los contadores de `iptables -t nat -vnL` muestran *conexiones*, no paquetes. Una regla DNAT con `pkts=48` atendió 48 conexiones.
2. **Una cadena `nat` sin regla coincidente es `ACCEPT` por política** — pero conntrack igual registra "sin NAT" para ese flujo. Agregar una regla de NAT después no la aplica retroactivamente.
3. **El tráfico con DNAT en `FORWARD` lleva el destino *posterior* al DNAT** (DNAT está en −100, filter en 0). Escribí `-d 192.0.2.20`, no `-d 203.0.113.10`.
4. **El tráfico con SNAT en `FORWARD` lleva el origen *previo* al SNAT** (SNAT en +100). Escribí `-s 10.20.0.0/16`.
5. **`-m conntrack --ctstate DNAT`** es la forma limpia de decir "cualquier cosa que haya sido redirigida por port-forward", sin duplicar la lista de direcciones.

### 5.3 Verificar un camino de NAT de punta a punta

```console
$ iptables -t nat -vnL PREROUTING --line-numbers
Chain PREROUTING (policy ACCEPT 8214 packets, 512K bytes)
num   pkts bytes target     prot opt in     out     source               destination
1      481 28860 DNAT       tcp  --  eth0   *       0.0.0.0/0            203.0.113.10         tcp dpt:443 to:192.0.2.20:443
2       12   720 DNAT       tcp  --  eth0   *       0.0.0.0/0            203.0.113.10         tcp dpt:25 to:192.0.2.30:25

$ conntrack -L -d 203.0.113.10 -p tcp --dport 443 2>/dev/null | head -1
tcp      6 431994 ESTABLISHED src=198.51.100.7 dst=203.0.113.10 sport=52310 dport=443 src=192.0.2.20 dst=198.51.100.7 sport=443 dport=52310 [ASSURED] mark=0 use=1
```

La tupla de respuesta `src=192.0.2.20` es la prueba de que el DNAT tuvo efecto. Si la tupla de respuesta sigue diciendo `src=203.0.113.10`, la regla no matcheó — revisá interfaz, dirección, y si una regla anterior en `nat/PREROUTING` ya terminó el recorrido.

```console
$ conntrack -E -e NEW -p tcp --dport 443 --any-nat
    [NEW] tcp      6 120 SYN_SENT src=198.51.100.7 dst=203.0.113.10 sport=52444 dport=443 [UNREPLIED] src=192.0.2.20 dst=198.51.100.7 sport=443 dport=52444
```

El streaming de eventos en vivo es la forma más rápida de responder "¿mi regla de NAT está matcheando siquiera?" — no necesita resetear contadores ni reglas de log.

### 5.4 Agotamiento de puertos de SNAT

Una sola dirección origen de SNAT te da ~64 000 tuplas **por cada par IP:puerto de destino**. Contra un solo upstream ocupado (un endpoint de S3, una API de pagos) ese techo es real.

```bash
# Spread across a pool. --persistent keeps a given client on a given source IP,
# which some upstreams' session affinity requires.
iptables -t nat -A POSTROUTING -s 10.20.0.0/16 -o eth0 \
    -j SNAT --to-source 203.0.113.10-203.0.113.14 --random-fully --persistent
```

| Síntoma | Métrica | Solución |
|---|---|---|
| `connect: Cannot assign requested address` intermitente | `insert_failed` en aumento | Pool de SNAT más grande, `--random-fully` |
| Tabla llena, `count` en `max` | `nf_conntrack_count` ≈ `nf_conntrack_max` | Subir `max` **y** bajar `tcp_timeout_established` |
| Funciona un rato tras el reinicio y después falla | Entradas `TIME_WAIT` dominando | Bajar `tcp_timeout_time_wait` a 30–60 s |

---

## 6. `ipset`

### 6.1 Por qué existe

Una cadena lineal de 5 000 reglas `-s <cidr> -j DROP` es O(N) **por paquete**. Un `ipset` es un hash/bitmap del kernel consultado en O(1), matcheado con una sola regla y actualizable **sin tocar el ruleset para nada** — lo que significa que las actualizaciones de feeds de amenazas nunca toman el lock de `xtables` ni arriesgan un restore fallido.

### 6.2 Tipos

| Tipo | Clave | Uso típico |
|---|---|---|
| `hash:ip` | dirección | fail2ban, lista de bloqueo por host |
| `hash:net` | CIDR (intervalo) | Feeds de amenazas, bogons, geobloqueos |
| `hash:ip,port` | dirección + proto/puerto | ACL de servicio por host |
| `hash:net,port` | CIDR + proto/puerto | ACL a nivel de segmento |
| `hash:ip,port,ip` | cliente + servicio + servidor | Microsegmentación de tres tuplas |
| `hash:net,iface` | CIDR + interfaz | Borde multi-tenant |
| `hash:mac`, `hash:ip,mac` | MAC | Control de admisión L2 (con `ebtables`/bridge) |
| `bitmap:port` | rango de puertos ≤ 65536 | El conjunto de puertos más denso posible |
| `list:set` | conjunto de conjuntos | Componer feeds; se evalúa en orden, soporta `nomatch` |

Opciones: `timeout` (TTL por elemento), `counters`, `comment`, `skbinfo` (transportar mark/prio/queue), `hashsize`, `maxelem`, `family inet|inet6`, `nomatch` (excepción por elemento dentro de un `hash:net`).

**Restricción dura:** un set tiene exactamente **una** familia. Necesitás `blocklist4` *y* `blocklist6`. No existe el set de doble pila.

### 6.3 Creación y uso

```console
$ ipset create blocklist4 hash:net family inet hashsize 4096 maxelem 262144 timeout 86400 counters comment
$ ipset create blocklist6 hash:net family inet6 hashsize 1024 maxelem 65536 timeout 86400 counters comment
$ ipset create mgmt_bastions hash:ip family inet comment
$ ipset add mgmt_bastions 10.20.0.10 comment "bastion-a"
$ ipset add mgmt_bastions 10.20.0.11 comment "bastion-b"

$ ipset add blocklist4 185.220.101.0/24 timeout 604800 comment "tor-exit feed 2026-08-20"
$ ipset add blocklist4 203.0.113.0/24 comment "corp range - permanent"
# Punch an exception INSIDE a blocked prefix. Only valid on hash:net.
$ ipset add blocklist4 203.0.113.77 nomatch comment "partner VPN endpoint"

$ ipset list blocklist4 -t
Name: blocklist4
Type: hash:net
Revision: 7
Header: family inet hashsize 4096 maxelem 262144 timeout 86400 counters comment bucketsize 12 initval 0x7f3a92c1
Size in memory: 452608
References: 2
Number of entries: 8421

$ ipset test blocklist4 185.220.101.44
185.220.101.44 is in set blocklist4
$ ipset test blocklist4 203.0.113.77
203.0.113.77 is NOT in set blocklist4
$ echo $?
1
```

Referencialo desde exactamente una regla por cadena:

```bash
iptables  -I INPUT   1 -m set --match-set blocklist4 src -j DROP
iptables  -I FORWARD 1 -m set --match-set blocklist4 src -j DROP
ip6tables -I INPUT   1 -m set --match-set blocklist6 src -j DROP
ip6tables -I FORWARD 1 -m set --match-set blocklist6 src -j DROP

# Two-dimensional match: source IP AND destination port, in one lookup.
ipset create db_clients hash:ip,port family inet
ipset add db_clients 10.20.4.0,tcp:5432   # hash:ip accepts a /24 only in hash:net
iptables -A FORWARD -m set --match-set db_clients src,dst -j ACCEPT
```

`src,dst` se lee de izquierda a derecha contra las dimensiones del set: primera dimensión ← origen, segunda ← destino.

### 6.4 Actualizaciones atómicas de feeds — el idioma `swap`

Nunca hagas `ipset flush` sobre un set en vivo: eso es una ventana con cero entradas.

```bash
#!/usr/bin/env bash
# /usr/local/sbin/refresh-blocklist.sh
set -euo pipefail
FEED_URL="https://internal.example.net/feeds/threat-v4.txt"
TMP=blocklist4_tmp

curl -fsS --max-time 30 "$FEED_URL" > /run/feed4.txt
# Sanity gate: a truncated feed must not become an empty firewall.
lines=$(grep -cE '^[0-9]+\.' /run/feed4.txt || true)
[ "$lines" -ge 100 ] || { echo "feed too small ($lines), aborting" >&2; exit 1; }

ipset destroy "$TMP" 2>/dev/null || true
ipset create "$TMP" hash:net family inet hashsize 4096 maxelem 262144 timeout 86400 counters comment
{
  while read -r cidr; do
    printf 'add %s %s timeout 86400 comment "feed %s"\n' "$TMP" "$cidr" "$(date -I)"
  done < <(grep -E '^[0-9]+\.' /run/feed4.txt)
} | ipset restore -exist

# swap is atomic in the kernel: the rule referencing blocklist4 never sees a gap.
ipset swap "$TMP" blocklist4
ipset destroy "$TMP"
ipset save > /etc/ipset.conf
logger -t fw "blocklist4 refreshed: $(ipset list blocklist4 -t | awk '/Number of entries/{print $4}') entries"
```

```console
$ /usr/local/sbin/refresh-blocklist.sh
$ ipset list blocklist4 -t | grep -E 'Number|References'
References: 2
Number of entries: 9137
```

**`References: 2`** significa que dos reglas vivas de netfilter apuntan a él. `ipset destroy` sobre un set con `References > 0` falla con `Set cannot be destroyed: it is in use by a kernel component` — ese conteo de referencias es lo que hace seguro al swap.

### 6.5 Persistencia

```console
$ ipset save > /etc/ipset.conf
$ head -4 /etc/ipset.conf
create blocklist4 hash:net family inet hashsize 4096 maxelem 262144 timeout 86400 counters comment bucketsize 12 initval 0x7f3a92c1
add blocklist4 185.220.101.0/24 timeout 601233 comment "tor-exit feed 2026-08-20"
add blocklist4 203.0.113.0/24 comment "corp range - permanent"
add blocklist4 203.0.113.77 nomatch comment "partner VPN endpoint"
```

**El orden de arranque es una trampa real:** `iptables-restore` falla duro si un set referenciado todavía no existe (`Set blocklist4 doesn't exist`). Los sets deben restaurarse **antes** que el ruleset — ver las unidades de systemd en §11.2.

---

## 7. `nftables`

El examen pide "conocimiento básico". La producción pide fluidez: nftables es el backend por defecto en RHEL 9+, Debian 11+, SUSE 15+, y el único backend de `firewalld` desde la 1.0.

### 7.1 Qué cambió realmente

| Dimensión | iptables (`x_tables`) | nftables |
|---|---|---|
| Frontera kernel/usuario | Un match/target = un módulo de kernel | Una VM genérica (`nf_tables`) + bytecode |
| Familias de direcciones | Binarios separados: `iptables`, `ip6tables`, `arptables`, `ebtables` | Una herramienta; familias `ip`, `ip6`, `inet`, `arp`, `bridge`, `netdev` |
| Doble pila | Dos rulesets, sincronizados a mano | `table inet` — **una regla cubre ambas** |
| Tablas/cadenas | Fijas, incorporadas, siempre presentes | Definidas por el usuario; una cadena existe solo si la creás |
| Actualización de reglas | Una syscall por regla; ruleset completo vía `restore` | **Transacciones atómicas** — el lote entero se commitea o nada |
| Sets | Externos (`ipset`) | Nativos, de primera clase, tipados, con intervalos y concatenaciones |
| Maps / verdict maps | ninguno | `dnat to tcp dport map {...}`, `jump vmap {...}` |
| Contadores | Implícitos en cada regla | Explícitos — las reglas sin `counter` son más baratas |
| Múltiples acciones por regla | No (un solo `-j`) | Sí: `counter log accept` |
| Flow offload | ninguno | `flowtable` (por software y por hardware) |
| Trazado | `TRACE` → `dmesg` | `nft monitor trace`, estructurado |

### 7.2 Elementos esenciales de sintaxis

```console
$ nft add table inet fw
$ nft add chain inet fw input '{ type filter hook input priority filter; policy drop; }'
$ nft add rule inet fw input ct state established,related accept
$ nft list ruleset
table inet fw {
	chain input {
		type filter hook input priority filter; policy drop;
		ct state established,related accept
	}
}

$ nft -a list chain inet fw input
table inet fw {
	chain input { # handle 1
		type filter hook input priority filter; policy drop;
		ct state established,related accept # handle 4
	}
}
$ nft delete rule inet fw input handle 4
```

Las reglas se direccionan por **handle**, no por índice. `nft -a` los imprime. `nft insert` antepone; `nft add` agrega al final; `nft replace rule ... handle N ...` reemplaza en el lugar.

Prioridades de cadena con nombre: `raw` (−300), `mangle` (−150), `dstnat` (−100), `filter` (0), `security` (50), `srcnat` (100). Usá los nombres, no los números.

### 7.3 Un ruleset de producción completo — DMZ de tres patas, doble pila, HA

```nft
#!/usr/sbin/nft -f
# /etc/nftables.conf
# Dual-stack, three-legged DMZ edge firewall. Applied atomically:
#   nft -c -f /etc/nftables.conf   (check)
#   nft -f /etc/nftables.conf      (commit — flush+load in ONE transaction)

flush ruleset

define WAN  = "eth0"
define LAN  = "eth1"
define DMZ  = "eth2"
define SYNC = "eth3"

define LAN4 = 10.20.0.0/16
define DMZ4 = 192.0.2.0/24
define LAN6 = 2001:db8:20::/48
define DMZ6 = 2001:db8:2::/64

define VIP4 = 203.0.113.10
define WEB4 = 192.0.2.20
define MTA4 = 192.0.2.30
define WEB6 = 2001:db8:2::20

table inet fw {

    # ---- Sets: O(1)/O(log n) lookups, updatable without touching rules ------
    set blocklist4 {
        type ipv4_addr
        flags interval, timeout
        auto-merge
        timeout 24h
        gc-interval 10m
    }

    set blocklist6 {
        type ipv6_addr
        flags interval, timeout
        auto-merge
        timeout 24h
        gc-interval 10m
    }

    set bastions4 {
        type ipv4_addr
        elements = { 10.20.0.10, 10.20.0.11 }
    }

    set martians4 {
        type ipv4_addr
        flags interval
        elements = {
            0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8,
            169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.0.2.0/24,
            192.168.0.0/16, 198.18.0.0/15, 198.51.100.0/24,
            203.0.113.0/24, 224.0.0.0/4, 240.0.0.0/4
        }
    }

    # Per-source SYN rate limiting, stateful, in-kernel, self-expiring.
    set ssh_flood {
        type ipv4_addr
        flags dynamic, timeout
        timeout 10m
        size 65536
    }

    # ---- Maps: policy as data ------------------------------------------------
    map dmz_services4 {
        type inet_service : ipv4_addr
        elements = { 443 : 192.0.2.20, 80 : 192.0.2.20, 25 : 192.0.2.30 }
    }

    # ---- Flowtable: software fast path ---------------------------------------
    # After a flow is ESTABLISHED it is offloaded and skips the whole forward
    # chain per packet. Add `flags offload` only if every listed NIC supports
    # hardware offload (check: ethtool -k <dev> | grep hw-tc-offload).
    flowtable ft {
        hook ingress priority filter
        devices = { eth0, eth1, eth2 }
        counter
    }

    # ---- Reusable chains ------------------------------------------------------
    chain logdrop {
        limit rate 6/minute burst 12 packets \
            log prefix "FW-DROP: " level warn flags all
        counter drop
    }

    chain icmp_ok {
        # IPv4
        icmp type { destination-unreachable, time-exceeded, parameter-problem } accept
        icmp type echo-request limit rate over 5/second burst 10 packets drop
        icmp type echo-request accept

        # IPv6 error messages: MUST pass (RFC 4890 §4.3.1).
        icmpv6 type { destination-unreachable, packet-too-big,
                      time-exceeded, parameter-problem } accept

        # NDP: hop limit 255 proves the packet did not cross a router.
        icmpv6 type { nd-router-solicit, nd-router-advert,
                      nd-neighbor-solicit, nd-neighbor-advert,
                      nd-redirect } ip6 hoplimit 255 accept

        # MLD: link-local scope only.
        ip6 saddr fe80::/10 icmpv6 type { mld-listener-query,
                                          mld-listener-report,
                                          mld-listener-done,
                                          mld2-listener-report } accept

        icmpv6 type echo-request limit rate over 5/second burst 10 packets drop
        icmpv6 type { echo-request, echo-reply } accept
        return
    }

    chain lan_to_wan {
        tcp dport { 80, 443, 587, 993 } counter accept \
            comment "JIRA-4471 baseline user egress"
        udp dport { 53, 123, 443 } counter accept
        return
    }

    chain lan_to_dmz {
        tcp dport { 22, 80, 443 } counter accept comment "ops access"
        return
    }

    chain dmz_to_wan {
        # The DMZ is assumed compromised. Explicit egress only: this is the
        # rule that turns a web-shell into a dead end instead of a beachhead.
        tcp dport { 80, 443 } counter accept comment "package + API egress"
        udp dport 123 counter accept comment "NTP"
        return
    }

    # ---- Base chains -----------------------------------------------------------
    chain prerouting_raw {
        type filter hook prerouting priority raw; policy accept;
        iifname { "lo", $SYNC } notrack
        # Bogon/martian ingress filter, before conntrack allocates an entry.
        iifname $WAN ip saddr @martians4 counter drop
        iifname $WAN ip6 saddr { ::/128, ::1/128, ::ffff:0:0/96, 2001:db8::/32 } counter drop
    }

    chain input {
        type filter hook input priority filter; policy drop;

        # Fast path first: one conntrack lookup, then done.
        ct state vmap { established : accept, related : accept, invalid : drop }

        iifname "lo" accept

        ip  saddr @blocklist4 counter drop
        ip6 saddr @blocklist6 counter drop

        # Stateless anti-spoofing that honours policy-routing marks.
        fib saddr . mark . iif oif missing counter jump logdrop

        meta l4proto { icmp, ipv6-icmp } jump icmp_ok

        # SSH: rate-limit per source into a dynamic set, then drop repeat offenders.
        iifname { $WAN, $LAN } tcp dport 22 ct state new \
            add @ssh_flood { ip saddr limit rate 4/minute burst 4 packets } \
            ip saddr @bastions4 accept
        iifname { $WAN, $LAN } tcp dport 22 ct state new counter jump logdrop

        # HA plane.
        iifname $LAN ip protocol vrrp accept
        iifname $SYNC ip saddr 10.99.0.0/30 udp dport 3780 accept

        # Node exporter, from monitoring only.
        iifname $LAN ip saddr 10.20.9.0/24 tcp dport 9100 accept

        counter jump logdrop
    }

    chain forward {
        type filter hook forward priority filter; policy drop;

        # Offload established flows to the flowtable fast path.
        meta l4proto { tcp, udp } ct state established flow add @ft counter

        ct state vmap { established : accept, related : accept, invalid : drop }

        ip  saddr @blocklist4 counter drop
        ip6 saddr @blocklist6 counter drop

        # Ingress spoofing: WAN must never carry our internal sources.
        iifname $WAN ip  saddr { $LAN4, $DMZ4 } counter jump logdrop
        iifname $WAN ip6 saddr { $LAN6, $DMZ6 } counter jump logdrop

        meta l4proto { icmp, ipv6-icmp } jump icmp_ok

        # Published DMZ services. ct status dnat covers the v4 port-forwards
        # without restating the address list; IPv6 is routed, not NAT'd.
        iifname $WAN oifname $DMZ ct status dnat counter accept
        iifname $WAN oifname $DMZ ip6 daddr $WEB6 tcp dport { 80, 443 } counter accept

        iifname $LAN oifname $WAN jump lan_to_wan
        iifname $LAN oifname $DMZ jump lan_to_dmz
        iifname $DMZ oifname $WAN jump dmz_to_wan

        # The rule the whole DMZ design exists for.
        iifname $DMZ oifname $LAN counter jump logdrop \
            comment "DMZ must never initiate into the trusted zone"

        counter jump logdrop
    }

    chain output {
        type filter hook output priority filter; policy accept;
        ct state invalid counter drop
    }

    chain forward_mangle {
        type filter hook forward priority mangle; policy accept;
        tcp flags syn / syn,rst tcp option maxseg size set rt mtu \
            comment "MSS clamp - prevents PMTUD blackholes downstream"
    }

    # ---- NAT ------------------------------------------------------------------
    chain prerouting_nat {
        type nat hook prerouting priority dstnat; policy accept;
        iifname $WAN ip daddr $VIP4 tcp dport { 443, 80, 25 } \
            counter dnat ip to tcp dport map @dmz_services4
        # Hairpin: LAN clients resolving the public name.
        iifname $LAN ip daddr $VIP4 tcp dport { 443, 80 } \
            counter dnat ip to tcp dport map @dmz_services4
    }

    chain postrouting_nat {
        type nat hook postrouting priority srcnat; policy accept;
        # Hairpin return path.
        ip saddr $LAN4 ip daddr $WEB4 tcp dport { 443, 80 } counter snat ip to 192.0.2.1
        # Egress. fully-random avoids sequential source-port collisions.
        oifname $WAN ip saddr $LAN4 counter snat ip to $VIP4 fully-random
        oifname $WAN ip saddr $DMZ4 counter snat ip to 203.0.113.11 fully-random
        # No IPv6 NAT: DMZ and LAN hold globally routable prefixes, filtered above.
    }
}
```

```console
$ nft -c -f /etc/nftables.conf && echo "ruleset valid"
ruleset valid
$ nft -f /etc/nftables.conf
$ nft list table inet fw | head -12
table inet fw {
	set blocklist4 {
		type ipv4_addr
		flags interval,timeout
		timeout 1d
		gc-interval 10m
		auto-merge
	}
...
```

**`flush ruleset` dentro del archivo es seguro**, a diferencia de `iptables -F` en la línea de comandos: el flush y la recarga son una sola transacción atómica. No hay ventana.

### 7.4 Manipulación de sets en tiempo de ejecución

```console
$ nft add element inet fw blocklist4 '{ 185.220.101.0/24 timeout 7d }'
$ nft add element inet fw blocklist4 '{ 45.155.205.0/24 }'
$ nft list set inet fw blocklist4
table inet fw {
	set blocklist4 {
		type ipv4_addr
		flags interval,timeout
		timeout 1d
		gc-interval 10m
		auto-merge
		elements = { 45.155.205.0/24 expires 23h58m12s,
			     185.220.101.0/24 timeout 7d expires 6d23h58m4s }
	}
}
$ nft delete element inet fw blocklist4 '{ 45.155.205.0/24 }'
$ nft list set inet fw ssh_flood
table inet fw {
	set ssh_flood {
		type ipv4_addr
		size 65536
		flags dynamic,timeout
		timeout 10m
		elements = { 198.51.100.44 expires 9m12s }
	}
}
```

`auto-merge` fusiona automáticamente intervalos adyacentes o solapados — el feed puede venir sucio y el set del kernel se mantiene mínimo.

### 7.5 Camino de migración desde iptables

```console
$ iptables-translate -A INPUT -p tcp --dport 443 -m conntrack --ctstate NEW -j ACCEPT
nft 'add rule ip filter INPUT tcp dport 443 ct state new counter accept'

$ iptables-save > /tmp/rules.v4
$ iptables-restore-translate -f /tmp/rules.v4 > /tmp/ruleset.nft
$ head -6 /tmp/ruleset.nft
# Translated by iptables-restore-translate v1.8.10 on Tue Aug 25 09:14:02 2026
add table ip filter
add chain ip filter INPUT { type filter hook input priority 0; policy drop; }
add chain ip filter FORWARD { type filter hook forward priority 0; policy drop; }
add chain ip filter OUTPUT { type filter hook output priority 0; policy accept; }
add rule ip filter INPUT ct state related,established counter accept
```

La traducción es **mecánica y correcta pero no idiomática**: produce `table ip` + `table ip6` en vez de `table inet`, mantiene cadenas lineales en vez de sets y maps, y emite `counter` en cada regla. Usala para arrancar, y después reescribí a mano hacia la familia `inet` con sets. Esa reescritura es donde está la ganancia real.

### 7.6 Modelo de rendimiento

| Mecanismo | Costo por paquete | Actualización del ruleset | Notas |
|---|---|---|---|
| Cadena lineal de iptables, N reglas | O(N) evaluaciones de match | No atómica por regla; atómica por tabla vía restore | N=3000 es un piso de CPU medible |
| iptables + `ipset` | Búsqueda hash O(1) | Las actualizaciones del set no requieren cambiar el ruleset | El arreglo clásico de escalabilidad |
| Set de nftables (hash) | O(1) | Transacción atómica | Nativo, tipado, con timeouts |
| Set de nftables (intervalo) | O(log n) | Atómica | `flags interval`, árbol rojo-negro |
| Verdict map de nftables | Despacho O(1)/O(log n) | Atómica | Reemplaza una cadena de saltos |
| `flowtable` de nftables (software) | Evita la cadena forward tras el handshake | — | Requiere `ct state established` |
| `flowtable flags offload` | En el hardware de la NIC | — | Necesita soporte del driver; los flujos se vuelven invisibles a los contadores |
| XDP/eBPF | Pre-`skb`, en el driver | Recarga del programa | Fuera del examen, pero es hacia donde va la industria |

Dos consecuencias de diseño:

1. **La regla `ct state established,related accept` debe ser la primera de cada cadena base.** Convierte un ruleset O(N) en una búsqueda O(1) para el 99,9 % de los paquetes.
2. **El offload por flowtable hace que los paquetes sean invisibles para tu filtro y tus contadores.** Ese es justamente el punto, y también es por qué no debés poner lógica de seguridad por paquete aguas abajo de él.

---

## 8. `ebtables` y los planos bridge/netdev

### 8.1 Por qué existe el filtrado L2

En cualquier hipervisor, host de contenedores o nodo de Kubernetes, el tráfico de los guests atraviesa un **bridge por software**, no un router. Puede que los hooks L3 nunca lo vean. `ebtables` (y la familia `bridge` de nftables) filtra tramas Ethernet: direcciones MAC, ARP, etiquetas VLAN, 802.1x y protocolos no-IP por completo.

El uso canónico en producción es el **anti-spoofing para guests no confiables**: impedir que una VM de un inquilino reclame la IP de otro mediante ARP gratuito, o que suplante la MAC del gateway.

### 8.2 Estructura

| Tabla | Cadenas | Propósito |
|---|---|---|
| `filter` | `INPUT`, `OUTPUT`, `FORWARD` | Aceptar/descartar tramas |
| `nat` | `PREROUTING`, `OUTPUT`, `POSTROUTING` | Reescritura de MAC (`dnat`, `snat`, `arpreply`) |
| `broute` | `BROUTING` | Decidir **rutear vs bridgear** por trama — un "brouter" |

```console
$ ebtables -L --Lc
Bridge table: filter

Bridge chain: INPUT, entries: 0, policy: ACCEPT

Bridge chain: FORWARD, entries: 3, policy: DROP
-p ARP -i vnet0 --arp-ip-src 10.20.7.51 --arp-mac-src 52:54:00:a1:b2:c3 -j ACCEPT , pcnt = 412 -- bcnt = 17304
-p IPv4 -i vnet0 --ip-src 10.20.7.51 -j ACCEPT , pcnt = 88401 -- bcnt = 91205118
-i vnet0 -j LOG --log-prefix "L2-SPOOF: " --log-level 4 --log-arp , pcnt = 3 -- bcnt = 126

Bridge chain: OUTPUT, entries: 0, policy: ACCEPT
```

```bash
# Anti-spoofing for guest vnet0 = 52:54:00:a1:b2:c3 / 10.20.7.51
ebtables -P FORWARD DROP
ebtables -A FORWARD -i vnet0 -p ARP --arp-ip-src 10.20.7.51 \
         --arp-mac-src 52:54:00:a1:b2:c3 -j ACCEPT
ebtables -A FORWARD -i vnet0 -p IPv4 -s 52:54:00:a1:b2:c3 --ip-src 10.20.7.51 -j ACCEPT
ebtables -A FORWARD -i vnet0 -j LOG --log-prefix "L2-SPOOF: " --log-arp
ebtables -A FORWARD -o vnet0 -p ARP --arp-ip-dst 10.20.7.51 -j ACCEPT
ebtables -A FORWARD -o vnet0 -p IPv4 --ip-dst 10.20.7.51 -j ACCEPT

ebtables-save > /etc/ebtables.conf
```

La misma política en la familia `bridge` de nftables — una herramienta, una transacción:

```nft
table bridge guests {
    chain forward {
        type filter hook forward priority filter; policy drop;
        iifname "vnet0" arp saddr ip 10.20.7.51 arp saddr ether 52:54:00:a1:b2:c3 accept
        iifname "vnet0" ether saddr 52:54:00:a1:b2:c3 ip saddr 10.20.7.51 accept
        iifname "vnet0" limit rate 6/minute log prefix "L2-SPOOF: " drop
        oifname "vnet0" ip daddr 10.20.7.51 accept
        oifname "vnet0" arp daddr ip 10.20.7.51 accept
    }
}
```

### 8.3 `br_netfilter`: tramas bridgeadas que llegan a `iptables`

```console
$ modprobe br_netfilter
$ sysctl -a 2>/dev/null | grep bridge-nf-call
net.bridge.bridge-nf-call-arptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
```

Con estos en `1`, las tramas IPv4/IPv6 bridgeadas recorren la cadena **L3** `FORWARD` de `iptables`. Esto lo requiere `kube-proxy` en modo iptables (`bridge-nf-call-iptables=1` es un prerrequisito documentado de Kubernetes), y simultáneamente es una fuente común de sorpresa: un bridge "puramente L2" queda de golpe sujeto a política L3. Usá `-m physdev --physdev-in vnet0 --physdev-is-bridged` para escribir reglas que solo matcheen tráfico bridgeado.

### 8.4 La familia `netdev`

nftables agrega una familia sin contraparte en iptables: `netdev`, enganchada en **ingress**, antes de `PREROUTING` y antes de que conntrack asigne nada. Es el lugar más barato para descartar una inundación.

```nft
table netdev ddos {
    chain ingress_eth0 {
        type filter hook ingress device "eth0" priority -500; policy accept;
        # Drop before conntrack, before routing, before allocation.
        ip saddr @blocklist4 counter drop
        ip frag-off & 0x1fff != 0 counter drop comment "no IPv4 fragments at the edge"
        tcp flags & (fin|syn|rst|psh|ack|urg) == 0 counter drop comment "NULL scan"
        tcp flags & (fin|syn) == (fin|syn) counter drop comment "SYN/FIN"
        tcp flags & (fin|rst) == (fin|rst) counter drop comment "FIN/RST"
    }
}
```

---

## 9. `conntrackd`: HA con estado

### 9.1 El problema que resuelve

Dos firewalls, VRRP, una VIP flotante. El primario falla; el backup toma la VIP en ~1 segundo. El ruteo converge. Y **muere toda conexión TCP establecida**, porque la tabla de conntrack del backup está vacía y su ruleset descarta todo lo que no sea `ESTABLISHED`.

`conntrackd` replica la tabla de conntrack entre nodos por un enlace dedicado, para que el failover sea transparente para los flujos.

### 9.2 Modos de sincronización

| Modo | Mecanismo | Compromiso |
|---|---|---|
| `alarm` | Resincronización completa periódica de la caché | Simple, alto ancho de banda, obsolescencia acotada |
| `ftfw` | **F**ault-**t**olerant **f**ire**w**all: protocolo confiable con ACKs y retransmisión sobre el enlace de sync | Valor por defecto recomendado; consistente, ancho de banda moderado |
| `notrack` | Sin protocolo de replicación; se apoya solo en la API de eventos del kernel | Menor sobrecarga, garantías más débiles |

### 9.3 Configuración completa

```ini
# /etc/conntrackd/conntrackd.conf
Sync {
    Mode FTFW {
        # How long a committed entry survives on the backup without refresh.
        DisableExternalCache Off
        # Resend window and timeouts for the reliable protocol.
        ResendQueueSize 131072
        ACKWindowSize 300
        CommitTimeout 180
        PurgeTimeout 60
    }

    # Dedicated L2 sync segment. NEVER share it with data traffic:
    # replicating the replication traffic is a feedback loop.
    UDP {
        IPv4_address 10.99.0.1
        IPv4_Destination_Address 10.99.0.2
        Port 3780
        Interface eth3
        SndSocketBuffer 24985600
        RcvSocketBuffer 24985600
        Checksum on
    }

    # Do not replicate the sync link's own flows, nor loopback.
    Options {
        TCPWindowTracking Off
        ExpectationSync Off
    }
}

General {
    Systemd on
    HashSize 65536
    HashLimit 1048576
    LogFile /var/log/conntrackd.log
    Syslog on
    LockFile /var/lock/conntrack.lock

    UNIX {
        Path /var/run/conntrackd.ctl
        Backlog 20
    }

    NetlinkBufferSize 2097152
    NetlinkBufferSizeMaxGrowth 8388608
    # Drop netlink events rather than stall the kernel if userspace lags.
    NetlinkOverrunResync On
    NetlinkEventsReliable Off

    # Only replicate what matters. Never replicate ICMP or the sync link.
    Filter From Userspace {
        Protocol Accept {
            TCP
            UDP
        }
        Address Ignore {
            IPv4_address 127.0.0.1
            IPv4_address 10.99.0.0/30
            IPv6_address ::1
        }
    }
}
```

```ini
# /etc/keepalived/keepalived.conf
global_defs {
    router_id fw-edge-a
    enable_script_security
    script_user root
}

vrrp_script chk_ruleset {
    script "/usr/local/sbin/fw-healthcheck.sh"
    interval 5
    timeout 3
    rise 2
    fall 2
    weight -40
}

vrrp_instance VI_WAN {
    state MASTER
    interface eth0
    virtual_router_id 51
    priority 150
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass __REDACTED__
    }
    virtual_ipaddress {
        203.0.113.10/28 dev eth0
        2001:db8:1::10/64 dev eth0
    }
    track_script { chk_ruleset }
    notify_master "/etc/conntrackd/primary-backup.sh primary"
    notify_backup "/etc/conntrackd/primary-backup.sh backup"
    notify_fault  "/etc/conntrackd/primary-backup.sh fault"
}

vrrp_instance VI_LAN {
    state MASTER
    interface eth1
    virtual_router_id 52
    priority 150
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass __REDACTED__
    }
    virtual_ipaddress {
        10.20.0.1/16 dev eth1
    }
    track_script { chk_ruleset }
}
```

```bash
#!/usr/bin/env bash
# /etc/conntrackd/primary-backup.sh
# Shipped with conntrack-tools; this is the operational core.
CONNTRACKD_BIN=/usr/sbin/conntrackd
CONNTRACKD_LOCK=/var/lock/conntrack.lock

case "$1" in
  primary)
    # Commit the external cache (peer's state) into THIS kernel, then flush the
    # cache and resync. Without this commit, every replicated flow is lost.
    $CONNTRACKD_BIN -C $CONNTRACKD_CONF -c   # commit external cache -> kernel
    $CONNTRACKD_BIN -f internal              # flush internal cache
    $CONNTRACKD_BIN -R                       # resync with kernel table
    $CONNTRACKD_BIN -B                       # send a bulk update to the peer
    logger -t conntrackd "transition to PRIMARY: external cache committed"
    ;;
  backup)
    $CONNTRACKD_BIN -t                       # shorten kernel timers
    $CONNTRACKD_BIN -n                       # request a full resync from peer
    logger -t conntrackd "transition to BACKUP: requested resync"
    ;;
  fault)
    $CONNTRACKD_BIN -t
    $CONNTRACKD_BIN -n
    logger -t conntrackd "transition to FAULT"
    ;;
esac
```

### 9.4 Verificar la replicación

```console
$ conntrackd -s
cache internal:
current active connections:               42817
connections created:                     918442    failed:            0
connections updated:                    2114093    failed:            0
connections destroyed:                   875625    failed:            0

cache external:
current active connections:               41902
connections created:                     902114    failed:            0
connections updated:                          0    failed:            0
connections destroyed:                   860212    failed:            0

traffic processed:
                   0 Bytes                         0 Pckts

UDP traffic (active device=eth3):
           418829104 Bytes sent                 2914 Bytes recv
              914022 Pckts sent                    41 Pckts recv
                   0 Error send                    0 Error recv

message tracking:
                   0 Malformed msgs                 2 Lost msgs
```

Cómo leerlo:

* **internal** = flujos que este nodo posee. **external** = flujos replicados desde el par.
* `internal ≈ external` en un par sano — los dos nodos convergen. Una brecha grande significa que la replicación está retrasada o que el enlace de sync está saturado.
* `Lost msgs` en aumento = ajustá `NetlinkBufferSize` y `ResendQueueSize`, o el enlace de sync quedó chico.
* En el **backup**, `traffic processed` debería ser ~0. Si no lo es, los dos nodos están reenviando — split brain.

```console
$ conntrackd -e         # dump the external cache
$ conntrackd -i         # dump the internal cache
$ conntrackd -n         # request a resync from the peer
$ conntrackd -c         # commit external cache into the kernel (failover)
```

**Prerrequisito fácil de pasar por alto:** `nf_conntrack_tcp_loose=0` (§4.3) más `conntrackd` es la combinación correcta. `tcp_loose=1` *sin* `conntrackd` también "funciona" — el backup retoma flujos en medio del stream — pero lo hace aceptando cualquier ACK en medio del stream de cualquiera, que es exactamente el agujero de inyección de estado que construiste un firewall con estado para cerrar.

---

## 10. Arquitecturas de firewall

### 10.1 Comparación de topologías

| Arquitectura | Descripción | Comprometer el servicio público significa | Costo | Dominio de falla |
|---|---|---|---|---|
| **Bastión single-homed** | Un host, filtrado + servicios | Exposición interna total | El más bajo | Todo |
| **Screened host** | El router filtra, el bastión sirve | La ACL del router es la única barrera | Bajo | Router + bastión |
| **DMZ de tres patas** | Un firewall, tres interfaces: WAN / LAN / DMZ | El atacante está dentro de la DMZ, aún filtrado de la LAN por el *mismo* firewall | Medio | Un firewall — un bug, un bypass |
| **Back-to-back / doble firewall** | Dos firewalls, **de distintos fabricantes/implementaciones**, DMZ entre ellos | El atacante debe vencer dos implementaciones independientes | Alto | Independiente |
| **DMZ colapsada (VLAN)** | Zonas como VLANs sobre conmutación compartida, firewall en un trunk | El VLAN hopping / una mala configuración del switch colapsa el límite | Bajo | Tejido de conmutación |
| **Microsegmentación** | Política por carga de trabajo (firewall de host, `NetworkPolicy`, service mesh) | El radio de impacto ≈ una carga de trabajo | El costo operativo más alto | Por carga de trabajo |

**Criterio del arquitecto:** la DMZ de tres patas es el valor por defecto correcto para una plataforma de un solo sitio. Back-to-back vale su costo únicamente cuando el régimen de cumplimiento exige diversidad de implementación (segmentación PCI-DSS para un CDE, por ejemplo) — de lo contrario el segundo firewall es una segunda cosa que configurar mal. La microsegmentación no es una alternativa al perímetro; es la capa que limita hasta dónde llega una brecha del perímetro.

### 10.2 Topología de referencia de tres patas

```
                    Internet
                       │
                  203.0.113.0/28
                       │
                    ┌──┴───┐  eth0 (WAN)  VIP 203.0.113.10
                    │  fw-a├──────┐
                    │  fw-b│      │ eth3 10.99.0.0/30  ← conntrackd sync (dedicated)
                    └──┬───┘      │
              eth2     │     eth1 │
        192.0.2.1/24   │   10.20.0.1/16
                       │          │
        ┌──────────────┴──┐    ┌──┴───────────────┐
        │      DMZ        │    │      LAN         │
        │  192.0.2.0/24   │    │  10.20.0.0/16    │
        │  2001:db8:2::/64│    │  2001:db8:20::/48│
        │                 │    │                  │
        │  web 192.0.2.20 │    │  bastion .0.10   │
        │  mta 192.0.2.30 │    │  db      .5.0/24 │
        └─────────────────┘    └──────────────────┘

Policy invariants (these are the design, the rules are the implementation):
  WAN → DMZ : published ports only, DNAT'd
  WAN → LAN : DENY (no exceptions)
  LAN → DMZ : explicit ops ports
  LAN → WAN : explicit egress allowlist
  DMZ → WAN : explicit egress allowlist (updates, APIs, NTP)
  DMZ → LAN : DENY  ← the reason the DMZ exists
```

La última línea es la única que importa. Todas las demás reglas son comodidad; `DMZ → LAN : DENY` es lo que convierte "nos vulneraron" en "perdimos un servidor web".

---

## 11. Infraestructura completa

### 11.1 Rol de Ansible

```yaml
# roles/netfilter/defaults/main.yml
---
netfilter_backend: nftables        # nftables | iptables
netfilter_wan_iface: eth0
netfilter_lan_iface: eth1
netfilter_dmz_iface: eth2
netfilter_sync_iface: eth3

netfilter_lan_v4: 10.20.0.0/16
netfilter_dmz_v4: 192.0.2.0/24
netfilter_lan_v6: "2001:db8:20::/48"
netfilter_dmz_v6: "2001:db8:2::/64"
netfilter_vip_v4: 203.0.113.10

netfilter_conntrack_max: 1048576
netfilter_conntrack_hashsize: 262144
netfilter_conntrack_tcp_established: 86400

netfilter_bastions:
  - 10.20.0.10
  - 10.20.0.11

netfilter_egress_lan:
  - { proto: tcp, ports: [80, 443, 587, 993], comment: "JIRA-4471 user baseline" }
  - { proto: udp, ports: [53, 123, 443],      comment: "DNS, NTP, QUIC" }

netfilter_egress_dmz:
  - { proto: tcp, ports: [80, 443], comment: "package repos + partner APIs" }
  - { proto: udp, ports: [123],     comment: "NTP" }

netfilter_published:
  - { port: 443, backend: 192.0.2.20, comment: "www" }
  - { port: 80,  backend: 192.0.2.20, comment: "www redirect" }
  - { port: 25,  backend: 192.0.2.30, comment: "inbound mail" }

netfilter_ha_enabled: true
netfilter_sync_local: 10.99.0.1
netfilter_sync_peer: 10.99.0.2
```

```yaml
# roles/netfilter/tasks/main.yml
---
- name: Install packet-filtering toolchain
  ansible.builtin.package:
    name:
      - nftables
      - iptables
      - ipset
      - conntrack
      - conntrack-tools
      - ebtables
      - ulogd2
    state: present

- name: Ensure firewalld is not competing for the ruleset
  ansible.builtin.systemd:
    name: firewalld
    state: stopped
    enabled: false
    masked: true
  failed_when: false

- name: Deploy conntrack and forwarding sysctls
  ansible.builtin.template:
    src: 80-conntrack.conf.j2
    dest: /etc/sysctl.d/80-conntrack.conf
    owner: root
    group: root
    mode: "0644"
  notify: reload sysctl

- name: Pin the conntrack hash bucket count at module load
  ansible.builtin.copy:
    content: "options nf_conntrack hashsize={{ netfilter_conntrack_hashsize }}\n"
    dest: /etc/modprobe.d/nf_conntrack.conf
    owner: root
    group: root
    mode: "0644"

- name: Deploy ipset definitions
  ansible.builtin.template:
    src: ipset.conf.j2
    dest: /etc/ipset.conf
    owner: root
    group: root
    mode: "0600"
    validate: "/bin/sh -c 'ipset restore -f %s -t'"
  notify: restore ipsets

- name: Deploy nftables ruleset
  ansible.builtin.template:
    src: nftables.conf.j2
    dest: /etc/nftables.conf
    owner: root
    group: root
    mode: "0600"
    # -c is a dry-run parse+semantic check. A template typo can never reach
    # the kernel: the task fails at validate time, before the file is written.
    validate: "/usr/sbin/nft -c -f %s"
  when: netfilter_backend == 'nftables'
  notify: reload nftables

- name: Deploy iptables/ip6tables rulesets
  ansible.builtin.template:
    src: "rules.{{ item.family }}.j2"
    dest: "/etc/iptables/rules.{{ item.family }}"
    owner: root
    group: root
    mode: "0600"
    validate: "{{ item.validator }} --test"
  loop:
    - { family: v4, validator: /usr/sbin/iptables-restore }
    - { family: v6, validator: /usr/sbin/ip6tables-restore }
  when: netfilter_backend == 'iptables'
  notify: reload iptables

- name: Deploy conntrackd configuration
  ansible.builtin.template:
    src: conntrackd.conf.j2
    dest: /etc/conntrackd/conntrackd.conf
    owner: root
    group: root
    mode: "0600"
  when: netfilter_ha_enabled | bool
  notify: restart conntrackd

- name: Deploy the failover transition script
  ansible.builtin.copy:
    src: primary-backup.sh
    dest: /etc/conntrackd/primary-backup.sh
    owner: root
    group: root
    mode: "0750"
  when: netfilter_ha_enabled | bool

- name: Enable persistence and HA units
  ansible.builtin.systemd:
    name: "{{ item }}"
    enabled: true
    state: started
    daemon_reload: true
  loop: "{{ netfilter_units }}"

- name: Assert the policy invariants actually hold
  ansible.builtin.include_tasks: verify.yml
  tags: [verify]
```

```yaml
# roles/netfilter/tasks/verify.yml
---
# These are not smoke tests; they are the policy expressed as assertions.
# If a refactor of the ruleset breaks an invariant, this fails the play.

- name: Read the live ruleset
  ansible.builtin.command: nft list ruleset
  register: nft_live
  changed_when: false
  when: netfilter_backend == 'nftables'

- name: Assert every base chain has a restrictive default policy
  ansible.builtin.assert:
    that:
      - "'hook input priority filter; policy drop;' in nft_live.stdout"
      - "'hook forward priority filter; policy drop;' in nft_live.stdout"
    fail_msg: "A base chain defaults to accept - this is a fail-open ruleset."
  when: netfilter_backend == 'nftables'

- name: Assert the DMZ cannot initiate into the LAN
  ansible.builtin.assert:
    that:
      - "'iifname \"' ~ netfilter_dmz_iface ~ '\" oifname \"' ~ netfilter_lan_iface ~ '\" counter packets' in nft_live.stdout"
    fail_msg: "The DMZ->LAN deny rule is missing. The DMZ is not a DMZ."
  when: netfilter_backend == 'nftables'

- name: Assert IPv6 error messages are not filtered
  ansible.builtin.assert:
    that:
      - "'packet-too-big' in nft_live.stdout"
      - "'nd-neighbor-solicit' in nft_live.stdout"
    fail_msg: "ICMPv6 is over-filtered: expect PMTUD blackholes and broken NDP."
  when: netfilter_backend == 'nftables'

- name: Read conntrack utilisation
  ansible.builtin.shell: |
    set -o pipefail
    c=$(cat /proc/sys/net/netfilter/nf_conntrack_count)
    m=$(cat /proc/sys/net/netfilter/nf_conntrack_max)
    awk -v c="$c" -v m="$m" 'BEGIN{printf "%.1f", c/m*100}'
  args:
    executable: /bin/bash
  register: ct_util
  changed_when: false

- name: Warn on conntrack pressure
  ansible.builtin.assert:
    that:
      - ct_util.stdout | float < 80.0
    fail_msg: >-
      conntrack utilisation is {{ ct_util.stdout }}% - the kernel is already
      early-dropping non-ASSURED entries. Raise nf_conntrack_max and lower
      nf_conntrack_tcp_timeout_established.
    success_msg: "conntrack utilisation {{ ct_util.stdout }}% - healthy"

- name: Verify no legacy iptables rules shadow the nftables ruleset
  ansible.builtin.command: iptables-legacy -S
  register: legacy
  changed_when: false
  failed_when: false

- name: Assert the legacy backend is empty
  ansible.builtin.assert:
    that:
      - legacy.stdout_lines | reject('match', '^-P .* ACCEPT$') | list | length == 0
    fail_msg: >-
      Rules exist in BOTH the legacy and nft backends. Both are evaluated;
      the effective policy is the intersection. Consolidate on one backend.
```

```yaml
# roles/netfilter/handlers/main.yml
---
- name: reload sysctl
  ansible.builtin.command: sysctl --system
  changed_when: true

- name: restore ipsets
  # -exist makes this idempotent; sets must exist BEFORE the ruleset loads.
  ansible.builtin.command: ipset restore -exist -file /etc/ipset.conf
  changed_when: true

- name: reload nftables
  ansible.builtin.systemd:
    name: nftables
    state: reloaded

- name: reload iptables
  ansible.builtin.systemd:
    name: "{{ item }}"
    state: reloaded
  loop:
    - iptables
    - ip6tables

- name: restart conntrackd
  ansible.builtin.systemd:
    name: conntrackd
    state: restarted
```

```yaml
# roles/netfilter/vars/main.yml
---
netfilter_units: >-
  {{
    (['nftables'] if netfilter_backend == 'nftables' else ['iptables', 'ip6tables'])
    + ['ipset-persistent', 'ulogd2']
    + (['conntrackd', 'keepalived'] if netfilter_ha_enabled | bool else [])
  }}
```

### 11.2 Unidades de systemd — el orden de arranque es un requisito de corrección

```ini
# /etc/systemd/system/ipset-persistent.service
# ipsets MUST be loaded before the ruleset: iptables-restore/nft abort with
# "Set blocklist4 doesn't exist" and the box boots with NO firewall.
[Unit]
Description=Restore ipset sets
Documentation=man:ipset(8)
DefaultDependencies=no
Before=network-pre.target nftables.service iptables.service ip6tables.service
Wants=network-pre.target
ConditionPathExists=/etc/ipset.conf

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ipset restore -exist -file /etc/ipset.conf
ExecReload=/sbin/ipset restore -exist -file /etc/ipset.conf
ExecStop=/bin/true
StandardOutput=journal

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/systemd/system/nftables.service.d/override.conf
[Unit]
After=ipset-persistent.service
Requires=ipset-persistent.service

[Service]
# Fail the unit loudly if the ruleset does not parse. A firewall that
# "started successfully" with an empty ruleset is worse than one that failed.
ExecStartPre=/usr/sbin/nft -c -f /etc/nftables.conf
ExecReload=
ExecReload=/usr/sbin/nft -c -f /etc/nftables.conf
ExecReload=/usr/sbin/nft -f /etc/nftables.conf
```

```ini
# /etc/systemd/system/fw-blocklist-refresh.service
[Unit]
Description=Refresh threat-intelligence ipsets
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/refresh-blocklist.sh
# The firewall must keep working if the feed is down.
SuccessExitStatus=0
Nice=10
IOSchedulingClass=idle
```

```ini
# /etc/systemd/system/fw-blocklist-refresh.timer
[Unit]
Description=Refresh threat-intelligence ipsets hourly

[Timer]
OnBootSec=5min
OnUnitActiveSec=1h
RandomizedDelaySec=10min
Persistent=true

[Install]
WantedBy=timers.target
```

### 11.3 Compuerta de CI: ningún ruleset llega a un nodo sin validar

```yaml
# .gitlab-ci.yml
---
stages: [lint, validate, dryrun, deploy]

variables:
  ANSIBLE_FORCE_COLOR: "1"
  ANSIBLE_HOST_KEY_CHECKING: "False"

.netfilter_image: &netfilter_image
  image: registry.example.net/ci/netfilter-tools:1.8.10-nft1.0.9
  before_script:
    - nft --version
    - iptables --version
    - ipset --version

lint:ansible:
  stage: lint
  <<: *netfilter_image
  script:
    - ansible-lint roles/netfilter
    - yamllint -s roles/netfilter

validate:nftables:
  stage: validate
  <<: *netfilter_image
  script:
    # Render every host's ruleset and parse-check it. A syntax error here
    # is a pipeline failure, not a 3 a.m. lockout.
    - ansible-playbook -i inventory/prod site.yml --tags netfilter --check --diff
    - |
      for f in build/rendered/*.nft; do
        echo "checking $f"
        nft -c -f "$f" || exit 1
      done

validate:invariants:
  stage: validate
  <<: *netfilter_image
  script:
    # Policy invariants asserted against the RENDERED text, before deploy.
    - |
      set -euo pipefail
      fail=0
      for f in build/rendered/*.nft; do
        grep -q 'policy drop;' "$f"        || { echo "$f: no drop policy"; fail=1; }
        grep -q 'packet-too-big'  "$f"     || { echo "$f: ICMPv6 PTB filtered"; fail=1; }
        grep -q 'nd-neighbor-solicit' "$f" || { echo "$f: NDP filtered"; fail=1; }
        grep -q 'ct state invalid' "$f"    || { echo "$f: INVALID not dropped"; fail=1; }
        # Dual-stack parity: every table must be inet, or both ip and ip6 present.
        grep -q 'table inet' "$f"          || { echo "$f: not dual-stack"; fail=1; }
      done
      exit $fail

dryrun:staging:
  stage: dryrun
  <<: *netfilter_image
  script:
    - ansible-playbook -i inventory/staging site.yml --tags netfilter --diff
    - ansible-playbook -i inventory/staging site.yml --tags verify
  environment:
    name: staging

deploy:prod:
  stage: deploy
  <<: *netfilter_image
  script:
    # serial: 1 in the play + the verify tasks mean a broken node stops the
    # rollout before it reaches the second firewall of an HA pair.
    - ansible-playbook -i inventory/prod site.yml --tags netfilter --diff
    - ansible-playbook -i inventory/prod site.yml --tags verify
  environment:
    name: production
  when: manual
  only:
    refs: [main]
```

### 11.4 El seguro contra quedar afuera

Aplicar un ruleset a un firewall remoto por el mismo enlace que ese ruleset gobierna es la forma más común de perder una máquina. Armá siempre un rollback antes:

```console
$ iptables-save > /root/fw-rollback-$(date +%s).v4
$ nft list ruleset > /root/nft-rollback-$(date +%s).nft
$ systemd-run --on-active=120 --unit=fw-rollback \
    /usr/sbin/nft -f /root/nft-rollback-1756108800.nft
Running timer as unit: fw-rollback.timer
Will run service as unit: fw-rollback.service

$ nft -f /etc/nftables.conf          # apply the new ruleset
$ ssh fw-edge-a 'echo still reachable'
still reachable
$ systemctl stop fw-rollback.timer   # cancel the rollback - you survived
```

Si el ruleset nuevo te deja afuera, el temporizador restaura el viejo en 120 s y tu sesión SSH se recupera. Esto cuesta 15 segundos de preparación y evitó más visitas al sitio que cualquier otra costumbre de este documento.

---

## 12. La era de los contenedores: quién más está escribiendo tu ruleset

En cualquier nodo que corra Docker o Kubernetes, no sos el único autor.

```console
$ iptables -t nat -S | head -8
-P PREROUTING ACCEPT
-P INPUT ACCEPT
-P OUTPUT ACCEPT
-P POSTROUTING ACCEPT
-N DOCKER
-N KUBE-MARK-MASQ
-N KUBE-POSTROUTING
-N KUBE-SERVICES
-A PREROUTING -m comment --comment "kubernetes service portals" -j KUBE-SERVICES
```

| Agente | Dónde escribe | Cómo convivir |
|---|---|---|
| `dockerd` | `nat/DOCKER`, `filter/DOCKER`, `filter/FORWARD` (inserta `-j DOCKER-USER` **primero**) | **Poné tus reglas en `DOCKER-USER`.** Todo lo que agregues a `FORWARD` queda esquivado. `dockerd` además fuerza `net.ipv4.ip_forward=1` |
| `kube-proxy` (modo iptables) | `KUBE-SERVICES`, `KUBE-SVC-*`, `KUBE-SEP-*`, `KUBE-POSTROUTING` | Miles de reglas generadas; una resincronización completa es O(servicios). No las edites a mano |
| `kube-proxy` (modo ipvs) | Tabla IPVS + un conjunto chico de reglas auxiliares de iptables e ipsets (`KUBE-CLUSTER-IP`, …) | Escala mucho mejor más allá de ~1 000 servicios |
| `kube-proxy` (modo nftables) | `table ip kube-proxy` en el backend nft | Alpha en v1.29, beta en v1.31 — verificá contra la versión de tu clúster antes de depender de él |
| CNI (Calico/Cilium) | Cadenas propias (`cali-*`) o eBPF, reemplazando iptables por completo | El reemplazo de kube-proxy de Cilium elimina la mayor parte de lo anterior |
| `fail2ban` | Cadenas propias vía `f2b-*`, o ipset | Preferí la acción con ipset: sin churn de ruleset, sin contención de lock |
| `firewalld` | Posee todo el ruleset de nftables | O lo usás exclusivamente o lo enmascarás. Nunca ambas cosas |

```bash
# The correct place for node-level policy on a Docker host:
iptables -I DOCKER-USER 1 -i eth0 -m set --match-set blocklist4 src -j DROP
iptables -I DOCKER-USER 2 -i eth0 -p tcp --dport 8080 ! -s 10.20.0.0/16 -j DROP
```

**La cadena `DOCKER-USER` es la única cadena que Docker garantiza que no va a reescribir.** Las reglas en otras partes de `FORWARD` son silenciosamente inefectivas porque el salto propio de Docker las precede.

---

## 13. Verificación y diagnóstico de fallas

### 13.1 El árbol de decisión

```
Traffic does not arrive at the service
│
├─ tcpdump on the firewall's ingress interface: is the packet there?
│  ├─ NO ──▶ upstream problem: routing, upstream ACL, DNS, or the client.
│  │         Not your firewall. Verify with: ip route get <dst>
│  └─ YES ─┐
│          │
├─ Does the client get an RST/ICMP-unreachable, or silence?
│  ├─ RST / ICMP admin-prohibited ──▶ an explicit REJECT rule, or nothing listening.
│  │   Check: ss -tlnp 'sport = :443'  AND  iptables -vnL | grep REJECT
│  └─ SILENCE ──▶ a DROP. Continue.
│
├─ Does a conntrack entry exist?
│  │   conntrack -L -d <dst> -p tcp --dport <port>
│  ├─ NO entry ──▶ dropped in raw/PREROUTING, or in a netdev/ingress chain,
│  │               or by rp_filter. Check dmesg for "martian source".
│  ├─ Entry, [UNREPLIED] ──▶ it got in; the REPLY is being dropped, or the
│  │                         backend never answered. Check FORWARD/OUTPUT and
│  │                         the backend's own host firewall.
│  └─ Entry, ASSURED ──▶ the firewall is fine; the problem is above L4 (TLS,
│                        vhost, app). Stop debugging netfilter.
│
├─ Are the counters moving?
│  │   iptables -Z && sleep 10 && iptables -vnL --line-numbers
│  ├─ The DROP rule's counter climbs ──▶ found it. Read the rule.
│  └─ No counter moves anywhere ──▶ the packet is not reaching this ruleset:
│      wrong backend (legacy vs nft), wrong table, or an agent's chain
│      (DOCKER-USER, KUBE-*) terminated first.
│
└─ Still unexplained ──▶ trace the packet (§13.3).
```

### 13.2 Diagnóstico guiado por contadores

```console
$ iptables -Z && ip6tables -Z && nft reset counters
$ sleep 10
$ iptables -vnL FORWARD --line-numbers
Chain FORWARD (policy DROP 47 packets, 2820 bytes)
num   pkts bytes target     prot opt in     out     source               destination
1    18442 22M   ACCEPT     all  --  *      *       0.0.0.0/0            0.0.0.0/0            ctstate RELATED,ESTABLISHED
2        0     0 LOGDROP    all  --  *      *       0.0.0.0/0            0.0.0.0/0            ctstate INVALID
3      211 12660 ACCEPT     all  --  eth0   eth2    0.0.0.0/0            0.0.0.0/0            ctstate DNAT
4        0     0 ACCEPT     tcp  --  eth1   eth0    10.20.0.0/16         0.0.0.0/0            multiport dports 80,443,587,993
5       47  2820 LOGDROP    all  --  *      *       0.0.0.0/0            0.0.0.0/0
```

Cómo leer esto en diez segundos:

* La regla 1 maneja 18 442 de 18 700 paquetes — el camino rápido funciona.
* La regla 4 tiene **cero** aciertos mientras la regla 5 descartó 47: el egreso de la LAN no matchea nada. Sospechá del nombre de la interfaz (`eth1` vs un bond/VLAN) o del CIDR de origen.
* `policy DROP 47 packets` en el encabezado de la cadena coincide con el conteo de la regla 5 — cada descarte pasa por `LOGDROP`, así que los logs van a mostrar qué es.

```console
$ journalctl -k --since "-2 min" -g 'FW4-DROP' -o cat | tail -2
FW4-DROP: IN=bond0.20 OUT=eth0 MAC=... SRC=10.20.4.51 DST=140.82.121.4 LEN=60 TOS=0x00 PREC=0x00 TTL=63 ID=54321 DF PROTO=TCP SPT=49882 DPT=443 WINDOW=64240 RES=0x00 SYN URGP=0
FW4-DROP: IN=bond0.20 OUT=eth0 MAC=... SRC=10.20.4.51 DST=140.82.121.4 LEN=60 TOS=0x00 PREC=0x00 TTL=63 ID=54322 DF PROTO=TCP SPT=49882 DPT=443 WINDOW=64240 RES=0x00 SYN URGP=0
```

`IN=bond0.20`, no `eth1`. Diagnóstico completo: la regla nombra la interfaz equivocada. Este es el ticket de "el firewall está roto" más común de todos, y el prefijo del `LOG` es lo que lo convierte en un arreglo de 90 segundos en vez de una tarde entera.

### 13.3 Trazado

**nftables (y `iptables-nft`):**

```console
$ nft add rule inet fw prerouting_raw ip saddr 198.51.100.7 meta nftrace set 1
$ nft monitor trace
trace id 9f3c1a02 inet fw prerouting_raw packet: iif "eth0" ether saddr 00:1b:21:0a:bc:de ether daddr 00:1b:21:0a:bc:df ip saddr 198.51.100.7 ip daddr 203.0.113.10 ip dscp cs0 ip ttl 54 ip id 41288 ip protocol tcp ip length 60 tcp sport 41234 tcp dport 22 tcp flags == syn tcp window 64240
trace id 9f3c1a02 inet fw prerouting_raw rule ip saddr 198.51.100.7 meta nftrace set 1 (verdict continue)
trace id 9f3c1a02 inet fw prerouting_raw verdict continue
trace id 9f3c1a02 inet fw input packet: iif "eth0" ... tcp dport 22 tcp flags == syn
trace id 9f3c1a02 inet fw input rule ct state vmap { established : accept, related : accept, invalid : drop } (verdict continue)
trace id 9f3c1a02 inet fw input rule iifname { "eth0", "eth1" } tcp dport 22 ct state new counter packets 1 bytes 60 jump logdrop (verdict jump logdrop)
trace id 9f3c1a02 inet fw logdrop rule limit rate 6/minute burst 12 packets log prefix "FW-DROP: " level warn (verdict continue)
trace id 9f3c1a02 inet fw logdrop verdict drop
trace id 9f3c1a02 inet fw logdrop policy accept
^C
$ nft -a list chain inet fw prerouting_raw | grep nftrace
		ip saddr 198.51.100.7 meta nftrace set 1 # handle 27
$ nft delete rule inet fw prerouting_raw handle 27
```

Cada regla que el paquete tocó, en orden, con el veredicto. El `trace id` agrupa todo el recorrido de un paquete. **Sacá la regla de traza cuando termines** — es una tormenta de eventos netlink por paquete.

**iptables legacy:**

```console
$ modprobe nf_log_ipv4
$ sysctl -w net.netfilter.nf_log.2=nf_log_ipv4
$ iptables-legacy -t raw -A PREROUTING -s 198.51.100.7 -j TRACE
$ dmesg -w | grep TRACE
[318442.114] TRACE: raw:PREROUTING:policy:2 IN=eth0 OUT= SRC=198.51.100.7 DST=203.0.113.10 LEN=60 PROTO=TCP SPT=41234 DPT=22 SYN
[318442.114] TRACE: filter:INPUT:rule:1 IN=eth0 OUT= SRC=198.51.100.7 DST=203.0.113.10 LEN=60 PROTO=TCP SPT=41234 DPT=22 SYN
[318442.114] TRACE: filter:INPUT:policy:14 IN=eth0 OUT= SRC=198.51.100.7 DST=203.0.113.10 LEN=60 PROTO=TCP SPT=41234 DPT=22 SYN
$ iptables-legacy -t raw -D PREROUTING -s 198.51.100.7 -j TRACE
```

Formato: `table:chain:rule|policy:number`. **Con el backend `iptables-nft`, `-j TRACE` no escribe a `dmesg`** — usá `xtables-monitor --trace` o `nft monitor trace` en su lugar. Esto sorprende a quienes aprendieron a trazar en RHEL 7 y pasaron a RHEL 9.

### 13.4 Referencia síntoma → causa

| Síntoma | Primer comando | Causa probable | Solución |
|---|---|---|---|
| `nf_conntrack: table full, dropping packet` | `conntrack -C; sysctl net.netfilter.nf_conntrack_max` | Tabla subdimensionada, o timeout established de 5 días | sysctls de §4.3 |
| Los flujos TCP largos mueren, los cortos andan bien | `conntrack -S` (`invalid` en aumento) | Ruteo asimétrico; conntrack ve una sola dirección | Arreglar el ruteo, o `tcp_be_liberal=1` como último recurso documentado |
| `Cannot assign requested address` intermitente en el egreso | `conntrack -S` (`insert_failed`) | Agotamiento de puertos de SNAT | `--random-fully`, pool de SNAT |
| IPv6 funciona, las transferencias grandes se cuelgan | `ip6tables -vnL \| grep -c packet-too-big` | PTB de ICMPv6 filtrado → agujero negro de PMTUD | §3.6; también `TCPMSS --clamp-mss-to-pmtu` |
| Vecinos IPv6 inalcanzables | `ip -6 neigh show` (todos `FAILED`) | NDP (ICMPv6 133–137) filtrado | §3.6 |
| Reglas presentes pero ignoradas | `iptables --version`; `iptables-legacy -S` | Dos backends en uso | Consolidar |
| La política se revierte tras reiniciar un contenedor | `iptables -S FORWARD \| head -1` | Reglas en `FORWARD` en vez de `DOCKER-USER` | §12 |
| `Another app is currently holding the xtables lock` | `fuser /run/xtables.lock` | Escritor concurrente (`fail2ban`, `dockerd`) | Pasar siempre `-w <timeout>` |
| `Set blocklist4 doesn't exist` en el arranque | `systemctl list-dependencies nftables` | ipsets restaurados después del ruleset | Ordenamiento de unidades de §11.2 |
| Todas las conexiones se caen en el failover | `conntrackd -s` (caché externa vacía) | Replicación caída, o nunca se llamó a `-c` | §9 |
| Log del kernel inundado, máquina que no responde | `journalctl -k --since -1min \| wc -l` | Target `LOG` sin `-m limit` | Agregar `limit`, o pasar a `NFLOG` + `ulogd2` |
| `martian source` en `dmesg` | `sysctl net.ipv4.conf.all.rp_filter` | RPF estricto vs camino asimétrico/multi-homed | `rp_filter=2` (loose) o `-m rpfilter --loose` |

### 13.5 Logging estructurado con `NFLOG` + `ulogd2`

`LOG` escribe texto libre al ring buffer del kernel, dentro del datapath, sin estructura. En un firewall ocupado eso es a la vez un problema de rendimiento y algo imposible de parsear. `NFLOG` entrega los paquetes al espacio de usuario por netlink:

```bash
nft add rule inet fw logdrop limit rate 20/second burst 40 packets \
    log prefix "drop " group 1
```

```ini
# /etc/ulogd.conf
[global]
logfile="/var/log/ulogd.log"
loglevel=5
plugin="/usr/lib/x86_64-linux-gnu/ulogd/ulogd_inppkt_NFLOG.so"
plugin="/usr/lib/x86_64-linux-gnu/ulogd/ulogd_raw2packet_BASE.so"
plugin="/usr/lib/x86_64-linux-gnu/ulogd/ulogd_filter_IFINDEX.so"
plugin="/usr/lib/x86_64-linux-gnu/ulogd/ulogd_filter_IP2STR.so"
plugin="/usr/lib/x86_64-linux-gnu/ulogd/ulogd_output_JSON.so"

stack=log1:NFLOG,base1:BASE,ifi1:IFINDEX,ip2str1:IP2STR,json1:JSON

[log1]
group=1
numeric_label=1

[json1]
sync=0
file="/var/log/ulogd.json"
```

```console
$ tail -1 /var/log/ulogd.json | jq -c '{ts:.timestamp,in:.oob.in,src:.src_ip,dst:.dst_ip,dpt:.dest_port,pfx:.oob.prefix}'
{"ts":"2026-08-25T09:41:12","in":"eth0","src":"198.51.100.7","dst":"203.0.113.10","dpt":22,"pfx":"drop "}
```

Las líneas JSON se envían directo a Loki/Elasticsearch. Limitá la tasa de la sentencia `log` sin importar el backend — netlink es más barato que `printk`, no gratis.

### 13.6 Contabilidad sin logging

Para saber "cuánto tráfico matcheó esta política" sin ningún costo de logging por paquete:

```console
$ nfacct add dmz-egress-https
$ iptables -A FORWARD -i eth2 -o eth0 -p tcp --dport 443 -m nfacct --nfacct-name dmz-egress-https
$ nfacct list
{ pkts = 00000000000418829, bytes = 00000000411204118 } = dmz-egress-https;
```

En nftables, un contador con nombre hace lo mismo:

```console
$ nft add counter inet fw dmz_egress_https
$ nft add rule inet fw forward iifname "eth2" oifname "eth0" tcp dport 443 counter name dmz_egress_https accept
$ nft list counters
table inet fw {
	counter dmz_egress_https {
		packets 418829 bytes 411204118
	}
}
```

---

## 14. Consolidación enfocada en el examen

Datos que se preguntan directamente y que es fácil olvidar bajo presión:

1. **Orden de recorrido de un paquete reenviado:** `raw/PREROUTING` → conntrack → `mangle/PREROUTING` → `nat/PREROUTING` (DNAT) → *decisión de ruteo* → `mangle/FORWARD` → `filter/FORWARD` → `mangle/POSTROUTING` → `nat/POSTROUTING` (SNAT).
2. **`filter`** tiene `INPUT`, `FORWARD`, `OUTPUT`. **`nat`** tiene `PREROUTING`, `INPUT`, `OUTPUT`, `POSTROUTING`. **`mangle`** tiene las cinco. **`raw`** tiene `PREROUTING`, `OUTPUT`.
3. **`-m state --state`** es la sintaxis legacy; **`-m conntrack --ctstate`** es la actual. Ambas aparecen en el material del examen.
4. **`iptables-save`/`iptables-restore`** trabajan sobre el ruleset completo; `restore` **vacía por defecto**, `-n`/`--noflush` agrega. `-t`/`--test` solo valida.
5. **`ipset` tiene una sola familia de direcciones por set.** IPv4 e IPv6 necesitan sets separados.
6. **`ipset swap`** es la primitiva de actualización atómica. `ipset destroy` falla mientras `References > 0`.
7. **Tablas de `ebtables`:** `filter`, `nat`, `broute`. La cadena `broute`/`BROUTING` es exclusiva de ebtables y decide bridge vs ruteo.
8. **Familias de nftables:** `ip`, `ip6`, `inet`, `arp`, `bridge`, `netdev`. `inet` es la de doble pila.
9. **`nft` no tiene tablas ni cadenas incorporadas.** Creás todo, incluidas las cadenas base con `type`/`hook`/`priority`/`policy`.
10. **`conntrackd`** replica el estado de conntrack; modos `alarm`, `ftfw`, `notrack`; `-c` commitea la caché externa en el kernel al promoverse a primario.
11. **`MASQUERADE`** = SNAT a la dirección de la interfaz de salida, para IPs dinámicas. **`SNAT`** para estáticas — más barato, y no vacía conntrack ante eventos del enlace.
12. **`REDIRECT`** es DNAT a la máquina local; **`REJECT`** envía un error, **`DROP`** no envía nada.
13. **Los tipos ICMPv6 133–137** son NDP y deben pasar; el **tipo 2** (`packet-too-big`) debe pasar o PMTUD se convierte en un agujero negro.
14. `-j LOG` continúa a la regla siguiente; `-j DROP`/`ACCEPT`/`REJECT` terminan.

---

## Referencias

**Certification objectives**

* LPI — Exam 303 Objectives (LPIC-3 Security, v3.0.0): <https://www.lpi.org/our-certifications/exam-303-objectives/>

**Netfilter project (upstream)**

* Netfilter/iptables project documentation index: <https://www.netfilter.org/documentation/index.html>
* iptables project page: <https://www.netfilter.org/projects/iptables/index.html>
* nftables project page and manpage: <https://www.netfilter.org/projects/nftables/manpage.html>
* nftables wiki (main page): <https://wiki.nftables.org/wiki-nftables/index.php/Main_Page>
* Moving from iptables to nftables: <https://wiki.nftables.org/wiki-nftables/index.php/Moving_from_iptables_to_nftables>
* nftables — Sets, maps and concatenations: <https://wiki.nftables.org/wiki-nftables/index.php/Sets>
* nftables — Flowtables: <https://wiki.nftables.org/wiki-nftables/index.php/Flowtables>
* nftables — Troubleshooting and ruleset debug: <https://wiki.nftables.org/wiki-nftables/index.php/Ruleset_debug/tracing>
* ipset project and manpage: <https://ipset.netfilter.org/ipset.man.html>
* conntrack-tools manual (`conntrack`, `conntrackd`): <https://conntrack-tools.netfilter.org/manual.html>
* ebtables project page: <https://www.netfilter.org/projects/ebtables/index.html>
* libnetfilter_log / ulogd project: <https://www.netfilter.org/projects/ulogd/index.html>

**Linux kernel documentation**

* Conntrack sysctl reference: <https://docs.kernel.org/networking/nf_conntrack-sysctl.html>
* Netfilter flowtable infrastructure: <https://docs.kernel.org/networking/nf_flowtable.html>
* IP sysctl reference (`rp_filter`, `ip_forward`, `accept_ra`): <https://docs.kernel.org/networking/ip-sysctl.html>

**Manual pages**

* `iptables(8)`: <https://man7.org/linux/man-pages/man8/iptables.8.html>
* `iptables-extensions(8)` — every match and target: <https://man7.org/linux/man-pages/man8/iptables-extensions.8.html>
* `ip6tables(8)`: <https://man7.org/linux/man-pages/man8/ip6tables.8.html>
* `nft(8)`: <https://man7.org/linux/man-pages/man8/nft.8.html>
* `ipset(8)`: <https://man7.org/linux/man-pages/man8/ipset.8.html>
* `ebtables(8)`: <https://man7.org/linux/man-pages/man8/ebtables.8.html>
* `conntrackd(8)`: <https://man7.org/linux/man-pages/man8/conntrackd.8.html>

**Standards and guidance**

* RFC 4890 — Recommendations for Filtering ICMPv6 Messages in Firewalls: <https://www.rfc-editor.org/rfc/rfc4890.html>
* RFC 4861 — Neighbor Discovery for IPv6: <https://www.rfc-editor.org/rfc/rfc4861.html>
* RFC 8200 — IPv6 Specification (fragmentation, extension headers): <https://www.rfc-editor.org/rfc/rfc8200.html>
* RFC 5095 — Deprecation of Type 0 Routing Headers in IPv6: <https://www.rfc-editor.org/rfc/rfc5095.html>
* NIST SP 800-41 Rev. 1 — Guidelines on Firewalls and Firewall Policy: <https://csrc.nist.gov/pubs/sp/800/41/r1/final>

**Ecosystem interaction**

* Kubernetes — kube-proxy and the nftables proxy mode: <https://kubernetes.io/docs/reference/networking/virtual-ips/>
* Docker — packet filtering and firewalls (`DOCKER-USER`): <https://docs.docker.com/engine/network/packet-filtering-firewalls/>
* keepalived documentation: <https://www.keepalived.org/manpage.html>