# LPIC-3 303 — Topic 331.4: DNS and Cryptography

## Guided Exercises

> **Scope.** DNSSEC on BIND 9.18+ (authoritative and validating), key material and rollovers, NSEC/NSEC3, TSIG, DANE/TLSA, SSHFP, DoT/DoH, and the diagnostic toolchain (`dig`, `delv`, `dnssec-verify`, `rndc`).
>
> **Format.** Each block is a numbered sequence you actually run, followed by verification questions. All answers are in the collapsible section at the end. Do not read it before finishing a block.
>
> **Honesty note on outputs.** Every output below is abridged and comes from a real run of this lab; your key tags, hashes, signatures, serials and timestamps **will differ**. Compare structure, not literal values.

---

## Lab prerequisites

A single Linux host, root access, no exposure to the public Internet needed.

| Component | Debian/Ubuntu package | RHEL/Fedora package |
|---|---|---|
| `named`, `rndc`, `dnssec-*`, `named-checkzone` | `bind9`, `bind9-utils` | `bind`, `bind-utils` |
| `dig`, `delv`, `nslookup` | `bind9-dnsutils` | `bind-utils` |
| `kdig` (DoT/DoH client) | `knot-dnsutils` | `knot-utils` |
| `openssl` | `openssl` | `openssl` |
| `ldns-dane` (optional) | `ldnsutils` | `ldns-utils` |

Two loopback addresses are used so both `named` instances can own port 53 without colliding with `systemd-resolved` (which binds only `127.0.0.53`). The whole `127.0.0.0/8` range is local on Linux — no `ip addr add` required.

| Role | Address | Zones |
|---|---|---|
| Authoritative | `127.0.0.10` | `test.` (parent), `example.test.` (child) |
| Validating resolver | `127.0.0.20` | none — recursive, forwards `test.` |

`.test` is reserved for exactly this purpose by **RFC 6761 §6.2**, so nothing here can ever collide with a real delegation.

**MAC caveat, read before you file a bug against yourself:** on Debian/Ubuntu the AppArmor profile `usr.sbin.named` permits `/var/lib/bind/** rw` — that is why the whole lab lives there. On RHEL/Fedora, SELinux requires the files to carry `named_zone_t`; label them with `semanage fcontext -a -t named_zone_t "/var/lib/bind/lab(/.*)?" && restorecon -Rv /var/lib/bind/lab`. A "permission denied" from `named` that `ls -l` says is impossible is almost always this.

---

## Exercise 1 — Build the unsigned baseline

You cannot debug a signed zone if you never saw it work unsigned.

1. Create the tree and fix ownership:

```bash
sudo mkdir -p /var/lib/bind/lab/{auth/keys,resolver}
sudo chown -R bind:bind /var/lib/bind/lab      # named:named on RHEL/Fedora
cd /var/lib/bind/lab
```

2. Write the child zone `/var/lib/bind/lab/auth/example.test.db`:

```dns
$TTL 300
@       IN SOA  ns1.example.test. hostmaster.example.test. (
                        2026082001 ; serial
                        3600       ; refresh
                        900        ; retry
                        604800     ; expire
                        300 )      ; negative TTL (RFC 2308)
@       IN NS   ns1.example.test.
@       IN MX   10 mail.example.test.
ns1     IN A    127.0.0.10
www     IN A    127.0.0.10
mail    IN A    127.0.0.10
```

3. Write the parent zone `/var/lib/bind/lab/auth/test.db`. It contains the delegation and, later, the DS:

```dns
$TTL 300
@       IN SOA  ns1.test. hostmaster.test. (
                        2026082001 3600 900 604800 300 )
@       IN NS   ns1.test.
ns1     IN A    127.0.0.10

; --- delegation of the child zone ---
example         IN NS   ns1.example.test.
ns1.example     IN A    127.0.0.10          ; glue: in-bailiwick NS needs it
```

4. Generate a TSIG key for the control channel — `rndc` has *always* been TSIG-authenticated, which is your first encounter with the mechanism:

```bash
sudo -u bind tsig-keygen -a hmac-sha256 rndc-lab | sudo tee /var/lib/bind/lab/rndc-lab.key
sudo chmod 640 /var/lib/bind/lab/rndc-lab.key
```

```text
key "rndc-lab" {
	algorithm hmac-sha256;
	secret "yz1Zc0Yy3o2rGqk8oQK0uJ1oQ0m8k8N0y9m0eS0nQ8k=";
};
```

5. Write `/var/lib/bind/lab/auth/named.conf`:

```conf
include "/var/lib/bind/lab/rndc-lab.key";

controls {
    inet 127.0.0.10 port 953 allow { 127.0.0.1; } keys { "rndc-lab"; };
};

options {
    directory       "/var/lib/bind/lab/auth";
    pid-file        "auth.pid";
    listen-on       { 127.0.0.10; };
    listen-on-v6    { none; };
    recursion       no;
    allow-query     { any; };
    allow-transfer  { none; };
    dnssec-validation no;        // an authoritative server validates nothing
    minimal-responses no;        // lab only: show full AUTHORITY/ADDITIONAL
};

logging {
    channel stderrlog { stderr; severity debug 3; print-category yes; };
    category dnssec  { stderrlog; };
    category general { stderrlog; };
};

zone "test." {
    type primary;
    file "test.db";
};

zone "example.test." {
    type primary;
    file "example.test.db";
};
```

6. Syntax-check both the configuration and the zones before ever starting the daemon:

```bash
sudo named-checkconf -z /var/lib/bind/lab/auth/named.conf
```

```text
zone test/IN: loaded serial 2026082001
zone example.test/IN: loaded serial 2026082001
```

7. Start it in the foreground so you can read the log live (use a second terminal or a `tmux` pane):

```bash
sudo named -c /var/lib/bind/lab/auth/named.conf -u bind -g
```

8. Query it:

```bash
dig @127.0.0.10 www.example.test A +noall +answer
dig @127.0.0.10 example.test SOA +dnssec +norec
```

```text
www.example.test.	300	IN	A	127.0.0.10

;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 18452
;; flags: qr aa; QUERY: 1, ANSWER: 1, AUTHORITY: 1, ADDITIONAL: 2
;; OPT PSEUDOSECTION:
; EDNS: version: 0, flags: do; udp: 1232
;; ANSWER SECTION:
example.test.		300	IN	SOA	ns1.example.test. hostmaster.example.test. 2026082001 3600 900 604800 300
```

**Questions — Block 1**

1. `dig +dnssec` was sent, the `do` flag appears in the OPT pseudosection, yet no `RRSIG` came back and there is no `ad` flag. Which of those two facts is expected here and which would be a bug in a signed deployment?
2. The `aa` flag is set but `ra` is absent. What does each tell you about the server you just queried, and why is `recursion no` mandatory on an authoritative server exposed to the Internet?
3. The last SOA field is `300`. In an unsigned zone it governs negative caching. What *additional* job does it acquire the moment the zone is signed?
4. Why does `ns1.example` need an A record inside `test.db` when the same name already exists in `example.test.db`?
5. `dnssec-validation no` is set on the authoritative instance. Is that a security regression? Justify in terms of what an authoritative server is asked to do.

---

## Exercise 2 — Key material: KSK, ZSK, key tags, DS

1. Generate a KSK and a ZSK for the child zone. ECDSA P-256 (algorithm 13, RFC 6605) is the current default choice:

```bash
cd /var/lib/bind/lab/auth
sudo -u bind dnssec-keygen -a ECDSAP256SHA256 -f KSK -K keys example.test
sudo -u bind dnssec-keygen -a ECDSAP256SHA256        -K keys example.test
```

```text
Kexample.test.+013+21237
Kexample.test.+013+34505
```

2. Inspect the naming convention and the permissions:

```bash
ls -l keys/
```

```text
-rw-r--r-- 1 bind bind  427 Aug 20 11:40 Kexample.test.+013+21237.key
-rw------- 1 bind bind  187 Aug 20 11:40 Kexample.test.+013+21237.private
-rw-r--r-- 1 bind bind  427 Aug 20 11:40 Kexample.test.+013+34505.key
-rw------- 1 bind bind  187 Aug 20 11:40 Kexample.test.+013+34505.private
```

3. Read the public halves:

```bash
grep -v '^;' keys/Kexample.test.+013+21237.key
grep -v '^;' keys/Kexample.test.+013+34505.key
```

```text
example.test. IN DNSKEY 257 3 13 mdsMFB4X0h7bK1i2qz1oQF6l0j0kQ1Yq...q1w==
example.test. IN DNSKEY 256 3 13 8lQ2rIu8y5o1nA1zK0m2wQ0f8h2y1c7d...pQ4==
```

4. Print the metadata the signing tools actually obey:

```bash
sudo -u bind dnssec-settime -p all keys/Kexample.test.+013+34505.key
```

```text
Created: Thu Aug 20 11:40:12 2026
Publish: Thu Aug 20 11:40:12 2026
Activate: Thu Aug 20 11:40:12 2026
Revoke: UNSET
Inactive: UNSET
Delete: UNSET
```

5. Derive the DS record that the *parent* will have to publish:

```bash
sudo -u bind dnssec-dsfromkey -a SHA-256 keys/Kexample.test.+013+21237.key
```

```text
example.test. IN DS 21237 13 2 4A9F1C7E2B0D6538A11E9C4477B2D0E5C83A6F91B24D7E08C5109A3B6D2F84C7
```

6. Repeat steps 1 and 5 for the parent zone `test.` (you will need its keys in Exercise 3):

```bash
sudo -u bind dnssec-keygen -a ECDSAP256SHA256 -f KSK -K keys test
sudo -u bind dnssec-keygen -a ECDSAP256SHA256        -K keys test
```

```text
Ktest.+013+47121
Ktest.+013+09134
```

**Questions — Block 2**

1. Decode `Kexample.test.+013+21237` field by field. Which of those numbers appears verbatim inside every `RRSIG` produced by that key?
2. `257` versus `256` in the DNSKEY RDATA: which bit differs, what is it called, and does the protocol *force* a SEP key to be the one signing the DNSKEY RRset?
3. Two different keys in the same zone produce the same key tag. Is the zone broken? What must a validator do?
4. The DS RDATA is `21237 13 2 4A9F…`. Name the four fields. What does `2` select, and which RFC introduced it?
5. Your operations runbook says "back up the keys". Which file is the actual secret, what happens if you lose only the `.key` file, and what happens if the `.private` file leaks?
6. Why is ECDSAP256SHA256 preferred over RSASHA256 for a zone that will be queried over UDP from the public Internet? Give the two operational reasons.

---

## Exercise 3 — Sign both zones and build the chain of trust

Order matters: sign the child first, because the child's signing run is what emits the DS set the parent must include.

1. Sign the child with *smart signing* (`-S` reads the key directory and honours the timing metadata, and injects the DNSKEY RRset for you):

```bash
cd /var/lib/bind/lab/auth
sudo -u bind dnssec-signzone -S -K keys -o example.test \
     -N INCREMENT -x -e +2592000 -t example.test.db
```

```text
Fetching KSK 21237/ECDSAP256SHA256 from key repository.
Fetching ZSK 34505/ECDSAP256SHA256 from key repository.
Verifying the zone using the following algorithms: ECDSAP256SHA256.
Zone fully signed:
Algorithm: ECDSAP256SHA256: KSKs: 1 active, 0 stand-by, 0 revoked
                            ZSKs: 1 active, 0 stand-by, 0 revoked
example.test.db.signed
Signatures generated:                        9
Signatures retained:                         0
Runtime in seconds:                       0.012
```

2. Note the two artefacts produced:

```bash
ls -1 example.test.db.signed dsset-example.test.
cat dsset-example.test.
```

```text
example.test.	IN DS	21237 13 2 4A9F1C7E2B0D6538A11E9C4477B2D0E5C83A6F91B24D7E08C5109A3B6D2F84C7
```

3. Hand the DS to the parent — append to `test.db`:

```dns
; --- secure delegation: DS supplied by the child operator ---
$INCLUDE dsset-example.test.
```

4. Sign the parent:

```bash
sudo -u bind dnssec-signzone -S -K keys -o test -N INCREMENT -x -e +2592000 -t test.db
```

5. Point `named` at the signed files. Edit `auth/named.conf`:

```conf
zone "test."         { type primary; file "test.db.signed"; };
zone "example.test." { type primary; file "example.test.db.signed"; };
```

6. Validate the *files themselves* before reloading — `named-checkzone` checks syntax, `dnssec-verify` checks cryptographic completeness:

```bash
sudo named-checkzone -D -o example.test example.test example.test.db.signed | head -20
sudo -u bind dnssec-verify -o example.test example.test.db.signed
```

```text
Loading zone 'example.test' from file 'example.test.db.signed'
Verifying the zone using the following algorithms: ECDSAP256SHA256.
Zone fully signed:
Algorithm: ECDSAP256SHA256: KSKs: 1 active, 0 stand-by, 0 revoked
                            ZSKs: 1 active, 0 stand-by, 0 revoked
```

7. Reload and dissect a signature:

```bash
sudo rndc -s 127.0.0.10 -k /var/lib/bind/lab/rndc-lab.key reload
dig @127.0.0.10 www.example.test A +dnssec +multiline +norec
```

```text
;; ANSWER SECTION:
www.example.test.	300 IN A 127.0.0.10
www.example.test.	300 IN RRSIG A 13 3 300 (
				20260919114233 20260820104233 34505 example.test.
				Wc4kR1mQx2b8l0N7pA5tZ9yE3sK6dV0hQ1fJ8u2Y
				gT7nB4cM9wX5oL0aP3rD6iS1vH8zK2eU4qC7yN0= )
```

8. Look at the apex DNSKEY RRset and confirm which key signed it:

```bash
dig @127.0.0.10 example.test DNSKEY +dnssec +multiline +norec | grep -A2 RRSIG
```

```text
example.test.		300 IN RRSIG DNSKEY 13 2 300 (
				20260919114233 20260820104233 21237 example.test.
				...
```

**Questions — Block 3**

1. Walk through the eight RDATA fields of the `RRSIG A` above and say what each one is. Which field would a validator use to detect a synthesised wildcard answer?
2. The `RRSIG A` cites key tag `34505` and the `RRSIG DNSKEY` cites `21237`. Which flag on `dnssec-signzone` produced that split, and what would happen if you dropped it?
3. `dnssec-signzone` reported "Signatures retained: 0". Under what circumstance is that number non-zero, and which option controls the threshold?
4. You need to change `www`'s address. Which file do you edit and which do you re-run — and what specifically breaks if you edit `example.test.db.signed` directly and reload?
5. `named-checkzone` accepted the file and `dnssec-verify` also passed. Which failure class does only the second one catch?
6. The DS lives in `test.db` but the DNSKEY lives in `example.test.db`. At the `example.test` zone cut, which server is authoritative for the DS RRset, and which RRSIG covers it?
7. `-e +2592000` set a 30-day validity. What is the operational failure mode of a long validity, and what is the failure mode of a short one?

---

## Exercise 4 — A validating resolver, and deliberately breaking it

1. Extract the parent's KSK public key and build a trust anchor file `/var/lib/bind/lab/lab.anchors`:

```bash
grep -v '^;' /var/lib/bind/lab/auth/keys/Ktest.+013+47121.key
```

```conf
trust-anchors {
    test. static-key 257 3 13 "AwEAAb3rQ0k9p2Y8mV1sK6tZ...n7Qw==";
};
```

Equivalent and often preferable — anchor the *digest* instead of the key, so a KSK rollover under RFC 5011 does not invalidate the file:

```conf
trust-anchors {
    test. static-ds 47121 13 2 "9C2E4B7A0D18F63C5511E0A94B7D2C86F31A0E57B9D4620C8A13F5E790B6D4C21";
};
```

2. Write `/var/lib/bind/lab/resolver/named.conf`:

```conf
include "/var/lib/bind/lab/rndc-lab.key";
include "/var/lib/bind/lab/lab.anchors";

controls {
    inet 127.0.0.20 port 953 allow { 127.0.0.1; } keys { "rndc-lab"; };
};

options {
    directory    "/var/lib/bind/lab/resolver";
    pid-file     "resolver.pid";
    listen-on    { 127.0.0.20; };
    listen-on-v6 { none; };
    recursion    yes;
    allow-query  { 127.0.0.0/8; };

    dnssec-validation yes;      // validate using the anchors configured above,
                                // NOT the built-in root key from bind.keys
};

logging {
    channel stderrlog { stderr; severity debug 3; print-category yes; };
    category dnssec { stderrlog; };
    category resolver { stderrlog; };
};

// Lab shortcut: there is no root zone here, so send everything under
// test. straight at the authoritative instance.
zone "test." {
    type forward;
    forward only;
    forwarders { 127.0.0.10; };
};
```

3. Start it in a second terminal:

```bash
sudo named -c /var/lib/bind/lab/resolver/named.conf -u bind -g
```

4. Ask the resolver and look for the `ad` flag:

```bash
dig @127.0.0.20 www.example.test A +dnssec
```

```text
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 55011
;; flags: qr rd ra ad; QUERY: 1, ANSWER: 2, AUTHORITY: 0, ADDITIONAL: 1
```

5. Confirm the resolver really loaded your anchor and nothing else:

```bash
sudo rndc -s 127.0.0.20 -k /var/lib/bind/lab/rndc-lab.key secroots -
```

```text
Secure roots:
./IN
: 
  test.
  - static: 47121/ECDSAP256SHA256
Negative trust anchors:
```

6. Validate independently of the resolver's opinion with `delv`, which does its own cryptography client-side:

```bash
delv @127.0.0.20 -a /var/lib/bind/lab/lab.anchors +root=test. \
     +rtrace +vtrace www.example.test A
```

```text
;; fetch: www.example.test/A
;; fetch: example.test/DNSKEY
;; fetch: example.test/DS
;; fetch: test/DNSKEY
;; validating test/DNSKEY: starting
;; validating test/DNSKEY: verify rdataset (keyid=47121): success
;; validating example.test/DS: verify rdataset (keyid=9134): success
;; validating example.test/DNSKEY: verify rdataset (keyid=21237): success
;; validating www.example.test/A: verify rdataset (keyid=34505): success
; fully validated
www.example.test.	300	IN	A	127.0.0.10
www.example.test.	300	IN	RRSIG	A 13 3 300 20260919114233 (...)
```

7. Now break it. Edit the **signed** file `auth/example.test.db.signed`, change `www`'s A record to `127.0.0.99`, leave the RRSIG untouched, reload the authoritative server, and flush the resolver cache:

```bash
sudo sed -i 's/^www.example.test.\t300\tIN\tA\t127.0.0.10/www.example.test.\t300\tIN\tA\t127.0.0.99/' \
     /var/lib/bind/lab/auth/example.test.db.signed
sudo rndc -s 127.0.0.10 -k /var/lib/bind/lab/rndc-lab.key reload
sudo rndc -s 127.0.0.20 -k /var/lib/bind/lab/rndc-lab.key flush
dig @127.0.0.20 www.example.test A +dnssec
```

```text
;; ->>HEADER<<- opcode: QUERY, status: SERVFAIL, id: 12730
;; flags: qr rd ra; QUERY: 1, ANSWER: 0, AUTHORITY: 0, ADDITIONAL: 1
;; OPT PSEUDOSECTION:
; EDNS: version: 0, flags: do; udp: 1232
; EDE: 6 (DNSSEC Bogus): (no valid signature found)
```

8. Prove the resolver is the one refusing, not the authoritative server:

```bash
dig @127.0.0.20 www.example.test A +cd +short
dig @127.0.0.10 www.example.test A +short +norec
```

```text
127.0.0.99
127.0.0.99
```

9. Now reproduce the single most common real-world DNSSEC outage — expired signatures — by re-signing into the past:

```bash
cd /var/lib/bind/lab/auth
sudo -u bind dnssec-signzone -S -K keys -o example.test -N INCREMENT -x \
     -s 20260701000000 -e 20260710000000 example.test.db
sudo rndc -s 127.0.0.10 -k /var/lib/bind/lab/rndc-lab.key reload
sudo rndc -s 127.0.0.20 -k /var/lib/bind/lab/rndc-lab.key flush
dig @127.0.0.20 www.example.test A +dnssec
```

```text
;; ->>HEADER<<- opcode: QUERY, status: SERVFAIL, id: 44120
; EDE: 7 (Signature Expired)
```

10. Learn the emergency lever. A negative trust anchor suspends validation for one subtree, for a bounded time, without touching the configuration:

```bash
sudo rndc -s 127.0.0.20 -k /var/lib/bind/lab/rndc-lab.key nta example.test
sudo rndc -s 127.0.0.20 -k /var/lib/bind/lab/rndc-lab.key nta -dump
dig @127.0.0.20 www.example.test A +short
sudo rndc -s 127.0.0.20 -k /var/lib/bind/lab/rndc-lab.key nta -remove example.test
```

```text
Negative trust anchor added: example.test/_default, expires 20 Aug 2026 13:42:07
example.test/_default: expiry 20 Aug 2026 13:42:07
127.0.0.99
```

11. Repair the zone: restore `127.0.0.10` in `example.test.db` (the unsigned source), re-sign normally, reload, flush, and confirm the `ad` flag is back.

**Questions — Block 4**

1. `dnssec-validation` accepts `yes`, `no` and `auto`. Define all three precisely, name the BIND 9.18 default, and explain why this lab must use `yes`.
2. In step 7 the resolver returned SERVFAIL while the authoritative server happily returned `127.0.0.99`. Which security property of DNSSEC does that demonstrate, and which property does it *not* provide?
3. What did `+cd` change in the query, and why is "just add `+cd`" the wrong permanent fix?
4. Distinguish the `do`, `ad` and `cd` flags: who sets each, and in which direction does each travel?
5. A user reports "DNS is broken". You get SERVFAIL from your resolver and a correct answer from the authoritative server with `+cd`. List the four checks you would run, in order, and the tool for each.
6. EDE 6 versus EDE 7 (RFC 8914): what different root causes do they point to, and why is EDE 7 disproportionately common in production?
7. `rndc nta` bought you an outage bypass. What is its default lifetime, what caps it, and what is the concrete risk of using it?
8. Why did `delv` still work in step 6 even though it queried the *same* resolver — what is it doing that `dig` is not?

---

## Exercise 5 — NSEC, zone walking, and NSEC3

1. Restore a healthy signed zone (Exercise 4 step 11) and query a name that does not exist:

```bash
dig @127.0.0.10 nothere.example.test A +dnssec +norec +multiline
```

```text
;; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: 39221
;; AUTHORITY SECTION:
example.test.		300 IN SOA ns1.example.test. hostmaster.example.test. (
				2026082004 3600 900 604800 300 )
example.test.		300 IN RRSIG SOA 13 2 300 (...)
mail.example.test.	300 IN NSEC ns1.example.test. A RRSIG NSEC
mail.example.test.	300 IN RRSIG NSEC 13 3 300 (...)
example.test.		300 IN NSEC mail.example.test. NS SOA MX RRSIG NSEC DNSKEY
example.test.		300 IN RRSIG NSEC 13 3 300 (...)
```

2. Walk the zone using nothing but public queries — no AXFR, no credentials:

```bash
for n in example.test mail.example.test ns1.example.test www.example.test; do
  dig @127.0.0.10 +norec +noall +authority +answer "$n" NSEC | awk '/[ \t]NSEC[ \t]/ {print $1, "->", $5}'
done
```

```text
example.test. -> mail.example.test.
mail.example.test. -> ns1.example.test.
ns1.example.test. -> www.example.test.
www.example.test. -> example.test.
```

3. Re-sign with NSEC3, following **RFC 9276** (zero iterations, empty salt):

```bash
cd /var/lib/bind/lab/auth
sudo -u bind dnssec-signzone -S -K keys -o example.test -N INCREMENT -x \
     -3 - -H 0 -e +2592000 example.test.db
sudo rndc -s 127.0.0.10 -k /var/lib/bind/lab/rndc-lab.key reload
```

4. Inspect the parameters and the hashed denial:

```bash
dig @127.0.0.10 example.test NSEC3PARAM +norec +noall +answer
dig @127.0.0.10 nothere.example.test A +dnssec +norec +noall +authority | grep NSEC3
```

```text
example.test.		0	IN	NSEC3PARAM 1 0 0 -

3AL4M5DGVQ7B9CBM7EI8T2QK0P5CO1H8.example.test. 300 IN NSEC3 1 0 0 - 8QK1RB3J9P0V4M6DLT2N7GA5FC0EU9SO A RRSIG
QOFN6BLU5R2K8V0M3JD1TC7A9GS4PE2H.example.test. 300 IN NSEC3 1 0 0 - EL7T0MCK4B9RV2N6GD3JQ1AS8UP5FO0X NS SOA MX RRSIG DNSKEY NSEC3PARAM
```

5. Compute a hashed owner name yourself and match it against the chain:

```bash
sudo -u bind nsec3hash - 1 0 www.example.test
```

```text
8QK1RB3J9P0V4M6DLT2N7GA5FC0EU9SO (salt=-, hash=1, iterations=0)
```

6. Observe the opt-out variant, which only makes sense for delegation-heavy zones such as a TLD — sign `test.` with it:

```bash
sudo -u bind dnssec-signzone -S -K keys -o test -N INCREMENT -x -3 - -H 0 -A test.db
```

**Questions — Block 5**

1. In step 1, two NSEC records were returned for a single NXDOMAIN. What does each one prove?
2. The NSEC record for `mail` lists `A RRSIG NSEC`. What is that field called and what second attack does it defeat?
3. You walked the entire zone with ordinary queries. Is that a DNSSEC vulnerability or a design consequence? What is the authoritative statement on it (RFC and section)?
4. Decode `NSEC3PARAM 1 0 0 -` field by field. Why does it carry a TTL of `0`?
5. RFC 9276 says iterations `0` and an empty salt. Explain both, given that more iterations intuitively sound "more secure". What does BIND 9.18 do when it validates a response with iterations above 150?
6. What does `-A` (opt-out) change about which names get NSEC3 records, what does it buy, and what does it cost the security model?
7. NSEC3 hashes the *owner name*. Name two properties of a real zone that make offline cracking of those hashes cheap regardless of iterations.

---

## Exercise 6 — Key rollovers with timing metadata

1. Read the current ZSK metadata and plan a pre-publish rollover. Create a successor key — `-S` inherits algorithm and size and computes the timings:

```bash
cd /var/lib/bind/lab/auth
sudo -u bind dnssec-settime -K keys -I +7d -D +14d Kexample.test.+013+34505
sudo -u bind dnssec-keygen  -K keys -S Kexample.test.+013+34505 -i 3d
```

```text
./Kexample.test.+013+34505.key
./Kexample.test.+013+34505.private
Kexample.test.+013+51876
```

2. Confirm the schedule of both keys:

```bash
sudo -u bind dnssec-settime -K keys -p Publish -p Activate -p Inactive -p Delete \
     keys/Kexample.test.+013+34505.key keys/Kexample.test.+013+51876.key
```

```text
Publish: Thu Aug 20 11:40:12 2026
Activate: Thu Aug 20 11:40:12 2026
Inactive: Thu Aug 27 11:40:12 2026
Delete: Thu Sep  3 11:40:12 2026

Publish: Mon Aug 24 11:40:12 2026
Activate: Thu Aug 27 11:40:12 2026
Inactive: UNSET
Delete: UNSET
```

3. Re-sign. Smart signing publishes only what the metadata says is publishable *right now*:

```bash
sudo -u bind dnssec-signzone -S -K keys -o example.test -N INCREMENT -x -3 - -H 0 example.test.db
dig @127.0.0.10 example.test DNSKEY +norec +noall +answer | awk '{print $1, $5, $6, $7}' | sort -u
```

```text
example.test. 256 3 13
example.test. 257 3 13
```

4. Simulate the passage of time by forcing the successor to be published immediately, then re-sign and re-inspect:

```bash
sudo -u bind dnssec-settime -K keys -P now Kexample.test.+013+51876
sudo -u bind dnssec-signzone -S -K keys -o example.test -N INCREMENT -x -3 - -H 0 example.test.db
dig @127.0.0.10 example.test DNSKEY +norec +noall +answer | wc -l
dig @127.0.0.10 www.example.test A +dnssec +norec +noall +answer | grep RRSIG
```

```text
3
www.example.test.	300	IN	RRSIG	A 13 3 300 20260919... 34505 example.test. ...
```

5. Force the successor to become active and watch the RRSIGs — not the DNSKEYs — switch:

```bash
sudo -u bind dnssec-settime -K keys -A now Kexample.test.+013+51876
sudo -u bind dnssec-settime -K keys -I now Kexample.test.+013+34505
sudo -u bind dnssec-signzone -S -K keys -o example.test -N INCREMENT -x -3 - -H 0 example.test.db
sudo rndc -s 127.0.0.10 -k /var/lib/bind/lab/rndc-lab.key reload
dig @127.0.0.10 www.example.test A +dnssec +norec +noall +answer | grep RRSIG
```

```text
www.example.test.	300	IN	RRSIG	A 13 3 300 20260919... 51876 example.test. ...
```

6. For the KSK, the constraint moves to the parent. Generate a second KSK, publish both DNSKEYs and both DS records, and only then retire the old one:

```bash
sudo -u bind dnssec-keygen -a ECDSAP256SHA256 -f KSK -K keys example.test
sudo -u bind dnssec-signzone -S -K keys -o example.test -N INCREMENT -x -3 - -H 0 example.test.db
cat dsset-example.test.
```

```text
Kexample.test.+013+60418
example.test.	IN DS	21237 13 2 4A9F1C7E2B0D6538A11E9C4477B2D0E5C83A6F91B24D7E08C5109A3B6D2F84C7
example.test.	IN DS	60418 13 2 7E1B03D9A5C82F460D1197EB35A0C7F248B6D91E0A3F5742C8B10E96D4A2F583
```

Re-run the `$INCLUDE` in `test.db`, re-sign the parent, reload, and verify the resolver still returns `ad`.

**Questions — Block 6**

1. Name and define the five `dnssec-settime` timing events (`-P`, `-A`, `-R`, `-I`, `-D`). Which two must never be set to the same instant, and why?
2. Between step 4 and step 5, the DNSKEY count went to 3 and *then* the RRSIGs changed. Restate that as the pre-publish rollover invariant, in terms of what a validator may hold in cache.
3. Why is pre-publish the standard ZSK strategy and double-DS/double-signature the standard KSK strategy? What resource does each strategy actually wait on?
4. Which two TTLs bound the minimum safe duration of a ZSK rollover step? Which parameter, outside your control, bounds the KSK step?
5. A colleague deletes the old ZSK's `.private` file "because the new one is active now", one hour after step 5. What breaks and for how long?
6. Explain the failure mode of an *algorithm* rollover (13 → 15) that a same-algorithm rollover does not have. Which rule in RFC 6781 covers it?
7. Under RFC 5011, which DNSKEY flag signals imminent withdrawal, and what is the mandatory hold-down timer?

---

## Exercise 7 — `dnssec-policy`: how this is actually run in production

Everything above is the manual pipeline the exam expects you to know. Nobody operates it that way at scale. BIND 9.16+ replaces it with a declarative policy and in-daemon key management.

1. Add a policy to `auth/named.conf`, above the zone statements:

```conf
dnssec-policy "lab" {
    dnskey-ttl                  300;
    max-zone-ttl                3600;

    keys {
        ksk key-directory lifetime unlimited algorithm ecdsap256sha256;
        zsk key-directory lifetime P30D      algorithm ecdsap256sha256;
    };

    nsec3param iterations 0 optout no salt-length 0;

    signatures-validity         P14D;
    signatures-validity-dnskey  P14D;
    signatures-refresh          P5D;

    publish-safety              PT1H;
    retire-safety               PT1H;
    zone-propagation-delay      PT5M;
    parent-ds-ttl               300;
    parent-propagation-delay    PT1H;
};
```

2. Convert the child zone. Point it back at the **unsigned** source file and let `named` own the signing:

```conf
zone "example.test." {
    type primary;
    file "example.test.db";
    key-directory "keys";
    dnssec-policy "lab";
    inline-signing yes;
};
```

3. Remove the hand-made artefacts so you can see the daemon build its own, then restart:

```bash
cd /var/lib/bind/lab/auth
sudo rm -f example.test.db.signed example.test.db.signed.jnl dsset-example.test.
sudo named-checkconf /var/lib/bind/lab/auth/named.conf
sudo rndc -s 127.0.0.10 -k /var/lib/bind/lab/rndc-lab.key reconfig
```

4. Watch it sign, in the log:

```text
zone example.test/IN (unsigned): loaded serial 2026082010
zone example.test/IN (signed): reconfiguring zone keys
keymgr: DNSKEY example.test/ECDSAP256SHA256/21237 (KSK) created for policy lab
keymgr: DNSKEY example.test/ECDSAP256SHA256/34505 (ZSK) created for policy lab
zone example.test/IN (signed): next key event: 20-Aug-2026 12:45:31.000
```

5. Interrogate key state — this is the command you will live in:

```bash
sudo rndc -s 127.0.0.10 -k /var/lib/bind/lab/rndc-lab.key dnssec -status example.test
```

```text
dnssec-policy: lab
current time:  Thu Aug 20 11:47:02 2026

key: 21237 (ECDSAP256SHA256), KSK
  published:      yes - since Thu Aug 20 11:45:31 2026
  key signing:    yes - since Thu Aug 20 11:45:31 2026

  No rollover scheduled
  - goal:           omnipresent
  - dnskey:         rumoured
  - ds:             hidden
  - key rrsig:      rumoured

key: 34505 (ECDSAP256SHA256), ZSK
  published:      yes - since Thu Aug 20 11:45:31 2026
  zone signing:    yes - since Thu Aug 20 11:45:31 2026

  Next rollover scheduled on Sat Sep 19 11:45:31 2026
  - goal:           omnipresent
  - dnskey:         rumoured
  - zone rrsig:     rumoured
```

6. The DS state is `hidden` — `named` is waiting to be told the parent published it. Publish the DS in `test.db` as before, then inform the daemon:

```bash
sudo -u bind dnssec-dsfromkey -a SHA-256 keys/Kexample.test.+013+21237.key
# ... add to test.db, re-sign the parent, reload ...
sudo rndc -s 127.0.0.10 -k /var/lib/bind/lab/rndc-lab.key \
     dnssec -checkds -key 21237 published example.test
```

```text
KSK 21237: Marked DS as published
```

7. Trigger an unscheduled ZSK rollover — the emergency procedure, now a one-liner:

```bash
sudo rndc -s 127.0.0.10 -k /var/lib/bind/lab/rndc-lab.key \
     dnssec -rollover -key 34505 example.test
sudo rndc -s 127.0.0.10 -k /var/lib/bind/lab/rndc-lab.key dnssec -status example.test
```

8. Look at what appeared on disk:

```bash
ls -1 /var/lib/bind/lab/auth/example.test.db*
```

```text
/var/lib/bind/lab/auth/example.test.db
/var/lib/bind/lab/auth/example.test.db.jbk
/var/lib/bind/lab/auth/example.test.db.signed
/var/lib/bind/lab/auth/example.test.db.signed.jnl
```

**Questions — Block 7**

1. With `inline-signing yes`, which file do you edit, which files must you never touch, and what does `.jnl` hold?
2. Explain the key-state machine words `hidden`, `rumoured`, `omnipresent`, `unretentive`. Which TTL drives each transition?
3. The KSK sat at `ds: hidden` until step 6. What is `named` protecting you against by refusing to advance on its own?
4. `signatures-validity P14D` with `signatures-refresh P5D`. What does refresh mean, and what is the consequence of setting refresh too close to validity?
5. Which three policy parameters encode "how long until the rest of the world sees my change", and why can none of them be zero in a real deployment with secondaries?
6. `parent-ds-ttl` and `parent-propagation-delay` describe someone else's infrastructure. Where do you get correct values, and what happens if you guess low?
7. What do CDS and CDNSKEY (RFC 7344/8078) automate here, and what would `CDS 0 0 0 00` in a child zone instruct the parent to do?

---

## Exercise 8 — TSIG: authenticating the transaction, not the data

1. Generate a transfer key and install it on the authoritative server:

```bash
sudo -u bind tsig-keygen -a hmac-sha256 xfr-lab | sudo tee /var/lib/bind/lab/xfr-lab.key
sudo chown bind:bind /var/lib/bind/lab/xfr-lab.key
sudo chmod 640 /var/lib/bind/lab/xfr-lab.key
```

2. Reference it in `auth/named.conf`:

```conf
include "/var/lib/bind/lab/xfr-lab.key";

zone "example.test." {
    type primary;
    file "example.test.db";
    key-directory "keys";
    dnssec-policy "lab";
    inline-signing yes;
    allow-transfer { key "xfr-lab"; };
    also-notify { 127.0.0.20 key "xfr-lab"; };
};
```

```bash
sudo rndc -s 127.0.0.10 -k /var/lib/bind/lab/rndc-lab.key reconfig
```

3. Attempt an unauthenticated transfer:

```bash
dig @127.0.0.10 example.test AXFR
```

```text
; <<>> DiG 9.18.28 <<>> @127.0.0.10 example.test AXFR
;; global options: +cmd
; Transfer failed.
```

4. Transfer with the key. Use `-k` (key **file**), not `-y`:

```bash
dig @127.0.0.10 example.test AXFR -k /var/lib/bind/lab/xfr-lab.key | head -8
```

```text
example.test.		300	IN	SOA	ns1.example.test. hostmaster.example.test. 2026082012 3600 900 604800 300
example.test.		300	IN	RRSIG	SOA 13 2 300 20260903... 34505 example.test. ...
example.test.		300	IN	NS	ns1.example.test.
example.test.		300	IN	DNSKEY	256 3 13 8lQ2rIu8y5o1nA1zK0m2wQ0f8h2y1c7d...
example.test.		300	IN	DNSKEY	257 3 13 mdsMFB4X0h7bK1i2qz1oQF6l0j0kQ1Yq...
;; XFR size: 21 records (messages 1, bytes 2361)
```

5. Reproduce a `BADKEY` by presenting a key the server does not know:

```bash
tsig-keygen -a hmac-sha256 wrong-key > /tmp/wrong.key
dig @127.0.0.10 example.test AXFR -k /tmp/wrong.key
```

```text
;; ->>HEADER<<- opcode: QUERY, status: NOTAUTH, id: 61027
;; TSIG PSEUDOSECTION:
wrong-key.		0	ANY	TSIG	hmac-sha256. 1787313522 300 0 ... 61027 BADKEY 0
; Transfer failed.
```

6. Reproduce a `BADTIME` by skewing the clock beyond the 300-second fudge:

```bash
faketime '+10 minutes' dig @127.0.0.10 example.test AXFR -k /var/lib/bind/lab/xfr-lab.key
```

```text
;; ->>HEADER<<- opcode: QUERY, status: NOTAUTH, id: 22984
;; TSIG PSEUDOSECTION:
xfr-lab.		0	ANY	TSIG	hmac-sha256. 1787314122 300 0 ... 22984 BADTIME 0
```

7. Configure the resolver instance as a secondary for the same zone, authenticated with the same key. Add to `resolver/named.conf`:

```conf
include "/var/lib/bind/lab/xfr-lab.key";

server 127.0.0.10 {
    keys { "xfr-lab"; };
};

zone "example.test." {
    type secondary;
    file "example.test.db.bak";
    primaries { 127.0.0.10; };
};
```

```bash
sudo rndc -s 127.0.0.20 -k /var/lib/bind/lab/rndc-lab.key reconfig
sudo rndc -s 127.0.0.20 -k /var/lib/bind/lab/rndc-lab.key retransfer example.test
```

```text
zone example.test/IN: Transfer started.
transfer of 'example.test/IN' from 127.0.0.10#53: connected using 127.0.0.20#37194 TSIG xfr-lab
zone example.test/IN: transferred serial 2026082012: TSIG 'xfr-lab'
```

**Questions — Block 8**

1. Does TSIG encrypt the zone transfer? State exactly which of confidentiality, integrity and origin authentication it provides.
2. Both TSIG and DNSSEC use cryptography on DNS messages. Give the three axes on which they differ: what is protected, key distribution, and scope of trust.
3. `-k` versus `-y` on `dig`: name the two concrete leaks `-y` causes on a shared host.
4. `BADKEY`, `BADSIG` and `BADTIME` all surface as rcode `NOTAUTH`. What distinct condition does each signal, and where in the response do you read them?
5. Why does TSIG include a timestamp and fudge at all — which attack is it stopping, and what does that make NTP on your name servers?
6. The `server 127.0.0.10 { keys { "xfr-lab"; }; };` block is on the secondary. What would happen without it, given the key is already `include`d?
7. `allow-transfer { key "xfr-lab"; };` restricts AXFR. Now that the zone is signed and NSEC3 is in use, is restricting AXFR still worth doing? Argue both sides.
8. `rndc` uses TSIG too. Where does the default key live on a stock Debian install, and why is `controls { inet * ... }` a critical misconfiguration?

---

## Exercise 9 — DANE: publishing X.509 in the DNS

1. Create a self-signed EC certificate for `www.example.test`:

```bash
sudo mkdir -p /var/lib/bind/lab/tls && cd /var/lib/bind/lab/tls
sudo openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -noenc \
     -keyout www.key -out www.crt -days 365 \
     -subj "/CN=www.example.test" \
     -addext "subjectAltName=DNS:www.example.test"
sudo openssl x509 -in www.crt -noout -subject -dates -ext subjectAltName
```

```text
subject=CN = www.example.test
notBefore=Aug 20 12:03:44 2026 GMT
notAfter=Aug 20 12:03:44 2027 GMT
X509v3 Subject Alternative Name:
    DNS:www.example.test
```

2. Compute the TLSA association data for selector `1` (SubjectPublicKeyInfo) and matching type `1` (SHA-256):

```bash
sudo openssl x509 -in www.crt -noout -pubkey \
  | openssl pkey -pubin -outform DER \
  | openssl dgst -sha256 -binary \
  | xxd -p -c 64
```

```text
5f2c9a41b73e08d6c1524fb097ae3d1682cb45790e6a1d3f84b20c7591de6a04
```

3. For contrast, compute selector `0` (the full certificate):

```bash
sudo openssl x509 -in www.crt -outform DER | openssl dgst -sha256 -binary | xxd -p -c 64
```

```text
a70b1e5c93d248fa06b7c1e3592d0847fb6a19c250e38d71b4c069af23158de6
```

4. Publish the record in `auth/example.test.db` (remember: the *unsigned* source, `named` re-signs). The service will run on 8443 so no root is needed:

```dns
_8443._tcp.www   IN TLSA 3 1 1 5f2c9a41b73e08d6c1524fb097ae3d1682cb45790e6a1d3f84b20c7591de6a04
```

Bump the SOA serial, then:

```bash
sudo rndc -s 127.0.0.10 -k /var/lib/bind/lab/rndc-lab.key reload example.test
dig @127.0.0.20 _8443._tcp.www.example.test TLSA +dnssec +short
dig @127.0.0.20 _8443._tcp.www.example.test TLSA | grep flags
```

```text
3 1 1 5F2C9A41B73E08D6C1524FB097AE3D1682CB45790E6A1D3F84B20C7591DE6A04
A 13 5 300 20260903... 34505 example.test. Wc4k...
;; flags: qr rd ra ad; QUERY: 1, ANSWER: 2, AUTHORITY: 0, ADDITIONAL: 1
```

5. Start a TLS server using nothing but OpenSSL:

```bash
sudo openssl s_server -accept 127.0.0.10:8443 -cert /var/lib/bind/lab/tls/www.crt \
     -key /var/lib/bind/lab/tls/www.key -www
```

6. In another terminal, verify the peer *against the TLSA record only* — no CA bundle involved:

```bash
openssl s_client -connect 127.0.0.10:8443 -servername www.example.test \
  -dane_tlsa_domain www.example.test \
  -dane_tlsa_rrdata "3 1 1 5f2c9a41b73e08d6c1524fb097ae3d1682cb45790e6a1d3f84b20c7591de6a04" \
  </dev/null 2>&1 | grep -Ei 'verify|dane|peername'
```

```text
depth=0 CN = www.example.test
verify error:num=18:self-signed certificate
verify return:1
DANE TLSA 3 1 1 ...91de6a04 matched EE certificate at depth 0
Verified peername: www.example.test
    Verify return code: 0 (ok)
```

7. Prove the binding is real by presenting a mismatched association:

```bash
openssl s_client -connect 127.0.0.10:8443 -servername www.example.test \
  -dane_tlsa_domain www.example.test \
  -dane_tlsa_rrdata "3 1 1 0000000000000000000000000000000000000000000000000000000000000000" \
  </dev/null 2>&1 | grep -Ei 'verify return code|dane'
```

```text
    Verify return code: 65 (CA signature digest algorithm too weak)
```

*(the exact code varies by OpenSSL build; what matters is that it is non-zero and no "matched EE certificate" line appears)*

8. Do the full end-to-end thing — lookup **and** validation — with a client that actually resolves the record. Point `/etc/resolv.conf` (or use `-n`) at the validating resolver:

```bash
ldns-dane -n -s 127.0.0.20 verify www.example.test 8443
```

```text
www.example.test. 8443 TLSA 3 1 1 5f2c...6a04 did match
```

9. Publish an SSHFP record (RFC 4255) — the same idea applied to SSH host keys:

```bash
ssh-keygen -r www.example.test -f /etc/ssh/ssh_host_ed25519_key.pub
```

```text
www.example.test IN SSHFP 4 1 9d3e6c1a70b4582f0e19d7c3a64b0158cf27e9d0
www.example.test IN SSHFP 4 2 c81f0a6b2d4759e0138acf6472b9d05e3a1780c6425f9db31e0a76c4589f2d13
```

Add the type-2 (SHA-256) form to the zone, re-sign, and test with `ssh -o VerifyHostKeyDNS=yes -o StrictHostKeyChecking=ask`.

**Questions — Block 9**

1. Decode `TLSA 3 1 1`: name all three fields and their values. What are the other options for each?
2. In step 6, OpenSSL printed `verify error:num=18:self-signed certificate` and *still* finished with `Verify return code: 0 (ok)`. Explain precisely why both are true.
3. Usage `3` is DANE-EE. Under RFC 7671, does the client still check that the certificate's SAN matches the hostname? What is the practical consequence for certificate management?
4. What does DANE fundamentally require of the DNS, and what exactly is a TLSA record worth if the zone is unsigned or the client does not validate?
5. `openssl s_client -dane_tlsa_rrdata` takes the record on the command line. Which two things does a real DANE client do that this invocation does not?
6. The owner name is `_8443._tcp.www.example.test`. Derive the owner name for an SMTP server `mx1.example.test` on port 25. For SMTP DANE (RFC 7672), which name is the TLSA record attached to — the MX hostname or the mail domain — and what must be true of the MX RRset?
7. You are rotating the certificate on `www`. Write the correct sequence of operations, and name the DNSSEC procedure from Exercise 6 that it structurally mirrors.
8. Why has DANE seen wide adoption in SMTP and essentially none in web browsers? Give the technical reason, not just "vendors did not implement it".

---

## Exercise 10 — Encrypted transport: DoT and DoH

DNSSEC authenticates data. It does nothing for confidentiality — anyone on the path reads every question you ask. DoT and DoH close that, on the stub-to-resolver hop.

1. Give the resolver a TLS certificate and a `tls` statement in `resolver/named.conf`:

```bash
sudo openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -noenc \
     -keyout /var/lib/bind/lab/tls/dns.key -out /var/lib/bind/lab/tls/dns.crt \
     -days 365 -subj "/CN=dns.example.test" -addext "subjectAltName=DNS:dns.example.test"
sudo chown bind:bind /var/lib/bind/lab/tls/dns.*
sudo chmod 640 /var/lib/bind/lab/tls/dns.key
```

```conf
tls lab-tls {
    cert-file "/var/lib/bind/lab/tls/dns.crt";
    key-file  "/var/lib/bind/lab/tls/dns.key";
    protocols { TLSv1.2; TLSv1.3; };
    prefer-server-ciphers yes;
};

options {
    // ... existing options ...
    listen-on port 53  { 127.0.0.20; };
    listen-on port 853 tls lab-tls { 127.0.0.20; };                 // DoT, RFC 7858
    listen-on port 443 tls lab-tls http default { 127.0.0.20; };    // DoH, RFC 8484
};
```

2. Restart and confirm the sockets:

```bash
sudo rndc -s 127.0.0.20 -k /var/lib/bind/lab/rndc-lab.key reconfig
sudo ss -lntp | grep -E '127.0.0.20:(53|443|853)'
```

```text
LISTEN 0 10 127.0.0.20:853  0.0.0.0:* users:(("named",pid=8841,fd=27))
LISTEN 0 10 127.0.0.20:443  0.0.0.0:* users:(("named",pid=8841,fd=28))
LISTEN 0 10 127.0.0.20:53   0.0.0.0:* users:(("named",pid=8841,fd=25))
```

3. Query over DoT and over DoH:

```bash
kdig +tls @127.0.0.20 www.example.test A
kdig +https=/dns-query @127.0.0.20 www.example.test A
```

```text
;; TLS session (TLS1.3)-(ECDHE-SECP256R1)-(ECDSA-SECP256R1-SHA256)-(AES-256-GCM)
;; ->>HEADER<<- opcode: QUERY; status: NOERROR; id: 3921
;; Flags: qr rd ra ad; QUERY: 1; ANSWER: 1; AUTHORITY: 0; ADDITIONAL: 1
;; ANSWER SECTION:
www.example.test.   	300	IN	A	127.0.0.10

;; HTTPS session (HTTP/2-POST)-(TLS1.3)-(ECDHE-SECP256R1)-(AES-256-GCM)
```

4. Confirm the ALPN identifiers each protocol negotiates:

```bash
openssl s_client -connect 127.0.0.20:853 -alpn dot </dev/null 2>&1 | grep -i alpn
openssl s_client -connect 127.0.0.20:443 -alpn h2  </dev/null 2>&1 | grep -i alpn
```

```text
ALPN protocol: dot
ALPN protocol: h2
```

5. Show that the `ad` flag survives the encrypted hop, and that it is the *resolver's* claim, not TLS's:

```bash
kdig +tls +dnssec @127.0.0.20 www.example.test A | grep -E 'Flags|EDE'
```

**Questions — Block 10**

1. Put DNSSEC, TSIG and DoT side by side: for each, name what is protected, against whom, and on which hop.
2. DoT is port 853, DoH is 443 with a URI template. Why did DoH deliberately choose 443 and normal HTTPS, and what does that do to an operator's ability to see or block DNS?
3. Once traffic is on DoT, is DNSSEC validation redundant? Give the concrete attack that TLS to your resolver does not stop.
4. When a stub connects over DoT and the resolver sets `ad`, what is the stub actually trusting? Which two configurations restore end-to-end assurance?
5. `kdig` accepted a self-signed certificate here. Which options would enforce real authentication of the resolver, and what is "strict" versus "opportunistic" DoT?
6. BIND is now serving DNS on 443. Name two operational consequences for a host that also serves HTTPS.

---

## Exercise 11 — Diagnostic drill

For each symptom, write the most probable cause and the single command that confirms it. Then run the ones you can reproduce in this lab.

1. `dig @resolver name A` → `SERVFAIL`. `dig @resolver name A +cd` → correct answer.
2. `dig @auth name A +norec` → correct. `dig @resolver name A` → `SERVFAIL`. `rndc secroots` shows a static anchor for the parent whose key tag is not in the parent's current DNSKEY RRset.
3. The zone worked for 27 days and broke overnight. Nothing was changed.
4. `delv` reports `; fully validated` from your laptop, but the resolver in the datacentre returns SERVFAIL for the same name.
5. `dig DNSKEY` over UDP returns a truncated response and the `tc` flag; TCP works. Validation intermittently fails from some networks.
6. `named` logs `zone example.test/IN: NSEC3 iterations 500 out of range`.
7. A newly delegated child validates as **insecure** rather than secure — no SERVFAIL, but no `ad` flag either.
8. The secondary logs `transfer of 'example.test/IN' from 127.0.0.10#53: failed while receiving responses: tsig indicates error`.

Useful commands for this drill:

```bash
dig @<r> <name> <type> +dnssec +multiline
dig @<r> <name> <type> +cd
delv @<r> <name> <type> +rtrace +vtrace -a <anchors> +root=<zone>
dnssec-verify -o <zone> <signedfile>
named-checkzone -D -o <zone> <zone> <signedfile>
rndc -s <r> secroots -
rndc -s <r> nta -dump
rndc -s <a> dnssec -status <zone>
rndc -s <r> dumpdb -cache && grep -i <name> /var/cache/bind/named_dump.db
dig @<r> <name> <type> +bufsize=1232 +ignore     # EDNS/fragmentation probe
```

For zones that are actually on the Internet, the reference third-party tools are **DNSViz** (`https://dnsviz.net/`) and Verisign's **DNSSEC Debugger** (`https://dnssec-debugger.verisignlabs.com/`), both of which render the full chain of trust graphically.

**Questions — Block 11**

Answer all eight items above: probable cause + confirming command.

---

## Teardown

```bash
sudo pkill -f '/var/lib/bind/lab' 
sudo rm -rf /var/lib/bind/lab
# RHEL/Fedora only:
sudo semanage fcontext -d "/var/lib/bind/lab(/.*)?" 2>/dev/null
```

---

<details>
<summary><b>Answers</b></summary>

### Block 1

1. **No RRSIG is expected** — the zone is unsigned at this point, so there is nothing to return. **No `ad` flag is also expected, but for a different reason**: `ad` is set by a *validating recursive resolver*, and you queried an authoritative server directly. Even against a fully signed zone, an authoritative server does not set `ad`. In a signed deployment, a missing RRSIG under `+dnssec` would be a bug; a missing `ad` from an authoritative server never is.

2. `aa` = Authoritative Answer: the responding server holds the zone locally and is not answering from cache. `ra` = Recursion Available: absent because `recursion no`. An Internet-facing authoritative server must not recurse because an open recursor is (a) a reflection/amplification weapon against third parties, and (b) a cache-poisoning target — cache and authoritative data must not share a namespace. Separating authoritative and recursive roles onto different instances is the standard hardening rule.

3. It becomes the **NSEC/NSEC3 TTL** and the authoritative denial-of-existence TTL. RFC 4034 §4 requires the TTL of an NSEC RR to be the SOA MINIMUM field, so this one number now controls how long a *proven* non-existence is cached — which is precisely what an attacker would like to be long when you add a record.

4. Because it is a **glue record**. `ns1.example.test` is *in-bailiwick* — it lives inside the zone it serves. A resolver following the delegation from `test.` needs the address to ask the child at all, but it cannot ask the child for it without already knowing it. The parent must supply it in the ADDITIONAL section. Note that glue is *not* signed by the parent: it is non-authoritative data in the parent zone, which is exactly why the DS, and not the NS/glue, is the security-relevant part of a delegation.

5. Not a regression. Validation is a *resolver* function: it means "check signatures on data I fetched from elsewhere before caching it". An authoritative server serves data it already holds and fetches nothing recursively, so there is nothing for it to validate. Setting `dnssec-validation no` on an authoritative-only instance removes a code path that would never fire. (It does not disable signing or serving RRSIGs — a very common confusion.)

### Block 2

1. `K` (key file prefix) + `example.test.` (zone/owner name) + `+013` (algorithm number, ECDSAP256SHA256, RFC 6605) + `+21237` (key tag). The **algorithm number and the key tag** both appear verbatim in every RRSIG that key generates — fields 2 and 7 of the RRSIG RDATA.

2. The low-order bit of the 16-bit flags field: `256` = 0x0100 (ZONE bit only), `257` = 0x0101 (ZONE + **SEP**, Secure Entry Point, RFC 4034 §2.1.1). The protocol does **not** force anything: SEP is a purely operational hint marking the key whose DS the parent should publish. Any key with the ZONE bit set may sign any RRset, and a single-key ("CSK") zone is entirely valid. The KSK/ZSK split is convention, not protocol.

3. Not broken. The key tag is a 16-bit checksum over the DNSKEY RDATA (RFC 4034 Appendix B), so collisions are expected — birthday bound at ~256 keys, and can even be provoked deliberately. A validator must treat the key tag as a **hint for candidate selection, not an identifier**: it tries every DNSKEY in the RRset whose owner, algorithm and tag match, and only fails after all candidates fail. This is also why "key tag collision" is a DoS consideration (KeyTrap-class attacks) — implementations cap the number of signature verifications attempted.

4. `21237` = key tag, `13` = algorithm, `2` = digest type, `4A9F…` = digest. Digest type `2` is SHA-256, introduced by **RFC 4509** (type 1 = SHA-1, deprecated; type 4 = SHA-384, RFC 6605). Digest type 2 is mandatory-to-implement and what every registry accepts today.

5. The **`.private` file is the secret** — it holds the private key. Losing only `.key` is recoverable: the public key can be regenerated from the private key (`dnssec-keyfromlabel`/`dnssec-settime` need it, and the DNSKEY RDATA is derivable). Losing `.private` means you can never sign with that key again — for a KSK that forces an emergency rollover with the parent. A **leaked** `.private` means an attacker can forge signatures your validators will accept for as long as the corresponding DNSKEY (or DS, for a KSK) remains published — a rollover plus DS withdrawal is mandatory, and cached data means the exposure outlives the change by the DNSKEY/DS TTLs.

6. (a) **Response size.** An ECDSA P-256 DNSKEY is 64 bytes and a signature 64 bytes, versus 256+ bytes each for RSA-2048. Smaller DNSKEY and RRSIG RRsets mean answers fit under the ~1232-byte EDNS payload sweet spot, avoiding IP fragmentation and TCP fallback — the leading cause of "DNSSEC works from here but not from there". (b) **Amplification.** Smaller responses mean a lower amplification factor if your server is abused as a reflector. Signing is also considerably faster, which matters when re-signing large zones. (Ed25519, algorithm 15, RFC 8080, is smaller still but has thinner deployment on the validator side.)

### Block 3

1. `A` = **type covered**; `13` = **algorithm**; `3` = **labels** (the number of labels in the original owner name, excluding the root and any leading wildcard); `300` = **original TTL** (the TTL as it appears in the zone, needed because caches decrement TTLs and the signature covers the original); `20260919114233` = **signature expiration**; `20260820104233` = **signature inception**; `34505` = **key tag**; `example.test.` = **signer's name**; then the signature itself. The **labels** field detects wildcard synthesis: if the label count in the RRSIG is fewer than the label count of the queried owner name, the answer was expanded from a wildcard, and the validator must additionally require an NSEC/NSEC3 proof that no closer match existed.

2. `-x` — "sign the DNSKEY RRset with the key-signing keys only". Without it, both keys sign the DNSKEY RRset (and by default the ZSK signs it too), producing a larger DNSKEY response for no security gain. Dropping it is not a security failure; it costs response bytes, which per Block 2 Q6 is exactly what you are trying to save.

3. Non-zero when you re-sign a zone that is **already signed** (`-f` on the signed output, or the same file in place). `dnssec-signzone` retains existing signatures that are not yet within the resign window and regenerates only the rest. The threshold is `-i cycle` (the resign interval), which defaults to one quarter of the signature validity period. This is what makes incremental re-signing of a million-record zone cheap.

4. Edit `example.test.db` (the unsigned source) and re-run `dnssec-signzone`. If you edit `example.test.db.signed` directly and reload, `named` will load it happily — it does not verify signatures at load time — and will serve an A record whose RRSIG no longer covers it. Every validating resolver on Earth then returns SERVFAIL for that name, while your own `dig @auth` looks perfect. This is exactly the failure you constructed in Exercise 4.

5. `named-checkzone` is a **syntax and zone-structure** check: parse errors, missing SOA/NS, CNAME conflicts, out-of-zone data. `dnssec-verify` is a **cryptographic completeness** check: that every authoritative RRset has a valid, in-date RRSIG from a published key, that the NSEC/NSEC3 chain is complete and correctly linked, and that the DNSKEY RRset is properly self-signed. Only `dnssec-verify` catches an unsigned RRset, a broken denial chain, or an expired signature.

6. The **parent (`test.`)** is authoritative for the DS RRset — the DS lives on the parent side of the zone cut (RFC 4035 §3.1.4.1), which is why it is signed by the **parent's ZSK**, not by any key of the child. This is the entire mechanism of the chain of trust: the parent's key vouches for a digest of the child's key. It is also why a DS query must never be answered from the child's zone data.

7. **Long validity**: a compromised or withdrawn key stays exploitable for the remaining lifetime of the signatures already published and cached; replay of old signed data is possible for longer. **Short validity**: any interruption of your re-signing automation — a failed cron job, a full disk, an HSM outage, a holiday weekend — takes the entire zone bogus when the signatures expire, and it fails *closed*, globally, with no warning. The industry compromise is roughly 14–30 days validity with re-signing at 1/4 to 1/3 of that, plus monitoring on the *minimum* remaining signature lifetime across the zone.

### Block 4

1. `no` — do not validate; accept everything, never set `ad`. `yes` — validate, using **only** trust anchors explicitly configured in `trust-anchors`/`managed-keys`/`trusted-keys` statements. `auto` — validate, using the built-in root trust anchor shipped in `bind.keys`, maintained automatically per RFC 5011. **`auto` is the BIND 9.18 default.** The lab needs `yes` because there is no real root here: with `auto`, the resolver would hold an anchor for `.` that our fake hierarchy cannot chain to, and everything would be bogus or insecure.

2. It demonstrates **data origin authentication and integrity** — the resolver proved that the data it received is not what the zone owner signed, and refused it, *without any prior relationship with the authoritative server*. It does **not** provide confidentiality (the forged answer travelled in cleartext and anyone could read it) and it does not provide availability (the result of detection is denial of service to the user — DNSSEC fails closed by design).

3. `+cd` sets the **Checking Disabled** bit in the query header, telling the recursive resolver "return the data to me even if it fails validation; I will validate myself, or I accept the risk". It is a diagnostic that isolates *where* the failure is: if `+cd` works and plain does not, the resolver's validator is rejecting the data, so the problem is signatures, not reachability. Making it permanent (e.g. `options { ... }` on stubs, or an application defaulting to CD=1) silently disables the entire protection you deployed — you keep the operational cost of DNSSEC and lose all of its benefit.

4. **`do`** (DNSSEC OK, an EDNS0 header-bit in the OPT RR) — set by the **client** in the *query*; means "send me RRSIG/NSEC/DNSKEY records". **`ad`** (Authentic Data) — set by the **validating resolver** in the *response*; means "I cryptographically verified this". **`cd`** (Checking Disabled) — set by the **client** in the *query*; means "do not withhold data from me on validation grounds". So: `do` and `cd` travel client→server, `ad` travels server→client. A stub that does not itself validate must trust both the resolver and the path to it before believing `ad` — which is what DoT addresses (Block 10).

5. (i) Is the data actually bogus or merely missing? `dig @resolver <name> +dnssec` and read the **EDE** code. (ii) Which link in the chain fails? `delv @resolver +rtrace +vtrace <name>` — it prints the fetch and verify sequence and names the failing step. (iii) Is the published zone internally consistent? `dnssec-verify -o <zone> <signedfile>` on the authoritative server. (iv) Is the parent's DS still correct for a currently published DNSKEY? `dig @parent <zone> DS` compared against `dig @child <zone> DNSKEY` — and `rndc secroots` if a local static anchor is involved. Only after those four does it make sense to look at the network (fragmentation, EDNS, TCP).

6. **EDE 6 (DNSSEC Bogus)** — signatures exist but do not verify: data was modified, a key was rolled without re-signing, or the DS/DNSKEY relationship is broken. **EDE 7 (Signature Expired)** — the RRSIG is structurally fine and cryptographically correct but the current time is outside its inception/expiration window. EDE 7 dominates in production because it has two independent triggers: a re-signing pipeline that stopped running (silent until the day of expiry), and **clock skew on the validating resolver** — an NTP failure makes perfectly good zones bogus with no fault on the zone owner's side. It is also why signature-expiry monitoring must alarm on *days remaining*, not on failure.

7. A negative trust anchor tells the resolver "treat this subtree as insecure, do not validate it" — the emergency lever when *someone else's* zone goes bogus and your users cannot work. Default lifetime is **1 hour** (`nta-lifetime`), capped at **1 week** (`max-nta-lifetime`). The risk is that for the duration, that subtree has **no DNSSEC protection at all** for every client of that resolver — you have voluntarily accepted spoofable answers for a domain, so it must be scoped as narrowly as possible, time-boxed, logged, and removed the moment the upstream is fixed.

8. `delv` performs the validation **itself, in the client process**. It sends its queries with CD=1 so the resolver hands over the raw records without filtering them, then builds and verifies the chain locally against the anchor you gave it with `-a`/`+root=`. That is why it can explain *which* step failed, and why it works even when the resolver's own validator is misconfigured. `dig` never validates anything — it only reports the `ad` bit that someone else set.

### Block 5

1. The NSEC at `mail.example.test.` (pointing to `ns1.example.test.`) proves that **no name exists in the canonical ordering between `mail` and `ns1`**, and `nothere` sorts there — so the queried name does not exist. The NSEC at the apex `example.test.` proves that **no wildcard `*.example.test` exists** that could have synthesised an answer. Both proofs are required for a signed NXDOMAIN (RFC 4035 §3.1.3.2); a validator that accepts only the first can be fooled into denying a name a wildcard would have answered.

2. The **type bit map**. It defeats *type* denial-of-existence forgery: it proves authoritatively which RR types do and do not exist at a name that *does* exist. Without it, an attacker could strip the MX or TLSA RRset from a response and claim the name has no such record — with NSEC the validator sees the bit is set and knows an answer was withheld. This is precisely what makes DANE and MX downgrade-resistant.

3. A **design consequence**, explicitly acknowledged. RFC 4033 §3.2 and RFC 4034 §? state that DNSSEC's authenticated denial of existence necessarily discloses zone contents; **RFC 5155 §1.3 and Appendix C** describe zone enumeration as the motivating problem for NSEC3. The confidentiality of zone contents was never a DNSSEC security goal. (Modern alternatives: NSEC3 to raise the cost, or **NSEC "white lies" / black lies** — online signing with minimally covering NSEC records, RFC 4470 / RFC 7129 — which eliminates enumeration entirely at the cost of requiring online keys.)

4. `1` = hash algorithm (SHA-1 — the only value ever registered); `0` = flags (bit 0 is opt-out; in NSEC3PARAM it must be 0); `0` = iterations (extra hash rounds beyond the first); `-` = salt (`-` means the empty salt). The **TTL is 0** because NSEC3PARAM is a signal to the authoritative server about which chain to use, not data intended to be cached and reused by resolvers.

5. Iterations were meant to slow dictionary attacks, but the attacker computes hashes offline on GPUs at enormous rates while the *authoritative server and every validator* pay the cost online, once per query — the defender pays far more than the attacker. Measured benefit is negligible, so **RFC 9276 §3.1** says use iterations 0. The salt was meant to prevent precomputed rainbow tables, but the zone name is already in the hash input, making each zone's table unique regardless; and rotating a salt requires re-signing the whole chain. Hence empty salt (§3.1). **BIND 9.18 treats a response with more than 150 NSEC3 iterations as *insecure*** (it stops validating rather than failing) — so excessive iterations do not make your zone more secure, they make it *less* validated.

6. Opt-out allows **insecure delegations** (delegations with an NS RRset but no DS) to be **omitted from the NSEC3 chain** — only secure delegations and names with authoritative data get NSEC3 records. It buys an enormous reduction in zone size and signing time for a zone that is mostly unsigned delegations (a TLD with millions of names, of which a few percent are signed). The cost: you can no longer prove that an insecure delegation *does not exist*, so an attacker can insert a fabricated insecure delegation into the covered gap. For a leaf zone with no delegations it buys nothing and should be `no`.

7. (a) **Predictable structure** — `www`, `mail`, `ns1`, `smtp`, `vpn`, `_dmarc`, `_domainkey` and a few thousand more cover the majority of real labels, so a dictionary attack rather than brute force is the relevant model. (b) **Short and low-entropy label space** — the hashed input is `label + zone name`, and the zone name is known, so the unknown part is a short string from a small alphabet; tools such as `nsec3walker` and `hashcat` process these at very high rates. This is why NSEC3 is best understood as raising the cost of enumeration, never as preventing it.

### Block 6

1. **`-P` Publish**: the earliest time the DNSKEY may appear in the zone. **`-A` Activate**: the time the key begins generating signatures. **`-R` Revoke**: the time the REVOKE bit is set (RFC 5011 signalling). **`-I` Inactive**: the time the key stops generating new signatures (it stays published). **`-D` Delete**: the time the DNSKEY is removed from the zone. **Publish and Activate must never coincide** for a key entering service, and **Inactive and Delete must never coincide** for a key leaving it — the gap in each case is what allows caches holding the *old* state to still find the key they need. Collapsing either gap is the classic way to break a rollover.

2. The invariant: **a key's DNSKEY must be published before the first RRSIG it makes, and must remain published after the last RRSIG it made expires from every cache.** A resolver may hold a cached RRSIG made by key X and separately fetch the DNSKEY RRset; if X is not in that RRset, validation fails. Pre-publish guarantees the union of "keys in the zone" always covers "keys referenced by any signature that could still be cached".

3. **ZSK pre-publish** waits on **your own zone's DNSKEY TTL** — everything involved is under your control and inside your zone, so simply publishing early and retiring late is sufficient. **KSK double-DS** waits on the **parent's DS TTL and the parent's publication latency** — the registry/registrar. You cannot flush the parent's caches, you often cannot predict how long the registry takes to publish, and a mistake there breaks the chain of trust for the entire zone rather than one RRset. Hence the more conservative, overlap-heavy procedure.

4. For the ZSK: the **DNSKEY RRset TTL** (how long an old view of the key set can persist) and the **maximum TTL of any signed RRset in the zone** (how long an RRSIG from the retiring key can persist), plus the signature validity remainder. For the KSK: the **parent's DS TTL**, which the child operator does not control and must query and honour. In BIND's `dnssec-policy` these appear as `dnskey-ttl`, `max-zone-ttl` and `parent-ds-ttl`.

5. Nothing breaks *immediately* in terms of signing — the key is inactive, so no new signatures need it. But the old ZSK's DNSKEY is still published (Delete is 14 days out), and RRSIGs it made are still in caches for up to `max-zone-ttl`. Deleting the `.private` file removes the ability to sign, which is not needed; the real hazard is deleting the `.key` file or removing the DNSKEY from the zone, which would break validation for every cache still holding an old RRSIG. Practically: deleting only `.private` at that moment is *survivable*, but it destroys the ability to roll back, and if the new key turns out to be faulty you now have no way to re-sign with the previous one. Treat key deletion as governed by the `Delete` timestamp, not by intuition.

6. In an algorithm rollover, **every RRset in the zone must be signed with every algorithm present in the DNSKEY RRset**, for the whole overlap period (RFC 6781 §4.1.4, and RFC 4035 §2.2 — the "signing algorithm completeness" rule). A validator that supports the new algorithm and finds it in the DNSKEY RRset will *require* a valid signature by that algorithm for every RRset; a zone that publishes the new DNSKEY but has not yet signed everything with it is bogus for those validators. Same-algorithm rollovers have no such rule because any key of the algorithm suffices. Additionally, the DS RRset in the parent must contain a DS for the new algorithm before the old is removed, and the transition order is: add new key + sign everything with both → add new DS → remove old DS → remove old signatures → remove old key.

7. The **REVOKE** bit (bit 8 of the DNSKEY flags, RFC 5011 §2.1) — a revoked KSK has flags `385` and must be self-signed while revoked, which is what proves the revocation is genuine. The **add** hold-down for a new key is **30 days** (or 1/2 the original TTL, whichever is greater); the **remove** hold-down after revocation is likewise 30 days. RFC 5011 is what makes `dnssec-validation auto` viable for the root zone without manual anchor updates — and note that `static-key` anchors, unlike `initial-key`/`initial-ds`, are *not* maintained by RFC 5011.

### Block 7

1. Edit **`example.test.db`** — the unsigned source. Never touch **`example.test.db.signed`** or **`example.test.db.signed.jnl`**; `named` owns both. The `.jnl` is the **journal**: an append-only incremental change log (the same mechanism used by dynamic update and IXFR) holding the deltas applied to the signed zone since it was last flushed to the `.signed` file. Reading a `.signed` file with a live `.jnl` present gives you a stale picture — use `rndc sync` or `rndc freeze`/`thaw` first, or just query the server. The `.jbk` is the journal-backed transaction file for the raw zone.

2. **`hidden`** — the record is not published anywhere and no cache can hold it. **`rumoured`** — it has been published, but not for long enough that every cache is guaranteed to have it; some resolvers still hold the old view. **`omnipresent`** — published for longer than the relevant TTL plus propagation delay plus safety margin, so *every* cache either has it or will fetch it. **`unretentive`** — it has been withdrawn, but caches may still hold it. Transitions are driven by: `dnskey-ttl` for the DNSKEY state, `max-zone-ttl` (+ `zone-propagation-delay`) for the zone RRSIG state, and `parent-ds-ttl` (+ `parent-propagation-delay`) for the DS state, each padded by `publish-safety` / `retire-safety`.

3. `named` cannot see the parent zone and has no way to know whether you actually submitted the DS to the registrar, whether the registrar published it, or when. If it advanced the KSK state on a guess and the DS was not really there, it would retire the old key and break the chain of trust for the whole zone. `rndc dnssec -checkds published` is the human (or automation) asserting the external fact. BIND 9.19+ can verify this itself using `parental-agents`/`checkds`, which queries the parent's name servers directly.

4. **Refresh** is when `named` starts regenerating signatures — a signature is renewed once its remaining lifetime drops below `signatures-validity − signatures-refresh`, i.e. here signatures are refreshed after 9 days of a 14-day life, leaving a 5-day buffer. If refresh is set too close to validity (say `P13D` of `P14D`), the buffer collapses: any outage of the signing process, a slow zone, or clock skew consumes the margin and signatures expire in production. BIND 9.18+ rejects a refresh interval above 90 % of validity for this reason. The buffer must exceed your worst realistic mean-time-to-repair.

5. `zone-propagation-delay` (how long until all your secondaries have the new zone), `parent-propagation-delay` (how long until the parent publishes a submitted DS) and `publish-safety`/`retire-safety` (explicit paranoia margins on each side). None can be zero with secondaries because a zone change reaches a secondary only after NOTIFY + transfer, or at worst after the SOA refresh interval — if the policy assumes instant propagation, it will retire a key while a lagging secondary is still serving signatures made by it, and that secondary's answers go bogus.

6. From the parent itself: `dig @<parent-ns> <yourzone> DS` gives the DS TTL directly; the propagation delay comes from the registry's or registrar's published SLA, or from measurement during a previous rollover. **Guessing low is the dangerous direction** — the policy will advance the KSK state machine before the parent's caches have actually converged, retiring the old DS/key while resolvers still reference it, which takes the entire zone bogus. Guessing high only makes rollovers slower.

7. CDS (Child DS) and CDNSKEY publish, *in the child zone and signed by the child*, the DS/DNSKEY the parent **should** publish. The parent (or registrar) polls for them and updates the delegation automatically, eliminating the manual out-of-band DS submission that makes KSK rollovers so painful — RFC 7344 for the mechanism, RFC 8078 for initial bootstrapping and for the delete signal. **`CDS 0 0 0 00`** (and the matching `CDNSKEY 0 3 0 0`) is the special "delete" record defined in RFC 8078 §4: it instructs the parent to **remove all DS records**, returning the child to an insecure (unsigned) delegation — the clean way to turn DNSSEC off without going bogus.

### Block 8

1. **No encryption.** TSIG (RFC 8945, obsoleting RFC 2845) computes a keyed HMAC over the DNS message plus a timestamp, using a symmetric secret shared by exactly two parties. It provides **integrity** (the message was not altered in transit) and **origin authentication** (it came from a holder of the shared secret). It provides **no confidentiality whatsoever** — the AXFR you performed in step 4 travelled in cleartext and any observer read the whole zone.

2. **What is protected**: TSIG protects a single **message/transaction** between two hosts; DNSSEC protects the **RRset data itself**, independently of how it was transported. **Key distribution**: TSIG uses a **symmetric shared secret** configured manually on both endpoints — it does not scale beyond a known set of peers; DNSSEC uses **asymmetric keys** with the chain of trust distributed through the DNS hierarchy itself, so a validator needs no prior relationship with the zone. **Scope of trust**: TSIG is **hop-by-hop** and its guarantee ends at the peer; DNSSEC is **end-to-end / object security** and survives arbitrary caching and forwarding. Consequence: TSIG secures AXFR/IXFR, NOTIFY, dynamic update and `rndc`; DNSSEC secures what a stranger's resolver eventually caches.

3. `-y` puts the **base64 secret on the command line**, which (a) is visible in the process table to every user on the host for the lifetime of the command (`ps auxww`, `/proc/<pid>/cmdline`), and (b) is written to the shell history file. `-k` passes a path; the secret is read from a file whose permissions you control (0640, owned by the key's group).

4. **BADKEY (rcode 17)** — the server does not recognise the key name presented, or that key is not permitted for this operation. **BADSIG (rcode 16)** — the key name is known but the HMAC does not verify: the secrets differ, or the algorithms differ, or the message was altered. **BADTIME (rcode 18)** — key and HMAC are fine but the timestamp in the TSIG RR is outside the fudge window (default 300 s) relative to the server's clock. All three are TSIG-specific extended rcodes carried in the **`Error` field of the TSIG RR itself** (shown by `dig` in the `;; TSIG PSEUDOSECTION:`), because the 4-bit header rcode cannot express them — the header shows `NOTAUTH` (9).

5. The timestamp plus fudge is an **anti-replay** measure: without it, an attacker who captured a valid signed request (say a dynamic update, or a NOTIFY) could replay it indefinitely, since the HMAC would remain valid forever. Bounding validity to ±fudge seconds limits the replay window. This makes **accurate time a hard dependency of your DNS infrastructure**: NTP/chrony failure on a primary or secondary breaks zone transfers with BADTIME, and (per Block 4 Q6) breaks DNSSEC validation with EDE 7. Time synchronisation is not a nicety here; it is part of the security mechanism.

6. Without it, the secondary would **know** the key but would never **use** it. The `key` clause in a `server` statement is what tells `named` "sign every request you send to this peer with this key". `include` merely defines the key; `allow-transfer { key ...; }` merely accepts it inbound. The transfer would go out unsigned and the primary would answer REFUSED. (The alternative is to attach the key at the zone level: `primaries { 127.0.0.10 key "xfr-lab"; };`.)

7. **Still worth doing.** Arguments that it no longer matters: the zone is signed so contents cannot be forged, and NSEC3 already concedes that enumeration is feasible, so AXFR reveals little that a determined walker cannot get. Arguments that it does matter, which win in practice: (i) AXFR is a **single cheap request** that yields the entire zone including records with no denial-of-existence exposure at all under NSEC3 white-lies or online signing; (ii) it is a **resource exhaustion** vector — unrestricted AXFR of a large zone is an amplification and CPU/bandwidth DoS; (iii) internal zones frequently contain host inventory, naming conventions and infrastructure topology that materially assist an attacker; (iv) defence in depth — the cost of `allow-transfer { key ...; }` is one line. It remains a baseline hardening item in every DNS benchmark.

8. On Debian/Ubuntu the default control key is **`/etc/bind/rndc.key`**, generated at install time by `rndc-confgen -a` and referenced from both `named.conf` and `/etc/bind/rndc.conf` (RHEL: `/etc/rndc.key`). `controls { inet * ... }` binds the control channel to **all interfaces**, exposing port 953 to the network; combined with a weak or leaked key, or an `allow` list of `any`, it grants full administrative control of the name server — `rndc` can reconfigure, dump the cache, add NTAs, stop the daemon and (with dynamic zones) alter data. The control channel must be bound to loopback or a management address and restricted by both `allow` and `keys`.

### Block 9

1. `3` = **certificate usage**; `1` = **selector**; `1` = **matching type**. Usage: `0` PKIX-TA (CA constraint, chain must still validate to a public root), `1` PKIX-EE (end-entity constraint, chain must still validate), `2` DANE-TA (trust anchor assertion, your own CA, no public root needed), `3` DANE-EE (end-entity assertion, no public root needed). Selector: `0` full certificate, `1` SubjectPublicKeyInfo. Matching type: `0` exact match on the selected data, `1` SHA-256 of it, `2` SHA-512 of it.

2. `verify error:num=18` is the **PKIX** verdict: the certificate chains to nothing in the trust store, because it is self-signed. `Verify return code: 0 (ok)` is the **final** verdict after DANE was applied: usage `3` (DANE-EE) *replaces* PKIX validation rather than supplementing it, so a matching TLSA record is sufficient on its own and the PKIX failure is not fatal. Had the usage been `1` (PKIX-EE), the PKIX error would have been fatal and the overall result would have been a failure regardless of the TLSA match.

3. **No.** RFC 7671 §5.1 specifies that for DANE-EE, name checks (CN/SAN) and certificate expiration are **not** performed — the TLSA record, published in a DNSSEC-signed zone under the name being connected to, *is* the binding between name and key. Practically this means a DANE-EE deployment can use a self-signed, long-lived, or "wrong-name" certificate, and — importantly — a certificate whose `notAfter` has passed will still be accepted. The corollary is that all the operational discipline moves into the DNS: your TLSA record is now the thing that must be correct, and rotating it is the risky operation.

4. DANE requires that the TLSA RRset be **DNSSEC-signed and validated by the client** (RFC 6698 §? — the security of DANE reduces entirely to the security of the DNSSEC chain). Without that, an on-path attacker simply forges the TLSA record to match their own certificate and the client happily "verifies" the attacker's key. A TLSA record in an unsigned zone, or read by a non-validating client, is worth **nothing** — it is strictly worse than no DANE, because it creates a false sense of assurance while adding an attacker-controlled trust input.

5. (i) It performs the **DNS lookup** of `_<port>._<proto>.<name> TLSA`. (ii) It requires the answer to be **DNSSEC-validated** — either by validating locally or by insisting on the `ad` bit from a trusted validating resolver over a trusted channel. `openssl s_client` with `-dane_tlsa_rrdata` does neither; you supplied the record by hand, so it only demonstrates the *matching* half of DANE, not the *trust* half. This is why `ldns-dane` in step 8, or a Postfix/`danectl` deployment, is the honest end-to-end test.

6. `_25._tcp.mx1.example.test`. For SMTP DANE (RFC 7672), the TLSA record is attached to the **MX hostname** (`mx1.example.test`), not to the mail domain (`example.test`), because that is the name the sending MTA actually connects to and the name presented in the TLS handshake. The **MX RRset itself must be DNSSEC-validated** — if the MX lookup is insecure, an attacker can redirect mail to a host of their choosing whose own TLSA records they control, defeating the whole exercise. Both the MX RRset in the mail domain and the TLSA/A records in the MX's zone must be signed.

7. (i) Generate the new key and certificate. (ii) **Publish the new TLSA record alongside the old one** (the RRset now has two records; a client accepts a match against *any* of them). (iii) Wait at least the TLSA RRset's TTL, plus propagation and a safety margin, so no cache holds an RRset containing only the old association. (iv) Deploy the new certificate on the server. (v) Wait again. (vi) Remove the old TLSA record. This is structurally identical to the **pre-publish ZSK rollover** of Exercise 6 — publish the new binding before you use it, remove the old binding only after everything that could have cached it has expired. Getting the order wrong here breaks TLS for every DANE-validating sender, which for SMTP means mail queues, not a browser warning.

8. Technically: DANE requires the client to perform **DNSSEC validation of the TLSA lookup**, and browsers deliberately do not do DNS resolution or DNSSEC validation themselves — they call the operating system's stub resolver, which typically returns no validation state the browser can trust. Adding a chain-of-trust fetch to the connection path also costs additional round trips on the critical path of every page load, and browser vendors judged the latency and the fragility (a bogus zone = a hard connection failure) unacceptable relative to Certificate Transparency + CAA, which achieve overlapping goals without a DNS dependency. SMTP has none of these constraints: MTAs are long-running daemons with their own validating resolvers, latency is irrelevant to a queued message, and the alternative (opportunistic TLS with no authentication at all) was far weaker — so DANE fills a real gap there.

### Block 10

1. **DNSSEC** — protects the *integrity and origin of the DNS data*, against anyone able to inject or modify answers anywhere between the zone and the validating resolver (including a malicious or compromised intermediate cache), **end-to-end from zone to validator**. **TSIG** — protects the *integrity and origin of a single DNS transaction*, against an off-path or on-path forger, **on one specific hop between two pre-configured peers** (primary↔secondary, admin↔`named`). **DoT/DoH** — protects the *confidentiality and integrity of the DNS conversation*, against a passive observer or on-path attacker, **on the stub↔recursive hop only**.

2. DoH (RFC 8484) uses 443 and standard HTTPS semantics so that DNS traffic is **indistinguishable from ordinary web traffic**, deliberately preventing censorship and interception by network operators — that was an explicit design goal, not an accident. The consequence for an operator is that DNS can no longer be observed, logged, filtered or redirected at the network layer: split-horizon DNS, malware sinkholing, parental controls, and DNS-based egress monitoring all fail silently when an application ships its own DoH resolver. DoT on 853 is comparatively operator-friendly — it is identifiable and blockable as a port, which is why enterprises frequently permit DoT and block DoH.

3. **Not redundant.** DoT authenticates and encrypts the channel to *your resolver*; it says nothing about where that resolver got its data. The attack it does not stop: **the resolver itself being fed forged data upstream** — a poisoned cache, a hijacked authoritative server, a BGP hijack of the authoritative infrastructure, or a compromised/malicious resolver operator. DNSSEC validation (ideally performed by the resolver, and the answer trusted via the `ad` bit over DoT; or performed by the stub itself) is what detects that. The two are orthogonal: confidentiality on the last hop, authenticity end-to-end.

4. The stub is trusting **the resolver's honesty and correctness** — that it really validated, and really is the resolver it claims to be. TLS makes the second part sound but does nothing for the first. The two configurations that restore end-to-end assurance: (i) run a **validating resolver on the endpoint itself** (`named`/`unbound`/`systemd-resolved` in validating mode on localhost), so no `ad` bit from a remote party is involved; or (ii) have the **application validate**, i.e. request with `cd`/`do` and verify the RRSIGs locally, as `delv` does. Both are cases of "do not delegate the trust decision".

5. `kdig +tls-ca[=FILE]` enables certificate-chain verification, and `+tls-hostname=NAME` enforces the expected name; `+tls-pin=BASE64` pins the SPKI. **Opportunistic** DoT (RFC 7858 §4.1) tries TLS and falls back to cleartext or accepts any certificate — it defeats passive surveillance only, and an active attacker can strip or spoof it. **Strict** DoT requires a successful, authenticated TLS handshake to a named resolver and **fails closed** if it cannot get one — that is the mode that actually resists an on-path attacker, and it is what a managed deployment should configure.

6. (i) **Port conflict and privilege**: `named` now holds 443 on that address, so a web server cannot bind the same address:port — you need separate addresses, or a TLS-terminating reverse proxy that routes by ALPN/path to `named`'s `/dns-query` endpoint. (ii) **Certificate and attack-surface coupling**: `named` is now running a TLS + HTTP/2 stack facing whatever can reach 443, which is a materially larger attack surface than a UDP/53 parser, and it needs a certificate whose renewal (ACME) must be wired into a `rndc reconfig`, or DoH clients start failing. Add to that: TCP/TLS session state means memory and file-descriptor consumption per client that UDP never had, so `tcp-clients`/`tcp-listen-queue` and the file-descriptor limit need revisiting.

### Block 11

1. **The resolver's validator is rejecting the data.** The data is reachable and syntactically fine but does not validate — bogus signatures, expired signatures, or a broken DS/DNSKEY link. Confirm and classify with the EDE code: `dig @<resolver> <name> A +dnssec` and read `; EDE: n`. Then `delv @<resolver> +vtrace <name> A` to see which step fails.

2. **The static trust anchor is stale** — the parent rolled its KSK and your manually configured anchor still names the retired key, so the chain cannot be built from your anchor. Confirm: `rndc -s <resolver> secroots -` and compare the listed key tag with `dig @<parent> <zone> DNSKEY +multiline`. Fix by updating the anchor, and prefer `initial-key`/`initial-ds` (RFC 5011-maintained) over `static-key` for anchors you do not personally rotate.

3. **Signatures expired.** Thirty days is the `dnssec-signzone` default validity — the re-signing automation stopped running (or was never scheduled) and the zone went bogus the moment the last signature aged out. Confirm: `dnssec-verify -o <zone> <signedfile>` on the authoritative server, or `dig @<auth> <zone> SOA +dnssec +multiline +norec` and read the RRSIG expiration field against the current date. Secondary suspect with identical symptoms: the *validator's* clock drifted — check `timedatectl`/`chronyc tracking`.

4. **Clock skew on the datacentre resolver, or a negative/stale trust anchor there** — the difference is in the validator, not the zone, because `delv` proved the zone itself is fine. Confirm: `chronyc tracking` (or `timedatectl`) on the failing resolver, then `rndc -s <r> secroots -` and `rndc -s <r> nta -dump`. A third candidate, if both are clean: that resolver cannot retrieve the DNSKEY/DS at all — see item 5.

5. **EDNS/UDP fragmentation or a middlebox dropping large DNS responses.** DNSKEY RRsets during a rollover are the largest responses a zone produces; paths that drop fragments or block DNS over TCP make validation fail from some networks and not others. Confirm: `dig @<auth> <zone> DNSKEY +dnssec +bufsize=1232 +ignore` versus `+bufsize=4096`, and `dig +tcp` — if 1232 and TCP work and 4096 does not, it is path MTU/fragmentation. Fix: cap `edns-udp-size`/`max-udp-size` at 1232, ensure TCP/53 is permitted end to end, and prefer ECDSA to shrink the responses in the first place (Block 2 Q6).

6. **The zone was signed with an NSEC3 iteration count above what BIND will accept**, per RFC 9276 and BIND's 150-iteration validation ceiling. Confirm: `dig @<auth> <zone> NSEC3PARAM +short` — the third field is the iteration count. Fix: re-sign with `-H 0` (or `nsec3param iterations 0` under `dnssec-policy`). Note that the *validating* side treats excessive iterations as insecure, so the symptom on the client is a silently missing `ad` flag rather than SERVFAIL.

7. **The DS is missing or does not match** — the parent has an NS delegation but no DS (or a DS for a key the child no longer publishes), so the validator correctly concludes the child is an unsigned delegation and stops validating. Confirm: `dig @<parent-ns> <child> DS +dnssec` compared against `dig @<child-ns> <child> DNSKEY +multiline`, checking that a published KSK's tag and digest match a DS. Fix: submit the DS via the registrar (or `rndc dnssec -checkds published` once it is live). "Insecure" is the correct, safe outcome here — but it means DNSSEC is doing nothing for that zone.

8. **TSIG failure on the transfer** — one of BADKEY, BADSIG or BADTIME. Confirm by reproducing the transfer manually and reading the TSIG pseudosection: `dig @<primary> <zone> AXFR -k <keyfile>`. Then narrow it: BADKEY → key name not in the primary's `allow-transfer` or not defined; BADSIG → the `secret` or `algorithm` differs between the two `named.conf` files (a classic copy-paste truncation of the base64); BADTIME → clock skew above the 300 s fudge, check `chronyc tracking` on both ends. The primary's log will name the key and the failure reason at `category security`.

</details>

---

## Sources

- LPI, *Exam 303-300 Objectives (LPIC-3 Security, version 3.0)* — https://www.lpi.org/our-certifications/exam-303-objectives/
- ISC, *BIND 9 Administrator Reference Manual*, chapters on `named.conf`, `dnssec-policy`, `tls`/`http`, and the `controls` statement — https://bind9.readthedocs.io/en/v9.18/reference.html
- ISC, *BIND 9 DNSSEC Guide* (manual signing, `dnssec-policy`, rollovers, troubleshooting) — https://bind9.readthedocs.io/en/v9.18/dnssec-guide.html
- RFC 4033 / 4034 / 4035 — *DNS Security Introduction and Requirements*, *Resource Records for the DNS Security Extensions*, *Protocol Modifications for the DNS Security Extensions* — https://www.rfc-editor.org/rfc/rfc4033 · https://www.rfc-editor.org/rfc/rfc4034 · https://www.rfc-editor.org/rfc/rfc4035
- RFC 4509 — *Use of SHA-256 in DNSSEC Delegation Signer (DS) Resource Records* — https://www.rfc-editor.org/rfc/rfc4509
- RFC 5011 — *Automated Updates of DNS Security (DNSSEC) Trust Anchors* — https://www.rfc-editor.org/rfc/rfc5011
- RFC 5155 — *DNS Security (DNSSEC) Hashed Authenticated Denial of Existence* — https://www.rfc-editor.org/rfc/rfc5155
- RFC 9276 — *Guidance for NSEC3 Parameter Settings* (BCP 236) — https://www.rfc-editor.org/rfc/rfc9276
- RFC 6781 — *DNSSEC Operational Practices, Version 2* — https://www.rfc-editor.org/rfc/rfc6781
- RFC 6605 / RFC 8080 — *Elliptic Curve Digital Signature Algorithm (DSA) for DNSSEC* / *Edwards-Curve Digital Security Algorithm (EdDSA) for DNSSEC* — https://www.rfc-editor.org/rfc/rfc6605 · https://www.rfc-editor.org/rfc/rfc8080
- RFC 7344 / RFC 8078 — *Automating DNSSEC Delegation Trust Maintenance* / *Managing DS Records from the Parent via CDS/CDNSKEY* — https://www.rfc-editor.org/rfc/rfc7344 · https://www.rfc-editor.org/rfc/rfc8078
- RFC 8945 — *Secret Key Transaction Authentication for DNS (TSIG)* — https://www.rfc-editor.org/rfc/rfc8945
- RFC 6698 / RFC 7671 / RFC 7672 — *DANE TLSA* / *DANE Operational Guidance* / *SMTP Security via Opportunistic DANE TLS* — https://www.rfc-editor.org/rfc/rfc6698 · https://www.rfc-editor.org/rfc/rfc7671 · https://www.rfc-editor.org/rfc/rfc7672
- RFC 4255 — *Using DNS to Securely Publish Secure Shell Key Fingerprints (SSHFP)* — https://www.rfc-editor.org/rfc/rfc4255
- RFC 7858 / RFC 8484 — *DNS over TLS* / *DNS Queries over HTTPS* — https://www.rfc-editor.org/rfc/rfc7858 · https://www.rfc-editor.org/rfc/rfc8484
- RFC 8914 — *Extended DNS Errors* — https://www.rfc-editor.org/rfc/rfc8914
- RFC 6761 — *Special-Use Domain Names* (reservation of `.test`) — https://www.rfc-editor.org/rfc/rfc6761
- OpenSSL Project, `openssl-s_client(1)` — DANE options (`-dane_tlsa_domain`, `-dane_tlsa_rrdata`) — https://docs.openssl.org/master/man1/openssl-s_client/
- CZ.NIC, *Knot DNS utilities — `kdig`* (`+tls`, `+https`) — https://www.knot-dns.cz/docs/latest/singlehtml/index.html#kdig
- Sandia National Laboratories, *DNSViz — a DNS visualization tool* — https://dnsviz.net/