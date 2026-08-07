# Guía de Estudio LPI-702: Tema 714.4 – Configurar DNS del Lado del Cliente

**Examen:** LPI BSD Specialist (Exam 702-100, Version 1.0)  
**Tema:** 714.4 Configurar DNS del Lado del Cliente  
**Ponderación del Tema:** 3.33  

---

## 1. Análisis Arquitectónico Profundo y Mecánica del Sistema

### 1.1 La Arquitectura del Resolver de BSD y el Ciclo de Vida de Ejecución
En sistemas BSD (FreeBSD, OpenBSD, NetBSD), la resolución de nombres de dominio (DNS) del lado del cliente es gestionada por funciones de la biblioteca C (`libc`)—principalmente POSIX moderna `getaddrinfo(3)` y la heredada `gethostbyname(3)`.

Cuando una aplicación solicita la resolución de un endpoint de red (por ejemplo, llamando a `curl https://api.internal.net`), el SO sigue una cadena de procesamiento estricta:

```
[ Application ] 
       │ (calls getaddrinfo)
       ▼
[ C Library Resolver (libc) ]
       │
       ├─► Read /etc/nsswitch.conf (FreeBSD/NetBSD)
       │     └─► Host lookup source order: [ files ──► dns ──► mdns ]
       │
       ├─► [ Source 1: "files" ] ──► Parse /etc/hosts
       │     └─► Match found? Return IP to Application.
       │
       └─► [ Source 2: "dns" ] ──► Read /etc/resolv.conf
             ├─► Check domain / search directives (Apply ndots evaluation)
             ├─► Construct UDP/TCP DNS Query Packet (EDNS0, Opt Pseudo-RR)
             └─► Send to configured nameserver (IP:53 or 127.0.0.1)
```

1. **System Name Service Switch (`/etc/nsswitch.conf`):**  
   En FreeBSD y NetBSD, el daemon y la biblioteca de Name Service Switch (NSS) despachan las solicitudes de búsqueda según la entrada `hosts`. OpenBSD confía directamente en `/etc/hosts` y `/etc/resolv.conf`, manteniendo un bucle de resolver ligero en `libc`.
2. **Tabla Estática Local (`/etc/hosts`):**  
   Evalúa los mapeos de IP a hostname línea por línea. Si se encuentra una cadena de host coincidente, la resolución finaliza inmediatamente sin enviar paquetes de red.
3. **Cliente del Sistema de Nombres de Dominio (`/etc/resolv.conf`):**  
   Define las direcciones IP de los nameservers recursivos, dominios de búsqueda por defecto, reglas de anexo de dominios (`ndots`) y parámetros de timeout/reintentos del socket.

---

### 1.2 Análisis Profundo de `/etc/resolv.conf`: Sintaxis y Directivas

El archivo `/etc/resolv.conf` configura las rutinas del resolver de la biblioteca C.

| Directiva | Descripción | Valor por Defecto / Recomendación para Producción |
| :--- | :--- | :--- |
| `nameserver <IP>` | Dirección IPv4 o IPv6 del resolver DNS recursivo. Se pueden listar hasta 3 directivas nameserver. Se comprueban secuencialmente a menos que se configure `rotate`. | Máximo 3 servidores. Usar `127.0.0.1` cuando se ejecuta un stub de almacenamiento en caché local como Unbound. |
| `search <domain ...>` | Lista de búsqueda para la resolución de hostnames. Hasta 6 dominios en total (máximo 256 caracteres en total). | Listar explícitamente los sufijos de dominios internos (ej. `prod.internal corp.local`). |
| `domain <domain>` | Nombre del dominio local. A los hostnames cortos se les anexa esta cadena. (Mutuamente excluyente con `search`; prevalece el último especificado). | Preferir `search` sobre `domain` en entornos empresariales de múltiples niveles. |
| `options ndots:n` | Umbral para el número de puntos en el nombre de una consulta antes de realizar una búsqueda *absoluta* inicial. Si los puntos $\ge n$, el nombre se consulta tal cual primero. Si los puntos $< n$, las rutas de búsqueda se anexan primero. | El valor por defecto es `1`. Configurar en `1` o `2` para reducir la amplificación de consultas DNS. |
| `options timeout:n` | Tiempo (en segundos) que el resolver espera una respuesta de un nameserver remoto antes de reintentar. | Por defecto `5`s. En producción, configurar en `1` o `2` segundos para evitar que los hilos de la aplicación se bloqueen. |
| `options attempts:n` | Número de veces que el resolver envía una consulta a sus nameservers antes de desistir. | Por defecto `2`. Configurar en `2` para un failover de baja latencia entre primario/secundario. |
| `options rotate` | Habilita la selección round-robin entre los nameservers configurados, balanceando la carga de consultas salientes entre todos los resolvers listados. | Habilitar en nodos de trabajo stateless de alto rendimiento. |
| `options edns0` | Habilita los Mecanismos de Extensión para DNS (RFC 6891), permitiendo tamaños de payload UDP mayores a 512 bytes (típicamente 1232 o 4096 bytes). | Obligatorio para redes modernas convalidadas por DNSSEC. |

---

### 1.3 Mecánica del Orden de Resolución y el Comportamiento de `ndots`

Comprender `ndots` es crítico para la resolución de problemas de latencia en microservicios y búsquedas de dominios externos.

Supongamos que `/etc/resolv.conf` tiene:
```text
search prod.internal corp.local
options ndots:2
```

- **Consulta 1:** La aplicación resuelve `db01` (Número de puntos = `0`).  
  - Como $0 < \text{ndots (2)}$, el resolver anexa las rutas de búsqueda **primero**:
    1. `db01.prod.internal`
    2. `db01.corp.local`
    3. `db01.` (reintento a la raíz FQDN)
- **Consulta 2:** La aplicación resuelve `api.service.io` (Número de puntos = `2`).  
  - Como $2 \ge \text{ndots (2)}$, el resolver realiza una consulta absoluta **primero**:
    1. `api.service.io.`
    2. (Si se retorna NXDOMAIN) `api.service.io.prod.internal`
    3. (Si se retorna NXDOMAIN) `api.service.io.corp.local`

---

### 1.4 Tipos de Registros Principales y Herramientas de Diagnóstico de Consultas

Los entornos BSD utilizan dos herramientas principales de búsqueda DNS en el sistema base y ports:
- `drill`: La herramienta de búsqueda por defecto de BSD provista por NLnet Labs (incluida en el sistema base de FreeBSD).
- `dig`: La herramienta clásica de BIND (disponible a través del paquete/port `bind-tools`).

#### Registros de Recursos (RRs) Esenciales:
- **A**: Registro de dirección IPv4.
- **AAAA**: Registro de dirección IPv6.
- **PTR**: Registro Puntero (Pointer) para búsquedas DNS inversas (mapea la dirección IP al hostname canónico vía `.in-addr.arpa` o `.ip6.arpa`).
- **MX**: Registro de Intercambiador de Correo (Mail Exchanger, incluye enteros de prioridad).
- **TXT**: Registros de Texto (utilizados para SPF, DKIM, DMARC y verificación de dominio).
- **CNAME**: Registro de Nombre Canónico (Canonical Name, alias que apunta a otro nombre de dominio).
- **NS**: Registros de designación autoritativa de Name Server.
- **SOA**: Registro de Inicio de Autoridad (Start of Authority, define administración de zona, números de serie, TTLs).

---

## 2. Manifiestos de Producción y Configuraciones Sintácticamente Válidas

### 2.1 Archivo `/etc/resolv.conf` Empresarial de Alta Disponibilidad

```text
# /etc/resolv.conf - Enterprise Production Client Configuration
# Managed by Infrastructure Automation - DO NOT EDIT MANUALLY

search infra.prod.internal corp.global
nameserver 10.0.10.53
nameserver 10.0.20.53
nameserver 1.1.1.1
options ndots:1 timeout:1 attempts:2 rotate edns0
```

### 2.2 Configuración del Name Service Switch en FreeBSD / NetBSD (`/etc/nsswitch.conf`)

```text
# /etc/nsswitch.conf - Name Service Switch configuration
# See nsswitch.conf(5) for syntax details.

group:          files
passwd:         files
hosts:          files dns
networks:       files dns
protocols:      files
services:       files
ethers:         files
rpc:            files
```

### 2.3 Configuración de Inserción Local en `/etc/hosts` para Producción

```text
# /etc/hosts - Static Host Lookup Table
# Syntax: <IP Address> <Official Host Name> [Aliases...]

127.0.0.1       localhost localhost.my.domain
::1             localhost localhost.my.domain

# Local Static Overrides for Emergency Out-of-Band Management
10.0.0.1        gateway.prod.internal router
10.0.10.12      db-primary.prod.internal db01
10.0.10.13      db-secondary.prod.internal db02
```

### 2.4 Resolver Stub de Almacenamiento en Caché Local Unbound (`/etc/unbound/unbound.conf`)

Para aplicaciones de ultra baja latencia, ejecutar un resolver local con caché en `127.0.0.1` desacopla los hilos de la aplicación de los retrasos DNS de la red externa.

```unicast
# /etc/unbound/unbound.conf - Local Caching Stub Resolver
server:
    verbosity: 1
    interface: 127.0.0.1
    port: 53
    do-ip4: yes
    do-ip6: no
    do-udp: yes
    do-tcp: yes

    # Access Control: strict loopback enforcement
    access-control: 127.0.0.0/8 allow
    access-control: ::1 allow

    # Security & Performance Hardening
    hide-identity: yes
    hide-version: yes
    harden-glue: yes
    harden-dnssec-stripped: yes
    prefetch: yes
    cache-min-ttl: 60
    cache-max-ttl: 86400

forward-zone:
    name: "."
    forward-addr: 10.0.10.53
    forward-addr: 10.0.20.53
```

---

## 3. Ejercicios Prácticos Guiados de Producción

### Ejercicio 1: Orden del Resolver del Sistema y Anulaciones Locales de Hosts

En este ejercicio, verificarás y alterarás el comportamiento de reserva para la resolución de hosts usando `/etc/nsswitch.conf` y `/etc/hosts`.

#### Paso 1.1: Verificar el orden actual de resolución en `/etc/nsswitch.conf`
Inspecciona la directiva `hosts:` en `/etc/nsswitch.conf` (FreeBSD/NetBSD):

```bash
grep -E "^hosts:" /etc/nsswitch.conf
```

**Salida Esperada:**
```text
hosts: files dns
```

#### Paso 1.2: Agregar un mapeo estático de host a `/etc/hosts`
Agrega una entrada mapeando `test-internal.local` a `127.0.0.99`.

```bash
echo "127.0.0.99  test-internal.local" | sudo tee -a /etc/hosts
```

#### Paso 1.3: Ejecutar la búsqueda utilizando el resolver del sistema
Consulta el host usando `host` o `getent`:

```bash
host test-internal.local
```

**Salida Esperada:**
```text
test-internal.local has address 127.0.0.99
```

#### Paso 1.4: Inspeccionar el comportamiento al invertir el orden de resolución
Edita temporalmente `/etc/nsswitch.conf` para que `dns` preceda a `files`:

```bash
sudo sed -i '' 's/^hosts:.*/hosts: dns files/' /etc/nsswitch.conf
```

Intenta resolver un registro externo inexistente frente a la entrada del host local:
```bash
host test-internal.local
```

Observa que debido a que `dns` se comprueba primero, el sistema consulta al nameserver externo. Si el servidor DNS ascendente no conoce `test-internal.local`, devuelve `NXDOMAIN` o falla antes de leer `/etc/hosts`, según los flags del backend de libc. Restaura el orden original:

```bash
sudo sed -i '' 's/^hosts:.*/hosts: files dns/' /etc/nsswitch.conf
```

---

#### Preguntas de Comprensión del Ejercicio 1

1. Si `/etc/nsswitch.conf` contiene `hosts: files dns`, ¿qué sucede cuando una aplicación llama a `getaddrinfo("db01.local")` y `db01.local` está presente en `/etc/hosts`? ¿Se enviará un paquete por el puerto UDP 53 a la red?
2. En OpenBSD, `/etc/nsswitch.conf` no controla la resolución de hosts. ¿Qué archivo gestiona la resolución estática de IP a hostname antes de consultar al DNS externo?

---

### Ejercicio 2: Ajuste del Resolver (`ndots`, `timeout`, `attempts`) y Rastreo de Red

En este ejercicio, configurarás opciones de resolución DNS de fallo rápido e inspeccionarás la amplificación de consultas causada por `ndots`.

#### Paso 2.1: Configurar timeouts agresivos en `/etc/resolv.conf`
Actualiza `/etc/resolv.conf` para configurar parámetros de failover a escala de microsegundos:

```bash
cat << 'EOF' | sudo tee /etc/resolv.conf
search internal.domain corp.domain
nameserver 1.1.1.1
nameserver 8.8.8.8
options ndots:2 timeout:1 attempts:1
EOF
```

#### Paso 2.2: Probar la búsqueda DNS con rastreo de paquetes
Abre una segunda terminal o ejecuta `tcpdump` en segundo plano para observar los paquetes UDP DNS salientes en el puerto 53:

```bash
sudo tcpdump -n -i any udp port 53 &
TCPDUMP_PID=$!
sleep 1
```

#### Paso 2.3: Realizar una búsqueda de dominio con un solo punto
Consulta `app.service` (contiene 1 punto):

```bash
host app.service
```

**Salida Esperada de `tcpdump`:**
```text
IP 192.168.1.50.41203 > 1.1.1.1.53: 4102+ A? app.service.internal.domain. (46)
IP 192.168.1.50.41204 > 1.1.1.1.53: 4103+ A? app.service.corp.domain. (42)
IP 192.168.1.50.41205 > 1.1.1.1.53: 4104+ A? app.service. (29)
```

Observa que debido a que se configuró `ndots:2` y `app.service` solo tiene **1 punto** ($1 < 2$), el resolver intentó `app.service.internal.domain.` primero, seguido de `app.service.corp.domain.` y finalmente `app.service.`.

#### Paso 2.4: Limpiar el proceso tcpdump
```bash
sudo kill $TCPDUMP_PID
```

---

#### Preguntas de Comprensión del Ejercicio 2

1. Un Ingeniero DevOps se queja de que al consultar `api.stripe.com` se generan solicitudes innecesarias al dominio de búsqueda (`api.stripe.com.corp.internal`) antes de consultar al dominio público. ¿Qué directiva y valor en `resolv.conf` corregirá este comportamiento inmediatamente?
2. Si se especifica `options timeout:2 attempts:2` en `/etc/resolv.conf` con 3 nameservers listados, ¿cuál es el tiempo máximo teórico que esperará un hilo de la aplicación antes de devolver un error total de timeout en la resolución DNS?

---

### Ejercicio 3: Diagnósticos Avanzados de Consultas DNS e Inspección de Registros con `drill`

En este ejercicio, utilizarás `drill` (la herramienta estándar de diagnóstico DNS en BSD) para realizar consultas dirigidas para registros A, AAAA, MX, TXT y PTR inverso, e inspeccionarás los flags EDNS0 y DNSSEC.

#### Paso 3.1: Consultar registros IPv4 (A) e IPv6 (AAAA) explícitamente
Consulta la dirección IPv4 para `freebsd.org` usando `drill`:

```bash
drill A freebsd.org
```

**Salida Esperada:**
```text
;; ->>HEADER<<- opcode: QUERY, rcode: NOERROR, id: 34912
;; flags: qr rd ra ; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 0

;; QUESTION SECTION:
;; freebsd.org.	IN	A

;; ANSWER SECTION:
freebsd.org.	900	IN	A	96.47.72.84

;; Query time: 24 msec
;; SERVER: 1.1.1.1#53(1.1.1.1)
;; WHEN: Thu Aug  6 20:56:13 2026
;; MSG SIZE rcvd: 45
```

Ahora consulta el registro IPv6 (AAAA):
```bash
drill AAAA freebsd.org
```

#### Paso 3.2: Inspeccionar registros MX (Mail Exchanger) y TXT
Obtén los servidores de Intercambio de Correo para `freebsd.org`:

```bash
drill MX freebsd.org
```

**Salida Esperada:**
```text
;; ANSWER SECTION:
freebsd.org.	3600	IN	MX	10 mx1.freebsd.org.
```

Obtén registros TXT (frecuentemente contienen reglas de políticas SPF):
```bash
drill TXT freebsd.org
```

#### Paso 3.3: Realizar Búsquedas Inversas PTR de DNS
Convierte una dirección IPv4 a su formato de búsqueda DNS inversa (`in-addr.arpa`) usando `drill -x`:

```bash
drill -x 96.47.72.84
```

**Salida Esperada:**
```text
;; QUESTION SECTION:
;; 84.72.47.96.in-addr.arpa.	IN	PTR

;; ANSWER SECTION:
84.72.47.96.in-addr.arpa.	3600	IN	PTR	wfe0.bsdgroup.tokyo.
```

#### Paso 3.4: Validar los flags de autenticación EDNS0 y DNSSEC
Consulta un dominio firmado con DNSSEC solicitando el flag de Datos Autenticados (`ad`) y parámetros de búfer EDNS0:

```bash
drill -D -d freebsd.org @1.1.1.1
```

Observa el flag `ad` en la respuesta del encabezado, confirmando que la validación criptográfica DNSSEC tuvo éxito en el resolver recursivo.

---

#### Preguntas de Comprensión del Ejercicio 3

1. ¿Qué flag de línea de comandos se pasa a `drill` (o `dig`) para realizar una búsqueda DNS inversa para una dirección IPv4 `192.0.2.53` sin construir manualmente la cadena `53.2.0.192.in-addr.arpa`?
2. ¿Qué estado de encabezado de respuesta (`rcode`) devuelto por `drill` indica que el nombre de dominio consultado no existe en el servidor autoritativo?

---

### Ejercicio 4: Despliegue de un Resolver Stub de Almacenamiento en Caché Local con Unbound

En este ejercicio, habilitarás y configurarás el resolver `unbound` del sistema base en BSD, configurarás almacenamiento en caché en loopback y apuntarás `/etc/resolv.conf` a `127.0.0.1`.

#### Paso 4.1: Habilitar Unbound en `/etc/rc.conf` de FreeBSD
Habilita el servicio Unbound para que se inicie automáticamente en el arranque del sistema:

```bash
sudo sysrc unbound_enable="YES"
```

**Salida Esperada:**
```text
unbound_enable: NO -> YES
```

#### Paso 4.2: Generar la clave raíz inicial de Unbound para DNSSEC
Ancla la validación DNSSEC usando `unbound-anchor`:

```bash
sudo unbound-anchor -a "/var/unbound/root.key" || true
```

#### Paso 4.3: Escribir la configuración local de loopback
Despliega el archivo de configuración de almacenamiento en caché local:

```bash
cat << 'EOF' | sudo tee /etc/unbound/unbound.conf
server:
    verbosity: 1
    interface: 127.0.0.1
    port: 53
    access-control: 127.0.0.0/8 allow
    hide-identity: yes
    hide-version: yes

forward-zone:
    name: "."
    forward-addr: 1.1.1.1
    forward-addr: 8.8.8.8
EOF
```

#### Paso 4.4: Iniciar el daemon Unbound y verificar el socket en escucha
Inicia el servicio:

```bash
sudo service unbound start
```

Verifica que Unbound esté activamente enlazado al puerto TCP/UDP 53 en `127.0.0.1` usando `sockstat` o `netstat`:

```bash
sockstat -4 -l -p 53
```

**Salida Esperada:**
```text
USER     COMMAND    PID   FD PROTO LOCAL ADDRESS         FOREIGN ADDRESS     
unbound  unbound    4812  3  udp4  127.0.0.1:53          *:*
unbound  unbound    4812  4  tcp4  127.0.0.1:53          *:*
```

#### Paso 4.5: Actualizar `/etc/resolv.conf` para usar loopback
Reconfigura `/etc/resolv.conf` para dirigir todas las búsquedas de nombres del sistema a la caché local de Unbound:

```bash
cat << 'EOF' | sudo tee /etc/resolv.conf
# Local Unbound Stub Resolver
nameserver 127.0.0.1
options edns0
EOF
```

#### Paso 4.6: Verificar la resolución local y el rendimiento del almacenamiento en caché
Ejecuta una búsqueda en frío (cold lookup):

```bash
drill freebsd.org @127.0.0.1 | grep "Query time"
```
*Tiempo de Consulta en Frío Esperado:* `~25-50 msec`

Ejecuta una búsqueda en caliente (warm/cached lookup):

```bash
drill freebsd.org @127.0.0.1 | grep "Query time"
```
*Tiempo de Consulta en Caliente Esperado:* `0 msec`

---

#### Preguntas de Comprensión del Ejercicio 4

1. ¿Por qué configurar `nameserver 127.0.0.1` en `/etc/resolv.conf` junto con un servicio Unbound local es superior para nodos de aplicación SRE de alto rendimiento en comparación con consultar servidores DNS remotos directamente sobre UDP?
2. ¿Qué herramienta de línea de comandos se puede utilizar para monitorear aciertos/fallos en caché y estadísticas de rendimiento en vivo de un daemon Unbound en ejecución?

---

## 4. Referencias Oficiales y Lecturas Adicionales

- **Resumen de la Certificación LPI BSD Specialist:**  
  [https://www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)
- **Páginas de Manual de FreeBSD - `resolv.conf(5)`:**  
  [https://man.freebsd.org/cgi/man.cgi?query=resolv.conf](https://man.freebsd.org/cgi/man.cgi?query=resolv.conf)
- **Páginas de Manual de FreeBSD - `nsswitch.conf(5)`:**  
  [https://man.freebsd.org/cgi/man.cgi?query=nsswitch.conf](https://man.freebsd.org/cgi/man.cgi?query=nsswitch.conf)
- **Páginas de Manual de OpenBSD - `resolv.conf(5)`:**  
  [https://man.openbsd.org/resolv.conf.5](https://man.openbsd.org/resolv.conf.5)
- **Documentación de Unbound de NLnet Labs:**  
  [https://nlnetlabs.nl/documentation/unbound/](https://nlnetlabs.nl/documentation/unbound/)

---

<details>
<summary><strong>Clave de Respuestas de Comprensión de los Ejercicios</strong></summary>

### Respuestas del Ejercicio 1
1. **Respuesta:** La llamada devuelve `127.0.0.99` inmediatamente desde `/etc/hosts`. No se envía ningún paquete DNS por el puerto UDP 53 a través de la red porque `files` está listado primero en `/etc/nsswitch.conf`, satisfaciendo la búsqueda localmente antes de llegar al backend `dns`.
2. **Respuesta:** `/etc/hosts` gestiona las resoluciones estáticas de hostname en OpenBSD antes de las llamadas a DNS externos.

---

### Respuestas del Ejercicio 2
1. **Respuesta:** Configurar `options ndots:1` (o asegurarse de que `ndots` sea $\le 2$, coincidiendo con la cantidad de puntos de `api.stripe.com` que tiene 2 puntos). Si se configura `ndots:1`, `api.stripe.com` contiene 2 puntos ($2 \ge 1$), forzando al resolver a emitir una consulta FQDN absoluta primero sin probar los sufijos de la ruta de búsqueda.
2. **Respuesta:** **12 segundos.**  
   *Cálculo:* `timeout` (2s) $\times$ `attempts` (2) = 4 segundos por nameserver. A través de 3 nameservers ($4\text{s} \times 3$), el tiempo total transcurrido antes de agotar el timeout es de $12$ segundos.

---

### Respuestas del Ejercicio 3
1. **Respuesta:** `drill -x <DIRECCIÓN_IP>` (ej. `drill -x 192.0.2.53`).
2. **Respuesta:** `NXDOMAIN` (Dominio No Existente, `rcode: NXDOMAIN`).

---

### Respuestas del Ejercicio 4
1. **Respuesta:** Un resolver local con almacenamiento en caché guarda las respuestas en memoria, reduciendo los tiempos promedio de respuesta de las consultas de decenas de milisegundos a menos de un milisegundo ($0\text{ms}$). También elimina el bloqueo de hilos bajo cargas pesadas de consultas salientes, aisla los fallos de la red DNS externa y habilita la validación DNSSEC local.
2. **Respuesta:** `unbound-control stats` (o `unbound-control stats_noreset`).

</details>