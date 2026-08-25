# LPIC-3 303 (303-300 v3.0.0) — Tema 334.2: Detección de intrusiones en red
## Ejercicios guiados de laboratorio

> **Peso en el examen:** 6.67 · **Fuente del objetivo:** <https://www.lpi.org/our-certifications/exam-303-objectives/>
>
> **Áreas de conocimiento clave cubiertas aquí:** monitorización del uso de ancho de banda · configuración de Snort, escritura y gestión de reglas · configuración de OpenVAS/GVM y NASL.
>
> **Términos y utilidades ejercitados:** `ntop`/`ntopng`, `Cacti`, `bandwidthd`, `iftop`, `iptraf-ng`, `snort`, `snort-stat`, `/etc/snort/*`, `oinkmaster`, `pulledpork`, `openvas`/`gvmd`/`gsad`/`ospd-openvas`, `greenbone-feed-sync`, `gvm-check-setup`, `gvm-cli`, `openvas-nasl`, NASL.

---

## 0. Topología del laboratorio, requisitos previos y reglas de compromiso

> **Reglas de compromiso.** Todo escaneo, sondeo y exploit de este laboratorio apunta a máquinas que usted mismo construye, en una red aislada de solo anfitrión **sin ruta a Internet desde el segmento objetivo**. Escanear vulnerabilidades en un host que no le pertenece o para el que no tiene autorización escrita es un delito penal en la mayoría de las jurisdicciones. Nunca apunte `gvmd` a una red de producción sin un documento de alcance firmado: un escaneo autenticado de GVM es indistinguible de un ataque para cualquier SOC que se precie.

Construya tres máquinas virtuales en una red aislada `192.168.56.0/24`:

| Rol | Nombre de host | IP | SO | Propósito |
|---|---|---|---|---|
| Sensor | `sensor` | 192.168.56.10 | Debian 12 (bookworm) | Snort 2.9 + Snort 3, herramientas de ancho de banda, Cacti |
| Objetivo | `target`  | 192.168.56.20 | Debian 12 | `nginx`, `vsftpd`, `openssh-server`, `snmpd` |
| Escáner | `scanner` | 192.168.56.30 | Kali Linux (rolling) | GVM/OpenVAS, `nmap`, `hping3` |

El sensor tiene además una segunda interfaz, `eth1`, conectada al mismo segmento en modo **promiscuo / monitor**: es la interfaz en la que Snort escucha, emulando un puerto SPAN/espejo.

```bash
# On all three, as root
apt-get update && apt-get -y install tcpdump ethtool net-tools iproute2 curl git
hostnamectl set-hostname sensor    # adjust per host
```

En `target`:

```bash
apt-get -y install nginx vsftpd openssh-server snmpd
systemctl enable --now nginx vsftpd ssh snmpd
```

Tome una instantánea de las tres VM ahora. Varios ejercicios son destructivos para la configuración.

---

## Ejercicio 1 — Preparar la interfaz del sensor para una captura honesta

Un NIDS que lee tramas reensambladas y descargadas por hardware ve un flujo de paquetes que el host objetivo nunca verá. Esta es la causa más común de «Snort está corriendo pero no detecta nada» en producción.

**Pasos**

1. Levante la interfaz de monitorización sin dirección IP. Una interfaz sin IP no puede ser direccionada, que es la postura correcta para un sensor pasivo:

   ```bash
   ip link set eth1 up
   ip addr flush dev eth1
   ip -brief link show eth1
   ```

   Esperado:

   ```
   eth1             UP             08:00:27:9c:1a:44 <BROADCAST,MULTICAST,UP,LOWER_UP>
   ```

2. Active el modo promiscuo explícitamente y confirme que el kernel lo aceptó:

   ```bash
   ip link set eth1 promisc on
   ip -d link show eth1 | grep -i promisc
   dmesg | tail -3
   ```

   Esperado (abreviado):

   ```
   [ 4213.882110] device eth1 entered promiscuous mode
   ```

3. Inspeccione las funciones de descarga (offload) de la NIC que reescriben el flujo de paquetes antes de que llegue a libpcap:

   ```bash
   ethtool -k eth1 | grep -E 'generic-receive-offload|large-receive-offload|tcp-segmentation-offload|generic-segmentation-offload'
   ```

   Esperado:

   ```
   tcp-segmentation-offload: on
   generic-segmentation-offload: on
   generic-receive-offload: on
   large-receive-offload: off [fixed]
   ```

4. Desactívelas y haga que el cambio sobreviva a un reinicio:

   ```bash
   ethtool -K eth1 gro off lro off tso off gso off
   ethtool -k eth1 | grep -E 'generic-receive-offload|tcp-segmentation-offload'
   ```

   ```bash
   cat >/etc/systemd/system/nic-offload@.service <<'EOF'
   [Unit]
   Description=Disable NIC offloads on %i for IDS capture
   After=network.target

   [Service]
   Type=oneshot
   ExecStart=/usr/sbin/ethtool -K %i gro off lro off tso off gso off
   RemainAfterExit=yes

   [Install]
   WantedBy=multi-user.target
   EOF
   systemctl daemon-reload
   systemctl enable --now nic-offload@eth1
   ```

5. Tome una captura de referencia y confirme que ve tráfico que *no* está dirigido al sensor. Desde `scanner`, ejecute `ping -c 20 192.168.56.20` mientras el sensor corre:

   ```bash
   tcpdump -i eth1 -nn -c 10 -s 0 'icmp'
   ```

   Esperado (abreviado):

   ```
   14:02:11.334512 IP 192.168.56.30 > 192.168.56.20: ICMP echo request, id 12, seq 1, length 64
   14:02:11.334980 IP 192.168.56.20 > 192.168.56.30: ICMP echo reply,   id 12, seq 1, length 64
   ```

6. Mida los descartes antes de confiar en cualquier conteo de alertas:

   ```bash
   tcpdump -i eth1 -nn -s 0 -w /tmp/base.pcap &
   sleep 30; kill %1
   ip -s link show eth1 | sed -n '3,6p'
   ```

   Esperado:

   ```
   RX:  bytes packets errors dropped  missed   mcast
       184220    1902      0       0       0      12
   ```

**Verificación de comprensión — bloque 1**

- **Q1.1** — ¿Por qué una interfaz en modo promiscuo y sin dirección IP sigue entregando tramas a `libpcap`?
- **Q1.2** — Explique con precisión qué le hace GRO a un flujo de cinco segmentos TCP de 1460 bytes, y por qué eso rompe una regla de Snort con `content:"attack"; depth:20;`.
- **Q1.3** — Ve `dropped 0` en `ip -s link`, pero el resumen de salida de Snort informa un 4 % de paquetes descartados. ¿Dónde se produce la pérdida y qué contador leería en su lugar?
- **Q1.4** — Dé una razón operativa para preferir un TAP de red pasivo antes que un puerto SPAN de switch para un sensor NIDS.

---

## Ejercicio 2 — Monitorización del uso de ancho de banda en tiempo real

El objetivo exige explícitamente *«implementar la monitorización del uso de ancho de banda»*. Las herramientas en tiempo real responden «qué está pasando ahora»; el ejercicio 3 responde «qué pasó el martes pasado».

**Pasos**

1. Instale el conjunto de herramientas de tiempo real en `sensor`:

   ```bash
   apt-get -y install iftop iptraf-ng nload bmon vnstat
   ```

2. Ejecute `iftop` asociado a la interfaz de monitorización, con hosts y puertos numéricos y unidades basadas en bytes:

   ```bash
   iftop -i eth1 -nNPB
   ```

   Esperado (abreviado):

   ```
                     12.5KB          25.0KB          37.5KB          50.0KB   62.5KB
   └───────────────┴───────────────┴───────────────┴───────────────┴──────────────
   192.168.56.30:51244        =>  192.168.56.20:80          14.2KB  9.81KB  9.02KB
                              <=                            310KB   241KB   228KB
   192.168.56.30:22           =>  192.168.56.10:22           1.9KB  1.71KB  1.65KB
   ──────────────────────────────────────────────────────────────────────────────
   TX:  cum:  1.42MB   peak:  45.2KB   rates:  16.1KB  11.5KB  10.7KB
   RX:        7.31MB          312KB            311KB   243KB   230KB
   TOTAL:     8.73MB          338KB            327KB   254KB   241KB
   ```

   Mientras corre, pulse `n` (alterna la resolución DNS), `p` (alterna los puertos), `t` (cicla entre la presentación de dos líneas y una línea), `L` (escala logarítmica), `P` (pausa), `o` (congela el orden actual).

   > Las tres columnas de tasa son las medias móviles de 2 segundos, 10 segundos y 40 segundos, no valores instantáneos.

3. Genere carga desde `scanner` y observe cómo aparecen los flujos:

   ```bash
   # on scanner
   dd if=/dev/zero bs=1M count=200 | ssh root@192.168.56.10 'cat > /dev/null'
   ```

4. Use `iftop` de forma no interactiva para que pueda alimentar un script o un informe de cron:

   ```bash
   timeout 15 iftop -i eth1 -nNB -t -s 10 -L 10 > /tmp/iftop-report.txt
   head -20 /tmp/iftop-report.txt
   ```

5. Aplique un filtro BPF para excluir su propio tráfico de gestión: un sensor que informa su propia sesión SSH como el mayor emisor es inútil:

   ```bash
   iftop -i eth1 -nNPB -f 'not (host 192.168.56.10 and port 22)'
   ```

6. Cambie a `iptraf-ng` para obtener desgloses por protocolo y por servicio:

   ```bash
   iptraf-ng -i eth1              # IP traffic monitor, single interface
   ```

   Después ejercite los recolectores no interactivos, cada uno de los cuales escribe un registro y puede ejecutarse en segundo plano:

   ```bash
   timeout 30 iptraf-ng -s eth1 -L /var/log/iptraf-services.log -B
   timeout 30 iptraf-ng -d eth1 -L /var/log/iptraf-detail.log   -B
   timeout 30 iptraf-ng -z eth1 -L /var/log/iptraf-sizes.log    -B
   grep -A15 'TCP/UDP service monitor' /var/log/iptraf-services.log | head -20
   ```

   Esperado (abreviado):

   ```
   *** TCP/UDP service monitor started on eth1
   Proto/Port      Pkts     Bytes   Pkts to/from   Bytes to/from
   TCP/80          4821   6431220           2410         6398112
   TCP/22           932    141880            466           78210
   UDP/161           48      6912             24            3456
   ```

7. Habilite `vnstat` para obtener totales de interfaz a largo plazo sin coste alguno (contadores del kernel, no captura de paquetes):

   ```bash
   systemctl enable --now vnstat
   vnstat -i eth1 --add 2>/dev/null; sleep 60
   vnstat -i eth1 -h
   ```

**Verificación de comprensión — bloque 2**

- **Q2.1** — `iftop` y `vnstat` discrepan sobre el rendimiento total en la misma interfaz. Dé la razón arquitectónica e indique cuál citaría en un informe de planificación de capacidad.
- **Q2.2** — `iptraf-ng -z` informa que el 71 % de los paquetes están en el rango de 1 a 75 bytes mientras el rendimiento total es bajo. ¿Qué dos condiciones muy distintas producen ese perfil, y cómo las distinguiría solo con `iftop`?
- **Q2.3** — ¿Por qué `iftop` necesita `CAP_NET_RAW`, y cuál es la forma de mínimo privilegio de permitir que un operador sin root lo ejecute?
- **Q2.4** — Añade `-f 'not port 22'` a `iftop` y el tráfico cae casi a cero en un enlace ocupado. ¿Qué le dice eso, y por qué es un *hallazgo* y no un error de configuración?

---

## Ejercicio 3 — Contabilidad histórica: `bandwidthd`, SNMP, RRDtool y Cacti

**Pasos — parte A: `bandwidthd`**

1. Instale y configure la contabilidad por host:

   ```bash
   apt-get -y install bandwidthd
   cp /etc/bandwidthd/bandwidthd.conf /etc/bandwidthd/bandwidthd.conf.orig
   ```

2. Edite `/etc/bandwidthd/bandwidthd.conf`:

   ```conf
   subnet 192.168.56.0/24
   dev "eth1"
   skip_intervals 0
   graph_cutoff 1024
   promiscuous true
   output_cdf true
   recover_cdf true
   filter "ip"
   graph true
   meta_refresh 150
   ```

3. Reinicie y confirme que está escribiendo:

   ```bash
   systemctl restart bandwidthd
   systemctl is-active bandwidthd
   ls -l /var/lib/bandwidthd/htdocs/ | head
   ```

   Esperado (abreviado, tras el primer intervalo de 150 segundos):

   ```
   -rw-r--r-- 1 root root  15234 Aug 25 14:20 index.html
   -rw-r--r-- 1 root root   4211 Aug 25 14:20 ip-192.168.56.20.html
   -rw-r--r-- 1 root root  28110 Aug 25 14:20 192.168.56.20-daily.png
   ```

4. Inspeccione el CDF persistente (la base de datos de contabilidad en bruto, no los gráficos):

   ```bash
   ls -l /var/lib/bandwidthd/*.cdf
   head -3 /var/lib/bandwidthd/log.1.0.cdf
   ```

**Pasos — parte B: SNMP + RRDtool + Cacti**

5. En `target`, exponga los contadores de interfaz por SNMP, restringidos al sensor:

   ```bash
   cp /etc/snmp/snmpd.conf /etc/snmp/snmpd.conf.orig
   cat >/etc/snmp/snmpd.conf <<'EOF'
   agentaddress udp:161
   rocommunity lab303 192.168.56.10
   sysLocation  Lab-303
   sysContact   lab@example.invalid
   view   systemonly  included   .1.3.6.1.2.1.1
   view   systemonly  included   .1.3.6.1.2.1.2
   view   systemonly  included   .1.3.6.1.2.1.25.1
   EOF
   systemctl restart snmpd
   ```

6. Desde `sensor`, verifique que los contadores son legibles y que está obteniendo contadores de **64 bits**:

   ```bash
   apt-get -y install snmp snmp-mibs-downloader rrdtool
   snmpwalk -v2c -c lab303 192.168.56.20 IF-MIB::ifDescr
   snmpget  -v2c -c lab303 192.168.56.20 IF-MIB::ifHCInOctets.2 IF-MIB::ifHCOutOctets.2
   ```

   Esperado:

   ```
   IF-MIB::ifDescr.1 = STRING: lo
   IF-MIB::ifDescr.2 = STRING: eth0
   IF-MIB::ifHCInOctets.2  = Counter64: 1043221190
   IF-MIB::ifHCOutOctets.2 = Counter64: 88213377
   ```

7. Construya un RRD mínimo a mano para que la abstracción de Cacti deje de ser magia:

   ```bash
   rrdtool create /tmp/eth0.rrd --step 300 \
     DS:in:COUNTER:600:0:U \
     DS:out:COUNTER:600:0:U \
     RRA:AVERAGE:0.5:1:600 \
     RRA:AVERAGE:0.5:6:700 \
     RRA:AVERAGE:0.5:24:775 \
     RRA:MAX:0.5:288:797
   rrdtool info /tmp/eth0.rrd | grep -E '^(step|ds\[in\]\.(type|minimal_heartbeat)|rra\[0\])'
   ```

   Esperado (abreviado):

   ```
   step = 300
   ds[in].type = "COUNTER"
   ds[in].minimal_heartbeat = 600
   rra[0].cf = "AVERAGE"
   ```

8. Instale Cacti y deje que `dbconfig-common` cree la base de datos:

   ```bash
   apt-get -y install cacti cacti-spine
   # Accept dbconfig-common; choose apache2 when prompted.
   grep -R 'poller' /etc/cron.d/cacti
   ```

   Esperado:

   ```
   */5 * * * * www-data [ -x /usr/share/cacti/site/poller.php ] && php /usr/share/cacti/site/poller.php >/dev/null 2>&1
   ```

9. Termine el instalador web en `http://192.168.56.10/cacti/` (credenciales por defecto `admin` / la contraseña que fijó durante la instalación). Luego:
   - **Console → Devices → Add**: hostname `192.168.56.20`, plantilla *Generic SNMP-enabled Host*, SNMP v2c, comunidad `lab303`.
   - **Create Graphs for this Host** → seleccione la interfaz `eth0` → *Interface - Traffic (bits/sec)*.
   - **Console → Settings → Poller** → Poller Type `spine`.

10. Fuerce un sondeo en lugar de esperar cinco minutos, y lea el RRD resultante directamente:

    ```bash
    sudo -u www-data php /usr/share/cacti/site/poller.php --force 2>&1 | tail -5
    ls -l /var/lib/cacti/rra/ | head
    rrdtool fetch /var/lib/cacti/rra/<file>.rrd AVERAGE -s -30m | head -8
    ```

    Esperado (abreviado):

    ```
    OK u:0.00 s:0.00 r:2.34
    08/25/2026 02:20:00 PM - SYSTEM STATS: Time:2.3418 Method:spine Processes:1 Threads:1 Hosts:2 HostsPerProcess:2 DataSources:8 RRDsProcessed:4
    ```

    ```
                          traffic_in          traffic_out
    1756130400: 1.2043302847e+04 8.8210039122e+02
    1756130700: 1.1980221194e+04 9.0112377301e+02
    ```

**Verificación de comprensión — bloque 3**

- **Q3.1** — `bandwidthd` y Cacti grafican ambos «ancho de banda». Indique la diferencia fundamental en la *fuente de datos* y dé una cosa que cada uno puede mostrar y el otro estructuralmente no.
- **Q3.2** — Su RRD tiene `DS:in:COUNTER:600:0:U` y el dispositivo se reinicia. ¿Qué valor se almacena para el intervalo que abarca el reinicio, y por qué?
- **Q3.3** — Sondeó `ifInOctets` (32 bits) en un enlace de 1 Gbit/s a intervalos de 5 minutos y el gráfico muestra picos inverosímiles. Explique el fallo y la solución.
- **Q3.4** — Explique, usando las definiciones de RRA del paso 7, por qué una ráfaga de tráfico de 30 segundos es invisible en el gráfico anual pero visible en el RRA `MAX`.
- **Q3.5** — ¿Por qué `rocommunity lab303 192.168.56.10` sigue siendo una autenticación débil, y qué cambia SNMPv3?

---

## Ejercicio 4 — Snort 2.9 desde la distribución: `/etc/snort/*` y los modos básicos

El paquete `snort` de Debian es el artefacto que nombra el objetivo del examen (`/etc/snort/*`, `snort-stat`). Snort 2.9 está al final de su vida útil aguas arriba —construirá Snort 3 en el ejercicio 6—, pero la disposición de la configuración y el dialecto de reglas son directamente examinables.

**Pasos**

1. Instale en `sensor`, respondiendo a las preguntas de debconf con la interfaz `eth1` y HOME_NET `192.168.56.0/24`:

   ```bash
   apt-get -y install snort snort-rules-default
   snort -V
   ```

   Esperado (abreviado):

   ```
      ,,_     -*> Snort! <*-
     o"  )~   Version 2.9.20 GRE (Build 82)
      ''''    By Martin Roesch & The Snort Team: http://www.snort.org/contact#team
              Copyright (C) 2014-2022 Cisco and/or its affiliates. All rights reserved.
   ```

2. Trace el árbol de configuración: sepa para qué sirve cada archivo, no solo que existe:

   ```bash
   ls -1 /etc/snort/
   ls -1 /etc/snort/rules | head
   ```

   Esperado (abreviado):

   ```
   attribute_table.dtd
   classification.config
   gen-msg.map
   reference.config
   rules/
   snort.conf
   snort.debian.conf
   threshold.conf
   unicode.map
   ```

   | Archivo | Rol |
   |---|---|
   | `snort.conf` | Configuración maestra: variables, decodificador, preprocesadores, salida, `include` de archivos de reglas |
   | `snort.debian.conf` | Ajustes del envoltorio de arranque específicos de Debian: `DEBIAN_SNORT_INTERFACE`, `HOME_NET`, opciones |
   | `classification.config` | Asocia los nombres de `classtype:` con prioridades |
   | `reference.config` | Asocia los prefijos de `reference:` (`cve`, `bugtraq`, `url`) con plantillas de URL |
   | `gen-msg.map` / `sid-msg.map` | Mapas de ID de generador y SID → mensaje usados por los plugins de salida y por `snort-stat` |
   | `threshold.conf` | Umbralización y supresión de eventos heredadas |
   | `rules/` | Archivos de reglas incorporados mediante `include $RULE_PATH/…` |

3. Lea el bloque de variables del que depende toda regla:

   ```bash
   grep -E '^(ipvar|portvar|var) ' /etc/snort/snort.conf | head -20
   ```

   Esperado (abreviado):

   ```
   ipvar HOME_NET 192.168.56.0/24
   ipvar EXTERNAL_NET !$HOME_NET
   ipvar DNS_SERVERS $HOME_NET
   portvar HTTP_PORTS [80,81,311,383,591,593,901,1220,...]
   var RULE_PATH /etc/snort/rules
   ```

4. Valide la configuración **antes** de tocar el servicio: este es el paso que separa un sensor funcional de uno silencioso:

   ```bash
   snort -T -c /etc/snort/snort.conf -i eth1 2>&1 | tail -8
   ```

   Esperado (abreviado):

   ```
           --== Initialization Complete ==--
   Snort successfully validated the configuration!
   Snort exiting
   ```

5. Ejecute los tres modos clásicos en secuencia, sobre una captura corta, y observe cómo difiere la salida:

   ```bash
   # (a) Sniffer mode — decoded headers to stdout, no rules at all
   timeout 10 snort -v -i eth1

   # (b) Sniffer with payload and link layer
   timeout 10 snort -dev -i eth1

   # (c) Packet logger mode — binary pcap into a log directory
   timeout 10 snort -b -l /var/log/snort -i eth1
   ls -l /var/log/snort/snort.log.*
   ```

6. Reproduzca un pcap a través del conjunto completo de reglas: así se prueba un sensor de forma determinista:

   ```bash
   # produce traffic first, from scanner:  nmap -sS -p 1-100 192.168.56.20
   tcpdump -i eth1 -nn -s 0 -w /tmp/scan.pcap &   # on sensor, before the nmap
   # ...run the nmap, then kill tcpdump
   snort -q -A console -c /etc/snort/snort.conf -r /tmp/scan.pcap
   ```

   Esperado (abreviado):

   ```
   08/25-14:31:02.118344  [**] [122:1:0] (portscan) TCP Portscan [**] [Priority: 3] {PROTO:255} 192.168.56.30 -> 192.168.56.20
   ```

7. Lea con atención las estadísticas de salida: estos números, y no el conteo de alertas, le dicen si el sensor está sano:

   ```bash
   snort -c /etc/snort/snort.conf -r /tmp/scan.pcap 2>&1 | sed -n '/Packet I\/O Totals/,/^===/p'
   ```

   Esperado (abreviado):

   ```
   ===============================================================================
   Packet I/O Totals:
      Received:         1902
      Analyzed:         1902 (100.000%)
       Dropped:            0 (  0.000%)
      Filtered:            0 (  0.000%)
   Outstanding:            0 (  0.000%)
      Injected:            0
   ===============================================================================
   ```

**Verificación de comprensión — bloque 4**

- **Q4.1** — ¿Cuál es la consecuencia práctica de fijar `ipvar EXTERNAL_NET any` en lugar de `!$HOME_NET`? Dé tanto el efecto sobre la detección como el efecto sobre el rendimiento.
- **Q4.2** — `snort -T` tiene éxito pero la unidad de systemd no arranca. Nombre tres causas que `-T` estructuralmente no puede detectar.
- **Q4.3** — En la alerta `[122:1:0]`, identifique cada uno de los tres números y explique por qué el tercero es `0` aquí pero distinto de cero en una regla escrita por usted.
- **Q4.4** — ¿Por qué reproducir un pcap no es una prueba completa de un sensor que va a funcionar en línea? Nombre dos comportamientos que solo aparecen con tráfico en vivo.
- **Q4.5** — ¿En qué circunstancias `Analyzed` queda por debajo de `Received` incluso cuando `Dropped` es 0?

---

## Ejercicio 5 — Anatomía de una regla: escribir, probar y ajustar reglas de Snort

**Pasos**

1. Cree un archivo de reglas locales y asegúrese de que se incluye exactamente una vez:

   ```bash
   grep -n 'local.rules' /etc/snort/snort.conf
   ```

   Esperado:

   ```
   576:include $RULE_PATH/local.rules
   ```

2. Escriba cuatro reglas que ejerciten la cabecera, las opciones de carga útil, las opciones ajenas a la carga útil y las opciones de posdetección:

   ```bash
   cat >/etc/snort/rules/local.rules <<'EOF'
   # ---- 1. Header only: any ICMP echo request into the lab
   alert icmp $EXTERNAL_NET any -> $HOME_NET any ( \
     msg:"LOCAL ICMP echo request into HOME_NET"; \
     itype:8; \
     classtype:misc-activity; \
     sid:1000001; rev:1; )

   # ---- 2. Payload: path traversal attempt in a URI
   alert tcp $EXTERNAL_NET any -> $HOME_NET $HTTP_PORTS ( \
     msg:"LOCAL HTTP path traversal attempt"; \
     flow:to_server,established; \
     content:"GET"; http_method; \
     content:"../"; http_uri; nocase; \
     reference:url,owasp.org/www-community/attacks/Path_Traversal; \
     classtype:web-application-attack; \
     sid:1000002; rev:1; )

   # ---- 3. Non-payload + rate: SSH authentication brute force
   alert tcp $EXTERNAL_NET any -> $HOME_NET 22 ( \
     msg:"LOCAL SSH connection flood from single source"; \
     flow:to_server; \
     flags:S; \
     detection_filter:track by_src, count 10, seconds 30; \
     classtype:attempted-recon; \
     sid:1000003; rev:1; )

   # ---- 4. Stateful across packets: FTP login followed by SITE EXEC
   alert tcp $EXTERNAL_NET any -> $HOME_NET 21 ( \
     msg:"LOCAL FTP USER observed"; \
     flow:to_server,established; \
     content:"USER "; depth:5; nocase; \
     flowbits:set,lab.ftp_user; flowbits:noalert; \
     sid:1000004; rev:1; )

   alert tcp $EXTERNAL_NET any -> $HOME_NET 21 ( \
     msg:"LOCAL FTP SITE EXEC after USER"; \
     flow:to_server,established; \
     flowbits:isset,lab.ftp_user; \
     content:"SITE EXEC"; nocase; \
     classtype:attempted-admin; priority:1; \
     sid:1000005; rev:1; )
   EOF
   snort -T -c /etc/snort/snort.conf -i eth1 2>&1 | tail -3
   ```

3. Dispare las reglas 1 y 2 desde `scanner` mientras Snort corre en modo consola en `sensor`:

   ```bash
   # sensor
   snort -q -A console -c /etc/snort/snort.conf -i eth1
   ```

   ```bash
   # scanner
   ping -c 3 192.168.56.20
   curl -s 'http://192.168.56.20/index.html?f=../../../../etc/passwd' -o /dev/null
   ```

   Esperado en el sensor:

   ```
   08/25-15:04:19.774312  [**] [1:1000001:1] LOCAL ICMP echo request into HOME_NET [**] [Classification: Misc activity] [Priority: 3] {ICMP} 192.168.56.30 -> 192.168.56.20
   08/25-15:04:33.117905  [**] [1:1000002:1] LOCAL HTTP path traversal attempt [**] [Classification: Web Application Attack] [Priority: 1] {TCP} 192.168.56.30:41288 -> 192.168.56.20:80
   ```

4. Dispare la regla 3 y observe la semántica de `detection_filter`:

   ```bash
   # scanner
   hping3 -S -p 22 -c 25 -i u20000 192.168.56.20
   ```

   Obtiene **una** alerta en el décimo paquete coincidente dentro de la ventana, y luego una por cada paquete posterior, no una por paquete desde el principio.

5. Ahora suprima una regla ruidosa por origen sin editarla, usando el filtrado de eventos:

   ```bash
   cat >>/etc/snort/threshold.conf <<'EOF'
   # Only ever report SID 1000001 once per 60s per source
   event_filter gen_id 1, sig_id 1000001, type limit, track by_src, count 1, seconds 60

   # The monitoring station legitimately pings everything; silence it entirely
   suppress gen_id 1, sig_id 1000001, track by_src, ip 192.168.56.30
   EOF
   snort -T -c /etc/snort/snort.conf -i eth1 2>&1 | tail -3
   ```

6. Verifique que la supresión surtió efecto repitiendo el ping del paso 3: no debería aparecer ninguna alerta ICMP, mientras que la alerta HTTP sí sigue apareciendo.

7. Lea una regla distribuida y descompóngala. Elija cualquier regla del conjunto de la distribución:

   ```bash
   grep -m1 'flowbits' /etc/snort/rules/*.rules
   ```

**Verificación de comprensión — bloque 5**

- **Q5.1** — En la regla 2, ¿por qué `content:"GET"; http_method;` es más barato para el motor de detección que `content:"GET /"; depth:5;` aunque ambos coincidan con el mismo tráfico?
- **Q5.2** — ¿Cuál es la diferencia entre `detection_filter` y un `event_filter` con `type limit`? ¿Cuál de los dos cambia si la regla *coincidió*?
- **Q5.3** — La regla 4 usa `flowbits:noalert`. ¿Qué se rompe si lo omite, y qué se rompe si además omite `flowbits:set`?
- **Q5.4** — Dos analistas añaden reglas con `sid:1000002`. ¿Qué hace Snort, y qué rango de SID deberían usar las reglas escritas localmente?
- **Q5.5** — Necesita que `content:"admin"` coincida solo en el cuerpo de la respuesta HTTP, nunca en las cabeceras. Nombre el mecanismo en Snort 2 y su equivalente en Snort 3.
- **Q5.6** — ¿Por qué `flow:to_server,established` mejora la precisión *y* a la vez reduce la CPU?

---

## Ejercicio 6 — Snort 3: arquitectura, configuración en Lua y multihilo

**Pasos**

1. Compile Snort 3 desde el código fuente en `sensor` (prevea entre 15 y 30 minutos):

   ```bash
   apt-get -y install build-essential cmake libpcap-dev libpcre2-dev libdumbnet-dev \
     bison flex zlib1g-dev pkg-config libhwloc-dev liblzma-dev openssl libssl-dev \
     libnghttp2-dev libluajit-5.1-dev libunwind-dev uuid-dev libtool autoconf \
     libmnl-dev libnetfilter-queue-dev

   cd /usr/local/src
   git clone https://github.com/snort3/libdaq.git
   cd libdaq && ./bootstrap && ./configure --prefix=/usr/local && make -j"$(nproc)" && make install

   cd /usr/local/src
   git clone https://github.com/snort3/snort3.git
   cd snort3 && ./configure_cmake.sh --prefix=/usr/local --enable-tcmalloc
   cd build && make -j"$(nproc)" && make install
   ldconfig
   /usr/local/bin/snort -V
   ```

   Esperado (abreviado):

   ```
      ,,_     -*> Snort++ <*-
     o"  )~   Version 3.1.78.0
      ''''    By Martin Roesch & The Snort Team
   ```

2. Enumere la arquitectura de ejecución. Cada etapa siguiente es un plugin que puede listar:

   ```bash
   /usr/local/bin/snort --show-plugins 2>&1 | awk '{print $1}' | sort | uniq -c | sort -rn | head
   /usr/local/bin/snort --help-module search_engine | head -20
   /usr/local/bin/snort --list-modules | head -20
   ```

   La cadena de procesamiento, en orden: **DAQ** (adquisición de paquetes) → **codecs** (decodificación de enlace/red/transporte) → **stream** (seguimiento de flujos + reensamblado TCP) → **inspectores** (`http_inspect`, `dns`, `ssh`, `port_scan`, …, los «preprocesadores» de Snort 2) → **detección** (MPSE de patrón rápido, y luego evaluación completa de las reglas) → **eventos** (filtros/supresión) → **registradores** (`alert_fast`, `alert_json`, `unified2`, …).

3. Inspeccione la configuración Lua por defecto y note la diferencia estructural con `snort.conf`:

   ```bash
   ls -1 /usr/local/etc/snort/
   grep -n 'HOME_NET' /usr/local/etc/snort/snort.lua
   ```

   Esperado (abreviado):

   ```
   file_magic.lua
   snort.lua
   snort_defaults.lua
   talos.lua
   ```

4. Configure un sensor mínimo funcional. Edite `/usr/local/etc/snort/snort.lua`:

   ```lua
   HOME_NET = '192.168.56.0/24'
   EXTERNAL_NET = '!$HOME_NET'

   ips =
   {
       enable_builtin_rules = true,
       include = RULE_PATH .. '/local.rules',
       variables = default_variables,
   }

   port_scan = { protos = 'all', scan_types = 'all', watch_ip = '192.168.56.0/24' }

   alert_fast = { file = true, packet = false }
   ```

5. Porte dos de sus reglas de Snort 2 a la sintaxis de Snort 3 y observe el cambio de los búferes adhesivos:

   ```bash
   mkdir -p /usr/local/etc/snort/rules
   cat >/usr/local/etc/snort/rules/local.rules <<'EOF'
   alert icmp ( msg:"LOCAL ICMP echo request into HOME_NET"; itype:8;
                classtype:misc-activity; sid:1000001; rev:1; )

   alert http ( msg:"LOCAL HTTP path traversal attempt";
                flow:to_server,established;
                http_method; content:"GET";
                http_uri;    content:"../", nocase;
                classtype:web-application-attack; sid:1000002; rev:1; )
   EOF
   ```

   > En Snort 3 la opción de búfer (`http_uri`) es un **búfer adhesivo** (*sticky buffer*) que va *antes* del `content:` al que se aplica, y los argumentos de las opciones de regla se separan por comas. En Snort 2 el modificador iba después del `content:`.

6. Valide y luego reproduzca:

   ```bash
   /usr/local/bin/snort -c /usr/local/etc/snort/snort.lua --warn-all -T 2>&1 | tail -5
   /usr/local/bin/snort -c /usr/local/etc/snort/snort.lua \
     -R /usr/local/etc/snort/rules/local.rules \
     -r /tmp/scan.pcap -A alert_fast -s 65535 -k none -l /var/log/snort
   ```

   Esperado (abreviado):

   ```
   Snort successfully validated the configuration (with 0 warnings).
   o")~   Snort exiting
   ```

7. Ejecute en vivo con varios hilos de paquetes sobre el fanout de AF_PACKET:

   ```bash
   /usr/local/bin/snort -c /usr/local/etc/snort/snort.lua \
     -i eth1 --daq afpacket --daq-var buffer_size_mb=1024 \
     -z 4 -A alert_fast -l /var/log/snort --warn-all
   ```

   La opción `-z 4` inicia cuatro hilos de procesamiento de paquetes; el fanout de `afpacket` aplica un hash a cada flujo para asignarlo exactamente a un hilo, de modo que el reensamblado de flujos siga siendo coherente.

8. Compare los dos dialectos de reglas mecánicamente:

   ```bash
   /usr/local/bin/snort -c /usr/local/etc/snort/snort.lua --rule-to-text \
     -R /usr/local/etc/snort/rules/local.rules 2>&1 | head
   /usr/local/bin/snort --dump-builtin-rules | head -5
   ```

**Verificación de comprensión — bloque 6**

- **Q6.1** — ¿Qué le aporta la abstracción DAQ que no le da llamar directamente a `libpcap`? Nombre dos módulos DAQ y el despliegue que implica cada uno.
- **Q6.2** — Explique por qué `-z 4` con el fanout de `afpacket` es seguro para el reensamblado TCP, pero cuatro procesos `snort` *separados* sobre la misma interfaz no lo serían.
- **Q6.3** — Convierta `content:"admin"; nocase; http_client_body;` (Snort 2) a Snort 3 y explique por qué cambió el orden.
- **Q6.4** — ¿Qué hace `-k none`, y cuál es el escenario exacto en el que omitirlo hace que una regla nunca se dispare silenciosamente?
- **Q6.5** — `--dump-builtin-rules` emite reglas con GID distintos de 1. ¿De dónde vienen esas reglas y por qué no puede editarlas en un archivo `.rules`?

---

## Ejercicio 7 — Gestión y actualización de reglas: `oinkmaster` y PulledPork

El objetivo es explícito sobre la *«gestión y actualización de reglas de Snort»*. Un sensor cuyas reglas tienen tres meses es un artefacto de cumplimiento, no un control.

**Pasos — parte A: `oinkmaster` (clásico, Snort 2)**

1. Instale e inspeccione la configuración:

   ```bash
   apt-get -y install oinkmaster
   grep -vE '^\s*#|^\s*$' /etc/oinkmaster.conf | head -20
   ```

2. Regístrese en <https://www.snort.org/users/sign_up> para obtener un **Oinkcode**, y luego fije la fuente de reglas:

   ```bash
   cat >>/etc/oinkmaster.conf <<'EOF'
   url = https://www.snort.org/rules/snortrules-snapshot-29200.tar.gz?oinkcode=<YOUR_OINKCODE>
   url = https://www.snort.org/downloads/community/community-rules.tar.gz
   EOF
   ```

3. Aprenda las tres directivas de ajuste: en esto consiste todo `oinkmaster`, y es examinable:

   ```bash
   cat >>/etc/oinkmaster.conf <<'EOF'
   # Never let an update overwrite rules I own
   skipfile local.rules
   skipfile deleted.rules

   # Disable a rule that is a permanent false positive here
   disablesid 2013504

   # Re-enable a rule the vendor ships disabled
   enablesid 2010935

   # Change a rule in place, every time it is updated
   modifysid 2002383 "alert" | "drop"
   EOF
   ```

4. Haga primero una ejecución en seco, luego aplique, y después recargue el sensor:

   ```bash
   mkdir -p /var/backups/snort-rules
   oinkmaster -C /etc/oinkmaster.conf -o /etc/snort/rules -c        # -c = careful (dry run)
   oinkmaster -C /etc/oinkmaster.conf -o /etc/snort/rules -b /var/backups/snort-rules
   ```

   Esperado (abreviado):

   ```
   Loading /etc/oinkmaster.conf
   Downloading file from https://www.snort.org/rules/... done.
   Archive successfully downloaded, unpacking... done.
   Setting up rules structures... done.
   Processing downloaded rules... disabled 1, enabled 1, modified 1, total=48231
   Comparing new files to the old ones... done.
   [***] Results from Oinkmaster started ... [***]
   [*] Rules modifications: [*]
       -> Modified active rules: 214
       -> Added new rules: 37
   ```

5. Nunca reinicie, siempre recargue: un reinicio descarta paquetes:

   ```bash
   snort -T -c /etc/snort/snort.conf -i eth1 >/dev/null 2>&1 && kill -HUP "$(cat /var/run/snort_eth1.pid)"
   ```

**Pasos — parte B: PulledPork 3 (actual, Snort 3)**

6. Instalación:

   ```bash
   cd /usr/local/src
   git clone https://github.com/shirkdog/pulledpork3.git
   cd pulledpork3
   mkdir -p /usr/local/etc/pulledpork3 /usr/local/bin/pulledpork3
   cp pulledpork.py       /usr/local/bin/
   cp -r lib/             /usr/local/bin/pulledpork3/
   cp etc/pulledpork.conf /usr/local/etc/pulledpork3/
   chmod +x /usr/local/bin/pulledpork.py
   ```

7. Configure `/usr/local/etc/pulledpork3/pulledpork.conf`:

   ```conf
   registered_ruleset  = true
   community_ruleset   = true
   oinkcode            = <YOUR_OINKCODE>
   snort_path          = /usr/local/bin/snort
   snort_version       = 3.1.78.0
   rule_path           = /usr/local/etc/snort/rules/pulledpork.rules
   local_rules         = /usr/local/etc/snort/rules/local.rules
   sorule_path         = /usr/local/etc/snort/so_rules/
   ips_policy          = balanced
   include_disabled_rules = false
   ```

8. Ejecútelo y lea el resumen:

   ```bash
   /usr/local/bin/pulledpork.py -c /usr/local/etc/pulledpork3/pulledpork.conf -v 2>&1 | tail -20
   wc -l /usr/local/etc/snort/rules/pulledpork.rules
   ```

   Esperado (abreviado):

   ```
   Rules ruleset:
       Rules loaded:              52104
       Rules enabled:             10233
       Rules disabled:            41871
       ...
   Writing rules to: /usr/local/etc/snort/rules/pulledpork.rules
   ```

9. Apunte Snort 3 al archivo fusionado, vuelva a validar y confirme que el número de reglas habilitadas cambió:

   ```lua
   -- in snort.lua
   ips = {
       enable_builtin_rules = true,
       include = RULE_PATH .. '/pulledpork.rules',
       variables = default_variables,
   }
   ```

   ```bash
   /usr/local/bin/snort -c /usr/local/etc/snort/snort.lua --warn-all -T 2>&1 | grep -iE 'rules|warning' | head
   ```

10. Automatícelo, pero nunca a ciegas:

    ```bash
    cat >/etc/cron.d/pulledpork <<'EOF'
    # Update rules nightly; validate before reloading. Failure mails root.
    30 3 * * * root /usr/local/bin/pulledpork.py -c /usr/local/etc/pulledpork3/pulledpork.conf >/var/log/pulledpork.log 2>&1 && /usr/local/bin/snort -c /usr/local/etc/snort/snort.lua -T >>/var/log/pulledpork.log 2>&1 && systemctl reload snort3
    EOF
    ```

**Verificación de comprensión — bloque 7**

- **Q7.1** — `oinkmaster` ofrece `disablesid`, y podría igualmente borrar la línea de la regla. ¿Por qué `disablesid` es la elección correcta en un entorno gestionado?
- **Q7.2** — ¿Qué es una `ips_policy` (`connectivity` / `balanced` / `security` / `max-detect`), y qué le hace a su tasa de falsos positivos y a su CPU pasar de `balanced` a `security`?
- **Q7.3** — La tarea de cron del paso 10 usa `&&` entre tres comandos. Nombre el modo de fallo exacto que evita este encadenamiento.
- **Q7.4** — ¿Qué son las reglas SO, por qué necesitan `sorule_path` y una `snort_version` coincidente, y qué riesgo de cadena de suministro conllevan?
- **Q7.5** — Su `local.rules` desapareció tras una actualización de reglas. ¿Qué directiva de configuración faltaba, en cada una de las dos herramientas?

---

## Ejercicio 8 — Salida, registro y triaje: `unified2`, `alert_json`, syslog y `snort-stat`

**Pasos**

1. Ejercite los plugins de salida de Snort 2 uno por uno contra el mismo pcap y compare:

   ```bash
   for mode in fast full console cmg csv; do
     echo "=== $mode ==="
     snort -q -A "$mode" -c /etc/snort/snort.conf -r /tmp/scan.pcap -l /tmp/out-$mode 2>&1 | head -4
   done
   ```

2. Configure la salida binaria `unified2`, el único formato que escala, porque Snort escribe un registro binario compacto y delega el coste del análisis a otro proceso:

   ```bash
   # in /etc/snort/snort.conf
   output unified2: filename snort.u2, limit 128, mpls_event_types, vlan_event_types
   ```

   ```bash
   snort -q -c /etc/snort/snort.conf -r /tmp/scan.pcap -l /var/log/snort
   ls -l /var/log/snort/snort.u2.*
   u2spewfoo /var/log/snort/snort.u2.* | head -30
   ```

   Esperado (abreviado):

   ```
   (Event)
       sensor id: 0	event id: 1	event second: 1756131062	event microsecond: 118344
       sig id: 1	gen id: 122	revision: 0	 classification: 3
       priority: 3	ip source: 192.168.56.30	ip destination: 192.168.56.20
       src port: 0	dest port: 0	protocol: 255	impact_flag: 0	blocked: 0
   ```

3. Envíe las alertas a syslog y confirme que llegan:

   ```bash
   snort -q -A syslog -c /etc/snort/snort.conf -r /tmp/scan.pcap
   grep snort /var/log/syslog | tail -3
   ```

   Esperado (abreviado):

   ```
   Aug 25 15:31:02 sensor snort[4412]: [122:1:0] (portscan) TCP Portscan [Classification: Attempted Information Leak] [Priority: 2]: {PROTO255} 192.168.56.30 -> 192.168.56.20
   ```

4. Resuma con `snort-stat`, la herramienta de informes que nombra el objetivo. Es un script en Perl que consume líneas de alerta en **formato syslog** por la entrada estándar:

   ```bash
   head -30 /usr/sbin/snort-stat
   grep -h snort /var/log/syslog | /usr/sbin/snort-stat | head -40
   ```

   Obtiene un informe en texto plano agrupado por host de origen, host de destino, firma y puerto, con conteos por grupo. *(La disposición exacta de las columnas varía entre versiones del paquete: lea la cabecera del script en su sistema en lugar de memorizar una muestra.)*

5. Vea dónde lo conecta automáticamente la distribución:

   ```bash
   cat /etc/cron.daily/snort
   grep -vE '^\s*#|^\s*$' /etc/snort/snort.debian.conf
   ```

6. Ahora el equivalente en Snort 3: JSON estructurado, listo para un enviador de registros:

   ```lua
   -- in snort.lua
   alert_json =
   {
       file = true,
       limit = 100,
       fields = 'timestamp iface src_addr src_port dst_addr dst_port proto ' ..
                'action msg gid sid rev priority class service pkt_num'
   }
   ```

   ```bash
   /usr/local/bin/snort -c /usr/local/etc/snort/snort.lua -r /tmp/scan.pcap -l /var/log/snort -q
   tail -2 /var/log/snort/alert_json.txt | python3 -m json.tool
   ```

   Esperado (abreviado):

   ```json
   {
       "timestamp": "08/25-15:31:02.118344",
       "iface": "eth1",
       "src_addr": "192.168.56.30",
       "dst_addr": "192.168.56.20",
       "dst_port": 80,
       "proto": "TCP",
       "action": "allow",
       "msg": "LOCAL HTTP path traversal attempt",
       "gid": 1, "sid": 1000002, "rev": 1,
       "priority": 1,
       "class": "Web Application Attack"
   }
   ```

7. Calcule una métrica de triaje —las diez firmas con más volumen—, que es lo que realmente impulsa el ajuste:

   ```bash
   python3 - <<'EOF'
   import json, collections
   c = collections.Counter()
   for line in open('/var/log/snort/alert_json.txt'):
       try: c[json.loads(line)['msg']] += 1
       except Exception: pass
   for msg, n in c.most_common(10): print(f'{n:8d}  {msg}')
   EOF
   ```

**Verificación de comprensión — bloque 8**

- **Q8.1** — ¿Por qué `-A full` es inaceptable en un sensor de 1 Gbit/s, y qué recurso concreto agota primero?
- **Q8.2** — Los registros de `unified2` referencian un SID pero no llevan el texto del mensaje. ¿Qué dos archivos debe leer también el consumidor (`barnyard2`, `u2spewfoo`, un conector SIEM), y qué se rompe si están desactualizados?
- **Q8.3** — La opción `limit 128` de `unified2`: ¿128 de qué, y qué hace Snort cuando se alcanza el límite?
- **Q8.4** — Dé una ventaja y una desventaja de `-A syslog` frente a escribir un archivo local, para un sensor en un segmento de red hostil.
- **Q8.5** — `snort-stat` no produce absolutamente nada a partir de su archivo de alertas. Nombre las dos causas más probables.

---

## Ejercicio 9 — Modo IPS en línea con el DAQ NFQ

**Pasos**

1. Convierta el sensor en un enrutador entre `scanner` y `target` para este ejercicio (o ejecute la prueba en el propio host objetivo, lo cual es más simple e igualmente instructivo):

   ```bash
   sysctl -w net.ipv4.ip_forward=1
   ```

2. Añada una regla `drop`. En Snort 3, `drop` requiere el modo en línea; en modo pasivo se degrada silenciosamente a `alert`:

   ```bash
   cat >>/usr/local/etc/snort/rules/local.rules <<'EOF'
   drop tcp any any -> any 80 ( msg:"LOCAL BLOCK path traversal";
        flow:to_server,established;
        http_uri; content:"../", nocase;
        sid:1000010; rev:1; )
   EOF
   ```

3. Encole el tráfico hacia el espacio de usuario con netfilter:

   ```bash
   iptables -I FORWARD -p tcp --dport 80 -j NFQUEUE --queue-num 4 --queue-bypass
   iptables -L FORWARD -n -v --line-numbers | head
   ```

4. Ejecute Snort en línea:

   ```bash
   /usr/local/bin/snort -c /usr/local/etc/snort/snort.lua \
     -Q --daq nfq --daq-var queue=4 --daq-var device=4 \
     -R /usr/local/etc/snort/rules/local.rules \
     -A alert_fast -l /var/log/snort --warn-all
   ```

   Esperado (abreviado):

   ```
   --------------------------------------------------
   Commencing packet processing
   ++ [0] nfq
   ```

5. Pruebe desde `scanner` y observe que la petición es *descartada*, no meramente registrada:

   ```bash
   curl -m 5 -s -o /dev/null -w '%{http_code}\n' 'http://192.168.56.20/?f=../../etc/passwd'
   ```

   Esperado: `000` (tiempo de espera agotado, sin respuesta), y en el sensor:

   ```
   08/25-16:02:44.881120 [Drop] [**] [1:1000010:1] LOCAL BLOCK path traversal [**] [Priority: 1] {TCP} 192.168.56.30:44120 -> 192.168.56.20:80
   ```

6. Lea las estadísticas del modo en línea al salir:

   ```
   ===============================================================================
   Action Stats:
        Alerts:            1 (  0.052%)
         Total:            1
        Logged:            1 (  0.052%)
        Passed:            0 (  0.000%)
   Limits:
         match:            0
         queue:            0
   ===============================================================================
   ```

7. Ahora comprenda el modo de fallo que acaba de crear. Mate Snort con `--queue-bypass` activo, luego quítelo y repita:

   ```bash
   # With --queue-bypass: traffic flows when no userspace program is attached (fail-open)
   iptables -R FORWARD 1 -p tcp --dport 80 -j NFQUEUE --queue-num 4
   # Without it: killing snort blackholes all port-80 traffic (fail-closed)
   ```

8. Limpieza:

   ```bash
   iptables -D FORWARD -p tcp --dport 80 -j NFQUEUE --queue-num 4 2>/dev/null
   iptables -D FORWARD -p tcp --dport 80 -j NFQUEUE --queue-num 4 --queue-bypass 2>/dev/null
   sysctl -w net.ipv4.ip_forward=0
   ```

**Verificación de comprensión — bloque 9**

- **Q9.1** — Enuncie la diferencia entre IDS e IPS en términos del *camino del paquete*, no de la intención, y explique por qué un sensor en puerto SPAN nunca puede hacer lo segundo.
- **Q9.2** — `--queue-bypass`: describa el compromiso de seguridad en una frase por cada dirección, y diga cuál elegiría para (a) un segmento de tarjetas de pago, (b) una red clínica hospitalaria.
- **Q9.3** — Su sensor en línea añade 4 ms de latencia. Nombre dos palancas de configuración en Snort 3 que la reducen y la detección que sacrifica con cada una.
- **Q9.4** — En modo pasivo escribe `drop tcp …`. ¿Qué ocurre realmente, y cómo hace que Snort se lo diga en lugar de adivinarlo?
- **Q9.5** — ¿Por qué un IPS convierte la configuración del *reensamblado TCP* en un riesgo de estabilidad y no solo en una cuestión de calidad de detección?

---

## Ejercicio 10 — OpenVAS / GVM: instalación, arquitectura y feeds

**Pasos**

1. En `scanner` (Kali), instale la pila de Greenbone Vulnerability Management:

   ```bash
   apt-get update && apt-get -y install gvm gvm-tools
   ```

2. Ejecute la instalación. Esto crea la base de datos PostgreSQL, genera los certificados, crea el usuario `admin` y realiza la primera sincronización completa de feeds: prevea de 30 a 90 minutos y varios GB de disco:

   ```bash
   gvm-setup 2>&1 | tee /root/gvm-setup.log
   ```

   Esperado (abreviado, al final):

   ```
   [+] GVM feeds updated
   [*] Checking Default scanner
   [*] Please note the password for the admin user
   [*] User created with password 'b3f0e2c1-9a2d-4f7b-8c1e-6a9d0e2b4c11'.
   ```

   Anote esa contraseña.

3. Verifique la instalación con la herramienta que nombra el objetivo:

   ```bash
   gvm-check-setup
   ```

   Esperado (abreviado):

   ```
   gvm-check-setup 24.5.0
     Test completeness and readiness of GVM-24.5.0
   Step 1: Checking OpenVAS (Scanner) ...
           OK: OpenVAS Scanner is present in version 23.0.1.
           OK: Notus Scanner is present in version 22.6.2.
           OK: Server CA Certificate is present as /var/lib/gvm/CA/servercert.pem.
           OK: NVT collection in /var/lib/openvas/plugins contains 92311 NVTs.
   Step 2: Checking GVMD Manager ...
           OK: gvmd is present in version 23.5.2.
   Step 3: Checking Certificates ...
   Step 4: Checking data ...
           OK: SCAP data found in /var/lib/gvm/scap-data.
           OK: CERT data found in /var/lib/gvm/cert-data.
   Step 5: Checking Postgresql DB and user ...
   Step 6: Checking GSA (Greenbone Security Assistant) ...
   Step 7: Checking if GVM services are up and running ...
           OK: ospd-openvas service is active.
           OK: gvmd    service is active.
           OK: gsad    service is active.
   It seems like your GVM-24.5.0 installation is OK.
   ```

4. Arranque la pila y relacione la arquitectura de procesos con lo que acaba de leer:

   ```bash
   gvm-start
   systemctl --no-pager status gvmd ospd-openvas gsad notus-scanner 2>&1 | grep -E 'Active:|●'
   ss -lntp | grep -E '9392|5432'
   ss -lxp | grep -E 'gvmd|ospd'
   ```

   Esperado (abreviado):

   ```
   LISTEN 0 128 127.0.0.1:9392 0.0.0.0:* users:(("gsad",pid=5120,fd=8))
   u_str LISTEN 0 128 /run/gvmd/gvmd.sock 39211 users:(("gvmd",pid=5033,fd=6))
   u_str LISTEN 0 128 /run/ospd/ospd-openvas.sock 39044 users:(("ospd-openvas",pid=4988,fd=5))
   ```

   | Componente | Rol | Habla |
   |---|---|---|
   | `gsad` | Greenbone Security Assistant — la interfaz web (HTTPS :9392) | GMP sobre el socket de gvmd |
   | `gvmd` | Gestor: usuarios, objetivos, tareas, configuraciones de escaneo, informes, datos SCAP/CERT en PostgreSQL | **GMP** (Greenbone Management Protocol) |
   | `ospd-openvas` | Envoltorio OSP que lanza y supervisa los procesos de escaneo `openvas` | **OSP** hacia gvmd, Redis hacia el escáner |
   | `openvas` | El motor del escáner: ejecuta NVT (scripts NASL) contra los objetivos | — |
   | `notus-scanner` | Correspondencia de vulnerabilidades basada en versiones de paquetes (rápida, sin sondeo) | MQTT vía `mosquitto` |
   | `redis-server@openvas` | Base de conocimiento por host compartida entre los procesos del escáner | — |

5. Sincronice los feeds explícitamente y comprenda los tres feeds separados:

   ```bash
   runuser -u _gvm -- greenbone-feed-sync --type nvt
   runuser -u _gvm -- greenbone-feed-sync --type scap
   runuser -u _gvm -- greenbone-feed-sync --type cert
   runuser -u _gvm -- greenbone-feed-sync --type gvmd-data
   ```

   | Feed | Contenido | Comando heredado |
   |---|---|---|
   | `nvt` | Pruebas de vulnerabilidad NASL → `/var/lib/openvas/plugins/` | `greenbone-nvt-sync`, antes `openvas-nvt-sync` |
   | `scap` | Datos CPE / CVE / OVAL → `/var/lib/gvm/scap-data/` | `greenbone-scapdata-sync` |
   | `cert` | Avisos de CERT-Bund / DFN-CERT → `/var/lib/gvm/cert-data/` | `greenbone-certdata-sync` |
   | `gvmd-data` | Configuraciones de escaneo, listas de puertos, formatos de informe, políticas de cumplimiento | `greenbone-gvmd-data-sync` |

6. Confirme el estado del feed a través del gestor y no del sistema de archivos:

   ```bash
   export GVM_USER=admin GVM_PASS='<password-from-step-2>'
   gvm-cli --gmp-username "$GVM_USER" --gmp-password "$GVM_PASS" \
     socket --socketpath /run/gvmd/gvmd.sock --xml "<get_feeds/>" | xmllint --format - | head -30
   ```

   Esperado (abreviado):

   ```xml
   <get_feeds_response status="200" status_text="OK">
     <feed><type>NVT</type><name>Greenbone Community Feed</name>
       <version>202608250541</version><currently_syncing/></feed>
     <feed><type>SCAP</type><version>202608241030</version></feed>
     <feed><type>CERT</type><version>202608241030</version></feed>
   </get_feeds_response>
   ```

7. Gestione usuarios. `openvas-adduser` / `openvas-rmuser` desaparecieron hace tiempo; ahora la identidad la gestiona `gvmd`:

   ```bash
   runuser -u _gvm -- gvmd --get-users --verbose
   runuser -u _gvm -- gvmd --create-user=analyst --password='S0me-Str0ng-Pass!'
   runuser -u _gvm -- gvmd --user=admin --new-password='An0ther-Str0ng-Pass!'
   runuser -u _gvm -- gvmd --get-roles
   runuser -u _gvm -- gvmd --delete-user=analyst --inheritor=admin
   ```

8. Exponga la interfaz de usuario únicamente en la red del laboratorio, y note qué está aceptando al hacerlo:

   ```bash
   sed -n '/ExecStart/p' /usr/lib/systemd/system/gsad.service
   # --listen 127.0.0.1 by default; change deliberately, behind a reverse proxy in production
   ```

**Verificación de comprensión — bloque 10**

- **Q10.1** — Trace una única petición de escaneo desde el navegador hasta el paquete en el cable, nombrando cada demonio y cada protocolo que atraviesa.
- **Q10.2** — ¿Por qué existe `notus-scanner` si `openvas` ya puede detectar versiones vulnerables? ¿Qué debe ser cierto del escaneo para que Notus aporte algo?
- **Q10.3** — ¿Para qué se usa Redis aquí, y qué le pasa a un escaneo en curso si se reinicia `redis-server@openvas`?
- **Q10.4** — Su `gvm-check-setup` informa `NVT collection … contains 0 NVTs` inmediatamente después de un `greenbone-feed-sync --type nvt` exitoso. Dé dos causas probables.
- **Q10.5** — Distinga el feed **SCAP** del feed **NVT**. ¿Cuál permite a GVM decirle la puntuación CVSS de un CVE, y cuál le permite decirle que el host está afectado?
- **Q10.6** — ¿Por qué `gvmd --delete-user` pide un `--inheritor`?

---

## Ejercicio 11 — Manejar GVM desde la CLI: el ciclo de vida completo de un escaneo GMP

La interfaz web no es scriptable, ni auditable, ni reproducible. Todo lo que sigue es XML de GMP sobre el socket UNIX de `gvmd`.

**Pasos**

1. Prepare una invocación reutilizable y verifique la autenticación:

   ```bash
   apt-get -y install xmlstarlet
   GMP='gvm-cli --gmp-username admin --gmp-password '"$GVM_PASS"' socket --socketpath /run/gvmd/gvmd.sock --xml'
   $GMP "<get_version/>"
   ```

   Esperado:

   ```xml
   <get_version_response status="200" status_text="OK"><version>22.5</version></get_version_response>
   ```

2. Descubra los ID de objeto que necesita: consulte siempre, nunca fije UUID sacados de un blog:

   ```bash
   $GMP "<get_port_lists/>"  | xmlstarlet sel -t -m '//port_list'  -v 'name' -o '  ' -v '@id' -n
   $GMP "<get_configs/>"     | xmlstarlet sel -t -m '//config'     -v 'name' -o '  ' -v '@id' -n
   $GMP "<get_scanners/>"    | xmlstarlet sel -t -m '//scanner'    -v 'name' -o '  ' -v '@id' -n
   $GMP "<get_report_formats/>" | xmlstarlet sel -t -m '//report_format' -v 'name' -o '  ' -v '@id' -n
   ```

   Esperado (abreviado):

   ```
   All IANA assigned TCP                33d0cd82-57c6-11e1-8ed1-406186ea4fc5
   All IANA assigned TCP and UDP        4a4717fe-57d2-11e1-9a26-406186ea4fc5
   OpenVAS Default                      c7e03b6c-3bbe-11e1-a057-406186ea4fc5
   Full and fast                        daba56c8-73ec-11df-a475-002264764cea
   Base                                 d21f6c81-2b88-4ac1-b7b4-a2a9f2ad4663
   OpenVAS Default                      08b69003-5fc2-4037-a479-93b440211c73
   ```

3. Guárdelos en variables de shell:

   ```bash
   PORTLIST_ID=$($GMP "<get_port_lists/>" | xmlstarlet sel -t -m '//port_list[name="All IANA assigned TCP"]' -v '@id' -n | head -1)
   CONFIG_ID=$($GMP  "<get_configs/>"     | xmlstarlet sel -t -m '//config[name="Full and fast"]'            -v '@id' -n | head -1)
   SCANNER_ID=$($GMP "<get_scanners/>"    | xmlstarlet sel -t -m '//scanner[name="OpenVAS Default"]'         -v '@id' -n | head -1)
   printf 'portlist=%s\nconfig=%s\nscanner=%s\n' "$PORTLIST_ID" "$CONFIG_ID" "$SCANNER_ID"
   ```

4. Cree el objetivo:

   ```bash
   TARGET_ID=$($GMP "<create_target>
       <name>lab-target-56.20</name>
       <hosts>192.168.56.20</hosts>
       <port_list id=\"$PORTLIST_ID\"/>
       <alive_tests>ICMP, TCP-ACK Service &amp; ARP Ping</alive_tests>
     </create_target>" | xmlstarlet sel -t -v '//create_target_response/@id')
   echo "$TARGET_ID"
   ```

5. Cree e inicie la tarea, capturando el ID de informe que devuelve:

   ```bash
   TASK_ID=$($GMP "<create_task>
       <name>lab-scan-56.20</name>
       <config  id=\"$CONFIG_ID\"/>
       <target  id=\"$TARGET_ID\"/>
       <scanner id=\"$SCANNER_ID\"/>
     </create_task>" | xmlstarlet sel -t -v '//create_task_response/@id')

   REPORT_ID=$($GMP "<start_task task_id=\"$TASK_ID\"/>" \
       | xmlstarlet sel -t -v '//start_task_response/report_id')
   echo "task=$TASK_ID report=$REPORT_ID"
   ```

6. Sondee hasta la finalización: el escaneo tardará entre 10 y 40 minutos:

   ```bash
   while :; do
     read -r status progress < <($GMP "<get_tasks task_id=\"$TASK_ID\"/>" \
       | xmlstarlet sel -t -v '//task/status' -o ' ' -v '//task/progress' -n)
     printf '\r%-12s %3s%%' "$status" "$progress"
     [ "$status" = "Done" ] && { echo; break; }
     [ "$status" = "Stopped" ] && { echo " — scan stopped"; break; }
     sleep 20
   done
   ```

   Esperado:

   ```
   Requested      0%
   Running       47%
   Done         100%
   ```

7. Extraiga los resultados: primero como resumen y luego completos:

   ```bash
   $GMP "<get_reports report_id=\"$REPORT_ID\" details=\"0\"/>" \
     | xmlstarlet sel -t -m '//report/result_count' \
         -o 'total='   -v 'full' -o ' hole='  -v 'hole' \
         -o ' warning=' -v 'warning' -o ' info=' -v 'info' -n

   $GMP "<get_results filter=\"task_id=$TASK_ID rows=100 sort-reverse=severity\"/>" \
     | xmlstarlet sel -t -m '//result' \
         -v 'severity' -o '  ' -v 'host' -o ':' -v 'port' -o '  ' -v 'name' -n \
     | head -20
   ```

   Esperado (abreviado):

   ```
   10.0  192.168.56.20:21/tcp   vsftpd Compromised Source Packages Backdoor Vulnerability
   7.5   192.168.56.20:80/tcp   nginx Multiple Vulnerabilities
   5.0   192.168.56.20:22/tcp   Weak Key Exchange (KEX) Algorithm(s) Supported (SSH)
   0.0   192.168.56.20:general  Traceroute
   ```

8. Exporte un informe en un formato portátil, usando un ID que consultó en lugar de adivinar:

   ```bash
   FMT_ID=$($GMP "<get_report_formats/>" \
     | xmlstarlet sel -t -m '//report_format[name="CSV Results"]' -v '@id' -n | head -1)
   $GMP "<get_reports report_id=\"$REPORT_ID\" format_id=\"$FMT_ID\" details=\"1\"/>" \
     | xmlstarlet sel -t -v '//report/text' | base64 -d > /root/lab-report.csv
   head -3 /root/lab-report.csv
   ```

9. Cree un objetivo con credenciales (autenticado) y observe la diferencia en el número de resultados:

   ```bash
   CRED_ID=$($GMP "<create_credential>
       <name>lab-ssh</name><type>usk</type>
       <login>scanuser</login>
       <key><private>$(sed 's/$/\\n/' /root/.ssh/id_ed25519 | tr -d '\n')</private></key>
     </create_credential>" | xmlstarlet sel -t -v '//create_credential_response/@id')
   # then reference it with <ssh_credential id="..."  port="22"/> inside <create_target>
   ```

**Verificación de comprensión — bloque 11**

- **Q11.1** — ¿Por qué `<start_task>` devuelve un `report_id` en lugar de resultados? ¿Qué le dice eso sobre el modelo de ejecución de GMP?
- **Q11.2** — Un escaneo con credenciales del mismo host devuelve 6 veces más hallazgos que el no autenticado. Explique el mecanismo y nombre el incremento de riesgo correspondiente que ha aceptado.
- **Q11.3** — ¿Qué es el **QoD** (Quality of Detection), cuál es el umbral de filtro por defecto, y por qué elevarlo a 100 oculta vulnerabilidades reales?
- **Q11.4** — Compare `Full and fast` con `Full and very deep ultimate`. Nombre la propiedad específica de los NVT que difiere y el peligro operativo del segundo.
- **Q11.5** — ¿Por qué fijar `daba56c8-73ec-11df-a475-002264764cea` en un script de automatización de producción es un defecto, aunque el UUID sea estable en la mayoría de las instalaciones?
- **Q11.6** — `<alive_tests>` está fijado en `ICMP, TCP-ACK Service & ARP Ping`. ¿Qué le ocurre a su escaneo si el segmento objetivo descarta ICMP y usted deja el valor por defecto, y cómo demuestra que eso es lo que pasó?

---

## Ejercicio 12 — NASL: leer, analizar, escribir y desplegar un NVT propio

**Pasos**

1. Localice el intérprete NASL del escáner y el árbol de plugins:

   ```bash
   which openvas-nasl openvas-nasl-lint 2>/dev/null
   ls /var/lib/openvas/plugins | head
   ls /var/lib/openvas/plugins/*.inc | head
   ```

2. Lea un NVT real e identifique la estructura de dos fases que tiene todo script NASL:

   ```bash
   grep -l 'ACT_GATHER_INFO' /var/lib/openvas/plugins/gb_*.nasl | head -1 | xargs sed -n '1,60p'
   ```

   Todo NVT se ejecuta dos veces: una con la variable `description` fijada (para registrar los metadatos: esto es lo que lee la indexación del feed) y otra de verdad.

3. Ejecute un NVT existente solo en modo descripción, para ver la salida de registro:

   ```bash
   openvas-nasl -X -B -i /var/lib/openvas/plugins \
     /var/lib/openvas/plugins/gb_nginx_detect.nasl 2>&1 | head -20
   ```

4. Escriba su propio NVT:

   ```bash
   mkdir -p /root/lab-nvt
   cat >/root/lab-nvt/lab_banner_check.nasl <<'EOF'
   # Lab NVT: flag any HTTP server that advertises its exact version in the
   # Server: header. Original work for LPIC-3 303 exercise 334.2.

   if (description)
   {
     script_oid("1.3.6.1.4.1.25623.1.0.999001");
     script_version("2026-08-25T00:00:00+0000");
     script_tag(name:"creation_date",     value:"2026-08-25 00:00:00 +0000 (Tue, 25 Aug 2026)");
     script_tag(name:"last_modification", value:"2026-08-25 00:00:00 +0000 (Tue, 25 Aug 2026)");
     script_name("Lab: HTTP Server Header Discloses Exact Version");
     script_category(ACT_GATHER_INFO);
     script_family("General");
     script_copyright("Copyright (C) 2026 Lab 303 - original work");
     script_dependencies("find_service.nasl", "http_version.nasl");
     script_require_ports("Services/www", 80);

     script_tag(name:"summary",  value:"The remote HTTP server discloses its exact
   product version in the Server response header.");
     script_tag(name:"solution", value:"Suppress or genericise the Server header
   (nginx: server_tokens off; Apache: ServerTokens Prod).");
     script_tag(name:"solution_type", value:"Mitigation");
     script_tag(name:"qod_type", value:"remote_banner");
     script_tag(name:"cvss_base", value:"2.6");
     script_tag(name:"severity_vector",
       value:"CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:L/I:N/A:N");

     exit(0);
   }

   include("http_func.inc");
   include("http_keepalive.inc");

   port   = get_http_port(default:80);
   banner = get_http_banner(port:port);

   if (!banner)
     exit(0);

   server = egrep(pattern:"^Server:", string:banner, icase:TRUE);
   if (!server)
     exit(99);

   server = chomp(server);

   # A version is disclosed only if the header contains digits and a dot
   if (eregmatch(pattern:"[0-9]+\.[0-9]+", string:server))
   {
     report = "The remote HTTP server returned the following header:\n\n" + server + "\n";
     log_message(port:port, data:report);
     exit(0);
   }

   exit(99);
   EOF
   ```

5. Analícelo con el linter antes de ejecutarlo contra un host:

   ```bash
   openvas-nasl -L /root/lab-nvt/lab_banner_check.nasl
   ```

   Esperado en caso de éxito: ninguna salida (o `lint: OK`); un error de sintaxis imprime el archivo, la línea y el token infractor.

6. Ejecútelo en modo descripción y luego contra el objetivo en vivo:

   ```bash
   openvas-nasl -X -B -i /var/lib/openvas/plugins /root/lab-nvt/lab_banner_check.nasl
   openvas-nasl -X -d -i /var/lib/openvas/plugins \
                -t 192.168.56.20 /root/lab-nvt/lab_banner_check.nasl
   ```

   Esperado (abreviado):

   ```
   ** Lab: HTTP Server Header Discloses Exact Version **
   The remote HTTP server returned the following header:

   Server: nginx/1.22.1
   ```

7. Demuestre el caso negativo. En `target`:

   ```bash
   # /etc/nginx/nginx.conf, inside http { }
   server_tokens off;
   ```

   ```bash
   systemctl reload nginx
   curl -sI http://192.168.56.20/ | grep -i '^server'
   ```

   Esperado: `Server: nginx`. Vuelva a ejecutar el NVT y confirme que ahora sale con 99 y sin hallazgo.

8. Despliegue el NVT en el escáner y reconstruya la caché de VT:

   ```bash
   install -o _gvm -g _gvm -m 0644 /root/lab-nvt/lab_banner_check.nasl /var/lib/openvas/plugins/
   runuser -u _gvm -- openvas --update-vt-info
   systemctl restart ospd-openvas
   $GMP "<get_nvts nvt_oid='1.3.6.1.4.1.25623.1.0.999001'/>" | xmlstarlet sel -t -v '//nvt/name' -n
   ```

9. **Advertencia de producción: haga esto antes de su próxima sincronización de feed.** El feed de NVT se entrega por `rsync` con borrado habilitado: un script propio que viva en `/var/lib/openvas/plugins/` no está en el manifiesto del feed y puede ser eliminado por el siguiente `greenbone-feed-sync --type nvt`. Mantenga la copia maestra fuera del árbol y vuelva a desplegarla desde un script:

   ```bash
   cat >/usr/local/sbin/deploy-lab-nvts.sh <<'EOF'
   #!/bin/sh
   set -eu
   SRC=/opt/lab-nvts
   DST=/var/lib/openvas/plugins
   for f in "$SRC"/*.nasl; do
       openvas-nasl -L "$f" || { echo "lint failed: $f" >&2; exit 1; }
       install -o _gvm -g _gvm -m 0644 "$f" "$DST/"
   done
   runuser -u _gvm -- openvas --update-vt-info
   EOF
   chmod +x /usr/local/sbin/deploy-lab-nvts.sh
   mkdir -p /opt/lab-nvts && cp /root/lab-nvt/*.nasl /opt/lab-nvts/
   ```

**Verificación de comprensión — bloque 12**

- **Q12.1** — Explique el bloque `if (description) { … exit(0); }`. ¿Qué llama al script con `description` fijada, y qué ocurriría si olvidara el `exit(0)`?
- **Q12.2** — El script termina con `exit(99)` en una rama y `exit(0)` en otra. ¿Cuál es la diferencia semántica para el escáner?
- **Q12.3** — ¿Qué garantiza `script_dependencies("find_service.nasl")`, y qué devolvería `get_http_port()` sin ello?
- **Q12.4** — ¿Por qué se exige que `script_oid` esté en el arco `1.3.6.1.4.1.25623.1.0.`, y qué colisiona si reutiliza un OID existente?
- **Q12.5** — Su NVT usa `qod_type: remote_banner`. ¿A qué porcentaje de QoD corresponde, y por qué una comprobación basada en `package` puntuaría más alto?
- **Q12.6** — Nombre dos categorías de script NASL (`ACT_*`) que nunca deben ejecutarse en un escaneo con `safe_checks`, y diga por qué.
- **Q12.7** — ¿Cuál es el riesgo específico de `-X` (`--no-signature-check`), y cuándo es aun así correcto usarlo?

---

## Ejercicio 13 — Cerrar el círculo: observar el escáner desde el sensor

Un escaneo de vulnerabilidades es, desde el punto de vista del cable, un ataque sostenido. Este ejercicio demuestra que su NIDS puede ver su propio instrumental, y por tanto el de un atacante.

**Pasos**

1. Habilite la detección de escaneos en Snort 3 (`snort.lua`) y confirme el preprocesador equivalente de Snort 2:

   ```lua
   port_scan =
   {
       protos      = 'all',
       scan_types  = 'all',
       watch_ip    = '192.168.56.0/24',
       tcp_window  = 0,
       tcp_ports   = { scans = 5, rejects = 5, nets = 25, ports = 25 },
   }
   ```

   ```bash
   grep -n 'sfportscan' /etc/snort/snort.conf
   ```

   Esperado (Snort 2):

   ```
   preprocessor sfportscan: proto  { all } memcap { 10000000 } sense_level { low }
   ```

2. Arranque el sensor alertando simultáneamente a consola y a JSON:

   ```bash
   /usr/local/bin/snort -c /usr/local/etc/snort/snort.lua \
     -R /usr/local/etc/snort/rules/local.rules \
     -i eth1 -A alert_fast -l /var/log/snort --warn-all
   ```

3. Desde `scanner`, ejecute de nuevo la tarea de GVM del ejercicio 11 (`<start_task task_id="$TASK_ID"/>`), o bien, para un equivalente rápido:

   ```bash
   nmap -sS -sV -p- --min-rate 2000 192.168.56.20
   ```

4. Observe el sensor. Debería ver eventos integrados del GID 122 (`port_scan`) más las reglas de contenido que disparen las cargas útiles de sondeo del escáner:

   ```
   08/25-17:12:04.221190 [**] [122:1:1] (portscan) TCP Portscan [**] [Priority: 3] {TCP} 192.168.56.30 -> 192.168.56.20
   08/25-17:12:19.774081 [**] [122:5:1] (portscan) TCP Filtered Portsweep [**] [Priority: 3] {TCP} 192.168.56.30 -> 192.168.56.0
   08/25-17:14:02.008112 [**] [1:1000002:1] LOCAL HTTP path traversal attempt [**] [Priority: 1] {TCP} 192.168.56.30:52288 -> 192.168.56.20:80
   ```

5. Cuantifique el ruido que produce un solo escaneo, y retenga ese número:

   ```bash
   wc -l /var/log/snort/alert_fast.txt
   awk -F'[][]' '{print $4}' /var/log/snort/alert_fast.txt | sort | uniq -c | sort -rn | head
   ```

6. Ahora haga lo que vuelve esto operativamente útil: añada una supresión de *escáner autorizado* para que la cola del SOC no quede destruida el primer martes de cada mes, manteniendo los eventos disponibles para auditoría:

   ```lua
   suppress = { { gid = 122, track = 'by_src', ip = '192.168.56.30' } }
   ```

   ```bash
   /usr/local/bin/snort -c /usr/local/etc/snort/snort.lua --warn-all -T 2>&1 | tail -3
   ```

7. Vuelva a ejecutar el paso 3 y verifique que las alertas del GID 122 desaparecieron mientras que las alertas de contenido del GID 1 permanecen.

**Verificación de comprensión — bloque 13**

- **Q13.1** — Suprimir todos los eventos del GID 122 procedentes de la IP del escáner es cómodo y peligroso. Enuncie el peligro con precisión y proponga un control que lo mitigue.
- **Q13.2** — Su NIDS vio el escaneo SYN de nmap pero produjo *cero* alertas durante la parte con credenciales del escaneo de GVM. ¿Por qué, y qué clase de monitorización cubre esa brecha? (Referencia cruzada con el objetivo 332.2.)
- **Q13.3** — El inspector `port_scan` se dispara con su servidor de copias de seguridad cada noche. Antes de escribir una supresión, ¿qué debería verificar, y cuál es el orden correcto de las tres opciones de ajuste (suppress / event_filter / edición de la regla)?
- **Q13.4** — Explique por qué un NIDS no es un control compensatorio para un host sin parchear, en términos que un comité de aprobación de cambios aceptaría.

---

## 14. Limpieza

```bash
# sensor
systemctl stop snort snort3 bandwidthd ntopng 2>/dev/null
iptables -F FORWARD
sysctl -w net.ipv4.ip_forward=0
rm -f /var/log/snort/* /tmp/*.pcap

# scanner
gvm-stop
runuser -u _gvm -- gvmd --get-tasks | head    # note IDs before deleting
```

Restaure las instantáneas de las VM que tomó en la sección 0 si desea partir de cero para el siguiente objetivo.

---

## Respuestas

<details>
<summary><strong>Haga clic para revelar todas las respuestas (Q1.1 – Q13.4)</strong></summary>

### Bloque 1 — Preparación del sensor

**Q1.1** — El modo promiscuo es una propiedad de la NIC/controlador, aplicada por debajo de la pila IP. La tarjeta deja de descartar las tramas cuya MAC de destino no es la suya y pasa todas hacia arriba; los sockets `AF_PACKET` (que usa `libpcap`) reciben tramas en la capa 2, antes de cualquier procesamiento IP. Solo hace falta una dirección IP para que la *pila IP* acepte y origine paquetes, cosa que un sensor pasivo deliberadamente no hace: sin dirección no hay superficie de ataque enrutable en la interfaz de monitorización.

**Q1.2** — GRO (Generic Receive Offload) fusiona los cinco segmentos de 1460 bytes en un único pseudosegmento grande de ~7300 bytes antes de entregarlo a `AF_PACKET`. Snort ve por tanto una disposición de paquetes que nunca existió en el cable. `depth:20` restringe la búsqueda de `content` a los primeros 20 bytes *de la carga útil del paquete*; si la cadena "attack" aparecía en el desplazamiento 5 del tercer segmento real, ahora está en el desplazamiento ~2925 del búfer fusionado y queda fuera de `depth`. Más en general, la descarga rompe toda la aritmética de offset/depth/distance/within y puede enmascarar evasiones que dependen de la segmentación.

**Q1.3** — `ip -s link` informa descartes en la capa del *controlador / búfer en anillo*. El porcentaje de Snort viene del DAQ, que cuenta los paquetes que el kernel encoló en el anillo `AF_PACKET` pero que Snort no consumió a tiempo: una pérdida del lado del espacio de usuario causada por un anillo demasiado pequeño o un motor de detección demasiado lento. Lea `/proc/net/ptype`, las estadísticas del DAQ en el resumen de salida de Snort, o `ethtool -S eth1 | grep -i drop`; para `AF_PACKET` en concreto, el contador `tp_drops` que Snort muestra en sus `Packet I/O Totals`. La solución es `--daq-var buffer_size_mb=`, más hilos de paquetes (`-z`), o menos reglas.

**Q1.4** — Un TAP es hardware pasivo: no puede sobresuscribirse, reenvía tramas erróneas/enanas/sobredimensionadas que el ASIC del switch descartaría, no compite con el reenvío de producción por los recursos del switch, y no puede ser reconfigurado por quien comprometa el plano de gestión del switch. Un puerto SPAN descarta tramas silenciosamente cuando el ancho de banda agregado espejado supera la velocidad del puerto, y las descarta *sin avisar*, de modo que su sensor informa «0 descartes» mientras pierde tráfico.

### Bloque 2 — Monitorización en tiempo real

**Q2.1** — `iftop` cuenta los bytes que captura vía `libpcap` en esa interfaz, así que mide lo que el sensor *ve* y está sujeto a descartes de captura, filtros BPF y decisiones de encapsulado de capa 2. `vnstat` lee los propios contadores de interfaz del kernel (`/sys/class/net/*/statistics/`, en última instancia los mismos contadores que expone SNMP), por lo que es exacto y barato pero no tiene detalle por flujo. Cite **`vnstat`** (o SNMP) para la planificación de capacidad: es la autoridad sobre el volumen. Use `iftop` para atribuir ese volumen a conversaciones.

**Q2.2** — (a) Una avalancha de paquetes pequeños: un SYN flood, un escaneo de puertos, o sesiones interactivas de SSH/telnet. (b) La sobrecarga normal de protocolo dominando: muchos ACK de TCP, consultas DNS, ARP o keepalives, es decir, un enlace con muchas conexiones de vida corta y poca carga útil. `iftop` los distingue: un escaneo/avalancha muestra un origen abriéndose en abanico hacia muchos destinos o puertos con tráfico de retorno casi nulo; la sobrecarga normal muestra pares bidireccionales equilibrados en muchas conversaciones establecidas.

**Q2.3** — `iftop` abre un socket raw/de paquetes para capturar tramas, lo que requiere `CAP_NET_RAW` (y `CAP_NET_ADMIN` para poner el modo promiscuo). El mínimo privilegio consiste en otorgar la capacidad al binario y no al usuario: `setcap cap_net_raw,cap_net_admin=eip /usr/sbin/iftop`, y luego restringir el permiso de ejecución a un grupo dedicado. Esto evita una regla `sudo` general que permitiría al operador usar el argumento de filtro BPF de `iftop` como punto de apoyo.

**Q2.4** — Le dice que prácticamente todo el tráfico de ese enlace es SSH o, mucho más probablemente en una interfaz de monitorización, que lo que está graficando son *sus propias sesiones de gestión y el tráfico propio del sensor*, no el tráfico que pretendía monitorizar. Es un hallazgo porque significa que su TAP/SPAN está reflejando lo equivocado (a menudo el enlace ascendente del propio sensor), de modo que toda métrica de detección posterior está midiendo la ruta de monitorización en lugar de la ruta de producción.

### Bloque 3 — Contabilidad histórica

**Q3.1** — `bandwidthd` hace captura de paquetes y contabilidad por **host/IP** dentro de una subred, así que puede decirle *qué host de la LAN* consumió el ancho de banda. Cacti sondea **contadores SNMP en un dispositivo**, así que contabiliza por **interfaz** y puede graficar cualquier cosa con un OID (CPU, temperatura, disco, contadores de error) durante años con almacenamiento mínimo, pero no puede desglosar el tráfico de una interfaz por host. Solo `bandwidthd` responde «quién»; solo Cacti responde «cuál fue el percentil 95 en el puerto WAN el trimestre pasado».

**Q3.2** — `COUNTER` asume valores monótonamente crecientes y calcula una tasa por segundo a partir del delta. En un reinicio el contador vuelve a 0, produciendo un delta *negativo*; el tipo `COUNTER` de RRDtool interpreta un descenso como un desbordamiento de un contador de 32 o 64 bits y calcula una tasa enorme, que luego supera el límite `max` (aquí `U` significa sin límite, así que no lo supera): con `U` obtiene un pico gigantesco; con un máximo razonable obtiene `UNKN` (NaN). Justamente por eso se prefiere `DERIVE` + `min:0` (que descarta los negativos como desconocidos) para contadores que pueden reiniciarse legítimamente.

**Q3.3** — Un contador `ifInOctets` de 32 bits se desborda tras 4 294 967 296 bytes, unos **34 segundos** a 1 Gbit/s. Con un intervalo de sondeo de 300 segundos el contador puede desbordarse varias veces entre sondeos, de modo que la corrección de desbordamiento de RRDtool calcula una tasa errónea (normalmente demasiado pequeña, en ocasiones absurda). La solución es sondear los contadores de alta capacidad de 64 bits `ifHCInOctets`/`ifHCOutOctets` de `IF-MIB`, lo que requiere SNMPv2c o v3: los contadores de 64 bits no existen en SNMPv1.

**Q3.4** — La vista anual se sirve desde un RRA con un factor de consolidación alto (`RRA:AVERAGE:0.5:288:797` consolida 288 puntos de datos primarios —un día— en una fila, usando la función de consolidación AVERAGE). Una ráfaga de 30 segundos ya queda promediada dentro del paso de 300 segundos, y luego se promedia de nuevo a lo largo de un día entero, así que desaparece por completo. El RRA `MAX` conserva el mayor punto de datos primario de cada intervalo de consolidación en lugar de la media, de modo que la ráfaga sobrevive como un pico visible, a costa de no decirle nada sobre su duración.

**Q3.5** — La cadena de comunidad viaja en texto claro en cada paquete SNMPv1/v2c, así que cualquiera que capture un solo paquete la tiene; la restricción por IP de origen solo es tan fuerte como su antisuplantación, y UDP se suplanta trivialmente para una operación de escritura. SNMPv3 añade un modelo de usuario real con autenticación HMAC (`authPriv` con SHA) y cifrado de la carga útil (AES), más protección contra repetición mediante engine boots/time, de modo que la credencial nunca viaja por el cable y la petición está protegida en integridad.

### Bloque 4 — Fundamentos de Snort 2.9

**Q4.1** — Efecto sobre la detección: las reglas escritas como `$EXTERNAL_NET any -> $HOME_NET …` pasarán a coincidir también con tráfico *interno a interno*, lo que saca a la luz movimiento lateral que de otro modo se perdería, pero también genera grandes volúmenes de falsos positivos a partir del tráfico interno normal de servicios. Efecto sobre el rendimiento: `EXTERNAL_NET any` elimina un rechazo temprano y extremadamente barato basado en IP, con lo que muchos más paquetes llegan a la costosa comparación de contenido; en un segmento interno ocupado esto puede duplicar o triplicar la CPU. La respuesta habitual en producción es mantener `!$HOME_NET` para el conjunto de reglas importado y escribir aparte un conjunto pequeño y dirigido de reglas de interno a interno.

**Q4.2** — Tres clases que `-T` no puede detectar: (1) **permisos/entorno de ejecución**: la unidad corre como un usuario sin privilegios que no puede abrir la interfaz, escribir en `/var/log/snort` o crear el archivo PID; (2) **estado de la interfaz en el arranque**: `eth1` todavía no existe, está caída, o la unidad de systemd compite con el objetivo de red; (3) **límites de recursos**: la configuración valida pero el proceso es eliminado por OOM o alcanza un `ulimit`/`memcap` bajo carga real, y las opciones a nivel de unidad (`-D`, `-u`, `-g`, `--daq`, rutas de PID) suministradas por el archivo de unidad en lugar de por su línea de comandos de `-T` sencillamente no se ejercitan en la prueba.

**Q4.3** — `[122:1:0]` es `[GID:SID:REV]`: **ID de generador** 122 (el preprocesador `sfportscan`/`port_scan`, no el motor de reglas), **ID de firma** 1, **revisión** 0. GID 1 significa «el motor de reglas de texto»; los GID por encima de 100 identifican preprocesadores/inspectores y eventos del decodificador, cuyas reglas están compiladas. La revisión es 0 porque los eventos integrados de los preprocesadores no llevan texto de regla que revisar; una regla escrita por usted lleva `rev:1;` y se incrementa cada vez que la cambia, para que los sistemas aguas abajo puedan saber qué versión produjo una alerta.

**Q4.4** — (1) **Detección dependiente del tiempo**: `detection_filter`, `event_filter`, los tiempos de espera de stream y la expiración de flujos se comportan de forma distinta cuando se reproduce una captura entera en segundos en lugar de a lo largo del intervalo real: una regla de tasa que nunca se dispararía en vivo puede dispararse en la reproducción, y viceversa. (2) **Comportamiento exclusivo del modo en línea**: los veredictos `drop`/`reject`, la inyección de paquetes, el bloqueo de sesiones, y las características de latencia y profundidad de cola del DAQ en línea NFQ/AFPacket sencillamente no existen en modo `-r`; tampoco la pérdida de paquetes, el reensamblado de fragmentos bajo presión de memoria o el enrutamiento asimétrico.

**Q4.5** — Cuando un paquete es recibido por el DAQ pero excluido de la detección antes del análisis: un filtro BPF aplicado con `-F`/línea de comandos (aparece como `Filtered`), paquetes descartados por el decodificador por estar malformados, paquetes de un flujo marcado como «ignore»/lista blanca de `stream` por un preprocesador o por una regla `pass` con vía rápida basada en flujo y —en modo en línea— paquetes en lista blanca del DAQ. Además, los paquetes aún encolados al salir aparecen como `Outstanding`.

### Bloque 5 — Reglas

**Q5.1** — `content:"GET"; http_method;` restringe la búsqueda al **búfer del método HTTP** que `http_inspect` ya ha extraído y normalizado. El motor de detección compara tres bytes contra un búfer diminuto ya analizado, y la regla solo se evalúa para paquetes que `http_inspect` ha identificado como peticiones HTTP. `content:"GET /"; depth:5;` busca en la **carga útil en bruto** de cada paquete TCP en esos puertos, participa en la selección de patrón rápido como patrón en bruto, y además coincidirá con "GET /" apareciendo dentro del cuerpo de un POST, de una transferencia de archivos o de una respuesta HTTP: es a la vez más lenta y menos precisa.

**Q5.2** — `detection_filter` es una compuerta **previa a la detección**: la regla solo *genera un evento* después de alcanzar el umbral, y se evalúa como parte de la coincidencia de la regla, de modo que las primeras N-1 coincidencias no producen evento alguno. `event_filter type limit` es **posterior a la detección**: la regla coincidió cada vez, el evento se generó, y el filtro decide cuántos de esos eventos se *registran*. La distinción importa para todo lo que cuente coincidencias aguas abajo (y para `flowbits`, que igualmente son fijados por una regla cuyo evento un filtro suprimió).

**Q5.3** — Sin `flowbits:noalert`, la regla 1000004 lanza una alerta en **cada** comando `USER` de FTP, es decir, en cada inicio de sesión normal, convirtiendo una precondición con estado en un generador permanente de falsos positivos. Sin `flowbits:set,lab.ftp_user`, el `flowbits:isset,lab.ftp_user` de la segunda regla nunca se cumple, así que la regla de `SITE EXEC` nunca se dispara: ha desactivado silenciosamente la detección que realmente le importa.

**Q5.4** — Snort se niega a cargar SID duplicados dentro del mismo GID y aborta el análisis de la configuración con un error del tipo `Duplicate rule SID 1000002`: el sensor no arranca, lo cual es un fallo que sí se nota, pero en un conjunto de reglas gestionado grande es una interrupción innecesaria. Las reglas locales deben usar SID **≥ 1 000 000**; del 100 al 999 999 están reservados para los conjuntos de reglas distribuidos/del proveedor, y del 1 al 99 para uso reservado/heredado.

**Q5.5** — Snort 2: `content:"admin"; http_server_body;`: el modificador `http_server_body` restringe el `content` precedente al búfer normalizado del cuerpo de respuesta extraído por `http_inspect`. Snort 3: la forma de búfer adhesivo, `http_server_body; content:"admin";`: el selector de búfer precede a las opciones de contenido que gobierna, y sigue vigente para todas las opciones de contenido posteriores hasta que se seleccione otro búfer.

**Q5.6** — Precisión: restringe la coincidencia a paquetes que van de cliente a servidor dentro de una sesión TCP que el preprocesador `stream` ha visto plenamente establecida (saludo de tres vías completado), lo que elimina coincidencias en paquetes sueltos o suplantados, en la respuesta del servidor que hace eco de la cadena de ataque, y en sondas de escáner que nunca completan un saludo. CPU: el estado del flujo se comprueba muy temprano y de forma muy barata, de modo que la gran mayoría de los paquetes se rechaza antes de cualquier comparación de patrones, y la regla queda excluida del grupo de patrón rápido evaluado para el tráfico de servidor a cliente.

### Bloque 6 — Snort 3

**Q6.1** — La capa DAQ (Data AcQuisition) abstrae la captura de paquetes *y* los veredictos de paquetes tras una única API, de modo que el mismo binario de Snort puede correr pasivamente sobre `libpcap`, a alta velocidad sobre `AF_PACKET` con fanout del kernel, en línea sobre netfilter, o sobre una tarjeta acelerada por hardware, sin recompilar el motor de detección y con una forma uniforme de devolver veredictos `pass`/`block`/`replace`, cosa que `libpcap` en bruto no puede expresar en absoluto. Dos módulos: **`afpacket`** — despliegue pasivo de alto rendimiento o en línea sobre un par de interfaces; **`nfq`** — IPS verdaderamente en línea detrás de un objetivo NFQUEUE de `iptables`/`nftables` en una ruta de reenvío de Linux.

**Q6.2** — Con el fanout de `afpacket`, el kernel aplica un *hash sobre la tupla del flujo* para elegir a qué anillo (y por tanto a qué hilo de paquetes de Snort) se entrega cada paquete. Cada paquete de una conexión TCP dada —en ambas direcciones, cuando se usa un hash simétrico— cae en el mismo hilo, de modo que ese hilo posee el flujo completo y puede reensamblarlo. Cuatro procesos independientes abriendo cada uno su propia captura recibirían cada uno *una copia de cada paquete*, cuadruplicando el trabajo, o (con grupos de fanout independientes) repartirían los flujos arbitrariamente de modo que ninguna instancia poseyera nunca un flujo completo, destruyendo el reensamblado, el estado de `flowbits` y el seguimiento de tasas.

**Q6.3** — Snort 3: `http_client_body; content:"admin", nocase;`. El orden cambió porque Snort 3 sustituyó los *modificadores de contenido* finales por **búferes adhesivos** iniciales: el nombre del búfer es una opción que fija el búfer de inspección actual, y cada `content`/`pcre`/`byte_test` posterior se aplica a ese búfer hasta que se seleccione otro distinto. Esto hace que la regla se lea en orden de evaluación y elimina la ambigüedad de Snort 2 en la que un modificador parecía adherirse al `content` equivocado.

**Q6.4** — `-k none` desactiva la verificación de sumas de comprobación para todos los protocolos. Omitirlo hace que Snort *excluya del análisis* cualquier paquete cuya suma de comprobación IP/TCP/UDP sea inválida, y las sumas son rutinariamente inválidas en dos situaciones normales: cuando la captura se toma en un host con **descarga de checksum** (la NIC calcula la suma después del punto de captura, así que los paquetes salientes capturados llevan un marcador de relleno), y al leer un pcap que fue reescrito o anonimizado. El resultado es una regla que nunca se dispara con su propio tráfico saliente pese a parecer perfectamente correcta.

**Q6.5** — Son **reglas integradas** emitidas por los codecs, el módulo `stream` y los inspectores (`port_scan` = GID 122, eventos del decodificador = GID 116, `http_inspect` = GID 119/120, etc.). Están compiladas dentro del correspondiente plugin en C++ en lugar de analizarse desde texto de regla, así que no hay cuerpo de regla que editar; se controlan mediante la configuración Lua del módulo (`enable_builtin_rules`, opciones de alerta por inspector) y mediante `suppress`/`event_filter`, no reescribiendo la regla. `--dump-builtin-rules` existe para que pueda generar texto de regla de referencia para el mapeo SID→mensaje y para habilitarlas selectivamente en `ips.states`.

### Bloque 7 — Gestión de reglas

**Q7.1** — `disablesid` es *declarativo e idempotente*: vive en la configuración bajo control de versiones, se reaplica automáticamente tras cada actualización, documenta la decisión (con un comentario) en un único lugar auditable, y sobrevive a que el proveedor vuelva a añadir o renumerar la regla. Borrar la línea es una edición manual sobre contenido generado: la deshace silenciosamente la siguiente actualización, es invisible para quien revise la configuración, y no deja constancia de quién desactivó qué ni por qué. El mismo argumento vale para `enablesid` y `modifysid`.

**Q7.2** — Una política IPS es una selección curada por el proveedor de qué reglas están habilitadas, ordenada por agresividad: `connectivity` (solo reglas de altísima confianza y bajo impacto: nunca romper el tráfico), `balanced` (el compromiso por defecto), `security` (más estricta, acepta más falsos positivos), `max-detect` (investigación/laboratorio; habilita casi todo). Pasar de `balanced` a `security` habilita varios miles de reglas adicionales: los falsos positivos suben materialmente, y la CPU sube tanto por las reglas extra como por el mayor estado del comparador de patrón rápido; en un sensor saturado esto se convierte en descartes de paquetes, lo que *reduce* la detección real. Cámbielo, y luego mida la tasa de descartes y el volumen de alertas antes y después.

**Q7.3** — Evita que una descarga de reglas rota o truncada se cargue en el sensor en ejecución. Si `pulledpork.py` falla (error de red, oinkcode caducado, archivo corrupto), el `snort -T` nunca se ejecuta; si `snort -T` falla (una regla malformada en el nuevo conjunto), el `systemctl reload` nunca se ejecuta, de modo que el sensor conserva su último conjunto de reglas correcto conocido y sigue inspeccionando. Sin el encadenamiento puede recargar Snort con un conjunto de reglas no analizable y —especialmente en línea— dejar caído el sensor, y posiblemente la ruta del tráfico, a las 03:30.

**Q7.4** — Las reglas SO («shared object») son lógica de detección distribuida como **bibliotecas compartidas de C compiladas** en lugar de texto de regla, usadas para detecciones que el lenguaje de reglas no puede expresar (máquinas de estados de protocolo complejas, decodificadores propios). Necesitan `sorule_path` porque Snort las carga con `dlopen()` desde un directorio dedicado, y necesitan una `snort_version` coincidente porque están compiladas contra una ABI concreta de Snort: un binario que no cuadre o no carga o hace caer el proceso. El riesgo de cadena de suministro es que está cargando código nativo opaco en el espacio de direcciones de un proceso con privilegios de root situado en la ruta del tráfico: no puede revisarlo, así que su integridad descansa enteramente en el transporte (HTTPS + oinkcode) y en confiar en el proveedor.

**Q7.5** — `oinkmaster`: la directiva que falta es **`skipfile local.rules`**, que le indica a `oinkmaster` que nunca toque ese archivo al sincronizar el directorio de salida. PulledPork 3: el ajuste que falta es **`local_rules = /path/to/local.rules`**, que le indica a PulledPork que lea sus reglas y las fusione en el archivo de salida generado en lugar de producir un archivo que las reemplace. En ambos casos la lección de fondo es la misma: la herramienta es dueña de su directorio de salida, así que todo lo que escriba a mano debe declararse.

### Bloque 8 — Salida y triaje

**Q8.1** — `-A full` escribe una alerta multilínea con formato para humanos *incluyendo el bloque de cabeceras decodificadas del paquete* para cada evento, de forma síncrona, desde la ruta de procesamiento de paquetes. En un sensor ocupado el primer recurso agotado es el **ancho de banda de E/S de disco / la latencia de escritura**: la escritura bloqueante detiene el hilo de detección, el anillo del DAQ se llena, y Snort empieza a descartar paquetes, de modo que cuantos más ataques ve, menos ve. El espacio en disco se agota poco después. Use `unified2` (binario, compacto, con consumidor asíncrono) o `alert_fast`/`alert_json` con `limit` fijado.

**Q8.2** — El consumidor debe leer **`sid-msg.map`** (SID → texto del mensaje, referencias y clasificación) y **`gen-msg.map`** (GID:SID → mensaje para eventos de preprocesador/integrados); `classification.config` aporta los nombres de classtype→prioridad. Si están desactualizados respecto al conjunto de reglas en ejecución, las reglas nuevas se representan como "Snort Alert [1:2054112:1]" sin descripción y —peor aún— un SID reutilizado o renumerado se representa con la descripción *equivocada*, de modo que un analista tría lo que no es. Regenerar los mapas debe formar parte del mismo paso de automatización que la actualización de reglas.

**Q8.3** — `limit 128` es un tope de tamaño en **megabytes** por archivo de salida. Cuando el `snort.u2.<timestamp>` actual alcanza 128 MB, Snort lo cierra y abre uno nuevo con un sufijo de marca de tiempo fresco; no borra nada y no deja de registrar. Existe para que el consumidor aguas abajo (`barnyard2` o un agente SIEM) pueda procesar y rotar archivos completados, y para que un único archivo nunca crezca más allá de lo que el instrumental y los sistemas de archivos manejan con comodidad.

**Q8.4** — Ventaja: las alertas salen del sensor inmediatamente y aterrizan en un host de registro separado y endurecido, así que un atacante que comprometa el sensor no puede borrar retroactivamente la evidencia de cómo entró; y obtiene agregación y retención centralizadas gratis. Desventaja: el syslog clásico sobre UDP/514 no está autenticado, ni cifrado, y es propenso a pérdidas: descarta mensajes silenciosamente bajo carga justo cuando un incidente genera más alertas, y anuncia a quien esté en la ruta que existe un sensor y qué detectó. Mitíguelo con `rsyslog`/`syslog-ng` sobre TLS con una cola asistida por disco.

**Q8.5** — (1) **Formato de entrada equivocado**: `snort-stat` analiza líneas de alerta con formato syslog, así que apuntarlo a un archivo producido por `-A fast`, `-A full` o `unified2` no arroja registros analizables: debe ejecutar Snort con `-A syslog` (o alimentarlo con el archivo de syslog). (2) **Nada que leer**: no se generaron alertas, el archivo está vacío o rotado, o no tiene permiso para leer `/var/log/syslog`; en sistemas con `systemd-journald` y sin `rsyslog`, `/var/log/syslog` puede no existir en absoluto y necesita `journalctl -t snort | snort-stat`.

### Bloque 9 — IPS en línea

**Q9.1** — Un **IDS** está *fuera* de la ruta del paquete: recibe una copia del tráfico (TAP/SPAN) y su veredicto no influye en si el paquete se entrega; para cuando decide, el paquete ya ha llegado. Un **IPS** está *sobre* la ruta del paquete: el paquete se retiene en la ruta de reenvío (NFQUEUE, puente, hardware) hasta que el motor devuelve un veredicto, de modo que un `drop` impide la entrega. Un sensor en puerto SPAN nunca puede impedir la entrega porque solo llega a tener una copia; el original fue reenviado por el ASIC del switch en el momento en que se reflejó. (Los reinicios TCP inyectados por un IDS son una carrera, no prevención.)

**Q9.2** — Con `--queue-bypass` (**fallo abierto**): si Snort muere, el tráfico fluye sin inspección; preserva la disponibilidad y pierde la seguridad. Sin él (**fallo cerrado**): si Snort muere, todo el tráfico coincidente se envía a un agujero negro; preserva la seguridad y pierde la disponibilidad. (a) Segmento de tarjetas de pago: **fallo cerrado**: un CDE que reenvía tráfico sin inspeccionar está fuera de cumplimiento, y el coste de una interrupción es menor que el de una brecha no detectada. (b) Red clínica hospitalaria: **fallo abierto**: una red en agujero negro puede impedir el acceso a historiales de pacientes o interrumpir la telemetría de dispositivos, y la seguridad del paciente prevalece sobre el beneficio marginal de seguridad; compense con monitorización y alertado estrictos sobre el propio proceso del IPS.

**Q9.3** — (1) Reducir el conjunto de reglas: una `ips_policy` más pequeña o de nivel inferior, o estados de regla dirigidos; sacrifica la detección de las firmas eliminadas. (2) Reducir el reensamblado de flujos y la profundidad de inspección: bajar los búferes de reensamblado de `stream_tcp`, reducir la normalización y la profundidad de cuerpo de `http_inspect`, o excluir flujos grandes con reglas `stream.ignore`/`pass` para tráfico masivo conocido; sacrifica la detección de todo lo que solo aparece en carga útil reensamblada o profunda. (Añadir hilos de paquetes con `-z` y aumentar el búfer del DAQ ayudan al rendimiento y al jitter, pero no reducen la latencia por paquete.)

**Q9.4** — En modo pasivo no hay forma de imponer un `drop`, así que Snort trata la regla como una alerta: el evento se genera y se registra, y la acción mostrada es `allow`. Para que sea explícito en lugar de supuesto, ejecute con `--warn-all`, que informa de las reglas cuya acción no puede honrarse en el modo actual, y lea el bloque `Action Stats` al salir: `Blocked`/`Dropped` serán 0 sin importar cuántas reglas `drop` coincidieron. Snort 3 también informa del modo de ejecución al arrancar (con `-Q` o sin él), lo que debería comprobar en sus verificaciones de despliegue.

**Q9.5** — En línea, el motor retiene paquetes mientras reensambla, así que la memoria de reensamblado (`memcap`) y el dimensionado de la tabla de flujos determinan directamente el almacenamiento intermedio y la latencia, y agotarlos fuerza una decisión de política: o liberar tráfico sin inspeccionar (fallo de seguridad) o retenerlo/descartarlo (fallo de disponibilidad). Bajo ataque —fragmentación deliberada, cantidades enormes de flujos semiabiertos, o enrutamiento asimétrico que impide que los flujos lleguen a completarse— el subsistema de reensamblado se convierte en el recurso que un adversario ataca para cegar o degradar la red. De forma pasiva, la misma configuración errónea solo degrada la calidad de la detección.

### Bloque 10 — Arquitectura de GVM

**Q10.1** — Navegador → **HTTPS** hacia **`gsad`** (:9392). `gsad` traduce la petición a XML de **GMP** y lo escribe sobre el socket UNIX `/run/gvmd/gvmd.sock` hacia **`gvmd`**. `gvmd` autentica al usuario, persiste el objetivo/tarea/configuración en **PostgreSQL**, y despacha el escaneo por **OSP** en `/run/ospd/ospd-openvas.sock` hacia **`ospd-openvas`**. `ospd-openvas` escribe las preferencias del escaneo y la base de conocimiento del objetivo en **Redis** y bifurca el escáner **`openvas`**, que ejecuta **NVT** en NASL; esos NVT abren conexiones TCP/UDP reales contra el objetivo, y *ese* es el paquete en el cable. Los resultados vuelven por Redis → `ospd-openvas` → OSP → `gvmd` → PostgreSQL, y `gsad` los representa. `notus-scanner` recibe listas de paquetes por **MQTT** (`mosquitto`) y devuelve coincidencias por la misma ruta.

**Q10.2** — `notus-scanner` realiza una correspondencia de vulnerabilidades puramente *local*: dada una lista de paquetes y versiones instaladas obtenida por un escaneo autenticado (con credenciales), la compara con la base de datos de avisos de Notus e informa de cada paquete vulnerable conocido, sin sondeo de red alguno. Es enormemente más rápido y más completo que los NVT basados en banners, pero **no aporta nada si el escaneo no tiene credenciales**, porque sin credenciales SSH/SMB/SNMP no hay lista de paquetes que comparar.

**Q10.3** — Redis es la **base de conocimiento**: el almacén por host donde el escáner registra todo lo que aprende (puertos abiertos, servicios detectados, banners, resultados de credenciales, salidas de NVT) para que cientos de scripts NASL que corren en paralelo puedan compartir hallazgos: `find_service.nasl` escribe `Services/www`, y cada NVT dependiente lo lee. Reiniciar `redis-server@openvas` destruye ese estado: los escaneos en curso pierden su base de conocimiento y fallan o producen resultados gravemente incompletos, y `ospd-openvas` normalmente da error. Nunca reinicie Redis mientras haya escaneos en curso.

**Q10.4** — (1) La sincronización tuvo éxito pero no se le ha comunicado al escáner: la caché de metadatos de VT en Redis no se reconstruyó; ejecute `runuser -u _gvm -- openvas --update-vt-info` y reinicie `ospd-openvas`. (2) **Propiedad/permisos**: la sincronización corrió como `root` (u otro usuario) y los archivos bajo `/var/lib/openvas/plugins/` no son legibles por `_gvm`, así que el escáner ve una colección vacía. Una tercera causa común es una discordancia de rutas: la sincronización escribió en un `plugins_folder` distinto del configurado en `/etc/openvas/openvas.conf`.

**Q10.5** — El **feed NVT** contiene la lógica de detección ejecutable: scripts NASL que sondean un host y deciden «este host está afectado». El **feed SCAP** contiene los datos de referencia: diccionarios de productos CPE, registros CVE con sus vectores y puntuaciones CVSS, y definiciones OVAL. Es decir: SCAP le dice la **gravedad y descripción** de un CVE; los NVT le dicen que **el host está afectado**. Un GVM con un feed NVT actual y un feed SCAP desactualizado detectará vulnerabilidades pero informará de metadatos CVE ausentes o desfasados para ellas.

**Q10.6** — Cada objeto en `gvmd` (objetivos, tareas, informes, credenciales, filtros, planificaciones) tiene un propietario. Eliminar un usuario sin especificar quién hereda sus objetos los dejaría huérfanos —haciendo inaccesibles e imborrables los informes históricos y las planificaciones activas— o destruiría evidencia de auditoría. `--inheritor` transfiere la propiedad de forma atómica para que el historial de escaneos y la configuración sobrevivan a los cambios de personal, que es exactamente lo que preguntará un auditor.

### Bloque 11 — Ciclo de vida de un escaneo GMP

**Q11.1** — Porque GMP es **asíncrono**: `<start_task>` solo encola el escaneo y devuelve de inmediato el identificador del informe que *será* poblado. El escaneo en sí corre durante minutos u horas en `ospd-openvas`/`openvas`, volcando resultados parciales en ese informe a medida que avanza. Se espera que el cliente sondee `<get_tasks>` en busca de `status`/`progress` (o se suscriba a una alerta) y luego recupere `<get_reports>`. Por eso toda automatización correcta de GVM tiene un bucle de sondeo y un tiempo de espera, y por eso mantener abierta una petición HTTP esperando resultados es un error de diseño.

**Q11.2** — Con credenciales el escáner inicia sesión (SSH/SMB/WMI/SNMP), enumera los paquetes instalados, la versión del kernel, los archivos de configuración y el estado del registro, y se los entrega a la comparación por versión de paquete (Notus y NVT de comprobación de seguridad local). Eso convierte miles de casos de «no se puede determinar remotamente» en hallazgos definitivos: es la diferencia entre adivinar a partir de banners y leer la base de datos de paquetes. El riesgo aceptado: ha almacenado **credenciales privilegiadas de cada host escaneado** en la base de datos del escáner, así que el escáner es ahora un objetivo de máximo valor cuyo compromiso otorga acceso a toda la flota; y un escaneo mal configurado u hostil puede bloquear cuentas, agotar recursos o escribir en los objetivos. Mitíguelo con cuentas de escaneo dedicadas de mínimo privilegio, autenticación por clave, credenciales por segmento y control de acceso estricto sobre el host de GVM.

**Q11.3** — **QoD** es la *Quality of Detection*: un valor de confianza de 0 a 100 % adjunto a cada resultado que expresa con qué fiabilidad el método de detección establece que la vulnerabilidad está realmente presente (p. ej. `exploit` 100 %, `package` 97 %, `registry` 97 %, `remote_banner` 80 %, `remote_banner_unreliable` 30 %, `general_note` 1 %). El filtro de informe por defecto muestra resultados con **QoD ≥ 70 %**. Elevarlo a 100 muestra solo los hallazgos demostrados por explotación exitosa o equivalente, lo que descarta la abrumadora mayoría de los hallazgos *verdaderos*, incluidos casi todos los resultados con credenciales basados en paquetes, y produce un informe tranquilizadoramente limpio mientras el host sigue siendo vulnerable.

**Q11.4** — La propiedad de los NVT que difiere son los **scripts de categoría `ACT_DESTRUCTIVE_ATTACK` / `ACT_DENIAL` / `ACT_KILL_HOST` y la preferencia `safe_checks`**. `Full and fast` habilita las comprobaciones seguras y se apoya en evidencia de versión/banner/registro; `Full and very deep ultimate` desactiva las comprobaciones seguras y habilita pruebas destructivas y de denegación de servicio que realmente intentan el exploit. El peligro es directo: puede tumbar servicios, corromper datos, reiniciar dispositivos y dejar hosts de producción fuera de servicio; solo tiene lugar en un laboratorio o en un entorno de preproducción con un acuerdo explícito y por escrito de que las interrupciones son aceptables.

**Q11.5** — Porque el UUID es *dato*, no API. Lo puebla el feed `gvmd-data` y puede diferir entre versiones, entre el feed comunitario y el empresarial, tras un renombrado, o si un administrador local ha clonado y modificado la configuración; una instalación nueva desde otra generación de feed puede no tenerlo en absoluto. El script entonces o falla con un opaco `Failed to find config` o —peor— vincula silenciosamente la tarea a una configuración distinta de la pretendida. Consultar `<get_configs/>` por nombre y exigir exactamente una coincidencia hace que el fallo sea ruidoso y la intención explícita.

**Q11.6** — `alive_tests` controla cómo decide GVM que un host está activo antes de escanearlo. Si el segmento descarta ICMP y ARP no está disponible (segmento enrutado) mientras sus sondas TCP-ACK dan contra puertos filtrados, GVM concluye que el host está **muerto y lo omite por completo**: obtiene una tarea completada, sin errores, y un informe vacío, que se lee exactamente igual que «no se encontraron vulnerabilidades». Demuéstrelo comprobando el conteo de hosts del informe y las entradas `Host Start`/`Host End` (`<get_reports … details="1"/>` muestra cero hosts escaneados), buscando el resumen `Hosts scanned: 0`, y reejecutando el objetivo con `<alive_tests>Consider Alive</alive_tests>`: si aparecen hallazgos, el fallo de la prueba de host activo fue la causa.

### Bloque 12 — NASL

**Q12.1** — El escáner ejecuta cada archivo NASL **dos veces**. En la primera pasada fija a TRUE la variable global `description` y ejecuta el script únicamente para cosechar metadatos —OID, nombre, categoría, familia, dependencias, puertos requeridos, etiquetas—, que es lo que puebla la caché de VT en Redis y la lista de NVT en `gvmd`. En la pasada real `description` no está fijada y la ejecución continúa hasta la lógica de detección. Omitir el `exit(0)` significaría que la pasada de descripción continuaría hacia el código de detección e intentaría sondear un host durante el registro de metadatos, produciendo errores durante `--update-vt-info` y, en escáneres antiguos, actividad de red no deseada en el momento de construir la caché.

**Q12.2** — `exit(0)` significa que el script terminó normalmente y *ha informado de lo que haya encontrado* (las llamadas a `log_message`/`security_message` ya realizadas se mantienen). `exit(99)` es el retorno convencional de «**no aplicable / nada encontrado**»: el script determinó que la condición no se aplica a este host y no produjo hallazgo alguno. La distinción se usa para diagnóstico y estadísticas: permite distinguir «el NVT corrió y no encontró nada» de «el NVT corrió y encontró algo», y en la salida de depuración hace fácil detectar un NVT inesperadamente silencioso.

**Q12.3** — Garantiza que `find_service.nasl` ya se ha ejecutado contra este host y ha poblado las entradas de la base de conocimiento (`Services/www`, `Services/ftp`, …) que describen qué servicio está en qué puerto, incluidos los servicios en puertos no estándar. Sin la dependencia, `get_http_port(default:80)` no tiene entrada de KB que consultar y recurre al valor por defecto suministrado, de modo que el NVT probaría solo el puerto 80 y perdería silenciosamente un servidor HTTP en 8080, 8443 o cualquier otro puerto, además de no poder omitir hosts en los que el puerto 80 corre algo que no es HTTP.

**Q12.4** — `1.3.6.1.4.1.25623` es el arco del **Private Enterprise Number de la IANA** de Greenbone; `1.3.6.1.4.1.25623.1.0.x` es el espacio de nombres que el escáner y el gestor usan para indexar los NVT. El OID es la clave primaria: es lo que `gvmd` almacena en los resultados, lo que referencian los filtros de informe y las anulaciones, y lo que indexa la caché de VT. Reutilizar un OID existente hace que su script colisione con un NVT del feed: según el orden de carga uno reemplaza silenciosamente al otro, los resultados se atribuyen a la prueba equivocada, y la siguiente sincronización de feed produce un estado inconsistente. Para trabajo local, elija un subrango claramente fuera del feed y documéntelo; para cualquier cosa publicada, obtenga su propio arco PEN.

**Q12.5** — `remote_banner` corresponde a un **QoD del 80 %**. Está por debajo del valor de `package` (**97 %**) porque un banner es autodeclarado, trivialmente alterable (`server_tokens off`, `ServerTokens Prod`, proxies inversos, retroadaptaciones del proveedor) y con frecuencia engañoso; sobre todo, las distribuciones retroadaptan correcciones de seguridad sin cambiar la versión anunciada, así que una comprobación basada en banner informa de una vulnerabilidad que ya ha sido parcheada. Una comprobación basada en `package` lee la versión del paquete realmente instalada desde la propia base de datos de paquetes del host mediante acceso autenticado, lo cual es evidencia directa en lugar de un anuncio.

**Q12.6** — `ACT_DENIAL` (pruebas de denegación de servicio), `ACT_KILL_HOST` (pruebas que tumban o reinician el objetivo) y `ACT_DESTRUCTIVE_ATTACK` (pruebas que modifican o destruyen datos). No deben ejecutarse bajo `safe_checks` porque establecen la vulnerabilidad *provocándola*: la prueba es una interrupción o una pérdida de datos en un sistema que le pidieron evaluar, no romper. Bajo `safe_checks` el escáner sustituye estas pruebas por inferencia de versión/configuración, cambiando certeza por seguridad.

**Q12.7** — Los NVT del feed oficial están firmados criptográficamente, y la comprobación de firma es lo que impide que un espejo de feed manipulado, una ruta rsync comprometida o un archivo local malicioso inyecten código que el escáner ejecuta con sus privilegios contra todos los hosts del alcance. `-X` desactiva esa comprobación por completo. Aun así es correcto —y necesario— al ejecutar un script **escrito por usted y sin firmar**, es decir, exactamente el flujo de desarrollo de este ejercicio. La regla es: `-X` para sus propios scripts en un laboratorio; nunca como forma de silenciar fallos de firma en contenido del feed, que deben tratarse como un incidente de seguridad.

### Bloque 13 — Correlación

**Q13.1** — Suprimir el GID 122 por IP de origen significa que cualquiera capaz de originar paquetes desde `192.168.56.30` —comprometiendo el escáner (un host que por diseño guarda credenciales privilegiadas de todo el parque) o suplantando su dirección— obtiene un canal de reconocimiento gratuito y permanentemente invisible a través de su NIDS. Mitigaciones, de mayor a menor fortaleza: (a) suprimir solo durante la ventana de escaneo planificada en lugar de permanentemente, gobernado por el mismo planificador que lanza el escaneo; (b) conservar los eventos pero encaminarlos a un flujo de baja prioridad/auditoría mediante `event_filter` o un registrador aparte en lugar de eliminarlos; (c) acompañar la supresión con monitorización robusta basada en host y comprobación de integridad sobre el propio escáner (objetivo 332.2), y con antisuplantación (uRPF / seguridad de puerto) para que la dirección de origen no pueda falsificarse.

**Q13.2** — La parte con credenciales del escaneo corre sobre **SSH**: el escáner se autentica y luego ejecuta comandos locales (consultas de paquetes, lecturas de archivos) dentro de un canal cifrado. Un IDS de red solo ve una sesión TLS/SSH —carga útil cifrada que no puede comparar contra patrones—, así que ninguna regla de contenido puede dispararse. La brecha la cubre la **detección de intrusiones y auditoría basada en host**: una herramienta HIDS/de integridad de archivos (AIDE, Samhain), el subsistema de auditoría de Linux (`auditd`) registrando las ejecuciones, y el registro de autenticación enviado fuera del host. Esta es precisamente la complementariedad entre los objetivos 332.2 (Detección de intrusiones en el host) y 334.2: ninguno reemplaza al otro.

**Q13.3** — Primero verifique **si el tráfico es legítimo**: identifique el proceso y la función de negocio (un agente de copias de seguridad enumerando legítimamente muchos hosts/puertos se ve idéntico a un barrido), confirme que el origen es lo que dice ser, y confirme que el comportamiento tiene un registro de cambio. Solo entonces ajuste, y en este orden: (1) **`event_filter`/umbral** primero, que reduce el volumen manteniendo la visibilidad, porque es lo menos destructivo; (2) **`suppress`** con el alcance más estrecho posible (GID:SID específico *y* origen específico *y*, donde se soporte, destino específico) si los eventos no aportan ningún valor; (3) **editar o desactivar la regla** en último lugar, y solo para una regla que sea errónea y no meramente ruidosa, porque esa decisión afecta a todos los hosts, no solo a este. Documente cada una con una razón y una fecha de revisión.

**Q13.4** — Un NIDS detecta e informa; no elimina la vulnerabilidad. En concreto: es ciego a la explotación cifrada y a la local en el host, solo reconoce patrones de ataque para los que tiene firmas (así que un exploit novedoso o ligeramente ofuscado del mismo fallo pasa), produce alertas que requieren un proceso de respuesta dotado de personal y presupuesto para tener algún efecto, e incluso un IPS en línea toma una decisión de bloqueo de mejor esfuerzo que un atacante determinado puede evadir, mientras el host sin parchear sigue siendo explotable por cualquiera que lo alcance por cualquier otra vía (un host interno comprometido, un cliente VPN, una interfaz de mantenimiento, acceso físico). Un control compensatorio debe reducir la *probabilidad o el impacto* de la explotación a un nivel comparable al del control original; una detección con un tiempo medio de respuesta medido en horas no alcanza ese listón para un fallo explotable remotamente. Es una medida legítima de reducción de riesgo *provisional* con una fecha de caducidad documentada y un compromiso de parcheo, no un sustituto del parche.

</details>

---

## Fuentes oficiales

- **LPI — Objetivos del examen 303 (303-300 v3.0.0)**: <https://www.lpi.org/our-certifications/exam-303-objectives/>
- **Snort — portal de documentación oficial**: <https://docs.snort.org/>
- **Snort — referencia de escritura de reglas**: <https://docs.snort.org/rules/>
- **Snort — descargas y conjuntos de reglas**: <https://www.snort.org/downloads>
- **Código fuente de Snort 3**: <https://github.com/snort3/snort3> · **libdaq**: <https://github.com/snort3/libdaq>
- **PulledPork 3**: <https://github.com/shirkdog/pulledpork3>
- **Oinkmaster**: <http://oinkmaster.sourceforge.net/>
- **Greenbone — documentación de la comunidad**: <https://greenbone.github.io/docs/>
- **Greenbone — openvas-scanner (motor NASL y documentación)**: <https://github.com/greenbone/openvas-scanner>
- **Greenbone — gvmd (documentación del protocolo GMP)**: <https://github.com/greenbone/gvmd>
- **Greenbone — gvm-tools / `gvm-cli`**: <https://gvm-tools.readthedocs.io/>
- **Greenbone — sincronización de feeds**: <https://github.com/greenbone/greenbone-feed-sync>
- **Documentación de ntop / ntopng**: <https://www.ntop.org/guides/ntopng/>
- **iftop**: <https://pdw.ex-parrot.com/iftop/>
- **iptraf-ng**: <https://github.com/iptraf-ng/iptraf-ng>
- **bandwidthd**: <https://sourceforge.net/projects/bandwidthd/>
- **Documentación de Cacti**: <https://docs.cacti.net/>
- **Documentación de RRDtool**: <https://oss.oetiker.ch/rrdtool/doc/>
- **Net-SNMP (IF-MIB, snmpd)**: <https://www.net-snmp.org/docs/man/>
- **netfilter — NFQUEUE / libnetfilter_queue**: <https://www.netfilter.org/projects/libnetfilter_queue/>