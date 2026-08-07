# LPI Security Essentials (020-100) — Topic 4.1: Network and Service Security

**Código de examen:** 020-100  
**Versión:** 1.0  
**Dominio:** Network and Service Security (Topic 024 / 4.1)  
**Ponderación:** 20  
**Rol objetivo:** Senior SRE / Platform Architect / Linux Security Specialist  

---

## Fuentes oficiales de referencia
* **Linux Professional Institute (LPI) Security Essentials Overview:** [https://www.lpi.org/our-certifications/security-essentials-overview/](https://www.lpi.org/our-certifications/security-essentials-overview/)
* **Materiales de aprendizaje de LPI para el examen 020-100:** [https://learning.lpi.org/en/learning-materials/020-100/](https://learning.lpi.org/en/learning-materials/020-100/)
* **Documentación oficial de Netfilter / nftables:** [https://netfilter.org/projects/nftables/](https://netfilter.org/projects/nftables/)
* **IETF RFC 8446 — The Transport Layer Security (TLS) Protocol Version 1.3:** [https://datatracker.ietf.org/doc/html/rfc8446](https://datatracker.ietf.org/doc/html/rfc8446)
* **Arquitectura del protocolo WireGuard:** [https://www.wireguard.com/papers/wireguard.pdf](https://www.wireguard.com/papers/wireguard.pdf)
* **IETF RFC 4033 — DNS Security Introduction and Requirements (DNSSEC):** [https://datatracker.ietf.org/doc/html/rfc4033](https://datatracker.ietf.org/doc/html/rfc4033)

---

## Ejercicio 1: Mecánica de red en el kernel de Linux, inspección de estados de sockets y análisis de tráfico

### Visión general de la arquitectura y mecánica interna
La pila de red del kernel de Linux procesa los paquetes entrantes a través de una secuencia determinista de capas de subsistemas:
1. **NIC Driver & NAPI:** Las interrupciones de hardware (Hard interrupts) activan SoftIRQs (`NET_RX_SOFTIRQ`), realizando polling de paquetes hacia los ring buffers de `sk_buff`.
2. **Link Layer (L2):** Desencapsula los encabezados Ethernet, realiza filtrado MAC, verifica las entradas de la caché ARP y pasa las tramas válidas hacia arriba.
3. **Network Layer (L3):** Evalúa los encabezados IPv4/IPv6. Si el host no actúa como router, `net.ipv4.ip_forward` debe permanecer en `0`. El Reverse Path Filtering del kernel (`rp_filter`) verifica que los paquetes entrantes lleguen por la interfaz que coincide con la mejor ruta de retorno de la tabla de enrutamiento, neutralizando ataques de IP spoofing.
4. **Transport Layer (L4):** Valida las sumas de comprobación (checksums) TCP/UDP y contrasta las tuplas de 5 elementos `(Source IP, Source Port, Destination IP, Destination Port, Protocol)` con los descriptores de socket registrados en la tabla de búsqueda de sockets del kernel.

```
       +-------------------------------------------------------------------+
       |                       Linux Kernel Netfilter                      |
       |                                                                   |
[NIC] ---> [PREROUTING] ---> [Routing Decision] ---> [FORWARD] ---> [POSTROUTING] ---> [NIC]
              |                                            ^
              v                                            |
           [INPUT]                                     [OUTPUT]
              |                                            ^
              +-------------> [Socket Buffer] -------------+
```

### Pasos de implementación guiada

1. **Auditar la configuración de reenvío de paquetes y Reverse Path Filtering del kernel**  
   Ejecutá `sysctl` para inspeccionar los parámetros de seguridad del kernel que rigen el procesamiento de paquetes L3:

   ```bash
   sudo sysctl net.ipv4.ip_forward net.ipv4.conf.all.rp_filter net.ipv4.conf.default.rp_filter net.ipv6.conf.all.forwarding
   ```

   **Salida esperada:**
   ```text
   net.ipv4.ip_forward = 0
   net.ipv4.conf.all.rp_filter = 1
   net.ipv4.conf.default.rp_filter = 1
   net.ipv6.conf.all.forwarding = 0
   ```

2. **Inspeccionar los estados de sockets de la capa de transporte y los listeners activos**  
   Usá `ss` (Socket Statistics) con salida numérica directa para auditar los sockets en escucha y las vinculaciones de procesos, filtrando los sockets TCP que no estén establecidos:

   ```bash
   sudo ss -tulpn
   ```

   **Salida esperada:**
   ```text
   Netid State   Recv-Q Send-Q    Local Address:Port      Peer Address:PortProc
   udp   UNCONN  0      0               0.0.0.0:68             0.0.0.0:*    users:(("dhclient",pid=842,fd=6))
   tcp   LISTEN  0      128             0.0.0.0:22             0.0.0.0:*    users:(("sshd",pid=1104,fd=3))
   tcp   LISTEN  0      511           127.0.0.1:6379           0.0.0.0:*    users:(("redis-server",pid=1420,fd=6))
   tcp   LISTEN  0      4096            0.0.0.0:443            0.0.0.0:*    users:(("nginx",pid=2048,fd=7))
   ```

3. **Capturar y analizar tramas de protocolo sin procesar usando `tcpdump`**  
   Realizá una captura de paquetes no promiscuos en la interfaz principal (`eth0`), filtrando los paquetes TCP SYN para detectar intentos de conexión no autorizados o escaneos de puertos:

   ```bash
   sudo tcpdump -i eth0 -nn -vvv -c 3 'tcp[tcpflags] & (tcp-syn) != 0 and tcp[tcpflags] & (tcp-ack) == 0'
   ```

   **Salida esperada:**
   ```text
   tcpdump: listening on eth0, link-type EN10MB (Ethernet), capture size 262144 bytes
   00:48:12.104928 IP (tos 0x0, ttl 64, id 54321, offset 0, flags [DF], proto TCP (6), length 60)
       192.168.1.50.48290 > 192.168.1.10.443: Flags [S], cksum 0x1a2b (correct), seq 382910482, win 64240, options [mss 1460,sackOK,TS val 2849102 ecr 0,nop,wscale 7], length 0
   00:48:12.105110 IP (tos 0x0, ttl 64, id 54322, offset 0, flags [DF], proto TCP (6), length 60)
       192.168.1.50.48292 > 192.168.1.10.22: Flags [S], cksum 0x3c4d (correct), seq 109284019, win 64240, options [mss 1460,sackOK,TS val 2849102 ecr 0,nop,wscale 7], length 0
   ```

---

### Preguntas de verificación — Ejercicio 1

**Pregunta 1.1:** Una auditoría de seguridad informa que `net.ipv4.conf.all.rp_filter` está configurado en `0` en un gateway de borde Linux multi-homed. ¿A qué vector de ataque específico expone esto al sistema y cómo ayuda la activación del modo estricto (`rp_filter = 1`) a mitigarlo en la capa de búsqueda de paquetes del kernel?

**Pregunta 1.2:** En la salida de `ss -tulpn`, `redis-server` está vinculado a `127.0.0.1:6379`, mientras que `nginx` está vinculado a `0.0.0.0:443`. ¿Cuáles son los pros y contras en materia de seguridad al vincular un servicio a `0.0.0.0` frente a una interfaz loopback o dedicada, y qué riesgo ocurre si Redis se expone accidentalmente en `0.0.0.0` sin autenticación?

---

## Ejercicio 2: Filtrado de paquetes con estado y defensa de perímetro con `nftables`

### Visión general de la arquitectura y mecánica interna
`nftables` es el marco moderno de clasificación de paquetes del kernel de Linux que reemplaza a `iptables`. Se ejecuta dentro de una pseudomáquina virtual de alto rendimiento (nftables VM) en el espacio del kernel:
* **Netfilter Hooks:** Los hooks interceptan paquetes en etapas de ejecución específicas (`prerouting`, `input`, `forward`, `output`, `postrouting`).
* **Connection Tracking (`conntrack`):** Realiza un seguimiento con estado (stateful) de las sesiones TCP/UDP/ICMP. Los estados incluyen `NEW` (SYN inicial), `ESTABLISHED` (handshake completado), `RELATED` (canales auxiliares como FTP-data) e `INVALID` (flags malformadas o números de secuencia fuera de ventana).
* **Optimización de reglas:** A diferencia de los recorridos de cadenas lineales de `iptables`, `nftables` utiliza conjuntos de búsqueda internos (`hash` y `rbtree`) permitiendo una complejidad temporal constante $O(1)$ para miles de rangos IP o definiciones de puertos.

```
Incoming Packet ---> Netfilter Hook (input) ---> Stateful Evaluation (conntrack)
                                                        |
         +----------------------------------------------+----------------------------------------------+
         |                                              |                                              |
 [State: INVALID]                             [State: ESTABLISHED]                               [State: NEW]
         |                                              |                                              |
   Action: DROP                                   Action: ACCEPT                                 Set Verification
 (Drop immediate)                              (Fast-path pass)                           (Port & IP Rate-Limit check)
```

### Pasos de implementación guiada

1. **Desplegar una directiva de filtrado con estado para producción**  
   Creá un archivo `/etc/nftables.conf` sintácticamente completo y apto para producción que implemente una postura de denegación por defecto (default-deny) en ingress, permita conexiones establecidas, proteja contra ataques TCP SYN flood mediante medidores (metering) e aísle el tráfico de loopback.

   Guardá el siguiente manifiesto en `/etc/nftables.conf`:

   ```nftables
   #!/usr/sbin/nft -f

   flush ruleset

   table inet global_firewall {
       # Set for dynamic blacklisting of malicious IPs
       set dynamic_blacklist {
           type ipv4_addr
           flags timeout
       }

       chain ingress_input {
           type filter hook input priority filter; policy drop;

           # Early drop for invalid connection states
           ct state invalid drop comment "Drop invalid TCP packet states"

           # Accept all loopback traffic
           iifname "lo" accept comment "Accept loopback traffic"

           # Allow stateful return traffic for outbound requests
           ct state established,related accept comment "Accept established & related connections"

           # Drop blacklisted source IPs dynamically
           ip saddr @dynamic_blacklist drop comment "Drop explicit blacklisted sources"

           # Rate-limit ICMP echo requests (Ping Flood protection)
           ip protocol icmp icmp type echo-request limit rate 5/second burst 10 packets accept
           ip protocol icmp icmp type echo-request drop

           # Rate-limit SSH ingress (Anti-bruteforce: max 3 new connections per minute per IP)
           tcp dport 22 ct state new meter ssh_meter { ip saddr limit rate 3/minute burst 5 packets } accept comment "Rate-limit SSH connection attempts"
           tcp dport 22 ct state new drop

           # Accept HTTPS (Port 443) and HTTP (Port 80)
           tcp dport { 80, 443 } ct state new accept comment "Allow web ingress"
       }

       chain egress_output {
           type filter hook output priority filter; policy accept;
       }

       chain transit_forward {
           type filter hook forward priority filter; policy drop;
       }
   }
   ```

2. **Cargar y verificar el conjunto de reglas en la memoria del kernel**  
   Aplicá el conjunto de reglas usando `nft` e inspeccioná las tablas de estado del kernel:

   ```bash
   sudo nft -f /etc/nftables.conf
   sudo nft list ruleset
   ```

   **Salida esperada:**
   ```text
   table inet global_firewall {
   	set dynamic_blacklist {
   		type ipv4_addr
   		flags timeout
   	}

   	chain ingress_input {
   		type filter hook input priority filter; policy drop;
   		ct state invalid drop comment "Drop invalid TCP packet states"
   		iifname "lo" accept comment "Accept loopback traffic"
   		ct state established,related accept comment "Accept established & related connections"
   		ip saddr @dynamic_blacklist drop comment "Drop explicit blacklisted sources"
   		ip protocol icmp icmp type echo-request limit rate 5/second burst 10 packets accept
   		ip protocol icmp icmp type echo-request drop
   		tcp dport 22 ct state new meter ssh_meter { ip saddr limit rate 3/minute burst 5 packets } accept comment "Rate-limit SSH connection attempts"
   		tcp dport 22 ct state new drop
   		tcp dport 80 ct state new accept comment "Allow web ingress"
   		tcp dport 443 ct state new accept comment "Allow web ingress"
   	}

   	chain egress_output {
   		type filter hook output priority filter; policy accept;
   	}

   	chain transit_forward {
   		type filter hook forward priority filter; policy drop;
   	}
   }
   ```

3. **Inspeccionar las entradas activas de seguimiento de conexiones (Connection Tracking)**  
   Usá `conntrack` para consultar en tiempo real los estados de sesión del kernel:

   ```bash
   sudo conntrack -L -p tcp --state ESTABLISHED
   ```

   **Salida esperada:**
   ```text
   tcp      6 431999 ESTABLISHED src=192.168.1.50 dst=192.168.1.10 sport=52104 dport=443 src=192.168.1.10 dst=192.168.1.50 sport=443 dport=52104 [ASSURED] mark=0 use=1
   conntrack v1.4.6 (conntrack-tools): 1 flow entries have been shown.
   ```

---

### Preguntas de verificación — Ejercicio 2

**Pregunta 2.1:** ¿Cuál es la diferencia operacional fundamental entre `policy drop` en la cadena `ingress_input` frente a añadir una regla de respaldo `reject` al final de la cadena? ¿Cuáles son las implicaciones de reconocimiento de red y consumo de recursos de ambos enfoques durante un escaneo de puertos activo?

**Pregunta 2.2:** En entornos SRE de alto rendimiento que manejan más de 500,000 conexiones TCP concurrentes, ¿qué fallo de subsistema del kernel ocurre si se supera la capacidad máxima de la tabla `conntrack` con estado (`net.netfilter.nf_conntrack_max`), y cómo pueden servicios específicos de alto volumen sin estado (por ejemplo, DNS, archivos estáticos) omitir el seguimiento de conexiones?

---

## Ejercicio 3: Robustecimiento de servicios, seguridad de transporte TLS 1.3 e aislamiento con Systemd

### Visión general de la arquitectura y mecánica interna
Asegurar los servicios de red requiere un enfoque multicapa: robustecer los entornos de ejecución de servicios mediante namespaces/cgroups de Linux y proteger la capa de transporte utilizando criptografía moderna.

* **Handshake TLS 1.3 (RFC 8446):** Elimina cifrados vulnerables heredados (RC4, 3DES, modo CBC) e intercambios de claves débiles (RSA estático, DH). TLS 1.3 reduce la latencia del handshake a 1-RTT (o 0-RTT mediante reanudación PSK) al combinar la negociación del suite de cifrado y el intercambio de claves Diffie-Hellman en el `ClientHello` inicial. Se exige Perfect Forward Secrecy (PFS) de forma obligatoria mediante Ephemeral Elliptic Curve Diffie-Hellman (ECDHE).

```
Client                                                               Server
  |                                                                    |
  |--- ClientHello (Key Share: ECDHE-X25519, CipherSuites) ---------->|
  |                                                                    |
  |                                  Selects Cipher Suite & Key Share  |
  |                                  Generates Server Ephemeral Key    |
  |                                  Derives Handshake Keys            |
  |                                                                    |
  |<-- ServerHello (Key Share: ECDHE-X25519) --------------------------|
  |<-- {EncryptedExtensions} ------------------------------------------|
  |<-- {Certificate & CertificateVerify} ------------------------------|
  |<-- {Finished} -----------------------------------------------------|
  |                                                                    |
  | Derives Application Keys                                           |
  |---> {Finished} --------------------------------------------------->|
  |                                                                    |
  |<=== [Application Data (Encrypted via AES-256-GCM / ChaCha20)] ====>|
```

* **Aislamiento de procesos mediante Systemd:** Restringe el acceso a llamadas al sistema (`Seccomp`), la visibilidad del sistema de archivos (`ProtectSystem=strict`) y los privilegios del kernel (`CapabilityBoundingSet=`).

### Pasos de implementación guiada

1. **Configurar el manifiesto de un servidor web NGINX robustecido con TLS 1.3**  
   Creá `/etc/nginx/conf.d/security_hardened.conf` para exigir TLS 1.3, encabezados HSTS strictly, estampar OCSP (OCSP stapling) y ciphers AEAD modernos:

   ```nginx
   # Hardened Production TLS 1.3 Site Configuration
   server {
       listen 443 ssl http2;
       listen [::]:443 ssl http2;
       server_name edge.production.internal;

       # X.509 Certificate Chain & Private Key
       ssl_certificate /etc/ssl/certs/production_chain.crt;
       ssl_certificate_key /etc/ssl/private/production.key;

       # Restrict Protocols strictly to TLS 1.3
       ssl_protocols TLSv1.3;

       # Modern AEAD Cipher Suites for TLS 1.3
       ssl_conf_command Ciphersuites TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256;

       # Session Optimization & Tickets Security
       ssl_session_timeout 1d;
       ssl_session_cache shared:SSL:10m;
       ssl_session_tickets off;

       # OCSP Stapling Mechanics
       ssl_stapling on;
       ssl_stapling_verify on;
       ssl_trusted_certificate /etc/ssl/certs/ca_root_chain.crt;
       resolver 1.1.1.1 8.8.8.8 valid=300s;
       resolver_timeout 5s;

       # HTTP Security Hardening Headers
       add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
       add_header X-Content-Type-Options "nosniff" always;
       add_header X-Frame-Options "DENY" always;
       add_header Content-Security-Policy "default-src 'self';" always;

       location / {
           root /var/www/html;
           index index.html;
       }
   }
   ```

2. **Robustecer la unidad de servicio mediante namespaces de Systemd**  
   Sobrescribí el archivo de unidad del servicio NGINX en systemd en `/etc/systemd/system/nginx.service.d/override.conf` para aplicar un aislamiento (sandboxing) estricto:

   ```ini
   [Service]
   # Capability Bounding
   CapabilityBoundingSet=CAP_NET_BIND_SERVICE
   AmbientCapabilities=CAP_NET_BIND_SERVICE
   NoNewPrivileges=true

   # File System Sandboxing
   ProtectSystem=strict
   ProtectHome=true
   ReadWritePaths=/var/log/nginx /var/run /var/cache/nginx
   PrivateTmp=true
   PrivateDevices=true

   # Kernel & Protocol Hardening
   ProtectKernelTunables=true
   ProtectKernelModules=true
   ProtectControlGroups=true
   RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
   MemoryDenyWriteExecute=true
   ```

3. **Verificar el handshake TLS 1.3 y el Cipher Suite mediante OpenSSL CLI**  
   Validá el cifrado de la capa de transporte y la negociación del handshake:

   ```bash
   openssl s_client -connect 127.0.0.1:443 -tls1_3 -servername edge.production.internal -brief
   ```

   **Salida esperada:**
   ```text
   CONNECTION ESTABLISHED
   Protocol version: TLSv1.3
   Ciphersuite: TLS_AES_256_GCM_SHA384
   Peer certificate: CN = edge.production.internal
   Hash type: SHA384
   Verification: OK
   Re-negotiation NOT supported
   ALPN protocol: h2
   Early data status: not sent
   ```

---

### Preguntas de verificación — Ejercicio 3

**Pregunta 3.1:** ¿Qué vulnerabilidad de seguridad criptográfica se mitiga al establecer `ssl_session_tickets off;` en configuraciones de TLS 1.3 cuando no existen mecanismos centralizados de rotación de claves de tickets en un clúster de balanceadores de carga SRE?

**Pregunta 3.2:** ¿Cómo protege la directiva de systemd `MemoryDenyWriteExecute=true` a un binario de servicio de red frente a exploits de corrupción de memoria (por ejemplo, ejecución de shellcode por desbordamiento de búfer), y qué entornos de ejecución dinámicos (como Node.js o las JVM de Java) se romperían si esta configuración está activada?

---

## Ejercicio 4: Domain Name System Security Extensions (DNSSEC) e integridad de resolución de nombres

### Visión general de la arquitectura y mecánica interna
El DNS estándar opera sobre UDP/53 no autenticado, lo que deja a la resolución de nombres vulnerable al envenenamiento de caché DNS (DNS Cache Poisoning) y la suplantación mediante Man-in-the-Middle (MitM).

**DNSSEC (RFC 4033)** añade autenticación criptográfica de origen y protección de integridad de datos al DNS mediante criptografía de clave pública:
* **RRSIG (Resource Record Signature):** Firma digital sobre un conjunto de registros RRset creada por la Zone Signing Key (ZSK) privada de la zona.
* **DNSKEY:** Contiene la Zone Signing Key (ZSK) pública y la Key Signing Key (KSK).
* **DS (Delegation Signer):** Digest de la KSK de la zona hija almacenado en la zona padre, estableciendo una cadena de confianza (**Chain of Trust**) ininterrumpida hasta el Root ICANN Trust Anchor.
* **NSEC/NSEC3:** Demuestra criptográficamente la inexistencia de un registro DNS (Authenticated Denial of Existence).

```
Root Zone (.) [Root Trust Anchor]
  |  DS Record (Hashes KSK of .org)
  v
.org Zone
  |  DS Record (Hashes KSK of example.org)
  v
example.org Zone
  ├── KSK (Key Signing Key) ---> Signs DNSKEY RRset (ZSK)
  └── ZSK (Zone Signing Key) ---> Signs A/AAAA Record Sets ---> Produces RRSIG Record
```

### Pasos de implementación guiada

1. **Realizar un rastreo de validación DNSSEC usando `dig`**  
   Consultá un dominio firmado con DNSSEC (`ietf.org`) solicitando registros DNSSEC (`+dnssec`) y formato multilínea (`+multi`):

   ```bash
   dig +dnssec +multi A ietf.org @1.1.1.1
   ```

   **Salida esperada:**
   ```text
   ;; Got answer:
   ;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 41285
   ;; flags: qr rd ra ad; QUERY: 1, ANSWER: 2, AUTHORITY: 0, ADDITIONAL: 1

   ;; OPT PSEUDOSECTION:
   ; EDNS: version: 0, flags: do; udp: 1232
   ;; QUESTION SECTION:
   ;ietf.org.		IN A

   ;; ANSWER SECTION:
   ietf.org.		300 IN A 104.16.44.99
   ietf.org.		300 IN RRSIG A 13 2 300 20260815000000 20260801000000 34185 ietf.org. +gH7bK9mF...
   ```

   > **Verificación crítica de flags:** Observá la flag `ad` (Authenticated Data) en el encabezado. Esto confirma que el resolver validador verificó la cadena completa de firmas con los root anchors de confianza.

2. **Validar criptográficamente la cadena de confianza usando `delv`**  
   Usá `delv` (Domain Entity Link Verification) para rastrear la prueba criptográfica desde las claves raíz hasta el registro de dirección del host:

   ```bash
   delv @1.1.1.1 ietf.org A +rtrace
   ```

   **Salida esperada:**
   ```text
   ;; fetch: . KSK KEY RSASHA256/20326 [...]
   ;; fully validated
   ;; fetch: org. DS SHA-256/26906 [...]
   ;; fully validated
   ;; fetch: ietf.org. DS SHA-256/34185 [...]
   ;; fully validated
   ;; unsigned answer: ietf.org. 300 IN A 104.16.44.99
   ;; fully validated
   ```

3. **Auditar la configuración del resolver local para la aplicación de DNSSEC**  
   Inspeccioná `/etc/systemd/resolved.conf` para asegurarte de que la validación de DNSSEC esté configurada en modo estricto en lugar de fallback:

   ```bash
   grep -E "^\[Resolve\]|^DNSSEC" /etc/systemd/resolved.conf
   ```

   **Salida esperada:**
   ```text
   [Resolve]
   DNSSEC=yes
   ```

---

### Preguntas de verificación — Ejercicio 4

**Pregunta 4.1:** ¿Cuál es la función específica de la flag `ad` (Authenticated Data) en el encabezado de respuesta DNS y por qué los stub resolvers que operan detrás de un proxy de caché local (por ejemplo, `systemd-resolved`) deben comunicarse a través de un canal de confianza (loopback o IPsec) al confiar en la flag `ad`?

**Pregunta 4.2:** Explicá cómo NSEC3 previene el zone walking (ataques de enumeración de zonas) en comparación con los registros NSEC estándar, y qué costo de rendimiento se introduce en los servidores DNS autoritativos cuando se utilizan altos conteos de iteraciones y valores de salt en los parámetros NSEC3.

---

## Ejercicio 5: Túneles cifrados, VPNs Mesh (WireGuard) y arquitectura de la capa de anonimato

### Visión general de la arquitectura y mecánica interna
Las redes privadas virtuales (VPNs) y las redes de anonimización protegen los datos en tránsito a través de redes públicas no confiables:

* **Mecánica del estado del kernel en WireGuard:** WireGuard opera dentro del kernel de Linux como una interfaz de red (`wg0`). Reemplaza las máquinas de estado heredadas de IPsec/OpenVPN con el **Noise Protocol Framework**. Utiliza **Cryptokey Routing**, que mapea claves públicas específicas a direcciones IP permitidas (`AllowedIPs`).
  * Criptografía: Curve25519 (Intercambio de claves), ChaCha20 (Cifrado simétrico), Poly1305 (Autenticación), BLAKE2s (Hashing).
  * Comportamiento sigiloso: WireGuard es completamente silencioso cuando no procesa tráfico válido; descarta paquetes no autenticados sin responder, volviendo a los hosts invisibles a los escaneos de puertos UDP.

```
       +-----------------------------------------------------------------------+
       |                         WireGuard Cryptokey Routing                   |
       |                                                                       |
       |  Inbound UDP 51820 Packet ---> Verify Poly1305 MAC                    |
       |                                       |                               |
       |                                Authenticated?                         |
       |                                    /     \                            |
       |                                 (Yes)    (No)                         |
       |                                  /         \                          |
       |     Decrypt Payload via ChaCha20            Silent Drop (No Response) |
       |                  |                                                    |
       |     Match Src IP to AllowedIPs                                        |
       |                  |                                                    |
       |     Forward Packet to wg0 Interface                                   |
       +-----------------------------------------------------------------------+
```

* **Onion Routing (Arquitectura de Tor):** Las redes de anonimato protegen los metadatos y el análisis de tráfico. Los datos están envueltos en múltiples capas de cifrado (como una cebolla) y se enrutan a través de un circuito de tres tipos de nodos:
  1. **Guard/Entry Node:** Ve la IP real del cliente, pero no puede ver el destino.
  2. **Middle Relay:** Ve únicamente los saltos anterior y siguiente; no puede ver la identidad del cliente ni el destino.
  3. **Exit Node:** Descifra la capa final y envía el tráfico al destino público. (Ve la carga útil en texto plano si no se utiliza TLS).

### Pasos de implementación guiada

1. **Construir la configuración de un gateway WireGuard para producción (`wg0.conf`)**  
   Creá la configuración del servidor en `/etc/wireguard/wg0.conf`:

   ```ini
   [Interface]
   # Tunnel IPv4/IPv6 Address Assignment
   Address = 10.200.0.1/24, fd42:42:42::1/64
   ListenPort = 51820

   # Server Private Key (Keep Secret)
   PrivateKey = SERVER_PRIVATE_KEY_PLACEHOLDER

   # Kernel Packet Forwarding & NAT Rules for Egress Isolation
   PostUp = sysctl -w net.ipv4.ip_forward=1
   PostUp = nft add table inet wg_nat
   PostUp = nft add chain inet wg_nat postrouting \{ type nat hook postrouting priority srcnat\; \}
   PostUp = nft add rule inet wg_nat postrouting oifname "eth0" masquerade
   PostDown = nft delete table inet wg_nat
   PostDown = sysctl -w net.ipv4.ip_forward=0

   [Peer]
   # Client 1: Engineering Laptop
   PublicKey = CLIENT1_PUBLIC_KEY_PLACEHOLDER
   AllowedIPs = 10.200.0.2/32, fd42:42:42::2/128

   [Peer]
   # Client 2: Edge Application Node
   PublicKey = CLIENT2_PUBLIC_KEY_PLACEHOLDER
   AllowedIPs = 10.200.0.3/32, fd42:42:42::3/128
   ```

2. **Levantar la interfaz de WireGuard y consultar el estado en el kernel**  
   Inicializá la interfaz usando `wg-quick` y auditá las estadísticas de la interfaz:

   ```bash
   sudo wg-quick up wg0
   sudo wg show wg0
   ```

   **Salida esperada:**
   ```text
   interface: wg0
     public key: 8vB...server_pubkey...=
     private key: (hidden)
     listening port: 51820

   peer: CLIENT1_PUBLIC_KEY_PLACEHOLDER
     endpoint: 203.0.113.45:61022
     allowed ips: 10.200.0.2/32, fd42:42:42::2/128
     latest handshake: 1 minute, 12 seconds ago
     transfer: 14.25 MiB received, 89.41 MiB sent
     persistent keepalive: every 25 seconds
   ```

3. **Auditar la capa de anonimato y la mecánica de aislamiento de egress**  
   Verificá que el tráfico que atraviesa proxies SOCKS5 anonimizados (como Tor en el puerto 9050) oculte completamente la dirección IP de origen:

   ```bash
   curl --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip
   ```

   **Salida esperada:**
   ```json
   {"IsTor":true,"IP":"185.220.101.5"}
   ```

---

### Preguntas de verificación — Ejercicio 5

**Pregunta 5.1:** En la tabla Cryptokey Routing de WireGuard, ¿qué sucede si dos bloques `[Peer]` separados están configurados con direcciones IP superpuestas en su directiva `AllowedIPs` (por ejemplo, ambos listando `10.200.0.2/32`)? ¿Cómo resuelve el kernel las ambigüedades de enrutamiento entrante y saliente?

**Pregunta 5.2:** Aunque Tor cifra el tráfico de carga útil de red a través de tres saltos internos, un SRE monitorea el tráfico que sale de un Tor Exit Node. Si un cliente de aplicación transmite tráfico HTTP (sin TLS) a través de Tor hacia un servicio backend, ¿qué límites de seguridad se mantienen y qué vulnerabilidades críticas permanecen expuestas en la capa del nodo de salida?

---

## <details><summary>Solucionario del control de comprensión y análisis de arquitectura</summary>

### Respuestas del Ejercicio 1
* **Respuesta 1.1:** Configurar `rp_filter = 0` permite que el kernel procese paquetes cuya dirección IP de origen no es alcanzable a través de la interfaz específica por la que llegaron. Esto expone al host al **IP Source Address Spoofing**, lo que permite a los atacantes en redes externas falsificar direcciones IP de origen de la red interna (por ejemplo, `10.0.0.0/8`) para eludir las ACL del firewall o lanzar ataques de reflexión. Habilitar el modo estricto (`rp_filter = 1`) hace que el kernel realice una búsqueda de enrutamiento inverso para la IP de origen de cada paquete entrante. Si la mejor ruta de retorno para esa IP no apunta de regreso a la interfaz exacta por la que llegó el paquete, el kernel lo descarta inmediatamente en L3 antes de que alcance cualquier servicio o socket.
* **Respuesta 1.2:** Vincular un servicio a `0.0.0.0` le indica al kernel que escuche en todas las interfaces de red actuales y futuras (incluidas las interfaces públicas de Internet). Vincular a `127.0.0.1` restringe los listeners de sockets estrictamente a la interfaz loopback local, haciéndolo inaccesible desde fuera del host. Si una base de datos como Redis (que históricamente carecía de autenticación predeterminada) se expone en `0.0.0.0:6379`, los atacantes externos pueden lograr la ejecución remota de código (RCE) o la exfiltración no autorizada de datos escribiendo claves SSH o tareas cron directamente en la memoria del sistema a través de comandos de Redis.

### Respuestas del Ejercicio 2
* **Respuesta 2.1:** Un `policy drop` por defecto descarta silenciosamente los paquetes que no coinciden sin enviar una respuesta ICMP. Una regla `reject` envía activamente de vuelta un paquete `ICMP Port Unreachable` (o TCP RST) al emisor.
  * *Impacto en reconocimiento:* `drop` hace que los puertos cerrados parezcan no responder o estar filtrados, ralentizando los escáneres de puertos (como `nmap`) porque deben esperar los timeouts de conexión. `reject` le confirma instantáneamente a un escáner que el host está activo y procesando tráfico.
  * *Impacto en recursos:* `drop` ahorra ancho de banda de red de salida durante un ataque DDoS porque el kernel genera cero paquetes de respuesta egress.
* **Respuesta 2.2:** Cuando `conntrack` se llena (`nf_conntrack: table full`), el kernel descarta todos los paquetes entrantes subsiguientes para nuevas conexiones, lo que resulta en una Denegación de Servicio (DoS) completa para el tráfico legítimo. En entornos de alto volumen, los SREs usan la tabla `raw` en Netfilter con el target `NOTRACK` (`nft add rule inet raw prerouting tcp dport 53 counter notrack`) para omitir el seguimiento de estado en servicios sin estado o de muy alto rendimiento.

### Respuestas del Ejercicio 3
* **Respuesta 3.1:** En TLS 1.3, las tickets de sesión se pueden emitir como Session Tickets sin estado cifradas por una clave simétrica STEK (Session Ticket Encryption Key) mantenida por el servidor. Si `ssl_session_tickets` está activado sin rotación automatizada de clave STEK en un pool de balanceadores de carga, un atacante que comprometa la clave STEK estática puede descifrar retroactivamente todas las sesiones TLS capturadas y registradas en el pasado, rompiendo el Perfect Forward Secrecy (PFS). Desactivar las tickets de sesión obliga a los clientes a depender de IDs de sesión con estado o requiere una rotación estricta fuera de banda de las claves STEK.
* **Respuesta 3.2:** `MemoryDenyWriteExecute=true` aplica la política de protección de memoria $W \oplus X$ (Write XOR Execute). Le indica al kernel que no permita mapear páginas de memoria que sean simultáneamente escribibles y ejecutables (`PROT_WRITE | PROT_EXEC`), evitando que los atacantes coloquen shellcode ejecutable en la memoria stack/heap y la ejecuten.
  * *Runtimes afectados:* Los compiladores dinámicos Just-In-Time (JIT) (por ejemplo, el motor V8 de Node.js, la JVM HotSpot de Java, PyPy en Python) generan código máquina dinámicamente en memoria en tiempo de ejecución y lo ejecutan de inmediato. Aplicar `MemoryDenyWriteExecute=true` provoca que estos entornos de ejecución colapsen con señales de error `SIGSEGV` o `EPERM` al realizar la asignación.

### Respuestas del Ejercicio 4
* **Respuesta 4.1:** La flag `ad` (Authenticated Data) indica que un resolver recursivo validador en la cadena superior ha validado la cadena de firmas criptográficas desde el root trust anchor hasta el conjunto de registros de destino. Los stub resolvers (como las aplicaciones locales) no realizan comprobaciones completas de firmas por sí mismos; confían en la flag `ad`. Por lo tanto, el salto de red entre el stub resolver y el proxy validador debe ser seguro (a través de loopback `127.0.0.1` o túneles cifrados IPsec/TLS) para evitar que un adversario en la LAN local falsifique respuestas e inyecte una flag `ad` falsa.
* **Respuesta 4.2:** Los registros `NSEC` estándar devuelven los nombres de dominio existentes exactos que preceden y siguen al nombre de dominio no existente consultado, lo que permite a un atacante iterar a través de la zona y descubrir todos los nombres de registros privados ("Zone Walking"). `NSEC3` reemplaza los nombres de dominio en texto plano con hashes criptográficos iterados y con salt (por ejemplo, `SHA-1(domain + salt)`), lo que evita la enumeración masiva. Sin embargo, los recuentos elevados de iteraciones requieren un procesamiento de CPU significativo en los servidores autoritativos para cada respuesta `NXDOMAIN`, exponiendo la infraestructura DNS autoritativa a ataques de denegación de servicio por agotamiento de CPU.

### Respuestas del Ejercicio 5
* **Respuesta 5.1:** WireGuard impone una asociación estricta 1 a 1 entre una dirección IP permitida y la clave pública de un peer en su tabla Cryptokey Routing. Si se define una dirección IP duplicada en un segundo peer, el kernel sobrescribe silenciosamente la entrada anterior, asociando la IP exclusivamente con el *último* peer analizado en el archivo de configuración. El tráfico saliente hacia esa IP se enrutará solo al último peer, y el tráfico entrante del peer original que utilice esa dirección IP se descartará como no autenticado.
* **Respuesta 5.2:** Tor proporciona anonimato de metadatos y transporte cifrado a través de los nodos Guard y Middle, ocultando con éxito la dirección IP de origen del cliente tanto a los observadores de Internet como al servidor de destino. Sin embargo, debido a que el nodo de salida (Exit Node) de Tor descifra la capa final del cifrado onion, el tráfico HTTP no TLS sale del Exit Node en texto plano. El operador de un Exit Node malicioso puede inspeccionar, interceptar, registrar o modificar la carga útil HTTP no cifrada (por ejemplo, robando contraseñas, cookies o inyectando scripts maliciosos) antes de entregarla al destino. Se requiere TLS de extremo a extremo (HTTPS sobre Tor) para garantizar la confidencialidad e integridad de la carga útil.

</details>