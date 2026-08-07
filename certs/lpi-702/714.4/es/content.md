# Guía de Estudio LPI-702: Tema 714.4 – Configuración de DNS del Lado del Cliente

**Certificación:** LPI BSD Specialist (Examen 702-100, Versión 1.0)  
**Tema:** 714.4 Configuración de DNS del Lado del Cliente  
**Peso del Examen:** 3.33 (Prioridad Alta)  
**Perfil Objetivo:** Senior SRE / Arquitecto Principal de Plataforma  

---

## 1. Motivación Arquitectónica y Planteamiento del Problema en Producción

En entornos de producción empresariales—que abarcan clusters BSD/Linux bare-metal, nubes híbridas y despliegues de Kubernetes de alta densidad—la resolución del Sistema de Nombres de Dominio (DNS) del lado del cliente es una dependencia crítica en la ruta de ejecución. Cada petición HTTP, llamada RPC, transacción de base de datos e invocación de microservicio comienza con un paso de resolución de nombre de host. Un DNS del lado del cliente configurado incorrectamente conduce a una amplificación catastrófica de la latencia de cola (tail latency), pérdida de paquetes, inanición de hilos (thread starvation) y cortes en cascada del sistema.

### 1.1 La Mecánica de la Resolución del Lado del Cliente: `getaddrinfo(3)` vs. Consultas Directas por Red

Los sistemas operativos resuelven nombres de host a través de dos mecanismos fundamentalmente distintos:

```
+-----------------------------------------------------------------------------------+
|                                 APPLICATION LAYER                                 |
+-----------------------------------------------------------------------------------+
           |                                                       |
           | Uses standard C Library API                           | Bypasses libc API
           v                                                       v
+-----------------------+                               +-----------------------+
|   getaddrinfo(3) /    |                               |      dig / drill /    |
|   gethostbyname(3)    |                               |        host CLI       |
+-----------------------+                               +-----------------------+
           |                                                       |
           v                                                       |
+-----------------------+                                          |
|  /etc/nsswitch.conf   | (Determines lookup order)                |
+-----------------------+                                          |
     |             |                                               |
     v             v                                               v
+----------+  +-----------------------+                 +-----------------------+
|  /etc/   |  |   /etc/resolv.conf    |                 |   /etc/resolv.conf    |
|  hosts   |  | (Nameservers/Options) |                 |  (Direct Nameserver)  |
+----------+  +-----------------------+                 +-----------------------+
                           |                                       |
                           +-------------------+-------------------+
                                               |
                                               v
                                    +---------------------+
                                    | Network Wire (UDP)  |
                                    | Port 53 / EDNS0     |
                                    +---------------------+
```

1. **Biblioteca C Estándar de POSIX (`libc` / `glibc` / `libc` de BSD):** Las aplicaciones estándar invocan funciones síncronas como `getaddrinfo(3)`. Esta capa lee `/etc/nsswitch.conf` para evaluar las fuentes de resolución de nombres en un orden estricto de izquierda a derecha (por ejemplo, archivos de host locales antes del DNS de red). Si se selecciona DNS, `libc` invoca sus rutinas de resolución internas, las cuales analizan `/etc/resolv.conf`.
2. **Utilidades de DNS Directo por Red (`dig`, `drill`, `host`):** Las órdenes de diagnóstico omiten `/etc/nsswitch.conf` y `/etc/hosts` por completo. Construyen tramas en formato binario de red DNS en bruto (raw DNS binary wire format) y las transmiten directamente a los servidores de nombres DNS upstream definidos en `/etc/resolv.conf` o proporcionados a través de flags de línea de comandos. Una resolución exitosa a través de `dig` **no** garantiza que una aplicación que llame a `getaddrinfo(3)` resuelva el mismo nombre de host.

### 1.2 Cuellos de Botella en Producción y Modos de Fallo

* **Bloqueo Monohilo e Inanición de Conexiones (Connection Starvation):** Los resolvers de la biblioteca C estándar no mantienen pools de sockets persistentes ni pools de hilos internos. Las llamadas síncronas a `getaddrinfo()` bloquean los hilos de trabajo (worker threads). Cuando un servidor DNS upstream experimenta una latencia elevada o pierde paquetes, los hilos de la aplicación se detienen esperando los timeouts de DNS (por defecto 5 segundos por intento), agotando los pools de hilos de la aplicación.
* **La Condición de Carrera en Netfilter Conntrack de Linux/BSD:** Cuando las aplicaciones consultan destinos de pila doble (`A` para IPv4 y `AAAA` para IPv6), `libc` envía dos consultas UDP simultáneamente a través de sockets distintos. En sistemas multinúcleo, los paquetes UDP paralelos que atraviesan las tablas de estado de `netfilter` de Linux o `pf` de BSD con la misma tupla de origen desencadenan una contención de bloqueos/condición de carrera en el seguimiento de conexiones (`conntrack`), lo que da lugar a respuestas DNS descartadas y retrasos inexplicables de 5 segundos.
* **Multiplicación por Dominio de Búsqueda (La Penalización de `ndots`):** Si un nombre de host de destino contiene menos puntos de los especificados por la directiva `ndots` en `/etc/resolv.conf`, el resolver añade secuencialmente cada dominio de búsqueda listado en la ruta de `search` antes de consultar el FQDN absoluto. En entornos de Kubernetes (`ndots:5`), consultar `external-api.stripe.com` (2 puntos) genera 4 consultas fallidas (`.svc.cluster.local`, `.cluster.local`, etc.) antes de emitir la consulta válida, multiplicando la carga del cluster DNS por 5x.
* **Penalización de Latencia No Cacheada:** Las búsquedas DNS remotas sobre UDP añaden entre 15ms y 50ms de latencia RTT. Los microservicios de alta frecuencia que realizan miles de conexiones salientes por segundo sufren una severa degradación del rendimiento sin almacenamiento en caché stub local (por ejemplo, Unbound o NodeLocal DNSCache), lo que reduce la latencia de los aciertos a niveles submilisegundo (<1ms).

---

## 2. Comparativa Técnica y Análisis de Alternativas (Trade-offs)

### Tabla 2.1: Modelos de Arquitectura DNS del Lado del Cliente

| Métrica / Dimensión | Resolver Stub Directo de `libc` (`/etc/resolv.conf`) | Resolver Caché con Daemon Local (Unbound) | Proxy Node-Local / DNSCache de Kubernetes |
| :--- | :--- | :--- | :--- |
| **Latencia de Búsqueda** | Alta (15ms–100ms por RTT) | Muy Baja (<1ms en acierto de caché) | Ultra Baja (<0.5ms vía loopback local) |
| **Sobrecarga de Recursos** | Casi Nula (Memoria en proceso) | Baja (~15MB–50MB RAM, escalable por CPU) | Baja-Media (~30MB RAM por Nodo) |
| **Soporte de Caché** | Ninguno (Cada llamada va a la red) | Avanzado (RRset, Infra, Negativo, Prefetch) | Avanzado (Motor CoreDNS/Unbound) |
| **Resiliencia y Conmutación por Error** | Deficiente (Round-robin / timeout básico) | Alta (Serve-Expired, Health checks) | Máxima (La caché local protege de fallos upstream) |
| **Validación DNSSEC** | Ninguna (Confía totalmente en el flag `AD` del resolver) | Validación Completa Nativa En Proceso | Proxy o Validación Completa según el motor |
| **Complejidad** | Mínima (Edición simple de archivo de texto) | Media (Requiere gestión de procesos) | Alta (Requiere DaemonSets, iptables/nftables) |

### Tabla 2.2: Comparativa de Herramientas de Inspección

| Característica | `getent hosts` | `dig` (Herramientas BIND) | `drill` (NLnet Labs / ldns) | `host` |
| :--- | :--- | :--- | :--- | :--- |
| **Subsistema Probado** | Stacking Completo del Sistema (`nsswitch.conf` + `libc`) | Protocolo Directo por Red (UDP/TCP Puerto 53) | Protocolo Directo por Red (UDP/TCP Puerto 53) | Protocolo Directo por Red (Simple) |
| **Respeta `/etc/hosts`** | **Sí** | **No** | **No** | **No** |
| **Respeta `nsswitch.conf`**| **Sí** | **No** | **No** | **No** |
| **Predeterminado en BSD** | Sí | Opcional (ports/packages) | **Sí (Predeterminado en FreeBSD/OpenBSD)** | Opcional / Base según el SO |
| **Flags EDNS0 / DNSSEC** | No | Control completo (`+dnssec`, `+bufsize`) | Control completo (`-D`, `-s`) | Básico |
| **Formato de Salida** | Sintaxis analizada de `/etc/hosts` | Formato Estándar Master File / Verboso | Formato Master File (Limpio) | Resumen de texto legible por humanos |

### Tabla 2.3: Alternativas de Protocolos de Transporte DNS

| Protocolo de Transporte | Carga Útil Máxima (Payload) | Sobrecarga / Handshake | Capacidad de Atravesar Firewalls | MTU / Riesgo de Fragmentación |
| :--- | :--- | :--- | :--- | :--- |
| **UDP Estándar** | 512 Bytes | 0 RTT (Sin estado / Stateless) | Alta (Puerto 53 abierto) | Ninguno (Ajusta dentro de MTU estándar) |
| **UDP + EDNS0** | 1232–4096 Bytes | 0 RTT | Alta (Puerto 53 abierto) | **Alto** si el payload > Path MTU (Caída de fragmentos) |
| **TCP (`use-vc`)** | 65535 Bytes | 1 RTT (SYN-ACK) + Desconexión | Alta (Puerto 53 TCP) | Bajo (Manejado por segmentación TCP MSS) |
| **DNS over TLS (DoT)**| 65535 Bytes | Handshake TLS 1.3 (1-2 RTT) | Media (Requiere Puerto 853 abierto) | Bajo (Encapsulamiento de payload TCP/TLS) |

---

## 3. Manifiestos de Producción y Especificaciones de Configuración

### 3.1 Configuración de Name Service Switch en Producción (`/etc/nsswitch.conf`)

Esta configuración dicta el orden de búsqueda para la resolución de nombres de host. Las invalidaciones estáticas locales en `/etc/hosts` tienen prioridad, seguidas de las consultas DNS. La política `[NOTFOUND=return]` evita recurrir a fuentes de resolución posteriores si los archivos locales informan explícitamente que un dominio no existe.

```ini
# /etc/nsswitch.conf - Production Host Resolution Configuration
# Syntax: database: source1 [action1] source2 [action2]

group:       files
group_compat: nis
hosts:       files dns [NOTFOUND=return]
networks:    files
passwd:      files
passwd_compat: nis
shells:      files
services:    files
protocols:   files
rpc:         files
```

---

### 3.2 Configuración del Resolver del Cliente Empresarial (`/etc/resolv.conf`)

Este archivo configura el comportamiento del resolver stub de `libc`. Todas las opciones están optimizadas para cargas de trabajo de producción de alto rendimiento y tolerantes a fallos.

```ini
# /etc/resolv.conf - Enterprise Client DNS Resolver Configuration

# Primary, Secondary, and Tertiary Upstream Recursive Nameservers
nameserver 10.240.0.10
nameserver 10.240.0.11
nameserver 1.1.1.1

# Domain Search Path (Keep short to avoid lookup multiplication penalties)
search infrastructure.internal production.corp

# Resolver Control Options:
# ndots:2            - Perform direct FQDN query if domain contains >= 2 dots.
# timeout:1          - Wait 1 second for a response before timing out (Default: 5s).
# attempts:2         - Query upstream nameservers a maximum of 2 times (Default: 2).
# rotate             - Round-robin load balance queries across all listed nameservers.
# single-request-reopen - Force socket closure and recreate a new socket for A and AAAA
#                      queries. Mitigates netfilter/conntrack UDP race conditions.
# edns0              - Enable EDNS0 extensions (supports large buffer sizes > 512B).
# trust-ad           - Pass Authentic Data (AD) bit from upstream validating resolver to app.
options ndots:2 timeout:1 attempts:2 rotate single-request-reopen edns0 trust-ad
```

---

### 3.3 Resolver Caché Local de Producción (`/etc/unbound/unbound.conf`)

Unbound es un resolver DNS recursivo con caché y validación, ligero y de nivel empresarial. A continuación se presenta una configuración de producción completa y sintácticamente válida optimizada para sistemas multihilo.

```yaml
# /etc/unbound/unbound.conf - Production Caching Resolver Configuration

server:
    # Interface and Port Bindings
    interface: 127.0.0.1
    interface: ::1
    port: 53
    do-ip4: yes
    do-ip6: yes
    do-udp: yes
    do-tcp: yes

    # Access Control Enforcement
    access-control: 127.0.0.0/8 allow
    access-control: ::1/128 allow
    access-control: 0.0.0.0/0 refuse

    # Performance Tuning & Memory Optimization
    num-threads: 4
    msg-cache-slabs: 4
    rrset-cache-slabs: 4
    infra-cache-slabs: 4
    key-cache-slabs: 4
    
    # Memory Sizing (Adjust according to host capacity)
    rrset-cache-size: 128m
    msg-cache-size: 64m
    key-cache-size: 32m
    infra-cache-numhosts: 10000

    # EDNS0 Buffer Safety (1232 bytes prevents IP fragmentation over standard 1500 MTU)
    edns-buffer-size: 1232
    max-udp-size: 1232

    # Prefetching and Resilience (Serve-Expired mitigates upstream outages)
    prefetch: yes
    prefetch-key: yes
    serve-expired: yes
    serve-expired-ttl: 86400
    serve-expired-client-timeout: 1800

    # Hardening & Security Policies
    harden-glue: yes
    harden-dnssec-stripped: yes
    harden-below-nxdomain: yes
    harden-referral-path: yes
    use-caps-for-id: no
    hide-identity: yes
    hide-version: yes
    identity: "DNS Resolver"

    # DNSSEC Root Anchor Configuration
    auto-trust-anchor-file: "/var/unbound/db/root.key"

    # Logging Parameters
    verbosity: 1
    log-queries: no
    log-replies: no
    use-syslog: yes

# Forwarding Zones - Route queries to authoritative enterprise DNS infrastructure
forward-zone:
    name: "."
    forward-addr: 10.240.0.10@53
    forward-addr: 10.240.0.11@53
    forward-first: yes

forward-zone:
    name: "internal.production."
    forward-addr: 10.250.0.1#53
```

---

### 3.4 Configuración de NodeLocal DNSCache en Kubernetes

Este manifiesto de Kubernetes despliega NodeLocal DNSCache en los nodos para interceptar las consultas de los clientes, eliminando las condiciones de carrera en el seguimiento de conexiones y almacenando las respuestas localmente en caché.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: node-local-dns
  namespace: kube-system
  labels:
    addonmanager.kubernetes.io/mode: Reconcile
data:
  Corefile: |
    cluster.local:53 {
        errors
        cache {
                success 9984 30
                denial 9984 5
        }
        reload
        loop
        bind 169.254.20.10
        forward . 10.96.0.10 {
                force_tcp
        }
        prometheus :9253
    }
    .:53 {
        errors
        cache 30
        reload
        loop
        bind 169.254.20.10
        forward . /etc/resolv.conf
        prometheus :9253
    }
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-local-dns
  namespace: kube-system
  labels:
    k8s-app: node-local-dns
spec:
  selector:
    matchLabels:
      k8s-app: node-local-dns
  template:
    metadata:
      labels:
        k8s-app: node-local-dns
    spec:
      priorityClassName: system-node-critical
      serviceAccountName: node-local-dns
      hostNetwork: true
      dnsPolicy: Default
      tolerations:
      - operator: Exists
        effect: NoSchedule
      containers:
      - name: node-cache
        image: registry.k8s.io/dns/k8s-dns-node-cache:1.22.28
        resources:
          requests:
            cpu: 25m
            memory: 25Mi
          limits:
            memory: 100Mi
        args:
        - -localip
        - 169.254.20.10
        - -conf
        - /etc/Corefile
        - -upstreamdns-config
        - /etc/kube-dns/config
        securityContext:
          capabilities:
            add:
            - NET_ADMIN
        volumeMounts:
        - mountPath: /etc/Corefile
          name: config-volume
        - mountPath: /etc/kube-dns
          name: kube-dns-config
      volumes:
      - name: config-volume
        configMap:
          name: node-local-dns
          items:
            - key: Corefile
              path: Corefile
      - name: kube-dns-config
        configMap:
          name: kube-dns
          optional: true
```

---

## 4. Comandos Reales de CLI y Salidas de Terminal en Producción

### 4.1 Consulta de Registros DNS con `dig`

Ejecución de una consulta de registro `A` con validación DNSSEC (`+dnssec`) y seguimiento de la latencia de respuesta:

```bash
$ dig +dnssec +multiline api.github.com A
```

**Output:**
```text
; <<>> DiG 9.18.28 <<>> +dnssec +multiline api.github.com A
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 48291
;; flags: qr rd ra ad; QUERY: 1, ANSWER: 3, AUTHORITY: 0, ADDITIONAL: 1

;; OPT PSEUDOSECTION:
; EDNS: version 0, flags: do; udp: 1232
;; QUESTION SECTION:
;api.github.com.		IN A

;; ANSWER SECTION:
api.github.com.		60 IN CNAME dualstack.g.github.com.
dualstack.g.github.com.	60 IN A 140.82.121.4
dualstack.g.github.com.	60 IN RRSIG A 13 3 60 20260807024412 (
				20260806004412 34070 github.com.
				pL8/kU3Z2mHq/K7tS0lA9dY8zQn31xZ2A8B9C0D1
				E2F3G4H5I6J7K8L9M0N= )

;; Query time: 14 msec
;; SERVER: 10.240.0.10#53(10.240.0.10) (UDP)
;; WHEN: Thu Aug 06 20:55:24 EDT 2026
;; MSG SIZE  rcvd: 214
```

---

### 4.2 Consulta de Registros DNS en BSD con `drill`

`drill` es la utilidad estándar de consulta DNS en sistemas BSD (FreeBSD, OpenBSD, NetBSD), construida sobre la biblioteca `ldns`.

Ejecución de una búsqueda inmensa/inversa de puntero DNS (`PTR`) usando `drill`:

```bash
$ drill -x 140.82.121.4
```

**Output:**
```text
;; ->>HEADER<<- opcode: QUERY, rcode: NOERROR, id: 18402
;; flags: qr rd ra ; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 0
;; QUESTION SECTION:
;; 4.121.82.140.in-addr.arpa.	IN	PTR

;; ANSWER SECTION:
4.121.82.140.in-addr.arpa.	3600	IN	PTR	lb-140-82-121-4-iad.github.com.

;; AUTHORITY SECTION:

;; ADDITIONAL SECTION:

;; Query time: 18 msec
;; SERVER: 127.0.0.1
;; WHEN: Thu Aug 06 20:55:24 2026
;; MSG SIZE rcvd: 87
```

---

### 4.3 Consulta de Registros SRV de Descubrimiento de Servicios

Evaluación de registros de servicio (`SRV`) para HashiCorp Consul o servicios de cluster de Kubernetes:

```bash
$ host -t SRV _k8s-cat-port._tcp.my-service.default.svc.cluster.local
```

**Output:**
```text
_k8s-cat-port._tcp.my-service.default.svc.cluster.local has SRV record 0 100 8080 10-244-1-45.my-service.default.svc.cluster.local.
```

---

### 4.4 Auditoría de la Capa NSS a Nivel de Sistema vía `getent`

Verificación de la resolución de host a través del pipeline de `libc`/`/etc/nsswitch.conf` del SO frente a DNS directo por red. Este comando comprueba `/etc/hosts` primero, respetando las reglas de configuración del SO:

```bash
$ getent hosts db-primary.internal
```

**Output:**
```text
10.240.5.50     db-primary.internal db-primary
```

---

### 4.5 Inspección de Métricas de Caché en Tiempo de Ejecución de Unbound

Uso de `unbound-control` para inspeccionar aciertos de caché, consumo de memoria y estado operativo:

```bash
$ unbound-control stats_noreset
```

**Output:**
```text
total.num.queries=148592
total.num.cachehits=139201
total.num.cachemiss=9391
total.num.prefetch=4120
total.num.zero_ttl=102
total.num.recursivereplies=9391
total.requestlist.avg=0.42
total.requestlist.max=12
total.requestlist.overwritten=0
total.requestlist.exceeded=0
total.tcpusage=4
time.up=86400.221045
time.elapsed=86400.221045
mem.cache.rrset=67108864
mem.cache.message=33554432
mem.mod.iterator=16384
mem.mod.validator=524288
```

---

### 4.6 Rastro de Sockets en Tiempo Real con `tcpdump`

Captura de consultas DNS del lado del cliente para inspeccionar flags de red, IDs de transacción y protocolos de transporte:

```bash
$ sudo tcpdump -nn -i eth0 -s 0 'port 53'
```

**Output:**
```text
20:55:24.104921 IP 10.240.0.50.41092 > 10.240.0.10.53: 48291+ [1au] A? api.github.com. (43)
20:55:24.118204 IP 10.240.0.10.53 > 10.240.0.50.41092: 48291 2/0/1 CNAME dualstack.g.github.com., A 140.82.121.4 (98)
20:55:24.118310 IP 10.240.0.50.59821 > 10.240.0.10.53: 12049+ [1au] AAAA? api.github.com. (43)
20:55:24.132115 IP 10.240.0.10.53 > 10.240.0.50.59821: 12049 2/0/1 CNAME dualstack.g.github.com., AAAA 2606:50c0:8000::64 (110)
```

---

## 5. Guía de Verificación y Resolución de Problemas (Runbook)

### 5.1 Diagrama de Flujo de Diagnóstico en Producción

```
                          [DNS Failure Reported]
                                    |
                                    v
                     Is the issue system-wide or app-specific?
                                    |
        +---------------------------+---------------------------+
        |                                                       |
        v                                                       v
 [App-Specific Failure]                                [System-Wide Failure]
        |                                                       |
        v                                                       v
Run `getent hosts <domain>`                             Run `dig +trace <domain>` /
Check /etc/nsswitch.conf order                         `drill -TD <domain>`
Check /etc/hosts for static overrides                   Inspect wire latency
        |                                                       |
        +---------------------------+---------------------------+
                                    |
                                    v
                  Check /etc/resolv.conf configuration
                                    |
          +-------------------------+-------------------------+
          |                                                   |
          v                                                   v
[UDP Timeout / 5s Delay]                           [SERVFAIL / DNSSEC Error]
          |                                                   |
          v                                                   v
Add `single-request-reopen`                         Validate upstream trust anchors
Verify MTU / EDNS0 size (1232)                      Check system time sync (NTP)
Check iptables/pf conntrack table                   Verify EDNS0 `do` flag handling
```

---

### 5.2 Escenarios de Fallo y Remediación de Emergencia

#### Escenario A: El Pico de Latencia de 5 Segundos (Condición de Carrera en Netfilter/Conntrack)
* **Síntoma:** Los microservicios experimentan aleatoriamente retrasos de 5.003 segundos durante peticiones HTTP/gRPC. Se observa una caída visible de paquetes UDP en la telemetría del firewall.
* **Causa Raíz:** Las peticiones paralelas `A` y `AAAA` comparten el mismo puerto de origen y ruta de secuencia, desencadenando una condición de carrera de bloqueo en el seguimiento de conexiones del kernel (`conntrack`).
* **Remediación:** Actualizar las opciones de `/etc/resolv.conf` para incluir `single-request-reopen`. Esto fuerza a `libc` a cerrar el socket y abrir uno nuevo antes de transmitir la consulta secundaria:
  ```ini
  options single-request-reopen
  ```

#### Escenario B: Alta Latencia Upstream debido a la Amplificación del Dominio de Búsqueda
* **Síntoma:** Los servidores CoreDNS o Bind upstream alcanzan el 100% de CPU. La telemetría muestra volúmenes masivos de consultas inválidas (`app.production.svc.cluster.local.svc.cluster.local`).
* **Causa Raíz:** El ajuste `ndots` en `/etc/resolv.conf` es demasiado alto (por ejemplo, `ndots:5`), lo que fuerza a las búsquedas FQDN con menos puntos a iterar a través de toda la ruta de `search`.
* **Remediación:** Reducir `ndots` a `2` o `1` en las configuraciones del cliente, o añadir un punto final (`.`) a los nombres de host absolutos dentro del código de la aplicación (por ejemplo, `api.stripe.com.`):
  ```ini
  options ndots:2
  ```

#### Escenario C: Truncamiento por Agujero Negro de Path MTU (Caídas de Búfer EDNS0)
* **Síntoma:** Las consultas `dig` con `+edns0` fallan o se cuelgan, pero las consultas cortas básicas tienen éxito. Las respuestas grandes (por ejemplo, registros firmados por DNSSEC) sufren timeout.
* **Causa Raíz:** El DNS upstream devuelve una carga útil UDP mayor que la Path MTU (por ejemplo, 4096 bytes en un enlace de 1500 bytes), causando fragmentación IP. Los firewalls o routers descartan los fragmentos IP.
* **Remediación:** Limitar el tamaño del búfer EDNS0 del lado del cliente en `/etc/unbound/unbound.conf` o `/etc/resolv.conf` a un umbral seguro de `1232` bytes:
  ```yaml
  edns-buffer-size: 1232
  max-udp-size: 1232
  ```

#### Escenario D: `SERVFAIL` Devuelto en Resolvers con Validación DNSSEC
* **Síntoma:** Los resolvers devuelven `RCODE 2 (SERVFAIL)`. Las búsquedas directas sin validar tienen éxito.
* **Causa Raíz:** El desajuste de reloj del sistema (skew) en el host cliente provoca que las ventanas de tiempo de firma DNSSEC válidas (marcas de tiempo de inicio y expiración de `RRSIG`) se rechacen por haber expirado o no ser válidas aún.
* **Remediación:** Sincronizar los relojes de hardware del SO cliente a través de NTP/Chrony y probar la validación:
  ```bash
  $ sudo chronyc tracking
  $ drill -D api.github.com
  ```

---

## 6. Referencias

* **Linux Professional Institute (LPI) BSD Specialist Overview:**  
  https://www.lpi.org/our-certifications/bsd-specialist-overview/
* **LPI Wiki – Topic 714.4 Objectives:**  
  https://wiki.lpi.org/wiki/BSD_Specialist_Objectives_V1.0
* **FreeBSD Manual Pages – resolv.conf(5):**  
  https://man.freebsd.org/cgi/man.cgi?resolv.conf(5)
* **FreeBSD Manual Pages – nsswitch.conf(5):**  
  https://man.freebsd.org/cgi/man.cgi?nsswitch.conf(5)
* **NLnet Labs Unbound Documentation:**  
  https://nlnetlabs.nl/documentation/unbound/unbound.conf/
* **Kubernetes Official Documentation – NodeLocal DNSCache:**  
  https://kubernetes.io/docs/tasks/administer-cluster/nodelocaldns/
* **IETF RFC 6891 – Extension Mechanisms for DNS (EDNS(0)):**  
  https://datatracker.ietf.org/doc/html/rfc6891