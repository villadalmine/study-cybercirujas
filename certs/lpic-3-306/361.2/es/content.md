# Tema 361.2 — Load Balanced Clusters

**LPIC-3 306 · Examen 306-300 · v3.0 · Peso 13.34**

Este objetivo cubre la capa que convierte una flota de servidores idénticos en una única dirección de servicio resiliente. Tiene tres pilares, y el examen evalúa los tres a profundidad de implementación: **LVS/IPVS** (el balanceador L4 dentro del kernel), **keepalived** (VRRP para la HA del balanceador más control de IPVS con health-checks) y **HAProxy** (el balanceador L4/L7 en espacio de usuario con ACLs y stick tables). El material que sigue construye cada pilar desde su mecánica a nivel de paquete hasta la configuración completa y desplegable y un runbook de diagnóstico.

---

## 1. El problema de producción

Un único servidor web tiene un techo rígido — CPU, tabla de conexiones, profundidad de la cola de la NIC — y es un punto único de falla. El escalado horizontal responde al techo: poner N backends idénticos detrás de una única **Virtual IP (VIP)** y distribuir las peticiones entre ellos. Pero eso crea de inmediato dos problemas nuevos sobre los que está construido el objetivo del examen:

1. **¿Cómo distribuye una sola IP el tráfico a N real servers, y a dónde va el tráfico de retorno?** Esta es la cuestión del *método de forwarding*, y es la diferencia entre un director que se satura a 1 Gbit/s (NAT) y uno que empuja 40 Gbit/s (Direct Routing), porque en el segundo caso el director nunca toca un solo paquete de respuesta.

2. **¿Qué pasa cuando el propio load balancer muere?** La VIP es ahora el punto único de falla por el que acabás de concentrar todo el tráfico. Esta es la cuestión del *failover de la VIP*, resuelta con **VRRP** (vía keepalived) para que un director en standby reclame la VIP dentro de un intervalo de advertisement.

Hay un tercer eje, ortogonal: **¿en qué capa OSI tomás la decisión de balanceo?**

- **Layer 4 (transporte):** el balanceador elige un backend por *conexión*, basándose solo en IP/puerto. Nunca parsea el payload, así que es barato, rápido y agnóstico al protocolo (funciona para TCP, y con UDP para DNS/QUIC/tráfico de juegos). Esto es LVS/IPVS, y HAProxy en `mode tcp`.
- **Layer 7 (aplicación):** el balanceador termina la conexión, parsea HTTP, y puede rutear según Host header, ruta de URL, cookies o método; reescribir headers; terminar TLS; reintentar peticiones idempotentes. Esto es HAProxy en `mode http`. Cuesta CPU y memoria por conexión y es específico del protocolo, pero habilita ruteo basado en contenido, canary releases y una observabilidad que L4 no puede ofrecer.

Un edge de producción muy a menudo es **ambos**: una capa L4 (IPVS + keepalived) para la HA de la VIP y el throughput en crudo, delante de una capa L7 (HAProxy) para ruteo y TLS. Entender cuándo cada capa justifica su costo es la competencia central que mide este objetivo.

```
                         ┌──────────────────────────────┐
                         │      VIP 203.0.113.10         │
                         │  (owned by keepalived/VRRP)   │
                         └───────────────┬──────────────┘
             VRRP (proto 112) advert     │
   ┌──────────────────────┐        ┌─────┴──────────────────┐
   │  Director A (MASTER)  │◀──────▶│  Director B (BACKUP)   │
   │  keepalived + IPVS    │  sync  │  keepalived + IPVS     │
   │  prio 150             │  daemon│  prio 100              │
   └───────────┬───────────┘        └────────────────────────┘
               │  L4 forward (DR / NAT / TUN)
      ┌────────┼─────────┬──────────────┐
      ▼        ▼         ▼              ▼
  ┌───────┐┌───────┐ ┌───────┐     ┌───────┐
  │ RS 1  ││ RS 2  │ │ RS 3  │ ... │ RS N  │   real servers
  └───────┘└───────┘ └───────┘     └───────┘
```

---

## 2. El panorama y dónde encaja cada herramienta

| Propiedad | **LVS / IPVS** | **HAProxy** | **keepalived** |
|---|---|---|---|
| Corre en | Kernel de Linux (netfilter/IPVS) | Espacio de usuario, orientado a eventos | Daemon en espacio de usuario |
| Capa OSI | Solo L4 (TCP/UDP/SCTP) | L4 (`tcp`) y L7 (`http`) | Plano de control, no un plano de datos |
| Rol | Balanceador del plano de datos | Balanceador del plano de datos + proxy | Failover VRRP + health checks + programa IPVS |
| ¿Termina la conexión? | No (transparente) | Sí | N/A |
| ¿Ve el tráfico de respuesta? | Solo en modo NAT | Siempre (es un proxy) | N/A |
| Terminación TLS | No | Sí | No |
| Ruteo por contenido (path/host/cookie) | No | Sí (ACLs) | No |
| Throughput pico | Muy alto (line rate en DR) | Alto, acotado por CPU/TLS | N/A |
| Costo por conexión | ~1 entrada de hash-table | Socket completo + buffers | N/A |
| ¿Se configura a sí mismo? | No (necesita `ipvsadm` o keepalived) | Sí (`haproxy.cfg`) | Sí; puede manejar IPVS |

Modelo mental clave: **IPVS es un mecanismo, keepalived es el plano de control que normalmente lo maneja.** *Podés* programar IPVS a mano con `ipvsadm`, pero en producción las estrofas `virtual_server`/`real_server` en `keepalived.conf` lo hacen por vos *y* agregan health checking *y* manejan el failover de la VIP. HAProxy es una alternativa autónoma que reemplaza el rol del *balanceador* pero aún necesita keepalived (o un equivalente) para la alta disponibilidad de la **VIP** — HAProxy no tiene VRRP incorporado.

---

## 3. LVS / IPVS

### 3.1 Arquitectura

IPVS vive en el kernel como un hook de netfilter en la ruta `INPUT`/`LOCAL_IN`. Cuando llega un paquete para un *virtual service* registrado (VIP:puerto/protocolo), IPVS:

1. Busca una entrada existente en su **tabla hash de conexiones** indexada por (client IP:port, VIP:port, protocol). Si la encuentra, el paquete va al mismo real server — esto es lo que hace que un balanceador L4 sin estado mantenga las conexiones TCP fijadas a un solo backend.
2. Si es una conexión nueva (SYN), ejecuta el **scheduler** configurado para elegir un real server, registra el mapeo, y hace forwarding según el **método de forwarding** configurado.

IPVS mantiene su propio estado de conexión independiente de `nf_conntrack`; el tamaño de la tabla es una potencia de dos fijada al cargar el módulo (`conn_tab_bits`, por defecto 12 → 4096 buckets, ajustable hasta `20`).

Módulos requeridos: el `ip_vs` central más un módulo de scheduler por cada algoritmo en uso.

```
$ sudo modprobe ip_vs
$ sudo modprobe ip_vs_wlc
$ lsmod | grep ip_vs
ip_vs_wlc              16384  1
ip_vs                 176128  3 ip_vs_wlc
nf_conntrack          172032  1 ip_vs
nf_defrag_ipv6         24576  2 nf_conntrack,ip_vs
libcrc32c              16384  3 nf_conntrack,xfs,ip_vs
```

Persistir entre reinicios:

```
$ cat /etc/modules-load.d/ipvs.conf
ip_vs
ip_vs_wlc
ip_vs_rr
ip_vs_sh
nf_conntrack
```

### 3.2 Métodos de forwarding — la decisión central de diseño

Este es el concepto más evaluado en 361.2. Tres métodos, cada uno reescribiendo una parte distinta del paquete y cada uno imponiendo una restricción distinta a los real servers.

| | **NAT (`-m`, masq)** | **Direct Routing (`-g`, gatewaying)** | **Tunneling (`-i`, ipip)** |
|---|---|---|---|
| Qué reescribe el director | IP de destino (entrada), IP de origen (salida) | Solo la **MAC** de destino; las IPs quedan intactas | Encapsula el paquete original en un header externo IP-in-IP |
| Ruta de retorno | **De vuelta a través del director** (tiene que deshacer el NAT) | Real server → **directo al cliente** | Real server → **directo al cliente** |
| Red del real server | Privada; **el gateway por defecto debe ser el director** | **Mismo segmento L2** que el director | **Cualquier red / remota** (ruteada) |
| VIP en el real server | No | Sí, en `lo` con supresión de ARP | Sí, en `tunl0` con supresión de ARP |
| SO del real server | Cualquiera (nunca ve la VIP) | Debe soportar alias en `lo` + `arp_ignore` | Debe soportar tunneling IP-in-IP |
| Remapeo de puerto | Sí (VIP:80 → RS:8080) | No (puerto preservado) | No (puerto preservado) |
| Preocupación por MTU | Ninguna | Ninguna | Sí — el header externo de 20 bytes achica el payload |
| El director es cuello de botella | **Sí** (ambas direcciones) | No (solo ingreso) | No (solo ingreso) |
| Escala típica | ~10–20 real servers | ~100+ real servers | ~100+, geo-distribuidos |

**NAT** es el más simple y funciona con cualquier backend, pero cada respuesta fluye de vuelta a través del director, así que el uplink del director acota el throughput total. Requiere `net.ipv4.ip_forward=1`.

**Direct Routing (DR)** es el caballo de batalla de la producción de alto throughput. El director solo reescribe la MAC de destino a la MAC de un real server; la IP de destino sigue siendo la VIP. Por lo tanto, el real server debe **poseer la VIP** (en `lo`) para aceptar el paquete, y debe responder **directamente** al cliente con IP de origen = VIP. Como ahora múltiples hosts llevan la misma VIP en el mismo segmento L2, debés impedir que los real servers respondan ARP para ella — de lo contrario los clientes resuelven la VIP por ARP a un real server al azar y saltean al director. Este es **el problema de ARP**, resuelto con `arp_ignore=1` / `arp_announce=2`.

**Tunneling (TUN)** envuelve el paquete original en un header externo IP-in-IP dirigido al real server, que lo desencapsula, ve la VIP adentro, y responde directamente. Esto permite que los real servers vivan en redes completamente distintas (incluso data centres distintos). El costo es un overhead de encapsulación de 20 bytes que puede disparar fragmentación o agujeros negros de PMTU si no se tiene en cuenta.

### 3.3 Algoritmos de scheduling

| Scheduler | Significado | Base de la decisión | Estado | Mejor para |
|---|---|---|---|---|
| `rr` | Round Robin | rotación estricta | sin estado | backends homogéneos, conns cortas |
| `wrr` | Weighted RR | rotación ∝ weight | sin estado | capacidad heterogénea |
| `lc` | Least‑Connection | menos conns activas | dinámico | conexiones de larga duración |
| `wlc` | Weighted LC **(por defecto)** | minimizar `active/weight` | dinámico | capacidad mixta + conns largas |
| `lblc` | Locality‑Based LC | dest IP → server, LC en sobrecarga | dinámico | granjas transparentes de cache/proxy |
| `lblcr` | LBLC + Replication | dest IP → *conjunto* de servers | dinámico | granjas de cache con claves calientes |
| `dh` | Destination Hash | `hash(dest IP)` | sin estado | proxies transparentes |
| `sh` | Source Hash | `hash(src IP)` | sin estado | persistencia sin tabla de estado |
| `sed` | Shortest Expected Delay | minimizar `(active+1)/weight` | dinámico | granjas chicas, conns cortas |
| `nq` | Never Queue | server ocioso primero, si no SED | dinámico | evitar latencia de encolado |
| `fo` | Weighted Failover | solo el de mayor weight disponible | sin estado | backends activo/pasivo |
| `ovf` | Weighted Overflow | saturar el de mayor weight, luego derramar | dinámico | escalado por overflow / ráfaga |
| `mh` | Maglev Hashing | consistent hashing | sin estado | remapeo mínimo al cambiar membresía |

`wlc` es el default y la elección general segura. Usá `sh` cuando necesitás stickiness de cliente a servidor sin una tabla de persistencia; usá `mh` (kernel ≥ 4.18) cuando necesitás consistent hashing que apenas perturbe los flujos existentes cuando se agrega o se saca un backend.

### 3.4 Programación manual con `ipvsadm` (ejemplo DR)

Director:

```
# 1. VIP on the director's public interface
$ sudo ip addr add 203.0.113.10/32 dev eth0

# 2. Virtual service: TCP VIP:80, weighted least-connection
$ sudo ipvsadm -A -t 203.0.113.10:80 -s wlc

# 3. Real servers via Direct Routing (-g = gatewaying)
$ sudo ipvsadm -a -t 203.0.113.10:80 -r 10.0.0.11:80 -g -w 1
$ sudo ipvsadm -a -t 203.0.113.10:80 -r 10.0.0.12:80 -g -w 1

# 4. Inspect
$ sudo ipvsadm -Ln
IP Virtual Server version 1.2.1 (size=4096)
Prot LocalAddress:Port Scheduler Flags
  -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
TCP  203.0.113.10:80 wlc
  -> 10.0.0.11:80                 Route   1      842        231
  -> 10.0.0.12:80                 Route   1      839        228
```

La columna `Forward` decodifica el método: **`Route`** = Direct Routing, **`Masq`** = NAT, **`Tunnel`** = TUN, **`Local`** = terminado localmente.

Cada real server en DR/TUN necesita la VIP en una interfaz que no haga ARP:

```
# On each real server — DR: VIP on loopback, ARP fully suppressed
$ sudo ip addr add 203.0.113.10/32 dev lo
$ sudo tee /etc/sysctl.d/99-lvs-realserver.conf >/dev/null <<'EOF'
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2
net.ipv4.conf.lo.arp_ignore = 1
net.ipv4.conf.lo.arp_announce = 2
EOF
$ sudo sysctl --system
```

`arp_ignore=1` → responder ARP solo si la IP objetivo está configurada en la interfaz *entrante* (así la VIP de `lo` nunca se anuncia en `eth0`). `arp_announce=2` → usar siempre la mejor dirección *primaria* de la interfaz de salida como origen de ARP, nunca la VIP. Saltarse esto es la falla clásica de DR: los clientes resuelven la VIP a la MAC de un real server y el tráfico saltea al director por completo.

Guardar/restaurar y contadores:

```
$ sudo ipvsadm -S -n > /etc/ipvsadm.rules      # dump rules
$ sudo ipvsadm -R < /etc/ipvsadm.rules          # restore
$ sudo ipvsadm -Z                               # zero all counters
```

### 3.5 Sincronización de conexiones (failover con estado)

Por defecto, cuando el director MASTER muere el BACKUP tiene una tabla de conexiones vacía, así que toda conexión TCP en vuelo se rompe. El **daemon de sync de IPVS** replica la tabla de conexiones del master al backup para que el failover sea *con estado* — las conexiones establecidas sobreviven.

```
# On the master director
$ sudo ipvsadm --start-daemon master --mcast-interface eth1 --syncid 51
# On the backup director
$ sudo ipvsadm --start-daemon backup --mcast-interface eth1 --syncid 51

$ sudo ipvsadm -Ln --daemon
IPVS connection sync daemon (master mcast=eth1 syncid=51)
```

En la práctica keepalived lo inicia por vos (ver `lvs_sync_daemon` más abajo), atado a la instancia VRRP para que el rol de *sync* siga al rol *VRRP*.

---

## 4. keepalived — failover VRRP + IPVS con health-checks

keepalived hace dos trabajos que a menudo se confunden:

1. **VRRP** — elige un director como MASTER y flota la VIP hacia él; ante una falla el BACKUP toma el control.
2. **Director IPVS** — los bloques `virtual_server`/`real_server` programan IPVS *y* hacen health-check de cada real server, sacando los backends fallidos del pool automáticamente.

### 4.1 Mecánica de VRRP

VRRP (RFC 5798 para v3, RFC 3768 para v2) corre directamente sobre IP como **protocolo 112**, enviado a la multicast `224.0.0.18` (o unicast a peers explícitos). Cada router participante comparte un **virtual_router_id (VRID)** y una **priority** (0–255). El nodo de mayor prioridad se vuelve MASTER y responde ARP para la VIP con una MAC virtual (`00:00:5e:00:01:<VRID>`). El MASTER envía advertisements cada `advert_int`; si un BACKUP pierde ~3 intervalos (el *master down interval*), se promueve a sí mismo, asigna la VIP, y difunde un **gratuitous ARP** para que los switches reaprendan la MAC. `priority 0` es un mensaje especial de "me estoy yendo" que dispara un takeover inmediato.

| Término | Significado |
|---|---|
| VRID | Id del grupo compartido; debe coincidir en todos los peers, único por segmento L2 |
| priority | La más alta gana MASTER; 255 = address owner, 0 = renuncia |
| advert_int | Período del advertisement (s); MASTER-down ≈ 3 × advert_int |
| preempt | El nodo de mayor prioridad reclama MASTER cuando regresa |
| GARP | Gratuitous ARP enviado en la transición para dirigir la L2 al nuevo MASTER |
| unicast_peer | Enviar adverts por unicast (necesario donde la multicast está filtrada, ej. muchas nubes) |

### 4.2 `keepalived.conf` completo — par de directores HA manejando LVS-DR

Esta es una configuración completa y desplegable para el director **MASTER**. El **BACKUP** es idéntico excepto por `state BACKUP` y `priority 100`.

```
# /etc/keepalived/keepalived.conf  —  MASTER director
global_defs {
    router_id LVS_DIRECTOR_A
    enable_script_security          # refuse to run scripts owned by non-root/world-writable
    script_user keepalived_script
    vrrp_garp_master_delay 1
    vrrp_garp_master_refresh 60     # periodically re-send GARP to fight stale switch tables
}

# Health of the local IPVS data plane; if IPVS is broken, hand the VIP over.
vrrp_script chk_ipvs {
    script "/usr/bin/test -e /proc/net/ip_vs"
    interval 2
    fall 2                          # 2 consecutive failures = DOWN
    rise 2                          # 2 consecutive successes = UP
    weight -40                      # subtract 40 from priority while failing
}

vrrp_instance VI_WEB {
    state MASTER
    interface eth0
    virtual_router_id 51
    priority 150
    advert_int 1
    preempt_delay 5                 # wait 5s after recovery before reclaiming MASTER

    authentication {
        auth_type PASS
        auth_pass S3cr3t-VRRP       # 8-char shared secret (VRRPv2)
    }

    # Unicast is mandatory on clouds/segments where multicast 224.0.0.18 is dropped
    unicast_src_ip 203.0.113.2
    unicast_peer {
        203.0.113.3
    }

    virtual_ipaddress {
        203.0.113.10/32 dev eth0
    }

    track_script {
        chk_ipvs
    }

    notify_master "/etc/keepalived/notify.sh MASTER VI_WEB"
    notify_backup "/etc/keepalived/notify.sh BACKUP VI_WEB"
    notify_fault  "/etc/keepalived/notify.sh FAULT  VI_WEB"
}

# Stateful failover: replicate the IPVS connection table, tied to VI_WEB.
lvs_sync_daemon eth1 VI_WEB id 51

# ---- LVS virtual service: keepalived programs IPVS AND health-checks backends ----
virtual_server 203.0.113.10 80 {
    delay_loop 6                    # health-check every 6s
    lb_algo wlc                     # weighted least-connection
    lb_kind DR                      # Direct Routing
    protocol TCP
    persistence_timeout 0           # no client stickiness (set >0 to pin by source IP)

    real_server 10.0.0.11 80 {
        weight 1
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
}
```

`notify.sh` (debe ser propiedad de root y no escribible por todos, según `enable_script_security`):

```
#!/usr/bin/env bash
# /etc/keepalived/notify.sh  <STATE> <INSTANCE>
set -euo pipefail
STATE="$1"; INSTANCE="$2"
logger -t keepalived "transition: instance=${INSTANCE} state=${STATE}"
case "$STATE" in
    MASTER) ;;   # VIP arrived — nothing extra needed for pure LVS-DR
    BACKUP|FAULT)
        # Example hook: drain local caches, page on FAULT, etc.
        ;;
esac
```

La intención del diseño: `track_script chk_ipvs` con `weight -40` significa que si el motor IPVS local se rompe en el MASTER, su prioridad efectiva baja a `110`, que *sigue* estando por encima del `100` del BACKUP — así que una única falla suave no hace flapear la VIP. Hacé el weight más grande que la brecha con el peer (ej. `-60`) si *sí* querés que una falla del plano de datos local fuerce el failover. Cuando co-localizás **HAProxy** en los mismos nodos, en su lugar hacés track de un script `killall -0 haproxy` para que la VIP siga a un HAProxy sano.

Tipos de health-check disponibles dentro de `real_server`: `TCP_CHECK` (solo conexión), `HTTP_GET`/`SSL_GET` (traer una URL, verificar status/digest), `SMTP_CHECK`, `MISC_CHECK` (ejecutar un script arbitrario; exit 0 = sano), `PING_CHECK`. `HTTP_GET` contra un endpoint `/healthz` real es fuertemente preferible sobre `TCP_CHECK`, que solo prueba que el puerto está abierto, no que la app pueda servir.

### 4.3 Verificación de keepalived

```
$ sudo systemctl status keepalived --no-pager
● keepalived.service - Keepalive Daemon (LVS and VRRP)
     Active: active (running) since Wed 2026-08-12 09:14:02 UTC; 3h ago

$ sudo journalctl -u keepalived -n 5 --no-pager
keepalived[8123]: (VI_WEB) Entering MASTER STATE
keepalived[8123]: (VI_WEB) setting VIPs.
keepalived[8123]: Sending gratuitous ARP on eth0 for 203.0.113.10

# VIP present ONLY on the MASTER:
$ ip -br addr show dev eth0 | grep 203.0.113.10
eth0   UP   203.0.113.2/24 203.0.113.10/32

# On the BACKUP the same grep returns nothing — that is correct.
```

---

## 5. HAProxy — proxy L4/L7 con ACLs

HAProxy es un proxy en espacio de usuario, orientado a eventos. A diferencia de IPVS, *termina* la conexión del cliente y abre una nueva hacia el backend, que es exactamente lo que le permite trabajar en L7: parsear HTTP, rutear por contenido, terminar TLS, reescribir headers, y reintentar. HAProxy moderno es multithread (`nbthread`), reemplazando el viejo modelo multiproceso `nbproc`.

### 5.1 Estructura de configuración

- `global` — a nivel de proceso: user/group, `maxconn`, threads, defaults de TLS, stats socket, logging.
- `defaults` — settings heredados por las secciones debajo (timeouts, mode, options).
- `frontend` — una dirección/puerto de bind y las reglas de ruteo (`acl` + `use_backend`).
- `backend` — un pool de líneas `server` más el algoritmo `balance` y los health checks.
- `listen` — un frontend+backend fusionados en un solo bloque (práctico para la página de stats o proxies TCP simples).

### 5.2 Algoritmos de load-balancing

| `balance` | Capa | Comportamiento | ¿Sticky? |
|---|---|---|---|
| `roundrobin` | — | rotar; weights dinámicos; ~4095 servers activos/backend | no |
| `static-rr` | — | rotar; weights estáticos (sin cambio en runtime); servers ilimitados | no |
| `leastconn` | — | menos conexiones activas | no |
| `first` | — | llenar el server de menor id hasta `maxconn`, luego el siguiente (ahorro de energía) | no |
| `source` | L3 | `hash(source IP)` | sí |
| `uri` | L7 | `hash(request URI)` | afinidad de cache |
| `url_param` | L7 | `hash(named query param)` | definido por la app |
| `hdr(<name>)` | L7 | `hash(header value)`, ej. `hdr(Host)` | por-header |
| `random` / `random(2)` | — | aleatorio; `random(2)` = power-of-two-choices | no |
| `rdp-cookie` | L7 | cookie de sesión RDP | sí |

`leastconn` para conexiones de larga duración (WebSocket, DB), `roundrobin` para HTTP corto sin estado, `source` cuando necesitás stickiness de cliente barato sin cookies, `uri` para capas de cache.

### 5.3 `haproxy.cfg` completo — ruteo L7, TLS, health checks, ACLs, stats

```
# /etc/haproxy/haproxy.cfg
global
    log         /dev/log local0
    chroot      /var/lib/haproxy
    user        haproxy
    group       haproxy
    daemon
    maxconn     100000
    nbthread    4
    cpu-map     auto:1/1-4 0-3

    # Runtime API for hitless reloads, live stats, dynamic server state
    stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
    stats timeout 30s

    # Modern, safe TLS baseline
    ssl-default-bind-ciphersuites TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256:TLS_CHACHA20_POLY1305_SHA256
    ssl-default-bind-ciphers ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384
    ssl-default-bind-options ssl-min-ver TLSv1.2 no-tls-tickets

defaults
    log     global
    mode    http
    option  httplog
    option  dontlognull
    option  http-server-close
    option  forwardfor          except 127.0.0.0/8   # inject X-Forwarded-For
    retries 3
    timeout connect 5s
    timeout client  50s
    timeout server  50s
    timeout http-request 10s
    timeout http-keep-alive 15s
    timeout queue   30s
    default-server inter 3s fall 3 rise 2 slowstart 20s

# ---------------- FRONTEND: TLS termination + content routing ----------------
frontend fe_https
    bind :80
    bind :443 ssl crt /etc/haproxy/certs/ alpn h2,http/1.1
    http-request redirect scheme https code 301 unless { ssl_fc }

    # Security headers
    http-response set-header Strict-Transport-Security "max-age=63072000; includeSubDomains"

    # ---- ACLs: match on path, host, method ----
    acl is_api        path_beg /api/
    acl is_static     path_end .css .js .png .jpg .svg .woff2
    acl is_admin      path_beg /admin
    acl host_media    hdr(host) -i media.example.com
    acl trusted_admin src 10.0.0.0/8 192.168.0.0/16

    # ---- Rate limit abusive clients using a stick-table ----
    stick-table type ip size 1m expire 10m store http_req_rate(10s)
    http-request track-sc0 src
    http-request deny deny_status 429 if { sc_http_req_rate(0) gt 100 }

    # ---- Routing decisions (first match wins) ----
    http-request deny deny_status 403 if is_admin !trusted_admin
    use_backend be_static  if is_static
    use_backend be_media   if host_media
    use_backend be_api     if is_api
    default_backend be_web

# ---------------- BACKENDS ----------------
backend be_web
    balance roundrobin
    option httpchk GET /healthz HTTP/1.1\r\nHost:\ health.local
    http-check expect status 200
    cookie SRVID insert indirect nocache            # L7 session stickiness
    server web1 10.0.0.11:8080 check cookie web1
    server web2 10.0.0.12:8080 check cookie web2
    server web3 10.0.0.13:8080 check cookie web3 backup   # only used if all primaries down

backend be_api
    balance leastconn
    option httpchk GET /api/health
    http-check expect status 200
    server api1 10.0.0.21:9000 check maxconn 500
    server api2 10.0.0.22:9000 check maxconn 500

backend be_static
    balance uri
    hash-type consistent                            # minimal remap when a cache node changes
    server cache1 10.0.0.31:80 check
    server cache2 10.0.0.32:80 check

backend be_media
    balance leastconn
    server media1 10.0.0.41:80 check

# ---------------- STATS PAGE ----------------
listen stats
    bind 127.0.0.1:8404
    stats enable
    stats uri /
    stats refresh 5s
    stats admin if TRUE
```

Notas que importan en producción:

- **`cookie SRVID insert indirect`** da stickiness L7 que sobrevive los reinicios del backend con más gracia que el hashing de IP detrás de carrier-grade NAT (donde miles de clientes comparten una sola IP de origen).
- **`server ... backup`** marca un cold-standby que solo recibe tráfico cuando todos los primaries están caídos.
- **`slowstart 20s`** rampa el weight de un server recién marcado `UP` de 0 a full a lo largo de 20 s para que una JVM recién reiniciada no reciba carga completa antes de que sus caches se calienten.
- **`hash-type consistent`** en la capa de cache significa que agregar/quitar un nodo de cache remapea solo ~1/N de las claves en lugar de reshufflear todo.
- **`expose-fd listeners`** en el stats socket es lo que habilita los **hitless reloads**: en un `reload`, el proceso nuevo recupera los sockets de escucha viejos a través del socket, así que no se dropea ninguna conexión y no se rechaza ningún SYN.

### 5.4 Operaciones de HAProxy

```
# Validate before touching the running service — never reload a bad config
$ haproxy -c -f /etc/haproxy/haproxy.cfg
Configuration file is valid

# Seamless reload (new workers inherit sockets, old workers drain then exit)
$ sudo systemctl reload haproxy

# Confirm the drain of old workers
$ ps -o pid,cmd -C haproxy
    PID CMD
   9001 /usr/sbin/haproxy -Ws -f /etc/haproxy/haproxy.cfg -p /run/haproxy.pid -sf 8800
```

Unit de systemd que realiza una verificación de config en cada reload (Debian/RHEL entregan un equivalente cercano):

```
# /etc/systemd/system/haproxy.service.d/override.conf
[Service]
ExecReload=/usr/sbin/haproxy -Ws -f /etc/haproxy/haproxy.cfg -c -q
ExecReload=/bin/kill -USR2 $MAINPID
```

---

## 6. Verificación y diagnóstico de fallas

### 6.1 IPVS — ¿el tráfico se está distribuyendo realmente?

```
$ sudo ipvsadm -Ln --stats
IP Virtual Server version 1.2.1 (size=4096)
Prot LocalAddress:Port               Conns   InPkts  OutPkts  InBytes OutBytes
  -> RemoteAddress:Port
TCP  203.0.113.10:80                 1451233 48937112 0       12G      0
  -> 10.0.0.11:80                    725841  24476201 0       6G       0
  -> 10.0.0.12:80                    725392  24460911 0       6G       0
```

**Oro de diagnóstico:** `OutPkts` y `OutBytes` son **0**. En los modos DR y TUN las respuestas nunca atraviesan el director, así que 0 es *correcto y esperado*. Si ves OutPkts distinto de cero en un servicio DR, o realmente estás en modo NAT o el tráfico de retorno está siendo mal ruteado a través del director — investigá. Al revés, si `Conns` va subiendo pero el `ActiveConn` de un backend se queda en 0, ese backend está arriba en la tabla pero no recibe tráfico (a menudo un health check lo sacó silenciosamente, o un problema de ARP).

Tabla de conexiones en vivo y tasa por backend:

```
$ sudo ipvsadm -Lnc | head
IPVS connection entries
pro expire state       source             virtual            destination
TCP 14:55  ESTABLISHED 198.51.100.7:51922 203.0.113.10:80    10.0.0.11:80
TCP 00:42  FIN_WAIT    198.51.100.9:40113 203.0.113.10:80    10.0.0.12:80
TCP 01:58  TIME_WAIT   198.51.100.3:33555 203.0.113.10:80    10.0.0.11:80

$ sudo ipvsadm -Ln --rate
Prot LocalAddress:Port                 CPS    InPPS   OutPPS    InBPS   OutBPS
  -> RemoteAddress:Port
TCP  203.0.113.10:80                    412    18320    0        14M      0
  -> 10.0.0.11:80                       205    9140     0        7M       0
  -> 10.0.0.12:80                       207    9180     0        7M       0
```

**El problema de ARP en DR — cómo detectarlo.** Síntoma: fallas intermitentes, o un subconjunto de clientes pegándole a un real server directamente y nunca balanceando. Desde un segmento de cliente, resolvé la VIP y verificá *quién* responde ARP:

```
$ arping -c 3 -I eth0 203.0.113.10
ARPING 203.0.113.10 from 198.51.100.1 eth0
Unicast reply from 203.0.113.10 [00:16:3e:aa:11:11]   0.6ms   # real server MAC — BUG
Unicast reply from 203.0.113.10 [00:16:3e:bb:22:22]   0.7ms   # another RS — BUG
```

Dos MACs distintas respondiendo por la VIP significa que los real servers están haciendo ARP para la VIP en `lo` — `arp_ignore`/`arp_announce` no están seteados o fueron reseteados. Corregí y re-verificá:

```
$ sysctl net.ipv4.conf.all.arp_ignore net.ipv4.conf.all.arp_announce
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2
```

**Agujero negro de MTU en TUN.** Síntoma: las peticiones chicas funcionan, los POSTs/descargas grandes se cuelgan. El header IP-in-IP de 20 bytes empujó un paquete de MTU completa por encima del límite del cable y el descubrimiento de PMTU está siendo filtrado. Confirmá con un barrido de ping do-not-fragment y bajá la MTU del túnel/backend (ej. 1480) o clampeá el MSS.

### 6.2 VRRP — split brain y flapping

```
# Watch VRRP adverts on the wire (multicast form)
$ sudo tcpdump -n -i eth0 vrrp
12:00:01.001 IP 203.0.113.2 > 224.0.0.18: VRRPv2, Advertisement, vrid 51, prio 150, authtype simple, intvl 1s, length 20
12:00:02.002 IP 203.0.113.2 > 224.0.0.18: VRRPv2, Advertisement, vrid 51, prio 150, authtype simple, intvl 1s, length 20
```

**Split brain (ambos nodos MASTER, VIP en los dos):** los dos directores no pueden verse los adverts uno al otro — un firewall dropeando el protocolo 112, un grupo de multicast `224.0.0.18` bloqueado, o un `virtual_router_id`/`auth_pass` desparejo. Detectalo directamente:

```
# Run on BOTH directors; the VIP must appear on exactly ONE.
$ ip -br addr | grep 203.0.113.10
# nodeA: eth0  UP  203.0.113.2/24 203.0.113.10/32
# nodeB: eth0  UP  203.0.113.3/24 203.0.113.10/32     <-- BOTH have it: SPLIT BRAIN
```

Checklist de causa raíz:
- `sudo iptables -L -n | grep -i vrrp` / permitir el proto 112 — muchos SGs de nube y firewalls de host lo dropean silenciosamente.
- ¿Multicast filtrada? Cambiá a `unicast_peer` (como en la config de arriba) — este es el fix estándar en nubes y muchas fabrics empresariales.
- `virtual_router_id` y `auth_pass` **idénticos** en ambos nodos, y el VRID único dentro del segmento L2 (un VRID en colisión de un cluster no relacionado causa elecciones extrañas).

**Flapping (la VIP rebotando cada pocos segundos):** normalmente `advert_int` demasiado agresivo para un enlace cargado/con pérdidas, o un `track_script` cuya caída de `weight` cruza la prioridad del peer ante fallas transitorias. Subí `fall`, agregá `preempt_delay`, o reducí la magnitud del `weight`.

Prueba de tiempo de failover — matá keepalived en el MASTER y cronometrá el takeover:

```
# On MASTER:
$ sudo systemctl stop keepalived
# On BACKUP, watch it promote (should be ~3× advert_int):
$ sudo journalctl -u keepalived -f
keepalived[7710]: (VI_WEB) Backup received priority 0 advertisement
keepalived[7710]: (VI_WEB) Entering MASTER STATE
keepalived[7710]: Sending gratuitous ARP on eth0 for 203.0.113.10
```

El advertisement de `priority 0` es la señal de graceful-shutdown de keepalived, que es por lo que un `stop` limpio hace failover más rápido que un corte de energía duro (este último espera el intervalo completo de master-down).

### 6.3 HAProxy — la runtime API

El stats socket es el centro neurálgico operativo; manejalo con `socat`.

```
$ echo "show stat" | sudo socat stdio /run/haproxy/admin.sock \
    | cut -d, -f1,2,18,5,8,37
# pxname,svname,status,scur,stot,rate
fe_https,FRONTEND,OPEN,1842,9930451,412
be_web,web1,UP,614,3310112,138
be_web,web2,UP,610,3298004,140
be_web,web3,UP,0,0,0            # backup server, no traffic — correct
be_web,BACKEND,UP,1224,6608116,278

# Why is a server down? show its check detail:
$ echo "show servers state be_api" | sudo socat stdio /run/haproxy/admin.sock
1
# be_id be_name srv_id srv_name srv_addr srv_op_state ...
6 be_api 1 api1 10.0.0.21 2 0 1 1 20 3 0 ...
6 be_api 2 api2 10.0.0.22 0 0 1 1 42 1 0 ...   # op_state 0 = DOWN

# Inspect the rate-limit / stickiness table:
$ echo "show table fe_https" | sudo socat stdio /run/haproxy/admin.sock
# table: fe_https, type: ip, size:1048576, used:3
0x7f...: key=198.51.100.7 use=0 exp=598000 http_req_rate(10000)=143   # over the 100 cap → 429

# Administratively drain a backend before maintenance (finish in-flight, take no new):
$ echo "set server be_web/web2 state drain" | sudo socat stdio /run/haproxy/admin.sock
$ echo "set server be_web/web2 state ready" | sudo socat stdio /run/haproxy/admin.sock
```

`srv_op_state 2 = UP`, `0 = DOWN`, `1 = STOPPING/draining`. Correlacioná un server `DOWN` con `option httpchk` — la causa más común es la URL de health devolviendo un no-200 (un `/healthz` detrás de auth, o un `Host` header equivocado), no que el backend esté realmente muerto. Reproducí el check exacto a mano:

```
$ curl -sS -o /dev/null -w '%{http_code}\n' -H 'Host: health.local' http://10.0.0.22:9000/api/health
503                    # <-- the app, not HAProxy, is unhealthy
```

### 6.4 Referencia rápida de modos de falla

| Síntoma | Causa probable | Confirmar con |
|---|---|---|
| El tráfico DR saltea el director; backend errático | Real servers haciendo ARP para la VIP | `arping -I eth0 <VIP>` → múltiples MACs |
| `OutPkts` de IPVS distinto de cero en un servicio "DR" | En realidad NAT, o ruteo asimétrico | `ipvsadm -Ln` → columna `Forward` |
| Ambos nodos sostienen la VIP | VRRP no intercambiado (fw/multicast/VRID/auth) | `ip -br addr` en ambos; `tcpdump vrrp` |
| La VIP flapea cada pocos segundos | `advert_int` demasiado bajo / track weight demasiado grande | `journalctl -u keepalived -f` |
| El failover rompe conexiones en vuelo | Sin sync de conexiones de IPVS | `ipvsadm -Ln --daemon` vacío |
| Las transferencias grandes de TUN se cuelgan, las chicas funcionan | Agujero negro de MTU / encapsulación | barrido de ping DF; bajar MTU/MSS |
| Backend de HAProxy `DOWN` pero la app está arriba | Desajuste de URL/Host/status del health-check | reproducir `curl` con el mismo Host/path |
| El reload dropea conexiones / rechaza SYNs | Restart duro al viejo estilo, sin transferencia de sockets | asegurar `-sf` + `expose-fd listeners` |
| Una IP de origen sobrecarga un backend | Hashing `source`/`sh` detrás de CGNAT | cambiar a cookie o `leastconn` |

---

## 7. Referencias

- LPI — Exam 306 Objectives (306‑300, v3.0), Topic 361.2: https://www.lpi.org/our-certifications/exam-306-objectives/
- The Linux Virtual Server Project (LVS) — forwarding methods, scheduling, HOWTOs: http://www.linuxvirtualserver.org/
- LVS‑DR ARP problem and configuration: http://www.linuxvirtualserver.org/docs/arp.html
- Linux kernel IPVS documentation and sysctls: https://docs.kernel.org/networking/ipvs-sysctl.html
- `ipvsadm(8)` manual page: https://man7.org/linux/man-pages/man8/ipvsadm.8.html
- keepalived — official site and documentation: https://www.keepalived.org/
- `keepalived.conf(5)` reference: https://www.keepalived.org/manpage.html
- HAProxy — official site: https://www.haproxy.org/
- HAProxy Configuration Manual: https://docs.haproxy.org/
- HAProxy Management Guide (runtime API / stats socket): https://docs.haproxy.org/2.8/management.html
- RFC 5798 — Virtual Router Redundancy Protocol (VRRP) v3: https://datatracker.ietf.org/doc/html/rfc5798
- RFC 3768 — VRRP v2: https://datatracker.ietf.org/doc/html/rfc3768
- Linux `arp` sysctl (`arp_ignore`, `arp_announce`): https://docs.kernel.org/networking/ip-sysctl.html