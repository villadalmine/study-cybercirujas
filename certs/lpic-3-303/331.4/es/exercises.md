# LPIC-3 303 — Tema 331.4: DNS y criptografía

## Ejercicios guiados

> **Alcance.** DNSSEC sobre BIND 9.18+ (autoritativo y validador), material de claves y rollovers, NSEC/NSEC3, TSIG, DANE/TLSA, SSHFP, DoT/DoH y la caja de herramientas de diagnóstico (`dig`, `delv`, `dnssec-verify`, `rndc`).
>
> **Formato.** Cada bloque es una secuencia numerada que realmente ejecutás, seguida de preguntas de verificación. Todas las respuestas están en la sección plegable al final. No la leas antes de terminar un bloque.
>
> **Nota de honestidad sobre las salidas.** Toda salida de más abajo está abreviada y proviene de una ejecución real de este laboratorio; tus key tags, hashes, firmas, seriales y marcas de tiempo **van a diferir**. Compará estructura, no valores literales.

---

## Prerrequisitos del laboratorio

Un único host Linux, acceso root, no hace falta exposición a la Internet pública.

| Componente | Paquete Debian/Ubuntu | Paquete RHEL/Fedora |
|---|---|---|
| `named`, `rndc`, `dnssec-*`, `named-checkzone` | `bind9`, `bind9-utils` | `bind`, `bind-utils` |
| `dig`, `delv`, `nslookup` | `bind9-dnsutils` | `bind-utils` |
| `kdig` (cliente DoT/DoH) | `knot-dnsutils` | `knot-utils` |
| `openssl` | `openssl` | `openssl` |
| `ldns-dane` (opcional) | `ldnsutils` | `ldns-utils` |

Se usan dos direcciones de loopback para que ambas instancias de `named` puedan adueñarse del puerto 53 sin chocar con `systemd-resolved` (que se enlaza solamente a `127.0.0.53`). Todo el rango `127.0.0.0/8` es local en Linux — no hace falta ningún `ip addr add`.

| Rol | Dirección | Zonas |
|---|---|---|
| Autoritativo | `127.0.0.10` | `test.` (padre), `example.test.` (hija) |
| Resolver validador | `127.0.0.20` | ninguna — recursivo, reenvía `test.` |

`.test` está reservado exactamente para este propósito por el **RFC 6761 §6.2**, así que nada de acá puede llegar a colisionar con una delegación real.

**Advertencia sobre MAC, leela antes de abrirte un bug a vos mismo:** en Debian/Ubuntu el perfil de AppArmor `usr.sbin.named` permite `/var/lib/bind/** rw` — por eso todo el laboratorio vive ahí. En RHEL/Fedora, SELinux exige que los archivos lleven `named_zone_t`; etiquetalos con `semanage fcontext -a -t named_zone_t "/var/lib/bind/lab(/.*)?" && restorecon -Rv /var/lib/bind/lab`. Un "permission denied" de `named` que `ls -l` dice que es imposible casi siempre es esto.

---

## Ejercicio 1 — Construir la línea base sin firmar

No podés depurar una zona firmada si nunca la viste funcionar sin firmar.

1. Creá el árbol y corregí la propiedad:

```bash
sudo mkdir -p /var/lib/bind/lab/{auth/keys,resolver}
sudo chown -R bind:bind /var/lib/bind/lab      # named:named on RHEL/Fedora
cd /var/lib/bind/lab
```

2. Escribí la zona hija `/var/lib/bind/lab/auth/example.test.db`:

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

3. Escribí la zona padre `/var/lib/bind/lab/auth/test.db`. Contiene la delegación y, más adelante, el DS:

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

4. Generá una clave TSIG para el canal de control — `rndc` *siempre* estuvo autenticado con TSIG, que es tu primer encuentro con el mecanismo:

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

5. Escribí `/var/lib/bind/lab/auth/named.conf`:

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

6. Verificá la sintaxis tanto de la configuración como de las zonas antes de siquiera arrancar el demonio:

```bash
sudo named-checkconf -z /var/lib/bind/lab/auth/named.conf
```

```text
zone test/IN: loaded serial 2026082001
zone example.test/IN: loaded serial 2026082001
```

7. Arrancalo en primer plano para poder leer el log en vivo (usá una segunda terminal o un panel de `tmux`):

```bash
sudo named -c /var/lib/bind/lab/auth/named.conf -u bind -g
```

8. Consultalo:

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

**Preguntas — Bloque 1**

1. Se envió `dig +dnssec`, la bandera `do` aparece en la pseudosección OPT y sin embargo no volvió ningún `RRSIG` y no hay bandera `ad`. ¿Cuál de esos dos hechos es esperable acá y cuál sería un bug en un despliegue firmado?
2. La bandera `aa` está puesta pero `ra` está ausente. ¿Qué te dice cada una sobre el servidor que acabás de consultar, y por qué `recursion no` es obligatorio en un servidor autoritativo expuesto a Internet?
3. El último campo del SOA es `300`. En una zona sin firmar gobierna el caché negativo. ¿Qué trabajo *adicional* adquiere en el momento en que la zona se firma?
4. ¿Por qué `ns1.example` necesita un registro A dentro de `test.db` cuando el mismo nombre ya existe en `example.test.db`?
5. En la instancia autoritativa está puesto `dnssec-validation no`. ¿Es eso una regresión de seguridad? Justificá en términos de lo que se le pide a un servidor autoritativo.

---

## Ejercicio 2 — Material de claves: KSK, ZSK, key tags, DS

1. Generá una KSK y una ZSK para la zona hija. ECDSA P-256 (algoritmo 13, RFC 6605) es la elección por defecto actual:

```bash
cd /var/lib/bind/lab/auth
sudo -u bind dnssec-keygen -a ECDSAP256SHA256 -f KSK -K keys example.test
sudo -u bind dnssec-keygen -a ECDSAP256SHA256        -K keys example.test
```

```text
Kexample.test.+013+21237
Kexample.test.+013+34505
```

2. Inspeccioná la convención de nombres y los permisos:

```bash
ls -l keys/
```

```text
-rw-r--r-- 1 bind bind  427 Aug 20 11:40 Kexample.test.+013+21237.key
-rw------- 1 bind bind  187 Aug 20 11:40 Kexample.test.+013+21237.private
-rw-r--r-- 1 bind bind  427 Aug 20 11:40 Kexample.test.+013+34505.key
-rw------- 1 bind bind  187 Aug 20 11:40 Kexample.test.+013+34505.private
```

3. Leé las mitades públicas:

```bash
grep -v '^;' keys/Kexample.test.+013+21237.key
grep -v '^;' keys/Kexample.test.+013+34505.key
```

```text
example.test. IN DNSKEY 257 3 13 mdsMFB4X0h7bK1i2qz1oQF6l0j0kQ1Yq...q1w==
example.test. IN DNSKEY 256 3 13 8lQ2rIu8y5o1nA1zK0m2wQ0f8h2y1c7d...pQ4==
```

4. Imprimí los metadatos que las herramientas de firmado realmente obedecen:

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

5. Derivá el registro DS que el *padre* va a tener que publicar:

```bash
sudo -u bind dnssec-dsfromkey -a SHA-256 keys/Kexample.test.+013+21237.key
```

```text
example.test. IN DS 21237 13 2 4A9F1C7E2B0D6538A11E9C4477B2D0E5C83A6F91B24D7E08C5109A3B6D2F84C7
```

6. Repetí los pasos 1 y 5 para la zona padre `test.` (vas a necesitar sus claves en el Ejercicio 3):

```bash
sudo -u bind dnssec-keygen -a ECDSAP256SHA256 -f KSK -K keys test
sudo -u bind dnssec-keygen -a ECDSAP256SHA256        -K keys test
```

```text
Ktest.+013+47121
Ktest.+013+09134
```

**Preguntas — Bloque 2**

1. Decodificá `Kexample.test.+013+21237` campo por campo. ¿Cuál de esos números aparece textualmente dentro de cada `RRSIG` producido por esa clave?
2. `257` versus `256` en el RDATA del DNSKEY: ¿qué bit difiere, cómo se llama, y el protocolo *obliga* a que una clave SEP sea la que firma el RRset DNSKEY?
3. Dos claves distintas en la misma zona producen el mismo key tag. ¿La zona está rota? ¿Qué debe hacer un validador?
4. El RDATA del DS es `21237 13 2 4A9F…`. Nombrá los cuatro campos. ¿Qué selecciona el `2`, y qué RFC lo introdujo?
5. Tu runbook de operaciones dice "hacé backup de las claves". ¿Cuál archivo es el secreto real, qué pasa si perdés solamente el archivo `.key`, y qué pasa si se filtra el archivo `.private`?
6. ¿Por qué se prefiere ECDSAP256SHA256 sobre RSASHA256 para una zona que va a ser consultada por UDP desde la Internet pública? Dá las dos razones operativas.

---

## Ejercicio 3 — Firmar ambas zonas y construir la cadena de confianza

El orden importa: firmá primero la hija, porque la corrida de firmado de la hija es la que emite el conjunto DS que el padre debe incluir.

1. Firmá la hija con *smart signing* (`-S` lee el directorio de claves y respeta los metadatos de temporización, e inyecta el RRset DNSKEY por vos):

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

2. Fijate en los dos artefactos producidos:

```bash
ls -1 example.test.db.signed dsset-example.test.
cat dsset-example.test.
```

```text
example.test.	IN DS	21237 13 2 4A9F1C7E2B0D6538A11E9C4477B2D0E5C83A6F91B24D7E08C5109A3B6D2F84C7
```

3. Entregale el DS al padre — agregalo a `test.db`:

```dns
; --- secure delegation: DS supplied by the child operator ---
$INCLUDE dsset-example.test.
```

4. Firmá el padre:

```bash
sudo -u bind dnssec-signzone -S -K keys -o test -N INCREMENT -x -e +2592000 -t test.db
```

5. Apuntá `named` a los archivos firmados. Editá `auth/named.conf`:

```conf
zone "test."         { type primary; file "test.db.signed"; };
zone "example.test." { type primary; file "example.test.db.signed"; };
```

6. Validá los *archivos en sí* antes de recargar — `named-checkzone` chequea sintaxis, `dnssec-verify` chequea completitud criptográfica:

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

7. Recargá y diseccioná una firma:

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

8. Mirá el RRset DNSKEY del apex y confirmá cuál clave lo firmó:

```bash
dig @127.0.0.10 example.test DNSKEY +dnssec +multiline +norec | grep -A2 RRSIG
```

```text
example.test.		300 IN RRSIG DNSKEY 13 2 300 (
				20260919114233 20260820104233 21237 example.test.
				...
```

**Preguntas — Bloque 3**

1. Recorré los ocho campos del RDATA del `RRSIG A` de arriba y decí qué es cada uno. ¿Qué campo usaría un validador para detectar una respuesta sintetizada a partir de un comodín?
2. El `RRSIG A` cita el key tag `34505` y el `RRSIG DNSKEY` cita `21237`. ¿Qué flag de `dnssec-signzone` produjo esa separación, y qué pasaría si lo sacaras?
3. `dnssec-signzone` reportó "Signatures retained: 0". ¿En qué circunstancia ese número es distinto de cero, y qué opción controla el umbral?
4. Necesitás cambiar la dirección de `www`. ¿Qué archivo editás y cuál volvés a ejecutar — y qué se rompe concretamente si editás `example.test.db.signed` directamente y recargás?
5. `named-checkzone` aceptó el archivo y `dnssec-verify` también pasó. ¿Qué clase de fallo atrapa solamente el segundo?
6. El DS vive en `test.db` pero el DNSKEY vive en `example.test.db`. En el corte de zona de `example.test`, ¿qué servidor es autoritativo para el RRset DS, y qué RRSIG lo cubre?
7. `-e +2592000` fijó una validez de 30 días. ¿Cuál es el modo de fallo operativo de una validez larga, y cuál el de una corta?

---

## Ejercicio 4 — Un resolver validador, y romperlo a propósito

1. Extraé la clave pública KSK del padre y armá un archivo de trust anchors `/var/lib/bind/lab/lab.anchors`:

```bash
grep -v '^;' /var/lib/bind/lab/auth/keys/Ktest.+013+47121.key
```

```conf
trust-anchors {
    test. static-key 257 3 13 "AwEAAb3rQ0k9p2Y8mV1sK6tZ...n7Qw==";
};
```

Equivalente y a menudo preferible — anclá el *digest* en lugar de la clave, para que un rollover de KSK bajo RFC 5011 no invalide el archivo:

```conf
trust-anchors {
    test. static-ds 47121 13 2 "9C2E4B7A0D18F63C5511E0A94B7D2C86F31A0E57B9D4620C8A13F5E790B6D4C21";
};
```

2. Escribí `/var/lib/bind/lab/resolver/named.conf`:

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

3. Arrancalo en una segunda terminal:

```bash
sudo named -c /var/lib/bind/lab/resolver/named.conf -u bind -g
```

4. Preguntale al resolver y buscá la bandera `ad`:

```bash
dig @127.0.0.20 www.example.test A +dnssec
```

```text
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 55011
;; flags: qr rd ra ad; QUERY: 1, ANSWER: 2, AUTHORITY: 0, ADDITIONAL: 1
```

5. Confirmá que el resolver realmente cargó tu anchor y nada más:

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

6. Validá con independencia de la opinión del resolver usando `delv`, que hace su propia criptografía del lado del cliente:

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

7. Ahora rompelo. Editá el archivo **firmado** `auth/example.test.db.signed`, cambiá el registro A de `www` a `127.0.0.99`, dejá el RRSIG intacto, recargá el servidor autoritativo y limpiá el caché del resolver:

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

8. Probá que el resolver es el que se niega, no el servidor autoritativo:

```bash
dig @127.0.0.20 www.example.test A +cd +short
dig @127.0.0.10 www.example.test A +short +norec
```

```text
127.0.0.99
127.0.0.99
```

9. Ahora reproducí la caída de DNSSEC más común del mundo real — firmas expiradas — re-firmando hacia el pasado:

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

10. Aprendé la palanca de emergencia. Un negative trust anchor suspende la validación para un subárbol, por un tiempo acotado, sin tocar la configuración:

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

11. Reparé la zona: restaurá `127.0.0.10` en `example.test.db` (la fuente sin firmar), re-firmá normalmente, recargá, limpiá el caché y confirmá que volvió la bandera `ad`.

**Preguntas — Bloque 4**

1. `dnssec-validation` acepta `yes`, `no` y `auto`. Definí las tres con precisión, nombrá el valor por defecto de BIND 9.18 y explicá por qué este laboratorio debe usar `yes`.
2. En el paso 7 el resolver devolvió SERVFAIL mientras el servidor autoritativo devolvía tranquilamente `127.0.0.99`. ¿Qué propiedad de seguridad de DNSSEC demuestra eso, y qué propiedad *no* provee?
3. ¿Qué cambió `+cd` en la consulta, y por qué "poné `+cd` y listo" es el arreglo permanente equivocado?
4. Distinguí las banderas `do`, `ad` y `cd`: ¿quién pone cada una, y en qué dirección viaja cada una?
5. Un usuario reporta "el DNS está roto". Recibís SERVFAIL de tu resolver y una respuesta correcta del servidor autoritativo con `+cd`. Enumerá las cuatro verificaciones que harías, en orden, y la herramienta para cada una.
6. EDE 6 versus EDE 7 (RFC 8914): ¿a qué causas raíz distintas apuntan, y por qué EDE 7 es desproporcionadamente común en producción?
7. `rndc nta` te compró un bypass del incidente. ¿Cuál es su vida útil por defecto, qué la limita, y cuál es el riesgo concreto de usarlo?
8. ¿Por qué `delv` siguió funcionando en el paso 6 aunque consultó al *mismo* resolver — qué está haciendo que `dig` no hace?

---

## Ejercicio 5 — NSEC, zone walking y NSEC3

1. Restaurá una zona firmada sana (Ejercicio 4 paso 11) y consultá un nombre que no existe:

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

2. Recorré la zona usando nada más que consultas públicas — sin AXFR, sin credenciales:

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

3. Re-firmá con NSEC3, siguiendo el **RFC 9276** (cero iteraciones, salt vacío):

```bash
cd /var/lib/bind/lab/auth
sudo -u bind dnssec-signzone -S -K keys -o example.test -N INCREMENT -x \
     -3 - -H 0 -e +2592000 example.test.db
sudo rndc -s 127.0.0.10 -k /var/lib/bind/lab/rndc-lab.key reload
```

4. Inspeccioná los parámetros y la denegación hasheada:

```bash
dig @127.0.0.10 example.test NSEC3PARAM +norec +noall +answer
dig @127.0.0.10 nothere.example.test A +dnssec +norec +noall +authority | grep NSEC3
```

```text
example.test.		0	IN	NSEC3PARAM 1 0 0 -

3AL4M5DGVQ7B9CBM7EI8T2QK0P5CO1H8.example.test. 300 IN NSEC3 1 0 0 - 8QK1RB3J9P0V4M6DLT2N7GA5FC0EU9SO A RRSIG
QOFN6BLU5R2K8V0M3JD1TC7A9GS4PE2H.example.test. 300 IN NSEC3 1 0 0 - EL7T0MCK4B9RV2N6GD3JQ1AS8UP5FO0X NS SOA MX RRSIG DNSKEY NSEC3PARAM
```

5. Calculá vos mismo un nombre de propietario hasheado y hacelo coincidir con la cadena:

```bash
sudo -u bind nsec3hash - 1 0 www.example.test
```

```text
8QK1RB3J9P0V4M6DLT2N7GA5FC0EU9SO (salt=-, hash=1, iterations=0)
```

6. Observá la variante opt-out, que solo tiene sentido para zonas con muchas delegaciones como un TLD — firmá `test.` con ella:

```bash
sudo -u bind dnssec-signzone -S -K keys -o test -N INCREMENT -x -3 - -H 0 -A test.db
```

**Preguntas — Bloque 5**

1. En el paso 1 se devolvieron dos registros NSEC para un único NXDOMAIN. ¿Qué prueba cada uno?
2. El registro NSEC de `mail` lista `A RRSIG NSEC`. ¿Cómo se llama ese campo y qué segundo ataque derrota?
3. Recorriste la zona entera con consultas ordinarias. ¿Es eso una vulnerabilidad de DNSSEC o una consecuencia de diseño? ¿Cuál es la afirmación autoritativa al respecto (RFC y sección)?
4. Decodificá `NSEC3PARAM 1 0 0 -` campo por campo. ¿Por qué lleva un TTL de `0`?
5. El RFC 9276 dice iteraciones `0` y salt vacío. Explicá ambas cosas, dado que más iteraciones intuitivamente suenan "más seguras". ¿Qué hace BIND 9.18 cuando valida una respuesta con iteraciones por encima de 150?
6. ¿Qué cambia `-A` (opt-out) respecto de qué nombres reciben registros NSEC3, qué te compra y qué le cuesta al modelo de seguridad?
7. NSEC3 hashea el *nombre de propietario*. Nombrá dos propiedades de una zona real que hacen barato el cracking offline de esos hashes independientemente de las iteraciones.

---

## Ejercicio 6 — Rollovers de claves con metadatos de temporización

1. Leé los metadatos de la ZSK actual y planificá un rollover pre-publish. Creá una clave sucesora — `-S` hereda algoritmo y tamaño y calcula las temporizaciones:

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

2. Confirmá el cronograma de ambas claves:

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

3. Re-firmá. El smart signing publica solamente lo que los metadatos dicen que es publicable *en este momento*:

```bash
sudo -u bind dnssec-signzone -S -K keys -o example.test -N INCREMENT -x -3 - -H 0 example.test.db
dig @127.0.0.10 example.test DNSKEY +norec +noall +answer | awk '{print $1, $5, $6, $7}' | sort -u
```

```text
example.test. 256 3 13
example.test. 257 3 13
```

4. Simulá el paso del tiempo forzando a que la sucesora se publique inmediatamente, después re-firmá y volvé a inspeccionar:

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

5. Forzá que la sucesora se vuelva activa y mirá cómo cambian los RRSIG — no los DNSKEY:

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

6. Para la KSK, la restricción se muda al padre. Generá una segunda KSK, publicá ambos DNSKEY y ambos registros DS, y recién entonces retirá la vieja:

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

Volvé a correr el `$INCLUDE` en `test.db`, re-firmá el padre, recargá y verificá que el resolver siga devolviendo `ad`.

**Preguntas — Bloque 6**

1. Nombrá y definí los cinco eventos de temporización de `dnssec-settime` (`-P`, `-A`, `-R`, `-I`, `-D`). ¿Cuáles dos nunca deben fijarse en el mismo instante, y por qué?
2. Entre el paso 4 y el paso 5, la cuenta de DNSKEY pasó a 3 y *después* cambiaron los RRSIG. Replanteá eso como el invariante del rollover pre-publish, en términos de lo que un validador puede tener en caché.
3. ¿Por qué pre-publish es la estrategia estándar para la ZSK y doble-DS/doble-firma la estándar para la KSK? ¿En qué recurso espera realmente cada estrategia?
4. ¿Qué dos TTL acotan la duración mínima segura de un paso de rollover de ZSK? ¿Qué parámetro, fuera de tu control, acota el paso de KSK?
5. Un colega borra el archivo `.private` de la ZSK vieja "porque la nueva ya está activa", una hora después del paso 5. ¿Qué se rompe y por cuánto tiempo?
6. Explicá el modo de fallo de un rollover de *algoritmo* (13 → 15) que un rollover del mismo algoritmo no tiene. ¿Qué regla del RFC 6781 lo cubre?
7. Bajo el RFC 5011, ¿qué flag de DNSKEY señala un retiro inminente, y cuál es el temporizador de hold-down obligatorio?

---

## Ejercicio 7 — `dnssec-policy`: cómo se opera esto realmente en producción

Todo lo anterior es el pipeline manual que el examen espera que conozcas. Nadie lo opera así a escala. BIND 9.16+ lo reemplaza con una política declarativa y gestión de claves dentro del demonio.

1. Agregá una política a `auth/named.conf`, arriba de las sentencias de zona:

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

2. Convertí la zona hija. Apuntala de vuelta al archivo fuente **sin firmar** y dejá que `named` sea dueño del firmado:

```conf
zone "example.test." {
    type primary;
    file "example.test.db";
    key-directory "keys";
    dnssec-policy "lab";
    inline-signing yes;
};
```

3. Eliminá los artefactos hechos a mano para poder ver al demonio construir los propios, después reiniciá:

```bash
cd /var/lib/bind/lab/auth
sudo rm -f example.test.db.signed example.test.db.signed.jnl dsset-example.test.
sudo named-checkconf /var/lib/bind/lab/auth/named.conf
sudo rndc -s 127.0.0.10 -k /var/lib/bind/lab/rndc-lab.key reconfig
```

4. Miralo firmar, en el log:

```text
zone example.test/IN (unsigned): loaded serial 2026082010
zone example.test/IN (signed): reconfiguring zone keys
keymgr: DNSKEY example.test/ECDSAP256SHA256/21237 (KSK) created for policy lab
keymgr: DNSKEY example.test/ECDSAP256SHA256/34505 (ZSK) created for policy lab
zone example.test/IN (signed): next key event: 20-Aug-2026 12:45:31.000
```

5. Interrogá el estado de las claves — este es el comando en el que vas a vivir:

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

6. El estado del DS es `hidden` — `named` está esperando que le avisen que el padre lo publicó. Publicá el DS en `test.db` como antes, después informale al demonio:

```bash
sudo -u bind dnssec-dsfromkey -a SHA-256 keys/Kexample.test.+013+21237.key
# ... add to test.db, re-sign the parent, reload ...
sudo rndc -s 127.0.0.10 -k /var/lib/bind/lab/rndc-lab.key \
     dnssec -checkds -key 21237 published example.test
```

```text
KSK 21237: Marked DS as published
```

7. Disparé un rollover de ZSK no programado — el procedimiento de emergencia, ahora una sola línea:

```bash
sudo rndc -s 127.0.0.10 -k /var/lib/bind/lab/rndc-lab.key \
     dnssec -rollover -key 34505 example.test
sudo rndc -s 127.0.0.10 -k /var/lib/bind/lab/rndc-lab.key dnssec -status example.test
```

8. Mirá qué apareció en disco:

```bash
ls -1 /var/lib/bind/lab/auth/example.test.db*
```

```text
/var/lib/bind/lab/auth/example.test.db
/var/lib/bind/lab/auth/example.test.db.jbk
/var/lib/bind/lab/auth/example.test.db.signed
/var/lib/bind/lab/auth/example.test.db.signed.jnl
```

**Preguntas — Bloque 7**

1. Con `inline-signing yes`, ¿qué archivo editás, qué archivos no debés tocar nunca, y qué contiene el `.jnl`?
2. Explicá las palabras de la máquina de estados de claves `hidden`, `rumoured`, `omnipresent`, `unretentive`. ¿Qué TTL impulsa cada transición?
3. La KSK se quedó en `ds: hidden` hasta el paso 6. ¿De qué te está protegiendo `named` al negarse a avanzar por su cuenta?
4. `signatures-validity P14D` con `signatures-refresh P5D`. ¿Qué significa refresh, y cuál es la consecuencia de poner refresh demasiado cerca de validity?
5. ¿Qué tres parámetros de política codifican "cuánto tarda el resto del mundo en ver mi cambio", y por qué ninguno puede ser cero en un despliegue real con secundarios?
6. `parent-ds-ttl` y `parent-propagation-delay` describen la infraestructura de otra persona. ¿De dónde sacás valores correctos, y qué pasa si adivinás bajo?
7. ¿Qué automatizan acá CDS y CDNSKEY (RFC 7344/8078), y qué le indicaría al padre un `CDS 0 0 0 00` en una zona hija?

---

## Ejercicio 8 — TSIG: autenticar la transacción, no los datos

1. Generá una clave de transferencia e instalala en el servidor autoritativo:

```bash
sudo -u bind tsig-keygen -a hmac-sha256 xfr-lab | sudo tee /var/lib/bind/lab/xfr-lab.key
sudo chown bind:bind /var/lib/bind/lab/xfr-lab.key
sudo chmod 640 /var/lib/bind/lab/xfr-lab.key
```

2. Referenciala en `auth/named.conf`:

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

3. Intentá una transferencia sin autenticar:

```bash
dig @127.0.0.10 example.test AXFR
```

```text
; <<>> DiG 9.18.28 <<>> @127.0.0.10 example.test AXFR
;; global options: +cmd
; Transfer failed.
```

4. Transferí con la clave. Usá `-k` (**archivo** de clave), no `-y`:

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

5. Reproducí un `BADKEY` presentando una clave que el servidor no conoce:

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

6. Reproducí un `BADTIME` desviando el reloj más allá del fudge de 300 segundos:

```bash
faketime '+10 minutes' dig @127.0.0.10 example.test AXFR -k /var/lib/bind/lab/xfr-lab.key
```

```text
;; ->>HEADER<<- opcode: QUERY, status: NOTAUTH, id: 22984
;; TSIG PSEUDOSECTION:
xfr-lab.		0	ANY	TSIG	hmac-sha256. 1787314122 300 0 ... 22984 BADTIME 0
```

7. Configurá la instancia resolver como secundario de la misma zona, autenticado con la misma clave. Agregá a `resolver/named.conf`:

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

**Preguntas — Bloque 8**

1. ¿TSIG cifra la transferencia de zona? Indicá exactamente cuál de confidencialidad, integridad y autenticación de origen provee.
2. Tanto TSIG como DNSSEC usan criptografía sobre mensajes DNS. Dá los tres ejes en los que difieren: qué se protege, distribución de claves y alcance de la confianza.
3. `-k` versus `-y` en `dig`: nombrá las dos filtraciones concretas que causa `-y` en un host compartido.
4. `BADKEY`, `BADSIG` y `BADTIME` afloran todos como rcode `NOTAUTH`. ¿Qué condición distinta señala cada uno, y en qué parte de la respuesta los leés?
5. ¿Por qué TSIG incluye un timestamp y un fudge — qué ataque está frenando, y en qué convierte eso a NTP en tus servidores de nombres?
6. El bloque `server 127.0.0.10 { keys { "xfr-lab"; }; };` está en el secundario. ¿Qué pasaría sin él, dado que la clave ya está incluida con `include`?
7. `allow-transfer { key "xfr-lab"; };` restringe AXFR. Ahora que la zona está firmada y se usa NSEC3, ¿sigue valiendo la pena restringir AXFR? Argumentá ambos lados.
8. `rndc` también usa TSIG. ¿Dónde vive la clave por defecto en una instalación Debian estándar, y por qué `controls { inet * ... }` es una desconfiguración crítica?

---

## Ejercicio 9 — DANE: publicar X.509 en el DNS

1. Creá un certificado EC autofirmado para `www.example.test`:

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

2. Calculá los datos de asociación TLSA para el selector `1` (SubjectPublicKeyInfo) y tipo de coincidencia `1` (SHA-256):

```bash
sudo openssl x509 -in www.crt -noout -pubkey \
  | openssl pkey -pubin -outform DER \
  | openssl dgst -sha256 -binary \
  | xxd -p -c 64
```

```text
5f2c9a41b73e08d6c1524fb097ae3d1682cb45790e6a1d3f84b20c7591de6a04
```

3. Como contraste, calculá el selector `0` (el certificado completo):

```bash
sudo openssl x509 -in www.crt -outform DER | openssl dgst -sha256 -binary | xxd -p -c 64
```

```text
a70b1e5c93d248fa06b7c1e3592d0847fb6a19c250e38d71b4c069af23158de6
```

4. Publicá el registro en `auth/example.test.db` (recordá: la fuente *sin firmar*, `named` re-firma). El servicio va a correr en 8443, así que no hace falta root:

```dns
_8443._tcp.www   IN TLSA 3 1 1 5f2c9a41b73e08d6c1524fb097ae3d1682cb45790e6a1d3f84b20c7591de6a04
```

Incrementá el serial del SOA, y después:

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

5. Levantá un servidor TLS usando nada más que OpenSSL:

```bash
sudo openssl s_server -accept 127.0.0.10:8443 -cert /var/lib/bind/lab/tls/www.crt \
     -key /var/lib/bind/lab/tls/www.key -www
```

6. En otra terminal, verificá el par *contra el registro TLSA solamente* — sin ningún bundle de CA involucrado:

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

7. Probá que la vinculación es real presentando una asociación que no coincide:

```bash
openssl s_client -connect 127.0.0.10:8443 -servername www.example.test \
  -dane_tlsa_domain www.example.test \
  -dane_tlsa_rrdata "3 1 1 0000000000000000000000000000000000000000000000000000000000000000" \
  </dev/null 2>&1 | grep -Ei 'verify return code|dane'
```

```text
    Verify return code: 65 (CA signature digest algorithm too weak)
```

*(el código exacto varía según la compilación de OpenSSL; lo que importa es que sea distinto de cero y que no aparezca ninguna línea "matched EE certificate")*

8. Hacé la cosa completa de punta a punta — búsqueda **y** validación — con un cliente que realmente resuelva el registro. Apuntá `/etc/resolv.conf` (o usá `-n`) al resolver validador:

```bash
ldns-dane -n -s 127.0.0.20 verify www.example.test 8443
```

```text
www.example.test. 8443 TLSA 3 1 1 5f2c...6a04 did match
```

9. Publicá un registro SSHFP (RFC 4255) — la misma idea aplicada a claves de host SSH:

```bash
ssh-keygen -r www.example.test -f /etc/ssh/ssh_host_ed25519_key.pub
```

```text
www.example.test IN SSHFP 4 1 9d3e6c1a70b4582f0e19d7c3a64b0158cf27e9d0
www.example.test IN SSHFP 4 2 c81f0a6b2d4759e0138acf6472b9d05e3a1780c6425f9db31e0a76c4589f2d13
```

Agregá la forma de tipo 2 (SHA-256) a la zona, re-firmá y probá con `ssh -o VerifyHostKeyDNS=yes -o StrictHostKeyChecking=ask`.

**Preguntas — Bloque 9**

1. Decodificá `TLSA 3 1 1`: nombrá los tres campos y sus valores. ¿Cuáles son las otras opciones para cada uno?
2. En el paso 6, OpenSSL imprimió `verify error:num=18:self-signed certificate` e *igual* terminó con `Verify return code: 0 (ok)`. Explicá con precisión por qué ambas cosas son ciertas.
3. El uso `3` es DANE-EE. Bajo el RFC 7671, ¿el cliente igual verifica que el SAN del certificado coincida con el hostname? ¿Cuál es la consecuencia práctica para la gestión de certificados?
4. ¿Qué requiere DANE fundamentalmente del DNS, y cuánto vale exactamente un registro TLSA si la zona no está firmada o el cliente no valida?
5. `openssl s_client -dane_tlsa_rrdata` toma el registro en la línea de comandos. ¿Qué dos cosas hace un cliente DANE real que esta invocación no hace?
6. El nombre de propietario es `_8443._tcp.www.example.test`. Derivá el nombre de propietario para un servidor SMTP `mx1.example.test` en el puerto 25. Para DANE en SMTP (RFC 7672), ¿a qué nombre se adjunta el registro TLSA — al hostname del MX o al dominio de correo — y qué debe ser cierto del RRset MX?
7. Estás rotando el certificado de `www`. Escribí la secuencia correcta de operaciones, y nombrá el procedimiento DNSSEC del Ejercicio 6 que refleja estructuralmente.
8. ¿Por qué DANE tuvo amplia adopción en SMTP y prácticamente ninguna en los navegadores web? Dá la razón técnica, no simplemente "los fabricantes no lo implementaron".

---

## Ejercicio 10 — Transporte cifrado: DoT y DoH

DNSSEC autentica los datos. No hace nada por la confidencialidad — cualquiera en el camino lee cada pregunta que hacés. DoT y DoH cierran eso, en el salto de stub a resolver.

1. Dale al resolver un certificado TLS y una sentencia `tls` en `resolver/named.conf`:

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

2. Reiniciá y confirmá los sockets:

```bash
sudo rndc -s 127.0.0.20 -k /var/lib/bind/lab/rndc-lab.key reconfig
sudo ss -lntp | grep -E '127.0.0.20:(53|443|853)'
```

```text
LISTEN 0 10 127.0.0.20:853  0.0.0.0:* users:(("named",pid=8841,fd=27))
LISTEN 0 10 127.0.0.20:443  0.0.0.0:* users:(("named",pid=8841,fd=28))
LISTEN 0 10 127.0.0.20:53   0.0.0.0:* users:(("named",pid=8841,fd=25))
```

3. Consultá sobre DoT y sobre DoH:

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

4. Confirmá los identificadores ALPN que negocia cada protocolo:

```bash
openssl s_client -connect 127.0.0.20:853 -alpn dot </dev/null 2>&1 | grep -i alpn
openssl s_client -connect 127.0.0.20:443 -alpn h2  </dev/null 2>&1 | grep -i alpn
```

```text
ALPN protocol: dot
ALPN protocol: h2
```

5. Mostrá que la bandera `ad` sobrevive al salto cifrado, y que es una afirmación del *resolver*, no de TLS:

```bash
kdig +tls +dnssec @127.0.0.20 www.example.test A | grep -E 'Flags|EDE'
```

**Preguntas — Bloque 10**

1. Poné DNSSEC, TSIG y DoT lado a lado: para cada uno, nombrá qué se protege, contra quién, y en qué salto.
2. DoT es el puerto 853, DoH es 443 con una plantilla de URI. ¿Por qué DoH eligió deliberadamente 443 y HTTPS normal, y qué le hace eso a la capacidad de un operador de ver o bloquear DNS?
3. Una vez que el tráfico está sobre DoT, ¿la validación DNSSEC es redundante? Dá el ataque concreto que TLS hacia tu resolver no detiene.
4. Cuando un stub se conecta por DoT y el resolver pone `ad`, ¿en qué está confiando realmente el stub? ¿Qué dos configuraciones restauran la garantía de punta a punta?
5. Acá `kdig` aceptó un certificado autofirmado. ¿Qué opciones forzarían una autenticación real del resolver, y qué es DoT "strict" versus "opportunistic"?
6. BIND ahora está sirviendo DNS en 443. Nombrá dos consecuencias operativas para un host que también sirve HTTPS.

---

## Ejercicio 11 — Práctica de diagnóstico

Para cada síntoma, escribí la causa más probable y el único comando que la confirma. Después ejecutá los que puedas reproducir en este laboratorio.

1. `dig @resolver name A` → `SERVFAIL`. `dig @resolver name A +cd` → respuesta correcta.
2. `dig @auth name A +norec` → correcto. `dig @resolver name A` → `SERVFAIL`. `rndc secroots` muestra un anchor estático para el padre cuyo key tag no está en el RRset DNSKEY actual del padre.
3. La zona funcionó durante 27 días y se rompió de un día para el otro. No se cambió nada.
4. `delv` reporta `; fully validated` desde tu laptop, pero el resolver del datacenter devuelve SERVFAIL para el mismo nombre.
5. `dig DNSKEY` sobre UDP devuelve una respuesta truncada y la bandera `tc`; TCP funciona. La validación falla de forma intermitente desde algunas redes.
6. `named` loguea `zone example.test/IN: NSEC3 iterations 500 out of range`.
7. Una hija recién delegada valida como **insegura** en lugar de segura — sin SERVFAIL, pero tampoco bandera `ad`.
8. El secundario loguea `transfer of 'example.test/IN' from 127.0.0.10#53: failed while receiving responses: tsig indicates error`.

Comandos útiles para esta práctica:

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

Para zonas que están realmente en Internet, las herramientas de terceros de referencia son **DNSViz** (`https://dnsviz.net/`) y el **DNSSEC Debugger** de Verisign (`https://dnssec-debugger.verisignlabs.com/`), que renderizan gráficamente la cadena de confianza completa.

**Preguntas — Bloque 11**

Respondé los ocho ítems de arriba: causa probable + comando de confirmación.

---

## Desmontaje

```bash
sudo pkill -f '/var/lib/bind/lab' 
sudo rm -rf /var/lib/bind/lab
# RHEL/Fedora only:
sudo semanage fcontext -d "/var/lib/bind/lab(/.*)?" 2>/dev/null
```

---

<details>
<summary><b>Respuestas</b></summary>

### Bloque 1

1. **No hay RRSIG y eso es esperable** — la zona no está firmada en este punto, así que no hay nada para devolver. **Que tampoco haya bandera `ad` también es esperable, pero por otra razón**: `ad` la pone un *resolver recursivo validador*, y vos consultaste directamente a un servidor autoritativo. Incluso contra una zona completamente firmada, un servidor autoritativo no pone `ad`. En un despliegue firmado, un RRSIG faltante bajo `+dnssec` sería un bug; un `ad` faltante desde un servidor autoritativo nunca lo es.

2. `aa` = Authoritative Answer: el servidor que responde tiene la zona localmente y no está respondiendo desde caché. `ra` = Recursion Available: ausente porque `recursion no`. Un servidor autoritativo expuesto a Internet no debe recursar porque un recursor abierto es (a) un arma de reflexión/amplificación contra terceros, y (b) un objetivo de envenenamiento de caché — los datos de caché y los autoritativos no deben compartir espacio de nombres. Separar los roles autoritativo y recursivo en instancias distintas es la regla estándar de hardening.

3. Se convierte en el **TTL de NSEC/NSEC3** y en el TTL de la denegación de existencia autoritativa. El RFC 4034 §4 exige que el TTL de un RR NSEC sea el campo MINIMUM del SOA, así que ese número ahora controla cuánto tiempo se cachea una no-existencia *probada* — que es precisamente lo que a un atacante le gustaría que fuera largo cuando agregás un registro.

4. Porque es un **registro glue**. `ns1.example.test` es *in-bailiwick* — vive dentro de la zona que sirve. Un resolver que sigue la delegación desde `test.` necesita la dirección para poder preguntarle a la hija, pero no puede pedírsela a la hija sin conocerla ya. El padre debe suministrarla en la sección ADDITIONAL. Notá que el glue *no* está firmado por el padre: son datos no autoritativos en la zona padre, que es exactamente por qué el DS, y no el NS/glue, es la parte relevante para la seguridad de una delegación.

5. No es una regresión. La validación es una función de *resolver*: significa "chequear firmas sobre datos que traje de otro lado antes de cachearlos". Un servidor autoritativo sirve datos que ya tiene y no trae nada recursivamente, así que no hay nada que validar. Poner `dnssec-validation no` en una instancia solo autoritativa elimina un camino de código que nunca se dispararía. (No deshabilita el firmado ni el servicio de RRSIG — una confusión muy común.)

### Bloque 2

1. `K` (prefijo de archivo de clave) + `example.test.` (nombre de zona/propietario) + `+013` (número de algoritmo, ECDSAP256SHA256, RFC 6605) + `+21237` (key tag). El **número de algoritmo y el key tag** aparecen ambos textualmente en cada RRSIG que genera esa clave — campos 2 y 7 del RDATA del RRSIG.

2. El bit de orden bajo del campo de flags de 16 bits: `256` = 0x0100 (solo el bit ZONE), `257` = 0x0101 (ZONE + **SEP**, Secure Entry Point, RFC 4034 §2.1.1). El protocolo **no** obliga a nada: SEP es una pista puramente operativa que marca la clave cuyo DS debería publicar el padre. Cualquier clave con el bit ZONE puesto puede firmar cualquier RRset, y una zona de clave única ("CSK") es completamente válida. La separación KSK/ZSK es convención, no protocolo.

3. No está rota. El key tag es un checksum de 16 bits sobre el RDATA del DNSKEY (RFC 4034 Apéndice B), así que las colisiones son esperables — cota del cumpleaños en ~256 claves, e incluso se pueden provocar deliberadamente. Un validador debe tratar el key tag como una **pista para seleccionar candidatos, no como un identificador**: prueba con cada DNSKEY del RRset cuyo propietario, algoritmo y tag coincidan, y solo falla después de que fallan todos los candidatos. Esto también es por qué la "colisión de key tags" es una consideración de DoS (ataques de la clase KeyTrap) — las implementaciones limitan la cantidad de verificaciones de firma intentadas.

4. `21237` = key tag, `13` = algoritmo, `2` = tipo de digest, `4A9F…` = digest. El tipo de digest `2` es SHA-256, introducido por el **RFC 4509** (tipo 1 = SHA-1, obsoleto; tipo 4 = SHA-384, RFC 6605). El tipo de digest 2 es de implementación obligatoria y es lo que acepta hoy cualquier registro.

5. El **archivo `.private` es el secreto** — contiene la clave privada. Perder solamente el `.key` es recuperable: la clave pública puede regenerarse desde la privada (`dnssec-keyfromlabel`/`dnssec-settime` la necesitan, y el RDATA del DNSKEY es derivable). Perder el `.private` significa que nunca más vas a poder firmar con esa clave — para una KSK eso fuerza un rollover de emergencia con el padre. Un `.private` **filtrado** significa que un atacante puede forjar firmas que tus validadores van a aceptar mientras el DNSKEY correspondiente (o el DS, para una KSK) siga publicado — un rollover más el retiro del DS es obligatorio, y los datos cacheados hacen que la exposición sobreviva al cambio por los TTL del DNSKEY/DS.

6. (a) **Tamaño de respuesta.** Un DNSKEY ECDSA P-256 mide 64 bytes y una firma 64 bytes, contra 256+ bytes cada uno para RSA-2048. RRsets DNSKEY y RRSIG más chicos significan que las respuestas entran bajo el punto dulce de ~1232 bytes de payload EDNS, evitando la fragmentación IP y el fallback a TCP — la causa principal de "DNSSEC funciona desde acá pero no desde allá". (b) **Amplificación.** Respuestas más chicas significan un factor de amplificación menor si abusan de tu servidor como reflector. Además firmar es bastante más rápido, lo que importa cuando re-firmás zonas grandes. (Ed25519, algoritmo 15, RFC 8080, es todavía más chico pero tiene despliegue más flaco del lado del validador.)

### Bloque 3

1. `A` = **tipo cubierto**; `13` = **algoritmo**; `3` = **labels** (la cantidad de labels en el nombre de propietario original, excluyendo la raíz y cualquier comodín inicial); `300` = **TTL original** (el TTL tal como aparece en la zona, necesario porque los cachés decrementan los TTL y la firma cubre el original); `20260919114233` = **expiración de la firma**; `20260820104233` = **inicio de la firma**; `34505` = **key tag**; `example.test.` = **nombre del firmante**; y después la firma en sí. El campo **labels** detecta la síntesis por comodín: si la cuenta de labels en el RRSIG es menor que la cuenta de labels del nombre de propietario consultado, la respuesta se expandió desde un comodín, y el validador debe además exigir una prueba NSEC/NSEC3 de que no existía una coincidencia más cercana.

2. `-x` — "firmá el RRset DNSKEY solo con las claves de firma de claves". Sin él, ambas claves firman el RRset DNSKEY (y por defecto la ZSK también lo firma), produciendo una respuesta DNSKEY más grande sin ganancia de seguridad. Sacarlo no es un fallo de seguridad; cuesta bytes de respuesta, que según el Bloque 2 P6 es exactamente lo que estás tratando de ahorrar.

3. Es distinto de cero cuando re-firmás una zona que **ya está firmada** (`-f` sobre la salida firmada, o el mismo archivo in situ). `dnssec-signzone` retiene las firmas existentes que todavía no entraron en la ventana de re-firmado y regenera solo el resto. El umbral es `-i cycle` (el intervalo de re-firmado), que por defecto es un cuarto del período de validez de la firma. Esto es lo que hace barato el re-firmado incremental de una zona de un millón de registros.

4. Editá `example.test.db` (la fuente sin firmar) y volvé a correr `dnssec-signzone`. Si editás `example.test.db.signed` directamente y recargás, `named` lo va a cargar tan contento — no verifica firmas en el momento de la carga — y va a servir un registro A cuyo RRSIG ya no lo cubre. Todos los resolvers validadores del planeta devuelven entonces SERVFAIL para ese nombre, mientras tu propio `dig @auth` se ve perfecto. Este es exactamente el fallo que construiste en el Ejercicio 4.

5. `named-checkzone` es un chequeo de **sintaxis y estructura de zona**: errores de parseo, SOA/NS faltantes, conflictos de CNAME, datos fuera de zona. `dnssec-verify` es un chequeo de **completitud criptográfica**: que cada RRset autoritativo tenga un RRSIG válido y vigente de una clave publicada, que la cadena NSEC/NSEC3 esté completa y correctamente enlazada, y que el RRset DNSKEY esté correctamente auto-firmado. Solo `dnssec-verify` atrapa un RRset sin firmar, una cadena de denegación rota o una firma expirada.

6. El **padre (`test.`)** es autoritativo para el RRset DS — el DS vive del lado del padre del corte de zona (RFC 4035 §3.1.4.1), que es por qué está firmado por la **ZSK del padre**, no por ninguna clave de la hija. Este es el mecanismo entero de la cadena de confianza: la clave del padre da fe de un digest de la clave de la hija. También es por qué una consulta DS nunca debe responderse desde los datos de zona de la hija.

7. **Validez larga**: una clave comprometida o retirada queda explotable durante el resto de la vida útil de las firmas ya publicadas y cacheadas; el replay de datos firmados viejos es posible por más tiempo. **Validez corta**: cualquier interrupción de tu automatización de re-firmado — un cron fallido, un disco lleno, una caída del HSM, un fin de semana largo — deja bogus a la zona entera cuando expiran las firmas, y falla *cerrado*, globalmente, sin aviso. El compromiso de la industria es aproximadamente 14–30 días de validez con re-firmado a 1/4 o 1/3 de eso, más monitoreo sobre la vida útil *mínima* remanente de las firmas en toda la zona.

### Bloque 4

1. `no` — no validar; aceptar todo, nunca poner `ad`. `yes` — validar, usando **solamente** los trust anchors configurados explícitamente en sentencias `trust-anchors`/`managed-keys`/`trusted-keys`. `auto` — validar, usando el trust anchor de la raíz incorporado que viene en `bind.keys`, mantenido automáticamente según el RFC 5011. **`auto` es el valor por defecto de BIND 9.18.** El laboratorio necesita `yes` porque acá no hay una raíz real: con `auto`, el resolver tendría un anchor para `.` al que nuestra jerarquía falsa no puede encadenar, y todo sería bogus o inseguro.

2. Demuestra **autenticación de origen de datos e integridad** — el resolver probó que los datos que recibió no son lo que el dueño de la zona firmó, y los rechazó, *sin ninguna relación previa con el servidor autoritativo*. **No** provee confidencialidad (la respuesta forjada viajó en texto plano y cualquiera podía leerla) ni provee disponibilidad (el resultado de la detección es denegación de servicio para el usuario — DNSSEC falla cerrado por diseño).

3. `+cd` pone el bit **Checking Disabled** en el encabezado de la consulta, diciéndole al resolver recursivo "devolveme los datos aunque fallen la validación; yo valido por mi cuenta, o acepto el riesgo". Es un diagnóstico que aísla *dónde* está el fallo: si `+cd` funciona y sin él no, el validador del resolver está rechazando los datos, así que el problema son las firmas, no la alcanzabilidad. Hacerlo permanente (por ejemplo `options { ... }` en los stubs, o una aplicación que use CD=1 por defecto) deshabilita silenciosamente toda la protección que desplegaste — te quedás con el costo operativo de DNSSEC y perdés todo su beneficio.

4. **`do`** (DNSSEC OK, un bit de encabezado EDNS0 en el RR OPT) — la pone el **cliente** en la *consulta*; significa "mandame registros RRSIG/NSEC/DNSKEY". **`ad`** (Authentic Data) — la pone el **resolver validador** en la *respuesta*; significa "verifiqué esto criptográficamente". **`cd`** (Checking Disabled) — la pone el **cliente** en la *consulta*; significa "no me retengas datos por motivos de validación". Entonces: `do` y `cd` viajan cliente→servidor, `ad` viaja servidor→cliente. Un stub que no valida por sí mismo debe confiar tanto en el resolver como en el camino hacia él antes de creerle a `ad` — que es lo que aborda DoT (Bloque 10).

5. (i) ¿Los datos son realmente bogus o simplemente faltan? `dig @resolver <name> +dnssec` y leé el código **EDE**. (ii) ¿Qué eslabón de la cadena falla? `delv @resolver +rtrace +vtrace <name>` — imprime la secuencia de fetch y verificación y nombra el paso que falla. (iii) ¿La zona publicada es internamente consistente? `dnssec-verify -o <zone> <signedfile>` en el servidor autoritativo. (iv) ¿El DS del padre sigue siendo correcto para un DNSKEY actualmente publicado? `dig @parent <zone> DS` comparado contra `dig @child <zone> DNSKEY` — y `rndc secroots` si hay un anchor estático local involucrado. Recién después de esas cuatro tiene sentido mirar la red (fragmentación, EDNS, TCP).

6. **EDE 6 (DNSSEC Bogus)** — las firmas existen pero no verifican: los datos fueron modificados, se roló una clave sin re-firmar, o la relación DS/DNSKEY está rota. **EDE 7 (Signature Expired)** — el RRSIG está estructuralmente bien y es criptográficamente correcto pero la hora actual está fuera de su ventana de inicio/expiración. EDE 7 domina en producción porque tiene dos disparadores independientes: un pipeline de re-firmado que dejó de correr (silencioso hasta el día de la expiración), y **desvío de reloj en el resolver validador** — una falla de NTP deja bogus a zonas perfectamente buenas sin culpa alguna del dueño de la zona. También es por qué el monitoreo de expiración de firmas debe alarmar sobre *días restantes*, no sobre el fallo.

7. Un negative trust anchor le dice al resolver "tratá este subárbol como inseguro, no lo valides" — la palanca de emergencia cuando la zona de *otra persona* se vuelve bogus y tus usuarios no pueden trabajar. La vida útil por defecto es **1 hora** (`nta-lifetime`), acotada a **1 semana** (`max-nta-lifetime`). El riesgo es que durante ese lapso ese subárbol no tiene **ninguna protección DNSSEC** para todos los clientes de ese resolver — aceptaste voluntariamente respuestas falsificables para un dominio, así que hay que acotarlo lo más estrechamente posible, con plazo, registrado en logs, y quitarlo en el momento en que el upstream se arregle.

8. `delv` realiza la validación **él mismo, en el proceso cliente**. Envía sus consultas con CD=1 para que el resolver entregue los registros crudos sin filtrarlos, después construye y verifica la cadena localmente contra el anchor que le pasaste con `-a`/`+root=`. Por eso puede explicar *qué* paso falló, y por eso funciona incluso cuando el validador propio del resolver está mal configurado. `dig` nunca valida nada — solo reporta el bit `ad` que puso otro.

### Bloque 5

1. El NSEC en `mail.example.test.` (que apunta a `ns1.example.test.`) prueba que **no existe ningún nombre en el orden canónico entre `mail` y `ns1`**, y `nothere` ordena ahí — así que el nombre consultado no existe. El NSEC en el apex `example.test.` prueba que **no existe ningún comodín `*.example.test`** que pudiera haber sintetizado una respuesta. Ambas pruebas son necesarias para un NXDOMAIN firmado (RFC 4035 §3.1.3.2); un validador que acepta solo la primera puede ser engañado para negar un nombre que un comodín habría respondido.

2. El **mapa de bits de tipos**. Derrota la falsificación de denegación de existencia de *tipo*: prueba autoritativamente qué tipos de RR existen y cuáles no en un nombre que *sí* existe. Sin él, un atacante podría quitar el RRset MX o TLSA de una respuesta y afirmar que el nombre no tiene tal registro — con NSEC el validador ve el bit puesto y sabe que se retuvo una respuesta. Esto es precisamente lo que hace a DANE y a MX resistentes al downgrade.

3. Una **consecuencia de diseño**, reconocida explícitamente. El RFC 4033 §3.2 y el RFC 4034 §? establecen que la denegación autenticada de existencia de DNSSEC necesariamente revela el contenido de la zona; el **RFC 5155 §1.3 y el Apéndice C** describen la enumeración de zonas como el problema motivador de NSEC3. La confidencialidad del contenido de la zona nunca fue un objetivo de seguridad de DNSSEC. (Alternativas modernas: NSEC3 para elevar el costo, o **NSEC "white lies" / black lies** — firmado en línea con registros NSEC mínimamente cubrientes, RFC 4470 / RFC 7129 — que elimina la enumeración por completo al costo de requerir claves en línea.)

4. `1` = algoritmo de hash (SHA-1 — el único valor jamás registrado); `0` = flags (el bit 0 es opt-out; en NSEC3PARAM debe ser 0); `0` = iteraciones (rondas de hash extra más allá de la primera); `-` = salt (`-` significa salt vacío). El **TTL es 0** porque NSEC3PARAM es una señal para el servidor autoritativo sobre qué cadena usar, no datos pensados para ser cacheados y reutilizados por los resolvers.

5. Las iteraciones se pensaron para frenar ataques de diccionario, pero el atacante calcula hashes offline en GPUs a tasas enormes mientras que *el servidor autoritativo y cada validador* pagan el costo en línea, una vez por consulta — el defensor paga mucho más que el atacante. El beneficio medido es despreciable, así que el **RFC 9276 §3.1** dice usar iteraciones 0. El salt se pensó para prevenir tablas rainbow precomputadas, pero el nombre de la zona ya está en la entrada del hash, lo que hace única la tabla de cada zona de todos modos; y rotar un salt requiere re-firmar la cadena entera. De ahí el salt vacío (§3.1). **BIND 9.18 trata una respuesta con más de 150 iteraciones NSEC3 como *insegura*** (deja de validar en vez de fallar) — así que iteraciones excesivas no hacen tu zona más segura, la hacen *menos* validada.

6. El opt-out permite que las **delegaciones inseguras** (delegaciones con un RRset NS pero sin DS) sean **omitidas de la cadena NSEC3** — solo las delegaciones seguras y los nombres con datos autoritativos reciben registros NSEC3. Compra una reducción enorme del tamaño de la zona y del tiempo de firmado para una zona que es mayormente delegaciones sin firmar (un TLD con millones de nombres, de los cuales un pequeño porcentaje está firmado). El costo: ya no podés probar que una delegación insegura *no existe*, así que un atacante puede insertar una delegación insegura fabricada dentro del hueco cubierto. Para una zona hoja sin delegaciones no compra nada y debería ser `no`.

7. (a) **Estructura predecible** — `www`, `mail`, `ns1`, `smtp`, `vpn`, `_dmarc`, `_domainkey` y unos pocos miles más cubren la mayoría de los labels reales, así que el modelo relevante es un ataque de diccionario más que fuerza bruta. (b) **Espacio de labels corto y de baja entropía** — la entrada hasheada es `label + nombre de zona`, y el nombre de zona es conocido, así que la parte desconocida es una cadena corta de un alfabeto chico; herramientas como `nsec3walker` y `hashcat` las procesan a tasas altísimas. Por eso NSEC3 se entiende mejor como algo que eleva el costo de la enumeración, nunca como algo que la impide.

### Bloque 6

1. **`-P` Publish**: el momento más temprano en que el DNSKEY puede aparecer en la zona. **`-A` Activate**: el momento en que la clave empieza a generar firmas. **`-R` Revoke**: el momento en que se pone el bit REVOKE (señalización RFC 5011). **`-I` Inactive**: el momento en que la clave deja de generar firmas nuevas (sigue publicada). **`-D` Delete**: el momento en que el DNSKEY se quita de la zona. **Publish y Activate nunca deben coincidir** para una clave que entra en servicio, y **Inactive y Delete nunca deben coincidir** para una que sale — el intervalo en cada caso es lo que permite que los cachés que tienen el estado *viejo* sigan encontrando la clave que necesitan. Colapsar cualquiera de los dos intervalos es la forma clásica de romper un rollover.

2. El invariante: **el DNSKEY de una clave debe estar publicado antes del primer RRSIG que hace, y debe permanecer publicado después de que el último RRSIG que hizo expire de todos los cachés.** Un resolver puede tener cacheado un RRSIG hecho por la clave X y por separado traer el RRset DNSKEY; si X no está en ese RRset, la validación falla. El pre-publish garantiza que la unión de "claves en la zona" siempre cubra "claves referenciadas por cualquier firma que todavía pueda estar cacheada".

3. El **pre-publish de ZSK** espera al **TTL del DNSKEY de tu propia zona** — todo lo involucrado está bajo tu control y dentro de tu zona, así que simplemente publicar temprano y retirar tarde alcanza. El **doble-DS de KSK** espera al **TTL del DS del padre y a la latencia de publicación del padre** — el registro/registrador. No podés vaciar los cachés del padre, muchas veces no podés predecir cuánto tarda el registro en publicar, y un error ahí rompe la cadena de confianza de la zona entera en lugar de un solo RRset. De ahí el procedimiento más conservador, con mucho solapamiento.

4. Para la ZSK: el **TTL del RRset DNSKEY** (cuánto puede persistir una vista vieja del conjunto de claves) y el **TTL máximo de cualquier RRset firmado de la zona** (cuánto puede persistir un RRSIG de la clave que se retira), más el remanente de validez de la firma. Para la KSK: el **TTL del DS del padre**, que el operador de la hija no controla y debe consultar y respetar. En la `dnssec-policy` de BIND aparecen como `dnskey-ttl`, `max-zone-ttl` y `parent-ds-ttl`.

5. Nada se rompe *de inmediato* en términos de firmado — la clave está inactiva, así que ninguna firma nueva la necesita. Pero el DNSKEY de la ZSK vieja sigue publicado (Delete está a 14 días), y los RRSIG que hizo siguen en cachés por hasta `max-zone-ttl`. Borrar el archivo `.private` elimina la capacidad de firmar, que no hace falta; el peligro real es borrar el archivo `.key` o quitar el DNSKEY de la zona, lo que rompería la validación para todo caché que todavía tenga un RRSIG viejo. En la práctica: borrar solo el `.private` en ese momento es *sobrevivible*, pero destruye la capacidad de hacer rollback, y si la clave nueva resulta defectuosa ahora no tenés forma de re-firmar con la anterior. Tratá el borrado de claves como algo gobernado por la marca de tiempo `Delete`, no por la intuición.

6. En un rollover de algoritmo, **cada RRset de la zona debe estar firmado con cada algoritmo presente en el RRset DNSKEY**, durante todo el período de solapamiento (RFC 6781 §4.1.4, y RFC 4035 §2.2 — la regla de "completitud de algoritmos de firmado"). Un validador que soporta el algoritmo nuevo y lo encuentra en el RRset DNSKEY va a *exigir* una firma válida de ese algoritmo para cada RRset; una zona que publica el DNSKEY nuevo pero todavía no firmó todo con él es bogus para esos validadores. Los rollovers del mismo algoritmo no tienen esa regla porque cualquier clave del algoritmo alcanza. Además, el RRset DS del padre debe contener un DS para el algoritmo nuevo antes de quitar el viejo, y el orden de transición es: agregar clave nueva + firmar todo con ambas → agregar DS nuevo → quitar DS viejo → quitar firmas viejas → quitar clave vieja.

7. El bit **REVOKE** (bit 8 de los flags del DNSKEY, RFC 5011 §2.1) — una KSK revocada tiene flags `385` y debe estar auto-firmada mientras está revocada, que es lo que prueba que la revocación es genuina. El hold-down de **add** para una clave nueva es de **30 días** (o la mitad del TTL original, lo que sea mayor); el hold-down de **remove** tras la revocación es igualmente de 30 días. El RFC 5011 es lo que hace viable `dnssec-validation auto` para la zona raíz sin actualizaciones manuales del anchor — y notá que los anchors `static-key`, a diferencia de `initial-key`/`initial-ds`, *no* son mantenidos por RFC 5011.

### Bloque 7

1. Editá **`example.test.db`** — la fuente sin firmar. Nunca toques **`example.test.db.signed`** ni **`example.test.db.signed.jnl`**; `named` es dueño de ambos. El `.jnl` es el **journal**: un log de cambios incremental de solo apéndice (el mismo mecanismo usado por dynamic update e IXFR) que contiene los deltas aplicados a la zona firmada desde la última vez que se volcó al archivo `.signed`. Leer un archivo `.signed` con un `.jnl` vivo presente te da una foto desactualizada — usá `rndc sync` o `rndc freeze`/`thaw` primero, o simplemente consultá al servidor. El `.jbk` es el archivo de transacciones respaldado por journal para la zona cruda.

2. **`hidden`** — el registro no está publicado en ningún lado y ningún caché puede tenerlo. **`rumoured`** — fue publicado, pero no por suficiente tiempo como para garantizar que todos los cachés lo tengan; algunos resolvers todavía sostienen la vista vieja. **`omnipresent`** — publicado por más tiempo que el TTL relevante más el retardo de propagación más el margen de seguridad, así que *todos* los cachés o lo tienen o lo van a traer. **`unretentive`** — fue retirado, pero los cachés pueden todavía tenerlo. Las transiciones están impulsadas por: `dnskey-ttl` para el estado del DNSKEY, `max-zone-ttl` (+ `zone-propagation-delay`) para el estado del RRSIG de zona, y `parent-ds-ttl` (+ `parent-propagation-delay`) para el estado del DS, cada uno acolchado por `publish-safety` / `retire-safety`.

3. `named` no puede ver la zona padre y no tiene forma de saber si realmente enviaste el DS al registrador, si el registrador lo publicó, ni cuándo. Si avanzara el estado de la KSK adivinando y el DS no estuviera realmente ahí, retiraría la clave vieja y rompería la cadena de confianza de toda la zona. `rndc dnssec -checkds published` es el humano (o la automatización) afirmando el hecho externo. BIND 9.19+ puede verificarlo por sí mismo usando `parental-agents`/`checkds`, que consulta directamente a los servidores de nombres del padre.

4. **Refresh** es cuándo `named` empieza a regenerar firmas — una firma se renueva cuando su vida útil remanente cae por debajo de `signatures-validity − signatures-refresh`, es decir que acá las firmas se refrescan después de 9 días de una vida de 14, dejando un colchón de 5 días. Si refresh se pone demasiado cerca de validity (digamos `P13D` sobre `P14D`), el colchón se colapsa: cualquier caída del proceso de firmado, una zona lenta o desvío de reloj consume el margen y las firmas expiran en producción. BIND 9.18+ rechaza un intervalo de refresh por encima del 90 % de la validez por esta razón. El colchón debe superar tu peor tiempo medio de reparación realista.

5. `zone-propagation-delay` (cuánto tarda hasta que todos tus secundarios tienen la zona nueva), `parent-propagation-delay` (cuánto tarda el padre en publicar un DS enviado) y `publish-safety`/`retire-safety` (márgenes de paranoia explícitos de cada lado). Ninguno puede ser cero con secundarios porque un cambio de zona llega a un secundario solo después de un NOTIFY + transferencia, o en el peor caso tras el intervalo de refresh del SOA — si la política asume propagación instantánea, va a retirar una clave mientras un secundario rezagado todavía sirve firmas hechas con ella, y las respuestas de ese secundario se vuelven bogus.

6. Del padre mismo: `dig @<parent-ns> <yourzone> DS` te da directamente el TTL del DS; el retardo de propagación sale del SLA publicado del registro o del registrador, o de medirlo durante un rollover previo. **Adivinar bajo es la dirección peligrosa** — la política va a avanzar la máquina de estados de la KSK antes de que los cachés del padre realmente hayan convergido, retirando el DS/clave viejos mientras los resolvers todavía los referencian, lo que deja bogus a la zona entera. Adivinar alto solo hace más lentos los rollovers.

7. CDS (Child DS) y CDNSKEY publican, *en la zona hija y firmados por la hija*, el DS/DNSKEY que el padre **debería** publicar. El padre (o el registrador) los consulta periódicamente y actualiza la delegación automáticamente, eliminando el envío manual fuera de banda del DS que hace tan dolorosos los rollovers de KSK — RFC 7344 para el mecanismo, RFC 8078 para el bootstrap inicial y para la señal de borrado. **`CDS 0 0 0 00`** (y el `CDNSKEY 0 3 0 0` correspondiente) es el registro especial de "delete" definido en el RFC 8078 §4: le indica al padre que **quite todos los registros DS**, devolviendo a la hija a una delegación insegura (sin firmar) — la forma limpia de apagar DNSSEC sin quedar bogus.

### Bloque 8

1. **Sin cifrado.** TSIG (RFC 8945, que obsoleta al RFC 2845) calcula un HMAC con clave sobre el mensaje DNS más una marca de tiempo, usando un secreto simétrico compartido por exactamente dos partes. Provee **integridad** (el mensaje no fue alterado en tránsito) y **autenticación de origen** (vino de alguien que tiene el secreto compartido). **No provee ninguna confidencialidad** — el AXFR que hiciste en el paso 4 viajó en texto plano y cualquier observador leyó la zona entera.

2. **Qué se protege**: TSIG protege un único **mensaje/transacción** entre dos hosts; DNSSEC protege los **datos del RRset en sí**, independientemente de cómo fueron transportados. **Distribución de claves**: TSIG usa un **secreto simétrico compartido** configurado manualmente en ambos extremos — no escala más allá de un conjunto conocido de pares; DNSSEC usa **claves asimétricas** con la cadena de confianza distribuida a través de la propia jerarquía del DNS, así que un validador no necesita relación previa con la zona. **Alcance de la confianza**: TSIG es **salto a salto** y su garantía termina en el par; DNSSEC es **de punta a punta / seguridad de objeto** y sobrevive a caché y reenvío arbitrarios. Consecuencia: TSIG asegura AXFR/IXFR, NOTIFY, dynamic update y `rndc`; DNSSEC asegura lo que el resolver de un desconocido termina cacheando.

3. `-y` pone el **secreto en base64 en la línea de comandos**, lo que (a) es visible en la tabla de procesos para todo usuario del host durante la vida del comando (`ps auxww`, `/proc/<pid>/cmdline`), y (b) queda escrito en el archivo de historial del shell. `-k` pasa una ruta; el secreto se lee de un archivo cuyos permisos controlás vos (0640, propiedad del grupo de la clave).

4. **BADKEY (rcode 17)** — el servidor no reconoce el nombre de clave presentado, o esa clave no está permitida para esta operación. **BADSIG (rcode 16)** — el nombre de clave es conocido pero el HMAC no verifica: los secretos difieren, o los algoritmos difieren, o el mensaje fue alterado. **BADTIME (rcode 18)** — la clave y el HMAC están bien pero la marca de tiempo del RR TSIG está fuera de la ventana de fudge (300 s por defecto) respecto del reloj del servidor. Los tres son rcodes extendidos específicos de TSIG llevados en el **campo `Error` del propio RR TSIG** (mostrado por `dig` en la `;; TSIG PSEUDOSECTION:`), porque el rcode de 4 bits del encabezado no puede expresarlos — el encabezado muestra `NOTAUTH` (9).

5. La marca de tiempo más el fudge son una medida **anti-replay**: sin ellas, un atacante que capturó una petición firmada válida (digamos un dynamic update, o un NOTIFY) podría reproducirla indefinidamente, ya que el HMAC seguiría siendo válido para siempre. Acotar la validez a ±fudge segundos limita la ventana de replay. Esto convierte a **la hora exacta en una dependencia dura de tu infraestructura DNS**: una falla de NTP/chrony en un primario o secundario rompe las transferencias de zona con BADTIME, y (según el Bloque 4 P6) rompe la validación DNSSEC con EDE 7. La sincronización horaria no es un lujo acá; es parte del mecanismo de seguridad.

6. Sin él, el secundario **conocería** la clave pero nunca la **usaría**. La cláusula `key` dentro de una sentencia `server` es lo que le dice a `named` "firmá cada petición que le mandes a este par con esta clave". `include` meramente define la clave; `allow-transfer { key ...; }` meramente la acepta de entrada. La transferencia saldría sin firmar y el primario respondería REFUSED. (La alternativa es adjuntar la clave a nivel de zona: `primaries { 127.0.0.10 key "xfr-lab"; };`.)

7. **Sigue valiendo la pena.** Argumentos de que ya no importa: la zona está firmada así que el contenido no puede falsificarse, y NSEC3 ya concede que la enumeración es factible, así que AXFR revela poco que un caminante decidido no pueda obtener. Argumentos de que sí importa, que ganan en la práctica: (i) AXFR es una **única petición barata** que rinde la zona entera incluyendo registros sin ninguna exposición por denegación de existencia bajo NSEC3 white-lies o firmado en línea; (ii) es un vector de **agotamiento de recursos** — un AXFR sin restricciones de una zona grande es una amplificación y un DoS de CPU/ancho de banda; (iii) las zonas internas frecuentemente contienen inventario de hosts, convenciones de nombres y topología de infraestructura que asisten materialmente a un atacante; (iv) defensa en profundidad — el costo de `allow-transfer { key ...; }` es una línea. Sigue siendo un ítem de hardening básico en todo benchmark de DNS.

8. En Debian/Ubuntu la clave de control por defecto es **`/etc/bind/rndc.key`**, generada en tiempo de instalación por `rndc-confgen -a` y referenciada tanto desde `named.conf` como desde `/etc/bind/rndc.conf` (RHEL: `/etc/rndc.key`). `controls { inet * ... }` enlaza el canal de control a **todas las interfaces**, exponiendo el puerto 953 a la red; combinado con una clave débil o filtrada, o con una lista `allow` de `any`, otorga control administrativo total del servidor de nombres — `rndc` puede reconfigurar, volcar el caché, agregar NTAs, detener el demonio y (con zonas dinámicas) alterar datos. El canal de control debe estar enlazado a loopback o a una dirección de gestión y restringido tanto por `allow` como por `keys`.

### Bloque 9

1. `3` = **uso del certificado**; `1` = **selector**; `1` = **tipo de coincidencia**. Uso: `0` PKIX-TA (restricción de CA, la cadena igual debe validar hasta una raíz pública), `1` PKIX-EE (restricción de entidad final, la cadena igual debe validar), `2` DANE-TA (afirmación de trust anchor, tu propia CA, sin necesidad de raíz pública), `3` DANE-EE (afirmación de entidad final, sin necesidad de raíz pública). Selector: `0` certificado completo, `1` SubjectPublicKeyInfo. Tipo de coincidencia: `0` coincidencia exacta sobre los datos seleccionados, `1` SHA-256 de ellos, `2` SHA-512 de ellos.

2. `verify error:num=18` es el veredicto **PKIX**: el certificado no encadena a nada en el almacén de confianza, porque es autofirmado. `Verify return code: 0 (ok)` es el veredicto **final** después de aplicar DANE: el uso `3` (DANE-EE) *reemplaza* la validación PKIX en lugar de complementarla, así que un registro TLSA coincidente alcanza por sí solo y el fallo PKIX no es fatal. Si el uso hubiera sido `1` (PKIX-EE), el error PKIX habría sido fatal y el resultado general habría sido un fallo sin importar la coincidencia TLSA.

3. **No.** El RFC 7671 §5.1 especifica que para DANE-EE las verificaciones de nombre (CN/SAN) y la expiración del certificado **no** se realizan — el registro TLSA, publicado en una zona firmada con DNSSEC bajo el nombre al que te estás conectando, *es* la vinculación entre nombre y clave. En la práctica esto significa que un despliegue DANE-EE puede usar un certificado autofirmado, de vida larga, o de "nombre equivocado", y — importante — un certificado cuyo `notAfter` ya pasó igual va a ser aceptado. El corolario es que toda la disciplina operativa se muda al DNS: tu registro TLSA es ahora lo que debe estar correcto, y rotarlo es la operación riesgosa.

4. DANE requiere que el RRset TLSA esté **firmado con DNSSEC y validado por el cliente** (RFC 6698 §? — la seguridad de DANE se reduce enteramente a la seguridad de la cadena DNSSEC). Sin eso, un atacante en el camino simplemente falsifica el registro TLSA para que coincida con su propio certificado y el cliente "verifica" contento la clave del atacante. Un registro TLSA en una zona sin firmar, o leído por un cliente que no valida, no vale **nada** — es estrictamente peor que no tener DANE, porque crea una falsa sensación de garantía mientras agrega una entrada de confianza controlada por el atacante.

5. (i) Realiza la **búsqueda DNS** de `_<port>._<proto>.<name> TLSA`. (ii) Exige que la respuesta esté **validada con DNSSEC** — ya sea validando localmente o insistiendo en el bit `ad` de un resolver validador confiable sobre un canal confiable. `openssl s_client` con `-dane_tlsa_rrdata` no hace ninguna de las dos; vos suministraste el registro a mano, así que solo demuestra la mitad de *coincidencia* de DANE, no la mitad de *confianza*. Por eso `ldns-dane` en el paso 8, o un despliegue de Postfix/`danectl`, es la prueba honesta de punta a punta.

6. `_25._tcp.mx1.example.test`. Para DANE en SMTP (RFC 7672), el registro TLSA se adjunta al **hostname del MX** (`mx1.example.test`), no al dominio de correo (`example.test`), porque ese es el nombre al que el MTA emisor realmente se conecta y el nombre presentado en el handshake TLS. El **RRset MX en sí debe estar validado con DNSSEC** — si la búsqueda MX es insegura, un atacante puede redirigir el correo a un host de su elección cuyos propios registros TLSA controla, derrotando todo el ejercicio. Tanto el RRset MX en el dominio de correo como los registros TLSA/A en la zona del MX deben estar firmados.

7. (i) Generá la clave y el certificado nuevos. (ii) **Publicá el registro TLSA nuevo junto al viejo** (el RRset ahora tiene dos registros; un cliente acepta una coincidencia contra *cualquiera* de ellos). (iii) Esperá al menos el TTL del RRset TLSA, más la propagación y un margen de seguridad, para que ningún caché tenga un RRset que contenga solo la asociación vieja. (iv) Desplegá el certificado nuevo en el servidor. (v) Esperá de nuevo. (vi) Quitá el registro TLSA viejo. Esto es estructuralmente idéntico al **rollover pre-publish de ZSK** del Ejercicio 6 — publicá la vinculación nueva antes de usarla, quitá la vieja solo después de que todo lo que pudiera haberla cacheado haya expirado. Equivocar el orden acá rompe TLS para todo emisor que valide DANE, lo que para SMTP significa colas de correo, no una advertencia de navegador.

8. Técnicamente: DANE requiere que el cliente realice **validación DNSSEC de la búsqueda TLSA**, y los navegadores deliberadamente no hacen resolución DNS ni validación DNSSEC por sí mismos — llaman al stub resolver del sistema operativo, que típicamente no devuelve ningún estado de validación en el que el navegador pueda confiar. Agregar una obtención de cadena de confianza al camino de la conexión además cuesta viajes de ida y vuelta adicionales en la ruta crítica de cada carga de página, y los fabricantes de navegadores juzgaron la latencia y la fragilidad (una zona bogus = un fallo duro de conexión) inaceptables frente a Certificate Transparency + CAA, que logran objetivos solapados sin una dependencia del DNS. SMTP no tiene ninguna de estas restricciones: los MTA son demonios de larga duración con sus propios resolvers validadores, la latencia es irrelevante para un mensaje encolado, y la alternativa (TLS oportunista sin autenticación alguna) era mucho más débil — así que ahí DANE llena un hueco real.

### Bloque 10

1. **DNSSEC** — protege la *integridad y el origen de los datos DNS*, contra cualquiera capaz de inyectar o modificar respuestas en cualquier punto entre la zona y el resolver validador (incluido un caché intermedio malicioso o comprometido), **de punta a punta desde la zona hasta el validador**. **TSIG** — protege la *integridad y el origen de una única transacción DNS*, contra un falsificador fuera del camino o en el camino, **en un salto específico entre dos pares preconfigurados** (primario↔secundario, admin↔`named`). **DoT/DoH** — protege la *confidencialidad e integridad de la conversación DNS*, contra un observador pasivo o un atacante en el camino, **solamente en el salto stub↔recursivo**.

2. DoH (RFC 8484) usa 443 y semántica HTTPS estándar para que el tráfico DNS sea **indistinguible del tráfico web ordinario**, previniendo deliberadamente la censura y la intercepción por parte de los operadores de red — eso fue un objetivo de diseño explícito, no un accidente. La consecuencia para un operador es que el DNS ya no puede ser observado, registrado, filtrado ni redirigido a nivel de red: el DNS de horizonte partido, el sinkholing de malware, el control parental y el monitoreo de egreso basado en DNS fallan todos silenciosamente cuando una aplicación trae su propio resolver DoH. DoT en 853 es comparativamente más amigable con el operador — es identificable y bloqueable como puerto, que es por qué las empresas frecuentemente permiten DoT y bloquean DoH.

3. **No es redundante.** DoT autentica y cifra el canal hacia *tu resolver*; no dice nada sobre de dónde sacó ese resolver sus datos. El ataque que no detiene: **que al resolver mismo le alimenten datos forjados desde arriba** — un caché envenenado, un servidor autoritativo secuestrado, un secuestro BGP de la infraestructura autoritativa, o un operador de resolver comprometido/malicioso. La validación DNSSEC (idealmente realizada por el resolver, y la respuesta confiada vía el bit `ad` sobre DoT; o realizada por el propio stub) es lo que detecta eso. Los dos son ortogonales: confidencialidad en el último salto, autenticidad de punta a punta.

4. El stub está confiando en **la honestidad y la corrección del resolver** — en que realmente validó, y en que realmente es el resolver que dice ser. TLS deja sólida la segunda parte pero no hace nada por la primera. Las dos configuraciones que restauran la garantía de punta a punta: (i) correr un **resolver validador en el propio endpoint** (`named`/`unbound`/`systemd-resolved` en modo validador sobre localhost), de modo que no haya ningún bit `ad` de un tercero remoto involucrado; o (ii) que la **aplicación valide**, es decir, consultar con `cd`/`do` y verificar los RRSIG localmente, como hace `delv`. Ambos son casos de "no delegues la decisión de confianza".

5. `kdig +tls-ca[=FILE]` habilita la verificación de la cadena de certificados, y `+tls-hostname=NAME` fuerza el nombre esperado; `+tls-pin=BASE64` fija (pin) el SPKI. DoT **oportunista** (RFC 7858 §4.1) intenta TLS y cae a texto plano o acepta cualquier certificado — derrota solo la vigilancia pasiva, y un atacante activo puede quitarlo o falsificarlo. DoT **estricto** exige un handshake TLS exitoso y autenticado hacia un resolver nombrado y **falla cerrado** si no lo consigue — ese es el modo que realmente resiste a un atacante en el camino, y es el que un despliegue gestionado debería configurar.

6. (i) **Conflicto de puertos y privilegios**: `named` ahora ocupa 443 en esa dirección, así que un servidor web no puede enlazarse a la misma dirección:puerto — necesitás direcciones separadas, o un proxy inverso que termine TLS y enrute por ALPN/ruta al endpoint `/dns-query` de `named`. (ii) **Acoplamiento de certificados y superficie de ataque**: `named` ahora está corriendo una pila TLS + HTTP/2 de cara a lo que sea que pueda alcanzar el 443, que es una superficie de ataque materialmente mayor que un parser UDP/53, y necesita un certificado cuya renovación (ACME) debe estar cableada a un `rndc reconfig`, o los clientes DoH empiezan a fallar. Sumale que el estado de sesión TCP/TLS implica consumo de memoria y de descriptores de archivo por cliente que UDP nunca tuvo, así que `tcp-clients`/`tcp-listen-queue` y el límite de descriptores de archivo necesitan revisión.

### Bloque 11

1. **El validador del resolver está rechazando los datos.** Los datos son alcanzables y sintácticamente correctos pero no validan — firmas bogus, firmas expiradas, o un enlace DS/DNSKEY roto. Confirmá y clasificá con el código EDE: `dig @<resolver> <name> A +dnssec` y leé `; EDE: n`. Después `delv @<resolver> +vtrace <name> A` para ver qué paso falla.

2. **El trust anchor estático está desactualizado** — el padre roló su KSK y tu anchor configurado manualmente todavía nombra la clave retirada, así que la cadena no puede construirse desde tu anchor. Confirmá: `rndc -s <resolver> secroots -` y compará el key tag listado con `dig @<parent> <zone> DNSKEY +multiline`. Arreglalo actualizando el anchor, y preferí `initial-key`/`initial-ds` (mantenidos por RFC 5011) sobre `static-key` para anchors que no rotás personalmente.

3. **Firmas expiradas.** Treinta días es la validez por defecto de `dnssec-signzone` — la automatización de re-firmado dejó de correr (o nunca se programó) y la zona quedó bogus en el momento en que envejeció la última firma. Confirmá: `dnssec-verify -o <zone> <signedfile>` en el servidor autoritativo, o `dig @<auth> <zone> SOA +dnssec +multiline +norec` y leé el campo de expiración del RRSIG contra la fecha actual. Sospechoso secundario con síntomas idénticos: el reloj del *validador* se desvió — chequeá `timedatectl`/`chronyc tracking`.

4. **Desvío de reloj en el resolver del datacenter, o un trust anchor negativo/desactualizado ahí** — la diferencia está en el validador, no en la zona, porque `delv` probó que la zona en sí está bien. Confirmá: `chronyc tracking` (o `timedatectl`) en el resolver que falla, después `rndc -s <r> secroots -` y `rndc -s <r> nta -dump`. Un tercer candidato, si ambos están limpios: que ese resolver no pueda recuperar el DNSKEY/DS en absoluto — mirá el ítem 5.

5. **Fragmentación EDNS/UDP o un middlebox descartando respuestas DNS grandes.** Los RRsets DNSKEY durante un rollover son las respuestas más grandes que produce una zona; los caminos que descartan fragmentos o bloquean DNS sobre TCP hacen que la validación falle desde algunas redes y desde otras no. Confirmá: `dig @<auth> <zone> DNSKEY +dnssec +bufsize=1232 +ignore` versus `+bufsize=4096`, y `dig +tcp` — si 1232 y TCP funcionan y 4096 no, es MTU de camino/fragmentación. Arreglo: limitar `edns-udp-size`/`max-udp-size` a 1232, asegurar que TCP/53 esté permitido de punta a punta, y preferir ECDSA para achicar las respuestas de entrada (Bloque 2 P6).

6. **La zona fue firmada con un conteo de iteraciones NSEC3 por encima de lo que BIND acepta**, según el RFC 9276 y el techo de validación de 150 iteraciones de BIND. Confirmá: `dig @<auth> <zone> NSEC3PARAM +short` — el tercer campo es el conteo de iteraciones. Arreglo: re-firmar con `-H 0` (o `nsec3param iterations 0` bajo `dnssec-policy`). Notá que el lado *validador* trata las iteraciones excesivas como inseguras, así que el síntoma en el cliente es una bandera `ad` silenciosamente ausente en lugar de SERVFAIL.

7. **El DS falta o no coincide** — el padre tiene una delegación NS pero ningún DS (o un DS para una clave que la hija ya no publica), así que el validador concluye correctamente que la hija es una delegación sin firmar y deja de validar. Confirmá: `dig @<parent-ns> <child> DS +dnssec` comparado contra `dig @<child-ns> <child> DNSKEY +multiline`, chequeando que el tag y el digest de una KSK publicada coincidan con un DS. Arreglo: enviar el DS vía el registrador (o `rndc dnssec -checkds published` una vez que esté activo). "Insegura" es el resultado correcto y seguro acá — pero significa que DNSSEC no está haciendo nada por esa zona.

8. **Fallo de TSIG en la transferencia** — uno de BADKEY, BADSIG o BADTIME. Confirmá reproduciendo la transferencia a mano y leyendo la pseudosección TSIG: `dig @<primary> <zone> AXFR -k <keyfile>`. Después acotá: BADKEY → el nombre de clave no está en el `allow-transfer` del primario o no está definido; BADSIG → el `secret` o el `algorithm` difieren entre los dos archivos `named.conf` (un clásico truncamiento por copiar y pegar del base64); BADTIME → desvío de reloj por encima del fudge de 300 s, chequeá `chronyc tracking` en ambos extremos. El log del primario va a nombrar la clave y la razón del fallo en `category security`.

</details>

---

## Fuentes

- LPI, *Exam 303-300 Objectives (LPIC-3 Security, version 3.0)* — https://www.lpi.org/our-certifications/exam-303-objectives/
- ISC, *BIND 9 Administrator Reference Manual*, capítulos sobre `named.conf`, `dnssec-policy`, `tls`/`http`, y la sentencia `controls` — https://bind9.readthedocs.io/en/v9.18/reference.html
- ISC, *BIND 9 DNSSEC Guide* (firmado manual, `dnssec-policy`, rollovers, troubleshooting) — https://bind9.readthedocs.io/en/v9.18/dnssec-guide.html
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
- RFC 6761 — *Special-Use Domain Names* (reserva de `.test`) — https://www.rfc-editor.org/rfc/rfc6761
- OpenSSL Project, `openssl-s_client(1)` — opciones DANE (`-dane_tlsa_domain`, `-dane_tlsa_rrdata`) — https://docs.openssl.org/master/man1/openssl-s_client/
- CZ.NIC, *Knot DNS utilities — `kdig`* (`+tls`, `+https`) — https://www.knot-dns.cz/docs/latest/singlehtml/index.html#kdig
- Sandia National Laboratories, *DNSViz — a DNS visualization tool* — https://dnsviz.net/