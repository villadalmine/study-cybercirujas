# 334.1 Endurecimiento de red — Ejercicios guiados

**Certificación:** LPIC-3 Security (examen 303-300, v3.0.0) · **Peso del tema:** 6.67

Estos ejercicios asumen que sos dueño de cada host que tocás. Escanear puertos, inyectar RA y hacer spoofing de DHCP contra redes que no administrás es, en la mayoría de las jurisdicciones, un acto delictivo. Construí el laboratorio de abajo y quedate dentro de él.

## Topología del laboratorio

| Rol | Hostname | IPv4 | IPv6 | Propósito |
|---|---|---|---|---|
| Workstation / analista | `lab-ops` | 192.168.56.30 | 2001:db8:cafe:1::30 | nmap, tshark, FreeRADIUS, arpwatch |
| Objetivo / supplicant | `lab-target` | 192.168.56.20 | SLAAC | host escaneado, cliente 802.1X |
| Router legítimo + DHCP | `lab-gw` | 192.168.56.10 | 2001:db8:cafe:1::1 | `radvd`, `kea-dhcp4` / `dhcpd` |
| Nodo rogue | `lab-rogue` | 192.168.56.66 | solo link-local | origen de RA rogue + DHCP rogue |

Los cuatro están en un único segmento L2 aislado (una red `isolated` de libvirt, una red interna de VirtualBox, o una VLAN dedicada sin uplink). Paquetes utilizados: `nmap ndiff wireshark tshark tcpdump freeradius freeradius-utils wpasupplicant hostapd radvd ndisc6 arpwatch nftables dhcpdump`.

Las rutas difieren entre distribuciones y el examen espera el layout de Red Hat:

| | Debian/Ubuntu | RHEL/Fedora/openSUSE |
|---|---|---|
| Configuración de FreeRADIUS | `/etc/freeradius/3.0/` | `/etc/raddb/` |
| Binario del demonio | `freeradius` | `radiusd` |
| Unit | `freeradius.service` | `radiusd.service` |
| Logs / accounting | `/var/log/freeradius/` | `/var/log/radius/` |

A lo largo del documento se usa `/etc/raddb` como ruta canónica; sustituilo por `/etc/freeradius/3.0` en Debian.

---

## Ejercicio 1 — Medir la superficie de ataque con `nmap`

### Pasos

1. En `lab-target`, obtené la vista local *autoritativa* de qué está escuchando, antes de escanear nada:

   ```bash
   ss -tulpnH | sort -k5
   ```

   ```
   tcp   LISTEN 0      4096       127.0.0.1:631        0.0.0.0:*    users:(("cupsd",pid=612,fd=7))
   tcp   LISTEN 0      511          0.0.0.0:80         0.0.0.0:*    users:(("nginx",pid=901,fd=6))
   tcp   LISTEN 0      128          0.0.0.0:22         0.0.0.0:*    users:(("sshd",pid=744,fd=3))
   udp   UNCONN 0      0            0.0.0.0:68         0.0.0.0:*    users:(("dhclient",pid=690,fd=6))
   ```

2. Desde `lab-ops`, ejecutá un TCP connect scan sin privilegios y luego el mismo escaneo como root:

   ```bash
   nmap -sT --reason -p 22,80,443,631,3306 192.168.56.20
   sudo nmap -sS --reason -p 22,80,443,631,3306 192.168.56.20
   ```

   ```
   PORT     STATE  SERVICE REASON
   22/tcp   open   ssh     syn-ack ttl 64
   80/tcp   open   http    syn-ack ttl 64
   443/tcp  closed https   reset ttl 64
   631/tcp  closed ipp     reset ttl 64
   3306/tcp closed mysql   reset ttl 64
   ```

3. Notá que `631` aparece como `closed`, no `filtered`, aunque `cupsd` esté corriendo. Confirmá por qué:

   ```bash
   ssh lab-target 'ss -tlnp | grep 631'
   ```

4. Agregá fingerprinting de servicio y de sistema operativo, y conservá el artefacto legible por máquina:

   ```bash
   sudo nmap -sS -sV -O -T4 --top-ports 1000 --open \
             -oA /var/lib/nmap-drift/baseline 192.168.56.20
   ```

   ```
   PORT   STATE SERVICE VERSION
   22/tcp open  ssh     OpenSSH 9.6p1 Debian 3 (protocol 2.0)
   80/tcp open  http    nginx 1.24.0
   MAC Address: 52:54:00:AA:BB:CC (QEMU virtual NIC)
   Device type: general purpose
   Running: Linux 5.X|6.X
   OS CPE: cpe:/o:linux:linux_kernel:6
   OS details: Linux 6.1 - 6.8
   Network Distance: 1 hop
   ```

   `-oA` escribe `baseline.nmap`, `baseline.gnmap` y `baseline.xml`.

5. Descubrí hosts sin tocar un solo puerto, y después compará contra un sondeo UDP de los puertos clásicos de infraestructura:

   ```bash
   sudo nmap -sn 192.168.56.0/24
   sudo nmap -sU -p 53,67,68,123,161,1812,1813 192.168.56.10
   ```

6. Usá NSE para convertir el hecho "el puerto está abierto" en un hallazgo de endurecimiento:

   ```bash
   sudo nmap -sV --script ssl-enum-ciphers -p 443 192.168.56.10
   sudo nmap --script "default and safe" -p 22,80 192.168.56.20
   ```

7. Observá el cable mientras escaneás. En una segunda terminal en `lab-target`:

   ```bash
   sudo tshark -i enp1s0 -Y 'tcp.flags.syn == 1 && tcp.flags.ack == 0' \
        -T fields -e ip.src -e tcp.dstport -e tcp.window_size
   ```

   Reejecutá el paso 2 con `-sS` y luego con `-sT`, y compará los tamaños de ventana y la presencia de un handshake completado.

8. Ahora instalá algo nuevo en `lab-target` y detectá la deriva:

   ```bash
   sudo systemctl enable --now mariadb        # simulates an unapproved change
   sudo nmap -sS -sV -O -T4 --top-ports 1000 --open \
             -oX /var/lib/nmap-drift/current.xml 192.168.56.20
   ndiff /var/lib/nmap-drift/baseline.xml /var/lib/nmap-drift/current.xml; echo "exit=$?"
   ```

   ```
   -lab-target (192.168.56.20):
   +lab-target (192.168.56.20):
    Host is up.
    PORT     STATE SERVICE VERSION
   +3306/tcp open  mysql   MariaDB 10.11.6
   exit=1
   ```

### Preguntas de comprensión

**Q1.1** `cupsd` está escuchando en el puerto 631 pero nmap reporta `closed`. ¿Por qué, y qué te dice eso sobre la diferencia entre "un servicio está corriendo" y "un servicio está expuesto"?

**Q1.2** ¿Qué distingue `closed` de `filtered` en la salida de nmap, y cuál de los dos indica que hay un filtro de paquetes en el camino?

**Q1.3** ¿Por qué `-sS` requiere root y `-sT` no, y qué rastro forense deja cada uno en los logs de aplicación del objetivo?

**Q1.4** `ndiff` salió con código 1. En un script de monitoreo gobernado por `set -e`, ¿por qué ese código de salida es una trampa, y cuáles son los tres códigos de salida de `ndiff`?

**Q1.5** Te piden demostrar que un host interno no tiene ninguna base de datos expuesta. ¿Qué es evidencia más fuerte: `ss -tulpn` en el host, o `nmap` desde la red? Explicá por qué la respuesta es "ambos, para afirmaciones distintas".

---

## Ejercicio 2 — Achicar la superficie: kernel, unit y filtro

### Pasos

1. Leé los valores actuales de los parámetros que deciden si el host confía en la red:

   ```bash
   sysctl net.ipv4.conf.all.rp_filter net.ipv4.conf.all.accept_redirects \
          net.ipv4.conf.all.log_martians net.ipv6.conf.all.accept_ra \
          net.ipv6.conf.enp1s0.accept_ra net.ipv6.conf.all.autoconf
   ```

2. Escribí una política persistente:

   ```ini
   # /etc/sysctl.d/60-net-hardening.conf
   # --- IPv4 path validation -------------------------------------------------
   net.ipv4.conf.all.rp_filter                = 1
   net.ipv4.conf.default.rp_filter            = 1
   net.ipv4.conf.all.accept_source_route      = 0
   net.ipv4.conf.default.accept_source_route  = 0
   net.ipv4.conf.all.log_martians             = 1
   net.ipv4.conf.default.log_martians         = 1

   # --- ICMP redirects: never accept, never send ----------------------------
   net.ipv4.conf.all.accept_redirects         = 0
   net.ipv4.conf.default.accept_redirects     = 0
   net.ipv4.conf.all.secure_redirects         = 0
   net.ipv4.conf.all.send_redirects           = 0
   net.ipv4.conf.default.send_redirects       = 0

   # --- Amplification and SYN flood -----------------------------------------
   net.ipv4.icmp_echo_ignore_broadcasts       = 1
   net.ipv4.icmp_ignore_bogus_error_responses = 1
   net.ipv4.tcp_syncookies                    = 1

   # --- ARP: answer only for addresses on the receiving interface -----------
   net.ipv4.conf.all.arp_ignore               = 1
   net.ipv4.conf.all.arp_announce             = 2

   # --- IPv6: this host is statically addressed, it learns nothing ----------
   net.ipv6.conf.all.accept_ra                = 0
   net.ipv6.conf.default.accept_ra            = 0
   net.ipv6.conf.all.accept_ra_defrtr         = 0
   net.ipv6.conf.all.accept_ra_pinfo          = 0
   net.ipv6.conf.all.accept_ra_rtr_pref       = 0
   net.ipv6.conf.all.autoconf                 = 0
   net.ipv6.conf.all.router_solicitations     = 0
   net.ipv6.conf.all.accept_redirects         = 0
   net.ipv6.conf.default.accept_redirects     = 0
   ```

   ```bash
   sudo sysctl --system
   sudo sysctl -a --pattern 'ipv6.conf.enp1s0.accept_ra'
   ```

3. Demostrá la semántica de `all` vs `default` vs por dispositivo en lugar de asumirla:

   ```bash
   sudo ip link add dummy0 type dummy && sudo ip link set dummy0 up
   sysctl net.ipv6.conf.dummy0.accept_ra net.ipv4.conf.dummy0.rp_filter
   sudo sysctl -w net.ipv4.conf.all.rp_filter=0
   sysctl net.ipv4.conf.dummy0.rp_filter          # per-device value unchanged
   ```

4. Verificá si tu gestor de red anula el kernel a tus espaldas:

   ```bash
   nmcli -f ipv6.method,ipv6.addr-gen-mode connection show "System enp1s0"
   grep -rn 'IPv6AcceptRA\|LinkLocalAddressing' /etc/systemd/network/ 2>/dev/null
   ```

5. Confiná un único servicio a las direcciones con las que tiene permitido hablar, usando el filtro BPF de cgroup v2 en lugar de una regla global de firewall:

   ```ini
   # /etc/systemd/system/nginx.service.d/10-net-lockdown.conf
   [Service]
   IPAddressDeny=any
   IPAddressAllow=localhost
   IPAddressAllow=192.168.56.0/24
   RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
   PrivateTmp=yes
   ProtectSystem=strict
   NoNewPrivileges=yes
   ```

   ```bash
   sudo systemctl daemon-reload && sudo systemctl restart nginx
   systemd-analyze security nginx.service | head -20
   ```

6. Colocá el filtro de paquetes. Este ruleset es el punto de aplicación para el trabajo con RA rogue y DHCP rogue de los ejercicios 6 y 7:

   ```nft
   #!/usr/sbin/nft -f
   # /etc/nftables.conf
   flush ruleset

   define TRUSTED_ROUTER_LL = fe80::5054:ff:fe12:3456
   define TRUSTED_DHCP4     = 192.168.56.10

   table inet filter {
       chain input {
           type filter hook input priority filter; policy drop;

           iif lo accept
           ct state established,related accept
           ct state invalid counter drop comment "no state, no entry"

           # Neighbour Discovery is mandatory for IPv6, but RFC 4861 says
           # every ND message must arrive with hop limit 255 and a
           # link-local source. Anything else was routed, so it is forged.
           icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert } \
               ip6 hoplimit 255 ip6 saddr fe80::/10 accept
           icmpv6 type { echo-request, echo-reply, destination-unreachable,
                         packet-too-big, time-exceeded, parameter-problem } accept

           # RA guard, host side: only the authorised router may advertise
           icmpv6 type nd-router-advert ip6 hoplimit 255 \
               ip6 saddr $TRUSTED_ROUTER_LL accept
           icmpv6 type nd-router-advert \
               counter log prefix "ROGUE-RA " level warn drop

           # Only the authorised DHCPv4 server may answer a client
           udp sport 67 udp dport 68 ip saddr $TRUSTED_DHCP4 accept
           udp sport 67 udp dport 68 \
               counter log prefix "ROGUE-DHCP " level warn drop

           tcp dport 22 ct state new limit rate 10/minute burst 5 packets accept
           counter comment "input-policy-drop"
       }

       chain forward { type filter hook forward priority filter; policy drop; }
       chain output  { type filter hook output  priority filter; policy accept; }
   }
   ```

   ```bash
   sudo nft -c -f /etc/nftables.conf && sudo systemctl enable --now nftables
   sudo nft list ruleset | grep -A2 ROGUE
   ```

7. Reescaneá desde `lab-ops` y observá cómo cambió el informe:

   ```bash
   sudo nmap -sS -p 22,80,3306 --reason 192.168.56.20
   ```

### Preguntas de comprensión

**Q2.1** Para `rp_filter` el kernel usa el *máximo* entre `conf.all` y `conf.<dev>`, pero para `accept_redirects` usa el valor por dispositivo con `all` actuando como escritura por difusión. ¿Qué bug práctico causa esa asimetría cuando fijás valores en `/etc/sysctl.d/`?

**Q2.2** ¿Por qué es necesario `net.ipv6.conf.default.accept_ra = 0` si ya fijaste `all`?

**Q2.3** `IPAddressDeny=any` no hace nada, en silencio, en algunos sistemas. ¿Cuál es el prerrequisito, y cómo verificarías que se cumple?

**Q2.4** Después del paso 6, nmap reporta el puerto 3306 como `filtered` en lugar de `closed`. Explicá la razón a nivel de paquete.

**Q2.5** ¿Por qué el ruleset verifica `ip6 hoplimit 255` en los mensajes de Neighbour Discovery? ¿Qué clase de ataque elimina ese único match?

**Q2.6** `rp_filter = 1` rompe un patrón de despliegue legítimo. Nombralo, y decí qué usarías en su lugar.

---

## Ejercicio 3 — Análisis de tráfico con `tshark` y Wireshark

### Pasos

1. Otorgá permisos de captura sin correr como root un disector de 3 millones de líneas:

   ```bash
   sudo dpkg-reconfigure wireshark-common       # Debian: answer "yes"
   sudo usermod -aG wireshark "$USER"
   getcap /usr/bin/dumpcap
   ```

   ```
   /usr/bin/dumpcap cap_net_admin,cap_net_raw=eip
   ```

   Cerrá sesión y volvé a entrar, después confirmá:

   ```bash
   tshark -D
   ```

   ```
   1. enp1s0
   2. lo (Loopback)
   3. any
   ```

2. Capturá con un **filtro de captura** (BPF dentro del kernel) y notá el costo de CPU frente a un **filtro de visualización** equivalente:

   ```bash
   tshark -i enp1s0 -f 'tcp port 80' -c 20 -w /tmp/http-bpf.pcapng
   tshark -i enp1s0 -Y 'http'        -c 20 -w /tmp/http-dfilter.pcapng
   ```

3. Generá una credencial en texto claro y demostrá que es legible:

   ```bash
   curl -u alice:S3cr3tPass http://192.168.56.10/private/ >/dev/null
   tshark -r /tmp/http-bpf.pcapng -Y 'http.authorization' \
          -T fields -e ip.src -e ip.dst -e http.authorization
   ```

   ```
   192.168.56.30   192.168.56.10   Basic YWxpY2U6UzNjcjN0UGFzcw==
   ```

4. Resumí una captura como lo harías en un informe de incidente:

   ```bash
   capinfos /tmp/http-bpf.pcapng | head -12
   tshark -r /tmp/http-bpf.pcapng -q -z io,phs
   tshark -r /tmp/http-bpf.pcapng -q -z conv,tcp
   tshark -r /tmp/http-bpf.pcapng -q -z endpoints,ip
   tshark -r /tmp/http-bpf.pcapng -q -z expert
   ```

5. Reensamblá una conversación de aplicación:

   ```bash
   tshark -r /tmp/http-bpf.pcapng -q -z follow,tcp,ascii,0
   ```

6. Extraé campos para un pipeline en lugar de mirar paquetes a ojo:

   ```bash
   tshark -r /tmp/http-bpf.pcapng -T fields \
          -e frame.number -e frame.time_relative -e ip.src -e tcp.dstport -e _ws.col.info \
          -E header=y -E separator=, -E quote=d
   ```

7. Ejecutá una captura acotada y de larga duración, apta para un host de producción — un ring buffer con snaplen truncado para quedarte con las cabeceras, no con los payloads:

   ```bash
   sudo install -d -m 0750 -o root -g wireshark /var/log/captures
   tshark -i enp1s0 -s 96 -f 'not port 22' \
          -b filesize:65536 -b files:10 \
          -w /var/log/captures/lab.pcapng
   ```

8. Recortá y fusioná después:

   ```bash
   editcap -A '2026-08-25 11:00:00' -B '2026-08-25 11:05:00' \
           /var/log/captures/lab_00001_*.pcapng /tmp/window.pcapng
   mergecap -w /tmp/all.pcapng /var/log/captures/lab_*.pcapng
   ```

### Preguntas de comprensión

**Q3.1** ¿Dónde se ejecuta un filtro de captura `-f`, dónde se ejecuta un filtro de visualización `-Y`, y bajo qué condición la elección decide si perdés paquetes?

**Q3.2** `-Y 'http'` y `-f 'tcp port 80'` no son equivalentes ni siquiera en una red puramente HTTP sobre el puerto 80. Dá un paquete que cada captura conserva y la otra descarta.

**Q3.3** ¿Por qué correr `wireshark` como root se considera una falla de endurecimiento, y cuál es la solución arquitectónica que trae Wireshark?

**Q3.4** Fijaste `-s 96`. ¿Qué análisis siguen siendo posibles y cuáles se vuelven imposibles?

**Q3.5** Un ring buffer de `-b filesize:65536 -b files:10` — ¿cuánto disco consume en régimen estacionario, y qué pasa con los datos más viejos?

**Q3.6** Nombrá el filtro de visualización que encuentra tráfico DHCPv4 en Wireshark 3.0 y posteriores, y el nombre al que reemplazó.

---

## Ejercicio 4 — FreeRADIUS: autenticar nodos de red

### Pasos

1. Instalá e inspeccioná el árbol de configuración antes de cambiar nada:

   ```bash
   sudo dnf install -y freeradius freeradius-utils     # or: apt install freeradius
   ls -1 /etc/raddb/
   ```

   ```
   certs/          dictionary       mods-config/     policy.d/       sites-available/
   clients.conf    mods-available/  panic.gdb        radiusd.conf    sites-enabled/
   ```

   ```bash
   ls -l /etc/raddb/sites-enabled/ /etc/raddb/mods-enabled/ | head
   ```

   Ambos directorios son granjas de symlinks hacia `*-available/`; habilitar un módulo es un `ln -s`.

2. Validá la configuración provista y confirmá la identidad del demonio:

   ```bash
   sudo radiusd -Cxl stdout | tail -5
   ```

   ```
   Configuration appears to be OK
   ```

3. Definí los clientes NAS. Nunca dejes `testing123` alcanzable desde algo que no sea loopback:

   ```conf
   # /etc/raddb/clients.conf
   client localhost {
       ipaddr                        = 127.0.0.1
       proto                         = *
       secret                        = testing123
       require_message_authenticator = no
       nas_type                      = other
       limit {
           max_connections = 16
           lifetime        = 0
           idle_timeout    = 30
       }
   }

   client sw-core-01 {
       ipaddr                        = 192.168.56.10
       secret                        = 'Q7!kp2Vf$Lm9zR4wXe8Tn1Bh'
       shortname                     = sw-core-01
       nas_type                      = other
       require_message_authenticator = yes
   }

   client lab-supplicants {
       ipaddr                        = 192.168.56.0/24
       secret                        = 'aK4#nD8vZq2Ls6Jr9Wt3Cy7M'
       shortname                     = lab-net
       require_message_authenticator = yes
   }
   ```

4. Creá las identidades de prueba. En FreeRADIUS 3.x el archivo `users` vive bajo `mods-config`:

   ```conf
   # /etc/raddb/mods-config/files/authorize
   bob     Cleartext-Password := "hello"
           Reply-Message = "Hello, %{User-Name}",
           Session-Timeout = 3600,
           Idle-Timeout = 600

   # MAC Authentication Bypass for a printer: identity == MAC, put it in the
   # quarantine VLAN and never let it route anywhere interesting.
   "0011223344ab"  Cleartext-Password := "0011223344ab"
           Tunnel-Type = VLAN,
           Tunnel-Medium-Type = IEEE-802,
           Tunnel-Private-Group-Id = "310"

   # Default: reject. An unmatched identity must not fall through to accept.
   DEFAULT Auth-Type := Reject
           Reply-Message = "Access denied by policy"
   ```

5. Detené el servicio y ejecutá el demonio en primer plano en modo debug — esta es la habilidad más importante de FreeRADIUS:

   ```bash
   sudo systemctl stop radiusd
   sudo radiusd -X
   ```

   ```
   Listening on auth address * port 1812 bound to server default
   Listening on acct address * port 1813 bound to server default
   Listening on auth address 127.0.0.1 port 18120 bound to server inner-tunnel
   Ready to process requests
   ```

6. Desde una segunda terminal, autenticá con PAP:

   ```bash
   radtest bob hello 127.0.0.1 0 testing123
   ```

   ```
   Sent Access-Request Id 215 from 0.0.0.0:39764 to 127.0.0.1:1812 length 74
       User-Name = "bob"
       User-Password = "hello"
       NAS-IP-Address = 127.0.0.1
       NAS-Port = 0
       Message-Authenticator = 0x00
       Cleartext-Password = "hello"
   Received Access-Accept Id 215 from 127.0.0.1:1812 to 127.0.0.1:39764 length 47
       Reply-Message = "Hello, bob"
       Session-Timeout = 3600
       Idle-Timeout = 600
   ```

   En la ventana de `radiusd -X`, leé la traza de política: `(0) files: users: Matched entry bob at line 2`, `(0) pap: Login OK`, `(0) Sent Access-Accept Id 215`.

7. Ahora un rechazo, y medile el tiempo:

   ```bash
   time ( echo "User-Name = bob, User-Password = wrongpass" \
          | radclient -x 127.0.0.1:1812 auth testing123 )
   ```

   ```
   Received Access-Reject Id 42 from 127.0.0.1:1812 to 127.0.0.1:47000 length 20
   real    0m1.012s
   ```

8. Enviá un conjunto arbitrario de atributos — la herramienta que usás cuando hay que reproducir la request de un switch de determinado fabricante:

   ```bash
   cat > /tmp/req.txt <<'EOF'
   User-Name = "0011223344ab"
   User-Password = "0011223344ab"
   NAS-IP-Address = 192.168.56.10
   NAS-Port = 24
   NAS-Port-Type = Ethernet
   Called-Station-Id = "00-1A-2B-3C-4D-5E"
   Calling-Station-Id = "00-11-22-33-44-AB"
   Service-Type = Call-Check
   EOF
   radclient -x -f /tmp/req.txt 127.0.0.1:1812 auth testing123
   ```

   Esperá `Tunnel-Private-Group-Id = "310"` en el Access-Accept.

9. Habilitá accounting hacia `radutmp` para que funcionen las herramientas de sesión. En `/etc/raddb/sites-enabled/default`, confirmá que `radutmp` esté presente en la sección `accounting {}`, y luego:

   ```bash
   printf 'User-Name = bob\nAcct-Status-Type = Start\nAcct-Session-Id = "0001"\nNAS-IP-Address = 192.168.56.10\nNAS-Port = 24\nFramed-IP-Address = 192.168.56.50\n' \
     | radclient -x 127.0.0.1:1813 acct testing123
   radwho
   ```

   ```
   Login      Name              What  TTY  When      From      Location
   bob        bob               shell  s24 Aug 25 11:41  192.168.56.10
   ```

   ```bash
   printf 'User-Name = bob\nAcct-Status-Type = Stop\nAcct-Session-Id = "0001"\nAcct-Session-Time = 300\nNAS-IP-Address = 192.168.56.10\nNAS-Port = 24\n' \
     | radclient -x 127.0.0.1:1813 acct testing123
   radlast
   ```

10. Observá el protocolo en sí, y mirá exactamente cuánto está protegiendo el secreto compartido:

    ```bash
    sudo tshark -i lo -f 'udp port 1812' -O radius \
                -o 'radius.shared_secret:testing123' -Y 'radius'
    ```

    En el árbol decodificado, buscá `User-Password` y la anotación `[Decrypted: hello]`, además de los atributos `Authenticator` y `Message-Authenticator`.

11. Inspeccioná dónde aterriza realmente la evidencia de accounting:

    ```bash
    ls -l /var/log/radius/radacct/192.168.56.10/
    sudo tail -20 /var/log/radius/radacct/192.168.56.10/detail-20260825
    ```

### Preguntas de comprensión

**Q4.1** ¿Qué puertos UDP usa RADIUS moderno para autenticación y accounting, y qué par usaba históricamente?

**Q4.2** `radtest` envió `User-Password` en un Access-Request. Explicá el mecanismo que lo protege, y por qué un secreto compartido débil lo vuelve inútil.

**Q4.3** ¿Por qué el Access-Reject tardó casi exactamente un segundo? Nombrá la directiva.

**Q4.4** ¿Por qué `mods-config/files/authorize` debe almacenar `Cleartext-Password` en lugar de un hash si pensás soportar CHAP o MS-CHAPv2?

**Q4.5** `radwho` no imprimió nada en tu primer intento. Nombrá las dos condiciones de configuración que deben cumplirse, y en qué archivo vive cada una.

**Q4.6** ¿Por qué `require_message_authenticator = yes` es importante para un NAS real, y por qué está en `no` para `localhost` en la configuración provista?

**Q4.7** ¿Cuál es la diferencia operativa entre `systemctl start radiusd` y `radiusd -X`, y por qué el segundo es el primer paso de todo diagnóstico de FreeRADIUS?

**Q4.8** La entrada `DEFAULT Auth-Type := Reject` está última en el archivo. ¿Qué pasaría si la pusieras primera?

---

## Ejercicio 5 — Autenticación de puerto 802.1X de punta a punta

### Pasos

1. Inicializá la cadena de certificados del servidor. La CA snake-oil provista es solo para laboratorios:

   ```bash
   cd /etc/raddb/certs && sudo ./bootstrap
   openssl x509 -in /etc/raddb/certs/server.pem -noout -subject -dates -ext extendedKeyUsage
   ```

2. Configurá el módulo EAP para PEAP/MSCHAPv2 con un piso TLS razonable:

   ```conf
   # /etc/raddb/mods-available/eap  (excerpt)
   eap {
       default_eap_type        = peap
       timer_expire            = 60
       ignore_unknown_eap_types = no
       max_sessions            = ${max_requests}

       tls-config tls-common {
           private_key_password    = whatever
           private_key_file        = ${certdir}/server.pem
           certificate_file        = ${certdir}/server.pem
           ca_file                 = ${cadir}/ca.pem
           dh_file                 = ${certdir}/dh
           tls_min_version         = "1.2"
           tls_max_version         = "1.3"
           cipher_list             = "HIGH:!aNULL:!eNULL:!EXPORT:!DES:!RC4:!MD5:!PSK:!SRP"
           cipher_server_preference = yes
       }

       peap {
           tls                   = tls-common
           default_eap_type      = mschapv2
           copy_request_to_tunnel = no
           use_tunneled_reply    = no
           virtual_server        = "inner-tunnel"
       }

       mschapv2 { }
   }
   ```

   ```bash
   sudo radiusd -Cxl stdout | tail -3
   sudo radiusd -X            # keep this running
   ```

3. Convertí `lab-gw` en un autenticador 802.1X con `hostapd` en modo wired:

   ```conf
   # /etc/hostapd/hostapd-wired.conf
   interface=br0
   driver=wired
   ieee8021x=1
   eap_reauth_period=3600
   use_pae_group_addr=1

   auth_server_addr=192.168.56.30
   auth_server_port=1812
   auth_server_shared_secret=aK4#nD8vZq2Ls6Jr9Wt3Cy7M

   acct_server_addr=192.168.56.30
   acct_server_port=1813
   acct_server_shared_secret=aK4#nD8vZq2Ls6Jr9Wt3Cy7M

   nas_identifier=lab-gw
   logger_stdout=-1
   logger_stdout_level=1
   ```

   ```bash
   sudo hostapd -dd /etc/hostapd/hostapd-wired.conf
   ```

4. Configurá el supplicant en `lab-target`:

   ```conf
   # /etc/wpa_supplicant/wired.conf
   ctrl_interface=/run/wpa_supplicant
   eapol_version=2
   ap_scan=0
   fast_reauth=1

   network={
       key_mgmt=IEEE8021X
       eap=PEAP
       identity="bob"
       anonymous_identity="anonymous@lab.example"
       password="hello"
       ca_cert="/etc/ssl/certs/lab-ca.pem"
       phase1="peaplabel=0"
       phase2="auth=MSCHAPV2"
   }
   ```

   ```bash
   sudo wpa_supplicant -D wired -i enp1s0 -c /etc/wpa_supplicant/wired.conf -d
   ```

   ```
   enp1s0: CTRL-EVENT-EAP-STARTED EAP authentication started
   enp1s0: CTRL-EVENT-EAP-PROPOSED-METHOD vendor=0 method=25
   EAP: Status notification: remote certificate verification (param=success)
   enp1s0: CTRL-EVENT-EAP-METHOD EAP vendor 0 method 26 (MSCHAPV2) selected
   enp1s0: CTRL-EVENT-EAP-SUCCESS EAP authentication completed successfully
   enp1s0: CTRL-EVENT-CONNECTED - Connection to 01:80:c2:00:00:03 completed
   ```

5. Capturá el intercambio desde ambos lados y observá qué partes están cifradas y cuáles no:

   ```bash
   sudo tshark -i enp1s0 -Y 'eapol || eap' \
        -T fields -e frame.number -e eth.src -e eap.code -e eap.type -e eap.identity
   sudo tshark -i enp1s0 -f 'udp port 1812' -Y 'radius' \
        -T fields -e radius.code -e radius.id -e radius.User_Name
   ```

6. Rompelo a propósito, de tres maneras, y leé la traza de `radiusd -X` en cada caso:

   ```bash
   # wrong inner password
   sed -i 's/password="hello"/password="nope"/' /etc/wpa_supplicant/wired.conf
   # unknown identity
   sed -i 's/identity="bob"/identity="nobody"/'  /etc/wpa_supplicant/wired.conf
   # wrong shared secret on the authenticator
   sed -i 's/^auth_server_shared_secret=.*/auth_server_shared_secret=WRONG/' \
       /etc/hostapd/hostapd-wired.conf
   ```

   Para el tercer caso, notá lo que imprime el servidor:

   ```
   Received packet from 192.168.56.10 with invalid Message-Authenticator!  (Shared secret is incorrect.)
   ```

7. Devolvé asignación de VLAN por identidad agregando atributos de túnel a `bob` en `mods-config/files/authorize`, y luego confirmá que el `Access-Accept` los lleva:

   ```conf
   bob     Cleartext-Password := "hello"
           Tunnel-Type = VLAN,
           Tunnel-Medium-Type = IEEE-802,
           Tunnel-Private-Group-Id = "120",
           Reply-Message = "Welcome to VLAN 120"
   ```

### Preguntas de comprensión

**Q5.1** Nombrá los tres roles de 802.1X y mapeá cada uno a un componente de este laboratorio.

**Q5.2** Las tramas EAPOL van a `01:80:c2:00:00:03`. ¿A qué familia de protocolos corresponde eso, y por qué 802.1X no se transporta sobre IP entre supplicant y autenticador?

**Q5.3** Con PEAP, ¿qué identidad ve en texto claro un atacante en el camino, y cuál queda protegida? ¿Para qué sirve `anonymous_identity`?

**Q5.4** Omitir `ca_cert` en la configuración del supplicant igual autentica correctamente. Explicá con precisión qué propiedad de seguridad acabás de descartar.

**Q5.5** Apareció `Received packet ... invalid Message-Authenticator` en lugar de un Access-Reject. ¿Por qué el servidor no puede simplemente responder "secreto incorrecto"?

**Q5.6** ¿Qué tres atributos debe llevar un Access-Accept para poner un puerto en una VLAN, y qué debe ser cierto del switch para que surtan efecto?

**Q5.7** MAC Authentication Bypass (`Service-Type = Call-Check`) autentica un dispositivo por su dirección MAC. ¿Por qué eso no es autenticación en ningún sentido significativo, y qué controles compensatorios requiere?

---

## Ejercicio 6 — Router Advertisements IPv6 rogue

### Pasos

1. En `lab-gw`, ejecutá el router *legítimo*:

   ```conf
   # /etc/radvd.conf
   interface enp1s0 {
       AdvSendAdvert on;
       MinRtrAdvInterval 30;
       MaxRtrAdvInterval 100;
       AdvDefaultPreference high;
       AdvManagedFlag off;
       AdvOtherConfigFlag on;

       prefix 2001:db8:cafe:1::/64 {
           AdvOnLink on;
           AdvAutonomous on;
           AdvRouterAddr on;
           AdvValidLifetime 2592000;
           AdvPreferredLifetime 604800;
       };

       RDNSS 2001:db8:cafe:1::53 {
           AdvRDNSSLifetime 1200;
       };

       DNSSL lab.example {
           AdvDNSSLLifetime 1200;
       };
   };
   ```

   ```bash
   sudo sysctl -w net.ipv6.conf.enp1s0.forwarding=1
   sudo systemctl enable --now radvd && systemctl status radvd --no-pager
   ```

2. En `lab-target` (con `accept_ra` temporalmente reactivado para que puedas ver el efecto), registrá la línea base honesta:

   ```bash
   sudo sysctl -w net.ipv6.conf.enp1s0.accept_ra=1 net.ipv6.conf.enp1s0.autoconf=1
   ip -6 addr show dev enp1s0
   ip -6 route show
   ```

   ```
   inet6 2001:db8:cafe:1:5054:ff:feaa:bbcc/64 scope global dynamic mngtmpaddr
          valid_lft 2591978sec preferred_lft 604778sec
   default via fe80::5054:ff:fe12:3456 dev enp1s0 proto ra metric 1024 pref high
   ```

   Notá `proto ra` — el kernel etiqueta las rutas que aprendió de un advertisement.

3. Solicitá activamente y enumerá todos los routers que respondan:

   ```bash
   rdisc6 -m enp1s0
   ```

   ```
   Soliciting ff02::2 (ff02::2) on enp1s0...

   Hop limit                 :           64 (      0x40)
   Stateful address conf.    :           No
   Stateful other conf.     :          Yes
   Router preference         :         high
   Router lifetime           :         1800 (0x00000708) seconds
    Prefix                   : 2001:db8:cafe:1::/64
     On-link                 :          Yes
     Autonomous address conf.:          Yes
    Recursive DNS server     : 2001:db8:cafe:1::53
    Source link-layer address: 52:54:00:12:34:56
    from fe80::5054:ff:fe12:3456
   ```

   `-m` sigue escuchando en lugar de salir después de la primera respuesta — que es justamente el punto cuando estás cazando un segundo router.

4. Resolvé una dirección de capa de enlace a la manera IPv6 (no hay ARP):

   ```bash
   ndisc6 2001:db8:cafe:1::1 enp1s0
   ```

   ```
   Soliciting 2001:db8:cafe:1::1 (2001:db8:cafe:1::1) on enp1s0...
   Target link-layer address: 52:54:00:12:34:56
    from 2001:db8:cafe:1::1
   ```

5. Iniciá un monitor continuo de RA en `lab-target`:

   ```bash
   sudo tshark -i enp1s0 -l -Y 'icmpv6.type == 134' \
        -T fields -e frame.time -e eth.src -e ipv6.src \
                  -e icmpv6.nd.ra.router_lifetime \
                  -e icmpv6.nd.ra.cur_hop_limit \
                  -e icmpv6.opt.prefix.prefix \
                  -e icmpv6.opt.rdnss.dns \
        -E separator=' | ' -E header=y
   ```

6. En `lab-rogue`, anunciá una ruta por defecto competidora con mayor preferencia y un servidor DNS que controlás:

   ```conf
   # /etc/radvd.conf on lab-rogue
   interface enp1s0 {
       AdvSendAdvert on;
       MaxRtrAdvInterval 4;
       AdvDefaultPreference high;
       AdvDefaultLifetime 9000;
       prefix 2001:db8:dead::/64 {
           AdvOnLink on;
           AdvAutonomous on;
       };
       RDNSS 2001:db8:dead::66 { AdvRDNSSLifetime 9000; };
   };
   ```

   ```bash
   sudo systemctl start radvd
   ```

7. En `lab-target`, observá el compromiso:

   ```bash
   ip -6 addr show dev enp1s0 | grep -c 'scope global dynamic'
   ip -6 route show | grep '^default'
   ```

   ```
   default via fe80::5054:ff:fe12:3456 dev enp1s0 proto ra metric 1024 pref high
   default via fe80::5054:ff:fe99:9966 dev enp1s0 proto ra metric 1024 pref high
   ```

   El host ahora tiene dos rutas por defecto y dos direcciones globales, y `rdisc6 -m` muestra dos valores `eth.src` distintos. En un segmento con exactamente un router, `count(distinct eth.src where icmpv6.type==134) > 1` es tu condición de alarma.

8. Vigilá también la variante de denegación de servicio — un RA que pone en cero el router lifetime, retirando el gateway real:

   ```bash
   sudo tshark -r /dev/stdin -Y 'icmpv6.type == 134 && icmpv6.nd.ra.router_lifetime == 0' 2>/dev/null &
   ```

9. Mitigá, en orden de durabilidad:

   ```bash
   # a) Host: refuse to learn anything (correct for statically addressed servers)
   sudo sysctl -w net.ipv6.conf.enp1s0.accept_ra=0 \
                  net.ipv6.conf.enp1s0.autoconf=0 \
                  net.ipv6.conf.enp1s0.accept_ra_defrtr=0 \
                  net.ipv6.conf.enp1s0.accept_ra_pinfo=0

   # b) Host: drop and log rogue RAs at the filter (exercise 2, step 6)
   sudo nft list chain inet filter input | grep ROGUE-RA
   sudo journalctl -k -g 'ROGUE-RA' -n 5

   # c) Clean up the state the attack already installed
   sudo ip -6 route flush proto ra
   sudo ip -6 addr flush dev enp1s0 scope global dynamic
   ```

   ```
   # d) Infrastructure: the only real fix — RFC 6105 RA Guard on the access switch
   interface GigabitEthernet1/0/12
    ipv6 nd raguard attach-policy HOST_PORTS
   ```

10. Verificá que el host quedó inerte mientras el rogue sigue transmitiendo:

    ```bash
    sudo timeout 20 tshark -i enp1s0 -q -Y 'icmpv6.type == 134' -z io,stat,10,'COUNT(icmpv6.type)icmpv6.type==134'
    ip -6 route show | grep -c 'proto ra'
    ```

    Los advertisements siguen llegando; el kernel no instala nada.

### Preguntas de comprensión

**Q6.1** ¿Qué tipos ICMPv6 son Router Solicitation y Router Advertisement, y a qué grupo multicast apunta cada uno?

**Q6.2** Un RA rogue no necesita posición privilegiada, ni envenenamiento ARP, ni acceso IPv4, y aun así puede tomar el control de todo un segmento. Explicá por qué el protocolo lo permite — citá la suposición de diseño del RFC 4861.

**Q6.3** Distinguí los dos modos de falla: el RA rogue que agrega una ruta por defecto, y el RA rogue que lleva `Router Lifetime = 0`. ¿Cuál es el impacto de cada uno?

**Q6.4** `accept_ra=0` protege el host. ¿Por qué, sin embargo, acá se lo describe como la *más débil* de las cuatro mitigaciones?

**Q6.5** ¿Cuál es la diferencia entre `accept_ra=1` y `accept_ra=2`, y cuándo importa la distinción?

**Q6.6** Un host en una red "solo IPv4" sigue siendo vulnerable a un RA rogue. Explicá la vía de ataque y por qué deshabilitar el direccionamiento IPv6 en el gestor de red no alcanza.

**Q6.7** `rdisc6` sin `-m` sale después de la primera respuesta. ¿Por qué eso lo vuelve inútil como detector de routers rogue, y qué flag lo arregla?

**Q6.8** Más allá de RA Guard, el RFC 3971 define una respuesta criptográfica. Nombrala y decí por qué rara vez se despliega.

---

## Ejercicio 7 — DHCP rogue y anomalías ARP

### Pasos

1. Desde `lab-ops`, preguntale al segmento quién está dispuesto a repartir direcciones:

   ```bash
   sudo nmap --script broadcast-dhcp-discover -e enp1s0
   ```

   ```
   Pre-scan script results:
   | broadcast-dhcp-discover:
   |   Response 1 of 2:
   |     Interface: enp1s0
   |     IP Offered: 192.168.56.101
   |     DHCP Message Type: DHCPOFFER
   |     Server Identifier: 192.168.56.10
   |     Subnet Mask: 255.255.255.0
   |     Router: 192.168.56.10
   |     Domain Name Server: 192.168.56.53
   |     IP Address Lease Time: 12h00m00s
   |   Response 2 of 2:
   |     Interface: enp1s0
   |     IP Offered: 10.13.37.55
   |     DHCP Message Type: DHCPOFFER
   |     Server Identifier: 192.168.56.66
   |     Router: 192.168.56.66
   |     Domain Name Server: 10.13.37.1
   |     IP Address Lease Time: 10m00s
   Nmap done: 0 IP addresses (0 hosts up) scanned in 5.42 seconds
   ```

   Dos ofertas en un segmento de un solo servidor: ese es el hallazgo. El lease corto, la subred ajena y el `Router`/`DNS` controlados por el atacante son la firma clásica de MITM.

2. Hacé lo mismo con DHCPv6, que se olvida con frecuencia:

   ```bash
   sudo nmap --script broadcast-dhcp6-discover -e enp1s0
   ```

3. Construí un detector pasivo en lugar de un sondeador activo, para que pueda correr permanentemente:

   ```bash
   sudo tshark -i enp1s0 -l -f 'udp port 67 or udp port 68' \
        -Y 'dhcp.option.dhcp == 2 || dhcp.option.dhcp == 5' \
        -T fields -e frame.time -e eth.src -e ip.src \
                  -e dhcp.option.dhcp -e dhcp.option.dhcp_server_id \
                  -e dhcp.option.router -e dhcp.option.domain_name_server \
                  -e dhcp.ip.your -e dhcp.option.ip_address_lease_time \
        -E separator=' | ' -E header=y
   ```

   La opción 53 con valor 2 es `DHCPOFFER`, con valor 5 es `DHCPACK`. Cualquier `dhcp.option.dhcp_server_id` fuera de tu inventario es un rogue.

4. Contrastá con la herramienta hecha para eso:

   ```bash
   sudo dhcpdump -i enp1s0
   ```

5. Aplicá el control en el host y, donde seas dueño del bridge, en L2:

   ```bash
   # host side: already in /etc/nftables.conf from exercise 2
   sudo journalctl -k -g 'ROGUE-DHCP' -n 5
   ```

   ```nft
   # /etc/nftables-bridge.conf — for a Linux bridge acting as the access switch
   table bridge dhcp_guard {
       chain forward {
           type filter hook forward priority -300; policy accept;

           # DHCP server traffic may only enter from the uplink port
           iifname != "uplink0" udp sport 67 udp dport 68 \
               counter log prefix "DHCP-SNOOP-DROP " level warn drop
           iifname != "uplink0" udp sport 547 udp dport 546 \
               counter log prefix "DHCP6-SNOOP-DROP " level warn drop
       }
   }
   ```

   ```bash
   sudo nft -c -f /etc/nftables-bridge.conf && sudo nft -f /etc/nftables-bridge.conf
   ```

   En hardware gestionado el equivalente es DHCP snooping:

   ```
   ip dhcp snooping
   ip dhcp snooping vlan 56
   interface GigabitEthernet1/0/24
    description uplink to core
    ip dhcp snooping trust
   interface range GigabitEthernet1/0/1-23
    ip dhcp snooping limit rate 15
   ```

6. Detectá la capa ARP del mismo ataque con `arpwatch`. Ejecutalo primero en primer plano:

   ```bash
   sudo install -d -m 0750 -o arpwatch -g arpwatch /var/lib/arpwatch
   sudo arpwatch -d -i enp1s0 -f /var/lib/arpwatch/enp1s0.dat
   ```

7. En `lab-rogue`, reclamá la dirección IPv4 del gateway, y después leé el reporte:

   ```bash
   sudo arping -c 3 -A -I enp1s0 -s 52:54:00:99:99:66 192.168.56.10
   ```

   ```
   From: root (root)
   To: root
   Subject: changed ethernet address (lab-gw)

               hostname: lab-gw
             ip address: 192.168.56.10
       ethernet address: 52:54:00:99:99:66
        ethernet vendor: unknown
   old ethernet address: 52:54:00:12:34:56
    old ethernet vendor: unknown
              timestamp: Tuesday, August 25, 2026 11:04:12 +0000
     previous timestamp: Tuesday, August 25, 2026 11:03:58 +0000
                  delta: 14 seconds
   ```

8. Hacelo persistente y enrutá las alertas a donde las lea un humano:

   ```bash
   # Debian: interfaces and options in /etc/arpwatch.conf, one per line
   echo 'enp1s0 -m security@lab.example -p' | sudo tee -a /etc/arpwatch.conf
   sudo systemctl enable --now arpwatch@enp1s0.service
   sudo journalctl -u arpwatch@enp1s0 -f
   ```

   `-p` deshabilita el modo promiscuo — monitoreás solo lo que el switch reenvía a este puerto, que es normalmente lo que querés en un puerto de acceso y nunca lo que querés en un puerto SPAN.

9. Fijá el gateway para que este host no pueda ser redirigido aunque se ataque la caché ARP:

   ```bash
   sudo ip neigh replace 192.168.56.10 lladdr 52:54:00:12:34:56 \
                 dev enp1s0 nud permanent
   ip neigh show 192.168.56.10
   ```

   ```
   192.168.56.10 dev enp1s0 lladdr 52:54:00:12:34:56 PERMANENT
   ```

### Preguntas de comprensión

**Q7.1** ¿Por qué `nmap --script broadcast-dhcp-discover` se clasifica como script de *pre-scan*, y por qué reporta "0 IP addresses ... scanned"?

**Q7.2** Llegan dos DHCPOFFER. ¿Cuál acepta un cliente estándar, y qué implica eso sobre la fiabilidad de un ataque de DHCP rogue desde el punto de vista del atacante?

**Q7.3** La oferta rogue tenía un lease de 10 minutos mientras que la legítima tenía 12 horas. ¿Por qué elegiría un atacante un lease corto?

**Q7.4** Un servidor DHCP rogue puede repartir un `Router` (opción 3) y un `Domain Name Server` (opción 6) maliciosos. Nombrá una tercera opción que sea al menos igual de peligrosa y explicá el ataque.

**Q7.5** DHCP snooping es una funcionalidad del switch, y sin embargo implementaste un equivalente con `nftables` en la familia `bridge`. ¿Por qué la familia `bridge` y no `inet`?

**Q7.6** Enumerá las clases de evento que reporta `arpwatch` y decí cuál indica ARP spoofing frente a cuál indica rotación normal de DHCP.

**Q7.7** ¿Qué cambia `arpwatch -p`, y en qué tipo de puerto omitirlo es un error?

**Q7.8** Una entrada de vecino `PERMANENT` derrota el ARP spoofing para esa única dirección. Dá dos razones por las que esto no escala como defensa general.

---

## Ejercicio 8 — Un arnés de detección de deriva continua

### Pasos

1. Escribí el chequeo:

   ```bash
   #!/usr/bin/env bash
   # /usr/local/sbin/net-drift
   set -euo pipefail
   umask 077

   TARGETS=/etc/net-drift/targets.txt
   STATE=/var/lib/net-drift
   BASE="$STATE/baseline.xml"
   CUR="$STATE/current.xml"
   DIFF="$STATE/drift.txt"

   install -d -m 0700 "$STATE"

   nmap -sS -sV -O --top-ports 1000 --open -T4 \
        -iL "$TARGETS" -oX "$CUR" >/dev/null

   if [[ ! -s $BASE ]]; then
       cp -- "$CUR" "$BASE"
       logger -t net-drift -p auth.notice "baseline established"
       exit 0
   fi

   # ndiff exits 0 identical, 1 differences, 2 error — distinguish 1 from 2.
   rc=0
   ndiff "$BASE" "$CUR" > "$DIFF" || rc=$?
   case $rc in
       0) logger -t net-drift -p auth.info "no drift" ;;
       1) logger -t net-drift -p auth.warning "network surface drift detected"
          logger -t net-drift -p auth.warning -f "$DIFF" ;;
       *) logger -t net-drift -p auth.err "ndiff failed with status $rc"; exit "$rc" ;;
   esac

   # Rogue infrastructure sweep, same run.
   nmap --script broadcast-dhcp-discover,broadcast-dhcp6-discover -e enp1s0 \
       | awk '/Server Identifier/ {print $NF}' | sort -u \
       | grep -vxF -f /etc/net-drift/authorised-dhcp.txt \
       | while read -r bad; do
             logger -t net-drift -p auth.crit "unauthorised DHCP server: $bad"
         done || true

   timeout 40 rdisc6 -m enp1s0 2>/dev/null \
       | awk '/^ from / {print $2}' | sort -u \
       | grep -vxF -f /etc/net-drift/authorised-routers.txt \
       | while read -r bad; do
             logger -t net-drift -p auth.crit "unauthorised IPv6 router: $bad"
         done || true
   ```

   ```bash
   sudo install -m 0700 /tmp/net-drift /usr/local/sbin/net-drift
   sudo install -d -m 0700 /etc/net-drift
   printf '192.168.56.10\n192.168.56.20\n' | sudo tee /etc/net-drift/targets.txt
   printf '192.168.56.10\n'                | sudo tee /etc/net-drift/authorised-dhcp.txt
   printf 'fe80::5054:ff:fe12:3456\n'      | sudo tee /etc/net-drift/authorised-routers.txt
   ```

2. Programalo:

   ```ini
   # /etc/systemd/system/net-drift.service
   [Unit]
   Description=Network surface and rogue-infrastructure drift check
   After=network-online.target
   Wants=network-online.target

   [Service]
   Type=oneshot
   Nice=10
   IOSchedulingClass=idle
   ExecStart=/usr/local/sbin/net-drift
   ProtectSystem=strict
   ReadWritePaths=/var/lib/net-drift
   PrivateTmp=yes
   NoNewPrivileges=yes
   AmbientCapabilities=CAP_NET_RAW CAP_NET_ADMIN
   CapabilityBoundingSet=CAP_NET_RAW CAP_NET_ADMIN
   ```

   ```ini
   # /etc/systemd/system/net-drift.timer
   [Unit]
   Description=Run the network drift check nightly

   [Timer]
   OnCalendar=daily
   RandomizedDelaySec=1h
   Persistent=true

   [Install]
   WantedBy=timers.target
   ```

   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable --now net-drift.timer
   systemctl list-timers net-drift.timer --no-pager
   sudo systemctl start net-drift.service && journalctl -u net-drift -n 20 --no-pager
   ```

3. Demostrá que el arnés dispara. Reejecutá el `radvd` rogue del ejercicio 6 y el `arping` del ejercicio 7, y después:

   ```bash
   sudo systemctl start net-drift.service
   sudo journalctl -t net-drift -p crit --no-pager
   ```

   ```
   Aug 25 23:41:07 lab-ops net-drift[4412]: unauthorised DHCP server: 192.168.56.66
   Aug 25 23:41:49 lab-ops net-drift[4412]: unauthorised IPv6 router: fe80::5054:ff:fe99:9966
   ```

4. Aprobá un cambio legítimo como debería hacerlo un proceso de control de cambios:

   ```bash
   sudo cp /var/lib/net-drift/current.xml /var/lib/net-drift/baseline.xml
   logger -t net-drift -p auth.notice "baseline re-approved: CHG-2026-0812 (mariadb on lab-target)"
   ```

### Preguntas de comprensión

**Q8.1** El script usa `set -e` y sin embargo invoca `ndiff` de una forma que sobrevive a una salida distinta de cero. Explicá la construcción y por qué un `ndiff a b` ingenuo abortaría el script ante cada deriva detectada.

**Q8.2** Aparece `AmbientCapabilities=CAP_NET_RAW` en lugar de correr como root. ¿Qué tipos de escaneo de nmap la necesitan, y cuáles funcionarían sin ella?

**Q8.3** ¿Por qué `RandomizedDelaySec=1h` y `Persistent=true`? ¿Contra qué protege cada uno?

**Q8.4** El paso 4 sobrescribe la línea base. Nombrá el control que debe envolver esta acción, y el modo de falla cuando falta.

**Q8.5** Este arnés detecta un servidor DHCP rogue solo si responde *durante el chequeo*. Nombrá un enfoque de detección sin ese punto ciego y decí cuánto cuesta.

---

## Fuentes de referencia

- LPI — Objetivos del examen 303-300: <https://www.lpi.org/our-certifications/exam-303-objectives/>
- Nmap Reference Guide: <https://nmap.org/book/man.html> · Ndiff: <https://nmap.org/ndiff/> · `broadcast-dhcp-discover`: <https://nmap.org/nsedoc/scripts/broadcast-dhcp-discover.html>
- Wireshark — `tshark(1)`: <https://www.wireshark.org/docs/man-pages/tshark.html> · Display Filter Reference: <https://www.wireshark.org/docs/dfref/> · Privilegios de `dumpcap`: <https://wiki.wireshark.org/CaptureSetup/CapturePrivileges>
- Documentación de FreeRADIUS: <https://www.freeradius.org/documentation/> · Wiki (archivos de configuración, `radiusd -X`): <https://wiki.freeradius.org/>
- RFC 2865 — RADIUS: <https://www.rfc-editor.org/rfc/rfc2865.html> · RFC 2866 — Accounting: <https://www.rfc-editor.org/rfc/rfc2866.html> · RFC 3579 — Soporte RADIUS para EAP: <https://www.rfc-editor.org/rfc/rfc3579.html>
- IEEE 802.1X-2020 — Port-Based Network Access Control: <https://standards.ieee.org/ieee/802.1X/7345/>
- hostapd: <https://w1.fi/hostapd/> · wpa_supplicant: <https://w1.fi/wpa_supplicant/>
- RFC 4861 — Neighbor Discovery para IPv6: <https://www.rfc-editor.org/rfc/rfc4861.html> · RFC 4862 — SLAAC: <https://www.rfc-editor.org/rfc/rfc4862.html>
- RFC 6104 — Planteo del problema del Router Advertisement IPv6 rogue: <https://www.rfc-editor.org/rfc/rfc6104.html> · RFC 6105 — IPv6 RA Guard: <https://www.rfc-editor.org/rfc/rfc6105.html> · RFC 3971 — SEND: <https://www.rfc-editor.org/rfc/rfc3971.html>
- ndisc6 / rdisc6 (herramientas de diagnóstico IPv6): <https://www.remlab.net/ndisc6/>
- radvd: <https://radvd.litech.org/>
- arpwatch (Lawrence Berkeley National Laboratory): <https://ee.lbl.gov/>
- Kernel de Linux — referencia de sysctl de IP: <https://www.kernel.org/doc/html/latest/networking/ip-sysctl.html>
- Wiki de nftables: <https://wiki.nftables.org/wiki-nftables/index.php/Main_Page>
- `systemd.resource-control(5)` — `IPAddressAllow`/`IPAddressDeny`: <https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html>
- RFC 2131 — DHCP: <https://www.rfc-editor.org/rfc/rfc2131.html> · RFC 3315/8415 — DHCPv6: <https://www.rfc-editor.org/rfc/rfc8415.html>

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1

**A1.1** `cupsd` está ligado a `127.0.0.1:631`, no a `0.0.0.0:631`. El socket existe, pero el kernel solo acepta conexiones cuya dirección de destino sea la de loopback, así que un SYN que llega por `enp1s0` con destino `192.168.56.20` no coincide con ningún socket en escucha y el kernel responde con RST — que nmap reporta como `closed`. Esta es la medida de endurecimiento más barata que existe: ligar los servicios a la dirección más estrecha que satisfaga el requisito. "Corriendo" es un hecho de la tabla de procesos; "expuesto" es una tupla de (dirección de bind, ruta, filtro de paquetes).

**A1.2** `closed` significa que nmap recibió una respuesta negativa activa — un RST TCP, o un ICMP port-unreachable para UDP — así que hay un host ahí y nada está escuchando. `filtered` significa que nmap no recibió *nada*, o un mensaje ICMP administratively-prohibited; el sondeo fue descartado en silencio. `filtered` es el que indica un filtro de paquetes con política DROP en el camino. `unfiltered` (solo desde un ACK scan) significa que el puerto es alcanzable pero nmap no puede distinguir abierto de cerrado.

**A1.3** `-sS` escribe paquetes crudos y nunca completa el handshake, así que necesita `CAP_NET_RAW` (root, o una capability ambiental). `-sT` usa la llamada al sistema `connect(2)` común, así que cualquier usuario puede ejecutarlo. El rastro difiere en consecuencia: `-sS` no deja nada en el log de aplicación porque la conexión se derriba con RST antes de que `accept(2)` retorne, mientras que `-sT` produce una conexión completada e inmediatamente cerrada que demonios como `sshd` registran (`Connection closed by 192.168.56.30 port 41234 [preauth]`). `-sS` es además considerablemente más rápido y no agota la tabla local de sockets.

**A1.4** `ndiff` sale con **0** cuando los dos escaneos son idénticos, **1** cuando difieren, y **2** ante un error como un archivo de entrada ilegible o malformado. Bajo `set -e` el caso *esperado e informativo* (se encontró deriva) aborta el script y — peor — un error genuino (2) se vuelve indistinguible de él si solo probás `if ! ndiff`. Capturá el estado explícitamente (`rc=0; ndiff … || rc=$?`) y ramificá sobre los tres valores, como en el ejercicio 8.

**A1.5** Demuestran afirmaciones distintas. `ss -tulpn` demuestra que *ningún proceso está ligado* a ese puerto en ese host — es autoritativo sobre la propia tabla de sockets del host pero no dice nada sobre un filtro, una regla NAT, un sidecar, u otro host bajo el mismo nombre DNS. `nmap` demuestra que *este puerto no es alcanzable desde donde escaneé* — autoritativo sobre la alcanzabilidad desde un punto de vista, pero no puede distinguir "no está escuchando" de "está escuchando pero con firewall", y no dice nada sobre la alcanzabilidad desde otra red. Una afirmación defendible necesita ambos: el inventario local del host para lo que existe, y la vista de red para lo que es alcanzable desde cada zona de seguridad.

### Ejercicio 2

**A2.1** Para `rp_filter` el valor efectivo es `max(conf.all.rp_filter, conf.<dev>.rp_filter)`, así que poner `all = 1` lo activa de manera fiable en todos lados y poner `all = 0` *no* lo desactiva donde un dispositivo tiene 1. Para la mayoría de las demás claves — `accept_redirects`, `accept_ra`, `forwarding` — el valor efectivo es el *por dispositivo*, y escribir `conf.all.X` es una escritura por difusión que copia el valor a toda interfaz **que exista en ese momento**. El bug práctico: una interfaz creada *después* de que corrió `sysctl --system` (un tun de VPN, un veth de contenedor, un bridge, una NIC conectada en caliente, una interfaz renombrada por udev tarde en el arranque) hereda `conf.default.X`, no el `conf.all.X` que fijaste. De ahí que tengas que fijar tanto `all` (dispositivos existentes) como `default` (dispositivos futuros), y volver a verificar por dispositivo.

**A2.2** `all` fue una difusión de una sola vez hacia las interfaces presentes cuando se aplicó la configuración. `default` es la plantilla que se copia al directorio sysctl por dispositivo cada vez que aparece una interfaz nueva. Sin él, toda interfaz creada más tarde — el veth de un contenedor, un túnel WireGuard, un bridge — levanta con el valor por defecto del kernel `accept_ra = 1` y va a instalar alegremente una ruta desde cualquier advertisement que vea. El paso 3 demuestra exactamente esto con `dummy0`.

**A2.3** `IPAddressAllow`/`IPAddressDeny` están implementados con un filtro eBPF de dirección de socket a nivel cgroup, así que requieren **cgroup v2 (la jerarquía unificada) y soporte BPF en el kernel**, y un systemd compilado con BPF firewalling. Verificalo con `systemd-analyze security <unit>` (la línea `IPAddressDeny=` aparece como exenta/ok frente a no soportada), `systemctl show <unit> -p IPAddressDeny`, y `systemctl --version | grep -o '+BPF_FRAMEWORK'`. En un sistema con cgroup v1 systemd registra una advertencia al iniciar la unit y la directiva queda silenciosamente inefectiva — un control de endurecimiento que parece configurado y no aplica nada.

**A2.4** Antes del ruleset, `mariadb` no estaba escuchando, así que el kernel generaba un RST TCP para el SYN y nmap clasificaba el puerto como `closed`. Después del ruleset, el `policy drop` al final de la cadena `input` descarta el SYN sin generar respuesta alguna, así que el sondeo de nmap expira tras todas sus retransmisiones y clasifica el puerto como `filtered`. La distinción es en sí misma una señal de reconocimiento: `closed` le dice al atacante que ahí existe un host, `filtered` le niega incluso eso.

**A2.5** El RFC 4861 §11.2 exige que todo mensaje de Neighbour Discovery se envíe con un Hop Limit IPv6 de 255 y exige que los receptores descarten los mensajes ND cuyo hop limit no sea 255. Como un router decrementa el hop limit, un valor de 255 en el receptor demuestra que el paquete *no fue enrutado* — se originó en el enlace local. Ese único match elimina por lo tanto todo el **spoofing de ND y RA inyectado remotamente desde fuera del enlace**: un atacante que no está en tu segmento L2 no puede falsificar un paquete que llegue con hop limit 255. No hace nada contra un atacante que *sí está* en el segmento — para eso están la lista blanca de `ip6 saddr` y RA Guard.

**A2.6** `rp_filter = 1` (reverse-path forwarding estricto) descarta todo paquete cuya dirección de origen no sería enrutada de vuelta por la interfaz por la que llegó. Eso rompe el **enrutamiento asimétrico** — legítimo en hosts multi-homed, montajes ECMP/multipath, algunas topologías VRRP y de balanceadores DSR, y esquemas de policy routing. La solución es `rp_filter = 2` (modo laxo: el origen debe ser enrutable por *alguna* interfaz, no necesariamente la de ingreso), que sigue frenando la inundación clásica con origen falsificado tolerando la asimetría. Las excepciones por interfaz (`net.ipv4.conf.<dev>.rp_filter = 2`) son preferibles a debilitar el valor global — recordando la regla de `max()` de A2.1, que implica que tenés que bajar `all` a 0 y subir las interfaces seguras individualmente.

### Ejercicio 3

**A3.1** Un filtro de captura `-f` se compila a bytecode BPF y se ejecuta **en el kernel**, dentro de la ruta de paquetes de `dumpcap`, antes de que el paquete se copie a espacio de usuario. Un filtro de visualización `-Y` se evalúa **en espacio de usuario** con el motor completo de disectores de Wireshark, después de que el paquete fue capturado, copiado y disecado. La elección decide si perdés paquetes cada vez que la tasa de captura se acerca al rendimiento de copia y disección de la máquina: en un enlace ocupado, disecar todo para descartar el 99% satura una CPU y el ring buffer del kernel desborda — `capinfos` y el resumen de `tshark` van a reportar paquetes perdidos. Regla práctica: recortá el volumen en el kernel con `-f`, después refiná en espacio de usuario con `-Y` o fuera de línea con `-r`.

**A3.2** `-f 'tcp port 80'` conserva todo paquete TCP en el puerto 80 — SYN, ACK, RST, FIN, retransmisiones, TLS sobre 80 y basura malformada — pero descarta HTTP servido en cualquier otro puerto. `-Y 'http'` conserva HTTP dondequiera que el disector lo reconozca (8080, 8000, o un puerto fijado por `decode_as`) pero descarta los paquetes puros de handshake y cierre que no llevan capa HTTP, que son exactamente los datos que necesitás para diagnosticar una conexión que nunca se completa.

**A3.3** Los disectores de Wireshark son cientos de miles de líneas de C que parsean entrada hostil, controlada por el atacante; un bug de disector se convierte en ejecución remota de código con los privilegios del proceso. Correr eso como root le da a un atacante que puede poner un paquete en tu cable el control total de la máquina. La solución arquitectónica es la separación de privilegios: el pequeño helper `dumpcap` tiene `cap_net_admin,cap_net_raw=eip` y no hace más que capturar, mientras que la GUI y los disectores corren como el usuario sin privilegios. La pertenencia al grupo `wireshark` concede la ejecución de `dumpcap`; nada más necesita privilegios.

**A3.4** `-s 96` trunca cada paquete a 96 bytes, lo que cubre Ethernet + IP + TCP/UDP y un poco más. Siguen siendo posibles: análisis de flujos y conversaciones, estadísticas de endpoints, inventario de puertos y protocolos, análisis de estado TCP y retransmisiones, temporización, inspección de opciones ND/RA/DHCP cortas, detección de servidores rogue. Ya no son posibles: reconstrucción de payload, `follow tcp stream`, extracción de archivos, recuperación de credenciales, inspección completa del handshake TLS, y cualquier disección de datos de aplicación más allá del corte — esas tramas aparecen como `[Packet size limited during capture]`. El truncamiento es muchas veces un *requisito*, no un compromiso: mantiene una captura permanente dentro de una política de protección de datos que prohíbe retener contenido de usuarios.

**A3.5** En régimen estacionario son como máximo **10 archivos × 65 536 kB ≈ 640 MB** (`-b filesize` está en kilobytes). Cuando el décimo archivo alcanza el límite de tamaño, `tshark` abre un undécimo y **borra el más viejo**, así que siempre tenés los ~640 MB más recientes y nada crece sin límite. Los datos más viejos se pierden de forma permanente — dimensioná el anillo contra cuánto tarda en notarse un incidente, y archivá los archivos fuera del equipo si necesitás una ventana más larga. Notá `-b duration:` y `-b interval:` como condiciones alternativas de rotación.

**A3.6** El filtro es **`dhcp`** (y `dhcpv6` para IPv6). Reemplazó a **`bootp`** en Wireshark 3.0, porque DHCP es una extensión del encuadre BOOTP y el disector históricamente llevaba ese nombre. `bootp` sigue aceptándose como alias obsoleto en muchas compilaciones, pero los scripts deberían usar `dhcp`; los nombres de campo también se movieron — `bootp.option.dhcp` pasó a ser `dhcp.option.dhcp`.

### Ejercicio 4

**A4.1** El RADIUS moderno usa **UDP/1812 para autenticación y autorización** y **UDP/1813 para accounting** (asignados por IANA, RFC 2865/2866). Los puertos históricos, previos a la asignación, todavía soportados por muchas implementaciones son **UDP/1645 (auth)** y **UDP/1646 (acct)** — colisionan con el servicio `datametrics`, que es por lo que fueron reemplazados. RadSec (RADIUS sobre TLS, RFC 6614) usa TCP/2083.

**A4.2** `User-Password` no está cifrado en ningún sentido moderno: el cliente hace XOR de la contraseña (rellenada a un múltiplo de 16 octetos) con un keystream construido a partir de `MD5(shared_secret || Request_Authenticator)`, encadenando MD5 sobre el bloque de texto cifrado anterior para contraseñas más largas. La única entrada secreta es el **secreto compartido** — el Request Authenticator viaja en texto claro en el mismo paquete. Así que un atacante que capture un Access-Request y conozca o adivine el secreto compartido recupera la contraseña recalculando el keystream; eso es exactamente lo que hace el paso 10 con `-o radius.shared_secret:testing123`. Consecuencias: los secretos compartidos deben ser largos, aleatorios y únicos por NAS (nunca el default del fabricante, nunca `testing123`, nunca reutilizados entre dispositivos), y RADIUS debería atravesar solo caminos confiables — o, mejor, RadSec/IPsec.

**A4.3** `reject_delay` en `radiusd.conf` (por defecto `1` segundo, expresado como `reject_delay = 1` dentro de la sección `security { }` o de nivel superior según la versión). El servidor retiene un Access-Reject ya calculado durante ese intervalo antes de enviarlo. Dos propósitos: limita la tasa de adivinación de contraseñas en línea a través del NAS, y amortigua las tormentas de peticiones que producen los clientes mal configurados que reintentan de inmediato ante un rechazo. También implica que una alerta ingenua de "latencia de autenticación" va a marcar cada login fallido.

**A4.4** CHAP (RFC 1994) y MS-CHAPv2 son protocolos de desafío–respuesta: el servidor debe calcular la respuesta esperada a partir del desafío y del *material de la contraseña* en sí — `MD5(id || password || challenge)` para CHAP, y un cálculo derivado del hash NT para MS-CHAPv2. Ni la contraseña ni el hash NT pueden derivarse de un hash unidireccional de la contraseña (`Crypt-Password`, bcrypt, SHA-512), así que un almacén con hash soporta **solo PAP**. Si necesitás CHAP/MS-CHAPv2 tenés que guardar `Cleartext-Password`, o `NT-Password` para MS-CHAP específicamente — que es por lo que el almacén de credenciales en sí se vuelve la joya de la corona y por lo que EAP-TLS (certificados, sin contraseña en reposo) es el diseño más fuerte.

**A4.5** Dos condiciones: (1) el **módulo `radutmp` debe estar listado en la sección `accounting { }`** del servidor virtual activo, `/etc/raddb/sites-enabled/default` (y típicamente en `session { }` para los chequeos de uso simultáneo); y (2) el **archivo `radutmp` debe existir y ser escribible** por el usuario `radiusd` — `/var/log/radius/radutmp` en RHEL, `/var/log/freeradius/radutmp` en Debian — con el `filename` del módulo en `/etc/raddb/mods-available/radutmp` apuntando a él. `radwho` lee `radutmp` (sesiones actuales); `radlast` lee `radwtmp` (histórico). Sin paquetes de accounting, sin el módulo, o con una ruta equivocada, ambas herramientas imprimen una tabla vacía sin error.

**A4.6** El atributo Message-Authenticator (RFC 2869) es un HMAC-MD5 sobre todo el paquete con clave igual al secreto compartido. Requerirlo significa que el servidor rechaza todo Access-Request que no esté protegido en integridad, lo que bloquea la inyección de paquetes y la suplantación trivial de un NAS por parte de cualquiera que pueda alcanzar UDP/1812 — y es obligatorio para toda petición que lleve EAP-Message. Está en `no` para `localhost` en la configuración provista porque las utilidades locales de prueba (`radtest`, y `radclient` salvo que se lo pidas) no siempre incluyen el atributo, y la configuración provista prioriza "el tutorial funciona sin tocar nada" por encima de la estrictez en un cliente solo de loopback. Para cualquier NAS real, ponelo en `yes`.

**A4.7** `systemctl start radiusd` demoniza, baja privilegios y registra con verbosidad normal a syslog o al journal — ves `Login OK` / `Login incorrect` y poco más. `radiusd -X` (equivalentemente `-Xxx`, o `-xx -l stdout`) corre monohilo en primer plano con salida de depuración completa, imprimiendo **cada módulo de la cadena de política, en orden, con la lista de atributos antes y después de cada uno**, la entrada exacta del archivo `users` que coincidió con su número de línea, los pares de atributos de la petición y de la respuesta, y la razón de la decisión. Como FreeRADIUS es un motor de políticas y no un programa de autenticación fijo, casi toda falla es "la petición bajó por una rama de la política distinta de la que asumiste" — que es invisible en los logs normales y explícita en `-X`. La primera pregunta estándar del proyecto upstream ante cualquier reporte de bug es la salida de `radiusd -X`.

**A4.8** El archivo `users` se procesa de arriba hacia abajo y, ante una entrada que coincide, se detiene en la primera coincidencia salvo que la entrada fije `Fall-Through = Yes`. `DEFAULT` coincide con **todas** las peticiones. Puesta primera, coincidiría con cada intento de autenticación antes de que `bob` o la entrada de MAB siquiera se consideren, y con `Auth-Type := Reject` todo usuario del archivo sería denegado — una caída total que parece un problema de credenciales. La regla de ordenamiento es la misma que la de un firewall: reglas específicas primero, catch-all al final.

### Ejercicio 5

**A5.1** **Supplicant** — el cliente que busca acceso: `lab-target` corriendo `wpa_supplicant`. **Autenticador** — el dispositivo de red que controla el puerto y retransmite EAP: `lab-gw` corriendo `hostapd -d wired` (en producción, el switch de acceso o el AP inalámbrico). **Servidor de autenticación** — la entidad que toma la decisión: `lab-ops` corriendo FreeRADIUS. El autenticador es deliberadamente un relé tonto; no guarda credenciales y no toma decisiones de política, que es por lo que un único servidor RADIUS puede gobernar miles de puertos.

**A5.2** `01:80:c2:00:00:03` es la **dirección de grupo PAE (Port Access Entity)**, una MAC multicast reservada de IEEE 802.1D; EAPOL usa el Ethertype `0x888E`. 802.1X no puede correr sobre IP porque su propósito entero es autenticar *antes* de que el puerto esté autorizado — en ese momento el supplicant no tiene dirección IP, ni ruta, ni lease DHCP, ni tráfico permitido más allá de EAPOL. El intercambio debe ser por lo tanto un protocolo de capa de enlace entre pares directamente conectados. Recién después de `CTRL-EVENT-EAP-SUCCESS` el autenticador abre el puerto al tráfico general, momento en el cual DHCP e IP pueden proceder.

**A5.3** La **identidad externa** del EAP-Response/Identity inicial viaja en texto claro, antes de que exista el túnel TLS, y es visible para cualquiera en el segmento. La **identidad interna y el intercambio de credenciales MSCHAPv2** viajan dentro del túnel TLS de PEAP y están protegidos. `anonymous_identity` te permite poner un valor no identificatorio (`anonymous@lab.example`) en la identidad externa para que los observadores pasivos aprendan solo el realm — necesario para el ruteo de proxy RADIUS — y no quién está iniciando sesión. Dejar `identity` tal cual filtra un inventario de nombres de usuario de tu organización a cualquiera con una captura.

**A5.4** Sin `ca_cert`, el supplicant establece el túnel TLS de PEAP con **cualquier certificado que el servidor presente, sin validar**. Eso destruye la autenticación del servidor, y la seguridad de PEAP descansa enteramente en ella: un atacante levanta un autenticador rogue más un servidor RADIUS rogue con un certificado autofirmado, el supplicant tuneliza hacia él contento, y luego entrega el intercambio MSCHAPv2 — del cual el atacante recupera material para crackear la contraseña fuera de línea (la construcción basada en DES de MSCHAPv2 está rota; `asleap`/`hashcat` lo hacen rutinariamente). Esta es *la* mala configuración clásica de 802.1X. Un supplicant correcto fija `ca_cert` y además restringe el nombre del servidor (`altsubject_match`, `domain_suffix_match`) para que un certificado de *alguna* CA confiable para *otro* nombre también sea rechazado.

**A5.5** El Message-Authenticator es un HMAC con clave igual al secreto compartido. Cuando el secreto es incorrecto el servidor calcula un HMAC distinto del que lleva el paquete, y no puede distinguir "un NAS legítimo con el secreto mal configurado" de "un atacante inyectando peticiones falsificadas". El RFC 2865 exige por lo tanto que **descarte el paquete en silencio**; responder algo le daría al atacante un oráculo que confirma que una dirección de origen dada es un cliente configurado y — a fines de sondeo — una respuesta con la que trabajar. En cambio lo registra localmente, que es por lo que "invalid Message-Authenticator" en `radiusd -X` es la firma definitiva de secreto compartido incorrecto, y por lo que un NAS con el secreto equivocado reporta "sin respuesta del servidor" en lugar de "rechazado".

**A5.6** `Tunnel-Type = VLAN (13)`, `Tunnel-Medium-Type = IEEE-802 (6)`, y `Tunnel-Private-Group-Id = "<vlan-id-or-name>"` (RFC 3580). Los tres son obligatorios — un switch que recibe solo `Tunnel-Private-Group-Id` lo ignora. El switch debe soportar VLANs asignadas por RADIUS (asignación dinámica de VLAN / "AAA authorization network"), debe tener la VLAN de destino definida y permitida en el puerto, y el puerto debe estar en modo controlado por 802.1X en lugar de una VLAN de acceso fija. Si el tag está presente en los atributos de túnel, el tag mismo (`Tunnel-Type:1 = VLAN`) debe ser consistente entre los tres.

**A5.7** MAB autentica un valor que el dispositivo difunde en cada trama que envía, que cualquier atacante en el segmento puede leer con una sola captura y luego fijar en su propia NIC con `ip link set address`. Es un *identificador*, no una *credencial* — no hay secreto y no se demuestra nada. Existe porque impresoras, cámaras IP, lectores de credenciales y controladores de HVAC no tienen supplicant. Controles compensatorios: poné los dispositivos con MAB en una VLAN dedicada y fuertemente filtrada, sin camino hacia nada sensible; usá lista blanca de MACs específicas en lugar de aceptar cualquiera; combinalo con DHCP snooping e IP Source Guard para que la dirección no pueda robarse mientras el dispositivo real está en línea; alertá si la misma MAC aparece en dos puertos; agregá perfilado de dispositivos (huella DHCP, patrón de tráfico) para detectar una laptop que se hace pasar por impresora; y preferí 802.1X con certificados para todo lo que pueda correr un supplicant.

### Ejercicio 6

**A6.1** **Router Solicitation es ICMPv6 tipo 133**, enviado a `ff02::2` (multicast de todos los routers). **Router Advertisement es ICMPv6 tipo 134**, enviado a `ff02::1` (multicast de todos los nodos) cuando es no solicitado/periódico, o unicast al host que solicitó como respuesta. Para completar: Neighbour Solicitation 135, Neighbour Advertisement 136, Redirect 137.

**A6.2** El RFC 4861 asume que el enlace local es un **entorno confiable y cooperativo**: todo nodo cuyo RA llegue con hop limit 255 y origen link-local es aceptado como router, sin autenticación del emisor y sin ninguna noción de autorización. El objetivo de diseño era el arranque sin configuración — un host debe poder encontrar un router antes de tener credenciales, claves o configuración con las cuales autenticar uno. La consecuencia es que "¿puedo ser tu gateway por defecto y tu servidor DNS?" es una afirmación no autenticada que cualquier dispositivo del segmento puede hacer, lo que el RFC 6104 documenta como el problema del RA rogue. Notá que la misma suposición de confianza subyace a ARP en IPv4; IPv6 simplemente la vuelve más poderosa, porque un solo RA entrega gateway, prefijo y DNS en un único paquete.

**A6.3** Agregar una ruta es un **man-in-the-middle**: el host instala una segunda ruta por defecto y una segunda dirección global y — según la selección de dirección de origen, las métricas de ruta y el campo de preferencia de router — envía parte o todo su tráfico off-link a través del atacante, que además pudo haber suministrado un RDNSS malicioso. Es parcial y probabilístico, pero suficiente, y es silencioso. `Router Lifetime = 0` es una **denegación de servicio**: el RFC 4861 define un lifetime de cero como "ya no soy un router por defecto", así que un RA falsificado que lleve el origen link-local del router *legítimo* y un lifetime de cero hace que todos los hosts del segmento borren su ruta por defecto. Inundar con muchos RA falsificados distintos es una tercera variante que agota CPU y estado de direcciones (el clásico efecto `flood_router26`) y puede colgar pilas sin parchear.

**A6.4** Porque protege solo a los hosts que te acordaste de configurar, y solo mientras nadie los cambie. Cada VM nueva, veth de contenedor, laptop, máquina de contratista, appliance, interfaz de gestión de hipervisor y NIC conectada en caliente arranca con el valor por defecto del kernel `accept_ra = 1`; NetworkManager y systemd-networkd anulan el sysctl por conexión (`ipv6.method=auto`, `IPv6AcceptRA=yes`), reactivándolo en silencio; y los hosts que legítimamente *necesitan* SLAAC — la mayoría de los clientes — no pueden usarlo en absoluto. Es host por host, de exclusión voluntaria, y falla abierto. RA Guard en el switch de acceso (RFC 6105) elimina el advertisement rogue del segmento por completo, protege a todos los dispositivos incluidos los que no administrás, no necesita estado por host, y falla cerrado. La postura correcta es ambas: `accept_ra=0` en servidores con direccionamiento estático como defensa en profundidad, y RA Guard como el control real.

**A6.5** `accept_ra = 1` significa "aceptar Router Advertisements **salvo** que esta interfaz esté haciendo forwarding" — el kernel ignora silenciosamente los RA en una interfaz con `forwarding=1`, bajo la teoría de que un router no debería aprender su propia ruta por defecto del segmento al que sirve. `accept_ra = 2` significa "aceptarlos **incluso si** el forwarding está habilitado". La distinción importa en cualquier host que sea a la vez router y cliente SLAAC: un gateway Linux o un host de contenedores/VMs que hace forwarding para sus huéspedes pero obtiene su propia configuración aguas arriba por SLAAC necesita `2`, y si no va a levantar sin ruta por defecto de una manera que parece una falla aguas arriba. También importa para el endurecimiento — habilitar el forwarding *no* es una forma fiable de hacer que un host ignore los RA, porque un valor de 2 lo derrota.

**A6.6** Cualquier kernel moderno tiene IPv6 habilitado y direcciones link-local configuradas, y la pila IPv6 es preferida sobre IPv4 por la política de selección de direcciones por defecto (RFC 6724). Un RA rogue suministra un prefijo global, una ruta por defecto y un RDNSS, y en ese momento el host "solo IPv4" de repente tiene IPv6 funcionando y lo prefiere — así que la resolución de nombres y las conexiones que antes usaban IPv4 ahora atraviesan al atacante. Este es el patrón NAT64/`SLAAC attack`. Deshabilitar el direccionamiento IPv6 en el gestor de red es insuficiente porque el kernel igual puede autoconfigurar antes o de forma independiente de él, y porque una interfaz reactivada o recién creada revierte. La remediación real es o bien la deshabilitación completa a nivel de kernel (`net.ipv6.conf.all.disable_ipv6=1`, más `ipv6.disable=1` en la línea de comandos del kernel donde realmente no se quiera IPv6) o — mucho mejor — desplegar IPv6 deliberadamente con RA Guard, de modo que IPv6 sea monitoreado en lugar de meramente no administrado.

**A6.7** Sin `-m`, `rdisc6` imprime el primer Router Advertisement que recibe y sale, así que en un segmento comprometido va a reportar exactamente un router — normalmente el más rápido en responder, que bien puede ser el atacante — y no te va a dar ninguna indicación de que existe un segundo. La detección de routers rogue es inherentemente una comparación de *conjuntos*, así que tenés que recolectar todas las respuestas. **`-m`** ("esperar múltiples RA") sigue escuchando; combinalo con `-w <ms>` para el tiempo de espera y un envoltorio `timeout` para scripting, y después compará el conjunto de direcciones link-local de origen contra tu inventario. `-1` hace lo opuesto de lo que querés acá: pide explícitamente una única respuesta.

**A6.8** **SEND — SEcure Neighbor Discovery (RFC 3971)**, que firma los mensajes ND y RA con una clave pública ligada a una **CGA (Cryptographically Generated Address, RFC 3972)** y valida la autorización del router con cadenas de certificados X.509. Rara vez se despliega porque requiere una PKI de autorización de routers, soporte de CGA y las opciones RSA Signature/Timestamp/Nonce en la pila de cada host, y los sistemas operativos mayoritarios no traen una implementación soportada; además interactúa mal con DHCPv6, las direcciones de privacidad y la movilidad. En la práctica la industria se asentó en los controles de L2 — RA Guard, DHCPv6 Guard, IPv6 Snooping/Source Guard — que no necesitan ninguna cooperación del host.

### Ejercicio 7

**A7.1** Los scripts NSE de broadcast no apuntan a un host: envían un sondeo de broadcast o multicast link-local por una interfaz y escuchan a quien responda. Nmap los ejecuta en la **fase de pre-scan**, antes del descubrimiento de hosts y del escaneo de puertos, porque sus resultados pueden *informar* el escaneo (descubren hosts que no conocías). Como no se dio una lista de objetivos, la fase de escaneo de hosts de nmap no tuvo nada que hacer y reporta "0 IP addresses ... scanned" — la salida útil está enteramente en el bloque `Pre-scan script results:`. Esta es también la razón por la que `-e <iface>` normalmente es obligatorio: sin objetivos, nmap no puede inferir por qué interfaz difundir.

**A7.2** Un cliente estándar acepta la **primera DHCPOFFER que recibe** (el RFC 2131 permite recolectar múltiples ofertas y elegir entre ellas, pero esencialmente toda implementación real toma la primera). Así que el ataque es una **carrera que el atacante normalmente gana**: el servidor rogue es un proceso liviano en el mismo segmento, sin base de datos de leases que consultar ni disco que tocar, mientras que el servidor legítimo típicamente está más lejos, más ocupado, y puede hacer primero una búsqueda de lease, una actualización DNS o una escritura a base de datos. Desde el punto de vista del atacante el ataque es poco fiable por cliente pero fiable en agregado — a lo largo de un segmento entero de renovaciones va a capturar una porción sustancial de los clientes, y forzar renovaciones (una desautenticación, un rebote de puerto, una inundación de DHCPNAK) mejora las probabilidades.

**A7.3** Un lease corto obliga al cliente a volver al servidor rogue cada pocos minutos, lo que (a) vuelve a ganar la carrera repetidamente y reafirma el gateway y el DNS maliciosos incluso si el cliente obtuvo brevemente un lease legítimo, (b) mantiene fresca la configuración del atacante para que un reinicio del nodo rogue recapture clientes rápido, y (c) implica que cuando el atacante se va, la configuración maliciosa expira rápido y la evidencia desaparece del archivo de leases del cliente. También es un indicio: un tiempo de lease muchísimo más corto que tu estándar es una firma de detección barata.

**A7.4** **Opción 121 — Classless Static Route** (y su predecesora la opción 33, más la opción 249 en Windows). Le permite al servidor instalar rutas específicas arbitrarias en la tabla de ruteo del cliente — por ejemplo `10.0.0.0/8` y `0.0.0.0/1` + `128.0.0.0/1` vía el atacante — que le ganan a la ruta por defecto por coincidencia de prefijo más largo. Esto es peligroso incluso contra un cliente VPN: la clase de ataque "TunnelVision" usa la opción 121 para enrutar tráfico esquivando la interfaz del túnel mientras la VPN sigue apareciendo conectada. Otras opciones de alto valor: **opción 66/67 (servidor TFTP y nombre de archivo de arranque)**, que puede redirigir el arranque por red a código provisto por el atacante, **opción 15 (domain name)** y **opción 119 (domain search)** para secuestro del orden de búsqueda, y **opción 252 (WPAD)** para inyección automática de proxy.

**A7.5** Porque las tramas que tenés que bloquear están siendo **puenteadas, no enrutadas**. Una DHCPOFFER de un nodo rogue hacia un cliente en otro puerto del mismo bridge se reenvía en capa 2 y nunca entra en la ruta de forwarding IP, así que ningún hook de las familias `inet`/`ip` la ve jamás — `type filter hook forward` en la familia `inet` solo procesa paquetes enrutados. La familia `bridge` se engancha a la propia ruta de forwarding del bridge (el sucesor nftables de `ebtables`), que es donde debe tomarse la decisión. El match `iifname != "uplink0"` implementa la esencia de DHCP snooping: el tráfico con rol de servidor (sport 67 → dport 68 para v4, 547 → 546 para v6) es legítimo solo desde el puerto confiable.

**A7.6** `arpwatch` reporta: **new activity** (un par MAC/IP no visto en seis meses), **new station** (una MAC nunca vista antes), **flip flop** (la MAC de una IP volvió a una MAC vista previamente), **changed ethernet address** (la MAC de una IP cambió a una nueva), **bogon** (una dirección ARP de origen fuera de la subred/máscara configurada de la interfaz), más **ethernet broadcast** e **ip broadcast** para direcciones de todos ceros o todos unos. **`changed ethernet address` y especialmente `flip flop`** son los indicadores de spoofing — un flip flop en cuestión de segundos es la firma de un atacante y el host real reclamando alternadamente una dirección. La rotación normal de DHCP produce **new station** y **new activity** (un dispositivo nuevo obtiene una dirección) y, benignamente, **changed ethernet address** cuando un lease se reasigna a otro dispositivo — que es por lo que arpwatch en un segmento DHCP necesita la base de datos de leases al lado para ser accionable, y por lo que las direcciones de gateways y servidores (que nunca deberían cambiar de MAC) son los sujetos de mayor señal.

**A7.7** `-p` le indica a `arpwatch` que **no ponga la interfaz en modo promiscuo**. Sin él, arpwatch ve todas las tramas que la NIC recibe; con él, solo las tramas que la interfaz aceptaría de todos modos — broadcast (que incluye todas las peticiones ARP), multicast y unicast dirigido a sí misma. Omitir `-p` es un error en un **puerto de acceso** conmutado normal, donde el modo promiscuo casi no aporta nada (el switch no te reenvía el unicast de otros puertos) pero cuesta CPU y, en algunos drivers, dispara alertas de monitoreo de capa de enlace. Omitirlo es *obligatorio* en un **puerto SPAN/espejo o un tap**, donde el punto entero es recibir tramas dirigidas a otras estaciones — ahí, `-p` cegaría al monitor a todo salvo el broadcast.

**A7.8** (1) **No escala operativamente**: cada gateway, servidor DNS, balanceador de carga y par necesita una entrada mantenida a mano en cada host, y un reemplazo legítimo de hardware, un cambio de NIC, un failover VRRP o una migración a la nube rompen la conectividad en silencio de una manera que se presenta como una caída parcial misteriosa en lugar de un error de configuración. (2) **Solo protege las entradas que fijaste, y solo en ese host** — el atacante simplemente apunta a una dirección no fijada, o envenena la caché *del gateway* en el sentido inverso, o ataca la tabla CAM del switch. Además, las entradas `nud permanent` saltean la detección de alcanzabilidad, así que el host sigue enviando a una MAC muerta. Los equivalentes escalables son **Dynamic ARP Inspection e IP Source Guard** en el switch (validando ARP contra la tabla de bindings de DHCP snooping) y **autenticación de puerto 802.1X** para que los dispositivos no autorizados nunca lleguen al segmento; las entradas estáticas a nivel de host conviene reservarlas para un puñado de direcciones genuinamente fijas y de alto valor.

### Ejercicio 8

**A8.1** La construcción es `rc=0; ndiff "$BASE" "$CUR" > "$DIFF" || rc=$?`. Bajo `set -e` un comando que sale con código distinto de cero termina el shell, **excepto** cuando es el operando izquierdo de `||`/`&&`, parte de una condición, o negado con `!` — así que `|| rc=$?` a la vez suprime la salida y captura el estado para el `case`. Un `ndiff a b` ingenuo aborta el script ante el código 1, que es el resultado *normal e informativo* cada vez que hay deriva: el script moriría justamente cuando tenía algo que reportar, no se enviaría ninguna alerta, y la unit de systemd mostraría `FAILURE` sin explicación. Notá también que `if ! ndiff a b; then …` correría sin abortar pero confundiría el código 1 (se encontró deriva) con el 2 (error de ndiff) — tratando en silencio un archivo de línea base corrupto como "deriva", o peor, como algo ya atendido.

**A8.2** `CAP_NET_RAW` se necesita para abrir sockets crudos y forjar paquetes: **`-sS`, `-sA`, `-sF`, `-sN`, `-sX`, `-sU`, `-sO`, el descubrimiento de hosts `-PE/-PS/-PA`, el fingerprinting de SO `-O`**, el escaneo a nivel ARP de un segmento local, y los scripts NSE de broadcast usados en el mismo script. Funcionan sin ella: **`-sT`** (connect scan, sockets comunes), **`-sn` con `-PS`/`-PA` degradado a sondeos TCP connect**, `-sV` de detección de versiones sobre puertos ya abiertos, y la mayoría de los scripts NSE que no usan sockets crudos. `CAP_NET_ADMIN` se incluye acá para la manipulación de interfaz que necesitan los scripts de broadcast y `rdisc6`. El sentido de `AmbientCapabilities` más un `CapabilityBoundingSet` acorde es que un compromiso de disector o de script NSE rinde acceso a sockets crudos, no root — un radio de explosión materialmente menor que `User=root`.

**A8.3** `RandomizedDelaySec=1h` reparte la hora de inicio a lo largo de una hora para que, en una flota, cientos de hosts no empiecen todos a escanear a las 00:00 — un escaneo sincronizado de toda la flota parece un ataque para tu propio IDS, satura enlaces, y puede voltear appliances frágiles. `Persistent=true` registra la última ejecución y, si la máquina estaba apagada o suspendida cuando el timer debería haber disparado, ejecuta la unit **una vez poco después del arranque** en lugar de saltear el intervalo — así una laptop o un host en una ventana de mantenimiento igual recibe su chequeo, y no se crea un hueco en el rastro de evidencia solo porque la máquina estuvo caída.

**A8.4** **Control de cambios** — la línea base puede reaprobarse solo contra un cambio registrado y autorizado (la referencia `CHG-2026-0812` en la línea de `logger`), con el diff mismo adjunto, por alguien distinto de quien hizo el cambio donde aplique la separación de funciones. Sin eso el arnés degenera en un sello de goma: la respuesta natural a una alerta ruidosa es "copiá current sobre baseline", y lo primero que hace un atacante que aterriza en el host de monitoreo es exactamente eso. El modo de falla es un sistema de monitoreo que reporta "sin deriva" indefinidamente mientras la superficie que vigilaba cambió por completo. Endurecimiento práctico: mantené las líneas base en control de versiones para que las reaprobaciones sean revisables y reversibles, hacé que `/var/lib/net-drift/baseline.xml` sea escribible solo por una ruta privilegiada separada, y alertá sobre la *modificación* de la línea base como evento propio.

**A8.5** Un sondeo activo nocturno solo encuentra un servidor rogue que esté encendido y respondiendo durante los pocos segundos del chequeo — un atacante que corre su servidor DHCP durante veinte minutos en la hora del almuerzo es invisible. El enfoque sin ese punto ciego es el **monitoreo pasivo continuo**: un filtro `tshark`/`dumpcap` corriendo permanentemente sobre `udp port 67 or 68` e `icmpv6.type == 134` (paso 3 del ejercicio 7 y paso 5 del ejercicio 6), alimentando una regla que alerte ante cualquier `dhcp.option.dhcp_server_id` u origen de RA fuera del inventario — o mejor, la ruta de aplicación, donde `log prefix "ROGUE-DHCP "` de `nftables` y el DHCP snooping del switch generan un evento por cada trama infractora. Los costos son un proceso de captura privilegiado y de larga vida que hay que asegurar y parchear (mitigado con capabilities en `dumpcap`, un snaplen truncado y un ring buffer), CPU y disco continuos, volumen de logs y una carga de ajuste por falsos positivos, y una decisión sobre la retención de datos de tráfico bajo tu política de protección de datos. En la práctica corrés ambos: aplicación más alertado pasivo para cobertura, y el sondeo activo periódico como verificación independiente de que la aplicación sigue en su lugar.

</details>