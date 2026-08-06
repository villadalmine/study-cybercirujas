# Guía de estudio para la certificación LPIC-2: Tema 207 / Tema 2.1 — Servidor de nombres de dominio (Ponderación: 8)

## 1. Arquitectura del tema y fuentes de referencia oficiales

El Domain Name System (DNS) es una base de datos distribuida y jerárquica crítica para la ingeniería de plataformas y la confiabilidad de la infraestructura. ISC BIND 9 (`named`) sigue siendo la implementación de referencia para DNS autoritativo y recursivo en sistemas Linux.

```
                                  [ Root Hits (.) ]
                                          |
                                    [ TLD (.com) ]
                                          |
                               [ Authoritative Primary ]
                                   (example.com)
                                   /           \
                 [ Internal View (Split) ]    [ External View (Split) ]
                    (10.0.0.0/8 Clients)         (Public Internet)
```

### Referencias oficiales
- **LPI LPIC-2 Objectives**: [LPI Official LPIC-2 201-450 & 202-450 Detailed Objectives](https://www.lpi.org/our-certifications/lpic-2-overview/)
- **ISC BIND 9 Administrator Reference Manual (ARM)**: [ISC BIND 9 Documentation](https://bind9.readthedocs.io/en/latest/)
- **RFC 1034 / RFC 1035**: [Domain Names - Concepts and Facilities / Implementation and Specification](https://datatracker.ietf.org/doc/html/rfc1035)
- **RFC 2845**: [Secret Key Transaction Authentication for DNS (TSIG)](https://datatracker.ietf.org/doc/html/rfc2845)
- **RFC 4033 / 4034 / 4035**: [DNS Security Extensions (DNSSEC) Resource Records & Protocol Modifications](https://datatracker.ietf.org/doc/html/rfc4033)

---

## 2. Ejercicios prácticos guiados de laboratorio

---

### Bloque de ejercicios 1: Topología Master/Secondary en producción con TSIG y RRL

#### Objetivo
Configurar un servidor DNS primario aislado (`ns1.ops.infra`) y un servidor DNS secundario (`ns2.ops.infra`). Aplicar seguridad utilizando TSIG (`hmac-sha256`) para transferencias de zona (AXFR), deshabilitar la resolución recursiva para consultas externas, aplicar Response Rate Limiting (RRL) y verificar la sintaxis utilizando conjuntos de herramientas nativos de BIND.

#### Paso 1: Generar clave TSIG y configurar listas de control de acceso (ACLs)
Iniciar sesión en `ns1.ops.infra` (IP: `192.168.50.10`). Generar un archivo de clave TSIG HMAC-SHA256 usando `tsig-keygen` y crear un fragmento de configuración dedicado.

```bash
# Generate TSIG key for secondary synchronization
tsig-keygen -a hmac-sha256 transfer-key.ops.infra > /etc/named/tsig-transfer.key
chown root:named /etc/named/tsig-transfer.key
chmod 0640 /etc/named/tsig-transfer.key
cat /etc/named/tsig-transfer.key
```

*Salida esperada:*
```bind
key "transfer-key.ops.infra" {
	algorithm hmac-sha256;
	secret "K8zP9xQvR2mN5bV8cW0L1kJ3hG6fD9sA2zX4cV6bN8m=";
};
```

#### Paso 2: Construir `/etc/named.conf` de producción en el nodo primario
Editar `/etc/named.conf` en `ns1.ops.infra`. Configurar opciones globales de seguridad, limitar las interfaces de consulta, aplicar RRL para mitigar ataques de amplificación y restringir las transferencias de zona exclusivamente a clientes TSIG autenticados.

```bind
include "/etc/named/tsig-transfer.key";

acl "trusted_secondaries" {
    192.168.50.11; // ns2.ops.infra
};

acl "internal_clients" {
    127.0.0.1;
    192.168.50.0/24;
};

options {
    listen-on port 53 { 127.0.0.1; 192.168.50.10; };
    listen-on-v6 port 53 { ::1; };
    directory "/var/named";
    dump-file "/var/named/data/cache_dump.db";
    statistics-file "/var/named/data/named_stats.txt";
    memstatistics-file "/var/named/data/named_mem_stats.txt";
    
    // Security & Recursion Controls
    recursion no;
    allow-query { any; };
    allow-recursion { none; };
    allow-transfer { key "transfer-key.ops.infra"; };
    version "NOT AVAILABLE";

    // Response Rate Limiting (RRL)
    rate-limit {
        responses-per-second 10;
        window 5;
        nxdomains-per-second 5;
        errors-per-second 5;
        ipv4-prefix-length 24;
    };

    dnssec-validation auto;
    managed-keys-directory "/var/named/dynamic";
    pid-file "/run/named/named.pid";
    session-keyfile "/run/named/session.key";
};

zone "ops.infra" IN {
    type primary; // Equivalent to 'master' in legacy BIND syntax
    file "slaves/ops.infra.db"; // Primary zone definition
    file "master/ops.infra.db";
    allow-transfer { key "transfer-key.ops.infra"; };
    notify yes;
    also-notify { 192.168.50.11; };
};
```

#### Paso 3: Definir un archivo de zona directa sintácticamente válido
Crear `/var/named/master/ops.infra.db` en `ns1.ops.infra`.

```bind
$TTL 86400
$ORIGIN ops.infra.
@   IN  SOA ns1.ops.infra. sysadmin.ops.infra. (
            2026080601 ; Serial YYYYMMDDnn
            3600       ; Refresh (1 hour)
            1800       ; Retry (30 minutes)
            1209600    ; Expire (2 weeks)
            86400      ; Minimum / Negative TTL (1 day)
            )

; Name Servers
@       IN  NS      ns1.ops.infra.
@       IN  NS      ns2.ops.infra.

; A Records for Infrastructure
ns1     IN  A       192.168.50.10
ns2     IN  A       192.168.50.11
app1    IN  A       192.168.50.20
app2    IN  A       192.168.50.21
lb01    IN  A       192.168.50.5
```

#### Paso 4: Validar la configuración y la integridad del archivo de zona
Ejecutar las herramientas de validación de BIND antes de iniciar el servicio.

```bash
# Check configuration syntax
named-checkconf /etc/named.conf

# Check zone file syntax and serial consistency
named-checkzone ops.infra /var/named/master/ops.infra.db
```

*Salida esperada:*
```text
zone ops.infra/IN: loaded serial 2026080601
OK
```

#### Paso 5: Configurar el nodo secundario (`ns2.ops.infra` - IP: 192.168.50.11)
Instalar el mismo archivo `tsig-transfer.key` en `ns2.ops.infra` y configurar `/etc/named.conf` para actuar como un servidor secundario que realiza transferencias de zona a través de TSIG.

```bind
include "/etc/named/tsig-transfer.key";

server 192.168.50.10 {
    keys { "transfer-key.ops.infra"; };
};

options {
    listen-on port 53 { 127.0.0.1; 192.168.50.11; };
    directory "/var/named";
    recursion no;
    allow-query { any; };
};

zone "ops.infra" IN {
    type secondary; // Equivalent to 'slave'
    file "slaves/ops.infra.db";
    primaries { 192.168.50.10 key "transfer-key.ops.infra"; };
};
```

#### Paso 6: Probar la transferencia de zona autenticada (AXFR) mediante `dig`
Ejecutar `dig` desde `ns2.ops.infra` para verificar que la transferencia AXFR no autenticada falle, pero la transferencia AXFR autenticada con TSIG sea exitosa.

```bash
# Attempt 1: Unauthenticated transfer (Should be REFUSED)
dig @192.168.50.10 ops.infra AXFR

# Attempt 2: Authenticated transfer using TSIG key
dig @192.168.50.10 ops.infra AXFR -k /etc/named/tsig-transfer.key
```

*Salida esperada (Intento 1):*
```text
;; ->>HEADER<<- opcode: QUERY, status: REFUSED, id: 41209
;; flags: qr ra; QUERY: 1, ANSWER: 0, AUTHORITY: 0, ADDITIONAL: 0
```

*Salida esperada (Intento 2):*
```text
; <<>> DiG 9.16.23-RH <<>> @192.168.50.10 ops.infra AXFR -k /etc/named/tsig-transfer.key
;; global options: +cmd
ops.infra.		86400	IN	SOA	ns1.ops.infra. sysadmin.ops.infra. 2026080601 3600 1800 1209600 86400
ops.infra.		86400	IN	NS	ns1.ops.infra.
ops.infra.		86400	IN	NS	ns2.ops.infra.
app1.ops.infra.		86400	IN	A	192.168.50.20
app2.ops.infra.		86400	IN	A	192.168.50.21
lb01.ops.infra.		86400	IN	A	192.168.50.5
ns1.ops.infra.		86400	IN	A	192.168.50.10
ns2.ops.infra.		86400	IN	A	192.168.50.11
ops.infra.		86400	IN	SOA	ns1.ops.infra. sysadmin.ops.infra. 2026080601 3600 1800 1209600 86400
;; Query time: 2 msec
;; SERVER: 192.168.50.10#53(192.168.50.10)
```

---

#### Preguntas de verificación (Bloque 1)

1. **Pregunta 1.1**: ¿Qué falla de seguridad específica ocurre si se omite `allow-transfer` o se establece en `any;` en un despliegue de BIND en producción?
2. **Pregunta 1.2**: En la sintaxis del registro SOA `2026080601 3600 1800 1209600 86400`, ¿qué sucede si el servidor secundario no logra comunicarse con el servidor primario durante un período que excede los `1209600` segundos?
3. **Pregunta 1.3**: ¿Cómo ayuda el bloque `response-rate-limiting` (RRL) de BIND a mitigar los ataques de amplificación DNS (DDoS) dirigidos a servidores autoritativos?

---

### Bloque de ejercicios 2: Registros de recursos avanzados, vistas Split-Horizon y mapas inversos

#### Objetivo
Implementar una arquitectura DNS Split-Horizon (Split-Brain) utilizando cláusulas `view` de BIND para ofrecer diferentes mapeos de IP según la IP de origen del cliente (Interna vs Externa). Configurar registros SRV, CAA, TXT (SPF/DMARC) y mapeo inverso IPv4 (`in-addr.arpa`).

#### Paso 1: Configurar `named.conf` para la arquitectura Split-Horizon
Editar `/etc/named.conf` en `ns1.ops.infra`. Tenga en cuenta que al usar cláusulas `view` de BIND, **todas las zonas deben estar dentro de una vista**.

```bind
acl "internal-network" {
    10.0.0.0/8;
    192.168.50.0/24;
    127.0.0.1;
};

options {
    directory "/var/named";
    listen-on port 53 { any; };
    recursion no;
};

// View for Internal Network Clients
view "internal" {
    match-clients { "internal-network"; };
    recursion yes;
    allow-recursion { "internal-network"; };

    zone "ops.infra" IN {
        type primary;
        file "master/ops.infra.internal.db";
    };

    zone "50.168.192.in-addr.arpa" IN {
        type primary;
        file "master/192.168.50.rev";
    };
};

// View for External/Public Clients
view "external" {
    match-clients { any; };
    recursion no;

    zone "ops.infra" IN {
        type primary;
        file "master/ops.infra.external.db";
    };
};
```

#### Paso 2: Redactar el archivo de zona interna con registros avanzados (`master/ops.infra.internal.db`)
Crear el archivo de zona interna que contiene registros MX, TXT (SPF/DMARC), SRV y CAA.

```bind
$TTL 86400
$ORIGIN ops.infra.
@   IN  SOA ns1.ops.infra. sysadmin.ops.infra. (
            2026080602 ; Serial
            7200       ; Refresh
            3600       ; Retry
            1209600    ; Expire
            3600 )     ; Negative Cache TTL

@       IN  NS      ns1.ops.infra.
@       IN  MX  10  mail01.ops.infra.

; Host Address Records
ns1     IN  A       192.168.50.10
mail01  IN  A       192.168.50.25
api     IN  A       10.10.100.50

; Service Location Record (SRV): _service._proto.name. TTL Class SRV priority weight port target.
_sip._tcp IN SRV    10 60 5060 sipserver.ops.infra.
sipserver IN A      192.168.50.30

; Certificate Authority Authorization (CAA)
@       IN  CAA     0 issue "letsencrypt.org"
@       IN  CAA     0 iodef "mailto:security@ops.infra"

; TXT Records: SPF and DMARC
@       IN  TXT     "v=spf1 ip4:192.168.50.25 -all"
_dmarc  IN  TXT     "v=DMARC1; p=reject; rua=mailto:dmarc-reports@ops.infra; pct=100"
```

#### Paso 3: Configurar la zona de mapeo inverso (`master/192.168.50.rev`)
Crear registros PTR que coincidan con el espacio de direcciones IPv4 `192.168.50.0/24`.

```bind
$TTL 86400
$ORIGIN 50.168.192.in-addr.arpa.
@   IN  SOA ns1.ops.infra. sysadmin.ops.infra. (
            2026080601 ; Serial
            3600       ; Refresh
            1800       ; Retry
            1209600    ; Expire
            3600 )     ; Minimum TTL

@       IN  NS      ns1.ops.infra.

; PTR Records (Last octet of IP address)
10      IN  PTR     ns1.ops.infra.
11      IN  PTR     ns2.ops.infra.
20      IN  PTR     app1.ops.infra.
25      IN  PTR     mail01.ops.infra.
```

#### Paso 4: Validar y verificar las búsquedas Split-Horizon y de punteros
Probar la resolución desde contextos de IP internos y externos utilizando `dig`.

```bash
# Verify PTR Reverse Lookup
dig @127.0.0.1 -x 192.168.50.25 +short

# Verify SRV Query
dig @127.0.0.1 SRV _sip._tcp.ops.infra. +noall +answer

# Verify CAA Record Query
dig @127.0.0.1 CAA ops.infra. +noall +answer
```

*Salida esperada:*
```text
mail01.ops.infra.
_sip._tcp.ops.infra.	86400	IN	SRV	10 60 5060 sipserver.ops.infra.
ops.infra.		86400	IN	CAA	0 issue "letsencrypt.org"
ops.infra.		86400	IN	CAA	0 iodef "mailto:security@ops.infra"
```

---

#### Preguntas de verificación (Bloque 2)

1. **Pregunta 2.1**: ¿Qué requisito de sintaxis debe observarse estrictamente en `named.conf` al introducir directivas `view` con respecto a las zonas definidas en el ámbito global de nivel superior?
2. **Pregunta 2.2**: Explique la diferencia operativa entre `p=none`, `p=quarantine` y `p=reject` en un registro TXT `_dmarc`.
3. **Pregunta 2.3**: ¿Cuál es el nombre de dominio canónico para la búsqueda inversa de la dirección IPv6 `2001:db8::1`?

---

### Bloque de ejercicios 3: Firma de DNSSEC, gestión de claves y resolución de problemas operativos

#### Objetivo
Implementar DNSSEC en una zona autoritativa utilizando mecanismos manuales y automatizados de BIND. Generar KSK (Key Signing Key) y ZSK (Zone Signing Key), firmar el archivo de zona, publicar registros DS, usar `rndc` para controles en tiempo de ejecución y diagnosticar errores de validación usando `delv`.

#### Paso 1: Generar claves criptográficas KSK y ZSK
Navegar al directorio seguro de claves de BIND y generar claves RSASHA256.

```bash
cd /var/named/keys

# Generate Zone Signing Key (ZSK) - 1280 bits
dnssec-keygen -a RSASHA256 -b 1280 -n ZONE ops.infra

# Generate Key Signing Key (KSK) - 2048 bits with Flag 257
dnssec-keygen -a RSASHA256 -b 2048 -f KSK -n ZONE ops.infra

ls -l Kops.infra.*
```

*Salida esperada:*
```text
-rw-r--r--. 1 root named 1729 Aug 6 10:00 Kops.infra.+008+12345.key
-rw-------. 1 root named 3227 Aug 6 10:00 Kops.infra.+008+12345.private
-rw-r--r--. 1 root named 2380 Aug 6 10:01 Kops.infra.+008+67890.key
-rw-------. 1 root named 4096 Aug 6 10:01 Kops.infra.+008+67890.private
```

#### Paso 2: Incluir claves en el archivo de zona y firmar manualmente mediante `dnssec-signzone`
Añadir las claves públicas (`.key`) a `/var/named/master/ops.infra.db` y ejecutar `dnssec-signzone`.

```bash
# Append key includes to the zone file
echo '$INCLUDE /var/named/keys/Kops.infra.+008+12345.key' >> /var/named/master/ops.infra.db
echo '$INCLUDE /var/named/keys/Kops.infra.+008+67890.key' >> /var/named/master/ops.infra.db

# Sign the zone file (Generates ops.infra.db.signed and dsset-ops.infra.)
dnssec-signzone -A -3 $(head -c 16 /dev/urandom | hexxdump -e '16/1 "%02X"') \
  -N INCREMENT -o ops.infra -k /var/named/keys/Kops.infra.+008+67890.key \
  /var/named/master/ops.infra.db /var/named/keys/Kops.infra.+008+12345.key
```

*Salida esperada:*
```text
Verifying the zone using private keys...
Zone signing complete:
Nodes: 8
Signatures generated: 18
Signatures retained: 0
Signatures dropped: 0
Signature verification failed: 0
Signature verification succeeded: 0
Signatures expired: 0
Signatures not yet valid: 0
Signatures remaining: 18
Authoritative signatures total: 18
Authoritative signatures computed: 18
Signatures set to expire in 30 days.
Signed zone file output: /var/named/master/ops.infra.db.signed
```

#### Paso 3: Actualizar `named.conf` para servir la zona firmada
Modificar el bloque de zona en `/etc/named.conf` para servir la variante de la zona `.signed`.

```bind
zone "ops.infra" IN {
    type primary;
    file "master/ops.infra.db.signed";
    allow-transfer { key "transfer-key.ops.infra"; };
};
```

Recargar BIND mediante `rndc`:

```bash
rndc reload ops.infra
rndc status
```

*Salida esperada:*
```text
version: BIND 9.16.23-RH (Extended Support Version) <id:1018968>
running on ns1.ops.infra: Linux x86_64 5.14.0-70.c8.x86_64 #1 SMP
boot time: Thu, 06 Aug 2026 09:00:00 GMT
last configured: Thu, 06 Aug 2026 10:15:00 GMT
configuration file: /etc/named.conf
cpus found: 4
worker threads: 4
number of zones: 105 (101 automatic)
debug level: 0
xfers running: 0
xfers deferred: 0
soa queries in progress: 0
query logging is OFF
server is idlok
```

#### Paso 4: Validar registros y firmas DNSSEC con `dig` y `delv`
Consultar los registros RRSIG y DNSKEY para verificar la integridad operativa.

```bash
# Query DNSKEY records
dig @127.0.0.1 ops.infra DNSKEY +multiline

# Query A record with DNSSEC validation request (+dnssec)
dig @127.0.0.1 app1.ops.infra A +dnssec

# Deep diagnostic validation using delv (Domain Entity Lookup & Verification)
delv @127.0.0.1 app1.ops.infra A +rtrace
```

*Salida esperada (fragmento de `dig +dnssec`):*
```text
;; QUESTION SECTION:
;app1.ops.infra.			IN	A

;; ANSWER SECTION:
app1.ops.infra.		86400	IN	A	192.168.50.20
app1.ops.infra.		86400	IN	RRSIG	A 8 3 86400 20260905100000 20260806100000 12345 ops.infra. g8F1N...==
```

---

#### Preguntas de verificación (Bloque 3)

1. **Pregunta 3.1**: ¿Cuál es la distinción funcional estructural entre una Zone Signing Key (ZSK) y una Key Signing Key (KSK) en la arquitectura DNSSEC?
2. **Pregunta 3.2**: Al ejecutar `rndc freeze ops.infra`, ¿qué estado operativo se impone a la zona y qué comando se debe emitir después de realizar modificaciones manuales en la zona?
3. **Pregunta 3.3**: Si `delv` reporta `unsigned answer` o `verification failure: trusted key mismatch`, ¿cuáles son las causas raíz principales en la cadena de confianza de DNSSEC?

---

## 3. Clave de respuestas y explicaciones arquitectónicas profundas

<details>
<summary>Haga clic para expandir la clave de respuestas y las explicaciones técnicas detalladas</summary>

### Respuestas del Bloque 1

* **Respuesta 1.1**: Si `allow-transfer` no está restringido (`any;`), cualquier actor malicioso en la red puede ejecutar una consulta `AXFR` (Full Zone Transfer) no solicitada. Esto filtra todo el esquema de la base de datos de su espacio de nombres de dominio (todos los hostnames internos, mapeos de IP, endpoints de servicios y topología de infraestructura), expandiendo drásticamente la superficie de ataque de reconocimiento para exploits dirigidos.

* **Respuesta 1.2**: Si un servidor secundario no puede establecer contacto con el servidor primario durante un período que excede el campo **Expire** del SOA (`1209600` segundos / 14 días), el servidor secundario considera que sus datos de zona en caché están obsoletos e inválidos. **Deja de responder consultas** para esa zona por completo, devolviendo `SERVFAIL` a las peticiones de los clientes para evitar servir registros desactualizados.

* **Respuesta 1.3**: Response Rate Limiting (RRL) rastrea los patrones de consulta de los clientes agrupados por subred (`ipv4-prefix-length 24`). Si un atacante suplanta la dirección IP de una víctima objetivo e inunda a un servidor BIND autoritativo con solicitudes de registros grandes (por ejemplo, consultas `ANY` o registros DNSSEC firmados), RRL descarta o trunca las respuestas que excedan `responses-per-second`. Esto evita que el servidor autoritativo sea utilizado como un amplificador en un ataque de denegación de servicio distribuido (DDoS).

---

### Respuestas del Bloque 2

* **Respuesta 2.1**: Una vez que se introducen las directivas `view` de BIND en `named.conf`, **cada una de las definiciones de zona debe residir dentro de un bloque `view`**. Definir sentencias `zone` de nivel superior fuera de un bloque `view` provoca un error fatal de análisis durante `named-checkconf` (`when views are used, all zones must be in views`).

* **Respuesta 2.2**: La política DMARC (`p=`) controla cómo los Mail Transfer Agents (MTAs) receptores procesan los mensajes que fallan en la autenticación SPF y DKIM:
  * `p=none`: Modo de monitoreo; los mensajes se entregan normalmente, pero los informes de falla se envían al URI `rua`.
  * `p=quarantine`: Los mensajes que fallan las comprobaciones se marcan como spam/sospechosos y se desvían a la carpeta de correo no deseado del destinatario.
  * `p=reject`: Los mensajes que fallan las comprobaciones se rechazan de plano en la fase de transacción del sobre SMTP (hard bounce).

* **Respuesta 2.3**: El nombre de dominio canónico de búsqueda inversa para `2001:db8::1` se expande a un formato hexadecimal completo de 32 nibbles separados por puntos bajo `ip6.arpa`:
  `1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa.`

---

### Respuestas del Bloque 3

* **Respuesta 3.1**: 
  * **Zone Signing Key (ZSK)**: Se utiliza para firmar todos los Resource Record Sets (RRsets) estándar en la zona (por ejemplo, A, AAAA, MX, TXT). Utiliza longitudes de clave más cortas (por ejemplo, RSA 1280-bit) para un rendimiento más rápido y se rota con frecuencia (por ejemplo, cada 30–90 días).
  * **Key Signing Key (KSK)**: Se utiliza exclusivamente para firmar el RRset `DNSKEY` que contiene la ZSK. Utiliza longitudes de clave más largas (por ejemplo, RSA 2048-bit) para mayor seguridad. El hash de su clave pública se publica en la zona padre como un registro Delegation Signer (**DS**) para establecer la cadena de confianza.

* **Respuesta 3.2**: `rndc freeze ops.infra` pausa las actualizaciones dinámicas de la zona (IXFR/DDNS), vuelca los archivos de registro (`.jnl`) pendientes directamente en el archivo de zona de texto plano y evita que BIND modifique el archivo en disco. Esto permite una edición de texto manual segura. Después de completar las modificaciones y actualizar el serial del SOA, debe emitir `rndc thaw ops.infra` para recargar la zona y volver a habilitar las actualizaciones dinámicas.

* **Respuesta 3.3**: Los errores significan un fallo en el establecimiento o verificación de la cadena de confianza de DNSSEC:
  1. La zona TLD padre mantiene un digest del **registro DS** que no coincide con el hash del **KSK** activo de la zona local.
  2. Las firmas criptográficas de la zona (**RRSIG**) han expirado debido a relojes del sistema no sincronizados (desviación de NTP) o por no volver a firmar la zona antes del vencimiento de la firma.
  3. El resolver local carece de la clave Root Anchor actualizada (`managed-keys`).

</details>