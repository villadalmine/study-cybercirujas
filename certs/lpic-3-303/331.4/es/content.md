# 331.4 — DNS y criptografía

**Examen:** LPIC-3 303-300 (Security), versión 3.0.0 · **Peso del tema:** 5/60 → **8.33 %** del examen
**Alcance:** DNSSEC (firma autoritativa + validación recursiva), gestión y rotación de claves, TSIG, DANE, y transportes DNS cifrados (DoT/DoH/DoQ/DNSCrypt).

---

## 1. El problema arquitectónico: DNS es la raíz no autenticada de todo

Toda decisión de confianza en una plataforma moderna arranca desde una resolución de nombre que, en su forma original de 1987, **no tiene autenticación, ni protección de integridad, ni confidencialidad**.

Considerá la cadena de dependencias de una acción rutinaria de producción — emitir un certificado TLS con ACME:

```
cert-manager  →  ACME DNS-01 challenge  →  _acme-challenge.svc.example.net TXT
                                              ↑
                        whoever can answer this record can mint a
                        publicly-trusted certificate for the name
```

Y la cadena para la entrega de correo:

```
sender MTA  →  MX example.net  →  mx1.example.net A  →  TCP/25  →  opportunistic STARTTLS
                    ↑                                                    ↑
        forge this and mail is rerouted              downgrade this and TLS never happens
```

Y para el descubrimiento de servicios dentro de un clúster:

```
kubelet /etc/resolv.conf  →  CoreDNS  →  upstream recursor  →  authoritative
                                              ↑
                        one poisoned cache entry redirects every
                        egress connection from every pod on the node
```

El modelo de amenaza tiene tres capas distintas, y **se resuelven con tres mecanismos diferentes que se confunden con frecuencia**:

| Amenaza | Qué hace el atacante | Mitigación | Qué *no* resuelve |
|---|---|---|---|
| **Falsificación off-path / envenenamiento de caché** | Compite contra la respuesta real con un paquete UDP falsificado (Kaminsky, 2008); adivina el TXID de 16 bits + el puerto origen | **DNSSEC** (autenticación de origen + integridad de los RRsets) | No oculta la consulta; no autentica al *servidor* |
| **Manipulación on-path / downgrade** | El ISP, el portal cautivo del hotel o un middlebox hostil reescribe NXDOMAIN → servidor de publicidad, quita el bit `DO` | **DNSSEC** de extremo a extremo (validación en el stub) + **DoT/DoH/DoQ** para el último tramo | El transporte cifrado por sí solo sigue confiando en lo que diga el resolver |
| **Vigilancia / perfilado** | Observación pasiva del puerto 53 en texto plano; el flujo de consultas es un historial de navegación completo | **DoT / DoH / DoQ / DNSCrypt / ODoH** | No demuestra que la respuesta sea genuina — una mentira cifrada sigue siendo una mentira |

> **El punto conceptual más importante de este objetivo:** DNSSEC y el transporte cifrado son **ortogonales**. DNSSEC te da *autenticidad* sin confidencialidad; DoT/DoH te dan *confidencialidad* (salto a salto) sin autenticidad de los datos en sí. Un diseño de producción necesita ambos, y ninguno sustituye al otro.

### 1.1 Por qué DNSSEC es un problema de SRE, no solo de seguridad

DNSSEC convierte un protocolo sin estado y amigable con la caché en un sistema con **material criptográfico acotado en el tiempo**. Las firmas caducan. Las claves rotan. La zona padre guarda una copia del digest de tu clave que no podés actualizar de forma atómica. Esto crea clases de caída completamente nuevas:

* **RRSIGs vencidos** — la caída de DNSSEC autoinfligida más común. La zona está bien, los servidores están arriba, las firmas están tres horas pasadas de su `Signature Expiration`, y todo resolver validante del planeta devuelve `SERVFAIL`. La zona no está "lenta" — **desapareció**, y sigue desaparecida hasta que vuelvas a firmar, porque el fallo es fail-closed por diseño.
* **Desajuste DS/DNSKEY** — rotaste la KSK y el DS del registrar sigue apuntando a la clave retirada. Mismo resultado: `SERVFAIL` global.
* **El radio de impacto es total y asimétrico.** Una zona sin firmar con un registro malo rompe un nombre. Una firma rota rompe *toda la zona y todo lo que cuelga de ella*, para cada resolver validante, y es invisible para tu propio monitoreo no validante.
* **La recuperación está atada al TTL.** No podés "hacer rollback" de un registro DS más rápido que el TTL del padre (el TTL del DS de `.com` es 86400 s). Diseñá cada rotación de modo que el modo de fallo sea "la clave vieja todavía funciona", nunca "la clave nueva todavía no es confiable".

Por eso las secciones operativas de este tema (temporización de claves, máquinas de estado de rotación, monitoreo) importan tanto como la criptografía.

---

## 2. Fundamentos de DNS de los que depende DNSSEC

DNSSEC no firma *mensajes*. Firma **RRsets**.

Un **RRset** es el conjunto completo de registros con la misma tupla `(owner name, class, type)`. Esta es la unidad atómica de DNSSEC:

```
www.example.net.  3600  IN  A  203.0.113.10
www.example.net.  3600  IN  A  203.0.113.11
```

Esos dos registros forman **un** RRset y están cubiertos por **un** `RRSIG`. Consecuencias que muerden en producción:

* No podés firmar un registro individual. Agregar un registro `A` invalida la firma de todo el RRset.
* Todos los registros de un RRset **deben** compartir el mismo TTL. Un desajuste es un error de carga de zona bajo DNSSEC.
* El `RRSIG` lleva el **Original TTL** para que un validador pueda reconstruir la forma canónica incluso después de que una caché haya decrementado el TTL en tránsito.
* El orden canónico (RFC 4034 §6) — nombres en minúsculas, ordenados en orden canónico de nombres, RDATA ordenado — debe ser reproducido byte a byte por el validador, si no el hash difiere y la validación falla.

### 2.1 Los tipos de registro de recurso de DNSSEC

| Tipo | Código | Vive en | Propósito |
|---|---|---|---|
| `DNSKEY` | 48 | ápex de la zona | Claves públicas usadas para verificar los `RRSIG` de esta zona |
| `RRSIG` | 46 | junto a cada RRset firmado | La firma sobre un RRset |
| `DS` | 43 | zona **padre**, en el punto de delegación | Digest de la KSK del hijo — el eslabón de la cadena de confianza |
| `NSEC` | 47 | zona firmada | Negación autenticada de existencia (siguiente nombre en orden canónico) |
| `NSEC3` | 50 | zona firmada | Negación autenticada de existencia con hash |
| `NSEC3PARAM` | 51 | ápex de la zona | Algoritmo de hash, flags, iteraciones y salt para `NSEC3` |
| `CDS` | 59 | ápex del **hijo** | "Por favor publicá este DS en el padre" (RFC 7344) |
| `CDNSKEY` | 60 | ápex del **hijo** | "Por favor derivá un DS de esta DNSKEY" (RFC 7344) |
| `TLSA` | 52 | `_port._proto.name` | Asociación de certificado DANE (RFC 6698) |
| `SSHFP` | 44 | nombre de host | Huella de la clave de host SSH (RFC 4255) |
| `OPENPGPKEY` | 61 | parte local hasheada | Publicación de clave PGP (RFC 7929) |
| `ZONEMD` | 63 | ápex de la zona | Digest del mensaje sobre toda la zona (RFC 8976) |

### 2.2 Los tres bits de EDNS0 / cabecera que gobiernan todo

| Bit | Puesto por | Significado | Uso diagnóstico |
|---|---|---|---|
| `DO` (DNSSEC OK) | el cliente, en el OPT RR de EDNS0 | "Mandame los registros `RRSIG`/`NSEC`" | `dig +dnssec` lo activa. Si está ausente, no se devuelve criptografía alguna |
| `CD` (Checking Disabled) | el cliente, en la cabecera | "No valides; dame los datos aunque sean bogus" | `dig +cd` — **la herramienta principal de triage**: si `+cd` funciona y sin él falla, es un fallo de validación, no de datos |
| `AD` (Authentic Data) | el **resolver**, en la respuesta | "Validé esto y es seguro" | `dig` lo muestra en `;; flags:`. Nunca confíes en el `AD` de un resolver no confiable sobre un canal no autenticado |

Los cuatro estados de validación (RFC 4035 §4.3):

| Estado | Significado | Comportamiento del resolver |
|---|---|---|
| **Secure** | La cadena completa desde el trust anchor hasta el RRset valida | Respuesta devuelta con `AD` activado |
| **Insecure** | Existe una delegación demostrablemente sin firmar (sin `DS`, probado por `NSEC`/`NSEC3`) | Respuesta devuelta, `AD` sin activar |
| **Bogus** | Existen firmas pero no validan (vencidas, clave incorrecta, manipuladas) | **`SERVFAIL`** |
| **Indeterminate** | No hay trust anchor alcanzable para esta rama | Tratada como insecure |

---

## 3. DNSSEC en profundidad

### 3.1 La cadena de confianza

```
                       root zone "."
                       ┌──────────────────────────────┐
   trust anchor ──────▶│ DNSKEY (KSK-2017, tag 20326) │
   configured out      │ DNSKEY (ZSK)                 │
   of band             │ RRSIG(DNSKEY) by KSK         │
                       │ DS  net.  ◀── digest of net's KSK
                       │ RRSIG(DS) by ZSK             │
                       └──────────────┬───────────────┘
                                      │ delegation
                       ┌──────────────▼───────────────┐
                       │ net. DNSKEY (KSK) (ZSK)      │
                       │ DS  example.net. ◀── digest of example.net's KSK
                       │ RRSIG(DS) by net's ZSK       │
                       └──────────────┬───────────────┘
                                      │ delegation
                       ┌──────────────▼───────────────┐
                       │ example.net. DNSKEY (KSK)(ZSK)│
                       │ www A 203.0.113.10           │
                       │ RRSIG(A) by example.net ZSK  │
                       └──────────────────────────────┘
```

El validador camina **hacia abajo** desde el anchor: verificar el RRset `DNSKEY` con el anchor → usar la ZSK para verificar el RRset `DS` del hijo → hashear la KSK del hijo y compararla con el `DS` → verificar el RRset `DNSKEY` del hijo con su KSK → verificar el `RRSIG` de la respuesta con la ZSK del hijo.

**Notá las dos verificaciones independientes en cada salto:** el `DS` en el padre está firmado por el *padre*, y la `DNSKEY` en el hijo está firmada por el *hijo*. Rompé cualquiera de las dos y la cadena queda bogus.

### 3.2 KSK vs ZSK vs CSK

La división entre Key Signing Key y Zone Signing Key es **puramente operativa**, no criptográfica. Nada en el protocolo la exige — el flag SEP (Secure Entry Point) es orientativo.

| | **KSK** (Key Signing Key) | **ZSK** (Zone Signing Key) | **CSK** (Combined Signing Key) |
|---|---|---|---|
| Flags de DNSKEY | 257 (bit SEP activado) | 256 | 257 |
| Firma | Solo el RRset `DNSKEY` del ápex | Todos los demás RRsets de la zona | Todo |
| Referenciada por el `DS` del padre | **Sí** | No | Sí |
| La rotación requiere interacción con el padre | **Sí** — lenta, fuera de banda, registrar/EPP o CDS | **No** — enteramente dentro de la zona | Sí |
| Vida útil típica | 1–2 años (o ilimitada con automatización CDS) | 30–90 días | 1 año |
| Tamaño típico | RSA-2048/4096, o ECDSA P-256 | RSA-1024/2048, o ECDSA P-256 | ECDSA P-256 |
| Puede vivir offline / en un HSM | **Sí** — de eso se trata todo esto | No, necesita estar online para firmar cambios | No |
| Flag de `dnssec-keygen` | `-f KSK` | (ninguno) | `-f KSK` con una política de clave única |

**Análisis de compromisos:**

* **Dividir KSK/ZSK** vale la pena cuando la KSK está genuinamente protegida de otra manera — medios offline, HSM, un firmante air-gapped. Si ambas claves están en el mismo directorio `/var/lib/bind/keys` con permisos `0600`, la división no te compra más que complejidad y una `DNSKEY` extra en cada respuesta.
* **CSK** es el valor por defecto correcto para zonas pequeñas y medianas con rotación **automatizada por CDS/CDNSKEY** (RFC 8078). Una clave, una máquina de estado, respuestas más chicas.
* Con **ECDSA P-256**, la motivación original de RSA para la división se evapora en buena medida: una clave P-256 son 64 bytes y una firma son 64 bytes, así que el argumento de "mantené la ZSK chica para mantener las respuestas chicas" queda sin efecto.

### 3.3 Selección de algoritmo

| Alg # | Nombre | Tamaño de clave | Tamaño de firma | Estado (RFC 8624 y sucesores) | Veredicto para zonas nuevas |
|---:|---|---:|---:|---|---|
| 1 | RSAMD5 | — | — | **MUST NOT** | Prohibido |
| 3 | DSA | — | — | MUST NOT | Prohibido |
| 5 | RSASHA1 | 1024–4096 | 128–512 B | MUST NOT sign | Migrar de inmediato |
| 7 | RSASHA1-NSEC3-SHA1 | 1024–4096 | 128–512 B | MUST NOT sign | Migrar de inmediato |
| 8 | RSASHA256 | 2048–4096 | 256–512 B | MUST implement, MAY sign | Aceptable; la zona raíz lo usa |
| 10 | RSASHA512 | 2048–4096 | 256–512 B | NOT RECOMMENDED | Evitar — no aporta nada sobre el 8 |
| 12 | ECC-GOST | — | — | MUST NOT | Prohibido |
| 13 | **ECDSAP256SHA256** | 32 B | 64 B | **MUST implement / RECOMMENDED** | **Elección por defecto** |
| 14 | ECDSAP384SHA384 | 48 B | 96 B | MAY | Solo si una política exige seguridad de 192 bits |
| 15 | **ED25519** | 32 B | 64 B | RECOMMENDED | Excelente, pero el soporte de validadores todavía no es universal |
| 16 | ED448 | 57 B | 114 B | MAY | Soporte de validadores escaso |

**Por qué el algoritmo 13 es el valor por defecto en producción:** un RRset `DNSKEY` con dos claves P-256 más su `RRSIG` entra cómodamente en un payload UDP de 1232 bytes, eliminando el fallback a TCP y los fallos por fragmentación IP. La misma zona con KSK + ZSK RSA-2048 produce una respuesta `DNSKEY` de alrededor de 1 kB, y una rotación de KSK la empuja más allá de los 1500 bytes — exactamente la condición que el DNS Flag Day 2020 se creó para atacar.

**Advertencia sobre Ed25519:** si firmás solo con el algoritmo 15, los resolvers que no lo implementan tratan la zona como **insecure** (no bogus) — perdés la protección en silencio en vez de romper. Eso es seguro pero inútil. No hagas "doble firma" con 13 + 15 salvo que hayas medido una necesidad real; las zonas multi-algoritmo deben mantener un conjunto completo de firmas por algoritmo y aproximadamente duplican el tamaño de la respuesta.

### 3.4 El Key Tag

El **Key Tag** es una pista de 16 bits que permite a un validador elegir la `DNSKEY` correcta del RRset sin probar la verificación con todas. Aparece en `RRSIG` (campo 7), en `DS` (campo 1), y en el nombre de archivo de `dnssec-keygen`.

Propiedades críticas:

* **No** es un identificador criptográfico. Es un checksum sobre el RDATA de la `DNSKEY`.
* **No** es único. Las colisiones son posibles y legales; un validador que encuentre dos claves con el mismo tag debe probar ambas.
* Cambia cuando cambia la clave — que es exactamente lo que lo vuelve un identificador operativo útil.

RFC 4034 Apéndice B, para todos los algoritmos excepto el 1:

```python
def keytag(rdata: bytes) -> int:
    """rdata = wire-format DNSKEY RDATA: flags(2) | protocol(1) | algorithm(1) | pubkey"""
    ac = 0
    for i, b in enumerate(rdata):
        ac += b if (i & 1) else (b << 8)
    ac += (ac >> 16) & 0xFFFF
    return ac & 0xFFFF
```

La convención de nombres de archivo lo codifica directamente:

```
Kexample.net.+013+34505.key
 │           │   │
 │           │   └── key tag (34505)
 │           └────── algorithm (13 = ECDSAP256SHA256)
 └────────────────── zone name
```

### 3.5 Negación autenticada de existencia

Firmar una respuesta NXDOMAIN al vuelo exigiría tener la clave privada online para cada consulta y habilitaría un DoS trivial por oráculo de firmas. En su lugar, DNSSEC precalcula **pruebas de no existencia**.

**NSEC** — una lista enlazada sobre los nombres de la zona ordenados canónicamente:

```
example.net.        3600 IN NSEC mail.example.net. A NS SOA MX RRSIG NSEC DNSKEY
mail.example.net.   3600 IN NSEC www.example.net.  A AAAA RRSIG NSEC
www.example.net.    3600 IN NSEC example.net.      A RRSIG NSEC
```

Una consulta por `nope.example.net` devuelve el `NSEC` de `mail.` probando que no existe nada entre `mail.` y `www.` — lo que también **revela que `mail` y `www` existen**. Recorrer la cadena enumera la zona entera.

**NSEC3** — la misma idea sobre **hashes SHA-1** de los nombres, con un salt y un contador de iteraciones, para que la enumeración cueste dinero en vez de ser gratis.

| | **NSEC** | **NSEC3** | **NSEC3 + opt-out** |
|---|---|---|---|
| Enumeración de la zona | Trivial (`ldns-walk`) | Requiere diccionario/fuerza bruta offline contra SHA-1 | Igual que NSEC3 |
| Costo de firma | El más bajo | Mayor (hashear cada nombre) | Menor que NSEC3 puro |
| Tamaño de la zona | 1 NSEC por nombre | 1 NSEC3 por nombre + `NSEC3PARAM` | 1 NSEC3 solo por delegación *segura* |
| Tamaño de la respuesta | El más chico | Mayor (2–3 registros NSEC3 por NXDOMAIN) | Mayor |
| Costo de CPU en el validador | Ninguno | `iterations + 1` operaciones SHA-1 por hash | Igual |
| Delegaciones inseguras | Cada una se prueba individualmente | Cada una se prueba individualmente | **No se prueban** — los hijos sin firmar quedan sin autenticar |
| Caso de uso correcto | Zonas públicas sin nada que ocultar; **el valor por defecto** | Zonas donde los nombres son sensibles; zonas que necesitan opt-out | **Solo TLDs y registros enormes** |

**El RFC 9276 no es una guía opcional — tratalo como una regla dura:**

```
nsec3param iterations 0 optout no salt-length 0;
```

* **Las iteraciones DEBEN ser 0.** Las iteraciones extra dan una protección insignificante (un atacante con un diccionario gana igual) y le entregan a cualquier cliente un vector de amplificación de CPU contra tus validadores. BIND ≥ 9.16.9 se niega a *servir* zonas con recuentos altos de iteraciones y trata > 150 como insecure; BIND 9.20 rechaza > 0 en `dnssec-policy`.
* **El salt DEBE estar vacío.** El salt solo defiende contra una tabla arcoíris *precalculada* para todo el espacio de nombres DNS — que nadie construye, porque el owner name ya está en la entrada del hash.
* **Opt-out solo para zonas a escala de registro.** En una zona empresarial, opt-out significa que un atacante puede insertar una delegación falsa sin firmar y vos no podés probar que no existía.

Si la privacidad de la zona es el requisito real, NSEC3 es la herramienta equivocada — retrasa la enumeración por horas, no para siempre. Usá una vista interna separada o DNS con split-horizon.

---

## 4. BIND 9 como firmante autoritativo

Hay tres modelos de firma. Conocé los tres: el objetivo del examen nombra las herramientas manuales, producción usa la automatizada.

| Modelo | Herramientas | ¿Clave privada online? | Latencia de cambio de zona | Rotación | Usar cuando |
|---|---|---|---|---|---|
| **Offline / manual** | `dnssec-keygen`, `dnssec-signzone`, `dnssec-settime`, cron | No — el firmante puede estar air-gapped | Minutos a horas (volver a firmar toda la zona) | Máquina de estado manual | Requisito regulatorio de KSK offline; zonas de altísimo valor |
| **Firma inline con `dnssec-policy`** | `named` + `rndc dnssec` | Sí (o vía PKCS#11) | Segundos | **Automática**, CDS RFC 7344 | **Valor por defecto para casi todo** |
| **Actualización dinámica + `dnssec-policy`** | `nsupdate`/RFC 2136 + `named` | Sí | Inmediata | Automática | ACME DNS-01, cert-manager, DDNS |

### 4.1 El camino moderno — `dnssec-policy`

Introducido en BIND 9.16 y la única forma sensata de correr DNSSEC a escala. Reemplaza toda la era de `auto-dnssec` / `dnssec-keymgr` / cron-jobs con una política declarativa y una máquina de estado de claves integrada que respeta los TTL y los retrasos de propagación.

**`/etc/bind/named.conf` — primario autoritativo completo:**

```conf
// ---------------------------------------------------------------------------
// /etc/bind/named.conf  --  authoritative primary, DNSSEC-signed
// BIND 9.20.x
// ---------------------------------------------------------------------------

include "/etc/bind/tsig/xfr-key.conf";      // TSIG key, mode 0640 root:bind
include "/etc/bind/tsig/rndc-key.conf";

acl "secondaries" {
    192.0.2.53;                 // ns2.example.net
    198.51.100.53;              // ns3.example.net
    2001:db8:2::53;
};

acl "monitoring" {
    10.20.0.0/16;               // Prometheus / blackbox exporter
};

options {
    directory              "/var/cache/bind";
    managed-keys-directory "/var/cache/bind/keys";
    key-directory          "/var/lib/bind/keys";     // 0700 bind:bind
    pid-file               "/run/named/named.pid";
    session-keyfile        "/run/named/session.key";

    listen-on       port 53 { 192.0.2.1; 127.0.0.1; };
    listen-on-v6    port 53 { 2001:db8:1::53; ::1; };

    // Authoritative-only: never recurse, never cache for clients.
    recursion no;
    allow-query        { any; };
    allow-query-cache  { none; };
    allow-transfer     { none; };            // overridden per zone, with TSIG
    allow-update       { none; };
    allow-notify       { none; };
    notify             explicit;

    // DNS Flag Day 2020: keep UDP payloads under the common 1500-byte MTU
    // to avoid IP fragmentation, which firewalls drop and which is a
    // spoofing vector (RFC 8900).
    edns-udp-size      1232;
    max-udp-size       1232;

    // Rate-limit the reflection/amplification surface.
    rate-limit {
        responses-per-second 15;
        nxdomains-per-second 5;
        errors-per-second    5;
        slip                 2;
        window               5;
        exempt-clients       { "monitoring"; 127.0.0.1; };
    };

    minimal-responses    yes;
    version              none;
    hostname             none;
    server-id            none;

    // Signing/serving policy defaults
    dnssec-validation    no;                 // authoritative-only: nothing to validate
    max-zone-ttl         1d;                 // must match dnssec-policy max-zone-ttl
    zone-statistics      full;
};

statistics-channels {
    inet 127.0.0.1 port 8053 allow { 127.0.0.1; };
};

controls {
    inet 127.0.0.1 port 953 allow { 127.0.0.1; } keys { "rndc-key"; };
};

logging {
    channel "dnssec_log" {
        file "/var/log/named/dnssec.log" versions 10 size 20m;
        severity debug 3;
        print-time  yes;
        print-category yes;
        print-severity yes;
    };
    channel "general_log" {
        file "/var/log/named/general.log" versions 5 size 50m;
        severity info;
        print-time yes;
        print-category yes;
    };
    channel "xfer_log" {
        file "/var/log/named/xfer.log" versions 5 size 20m;
        severity info;
        print-time yes;
    };
    category dnssec        { "dnssec_log"; };
    category dnstap        { "null"; };
    category xfer-out      { "xfer_log"; };
    category xfer-in       { "xfer_log"; };
    category notify        { "xfer_log"; };
    category security      { "general_log"; };
    category default       { "general_log"; };
};

// ---------------------------------------------------------------------------
// DNSSEC policy
// ---------------------------------------------------------------------------
dnssec-policy "prod-ecdsa" {
    keys {
        ksk key-directory lifetime P2Y  algorithm ecdsap256sha256;
        zsk key-directory lifetime P90D algorithm ecdsap256sha256;
    };

    // How long a DNSKEY RRset may be cached. Drives the rollover timing math.
    dnskey-ttl                  PT1H;       // 3600 s

    // The largest TTL that may appear anywhere in the zone. named enforces it.
    max-zone-ttl                P1D;

    // Signature lifetime and how early to refresh. Refresh MUST be well below
    // validity: the difference is your entire outage budget if signing stops.
    signatures-validity         P14D;
    signatures-validity-dnskey  P14D;
    signatures-refresh          P5D;        // ~9 days of slack
    signatures-jitter           PT12H;      // avoid a thundering-herd re-sign

    // Propagation model -- how long until every secondary and every cache
    // has seen a change. Be generous; the cost of being generous is a slower
    // rollover, the cost of being optimistic is a global SERVFAIL.
    zone-propagation-delay      PT10M;
    parent-propagation-delay    PT2H;
    parent-ds-ttl               PT1H;       // must match the parent's real DS TTL
    publish-safety              PT1H;
    retire-safety               PT1H;
    purge-keys                  P90D;

    // RFC 9276: iterations 0, no salt, no opt-out.
    nsec3param                  iterations 0 optout no salt-length 0;

    // RFC 7344 / 8078: publish CDS+CDNSKEY so the parent can automate the DS.
    cds-digest-types            { "sha-256"; };
};

// ---------------------------------------------------------------------------
// Zones
// ---------------------------------------------------------------------------
zone "example.net" IN {
    type primary;
    file "/var/lib/bind/zones/db.example.net";

    dnssec-policy "prod-ecdsa";
    inline-signing yes;          // implicit from 9.19+, explicit here for clarity

    allow-transfer   { key "xfr-key"; };
    also-notify      { 192.0.2.53 key "xfr-key";
                       198.51.100.53 key "xfr-key"; };
    notify           explicit;

    // Ask these servers whether our DS has appeared in the parent, so the
    // KSK rollover state machine can advance without human intervention.
    parental-agents  { "net-servers"; };
    checkds          explicit;
};

parental-agents "net-servers" {
    192.5.6.30;                  // a.gtld-servers.net
    192.33.14.30;                // b.gtld-servers.net
};

zone "113.0.203.in-addr.arpa" IN {
    type primary;
    file "/var/lib/bind/zones/db.203.0.113";
    dnssec-policy "prod-ecdsa";
    inline-signing yes;
    allow-transfer { key "xfr-key"; };
    also-notify    { 192.0.2.53 key "xfr-key"; };
};
```

**El archivo de zona sin firmar** — notá que no contiene material DNSSEC en absoluto. Con firma inline, `named` mantiene la copia firmada en un journal/archivo `.signed` separado y nunca editás datos firmados a mano.

```dns
; /var/lib/bind/zones/db.example.net
$TTL 3600
$ORIGIN example.net.

@   IN  SOA ns1.example.net. hostmaster.example.net. (
                2026082001  ; serial   (YYYYMMDDnn)
                7200        ; refresh  2h
                3600        ; retry    1h
                1209600     ; expire   14d
                3600 )      ; minimum / negative TTL

@           IN  NS      ns1.example.net.
@           IN  NS      ns2.example.net.
@           IN  NS      ns3.example.net.

@           IN  MX  10  mx1.example.net.
@           IN  MX  20  mx2.example.net.

@           IN  CAA 0   issue "letsencrypt.org"
@           IN  CAA 0   iodef "mailto:security@example.net"

@           IN  TXT     "v=spf1 mx -all"

ns1         IN  A       192.0.2.1
ns1         IN  AAAA    2001:db8:1::53
ns2         IN  A       192.0.2.53
ns2         IN  AAAA    2001:db8:2::53
ns3         IN  A       198.51.100.53

mx1         IN  A       203.0.113.25
mx2         IN  A       203.0.113.26

www         IN  A       203.0.113.10
www         IN  A       203.0.113.11
www         IN  AAAA    2001:db8:3::10

api         IN  A       203.0.113.20

; DANE records -- see section 7
_25._tcp.mx1   IN  TLSA 3 1 1 (
                    8A9E1B4F2C0D77A3E5619B8C4D2F0A6E
                    3B7C1D95F84A20E6C3D71B0F5A94E28C )
_443._tcp.www  IN  TLSA 3 1 1 (
                    D4C8F1A2B7E390654C1D8B2FA07E63C9
                    18B4D70A2E5C9F3168B0DA47C25E19F8 )
```

**Ponerlo en marcha:**

```
$ sudo named-checkconf -z /etc/bind/named.conf
zone example.net/IN: loaded serial 2026082001
zone 113.0.203.in-addr.arpa/IN: loaded serial 2026082001

$ sudo systemctl restart named

$ sudo rndc status
version: BIND 9.20.4-1 (Extended Support Version) <id:...>
running on signer01: Linux x86_64 6.12.0-1-amd64
boot time: Thu, 20 Aug 2026 10:58:41 GMT
last configured: Thu, 20 Aug 2026 10:58:41 GMT
configuration file: /etc/bind/named.conf
CPUs found: 8
worker threads: 8
number of zones: 4 (0 automatic)
debug level: 0
xfers running: 0
xfers deferred: 0
soa queries in progress: 0
query logging is OFF
recursive clients: 0/900/1000
tcp clients: 0/150
TCP high-water: 0
server is up and running
```

```
$ sudo grep -E 'dnssec|key' /var/log/named/dnssec.log | tail -12
20-Aug-2026 10:59:12.104 dnssec: info: keymgr: DNSKEY example.net/ECDSAP256SHA256/34505 (KSK) created for policy prod-ecdsa
20-Aug-2026 10:59:12.109 dnssec: info: keymgr: DNSKEY example.net/ECDSAP256SHA256/51230 (ZSK) created for policy prod-ecdsa
20-Aug-2026 10:59:12.115 dnssec: info: keymgr: DNSKEY example.net/ECDSAP256SHA256/34505 (KSK) is now published
20-Aug-2026 10:59:12.115 dnssec: info: keymgr: DNSKEY example.net/ECDSAP256SHA256/51230 (ZSK) is now published
20-Aug-2026 10:59:12.118 dnssec: info: zone example.net/IN (signed): reconfiguring zone keys
20-Aug-2026 10:59:12.121 dnssec: info: zone example.net/IN (signed): next key event: 20-Aug-2026 11:59:12.115
20-Aug-2026 10:59:12.402 dnssec: info: zone example.net/IN (signed): sending notifies (serial 2026082002)
```

```
$ ls -l /var/lib/bind/keys/
total 16
-rw-r--r-- 1 bind bind  435 Aug 20 10:59 Kexample.net.+013+34505.key
-rw------- 1 bind bind  187 Aug 20 10:59 Kexample.net.+013+34505.private
-rw-r--r-- 1 bind bind  601 Aug 20 10:59 Kexample.net.+013+34505.state
-rw-r--r-- 1 bind bind  431 Aug 20 10:59 Kexample.net.+013+51230.key
-rw------- 1 bind bind  187 Aug 20 10:59 Kexample.net.+013+51230.private
-rw-r--r-- 1 bind bind  598 Aug 20 10:59 Kexample.net.+013+51230.state
```

El archivo `.state` es la máquina de estado persistente del gestor de claves — **respaldalo junto con las claves privadas**; sin él `named` vuelve a derivar valores por defecto conservadores y puede trabar una rotación.

```
$ cat /var/lib/bind/keys/Kexample.net.+013+34505.state
; This is the state of key 34505, for example.net.
Algorithm: 13
Length: 256
Lifetime: 63072000
KSK: yes
ZSK: no
Generated: 20260820105912 (Thu Aug 20 10:59:12 2026)
Published: 20260820105912 (Thu Aug 20 10:59:12 2026)
Active: 20260820105912 (Thu Aug 20 10:59:12 2026)
Retired: 20280819105912 (Sat Aug 19 10:59:12 2028)
Removed: 20280819135912 (Sat Aug 19 13:59:12 2028)
DNSKEYChange: 20260820105912 (Thu Aug 20 10:59:12 2026)
KRRSIGChange: 20260820105912 (Thu Aug 20 10:59:12 2026)
DSChange: 20260820105912 (Thu Aug 20 10:59:12 2026)
DNSKEYState: rumoured
KRRSIGState: rumoured
DSState: hidden
GoalState: omnipresent
```

**Los cuatro estados de clave** — este vocabulario es el que habla `rndc dnssec -status`:

| Estado | Significado |
|---|---|
| `hidden` | El registro no está publicado y ninguna caché lo tiene |
| `rumoured` | Publicado, pero puede que las cachés todavía no lo tengan |
| `omnipresent` | Publicado el tiempo suficiente como para que toda caché que pudiera tenerlo, lo tenga |
| `unretentive` | Retirado, pero cachés obsoletas todavía pueden servirlo |

Solo se puede confiar en una clave para validación una vez que su `DNSKEY` está `omnipresent`; solo se la puede eliminar una vez que sus firmas están `hidden`. Ese es todo el argumento de seguridad de la máquina de rotación.

**Estado en vivo:**

```
$ sudo rndc dnssec -status example.net
dnssec-policy: prod-ecdsa
current time:  Thu Aug 20 12:04:11 2026

key: 34505 (ECDSAP256SHA256), KSK
  published:      yes - since Thu Aug 20 10:59:12 2026
  key signing:    yes - since Thu Aug 20 10:59:12 2026

  Key is waiting to be published in the parent zone.
  Waiting for DS to be published in the parent (checkds explicit).

key: 51230 (ECDSAP256SHA256), ZSK
  published:      yes - since Thu Aug 20 10:59:12 2026
  zone signing:   yes - since Thu Aug 20 11:59:12 2026

  Next rollover scheduled on Tue Nov 17 10:59:12 2026
  - goal:           omnipresent
  - dnskey:         omnipresent
  - zone rrsig:     omnipresent
```

**Extraer el DS para entregárselo al registrar:**

```
$ dnssec-dsfromkey -a SHA-256 /var/lib/bind/keys/Kexample.net.+013+34505.key
example.net. IN DS 34505 13 2 6C2A9F3E17B4D08C5E19A6B27F40D3C8B195E62A4F0D7C31 \
                            B8E5A94206DF13C7

$ dig +short @192.0.2.1 example.net CDS
34505 13 2 6C2A9F3E17B4D08C5E19A6B27F40D3C8B195E62A4F0D7C31B8E5A94206DF13C7

$ dig +short @192.0.2.1 example.net CDNSKEY
257 3 13 mdsswUyr3DPW132mOi8V9xESWE8jTo0dxCjjnopKl+GqJxpVXckHAeF+ KkxLbxILfDLUT0rAK9iUzy1L53eKGQ==
```

Enviá el `DS` al registrar (EPP, consola web o proveedor de Terraform). Después decile a BIND que el padre ya lo tiene:

```
$ sudo rndc dnssec -checkds -key 34505 published example.net
$ sudo rndc dnssec -status example.net | head -8
dnssec-policy: prod-ecdsa
current time:  Thu Aug 20 15:41:02 2026

key: 34505 (ECDSAP256SHA256), KSK
  published:      yes - since Thu Aug 20 10:59:12 2026
  key signing:    yes - since Thu Aug 20 10:59:12 2026
  parent ds:      yes - since Thu Aug 20 15:41:02 2026
```

Con `checkds explicit` y `parental-agents` funcionando, BIND consulta al padre por su cuenta y hace avanzar la máquina de estado sin ningún paso humano.

### 4.2 El camino manual — `dnssec-keygen` / `dnssec-signzone`

Sigue siendo conocimiento obligatorio para el examen, y sigue siendo la arquitectura correcta cuando la KSK debe vivir en una máquina offline.

**Generar claves:**

```
$ cd /var/lib/bind/keys
$ sudo -u bind dnssec-keygen -a ECDSAP256SHA256 -f KSK -n ZONE example.net
Generating key pair.
Kexample.net.+013+34505

$ sudo -u bind dnssec-keygen -a ECDSAP256SHA256 -n ZONE example.net
Generating key pair.
Kexample.net.+013+51230
```

Flags útiles:

| Flag | Significado |
|---|---|
| `-a <alg>` | Algoritmo. Desde BIND 9.16 el valor por defecto es `ECDSAP256SHA256` |
| `-b <bits>` | Tamaño de clave — obligatorio para RSA, ignorado/fijo para ECDSA y EdDSA |
| `-f KSK` | Activa el bit SEP (flags 257) |
| `-f REVOKE` | Activa el bit REVOKE (flags 385) — RFC 5011 |
| `-n ZONE` | Tipo de propietario. `HOST` para claves de host TSIG/SIG(0) |
| `-3` | Usar un algoritmo compatible con NSEC3 (heredado; solo relevante para RSASHA1) |
| `-P`/`-A`/`-I`/`-D` | Tiempos de Publish / Activate / Inactive / Delete |
| `-P sync` / `-D sync` | Tiempos de publicación y borrado de CDS/CDNSKEY |
| `-L <ttl>` | TTL por defecto para el registro DNSKEY |
| `-K <dir>` | Directorio de claves |
| `-S <keyfile>` | Crear una clave sucesora para una rotación suave |

**Inspeccionar la clave pública:**

```
$ cat Kexample.net.+013+34505.key
; This is a key-signing key, keyid 34505, for example.net.
; Created: 20260820105912 (Thu Aug 20 10:59:12 2026)
; Publish: 20260820105912 (Thu Aug 20 10:59:12 2026)
; Activate: 20260820105912 (Thu Aug 20 10:59:12 2026)
example.net. IN DNSKEY 257 3 13 mdsswUyr3DPW132mOi8V9xESWE8jTo0dxCjjnopKl+Gq
JxpVXckHAeF+KkxLbxILfDLUT0rAK9iUzy1L53eKGQ==
```

Campo por campo: `257` = flags (ZONE + SEP), `3` = protocolo (siempre 3), `13` = algoritmo, y luego el base64 de la clave pública en crudo.

**Incluir las claves y firmar:**

```
$ sudo -u bind sh -c 'cat /var/lib/bind/keys/K example.net.+013+*.key >> \
      /var/lib/bind/zones/db.example.net'

$ cd /var/lib/bind/zones
$ sudo -u bind dnssec-signzone -A -3 - -H 0 -N INCREMENT -o example.net \
      -K /var/lib/bind/keys -S -x -t db.example.net
Fetching example.net/ECDSAP256SHA256/34505 (KSK) from key repository.
Fetching example.net/ECDSAP256SHA256/51230 (ZSK) from key repository.
Verifying the zone using the following algorithms: ECDSAP256SHA256.
Zone fully signed:
Algorithm: ECDSAP256SHA256: KSKs: 1 active, 0 stand-by, 0 revoked
                            ZSKs: 1 active, 0 stand-by, 0 revoked
db.example.net.signed
Signatures generated:                       31
Signatures retained:                         0
Signatures dropped:                          0
Signatures successfully verified:            0
Signatures unsuccessfully verified:          0
Signing time in seconds:                 0.019
Signatures per second:                1631.578
Runtime in seconds:                      0.031
```

| Flag | Significado |
|---|---|
| `-o <origin>` | Origen de la zona (por defecto el nombre de archivo — ponelo siempre explícitamente) |
| `-S` | Firma inteligente: lee los metadatos de las claves y respeta Publish/Activate/Inactive |
| `-3 <salt>` | Generar NSEC3; `-` significa **sin salt** (RFC 9276) |
| `-H <n>` | Iteraciones de NSEC3; **`0`** |
| `-A` | Opt-out de NSEC3 **desactivado** para el ápex de la zona / delegaciones inseguras (`-AA` habilita opt-out) |
| `-x` | Firmar el RRset `DNSKEY` **solo** con la KSK (respuestas más chicas) |
| `-N INCREMENT` | Incrementar el serial del SOA automáticamente |
| `-t` | Imprimir estadísticas de firma |
| `-s`/`-e` | Inicio/vencimiento de la firma (`now-1h`, `now+30d`) |
| `-K <dir>` | Directorio de claves |
| `-P` | Desactivar la verificación post-firma (no usar) |

**Verificar antes de servir:**

```
$ dnssec-verify -o example.net db.example.net.signed
Loading zone 'example.net' from file 'db.example.net.signed'
Verifying the zone using the following algorithms: ECDSAP256SHA256.
Zone fully signed:
Algorithm: ECDSAP256SHA256: KSKs: 1 active, 0 stand-by, 0 revoked
                            ZSKs: 1 active, 0 stand-by, 0 revoked

$ named-checkzone -D -o example.net example.net db.example.net.signed
zone example.net/IN: loaded serial 2026082002 (DNSSEC signed)
OK
```

Apuntá la zona a `db.example.net.signed` y después hacé `rndc reload example.net`.

**La trampa del modelo manual:** las firmas vencen 30 días después de firmar por defecto (`-e now+30d`). Si tu cron job de re-firma muere en silencio, la zona queda bogus el día 30 sin ningún aviso. Un cron mínimo y honesto:

```bash
#!/usr/bin/env bash
# /usr/local/sbin/resign-zones.sh -- re-sign every 7 days, alert loudly on failure
set -Eeuo pipefail

ZONEDIR=/var/lib/bind/zones
KEYDIR=/var/lib/bind/keys
ZONES=(example.net 113.0.203.in-addr.arpa)

trap 'logger -p daemon.crit -t resign "FAILED signing ${z:-?} at line $LINENO"; exit 1' ERR

for z in "${ZONES[@]}"; do
    tmp=$(mktemp "${ZONEDIR}/.${z}.XXXXXX")
    dnssec-signzone -S -x -A -3 - -H 0 -N INCREMENT \
        -o "$z" -K "$KEYDIR" \
        -s now-3600 -e now+21d \
        -f "$tmp" "${ZONEDIR}/db.${z}"
    dnssec-verify -o "$z" "$tmp"
    install -o bind -g bind -m 0640 "$tmp" "${ZONEDIR}/db.${z}.signed"
    rm -f "$tmp"
    rndc reload "$z"
    logger -p daemon.info -t resign "re-signed ${z}"
done
```

Fijate en `-e now+21d` con una cadencia de 7 días: **tres ejecuciones fallidas antes de una caída**, no cero.

### 4.3 KSK offline y almacenamiento en HSM

El soporte nativo de PKCS#11 fue **eliminado en BIND 9.18**. El almacenamiento de claves en un HSM ahora pasa por OpenSSL:

* **Provider de OpenSSL 3.x:** `pkcs11-provider`, configurado en `openssl.cnf`.
* **Engine de OpenSSL 1.1.x:** `engine_pkcs11` / `libp11` con `engine-pkcs11` en `named.conf` (`OPENSSL_CONF`).

```
$ dnssec-keyfromlabel -E pkcs11 -a ECDSAP256SHA256 -f KSK \
      -l "token=DNSSEC;object=example-net-ksk;pin-source=/etc/bind/hsm.pin" example.net
Kexample.net.+013+34505
```

El archivo `.private` entonces contiene una referencia a una etiqueta en vez de material de clave:

```
$ cat Kexample.net.+013+34505.private
Private-key-format: v1.3
Algorithm: 13 (ECDSAP256SHA256)
Engine: pkcs11
Label: token=DNSSEC;object=example-net-ksk;pin-source=/etc/bind/hsm.pin
```

BIND 9.21 agrega soporte de **KSK offline** (`offline-ksk yes;` en una `dnssec-policy`), donde la KSK firma el RRset `DNSKEY` fuera de banda hacia un archivo Signed Key Response (SKR) que consume el firmante online. Sabé que existe; es la respuesta a "la KSK nunca debe tocar un host conectado a la red".

---

## 5. Rotación de claves

### 5.1 Las dos formas de rotación

**Rotación de ZSK — Pre-Publish.** Barata, sin participación del padre.

```
 t0            t1                  t2                  t3
 │             │                   │                   │
 ├─ ZSK-A signs the zone
 │             ├─ publish ZSK-B in DNSKEY (not signing yet)
 │             │   wait ≥ dnskey-ttl + propagation
 │             │                   ├─ switch: ZSK-B signs, ZSK-A stops
 │             │                   │   wait ≥ max-zone-ttl + propagation
 │             │                   │                   ├─ remove ZSK-A
```

Por qué pre-publish y no doble firma: mantiene chico el RRset `DNSKEY` (solo una clave extra) y nunca duplica la cantidad de `RRSIG` en la zona. La invariante es *"la clave necesaria para verificar cualquier RRSIG en caché está siempre en el RRset DNSKEY publicado"*.

**Rotación de KSK — Double-DS (o Double-KSK).** Cara, requiere al padre.

```
 t0            t1                    t2                    t3
 │             │                     │                     │
 ├─ KSK-A, DS(A) in parent
 │             ├─ publish DS(B) in the parent alongside DS(A)
 │             │   wait ≥ parent-ds-ttl + parent-propagation-delay
 │             │                     ├─ publish KSK-B, sign DNSKEY with B, drop A
 │             │                     │   wait ≥ dnskey-ttl + propagation
 │             │                     │                     ├─ remove DS(A)
```

| | **Double-DS** | **Double-KSK (doble firma)** |
|---|---|---|
| Orden | Primero el DS, después la clave | Primero la clave, después el DS |
| Tamaño del RRset `DNSKEY` durante la rotación | Sin cambios | Dos KSKs + dos `RRSIG(DNSKEY)` |
| Interacciones con el padre | 2 (agregar DS, quitar DS) | 2 |
| Riesgo si el padre es lento | **Ninguno** — DS(B) simplemente no se usa | La clave nueva está viva antes de que llegue el DS solo si invertís el orden |
| Riesgo de tamaño de respuesta | Bajo | Puede exceder 1232 B con RSA |
| Valor por defecto de `dnssec-policy` en BIND | **Double-DS** | — |

**Double-DS es el valor por defecto correcto** precisamente porque el paso lento, humano y propenso a errores (el registrar) ocurre **primero**, mientras la clave vieja sigue plenamente funcional. Si el registrar tarda tres semanas, no se rompe nada.

### 5.2 Rotación automatizada con `dnssec-policy`

No hay nada que hacer — el `lifetime` de la política la dispara. Para forzar una antes de tiempo (sospecha de compromiso):

```
$ sudo rndc dnssec -rollover -key 51230 example.net

$ sudo rndc dnssec -status example.net
dnssec-policy: prod-ecdsa
current time:  Thu Aug 20 16:12:44 2026

key: 34505 (ECDSAP256SHA256), KSK
  published:      yes - since Thu Aug 20 10:59:12 2026
  key signing:    yes - since Thu Aug 20 10:59:12 2026
  parent ds:      yes - since Thu Aug 20 15:41:02 2026

key: 51230 (ECDSAP256SHA256), ZSK
  published:      yes - since Thu Aug 20 10:59:12 2026
  zone signing:   yes - since Thu Aug 20 11:59:12 2026

  Key will retire on Thu Aug 20 17:12:44 2026
  - goal:           hidden
  - dnskey:         omnipresent
  - zone rrsig:     omnipresent

key: 09417 (ECDSAP256SHA256), ZSK
  published:      yes - since Thu Aug 20 16:12:44 2026
  zone signing:   no

  Key is not yet signing the zone.
  - goal:           omnipresent
  - dnskey:         rumoured
  - zone rrsig:     hidden
```

Notá que la máquina se niega a hacer firmar a la ZSK-09417 hasta que su `DNSKEY` alcance `omnipresent` — es decir, hasta que haya transcurrido `dnskey-ttl + publish-safety + zone-propagation-delay`. **No podés forzar esto de forma segura, y no deberías intentarlo.**

Para la KSK, una vez que el nuevo DS está vivo en el padre y el viejo fue eliminado:

```
$ sudo rndc dnssec -checkds -key 34505 withdrawn example.net
```

### 5.3 Rotación manual con `dnssec-settime`

`dnssec-settime` edita los metadatos de temporización dentro del par `.key`/`.private`. Los tiempos son absolutos (`YYYYMMDDHHMMSS`), relativos a ahora (`+30d`), o relativos a otro evento.

| Metadato | Flag | Significado |
|---|---|---|
| Created | — | Fijado en la generación, inmutable |
| Publish | `-P` | Aparece en el RRset `DNSKEY` |
| Activate | `-A` | Empieza a producir firmas |
| Revoke | `-R` | Bit REVOKE activado (solo para anchors RFC 5011) |
| Inactive | `-I` | Deja de producir firmas nuevas (las viejas siguen válidas) |
| Delete | `-D` | Se elimina del RRset `DNSKEY` |
| SyncPublish | `-P sync` | Se publican `CDS`/`CDNSKEY` |
| SyncDelete | `-D sync` | Se retiran `CDS`/`CDNSKEY` |

La única regla de orden que previene caídas: **`Publish` ≤ `Activate` ≤ `Inactive` ≤ `Delete`**, con `Activate − Publish ≥ dnskey_ttl + propagación` y `Delete − Inactive ≥ max_zone_ttl + propagación`.

Una rotación de ZSK pre-publish completa hecha a mano:

```
$ cd /var/lib/bind/keys

# 1. Create the successor, inheriting timing relationships from the predecessor.
$ sudo -u bind dnssec-keygen -S Kexample.net.+013+51230 -i 7200
Generating key pair.
Kexample.net.+013+09417

# 2. Inspect what -S decided.
$ dnssec-settime -p all Kexample.net.+013+09417
Created: Thu Aug 20 16:20:03 2026
Publish: Thu Aug 20 14:20:03 2026
Activate: Wed Nov 18 10:59:12 2026
Predecessor: 51230

$ dnssec-settime -p all Kexample.net.+013+51230
Created: Thu Aug 20 10:59:12 2026
Publish: Thu Aug 20 10:59:12 2026
Activate: Thu Aug 20 10:59:12 2026
Inactive: Wed Nov 18 10:59:12 2026
Delete: Thu Nov 19 10:59:12 2026
Successor: 09417

# 3. Nothing else to do -- smart signing honours the metadata on every run.
$ sudo -u bind dnssec-signzone -S -x -A -3 - -H 0 -N INCREMENT \
      -o example.net -K /var/lib/bind/keys -t /var/lib/bind/zones/db.example.net
Fetching example.net/ECDSAP256SHA256/34505 (KSK) from key repository.
Fetching example.net/ECDSAP256SHA256/51230 (ZSK) from key repository.
Fetching example.net/ECDSAP256SHA256/09417 (ZSK) from key repository.
Verifying the zone using the following algorithms: ECDSAP256SHA256.
Zone fully signed:
Algorithm: ECDSAP256SHA256: KSKs: 1 active, 0 stand-by, 0 revoked
                            ZSKs: 1 active, 1 stand-by, 0 revoked
```

`1 active, 1 stand-by` es exactamente el estado pre-publish: la ZSK-09417 está en el RRset `DNSKEY` pero no firma.

**La rotación de emergencia de KSK con `-R` (revocación RFC 5011)** aplica únicamente a claves usadas como *trust anchors* (la raíz, o un anchor empresarial interno). Para una zona normal con un `DS` en el padre, la revocación no significa nada — el `DS` del padre es autoritativo y la revocación no es lo que quita la confianza.

### 5.4 Planilla de tiempos de rotación

Calculá estos valores una vez por zona y ponelos en la política:

```
ZSK pre-publish interval  ≥ dnskey_ttl + zone_propagation_delay + publish_safety
ZSK post-retire interval  ≥ max_zone_ttl + zone_propagation_delay + retire_safety
KSK DS-publish interval   ≥ parent_ds_ttl + parent_propagation_delay + publish_safety
KSK DS-retire interval    ≥ parent_ds_ttl + parent_propagation_delay + retire_safety
```

Para la política de §4.1 (`dnskey-ttl 1h`, `max-zone-ttl 1d`, `parent-ds-ttl 1h`, `parent-propagation-delay 2h`, `zone-propagation-delay 10m`, márgenes de seguridad de 1h):

| Paso | Espera mínima |
|---|---|
| ZSK publicada → firmando | 1 h + 10 m + 1 h = **2 h 10 m** |
| ZSK deja de firmar → eliminada | 24 h + 10 m + 1 h = **25 h 10 m** |
| DS publicado → la nueva KSK firma la DNSKEY | 1 h + 2 h + 1 h = **4 h** |
| KSK vieja eliminada → DS viejo eliminado | 1 h + 2 h + 1 h = **4 h** |

Rotación total de ZSK: ~27 h. Rotación total de KSK: ~8 h *después* de que actúe el registrar. Planificá las ventanas de mantenimiento en consecuencia, y nunca comprimas estos números para "que el cambio vaya más rápido".

---

## 6. BIND 9 como resolver recursivo validante

**`/etc/bind/named.conf` — recursor validante completo:**

```conf
// ---------------------------------------------------------------------------
// /etc/bind/named.conf  --  validating recursive resolver
// BIND 9.20.x
// ---------------------------------------------------------------------------

include "/etc/bind/tsig/rndc-key.conf";

acl "internal" {
    10.0.0.0/8;
    172.16.0.0/12;
    192.168.0.0/16;
    fd00::/8;
    127.0.0.1;
    ::1;
};

tls "resolver-tls" {
    cert-file "/etc/bind/tls/fullchain.pem";
    key-file  "/etc/bind/tls/privkey.pem";
    protocols { TLSv1.3; };
    ciphers   "HIGH:!aNULL:!eNULL:!MD5:!RC4";
    prefer-server-ciphers yes;
    session-tickets no;
};

http "resolver-http" {
    endpoints { "/dns-query"; };
};

options {
    directory              "/var/cache/bind";
    managed-keys-directory "/var/cache/bind/keys";   // RFC 5011 state -- MUST be writable by named
    pid-file               "/run/named/named.pid";

    listen-on port 53  { 10.20.0.53; 127.0.0.1; };
    listen-on-v6 port 53 { fd00:20::53; ::1; };

    // DNS over TLS (RFC 7858) and DNS over HTTPS (RFC 8484)
    listen-on port 853 tls "resolver-tls" { 10.20.0.53; };
    listen-on-v6 port 853 tls "resolver-tls" { fd00:20::53; };
    listen-on port 443 tls "resolver-tls" http "resolver-http" { 10.20.0.53; };

    recursion yes;
    allow-query        { "internal"; };
    allow-recursion    { "internal"; };
    allow-query-cache  { "internal"; };
    allow-transfer     { none; };

    // ---- DNSSEC validation ------------------------------------------------
    // "auto" loads the built-in root trust anchor from /etc/bind/bind.keys and
    // maintains it automatically per RFC 5011. Do NOT hardcode a DS unless you
    // have an operational process for the next root KSK rollover.
    dnssec-validation      auto;
    // "yes" would require an explicit trust-anchors{} block, with no RFC 5011
    // tracking -- a liability during a root KSK roll.

    // Serve stale answers rather than SERVFAIL when upstream is unreachable.
    // This does NOT bypass validation: bogus data is still refused.
    stale-answer-enable    yes;
    stale-answer-ttl       30;
    max-stale-ttl          86400;
    stale-refresh-time     30;
    stale-answer-client-timeout 1800;   // ms

    // Aggressive use of DNSSEC-validated cache (RFC 8198): synthesise NXDOMAIN
    // from cached NSEC/NSEC3. Cuts random-subdomain-attack traffic dramatically.
    synth-from-dnssec      yes;

    // QNAME minimisation (RFC 9156): send only the label the upstream needs.
    qname-minimization      relaxed;

    // Flag Day 2020
    edns-udp-size          1232;
    max-udp-size           1232;

    // Do not become an amplifier if the ACL is ever misconfigured.
    rate-limit {
        responses-per-second 50;
        slip 2;
        window 5;
        exempt-clients { "internal"; };
    };

    // Prefetch popular records before they expire -- smooths validation cost.
    prefetch 2 9;

    max-cache-size         60%;
    max-cache-ttl          86400;
    max-ncache-ttl         3600;

    minimal-responses      yes;
    version                none;
    hostname               none;
};

controls {
    inet 127.0.0.1 port 953 allow { 127.0.0.1; } keys { "rndc-key"; };
};

statistics-channels {
    inet 127.0.0.1 port 8053 allow { 127.0.0.1; };
};

logging {
    channel "dnssec_log" {
        file "/var/log/named/dnssec.log" versions 10 size 50m;
        severity debug 3;                 // level 3 shows every validation step
        print-time yes; print-category yes; print-severity yes;
    };
    channel "resolver_log" {
        file "/var/log/named/resolver.log" versions 5 size 50m;
        severity info;
        print-time yes; print-category yes;
    };
    category dnssec       { "dnssec_log"; };
    category resolver     { "resolver_log"; };
    category lame-servers { "null"; };
    category default      { "resolver_log"; };
};

// Optional: forward a private namespace to internal authoritatives, and mark it
// insecure so validation does not fail on an unsigned internal zone whose parent
// is signed.
zone "corp.example.net" {
    type forward;
    forward only;
    forwarders { 10.20.1.53; 10.20.2.53; };
};

// Local trust anchor for an internal zone whose parent cannot hold a DS.
trust-anchors {
    corp.example.net. static-ds 62311 13 2
        "1F5C0AB93D7E4682C0A5B3E71D94F208C6B7A3E50D291F84B0C7E635A9D2F14C";
};
```

**Verificar que la validación funciona, de punta a punta:**

```
$ dig +dnssec +multi @10.20.0.53 www.example.net A

; <<>> DiG 9.20.4 <<>> +dnssec +multi @10.20.0.53 www.example.net A
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 41532
;; flags: qr rd ra ad; QUERY: 1, ANSWER: 4, AUTHORITY: 0, ADDITIONAL: 1

;; OPT PSEUDOSECTION:
; EDNS: version: 0, flags: do; udp: 1232
;; QUESTION SECTION:
;www.example.net.	IN A

;; ANSWER SECTION:
www.example.net.	3600 IN A 203.0.113.10
www.example.net.	3600 IN A 203.0.113.11
www.example.net.	3600 IN RRSIG A 13 3 3600 (
				20260903120000 20260820120000 51230 example.net.
				kZ8vQ3mF1tY7pR2wX9cH4nB6dL0aS5jE
				gT8uV2yK1xM7rN3qP6zC4wD9fA0bH5eI= )

;; Query time: 148 msec
;; SERVER: 10.20.0.53#53(10.20.0.53) (UDP)
;; WHEN: Thu Aug 20 12:31:07 UTC 2026
;; MSG SIZE  rcvd: 251
```

**El `ad` en los flags es la prueba.** Su ausencia significa insecure o sin validar — nunca lo des por sentado.

```
$ delv +rtrace @10.20.0.53 www.example.net A
;; fetch: www.example.net/A
;; fetch: example.net/DNSKEY
;; fetch: example.net/DS
;; fetch: net/DNSKEY
;; fetch: net/DS
;; fetch: ./DNSKEY
; fully validated
www.example.net.	3600	IN	A	203.0.113.10
www.example.net.	3600	IN	A	203.0.113.11
www.example.net.	3600	IN	RRSIG	A 13 3 3600 20260903120000 20260820120000 51230 example.net. kZ8vQ3mF1tY7pR2wX9cH4nB6dL0aS5jEgT8uV2yK1xM7rN3qP6zC4wD9fA0bH5eI=
```

`delv` **no** es `dig +dnssec`. `dig` te muestra lo que dijo el servidor; `delv` realiza la validación *él mismo*, en el cliente, usando la misma biblioteca que usa `named`. Cuando el resolver dice bogus y necesitás saber *por qué*, `delv` es la herramienta.

```
$ delv +vtrace @10.20.0.53 www.broken-sig.test A
;; fetch: www.broken-sig.test/A
;; validating www.broken-sig.test/A: starting
;; validating www.broken-sig.test/A: attempting positive response validation
;; fetch: broken-sig.test/DNSKEY
;; validating broken-sig.test/DNSKEY: starting
;; validating broken-sig.test/DNSKEY: attempting positive response validation
;; validating broken-sig.test/DNSKEY: verify failed due to bad signature (keyid=51230): RRSIG has expired
;; validating broken-sig.test/DNSKEY: no valid signature found
;; broken-sig.test/DNSKEY: got insecure response; parent indicates it should be secure
;; validating www.broken-sig.test/A: in fetch_callback_validator
;; validating www.broken-sig.test/A: fetch_callback_validator: got broken trust chain
;; validating www.broken-sig.test/A: bad trust chain
;; resolution failed: broken trust chain
```

**El triage con `+cd`, en un par de comandos:**

```
$ dig +short @10.20.0.53 www.broken-sig.test A
                                              # empty -> SERVFAIL

$ dig @10.20.0.53 www.broken-sig.test A | grep -E 'status|flags'
;; ->>HEADER<<- opcode: QUERY, status: SERVFAIL, id: 22194
;; flags: qr rd ra; QUERY: 1, ANSWER: 0, AUTHORITY: 0, ADDITIONAL: 1

$ dig +cd @10.20.0.53 www.broken-sig.test A | grep -E 'status|^www'
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 39471
www.broken-sig.test.	300	IN	A	198.51.100.77
```

`+cd` funciona, sin él falla ⇒ **fallo de validación DNSSEC, no un problema de servidor ni de datos.**

**Negative Trust Anchors** — la válvula de emergencia cuando la zona de *un tercero* está bogus y tus usuarios la necesitan ya. Esto es deliberadamente temporal; la vida máxima está acotada (`max-ntas`, por defecto 1 semana) y por defecto no persiste entre reinicios.

```
$ sudo rndc nta -d 3600 broken-sig.test
Negative trust anchor added: broken-sig.test/_default, expires 20-Aug-2026 13:33:12.000

$ sudo rndc nta -dump
broken-sig.test/_default: expiry 20-Aug-2026 13:33:12.000

$ dig +short @10.20.0.53 www.broken-sig.test A
198.51.100.77

$ sudo rndc nta -remove broken-sig.test
Negative trust anchor removed: broken-sig.test/_default
```

**Nunca agregues un NTA para una zona que vos operás.** Te oculta tu propia caída a vos mismo mientras todo otro resolver de Internet sigue fallando.

**Estado del trust anchor:**

```
$ sudo rndc managed-keys status
view: _default
next scheduled event: Fri, 21 Aug 2026 04:11:52 GMT

  name: .
    keyid: 20326
      algorithm: RSASHA256
      flags: KSK SEP
      next refresh: Fri, 21 Aug 2026 04:11:52 GMT
      trusted since: Thu, 20 Aug 2026 10:44:03 GMT
```

Si tenés que fijar el anchor raíz explícitamente (build air-gapped, sin `managed-keys-directory` escribible):

```conf
trust-anchors {
    // Root KSK-2017 -- verify against https://data.iana.org/root-anchors/root-anchors.xml
    . initial-ds 20326 8 2
        "E06D44B80B8F1D39A95C0B0D7C65D08458E880409BBC683457104237C7F8EC8D";
};
```

`initial-ds` / `initial-key` habilitan el seguimiento RFC 5011 desde ese punto de partida (el valor es un *bootstrap*, y `named` mantiene el conjunto vivo en `managed-keys-directory`). `static-ds` / `static-key` desactivan el seguimiento por completo — correcto solo para anchors internos que rotás vos mismo, **nunca** para la raíz.

### 6.1 systemd-resolved (conocimiento general)

```ini
# /etc/systemd/resolved.conf.d/50-secure.conf
[Resolve]
DNS=9.9.9.9#dns.quad9.net 2620:fe::fe#dns.quad9.net
FallbackDNS=
Domains=~.
DNSOverTLS=yes
DNSSEC=yes
DNSStubListenerExtra=127.0.0.53:53
Cache=yes
CacheFromLocalhost=no
```

```
$ resolvectl status
Global
         Protocols: +LLMNR +mDNS +DNSOverTLS DNSSEC=yes/supported
  resolv.conf mode: stub
Current DNS Server: 9.9.9.9#dns.quad9.net
       DNS Servers: 9.9.9.9#dns.quad9.net 2620:fe::fe#dns.quad9.net
        DNS Domain: ~.

$ resolvectl query www.example.net
www.example.net: 203.0.113.10                  -- link: eth0
                 203.0.113.11                  -- link: eth0

-- Information acquired via protocol DNS in 21.4ms.
-- Data is authenticated: yes; Data was acquired via local or encrypted transport: yes
-- Data from: network

$ resolvectl statistics
DNSSEC Verdicts
Secure: 1842
Insecure: 9317
Bogus: 3
Indeterminate: 0
```

**Chequeo de realidad operativa:** `DNSSEC=yes` en `resolved` es genuinamente fail-closed y genuinamente se rompe en los portales cautivos de hoteles y aeropuertos y en zonas corporativas split-horizon cuyos padres están firmados. `DNSSEC=allow-downgrade` es un **ajuste de seguridad teatral** — permite que un atacante on-path que quite el bit `DO` desactive la validación, que es exactamente el atacante que DNSSEC existe para frenar. En un servidor, la respuesta correcta es un resolver validante de verdad (`named`, `unbound`) en localhost con `DNSSEC=no` en `resolved`; en una laptop, `DNSSEC=yes` más un workaround documentado para portales cautivos.

---

## 7. DANE — vincular X.509 al DNS

### 7.1 El problema que resuelve DANE

El modelo de confianza de la WebPKI es "cualquiera de unas ~150 CAs puede emitir para cualquier nombre". DANE lo invierte: **el dueño del dominio declara, en DNS protegido por DNSSEC, qué certificado o qué CA es aceptable para un servicio dado.**

El registro `TLSA` vive en un nombre de propietario estructurado:

```
_<port>._<proto>.<hostname>.  IN  TLSA  <usage> <selector> <matching-type> <data>
```

| Campo | Valor | Nombre | Significado |
|---|---|---:|---|
| **Usage** | 0 | PKIX-TA | La cadena de certificados debe contener esta CA **y** validar contra el almacén de confianza del sistema |
| | 1 | PKIX-EE | El certificado EE debe ser este **y** validar contra el almacén de confianza del sistema |
| | 2 | DANE-TA | La cadena debe anclarse en esta CA; **no se consulta el almacén de confianza del sistema** |
| | **3** | **DANE-EE** | El certificado EE debe ser exactamente este; **sin CA, sin chequeo de vencimiento, sin chequeo de nombre** |
| **Selector** | 0 | Cert | Coincidir con el certificado DER completo |
| | **1** | **SPKI** | Coincidir con el `SubjectPublicKeyInfo` — sobrevive a la renovación del certificado con la misma clave |
| **Matching** | 0 | Full | Los datos crudos |
| | **1** | **SHA-256** | Digest SHA-256 — la única elección sensata |
| | 2 | SHA-512 | Digest SHA-512 |

| Combinación | Comportamiento ante renovación | ¿Necesita almacén de confianza? | Recomendada para |
|---|---|---|---|
| `3 1 1` | Sobrevive a la renovación **si se reutiliza la clave** | No | **SMTP (RFC 7672), servicios autofirmados, PKI interna** |
| `3 0 1` | Se rompe en cada renovación | No | Solo con automatización estricta |
| `2 1 1` | Sobrevive completamente a la renovación del EE | No | CA privada; intermedios de larga vida |
| `2 0 1` | Sobrevive a la renovación del EE | No | Fijar un intermedio público — **frágil**, las CAs rotan intermedios |
| `1 1 1` | Se rompe en la renovación | **Sí** | Pinning web con doble cinturón |
| `0 x 1` | Estable | **Sí** | Raramente útil |

**Los usages 0 y 1 están efectivamente muertos para los navegadores** — ningún navegador mainstream implementa DANE. El despliegue real, obligatorio y estructural de DANE es **SMTP (RFC 7672)**, donde arregla la falla fundamental del STARTTLS oportunista: un atacante on-path puede quitar la capacidad `STARTTLS` y el MTA emisor cae en silencio a texto plano. Con un registro `TLSA` presente y validado por DNSSEC, el emisor **debe** usar TLS y **debe** coincidir con el registro.

### 7.2 Generar registros TLSA

```
# 3 1 1 -- DANE-EE, SPKI, SHA-256 -- from a live server
$ openssl s_client -connect mx1.example.net:25 -starttls smtp -showcerts </dev/null 2>/dev/null \
  | openssl x509 -noout -pubkey \
  | openssl pkey -pubin -outform DER \
  | openssl dgst -sha256 -binary \
  | xxd -p -c 64
8a9e1b4f2c0d77a3e5619b8c4d2f0a6e3b7c1d95f84a20e6c3d71b0f5a94e28c

# ...or from a local certificate file
$ openssl x509 -in /etc/ssl/certs/mx1.pem -noout -pubkey \
  | openssl pkey -pubin -outform DER \
  | openssl dgst -sha256 -binary | xxd -p -c 64
8a9e1b4f2c0d77a3e5619b8c4d2f0a6e3b7c1d95f84a20e6c3d71b0f5a94e28c

# 3 0 1 -- full certificate, SHA-256
$ openssl x509 -in /etc/ssl/certs/mx1.pem -outform DER \
  | openssl dgst -sha256 -binary | xxd -p -c 64
c71a05b8e3d94f2016ab7c58d0e93f41b62a8c07d5194e3fa8b06c21d7e4593a
```

Registros resultantes:

```dns
_25._tcp.mx1.example.net.  3600 IN TLSA 3 1 1 8a9e1b4f2c0d77a3e5619b8c4d2f0a6e3b7c1d95f84a20e6c3d71b0f5a94e28c
_25._tcp.mx2.example.net.  3600 IN TLSA 3 1 1 8a9e1b4f2c0d77a3e5619b8c4d2f0a6e3b7c1d95f84a20e6c3d71b0f5a94e28c
_443._tcp.www.example.net. 3600 IN TLSA 3 1 1 d4c8f1a2b7e390654c1d8b2fa07e63c918b4d70a2e5c9f3168b0da47c25e19f8
```

El `TLSA` para SMTP va en el **nombre de host destino del MX**, no en el dominio. Y el propio nombre del destino del MX debe ser DNSSEC-secure, o el RFC 7672 dice que DANE no aplica.

### 7.3 Verificar DANE

```
$ dig +dnssec +short @10.20.0.53 _25._tcp.mx1.example.net TLSA
3 1 1 8A9E1B4F2C0D77A3E5619B8C4D2F0A6E3B7C1D95F84A20E6C3D71B0F5A94E28C
TLSA 13 4 3600 20260903120000 20260820120000 51230 example.net. Qm4x...

$ delv @10.20.0.53 _25._tcp.mx1.example.net TLSA
; fully validated
_25._tcp.mx1.example.net. 3600 IN TLSA 3 1 1 8A9E1B4F2C0D77A3E5619B8C4D2F0A6E3B7C1D95F84A20E6C3D71B0F5A94E28C
_25._tcp.mx1.example.net. 3600 IN RRSIG TLSA 13 4 3600 20260903120000 20260820120000 51230 example.net. Qm4x...
```

**Validación de punta a punta con el soporte DANE integrado de OpenSSL:**

```
$ openssl s_client -connect mx1.example.net:25 -starttls smtp \
      -dane_tlsa_domain mx1.example.net \
      -dane_tlsa_rrdata "3 1 1 8a9e1b4f2c0d77a3e5619b8c4d2f0a6e3b7c1d95f84a20e6c3d71b0f5a94e28c" \
      </dev/null 2>&1 | grep -E 'DANE|Verify|Verification'
DANE TLSA 3 1 1 ...5a94e28c matched EE certificate at depth 0
Verification: OK
Verify return code: 0 (ok)
```

Un **fallo** se ve así — notá que el handshake TLS en sí tiene éxito; solo falla el vínculo DANE:

```
$ openssl s_client -connect mx1.example.net:25 -starttls smtp \
      -dane_tlsa_domain mx1.example.net \
      -dane_tlsa_rrdata "3 1 1 0000000000000000000000000000000000000000000000000000000000000000" \
      </dev/null 2>&1 | grep -E 'DANE|Verify|Verification'
Verification error: No matching DANE TLSA records
Verify return code: 65 (No matching DANE TLSA records)
```

Chequeo automatizado de punta a punta (valida la cadena DNSSEC *y* el vínculo TLS):

```
$ danetool --check mx1.example.net --port 25 --starttls-proto smtp
Resolving 'mx1.example.net'...
Obtaining certificate from '203.0.113.25:25'...
Querying DNS for _25._tcp.mx1.example.net (TLSA)...
Verification: Certificate matches. Verified.
```

### 7.4 Desplegar DANE para SMTP con Postfix

**Lado emisor** (verificar los registros DANE ajenos) — requiere un resolver **validante**:

```conf
# /etc/postfix/main.cf
smtp_dns_support_level = dnssec
smtp_tls_security_level = dane
smtp_tls_loglevel = 1
smtp_host_lookup = dns
```

```
$ sudo postmap -q "secure-partner.example" \
      socketmap:unix:/var/spool/postfix/private/tlsproxy:
$ sudo grep 'Verified TLS' /var/log/mail.log | tail -2
Aug 20 13:02:11 mx1 postfix/smtp[8812]: Verified TLS connection established to
  mx.secure-partner.example[198.51.100.25]:25: TLSv1.3 with cipher
  TLS_AES_256_GCM_SHA384 (256/256 bits) key-exchange X25519 server-signature
  ECDSA (P-256) server-digest SHA256
```

`Verified TLS connection` (a diferencia de `Trusted` o `Untrusted`) es la línea de log que prueba que DANE coincidió.

**Lado receptor** — publicá `TLSA` para tus propios hosts MX y hacé que la renovación sea segura. La disciplina clave: **reutilizar el par de claves en la renovación** para que un registro SPKI `3 1 1` sobreviva, o ejecutar una rotación publicar-y-después-cambiar.

La rotación de renovación, en orden:

1. Generá la nueva clave/CSR **sin** desplegarla.
2. Publicá un **segundo** registro `TLSA` para el nuevo SPKI junto al viejo.
3. Esperá ≥ el TTL del `TLSA` + propagación.
4. Instalá el nuevo certificado y recargá el MTA.
5. Esperá ≥ el TTL del `TLSA` otra vez.
6. Eliminá el registro `TLSA` viejo.

Hacer los pasos 4 y 2 en el orden equivocado es una caída de correo que solo afecta a los emisores que hacen DANE correctamente — o sea, exactamente tus socios más conscientes de la seguridad.

### 7.5 DANE frente a las alternativas para SMTP

| | **DANE (RFC 7672)** | **MTA-STS (RFC 8461)** | **STARTTLS oportunista simple** |
|---|---|---|---|
| Raíz de confianza | DNSSEC | WebPKI + archivo de política HTTPS | Ninguna |
| Requiere zona firmada | **Sí** | No | No |
| A prueba de downgrade | Sí | Solo después de la primera obtención exitosa (TOFU) | **No** |
| Descubrimiento de la política | `TLSA` en el DNS | TXT `_mta-sts` + `https://mta-sts.<domain>/.well-known/mta-sts.txt` | — |
| Modo de fallo | Fallo duro | Fallo duro una vez cacheada la política | Texto plano en silencio |
| Piezas móviles extra | DNS firmado | Un servidor web que nunca debe romperse | Ninguna |
| Reportes | — | TLS-RPT (RFC 8460) | — |

Son complementarios, no competidores: publicá **ambos**. DANE cubre a los emisores capaces de DNSSEC sin dependencia de HTTPS; MTA-STS cubre a los grandes proveedores que eligieron no desplegar validación DNSSEC.

---

## 8. TSIG — autenticar el DNS entre servidores

DNSSEC autentica **datos**. TSIG (RFC 8945, que reemplaza al RFC 2845) autentica **transacciones**: un secreto HMAC compartido entre dos partes, que cubre todo el mensaje DNS más una marca de tiempo.

Usá TSIG para:

* **Transferencias de zona** (AXFR/IXFR) — las ACLs por IP por sí solas son falsificables e inútiles detrás de NAT o en VPCs cloud con direcciones rotativas.
* Mensajes **NOTIFY**.
* **Actualizaciones dinámicas** (RFC 2136) — ACME DNS-01, DHCP-DDNS, `cert-manager`.
* **`rndc`** — el canal de control está protegido por TSIG por construcción.

### 8.1 Generar y configurar claves

```
$ tsig-keygen -a hmac-sha256 xfr-key
key "xfr-key" {
	algorithm hmac-sha256;
	secret "Vc3AqfE7wJ2z2iZ+2Cq1sLh0X9dQ1ZKp4X1p3Yv4S6Y=";
};

$ sudo tsig-keygen -a hmac-sha256 acme-update-key > /etc/bind/tsig/acme-key.conf
$ sudo chown root:bind /etc/bind/tsig/acme-key.conf
$ sudo chmod 0640 /etc/bind/tsig/acme-key.conf
```

`ddns-confgen` es el nombre heredado; `tsig-keygen` es la herramienta actual. `dnssec-keygen -a HMAC-SHA256 -n HOST` también funciona y produce archivos `K<name>.+165+<tag>.{key,private}`, que es la forma que consumen `dig -k` y `nsupdate -k`.

| Algoritmo TSIG | Estado | Nota |
|---|---|---|
| `hmac-md5` (`HMAC-MD5.SIG-ALG.REG.INT`) | **Obsoleto** | Valor por defecto heredado; no usar |
| `hmac-sha1` | Obsoleto | Evitar |
| `hmac-sha224` | Permitido | Inusual |
| `hmac-sha256` | **Valor por defecto recomendado** | Secreto de 256 bits |
| `hmac-sha384` / `hmac-sha512` | Permitidos | Más grandes, sin ganancia práctica |
| GSS-TSIG (RFC 3645) | Permitido | Actualizaciones autenticadas con Kerberos (integración con AD) |

**Lado primario:**

```conf
include "/etc/bind/tsig/xfr-key.conf";
include "/etc/bind/tsig/acme-key.conf";

zone "example.net" IN {
    type primary;
    file "/var/lib/bind/zones/db.example.net";
    dnssec-policy "prod-ecdsa";
    inline-signing yes;

    allow-transfer { key "xfr-key"; };
    also-notify    { 192.0.2.53 key "xfr-key"; 198.51.100.53 key "xfr-key"; };
    notify explicit;

    // Restrict dynamic updates to the ACME challenge label only.
    update-policy {
        grant "acme-update-key" name _acme-challenge.example.net. TXT;
        grant "acme-update-key" subdomain _acme-challenge.example.net. TXT;
    };
};
```

`update-policy` es estrictamente mejor que `allow-update { key "..."; }`: esta última le otorga **toda la zona** a quien tenga la clave. Tipos de grant de `update-policy` que conviene conocer: `name` (exacto), `subdomain`, `zonesub`, `wildcard`, `self`, `selfsub`, `krb5-self`, `ms-self`, `tcp-self`, `external`.

**Lado secundario:**

```conf
include "/etc/bind/tsig/xfr-key.conf";

// Bind the key to the peer address: every message to/from this IP is signed.
server 192.0.2.1  { keys { "xfr-key"; }; };
server 2001:db8:1::53 { keys { "xfr-key"; }; };

zone "example.net" IN {
    type secondary;
    file "/var/lib/bind/zones/sec.example.net";
    primaries { 192.0.2.1; 2001:db8:1::53; };
    allow-transfer { none; };
    allow-notify   { key "xfr-key"; };
    // Do NOT set dnssec-policy here -- a secondary transfers already-signed data.
};
```

La sentencia `server` es la pieza que la gente se olvida. Sin ella, el secundario *aceptará* mensajes firmados pero no *firmará* la petición AXFR que envía, y el primario la rechazará.

### 8.2 Probar TSIG

```
$ dig @192.0.2.1 example.net AXFR -y hmac-sha256:xfr-key:Vc3AqfE7wJ2z2iZ+2Cq1sLh0X9dQ1ZKp4X1p3Yv4S6Y=

; <<>> DiG 9.20.4 <<>> @192.0.2.1 example.net AXFR -y hmac-sha256:xfr-key:[key]
; (1 server found)
;; global options: +cmd
example.net.	3600 IN SOA ns1.example.net. hostmaster.example.net. 2026082002 7200 3600 1209600 3600
example.net.	3600 IN RRSIG SOA 13 2 3600 20260903120000 20260820120000 51230 example.net. Lx7...
example.net.	3600 IN NS ns1.example.net.
...
example.net.	3600 IN SOA ns1.example.net. hostmaster.example.net. 2026082002 7200 3600 1209600 3600
;; Query time: 12 msec
;; SERVER: 192.0.2.1#53(192.0.2.1) (TCP)
;; WHEN: Thu Aug 20 13:44:02 UTC 2026
;; XFR size: 47 records (messages 1, bytes 4318)

;; TSIG PSEUDOSECTION:
xfr-key.		0	ANY	TSIG	hmac-sha256. 1755697442 300 32 3nQ7xK9mB2vT... 51203 NOERROR 0
```

Poner el secreto en la línea de comandos lo filtra a `ps` y al historial del shell. Usá un archivo de clave:

```
$ dig @192.0.2.1 example.net AXFR -k /etc/bind/tsig/Kxfr-key.+165+51203.key
```

**Rechazo sin la clave — así se ve "funciona" desde afuera:**

```
$ dig @192.0.2.1 example.net AXFR

; <<>> DiG 9.20.4 <<>> @192.0.2.1 example.net AXFR
;; global options: +cmd
; Transfer failed.
```

```
$ sudo tail -3 /var/log/named/xfer.log
20-Aug-2026 13:45:19.221 xfer-out: info: client @0x7f3c1004a120 198.51.100.9#51882
  (example.net): bad zone transfer request: 'example.net/IN': non-authoritative zone (NOTAUTH)
20-Aug-2026 13:45:19.221 security: info: client @0x7f3c1004a120 198.51.100.9#51882
  (example.net): zone transfer 'example.net/IN' denied
```

**Desfase de reloj — el fallo clásico de TSIG.** El `fudge` por defecto es 300 s; la firma cubre una marca de tiempo.

```
$ dig @192.0.2.1 example.net SOA -y hmac-sha256:xfr-key:Vc3AqfE7wJ2z2iZ+2Cq1sLh0X9dQ1ZKp4X1p3Yv4S6Y=
;; Couldn't verify signature: tsig verify failure
...
;; TSIG PSEUDOSECTION:
xfr-key.	0 ANY TSIG hmac-sha256. 1755697442 300 0  18 BADTIME 6 ...
```

`BADTIME` (error 18) ⇒ los relojes de los dos hosts difieren en más que el fudge. **Corré NTP en cada servidor DNS**; esto no es opcional en cuanto entra TSIG o DNSSEC en juego. Códigos de error de TSIG: `BADSIG` 16 (secreto incorrecto), `BADKEY` 17 (nombre de clave desconocido), `BADTIME` 18 (desfase de reloj), `BADTRUNC` 22 (MAC truncado rechazado).

### 8.3 Actualización dinámica con `nsupdate` (el camino de ACME DNS-01)

```
$ nsupdate -k /etc/bind/tsig/Kacme-update-key.+165+42817.key -v <<'EOF'
server 192.0.2.1
zone example.net
update delete _acme-challenge.example.net. TXT
update add    _acme-challenge.example.net. 60 TXT "gfj9Xq...Rg85nM"
send
EOF

$ dig +short @192.0.2.1 _acme-challenge.example.net TXT
"gfj9Xq...Rg85nM"

$ sudo tail -2 /var/log/named/general.log
20-Aug-2026 13:51:07.442 update: info: client @0x7f3c10052ab0 10.20.4.18#39114/key
  acme-update-key: updating zone 'example.net/IN': deleting rrset at
  '_acme-challenge.example.net' TXT
20-Aug-2026 13:51:07.443 update: info: client @0x7f3c10052ab0 10.20.4.18#39114/key
  acme-update-key: updating zone 'example.net/IN': adding an RR at
  '_acme-challenge.example.net' TXT "gfj9Xq...Rg85nM"
```

Con `dnssec-policy` + `inline-signing`, `named` vuelve a firmar el RRset modificado de inmediato. Sin paso de re-firma, sin incrementar el serial a mano.

**Manifiestos Kubernetes completos — solver RFC2136 de cert-manager sobre TSIG:**

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: bind-tsig-acme
  namespace: cert-manager
type: Opaque
stringData:
  # The raw base64 secret from tsig-keygen -- NOT re-encoded.
  # (stringData handles the Kubernetes-level base64 for us.)
  tsig-secret-key: "Kq7Rz2Xw9Nm4Bv6Tc1Yh8Jd0Ls5Pe3Fg7Ua2Wi4Oq="
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-dns01
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: hostmaster@example.net
    privateKeySecretRef:
      name: letsencrypt-dns01-account-key
    solvers:
      - selector:
          dnsZones:
            - "example.net"
        dns01:
          rfc2136:
            nameserver: "192.0.2.1:53"
            tsigKeyName: "acme-update-key"
            tsigAlgorithm: HMACSHA256
            tsigSecretSecretRef:
              name: bind-tsig-acme
              key: tsig-secret-key
          # Do not ask the cluster's own resolver whether the TXT record is
          # visible -- it may be split-horizon. Check the authoritative servers.
      - selector: {}
        http01:
          ingress:
            ingressClassName: nginx
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-example-net
  namespace: platform
spec:
  secretName: wildcard-example-net-tls
  issuerRef:
    name: letsencrypt-dns01
    kind: ClusterIssuer
  commonName: "*.example.net"
  dnsNames:
    - "example.net"
    - "*.example.net"
  duration: 2160h      # 90d
  renewBefore: 720h    # 30d
  privateKey:
    algorithm: ECDSA
    size: 256
    # rotationPolicy: Never  <-- REQUIRED if you publish a DANE `3 1 1` record
    #                            for this certificate: reusing the key keeps the
    #                            SPKI digest stable across renewals.
    rotationPolicy: Always
```

```yaml
---
# cert-manager must resolve the ACME propagation check against the
# authoritative servers, not the cluster resolver.
apiVersion: v1
kind: ConfigMap
metadata:
  name: cert-manager-dns-config
  namespace: cert-manager
data:
  extraArgs: |
    --dns01-recursive-nameservers=192.0.2.1:53,198.51.100.53:53
    --dns01-recursive-nameservers-only
```

**Nota de seguridad sobre el grant.** El `update-policy` de arriba restringe `acme-update-key` a registros `TXT` de `_acme-challenge.example.net` únicamente. Si en cambio escribís `allow-update { key "acme-update-key"; };`, un pod de cert-manager comprometido puede reescribir tus `MX`, tus registros `A` y tus registros `TLSA`. Acotá el grant.

### 8.4 TSIG vs SIG(0) vs TLS mutuo

| | **TSIG** | **SIG(0)** (RFC 2931) | **XoT / mTLS** (RFC 9103) |
|---|---|---|---|
| Criptografía | HMAC simétrico | Asimétrica (clave pública en el DNS) | TLS con certificados de cliente |
| Distribución de claves | Secreto compartido fuera de banda, **O(n²)** pares | Clave pública publicada en el DNS, **O(n)** | PKI, **O(n)** |
| Confidencialidad de la transferencia | **Ninguna** — AXFR va en texto plano | Ninguna | **Sí** |
| Compromiso de un peer | Expone el secreto compartido de ese par | Expone solo la clave privada de ese peer | Expone un certificado de cliente |
| Protección contra replay | Marca de tiempo + fudge (necesita NTP) | Marca de tiempo (necesita NTP) | TLS |
| Soporte de servidores | Universal | Irregular | BIND 9.18+, Knot, Unbound |
| Mejor para | Primario/secundario entre dos partes, actualización dinámica | Múltiples partes, rotación de claves sin coordinación | Transferencias confidenciales, redes cloud/hostiles |

**Transferencia de zona sobre TLS (XoT)** en BIND 9.18+, cuando el contenido de la zona en sí es sensible:

```conf
tls "xot-primary" {
    cert-file "/etc/bind/tls/ns1-fullchain.pem";
    key-file  "/etc/bind/tls/ns1-privkey.pem";
    ca-file   "/etc/bind/tls/internal-ca.pem";   // require a client cert
    remote-hostname "ns1.example.net";
    protocols { TLSv1.3; };
};

// Primary
options { listen-on port 853 tls "xot-primary" { 192.0.2.1; }; };

// Secondary
zone "example.net" {
    type secondary;
    primaries { 192.0.2.1 port 853 tls "xot-primary" key "xfr-key"; };
    file "/var/lib/bind/zones/sec.example.net";
};
```

TSIG y XoT se componen: TLS aporta confidencialidad y autenticación de canal, TSIG aporta autenticación de mensaje que sobrevive a un proxy que termina TLS.

---

## 9. Transportes DNS cifrados

### 9.1 La comparación

| | **Do53** | **DoT** (RFC 7858) | **DoH** (RFC 8484) | **DoQ** (RFC 9250) | **DNSCrypt** | **ODoH** (RFC 9230) |
|---|---|---|---|---|---|---|
| Transporte | UDP/TCP 53 | TLS 1.2+/TCP 853 | HTTPS/443 | QUIC/UDP 853 | UDP/TCP 443 o 5443 | HTTPS vía un relay |
| Vía de estandarización | Sí | Sí | Sí | Sí | **No** — especificación comunitaria | Experimental |
| Bloqueable por puerto | Trivialmente | **Sí** — el puerto 853 lo delata | **No** — indistinguible del tráfico web | Sí | En parte | No |
| Bloqueo de cabecera de línea | N/A | **Sí** (TCP) | Sí (HTTP/2 sobre TCP) | **No** (streams QUIC) | No | Depende |
| Establecimiento de conexión | 0 RTT | 2–3 RTT (1 con reanudación TLS 1.3) | 3+ RTT | **0–1 RTT** | 1 RTT | 2+ RTT |
| Metadatos filtrados al resolver | Consulta + IP del cliente | Consulta + IP del cliente | Consulta + IP del cliente + **cabeceras HTTP, User-Agent** | Consulta + IP del cliente | Consulta + IP del cliente | Consulta **o** IP del cliente, nunca ambas |
| Autenticación del servidor | Ninguna | Certificado (pin de SPKI o PKIX) | Certificado | Certificado | Clave pública firmada desde un stamp DNSCrypt | Certificado |
| Visibilidad empresarial | Total | Bloqueable, así que la política es aplicable | **Evita el split-horizon y las políticas basadas en DNS** | Bloqueable | Bloqueable | Evita |
| BIND 9.18+ | Sí | **Sí** | **Sí** | 9.19+ (experimental) | No | No |
| Unbound | Sí | Sí | Sí (1.12+) | 1.19+ | No | No |
| Proxy `dnsdist` / estilo `dnsdist` | Sí | Sí | Sí | Sí | Sí | — |

**El argumento arquitectónico que tenés que poder sostener:** el uso del puerto 443 por parte de DoH es simultáneamente su mayor virtud (incensurable) y su mayor problema operativo (un cliente DoH a nivel de aplicación dentro de un pod o un navegador **evita en silencio tu CoreDNS, tus zonas split-horizon, tu política de egress basada en DNS y tu registro de consultas**). En una flota gestionada, la postura correcta es: correr tu propio resolver DoT/DoH, publicarlo vía `resolvectl`/DHCP/Discovery of Designated Resolvers (RFC 9462), y bloquear o redirigir los endpoints DoH de terceros en el egress — no "prohibir el cifrado".

### 9.2 BIND 9.18+ como servidor DoT/DoH

La configuración está en §6 arriba (`tls`, `http`, `listen-on ... tls ... http ...`). Pruebas del lado del cliente:

```
$ dig +tls @10.20.0.53 www.example.net A +dnssec

; <<>> DiG 9.20.4 <<>> +tls @10.20.0.53 www.example.net A +dnssec
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 8823
;; flags: qr rd ra ad; QUERY: 1, ANSWER: 3, AUTHORITY: 0, ADDITIONAL: 1
...
;; SERVER: 10.20.0.53#853(10.20.0.53) (TLS)
```

```
$ dig +https @10.20.0.53 www.example.net A
;; SERVER: 10.20.0.53#443(10.20.0.53) (HTTPS)

$ kdig +tls @9.9.9.9 +tls-hostname=dns.quad9.net +tls-ca www.example.net A
;; TLS session (TLS1.3)-(ECDHE-X25519)-(ECDSA-SECP256R1-SHA256)-(AES-256-GCM)
;; DEBUG: Certificate chain verified.
;; ->>HEADER<<- opcode: QUERY; status: NOERROR; id: 12005
;; Flags: qr rd ra ad; QUERY: 1; ANSWER: 2; AUTHORITY: 0; ADDITIONAL: 1
```

Verificar el certificado DoT directamente:

```
$ openssl s_client -connect 10.20.0.53:853 -servername dns.example.net \
      -alpn dot </dev/null 2>/dev/null | openssl x509 -noout -subject -dates -ext subjectAltName
subject=CN = dns.example.net
notBefore=Aug  1 00:00:00 2026 GMT
notAfter=Oct 30 23:59:59 2026 GMT
X509v3 Subject Alternative Name:
    DNS:dns.example.net, IP Address:10.20.0.53
```

El SAN `IP Address` importa: los clientes DoT configurados con una IP pelada (`DNS=10.20.0.53#dns.example.net` en `resolved` usa el nombre, pero muchos clientes no) fallarán la verificación de nombre sin él.

### 9.3 DNSCrypt (conocimiento general)

Anterior a DoT/DoH; **no es un estándar de la IETF**. Usa X25519 + XSalsa20-Poly1305 (o XChaCha20-Poly1305), con la clave pública del servidor distribuida fuera de banda en un "DNS stamp" (`sdns://…`) en vez de vía PKIX. Sus rasgos distintivos son los **relays anonimizados** y el **padding de consultas**, y `dnscrypt-proxy` se usa ampliamente como stub local que habla DNSCrypt/DoH/ODoH hacia arriba y Do53 plano hacia el host. Para el examen: sabé qué es, que es anterior e independiente de DoT/DoH, y que autentica al *servidor* con una clave pública precompartida, no con una CA.

```
# /etc/dnscrypt-proxy/dnscrypt-proxy.toml  (excerpt)
listen_addresses = ['127.0.0.1:53', '[::1]:53']
server_names = ['quad9-dnscrypt-ip4-filter-pri']
require_dnssec = true
require_nolog  = true
require_nofilter = false
dnscrypt_servers = true
doh_servers = true
odoh_servers = false
```

---

## 10. Verificación y diagnóstico de fallos

### 10.1 La escalera de triage

Ejecutá estos en orden. Cada peldaño elimina una clase de causa.

```
1.  named-checkconf -z              -- does the config parse and do the zones load?
2.  dig +short SOA @<auth>          -- is the authoritative server answering at all?
3.  dig +dnssec ... | grep flags    -- is the `ad` flag present?
4.  dig +cd                         -- does it work with validation disabled?  <-- the fork
5.  delv +vtrace @<resolver>        -- where exactly in the chain does it break?
6.  dnssec-verify -o <zone> <file>  -- is the signed zone internally consistent?
7.  dig +short DS <zone> @<parent>  -- does the parent's DS match a live DNSKEY?
8.  rndc dnssec -status <zone>      -- what does the key state machine think?
9.  journalctl / dnssec.log         -- what did named actually log?
```

### 10.2 Catálogo de fallos

| Síntoma | Causa probable | Comando de confirmación | Solución |
|---|---|---|---|
| `SERVFAIL` en toda una zona; `+cd` funciona | `RRSIG` vencido | `dig +dnssec +cd SOA <zone> @<auth>` — comparar el campo 5 (vencimiento) con `date -u` | Volver a firmar; arreglar el cron; alertar sobre el vencimiento |
| `SERVFAIL`; `delv` dice `no valid signature found` e `insecure response; parent indicates it should be secure` | El `DS` en el padre no coincide con ninguna `DNSKEY` publicada | `dig +short DS <zone> @<parent-ns>` contra la salida de `dnssec-dsfromkey` | Publicar el `DS` correcto, o volver a agregar la clave que coincide |
| `SERVFAIL` solo para algunos resolvers | Inconsistencia multi-signer/anycast; un nodo tiene datos firmados obsoletos | `for ns in ...; do dig +norec SOA <zone> @$ns +short; done` | Arreglar la replicación; revisar `also-notify` |
| `delv`: `RRSIG validity period has not begun` | Desfase de reloj en el **validador** | `timedatectl` en el resolver | NTP |
| `RRSIG has expired` pero el archivo se firmó hace 5 min | Desfase de reloj en el **firmante** (firmado con un vencimiento pasado) | `timedatectl` en el firmante | NTP; volver a firmar |
| Las respuestas funcionan sobre TCP pero dan `SERVFAIL`/timeout sobre UDP | Respuesta > MTU del camino, fragmentos descartados | `dig +bufsize=1232 +ignore`, `dig +tcp` | `edns-udp-size 1232`; pasar a ECDSA para achicar el RRset `DNSKEY` |
| Un resolver validante devuelve `SERVFAIL` para una zona **interna** | Zona interna sin firmar pero su padre está firmado y tiene un `DS`, o inconsistencia de split-horizon | `delv @<resolver> <name>` | `validate-except { "corp.example.net"; };` o un `trust-anchors static-ds` local |
| El resolver registra `no valid DS` para una zona que *sí* está sin firmar | `DS` obsoleto dejado en el padre después de "desfirmar" | `dig +short DS <zone> @<parent>` | Eliminar el `DS` en el registrar **antes** de quitar las firmas |
| Transferencia de zona rechazada | Falta `server ... keys {}` en el secundario | `dig AXFR -y ...` desde el host secundario | Agregar la sentencia `server` |
| TSIG `BADTIME` | Desfase de reloj > `fudge` (300 s) | `dig ... -y ...` y leer la pseudosección TSIG | NTP |
| TSIG `BADKEY` | Desajuste del nombre de clave (los nombres no distinguen mayúsculas pero deben coincidir) | Comparar `key "..."` en ambos extremos | Alinear los nombres |
| TSIG `BADSIG` | Secreto incorrecto, o el secreto fue re-codificado en base64 | Salida de `tsig-keygen` contra el secreto desplegado | Volver a desplegar el secreto textualmente |
| Zona NSEC3 tratada como insecure por BIND 9.16.9+ | `iterations` demasiado alto | `dig +short NSEC3PARAM <zone>` | Volver a firmar con `iterations 0` (RFC 9276) |
| Rotación de KSK trabada en `rumoured` para siempre | `parental-agents` inalcanzables, o nunca se corrió `rndc dnssec -checkds` | `rndc dnssec -status <zone>` | Arreglar `parental-agents`; correr `-checkds published` |
| DANE falla después de renovar un certificado | Clave rotada, el digest SPKI `3 1 1` cambió | `openssl s_client -dane_tlsa_domain ...` | Publicar el nuevo `TLSA` **antes** de desplegar; o `rotationPolicy: Never` |
| `resolved` reporta `Bogus` para una zona que funciona | `DNSSEC=yes` con un upstream que mutila EDNS | `resolvectl statistics`; `resolvectl show-server-state` | Usar un recursor validante local, `DNSSEC=no` en `resolved` |

### 10.3 Leer un `RRSIG` a mano

```
www.example.net. 3600 IN RRSIG A 13 3 3600 20260903120000 20260820120000 51230 example.net. kZ8v...
                               │  │ │  │            │              │        │        │
                               │  │ │  │            │              │        │        └─ signer's name
                               │  │ │  │            │              │        └────────── key tag
                               │  │ │  │            │              └─────────────────── inception (UTC)
                               │  │ │  │            └────────────────────────────────── expiration (UTC)
                               │  │ │  └─────────────────────────────────────────────── original TTL
                               │  │ └────────────────────────────────────────────────── labels (www.example.net = 3)
                               │  └──────────────────────────────────────────────────── algorithm (13)
                               └─────────────────────────────────────────────────────── type covered (A)
```

* **Vencimiento en el pasado** ⇒ bogus en todas partes. Compará contra `date -u +%Y%m%d%H%M%S`.
* **Labels ≠ la cantidad real de etiquetas** ⇒ la respuesta vino de un comodín; el validador debe además probar que el nombre exacto no existe.
* **Key tag** ⇒ debe corresponder a una clave del RRset `DNSKEY` publicado con un algoritmo coincidente.
* **Nombre del firmante** ⇒ debe ser el ápex de la zona, o la respuesta está fuera de bailiwick.

Un one-liner que convierte "¿mi zona está por romperse?" en un número:

```
$ dig +short +dnssec SOA example.net @192.0.2.1 \
  | awk '$1=="SOA" && NF>6 {print $5}' \
  | while read -r e; do
      exp=$(date -u -d "${e:0:8} ${e:8:2}:${e:10:2}:${e:12:2}" +%s)
      printf 'RRSIG(SOA) expires in %d hours\n' $(( (exp - $(date -u +%s)) / 3600 ))
    done
RRSIG(SOA) expires in 331 hours
```

### 10.4 Monitoreo — la parte que no es opcional

Todo lo anterior es reactivo. Lo único que previene de forma confiable una caída de DNSSEC es una alerta que se dispare **días** antes de que venzan las firmas.

**Reglas de Prometheus:**

```yaml
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: dnssec-health
  namespace: monitoring
  labels:
    prometheus: platform
    role: alert-rules
spec:
  groups:
    - name: dnssec.rules
      interval: 5m
      rules:
        # ---- Signature expiry: the number-one self-inflicted DNS outage ----
        - alert: DnssecSignatureExpiringSoon
          expr: |
            (dnssec_rrsig_expiry_timestamp_seconds - time()) < 5 * 24 * 3600
          for: 30m
          labels:
            severity: warning
            team: platform
          annotations:
            summary: "RRSIG for {{ $labels.zone }} expires in under 5 days"
            description: >-
              Zone {{ $labels.zone }} on {{ $labels.instance }} has signatures
              expiring at {{ $value | humanizeTimestamp }}. When they expire,
              every validating resolver on the Internet returns SERVFAIL for the
              entire zone. Check the signing service and re-sign.
            runbook_url: "https://runbooks.example.net/dns/rrsig-expiry"

        - alert: DnssecSignatureExpiringCritical
          expr: |
            (dnssec_rrsig_expiry_timestamp_seconds - time()) < 24 * 3600
          for: 5m
          labels:
            severity: critical
            team: platform
          annotations:
            summary: "RRSIG for {{ $labels.zone }} expires in under 24 hours"

        # ---- Chain of trust: DS in the parent must match a live DNSKEY ----
        - alert: DnssecChainOfTrustBroken
          expr: dnssec_chain_valid == 0
          for: 10m
          labels:
            severity: critical
          annotations:
            summary: "DNSSEC chain of trust broken for {{ $labels.zone }}"
            description: >-
              The DS record in the parent zone does not match any published
              DNSKEY, or the DNSKEY RRset does not validate. The zone is BOGUS.

        # ---- Validation from the client's point of view ----
        - alert: DnssecValidationFailing
          expr: probe_success{job="blackbox-dns-validated"} == 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Validated DNS probe failing for {{ $labels.instance }}"

        # ---- Resolver-side bogus rate: someone else's zone, or ours ----
        - alert: ResolverBogusRateHigh
          expr: |
            rate(bind_resolver_dnssec_validation_errors_total[10m]) > 1
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "Elevated DNSSEC validation failures on {{ $labels.instance }}"

        # ---- DANE / TLSA drift after certificate renewal ----
        - alert: DaneTlsaMismatch
          expr: dane_tlsa_match == 0
          for: 10m
          labels:
            severity: critical
          annotations:
            summary: "TLSA record does not match the served certificate for {{ $labels.target }}"
            description: >-
              Mail from DANE-enforcing senders is being rejected. Publish the new
              SPKI digest and wait one TLSA TTL before removing the old record.
```

**Módulo del blackbox exporter que valida de verdad:**

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: blackbox-exporter-config
  namespace: monitoring
data:
  config.yml: |
    modules:
      dns_validated_a:
        prober: dns
        timeout: 5s
        dns:
          transport_protocol: "udp"
          preferred_ip_protocol: "ip4"
          query_name: "www.example.net"
          query_type: "A"
          # dnssec_ok makes the probe request signatures; validate_answer_rrs
          # then asserts an RRSIG is actually present.
          dnssec_ok: true
          valid_rcodes:
            - NOERROR
          validate_answer_rrs:
            fail_if_not_matches_regexp:
              - "www\\.example\\.net\\.\\s+\\d+\\s+IN\\s+RRSIG\\s+A\\s+13\\s+"
          validate_authority_rrs: {}

      dns_tls_853:
        prober: dns
        timeout: 5s
        dns:
          transport_protocol: "tcp"
          query_name: "www.example.net"
          query_type: "A"
```

**Un CronJob que mide el vencimiento real de las firmas** (la métrica que consumen las reglas de arriba):

```yaml
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: dnssec-expiry-probe
  namespace: monitoring
spec:
  schedule: "*/15 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 300
      template:
        spec:
          restartPolicy: Never
          securityContext:
            runAsNonRoot: true
            runAsUser: 65534
            runAsGroup: 65534
            seccompProfile:
              type: RuntimeDefault
          containers:
            - name: probe
              image: internal.registry.example.net/tools/bind-utils:9.20.4
              imagePullPolicy: IfNotPresent
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities:
                  drop: ["ALL"]
              resources:
                requests: { cpu: "20m", memory: "32Mi" }
                limits:   { cpu: "200m", memory: "128Mi" }
              env:
                - name: PUSHGATEWAY
                  value: "http://pushgateway.monitoring.svc:9091"
                - name: ZONES
                  value: "example.net 113.0.203.in-addr.arpa"
                - name: AUTH_NS
                  value: "192.0.2.1"
              command: ["/bin/sh", "-eu", "-c"]
              args:
                - |
                  now=$(date -u +%s)
                  out=""
                  for z in $ZONES; do
                    line=$(dig +short +dnssec SOA "$z" "@$AUTH_NS" \
                           | awk '$1=="SOA" && NF>7 {print $5; exit}')
                    if [ -z "$line" ]; then
                      echo "no RRSIG(SOA) for $z" >&2
                      out="${out}dnssec_rrsig_present{zone=\"$z\"} 0\n"
                      continue
                    fi
                    exp=$(date -u -d "${line%??????} ${line#????????}" +%s 2>/dev/null || \
                          date -u -d "$(echo "$line" | sed -E 's/^(.{4})(.{2})(.{2})(.{2})(.{2})(.{2})$/\1-\2-\3 \4:\5:\6/')" +%s)
                    out="${out}dnssec_rrsig_present{zone=\"$z\"} 1\n"
                    out="${out}dnssec_rrsig_expiry_timestamp_seconds{zone=\"$z\"} ${exp}\n"

                    # Chain of trust: does any parent DS match a published DNSKEY?
                    if delv "@$AUTH_NS" "$z" DNSKEY 2>&1 | grep -q '^; fully validated'; then
                      out="${out}dnssec_chain_valid{zone=\"$z\"} 1\n"
                    else
                      out="${out}dnssec_chain_valid{zone=\"$z\"} 0\n"
                    fi
                    echo "zone=$z expiry=$exp remaining_h=$(( (exp - now) / 3600 ))"
                  done
                  printf "%b" "$out" | \
                    curl --fail --silent --show-error --data-binary @- \
                      "${PUSHGATEWAY}/metrics/job/dnssec_expiry_probe"
```

**Equivalente con timer de systemd, para hosts fuera de un clúster:**

```ini
# /etc/systemd/system/dnssec-expiry-check.service
[Unit]
Description=Check DNSSEC signature expiry for locally served zones
After=network-online.target named.service
Wants=network-online.target

[Service]
Type=oneshot
User=nobody
Group=nogroup
ExecStart=/usr/local/sbin/dnssec-expiry-check.sh
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
NoNewPrivileges=yes
CapabilityBoundingSet=
RestrictAddressFamilies=AF_INET AF_INET6
```

```ini
# /etc/systemd/system/dnssec-expiry-check.timer
[Unit]
Description=Run the DNSSEC expiry check every 15 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
AccuracySec=1min
Persistent=true

[Install]
WantedBy=timers.target
```

**Validación externa que también deberías correr** — porque tu propio monitoreo comparte modos de fallo con tus propios servidores:

* **Zonemaster** (`https://zonemaster.net`) y el paquete `zonemaster-cli`.
* **DNSViz** (`https://dnsviz.net`) — dibuja toda la cadena de confianza gráficamente y es la forma más rápida de ver *dónde* se rompió una cadena.
* **Verisign DNSSEC Analyzer** (`https://dnssec-analyzer.verisignlabs.com`).
* **Internet.nl** — chequea DNSSEC, DANE y seguridad del correo en conjunto.

---

## 11. Checklist de producción

**Antes de firmar una zona por primera vez**

- [ ] Todos los TTL de la zona son ≤ el `max-zone-ttl` de la política, y todos los registros de cada RRset comparten un TTL.
- [ ] NTP está corriendo y sano en cada servidor autoritativo y en cada firmante.
- [ ] `edns-udp-size 1232` en autoritativos y recursores.
- [ ] Algoritmo 13 (ECDSAP256SHA256) salvo que una política escrita diga otra cosa.
- [ ] `nsec3param iterations 0 optout no salt-length 0`, o NSEC simple.
- [ ] El directorio de claves y `managed-keys-directory` son `0700`, propiedad del usuario `named`, y **están en el conjunto de respaldo** — incluyendo los archivos `.state`.
- [ ] `dnssec-verify` pasa antes de que la zona se sirva.
- [ ] Existe monitoreo de vencimiento y fue probado forzando una alerta.

**Antes de enviar el DS al registrar**

- [ ] El RRset `DNSKEY` valida en **todos** los servidores autoritativos (`dig +norec` en cada uno).
- [ ] La salida de `dnssec-dsfromkey` coincide con el `CDS` publicado.
- [ ] Tipo de digest SHA-256 (2), no SHA-1.
- [ ] Conocés el TTL del `DS` del padre y coincide con `parent-ds-ttl` en la política.

**Antes de renovar un certificado que tiene un registro `TLSA`**

- [ ] Nuevo `TLSA` publicado **primero**; esperaste ≥ el TTL.
- [ ] Reutilización de clave (`rotationPolicy: Never`) si el registro es `3 1 1` y no querés una rotación.
- [ ] `openssl s_client -dane_tlsa_domain` verificado contra el registro **nuevo** antes de eliminar el viejo.

**Nunca**

- [ ] Nunca agregues un Negative Trust Anchor para una zona que vos operás.
- [ ] Nunca pongas `DNSSEC=allow-downgrade`.
- [ ] Nunca otorgues `allow-update { key "x"; }` cuando `update-policy` puede acotarlo.
- [ ] Nunca quites las firmas de una zona cuyo `DS` sigue en el padre.
- [ ] Nunca comprimas las esperas de rotación para "que vaya más rápido".

---

## 12. Referencia de comandos

| Herramienta | Propósito | Invocación canónica |
|---|---|---|
| `named-checkconf` | Validar `named.conf` (y las zonas con `-z`) | `named-checkconf -z /etc/bind/named.conf` |
| `named-checkzone` | Validar un archivo de zona | `named-checkzone -D -o example.net example.net db.example.net.signed` |
| `dnssec-keygen` | Generar claves DNSSEC / TSIG | `dnssec-keygen -a ECDSAP256SHA256 -f KSK -n ZONE example.net` |
| `dnssec-keyfromlabel` | Crear un handle de clave para un objeto de HSM | `dnssec-keyfromlabel -E pkcs11 -a ECDSAP256SHA256 -f KSK -l "..." example.net` |
| `dnssec-settime` | Leer/modificar los metadatos de temporización de una clave | `dnssec-settime -p all Kexample.net.+013+51230` |
| `dnssec-signzone` | Firmar una zona offline | `dnssec-signzone -S -x -A -3 - -H 0 -N INCREMENT -o example.net db.example.net` |
| `dnssec-verify` | Verificar un archivo de zona firmado | `dnssec-verify -o example.net db.example.net.signed` |
| `dnssec-dsfromkey` | Derivar un `DS` de una `DNSKEY` | `dnssec-dsfromkey -a SHA-256 Kexample.net.+013+34505.key` |
| `dnssec-cds` | Actualizar el `DS` de un padre a partir del `CDS` de un hijo | `dnssec-cds -s /var/lib/bind/zones -f db.parent -d /var/lib/bind/zones example.net` |
| `dnssec-importkey` | Importar una clave pública externa | `dnssec-importkey -f pubkey.txt example.net` |
| `tsig-keygen` | Generar un bloque de clave TSIG | `tsig-keygen -a hmac-sha256 xfr-key` |
| `rndc` | Canal de control | `rndc dnssec -status example.net`, `rndc nta -d 3600 zone`, `rndc managed-keys status`, `rndc sign zone`, `rndc loadkeys zone` |
| `dig` | Consultar e inspeccionar | `dig +dnssec +multi`, `+cd`, `+tls`, `+https`, `-y`, `-k`, `+trace`, `+nsid`, `+bufsize=1232` |
| `delv` | Validación DNSSEC **del lado del cliente** | `delv +vtrace @resolver name TYPE` |
| `nsupdate` | Actualización dinámica RFC 2136 | `nsupdate -k Kacme.+165+42817.key -v` |
| `danetool` | Utilidad DANE de GnuTLS | `danetool --check host --port 25 --starttls-proto smtp` |
| `openssl` | Generación de TLSA y verificación DANE | `openssl x509 -noout -pubkey`, `openssl s_client -dane_tlsa_domain ... -dane_tlsa_rrdata ...` |
| `resolvectl` | Control de systemd-resolved | `resolvectl status`, `query`, `statistics`, `flush-caches`, `show-server-state` |
| `kdig` | El `dig` de Knot — el mejor cliente DoT/DoQ | `kdig +tls @host +tls-hostname=... name` |

---

## Referencias

**Objetivos de la certificación**

- LPI — Exam 303 Objectives (303-300, v3.0): https://www.lpi.org/our-certifications/exam-303-objectives/
- LPI — LPIC-3 Security certification overview: https://www.lpi.org/our-certifications/lpic-3-security-overview/

**DNSSEC — especificaciones centrales**

- RFC 4033 — DNS Security Introduction and Requirements: https://www.rfc-editor.org/rfc/rfc4033
- RFC 4034 — Resource Records for the DNS Security Extensions: https://www.rfc-editor.org/rfc/rfc4034
- RFC 4035 — Protocol Modifications for the DNS Security Extensions: https://www.rfc-editor.org/rfc/rfc4035
- RFC 5155 — DNSSEC Hashed Authenticated Denial of Existence (NSEC3): https://www.rfc-editor.org/rfc/rfc5155
- RFC 6840 — Clarifications and Implementation Notes for DNSSEC: https://www.rfc-editor.org/rfc/rfc6840
- RFC 8624 — Algorithm Implementation Requirements and Usage Guidance for DNSSEC: https://www.rfc-editor.org/rfc/rfc8624
- RFC 9276 — Guidance for NSEC3 Parameter Settings: https://www.rfc-editor.org/rfc/rfc9276
- RFC 8198 — Aggressive Use of DNSSEC-Validated Cache: https://www.rfc-editor.org/rfc/rfc8198
- RFC 6605 — Elliptic Curve DSA for DNSSEC: https://www.rfc-editor.org/rfc/rfc6605
- RFC 8080 — Edwards-Curve DSA for DNSSEC: https://www.rfc-editor.org/rfc/rfc8080

**Gestión y rotación de claves**

- RFC 5011 — Automated Updates of DNS Security Trust Anchors: https://www.rfc-editor.org/rfc/rfc5011
- RFC 6781 — DNSSEC Operational Practices, Version 2: https://www.rfc-editor.org/rfc/rfc6781
- RFC 7344 — Automating DNSSEC Delegation Trust Maintenance (CDS/CDNSKEY): https://www.rfc-editor.org/rfc/rfc7344
- RFC 8078 — Managing DS Records from the Parent via CDS/CDNSKEY: https://www.rfc-editor.org/rfc/rfc8078
- RFC 8901 — Multi-Signer DNSSEC Models: https://www.rfc-editor.org/rfc/rfc8901
- IANA — DNSSEC Root Trust Anchors: https://www.iana.org/dnssec/files
- IANA — Root Zone KSK Rollover information: https://www.iana.org/dnssec/ceremonies

**Seguridad de transacciones**

- RFC 8945 — Secret Key Transaction Authentication for DNS (TSIG): https://www.rfc-editor.org/rfc/rfc8945
- RFC 2931 — DNS Request and Transaction Signatures (SIG(0)): https://www.rfc-editor.org/rfc/rfc2931
- RFC 3645 — GSS Algorithm for TSIG (GSS-TSIG): https://www.rfc-editor.org/rfc/rfc3645
- RFC 2136 — Dynamic Updates in the Domain Name System: https://www.rfc-editor.org/rfc/rfc2136
- RFC 9103 — DNS Zone Transfer over TLS (XoT): https://www.rfc-editor.org/rfc/rfc9103

**DANE**

- RFC 6698 — The DNS-Based Authentication of Named Entities (DANE) Protocol for TLS: https://www.rfc-editor.org/rfc/rfc6698
- RFC 7671 — DANE Protocol: Updates and Operational Guidance: https://www.rfc-editor.org/rfc/rfc7671
- RFC 7672 — SMTP Security via Opportunistic DANE TLS: https://www.rfc-editor.org/rfc/rfc7672
- RFC 7673 — Using DANE TLSA Records with SRV Records: https://www.rfc-editor.org/rfc/rfc7673
- RFC 8461 — SMTP MTA Strict Transport Security (MTA-STS): https://www.rfc-editor.org/rfc/rfc8461
- RFC 8460 — SMTP TLS Reporting: https://www.rfc-editor.org/rfc/rfc8460
- Postfix — TLS Readme (DANE section): https://www.postfix.org/TLS_README.html#client_tls_dane

**Transportes cifrados**

- RFC 7858 — Specification for DNS over Transport Layer Security (DoT): https://www.rfc-editor.org/rfc/rfc7858
- RFC 8310 — Usage Profiles for DNS over TLS and DTLS: https://www.rfc-editor.org/rfc/rfc8310
- RFC 8484 — DNS Queries over HTTPS (DoH): https://www.rfc-editor.org/rfc/rfc8484
- RFC 9250 — DNS over Dedicated QUIC Connections (DoQ): https://www.rfc-editor.org/rfc/rfc9250
- RFC 9230 — Oblivious DNS over HTTPS (ODoH): https://www.rfc-editor.org/rfc/rfc9230
- RFC 9462 — Discovery of Designated Resolvers: https://www.rfc-editor.org/rfc/rfc9462
- DNSCrypt — protocol specification: https://dnscrypt.info/protocol/
- `dnscrypt-proxy` documentation: https://github.com/DNSCrypt/dnscrypt-proxy/wiki

**Endurecimiento operativo**

- RFC 9156 — DNS Query Name Minimisation to Improve Privacy: https://www.rfc-editor.org/rfc/rfc9156
- RFC 8900 — IP Fragmentation Considered Fragile: https://www.rfc-editor.org/rfc/rfc8900
- RFC 8976 — Message Digest for DNS Zones (ZONEMD): https://www.rfc-editor.org/rfc/rfc8976
- RFC 9432 — DNS Catalog Zones: https://www.rfc-editor.org/rfc/rfc9432
- DNS Flag Day 2020 — EDNS buffer size: https://dnsflagday.net/2020/

**Documentación de implementaciones**

- ISC — BIND 9 Administrator Reference Manual: https://bind9.readthedocs.io/en/latest/
- ISC — DNSSEC Guide: https://bind9.readthedocs.io/en/latest/dnssec-guide.html
- ISC — `dnssec-policy` reference: https://bind9.readthedocs.io/en/latest/reference.html#dnssec-policy-grammar
- ISC — `rndc` manual page: https://bind9.readthedocs.io/en/latest/manpages.html#rndc-name-server-control-utility
- NLnet Labs — Unbound documentation: https://unbound.docs.nlnetlabs.nl/
- NLnet Labs — DNSSEC key rollover guidance: https://nlnetlabs.nl/documentation/
- CZ.NIC — Knot DNS documentation: https://www.knot-dns.cz/documentation/
- freedesktop.org — `systemd-resolved` manual: https://www.freedesktop.org/software/systemd/man/latest/systemd-resolved.service.html
- freedesktop.org — `resolved.conf` manual: https://www.freedesktop.org/software/systemd/man/latest/resolved.conf.html
- OpenSSL — `s_client` manual (DANE options): https://docs.openssl.org/master/man1/openssl-s_client/
- cert-manager — RFC 2136 (TSIG) DNS-01 solver: https://cert-manager.io/docs/configuration/acme/dns01/rfc2136/

**Servicios de diagnóstico**

- DNSViz — visual analysis of DNSSEC chains: https://dnsviz.net/
- Verisign Labs — DNSSEC Debugger: https://dnssec-analyzer.verisignlabs.com/
- Zonemaster — DNS delegation and DNSSEC testing: https://zonemaster.net/
- Internet.nl — DNSSEC, DANE and mail security tests: https://internet.nl/
- ICANN — DNSSEC deployment statistics: https://stats.dnssec-tools.org/
- APNIC Labs — DNSSEC validation measurement: https://stats.labs.apnic.net/dnssec