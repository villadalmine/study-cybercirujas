# 334.2 — Detección de Intrusiones en Red

**Certificación:** LPIC-3 Security (examen 303-300, v3.0.0) · **Tema:** 334 Seguridad de Red · **Objetivo:** 334.2
**Peso del examen:** 6.67 (normalizado por la plataforma) · **Audiencia:** Platform Architect / SRE operando NSM a escala productiva

---

## 1. Motivación: el problema arquitectónico

Operás una flota. Los hosts están endurecidos (332.1), MAC está aplicado (333.2), los filtros de paquetes están en su lugar (334.3). Cada uno de esos controles responde la pregunta *"¿esta acción está permitida?"* — ninguno responde *"¿qué está cruzando realmente el cable, y parece una intrusión?"*

La brecha es concreta y recurrente:

- **Un flujo permitido puede ser un ataque.** `443/tcp egress → internet` está permitido para cada pod de tu clúster. Es también el canal exacto que usa un beacon de C2. El firewall ve cumplimiento de política; solo la inspección de tráfico ve un beacon con jitter de 60 segundos hacia un dominio registrado hace nueve horas.
- **La telemetría de host puede ser deshabilitada por el atacante.** auditd, Falco y el agente EDR corren todos *en la máquina que está siendo comprometida*. Un sensor de red sobre un TAP pasivo no tiene ninguna interfaz con dirección IP en el segmento monitoreado — no puede ser alcanzado, reconfigurado ni silenciado desde la víctima. Por eso el NIDS sobrevive como plano de control independiente y por eso es un objetivo separado de 332.2 (Detección de Intrusiones en Host).
- **El movimiento lateral es invisible desde cualquier host individual.** El host A registra un login SSH exitoso. El host B registra un login SSH exitoso. Solo una vista de red ve que el mismo origen recorrió 43 hosts en 90 segundos.
- **El análisis retrospectivo necesita el registro crudo.** Cuando se publica un CVE un martes por una vulnerabilidad explotada el jueves anterior, los logs de host ya rotaron. PCAP de fidelidad completa o logs de protocolo (Zeek) te permiten responder "¿nos golpearon?" en vez de "no tenemos forma de saberlo".

### 1.1 Las tres disciplinas distintas que el objetivo confunde

LPI las agrupa; producción las separa, porque tienen modos de falla distintos, costos distintos y semánticas de guardia distintas.

| Disciplina | Pregunta que responde | Herramientas canónicas (303-300) | Datos producidos | Modo de falla |
|---|---|---|---|---|
| **Detección de Intrusiones en Red (NIDS)** | "¿Este paquete/stream coincide con una firma conocida como maliciosa o con una anomalía?" | Snort, Suricata | Alertas (orientado a eventos) | Los falsos positivos ahogan al SOC; los falsos negativos son silenciosos |
| **Monitoreo de Seguridad de Red (NSM)** | "¿Qué pasó en esta red, en términos de protocolo?" | Zeek (conocimiento general), logs de protocolo EVE de Suricata | Logs de transacciones (siempre activos) | Explosión de almacenamiento; no alerta por sí solo |
| **Monitoreo de red / visibilidad de flujos** | "¿Cuánto, desde dónde hacia dónde, está sano?" | ntop/ntopng, Cacti | Series temporales + flujos | Ciego al payload; huecos en el sondeo SNMP |
| **Escaneo de vulnerabilidades / seguridad** | "¿Qué debilidades existen antes de que alguien ataque?" | OpenVAS / Greenbone, NASL | Hallazgos + CVSS | Obsolescencia del feed; los escaneos son en sí mismos disruptivos |

Una plataforma de seguridad productiva corre **las cuatro**. El examen espera que puedas instalar, configurar y mantener cada una, y que *conozcas las reglas de Snort* y NASL a nivel de sintaxis.

### 1.2 Detección vs. prevención: el compromiso de disponibilidad

| Propiedad | IDS (pasivo, fuera de banda) | IPS (en línea, en banda) |
|---|---|---|
| Ubicación | Puerto SPAN, TAP de red, túnel ERSPAN | Bridge, salto ruteado, `NFQUEUE` en el host |
| Impacto de la falla del sensor | Solo pérdida de visibilidad | **Pérdida de conectividad** salvo que se haya diseñado el fail-open |
| Latencia añadida | Cero | 20 µs – varios ms por paquete |
| Puede detener un ataque | No (la inyección de TCP RST es best-effort y sujeta a carreras) | Sí (`drop`, `reject`) |
| Resistencia a evasión | Menor (el sensor puede reensamblar distinto al host) | Mayor (el sensor *es* el camino; se aplica normalización) |
| Tolerancia a pérdida de paquetes | Degrada la calidad de detección | Degrada **el servicio** |
| Radio de impacto típico de una regla mala | Una alerta ruidosa | Una caída de producción |
| Dónde lo ponen realmente los SRE | En todos lados, primero | Segmentos estrechos de alto valor, después de meses de baselining con IDS |

**Regla arquitectónica práctica:** nunca despliegues una firma en modo IPS `drop` que no haya corrido al menos un ciclo de negocio completo en modo IDS `alert` sobre el mismo tráfico. Una regla con 0.01% de tasa de falsos positivos es una molestia menor en IDS y un Sev-1 en IPS.

### 1.3 Dónde ve el tráfico el sensor

```
                       ┌──────────────────────────────────────────┐
   Internet ───────────┤  Border router / firewall (334.3)        │
                       └───────────┬──────────────────────────────┘
                                   │
                        ┌──────────┴───────────┐
                        │  Passive optical TAP │──► copy ──┐
                        └──────────┬───────────┘           │
                                   │                       │
                        ┌──────────┴───────────┐    ┌──────▼───────────────┐
                        │  Core switch          │    │ SENSOR (no IP on the │
                        │  SPAN/RSPAN/ERSPAN ───┼───►│ monitored segment)   │
                        └──────────┬───────────┘    │ Suricata + Zeek       │
                                   │                │ eth0: mgmt (10.10.0.9)│
              ┌────────────────────┼──────────┐     │ eth1: capture (no IP) │
              │                    │          │     └──────┬────────────────┘
        ┌─────▼─────┐        ┌─────▼─────┐  ┌─▼────┐       │ EVE JSON / Zeek TSV
        │ Node pool │        │ DB tier   │  │ DMZ  │       ▼
        └───────────┘        └───────────┘  └──────┘   Elasticsearch / Loki / Kafka
```

| Método de tap | Fidelidad | Costo | ¿Falla abierto? | Notas |
|---|---|---|---|---|
| **TAP óptico pasivo** | 100%, ambas direcciones, sin sobresuscripción | Hardware por enlace | Sí (vidrio) | Estándar de oro; no puede ver tráfico intra-switch |
| **SPAN / port mirror** | Pierde bajo sobresuscripción; el switch desprioriza SPAN | Gratis | N/A | El más común; *silenciosamente* con pérdidas — hay que medirlo |
| **ERSPAN (encapsulado en GRE)** | Igual que SPAN + riesgo de MTU del túnel | Gratis | N/A | Permite centralizar sensores; Suricata decodifica ERSPAN nativamente |
| **AF_PACKET en el host / nodo** | Ve solo el tráfico de ese host | Gratis | Sí | La respuesta nativa de Kubernetes (DaemonSet con `hostNetwork`) |
| **Bridge en línea (IPS)** | 100% | Latencia + riesgo | Solo con una NIC de bypass | Requiere bypass por hardware o ingeniería de `fail-open` |
| **Redirección eBPF/XDP** | Line rate, algo así como kernel-bypass | CPU | Sí | `af-xdp` de Suricata 7, o filtro XDP para descartar tráfico conocido como bueno |

### 1.4 El problema del cifrado — decilo honestamente

Prácticamente todo el tráfico interesante es TLS. Un motor de firmas no puede hacer match sobre `content:"cmd.exe"` dentro de TLS 1.3. Lo que queda visible, y sobre lo que realmente detectan los NIDS modernos:

| Visible bajo TLS 1.3 | Valor de detección |
|---|---|
| SNI (salvo que se use ECH) | Reputación de dominio, DGA, typosquatting |
| Cadena de certificados (TLS ≤1.2 en claro; 1.3 cifrado) | C2 autofirmado, emisores conocidos como maliciosos, pivot por JA3S |
| Fingerprint de cliente JA3 / JA4 | Stacks TLS de malware que difieren del navegador del host |
| Forma del flujo: tamaño, temporización, jitter, ratios de bytes | Beaconing, volumen de exfiltración |
| DNS (salvo DoH/DoT) | El protocolo en texto plano de mayor rendimiento que queda |
| Anomalías a nivel de paquete | Tunelización, protocolo en puerto equivocado |

**Consecuencia para la arquitectura:** la proporción de valor se desplaza desde las *firmas* hacia los *logs de NSM más analítica*. Por eso Zeek pertenece a un stack productivo aunque el examen solo requiera conocimiento general de él, y por eso los eventos de protocolo de `eve.json` de Suricata (`tls`, `dns`, `flow`, `anomaly`) importan tanto como sus eventos `alert`.

---

## 2. Comparación de motores: Snort 3 vs Suricata 7 vs Zeek 6

| Dimensión | **Snort 3** | **Suricata 7** | **Zeek 6** |
|---|---|---|---|
| Modelo | IDS/IPS por firmas | IDS/IPS por firmas + NSM | Analizador de protocolos + scripting (NSM) |
| Origen / licencia | Cisco / GPLv2 | OISF / GPLv2 | Corelight+comunidad / BSD |
| Concurrencia | Multi-hilo (Snort 3 reescribió esto; Snort 2 era mono-hilo) | Multi-hilo desde el día uno; runmode `workers` | **Cluster** multi-proceso (manager/proxy/workers) |
| Lenguaje de configuración | **Lua** (`snort.lua`) | **YAML** (`suricata.yaml`) | **Zeek script** (`local.zeek`) + `node.cfg` |
| Lenguaje de reglas | Reglas de Snort 3 | Compatible con Snort + extensiones de Suricata (sticky buffers, `lua`, datasets) | Sin reglas; scripts + framework Intel |
| Multi-pattern matcher | Hyperscan / AC | **Hyperscan** (Intel), AC-KS, AC-BS | N/A |
| Salida nativa | `alert_fast`, `alert_full`, `alert_json`, `alert_csv`, `unified2` (legacy) | **EVE JSON** (alert, http, dns, tls, flow, files, anomaly, stats) | Logs TSV o JSON por protocolo (`conn.log`, `dns.log`, `ssl.log`, `files.log`, `notice.log`) |
| Extracción / hashing de archivos | Política `file_id`, MD5/SHA | `file-store` + MD5/SHA1/SHA256 | `files.log`, `FileExtract` |
| Scripting Lua en reglas | Sí (opciones de regla) | Sí (keyword `lua`) | Todo el motor está scripteado |
| Transportes IPS | `daq afpacket` (pares en línea), `nfq`, `ipfw` | pares en línea `af-packet`, `nfqueue`, `ipfw`, DPDK | **Ninguno** (solo pasivo) |
| Captura con kernel-bypass | AF_PACKET, PF_RING, DPDK (vía DAQ) | AF_PACKET, AF_XDP, PF_RING, **DPDK**, netmap | AF_PACKET, PF_RING |
| IPv6 / túneles | Sí (GRE, ERSPAN, VXLAN, Teredo) | Sí, más GENEVE, VXLAN, ERSPAN I/II, MPLS | Sí |
| Mejor en | Matching determinista de firmas, ecosistema Cisco Talos | Firmas de alto throughput + logging de protocolos en un solo proceso | Analítica profunda de comportamiento/protocolo, lógica personalizada |
| Debilidad | Menos loggers de protocolo; equivalente a EVE más chico | Carga de tuning de reglas; dimensionamiento de memcaps | Sin bloqueo; curva de aprendizaje más empinada; más CPU por Gbps |
| Feeds de reglas | Talos (VRT, subscriber/registered), comunidad | ET Open / ET Pro, más comunidad de Snort | Feeds de Intel (MISP, CIF) |

**Guía de selección para el arquitecto:**

- **Suricata** como sensor por defecto: un solo proceso te da firmas **y** logs JSON de calidad NSM, y su camino `af-packet` + Hyperscan escala a 10 Gbps+ sobre CPUs commodity.
- **Zeek** al lado cuando necesitás comportamiento que ninguna firma expresa ("cualquier host que hizo más de N consultas DNS NXDOMAIN distintas en 60s") e historia de protocolos con retención larga.
- **Snort 3** cuando la organización está estandarizada sobre suscripciones de reglas de Talos o herramientas de Cisco, o cuando el examen lo pide — sigue siendo de primera clase y está explícitamente en los objetivos (`snort-stat`, `/etc/snort/*`).

---

## 3. Suricata: puesta en producción

### 3.1 Instalación

```bash
$ sudo apt-get install -y suricata suricata-update jq
$ suricata --build-info | head -n 30
This is Suricata version 7.0.5 RELEASE
Features: PCAP_SET_BUFF AF_PACKET AF_XDP HAVE_PACKET_FANOUT LIBCAP_NG LIBNET1.1 HAVE_HTP_URI_NORMALIZE_HOOK PCRE_JIT HAVE_NSS HAVE_LUA HAVE_LUAJIT HAVE_LIBJANSSON TLS TLS_C11 MAGIC RUST POPCNT64
SIMD support: SSE_4_2 SSE_4_1 SSE_3
Atomic intrinsics: 1 2 4 8 16 byte(s)
64-bits, Little-endian architecture
GCC version 12.2.0, C version 201112
compiled with _FORTIFY_SOURCE=2
L1 cache line size (CLS)=64
thread local storage method: __thread
compiled with LibHTP v0.5.46, linked against LibHTP v0.5.46

Suricata Configuration:
  AF_PACKET support:                       yes
  AF_XDP support:                          yes
  DPDK support:                            yes
  eBPF support:                            yes
  XDP support:                             yes
  Hyperscan support:                       yes
  Libnet support:                          yes
  NFQueue support:                         yes
```

Las dos líneas que deciden tu techo de throughput son **`Hyperscan support: yes`** y **`AF_PACKET support: yes`**. Un build de la distro sin Hyperscan te va a costar aproximadamente 2–3× de CPU sobre el mismo ruleset.

### 3.2 `suricata.yaml` de producción completo

Esta es una configuración completa y ejecutable para un sensor pasivo sobre `enp3s0f1`, 8 hilos de trabajo, salida EVE JSON, Hyperscan y memcaps correctamente dimensionados para un segmento de ~2 Gbps.

```yaml
%YAML 1.1
---
# /etc/suricata/suricata.yaml
# Production passive NIDS/NSM sensor — 2 Gbps segment, 8 workers, NUMA node 0.

vars:
  address-groups:
    HOME_NET: "[10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,fd00::/8]"
    EXTERNAL_NET: "!$HOME_NET"
    HTTP_SERVERS: "$HOME_NET"
    SMTP_SERVERS: "$HOME_NET"
    SQL_SERVERS: "[10.40.12.0/24]"
    DNS_SERVERS: "[10.10.0.10,10.10.0.11]"
    TELNET_SERVERS: "$HOME_NET"
    AIM_SERVERS: "$EXTERNAL_NET"
    DC_SERVERS: "[10.10.4.0/24]"
    DNP3_SERVER: "$HOME_NET"
    DNP3_CLIENT: "$HOME_NET"
    MODBUS_CLIENT: "$HOME_NET"
    MODBUS_SERVER: "$HOME_NET"
    ENIP_CLIENT: "$HOME_NET"
    ENIP_SERVER: "$HOME_NET"
  port-groups:
    HTTP_PORTS: "[80,81,591,593,3128,3702,7080,8000,8008,8028,8080,8081,8088,8118,8123,8180,8181,8243,8280,8300,8800,8888,8899,9000,9080,9090,9091,9443,9999]"
    SHELLCODE_PORTS: "!80"
    ORACLE_PORTS: 1521
    SSH_PORTS: "[22,2222]"
    DNP3_PORTS: 20000
    MODBUS_PORTS: 502
    FILE_DATA_PORTS: "[$HTTP_PORTS,110,143]"
    FTP_PORTS: 21
    GENEVE_PORTS: 6081
    VXLAN_PORTS: 4789
    TEREDO_PORTS: 3544

default-log-dir: /var/log/suricata/

stats:
  enabled: yes
  interval: 30
  decoder-events: true
  decoder-events-prefix: "decoder.event"
  stream-events: false

plugins: []

outputs:
  - fast:
      enabled: no
      filename: fast.log
      append: yes

  - eve-log:
      enabled: yes
      filetype: regular          # regular | syslog | unix_dgram | unix_stream | redis
      filename: eve.json
      # Rotate via logrotate + `suricatasc -c reopen-log-files`
      pcap-file: false
      community-id: true         # correlate with Zeek / Arkime / Elastic
      community-id-seed: 0
      xff:
        enabled: yes
        mode: extra-data
        deployment: reverse
        header: X-Forwarded-For
      types:
        - alert:
            payload: yes
            payload-buffer-size: 4kb
            payload-printable: yes
            packet: yes
            metadata: yes
            http-body: yes
            http-body-printable: yes
            tagged-packets: yes
        - anomaly:
            enabled: yes
            types:
              decode: yes
              stream: yes
              applayer: yes
        - http:
            extended: yes
            custom: [Accept-Encoding, Accept-Language, Authorization, Referer]
        - dns:
            version: 2
            enabled: yes
            requests: yes
            responses: yes
        - tls:
            extended: yes
            ja3: yes
        - files:
            force-magic: yes
            force-hash: [md5, sha256]
        - smtp:
            extended: yes
        - ssh
        - stats:
            totals: yes
            threads: yes            # per-thread counters are how you find one hot worker
            deltas: yes
        - flow
        - netflow
        - dhcp:
            enabled: yes
            extended: yes
        - krb5
        - snmp
        - rdp
        - sip
        - ftp
        - mqtt
        - ike
        - dcerpc
        - drop:
            alerts: yes
            flows: all

  - http-log:
      enabled: no
      filename: http.log
      append: yes

  - pcap-log:
      enabled: no                # enable only with a sized ring buffer; see §7.6
      filename: log.pcap
      limit: 1000mb
      max-files: 2000
      compression: lz4
      lz4-checksum: no
      lz4-level: 0
      mode: multi
      dir: /srv/pcap
      use-stream-depth: no
      honor-pass-rules: no

  - alert-debug:
      enabled: no
      filename: alert-debug.log
      append: yes

  - stats:
      enabled: yes
      filename: stats.log
      append: no                 # overwrite: this is a gauge snapshot, not a journal
      totals: yes
      threads: yes

  - syslog:
      enabled: no
      facility: local5
      level: Info

  - file-store:
      version: 2
      enabled: no                # storing extracted files needs a retention policy first
      dir: filestore
      write-fileinfo: yes
      stream-depth: 0
      max-open-files: 0
      force-filestore: no

logging:
  default-log-level: notice
  default-output-filter:
  outputs:
    - console:
        enabled: yes
    - file:
        enabled: yes
        level: info
        filename: /var/log/suricata/suricata.log
    - syslog:
        enabled: no
        facility: local5
        format: "[%i] <%d> -- "

af-packet:
  - interface: enp3s0f1
    threads: 8                   # MUST match RSS queue count — see §7.2
    cluster-id: 99
    cluster-type: cluster_flow   # cluster_flow | cluster_cpu | cluster_qm | cluster_ebpf
    defrag: yes
    use-mmap: yes
    mmap-locked: yes
    tpacket-v3: yes
    ring-size: 200000            # frames per ring; raise until kernel_drops == 0
    block-size: 1048576
    buffer-size: 128000000
    checksum-checks: kernel      # kernel | yes | no | auto
    copy-mode: no                # 'ips' or 'tap' for inline pairs
  - interface: default
    threads: auto
    cluster-id: 98
    cluster-type: cluster_flow
    defrag: yes
    use-mmap: yes

af-xdp:
  - interface: default
    threads: auto
    disable-promisc: false
    force-xdp-mode: none
    force-bind-mode: none
    mem-unaligned: no
    gro-flush-timeout: 2000000
    napi-defer-hard-irq: 2

pcap:
  - interface: enp3s0f1
    buffer-size: 128000000
    checksum-checks: auto
  - interface: default

pcap-file:
  checksum-checks: auto

app-layer:
  protocols:
    rfb:
      enabled: yes
      detection-ports:
        dp: 5900, 5901, 5902, 5903, 5904, 5905, 5906, 5907, 5908, 5909
    mqtt:
      enabled: yes
    krb5:
      enabled: yes
    snmp:
      enabled: yes
    ikev2:
      enabled: yes
    tls:
      enabled: yes
      detection-ports:
        dp: "[443,444,465,853,993,995,3269,3306,5061,6379,6697,8443,9001,9443]"
      ja3-fingerprints: auto
      encryption-handling: default
    dcerpc:
      enabled: yes
    ftp:
      enabled: yes
    rdp:
      enabled: yes
    ssh:
      enabled: yes
      hassh: yes
    http2:
      enabled: yes
    smtp:
      enabled: yes
      raw-extraction: no
      mime:
        decode-mime: yes
        decode-base64: yes
        decode-quoted-printable: yes
        header-value-depth: 2000
        extract-urls: yes
        body-md5: no
      inspected-tracker:
        content-limit: 100000
        content-inspect-min-size: 32768
        content-inspect-window: 4096
    imap:
      enabled: detection-only
    smb:
      enabled: yes
      detection-ports:
        dp: 139, 445
    nfs:
      enabled: yes
    tftp:
      enabled: yes
    dns:
      tcp:
        enabled: yes
        detection-ports:
          dp: 53
      udp:
        enabled: yes
        detection-ports:
          dp: 53
    http:
      enabled: yes
      libhtp:
        default-config:
          personality: IDS
          request-body-limit: 100kb
          response-body-limit: 100kb
          request-body-minimal-inspect-size: 32kb
          request-body-inspect-window: 4kb
          response-body-minimal-inspect-size: 40kb
          response-body-inspect-window: 16kb
          response-body-decompress-layer-limit: 2
          http-body-inline: auto
          swf-decompression:
            enabled: no
            type: both
            compress-depth: 100kb
            decompress-depth: 100kb
          double-decode-path: no
          double-decode-query: no
        server-config:
          - apache:
              address: [10.20.0.0/24]
              personality: Apache_2
              request-body-limit: 4096
              response-body-limit: 4096
              double-decode-path: no
              double-decode-query: no
          - iis:
              address: [10.30.0.0/24]
              personality: IIS_7_0
              request-body-limit: 4096
              response-body-limit: 4096
              double-decode-path: yes
              double-decode-query: yes
    modbus:
      enabled: no
      detection-ports:
        dp: 502
      stream-depth: 0
    dnp3:
      enabled: no
      detection-ports:
        dp: 20000
    enip:
      enabled: no
      detection-ports:
        dp: 44818
        sp: 44818
    sip:
      enabled: yes
    templat:
      enabled: no
    rdp:
      enabled: yes

asn1-max-frames: 256

security:
  limit-noproc: true
  landlock:
    enabled: no
  lua:
    allow-rules: false

run-as:
  user: suricata
  group: suricata

coredump:
  max-dump: unlimited

host-mode: auto

unix-command:
  enabled: yes
  filename: /var/run/suricata/suricata-command.socket

legacy:
  uricontent: enabled

exception-policy: auto

engine-analysis:
  rules-fast-pattern: yes
  rules: yes

pcre:
  match-limit: 3500
  match-limit-recursion: 1500

host-os-policy:
  windows: [0.0.0.0/0]
  bsd: []
  bsd-right: []
  old-linux: []
  linux: [10.0.0.0/8, 192.168.1.0/24]
  old-solaris: []
  solaris: []
  hpux10: []
  hpux11: []
  irix: []
  macos: []
  vista: []
  windows2k3: []

defrag:
  memcap: 512mb
  hash-size: 65536
  trackers: 65535
  max-frags: 65535
  prealloc: yes
  timeout: 60

flow:
  memcap: 2gb                  # ~ 290 bytes/flow: 2 GB ≈ 7M concurrent flows
  hash-size: 262144
  prealloc: 100000
  emergency-recovery: 30
  managers: 1
  recyclers: 1

vlan:
  use-for-tracking: true

flow-timeouts:
  default:
    new: 30
    established: 300
    closed: 0
    bypassed: 100
    emergency-new: 10
    emergency-established: 100
    emergency-closed: 0
    emergency-bypassed: 50
  tcp:
    new: 60
    established: 600
    closed: 60
    bypassed: 100
    emergency-new: 5
    emergency-established: 100
    emergency-closed: 10
    emergency-bypassed: 50
  udp:
    new: 30
    established: 300
    bypassed: 100
    emergency-new: 10
    emergency-established: 100
    emergency-bypassed: 50
  icmp:
    new: 30
    established: 300
    bypassed: 100
    emergency-new: 10
    emergency-established: 100
    emergency-bypassed: 50

stream:
  memcap: 4gb
  checksum-validation: no       # offloads are disabled; kernel already validated
  inline: auto
  bypass: false
  prealloc-sessions: 100000
  midstream: false
  async-oneside: false
  reassembly:
    memcap: 8gb
    depth: 4mb                  # bytes per flow reassembled; > this is not inspected
    toserver-chunk-size: 2560
    toclient-chunk-size: 2560
    randomize-chunk-size: yes
    randomize-chunk-range: 10

host:
  hash-size: 4096
  prealloc: 1000
  memcap: 128mb

decoder:
  teredo:
    enabled: true
    ports: $TEREDO_PORTS
  vxlan:
    enabled: true
    ports: $VXLAN_PORTS
  geneve:
    enabled: true
    ports: $GENEVE_PORTS
  erspan:
    typeI:
      enabled: false

detect:
  profile: high                 # low | medium | high | custom
  custom-values:
    toclient-groups: 3
    toserver-groups: 25
  sgh-mpm-context: auto
  inspection-recursion-limit: 3000
  prefilter:
    default: mpm
  grouping:
    tcp-whitelist: 53, 80, 139, 443, 445, 1433, 3306, 3389, 6666, 6667, 8080
    udp-whitelist: 53, 135, 5060
  profiling:
    grouping:
      dump-to-disk: false
      include-rules: false
      include-mpm-stats: false

mpm-algo: hs                    # hs = Hyperscan; ac | ac-bs | ac-ks | hs
spm-algo: hs

threading:
  set-cpu-affinity: yes
  cpu-affinity:
    - management-cpu-set:
        cpu: [ 0 ]
    - receive-cpu-set:
        cpu: [ 0 ]
    - worker-cpu-set:
        cpu: [ 2, 4, 6, 8, 10, 12, 14, 16 ]   # physical cores of NUMA node 0
        mode: "exclusive"
        prio:
          low: [ 0 ]
          medium: [ 1 ]
          high: [ 2, 4, 6, 8, 10, 12, 14, 16 ]
          default: "high"
  detect-thread-ratio: 1.0
  stack-size: 8mb

luajit:
  states: 128

profiling:
  rules:
    enabled: no
    filename: rule_perf.log
    append: yes
    limit: 100
    json: yes
  keywords:
    enabled: no
    filename: keyword_perf.log
    append: yes
  prefilter:
    enabled: no
    filename: prefilter_perf.log
    append: yes
  rulegroups:
    enabled: no
    filename: rule_group_perf.log
    append: yes
  packets:
    enabled: no
    filename: packet_stats.log
    append: yes
    csv:
      enabled: no
      filename: packet_stats.csv
  locks:
    enabled: no
    filename: lock_stats.log
    append: yes
  pcap-log:
    enabled: no
    filename: pcaplog_stats.log
    append: yes

nfq:
  mode: accept
  repeat-mark: 1
  repeat-mask: 1
  bypass-mark: 2
  bypass-mask: 2
  route-queue: 2
  batchcount: 20
  fail-open: yes               # CRITICAL for IPS: kernel accepts if Suricata dies

nflog:
  - group: 2
    buffer-size: 18432
  - group: default
    qthreshold: 1
    qtimeout: 100
    max-size: 20000

capture:
  disable-offloading: true      # Suricata itself calls ethtool -K on start
  checksum-validation: none

napatech:
  streams: ["0-3"]
  enable-stream-stats: no
  auto-config: yes

default-rule-path: /var/lib/suricata/rules
rule-files:
  - suricata.rules
  - local.rules

classification-file: /etc/suricata/classification.config
reference-config-file: /etc/suricata/reference.config
threshold-file: /etc/suricata/threshold.config

include: /etc/suricata/include/datasets.yaml
```

Validá antes de reiniciar el servicio, siempre:

```bash
$ sudo suricata -T -c /etc/suricata/suricata.yaml -v
Notice: suricata: This is Suricata version 7.0.5 RELEASE running in SYSTEM mode
Info: cpu: CPUs/cores online: 32
Info: suricata: Setting engine mode to IDS mode by default
Info: exception-policy: master exception-policy set to: auto
Info: detect: 1 rule files processed. 42817 rules successfully loaded, 0 rules failed, 0
Info: threshold-config: Threshold config parsed: 14 rule(s) found
Info: detect: 42820 signatures processed. 1214 are IP-only rules, 5301 are inspecting packet payload, 36988 inspect application layer, 108 are decoder event only
Notice: suricata: Configuration provided was successfully loaded. Exiting.
```

`suricata -T` sale con código distinto de cero ante cualquier error — esta es tu compuerta de CI (§9).

### 3.3 Gestión de reglas con `suricata-update`

`suricata-update` es el gestor de reglas soportado. Baja las fuentes, aplica transformaciones de enable/disable/modify y escribe un único `suricata.rules` fusionado.

```bash
$ sudo suricata-update update-sources
$ suricata-update list-sources
Name: et/open
  Vendor: Proofpoint
  Summary: Emerging Threats Open Ruleset
  License: MIT
Name: et/pro
  Vendor: Proofpoint
  Summary: Emerging Threats Pro Ruleset
  License: Commercial
  Parameters: secret-code
Name: oisf/trafficid
  Vendor: OISF
  Summary: Suricata Traffic ID ruleset
  License: MIT
Name: sslbl/ja3-fingerprints
  Vendor: Abuse.ch
  Summary: Abuse.ch Suricata JA3 Fingerprint Ruleset
  License: CC0-1.0
Name: tgreen/hunting
  Vendor: tgreen
  Summary: Threat hunting rules
  License: GPLv3

$ sudo suricata-update enable-source et/open
$ sudo suricata-update enable-source oisf/trafficid
$ sudo suricata-update enable-source sslbl/ja3-fingerprints
$ sudo suricata-update
21/8/2026 -- 09:14:02 - <Info> -- Using data-directory /var/lib/suricata.
21/8/2026 -- 09:14:02 - <Info> -- Using Suricata configuration /etc/suricata/suricata.yaml
21/8/2026 -- 09:14:02 - <Info> -- Using /etc/suricata/rules for Suricata provided rules.
21/8/2026 -- 09:14:02 - <Info> -- Found Suricata version 7.0.5 at /usr/bin/suricata.
21/8/2026 -- 09:14:03 - <Info> -- Loading /etc/suricata/disable.conf.
21/8/2026 -- 09:14:03 - <Info> -- Loading /etc/suricata/enable.conf.
21/8/2026 -- 09:14:03 - <Info> -- Loading /etc/suricata/modify.conf.
21/8/2026 -- 09:14:03 - <Info> -- Fetching https://rules.emergingthreats.net/open/suricata-7.0.5/emerging.rules.tar.gz.
 100% - 4382019/4382019
21/8/2026 -- 09:14:09 - <Info> -- Loading distribution rule file /etc/suricata/rules/app-layer-events.rules
21/8/2026 -- 09:14:10 - <Info> -- Ignoring file rules/emerging-deleted.rules
21/8/2026 -- 09:14:14 - <Info> -- Loaded 46012 rules.
21/8/2026 -- 09:14:15 - <Info> -- Disabled 1174 rules.
21/8/2026 -- 09:14:15 - <Info> -- Enabled 6 rules.
21/8/2026 -- 09:14:15 - <Info> -- Modified 21 rules.
21/8/2026 -- 09:14:15 - <Info> -- Dropped 0 rules.
21/8/2026 -- 09:14:16 - <Info> -- Enabled 138 rules for flowbit dependencies.
21/8/2026 -- 09:14:16 - <Info> -- Backing up current rules.
21/8/2026 -- 09:14:17 - <Info> -- Writing rules to /var/lib/suricata/rules/suricata.rules: total: 46012; enabled: 38821; added: 63; removed 11; modified: 209
21/8/2026 -- 09:14:19 - <Info> -- Writing /var/lib/suricata/rules/classification.config
21/8/2026 -- 09:14:19 - <Info> -- Testing with suricata -T.
21/8/2026 -- 09:14:47 - <Info> -- Done.
```

Archivos de control:

```bash
$ cat /etc/suricata/disable.conf
# Disable by SID
2019401
# Disable by regex over msg
re:heartbleed
# Disable a whole group
group:emerging-info.rules
# Disable by metadata key/value
metadata: created_at 2011_01_01

$ cat /etc/suricata/enable.conf
2010937
re:MALWARE-CNC
group:emerging-exploit.rules

$ cat /etc/suricata/modify.conf
# <sid|re:|group:> "<from-regex>" "<to>"
2019401 "alert" "drop"
re:"ET POLICY" "sid:(\d+);" "sid:\1; threshold: type limit, track by_src, count 1, seconds 300;"

$ cat /etc/suricata/drop.conf
# Every SID matching these becomes 'drop' (IPS mode only)
re:^ET TROJAN
2018959
```

Recarga de reglas **sin perder un solo paquete** (este es todo el sentido del live reload de Suricata):

```bash
$ sudo suricatasc -c "reload-rules"
{"message": "done", "return": "OK"}

# Non-blocking variant: returns immediately, reload happens in background
$ sudo suricatasc -c "ruleset-reload-nonblocking"
{"message": "done", "return": "OK"}

$ sudo suricatasc -c "ruleset-stats"
{"message": [{"rules_loaded": 38821, "rules_failed": 0, "last_reload": "2026-08-21T09:15:02.114331+0000"}], "return": "OK"}
```

Automatizalo, pero **escalonalo** a lo largo de la flota para que no todos los sensores recarguen simultáneamente:

```ini
# /etc/systemd/system/suricata-update.timer
[Unit]
Description=Daily Suricata ruleset update

[Timer]
OnCalendar=*-*-* 04:00:00
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
```

```ini
# /etc/systemd/system/suricata-update.service
[Unit]
Description=Update Suricata rules and hot-reload
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/suricata-update --no-test --quiet
ExecStart=/usr/bin/suricata -T -c /etc/suricata/suricata.yaml
ExecStart=/usr/bin/suricatasc -c ruleset-reload-nonblocking
```

Fijate en el orden: `suricata-update --no-test` escribe el archivo, un `suricata -T` **explícito** lo valida, y recién entonces se dispara la recarga. Si la validación falla, systemd se detiene y el motor en ejecución conserva su ruleset previo, que funcionaba.

### 3.4 El lenguaje de reglas de Suricata/Snort

```
action protocol src_ip src_port direction dst_ip dst_port (options)
   │      │                                                    │
   │      │                                                    └─ metadata + detection + post-match
   │      └─ ip | tcp | udp | icmp | http | tls | dns | smb | ssh | ftp | krb5 | dcerpc | ...
   └─ alert | drop | reject | pass   (drop/reject require IPS mode)
```

| Acción | Modo IDS | Modo IPS |
|---|---|---|
| `alert` | Registra la alerta | Registra la alerta, el paquete pasa |
| `pass` | Deja de inspeccionar este paquete/flujo | Igual; usalo para whitelisting |
| `drop` | Se registra como would-drop | El paquete se descarta silenciosamente, el flujo se bloquea |
| `reject` / `rejectsrc` / `rejectdst` / `rejectboth` | Envía RST/ICMP unreach (best-effort) | Descarta **y** envía RST/ICMP |

Una regla de producción completamente anotada:

```
alert http $HOME_NET any -> $EXTERNAL_NET any ( \
    msg:"LOCAL EXFIL Large multipart POST to newly-observed domain"; \
    flow:established,to_server; \
    http.method; content:"POST"; \
    http.header; content:"Content-Type|3a| multipart/form-data"; nocase; \
    http.host; content:!"corp.example.net"; endswith; \
    http.request_body; bsize:>5000000; \
    threshold: type limit, track by_src, count 1, seconds 300; \
    metadata: created_at 2026_08_21, updated_at 2026_08_21, \
              mitre_tactic_id TA0010, mitre_technique_id T1567; \
    reference:url,attack.mitre.org/techniques/T1567/; \
    classtype:policy-violation; sid:1000021; rev:2; )
```

Campo por campo, las partes que un SRE debe poder leer de un vistazo:

| Opción | Clase | Significado |
|---|---|---|
| `msg` | meta | Texto de la alerta. Prefijalo con una etiqueta de la organización (`LOCAL`) para que tus reglas sean grepeables contra las del proveedor |
| `sid` | meta | ID de firma. **1 000 000–1 999 999 es el rango local reservado** |
| `rev` | meta | Revisión. Incrementala en cada edición; el motor usa `sid:rev` para deduplicar |
| `classtype` | meta | Mapea a una prioridad vía `classification.config` |
| `reference` | meta | `url,`/`cve,`/`bugtraq,` — se expande vía `reference.config` |
| `metadata` | meta | Clave/valor libre; `suricata-update` filtra sobre esto; llevá los IDs de ATT&CK acá |
| `flow` | estado | `established`, `to_server`/`to_client`, `not_established`, `stateless` |
| `content` | payload | Match de bytes. `|3a|` es hexadecimal para `:` |
| `nocase`, `depth`, `offset`, `distance`, `within`, `startswith`, `endswith`, `bsize` | modificadores | Restringen dónde/cómo hace match `content` |
| `http.uri`, `http.host`, `tls.sni`, `dns.query`, `file.data`, `ja3.hash` | **sticky buffers** | Fijan el buffer para los `content`/`pcre` *subsiguientes* — el idioma moderno de Suricata, que reemplaza a los modificadores estilo `http_uri` |
| `pcre` | payload | Regex — **caro**; anclalo siempre detrás de un `content` para que el MPM prefiltre |
| `flowbits` | estado | Estado entre paquetes/entre reglas: `set`, `isset`, `unset`, `noalert` |
| `threshold` / `detection_filter` | tasa | `limit` (registrar como máximo N), `threshold` (registrar cada N-ésimo), `both` |
| `byte_test`, `byte_jump`, `byte_extract` | binario | Protocolos binarios con prefijo de longitud / dirigidos por offset |
| `dataset`, `datarep` | conjuntos | Match contra una lista grande en disco (feeds de IOC) con reputación |
| `tag` | post-match | Captura los paquetes subsiguientes del flujo dentro de la salida de la alerta |
| `xbits` | estado | Como flowbits pero con alcance de host y persistente entre flujos |

Una correlación de dos etapas con `flowbits` — "fallo de autenticación seguido de éxito desde el mismo flujo":

```
alert ftp $EXTERNAL_NET any -> $HOME_NET 21 (msg:"LOCAL FTP login failure observed"; \
    flow:established,to_client; content:"530 "; startswith; \
    flowbits:set,ftp.login_failed; flowbits:noalert; \
    classtype:not-suspicious; sid:1000030; rev:1;)

alert ftp $EXTERNAL_NET any -> $HOME_NET 21 (msg:"LOCAL FTP brute-force success after failures"; \
    flow:established,to_client; content:"230 "; startswith; \
    flowbits:isset,ftp.login_failed; \
    classtype:attempted-admin; sid:1000031; rev:1;)
```

Correlación con alcance de host usando `xbits` — "cualquier host que disparó una firma de escáner es de acá en más interesante durante 1 hora":

```
alert tcp $EXTERNAL_NET any -> $HOME_NET any (msg:"LOCAL Scanner behaviour"; \
    flags:S; threshold: type both, track by_src, count 100, seconds 10; \
    xbits:set,host.scanner,track ip_src,expire 3600; \
    classtype:attempted-recon; sid:1000040; rev:1;)

alert http $EXTERNAL_NET any -> $HOME_NET any (msg:"LOCAL HTTP request from recent scanner"; \
    flow:established,to_server; xbits:isset,host.scanner,track ip_src; \
    classtype:attempted-recon; sid:1000041; rev:1;)
```

Matching de protocolos binarios con `byte_test`/`byte_jump` (el patrón que al examen le gusta para "opciones avanzadas de reglas"):

```
alert tcp any any -> $HOME_NET 445 (msg:"LOCAL SMB2 oversized write length"; \
    flow:established,to_server; \
    content:"|FE|SMB"; depth:4; \
    content:"|09 00|"; distance:8; within:2;      /* SMB2 WRITE command */ \
    byte_test:4,>,1048576,36,relative,little; \
    classtype:attempted-admin; sid:1000050; rev:1;)
```

Feeds grandes de IOC vía `dataset` — la forma correcta de hacer match sobre 500 000 dominios sin 500 000 reglas:

```yaml
# /etc/suricata/include/datasets.yaml
datasets:
  c2-domains:
    type: string
    state: /var/lib/suricata/datasets/c2-domains.lst
  bad-ja3:
    type: string
    state: /var/lib/suricata/datasets/bad-ja3.lst
```

```
alert dns $HOME_NET any -> any any (msg:"LOCAL DNS query for known C2 domain"; \
    dns.query; dataset:isset,c2-domains; \
    classtype:trojan-activity; sid:1000060; rev:1;)

alert tls $HOME_NET any -> $EXTERNAL_NET any (msg:"LOCAL Malicious JA3 client fingerprint"; \
    ja3.hash; dataset:isset,bad-ja3; \
    classtype:trojan-activity; sid:1000061; rev:1;)
```

La supresión y el thresholding viven fuera de las reglas, en `threshold.config`, así nunca forkeás una regla del proveedor para silenciarla:

```
# /etc/suricata/threshold.config

# Suppress entirely for a known-good scanner host
suppress gen_id 1, sig_id 2010935, track by_src, ip 10.10.0.55

# Suppress a whole CIDR
suppress gen_id 1, sig_id 2013028, track by_dst, ip 10.40.12.0/24

# Rate-limit a chatty policy rule to 1 alert per source per 5 minutes
threshold gen_id 1, sig_id 2019401, type limit, track by_src, count 1, seconds 300

# Only alert on the 20th occurrence in 60s (classic brute force)
threshold gen_id 1, sig_id 2001219, type threshold, track by_src, count 20, seconds 60

# Global rate limit for a decoder event
threshold gen_id 1, sig_id 2200003, type limit, track by_src, count 5, seconds 600
```

Verificá cómo va a compilarse realmente una regla — qué buffer, qué fast pattern:

```bash
$ sudo suricata --engine-analysis -c /etc/suricata/suricata.yaml -S /etc/suricata/rules/local.rules
$ sed -n '1,40p' /var/log/suricata/rules_analysis.txt
== Sid: 1000021 ==
alert http $HOME_NET any -> $EXTERNAL_NET any (msg:"LOCAL EXFIL Large multipart POST ...")
    Rule matches on http uri buffer.
    Rule matches on http header buffer.
    App layer protocol is http.
    Rule contains 3 content options, 0 http content options, 1 pcre options, and 0 pcre options with http modifiers.
    Fast Pattern "Content-Type|3a| multipart/form-data" on "http header" buffer.
    Warning: Rule app layer protocol is http, but the signature is not limited by flow direction.
```

Una regla cuyo fast pattern es corto o extremadamente común (`"GET"`, `"|00|"`) va a evaluarse en casi cada paquete. `--engine-analysis` es cómo detectás eso antes de que te cueste el 30% de un núcleo de CPU.

### 3.5 Suricata como IPS

Dos transportes en línea soportados:

**(a) `NFQUEUE` — IPS a nivel de host (una sola máquina, o un router Linux).**

```nft
#!/usr/sbin/nft -f
# /etc/nftables.conf — send forwarded + inbound traffic to Suricata queues 0-7
flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;
        ct state established,related accept
        iif "lo" accept
        ct state invalid drop
        tcp dport 22 ct state new limit rate 10/minute accept
        # Everything else that survives goes to Suricata before acceptance
        ct state new queue num 0-7 bypass
    }

    chain forward {
        type filter hook forward priority 0; policy drop;
        ct state established,related accept
        # Fan out across 8 queues; 'bypass' = accept if no userspace reader
        queue num 0-7 flags bypass
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}
```

```bash
$ sudo suricata -c /etc/suricata/suricata.yaml -q 0 -q 1 -q 2 -q 3 -q 4 -q 5 -q 6 -q 7 -D
$ sudo suricata -c /etc/suricata/suricata.yaml --list-runmodes | sed -n '/nfq/,/^$/p'
------------------------------------- Runmode -------------------------------------
nfq
---------------------------------------------------------------
| RunMode Type      | Custom Mode       | Description
|-------------------------------------------------------------
| NFQ               | autofp            | Multi threaded NFQ mode. Packets from each queue are assigned to a single detect thread
| NFQ               | workers           | Multi queue NFQ mode. Packets from each queue are processed by one thread
```

Las dos banderas que evitan que esto se convierta en una caída:

| Configuración | Dónde | Efecto si Suricata muere |
|---|---|---|
| `flags bypass` en la sentencia `queue` de nft | kernel | El kernel **acepta** los paquetes en vez de descartarlos |
| `nfq: fail-open: yes` | `suricata.yaml` | Suricata activa `NFQA_CFG_F_FAIL_OPEN`; el kernel acepta cuando la cola está llena |

Sin ambas, `systemctl stop suricata` en un nodo que reenvía tráfico es una partición de red.

**(b) Bridge en línea con `af-packet` — un appliance IPS transparente de dos NICs.**

```yaml
af-packet:
  - interface: enp3s0f0
    threads: 8
    defrag: no                 # MUST be no in inline mode; Suricata does its own
    cluster-id: 98
    cluster-type: cluster_flow
    copy-mode: ips             # 'ips' drops on match; 'tap' forwards everything
    copy-iface: enp3s0f1
    use-mmap: yes
    tpacket-v3: no             # tpacket-v3 is RX-only; inline needs v2
    ring-size: 200000
    buffer-size: 128000000
    checksum-checks: no

  - interface: enp3s0f1
    threads: 8
    defrag: no
    cluster-id: 97
    cluster-type: cluster_flow
    copy-mode: ips
    copy-iface: enp3s0f0
    use-mmap: yes
    tpacket-v3: no
    ring-size: 200000
    buffer-size: 128000000
    checksum-checks: no
```

```bash
$ sudo ip link set enp3s0f0 up promisc on arp off
$ sudo ip link set enp3s0f1 up promisc on arp off
$ sudo ethtool -K enp3s0f0 gro off lro off tso off gso off rx-vlan-offload off tx-vlan-offload off
$ sudo ethtool -K enp3s0f1 gro off lro off tso off gso off rx-vlan-offload off tx-vlan-offload off
$ sudo systemctl restart suricata
$ sudo suricatasc -c "iface-stat enp3s0f0"
{"message": {"pkts": 184203311, "drop": 0, "invalid-checksums": 0}, "return": "OK"}
```

Confirmá que el modo IPS está realmente activo (esta es la verificación que la gente saltea y después se pregunta por qué no bloquea nada):

```bash
$ grep -E "engine mode|IPS mode|inline" /var/log/suricata/suricata.log | tail -5
Info: suricata: Setting engine mode to IPS mode
Info: af-packet: enp3s0f0: enabling zero copy mode by using data release call
Info: runmodes: enp3s0f0: creating 8 threads
Info: stream-tcp: stream "inline" enabled

$ jq -c 'select(.event_type=="drop")' /var/log/suricata/eve.json | head -2
{"timestamp":"2026-08-21T11:04:33.882119+0000","flow_id":1487229103772811,"in_iface":"enp3s0f0","event_type":"drop","src_ip":"203.0.113.44","src_port":51422,"dest_ip":"10.20.0.15","dest_port":80,"proto":"TCP","drop":{"len":1500,"tos":0,"ttl":56,"ipid":24118,"tcpseq":2298331104,"tcpack":3811207449,"tcpwin":501,"syn":false,"ack":true,"psh":true,"rst":false,"urg":false,"fin":false,"tcpres":0,"tcpurgp":0},"alert":{"action":"blocked","gid":1,"signature_id":2019401,"rev":6,"signature":"ET WEB_SERVER Possible SQL Injection UNION SELECT","category":"Web Application Attack","severity":1}}
```

`"action":"blocked"` significa que el paquete fue realmente descartado. En modo IDS una regla `drop` reporta `"action":"allowed"` — esa discrepancia es el caso de soporte número uno de "mi IPS no bloquea".

### 3.6 Unidad systemd

```ini
# /etc/systemd/system/suricata.service
[Unit]
Description=Suricata IDS/IPS network sensor
Documentation=man:suricata(8) https://docs.suricata.io/
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
Environment=LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libtcmalloc_minimal.so.4
ExecStartPre=/usr/bin/suricata -T -c /etc/suricata/suricata.yaml
ExecStartPre=/sbin/ethtool -K enp3s0f1 gro off lro off tso off gso off rx-vlan-offload off
ExecStartPre=/sbin/ip link set enp3s0f1 up promisc on arp off
ExecStart=/usr/bin/suricata -D --af-packet -c /etc/suricata/suricata.yaml --pidfile /run/suricata.pid
ExecReload=/usr/bin/suricatasc -c ruleset-reload-nonblocking
PIDFile=/run/suricata.pid
Restart=on-failure
RestartSec=5
LimitNOFILE=65535
LimitMEMLOCK=infinity
LimitCORE=infinity
CPUAffinity=0 2 4 6 8 10 12 14 16
OOMScoreAdjust=-500
# Sensor must not be reachable from the monitored segment
PrivateTmp=yes
ProtectSystem=full
ProtectHome=yes
NoNewPrivileges=yes
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_SYS_NICE CAP_IPC_LOCK
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_SYS_NICE CAP_IPC_LOCK

[Install]
WantedBy=multi-user.target
```

```
# /etc/logrotate.d/suricata
/var/log/suricata/*.log /var/log/suricata/*.json {
    daily
    rotate 14
    missingok
    nocompress
    create 0640 suricata suricata
    sharedscripts
    postrotate
        /usr/bin/suricatasc -c reopen-log-files > /dev/null 2>&1 || true
    endscript
}
```

`reopen-log-files` es obligatorio: sin eso, Suricata sigue escribiendo al inodo rotado y `eve.json` queda vacío para siempre mientras el motor reporta salud perfecta.

---

## 4. Snort 3: configuración y reglas

### 4.1 Compilar y verificar

```bash
$ snort -V

   ,,_     -*> Snort++ <*-
  o"  )~   Version 3.1.78.0
   ''''    By Martin Roesch & The Snort Team
           http://snort.org/contact#team
           Copyright (C) 2014-2024 Cisco and/or its affiliates. All rights reserved.
           Copyright (C) 1998-2013 Sourcefire, Inc., et al.
           Using DAQ version 3.0.14
           Using LuaJIT version 2.1.0-beta3
           Using OpenSSL 3.0.11 19 Sep 2023
           Using libpcap version 1.10.3 (with TPACKET_V3)
           Using PCRE version 8.39 2016-06-14
           Using ZLIB version 1.2.13
           Using Hyperscan version 5.4.2 2023-01-25
           Using LZMA version 5.4.1
```

### 4.2 `snort.lua` completo

```lua
-- /usr/local/etc/snort/snort.lua
-- Snort 3 production IDS configuration.

---------------------------------------------------------------------------
-- 1. Network variables
---------------------------------------------------------------------------
HOME_NET = '[10.0.0.0/8,172.16.0.0/12,192.168.0.0/16]'
EXTERNAL_NET = '!$HOME_NET'

HTTP_SERVERS   = HOME_NET
SQL_SERVERS    = '[10.40.12.0/24]'
DNS_SERVERS    = '[10.10.0.10,10.10.0.11]'
SMTP_SERVERS   = HOME_NET
SSH_SERVERS    = HOME_NET
FTP_SERVERS    = HOME_NET
TELNET_SERVERS = HOME_NET
SIP_SERVERS    = HOME_NET

HTTP_PORTS = '[80,81,311,383,591,593,901,1220,1414,1741,1830,2301,2381,2809,3037,3128,3702,4343,4848,5250,6988,7000,7001,7144,7145,7510,7777,7779,8000,8008,8014,8028,8080,8085,8088,8090,8118,8123,8180,8181,8243,8280,8300,8800,8888,8899,9000,9060,9080,9090,9091,9443,9999,11371,34443,34444,41080,50002,55555]'
SHELLCODE_PORTS = '!80'
ORACLE_PORTS = '1024:'
SSH_PORTS = '[22,2222]'
FTP_PORTS = '[21,2100,3535]'
FILE_DATA_PORTS = '[$HTTP_PORTS,110,143]'
MAIL_PORTS = '[110,143]'

---------------------------------------------------------------------------
-- 2. Include paths
---------------------------------------------------------------------------
dofile('/usr/local/etc/snort/snort_defaults.lua')
dofile('/usr/local/etc/snort/file_magic.lua')

RULE_PATH   = '/usr/local/etc/snort/rules'
BUILTIN_RULE_PATH = '/usr/local/etc/snort/builtin_rules'
WHITE_LIST_PATH = '/usr/local/etc/snort/lists'
BLACK_LIST_PATH = '/usr/local/etc/snort/lists'

---------------------------------------------------------------------------
-- 3. Packet decoding and normalization
---------------------------------------------------------------------------
daq =
{
    module_dirs = { '/usr/local/lib/daq' },
    modules =
    {
        {
            name = 'afpacket',
            mode = 'passive',
            variables = { 'fanout_type=hash', 'debug' }
        }
    },
    snaplen = 1518,
    inputs = { 'enp3s0f1' }
}

decode =
{
    max_ip6_extensions = 8,
    max_ip_layers = 4
}

normalizer =
{
    tcp =
    {
        ips  = true,        -- normalize for inline IPS (removes ambiguity)
        trim_syn  = true,
        trim_rst  = true,
        trim_win  = true,
        trim_mss  = true,
        ecn = 'stream',
        opts = true,
        req_urg = true,
        req_pay = true,
        req_urp = true,
        rsv = true,
        pad = true
    },
    ip4 = { df = true, rf = true, tos = true, trim = true },
    ip6 = true,
    icmp4 = true,
    icmp6 = true
}

---------------------------------------------------------------------------
-- 4. Stream reassembly
---------------------------------------------------------------------------
stream =
{
    ip_cache   = { max_sessions = 16384 },
    icmp_cache = { max_sessions = 65536 },
    tcp_cache  = { max_sessions = 786432, idle_timeout = 180 },
    udp_cache  = { max_sessions = 131072, idle_timeout = 180 },
    user_cache = { max_sessions = 1024 },
    file_cache = { max_sessions = 128 }
}

stream_ip =
{
    max_overlaps = 10,
    min_frag_length = 100,
    session_timeout = 180
}

stream_icmp = { session_timeout = 30 }

stream_tcp =
{
    policy = 'linux',
    session_timeout = 180,
    max_window = 0,
    overlap_limit = 10,
    max_pdu = 16384,
    reassemble_async = true,
    require_3whs = -1,
    show_rebuilt_packets = false,
    queue_limit = { max_bytes = 4194304, max_segments = 3072 },
    small_segments = { count = 0, maximum_size = 0 }
}

stream_udp = { session_timeout = 180 }

---------------------------------------------------------------------------
-- 5. Application-layer inspectors
---------------------------------------------------------------------------
arp_spoof = { }

back_orifice = { }

dns = { }

http_inspect =
{
    request_depth = 65535,
    response_depth = 65535,
    unzip = true,
    normalize_utf = true,
    decompress_pdf = true,
    decompress_swf = true,
    decompress_zip = true,
    script_detection = true,
    xff_headers = 'x-forwarded-for true-client-ip'
}

http2_inspect = { }

imap = { }
pop  = { }

smtp =
{
    alt_max_command_line_len =
    {
        { command = 'AUTH',      length = 240 },
        { command = 'BDAT',      length = 240 },
        { command = 'DATA',      length = 240 },
        { command = 'MAIL',      length = 260 },
        { command = 'RCPT',      length = 300 },
        { command = 'HELP',      length = 500 }
    },
    b64_decode_depth = 65535,
    qp_decode_depth = 65535,
    bitenc_decode_depth = 65535,
    uu_decode_depth = 65535,
    log_mailfrom = true,
    log_rcptto = true,
    log_filename = true,
    log_email_hdrs = true
}

ssh = { }

ssl = { }

telnet = { }

ftp_server = default_ftp_server
ftp_client = { }
ftp_data = { }

dce_smb = { policy = 'WinVista' }
dce_tcp = { policy = 'WinVista' }
dce_udp = { policy = 'WinVista' }
dce_http_proxy = { }
dce_http_server = { }

sip = { }
rpc_decode = { }
modbus = { }
dnp3 = { }
s7commplus = { }
cip = { }
iec104 = { }
mms = { }

wizard = default_wizard          -- service identification on non-standard ports

---------------------------------------------------------------------------
-- 6. Application identification and file policy
---------------------------------------------------------------------------
appid =
{
    app_detector_dir = '/usr/local/lib/snort_extra',
    log_stats = true
}

file_id =
{
    file_rules = file_magic,
    trace_type = true,
    trace_signature = true,
    enable_type = true,
    enable_signature = true,
    file_policy =
    {
        { when = { file_type_id = 21 }, use = { verdict = 'log', enable_file_signature = true } },
        { when = { sha256 = 'E1E3C6E4C1EFB1B9F0E1C7EE0D8F5F0E2C9E4B7A1D2E3F4A5B6C7D8E9F0A1B2C' },
          use = { verdict = 'block' } },
        { when = { }, use = { verdict = 'log', enable_file_type = true, enable_file_signature = true } }
    }
}

---------------------------------------------------------------------------
-- 7. Reputation / IP lists
---------------------------------------------------------------------------
reputation =
{
    blocklist = BLACK_LIST_PATH .. '/blocklist.txt',
    allowlist = WHITE_LIST_PATH .. '/allowlist.txt',
    memcap = 500,
    scan_local = true,
    priority = 'blocklist'
}

---------------------------------------------------------------------------
-- 8. Detection engine
---------------------------------------------------------------------------
search_engine =
{
    search_method = 'hyperscan',
    split_any_any = true,
    detect_raw_tcp = false
}

detection =
{
    hyperscan_literals = true,
    pcre_to_regex = true,
    pcre_match_limit = 3500,
    pcre_match_limit_recursion = 1500,
    enable_address_anomaly_checks = true,
    global_default_rule_state = true
}

ips =
{
    mode = 'tap',                     -- 'tap' = IDS; 'inline' = IPS
    variables = default_variables,
    include = RULE_PATH .. '/snort3-community.rules',
    rules = [[
        include $RULE_PATH/local.rules
    ]],
    enable_builtin_rules = true
}

event_queue =
{
    max_queue = 8,
    log = 5,
    order_events = 'content_length'
}

event_filter =
{
    { gid = 1, sid = 2019401, type = 'limit', track = 'by_src', count = 1, seconds = 300 }
}

suppress =
{
    { gid = 1, sid = 2010935, track = 'by_src', ip = '10.10.0.55' }
}

rate_filter =
{
    { gid = 1, sid = 1000012, track = 'by_src', count = 100, seconds = 10,
      new_action = 'drop', timeout = 60 }
}

active = { attempts = 2, device = 'enp3s0f1' }

---------------------------------------------------------------------------
-- 9. Outputs
---------------------------------------------------------------------------
alert_json =
{
    file = true,
    limit = 1000,
    fields = 'timestamp action class b64_data dir dst_addr dst_ap dst_port \
              eth_dst eth_len eth_src eth_type gid icmp_code icmp_id icmp_seq \
              icmp_type iface ip_id ip_len msg mpls pkt_gen pkt_len pkt_num \
              priority proto rev rule seconds service sid src_addr src_ap \
              src_port target tcp_ack tcp_flags tcp_len tcp_seq tcp_win \
              tos ttl udp_len vlan timestamp',
    separator = ', '
}

alert_fast =
{
    file = true,
    packet = false,
    limit = 100
}

packet_capture = { enable = false }

profiler =
{
    modules = { show = true, count = 10, sort = 'total_time' },
    memory  = { show = false },
    rules   = { show = true, count = 10, sort = 'avg_check' }
}

trace = { modules = { } }

process = { daemon = true, utc = true }

output =
{
    logdir = '/var/log/snort',
    show_year = true,
    wide_hex_dump = true
}

---------------------------------------------------------------------------
-- 10. Multi-threading — one packet thread per RSS queue
---------------------------------------------------------------------------
snort = { ['-z'] = 8 }
```

### 4.3 Ejecutar y validar Snort 3

```bash
$ sudo snort -c /usr/local/etc/snort/snort.lua --warn-all -T
--------------------------------------------------
o")~   Snort++ 3.1.78.0
--------------------------------------------------
Loading /usr/local/etc/snort/snort.lua:
Loading snort_defaults.lua:
Finished snort_defaults.lua:
        ips policy vars
        detection
        ips
Loading rules:
        rule counts
                total rules loaded: 4104
                text rules: 4104
                option chains: 4104
                chain headers: 331
        service rule counts          to-srv  to-cli
                          file_id:       19      19
                             http:     1489     742
                              ssl:       12       6
                            total:     1520     767
        fast pattern groups
                          to_server: 96
                          to_client: 61
        search engine
                        instances: 157
                        patterns: 6621
                        pattern chars: 78229
                        num states: 51033
                        num match states: 6188
                        memory scale: KB
                        total memory: 2412.3
                        pattern memory: 421.9
                        match list memory: 726.4
                        transition memory: 1218.6
Finished /usr/local/etc/snort/snort.lua:
--------------------------------------------------
Snort successfully validated the configuration (with 0 warnings).
o")~   Snort exiting
```

Ejecución IDS en vivo contra un PCAP (la forma en que se hace regresión de una regla):

```bash
$ sudo snort -c /usr/local/etc/snort/snort.lua -R /usr/local/etc/snort/rules/local.rules \
      -r /srv/pcap/sqli-sample.pcap -A alert_fast -q
08/21-11:22:04.882119 [**] [1:1000021:2] "LOCAL EXFIL Large multipart POST to newly-observed domain" [**] [Classification: Potential Corporate Privacy Violation] [Priority: 1] {TCP} 10.20.0.15:44118 -> 198.51.100.77:443
08/21-11:22:05.114882 [**] [1:2019401:6] "ET WEB_SERVER Possible SQL Injection UNION SELECT" [**] [Classification: Web Application Attack] [Priority: 1] {TCP} 203.0.113.44:51422 -> 10.20.0.15:80
```

Captura en vivo sobre la interfaz:

```bash
$ sudo snort -c /usr/local/etc/snort/snort.lua -i enp3s0f1 --daq afpacket \
      --daq-var fanout_type=hash -z 8 -l /var/log/snort -D
```

Modo IPS en línea (`-Q` selecciona inline; el DAQ debe soportarlo):

```bash
$ sudo snort -c /usr/local/etc/snort/snort.lua -Q --daq nfq --daq-var queue=0 \
      --daq-var queue_maxlen=8192 -l /var/log/snort
```

### 4.4 `snort-stat` y `/etc/snort/*` — los artefactos legacy que el examen nombra

Snort 2 traía `snort-stat`, un generador de reportes en Perl que parsea salida con formato `alert` desde syslog. Sigue estando explícitamente listado en los objetivos, así que sabé qué hace:

```bash
$ sudo grep snort /var/log/messages | snort-stat -a -r
Events from  Aug 21 00:00:04  to  Aug 21 23:58:11
Total events: 4183
Signatures recorded: 37
Source IP recorded: 219
Destination IP recorded: 46

The number of attacks from same host to same destination using same method
 #     <Source IP>       <Destination IP>       <Method>
2891   203.0.113.44      10.20.0.15             WEB-MISC SQL Injection attempt
 812   198.51.100.77     10.10.0.10             DNS zone transfer attempt
 199   192.0.2.9         10.40.12.31            MS-SQL probe response overflow attempt

Percentage and number of attacks from a host to a destination
   % of the total number of attacks
 69.11%  2891  203.0.113.44 -> 10.20.0.15
 19.41%   812  198.51.100.77 -> 10.10.0.10
```

El layout canónico de Snort 2 (sigue siendo lo que `/etc/snort/*` significa en el examen):

| Ruta | Propósito |
|---|---|
| `/etc/snort/snort.conf` | Configuración principal (Snort 2). Snort 3 la reemplaza con `snort.lua` |
| `/etc/snort/rules/*.rules` | Archivos de reglas, uno por categoría (`web-misc.rules`, `exploit.rules`, `local.rules`) |
| `/etc/snort/classification.config` | Mapeo `classtype` → prioridad |
| `/etc/snort/reference.config` | Prefijo `reference:` → plantilla de URL |
| `/etc/snort/threshold.config` | Sentencias `threshold` / `suppress` |
| `/etc/snort/gen-msg.map`, `sid-msg.map` | GID/SID → texto, usado por barnyard2 / `snort-stat` |
| `/var/log/snort/alert` | Salida por defecto de `alert_full`/`alert_fast` |
| `/var/log/snort/snort.log.<epoch>` | Log binario de paquetes en formato tcpdump |

```bash
$ head -8 /etc/snort/classification.config
config classification: not-suspicious,Not Suspicious Traffic,3
config classification: unknown,Unknown Traffic,3
config classification: bad-unknown,Potentially Bad Traffic,2
config classification: attempted-recon,Attempted Information Leak,2
config classification: successful-recon-limited,Information Leak,2
config classification: attempted-dos,Attempted Denial of Service,2
config classification: attempted-user,Attempted User Privilege Gain,1
config classification: successful-admin,Successful Administrator Privilege Gain,1

$ head -5 /etc/snort/reference.config
config reference: bugtraq   http://www.securityfocus.com/bid/
config reference: cve       http://cve.mitre.org/cgi-bin/cvename.cgi?name=
config reference: nessus    http://cgi.nessus.org/plugins/dump.php3?id=
config reference: url       http://
config reference: mcafee    http://vil.nai.com/vil/content/v_
```

Las actualizaciones de reglas para Snort se gestionan con **PulledPork** (Snort 2/3) o `snort-openappid`:

```bash
$ sudo /usr/local/bin/pulledpork.py -c /usr/local/etc/pulledpork/pulledpork.conf -v
2026-08-21 04:07:11 INFO     Config successfully parsed
2026-08-21 04:07:11 INFO     Rulesets to process: snort_community, et_open
2026-08-21 04:07:14 INFO     Downloading https://www.snort.org/downloads/community/snort3-community-rules.tar.gz
2026-08-21 04:07:19 INFO     Downloading https://rules.emergingthreats.net/open/snort-3.0/emerging.rules.tar.gz
2026-08-21 04:07:33 INFO     Rules written to /usr/local/etc/snort/rules/pulledpork.rules
2026-08-21 04:07:33 INFO     Total rules: 51203  Enabled: 39118  Disabled: 12085
2026-08-21 04:07:34 INFO     Validating with snort -T ... OK
2026-08-21 04:07:34 INFO     Reloading snort (SIGHUP to pid 4412)
```

---

## 5. Zeek: monitoreo de seguridad de red (conocimiento general + forma productiva)

Zeek no produce alertas por defecto; produce un *registro de lo que pasó*. Ese registro es el sustrato para la caza de amenazas, y es lo que hace que una pregunta post-incidente sea respondible.

### 5.1 Layout del clúster

```
# /opt/zeek/etc/node.cfg — 1 manager, 1 logger, 2 proxies, 16 workers
[logger-1]
type=logger
host=10.10.0.9

[manager]
type=manager
host=10.10.0.9

[proxy-1]
type=proxy
host=10.10.0.9

[proxy-2]
type=proxy
host=10.10.0.9

[worker-1]
type=worker
host=10.10.0.9
interface=af_packet::enp3s0f1
lb_method=custom
lb_procs=16
pin_cpus=2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17
af_packet_fanout_id=23
af_packet_fanout_mode=AF_Packet::FANOUT_HASH
af_packet_buffer_size=128*1024*1024
```

```
# /opt/zeek/etc/networks.cfg
10.0.0.0/8       Private RFC1918 10/8
172.16.0.0/12    Private RFC1918 172.16/12
192.168.0.0/16   Private RFC1918 192.168/16
```

```zeek
# /opt/zeek/share/zeek/site/local.zeek
@load base/protocols/conn
@load base/protocols/dns
@load base/protocols/http
@load base/protocols/ssl
@load base/protocols/ssh
@load base/protocols/smb
@load base/protocols/ftp
@load base/frameworks/files/hash-all-files
@load base/frameworks/notice
@load frameworks/files/detect-MHR

@load policy/tuning/json-logs.zeek          # emit JSON instead of TSV
@load policy/protocols/conn/vlan-logging
@load policy/protocols/conn/mac-logging
@load policy/protocols/ssl/validate-certs
@load policy/protocols/ssl/log-hostcerts-only
@load policy/protocols/ssh/detect-bruteforcing
@load policy/protocols/http/detect-sqli
@load policy/frameworks/notice/community-id
@load packages                              # zkg-managed packages

redef Site::local_nets = { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 };
redef LogAscii::use_json = T;
redef Log::default_rotation_interval = 1 hr;
redef digest_salt = "REPLACE-ME-PER-SITE";

# Intel framework: feed from MISP export
@load frameworks/intel/seen
@load frameworks/intel/do_notice
redef Intel::read_files += { "/opt/zeek/share/zeek/site/intel/misp.dat" };

# Custom detection: excessive NXDOMAIN from a single host (DGA indicator)
module LocalDetect;

export {
    redef enum Notice::Type += { DGA_Suspected };
}

global nxdomain_count: table[addr] of count &default=0 &create_expire=5min;

event DNS::log_dns(rec: DNS::Info)
    {
    if ( ! rec?$rcode_name || rec$rcode_name != "NXDOMAIN" ) return;
    if ( ! Site::is_local_addr(rec$id$orig_h) ) return;

    ++nxdomain_count[rec$id$orig_h];

    if ( nxdomain_count[rec$id$orig_h] == 50 )
        NOTICE([$note=DGA_Suspected,
                $msg=fmt("%s produced 50 NXDOMAIN responses in 5 minutes", rec$id$orig_h),
                $src=rec$id$orig_h,
                $identifier=cat(rec$id$orig_h),
                $suppress_for=1hr]);
    }
```

```bash
$ sudo /opt/zeek/bin/zeekctl deploy
checking configurations ...
installing ...
removing old policies in /opt/zeek/spool/installed-scripts-do-not-touch/site ...
creating policy directories ...
installing site policies ...
generating standalone-layout.zeek ...
generating local-networks.zeek ...
generating zeekctl-config.zeek ...
generating zeekctl-config.sh ...
stopping ...
starting ...
starting logger-1 ...
starting manager ...
starting proxy-1 ...
starting proxy-2 ...
starting workers ...

$ sudo /opt/zeek/bin/zeekctl status
Name         Type    Host       Status    Pid    Started
logger-1     logger  10.10.0.9  running   14882  21 Aug 09:31:02
manager      manager 10.10.0.9  running   14921  21 Aug 09:31:04
proxy-1      proxy   10.10.0.9  running   14977  21 Aug 09:31:06
proxy-2      proxy   10.10.0.9  running   14979  21 Aug 09:31:06
worker-1-1   worker  10.10.0.9  running   15044  21 Aug 09:31:08
worker-1-2   worker  10.10.0.9  running   15046  21 Aug 09:31:08
...
worker-1-16  worker  10.10.0.9  running   15074  21 Aug 09:31:08

$ sudo /opt/zeek/bin/zeekctl netstats
worker-1-1: 1755772284.114 recvd=48219113 dropped=0 link=48219113
worker-1-2: 1755772284.118 recvd=47883021 dropped=0 link=47883021
...

$ ls /opt/zeek/logs/current/
capture_loss.log  conn.log  dns.log  files.log  http.log  known_certs.log
known_hosts.log   known_services.log  notice.log  packet_filter.log
ssh.log  ssl.log  stats.log  stderr.log  stdout.log  weird.log  x509.log

$ zeek-cut -d ts id.orig_h id.resp_h id.resp_p service duration orig_bytes resp_bytes < conn.log | head -5
2026-08-21T11:04:31+0000  10.20.0.15  198.51.100.77  443   ssl   312.884   14882  5921003
2026-08-21T11:04:33+0000  10.20.0.31  10.10.0.10     53    dns   0.002     41     107
2026-08-21T11:04:33+0000  10.20.0.31  93.184.216.34  80    http  1.113     318    41029
```

`capture_loss.log` es la métrica sobre la que alerta un SRE — es la propia estimación de Zeek sobre cuánto se perdió:

```bash
$ jq -r 'select(.percent_lost > 0.5) | "\(.ts) \(.peer) \(.percent_lost)%"' /opt/zeek/logs/current/capture_loss.log
1755772800.000000 worker-1-7 2.31%
```

Cualquier valor por encima de ~1% invalida tus garantías de detección — tratalo como un page, no como un warning.

---

## 6. Monitoreo de red: ntopng y Cacti

### 6.1 ntopng

`ntop`/`ntopng` responde la pregunta volumétrica: quién habla con quién, cuánto, sobre qué protocolo. Está orientado a flujos, no a firmas, y está explícitamente en los objetivos.

```bash
$ sudo apt-get install -y redis-server ntopng ntopng-data nprobe
$ sudo systemctl enable --now redis-server
```

```
# /etc/ntopng/ntopng.conf
-i=enp3s0f1
-i=tcp://127.0.0.1:5556          # nProbe / NetFlow collector endpoint
-w=3000                          # HTTP port
-W=3001                          # HTTPS port
-m=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16
-d=/var/lib/ntopng
-G=/var/run/ntopng.pid
-U=ntopng
--dns-mode=1                     # 0=all, 1=local only, 2=none, 3=none+no decode
--local-host-max-idle=600
--flow-max-idle=60
--disable-autologout
--community
-F="es;http://elastic.example.net:9200;ntopng;ntopng-%Y.%m.%d;"
--redis=localhost:6379
--http-prefix=/ntopng
--zmq-encryption-key=/etc/ntopng/zmq.key
```

```bash
$ sudo systemctl restart ntopng
$ sudo systemctl status ntopng --no-pager -l | head -12
● ntopng.service - ntopng high-speed web-based traffic monitoring and analysis tool
     Loaded: loaded (/lib/systemd/system/ntopng.service; enabled)
     Active: active (running) since Fri 2026-08-21 11:41:07 UTC; 8s ago
   Main PID: 21114 (ntopng)
      Tasks: 22 (limit: 154321)
     Memory: 412.8M
     CGroup: /system.slice/ntopng.service
             └─21114 /usr/bin/ntopng /etc/ntopng/ntopng.conf

Aug 21 11:41:07 sensor01 ntopng[21114]: [Redis.cpp:150] Successfully connected to Redis 127.0.0.1:6379@0
Aug 21 11:41:07 sensor01 ntopng[21114]: [PcapInterface.cpp:107] Reading packets from interface enp3s0f1...
Aug 21 11:41:07 sensor01 ntopng[21114]: [HTTPserver.cpp:1181] HTTP server listening on port 3000
```

Recolección de NetFlow/IPFIX con `nprobe` por delante (el patrón estándar de escalado horizontal de ntopng — sondas en los bordes, ntopng central):

```bash
# On the router/exporter side, export NetFlow v9 to the collector
$ sudo nprobe -i enp1s0 -n 10.10.0.9:2055 -V 9 -T "%IPV4_SRC_ADDR %IPV4_DST_ADDR %IPV4_NEXT_HOP %INPUT_SNMP %OUTPUT_SNMP %IN_PKTS %IN_BYTES %FIRST_SWITCHED %LAST_SWITCHED %L4_SRC_PORT %L4_DST_PORT %TCP_FLAGS %PROTOCOL %SRC_TOS %SRC_AS %DST_AS %SRC_MASK %DST_MASK"

# On the collector side, turn NetFlow into a ZMQ feed ntopng consumes
$ sudo nprobe --zmq "tcp://*:5556" -i none -n none --collector-port 2055
21/Aug/2026 11:47:02 [nprobe.c:4381] Welcome to nProbe v.10.6 for x86_64-pc-linux-gnu
21/Aug/2026 11:47:02 [collect.c:2361] Flow collector listening on port 2055 (IPv4/v6)
21/Aug/2026 11:47:02 [nprobe.c:2211] Exporting flows towards ZMQ endpoint tcp://*:5556
```

Verificación:

```bash
$ curl -s -u admin:changeme "http://127.0.0.1:3000/lua/rest/v2/get/interface/data.lua?ifid=0" | jq '{name:.rsp.ifname, packets:.rsp.packets, drops:.rsp.drops, bytes:.rsp.bytes, num_flows:.rsp.num_flows, num_hosts:.rsp.num_hosts}'
{
  "name": "enp3s0f1",
  "packets": 91882031,
  "drops": 0,
  "bytes": 74881029113,
  "num_flows": 118422,
  "num_hosts": 3811
}

$ curl -s -u admin:changeme "http://127.0.0.1:3000/lua/rest/v2/get/host/l7/stats.lua?ifid=0&host=10.20.0.15" | jq '.rsp[] | select(.bytes > 1000000) | {proto:.proto, bytes:.bytes}'
{"proto":"TLS","bytes":5921003211}
{"proto":"DNS","bytes":4118822}
{"proto":"HTTP","bytes":2004112}
```

### 6.2 Cacti

Cacti es el lado de series temporales RRDtool/SNMP: contadores de interfaz, tasas de error, CPU y — relevante acá — **la salud del sensor mismo**.

```bash
$ sudo apt-get install -y cacti cacti-spine snmp snmpd rrdtool
$ sudo -u www-data php /usr/share/cacti/site/cli/add_device.php \
      --description="sensor01" --ip=10.10.0.9 --template=8 \
      --version=3 --username=cactipoll --authproto=SHA --authpass='REDACTED' \
      --privproto=AES --privpass='REDACTED' --secLevel=authPriv
Adding sensor01 (10.10.0.9) as "Net-SNMP Device" using SNMP v3 with community "public"
Success - new device-id: (17)

$ sudo -u www-data php /usr/share/cacti/site/cli/add_graphs.php \
      --graph-type=ds --graph-template-id=2 --host-id=17 \
      --snmp-query-id=1 --snmp-query-type-id=13 --snmp-field=ifName --snmp-value=enp3s0f1
Graph Added - graph-id: (231) - data-source-ids: (198, 199)
```

`snmpd` en el sensor, restringido a la red de gestión:

```
# /etc/snmp/snmpd.conf
agentAddress udp:10.10.0.9:161

createUser cactipoll SHA "REDACTED" AES "REDACTED"
rouser cactipoll authPriv -V systemonly

view   systemonly  included   .1.3.6.1.2.1.1
view   systemonly  included   .1.3.6.1.2.1.2
view   systemonly  included   .1.3.6.1.2.1.25.1
view   systemonly  included   .1.3.6.1.4.1.2021.10
view   systemonly  included   .1.3.6.1.4.1.2021.4

sysLocation  DC1 Rack A12
sysContact   noc@example.net
```

```bash
$ snmpwalk -v3 -l authPriv -u cactipoll -a SHA -A 'REDACTED' -x AES -X 'REDACTED' \
      10.10.0.9 IF-MIB::ifName
IF-MIB::ifName.1 = STRING: lo
IF-MIB::ifName.2 = STRING: enp3s0f0
IF-MIB::ifName.3 = STRING: enp3s0f1

$ sudo -u www-data /usr/sbin/spine --verbose=2 --first=0 --last=0 2>&1 | tail -6
SPINE: Poller[1] PID[31882] Device[17] HT[1] DS[198] SNMP: v3: 10.10.0.9, dsname: traffic_in, oid: .1.3.6.1.2.1.31.1.1.1.6.3, value: 74881029113
SPINE: Poller[1] PID[31882] Device[17] HT[1] DS[199] SNMP: v3: 10.10.0.9, dsname: traffic_out, oid: .1.3.6.1.2.1.31.1.1.1.10.3, value: 0
SPINE: Poller[1] PID[31882] Time: 0.4113 s, Threads: 8, Devices: 17
```

**Nota arquitectónica:** `traffic_out = 0` en una interfaz de captura es el valor esperado y *deseado* — una NIC de sensor pasivo nunca debe transmitir. Un contador distinto de cero ahí significa que la interfaz tiene una IP o que ARP está habilitado, y que el sensor se volvió alcanzable desde la red monitoreada. Graficalo y alertá sobre eso.

---

## 7. Ingeniería de rendimiento, verificación y diagnóstico de fallas

Acá es donde los despliegues de NIDS fallan realmente. Un sensor que reporta "running" mientras descarta el 40% de los paquetes es peor que no tener sensor, porque produce la *ilusión* de cobertura.

### 7.1 La métrica más importante de todas

```bash
$ sudo suricatasc -c "iface-stat enp3s0f1"
{"message": {"pkts": 3184203311, "drop": 41882913, "invalid-checksums": 0}, "return": "OK"}
```

`drop / pkts = 1.31%`. Eso es el 1.31% de tu red sobre el que no podés hacer ninguna afirmación.

Medición continua desde las stats de EVE:

```bash
$ jq -r 'select(.event_type=="stats") |
    "\(.timestamp) recv=\(.stats.capture.kernel_packets) drop=\(.stats.capture.kernel_drops) " +
    "pct=\(if .stats.capture.kernel_packets>0 then (.stats.capture.kernel_drops*100/.stats.capture.kernel_packets|.*100|round/100) else 0 end)%"' \
    /var/log/suricata/eve.json | tail -3
2026-08-21T12:00:00.000229+0000 recv=3184203311 drop=41882913 pct=1.32%
2026-08-21T12:00:30.000188+0000 recv=3186119004 drop=41882913 pct=1.31%
2026-08-21T12:01:00.000201+0000 recv=3188044117 drop=41882913 pct=1.31%
```

SLI de Prometheus (los drops son un contador; alertá sobre la *tasa*, no sobre el total):

```yaml
# /etc/prometheus/rules/nids.yml
groups:
  - name: nids-sensor-health
    interval: 30s
    rules:
      - record: sensor:packet_drop_ratio:rate5m
        expr: |
          rate(suricata_capture_kernel_drops_total[5m])
            /
          clamp_min(rate(suricata_capture_kernel_packets_total[5m]), 1)

      - alert: SuricataDroppingPackets
        expr: sensor:packet_drop_ratio:rate5m > 0.001
        for: 10m
        labels:
          severity: warning
          team: security-platform
        annotations:
          summary: "Sensor {{ $labels.instance }} dropping {{ $value | humanizePercentage }} of packets"
          runbook_url: "https://runbooks.example.net/nids/packet-drops"

      - alert: SuricataDroppingPacketsCritical
        expr: sensor:packet_drop_ratio:rate5m > 0.01
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Sensor {{ $labels.instance }} has LOST VISIBILITY ({{ $value | humanizePercentage }} drop)"

      - alert: SuricataNoTraffic
        expr: rate(suricata_capture_kernel_packets_total[5m]) == 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Sensor {{ $labels.instance }} sees ZERO packets — SPAN/TAP is dead"

      - alert: SuricataRulesetStale
        expr: (time() - suricata_ruleset_last_reload_timestamp_seconds) > 172800
        for: 1h
        labels:
          severity: warning
        annotations:
          summary: "Ruleset on {{ $labels.instance }} has not reloaded in 48h"

      - alert: SuricataEveLogStalled
        expr: (time() - suricata_eve_last_write_timestamp_seconds) > 300
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "eve.json on {{ $labels.instance }} has not been written in 5 minutes (logrotate without reopen-log-files?)"
```

### 7.2 Diagnosticar drops — un árbol de decisión

```
Drops observed
   │
   ├─► Is the drop counter in the KERNEL (capture.kernel_drops) or the NIC (ethtool -S)?
   │      │
   │      ├─ NIC (rx_missed_errors, rx_no_buffer_count, fifo_errors)
   │      │     → NIC ring too small, or IRQ/CPU starvation
   │      │     → ethtool -g / ethtool -G, IRQ affinity, disable irqbalance
   │      │
   │      └─ Kernel (kernel_drops, /proc/net/softnet_stat col 2)
   │            → AF_PACKET ring too small OR workers too slow
   │            │
   │            ├─ Are workers CPU-saturated? (top -H -p $(pidof suricata))
   │            │     ├─ YES → too many rules / bad fast patterns / no Hyperscan
   │            │     │        → suricata --engine-analysis; enable rule profiling
   │            │     │        → add bypass for high-volume trusted flows
   │            │     │        → scale threads to RSS queues; check NUMA locality
   │            │     └─ NO  → ring-size / block-size too small, or one hot thread
   │            │              → cluster_flow imbalance (elephant flow on 1 worker)
   │            │              → check per-thread counters in eve stats
   │            │
   │            └─ Is ONE thread hot and the rest idle?
   │                  → cluster_flow hashes a single huge flow to one worker
   │                  → use cluster_qm with RSS symmetric hashing, or bypass that flow
   │
   └─► No drops but no alerts either → see §7.5
```

Comandos concretos para cada rama:

```bash
# --- NIC-level counters ---
$ ethtool -S enp3s0f1 | grep -Ei "drop|discard|miss|error|no_buf|fifo"
     rx_dropped: 0
     rx_missed_errors: 118822
     rx_no_buffer_count: 0
     rx_fifo_errors: 118822
     rx_crc_errors: 0

# --- NIC ring sizes: raise RX to the hardware maximum ---
$ ethtool -g enp3s0f1
Ring parameters for enp3s0f1:
Pre-set maximums:
RX:             4096
RX Mini:        n/a
RX Jumbo:       n/a
TX:             4096
Current hardware settings:
RX:             512
TX:             512
$ sudo ethtool -G enp3s0f1 rx 4096

# --- RSS queues MUST equal Suricata's thread count ---
$ ethtool -l enp3s0f1
Channel parameters for enp3s0f1:
Pre-set maximums:
RX:             n/a
TX:             n/a
Other:          1
Combined:       32
Current hardware settings:
Combined:       32
$ sudo ethtool -L enp3s0f1 combined 8

# --- Kernel softirq backlog: column 2 = dropped ---
$ awk '{ printf "cpu%02d processed=%d dropped=%d squeezed=%d\n", NR-1, strtonum("0x"$1), strtonum("0x"$2), strtonum("0x"$3) }' /proc/net/softnet_stat | awk '$3 !~ /dropped=0$/'
cpu02 processed=418822031 dropped=118822 squeezed=41

# --- NUMA locality: pin workers to the NIC's own node ---
$ cat /sys/class/net/enp3s0f1/device/numa_node
0
$ lscpu | grep -E "NUMA node0|NUMA node1"
NUMA node0 CPU(s):   0-15,32-47
NUMA node1 CPU(s):   16-31,48-63

# --- Per-thread load: find the hot worker ---
$ top -H -b -n1 -p $(pidof suricata) | grep -E "W#|%CPU" | head -12
  PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
21882 suricata  20   0   28.4g   9.1g  12m  R  99.7  14.2  318:44.11 W#01-enp3s0f1
21883 suricata  20   0   28.4g   9.1g  12m  S  22.1  14.2   71:02.88 W#02-enp3s0f1
21884 suricata  20   0   28.4g   9.1g  12m  S  19.8  14.2   64:11.02 W#03-enp3s0f1
```

`W#01` al 99.7% mientras el resto está ocioso es el clásico **desbalance por flujo elefante**: `cluster_flow` hashea un stream de backup de 8 Gbps hacia un único worker. Arreglalo bypasseando el flujo en vez de agregando CPUs:

```
# /etc/suricata/rules/local.rules — do not inspect the backup replication stream
pass ip 10.40.12.31 any <> 10.40.12.32 any (msg:"LOCAL bypass DB replication"; sid:1000001; rev:1;)
```

o, mejor, delegá la decisión al kernel con `bypass`:

```
alert tcp any any -> any any (msg:"LOCAL bypass large TLS after 1MB"; \
    flow:established; tls.version:1.2; \
    bytes:>1048576; bypass; sid:1000002; rev:1;)
```

### 7.3 Offloads — por qué deben estar apagados

Generic Receive Offload le entrega a Suricata un único "paquete" de 40 KB que nunca existió en el cable. Los límites de segmento, y por lo tanto las oportunidades de evasión que viven en ellos, quedan borrados; el análisis de secuencia TCP se vuelve carente de sentido.

```bash
$ ethtool -k enp3s0f1 | grep -E "generic-receive-offload|large-receive-offload|tcp-segmentation-offload|generic-segmentation-offload|rx-vlan-offload"
rx-vlan-offload: on
tcp-segmentation-offload: on
generic-segmentation-offload: on
generic-receive-offload: on
large-receive-offload: off [fixed]

$ sudo ethtool -K enp3s0f1 gro off lro off tso off gso off rx-vlan-offload off tx-vlan-offload off rxvlan off txvlan off
$ ethtool -k enp3s0f1 | grep -E "generic-receive-offload|generic-segmentation-offload"
generic-receive-offload: off
generic-segmentation-offload: off
```

Síntoma cuando te olvidás: una inundación de anomalías `decoder.ipv4.trunc_pkt`, `stream.reassembly_...` e `invalid-checksums` por miles.

```bash
$ jq -r 'select(.event_type=="stats") | .stats.decoder | {pkts, invalid, ipv4, tcp, too_many_layers}' /var/log/suricata/eve.json | tail -8
{
  "pkts": 3188044117,
  "invalid": 0,
  "ipv4": 3021118822,
  "tcp": 2884113092,
  "too_many_layers": 0
}
```

`invalid` debe ser ~0. Cualquier otra cosa significa que al decodificador se le están dando tramas que no existieron en el cable.

### 7.4 Agotamiento de memcap

```bash
$ jq -r 'select(.event_type=="stats") | .stats |
  "flow.memcap=\(.flow.memcap) flow.emerg=\(.flow.emerg_mode_entered) " +
  "tcp.reass_memcap=\(.tcp.reassembly_memcap) tcp.memcap=\(.tcp.memuse) " +
  "defrag.memcap=\(.defrag.max_frag_hits)"' /var/log/suricata/eve.json | tail -1
flow.memcap=418822 flow.emerg=14 tcp.reass_memcap=91882 tcp.memcap=3211882192 defrag.memcap=0
```

| Contador | Distinto de cero significa | Solución |
|---|---|---|
| `flow.memcap` | Tabla de flujos llena → nuevos flujos silenciosamente sin seguimiento | Subí `flow.memcap`; acortá los `flow-timeouts` |
| `flow.emerg_mode_entered` | Suricata entró en modo de emergencia y expiró flujos agresivamente | Igual; esto es una caída de visibilidad |
| `tcp.reassembly_memcap` | Buffers de reensamblado agotados → el parseo de capa de aplicación se detiene a mitad del flujo | Subí `stream.reassembly.memcap`; bajá `depth` |
| `tcp.ssn_memcap_drop` | Nuevas sesiones TCP descartadas por completo | Subí `stream.memcap` |
| `defrag.max_frag_hits` | Tabla de fragmentos IP llena → ataques fragmentados invisibles | Subí `defrag.memcap`/`trackers` |
| `tcp.stream_depth_reached` | El flujo excedió `reassembly.depth`; el resto sin inspeccionar | Esperable en descargas grandes; subilo solo si necesitás inspección profunda de archivos |
| `app_layer.error.*.alloc` | Fallas de asignación del parser | Presión de memoria — revisá el RSS total |

Heurística de dimensionamiento que se sostiene en la práctica:

| Tasa del segmento | `flow.memcap` | `stream.memcap` | `stream.reassembly.memcap` | Workers | RAM |
|---|---|---|---|---|---|
| 200 Mbps | 128 MB | 256 MB | 512 MB | 2 | 4 GB |
| 1 Gbps | 512 MB | 1 GB | 2 GB | 4 | 8 GB |
| 2 Gbps | 2 GB | 4 GB | 8 GB | 8 | 24 GB |
| 10 Gbps | 8 GB | 16 GB | 32 GB | 16–24 | 96 GB |
| 40 Gbps | 24 GB | 48 GB | 96 GB | 32–48 (+DPDK/PF_RING) | 256 GB |

### 7.5 "El sensor corre pero nunca alerta"

Recorré la lista en orden; cada paso es una causa raíz distinta y común.

```bash
# 1. Is it seeing packets at all?
$ sudo suricatasc -c "iface-stat enp3s0f1"
{"message": {"pkts": 0, "drop": 0, "invalid-checksums": 0}, "return": "OK"}
#   → pkts=0: the SPAN/TAP is dead, or the interface is down/not promiscuous.
$ ip -s link show enp3s0f1
3: enp3s0f1: <BROADCAST,MULTICAST,PROMISC,UP,LOWER_UP> mtu 1500 qdisc mq state UP mode DEFAULT group default qlen 1000
    link/ether 3c:fd:fe:a1:b2:c3 brd ff:ff:ff:ff:ff:ff
    RX:  bytes packets errors dropped  missed   mcast
    74881029113 91882031      0       0       0   41882
    TX:  bytes packets errors dropped carrier collsns
              0        0      0       0       0       0
#   PROMISC must be present. TX must be 0 on a passive sensor.
$ sudo tcpdump -i enp3s0f1 -c 5 -nn
tcpdump: verbose output suppressed, use -v[v]... for full protocol decode
listening on enp3s0f1, link-type EN10MB (Ethernet), snapshot length 262144 bytes
11:52:03.114882 IP 10.20.0.15.44118 > 198.51.100.77.443: Flags [P.], seq 1:518, ack 1, win 501, length 517
5 packets captured

# 2. Are rules actually loaded?
$ sudo suricatasc -c "ruleset-stats"
{"message": [{"rules_loaded": 0, "rules_failed": 0}], "return": "OK"}
#   → 0 loaded: default-rule-path / rule-files mismatch. Check the log:
$ grep -E "rule files processed|no rules loaded|Error" /var/log/suricata/suricata.log | tail
Warning: detect: No rule files match the pattern /var/lib/suricata/rules/suricata.rules

# 3. Is HOME_NET wrong? (the most common silent failure)
$ suricata --dump-config 2>/dev/null | grep -E "^vars.address-groups.(HOME_NET|EXTERNAL_NET)"
vars.address-groups.HOME_NET = [192.168.0.0/16]
vars.address-groups.EXTERNAL_NET = !$HOME_NET
#   Your production network is 10.0.0.0/8. Every $HOME_NET-anchored rule is dead.

# 4. Is checksum validation discarding everything?
$ jq -r 'select(.event_type=="stats") | .stats.capture' /var/log/suricata/eve.json | tail -1
{"kernel_packets":3188044117,"kernel_drops":0,"errors":0}
$ grep -c "invalid checksum" /var/log/suricata/suricata.log
#   With offloads on and checksum-checks: yes → everything is discarded pre-detection.
#   Set `checksum-checks: no` (offloads are already disabled) or `auto`.

# 5. Prove the detection path end-to-end with a known-good test rule
$ cat >> /etc/suricata/rules/local.rules <<'EOF'
alert dns any any -> any any (msg:"LOCAL TEST canary dns query"; dns.query; content:"nids-canary.example.net"; nocase; sid:1000999; rev:1;)
EOF
$ sudo suricatasc -c "reload-rules"
{"message": "done", "return": "OK"}
$ dig +short @10.10.0.10 nids-canary.example.net
$ jq -c 'select(.alert.signature_id==1000999) | {ts:.timestamp, sig:.alert.signature, src:.src_ip}' /var/log/suricata/eve.json | tail -1
{"ts":"2026-08-21T11:56:22.114882+0000","sig":"LOCAL TEST canary dns query","src":"10.20.0.31"}
```

**Institucionalizá el paso 5.** Un canario sintético — un cron job que emite una petición benigna e identificable de forma única cada 5 minutos, más una alerta cuando el evento EVE correspondiente *no* aparece — es el único monitoreo que prueba que toda la cadena (TAP → NIC → kernel → motor → reglas → log → shipper → SIEM) está viva. Cualquier otra métrica prueba una parte de ella.

```ini
# /etc/systemd/system/nids-canary.timer
[Unit]
Description=NIDS end-to-end detection canary
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
```

```ini
# /etc/systemd/system/nids-canary.service
[Unit]
Description=Emit NIDS canary traffic
[Service]
Type=oneshot
ExecStart=/usr/bin/dig +short +tries=1 +time=2 @10.10.0.10 nids-canary.example.net
ExecStart=/usr/bin/curl -sS -m 5 -o /dev/null -A "nids-canary/1.0" http://canary.example.net/nids-probe
```

### 7.6 Profiling de rendimiento de reglas

```yaml
# Temporarily, in suricata.yaml — profiling costs ~15% CPU, do not leave it on
profiling:
  rules:
    enabled: yes
    filename: rule_perf.log
    append: no
    limit: 50
    json: yes
    sort: avgticks
```

```bash
$ sudo systemctl restart suricata && sleep 900
$ jq -r '.rules[] | select(.checks > 1000) | [.signature_id, .checks, .matches, .ticks_avg, .ticks_total] | @tsv' \
      /var/log/suricata/rule_perf.log | sort -k4 -rn | head -8
2027865  4881029   12      88214    430516089
2019401  3118822    3      41182    128422118
2013028  2884113    0      31118     89211044
2010935  1988211    0      22014     43772118

$ jq -r '.rules[] | select(.checks > 1000 and .matches == 0) | .signature_id' /var/log/suricata/rule_perf.log | wc -l
118
```

118 reglas que fueron evaluadas miles de veces y nunca hicieron match ni una sola vez son puro impuesto de CPU sobre esta red. Deshabilitalas en `disable.conf` — y reevaluá trimestralmente, porque "nunca hizo match" es una afirmación sobre tu tráfico, no sobre la validez de la regla.

Equivalente en Snort 3:

```bash
$ sudo snort -c /usr/local/etc/snort/snort.lua -r /srv/pcap/sample.pcap --pcap-filter '*' \
      --tweaks profile -q 2>&1 | sed -n '/rule profile/,/^$/p'
--------------------------------------------------
rule profile (all, sorted by avg_check)
      #         gid       sid   rev     checks   matches    alerts    time (us)  avg/check  avg/match
      1           1   2027865     4    4881029        12        12      430516        88.2     35876.3
      2           1   2019401     6    3118822         3         3      128422        41.1     42807.3
      3           1   2013028     3    2884113         0         0       89211        30.9        0.0
```

### 7.7 Retención de PCAP para análisis retrospectivo

```yaml
outputs:
  - pcap-log:
      enabled: yes
      filename: log.pcap
      limit: 1000mb
      max-files: 4000          # 4000 × 1 GB ≈ 4 TB ring
      compression: lz4
      lz4-level: 1
      mode: multi              # one file per thread; far faster than 'normal'
      dir: /srv/pcap
      use-stream-depth: no
      honor-pass-rules: yes    # respect 'pass' rules — do not store bypassed flows
      conditional: alerts      # 'all' | 'alerts' | 'tag' — store only flows with alerts
```

Dimensionamiento: `retention_hours = (ring_bytes × 8) / (avg_bits_per_second × 3600)`. Un ring de 4 TB sobre un enlace sostenido de 2 Gbps guarda ~4.4 horas de captura completa de paquetes. `conditional: alerts` típicamente eleva eso en uno o dos órdenes de magnitud, al costo de perder el contexto previo a la alerta — que suele ser exactamente el contexto que necesitás. Presupuestá captura completa solo en segmentos de alto valor.

Extraer un flujo del ring para análisis:

```bash
$ ls -1 /srv/pcap | tail -3
log.pcap.1755772800.3
log.pcap.1755772800.4
log.pcap.1755772801.1
$ tcpdump -r /srv/pcap/log.pcap.1755772800.3 -w /tmp/incident.pcap \
      'host 203.0.113.44 and host 10.20.0.15'
reading from file /srv/pcap/log.pcap.1755772800.3, link-type EN10MB (Ethernet), snapshot length 262144
$ capinfos /tmp/incident.pcap | head -8
File name:           /tmp/incident.pcap
File type:           Wireshark/tcpdump/... - pcap
File encapsulation:  Ethernet
Number of packets:   4,118
File size:           3,211,882 bytes
Data size:           3,146,000 bytes
Capture duration:    312.884000 seconds
First packet time:   2026-08-21 11:04:31.114882
```

Reproducir un PCAP a través del motor offline — la forma estándar de probar una regla nueva sin tocar producción:

```bash
$ sudo suricata -c /etc/suricata/suricata.yaml -S /etc/suricata/rules/local.rules \
      -r /tmp/incident.pcap -l /tmp/suri-test --runmode single -k none
Notice: suricata: This is Suricata version 7.0.5 RELEASE running in USER mode
Info: detect: 1 rule files processed. 21 rules successfully loaded, 0 rules failed
Notice: suricata: Signal Received.  Stopping engine.
Info: suricata: time elapsed 1.114s
Info: counters: (single) Packets 4118, bytes 3146000
$ jq -r 'select(.event_type=="alert") | "\(.alert.signature_id) \(.alert.signature)"' /tmp/suri-test/eve.json | sort | uniq -c
      1 1000021 LOCAL EXFIL Large multipart POST to newly-observed domain
     14 2019401 ET WEB_SERVER Possible SQL Injection UNION SELECT
```

`-k none` deshabilita la validación de checksums, lo cual es necesario cuando el PCAP fue capturado en un host con offloads de TX (los checksums son calculados por la NIC después de la captura).

---

## 8. Escaneo de vulnerabilidades: OpenVAS / Greenbone y NASL

El objetivo nombra OpenVAS y sus scripts auxiliares clásicos. El proyecto fue renombrado a **Greenbone Vulnerability Management (GVM)**; `openvas` es ahora el motor de escaneo manejado por `ospd-openvas`, y los auxiliares legacy `openvas-*` fueron reemplazados por `gvm-*`. Conocé ambos.

| Nombre legacy (en los objetivos) | Equivalente actual | Propósito |
|---|---|---|
| `openvas-setup` | `gvm-setup` | BD inicial, certificados, sincronización de feed, usuario admin |
| `openvas-check-setup` | `gvm-check-setup` | Validar la instalación de punta a punta |
| `openvas-nvt-sync` | `greenbone-nvt-sync` / `greenbone-feed-sync --type nvt` | Sincronizar el feed de NVT (plugins NASL) |
| `openvas-scapdata-sync` | `greenbone-feed-sync --type scap` | Sincronizar datos CVE/CPE/OVAL |
| `openvas-certdata-sync` | `greenbone-feed-sync --type cert` | Sincronizar avisos de CERT |
| `openvas-adduser` | `gvmd --create-user=<u> --role=Admin` | Crear un usuario |
| `openvas-mkcert` / `openvas-mkcert-client` | `gvm-manage-certs -a` | Generar certificados de servidor/cliente |
| `openvas-start` / `openvas-stop` | `gvm-start` / `gvm-stop`, o unidades systemd | Arrancar/detener el stack |
| OMP (`omp`) | GMP (`gvm-cli`, `gvm-script`) | Cliente del protocolo de gestión |
| — | `ospd-openvas` | Demonio de escaneo OSP que fronte a `openvas` |

### 8.1 Instalación y verificación

```bash
$ sudo gvm-setup
[>] Starting PostgreSQL service
[>] Creating database user and database 'gvmd'
[*] Creating certificates
[>] Migrating gvmd database
[>] Checking for GVM admin user
[*] Creating user admin
[*] User created with password 'f7c1b8a4-3e9d-4a12-9c55-1e0b7a2d84ff'.
[>] Updating NVT feed (this takes a while)
[*] Syncing from feed.community.greenbone.net
[>] Updating SCAP data
[>] Updating CERT data
[+] GVM feeds updated
[*] Please note the password for the admin user

$ sudo gvm-check-setup
gvm-check-setup 23.11.0
  Test completeness and readiness of GVM-23.11.0
Step 1: Checking OpenVAS (Scanner)...
        OK: OpenVAS Scanner is present in version 23.0.1.
        OK: Notus Scanner is present in version 22.6.3.
        OK: Server CA Certificate is present as /var/lib/gvm/CA/servercert.pem.
Step 2: Checking GVMD Manager ...
        OK: gvmd is present in version 23.5.2.
        OK: Access rights for the Greenbone Vulnerability Manager are correct.
        OK: PostgreSQL version is 15.
        OK: gvmd database is at revision 255.
        OK: Greenbone Vulnerability Manager database is at revision 255.
        OK: Access rights for the CA Certificate are correct.
Step 3: Checking Certificates ...
        OK: GVM client certificate is valid and present as /var/lib/gvm/CA/clientcert.pem.
Step 4: Checking data ...
        OK: NVT collection in /var/lib/openvas/plugins contains 92418 NVTs.
        OK: SCAP data found in /var/lib/gvm/scap-data.
        OK: CERT data found in /var/lib/gvm/cert-data.
Step 5: Checking Postgresql DB and user ...
        OK: Postgresql version and default port are OK.
Step 6: Checking Greenbone Security Assistant (GSA) ...
        OK: Greenbone Security Assistant is present in version 23.2.1.
Step 7: Checking if GVM services are up and running ...
        OK: ospd-openvas service is active.
        OK: gvmd service is active.
        OK: gsad service is active.
Step 8: Checking few other requirements...
        OK: nmap is present in version 7.93.
        OK: ssh-keygen found, LSC credential generation for GNU/Linux targets is likely to work.

It seems like your GVM-23.11.0 installation is OK.
```

La frescura del feed es un SLI operativo — un escáner con un feed de NVT de 30 días de antigüedad reporta "limpio" durante un mes de CVEs nuevos:

```bash
$ sudo greenbone-feed-sync --type all
$ gvm-cli --gmp-username admin --gmp-password "$GMP_PW" socket \
      --xml '<get_feeds/>' | xmllint --format - | grep -E "<name>|<version>|<currently_syncing>"
      <name>NVT</name>
      <version>202608210541</version>
      <name>SCAP</name>
      <version>202608210230</version>
      <name>CERT</name>
      <version>202608210300</version>
```

### 8.2 Manejar un escaneo desde la CLI

```bash
$ export GMP_PW='...'
$ gvm-cli --gmp-username admin --gmp-password "$GMP_PW" socket --xml \
  '<create_target>
     <name>dmz-webtier</name>
     <hosts>10.20.0.10-10.20.0.40</hosts>
     <port_list id="33d0cd82-57c6-11e1-8ed1-406186ea4fc5"/>
     <alive_tests>ICMP, TCP-ACK Service &amp; ARP Ping</alive_tests>
   </create_target>'
<create_target_response status="201" status_text="OK, resource created" id="9f1b8a44-3e2d-4a12-9c55-1e0b7a2d84ff"/>

$ gvm-cli --gmp-username admin --gmp-password "$GMP_PW" socket --xml \
  '<create_task>
     <name>dmz-webtier full and fast</name>
     <config id="daba56c8-73ec-11df-a475-002264764cea"/>
     <target id="9f1b8a44-3e2d-4a12-9c55-1e0b7a2d84ff"/>
     <scanner id="08b69003-5fc2-4037-a479-93b440211c73"/>
   </create_task>'
<create_task_response status="201" status_text="OK, resource created" id="c4118822-91aa-4c31-b7e0-2d1e88f0a913"/>

$ gvm-cli --gmp-username admin --gmp-password "$GMP_PW" socket --xml \
  '<start_task task_id="c4118822-91aa-4c31-b7e0-2d1e88f0a913"/>'
<start_task_response status="202" status_text="OK, request submitted"><report_id>a8812f11-...</report_id></start_task_response>

$ gvm-cli --gmp-username admin --gmp-password "$GMP_PW" socket --xml \
  '<get_tasks task_id="c4118822-91aa-4c31-b7e0-2d1e88f0a913"/>' | xmllint --format - | grep -E "<status>|<progress>"
      <status>Running</status>
      <progress>41</progress>

# Fetch results as CSV once done
$ gvm-cli --gmp-username admin --gmp-password "$GMP_PW" socket --xml \
  '<get_reports report_id="a8812f11-..." format_id="c1645568-627a-11e3-a660-406186ea4fc5" filter="min_qod=70 severity&gt;5.0"/>' \
  | xmllint --xpath 'string(//report_format/../text())' - | base64 -d | head -4
IP,Hostname,Port,Port Protocol,CVSS,Severity,QoD,Solution Type,NVT Name,Summary
10.20.0.15,web01.example.net,443,tcp,7.5,High,98,VendorFix,OpenSSL: Multiple Vulnerabilities,...
10.20.0.22,web02.example.net,22,tcp,5.3,Medium,80,Mitigation,Weak MAC Algorithm(s) Supported (SSH),...
```

`min_qod=70` importa: una Quality of Detection por debajo de ~70 es inferencia y no prueba, y volcar hallazgos QoD-30 sin filtrar en una cola de tickets es la forma en que los programas de vulnerabilidades pierden credibilidad.

### 8.3 NASL

NASL (Nessus Attack Scripting Language) es el lenguaje en el que está escrito cada NVT. El examen espera que reconozcas su estructura y sepas cómo ejecutar uno de forma independiente.

```nasl
# /var/lib/openvas/plugins/local/example_banner_check.nasl
if (description)
{
  script_oid("1.3.6.1.4.1.25623.1.0.900001");
  script_version("2026-08-21T09:00:00+0000");
  script_tag(name:"last_modification", value:"2026-08-21 09:00:00 +0000 (Fri, 21 Aug 2026)");
  script_tag(name:"creation_date", value:"2026-08-21 09:00:00 +0000 (Fri, 21 Aug 2026)");
  script_tag(name:"cvss_base", value:"5.0");
  script_tag(name:"cvss_base_vector", value:"AV:N/AC:L/Au:N/C:P/I:N/A:N");
  script_tag(name:"qod_type", value:"remote_banner");
  script_tag(name:"solution_type", value:"Mitigation");
  script_name("Local: Deprecated web server banner exposed");
  script_category(ACT_GATHER_INFO);
  script_family("Web Servers");
  script_copyright("Copyright (C) 2026 Example Corp");
  script_dependencies("gb_get_http_banner.nasl");
  script_require_ports("Services/www", 80, 443);
  script_tag(name:"summary", value:"The remote web server discloses a detailed version banner.");
  script_tag(name:"impact", value:"An attacker can map the exact software version to known CVEs.");
  script_tag(name:"solution", value:"Set ServerTokens Prod / server_tokens off.");
  exit(0);
}

include("http_func.inc");
include("http_keepalive.inc");
include("misc_func.inc");

port = http_get_port(default:80);
banner = http_get_remote_headers(port:port);
if (!banner) exit(0);

srv = egrep(pattern:"^Server:.*", string:banner, icase:TRUE);
if (!srv) exit(0);

if (eregmatch(pattern:"Server:\s*(Apache|nginx)/[0-9]+\.[0-9]+\.[0-9]+", string:srv, icase:TRUE))
{
  report = "The remote web server returned a detailed version banner:\n\n" + chomp(srv);
  security_message(port:port, data:report);
  exit(0);
}

exit(99);
```

Ejecutarlo de forma independiente contra un objetivo — el ciclo para desarrollar o depurar un plugin:

```bash
$ sudo openvas-nasl -X -B -d -t 10.20.0.15 /var/lib/openvas/plugins/local/example_banner_check.nasl
lib  nasl-Message: 12:11:04.882: Starting Authenticated Scan
** description
** script_oid(1.3.6.1.4.1.25623.1.0.900001)
** script_name(Local: Deprecated web server banner exposed)
** script_category(ACT_GATHER_INFO)
** http_get_port(default:80) -> 443
** http_get_remote_headers(port:443)
** security_message(port:443, data:"The remote web server returned a detailed version banner:

Server: nginx/1.18.0")

$ sudo openvas-nasl -X -t 10.20.0.15 -k /var/lib/openvas/plugins/local/example_banner_check.nasl 2>&1 | tail -2
```

| Flag de `openvas-nasl` | Efecto |
|---|---|
| `-t <host>` | Objetivo |
| `-X` | Ejecutar **sin** verificación de firma (necesario para plugins locales sin firmar) |
| `-B` | Mostrar una descripción de todas las llamadas a funciones del script (traza) |
| `-d` | Salida de depuración |
| `-k <file>` | Cargar un volcado de KB (base de conocimiento), para que los resultados de las dependencias estén disponibles |
| `-s` | Ejecutar como si fuera el escáner (chequeos seguros) |

Firmar los plugins locales es la alternativa correcta para producción a `-X`:

```bash
$ cd /var/lib/openvas/plugins/local
$ sha256sum example_banner_check.nasl > sha256sums
$ gpg --homedir /etc/openvas/gnupg --detach-sign --armor --output sha256sums.asc sha256sums
$ grep nasl_no_signature_check /etc/openvas/openvas.conf
nasl_no_signature_check = no
```

---

## 9. Kubernetes: correr Suricata como sensor a nivel de nodo

El DaemonSet con `hostNetwork` es la respuesta nativa del clúster a "no hay puerto SPAN en una VPC en la nube". El sensor de cada nodo ve el tráfico de ese nodo — incluido el tráfico pod-a-pod que sale del nodo y todo el tráfico que cruza la interfaz de nodo del CNI.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: security-nids
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: suricata
  namespace: security-nids
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: suricata-config
  namespace: security-nids
data:
  suricata.yaml: |
    %YAML 1.1
    ---
    vars:
      address-groups:
        HOME_NET: "[10.0.0.0/8,172.16.0.0/12,192.168.0.0/16]"
        EXTERNAL_NET: "!$HOME_NET"
        HTTP_SERVERS: "$HOME_NET"
        DNS_SERVERS: "$HOME_NET"
        SQL_SERVERS: "$HOME_NET"
        SMTP_SERVERS: "$HOME_NET"
        TELNET_SERVERS: "$HOME_NET"
      port-groups:
        HTTP_PORTS: "[80,8080,8000,8008,8081,9080,9090]"
        SHELLCODE_PORTS: "!80"
        ORACLE_PORTS: 1521
        SSH_PORTS: 22
        FILE_DATA_PORTS: "[$HTTP_PORTS,110,143]"
        FTP_PORTS: 21
        GENEVE_PORTS: 6081
        VXLAN_PORTS: 4789
        TEREDO_PORTS: 3544

    default-log-dir: /var/log/suricata/

    stats:
      enabled: yes
      interval: 30

    outputs:
      - eve-log:
          enabled: yes
          filetype: regular
          filename: /var/log/suricata/eve.json
          community-id: true
          types:
            - alert:
                payload: yes
                payload-printable: yes
                packet: yes
                metadata: yes
            - anomaly:
                enabled: yes
                types:
                  decode: yes
                  stream: yes
                  applayer: yes
            - http:
                extended: yes
            - dns:
                version: 2
            - tls:
                extended: yes
                ja3: yes
            - files:
                force-magic: yes
                force-hash: [sha256]
            - flow
            - stats:
                totals: yes
                threads: yes
                deltas: yes
            - drop:
                alerts: yes

    af-packet:
      - interface: default
        cluster-id: 99
        cluster-type: cluster_flow
        defrag: yes
        use-mmap: yes
        tpacket-v3: yes
        ring-size: 100000
        block-size: 1048576
        checksum-checks: kernel
        threads: 2

    app-layer:
      protocols:
        tls:
          enabled: yes
          detection-ports:
            dp: "[443,6443,8443,9443,10250,2379,2380]"
          ja3-fingerprints: yes
        http:
          enabled: yes
          libhtp:
            default-config:
              personality: IDS
              request-body-limit: 100kb
              response-body-limit: 100kb
        http2: { enabled: yes }
        dns:
          tcp: { enabled: yes, detection-ports: { dp: 53 } }
          udp: { enabled: yes, detection-ports: { dp: 53 } }
        ssh: { enabled: yes }
        smb: { enabled: yes }
        krb5: { enabled: yes }
        dcerpc: { enabled: yes }

    decoder:
      vxlan:
        enabled: true
        ports: $VXLAN_PORTS
      geneve:
        enabled: true
        ports: $GENEVE_PORTS

    flow:
      memcap: 512mb
      hash-size: 65536
      prealloc: 20000
      emergency-recovery: 30

    stream:
      memcap: 1gb
      checksum-validation: no
      inline: no
      reassembly:
        memcap: 2gb
        depth: 1mb
        toserver-chunk-size: 2560
        toclient-chunk-size: 2560

    defrag:
      memcap: 128mb
      trackers: 65535

    host:
      hash-size: 4096
      prealloc: 1000
      memcap: 32mb

    detect:
      profile: medium
      sgh-mpm-context: auto
      prefilter:
        default: mpm

    mpm-algo: auto
    spm-algo: auto

    threading:
      set-cpu-affinity: no
      detect-thread-ratio: 1.0

    logging:
      default-log-level: notice
      outputs:
        - console:
            enabled: yes

    unix-command:
      enabled: yes
      filename: /var/run/suricata/suricata-command.socket

    default-rule-path: /var/lib/suricata/rules
    rule-files:
      - suricata.rules
      - k8s-local.rules

    classification-file: /etc/suricata/classification.config
    reference-config-file: /etc/suricata/reference.config
    threshold-file: /etc/suricata/threshold.config

  k8s-local.rules: |
    # Cluster-specific detections. SID range 1000100-1000199.
    alert tls $HOME_NET any -> $EXTERNAL_NET any (msg:"K8S Egress TLS to non-allowlisted SNI"; \
        flow:established,to_server; tls.sni; \
        content:!".example.net"; endswith; \
        content:!".googleapis.com"; endswith; \
        content:!".docker.io"; endswith; \
        threshold: type limit, track by_src, count 1, seconds 600; \
        classtype:policy-violation; sid:1000100; rev:1;)

    alert http $HOME_NET any -> $HOME_NET 10250 (msg:"K8S Direct kubelet API access from pod network"; \
        flow:established,to_server; http.uri; content:"/run/"; startswith; \
        classtype:attempted-admin; sid:1000101; rev:1;)

    alert tcp $HOME_NET any -> $HOME_NET [2379,2380] (msg:"K8S etcd access from unexpected source"; \
        flow:established,to_server; \
        threshold: type limit, track by_src, count 1, seconds 300; \
        classtype:attempted-admin; sid:1000102; rev:1;)

    alert dns $HOME_NET any -> any any (msg:"K8S Pod DNS query for cloud metadata endpoint"; \
        dns.query; content:"metadata"; nocase; \
        classtype:attempted-recon; sid:1000103; rev:1;)

    alert http $HOME_NET any -> 169.254.169.254 any (msg:"K8S Cloud IMDS access from pod network"; \
        flow:established,to_server; \
        classtype:attempted-recon; sid:1000104; rev:1;)

  threshold.config: |
    # Node-to-node kubelet health traffic is expected
    suppress gen_id 1, sig_id 1000101, track by_src, ip 10.0.0.0/8

  classification.config: |
    config classification: not-suspicious,Not Suspicious Traffic,3
    config classification: unknown,Unknown Traffic,3
    config classification: bad-unknown,Potentially Bad Traffic,2
    config classification: attempted-recon,Attempted Information Leak,2
    config classification: successful-recon-limited,Information Leak,2
    config classification: attempted-dos,Attempted Denial of Service,2
    config classification: attempted-user,Attempted User Privilege Gain,1
    config classification: successful-user,Successful User Privilege Gain,1
    config classification: attempted-admin,Attempted Administrator Privilege Gain,1
    config classification: successful-admin,Successful Administrator Privilege Gain,1
    config classification: trojan-activity,A Network Trojan was detected,1
    config classification: policy-violation,Potential Corporate Privacy Violation,1
    config classification: web-application-attack,Web Application Attack,1
    config classification: misc-activity,Misc activity,3

  reference.config: |
    config reference: cve       https://cve.mitre.org/cgi-bin/cvename.cgi?name=
    config reference: url       http://
    config reference: md5       https://www.virustotal.com/gui/file/
    config reference: attack    https://attack.mitre.org/techniques/
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: suricata
  namespace: security-nids
  labels:
    app.kubernetes.io/name: suricata
    app.kubernetes.io/component: nids
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: suricata
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  template:
    metadata:
      labels:
        app.kubernetes.io/name: suricata
        app.kubernetes.io/component: nids
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9917"
    spec:
      serviceAccountName: suricata
      hostNetwork: true
      hostPID: false
      dnsPolicy: ClusterFirstWithHostNet
      priorityClassName: system-node-critical
      terminationGracePeriodSeconds: 30
      tolerations:
        - operator: Exists
      initContainers:
        - name: rules-fetch
          image: jasonish/suricata:7.0.5
          command:
            - /bin/sh
            - -c
            - |
              set -eu
              suricata-update \
                --no-test \
                --data-dir /var/lib/suricata \
                --suricata-conf /etc/suricata/suricata.yaml \
                --local /etc/suricata/k8s-local.rules
              suricata -T -c /etc/suricata/suricata.yaml -v
          volumeMounts:
            - name: config
              mountPath: /etc/suricata
            - name: rules
              mountPath: /var/lib/suricata
          resources:
            requests: { cpu: 200m, memory: 512Mi }
            limits:   { cpu: "2",  memory: 2Gi }
      containers:
        - name: suricata
          image: jasonish/suricata:7.0.5
          args:
            - -c
            - /etc/suricata/suricata.yaml
            - --af-packet=$(CAPTURE_IFACE)
            - -v
          env:
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: CAPTURE_IFACE
              value: "eth0"
          securityContext:
            runAsUser: 0
            privileged: false
            allowPrivilegeEscalation: true
            readOnlyRootFilesystem: false
            capabilities:
              drop: ["ALL"]
              add: ["NET_ADMIN", "NET_RAW", "SYS_NICE", "IPC_LOCK"]
          volumeMounts:
            - name: config
              mountPath: /etc/suricata
            - name: rules
              mountPath: /var/lib/suricata
            - name: logs
              mountPath: /var/log/suricata
            - name: run
              mountPath: /var/run/suricata
          resources:
            requests: { cpu: "1",  memory: 3Gi }
            limits:   { cpu: "3",  memory: 6Gi }
          startupProbe:
            exec:
              command: ["/bin/sh", "-c", "test -S /var/run/suricata/suricata-command.socket"]
            initialDelaySeconds: 20
            periodSeconds: 10
            failureThreshold: 30
          livenessProbe:
            exec:
              command:
                - /bin/sh
                - -c
                - "suricatasc -c uptime | grep -q return"
            initialDelaySeconds: 60
            periodSeconds: 60
            timeoutSeconds: 10
            failureThreshold: 3
        - name: exporter
          image: corelight/suricata-prometheus-exporter:0.5.0
          args:
            - --eve-file=/var/log/suricata/eve.json
            - --listen=:9917
            - --node=$(NODE_NAME)
          env:
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          ports:
            - name: metrics
              containerPort: 9917
              protocol: TCP
          volumeMounts:
            - name: logs
              mountPath: /var/log/suricata
              readOnly: true
          resources:
            requests: { cpu: 50m,  memory: 64Mi }
            limits:   { cpu: 200m, memory: 256Mi }
        - name: shipper
          image: timberio/vector:0.39.0-debian
          args: ["--config", "/etc/vector/vector.yaml"]
          volumeMounts:
            - name: logs
              mountPath: /var/log/suricata
              readOnly: true
            - name: vector-config
              mountPath: /etc/vector
            - name: vector-data
              mountPath: /var/lib/vector
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { cpu: 500m, memory: 512Mi }
      volumes:
        - name: config
          configMap:
            name: suricata-config
        - name: vector-config
          configMap:
            name: suricata-vector
        - name: rules
          hostPath:
            path: /var/lib/suricata
            type: DirectoryOrCreate
        - name: logs
          hostPath:
            path: /var/log/suricata
            type: DirectoryOrCreate
        - name: run
          emptyDir: {}
        - name: vector-data
          hostPath:
            path: /var/lib/vector
            type: DirectoryOrCreate
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: suricata-vector
  namespace: security-nids
data:
  vector.yaml: |
    data_dir: /var/lib/vector
    sources:
      eve:
        type: file
        include: ["/var/log/suricata/eve.json"]
        read_from: beginning
        fingerprint:
          strategy: device_and_inode
    transforms:
      parsed:
        type: remap
        inputs: ["eve"]
        source: |
          . = parse_json!(.message)
          .node = get_env_var("NODE_NAME") ?? "unknown"
          .cluster = "prod-eu-west-1"
      alerts_only:
        type: filter
        inputs: ["parsed"]
        condition: '.event_type == "alert" || .event_type == "anomaly" || .event_type == "drop"'
    sinks:
      kafka_alerts:
        type: kafka
        inputs: ["alerts_only"]
        bootstrap_servers: "kafka-0.kafka:9092,kafka-1.kafka:9092"
        topic: "nids.alerts"
        compression: zstd
        encoding:
          codec: json
      loki_all:
        type: loki
        inputs: ["parsed"]
        endpoint: "http://loki.observability:3100"
        labels:
          app: suricata
          node: "{{ node }}"
          event_type: "{{ event_type }}"
        encoding:
          codec: json
---
apiVersion: v1
kind: Service
metadata:
  name: suricata-metrics
  namespace: security-nids
  labels:
    app.kubernetes.io/name: suricata
spec:
  clusterIP: None
  selector:
    app.kubernetes.io/name: suricata
  ports:
    - name: metrics
      port: 9917
      targetPort: 9917
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: suricata
  namespace: security-nids
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: suricata
  endpoints:
    - port: metrics
      interval: 30s
      scrapeTimeout: 10s
```

Verificación del despliegue:

```bash
$ kubectl apply -f suricata-daemonset.yaml
namespace/security-nids created
serviceaccount/suricata created
configmap/suricata-config created
configmap/suricata-vector created
daemonset.apps/suricata created
service/suricata-metrics created
servicemonitor.monitoring.coreos.com/suricata created

$ kubectl -n security-nids rollout status ds/suricata --timeout=300s
Waiting for daemon set "suricata" rollout to finish: 0 of 12 updated pods are available...
Waiting for daemon set "suricata" rollout to finish: 8 of 12 updated pods are available...
daemon set "suricata" successfully rolled out

$ kubectl -n security-nids get pods -o wide
NAME             READY   STATUS    RESTARTS   AGE   IP            NODE
suricata-4nfw2   3/3     Running   0          3m    10.0.12.11    node-01
suricata-8pk4l   3/3     Running   0          3m    10.0.12.12    node-02
suricata-b2xq9   3/3     Running   0          3m    10.0.12.13    node-03

$ kubectl -n security-nids exec suricata-4nfw2 -c suricata -- suricatasc -c "iface-stat eth0"
{"message": {"pkts": 4118822, "drop": 0, "invalid-checksums": 0}, "return": "OK"}

$ kubectl -n security-nids exec suricata-4nfw2 -c suricata -- suricatasc -c "ruleset-stats"
{"message": [{"rules_loaded": 38821, "rules_failed": 0}], "return": "OK"}

# End-to-end: trigger the IMDS rule from a workload pod
$ kubectl run probe --rm -it --image=curlimages/curl:8.8.0 --restart=Never -- \
      curl -s -m 3 http://169.254.169.254/latest/meta-data/ ; echo
pod "probe" deleted

$ kubectl -n security-nids logs suricata-4nfw2 -c suricata --since=1m | grep 1000104
$ kubectl -n security-nids exec suricata-4nfw2 -c suricata -- \
      sh -c 'tail -n 200 /var/log/suricata/eve.json | grep 1000104' | jq -c '{ts:.timestamp,sig:.alert.signature,src:.src_ip,dst:.dest_ip}'
{"ts":"2026-08-21T12:31:08.114882+0000","sig":"K8S Cloud IMDS access from pod network","src":"10.244.3.17","dst":"169.254.169.254"}
```

**Límites conocidos de este patrón, declaralos a los interesados:**

| Limitación | Consecuencia | Mitigación |
|---|---|---|
| El tráfico pod-a-pod en el mismo nodo puede no cruzar `eth0` | Punto ciego para movimiento lateral intra-nodo | Capturá también el bridge del CNI (`cni0`, `cilium_vxlan`), o usá herramientas basadas en eBPF |
| Los CNI basados en eBPF evitan el camino de netfilter/interfaz | Tráfico invisible para AF_PACKET en algunas interfaces | Capturá el dispositivo de túnel explícitamente; agregá los decodificadores `vxlan`/`geneve` (hecho arriba) |
| El mTLS del service mesh cifra el tráfico pod-a-pod | Payload invisible | Apoyate en telemetría de flujo/JA3/anomalías; combinalo con logs de autorización a nivel de mesh |
| El DaemonSet necesita `hostNetwork` + `NET_ADMIN`/`NET_RAW` | Los Pod Security Standards deben ser `privileged` para el namespace | Aislalo en un namespace dedicado con RBAC estricto (como arriba) |
| La CPU del sensor compite con las cargas de trabajo | Riesgo de vecino ruidoso en nodos ocupados | `requests`/`limits` fijados, prioridad `system-node-critical` y un ruleset con `profile: medium` |

---

## 10. Ingeniería de detección como código

Las firmas son código. Merecen control de versiones, revisión y CI.

```yaml
# .gitlab-ci.yml (or the GitHub Actions equivalent)
stages: [lint, test, deploy]

variables:
  SURICATA_IMAGE: jasonish/suricata:7.0.5

lint:rules:
  stage: lint
  image: $SURICATA_IMAGE
  script:
    - suricata -T -c ci/suricata-ci.yaml -S rules/local.rules -v
    - suricata --engine-analysis -c ci/suricata-ci.yaml -S rules/local.rules -l /tmp/ea
    - |
      if grep -qE "Warning|Fast Pattern \"[^\"]{1,3}\"" /tmp/ea/rules_analysis.txt; then
        echo "ERROR: weak fast pattern or engine warning detected"
        grep -E "Warning|Fast Pattern \"[^\"]{1,3}\"" /tmp/ea/rules_analysis.txt
        exit 1
      fi
    - |
      # Enforce local SID range and mandatory metadata
      awk '/^(alert|drop|pass|reject)/ {
             if ($0 !~ /sid:10[0-9]{5};/)  { print "BAD SID RANGE: " $0; bad=1 }
             if ($0 !~ /rev:[0-9]+;/)      { print "MISSING rev: "  $0; bad=1 }
             if ($0 !~ /classtype:/)       { print "MISSING classtype: " $0; bad=1 }
             if ($0 !~ /metadata:.*created_at/) { print "MISSING created_at: " $0; bad=1 }
           } END { exit bad }' rules/local.rules

test:true-positive:
  stage: test
  image: $SURICATA_IMAGE
  script:
    - |
      set -e
      fail=0
      for pcap in tests/pcaps/*.pcap; do
        sid=$(basename "$pcap" .pcap | cut -d- -f1)
        rm -rf /tmp/out && mkdir -p /tmp/out
        suricata -c ci/suricata-ci.yaml -S rules/local.rules -r "$pcap" -l /tmp/out -k none -q 0 >/dev/null 2>&1 || true
        if ! jq -e --argjson s "$sid" 'select(.event_type=="alert" and .alert.signature_id==$s)' /tmp/out/eve.json >/dev/null; then
          echo "FAIL: $pcap did not trigger sid $sid"
          fail=1
        else
          echo "PASS: $pcap -> sid $sid"
        fi
      done
      exit $fail

test:false-positive:
  stage: test
  image: $SURICATA_IMAGE
  script:
    - |
      set -e
      # Benign traffic corpus must produce ZERO alerts from local SIDs
      rm -rf /tmp/fp && mkdir -p /tmp/fp
      for pcap in tests/benign/*.pcap; do
        suricata -c ci/suricata-ci.yaml -S rules/local.rules -r "$pcap" -l /tmp/fp -k none -q 0 >/dev/null 2>&1 || true
      done
      hits=$(jq -r 'select(.event_type=="alert" and .alert.signature_id >= 1000000 and .alert.signature_id < 2000000) | .alert.signature_id' /tmp/fp/eve.json 2>/dev/null | sort -u)
      if [ -n "$hits" ]; then
        echo "FALSE POSITIVES on benign corpus:"; echo "$hits"; exit 1
      fi
      echo "No false positives on benign corpus."

deploy:rules:
  stage: deploy
  only: [main]
  script:
    - ansible-playbook -i inventory/sensors.ini playbooks/deploy-rules.yml
```

```yaml
# playbooks/deploy-rules.yml
- hosts: nids_sensors
  serial: "25%"                 # never reload the whole fleet at once
  become: true
  tasks:
    - name: Ship local rules
      ansible.builtin.copy:
        src: ../rules/local.rules
        dest: /etc/suricata/rules/local.rules
        owner: root
        group: suricata
        mode: "0640"
        backup: true
      register: rules

    - name: Validate configuration with the new rules
      ansible.builtin.command:
        cmd: suricata -T -c /etc/suricata/suricata.yaml
      changed_when: false
      register: validate
      failed_when: validate.rc != 0

    - name: Roll back on validation failure
      ansible.builtin.command:
        cmd: "cp {{ rules.backup_file }} /etc/suricata/rules/local.rules"
      when: validate.rc != 0

    - name: Hot-reload the ruleset
      ansible.builtin.command:
        cmd: suricatasc -c ruleset-reload-nonblocking
      when: rules.changed and validate.rc == 0

    - name: Confirm rules are live
      ansible.builtin.command:
        cmd: suricatasc -c ruleset-stats
      register: stats
      changed_when: false
      failed_when: "'\"rules_failed\": 0' not in stats.stdout"
```

### 10.1 Runbook de triaje de falsos positivos

```bash
# 1. Quantify: which SIDs dominate the last 24h?
$ jq -r 'select(.event_type=="alert") | "\(.alert.signature_id)\t\(.alert.signature)"' /var/log/suricata/eve.json \
    | sort | uniq -c | sort -rn | head -10
   4881 2013028	ET POLICY curl User-Agent Outbound
   3118 2019401	ET WEB_SERVER Possible SQL Injection UNION SELECT
   1882 2010935	ET POLICY Suspicious inbound to MSSQL port 1433
    211 2027865	ET JA3 Hash - Possible Malware

# 2. Concentrate: is it one source, one destination, or diffuse?
$ jq -r 'select(.alert.signature_id==2013028) | .src_ip' /var/log/suricata/eve.json | sort | uniq -c | sort -rn | head -5
   4791 10.30.4.12
     51 10.30.4.13
     39 10.30.4.14

# 3. Inspect the actual payload before deciding
$ jq -r 'select(.alert.signature_id==2013028) | .payload_printable' /var/log/suricata/eve.json | head -1 | head -c 400
GET /api/v1/health HTTP/1.1
Host: internal-api.example.net
User-Agent: curl/8.4.0
Accept: */*

# 4. Decide, and record the decision as configuration, never as a silenced dashboard
#    -> 10.30.4.12 is the monitoring runner; suppress for that source only.
$ sudo tee -a /etc/suricata/threshold.config >/dev/null <<'EOF'
# 2026-08-21 jgomez: monitoring runners use curl for health checks (TICKET SEC-4412)
suppress gen_id 1, sig_id 2013028, track by_src, ip 10.30.4.12
suppress gen_id 1, sig_id 2013028, track by_src, ip 10.30.4.13
suppress gen_id 1, sig_id 2013028, track by_src, ip 10.30.4.14
EOF
$ sudo suricata -T -c /etc/suricata/suricata.yaml && sudo suricatasc -c reload-rules
{"message": "done", "return": "OK"}
```

La regla que mantiene esto honesto: **cada supresión lleva una fecha, un responsable y un ticket en un comentario.** Un `threshold.config` lleno de supresiones anónimas es una reducción indocumentada de tu superficie de detección, y nadie se va a animar a sacar ninguna dos años después.

---

## 11. Resumen de referencia para el examen

| Herramienta | Archivo de configuración | CLI clave | Validar | Recargar |
|---|---|---|---|---|
| **Suricata** | `/etc/suricata/suricata.yaml` | `suricata -c <cfg> -i <if>`, `-r <pcap>`, `-q <n>` (NFQUEUE), `-T`, `--af-packet`, `--engine-analysis`, `--dump-config`, `--build-info`, `--list-runmodes` | `suricata -T -c ...` | `suricatasc -c reload-rules` |
| **suricata-update** | `/etc/suricata/{enable,disable,modify,drop}.conf` | `update-sources`, `list-sources`, `enable-source`, `update` | `--no-test` lo saltea | vía `suricatasc` |
| **Snort 3** | `/usr/local/etc/snort/snort.lua` | `snort -c <lua> -i <if> -A alert_fast`, `-r <pcap>`, `-R <rules>`, `-Q` (inline), `-z <threads>`, `-T`, `-V`, `--warn-all` | `snort -c ... -T` | SIGHUP / reiniciar |
| **Snort 2 (legacy)** | `/etc/snort/snort.conf`, `/etc/snort/rules/*` | `snort -A full -c snort.conf -i eth0`, `snort-stat` | `snort -T -c ...` | SIGHUP |
| **Zeek** | `/opt/zeek/etc/{node,networks,zeekctl}.cfg`, `site/local.zeek` | `zeekctl deploy/status/netstats/diag`, `zeek -r <pcap> local`, `zeek-cut` | `zeek -a` (solo parseo) | `zeekctl deploy` |
| **ntopng** | `/etc/ntopng/ntopng.conf` | `ntopng -i <if> -w 3000 -m <local nets>`, `nprobe` | `ntopng -h` / log | reiniciar |
| **Cacti** | UI web + `/etc/cacti/debian.php` | `spine`, `poller.php`, `cli/add_device.php` | `spine --verbose=2` | cron del poller |
| **OpenVAS / GVM** | `/etc/openvas/openvas.conf`, `/etc/gvm/*` | `gvm-setup`, `gvm-check-setup`, `gvm-start`/`gvm-stop`, `greenbone-feed-sync`, `gvmd --create-user`, `gvm-cli`, `openvas-nasl` | `gvm-check-setup` | reiniciar el servicio |

**Anatomía de una regla, memorizada:**
`action proto src_ip src_port -> dst_ip dst_port (msg; flow; content; modifiers; sticky buffers; threshold; classtype; sid; rev;)`

**Rango de SID local:** `1000000–1999999`. **Acciones de regla:** `alert`, `pass`, `drop`, `reject`. **`drop` requiere modo IPS** — en modo IDS se registra con `"action":"allowed"`.

**Modos de falla ordenados por cuán seguido muerden en producción:**

1. `HOME_NET` no coincide con la red real → la mayoría de las reglas silenciosamente inertes.
2. Offloads (GRO/LRO/TSO) dejados activados → anomalías del decodificador, puntos ciegos de evasión, checksums espurios.
3. `logrotate` sin `reopen-log-files` → `eve.json` congelado, el motor reporta salud.
4. Drops del kernel por rings subdimensionados o pocos workers → medible, y nadie lo midió.
5. Desbalance por flujo elefante en `cluster_flow` → un worker al 100%, el resto ocioso.
6. NFQUEUE sin `fail-open` / `bypass` → reiniciar el sensor se convierte en una caída de red.
7. Feed de reglas que no se actualiza → detección congelada al día de la instalación.
8. Supresiones obsoletas sin responsable → superficie de detección erosionada silenciosamente.

---

## Referencias

**LPI**
- Exam 303 Objectives (303-300, v3.0): https://www.lpi.org/our-certifications/exam-303-objectives/
- LPIC-3 Security certification overview: https://www.lpi.org/our-certifications/lpic-3-303-overview/

**Suricata (OISF)**
- Suricata 7.0 documentation: https://docs.suricata.io/en/suricata-7.0.5/
- Configuration reference (`suricata.yaml`): https://docs.suricata.io/en/suricata-7.0.5/configuration/suricata-yaml.html
- Rule syntax (Suricata Rules): https://docs.suricata.io/en/suricata-7.0.5/rules/index.html
- Performance tuning (High Performance Configuration): https://docs.suricata.io/en/suricata-7.0.5/performance/high-performance-config.html
- Packet capture: AF_PACKET, AF_XDP, DPDK: https://docs.suricata.io/en/suricata-7.0.5/capture-hardware/index.html
- EVE JSON output reference: https://docs.suricata.io/en/suricata-7.0.5/output/eve/eve-json-format.html
- IPS/inline setup (NFQUEUE and AF_PACKET): https://docs.suricata.io/en/suricata-7.0.5/setting-up-ipsinline-for-linux.html
- Unix socket / `suricatasc`: https://docs.suricata.io/en/suricata-7.0.5/unix-socket.html
- `suricata-update` documentation: https://suricata-update.readthedocs.io/en/latest/
- OISF project home: https://suricata.io/

**Snort**
- Snort 3 official documentation portal: https://docs.snort.org/
- Snort 3 user manual: https://docs.snort.org/start/
- Snort 3 rules reference: https://docs.snort.org/rules/
- Snort project home and downloads: https://www.snort.org/downloads
- Talos rule documentation: https://www.snort.org/rules_explanation
- PulledPork 3 (rule management): https://github.com/shirkdog/pulledpork3

**Zeek**
- Zeek documentation: https://docs.zeek.org/en/master/
- Cluster configuration (`node.cfg`): https://docs.zeek.org/en/master/cluster-setup.html
- Log files reference: https://docs.zeek.org/en/master/logs/index.html
- Zeek scripting: https://docs.zeek.org/en/master/scripting/index.html
- Zeek project home: https://zeek.org/

**Network monitoring**
- ntop / ntopng documentation: https://www.ntop.org/guides/ntopng/
- nProbe documentation: https://www.ntop.org/guides/nprobe/
- ntop project home: https://www.ntop.org/
- Cacti documentation: https://docs.cacti.net/
- Cacti project home: https://www.cacti.net/
- RRDtool: https://oss.oetiker.ch/rrdtool/doc/index.en.html
- Net-SNMP documentation: https://www.net-snmp.org/docs/

**Vulnerability scanning**
- Greenbone Community Documentation: https://greenbone.github.io/docs/
- GVM installation and `gvm-check-setup`: https://greenbone.github.io/docs/latest/22.4/source-build/index.html
- python-gvm / gvm-tools (`gvm-cli`, `gvm-script`): https://gvm-tools.readthedocs.io/en/latest/
- GMP protocol reference: https://docs.greenbone.net/API/GMP/gmp-22.4.html
- NASL and NVT development: https://greenbone.github.io/docs/latest/development.html
- openvas-scanner source: https://github.com/greenbone/openvas-scanner

**Kernel and capture internals**
- Linux `packet(7)` / AF_PACKET: https://man7.org/linux/man-pages/man7/packet.7.html
- `ethtool(8)`: https://man7.org/linux/man-pages/man8/ethtool.8.html
- Linux networking scaling (RSS, RPS, RFS, XPS): https://www.kernel.org/doc/Documentation/networking/scaling.rst
- libnetfilter_queue / NFQUEUE: https://netfilter.org/projects/libnetfilter_queue/
- nftables wiki: https://wiki.nftables.org/wiki-nftables/index.php/Main_Page
- tcpdump / libpcap: https://www.tcpdump.org/manpages/tcpdump.1.html

**Detection engineering context**
- MITRE ATT&CK Enterprise matrix: https://attack.mitre.org/matrices/enterprise/
- Emerging Threats Open ruleset: https://rules.emergingthreats.net/open/
- Community ID flow hashing specification: https://github.com/corelight/community-id-spec
- JA3/JA4 TLS fingerprinting: https://github.com/FoxIO-LLC/ja4
- NIST SP 800-94, Guide to Intrusion Detection and Prevention Systems: https://csrc.nist.gov/pubs/sp/800/94/final